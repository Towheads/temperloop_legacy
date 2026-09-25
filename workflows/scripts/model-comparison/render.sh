#!/usr/bin/env bash
#
# render.sh — the DECISION-FIRST MARKDOWN RENDERING of a comparison report
# (temperloop#2058, epic #1225 "model comparison harness"). Turns the JSON
# object workflows/scripts/report-producers/model-comparison emits into the
# page a human actually reads to make a model-routing decision: the verdict
# and the winner (or exactly why no winner is named) in the first lines, one
# table of the figures that matter, then the honesty block — sample floor,
# intervals, detectable effect, order effect, corpus window, gate versions,
# cost basis, cross-vendor comparability, emit coverage — and a short list
# of what would change the verdict. Nothing here is a second report: it is
# the producer's report, laid out for a reader instead of for jq.
#
# ── DERIVES NO STATISTIC, INVENTS NO FIGURE ─────────────────────────────
# Every number on the page is copied from the producer's JSON. The only
# transformations are presentational: rounding, thousands separators, and
# milliseconds→minutes on the duration row (labelled as such). A figure the
# producer WITHHELD (a null carrying a stated reason) renders as "n/a" in the
# table and its reason appears verbatim under "Withheld figures" — never as
# 0, never as a blank cell, never re-derived from neighbouring fields. The
# `winner` key is read as the producer minted it: this file never infers a
# winner from a verdict string, a delta's sign, or an interval's position,
# because the producer's three withholding conditions (sample floor, order-
# effect cleanliness, verdict direction) are the whole point of that key and
# a renderer that re-derived it would silently undo them (temperloop#1606).
# The same rule governs the CROSS-VENDOR cost verdict (temperloop#1742):
# `cost_basis.cross_vendor.comparable` is the producer's call, and when it
# reads false this file prints the producer's stated reason IN PLACE OF the
# cost delta — in the Decision line and in the at-a-glance cell. It never
# infers incomparability from a model name or a provider string of its own,
# and a report carrying no `cross_vendor` block renders exactly as it did
# before the block existed.
#
# ── FAIL-CLOSED, LIKE THE REST OF THE MODULE ────────────────────────────
# The producer is a report.d drop-in and therefore exits 0 with one
# `skipped -- model-comparison: <reason>` line when it cannot report; that is
# the right contract for `temperloop report`, which must never be broken by
# one producer. THIS file is the opposite kind of thing — an operator asked
# for a rendering, and a rendering of nothing is a lie — so a skip line, an
# unreadable/absent/empty input, malformed JSON, or an unknown schema
# version is a CANNOT EVALUATE (workflows/scripts/lib/cannot-evaluate.sh,
# reserved exit code 2), with no Markdown written. "Could not render",
# "inconclusive" and "the candidate won" stay three different outputs.
#
# ── INERT, LIKE THE REST OF THE MODULE (ADR 0027) ───────────────────────
# Nothing invokes this file for you. batch.sh prints a one-line pointer to
# it on completion; /telemetry and /check-in surfacing is a separate item
# (temperloop#2061) fed by the optional --summary-out sidecar below.
#
# Usage:
#   render.sh [--in <report.json>]            render an already-produced JSON
#             [--records-dir <dir>]           or run the producer over this
#             [--repo-root <path>]            arm directory (default: the
#                                              producer's own default,
#                                              MODEL_COMPARISON_REPORT_RECORDS_DIR,
#                                              resolved against --repo-root,
#                                              which defaults to the git
#                                              toplevel of the cwd)
#             [--out <report.md>]             write the Markdown here instead
#                                              of stdout
#             [--summary-out <summary.json>]  also write a small machine-
#                                              readable sidecar (schema
#                                              model-comparison-summary-v1)
#   render.sh schema                          print the sidecar's field list
#
# Exit codes: 0 rendered · 2 CANNOT EVALUATE or usage error.
#
# EGRESS: none. No network, no model call, no gh — a producer run is local.

set -uo pipefail

# Physical derivation (`cd -P`) — dir-symlink-composition-safe (temperloop#1557).
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd -P "$HERE/.." && pwd)"
PRODUCER="${MODEL_COMPARISON_RENDER_PRODUCER:-$SCRIPTS_DIR/report-producers/model-comparison}"  # setting:exempt — test/fixture override, mirrors the sibling tests' SUT pins

# shellcheck source=../lib/cannot-evaluate.sh
. "$SCRIPTS_DIR/lib/cannot-evaluate.sh"

SCHEMA_EXPECTED="model-comparison-report-v1"
SUMMARY_SCHEMA="model-comparison-summary-v1"

usage() {
  sed -n '/^# Usage:/,/^# Exit codes/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
}

ce() { cannot_evaluate_emit "render.sh" "$1"; return $?; }

# ── argument parsing — a trailing value-flag with no operand is an error,
#    never a shift-2 spin (the repo's option-loop class, temperloop#1479).
in_file="" records_dir="" repo_root="" out_file="" summary_out=""
if [ "${1:-}" = "schema" ]; then
  cat <<EOF
$SUMMARY_SCHEMA fields: schema_version generated_at_utc report_generated_at_utc baseline_models candidate_models verdict winner winner_axis winner_withheld_reason quality_paired_n quality_min_sample quality_below_min_sample quality_comparison_is_clean cost_verdict cost_paired_n records_dir report_md
EOF
  exit 0
fi
while [ $# -gt 0 ]; do
  case "$1" in
    --in|--records-dir|--repo-root|--out|--summary-out)
      if [ $# -lt 2 ]; then usage; ce "$1 needs a value"; exit 2; fi
      case "$1" in
        --in) in_file="$2" ;;
        --records-dir) records_dir="$2" ;;
        --repo-root) repo_root="$2" ;;
        --out) out_file="$2" ;;
        --summary-out) summary_out="$2" ;;
      esac
      shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; ce "unknown argument: $1"; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { ce "jq is required to render a report and is not on PATH"; exit 2; }

# ── obtain the producer's JSON ──────────────────────────────────────────
scratch="$(mktemp -d "${TMPDIR:-/tmp}/mc-render-XXXXXX")" || { ce "could not create a scratch dir"; exit 2; }
trap 'rm -rf "$scratch"' EXIT
raw="$scratch/report.json"

if [ -n "$in_file" ]; then
  [ -e "$in_file" ] || { ce "input report does not exist: $in_file"; exit 2; }
  [ -r "$in_file" ] || { ce "input report is not readable: $in_file"; exit 2; }
  [ -s "$in_file" ] || { ce "input report is empty: $in_file"; exit 2; }
  cp "$in_file" "$raw" 2>/dev/null || { ce "input report could not be read: $in_file"; exit 2; }
else
  if [ -z "$repo_root" ]; then
    repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)"
  fi
  repo_root="$(cd -P "$repo_root" 2>/dev/null && pwd)" || { ce "--repo-root does not exist"; exit 2; }
  [ -x "$PRODUCER" ] || { ce "the report producer is not executable at $PRODUCER"; exit 2; }
  if [ -n "$records_dir" ]; then
    case "$records_dir" in /*) ;; *) records_dir="$repo_root/$records_dir" ;; esac
    [ -d "$records_dir" ] || { ce "--records-dir does not exist: $records_dir"; exit 2; }
    ( cd "$repo_root" && MODEL_COMPARISON_REPORT_RECORDS_DIR="$records_dir" bash "$PRODUCER" ) >"$raw" 2>"$scratch/producer.err"
  else
    ( cd "$repo_root" && bash "$PRODUCER" ) >"$raw" 2>"$scratch/producer.err"
  fi
  [ -s "$raw" ] || { ce "the report producer printed nothing (stderr: $(head -c 300 "$scratch/producer.err" 2>/dev/null))"; exit 2; }
fi

first_line="$(head -n 1 "$raw")"
case "$first_line" in
  "skipped -- "*)
    ce "the producer could not report — ${first_line#skipped -- }"; exit 2 ;;
esac
jq -e 'type == "object"' "$raw" >/dev/null 2>&1 || { ce "input is not a JSON object (a report is exactly one JSON object)"; exit 2; }
schema="$(jq -r '.schema_version // ""' "$raw")"
[ "$schema" = "$SCHEMA_EXPECTED" ] || { ce "unknown report schema '${schema:-<absent>}' (this renderer understands $SCHEMA_EXPECTED); refusing to render figures it might mislabel"; exit 2; }
jq -e 'has("comparison") and has("quality_comparison") and has("arms")' "$raw" >/dev/null 2>&1 \
  || { ce "report is missing one of comparison / quality_comparison / arms — not a complete $SCHEMA_EXPECTED object"; exit 2; }

# ── the rendering — one jq program, every figure read from the object ───
JQ_RENDER="$(cat <<'JQEOF'
def chunk3: if length <= 3 then [.] else [.[0:3]] + (.[3:] | chunk3) end;
def r1: if . == null then null elif (.|type) != "number" then . else ((. * 10 | round) / 10) end;
def commas:
  if . == null then "n/a"
  elif (.|type) != "number" then tostring
  else
    (r1 | tostring) as $s
    | ($s | split(".")) as $p
    | (if ($p[0] | startswith("-")) then "-" else "" end) as $sign
    | ($p[0] | ltrimstr("-") | explode | reverse | chunk3 | map(reverse | implode) | reverse | join(",")) as $g
    | $sign + $g + (if ($p | length) > 1 then "." + $p[1] else "" end)
  end;
def na: if . == null then "n/a" else (commas) end;
def pct: if . == null then "n/a" else ((. * 1000 | round) / 10 | tostring) + "%" end;
def mins: if . == null then "n/a" else ((. / 60000 | r1) | tostring) + " min" end;
def signed: if . == null then "n/a" elif . > 0 then "+" + (commas) else (commas) end;
def models($arm): ($arm.cost.by_model // {} | keys) as $k | if ($k | length) == 0 then "model not recorded" else ($k | join(", ")) end;
def ci($c): if $c == null or $c.lower == null or $c.upper == null then "n/a" else "[" + ($c.lower | signed) + ", " + ($c.upper | signed) + "]" end;
def bullet($s): "- " + $s;

.arms.baseline as $b | .arms.candidate as $c
| .comparison as $cost | .quality_comparison as $q
| ($cost.winner // null) as $winner
| (models($b)) as $bm | (models($c)) as $cm
| ($q.paired // {}) as $qp | ($q.unpaired // {}) as $qu
| ($q.execution_order // {}) as $qo
# THE CROSS-VENDOR COST VERDICT (temperloop#1742) — read, never re-derived.
# The producer owns it (it owns cost_basis); this file only formats it, the
# same way it already formats weights_caveat and the overlay reasons. An
# OLDER report that carries no cross_vendor block renders exactly as before:
# every use below is guarded on presence, so nothing is invented for a JSON
# that never made the call.
| (.cost_basis.cross_vendor // null) as $cv
| (($cv != null) and ($cv.comparable == false)) as $cv_unavailable
| (if $cv == null then null else ($cv.reason // "no reason stated") end) as $cv_reason
| (
    if $winner != null then
      "**Winner: " + $winner + "** (" + (if $winner == "candidate" then $cm else $bm end) + ") — decided on the " + ($cost.winner_axis // "quality") + " axis."
    elif ($q.below_min_sample == true) then
      "**Inconclusive — below the sample floor.** " + (($qp.n // 0) | tostring) + " outcomes were judged in both arms; the floor is " + (($q.min_sample // "?") | tostring) + ". No winner is named."
    elif ($cost.winner_withheld_reason != null) then
      "**No winner named — the comparison is not clean.** The quality verdict read `" + ($q.verdict // "?") + "`, but arm order and arm are not separable on the judged pairs (details below)."
    elif ($q.verdict == "no_significant_difference") then
      "**No significant quality difference.** No winner is named: the judged pairs do not separate the two models on quality."
    elif ($q.verdict == null) then
      "**No verdict.** The quality statistics could not be computed" + (if $q.statistics_unavailable_reason != null then ": " + $q.statistics_unavailable_reason else "" end) + "."
    else
      "**No winner named** (quality verdict: `" + ($q.verdict | tostring) + "`)."
    end
  ) as $headline
| [
  "# Model comparison — " + $bm + " (baseline) vs " + $cm + " (candidate)",
  "",
  "_Rendered " + (.generated_at_local // .generated_at_utc // "?") + " " + (.display_timezone // "") + " from `" + (.records_dir // "?") + "` · every figure below is copied from the producer JSON; nothing is recomputed here._",
  "",
  "## Decision",
  "",
  $headline,
  "",
  bullet("**Quality (decides):** candidate " + (($qp.absolute_delta) | signed) + " judge points vs baseline on " + (($qp.n // 0) | tostring) + " paired outcomes (" + ($qp.baseline_mean | na) + " → " + ($qp.candidate_mean | na) + "; relative " + (if $qp.relative_delta_pct == null then "n/a" else (($qp.relative_delta_pct | r1 | tostring) + "%") end) + "); 95% CI " + ci($q.confidence_interval) + "; verdict `" + ($q.verdict // "n/a") + "`."),
  (if $cv_unavailable then
     bullet("**Cost (descriptive, decides nothing): UNAVAILABLE for this comparison.** " + $cv_reason)
   else
     bullet("**Cost (descriptive, decides nothing):** candidate minus baseline " + ($cost.confidence_interval.mean | signed) + " cost-weighted units per merged outcome on " + (($cost.paired_outcomes_n // 0) | tostring) + " paired outcomes (negative = candidate cheaper); 95% CI " + ci($cost.confidence_interval) + "; verdict `" + ($cost.verdict // "n/a") + "`.")
   end),
  (if $cost.winner_withheld_reason != null then bullet("**Why no winner:** " + ($cost.winner_withheld_reason | tostring)) else empty end),
  (if ($q.below_min_sample == true) and ($q.inconclusive_note // null) != null then bullet("**Floor note:** " + ($q.inconclusive_note | tostring)) else empty end),
  bullet("**Transferability:** " + ($cost.transferability // "not stated")),
  "",
  "## At a glance",
  "",
  "| axis | baseline | candidate | delta (cand − base) | reads as |",
  "|---|---|---|---|---|",
  "| judge quality, paired mean (points) | " + ($qp.baseline_mean | na) + " | " + ($qp.candidate_mean | na) + " | " + ($qp.absolute_delta | signed) + " | decides the winner; n=" + (($qp.n // 0) | tostring) + " |",
  "| judge quality, unpaired mean (points) | " + ($qu.baseline_mean | na) + " (n=" + (($qu.baseline_judged_n // 0) | tostring) + ") | " + ($qu.candidate_mean | na) + " (n=" + (($qu.candidate_judged_n // 0) | tostring) + ") | " + ($qu.absolute_delta | signed) + " | context only |",
  "| cost per merged outcome (weighted units) | " + ($b.cost.cost_per_merged_outcome | na) + " | " + ($c.cost.cost_per_merged_outcome | na) + " | " + (if $cv_unavailable then "unavailable" else ($cost.confidence_interval.mean | signed) + " (paired mean)" end) + " | " + (if $cv_unavailable then "not comparable — see Decision and Run provenance" else "descriptive" end) + " |",
  "| merged outcomes (pass / scored) | " + (($b.quality.pass_n // 0) | tostring) + " / " + (($b.quality.scored_n // 0) | tostring) + " (" + ($b.quality.pass_rate | pct) + ") | " + (($c.quality.pass_n // 0) | tostring) + " / " + (($c.quality.scored_n // 0) | tostring) + " (" + ($c.quality.pass_rate | pct) + ") | — | could-have-merged rate |",
  "| gate passed / ran | " + (($b.gate_outcomes.passed_n // 0) | tostring) + " / " + (($b.gate_outcomes.ran_n // 0) | tostring) + " | " + (($c.gate_outcomes.passed_n // 0) | tostring) + " / " + (($c.gate_outcomes.ran_n // 0) | tostring) + " | — | mechanical quality gate |",
  "| rework rate (gate failed) | " + ($b.intervention_rework.rework_rate | pct) + " | " + ($c.intervention_rework.rework_rate | pct) + " | — | proxy, not a human log |",
  "| integration errors / attempted | " + (($b.compatibility.integration_error_n // 0) | tostring) + " / " + (($b.compatibility.attempted_n // 0) | tostring) + " | " + (($c.compatibility.integration_error_n // 0) | tostring) + " / " + (($c.compatibility.attempted_n // 0) | tostring) + " | — | compatibility, never quality |",
  "| mean duration per record | " + ($b.duration.mean_ms | mins) + " | " + ($c.duration.mean_ms | mins) + " | — | ms→min conversion only |",
  "| records / scored / judged | " + (($b.records_n // 0) | tostring) + " / " + (($b.scored_n // 0) | tostring) + " / " + (($b.judge_quality.judged_n // 0) | tostring) + " | " + (($c.records_n // 0) | tostring) + " / " + (($c.scored_n // 0) | tostring) + " / " + (($c.judge_quality.judged_n // 0) | tostring) + " | — | denominators |",
  "",
  "## Can this verdict be trusted?",
  "",
  "**Quality axis (the one that decides)**",
  "",
  bullet("Sample: " + (($qp.n // 0) | tostring) + " outcomes judged in both arms; floor " + (($q.min_sample // "?") | tostring) + "; " + (if $q.below_min_sample == true then "BELOW the floor" elif $q.below_min_sample == false then "at or above the floor" else "floor check unavailable" end) + "."),
  bullet("Confidence interval (95%, bootstrap): " + ci($q.confidence_interval) + (if ($q.confidence_interval.degenerate // false) == true then " — degenerate (no observed spread)" else "" end) + "."),
  bullet("Minimum detectable effect: " + ($q.minimum_detectable_effect.disclosure // "not stated")),
  bullet("Power projection: " + ($q.power_projection.statement // "not stated")),
  bullet("Order effect: " + ($qo.statement // "not stated")),
  bullet("Paired vs unpaired bases: " + ($q.basis_agreement.statement // "not stated")),
  bullet("Judge rows lost to outages: baseline " + (($b.judge_quality.degraded_n // 0) | tostring) + ", candidate " + (($c.judge_quality.degraded_n // 0) | tostring) + " (excluded from every mean, listed under Degradations)."),
  "",
  "**Cost axis (descriptive)**",
  "",
  bullet(($cost.mints_no_winner_reason // "the cost axis mints no winner") | split(". ")[0] + "."),
  bullet("Paired outcomes: " + (($cost.paired_outcomes_n // 0) | tostring) + " (baseline pairable " + (($cost.baseline_pairable_n // 0) | tostring) + ", candidate pairable " + (($cost.candidate_pairable_n // 0) | tostring) + "); floor " + (($cost.min_sample // "?") | tostring) + "."),
  bullet("Confidence interval (95%, bootstrap): " + ci($cost.confidence_interval) + "."),
  bullet("Minimum detectable effect: " + ($cost.minimum_detectable_effect.disclosure // "not stated")),
  bullet("Order effect: " + ($cost.order_effect_disclosure // .execution_order.statement // "not stated")),
  "",
  "## What would change this verdict",
  "",
  (if $q.below_min_sample == true then bullet("Reach the sample floor: " + (($q.min_sample // "?") | tostring) + " outcomes judged in both arms are required; this run has " + (($qp.n // 0) | tostring) + ". Judge outages and integration errors both cost paired N without costing a replay to fix (see Degradations).") else empty end),
  (if ($q.power_projection.pairs_needed // null) != null then bullet("To detect a " + (($q.power_projection.target_effect_pct // "?") | tostring) + "% quality difference (" + (($q.power_projection.target_effect_points // "?") | tostring) + " points) at the stated power, " + ($q.power_projection.pairs_needed | tostring) + " judged pairs are needed; this run has " + (($q.power_projection.pairs_observed // 0) | tostring) + ".") else empty end),
  (if $qo.comparison_is_clean == false then bullet("Separate position from arm: the quality comparison is not clean. Re-run under the counterbalanced driver, or add records until the order effect is small next to the arm effect — the withheld reason above says which.") else empty end),
  (if ($qo | has("positions_present")) and ($qo.positions_present == false) then bullet("Record execution order: no judged pair carries a position, so the order effect cannot be estimated. Replay under a driver that stamps `execution_order` (batch.sh does).") else empty end),
  (if (($b.judge_quality.degraded_n // 0) + ($c.judge_quality.degraded_n // 0)) > 0 then bullet("Re-judge the " + ((($b.judge_quality.degraded_n // 0) + ($c.judge_quality.degraded_n // 0)) | tostring) + " outage-degraded rows (`judge.sh judge-batch` on the same arm files) — that adds paired N without re-running any replay.") else empty end),
  (if (($b.compatibility.integration_error_n // 0) + ($c.compatibility.integration_error_n // 0)) > 0 then bullet("Retry the " + ((($b.compatibility.integration_error_n // 0) + ($c.compatibility.integration_error_n // 0)) | tostring) + " integration-error legs (`batch.sh run … --retry-stage <stage>` against the same state dir); they are compatibility facts and contribute no quality or cost pair until they score.") else empty end),
  (if $winner != null then bullet("Nothing here is a routing decision by itself: the winner is a quality verdict at this N on this corpus alone. Read the cost row beside it, and the pre-registered decision rule on the issue for the run, before re-pointing a seat.") else empty end),
  "",
  "## Run provenance",
  "",
  bullet("Report generated " + (.generated_at_utc // "?") + " UTC (" + (.generated_at_local // "?") + " " + (.display_timezone // "") + "); schema `" + (.schema_version // "?") + "`; records dir `" + (.records_dir // "?") + "`."),
  bullet("Corpus window: " + (if .corpus_window.window_unavailable_reason != null then ("not available — " + (.corpus_window.window_unavailable_reason | tostring)) else ((.corpus_window.records_n // 0) | tostring) + " records, PRs " + ((.corpus_window.pr_lowest // "?") | tostring) + "–" + ((.corpus_window.pr_highest // "?") | tostring) + ", replayed " + (.corpus_window.replayed_from_local // "?") + " → " + (.corpus_window.replayed_to_local // "?") + " " + (.corpus_window.display_timezone // "") end) + "."),
  bullet("Gate versions: " + (if .gate_versions.versions_unavailable_reason != null then ("not available — " + (.gate_versions.versions_unavailable_reason | tostring)) else ((.gate_versions.distinct_n // 0) | tostring) + " distinct (gate script, base) pair(s): " + ((.gate_versions.pairs // []) | map((.gate_script // "?") + " @ " + ((.base // "?") | tostring | .[0:8])) | join("; ")) end) + "."),
  bullet("Cost basis: " + (.cost_basis.unit // "?") + "; weights input " + ((.cost_basis.weights.input // "?") | tostring) + ", cache_read " + ((.cost_basis.weights.cache_read // "?") | tostring) + ", cache_creation " + ((.cost_basis.weights.cache_creation // "?") | tostring) + ", output " + ((.cost_basis.weights.output // "?") | tostring) + ". " + (.cost_basis.weights_caveat // "")),
  (if $cv != null then bullet("Cross-vendor cost axis: " + (if $cv.comparable then "COMPARABLE — " else "UNAVAILABLE — " end) + $cv_reason + " " + ($cv.assumption // "")) else empty end),
  bullet("Dollar overlay: " + (if (.cost_basis.list_price_overlay.estimate_usd // null) != null then ("~$" + (.cost_basis.list_price_overlay.estimate_usd | commas) + " (" + (.cost_basis.list_price_overlay.staleness // "staleness not stated") + "; priced: " + ((.cost_basis.list_price_overlay.priced_models // []) | join(", ")) + "; excluded: " + ((.cost_basis.list_price_overlay.excluded_models // []) | if length == 0 then "none" else join(", ") end) + ")") else ("not available — " + (.cost_basis.list_price_overlay.estimate_usd_unavailable_reason // .cost_basis.list_price_overlay.staleness // "no price table resolved" | tostring)) end) + "."),
  bullet("Emit coverage: " + (if (.emit_coverage.zero_is_structural // false) == true then ("structural zero — " + (.emit_coverage.zero_statement // "no emit-feasible seat ran during this comparison" | tostring)) elif (.emit_coverage.coverage_pct // null) != null then ((.emit_coverage.coverage_pct | tostring) + "% (" + ((.emit_coverage.observed_seats // 0) | tostring) + " of " + ((.emit_coverage.feasible_seats // 0) | tostring) + " emit-feasible seats observed)") else ("not available — " + (.emit_coverage.unavailable_reason // "no reason stated" | tostring)) end) + "."),
  "",
  "## Degradations and withheld figures",
  "",
  ([
    ($b.judge_quality.degraded_rows // [] | map(bullet("baseline pr:" + ((.pr // "?") | tostring) + " judge " + (.judge_outcome // "?") + " — " + (.degradation_notice // "no notice")))),
    ($c.judge_quality.degraded_rows // [] | map(bullet("candidate pr:" + ((.pr // "?") | tostring) + " judge " + (.judge_outcome // "?") + " — " + (.degradation_notice // "no notice")))),
    (if $b.cost.errored_uncosted_reason != null then [bullet("baseline cost: " + ($b.cost.errored_uncosted_reason | tostring))] else [] end),
    (if $c.cost.errored_uncosted_reason != null then [bullet("candidate cost: " + ($c.cost.errored_uncosted_reason | tostring))] else [] end),
    (if $b.cost.cost_per_merged_outcome_unavailable_reason != null then [bullet("baseline cost per merged outcome withheld: " + ($b.cost.cost_per_merged_outcome_unavailable_reason | tostring))] else [] end),
    (if $c.cost.cost_per_merged_outcome_unavailable_reason != null then [bullet("candidate cost per merged outcome withheld: " + ($c.cost.cost_per_merged_outcome_unavailable_reason | tostring))] else [] end),
    (if $q.statistics_unavailable_reason != null then [bullet("quality statistics withheld: " + ($q.statistics_unavailable_reason | tostring))] else [] end),
    (if $cost.statistics_unavailable_reason != null then [bullet("cost statistics withheld: " + ($cost.statistics_unavailable_reason | tostring))] else [] end),
    (if ($q.basis_agreement.bases_disagree // false) == true then [bullet("quality bases disagree: " + ($q.basis_agreement.statement | tostring))] else [] end),
    (if ($b.compatibility.by_stage // {} | length) > 0 then [bullet("baseline integration errors by stage: " + ($b.compatibility.by_stage | to_entries | map(.key + "=" + (.value | tostring)) | join(", ")))] else [] end),
    (if ($c.compatibility.by_stage // {} | length) > 0 then [bullet("candidate integration errors by stage: " + ($c.compatibility.by_stage | to_entries | map(.key + "=" + (.value | tostring)) | join(", ")))] else [] end)
  ] | add | if length == 0 then bullet("none — every figure above was measured; nothing was withheld") else .[] end),
  ""
] | .[]
JQEOF
)"

md="$scratch/report.md"
if ! jq -r "$JQ_RENDER" "$raw" >"$md" 2>"$scratch/jq.err"; then
  ce "rendering failed: $(head -c 400 "$scratch/jq.err")"; exit 2
fi
[ -s "$md" ] || { ce "rendering produced no output"; exit 2; }

# ── the optional machine-readable sidecar (temperloop#2061's feed) ─────
if [ -n "$summary_out" ]; then
  if ! jq -c --arg schema "$SUMMARY_SCHEMA" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg md "${out_file:-}" '
    {schema_version: $schema,
     generated_at_utc: $now,
     report_generated_at_utc: (.generated_at_utc // null),
     baseline_models: (.arms.baseline.cost.by_model // {} | keys),
     candidate_models: (.arms.candidate.cost.by_model // {} | keys),
     verdict: (.quality_comparison.verdict // null),
     winner: (.comparison.winner // null),
     winner_axis: (.comparison.winner_axis // null),
     winner_withheld_reason: (.comparison.winner_withheld_reason // null),
     quality_paired_n: (.quality_comparison.paired.n // null),
     quality_min_sample: (.quality_comparison.min_sample // null),
     quality_below_min_sample: .quality_comparison.below_min_sample,
     quality_comparison_is_clean: .quality_comparison.execution_order.comparison_is_clean,
     cost_verdict: (.comparison.verdict // null),
     cost_paired_n: (.comparison.paired_outcomes_n // null),
     records_dir: (.records_dir // null),
     report_md: (if $md == "" then null else $md end)}' "$raw" >"$scratch/summary.json" 2>"$scratch/jq.err"; then
    ce "sidecar rendering failed: $(head -c 400 "$scratch/jq.err")"; exit 2
  fi
  cp "$scratch/summary.json" "$summary_out" || { ce "could not write --summary-out $summary_out"; exit 2; }
fi

if [ -n "$out_file" ]; then
  cp "$md" "$out_file" || { ce "could not write --out $out_file"; exit 2; }
  printf 'render.sh: wrote %s\n' "$out_file" >&2
else
  cat "$md"
fi
exit 0
