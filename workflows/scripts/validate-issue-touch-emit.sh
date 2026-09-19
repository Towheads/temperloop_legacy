#!/usr/bin/env bash
#
# validate-issue-touch-emit.sh — presence-lint for the build.md issue-touch
# emit (foundation #916/#919, epic #916 "issue-touch-stream").
#
# build.md's Step 3f (PR opened) and Step 4d (PR confirmed MERGED) are the
# only places a `pr-open` / `merge` touch happens for a plan item.
# emit-issue-touch.sh is the concrete emit — but a prose orchestrator step in
# a skill doc can silently rot (the June silent-failure class: an
# LLM-executed markdown step gets skipped or paraphrased away and nobody
# notices, because the failure mode is an ABSENT record, not an error). This
# script is the mechanical owner that makes that rot loud: it FAILS CI (exit
# 1) if either half of the wiring goes missing —
#
#   1. the script itself (workflows/scripts/emit-issue-touch.sh) is absent or
#      not executable, or
#   2. its invocation is removed from claude/commands/build.md — i.e. the
#      3f step no longer calls emit-issue-touch.sh with `--kind pr-open`, or
#      the 4d step no longer calls it with `--kind merge`, or
#   3. (temperloop#2131) its invocation is removed from
#      claude/workflows/build-level.mjs — i.e. the 3h round-telemetry emit no
#      longer calls it with `--kind review-round`.
#
# TWO TARGETS, not one (temperloop#2131). Before that item this script read
# build.md ALONE, so the §3e round-telemetry emit — which lives in the Workflow
# DRIVER, not in the prose spec — was neither covered nor coverable here: the
# lint could go green with the emit deleted. build.md's two call sites still
# live in the SAME file (unlike validate-command-run-emit.sh's two-file
# sweep.md/triage.md case), so those two are checked as two --kind values within
# one file; build-level.mjs is a THIRD check against a SECOND file. This mirrors
# the validate-capture-backstop.sh / validate-command-run-emit.sh shape (same
# script style, same hard-fail-on-half-present contract, wired into
# scripts/quality-gates.sh the same way).
#
# WHY THE .mjs IS SCANNED COMMENT-STRIPPED. That file documents its own wiring
# in prose right beside it, and a window-based presence grep would happily match
# the COMMENT that names the flag — the temperloop#1152 defect class, a guard
# that fires on documentation of the thing it guards, which here would let the
# real emit be deleted while this lint stayed green. `//` lines are removed
# before the scan so only executable text can satisfy it.
#
# Usage: workflows/scripts/validate-issue-touch-emit.sh   (resolves the repo itself)

set -euo pipefail

SCRIPTS_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -P "$SCRIPTS_DIR/../.." && pwd)"
EMIT_SCRIPT="$SCRIPTS_DIR/emit-issue-touch.sh"
BUILD_MD="$REPO/claude/commands/build.md"
BUILD_LEVEL_MJS="$REPO/claude/workflows/build-level.mjs"

TMP_CODE=""
cleanup() { [ -n "$TMP_CODE" ] && rm -f "$TMP_CODE"; return 0; }
trap cleanup EXIT

fail=0

# --- 1. the emit script itself must exist and be executable -----------------
if [ ! -f "$EMIT_SCRIPT" ]; then
  echo "FAIL  emit-issue-touch.sh is missing (expected at $EMIT_SCRIPT)"
  fail=1
elif [ ! -x "$EMIT_SCRIPT" ]; then
  echo "FAIL  emit-issue-touch.sh exists but is not executable ($EMIT_SCRIPT)"
  fail=1
else
  echo "ok    emit-issue-touch.sh present and executable"
fi

# check_kind_wiring — DEFINED AT TOP LEVEL (temperloop#2131), not nested inside
# section 2's `else` as it was before this item: section 3 below calls it for a
# SECOND target, and a definition reachable only when build.md happens to be
# present would make the .mjs check silently disappear whenever build.md is the
# thing that broke — a lint whose coverage depends on another check passing.
#
# $1=step label (for the message) $2=expected --kind value
# $3=file to scan  $4=path to NAME in the message (may differ from $3 when a
# comment-stripped temp copy is scanned — temperloop#2131)
check_kind_wiring() {
  local label="$1" kindval="$2" file="${3:-$BUILD_MD}" named="${4:-${3:-$BUILD_MD}}"
  # Materialize the -A4 context block via command substitution FIRST, then
  # scan the captured text — never pipe it live into a second grep. A live
  # `grep -A4 ... | grep -Eq ...` pipeline is a false-failure trap under
  # `set -o pipefail` (foundation #287): `grep -Eq` exits the instant it
  # finds a match, closing its read end while the upstream `grep -A4` may
  # still have buffered context lines queued to write; the upstream then
  # dies with "grep: write error: Broken pipe" (EPIPE) and a nonzero exit,
  # which — even though the match WAS found — makes the pipeline's
  # pipefail-computed status nonzero and reads as "pattern absent". This is
  # timing-dependent (depends on pipe-buffer/scheduling), so it flakes
  # rather than failing deterministically. Command substitution has no such
  # race: `grep -A4` runs to completion and its full output is captured
  # before the second grep ever looks at it, so there is no live pipe to
  # close early. `|| true` on the capture keeps `set -e` from tripping when
  # the emit-issue-touch.sh line simply has no match at all (a genuine
  # absence, not an EPIPE) — the subsequent `grep -Eq` on the captured text
  # (possibly empty) still correctly reports FAIL for that case.
  local block
  block="$(grep -A4 -F 'emit-issue-touch.sh' "$file" || true)"
  if ! grep -Eq -- "--kind[[:space:]]+${kindval}\b" <<<"$block"; then
    echo "FAIL  $named invokes emit-issue-touch.sh but never with --kind ${kindval} (expected at $label) — wiring drifted"
    fail=1
    return
  fi
  echo "ok    $named wires emit-issue-touch.sh --kind $kindval ($label)"
}

# --- 2. build.md must still invoke it with BOTH --kind values ---------------
if [ ! -f "$BUILD_MD" ]; then
  echo "FAIL  build.md doc missing entirely ($BUILD_MD)"
  fail=1
elif ! grep -Fq 'emit-issue-touch.sh' "$BUILD_MD"; then
  echo "FAIL  build.md ($BUILD_MD) no longer invokes emit-issue-touch.sh anywhere — the issue-touch emit was removed from the executable path"
  fail=1
else
  check_kind_wiring "3f, PR open" "pr-open" "$BUILD_MD" "build.md"
  check_kind_wiring "4d, confirmed merge" "merge" "$BUILD_MD" "build.md"
fi

# --- 3. build-level.mjs must still invoke it with --kind review-round --------
# temperloop#2131. The §3e round-telemetry emit lives in the Workflow driver,
# not in build.md, so it needs its own target here — see the TWO TARGETS note in
# the header for why a build.md-only lint could not cover it.
if [ ! -f "$BUILD_LEVEL_MJS" ]; then
  echo "FAIL  build-level.mjs driver missing entirely ($BUILD_LEVEL_MJS)"
  fail=1
else
  TMP_CODE="$(mktemp -t issue-touch-emit-code.XXXXXX)"
  grep -v '^[[:space:]]*//' "$BUILD_LEVEL_MJS" > "$TMP_CODE" || true
  if ! grep -F 'emit-issue-touch.sh' "$TMP_CODE" >/dev/null; then
    echo "FAIL  build-level.mjs ($BUILD_LEVEL_MJS) no longer invokes emit-issue-touch.sh in executable text — the §3e round-telemetry emit was removed from the driver (temperloop#2131)"
    fail=1
  else
    check_kind_wiring "3h, §3e round telemetry" "review-round" "$TMP_CODE" "build-level.mjs"
  fi
fi

echo "---"
if [ "$fail" -ne 0 ]; then
  echo "validate-issue-touch-emit: FAIL"
  exit 1
fi
echo "validate-issue-touch-emit: OK"
