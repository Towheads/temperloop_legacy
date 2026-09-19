#!/usr/bin/env bash
#
# test_dual_build_report.sh — fixture suite for
# workflows/scripts/report-producers/dual-build (temperloop#2084, epic
# #2065 "new-work dual-build harness"). Plain mktemp-fixture style, same
# shape as the sibling test_dual_build_ledger.sh (bash 3.2 compatible; no
# mapfile / associative arrays / GNU-only flags).
#
# Builds real ledgers via dual-build-ledger.sh's own `append`/
# `calibrate-record` commands (never hand-shaping rows.jsonl directly), so
# this suite exercises the producer against exactly the row shape the real
# ledger writes.
#
# Sections:
#   1   skip -- invoked with arguments (contract: no-arg producer)
#   2   skip -- no ledger dir at all
#   3   skip -- ledger dir present but rows.jsonl empty/absent
#   4   the 7/10 fixture (acceptance bullet 3): win rate, interval bounds,
#       per-arm cost totals, "below floor - keep accumulating" (n=10 <
#       the default MODEL_COMPARISON_MIN_SAMPLE_N=20)
#   5   calibrated + decisive sample -> a real verdict ("candidate is
#       better")
#   6   uncalibrated (NEVER CALIBRATED) -> "judge uncalibrated - verdict
#       withheld"
#   7   unresolved rate above DUAL_BUILD_UNRESOLVED_THRESHOLD_PCT withholds
#       the verdict the same way (acceptance bullet 2)
#   8   item classification: gate-decided win, judged tie, infra, and
#       both-gates-failed (incomplete) all land in the honesty block, never
#       in the win-rate numerator/denominator
#   9   level-pick tally is override-inclusive and distinct from win_rate
#  10   splits.task_type / splits.seat report {available:false,...} rather
#       than a fabricated number
#  11   exit code is always 0, success or skip alike
#  12   ledger-dir scoping: default-path resolution reads the INVOKING
#       repo's own ledger (cwd-scoped via `git rev-parse --show-toplevel`),
#       and a DIFFERENT repo's cwd never reads it (review round 1 [HIGH])
#
# Usage: bash workflows/scripts/report-producers/tests/test_dual_build_report.sh
set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$HERE/../dual-build"
LEDGER_SH="$HERE/../../model-comparison/dual-build-ledger.sh"

pass=0; total=0
ok()    { pass=$((pass + 1)); printf 'PASS: %s\n' "$1"; }
count() { total=$((total + 1)); }
fail()  { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-dual-build-report.XXXXXX")" || exit 1
WORK="$(cd -P "$WORK" && pwd)"
trap 'chmod -R u+rwX "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

sut() { DUAL_BUILD_LEDGER_DIR="$1" bash "$SUT"; }

# mk_row <slug> <arm> <gate> <preference|-> <pick|-> <loss_reason|->
# Prints one valid ledger row JSON object for `dual-build-ledger.sh append`.
mk_row() {
  local slug="$1" arm="$2" gate="$3" pref="$4" pick="$5" lr="${6:--}"
  local judge="null"
  [ "$pref" != "-" ] && judge="{\"preference\":\"$pref\",\"margin\":10,\"order_agreement\":true}"
  local pickobj="null"
  [ "$pick" != "-" ] && pickobj="{\"arm\":\"$pick\",\"reason\":\"tally\"}"
  local lrjson="null"
  [ "$lr" != "-" ] && lrjson="\"$lr\""
  jq -cn --arg slug "$slug" --arg arm "$arm" --arg gate "$gate" --argjson judge "$judge" \
    --argjson pick "$pickobj" --argjson lr "$lrjson" '
    {tier:"sonnet", model: (if $arm=="baseline" then "claude-opus-4-8" else "claude-sonnet-5" end),
     slug:$slug, arm:$arm, base_sha:"aaa111", head_sha:("h_"+$slug+"_"+$arm), start_order:1, gate:$gate,
     cost:{tokens_in:100, tokens_out:50, wall_clock_ms:1000, retry_tokens:0, retry_count:0, recovery:false},
     judge:$judge, pick:$pick, override:{applied:false, scope:null, reason:null},
     loss_reason:$lr,
     cross_read_attempted:false, guard_armed:"ARMED", machinery_version:"1.0.0"}'
}

# append <ledger_dir> <slug> <arm> <gate> <pref> <pick> [loss_reason]
append() {
  local dir="$1"; shift
  mk_row "$@" | bash "$LEDGER_SH" append --dir "$dir" --row - >/dev/null
}

# ── 1. skip -- invoked with arguments ──────────────────────────────────────
count
out="$(bash "$SUT" --whatever 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "skipped -- dual-build: invoked with 1 argument(s); the .temperloop/report.d/ contract invokes a producer with none" ]; then
  ok "1: skip on unexpected arguments"
else
  fail "1: expected the arg-count skip line and exit 0, got rc=$rc out=$out"
fi

# ── 2. skip -- no ledger dir at all ─────────────────────────────────────────
count
out="$(sut "$WORK/nope" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [[ "$out" == "skipped -- dual-build: no ledger rows found"* ]]; then
  ok "2: skip on absent ledger dir"
else
  fail "2: expected a no-rows skip and exit 0, got rc=$rc out=$out"
fi

# ── 3. skip -- ledger dir present, no rows ──────────────────────────────────
count
mkdir -p "$WORK/empty"
out="$(sut "$WORK/empty" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [[ "$out" == "skipped -- dual-build: no ledger rows found"* ]]; then
  ok "3: skip on empty ledger dir"
else
  fail "3: expected a no-rows skip and exit 0, got rc=$rc out=$out"
fi

# ── 4. the 7/10 fixture ─────────────────────────────────────────────────────
D4="$WORK/d4"
for i in 1 2 3 4 5 6 7; do
  append "$D4" "item$i" baseline pass candidate candidate
  append "$D4" "item$i" candidate pass candidate candidate
done
for i in 8 9 10; do
  append "$D4" "item$i" baseline pass baseline baseline
  append "$D4" "item$i" candidate pass baseline baseline
done
out="$(sut "$D4" 2>&1)"; rc=$?
count
[ "$rc" -eq 0 ] && jq -e . >/dev/null 2>&1 <<<"$out" && ok "4a: exits 0 and prints one JSON object" || fail "4a: rc=$rc out=$out"

count
wr="$(jq '.tiers[0].win_rate' <<<"$out")"
[ "$(jq '.candidate_wins' <<<"$wr")" = "7" ] && [ "$(jq '.baseline_wins' <<<"$wr")" = "3" ] \
  && [ "$(jq '.resolved' <<<"$wr")" = "10" ] && [ "$(jq '.candidate_win_pct' <<<"$wr")" = "70" ] \
  && ok "4b: win rate is 7/10 (70%)" || fail "4b: unexpected win_rate: $wr"

count
interval="$(jq '.interval' <<<"$wr")"
[ "$(jq '.n' <<<"$interval")" = "10" ] && [ "$(jq '.k' <<<"$interval")" = "7" ] \
  && [ "$(jq '.lower > 0.3 and .lower < 0.4' <<<"$interval")" = "true" ] \
  && [ "$(jq '.upper > 0.9 and .upper < 0.95' <<<"$interval")" = "true" ] \
  && ok "4c: exact-binom interval bounds match the fixture (n=10,k=7)" || fail "4c: unexpected interval: $interval"

count
cost="$(jq '.tiers[0].cost' <<<"$out")"
[ "$(jq '.baseline.tokens_in' <<<"$cost")" = "1000" ] && [ "$(jq '.baseline.tokens_out' <<<"$cost")" = "500" ] \
  && [ "$(jq '.candidate.tokens_in' <<<"$cost")" = "1000" ] && [ "$(jq '.candidate.tokens_out' <<<"$cost")" = "500" ] \
  && ok "4d: per-arm cost totals match the fixture (10 items x 100/50 tokens)" || fail "4d: unexpected cost: $cost"

count
[ "$(jq -r '.tiers[0].verdict' <<<"$out")" = "below floor - keep accumulating" ] \
  && ok "4e: below the default MODEL_COMPARISON_MIN_SAMPLE_N floor (10 < 20)" \
  || fail "4e: expected the below-floor verdict, got $(jq -r '.tiers[0].verdict' <<<"$out")"

# ── 5. calibrated + decisive sample -> a real verdict ──────────────────────
D5="$WORK/d5"
for i in $(seq 1 18); do
  append "$D5" "w$i" baseline pass candidate candidate
  append "$D5" "w$i" candidate pass candidate candidate
done
for i in 19 20; do
  append "$D5" "w$i" baseline pass baseline baseline
  append "$D5" "w$i" candidate pass baseline baseline
done
for i in $(seq 1 20); do
  pref=candidate; [ "$i" -gt 18 ] && pref=baseline
  bash "$LEDGER_SH" calibrate-record --dir "$D5" --slug "w$i" --preference "$pref" >/dev/null
done
out5="$(sut "$D5" 2>&1)"; rc=$?
count
[ "$rc" -eq 0 ] && [ "$(jq -r '.calibration.status' <<<"$out5")" = "calibrated" ] \
  && [ "$(jq -r '.tiers[0].verdict' <<<"$out5")" = "candidate is better" ] \
  && ok "5: calibrated + 18/20 decisive win rate mints a real verdict" \
  || fail "5: rc=$rc out=$out5"

# ── 6. uncalibrated withholds the verdict ───────────────────────────────────
D6="$WORK/d6"
for i in $(seq 1 18); do
  append "$D6" "w$i" baseline pass candidate candidate
  append "$D6" "w$i" candidate pass candidate candidate
done
for i in 19 20; do
  append "$D6" "w$i" baseline pass baseline baseline
  append "$D6" "w$i" candidate pass baseline baseline
done
out6="$(sut "$D6" 2>&1)"; rc=$?
count
[ "$rc" -eq 0 ] && [ "$(jq -r '.calibration.status' <<<"$out6")" = "NEVER CALIBRATED" ] \
  && [ "$(jq -r '.tiers[0].verdict' <<<"$out6")" = "judge uncalibrated - verdict withheld" ] \
  && ok "6: an uncalibrated judge withholds the verdict even at a decisive, above-floor sample" \
  || fail "6: rc=$rc out=$out6"

# ── 7. unresolved rate above the threshold withholds the verdict too ───────
# Same calibrated corpus as §5 plus enough judged ties to push the
# unresolved rate over DUAL_BUILD_UNRESOLVED_THRESHOLD_PCT (default 20%).
D7="$WORK/d7"
for i in $(seq 1 18); do
  append "$D7" "w$i" baseline pass candidate candidate
  append "$D7" "w$i" candidate pass candidate candidate
done
for i in 19 20; do
  append "$D7" "w$i" baseline pass baseline baseline
  append "$D7" "w$i" candidate pass baseline baseline
done
for i in 21 22 23 24 25 26; do
  append "$D7" "t$i" baseline pass tie -
  append "$D7" "t$i" candidate pass tie -
done
for i in $(seq 1 20); do
  pref=candidate; [ "$i" -gt 18 ] && pref=baseline
  bash "$LEDGER_SH" calibrate-record --dir "$D7" --slug "w$i" --preference "$pref" >/dev/null
done
out7="$(sut "$D7" 2>&1)"; rc=$?
count
unresolved_pct="$(jq -r '.tiers[0].honesty.unresolved_rate_pct' <<<"$out7")"
[ "$rc" -eq 0 ] && [ "$(jq -r '.calibration.status' <<<"$out7")" = "calibrated" ] \
  && [ "$unresolved_pct" -gt 20 ] \
  && [ "$(jq -r '.tiers[0].verdict' <<<"$out7")" = "judge uncalibrated - verdict withheld" ] \
  && ok "7: an unresolved rate ($unresolved_pct%) above the threshold withholds the verdict the same way" \
  || fail "7: rc=$rc unresolved_pct=$unresolved_pct out=$out7"

# ── 8. item classification: gate-decided, tied, infra, incomplete ──────────
D8="$WORK/d8"
append "$D8" itemA baseline pass - baseline gate
append "$D8" itemA candidate fail - baseline gate
append "$D8" itemB baseline pass tie - -
append "$D8" itemB candidate pass tie - -
append "$D8" itemC baseline pass - - infra
append "$D8" itemC candidate pass - - infra
append "$D8" itemD baseline fail - - incomplete
append "$D8" itemD candidate fail - - incomplete
append "$D8" itemE baseline pass candidate candidate -
append "$D8" itemE candidate pass candidate candidate -
out8="$(sut "$D8" 2>&1)"; rc=$?
count
wr8="$(jq '.tiers[0].win_rate' <<<"$out8")"
honesty8="$(jq '.tiers[0].honesty' <<<"$out8")"
[ "$rc" -eq 0 ] \
  && [ "$(jq '.baseline_wins' <<<"$wr8")" = "1" ] && [ "$(jq '.candidate_wins' <<<"$wr8")" = "1" ] \
  && [ "$(jq '.resolved' <<<"$wr8")" = "2" ] \
  && [ "$(jq '.unresolved_count' <<<"$honesty8")" = "3" ] \
  && [ "$(jq '.unresolved_breakdown.tied' <<<"$honesty8")" = "1" ] \
  && [ "$(jq '.unresolved_breakdown.infra' <<<"$honesty8")" = "1" ] \
  && [ "$(jq '.unresolved_breakdown.incomplete' <<<"$honesty8")" = "1" ] \
  && ok "8: gate-decided/tied/infra/incomplete classify correctly and stay out of win_rate's own numerator/denominator" \
  || fail "8: rc=$rc win_rate=$wr8 honesty=$honesty8"

# ── 9. level-pick tally is override-inclusive and distinct from win_rate ───
D9="$WORK/d9"
# itemF: candidate wins the judge call, but the operator OVERRODE it to
# baseline for this one item (ADR 0038 lever (i)) — pick disagrees with win.
mk_row itemF baseline pass candidate baseline - | jq -c '.override = {applied:true, scope:"item", reason:"operator override"}' \
  | bash "$LEDGER_SH" append --dir "$D9" --row - >/dev/null
mk_row itemF candidate pass candidate baseline - | jq -c '.override = {applied:true, scope:"item", reason:"operator override"}' \
  | bash "$LEDGER_SH" append --dir "$D9" --row - >/dev/null
out9="$(sut "$D9" 2>&1)"; rc=$?
count
tally9="$(jq '.tiers[0].level_pick_tally' <<<"$out9")"
wr9="$(jq '.tiers[0].win_rate' <<<"$out9")"
override9="$(jq '.tiers[0].override' <<<"$out9")"
[ "$rc" -eq 0 ] \
  && [ "$(jq '.candidate_wins' <<<"$wr9")" = "1" ] \
  && [ "$(jq '.baseline' <<<"$tally9")" = "1" ] && [ "$(jq '.candidate' <<<"$tally9")" = "0" ] \
  && [ "$(jq '.count' <<<"$override9")" = "1" ] \
  && ok "9: the level-pick tally reflects the override even though win_rate (override-blind) still credits the candidate" \
  || fail "9: rc=$rc tally=$tally9 win_rate=$wr9 override=$override9"

# ── 10. splits report unavailable rather than a fabricated number ──────────
count
splits="$(jq '.tiers[0].splits' <<<"$out")"
[ "$(jq '.task_type.available' <<<"$splits")" = "false" ] && [ "$(jq '.seat.available' <<<"$splits")" = "false" ] \
  && [ -n "$(jq -r '.task_type.reason' <<<"$splits")" ] && [ -n "$(jq -r '.seat.reason' <<<"$splits")" ] \
  && ok "10: task_type/seat splits are honestly reported unavailable, never fabricated" \
  || fail "10: unexpected splits: $splits"

# ── 11. exit code is always 0 ───────────────────────────────────────────────
count
rc_ok=1
for d in "$WORK/nope" "$D4" "$D5" "$D6" "$D7" "$D8" "$D9"; do
  sut "$d" >/dev/null 2>&1 || rc_ok=0
done
[ "$rc_ok" -eq 1 ] && ok "11: every scenario above exits 0 (skip and success alike)" || fail "11: a scenario exited non-zero"

# ── 12. ledger-dir scoping: read from the INVOKING repo, not $0 ────────────
# review round 1 [HIGH]: the producer used to resolve LEDGER_DIR/REPO_LABEL
# by climbing from its own $0 location -- always the KERNEL checkout under
# the .temperloop/report.d shim -- so every adopter repo silently read (or,
# once the kernel dogfoods --dual-build, would silently RENDER) the
# kernel's own ledger under its own heading, regardless of invocation cwd.
# Two throwaway git repos, each with its OWN default-location ledger,
# discriminate the fix directly: repo A's rows must be visible only from
# repo A's cwd, never leaking to repo B's.
REPO_A="$WORK/repoA"; REPO_B="$WORK/repoB"
mkdir -p "$REPO_A" "$REPO_B"
( cd "$REPO_A" && git init -q )
( cd "$REPO_B" && git init -q )
append "$REPO_A/.temperloop/model-comparison/dual-build" only1 baseline pass candidate candidate
append "$REPO_A/.temperloop/model-comparison/dual-build" only1 candidate pass candidate candidate

count
outA="$(cd "$REPO_A" && env -u DUAL_BUILD_LEDGER_DIR bash "$SUT" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && [ "$(jq -r '.repo' <<<"$outA" 2>/dev/null)" = "repoA" ] \
  && [ "$(jq -r '.tiers[0].honesty.total_dual_built_items' <<<"$outA" 2>/dev/null)" = "1" ] \
  && ok "12a: default-path resolution reads repo A's OWN ledger when cwd=repo A" \
  || fail "12a: rc=$rc outA=$outA"

count
outB="$(cd "$REPO_B" && env -u DUAL_BUILD_LEDGER_DIR bash "$SUT" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && [[ "$outB" == "skipped -- dual-build: no ledger rows found"* ]] \
  && ok "12b: default-path resolution from a DIFFERENT repo's cwd (repo B) does not read repo A's ledger" \
  || fail "12b: rc=$rc outB=$outB"

echo
echo "== $pass/$total passed =="
[ "$pass" -eq "$total" ] || exit 1
