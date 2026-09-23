#!/usr/bin/env bash
#
# dual-build-preflight.sh — the dual-build harness's orchestrator-side spend
# gate (temperloop#2079, epic #2065 "new-work dual-build harness", design
# dimension 4 #6 / D10). Called by `build.md`'s `--dual-build <tier>=<candidate>`
# Step 0/1 BEFORE the dual-build workflow is invoked: it resolves which of a
# level's plan items are in scope for the named tier, projects the level's
# 2x-worker + judge spend against the REPLAY harness's own shared ceiling
# (REPLAY_PREFLIGHT_CEILING_TOKENS), checks the candidate's provider actually
# has a usable credential, and — only when none of that refuses — emits the
# `dualBuild` workflow-input JSON (`claude/plan-schema.md`'s shared seam, per
# this epic's plan note § Sequencing notes) plus a cumulative-spend line for
# the consent prompt and the on-demand report alike.
#
#   dual-build-preflight.sh --tier <tier> --items-file <path|-> \
#       --baseline <model> --candidate <model> \
#       [--judge-model <id>] [--provider <name>] [--execution live|recorded]
#
#   --tier         the plan `model:` tier under test (e.g. "sonnet").
#   --items-file   a JSON array of the LEVEL's plan items, each
#                  `{"slug":"...","model":"..."}` — "-" reads stdin. This is
#                  a plain array, not a full plan note: the orchestrator
#                  (build.md) resolves the level's items from the plan note
#                  itself (plan.sh's own job) and hands this script only the
#                  two fields it needs per item.
#   --baseline     the tier's own current model (the arm NOT under test).
#   --candidate    the candidate model under test.
#   --judge-model  OPTIONAL (temperloop#2203) — the model the PAIRWISE JUDGE
#                  itself runs on for this run, and this run only. Omitted
#                  (the default) the field is null, the emitted `dualBuild`
#                  object carries NO `judgeModel` key at all, and
#                  `build-level.mjs` invokes `judge.sh pairwise` with the
#                  byte-identical command it emitted before this flag
#                  existed — judge.sh then resolves its own
#                  MODEL_COMPARISON_JUDGE_MODEL default. Given, the value
#                  rides the emitted object through to `judge.sh pairwise
#                  --model <id>`, and is named on `cumulative_spend_line`
#                  so the consent prompt discloses WHICH instrument is
#                  about to read the two arms. Per-invocation by design:
#                  the alternative — editing build.config.sh or a
#                  machine-local override — changes the judge for every
#                  other run on the host and outlives this one. An empty
#                  value is refused (CANNOT_EVALUATE), never silently
#                  treated as absent.
#   --provider     the CANDIDATE's provider name, as registered in
#                  candidate-session.sh's `_CS_PROVIDER_TABLE` (default:
#                  "anthropic", candidate-session.sh's own `_CS_DEFAULT_
#                  PROVIDER` — duplicated here because candidate-session.sh
#                  is invoked as a subprocess, never sourced (its own CLI
#                  dispatch runs unconditionally on `source`), so its
#                  internal constant is not reachable; a documented
#                  duplicate held honest by candidate-session.sh's own
#                  header table, the same pattern the model-comparison
#                  module already uses for its cost_basis string).
#   --execution    live|recorded (default: live), forwarded verbatim to
#                  candidate-session.sh's own `preflight --execution` flag.
#                  "recorded" is a TEST SEAM ONLY — it is what a fixture
#                  passes to exercise the credential-refusal path
#                  hermetically (no network, no runner requirement); real
#                  orchestrator usage never needs anything but the "live"
#                  default, since a dual-built level always ends in a real
#                  candidate spawn.
#
# ── SETTINGS THIS SCRIPT CONSUMES, NEVER DECLARES ────────────────────────────
# REPLAY_PREFLIGHT_CEILING_TOKENS and REPLAY_PREFLIGHT_TOKENS_PER_REPLAY are
# the REPLAY harness's own settings (workflows/scripts/build/build.config.sh,
# registered in workflows/scripts/config/setting-registry.tsv) — this script
# sources build.config.sh and reads them, exactly as
# workflows/scripts/model-comparison/replay.sh's own `preflight` does; it
# does not mint a second, dual-build-specific ceiling (design dimension 6:
# "the same ceiling the replay harness's own pre-flight shares, not a
# dual-build-specific one").
#
# DUAL_BUILD_MIN_INSCOPE_ITEMS is a genuinely NEW dual-build setting, but
# this item (temperloop#2079) does NOT declare it — the epic's plan note
# names `dual-build-settings` (temperloop#2071) as "the epic's only L0 item
# touching build.config.sh, by design, so a later item stacks on this
# commit rather than adding a competing definition of the same setting
# name" (that commit's own message). This item and that one are sibling,
# file-disjoint L0 items with no depends-on between them, so this script
# never writes a matching `${DUAL_BUILD_MIN_INSCOPE_ITEMS:=...}` fallback of
# its own — doing so would be exactly the "competing definition" that note
# warns against AND would trip check-setting-registry.sh's UNREGISTERED
# sweep in isolation (a `:=`/`:-` seam for an ALL-CAPS name not yet present
# in setting-registry.tsv in THIS branch's tree). Instead this script reads
# the bare variable and, like REPLAY_PREFLIGHT_CEILING_TOKENS above,
# CANNOT_EVALUATEs by name if it is unset or not a non-negative integer —
# which is also the correct behavior for a genuinely fresh checkout that
# has never sourced dual-build-settings' commit (temperloop#2071 landing
# via the merge queue is what makes this var reliably present in
# production; a caller/test that needs it before that merge exports it
# directly, the highest-precedence layer per build.config.sh's own ladder).
#
# ── OUTPUT — ONE JSON LINE, CLOSED OUTCOME SET ───────────────────────────────
#   {"outcome":"CANNOT_EVALUATE","error":<msg>}   exit 1 (this script's own
#     documented CANNOT_EVALUATE code — matching every sibling model-
#     comparison script's convention; RC_CANNOT_EVALUATE=2 is the shared
#     LIBRARY FUNCTION's own return value, a distinct contract — see
#     workflows/scripts/lib/cannot-evaluate.sh's header)
#   {"outcome":"PREFLIGHT", tier, baseline, candidate, provider, judge_model,
#    in_scope_n, min_inscope_items, in_scope_slugs,
#    arms_n:2, tokens_per_replay, estimated_total_tokens,
#    ceiling_tokens, ceiling_setting:"REPLAY_PREFLIGHT_CEILING_TOKENS",
#    ceiling_shared_statement, ceiling_exceeded, below_min_inscope,
#    credential_ok, credential_error,
#    spend_account, spend_org,
#    stop, stop_reason: null|"below_min_inscope"|"no_credential"|"ceiling_exceeded",
#    dualBuild: null | {tier, baseline, candidate, inScope:[slug,...]
#                       [, judgeModel]},
#    cumulative_spend_line}
#
# `judge_model` is null and `dualBuild.judgeModel` is ABSENT unless
# --judge-model was given — the no-override path emits exactly the object it
# emitted before temperloop#2203, so a caller that never passes the flag sees
# no shape change at all.
#   exit 0 when stop=false (PROCEED); exit 3 when stop=true (mirrors
#   replay.sh preflight's own `[ "$stop" = "false" ] || return 3` — a
#   distinct non-zero code from RC_CANNOT_EVALUATE (2), so a caller can tell
#   "refused/declined, but the projection itself is trustworthy" apart from
#   "could not even compute a projection".
#
# stop_reason priority when more than one refusal condition holds (below the
# item-count floor also always makes credential/ceiling moot): below_min_
# inscope > no_credential > ceiling_exceeded. All three are ALWAYS computed
# and reported regardless of which one trips `stop`, so a caller sees the
# full picture rather than only the first-hit reason.
#
# spend_account / spend_org are BEST-EFFORT, LOCAL-ONLY (no network call —
# no `gh api`, mirroring the model-comparison module's own no-live-call
# discipline for anything short of an actual candidate spawn): `git config
# user.email` (or `whoami`) for the account, and the origin remote's
# `<owner>/<repo>` (workflows/scripts/lib/land-on-protected-main.sh's own
# `land__nwo`, already sourced by two sibling workflows/scripts/build/*.sh
# scripts) for the org. Either can resolve to an "unknown" placeholder
# string; that placeholder is still named honestly rather than silently
# blank, since the point is transparency, not verified billing identity.
#
# Hermetic: no network, no live model call, no `gh` call of any kind. The
# only subprocess this script spawns is candidate-session.sh's own
# `preflight` subcommand, and even that is steered through its documented
# `--execution recorded` test seam in this suite's own fixtures.
#
# See: [[Designs/temperloop - new-work dual-build harness]] dimension 4 #6,
# dimension 6, dimension 12; [[Plans/2026-09-17 temperloop - new-work
# dual-build harness#dual-build-preflight-script]].

set -uo pipefail

# Physical derivation (`cd -P`) — dir-symlink-composition-safe, matching the
# rest of this module's scripts (e.g. test_replay_preflight.sh's own HERE).
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$HERE/../../.." && pwd)"
CANDIDATE_SESSION_SH="$HERE/../model-comparison/candidate-session.sh"

# shellcheck source=./build.config.sh
[ -f "$HERE/build.config.sh" ] && . "$HERE/build.config.sh"

# shellcheck source=../lib/land-on-protected-main.sh
[ -f "$HERE/../lib/land-on-protected-main.sh" ] && . "$HERE/../lib/land-on-protected-main.sh"

# ── cannot-evaluate.sh: THE ONE emission path (temperloop#1475/#1487) ───────
# Same degraded-fallback boilerplate replay.sh/batch.sh/judge.sh/score.sh
# each carry, reproduced here byte-for-byte rather than re-derived: if the
# real lib is unreachable (a structurally-off checkout, or this file reached
# via a symlink that defeats `$HERE`'s directory-only `cd -P` resolution),
# this still emits the frozen CANNOT_EVALUATE shape and still fails CLOSED
# on the reserved code, but says so honestly instead of silently
# re-implementing the contract a second time.
# shellcheck source=../lib/cannot-evaluate.sh
[ -f "$HERE/../lib/cannot-evaluate.sh" ] && . "$HERE/../lib/cannot-evaluate.sh"
if ! command -v cannot_evaluate_emit >/dev/null 2>&1; then
  RC_CANNOT_EVALUATE=2
  cannot_evaluate_emit() {
    local _e="${2//\\/\\\\}"; _e="${_e//\"/\\\"}"
    printf '{"outcome":"CANNOT_EVALUATE","error":"%s"}\n' "$_e"
    printf '%s: CANNOT-EVALUATE-DEGRADED — workflows/scripts/lib/cannot-evaluate.sh could not be sourced (checkout is structurally off); original message: %s\n' "$1" "$2" >&2
    return "$RC_CANNOT_EVALUATE"
  }
fi

command -v jq >/dev/null 2>&1 || { cannot_evaluate_emit "dual-build-preflight.sh" "jq not found"; exit 1; }

# _dbp_ce <msg> — the ONE refusal path, delegating to the shared library
# (matching batch.sh's `bd_cannot_evaluate` / replay.sh's `preflight_cannot_
# evaluate`). Exit status stays this script's OWN documented CANNOT_EVALUATE
# code (1), NOT RC_CANNOT_EVALUATE — that constant freezes the library
# function's own return value, not a top-level script's process exit code
# (see workflows/scripts/lib/cannot-evaluate.sh's own header, and
# claude/presentation-plane.md's "cannot evaluate" idiom row).
_dbp_ce() { cannot_evaluate_emit "dual-build-preflight.sh" "$1"; exit 1; }

# ── arg parse ────────────────────────────────────────────────────────────────
tier="" items_file="" baseline="" candidate="" judge_model="" provider="anthropic" execution="live"
judge_model_given=false
while [ $# -gt 0 ]; do
  case "$1" in
    --tier)        [ $# -ge 2 ] || { printf 'dual-build-preflight.sh: --tier needs a value\n' >&2; exit 2; }; tier="$2"; shift 2 ;;
    --items-file)  [ $# -ge 2 ] || { printf 'dual-build-preflight.sh: --items-file needs a value\n' >&2; exit 2; }; items_file="$2"; shift 2 ;;
    --baseline)    [ $# -ge 2 ] || { printf 'dual-build-preflight.sh: --baseline needs a value\n' >&2; exit 2; }; baseline="$2"; shift 2 ;;
    --candidate)   [ $# -ge 2 ] || { printf 'dual-build-preflight.sh: --candidate needs a value\n' >&2; exit 2; }; candidate="$2"; shift 2 ;;
    --judge-model) [ $# -ge 2 ] || { printf 'dual-build-preflight.sh: --judge-model needs a value\n' >&2; exit 2; }; judge_model="$2"; judge_model_given=true; shift 2 ;;
    --provider)    [ $# -ge 2 ] || { printf 'dual-build-preflight.sh: --provider needs a value\n' >&2; exit 2; }; provider="$2"; shift 2 ;;
    --execution)
      [ $# -ge 2 ] || { printf 'dual-build-preflight.sh: --execution needs a value\n' >&2; exit 2; }
      case "$2" in
        live|recorded) execution="$2" ;;
        *) printf 'dual-build-preflight.sh: --execution takes live|recorded, got %s\n' "$2" >&2; exit 2 ;;
      esac
      shift 2 ;;
    *) printf 'dual-build-preflight.sh: unknown argument %s\n' "$1" >&2; exit 2 ;;
  esac
done

[ -n "$tier" ]        || _dbp_ce "no --tier given"
[ -n "$items_file" ]  || _dbp_ce "no --items-file given"
[ -n "$baseline" ]    || _dbp_ce "no --baseline given"
[ -n "$candidate" ]   || _dbp_ce "no --candidate given"
# temperloop#2203 — an EMPTY --judge-model is refused rather than read as
# absent: a run that named a judge and silently got the host default is
# indistinguishable, afterwards, from one that never named one.
#
# The emptiness test is TRIMMED, and that is the whole point of the `tr`:
# build-level.mjs's own `str()` trims before testing, so an UNtrimmed test
# here would disagree with its consumer on exactly one input class — a
# whitespace-only value. That value would clear this pre-flight, clear the
# ask-now consent gate with the judge's name rendered as blank space, and
# only then be refused at drive time with dual-build-input-invalid: the
# late refusal this early one exists to prevent. `tr -d '[:space:]'` is
# POSIX and carries no BSD-vs-GNU divergence.
if [ "$judge_model_given" = "true" ]; then
  [ -n "$(printf '%s' "$judge_model" | tr -d '[:space:]')" ] \
    || _dbp_ce "--judge-model was given an empty or whitespace-only value; omit the flag to judge under judge.sh's own default"
fi

# ── read + validate the level's items ────────────────────────────────────────
items_json=""
if [ "$items_file" = "-" ]; then
  items_json="$(cat)"
else
  [ -f "$items_file" ] && [ -r "$items_file" ] || _dbp_ce "items-file not found or not readable: $items_file"
  items_json="$(cat "$items_file")"
fi
[ -n "$items_json" ] || _dbp_ce "items-file has no content: $items_file"

printf '%s' "$items_json" | jq -e 'type=="array"' >/dev/null 2>&1 \
  || _dbp_ce "items-file is not a JSON array: $items_file"
printf '%s' "$items_json" | jq -e 'all(.[]; (.slug|type=="string") and (.slug|length>0) and (.model == null or (.model|type=="string")))' >/dev/null 2>&1 \
  || _dbp_ce "malformed item record (each item needs a non-empty string .slug, and .model — when present — must be a string): $items_file"

# ── settings this script CONSUMES — CANNOT_EVALUATE on unset/non-integer ────
# Same fail-closed floor replay.sh preflight's own settings-validation loop
# uses (temperloop#1365): a missing/garbage value never silently reads as
# zero-and-under-budget.
for _s in REPLAY_PREFLIGHT_CEILING_TOKENS REPLAY_PREFLIGHT_TOKENS_PER_REPLAY DUAL_BUILD_MIN_INSCOPE_ITEMS; do
  _v="${!_s-}"
  case "$_v" in
    ''|*[!0-9]*) _dbp_ce "$_s is not a non-negative integer (\"$_v\") — the batch estimate and the in-scope floor cannot be evaluated against it" ;;
  esac
done
unset _s _v

# ── resolve in-scope items ───────────────────────────────────────────────────
in_scope_json="$(printf '%s' "$items_json" | jq --arg t "$tier" '[.[] | select(.model == $t)]')"
in_scope_n="$(printf '%s' "$in_scope_json" | jq 'length')"
in_scope_slugs_json="$(printf '%s' "$in_scope_json" | jq '[.[].slug]')"

below_min_inscope=false
[ "$in_scope_n" -lt "$DUAL_BUILD_MIN_INSCOPE_ITEMS" ] && below_min_inscope=true

# ── project spend (reused REPLAY ceiling math, temperloop#1379's own shape:
#    N items x 2 arms x per-arm cost — the SAME unit REPLAY_PREFLIGHT_
#    CEILING_TOKENS is denominated in, never a raw token sum) ────────────────
arms_n=2
estimated_total_tokens=$((in_scope_n * arms_n * REPLAY_PREFLIGHT_TOKENS_PER_REPLAY))
ceiling_exceeded=false
[ "$estimated_total_tokens" -gt "$REPLAY_PREFLIGHT_CEILING_TOKENS" ] && ceiling_exceeded=true

# ── candidate provider credential check — candidate-session.sh is THE ONE
#    host-supply seam (never sourced: its own CLI dispatch would run
#    unconditionally on `source`, so it is always invoked as a subprocess,
#    exactly as replay.sh's own `execute` does) ──────────────────────────────
credential_ok=true
credential_error=""
if [ -f "$CANDIDATE_SESSION_SH" ]; then
  pf_out=""
  if ! pf_out="$(bash "$CANDIDATE_SESSION_SH" preflight --provider "$provider" --execution "$execution" 2>&1)"; then
    credential_ok=false
    credential_error="$pf_out"
  fi
else
  credential_ok=false
  credential_error="candidate-session.sh not found at $CANDIDATE_SESSION_SH — the candidate spawn seam is unavailable"
fi

# ── best-effort, LOCAL-ONLY spend attribution (no network call) ─────────────
spend_account="$(git -C "$REPO_ROOT" config user.email 2>/dev/null)"
# `whoami`, not $USER: an ALL-CAPS `${USER:-...}` fallback would be a
# setting-shaped seam check-setting-registry.sh's UNREGISTERED sweep flags
# (USER is not in its SETTING_REGISTRY_GENERIC_ALLOWLIST) — `whoami` reads
# the identical identity with no such seam.
[ -n "$spend_account" ] || spend_account="$(whoami 2>/dev/null)"
[ -n "$spend_account" ] || spend_account="unknown — no git user.email and whoami failed"

spend_org="unknown — no resolvable origin remote"
if command -v land__nwo >/dev/null 2>&1; then
  # LAND_ROOT is an IN-PARAM land__nwo (sourced from land-on-protected-main.sh,
  # SC1091-unresolvable) reads from this same shell's variable space — no
  # `export` needed since it's a plain function call, not a subprocess — so
  # the static linter's "appears unused" is a false positive here.
  # shellcheck disable=SC2034
  LAND_ROOT="$REPO_ROOT"
  _nwo="$(land__nwo)"
  [ -n "$_nwo" ] && spend_org="$_nwo"
  unset _nwo LAND_ROOT
fi

# ── stop decision — priority: below_min_inscope > no_credential > ceiling ───
stop=false
stop_reason=""
if [ "$below_min_inscope" = "true" ]; then
  stop=true; stop_reason="below_min_inscope"
elif [ "$credential_ok" = "false" ]; then
  stop=true; stop_reason="no_credential"
elif [ "$ceiling_exceeded" = "true" ]; then
  stop=true; stop_reason="ceiling_exceeded"
fi

cumulative_spend_line="Cumulative dual-build spend projected for this level: $estimated_total_tokens cost-weighted token units across $in_scope_n in-scope item(s) tagged model: $tier (2 arms x $REPLAY_PREFLIGHT_TOKENS_PER_REPLAY per item), against a ceiling of $REPLAY_PREFLIGHT_CEILING_TOKENS (REPLAY_PREFLIGHT_CEILING_TOKENS — the replay harness's own shared ceiling setting, not a dual-build-specific one). Spend lands on account '$spend_account' (org: $spend_org)."
# temperloop#2203 — disclose the INSTRUMENT on the consent prompt, but only
# when this run selected one: with no --judge-model the line is byte-identical
# to the pre-#2203 one, so no existing consent text changes.
[ -n "$judge_model" ] && cumulative_spend_line="$cumulative_spend_line Pairwise judge for this run: $judge_model (per-invocation --judge-model; no host default was changed)."

payload="$(jq -n \
  --arg tier "$tier" --arg baseline "$baseline" --arg candidate "$candidate" --arg provider "$provider" \
  --arg judge_model "$judge_model" \
  --argjson in_scope_n "$in_scope_n" --argjson min_inscope_items "$DUAL_BUILD_MIN_INSCOPE_ITEMS" \
  --argjson in_scope_slugs "$in_scope_slugs_json" \
  --argjson arms_n "$arms_n" --argjson tokens_per_replay "$REPLAY_PREFLIGHT_TOKENS_PER_REPLAY" \
  --argjson estimated_total_tokens "$estimated_total_tokens" --argjson ceiling_tokens "$REPLAY_PREFLIGHT_CEILING_TOKENS" \
  --argjson ceiling_exceeded "$ceiling_exceeded" --argjson below_min_inscope "$below_min_inscope" \
  --argjson credential_ok "$credential_ok" --arg credential_error "$credential_error" \
  --arg spend_account "$spend_account" --arg spend_org "$spend_org" \
  --argjson stop "$stop" --arg stop_reason "$stop_reason" \
  --arg cumulative_spend_line "$cumulative_spend_line" \
  '{outcome:"PREFLIGHT",
    tier:$tier, baseline:$baseline, candidate:$candidate, provider:$provider,
    judge_model: (if $judge_model == "" then null else $judge_model end),
    in_scope_n:$in_scope_n, min_inscope_items:$min_inscope_items, in_scope_slugs:$in_scope_slugs,
    arms_n:$arms_n, tokens_per_replay:$tokens_per_replay,
    estimated_total_tokens:$estimated_total_tokens,
    ceiling_tokens:$ceiling_tokens, ceiling_setting:"REPLAY_PREFLIGHT_CEILING_TOKENS",
    ceiling_shared_statement:"REPLAY_PREFLIGHT_CEILING_TOKENS is the replay harness'\''s own shared ceiling setting, not a dual-build-specific one.",
    ceiling_exceeded:$ceiling_exceeded, below_min_inscope:$below_min_inscope,
    credential_ok:$credential_ok, credential_error: (if $credential_error == "" then null else $credential_error end),
    spend_account:$spend_account, spend_org:$spend_org,
    stop:$stop, stop_reason: (if $stop_reason == "" then null else $stop_reason end),
    dualBuild: (if $stop then null
                else {tier:$tier, baseline:$baseline, candidate:$candidate, inScope:$in_scope_slugs}
                     + (if $judge_model == "" then {} else {judgeModel:$judge_model} end)
                end),
    cumulative_spend_line:$cumulative_spend_line}')" || _dbp_ce "failed to emit the PREFLIGHT record"

printf '%s\n' "$payload"

[ "$stop" = "false" ] || exit 3
exit 0
