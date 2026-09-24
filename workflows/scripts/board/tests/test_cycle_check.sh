#!/usr/bin/env bash
#
# Fixture-replay tests for cycle-check.sh — the script-backed cycle guard
# `/triage`'s Step-4 edge-stamping sub-step must run before every
# `blocked_by` write (temperloop#1847, docs/adr/0031).
#
# Zero network: we SOURCE cycle-check.sh (its execute-guard suppresses the
# auto-run when sourced) and override the board.sh `_board_gh` seam with a
# small synthetic `blocked_by` graph, keyed by the issue number embedded in
# the REST path `board_blocked_by_open` requests
# (`repos/<repo>/issues/<n>/dependencies/blocked_by`) — the same seam
# test_blocked_by.sh replays against, one level up the call stack.
#
# The property under test: writing "<issue> blocked_by <blocker>" must be
# refused (CYCLE) whenever <blocker> already (directly or transitively)
# depends on <issue> in the EXISTING graph, and permitted (SAFE) otherwise
# — with a read failure anywhere in the walk reported UNREADABLE, never
# silently treated as SAFE.
#
# The `_board_gh` override is invoked indirectly (board_blocked_by_open
# calls it) and is redefined mid-file per case, so shellcheck's
# "never invoked" / "unreachable" checks are false positives — disabled
# file-wide, like test_blocked_by.sh / test_board_replay.sh. The module-level
# CYCLE_CHECK_ISSUE / CYCLE_CHECK_BLOCKER / PROJECT_NUMBER assignments in
# run_check() are consumed by cycle_check_main() in the sourced script — a
# cross-file use the static analyzer cannot see (cf. test_claim_guard.sh's
# identical disable for the same cross-file-global shape) — so SC2034 is
# disabled file-wide too. `set -- $line` in the synthetic-graph parsers below
# is deliberate unquoted word-splitting (each GRAPH line is space-separated
# fields by construction, never glob-sensitive test data) — SC2086 disabled
# file-wide rather than per-line since every occurrence here is the same
# pattern.
# shellcheck disable=SC2317,SC2329,SC2034,SC2086
set -euo pipefail

# Hermetic conf env (temperloop#501): fixture tests must never resolve
# boards through the repo's or host's real boards.conf.
export BOARDS_CONF_REPO_LOCAL=/dev/null
export BOARDS_CONF_MACHINE=/dev/null

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$HERE/.." && pwd)"

# shellcheck source=scripts/cycle-check.sh
# shellcheck disable=SC1091
source "$SCRIPTS_DIR/cycle-check.sh"

fail() { printf 'FAIL: %b\n' "$1" >&2; exit 1; }

# GRAPH holds one "<issue> <blocker1>,<blocker2>,..." pair per line — the
# synthetic blocked_by edges: issue X is blocked_by every blocker on its
# line. `_board_gh` below answers board_blocked_by_open's REST read by
# parsing the issue number out of the requested path and looking it up here.
GRAPH=""
edge_set() { GRAPH="$1"; }  # e.g. "10 5
                             #      5 3"

# The default graph-lookup `_board_gh`. Re-installed by `reset_gh` after any
# case that plants a one-off override (5, 7, 8) — those cases replace this
# function directly and must not leak into a later case.
default_board_gh() {
  # Called as: _board_gh api "repos/<repo>/issues/<n>/dependencies/blocked_by"
  local path="$2" issue blockers
  issue="${path#repos/*/issues/}"
  issue="${issue%/dependencies/blocked_by}"
  blockers=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    set -- $line
    if [ "$1" = "$issue" ]; then
      shift
      blockers="$*"
    fi
  done <<<"$GRAPH"
  if [ -z "$blockers" ]; then
    echo '[]'
    return 0
  fi
  local out="[" first=1 b
  for b in $blockers; do
    [ "$first" = 1 ] || out="$out,"
    out="$out{\"number\":$b,\"state\":\"open\"}"
    first=0
  done
  out="$out]"
  printf '%s' "$out"
}
reset_gh() { _board_gh() { default_board_gh "$@"; }; }
reset_gh

run_check() {
  CYCLE_CHECK_ISSUE="$1"
  CYCLE_CHECK_BLOCKER="$2"
  PROJECT_NUMBER=7
  OUT="$(cycle_check_main)"
}

# ── Case 1 — an empty existing graph is always SAFE ──────────────────────
edge_set ""
run_check 10 5
[ "$OUT" = "SAFE 10 5" ] || fail "case 1: an unblocked pair over an empty graph must be SAFE, got: [$OUT]"

# ── Case 2 — a direct existing edge in the SAME direction is still SAFE ──
# 5 is already blocked_by 3; proposing "10 blocked_by 5" adds a NEW chain
# tail, no loop.
edge_set "5 3"
run_check 10 5
[ "$OUT" = "SAFE 10 5" ] || fail "case 2: extending an existing chain must be SAFE, got: [$OUT]"

# ── Case 3 — a direct cycle: blocker already depends on issue ────────────
# 5 is blocked_by 10 already; proposing "10 blocked_by 5" would close a
# 2-node loop (10 needs 5, 5 needs 10).
edge_set "5 10"
run_check 10 5
[ "$OUT" = "CYCLE 10 5 path=5->10" ] || fail "case 3: a direct 2-node cycle must be refused with its path, got: [$OUT]"

# ── Case 4 — a transitive cycle several hops out ──────────────────────────
# 5 blocked_by 7; 7 blocked_by 10. So 5 already (transitively) depends on
# 10. Proposing "10 blocked_by 5" closes the loop through the chain
# 5 -> 7 -> 10.
edge_set "5 7
7 10"
run_check 10 5
[ "$OUT" = "CYCLE 10 5 path=5->7->10" ] || fail "case 4: a transitive cycle must be refused with the full chain, got: [$OUT]"

# ── Case 5 — a self-blocker is refused without any read ─────────────────
# run_check's `OUT="$(cycle_check_main)"` runs cycle_check_main in a command-
# substitution SUBSHELL, so a plain shell-variable flip inside the _board_gh
# override (e.g. GH_CALLED=1) never propagates back to this shell — the
# assertion would pass vacuously even if a read DID happen. Assert via an
# out-of-band marker FILE instead, whose existence survives the subshell.
GH_CALL_MARKER="$(mktemp -u)"
_board_gh() { : >"$GH_CALL_MARKER"; echo '[]'; }
run_check 10 10
[ "$OUT" = "CYCLE 10 10 path=10->10 (self-blocker)" ] || fail "case 5: a self-blocker must be refused, got: [$OUT]"
if [ -e "$GH_CALL_MARKER" ]; then
  rm -f "$GH_CALL_MARKER"
  fail "case 5: a self-blocker must be caught before any board read"
fi
rm -f "$GH_CALL_MARKER" 2>/dev/null || true

# ── Case 6 — an unrelated sibling chain never false-positives ───────────
# 5 depends on 3, unrelated to 10. "10 blocked_by 5" must stay SAFE.
reset_gh
edge_set "5 3"
run_check 10 5
[ "$OUT" = "SAFE 10 5" ] || fail "case 6: an unrelated chain must not false-positive a cycle, got: [$OUT]"

# ── Case 7 — a CLOSED blocker on an intermediate node does not gate the ──
# walk (board_blocked_by_open already filters state=open at the adapter
# layer; this just proves cycle-check doesn't re-derive that filter wrong).
# 5 is blocked_by 10, but that edge is CLOSED — 5 does not actually depend
# on 10 any more, so "10 blocked_by 5" must be SAFE.
_board_gh() {
  local path="$2" issue
  issue="${path#repos/*/issues/}"; issue="${issue%/dependencies/blocked_by}"
  if [ "$issue" = "5" ]; then
    echo '[{"number":10,"state":"closed"}]'
  else
    echo '[]'
  fi
}
run_check 10 5
[ "$OUT" = "SAFE 10 5" ] || fail "case 7: a CLOSED existing blocker must not be walked as live, got: [$OUT]"

# ── Case 8 — a failed read anywhere in the walk reports UNREADABLE, ──────
# never SAFE. Walking from 5 -> 7 succeeds, but 7's own read fails.
_board_gh() {
  local path="$2" issue
  issue="${path#repos/*/issues/}"; issue="${issue%/dependencies/blocked_by}"
  case "$issue" in
    5) echo '[{"number":7,"state":"open"}]' ;;
    7) return 1 ;;  # simulate a REST failure
    *) echo '[]' ;;
  esac
}
run_check 10 5
[ "$OUT" = "UNREADABLE 10 5 reason=blocked_by-read-failed(#7)" ] ||
  fail "case 8: a failed read mid-walk must report UNREADABLE and never SAFE, got: [$OUT]"

# ── Case 9 — a diamond graph terminates (no infinite loop on a re-visit) ─
# 5 depends on {7,8}; both 7 and 8 depend on 3. 3 is unrelated to 10, so
# this must resolve SAFE and, critically, must actually RETURN (a walk
# that doesn't dedupe visited nodes could loop forever re-queueing 3).
reset_gh
edge_set "5 7 8
7 3
8 3"
run_check 10 5
[ "$OUT" = "SAFE 10 5" ] || fail "case 9: a diamond graph must resolve (and stay SAFE when unrelated), got: [$OUT]"

# ── Case 10 — the node cap fails UNREADABLE, not an infinite hang ────────
reset_gh
CYCLE_CHECK_MAX_NODES=3
edge_set "5 6
6 7
7 8
8 9"
run_check 10 5
CYCLE_CHECK_MAX_NODES=500  # restore the script default; ${VAR:-500} is a no-op here since VAR is already set (to 3)
case "$OUT" in
  UNREADABLE\ 10\ 5\ reason=graph-too-large*) ;;
  *) fail "case 10: a graph past CYCLE_CHECK_MAX_NODES must report UNREADABLE, got: [$OUT]" ;;
esac

echo "PASS: test_cycle_check.sh (BFS verdicts)"

# ── Case 11 — CLI arg validation, driven as a REAL subprocess ───────────
cli() { set +e; CLI_OUT="$(bash "$SCRIPTS_DIR/cycle-check.sh" "$@" 2>&1)"; CLI_RC=$?; set -e; }

cli
[ "$CLI_RC" = 2 ] || fail "case 11: no args must be a usage error (rc 2), got rc=$CLI_RC"
printf '%s\n' "$CLI_OUT" | grep '^usage: cycle-check.sh ' >/dev/null ||
  fail "case 11: the no-args error must print usage; got: $CLI_OUT"

cli --board 7 10
[ "$CLI_RC" = 2 ] || fail "case 11: one arg must be a usage error (rc 2), got rc=$CLI_RC"

cli --board 7 abc 5
[ "$CLI_RC" = 2 ] || fail "case 11: a non-numeric issue must be a usage error (rc 2), got rc=$CLI_RC"
printf '%s\n' "$CLI_OUT" | grep 'issue must be a number' >/dev/null ||
  fail "case 11: a non-numeric issue must say so; got: $CLI_OUT"

cli --board 7 10 xyz
[ "$CLI_RC" = 2 ] || fail "case 11: a non-numeric blocker must be a usage error (rc 2), got rc=$CLI_RC"
printf '%s\n' "$CLI_OUT" | grep 'blocker must be a number' >/dev/null ||
  fail "case 11: a non-numeric blocker must say so; got: $CLI_OUT"

cli --board 7 --nope 10 5
[ "$CLI_RC" = 2 ] || fail "case 11: an unknown flag must be a usage error (rc 2), got rc=$CLI_RC"

echo "PASS: test_cycle_check.sh (CLI)"

# ── Case 12 — SPEC CONFORMANCE: /triage must actually invoke this guard ──
# The execution signal for the Step-4 edge-stamping sub-step's cycle check
# (claude/CLAUDE.kernel.md § Mandatory-step birth rule shape): a guard that
# exists but is never called from the spec is the exact gap this asserts
# against. Skipped (not failed) where the spec is absent — a consuming repo
# vendors the board scripts without claude/commands/.
SPEC="$(cd "$SCRIPTS_DIR/../../.." && pwd)/claude/commands/triage.md"
if [ -f "$SPEC" ]; then
  grep -F 'cycle-check.sh' "$SPEC" >/dev/null ||
    fail "case 12: claude/commands/triage.md carries no cycle-check.sh invocation — the edge-stamping sub-step is unguarded"
  grep -F 'board_blocked_by_add' "$SPEC" >/dev/null ||
    fail "case 12: claude/commands/triage.md carries no board_blocked_by_add call — the edge-stamping sub-step is missing"
  # Guarded-helper degradation: a stale adapter must be a documented no-op
  # that posts NO edges-considered marker — not a raw-REST fallback.
  grep -F 'command -v board_blocked_by_add' "$SPEC" >/dev/null ||
    fail "case 12: the edge-stamping sub-step doesn't guard on board_blocked_by_add's presence — it would crash 'command not found' on a stale adapter instead of degrading"
  grep -F 'no edges-considered marker posted' "$SPEC" >/dev/null ||
    fail "case 12: the stale-adapter degradation doesn't say the marker is withheld — a false all-clear could reach sweep's admission gate"
  # shellcheck disable=SC2016  # literal Markdown backticks in a fixed-string grep -F
  grep -F 'raw `gh api repos/.../dependencies/blocked_by` POST' "$SPEC" >/dev/null ||
    fail "case 12: the spec no longer states the raw-REST-fallback prohibition explicitly"
  echo "PASS: test_cycle_check.sh (spec conformance)"
else
  echo "SKIP: case 12 spec conformance — claude/commands/triage.md not present in this checkout"
fi
