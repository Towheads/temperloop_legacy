#!/usr/bin/env bash
#
# check-workflow-script-size.sh — fail the build BEFORE a workflow script grows
# past the size at which the harness refuses to load it (temperloop#2126).
#
# ── WHY THIS EXISTS ─────────────────────────────────────────────────────
# The harness Workflow tool rejects a `scriptPath` whose file exceeds a hard
# byte limit. That limit is the HARNESS's, not this repo's, so nothing in
# `checks` measured against it: claude/workflows/build-level.mjs reached 98.4%
# of it in PR #2114 with no signal at all, went over in PR #2125, and every
# command that drives work through the engine — /fix, /sweep, /build — stopped
# loading. The failure is invisible to CI by construction (both PRs were green)
# and it is NOT self-repairing: the fix would have to be driven by the engine
# that no longer loads, so it costs a hand repair outside the pipeline.
#
# This is the § Mandatory-step birth rule's "static guard" shape: the constraint
# that decides whether the orchestrator runs at all is now measured, and goes
# red while there is still room to land a fix rather than after the engine is
# already unloadable.
#
# ── WHAT IT CHECKS ──────────────────────────────────────────────────────
# Every `claude/workflows/*.mjs` against WORKFLOW_SCRIPT_BUDGET_PCT of
# WORKFLOW_SCRIPT_BYTE_CEILING. Both are declared in build.config.sh and named
# symbolically here — this script restates neither default (§ Named-setting
# convention). Over budget is a hard FAIL naming current bytes, the budget, the
# ceiling and the margin, because a number without its margin does not tell a
# reader how much room is left.
#
# Usage:
#   check-workflow-script-size.sh [--dir <dir>]
#
# Exit: 0 all files within budget · 1 at least one over
set -euo pipefail

DIR="claude/workflows"
while [ $# -gt 0 ]; do
  case "$1" in
    --dir) DIR="${2:?--dir needs a value}"; shift 2 ;;
    -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
    *) printf 'check-workflow-script-size.sh: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
# shellcheck source=/dev/null
[ -f "$root/workflows/scripts/build/build.config.sh" ] \
  && . "$root/workflows/scripts/build/build.config.sh" >/dev/null 2>&1 || true
ceiling="${WORKFLOW_SCRIPT_BYTE_CEILING:-524288}"
pct="${WORKFLOW_SCRIPT_BUDGET_PCT:-90}"
budget=$(( ceiling * pct / 100 ))

shopt -s nullglob
files=("$root/$DIR"/*.mjs)
if [ "${#files[@]}" -eq 0 ]; then
  printf 'SKIP: no workflow scripts under %s — nothing to measure\n' "$DIR"
  exit 0
fi

rc=0
for f in "${files[@]}"; do
  rel="${f#"$root"/}"
  # An unreadable file must FAIL, never measure as zero bytes: `wc -c` on a file
  # it cannot open reports nothing, and treating that as 0 would be a degenerate
  # PASS — the exact shape workflows/scripts/config/check-surface-registry.tsv
  # exists to forbid.
  if ! bytes=$(wc -c < "$f" 2>/dev/null | tr -d '[:space:]') || [ -z "$bytes" ]; then
    printf 'FAIL: %s could not be read — refusing to treat an unreadable workflow script as 0 bytes\n' "$rel" >&2
    rc=1; continue
  fi
  if [ "$bytes" -gt "$budget" ]; then
    printf 'FAIL: %s is %s bytes — over the %s%% budget (%s) of the harness ceiling (%s).\n' \
      "$rel" "$bytes" "$pct" "$budget" "$ceiling" >&2
    printf '      The Workflow tool refuses a scriptPath above %s bytes, and /fix, /sweep and /build\n' "$ceiling" >&2
    printf '      all invoke this file that way. Shed at least %s bytes (temperloop#2126).\n' \
      "$(( bytes - budget ))" >&2
    rc=1
  else
    printf 'PASS: %s is %s bytes — %s%% of the %s-byte ceiling, %s bytes of headroom to the %s%% budget\n' \
      "$rel" "$bytes" "$(( bytes * 100 / ceiling ))" "$ceiling" "$(( budget - bytes ))" "$pct"
  fi
done
exit "$rc"
