#!/usr/bin/env bash
#
# Tests for the TURN-END WAKE GUARANTEE (temperloop#2210) — wake-guard.sh, and
# the kill-not-detach bound claude/workflows/build-level.mjs compiles into the
# worker's own scoped-gate command.
#
# WHAT IS ACTUALLY BEING PINNED. The merge queue and CI are pull-only, so an
# orchestrator turn that ends with in-flight work and no armed wake source
# never learns anything again: silence is indistinguishable from "still
# running". That ambiguity stalled the /build of epic #2065 three times (~20
# min, 12.5 h, and once more) and EVERY one was caught by the operator asking,
# never by a mechanism. Two of those stalls' causes are in scope here:
#   1. the turn ended with open PRs and nothing scheduled;
#   2. `Bash timeout:` DETACHES rather than kills, so a 500s-bounded command
#      ran 12.5h unbounded.
# A third is in scope only as a property this guard must not repeat: the
# watchdog then in play was `until ! pgrep -f …`, which asked the WATCHED
# process for permission to fire, so the hang took the guard down with it.
#
# Covers:
#   - assert: the REFUSAL — open work + no wake source exits non-zero;
#     open work + an armed wake, and no open work at all, both pass; the wake
#     kinds are a CLOSED set (an unknown kind ERRORs, never reads as armed)
#   - arm: a PR the queue merges AFTER the point an unarmed turn would have
#     ended RESUMES within ONE poll interval (real gate.sh, fake gh, no network)
#   - arm: DISCRIMINATION control — the same fixture with a PR that NEVER
#     merges TIMEOUTs at the bound, so the RESUMED assertion above can fail
#   - arm: gate.sh's own CONFLICTING/TIMEOUT verdicts are relayed verbatim with
#     their exit codes; an empty PR set is NO_OPEN_WORK, not an error
#   - arm: a WEDGED poll — one that never reaches its own deadline — is KILLED
#     at the derived outer bound and reported TIMEOUT killed:true, never left
#     running and never reported as merely still-polling
#   - bound: a hanging backgrounded command is KILLED at its bound, reported
#     TIMEOUT/137, and its whole grandchild TREE is reaped (killed, not
#     detached — the process trees the 12.5h stall left behind)
#   - bound: a fast command's stdout and exit status pass through untouched and
#     it returns IMMEDIATELY, not after the bound (the foundation#861 pipe leak)
#   - bound: the watchdog does not depend on what it watches — a command that
#     traps and IGNORES SIGTERM is still reaped at the bound, and the guard's
#     source contains no `pgrep -f`/`until ! pgrep` pattern-liveness check
#   - bound: SIGNALS reap the group too — HUP/INT/QUIT/TERM on the guard each
#     reap the watched tree and exit 129/130/131/143 rather than dying and
#     leaving the child DETACHED (the defect class through the signal door),
#     each with its own RED arm that splices _wg_reap out of that one handler
#   - bound: retiring the watchdog does not ORPHAN its own `sleep` for the full
#     bound, with a CONTROL proving the pre-fix bare-kill shape does
#   - arm: a MULTI-PR set shares ONE wall-clock budget, so N ordinary queue
#     waits can never sum past the harness's foreground ceiling and get this
#     very call auto-backgrounded; CONTROL: a wide budget merges all four
#   - arm: sourced repeat calls keep the CALLER's EXIT trap and leave no
#     scratch file behind (no process-wide `trap … EXIT` from a cmd_* function)
#   - arm/assert: zero-padded values are normalised to decimal, never parsed as
#     octal (which aborts the shell mid-expansion and emits NO JSON at all)
#   - build-level.mjs: the GENERATED worker-gate command is executed for real —
#     a hanging suite is killed at its bound and the sentinel says TIMEOUT
#     (`state:finished`, `rc:137`, `timedOut:true`), while green / red / the
#     missing-worktree refusal keep their exact pre-#2210 behaviour
#   - static guards (the non-removable half): the generated worker-gate command
#     carries the bound and group-retires its watchdog, /build 4b's
#     post-enqueue MERGED wait names the armed wake, and 4b's turn-end REFUSAL
#     is a registered mandatory step (kernel § Mandatory-step birth rule) whose
#     execution signal is this very guard — each goes red if the wiring is
#     deleted
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$(cd "$HERE/.." && pwd)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd)"
SCRIPT="$BUILD_DIR/wake-guard.sh"
MJS="$REPO_ROOT/claude/workflows/build-level.mjs"
BUILD_MD="$REPO_ROOT/claude/commands/build.md"
[ -f "$SCRIPT" ] || { echo "FAIL: wake-guard.sh not found at $SCRIPT" >&2; exit 1; }
[ -f "$MJS" ]    || { echo "FAIL: build-level.mjs not found at $MJS" >&2; exit 1; }

PASS=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { PASS=$((PASS + 1)); echo "PASS: $1"; }

TMP="$(mktemp -d)"
# pgrep/pkill -f take an EXTENDED REGEX, not a literal, and a mktemp path is
# full of characters an ERE reads as metacharacters (`.` at minimum, and
# whatever $TMPDIR happens to contain on another host). Escaping them keeps
# every fixture match exact — and keeps the EXIT-time pkill from being a broad
# unanchored sweep over a developer's process table.
TMP_RE="$(printf '%s' "$TMP" | sed -e 's/[][(){}.*+?^$|\\]/\\&/g')"
pg_count() { pgrep -f "$1" 2>/dev/null | wc -l | tr -d ' '; }
cleanup() {
  # Belt: any fixture process that somehow survived must not outlive the suite.
  pkill -f "$TMP_RE" >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

# Every fixture keeps its sentinel/log inside $TMP, never /tmp/qg-*, so a run
# can never read or clobber a real /build worker's gate sentinel.
export TMPDIR="$TMP"

# run <args...> — capture stdout/exit without letting a non-zero abort the run,
# so every exit code is ASSERTED rather than assumed.
OUT=""; RC=0
run() { RC=0; OUT="$(bash "$SCRIPT" "$@" 2>"$TMP/err.txt")" || RC=$?; }

jqf() { printf '%s' "$1" | jq -r "$2" 2>/dev/null; }

# ============================================================================
# assert — the REFUSAL
# ============================================================================
run assert --open 0
[ "$RC" -eq 0 ] || fail "assert --open 0 exit $RC, want 0"
[ "$(jqf "$OUT" .outcome)" = "NO_OPEN_WORK" ] || fail "assert --open 0 outcome: $OUT"
ok "assert: no open work needs no wake source"

run assert --open 2 --wake poll
[ "$RC" -eq 0 ] || fail "assert armed exit $RC, want 0"
[ "$(jqf "$OUT" .outcome)" = "WAKE_ARMED" ] || fail "assert armed outcome: $OUT"
ok "assert: open work with an armed wake passes"

run assert --open 2
[ "$RC" -eq 4 ] || fail "assert unarmed exit $RC, want 4"
[ "$(jqf "$OUT" .outcome)" = "NO_WAKE_SOURCE" ] || fail "assert unarmed outcome: $OUT"
[ "$(jqf "$OUT" .open)" = "2" ] || fail "assert unarmed open count: $OUT"
[ -n "$(jqf "$OUT" .remedy)" ] || fail "assert unarmed carries no remedy: $OUT"
ok "assert: open work with NOTHING scheduled is refused, non-zero, with a remedy"

# The closed set matters: the failure this whole item guards is a wake that was
# BELIEVED armed and was not, so an unrecognised kind must never read as armed.
run assert --open 2 --wake monitor-ish
[ "$RC" -eq 1 ] || fail "assert unknown-kind exit $RC, want 1"
[ "$(jqf "$OUT" .outcome)" = "ERROR" ] || fail "assert unknown-kind outcome: $OUT"
ok "assert: an unrecognised wake kind ERRORs, it is never accepted as armed"

# ============================================================================
# bound — the kill-not-detach watchdog
# ============================================================================
# The fixture spawns grandchildren and then sleeps, which is the shape that
# left orphaned process trees behind in the real incident.
cat > "$TMP/hang.sh" <<'EOF'
#!/usr/bin/env bash
echo started
bash -c 'sleep 600' &
bash -c 'sleep 600' &
sleep 600
EOF
chmod +x "$TMP/hang.sh"

T0=$(date +%s)
run bound --label hang --timeout-secs 2 -- "$TMP/hang.sh"
ELAPSED=$(( $(date +%s) - T0 ))
[ "$RC" -eq 137 ] || fail "bound hang exit $RC, want 137"
LAST="$(printf '%s\n' "$OUT" | tail -1)"
[ "$(jqf "$LAST" .outcome)" = "TIMEOUT" ] || fail "bound hang outcome: $LAST"
[ "$(jqf "$LAST" .killed)" = "true" ] || fail "bound hang killed flag: $LAST"
[ "$(jqf "$LAST" .bound_secs)" = "2" ] || fail "bound hang bound_secs: $LAST"
[ "$ELAPSED" -ge 2 ] && [ "$ELAPSED" -le 8 ] || fail "bound hang took ${ELAPSED}s, want ~2s"
sleep 1
SURVIVORS="$(pg_count "$TMP_RE/hang\.sh")"
[ "$SURVIVORS" = "0" ] || fail "bound hang left $SURVIVORS process(es) running — DETACHED, not killed"
ok "bound: a hanging command is KILLED at its bound, reported TIMEOUT, tree reaped"

# CONTROL: without the bound the same fixture runs on unbounded — this is what
# makes the assertion above discriminating rather than vacuously true.
"$TMP/hang.sh" >/dev/null 2>&1 &
CTRL=$!
sleep 3
kill -0 "$CTRL" 2>/dev/null || fail "control fixture died on its own — the hang assertion proves nothing"
disown "$CTRL" 2>/dev/null || true
kill -9 "$CTRL" 2>/dev/null; pkill -f "$TMP_RE/hang\.sh" >/dev/null 2>&1
ok "bound: CONTROL — the same fixture runs on unbounded when nothing guards it"

T0=$(date +%s)
run bound --label fast --timeout-secs 30 -- bash -c 'echo pass-through; exit 3'
ELAPSED=$(( $(date +%s) - T0 ))
[ "$RC" -eq 3 ] || fail "bound fast exit $RC, want the command's own 3"
[ "$OUT" = "pass-through" ] || fail "bound fast stdout: [$OUT]"
[ "$ELAPSED" -le 5 ] || fail "bound fast took ${ELAPSED}s — the watchdog's sleep is holding the pipe open (foundation#861)"
ok "bound: a fast command's stdout + exit status pass through, and it returns at once"

# The watchdog must not depend on the thing it watches. This fixture TRAPS and
# ignores SIGTERM — a cooperative kill would never land — and the guard still
# reaps it, because it signals with SIGKILL against a pid it captured up front.
cat > "$TMP/stubborn.sh" <<'EOF'
#!/usr/bin/env bash
trap '' TERM INT HUP
while :; do sleep 1; done
EOF
chmod +x "$TMP/stubborn.sh"
T0=$(date +%s)
run bound --label stubborn --timeout-secs 2 -- "$TMP/stubborn.sh"
ELAPSED=$(( $(date +%s) - T0 ))
[ "$RC" -eq 137 ] || fail "bound stubborn exit $RC, want 137"
[ "$ELAPSED" -le 8 ] || fail "bound stubborn took ${ELAPSED}s — the guard waited on the watched process"
sleep 1
[ "$(pg_count "$TMP_RE/stubborn\.sh")" = "0" ] \
  || fail "bound stubborn survived — a SIGTERM-ignoring process outlived its bound"
ok "bound: a SIGTERM-ignoring process is still reaped — the guard needs no cooperation"

# The #2065 cause-3 shape, pinned statically: a guard written as
# `until ! pgrep -f <pattern>` asks the watched process's own liveness for
# permission to fire, and a pattern that matches nothing reads exactly like a
# process that finished.
# Comments are stripped first: the header EXPLAINS the `pgrep -f` shape at
# length, and a check that fired on its own rationale would be unfixable.
CODE="$(sed 's/#.*//' "$SCRIPT")"
printf '%s' "$CODE" | grep 'pgrep -f' >/dev/null && fail "wake-guard.sh greps for a command PATTERN — the watchdog must not depend on what it watches"
printf '%s' "$CODE" | grep -E 'until[[:space:]]+!' >/dev/null && fail "wake-guard.sh polls the watched process's liveness (until ! …)"
ok "bound: the guard carries no pattern-liveness check (the #2065 cause-3 shape)"

# SIGNALS REAP THE GROUP TOO, NOT JUST THE BOUND. `set -m` moves the watched
# command into its OWN process group — out of wake-guard.sh's foreground group
# — so a signal delivered to the guard does NOT reach the child. With no
# handler installed the guard dies and the child survives FULLY DETACHED: this
# item's own defect class, arriving through the signal door instead of the
# timeout door. All four terminating signals must reap before exiting, and each
# green arm below is paired with its own RED arm (the same discrimination shape
# tests/test_bounded_suite.sh case 9 uses for the script this one is modelled on).
export SIG_PIDFILE="$TMP/sig.child.pid"
cat > "$TMP/sigfix.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$SIG_PIDFILE"
bash -c 'sleep 600' &
printf '%s\n' "$!" >> "$SIG_PIDFILE"
sleep 600
EOF
chmod +x "$TMP/sigfix.sh"

SIG_RC=0; SIG_SELF_PID=""; SIG_GC_PID=""
# sig_launch <guard> <signame> — start <guard> on the hanging fixture, wait
# until its tree is genuinely up, signal it, and leave the outcome in
# SIG_RC / SIG_SELF_PID / SIG_GC_PID.
sig_launch() {
  local guard="$1" signame="$2" wpid i=0
  rm -f "$SIG_PIDFILE"
  # `set -m` HERE IS LOAD-BEARING, not a copy of the guard's own. A shell
  # WITHOUT job control sets SIGINT and SIGQUIT to SIG_IGN in every `&` child,
  # and bash cannot re-trap a signal that was ignored on entry — so launching
  # from a plain background job makes the guard DEAF to SIGINT/SIGQUIT and the
  # case would hang (observed) or "pass" against a guard that merely ignored
  # them. Job control gives the job its own group without that ignore, which is
  # also how a terminal delivers Ctrl-C for real.
  #
  # The bound is short on purpose: if a handler ever stops responding, the
  # guard's OWN bound ends the run in ~25s with a 137 the rc assertion below
  # rejects, instead of this case hanging for the fixture's full sleep.
  set -m
  bash "$guard" bound --label "sig-$signame" --timeout-secs 25 -- "$TMP/sigfix.sh" >/dev/null 2>&1 &
  wpid=$!
  set +m
  while [ "$i" -lt 100 ]; do
    [ -s "$SIG_PIDFILE" ] && [ "$(wc -l < "$SIG_PIDFILE")" -ge 2 ] && break
    sleep 0.1; i=$((i + 1))
  done
  SIG_SELF_PID="$(sed -n 1p "$SIG_PIDFILE" 2>/dev/null)"
  SIG_GC_PID="$(sed -n 2p "$SIG_PIDFILE" 2>/dev/null)"
  if [ -z "$SIG_SELF_PID" ] || [ -z "$SIG_GC_PID" ]; then
    kill -9 "$wpid" 2>/dev/null
    fail "SIG$signame: the fixture never recorded its own pid AND its grandchild's — every survival assertion would be vacuous"
  fi
  kill -0 "$SIG_SELF_PID" 2>/dev/null \
    || fail "SIG$signame: the watched command was already dead BEFORE the signal — nothing was under test"
  kill -0 "$SIG_GC_PID" 2>/dev/null \
    || fail "SIG$signame: the grandchild was already dead BEFORE the signal — nothing was under test"
  kill -"$signame" "$wpid" 2>/dev/null || fail "SIG$signame: could not signal the guard (pid $wpid)"
  SIG_RC=0
  wait "$wpid" 2>/dev/null || SIG_RC=$?
  sleep 1
  return 0
}

# 129/130/131/143 are the conventional 128+SIGHUP / +SIGINT / +SIGQUIT / +SIGTERM.
for _sigpair in HUP:129 INT:130 QUIT:131 TERM:143; do
  _signame="${_sigpair%%:*}"; _sigcode="${_sigpair##*:}"
  sig_launch "$SCRIPT" "$_signame"
  [ "$SIG_RC" -eq "$_sigcode" ] \
    || fail "SIG$_signame: the guard must exit $_sigcode (128+signal), got $SIG_RC"
  kill -0 "$SIG_SELF_PID" 2>/dev/null \
    && fail "SIG$_signame: the WATCHED command survived the guard — \`set -m\` moved it out of the caller's group, so it is now fully DETACHED: this item's own defect class through the signal door"
  kill -0 "$SIG_GC_PID" 2>/dev/null \
    && fail "SIG$_signame: the watched command's GRANDCHILD survived — an orphaned process tree, exactly what the 12.5h stall left behind"

  # RED ARM: splice _wg_reap out of THIS ONE handler. Without it the tree must
  # survive — otherwise something other than the handler is doing the reaping
  # and the green arm above proves nothing.
  _sigmutant="$TMP/sig-mutant-$_signame.sh"
  sed "s/trap '_wg_reap; exit $_sigcode' $_signame/trap 'exit $_sigcode' $_signame/" "$SCRIPT" > "$_sigmutant"
  if diff -q "$SCRIPT" "$_sigmutant" >/dev/null 2>&1; then
    fail "SIG$_signame: RED-arm splice found no \`trap '_wg_reap; exit $_sigcode' $_signame\` line — the signal is unarmed or armed in an unexpected shape, so its discrimination proof is inert"
  fi
  sig_launch "$_sigmutant" "$_signame"
  if ! kill -0 "$SIG_SELF_PID" 2>/dev/null && ! kill -0 "$SIG_GC_PID" 2>/dev/null; then
    fail "SIG$_signame: RED arm — with _wg_reap spliced out the watched tree died anyway, so the green arm above is not produced by the handler"
  fi
  # Reap what the RED arm deliberately left detached. GROUP first — the guard's
  # own `set -m` made the fixture a process-group leader, and the fixture's own
  # `sleep` is a child of it that a bare pid kill would leave behind (the very
  # orphan this suite asserts against elsewhere, so the suite must not create
  # one itself) — then the bare pids as the fallback.
  kill -9 -"$SIG_SELF_PID" 2>/dev/null
  kill -9 "$SIG_GC_PID" "$SIG_SELF_PID" 2>/dev/null
done
ok "bound: HUP/INT/QUIT/TERM each REAP the watched group before exiting (each with its own RED arm), never detach it"

# The watchdog's own `sleep` must not outlive the call it guarded. `kill "$wd"`
# signals only the subshell; its `sleep` is a separate child OF that subshell,
# so a bare kill reparents it to init for the FULL bound — one stray process
# per fast call, and `arm` arms one watchdog per PR.
# The watched command sleeps a beat on purpose: the watchdog's `sleep` has to
# have actually FORKED before the retire, or a race would make this assertion
# pass vacuously.
WD_BOUND=9173
sleep_count() { ps -eo command 2>/dev/null | grep -c "^sleep $1\$" || true; }
run bound --label orphan --timeout-secs "$WD_BOUND" -- bash -c 'sleep 1; exit 0'
[ "$RC" -eq 0 ] || fail "bound orphan-probe exit $RC, want 0"
sleep 1
STRAY="$(sleep_count "$WD_BOUND")"
[ "$STRAY" = "0" ] || fail "the retired watchdog orphaned $STRAY 'sleep $WD_BOUND' process(es) — it idles for the whole bound"
ok "bound: retiring the watchdog on the fast path takes its sleep with it"

# CONTROL: the PRE-FIX shape — a watchdog started WITHOUT job control (so it
# shares the caller's process group) and retired with a bare `kill $wd` — does
# orphan its sleep. That is what makes the assertion above discriminating
# rather than vacuously true.
bash -c '( sleep 9174 2>/dev/null; : ) </dev/null >/dev/null 2>&1 & __w=$!; sleep 0.5; kill "$__w" 2>/dev/null; wait "$__w" 2>/dev/null' >/dev/null 2>&1
sleep 1
CTRL_STRAY="$(sleep_count 9174)"
pkill -f '^sleep 9174' >/dev/null 2>&1 || true
[ "$CTRL_STRAY" -ge 1 ] || fail "CONTROL: the pre-fix bare-kill retire did NOT orphan its sleep here — the orphan assertion above proves nothing"
ok "bound: CONTROL — the pre-fix bare-kill retire orphans its sleep, which is what the group retire fixes"

# A zero-padded value passes a digits-only check and then aborts `$(( ))` as
# invalid OCTAL — the shell dies mid-expansion and emits NO JSON at all, which
# breaks the closed-outcome contract. Reachable from config as well as the CLI.
run assert --open 09 --wake poll
[ "$RC" -eq 0 ] || fail "assert --open 09 exit $RC, want 0 ($(cat "$TMP/err.txt"))"
[ "$(jqf "$OUT" .outcome)" = "WAKE_ARMED" ] || fail "assert zero-padded outcome: $OUT"
[ "$(jqf "$OUT" .open)" = "9" ] || fail "assert zero-padded open count not normalised to decimal: $OUT"
ok "assert: a zero-padded count is normalised to decimal, never parsed as octal"

# ============================================================================
# arm — the wake source, armed
# ============================================================================
run arm owner/repo
[ "$RC" -eq 0 ] || fail "arm with no PRs exit $RC, want 0"
[ "$(jqf "$OUT" .outcome)" = "NO_OPEN_WORK" ] || fail "arm no-PR outcome: $OUT"
ok "arm: an empty in-flight set is NO_OPEN_WORK, not an error"

# A fake `gh` on PATH drives the REAL gate.sh poll loop: deterministic, zero
# network (Principle 3 — recorded fixture, never a live system).
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
n=$(( $(cat "$GH_COUNT" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$GH_COUNT"
case "${GH_MODE:-merge}" in
  never)   echo '{"state":"OPEN","mergedAt":null,"mergeable":"MERGEABLE","mergeStateStatus":"BLOCKED"}' ;;
  dirty)   echo '{"state":"OPEN","mergedAt":null,"mergeable":"CONFLICTING","mergeStateStatus":"DIRTY"}' ;;
  *) if [ "$n" -ge "${GH_MERGE_AT:-3}" ]; then
       echo '{"state":"MERGED","mergedAt":"2026-09-24T00:00:00Z","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}'
     else
       echo '{"state":"OPEN","mergedAt":null,"mergeable":"MERGEABLE","mergeStateStatus":"BLOCKED"}'
     fi ;;
esac
EOF
chmod +x "$TMP/bin/gh"

arm() { RC=0; OUT="$(PATH="$TMP/bin:$PATH" bash "$SCRIPT" arm "$@" 2>"$TMP/err.txt")" || RC=$?; }

# THE CENTRAL FIXTURE. The queue merges the PR at read 3 — i.e. AFTER the point
# at which an orchestrator that armed nothing would already have ended its turn
# and stopped listening. The armed wake sees it one interval later.
export GH_COUNT="$TMP/c1" GH_MODE=merge GH_MERGE_AT=3
T0=$(date +%s)
arm owner/repo 7 --interval 1 --timeout 30
ELAPSED=$(( $(date +%s) - T0 ))
[ "$RC" -eq 0 ] || fail "arm merge-after-turn-end exit $RC, want 0 ($OUT / $(cat "$TMP/err.txt"))"
[ "$(jqf "$OUT" .outcome)" = "RESUMED" ] || fail "arm merge-after-turn-end outcome: $OUT"
[ "$(jqf "$OUT" '.merged | join(",")')" = "7" ] || fail "arm merged set: $OUT"
# "within one poll interval": the merge became visible on read 3, i.e. 2
# intervals in; resuming by interval 3 is within one interval of it.
[ "$ELAPSED" -le 3 ] || fail "arm resumed after ${ELAPSED}s — more than one poll interval past the merge"
ok "arm: a merge that lands AFTER the turn would have ended resumes within one poll interval"

# DISCRIMINATION CONTROL. Same fixture, same assertions available — but the PR
# never merges, so the RESUMED verdict above is something this check CAN fail.
export GH_COUNT="$TMP/c2" GH_MODE=never
T0=$(date +%s)
arm owner/repo 7 --interval 1 --timeout 3
ELAPSED=$(( $(date +%s) - T0 ))
[ "$RC" -eq 4 ] || fail "arm never-merges exit $RC, want 4"
[ "$(jqf "$OUT" .outcome)" = "TIMEOUT" ] || fail "arm never-merges outcome: $OUT"
[ "$ELAPSED" -le 10 ] || fail "arm never-merges took ${ELAPSED}s — it did not stop at its bound"
ok "arm: CONTROL — a PR that never merges TIMEOUTs at the bound, so RESUMED discriminates"

export GH_COUNT="$TMP/c3" GH_MODE=dirty
arm owner/repo 7 --interval 1 --timeout 10
[ "$RC" -eq 3 ] || fail "arm conflicting exit $RC, want 3"
[ "$(jqf "$OUT" .outcome)" = "CONFLICTING" ] || fail "arm conflicting outcome: $OUT"
ok "arm: gate.sh's terminal-bad verdict is relayed verbatim with its own exit code"

# A WEDGED poll: gate.sh itself never reaches its own deadline. The outer
# watchdog — the belt to gate.sh's suspenders — is what turns that into a
# reported TIMEOUT instead of a process nobody is waiting on.
cat > "$TMP/wedged-gate.sh" <<'EOF'
#!/usr/bin/env bash
sleep 600
EOF
chmod +x "$TMP/wedged-gate.sh"
T0=$(date +%s)
arm owner/repo 7 --interval 1 --timeout 2 --gate-bin "$TMP/wedged-gate.sh"
ELAPSED=$(( $(date +%s) - T0 ))
[ "$RC" -eq 4 ] || fail "arm wedged-poll exit $RC, want 4"
[ "$(jqf "$OUT" .outcome)" = "TIMEOUT" ] || fail "arm wedged-poll outcome: $OUT"
[ "$(jqf "$OUT" .killed)" = "true" ] || fail "arm wedged-poll killed flag: $OUT"
[ "$ELAPSED" -le 12 ] || fail "arm wedged-poll took ${ELAPSED}s — the outer bound never fired"
sleep 1
[ "$(pg_count "$TMP_RE/wedged-gate\.sh")" = "0" ] \
  || fail "arm wedged-poll left the poll running — detached, not killed"
ok "arm: a wedged poll is killed at the derived outer bound and reported TIMEOUT"

# ONE BUDGET FOR THE WHOLE PR SET. `arm` polls sequentially, and a level
# routinely selects more than one PR, so a PER-PR bound would let N ordinary
# queue waits SUM past the harness's foreground ceiling — at which point the
# harness auto-backgrounds this very call and the turn ends with the verdict
# lost. That is #2210's own defect reintroduced through the new mechanism.
cat > "$TMP/slow-merge-gate.sh" <<'EOF'
#!/usr/bin/env bash
sleep 1
echo '{"outcome":"MERGED","pr":0,"mergedAt":"2026-09-24T00:00:00Z"}'
exit 0
EOF
chmod +x "$TMP/slow-merge-gate.sh"

T0=$(date +%s)
arm owner/repo 21 22 23 24 --interval 1 --timeout 3 --gate-bin "$TMP/slow-merge-gate.sh"
ELAPSED=$(( $(date +%s) - T0 ))
[ "$RC" -eq 4 ] || fail "arm multi-PR budget exit $RC, want 4 — the set spent more than its one shared budget ($OUT)"
[ "$(jqf "$OUT" .outcome)" = "TIMEOUT" ] || fail "arm multi-PR budget outcome: $OUT"
[ "$(jqf "$OUT" .budget_secs)" = "3" ] || fail "arm multi-PR budget_secs: $OUT"
printf '%s' "$(jqf "$OUT" .reason)" | grep 'budget' >/dev/null || fail "arm multi-PR budget reason does not name the budget: $OUT"
[ -n "$(jqf "$OUT" .pr)" ] || fail "arm multi-PR budget names no unfinished PR: $OUT"
[ "$ELAPSED" -le 8 ] || fail "arm multi-PR took ${ELAPSED}s against a 3s budget — the set is NOT sharing one deadline"
ok "arm: a multi-PR set shares ONE wall-clock budget and stops at it, never sums past the foreground ceiling"

# DISCRIMINATION CONTROL: the identical 4-PR fixture with a budget wide enough
# RESUMES all four — so the TIMEOUT above is a real budget verdict, not this
# fixture simply being unable to merge.
T0=$(date +%s)
arm owner/repo 21 22 23 24 --interval 1 --timeout 60 --gate-bin "$TMP/slow-merge-gate.sh"
ELAPSED=$(( $(date +%s) - T0 ))
[ "$RC" -eq 0 ] || fail "arm multi-PR control exit $RC, want 0 ($OUT / $(cat "$TMP/err.txt"))"
[ "$(jqf "$OUT" .outcome)" = "RESUMED" ] || fail "arm multi-PR control outcome: $OUT"
[ "$(jqf "$OUT" '.merged | join(",")')" = "21,22,23,24" ] || fail "arm multi-PR control merged set: $OUT"
[ "$ELAPSED" -le 20 ] || fail "arm multi-PR control took ${ELAPSED}s"
ok "arm: CONTROL — the same four PRs under a wide budget all RESUME, so the budget TIMEOUT discriminates"

# Zero-padded interval/PR: digits-only validation accepts them and `$(( ))`
# then rejects them as invalid octal, aborting the shell with NO JSON at all —
# and `007` is not valid JSON for `jq --argjson` either.
arm owner/repo 007 --interval 08 --timeout 30 --gate-bin "$TMP/slow-merge-gate.sh"
[ "$RC" -eq 0 ] || fail "arm zero-padded exit $RC, want 0 ($OUT / $(cat "$TMP/err.txt"))"
[ "$(jqf "$OUT" .outcome)" = "RESUMED" ] || fail "arm zero-padded outcome (no JSON = the shell aborted mid-expansion): $OUT"
[ "$(jqf "$OUT" '.merged | join(",")')" = "7" ] || fail "arm zero-padded PR not normalised to decimal: $OUT"
ok "arm: zero-padded interval/PR values are normalised, never parsed as octal or emitted as invalid JSON"

# SOURCING SAFETY. This file advertises itself as sourceable (the dispatch
# guard at the bottom), so cmd_arm must not install a process-wide `trap …
# EXIT`: that silently REPLACES the sourcing caller's own cleanup trap, and
# tracks only the latest scratch across repeat calls, leaking the earlier one.
mkdir -p "$TMP/probe"
cat > "$TMP/source-probe.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
trap 'printf caller-trap-ran > "$PROBE_MARK"' EXIT
# shellcheck disable=SC1090
. "$WG_SCRIPT"
cmd_arm owner/repo 11 --interval 1 --timeout 20 --gate-bin "$FAKE_GATE" >/dev/null
cmd_arm owner/repo 12 --interval 1 --timeout 20 --gate-bin "$FAKE_GATE" >/dev/null
EOF
PROBE_RC=0
PROBE_MARK="$TMP/probe/mark" WG_SCRIPT="$SCRIPT" FAKE_GATE="$TMP/slow-merge-gate.sh" \
  TMPDIR="$TMP/probe" bash "$TMP/source-probe.sh" >/dev/null 2>"$TMP/probe/err.txt" || PROBE_RC=$?
[ "$PROBE_RC" -eq 0 ] || fail "sourced cmd_arm probe exited $PROBE_RC: $(cat "$TMP/probe/err.txt")"
[ "$(cat "$TMP/probe/mark" 2>/dev/null || true)" = "caller-trap-ran" ] \
  || fail "sourcing wake-guard.sh and calling cmd_arm CLOBBERED the caller's own EXIT trap"
LEFT="$(find "$TMP/probe" -name 'wake-guard.*' 2>/dev/null | wc -l | tr -d ' ')"
[ "$LEFT" = "0" ] || fail "cmd_arm left $LEFT scratch file(s) behind across repeat sourced calls"
ok "arm: sourced repeat calls keep the caller's EXIT trap and leave no scratch file behind"

# ============================================================================
# build-level.mjs — the worker's own scoped gate, EXECUTED
# ============================================================================
# The generated command is extracted from the real .mjs source and run for real
# against a fixture suite. Asserting on the emitted TEXT alone would pass a
# command that cannot work; this runs it.
cat > "$TMP/extract.mjs" <<'EOF'
import fs from 'node:fs';
const src = fs.readFileSync(process.env.MJS_PATH, 'utf8');
const grab = (name) => {
  const m = src.match(new RegExp('\\nfunction ' + name + '\\([\\s\\S]*?\\n}\\n'));
  if (!m) { console.error('not found: ' + name); process.exit(2); }
  return m[0];
};
const fn = new Function([
  'const WORKER_GATE_CEILING_SECS = ' + Number(process.env.CEIL) + ';',
  grab('sq'), grab('workerGateSentinel'), grab('workerGateLog'),
  grab('killNotDetachWatchdog'), grab('retireWatchdog'), grab('workerGateCmd'),
  'return workerGateCmd;',
].join('\n'))();
process.stdout.write(fn(process.argv[2], process.argv[3]));
EOF
export MJS_PATH="$MJS"

gate_cmd() { CEIL="$1" node "$TMP/extract.mjs" "$2" "$3"; }
# The generated command writes its sentinel to /tmp/qg-<slug>.worker-gate.json,
# so every fixture uses a run-unique slug and cleans up after itself.
SLUG_BASE="wakeguard-$$"
sentinel_of() { printf '/tmp/qg-%s.worker-gate.json' "$1"; }
rm_sentinels() { rm -f "/tmp/qg-${SLUG_BASE}"*.worker-gate.json "/tmp/qg-${SLUG_BASE}"*.worker-gate.log; }
trap 'rm_sentinels; cleanup' EXIT

mkdir -p "$TMP/wt/scripts"
write_gate() { printf '%s\n' "$@" > "$TMP/wt/scripts/quality-gates.sh"; chmod +x "$TMP/wt/scripts/quality-gates.sh"; }

# 1. A HANGING suite — the 12.5h shape.
write_gate '#!/usr/bin/env bash' 'echo "gate starting"' "bash -c 'sleep 600' &" "bash -c 'sleep 600' &" 'sleep 600'
SLUG="${SLUG_BASE}-hang"
CMD="$(gate_cmd 3 "$SLUG" "$TMP/wt")"
T0=$(date +%s); RC=0
OUT="$(bash -c "$CMD" 2>&1)" || RC=$?
ELAPSED=$(( $(date +%s) - T0 ))
SENT="$(cat "$(sentinel_of "$SLUG")" 2>/dev/null || echo '')"
[ "$RC" -eq 137 ] || fail "worker gate hang exit $RC, want 137"
[ "$ELAPSED" -le 10 ] || fail "worker gate hang took ${ELAPSED}s — the compiled bound never fired"
[ "$(jqf "$SENT" .state)" = "finished" ] || fail "worker gate hang sentinel state: $SENT"
[ "$(jqf "$SENT" .rc)" = "137" ] || fail "worker gate hang sentinel rc: $SENT"
[ "$(jqf "$SENT" .timedOut)" = "true" ] || fail "worker gate hang sentinel timedOut: $SENT"
[ "$(jqf "$SENT" .outcome)" = "TIMEOUT" ] || fail "worker gate hang sentinel outcome: $SENT"
sleep 1
[ "$(pg_count "$TMP_RE/wt/scripts/quality-gates\.sh")" = "0" ] \
  || fail "worker gate hang left the suite running — DETACHED, not killed (the 12.5h shape)"
ok "worker gate: a hanging suite is killed at its bound and the sentinel reports TIMEOUT"

# 2-4. CONTROLS — the three pre-#2210 paths must be untouched.
write_gate '#!/usr/bin/env bash' 'echo "all gates passed in 2s"' 'exit 0'
SLUG="${SLUG_BASE}-green"; RC=0
OUT="$(bash -c "$(gate_cmd 60 "$SLUG" "$TMP/wt")" 2>&1)" || RC=$?
SENT="$(cat "$(sentinel_of "$SLUG")" 2>/dev/null || echo '')"
[ "$RC" -eq 0 ] || fail "worker gate green exit $RC, want 0"
[ "$(jqf "$SENT" .state)" = "finished" ] || fail "worker gate green state: $SENT"
[ "$(jqf "$SENT" .rc)" = "0" ] || fail "worker gate green rc: $SENT"
[ "$(jqf "$SENT" .timedOut)" = "null" ] || fail "worker gate green must not claim a timeout: $SENT"
printf '%s\n' "$OUT" | grep 'all gates passed in 2s' >/dev/null || fail "worker gate green lost the suite's stdout: $OUT"
ok "worker gate: CONTROL — a green suite still exits 0, keeps its stdout, writes no timeout"

write_gate '#!/usr/bin/env bash' 'echo "1 gate FAILED"' 'exit 1'
SLUG="${SLUG_BASE}-red"; RC=0
OUT="$(bash -c "$(gate_cmd 60 "$SLUG" "$TMP/wt")" 2>&1)" || RC=$?
SENT="$(cat "$(sentinel_of "$SLUG")" 2>/dev/null || echo '')"
[ "$RC" -eq 1 ] || fail "worker gate red exit $RC, want the suite's own 1"
[ "$(jqf "$SENT" .rc)" = "1" ] || fail "worker gate red sentinel rc: $SENT"
[ "$(jqf "$SENT" .timedOut)" = "null" ] || fail "worker gate red must not claim a timeout: $SENT"
ok "worker gate: CONTROL — a red suite still reports its own non-zero rc, not a timeout"

SLUG="${SLUG_BASE}-nowt"; RC=0
OUT="$(bash -c "$(gate_cmd 60 "$SLUG" "$TMP/does-not-exist")" 2>&1)" || RC=$?
[ "$RC" -eq 1 ] || fail "worker gate missing-worktree exit $RC, want 1"
[ -f "$(sentinel_of "$SLUG")" ] && fail "worker gate refusal wrote a sentinel — a refusal must leave none"
ok "worker gate: CONTROL — the missing-worktree refusal still writes no sentinel at all"

# ============================================================================
# STATIC GUARDS — the wiring itself, so removing it goes red
# ============================================================================
GEN="$(gate_cmd 900 "${SLUG_BASE}-static" /tmp/x)"
printf '%s' "$GEN" | grep 'set -m;' >/dev/null \
  || fail "the generated worker-gate command no longer starts the suite in its own process group"
# shellcheck disable=SC2016  # the shell VARIABLE NAMES are the literal text
#   being searched for in the generated command — expansion would defeat the check.
printf '%s' "$GEN" | grep 'sleep "\$__wgb"' >/dev/null \
  || fail "the generated worker-gate command no longer arms a wall-clock watchdog"
# shellcheck disable=SC2016  # same: the literal variable name IS the pattern.
printf '%s' "$GEN" | grep 'kill -9 -"\$__wgp"' >/dev/null \
  || fail "the generated worker-gate command no longer group-kills the suite at its bound"
printf '%s' "$GEN" | grep '"timedOut":true' >/dev/null \
  || fail "the generated worker-gate command no longer reports a bound kill as TIMEOUT"
# The watchdog is retired by GROUP, not by bare pid: a bare kill signals the
# subshell only and orphans its `sleep` for the whole ceiling.
# shellcheck disable=SC2016  # the literal variable name IS the pattern.
printf '%s' "$GEN" | grep 'kill -- -"\$__wgw"' >/dev/null \
  || fail "the generated worker-gate command no longer group-retires its watchdog — its sleep is orphaned for the full bound"
ok "static: the generated worker-gate command carries its kill-not-detach bound"

grep -q 'wake-guard.sh arm' "$BUILD_MD" \
  || fail "/build no longer names the armed wake (wake-guard.sh arm) — the MERGED wait can end a turn with nothing scheduled again"
awk '/^2\. \*\*Timeout ceiling/ && /wake-guard\.sh arm/ { found = 1 } END { exit found ? 0 : 1 }' "$BUILD_MD" \
  || fail "/build 4b step 2 (the post-enqueue MERGED wait) no longer arms the wake"
ok "static: /build 4b's post-enqueue MERGED wait names the armed wake"

# THE REFUSAL is the last line of defense — a turn that ends with open work and
# nothing scheduled. It is declared MANDATORY in the spec, so per the kernel's
# § Mandatory-step birth rule it ships an execution signal in the same change:
# this guard IS that signal (registered in mandatory-step-registry.tsv), and it
# goes red the moment 4b stops invoking `wake-guard.sh assert`.
grep -q 'wake-guard.sh assert' "$BUILD_MD" \
  || fail "/build no longer invokes the turn-end refusal (wake-guard.sh assert) — a turn can end with open work and nothing scheduled again"
awk '/wake-guard\.sh assert/ && /mandatory before ending ANY turn at this step/ { found = 1 } END { exit found ? 0 : 1 }' "$BUILD_MD" \
  || fail "/build's wake-guard.sh assert invocation no longer carries its mandatory declaration — mandatory-step-registry.tsv's DECLARATION for it is now dangling"
REGISTRY="$REPO_ROOT/workflows/scripts/config/mandatory-step-registry.tsv"
grep -q 'turn-end wake assertion' "$REGISTRY" \
  || fail "the turn-end wake assertion has no mandatory-step-registry.tsv row — a step declared mandatory with no execution signal is the #1616 defect class"
ok "static: the turn-end refusal is a REGISTERED mandatory step, not prose (kernel § Mandatory-step birth rule)"

echo
echo "All $PASS wake-guard checks passed."
