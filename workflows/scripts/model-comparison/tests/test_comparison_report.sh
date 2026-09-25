#!/usr/bin/env bash
#
# test_comparison_report.sh — fixture suite for the COMPARISON REPORT producer
# (temperloop#1261, epic #1225 "model comparison harness"):
# workflows/scripts/report-producers/model-comparison.
#
# ── WHAT THIS SUITE IS DEFENDING ───────────────────────────────────────────
# The producer is the surface a human reads to make a model-routing decision,
# so the failure mode that matters is not "a wrong number" but "a number that
# looks trustworthy and is not". Four guarantees carry that weight, and each
# one here is proved by BREAKING it and watching the suite go red, not merely
# by observing it hold:
#
#   1. Below the configured sample floor the report says `inconclusive` and
#      names NO winner. Proved twice over: remove the producer's own winner
#      gate and a winner appears; and, separately, remove the floor inside
#      stats.py itself and a winner appears through the unmodified producer —
#      so the producer is shown to ride the library's floor rather than a
#      private re-implementation of it.
#   2. The four honesty disclosures — emit-coverage %, corpus window, gate
#      versions, cost basis — appear on a FLATTERING run, not only a degraded
#      one. Each is deleted from a passing report in turn and the assertion
#      that guards it must go red.
#   3. A degraded run emits NO fabricated figure: no `winner` key and no cost
#      figure anywhere, while still exiting 0 with a single `skipped -- ` line.
#      Proved by rewriting the producer's own degradation path to emit a
#      fabricated object and watching the assertion catch it.
#   4. Every statistic is CONSUMED from stats.sh, never recomputed here. The
#      published CI and MDE must be byte-identical to an independent stats.sh
#      call over the producer's own published delta array; a mutation that
#      nudges the published bound by 5% must go red.
#   5. ARM ORDER is disclosed and its effect ESTIMATED (temperloop#1571,
#      section M). Arm used to be perfectly confounded with execution
#      position; the report must now say whether the order was counterbalanced,
#      publish the order effect beside the arm effect against a known-answer
#      fixture, and withhold a bare winner when the two are comparable —
#      proved by neutering that gate and watching the winner reappear.
#
# ── HERMETIC BY CONSTRUCTION ───────────────────────────────────────────────
# Zero network, zero model calls, zero writes outside $TMPDIR. Section L is a
# suite-wide canary: `claude`, `gh`, `curl` and `wget` stand-ins are prepended
# to PATH for the whole run and must never be invoked by anything under test.
# Section L2 proves the canary can actually fire, so L1 is a measurement
# rather than a tautology.
#
# ── MUTATION MECHANISM ─────────────────────────────────────────────────────
# `mkmirror` builds a throwaway tree whose layout satisfies the producer's own
# sibling-relative resolution ($0/../model-comparison, ../build, ../config),
# with the model-comparison module and the pricing config COPIED (so they can
# be mutated) and build/lib SYMLINKED (so nothing under test resolves against
# a stale duplicate of the real config). Nothing in the real tree is ever
# written.
#
# Usage: bash workflows/scripts/model-comparison/tests/test_comparison_report.sh
#
# shellcheck disable=SC2016
#
# Blanket shellcheck exemptions, each with its reason:
#   SC2016  jq filters are single-quoted on purpose; $foo inside one is a jq
#           variable, never a shell one.
#   SC2030/SC2031  several tests deliberately export a setting inside a ( … )
#           subshell so the override applies to exactly one producer run and
#           cannot leak into the next assertion. The "change might be lost"
#           warning is the intended behaviour here, not a bug.
#   SC2089/SC2090  the fabrication mutation in section E carries literal
#           backslash-escaped quotes because its value IS shell source text
#           being injected into a mirrored script; an array would defeat the
#           point.
# shellcheck disable=SC2030,SC2031,SC2089,SC2090

set -uo pipefail

# Physical derivation (`cd -P`) — dir-symlink-composition-safe (temperloop#1557).
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MC_DIR="$(cd -P "$HERE/.." && pwd)"
SCRIPTS_DIR="$(cd -P "$MC_DIR/.." && pwd)"
PRODUCER="$SCRIPTS_DIR/report-producers/model-comparison"
STATS="$MC_DIR/stats.sh"

# shellcheck source=../../lib/portable-timeout.sh
. "$SCRIPTS_DIR/lib/portable-timeout.sh"

pass=0
total=0
ok() { pass=$((pass + 1)); echo "PASS: $1"; }
count() { total=$((total + 1)); }
fail() { echo "FAIL: $1" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-comparison-report-XXXXXX")"
WORK="$(cd -P "$WORK" && pwd)"
trap 'chmod -R u+rwX "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

# ═══════════════════════════════════════════════════════════════════════════
# THE CANARIES — network/model entry points no test may ever reach.
# ═══════════════════════════════════════════════════════════════════════════
CANARY="$WORK/CANARY"
mkdir -p "$WORK/bin"
for tool in claude gh curl wget; do
  cat >"$WORK/bin/$tool" <<EOF
#!/usr/bin/env bash
printf 'INVOKED %s %s\n' "$tool" "\$*" >>"$CANARY"
exit 0
EOF
  chmod +x "$WORK/bin/$tool"
done
PATH="$WORK/bin:$PATH"
export PATH

# ═══════════════════════════════════════════════════════════════════════════
# HELPERS
# ═══════════════════════════════════════════════════════════════════════════

# mkrepo <dir> — a stand-in "target repo": the cwd shape report.sh hands a
# producer, carrying the records dir and an empty attribution raw lake.
mkrepo() {
  rm -rf "$1"
  mkdir -p "$1/.temperloop/model-comparison" "$1/meta/data/raw"
}

# record <pr> <arm-model> <input-tokens> <output-tokens> <verdict> <gate-passed>
#        <judge-outcome> <quality-score> <prepared-day> <outcome> [judge-notice]
# Emits ONE replay-record-v1-shaped line. This is INPUT DATA only — no figure
# the producer computes is recomputed here.
record() {
  local pr="$1" model="$2" inp="$3" outp="$4" verdict="$5" gate="$6" \
        jout="$7" qs="$8" day="$9" outcome="${10}" jnotice="${11:-}"
  local tokens='null' scoreobj judgeobj interr='null'
  if [ "$outcome" = "scored" ]; then
    tokens="$(jq -cn --argjson i "$inp" --argjson o "$outp" \
      '{input:$i, output:$o, cache_read:2000, cache_creation:100}')"
    scoreobj="$(jq -cn --arg v "$verdict" --argjson g "$gate" \
      '{outcome:"SCORED", scored:true, verdict:$v, not_scored_reason:null,
        base:"base0001", truth_head:"head0001", diff:null,
        gate_result:{outcome:"GATES", ran:true, gate_script:"scripts/quality-gates.sh",
                     exit_code:(if $g then 0 else 1 end), passed:$g,
                     timed_out:false, duration_ms:1000, timeout_secs:1800},
        acceptance_results:[], components:null, contamination_flags:[]}')"
  else
    scoreobj='{"outcome":"NOT_SCORED","scored":false,"verdict":null,"not_scored_reason":"integration-error","base":null,"truth_head":null,"diff":null,"gate_result":null,"acceptance_results":null,"components":null,"contamination_flags":[]}'
    interr='{"stage":"candidate-timeout","detail":"the candidate run exceeded its wall-clock bound"}'
  fi
  case "$jout" in
    none) judgeobj='null' ;;
    JUDGED) judgeobj="$(jq -cn --argjson q "$qs" '{outcome:"JUDGED", scored:true, quality_score:$q, dimensions:{}, rationale:"r", concerns:[], judge_provider:"anthropic", judge_model:"claude-opus-4-8", tokens:null, duration_ms:10, disclosed:false, prompt_sha256:"bb", guard:{enforced:true}, evaluated_at:"2026-08-20T00:00:00Z"}')" ;;
    *) judgeobj="$(jq -cn --arg o "$jout" --arg n "$jnotice" '{outcome:$o, scored:false, quality_score:null, dimensions:null, rationale:null, concerns:[], judge_provider:"anthropic", judge_model:"claude-opus-4-8", degradation_notice:$n, tokens:null, duration_ms:0, disclosed:false, prompt_sha256:"bb", guard:{enforced:true}, evaluated_at:"2026-08-20T00:00:00Z"}')" ;;
  esac
  jq -cn --argjson pr "$pr" --arg model "$model" --argjson tokens "$tokens" \
    --argjson score "$scoreobj" --argjson judge "$judgeobj" \
    --argjson interr "$interr" --arg outcome "$outcome" \
    --argjson dur "$((60000 + inp))" --arg day "$day" '
    {pr:$pr, issue:($pr - 100), merge_commit:"mc0001", base:"base0001", head:"head0001",
     title:"item \($pr)", scope:null, acceptance:["does a thing"], notes:"",
     status:"eligible", reject_reason:"", flags:[],
     buckets:{N:["a.sh"], T:["tests/t.sh"], X:[], R:[]},
     template_sha:"tpl0000", file_count:2,
     worktree:{path:"/tmp/wt", branch:"replay/\($pr)", prepared_at:($day + "T10:00:00Z")},
     candidate:{provider:"anthropic", model:$model, diff_ref:"cafe",
                tokens:$tokens, duration_ms:$dur, outcome:$outcome,
                integration_error:$interr, disclosed:false, prompt_sha256:"aa"},
     score:$score}
    | if $judge == null then . else . + {judge:$judge} end'
}

# fill <file> <model> <n> <base-input> <jitter> — n scored+passing+judged
# records with a deterministic, VARYING cost profile (a constant profile has
# zero variance, which is a genuinely different statistical case and is
# covered separately in section E).
# [qoffset] shifts every judged score by a constant (default 0). Needed since
# temperloop#1606: the winner is minted from the QUALITY axis, so a fixture
# whose two arms judge IDENTICALLY can never name one, and the floor/mutation
# proofs below would pass for the wrong reason.
fill() {
  local file="$1" model="$2" n="$3" base="$4" jit="$5" qoff="${6:-0}" i=0 inp day
  : >"$file"
  while [ "$i" -lt "$n" ]; do
    inp=$(( base + i * 7 + (i % 7) * jit ))
    day="$(printf '2026-08-%02d' $(( (i % 20) + 1 )))"
    # A NON-ZERO qoff also varies per record. A constant offset makes every
    # quality delta identical, and stats.sh correctly refuses a zero-variance
    # array as `degenerate` — so a fixture built that way can never mint a
    # winner, and every proof that needs one would pass for the wrong reason.
    local qvar=0
    [ "$qoff" -ne 0 ] && qvar=$(( i % 3 ))
    record $(( 1000 + i )) "$model" "$inp" $(( 100 + (i % 5) * 3 )) pass true \
      JUDGED $(( 70 + (i % 11) + qoff + qvar )) "$day" scored >>"$file"
    i=$(( i + 1 ))
  done
}

# lake <repo> <seat>... — write an attribution raw-lake month file naming the
# given seats.
lake() {
  local repo="$1"; shift
  local f="$repo/meta/data/raw/model-usage-2026-08.jsonl"
  : >"$f"
  local s
  for s in "$@"; do
    jq -cn --arg s "$s" '{schema_version:"1", ts:"2026-08-05T00:00:00Z", session_id:"s1",
      repo:"o/r", seat:$s, model:"claude-haiku-4-5", provider:"anthropic",
      usage_source:"cli-envelope", tokens:{input:1,output:1,cache_read:0,cache_creation:0},
      weighted_units:6, duration_ms:10, outcome_ref:"issue:1"}' >>"$f"
  done
}

# run <repo> [producer] — run the producer with cwd = <repo>. Stdout lands in
# $RUN_OUT, exit status in $RUN_RC. Bounded, so a hang fails rather than
# stalls the suite.
RUN_OUT=""; RUN_RC=0
run() {
  local repo="$1" prod="${2:-$PRODUCER}"
  RUN_OUT="$WORK/run.out"
  ( cd "$repo" && run_with_timeout 120 bash "$prod" ) >"$RUN_OUT" 2>"$WORK/run.err"
  RUN_RC=$?
}

# mkmirror <dest> — a mutable copy of the producer plus the sibling layout its
# own $0-relative resolution needs.
mkmirror() {
  local dest="$1"
  rm -rf "$dest"
  mkdir -p "$dest/workflows/scripts/report-producers" "$dest/workflows/scripts/config"
  cp "$PRODUCER" "$dest/workflows/scripts/report-producers/model-comparison"
  chmod +x "$dest/workflows/scripts/report-producers/model-comparison"
  # `-L` (dereference): in a composed overlay tree that vendors this kernel
  # as a subtree, individual files under model-comparison/ can be RELATIVE
  # symlinks into the vendored kernel/ copy (e.g. foundation: .../model-
  # comparison/stats.sh -> ../../../kernel/workflows/scripts/model-
  # comparison/stats.sh). A plain `cp -R` preserves a symlink AS a symlink
  # rather than copying its target's content, so once this mirror lands in
  # an unrelated scratch dir with no kernel/ sibling at the right relative
  # depth, that symlink goes dangling — the mirrored stats.sh then resolves
  # to nothing, the producer's own defensive "comparison-statistics library
  # is missing" skip fires, and the suite's mutation assertions fail before
  # ever reaching the mutated code (verified: reproducing this exact
  # relative-symlink + cp -R + relocate sequence produces a dangling link;
  # `cp -RL` copies the real content and resolves correctly regardless of
  # relocation). `-L` is a no-op when $MC_DIR is already real files (the
  # kernel's own checkout), so this keeps the suite's mutation coverage LIVE
  # for a vendoring consumer instead of it silently degrading before the
  # mutated code is ever reached (temperloop#1490).
  cp -RL "$MC_DIR" "$dest/workflows/scripts/model-comparison"
  cp "$SCRIPTS_DIR/config/default-pricing.json" "$dest/workflows/scripts/config/default-pricing.json"
  ln -s "$SCRIPTS_DIR/build" "$dest/workflows/scripts/build"
  ln -s "$SCRIPTS_DIR/lib" "$dest/workflows/scripts/lib"
  printf '%s\n' "$dest/workflows/scripts/report-producers/model-comparison"
}

# jqf <file> <filter> — read one raw value out of a JSON file.
jqf() { jq -r "$2" "$1" 2>/dev/null; }

# ═══════════════════════════════════════════════════════════════════════════
# THE FLATTERING RUN — the baseline every honesty assertion is checked against
# ═══════════════════════════════════════════════════════════════════════════
# Deliberately the run that looks GOOD: every record scored, every gate green,
# every row judged, a clean statistically-significant win for the candidate.
# If a disclosure can be dropped anywhere, this is the run where nobody would
# notice.
FLAT="$WORK/flattering"
mkrepo "$FLAT"
fill "$FLAT/.temperloop/model-comparison/baseline.jsonl"  claude-opus-4-8  24 5000 0
fill "$FLAT/.temperloop/model-comparison/candidate.jsonl" claude-sonnet-5  24 4200 90 8
lake "$FLAT" pipeline-drive-safe retro-judge

run "$FLAT"
FLAT_OUT="$WORK/flattering.json"
cp "$RUN_OUT" "$FLAT_OUT"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION A — the .temperloop/report.d/ drop-in contract
# ═══════════════════════════════════════════════════════════════════════════

count
[ "$RUN_RC" -eq 0 ] || fail "A1: the producer must exit 0 on a good run, got $RUN_RC"
ok "A1 exit 0 on a good run"

count
jq -e 'type == "object"' "$FLAT_OUT" >/dev/null 2>&1 \
  || fail "A2: stdout must parse as a single JSON object"
[ "$(jq -s 'length' "$FLAT_OUT" 2>/dev/null)" = "1" ] \
  || fail "A2: stdout must be EXACTLY ONE JSON document, not several"
ok "A2 stdout is exactly one JSON object"

count
# The kernel reserves `notice` globally and scopes tokens_spent/by_model to the
# producer literally named `tokens` (report.contract.md § Reserved top-level
# keys). This producer must carry the first and never the second pair, or it
# could hijack the headline spend figure ADR 0020 owns.
jq -e '(.notice | type) == "string"' "$FLAT_OUT" >/dev/null 2>&1 \
  || fail "A3: the report must carry a string notice field — its only human channel"
[ "$(jqf "$FLAT_OUT" '.notice | contains("\n")')" = "false" ] \
  || fail "A3: the notice field must be a SINGLE-LINE string (report.contract.md leaves an embedded newline undefined)"
jq -e 'has("tokens_spent") or has("by_model") | not' "$FLAT_OUT" >/dev/null 2>&1 \
  || fail "A3: this producer must NOT emit tokens_spent/by_model — those are scoped to the producer named 'tokens' and drive the headline spend figure"
ok "A3 uses the reserved single-line notice channel and never the tokens-scoped headline keys"

count
# Additive by construction: the tokens producer's own slot format is untouched
# because this producer writes a DIFFERENT file under a DIFFERENT name, and the
# kernel ships no .temperloop/report.d/ shim for it (ADR 0027, inert by design).
[ -f "$SCRIPTS_DIR/report-producers/tokens" ] \
  || fail "A4: the tokens producer must still exist"
[ ! -e "$SCRIPTS_DIR/../../.temperloop/report.d/model-comparison" ] \
  || fail "A4: the kernel must ship NO .temperloop/report.d/model-comparison shim — arming it in every install is exactly the standing cost ADR 0027 forbids"
ok "A4 additive only: the tokens producer is untouched and this producer ships un-armed"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION B — the metrics the acceptance names
# ═══════════════════════════════════════════════════════════════════════════

count
for k in cost judge_quality gate_outcomes intervention_rework duration quality compatibility; do
  jq -e --arg k "$k" '.arms.baseline | has($k)' "$FLAT_OUT" >/dev/null 2>&1 \
    || fail "B1: the baseline arm is missing the '$k' block"
  jq -e --arg k "$k" '.arms.candidate | has($k)' "$FLAT_OUT" >/dev/null 2>&1 \
    || fail "B1: the candidate arm is missing the '$k' block"
done
ok "B1 both arms carry cost, judge quality, gate outcomes, intervention/rework, duration, and score.sh's quality/compatibility split"

count
[ "$(jqf "$FLAT_OUT" '.arms.candidate.cost.cost_per_merged_outcome | type')" = "number" ] \
  || fail "B2: a fully-scored arm must report a whole-job cost per merged outcome"
[ "$(jqf "$FLAT_OUT" '.arms.candidate.cost.merged_outcomes_n')" = "24" ] \
  || fail "B2: merged_outcomes_n should count the 24 passing records"
ok "B2 whole-job cost per merged outcome is reported on a fully-scored arm"

count
# The quality/compatibility split is score.sh's, embedded verbatim — asserted
# by comparing against an independent score.sh aggregate call, so a future
# re-derivation here would diverge and fail.
indep_q="$(bash "$MC_DIR/score.sh" aggregate --records-file "$FLAT/.temperloop/model-comparison/candidate.jsonl" 2>/dev/null | jq -c '.quality')"
mine_q="$(jq -c '.arms.candidate.quality' "$FLAT_OUT")"
[ -n "$indep_q" ] && [ "$indep_q" = "$mine_q" ] \
  || fail "B3: the arm's quality block must be score.sh aggregate's own, byte-identical (independent: $indep_q; reported: $mine_q)"
ok "B3 the scored-only quality split is score.sh's own output, not re-derived here"

count
# The weights are CONSUMED from the SPEND_WEIGHT_* settings, not hardcoded.
# Non-default weights are exported and the expected total is hand-computed:
# one record with input=5000, output=100, cache_read=2000, cache_creation=100
# under weights 2 / 0.5 / 2 / 10 is 5000*2 + 2000*0.5 + 100*2 + 100*10
# = 10000 + 1000 + 200 + 1000 = 12200.
WREPO="$WORK/weights"
mkrepo "$WREPO"
record 1001 claude-sonnet-5 5000 100 pass true JUDGED 80 2026-08-01 scored \
  >"$WREPO/.temperloop/model-comparison/candidate.jsonl"
record 1001 claude-opus-4-8 5000 100 pass true JUDGED 80 2026-08-01 scored \
  >"$WREPO/.temperloop/model-comparison/baseline.jsonl"
(
  export SPEND_WEIGHT_INPUT=2 SPEND_WEIGHT_CACHE_READ=0.5 \
         SPEND_WEIGHT_CACHE_CREATE=2 SPEND_WEIGHT_OUTPUT=10
  run "$WREPO"
  cp "$RUN_OUT" "$WORK/weights.json"
)
[ "$(jqf "$WORK/weights.json" '.arms.candidate.cost.total_weighted_units')" = "12200" ] \
  || fail "B4: expected the hand-computed 12200 cost-weighted units under the exported non-default weights, got $(jqf "$WORK/weights.json" '.arms.candidate.cost.total_weighted_units')"
[ "$(jqf "$WORK/weights.json" '.cost_basis.weights.output')" = "10" ] \
  || fail "B4: the report must state the weights it actually used"
ok "B4 cost weighting consumes the configured SPEND_WEIGHT_* values (hand-computed 12200 under non-default weights)"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION C — THE HONESTY DISCLOSURES, ON A FLATTERING RUN
# ═══════════════════════════════════════════════════════════════════════════
# assert_disclosures <json-file> — the four disclosures the acceptance names.
# Returns non-zero (quietly) when any is absent, so it can be pointed at a
# deliberately-mutilated report to prove it actually notices.
assert_disclosures() {
  local f="$1"
  # 1. emit-coverage percentage, with its feasible-seat denominator.
  jq -e '(.emit_coverage.coverage_pct | type) == "number"' "$f" >/dev/null 2>&1 || return 1
  jq -e '(.emit_coverage.feasible_seats | type) == "number"' "$f" >/dev/null 2>&1 || return 1
  jq -e '(.emit_coverage.excluded_seats | type) == "array" and (.emit_coverage.excluded_seats | length) > 0' "$f" >/dev/null 2>&1 || return 1
  # 2. corpus window.
  jq -e '(.corpus_window | type) == "object"' "$f" >/dev/null 2>&1 || return 1
  jq -e '(.corpus_window.replayed_from_utc | type) == "string"' "$f" >/dev/null 2>&1 || return 1
  jq -e '(.corpus_window.records_n | type) == "number"' "$f" >/dev/null 2>&1 || return 1
  # 3. gate versions.
  jq -e '(.gate_versions | type) == "object"' "$f" >/dev/null 2>&1 || return 1
  jq -e '(.gate_versions.distinct_n | type) == "number"' "$f" >/dev/null 2>&1 || return 1
  jq -e '(.gate_versions.pairs | type) == "array"' "$f" >/dev/null 2>&1 || return 1
  # 4. cost basis — named as one of the three units, not merely present.
  jq -e '(.cost_basis.unit | type) == "string"' "$f" >/dev/null 2>&1 || return 1
  jq -e '.cost_basis.statement | test("METERED DOLLARS")' "$f" >/dev/null 2>&1 || return 1
  jq -e '.cost_basis.statement | test("SUBSCRIPTION-USAGE SHARE")' "$f" >/dev/null 2>&1 || return 1
  jq -e '.cost_basis.statement | test("TOKEN COUNTS")' "$f" >/dev/null 2>&1 || return 1
  return 0
}

count
assert_disclosures "$FLAT_OUT" \
  || fail "C1: the four honesty disclosures must all be present on a FLATTERING run"
ok "C1 coverage %, corpus window, gate versions and cost basis all appear on a flattering run"

count
# MUTATION PROOF — delete each disclosure in turn from the passing report and
# require the assertion to notice. Renaming would prove less; these are real
# deletions of the published key.
for key in emit_coverage corpus_window gate_versions cost_basis; do
  jq --arg k "$key" 'del(.[$k])' "$FLAT_OUT" >"$WORK/mutilated.json"
  if assert_disclosures "$WORK/mutilated.json"; then
    fail "C2: deleting .$key from the report left the disclosure assertion GREEN — the assertion is not load-bearing"
  fi
done
ok "C2 mutation proof: deleting each of the four disclosures in turn turns the assertion RED"

count
# The cost basis must name WHICH unit, and must not claim to be the two units
# it is not. A report that showed a dollar figure without saying it is a list-
# price estimate would let a reader compare it to an invoice. Since
# temperloop#1380 the unit string is also the one the replay spend gate
# authorizes a batch in — "token-counts" named the family but not the unit,
# and the gate, reading the same word, meant a RAW sum. The AGREEMENT between
# the two surfaces is pinned in test_replay_preflight_cost_unit.sh; this line
# pins this producer's half of it.
[ "$(jqf "$FLAT_OUT" '.cost_basis.unit')" = "cost-weighted-token-units" ] \
  || fail "C3: the cost basis must name cost-weighted-token-units as the unit in play"
jq -e '.cost_basis.list_price_overlay.note | test("never metered dollars")' "$FLAT_OUT" >/dev/null 2>&1 \
  || fail "C3: the optional dollar overlay must disclaim being metered dollars"
ok "C3 the cost basis names its unit and disclaims the two units it is not"

count
# The coverage figure must be the STATS.SH one against the CONFIGURED
# denominator, not a locally-divided pair of numbers. Two observed seats
# against an exported NON-default denominator of 2 must read 100%; the same
# two seats against the shipped denominator must not.
COVREPO="$WORK/coverage"
mkrepo "$COVREPO"
fill "$COVREPO/.temperloop/model-comparison/baseline.jsonl"  claude-opus-4-8 4 5000 0
fill "$COVREPO/.temperloop/model-comparison/candidate.jsonl" claude-sonnet-5 4 4200 90
lake "$COVREPO" pipeline-drive-safe retro-judge
( export MODEL_COMPARISON_EMIT_FEASIBLE_SEATS=2; run "$COVREPO"; cp "$RUN_OUT" "$WORK/cov2.json" )
run "$COVREPO"; cp "$RUN_OUT" "$WORK/covdefault.json"
[ "$(jqf "$WORK/cov2.json" '.emit_coverage.coverage_pct')" = "100" ] \
  || fail "C4: two observed seats against an exported denominator of 2 must read 100%, got $(jqf "$WORK/cov2.json" '.emit_coverage.coverage_pct')"
[ "$(jqf "$WORK/cov2.json" '.emit_coverage.feasible_seats')" = "2" ] \
  || fail "C4: the report must state the denominator it actually used"
[ "$(jqf "$WORK/covdefault.json" '.emit_coverage.coverage_pct')" != "100" ] \
  || fail "C4: the same two seats against the shipped denominator must NOT read 100% — the figure is not tracking the configured denominator"
ok "C4 emit coverage is stats.sh's figure against the configured emit-feasible denominator, not a local division"

count
# A seat outside the emit-FEASIBLE roster must not inflate the numerator. The
# module's own replay seats emit too, and counting them would push observed
# past feasible and turn the percentage into nonsense. build-worker
# (temperloop#2065) is the FOURTH feasible seat since it joined the roster —
# emitted here too, so all four (not just three) are the observed set.
lake "$COVREPO" pipeline-drive-safe retro-judge replay-candidate replay-judge pipeline-drive-merge build-worker
run "$COVREPO"
[ "$(jqf "$RUN_OUT" '.emit_coverage.observed_seats')" = "4" ] \
  || fail "C5: six emitted seats, four of them emit-feasible, must count as 4 observed — got $(jqf "$RUN_OUT" '.emit_coverage.observed_seats')"
[ "$(jqf "$RUN_OUT" '.emit_coverage.coverage_pct')" = "100" ] \
  || fail "C5: all four emit-feasible seats observed should read 100%"
ok "C5 only emit-feasible seats count toward the coverage numerator"

count
# The exclusion list must be stated alongside the figure (the L0 spike's own
# directive for this item), naming the un-emittable seats rather than dropping
# them silently — otherwise a 100% reading implies a claim the system does not
# make. A1 moved OFF this list to FEASIBLE_SEAT_ROSTER as "build-worker"
# (temperloop#2065) — A5 (still excluded; a DIFFERENT seat, build-level.mjs's
# runMachinery) replaces it here.
for seat in A5 A2 B1 B2 C1; do
  jq -e --arg s "$seat" '[.emit_coverage.excluded_seats[].seats[]] | index($s) != null' "$FLAT_OUT" >/dev/null 2>&1 \
    || fail "C6: the excluded-seat list must name $seat"
done
jq -e '.emit_coverage.below_100_does_not_mean | test("spend visibility")' "$FLAT_OUT" >/dev/null 2>&1 \
  || fail "C6: the report must say what a sub-100% figure does NOT mean"
ok "C6 the named exclusion list and the does-not-mean caveat ride alongside the coverage figure"

count
# MUTATION PROOF for the end-to-end path (not only the assertion): rename the
# published emit_coverage key in a mirrored producer and require C1 to go red.
MIRROR1="$(mkmirror "$WORK/m1")"
perl -pi -e 's/^(\s+)emit_coverage: \{$/$1emit_coverage_GONE: {/' "$MIRROR1"
run "$FLAT" "$MIRROR1"
if assert_disclosures "$RUN_OUT"; then
  fail "C7: a producer that no longer publishes emit_coverage still passed the disclosure assertion"
fi
ok "C7 mutation proof: a producer that stops publishing emit_coverage turns C1 RED"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION D — THE INCONCLUSIVE FLOOR, AND THE WINNER GATE
# ═══════════════════════════════════════════════════════════════════════════
# The floor is exported to a NON-default value throughout, so these tests
# prove the producer honours the CONFIGURED floor rather than agreeing with a
# shipped constant by accident.
FLOOR=12
SMALL="$WORK/small"
mkrepo "$SMALL"
fill "$SMALL/.temperloop/model-comparison/baseline.jsonl"  claude-opus-4-8  3 5000 0
fill "$SMALL/.temperloop/model-comparison/candidate.jsonl" claude-sonnet-5  3 4200 90 8
lake "$SMALL" pipeline-drive-safe

count
( export MODEL_COMPARISON_MIN_SAMPLE_N=$FLOOR; run "$SMALL"; cp "$RUN_OUT" "$WORK/small.json" )
[ "$(jqf "$WORK/small.json" '.comparison.verdict')" = "inconclusive" ] \
  || fail "D1: 3 paired outcomes under a floor of $FLOOR must report inconclusive, got $(jqf "$WORK/small.json" '.comparison.verdict')"
[ "$(jqf "$WORK/small.json" '.comparison | has("winner")')" = "false" ] \
  || fail "D1: an inconclusive run must not carry a winner key at all"
[ "$(jqf "$WORK/small.json" '.comparison.below_min_sample')" = "true" ] \
  || fail "D1: the run must say it is below the floor"
[ "$(jqf "$WORK/small.json" '.comparison.confidence_interval.lower')" = "null" ] \
  || fail "D1: below the floor the bootstrap bounds must be withheld"
ok "D1 below the configured floor the report says inconclusive, withholds the bounds, and names no winner"

count
# The MDE disclosure is required on EVERY run — most of all the under-powered
# one, where "at this N only deltas of at least X are detectable" is the whole
# point. It must be a real number here, not a shrug.
[ "$(jqf "$WORK/small.json" '.comparison.minimum_detectable_effect.mde | type')" = "number" ] \
  || fail "D2: a below-floor run must still disclose a minimum detectable effect"
jq -e '.comparison.minimum_detectable_effect.disclosure | test("at N=3")' "$WORK/small.json" >/dev/null 2>&1 \
  || fail "D2: the MDE disclosure must name the N it was computed at"
ok "D2 the minimum-detectable-effect disclosure is present even below the floor"

count
# MUTATION PROOF 1 — REMOVE THE FLOOR from the producer's own verdict call
# (the realistic bug: reaching for the unfloored form, exactly the shape the
# dispersion probe uses). The same 3 records must then yield a winner, which
# is what makes D1 a refusal the floor is causing rather than a coincidence
# of this fixture. The 3 QUALITY deltas are all +8, so an unfloored bootstrap
# lands wholly above zero and reads as a confident candidate win.
MIRROR2="$(mkmirror "$WORK/m2")"
# Since temperloop#1606 the winner rides the QUALITY verdict call, so that is
# the one whose floor has to be removed for this proof to measure anything.
perl -pi -e 's/^(\s*)qvj="\$\(bash "\$STATS_SH" verdict --deltas "\$qdeltas" 2>\/dev\/null\)"$/$1qvj="\$(bash "\$STATS_SH" verdict --deltas "\$qdeltas" --min-sample 1 2>\/dev\/null)"/' "$MIRROR2"
grep -F 'qvj="$(bash "$STATS_SH" verdict --deltas "$qdeltas" --min-sample 1' "$MIRROR2" >/dev/null \
  || fail "D3: the floor-removal mutation did not apply — the proof would be vacuous"
( export MODEL_COMPARISON_MIN_SAMPLE_N=$FLOOR; run "$SMALL" "$MIRROR2"; cp "$RUN_OUT" "$WORK/small-mut.json" )
[ "$(jqf "$WORK/small-mut.json" '.comparison | has("winner")')" = "true" ] \
  || fail "D3: with the floor removed from the producer's verdict call a winner should have appeared on 3 records — the floor was not what was suppressing it"
[ "$(jqf "$WORK/small-mut.json" '.comparison.winner')" = "candidate" ] \
  || fail "D3: the unfloored mutant should have named the candidate on these 3 all-positive quality deltas"
ok "D3 mutation proof: removing the floor from the producer's verdict call makes a winner appear on 3 records"

count
# MUTATION PROOF 2 — leave the producer untouched and remove the floor inside
# stats.py. A winner must appear, proving the producer genuinely rides the
# library's floor rather than a private copy of it.
MIRROR3="$(mkmirror "$WORK/m3")"
perl -pi -e 's/^(\s+)if n < args\.min_sample:$/$1if False:/' "$WORK/m3/workflows/scripts/model-comparison/stats.py"
grep -F 'if False:' "$WORK/m3/workflows/scripts/model-comparison/stats.py" >/dev/null \
  || fail "D4: the stats.py floor mutation did not apply — the proof would be vacuous"
( export MODEL_COMPARISON_MIN_SAMPLE_N=$FLOOR; run "$SMALL" "$MIRROR3"; cp "$RUN_OUT" "$WORK/small-mut2.json" )
[ "$(jqf "$WORK/small-mut2.json" '.comparison | has("winner")')" = "true" ] \
  || fail "D4: with stats.py's floor removed the UNMODIFIED producer should have named a winner on 3 records — it is not riding the library floor"
ok "D4 mutation proof: removing stats.py's own floor makes the unmodified producer name a winner on 3 records"

count
# Above the floor, a real difference IS named — otherwise D1 could be passing
# because the producer never names a winner at all.
[ "$(jqf "$FLAT_OUT" '.comparison.verdict')" = "candidate_better" ] \
  || fail "D5: the flattering run should reach a candidate_better verdict, got $(jqf "$FLAT_OUT" '.comparison.verdict')"
[ "$(jqf "$FLAT_OUT" '.comparison.winner')" = "candidate" ] \
  || fail "D5: a supported verdict must name its winner"
ok "D5 above the floor a supported verdict does name a winner — D1 is a refusal, not an inability"

count
# A no-significant-difference verdict above the floor also names no winner:
# "not distinguishable" is not "tied and therefore either".
SAME="$WORK/same"
mkrepo "$SAME"
fill "$SAME/.temperloop/model-comparison/baseline.jsonl"  claude-opus-4-8  24 5000 90
fill "$SAME/.temperloop/model-comparison/candidate.jsonl" claude-sonnet-5  24 5000 90
lake "$SAME" pipeline-drive-safe
run "$SAME"
[ "$(jqf "$RUN_OUT" '.comparison.below_min_sample')" = "false" ] \
  || fail "D6: this fixture is meant to sit above the floor"
[ "$(jqf "$RUN_OUT" '.comparison | has("winner")')" = "false" ] \
  || fail "D6: a run with no significant difference must name no winner"
ok "D6 above the floor with no significant difference, still no winner"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION E — NO FABRICATED FIGURE ON A DEGRADED RUN
# ═══════════════════════════════════════════════════════════════════════════
# assert_no_fabrication <stdout-file> <rc> — the degraded-run contract:
# exit 0, one `skipped -- ` line, and nowhere in the output a winner or a cost
# figure. Returns non-zero quietly so it can be proved load-bearing.
assert_no_fabrication() {
  local f="$1" rc="$2"
  [ "$rc" -eq 0 ] || return 1
  [ "$(grep -c . "$f")" = "1" ] || return 1
  grep -q '^skipped -- model-comparison: ' "$f" || return 1
  grep -q 'winner' "$f" && return 1
  grep -qE 'cost_per_merged_outcome|weighted_units|estimate_usd' "$f" && return 1
  return 0
}

count
STARVED="$WORK/starved"
mkrepo "$STARVED"
run "$STARVED"
assert_no_fabrication "$RUN_OUT" "$RUN_RC" \
  || fail "E1: a starved run must exit 0 with one 'skipped -- ' line and no winner and no cost figure; got rc=$RUN_RC out=$(cat "$RUN_OUT")"
ok "E1 a fully starved run: exit 0, one skipped line, no winner key, no cost figure"

count
# One arm only is still not a comparison.
fill "$STARVED/.temperloop/model-comparison/baseline.jsonl" claude-opus-4-8 24 5000 0
run "$STARVED"
assert_no_fabrication "$RUN_OUT" "$RUN_RC" \
  || fail "E2: a run with only a baseline arm must degrade, not report half a comparison"
grep -q 'candidate arm' "$RUN_OUT" \
  || fail "E2: the skipped line must name what was missing"
ok "E2 one arm present is a named degradation, never half a comparison"

count
# Malformed records degrade rather than being partially rolled up.
printf 'not json at all\n' >"$STARVED/.temperloop/model-comparison/candidate.jsonl"
run "$STARVED"
assert_no_fabrication "$RUN_OUT" "$RUN_RC" \
  || fail "E3: an unparseable arm must degrade rather than report a partial roll-up"
ok "E3 an unparseable arm degrades rather than reporting a partial roll-up"

count
# MUTATION PROOF — rewrite the degradation path to emit a fabricated report
# and require the assertion to catch it. Without this, E1-E3 could be passing
# because the assertion is toothless.
MIRROR4="$(mkmirror "$WORK/m4")"
# The replacement rides an env var so neither the shell nor perl reprocesses
# its escapes on the way in.
FAB_SKIP='skip() { echo "{\"winner\":\"candidate\",\"cost_per_merged_outcome\":9999}"; exit 0; }'
export FAB_SKIP
perl -pi -e 's/^skip\(\) \{ printf.*$/$ENV{FAB_SKIP}/' "$MIRROR4"
unset FAB_SKIP
grep -F 'cost_per_merged_outcome\":9999' "$MIRROR4" >/dev/null \
  || fail "E4: the fabrication mutation did not apply — the proof would be vacuous"
STARVED2="$WORK/starved2"
mkrepo "$STARVED2"
run "$STARVED2" "$MIRROR4"
if assert_no_fabrication "$RUN_OUT" "$RUN_RC"; then
  fail "E4: a degradation path that emitted a fabricated winner+cost object still passed the no-fabrication assertion"
fi
ok "E4 mutation proof: a degradation path that fabricates a winner and a cost figure turns E1 RED"

count
# The subtler fabrication: records present, but no token counts. A whole-job
# cost figure over a partial cost corpus is a figure derived from missing
# data, so it must be withheld WITH A STATED REASON — and still no winner,
# because a delta needs both sides.
PARTIAL="$WORK/partial"
mkrepo "$PARTIAL"
{
  record 1001 claude-opus-4-8 5000 100 pass true JUDGED 80 2026-08-01 scored
  record 1002 claude-opus-4-8 5100 100 pass true JUDGED 80 2026-08-02 scored
} >"$PARTIAL/.temperloop/model-comparison/baseline.jsonl"
{
  record 1001 claude-sonnet-5 4000 100 pass true JUDGED 80 2026-08-01 scored | jq -c '.candidate.tokens = null'
  record 1002 claude-sonnet-5 4100 100 pass true JUDGED 80 2026-08-02 scored
} >"$PARTIAL/.temperloop/model-comparison/candidate.jsonl"
lake "$PARTIAL" pipeline-drive-safe
run "$PARTIAL"
[ "$RUN_RC" -eq 0 ] || fail "E5: a partial-token run must still exit 0"
[ "$(jqf "$RUN_OUT" '.arms.candidate.cost.cost_per_merged_outcome')" = "null" ] \
  || fail "E5: a whole-job cost figure must be withheld when some scored records carry no tokens"
[ "$(jqf "$RUN_OUT" '.arms.candidate.cost.cost_per_merged_outcome_unavailable_reason | type')" = "string" ] \
  || fail "E5: withholding the figure must come with a stated reason, never a silent null"
[ "$(jqf "$RUN_OUT" '.arms.candidate.cost.uncosted_n')" = "1" ] \
  || fail "E5: the record with no tokens must be counted as uncosted, never as a zero"
[ "$(jqf "$RUN_OUT" '.comparison.paired_outcomes_n')" = "1" ] \
  || fail "E5: only the outcome with tokens on BOTH sides may contribute a delta"
[ "$(jqf "$RUN_OUT" '.comparison | has("winner")')" = "false" ] \
  || fail "E5: one pair is below any floor — no winner"
ok "E5 a token-starved record is counted as uncosted, the whole-job figure is withheld with a stated reason, and no winner is named"

count
# An integration-error record must never be read as a model quality failure —
# it lands in compatibility and in the intervention proxy, and nowhere in the
# quality block.
IERR="$WORK/ierr"
mkrepo "$IERR"
fill "$IERR/.temperloop/model-comparison/baseline.jsonl" claude-opus-4-8 3 5000 0
{
  record 1000 claude-sonnet-5 4000 100 pass true JUDGED 80 2026-08-01 scored
  record 1001 claude-sonnet-5 0 0 x false none 0 2026-08-02 integration-error
  record 1002 claude-sonnet-5 4100 100 fail false JUDGED 60 2026-08-03 scored
} >"$IERR/.temperloop/model-comparison/candidate.jsonl"
lake "$IERR" pipeline-drive-safe
run "$IERR"
[ "$(jqf "$RUN_OUT" '.arms.candidate.quality.scored_n')" = "2" ] \
  || fail "E6: the integration error must be excluded from the quality denominator"
[ "$(jqf "$RUN_OUT" '.arms.candidate.compatibility.integration_error_n')" = "1" ] \
  || fail "E6: the integration error must be reported as a compatibility fact"
[ "$(jqf "$RUN_OUT" '.arms.candidate.intervention_rework.intervention_n')" = "1" ] \
  || fail "E6: the integration error must count as an intervention"
[ "$(jqf "$RUN_OUT" '.arms.candidate.intervention_rework.rework_n')" = "1" ] \
  || fail "E6: the gate-failing record must count as rework"
ok "E6 integration errors sit in compatibility and intervention, never in the quality denominator; a failed gate counts as rework"

count
# The SAME integration-error record (stage "candidate-timeout", tokens null)
# must also be visible in the COST section — never silently absent just
# because it was never scored — with a stated reason that a SIGKILLed spawn
# has no envelope, so partial-usage capture is structurally impossible.
[ "$(jqf "$RUN_OUT" '.arms.candidate.cost.errored_uncosted_n')" = "1" ] \
  || fail "E7: the integration-error record must be counted in the cost block, not silently absent"
[ "$(jqf "$RUN_OUT" '.arms.candidate.cost.errored_uncosted_reason | type')" = "string" ] \
  || fail "E7: the errored-uncosted count must carry a stated reason string, never a bare number"
[ "$(jqf "$RUN_OUT" '.arms.candidate.cost.errored_uncosted_reason | test("candidate-timeout"; "i")')" = "true" ] \
  || fail "E7: the reason must name the integration-error stage rather than a generic disclaimer"
[ "$(jqf "$RUN_OUT" '.arms.baseline.cost.errored_uncosted_n')" = "0" ] \
  || fail "E7: an arm with no integration errors must report zero, not the count omitted"
[ "$(jqf "$RUN_OUT" '.arms.baseline.cost.errored_uncosted_reason')" = "null" ] \
  || fail "E7: an arm with zero integration errors states no reason (null, not a fabricated explanation)"
ok "E7 an integration-errored, token-null record is counted in the cost block's errored_uncosted_n with a stated no-envelope reason, never fabricated tokens"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION F — STATISTICS CONSUMED, NOT RECOMPUTED
# ═══════════════════════════════════════════════════════════════════════════

count
# Byte-identical to an independent stats.sh call over the producer's OWN
# published delta array. The array is published precisely so this check needs
# no re-derivation of production logic.
DELTAS="$(jq -c '.comparison.deltas' "$FLAT_OUT")"
[ "$(jq -r 'length' <<<"$DELTAS")" = "24" ] || fail "F1: expected 24 published deltas"
indep_ci="$(bash "$STATS" bootstrap-ci --deltas "$DELTAS" | jq -c '{lower,upper,mean,iterations,seed,ci_width_pct}')"
mine_ci="$(jq -c '.comparison.confidence_interval | {lower,upper,mean,iterations,seed,ci_width_pct}' "$FLAT_OUT")"
[ "$indep_ci" = "$mine_ci" ] \
  || fail "F1: the published confidence interval diverges from an independent stats.sh call (independent: $indep_ci; reported: $mine_ci)"
ok "F1 the published confidence interval is byte-identical to an independent stats.sh bootstrap-ci call"

count
indep_sd="$(bash "$STATS" verdict --deltas "$DELTAS" --min-sample 1 | jq -r '.stddev')"
indep_mde="$(bash "$STATS" mde --n 24 --stddev "$indep_sd" | jq -c '{mde,margin_of_error,power,ci_width_pct}')"
mine_mde="$(jq -c '.comparison.minimum_detectable_effect | {mde,margin_of_error,power,ci_width_pct}' "$FLAT_OUT")"
[ "$indep_mde" = "$mine_mde" ] \
  || fail "F2: the published MDE diverges from an independent stats.sh mde call (independent: $indep_mde; reported: $mine_mde)"
ok "F2 the published MDE and margin of error are byte-identical to an independent stats.sh mde call"

count
# Above the floor, stats.sh verdict computes its own mde too. The producer's
# published figure must equal it — a second, independent way of catching a
# locally-recomputed substitute.
verdict_mde="$(bash "$STATS" verdict --deltas "$DELTAS" | jq -r '.mde')"
[ "$verdict_mde" = "$(jqf "$FLAT_OUT" '.comparison.minimum_detectable_effect.mde')" ] \
  || fail "F3: the published MDE disagrees with stats.sh verdict's own MDE over the same deltas"
ok "F3 the published MDE also matches stats.sh verdict's own MDE over the same deltas"

count
# MUTATION PROOF — nudge the published lower bound by 5% in a mirrored
# producer. F1 must go red.
MIRROR5="$(mkmirror "$WORK/m5")"
perl -pi -e 's/lower: \$ci\.lower, upper: \$ci\.upper,/lower: (\$ci.lower * 1.05), upper: \$ci.upper,/' "$MIRROR5"
grep -F '$ci.lower * 1.05' "$MIRROR5" >/dev/null \
  || fail "F4: the CI mutation did not apply — the proof would be vacuous"
run "$FLAT" "$MIRROR5"
mut_ci="$(jq -c '.comparison.confidence_interval | {lower,upper,mean,iterations,seed,ci_width_pct}' "$RUN_OUT")"
[ "$mut_ci" != "$indep_ci" ] \
  || fail "F4: a producer publishing a 5%-scaled lower bound still matched the independent stats.sh call — F1 is not load-bearing"
ok "F4 mutation proof: a 5% nudge to the published lower bound turns F1 RED"

count
# The dispersion probe must not leak: its own (floor-1) verdict and bounds are
# discarded, so a below-floor run cannot inherit a conclusive-looking result
# from it.
[ "$(jqf "$WORK/small.json" '.comparison.confidence_interval.below_min_sample')" = "true" ] \
  || fail "F5: the published interval must be the floor-respecting one, not the dispersion probe's"
[ "$(jqf "$WORK/small.json" '.comparison.confidence_interval.upper')" = "null" ] \
  || fail "F5: the dispersion probe's bounds must never reach stdout"
ok "F5 the dispersion probe contributes only a standard deviation — never its verdict or its bounds"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION G — A MID-BATCH JUDGE OUTAGE CARRIES ITS NAMED NOTICE
# ═══════════════════════════════════════════════════════════════════════════

count
JREPO="$WORK/judge"
mkrepo "$JREPO"
fill "$JREPO/.temperloop/model-comparison/baseline.jsonl" claude-opus-4-8 3 5000 0
NOTICE_TEXT="judge-transport-failed: the judge runner exited 137 mid-batch"
{
  record 1000 claude-sonnet-5 4000 100 pass true JUDGED 90 2026-08-01 scored
  record 1001 claude-sonnet-5 4100 100 pass true UNAVAILABLE 0 2026-08-02 scored "$NOTICE_TEXT"
  record 1002 claude-sonnet-5 4200 100 pass true JUDGED 70 2026-08-03 scored
} >"$JREPO/.temperloop/model-comparison/candidate.jsonl"
lake "$JREPO" pipeline-drive-safe
run "$JREPO"
[ "$(jqf "$RUN_OUT" '.arms.candidate.judge_quality.degraded_n')" = "1" ] \
  || fail "G1: the UNAVAILABLE row must be reported as degraded"
[ "$(jqf "$RUN_OUT" '.arms.candidate.judge_quality.degraded_rows[0].degradation_notice')" = "$NOTICE_TEXT" ] \
  || fail "G1: the row's own NAMED degradation notice must be carried verbatim"
[ "$(jqf "$RUN_OUT" '.arms.candidate.judge_quality.degraded_rows[0].outcome_ref')" = "pr:1001" ] \
  || fail "G1: the degraded row must name which outcome it was"
ok "G1 a mid-batch judge outage row carries its named degradation notice, tagged with its outcome"

count
# The outage row must be EXCLUDED from the mean, never folded in as a zero —
# a withheld judgment is not a judgment of zero. (90 + 70) / 2 = 80; folding a
# zero in would give 53.3.
[ "$(jqf "$RUN_OUT" '.arms.candidate.judge_quality.judged_n')" = "2" ] \
  || fail "G2: only the two JUDGED rows may enter the mean"
[ "$(jqf "$RUN_OUT" '.arms.candidate.judge_quality.mean_quality_score')" = "80" ] \
  || fail "G2: expected the mean of the two real judgments (80), got $(jqf "$RUN_OUT" '.arms.candidate.judge_quality.mean_quality_score') — a withheld judgment must not be scored as a zero"
ok "G2 an outage row is excluded from the judge-quality mean rather than counted as a zero"

count
# MUTATION PROOF — widen the JUDGED selector to swallow every judged-ish row.
# The mean must move and G2 must go red.
MIRROR6="$(mkmirror "$WORK/m6")"
perl -pi -e 's/\(\$recs \| map\(select\(\(\(\.judge \/\/ \{\}\)\.outcome \/\/ null\) == "JUDGED"\)\)\)/(\$recs | map(select((((.judge \/\/ {}).outcome \/\/ null) != null))))/' "$MIRROR6"
grep -F 'outcome // null) != null))))' "$MIRROR6" >/dev/null \
  || fail "G3: the judged-selector mutation did not apply — the proof would be vacuous"
run "$JREPO" "$MIRROR6"
[ "$(jqf "$RUN_OUT" '.arms.candidate.judge_quality.mean_quality_score')" != "80" ] \
  || fail "G3: swallowing the outage row into the mean left it unchanged — G2 is not load-bearing"
ok "G3 mutation proof: folding the outage row into the mean moves it, so G2 is load-bearing"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION H — THE PRICE TABLE: DATED LABEL, OR TOKEN COUNTS ONLY, STATED
# ═══════════════════════════════════════════════════════════════════════════

count
# The kernel default table drives a DATED staleness label carrying its own
# as_of, never a bare dollar figure.
[ "$(jqf "$FLAT_OUT" '.cost_basis.list_price_overlay.table_in_effect')" = "kernel-default" ] \
  || fail "H1: with no user table the kernel default should be in effect"
as_of="$(jq -r '.as_of' "$SCRIPTS_DIR/config/default-pricing.json")"
jq -e --arg d "$as_of" '.cost_basis.list_price_overlay.staleness | test("dated " + $d)' "$FLAT_OUT" >/dev/null 2>&1 \
  || fail "H1: the staleness label must carry the table's own as_of date"
jq -e '.cost_basis.list_price_overlay.staleness | test("STALE BY CONSTRUCTION")' "$FLAT_OUT" >/dev/null 2>&1 \
  || fail "H1: the staleness label must say the table is a committed snapshot, not a live rate"
[ "$(jqf "$FLAT_OUT" '.cost_basis.list_price_overlay.estimate_usd | type')" = "number" ] \
  || fail "H1: a resolving price table should produce a directional estimate"
ok "H1 the default price table renders a dated staleness label beside its directional estimate"

count
# A user table overrides outright and is NEVER merged per-key: a model the
# user table omits is excluded BY NAME, not back-filled from the kernel table.
UREPO="$WORK/userprice"
mkrepo "$UREPO"
fill "$UREPO/.temperloop/model-comparison/baseline.jsonl"  claude-opus-4-8 3 5000 0
fill "$UREPO/.temperloop/model-comparison/candidate.jsonl" claude-sonnet-5 3 4200 90
lake "$UREPO" pipeline-drive-safe
printf '{"claude-sonnet-5": 4.00}\n' >"$UREPO/.temperloop/pricing.json"
run "$UREPO"
[ "$(jqf "$RUN_OUT" '.cost_basis.list_price_overlay.table_in_effect')" = "user" ] \
  || fail "H2: a present user table must win outright"
jq -e '[.cost_basis.list_price_overlay.excluded_models[]] | index("claude-opus-4-8") != null' "$RUN_OUT" >/dev/null 2>&1 \
  || fail "H2: a model absent from the user table must be excluded BY NAME, never back-filled from the kernel default"
jq -e '[.cost_basis.list_price_overlay.priced_models[]] | index("claude-sonnet-5") != null' "$RUN_OUT" >/dev/null 2>&1 \
  || fail "H2: the model the user priced must be priced"
ok "H2 a user price table overrides outright; an omitted model is excluded by name, never back-filled"

count
# A malformed user table degrades to token counts only, STATED.
printf '[1,2,3]\n' >"$UREPO/.temperloop/pricing.json"
run "$UREPO"
[ "$(jqf "$RUN_OUT" '.cost_basis.list_price_overlay.table_in_effect')" = "user-malformed" ] \
  || fail "H3: a non-object user table must be named as malformed"
[ "$(jqf "$RUN_OUT" '.cost_basis.list_price_overlay.estimate_usd')" = "null" ] \
  || fail "H3: a malformed table must produce no dollar figure"
jq -e '.cost_basis.list_price_overlay.staleness | test("TOKEN COUNTS ONLY")' "$RUN_OUT" >/dev/null 2>&1 \
  || fail "H3: the degradation must be STATED as token counts only, never silently omitted"
ok "H3 a malformed user price table degrades to a stated token-counts-only basis"

count
# An absent/broken kernel default table does the same rather than vanishing.
rm -f "$UREPO/.temperloop/pricing.json"
MIRROR7="$(mkmirror "$WORK/m7")"
printf '{"oops": true}\n' >"$WORK/m7/workflows/scripts/config/default-pricing.json"
run "$UREPO" "$MIRROR7"
[ "$(jqf "$RUN_OUT" '.cost_basis.list_price_overlay.table_in_effect')" = "kernel-default-malformed" ] \
  || fail "H4: a broken kernel default table must be named, got $(jqf "$RUN_OUT" '.cost_basis.list_price_overlay.table_in_effect')"
jq -e '.cost_basis.list_price_overlay.staleness | test("TOKEN COUNTS ONLY")' "$RUN_OUT" >/dev/null 2>&1 \
  || fail "H4: a broken default table must state the token-counts-only degradation"
[ "$(jqf "$RUN_OUT" '.arms.candidate.cost.total_weighted_units | type')" = "number" ] \
  || fail "H4: the token counts themselves must survive a missing price table"
ok "H4 a broken kernel default price table degrades to a stated token-counts-only basis, token figures intact"

count
# A WELL-FORMED price table that simply names neither model in the run must
# withhold the headline figure rather than let `add // 0` render a false
# "$0.00" that reads as free (temperloop#1384). The exclusion machinery
# (H2) already reports the excluded models correctly — this proves the
# rendered dollar figure stops lying too.
printf '{"claude-haiku-4-5": 1.00}\n' >"$UREPO/.temperloop/pricing.json"
run "$UREPO"
[ "$(jqf "$RUN_OUT" '.cost_basis.list_price_overlay.table_in_effect')" = "user" ] \
  || fail "H5: a present, well-formed user table must still be in effect"
[ "$(jqf "$RUN_OUT" '.cost_basis.list_price_overlay.priced_models | length')" = "0" ] \
  || fail "H5: neither arm's model is in this table — priced_models must be empty"
[ "$(jqf "$RUN_OUT" '.cost_basis.list_price_overlay.estimate_usd')" = "null" ] \
  || fail "H5: with every model excluded, estimate_usd must be null, never a fabricated 0 (\"free\")"
jq -e '.cost_basis.list_price_overlay.estimate_usd_unavailable_reason | test("claude-opus-4-8") and test("claude-sonnet-5")' "$RUN_OUT" >/dev/null 2>&1 \
  || fail "H5: estimate_usd_unavailable_reason must name every excluded model"
ok "H5 a price table excluding every model in the run withholds estimate_usd (null, never 0) with a stated reason naming the excluded models"

count
# MUTATION PROOF — restore the naive `add // 0` fold with nothing else
# changed. H5 must go red, proving the withhold logic (not some other guard)
# is what keeps the false $0.00 from rendering.
MIRROR8="$(mkmirror "$WORK/m8")"
perl -0pi -e 's/elif \(\$priced_models \| length\) == 0 then null\n\s*else/else/' "$MIRROR8"
grep -F 'elif ($priced_models | length) == 0 then null' "$MIRROR8" >/dev/null \
  && fail "H6: the withhold-branch mutation did not apply — the proof would be vacuous"
run "$UREPO" "$MIRROR8"
[ "$(jqf "$RUN_OUT" '.cost_basis.list_price_overlay.estimate_usd')" = "0" ] \
  || fail "H6: removing the withhold branch should reveal the old fabricated-0.00 bug, got $(jqf "$RUN_OUT" '.cost_basis.list_price_overlay.estimate_usd')"
ok "H6 mutation proof: removing the withhold branch resurrects the fabricated \$0.00 — H5 is load-bearing"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION I — CORPUS WINDOW AND GATE VERSIONS ARE READ, NOT ASSUMED
# ═══════════════════════════════════════════════════════════════════════════

count
[ "$(jqf "$FLAT_OUT" '.corpus_window.replayed_from_utc')" = "2026-08-01T10:00:00Z" ] \
  || fail "I1: the corpus window must report the earliest prepared_at it actually saw"
[ "$(jqf "$FLAT_OUT" '.corpus_window.replayed_to_utc')" = "2026-08-20T10:00:00Z" ] \
  || fail "I1: the corpus window must report the latest prepared_at it actually saw"
[ "$(jqf "$FLAT_OUT" '.corpus_window.pr_lowest')" = "1000" ] \
  || fail "I1: the corpus window must report the PR range replayed"
ok "I1 the corpus window is read off the records, not assumed"

count
# Human-facing local rendering must differ from the stored UTC instant under a
# non-UTC display zone, and must NOT differ under UTC — proving the conversion
# is real and honours the configured zone rather than echoing the UTC string.
utc_from="$(jqf "$FLAT_OUT" '.corpus_window.replayed_from_utc')"
la_local="$(jqf "$FLAT_OUT" '.corpus_window.replayed_from_local')"
[ "$la_local" = "2026-08-01 03:00:00" ] \
  || fail "I2: 2026-08-01T10:00:00Z should render as 03:00:00 in America/Los_Angeles (summer, -07:00), got '$la_local'"
( export DISPLAY_TZ=UTC; run "$FLAT"; cp "$RUN_OUT" "$WORK/utc.json" )
[ "$(jqf "$WORK/utc.json" '.corpus_window.replayed_from_local')" = "2026-08-01 10:00:00" ] \
  || fail "I2: under DISPLAY_TZ=UTC the local rendering must match the stored instant"
[ "$(jqf "$WORK/utc.json" '.corpus_window.replayed_from_utc')" = "$utc_from" ] \
  || fail "I2: the STORED timestamp must stay UTC regardless of the display zone"
[ "$(jqf "$WORK/utc.json" '.display_timezone')" = "UTC" ] \
  || fail "I2: the report must name the display zone it rendered in"
ok "I2 human-facing timestamps render in the configured display zone while stored ones stay UTC"

count
# Gate versions are the (script, base) pairs actually run — several bases mean
# several gate versions, stated rather than collapsed into one.
GREPO="$WORK/gates"
mkrepo "$GREPO"
fill "$GREPO/.temperloop/model-comparison/baseline.jsonl" claude-opus-4-8 2 5000 0
{
  record 1000 claude-sonnet-5 4000 100 pass true JUDGED 80 2026-08-01 scored
  record 1001 claude-sonnet-5 4100 100 pass true JUDGED 80 2026-08-02 scored | jq -c '.score.base = "base0002"'
} >"$GREPO/.temperloop/model-comparison/candidate.jsonl"
lake "$GREPO" pipeline-drive-safe
run "$GREPO"
[ "$(jqf "$RUN_OUT" '.gate_versions.distinct_n')" = "2" ] \
  || fail "I3: two distinct bases must be reported as two gate versions, got $(jqf "$RUN_OUT" '.gate_versions.distinct_n')"
ok "I3 a comparison spanning two bases reports two gate versions rather than collapsing them"

count
# A comparison with no gate that ever ran says so rather than reporting an
# empty list as if it meant "clean".
NGREPO="$WORK/nogate"
mkrepo "$NGREPO"
record 1000 claude-opus-4-8 5000 100 pass true JUDGED 80 2026-08-01 scored | jq -c '.score.gate_result = null' \
  >"$NGREPO/.temperloop/model-comparison/baseline.jsonl"
record 1000 claude-sonnet-5 4000 100 pass true JUDGED 80 2026-08-01 scored | jq -c '.score.gate_result = null' \
  >"$NGREPO/.temperloop/model-comparison/candidate.jsonl"
run "$NGREPO"
[ "$(jqf "$RUN_OUT" '.gate_versions.versions_unavailable_reason | type')" = "string" ] \
  || fail "I4: a comparison where no gate ran must state that, not present an empty list as a clean bill"
[ "$(jqf "$RUN_OUT" '.arms.candidate.gate_outcomes.no_gate_result_n')" = "1" ] \
  || fail "I4: a scored record with no gate result must be counted as such"
ok "I4 a comparison where no gate ever ran says so rather than showing an empty list"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION J — ARG HYGIENE AND PORTABILITY
# ═══════════════════════════════════════════════════════════════════════════

count
# The report.d contract invokes a producer with NO arguments. A trailing flag
# must degrade promptly — never spin. The bounded runner is what makes this a
# hang test and not just an output test.
( cd "$FLAT" && run_with_timeout 20 bash "$PRODUCER" --records-dir ) >"$WORK/argflag.out" 2>&1
rc=$?
[ "$rc" -eq 0 ] || fail "J1: a trailing flag must degrade at exit 0 (and must not hang); got rc=$rc"
grep -q '^skipped -- model-comparison: ' "$WORK/argflag.out" \
  || fail "J1: an argument-bearing invocation must render the skipped line"
ok "J1 a trailing flag degrades promptly at exit 0 rather than spinning"

count
rc=0
( cd "$FLAT" && run_with_timeout 20 bash "$PRODUCER" --bogus value extra ) >"$WORK/argbogus.out" 2>&1 || rc=$?
[ "$rc" -eq 0 ] || fail "J2: unknown arguments must still exit 0 — a producer may never break temperloop report"
grep -q '^skipped -- model-comparison: ' "$WORK/argbogus.out" \
  || fail "J2: unknown arguments must render the skipped line"
ok "J2 unknown arguments degrade at exit 0"

count
# Stock macOS /bin/bash 3.2 is a first-class target, so the whole flattering
# run is re-executed under it and must produce byte-identical output apart
# from its own generation timestamp.
if [ -x /bin/bash ] && /bin/bash --version 2>/dev/null | grep 'version 3\.2' >/dev/null; then
  rc=0
  ( cd "$FLAT" && run_with_timeout 120 /bin/bash "$PRODUCER" ) >"$WORK/bash32.json" 2>/dev/null || rc=$?
  [ "$rc" -eq 0 ] || fail "J3: the producer must run clean under /bin/bash 3.2"
  a="$(jq -cS 'del(.generated_at_utc, .generated_at_local)' "$FLAT_OUT")"
  b="$(jq -cS 'del(.generated_at_utc, .generated_at_local)' "$WORK/bash32.json")"
  [ "$a" = "$b" ] || fail "J3: the bash 3.2 run produced different output from the default-bash run"
  ok "J3 identical output under stock /bin/bash 3.2"
else
  ok "J3 skipped -- no /bin/bash 3.2 on this host (the suite still runs under whichever bash invoked it)"
fi

count
# The producer must not care about the ambient numeric locale — a
# comma-decimal locale is where a dollar figure silently loses its cents. The
# locale's presence is CHECKED rather than assumed, so a host without it
# reports a skip instead of a vacuous green.
COMMA_LOCALE=""
for cand in de_DE.UTF-8 fr_FR.UTF-8 de_DE.utf8 fr_FR.utf8; do
  if locale -a 2>/dev/null | grep -x "$cand" >/dev/null; then COMMA_LOCALE="$cand"; break; fi
done
if [ -n "$COMMA_LOCALE" ]; then
  ( cd "$FLAT" && LC_ALL="$COMMA_LOCALE" LC_NUMERIC="$COMMA_LOCALE" run_with_timeout 120 bash "$PRODUCER" ) >"$WORK/locale.json" 2>/dev/null
  a="$(jq -cS 'del(.generated_at_utc, .generated_at_local)' "$FLAT_OUT")"
  b="$(jq -cS 'del(.generated_at_utc, .generated_at_local)' "$WORK/locale.json")"
  [ "$a" = "$b" ] \
    || fail "J4: the comma-decimal locale $COMMA_LOCALE changed the report's numbers"
  ok "J4 a comma-decimal ambient locale ($COMMA_LOCALE) changes nothing"
else
  ok "J4 skipped -- no comma-decimal locale installed on this host to exercise the guard with"
fi

count
# No writes outside $TMPDIR: the target repo must be left exactly as found.
before="$(cd "$FLAT" && find . -type f | sort | while IFS= read -r p; do printf '%s ' "$p"; done)"
run "$FLAT"
after="$(cd "$FLAT" && find . -type f | sort | while IFS= read -r p; do printf '%s ' "$p"; done)"
[ "$before" = "$after" ] || fail "J5: the producer wrote into the target repo"
ok "J5 the producer writes nothing into the target repo"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION K — THE PRODUCER'S OWN DEGRADATION WHEN ITS DEPENDENCIES ARE GONE
# ═══════════════════════════════════════════════════════════════════════════

count
# stats.sh missing: the report must NOT fall back to a locally computed
# interval. It degrades instead — the whole point of consuming the library.
MIRROR8="$(mkmirror "$WORK/m8")"
rm -f "$WORK/m8/workflows/scripts/model-comparison/stats.sh"
run "$FLAT" "$MIRROR8"
[ "$RUN_RC" -eq 0 ] || fail "K1: a missing stats library must still exit 0"
grep -q '^skipped -- model-comparison: ' "$RUN_OUT" \
  || fail "K1: a missing stats library must render the skipped line"
grep -q 'winner' "$RUN_OUT" \
  && fail "K1: a missing stats library must never produce a winner"
ok "K1 a missing statistics library degrades rather than being locally substituted"

count
# stats.py broken (the library present, its numeric core unusable): the report
# still renders its per-arm facts, but withholds the interval, the MDE and any
# winner, with the reason stated.
MIRROR9="$(mkmirror "$WORK/m9")"
printf 'import sys\nsys.exit(3)\n' >"$WORK/m9/workflows/scripts/model-comparison/stats.py"
run "$FLAT" "$MIRROR9"
[ "$RUN_RC" -eq 0 ] || fail "K2: a broken numeric core must still exit 0"
[ "$(jqf "$RUN_OUT" '.comparison.confidence_interval')" = "null" ] \
  || fail "K2: with the numeric core broken there must be no confidence interval"
[ "$(jqf "$RUN_OUT" '.comparison | has("winner")')" = "false" ] \
  || fail "K2: with the numeric core broken there must be no winner"
[ "$(jqf "$RUN_OUT" '.comparison.statistics_unavailable_reason | type')" = "string" ] \
  || fail "K2: the missing statistics must be explained, not silently absent"
[ "$(jqf "$RUN_OUT" '.emit_coverage.coverage_pct')" = "null" ] \
  || fail "K2: coverage rides the same library and must be withheld too"
[ "$(jqf "$RUN_OUT" '.emit_coverage.unavailable_reason | type')" = "string" ] \
  || fail "K2: a withheld coverage figure must state why"
ok "K2 a broken numeric core withholds every statistic WITH a stated reason, and names no winner"

count
# score.sh missing: refuse rather than re-derive its scored-only split here.
MIRROR10="$(mkmirror "$WORK/m10")"
rm -f "$WORK/m10/workflows/scripts/model-comparison/score.sh"
run "$FLAT" "$MIRROR10"
[ "$RUN_RC" -eq 0 ] || fail "K3: a missing scorer must still exit 0"
grep -q '^skipped -- model-comparison: ' "$RUN_OUT" \
  || fail "K3: a missing scorer must render the skipped line"
ok "K3 a missing scorer degrades rather than having its split re-derived here"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION M — THE ORDER EFFECT (temperloop#1571)
#
# batch.sh used to run the two arms in one FIXED order on every record, so ARM
# was perfectly confounded with EXECUTION POSITION. It now counterbalances the
# order and stamps each leg's position onto the record; this section is the
# READING half — the producer must state that arm order was counterbalanced,
# estimate the ORDER effect beside the ARM effect, and refuse to present a
# bare winner when the two are comparable in magnitude.
#
# THE FIXTURE IS BUILT AROUND A KNOWN ANSWER. With SPEND_WEIGHT_INPUT = 1 and
# every other token class held identical between the arms, a delta in
# cost-weighted units IS the delta in input tokens — so the fixture can inject
# an exact arm effect and an exact order effect and the producer's estimates
# are checkable against arithmetic rather than against themselves. The
# generator models a position-2 penalty of ORD on whichever arm ran second,
# plus a per-PAIR jitter J (identical for the two records of a pair, so the
# baseline-first and candidate-first halves see the same jitter distribution
# and it cancels out of the order estimate):
#
#   odd record  (baseline first): delta = ARM + ORD + J
#   even record (candidate first): delta = ARM - ORD + J
#   => arm_effect = ARM + mean(J),  order_effect = ORD
# ═══════════════════════════════════════════════════════════════════════════

# mk_stamp <record-index> <position> <arm> <mode> — stdin one record, stdout
# the same record with batch.sh's `execution_order` block attached (unchanged
# under `none`, which reproduces a pre-#1571 corpus).
mk_stamp() {
  if [ "$4" = "none" ]; then cat; return 0; fi
  jq -c --argjson i "$1" --argjson p "$2" --arg arm "$3" \
    '. + {execution_order:{rule:"counterbalanced-by-record-index-v1", seed:0,
                           record_index:$i, arm:$arm, position:$p, arms_n:2,
                           first_arm:(if $p == 1 then $arm
                                      elif $arm == "baseline" then "candidate"
                                      else "baseline" end),
                           basis:"the execution POSITION of this leg within its record pair"}}'
}

# mk_ordered_pair <repo> <n> <base-input> <arm-delta> <order-delta> <mode>
#                 [quality-arm-delta] [quality-order-delta]
#   mode: counterbalanced | fixed | none
#
# The last two are in JUDGE POINTS and inject the same two effects into the
# QUALITY axis (temperloop#1606). They exist because the winner gate moved:
# it is now the QUALITY order-effect check that withholds, so a fixture that
# injects an order effect into COST alone no longer exercises the gate it was
# written to exercise. A quality jitter is added alongside, because a constant
# delta array is `degenerate` to stats.sh and can never mint a winner — which
# would make every proof below pass for the wrong reason.
mk_ordered_pair() {
  local repo="$1" n="$2" base="$3" armd="$4" ordd="$5" mode="$6" qarmd="${7:-6}" qordd="${8:-0}"
  local bf="$repo/.temperloop/model-comparison/baseline.jsonl"
  local cf="$repo/.temperloop/model-comparison/candidate.jsonl"
  : >"$bf"; : >"$cf"
  local i=1 pos_b pos_c inp_b inp_c true_b jit day
  while [ "$i" -le "$n" ]; do
    case "$mode" in
      fixed) pos_b=1; pos_c=2 ;;
      *) if [ $(( i % 2 )) -eq 1 ]; then pos_b=1; pos_c=2; else pos_b=2; pos_c=1; fi ;;
    esac
    true_b=$(( base + i * 13 ))
    jit=$(( ((i - 1) / 2 % 3) * 10 ))
    inp_b=$(( true_b + (pos_b == 2 ? ordd : 0) ))
    inp_c=$(( true_b + armd + jit + (pos_c == 2 ? ordd : 0) ))
    day="$(printf '2026-08-%02d' $(( (i % 20) + 1 )))"
    # Output tokens held CONSTANT across both arms: anything differing between
    # them other than the injected effects would pollute the delta.
    local qjit=$(( (i - 1) % 3 ))
    local qual_b=$(( 70 + (pos_b == 2 ? qordd : 0) ))
    local qual_c=$(( 70 + qarmd + qjit + (pos_c == 2 ? qordd : 0) ))
    record $(( 2000 + i )) claude-opus-4-8 "$inp_b" 100 pass true JUDGED "$qual_b" "$day" scored \
      | mk_stamp "$i" "$pos_b" baseline "$mode" >>"$bf"
    record $(( 2000 + i )) claude-sonnet-5 "$inp_c" 100 pass true JUDGED "$qual_c" "$day" scored \
      | mk_stamp "$i" "$pos_c" candidate "$mode" >>"$cf"
    i=$(( i + 1 ))
  done
}

# M1 — a COUNTERBALANCED corpus whose order effect is negligible against its
#      arm effect: the report states the counterbalance, publishes both
#      estimates, calls the comparison CLEAN, and still names its winner.
count
ORD_CLEAN="$WORK/order-clean"
mkrepo "$ORD_CLEAN"
mk_ordered_pair "$ORD_CLEAN" 24 5000 -800 -20 counterbalanced 8 0
lake "$ORD_CLEAN" pipeline-drive-safe retro-judge
run "$ORD_CLEAN"
ORD_CLEAN_OUT="$WORK/order-clean.json"; cp "$RUN_OUT" "$ORD_CLEAN_OUT"
[ "$RUN_RC" -eq 0 ] || fail "M1: the producer must exit 0, got $RUN_RC: $(head -c 300 "$WORK/run.err")"
[ "$(jqf "$ORD_CLEAN_OUT" '.execution_order.counterbalanced')" = "true" ] \
  || fail "M1: the report must STATE that arm order was counterbalanced: $(jqf "$ORD_CLEAN_OUT" '.execution_order')"
[ "$(jqf "$ORD_CLEAN_OUT" '.execution_order.baseline_first_n')" = "12" ] \
  || fail "M1: 12 of 24 paired records ran the baseline first, got $(jqf "$ORD_CLEAN_OUT" '.execution_order.baseline_first_n')"
[ "$(jqf "$ORD_CLEAN_OUT" '.execution_order.candidate_first_n')" = "12" ] \
  || fail "M1: 12 of 24 paired records ran the candidate first, got $(jqf "$ORD_CLEAN_OUT" '.execution_order.candidate_first_n')"
[ "$(jqf "$ORD_CLEAN_OUT" '.execution_order.comparison_is_clean')" = "true" ] \
  || fail "M1: an order effect ~2.5% of the arm effect must read as clean: $(jqf "$ORD_CLEAN_OUT" '.execution_order.statement')"
[ "$(jqf "$ORD_CLEAN_OUT" '.comparison.winner')" = "candidate" ] \
  || fail "M1: a clean counterbalanced run must still name its winner: $(jqf "$ORD_CLEAN_OUT" '.comparison.verdict')"
case "$(jqf "$ORD_CLEAN_OUT" '.notice')" in
  *"arm order: counterbalanced"*) : ;;
  *) fail "M1: the human notice must state that arm order was counterbalanced: $(jqf "$ORD_CLEAN_OUT" '.notice')" ;;
esac
ok "M1 a counterbalanced run STATES the counterbalance, calls the comparison clean, and still names its winner"

# M2 — THE ESTIMATES ARE THE INJECTED ONES. Checked against the fixture's own
#      arithmetic, so this is a known-answer test rather than the producer
#      agreeing with itself.
count
[ "$(jqf "$ORD_CLEAN_OUT" '.execution_order.arm_effect')" = "-790" ] \
  || fail "M2: the estimated ARM effect should be the injected -800 plus the mean jitter 10, got $(jqf "$ORD_CLEAN_OUT" '.execution_order.arm_effect')"
[ "$(jqf "$ORD_CLEAN_OUT" '.execution_order.order_effect')" = "-20" ] \
  || fail "M2: the estimated ORDER effect should be the injected -20, got $(jqf "$ORD_CLEAN_OUT" '.execution_order.order_effect')"
[ "$(jqf "$ORD_CLEAN_OUT" '.comparison.order_effect')" = "-20" ] \
  || fail "M2: the order effect must also sit inside the comparison block, beside the figures it qualifies"
[ "$(jqf "$ORD_CLEAN_OUT" '.execution_order.order_effect_comparable_to_arm_effect')" = "false" ] \
  || fail "M2: |-20| is ~2.5% of |-790| — well under the published ratio"
jq -e '.execution_order.estimator | type == "string" and (length > 80)' "$ORD_CLEAN_OUT" >/dev/null \
  || fail "M2: the estimator must be STATED, so a reader can re-derive it from the published means"
ok "M2 known-answer: the published arm effect (-790) and order effect (-20) are exactly the ones the fixture injected"

# M3 — AN ORDER EFFECT COMPARABLE TO THE ARM EFFECT. Same machinery, same N,
#      same supported verdict — but the comparison is no longer clean, so the
#      report SAYS SO and names NO winner rather than handing back a bare one.
count
ORD_DIRTY="$WORK/order-dirty"
mkrepo "$ORD_DIRTY"
mk_ordered_pair "$ORD_DIRTY" 24 5000 -200 -150 counterbalanced 2 6
lake "$ORD_DIRTY" pipeline-drive-safe retro-judge
run "$ORD_DIRTY"
ORD_DIRTY_OUT="$WORK/order-dirty.json"; cp "$RUN_OUT" "$ORD_DIRTY_OUT"
[ "$RUN_RC" -eq 0 ] || fail "M3: the producer must exit 0, got $RUN_RC"
[ "$(jqf "$ORD_DIRTY_OUT" '.execution_order.arm_effect')" = "-190" ] \
  || fail "M3: expected the injected arm effect -190, got $(jqf "$ORD_DIRTY_OUT" '.execution_order.arm_effect')"
[ "$(jqf "$ORD_DIRTY_OUT" '.execution_order.order_effect')" = "-150" ] \
  || fail "M3: expected the injected order effect -150, got $(jqf "$ORD_DIRTY_OUT" '.execution_order.order_effect')"
[ "$(jqf "$ORD_DIRTY_OUT" '.execution_order.order_effect_comparable_to_arm_effect')" = "true" ] \
  || fail "M3: |-150| is ~79% of |-190| — comparable by the published ratio"
[ "$(jqf "$ORD_DIRTY_OUT" '.execution_order.comparison_is_clean')" = "false" ] \
  || fail "M3: a comparable order effect must make the comparison NOT clean"
[ "$(jqf "$ORD_DIRTY_OUT" '.comparison | has("winner")')" = "false" ] \
  || fail "M3: a not-clean comparison must name NO winner, got $(jqf "$ORD_DIRTY_OUT" '.comparison.winner')"
[ "$(jqf "$ORD_DIRTY_OUT" '.comparison.winner_withheld_reason | type')" = "string" ] \
  || fail "M3: withholding a winner must be EXPLAINED, never a silent absence"
case "$(jqf "$ORD_DIRTY_OUT" '.execution_order.statement')" in
  *"NOT CLEAN"*) : ;;
  *) fail "M3: the report must say the comparison is not clean in words: $(jqf "$ORD_DIRTY_OUT" '.execution_order.statement')" ;;
esac
case "$(jqf "$ORD_DIRTY_OUT" '.notice')" in
  *"NOT CLEAN"*) : ;;
  *) fail "M3: the human notice must carry the not-clean verdict: $(jqf "$ORD_DIRTY_OUT" '.notice')" ;;
esac
# AND the sample floor is NOT what suppressed it: the same run is above the
# floor and stats.sh still returned a supported verdict. Without this pair of
# checks the withholding could not be attributed to the order gate.
[ "$(jqf "$ORD_DIRTY_OUT" '.comparison.below_min_sample')" = "false" ] \
  || fail "M3: this run must be ABOVE the sample floor, or the withholding is not attributable to the order effect"
[ "$(jqf "$ORD_DIRTY_OUT" '.comparison.verdict')" = "candidate_better" ] \
  || fail "M3: stats.sh must still return a supported verdict — the winner is withheld by the ORDER gate, not by an inconclusive one: $(jqf "$ORD_DIRTY_OUT" '.comparison.verdict')"
ok "M3 an order effect comparable to the arm effect: the report says NOT CLEAN and withholds the winner, above the floor and on a supported verdict"

# M4 — A FIXED-ORDER CORPUS (the pre-#1571 driver's own output). Every record
#      ran the same arm first, so the order effect is not identifiable at all
#      and the arm effect is arm-plus-position. That is the worst case, and it
#      must be the loudest — never a silently clean-looking report.
count
ORD_FIXED="$WORK/order-fixed"
mkrepo "$ORD_FIXED"
mk_ordered_pair "$ORD_FIXED" 24 5000 -200 -150 fixed 2 6
lake "$ORD_FIXED" pipeline-drive-safe retro-judge
run "$ORD_FIXED"
ORD_FIXED_OUT="$WORK/order-fixed.json"; cp "$RUN_OUT" "$ORD_FIXED_OUT"
[ "$RUN_RC" -eq 0 ] || fail "M4: the producer must exit 0, got $RUN_RC"
[ "$(jqf "$ORD_FIXED_OUT" '.execution_order.positions_recorded')" = "true" ] \
  || fail "M4: the positions ARE recorded here — they are just all the same"
[ "$(jqf "$ORD_FIXED_OUT" '.execution_order.counterbalanced')" = "false" ] \
  || fail "M4: a fixed-order corpus must report counterbalanced:false"
[ "$(jqf "$ORD_FIXED_OUT" '.execution_order.order_effect')" = "null" ] \
  || fail "M4: with every record in one order the order effect is UNIDENTIFIABLE and must be withheld, not estimated: $(jqf "$ORD_FIXED_OUT" '.execution_order.order_effect')"
[ "$(jqf "$ORD_FIXED_OUT" '.execution_order.comparison_is_clean')" = "false" ] \
  || fail "M4: a fully confounded corpus is not a clean comparison"
[ "$(jqf "$ORD_FIXED_OUT" '.comparison | has("winner")')" = "false" ] \
  || fail "M4: a fully confounded corpus must name no winner"
case "$(jqf "$ORD_FIXED_OUT" '.execution_order.statement')" in
  *CONFOUNDED*) : ;;
  *) fail "M4: the confound must be NAMED: $(jqf "$ORD_FIXED_OUT" '.execution_order.statement')" ;;
esac
ok "M4 a fixed-order corpus is reported as CONFOUNDED with the order effect withheld as unidentifiable, and names no winner"

# M5 — BACKWARD COMPATIBILITY. A pre-#1571 corpus carries no position at all.
#      That is UNKNOWN, not not-clean: the producer discloses it and withholds
#      nothing, because inventing a position would be exactly the laundering
#      this item exists to stop.
count
ORD_NONE="$WORK/order-none"
mkrepo "$ORD_NONE"
mk_ordered_pair "$ORD_NONE" 24 5000 -800 -20 none 8 0
lake "$ORD_NONE" pipeline-drive-safe retro-judge
run "$ORD_NONE"
ORD_NONE_OUT="$WORK/order-none.json"; cp "$RUN_OUT" "$ORD_NONE_OUT"
[ "$RUN_RC" -eq 0 ] || fail "M5: the producer must exit 0, got $RUN_RC"
[ "$(jqf "$ORD_NONE_OUT" '.execution_order.positions_recorded')" = "false" ] \
  || fail "M5: a corpus with no execution_order must report positions_recorded:false"
[ "$(jqf "$ORD_NONE_OUT" '.execution_order.counterbalanced')" = "null" ] \
  || fail "M5: unknown is null, never false — the two are different statements"
[ "$(jqf "$ORD_NONE_OUT" '.execution_order.comparison_is_clean')" = "null" ] \
  || fail "M5: cleanliness is UNKNOWN on a positionless corpus, not decided"
[ "$(jqf "$ORD_NONE_OUT" '.comparison.winner')" = "candidate" ] \
  || fail "M5: an unknown order effect must withhold nothing — the pre-#1571 report is unchanged"
case "$(jqf "$ORD_NONE_OUT" '.execution_order.statement')" in
  *"NOT ESTIMABLE"*) : ;;
  *) fail "M5: the unknown must be DISCLOSED: $(jqf "$ORD_NONE_OUT" '.execution_order.statement')" ;;
esac
ok "M5 a pre-counterbalancing corpus is disclosed as NOT ESTIMABLE and withholds nothing — unknown is not the same statement as not-clean"

# M6 — MUTATION PROOF. Neuter the order-effect winner gate in a mirrored
#      producer. Targets the QUALITY gate since temperloop#1606: that is the
#      axis the winner is minted from, so it is the gate that withholds.
#      producer and M3's own fixture DOES name a winner — so M3's withholding
#      is that gate doing work, not the sample floor and not an inconclusive
#      verdict.
count
MIRROR_M="$(mkmirror "$WORK/m-order")"
MUT_OLD='if [ "${q_comparison_clean:-}" = "false" ] && [ "$winner_json" != "null" ]; then' \
MUT_NEW='if false; then' \
perl -0777 -pi -e '
  my $o = $ENV{MUT_OLD}; my $n = $ENV{MUT_NEW};
  my $count = () = /\Q$o\E/g;
  die "M6: the order-gate mutation target is not present exactly once (count=$count)\n" unless $count == 1;
  s/\Q$o\E/$n/;
' "$MIRROR_M" || fail "M6: the order-gate mutation did not apply — the proof would be vacuous"
run "$ORD_DIRTY" "$MIRROR_M"
[ "$RUN_RC" -eq 0 ] || fail "M6: the mutated producer must still exit 0, got $RUN_RC"
[ "$(jqf "$RUN_OUT" '.comparison.winner')" = "candidate" ] \
  || fail "M6: the mutation proof did not fire — with the order gate neutered the same fixture should have named a winner, so M3 proves nothing: $(jqf "$RUN_OUT" '.comparison.verdict')"
[ "$(jqf "$RUN_OUT" '.quality_comparison.execution_order.comparison_is_clean')" = "false" ] \
  || fail "M6: the mutation must remove only the WITHHOLDING, leaving the not-clean finding intact"
ok "M6 MUTATION PROOF: neutering the order-effect gate makes M3's fixture name a winner — the withholding is that gate, not the floor"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION L — THE SUITE-WIDE NO-EGRESS VERDICT
# ═══════════════════════════════════════════════════════════════════════════

count
if [ -e "$CANARY" ]; then
  fail "L1: a network or model entry point was invoked during this suite: $(cat "$CANARY")"
fi
ok "L1 NO NETWORK, NO MODEL CALL: the claude/gh/curl/wget canaries on PATH were never invoked"

count
"$WORK/bin/curl" --self-test >/dev/null 2>&1
[ -e "$CANARY" ] || fail "L2: the canary itself does not work, so L1 proves nothing"
rm -f "$CANARY"
ok "L2 the canary is functional — L1 is a measurement, not a tautology"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION V — emit coverage has THREE states, not two (temperloop#1534)
# ═══════════════════════════════════════════════════════════════════════════
# `observed_seats == 0` used to be indistinguishable between an UNREAD stream,
# a read stream with no emit-feasible seat in it, and a real wiring defect. All
# three rendered as a hard 0% under a disclosure asserting the defect. Since a
# standalone comparison drives no /build pipeline seat, EVERY clean run accused
# itself of "a defect with a declared owner".
count
# (b) STRUCTURAL ZERO — the lake reads fine and holds records, but NONE from an
# emit-feasible seat. That is what a standalone comparison always looks like:
# replay-candidate and replay-judge are deliberately excluded from the
# numerator, so a run driving no /build pipeline work observes 0 of 3 by
# construction. This is the ordinary case, and the one that was being libelled.
# Its own fixture, not $FLAT — $FLAT's lake NAMES feasible seats, so it is case
# (c) and would prove the opposite of what V1 claims.
STRUCT="$WORK/structural-zero"; mkrepo "$STRUCT"
fill "$STRUCT/.temperloop/model-comparison/baseline.jsonl"  claude-opus-4-8  24 5000 0
fill "$STRUCT/.temperloop/model-comparison/candidate.jsonl" claude-sonnet-5  24 4200 90 8
lake "$STRUCT" replay-candidate replay-judge
run "$STRUCT"; cp "$RUN_OUT" "$WORK/struct.json"
[ "$(jqf "$WORK/struct.json" '.emit_coverage.observed_seats')" = "0" ] \
  || fail "V1: the fixture must observe ZERO feasible seats, got $(jqf "$WORK/struct.json" '.emit_coverage.observed_seats')"
[ "$(jqf "$WORK/struct.json" '.emit_coverage.lake.records_n')" != "0" ] \
  || fail "V1: the fixture lake must hold records, or this is the unavailable case rather than the structural one"
[ "$(jqf "$WORK/struct.json" '.emit_coverage.zero_is_structural')" = "true" ] \
  || fail "V1: a run that drove no pipeline seat must report its 0% as STRUCTURAL, got $(jqf "$WORK/struct.json" '.emit_coverage.zero_is_structural')"
jq -e '.emit_coverage.zero_statement | test("STRUCTURAL, not a defect")' "$WORK/struct.json" >/dev/null 2>&1 \
  || fail "V1: the structural zero must SAY it is not a defect: $(jqf "$WORK/struct.json" '.emit_coverage.zero_statement')"
jq -e '.emit_coverage.zero_statement | test("does not apply here")' "$WORK/struct.json" >/dev/null 2>&1 \
  || fail "V1: the structural zero must say below_100_means does not describe this run"
ok "V1 a run whose lake holds records but no emit-feasible seat reports its 0% as STRUCTURAL, and says the defect framing does not apply"

count
# The honesty disclosures must survive the fix — the contract is explicit that
# the unconditional-honesty property is not weakened to solve this.
for _k in below_100_means below_100_does_not_mean feasible_seat_roster excluded_seats; do
  [ "$(jqf "$FLAT_OUT" ".emit_coverage | has(\"$_k\")")" = "true" ] \
    || fail "V2: the emit-coverage disclosure '$_k' disappeared — the fix must not weaken unconditional honesty"
done
jq -e '.emit_coverage.below_100_means | test("GIVEN that an emit-feasible seat ran")' "$FLAT_OUT" >/dev/null 2>&1 \
  || fail "V2: below_100_means must state its own precondition rather than asserting a defect unconditionally"
ok "V2 every emit-coverage disclosure is still present, and below_100_means now states its precondition"

count
# (a) UNREAD STREAM — reported as unavailable, never as 0%. An unread stream is
# not evidence of a wiring defect, and rounding it to zero manufactures one out
# of a missing file.
NOLAKE="$WORK/no-such-lake"
# The var is EXPORTED inside the subshell, not passed via `env`: run_with_timeout
# is a shell function, and `env VAR=x <function>` cannot invoke one — it looks for
# an executable and finds nothing, which is why the first draft produced an empty
# file and V3 failed with a blank value rather than a wrong one.
run_nolake() { ( cd "$1" && export MODEL_USAGE_RAW_DIR="$NOLAKE" && run_with_timeout 120 bash "$PRODUCER" ) >"$WORK/nolake.json" 2>/dev/null; }
run_nolake "$FLAT"
[ "$(jq -r '.emit_coverage.coverage_pct' "$WORK/nolake.json")" = "null" ] \
  || fail "V3: an unreadable stream must report a NULL percentage, got $(jq -r '.emit_coverage.coverage_pct' "$WORK/nolake.json")"
[ "$(jq -r '.emit_coverage.zero_is_structural' "$WORK/nolake.json")" = "false" ] \
  || fail "V3: an unread stream is not a structural zero — the two are different statements"
jq -e '.emit_coverage.unavailable_reason | test("could not be read at all")' "$WORK/nolake.json" >/dev/null 2>&1 \
  || fail "V3: the unavailable case must name itself: $(jq -r '.emit_coverage.unavailable_reason' "$WORK/nolake.json")"
ok "V3 an absent attribution stream reports UNAVAILABLE with a null percentage, not a hard 0%"

count
# (c) A REAL FIGURE — a feasible seat DID run. Without this, V1 and V3 would be
# compatible with a producer that never reports a percentage at all.
SEATRUN="$WORK/seat-ran"; mkrepo "$SEATRUN"
fill "$SEATRUN/.temperloop/model-comparison/baseline.jsonl"  claude-opus-4-8  24 5000 0
fill "$SEATRUN/.temperloop/model-comparison/candidate.jsonl" claude-sonnet-5  24 4200 90 8
lake "$SEATRUN" pipeline-drive-safe
run "$SEATRUN"; cp "$RUN_OUT" "$WORK/seatran.json"
[ "$(jqf "$WORK/seatran.json" '.emit_coverage.observed_seats')" -ge 1 ] \
  || fail "V4: the fixture must observe a feasible seat, or V1/V3 prove only that no figure is ever reported"
[ "$(jqf "$WORK/seatran.json" '.emit_coverage.zero_is_structural')" = "false" ] \
  || fail "V4: a run where a feasible seat DID run is not a structural zero"
[ "$(jqf "$WORK/seatran.json" '.emit_coverage.zero_statement')" = "null" ] \
  || fail "V4: the structural statement must be absent when it does not apply"
ok "V4 a run where an emit-feasible seat DID run reports a real percentage and is not marked structural"
# SECTION Q — the QUALITY axis (temperloop#1609) and its two bases (#1744)
# ═══════════════════════════════════════════════════════════════════════════
# Built from the REAL judge scores of the temperloop#1656 A/A validation run,
# not from invented numbers. That run put the SAME model in both arms with
# zero provider config, so the true quality difference is ZERO BY
# CONSTRUCTION and any winner the report mints from it is a false positive.
# It is the one input where the right answer is known independently of the
# code under test, which is what makes it worth carrying as a fixture.
#
# It also reproduces the #1744 basis split exactly: 18 outcomes judged in BOTH
# arms, plus 5 judged only in the baseline and 4 only in the candidate (legs
# lost to REPLAY_CANDIDATE_TIMEOUT_SECS). Those 9 unpaired rows are why the
# paired and unpaired relative deltas come out 3.4 points apart.
AA="$WORK/aa-quality"
mkrepo "$AA"
AA_B="$AA/.temperloop/model-comparison/baseline.jsonl"
AA_C="$AA/.temperloop/model-comparison/candidate.jsonl"
: >"$AA_B"; : >"$AA_C"

# pr:baseline_q:candidate_q:first_arm — the 18 outcomes judged in both arms,
# carrying the run's ACTUAL 9/9 counterbalanced order split. The positions
# matter: since temperloop#1606 the winner gate reads the order-effect check on
# THIS axis, and without stamps the fixture reports cleanliness as `null` and
# exercises nothing. With them it reproduces the real run's finding — a quality
# order effect of +4.4 judge points against an arm effect of -3.8, i.e. NOT
# clean, on a run whose true arm effect is zero by construction.
aa_i=0
for t in 1332:55:59:b 1336:55:53:b 1340:77:72:c 1341:64:70:b 1359:61:67:b 1489:60:71:b \
         1507:48:50:c 1519:52:56:b 1532:80:66:c 1547:44:56:c 1548:56:44:c 1550:80:60:b \
         1569:41:2:c 1573:60:57:b 1581:58:54:c 1583:62:52:c 1637:60:60:b 1638:64:60:c; do
  aa_i=$(( aa_i + 1 ))
  pr="${t%%:*}"; rest="${t#*:}"; bq="${rest%%:*}"; rest="${rest#*:}"
  cq="${rest%%:*}"; first="${rest#*:}"
  if [ "$first" = "b" ]; then bpos=1; cpos=2; else bpos=2; cpos=1; fi
  record "$pr" claude-opus-5 5000 100 pass true JUDGED "$bq" 2026-08-20 scored \
    | mk_stamp "$aa_i" "$bpos" baseline counterbalanced >>"$AA_B"
  record "$pr" claude-opus-5 5000 100 pass true JUDGED "$cq" 2026-08-20 scored \
    | mk_stamp "$aa_i" "$cpos" candidate counterbalanced >>"$AA_C"
done
# Judged in the BASELINE arm only — the candidate leg timed out.
for t in 1329:56 1508:50 1551:55 1636:55 1653:60; do
  record "${t%%:*}" claude-opus-5 5000 100 pass true JUDGED "${t#*:}" 2026-08-20 scored >>"$AA_B"
done
# Judged in the CANDIDATE arm only.
for t in 1437:62 1522:63 1572:62 1574:60; do
  record "${t%%:*}" claude-opus-5 5000 100 pass true JUDGED "${t#*:}" 2026-08-20 scored >>"$AA_C"
done
lake "$AA" pipeline-drive-safe retro-judge
run "$AA"
AA_OUT="$WORK/aa-quality.json"
cp "$RUN_OUT" "$AA_OUT"

count
[ "$RUN_RC" -eq 0 ] || fail "Q1: the producer must exit 0 on the A/A quality fixture, got $RUN_RC"
[ "$(jqf "$AA_OUT" '.quality_comparison.paired.n')" = "18" ] \
  || fail "Q1: expected 18 outcomes judged in both arms, got $(jqf "$AA_OUT" '.quality_comparison.paired.n')"
ok "Q1 the quality axis pairs on judged-in-BOTH-arms rows only (18 of 23 and 22)"

count
# THE ONE THAT MATTERS, and temperloop#1741's acceptance check. The quality
# axis IS the minting axis since temperloop#1606 — and on this run the true
# effect is ZERO BY CONSTRUCTION, so any winner is a false positive.
#
# Three independent conditions each withhold here, which is the point: even if
# one were wrongly satisfied the other two still refuse.
[ "$(jqf "$AA_OUT" '.quality_comparison.mints_winner')" = "true" ] \
  || fail "Q2: the quality axis must BE the minting axis (temperloop#1606)"
[ "$(jqf "$AA_OUT" '.comparison.winner_axis')" = "quality" ] \
  || fail "Q2: the report must name quality as the deciding axis, got $(jqf "$AA_OUT" '.comparison.winner_axis')"
[ "$(jqf "$AA_OUT" '.comparison.mints_winner')" = "false" ] \
  || fail "Q2: the COST axis must mint nothing"
[ "$(jqf "$AA_OUT" '.comparison | has("winner")')" = "false" ] \
  || fail "Q2: a winner was minted on a known-zero A/A run: $(jqf "$AA_OUT" '.comparison.winner')"
[ "$(jqf "$AA_OUT" '.quality_comparison.below_min_sample')" = "true" ] \
  || fail "Q2: n=18 is below the floor of 20 and must be reported as such"
[ "$(jqf "$AA_OUT" '.quality_comparison.execution_order.comparison_is_clean')" = "false" ] \
  || fail "Q2: the quality order effect (+4.4 pts) is comparable to its arm effect (-3.8) — this run is NOT clean on the minting axis"
ok "Q2 quality is the minting axis, cost mints nothing, and the known-zero A/A run still names NO winner — floor and order-effect gates both refusing"

count
# #1744: the two bases disagree here, and the report must SAY so rather than
# publish whichever it happened to compute.
[ "$(jqf "$AA_OUT" '.quality_comparison.basis_agreement.bases_disagree')" = "true" ] \
  || fail "Q3: the paired and unpaired bases differ by 3.4 points and must be disclosed as disagreeing"
q_paired="$(jqf "$AA_OUT" '.quality_comparison.paired.relative_delta_pct')"
q_unpaired="$(jqf "$AA_OUT" '.quality_comparison.unpaired.relative_delta_pct')"
[ "$q_paired" = "-6.3" ] || fail "Q3: paired relative delta expected -6.3, got $q_paired"
[ "$q_unpaired" = "-2.9" ] || fail "Q3: unpaired relative delta expected -2.9, got $q_unpaired"
ok "Q3 both quality bases are published, labelled, and their disagreement disclosed (-6.3% paired vs -2.9% unpaired)"

count
# Only ONE of the two bases straddles the 5% bar. That is the whole reason
# #1744 exists, so pin it: publishing the unpaired figure alone would report a
# pass on a run whose paired reading breaches.
awk -v p="$q_paired" -v u="$q_unpaired" 'BEGIN{
  pa=(p<0?-p:p); ua=(u<0?-u:u);
  exit !(pa > 5 && ua < 5)
}' || fail "Q4: the fixture no longer straddles the 5% bar across bases, so it cannot prove the disclosure matters"
ok "Q4 the fixture straddles the 5% bar across bases — paired breaches it, unpaired does not"

count
# Every quality statistic must be CONSUMED from stats.sh, exactly as section H
# asserts for the cost axis: independently re-run the library over the report
# own published delta array and demand the same numbers back.
q_deltas="$(jq -c '.quality_comparison.deltas' "$AA_OUT")"
q_ind="$(bash "$SCRIPTS_DIR/model-comparison/stats.sh" verdict --deltas "$q_deltas" --min-sample 1 2>/dev/null)"
q_sd_ind="$(jq -r '.stddev' <<<"$q_ind")"
q_sd_rep="$(jqf "$AA_OUT" '.quality_comparison.minimum_detectable_effect.observed_stddev')"
[ "$q_sd_ind" = "$q_sd_rep" ] \
  || fail "Q5: the published quality stddev ($q_sd_rep) is not stats.sh own ($q_sd_ind) — it is being recomputed somewhere"
q_mde_ind="$(bash "$SCRIPTS_DIR/model-comparison/stats.sh" mde --n 18 --stddev "$q_sd_ind" 2>/dev/null | jq -r '.mde')"
q_mde_rep="$(jqf "$AA_OUT" '.quality_comparison.minimum_detectable_effect.mde')"
[ "$q_mde_ind" = "$q_mde_rep" ] \
  || fail "Q5: the published quality MDE ($q_mde_rep) is not stats.sh own ($q_mde_ind)"
ok "Q5 the quality CI/MDE are byte-identical to an independent stats.sh call over the published deltas"

count
# The power projection must be INVERTED from the MDE beside it, never a second
# derivation — so it is always at the same power and confidence.
q_needed="$(jqf "$AA_OUT" '.quality_comparison.power_projection.pairs_needed')"
q_pct="$(jqf "$AA_OUT" '.quality_comparison.power_projection.target_effect_pct')"
q_bmean="$(jqf "$AA_OUT" '.quality_comparison.paired.baseline_mean')"
# Re-derive the target from the published MEAN and PERCENTAGE, not from the
# published target_effect_points: that field is rounded for a human reader
# (2.99 renders as 3), while the producer projects from the unrounded value.
# The +/-1 tolerance is that same rounding, and is deliberately tight enough
# that a genuinely different formula still fails.
awk -v mde="$q_mde_rep" -v sd="$q_sd_rep" -v n=18 -v bmean="$q_bmean" -v pct="$q_pct" -v got="$q_needed" 'BEGIN{
  tgt = bmean * pct / 100;
  k = mde * sqrt(n) / sd;
  exact = (k * sd / tgt) ^ 2;
  want = int(exact); if (exact > want) want++;      # ceil
  d = got - want; if (d < 0) d = -d;
  exit !(d <= 1)
}' || fail "Q6: pairs_needed ($q_needed) is not the inversion of the published MDE at a ${q_pct}% bar on a ${q_bmean}-point baseline mean"
[ "$q_needed" -gt 18 ] \
  || fail "Q6: the fixture must be UNDER-powered for its own bar, or the projection proves nothing"
ok "Q6 the power projection inverts the published MDE, and reports this run under-powered for a ${q_pct}% bar ($q_needed pairs needed, 18 observed)"

count
# A record scored in both arms but judged in only one must contribute NO
# quality delta — never a substituted zero, which would be a real judgment the
# run never obtained. The 9 unpaired rows above are exactly that case.
[ "$(jqf "$AA_OUT" '.quality_comparison.deltas | length')" = "18" ] \
  || fail "Q7: the delta array must hold exactly the 18 paired outcomes"
[ "$(jqf "$AA_OUT" '.quality_comparison.unpaired.baseline_judged_n')" = "23" ] \
  || fail "Q7: expected 23 baseline-judged rows"
[ "$(jqf "$AA_OUT" '.quality_comparison.unpaired.candidate_judged_n')" = "22" ] \
  || fail "Q7: expected 22 candidate-judged rows"
ok "Q7 a row judged in only one arm contributes no delta rather than a substituted zero"

count
# Q8 — AN ARM THAT JUDGED NOTHING. A batch whose candidate legs are every one
# an integration-error record produces exactly this: baseline rows judged,
# candidate rows carrying no judge block at all. The relative-delta bindings
# guard the DENOMINATOR (the baseline mean), which is not enough — the
# numerator can be null too, and `null - 70` aborts the whole derivation,
# taking the entire report down with it rather than reporting one axis as
# unavailable. Caught in CI by test_replay_batch.sh J1, pinned here at the
# producer where the defect actually lives.
NOJ="$WORK/no-judged-candidate"
mkrepo "$NOJ"
record 700 claude-opus-4-8 5000 100 pass true JUDGED 70 2026-08-20 scored \
  >"$NOJ/.temperloop/model-comparison/baseline.jsonl"
record 700 claude-sonnet-5 4200 100 pass true none 0 2026-08-20 scored \
  >"$NOJ/.temperloop/model-comparison/candidate.jsonl"
lake "$NOJ" pipeline-drive-safe retro-judge
run "$NOJ"
NOJ_OUT="$WORK/no-judged-candidate.json"; cp "$RUN_OUT" "$NOJ_OUT"
[ "$RUN_RC" -eq 0 ] \
  || fail "Q8: an arm with zero judged rows must not take the report down, got rc=$RUN_RC: $(head -c 300 "$NOJ_OUT")"
jq -e 'type == "object" and has("schema_version")' "$NOJ_OUT" >/dev/null 2>&1 \
  || fail "Q8: the producer skipped instead of reporting: $(head -c 300 "$NOJ_OUT")"
[ "$(jqf "$NOJ_OUT" '.quality_comparison.paired.n')" = "0" ] \
  || fail "Q8: expected 0 paired quality outcomes, got $(jqf "$NOJ_OUT" '.quality_comparison.paired.n')"
[ "$(jqf "$NOJ_OUT" '.quality_comparison.unpaired.candidate_mean')" = "null" ] \
  || fail "Q8: an arm that judged nothing must report a null mean, never a substituted 0"
[ "$(jqf "$NOJ_OUT" '.quality_comparison.statistics_unavailable_reason')" != "null" ] \
  || fail "Q8: the quality axis must say WHY it has no statistics, not fall silent"
# The COST axis is untouched by a quality-side absence — the two must degrade
# independently, or one missing judge takes the whole comparison with it.
[ "$(jqf "$NOJ_OUT" '.comparison.paired_outcomes_n')" = "1" ] \
  || fail "Q8: the cost axis must still pair normally when the quality axis cannot: $(jqf "$NOJ_OUT" '.comparison.paired_outcomes_n')"
ok "Q8 an arm that judged nothing degrades the quality axis alone — named reason, null means, cost axis intact"

# ── Q9-Q11: the mint moved to quality (temperloop#1606) ────────────────────
# Q9 is the POLARITY proof, and it is the one that caught a real bug before it
# shipped. stats.sh assumes LOWER IS BETTER — correct for cost, backwards for
# quality — so reading its verdict straight through names the LOSER:
#     stats.sh verdict --deltas '[8,9,10]'  ->  "baseline_better"
# on three deltas meaning the candidate scored 8-10 points BETTER.
# mkq <repo> <n> <baseline-q> <candidate-q-offset> <cost-arm-delta>
# A qoff of 0 means NO quality difference at all — the jitter is suppressed
# too, or the fixture would carry a small quality win and Q11 could not test
# what it claims to.
mkq() {
  local repo="$1" n="$2" bq="$3" qoff="$4" costd="$5" i=1
  mkrepo "$repo"
  local bf="$repo/.temperloop/model-comparison/baseline.jsonl"
  local cf="$repo/.temperloop/model-comparison/candidate.jsonl"
  : >"$bf"; : >"$cf"
  while [ "$i" -le "$n" ]; do
    record $(( 3000 + i )) claude-opus-4-8 5000 100 pass true JUDGED "$bq" 2026-08-20 scored >>"$bf"
    # Cost carries a jitter for the same reason quality does: a constant delta
    # array is `degenerate` to stats.sh and yields no_significant_difference,
    # so a fixture built that way could not produce the COST win Q11 needs.
    record $(( 3000 + i )) claude-sonnet-5 $(( 5000 + costd + (i % 4) * 40 )) 100 pass true \
      JUDGED $(( bq + qoff + (qoff == 0 ? 0 : i % 3) )) 2026-08-20 scored >>"$cf"
    i=$(( i + 1 ))
  done
  lake "$repo" pipeline-drive-safe retro-judge
}

count
QUP="$WORK/q-candidate-better"; mkq "$QUP" 24 60 8 0
run "$QUP"; cp "$RUN_OUT" "$WORK/qup.json"
[ "$(jqf "$WORK/qup.json" '.quality_comparison.library_verdict')" = "baseline_better" ] \
  || fail "Q9: the fixture no longer reproduces the polarity trap — stats.sh should call these deltas baseline_better"
[ "$(jqf "$WORK/qup.json" '.quality_comparison.verdict')" = "candidate_better" ] \
  || fail "Q9: the library verdict must be TRANSLATED into quality polarity, got $(jqf "$WORK/qup.json" '.quality_comparison.verdict')"
[ "$(jqf "$WORK/qup.json" '.comparison.winner')" = "candidate" ] \
  || fail "Q9: THE CANDIDATE SCORED HIGHER AND MUST WIN — got $(jqf "$WORK/qup.json" '.comparison.winner'). Reading stats.sh straight through names the loser."
ok "Q9 POLARITY: the candidate scoring HIGHER wins, though stats.sh (lower-is-better) calls the same deltas baseline_better"

count
QDN="$WORK/q-baseline-better"; mkq "$QDN" 24 60 -8 0
run "$QDN"; cp "$RUN_OUT" "$WORK/qdn.json"
[ "$(jqf "$WORK/qdn.json" '.quality_comparison.verdict')" = "baseline_better" ] \
  || fail "Q10: a candidate scoring LOWER must read baseline_better, got $(jqf "$WORK/qdn.json" '.quality_comparison.verdict')"
[ "$(jqf "$WORK/qdn.json" '.comparison.winner')" = "baseline" ] \
  || fail "Q10: the candidate scored LOWER and the baseline must win, got $(jqf "$WORK/qdn.json" '.comparison.winner')"
ok "Q10 …and the candidate scoring LOWER loses — the translation is directional, not a blanket flip"

count
# Q11 — COST CANNOT MINT. A large, consistent cost win with NO quality
# difference must name NO winner. This is the #1262 failure made impossible:
# that run minted `candidate` on cost alone while quality said nothing.
QNC="$WORK/q-cost-only"; mkq "$QNC" 24 60 0 -3000
run "$QNC"; cp "$RUN_OUT" "$WORK/qnc.json"
[ "$(jqf "$WORK/qnc.json" '.comparison.verdict')" = "candidate_better" ] \
  || fail "Q11: the fixture must produce a COST win, or it proves nothing: $(jqf "$WORK/qnc.json" '.comparison.verdict')"
[ "$(jqf "$WORK/qnc.json" '.comparison | has("winner")')" = "false" ] \
  || fail "Q11: a cost win with no quality difference must name NO winner, got $(jqf "$WORK/qnc.json" '.comparison.winner')"
ok "Q11 a decisive COST win with no quality difference names NO winner — the #1262 false positive is now structurally impossible"
# SECTION R — is the order-effect decomposition outlier-driven? (#1741)
# ═══════════════════════════════════════════════════════════════════════════
# arm_effect and order_effect are two MEANS over a heavy-tailed distribution.
# The #1656 A/A run reported arm 6,596 against order 330,525 — a reassuring 50x,
# read as "position is doing the work, not the model". Drop the largest-|delta|
# record from each order group and it INVERTS to arm 131,144 / order 47,696. The
# tidy near-zero arm effect was coincidental cancellation, and the report said
# nothing about it.
count
# Built from the REAL #1656 cost deltas and their real 9/9 order split, so this
# reproduces the actual inversion rather than a constructed one.
ROB="$WORK/robustness-aa"; mkrepo "$ROB"
ROB_B="$ROB/.temperloop/model-comparison/baseline.jsonl"
ROB_C="$ROB/.temperloop/model-comparison/candidate.jsonl"
: >"$ROB_B"; : >"$ROB_C"
rob_i=0
# pr:baseline_input:candidate_input:first_arm — inputs chosen so the weighted
# delta reproduces the run's own shape (two extremes, one per order group).
for t in 1547:4099298:516347:c 1548:1789537:1095888:c 1340:1109796:1069486:c \
         1569:548630:515558:c 1583:587397:1189537:c 1581:571703:919720:c \
         1638:1346052:1637986:c 1507:665606:780916:c 1532:1023386:1100604:c \
         1550:230436:488166:b 1341:522660:730684:b 1332:1083035:1123187:b \
         1573:1277715:1323200:b 1336:1654904:1891444:b 1489:742268:934316:b \
         1637:332171:1935550:b 1519:610160:971472:b 1359:1257386:1346811:b; do
  rob_i=$(( rob_i + 1 ))
  pr="${t%%:*}"; rest="${t#*:}"; bi="${rest%%:*}"; rest="${rest#*:}"
  ci="${rest%%:*}"; first="${rest#*:}"
  if [ "$first" = "b" ]; then bpos=1; cpos=2; else bpos=2; cpos=1; fi
  record "$pr" claude-opus-5 "$bi" 0 pass true JUDGED 60 2026-08-20 scored \
    | jq -c '.candidate.tokens = {input:.candidate.tokens.input, output:0, cache_read:0, cache_creation:0}' \
    | mk_stamp "$rob_i" "$bpos" baseline counterbalanced >>"$ROB_B"
  record "$pr" claude-opus-5 "$ci" 0 pass true JUDGED 60 2026-08-20 scored \
    | jq -c '.candidate.tokens = {input:.candidate.tokens.input, output:0, cache_read:0, cache_creation:0}' \
    | mk_stamp "$rob_i" "$cpos" candidate counterbalanced >>"$ROB_C"
done
lake "$ROB" pipeline-drive-safe retro-judge
run "$ROB"; cp "$RUN_OUT" "$WORK/rob.json"
[ "$(jqf "$WORK/rob.json" '.execution_order | has("robustness")')" = "true" ] \
  || fail "R1: the execution_order block publishes no robustness disclosure"
r_flips="$(jqf "$WORK/rob.json" '.execution_order.robustness.verdict_flips')"
[ "$r_flips" = "true" ] \
  || fail "R1: this fixture reproduces the #1656 inversion and must report verdict_flips true, got $r_flips (headline arm $(jqf "$WORK/rob.json" '.execution_order.arm_effect') / order $(jqf "$WORK/rob.json" '.execution_order.order_effect'); trimmed arm $(jqf "$WORK/rob.json" '.execution_order.robustness.arm_effect_trimmed'))"
jq -e '.execution_order.robustness.statement | test("DOES NOT SURVIVE ITS OWN OUTLIERS")' "$WORK/rob.json" >/dev/null 2>&1 \
  || fail "R1: a flipped verdict must SAY the finding does not survive its outliers"
ok "R1 a decomposition carried by two records reports verdict_flips and says the headline ratio is a corpus artifact"

count
# The disclosure must WITHHOLD NOTHING — it is not a second gate. The run's
# clean/not-clean verdict, and any winner, are decided exactly as before.
r_clean_before="$(jqf "$WORK/rob.json" '.comparison.comparison_is_clean')"
[ -n "$r_clean_before" ] \
  || fail "R2: the cleanliness verdict disappeared"
[ "$(jqf "$WORK/rob.json" '.execution_order.robustness.dropped_per_group')" = "1" ] \
  || fail "R2: the disclosure must state how many records it dropped per group"
ok "R2 the robustness block is a disclosure, not a gate — it drops 1 per group, states it, and changes no verdict"

count
# And a decomposition that SURVIVES its outliers says so, or the field would be
# a permanent alarm nobody reads.
[ "$(jqf "$ORD_CLEAN_OUT" '.execution_order.robustness.verdict_flips')" = "false" ] \
  || fail "R3: the clean counterbalanced fixture must NOT report a flip, got $(jqf "$ORD_CLEAN_OUT" '.execution_order.robustness.verdict_flips')"
jq -e '.execution_order.robustness.statement | test("SURVIVES its own outliers")' "$ORD_CLEAN_OUT" >/dev/null 2>&1 \
  || fail "R3: a surviving decomposition must say so positively"
ok "R3 a decomposition that survives its own outliers says so — the field is a finding, not a permanent alarm"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION S — THE CROSS-VENDOR COST AXIS (temperloop#1742)
# ═══════════════════════════════════════════════════════════════════════════
# ONE SPEND_WEIGHT_* set is applied to BOTH arms. That is correct within one
# vendor (the weights cancel out of the delta) and indefensible across two.
# The axis must therefore say WHICH case it is in, and declare itself
# UNAVAILABLE with a named reason rather than publish an incomparable figure.
# Two further properties are pinned here because both are silent failures:
# an absent token class must read UNMAPPED and never as a vendor that bills
# zero, and the verdict must be a DISCLOSURE — it may not move a single cost
# number, or the three-surface weighting identity (batch.sh
# spend_reconciliation, emit-model-usage.sh, this producer) would be broken
# by the very block that exists to protect it.

REPO_ROOT="$(cd -P "$SCRIPTS_DIR/../.." && pwd)"

# The flattering run is SAME-VENDOR by construction (fill() stamps provider
# "anthropic" on both arms), so it is the comparable-case fixture.
count
[ "$(jqf "$FLAT_OUT" '.cost_basis.cross_vendor.comparable')" = "true" ] \
  || fail "S1: a same-vendor comparison must report cross_vendor.comparable true, got $(jqf "$FLAT_OUT" '.cost_basis.cross_vendor.comparable')"
[ "$(jqf "$FLAT_OUT" '.cost_basis.cross_vendor.state')" = "same-provider" ] \
  || fail "S1: expected state same-provider, got $(jqf "$FLAT_OUT" '.cost_basis.cross_vendor.state')"
[ "$(jqf "$FLAT_OUT" '.cost_basis.cross_vendor.arm_tariffs.baseline.provider')" = "anthropic" ] \
  || fail "S1: the baseline arm tariff must name the provider read off the records"
[ "$(jqf "$FLAT_OUT" '.cost_basis.cross_vendor.arm_tariffs.candidate.provider')" = "anthropic" ] \
  || fail "S1: the candidate arm tariff must name the provider read off the records"
ok "S1 a same-vendor comparison reports the cost axis COMPARABLE and names each arm's tariff"

# ── the cross-vendor fixture: byte-identical records, one provider changed ──
# Built from the SAME fill() calls as the flattering run, so every token count
# is identical and the ONLY difference is candidate.provider. That is what
# makes S3 below a real no-arithmetic-change proof rather than a coincidence.
XV="$WORK/crossvendor"
mkrepo "$XV"
fill "$WORK/xv-base.jsonl" claude-opus-4-8 24 5000 0
fill "$WORK/xv-cand.jsonl" claude-sonnet-5 24 4200 90 8
cp "$WORK/xv-base.jsonl" "$XV/.temperloop/model-comparison/baseline.jsonl"
jq -c '.candidate.provider = "openai"' "$WORK/xv-cand.jsonl" \
  >"$XV/.temperloop/model-comparison/candidate.jsonl"
lake "$XV" pipeline-drive-safe retro-judge
run "$XV"; cp "$RUN_OUT" "$WORK/crossvendor.json"

count
[ "$(jqf "$WORK/crossvendor.json" '.cost_basis.cross_vendor.comparable')" = "false" ] \
  || fail "S2: two arms on different providers must report comparable false, got $(jqf "$WORK/crossvendor.json" '.cost_basis.cross_vendor.comparable')"
[ "$(jqf "$WORK/crossvendor.json" '.cost_basis.cross_vendor.state')" = "provider-differs" ] \
  || fail "S2: expected state provider-differs, got $(jqf "$WORK/crossvendor.json" '.cost_basis.cross_vendor.state')"
jq -e '.cost_basis.cross_vendor.reason | test("anthropic") and test("openai")' "$WORK/crossvendor.json" >/dev/null 2>&1 \
  || fail "S2: the reason must NAME both providers, got: $(jqf "$WORK/crossvendor.json" '.cost_basis.cross_vendor.reason')"
jq -e '.cost_basis.cross_vendor.reason | test("candidate.provider")' "$WORK/crossvendor.json" >/dev/null 2>&1 \
  || fail "S2: the reason must say WHICH record field the vendor fact was read from"
[ "$(jqf "$WORK/crossvendor.json" '.cost_basis.cross_vendor.arm_tariffs.candidate.provider')" = "openai" ] \
  || fail "S2: arm_tariffs must carry the per-arm providers it judged on"
ok "S2 a cross-vendor comparison declares the cost axis UNAVAILABLE with a named reason, not a published delta"

count
# THE VERDICT IS A DISCLOSURE, NOT A REPRICING. Every cost figure in the
# cross-vendor report must be byte-identical to the same-vendor one built from
# the same token counts: a single weight set still prices both arms, so
# batch.sh spend_reconciliation, emit-model-usage.sh and this producer keep
# counting a token the same way. If this assertion ever fails, the axis has
# started repricing rather than reporting.
[ "$(jq -S -c '.arms' "$FLAT_OUT")" = "$(jq -S -c '.arms' "$WORK/crossvendor.json")" ] \
  || fail "S3: the cross-vendor verdict changed a per-arm cost figure — it must disclose, never reprice"
[ "$(jq -S -c '.comparison.deltas' "$FLAT_OUT")" = "$(jq -S -c '.comparison.deltas' "$WORK/crossvendor.json")" ] \
  || fail "S3: the cross-vendor verdict changed the paired deltas"
[ "$(jq -S -c '.cost_basis.weights' "$FLAT_OUT")" = "$(jq -S -c '.cost_basis.weights' "$WORK/crossvendor.json")" ] \
  || fail "S3: the cross-vendor verdict introduced a second weight set"
ok "S3 the verdict is a DISCLOSURE: not one cost figure, delta or weight moves between the same- and cross-vendor runs"

# ── AN UNPRICED CLASS, IN THE SHAPES REAL RECORDS ACTUALLY HAVE ────────────
# The shape that matters is NOT a deleted key. replay.sh (the only writer of
# candidate.tokens) builds the block with `<envelopeField> // 0` for all four
# classes, so a class the vendor envelope never carried arrives as **0 on
# every record** — never as an absent key. A check that keys on key-absence
# is unreachable from the live pipeline, and would pass its own fixture while
# the silent zero it exists to stop sailed through production untouched
# (temperloop#1742 review round 1). Both fixtures below therefore use record
# shapes replay.sh can actually emit: 0 on every row (today) and null on
# every row (after temperloop#2275 makes the vendor fact recoverable).
ZA="$WORK/zero-all"
mkrepo "$ZA"
cp "$WORK/xv-base.jsonl" "$ZA/.temperloop/model-comparison/baseline.jsonl"
jq -c '.candidate.tokens.cache_creation = 0' "$WORK/xv-cand.jsonl" \
  >"$ZA/.temperloop/model-comparison/candidate.jsonl"
lake "$ZA" pipeline-drive-safe retro-judge
run "$ZA"; cp "$RUN_OUT" "$WORK/zero-all.json"

NC="$WORK/null-class"
mkrepo "$NC"
cp "$WORK/xv-base.jsonl" "$NC/.temperloop/model-comparison/baseline.jsonl"
jq -c '.candidate.tokens.cache_creation = null' "$WORK/xv-cand.jsonl" \
  >"$NC/.temperloop/model-comparison/candidate.jsonl"
lake "$NC" pipeline-drive-safe retro-judge
run "$NC"; cp "$RUN_OUT" "$WORK/null-class.json"

count
# THE REAL SHAPE, UNDER ONE PROVIDER. 0 on every record is what replay.sh
# writes both for a class the vendor never billed AND for a class genuinely
# billed at zero. Under same-provider both arms share ONE envelope shape, so
# the ambiguity cannot bite: it is a measured zero, a real cost fact the delta
# must carry, and withholding here would defeat the same-vendor comparison the
# axis exists for (temperloop#2059 is Anthropic-only). DISCLOSED, not refused
# — review round 2.
[ "$(jqf "$WORK/zero-all.json" '.cost_basis.cross_vendor.arm_tariffs.candidate.zero_on_every_record_token_classes | join(",")')" = "cache_creation" ] \
  || fail "S4: a class reading 0 on every record must still be DISCLOSED in zero_on_every_record_token_classes, got $(jqf "$WORK/zero-all.json" '.cost_basis.cross_vendor.arm_tariffs.candidate.zero_on_every_record_token_classes | tostring')"
[ "$(jqf "$WORK/zero-all.json" '.cost_basis.cross_vendor.comparable')" = "true" ] \
  || fail "S4: under ONE provider an all-zero class is a measured zero and must NOT withhold the axis, got comparable=$(jqf "$WORK/zero-all.json" '.cost_basis.cross_vendor.comparable') reason=$(jqf "$WORK/zero-all.json" '.cost_basis.cross_vendor.reason')"
jq -e '.cost_basis.cross_vendor.reason | test("DISCLOSURE, not a refusal")' "$WORK/zero-all.json" >/dev/null 2>&1 \
  || fail "S4: the reason must say plainly that this is a disclosure rather than a refusal"
jq -e '.cost_basis.cross_vendor.reason | test("temperloop#2275")' "$WORK/zero-all.json" >/dev/null 2>&1 \
  || fail "S4: the reason must still name the replay.sh ambiguity and its filed root cause"
# The RULE itself is stated, not merely enacted — a reader of the block can
# tell why the two unpriced shapes withhold differently.
jq -e '.cost_basis.cross_vendor.unmapped_vs_zero_note | test("EVERY state") and test("one provider")' "$WORK/zero-all.json" >/dev/null 2>&1 \
  || fail "S4: the note must state the rule: unmapped refuses in every state, all-zero only when the arms are not on one provider"
if jq -e '.cost_basis.cross_vendor.unmapped_vs_zero_note | test("BOTH withhold")' "$WORK/zero-all.json" >/dev/null 2>&1; then
  fail "S4: the note still carries the round-1 blanket claim that both shapes withhold"
fi
# …and a class carrying real non-zero values lands in NEITHER bucket, so the
# bucket assertion above is a discrimination rather than a blanket alarm.
[ "$(jqf "$WORK/zero-all.json" '[.cost_basis.cross_vendor.arm_tariffs.candidate | .unmapped_token_classes[], .zero_on_every_record_token_classes[]] | index("cache_read")')" = "null" ] \
  || fail "S4: cache_read carries real values here and must be in neither unpriced bucket"
ok "S4 under ONE provider a class reading 0 on every record is DISCLOSED as a measured zero and does not withhold the axis"

count
# THE SAME CLASS, THE SAME ZEROS, ARMS ON TWO VENDORS. Now the two arms
# envelopes can differ, the all-zero reading is not available, and the class is
# named beside the provider verdict so a reader does not take it for a
# measurement. This is the pair that makes S4 a RULE rather than a blanket
# permission (review round 2).
ZX="$WORK/zero-all-crossvendor"
mkrepo "$ZX"
cp "$WORK/xv-base.jsonl" "$ZX/.temperloop/model-comparison/baseline.jsonl"
jq -c '.candidate.provider = "openai" | .candidate.tokens.cache_creation = 0' "$WORK/xv-cand.jsonl" \
  >"$ZX/.temperloop/model-comparison/candidate.jsonl"
lake "$ZX" pipeline-drive-safe retro-judge
run "$ZX"; cp "$RUN_OUT" "$WORK/zero-all-crossvendor.json"
[ "$(jqf "$WORK/zero-all-crossvendor.json" '.cost_basis.cross_vendor.comparable')" = "false" ] \
  || fail "S4b: with the arms on two vendors the axis must be withheld"
[ "$(jqf "$WORK/zero-all-crossvendor.json" '.cost_basis.cross_vendor.arm_tariffs.candidate.zero_on_every_record_token_classes | join(",")')" = "cache_creation" ] \
  || fail "S4b: the zero class must still be reported per arm"
jq -e '.cost_basis.cross_vendor.reason | test("cache_creation")' "$WORK/zero-all-crossvendor.json" >/dev/null 2>&1 \
  || fail "S4b: the withheld reason must NAME the zero class, not only the provider mismatch: $(jqf "$WORK/zero-all-crossvendor.json" '.cost_basis.cross_vendor.reason')"
if jq -e '.cost_basis.cross_vendor.reason | test("DISCLOSURE, not a refusal")' "$WORK/zero-all-crossvendor.json" >/dev/null 2>&1; then
  fail "S4b: the measured-zero disclosure wording must NOT appear when the arms are on two vendors"
fi
ok "S4b the same all-zero class, with the arms on two vendors, is named in the withheld reason instead — S4 is a rule, not a blanket permission"

count
# SAME PROVIDER, WITHHELD ANYWAY — the case that caught the round-2 reason
# wording. A same-provider run CAN be withheld: by an unmapped class. Gating
# the all-zero sentences on comparability rather than on the STATE sent this
# run down the cross-vendor branch, where it asserted two things that are
# false of it — that the arms were not on one provider, and that the axis was
# withheld on the provider verdict (review round 3 [MEDIUM]).
MW="$WORK/mixed-withheld"
mkrepo "$MW"
jq -c '.candidate.tokens.cache_creation = null' "$WORK/xv-base.jsonl" \
  >"$MW/.temperloop/model-comparison/baseline.jsonl"
jq -c '.candidate.tokens.cache_creation = 0' "$WORK/xv-cand.jsonl" \
  >"$MW/.temperloop/model-comparison/candidate.jsonl"
lake "$MW" pipeline-drive-safe retro-judge
run "$MW"; cp "$RUN_OUT" "$WORK/mixed-withheld.json"
[ "$(jqf "$WORK/mixed-withheld.json" '.cost_basis.cross_vendor.state')" = "same-provider" ] \
  || fail "S4c: fixture precondition — both arms must be on one provider, got $(jqf "$WORK/mixed-withheld.json" '.cost_basis.cross_vendor.state')"
[ "$(jqf "$WORK/mixed-withheld.json" '.cost_basis.cross_vendor.comparable')" = "false" ] \
  || fail "S4c: the unmapped class must withhold the axis even under one provider"
jq -e '.cost_basis.cross_vendor.reason | test("UNMAPPED")' "$WORK/mixed-withheld.json" >/dev/null 2>&1 \
  || fail "S4c: the reason must name the unmapped class as the thing withholding"
# THE REGRESSION ITSELF: no sentence may claim this run spans two providers,
# nor that the provider verdict is what withheld it.
if jq -e '.cost_basis.cross_vendor.reason | test("NOT on one provider")' "$WORK/mixed-withheld.json" >/dev/null 2>&1; then
  fail "S4c: a same-provider run must never be told it is not on one provider: $(jqf "$WORK/mixed-withheld.json" '.cost_basis.cross_vendor.reason')"
fi
if jq -e '.cost_basis.cross_vendor.reason | test("already withheld on the provider verdict")' "$WORK/mixed-withheld.json" >/dev/null 2>&1; then
  fail "S4c: this run is withheld on the unmapped class, not on the provider verdict"
fi
jq -e '.cost_basis.cross_vendor.reason | test("NOT on this")' "$WORK/mixed-withheld.json" >/dev/null 2>&1 \
  || fail "S4c: the all-zero class must be disclosed as a measured zero and explicitly NOT credited with the refusal"
ok "S4c same provider, withheld on an unmapped class: the all-zero class is still disclosed as a measured zero and the reason asserts nothing false about the provider"

count
# The post-#2275 shape: an explicit null is the arm saying it never had the
# class at all. Reported APART from the all-zero case, so the distinction
# survives in the output the moment the records can carry it.
[ "$(jqf "$WORK/null-class.json" '.cost_basis.cross_vendor.arm_tariffs.candidate.unmapped_token_classes | join(",")')" = "cache_creation" ] \
  || fail "S5: a class that is null on every record must be reported UNMAPPED, got $(jqf "$WORK/null-class.json" '.cost_basis.cross_vendor.arm_tariffs.candidate.unmapped_token_classes | tostring')"
[ "$(jqf "$WORK/null-class.json" '.cost_basis.cross_vendor.arm_tariffs.candidate.zero_on_every_record_token_classes | length')" = "0" ] \
  || fail "S5: a null class is unmapped, NOT zero-on-every-record — the two buckets must not collapse"
[ "$(jqf "$WORK/null-class.json" '.cost_basis.cross_vendor.comparable')" = "false" ] \
  || fail "S5: an unmapped class must withhold the axis"
jq -e '.cost_basis.cross_vendor.reason | test("UNMAPPED")' "$WORK/null-class.json" >/dev/null 2>&1 \
  || fail "S5: the reason must name the class as unmapped"
# …and it refuses under BOTH provider states. Unlike the all-zero case, a
# class with NO VALUE is a gap rather than a measurement, so one provider does
# not rescue it (review round 2 point 3).
NX="$WORK/null-class-crossvendor"
mkrepo "$NX"
cp "$WORK/xv-base.jsonl" "$NX/.temperloop/model-comparison/baseline.jsonl"
jq -c '.candidate.provider = "openai" | .candidate.tokens.cache_creation = null' "$WORK/xv-cand.jsonl" \
  >"$NX/.temperloop/model-comparison/candidate.jsonl"
lake "$NX" pipeline-drive-safe retro-judge
run "$NX"; cp "$RUN_OUT" "$WORK/null-class-crossvendor.json"
[ "$(jqf "$WORK/null-class-crossvendor.json" '.cost_basis.cross_vendor.comparable')" = "false" ] \
  || fail "S5: a null class must withhold with the arms on two vendors too"
[ "$(jqf "$WORK/null-class.json" '.cost_basis.cross_vendor.state')" = "same-provider" ] \
  || fail "S5: the same-provider null fixture must actually be same-provider, or its refusal proves nothing"
ok "S5 a null-valued class reads UNMAPPED and withholds under BOTH provider states — a gap is not rescued by one vendor, the way a measured zero is"

count
# MUTATION PROOF: empty the class roster the unmapped check walks, so an
# absent class can no longer be detected. S4's fixture must then read
# comparable — proving S4 rides this detection and not something else.
MIRROR_CV="$(mkmirror "$WORK/mcv")"
perl -pi -e 's/^(\s*)\| \(\["input", "cache_read", "cache_creation", "output"\]\) as \$tok_classes$/$1| ([]) as \$tok_classes/' "$MIRROR_CV"
grep -F '| ([]) as $tok_classes' "$MIRROR_CV" >/dev/null \
  || fail "S6: the unmapped-detection mutation did not apply — the proof would be vacuous"
# The REFUSING detection is now the UNMAPPED one (S5's fixture), so that is
# what the mutation has to defeat; the all-zero fixture is run through the same
# mutant to prove its DISCLOSURE bucket is riding the same roster.
run "$NC" "$MIRROR_CV"; cp "$RUN_OUT" "$WORK/null-class-mut.json"
[ "$(jqf "$WORK/null-class-mut.json" '.cost_basis.cross_vendor.comparable')" = "true" ] \
  || fail "S6: with the class roster emptied the null fixture should read comparable — S5 is not riding the detection it claims to"
run "$ZA" "$MIRROR_CV"; cp "$RUN_OUT" "$WORK/zero-all-mut.json"
[ "$(jqf "$WORK/zero-all-mut.json" '.cost_basis.cross_vendor.arm_tariffs.candidate.zero_on_every_record_token_classes | length')" = "0" ] \
  || fail "S6: the mutant must also see no all-zero class — otherwise S4's disclosure is riding something else"
ok "S6 mutation proof: emptying the token-class roster makes S5's null class invisible (the axis wrongly reads comparable) and empties S4's disclosure bucket"

count
# Comparability is REFUSED, never assumed, when the records carry no vendor
# fact at all. A same-tariff assumption nobody can check is exactly what this
# block exists to stop being published as a number.
NP="$WORK/noprovider"
mkrepo "$NP"
jq -c '.candidate.provider = null' "$WORK/xv-base.jsonl" >"$NP/.temperloop/model-comparison/baseline.jsonl"
jq -c '.candidate.provider = null' "$WORK/xv-cand.jsonl" >"$NP/.temperloop/model-comparison/candidate.jsonl"
lake "$NP" pipeline-drive-safe retro-judge
run "$NP"; cp "$RUN_OUT" "$WORK/noprovider.json"
[ "$(jqf "$WORK/noprovider.json" '.cost_basis.cross_vendor.state')" = "provider-unrecorded" ] \
  || fail "S7: records with no provider must be reported as unrecorded, got $(jqf "$WORK/noprovider.json" '.cost_basis.cross_vendor.state')"
[ "$(jqf "$WORK/noprovider.json" '.cost_basis.cross_vendor.comparable')" = "false" ] \
  || fail "S7: an UNESTABLISHED same-tariff assumption must refuse the axis, not assume it"
jq -e '.cost_basis.cross_vendor.reason | test("ESTABLISH")' "$WORK/noprovider.json" >/dev/null 2>&1 \
  || fail "S7: the reason must say the assumption could not be established"
ok "S7 with no provider on the records comparability is REFUSED rather than assumed"

count
# THE SAME-TARIFF ASSUMPTION IS STATED AT THE THREE SITES THE ISSUE NAMES.
jq -e '.cost_basis.cross_vendor.assumption | test("SAME-TARIFF ASSUMPTION")' "$FLAT_OUT" >/dev/null 2>&1 \
  || fail "S8: site 1 of 3 — the producer's cost_basis block must state the same-tariff assumption"
grep -q 'SAME-TARIFF ASSUMPTION' "$SCRIPTS_DIR/build/build.config.sh" \
  || fail "S8: site 2 of 3 — build.config.sh's cost-basis comment block must state the same-tariff assumption"
grep -q 'same-tariff assumption' "$REPO_ROOT/docs/adr/0026-attribution-telemetry-coexists-with-transcript-cost.md" \
  || fail "S8: site 3 of 3 — ADR 0026 must state the same-tariff assumption"
ok "S8 the same-tariff assumption is stated at all three sites: the producer's cost_basis block, build.config.sh, and ADR 0026"

count
# THE SPEND GATE IS A BUDGET CAP, NOT A COMPARISON, AND IS UNCHANGED. The
# pre-flight ceiling stays in house currency under any tariff; this verdict
# must not have leaked into it, nor into either of the other two weighting
# surfaces.
grep -q 'REPLAY_PREFLIGHT_CEILING_TOKENS' "$MC_DIR/replay.sh" \
  || fail "S9: the pre-flight spend ceiling disappeared from replay.sh"
for untouched in "$MC_DIR/replay.sh" "$MC_DIR/batch.sh" "$SCRIPTS_DIR/emit-model-usage.sh"; do
  if grep -q 'cross_vendor' "$untouched"; then
    fail "S9: $untouched must be untouched by the cross-vendor verdict — the spend gate and the weighting surfaces are considered separately from the comparison"
  fi
done
jq -e '.cost_basis.cross_vendor.spend_gate_note | test("REPLAY_PREFLIGHT_CEILING_TOKENS")' "$FLAT_OUT" >/dev/null 2>&1 \
  || fail "S9: the block must state that the spend gate is deliberately unaffected"
ok "S9 the pre-flight spend gate and the other two weighting surfaces are untouched, and the block says so"

count
# MIXED PROVIDERS WITHIN ONE ARM. Not the same failure as two arms on two
# vendors: here a single arm has no ONE tariff to compare at all, so there is
# nothing for the other arm to be compared against (review round 1 [MEDIUM]:
# this state shipped with no fixture behind it).
MX="$WORK/mixed"
mkrepo "$MX"
jq -c 'if (.pr % 2) == 1 then .candidate.provider = "openai" else . end' "$WORK/xv-base.jsonl" \
  >"$MX/.temperloop/model-comparison/baseline.jsonl"
cp "$WORK/xv-cand.jsonl" "$MX/.temperloop/model-comparison/candidate.jsonl"
lake "$MX" pipeline-drive-safe retro-judge
run "$MX"; cp "$RUN_OUT" "$WORK/mixed.json"
[ "$(jqf "$WORK/mixed.json" '.cost_basis.cross_vendor.state')" = "provider-mixed" ] \
  || fail "S10: an arm carrying two providers must report state provider-mixed, got $(jqf "$WORK/mixed.json" '.cost_basis.cross_vendor.state')"
[ "$(jqf "$WORK/mixed.json" '.cost_basis.cross_vendor.comparable')" = "false" ] \
  || fail "S10: a mixed arm has no single tariff — the axis must be withheld"
[ "$(jqf "$WORK/mixed.json" '.cost_basis.cross_vendor.arm_tariffs.baseline.providers_observed | length')" = "2" ] \
  || fail "S10: both observed providers must be listed for the mixed arm, got $(jqf "$WORK/mixed.json" '.cost_basis.cross_vendor.arm_tariffs.baseline.providers_observed | tostring')"
[ "$(jqf "$WORK/mixed.json" '.cost_basis.cross_vendor.arm_tariffs.baseline.provider')" = "null" ] \
  || fail "S10: a mixed arm has no single provider — the scalar field must be null, never one of the two"
jq -e '.cost_basis.cross_vendor.reason | test("MIXES PROVIDERS")' "$WORK/mixed.json" >/dev/null 2>&1 \
  || fail "S10: the reason must say the arm mixes providers"
ok "S10 an arm mixing providers across its own records reports provider-mixed and withholds the axis"

count
# BOTH arms unpriced on the same class: the reason names BOTH, joined — the
# one-arm fixtures above cannot exercise that join.
BO="$WORK/both-unpriced"
mkrepo "$BO"
jq -c '.candidate.tokens.cache_creation = null' "$WORK/xv-base.jsonl" \
  >"$BO/.temperloop/model-comparison/baseline.jsonl"
jq -c '.candidate.tokens.cache_creation = null' "$WORK/xv-cand.jsonl" \
  >"$BO/.temperloop/model-comparison/candidate.jsonl"
lake "$BO" pipeline-drive-safe retro-judge
run "$BO"; cp "$RUN_OUT" "$WORK/both-unpriced.json"
jq -e '.cost_basis.cross_vendor.reason | test("the baseline arm .cache_creation. and the candidate arm .cache_creation.")' "$WORK/both-unpriced.json" >/dev/null 2>&1 \
  || fail "S11: with both arms unpriced the reason must name both, joined: $(jqf "$WORK/both-unpriced.json" '.cost_basis.cross_vendor.reason')"
[ "$(jqf "$WORK/both-unpriced.json" '.cost_basis.cross_vendor.comparable')" = "false" ] \
  || fail "S11: an unmapped class in both arms still withholds the axis"
ok "S11 a class unpriced in BOTH arms names both arms in one joined reason"

count
# THE ROSTER AND THE WEIGHT SET ARE TWO LITERALS IN ONE FILE. A class priced
# by `wu` but missing from the roster would be weighted-but-never-checked —
# precisely the invisible gap this round found in the unmapped predicate. Held
# equal mechanically rather than by eye (review round 1 [LOW]).
[ "$(jqf "$FLAT_OUT" '.cost_basis.cross_vendor.token_classes_priced | sort | join(",")')" \
  = "$(jqf "$FLAT_OUT" '.cost_basis.weights | keys | join(",")')" ] \
  || fail "S12: the checked class roster and the priced weight set have diverged: roster $(jqf "$FLAT_OUT" '.cost_basis.cross_vendor.token_classes_priced | tostring') vs weights $(jqf "$FLAT_OUT" '.cost_basis.weights | keys | tostring')"
ok "S12 the token-class roster the unpriced checks walk is exactly the weight set the cost figures are computed from"

count
# PROVIDER MATCHING IS CASE-INSENSITIVE, and an EMPTY provider string is not
# a vendor fact (review round 1 [LOW]). Fail-closed direction preserved:
# normalisation can only move a verdict toward unrecorded, never toward
# comparable — the empty-string arm below proves that half.
CI="$WORK/case-insensitive"
mkrepo "$CI"
jq -c '.candidate.provider = "Anthropic"' "$WORK/xv-base.jsonl" \
  >"$CI/.temperloop/model-comparison/baseline.jsonl"
jq -c '.candidate.provider = "ANTHROPIC"' "$WORK/xv-cand.jsonl" \
  >"$CI/.temperloop/model-comparison/candidate.jsonl"
lake "$CI" pipeline-drive-safe retro-judge
run "$CI"; cp "$RUN_OUT" "$WORK/case-insensitive.json"
[ "$(jqf "$WORK/case-insensitive.json" '.cost_basis.cross_vendor.state')" = "same-provider" ] \
  || fail "S13: Anthropic and ANTHROPIC are one vendor, got state $(jqf "$WORK/case-insensitive.json" '.cost_basis.cross_vendor.state')"
[ "$(jqf "$WORK/case-insensitive.json" '.cost_basis.cross_vendor.arm_tariffs.baseline.provider')" = "anthropic" ] \
  || fail "S13: the published provider must be the normalised form"
ES="$WORK/empty-provider"
mkrepo "$ES"
jq -c '.candidate.provider = ""' "$WORK/xv-base.jsonl" \
  >"$ES/.temperloop/model-comparison/baseline.jsonl"
cp "$WORK/xv-cand.jsonl" "$ES/.temperloop/model-comparison/candidate.jsonl"
lake "$ES" pipeline-drive-safe retro-judge
run "$ES"; cp "$RUN_OUT" "$WORK/empty-provider.json"
[ "$(jqf "$WORK/empty-provider.json" '.cost_basis.cross_vendor.state')" = "provider-unrecorded" ] \
  || fail "S13: an empty provider string is not a vendor fact — it must read unrecorded, got $(jqf "$WORK/empty-provider.json" '.cost_basis.cross_vendor.state')"
[ "$(jqf "$WORK/empty-provider.json" '.cost_basis.cross_vendor.comparable')" = "false" ] \
  || fail "S13: normalisation must stay fail-closed — an empty provider cannot make the axis comparable"
ok "S13 provider matching is case-insensitive and an empty provider reads unrecorded, never comparable"

echo
echo "test_comparison_report.sh: $pass/$total checks passed"
[ "$pass" -eq "$total" ] || exit 1
