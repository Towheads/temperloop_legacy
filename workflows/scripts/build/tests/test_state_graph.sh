#!/usr/bin/env bash
#
# Tests for workflows/scripts/build/state-graph.sh — the derived state
# graph's core builder (temperloop#1910, ADR 0033). ONE fixture system: this
# test `source`s state-graph.sh (whose source-guard skips the CLI dispatch),
# which in turn sources board.sh — and overrides the SAME `_board_gh` seam
# the board replay tests use (no second mock layer, no PATH shim, zero
# network), plus this file's own `_sg_git` seam for `git worktree list`.
# Fixtures are entirely synthetic: no real host names, session ids, or paths.
#
# Covers (sixteen ok/absent/error/stale cases, four per source, plus six extra
# pr_list cases for the control-byte, empty-after-sanitize, and arity/type
# guard classes):
#   - board:        ok (valid fnd:status:* + a claimed_by edge, session id
#                    normalized via jk_session8), absent (zero open issues),
#                    error (a status not in the ontology registry), stale
#   - board_edges:  ok (sub_issue_of + blocked_by from board_sub_issues /
#                    board_blocked_by_open), absent (no edges found), error
#                    (cascades from an upstream board error — board.sh's own
#                    accessors are fail-open by design, see state-graph.sh's
#                    comment), stale
#   - pr_list:      ok (a PR node + a closes edge parsed from a bare
#                    `Closes #N` line — a backticked / mid-sentence / same-
#                    line-trailer mention is excluded), absent (no open PRs),
#                    error (gh pr list fails), stale — plus one extra ok case
#                    (temperloop#1981): a LITERAL control byte in a PR title or
#                    body is stripped before jq, so the source recovers rather
#                    than degrading to error for as long as that PR stays open,
#                    and two empty-after-jq cases (round 2) — a control-byte-
#                    only and a whitespace-only payload — each asserting a ZERO
#                    return plus valid JSON with status `error`, since jq exits
#                    0 with no output on both and the fall-through was a
#                    non-zero return that aborts the whole snapshot build,
#                    and three arity/type cases (round 3) — a multi-document
#                    payload, non-array JSON, and an array whose elements are
#                    not PR objects — each asserting a ZERO return plus valid
#                    JSON with status `error`, since a `length`-only guard let
#                    all three past into either the hard abort or a confident
#                    `ok` over an empty node set
#   - worktrees:    ok (a linked `<repo>.wt/<slug>` worktree), absent (no
#                    linked worktrees), error (git itself fails), stale
# Plus: the snapshot goes through lib/cache.sh (repo-keyed dir, meta.json,
# atomic write); `clean --board N` removes only that one repo's snapshot;
# `bench --scale N` reports an N-scaled synthetic node/edge count and a
# build_ms; the reader table is structurally extensible (state-graph-build-
# local appends three more sources without editing the assembly loop).
#
# The seams are redefined mid-file per case (the library calls them
# indirectly), so shellcheck's "never invoked"/"unreachable" checks are false
# positives — disabled file-wide like the sibling board replay tests.
# shellcheck disable=SC2317,SC2329
set -euo pipefail

# Hermetic conf env (temperloop#501): fixture tests must never resolve boards
# through the repo's or host's real boards.conf.
export BOARDS_CONF_REPO_LOCAL=/dev/null
export BOARDS_CONF_MACHINE=/dev/null

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the script under test. Its source-guard ([ BASH_SOURCE = $0 ]) skips
# the CLI dispatch, exposing cmd_*/_sg_* and the shared _board_gh seam.
# shellcheck source=workflows/scripts/build/state-graph.sh
source "$HERE/../state-graph.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Host-local sources (state-graph-build-local, temperloop#1918: plan_notes /
# journal / tmux; temperloop#1980 round 3: transcripts) must never read this
# RUNNER's real knowledge store, transcript root, tmux server, or Claude
# Code projects directory — this file's own four-source suite (and its exact
# node/edge counts, e.g. the bench assertions below) stays deterministic
# regardless of what plan notes, journals, tmux windows, or session
# transcripts happen to exist on the host actually running the test.
# Isolated exactly like the BOARDS_CONF_* hermetic-env pair above;
# test_state_graph_local.sh is the dedicated suite for these four sources'
# own behavior.
export KNOWLEDGE_STORE_ROOT="$TMP/no-such-knowledge-store"
export SPEND_TRANSCRIPT_ROOT="$TMP/no-such-transcripts"
export CLAUDE_PROJECTS_DIR="$TMP/no-such-projects"
_sg_tmux() { return 1; }

# Every test gets its own cache root so cases never see each other's state.
fresh_cache() { export CACHE_STORE_ROOT="$TMP/cache-$1"; }

BOARD=4          # Towheads/foundation, per board.sh's built-in map
REPO="Towheads/foundation"

# Confirm the shared fixture system is live.
command -v _board_gh >/dev/null || fail "board.sh not sourced — shared fixture system missing"
echo "PASS: state-graph.sh sources board.sh — one shared fixture system (_board_gh in scope)"

# =============================================================================
# source: board (Issue nodes, fnd:status:* state, claimed_by edges)
# =============================================================================

# --- board: ok ---------------------------------------------------------------
# A valid fnd:status:* label plus a claim stamp; the claimed_by edge's session
# id must be normalized through jk_session8 (the join-key loader), never
# hand-rolled — an already-8-hex-char stamp (board_own_stamp's own truncated
# form) falls back to the loader's lowercase OUTPUT shape.
_board_gh() {
  case "$1 $2" in
    "issue list")
      cat <<'JSON'
[{"number":10,"title":"x","labels":[{"name":"fnd:status:ready"},{"name":"fnd:host/session:mini-1:ABCD1234"}]}]
JSON
      ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
out="$(_sg_read_board "$BOARD")"
[ "$(jq -r .status <<<"$out")" = "ok" ] || fail "board ok status (got: $out)"
[ "$(jq -r '.nodes[0].status' <<<"$out")" = "fnd:status:ready" ] || fail "board ok status token (got: $out)"
[ "$(jq -r '.edges[0].to' <<<"$out")" = "Session:mini-1:abcd1234" ] || fail "board ok claimed_by not lowercase-normalized (got: $out)"
echo "PASS: board source ok — valid status token + normalized claimed_by edge"

# --- board: absent -------------------------------------------------------
_board_gh() {
  case "$1 $2" in
    "issue list") echo '[]' ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
out="$(_sg_read_board "$BOARD")"
[ "$(jq -r .status <<<"$out")" = "absent" ] || fail "board absent status (got: $out)"
echo "PASS: board source absent — zero open issues"

# --- board: error (unknown status token) ------------------------------------
_board_gh() {
  case "$1 $2" in
    "issue list") echo '[{"number":1,"title":"x","labels":[{"name":"fnd:status:x-bogus"}]}]' ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
out="$(_sg_read_board "$BOARD")"
[ "$(jq -r .status <<<"$out")" = "error" ] || fail "board error status on unknown token (got: $out)"
echo "PASS: board source error — node status not in ontology registry"

# --- board: error (board_resolve itself fails) ------------------------------
_board_gh() { return 7; }
out="$(_sg_read_board "$BOARD")"
[ "$(jq -r .status <<<"$out")" = "error" ] || fail "board error status on board_resolve failure (got: $out)"
echo "PASS: board source error — board_resolve failure"

# --- board: closed-issue residue (temperloop#1978 round 2, acceptance
# criterion 2) --------------------------------------------------------------
# ONE `_board_gh api "repos/.../issues" --method GET -f state=closed -f
# labels=<label> ...` call PER `fnd:status:*` label (never `gh issue list` —
# that shape collides with the OPEN-issue mock arm every other case in this
# file uses; never a single unfiltered call either — GitHub's `labels`
# filter is server-side AND-only, so this must be one call per label).
# `fnd:status:backlog`'s own call returns #158 (this item's day-1 soak
# evidence); `fnd:status:ready` and `fnd:status:in-progress` return empty
# pages, mirroring the live label inventory having zero closed residue for
# those two labels today.
_board_gh() {
  case "$1 $2" in
    "issue list") echo '[{"number":1,"title":"x","labels":[{"name":"fnd:status:ready"}]}]' ;;
    "api repos/$REPO/issues")
      case " $* " in
        *" labels=fnd:status:backlog "*) echo '[{"number":158,"title":"y","labels":[{"name":"fnd:status:backlog"}]}]' ;;
        *) echo '[]' ;;
      esac
      ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
out="$(_sg_read_board "$BOARD")"
[ "$(jq -r .status <<<"$out")" = "ok" ] || fail "board ok status with closed residue present (got: $out)"
[ "$(jq -c '[.nodes[] | select(.id=="Issue:158")] | .[0] | {status,state}' <<<"$out")" = '{"status":"fnd:status:backlog","state":"closed"}' ] \
  || fail "board closed-residue node #158 shape mismatch (got: $out)"
[ "$(jq '.nodes | length' <<<"$out")" = 2 ] || fail "board closed-residue node count (open #1 + closed #158, found via its own label's call) mismatch (got: $out)"
echo "PASS: board source — a closed issue still wearing an fnd:status:* label surfaces as its own residue Issue node, via that label's own filtered GET"

# --- board: closed-issue residue call is a GET, never a POST (temperloop#1978
# round 2, Finding 1 + required structural defense) -------------------------
# `gh api` silently switches from GET to POST the instant ANY `-f`/`-F`
# param is present, unless `--method`/`-X` names GET explicitly — this is
# exactly the round-1 regression (a live 422 against the create-an-issue
# endpoint, swallowed whole by the fail-soft arm). A mock that only replays
# a canned BODY back is structurally blind to this (dispatches on "$1 $2"
# regardless of method), so this one instead RECORDS the full argv of every
# closed-residue call — to a FILE, since `_sg_read_board` invokes `_board_gh`
# through `$(...)` command substitution, a subshell an in-memory array
# mutation would not survive — and asserts `--method GET` (or `-X GET`) is
# present on EACH recorded call: asserting on the REQUEST SHAPE, not the
# response.
_SG_TEST_CALLS_FILE="$TMP/closed-residue-calls"
: > "$_SG_TEST_CALLS_FILE"
_board_gh() {
  case "$1 $2" in
    "issue list") echo '[{"number":1,"title":"x","labels":[{"name":"fnd:status:ready"}]}]' ;;
    "api repos/$REPO/issues")
      printf '%s\n' "$*" >> "$_SG_TEST_CALLS_FILE"
      echo '[]'
      ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
out="$(_sg_read_board "$BOARD")"
[ -s "$_SG_TEST_CALLS_FILE" ] || fail "closed-residue read made zero _board_gh api calls (expected one per fnd:status:* label)"
while IFS= read -r call; do
  case " $call " in
    *" --method GET "*|*" -X GET "*) : ;;
    *) fail "closed-residue call regressed off an explicit GET (gh api would silently POST to the create-issue endpoint): $call" ;;
  esac
done < "$_SG_TEST_CALLS_FILE"
echo "PASS: board source — every closed-residue call carries an explicit --method GET (never a bare -f call that gh would silently POST)"

# --- board: closed-issue residue read fails -> FAIL-SOFT, never errors the
# whole board source (the primary open-issue read still succeeded) ----------
_board_gh() {
  case "$1 $2" in
    "issue list") echo '[{"number":1,"title":"x","labels":[{"name":"fnd:status:ready"}]}]' ;;
    "api repos/$REPO/issues") return 1 ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
out="$(_sg_read_board "$BOARD" 2>/dev/null)"
[ "$(jq -r .status <<<"$out")" = "ok" ] || fail "a failing closed-residue read must not error the whole board source (got: $out)"
[ "$(jq '.nodes | length' <<<"$out")" = 1 ] || fail "a failing closed-residue read should contribute zero extra nodes (got: $out)"
echo "PASS: board source — a failing closed-residue read degrades to zero extra nodes, never a hard error on the whole source"

# --- board: closed-issue residue routes through board.sh's sanitize stage
# (temperloop#1978 round 3, HIGH 3) -- a literal control byte in a returned
# issue's title must not silently zero out that label's residue the way an
# unsanitized `… | jq` would (the parse fails, `2>/dev/null` swallows it,
# `|| extra='[]'` turns it into a clean empty result — the exact silent-
# zero-residue failure this whole read exists to prevent, reached by
# another path).
_ctrl="$(printf '\001')"
_board_gh() {
  case "$1 $2" in
    "issue list") echo '[{"number":1,"title":"x","labels":[{"name":"fnd:status:ready"}]}]' ;;
    "api repos/$REPO/issues")
      case " $* " in
        *" labels=fnd:status:backlog "*) printf '[{"number":159,"title":"bad%sbyte","labels":[{"name":"fnd:status:backlog"}]}]\n' "$_ctrl" ;;
        *) echo '[]' ;;
      esac
      ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
out="$(_sg_read_board "$BOARD" 2>/dev/null)"
[ "$(jq -r .status <<<"$out")" = "ok" ] || fail "a control byte in a closed-residue title must not error the whole board source (got: $out)"
[ "$(jq '[.nodes[] | select(.id=="Issue:159")] | length' <<<"$out")" = 1 ] \
  || fail "a control byte in a closed-residue issue's title must not silently drop that label's residue — the sanitize stage must run before jq parses it (got: $out)"
echo "PASS: board source — the closed-issue residue read routes through _board_sanitize_control_chars before jq, surviving a leaked control byte"

# --- board: closed-issue residue excludes pull requests (temperloop#1978
# round 3, MEDIUM 1) -- GitHub's REST /repos/{o}/{r}/issues endpoint returns
# PRs alongside issues; reconcile.sh's own `gh issue list` side never does,
# so an unfiltered read would turn a closed, labeled PR into a phantom
# residue Issue node reconcile.sh can never agree with.
_board_gh() {
  case "$1 $2" in
    "issue list") echo '[{"number":1,"title":"x","labels":[{"name":"fnd:status:ready"}]}]' ;;
    "api repos/$REPO/issues")
      case " $* " in
        *" labels=fnd:status:backlog "*) echo '[{"number":160,"title":"a PR","pull_request":{"url":"x"},"labels":[{"name":"fnd:status:backlog"}]}]' ;;
        *) echo '[]' ;;
      esac
      ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
out="$(_sg_read_board "$BOARD" 2>/dev/null)"
[ "$(jq -r .status <<<"$out")" = "ok" ] || fail "a closed PR on the residue endpoint must not error the whole board source (got: $out)"
[ "$(jq '.nodes | length' <<<"$out")" = 1 ] || fail "a closed PR carrying an fnd:status:* label must never become a residue Issue node (got: $out)"
echo "PASS: board source — the closed-issue residue read excludes pull requests via select(has(\"pull_request\") | not)"

# --- board: closed-issue residue warns (never silently truncates) when a
# label's page returns exactly per_page=100 (temperloop#1978 round 3,
# MEDIUM 2) -- mirrors reconcile.sh's own never-silently-truncate posture
# at its STATE_LIMIT cap.
_full_page="$(jq -cn '[range(100) | {number:(2000+.), title:"x", labels:[{name:"fnd:status:backlog"}]}]')"
_board_gh() {
  case "$1 $2" in
    "issue list") echo '[{"number":1,"title":"x","labels":[{"name":"fnd:status:ready"}]}]' ;;
    "api repos/$REPO/issues")
      case " $* " in
        *" labels=fnd:status:backlog "*) printf '%s\n' "$_full_page" ;;
        *) echo '[]' ;;
      esac
      ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
_sg_read_board "$BOARD" >/dev/null 2>"$TMP/full-page-stderr"
grep -q "returned a full page (100)" "$TMP/full-page-stderr" \
  || fail "a closed-residue label page returning exactly 100 items must warn about possible truncation (stderr: $(cat "$TMP/full-page-stderr"))"
echo "PASS: board source — a closed-residue label page returning exactly per_page=100 warns rather than silently truncating"

# --- board: closed-issue residue label list is captured before the loop
# (temperloop#1978 round 3, LOW) -- under set -euo pipefail, the producer's
# `grep '^fnd:status:'` exits 1 whenever the registry carries zero
# fnd:status:* rows; without the `|| true` fallback the bare assignment
# would abort the whole function instead of degrading to "no labels to
# query".
_orig_sg_issue_status_tokens="$(declare -f _sg_issue_status_tokens)"
_sg_issue_status_tokens() { printf 'done\n'; }
_board_gh() {
  case "$1 $2" in
    "issue list") echo '[]' ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
out="$(_sg_read_board "$BOARD" 2>/dev/null)"
[ "$(jq -r .status <<<"$out")" = "absent" ] || fail "a zero-fnd:status:*-label registry must not abort the board source (got: $out)"
[ "$(jq '.nodes | length' <<<"$out")" = 0 ] || fail "a zero-fnd:status:*-label registry should contribute zero residue nodes, not error (got: $out)"
echo "PASS: board source — an empty fnd:status:* label set (grep finds no match) degrades cleanly under set -euo pipefail via the captured-labels || true fallback"
eval "$_orig_sg_issue_status_tokens"

# --- board: closed-issue residue is reachable when the board has zero OPEN
# issues (temperloop#1978 round 3, MEDIUM 3) -- hoisted above the `count -eq
# 0` branch: a board with no open issues but real closed-with-label residue
# is not "absent", it simply has all-closed state, so the absent arm must
# still carry residue nodes rather than short-circuiting past the read.
_board_gh() {
  case "$1 $2" in
    "issue list") echo '[]' ;;
    "api repos/$REPO/issues")
      case " $* " in
        *" labels=fnd:status:backlog "*) echo '[{"number":161,"title":"z","labels":[{"name":"fnd:status:backlog"}]}]' ;;
        *) echo '[]' ;;
      esac
      ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
out="$(_sg_read_board "$BOARD" 2>/dev/null)"
[ "$(jq -r .status <<<"$out")" = "absent" ] || fail "zero open issues plus residue must stay 'absent' status, not ok/error (got: $out)"
[ "$(jq '.nodes | length' <<<"$out")" = 1 ] || fail "closed-issue residue must be reachable when the board has zero OPEN issues (got: $out)"
[ "$(jq -c '.nodes[0] | {status,state}' <<<"$out")" = '{"status":"fnd:status:backlog","state":"closed"}' ] \
  || fail "residue node shape mismatch on a zero-open-issue board (got: $out)"
echo "PASS: board source — closed-issue residue is reachable even when the board has zero OPEN issues (the 'absent' arm carries residue nodes)"

# --- board: an empty-but-exit-0 closed-residue page must not abort
# _sg_read_board (temperloop#1978 round 4, MEDIUM 1) -- jq exits 0 with NO
# output on empty input (it is not an error, there is simply no JSON value
# to filter), so the pre-fix `|| extra='[]'` guard never fires and `extra`
# stays the empty string; `--argjson extra ""` then errors (invalid JSON,
# jq exit 2), which under set -euo pipefail aborted the WHOLE board source
# rather than degrading to zero extra nodes for that one label.
_board_gh() {
  case "$1 $2" in
    "issue list") echo '[{"number":1,"title":"x","labels":[{"name":"fnd:status:ready"}]}]' ;;
    "api repos/$REPO/issues")
      case " $* " in
        *" labels=fnd:status:backlog "*) : ;;  # exit 0, empty stdout — the exact input jq treats as "no value"
        *) echo '[]' ;;
      esac
      ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
out="$(_sg_read_board "$BOARD" 2>/dev/null)" \
  || fail "an empty-but-successful closed-residue page aborted _sg_read_board (rc=$?) instead of producing a result"
[ "$(jq -r .status <<<"$out")" = "ok" ] || fail "an empty-but-successful closed-residue page must still produce an ok board result (got: $out)"
[ "$(jq '.nodes | length' <<<"$out")" = 1 ] || fail "an empty-but-successful closed-residue page must contribute zero extra nodes, not abort (got: $out)"
echo "PASS: board source — an empty-but-exit-0 residue page degrades to zero extra nodes rather than aborting _sg_read_board (extra is never passed empty to --argjson)"

# --- board: an unparseable closed-residue page WARNS and is distinguishable
# from a short (non-truncated) page (temperloop#1978 round 4, MEDIUM 2) --
# `${page_count:-0}` used to collapse a failed parse to 0, which reads as "a
# short page, definitely not truncated" when the truth is "could not tell";
# the same input also fails the extra-nodes jq, so residue silently vanished
# with ZERO stderr output. A truncated body and a non-JSON error-page body
# (both bodies a `gh api` call can plausibly hand back on a proxy/edge
# failure with a 2xx-looking wrapper) must each warn.
_board_gh() {
  case "$1 $2" in
    "issue list") echo '[{"number":1,"title":"x","labels":[{"name":"fnd:status:ready"}]}]' ;;
    "api repos/$REPO/issues")
      case " $* " in
        *" labels=fnd:status:backlog "*) printf '[{"number":170,"title":"trunc"' ;;  # truncated: invalid JSON
        *) echo '[]' ;;
      esac
      ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
: > "$TMP/unparseable-page-stderr"
_sg_read_board "$BOARD" >/dev/null 2>"$TMP/unparseable-page-stderr"
grep -q "unparseable page" "$TMP/unparseable-page-stderr" \
  || fail "a truncated closed-residue page must warn 'unparseable page' on stderr (stderr: $(cat "$TMP/unparseable-page-stderr"))"
echo "PASS: board source — a truncated closed-residue page warns 'unparseable page' rather than silently reading as not-truncated"

_board_gh() {
  case "$1 $2" in
    "issue list") echo '[{"number":1,"title":"x","labels":[{"name":"fnd:status:ready"}]}]' ;;
    "api repos/$REPO/issues")
      case " $* " in
        *" labels=fnd:status:backlog "*) echo '<html>Bad Gateway</html>' ;;  # non-JSON error body
        *) echo '[]' ;;
      esac
      ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
: > "$TMP/unparseable-page-stderr-2"
_sg_read_board "$BOARD" >/dev/null 2>"$TMP/unparseable-page-stderr-2"
grep -q "unparseable page" "$TMP/unparseable-page-stderr-2" \
  || fail "a non-JSON error-body closed-residue page must warn 'unparseable page' on stderr (stderr: $(cat "$TMP/unparseable-page-stderr-2"))"
echo "PASS: board source — a non-JSON error-body closed-residue page warns 'unparseable page' rather than silently reading as not-truncated"

# --- board: the ontology `bad` check runs BEFORE the closed-issue residue
# fan-out (temperloop#1978 round 4, LOW 3) -- a registry-drift board (a
# status token outside the ontology registry) must return `error` while
# spending ZERO REST calls on residue its own error return would only
# discard. `count -eq 0` must stay BELOW the residue read (round-3 hoist
# preserved): bad check -> residue read -> count -eq 0.
_SG_TEST_RESIDUE_CALLED_FILE="$TMP/residue-called-on-bad-ontology"
rm -f "$_SG_TEST_RESIDUE_CALLED_FILE"
_board_gh() {
  case "$1 $2" in
    "issue list") echo '[{"number":1,"title":"x","labels":[{"name":"fnd:status:x-bogus"}]}]' ;;
    "api repos/$REPO/issues") touch "$_SG_TEST_RESIDUE_CALLED_FILE"; echo '[]' ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
out="$(_sg_read_board "$BOARD" 2>/dev/null)"
[ "$(jq -r .status <<<"$out")" = "error" ] || fail "a registry-drift board must still return error (got: $out)"
[ -e "$_SG_TEST_RESIDUE_CALLED_FILE" ] && fail "the ontology bad-token error return must precede the residue fan-out — a REST call was made anyway"
echo "PASS: board source — the ontology bad-token check runs before the closed-issue residue fan-out, spending zero REST calls on residue it would only discard"

# =============================================================================
# source: board_edges (sub_issue_of, blocked_by)
# =============================================================================

# --- board_edges: ok ---------------------------------------------------------
_board_gh() {
  case "$1 $2" in
    "issue list") echo '[{"number":11,"title":"x","labels":[{"name":"fnd:status:ready"}]},{"number":12,"title":"y","labels":[{"name":"fnd:status:ready"}]}]' ;;
    "api repos/$REPO/issues/11/sub_issues") echo '[{"number":12,"state":"open"}]' ;;
    "api repos/$REPO/issues/11/dependencies/blocked_by") echo '[]' ;;
    "api repos/$REPO/issues/12/sub_issues") echo '[]' ;;
    "api repos/$REPO/issues/12/dependencies/blocked_by") echo '[{"number":11,"state":"open"}]' ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
board_r="$(_sg_read_board "$BOARD")"
out="$(_sg_read_board_edges "$BOARD" "$board_r")"
[ "$(jq -r .status <<<"$out")" = "ok" ] || fail "board_edges ok status (got: $out)"
[ "$(jq -c '[.edges[] | .type] | sort' <<<"$out")" = '["blocked_by","sub_issue_of"]' ] || fail "board_edges ok edge types (got: $out)"
echo "PASS: board_edges source ok — sub_issue_of + blocked_by from board.sh accessors"

# --- board_edges: absent (no edges found) -----------------------------------
_board_gh() {
  case "$1 $2" in
    "issue list") echo '[{"number":13,"title":"x","labels":[{"name":"fnd:status:ready"}]}]' ;;
    "api repos/$REPO/issues/13/sub_issues") echo '[]' ;;
    "api repos/$REPO/issues/13/dependencies/blocked_by") echo '[]' ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
board_r="$(_sg_read_board "$BOARD")"
out="$(_sg_read_board_edges "$BOARD" "$board_r")"
[ "$(jq -r .status <<<"$out")" = "absent" ] || fail "board_edges absent status (got: $out)"
echo "PASS: board_edges source absent — issues exist, no sub_issue_of/blocked_by edges"

# --- board_edges: error (cascades from upstream board error) ---------------
_board_gh() { return 7; }
board_r="$(_sg_read_board "$BOARD")"
out="$(_sg_read_board_edges "$BOARD" "$board_r")"
[ "$(jq -r .status <<<"$out")" = "error" ] || fail "board_edges error status (got: $out)"
echo "PASS: board_edges source error — cascades from the upstream board source"

# --- board_edges: stale (via the read-time transform, see below) ----------
# Exercised together with the other three sources' stale case at the bottom
# of this file (_sg_read_snapshot marks EVERY source stale uniformly at
# read-time — there is no per-source stale trigger to test separately).

# =============================================================================
# source: pr_list (PR nodes, closes edges)
# =============================================================================

# --- pr_list: ok (bare Closes line only; backticked/trailing/leading excluded)
_board_gh() {
  case "$1 $2" in
    "pr list")
      jq -nc '[{number:1,title:"a",body:"intro\nCloses #10\nFixes #11\n`Closes #12`\nCloses #13 trailing\nleading Closes #14\n"}]'
      ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
out="$(_sg_read_pr_list "$BOARD")"
[ "$(jq -r .status <<<"$out")" = "ok" ] || fail "pr_list ok status (got: $out)"
[ "$(jq -c '[.edges[].to] | sort' <<<"$out")" = '["Issue:10","Issue:11"]' ] || fail "pr_list closes-line parsing (got: $out)"
echo "PASS: pr_list source ok — PR node + closes edges from bare Closes/Fixes lines only"

# --- pr_list: absent (no open PRs) ------------------------------------------
_board_gh() {
  case "$1 $2" in
    "pr list") echo '[]' ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
out="$(_sg_read_pr_list "$BOARD")"
[ "$(jq -r .status <<<"$out")" = "absent" ] || fail "pr_list absent status (got: $out)"
echo "PASS: pr_list source absent — no open PRs"

# --- pr_list: error (gh pr list fails) --------------------------------------
_board_gh() {
  case "$1 $2" in
    "pr list") return 5 ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
out="$(_sg_read_pr_list "$BOARD")"
[ "$(jq -r .status <<<"$out")" = "error" ] || fail "pr_list error status (got: $out)"
echo "PASS: pr_list source error — gh pr list failure"

# --- pr_list: a literal control byte in a title/body still parses ------------
# temperloop#1981. `gh` can leak a raw control byte out of a user-authored PR
# title or body; jq exits 5 on one, and pre-fix that made the `count` guard
# report the WHOLE source `error` ("unparseable gh pr list output") for as long
# as that single PR stayed open — a degrade-instead-of-recover bug that left
# `unlinked-prs` answering `unknown` on every run for the duration. With the
# read routed through `_board_sanitize_control_chars` the byte is stripped and
# the source recovers: `ok`, with the node AND its closes edge intact. The
# fixture emits 0x01/0x02 LITERALLY (printf '\001'), not as a JSON \u escape —
# an escape is valid JSON and would not reproduce the failure. The body's byte
# sits INSIDE the `Closes #1<0x01>0` line, not merely somewhere in the body:
# `body` is not emitted as a node field, so a byte elsewhere would only prove
# the parse survived — inside the linkage line it additionally proves the
# closes-edge regex matches POST-strip text (round-2 reviewer hardening).
_board_gh() {
  case "$1 $2" in
    "pr list")
      printf '[{"number":7,"title":"ti\001tle","body":"Closes #1\0010\\nbody\\n"}]\n'
      ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
out="$(_sg_read_pr_list "$BOARD")"
[ "$(jq -r .status <<<"$out")" = "ok" ] || fail "pr_list control-byte status not ok (got: $out)"
[ "$(jq -c '[.nodes[].id]' <<<"$out")" = '["PR:7"]' ] || fail "pr_list control-byte node set (got: $out)"
[ "$(jq -r '.nodes[0].title' <<<"$out")" = "title" ] || fail "pr_list control-byte title not stripped (got: $out)"
[ "$(jq -c '[.edges[].to]' <<<"$out")" = '["Issue:10"]' ] || fail "pr_list control-byte closes edge (got: $out)"
echo "PASS: pr_list source ok — a literal control byte in a PR title/body is stripped, not degraded to error"

# --- pr_list: empty-after-jq must report `error` AND return 0 ---------------
# temperloop#1981 round 2. `jq` can exit ZERO with NO OUTPUT on empty or
# whitespace-only input, so a guard keyed only on jq's EXIT STATUS leaves
# `count` empty: `[ "" -eq 0 ]` errors and evaluates false, execution falls
# through to `_sg_source_result ok "" ""`, and that `jq --argjson ""` fails
# hard — a NON-ZERO return, which `_sg_build_snapshot`'s bare `r_pr=$(...)`
# assignment turns into a `set -e` abort of the WHOLE snapshot build (every
# other `_sg_read_*` in state-graph.sh returns 0 on every path). Both cases
# below therefore assert the RETURN CODE and VALID JSON, not just the status
# string: the defect is a non-zero return with EMPTY stdout, against which a
# status-only grep would pass vacuously.
#
# Two routes reach the same hole, hence two cases:
#   1. control-byte-only — `tr -d '\000-\037'` strips the payload to nothing;
#   2. whitespace-only — SPACE is 0x20, OUTSIDE `tr -d '\000-\037'`, so the
#      SPACEs survive sanitizing while the TAB (0x09) is stripped, which is why
#      the payload is still WHITESPACE when it reaches jq rather than empty.
#      (It sanitizes to four spaces — the tab does NOT survive intact.)
_board_gh() {
  case "$1 $2" in
    "pr list") printf '\001\002\003' ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
rc=0
out="$(_sg_read_pr_list "$BOARD")" || rc=$?
[ "$rc" -eq 0 ] || fail "pr_list control-byte-only payload must return 0, not abort the snapshot build (rc=$rc, out: $out)"
jq -e . >/dev/null 2>&1 <<<"$out" || fail "pr_list control-byte-only payload must emit valid JSON (got: $out)"
[ "$(jq -r .status <<<"$out")" = "error" ] || fail "pr_list control-byte-only payload status (got: $out)"
echo "PASS: pr_list source error — a control-byte-only payload sanitizes to empty, reports error, and returns 0"

_board_gh() {
  case "$1 $2" in
    "pr list") printf '  \t  ' ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
rc=0
out="$(_sg_read_pr_list "$BOARD")" || rc=$?
[ "$rc" -eq 0 ] || fail "pr_list whitespace-only payload must return 0, not abort the snapshot build (rc=$rc, out: $out)"
jq -e . >/dev/null 2>&1 <<<"$out" || fail "pr_list whitespace-only payload must emit valid JSON (got: $out)"
[ "$(jq -r .status <<<"$out")" = "error" ] || fail "pr_list whitespace-only payload status (got: $out)"
echo "PASS: pr_list source error — a whitespace-only payload (SPACEs survive sanitizing; the TAB is stripped) reports error and returns 0"

# --- pr_list: the `count` guard needs ARITY and TYPE, not just non-emptiness -
# temperloop#1981 round 3. Round 2's `jq 'length'` guard answered a WEAKER
# question than the guard needs, and three input classes slipped past it into
# the two failure modes above:
#
#   1. MULTI-DOCUMENT (`[] []`) — bare `jq` emits one line PER INPUT DOCUMENT,
#      so `count` is $'0\n0': non-empty, so `[ -z ]` passes; `[ "$count" -eq 0 ]`
#      then errors on a non-integer and evaluates false; the transforms each
#      emit two documents, and `--argjson` rejects them → the ROUND-1 HARD
#      ABORT by a third route.
#   2. NON-ARRAY JSON — `length` is defined on objects (key count), strings
#      (character count) and numbers (absolute value), so each passes a guard
#      that only proves "parses, length non-zero". The fixture is an OBJECT
#      WHOSE VALUES ARE PR-SHAPED, deliberately: `.[]` iterates an object's
#      VALUES, so unlike `"abc"` or `5` it does NOT fail the projection — it
#      projects cleanly into a FABRICATED PR node and a fabricated closes edge,
#      which round 2 would have reported `ok`. That makes this case discriminate
#      the guard's TYPE clause specifically (a length-only guard admits it, and
#      the honest-error transform arms never fire because nothing fails). A
#      plainer `{"a":1}` fixture would NOT discriminate it — the arms would
#      catch that one anyway, leaving the type clause deletable with the suite
#      still green.
#   3. ARRAY OF `number`-BEARING OBJECTS WITH A NON-PR FIELD
#      (`[{"number":1,"title":"t","body":5}]`) — a GENUINE array whose every
#      element passes the element clause added by temperloop#2001, so it clears
#      the whole `count` guard LEGITIMATELY, and still fails the EDGE transform
#      (`5 | split("\n")` exits 5). This is the case no guard tightening
#      closes; it discriminates the honest-`error` transform arms specifically.
#      It REPLACES the pre-#2001 fixture `["a","b"]`, which the element clause
#      now rejects upstream at the guard — that fixture would still have gone
#      green here, but as a guard case wearing a transform-arm case's label,
#      leaving the arms undiscriminated.
#
# All three assert a ZERO return AND valid JSON AND status `error`, for the same
# reason the two cases above do: the failure modes are a non-zero return with
# empty stdout, and a confident `ok` with an empty node set.
_board_gh() {
  case "$1 $2" in
    "pr list") printf '[] []' ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
rc=0
out="$(_sg_read_pr_list "$BOARD")" || rc=$?
[ "$rc" -eq 0 ] || fail "pr_list multi-document payload must return 0, not abort the snapshot build (rc=$rc, out: $out)"
jq -e . >/dev/null 2>&1 <<<"$out" || fail "pr_list multi-document payload must emit valid JSON (got: $out)"
[ "$(jq -r .status <<<"$out")" = "error" ] || fail "pr_list multi-document payload status (got: $out)"
echo "PASS: pr_list source error — a multi-document payload reports error and returns 0"

_board_gh() {
  case "$1 $2" in
    "pr list") printf '{"a":{"number":1,"title":"x","body":"Closes #9\\n"}}' ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
rc=0
out="$(_sg_read_pr_list "$BOARD")" || rc=$?
[ "$rc" -eq 0 ] || fail "pr_list non-array payload must return 0 (rc=$rc, out: $out)"
jq -e . >/dev/null 2>&1 <<<"$out" || fail "pr_list non-array payload must emit valid JSON (got: $out)"
[ "$(jq -r .status <<<"$out")" = "error" ] || fail "pr_list non-array JSON must report error, never a confident ok over FABRICATED nodes (got: $out)"
[ "$(jq -c '.nodes' <<<"$out")" = '[]' ] || fail "pr_list non-array JSON must not fabricate PR nodes (got: $out)"
echo "PASS: pr_list source error — an object whose values are PR-shaped reports error, not a confident ok over fabricated nodes"

_board_gh() {
  case "$1 $2" in
    "pr list") printf '[{"number":1,"title":"t","body":5}]' ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
rc=0
out="$(_sg_read_pr_list "$BOARD")" || rc=$?
[ "$rc" -eq 0 ] || fail "pr_list transform-arm payload must return 0 (rc=$rc, out: $out)"
jq -e . >/dev/null 2>&1 <<<"$out" || fail "pr_list transform-arm payload must emit valid JSON (got: $out)"
[ "$(jq -r .status <<<"$out")" = "error" ] || fail "pr_list array whose elements clear the count guard but fail a transform must report error, never a confident ok with an empty node set (got: $out)"
[ "$(jq -c '.nodes' <<<"$out")" = '[]' ] || fail "pr_list transform-arm error must carry no nodes (got: $out)"
echo "PASS: pr_list source error — an array that clears the count guard but fails the edge transform reports error, not a wrong-empty ok"

# --- pr_list: the `count` guard needs an ELEMENT test, not just arity+type --
# temperloop#2001, the residual round 3 left open. The arity/type guard admits
# a genuine single top-level array, and `.number` does NOT error on `null` or
# on an object with no `number` key — and `null | tostring` is the string
# "null". So each of the three payloads below projected CLEANLY pre-fix: both
# transforms exited 0 with non-empty output, every guard passed, and the source
# reported `ok` over a FABRICATED `{"id":"PR:null","number":null}` node that
# `_sg_query_unlinked_prs` then emitted as a confident finding. This is the
# invent-data twin of the wrong-empty class above, and the assertions are
# shaped for it: status `error` AND an EMPTY node set, since a status-only
# check would pass over a fabricated node had the guard merely been reordered.
#
#   a. `[null]`                       — a null element; `.number` yields null.
#   b. `[{"a":1}]`                    — an object with no `number` key; same.
#   c. `[{"number":1},{"number":"x"}]` — MIXED: one well-formed element and one
#      whose `number` is a string. Partially projecting it would be worse than
#      either pure case, because a HALF-read page reported `ok` looks exactly
#      like a fully-read one downstream. `all` is all-or-nothing by
#      construction, so the whole source reports `error`.
for _sg_t2001 in '[null]' '[{"a":1}]' '[{"number":1},{"number":"x"}]'; do
  # shellcheck disable=SC2317  # invoked indirectly, through _sg_read_pr_list
  _board_gh() {
    case "$1 $2" in
      "pr list") printf '%s' "$_sg_t2001" ;;
      *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
    esac
  }
  rc=0
  out="$(_sg_read_pr_list "$BOARD")" || rc=$?
  [ "$rc" -eq 0 ] || fail "pr_list malformed-element payload $_sg_t2001 must return 0 (rc=$rc, out: $out)"
  jq -e . >/dev/null 2>&1 <<<"$out" || fail "pr_list malformed-element payload $_sg_t2001 must emit valid JSON (got: $out)"
  [ "$(jq -r .status <<<"$out")" = "error" ] || fail "pr_list array whose elements lack a numeric number must report error, never a confident ok ($_sg_t2001 -> $out)"
  [ "$(jq -c '.nodes' <<<"$out")" = '[]' ] || fail "pr_list must not fabricate a PR:null node ($_sg_t2001 -> $out)"
done
echo "PASS: pr_list source error — an array whose elements lack a numeric number (incl. a mixed array) reports error, not a fabricated PR:null node"

# --- pr_list: the element clause must not break the empty or ok cases -------
# `all` over `[]` is `true`, so an EMPTY array still counts 0 and still reports
# `absent` — the element clause must not turn a legitimately empty PR list into
# an error. Re-asserted HERE, next to the clause it constrains, rather than
# relying on the `absent` case far above staying put.
_board_gh() {
  case "$1 $2" in
    "pr list") printf '[]' ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
out="$(_sg_read_pr_list "$BOARD")"
[ "$(jq -r .status <<<"$out")" = "absent" ] || fail "pr_list empty array must still report absent under the element clause (got: $out)"
echo "PASS: pr_list source absent — an empty array still counts 0 under the element clause"

_board_gh() {
  case "$1 $2" in
    "pr list") printf '[{"number":3,"title":"t3","body":"Closes #30\\n"},{"number":4,"title":"t4","body":"no linkage\\n"}]' ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
out="$(_sg_read_pr_list "$BOARD")"
[ "$(jq -r .status <<<"$out")" = "ok" ] || fail "pr_list well-formed multi-element payload must still report ok (got: $out)"
[ "$(jq -c '[.nodes[].id]' <<<"$out")" = '["PR:3","PR:4"]' ] || fail "pr_list well-formed payload nodes intact (got: $out)"
[ "$(jq -c '[.edges[] | [.from,.to]]' <<<"$out")" = '[["PR:3","Issue:30"]]' ] || fail "pr_list well-formed payload closes edges intact (got: $out)"
echo "PASS: pr_list source ok — a well-formed multi-element payload still projects its nodes and closes edges intact"

# =============================================================================
# source: worktrees (Worktree nodes)
# =============================================================================

# --- worktrees: ok (a linked <repo>.wt/<slug> worktree) ---------------------
_sg_git() {
  cat <<'EOT'
worktree /home/x/dev/batch/foundation
HEAD abc
branch main

worktree /home/x/dev/batch/foundation.wt/slug1
HEAD def
branch feat/slug1
EOT
}
out="$(_sg_read_worktrees "$BOARD")"
[ "$(jq -r .status <<<"$out")" = "ok" ] || fail "worktrees ok status (got: $out)"
[ "$(jq -r '.nodes[0].path' <<<"$out")" = "/home/x/dev/batch/foundation.wt/slug1" ] || fail "worktrees ok node (got: $out)"
echo "PASS: worktrees source ok — a linked <repo>.wt/<slug> worktree"

# --- worktrees: absent (main checkout only, no linked worktrees) -----------
_sg_git() { echo "worktree /home/x/dev/batch/foundation"; }
out="$(_sg_read_worktrees "$BOARD")"
[ "$(jq -r .status <<<"$out")" = "absent" ] || fail "worktrees absent status (got: $out)"
echo "PASS: worktrees source absent — no linked worktrees"

# --- worktrees: error (git itself fails) ------------------------------------
_sg_git() { return 9; }
out="$(_sg_read_worktrees "$BOARD")"
[ "$(jq -r .status <<<"$out")" = "error" ] || fail "worktrees error status (got: $out)"
echo "PASS: worktrees source error — git worktree list failure"

# =============================================================================
# stale: a read-time transform marks EVERY source stale (ADR 0033)
# =============================================================================
fresh_cache stale
_board_gh() {
  case "$1 $2" in
    "issue list") echo '[{"number":20,"title":"x","labels":[{"name":"fnd:status:ready"}]}]' ;;
    "api repos/$REPO/issues/20/sub_issues") echo '[]' ;;
    "api repos/$REPO/issues/20/dependencies/blocked_by") echo '[]' ;;
    "pr list") echo '[]' ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
_sg_git() { echo "worktree /home/x/dev/batch/foundation"; }

fresh="$(_sg_build_snapshot "$BOARD")"
_sg_persist_snapshot "$BOARD" "$fresh" "state-graph" || fail "persist for stale test failed"
# A just-built snapshot is fresh: none of the four sources report stale.
read_now="$(_sg_read_snapshot "$BOARD" state-graph)"
[ "$(jq -r '[.sources[].status] | index("stale")' <<<"$read_now")" = "null" ] \
  || fail "a fresh snapshot must not read stale (got: $read_now)"
echo "PASS: a fresh snapshot's read carries each source's real build-time status"

# Age the meta.json past STATE_GRAPH_MAX_AGE_S and re-read.
meta="$(cache_meta_file "$BOARD" state-graph)"
old_ts=$(( $(date +%s) - STATE_GRAPH_MAX_AGE_S - 10 ))
jq -c --argjson ts "$old_ts" '.last_refresh=$ts' "$meta" >"$meta.tmp" && mv "$meta.tmp" "$meta"
stale_read="$(_sg_read_snapshot "$BOARD" state-graph)"
for src in board board_edges pr_list worktrees; do
  [ "$(jq -r --arg s "$src" '.sources[$s].status' <<<"$stale_read")" = "stale" ] \
    || fail "source $src did not read stale past STATE_GRAPH_MAX_AGE_S (got: $stale_read)"
done
echo "PASS: board source stale — a read past STATE_GRAPH_MAX_AGE_S"
echo "PASS: board_edges source stale — a read past STATE_GRAPH_MAX_AGE_S"
echo "PASS: pr_list source stale — a read past STATE_GRAPH_MAX_AGE_S"
echo "PASS: worktrees source stale — a read past STATE_GRAPH_MAX_AGE_S"

# =============================================================================
# the snapshot goes through lib/cache.sh (repo-keyed dir, meta.json, atomic)
# =============================================================================
fresh_cache cache-integration
_board_gh() {
  case "$1 $2" in
    "issue list") echo '[]' ;;
    "pr list") echo '[]' ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
_sg_git() { echo "worktree /home/x/dev/batch/foundation"; }
built="$(cmd_build --board "$BOARD")"

expect_dir="$(cache_repo_dir "$BOARD" state-graph)"
expect_snap="$(cache_snapshot_file "$BOARD" state-graph)"
expect_meta="$(cache_meta_file "$BOARD" state-graph)"
[ -d "$expect_dir" ] || fail "cache.sh's own cache_repo_dir path was not created"
[ -s "$expect_snap" ] || fail "cache.sh's own cache_snapshot_file path was not written"
[ -s "$expect_meta" ] || fail "cache.sh's own cache_meta_file path was not written"
[ "$(cat "$expect_snap")" = "$built" ] || fail "on-disk snapshot does not match cmd_build's stdout"
[ "$(jq -r '.schema_version' "$expect_meta")" = "1" ] || fail "meta.json missing schema_version"
[ "$(jq -r '.repo' "$expect_meta")" = "$REPO" ] || fail "meta.json repo mismatch"
# cache_dirty (kind=state-graph) must invalidate ONLY this kind's freshness,
# never touch the sibling "issues" kind cache.sh already owns.
cache_dirty "$BOARD" state-graph
[ "$(jq -r '.last_refresh' "$expect_meta")" = "0" ] || fail "cache_dirty did not zero last_refresh"
echo "PASS: the snapshot is written and invalidated through lib/cache.sh (kind=state-graph)"

# =============================================================================
# clean --board N removes ONE repo's snapshot only
# =============================================================================
fresh_cache clean
_board_gh() {
  case "$1 $2" in
    "issue list") echo '[]' ;;
    "pr list") echo '[]' ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
_sg_git() { echo "worktree /home/x/dev/batch/foundation"; }
cmd_build --board 4 >/dev/null
cmd_build --board 3 >/dev/null
dir4="$(cache_repo_dir 4 state-graph)"
dir3="$(cache_repo_dir 3 state-graph)"
[ -d "$dir4" ] && [ -d "$dir3" ] || fail "setup: both boards' snapshots should exist before clean"
cmd_clean --board 4
[ ! -d "$dir4" ] || fail "clean --board 4 left board 4's snapshot behind"
[ -d "$dir3" ] || fail "clean --board 4 removed board 3's snapshot too"
echo "PASS: clean --board N removes only that one repo's snapshot"

# =============================================================================
# bench --scale N: a synthetic N-scaled snapshot, timed
# =============================================================================
fresh_cache bench
_board_gh() {
  case "$1 $2" in
    "issue list") echo '[{"number":1,"title":"x","labels":[{"name":"fnd:status:ready"}]}]' ;;
    "api repos/$REPO/issues/1/sub_issues") echo '[]' ;;
    "api repos/$REPO/issues/1/dependencies/blocked_by") echo '[]' ;;
    "pr list") echo '[]' ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
_sg_git() { echo "worktree /home/x/dev/batch/foundation"; }
bench_out="$(cmd_bench --scale 5 --board "$BOARD")"
echo "$bench_out" | grep 'scale=5' >/dev/null || fail "bench did not report the requested scale (got: $bench_out)"
echo "$bench_out" | grep -E 'nodes=5( |$)' >/dev/null || fail "bench did not scale node count 5x the 1-node base (got: $bench_out)"
echo "$bench_out" | grep -E 'build_ms=[0-9]+' >/dev/null || fail "bench did not print a build_ms figure (got: $bench_out)"
echo "PASS: bench --scale N generates a synthetic N-scaled snapshot and prints build time"

# =============================================================================
# the reader table is extensible (state-graph-build-local, temperloop#1918,
# added plan_notes/journal/tmux, and temperloop#1980 round 3 added
# transcripts, without touching these four core sources — see
# test_state_graph_local.sh for their own ok/absent/error/stale coverage)
# =============================================================================
[ "$_SG_SOURCES" = "board board_edges pr_list worktrees plan_notes journal tmux transcripts" ] \
  || fail "reader table drifted from the eight known sources (got: $_SG_SOURCES)"
echo "PASS: the reader table names exactly the eight known sources and nothing else"

echo "ALL PASS: test_state_graph.sh"
