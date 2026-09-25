#!/usr/bin/env bash
#
# test_render.sh — fixture suite for the DECISION-FIRST MARKDOWN RENDERER
# (workflows/scripts/model-comparison/render.sh, temperloop#2058).
#
# What it pins, and why each one is load-bearing:
#   A  the WINNER path: a fixture the real producer scores as a clean
#      above-floor quality win renders "Winner: candidate" in the Decision
#      section and in the --summary-out sidecar.
#   B  the FLOOR path: a below-floor fixture renders "Inconclusive — below
#      the sample floor", names N and the floor, and carries NO "Winner:".
#   C  the NOT-CLEAN path: a fixture whose quality delta rides execution
#      position renders "No winner named — the comparison is not clean" and
#      the producer's withheld reason verbatim.
#   D  FAIL-CLOSED inputs: a `skipped --` producer line, an absent, an
#      unreadable, an empty, a non-JSON, and an unknown-schema input each
#      exit RC 2 with the one CANNOT EVALUATE emission path and write no
#      Markdown (the module's #1409 class; registered in
#      check-surface-registry.tsv against this file).
#   E  MUTATION PROOFS that the renderer READS the winner rather than
#      re-deriving it: deleting `comparison.winner` from a winning report
#      removes the winner from the page while the verdict string still
#      says candidate_better; injecting `winner_withheld_reason` renders
#      the reason; nulling a figure renders "n/a", never 0.
#   F  the producer path (--records-dir/--repo-root/--out) renders the
#      same page the --in path does, and the canaries never fire.
#
# HERMETIC BY CONSTRUCTION: synthetic arm records in a tmpdir, the REAL
# producer and REAL stats library over them, and a claude/gh/curl/wget
# canary on PATH asserted never invoked.
#
# Usage: bash workflows/scripts/model-comparison/tests/test_render.sh
# shellcheck disable=SC2016

set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MC_DIR="$(cd -P "$HERE/.." && pwd)"
SCRIPTS_DIR="$(cd -P "$MC_DIR/.." && pwd)"
SUT="$MC_DIR/render.sh"
PRODUCER="$SCRIPTS_DIR/report-producers/model-comparison"

# shellcheck source=../../lib/portable-timeout.sh
. "$SCRIPTS_DIR/lib/portable-timeout.sh"

pass=0; total=0
ok() { pass=$((pass + 1)); echo "PASS: $1"; }
count() { total=$((total + 1)); }
fail() { echo "FAIL: $1" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-render-XXXXXX")"
WORK="$(cd -P "$WORK" && pwd)"
trap 'chmod -R u+rwX "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

# ── canaries ──────────────────────────────────────────────────────────────
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
PATH="$WORK/bin:$PATH"; export PATH

# ── fixture helpers (replay-record-v1 shape, same as the producer suite) ──
mkrepo() { rm -rf "$1"; mkdir -p "$1/.temperloop/model-comparison" "$1/meta/data/raw"; }

# record <pr> <model> <input-tokens> <quality-score> <position 1|2> <day>
record() {
  local pr="$1" model="$2" inp="$3" qs="$4" pos="$5" day="$6"
  jq -cn --argjson pr "$pr" --arg model "$model" --argjson inp "$inp" --argjson qs "$qs" \
    --argjson pos "$pos" --arg day "$day" '
    {pr:$pr, issue:($pr - 100), merge_commit:"mc0001", base:"base0001", head:"head0001",
     title:"item \($pr)", scope:null, acceptance:["does a thing"], notes:"",
     status:"eligible", reject_reason:"", flags:[],
     buckets:{N:["a.sh"], T:["tests/t.sh"], X:[], R:[]},
     template_sha:"tpl0000", file_count:2,
     worktree:{path:"/tmp/wt", branch:"replay/\($pr)", prepared_at:($day + "T10:00:00Z")},
     candidate:{provider:"anthropic", model:$model, diff_ref:"cafe",
                tokens:{input:$inp, output:120, cache_read:2000, cache_creation:100},
                duration_ms:(60000 + $inp), outcome:"scored", integration_error:null,
                disclosed:false, prompt_sha256:"aa"},
     execution_order:{position:$pos, rule:"counterbalanced-by-record-index-v1", seed:0},
     score:{outcome:"SCORED", scored:true, verdict:"pass", not_scored_reason:null,
            base:"base0001", truth_head:"head0001", diff:null,
            gate_result:{outcome:"GATES", ran:true, gate_script:"scripts/quality-gates.sh",
                         exit_code:0, passed:true, timed_out:false, duration_ms:1000, timeout_secs:1800},
            acceptance_results:[], components:null, contamination_flags:[]},
     judge:{outcome:"JUDGED", scored:true, quality_score:$qs, dimensions:{}, rationale:"r", concerns:[],
            judge_provider:"anthropic", judge_model:"claude-opus-4-8", tokens:null, duration_ms:10,
            disclosed:false, prompt_sha256:"bb", guard:{enforced:true}, evaluated_at:"2026-08-20T00:00:00Z"}}'
}

# arms <repo> <n> <mode>  — writes baseline.jsonl + candidate.jsonl.
#   mode=winner    candidate scores +8 (±2 jitter) regardless of position → clean win
#   mode=notclean  candidate scores +14 only when it ran SECOND, +0 when first → order-confounded
#   mode=flat      candidate scores the same as baseline
# Arm order is counterbalanced by record index: baseline runs first on even i.
arms() {
  local repo="$1" n="$2" mode="$3" i=0 bq cq bpos cpos day
  : >"$repo/.temperloop/model-comparison/baseline.jsonl"
  : >"$repo/.temperloop/model-comparison/candidate.jsonl"
  while [ "$i" -lt "$n" ]; do
    day="$(printf '2026-08-%02d' $(( (i % 20) + 1 )))"
    bq=$(( 60 + (i % 7) * 3 ))
    if [ $((i % 2)) -eq 0 ]; then bpos=1; cpos=2; else bpos=2; cpos=1; fi
    case "$mode" in
      winner)   cq=$(( bq + 8 + (i % 3) - 1 )) ;;
      notclean) if [ "$cpos" -eq 2 ]; then cq=$(( bq + 14 )); else cq=$bq; fi ;;
      flat)     cq=$bq ;;
    esac
    record $(( 1000 + i )) claude-opus-5   $(( 200000 + i * 7 )) "$bq" "$bpos" "$day" >>"$repo/.temperloop/model-comparison/baseline.jsonl"
    record $(( 1000 + i )) claude-sonnet-5 $(( 120000 + i * 5 )) "$cq" "$cpos" "$day" >>"$repo/.temperloop/model-comparison/candidate.jsonl"
    i=$(( i + 1 ))
  done
}

produce() { ( cd "$1" && run_with_timeout 120 bash "$PRODUCER" ) >"$2" 2>"$WORK/producer.err"; }

# render <args...> — stdout → $R_OUT, stderr → $R_ERR, rc → $R_RC
R_OUT=""; R_ERR=""; R_RC=0
render() {
  R_OUT="$WORK/render.out"; R_ERR="$WORK/render.err"
  run_with_timeout 120 bash "$SUT" "$@" >"$R_OUT" 2>"$R_ERR"
  R_RC=$?
}
expect_cannot_evaluate() {  # <label>
  [ "$R_RC" -eq 2 ] || fail "$1: expected rc 2, got $R_RC (stderr: $(cat "$R_ERR"))"
  grep -q 'render.sh: CANNOT EVALUATE' "$R_ERR" || fail "$1: no CANNOT EVALUATE human line on stderr: $(cat "$R_ERR")"
  jq -e '.outcome == "CANNOT_EVALUATE"' "$R_OUT" >/dev/null 2>&1 || fail "$1: stdout is not the CANNOT_EVALUATE machine verdict: $(cat "$R_OUT")"
}

# ═══════════════════════════════════════════════════════════════════════════
# A — the winner path
# ═══════════════════════════════════════════════════════════════════════════
WREPO="$WORK/winner"; mkrepo "$WREPO"; arms "$WREPO" 24 winner
WJSON="$WORK/winner.json"; produce "$WREPO" "$WJSON"
count
[ "$(jq -r '.comparison.winner // "ABSENT"' "$WJSON")" = "candidate" ] \
  || fail "A0 fixture precondition: the producer did not mint candidate as the winner: $(jq -c '{w:.comparison.winner, v:.quality_comparison.verdict, floor:.quality_comparison.below_min_sample, clean:.quality_comparison.execution_order.comparison_is_clean}' "$WJSON")"
ok "A0 fixture precondition: the real producer mints candidate as the winner on the winner fixture"

count
render --in "$WJSON" --summary-out "$WORK/winner.summary.json"
[ "$R_RC" -eq 0 ] || fail "A1: rc $R_RC: $(cat "$R_ERR")"
grep -q '^\*\*Winner: candidate\*\* (claude-sonnet-5)' "$R_OUT" || fail "A1: Decision headline does not name the candidate winner with its model: $(grep -n 'Winner\|winner' "$R_OUT" | head -3)"
ok "A1 winner: the Decision headline names 'Winner: candidate' with the candidate's model"

count
head -n 12 "$R_OUT" | grep '^## Decision' >/dev/null || fail "A2: Decision is not within the first 12 lines"
awk '/^## Decision/{f=1;next} /^## /{f=0} f' "$R_OUT" | grep 'Winner: candidate' >/dev/null || fail "A2: the winner is not inside the Decision section"
ok "A2 winner: the verdict is decision-first — inside ## Decision, near the top"

count
jq -e '.schema_version == "model-comparison-summary-v1" and .winner == "candidate" and .winner_axis == "quality" and .verdict == "candidate_better" and .quality_below_min_sample == false and .baseline_models == ["claude-opus-5"] and .candidate_models == ["claude-sonnet-5"]' \
  "$WORK/winner.summary.json" >/dev/null || fail "A3: sidecar fields wrong: $(cat "$WORK/winner.summary.json")"
# cost_verdict travels with the two fields that say whether it is a
# COMPARISON at all — on a same-vendor run, comparable with a null reason.
jq -e '.cost_axis_comparable == true and .cost_axis_unavailable_reason == null' \
  "$WORK/winner.summary.json" >/dev/null \
  || fail "A3: the sidecar must qualify cost_verdict with the cross-vendor verdict: $(cat "$WORK/winner.summary.json")"
ok "A3 sidecar: --summary-out carries winner, axis, verdict, floor flag, both arms' models, and the cross-vendor cost-axis verdict"

count
for f in $(bash "$SUT" schema | sed 's/^[^:]*: //'); do
  jq -e --arg f "$f" 'has($f)' "$WORK/winner.summary.json" >/dev/null || fail "A4: sidecar lacks field '$f' promised by 'render.sh schema'"
done
ok "A4 sidecar: every field 'render.sh schema' promises is present"

count
for row in 'judge quality, paired mean (points)' 'cost per merged outcome (weighted units)' 'integration errors / attempted'; do
  grep -qF "| $row | " "$R_OUT" || fail "A5: the at-a-glance table is missing the '$row' row"
done
[ "$(grep -c '^| ' "$R_OUT")" -ge 10 ] || fail "A5: expected at least 10 table lines, got $(grep -c '^| ' "$R_OUT")"
ok "A5 table: quality, cost and compatibility rows all render"

count
qmean="$(jq -r '.quality_comparison.paired.candidate_mean' "$WJSON")"
grep -q "^| judge quality, paired mean (points) | [0-9.]* | $qmean |" "$R_OUT" || fail "A6: the paired candidate mean $qmean is not the figure on the page: $(grep '^| judge quality, paired' "$R_OUT")"
ok "A6 copied-not-derived: the paired quality mean on the page is byte-for-byte the producer's"

# ═══════════════════════════════════════════════════════════════════════════
# B — the floor path
# ═══════════════════════════════════════════════════════════════════════════
FREPO="$WORK/floor"; mkrepo "$FREPO"; arms "$FREPO" 6 winner
FJSON="$WORK/floor.json"; produce "$FREPO" "$FJSON"
count
[ "$(jq -r '.quality_comparison.below_min_sample' "$FJSON")" = "true" ] || fail "B0 fixture precondition: 6 records should sit below the floor"
[ "$(jq -r '.comparison.winner // "ABSENT"' "$FJSON")" = "ABSENT" ] || fail "B0 fixture precondition: below the floor no winner may exist"
ok "B0 fixture precondition: 6 records are below the floor and carry no winner"

count
render --in "$FJSON"
[ "$R_RC" -eq 0 ] || fail "B1: rc $R_RC: $(cat "$R_ERR")"
grep -q '^\*\*Inconclusive — below the sample floor\.\*\* 6 outcomes were judged in both arms; the floor is 20\.' "$R_OUT" \
  || fail "B1: floor headline missing or wrong: $(awk '/^## Decision/{f=1;next} /^## /{f=0} f' "$R_OUT" | head -3)"
! grep -q 'Winner:' "$R_OUT" || fail "B1: a below-floor page must never say Winner:"
ok "B1 floor: the headline says inconclusive, names N=6 against the floor of 20, and no Winner: appears"

count
grep -q '^- Reach the sample floor: 20 outcomes judged in both arms are required; this run has 6\.' "$R_OUT" \
  || fail "B2: the what-would-change section does not say how to reach the floor"
ok "B2 floor: 'what would change this verdict' says reach the floor, with both numbers from the JSON"

# ═══════════════════════════════════════════════════════════════════════════
# C — the not-clean path
# ═══════════════════════════════════════════════════════════════════════════
NREPO="$WORK/notclean"; mkrepo "$NREPO"; arms "$NREPO" 24 notclean
NJSON="$WORK/notclean.json"; produce "$NREPO" "$NJSON"
count
[ "$(jq -r '.comparison.winner_withheld_reason // "ABSENT"' "$NJSON")" != "ABSENT" ] \
  || fail "C0 fixture precondition: the producer did not withhold a winner on the order-confounded fixture: $(jq -c '{w:.comparison.winner, clean:.quality_comparison.execution_order.comparison_is_clean, arm:.quality_comparison.execution_order.arm_effect, ord:.quality_comparison.execution_order.order_effect, v:.quality_comparison.verdict}' "$NJSON")"
[ "$(jq -r '.comparison.winner // "ABSENT"' "$NJSON")" = "ABSENT" ] || fail "C0 fixture precondition: a withheld winner must be absent"
ok "C0 fixture precondition: the real producer withholds the winner when the quality delta rides execution position"

count
render --in "$NJSON"
[ "$R_RC" -eq 0 ] || fail "C1: rc $R_RC: $(cat "$R_ERR")"
grep -q '^\*\*No winner named — the comparison is not clean\.\*\*' "$R_OUT" || fail "C1: not-clean headline missing"
! grep -q 'Winner:' "$R_OUT" || fail "C1: a withheld-winner page must never say Winner:"
reason="$(jq -r '.comparison.winner_withheld_reason' "$NJSON")"
grep -qF -- "- **Why no winner:** $reason" "$R_OUT" || fail "C1: the producer's withheld reason is not on the page verbatim"
ok "C1 not-clean: headline says no winner, the comparison is not clean, and the withheld reason appears verbatim"

count
grep -q '^- Separate position from arm: the quality comparison is not clean\.' "$R_OUT" || fail "C2: what-would-change lacks the order-effect remedy"
ok "C2 not-clean: 'what would change this verdict' names the order-effect remedy"

# ═══════════════════════════════════════════════════════════════════════════
# D — fail-closed inputs (one emission path, RC 2, no Markdown)
# ═══════════════════════════════════════════════════════════════════════════
count
printf 'skipped -- model-comparison: no arm files under .temperloop/model-comparison\n' >"$WORK/skip.txt"
render --in "$WORK/skip.txt" --out "$WORK/skip.md"
expect_cannot_evaluate "D1 skip line"
grep -q 'the producer could not report — model-comparison: no arm files' "$R_ERR" || fail "D1: the producer's skip reason is not carried into the diagnostic: $(cat "$R_ERR")"
[ ! -e "$WORK/skip.md" ] || fail "D1: a CANNOT EVALUATE must write no --out file"
ok "D1 fail-closed: a 'skipped --' producer line is CANNOT EVALUATE (rc 2), reason carried, no Markdown written"

count
render --in "$WORK/does-not-exist.json"; expect_cannot_evaluate "D2 absent"
grep -q 'does not exist' "$R_ERR" || fail "D2: absent input not named as such"
ok "D2 fail-closed: an absent --in file is CANNOT EVALUATE"

count
: >"$WORK/empty.json"
render --in "$WORK/empty.json"; expect_cannot_evaluate "D3 empty"
grep -q 'is empty' "$R_ERR" || fail "D3: empty input not named as such"
ok "D3 fail-closed: an empty --in file is CANNOT EVALUATE"

count
if [ "$(id -u)" -eq 0 ]; then
  ok "D4 fail-closed: (skipped — running as root, chmod 000 is not unreadable)"
else
  cp "$WJSON" "$WORK/unreadable.json"; chmod 000 "$WORK/unreadable.json"
  render --in "$WORK/unreadable.json"; expect_cannot_evaluate "D4 unreadable"
  grep -q 'not readable' "$R_ERR" || fail "D4: unreadable input not named as such"
  chmod 644 "$WORK/unreadable.json"
  ok "D4 fail-closed: an unreadable --in file is CANNOT EVALUATE"
fi

count
printf 'this is not json\n' >"$WORK/notjson.json"
render --in "$WORK/notjson.json"; expect_cannot_evaluate "D5 non-JSON"
ok "D5 fail-closed: a non-JSON input is CANNOT EVALUATE"

count
jq '.schema_version = "model-comparison-report-v2"' "$WJSON" >"$WORK/drift.json"
render --in "$WORK/drift.json"; expect_cannot_evaluate "D6 schema drift"
grep -q "unknown report schema 'model-comparison-report-v2'" "$R_ERR" || fail "D6: schema drift not named: $(cat "$R_ERR")"
ok "D6 fail-closed: an unknown schema_version is refused rather than rendered with possibly-mislabelled figures"

count
render --in; expect_cannot_evaluate "D7 dangling flag"
render --bogus; expect_cannot_evaluate "D8 unknown flag"
ok "D7/D8 usage: a dangling value-flag and an unknown flag both fail closed, never spin"

# ═══════════════════════════════════════════════════════════════════════════
# E — mutation proofs: the winner is READ, never re-derived
# ═══════════════════════════════════════════════════════════════════════════
count
jq 'del(.comparison.winner)' "$WJSON" >"$WORK/mut-nowinner.json"
[ "$(jq -r '.quality_comparison.verdict' "$WORK/mut-nowinner.json")" = "candidate_better" ] || fail "E1 precondition: verdict must still read candidate_better"
render --in "$WORK/mut-nowinner.json" --summary-out "$WORK/mut.summary.json"
[ "$R_RC" -eq 0 ] || fail "E1: rc $R_RC"
! grep -q 'Winner:' "$R_OUT" || fail "E1 MUTATION PROOF FAILED: with comparison.winner deleted the page still names a winner — the renderer is deriving it from the verdict"
[ "$(jq -r '.winner' "$WORK/mut.summary.json")" = "null" ] || fail "E1: sidecar minted a winner the producer did not"
ok "E1 MUTATION PROOF: deleting comparison.winner removes the winner from page and sidecar even though the verdict still says candidate_better"

count
jq 'del(.comparison.winner) | .comparison.winner_withheld_reason = "FIXTURE-WITHHELD: position is doing the work"' "$WJSON" >"$WORK/mut-withheld.json"
render --in "$WORK/mut-withheld.json"
grep -q '^\*\*No winner named — the comparison is not clean\.\*\*' "$R_OUT" || fail "E2: injected withheld reason did not switch the headline"
grep -qF 'FIXTURE-WITHHELD: position is doing the work' "$R_OUT" || fail "E2: injected withheld reason not on the page"
ok "E2 MUTATION PROOF: an injected winner_withheld_reason renders the not-clean headline and the reason verbatim"

count
jq '.quality_comparison.paired.candidate_mean = null | .arms.candidate.cost.cost_per_merged_outcome = null | .arms.candidate.cost.cost_per_merged_outcome_unavailable_reason = "FIXTURE-WITHHELD-COST"' "$WJSON" >"$WORK/mut-null.json"
render --in "$WORK/mut-null.json"
grep -q '^| judge quality, paired mean (points) | [0-9.]* | n/a |' "$R_OUT" || fail "E3: a nulled candidate mean did not render as n/a: $(grep '^| judge quality, paired' "$R_OUT")"
grep -q '^| cost per merged outcome (weighted units) | [0-9.,]* | n/a |' "$R_OUT" || fail "E3: a nulled cost per merged outcome did not render as n/a: $(grep '^| cost per merged' "$R_OUT")"
grep -qF 'candidate cost per merged outcome withheld: FIXTURE-WITHHELD-COST' "$R_OUT" || fail "E3: the withheld reason is not listed under Degradations"
ok "E3 MUTATION PROOF: a withheld figure renders n/a in the table and its reason under Degradations — never 0, never blank"

# ═══════════════════════════════════════════════════════════════════════════
# F — the producer path, --out, and the canaries
# ═══════════════════════════════════════════════════════════════════════════
count
render --records-dir "$WREPO/.temperloop/model-comparison" --repo-root "$WREPO" --out "$WORK/via-producer.md"
[ "$R_RC" -eq 0 ] || fail "F1: rc $R_RC: $(cat "$R_ERR")"
[ -s "$WORK/via-producer.md" ] || fail "F1: --out wrote nothing"
[ ! -s "$R_OUT" ] || fail "F1: with --out the Markdown must not also go to stdout"
grep -q '^\*\*Winner: candidate\*\*' "$WORK/via-producer.md" || fail "F1: the producer path did not render the winner"
grep -q 'render.sh: wrote ' "$R_ERR" || fail "F1: no wrote-line on stderr"
ok "F1 producer path: --records-dir/--repo-root runs the real producer and --out writes the same page"

count
render --records-dir "$WORK/no-such-dir" --repo-root "$WREPO"; expect_cannot_evaluate "F2 missing records dir"
ok "F2 producer path: a missing --records-dir is CANNOT EVALUATE"

count
EMPTYREPO="$WORK/emptyrepo"; mkrepo "$EMPTYREPO"
render --repo-root "$EMPTYREPO" --out "$WORK/empty.md"; expect_cannot_evaluate "F3 producer skip"
[ ! -e "$WORK/empty.md" ] || fail "F3: no Markdown may be written when the producer skips"
ok "F3 producer path: a repo with no arm files makes the producer skip, and the skip is CANNOT EVALUATE here"

# ═══════════════════════════════════════════════════════════════════════════
# G — THE CROSS-VENDOR COST AXIS (temperloop#1742)
# ═══════════════════════════════════════════════════════════════════════════
# The VERDICT is the producer's; this file only formats it. Three properties:
# an unavailable axis prints the producer's reason WHERE THE DELTA WAS; an
# available one changes the page by exactly the one added line and nothing
# else; and flipping the producer's verdict alone flips the rendering — so
# the substitution rides the verdict rather than the renderer guessing from
# a model name.

count
# The winner fixture is SAME-VENDOR (record() stamps provider "anthropic"),
# so its rendering must differ from the SAME report with the cross_vendor
# block deleted by exactly ONE line: the added disclosure. This is the
# "renders byte-identically to today except for the added cross_vendor
# block" acceptance, measured rather than asserted.
[ "$(jq -r '.cost_basis.cross_vendor.comparable' "$WJSON")" = "true" ] \
  || fail "G1 fixture precondition: the same-vendor winner fixture should read comparable"
jq 'del(.cost_basis.cross_vendor)' "$WJSON" >"$WORK/nocv.json"
render --in "$WJSON";           cp "$R_OUT" "$WORK/cv-with.md"
render --in "$WORK/nocv.json";  cp "$R_OUT" "$WORK/cv-without.md"
added="$(diff "$WORK/cv-without.md" "$WORK/cv-with.md" | grep -c '^> ')"
removed="$(diff "$WORK/cv-without.md" "$WORK/cv-with.md" | grep -c '^< ')"
[ "$added" = "1" ] && [ "$removed" = "0" ] \
  || fail "G1: a same-vendor page must gain exactly the one cross-vendor line and change nothing else (added=$added removed=$removed): $(diff "$WORK/cv-without.md" "$WORK/cv-with.md")"
grep -q '^- Cross-vendor cost axis: COMPARABLE — ' "$WORK/cv-with.md" \
  || fail "G1: the added line must be the cross-vendor disclosure"
ok "G1 same-vendor: the page is byte-identical to one rendered without the block, plus exactly the one added cross_vendor line"

count
# UNAVAILABLE: the producer's reason goes where the delta was. Injected onto
# the real report rather than re-run, so this measures the RENDERER.
jq '.cost_basis.cross_vendor.comparable = false
    | .cost_basis.cross_vendor.state = "provider-differs"
    | .cost_basis.cross_vendor.reason = "FIXTURE-REASON: the arms ran against different providers (anthropic vs openai)"' \
   "$WJSON" >"$WORK/cv-unavailable.json"
render --in "$WORK/cv-unavailable.json"; cp "$R_OUT" "$WORK/cv-unavailable.md"
[ "$R_RC" -eq 0 ] || fail "G2: rc $R_RC: $(cat "$R_ERR")"
grep -q 'Cost (descriptive, decides nothing): UNAVAILABLE for this comparison' "$WORK/cv-unavailable.md" \
  || fail "G2: the Decision cost line must say the axis is unavailable"
grep -q 'FIXTURE-REASON: the arms ran against different providers' "$WORK/cv-unavailable.md" \
  || fail "G2: the producer's reason must be printed verbatim where the delta was"
grep -q '^| cost per merged outcome (weighted units) |.*| unavailable |' "$WORK/cv-unavailable.md" \
  || fail "G2: the at-a-glance delta cell must read unavailable, never a number: $(grep '^| cost per merged outcome' "$WORK/cv-unavailable.md")"
# The delta is REPLACED, not annotated: the phrase that carries the number is
# gone from the page entirely, so no reader can lift an incomparable figure
# off it.
if grep -q 'candidate minus baseline' "$WORK/cv-unavailable.md"; then
  fail "G2: the numeric paired-mean delta must be GONE, not merely annotated: $(grep -n 'candidate minus baseline' "$WORK/cv-unavailable.md")"
fi
# …and the MACHINE-READABLE sidecar must not hand a consumer the very figure
# the page just withheld (review round 1 [MEDIUM]): cost_verdict still rides,
# but now flagged, with the reason beside it.
render --in "$WORK/cv-unavailable.json" --summary-out "$WORK/cv-unavailable.summary.json"
jq -e '.cost_axis_comparable == false' "$WORK/cv-unavailable.summary.json" >/dev/null \
  || fail "G2: the sidecar must flag an incomparable cost axis: $(cat "$WORK/cv-unavailable.summary.json")"
jq -e '.cost_axis_unavailable_reason | test("FIXTURE-REASON")' "$WORK/cv-unavailable.summary.json" >/dev/null \
  || fail "G2: the sidecar must carry the producer's reason verbatim"
jq -e 'has("cost_verdict")' "$WORK/cv-unavailable.summary.json" >/dev/null \
  || fail "G2: cost_verdict must still be present — this is additive flagging, not a schema removal"
for f in $(bash "$SUT" schema | sed 's/^[^:]*: //'); do
  jq -e --arg f "$f" 'has($f)' "$WORK/cv-unavailable.summary.json" >/dev/null \
    || fail "G2: sidecar lacks field '$f' promised by 'render.sh schema'"
done
ok "G2 cross-vendor: the delta is replaced by the producer's named reason, in the Decision line, the at-a-glance cell and the machine-readable sidecar"

count
# MUTATION PROOF: the ONLY difference between these two renders is the
# producer's boolean. Flipping it back must restore the number, so the
# substitution is driven by the verdict and by nothing else on the page.
jq '.cost_basis.cross_vendor.comparable = true' "$WORK/cv-unavailable.json" >"$WORK/cv-flipped.json"
render --in "$WORK/cv-flipped.json"; cp "$R_OUT" "$WORK/cv-flipped.md"
if grep -q 'Cost (descriptive, decides nothing): UNAVAILABLE' "$WORK/cv-flipped.md"; then
  fail "G3: flipping comparable back to true must restore the delta — the renderer is not reading the verdict"
fi
grep -q 'candidate minus baseline' "$WORK/cv-flipped.md" \
  || fail "G3: the numeric delta line did not come back when the verdict said comparable"
grep -q '^| cost per merged outcome (weighted units) |.*(paired mean) |' "$WORK/cv-flipped.md" \
  || fail "G3: the at-a-glance delta cell did not come back"
ok "G3 MUTATION PROOF: flipping cost_basis.cross_vendor.comparable alone flips the rendering both ways"

count
# ONE PREDICATE, FAIL-CLOSED, BOTH SITES (review round 1 [LOW]). A
# `comparable: null` — a shape the producer does not emit, and exactly the
# shape a future one might — used to render inconsistently: the delta was
# published (== false was untrue) while the provenance line already read
# UNAVAILABLE. Both sites now read the same predicate, and anything that is
# not an explicit `true` withholds.
jq '.cost_basis.cross_vendor.comparable = null
    | .cost_basis.cross_vendor.reason = "FIXTURE-NULL: comparability was not established"' \
   "$WJSON" >"$WORK/cv-null.json"
render --in "$WORK/cv-null.json" --summary-out "$WORK/cv-null.summary.json"
cp "$R_OUT" "$WORK/cv-null.md"
[ "$R_RC" -eq 0 ] || fail "G4: rc $R_RC: $(cat "$R_ERR")"
grep -q 'Cost (descriptive, decides nothing): UNAVAILABLE for this comparison' "$WORK/cv-null.md" \
  || fail "G4: a null verdict must withhold the delta, not publish it"
grep -q '^- Cross-vendor cost axis: UNAVAILABLE — ' "$WORK/cv-null.md" \
  || fail "G4: the provenance line must agree with the Decision line"
if grep -q 'candidate minus baseline' "$WORK/cv-null.md"; then
  fail "G4: the numeric delta leaked onto a page whose comparability was never established"
fi
jq -e '.cost_axis_comparable == null and (.cost_axis_unavailable_reason | test("FIXTURE-NULL"))' \
  "$WORK/cv-null.summary.json" >/dev/null \
  || fail "G4: the sidecar must carry the same fail-closed reading: $(cat "$WORK/cv-null.summary.json")"
ok "G4 a comparable:null verdict withholds at BOTH render sites and in the sidecar — one fail-closed predicate, not three readings"

count
[ ! -e "$CANARY" ] || fail "CANARY FIRED: $(cat "$CANARY")"
ok "canary: claude/gh/curl/wget were never invoked"

echo "test_render.sh: $pass/$total checks passed"
[ "$pass" -eq "$total" ]
