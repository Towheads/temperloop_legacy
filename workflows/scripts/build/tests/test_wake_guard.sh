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
#   - build-level.mjs: the GENERATED worker-gate command is executed for real —
#     a hanging suite is killed at its bound and the sentinel says TIMEOUT
#     (`state:finished`, `rc:137`, `timedOut:true`), while green / red / the
#     missing-worktree refusal keep their exact pre-#2210 behaviour
#   - static guards (the non-removable half): the generated worker-gate command
#     carries the bound, and /build 4b's post-enqueue MERGED wait names the
#     armed wake — each goes red if the wiring is deleted
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
cleanup() {
  # Belt: any fixture process that somehow survived must not outlive the suite.
  pkill -f "$TMP" >/dev/null 2>&1 || true
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
cat > "$TMP/hang.sh" <<EOF
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
SURVIVORS="$(pgrep -f "$TMP/hang.sh" 2>/dev/null | wc -l | tr -d ' ')"
[ "$SURVIVORS" = "0" ] || fail "bound hang left $SURVIVORS process(es) running — DETACHED, not killed"
ok "bound: a hanging command is KILLED at its bound, reported TIMEOUT, tree reaped"

# CONTROL: without the bound the same fixture runs on unbounded — this is what
# makes the assertion above discriminating rather than vacuously true.
"$TMP/hang.sh" >/dev/null 2>&1 &
CTRL=$!
sleep 3
kill -0 "$CTRL" 2>/dev/null || fail "control fixture died on its own — the hang assertion proves nothing"
disown "$CTRL" 2>/dev/null || true
kill -9 "$CTRL" 2>/dev/null; pkill -f "$TMP/hang.sh" >/dev/null 2>&1
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
[ "$(pgrep -f "$TMP/stubborn.sh" 2>/dev/null | wc -l | tr -d ' ')" = "0" ] \
  || fail "bound stubborn survived — a SIGTERM-ignoring process outlived its bound"
ok "bound: a SIGTERM-ignoring process is still reaped — the guard needs no cooperation"

# The #2065 cause-3 shape, pinned statically: a guard written as
# `until ! pgrep -f <pattern>` asks the watched process's own liveness for
# permission to fire, and a pattern that matches nothing reads exactly like a
# process that finished.
# Comments are stripped first: the header EXPLAINS the `pgrep -f` shape at
# length, and a check that fired on its own rationale would be unfixable.
CODE="$(sed 's/#.*//' "$SCRIPT")"
printf '%s' "$CODE" | grep -q 'pgrep -f' && fail "wake-guard.sh greps for a command PATTERN — the watchdog must not depend on what it watches"
printf '%s' "$CODE" | grep -qE 'until[[:space:]]+!' && fail "wake-guard.sh polls the watched process's liveness (until ! …)"
ok "bound: the guard carries no pattern-liveness check (the #2065 cause-3 shape)"

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
[ "$(pgrep -f "$TMP/wedged-gate.sh" 2>/dev/null | wc -l | tr -d ' ')" = "0" ] \
  || fail "arm wedged-poll left the poll running — detached, not killed"
ok "arm: a wedged poll is killed at the derived outer bound and reported TIMEOUT"

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
  grab('killNotDetachWatchdog'), grab('workerGateCmd'),
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
[ "$(pgrep -f "$TMP/wt/scripts/quality-gates.sh" 2>/dev/null | wc -l | tr -d ' ')" = "0" ] \
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
printf '%s\n' "$OUT" | grep -q 'all gates passed in 2s' || fail "worker gate green lost the suite's stdout: $OUT"
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
printf '%s' "$GEN" | grep -q 'set -m;' \
  || fail "the generated worker-gate command no longer starts the suite in its own process group"
# shellcheck disable=SC2016  # the shell VARIABLE NAMES are the literal text
#   being searched for in the generated command — expansion would defeat the check.
printf '%s' "$GEN" | grep -q 'sleep "\$__wgb"' \
  || fail "the generated worker-gate command no longer arms a wall-clock watchdog"
# shellcheck disable=SC2016  # same: the literal variable name IS the pattern.
printf '%s' "$GEN" | grep -q 'kill -9 -"\$__wgp"' \
  || fail "the generated worker-gate command no longer group-kills the suite at its bound"
printf '%s' "$GEN" | grep -q '"timedOut":true' \
  || fail "the generated worker-gate command no longer reports a bound kill as TIMEOUT"
ok "static: the generated worker-gate command carries its kill-not-detach bound"

grep -q 'wake-guard.sh arm' "$BUILD_MD" \
  || fail "/build no longer names the armed wake (wake-guard.sh arm) — the MERGED wait can end a turn with nothing scheduled again"
awk '/^2\. \*\*Timeout ceiling/ && /wake-guard\.sh arm/ { found = 1 } END { exit found ? 0 : 1 }' "$BUILD_MD" \
  || fail "/build 4b step 2 (the post-enqueue MERGED wait) no longer arms the wake"
ok "static: /build 4b's post-enqueue MERGED wait names the armed wake"

echo
echo "All $PASS wake-guard checks passed."
