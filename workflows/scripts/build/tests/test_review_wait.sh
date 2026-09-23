#!/usr/bin/env bash
#
# test_review_wait.sh — workflows/scripts/build/review-wait.sh, the §3e review
# ceiling's wall-clock tick (temperloop#2049).
#
# WHAT THIS GATE IS FOR. The defect it locks down is not "the timer is wrong by
# a bit" — it is "the timer did not wait AT ALL and said it had". So the
# load-bearing assertions are about REALIZED WALL CLOCK, measured by this test
# against its own `date`, never taken from the script's own report:
#
#   1. a wait of N seconds takes at LEAST N seconds of real wall clock;
#   2. the JSON line appears ONLY after the interval — a run cut short prints
#      nothing at all (the discrimination control: it is what makes #1 mean
#      something, since a script that printed instantly would pass a
#      "prints valid JSON" check just as well);
#   3. `realized_secs` is a MEASUREMENT (>= the interval), which is the field
#      claude/workflows/build-level.mjs audits an elapse against;
#   4. a bad argument is REFUSED, never silently treated as a zero-length wait.
#
# Runs in a few seconds: every interval here is small on purpose. The intervals
# the pipeline actually asks for (the SLOW mark, then ceiling slices) are the
# caller's business — review-wait.sh carries no ceiling of its own.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd)"
WAIT_SH="$REPO_ROOT/workflows/scripts/build/review-wait.sh"

# SCRATCH LIVES OUTSIDE THE REPO TREE (temperloop#2162). Case 3 below needs a
# file to capture an interrupted run's stdout, and it used to put that file in
# $HERE — i.e. INSIDE the checkout, under a git-tracked directory. That was
# harmless while this suite ran serially inside `make test-build`'s single
# gate-pool slot. temperloop#2162 split that umbrella into ~73 per-script gates
# that the pool runs CONCURRENTLY, and the transient file immediately collided
# with a sibling gate that reads GLOBAL state: bin/subcommands/tests/
# test_tokens_producer.sh case 15 asserts the whole repo's `git status` is
# unchanged across its own run, and it went red naming
# `.review-wait-early.<pid>` — a real coupling through the working tree,
# reproduced at 32-way concurrency. A `mktemp -d` has no such reach, and the
# assertions below are indifferent to where the file lives.
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/test-review-wait-XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT

FAILED=0
pass() { printf 'ok   — %s\n' "$1"; }
fail() { printf 'FAIL — %s\n' "$1" >&2; FAILED=1; }

[ -x "$WAIT_SH" ] || { fail "review-wait.sh missing or not executable at $WAIT_SH"; exit 1; }

# --- 1. the wait is REAL -----------------------------------------------------
# Measured against this test's own clock, not the script's self-report.
start="$(date +%s)"
out="$("$WAIT_SH" 4)"
realized=$(( $(date +%s) - start ))
if [ "$realized" -ge 4 ]; then
  pass "a 4s wait consumes at least 4s of real wall clock (measured ${realized}s)"
else
  fail "a 4s wait returned after only ${realized}s — this is temperloop#2049 verbatim: the ceiling would fire ~40x early"
fi

# --- 2. the report is well formed and is a MEASUREMENT -----------------------
case "$out" in
  *'"outcome":"REVIEW_WAIT_ELAPSED"'*) pass "prints the REVIEW_WAIT_ELAPSED outcome the executor relays" ;;
  *) fail "expected a REVIEW_WAIT_ELAPSED line, got: $out" ;;
esac
case "$out" in
  *'"secs":4'*) pass "echoes the interval it was asked for" ;;
  *) fail "expected the requested interval echoed as secs:4, got: $out" ;;
esac
reported="$(printf '%s' "$out" | sed -E 's/.*"realized_secs":([0-9]+).*/\1/')"
case "$reported" in
  '' | *[!0-9]*) fail "realized_secs is absent or non-numeric — the .mjs audits the elapse against it: $out" ;;
  *)
    if [ "$reported" -ge 4 ]; then
      pass "realized_secs (${reported}) is a measurement that reaches the interval"
    else
      fail "realized_secs (${reported}) is below the interval it waited — the .mjs would refuse this tick: $out"
    fi
    ;;
esac
if printf '%s' "$out" | grep -c '^{.*}$' >/dev/null 2>&1; then
  pass "the report is a single JSON object line"
else
  fail "the report is not a single JSON object line: $out"
fi

# --- 3. DISCRIMINATION CONTROL: nothing is printed BEFORE the interval -------
# Without this, assertion 1 could be satisfied by a script that slept and then
# printed regardless — and a script that printed FIRST and slept after would be
# indistinguishable from a correct one to every other check here. Cut a long
# wait short and require that it produced NO elapsed line.
"$WAIT_SH" 60 > "$SCRATCH/review-wait-early.out" 2>/dev/null &
early_pid=$!
sleep 3
kill -9 "$early_pid" 2>/dev/null
wait "$early_pid" 2>/dev/null
early_out="$(cat "$SCRATCH/review-wait-early.out" 2>/dev/null || true)"
rm -f "$SCRATCH/review-wait-early.out"
case "$early_out" in
  *REVIEW_WAIT_ELAPSED*)
    fail "an interrupted 60s wait reported REVIEW_WAIT_ELAPSED after 3s — the line must follow the interval, never precede it: $early_out" ;;
  *)
    pass "a wait cut short prints no elapsed line (the control that arms the timing assertion)" ;;
esac

# --- 4. bad arguments are REFUSED, never a zero-length wait ------------------
for bad in "0" "-5" "abc" "4.5" ""; do
  if [ -z "$bad" ]; then
    bad_out="$("$WAIT_SH" 2>&1)"; rc=$?
    label="no argument"
  else
    bad_out="$("$WAIT_SH" "$bad" 2>&1)"; rc=$?
    label="argument '$bad'"
  fi
  if [ "$rc" -eq 0 ]; then
    fail "$label was accepted (exit 0) — a malformed interval must never read as a completed wait: $bad_out"
  elif printf '%s' "$bad_out" | grep 'REVIEW_WAIT_ELAPSED' >/dev/null; then
    fail "$label produced an ELAPSED line: $bad_out"
  else
    pass "$label is refused with a non-zero exit and no elapsed line"
  fi
done

# Too many arguments (the caller passes exactly one).
if two_out="$("$WAIT_SH" 1 2 2>&1)"; then
  fail "two arguments were accepted — the contract is exactly one: $two_out"
else
  pass "a second argument is refused"
fi

if [ "$FAILED" -eq 0 ]; then
  echo "PASS: review-wait.sh — the wait is real, measured, and refuses a malformed interval (temperloop#2049)"
  exit 0
fi
echo "FAIL: review-wait.sh gate" >&2
exit 1
