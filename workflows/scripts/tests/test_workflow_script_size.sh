#!/usr/bin/env bash
#
# test_workflow_script_size.sh — the DISCRIMINATION fixture for
# check-workflow-script-size.sh (temperloop#2126).
#
# A guard that only ever passes is indistinguishable from no guard at all, and
# that is precisely the failure this whole item exists to close: nothing
# measured build-level.mjs against the harness ceiling, so it crossed silently
# in one PR and disabled /fix, /sweep and /build in the next. A fixture that
# asserts only the green arm would reproduce the same shape one level up.
# So both directions are pinned here: OVER budget must FAIL, UNDER must PASS.
set -euo pipefail

GUARD="$(git rev-parse --show-toplevel)/workflows/scripts/check-workflow-script-size.sh"
[ -x "$GUARD" ] || { echo "FAIL: guard not executable at $GUARD" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/wfsize-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT INT TERM
mkdir -p "$TMP/wf"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; fails=$((fails+1)); }

# Pin the thresholds for the fixture so it never depends on the live defaults.
export WORKFLOW_SCRIPT_BYTE_CEILING=1000 WORKFLOW_SCRIPT_BUDGET_PCT=90   # budget = 900

# --- 1. UNDER budget -> exit 0 and report headroom ------------------------
head -c 500 /dev/zero | tr '\0' 'x' > "$TMP/wf/small.mjs"
if out="$(bash "$GUARD" --dir "$(basename "$TMP")/wf" 2>&1)"; then :; else out="$out"; fi
out="$(cd "$TMP" && WORKFLOW_SCRIPT_BYTE_CEILING=1000 WORKFLOW_SCRIPT_BUDGET_PCT=90 bash "$GUARD" --dir wf 2>&1)" && rc=0 || rc=$?
[ "${rc:-0}" -eq 0 ] && pass "under budget exits 0" || fail "under budget must exit 0, got $rc: $out"
case "$out" in *headroom*) pass "under budget reports headroom in bytes" ;; *) fail "under budget must report headroom: $out" ;; esac

# --- 2. OVER budget -> exit 1, naming bytes, budget, ceiling and margin ----
head -c 950 /dev/zero | tr '\0' 'x' > "$TMP/wf/small.mjs"
out="$(cd "$TMP" && WORKFLOW_SCRIPT_BYTE_CEILING=1000 WORKFLOW_SCRIPT_BUDGET_PCT=90 bash "$GUARD" --dir wf 2>&1)" && rc=0 || rc=$?
[ "$rc" -eq 1 ] && pass "over budget exits 1" || fail "over budget must exit 1, got $rc: $out"
case "$out" in *FAIL:*) pass "over budget emits FAIL" ;; *) fail "over budget must emit FAIL: $out" ;; esac
case "$out" in *900*) pass "over budget names the budget" ;; *) fail "over budget must name the budget: $out" ;; esac
case "$out" in *1000*) pass "over budget names the ceiling" ;; *) fail "over budget must name the ceiling: $out" ;; esac
case "$out" in *" 50 bytes"*|*"50 bytes"*) pass "over budget names the margin to shed" ;; *) fail "over budget must name how many bytes to shed: $out" ;; esac

# --- 3. no workflow scripts -> SKIP, never a silent pass -------------------
rm -f "$TMP/wf"/*.mjs
out="$(cd "$TMP" && bash "$GUARD" --dir wf 2>&1)" && rc=0 || rc=$?
[ "$rc" -eq 0 ] && case "$out" in *SKIP*) pass "an absent workflows dir SKIPs explicitly rather than passing silently" ;;
  *) fail "an empty dir must say SKIP: $out" ;; esac || fail "empty dir must exit 0, got $rc"

# --- 3b. an EMPTY .mjs is measured (0 bytes is under any budget), not skipped
: > "$TMP/wf/empty.mjs"
out="$(cd "$TMP" && WORKFLOW_SCRIPT_BYTE_CEILING=1000 WORKFLOW_SCRIPT_BUDGET_PCT=90 bash "$GUARD" --dir wf 2>&1)" && rc=0 || rc=$?
[ "$rc" -eq 0 ] && case "$out" in *empty.mjs*) pass "an empty .mjs is measured, not skipped" ;;
  *) fail "an empty .mjs must be measured and named: $out" ;; esac || fail "empty .mjs must exit 0, got $rc: $out"

# --- 3c. an UNREADABLE .mjs must FAIL, never measure as zero bytes ---------
# `wc -c` on a file it cannot open reports nothing; treating that as 0 would be
# the degenerate pass this whole registry exists to forbid.
if [ "$(id -u)" -eq 0 ]; then
  printf 'SKIP: running as root — an unreadable file is not constructible, so the guard cannot be probed here\n'
else
  chmod 000 "$TMP/wf/empty.mjs"
  out="$(cd "$TMP" && WORKFLOW_SCRIPT_BYTE_CEILING=1000 WORKFLOW_SCRIPT_BUDGET_PCT=90 bash "$GUARD" --dir wf 2>&1)" && rc=0 || rc=$?
  chmod 644 "$TMP/wf/empty.mjs"
  [ "$rc" -ne 0 ] && pass "an unreadable .mjs FAILS rather than measuring as zero bytes" \
    || fail "an unreadable .mjs must not pass as 0 bytes (got exit $rc): $out"
fi
rm -f "$TMP/wf/empty.mjs"

# --- 4. the REAL engine is within budget at the REAL thresholds ------------
unset WORKFLOW_SCRIPT_BYTE_CEILING WORKFLOW_SCRIPT_BUDGET_PCT
out="$(bash "$GUARD" 2>&1)" && rc=0 || rc=$?
[ "$rc" -eq 0 ] && pass "the shipped claude/workflows/*.mjs are within budget" \
  || fail "the shipped workflow scripts are OVER budget: $out"

# --- 5. the engine still carries its MACHINE-PARSED sentinel -------------
# Suggested by the #2083 session while reviewing this change, and it is the
# better half of the fix. Extracting comment volume is how this file is kept
# under the ceiling, and five of the blocks moved on the first pass turned out
# to be contracts rather than prose. The worst was the HANDOFF-CAPABILITIES
# sentinel: handoff-capability.sh answers CAPABILITIES_INDETERMINATE when it
# cannot find the declaration, and INDETERMINATE "reads identically to a pass
# at every call site" -- every /fix, /sweep and /build Step 0 probe silently
# reported every hand-off key unverified, with nothing going red.
#
# Restoring the block fixed that instance. THIS makes the next instance fail
# LOUDLY instead: the sentinel's absence from the shipped engine is now a red
# gate, not a degraded probe. Deliberately asserted HERE rather than by
# changing handoff-capability.sh's contract -- INDETERMINATE is the right
# answer for a foreign or older engine, and this repo's own engine is the one
# thing that must never produce it.
ENGINE="$(git rev-parse --show-toplevel)/claude/workflows/build-level.mjs"
if [ -f "$ENGINE" ]; then
  for marker in 'HANDOFF-CAPABILITIES-BEGIN' 'HANDOFF-CAPABILITIES-END'; do
    grep -qF -- "$marker" "$ENGINE" \
      && pass "the engine carries its $marker sentinel inline" \
      || fail "$marker is GONE from build-level.mjs — handoff-capability.sh will answer CAPABILITIES_INDETERMINATE, which every Step 0 call site reads as a pass. Restore the block inline; never relocate a machine-parsed comment."
  done
  probe="$(bash "$(git rev-parse --show-toplevel)/workflows/scripts/build/handoff-capability.sh" check "$ENGINE" "repoRoot,items" 2>/dev/null || true)"
  case "$probe" in
    *'"outcome":"CAPABILITIES_OK"'*) pass "handoff-capability.sh reads the engine as CAPABILITIES_OK" ;;
    *'INDETERMINATE'*) fail "handoff-capability.sh cannot read the engine's declaration (CAPABILITIES_INDETERMINATE) — a silent degradation at every Step 0 call site: $probe" ;;
    *) fail "handoff-capability.sh returned an unexpected outcome for the engine: $probe" ;;
  esac
fi

[ "$fails" -eq 0 ] || { printf '\n%d check(s) failed\n' "$fails" >&2; exit 1; }
printf '\nOK — all workflow-script-size checks passed\n'
