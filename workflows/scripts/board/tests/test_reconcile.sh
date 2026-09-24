#!/usr/bin/env bash
#
# Fixture-replay tests for scripts/reconcile.sh. Zero network, zero real tmux:
# we SOURCE reconcile.sh (its execute-guard suppresses the auto-run when sourced)
# and then override its two seams —
#   - board reads:  board.sh's `_board_gh` (the same seam test_board_replay uses)
#   - tmux reads:   reconcile.sh's `_reconcile_tmux`
# — to inject canned board item-lists and canned @claimed_issue marker lines.
# Each case drives reconcile_main / status_reconcile_main and asserts the
# human-readable report contains (or omits) the expected drift lines. The status
# lens also reads canned `issue list` / `pr list` and records `project item-edit`
# writes through the same _board_gh seam.
#
# Covered — Lens 1 (marker drift):
#   1) marker-without-board  — local marker for an issue the board does not have
#      In Progress for this host.
#   2) board-without-marker  — board In Progress for this host, no live marker.
#   3) in sync               — every marker matches a board claim and vice versa.
# Covered — Lens 1 repair (--fix), including the temperloop#1037 widening:
#   1)-7)  the pre-#1037 single-window gates, now expressed per window.
#   8)     EVERY window's stale terminal marker clears in one sweep (the #1037
#          repro: one closed issue branding four windows for over a month).
#   9)     the gate still discriminates per window — a CLOSED marker clears while
#          an OPEN one in another window survives the SAME sweep.
#   10)    a peer session's LIVE same-host claim in another window is refused
#          (GH #297's wrongful-clear class is not reintroduced).
#   11)    the sweep reads and repairs the tmux server from OUTSIDE tmux — what
#          makes the /tidy nightly's repair automatic rather than hand-run.
#   12)13) the cross-board number-collision guard: a number that is a live
#          same-host claim on ANOTHER registered board is never cleared, with a
#          negative control proving the refusal comes from the guard.
# Covered — Lens 2 (status drift):
#   1) terminal-but-not-Done — closed/merged backing, flagged; --fix moves to Done.
#   2) orphaned In-Progress + unresolved — reported, never auto-fixed.
#   3) in sync               — every item's status matches its GitHub state.
#   4) stale claim (GH #85)  — same-host stamp, DEAD session → flagged, never
#      auto-fixed; a same-host LIVE claim is NOT flagged.
#   5) foreign claim         — stamped to another host → reported, never released
#      from here (no liveness call; foreign wins even if told the session is dead).
#   6) terminal beats stale  — a closed-backed In-Progress dead-stamp item is
#      classed terminal, not stale (jq branch priority).
# The session-liveness oracle (_reconcile_session_live) is the THIRD seam these
# tests override — data-driven by DEAD_SESSIONS, zero filesystem dependence.
#
# FIX is read by status_reconcile_main in the sourced reconcile.sh, not in this
# file — shellcheck can't see that cross-file use, so silence SC2034 file-wide
# (the directive must precede the first command). CI excludes tests/ anyway.
# shellcheck disable=SC2034
set -euo pipefail

# Hermetic conf env (temperloop#501): fixture tests must never resolve boards
# through the repo's or host's real boards.conf — a consumer's committed
# cutover flip (e.g. stageFind's board.3.backend=issues) or a driver host's
# machine-level conf would silently change canned-fixture resolution.
export BOARDS_CONF_REPO_LOCAL=/dev/null
export BOARDS_CONF_MACHINE=/dev/null


HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$HERE/.." && pwd)"

# Pin the host so the test is deterministic regardless of the runner's hostname.
export SUBSET_HOST_LABEL="testhost"
# Pretend we are inside tmux so reconcile reads markers (the value is unused —
# _reconcile_tmux is fully overridden below).
export TMUX="fake-socket,0,0"
# A pane id makes lib/claim_marker.sh's `_claim_marker_targetable` true, so the
# --fix marker-repair cases (temperloop#748) exercise the REAL claim_marker_peek /
# claim_marker_clear — their tmux calls are redirected to a file-backed stub below,
# so no real tmux server is ever contacted.
export TMUX_PANE="%0"
# Never let a runner that happens to be inside cmux pull the repair down the cmux
# branch — the marker-repair cases are tmux-shaped and must stay hermetic.
unset CMUX_WORKSPACE_ID
# Scratch dir for this run's stubs. (Formerly BOARD_CACHE_DIR, isolating the
# on-disk board cache from other runs — that cache was removed with the
# Projects-v2 arm, ADR 0004, so this is now just a work dir.)
TEST_WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/reconcile-test-XXXXXX")"
trap 'rm -rf "$TEST_WORK_DIR"' EXIT

# shellcheck source=scripts/reconcile.sh
# shellcheck disable=SC1091
source "$SCRIPTS_DIR/reconcile.sh"

fail() { printf 'FAIL: %b\n' "$1" >&2; exit 1; }

# board.sh sets BOARD_OWNER etc.; reconcile_main / status_reconcile_main call
# board_resolve which fans out to _board_gh for project view / field-list /
# item-list. The status lens additionally reads `issue list` / `pr list` and (on
# --fix) writes `project item-edit`. The field-list carries In Progress + Ready +
# Done options so board_set_status can resolve "Done" on the --fix path (the
# marker lens reads no options, so the extra ones are harmless to it).
FIELD_LIST_JSON='{"fields":[{"id":"PVTSSF_status","name":"Status","type":"ProjectV2SingleSelectField","options":[{"id":"opt_inprogress","name":"In Progress"},{"id":"opt_ready","name":"Ready"},{"id":"opt_done","name":"Done"}]},{"id":"PVTF_hostsession","name":"Host/Session","type":"ProjectV2Field"}]}'

# Set per-case before run_case (marker lens) / run_status (status lens).
ITEM_LIST_JSON=""
MARKER_LINES=""
ISSUE_LIST_JSON="[]"   # status lens: [{"number":N,"state":"OPEN|CLOSED"}]
PR_LIST_JSON="[]"      # status lens: [{"number":N,"state":"OPEN|CLOSED|MERGED"}]
EDITS="/dev/null"      # status lens: run_status repoints this to a temp file
# Marker-repair (--fix, temperloop#748) terminality oracle fixtures: the single-item
# `issue view` / `pr view` reads _reconcile_issue_state makes. Empty = "gh printed
# nothing" (the not-found / unreadable case), which must fail safe to NO repair.
ISSUE_VIEW_JSON=""     # e.g. '{"state":"CLOSED"}'
PR_VIEW_JSON=""        # e.g. '{"state":"MERGED"}'
# Per-issue override for the multi-window cases (temperloop#1037), where one
# sweep must resolve DIFFERENT states for different markers: newline-separated
# "<n><TAB><STATE>" rows. A number listed here wins over ISSUE_VIEW_JSON; a
# number absent falls back to it, so every pre-#1037 case is unaffected.
ISSUE_STATE_MAP=""
# Item list replayed for every registered board OTHER than the swept one (board 3
# / stageFind), for the cross-board live-claim guard. Empty = "no other board has
# any In-Progress item", i.e. the pre-temperloop#1037 world.
OTHER_BOARD_ITEMS_JSON='{"items":[]}'
# Stubbed session-liveness oracle (GH #85): treat every session as LIVE except
# those listed here (space-separated session ids). Default empty → all live, so
# the pre-existing scases (whose stamped items are all "ok/live") pass unchanged;
# a stale-claim case sets it to mark a specific session dead. This fully replaces
# the real _reconcile_session_live (no filesystem / transcript dependence).
DEAD_SESSIONS=""

# Override the board seam: replay canned JSON for every read, and RECORD each
# item-edit's --id (the only write, issued by the --fix path) to $EDITS.
# ITEM_LIST_JSON stays authored in the readable board-item shape every case
# below already uses ({id, content:{number,title}, status, "host/Session"}).
# On the issues-only backend (ADR 0004) the whole-board read is a `gh issue
# list`, so this converts that fixture into the RAW issues-list payload gh
# would return — letting board.sh's own issue_item reshape run for real rather
# than hand-authoring `fnd:` labels in 20 fixtures. Two faithful details:
#   - a "Done" item is a CLOSED issue, so it is omitted from the `--state open`
#     read exactly as the former `-status:Done` Projects query omitted it (its
#     closed-ness still reaches the status lens via ISSUE_LIST_JSON);
#   - a Host/Session stamp becomes the verbatim fnd:host/session:<stamp> label.
_reconcile_board_items_as_issues() {
  printf '%s' "$ITEM_LIST_JSON" | jq -c '
    def slug: ascii_downcase | gsub(" "; "-");
    [ .items[]
      | select((.status // "") != "Done")
      | { number: .content.number,
          title: (.content.title // ""),
          milestone: null,
          labels: (
            (if (.status // "") != "" then [{name: ("fnd:status:" + (.status | slug))}] else [] end)
            + (if (.["host/Session"] // "") != "" then [{name: ("fnd:host/session:" + .["host/Session"])}] else [] end)
          ) } ]'
}

_board_gh() {
  case "$1 $2" in
    "issue list")
      # Two distinct reads share this verb: board.sh's whole-board read
      # (--state open, requesting title/labels/milestone) and the status lens's
      # own state read (--state all). Route by argv so each gets its fixture.
      case "$*" in
        # The cross-board guard (temperloop#1037) reads EVERY registered board's
        # item list, so the whole-board read has to be repo-aware or every board
        # would replay board 3's fixture and the guard could not be tested. Any
        # repo other than the swept board's replays OTHER_BOARD_ITEMS_JSON, which
        # defaults to empty — leaving every pre-#1037 case unaffected.
        *"--state open"*labels*)
          case "$*" in
            *"/stageFind"*) _reconcile_board_items_as_issues ;;
            *)              ITEM_LIST_JSON="$OTHER_BOARD_ITEMS_JSON" _reconcile_board_items_as_issues ;;
          esac ;;
        *)                       printf '%s' "$ISSUE_LIST_JSON" ;;
      esac ;;
    "pr list")            printf '%s' "$PR_LIST_JSON" ;;
    "issue view")
      # $3 is the issue number (`issue view <n> -R … --json state`).
      local sv; sv="$(printf '%s\n' "$ISSUE_STATE_MAP" | awk -F'\t' -v n="$3" '$1==n {print $2; exit}')"
      if [ -n "$sv" ]; then printf '{"state":"%s"}' "$sv"; else printf '%s' "$ISSUE_VIEW_JSON"; fi ;;
    "pr view")            printf '%s' "$PR_VIEW_JSON" ;;
    "api "*)
      # The single-issue read the issues-only writers do before every write.
      local n="${2##*/}"
      printf '{"number":%s,"title":"","state":"open","labels":[]}' "$n" ;;
    "label create") return 0 ;;
    "issue edit" | "issue close" | "issue reopen")
      # Record ONE line per issue touched by a write, so the per-item presence/
      # absence assertions below keep their shape (a Done move is a label strip
      # plus a close — one logical edit, one record).
      local n="$3"
      grep -qx "ISSUE_$n" "$EDITS" 2>/dev/null || printf 'ISSUE_%s\n' "$n" >>"$EDITS"
      return 0 ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}

# Override the tmux seam: emit canned "<window_id>\t<@claimed_issue>" rows, the
# way `tmux list-windows -a -F '#{window_id}\t#{@claimed_issue}'` would (rows for
# windows with no marker are included to mirror reality — reconcile drops them).
_reconcile_tmux() {
  printf '%s' "$MARKER_LINES"
}

# Run reconcile_main with the current ITEM_LIST_JSON / MARKER_LINES and capture
# its stdout into $OUT.
run_case() {
  OUT="$(reconcile_main)"
}

# --- case 1: marker-without-board ---------------------------------------------
# Board: #500 In Progress on a DIFFERENT host; #501 only Ready. Local marker for
# #500 → stale (wrong host); local marker for #777 → stale (not on board at all).
ITEM_LIST_JSON='{"items":[
  {"id":"ISSUE_500","content":{"number":500,"title":"Claimed elsewhere"},"status":"In Progress","host/Session":"otherhost:dead1234"},
  {"id":"ISSUE_501","content":{"number":501,"title":"Just ready"},"status":"Ready"}
]}'
MARKER_LINES='@0	#500 Claimed elsewhere
@1	#777 phantom local claim
@2	
'
run_case
grep -q "marker-without-board" <<<"$OUT" \
  || fail "case1: expected a marker-without-board section\n$OUT"
grep -q "#500 — In Progress on the board but stamped to 'otherhost'" <<<"$OUT" \
  || fail "case1: expected #500 wrong-host drift line\n$OUT"
grep -q "#777 — marker set locally, but #777 is NOT In Progress" <<<"$OUT" \
  || fail "case1: expected #777 not-on-board drift line\n$OUT"
grep -q "In sync" <<<"$OUT" \
  && fail "case1: must NOT report in-sync when drift exists\n$OUT"
# Nothing on this host claimed → no board-without-marker section.
grep -q "board-without-marker" <<<"$OUT" \
  && fail "case1: unexpected board-without-marker section\n$OUT"
echo "PASS: case 1 marker-without-board (wrong host + not-on-board) reported"

# --- case 2: board-without-marker ---------------------------------------------
# Board: #600 In Progress stamped to THIS host (testhost), but NO live marker.
ITEM_LIST_JSON='{"items":[
  {"id":"ISSUE_600","content":{"number":600,"title":"Claimed here, parked"},"status":"In Progress","host/Session":"testhost:abcd1234"}
]}'
MARKER_LINES=''   # no live markers at all (e.g. after release.sh)
run_case
grep -q "board-without-marker" <<<"$OUT" \
  || fail "case2: expected a board-without-marker section\n$OUT"
grep -q "#600 — In Progress on the board (this host) but NO live tmux marker — Claimed here, parked" <<<"$OUT" \
  || fail "case2: expected #600 board-without-marker line with title\n$OUT"
grep -q "marker-without-board" <<<"$OUT" \
  && fail "case2: unexpected marker-without-board section\n$OUT"
grep -q "In sync" <<<"$OUT" \
  && fail "case2: must NOT report in-sync when drift exists\n$OUT"
echo "PASS: case 2 board-without-marker (claimed here, no live marker) reported"

# --- case 3: fully in sync ----------------------------------------------------
# Board: #700 In Progress on THIS host; a live marker for #700 holds it. Also an
# item on another host (#701) with no local marker — correctly NOT flagged since
# it is not this host's claim. Result: no drift in either direction.
ITEM_LIST_JSON='{"items":[
  {"id":"ISSUE_700","content":{"number":700,"title":"Working it now"},"status":"In Progress","host/Session":"testhost:beef5678"},
  {"id":"ISSUE_701","content":{"number":701,"title":"Someone else"},"status":"In Progress","host/Session":"otherhost:cafe9999"}
]}'
MARKER_LINES='@0	#700 Working it now
'
run_case
grep -q "In sync" <<<"$OUT" \
  || fail "case3: expected an in-sync all-clear\n$OUT"
grep -q "marker-without-board" <<<"$OUT" \
  && fail "case3: unexpected marker-without-board section\n$OUT"
grep -q "board-without-marker" <<<"$OUT" \
  && fail "case3: unexpected board-without-marker section\n$OUT"
echo "PASS: case 3 fully in-sync all-clear (other host's claim not mis-flagged)"

echo
echo "=== Lens 1 repair: --fix marker repair (temperloop#748) ==="

# The repair clears markers through the REAL lib/claim_marker.sh primitive
# release.sh uses underneath (claim_marker_clear_window) — so rather than stubbing
# those functions (which would prove nothing about reuse), we stub the ONE tmux
# seam beneath them, `_claim_marker_tmux`, with a file-backed fake PER-WINDOW
# option store. File-backed, not a shell variable, because reconcile_main runs
# inside a command substitution: a variable mutation there would die with the
# subshell, while a clear recorded to a file is observable from the test.
#
# Per-WINDOW (temperloop#1037): the repair now sweeps every window on the server,
# so the stub has to distinguish targets — a single-window store could not tell a
# correct two-window sweep from a bug that clears the same window twice.
MARKER_STUB_DIR="$TEST_WORK_DIR/marker-stub"
mkdir -p "$MARKER_STUB_DIR"
MARKER_CLEARS_FILE="$MARKER_STUB_DIR/clears"
: >"$MARKER_CLEARS_FILE"

# Store path for a window id ("@0" -> "$MARKER_STUB_DIR/win_0").
_stub_win_file() { printf '%s/win_%s' "$MARKER_STUB_DIR" "$(printf '%s' "$1" | tr -c 'A-Za-z0-9' '_')"; }

_claim_marker_tmux() {
  local verb="${1:-}"; shift || true
  local target="" unset_form=0 optname="" f
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -t)  target="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
      -wu) unset_form=1; shift ;;
      -w|-wqv) shift ;;
      *)   optname="$1"; shift ;;
    esac
  done
  f="$(_stub_win_file "$target")"
  case "$verb" in
    show-options) [ -f "$f" ] && cat "$f" ;;
    set-option)
      # Two unset forms are reachable from the repair path: `-wu @claimed_issue`
      # (the clear) and `-wu automatic-rename` (the restore, temperloop#1037).
      # Each is recorded distinctly so a test can assert BOTH happened, and to
      # the same window. Prints nothing (stdout would land in the report).
      if [ "$unset_form" = 1 ]; then
        case "$optname" in
          @claimed_issue)
            printf 'cleared:%s:%s\n' "$target" "$(cat "$f" 2>/dev/null)" >>"$MARKER_CLEARS_FILE"
            : >"$f" ;;
          automatic-rename)
            printf 'autorename:%s\n' "$target" >>"$MARKER_CLEARS_FILE" ;;
        esac
      fi ;;
  esac
  return 0
}

# Per-case fixture reset. Each argument is one "<window_id> <marker display>"
# pair; it seeds that window's option store AND the `list-windows` fixture the
# sweep reads, so the two can never disagree. Prior clears are forgotten.
seed_windows() {
  rm -f "$MARKER_STUB_DIR"/win_* 2>/dev/null || true
  : >"$MARKER_CLEARS_FILE"
  MARKER_LINES=""
  local pair win marker
  for pair in "$@"; do
    win="${pair%% *}"; marker="${pair#* }"
    printf '%s' "$marker" >"$(_stub_win_file "$win")"
    MARKER_LINES+="$win"$'\t'"$marker"$'\n'
  done
}
# Marker currently held by <window_id> in the fake store ("" once cleared).
window_marker() { cat "$(_stub_win_file "$1")" 2>/dev/null || true; }
cleared_count()    { grep -c '^cleared:'    "$MARKER_CLEARS_FILE" 2>/dev/null || true; }
autorename_count() { grep -c '^autorename:' "$MARKER_CLEARS_FILE" 2>/dev/null || true; }

# --- mcase 1: dry-run — no --fix mutates NOTHING ------------------------------
# The exact temperloop#748 repro: this window's marker names #502, which is not
# In Progress on the board and is CLOSED on GitHub — the provably-safe class. With
# FIX=0 it must still only be REPORTED (plus the discoverability hint), never cleared.
ITEM_LIST_JSON='{"items":[
  {"id":"ISSUE_503","content":{"number":503,"title":"Unrelated"},"status":"Ready"}
]}'
ISSUE_VIEW_JSON='{"state":"CLOSED"}'
PR_VIEW_JSON=""
seed_windows '@0 #502 Claim target'
FIX=0
run_case
grep -q "#502 — marker set locally, but #502 is NOT In Progress" <<<"$OUT" \
  || fail "mcase1: expected the #502 stale-marker drift line\n$OUT"
grep -q -- "pass --fix to clear any window's marker" <<<"$OUT" \
  || fail "mcase1: report should point at the repair flag\n$OUT"
grep -q -- "--fix (marker lens)" <<<"$OUT" \
  && fail "mcase1: repair section must not run without --fix\n$OUT"
[ "$(cleared_count)" = "0" ] || fail "mcase1: dry run must clear nothing (got $(cleared_count))"
[ "$(autorename_count)" = "0" ] || fail "mcase1: dry run must not touch automatic-rename (got $(autorename_count))"
[ "$(window_marker @0)" = '#502 Claim target' ] \
  || fail "mcase1: dry run must leave the marker intact (got '$(window_marker @0)')"
echo "PASS: marker case 1 report-only without --fix (mutates nothing)"

# --- mcase 2: safe clear — stale marker naming a CLOSED issue -----------------
# Same fixture, FIX=1: both gates pass (marker-without-board drift + provably
# terminal), so claim_marker_clear fires exactly once and the marker is gone.
seed_windows '@0 #502 Claim target'
FIX=1
run_case
grep -q -- "--fix (marker lens)" <<<"$OUT" \
  || fail "mcase2: expected the repair section\n$OUT"
grep -q "✓ cleared \[#502 Claim target\] in window @0 — #502 is CLOSED" <<<"$OUT" \
  || fail "mcase2: expected #502 to be cleared as CLOSED\n$OUT"
[ "$(cleared_count)" = "1" ] || fail "mcase2: expected exactly one clear (got $(cleared_count))\n$OUT"
[ -z "$(window_marker @0)" ] \
  || fail "mcase2: marker should be gone (got '$(window_marker @0)')"
# temperloop#1037: the same clear must restore that window's automatic-rename,
# or the window name stays frozen at the claim string forever.
grep -qx 'autorename:@0' "$MARKER_CLEARS_FILE" \
  || fail "mcase2: the clear must also unset automatic-rename on @0\n$(cat "$MARKER_CLEARS_FILE")"
FIX=0
echo "PASS: marker case 2 safe clear fires for a CLOSED-issue stale marker (+ automatic-rename restored)"

# --- mcase 3: PR fallback — a MERGED PR number is terminal too ----------------
# `gh issue view` finds nothing (empty payload); the pr-view fallback reports
# MERGED, which is equally terminal.
ITEM_LIST_JSON='{"items":[]}'
ISSUE_VIEW_JSON=""
PR_VIEW_JSON='{"state":"MERGED"}'
seed_windows '@0 #740 Merged PR'
FIX=1
run_case
grep -q "✓ cleared \[#740 Merged PR\] in window @0 — #740 is MERGED" <<<"$OUT" \
  || fail "mcase3: expected the pr-view fallback to prove #740 MERGED\n$OUT"
[ "$(cleared_count)" = "1" ] || fail "mcase3: expected exactly one clear (got $(cleared_count))\n$OUT"
FIX=0
echo "PASS: marker case 3 MERGED PR resolves terminal via the pr-view fallback"

# --- mcase 4: UNSAFE — stale marker whose issue is still OPEN ------------------
# marker-without-board drift, but #800 is OPEN: the work may be live, so it is
# reported and NEVER cleared.
ITEM_LIST_JSON='{"items":[]}'
ISSUE_VIEW_JSON='{"state":"OPEN"}'
PR_VIEW_JSON=""
seed_windows '@0 #800 Still open'
FIX=1
run_case
grep -q "#800 (window @0) — NOT repaired" <<<"$OUT" \
  || fail "mcase4: an OPEN issue's marker must be refused\n$OUT"
grep -q "not provably terminal (state 'OPEN')" <<<"$OUT" \
  || fail "mcase4: refusal should name the non-terminal state\n$OUT"
grep -q "✓ cleared" <<<"$OUT" && fail "mcase4: nothing may be cleared\n$OUT"
[ "$(cleared_count)" = "0" ] || fail "mcase4: OPEN issue must not be cleared (got $(cleared_count))"
[ "$(autorename_count)" = "0" ] || fail "mcase4: a refusal must not touch automatic-rename (got $(autorename_count))"
[ "$(window_marker @0)" = '#800 Still open' ] \
  || fail "mcase4: the marker must survive untouched"
FIX=0
echo "PASS: marker case 4 no clear for an OPEN-issue marker"

# --- mcase 5: UNSAFE — unreadable state fails safe ----------------------------
# Neither view returns anything (not found / auth error). "Not provably terminal"
# → no repair. A read failure can only ever make the repair do LESS.
ITEM_LIST_JSON='{"items":[]}'
ISSUE_VIEW_JSON=""
PR_VIEW_JSON=""
seed_windows '@0 #999 Unknown to GitHub'
FIX=1
run_case
grep -q "not provably terminal (state 'unknown')" <<<"$OUT" \
  || fail "mcase5: an unreadable state must fail safe to no repair\n$OUT"
[ "$(cleared_count)" = "0" ] || fail "mcase5: unreadable state must clear nothing (got $(cleared_count))"
FIX=0
echo "PASS: marker case 5 unreadable GitHub state fails safe (no clear)"

# --- mcase 6: UNSAFE — the whole board-without-marker class is never repaired --
# #600 is In Progress on the board for THIS host with no live marker anywhere —
# the class temperloop#719 proved produces FALSE stranded-claim signals. Even with
# --fix, nothing is cleared and (above all) nothing is re-stamped: with no marker
# in this window there is nothing for the repair to act on at all.
ITEM_LIST_JSON='{"items":[
  {"id":"ISSUE_600","content":{"number":600,"title":"Claimed here, marker clobbered"},"status":"In Progress","host/Session":"testhost:e4e906b5"}
]}'
ISSUE_VIEW_JSON='{"state":"CLOSED"}'   # even a terminal answer must not license a repair here
PR_VIEW_JSON=""
seed_windows          # no window on the server holds a marker at all
FIX=1
run_case
grep -q "board-without-marker (claimed on board, no local marker — REPORT-ONLY, never repaired)" <<<"$OUT" \
  || fail "mcase6: expected the board-without-marker section, marked report-only\n$OUT"
grep -q "#600 — In Progress on the board (this host) but NO live tmux marker" <<<"$OUT" \
  || fail "mcase6: #600 should still be reported\n$OUT"
grep -q "nothing to repair: no claim marker is set in any window" <<<"$OUT" \
  || fail "mcase6: repair should no-op with no marker anywhere on the server\n$OUT"
grep -q "✓ cleared" <<<"$OUT" && fail "mcase6: board-without-marker must never be cleared\n$OUT"
[ "$(cleared_count)" = "0" ] || fail "mcase6: board-without-marker must clear nothing (got $(cleared_count))"
[ -z "$(window_marker @0)" ] \
  || fail "mcase6: board-without-marker must never RE-STAMP a marker (got '$(window_marker @0)')"
FIX=0
echo "PASS: marker case 6 board-without-marker never repaired (no clear, no re-stamp)"

# --- mcase 7: UNSAFE — a LIVE same-host board claim is never cleared -----------
# The marker names #700, which IS In Progress on the board stamped to this host: a
# live claim (the K#275 claim-until-Done case). Gate 1 must refuse BEFORE the
# terminality check, so even a CLOSED answer from GitHub cannot license the clear.
ITEM_LIST_JSON='{"items":[
  {"id":"ISSUE_700","content":{"number":700,"title":"Working it now"},"status":"In Progress","host/Session":"testhost:beef5678"}
]}'
ISSUE_VIEW_JSON='{"state":"CLOSED"}'
PR_VIEW_JSON=""
seed_windows '@0 #700 Working it now'
FIX=1
run_case
grep -q "#700 (window @0) — NOT repaired: it is In Progress on the board, stamped to this host" <<<"$OUT" \
  || fail "mcase7: a live same-host claim must be refused by gate 1\n$OUT"
[ "$(cleared_count)" = "0" ] || fail "mcase7: a live claim must not be cleared (got $(cleared_count))"
[ "$(window_marker @0)" = '#700 Working it now' ] \
  || fail "mcase7: the live claim's marker must survive"
FIX=0
echo "PASS: marker case 7 a live same-host claim is refused before the terminality check"

echo
echo "=== Lens 1 repair widened to every window (temperloop#1037) ==="

# --- mcase 8: the #1037 repro — a stale marker in EVERY window is cleared ------
# The live defect: one closed issue's marker branded four windows and survived
# for over a month, because the pre-#1037 repair only ever reached the window the
# operator happened to run it from. All four must now clear in ONE sweep, and
# each must have its automatic-rename restored.
ITEM_LIST_JSON='{"items":[]}'
ISSUE_VIEW_JSON='{"state":"CLOSED"}'
PR_VIEW_JSON=""
seed_windows '@0 #502 Claim target' '@1 #502 Claim target' \
             '@2 #502 Claim target' '@3 #502 Claim target'
FIX=1
run_case
for w in @0 @1 @2 @3; do
  grep -q "✓ cleared \[#502 Claim target\] in window $w — #502 is CLOSED" <<<"$OUT" \
    || fail "mcase8: window $w was not cleared\n$OUT"
  [ -z "$(window_marker "$w")" ] || fail "mcase8: window $w still holds '$(window_marker "$w")'"
  grep -qx "autorename:$w" "$MARKER_CLEARS_FILE" \
    || fail "mcase8: automatic-rename not restored on $w\n$(cat "$MARKER_CLEARS_FILE")"
done
[ "$(cleared_count)" = "4" ] || fail "mcase8: expected four clears (got $(cleared_count))\n$OUT"
FIX=0
echo "PASS: marker case 8 every window's stale marker is cleared in one sweep (#1037 repro)"

# --- mcase 9: the gate still discriminates PER WINDOW --------------------------
# Widening must not degrade into "clear everything": in the SAME sweep, @0's
# CLOSED issue clears while @1's OPEN issue is refused and survives. This is the
# discriminating case for "never on 'looks stale'" — both markers look equally
# stale locally; only the GitHub proof separates them.
ITEM_LIST_JSON='{"items":[]}'
ISSUE_VIEW_JSON=""
PR_VIEW_JSON=""
ISSUE_STATE_MAP="$(printf '502\tCLOSED\n800\tOPEN\n')"
seed_windows '@0 #502 Claim target' '@1 #800 Still open'
FIX=1
run_case
grep -q "✓ cleared \[#502 Claim target\] in window @0 — #502 is CLOSED" <<<"$OUT" \
  || fail "mcase9: the CLOSED-issue marker in @0 should have cleared\n$OUT"
grep -q "#800 (window @1) — NOT repaired" <<<"$OUT" \
  || fail "mcase9: the OPEN-issue marker in @1 must be refused, naming its window\n$OUT"
[ -z "$(window_marker @0)" ] || fail "mcase9: @0 should be cleared"
[ "$(window_marker @1)" = '#800 Still open' ] || fail "mcase9: @1's OPEN marker must survive"
[ "$(cleared_count)" = "1" ] || fail "mcase9: exactly one clear expected (got $(cleared_count))\n$OUT"
[ "$(autorename_count)" = "1" ] || fail "mcase9: only the cleared window's automatic-rename may be touched"
FIX=0
echo "PASS: marker case 9 an OPEN-issue marker in another window survives the sweep"

# --- mcase 10: a peer session's LIVE claim in another window is never cleared --
# The GH #297 hazard the widening had to not reintroduce: @1 belongs to a
# concurrent session that legitimately holds #700 In Progress on this host. Gate 1
# refuses it even while @0's terminal marker clears in the same pass.
ITEM_LIST_JSON='{"items":[
  {"id":"ISSUE_700","content":{"number":700,"title":"Peer session working it"},"status":"In Progress","host/Session":"testhost:beef5678"}
]}'
ISSUE_VIEW_JSON=""
PR_VIEW_JSON=""
ISSUE_STATE_MAP="$(printf '502\tCLOSED\n700\tCLOSED\n')"
seed_windows '@0 #502 Claim target' '@1 #700 Peer session working it'
FIX=1
run_case
grep -q "#700 (window @1) — NOT repaired: it is In Progress on the board, stamped to this host" <<<"$OUT" \
  || fail "mcase10: a peer's live same-host claim must be refused in another window\n$OUT"
[ "$(window_marker @1)" = '#700 Peer session working it' ] \
  || fail "mcase10: the peer's marker must survive untouched"
[ -z "$(window_marker @0)" ] || fail "mcase10: @0's terminal marker should still have cleared"
[ "$(cleared_count)" = "1" ] || fail "mcase10: exactly one clear expected (got $(cleared_count))\n$OUT"
FIX=0
echo "PASS: marker case 10 a peer's live claim in another window survives (GH #297 not reintroduced)"

# --- mcase 11: the sweep works from OUTSIDE tmux -------------------------------
# What makes the clear automatic rather than hand-run: the periodic sweep (/tidy)
# runs outside tmux, and must still read and repair the operator's windows. The
# pre-#1037 $TMUX guard made that a guaranteed no-op.
ITEM_LIST_JSON='{"items":[]}'
ISSUE_VIEW_JSON='{"state":"CLOSED"}'
PR_VIEW_JSON=""
ISSUE_STATE_MAP=""
seed_windows '@0 #502 Claim target'
FIX=1
OUT="$(unset TMUX; reconcile_main)"
grep -q "✓ cleared \[#502 Claim target\] in window @0 — #502 is CLOSED" <<<"$OUT" \
  || fail "mcase11: a sweep from outside tmux must still repair the server's windows\n$OUT"
[ -z "$(window_marker @0)" ] || fail "mcase11: @0 should be cleared from outside tmux"
[ "$(cleared_count)" = "1" ] || fail "mcase11: expected exactly one clear (got $(cleared_count))\n$OUT"
FIX=0
echo "PASS: marker case 11 the repair reaches the tmux server from outside tmux"

# --- mcase 12: the cross-board number-collision guard --------------------------
# A marker records "#<n> <title>" and NOT which repo <n> belongs to, while every
# board numbers into the same range — so a sweep of board 3 resolving a marker
# that actually came from board 4 misattributes it. Here #900 is a LIVE
# In-Progress claim for this host on the OTHER board, and reads CLOSED in the
# swept board's repo: without the guard, a sweep would wipe a live claim's chip
# (the GH #297 wrongful-clear class, arriving through the number space).
ITEM_LIST_JSON='{"items":[]}'
OTHER_BOARD_ITEMS_JSON='{"items":[
  {"id":"ISSUE_900","content":{"number":900,"title":"Live on the other board"},"status":"In Progress","host/Session":"testhost:abcd0001"}
]}'
ISSUE_VIEW_JSON='{"state":"CLOSED"}'
PR_VIEW_JSON=""
ISSUE_STATE_MAP=""
seed_windows '@0 #900 Live on the other board'
FIX=1
run_case
grep -q "#900 (window @0) — NOT repaired: #900 is a live In-Progress claim for this host on another registered board" <<<"$OUT" \
  || fail "mcase12: a live claim on another board must be refused\n$OUT"
[ "$(window_marker @0)" = '#900 Live on the other board' ] \
  || fail "mcase12: the other board's live claim marker must survive"
[ "$(cleared_count)" = "0" ] || fail "mcase12: nothing may be cleared (got $(cleared_count))\n$OUT"
FIX=0
echo "PASS: marker case 12 a live claim on ANOTHER registered board is never cleared"

# --- mcase 13: the guard's negative control -----------------------------------
# Same marker, same CLOSED answer — but now NO board holds #900 In Progress for
# this host. The clear must fire, proving mcase 12's refusal came from the guard
# and not from the sweep having simply stopped clearing anything.
OTHER_BOARD_ITEMS_JSON='{"items":[]}'
seed_windows '@0 #900 Live on the other board'
FIX=1
run_case
grep -q "✓ cleared \[#900 Live on the other board\] in window @0 — #900 is CLOSED" <<<"$OUT" \
  || fail "mcase13: with no live claim anywhere, the terminal marker must clear\n$OUT"
[ "$(cleared_count)" = "1" ] || fail "mcase13: expected exactly one clear (got $(cleared_count))\n$OUT"
FIX=0
echo "PASS: marker case 13 the cross-board guard's negative control still clears"

# Restore the marker-lens fixtures for anything downstream.
ISSUE_VIEW_JSON=""; PR_VIEW_JSON=""; ISSUE_STATE_MAP=""; OTHER_BOARD_ITEMS_JSON='{"items":[]}'; seed_windows

echo
echo "=== Lens 2: status drift (status_reconcile_main) ==="

# Status reconcile resolves the board, bulk-reads issue+PR state, and (with --fix)
# writes Done — all through the shared _board_gh seam above. run_status repoints
# $EDITS at a fresh temp file so each case can assert which items were edited.
run_status() { EDITS="$(mktemp)"; OUT="$(status_reconcile_main)"; }

# Override the liveness seam: deterministic, data-driven by DEAD_SESSIONS. A
# session id in that list is DEAD (return 1); everything else is LIVE (return 0).
# Mirrors how _reconcile_tmux is overridden for the marker lens.
_reconcile_session_live() {
  case " $DEAD_SESSIONS " in
    *" $1 "*) return 1 ;;
    *)        return 0 ;;
  esac
}

# Pin "now" so the foreign-claim age cases (GH #152) are hermetic regardless of the
# wall clock — AND independent of the parser. FAKE_NOW is a LITERAL true-UTC epoch
# (2026-06-07T00:00:00Z = 1780790400), NOT _reconcile_epoch_of's output: deriving it
# from the same parser would let any timezone skew in the parser cancel itself and
# escape detection. With a literal here, a parser that mis-handles the trailing 'Z'
# as local time (the BSD `date -j -f` footgun) shifts upd_epoch but not now, so the
# age math — and scase7's exact-day assertion — catches the regression.
FAKE_NOW=1780790400
_reconcile_now() { echo "$FAKE_NOW"; }

# Directly assert the portable parser yields TRUE UTC (not host-local): the same
# instant must round-trip to FAKE_NOW regardless of the runner's $TZ.
[ "$(_reconcile_epoch_of 2026-06-07T00:00:00Z)" = "$FAKE_NOW" ] \
  || fail "setup: _reconcile_epoch_of must parse ISO-Z as UTC (got $(_reconcile_epoch_of 2026-06-07T00:00:00Z), want $FAKE_NOW) — timezone skew?"

# --- status case 1: terminal-but-not-Done, with --fix -------------------------
# #200 merged PR at (none) status, #201 closed issue still Ready → both terminal.
# #202 merged PR already Done (ok). #203 open issue claimed (ok). --fix moves the
# two terminal items to Done; the ok items are untouched.
ITEM_LIST_JSON='{"items":[
  {"id":"ISSUE_200","content":{"number":200,"title":"Merged PR, no status"}},
  {"id":"ISSUE_201","content":{"number":201,"title":"Closed issue still Ready"},"status":"Ready"},
  {"id":"ISSUE_202","content":{"number":202,"title":"Merged PR already Done"},"status":"Done"},
  {"id":"ISSUE_203","content":{"number":203,"title":"Open, claimed"},"status":"In Progress","host/Session":"testhost:abcd1234"}
]}'
ISSUE_LIST_JSON='[{"number":201,"state":"CLOSED"},{"number":203,"state":"OPEN"}]'
PR_LIST_JSON='[{"number":200,"state":"MERGED"},{"number":202,"state":"MERGED"}]'
FIX=1
run_status
grep -q "terminal-but-not-Done" <<<"$OUT" || fail "scase1: expected terminal section\n$OUT"
# Exact field alignment: #200 has NO board status, so its row has an empty middle
# field — assert the backing state and the '(none)' status land in the right slots
# (guards the IFS=tab empty-field-collapse bug).
grep -q "#200 — backing MERGED but board status '(none)'" <<<"$OUT" \
  || fail "scase1: #200 fields misaligned (empty-status collapse?)\n$OUT"
grep -q "#201 — backing CLOSED but board status 'Ready'" <<<"$OUT" \
  || fail "scase1: #201 (closed Ready) should be flagged with aligned fields\n$OUT"
grep -q "✓ #200 → Done" <<<"$OUT" || fail "scase1: --fix should move #200 to Done\n$OUT"
grep -q "✓ #201 → Done" <<<"$OUT" || fail "scase1: --fix should move #201 to Done\n$OUT"
grep -qx "ISSUE_202" "$EDITS" && fail "scase1: #202 already Done must not be edited\n$(cat "$EDITS")"
grep -qx "ISSUE_203" "$EDITS" && fail "scase1: #203 open/ok must not be edited\n$(cat "$EDITS")"
grep -q "In sync" <<<"$OUT" && fail "scase1: must not report in-sync with drift\n$OUT"
FIX=0
echo "PASS: status case 1 terminal-but-not-Done flagged + --fix moves them to Done"

# --- status case 2: orphaned In-Progress + unresolved (report-only) -----------
# #300 In Progress with empty Host/Session → orphan (NOT auto-fixed). #301 claimed
# to this host with a LIVE session (DEAD_SESSIONS empty) → ok, not flagged. #302
# Ready but in neither list → unresolved.
ITEM_LIST_JSON='{"items":[
  {"id":"ISSUE_300","content":{"number":300,"title":"Orphaned claim"},"status":"In Progress","host/Session":""},
  {"id":"ISSUE_301","content":{"number":301,"title":"Properly claimed"},"status":"In Progress","host/Session":"testhost:dead1234"},
  {"id":"ISSUE_302","content":{"number":302,"title":"Unknown to GH"},"status":"Ready"}
]}'
ISSUE_LIST_JSON='[{"number":300,"state":"OPEN"},{"number":301,"state":"OPEN"}]'
PR_LIST_JSON='[]'
FIX=1   # even with --fix, orphan and unknown are report-only
run_status
grep -q "orphaned In-Progress" <<<"$OUT" || fail "scase2: expected orphan section\n$OUT"
grep -q "#300" <<<"$OUT" || fail "scase2: #300 orphan should be flagged\n$OUT"
grep -q "#301" <<<"$OUT" && fail "scase2: #301 (live stamped) must not be flagged\n$OUT"
grep -q "^stale claims" <<<"$OUT" && fail "scase2: a live same-host claim must not be classed stale\n$OUT"
grep -q "unresolved" <<<"$OUT" || fail "scase2: expected unresolved section\n$OUT"
grep -q "#302" <<<"$OUT" || fail "scase2: #302 unknown should be flagged\n$OUT"
grep -qx "ISSUE_300" "$EDITS" && fail "scase2: orphan #300 must NEVER be auto-edited\n$(cat "$EDITS")"
[ ! -s "$EDITS" ] || fail "scase2: no item-edit should fire (no terminal items)\n$(cat "$EDITS")"
FIX=0
echo "PASS: status case 2 orphan + unresolved reported, never auto-fixed"

# --- status case 3: fully in sync ---------------------------------------------
# #400 merged PR already Done; #401 open issue Ready; #402 open issue claimed. No
# drift in any class.
ITEM_LIST_JSON='{"items":[
  {"id":"ISSUE_400","content":{"number":400,"title":"Done merged PR"},"status":"Done"},
  {"id":"ISSUE_401","content":{"number":401,"title":"Open, ready"},"status":"Ready"},
  {"id":"ISSUE_402","content":{"number":402,"title":"Open, claimed"},"status":"In Progress","host/Session":"testhost:beef5678"}
]}'
ISSUE_LIST_JSON='[{"number":401,"state":"OPEN"},{"number":402,"state":"OPEN"}]'
PR_LIST_JSON='[{"number":400,"state":"MERGED"}]'
FIX=0
run_status
grep -q "In sync" <<<"$OUT" || fail "scase3: expected in-sync all-clear\n$OUT"
grep -q "terminal-but-not-Done" <<<"$OUT" && fail "scase3: unexpected terminal section\n$OUT"
grep -q "orphaned In-Progress" <<<"$OUT" && fail "scase3: unexpected orphan section\n$OUT"
grep -q "^stale claims" <<<"$OUT" && fail "scase3: unexpected stale section\n$OUT"
echo "PASS: status case 3 fully in-sync all-clear"

# --- status case 4: stale claim — same-host stamp, DEAD session (GH #85) -------
# #800 In Progress stamped to THIS host but its session is dead → stale claim,
# report-only (never auto-edited, even with --fix). #801 same host but LIVE → ok.
ITEM_LIST_JSON='{"items":[
  {"id":"ISSUE_800","content":{"number":800,"title":"Stranded by a dead run"},"status":"In Progress","host/Session":"testhost:dead0001"},
  {"id":"ISSUE_801","content":{"number":801,"title":"Actively worked"},"status":"In Progress","host/Session":"testhost:live0001"}
]}'
ISSUE_LIST_JSON='[{"number":800,"state":"OPEN"},{"number":801,"state":"OPEN"}]'
PR_LIST_JSON='[]'
DEAD_SESSIONS="dead0001"
FIX=1
run_status
grep -q "^stale claims" <<<"$OUT" || fail "scase4: expected stale section\n$OUT"
grep -q "#800 — stamped 'testhost:dead0001'" <<<"$OUT" \
  || fail "scase4: #800 stale should be flagged with its stamp\n$OUT"
grep -q "#801" <<<"$OUT" && fail "scase4: #801 (live same-host) must not be flagged\n$OUT"
[ ! -s "$EDITS" ] || fail "scase4: stale claim must NEVER be auto-edited\n$(cat "$EDITS")"
DEAD_SESSIONS=""; FIX=0
echo "PASS: status case 4 stale same-host claim flagged (live one not), never auto-fixed"

# --- status case 5: foreign claim — stamped to ANOTHER host (report-only) ------
# #900 In Progress stamped to a different host → liveness unverifiable here, so it
# is reported under foreign and NEVER released from this machine — even though the
# local oracle is told its session id is dead (foreign wins, no liveness call).
ITEM_LIST_JSON='{"items":[
  {"id":"ISSUE_900","content":{"number":900,"title":"Owned by another host"},"status":"In Progress","host/Session":"otherhost:abcd0001"}
]}'
ISSUE_LIST_JSON='[{"number":900,"state":"OPEN"}]'
PR_LIST_JSON='[]'
DEAD_SESSIONS="abcd0001"
FIX=1
run_status
grep -q "^foreign claims" <<<"$OUT" || fail "scase5: expected foreign section\n$OUT"
grep -q "#900 — stamped 'otherhost:abcd0001' (host 'otherhost'" <<<"$OUT" \
  || fail "scase5: #900 foreign should name the owning host\n$OUT"
grep -q "^stale claims" <<<"$OUT" && fail "scase5: foreign must not be classed stale\n$OUT"
[ ! -s "$EDITS" ] || fail "scase5: foreign claim must NEVER be auto-edited\n$(cat "$EDITS")"
DEAD_SESSIONS=""; FIX=0
echo "PASS: status case 5 foreign claim reported (host-aware), never released here"

# --- status case 6: terminal beats stale (jq branch priority) -----------------
# #1000 In Progress stamped to a DEAD same-host session, but its backing issue is
# CLOSED → must classify terminal (work is done), NOT stale.
ITEM_LIST_JSON='{"items":[
  {"id":"ISSUE_1000","content":{"number":1000,"title":"Closed but still In Progress"},"status":"In Progress","host/Session":"testhost:dead0002"}
]}'
ISSUE_LIST_JSON='[{"number":1000,"state":"CLOSED"}]'
PR_LIST_JSON='[]'
DEAD_SESSIONS="dead0002"
FIX=0
run_status
grep -q "terminal-but-not-Done" <<<"$OUT" || fail "scase6: closed-backed item should be terminal\n$OUT"
grep -q "#1000" <<<"$OUT" || fail "scase6: #1000 should be flagged terminal\n$OUT"
grep -q "^stale claims" <<<"$OUT" && fail "scase6: terminal must take priority over stale\n$OUT"
DEAD_SESSIONS=""
echo "PASS: status case 6 terminal-but-not-Done beats stale (priority)"

# --- status case 7: foreign claim STALE — old issue activity → escalated (GH #152) -
# #910 foreign (another host), backing issue last updated 37d before the pinned now
# → escalated to the louder "foreign claims (STALE …)" bucket. Report-only: never
# auto-edited even with --fix (releasing another host's claim is never automated).
ITEM_LIST_JSON='{"items":[
  {"id":"ISSUE_910","content":{"number":910,"title":"Stranded on a dead host"},"status":"In Progress","host/Session":"deadhost:abcd9100"}
]}'
ISSUE_LIST_JSON='[{"number":910,"state":"OPEN","updatedAt":"2026-05-01T00:00:00Z"}]'
PR_LIST_JSON='[]'
FIX=1
run_status
grep -q "^foreign claims (STALE" <<<"$OUT" || fail "scase7: expected STALE foreign section\n$OUT"
grep -q "#910 — stamped 'deadhost:abcd9100' (host 'deadhost')" <<<"$OUT" \
  || fail "scase7: #910 should name the owning host\n$OUT"
# Exact day count (2026-05-01 → pinned 2026-06-07 = 37d). Asserting the EXACT value,
# not a range, is what catches a parser timezone regression (local-time parse → 36d).
grep -q "no activity for 37d" <<<"$OUT" \
  || fail "scase7: #910 should report exactly 37d stale (timezone skew if off-by-one?)\n$OUT"
[ ! -s "$EDITS" ] || fail "scase7: a stale foreign claim must NEVER be auto-edited\n$(cat "$EDITS")"
FIX=0
echo "PASS: status case 7 stale foreign claim escalated, never auto-released"

# --- status case 8: foreign RECENT + fail-safe — stay in the plain foreign bucket -
# #911 foreign, backing issue updated 2d ago → recent, plain "foreign claims" (not
# escalated). #912 foreign with NO updatedAt available → fail safe to plain foreign
# (never escalate on missing data, never crash).
ITEM_LIST_JSON='{"items":[
  {"id":"ISSUE_911","content":{"number":911,"title":"Actively worked elsewhere"},"status":"In Progress","host/Session":"otherhost:abcd9110"},
  {"id":"ISSUE_912","content":{"number":912,"title":"Foreign, no updatedAt"},"status":"In Progress","host/Session":"otherhost:abcd9120"}
]}'
ISSUE_LIST_JSON='[{"number":911,"state":"OPEN","updatedAt":"2026-06-05T00:00:00Z"},{"number":912,"state":"OPEN"}]'
PR_LIST_JSON='[]'
FIX=1
run_status
grep -q "^foreign claims (In Progress" <<<"$OUT" || fail "scase8: expected plain foreign section\n$OUT"
grep -q "#911" <<<"$OUT" || fail "scase8: #911 recent should be plain foreign\n$OUT"
grep -q "#912" <<<"$OUT" || fail "scase8: #912 (no updatedAt) should fail safe to plain foreign\n$OUT"
grep -q "^foreign claims (STALE" <<<"$OUT" \
  && fail "scase8: neither recent nor missing-updatedAt foreign should escalate\n$OUT"
[ ! -s "$EDITS" ] || fail "scase8: foreign claims must NEVER be auto-edited\n$(cat "$EDITS")"
FIX=0
echo "PASS: status case 8 recent + missing-updatedAt foreign stay plain (no escalation), never edited"

echo
echo "=== Lens 3: the live-read guarantee (reconcile.sh must never read a cache) ==="

# reconcile is a DRIFT DETECTOR; fed cached data it is self-defeating. That
# guarantee used to rest on reconcile.sh's own `export BOARD_CACHE_TTL=0`, and
# this case proved it by planting a FRESH but WRONG on-disk cache file and
# asserting the live truth still won.
#
# ADR 0004 removed board.sh's cross-process cache (and BOARD_CACHE_TTL with it),
# so there is no longer a TTL to pin — but the GUARANTEE still matters, and it is
# now STRUCTURAL: the only cache that can sit in front of a board read is the
# issue-corpus store in lib/cache.sh, and board.sh consults it ONLY when the
# calling process has itself sourced that file (the `command -v cache_read`
# probe in _board_issues_item_list). reconcile.sh never sources it, so the read
# is live no matter what a shared boards.conf says.
#
# That is a stronger property than the old TTL pin — it cannot be defeated by a
# config value at all — so this case now asserts it directly, in both halves:
# the structural precondition, and the live-truth behavior under the most
# hostile config available (cache=on for this very board).

# (a) STRUCTURAL: cache_read must not be in scope after sourcing reconcile.sh.
# If a future change makes reconcile.sh source lib/cache.sh, this fails — which
# is exactly the review moment the guarantee needs.
if command -v cache_read >/dev/null 2>&1; then
  fail "live-read: reconcile.sh must NOT bring cache_read into scope — a drift detector must never read a cache (see reconcile.sh's live-read comment)"
fi

# (b) BEHAVIORAL, under a boards.conf that turns the cache ON for board 3.
# Even with the enable axis set, the read must stay live (the axis is inert
# without cache.sh in scope), so the LIVE truth below must win: #950 In Progress
# on THIS host, matched by a live tmux marker → "in sync", not a false
# marker-without-board drift.
CACHEON_CONF="$TEST_WORK_DIR/cache-on-boards.conf"
cat > "$CACHEON_CONF" <<'CONF'
board.3.cache=on
CONF
ITEM_LIST_JSON='{"items":[
  {"id":"ISSUE_950","content":{"number":950,"title":"Live truth item"},"status":"In Progress","host/Session":"testhost:live0001"}
]}'
MARKER_LINES='@0	#950 Live truth item
'
OUT="$(BOARDS_CONF_MACHINE="$CACHEON_CONF" BOARDS_CONF_REPO_LOCAL="$TEST_WORK_DIR/no-such-conf" reconcile_main)"
grep -q "In sync" <<<"$OUT" \
  || fail "live-read: expected 'in sync' from the LIVE #950 claim even with board.3.cache=on\n$OUT"
grep -q "marker-without-board" <<<"$OUT" \
  && fail "live-read: #950 flagged marker-without-board — something served a cached read\n$OUT"
echo "PASS: live-read — reconcile never brings cache_read into scope, and reads live even under board.<N>.cache=on"

echo
echo "PASS: all reconcile.sh drift-detection assertions passed"
