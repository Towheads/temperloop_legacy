#!/usr/bin/env bash
#
# test_judge_repeat.sh — judge-repeat.sh, the judge REPEAT-VARIANCE sweep
# (temperloop#2266).
#
# Hermetic by construction: every judge call goes through a RECORDED runner
# (`--judge-runner "bash $JSTUB"`) whose stdout is a canned reply, and a canary
# `claude` is placed FIRST on PATH that fails loudly if anything ever invokes
# it. No network, no gh, no live model, no writes outside $WORK.
#
# Sections:
#   1  records — reconstructs two records from archived patches: identical item
#      blocks (or judge.sh refuses the pair), distinct diffs, real models
#   2  records — REFUSALS: an arm that gated `fail`, a missing archive, an
#      unknown base_sha, a malformed item-file
#   3  sweep — appends one corpus row per repeat and returns an honest summary
#   4  sweep — THE LIVE-CALL TRAP: neither runner flag is CANNOT_EVALUATE, and
#      both together is a refusal
#   5  sweep — an UNAVAILABLE repeat is RECORDED, never silently dropped
#   6  the load-bearing isolation assertion: a sweep leaves calibration.json and
#      calibration-pairs.jsonl untouched (ADR 0041's blind-pair bar must not
#      move because a machine re-judged something)
#   7  report — the sign test, margin stats and order-agreement rate
#   8  DISCRIMINATION CONTROL: the whole suite is worthless if the reconstructor
#      would accept anything, so a deliberately corrupted archive must fail
#
set -u

FAILED=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILED=$((FAILED + 1)); }

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MC="$(cd -P "$HERE/.." && pwd)"
JR="$MC/judge-repeat.sh"
LEDGER="$MC/dual-build-ledger.sh"

[ -f "$JR" ] || { echo "FAIL: judge-repeat.sh not found at $JR" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/jr-test.XXXXXX")" || exit 1
cleanup() {
  # Any worktree the reconstructor left behind would fail this teardown; that
  # is deliberate signal, not noise.
  [ -d "$WORK/repo" ] && git -C "$WORK/repo" worktree prune >/dev/null 2>&1
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

# ── the canary: nothing in this suite may reach a real model ────────────────
mkdir -p "$WORK/bin"
cat >"$WORK/bin/claude" <<'CANARY'
#!/usr/bin/env bash
echo "CANARY: a live claude was invoked by the judge-repeat fixture suite" >&2
touch "${JR_CANARY_TRIPPED:-/tmp/jr-canary-tripped}"
exit 97
CANARY
chmod +x "$WORK/bin/claude"
export JR_CANARY_TRIPPED="$WORK/canary-tripped"
export PATH="$WORK/bin:$PATH"

# ── a real little git repo with two divergent one-commit "arms" ─────────────
REPO="$WORK/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name t
printf 'line one\nline two\nline three\n' >"$REPO/doc.md"
git -C "$REPO" add doc.md
git -C "$REPO" commit -qm base
BASE="$(git -C "$REPO" rev-parse HEAD)"

git -C "$REPO" checkout -qb arm-baseline
printf 'line one\nline two CHANGED BY BASELINE\nline three\n' >"$REPO/doc.md"
git -C "$REPO" commit -qam "baseline arm"
HEAD_A="$(git -C "$REPO" rev-parse HEAD)"

git -C "$REPO" checkout -q "$BASE" 2>/dev/null
git -C "$REPO" checkout -qb arm-candidate
printf 'line one\nline two CHANGED, DIFFERENTLY, BY CANDIDATE\nline three\nplus a line\n' >"$REPO/doc.md"
git -C "$REPO" commit -qam "candidate arm"
HEAD_B="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" checkout -q "$BASE" 2>/dev/null

LED="$WORK/ledger"
mkdir -p "$LED"
SLUG="fixture-item"

mkrow() { # mkrow <arm> <gate> <head> <base>
  jq -cn --arg arm "$1" --arg gate "$2" --arg head "$3" --arg base "$4" --arg slug "$SLUG" \
    --argjson so "$([ "$1" = baseline ] && echo 1 || echo 2)" '
    {tier:"sonnet", model:"claude-sonnet-5", slug:$slug, arm:$arm,
     base_sha:$base, head_sha:$head, start_order:$so, gate:$gate,
     cost:{tokens_in:null,tokens_out:null,wall_clock_ms:1,retry_tokens:null,retry_count:0,recovery:false},
     judge:null, pick:null, override:{applied:false}, loss_reason:null,
     cross_read_attempted:false, guard_armed:"ARMED", machinery_version:"test",
     operator:"t", host:"h"}'
}

bash "$LEDGER" append --dir "$LED" --row "$(mkrow baseline pass "$HEAD_A" "$BASE")" >/dev/null
bash "$LEDGER" append --dir "$LED" --row "$(mkrow candidate pass "$HEAD_B" "$BASE")" >/dev/null

git -C "$REPO" format-patch "$BASE..arm-baseline" --stdout >"$WORK/a.patch" 2>/dev/null
git -C "$REPO" format-patch "$BASE..arm-candidate" --stdout >"$WORK/b.patch" 2>/dev/null
bash "$LEDGER" archive "$SLUG" baseline --dir "$LED" --from "$WORK/a.patch" >/dev/null
bash "$LEDGER" archive "$SLUG" candidate --dir "$LED" --from "$WORK/b.patch" >/dev/null

ITEM="$WORK/item.json"
cat >"$ITEM" <<'ITEMEOF'
{"issue": 4242, "title": "A fixture item", "scope": "doc.md",
 "acceptance": ["line two is changed", "line one survives"]}
ITEMEOF

# ── the recorded judge runner ───────────────────────────────────────────────
JSTUB="$WORK/judge-stub.sh"
cat >"$JSTUB" <<'STUBEOF'
#!/usr/bin/env bash
set -u
COUNT_FILE="${JSTUB_COUNT_FILE:-/tmp/jr-stub-count}"
n=0
[ -f "$COUNT_FILE" ] && n="$(cat "$COUNT_FILE")"
n=$((n + 1))
echo "$n" >"$COUNT_FILE"
if [ -n "${JSTUB_FAIL_AT:-}" ] && [ "$n" -eq "${JSTUB_FAIL_AT}" ]; then
  echo "jstub: forced failure at call $n" >&2
  exit 5
fi
pref="1"; margin=40
if [ -n "${JSTUB_POSITIONS:-}" ]; then
  i=1
  for p in $(printf '%s' "$JSTUB_POSITIONS" | tr ',' ' '); do
    [ "$i" -eq "$n" ] && pref="$p"
    i=$((i + 1))
  done
fi
body="$(jq -cn --arg pref "$pref" --argjson margin "$margin" \
  '{preference:$pref, margin:$margin, rationale:"stub", concerns:[]}')"
jq -cn --arg body "$body" \
  '{result:$body, modelUsage:{"stub-model":{inputTokens:5,outputTokens:5,cacheReadInputTokens:0,cacheCreationInputTokens:0}}, duration_ms:5, is_error:false}'
STUBEOF
chmod +x "$JSTUB"
export JSTUB_COUNT_FILE="$WORK/stub-count"

jr() { bash "$JR" "$@" --dir "$LED" --repo "$REPO"; }

# ── Section 1 — records reconstructs a usable pair ──────────────────────────
OUT="$WORK/rec1"
if R="$(jr records --slug "$SLUG" --item-file "$ITEM" --out-dir "$OUT" 2>&1)"; then
  if [ -f "$OUT/a.json" ] && [ -f "$OUT/b.json" ]; then
    pass "1 records writes both records"
  else
    fail "1 records claimed success but did not write both records: $R"
  fi
  ib_a="$(jq -Sc '{issue,title,scope,acceptance}' "$OUT/a.json" 2>/dev/null)"
  ib_b="$(jq -Sc '{issue,title,scope,acceptance}' "$OUT/b.json" 2>/dev/null)"
  [ "$ib_a" = "$ib_b" ] \
    && pass "1 both records carry an IDENTICAL item block — judge.sh pairwise refuses a drifted pair" \
    || fail "1 item blocks differ, so judge.sh pairwise would refuse this pair: $ib_a vs $ib_b"
  da="$(jq -r '.score.diff.text_excerpt' "$OUT/a.json")"
  db="$(jq -r '.score.diff.text_excerpt' "$OUT/b.json")"
  { [ -n "$da" ] && [ -n "$db" ] && [ "$da" != "$db" ]; } \
    && pass "1 the two rebuilt diffs are non-empty and DISTINCT" \
    || fail "1 the rebuilt diffs are empty or identical — the judge would be comparing nothing"
  printf '%s' "$da" | grep -q "CHANGED BY BASELINE" \
    && pass "1 the baseline diff carries that arm's own content" \
    || fail "1 the baseline record does not carry the baseline arm's change"
  [ "$(jq -r '.candidate.model' "$OUT/a.json")" = "claude-sonnet-5" ] \
    && pass "1 the record carries the arm's model from its ledger row" \
    || fail "1 the record's candidate.model is wrong"
else
  fail "1 records failed outright: $R"
fi

# ── Section 2 — refusals ────────────────────────────────────────────────────
LED2="$WORK/ledger-fail"; mkdir -p "$LED2"
bash "$LEDGER" append --dir "$LED2" --row "$(mkrow baseline pass "$HEAD_A" "$BASE")" >/dev/null
bash "$LEDGER" append --dir "$LED2" --row "$(jq -c '.gate="fail"' <<<"$(mkrow candidate pass "$HEAD_B" "$BASE")")" >/dev/null
bash "$LEDGER" archive "$SLUG" baseline --dir "$LED2" --from "$WORK/a.patch" >/dev/null
bash "$LEDGER" archive "$SLUG" candidate --dir "$LED2" --from "$WORK/b.patch" >/dev/null
if R="$(bash "$JR" records --slug "$SLUG" --item-file "$ITEM" --out-dir "$WORK/rec2" --dir "$LED2" --repo "$REPO" 2>&1)"; then
  fail "2 an arm that gated 'fail' was accepted — that pair never had a judge verdict, so a repeat sweep over it measures nothing"
else
  printf '%s' "$R" | grep -q "gated" \
    && pass "2 an arm that gated 'fail' is refused, by name" \
    || fail "2 refused the failed-gate pair but not legibly: $R"
fi

LED3="$WORK/ledger-noarch"; mkdir -p "$LED3"
bash "$LEDGER" append --dir "$LED3" --row "$(mkrow baseline pass "$HEAD_A" "$BASE")" >/dev/null
bash "$LEDGER" append --dir "$LED3" --row "$(mkrow candidate pass "$HEAD_B" "$BASE")" >/dev/null
bash "$LEDGER" archive "$SLUG" baseline --dir "$LED3" --from "$WORK/a.patch" >/dev/null
if R="$(bash "$JR" records --slug "$SLUG" --item-file "$ITEM" --out-dir "$WORK/rec3" --dir "$LED3" --repo "$REPO" 2>&1)"; then
  fail "2 a MISSING archive was accepted — the pair is not recoverable and the sweep would be measuring a fabrication"
else
  printf '%s' "$R" | grep -q "no archived patch" \
    && pass "2 a missing archive is refused, naming the absent path" \
    || fail "2 refused the missing archive but not legibly: $R"
fi

LED4="$WORK/ledger-unkbase"; mkdir -p "$LED4"
bash "$LEDGER" append --dir "$LED4" --row "$(jq -c '.base_sha="unknown"' <<<"$(mkrow baseline pass "$HEAD_A" "$BASE")")" >/dev/null
bash "$LEDGER" append --dir "$LED4" --row "$(mkrow candidate pass "$HEAD_B" "$BASE")" >/dev/null
bash "$LEDGER" archive "$SLUG" baseline --dir "$LED4" --from "$WORK/a.patch" >/dev/null
bash "$LEDGER" archive "$SLUG" candidate --dir "$LED4" --from "$WORK/b.patch" >/dev/null
if R="$(bash "$JR" records --slug "$SLUG" --item-file "$ITEM" --out-dir "$WORK/rec4" --dir "$LED4" --repo "$REPO" 2>&1)"; then
  fail "2 an 'unknown' base_sha was accepted — the diff would be rebuilt against a guess"
else
  printf '%s' "$R" | grep -q "base_sha" \
    && pass "2 an unknown base_sha is refused and asks for --base" \
    || fail "2 refused the unknown base but not legibly: $R"
fi
if R="$(bash "$JR" records --slug "$SLUG" --item-file "$ITEM" --out-dir "$WORK/rec4b" --dir "$LED4" --repo "$REPO" --base "$BASE" 2>&1)"; then
  pass "2 ... and --base makes that same pair reconstructable"
else
  fail "2 --base did not rescue the unknown-base pair: $R"
fi

printf 'not json at all' >"$WORK/bad-item.json"
if bash "$JR" records --slug "$SLUG" --item-file "$WORK/bad-item.json" --out-dir "$WORK/rec5" --dir "$LED" --repo "$REPO" >/dev/null 2>&1; then
  fail "2 a malformed --item-file was accepted"
else
  pass "2 a malformed --item-file is refused"
fi

# ── Section 3 — sweep appends one corpus row per repeat ─────────────────────
rm -f "$JSTUB_COUNT_FILE"
if S="$(jr sweep --slug "$SLUG" --item-file "$ITEM" --n 4 --judge-runner "bash $JSTUB" 2>&1 | tail -1)"; then
  n_rep="$(printf '%s' "$S" | jq -r '.repeats // 0' 2>/dev/null)"
  n_cmp="$(printf '%s' "$S" | jq -r '.compared // 0' 2>/dev/null)"
  { [ "$n_rep" = "4" ] && [ "$n_cmp" = "4" ]; } \
    && pass "3 sweep ran 4 repeats and compared 4" \
    || fail "3 sweep summary wrong (repeats=$n_rep compared=$n_cmp): $S"
  rows="$(bash "$LEDGER" repeat-read --dir "$LED" --slug "$SLUG" | jq 'length')"
  [ "$rows" = "4" ] \
    && pass "3 the corpus holds one row per repeat" \
    || fail "3 expected 4 corpus rows, found $rows"
  seqs="$(bash "$LEDGER" repeat-read --dir "$LED" --slug "$SLUG" | jq -c '[.[].seq]')"
  [ "$seqs" = "[1,2,3,4]" ] \
    && pass "3 corpus rows carry a dense ledger-assigned seq" \
    || fail "3 corpus seqs are $seqs, not [1,2,3,4]"
  so="$(bash "$LEDGER" repeat-read --dir "$LED" --slug "$SLUG" | jq -c '[.[0].pair[].start_order]')"
  [ "$so" = "[1,2]" ] \
    && pass "3 each row records start_order for BOTH arms (the k-arm study's first hypothesis needs it, and a migration later would be worse)" \
    || fail "3 start_order not recorded per arm: $so"
else
  fail "3 sweep failed: $S"
fi

# ── Section 4 — the live-call trap ──────────────────────────────────────────
if R="$(jr sweep --slug "$SLUG" --item-file "$ITEM" --n 1 2>&1)"; then
  fail "4 sweep ran with NEITHER --judge-runner nor --live — there must be no implicit judge binary"
else
  printf '%s' "$R" | grep -q "CANNOT_EVALUATE" \
    && pass "4 sweep with neither runner flag is CANNOT_EVALUATE" \
    || fail "4 refused, but not with the named CANNOT_EVALUATE refusal: $R"
fi
if jr sweep --slug "$SLUG" --item-file "$ITEM" --n 1 --judge-runner "bash $JSTUB" --live >/dev/null 2>&1; then
  fail "4 --judge-runner and --live together were accepted"
else
  pass "4 --judge-runner and --live together are refused as mutually exclusive"
fi

# ── Section 5 — an unavailable repeat is recorded, not dropped ──────────────
LED5="$WORK/ledger-unavail"; mkdir -p "$LED5"
bash "$LEDGER" append --dir "$LED5" --row "$(mkrow baseline pass "$HEAD_A" "$BASE")" >/dev/null
bash "$LEDGER" append --dir "$LED5" --row "$(mkrow candidate pass "$HEAD_B" "$BASE")" >/dev/null
bash "$LEDGER" archive "$SLUG" baseline --dir "$LED5" --from "$WORK/a.patch" >/dev/null
bash "$LEDGER" archive "$SLUG" candidate --dir "$LED5" --from "$WORK/b.patch" >/dev/null
rm -f "$JSTUB_COUNT_FILE"
S="$(JSTUB_FAIL_AT=1 bash "$JR" sweep --slug "$SLUG" --item-file "$ITEM" --n 2 \
      --judge-runner "bash $JSTUB" --dir "$LED5" --repo "$REPO" 2>&1 | tail -1)"
u="$(printf '%s' "$S" | jq -r '.unavailable // -1' 2>/dev/null)"
rows5="$(bash "$LEDGER" repeat-read --dir "$LED5" --slug "$SLUG" | jq 'length')"
{ [ "${u:-0}" -ge 1 ] && [ "$rows5" = "2" ]; } \
  && pass "5 a judge that could not answer is RECORDED as unavailable, not silently dropped" \
  || fail "5 unavailable repeat mishandled (unavailable=$u rows=$rows5): $S"

# ── Section 6 — the calibration store is untouched (ADR 0041) ───────────────
{ [ ! -f "$LED/calibration.json" ] && [ ! -f "$LED/calibration-pairs.jsonl" ]; } \
  && pass "6 a sweep writes NO calibration state — a machine re-judge is not a blind human pair and must not move the calibration bar" \
  || fail "6 a sweep created calibration state: $(ls "$LED")"
[ -f "$LED/judge-repeat.jsonl" ] \
  && pass "6 the corpus lives in its own judge-repeat.jsonl store" \
  || fail "6 no judge-repeat.jsonl was written"

# ── Section 7 — report ──────────────────────────────────────────────────────
LED7="$WORK/ledger-report"; mkdir -p "$LED7"
bash "$LEDGER" append --dir "$LED7" --row "$(mkrow baseline pass "$HEAD_A" "$BASE")" >/dev/null
bash "$LEDGER" append --dir "$LED7" --row "$(mkrow candidate pass "$HEAD_B" "$BASE")" >/dev/null
bash "$LEDGER" archive "$SLUG" baseline --dir "$LED7" --from "$WORK/a.patch" >/dev/null
bash "$LEDGER" archive "$SLUG" candidate --dir "$LED7" --from "$WORK/b.patch" >/dev/null
rm -f "$JSTUB_COUNT_FILE"
# Positions alternate per JUDGE CALL, and pairwise makes two calls (AB then BA)
# per repeat, so this drives a mix of agreeing and disagreeing repeats.
JSTUB_POSITIONS="1,1,1,2,2,2,1,1" bash "$JR" sweep --slug "$SLUG" --item-file "$ITEM" --n 4 \
  --judge-runner "bash $JSTUB" --dir "$LED7" --repo "$REPO" >/dev/null 2>&1
if RPT="$(bash "$JR" report --slug "$SLUG" --dir "$LED7" --repo "$REPO" 2>&1 | tail -1)"; then
  tot="$(printf '%s' "$RPT" | jq -r '.n // 0')"
  dec="$(printf '%s' "$RPT" | jq -r '.decisive // -1')"
  a="$(printf '%s' "$RPT" | jq -r '.prefer_a // 0')"
  b="$(printf '%s' "$RPT" | jq -r '.prefer_b // 0')"
  t="$(printf '%s' "$RPT" | jq -r '.tie // 0')"
  [ "$tot" = "4" ] \
    && pass "7 report reads the whole corpus for the slug" \
    || fail "7 report saw $tot rows, expected 4: $RPT"
  [ "$dec" = "$((a + b))" ] \
    && pass "7 'decisive' excludes ties — a resolved tie is a real verdict but carries no sign" \
    || fail "7 decisive=$dec does not equal prefer_a+prefer_b=$((a + b)) (tie=$t)"
  printf '%s' "$RPT" | jq -e '.sign_test' >/dev/null 2>&1 \
    && pass "7 the fair-coin sign test comes from stats.sh, not hand-rolled here" \
    || fail "7 no sign_test in the report: $RPT"
  printf '%s' "$RPT" | jq -e '.scope_note | test("start_order is constant")' >/dev/null 2>&1 \
    && pass "7 the report states plainly what this measurement CANNOT answer" \
    || fail "7 the report does not disclose its own scope limit"
else
  fail "7 report failed: $RPT"
fi
if bash "$JR" report --slug no-such-slug --dir "$LED7" --repo "$REPO" >/dev/null 2>&1; then
  fail "7 report invented a summary for a slug with no corpus rows"
else
  pass "7 report refuses a slug with no rows rather than printing an empty verdict"
fi

# ── Section 8 — DISCRIMINATION CONTROL ──────────────────────────────────────
# Every assertion above is worthless if the reconstructor would accept anything.
# Corrupt an archive so `git am` cannot apply it and require a refusal.
LED8="$WORK/ledger-corrupt"; mkdir -p "$LED8"
bash "$LEDGER" append --dir "$LED8" --row "$(mkrow baseline pass "$HEAD_A" "$BASE")" >/dev/null
bash "$LEDGER" append --dir "$LED8" --row "$(mkrow candidate pass "$HEAD_B" "$BASE")" >/dev/null
printf 'From 0000\nSubject: [PATCH] junk\n\ndiff --git a/doc.md b/doc.md\n@@ MALFORMED HUNK @@\n' >"$WORK/corrupt.patch"
bash "$LEDGER" archive "$SLUG" baseline --dir "$LED8" --from "$WORK/corrupt.patch" >/dev/null
bash "$LEDGER" archive "$SLUG" candidate --dir "$LED8" --from "$WORK/b.patch" >/dev/null
if R="$(bash "$JR" records --slug "$SLUG" --item-file "$ITEM" --out-dir "$WORK/rec8" --dir "$LED8" --repo "$REPO" 2>&1)"; then
  fail "8 CONTROL: a CORRUPT archive was accepted — the reconstructor would accept anything, so every assertion above proves nothing"
else
  pass "8 CONTROL: a corrupt archive is refused, so the clean reconstructions above are real"
fi

# ── the canary ──────────────────────────────────────────────────────────────
[ ! -f "$JR_CANARY_TRIPPED" ] \
  && pass "canary: the suite issued NO live model call" \
  || fail "canary: a live claude was invoked — this suite is not hermetic"

echo ""
if [ "$FAILED" -eq 0 ]; then
  echo "All test_judge_repeat.sh cases passed."
else
  echo "test_judge_repeat.sh: $FAILED case(s) failed." >&2
  exit 1
fi
