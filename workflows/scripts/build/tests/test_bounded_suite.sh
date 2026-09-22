#!/usr/bin/env bash
#
# test_bounded_suite.sh — the RED/GREEN proof for workflows/scripts/build/
# bounded-suite.sh, the wall-clock guard on `make test-build-workflow` and
# `make test-build` (temperloop#2184).
#
# WHAT IS ACTUALLY BEING PROVEN, and why each case exists:
#
#   1  a healthy run is byte-identical: same stdout, same stderr (the two
#      streams are NOT merged by the wrapper), same exit code.
#   2  a non-zero exit passes straight through, unchanged.
#   3  a HANG terminates at the bound, exits non-zero, NAMES THE CASE THAT WAS
#      RUNNING (not the last one that passed — that confusion is the defect
#      this item names), and reaps the suite's whole PROCESS GROUP so no
#      orphaned tree outlives the failure.
#   4  the same naming works for a suite section that announces nothing until
#      it passes, via source-order derivation (--case-source), for BOTH case
#      declaration forms the real suite uses.
#   5  BSD/macOS dialect: the bound still holds with NEITHER `timeout` nor
#      `gtimeout` on PATH. temperloop is the kernel repo and a stranger's
#      stock macOS has neither, so a guard that silently needed one would be a
#      guarantee that evaporates exactly where it is most needed. The stripped
#      PATH is mandatory rather than trusting whatever this dev box has
#      installed (this host HAS Homebrew coreutils, so the gap would be
#      invisible otherwise) — the same reasoning as test_pipeline_cron.sh's
#      wrapper 32.
#   6  DISCRIMINATION: a mutant of the guard with its bound check neutralised
#      does NOT terminate the same hang. Without this, case 3's "it exited
#      137" would prove nothing — a fixture that happened to end on its own
#      would produce the same green.
#   7  a `0` / non-numeric bound is rejected back to the default AND reported,
#      never honored (honoring `0` means either no bound at all — this item's
#      own defect via a typo — or killing every healthy run instantly).
#   8  static lockstep: both Makefile targets actually route through the guard,
#      the bound is a NAMED SETTING rather than a literal in the recipe, and
#      test_workflow.sh still writes the progress breadcrumb. A node/shell
#      behaviour case cannot see wiring that was deleted from the Makefile.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && cd ../../../.. && pwd)"
GUARD="$REPO_ROOT/workflows/scripts/build/bounded-suite.sh"
MAKEFILE="$REPO_ROOT/Makefile"
CONFIG="$REPO_ROOT/workflows/scripts/build/build.config.sh"
WORKFLOW_SUITE="$REPO_ROOT/workflows/scripts/build/tests/test_workflow.sh"

[ -f "$GUARD" ] || { echo "FAIL: bounded-suite.sh not found at $GUARD" >&2; exit 1; }

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/test-bounded-suite.XXXXXX")"
STRAY_PIDS=()
cleanup() {
  local p
  for p in ${STRAY_PIDS[@]+"${STRAY_PIDS[@]}"}; do
    kill -9 "$p" 2>/dev/null
  done
  rm -rf "$TMPD"
  return 0
}
trap cleanup EXIT INT TERM

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "PASS: $1"; }

# ---------------------------------------------------------------------------
# 1 + 2: a healthy run is transparent — stdout, stderr and exit code unchanged
# ---------------------------------------------------------------------------
cat > "$TMPD/healthy.sh" <<'EOF'
#!/usr/bin/env bash
echo "PASS: first case"
echo "noise on stderr" >&2
echo "PASS: second case"
exit "${FIXTURE_RC:-0}"
EOF

OUT="$TMPD/o1"; ERR="$TMPD/e1"; rc=0
BUILD_SUITE_TIMEOUT_SECS=60 bash "$GUARD" --label healthy -- bash "$TMPD/healthy.sh" \
  >"$OUT" 2>"$ERR" || rc=$?
[ "$rc" -eq 0 ] || fail "1: a healthy run must exit 0, got $rc (stderr: $(cat "$ERR"))"
printf 'PASS: first case\nPASS: second case\n' > "$TMPD/expected-out"
diff -u "$TMPD/expected-out" "$OUT" >/dev/null \
  || fail "1: stdout was altered by the wrapper: $(diff -u "$TMPD/expected-out" "$OUT")"
[ "$(cat "$ERR")" = "noise on stderr" ] \
  || fail "1: stderr must pass through unmerged and unchanged, got: $(cat "$ERR")"
pass "1 a healthy run is transparent — identical stdout, identical stderr (the wrapper does NOT merge the two streams), exit 0"

rc=0
FIXTURE_RC=3 BUILD_SUITE_TIMEOUT_SECS=60 bash "$GUARD" --label healthy -- bash "$TMPD/healthy.sh" \
  >/dev/null 2>/dev/null || rc=$?
[ "$rc" -eq 3 ] || fail "2: the wrapped command's own exit code must pass through, expected 3 got $rc"
pass "2 a failing suite's own exit code passes straight through (3, not the wrapper's own)"

# The shared hanging fixture: announces one case as PASSED, declares a SECOND
# as in flight, forks a grandchild, then stalls forever.
GRANDCHILD_FILE="$TMPD/grandchild.pid"
cat > "$TMPD/hang.sh" <<EOF
#!/usr/bin/env bash
echo "PASS: case-one the one that finished"
printf '%s\n' "case-two the one that stalled" > "\${SUITE_PROGRESS_FILE:-/dev/null}"
sleep 300 &
printf '%s\n' "\$!" > "$GRANDCHILD_FILE"
sleep 300
EOF

# ---------------------------------------------------------------------------
# 2b: the guard reads its bound from build.config.sh WITHOUT leaking that
#     file's ~200 exported settings into the suite's environment
# ---------------------------------------------------------------------------
# Not a hypothetical: sourcing build.config.sh in the guard's own shell turned
# test_dual_build_preflight.sh's "no build.config.sh sibling, so the ceiling is
# unset" fixture red, because the ceiling was no longer unset. A test runner
# that silently rewrites the environment its tests run in is worse than the
# hang it was added to catch.
CFGDIR="$TMPD/cfgdir"
mkdir -p "$CFGDIR"
cp "$GUARD" "$CFGDIR/bounded-suite.sh"
cat > "$CFGDIR/build.config.sh" <<'EOF'
#!/usr/bin/env bash
: "${BUILD_SUITE_TIMEOUT_SECS:=2}"
: "${LEAK_CANARY_SETTING:=leaked}"
export BUILD_SUITE_TIMEOUT_SECS LEAK_CANARY_SETTING
EOF

canary="$(env -u BUILD_SUITE_TIMEOUT_SECS bash "$CFGDIR/bounded-suite.sh" --label cfg -- \
  bash -c 'printf "%s" "${LEAK_CANARY_SETTING:-<unset>}"' 2>/dev/null)"
[ "$canary" = "<unset>" ] \
  || fail "2b: build.config.sh's exports leaked into the suite's environment (LEAK_CANARY_SETTING=$canary) — every test now runs under a rewritten environment"

rc=0
t0=$SECONDS
env -u BUILD_SUITE_TIMEOUT_SECS bash "$CFGDIR/bounded-suite.sh" --label cfg -- bash "$TMPD/hang.sh" \
  >/dev/null 2>/dev/null || rc=$?
cfg_elapsed=$((SECONDS - t0))
[ "$rc" -eq 137 ] \
  || fail "2b: the bound must come FROM build.config.sh when the env does not set it (expected 137, got $rc after ${cfg_elapsed}s)"
[ "$cfg_elapsed" -lt 20 ] \
  || fail "2b: the config's 2s bound was not honored — took ${cfg_elapsed}s, so the guard fell through to its own 1800s fallback"
gc="$(cat "$GRANDCHILD_FILE" 2>/dev/null)"
[ -n "$gc" ] && STRAY_PIDS+=("$gc")
pass "2b the bound is read from build.config.sh (a 2s config value is honored) and NONE of that file's other exported settings reach the suite's environment"

# ---------------------------------------------------------------------------
# 3: a hang is bounded, NAMES THE RUNNING CASE, and reaps the process group
# ---------------------------------------------------------------------------
OUT="$TMPD/o3"; ERR="$TMPD/e3"; rc=0
t0=$SECONDS
BUILD_SUITE_TIMEOUT_SECS=2 bash "$GUARD" --label test-build-workflow -- bash "$TMPD/hang.sh" \
  >"$OUT" 2>"$ERR" || rc=$?
elapsed=$((SECONDS - t0))

[ "$rc" -ne 0 ] || fail "3: a hang must FAIL LOUDLY — the wrapper exited 0"
[ "$rc" -eq 137 ] || fail "3: a timeout must exit 137 (the portable-timeout.sh convention), got $rc"
[ "$elapsed" -lt 30 ] \
  || fail "3: the bound did not hold — a 2s bound took ${elapsed}s to terminate the hang"
grep -q 'TIMEOUT' "$ERR" || fail "3: the failure must be loud on stderr; got: $(cat "$ERR")"

running_line="$(grep -A1 'CASE THAT WAS RUNNING' "$ERR" | tail -1)"
case "$running_line" in
  *"case-two the one that stalled"*) : ;;
  *) fail "3: the report must NAME the running case; the line under 'CASE THAT WAS RUNNING' was: $running_line" ;;
esac
case "$running_line" in
  *case-one*) fail "3: the running-case line named the COMPLETED case — that is the exact defect this item fixes: $running_line" ;;
esac
completed_line="$(grep -A1 'COMPLETED before it' "$ERR" | tail -1)"
case "$completed_line" in
  *"case-one the one that finished"*) : ;;
  *) fail "3: the report must also show the last COMPLETED case, separately and labelled as such; got: $completed_line" ;;
esac
grep -q 'BUILD_SUITE_TIMEOUT_SECS' "$ERR" \
  || fail "3: the report must name the setting that fired, so the bound is raisable without editing a recipe"

gc="$(cat "$GRANDCHILD_FILE" 2>/dev/null)"
[ -n "$gc" ] || fail "3: fixture never recorded its grandchild pid — the reaping half proves nothing"
STRAY_PIDS+=("$gc")
sleep 1
if kill -0 "$gc" 2>/dev/null; then
  fail "3: grandchild $gc survived the bound — the guard orphaned a process tree, which is half of the observed incident"
fi
pass "3 a hang terminates at the bound with a loud non-zero exit, the report NAMES the running case (and shows the completed one separately, labelled), and the whole process group — grandchildren included — is reaped"

# ---------------------------------------------------------------------------
# 4: source-order derivation names an inline section that announced nothing
# ---------------------------------------------------------------------------
cat > "$TMPD/silent-hang.sh" <<'EOF'
#!/usr/bin/env bash
echo "PASS: alpha the first inline section"
sleep 300
EOF
# The case-source carries BOTH declaration forms the real suite uses: a
# col-0 `echo "PASS: …"` (the inline sections) and a col-0 `run_node_case "…"`
# (the 253 node cases). The hang lands in the section that would have ended
# with the SECOND declaration, so that is the one the guard must name.
cat > "$TMPD/case-source.sh" <<'EOF'
#!/usr/bin/env bash
echo "PASS: alpha the first inline section"
run_node_case "gamma the node case that stalled" "
  const x = 1;
"
EOF

ERR="$TMPD/e4"; rc=0
BUILD_SUITE_TIMEOUT_SECS=2 bash "$GUARD" --label test-build-workflow \
  --case-source "$TMPD/case-source.sh" -- bash "$TMPD/silent-hang.sh" \
  >/dev/null 2>"$ERR" || rc=$?
[ "$rc" -eq 137 ] || fail "4: expected a 137 timeout, got $rc"
running_line="$(grep -A1 'CASE THAT WAS RUNNING' "$ERR" | tail -1)"
case "$running_line" in
  *"gamma the node case that stalled"*) : ;;
  *) fail "4: source-order derivation must name the NEXT declared case; got: $running_line" ;;
esac
case "$running_line" in
  *alpha*) fail "4: derivation named the case that already PASSED: $running_line" ;;
esac
grep -q 'derived from' "$ERR" \
  || fail "4: the report must say which source resolved the name, so a derived name is never mistaken for an observed one"
pass "4 a stall in a section that announces nothing is still named, by source-order derivation over both declaration forms, and the report labels the name as derived"

# ---------------------------------------------------------------------------
# 5: BSD/macOS dialect — the bound holds with no GNU timeout/gtimeout on PATH
# ---------------------------------------------------------------------------
NOGNU_BIN="$TMPD/nognu-bin"
mkdir -p "$NOGNU_BIN"
for _t in bash sh env date ps wc tail tr sed grep awk sleep kill mktemp rm cat \
          mkdir basename dirname printf true false head cut uname id diff; do
  _p="$(command -v "$_t" 2>/dev/null || true)"
  [ -n "$_p" ] && ln -sf "$_p" "$NOGNU_BIN/$_t"
done
if ( PATH="$NOGNU_BIN"; command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1 ); then
  fail "5: timeout/gtimeout still resolve on the stripped PATH — the dependency-free path was NOT exercised, so this case proves nothing"
fi

ERR="$TMPD/e5"; rc=0
t0=$SECONDS
PATH="$NOGNU_BIN" BUILD_SUITE_TIMEOUT_SECS=2 bash "$GUARD" --label test-build -- bash "$TMPD/hang.sh" \
  >/dev/null 2>"$ERR" || rc=$?
elapsed=$((SECONDS - t0))
[ "$rc" -eq 137 ] || fail "5: the bound vanished without GNU coreutils — expected 137, got $rc"
[ "$elapsed" -lt 30 ] || fail "5: the bound took ${elapsed}s with no GNU timeout on PATH"
running_line="$(grep -A1 'CASE THAT WAS RUNNING' "$ERR" | tail -1)"
case "$running_line" in
  *"case-two the one that stalled"*) : ;;
  *) fail "5: the running-case name must survive the stripped PATH too; got: $running_line" ;;
esac
gc="$(cat "$GRANDCHILD_FILE" 2>/dev/null)"
[ -n "$gc" ] && STRAY_PIDS+=("$gc")
pass "5 the bound, the naming and the exit code are identical on a stock macOS with NEITHER timeout(1) nor gtimeout installed — the guard depends on no GNU binary"

# ---------------------------------------------------------------------------
# 6: DISCRIMINATION — without the bound check, the same hang is NOT terminated
# ---------------------------------------------------------------------------
# RED/GREEN over one fixture that sleeps LONGER than the bound but does finish
# on its own, so both arms terminate and the difference is unambiguous:
#   real guard  -> killed at the bound, well before the fixture would end
#   mutant      -> runs to the fixture's own end, i.e. bounded by nothing
MUTANT="$TMPD/mutant-guard.sh"
sed 's/-ge "\$bound"/-ge 999999/' "$GUARD" > "$MUTANT"
if diff -q "$GUARD" "$MUTANT" >/dev/null 2>&1; then
  fail "6: mutant splice failed — the bound comparison was not found in its expected shape, so this discrimination proof is inert"
fi

cat > "$TMPD/short-hang.sh" <<'EOF'
#!/usr/bin/env bash
echo "PASS: case-one the one that finished"
printf '%s\n' "case-two the one that stalled" > "${SUITE_PROGRESS_FILE:-/dev/null}"
sleep 8
EOF

rc=0
t0=$SECONDS
BUILD_SUITE_TIMEOUT_SECS=2 bash "$GUARD" --label green -- bash "$TMPD/short-hang.sh" \
  >/dev/null 2>"$TMPD/e6-green" || rc=$?
green_elapsed=$((SECONDS - t0))
[ "$rc" -eq 137 ] || fail "6: GREEN arm — the real guard must kill the over-running fixture (expected 137, got $rc)"
[ "$green_elapsed" -lt 8 ] \
  || fail "6: GREEN arm — the guard took ${green_elapsed}s, i.e. it waited for the fixture instead of bounding it"

mrc=0
t0=$SECONDS
BUILD_SUITE_TIMEOUT_SECS=2 bash "$MUTANT" --label red -- bash "$TMPD/short-hang.sh" \
  >/dev/null 2>"$TMPD/e6-red" || mrc=$?
red_elapsed=$((SECONDS - t0))
[ "$mrc" -eq 0 ] \
  || fail "6: RED arm — with the bound spliced out the guard should have returned the fixture's own exit code, got $mrc"
[ "$red_elapsed" -ge 7 ] \
  || fail "6: RED arm — the mutant returned in ${red_elapsed}s, so something OTHER than the bound comparison is terminating the run and case 3 proves nothing"
grep -q 'TIMEOUT' "$TMPD/e6-red" \
  && fail "6: RED arm — the mutant still reported a timeout; the splice did not remove the behaviour under test"
pass "6 discrimination: splice the bound comparison out and the identical over-running fixture runs to its own end unbounded (${red_elapsed}s, exit 0); restore it and the same fixture is killed at the bound (${green_elapsed}s, exit 137) — case 3's 137 is produced by the guard, not by the fixture"

# ---------------------------------------------------------------------------
# 7: a 0 / non-numeric bound is rejected back to the default AND reported
# ---------------------------------------------------------------------------
# NOTE the set: `0` and a non-numeric value are REJECTED and reported. An
# EMPTY value is deliberately NOT in this set — under build.config.sh's
# documented `: "${VAR:=default}"` idiom, null and unset are the same thing
# and correctly take the configured default, silently. That is the config
# precedence ladder working, not a rejection, and it is asserted separately
# below.
for badval in 0 abc; do
  ERR="$TMPD/e7"; rc=0
  BUILD_SUITE_TIMEOUT_SECS="$badval" bash "$GUARD" --label badbound -- bash "$TMPD/healthy.sh" \
    >/dev/null 2>"$ERR" || rc=$?
  [ "$rc" -eq 0 ] \
    || fail "7: a rejected bound must not kill a HEALTHY run (BUILD_SUITE_TIMEOUT_SECS='$badval' exited $rc)"
  grep -q 'not a positive integer' "$ERR" \
    || fail "7: the rejected value must be REPORTED, not silently corrected (BUILD_SUITE_TIMEOUT_SECS='$badval'); stderr: $(cat "$ERR")"
done
ERR="$TMPD/e7-empty"; rc=0
BUILD_SUITE_TIMEOUT_SECS="" bash "$GUARD" --label emptybound -- bash "$TMPD/healthy.sh" \
  >/dev/null 2>"$ERR" || rc=$?
[ "$rc" -eq 0 ] || fail "7: an EMPTY bound must take the configured default, got exit $rc"
grep -q 'not a positive integer' "$ERR" \
  && fail "7: an EMPTY bound is not an invalid value — null and unset are the same under the ':=' idiom, so it must take the default SILENTLY"
pass "7 a 0 / non-numeric bound is refused back to the default and the refusal is REPORTED — never honored as 'no bound' (this item's own defect via a typo) and never as 'kill instantly'; an empty value is not a rejection and takes the default silently, per the ':=' precedence idiom"

# ---------------------------------------------------------------------------
# 8: static lockstep — the wiring a behaviour case cannot see
# ---------------------------------------------------------------------------
grep -q 'bounded-suite.sh --label test-build-workflow' "$MAKEFILE" \
  || fail "8: the Makefile's test-build-workflow target must run through bounded-suite.sh — an unwired guard bounds nothing"
grep -q 'bounded-suite.sh --label test-build ' "$MAKEFILE" \
  || fail "8: the Makefile's test-build target must run through bounded-suite.sh too — it has the identical gap"
grep -q -- '--case-source \$(BUILD_SRC)/tests/test_workflow.sh' "$MAKEFILE" \
  || fail "8: test-build-workflow must pass --case-source, or a stall in an inline section cannot be named"
grep -q '^: "\${BUILD_SUITE_TIMEOUT_SECS:=' "$CONFIG" \
  || fail "8: BUILD_SUITE_TIMEOUT_SECS must be defined in build.config.sh — the bound is a NAMED SETTING, not a literal (CLAUDE.kernel.md § Named-setting convention)"
grep -q 'BUILD_SUITE_TIMEOUT_SECS' "$GUARD" \
  || fail "8: the guard must READ the named setting"
if grep -nE 'bounded-suite\.sh.*[0-9]{2,}' "$MAKEFILE" | grep -v 'BUILD_SRC' >/dev/null 2>&1; then
  fail "8: a bound literal leaked into a Makefile recipe — the value belongs in build.config.sh"
fi
grep -q 'wf_progress "\$desc"' "$WORKFLOW_SUITE" \
  || fail "8: test_workflow.sh's run_node_case must write the progress breadcrumb at case START, or the guard cannot name a node case"
grep -q 'wf_progress ""' "$WORKFLOW_SUITE" \
  || fail "8: run_node_case must CLEAR the breadcrumb at case end, or a stall in the inline section AFTER a case is misattributed to that case"
pass "8 static lockstep: both Makefile targets route through the guard, the bound lives in build.config.sh rather than in a recipe literal, and test_workflow.sh sets and clears the breadcrumb"

echo ""
echo "All test_bounded_suite.sh cases passed."
