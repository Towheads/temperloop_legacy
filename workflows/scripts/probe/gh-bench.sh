#!/usr/bin/env bash
#
# gh-bench.sh — the SYNTHETIC anchor for the F#988 gh-performance measurement
# (the git-bug tracker evaluation). Times the board adapter's read-heavy paths
# over a fixed set of sections, snapshots the REST `core` rate-limit budget
# around the run — the budget the tracker path actually spends — and freezes
# per-op-class summary records to the gh-perf lake (via emit-gh-perf.sh) so
# `gh-perf-report.sh --compare before after` has an apples-to-apples anchor
# alongside the passive gh-call-logger v2 live window.
#
# WHY a synthetic anchor AND a live window: the live window (the v2 TSV) is
# zero-effort but its op mix drifts with whatever the operator did that week.
# This bench runs the SAME sections every time, so a before/after delta is
# attributable to the tracker change, not to a change in what was measured.
#
# Every registered board (issues-only backend, temperloop#524 — the
# Projects-v2/GraphQL arm's removal) is SAFE to run repeatedly: it spends only
# REST's separate 5,000-pt/hr `core` bucket, never the shared Projects-v2
# GraphQL budget the arm used to draw on — no board has a Projects-v2 page
# left to spend GraphQL points against. The `graphql_remaining` figure is
# still snapshotted and reported alongside `core_remaining` (a stray `gh api
# graphql` call from outside the tracker path still draws on that separate
# budget and is worth being able to see) — but core(REST) is the load-bearing,
# reported figure this bench exists to catch drain on; the run-total record
# captures both.
#
# Usage:
#   gh-bench.sh --board N --phase before|after --label <str>
#               [--reps N] [--cold|--warm|--both] [--with-mutations]
#               [--backend github|git-bug] [--dry-run]
#
#   --reps N           invocations per section (default 3); p50/p95/max over them
#   --cold|--warm|--both  board_resolve cache state to exercise (default both).
#                      `resolve_cold` FORCES a live read every rep (cache_dirty
#                      before each board_resolve, when lib/cache.sh is sourced —
#                      see below); `resolve_warm` reads whatever is currently
#                      cached. Whenever the board's issue-plane cache isn't in
#                      effect for the board under test (lib/cache.sh not
#                      sourced, or that board's `board.<N>.cache` conf axis is
#                      off), cold and warm both fall through to the same live
#                      path and report near-identical numbers — an honest
#                      result, not a bug.
#   --with-mutations   also time a WRITE (board_set_status set to the CURRENT
#                      value — idempotent, no net state change). Off by default.
#   --dry-run          offline self-test: no network, no rate_limit, fake timings
#                      exercising the stats+emit+table pipeline (used by the test).
#
# Sources lib/cache.sh (guarded, optional — same convention as worklist.sh) so
# the board adapter's cached read arm is actually reachable here; without it
# `resolve_cold`/`resolve_warm` would be measuring the same live path under two
# different names (the bug this bench used to have — foundation#1029's
# `BASH_ENV=…/cache.sh gh-bench.sh …` workaround).
#
# Records land (one per op_class, plus a `_run_total`) in:
#   ${GH_PERF_RAW_DIR:-<repo>/meta/data/raw}/gh-perf-YYYY-MM.jsonl
# Per-op-class records for `resolve_cold`/`resolve_warm` fold the arm they
# measured into `--label` (`<label>-live` / `<label>-cached`) since the lake
# is append-only, never backfilled, and emit-gh-perf.sh's record shape carries
# no arm field — an unlabelled row would be permanently ambiguous. The
# `_run_total` record instead folds in whether lib/cache.sh was sourced at all
# this run (`<label>-cache-available` / `<label>-cache-unavailable`): a single
# `--both` run's `_run_total` spans BOTH arms, so attributing it to one would
# be a lie — these are two different true facts about the run.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EMIT="${GH_BENCH_EMIT_BIN:-$HERE/../emit-gh-perf.sh}"

board=""; phase=""; label=""; reps=3; mode="both"
backend="github"; with_mutations=0; dry_run=0

die() { echo "gh-bench: $1" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --board)          board="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
    --phase)          phase="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
    --label)          label="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
    --reps)           reps="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
    --cold)           mode="cold"; shift ;;
    --warm)           mode="warm"; shift ;;
    --both)           mode="both"; shift ;;
    --with-mutations) with_mutations=1; shift ;;
    --backend)        backend="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
    --dry-run)        dry_run=1; shift ;;
    -h|--help)        sed -n '2,63p' "$0"; exit 0 ;;
    *)                die "unknown argument: $1" ;;
  esac
done

[ -n "$board" ] || die "--board is required"
[ -n "$phase" ] || die "--phase is required (before|after)"
[ -n "$label" ] || die "--label is required"
case "$phase" in before|after) : ;; *) die "--phase must be before|after" ;; esac
case "$reps" in ''|*[!0-9]*) die "--reps must be a number" ;; esac
[ "$reps" -ge 1 ] || die "--reps must be >= 1"

command -v jq >/dev/null 2>&1 || die "jq is required"

# --- ms clock (perl Time::HiRes; whole-second fallback) ---------------------
_now_ms() {
  local ms
  if ms="$(/usr/bin/perl -MTime::HiRes=time -e 'printf "%d", time()*1000' 2>/dev/null)" \
     && [ -n "$ms" ]; then printf '%s' "$ms"; else printf '%s000' "$(date +%s)"; fi
}

# --- percentile stats over a list of integer ms -----------------------------
# echoes "count p50 p95 max total" (nearest-rank; for small reps p95≈max).
_stats() {
  local n; n=$#
  [ "$n" -eq 0 ] && { echo "0 0 0 0 0"; return; }
  local sorted tot mx p50 p95
  sorted="$(printf '%s\n' "$@" | sort -n)"
  tot="$(printf '%s\n' "$@" | awk '{s+=$1} END{printf "%d", s+0}')"
  mx="$(printf '%s\n' "$sorted" | tail -1)"
  p50="$(printf '%s\n' "$sorted" | awk -v n="$n" 'NR==int((n-1)*0.5)+1{print; exit}')"
  p95="$(printf '%s\n' "$sorted" | awk -v n="$n" 'NR==int((n-1)*0.95)+1{print; exit}')"
  echo "$n $p50 $p95 $mx $tot"
}

# --- rate-limit snapshot: "graphql_remaining core_remaining" ----------------
_ratelimit() {
  if [ "$dry_run" -eq 1 ]; then echo "0 0"; return; fi
  gh api rate_limit 2>/dev/null \
    | jq -r '"\(.resources.graphql.remaining // 0) \(.resources.core.remaining // 0)"' \
    2>/dev/null || echo "0 0"
}

# --- the board adapter under test -------------------------------------------
if [ "$dry_run" -eq 0 ]; then
  # shellcheck source=workflows/scripts/board/lib/board.sh
  . "$HERE/../board/lib/board.sh"
  # Issue-plane read cache (F#988 Contract). board.sh's cached read arm gates
  # on `command -v cache_read` and board.sh NEVER sources cache.sh itself
  # (board.sh:479-483) — a deliberate one-way layering that keeps reconcile.sh
  # permanently on the live arm. So the CALLER must source it, exactly like
  # worklist.sh:50-53, or `resolve_cold`/`resolve_warm` below silently measure
  # the identical live path. Guarded on existence: a consuming repo that
  # vendors a subset without cache.sh still runs unchanged. `if` rather than
  # `[ -f … ] && source …` because this script is `set -euo pipefail`: the &&
  # form would abort the run when cache.sh is absent.
  if [ -f "$HERE/../board/lib/cache.sh" ]; then
    # shellcheck source=workflows/scripts/board/lib/cache.sh
    . "$HERE/../board/lib/cache.sh"
  fi
  REPO="$(board_repo "$board")" || die "cannot resolve repo for board $board"
fi

# Fixed issue set: the first up-to-5 issue numbers on the board (discovered live
# so the bench needs no hardcoded numbers). Dry-run uses a fake set.
if [ "$dry_run" -eq 1 ]; then
  ISSUES="1 2 3"
else
  # board_item_list wraps as {"items":[…]} on the issues backend and may return a
  # bare array on Projects — accept either: (.items // .) then iterate.
  ISSUES="$(board_item_list "$board" 2>/dev/null \
    | jq -r '(.items // .)[]?.content.number // empty' 2>/dev/null | head -5 | tr '\n' ' ')"
  [ -n "${ISSUES// /}" ] || die "no issues discovered on board $board — cannot bench"
fi

# --- one invocation of a named section (output discarded) -------------------
# Dry-run replaces every section body with a no-op so the pipeline is exercised
# offline. Live-run calls the real adapter path the section names.
_run_section() {
  local sec="$1" i
  if [ "$dry_run" -eq 1 ]; then return 0; fi
  case "$sec" in
    resolve_cold)
      # Force a genuinely live read: dirty the on-disk store's entry for this
      # repo (a pure no-op when lib/cache.sh isn't sourced or no store exists
      # yet — cache_dirty's own contract) BEFORE EVERY rep, not just once —
      # the store persists across reps (it's an on-disk, cross-process cache,
      # unlike the removed in-memory board.sh cache), so dirtying only once
      # would leave reps 2..N silently served warm. `BOARD_CACHE_TTL=0` used
      # to sit here; that variable is dead (its only remaining mention in
      # board.sh is a comment describing the removed Projects-v2 cache), so it
      # forced nothing — resolve_cold and resolve_warm were byte-identical.
      command -v cache_dirty >/dev/null 2>&1 && cache_dirty "$REPO" >/dev/null 2>&1
      board_resolve "$board" >/dev/null 2>&1 || true
      ;;
    resolve_warm) board_resolve "$board" >/dev/null 2>&1 || true ;;
    item_list)    board_item_list "$board" >/dev/null 2>&1 || true ;;
    resolve_item) for i in $ISSUES; do board_resolve_item "$board" "$i" >/dev/null 2>&1 || true; done ;;
    worklist)     "$HERE/../board/worklist.sh" --board "$board" --all >/dev/null 2>&1 || true ;;
    reconcile_status) "$HERE/../board/reconcile.sh" --board "$board" --status >/dev/null 2>&1 || true ;;
    pipeline_read_emu)
      # emulate pipeline-tick's read fan-out: two label searches + a per-issue view
      GH_CALL_OP="bench:pipeline_emu" gh issue list --repo "$REPO" --search "label:fnd:status:in-progress" --limit 20 >/dev/null 2>&1 || true
      GH_CALL_OP="bench:pipeline_emu" gh issue list --repo "$REPO" --search "is:open" --limit 20 >/dev/null 2>&1 || true
      for i in $ISSUES; do GH_CALL_OP="bench:pipeline_emu" gh issue view "$i" --repo "$REPO" --json number,labels,state >/dev/null 2>&1 || true; done
      ;;
    rel_loop)     for i in $ISSUES; do board_blocked_by_open "$board" "$i" >/dev/null 2>&1 || true; board_sub_issues "$board" "$i" >/dev/null 2>&1 || true; done ;;
    mutation_noop)
      for i in $ISSUES; do
        cur="$(board_resolve_item "$board" "$i" 2>/dev/null | jq -r '.status // empty' 2>/dev/null)"
        if [ -n "$cur" ]; then board_set_status "$board" "$i" "$cur" >/dev/null 2>&1 || true; fi
        break   # a single write is enough to time the write path
      done ;;
  esac
}

# --- per-section arm label suffix -------------------------------------------
# Only resolve_cold/resolve_warm have a CODE-ENFORCED arm (cold: cache_dirty
# forced every rep above; warm: served whatever's currently cached) — every
# other section (item_list, resolve_item, worklist, reconcile_status,
# pipeline_read_emu, rel_loop, mutation_noop) runs once per invocation
# regardless of --cold/--warm/--both and has no such guarantee, so it keeps
# the plain label rather than a guessed/unverified arm suffix.
_section_label() {
  case "$1" in
    resolve_cold) printf '%s-live' "$label" ;;
    resolve_warm) printf '%s-cached' "$label" ;;
    *)            printf '%s' "$label" ;;
  esac
}

# --- section list from mode -------------------------------------------------
SECTIONS=""
case "$mode" in
  cold) SECTIONS="resolve_cold" ;;
  warm) SECTIONS="resolve_warm" ;;
  both) SECTIONS="resolve_cold resolve_warm" ;;
esac
SECTIONS="$SECTIONS item_list resolve_item worklist reconcile_status pipeline_read_emu rel_loop"
[ "$with_mutations" -eq 1 ] && SECTIONS="$SECTIONS mutation_noop"

# --- run --------------------------------------------------------------------
echo "gh-bench: board=$board phase=$phase label=$label reps=$reps mode=$mode backend=$backend dry_run=$dry_run"
[ "$dry_run" -eq 0 ] && echo "gh-bench: issue set = ${ISSUES}"

read -r gql0 core0 <<EOF
$(_ratelimit)
EOF

printf '%-18s %5s %8s %8s %8s %9s\n' "op_class" "reps" "p50_ms" "p95_ms" "max_ms" "total_ms"
printf '%-18s %5s %8s %8s %8s %9s\n' "------------------" "-----" "--------" "--------" "--------" "---------"

for sec in $SECTIONS; do
  durs=""
  r=0
  while [ "$r" -lt "$reps" ]; do
    t0="$(_now_ms)"; _run_section "$sec"; t1="$(_now_ms)"
    d=$(( t1 - t0 )); [ "$d" -ge 0 ] || d=0
    durs="$durs $d"
    r=$(( r + 1 ))
  done
  # shellcheck disable=SC2086  # intentional word-split of the durations list
  set -- $durs
  read -r cnt p50 p95 mx tot <<EOF
$(_stats "$@")
EOF
  printf '%-18s %5s %8s %8s %8s %9s\n' "$sec" "$cnt" "$p50" "$p95" "$mx" "$tot"
  "$EMIT" --phase "$phase" --label "$(_section_label "$sec")" --source bench --backend "$backend" \
    --board "$board" --op-class "$sec" --count "$cnt" \
    --p50 "$p50" --p95 "$p95" --max "$mx" --total "$tot" >/dev/null 2>&1 || true
done

read -r gql1 core1 <<EOF
$(_ratelimit)
EOF
gql_spent=$(( gql0 - gql1 )); [ "$gql_spent" -ge 0 ] || gql_spent=0
core_spent=$(( core0 - core1 )); [ "$core_spent" -ge 0 ] || core_spent=0
echo "gh-bench: budget spent this run — core(REST)=${core_spent} calls [the tracker's own 5,000/hr bucket], graphql=${gql_spent} pts (informational — no board draws on this budget anymore)"

# _run_total spans EVERY section run this invocation — in --both mode that's
# both the cold and the warm arm under ONE record, so attributing it to
# either arm would be a lie. What IS true of the whole process is whether
# lib/cache.sh got sourced at all (the precondition for either arm to mean
# anything) — report that fact instead, folded into --label the same way.
if command -v cache_read >/dev/null 2>&1; then
  total_label="${label}-cache-available"
else
  total_label="${label}-cache-unavailable"
fi
"$EMIT" --phase "$phase" --label "$total_label" --source bench --backend "$backend" \
  --board "$board" --op-class "_run_total" --count "$reps" \
  --gql-pts "$gql_spent" --rest-calls "$core_spent" >/dev/null 2>&1 || true

echo "gh-bench: done — records appended to ${GH_PERF_RAW_DIR:-<repo>/meta/data/raw}/gh-perf-$(date -u +%Y-%m).jsonl"
