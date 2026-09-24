#!/usr/bin/env bash
#
# Tests for `state-graph.sh soak` — the mechanical cross-check (day count set
# by `STATE_GRAPH_SOAK_DAYS`) between the four board/PR/worktree-comparable
# queries and the INDEPENDENT `reconcile.sh --status` read ADR 0033's
# independence claim rests on
# (temperloop#1910; PER-CLASS scope rewrite temperloop#1978; stale-claims's
# liveness oracle corrected to transcripts, gated on host, temperloop#1980
# round 3). Sibling of test_state_graph.sh / test_state_graph_local.sh /
# test_state_graph_queries.sh, which cover the eight `_sg_read_*` sources
# and the five `_sg_query_*` functions this file never re-covers — it feeds
# `_sg_soak_run` real (mocked) board/reconcile inputs through the SAME
# `_board_gh`/`_sg_git`/`_sg_tmux`/`_sg_reconcile` seams (transcripts has no
# seam of its own — real files under `$CLAUDE_PROJECTS_DIR`, mirroring the
# journal source's own precedent), plus this file's own deterministic
# `_sg_soak_day`/`_sg_now_ms` overrides and a pinned `$SUBSET_HOST_LABEL` so
# stale-claims's host gate matches every fixture's claim stamp. Fixtures are
# entirely synthetic: no real host names, session ids, issue numbers, or
# paths (the mnemonic placeholder "mini-1" only).
#
# Covers:
#   - a MATCHING day (status-drift class): both `query status-drift` and
#     reconcile.sh's `orphaned In-Progress` class independently flag the SAME
#     issue — classes["status-drift"].diff.agree=true, both only_in_* empty.
#   - a DIFFERING day (status-drift class): the two sides flag DIFFERENT
#     issues — diff.agree=false, each only_in_* names the issue the other
#     side missed.
#   - a dead-session claim stamp (temperloop#1978, this item's day-1
#     #1225/#1111/#1048/#1047 shape): surfaces in the stale-claims class
#     (both sides agree) and is correctly ABSENT from status-drift's own
#     drift_query_set — a claimed, in-progress issue trips neither of
#     status-drift's own open-domain finding kinds.
#   - a closed issue still wearing an fnd:status:* label (temperloop#1978,
#     this item's day-1 #158 shape): surfaces in the status-drift class on
#     BOTH sides (the board source's own closed-issue residue read vs.
#     reconcile's `residual status labels on closed issues`) — agree:true.
#   - a Ready-status issue still wearing its claim stamp (temperloop#1980
#     round 4 HIGH): correctly ABSENT from stale-claims's own
#     drift_query_set — `$claims` is gated to In Progress, matching
#     reconcile's own producer, which emits nothing for a non-In-Progress
#     claim (the "Park, don't abandon" residue).
#   - the PARKED-BUT-STAMPED case against STATUS-DRIFT (temperloop#1996): an
#     OPEN issue off In Progress still wearing its claim stamp is flagged
#     `claimed_not_in_progress` by the query, but that kind has NO
#     counterpart in `reconcile.sh --status` (its real counterpart, class
#     (m) `PARKED claim stamps on OPEN issues`, lives in the `--labels`
#     lens the soak never calls) — so it is excluded from the compared set
#     and NAMED in `not_covered_kinds`, never left in `only_in_drift_query`
#     as a standing false disagreement. The query itself still reports it.
#   - KIND COMPLETENESS (temperloop#1996): every finding kind
#     `_sg_query_status_drift` can emit is dispositioned in
#     `_SG_SOAK_STATUS_DRIFT_KIND_COUNTERPART`, and the table names no kind
#     the query cannot emit — so a FOURTH kind cannot be added without
#     being audited against what `--status` can actually report.
#   - unlinked-prs / orphan-worktrees: reconcile.sh has no matching class for
#     either, so their reconcile_set/diff always read the literal string
#     "not-covered" — never an empty-set false agreement/disagreement.
#   - "never a false agreement over unknown": a degraded board source makes
#     status-drift's drift_query_set (and diff) the literal string
#     "unknown", never an empty array that would read as false agreement; a
#     failing `_sg_reconcile` does the same to BOTH mapped classes'
#     reconcile_set/diff independently of the board source (one reconcile.sh
#     call covers both classes, so it degrades them together) — while
#     unlinked-prs/orphan-worktrees stay "not-covered" regardless, since
#     nothing about them was ever going to be compared against reconcile.
#   - `--count` counts DISTINCT `day` values across every CURRENT-SCHEMA-
#     COMPARABLE record in the log (`type:"audit"`/`type:"bench"`, or
#     `type:"run"` at `schema:2`), 0 on an empty/missing log — and correctly
#     EXCLUDES a pre-temperloop#1978 flat-schema run record (no `type` field
#     at all) from the count (acceptance criterion 4).
#   - `--status` (temperloop#2016) reports the soak clock's staleness as ONE
#     closed JSON line carrying all three figures — days recorded, days
#     required (`STATE_GRAPH_SOAK_DAYS`, read not restated), and how LONG
#     since the most recent record — plus a TYPED `state` whose values never
#     collapse into one another: `never-recorded` (nothing ever ran:
#     days_recorded 0, last_day/days_since_last NULL, never 0) vs `stale`
#     (records exist, the newest older than `STATE_GRAPH_SOAK_STALE_DAYS`) vs
#     `current` vs `unreadable` (a torn line, or a qualifying record whose
#     `day` is not a date — its own answer, never a silent never-recorded).
#     Covered at the BOUNDARY too (exactly at the threshold still reads
#     current; one day past reads stale), plus: it exits 0 in every state
#     (it reports, it never gates), it writes nothing to the log, and its
#     day set is the SAME `_sg_soak_qualifying_days` filter `--count` reads
#     — so a legacy flat-schema record is excluded from the recency exactly
#     as it is from the count, and the two can never drift apart.
#   - `--audit --items <file>` appends a `{day, type:"audit",
#     audited_items}` record, extracting one issue number per line
#     (bare/`#N`/`Issue:N` all accepted); a zero-issue file is a legitimate
#     empty audit set, not a crash (the same pipefail/grep absorption the
#     reconcile-set extraction needs).
#   - the log rides lib/cache.sh's own path accessors (kind=state-graph-soak,
#     fully isolated from state-graph/state-graph-bench) and is APPEND-ONLY
#     — a second run never clobbers the first.
#   - `bench --scale N` captures one `{day, type:"bench", scale, query_ms,
#     slow_queries}` record into the SAME log, correctly naming only the
#     query whose deterministic elapsed time exceeds
#     `STATE_GRAPH_QUERY_SLOW_MS`.
#   - CLI dispatch: `soak --help` (THE class-A activation predicate, run
#     verbatim), missing --board, --audit with no --items, an unknown arg —
#     all exit/behave correctly with zero network reached.
#
# The seams are redefined mid-file per case (the library calls them
# indirectly), so shellcheck's "never invoked"/"unreachable" checks are false
# positives — disabled file-wide like the sibling state-graph test files.
# shellcheck disable=SC2317,SC2329
set -euo pipefail

# Hermetic conf env (temperloop#501): fixture tests must never resolve boards
# through the repo's or host's real boards.conf.
export BOARDS_CONF_REPO_LOCAL=/dev/null
export BOARDS_CONF_MACHINE=/dev/null

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=workflows/scripts/build/state-graph.sh
source "$HERE/../state-graph.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Host-local sources must never read this RUNNER's real knowledge store,
# transcript root, Claude Code projects directory, or tmux server — mirrors
# test_state_graph.sh's own hermetic-env pair exactly. transcripts
# (temperloop#1980 round 3, stale-claims's liveness oracle) defaults to an
# EXISTING-but-empty directory rather than a missing one, so the ordinary
# "no live session for this claim" (stale) case reads a real ok/zero-nodes
# result by default (mirrors tmux's own prior "reachable server, zero
# markers" mock default) — the transcripts-source-ABSENT case below
# overrides this per-test to exercise the unknown carve-out instead.
export KNOWLEDGE_STORE_ROOT="$TMP/no-such-knowledge-store"
export SPEND_TRANSCRIPT_ROOT="$TMP/no-such-transcripts"
export CLAUDE_PROJECTS_DIR="$TMP/cp-default"
mkdir -p "$CLAUDE_PROJECTS_DIR"
# stale-claims's host gate (temperloop#1980 round 3 HIGH 2) reads the
# snapshot's own `.host` field (`board_host_label` at build time) — pinned
# here to match every fixture's `fnd:host/session:mini-1:*` claim stamp
# below, or every claim in this file would be silently host-filtered out.
export SUBSET_HOST_LABEL="mini-1"
_sg_tmux() { return 1; }
_sg_git() { echo "worktree /home/x/dev/batch/foundation"; }

# Every test gets its own cache root so cases never see each other's state.
fresh_cache() { export CACHE_STORE_ROOT="$TMP/cache-$1"; }

BOARD=4          # Towheads/foundation, per board.sh's built-in map
REPO="Towheads/foundation"

command -v _sg_reconcile >/dev/null || fail "_sg_reconcile seam missing — soak has no independent reconcile.sh invocation point"
echo "PASS: state-graph.sh defines the _sg_reconcile seam (mirrors _sg_git/_sg_tmux)"

# A small accessor: read one class's field out of a soak run record.
class_field() { jq -c --arg c "$1" --arg f "$2" '.classes[$c][$f]' <<<"$3"; }

# =============================================================================
# a MATCHING day (status-drift class) — both sides independently flag #10
# =============================================================================
fresh_cache matching
_board_gh() {
  case "$1 $2" in
    "issue list") echo '[{"number":10,"title":"x","labels":[{"name":"fnd:status:in-progress"}]}]' ;;
    "api repos/$REPO/issues/10/sub_issues") echo '[]' ;;
    "api repos/$REPO/issues/10/dependencies/blocked_by") echo '[]' ;;
    "pr list") echo '[]' ;;
    "api repos/$REPO/issues") echo '[]' ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
# issue #10 is fnd:status:in-progress with NO claimed_by edge -> status-drift
# flags it (in_progress_no_claim). reconcile.sh's own orphaned-In-Progress
# bucket independently names the SAME issue by number — a real matching day,
# not a vacuous both-empty one.
_sg_reconcile() {
  cat <<'EOT'
orphaned In-Progress (report-only — park by hand: release.sh / re-claim):
  #10 — In Progress with no Host/Session owner (orphaned claim) — some title
EOT
}
_sg_soak_day() { echo "2026-01-01"; }
record="$(_sg_soak_run "$BOARD")"
[ "$(jq -r '.type' <<<"$record")" = "run" ] || fail "matching-day record missing type:run (got: $record)"
[ "$(jq -r '.schema' <<<"$record")" = "2" ] || fail "matching-day record missing schema:2 (got: $record)"
[ "$(class_field status-drift drift_query_set "$record")" = '[10]' ] || fail "matching-day status-drift drift_query_set (got: $record)"
[ "$(class_field status-drift reconcile_set "$record")" = '[10]' ] || fail "matching-day status-drift reconcile_set (got: $record)"
[ "$(jq -r '.classes["status-drift"].diff.agree' <<<"$record")" = "true" ] || fail "matching-day status-drift diff.agree should be true (got: $record)"
[ "$(jq -c '.classes["status-drift"].diff.only_in_drift_query' <<<"$record")" = '[]' ] || fail "matching-day only_in_drift_query should be empty (got: $record)"
[ "$(jq -c '.classes["status-drift"].diff.only_in_reconcile' <<<"$record")" = '[]' ] || fail "matching-day only_in_reconcile should be empty (got: $record)"
[ "$(jq -r '.day' <<<"$record")" = "2026-01-01" ] || fail "matching-day record day mismatch (got: $record)"
# unlinked-prs / orphan-worktrees: reconcile.sh has no matching class for
# either — reconcile_set/diff always read "not-covered", never an empty-set
# false agreement.
[ "$(class_field unlinked-prs reconcile_set "$record")" = '"not-covered"' ] || fail "unlinked-prs reconcile_set should be 'not-covered' (got: $record)"
[ "$(class_field unlinked-prs diff "$record")" = '"not-covered"' ] || fail "unlinked-prs diff should be 'not-covered' (got: $record)"
[ "$(class_field orphan-worktrees reconcile_set "$record")" = '"not-covered"' ] || fail "orphan-worktrees reconcile_set should be 'not-covered' (got: $record)"
[ "$(class_field orphan-worktrees diff "$record")" = '"not-covered"' ] || fail "orphan-worktrees diff should be 'not-covered' (got: $record)"
echo "PASS: soak — a matching day (status-drift class, both sides flag the same issue) records agree:true; unlinked-prs/orphan-worktrees read not-covered"

# =============================================================================
# a DIFFERING day (status-drift class) — the two sides flag DIFFERENT issues
# =============================================================================
_sg_reconcile() {
  cat <<'EOT'
terminal-but-not-Done (work complete, board not):
  #99 — backing CLOSED but board status 'In Progress' — should be Done: some title
EOT
}
_sg_soak_day() { echo "2026-01-02"; }
record="$(_sg_soak_run "$BOARD")"
[ "$(class_field status-drift drift_query_set "$record")" = '[10]' ] || fail "differing-day status-drift drift_query_set (got: $record)"
[ "$(class_field status-drift reconcile_set "$record")" = '[99]' ] || fail "differing-day status-drift reconcile_set (got: $record)"
[ "$(jq -r '.classes["status-drift"].diff.agree' <<<"$record")" = "false" ] || fail "differing-day status-drift diff.agree should be false (got: $record)"
[ "$(jq -c '.classes["status-drift"].diff.only_in_drift_query' <<<"$record")" = '[10]' ] || fail "differing-day only_in_drift_query (got: $record)"
[ "$(jq -c '.classes["status-drift"].diff.only_in_reconcile' <<<"$record")" = '[99]' ] || fail "differing-day only_in_reconcile (got: $record)"
echo "PASS: soak — a differing day (status-drift class, each side flags a distinct issue) records agree:false with per-side diffs"

# =============================================================================
# a matching day whose reconcile.sh report embeds `#N` inside a flagged
# line's TITLE (and a `#M` inside a stderr warning) — neither may inflate
# the status-drift reconcile_set into a phantom disagreement (over-broad
# #[0-9]+ extraction over merged stdout+stderr).
# =============================================================================
_sg_reconcile() {
  echo "warning: #50 could not be labeled Backlog" >&2
  cat <<'EOT'
orphaned In-Progress (report-only — park by hand: release.sh / re-claim):
  #10 — In Progress with no Host/Session owner (orphaned claim) — fix flaky test (temperloop#1910)
EOT
}
_sg_soak_day() { echo "2026-01-05"; }
record="$(_sg_soak_run "$BOARD")"
[ "$(class_field status-drift reconcile_set "$record")" = '[10]' ] || fail "a #N inside a title or stderr warning must never inflate status-drift reconcile_set (got: $record)"
[ "$(jq -r '.classes["status-drift"].diff.agree' <<<"$record")" = "true" ] || fail "a #N inside a title or stderr warning must never manufacture a false disagreement (got: $record)"
echo "PASS: soak — a #N embedded in a flagged line's TITLE or a stderr warning is never mistaken for a flagged item ref"

# =============================================================================
# a claim with no live transcript (temperloop#1978, this item's day-1
# #1225/#1111/#1048/#1047 shape): surfaces in stale-claims on BOTH sides and
# is correctly ABSENT from status-drift's own drift_query_set — a claimed,
# in-progress issue trips neither of status-drift's own open-domain finding
# kinds (it is neither unclaimed-in-progress nor claimed-but-not-in-progress).
#
# transcripts is seeded OK (the file-level default `$CLAUDE_PROJECTS_DIR`,
# an existing but empty directory) so no Transcript node exists for
# `deadbeef` — temperloop#1980 round 3: transcripts, not tmux and not the
# journal, is stale-claims's liveness oracle now, the SAME evidence
# reconcile.sh's own `_reconcile_session_live` checks. The journal is
# deliberately left at its absent default here to prove it plays no role in
# this verdict at all (round 1 keyed this same scenario off a journal
# Session node instead; round 2 off a tmux marker instead — both were the
# bug).
# =============================================================================
_board_gh() {
  case "$1 $2" in
    "issue list")
      echo '[{"number":20,"title":"x","labels":[{"name":"fnd:status:in-progress"},{"name":"fnd:host/session:mini-1:deadbeef"}]}]'
      ;;
    "api repos/$REPO/issues/20/sub_issues") echo '[]' ;;
    "api repos/$REPO/issues/20/dependencies/blocked_by") echo '[]' ;;
    "pr list") echo '[]' ;;
    "api repos/$REPO/issues") echo '[]' ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
# transcripts is ok (reachable dir) but holds no Transcript node for
# `deadbeef` -> stale-claims (board + transcripts, gated on host) flags #20
# as a claim naming an issue with no live transcript.
_sg_reconcile() {
  cat <<'EOT'
stale claims (In Progress, stamped to a dead same-host session — park by hand):
  #20 — stamped 'mini-1:deadbeef' but that session is not live on this host 'mini-1' — some title
EOT
}
_sg_soak_day() { echo "2026-01-06"; }
record="$(_sg_soak_run "$BOARD")"
[ "$(class_field stale-claims drift_query_set "$record")" = '[20]' ] || fail "no-transcript stale-claims drift_query_set (got: $record)"
[ "$(class_field stale-claims reconcile_set "$record")" = '[20]' ] || fail "no-transcript stale-claims reconcile_set (got: $record)"
[ "$(jq -r '.classes["stale-claims"].diff.agree' <<<"$record")" = "true" ] || fail "no-transcript stale-claims diff.agree should be true (got: $record)"
[ "$(class_field status-drift drift_query_set "$record")" = '[]' ] || fail "a claimed in-progress issue must NOT surface in status-drift's drift_query_set (got: $record)"
[ "$(class_field status-drift reconcile_set "$record")" = '[]' ] || fail "a dead-session claim stamp line must NOT be attributed to status-drift's reconcile_set (got: $record)"
echo "PASS: soak — a claim with no live transcript surfaces in stale-claims (both sides agree) and is absent from status-drift on either side"

# =============================================================================
# a closed issue still wearing an fnd:status:* label (temperloop#1978, this
# item's day-1 #158 shape): surfaces in status-drift on BOTH sides — the
# board source's own closed-issue residue read vs. reconcile's own "residual
# status labels on closed issues" class.
#
# transcripts stays at its file-level default (an existing, empty
# directory — ok, not absent) so the "must NOT surface in stale-claims"
# assertion below is a real empty-set read, not transcripts-absent's own
# "unknown" (temperloop#1980 round 3) masking it.
# =============================================================================
_board_gh() {
  case "$1 $2" in
    # a real, unrelated OPEN issue alongside the closed one — the primary
    # open-issue read stays "ok" (never "absent"), the branch the closed-
    # issue residue supplement is actually wired into (_sg_read_board).
    "issue list") echo '[{"number":1,"title":"other","labels":[{"name":"fnd:status:ready"}]}]' ;;
    "pr list") echo '[]' ;;
    # per-label residue read (temperloop#1978 round 2): #158 only shows up on
    # the fnd:status:backlog label's own call, never the other two labels'.
    "api repos/$REPO/issues")
      case " $* " in
        *" labels=fnd:status:backlog "*) echo '[{"number":158,"title":"x","labels":[{"name":"fnd:status:backlog"}]}]' ;;
        *) echo '[]' ;;
      esac
      ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
_sg_reconcile() {
  cat <<'EOT'
residual status labels on closed issues (work complete, tracker label not stripped):
  #158 — CLOSED but still labeled 'fnd:status:backlog' (Done here is 'closed + no status label') — some title
  (repair: reconcile.sh --board 4 --labels --apply)
EOT
}
_sg_soak_day() { echo "2026-01-07"; }
record="$(_sg_soak_run "$BOARD")"
[ "$(class_field status-drift drift_query_set "$record")" = '[158]' ] || fail "closed-residue status-drift drift_query_set (got: $record)"
[ "$(class_field status-drift reconcile_set "$record")" = '[158]' ] || fail "closed-residue status-drift reconcile_set (got: $record)"
[ "$(jq -r '.classes["status-drift"].diff.agree' <<<"$record")" = "true" ] || fail "closed-residue status-drift diff.agree should be true (got: $record)"
[ "$(class_field stale-claims drift_query_set "$record")" = '[]' ] || fail "a closed status-label residue must NOT surface in stale-claims (got: $record)"
echo "PASS: soak — a closed issue still wearing an fnd:status:* label surfaces in status-drift on both sides (the #158 shape)"

# =============================================================================
# transcripts source ABSENT (temperloop#1980 round 3): a LIVE claim must
# never be misread as stale merely because no transcript directory is
# reachable. stale-claims' own class reads "unknown" — even when
# reconcile.sh's INDEPENDENT read (its own liveness check, unrelated to this
# transcripts source) happens to name the very same issue — never folded
# into a false agreement, and never a concrete drift_query_set computed
# against zero known-live sessions. (Round 1 keyed this same scenario off
# the journal source instead, round 2 off tmux; superseded — transcripts is
# now the sole oracle, so the journal stays at its absent default here too
# and is simply irrelevant.)
# =============================================================================
export CLAUDE_PROJECTS_DIR="$TMP/no-such-projects"   # forces the source absent
_board_gh() {
  case "$1 $2" in
    "issue list")
      echo '[{"number":30,"title":"x","labels":[{"name":"fnd:status:in-progress"},{"name":"fnd:host/session:mini-1:c0ffee00"}]}]'
      ;;
    "api repos/$REPO/issues/30/sub_issues") echo '[]' ;;
    "api repos/$REPO/issues/30/dependencies/blocked_by") echo '[]' ;;
    "pr list") echo '[]' ;;
    "api repos/$REPO/issues") echo '[]' ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
_sg_reconcile() {
  cat <<'EOT'
stale claims (In Progress, stamped to a dead same-host session — park by hand):
  #30 — stamped 'mini-1:c0ffee00' but that session is not live on this host 'mini-1' — some title
EOT
}
_sg_soak_day() { echo "2026-01-08"; }
record="$(_sg_soak_run "$BOARD")"
[ "$(class_field stale-claims drift_query_set "$record")" = '"unknown"' ] || fail "transcripts-absent stale-claims drift_query_set must read the literal string 'unknown' (got: $record)"
[ "$(class_field stale-claims diff "$record")" = '"unknown"' ] || fail "transcripts-absent stale-claims diff must read 'unknown' — never folded into a false agreement with reconcile.sh's independent read (got: $record)"
[ "$(class_field stale-claims reconcile_set "$record")" = '[30]' ] || fail "transcripts-absent stale-claims reconcile_set must still carry reconcile.sh's own independent (unaffected) read (got: $record)"
echo "PASS: soak — a transcripts-absent read makes stale-claims' own class 'unknown', never a false agreement/disagreement with reconcile.sh's independent read (temperloop#1980 round 3)"
export CLAUDE_PROJECTS_DIR="$TMP/cp-default"   # restore the ok/empty default for the remaining cases

# =============================================================================
# "never a false agreement over unknown"
# =============================================================================
# board_resolve failure -> status-drift's own status is "unknown" ->
# drift_query_set/diff must read "unknown", never an empty array that would
# look like real agreement. unlinked-prs/orphan-worktrees, which never
# depend on board, stay "not-covered" regardless.
#
# transcripts stays at its file-level ok/empty default here — DELIBERATELY,
# so the board guard inside _sg_query_stale_claims is the ONLY thing that
# can produce `unknown` for this class on this day. Without this, an absent
# transcripts source would independently force `unknown` too, and this
# assertion would stay green even if the board-degraded check inside
# _sg_query_stale_claims were deleted outright — decorative coverage
# (temperloop#1980 round 2 review finding; carried forward unchanged into
# round 3's transcripts-keyed oracle — mutation-confirmed still
# discriminating).
_board_gh() { return 7; }
_sg_reconcile() { echo "In sync: every board item's status matches its GitHub state; no orphaned or stale claims."; }
_sg_soak_day() { echo "2026-01-03"; }
record="$(_sg_soak_run "$BOARD")"
[ "$(class_field status-drift drift_query_set "$record")" = '"unknown"' ] || fail "degraded board source should make status-drift drift_query_set the literal string unknown (got: $record)"
[ "$(class_field status-drift diff "$record")" = '"unknown"' ] || fail "degraded board source should make status-drift diff the literal string unknown (got: $record)"
[ "$(class_field stale-claims drift_query_set "$record")" = '"unknown"' ] || fail "degraded board source should make stale-claims drift_query_set the literal string unknown too (got: $record)"
[ "$(class_field unlinked-prs reconcile_set "$record")" = '"not-covered"' ] || fail "unlinked-prs reconcile_set stays not-covered even when board is degraded (got: $record)"
echo "PASS: soak — a degraded board source reads each affected class's drift_query_set/diff as 'unknown', never a false empty agreement (board guard, not a transcripts-absent freebie)"

# A failing _sg_reconcile invocation degrades BOTH mapped classes'
# reconcile_set/diff independently of the board source (one reconcile.sh
# call covers both classes, so it degrades them together) — while
# unlinked-prs/orphan-worktrees stay "not-covered" regardless.
_board_gh() {
  case "$1 $2" in
    "issue list") echo '[]' ;;
    "pr list") echo '[]' ;;
    "api repos/$REPO/issues") echo '[]' ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
_sg_reconcile() { echo "reconcile.sh: some fatal error" >&2; return 1; }
_sg_soak_day() { echo "2026-01-04"; }
record="$(_sg_soak_run "$BOARD")"
[ "$(class_field status-drift drift_query_set "$record")" = '[]' ] || fail "an ok board source should still produce a real (empty) status-drift drift_query_set (got: $record)"
[ "$(class_field status-drift reconcile_set "$record")" = '"unknown"' ] || fail "a failing _sg_reconcile invocation should make status-drift reconcile_set 'unknown' (got: $record)"
[ "$(class_field status-drift diff "$record")" = '"unknown"' ] || fail "a failing _sg_reconcile invocation should make status-drift diff 'unknown' (got: $record)"
[ "$(class_field stale-claims reconcile_set "$record")" = '"unknown"' ] || fail "a failing _sg_reconcile invocation should make stale-claims reconcile_set 'unknown' too (got: $record)"
[ "$(class_field unlinked-prs reconcile_set "$record")" = '"not-covered"' ] || fail "unlinked-prs reconcile_set stays not-covered even when reconcile.sh itself fails (got: $record)"
[ "$(class_field unlinked-prs diff "$record")" = '"not-covered"' ] || fail "unlinked-prs diff stays not-covered even when reconcile.sh itself fails (got: $record)"
echo "PASS: soak — a failing reconcile.sh invocation reads both mapped classes' reconcile_set/diff as 'unknown', independent of the board source; unlinked-prs/orphan-worktrees stay not-covered"

# =============================================================================
# reconcile's "stranded claim stamps on closed issues" class is EXCLUDED from
# stale-claims (temperloop#1980 round 3 MEDIUM): the board source's closed-
# issue residue read never attaches a claimed_by edge to a closed Issue
# node, so this reconcile class could only ever land in only_in_reconcile —
# a standing false disagreement, never a real cross-check. Confirms the
# narrowed _sg_reconcile_class_set mapping: this class contributes NOTHING
# to stale-claims's reconcile_set, even though its `#N` line shape is
# otherwise indistinguishable from the mapped "stale claims (In
# Progress...)" class.
# =============================================================================
_board_gh() {
  case "$1 $2" in
    "issue list") echo '[]' ;;
    "pr list") echo '[]' ;;
    "api repos/$REPO/issues") echo '[]' ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
_sg_reconcile() {
  cat <<'EOT'
stranded claim stamps on closed issues (claim lock that can never be released):
  #200 — CLOSED but still stamped 'mini-1:beadbead' (fnd:host/session label never cleared) — some title
EOT
}
_sg_soak_day() { echo "2026-01-09"; }
record="$(_sg_soak_run "$BOARD")"
[ "$(class_field stale-claims reconcile_set "$record")" = '[]' ] || fail "stranded-claim-stamp reconcile_set must be empty — that reconcile class is deliberately NOT mapped to stale-claims (got: $record)"
[ "$(jq -r '.classes["stale-claims"].diff.agree' <<<"$record")" = "true" ] || fail "an empty drift_query_set against an empty (correctly-unmapped) reconcile_set should read agree:true, never a manufactured only_in_reconcile disagreement (got: $record)"
echo "PASS: soak — reconcile's 'stranded claim stamps on closed issues' class is excluded from stale-claims entirely (temperloop#1980 round 3 MEDIUM: a class that can never agree is not diffed)"

# =============================================================================
# a Ready-status issue still wearing its claim stamp (temperloop#1980 round
# 4 HIGH): `$claims` is now gated to In Progress, matching reconcile's own
# producer, which emits NOTHING for a stamp on a non-In-Progress item — the
# ordinary "Park, don't abandon" residue (board_set_status moves an issue
# off In Progress without clearing its claim stamp; only release.sh does).
# Reproduces the reviewer's own live repro against a built snapshot:
# `"drift_query_set":[21],"reconcile_set":[]` before this fix. Absent the
# gate, #21's claim would read stale (no live transcript for 'ghost21').
# =============================================================================
_board_gh() {
  case "$1 $2" in
    "issue list")
      echo '[{"number":21,"title":"x","labels":[{"name":"fnd:status:ready"},{"name":"fnd:host/session:mini-1:ghost21"}]}]'
      ;;
    "api repos/$REPO/issues/21/sub_issues") echo '[]' ;;
    "api repos/$REPO/issues/21/dependencies/blocked_by") echo '[]' ;;
    "pr list") echo '[]' ;;
    "api repos/$REPO/issues") echo '[]' ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
_sg_reconcile() { echo "In sync: every board item's status matches its GitHub state; no orphaned or stale claims."; }
_sg_soak_day() { echo "2026-01-10"; }
record="$(_sg_soak_run "$BOARD")"
[ "$(class_field stale-claims drift_query_set "$record")" = '[]' ] || fail "a Ready-status issue's claim stamp must NOT surface in stale-claims's drift_query_set (got: $record)"
[ "$(class_field stale-claims reconcile_set "$record")" = '[]' ] || fail "reconcile's own (in-sync) read carries no class for a non-In-Progress claim (got: $record)"
[ "$(jq -r '.classes["stale-claims"].diff.agree' <<<"$record")" = "true" ] || fail "an empty drift_query_set against an empty reconcile_set should read agree:true, not a manufactured disagreement (got: $record)"
echo "PASS: soak — a Ready-status issue's claim stamp is excluded from stale-claims's drift_query_set entirely (temperloop#1980 round 4 HIGH: gated to In Progress, matching reconcile's own producer)"

# =============================================================================
# the PARKED-BUT-STAMPED case, now against STATUS-DRIFT (temperloop#1996):
# an OPEN issue, status off In Progress, claim stamp still attached — the
# ordinary "Park, don't abandon" residue (board_set_status moves the issue
# off In Progress; only release.sh clears the stamp, release.sh:175).
#
# `_sg_query_status_drift` flags it `claimed_not_in_progress`, and that kind
# has NO counterpart in `reconcile.sh --status` at all: its real counterpart
# is reconcile class (m), `PARKED claim stamps on OPEN issues`, which lives
# in `label_reconcile_main` — the `--labels` lens `_sg_soak_run` never
# calls. So before this fix every parked-but-stamped item landed in
# `only_in_drift_query` and could never agree — a standing false
# disagreement on an ordinary documented flow. The soak now excludes the
# kind from the compared set and NAMES it in `not_covered_kinds` instead.
#
# Deliberately a separate run from the round-4 case above (same fixture
# shape, different lens): that one asserts the STALE-CLAIMS gate, this one
# the STATUS-DRIFT kind gate, and neither should silently carry the other.
# =============================================================================
_board_gh() {
  case "$1 $2" in
    "issue list")
      echo '[{"number":22,"title":"x","labels":[{"name":"fnd:status:ready"},{"name":"fnd:host/session:mini-1:parked22"}]}]'
      ;;
    "api repos/$REPO/issues/22/sub_issues") echo '[]' ;;
    "api repos/$REPO/issues/22/dependencies/blocked_by") echo '[]' ;;
    "pr list") echo '[]' ;;
    "api repos/$REPO/issues") echo '[]' ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
_sg_reconcile() { echo "In sync: every board item's status matches its GitHub state; no orphaned or stale claims."; }
_sg_soak_day() { echo "2026-01-11"; }
record="$(_sg_soak_run "$BOARD")"
# The query itself still reports the finding — this fix narrows the SOAK's
# comparison, it does not delete a true drift finding from `query`.
[ "$(jq -r '[.findings[] | select(.kind=="claimed_not_in_progress") | .id] | join(",")' \
     <<<"$(_sg_query_status_drift "$(_sg_build_snapshot "$BOARD")")")" = "Issue:22" ] ||
  fail "query status-drift must STILL report the parked-but-stamped issue as claimed_not_in_progress — the soak narrows the comparison, not the query"
[ "$(class_field status-drift drift_query_set "$record")" = '[]' ] || fail "a parked-but-stamped issue must NOT enter status-drift's compared drift_query_set — --status has no counterpart for that kind (got: $record)"
[ "$(class_field status-drift reconcile_set "$record")" = '[]' ] || fail "reconcile's own (in-sync) --status read carries nothing for a parked claim stamp (got: $record)"
[ "$(jq -c '.classes["status-drift"].diff.only_in_drift_query' <<<"$record")" = '[]' ] || fail "a parked-but-stamped issue must never land in only_in_drift_query (got: $record)"
[ "$(jq -r '.classes["status-drift"].diff.agree' <<<"$record")" = "true" ] || fail "the parked-but-stamped case must not manufacture a status-drift disagreement (got: $record)"
# The narrowing is NAMED, never silent — the per-kind analogue of the
# class-level "not-covered" literal.
[ "$(class_field status-drift not_covered_kinds "$record")" = '["claimed_not_in_progress"]' ] || fail "status-drift's entry must name the excluded kind in not_covered_kinds (got: $record)"
[ "$(class_field stale-claims not_covered_kinds "$record")" = '[]' ] || fail "stale-claims has no uncounterparted finding kind — its not_covered_kinds is [] (got: $record)"
[ "$(class_field unlinked-prs not_covered_kinds "$record")" = '[]' ] || fail "unlinked-prs is not-covered as a WHOLE class, so its not_covered_kinds stays [] (got: $record)"
echo "PASS: soak — a parked-but-stamped open issue produces no false status-drift disagreement, and the excluded kind is named in not_covered_kinds (temperloop#1996)"

# =============================================================================
# KIND COMPLETENESS (temperloop#1996): every finding kind
# `_sg_query_status_drift` can emit must be dispositioned in
# `_SG_SOAK_STATUS_DRIFT_KIND_COUNTERPART` — counterparted, or explicitly
# "not-covered". This is the structural half of the fix: adding a FOURTH
# kind without auditing it against what `--status` can emit fails HERE
# rather than being rediscovered a fourth time as a standing false
# disagreement in a production soak log.
# =============================================================================
sg_src="$HERE/../state-graph.sh"
sg_body="$(sed -n '/^_sg_query_status_drift()/,/^}/p' "$sg_src")"
# WHITESPACE-TOLERANT extraction (shell-reviewer, MEDIUM). A strict
# `kind:"..."` pattern is defeated by `kind: "..."` — one space, valid jq,
# stylistically indistinguishable — and the count assertion is derived from
# the SAME extraction, so it passes too and both completeness loops then
# iterate the known three. A guard a one-character reformat silently disarms
# is not a structural defense (kernel principle 5), which is precisely what
# this block exists to be. `-E` + POSIX classes behave identically on BSD and
# GNU grep. `|| true` keeps the no-match case reaching its own explanatory
# `fail` below rather than dying bare under `set -e` + `pipefail` (the LOW).
emitted_kinds="$(printf '%s\n' "$sg_body" |
  grep -oE 'kind:[[:space:]]*"[a-z_]+"' |
  sed -E -e 's/^kind:[[:space:]]*"//' -e 's/"$//' | sort -u || true)"
# STRICT extraction, kept only as a cross-check: if the two disagree, someone
# reformatted a `kind:` and the strict pattern would have started silently
# under-reporting. Trip the test on the reformat instead of absorbing it.
emitted_kinds_strict="$(printf '%s\n' "$sg_body" |
  grep -o 'kind:"[a-z_]*"' | sed -e 's/^kind:"//' -e 's/"$//' | sort -u || true)"
[ -n "$emitted_kinds" ] || fail "could not extract any finding kind from _sg_query_status_drift — the completeness check would pass vacuously"
[ "$emitted_kinds" = "$emitted_kinds_strict" ] || fail "whitespace-tolerant and strict kind extractions disagree — a \`kind:\` was reformatted, and the strict pattern would silently under-report. Loose: $(printf '%s' "$emitted_kinds" | tr '\n' ' ')| strict: $(printf '%s' "$emitted_kinds_strict" | tr '\n' ' ')"
[ "$(printf '%s\n' "$emitted_kinds" | wc -l | tr -d ' ')" -eq 3 ] || fail "expected _sg_query_status_drift to emit 3 finding kinds (got: $(printf '%s' "$emitted_kinds" | tr '\n' ' '))"
while IFS= read -r k; do
  [ "$(jq -r --arg k "$k" 'has($k)' <<<"$_SG_SOAK_STATUS_DRIFT_KIND_COUNTERPART")" = "true" ] ||
    fail "status-drift finding kind '$k' is not dispositioned in _SG_SOAK_STATUS_DRIFT_KIND_COUNTERPART — audit it against what reconcile.sh --status can emit, then map it or mark it not-covered"
done <<<"$emitted_kinds"
# And the table names nothing the query cannot emit (a stale entry silently
# narrowing a kind that no longer exists is the same bug pointed the other
# way).
# Captured, NOT a process substitution (shell-reviewer, LOW): a process
# substitution's exit status is invisible to `set -e`/`pipefail`, so a
# malformed table literal would yield no lines, skip the loop body, and report
# PASS having checked nothing. A failing command substitution DOES trip
# `set -e`, and the non-empty assertion closes the remaining vacuity.
table_kinds="$(jq -r 'keys[]' <<<"$_SG_SOAK_STATUS_DRIFT_KIND_COUNTERPART")"
[ -n "$table_kinds" ] || fail "_SG_SOAK_STATUS_DRIFT_KIND_COUNTERPART yielded no keys — the reverse-direction check would pass vacuously"
while IFS= read -r k; do
  printf '%s\n' "$emitted_kinds" | grep -Fx "$k" >/dev/null ||
    fail "_SG_SOAK_STATUS_DRIFT_KIND_COUNTERPART names kind '$k', which _sg_query_status_drift never emits"
done <<<"$table_kinds"
echo "PASS: soak — every status-drift finding kind is dispositioned in the counterpart table, and the table names no kind the query cannot emit (temperloop#1996)"

# =============================================================================
# --count: distinct days, log is append-only through lib/cache.sh
# =============================================================================
expect_dir="$(cache_repo_dir "$BOARD" state-graph-soak)"
expect_log="$(cache_snapshot_file "$BOARD" state-graph-soak)"
[ -d "$expect_dir" ] || fail "soak log directory was not created via cache_repo_dir(kind=state-graph-soak)"
[ -s "$expect_log" ] || fail "soak log file was not created via cache_snapshot_file(kind=state-graph-soak)"
lines_before="$(wc -l <"$expect_log" | tr -d ' ')"
[ "$lines_before" -eq 11 ] || fail "soak log should carry exactly the eleven runs above (got $lines_before lines)"

count="$(cmd_soak --count --board "$BOARD")"
[ "$count" = 11 ] || fail "soak --count should report 11 distinct days (got: $count)"
echo "PASS: soak --count — distinct days recorded, log persisted append-only through lib/cache.sh"

# --count SCHEMA exclusion (temperloop#1978, acceptance criterion 4): a
# hand-appended pre-temperloop#1978 flat-schema run record (no `type` field
# at all — the OLD `{day, drift_query_set, reconcile_set, diff}` shape) adds
# a line to the log but must NOT add to the day count — it is silently
# excluded as not current-schema-comparable, never misread as a per-class
# run for a day nothing per-class was ever recorded on.
printf '%s\n' '{"day":"2025-12-31","drift_query_set":[],"reconcile_set":[],"diff":{"only_in_drift_query":[],"only_in_reconcile":[],"agree":true}}' >>"$expect_log"
lines_after_legacy="$(wc -l <"$expect_log" | tr -d ' ')"
[ "$lines_after_legacy" -eq 12 ] || fail "the hand-appended legacy record should still add a line to the log (got $lines_after_legacy lines)"
count_with_legacy="$(cmd_soak --count --board "$BOARD")"
[ "$count_with_legacy" = 11 ] || fail "soak --count must exclude a pre-temperloop#1978 flat-schema run record from the day count (got: $count_with_legacy)"
echo "PASS: soak --count — a pre-temperloop#1978 flat-schema run record (no type field) is excluded from the day count"

# --count on a board with no soak log yet prints 0, never an error.
fresh_cache empty-count
count0="$(cmd_soak --count --board "$BOARD")"
[ "$count0" = 0 ] || fail "soak --count on an empty/missing log should print 0 (got: $count0)"
echo "PASS: soak --count — 0 on a board with no soak log yet"

# --count over a torn/malformed log line surfaces WHY it failed (a bare
# non-zero exit under pipefail leaves the reason silent).
fresh_cache count-malformed
malformed_dir="$(cache_repo_dir "$BOARD" state-graph-soak)"
mkdir -p "$malformed_dir"
malformed_log="$(cache_snapshot_file "$BOARD" state-graph-soak)"
printf '{not valid json\n' >"$malformed_log"
rc=0; malformed_out="$(cmd_soak --count --board "$BOARD" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "soak --count over a malformed log should exit non-zero (got: $malformed_out)"
printf '%s' "$malformed_out" | grep -F -- 'unreadable soak log' >/dev/null || fail "soak --count over a malformed log should name the unreadable log path (got: $malformed_out)"
echo "PASS: soak --count — a torn/malformed log line surfaces a diagnostic and exits non-zero"

# =============================================================================
# --status: the read-only staleness report (temperloop#2016)
#
# The three figures (days recorded / days required / how long since the most
# recent record) plus a TYPED state, in ONE closed JSON line. Every case below
# pins `_sg_soak_day` so "how long ago" is deterministic rather than a function
# of the calendar the suite happens to run on, and writes its own log lines by
# hand (no network, no real cache dir — `fresh_cache` gives each case its own
# CACHE_STORE_ROOT under $TMP).
# =============================================================================

# A small accessor: write N literal log lines into THIS case's soak log.
seed_soak_log() {
  local dir file
  dir="$(cache_repo_dir "$BOARD" state-graph-soak)"
  mkdir -p "$dir"
  file="$(cache_snapshot_file "$BOARD" state-graph-soak)"
  printf '%s\n' "$@" >"$file"
  printf '%s' "$file"
}

# one closed JSON line, always — never two lines, never a bare figure.
assert_one_json_line() {
  local out="$1" what="$2"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] || fail "$what should print exactly ONE line (got: $out)"
  jq -e . >/dev/null 2>&1 <<<"$out" || fail "$what should print parseable JSON (got: $out)"
}

# --- never recorded: nothing has EVER run ------------------------------------
# days_recorded is 0 and last_day/days_since_last are NULL — there is no "how
# long ago" for a clock that never started, and a 0 there would read as "ran
# today", the exact typed-state collapse this report exists to avoid.
fresh_cache status-never
_sg_soak_day() { echo "2026-09-14"; }
rc=0; never_out="$(cmd_soak --status --board "$BOARD")" || rc=$?
[ "$rc" -eq 0 ] || fail "soak --status on a board with no soak log should exit 0, not gate (got rc=$rc)"
assert_one_json_line "$never_out" "soak --status"
[ "$(jq -r '.state' <<<"$never_out")" = "never-recorded" ] || fail "an empty/missing soak log must read state=never-recorded (got: $never_out)"
[ "$(jq -r '.days_recorded' <<<"$never_out")" = "0" ] || fail "never-recorded must report days_recorded 0 (got: $never_out)"
[ "$(jq -r '.last_day' <<<"$never_out")" = "null" ] || fail "never-recorded has no last_day — it must be null, never a date (got: $never_out)"
[ "$(jq -r '.days_since_last' <<<"$never_out")" = "null" ] || fail "never-recorded has no days_since_last — it must be null, never 0 (got: $never_out)"
echo "PASS: soak --status — a log with no qualifying record reads never-recorded, with a NULL days_since_last (never 0)"

# --- stale: records exist, the newest is old ---------------------------------
# The payload is the FIGURE: "no soak record in 6 days" carries information on
# day 6 that a repeated "soak is stale" boolean does not.
fresh_cache status-stale
seed_soak_log \
  '{"day":"2026-09-05","type":"audit","audited_items":[]}' \
  '{"day":"2026-09-08","type":"run","schema":2,"classes":{}}' >/dev/null
rc=0; stale_out="$(cmd_soak --status --board "$BOARD")" || rc=$?
[ "$rc" -eq 0 ] || fail "soak --status over a stale clock must still exit 0 — it reports, it never gates (got rc=$rc)"
assert_one_json_line "$stale_out" "soak --status"
[ "$(jq -r '.state' <<<"$stale_out")" = "stale" ] || fail "records ending 6 days ago must read state=stale (got: $stale_out)"
[ "$(jq -r '.days_since_last' <<<"$stale_out")" = "6" ] || fail "soak --status must report HOW LONG since the most recent record, not merely THAT it is stale (got: $stale_out)"
[ "$(jq -r '.last_day' <<<"$stale_out")" = "2026-09-08" ] || fail "stale must name the most recent recorded day (got: $stale_out)"
[ "$(jq -r '.days_recorded' <<<"$stale_out")" = "2" ] || fail "stale must still report the distinct days recorded (got: $stale_out)"
[ "$(jq -r '.days_required' <<<"$stale_out")" = "$STATE_GRAPH_SOAK_DAYS" ] || fail "days_required must come from STATE_GRAPH_SOAK_DAYS (got: $stale_out)"
echo "PASS: soak --status — a stopped clock reports how LONG it has been stopped (days_since_last), alongside recorded/required"

# --- the three figures never collapse into a boolean -------------------------
[ "$(jq -c '[.days_recorded, .days_required, .days_since_last] | map(type) | unique' <<<"$stale_out")" = '["number"]' ] \
  || fail "all three figures must be numbers on a stale clock, never booleans/nulls (got: $stale_out)"
echo "PASS: soak --status — all three figures (recorded, required, since-last) are present as numbers, not a boolean"

# --- days_required is READ from the setting, never a restated literal --------
rc=0; req_out="$(STATE_GRAPH_SOAK_DAYS=21 cmd_soak --status --board "$BOARD")" || rc=$?
[ "$(jq -r '.days_required' <<<"$req_out")" = "21" ] || fail "days_required must track STATE_GRAPH_SOAK_DAYS, never a hardcoded 14 (got: $req_out)"
echo "PASS: soak --status — days_required reads STATE_GRAPH_SOAK_DAYS rather than restating its default"

# --- current: a record from today --------------------------------------------
fresh_cache status-current
seed_soak_log '{"day":"2026-09-14","type":"run","schema":2,"classes":{}}' >/dev/null
current_out="$(cmd_soak --status --board "$BOARD")"
[ "$(jq -r '.state' <<<"$current_out")" = "current" ] || fail "a record from today must read state=current (got: $current_out)"
[ "$(jq -r '.days_since_last' <<<"$current_out")" = "0" ] || fail "a record from today is 0 days old (got: $current_out)"
echo "PASS: soak --status — a record from today reads current at days_since_last 0"

# --- THE BOUNDARY: exactly at the threshold is still current -----------------
# STATE_GRAPH_SOAK_STALE_DAYS is the oldest age still acceptable (`<=`), not
# the youngest that is not — so a record exactly that many days old is the
# LAST current one, and one day older is the first stale one.
fresh_cache status-boundary
seed_soak_log '{"day":"2026-09-11","type":"run","schema":2,"classes":{}}' >/dev/null
boundary_out="$(STATE_GRAPH_SOAK_STALE_DAYS=3 cmd_soak --status --board "$BOARD")"
[ "$(jq -r '.days_since_last' <<<"$boundary_out")" = "3" ] || fail "boundary fixture should be exactly 3 days old (got: $boundary_out)"
[ "$(jq -r '.state' <<<"$boundary_out")" = "current" ] || fail "EXACTLY at STATE_GRAPH_SOAK_STALE_DAYS must still read current (got: $boundary_out)"
just_past_out="$(STATE_GRAPH_SOAK_STALE_DAYS=2 cmd_soak --status --board "$BOARD")"
[ "$(jq -r '.state' <<<"$just_past_out")" = "stale" ] || fail "one day past STATE_GRAPH_SOAK_STALE_DAYS must read stale (got: $just_past_out)"
echo "PASS: soak --status — exactly at STATE_GRAPH_SOAK_STALE_DAYS reads current; one day past reads stale"

# --- unreadable is its OWN answer, never a silent never-recorded -------------
fresh_cache status-unreadable
seed_soak_log '{not valid json' >/dev/null
rc=0; unreadable_out="$(cmd_soak --status --board "$BOARD" 2>/dev/null)" || rc=$?
[ "$rc" -eq 0 ] || fail "soak --status over a torn log still reports rather than gating (got rc=$rc)"
assert_one_json_line "$unreadable_out" "soak --status over a torn log"
[ "$(jq -r '.state' <<<"$unreadable_out")" = "unreadable" ] || fail "a torn soak log must read state=unreadable, never never-recorded (got: $unreadable_out)"
[ "$(jq -r '.days_recorded' <<<"$unreadable_out")" = "null" ] || fail "an unreadable log knows NO day count — days_recorded must be null, never 0 (got: $unreadable_out)"
printf '%s' "$(cmd_soak --status --board "$BOARD" 2>&1 >/dev/null)" | grep -F -- 'unreadable soak log' >/dev/null \
  || fail "soak --status over a torn log should name the unreadable log path on stderr"
echo "PASS: soak --status — a torn log reads unreadable (its own state, days_recorded null), exits 0, and says why on stderr"

# --- a qualifying record whose `day` is not a date is also unreadable --------
fresh_cache status-badday
seed_soak_log '{"day":"whenever","type":"run","schema":2,"classes":{}}' >/dev/null
rc=0; badday_out="$(cmd_soak --status --board "$BOARD" 2>/dev/null)" || rc=$?
[ "$rc" -eq 0 ] || fail "soak --status over an unparseable day should report, not gate (got rc=$rc)"
[ "$(jq -r '.state' <<<"$badday_out")" = "unreadable" ] || fail "a non-date day value must read unreadable, never be silently treated as never-recorded or current (got: $badday_out)"
echo "PASS: soak --status — a qualifying record whose day is not a YYYY-MM-DD date reads unreadable, not never-recorded"

# --- a SHAPE-valid but CALENDAR-invalid day is unreadable too ----------------
# The regex + range guard alone accepts 2026-02-30: month and day are both in
# range, so the days-from-civil formula runs and returns an integer. Not a
# harmless one — 2026-02-30 and 2026-03-02 both compute to 20514, so a
# corrupted `day` would be read as a real date two days later and the
# staleness figure would be quietly wrong by two. Wrong-with-no-signal is
# strictly worse than `unreadable`, which is the typed answer this case is
# owed. The leap-year arm matters in both directions: 2024-02-29 is a real
# date and must NOT be rejected.
for bad_day in 2026-02-30 2026-04-31 2026-02-29 1900-02-29; do
  fresh_cache "status-calendar-$bad_day"
  seed_soak_log "{\"day\":\"$bad_day\",\"type\":\"run\",\"schema\":2,\"classes\":{}}" >/dev/null
  rc=0; cal_out="$(cmd_soak --status --board "$BOARD" 2>/dev/null)" || rc=$?
  [ "$rc" -eq 0 ] || fail "soak --status over a calendar-invalid day should report, not gate (day=$bad_day, rc=$rc)"
  [ "$(jq -r '.state' <<<"$cal_out")" = "unreadable" ] \
    || fail "$bad_day is not a real calendar date — it must read unreadable, never a silently-wrong days_since_last (got: $cal_out)"
  [ "$(jq -r '.days_since_last' <<<"$cal_out")" = "null" ] \
    || fail "$bad_day must yield NO recency figure at all, never a computed one (got: $cal_out)"
done
echo "PASS: soak --status — a shape-valid but calendar-invalid day (Feb 30, Apr 31, Feb 29 in a non-leap year) reads unreadable, not a wrong number"

# --- ...and a REAL leap day is still accepted -------------------------------
fresh_cache status-leapday
seed_soak_log '{"day":"2024-02-29","type":"run","schema":2,"classes":{}}' >/dev/null
leap_out="$(cmd_soak --status --board "$BOARD" 2>/dev/null)"
[ "$(jq -r '.state' <<<"$leap_out")" != "unreadable" ] \
  || fail "2024-02-29 IS a real calendar date — the days-in-month guard must not reject a genuine leap day (got: $leap_out)"
[ "$(jq -r '.last_day' <<<"$leap_out")" = "2024-02-29" ] \
  || fail "a genuine leap day must survive as last_day (got: $leap_out)"
echo "PASS: soak --status — a genuine leap day (2024-02-29) is accepted, so the guard rejects only real impossibilities"

# --- --count and --status read the SAME qualifying-day filter ----------------
# One filter, two readers (temperloop#2016): a pre-temperloop#1978 flat-schema
# record is excluded from BOTH the count and the recency — if the two filters
# could drift apart, the stalled clock would be invisible in exactly the way
# this report exists to fix.
fresh_cache status-shared-filter
seed_soak_log \
  '{"day":"2026-09-10","type":"run","schema":2,"classes":{}}' \
  '{"day":"2026-09-13","drift_query_set":[],"reconcile_set":[],"diff":{"only_in_drift_query":[],"only_in_reconcile":[],"agree":true}}' >/dev/null
shared_out="$(cmd_soak --status --board "$BOARD")"
shared_count="$(cmd_soak --count --board "$BOARD")"
[ "$(jq -r '.days_recorded' <<<"$shared_out")" = "$shared_count" ] || fail "soak --status days_recorded must equal soak --count (got: $shared_out vs $shared_count)"
[ "$(jq -r '.last_day' <<<"$shared_out")" = "2026-09-10" ] || fail "a legacy flat-schema record must not become last_day — --count and --status share one filter (got: $shared_out)"
[ "$(jq -r '.days_since_last' <<<"$shared_out")" = "4" ] || fail "recency must be measured from the newest QUALIFYING day (got: $shared_out)"
echo "PASS: soak --status — days_recorded equals --count and recency skips a non-qualifying record: one shared filter, never two"

# --- --status is READ-ONLY: it appends nothing to the log --------------------
log_before="$(cat "$(cache_snapshot_file "$BOARD" state-graph-soak)")"
cmd_soak --status --board "$BOARD" >/dev/null
[ "$(cat "$(cache_snapshot_file "$BOARD" state-graph-soak)")" = "$log_before" ] \
  || fail "soak --status must never write to the soak log (it is a read-only report)"
echo "PASS: soak --status — read-only: the soak log is byte-identical after a status read"

# =============================================================================
# --audit --items <file>
# =============================================================================
fresh_cache audit
_board_gh() {
  case "$1 $2" in
    "issue list") echo '[]' ;;
    "pr list") echo '[]' ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
_sg_reconcile() { echo "In sync: every board item's status matches its GitHub state; no orphaned or stale claims."; }
_sg_soak_day() { echo "2026-01-10"; }

ITEMS_FILE="$TMP/audit-items.txt"
printf '10\n#20\nIssue:30\n#40 build fails on 2026-09\n' >"$ITEMS_FILE"
audit_record="$(cmd_soak --audit --board "$BOARD" --items "$ITEMS_FILE")"
[ "$(jq -r '.type' <<<"$audit_record")" = "audit" ] || fail "audit record missing type:audit (got: $audit_record)"
[ "$(jq -c '.audited_items' <<<"$audit_record")" = '[10,20,30,40]' ] || fail "audit record did not extract bare/#N/Issue:N item refs correctly, anchored to one ref per line (got: $audit_record)"
[ "$(jq -r '.day' <<<"$audit_record")" = "2026-01-10" ] || fail "audit record day mismatch (got: $audit_record)"
echo "PASS: soak --audit — records a hand-audited item set against today, accepting bare/#N/Issue:N refs"

# a zero-issue items file is a legitimate empty audit set, not a crash.
EMPTY_ITEMS_FILE="$TMP/empty-items.txt"
: >"$EMPTY_ITEMS_FILE"
empty_audit="$(cmd_soak --audit --board "$BOARD" --items "$EMPTY_ITEMS_FILE")"
[ "$(jq -c '.audited_items' <<<"$empty_audit")" = '[]' ] || fail "an items file naming zero issues should produce an empty audited_items array (got: $empty_audit)"
echo "PASS: soak --audit — a zero-issue items file produces an empty set, not a crash (pipefail/grep absorption)"

# missing --items file errors rather than silently no-opping.
rc=0; cmd_soak --audit --board "$BOARD" --items "$TMP/does-not-exist.txt" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "soak --audit against a missing items file should fail, not silently succeed"
echo "PASS: soak --audit — a missing items file fails rather than silently no-opping"

# =============================================================================
# bench --scale N captures one {day, type:"bench", ...} record into the SAME
# soak log, correctly naming only the query whose deterministic elapsed time
# exceeds STATE_GRAPH_QUERY_SLOW_MS (temperloop#1910, acceptance criterion 2)
# =============================================================================
fresh_cache bench-soak
_board_gh() {
  case "$1 $2" in
    "issue list") echo '[]' ;;
    "pr list") echo '[]' ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
_sg_soak_day() { echo "2026-01-20"; }
export STATE_GRAPH_QUERY_SLOW_MS=50

# _sg_now_ms is called via command substitution ($(_sg_now_ms)), each call a
# SUBSHELL — an in-memory index would reset every call (the same subshell
# caveat test_state_graph_queries.sh's own gh-call-count comment documents),
# so this counter lives on DISK instead, surviving the subshell boundary.
# Sequence: build start/end (10ms, ignored), then per query in
# _SG_SOURCES-independent, fixed order (status-drift, stale-claims,
# unlinked-prs, orphan-worktrees, resume): 10ms each except resume's 100ms —
# the one query that must land in slow_queries.
NOW_SEQ_FILE="$TMP/now-seq.txt"
printf '0\n10\n10\n20\n20\n30\n30\n40\n40\n50\n50\n150\n' >"$NOW_SEQ_FILE"
NOW_IDX_FILE="$TMP/now-idx.txt"
echo 0 >"$NOW_IDX_FILE"
_sg_now_ms() {
  local idx v
  idx="$(cat "$NOW_IDX_FILE")"
  v="$(sed -n "$((idx + 1))p" "$NOW_SEQ_FILE")"
  echo $((idx + 1)) >"$NOW_IDX_FILE"
  echo "$v"
}
bench_stdout="$(cmd_bench --scale 1 --board "$BOARD")"
echo "$bench_stdout" | grep -E 'build_ms=[0-9]+' >/dev/null || fail "bench stdout format regressed (got: $bench_stdout)"

bench_logf="$(cache_snapshot_file "$BOARD" state-graph-soak)"
[ -s "$bench_logf" ] || fail "bench did not append to the soak log"
bench_record="$(tail -1 "$bench_logf")"
[ "$(jq -r '.type' <<<"$bench_record")" = "bench" ] || fail "bench soak-log record missing type:bench (got: $bench_record)"
[ "$(jq -r '.scale' <<<"$bench_record")" = "1" ] || fail "bench soak-log record scale mismatch (got: $bench_record)"
[ "$(jq -r '.query_ms.resume' <<<"$bench_record")" = "100" ] || fail "bench soak-log record resume timing mismatch (got: $bench_record)"
[ "$(jq -r '.query_ms."status-drift"' <<<"$bench_record")" = "10" ] || fail "bench soak-log record status-drift timing mismatch (got: $bench_record)"
[ "$(jq -c '.slow_queries' <<<"$bench_record")" = '["resume"]' ] || fail "bench should name only resume as the slow query at this scale (got: $bench_record)"
echo "PASS: bench --scale N — captures one {day, type:bench, query_ms, slow_queries} record naming the first query to exceed STATE_GRAPH_QUERY_SLOW_MS"

# =============================================================================
# bench --scale N with a non-integer STATE_GRAPH_QUERY_SLOW_MS override warns
# and falls back to the config default (500) instead of dying mid-run after
# the summary line has already printed. Own deterministic _sg_now_ms (a
# constant — this fixture only cares that the run COMPLETES and records, not
# about specific query timings) rather than reusing the exhausted disk-backed
# sequence above, since `_sg_now_ms` has no per-test reset otherwise.
# =============================================================================
fresh_cache bench-bad-slow-ms
_board_gh() {
  case "$1 $2" in
    "issue list") echo '[]' ;;
    "pr list") echo '[]' ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
_sg_soak_day() { echo "2026-01-21"; }
_sg_now_ms() { echo 0; }
export STATE_GRAPH_QUERY_SLOW_MS=500ms
rc=0; bad_slow_out="$(cmd_bench --scale 1 --board "$BOARD" 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || fail "bench with a non-integer STATE_GRAPH_QUERY_SLOW_MS should still complete (rc=$rc, out: $bad_slow_out)"
printf '%s' "$bad_slow_out" | grep -F -- 'STATE_GRAPH_QUERY_SLOW_MS' >/dev/null || fail "bench with a non-integer STATE_GRAPH_QUERY_SLOW_MS should warn on stderr (got: $bad_slow_out)"
printf '%s' "$bad_slow_out" | grep -E 'build_ms=[0-9]+' >/dev/null || fail "bench should still print its summary line (got: $bad_slow_out)"
bad_slow_logf="$(cache_snapshot_file "$BOARD" state-graph-soak)"
bad_slow_record="$(tail -1 "$bad_slow_logf")"
[ "$(jq -r '.type' <<<"$bad_slow_record")" = "bench" ] || fail "bench with a bad slow-ms override should still append a soak-log record (got: $bad_slow_record)"
[ "$(jq -r '.slow_ms' <<<"$bad_slow_record")" = "500" ] || fail "bench should fall back to the default slow_ms=500 on a bad override (got: $bad_slow_record)"
unset -f _sg_now_ms
unset STATE_GRAPH_QUERY_SLOW_MS
echo "PASS: bench — a non-integer STATE_GRAPH_QUERY_SLOW_MS warns and falls back to the default instead of dying mid-run"

# =============================================================================
# CLI dispatch — invoked as a real subprocess, zero network reached
# (mirrors test_state_graph_queries.sh's cmd_query CLI section exactly)
# =============================================================================
STATE_GRAPH_BIN="$HERE/../state-graph.sh"
CLI_TMP="$(mktemp -d)"
trap 'rm -rf "$TMP" "$CLI_TMP"' EXIT

NETWORK_CANARY="$CLI_TMP/network-canary.log"
SHIM_BIN="$CLI_TMP/shim-bin"
mkdir -p "$SHIM_BIN"
for _shim_cmd in gh git tmux; do
  cat >"$SHIM_BIN/$_shim_cmd" <<SHIMEOF
#!/usr/bin/env bash
echo "CANARY: $_shim_cmd \$*" >>"$NETWORK_CANARY"
exit 1
SHIMEOF
  chmod +x "$SHIM_BIN/$_shim_cmd"
done
SHIM_PATH="$SHIM_BIN:$PATH"

echo "── soak CLI: --help prints usage naming --count (THE class-A activation predicate, run verbatim) ──"
PATH="$SHIM_PATH" bash "$STATE_GRAPH_BIN" soak --help 2>/dev/null | grep -- '--count' >/dev/null \
  || fail "the exact activation-gate predicate (soak --help | grep -q -- '--count') failed"
echo "PASS: soak CLI — --help satisfies the class-A activation predicate verbatim"

echo "── soak CLI: --help names --status (discoverability of the staleness report) ──"
PATH="$SHIM_PATH" bash "$STATE_GRAPH_BIN" soak --help 2>/dev/null | grep -- '--status' >/dev/null \
  || fail "soak --help must name --status — an undiscoverable report is a report nobody runs"
echo "PASS: soak CLI — --help names --status alongside --count"

echo "── soak CLI: --help exits 0 ──"
rc=0; PATH="$SHIM_PATH" bash "$STATE_GRAPH_BIN" soak --help >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] || fail "soak --help should exit 0 (got rc=$rc)"
echo "PASS: soak CLI — --help exits 0"

echo "── soak CLI: missing --board exits 2 ──"
rc=0; out="$(PATH="$SHIM_PATH" bash "$STATE_GRAPH_BIN" soak 2>&1)" || rc=$?
[ "$rc" -eq 2 ] || fail "missing --board did not exit 2 (got rc=$rc, out: $out)"
echo "PASS: soak CLI — missing --board exits 2"

echo "── soak CLI: --audit with no --items exits 2 ──"
rc=0; out="$(PATH="$SHIM_PATH" bash "$STATE_GRAPH_BIN" soak --audit --board 4 2>&1)" || rc=$?
[ "$rc" -eq 2 ] || fail "soak --audit with no --items did not exit 2 (got rc=$rc, out: $out)"
printf '%s' "$out" | grep -F -- '--items' >/dev/null || fail "soak --audit error did not name the missing --items flag (got: $out)"
echo "PASS: soak CLI — --audit with no --items exits 2"

echo "── soak CLI: an unknown arg exits 2 ──"
rc=0; out="$(PATH="$SHIM_PATH" bash "$STATE_GRAPH_BIN" soak --board 4 --bogus 2>&1)" || rc=$?
[ "$rc" -eq 2 ] || fail "an unknown soak arg did not exit 2 (got rc=$rc, out: $out)"
echo "PASS: soak CLI — an unknown arg exits 2"

if [ -s "$NETWORK_CANARY" ]; then
  fail "a soak CLI subprocess reached a real gh/git/tmux binary instead of exiting on validation (canary: $(cat "$NETWORK_CANARY"))"
fi
echo "PASS: soak CLI — zero network reached across every subprocess case (shim canary empty)"

echo "ALL PASS: test_state_graph_soak.sh"
