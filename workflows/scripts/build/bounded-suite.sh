#!/usr/bin/env bash
#
# bounded-suite.sh — a WALL-CLOCK GUARD around a long-running Makefile test
# suite, which names the case that was RUNNING when the bound fired
# (temperloop#2184).
#
# ── WHY THIS EXISTS ─────────────────────────────────────────────────────────
# `make test-build-workflow` and `make test-build` had NO wall-clock bound at
# all. A hang anywhere inside the suite therefore ran forever with no signal:
# the observed incident was a ~50h run leaving two orphaned process trees
# behind, noticed only because a human eventually looked at `ps`. Nothing went
# red, nothing was logged, and the last line on screen named the case that had
# just COMPLETED — which reads as "this case hung", the opposite of the truth.
#
# This wrapper turns that silent forever-hang into a loud, bounded failure that
# NAMES THE RUNNING CASE. Deliberately NOT in scope: diagnosing what caused the
# original hang. The absent bound is the defect, independent of the trigger.
#
# ── THE BOUND IS A NAMED SETTING ────────────────────────────────────────────
# $BUILD_SUITE_TIMEOUT_SECS (workflows/scripts/build/build.config.sh, layer 5),
# with the byte-identical layer-6 fallback below for a checkout that does not
# vendor that config file. The Makefile recipes name the wrapper, never a
# number — per CLAUDE.kernel.md § Named-setting convention.
#
# ── BSD/macOS DIALECT (the platform this repo's kernel devs run) ────────────
# Stock macOS ships NO GNU `timeout` and no `gtimeout` unless Homebrew
# coreutils is installed, so this guard uses NEITHER. It is a dependency-free
# bash watchdog — `bash` + `sleep` + `kill` + `ps` — modelled on
# workflows/scripts/lib/portable-timeout.sh's third tier. It deliberately does
# not just CALL run_with_timeout, for two reasons that matter here:
#
#   1. PROCESS-GROUP REAPING. run_with_timeout's fallback tier `kill -9`s the
#      direct child only. A test suite's child is a shell that has itself
#      spawned `node`/`git`/`sleep` grandchildren — killing the shell leaves
#      exactly the ORPHANED PROCESS TREES the incident observed. This wrapper
#      runs the suite in its OWN process group (bash job control, `set -m`) and
#      signals the whole group, so nothing survives the bound.
#   2. NAMING THE RUNNING CASE. A generic watchdog can only report "timed out".
#      This wrapper tracks suite progress (below) so the failure says WHICH
#      case was in flight.
#
# ── HOW THE RUNNING CASE IS RESOLVED (two sources, in order) ────────────────
#   1. BREADCRUMB (authoritative). The wrapper exports $SUITE_PROGRESS_FILE and
#      a cooperating suite writes the in-flight case name there at case START
#      and truncates it at case END. test_workflow.sh's run_node_case() does
#      this for its 253 node cases; the `make test-build` recipe does it with
#      the test-script filename.
#   2. SOURCE-ORDER DERIVATION (fallback, `--case-source FILE`). Suites also
#      contain straight-line inline sections that announce nothing until they
#      pass. For those the wrapper reads the LAST `PASS: <desc>` line the suite
#      emitted, finds that case's declaration in FILE, and reports the NEXT
#      case declaration in source order — i.e. the one that had started and not
#      finished. The report labels which source it used, and always prints the
#      last COMPLETED case separately, so the two can never be confused (that
#      confusion is the defect this item names).
#
# Both sources can be absent; the wrapper then says so plainly rather than
# guessing. In every case it also prints the live process-group snapshot taken
# immediately before the kill, which names the actual stuck command.
#
# ── SIGNALS REAP THE GROUP TOO, NOT JUST THE BOUND ──────────────────────────
# `set -m` puts the suite in its OWN process group, which is what lets the
# bound reap the whole tree. It has a second, less obvious consequence: the
# suite is no longer in `make`'s foreground group, so a terminal Ctrl-C — or a
# terminal HANGUP — no longer reaches it. If this wrapper's handlers merely
# exited, the suite would keep running FULLY DETACHED — reintroducing the
# orphaned process trees this item exists to prevent, through a different door,
# and making the signal strictly WORSE than before the wrapper existed. Worse
# still for a hangup: the bound IS this wrapper's poll loop, so a wrapper that
# died on SIGHUP would take the bound with it and restore the unbounded
# forever-hang in full.
#
# So EVERY interactive/terminating signal a terminal or a CI job can deliver
# runs the SAME reap() the bound does before exiting: HUP (129), INT (130),
# QUIT (131) and TERM (143). That is the set workflows/scripts/tests/lib/
# sandbox.sh already installs for its own cleanup traps — this guard follows
# the established in-repo convention rather than arming a subset of it.
# Covered per-signal, with a per-signal RED arm, by
# tests/test_bounded_suite.sh case 9.
#
# ── WHAT IS *NOT* IDENTICAL IN A WRAPPED RUN ────────────────────────────────
# The suite's stdout is byte-identical and its stderr is untouched and
# unmerged, but a wrapped run is NOT indistinguishable from an unwrapped one:
# the suite's stdout is a FILE ($LOG), relayed onward, not the caller's
# terminal. So `isatty(1)` is FALSE for the suite where it may have been true
# before, and stdout arrives in <=1s relay batches, which can interleave with
# the (unredirected, unbuffered) stderr differently than an unwrapped run
# would. A suite that colourizes or draws progress on a tty check will take
# its non-tty branch. Accepted trade-off, deliberately not re-architected
# around a pty: these suites emit plain line-oriented text, and a pty would
# add a platform-specific dependency to a guard whose whole point is to work
# on a stock macOS with no extra binaries.
#
# ── USAGE ───────────────────────────────────────────────────────────────────
#   bounded-suite.sh --label <name> [--case-source <suite.sh>] -- <cmd> [args…]
#
#     --label        name used in the failure report (conventionally the make
#                    target being bounded). Required.
#     --case-source  suite source file for source-order derivation. Optional.
#     --             end of wrapper options; everything after is the command.
#
# Exit status: the wrapped command's own status, unchanged — EXCEPT on a
# timeout, which exits 137 (128+SIGKILL, the same code
# workflows/scripts/lib/portable-timeout.sh normalizes a timeout to).
#
# This script writes nothing outside its own mktemp -d scratch dir.

set -uo pipefail

BOUNDED_SUITE_TIMEOUT_EXIT=137

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Layer 5 (and, through build.config.sh's own sourcing, layers 3-4): read the
# vendored tracked config when this checkout has it.
#
# IN A SUBSHELL, DELIBERATELY. build.config.sh ends by EXPORTING ~200
# settings, and this script's whole job is to launch a test suite — sourcing
# it here would inject every one of those into the environment of every test
# the suite runs. That is not hypothetical: it turned test_dual_build_
# preflight.sh's "no build.config.sh sibling, so the ceiling is unset"
# fixture green-to-red, because the ceiling was no longer unset. The subshell
# resolves ONE value and lets the exports die with it. An env var already set
# by the caller (precedence layer 2) wins and skips the read entirely.
if [ -z "${BUILD_SUITE_TIMEOUT_SECS:-}" ] && [ -f "$SCRIPT_DIR/build.config.sh" ]; then
  BUILD_SUITE_TIMEOUT_SECS="$(
    set +u
    # shellcheck source=workflows/scripts/build/build.config.sh
    . "$SCRIPT_DIR/build.config.sh" >/dev/null 2>&1
    printf '%s' "${BUILD_SUITE_TIMEOUT_SECS:-}"
  )"
fi
# Layer 6: byte-identical fallback for a non-vendoring checkout. Keep in
# lockstep with build.config.sh's own literal and with the
# workflows/scripts/config/setting-registry.tsv row.
: "${BUILD_SUITE_TIMEOUT_SECS:=1800}"
BOUNDED_SUITE_DEFAULT_SECS=1800

label=""
case_source=""
while [ $# -gt 0 ]; do
  case "$1" in
    # Shift the FLAG first, then the value only if one is actually there
    # (temperloop#1342): a bare `shift 2` FAILS without shifting when the flag
    # is the final argument, so the same arm re-matches forever and the loop
    # spins at 100% CPU. A guard against an unbounded hang must not ship one.
    --label)       label="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
    --case-source) case_source="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
    --)            shift; break ;;
    *)
      echo "bounded-suite.sh: unknown option '$1' (expected --label/--case-source/--)" >&2
      exit 2
      ;;
  esac
done

[ -n "$label" ] || { echo "bounded-suite.sh: --label is required" >&2; exit 2; }
[ $# -gt 0 ]    || { echo "bounded-suite.sh: no command given after --" >&2; exit 2; }

# A `0` or non-numeric bound is REJECTED back to the default rather than
# honored — the lesson temperloop#1592 recorded for the same class of guard.
# Honoring `0` would mean either "no bound at all" (recreating this item's own
# defect through a typo) or "kill every healthy run instantly"; both readings
# are wrong, so the value is refused and the refusal is REPORTED, never
# silently corrected.
bound="$BUILD_SUITE_TIMEOUT_SECS"
case "$bound" in
  ''|*[!0-9]*) bound="" ;;
esac
if [ -z "$bound" ] || [ "$bound" -lt 1 ]; then
  echo "bounded-suite.sh: BUILD_SUITE_TIMEOUT_SECS='$BUILD_SUITE_TIMEOUT_SECS' is not a positive integer — using the ${BOUNDED_SUITE_DEFAULT_SECS}s default instead" >&2
  bound="$BOUNDED_SUITE_DEFAULT_SECS"
fi

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/bounded-suite.XXXXXX")" || exit 2
# shellcheck disable=SC2329  # invoked indirectly, from the traps below.
cleanup() { rm -rf "$TMPD"; }

# reap() — terminate the suite's whole process group. THE ONLY killer in this
# script: the bound calls it, and so do the HUP/INT/QUIT/TERM handlers.
# Factored out precisely so those paths can never diverge, which is exactly how
# the signal path came to orphan the tree in the first place.
#
# $pgid / $child are resolved further down, AFTER the traps are installed, so
# a signal can legitimately arrive before either exists — hence ${x:-} and the
# early return. When the traps fire after the launch but before $pgid is
# resolved, the group id is re-derived here from $child rather than skipped.
# shellcheck disable=SC2329  # invoked indirectly, from the traps below.
reap() {
  local g s
  [ -n "${child:-}" ] || return 0
  g="${pgid:-}"
  if [ -z "$g" ]; then
    g="$(ps -o pgid= -p "$child" 2>/dev/null | tr -d ' ')"
    s="$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')"
    # Never signal our OWN group: that would kill this wrapper (and, under a
    # bare `make`, make itself) instead of just the suite.
    if [ -z "$g" ] || [ "$g" = "$s" ]; then g=""; fi
  fi
  if [ -n "$g" ]; then
    kill -TERM "-$g" 2>/dev/null
    sleep 2
    kill -KILL "-$g" 2>/dev/null
  else
    kill -TERM "$child" 2>/dev/null
    sleep 2
    kill -KILL "$child" 2>/dev/null
  fi
  return 0
}

# EXIT sweeps the scratch dir; HUP/INT/QUIT/TERM must also REAP THE SUITE and
# then TERMINATE.
#   - reap, because `set -m` below moved the suite into its own process group,
#     out of make's foreground group: a terminal Ctrl-C (or a hangup from a
#     closed terminal / dropped SSH session) reaches this wrapper but NOT the
#     suite, so a handler that skipped reap() would leave the whole suite tree
#     running fully detached — this item's own defect class, reintroduced
#     through the signal door (and the signal would be worse than before the
#     wrapper existed, when make's group still caught it).
#   - exit, because a trap handler that returns without exiting leaves bash
#     carrying on with the next command, which would make this guard itself
#     unkillable by an ordinary SIGTERM (a Ctrl-C'd `make`, a CI job timeout).
#
# ALL FOUR, not a subset. An UNARMED signal takes bash's default disposition
# and kills this wrapper outright — which is strictly worse than no wrapper:
# the suite survives detached AND the bound dies with the poll loop that
# enforces it, restoring the unbounded forever-hang #2184 exists to fix. SIGHUP
# is the live case (closing a terminal, an SSH drop); SIGQUIT (Ctrl-\) is the
# same class at lower likelihood. Each is one line, all four share reap(), and
# each has its own RED arm in tests/test_bounded_suite.sh case 9.
#
# 129/130/131/143 are the conventional 128+SIGHUP / +SIGINT / +SIGQUIT /
# +SIGTERM codes. Kept as FOUR separate `trap` lines, one per signal, so the
# test's RED-arm splice can neutralise exactly one handler at a time.
trap cleanup EXIT
trap 'reap; cleanup; exit 129' HUP
trap 'reap; cleanup; exit 130' INT
trap 'reap; cleanup; exit 131' QUIT
trap 'reap; cleanup; exit 143' TERM

LOG="$TMPD/out.log"
RCF="$TMPD/rc"
PROGRESS="$TMPD/progress"
: > "$LOG"
: > "$PROGRESS"
export SUITE_PROGRESS_FILE="$PROGRESS"
# temperloop#2245 — tell the wrapped command it is ALREADY bounded. A suite
# that self-binds (tests/test_workflow.sh's preamble re-execs itself under
# this wrapper when run directly, so a bare `bash …/test_workflow.sh` gets the
# same bound as `make`) keys on this variable to skip that re-exec, so the
# make/gates path never wraps twice. Exported here rather than set by each
# recipe so the Makefile and scripts/quality-gates.sh stay untouched.
export WF_TEST_SELF_BOUND=1

# ── stdout relay ────────────────────────────────────────────────────────────
# The suite's stdout goes to $LOG (so the wrapper can read its PASS lines) and
# is relayed to this process's stdout as it grows. stderr is NOT redirected —
# it stays attached to the caller's stderr exactly as before, so the two
# streams are not merged and no output moves between them.
relay_pos=0
relay() {
  local size
  size="$(wc -c < "$LOG" 2>/dev/null | tr -d ' ')"
  [ -n "$size" ] || return 0
  if [ "$size" -gt "$relay_pos" ]; then
    # `head -c` BOUNDS the read to exactly the bytes counted above. Without it
    # `tail` reads to the file's EOF AS OF WHEN TAIL RUNS, which the still-
    # running suite has already grown past $size — those extra bytes would be
    # emitted now AND again on the next pass, DUPLICATING output lines
    # (observed: 3 duplicated PASS lines in one 368-line run).
    tail -c "+$((relay_pos + 1))" "$LOG" 2>/dev/null | head -c "$((size - relay_pos))"
    relay_pos="$size"
  fi
  return 0
}

# ── launch in its own process group ─────────────────────────────────────────
# `set -m` (job control) puts the background job in a NEW process group, whose
# id is the job leader's pid. Signalling -PGID reaches every descendant that
# has not deliberately left the group, which is what makes the bound reap the
# whole tree instead of orphaning it.
#
# ── THE EXIT-CODE HANDOFF IS ATOMIC, AND WHY IT HAS TO BE ───────────────────
# $RCF is the child's only channel back to this shell, and the poll loop below
# uses `[ -f "$RCF" ]` as its "the suite finished" signal. Writing it as
# `printf … > "$RCF"` would CREATE/TRUNCATE the file before printf's bytes
# land, so the poller can observe an EXISTING BUT EMPTY $RCF, read "", and —
# via the non-numeric guard below — report exit 1 for a suite that passed.
# That is an intermittent false failure in the gate that guards every other
# gate, i.e. precisely the "flaky test" class CLAUDE.kernel.md § Fix the real
# problem, not the symptom forbids papering over.
#
# So the child writes a SIBLING temp file and `mv`s it into place. A rename
# within one directory is atomic, so $RCF never exists in a partial state and
# the `-f` test means what the poller assumes it means. The `wait` before the
# read below is a second, independent belt (the writer is the very job being
# waited on). Covered by tests/test_bounded_suite.sh case 10.
set -m
{ ( exec "$@" ) >"$LOG"; __rc=$?; printf '%s\n' "$__rc" > "$RCF.tmp" && mv -f "$RCF.tmp" "$RCF"; } &
child=$!
set +m

pgid="$(ps -o pgid= -p "$child" 2>/dev/null | tr -d ' ')"
self_pgid="$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')"
# SAFETY: if job control did not give the job its own group, signalling the
# group would signal THIS process too. Fall back to the single pid instead.
if [ -z "$pgid" ] || [ "$pgid" = "$self_pgid" ]; then
  pgid=""
fi

# ── POLL CADENCE: fine-grained first, then 1s (temperloop#2162) ─────────────
# A flat `sleep 1` costs every wrapped command a fixed ~1s tail, because the
# poller cannot observe $RCF until its first sleep has elapsed. That was free
# when the only callers were two multi-minute umbrella suites. It is not free
# now: temperloop#2162 splits those umbrellas into ~73 PER-SCRIPT gates, each
# individually wrapped by this guard, and most of them finish in under two
# seconds — a flat 1s tail would have added ~73s of pure poll latency to the
# suite's serial cost for no bound-related reason.
#
# So the first $BS_FAST_POLLS iterations sleep $BS_FAST_SECS and the rest sleep
# 1s. The BOUND ITSELF IS UNCHANGED: it is computed from `date +%s` against
# $bound above, never from a poll count, so cadence cannot move when the guard
# fires — only how quickly a FINISHED command is noticed.
#
# `sleep` with a FRACTIONAL argument is a BSD/GNU extension, not POSIX. Rather
# than probe for it once at startup (which would itself cost a fractional
# sleep on every wrapped invocation — the exact overhead this is removing), the
# fractional form is attempted inline and falls back to a whole second when the
# host's `sleep` rejects it. A host without fractional sleep therefore gets
# exactly the pre-#2162 cadence, which is correct, just slower to notice.
BS_FAST_POLLS=10
BS_FAST_SECS=0.2

start="$(date +%s)"
timed_out=0
polls=0
while [ ! -f "$RCF" ]; do
  if [ $(( $(date +%s) - start )) -ge "$bound" ]; then
    timed_out=1
    break
  fi
  relay
  if [ "$polls" -lt "$BS_FAST_POLLS" ]; then
    sleep "$BS_FAST_SECS" 2>/dev/null || sleep 1
  else
    sleep 1
  fi
  polls=$((polls + 1))
done
relay

if [ "$timed_out" -eq 0 ]; then
  # `wait` FIRST, then read. The job being waited on is the same job that
  # writes $RCF, so once wait returns the file is complete — the second belt
  # behind the atomic rename above. Reading before the wait is the ordering
  # that produces an intermittent exit 1 on a green suite.
  wait "$child" 2>/dev/null
  rc="$(cat "$RCF" 2>/dev/null)"
  case "$rc" in ''|*[!0-9]*) rc=1 ;; esac
  exit "$rc"
fi

# ── the bound fired ─────────────────────────────────────────────────────────
elapsed=$(( $(date +%s) - start ))

last_completed="$(grep '^PASS: ' "$LOG" 2>/dev/null | tail -1 | sed 's/^PASS: //')"
[ -n "$last_completed" ] || last_completed="(none seen — the suite emitted no \`PASS: <case>\` line before the bound fired)"

running=""
running_src=""
breadcrumb="$(tr -d '\n' < "$PROGRESS" 2>/dev/null)"
if [ -n "$breadcrumb" ]; then
  running="$breadcrumb"
  running_src="breadcrumb written by the suite at case start"
elif [ -n "$case_source" ] && [ -f "$case_source" ]; then
  derived="$(
    awk '
      FNR == NR {
        if ($0 ~ /^run_node_case "/) {
          d = substr($0, length("run_node_case \"") + 1)
          sub(/" "$/, "", d)
          n++; cases[n] = d
        } else if ($0 ~ /^echo "PASS: /) {
          d = substr($0, length("echo \"PASS: ") + 1)
          sub(/"[[:space:]]*$/, "", d)
          n++; cases[n] = d
        }
        next
      }
      /^PASS: / { last = substr($0, 7) }
      END {
        if (n == 0) { print ""; exit }
        if (last == "") { print cases[1]; exit }
        idx = 0
        for (i = 1; i <= n; i++) if (cases[i] == last) idx = i
        if (idx == 0) { print ""; exit }
        if (idx >= n) { print "(past the last declared case in the suite source)"; exit }
        print cases[idx + 1]
      }
    ' "$case_source" "$LOG" 2>/dev/null
  )"
  if [ -n "$derived" ]; then
    running="$derived"
    running_src="derived from $case_source — the case declared immediately after the last one that passed"
  fi
fi
if [ -z "$running" ]; then
  running="(unresolvable — the suite wrote no progress breadcrumb and no case source was given)"
  running_src="none"
fi

# `ps -A -o …args=` rather than the BSD-shaped `-ax -o …command=`: `-A`,
# `-o`-with-`=` header suppression and the `args` format keyword are all POSIX,
# so macOS's BSD ps and Linux's procps both accept this exact spelling. (On
# macOS `-e` means "also show the environment", NOT "all processes", so `-A` is
# the portable one.) This section is the whole value of the timeout report —
# it names the actually-stuck command — and losing it on the Linux CI runner,
# where nobody can attach a debugger, is exactly where it can least afford to
# degrade.
if [ -n "$pgid" ]; then
  procs="$(ps -A -o pgid=,pid=,ppid=,etime=,args= 2>/dev/null | awk -v p="$pgid" '$1 == p')"
else
  procs="$(ps -o pid=,ppid=,etime=,args= -p "$child" 2>/dev/null)"
fi
[ -n "$procs" ] || procs="(no live processes found at kill time)"

# REAP FIRST, REPORT SECOND. The report speaks in the past tense about what was
# killed, so it must run AFTER the kill or it is asserting something that has
# not happened yet. The process snapshot above is deliberately taken BEFORE the
# reap — it is the whole diagnostic value of this report — and is already held
# in $procs, so moving the printing down costs nothing.
reap

# WHAT THE REPORT MAY CLAIM depends on which arm reap() took, and the two are
# not interchangeable. With $pgid resolved, the whole process group got SIGTERM
# then SIGKILL and nothing survives. With $pgid BLANKED (job control did not
# give the job its own group — see the safety fallback above), reap() signalled
# ONLY "$child": every grandchild the suite forked is still running. Telling an
# operator "nothing is left orphaned" on that path is worse than saying nothing
# at all — the fallback is precisely the case where they need to go look at
# `ps` themselves.
if [ -n "$pgid" ]; then
  procs_heading="Live processes in the suite's process group, snapshotted just before the kill:"
else
  procs_heading="Live processes under the suite's pid ($child), snapshotted just before the kill:"
fi

{
  echo ""
  echo "================================================================================"
  echo "TIMEOUT: '$label' hit the BUILD_SUITE_TIMEOUT_SECS wall-clock bound."
  echo ""
  echo "  bound      : ${bound}s (setting: BUILD_SUITE_TIMEOUT_SECS)"
  echo "  ran for    : ${elapsed}s before being killed"
  echo ""
  echo "  CASE THAT WAS RUNNING when the bound fired:"
  echo "      $running"
  echo "      [resolved via: $running_src]"
  echo ""
  echo "  Last case that COMPLETED before it (this is NOT the stalled case):"
  echo "      $last_completed"
  echo ""
  echo "  $procs_heading"
  printf '%s\n' "$procs" | sed 's/^/      /'
  echo ""
  if [ -n "$pgid" ]; then
    echo "  The whole process group ($pgid) was killed (SIGTERM, then SIGKILL), so"
    echo "  nothing is left orphaned behind this failure."
  else
    echo "  WARNING — job control did NOT isolate this suite in its own process"
    echo "  group, so only the suite's single pid ($child) was signalled (SIGTERM,"
    echo "  then SIGKILL). ANY DESCENDANTS IT SPAWNED MAY STILL BE RUNNING. Check"
    echo "  for survivors and kill them yourself:"
    echo "      ps -A -o pid=,ppid=,etime=,args= | grep -v grep"
  fi
  echo ""
  echo "  To allow a legitimately longer run, raise the setting, never the recipe:"
  echo "      BUILD_SUITE_TIMEOUT_SECS=<seconds> make $label"
  echo "================================================================================"
} >&2

wait "$child" 2>/dev/null
relay

exit "$BOUNDED_SUITE_TIMEOUT_EXIT"
