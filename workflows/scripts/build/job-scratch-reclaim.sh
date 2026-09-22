#!/usr/bin/env bash
#
# job-scratch-reclaim.sh — reclaim regenerable background-job scratch
# (temperloop#1111). The mutating half of the job-scratch retention policy;
# the classification it acts on lives in lib/job-scratch.sh (sourced, read-only)
# and is shared verbatim with env-reconcile.sh's JOB_SCRATCH_* drift classes,
# so the detector and the reclaimer can never disagree about what is safe to
# delete.
#
# DRY-RUN BY DEFAULT — it prints what it would delete and changes nothing.
# Pass --apply to actually delete.
#
# WHAT IT DELETES: the `tmp/` tree of a job whose classification is
# JOB_SCRATCH_RECLAIMABLE — a job that reached a terminal state, whose grace
# window has elapsed, and whose scratch exceeds the size floor. The run RECORD
# (state.json, timeline.jsonl — ~140KB) is always kept: the point is to bound
# the regenerable trees, not to erase the history of the run.
#
# WHAT IT NEVER DELETES:
#   - a JOB_SCRATCH_ABANDONED job's scratch (non-terminal, or unreadable
#     state) — a non-terminal job can still resume (`blocked` awaits an
#     operator answer and then continues), so that class is report-only and a
#     human disposes it;
#   - anything outside `<root>/<id>/tmp` — every candidate is re-verified
#     against the resolved root immediately before removal (see prune_one);
#   - a symlinked `tmp/` — never followed, so the reclaimer cannot be aimed at
#     an arbitrary path by a planted link.
#
# Usage:
#   job-scratch-reclaim.sh                 # dry-run: report what would be reclaimed
#   job-scratch-reclaim.sh --apply         # delete reclaimable job scratch
#   job-scratch-reclaim.sh --root <dir>    # sweep a different jobs directory
#
# Exit status is 0 whenever the sweep ran (including "nothing to do") — this is
# a hygiene helper invoked from /tidy's § Environment hygiene auto-heal, and a
# non-zero exit there would read as a drain failure rather than a clean host.
# Only a usage error exits non-zero.
#
# Env overrides: see lib/job-scratch.sh's header (JOB_SCRATCH_ROOT,
# JOB_SCRATCH_MIN_MB, JOB_SCRATCH_GRACE_DAYS, JOB_SCRATCH_ABANDONED_DAYS,
# JOB_SCRATCH_TERMINAL_STATES) — all registered in
# workflows/scripts/config/setting-registry.tsv.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/job-scratch.sh
source "$SCRIPT_DIR/lib/job-scratch.sh"

usage() {
  sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

APPLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --root) JOB_SCRATCH_ROOT="${2:?--root needs a directory}"; shift 2 ;;
    --root=*) JOB_SCRATCH_ROOT="${1#--root=}"; shift ;;
    -h|--help) usage 0 ;;
    *) echo "job-scratch-reclaim: unknown arg '$1'" >&2; usage 2 ;;
  esac
done

ROOT="$JOB_SCRATCH_ROOT"

# ── prune_one <job_dir> ──────────────────────────────────────────────────────
# Removes <job_dir>/tmp after re-verifying, from scratch, that the target is
# exactly a `tmp` directory one level under the resolved root. The classifier
# already agreed; this is the independent second check that keeps a bad root
# (`--root /`), a crafted id, or a future classifier bug from turning into an
# unbounded delete. Returns 1 without touching anything if any guard fails.
prune_one() {
  local dir="$1" tmp="$1/tmp" parent
  [ -d "$tmp" ] || return 1
  [ -L "$tmp" ] && return 1
  [ "$(basename "$tmp")" = "tmp" ] || return 1
  parent="$(cd "$dir/.." 2>/dev/null && pwd -P)" || return 1
  [ -n "$ROOT_ABS" ] || return 1
  [ "$parent" = "$ROOT_ABS" ] || return 1
  rm -rf -- "$tmp"
}

ROOT_ABS=""
if [ -n "$ROOT" ] && [ -d "$ROOT" ]; then
  ROOT_ABS="$(cd "$ROOT" 2>/dev/null && pwd -P)" || ROOT_ABS=""
fi

if [ -z "$ROOT_ABS" ]; then
  echo "=== job scratch reclaim ==="
  echo "  root not present: $ROOT"
  echo "---"
  echo "OK (nothing to sweep)"
  exit 0
fi

# The resolved root must not be a filesystem root or the caller's HOME: those
# can only come from a misconfigured JOB_SCRATCH_ROOT/--root, and the blast
# radius of proceeding is the whole machine.
case "$ROOT_ABS" in
  /|"$HOME") echo "job-scratch-reclaim: refusing to sweep root '$ROOT_ABS'" >&2; exit 2 ;;
esac

reclaimable=0
abandoned=0
reclaimable_kb=0
abandoned_kb=0
reclaimed=0
reclaimed_kb=0
failed=0
LINES=""

while IFS= read -r line; do
  [ -n "$line" ] || continue
  cls="${line%% *}"
  dir="${line#* }"
  kb="$(job_scratch_size_kb "$dir/tmp")"
  case "$cls" in
    JOB_SCRATCH_RECLAIMABLE:*)
      reclaimable=$((reclaimable + 1))
      reclaimable_kb=$((reclaimable_kb + kb))
      if [ "$APPLY" -eq 1 ]; then
        if prune_one "$dir"; then
          reclaimed=$((reclaimed + 1))
          reclaimed_kb=$((reclaimed_kb + kb))
          LINES="${LINES}  RECLAIMED    ${dir}/tmp  [${cls}]"$'\n'
        else
          failed=$((failed + 1))
          LINES="${LINES}  SKIPPED      ${dir}/tmp  [${cls}] (guard refused)"$'\n'
        fi
      else
        LINES="${LINES}  WOULD-RECLAIM ${dir}/tmp  [${cls}]"$'\n'
      fi
      ;;
    JOB_SCRATCH_ABANDONED:*)
      abandoned=$((abandoned + 1))
      abandoned_kb=$((abandoned_kb + kb))
      LINES="${LINES}  REPORT-ONLY  ${dir}/tmp  [${cls}]"$'\n'
      ;;
  esac
done < <(job_scratch_list "$ROOT_ABS")

echo "=== job scratch reclaim ==="
echo "  root: $ROOT_ABS"
printf '%s' "$LINES"
echo "---"
if [ "$APPLY" -eq 1 ]; then
  printf 'RECLAIMED: %d job(s), %d MB freed; report-only (abandoned): %d job(s), %d MB\n' \
    "$reclaimed" "$((reclaimed_kb / 1024))" "$abandoned" "$((abandoned_kb / 1024))"
  [ "$failed" -gt 0 ] && printf 'GUARD-REFUSED: %d\n' "$failed"
else
  printf 'DRY-RUN: %d job(s) reclaimable, %d MB; report-only (abandoned): %d job(s), %d MB\n' \
    "$reclaimable" "$((reclaimable_kb / 1024))" "$abandoned" "$((abandoned_kb / 1024))"
fi
exit 0
