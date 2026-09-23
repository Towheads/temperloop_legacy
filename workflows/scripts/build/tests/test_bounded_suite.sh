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
#   9  SIGNAL PATH: interrupting the WRAPPER leaves NO surviving suite
#      processes, for the FULL signal set the repo's own convention uses
#      (sandbox.sh's EXIT/HUP/INT/TERM) plus QUIT: SIGHUP, SIGINT, SIGQUIT and
#      SIGTERM, each with its own green arm AND its own RED arm. `set -m` takes
#      the suite out of make's foreground group, so a handler that merely
#      exited would leave the tree running fully detached — this item's own
#      defect class through a second door, and the signal would become WORSE
#      than before the wrapper existed. For an UNARMED signal it is worse
#      again: bash's default disposition kills the wrapper, and the bound IS
#      the wrapper's poll loop, so the unbounded forever-hang comes back.
#  10  NO FLAKY EXIT: the exit-code handoff is atomic, so a green suite can
#      never intermittently be reported non-zero. Shown, not asserted: a
#      watcher races the file, and a mutant restoring the create-before-write
#      ordering deterministically misreports a passing fixture as exit 1.
#  11  REPORT HONESTY: the timeout report does not claim whole-group reaping on
#      the SINGLE-PID fallback path (where $pgid was blanked and only the direct
#      child was signalled). It says job control did not isolate the suite,
#      names the one pid it killed, and sends the operator to `ps` — while the
#      normal path still makes the strong claim, so the case cannot be passed by
#      deleting the sentence.

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
# 9: SIGNAL PATH — interrupting the WRAPPER must leave no surviving suite
# ---------------------------------------------------------------------------
# THIS IS THE ITEM'S OWN DEFECT CLASS, reached through a second door. `set -m`
# puts the suite in its OWN process group, which is what lets the bound reap
# the whole tree — but it also takes the suite OUT of make's foreground group,
# so a terminal Ctrl-C no longer reaches it. A wrapper whose INT/TERM handlers
# merely exited would therefore leave the entire suite tree running FULLY
# DETACHED, i.e. exactly the orphaned process trees the ~50h incident left
# behind — and would make Ctrl-C strictly WORSE than before this wrapper
# existed, when make's own process group still caught it.
#
# The fixture records BOTH its own pid and a forked grandchild's, so "gone" is
# asserted over the whole tree rather than just the direct child.
SIG_SELF="$TMPD/sig.self.pid"
SIG_GC="$TMPD/sig.gc.pid"
cat > "$TMPD/sig-hang.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$\$" > "$SIG_SELF"
echo "PASS: case-one the one that finished"
sleep 300 &
printf '%s\n' "\$!" > "$SIG_GC"
sleep 300
EOF

SIG_RC=0
SIG_SELF_PID=""
SIG_GC_PID=""
# Launch $1 on the hanging fixture, wait until the tree is genuinely up, send
# it SIG$2, and leave the outcome in SIG_RC / SIG_SELF_PID / SIG_GC_PID.
sig_launch_and_signal() {
  local guard="$1" signame="$2" wpid i=0
  rm -f "$SIG_SELF" "$SIG_GC"
  # `set -m` IS LOAD-BEARING HERE, not a copy-paste of the guard. A shell
  # WITHOUT job control sets SIGINT and SIGQUIT to SIG_IGN in every `&` child,
  # and bash cannot re-trap a signal that was ignored on entry — so launching
  # the wrapper from a plain background job would make it deaf to SIGINT, and
  # this case would "pass" against a wrapper that merely ignored the signal.
  # Job control puts the job in its own process group WITHOUT that ignore,
  # which is also how `make` runs the wrapper from a terminal. (Observed: the
  # INT arm sat out the fixture's whole sleep and returned 0 before this.)
  #
  # The bound is set SHORT deliberately: if a handler ever stops responding,
  # the guard's own bound ends the run in ~20s with a 137 that the rc
  # assertion below rejects, instead of this case hanging for 300s.
  set -m
  BUILD_SUITE_TIMEOUT_SECS=20 bash "$guard" --label "sig-$signame" -- \
    bash "$TMPD/sig-hang.sh" >/dev/null 2>&1 &
  wpid=$!
  set +m
  while [ "$i" -lt 100 ]; do
    [ -s "$SIG_GC" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  SIG_SELF_PID="$(cat "$SIG_SELF" 2>/dev/null)"
  SIG_GC_PID="$(cat "$SIG_GC" 2>/dev/null)"
  if [ -z "$SIG_SELF_PID" ] || [ -z "$SIG_GC_PID" ]; then
    kill -9 "$wpid" 2>/dev/null
    fail "9: the fixture never recorded its own pid AND its grandchild's — every survival assertion below would be vacuous"
  fi
  STRAY_PIDS+=("$SIG_SELF_PID" "$SIG_GC_PID" "$wpid")
  kill -0 "$SIG_SELF_PID" 2>/dev/null \
    || fail "9: the suite (pid $SIG_SELF_PID) was already dead BEFORE the signal — nothing was under test"
  kill -0 "$SIG_GC_PID" 2>/dev/null \
    || fail "9: the grandchild (pid $SIG_GC_PID) was already dead BEFORE the signal — nothing was under test"
  kill "-$signame" "$wpid" 2>/dev/null \
    || fail "9: could not send SIG$signame to the wrapper (pid $wpid)"
  SIG_RC=0
  wait "$wpid" || SIG_RC=$?
  # Give the kernel a beat to reap the tree before asking whether it is gone.
  sleep 1
  return 0
}

# THE SIGNAL SET IS THE REPO'S OWN CONVENTION, not a subset of it.
# workflows/scripts/tests/lib/sandbox.sh installs EXIT/HUP/INT/TERM and says so
# in its header; bounded-suite.sh arming only INT/TERM was a divergence with
# teeth. SIGHUP is the live gap — closing a terminal or dropping an SSH session
# hangs up the wrapper, and an UNARMED HUP kills it outright, which is strictly
# WORSE than no wrapper at all on two counts: (a) `set -m` already moved the
# suite out of make's foreground group, so it survives fully detached where a
# pre-wrapper run would have died with the group, and (b) the bound IS this
# wrapper's poll loop, so the 1800s guarantee dies with it and the run is back
# to the unbounded forever-hang #2184 exists to fix. SIGQUIT (Ctrl-\) is the
# same class at lower likelihood. Every signal gets its OWN green arm AND its
# OWN red arm — kernel principle 1, every meaningful behaviour tested for every
# state: a shared red arm would let a mis-spelled handler for one signal ride
# in on another's proof.
for _sigspec in HUP:129 INT:130 QUIT:131 TERM:143; do
  _signame="${_sigspec%%:*}"
  _sigcode="${_sigspec##*:}"

  # GREEN arm — the shipped guard reaps the whole tree and exits 128+signal.
  sig_launch_and_signal "$GUARD" "$_signame"
  [ "$SIG_RC" -eq "$_sigcode" ] \
    || fail "9: the wrapper must exit $_sigcode on SIG$_signame (128+signal), got $SIG_RC"
  if kill -0 "$SIG_SELF_PID" 2>/dev/null; then
    fail "9: SIG$_signame — the SUITE (pid $SIG_SELF_PID) SURVIVED the wrapper. \`set -m\` moved it out of the caller's process group, so it is now fully detached: the orphaned-tree defect #2184 exists to fix, reintroduced through the signal door"
  fi
  if kill -0 "$SIG_GC_PID" 2>/dev/null; then
    fail "9: SIG$_signame — the suite's GRANDCHILD (pid $SIG_GC_PID) survived the wrapper, i.e. an orphaned process tree — exactly what the ~50h incident left behind"
  fi

  # RED arm — splice reap() back OUT of THIS signal's handler (the pre-fix
  # shape) and the very same probe must leave the tree alive. Without it the
  # green arm above would prove nothing: a fixture that happened to die on its
  # own, or a signal that propagated by some other route, reads identically.
  # Per-signal by construction — the handlers are four separate `trap` lines
  # precisely so one can be neutralised without touching the other three.
  SIG_MUTANT="$TMPD/sig-mutant-guard.$_signame.sh"
  sed "s/trap 'reap; cleanup; exit $_sigcode' $_signame/trap 'cleanup; exit $_sigcode' $_signame/" \
    "$GUARD" > "$SIG_MUTANT"
  if diff -q "$GUARD" "$SIG_MUTANT" >/dev/null 2>&1; then
    fail "9: RED-arm splice failed for SIG$_signame — no \`trap 'reap; cleanup; exit $_sigcode' $_signame\` line was found in the guard, so this signal is either unarmed or armed in an unexpected shape and its discrimination proof is inert"
  fi
  sig_launch_and_signal "$SIG_MUTANT" "$_signame"
  if ! kill -0 "$SIG_SELF_PID" 2>/dev/null && ! kill -0 "$SIG_GC_PID" 2>/dev/null; then
    fail "9: RED arm SIG$_signame — with reap() spliced out of the handler the suite tree died ANYWAY, so something other than the handler is reaping it and the green arm above proves nothing"
  fi
  kill -9 "$SIG_GC_PID" "$SIG_SELF_PID" 2>/dev/null
done
pass "9 signal path: SIGHUP, SIGINT, SIGQUIT and SIGTERM on the wrapper each reap the suite's whole process group — the suite process AND its grandchild are both gone afterwards — and the wrapper exits 129/130/131/143; for EACH signal, splicing reap() out of that one handler leaves both alive, so every green is produced by its own handler and not by the fixture"

# ---------------------------------------------------------------------------
# 10: NO FLAKY EXIT — the exit-code handoff has no create-before-write race
# ---------------------------------------------------------------------------
# $RCF is the child's only channel back to the wrapper, and the poll loop uses
# `[ -f "$RCF" ]` as "the suite finished". A plain `printf … > "$RCF"` creates
# and truncates the file BEFORE printf's bytes land, so the poller can see an
# existing-but-empty file, read "", and report exit 1 for a suite that PASSED —
# an intermittent false failure in the gate that guards every other gate.
#
# ARM A — SHOW the ordering rather than assert it. Point the guard's mktemp at
# a directory we control and race a watcher against it: every observation of
# $RCF the instant it becomes visible must already be complete. (The wrapper's
# own 1s poll cadence guarantees a window in which the file exists and the
# wrapper is still alive, so this arm cannot silently observe nothing — which
# is asserted too, rather than assumed.)
RCWATCH="$TMPD/rcwatch"
mkdir -p "$RCWATCH"
rc_observations=0
rc_partial=0
_iter=0
while [ "$_iter" -lt 5 ]; do
  _iter=$((_iter + 1))
  rm -rf "$RCWATCH"/bounded-suite.*
  TMPDIR="$RCWATCH" BUILD_SUITE_TIMEOUT_SECS=60 bash "$GUARD" --label rcwatch -- \
    bash "$TMPD/healthy.sh" >/dev/null 2>&1 &
  watch_pid=$!
  seen=0
  while kill -0 "$watch_pid" 2>/dev/null; do
    for f in "$RCWATCH"/bounded-suite.*/rc; do
      [ -f "$f" ] || continue
      body="$(cat "$f" 2>/dev/null)"
      rc_observations=$((rc_observations + 1))
      case "$body" in ''|*[!0-9]*) rc_partial=$((rc_partial + 1)) ;; esac
      seen=1
    done
    [ "$seen" -eq 1 ] && break
  done
  wait "$watch_pid" 2>/dev/null
done
[ "$rc_observations" -ge 1 ] \
  || fail "10 ARM A: the watcher never observed the exit-code file at all across 5 runs — this arm is vacuous, not passing"
[ "$rc_partial" -eq 0 ] \
  || fail "10 ARM A: the exit-code file was observed EXISTING but empty/non-numeric $rc_partial of $rc_observations times — the poll loop's \`-f\` test can therefore fire before the code is written, and a green suite intermittently exits 1"

# ARM B — RED/GREEN over the ordering itself. The mutant restores BOTH halves
# of the racy shape (create-before-write, and reading $RCF before `wait`) and
# widens the window so the consequence is deterministic rather than occasional:
# a fixture that exits 0 must then be misreported as exit 1.
RACE_MUTANT="$TMPD/race-mutant-guard.sh"
: > "$RACE_MUTANT"
race_spliced_write=0
race_spliced_wait=0
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    *'__rc" > "$RCF.tmp"'*)
      printf '%s\n' '{ ( exec "$@" ) >"$LOG"; __rc=$?; : > "$RCF"; sleep 3; printf "%s\n" "$__rc" >> "$RCF"; } &' >> "$RACE_MUTANT"
      race_spliced_write=1
      ;;
    '  wait "$child" 2>/dev/null')
      # dropped: restores the read-before-wait half of the original ordering
      race_spliced_wait=1
      ;;
    *) printf '%s\n' "$line" >> "$RACE_MUTANT" ;;
  esac
done < "$GUARD"
[ "$race_spliced_write" -eq 1 ] \
  || fail "10 ARM B: splice failed — the atomic '> \$RCF.tmp && mv' write was not found in its expected shape, so this demonstration is inert"
[ "$race_spliced_wait" -eq 1 ] \
  || fail "10 ARM B: splice failed — the pre-read 'wait \$child' was not found, so the mutant does not actually restore the racy ordering"

mrc=0
BUILD_SUITE_TIMEOUT_SECS=60 bash "$RACE_MUTANT" --label racered -- bash "$TMPD/healthy.sh" \
  >/dev/null 2>/dev/null || mrc=$?
[ "$mrc" -eq 1 ] \
  || fail "10 ARM B RED: with the create-before-write ordering restored, the GREEN fixture should be misreported as exit 1, got $mrc — the demonstration is inert and ARM A's green proves nothing about ordering"

rc=0
BUILD_SUITE_TIMEOUT_SECS=60 bash "$GUARD" --label racegreen -- bash "$TMPD/healthy.sh" \
  >/dev/null 2>/dev/null || rc=$?
[ "$rc" -eq 0 ] \
  || fail "10 ARM B GREEN: the shipped guard must report the fixture's own exit 0, got $rc"
pass "10 no flaky exit: the exit-code handoff is an atomic rename, so \$RCF is never observable in a partial state ($rc_observations live observations, 0 partial) and 'wait' precedes the read as a second belt; restore the create-before-write ordering and the same passing fixture is misreported as exit 1"

# ---------------------------------------------------------------------------
# 11: the timeout report must not over-claim on the single-pid fallback
# ---------------------------------------------------------------------------
# reap() has TWO arms. With $pgid resolved it signals the whole process group
# and nothing survives. When job control did NOT give the job its own group the
# guard deliberately BLANKS $pgid (signalling the group would kill the wrapper,
# and under a bare `make`, make itself), and reap() then signals only "$child" —
# so every grandchild the suite forked IS STILL RUNNING. The report telling an
# operator "nothing is left orphaned" on that path is worse than silence: the
# fallback is precisely the case where they need to go look at `ps` themselves.
#
# Both arms are exercised. The fallback is reached by splicing the guard's own
# safety condition to always-true — the honest way to reach a branch that a
# working host's job control never takes.
FB_MUTANT="$TMPD/fallback-guard.sh"
sed 's/^if \[ -z "\$pgid" \] || \[ "\$pgid" = "\$self_pgid" \]; then/if true; then/' \
  "$GUARD" > "$FB_MUTANT"
if diff -q "$GUARD" "$FB_MUTANT" >/dev/null 2>&1; then
  fail "11: splice failed — the guard's \$pgid safety fallback was not found in its expected shape, so the single-pid report arm is untested"
fi

FB_ERR="$TMPD/fallback.err"
BUILD_SUITE_TIMEOUT_SECS=3 bash "$FB_MUTANT" --label fallbackdemo -- bash "$TMPD/hang.sh" \
  >/dev/null 2>"$FB_ERR"
# By construction this arm ORPHANS the fixture tree — that is the very thing the
# report must confess to. Register the survivors so this test does not leak the
# `sleep 300`s it deliberately provoked (the EXIT trap reaps STRAY_PIDS), and so
# a `fail` below still cleans up.
FB_GC_PID="$(cat "$GRANDCHILD_FILE" 2>/dev/null)"
[ -n "$FB_GC_PID" ] && STRAY_PIDS+=("$FB_GC_PID")
pkill -f "$TMPD/hang.sh" 2>/dev/null
[ -n "$FB_GC_PID" ] && kill -9 "$FB_GC_PID" 2>/dev/null

grep -q 'job control did NOT isolate' "$FB_ERR" \
  || fail "11: on the single-pid fallback the report must SAY job control did not isolate the suite; stderr was: $(cat "$FB_ERR")"
grep -q 'MAY STILL BE RUNNING' "$FB_ERR" \
  || fail "11: on the single-pid fallback the report must warn that descendants may have survived and tell the operator to check — that path is exactly where they need to look at \`ps\` themselves"
if grep -q 'nothing is left orphaned' "$FB_ERR"; then
  fail "11: the report claimed 'nothing is left orphaned' on the SINGLE-PID fallback, where reap() signalled only the direct child — a false assurance that tells the operator not to go looking for the surviving tree"
fi
grep -q "Live processes under the suite's pid" "$FB_ERR" \
  || fail "11: the process-snapshot heading must not say 'process group' on a path where no group was resolved"

# GREEN counterpart — on the normal path the strong claim is not just allowed,
# it is REQUIRED, or this case would pass against a guard that simply deleted
# the sentence.
FB_OK="$TMPD/pgid.err"
BUILD_SUITE_TIMEOUT_SECS=3 bash "$GUARD" --label pgiddemo -- bash "$TMPD/hang.sh" \
  >/dev/null 2>"$FB_OK"
grep -q 'nothing is left orphaned' "$FB_OK" \
  || fail "11: on the NORMAL path the whole group IS reaped, so the report must still say nothing is left orphaned; stderr was: $(cat "$FB_OK")"
grep -q 'job control did NOT isolate' "$FB_OK" \
  && fail "11: the normal path must NOT emit the fallback warning — job control DID isolate the suite there"
pass "11 timeout report honesty: on the single-pid fallback the report names the one pid it signalled, says job control did not isolate the suite and tells the operator to check for survivors — and never claims whole-group reaping; on the normal path it still makes that claim, so the assertion is not satisfied by deleting the sentence"

# ---------------------------------------------------------------------------
# 8: static lockstep — the wiring a behaviour case cannot see
# ---------------------------------------------------------------------------
# `"?` throughout: these assert the WIRING (the target routes through the
# guard), not the quoting style of the $(BUILD_SRC) expansion around it — the
# recipes quote it so a checkout path containing a space still works, and that
# quote must not be able to turn a wiring gate red.
grep -qE 'bounded-suite\.sh"? --label test-build-workflow' "$MAKEFILE" \
  || fail "8: the Makefile's test-build-workflow target must run through bounded-suite.sh — an unwired guard bounds nothing"
grep -qE 'bounded-suite\.sh"? --label test-build ' "$MAKEFILE" \
  || fail "8: the Makefile's test-build target must run through bounded-suite.sh too — it has the identical gap"
grep -qE -- '--case-source "?\$\(BUILD_SRC\)/tests/test_workflow\.sh' "$MAKEFILE" \
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

# ---------------------------------------------------------------------------
# 12: POLL CADENCE — a SHORT wrapped command returns promptly (temperloop#2162)
#
# WHY THIS IS A TEST AND NOT A TUNING NOTE. temperloop#2162 split
# `make test-build` / `make test-cli-subcommands` into ~73 PER-SCRIPT gates and
# wrapped each one in this guard, so the #2184 bound survives at the finer
# granularity instead of being left behind on a make target the gate set no
# longer runs. With the original flat `sleep 1` poll, every one of those 73
# gates paid a fixed ~1s tail it could not observe its own completion inside —
# roughly 73s of pure latency added to the suite's serial cost, for no
# bound-related reason. That is exactly the kind of regression that gets the
# wrapper quietly dropped from the gates again.
#
# THE MEASUREMENT IS A DELTA, NOT A CEILING, and the fixture is deliberately
# NOT instantaneous. Both choices are scars from building this case:
#
#   * An absolute ceiling is a load test, not a cadence test. This suite runs
#     as one of ~73 POOLED gates — under 24-way concurrency an "under 2s"
#     ceiling measures the host. So the assertion is the DELTA between the
#     shipped guard and a spliced flat-`sleep 1` copy, measured back to back on
#     the same host moments apart, where load cancels.
#   * An INSTANT fixture cannot discriminate at all: the poll tests for $RCF
#     BEFORE its first sleep, so a command that finishes inside the wrapper's
#     own start-up (~50ms of `ps` calls) is already done at that first check
#     and BOTH cadences cost zero sleeps. Measured directly — at 24-way
#     concurrency an instant fixture produced 1s vs 1s and the control proved
#     nothing. The fixture therefore takes ~0.4s: long enough that the first
#     check always misses, short enough that the two cadences differ by the
#     thing under test (a ~0.2s notice vs a ~1.0s one).
# ---------------------------------------------------------------------------
cat > "$TMPD/quick.sh" <<'EOF'
#!/usr/bin/env bash
echo "PASS: short case"
sleep 0.4 2>/dev/null || sleep 1
exit 0
EOF

POLL_RUNS=5
POLL_ELAPSED=""
# An OUT-PARAM, not a command substitution (temperloop#2194). `fail()` is
# `exit 1`, and an exit inside `$( )` kills only the substitution's SUBSHELL:
# the parent carried on with POLL_ELAPSED unset-as-empty, bash arithmetic reads
# an empty-but-set variable as 0 even under `set -u`, and the delta assertion
# below then evaluated `0 - 0` and blamed the TIMING — "the flat-sleep-1
# control took s vs the shipped guard's s" — for what was actually the fixture
# failing under the guard. The suite still went red; the operator was just sent
# to the wrong place, with the real cause printed from the dead subshell where
# it reads as noise. Running in the CALLER'S shell keeps both the out-param and
# fail()'s exit, exactly as gate_selection_local_changed_to_file does for its
# own out-param (temperloop#1663), and as the sibling suite's own note at
# test_gate_selection.sh warns: "No subshell: fail() exits, and an exit inside
# `( )` would leave the suite printing OK on a red case."
poll_elapsed() {  # poll_elapsed <guard-path> -> POLL_ELAPSED = whole seconds for $POLL_RUNS runs
  local guard="$1" t0 t1 i
  t0="$(date +%s)"
  i=0
  while [ "$i" -lt "$POLL_RUNS" ]; do
    BUILD_SUITE_TIMEOUT_SECS=60 bash "$guard" --label quick -- bash "$TMPD/quick.sh" \
      >/dev/null 2>/dev/null || fail "12: the short fixture must exit 0 under $guard"
    i=$((i + 1))
  done
  t1="$(date +%s)"
  POLL_ELAPSED=$((t1 - t0))
}

# The control: the pre-#2162 flat-`sleep 1` cadence, spliced out of the shipped
# guard so the two runs differ in exactly one line.
sed 's/    sleep "\$BS_FAST_SECS" 2>\/dev\/null || sleep 1/    sleep 1/' \
  "$GUARD" > "$TMPD/guard-flat-poll.sh"
if ! grep -q 'BS_FAST_POLLS' "$TMPD/guard-flat-poll.sh" \
  || [ "$(grep -c 'sleep "\$BS_FAST_SECS"' "$TMPD/guard-flat-poll.sh" | tr -d ' ')" != 0 ]; then
  fail "12: the discrimination splice did not apply — the fast-poll line was not replaced, so the control proves nothing"
fi

poll_elapsed "$GUARD";                   fast_elapsed="$POLL_ELAPSED"
poll_elapsed "$TMPD/guard-flat-poll.sh"; slow_elapsed="$POLL_ELAPSED"
[ $((slow_elapsed - fast_elapsed)) -ge 1 ] \
  || fail "12: discrimination FAILED — the flat-sleep-1 control took ${slow_elapsed}s vs the shipped guard's ${fast_elapsed}s over $POLL_RUNS runs, so the fast poll is not actually in effect (or the measurement cannot see it)"
# A catastrophe ceiling only: far outside any plausible load, so it can never be
# the flaky half. $POLL_RUNS × (0.4s fixture + a fast notice) is ~3s.
# The companion bound is a CATASTROPHE bound, not a cadence assertion — the
# delta above is what proves the cadence. Expected ~3-3.5s; 30s leaves ~10x
# headroom so a loaded 24-way pool cannot turn this into a flaky red (a flaky
# red is real signal to chase, so a test must not manufacture one).
[ "$fast_elapsed" -le 30 ] \
  || fail "12: $POLL_RUNS short wrapped commands took ${fast_elapsed}s — the per-script gates pay this 73 times"
pass "12 poll cadence: $POLL_RUNS short wrapped commands cost ${fast_elapsed}s under the shipped guard and ${slow_elapsed}s once the fast poll is spliced back out to a flat 'sleep 1' — the delta is produced by the cadence, measured back to back on this host"

# 12b: the BOUND is unaffected by the cadence — it is computed from `date +%s`,
# never from a poll count. Re-checked here, not merely inherited from case 3,
# because this case is the one that changed the loop the bound lives in.
rc=0
t0="$(date +%s)"
BUILD_SUITE_TIMEOUT_SECS=2 bash "$GUARD" --label cadence-bound -- \
  bash -c 'echo "PASS: one"; sleep 30' >/dev/null 2>/dev/null || rc=$?
t1="$(date +%s)"
[ "$rc" -eq 137 ] || fail "12b: the bound must still fire with exit 137 under the new cadence, got $rc"
[ $((t1 - t0)) -lt 15 ] || fail "12b: a 2s bound took $((t1 - t0))s to fire — the cadence changed the bound"
pass "12b the bound is still wall-clock, not poll-count: a 2s bound over a 30s hang fires in $((t1 - t0))s with exit 137"

echo ""
echo "All test_bounded_suite.sh cases passed."
