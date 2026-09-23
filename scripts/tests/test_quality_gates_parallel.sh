#!/usr/bin/env bash
#
# test_quality_gates_parallel.sh — regression tests for the BOUNDED-CONCURRENCY
# scheduler scripts/quality-gates.sh runs its gate set through
# (workflows/scripts/lib/gate-pool.sh — temperloop#1025).
#
# Third sibling of test_quality_gates_freshness.sh and test_quality_gates_retry.sh,
# which cover the other two libs quality-gates.sh sources. Hermetic and fast:
# every "gate" here is a throwaway script under a tmpdir whose verdict, output
# and duration are scripted — no `make`, no network, and never this repo's real
# 109-target gate list (which is exactly why the scheduling policy lives in a
# sourceable lib: it could not otherwise be exercised without running the whole
# suite, which is the very cost this change exists to remove).
#
# The load-bearing property under test is EXIT-CODE INTEGRITY. A parallel runner
# whose worst failure mode is "a lost non-zero" would make CI green on a real
# failure — strictly worse than the slow serial loop it replaces. So the suite
# leans on the fail-closed paths (2, 3, 8, 9, 10) at least as hard as on the
# speedup (7).
#
# Covers, one case per contract clause:
#   1. every gate runs exactly once, and the replay is in LIST order regardless
#      of completion order (a fast gate finishing first must not jump the log)
#   2. one failing gate among passing ones → run returns non-zero, that gate and
#      only that gate is marked failed
#   3. FAIL-CLOSED: a worker that exits 0 but writes no verdict is recorded as a
#      FAILURE, not a pass
#   4. a worker's `deterministic` verdict survives the meta-file channel intact
#   5. SERIAL LANE: two lane-pinned gates never overlap each other, while still
#      overlapping the pool
#   6. `slow` gates are dispatched before ordinary pool gates
#   7. the pool really is concurrent — N one-second gates at width N finish in
#      about one second, not N
#   8. a worker that dies abruptly (unbound variable under `set -u`) still
#      completes the run — no hang — and is recorded as a failure
#   9. jobs resolution: `auto` is a sane positive integer, an explicit integer is
#      honored, and garbage degrades to 1 (serial) rather than to a guess
#  10. WIRING: quality-gates.sh really sources this lib, drives it, keeps a
#      serial fallback, and keeps CI on a single non-matrix job
#  11. UNCHANGED EXECUTION ENVIRONMENT: the pool does not change the SIGINT
#      disposition a gate sees, measured DIFFERENTIALLY against a serial
#      baseline this suite takes for itself — the CI regression that made
#      test_gh_call_logger.sh's "Ctrl-C -> 130" case observe 0 — and the pool
#      leaves the caller's own `set -m` state untouched. When the invoker left
#      the disposition alone the absolute "130, not 0" form still runs;
#      otherwise it reports itself as a SKIP (temperloop#2094)
#  11b. and the FIXTURE for 11's resolution: the same fixture run under BOTH a
#      default invocation and an ancestor-hard-ignored one, pinning that this
#      suite's verdict is a property of the POOL and never of how the suite
#      itself was launched
#
# Usage: scripts/tests/test_quality_gates_parallel.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$REPO_ROOT/workflows/scripts/lib/gate-pool.sh"
QG="$REPO_ROOT/scripts/quality-gates.sh"
CI="$REPO_ROOT/.github/workflows/ci.yml"

[ -f "$LIB" ] || { echo "FAIL: lib not found at $LIB" >&2; exit 1; }

fail_count=0
fail() { echo "FAIL: $1" >&2; fail_count=$((fail_count + 1)); }
pass() { echo "PASS: $1"; }
# A check that does not apply to THIS tree reports itself rather than vanishing —
# a silent no-op is the failure mode a skipped check is supposed to avoid.
skip() { echo "SKIP: $1"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/qg-pool-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# shellcheck source=workflows/scripts/lib/gate-pool.sh
source "$LIB"

# ---------------------------------------------------------------------------
# A scripted worker. Each "gate" command line is `sh -c :`-shaped only in name;
# the worker below interprets the FIRST word as a directive so a case can script
# a verdict, a duration, and an interleaving trace without writing files.
#
#   pass:<name>[:<sleep>]   → verdict pass
#   fail:<name>[:<sleep>]   → verdict fail
#   det:<name>              → verdict deterministic
#   nometa:<name>           → exits 0 having written NO verdict (fail-closed)
#   boom:<name>             → dies on an unbound variable under `set -u`
#   sig:<name>              → runs a child that kills ITSELF with SIGINT and
#                             records the exit code it observed to $WORK/sigcode
#
# Every invocation appends `<name> start`/`<name> end` to $WORK/trace with a
# timestamp, which is how the overlap assertions below are made.
# ---------------------------------------------------------------------------
tw() {
  local spec="$1"
  local kind name secs
  kind="${spec%%:*}"
  name="${spec#*:}"
  secs="${name#*:}"
  name="${name%%:*}"
  case "$secs" in '' | "$name") secs=0 ;; esac

  printf '%s %s start %s\n' "$(date +%s)" "$name" "$$" >>"$WORK/trace"
  echo "output of $name"
  [ "$secs" != 0 ] && sleep "$secs"
  printf '%s %s end %s\n' "$(date +%s)" "$name" "$$" >>"$WORK/trace"

  case "$kind" in
    pass) printf 'pass\t1\t\n' >"$GATE_POOL_META"; return 0 ;;
    fail) printf 'fail\t3\t\n' >"$GATE_POOL_META"; return 1 ;;
    det) printf 'deterministic\t1\tsignature match\n' >"$GATE_POOL_META"; return 1 ;;
    nometa) return 0 ;;
    boom) echo "${THIS_IS_NOT_SET_ON_PURPOSE}"; return 0 ;;
    sig)
      local sigcode=0
      "$WORK/selfint.sh" || sigcode=$?
      printf '%s\n' "$sigcode" >"$WORK/sigcode"
      # Compared against the SERIAL baseline this suite measured for ITSELF
      # (SIG_BASELINE, § 11) rather than a literal 130 — see that section for
      # why an absolute expectation here is an assertion about the INVOKER,
      # not about the pool (temperloop#2094).
      if [ "$sigcode" -eq "${SIG_BASELINE:-130}" ]; then
        printf 'pass\t1\t\n' >"$GATE_POOL_META"
        return 0
      fi
      printf 'fail\t1\tSIGINT observed as %s (serial baseline %s)\n' \
        "$sigcode" "${SIG_BASELINE:-130}" >"$GATE_POOL_META"
      return 1
      ;;
  esac
}

# The `sig` fixture: a script that kills itself with SIGINT, exactly as
# workflows/scripts/probe/tests/test_gh_call_logger.sh's fake tool does. Under
# the default (job-control-off) `&` fork this is a NO-OP, because bash
# hard-ignores SIGINT in an asynchronous child and the disposition is inherited
# through exec — which is how a real gate silently changed verdict.
cat >"$WORK/selfint.sh" <<'SELFINT'
#!/usr/bin/env bash
kill -INT $$
sleep 1
SELFINT
chmod +x "$WORK/selfint.sh"

# run_case <jobs> <lanes-csv> <gate>... — set up the pool arrays, run, capture
# stdout. <lanes-csv> is a comma-separated lane per gate, positionally ("" =
# all pool). Parallel arrays rather than an associative one on purpose: bash 3.2
# (the macOS system bash the nightly leg may run on) has no `declare -A`.
# Leaves the replayed log at $WORK/out and the verdicts in the GATE_POOL_*
# arrays.
run_case() {
  local jobs="$1" lanes_csv="$2"; shift 2
  GATE_POOL_GATES=("$@")
  GATE_POOL_LANE=()
  local i=0 g lane rest="$lanes_csv"
  for g in "$@"; do
    lane="${rest%%,*}"
    case "$rest" in *,*) rest="${rest#*,}" ;; *) rest="" ;; esac
    [ -n "$lane" ] || lane="pool"
    GATE_POOL_LANE+=("$lane")
    i=$((i + 1))
  done
  : >"$WORK/trace"
  _gate_pool_tmpdir=""
  gate_pool_init || { fail "gate_pool_init failed"; return 1; }
  gate_pool_run "$jobs" tw >"$WORK/out" 2>"$WORK/err"
  CASE_RC=$?
  return 0
}

# ---------------------------------------------------------------------------
# 1. Every gate runs once; replay is in LIST order regardless of finish order.
#    The first gate is the SLOWEST, so a naive "print as they finish" scheduler
#    would emit its block last and this assertion would catch it.
# ---------------------------------------------------------------------------
run_case 4 "" "pass:slowest:2" "pass:beta" "pass:gamma"
order="$(grep -c '^=== ' "$WORK/out")"
replayed="$(grep '^=== ' "$WORK/out" | tr '\n' '|')"
if [ "$order" = "3" ] && [ "$replayed" = "=== pass:slowest:2 ===|=== pass:beta ===|=== pass:gamma ===|" ]; then
  pass "every gate replayed exactly once, in LIST order (not completion order)"
else
  fail "replay order/count wrong: count=$order order=[$replayed]"
fi
if grep -q 'output of beta' "$WORK/out" && grep -q 'output of gamma' "$WORK/out"; then
  pass "each gate's captured output is replayed whole"
else
  fail "a gate's captured output is missing from the replay"
fi
if [ "$CASE_RC" -eq 0 ]; then
  pass "an all-passing run returns 0"
else
  fail "an all-passing run returned $CASE_RC"
fi

# ---------------------------------------------------------------------------
# 2. One failure among passes → non-zero, and only that gate is marked failed.
# ---------------------------------------------------------------------------
run_case 4 "" "pass:a" "fail:b" "pass:c"
if [ "$CASE_RC" -ne 0 ]; then
  pass "a run with one failing gate returns non-zero"
else
  fail "a run with a failing gate returned 0 — a LOST non-zero, the worst failure mode"
fi
if [ "${GATE_POOL_STATUS[0]}" = "pass" ] && [ "${GATE_POOL_STATUS[1]}" = "fail" ] \
  && [ "${GATE_POOL_STATUS[2]}" = "pass" ]; then
  pass "exactly the failing gate is marked failed"
else
  fail "verdicts misattributed: [${GATE_POOL_STATUS[0]} ${GATE_POOL_STATUS[1]} ${GATE_POOL_STATUS[2]}]"
fi

# ---------------------------------------------------------------------------
# 3. FAIL-CLOSED: a worker that exits 0 without writing a verdict is a FAILURE.
#    (A scheduler that treated "no news" as good news is exactly how a suite
#    silently stops gating.)
# ---------------------------------------------------------------------------
run_case 2 "" "pass:x" "nometa:y"
if [ "${GATE_POOL_STATUS[1]}" = "fail" ] && [ "$CASE_RC" -ne 0 ]; then
  pass "a verdict-less worker is recorded as a FAILURE, not a pass"
else
  fail "verdict-less worker recorded as [${GATE_POOL_STATUS[1]}], run rc=$CASE_RC"
fi
case "${GATE_POOL_NOTE[1]}" in
  *"verdict lost"* | *MISMATCH*) pass "the lost verdict is NAMED in the note, not silently swallowed" ;;
  *) fail "lost-verdict note is unhelpful: [${GATE_POOL_NOTE[1]}]" ;;
esac

# ---------------------------------------------------------------------------
# 4. A `deterministic` verdict survives the meta-file channel intact — the
#    retry classification must not be flattened to a plain fail by the pool.
# ---------------------------------------------------------------------------
run_case 2 "" "det:d"
if [ "${GATE_POOL_STATUS[0]}" = "deterministic" ] && [ "${GATE_POOL_NOTE[0]}" = "signature match" ]; then
  pass "a deterministic verdict + its note round-trip through the pool"
else
  fail "deterministic verdict lost: [${GATE_POOL_STATUS[0]}] note=[${GATE_POOL_NOTE[0]}]"
fi

# ---------------------------------------------------------------------------
# 5. SERIAL LANE: lane gates never overlap EACH OTHER, but do overlap the pool.
# ---------------------------------------------------------------------------
run_case 4 "serial,serial,pool,pool" "pass:lane1:2" "pass:lane2:2" "pass:p1:2" "pass:p2:2"
lane1_end="$(awk '$2=="lane1" && $3=="end" {print $1}' "$WORK/trace")"
lane2_start="$(awk '$2=="lane2" && $3=="start" {print $1}' "$WORK/trace")"
p1_start="$(awk '$2=="p1" && $3=="start" {print $1}' "$WORK/trace")"
lane1_start="$(awk '$2=="lane1" && $3=="start" {print $1}' "$WORK/trace")"
if [ -n "$lane1_end" ] && [ -n "$lane2_start" ] && [ "$lane2_start" -ge "$lane1_end" ]; then
  pass "two serial-lane gates never overlap each other"
else
  fail "serial-lane gates overlapped: lane1 ended $lane1_end, lane2 started $lane2_start"
fi
if [ -n "$p1_start" ] && [ -n "$lane1_start" ] && [ "$p1_start" -lt "$lane1_end" ]; then
  pass "a pool gate still overlaps the serial lane (pinning costs no wall time)"
else
  fail "the serial lane serialized the whole run: p1 started $p1_start, lane1 ended $lane1_end"
fi

# ---------------------------------------------------------------------------
# 6. `slow` gates are dispatched FIRST (longest-processing-time-first), so a
#    long gate at the end of the list cannot straggle past an idle pool.
# ---------------------------------------------------------------------------
run_case 1 "pool,pool,slow" "pass:head1" "pass:head2" "pass:tail"
first_started="$(awk '$3=="start" {print $2; exit}' "$WORK/trace")"
if [ "$first_started" = "tail" ]; then
  pass "a 'slow'-hinted gate is dispatched before ordinary pool gates"
else
  fail "'slow' hint ignored — first dispatched was [$first_started], expected tail"
fi
if [ "$(grep -c '^=== ' "$WORK/out")" = "3" ] \
  && [ "$(grep '^=== ' "$WORK/out" | head -1)" = "=== pass:head1 ===" ]; then
  pass "the 'slow' dispatch hint does NOT reorder the replay"
else
  fail "'slow' hint leaked into replay order"
fi

# ---------------------------------------------------------------------------
# 7. The pool is genuinely concurrent: 4 one-second gates at width 4 take about
#    a second, not four. This is the whole point of the change, so it is
#    asserted rather than assumed.
# ---------------------------------------------------------------------------
t0="$(date +%s)"
run_case 4 "" "pass:c1:1" "pass:c2:1" "pass:c3:1" "pass:c4:1"
elapsed=$(($(date +%s) - t0))
if [ "$elapsed" -le 2 ]; then
  pass "4x 1s gates at width 4 finished in ${elapsed}s (concurrent, not serialized)"
else
  fail "4x 1s gates at width 4 took ${elapsed}s — the pool is not running them concurrently"
fi
if [ "$GATE_POOL_SERIAL_SUM" -ge 4 ] && [ "$GATE_POOL_WALL" -le 2 ]; then
  pass "the measured serial-equivalent (${GATE_POOL_SERIAL_SUM}s) vs wall (${GATE_POOL_WALL}s) speedup is reported"
else
  fail "timing accounting wrong: serial_sum=$GATE_POOL_SERIAL_SUM wall=$GATE_POOL_WALL"
fi

# ---------------------------------------------------------------------------
# 8. A worker that dies ABRUPTLY still completes the run. The child publishes
#    its completion marker from an EXIT trap precisely so this cannot hang — a
#    hang would burn the whole CI job timeout and report nothing, which is worse
#    than any red gate. Guarded by a hard timeout so a regression FAILS rather
#    than wedging this suite.
# ---------------------------------------------------------------------------
(
  run_case 2 "" "pass:ok" "boom:dead"
  printf '%s\n' "$CASE_RC" >"$WORK/boom.rc"
  printf '%s\n' "${GATE_POOL_STATUS[1]}" >"$WORK/boom.status"
) &
boom_pid=$!
boom_waited=0
while kill -0 "$boom_pid" 2>/dev/null && [ "$boom_waited" -lt 20 ]; do
  sleep 1
  boom_waited=$((boom_waited + 1))
done
if kill -0 "$boom_pid" 2>/dev/null; then
  kill -9 "$boom_pid" 2>/dev/null
  fail "an abruptly-dying worker HUNG the pool (no completion marker published)"
else
  wait "$boom_pid" 2>/dev/null
  if [ "$(cat "$WORK/boom.status" 2>/dev/null)" = "fail" ] \
    && [ "$(cat "$WORK/boom.rc" 2>/dev/null)" != "0" ]; then
    pass "an abruptly-dying worker is recorded as a failure and never hangs the pool"
  else
    fail "abrupt worker death mis-recorded: status=[$(cat "$WORK/boom.status" 2>/dev/null)] rc=[$(cat "$WORK/boom.rc" 2>/dev/null)]"
  fi
fi

# ---------------------------------------------------------------------------
# 9. Jobs resolution.
# ---------------------------------------------------------------------------
auto="$(gate_pool_resolve_jobs auto)"
case "$auto" in
  '' | *[!0-9]*) fail "gate_pool_resolve_jobs auto returned non-numeric [$auto]" ;;
  *)
    if [ "$auto" -ge 1 ] && [ "$auto" -le 4 ]; then
      pass "auto resolves to a sane clamped worker count ($auto)"
    else
      fail "auto resolved to $auto, outside the measured clamp (see gate-pool.sh's _gate_pool_auto_cap: width 8 was both slower AND flakier than width 4 on a 10-core box)"
    fi
    ;;
esac
[ "$(gate_pool_resolve_jobs 6)" = "6" ] \
  && pass "an explicit integer is honored" \
  || fail "explicit integer not honored (the cap must apply to auto only, never to an explicit request): [$(gate_pool_resolve_jobs 6)]"
[ "$(gate_pool_resolve_jobs banana)" = "1" ] \
  && pass "an unparseable setting degrades to SERIAL, never to a guessed width" \
  || fail "unparseable jobs setting resolved to [$(gate_pool_resolve_jobs banana)]"
[ "$(gate_pool_resolve_jobs 0)" = "1" ] \
  && pass "0 workers clamps to 1" \
  || fail "0 resolved to [$(gate_pool_resolve_jobs 0)]"

# ---------------------------------------------------------------------------
# 10. WIRING. Guards against a future refactor that quietly re-inlines a loop
#     (leaving this whole suite testing dead code), drops the serial fallback,
#     or "simplifies" CI into a matrix — which would rename the required
#     `checks (ubuntu-latest)` status context and silently un-gate the branch.
# ---------------------------------------------------------------------------
if grep -q 'workflows/scripts/lib/gate-pool.sh' "$QG" \
  && grep -q 'gate_pool_run' "$QG" \
  && grep -q 'gate_pool_init' "$QG" \
  && grep -q 'gate_pool_resolve_jobs' "$QG"; then
  pass "quality-gates.sh sources gate-pool.sh and drives the scheduler"
else
  fail "quality-gates.sh no longer wires gate-pool.sh — the scheduler this suite covers is not the one that runs"
fi
if grep -q 'SERIAL_LANE_PINS' "$QG" && grep -q 'gate_lane_of' "$QG"; then
  pass "the audited serial-lane pin list is still wired into the classification"
else
  fail "SERIAL_LANE_PINS / gate_lane_of missing — shared-state gates would run concurrently"
fi
if grep -q 'gate_pool_ready' "$QG" && grep -q 'gate_run_with_retry "$gate" ||' "$QG"; then
  pass "the serial fallback loop is still present (QUALITY_GATES_JOBS=1 / no scratch)"
else
  fail "the serial fallback loop is gone — there is no always-correct path left"
fi
if grep -q 'QUALITY_GATES_JOBS' "$REPO_ROOT/workflows/scripts/build/build.config.sh"; then
  pass "the worker count is a config-named setting, not a literal in the loop"
else
  fail "QUALITY_GATES_JOBS is not declared in build.config.sh"
fi
# The required-status-context shape is a PER-REPO contract, not a kernel
# invariant. This assertion encodes the KERNEL's own single-entry matrix, whose
# job renders as the required context `checks (ubuntu-latest)`. A vendoring
# consumer (repo-root `.kernel-pin`) names its required context under its own
# ci.yml contract — foundation's, for instance, is a single NON-matrix job named
# `checks` — so holding a consumer to the kernel's shape can only ever produce a
# false failure (temperloop#1144). Scope the assertion to the kernel's own
# checkout; every other check in this section is a genuinely shared invariant
# and keeps running in a consumer.
#
# Since temperloop#2165 the workflow carries TWO jobs: `runner-preflight`, a
# hosted routing helper that picks `checks`'s `runs-on`, and `checks` itself,
# still on the single-entry matrix. A status context is named from the job name
# plus its matrix values — never from `runs-on` — so the preflight job does not
# move `checks (ubuntu-latest)`. The assertion therefore pins the exact job SET
# and the matrix line, rather than counting jobs.
if [ -f "$CI" ] && [ ! -f "$REPO_ROOT/.kernel-pin" ]; then
  ci_jobs="$(awk '/^jobs:/{f=1; next} f && /^  [a-z-]+:$/{sub(/^  /, ""); sub(/:$/, ""); print}' "$CI" | tr '\n' ' ')"
  if grep -q 'os: \[ubuntu-latest\]' "$CI" && [ "$ci_jobs" = "runner-preflight checks " ]; then
    pass "CI still runs the gate set as ONE matrix job, 'checks', behind the runner-preflight router (required context unchanged)"
  else
    fail "CI's job/matrix shape changed (jobs: '${ci_jobs}') — the required 'checks (ubuntu-latest)' context may have moved"
  fi
elif [ -f "$CI" ]; then
  skip "CI job/matrix shape — required-context shape is a per-repo contract (vendoring consumer, .kernel-pin present)"
fi

# ---------------------------------------------------------------------------
# 11. UNCHANGED EXECUTION ENVIRONMENT — the signal-disposition regression.
#
#     A parallel runner may not change what a gate OBSERVES, or "identical
#     pass/fail semantics" is a claim rather than a fact. bash sets SIGINT and
#     SIGQUIT to SIG_IGN in an asynchronous child when job control is off, and
#     hard-ignores them, so the disposition is inherited through fork AND exec
#     by the entire gate subtree and cannot be reset from inside it. That made
#     workflows/scripts/probe/tests/test_gh_call_logger.sh's fixture — the same
#     `kill -INT $$` shape used here — observe 0 instead of 130, failing the
#     `make test-conventions-probe` gate in CI deterministically.
#
#     This case is a SEMANTICS assertion, not a signal-handling curiosity: it
#     pins that a gate runs with the same disposition it did under the serial
#     loop.
#
#     DIFFERENTIAL, not absolute (temperloop#2094). The contract this defends
#     is "the POOL does not change what a gate observes" — a statement about
#     the delta between the serial shape and the pooled shape. The earlier
#     absolute form (`expect exactly 130`) silently asserted something else as
#     well: that the INVOKER handed this suite a DEFAULT SIGINT disposition.
#     It cannot, because SIG_IGN arrives from ABOVE. Launch the suite itself as
#     an asynchronous child of a job-control-off shell — `( … ) &`, `nohup`, an
#     agent harness's background Bash, any `trap '' INT` ancestor — and bash
#     hard-ignores SIGINT for this process and EVERY descendant, `set -m`
#     inside the pool included (a hard-ignore cannot be reset from inside the
#     process that inherited it). Both the serial and the pooled leg then
#     observe 0, the pool has changed nothing, and the absolute form still went
#     red — turning the whole 199-gate suite red for a property of its
#     caller. That is the temperloop#2094 blocker: it made every §3e.5
#     acceptance run on this host escalate `acceptance-gate-failed` for a
#     reason unrelated to the diff under test.
#
#     So: measure the SERIAL baseline in this very process first, then require
#     the POOLED leg to agree with it. When the baseline IS 130 (the invoker
#     left the disposition alone) the old absolute check still runs, unchanged
#     and just as strict — removing `set -m` from _gate_pool_spawn still turns
#     this red. When it is not, the absolute half reports itself as a SKIP
#     rather than vanishing, and the differential half keeps covering the
#     regression 694ddaf5 fixed.
# ---------------------------------------------------------------------------
# The serial baseline: the pre-pool shape, run in THIS process. Whatever this
# observes is what a gate run by the old `for` loop would have observed, so it
# is the only honest expectation for the pooled leg.
SIG_BASELINE=0
"$WORK/selfint.sh" || SIG_BASELINE=$?

rm -f "$WORK/sigcode"
run_case 2 "" "pass:presig" "sig:selfkill"
sig_observed="$(cat "$WORK/sigcode" 2>/dev/null)"
if [ "$sig_observed" = "$SIG_BASELINE" ]; then
  pass "the pool does not change the SIGINT disposition a gate sees (pooled [$sig_observed] = serial baseline [$SIG_BASELINE])"
else
  fail "SIGINT disposition changed by the pool: gate observed [$sig_observed], serial baseline is [$SIG_BASELINE] — an asynchronous child is inheriting SIG_IGN (see _gate_pool_spawn's 'set -m')"
fi
if [ "$SIG_BASELINE" = "130" ]; then
  if [ "$sig_observed" = "130" ]; then
    pass "a gate still sees the DEFAULT SIGINT disposition (self-kill observed as 130, not 0)"
  else
    fail "SIGINT disposition changed by the pool: gate observed [$sig_observed], expected 130 — an asynchronous child is inheriting SIG_IGN (see _gate_pool_spawn's 'set -m')"
  fi
else
  skip "absolute SIGINT disposition — this suite was INVOKED with SIGINT already ignored (serial baseline [$SIG_BASELINE], not 130), so 130 is unobservable from here; the differential check above still covers the pool (temperloop#2094)"
fi
if [ "${GATE_POOL_STATUS[1]}" = "pass" ] && [ "$CASE_RC" -eq 0 ]; then
  pass "the signal-asserting gate reaches its own verdict through the pool"
else
  fail "signal-asserting gate verdict=[${GATE_POOL_STATUS[1]}] rc=$CASE_RC note=[${GATE_POOL_NOTE[1]}]"
fi

# ---------------------------------------------------------------------------
# 11b. THE FIXTURE that pins 11's resolution (temperloop#2094).
#
#      11 above is now invoker-independent by construction; this is the check
#      that says so out loud, so the absolute form cannot silently return.
#
#      $WORK/sigprobe.sh is a self-contained miniature of 11: it sources the
#      SAME lib, runs the SAME `kill -INT $$` fixture twice — once directly
#      (the serial shape) and once through gate_pool_run — and prints
#      "<serial> <pooled>". Run it under two INVOCATION environments:
#
#        default   the disposition this suite itself was handed
#        ignored   SIGINT hard-ignored by an ancestor (`trap '' INT`), which
#                  is what a `( … ) &` / nohup / agent-background launch does
#
#      Both must report serial == pooled: the pool is transparent under EITHER
#      invocation. Under `default` the pooled leg must additionally be 130,
#      which is the original regression check — so deleting `set -m` from
#      _gate_pool_spawn still turns this red, while an inherited ignore cannot.
# ---------------------------------------------------------------------------
cat >"$WORK/sigprobe.sh" <<'PROBE'
#!/usr/bin/env bash
# <lib> <selfint> — print "<serial-rc> <pooled-rc>" for the self-kill fixture.
set -uo pipefail
lib="$1"; selfint="$2"
# shellcheck source=/dev/null
source "$lib"
serial_rc=0
"$selfint" || serial_rc=$?
probe_worker() {
  local rc=0
  "$selfint" || rc=$?
  printf '%s\n' "$rc" >"${GATE_POOL_META%.meta}.rc"
  printf 'pass\t1\t\n' >"$GATE_POOL_META"
  return 0
}
GATE_POOL_GATES=("sig")
GATE_POOL_LANE=("pool")
_gate_pool_tmpdir=""
gate_pool_init || { printf 'init-failed init-failed\n'; exit 2; }
gate_pool_run 1 probe_worker >/dev/null 2>&1
pooled_rc="$(cat "$_gate_pool_tmpdir/0.rc" 2>/dev/null)"
printf '%s %s\n' "$serial_rc" "${pooled_rc:-none}"
PROBE
chmod +x "$WORK/sigprobe.sh"

# The probe's stderr is KEPT, not discarded (review round 1): it is the only
# account of WHY a probe produced nothing, and a fixture whose failure mode is
# undiagnosable is one nobody can act on.
probe_default="$(bash "$WORK/sigprobe.sh" "$LIB" "$WORK/selfint.sh" 2>"$WORK/sigprobe.default.err")"
probe_ignored="$(bash -c 'trap "" INT; exec bash "$0" "$1" "$2"' \
  "$WORK/sigprobe.sh" "$LIB" "$WORK/selfint.sh" 2>"$WORK/sigprobe.ignored.err")"

# FAIL-CLOSED ON THE READING ITSELF (review round 1, temperloop#2094).
# Comparing "${p% *}" against "${p#* }" and nothing else is fail-OPEN: for any
# value carrying no space BOTH expansions return the whole string, so they are
# trivially equal. Two live paths reached that: the probe prints its own
# `init-failed init-failed` sentinel when gate_pool_init fails, and any death of
# sigprobe.sh before its final printf yields an EMPTY capture — a missing lib, an
# unbound variable, an unset "$1". Both reported GREEN, from the one fixture whose
# whole job is stopping the absolute form from silently returning. So the SHAPE is
# validated before the two halves are compared, per this suite's own FAIL-CLOSED
# clause: a reading that is not "<digits> <digits>" is a FAILURE, never a pass.
probe_reading_ok() { # <reading> — true only for two space-separated integers
  case "$1" in
    [0-9]*' '[0-9]*) return 0 ;;
    *) return 1 ;;
  esac
}
probe_why() { # <errfile> — a one-line account of a probe that produced nothing
  if [ -s "$1" ]; then
    printf ' — probe stderr: %s' "$(tr '\n' ' ' <"$1")"
  else
    printf ' — probe wrote nothing to stderr'
  fi
}

if ! probe_reading_ok "$probe_default"; then
  fail "sigprobe produced no usable reading under the DEFAULT invocation: [$probe_default]$(probe_why "$WORK/sigprobe.default.err")"
elif [ "${probe_default% *}" = "${probe_default#* }" ]; then
  pass "pool transparency holds under the invoker's own disposition (serial/pooled: $probe_default)"
else
  fail "the pool changed the disposition under the default invocation (serial/pooled: $probe_default)"
fi
if ! probe_reading_ok "$probe_ignored"; then
  fail "sigprobe produced no usable reading under an inherited SIG_IGN: [$probe_ignored]$(probe_why "$WORK/sigprobe.ignored.err")"
elif [ "${probe_ignored% *}" = "${probe_ignored#* }" ]; then
  pass "pool transparency holds when SIGINT is hard-ignored by an ANCESTOR (serial/pooled: $probe_ignored) — a backgrounded suite can no longer false-fail (temperloop#2094)"
else
  fail "the pool changed the disposition under an inherited SIG_IGN (serial/pooled: $probe_ignored)"
fi
if [ "$SIG_BASELINE" = "130" ]; then
  if [ "$probe_default" = "130 130" ]; then
    pass "under a DEFAULT invocation the pooled fixture still dies of SIGINT (130) — the 694ddaf5 regression check is intact"
  else
    fail "under a DEFAULT invocation the pooled fixture reported [$probe_default], expected [130 130] — 'set -m' is not reaching the fork"
  fi
  if [ "$probe_ignored" = "0 0" ]; then
    pass "under an inherited SIG_IGN both legs observe 0 — the suite reports the INVOKER's disposition, it does not fail over it"
  else
    fail "under an inherited SIG_IGN the fixture reported [$probe_ignored], expected [0 0]"
  fi
else
  skip "the absolute half of the 2094 fixture — this suite was itself invoked with SIGINT ignored (baseline [$SIG_BASELINE]); the two transparency checks above still ran"
fi

# The job control the fix relies on is scoped to the fork — a sourced lib must
# not leave the caller's shell in a mode it never asked for.
case "$-" in
  *m*) fail "gate_pool_run left job control (set -m) enabled in the caller's shell" ;;
  *) pass "the pool restores the caller's job-control setting after forking" ;;
esac

echo "---"
if [ "$fail_count" -eq 0 ]; then
  echo "OK — all gate-pool checks passed"
else
  echo "$fail_count check(s) failed"
fi
[ "$fail_count" -eq 0 ]
