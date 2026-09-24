#!/usr/bin/env bash
#
# emit-command-run.sh — append one per-run telemetry record for a /sweep or
# /triage command run to the append-only raw sink (foundation #729).
#
# WHY THIS EXISTS: /sweep and /triage have no plan-note footer (unlike /build,
# whose plan note IS the run record), so a whole run could complete — or
# silently stop emitting — with no telemetry signal at all. That is the June
# silent-failure class: a stream nobody writes to produces no staleness alarm,
# so its absence looks identical to "nothing to do" rather than "broken." This
# script is the mechanical fix: a concrete, invocable emit, backed by a
# presence-lint (workflows/scripts/validate-command-run-emit.sh, wired into
# `scripts/quality-gates.sh`) that fails CI if this script disappears OR its
# call is removed from claude/commands/sweep.md / claude/commands/triage.md.
#
# Usage:
#   emit-command-run.sh --command sweep|triage|fix --board <N> \
#     --items-processed <N> --merged <N> --resolved <N> --parked <N> \
#     --reported-no-op <N> [--epic <N>] [--run-id <id>] [--target <id>]
#   emit-command-run.sh --open --command sweep|triage|fix [--board <N>] \
#     [--target <id>]
#     → mints this run's stable run id, records it in the OPEN LEDGER, and
#       prints it. Called ONCE, at the start of a run. See THE RUN LEDGER.
#
#   --target is the RUN's own identity within a session: the thing this run
#   drives (a /fix target, a /sweep board). It never enters the record — it
#   only keys the open ledger — and a run's `--open` call and its terminal
#   emit MUST pass the SAME value, or the terminal emit cannot find the
#   marker to adopt. See THE RUN LEDGER's "ONE MARKER PER RUN" note.
#
# Appends ONE JSONL line to:
#   ${CMD_RUN_RAW_DIR:-<repo>/meta/data/raw}/command-runs-YYYY-MM.jsonl
# (monthly rotation, matching the pipeline-<YYYY-MM>.jsonl / session-YYYY-MM
# convention already used in meta/data/raw/).
#
# canonical sink spec: meta/data/raw/README.md (lake path + schema-version
# convention; this stream's own record shape is documented below).
#
# Record shape: {ts, session_id, run_id, command, board, items_processed, merged, resolved, parked, reported_no_op, epic?}
#   ts               ISO-8601 UTC, `Z` suffix (matches the raw/ stream convention)
#   session_id       the RAW $CLAUDE_CODE_SESSION_ID (full value, UNTRUNCATED) —
#                     the join key every other raw/ stream keys on
#                     (askuserquestion-events.jsonl, workflow-eval-results.jsonl);
#                     deliberately NOT the 8-char truncated form claim.sh stamps
#                     onto the board's Host/Session field for human display —
#                     that truncation is a UI convenience, not a join key, and
#                     truncating here would break the join to Layer-2 session
#                     telemetry this record exists to support. null when the
#                     env var is unset (e.g. a manual/non-Claude-Code run).
#   run_id           the STABLE id of the RUN this record belongs to
#                     (temperloop#2220). Every record this script writes from
#                     #2220 on carries it; its ABSENCE is a reliable pre-#2220
#                     marker, read as UNKNOWN — the same append-only,
#                     never-backfilled convention as `resolved` /
#                     `reported_no_op` below. It is what makes the stream
#                     REDUCIBLE: several records can describe ONE run (a /fix
#                     run parks at the merge gate, the operator approves it
#                     later in the same run, and the run emits again with
#                     --merged 1), so a consumer collapses by run_id and takes
#                     the LAST record rather than summing every line. A
#                     pre-#2220 record without the field reduces as its own
#                     singleton run — the tolerant read, since this stream is
#                     never rewritten. Purely additive, so no schema_version
#                     bump (meta/data/raw/README.md convention).
#   command          "sweep" | "triage" | "fix" (whatever --command was passed,
#                     verbatim)
#   board            the board id (--board), or null
#   items_processed  integer — how many items the run drove/considered
#   merged           integer — how many landed a merged PR
#   resolved         integer — how many reached a terminal outcome that is
#                     NOT a merge: a `kind: spike` closed on its verdict, a
#                     culled issue, a decision routed off-board. Added by
#                     temperloop#1084 — before it, /sweep folded these into
#                     `merged` (or, worse, into nothing at all, so the counts
#                     did not reconcile against items_processed).
#                     ⚠ ABSENT on a record written before #1084 — and absent
#                     means UNKNOWN, never 0. This stream is append-only and is
#                     NEVER backfilled, so a consumer must distinguish `has no
#                     resolved field` (a pre-#1084 record: some of its `merged`
#                     count may in fact be verdict-resolved) from
#                     `"resolved": 0` (a post-#1084 run that genuinely resolved
#                     nothing). Every record this script writes from #1084 on
#                     carries the field explicitly, so its absence is a
#                     reliable pre-#1084 marker. Purely additive, so no
#                     schema_version bump (meta/data/raw/README.md convention).
#   parked           integer — how many were parked/deferred/escalated
#   reported_no_op   integer — how many were a terminal "nothing to do" outcome
#                     that is not a merge, a verdict-resolve, or a park: an
#                     already-done target, a claim already held by another
#                     session, or an epic-refused redirect (`/fix` 4d/4e/Step
#                     3). Added by temperloop#1103 — before it, `/fix`'s two
#                     reported-no-op routes (4d/4e) never called this emitter
#                     at all, so a no-op /fix run had no way to reconcile:
#                     items_processed=1 with merged=resolved=parked=0 would
#                     have tripped the loud failure below on every single
#                     no-op run, so fix.md instead skipped the emit entirely —
#                     which meant a no-op /fix run left NO telemetry record,
#                     the exact absent-signal failure this whole script exists
#                     to close.
#                     ⚠ ABSENT on a record written before #1103 — and absent
#                     means UNKNOWN, never 0, same convention as `resolved`
#                     above: this stream is append-only and is NEVER
#                     backfilled, so a pre-#1103 record's true disposition
#                     mix (e.g. a /fix no-op that got folded into no count at
#                     all, or simply never emitted) cannot be recovered.
#                     Every record this script writes from #1103 on carries
#                     the field explicitly, so its absence is a reliable
#                     pre-#1103 marker. Purely additive, so no schema_version
#                     bump (meta/data/raw/README.md convention).
#   epic             OPTIONAL — the epic issue number the run drove against
#                     (e.g. `/assess --epic N`, or `/build` on a plan note with
#                     an `epic:` frontmatter field). ABSENT (not null/empty)
#                     from the record entirely when the caller doesn't pass
#                     `--epic` — most command-run callers (sweep/triage) never
#                     run against a single epic, so this keeps their records
#                     shaped exactly as before (purely additive; no
#                     schema_version bump per the convention in
#                     meta/data/raw/README.md).
#   epics_reviewed    OPTIONAL — /sweep's end-of-run epic-closing gate
#   epics_closed      (temperloop item "epic-closing-gate", epic #1847): how
#   epics_left_open   many Operational-epic parents the gate looked at this
#                     run, how many it actually closed (a real
#                     board_close_done / gh issue close write), and how many
#                     it left open (keep-open, unattended, partial, or a
#                     declined offer). ALL THREE ABSENT from the record
#                     entirely when the caller doesn't pass `--epics-
#                     reviewed` — callers OTHER THAN /sweep (triage/fix)
#                     never touch this schema extension, so this keeps their
#                     records shaped exactly as before (purely additive; no
#                     schema_version bump). Every /sweep run itself DOES pass
#                     all three, even on its zero-epic fast path
#                     (`--epics-reviewed 0 --epics-closed 0
#                     --epics-left-open 0`) — the always-carry semantics
#                     (round 5 escalation, MEDIUM finding): a /sweep record
#                     missing this extension is itself the "the gate step
#                     didn't run" signal, distinct from a genuine 0/0/0 (the
#                     gate ran and found nothing to review). This is a
#                     DISTINCT partition from
#                     merged/resolved/parked/reported_no_op above — an epic is
#                     never one of a run's Phase-2 pooled ISSUES, so it never
#                     contributes to items_processed; it is its own
#                     three-way split, enforced by its own accounting check
#                     below (see THE ONE LOUD FAILURE), the same shape as the
#                     items_processed partition but independent of it.
#
# THE RUN LEDGER — the other half of `run_id` (temperloop#2220).
# A run id alone makes a DOUBLE emit reducible. It does nothing about the
# inverse failure the same issue turned up: a run that emits NOTHING (seven
# consecutive /fix dispositions, zero records — the terminal emit simply was
# not called). Detecting that needs a witness that the run STARTED, so this
# script keeps a tiny open ledger beside the stream:
#
#   ${CMD_RUN_RAW_DIR:-<repo>/meta/data/raw}/command-run-open/<session>__<command>[__<target>].json
#     {run_id, command, session_id, board, target, opened_at, opened_epoch, emitted}
#
# ONE MARKER PER RUN — why the key carries `--target`. The key was once
# (session, command) alone, on the stated premise that only one run of one
# command runs per session at a time. That premise is FALSE, and was disproved
# by ordinary operator usage in the very session that built this: `/fix 2220
# and 2224` ran two /fix runs CONCURRENTLY in one session. Two live runs, one
# key — one marker, one run id, and whichever `--open` came second silently
# overwrote the first run's held id. A run id that two runs share is the same
# double-count the field exists to prevent, one layer down. So the key carries
# the run's target, `--open` NEVER clobbers a marker that is still live on its
# key (it reuses it and says so on stderr), and a STALE un-emitted marker — the
# MISSING-RUN alarm — is moved aside rather than overwritten, because deleting
# the alarm before any guard reads it is the failure this ledger exists to
# report. A caller that passes no `--target` keeps the old (session, command)
# key verbatim, so nothing about an existing marker changes shape.
#
# `nosession` (the $CLAUDE_CODE_SESSION_ID-unset fallback) is a KNOWN, bounded
# residue, disposed rather than fixed: outside Claude Code every run keys on
# the same `nosession` stem, so two manual runs of one command CAN meet on one
# key. Target-keying removes the common case (two manual runs on different
# targets no longer collide), and the never-clobber rule removes the damaging
# half of what is left — a collision now REUSES the held id and warns, instead
# of destroying it. A PID would make the key unique but unusable: the marker's
# whole job is to be found by a LATER, SEPARATE process (the terminal emit), so
# a key no other process can reconstruct is not a ledger.
#
#   * `--open` (run start) mints a run id, writes the marker with emitted=0,
#     and prints the id.
#   * A normal emit ADOPTS that marker's run id (so the caller never has to
#     carry the string between steps), appends its record, and then either
#     HOLDS the marker — bumping `emitted` — when the record still reports a
#     parked item (the run may converge later in this same run), or CLOSES it
#     (removes it) when nothing is parked and the run is genuinely over. It
#     closes ONLY the marker it ADOPTED: a marker on the same key that this
#     emit did not adopt — an aged `emitted=0` alarm, or a malformed one with
#     no run_id — is left in place for the guard to find, never swept up as a
#     side effect of some other run finishing.
#   * `--open` also PRUNES spent markers — held past the adoption TTL with a
#     record already emitted, so nothing can adopt them again. A marker with
#     emitted=0 is never pruned at any age: that one IS the alarm below.
#
#     THE TRADE-OFF THAT BUYS, STATED RATHER THAN HIDDEN (temperloop#2220
#     round 3, LOW). `--open` is the ONLY reaper. Because the close path now
#     retires only the marker its own emit ADOPTED, a marker that was held
#     (emitted > 0) and has since aged past $CMD_RUN_RUN_ID_TTL_SECS is SPENT
#     but LINGERS on disk until the next `--open` on this host runs the prune.
#     That is accepted deliberately, and the cost is bounded and inert:
#       - a spent marker cannot be adopted (it is past the TTL), so it can
#         never merge two runs onto one run id;
#       - it cannot raise a false MISSING-RUN either, because that check fires
#         on `emitted == 0` or a run id absent from the stream, and a spent
#         marker has emitted > 0 with its record already in the lake;
#       - the ledger stays bounded at one file per (session, command, target)
#         key, and every instrumented run starts with an `--open`, so the
#         lingering window is one run, not unbounded growth.
#     The alternative — reaping on the close path too — was rejected: it would
#     put a directory scan plus a jq read per marker on the terminal-emit hot
#     path of every command run, to retire OTHER runs' inert files a few
#     minutes earlier, and it would re-touch the exact close-path logic whose
#     unconditional `rm` was the round-3 defect. Lingering is the cheaper,
#     safer side of that trade.
#   * A marker left behind with emitted=0 is a run that started and never
#     emitted. workflows/scripts/validate-command-run-reconcile.sh is the
#     guard that reads it and goes red — on that MISSING case and on the
#     DUPLICATE case alike, since "exactly one reducible record per run" is
#     one property that breaks in two directions.
#
# A marker is only ADOPTED while it is fresher than CMD_RUN_RUN_ID_TTL_SECS,
# so a stale one from an earlier run can never silently merge two runs into
# one; past the TTL the emit mints a fresh id instead. The ledger is
# best-effort throughout: an unwritable ledger degrades to a freshly minted,
# per-emit run id and never blocks or fails the emit.
#
# WARN, DON'T DROP: any INFRASTRUCTURE failure here (jq missing, sink
# unwritable, disk full, a malformed count) warns to stderr and exits 0. A
# telemetry emit must never fail or block the calling command — see the
# `|| true`-safe contract in the epic #724 Contract.
#
# THE ONE LOUD FAILURE — a disposition-accounting mismatch (temperloop#1084,
# extended to a four-way partition by temperloop#1103).
# `merged + resolved + parked + reported_no_op` MUST equal `items_processed`:
# every item a run drove reaches exactly one terminal disposition, so the four
# counts partition the total. If they don't, the run produced an outcome this
# schema cannot express — precisely the silent under-report #1084 was filed
# for (a 30-item sweep emitting merged=27, parked=1 and no way to say the
# other 2 were resolved by verdict), and the same class of bug #1103 was filed
# for (a /fix no-op run emitting items_processed=1 with nothing else set,
# because the schema had no fourth field to say "nothing happened, on
# purpose"). That is an ACCOUNTING bug in the caller or a MISSING FIELD in
# this schema, not an infrastructure hiccup, so it must not be swallowed:
#
#   * the record IS still appended, with the caller's counts verbatim — the
#     mismatch is preserved in the stream rather than dropped, because an
#     inconsistent record is strictly more informative than no record (the
#     absent-stream ambiguity this whole script exists to close), and
#   * the script then prints a FAIL line naming the arithmetic and exits **2**.
#
# A SECOND, INDEPENDENT accounting check (temperloop item "epic-closing-
# gate", epic #1847) — /sweep's end-of-run epic-closing gate. WHENEVER
# `--epics-reviewed` is passed, `epics_closed + epics_left_open` MUST equal
# `epics_reviewed`: every Operational epic the gate looked at reaches exactly
# one of "actually closed" or "left open" (keep-open, unattended, partial
# drain, or a declined offer-close). This mirrors the
# merged+resolved+parked+reported_no_op == items_processed check above in
# shape only — it is a SEPARATE partition over a SEPARATE population (epics,
# never Phase-2 pooled issues), checked independently, and never folded into
# the items_processed arithmetic. Omitting `--epics-reviewed` entirely (the
# common case — most callers, and a /sweep run that admitted no epics this
# run) skips this check outright; a caller that passes `--epics-reviewed 0`
# still must pass `--epics-closed 0 --epics-left-open 0` (0+0==0 reconciles
# trivially).
#
# Exit codes: 0 = emitted, or warned-and-skipped for an infrastructure reason
#             2 = record emitted BUT the disposition counts do not reconcile
#                 (either the items_processed partition, the epics_reviewed
#                 partition, or both — the FAIL lines name which)
# A caller that must never see a non-zero (a `|| true` site) keeps working; a
# caller or CI reading the exit code sees the accounting break loudly.
#
# Kept POSIX-bash-3.2-friendly (no mapfile/associative arrays) to match the
# rest of workflows/scripts/ (macOS dev shell + Linux CI).

set -uo pipefail

self="$(basename "$0")"

command=""
board=""
run_id=""
target=""
open_mode=0
items_processed=""
merged=""
resolved=""
parked=""
reported_no_op=""
epic=""
epics_reviewed=""
epics_closed=""
epics_left_open=""

# ARG LOOP — the shift is deliberately TWO steps (temperloop#1342). Bash's
# `shift 2` FAILS (count out of range) when the flag is the LAST argument, and
# a FAILED shift does not shift: `$#` never decreases, the same arm re-matches,
# and this loop spins at 100% CPU forever. `${2:-}` is what makes that a HANG
# rather than a `set -u` crash. A hang here is strictly worse than the failure
# this file's never-fail-or-block-the-spawn-site contract exists to prevent —
# the conventional `emit-… || true` call shape cannot save a caller from it.
# So: shift the FLAG, then the value only if one is actually there.
# scripts/lint-argloop-shift2.sh is the mechanical guard for the class.
while [ $# -gt 0 ]; do
  case "$1" in
    --command) command="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
    --board) board="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
    --items-processed) items_processed="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
    --merged) merged="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
    --resolved) resolved="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
    --parked) parked="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
    --reported-no-op) reported_no_op="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
    --epic) epic="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
    --run-id) run_id="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
    --target) target="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
    --open) open_mode=1; shift ;;
    --epics-reviewed) epics_reviewed="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
    --epics-closed) epics_closed="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
    --epics-left-open) epics_left_open="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
    *)
      printf '%s: WARN unknown argument %s (ignored)\n' "$self" "$1" >&2
      shift
      ;;
  esac
done

if [ -z "$command" ]; then
  printf '%s: WARN --command is required — no record emitted\n' "$self" >&2
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  printf '%s: WARN jq not found — no record emitted (command=%s)\n' "$self" "$command" >&2
  exit 0
fi

# ── THE RUN LEDGER (temperloop#2220) ─────────────────────────────────────
# Resolve the raw sink dir the same way pipeline-cron.sh resolves
# PIPELINE_RAW_DIR: an explicit override env var first, else the repo this
# script lives in (workflows/scripts/../../meta/data/raw), so it works from
# any checkout that vendors this file, not just a hardcoded
# $HOME/dev/foundation path. Resolved HERE rather than just before the
# append, because `--open` writes the ledger and never reaches that point.
# BOTH resolutions carry a fallback. `here` used to have none while the very
# next line's did — and an empty `here` makes "$here/../.." resolve to `/`,
# where `cd -P` SUCCEEDS, so that line's `||` fallback could never fire.
here="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || here=""
[ -n "$here" ] || here="$(dirname "${BASH_SOURCE[0]}")"
[ -n "$here" ] || here="."
raw_root="$(cd -P "$here/../.." 2>/dev/null && pwd || echo "$HOME/dev/foundation")"
raw_dir="${CMD_RUN_RAW_DIR:-$raw_root/meta/data/raw}"
open_dir="$raw_dir/command-run-open"

# How long an open marker stays ADOPTABLE. Past it, an emit mints a fresh run
# id rather than adopting a marker some earlier run left behind — a stale
# adoption would silently merge two runs into one, which is the same
# under-count this field exists to prevent, one layer over.
: "${CMD_RUN_RUN_ID_TTL_SECS:=43200}"

# A malformed TTL silently disables the freshness bound it exists to be: the
# bare `[ … -le "$CMD_RUN_RUN_ID_TTL_SECS" ]` below returns 2 on a plausible
# typo like `12h`, the adoption arm reads that as "too old", and every emit
# mints a fresh id — so a park and its later merge stop sharing a run id and
# the run double-counts again, with nothing said. This emitter never FAILS a
# caller (see WARN, DON'T DROP), so it warns loudly and falls back to the
# documented default rather than running with a bound it cannot evaluate. The
# fallback re-runs the SAME `${VAR:=…}` seam so the literal never diverges
# from workflows/scripts/config/setting-registry.tsv.
case "$CMD_RUN_RUN_ID_TTL_SECS" in
  ''|*[!0-9]*)
    printf '%s: WARN CMD_RUN_RUN_ID_TTL_SECS must be a whole number of SECONDS, got "%s" — falling back to the default. Left unchecked this disables the open-marker freshness bound entirely, so a parked run and its later merge would stop sharing a run id.\n' \
      "$self" "$CMD_RUN_RUN_ID_TTL_SECS" >&2
    unset CMD_RUN_RUN_ID_TTL_SECS
    : "${CMD_RUN_RUN_ID_TTL_SECS:=43200}"
    ;;
esac

# The ledger is keyed on (session, command, target) — see THE RUN LEDGER's
# "ONE MARKER PER RUN" note for why the target is load-bearing and not
# decoration. A caller that passes no --target keeps the old (session,
# command) key byte-for-byte, so existing markers keep their names.
# Only the KEY is sanitised — never the resolved sink path, which may
# legitimately contain characters this filter would mangle.
marker_key_raw="${CLAUDE_CODE_SESSION_ID:-nosession}__$command"
if [ -n "$target" ]; then
  marker_key_raw="${marker_key_raw}__$target"
fi
marker_key="$(printf '%s' "$marker_key_raw" | tr -c 'A-Za-z0-9._-' '_')"
marker_path="$open_dir/$marker_key.json"

mint_run_id() {  # → a fresh, sortable, collision-resistant run id
  printf 'run-%s-%04x%04x\n' "$(date -u +%Y%m%dT%H%M%SZ)" "$RANDOM" "$RANDOM"
}

# ATOMIC. `jq … > "$marker_path"` truncates the file and then fills it, so a
# concurrent reader — the reconcile guard, or another emit adopting the id —
# can catch it empty or half-written, and the guard maps an unparseable marker
# to a hard FAIL. Writing a sibling temp file and `mv -f`-ing it into place is
# a rename within one directory, which is atomic, and costs nothing.
write_marker() {  # $1=run_id $2=opened_at $3=opened_epoch $4=emitted → 0 ok
  local tmp
  mkdir -p "$open_dir" 2>/dev/null || return 1
  tmp="$marker_path.tmp.$$"
  jq -nc \
    --arg run_id "$1" \
    --arg command "$command" \
    --arg session_id "${CLAUDE_CODE_SESSION_ID:-}" \
    --arg board "$board" \
    --arg target "$target" \
    --arg opened_at "$2" \
    --argjson opened_epoch "$3" \
    --argjson emitted "$4" \
    '{run_id: $run_id, command: $command,
      session_id: (if $session_id == "" then null else $session_id end),
      board: (if $board == "" then null else ($board | tonumber? // $board) end),
      target: (if $target == "" then null else $target end),
      opened_at: $opened_at, opened_epoch: $opened_epoch, emitted: $emitted}' \
    > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  mv -f "$tmp" "$marker_path" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  return 0
}

# read_marker <path> → sets MK_RID / MK_EPOCH / MK_EMITTED from that marker
# (empty / 0 / 0 when it cannot be read or parsed). Shared by --open below and
# the adoption arm further down, so the two can never read a marker
# differently.
read_marker() {
  MK_RID=""; MK_EPOCH=0; MK_EMITTED=0
  [ -r "$1" ] || return 1
  MK_RID="$(jq -r '.run_id // empty' "$1" 2>/dev/null)" || MK_RID=""
  MK_EPOCH="$(jq -r '.opened_epoch // 0' "$1" 2>/dev/null)" || MK_EPOCH=0
  MK_EMITTED="$(jq -r '.emitted // 0' "$1" 2>/dev/null)" || MK_EMITTED=0
  case "$MK_EPOCH" in ''|*[!0-9]*) MK_EPOCH=0 ;; esac
  case "$MK_EMITTED" in ''|*[!0-9]*) MK_EMITTED=0 ;; esac
  return 0
}

# Prune SPENT markers — held past the adoption TTL with a record already
# emitted (emitted > 0), so no later emit can ever adopt them again and the
# reconcile guard has nothing left to say about them. Bounds the ledger
# directory, which otherwise grows one file per (session, command) that ended
# on a parked item. A marker with emitted=0 is NEVER pruned at any age: that
# one IS the missing-run signal, and erasing it here would delete the alarm
# before the guard ever reads it. Best-effort, run once per `--open`.
prune_spent_markers() {
  local f m_emitted m_epoch now
  [ -d "$open_dir" ] || return 0
  now="$(date -u +%s)"
  for f in "$open_dir"/*.json; do
    [ -f "$f" ] && [ -r "$f" ] || continue
    m_emitted="$(jq -r '.emitted // 0' "$f" 2>/dev/null)" || continue
    m_epoch="$(jq -r '.opened_epoch // 0' "$f" 2>/dev/null)" || continue
    case "$m_emitted" in ''|*[!0-9]*) continue ;; esac
    case "$m_epoch" in ''|*[!0-9]*) continue ;; esac
    [ "$m_emitted" -gt 0 ] || continue
    [ "$((now - m_epoch))" -gt "$CMD_RUN_RUN_ID_TTL_SECS" ] || continue
    rm -f "$f" 2>/dev/null || true
  done
}

if [ "$open_mode" -eq 1 ]; then
  prune_spent_markers
  open_now_epoch="$(date -u +%s)"
  MK_RID=""; MK_EPOCH=0; MK_EMITTED=0
  read_marker "$marker_path" || true

  # NEVER CLOBBER A LIVE MARKER. The previous `> "$marker_path"` minted a
  # fresh id and dropped the held one on the floor, so the run that opened
  # first lost the very id its own terminal emit would have adopted. Within
  # the TTL this key is still somebody's live run: hand that run's id back
  # (a re-run of Step 0 in one run is idempotent this way) and say so.
  if [ -z "$run_id" ] && [ -n "$MK_RID" ] \
     && [ "$((open_now_epoch - MK_EPOCH))" -le "$CMD_RUN_RUN_ID_TTL_SECS" ]; then
    printf '%s: WARN an open marker is already LIVE on this ledger key (%s, run_id=%s, emitted=%s) — reusing its run id rather than overwriting it. If these are two DIFFERENT runs, give each its own --target: a run id is per RUN, and two runs sharing one is exactly the double-count it exists to prevent.\n' \
      "$self" "$marker_key" "$MK_RID" "$MK_EMITTED" >&2
    printf '%s\n' "$MK_RID"
    exit 0
  fi

  [ -n "$run_id" ] || run_id="$(mint_run_id)"

  # A marker we are about to REPLACE is either a stale un-emitted MISSING-RUN
  # alarm (never pruned, at any age — that one IS the alarm) or a live marker
  # an explicit --run-id is displacing. Either way, overwriting it deletes a
  # record the reconcile guard has not read yet, so move it aside instead. It
  # stays a *.json in the same ledger dir, so the guard still finds it.
  if [ -n "$MK_RID" ] && [ "$MK_RID" != "$run_id" ]; then
    mv -f "$marker_path" \
      "$open_dir/${marker_key}__$(printf '%s' "$MK_RID" | tr -c 'A-Za-z0-9._-' '_').json" \
      2>/dev/null || true
  fi

  if ! write_marker "$run_id" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$open_now_epoch" 0; then
    # Warn-don't-drop, same contract as every other failure here: the run id
    # is still printed, so the run stays reducible even with no ledger — only
    # the MISSING-run detection degrades.
    printf '%s: WARN could not write the run-id open marker under %s (command=%s) — the run id below is still usable\n' \
      "$self" "$open_dir" "$command" >&2
  fi
  printf '%s\n' "$run_id"
  exit 0
fi

# Default remaining counters to 0 (numeric) rather than failing — a caller
# that only knows command/board can still get a record with 0 counts, which
# is more useful for staleness detection than no record at all. (0/0/0/0 still
# reconciles, so the no-counter caller never trips the accounting check below.)
items_processed="${items_processed:-0}"
merged="${merged:-0}"
resolved="${resolved:-0}"
parked="${parked:-0}"
reported_no_op="${reported_no_op:-0}"

# epics_reviewed is the ACTIVATION signal for the whole epics_* extension
# (temperloop item "epic-closing-gate") — remember whether the caller passed
# it BEFORE defaulting it, since an omitted --epics-reviewed must leave all
# three fields OUT of the record entirely (purely additive), while a passed
# `--epics-reviewed 0` still activates the extension (and its accounting
# check) with a legitimate all-zero record.
epics_extension_active=0
[ -n "$epics_reviewed" ] && epics_extension_active=1
epics_reviewed="${epics_reviewed:-0}"
epics_closed="${epics_closed:-0}"
epics_left_open="${epics_left_open:-0}"

# A count that isn't a non-negative integer is an infrastructure-class caller
# error, not an accounting one: warn and emit nothing (exit 0). Previously jq
# would fail on the --argjson and produce the generic "failed to build JSON
# record" warning; naming the offending flag is strictly more useful.
check_count() {  # $1=flag $2=value → 0 ok, 1 malformed (already warned)
  case "$2" in
    ''|*[!0-9]*)
      printf '%s: WARN %s must be a non-negative integer, got "%s" — no record emitted (command=%s)\n' \
        "$self" "$1" "$2" "$command" >&2
      return 1 ;;
  esac
  return 0
}

check_count --items-processed "$items_processed" || exit 0
check_count --merged          "$merged"          || exit 0
check_count --resolved        "$resolved"        || exit 0
check_count --parked          "$parked"          || exit 0
check_count --reported-no-op  "$reported_no_op"  || exit 0
if [ "$epics_extension_active" -eq 1 ]; then
  check_count --epics-reviewed  "$epics_reviewed"  || exit 0
  check_count --epics-closed    "$epics_closed"    || exit 0
  check_count --epics-left-open "$epics_left_open" || exit 0
fi

# Normalise to base-10 so a zero-padded count ("08") is neither read as octal
# by $(( )) nor emitted as invalid JSON by jq --argjson.
items_processed=$((10#$items_processed))
merged=$((10#$merged))
resolved=$((10#$resolved))
parked=$((10#$parked))
reported_no_op=$((10#$reported_no_op))
epics_reviewed=$((10#$epics_reviewed))
epics_closed=$((10#$epics_closed))
epics_left_open=$((10#$epics_left_open))

# THE ACCOUNTING CHECK (temperloop#1084, extended #1103) — see the header.
# Computed BEFORE the emit so the failure message is ready, but acted on
# AFTER it so the record is never dropped over it.
disposition_total=$((merged + resolved + parked + reported_no_op))
reconciles=1
[ "$disposition_total" -eq "$items_processed" ] || reconciles=0

# THE EPICS-REVIEWED ACCOUNTING CHECK — a SEPARATE partition, active only
# when the caller passed --epics-reviewed (see the header note above).
# epics_closed + epics_left_open MUST equal epics_reviewed.
epics_reconciles=1
if [ "$epics_extension_active" -eq 1 ]; then
  epics_total=$((epics_closed + epics_left_open))
  [ "$epics_total" -eq "$epics_reviewed" ] || epics_reconciles=0
fi

ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
month="$(date -u +%Y-%m)"
now_epoch="$(date -u +%s)"
session_id="${CLAUDE_CODE_SESSION_ID:-}"
raw_file="$raw_dir/command-runs-${month}.jsonl"

mkdir -p "$raw_dir" 2>/dev/null || true

# RESOLVE THE RUN ID (temperloop#2220) — explicit flag, else this run's open
# marker, else a freshly minted one. The marker arm is what lets a caller
# park now and merge later in the SAME run without carrying the id between
# steps; the freshness bound is what stops a marker an earlier run abandoned
# from silently swallowing this one.
marker_opened_at=""
marker_opened_epoch=0
marker_emitted=0
marker_run_id=""
if [ -r "$marker_path" ]; then
  MK_RID=""; MK_EPOCH=0; MK_EMITTED=0
  read_marker "$marker_path" || true
  marker_run_id="$MK_RID"
  marker_opened_epoch="$MK_EPOCH"
  marker_emitted="$MK_EMITTED"
  marker_opened_at="$(jq -r '.opened_at // empty' "$marker_path" 2>/dev/null)" || marker_opened_at=""
fi

if [ -n "$run_id" ]; then
  : # explicit --run-id always wins
elif [ -n "$marker_run_id" ] && [ "$((now_epoch - marker_opened_epoch))" -le "$CMD_RUN_RUN_ID_TTL_SECS" ]; then
  run_id="$marker_run_id"
else
  run_id="$(mint_run_id)"
  marker_opened_at=""
  marker_opened_epoch=0
  marker_emitted=0
fi

[ -n "$marker_opened_at" ] || marker_opened_at="$ts"
[ "$marker_opened_epoch" -gt 0 ] || marker_opened_epoch="$now_epoch"

record="$(jq -nc \
  --arg ts "$ts" \
  --arg session_id "$session_id" \
  --arg run_id "$run_id" \
  --arg command "$command" \
  --arg board "$board" \
  --argjson items_processed "$items_processed" \
  --argjson merged "$merged" \
  --argjson resolved "$resolved" \
  --argjson parked "$parked" \
  --argjson reported_no_op "$reported_no_op" \
  --arg epic "$epic" \
  --argjson epics_extension_active "$epics_extension_active" \
  --argjson epics_reviewed "$epics_reviewed" \
  --argjson epics_closed "$epics_closed" \
  --argjson epics_left_open "$epics_left_open" \
  '{
    ts: $ts,
    session_id: (if $session_id == "" then null else $session_id end),
    run_id: $run_id,
    command: $command,
    board: (if $board == "" then null else ($board | tonumber? // $board) end),
    items_processed: $items_processed,
    merged: $merged,
    resolved: $resolved,
    parked: $parked,
    reported_no_op: $reported_no_op
  }
  + (if $epic == "" then {} else {epic: ($epic | tonumber? // $epic)} end)
  + (if $epics_extension_active == 1 then
       {epics_reviewed: $epics_reviewed, epics_closed: $epics_closed, epics_left_open: $epics_left_open}
     else {} end)' 2>/dev/null)"

if [ -z "$record" ]; then
  printf '%s: WARN failed to build JSON record (command=%s) — no record emitted\n' "$self" "$command" >&2
  exit 0
fi

if ! printf '%s\n' "$record" >> "$raw_file" 2>/dev/null; then
  printf '%s: WARN failed to append record to %s (command=%s)\n' "$self" "$raw_file" "$command" >&2
  exit 0
fi

printf '%s\n' "$record"

# HOLD OR CLOSE THE OPEN MARKER (temperloop#2220). A record that still
# reports a PARKED item is not necessarily the run's last word — the merge
# gate is exactly the park a later emit in the SAME run converges — so the
# marker is held (with `emitted` bumped, which is what tells the reconcile
# guard this run did emit). Nothing parked means the run reached a terminal
# disposition, so the marker is closed. Best-effort throughout: a ledger
# failure never touches the record already on disk, and never fails the emit.
if [ "$parked" -gt 0 ]; then
  write_marker "$run_id" "$marker_opened_at" "$marker_opened_epoch" "$((marker_emitted + 1))" || true
elif [ -n "$marker_run_id" ] && [ "$marker_run_id" = "$run_id" ]; then
  # CLOSE ONLY THE MARKER THIS EMIT ACTUALLY ADOPTED. An unconditional `rm`
  # here deleted whatever happened to sit on this ledger key — including a
  # marker this run never adopted, which is precisely the MISSING-RUN alarm:
  # an `emitted=0` marker aged past $CMD_RUN_RUN_ID_TTL_SECS (so a fresh id
  # was minted instead of adopting it), or a MALFORMED one carrying no
  # run_id at all (a hard MARKER-MALFORMED failure for the guard). Both were
  # erased before validate-command-run-reconcile.sh could ever read them,
  # contradicting this file's own twice-stated invariant that an emitted=0
  # marker is never removed at any age — and silently vaporising the MISSING
  # half of the property. prune_spent_markers() and `--open` already guard
  # this case; the close path was the one hole. An unadopted marker is left
  # exactly where it is: it belongs to some other run, and only its own run
  # (or prune_spent_markers, once it is spent) may retire it.
  rm -f "$marker_path" 2>/dev/null || true
fi

# The record is safely on disk; NOW fail loudly if the counts don't add up —
# either partition, independently (see the header's "SECOND, INDEPENDENT
# accounting check" note).
loud_fail=0

if [ "$reconciles" -ne 1 ]; then
  loud_fail=1
  printf '%s: FAIL disposition counts do not reconcile (command=%s): merged(%s) + resolved(%s) + parked(%s) + reported_no_op(%s) = %s, but --items-processed is %s.\n' \
    "$self" "$command" "$merged" "$resolved" "$parked" "$reported_no_op" "$disposition_total" "$items_processed" >&2
  printf '%s: every item a run drives must reach exactly one terminal disposition, so the four counts must partition the total. Either the caller miscounted, or the run produced an outcome this schema cannot express — in which case the fix is a new disposition field here, NOT a fudged total. Canonical shape: meta/data/raw/README.md (command-run stream).\n' \
    "$self" >&2
fi

if [ "$epics_reconciles" -ne 1 ]; then
  loud_fail=1
  printf '%s: FAIL epics_closed + epics_left_open == epics_reviewed does not reconcile (command=%s): epics_closed(%s) + epics_left_open(%s) = %s, but --epics-reviewed is %s.\n' \
    "$self" "$command" "$epics_closed" "$epics_left_open" "$epics_total" "$epics_reviewed" >&2
  printf '%s: every epic the closing gate reviewed must reach exactly one of closed / left-open, so the two counts must partition epics_reviewed — the same partition shape as the items_processed check above, but a SEPARATE population (epics, never Phase-2 pooled issues).\n' \
    "$self" >&2
fi

if [ "$loud_fail" -eq 1 ]; then
  printf '%s: the record above WAS appended to %s (the mismatch is preserved in the stream, not swallowed).\n' \
    "$self" "$raw_file" >&2
  exit 2
fi
