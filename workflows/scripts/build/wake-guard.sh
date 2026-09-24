#!/usr/bin/env bash
#
# wake-guard.sh — the STRUCTURAL turn-end wake guarantee for /build
# (temperloop#2210).
#
# ── WHY THIS EXISTS ─────────────────────────────────────────────────────────
# The merge queue and CI are PULL-ONLY. Nothing notifies an orchestrator that a
# PR merged, went green, or fell BEHIND. So an orchestrator turn that ends with
# in-flight work and NO ARMED WAKE SOURCE never learns anything again: silence
# is indistinguishable from "still running", and the run stalls until a human
# happens to ask. The /build of epic #2065 stalled three times that way — about
# 20 minutes, 12.5 HOURS, and once more — and EVERY one was caught by the
# operator asking, never by a mechanism.
#
# Two compounding causes, both addressed here:
#
#   1. NO WAKE SOURCE. The turn ended with open PRs and nothing scheduled —
#      no Monitor, no scheduled wakeup, no polling background task.
#   2. `Bash timeout:` DETACHES, IT DOES NOT KILL. A 500s-bounded command was
#      moved to the background at the bound and then ran UNBOUNDED for 12.5h.
#      A bound that only detaches is not a bound.
#
# ── WHAT THIS SCRIPT IS, AND WHAT IT DELIBERATELY IS NOT ────────────────────
# It is deliberately THIN. It owns no GitHub-state vocabulary of its own: every
# merge-state read is `gate.sh poll`, which already implements the bounded
# poll-until-MERGED loop with its own closed outcome set (MERGED / CONFLICTING /
# TIMEOUT + the #1178 queue diagnosis) and its own #130 premature-close guard.
# Re-deriving any of that here would be a second, drifting copy of the merge
# vocabulary. What this script ADDS is the thing gate.sh cannot add for itself:
#
#   • `arm`    — the wake source, ARMED. A blocking, foreground, bounded poll
#                over the in-flight PR set. Because it BLOCKS, the orchestrator
#                turn cannot end while the work is still open — which is the
#                whole defect. A PR the queue merges AFTER the orchestrator
#                would otherwise have yielded is seen within ONE poll interval.
#   • `bound`  — the KILL-NOT-DETACH watchdog, reusable by any long-running
#                build-path command. It is what makes `arm` itself safe, and it
#                is exported as its own subcommand so the other backgrounded
#                sites in the build path can wrap without re-deriving it.
#   • `assert` — the REFUSAL. A turn-end that reports open work and no armed
#                wake source exits non-zero instead of yielding into silence.
#
# It does NOT decide whether to merge, does not enqueue, and does not write
# plan-note sentinels — same division of labour gate.sh already keeps.
#
# ── THE WATCHDOG DOES NOT DEPEND ON WHAT IT WATCHES ─────────────────────────
# The #2065 stalls had a third cause worth naming, because this guard must not
# repeat it: the watchdog in play then was `until ! pgrep -f <pattern>`, which
# asks the WATCHED process's own liveness for permission to fire. A hang took
# the guard down with it, and a pattern that matched nothing looked exactly
# like a process that had finished.
#
# This watchdog is armed BEFORE the watched command can misbehave, in its own
# detached subshell, and it knows ONE fact: a pid. It never greps for a command
# pattern, never re-reads the child's state, and never waits on the child's
# cooperation — it sleeps for the bound and signals. A total hang in the
# watched process changes nothing about whether the guard fires.
#
# ── BSD/macOS DIALECT ───────────────────────────────────────────────────────
# Stock macOS ships NO GNU `timeout` and no `gtimeout`, so this uses neither —
# bash + `sleep` + `kill`, the same dependency-free third tier
# workflows/scripts/lib/portable-timeout.sh documents and bounded-suite.sh
# builds on. Like bounded-suite.sh (and UNLIKE portable-timeout.sh's fallback,
# which kills only the DIRECT child) the watched command runs in its OWN
# PROCESS GROUP (`set -m`) and the bound signals the GROUP — so a poll whose
# `gh` or `sleep` grandchild is what actually wedged leaves nothing detached
# behind. A timeout exits 137 (128+SIGKILL), the code portable-timeout.sh
# normalizes every backend's timeout onto.
#
# ── THE BOUNDS ARE NAMED SETTINGS, NEVER LITERALS ───────────────────────────
#   $BUILD_WAKE_POLL_INTERVAL  seconds between merge-state reads
#   $BUILD_WAKE_POLL_TIMEOUT   wall-clock bound on ONE armed-wake call
# Both live in workflows/scripts/build/build.config.sh, with byte-identical
# layer-6 fallbacks below for a checkout that does not vendor that file — the
# convention gate.sh already uses for BUILD_QUEUE_STALL_AFTER.
#
# $BUILD_WAKE_POLL_TIMEOUT is a LIVENESS bound on one call — how long this
# process may block before handing control back — sized to sit under the
# harness's ~590s foreground Bash ceiling. It is NOT the merge-queue ceiling:
# how long a PR may legitimately sit in the queue is BUILD_QUEUE_TIMEOUT, whose
# sizing is a separate open question (temperloop#2055) this script deliberately
# does not pre-empt. A caller that wants the full queue ceiling chains armed
# calls; it never widens this one past the foreground cap.
#
# ── USAGE ───────────────────────────────────────────────────────────────────
#   wake-guard.sh arm <owner>/<repo> <pr> [<pr> ...]
#                     [--interval <secs>] [--timeout <secs>] [--gate-bin <path>]
#   wake-guard.sh bound --label <name> --timeout-secs <secs> -- <cmd> [args...]
#   wake-guard.sh assert --open <n> [--wake <poll|wakeup|background|none>]
#
# ── OUTPUT CONTRACT — CLOSED outcome set, one JSON line ─────────────────────
#   arm    → {"outcome":"RESUMED","merged":[…],"waited":…}              exit 0
#            {"outcome":"NO_OPEN_WORK"}                                 exit 0
#            {"outcome":"CONFLICTING","pr":…,…}                         exit 3
#            {"outcome":"TIMEOUT","pr":…,"waited":…,…}                  exit 4
#            {"outcome":"TIMEOUT","pr":…,"killed":true,"bound_secs":…}  exit 4
#   bound  → the wrapped command's own stdout and exit status, EXCEPT on a
#            timeout: {"outcome":"TIMEOUT","label":…,"bound_secs":…,
#                      "elapsed_secs":…,"killed":true}                exit 137
#   assert → {"outcome":"NO_OPEN_WORK"}                                 exit 0
#            {"outcome":"WAKE_ARMED","open":…,"wake":…}                 exit 0
#            {"outcome":"NO_WAKE_SOURCE","open":…,"remedy":…}           exit 4
#   error  → {"outcome":"ERROR","error":…}                              exit 1

set -uo pipefail

_WG_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

command -v jq >/dev/null 2>&1 || { echo '{"outcome":"ERROR","error":"jq not found"}'; exit 1; }

# fd 3 = the script's real stdout, so a die() inside a command substitution
# still reaches the caller (the same seam gate.sh / ci-poll.sh / pr.sh use).
exec 3>&1
die() {
  jq -cn --arg error "$1" '{outcome:"ERROR", error:$error}' >&3
  exit 1
}

usage() {
  die "usage: wake-guard.sh arm <owner>/<repo> <pr> [<pr> ...] [--interval <secs>] [--timeout <secs>] [--gate-bin <path>] | bound --label <name> --timeout-secs <secs> -- <cmd> [args...] | assert --open <n> [--wake <poll|wakeup|background|none>]"
}

_wg_uint() {
  case "${1:-}" in
    ""|*[!0-9]*) return 1 ;;
    *) printf '%s' "$1" ;;
  esac
}

# --- the watchdog ------------------------------------------------------------
# _wg_run_bounded <secs> <cmd...> — run <cmd> under a KILL-not-detach bound.
#
# The four load-bearing properties, in the order they appear below:
#   1. `set -m` gives the child its OWN process group (pgid == its pid), so the
#      kill reaps the whole tree instead of orphaning grandchildren.
#   2. The watchdog subshell is armed IMMEDIATELY AFTER the child starts and
#      BEFORE anything is waited on, so there is no window in which a command
#      can hang unguarded.
#   3. It is detached from EVERY inherited descriptor — `</dev/null >/dev/null
#      2>&1` AND `3>&-`. Without that, its `sleep` inherits the write end of any
#      command substitution wrapping this call, and every FAST call stalls for
#      the full bound waiting on an EOF the orphaned sleep is holding open (the
#      pipe leak foundation#861 recorded against the same shape). Closing fd 3
#      is not optional belt-and-braces here: this script's die() seam dups the
#      real stdout onto fd 3, so `>/dev/null` alone leaves fd 3 STILL pointing
#      at that pipe and the leak survives the redirect that was meant to fix it.
#      The watched command gets `3>&-` for the same reason — it has no business
#      holding this script's reporting channel open either.
#      (Caught by tests/test_wake_guard.sh's own fast-path timing assertion,
#      which measured the full 30s bound on a command that exits instantly.)
#   4. It knows only a pid. No `pgrep -f`, no re-read of the child's state, no
#      dependence on the child answering anything — see the header.
#
# Sets $_WG_TIMED_OUT to 1 iff the bound fired, and $_WG_ELAPSED to the wall
# clock it took. Returns the child's status (137 on a kill).
#
# CALL IT IN THE CURRENT SHELL, NEVER INSIDE `$(...)`. Both of those are plain
# shell variables, so a command substitution would run this in a SUBSHELL and
# every assignment would be discarded at the closing paren — the timeout would
# then read as 0 on every call and a killed child would fall through to the
# caller's "unexpected status" arm instead of being reported as a TIMEOUT. A
# caller that needs the child's stdout redirects it to a file (cmd_arm below
# does exactly that) rather than capturing it.
_WG_TIMED_OUT=0
_WG_ELAPSED=0
_wg_run_bounded() {
  local bound="$1"; shift
  local rc=0 pid wd elapsed t0
  _WG_TIMED_OUT=0
  t0="$(date +%s)"
  set -m
  "$@" 3>&- &
  pid=$!
  set +m
  # `kill -KILL -$pid` signals the GROUP; the bare-pid fallback covers a host
  # where job control could not give the child its own group, so the bound
  # degrades to portable-timeout.sh's direct-child kill rather than to nothing.
  ( sleep "$bound" 2>/dev/null
    kill -KILL -"$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null
  ) </dev/null >/dev/null 2>&1 3>&- &
  wd=$!
  wait "$pid" 2>/dev/null; rc=$?
  kill "$wd" 2>/dev/null
  wait "$wd" 2>/dev/null
  elapsed=$(( $(date +%s) - t0 ))
  # Timed out iff BOTH the child died by signal AND the wall clock actually
  # reached the bound — the same two-part test build-level.mjs's #1071 step
  # bound uses, so a command that exits 137 on its own is never mislabelled.
  if [ "$rc" -ge 128 ] && [ "$elapsed" -ge "$bound" ]; then
    _WG_TIMED_OUT=1
  fi
  _WG_ELAPSED="$elapsed"
  return "$rc"
}

# --- bound: the kill-not-detach wrapper, as a subcommand --------------------
cmd_bound() {
  local label="" bound="" rc=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --label)        [ $# -ge 2 ] || usage; label="$2"; shift 2 ;;
      --timeout-secs) [ $# -ge 2 ] || usage; bound="$2"; shift 2 ;;
      --)             shift; break ;;
      *)              usage ;;
    esac
  done
  [ -n "$label" ] || die "bound: --label is required"
  _wg_uint "$bound" >/dev/null || die "bound: --timeout-secs '$bound' invalid — must be a non-negative integer"
  [ "$bound" -gt 0 ] || die "bound: --timeout-secs must be greater than 0 — a zero bound is no bound at all"
  [ $# -ge 1 ] || die "bound: no command after --"

  _wg_run_bounded "$bound" "$@" || rc=$?
  if [ "$_WG_TIMED_OUT" -eq 1 ]; then
    jq -cn --arg label "$label" --argjson b "$bound" --argjson e "$_WG_ELAPSED" \
      '{outcome:"TIMEOUT", label:$label, bound_secs:$b, elapsed_secs:$e, killed:true}' >&3
    return 137
  fi
  return "$rc"
}

# --- arm: the wake source, armed --------------------------------------------
# One `gate.sh poll` per PR, each under the watchdog above. Sequential and
# blocking BY DESIGN: a blocking call is the only shape an orchestrator turn
# cannot end in front of, which is the defect this closes.
cmd_arm() {
  local owner_repo="" interval="" timeout="" gate_bin=""
  local -a prs=()
  [ $# -ge 1 ] || usage
  owner_repo="$1"; shift
  case "$owner_repo" in
    */*/*|*/|/*|"") die "owner/repo '$owner_repo' invalid — must be <owner>/<repo>" ;;
    */*) ;;
    *) die "owner/repo '$owner_repo' invalid — must be <owner>/<repo>" ;;
  esac
  while [ $# -gt 0 ]; do
    case "$1" in
      --interval) [ $# -ge 2 ] || usage; interval="$2"; shift 2 ;;
      --timeout)  [ $# -ge 2 ] || usage; timeout="$2"; shift 2 ;;
      --gate-bin) [ $# -ge 2 ] || usage; gate_bin="$2"; shift 2 ;;
      -*)         usage ;;
      *)          _wg_uint "$1" >/dev/null || die "pr '$1' invalid — must be a PR number"
                  prs+=("$1"); shift ;;
    esac
  done

  interval="${interval:-${BUILD_WAKE_POLL_INTERVAL:-30}}"
  timeout="${timeout:-${BUILD_WAKE_POLL_TIMEOUT:-540}}"
  _wg_uint "$interval" >/dev/null || die "interval '$interval' invalid"
  _wg_uint "$timeout" >/dev/null || die "timeout '$timeout' invalid"
  [ "$interval" -gt 0 ] || die "interval must be greater than 0"
  [ "$timeout" -gt 0 ] || die "timeout must be greater than 0"
  gate_bin="${gate_bin:-$_WG_HERE/gate.sh}"
  [ -f "$gate_bin" ] || die "gate.sh not found at '$gate_bin'"

  # NO OPEN WORK is a first-class outcome, not an error: a turn with nothing
  # in flight needs no wake source, and saying so explicitly is what lets the
  # caller distinguish "nothing to wait for" from "waited and learned nothing".
  if [ "${#prs[@]}" -eq 0 ]; then
    jq -cn '{outcome:"NO_OPEN_WORK"}' >&3
    return 0
  fi

  # The watchdog bound is DERIVED, never a second setting: gate.sh's own
  # deadline can be up to one sleep interval late (it checks the deadline
  # between reads), so the outer kill sits exactly one interval past it. The
  # watchdog is the belt to gate.sh's suspenders — it fires only when gate.sh
  # itself wedged and never reached its own TIMEOUT.
  local wd_bound=$(( timeout + interval ))

  # The poll's stdout goes to a scratch FILE, not a command substitution — see
  # the _wg_run_bounded contract above: a substitution would run the watchdog in
  # a subshell and silently discard its timeout verdict. This is the only file
  # this script writes, and it is removed on every exit path.
  local scratch
  scratch="$(mktemp -t wake-guard.XXXXXX)" || die "could not create a scratch file for the armed poll"
  # shellcheck disable=SC2064  # $scratch is expanded NOW, deliberately.
  trap "rm -f '$scratch'" EXIT

  local t0 pr out rc merged_json
  t0="$(date +%s)"
  merged_json='[]'
  for pr in "${prs[@]}"; do
    rc=0
    _wg_run_bounded "$wd_bound" bash "$gate_bin" poll "$owner_repo" "$pr" \
      --interval "$interval" --timeout "$timeout" >"$scratch" 2>/dev/null || rc=$?
    out="$(cat "$scratch" 2>/dev/null || true)"
    if [ "$_WG_TIMED_OUT" -eq 1 ]; then
      # gate.sh never reached its own deadline — it wedged and was KILLED, not
      # detached. Reported as a TIMEOUT so a wedged poll can never read as a
      # still-running one (the silence-vs-running ambiguity this item closes).
      jq -cn --argjson pr "$pr" --argjson b "$wd_bound" --argjson e "$_WG_ELAPSED" \
        '{outcome:"TIMEOUT", pr:$pr, waited:$e, killed:true, bound_secs:$b,
          reason:"the armed poll itself wedged and was killed at its bound"}' >&3
      return 4
    fi
    case "$rc" in
      0) merged_json="$(jq -cn --argjson acc "$merged_json" --argjson pr "$pr" '$acc + [$pr]')" ;;
      3) printf '%s\n' "$out" >&3; return 3 ;;
      4) printf '%s\n' "$out" >&3; return 4 ;;
      *) die "gate.sh poll failed for #$pr (exit $rc): $(printf '%s' "$out" | tail -1)" ;;
    esac
  done
  jq -cn --argjson merged "$merged_json" --argjson waited "$(( $(date +%s) - t0 ))" \
    '{outcome:"RESUMED", merged:$merged, waited:$waited}' >&3
  return 0
}

# --- assert: the refusal -----------------------------------------------------
# A turn-end that has open work and nothing scheduled FAILS here rather than
# yielding into silence. The wake kinds are a CLOSED set on purpose: an
# unrecognised value is an error, never quietly accepted as "armed", because
# the whole failure mode this guards is a wake that was believed armed and
# was not.
WAKE_KINDS="poll wakeup background none"
cmd_assert() {
  local open="" wake="none"
  while [ $# -gt 0 ]; do
    case "$1" in
      --open) [ $# -ge 2 ] || usage; open="$2"; shift 2 ;;
      --wake) [ $# -ge 2 ] || usage; wake="$2"; shift 2 ;;
      *)      usage ;;
    esac
  done
  _wg_uint "$open" >/dev/null || die "assert: --open '$open' invalid — must be a non-negative integer"
  case " $WAKE_KINDS " in
    *" $wake "*) ;;
    *) die "assert: --wake '$wake' invalid — must be one of: $WAKE_KINDS" ;;
  esac

  if [ "$open" -eq 0 ]; then
    jq -cn '{outcome:"NO_OPEN_WORK"}' >&3
    return 0
  fi
  if [ "$wake" = "none" ]; then
    jq -cn --argjson open "$open" \
      --arg remedy "arm one before ending the turn: wake-guard.sh arm <owner>/<repo> <pr> [<pr> ...]" \
      '{outcome:"NO_WAKE_SOURCE", open:$open, wake:"none", remedy:$remedy}' >&3
    return 4
  fi
  jq -cn --argjson open "$open" --arg wake "$wake" \
    '{outcome:"WAKE_ARMED", open:$open, wake:$wake}' >&3
  return 0
}

# --- dispatch (skipped when sourced for tests) -------------------------------
# Mirrors gate.sh: a test `source`s this file to call cmd_* directly, so the
# dispatch must NOT run on source.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  [ $# -ge 1 ] || usage
  _wg_cmd="$1"; shift
  case "$_wg_cmd" in
    arm)    cmd_arm "$@" ;;
    bound)  cmd_bound "$@" ;;
    assert) cmd_assert "$@" ;;
    *)      usage ;;
  esac
fi
