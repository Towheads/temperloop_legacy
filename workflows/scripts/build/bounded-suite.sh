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
# EXIT sweeps the scratch dir; INT/TERM must also TERMINATE, not merely clean
# up — a trap handler that returns without exiting leaves bash carrying on
# with the next command, so an un-exiting TERM handler would make this guard
# itself unkillable by an ordinary SIGTERM (a Ctrl-C'd `make`, a CI job
# timeout). 130/143 are the conventional 128+SIGINT / 128+SIGTERM codes.
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

LOG="$TMPD/out.log"
RCF="$TMPD/rc"
PROGRESS="$TMPD/progress"
: > "$LOG"
: > "$PROGRESS"
export SUITE_PROGRESS_FILE="$PROGRESS"

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
set -m
{ ( exec "$@" ) >"$LOG"; printf '%s\n' "$?" > "$RCF"; } &
child=$!
set +m

pgid="$(ps -o pgid= -p "$child" 2>/dev/null | tr -d ' ')"
self_pgid="$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')"
# SAFETY: if job control did not give the job its own group, signalling the
# group would signal THIS process too. Fall back to the single pid instead.
if [ -z "$pgid" ] || [ "$pgid" = "$self_pgid" ]; then
  pgid=""
fi

start="$(date +%s)"
timed_out=0
while [ ! -f "$RCF" ]; do
  if [ $(( $(date +%s) - start )) -ge "$bound" ]; then
    timed_out=1
    break
  fi
  relay
  sleep 1
done
relay

if [ "$timed_out" -eq 0 ]; then
  rc="$(cat "$RCF" 2>/dev/null)"
  case "$rc" in ''|*[!0-9]*) rc=1 ;; esac
  wait "$child" 2>/dev/null
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

if [ -n "$pgid" ]; then
  procs="$(ps -ax -o pgid=,pid=,ppid=,etime=,command= 2>/dev/null | awk -v p="$pgid" '$1 == p')"
else
  procs="$(ps -o pid=,ppid=,etime=,command= -p "$child" 2>/dev/null)"
fi
[ -n "$procs" ] || procs="(no live processes found at kill time)"

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
  echo "  Live processes in the suite's process group at kill time:"
  printf '%s\n' "$procs" | sed 's/^/      /'
  echo ""
  echo "  The whole process group was killed (SIGTERM, then SIGKILL), so nothing"
  echo "  is left orphaned behind this failure."
  echo ""
  echo "  To allow a legitimately longer run, raise the setting, never the recipe:"
  echo "      BUILD_SUITE_TIMEOUT_SECS=<seconds> make $label"
  echo "================================================================================"
} >&2

if [ -n "$pgid" ]; then
  kill -TERM "-$pgid" 2>/dev/null
  sleep 2
  kill -KILL "-$pgid" 2>/dev/null
else
  kill -TERM "$child" 2>/dev/null
  sleep 2
  kill -KILL "$child" 2>/dev/null
fi
wait "$child" 2>/dev/null
relay

exit "$BOUNDED_SUITE_TIMEOUT_EXIT"
