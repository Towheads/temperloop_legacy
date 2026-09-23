#!/usr/bin/env bash
#
# test_dual_build_preflight.sh — fixture suite for
# workflows/scripts/build/dual-build-preflight.sh (temperloop#2079, epic
# #2065 "new-work dual-build harness"): the orchestrator-side dual-build
# spend gate that resolves a level's in-scope items, projects 2x-worker +
# judge spend against REPLAY_PREFLIGHT_CEILING_TOKENS, checks the
# candidate's provider credential via candidate-session.sh, and emits the
# `dualBuild` workflow-input JSON plus a cumulative-spend line only when
# none of that refuses.
#
# Hermetic: no network, no `gh`, no live model call, no live git remote
# requirement (a throwaway git repo is built per test). Every candidate-
# session.sh call goes through its documented `--execution recorded` test
# seam. bash 3.2-portable (no mapfile / associative arrays).
#
# Sections:
#   1-3   in-scope resolution: model: tier filter, in_scope_n, inScope slugs
#   4-6   DUAL_BUILD_MIN_INSCOPE_ITEMS: at/above proceeds, below declines
#         (stop:true, stop_reason:"below_min_inscope", dualBuild:null,
#         non-zero exit) + MUTATION PROOF the floor check is load-bearing
#   7-9   REPLAY_PREFLIGHT_CEILING_TOKENS: under proceeds, over refuses
#         (stop_reason:"ceiling_exceeded") + MUTATION PROOF the ceiling
#         check is load-bearing; math pins 2 arms x tokens_per_replay
#   10-12 candidate-session.sh IS CONSULTED for the CANDIDATE's provider:
#         missing key -> stop_reason:"no_credential", key present ->
#         proceeds + MUTATION PROOF the credential check is load-bearing
#   13-15 FAIL CLOSED on an unset/malformed REPLAY_PREFLIGHT_CEILING_TOKENS,
#         REPLAY_PREFLIGHT_TOKENS_PER_REPLAY, DUAL_BUILD_MIN_INSCOPE_ITEMS —
#         all CANNOT_EVALUATE, non-zero, naming the exact setting
#   16-19 FAIL CLOSED on malformed / absent / empty items-file, missing
#         required flags
#   20    the emitted `dualBuild` JSON shape matches {tier,baseline,
#         candidate,inScope} exactly on the proceed path, and is null on
#         every refusal path
#   21    spend_account / spend_org resolve from LOCAL git state only (no
#         network) — a throwaway repo with a known user.email and origin
#         proves both fields
#   22    stdin items-file (`--items-file -`)
#   23-28 --judge-model (temperloop#2203): given -> rides .judge_model,
#         .dualBuild.judgeModel and the consent line; absent -> null field,
#         NO judgeModel key, byte-identical consent line; empty -> refused
#
# Usage: bash workflows/scripts/build/tests/test_dual_build_preflight.sh

set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$(cd -P "$HERE/.." && pwd)"
SUT="$BUILD_DIR/dual-build-preflight.sh"

pass=0
total=0
ok()    { pass=$((pass + 1)); echo "PASS: $1"; }
count() { total=$((total + 1)); }
fail()  { echo "FAIL: $1" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-dual-build-preflight-XXXXXX")"
WORK="$(cd -P "$WORK" && pwd)"
trap 'chmod -R u+rwX "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

# mutate_file <file> <old-literal-text> <new-literal-text> — exact, literal,
# single-occurrence replacement (same idiom as
# workflows/scripts/model-comparison/tests/test_replay_preflight.sh's own
# helper). Dies loudly if the old text is missing or not unique.
mutate_file() {
  local file="$1" old="$2" new="$3"
  MUT_OLD="$old" MUT_NEW="$new" perl -0777 -pi -e '
    my $o = $ENV{MUT_OLD};
    my $n = $ENV{MUT_NEW};
    my $count = () = /\Q$o\E/g;
    die "mutate_file: old text not found-or-not-unique (count=$count)\n" unless $count == 1;
    s/\Q$o\E/$n/;
  ' "$file"
}

# A throwaway git repo standing in for a real checkout: dual-build-
# preflight.sh needs REPO_ROOT for spend_account/spend_org resolution
# (git config user.email + the origin remote), and derives it as
# $HERE/../../.. from wherever it is copied. So each fixture COPIES the SUT
# and its two sourced siblings (build.config.sh, candidate-session.sh, plus
# land-on-protected-main.sh and cannot-evaluate.sh) into
# <repo>/workflows/scripts/{build,model-comparison,lib}/ — the same
# relative layout as the real tree — rather than invoking the live
# checkout's copy in place, so REPLAY_PREFLIGHT_* / DUAL_BUILD_* settings
# and the git fixture are both fully test-controlled.
REPO_SRC_ROOT="$(cd -P "$BUILD_DIR/../../.." && pwd)"

mk_repo() {  # mk_repo <dir> — a fresh git repo with the SUT + real siblings
  local dir="$1"
  rm -rf "$dir"
  mkdir -p "$dir/workflows/scripts/build" "$dir/workflows/scripts/model-comparison" "$dir/workflows/scripts/lib"
  cp "$SUT" "$dir/workflows/scripts/build/dual-build-preflight.sh"
  cp "$REPO_SRC_ROOT/workflows/scripts/build/build.config.sh" "$dir/workflows/scripts/build/build.config.sh"
  cp "$REPO_SRC_ROOT/workflows/scripts/model-comparison/candidate-session.sh" "$dir/workflows/scripts/model-comparison/candidate-session.sh"
  cp "$REPO_SRC_ROOT/workflows/scripts/lib/land-on-protected-main.sh" "$dir/workflows/scripts/lib/land-on-protected-main.sh"
  cp "$REPO_SRC_ROOT/workflows/scripts/lib/cannot-evaluate.sh" "$dir/workflows/scripts/lib/cannot-evaluate.sh"
  git -C "$dir" init -q
  git -C "$dir" config user.email "fixture@example.com"
  git -C "$dir" config user.name "Fixture User"
  git -C "$dir" remote add origin "https://github.com/FixtureOrg/fixture-repo.git"
}

REPO="$WORK/repo"
mk_repo "$REPO"
DBP="$REPO/workflows/scripts/build/dual-build-preflight.sh"

write_items() {  # write_items <file> <json>
  printf '%s' "$2" > "$1"
}

ITEMS_MIXED='[{"slug":"a","model":"sonnet"},{"slug":"b","model":"opus"},{"slug":"c","model":"sonnet"},{"slug":"d","model":"sonnet"}]'

# run <items-json> [extra env assignments…] — always DUAL_BUILD_MIN_INSCOPE_ITEMS=2
# and --execution recorded (hermetic: bypasses candidate-session.sh's live
# runner requirement so the KEY gate alone is exercised, per that script's
# own documented test seam).
run() {
  local items="$1"; shift
  local f="$WORK/items-$$-$RANDOM.json"
  write_items "$f" "$items"
  # DUAL_BUILD_MIN_INSCOPE_ITEMS=2 is the default, listed FIRST so any
  # override in "$@" (env's last-wins semantics for a repeated NAME=value)
  # takes precedence over it.
  env DUAL_BUILD_MIN_INSCOPE_ITEMS=2 "$@" \
    bash "$DBP" --tier sonnet --items-file "$f" --baseline claude-opus-4-8 \
      --candidate claude-sonnet-5 --execution recorded
}

field() { printf '%s' "$1" | jq -r "$2"; }

# ── 1-3: in-scope resolution ─────────────────────────────────────────────────
echo "--- 1-3: in-scope resolution (model: tier filter) ---"
count; v="$(run "$ITEMS_MIXED")"
[ "$(field "$v" .in_scope_n)" = "3" ] && ok "in_scope_n=3 (a,c,d match tier sonnet; b=opus excluded)" || fail "in_scope_n: got $(field "$v" .in_scope_n)"
count; [ "$(field "$v" '.in_scope_slugs | sort | join(",")')" = "a,c,d" ] && ok "in_scope_slugs = a,c,d" || fail "in_scope_slugs: got $(field "$v" '.in_scope_slugs')"
count; [ "$(field "$v" .outcome)" = "PREFLIGHT" ] && ok "outcome=PREFLIGHT" || fail "outcome: got $(field "$v" .outcome)"

# ── 3b: absent .model key (temperloop#2079 regression — claude/plan-schema.md
# § "Optional model: field" makes model: OPTIONAL; absent means "inherit the
# session model (top tier)", which /assess deliberately leaves absent on
# every kind: spike item and every size: L item. ITEMS_MIXED above always
# stamps .model on every element, which is exactly why the original
# `.model|type=="string"` validation predicate's bug went untested: an item
# with NO .model key at all must be silently excluded from scope (never
# CANNOT_EVALUATE as a "malformed" record), and in_scope_n must resolve
# correctly around it ─────────────────────────────────────────────────────
echo "--- 3b: item with no .model key at all (absent, not stamped) ---"
ITEMS_NO_MODEL_KEY='[{"slug":"a","model":"sonnet"},{"slug":"b"}]'
count; rc=0; v="$(run "$ITEMS_NO_MODEL_KEY" DUAL_BUILD_MIN_INSCOPE_ITEMS=1)" || rc=$?
[ "$(field "$v" .outcome)" = "PREFLIGHT" ] && [ "$rc" -eq 0 ] \
  && ok "an item with no .model key is NOT treated as a malformed record (outcome=PREFLIGHT, exit 0)" \
  || fail "no-model-key: outcome=$(field "$v" .outcome) rc=$rc"
count; [ "$(field "$v" .in_scope_n)" = "1" ] && ok "in_scope_n=1 (only a, which has model:sonnet; b has no .model key and is excluded)" \
  || fail "in_scope_n: got $(field "$v" .in_scope_n)"
count; [ "$(field "$v" '.in_scope_slugs | join(",")')" = "a" ] && ok "in_scope_slugs = a (b silently excluded, not counted, not erroring)" \
  || fail "in_scope_slugs: got $(field "$v" '.in_scope_slugs')"

# ── 4-6: DUAL_BUILD_MIN_INSCOPE_ITEMS floor ─────────────────────────────────
echo "--- 4-6: min-inscope floor ---"
count; v="$(run "$ITEMS_MIXED" DUAL_BUILD_MIN_INSCOPE_ITEMS=3)"
[ "$(field "$v" .stop)" = "false" ] && ok "3 in-scope, floor=3 -> proceeds (at the floor, not below it)" || fail "at-floor: got stop=$(field "$v" .stop)"

count; rc=0; v="$(run "$ITEMS_MIXED" DUAL_BUILD_MIN_INSCOPE_ITEMS=4)" || rc=$?
[ "$(field "$v" .stop)" = "true" ] && [ "$(field "$v" .stop_reason)" = "below_min_inscope" ] && [ "$(field "$v" .dualBuild)" = "null" ] && [ "$rc" -eq 3 ] \
  && ok "3 in-scope, floor=4 -> declines (below_min_inscope, dualBuild:null, exit 3)" \
  || fail "below-floor: stop=$(field "$v" .stop) reason=$(field "$v" .stop_reason) dualBuild=$(field "$v" .dualBuild) rc=$rc"

echo "--- MUTATION PROOF: the min-inscope floor check is load-bearing ---"
count
mutate_file "$DBP" '[ "$in_scope_n" -lt "$DUAL_BUILD_MIN_INSCOPE_ITEMS" ] && below_min_inscope=true' 'true && below_min_inscope=false'
v="$(run "$ITEMS_MIXED" DUAL_BUILD_MIN_INSCOPE_ITEMS=4)"
[ "$(field "$v" .stop)" = "false" ] && ok "MUTATED: disabling the floor check makes a genuinely-below-floor batch WRONGLY proceed (RED confirmed)" \
  || fail "mutation had no effect — floor check may not be load-bearing: stop=$(field "$v" .stop)"
mk_repo "$REPO"  # restore pristine SUT
v="$(run "$ITEMS_MIXED" DUAL_BUILD_MIN_INSCOPE_ITEMS=4)"
count
[ "$(field "$v" .stop)" = "true" ] && ok "RESTORED: same below-floor batch correctly declines again (GREEN confirmed)" \
  || fail "restore did not recover correct behavior: stop=$(field "$v" .stop)"

# ── 7-9: ceiling ─────────────────────────────────────────────────────────────
echo "--- 7-9: REPLAY_PREFLIGHT_CEILING_TOKENS ---"
count; v="$(run "$ITEMS_MIXED" REPLAY_PREFLIGHT_CEILING_TOKENS=50000000 REPLAY_PREFLIGHT_TOKENS_PER_REPLAY=470000)"
# 3 in-scope x 2 arms x 470000 = 2820000, well under 50000000
[ "$(field "$v" .estimated_total_tokens)" = "2820000" ] && [ "$(field "$v" .stop)" = "false" ] \
  && ok "3 items x 2 arms x 470000 = 2820000, under ceiling -> proceeds" \
  || fail "under-ceiling: estimated=$(field "$v" .estimated_total_tokens) stop=$(field "$v" .stop)"

count; rc=0; v="$(run "$ITEMS_MIXED" REPLAY_PREFLIGHT_CEILING_TOKENS=2000000 REPLAY_PREFLIGHT_TOKENS_PER_REPLAY=470000)" || rc=$?
[ "$(field "$v" .stop)" = "true" ] && [ "$(field "$v" .stop_reason)" = "ceiling_exceeded" ] && [ "$(field "$v" .dualBuild)" = "null" ] && [ "$rc" -eq 3 ] \
  && ok "2820000 > ceiling 2000000 -> refuses (ceiling_exceeded, dualBuild:null, exit 3)" \
  || fail "over-ceiling: stop=$(field "$v" .stop) reason=$(field "$v" .stop_reason) rc=$rc"

echo "--- MUTATION PROOF: the ceiling check is load-bearing ---"
count
mutate_file "$DBP" '[ "$estimated_total_tokens" -gt "$REPLAY_PREFLIGHT_CEILING_TOKENS" ] && ceiling_exceeded=true' 'true && ceiling_exceeded=false'
v="$(run "$ITEMS_MIXED" REPLAY_PREFLIGHT_CEILING_TOKENS=2000000 REPLAY_PREFLIGHT_TOKENS_PER_REPLAY=470000)"
[ "$(field "$v" .stop)" = "false" ] && ok "MUTATED: disabling the ceiling check makes a genuinely-over-budget batch WRONGLY proceed (RED confirmed)" \
  || fail "mutation had no effect — ceiling check may not be load-bearing: stop=$(field "$v" .stop)"
mk_repo "$REPO"
v="$(run "$ITEMS_MIXED" REPLAY_PREFLIGHT_CEILING_TOKENS=2000000 REPLAY_PREFLIGHT_TOKENS_PER_REPLAY=470000)"
count
[ "$(field "$v" .stop)" = "true" ] && ok "RESTORED: same over-ceiling batch correctly refuses again (GREEN confirmed)" \
  || fail "restore did not recover correct behavior: stop=$(field "$v" .stop)"

# ── 10-12: candidate-session.sh credential check ────────────────────────────
echo "--- 10-12: candidate provider credential (candidate-session.sh) ---"
count; v="$(run "$ITEMS_MIXED")"  # default provider "anthropic" — exempt from the key gate
[ "$(field "$v" .credential_ok)" = "true" ] && [ "$(field "$v" .stop)" = "false" ] \
  && ok "default provider anthropic (key-exempt) -> credential_ok, proceeds" \
  || fail "anthropic default: credential_ok=$(field "$v" .credential_ok) stop=$(field "$v" .stop)"

f="$WORK/items-cred.json"; write_items "$f" "$ITEMS_MIXED"
rc=0
v="$(env DUAL_BUILD_MIN_INSCOPE_ITEMS=2 OPENAI_API_KEY= bash "$DBP" --tier sonnet --items-file "$f" \
      --baseline x --candidate y --provider openai --execution recorded)" || rc=$?
count
[ "$(field "$v" .credential_ok)" = "false" ] && [ "$(field "$v" .stop_reason)" = "no_credential" ] \
  && [ "$(field "$v" .dualBuild)" = "null" ] && [ "$rc" -eq 3 ] \
  && printf '%s' "$(field "$v" .credential_error)" | grep "OPENAI_API_KEY" >/dev/null \
  && ok "provider openai, unset OPENAI_API_KEY -> refuses by name (no_credential, names OPENAI_API_KEY, exit 3)" \
  || fail "no-credential: credential_ok=$(field "$v" .credential_ok) reason=$(field "$v" .stop_reason) rc=$rc error=$(field "$v" .credential_error)"

count
v="$(env DUAL_BUILD_MIN_INSCOPE_ITEMS=2 OPENAI_API_KEY=stub-key bash "$DBP" --tier sonnet --items-file "$f" \
      --baseline x --candidate y --provider openai --execution recorded)"
[ "$(field "$v" .credential_ok)" = "true" ] && [ "$(field "$v" .stop)" = "false" ] \
  && ok "provider openai, OPENAI_API_KEY set -> credential_ok, proceeds" \
  || fail "credential-present: credential_ok=$(field "$v" .credential_ok) stop=$(field "$v" .stop)"

echo "--- MUTATION PROOF: the credential check is load-bearing ---"
count
mutate_file "$DBP" 'if ! pf_out="$(bash "$CANDIDATE_SESSION_SH" preflight --provider "$provider" --execution "$execution" 2>&1)"; then' \
                    'if false; then'
v="$(env DUAL_BUILD_MIN_INSCOPE_ITEMS=2 OPENAI_API_KEY= bash "$DBP" --tier sonnet --items-file "$f" \
      --baseline x --candidate y --provider openai --execution recorded)"
[ "$(field "$v" .stop)" = "false" ] && ok "MUTATED: disabling the candidate-session.sh call makes an unset-key provider WRONGLY proceed (RED confirmed)" \
  || fail "mutation had no effect — credential check may not be load-bearing: stop=$(field "$v" .stop)"
mk_repo "$REPO"
v="$(env DUAL_BUILD_MIN_INSCOPE_ITEMS=2 OPENAI_API_KEY= bash "$DBP" --tier sonnet --items-file "$f" \
      --baseline x --candidate y --provider openai --execution recorded)"
count
[ "$(field "$v" .stop)" = "true" ] && ok "RESTORED: same unset-key provider correctly refuses again (GREEN confirmed)" \
  || fail "restore did not recover correct behavior: stop=$(field "$v" .stop)"

# ── 13-15: FAIL CLOSED on unset/malformed settings ──────────────────────────
echo "--- 13-15: fail-closed settings validation ---"
BLANK_REPO="$WORK/blank-repo"
mkdir -p "$BLANK_REPO/workflows/scripts/build"
cp "$SUT" "$BLANK_REPO/workflows/scripts/build/dual-build-preflight.sh"  # no build.config.sh sibling at all
f2="$WORK/items-blank.json"; write_items "$f2" "$ITEMS_MIXED"

count; rc=0
out="$(env DUAL_BUILD_MIN_INSCOPE_ITEMS=2 bash "$BLANK_REPO/workflows/scripts/build/dual-build-preflight.sh" \
        --tier sonnet --items-file "$f2" --baseline x --candidate y --execution recorded 2>/dev/null)" || rc=$?
[ "$(field "$out" .outcome)" = "CANNOT_EVALUATE" ] && printf '%s' "$(field "$out" .error)" | grep "REPLAY_PREFLIGHT_CEILING_TOKENS" >/dev/null && [ "$rc" -ne 0 ] \
  && ok "no build.config.sh sibling (unset ceiling) -> CANNOT_EVALUATE naming REPLAY_PREFLIGHT_CEILING_TOKENS" \
  || fail "unset-ceiling: outcome=$(field "$out" .outcome) error=$(field "$out" .error) rc=$rc"

count; rc=0
out="$(env DUAL_BUILD_MIN_INSCOPE_ITEMS=not-a-number bash "$DBP" --tier sonnet --items-file "$f" \
        --baseline x --candidate y --execution recorded 2>/dev/null)" || rc=$?
[ "$(field "$out" .outcome)" = "CANNOT_EVALUATE" ] && printf '%s' "$(field "$out" .error)" | grep "DUAL_BUILD_MIN_INSCOPE_ITEMS" >/dev/null && [ "$rc" -ne 0 ] \
  && ok "non-numeric DUAL_BUILD_MIN_INSCOPE_ITEMS -> CANNOT_EVALUATE naming it" \
  || fail "malformed-min: outcome=$(field "$out" .outcome) error=$(field "$out" .error) rc=$rc"

count; rc=0
out="$(env DUAL_BUILD_MIN_INSCOPE_ITEMS=2 REPLAY_PREFLIGHT_TOKENS_PER_REPLAY=-5 bash "$DBP" --tier sonnet --items-file "$f" \
        --baseline x --candidate y --execution recorded 2>/dev/null)" || rc=$?
[ "$(field "$out" .outcome)" = "CANNOT_EVALUATE" ] && printf '%s' "$(field "$out" .error)" | grep "REPLAY_PREFLIGHT_TOKENS_PER_REPLAY" >/dev/null \
  && ok "negative REPLAY_PREFLIGHT_TOKENS_PER_REPLAY -> CANNOT_EVALUATE naming it" \
  || fail "negative-tpr: outcome=$(field "$out" .outcome) error=$(field "$out" .error)"

# ── 16-19: FAIL CLOSED on items-file / required flags ───────────────────────
echo "--- 16-19: fail-closed input validation ---"
count; rc=0
out="$(env DUAL_BUILD_MIN_INSCOPE_ITEMS=2 bash "$DBP" --tier sonnet --items-file "$WORK/does-not-exist.json" --baseline x --candidate y 2>/dev/null)" || rc=$?
[ "$(field "$out" .outcome)" = "CANNOT_EVALUATE" ] && [ "$rc" -ne 0 ] && ok "absent items-file -> CANNOT_EVALUATE" || fail "absent: $out rc=$rc"

count; f3="$WORK/notarray.json"; write_items "$f3" '{"slug":"a"}'
out="$(env DUAL_BUILD_MIN_INSCOPE_ITEMS=2 bash "$DBP" --tier sonnet --items-file "$f3" --baseline x --candidate y 2>/dev/null)"
[ "$(field "$out" .outcome)" = "CANNOT_EVALUATE" ] && ok "non-array items-file -> CANNOT_EVALUATE" || fail "non-array: $out"

count; f4="$WORK/emptyfields.json"; write_items "$f4" '[{"slug":"","model":"sonnet"}]'
out="$(env DUAL_BUILD_MIN_INSCOPE_ITEMS=2 bash "$DBP" --tier sonnet --items-file "$f4" --baseline x --candidate y 2>/dev/null)"
[ "$(field "$out" .outcome)" = "CANNOT_EVALUATE" ] && ok "empty-string slug -> CANNOT_EVALUATE (malformed record)" || fail "empty-slug: $out"

count; rc=0
out="$(bash "$DBP" --items-file "$f" --baseline x --candidate y 2>/dev/null)" || rc=$?
[ "$(field "$out" .outcome)" = "CANNOT_EVALUATE" ] && [ "$rc" -ne 0 ] && ok "missing --tier -> CANNOT_EVALUATE" || fail "missing --tier: $out rc=$rc"

# ── 20: dualBuild JSON shape ─────────────────────────────────────────────────
echo "--- 20: dualBuild input JSON shape ---"
count; v="$(run "$ITEMS_MIXED")"
db="$(field "$v" '.dualBuild | {tier,baseline,candidate} | to_entries | map("\(.key)=\(.value)") | join(",")')"
[ "$db" = "tier=sonnet,baseline=claude-opus-4-8,candidate=claude-sonnet-5" ] \
  && [ "$(field "$v" '.dualBuild.inScope | sort | join(",")')" = "a,c,d" ] \
  && ok "dualBuild = {tier,baseline,candidate,inScope} exactly, on the proceed path" \
  || fail "dualBuild shape: $(field "$v" .dualBuild)"

# ── 21: spend_account / spend_org resolve LOCALLY (no network) ─────────────
echo "--- 21: spend_account / spend_org (local git state, no network) ---"
count; v="$(run "$ITEMS_MIXED")"
[ "$(field "$v" .spend_account)" = "fixture@example.com" ] && ok "spend_account = git config user.email" || fail "spend_account: $(field "$v" .spend_account)"
count; [ "$(field "$v" .spend_org)" = "FixtureOrg/fixture-repo" ] && ok "spend_org = <owner>/<repo> from the origin remote" || fail "spend_org: $(field "$v" .spend_org)"

# ── 22: stdin items-file ─────────────────────────────────────────────────────
echo "--- 22: --items-file - reads stdin ---"
count
v="$(printf '%s' "$ITEMS_MIXED" | env DUAL_BUILD_MIN_INSCOPE_ITEMS=2 bash "$DBP" --tier sonnet --items-file - --baseline x --candidate y --execution recorded)"
[ "$(field "$v" .in_scope_n)" = "3" ] && ok "--items-file - reads the level's items from stdin" || fail "stdin: $(field "$v" .in_scope_n)"

# ── 23-28: --judge-model (temperloop#2203) ───────────────────────────────────
# The per-run pairwise-judge seam. Every input state is asserted: GIVEN (the id
# rides `dualBuild.judgeModel`, the top-level `judge_model` field and the
# consent line), ABSENT (no key at all — the object is byte-identical to the
# pre-#2203 one, which is what keeps a caller that never passes the flag from
# regressing), EMPTY and WHITESPACE-ONLY (both refused loudly, never read as
# absent — the two must agree, because build-level.mjs's own `str()` trims and
# a gate that did not would refuse them in different places), and PADDED-BUT-
# REAL (accepted — the control that keeps the two refusals from being satisfied
# by a gate that simply refuses every value it is given).
echo "--- 23-28: --judge-model per-run pairwise judge ---"

# run_judge <items-json> <judge-model-args…> — run() plus arbitrary extra SUT
# flags (run() itself takes only env assignments).
run_judge() {
  local items="$1"; shift
  local f="$WORK/items-judge-$$-$RANDOM.json"
  write_items "$f" "$items"
  env DUAL_BUILD_MIN_INSCOPE_ITEMS=2 \
    bash "$DBP" --tier sonnet --items-file "$f" --baseline claude-opus-4-8 \
      --candidate claude-sonnet-5 --execution recorded "$@"
}

# 23: GIVEN — the value reaches the emitted object AND the top-level field.
count; v="$(run_judge "$ITEMS_MIXED" --judge-model claude-haiku-9)"
[ "$(field "$v" .judge_model)" = "claude-haiku-9" ] \
  && [ "$(field "$v" .dualBuild.judgeModel)" = "claude-haiku-9" ] \
  && ok "--judge-model rides both .judge_model and .dualBuild.judgeModel" \
  || fail "judge-model given: judge_model=$(field "$v" .judge_model) dualBuild=$(field "$v" .dualBuild)"

# 24: GIVEN — the consent prompt discloses the instrument. Without this the
# operator consents to a spend without being told which judge reads the arms.
count; printf '%s' "$v" | jq -e '.cumulative_spend_line | test("Pairwise judge for this run: claude-haiku-9")' >/dev/null \
  && ok "the judge identity is named on cumulative_spend_line (the consent prompt)" \
  || fail "consent line omits the judge: $(field "$v" .cumulative_spend_line)"

# 25: ABSENT — no key at all, null field, and a spend line byte-identical to
# the flag-less one. THE regression guard for the no-override path.
count; v_abs="$(run_judge "$ITEMS_MIXED")"
v_plain="$(run "$ITEMS_MIXED")"
[ "$(field "$v_abs" .judge_model)" = "null" ] \
  && [ "$(field "$v_abs" '.dualBuild | has("judgeModel")')" = "false" ] \
  && [ "$(field "$v_abs" '.dualBuild | keys | sort | join(",")')" = "baseline,candidate,inScope,tier" ] \
  && [ "$(field "$v_abs" .cumulative_spend_line)" = "$(field "$v_plain" .cumulative_spend_line)" ] \
  && ok "no --judge-model: judge_model null, NO judgeModel key, consent line unchanged" \
  || fail "judge-model absent: judge_model=$(field "$v_abs" .judge_model) dualBuild=$(field "$v_abs" .dualBuild)"

# 26: EMPTY — refused loudly (CANNOT_EVALUATE, non-zero), never silently read
# as absent. A run that named a judge and got the host default instead is
# indistinguishable afterwards from one that never named one.
count; rc=0; v="$(run_judge "$ITEMS_MIXED" --judge-model "")" || rc=$?
[ "$(field "$v" .outcome)" = "CANNOT_EVALUATE" ] && [ "$rc" -ne 0 ] \
  && printf '%s' "$v" | jq -e '.error | test("--judge-model")' >/dev/null \
  && ok "an EMPTY --judge-model is refused (CANNOT_EVALUATE, non-zero), not read as absent" \
  || fail "empty judge-model: outcome=$(field "$v" .outcome) rc=$rc"

# 27: WHITESPACE-ONLY — refused on exactly the same terms as case 26, because
# the consumer refuses it too. build-level.mjs's `str()` TRIMS before testing,
# so an untrimmed test here would let '   ' clear this pre-flight and the
# ask-now consent gate — with the judge's name rendering as blank space on the
# spend line the operator consents to — and only then be refused at drive time
# with dual-build-input-invalid. That late refusal is precisely what moving the
# check forward to the pre-flight exists to prevent, so the two validators must
# agree on all three input states, not two of them.
count; rc=0; v="$(run_judge "$ITEMS_MIXED" --judge-model "   ")" || rc=$?
[ "$(field "$v" .outcome)" = "CANNOT_EVALUATE" ] && [ "$rc" -ne 0 ] \
  && printf '%s' "$v" | jq -e '.error | test("--judge-model")' >/dev/null \
  && ok "a WHITESPACE-ONLY --judge-model is refused too — the shell gate trims, matching build-level.mjs's str()" \
  || fail "whitespace judge-model: outcome=$(field "$v" .outcome) rc=$rc"

# 28: the CONTROL for 26-27 — a judge model that is merely SURROUNDED by
# whitespace is a real value, not an empty one, and must still be ACCEPTED.
# Without this, cases 26-27 are equally satisfied by a gate that refuses every
# --judge-model it is given (temperloop#1706: an assertion that cannot fail).
count; v="$(run_judge "$ITEMS_MIXED" --judge-model " claude-haiku-9 ")"
[ "$(field "$v" .outcome)" = "PREFLIGHT" ] \
  && ok "a padded but non-empty --judge-model is ACCEPTED (the control: the gate does not refuse everything)" \
  || fail "padded judge-model should be accepted: outcome=$(field "$v" .outcome) judge_model=$(field "$v" .judge_model)"

echo
echo "test_dual_build_preflight: pass=$pass/$total"
[ "$pass" -eq "$total" ] || fail "not all assertions passed"
echo "test_dual_build_preflight: OK"
