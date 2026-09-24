#!/usr/bin/env bash
#
# validate-command-run-reconcile.sh — the reconciliation guard for the
# command-run telemetry stream (temperloop#2220).
#
# THE PROPERTY IT OWNS, in one line:
#
#     the stream reduces to EXACTLY ONE record per command run.
#
# It breaks in BOTH directions, and a guard that only watches one half is
# worth very little:
#
#   * DUPLICATE — one run, several records. A `/fix` run parks at the merge
#     gate (`parked: 1`), the operator approves later in the same run, and the
#     run emits again (`merged: 1`). Two lines, one item; any consumer summing
#     `items_processed` counts it twice and the run reads as both parked and
#     merged. That is the shape temperloop#2220 was filed on.
#   * MISSING — one run, no record at all. Observed in the same session that
#     filed it: seven consecutive `/fix` dispositions and a second session's
#     two merges produced ZERO records, because the terminal emit simply was
#     not called. A duplicate-only guard passes cleanly through that silence.
#
# THE REDUCER (the consumer reference implementation, `--reduce`).
# Records carry a stable `run_id` from temperloop#2220 on. Reduction is:
# group by `run_id`, sort by `ts`, take the LAST record of each group — a
# later record supersedes an earlier one for the same run, which is how the
# park→merge pair collapses to one merged item WITHOUT rewriting or
# backfilling any already-written line (this stream is strictly append-only,
# per meta/data/raw/README.md).
#
# THE PRE-#2220 BACKLOG. A record with no `run_id` is a legacy record and
# reduces as its OWN SINGLETON RUN — the tolerant read. That is not a repair:
# a legacy park→merge pair still reduces to two runs, because nothing in the
# data can say the two lines belonged together and the stream is never
# rewritten. Legacy records are therefore reported, never failed. What IS
# failed is a record written AFTER the cutover (the earliest `run_id`-bearing
# record on this host) that still carries no `run_id` — that is the wiring
# regressing, and it is unreducible by construction.
#
# THE CHECKS (any one of them exits 1):
#   1. MISSING-RUN      an open-ledger marker (emit-command-run.sh's
#                       `--open`) past the grace window that never got a
#                       record: `emitted` is 0, or its `run_id` appears in no
#                       stream record at all.
#   2. UNREDUCIBLE      a record at or after the cutover with no `run_id`.
#   3. NON-RECONCILING  a reduced, run_id-bearing record whose dispositions
#                       do not partition `items_processed`. The emitter
#                       asserts this per-record at write time; this asserts it
#                       on the REDUCED view, which is what a consumer reads.
#
# FAIL CLOSED. A validator that cannot evaluate its input reports that and
# exits non-zero — it never prints OK over an input it never read (the
# temperloop#1409 class). So: no jq, an explicitly-targeted stream that is
# absent / unreadable / empty, an explicitly-targeted open-dir that is not a
# readable directory, an unparseable stream, or an unreadable marker are all
# exit 1. The ONE case that is legitimately exit 0 is the DEFAULT mode
# finding no `command-runs-*.jsonl` at all: the lake is per-host and
# gitignored, so "this host has not emitted yet" is a real, expected state and
# not a broken property.
#
# Usage:
#   validate-command-run-reconcile.sh                  # this host's own lake
#   validate-command-run-reconcile.sh --reduce         # print the reduced runs
#   validate-command-run-reconcile.sh --stream <file> [--stream <file>…] \
#                                     [--open-dir <dir>]
#   validate-command-run-reconcile.sh --raw-dir <dir>  # a whole lake elsewhere
#
# Exit codes: 0 = property holds (or nothing emitted yet); 1 = property broken
#             or input could not be evaluated.
#
# Kept POSIX-bash-3.2-friendly (no mapfile/associative arrays) to match the
# rest of workflows/scripts/ (macOS dev shell + Linux CI).

set -uo pipefail

self="$(basename "$0")"
here="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -P "$here/../.." 2>/dev/null && pwd || echo "$HOME/dev/foundation")"

# How old an un-emitted open marker must be before it counts as a missing run
# rather than a run still in flight. A /fix run that parks at the merge gate
# and waits on an operator is legitimately long-lived, so this is generous.
: "${CMD_RUN_OPEN_GRACE_SECS:=21600}"

streams=""          # newline-separated; explicit --stream targets
raw_dir=""
open_dir=""
open_dir_explicit=0
reduce_only=0

usage() {
  sed -n '2,70p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --stream)   streams="$streams${2:-}
"; shift; if [ $# -gt 0 ]; then shift; fi ;;
    --raw-dir)  raw_dir="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
    --open-dir) open_dir="${2:-}"; open_dir_explicit=1; shift; if [ $# -gt 0 ]; then shift; fi ;;
    --reduce)   reduce_only=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    *)
      printf '%s: FAIL unknown argument %s\n' "$self" "$1" >&2
      exit 1 ;;
  esac
done

if ! command -v jq >/dev/null 2>&1; then
  printf '%s: FAIL CANNOT EVALUATE — jq not found, so the stream cannot be parsed. Install jq; a reconciliation guard never reports OK over an input it could not read.\n' "$self" >&2
  exit 1
fi

# ── Resolve the inputs ───────────────────────────────────────────────────
explicit_streams=0
[ -n "$streams" ] && explicit_streams=1

if [ "$explicit_streams" -eq 0 ]; then
  [ -n "$raw_dir" ] || raw_dir="${CMD_RUN_RAW_DIR:-$repo_root/meta/data/raw}"
  for f in "$raw_dir"/command-runs-*.jsonl; do
    [ -f "$f" ] || continue
    streams="$streams$f
"
  done
  if [ -z "$streams" ]; then
    printf '%s: ok — no command-runs-*.jsonl under %s; this host has emitted no command-run telemetry yet, so there is no reconciliation property to break.\n' "$self" "$raw_dir"
    exit 0
  fi
  [ "$open_dir_explicit" -eq 1 ] || open_dir="$raw_dir/command-run-open"
else
  # An explicitly-named stream MUST be readable and non-empty: the caller
  # asserted it exists, so an absent/empty one is an evaluation failure, not
  # an empty result set.
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ ! -e "$f" ]; then
      printf '%s: FAIL CANNOT EVALUATE — --stream %s does not exist.\n' "$self" "$f" >&2
      exit 1
    fi
    if [ ! -r "$f" ]; then
      printf '%s: FAIL CANNOT EVALUATE — --stream %s is not readable.\n' "$self" "$f" >&2
      exit 1
    fi
    if [ ! -s "$f" ]; then
      printf '%s: FAIL CANNOT EVALUATE — --stream %s is empty; an empty stream that was named explicitly is an unread input, not a clean run.\n' "$self" "$f" >&2
      exit 1
    fi
  done <<EOF
$streams
EOF
fi

if [ -n "$open_dir" ] && [ "$open_dir_explicit" -eq 1 ] && [ ! -d "$open_dir" ]; then
  printf '%s: FAIL CANNOT EVALUATE — --open-dir %s is not a readable directory, so a run that started and never emitted cannot be detected.\n' "$self" "$open_dir" >&2
  exit 1
fi

# ── Reduce ───────────────────────────────────────────────────────────────
stream_files=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  stream_files="$stream_files $f"
done <<EOF
$streams
EOF

# shellcheck disable=SC2086  # deliberate word-splitting of the collected list
report="$(cat $stream_files 2>/dev/null | jq -s -c '
  map(select(type == "object"))
  | (map(select((.run_id // null) != null) | (.ts // "")) | sort | first) as $cutover
  | (to_entries | map(.value + {_i: .key}))
  | map(. + {_k: (if (.run_id // null) != null
                  then "rid:" + (.run_id | tostring)
                  else "legacy:" + (._i | tostring) end)}) as $idx
  | {
      cutover: $cutover,
      total_records: ($idx | length),
      runs: ($idx
        | group_by(._k)
        | map((sort_by(.ts // "")) as $g | ($g | last) as $l | {
            run_id: ($l.run_id // null),
            command: ($l.command // null),
            session_id: ($l.session_id // null),
            ts: ($l.ts // null),
            items_processed: ($l.items_processed // 0),
            merged: ($l.merged // 0),
            resolved: ($l.resolved // 0),
            parked: ($l.parked // 0),
            reported_no_op: (if ($l | has("reported_no_op")) then $l.reported_no_op else null end),
            records: ($g | length),
            legacy: (($l.run_id // null) == null)
          })
        | sort_by(.ts // "")),
      unreducible: ($idx
        | map(select((.run_id // null) == null
                     and $cutover != null
                     and (.ts // "") >= $cutover))
        | map({ts: (.ts // null), command: (.command // null), session_id: (.session_id // null)}))
    }' 2>/dev/null)"

if [ -z "$report" ]; then
  printf '%s: FAIL CANNOT EVALUATE — the command-run stream could not be parsed as JSONL (%s). A malformed stream is an unread input, never a clean one.\n' \
    "$self" "$(printf '%s' "$stream_files" | sed 's/^ //')" >&2
  exit 1
fi

if [ "$reduce_only" -eq 1 ]; then
  printf '%s' "$report" | jq -c '.runs[]'
  exit 0
fi

fail=0
total_records="$(printf '%s' "$report" | jq -r '.total_records')"
run_count="$(printf '%s' "$report" | jq -r '.runs | length')"
legacy_count="$(printf '%s' "$report" | jq -r '[.runs[] | select(.legacy)] | length')"
cutover="$(printf '%s' "$report" | jq -r '.cutover // "none"')"

# ── Check 1: MISSING-RUN (a run that started and never emitted) ──────────
if [ -n "$open_dir" ] && [ -d "$open_dir" ]; then
  now_epoch="$(date -u +%s)"
  for m in "$open_dir"/*.json; do
    [ -f "$m" ] || continue
    if [ ! -r "$m" ]; then
      printf 'FAIL  MARKER-UNREADABLE  %s — an open-ledger marker that cannot be read leaves it unknown whether that run ever emitted.\n' "$m"
      fail=1
      continue
    fi
    m_rid="$(jq -r '.run_id // empty' "$m" 2>/dev/null)" || m_rid=""
    m_cmd="$(jq -r '.command // "?"' "$m" 2>/dev/null)" || m_cmd="?"
    m_at="$(jq -r '.opened_at // "?"' "$m" 2>/dev/null)" || m_at="?"
    m_epoch="$(jq -r '.opened_epoch // 0' "$m" 2>/dev/null)" || m_epoch=0
    m_emitted="$(jq -r '.emitted // 0' "$m" 2>/dev/null)" || m_emitted=0
    case "$m_epoch" in ''|*[!0-9]*) m_epoch=0 ;; esac
    case "$m_emitted" in ''|*[!0-9]*) m_emitted=0 ;; esac
    if [ -z "$m_rid" ]; then
      printf 'FAIL  MARKER-MALFORMED  %s — carries no run_id, so the run it opened can never be matched to a record.\n' "$m"
      fail=1
      continue
    fi
    # Still inside the grace window ⇒ plausibly still in flight; say nothing.
    [ "$((now_epoch - m_epoch))" -ge "$CMD_RUN_OPEN_GRACE_SECS" ] || continue
    seen="$(printf '%s' "$report" | jq -r --arg r "$m_rid" '[.runs[] | select(.run_id == $r)] | length')"
    if [ "$m_emitted" -eq 0 ] || [ "$seen" -eq 0 ]; then
      printf 'FAIL  MISSING-RUN  run_id=%s command=%s opened_at=%s — this run opened and never produced a reducible record (emitted=%s, records in stream=%s). The run happened; the terminal emit did not. Call emit-command-run.sh at EVERY terminal route of /%s, then remove %s.\n' \
        "$m_rid" "$m_cmd" "$m_at" "$m_emitted" "$seen" "$m_cmd" "$m"
      fail=1
    fi
  done
fi

# ── Check 2: UNREDUCIBLE (post-cutover record with no run_id) ────────────
unreducible_n="$(printf '%s' "$report" | jq -r '.unreducible | length')"
if [ "$unreducible_n" -gt 0 ]; then
  printf '%s' "$report" | jq -r --arg c "$cutover" '.unreducible[]
    | "FAIL  UNREDUCIBLE  ts=\(.ts) command=\(.command) session=\(.session_id) — written at or after this host'"'"'s run-id cutover (\($c)) but carrying no run_id, so it can never be collapsed with the other records of its run. The caller lost its --run-id/--open wiring (emit-command-run.sh, temperloop#2220)."'
  fail=1
fi

# ── Check 3: NON-RECONCILING reduced record ──────────────────────────────
nonrec="$(printf '%s' "$report" | jq -r '
  [.runs[]
   | select(.legacy | not)
   | select(.reported_no_op != null)
   | select((.merged + .resolved + .parked + .reported_no_op) != .items_processed)]
  | .[] | "FAIL  NON-RECONCILING  run_id=\(.run_id) command=\(.command) — merged(\(.merged)) + resolved(\(.resolved)) + parked(\(.parked)) + reported_no_op(\(.reported_no_op)) != items_processed(\(.items_processed)) in the REDUCED view of this run."')"
if [ -n "$nonrec" ]; then
  printf '%s\n' "$nonrec"
  fail=1
fi

# ── Verdict ──────────────────────────────────────────────────────────────
if [ "$fail" -eq 1 ]; then
  printf '%s: FAIL the command-run stream does not reduce to exactly one record per run (%s record(s) → %s run(s); %s legacy run(s) with no run_id; cutover %s).\n' \
    "$self" "$total_records" "$run_count" "$legacy_count" "$cutover" >&2
  printf '%s: the pre-#2220 backlog is NEVER backfilled — a legacy record reduces as its own singleton run and is reported, not failed. Only the findings above are defects.\n' "$self" >&2
  exit 1
fi

printf '%s: ok — %s record(s) reduce to %s run(s), one record per run (%s legacy run(s) with no run_id, read as singletons; cutover %s).\n' \
  "$self" "$total_records" "$run_count" "$legacy_count" "$cutover"
exit 0
