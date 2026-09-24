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
# absent / unreadable / empty, an unparseable stream, an unreadable marker,
# or a non-numeric $CMD_RUN_OPEN_GRACE_SECS are all exit 1; a set-but-EMPTY
# $CMD_RUN_RAW_DIR is exit 1 for the same reason. "Explicitly targeted"
# includes a flag whose operand is EMPTY (`--open-dir ""`, the shape a
# composed `--open-dir "$LEDGER"` produces when $LEDGER is unset): that is a
# USAGE error, exit 2, refused in the parser before any gate is reached — so
# no target can be both asserted and blank, and no check below can be skipped
# by emptiness.
#
# EVERY FLAG'S OPERAND IS VALIDATED AT PARSE TIME, AND EVERY GATE KEYS ON
# EXPLICITNESS. The two are one property: a flag recorded as "given" while
# carrying an empty path used to leave every later `[ -n "$path" ]` gate
# false, so the surface it named was never classified and its check never ran
# (`--open-dir ""` silently disabled the MISSING-RUN check while this guard
# still exited 0 — the fail-open class again, one level up from any single
# surface). Operands are therefore refused once, centrally, in the argument
# loop, and each gate below asks `*_explicit` / `*_set` — never `-n` on a
# path. A flag added later inherits both halves.
#
# EVERY DIRECTORY SURFACE GOES THROUGH ONE SHARED CLASSIFIER, `classify_dir`.
# This guard has two of them — the LAKE (`--raw-dir`, $CMD_RUN_RAW_DIR, or the
# per-host default) and the OPEN LEDGER (`--open-dir`, or the default
# `<lake>/command-run-open`) — and the SAME fail-open bug was written on each
# of them in turn, because each was classified by its own bespoke block. It is
# classified in exactly one place now, so a surface added later inherits the
# guard rather than repeating the bug a fourth time. The verdict is closed:
#   * a path that EXISTS but is NOT A DIRECTORY, and
#   * a directory this process cannot LIST (it needs BOTH `-r` and `-x`)
# fail closed on EVERY surface in EITHER mode; and
#   * a path that is simply ABSENT fails closed when it was named EXPLICITLY,
# and is handed back to the caller otherwise — that one state is the only one
# whose meaning differs per surface (a host that has not emitted yet, versus a
# ledger no run ever opened), so it is the only judgement a caller still makes.
# A lake named explicitly that holds no `command-runs-*.jsonl` fails closed on
# top of that. The explicit/default asymmetry is the same one `--stream`
# already implements: a caller who NAMES a target has asserted it exists, so
# an empty result set from it is an unread input, not a clean run.
#
# The ONE case that is legitimately exit 0 is DEFAULT mode — no `--raw-dir`,
# no $CMD_RUN_RAW_DIR — finding a present, readable lake directory (or no
# lake directory at all) with no `command-runs-*.jsonl` in it: the lake is
# per-host and gitignored, so "this host has not emitted yet" is a real,
# expected state and not a broken property.
#
# FIVE WAYS THIS GUARD ONCE FAILED **OPEN** — the five below are closed and
# regression-tested, because a reconciliation guard that cannot fail closed is
# strictly worse than no guard at all: it manufactures confidence.
#
# A SIXTH IS KNOWN AND STILL OPEN — temperloop#2247. Passing `--stream`
# alongside `--raw-dir`/$CMD_RUN_RAW_DIR skips the lake branch entirely, so an
# explicitly-targeted lake — even an absent one — is accepted, never classified
# and never read, and Check 1 (MISSING-RUN) never runs. So do NOT read the list
# below as "this guard can no longer fail open": read it as the five specific
# ways it has been shown to, and fixed. That distinction is deliberate. Five
# rounds each closed a site and then asserted completeness here, and every one
# of those assertions was falsified by the next review sweep; #2247 replaces
# the site-by-site approach with an enumerated invariant.
#
# Three of the five are ONE CLASS on three different surfaces, which is why the fourth
# fix was a shared classifier rather than a third bespoke patch — and the
# fifth is that same class one level ABOVE every surface, which is why its fix
# is in the parser rather than on a surface at all.
#   * A SPACED LAKE PATH. The file list was accumulated as a space-joined
#     string and expanded unquoted into `cat $stream_files`. A path containing
#     a space split into non-existent fragments, `cat`'s error went to
#     /dev/null, `jq -s` over EMPTY input produced a perfectly valid empty
#     report, and every check below passed vacuously — `ok — 0 record(s)`
#     over a lake that was never read. The list is now an indexed ARRAY handed
#     straight to `jq` (no `cat`), and jq's EXIT STATUS is kept and checked:
#     a read that FAILED is distinguishable from a read that found nothing,
#     which is this guard's entire job. Reachable from `--stream`,
#     `--raw-dir` and `$CMD_RUN_RAW_DIR` alike.
#   * A NON-NUMERIC GRACE WINDOW. `CMD_RUN_OPEN_GRACE_SECS=6h` made the
#     `[ … -ge "$…" ]` age test return 2, which the surrounding `|| continue`
#     read as an ordinary "no" — silently skipping the MISSING-RUN check for
#     every marker while still exiting 0. A malformed setting now FAILS the
#     guard loudly rather than disabling the half of it that the setting
#     bounds.
#   * AN UN-LISTABLE LAKE DIRECTORY. The first two were closed on the FILE
#     surface only; the DIRECTORY surface kept the same hole one level up.
#     `for f in "$raw_dir"/command-runs-*.jsonl` with `[ -f "$f" ] || continue`
#     cannot tell "directory readable, no files" from "directory unreadable /
#     absent / not a directory at all" — every one of them fell into the
#     `[ -z "$streams" ]` arm and printed the sanctioned exit-0 sentence. A
#     lake HOLDING A REAL RECORD, merely `chmod 000`, therefore asserted that
#     this host had emitted no telemetry and that there was no property to
#     break: a conclusion fabricated from a read that failed. The directory is
#     now CLASSIFIED BEFORE the glob (not-a-directory and unlistable both fail
#     closed in either mode), and an explicitly-named lake that is absent or
#     holds no matching file fails closed too — the same asymmetry `--stream`
#     already implements.
#   * AN UN-LISTABLE OPEN LEDGER. Pre-existing since this file's first commit,
#     and missed by all three of the reviews that closed the three above — the
#     tell that the CLASS, not any one surface, was the thing left open. The
#     `--open-dir` validation tested directory-ness ALONE (`[ ! -d ]`) while
#     its own message said "is not a readable directory", and Check 1's loop
#     was gated on a bare `[ -d ]`. A ledger that IS a directory but cannot be
#     LISTED made `for m in "$open_dir"/*.json` fail to expand, the
#     `[ -f "$m" ] || continue` swallowed the unexpanded pattern, the loop body
#     never ran, and `fail` stayed 0 — so an aged `emitted=0` MISSING-RUN alarm
#     sitting in that ledger became INVISIBLE and the guard printed its clean
#     reduction verdict straight over it. `--open-dir` is EXPLICIT targeting,
#     so by the asymmetry above it should have been the STRICTEST surface; it
#     was the laxest. And this is the MISSING half — the half this guard's
#     scope was widened to cover after one session produced seven runs and
#     zero records. Both surfaces now share `classify_dir`, and Check 1 runs
#     only over a ledger that classifier confirmed listable.
#   * AN EMPTY FLAG OPERAND — the same class ABOVE every surface, and the
#     reason the fix is in the parser. `--open-dir` recorded that the ledger
#     had been named EXPLICITLY but stored an empty path, while the gate that
#     decided whether to classify it asked `[ -n "$open_dir" ]` —
#     NON-EMPTINESS, not explicitness. So `--open-dir ""` skipped
#     `classify_dir` altogether: the strictest surface in this guard became
#     unreachable, Check 1 never ran, and an aged `emitted=0` MISSING-RUN
#     alarm went unread while the clean reduction verdict printed over it —
#     byte-identical to the bug above, on a path that never touches a
#     directory surface at all. `--raw-dir ""` was the same defect the other
#     way: an emptied operand silently re-targeted this host's DEFAULT lake
#     instead of failing closed, so a mistargeted probe reported on a lake the
#     caller never asked about. The trigger is not a typo but a composed
#     invocation — `--open-dir "$LEDGER"` with $LEDGER unset, the shape CI
#     wiring and `/tidy` produce. Fixed once, at the decision point: every
#     flag's operand must be present and non-empty (exit 2, a USAGE error),
#     and every gate keys on `*_explicit` / `*_set`.
#
# SETTINGS (named, never valued here — the kernel's § Named-setting
# convention; `workflows/scripts/config/setting-registry.tsv` records the
# defaults): $CMD_RUN_OPEN_GRACE_SECS bounds the MISSING-RUN check,
# $CMD_RUN_RAW_DIR selects the lake.
#
# Usage:
#   validate-command-run-reconcile.sh                  # this host's own lake
#   validate-command-run-reconcile.sh --reduce         # print the reduced runs
#   validate-command-run-reconcile.sh --stream <file> [--stream <file>…] \
#                                     [--open-dir <dir>]
#   validate-command-run-reconcile.sh --raw-dir <dir>  # a whole lake elsewhere
#
# Exit codes: 0 = property holds (or nothing emitted yet); 1 = property broken
#             or input could not be evaluated; 2 = USAGE — an unknown flag, or
#             a flag whose operand is missing or empty (refused in the parser,
#             before any input is read).
#
# Kept POSIX-bash-3.2-friendly (no mapfile/associative arrays) to match the
# rest of workflows/scripts/ (macOS dev shell + Linux CI).

set -uo pipefail

self="$(basename "$0")"
# BOTH resolutions carry a fallback. `here` used to have none while the very
# next line's did: an empty `here` made "$here/../.." resolve to `/`, and the
# `||` fallback on that line could then never fire because `cd -P /` succeeds.
here="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || here=""
[ -n "$here" ] || here="$(dirname "${BASH_SOURCE[0]}")"
[ -n "$here" ] || here="."
repo_root="$(cd -P "$here/../.." 2>/dev/null && pwd || echo "$HOME/dev/foundation")"

# How old an un-emitted open marker must be before it counts as a missing run
# rather than a run still in flight. A /fix run that parks at the merge gate
# and waits on an operator is legitimately long-lived, so this is generous.
: "${CMD_RUN_OPEN_GRACE_SECS:=21600}"

streams=""          # newline-separated; explicit --stream targets
streams_explicit=0
raw_dir=""
raw_dir_explicit=0
open_dir=""
open_dir_explicit=0  # --open-dir was given
open_dir_set=0       # …or the default <lake>/command-run-open was resolved
reduce_only=0

usage() {
  # Print the header comment block, however long it is — a hard-coded line
  # range silently truncates the usage text the next time the header grows.
  awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
}

# THE ONE PLACE AN OPERAND IS VALIDATED (the header's fifth "failed OPEN").
# Every value-taking flag routes through this, so a flag added later inherits
# the check instead of re-opening the class on a sixth surface. An operand
# that is MISSING (`--open-dir` at end of argv) and one that is EMPTY
# (`--open-dir ""`, what a composed `--open-dir "$LEDGER"` produces when
# $LEDGER is unset) are the SAME mistake and get the same refusal: the caller
# asserted a target and named none. Refusing here — before any input is read
# — is what lets every gate below key on explicitness rather than on a path
# being non-empty, which is how `--open-dir ""` once skipped the whole
# MISSING-RUN check while this guard still exited 0.
need_operand() {  # <flag> <operand-or-empty>
  if [ -z "${2:-}" ]; then
    printf '%s: FAIL USAGE — %s needs a non-empty operand (it was given none, or an empty string). A flag that NAMES a target asserts it exists, so an empty operand is a mistargeted probe, never a default: it would leave this run gated on a path that is both explicitly named and blank, silently skipping the check that path selects. Pass a real path, or drop the flag to take the default.\n' \
      "$self" "$1" >&2
    exit 2
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --stream)
      need_operand "$1" "${2:-}"
      streams="$streams$2
"; streams_explicit=1; shift 2 ;;
    --raw-dir)
      need_operand "$1" "${2:-}"
      raw_dir="$2"; raw_dir_explicit=1; shift 2 ;;
    --open-dir)
      need_operand "$1" "${2:-}"
      open_dir="$2"; open_dir_explicit=1; open_dir_set=1; shift 2 ;;
    --reduce)   reduce_only=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    *)
      printf '%s: FAIL USAGE — unknown argument %s.\n' "$self" "$1" >&2
      exit 2 ;;
  esac
done

if ! command -v jq >/dev/null 2>&1; then
  printf '%s: FAIL CANNOT EVALUATE — jq not found, so the stream cannot be parsed. Install jq; a reconciliation guard never reports OK over an input it could not read.\n' "$self" >&2
  exit 1
fi

# A malformed grace window is an EVALUATION failure, not a shrug. Left
# unchecked, `CMD_RUN_OPEN_GRACE_SECS=6h` makes the age comparison in Check 1
# return 2, which its `|| continue` reads as an ordinary "not yet old enough"
# — so the MISSING-RUN arm is skipped for EVERY marker and the guard still
# exits 0. That is the exact half of this property the item widened scope to
# cover, disabled by a plausible typo, silently. Same `case` shape the marker
# fields below and emit-command-run.sh's check_count() already use.
case "$CMD_RUN_OPEN_GRACE_SECS" in
  ''|*[!0-9]*)
    printf '%s: FAIL CANNOT EVALUATE — CMD_RUN_OPEN_GRACE_SECS must be a whole number of SECONDS, got "%s". A non-numeric value makes the age test below return an error that reads as "still in flight", silently disabling the MISSING-RUN check for every marker while this guard still exits 0. Set it to an integer (see workflows/scripts/config/setting-registry.tsv) or unset it to take the default.\n' \
      "$self" "$CMD_RUN_OPEN_GRACE_SECS" >&2
    exit 1 ;;
esac

# ── The SHARED directory classifier ──────────────────────────────────────
# ONE closed answer to "can this directory be LISTED?", used by EVERY
# directory surface this guard has, and inherited by any added later.
#
# WHY IT IS SHARED (the header's fourth "failed OPEN"). The identical
# fail-open was written three times on three surfaces and survived three
# review rounds: a bare `[ -d "$d" ]` (or `[ ! -d "$d" ]`) followed by a glob
# and a `[ -f "$x" ] || continue` folds four genuinely different states —
# listable, present-but-unlistable, absent, and not-a-directory — into ONE
# empty file list, and the caller's empty-list arm then prints something
# reassuring over a read that FAILED. Patching each surface as it was found is
# precisely how the class survived; it is closed here once, for all of them
# (kernel principle 5, counter AI failure modes structurally; principle 6,
# limit blast radius through boundaries).
#
# Usage:   classify_dir <path> <explicit 0|1> <what-it-is-for>
# Returns: 0  listable — the caller may glob it
#          1  a CLOSED failure; the message is already on stderr, the caller
#             exits 1 without deciding anything
#          2  absent AND not explicitly named — SILENT, and the only state
#             handed back to the caller, because it is the only one whose
#             meaning differs per surface. Every other state fails on every
#             surface, so no caller can get it wrong.
classify_dir() {
  # `local` so a shared helper cannot leak its parameters into the caller's
  # scope and collide with a variable added later (bash 3.2 supports it).
  local cd_path cd_explicit cd_what
  cd_path="$1"; cd_explicit="$2"; cd_what="$3"
  if [ -e "$cd_path" ] && [ ! -d "$cd_path" ]; then
    printf '%s: FAIL CANNOT EVALUATE — %s is not a directory, so the %s it names can never be listed. An unlistable directory is an unread input, never an empty one.\n' \
      "$self" "$cd_path" "$cd_what" >&2
    return 1
  fi
  if [ -d "$cd_path" ]; then
    if [ ! -r "$cd_path" ] || [ ! -x "$cd_path" ]; then
      printf '%s: FAIL CANNOT EVALUATE — %s is not a readable, searchable directory (listing one needs BOTH r and x), so this %s is indistinguishable from one that is genuinely empty. Fix its permissions; a reconciliation guard never reports a clean verdict over a directory it could not open.\n' \
        "$self" "$cd_path" "$cd_what" >&2
      return 1
    fi
    return 0
  fi
  if [ "$cd_explicit" -eq 1 ]; then
    printf '%s: FAIL CANNOT EVALUATE — the %s %s was named EXPLICITLY but does not exist. A named target that is absent is a mistargeted probe, not a clean run.\n' \
      "$self" "$cd_what" "$cd_path" >&2
    return 1
  fi
  return 2
}

# ── Resolve the inputs ───────────────────────────────────────────────────
# EXPLICITNESS IS A PARSE-TIME FACT, never re-derived from a path being
# non-empty. `$streams_explicit` / `$raw_dir_explicit` / `$open_dir_explicit`
# are set where the flag was READ; every gate below reads those flags. The
# superseded `[ -n "$path" ]` form conflated "not given" with "given empty",
# which is exactly how an empty operand disabled a whole check.
if [ "$streams_explicit" -eq 0 ]; then
  # Was the lake NAMED, or defaulted? The distinction is the whole basis of
  # the fail-closed asymmetry below: a caller who names a lake has asserted it
  # exists, exactly as `--stream` and `--open-dir` already treat their targets.
  if [ "$raw_dir_explicit" -eq 1 ]; then
    :                                        # --raw-dir <dir>, validated at parse time
  elif [ "${CMD_RUN_RAW_DIR+set}" = set ]; then
    # A SET-BUT-EMPTY setting is the env-var twin of an empty flag operand —
    # `CMD_RUN_RAW_DIR="$LAKE"` with $LAKE unset — and silently falling back
    # to this host's default lake would report on a lake the caller never
    # asked about. It is a setting, not a flag, so it fails as CANNOT
    # EVALUATE (exit 1) rather than as a usage error.
    if [ -z "$CMD_RUN_RAW_DIR" ]; then
      printf '%s: FAIL CANNOT EVALUATE — CMD_RUN_RAW_DIR is set but EMPTY, so the lake it selects is named and blank at once. Falling back to this host'"'"'s default lake here would report a clean verdict over a lake the caller never asked about. Set it to a real path, or unset it to take the default.\n' "$self" >&2
      exit 1
    fi
    raw_dir="$CMD_RUN_RAW_DIR"               # $CMD_RUN_RAW_DIR
    raw_dir_explicit=1
  else
    raw_dir="$repo_root/meta/data/raw"       # the default, per-host lake
  fi

  # CLASSIFY THE DIRECTORY BEFORE GLOBBING IT — through the SHARED classifier
  # above, never a block of its own. The glob below plus `[ -f "$f" ] ||
  # continue` collapses four very different states into one empty file list —
  # listable-but-empty, unlistable, absent, and not-a-directory — and the
  # empty-list arm prints the sanctioned exit-0 sentence over ALL of them. A
  # lake that holds a real record but is `chmod 000` then asserts this host
  # emitted nothing: a conclusion fabricated from a read that failed. Only
  # rc=2 (absent, and NOT explicitly named) comes back for this surface to
  # judge, and its judgement is the documented exit-0 case below.
  # ONE $?-READING IDIOM, used identically at BOTH call sites: capture the
  # status into `classify_rc` on the line straight after the call, then branch
  # on the VARIABLE. `$?` is whatever ran last, so reading it inline is
  # position-fragile — inserting one line between the call and the test (a
  # `printf`, a debug `echo`) silently re-points it at that line's status.
  classify_dir "$raw_dir" "$raw_dir_explicit" \
    "command-run lake (--raw-dir, the CMD_RUN_RAW_DIR setting, or this host's default)"
  classify_rc=$?
  case "$classify_rc" in
    1) exit 1 ;;
  esac

  for f in "$raw_dir"/command-runs-*.jsonl; do
    [ -f "$f" ] || continue
    streams="$streams$f
"
  done
  if [ -z "$streams" ]; then
    if [ "$raw_dir_explicit" -eq 1 ]; then
      printf '%s: FAIL CANNOT EVALUATE — no command-runs-*.jsonl under %s, which was named explicitly (--raw-dir, or the CMD_RUN_RAW_DIR setting). The caller asserted this lake; an empty result set from it is an unread input, not a clean run. (Only DEFAULT mode treats an empty lake as "this host has emitted nothing yet".)\n' "$self" "$raw_dir" >&2
      exit 1
    fi
    printf '%s: ok — no command-runs-*.jsonl under %s; this host has emitted no command-run telemetry yet, so there is no reconciliation property to break.\n' "$self" "$raw_dir"
    exit 0
  fi
  if [ "$open_dir_explicit" -eq 0 ]; then
    open_dir="$raw_dir/command-run-open"     # the default ledger beside the lake
  fi
  open_dir_set=1
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

# THE OPEN LEDGER, through the SAME classifier (the header's fourth "failed
# OPEN"). This surface used to test directory-ness ALONE while claiming to
# test readability, so a ledger that could not be LISTED hid every marker in
# it — including the aged `emitted=0` markers that ARE the MISSING-RUN alarm.
# The classifier's verdict is also what gates Check 1 below: the loop runs
# ONLY over a ledger this process confirmed it can list, never over a bare
# `[ -d ]` that a chmod-000 directory satisfies.
#
# THE GATE KEYS ON `$open_dir_set`, NOT ON `[ -n "$open_dir" ]` (the header's
# fifth "failed OPEN"). `--open-dir ""` set the explicit flag and left the
# path blank, so the old non-emptiness gate was false, this classifier never
# ran, and Check 1 was skipped over a ledger the caller had explicitly named.
# The parser now refuses an empty operand outright, and this gate asks the
# parse-time fact instead of re-deriving it from the path.
open_dir_listable=0
if [ "$open_dir_set" -eq 1 ]; then
  classify_dir "$open_dir" "$open_dir_explicit" \
    "open ledger (--open-dir, or the default <lake>/command-run-open)"
  classify_rc=$?
  case "$classify_rc" in
    0) open_dir_listable=1 ;;
    1) exit 1 ;;
  esac
fi

# ── Reduce ───────────────────────────────────────────────────────────────
# An indexed ARRAY, never a space-joined string (see the header's "TWO WAYS
# THIS GUARD ONCE FAILED OPEN"). bash-3.2 safe: `+=` on an indexed array is
# 3.1+, and the array is proven non-empty before it is ever expanded, so no
# empty-expansion abort under `set -u`.
stream_files=()
while IFS= read -r f; do
  [ -n "$f" ] || continue
  stream_files+=("$f")
done <<EOF
$streams
EOF

if [ "${#stream_files[@]}" -eq 0 ]; then
  printf '%s: FAIL CANNOT EVALUATE — the resolved stream list is empty, so nothing was read. A guard that reduces zero files reports "ok" over a lake it never opened.\n' "$self" >&2
  exit 1
fi

stream_list="$(printf '%s ' "${stream_files[@]}")"
stream_list="${stream_list% }"

# jq OPENS THE FILES ITSELF — no `cat`, nothing word-split, and a parse error
# names the offending file. Its stderr is captured rather than discarded and
# its EXIT STATUS is kept: a read that FAILED must be distinguishable from a
# read that found nothing.
jq_err=""
jq_err="$(mktemp "${TMPDIR:-/tmp}/command-run-reconcile.XXXXXX" 2>/dev/null)" || jq_err=""
report="$(jq -s -c '
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
    }' "${stream_files[@]}" 2>"${jq_err:-/dev/null}")"
jq_rc=$?

jq_msg=""
if [ -n "$jq_err" ]; then
  jq_msg="$(tr '\n' ' ' < "$jq_err" 2>/dev/null | sed 's/  */ /g; s/ *$//')"
  rm -f "$jq_err" 2>/dev/null || true
fi

if [ "$jq_rc" -ne 0 ] || [ -z "$report" ]; then
  printf '%s: FAIL CANNOT EVALUATE — the command-run stream could not be READ or parsed (jq exit %s over: %s)%s. An unread input is never a clean one — a lake path this guard cannot open must fail CLOSED here, not reduce to an empty report.\n' \
    "$self" "$jq_rc" "$stream_list" "${jq_msg:+ — jq said: $jq_msg}" >&2
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
if [ "$open_dir_listable" -eq 1 ]; then
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
    m_tgt="$(jq -r '.target // "-"' "$m" 2>/dev/null)" || m_tgt="-"
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
    # A COUNT THAT IS NOT A NUMBER READS AS ZERO, i.e. "no record found", so
    # the arm below still fires. Bare `[ "$seen" -eq 0 ]` on an empty or
    # non-numeric $seen exits 2, which `if` reads as FALSE — skipping the
    # MISSING-RUN report for that marker while the guard still exits 0. Same
    # fail-open shape as the *_SECS comparison above; same `case` guard as
    # every other numeric read in this loop.
    case "$seen" in ''|*[!0-9]*) seen=0 ;; esac
    if [ "$m_emitted" -eq 0 ] || [ "$seen" -eq 0 ]; then
      printf 'FAIL  MISSING-RUN  run_id=%s command=%s target=%s opened_at=%s — this run opened and never produced a reducible record (emitted=%s, records in stream=%s). The run happened; the terminal emit did not. Call emit-command-run.sh at EVERY terminal route of /%s — passing the SAME --target the --open call used, or the terminal emit cannot find this marker to adopt — then remove %s.\n' \
        "$m_rid" "$m_cmd" "$m_tgt" "$m_at" "$m_emitted" "$seen" "$m_cmd" "$m"
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
