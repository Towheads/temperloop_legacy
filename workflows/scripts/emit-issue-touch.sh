#!/usr/bin/env bash
#
# emit-issue-touch.sh — append one record to the append-only issue-touches
# raw-lake stream, recording a `pr-open` or `merge` work-touch on an issue
# (foundation #916/#919, epic #916 "issue-touch-stream"). Sibling to
# emit-command-run.sh: same structure and arg style. Its lake dir, unlike that
# sibling's, is NOT re-derived here — on the DEFAULT path it comes from
# board/lib/raw_lake.sh, the single owner this stream's other writer
# (board/capture.sh) consumes too (temperloop#1902). The ISSUE_TOUCHES_RAW_DIR
# override short-circuits that lookup entirely: an override that is set needs
# no resolution, so it is honored even where board/lib/ is absent.
#
# WHY THIS EXISTS: build.md's Step 3f (PR opened) and Step 4d (PR confirmed
# MERGED) are the only places those two touches happen for a plan item — but,
# like /sweep and /triage before emit-command-run.sh existed, a prose
# orchestrator step can silently rot (an LLM-executed markdown instruction
# gets skipped or paraphrased away and nobody notices, because the failure
# mode is an ABSENT record, not an error). This script is the mechanical fix:
# a concrete, invocable emit, backed by a presence-lint
# (workflows/scripts/validate-issue-touch-emit.sh, wired into
# scripts/quality-gates.sh) that fails CI if this script disappears OR its
# calls are removed from claude/commands/build.md's 3f/4d steps.
#
# Claim touches are DELIBERATELY NOT emitted by this script — the existing
# claims-<YYYY-MM>.jsonl stream (scripts/board/claim.sh's claim_log_emit)
# already covers them and is unioned at read time with this stream. Capture
# touches are likewise emitted separately, by scripts/board/capture.sh's own
# issue_touch_log_emit (same record shape, `kind:"capture"`), not by this
# script — this script only ever emits `kind` in {pr-open, merge, review-round}.
#
# `review-round` (temperloop#2131) is the THIRD kind this script emits: one
# record per §3e review round an item spent, written by
# claude/workflows/build-level.mjs at 3h (see its emitReviewRounds()). It rides
# THIS stream rather than a new one on purpose — rounds-to-merge is a join
# against the very pr-open/merge touches already here, so a rollup needs one
# file and no GitHub call. Extending this script was likewise the point rather
# than forking a sibling emitter: before temperloop#2131 the `kind` case below
# matched only `pr-open|merge` and WARNed-then-exited-0 on anything else, so an
# unextended script would have dropped every review-round record SILENTLY, on a
# SUCCESS exit — the exact absent-record failure this whole stream exists to
# prevent. The case arm, the usage line and the invariant sentence above are
# therefore one change, never three.
#
# Usage:
#   emit-issue-touch.sh --repo <owner/repo> --issue <N> --kind pr-open|merge
#   emit-issue-touch.sh --repo <owner/repo> --issue <N> --kind review-round \
#     [--round <N>] [--round-kind <k>] [--pr <N>] [--sha <hex>] \
#     [--wall-ms <N>] [--tokens <N>] [--reviewers <json-array>]
#
# The seven per-round flags are accepted ONLY as `review-round` detail; they are
# ignored (with a WARN) on a pr-open/merge record, whose shape is unchanged.
#
# Appends ONE JSONL line to:
#   ${ISSUE_TOUCHES_RAW_DIR:-$(raw_lake_dir)}/issue-touches-YYYY-MM.jsonl
# — evaluated in that order, so raw_lake_dir() is reached ONLY when the
# override is unset. raw_lake_dir() is board/lib/raw_lake.sh's shared resolver
# — the single owner of the lake dir, shared with this stream's other writer,
# capture.sh (temperloop#1902) — resolving to <that checkout>/meta/data/raw
# (monthly rotation, matching the claims-YYYY-MM.jsonl / command-runs-YYYY-MM
# convention already used in meta/data/raw/).
#
# canonical sink spec: meta/data/raw/README.md (lake path + schema-version
# convention; this stream's own record shape is documented below).
#
# Record shape: {schema_version, ts, repo, issue, session_id, host, kind}
#   schema_version   "1" (string) — bump on a breaking shape change
#   ts               ISO-8601 UTC, `Z` suffix (matches the raw/ stream convention)
#   repo             "owner/repo" the issue lives in, verbatim from --repo
#   issue            integer issue number, verbatim from --issue
#   session_id       the RAW $CLAUDE_CODE_SESSION_ID (full value, UNTRUNCATED),
#                     null when unset — same join-key convention as
#                     emit-command-run.sh and claim.sh's claim_log_emit
#                     (deliberately NOT the truncated host:sess8 board stamp)
#   host             $SUBSET_HOST_LABEL if set, else `hostname -s` — same
#                     derivation as scripts/board/claim.sh's claim_main
#   kind             "pr-open" | "merge" | "review-round" (verbatim from
#                     --kind; a `capture` record is emitted by capture.sh
#                     itself, never here)
#
# Additional fields, present ONLY on a `kind:"review-round"` record
# (temperloop#2131) — a pr-open/merge record carries none of them, so every
# pre-existing consumer reads byte-identical lines:
#   round            integer round ordinal (the worktree's DURABLE
#                     build-review-rounds counter, so a continuation round
#                     reports 3, not 1), null when not supplied/unparseable
#   round_kind       the round's bucket in build-level.mjs's
#                     escalationRoundKind() vocabulary (temperloop#2135) —
#                     one of review | gate-timeout | gate-fail | activation |
#                     ci | other. THAT function is the one place the mapping is
#                     stated; this script only validates membership and never
#                     re-derives a kind, so the two cannot drift. An
#                     unrecognised value is recorded as "other".
#   pr               integer PR number the round belongs to, null when absent
#   sha              the commit the round reviewed (7-64 hex), null otherwise
#   wall_ms          the round's measured wall-clock in ms, null when unknown
#   tokens           the round's token cost, null when unknown — and it IS
#                     null today by construction: the Workflow runtime's
#                     agent() returns no usage envelope, the same honest
#                     degrade worker-usage.sh documents. Never a guess.
#   reviewers        JSON array of {name, model, highs, mediums, lows} — one
#                     entry per reviewer that RAN in the round. `model` is the
#                     RESOLVED model that reviewer ran as, self-reported by the
#                     reviewer itself, NOT the seat file's declared value: a
#                     seat declaring `model: inherit` resolves per session, so
#                     the declared string cannot answer "what actually reviewed
#                     this". Unknown reads null, never the declared value.
#                     Defaults to [] when absent or not parseable as an array.
#
# WARN, DON'T DROP: any failure here (bad args, jq missing, sink unwritable,
# disk full) warns to stderr and exits 0. A telemetry emit must never fail or
# block the calling orchestrator step (build.md 3f/4d) — see the `|| true`-safe
# contract in the epic #724 Contract (the same contract emit-command-run.sh
# follows).
#
# Kept POSIX-bash-3.2-friendly (no mapfile/associative arrays) to match the
# rest of workflows/scripts/ (macOS dev shell + Linux CI).

set -uo pipefail

self="$(basename "$0")"

repo=""
issue=""
kind=""
# temperloop#2131 — the `review-round` detail flags. All optional, all empty by
# default, all serialized ONLY under that kind (see the record builder below).
round=""
round_kind=""
pr=""
sha=""
wall_ms=""
tokens=""
reviewers=""

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
    --repo) repo="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
    --issue) issue="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
    --kind) kind="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
    # temperloop#2131 review-round detail. Every arm uses the SAME two-step
    # shift the three arms above use, for the same reason the ARG LOOP comment
    # gives: a `shift 2` on a trailing flag fails, does not shift, and spins.
    --round) round="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
    --round-kind) round_kind="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
    --pr) pr="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
    --sha) sha="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
    --wall-ms) wall_ms="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
    --tokens) tokens="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
    --reviewers) reviewers="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
    *)
      printf '%s: WARN unknown argument %s (ignored)\n' "$self" "$1" >&2
      shift
      ;;
  esac
done

if [ -z "$repo" ] || [ -z "$issue" ] || [ -z "$kind" ]; then
  printf '%s: WARN --repo, --issue, and --kind are all required — no record emitted\n' "$self" >&2
  exit 0
fi

case "$issue" in
  ''|*[!0-9]*)
    printf '%s: WARN --issue must be a number, got %s — no record emitted\n' "$self" "$issue" >&2
    exit 0
    ;;
esac

case "$kind" in
  pr-open|merge|review-round) : ;;
  *)
    printf '%s: WARN --kind must be pr-open, merge or review-round, got %s — no record emitted\n' "$self" "$kind" >&2
    exit 0
    ;;
esac

# --- temperloop#2131: normalise the review-round detail ----------------------
# Every field VALIDATES to a known shape or degrades to the JSON null the record
# builder below emits — never to a plausible-but-wrong value. Same reasoning as
# build-level.mjs's own marker reads: a filter that merely strips bad bytes
# yields something well-shaped and false, which is worse than an honest gap.
if [ "$kind" = "review-round" ]; then
  for _f in round pr wall_ms tokens; do
    _v="${!_f}"
    case "$_v" in
      '') : ;;
      *[!0-9]*)
        printf '%s: WARN --%s must be a number, got %s — recording null for it\n' "$self" "$_f" "$_v" >&2
        printf -v "$_f" '%s' ''
        ;;
    esac
  done
  case "$round_kind" in
    ''|review|gate-timeout|gate-fail|activation|ci|other) : ;;
    *)
      printf '%s: WARN --round-kind %s is outside the closed vocabulary — recording "other"\n' "$self" "$round_kind" >&2
      round_kind="other"
      ;;
  esac
  # 7-64 hex, the same floor build-level.mjs applies to a relayed sha: 7 is
  # git's own minimum abbreviation length, and anything shorter is residue.
  if [ -n "$sha" ]; then
    case "$sha" in
      *[!0-9a-fA-F]*) _sha_ok="" ;;
      *) _sha_ok="1" ;;
    esac
    if [ -n "$_sha_ok" ] && [ "${#sha}" -ge 7 ] && [ "${#sha}" -le 64 ]; then
      :
    else
      printf '%s: WARN --sha %s is not a 7-64 char hex commit — recording null for it\n' "$self" "$sha" >&2
      sha=""
    fi
  fi
else
  # The detail flags are meaningless on a pr-open/merge record; say so rather
  # than serialising them, so that record shape stays byte-identical for every
  # consumer that predates this kind.
  if [ -n "$round$round_kind$pr$sha$wall_ms$tokens$reviewers" ]; then
    printf '%s: WARN review-round detail flags ignored on --kind %s\n' "$self" "$kind" >&2
  fi
fi

if ! command -v jq >/dev/null 2>&1; then
  printf '%s: WARN jq not found — no record emitted (repo=%s issue=%s kind=%s)\n' "$self" "$repo" "$issue" "$kind" >&2
  exit 0
fi

ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
month="$(date -u +%Y-%m)"
session_id="${CLAUDE_CODE_SESSION_ID:-}"
host="${SUBSET_HOST_LABEL:-$(hostname -s)}"

# Resolve the raw sink dir. ORDER MATTERS, and the override comes FIRST: when
# ISSUE_TOUCHES_RAW_DIR is set the caller has already answered the question, so
# nothing needs resolving and the shared resolver need not be present at all.
# Putting the resolver-presence guard ahead of the override instead would let a
# missing board/lib/ subtree drop a record the caller had fully specified the
# sink for — and because build.md's 3f/4d invoke this script as
# `emit-issue-touch.sh … || true`, a WARN-and-exit-0 is indistinguishable from
# success at the call site and surfaces only as an ABSENT record, which is the
# exact failure this whole stream exists to prevent. It would also invert
# raw_lake.sh's own contract: that library owns the DEFAULT's value, never the
# per-stream override seam (workflows/scripts/config/setting-registry.tsv).
#
# Only the DEFAULT path reaches for board/lib/raw_lake.sh's raw_lake_dir()
# (temperloop#1902), the SINGLE OWNER of that path — the same resolver this
# stream's other writer (board/capture.sh's ISSUE_TOUCHES_RAW_DIR_DEFAULT)
# consumes. This script used to re-derive the directory itself with a fixed
# `../..` hop while capture.sh derived it from its own git toplevel — two
# derivations of one path, which is one path that can tear. Both writers now
# consume the one resolver, so the stream cannot split by writer identity and a
# future fix lands in one place.
raw_dir="${ISSUE_TOUCHES_RAW_DIR:-}"
if [ -z "$raw_dir" ]; then
  # Locate the library relative to THIS file, resolving symlinks first (the
  # same portable loop board/claim.sh uses, no GNU `readlink -f`) so an
  # installed-on-PATH symlink still finds its SOURCE checkout's library — and,
  # through it, that checkout's own lake. The loop is BOUNDED: a symlink cycle
  # (a -> b -> a) keeps `[ -L ]` true forever, and a hang here is strictly
  # worse than the failure this file's never-fail-or-block-the-spawn-site
  # contract exists to prevent — the conventional `emit-… || true` call shape
  # cannot save a caller from it (the same reasoning as the ARG LOOP above,
  # temperloop#1342). On hitting the bound we stop resolving; the presence
  # check below then turns an unresolvable chain into a WARN, never a spin.
  here="${BASH_SOURCE[0]:-$0}"
  _hops=0
  while [ -L "$here" ] && [ "$_hops" -lt 40 ]; do
    _d="$(cd -P "$(dirname "$here")" 2>/dev/null && pwd)" || _d=""
    here="$(readlink "$here" 2>/dev/null)" || here=""
    case "$here" in /*) ;; *) here="${_d:-.}/$here" ;; esac
    _hops=$((_hops + 1))
  done
  here="$(cd -P "$(dirname "$here")" 2>/dev/null && pwd)" || here=""
  if [ -z "$here" ] || [ ! -r "$here/board/lib/raw_lake.sh" ]; then
    printf '%s: WARN raw-lake resolver not found at %s — no record emitted (repo=%s issue=%s kind=%s); set ISSUE_TOUCHES_RAW_DIR to name the sink directly\n' \
      "$self" "${here:-?}/board/lib/raw_lake.sh" "$repo" "$issue" "$kind" >&2
    exit 0
  fi
  # shellcheck source=board/lib/raw_lake.sh
  # shellcheck disable=SC1091
  source "$here/board/lib/raw_lake.sh"
  raw_dir="$(raw_lake_dir)"
fi
raw_file="$raw_dir/issue-touches-${month}.jsonl"

mkdir -p "$raw_dir" 2>/dev/null || true

# temperloop#2131 — `reviewers` is the one field that arrives as JSON rather
# than a scalar, so it is PARSED before the record is built and falls back to
# `[]` when it is absent, malformed, or not an array. Parsing it here (rather
# than passing it to --argjson and letting a malformed value fail the whole jq
# invocation) keeps the fail-open contract: a garbled reviewers list costs the
# reviewer detail, never the record.
reviewers_json="[]"
if [ "$kind" = "review-round" ] && [ -n "$reviewers" ]; then
  if _parsed="$(printf '%s' "$reviewers" | jq -c 'if type == "array" then . else error("not an array") end' 2>/dev/null)" \
     && [ -n "$_parsed" ]; then
    reviewers_json="$_parsed"
  else
    printf '%s: WARN --reviewers is not a JSON array — recording [] (repo=%s issue=%s)\n' "$self" "$repo" "$issue" >&2
  fi
fi

# The base record is IDENTICAL to the pre-temperloop#2131 shape; the
# review-round detail is merged on top only for that kind, so a pr-open/merge
# line is byte-for-byte what it always was.
record="$(jq -nc \
  --arg ts "$ts" \
  --arg repo "$repo" \
  --argjson issue "$issue" \
  --arg session_id "$session_id" \
  --arg host "$host" \
  --arg kind "$kind" \
  --arg round "$round" \
  --arg round_kind "$round_kind" \
  --arg pr "$pr" \
  --arg sha "$sha" \
  --arg wall_ms "$wall_ms" \
  --arg tokens "$tokens" \
  --argjson reviewers "$reviewers_json" \
  '
    def num($s): if $s == "" then null else ($s | tonumber? // null) end;
    {
      schema_version: "1",
      ts: $ts,
      repo: $repo,
      issue: $issue,
      session_id: (if $session_id == "" then null else $session_id end),
      host: $host,
      kind: $kind
    }
    + (if $kind == "review-round" then {
        round: num($round),
        round_kind: (if $round_kind == "" then "other" else $round_kind end),
        pr: num($pr),
        sha: (if $sha == "" then null else $sha end),
        wall_ms: num($wall_ms),
        tokens: num($tokens),
        reviewers: $reviewers
      } else {} end)
  ' 2>/dev/null)"

if [ -z "$record" ]; then
  printf '%s: WARN failed to build JSON record (repo=%s issue=%s kind=%s) — no record emitted\n' "$self" "$repo" "$issue" "$kind" >&2
  exit 0
fi

if ! printf '%s\n' "$record" >> "$raw_file" 2>/dev/null; then
  printf '%s: WARN failed to append record to %s (repo=%s issue=%s kind=%s)\n' "$self" "$raw_file" "$repo" "$issue" "$kind" >&2
  exit 0
fi

printf '%s\n' "$record"
