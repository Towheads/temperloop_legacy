#!/usr/bin/env bash
#
# job-scratch.sh — SOURCED classifier for background-job scratch retention
# (temperloop#1111). Given the harness's job directory (`~/.claude/jobs/`),
# decide — per job — whether its `tmp/` scratch tree is still load-bearing or
# is regenerable residue that nothing will ever read again.
#
# WHY THIS EXISTS. `/build` isolates each worker in its own worktree and each
# Swift worker gets its own DERIVED_DATA path, so parallel `xcodebuild`
# invocations don't collide. That isolation is correct; what was missing is
# that NOTHING reclaimed the scratch once the job finished. Measured evidence
# (temperloop#1111): two job dirs held 38.5GB — 13 Xcode DerivedData trees at
# ~2.3GB each in one, eval/benchmark corpora (basic-memory homes + embedding
# indexes) in the other — while the other 55 job dirs totalled ~6MB combined.
# The root volume hit 0 bytes free, hard enough that the harness's own Bash
# tool could not allocate a command's output file, which blocks DIAGNOSING the
# problem and not merely doing work. Both classes of artifact are 100%
# regenerable: DerivedData rebuilds on the next `xcodebuild`, eval corpora
# reindex. The retained bytes buy nothing after the run ends.
#
# WHY A SWEEP, NOT A LEVEL-CLOSE PURGE. The originating issue left the
# reclamation trigger deliberately to design (level-close / job-terminal /
# age-based / size cap). A `/build` level-close purge would need a reliable
# worker→job-dir mapping the kernel does not own — the job directory is the
# HARNESS's, created and named outside any kernel code path — so a level-close
# hook would silently miss every job it failed to map, which is the exact
# failure shape (a leak nobody notices) this is meant to close. A sweep keyed
# on the job's OWN terminal state needs no such mapping, reclaims the backlog
# that already exists, and degrades to a no-op rather than to a silent miss.
#
# ── Classification ──────────────────────────────────────────────────────────
# Per job directory <root>/<id>/ (which the harness populates with state.json,
# timeline.jsonl and tmp/), the verdict is one of:
#
#   JOB_SCRATCH_RECLAIMABLE:<id>:<MB>MB:<state>
#       The job reached a TERMINAL state (JOB_SCRATCH_TERMINAL_STATES), its
#       last activity is older than the grace window, and its tmp/ exceeds the
#       size floor. Safe to delete: nothing will read it again. This is the
#       ONLY class job-scratch-reclaim.sh --apply ever removes.
#
#   JOB_SCRATCH_ABANDONED:<id>:<MB>MB:<state>
#       Big scratch under a job that is NOT terminal (or whose state cannot be
#       read at all) and has shown no activity for the abandoned horizon. This
#       is REPORT-ONLY and is never auto-deleted — a non-terminal job may still
#       resume (`blocked` is the live case: it awaits an operator answer and
#       then continues), and deleting a live run's scratch mid-flight is a far
#       worse failure than leaving bytes on disk. A human disposes it.
#
#   (empty)
#       Nothing to say: no tmp/ at all, tmp/ under the size floor, or a
#       terminal job still inside its grace window.
#
# FAIL-OPEN, FAIL-SAFE. An unreadable/absent/unparseable state.json yields an
# EMPTY state, which can never be terminal — so an unclassifiable job is at
# worst reported, never reclaimed. Uncertainty always resolves toward keeping
# the bytes.
#
# ── Sourced surface ─────────────────────────────────────────────────────────
#   job_scratch_root                    resolved jobs directory
#   job_scratch_state <job_dir>         the job's `state` string ("" if unknown)
#   job_scratch_is_terminal <state>     exit 0 iff <state> is in the terminal set
#   job_scratch_size_kb <path>          du -sk of <path> (0 when unreadable)
#   job_scratch_mtime <path>            portable mtime-as-epoch (0 when absent)
#   job_scratch_classify <job_dir>      the verdict token above (or empty)
#   job_scratch_list [root]             one `<verdict> <job_dir>` line per
#                                       non-empty verdict, over every job under
#                                       <root> (default job_scratch_root)
#
# Every function is READ-ONLY. Deletion lives in the sibling CLI
# (job-scratch-reclaim.sh --apply), deliberately kept out of this lib so the
# reconciler (env-reconcile.sh) can source the classification without ever
# gaining the ability to mutate — the same read-only contract that file's own
# header already promises.
#
# Env overrides (registered in workflows/scripts/config/setting-registry.tsv):
#   JOB_SCRATCH_ROOT              jobs directory to sweep
#   JOB_SCRATCH_MIN_MB            size floor, in MB, below which scratch is ignored
#   JOB_SCRATCH_GRACE_DAYS        days a TERMINAL job's scratch is kept before reclaim
#   JOB_SCRATCH_ABANDONED_DAYS    days of no activity before non-terminal scratch is reported
#   JOB_SCRATCH_TERMINAL_STATES   space-separated `state` values treated as terminal
#
# Kept bash-3.2 friendly (no associative arrays, no mapfile) so it runs on the
# macOS dev shell as well as Linux CI.

JOB_SCRATCH_ROOT="${JOB_SCRATCH_ROOT:-$HOME/.claude/jobs}"
JOB_SCRATCH_MIN_MB="${JOB_SCRATCH_MIN_MB:-100}"
JOB_SCRATCH_GRACE_DAYS="${JOB_SCRATCH_GRACE_DAYS:-1}"
JOB_SCRATCH_ABANDONED_DAYS="${JOB_SCRATCH_ABANDONED_DAYS:-14}"
# `blocked` is deliberately ABSENT: a blocked job is waiting on an operator
# answer and resumes afterwards, so its scratch is live, not residue.
JOB_SCRATCH_TERMINAL_STATES="${JOB_SCRATCH_TERMINAL_STATES:-done failed cancelled canceled error killed}"

job_scratch_root() { printf '%s\n' "$JOB_SCRATCH_ROOT"; }

# ── job_scratch_mtime <path> ─────────────────────────────────────────────────
# Portable mtime-as-epoch, GNU-first then BSD. Mirrors env-reconcile.sh's
# file_mtime: each branch emits ONLY on success, because GNU `stat -f %m`
# mis-parses as a filesystem-mode query and leaks a multi-line blob to stdout
# while exiting non-zero, which a bare `A || B` would concatenate into the
# result and break the arithmetic that consumes it under `set -u`.
job_scratch_mtime() {
  local m
  if m="$(stat -c %Y "$1" 2>/dev/null)" && [ -n "$m" ]; then printf '%s\n' "$m"; return 0; fi
  if m="$(stat -f %m "$1" 2>/dev/null)" && [ -n "$m" ]; then printf '%s\n' "$m"; return 0; fi
  printf '0\n'
}

# ── job_scratch_size_kb <path> ───────────────────────────────────────────────
# `du -sk` is the one size probe both BSD (macOS) and GNU coreutils spell the
# same way. Unreadable / absent → 0, never an empty string (callers do integer
# arithmetic on this under `set -u`).
job_scratch_size_kb() {
  local kb
  kb="$(du -sk "$1" 2>/dev/null | awk 'NR==1 {print $1}')"
  case "$kb" in
    ''|*[!0-9]*) printf '0\n' ;;
    *) printf '%s\n' "$kb" ;;
  esac
}

# ── job_scratch_state <job_dir> ──────────────────────────────────────────────
# The job's top-level `state` string, or EMPTY when it cannot be determined.
# jq is authoritative when present (it cannot be fooled by a nested `"state"`
# key inside the `children[]` array these files carry); the sed fallback keeps
# the sweep working on a host with no jq rather than silently classifying
# every job as unknown — a silent no-op is the failure mode this whole item
# exists to prevent, so it must not be reintroduced by a missing dependency.
job_scratch_state() {
  local f="$1/state.json" s=""
  [ -f "$f" ] || { printf ''; return 0; }
  if command -v jq >/dev/null 2>&1; then
    s="$(jq -r 'if type == "object" then (.state // "") else "" end' "$f" 2>/dev/null)" || s=""
    [ "$s" = "null" ] && s=""
  fi
  if [ -z "$s" ]; then
    s="$(sed -n 's/.*"state"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$f" 2>/dev/null | awk 'NR==1 {print}')"
  fi
  printf '%s' "$s"
}

# ── job_scratch_is_terminal <state> ──────────────────────────────────────────
job_scratch_is_terminal() {
  local s="${1:-}" t
  [ -n "$s" ] || return 1
  for t in $JOB_SCRATCH_TERMINAL_STATES; do
    [ "$s" = "$t" ] && return 0
  done
  return 1
}

# ── job_scratch_classify <job_dir> ───────────────────────────────────────────
# Prints one verdict token (see the header) or nothing. Never mutates.
job_scratch_classify() {
  local dir="$1" id tmp state mt age size_kb size_mb floor_kb grace_s abandoned_s
  id="$(basename "$dir")"
  tmp="$dir/tmp"

  # A symlinked tmp/ is never classified: the reclaimer would otherwise be
  # pointed at an arbitrary target outside the jobs root.
  [ -d "$tmp" ] || { printf ''; return 0; }
  [ -L "$tmp" ] && { printf ''; return 0; }

  size_kb="$(job_scratch_size_kb "$tmp")"
  floor_kb=$(( JOB_SCRATCH_MIN_MB * 1024 ))
  [ "$size_kb" -ge "$floor_kb" ] || { printf ''; return 0; }
  size_mb=$(( size_kb / 1024 ))

  state="$(job_scratch_state "$dir")"

  # Last activity: state.json's mtime while it exists (a terminal job stops
  # rewriting it), else the job directory's own.
  if [ -f "$dir/state.json" ]; then
    mt="$(job_scratch_mtime "$dir/state.json")"
  else
    mt="$(job_scratch_mtime "$dir")"
  fi
  age=$(( $(date +%s) - mt ))

  grace_s=$(( JOB_SCRATCH_GRACE_DAYS * 86400 ))
  abandoned_s=$(( JOB_SCRATCH_ABANDONED_DAYS * 86400 ))

  if job_scratch_is_terminal "$state"; then
    if [ "$age" -ge "$grace_s" ]; then
      printf 'JOB_SCRATCH_RECLAIMABLE:%s:%sMB:%s' "$id" "$size_mb" "$state"
    fi
    return 0
  fi

  if [ "$age" -ge "$abandoned_s" ]; then
    printf 'JOB_SCRATCH_ABANDONED:%s:%sMB:%s' "$id" "$size_mb" "${state:-unknown}"
  fi
  return 0
}

# ── job_scratch_list [root] ──────────────────────────────────────────────────
# One `<verdict> <job_dir>` line per job with a non-empty verdict. An absent
# root prints nothing and exits 0 (fail-open: a host that never ran a
# background job is not drift).
job_scratch_list() {
  local root="${1:-$JOB_SCRATCH_ROOT}" d cls
  [ -n "$root" ] && [ -d "$root" ] || return 0
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    cls="$(job_scratch_classify "$d")"
    [ -n "$cls" ] && printf '%s %s\n' "$cls" "$d"
  done < <(find "$root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
  return 0
}
