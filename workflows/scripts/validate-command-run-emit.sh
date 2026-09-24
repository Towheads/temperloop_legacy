#!/usr/bin/env bash
#
# validate-command-run-emit.sh — presence-lint for the /sweep + /triage
# per-run telemetry emit (foundation #729, epic #724).
#
# /sweep and /triage have no plan-note footer, so nothing else signals that a
# run happened at all. emit-command-run.sh is the fix — but a prose "final
# step" in a skill doc can silently rot (the June silent-failure class: an
# LLM-executed markdown step gets skipped or paraphrased away and nobody
# notices, because the failure mode is an ABSENT record, not an error). This
# script is the mechanical owner that makes that rot loud: it FAILS CI (exit 1)
# if either half of the wiring goes missing —
#
#   1. the script itself (workflows/scripts/emit-command-run.sh) is absent or
#      not executable, or
#   2. its invocation is removed from claude/commands/sweep.md or
#      claude/commands/triage.md — i.e. the skill doc no longer contains a
#      call to `emit-command-run.sh` with `--command sweep` / `--command
#      triage` respectively, or
#   3. (temperloop#1084) a command doc that defines a **`resolved (verdict)`**
#      terminal disposition invokes the emit WITHOUT `--resolved`. That is the
#      exact defect #1084 was filed for: /sweep can terminate an item on a
#      spike verdict, but its emit could only say merged/parked, so the
#      verdict-resolved items vanished and the counts stopped reconciling
#      against items_processed. The check is CONTENT-DERIVED, not a hardcoded
#      doc list: any command doc whose prose declares the `resolved (verdict)`
#      disposition must pass `--resolved`, so a doc that GAINS that disposition
#      later is caught without editing this script. A doc with no such
#      disposition may legitimately omit the flag (it defaults to 0) — but it
#      still has to satisfy the emitter's own
#      `merged + resolved + parked + reported_no_op == items_processed`
#      assertion at run time.
#   4. (temperloop#1103) the same content-derived check, for the
#      **`reported-no-op`** terminal disposition: a command doc whose prose
#      declares it invokes the emit WITHOUT `--reported-no-op`. This is the
#      sibling gap #1103 was filed for: `/fix` can terminate a target on
#      `already-done` / `claimed-elsewhere` with nothing merged, resolved, or
#      parked, but before #1103 the schema had no fourth field to say so —
#      fix.md instead just skipped the emit on those two routes, so a no-op
#      /fix run left NO telemetry record at all. Content-derived the same way
#      as `resolved`: any doc that declares `reported-no-op` must pass
#      `--reported-no-op`, so a future doc that grows this disposition is
#      caught without editing this script.
#   5. (temperloop#1847 escalation round 2) the same content-derived shape,
#      for `/sweep`'s Step 3.6A **epic-closing gate**. Its accounting check —
#      `epics_closed + epics_left_open == epics_reviewed` in
#      emit-command-run.sh — only ACTIVATES when the caller passes
#      `--epics-reviewed`, so a future sweep.md edit that quietly drops the
#      three `--epics-*` flags would exit 0 in a shape indistinguishable from
#      a doc that never touches the extension at all: the mandatory-step
#      declaration would silently rot with a "signal" that was never really
#      armed (the K.52 class this closes). Content-derived the same way as
#      `resolved`/`reported-no-op`: any doc whose prose declares the Step
#      3.6A epic-closing gate (matched on BOTH the `epics_reviewed` field name
#      and the `Step 3.6A` anchor) must pass `--epics-reviewed` on its emit
#      call, so the signal is unconditional on the DOC side.
#   6. (temperloop#2220 — stable command-run id) a caller doc no longer OPENS
#      the run ledger at the run's start (`--open --command <cmd>`). Without
#      it a park-then-merge run's two records share no run_id and the item is
#      counted twice, and a run that emits nothing leaves no marker at all.
#   7. (temperloop#2220 round 5) a doc's `--open` call interpolates a shell
#      variable (`--board "$BOARD"` / `--target "$BOARD"`) without declaring
#      the ORDERING dependency that makes it non-empty, or states the
#      never-stops-a-run carve-out in wording the other docs do not share.
#      See check_open_ordering below for why an empty `--target` is worse
#      than a skipped check: it manufactures a FALSE MISSING-RUN alarm.
#
# This mirrors the validate-capture-backstop.sh shape (same script style, same
# hard-fail-on-half-present contract, wired into scripts/quality-gates.sh
# the same way) — see workflows/scripts/validate-capture-backstop.sh for the sibling
# pattern this one is modeled on.
#
# Usage: workflows/scripts/validate-command-run-emit.sh   (resolves the repo itself)

set -euo pipefail

SCRIPTS_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -P "$SCRIPTS_DIR/../.." && pwd)"
EMIT_SCRIPT="$SCRIPTS_DIR/emit-command-run.sh"
SWEEP_MD="$REPO/claude/commands/sweep.md"
TRIAGE_MD="$REPO/claude/commands/triage.md"
FIX_MD="$REPO/claude/commands/fix.md"

fail=0

# --- 1. the emit script itself must exist and be executable -----------------
if [ ! -f "$EMIT_SCRIPT" ]; then
  echo "FAIL  emit-command-run.sh is missing (expected at $EMIT_SCRIPT)"
  fail=1
elif [ ! -x "$EMIT_SCRIPT" ]; then
  echo "FAIL  emit-command-run.sh exists but is not executable ($EMIT_SCRIPT)"
  fail=1
else
  echo "ok    emit-command-run.sh present and executable"
  # 1b. and it must still accept --resolved / --reported-no-op + still assert
  #     the sum (#1084, extended #1103). Without these the wiring below is
  #     cosmetic: the callers would pass a flag the script silently drops (the
  #     `WARN unknown argument` arm).
  if ! grep -Eq -- '--resolved\)' "$EMIT_SCRIPT"; then
    echo "FAIL  emit-command-run.sh no longer parses --resolved — the verdict-resolved disposition (temperloop#1084) lost its telemetry field"
    fail=1
  elif ! grep -Eq -- '--reported-no-op\)' "$EMIT_SCRIPT"; then
    echo "FAIL  emit-command-run.sh no longer parses --reported-no-op — the reported-no-op disposition (temperloop#1103) lost its telemetry field"
    fail=1
  elif ! grep -Fq 'disposition_total' "$EMIT_SCRIPT"; then
    echo "FAIL  emit-command-run.sh parses --resolved/--reported-no-op but no longer asserts merged + resolved + parked + reported_no_op == items_processed — a disposition added without a field would under-report silently again (temperloop#1084/#1103)"
    fail=1
  elif ! grep -Eq -- '--run-id\)' "$EMIT_SCRIPT" || ! grep -Eq -- '--open\)' "$EMIT_SCRIPT"; then
    echo "FAIL  emit-command-run.sh no longer parses --run-id / --open — the stable run id (temperloop#2220) is what makes a park-then-merge run reducible to ONE item instead of two, and the open ledger is the only trace a run that emitted nothing leaves behind"
    fail=1
  elif ! grep -Eq -- 'run_id: [$]run_id' "$EMIT_SCRIPT"; then
    echo "FAIL  emit-command-run.sh parses --run-id/--open but no longer writes run_id into the record — the flags would be accepted and silently dropped, leaving every record unreducible (temperloop#2220)"
    fail=1
  else
    echo "ok    emit-command-run.sh parses --resolved / --reported-no-op / --run-id / --open, asserts the disposition sum, and writes run_id"
  fi
fi

# --- 2. each command doc must still invoke it with its own --command value --
check_wiring() {  # $1=label $2=path $3=expected --command value
  local label="$1" file="$2" cmdval="$3"
  if [ ! -f "$file" ]; then
    echo "FAIL  $label doc missing entirely ($file)"
    fail=1
    return
  fi
  if ! grep -Fq 'emit-command-run.sh' "$file"; then
    echo "FAIL  $label ($file) no longer invokes emit-command-run.sh — the run-telemetry emit was removed from the executable path"
    fail=1
    return
  fi
  # The invocation spans a few lines (a `\`-continued bash block), so scan a
  # window of lines AFTER the emit-command-run.sh match for the --command
  # flag rather than requiring it on the same line.
  if ! grep -A4 -F 'emit-command-run.sh' "$file" | grep -E -- "--command[[:space:]]+${cmdval}\b" >/dev/null; then
    echo "FAIL  $label ($file) invokes emit-command-run.sh but not with --command ${cmdval} — wiring drifted"
    fail=1
    return
  fi
  echo "ok    $label wires emit-command-run.sh --command $cmdval"
}

# --- 3. a doc that can terminate an item on a VERDICT must pass --resolved ---
# Content-derived (see the header): the trigger is the doc declaring the
# `resolved (verdict)` disposition, not this script knowing which docs do.
check_resolved() {  # $1=label $2=path
  local label="$1" file="$2"
  [ -f "$file" ] || return 0   # missing-doc case already reported by check_wiring
  if ! grep -Fqi 'resolved (verdict)' "$file"; then
    echo "ok    $label declares no 'resolved (verdict)' disposition — --resolved not required"
    return
  fi
  # The invocation is a `\`-continued block; scan a window after the match.
  if ! grep -A8 -F 'emit-command-run.sh' "$file" | grep -E -- '--resolved[[:space:]]' >/dev/null; then
    echo "FAIL  $label ($file) declares a 'resolved (verdict)' terminal disposition but its emit-command-run.sh call omits --resolved — verdict-resolved items would be invisible and the counts would not reconcile against items_processed (temperloop#1084)"
    fail=1
    return
  fi
  echo "ok    $label declares 'resolved (verdict)' and passes --resolved"
}

# --- 4. a doc that can terminate an item on a REPORTED-NO-OP must pass it ----
# Content-derived (see the header), the same shape as check_resolved above:
# the trigger is the doc declaring the `reported-no-op` disposition, not this
# script knowing which docs do (temperloop#1103).
check_reported_no_op() {  # $1=label $2=path
  local label="$1" file="$2"
  [ -f "$file" ] || return 0   # missing-doc case already reported by check_wiring
  if ! grep -Fqi 'reported-no-op' "$file"; then
    echo "ok    $label declares no 'reported-no-op' disposition — --reported-no-op not required"
    return
  fi
  # The invocation is a `\`-continued block; scan a window after the match.
  if ! grep -A8 -F 'emit-command-run.sh' "$file" | grep -E -- '--reported-no-op[[:space:]]' >/dev/null; then
    echo "FAIL  $label ($file) declares a 'reported-no-op' terminal disposition but its emit-command-run.sh call omits --reported-no-op — reported-no-op runs would be invisible and the counts would not reconcile against items_processed (temperloop#1103)"
    fail=1
    return
  fi
  echo "ok    $label declares 'reported-no-op' and passes --reported-no-op"
}

# --- 5. a doc that declares the Step 3.6A epic-closing gate must pass -------
# --epics-reviewed. Content-derived (see the header), the same shape as
# check_resolved/check_reported_no_op above: the trigger is the doc
# declaring the gate (temperloop#1847 escalation round 2), not this script
# knowing which docs do. Matched on BOTH `epics_reviewed` and `Step 3.6A` so
# renaming either alone still leaves the check armed via the other.
check_epics_reviewed() {  # $1=label $2=path
  local label="$1" file="$2"
  [ -f "$file" ] || return 0   # missing-doc case already reported by check_wiring
  if ! grep -Fq 'epics_reviewed' "$file" || ! grep -Fq 'Step 3.6A' "$file"; then
    echo "ok    $label declares no Step 3.6A epic-closing gate — --epics-reviewed not required"
    return
  fi
  # The invocation is a `\`-continued block; scan a window after the match.
  if ! grep -A8 -F 'emit-command-run.sh' "$file" | grep -E -- '--epics-reviewed[[:space:]]' >/dev/null; then
    echo "FAIL  $label ($file) declares the Step 3.6A epic-closing gate (epics_reviewed) but its emit-command-run.sh call omits --epics-reviewed — the epics_closed + epics_left_open == epics_reviewed accounting check would never activate, and a dropped flag would read as not-applicable rather than a broken mandatory step (temperloop#1847 escalation round 2)"
    fail=1
    return
  fi
  echo "ok    $label declares the Step 3.6A epic-closing gate and passes --epics-reviewed"
}

# --- 6. every caller doc must OPEN the run ledger (temperloop#2220) ---------
# The terminal emit alone cannot make the stream reducible: a /fix run can emit
# TWICE (park at the merge gate, merge after the operator approves, same run),
# and a run that emits NOTHING leaves no trace at all. The `--open` call at the
# run's start is what mints the stable run_id and records that the run started,
# so dropping it silently re-opens BOTH failures — a double-counted item, and a
# silent run no guard can see. Same presence-lint shape as check_wiring above.
check_open_ledger() {  # $1=label $2=path $3=expected --command value
  local label="$1" file="$2" cmdval="$3"
  [ -f "$file" ] || return 0   # missing-doc case already reported by check_wiring
  # ANCHOR ON A NON-`-` BOUNDARY, never `\b`. `\b` matches between `e` and
  # `-`, so `--open --command triage-feedback` — a line triage.md legitimately
  # carries — satisfied the presence check for `triage` all by itself: drop
  # the main `/triage` open call entirely and this lint stayed green, which is
  # the exact regression it exists to catch. A trailing space-or-end-of-line
  # is what actually separates one --command value from a longer one.
  if ! grep -E -- "--open[[:space:]]+--command[[:space:]]+${cmdval}([[:space:]]|$)" "$file" >/dev/null; then
    echo "FAIL  $label ($file) no longer opens the run ledger — expected an \`emit-command-run.sh --open --command ${cmdval}\` call at the run's start. Without it a park-then-merge run's records carry no shared run_id (the item is counted twice), and a run that emits nothing leaves no marker for workflows/scripts/validate-command-run-reconcile.sh to catch (temperloop#2220)"
    fail=1
    return
  fi
  echo "ok    $label opens the run ledger (--open --command $cmdval)"
}

# --- 7. an --open call that INTERPOLATES a variable must declare its ordering
# Content-derived, the same shape as the checks above: the trigger is the open
# call passing a shell variable (`--board "$BOARD"` / `--target "$BOARD"`), not
# this script knowing which docs do.
#
# WHY A LINT AND NOT A REVIEW NOTE (temperloop#2220). Each Step-0 item is
# typically its own Bash call with no persisted shell state, and every one of
# these docs computes `$BOARD` in an EARLIER numbered item of the SAME "Run in
# parallel:" list. Under a literal reading, an open call with no ordering
# call-out can therefore run with `$BOARD` still empty — and `--target` is the
# load-bearing half of the ledger marker key. An empty one writes the marker
# under the target-LESS key; the terminal emit, by then holding a resolved
# board, computes the target-BEARING key, adopts nothing, and mints a second
# id. The orphan is never pruned (`prune_spent_markers()` leaves `emitted=0`
# alone, deliberately) and ages into a MISSING-RUN alarm that is FALSE. This
# does not merely disable the guard: it manufactures a wrong alarm, which is
# the worst failure available to a reconciliation signal — it teaches the
# reader to ignore it. The convention already exists in these same files
# ("Runs **after** item 3 (it needs `ownerRepo`)"); this makes it mechanical.
#
# Also asserts the CARVE-OUT WORDING is the same sentence in all three docs: a
# best-effort step stated three different ways invites an executor to treat
# one of them as blocking.
check_open_ordering() {  # $1=label $2=path $3=expected --command value
  local label="$1" file="$2" cmdval="$3" line
  [ -f "$file" ] || return 0   # missing-doc case already reported by check_wiring
  line="$(grep -E -- "--open[[:space:]]+--command[[:space:]]+${cmdval}([[:space:]]|$)" "$file" | head -1)"
  if [ -z "$line" ]; then
    return 0                   # absent open call already reported by check_open_ledger
  fi
  if printf '%s' "$line" | grep -E -q -- '--(board|target)[[:space:]]+"\$'; then
    if ! printf '%s' "$line" | grep -E -q 'Runs[[:space:]]+\*{0,2}after\*{0,2}[[:space:]]+item[[:space:]]+[0-9]'; then
      echo "FAIL  $label ($file) opens the run ledger with a shell variable (--board/--target \"\$…\") but the item carries no ordering call-out. Add the convention this repo already uses for a cross-item data dependency inside a 'Run in parallel:' list — \"Runs after item N — it needs \\\`\$BOARD\\\`\". Without it the open call can run before the board is inferred, keying the marker WITHOUT a target while the terminal emit keys it WITH one: the emit adopts nothing, mints a second run id, and the orphaned emitted=0 marker ages into a MISSING-RUN alarm that is FALSE (temperloop#2220)"
      fail=1
      return
    fi
  fi
  if ! grep -Fq '(the telemetry ledger open) never stops a run' "$file"; then
    echo "FAIL  $label ($file) opens the run ledger but does not carry the shared carve-out sentence '<item> (the telemetry ledger open) never stops a run' — the best-effort status of this step must read the same in every caller doc, or an executor will treat one doc's open call as a blocking Step-0 check (temperloop#2220)"
    fail=1
    return
  fi
  echo "ok    $label declares the open call's ordering dependency and the shared never-stops-a-run carve-out"
}

check_wiring "sweep.md"  "$SWEEP_MD"  "sweep"
check_wiring "triage.md" "$TRIAGE_MD" "triage"
check_wiring "fix.md"    "$FIX_MD"    "fix"

check_open_ledger "sweep.md"  "$SWEEP_MD"  "sweep"
check_open_ledger "triage.md" "$TRIAGE_MD" "triage"
check_open_ledger "fix.md"    "$FIX_MD"    "fix"

check_open_ordering "sweep.md"  "$SWEEP_MD"  "sweep"
check_open_ordering "triage.md" "$TRIAGE_MD" "triage"
check_open_ordering "fix.md"    "$FIX_MD"    "fix"

check_resolved "sweep.md"  "$SWEEP_MD"
check_resolved "triage.md" "$TRIAGE_MD"
check_resolved "fix.md"    "$FIX_MD"

check_reported_no_op "sweep.md"  "$SWEEP_MD"
check_reported_no_op "triage.md" "$TRIAGE_MD"
check_reported_no_op "fix.md"    "$FIX_MD"

# Only sweep.md declares the epic-closing gate today; the function itself
# stays content-derived (it no-ops on triage.md/fix.md too) so a future doc
# that grows this same gate is caught without editing this script.
check_epics_reviewed "sweep.md" "$SWEEP_MD"

echo "---"
if [ "$fail" -ne 0 ]; then
  echo "validate-command-run-emit: FAIL"
  exit 1
fi
echo "validate-command-run-emit: OK"
