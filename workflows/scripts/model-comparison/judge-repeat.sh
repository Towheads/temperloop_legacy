#!/usr/bin/env bash
#
# judge-repeat.sh — the judge REPEAT-VARIANCE sweep (temperloop#2266, the cheap
# half of temperloop#2209's noise-floor characterisation).
#
# ── WHAT THIS MEASURES, AND WHAT IT DELIBERATELY DOES NOT ───────────────────
# temperloop#2209 found the dual-build pairwise judge returns a CONFIDENT,
# order-stable preference between two samples of the SAME model (margin 17.5,
# then margin 17, `order_agreement: true` both times). "The noise floor" is
# really two different quantities, and conflating them is how the expensive one
# gets built first:
#
#   JUDGE REPEAT VARIANCE  the same two diffs, judged N times. Is margin 17 a
#                          stable property of this pair, or one draw from a wide
#                          distribution?                        ← THIS SCRIPT
#
#   SAMPLE-TO-SAMPLE FLOOR different same-model diffs. What margin does the
#                          judge invent when nothing actually differs?
#                          ← needs k fresh builds; NOT this script
#
# Only the second needs the build machinery, and it is only worth building once
# the first is known: a judge that is unstable on a FIXED pair is indicted on
# its own, and a judge that is stable at ~17 tells the build study exactly what
# it has to measure. Either outcome is decision-relevant, which is what makes
# this the cheap first move — it costs N judge calls and ZERO builds.
#
# ── WHY THIS IS POSSIBLE AT ALL ────────────────────────────────────────────
# `judge.sh pairwise` takes `--record-a` / `--record-b` and never touches a
# worktree: it is a pure function of two STORED records, and runs both position
# orders internally. So an archived pair can be re-judged as often as we like,
# long after its worktrees are gone. This script reconstructs those records
# from the ledger's own `git format-patch` archives.
#
# ── THE CORPUS IS ITS OWN STORE ────────────────────────────────────────────
# Rows go to `judge-repeat.jsonl` via `dual-build-ledger.sh repeat-append`,
# NEVER to `calibration-pairs.jsonl`. ADR 0041 pins that store to BLIND HUMAN
# pairs and computes `calibration.json`'s `n` from it — a machine re-judge is
# not a human label, so recording one there would move the very calibration bar
# this study exists to earn honestly.
#
# ── THE LIVE-CALL TRAP (the same shape replay.sh execute uses) ─────────────
# There is no implicit candidate binary. The caller passes EITHER
# `--judge-runner <cmd>` (a recorded/stubbed runner — how every fixture drives
# this) OR the explicit `--live` flag. With neither, `sweep` prints
# CANNOT_EVALUATE and exits non-zero; it never falls back to a `claude` on
# PATH. That refusal is what makes "the fixture suite issues no live model
# call, ever" a structural property rather than a promise.
#
# ── USAGE ──────────────────────────────────────────────────────────────────
#   judge-repeat.sh sweep --slug S --item-file <json> --n N \
#       ( --judge-runner <cmd> | --live ) [--model ID] [--provider NAME] \
#       [--dir DIR] [--repo PATH] [--base SHA] [--keep-records DIR]
#       Re-judges slug S's archived arm pair N times, appending one
#       judge-repeat row per repeat. Prints a summary object.
#
#   judge-repeat.sh records --slug S --item-file <json> --out-dir DIR \
#       [--dir DIR] [--repo PATH] [--base SHA]
#       Reconstructs the two judge records and stops. The inspection seam:
#       what `sweep` would send, without sending it.
#
#   judge-repeat.sh report --slug S [--dir DIR]
#       Summarises the accumulated corpus for S: the margin distribution, the
#       fair-coin sign test over decisive verdicts, and the order-agreement
#       rate. Statistics come from stats.sh, never hand-rolled here.
#
#   --item-file is a JSON object carrying the item block BOTH records must
#   share: {issue, title, scope, acceptance:[...]}. It has to be supplied
#   because build-level.mjs composes this block from the plan note at run time
#   and never persists it (`itemBlock`, build-level.mjs:5283). The two records
#   MUST agree on it or `judge.sh pairwise` refuses the pair outright
#   (`_je_pairwise_same_item_ok`) — which is the guard that keeps the two
#   position orders differing in nothing but candidate position.
#
#   `--dir` defaults to `<repo>/.temperloop/model-comparison/dual-build`, the
#   same ledger root dual-build-ledger.sh uses. `--base` overrides the base sha
#   read from the arm's own ledger row (needed when an arm gated `fail` and
#   recorded `base_sha: "unknown"`).
#
# ── EXIT CODES ─────────────────────────────────────────────────────────────
#   0  the sweep completed (every repeat reached a verdict, or an UNAVAILABLE
#      repeat was recorded honestly as one — see `unavailable` in the summary)
#   1  CANNOT_EVALUATE — bad arguments, a missing/unusable archive, a record
#      that cannot be reconstructed, or neither runner flag given
#
set -u

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEDGER="$HERE/dual-build-ledger.sh"
JUDGE="$HERE/judge.sh"
STATS="$HERE/stats.sh"

die() { echo "judge-repeat.sh: $1" >&2; exit 1; }

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
}

command -v jq >/dev/null 2>&1 || die "jq not found"
command -v git >/dev/null 2>&1 || die "git not found"
[ -f "$LEDGER" ] || die "dual-build-ledger.sh not found beside this script"

# _jr_repo_root — the DATA-side resolution, matching dual-build-ledger.sh's own
# boundary: the repo a patch is test-applied against follows cwd, never the $0
# climb to the kernel checkout.
_jr_repo_root() {
  git rev-parse --show-toplevel 2>/dev/null || true
}

# _jr_arm_row <rows-file> <slug> <arm> — the LAST row for this (slug, arm).
# Last, not first: a slug re-driven within a level appends again, and the most
# recent row is the one whose head_sha the archive corresponds to.
_jr_arm_row() {
  jq -sc --arg s "$2" --arg a "$3" \
    '[.[] | select(.slug == $s and .arm == $a)] | if length == 0 then null else .[-1] end' "$1"
}

# _jr_reconstruct_diff <repo> <patch> <base> — the cumulative diff the ORIGINAL
# run sent the judge, rebuilt from the archived patch.
#
# Via a throwaway detached worktree + `git am`, not by scraping the patch text:
# a format-patch holds ONE diff per commit, so scraping would concatenate them
# for a multi-commit arm, while the judge was sent `git diff base..HEAD` — a
# single cumulative diff. For the common one-commit arm the two agree, which is
# exactly why scraping would pass a smoke test and silently diverge later.
_jr_reconstruct_diff() {
  local repo="$1" patch="$2" base="$3" wt rc=0
  wt="$(mktemp -d)" || return 1
  rm -rf "$wt"
  if ! git -C "$repo" worktree add --detach "$wt" "$base" >/dev/null 2>&1; then
    git -C "$repo" worktree remove --force "$wt" >/dev/null 2>&1 || true
    return 1
  fi
  if ! git -C "$wt" am --keep-cr <"$patch" >/dev/null 2>&1; then
    git -C "$wt" am --abort >/dev/null 2>&1 || true
    rc=1
  else
    git -C "$wt" diff "$base"..HEAD 2>/dev/null | head -c 200000
  fi
  git -C "$repo" worktree remove --force "$wt" >/dev/null 2>&1 || true
  return $rc
}

# _jr_build_records <repo> <dir> <slug> <item-file> <base-override> <out-dir>
# Writes a.json (baseline) and b.json (candidate), mirroring the record shape
# build-level.mjs:5289 composes: the shared item block, `.candidate`, and the
# diff at `.score.diff.text_excerpt`. Echoes a JSON object describing the pair.
_jr_build_records() {
  local repo="$1" dir="$2" slug="$3" item_file="$4" base_override="$5" out="$6"
  local rows="$dir/rows.jsonl"
  [ -f "$rows" ] || die "no ledger rows at $rows"
  [ -f "$item_file" ] || die "no such --item-file $item_file"
  jq -e . "$item_file" >/dev/null 2>&1 || die "--item-file $item_file is not valid JSON"
  for f in title scope acceptance; do
    jq -e --arg f "$f" 'has($f)' "$item_file" >/dev/null 2>&1 \
      || die "--item-file is missing required field '$f' — both records must carry an IDENTICAL item block or judge.sh pairwise refuses the pair"
  done

  mkdir -p "$out" || die "cannot create record dir $out"
  local pair_meta="[]" arm file row model start_order head_sha base patch diff
  local n=0
  for arm in baseline candidate; do
    row="$(_jr_arm_row "$rows" "$slug" "$arm")"
    [ -n "$row" ] && [ "$row" != "null" ] \
      || die "no ledger row for $slug@$arm — nothing to re-judge"
    [ "$(printf '%s' "$row" | jq -r '.gate')" = "pass" ] \
      || die "$slug@$arm gated '$(printf '%s' "$row" | jq -r '.gate')', so this pair never had a judge verdict (one-arm-only) and a repeat sweep over it would measure nothing"
    model="$(printf '%s' "$row" | jq -r '.model')"
    start_order="$(printf '%s' "$row" | jq -r '.start_order // null')"
    head_sha="$(printf '%s' "$row" | jq -r '.head_sha')"
    base="$base_override"
    [ -n "$base" ] || base="$(printf '%s' "$row" | jq -r '.base_sha')"
    [ -n "$base" ] && [ "$base" != "unknown" ] && [ "$base" != "null" ] \
      || die "$slug@$arm records base_sha '$base' — pass --base <sha> to say what to rebuild the diff against"

    patch="$dir/archives/${slug}@${arm}.patch"
    [ -f "$patch" ] || die "no archived patch at $patch — the pair is not recoverable, which is temperloop#2260"

    diff="$(_jr_reconstruct_diff "$repo" "$patch" "$base")" \
      || die "could not rebuild $slug@$arm's diff from its archive against $base"
    [ -n "$diff" ] || die "$slug@$arm's archive rebuilt to an EMPTY diff — a judge asked to compare nothing would return a meaningless verdict"

    if [ "$arm" = "baseline" ]; then file="$out/a.json"; else file="$out/b.json"; fi
    jq -c --arg provider anthropic --arg model "$model" --arg d "$diff" \
      '{issue: (.issue // null), title: .title, scope: .scope, acceptance: .acceptance}
       + {candidate: {provider: $provider, model: $model},
          score: {diff: {text_excerpt: $d}}}' "$item_file" >"$file" \
      || die "could not compose the $arm record"

    pair_meta="$(printf '%s' "$pair_meta" | jq -c \
      --arg arm "$arm" --arg model "$model" --arg head "$head_sha" --arg base "$base" \
      --argjson so "${start_order:-null}" --argjson bytes "${#diff}" \
      '. + [{arm: $arm, model: $model, start_order: $so, head_sha: $head, base_sha: $base, diff_bytes: $bytes}]')"
    n=$((n + 1))
  done
  printf '%s\n' "$pair_meta"
}

cmd_records() {
  local dir="" slug="" item_file="" repo="" base="" out=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --dir) [ $# -ge 2 ] || die "records: --dir requires a path"; dir="$2"; shift 2 ;;
      --slug) [ $# -ge 2 ] || die "records: --slug requires a value"; slug="$2"; shift 2 ;;
      --item-file) [ $# -ge 2 ] || die "records: --item-file requires a path"; item_file="$2"; shift 2 ;;
      --repo) [ $# -ge 2 ] || die "records: --repo requires a path"; repo="$2"; shift 2 ;;
      --base) [ $# -ge 2 ] || die "records: --base requires a sha"; base="$2"; shift 2 ;;
      --out-dir) [ $# -ge 2 ] || die "records: --out-dir requires a path"; out="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "records: unknown argument $1" ;;
    esac
  done
  [ -n "$slug" ] || die "records: --slug is required"
  [ -n "$item_file" ] || die "records: --item-file is required"
  [ -n "$out" ] || die "records: --out-dir is required"
  [ -n "$repo" ] || repo="$(_jr_repo_root)"
  [ -n "$repo" ] || die "records: no --repo given and cwd is not inside a git working tree"
  [ -n "$dir" ] || dir="$repo/.temperloop/model-comparison/dual-build"

  local meta
  meta="$(_jr_build_records "$repo" "$dir" "$slug" "$item_file" "$base" "$out")" || exit 1
  jq -cn --arg slug "$slug" --arg out "$out" --argjson pair "$meta" \
    '{outcome: "RECORDS", slug: $slug, out_dir: $out, record_a: ($out + "/a.json"), record_b: ($out + "/b.json"), pair: $pair}'
}

cmd_sweep() {
  local dir="" slug="" item_file="" repo="" base="" n="" runner="" live="" model="" provider="" keep=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --dir) [ $# -ge 2 ] || die "sweep: --dir requires a path"; dir="$2"; shift 2 ;;
      --slug) [ $# -ge 2 ] || die "sweep: --slug requires a value"; slug="$2"; shift 2 ;;
      --item-file) [ $# -ge 2 ] || die "sweep: --item-file requires a path"; item_file="$2"; shift 2 ;;
      --repo) [ $# -ge 2 ] || die "sweep: --repo requires a path"; repo="$2"; shift 2 ;;
      --base) [ $# -ge 2 ] || die "sweep: --base requires a sha"; base="$2"; shift 2 ;;
      --n) [ $# -ge 2 ] || die "sweep: --n requires a count"; n="$2"; shift 2 ;;
      --judge-runner) [ $# -ge 2 ] || die "sweep: --judge-runner requires a command"; runner="$2"; shift 2 ;;
      --live) live=1; shift ;;
      --model) [ $# -ge 2 ] || die "sweep: --model requires an id"; model="$2"; shift 2 ;;
      --provider) [ $# -ge 2 ] || die "sweep: --provider requires a name"; provider="$2"; shift 2 ;;
      --keep-records) [ $# -ge 2 ] || die "sweep: --keep-records requires a path"; keep="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "sweep: unknown argument $1" ;;
    esac
  done
  [ -n "$slug" ] || die "sweep: --slug is required"
  [ -n "$item_file" ] || die "sweep: --item-file is required"
  [ -n "$n" ] || die "sweep: --n is required"
  case "$n" in ''|*[!0-9]*) die "sweep: --n must be a positive integer" ;; esac
  [ "$n" -ge 1 ] || die "sweep: --n must be at least 1"
  # THE LIVE-CALL TRAP — see the header. Neither flag is a refusal, never a
  # fallback to whatever `claude` happens to be on PATH.
  if [ -n "$runner" ] && [ -n "$live" ]; then
    die "sweep: --judge-runner and --live are mutually exclusive"
  fi
  [ -n "$runner" ] || [ -n "$live" ] \
    || die "sweep: CANNOT_EVALUATE — pass either --judge-runner <cmd> (recorded) or --live (a real judge call). There is no implicit judge binary."
  [ -f "$JUDGE" ] || die "sweep: judge.sh not found beside this script"
  [ -n "$repo" ] || repo="$(_jr_repo_root)"
  [ -n "$repo" ] || die "sweep: no --repo given and cwd is not inside a git working tree"
  [ -n "$dir" ] || dir="$repo/.temperloop/model-comparison/dual-build"

  local recdir cleanup=1
  if [ -n "$keep" ]; then recdir="$keep"; cleanup=0; else recdir="$(mktemp -d)" || die "sweep: cannot create a scratch dir"; fi

  local meta
  meta="$(_jr_build_records "$repo" "$dir" "$slug" "$item_file" "$base" "$recdir")" || {
    [ "$cleanup" -eq 1 ] && rm -rf "$recdir"
    exit 1
  }

  local judge_model="$model"
  [ -n "$judge_model" ] || judge_model="${MODEL_COMPARISON_JUDGE_MODEL:-}"

  local i=1 compared=0 unavailable=0 out rc verdict pref margin agree om
  while [ "$i" -le "$n" ]; do
    set -- pairwise --record-a "$recdir/a.json" --record-b "$recdir/b.json"
    if [ -n "$runner" ]; then set -- "$@" --judge-runner "$runner"; else set -- "$@" --live; fi
    [ -z "$model" ] || set -- "$@" --model "$model"
    [ -z "$provider" ] || set -- "$@" --provider "$provider"

    out="$(bash "$JUDGE" "$@" 2>/dev/null)"; rc=$?
    verdict="$(printf '%s\n' "$out" | tail -1)"
    if [ "$rc" -eq 0 ] && printf '%s' "$verdict" | jq -e 'has("preference")' >/dev/null 2>&1; then
      pref="$(printf '%s' "$verdict" | jq -r '.preference')"
      margin="$(printf '%s' "$verdict" | jq -r '.margin // 0')"
      agree="$(printf '%s' "$verdict" | jq -r '.order_agreement // false')"
      om="$(printf '%s' "$verdict" | jq -c '[.orders[]? | .margin // null]')"
      compared=$((compared + 1))
      # A repeat whose two position orders DISAGREE is forced to tie/margin 0 by
      # judge.sh. That is recorded as-is, never dropped: dropping it would pull
      # the reported mean margin away from zero and flatter the instrument.
      jq -cn --arg slug "$slug" --arg jm "$judge_model" --argjson idx "$i" \
        --arg pref "$pref" --argjson margin "$margin" --argjson agree "$agree" \
        --argjson om "$om" --argjson pair "$meta" \
        '{slug: $slug, repeat_index: $idx, judge_model: $jm, outcome: "COMPARED",
          preference: $pref, margin: $margin, order_agreement: $agree,
          order_margins: $om, pair: $pair}' \
        | bash "$LEDGER" repeat-append --dir "$dir" --row - >/dev/null \
        || die "sweep: repeat $i judged, but the corpus append failed — refusing to continue on a partial record"
    else
      unavailable=$((unavailable + 1))
      jq -cn --arg slug "$slug" --arg jm "$judge_model" --argjson idx "$i" \
        --argjson rc "$rc" --argjson pair "$meta" \
        '{slug: $slug, repeat_index: $idx, judge_model: $jm, outcome: "UNAVAILABLE",
          preference: null, margin: null, order_agreement: false,
          order_margins: [], judge_exit: $rc, pair: $pair}' \
        | bash "$LEDGER" repeat-append --dir "$dir" --row - >/dev/null \
        || die "sweep: repeat $i was unavailable, and recording that fact ALSO failed"
    fi
    i=$((i + 1))
  done

  [ "$cleanup" -eq 1 ] && rm -rf "$recdir"
  jq -cn --arg slug "$slug" --argjson n "$n" --argjson c "$compared" \
    --argjson u "$unavailable" --arg jm "$judge_model" --argjson pair "$meta" \
    '{outcome: "SWEEP", slug: $slug, repeats: $n, compared: $c, unavailable: $u,
      judge_model: $jm, pair: $pair}'
}

cmd_report() {
  local dir="" slug="" repo=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --dir) [ $# -ge 2 ] || die "report: --dir requires a path"; dir="$2"; shift 2 ;;
      --slug) [ $# -ge 2 ] || die "report: --slug requires a value"; slug="$2"; shift 2 ;;
      --repo) [ $# -ge 2 ] || die "report: --repo requires a path"; repo="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "report: unknown argument $1" ;;
    esac
  done
  [ -n "$slug" ] || die "report: --slug is required"
  [ -n "$repo" ] || repo="$(_jr_repo_root)"
  [ -n "$dir" ] || dir="${repo:-.}/.temperloop/model-comparison/dual-build"

  local rows
  rows="$(bash "$LEDGER" repeat-read --dir "$dir" --slug "$slug")" || exit 1
  local n
  n="$(printf '%s' "$rows" | jq 'length')"
  [ "$n" -gt 0 ] || die "report: no judge-repeat rows for '$slug' — run a sweep first"

  # DECISIVE = a COMPARED repeat that named an arm. A resolved tie is a real
  # verdict but carries no sign, so it belongs in the denominator of neither a
  # sign test nor a win rate — counted and reported separately instead.
  local summary
  summary="$(printf '%s' "$rows" | jq -c '
    {
      n: length,
      compared: ([.[] | select(.outcome == "COMPARED")] | length),
      unavailable: ([.[] | select(.outcome == "UNAVAILABLE")] | length),
      prefer_a: ([.[] | select(.preference == "A")] | length),
      prefer_b: ([.[] | select(.preference == "B")] | length),
      tie: ([.[] | select(.preference == "tie")] | length),
      order_agree: ([.[] | select(.order_agreement == true)] | length),
      margins: [.[] | select(.outcome == "COMPARED") | .margin]
    }
    | . + {decisive: (.prefer_a + .prefer_b)}
    | . + {margin_mean: (if (.margins | length) > 0 then ((.margins | add) / (.margins | length)) else null end),
           margin_min: (.margins | min), margin_max: (.margins | max)}')"

  local decisive prefer_a margins binom="null" ci="null"
  decisive="$(printf '%s' "$summary" | jq -r '.decisive')"
  prefer_a="$(printf '%s' "$summary" | jq -r '.prefer_a')"
  margins="$(printf '%s' "$summary" | jq -c '.margins')"

  # Statistics come from stats.sh — the module's own math, with its own
  # inconclusive floor (MODEL_COMPARISON_MIN_SAMPLE_N) and its own refusal to
  # print an interval below it. Never reimplemented here.
  if [ -f "$STATS" ] && [ "$decisive" -gt 0 ]; then
    binom="$(bash "$STATS" exact-binom --n "$decisive" --k "$prefer_a" 2>/dev/null)" || binom="null"
    [ -n "$binom" ] || binom="null"
  fi
  if [ -f "$STATS" ] && [ "$(printf '%s' "$margins" | jq 'length')" -gt 0 ]; then
    ci="$(bash "$STATS" bootstrap-ci --deltas "$margins" 2>/dev/null)" || ci="null"
    [ -n "$ci" ] || ci="null"
  fi

  jq -cn --arg slug "$slug" --argjson s "$summary" --argjson binom "$binom" --argjson ci "$ci" \
    '{outcome: "REPORT", slug: $slug}
     + $s
     + {sign_test: $binom, margin_ci: $ci,
        sign_test_note: "null_p is a fixed 0.5 fair coin: on a same-model pair the judge should have no side to take. k counts A (the baseline arm).",
        scope_note: "This is JUDGE REPEAT variance over ONE stored pair. It says nothing about sample-to-sample variance across different same-model diffs, and start_order is constant within a single pair so no execution-order effect is testable here."}'
}

[ $# -ge 1 ] || { usage; exit 1; }
sub="$1"; shift
case "$sub" in
  sweep) cmd_sweep "$@" ;;
  records) cmd_records "$@" ;;
  report) cmd_report "$@" ;;
  -h|--help|help) usage; exit 0 ;;
  *) die "unknown subcommand '$sub' (expected sweep, records or report)" ;;
esac
