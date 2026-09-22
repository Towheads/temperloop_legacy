#!/usr/bin/env bash
#
# test_replay_batch.sh — fixture suite for the replay BATCH DRIVER
# (temperloop#1401, epic #1225 "model comparison harness"): batch.sh, the
# operator-invoked thing that turns a corpus file into the two arm files
# workflows/scripts/report-producers/model-comparison reads.
#
# ── HERMETIC BY CONSTRUCTION, NOT BY PROMISE ───────────────────────────────
# This is the file that would spend a whole BATCH of real money if it ever
# reached a model by accident — one mistake here multiplies by the corpus
# size. Two independent mechanisms, both asserted:
#
#   1. THE SEAM. Every batch below drives BOTH arms (and the judge) through
#      RECORDED runners on disk. `--live` is never passed by any test in this
#      file, and batch.sh refuses — before it prepares a worktree and before
#      it even consults the spend gate — when an arm has no seam.
#   2. THE CANARY. `$WORK/bin` is prepended to PATH for the WHOLE suite and
#      contains a `claude` that records its own invocation to `$WORK/CANARY`.
#      Section L asserts that file never came into existence, and check L2
#      proves the canary is genuinely capable of firing. Section H MUTATES
#      the driver's candidate-arm seam selection (in a throwaway mirror of
#      the module) to force `--live`, and proves the canary DOES fire — so
#      "no live call" is a MEASUREMENT of the whole run rather than a claim
#      about the tests someone remembered to check.
#
# No network, no `gh`, no model call, no writes outside $TMPDIR.
#
# ── WHAT EACH SECTION PINS ─────────────────────────────────────────────────
#   A  THE SEAM — every un-seamed arm refuses BEFORE anything is spent
#   B  THE GATE RUNS FIRST — a stopped pre-flight, and an unconfirmed batch,
#      execute NOTHING (+ MUTATION PROOF that neutering the stop check does
#      execute, i.e. the gate is load-bearing)
#   C  THE TWO-ARM UNIT CONTRACT + THE BATCH CAP (temperloop#1379) — the cap
#      binds CORPUS RECORDS, every selected record is replayed in BOTH arms,
#      and the driver's authorized figures are the GATE's own (+ two
#      MUTATION PROOFS: a one-arm loop, and a cap taken from anywhere but
#      the gate)
#   D  ONE RECORD'S FAILURE DOES NOT ABORT THE BATCH, and the completion rate
#      falls out of the driver's own output (+ MUTATION PROOF that counting a
#      failed leg as completed reports 1.0 — the temperloop#1365 "could not
#      evaluate rendered as evaluated, and fine" class)
#   E  RESUMABILITY — a re-invocation re-spends nothing (+ MUTATION PROOF
#      that neutering the resume check DOES re-spend), and a state dir bound
#      to a different batch is refused
#   F  ISOLATION — every prepared worktree is torn down on the success AND
#      the failure path, and verify-clean-parent passes (+ MUTATION PROOF)
#   G  THE REPORT PRODUCER CONSUMES THE OUTPUT UNCHANGED — the real producer
#      is run on the driver's own fixture output
#   H  JUDGING — wired, resumable, and a skip is NAMED rather than silent
#      (+ the live-arm MUTATION PROOF)
#   I  INTERRUPT SEMANTICS (temperloop#1527) — a SIGTERM mid-leg STOPS the
#      batch before the next leg begins, tears the in-flight worktree down,
#      and dies with the signal-derived status (+ MUTATION PROOF that the
#      pre-fix single `trap … EXIT INT TERM` cleans up and CONTINUES)
#   J  ARM-FILE RECONCILIATION (temperloop#1556) — the arm file the driver
#      WROTE is checked against the leg records it COUNTED, so a healthy
#      completion rate derived from intact legs can never sit beside an arm
#      file that no longer holds them (+ MUTATION PROOF that restoring the
#      pre-fix judge substitution corrupts the arm and the driver says so)
#   K  THE CIRCUIT BREAKER (temperloop#1554) — a systemically unavailable
#      spawn path STOPS the batch instead of being hammered to the end of the
#      corpus; the stop is distinguishable from a completed-but-degraded run;
#      the skipped legs are NOT ATTEMPTED rather than integration errors and a
#      resume re-drives them; and an isolated failure below the threshold, or
#      a run of errors whose STAGE keeps changing, still runs to completion
#      (+ MUTATION PROOF that disarming the breaker runs the whole corpus out)
#   M  COUNTERBALANCED ARM ORDER (temperloop#1571) — arm is no longer
#      confounded with execution position: the baseline arm runs first on
#      exactly half a 6-record corpus, every leg records its position, the
#      assignment is reproducible from the recorded rule+seed alone, and no
#      unaudited fixed-order arm loop can be reintroduced (+ MUTATION PROOF
#      that a driver reverted to fixed order FAILS the same predicate)
#   N  RECORD-LEVEL CONCURRENCY (temperloop#1682) — --concurrency N runs N
#      RECORDS at once and changes nothing about what is measured: the same
#      arm order and the same records in both arms at N=1 and N=4, a record's
#      two legs never overlapping in time, the breaker still stopping the
#      batch (and SAYING that it stops dispatch rather than execution), the
#      width clamped to its cap and an unparseable one resolving to 1, and a
#      resume across widths re-spending nothing (+ MUTATION PROOF that a
#      driver overlapping a record's two legs FAILS the same predicate)
#   L  the suite-wide no-live-call canary verdict
#
# Usage: bash workflows/scripts/model-comparison/tests/test_replay_batch.sh [--group 1..8]
#
# shellcheck disable=SC2016

set -uo pipefail

# ── SHARDING: `--group N` (temperloop#2163) ────────────────────────────────
# The sections above fall into eight DEPENDENCY-CLOSED groups. `--group N` runs
# exactly one of them; with no flag every group runs, in file order, with the
# same assertions, exactly as before. Nothing is skipped, moved to nightly or
# loosened — the partition is only about WHERE the wall time is paid.
#
# WHY: the quality-gate pool's makespan is max(total/jobs, longest single
# gate), so a 250-second suite is a straggler no amount of added pool
# parallelism can shorten — it sets the floor on its own. The work here is
# irreducibly ~190 replay legs at ~1.3s each (measured: 0.43s worktree
# prepare + 0.25s teardown + ~0.6s execute-and-score per leg, against a
# fixture whose runners are already recorded stubs and whose gate is a
# two-line script). There is no wait to delete, so the only honest way to
# shorten the longest gate is to run those legs in more than one process.
#
# THE GROUPS, and why each is closed:
#   1  A B          the refusal paths; no state flows out of them
#   2  C D E F      ONE chain: C1's happy-path batch populates $A_OUT/$A_STATE
#                   and E resumes it; D's degraded batch populates $FAIL_OUT
#                   and F asserts teardown on BOTH that failure path and C's
#                   success path
#   3  G H          the report producer and the judge pass, both over the
#                   section-C run — rebuilt on a shard by drive_a_happy_path
#   4  I J          interrupt semantics, arm-file reconciliation
#   5  K            the circuit breaker (8-leg corpora, four scenarios)
#   6  S M          projected-vs-observed spend, counterbalanced arm order
#   7  N            record-level concurrency (carries its own N=1 reference run)
#   8  R W          --retry-stage recovery, atomic leg-state writes
#
# Section L — the no-live-call canary verdict — is deliberately OUTSIDE the
# partition and runs at the END of every shard, so "no live call happened" is
# asserted for whatever this process actually ran rather than only for a
# whole-suite run. Every group therefore carries its own hermeticity proof.
#
# The few fixtures that straddle a boundary ($A_OUT/$A_STATE and their drive,
# the circuit breaker's corpus and stub) are defined with the rest of the
# fixture setup below, never inside a group, so every group starts from the
# same base.
GROUP="all"
while [ $# -gt 0 ]; do
  case "$1" in
    --group) GROUP="${2:?--group needs a value}"; shift 2 ;;
    *) echo "test_replay_batch.sh: unknown arg: $1 (want --group 1..8)" >&2; exit 2 ;;
  esac
done
case "$GROUP" in
  all|1|2|3|4|5|6|7|8) ;;
  *) echo "test_replay_batch.sh: --group must be 1..8 (got: $GROUP)" >&2; exit 2 ;;
esac

# run_group <n> -> rc 0 iff group <n> should run in this process.
run_group() { [ "$GROUP" = "all" ] || [ "$GROUP" = "$1" ]; }

# Physical derivation (`cd -P`) — dir-symlink-composition-safe (temperloop#1557).
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MC_DIR="$(cd -P "$HERE/.." && pwd)"
SCRIPTS_DIR="$(cd -P "$MC_DIR/.." && pwd)"
SUT="$MC_DIR/batch.sh"
PRODUCER="$SCRIPTS_DIR/report-producers/model-comparison"

pass=0
total=0
ok() { pass=$((pass + 1)); echo "PASS: $1"; }
count() { total=$((total + 1)); }
fail() { echo "FAIL: $1" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-replay-batch-XXXXXX")"
WORK="$(cd -P "$WORK" && pwd)"
trap 'chmod -R u+rwX "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

# ═══════════════════════════════════════════════════════════════════════════
# THE CANARY — a `claude` on PATH that no test may ever reach.
# ═══════════════════════════════════════════════════════════════════════════
CANARY="$WORK/CANARY"
mkdir -p "$WORK/bin"
cat >"$WORK/bin/claude" <<EOF
#!/usr/bin/env bash
# Suite canary: if anything under test invokes a bare 'claude', this records
# it. Section L fails the whole suite if this file exists at the end.
printf 'INVOKED %s\n' "\$*" >>"$CANARY"
exit 0
EOF
chmod +x "$WORK/bin/claude"
PATH="$WORK/bin:$PATH"
export PATH

# mutate_file <file> <old-literal> <new-literal> — exact, literal,
# single-occurrence replacement (the same helper, and the same rationale, as
# test_replay_score.sh's). Dies loudly if the old text is missing or not
# unique, so a mutation proof can never silently become a no-op that passes.
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

# mk_mirror <dest> — a throwaway, symlink-backed mirror of workflows/scripts,
# so a mutation proof edits ONE real copy of a script and never writes into
# the checkout. Relative resolution ($HERE/../build, $HERE/replay.sh) still
# works because the DIRECTORIES are real and only the leaves are links.
mk_mirror() {
  local d="$1" f b
  mkdir -p "$d/workflows/scripts/model-comparison"
  for f in "$SCRIPTS_DIR"/*; do
    b="$(basename "$f")"
    [ "$b" = "model-comparison" ] && continue
    ln -s "$f" "$d/workflows/scripts/$b"
  done
  for f in "$MC_DIR"/*; do
    ln -s "$f" "$d/workflows/scripts/model-comparison/$(basename "$f")"
  done
}

# unlink_and_copy <mirror-path> — swap one mirrored symlink for a real,
# editable copy of its target.
unlink_and_copy() {
  local p="$1" target real
  target="$(cd -P "$(dirname "$p")" && pwd)/$(basename "$p")"
  real="$(readlink "$target")"
  rm -f "$target"
  cp "$real" "$target"
  chmod u+w "$target"
}

# ═══════════════════════════════════════════════════════════════════════════
# THE FIXTURE REPO — an origin remote (worktree.sh create resolves
# origin/HEAD), a base commit, a merged "truth" commit, and an in-tree gate
# script so score.sh runs the WORKTREE'S OWN gate (trap C, "never mix trees").
# ═══════════════════════════════════════════════════════════════════════════
ORIGIN="$WORK/origin.git"
git init -q --bare "$ORIGIN"
git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main

REPO="$WORK/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" symbolic-ref HEAD refs/heads/main
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name  T
git -C "$REPO" config commit.gpgsign false

mkdir -p "$REPO/workflows/scripts/drain" "$REPO/scripts" "$REPO/claude/workflows" "$REPO/.temperloop"
cat >"$REPO/workflows/scripts/drain/scan_stub.py" <<'PY'
def _is_command_expansion_turn(turn_text):
    return False
PY
printf '# changelog\n' >"$REPO/CHANGELOG.md"
printf '// build-level at base\n' >"$REPO/claude/workflows/build-level.mjs"
# The driver's default output directory is MODEL_COMPARISON_REPORT_RECORDS_DIR
# under the repo root, and the real kernel checkout gitignores it. The fixture
# repo carries the same ignore, because `replay.sh verify-clean-parent` is a
# REAL assertion here: an un-ignored output directory would (correctly) leave
# the parent dirty and the isolation backstop would (correctly) say so.
printf 'model-comparison/\n' >"$REPO/.temperloop/.gitignore"
cat >"$REPO/scripts/quality-gates.sh" <<'GATE'
#!/usr/bin/env bash
# fixture gate: red iff a GATE_FAIL marker exists in the tree it runs against
if [ -f "GATE_FAIL" ]; then
  echo "fixture gate: FAIL"
  exit 1
fi
echo "fixture gate: OK"
exit 0
GATE
chmod +x "$REPO/scripts/quality-gates.sh"
git -C "$REPO" add -A
git -C "$REPO" commit -qm "base"
BASE="$(git -C "$REPO" rev-parse HEAD)"

git -C "$REPO" checkout -qb truth
cat >"$REPO/workflows/scripts/drain/scan_stub.py" <<'PY'
import re

_CMD_INVOCATION_PATTERN = re.compile(r'<command-name>', re.IGNORECASE)


def _is_command_expansion_turn(turn_text):
    return bool(_CMD_INVOCATION_PATTERN.search(turn_text))
PY
mkdir -p "$REPO/workflows/scripts/drain/tests"
printf '#!/usr/bin/env bash\necho truth-test\n' >"$REPO/workflows/scripts/drain/tests/test_scan_stub.sh"
printf '# changelog\n\n- entry\n' >"$REPO/CHANGELOG.md"
git -C "$REPO" add -A
git -C "$REPO" commit -qm "truth"
TRUTH="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" checkout -q main
git -C "$REPO" remote add origin "$ORIGIN"
git -C "$REPO" push -q origin main
git -C "$REPO" remote set-head origin -a >/dev/null

TEMPLATE_SHA="$(git -C "$REPO" rev-parse "$BASE:claude/workflows/build-level.mjs")"
TRUTH_PY="$WORK/truth-scan_stub.py"
git -C "$REPO" show "$TRUTH:workflows/scripts/drain/scan_stub.py" >"$TRUTH_PY"
BOGUS_BASE="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"

# ── corpus records ─────────────────────────────────────────────────────────
# mk_corpus_line <pr> <status> <base-sha>
mk_corpus_line() {
  jq -cn --argjson pr "$1" --arg st "$2" --arg base "$3" --arg head "$TRUTH" --arg tpl "$TEMPLATE_SHA" \
    '{schema_version:"replay-record-v1", pr:$pr, issue:("#" + ($pr|tostring)),
      merge_commit:null, base:$base, head:$head,
      title:"Exclude the expanded command-spec turn", scope:"drain scan_stub.py",
      acceptance:["A named path is fixed."], notes:"", status:$st, reject_reason:"", flags:[],
      buckets:{N:["workflows/scripts/drain/scan_stub.py"],
               T:["workflows/scripts/drain/tests/test_scan_stub.sh"],
               X:["CHANGELOG.md"], R:[]},
      template_sha:$tpl, file_count:2,
      worktree:{path:null,branch:null,prepared_at:null},
      candidate:{provider:null,model:null,diff_ref:null},
      score:{verdict:null,acceptance_results:null,gate_result:null}}'
}

# CORPUS_A — the happy path: 2 eligible records, 1 rejected (never replayed).
CORPUS_A="$WORK/corpus-a.jsonl"
{ mk_corpus_line 101 eligible "$BASE"
  mk_corpus_line 102 rejected "$BASE"
  mk_corpus_line 103 flagged-eligible "$BASE"; } >"$CORPUS_A"

# CORPUS_CAP — 3 eligible records, exercised under a batch cap of 2.
CORPUS_CAP="$WORK/corpus-cap.jsonl"
{ mk_corpus_line 201 eligible "$BASE"
  mk_corpus_line 202 eligible "$BASE"
  mk_corpus_line 203 eligible "$BASE"; } >"$CORPUS_CAP"

# CORPUS_FAIL — 3 eligible records, the MIDDLE one carrying an unreachable
# base so its worktree can never be prepared. Both of its legs fail; the
# batch must carry on and still produce the other two records in both arms.
CORPUS_FAIL="$WORK/corpus-fail.jsonl"
{ mk_corpus_line 301 eligible "$BASE"
  mk_corpus_line 302 eligible "$BOGUS_BASE"
  mk_corpus_line 303 eligible "$BASE"; } >"$CORPUS_FAIL"

# ── the RECORDED candidate runners (the test seam) ─────────────────────────
# Invoked as `<cmd> <prompt-file> <worktree>`. They reach no network: each
# replays a canned envelope and makes a fixed set of edits in the worktree.
# Each also APPENDS to a call log, which is how section E measures that a
# resumed run re-spent nothing.
mk_stub() {  # mk_stub <path> <model-key> <log>
  local p="$1" modelkey="$2" log="$3"
  cat >"$p" <<STUBEOF
#!/usr/bin/env bash
set -u
printf '%s %s\n' "$modelkey" "\$1" >>"$log"
wt="\$2"
cp "$TRUTH_PY" "\$wt/workflows/scripts/drain/scan_stub.py"
mkdir -p "\$wt/workflows/scripts/drain/tests"
printf '#!/usr/bin/env bash\necho candidate-test\n' >"\$wt/workflows/scripts/drain/tests/test_scan_stub.sh"
jq -cn --arg m "$modelkey" '{type:"result", subtype:"success", is_error:false, duration_ms:4242,
  modelUsage:{(\$m):{inputTokens:1200, outputTokens:340,
                     cacheReadInputTokens:9000, cacheCreationInputTokens:120,
                     provider:"firstParty"}}}'
STUBEOF
  chmod +x "$p"
}
CAND_LOG="$WORK/candidate-calls.log"; : >"$CAND_LOG"
BASE_STUB="$WORK/stub-baseline.sh"
CAND_STUB="$WORK/stub-candidate.sh"
mk_stub "$BASE_STUB" "recorded-baseline-model" "$CAND_LOG"
mk_stub "$CAND_STUB" "recorded-candidate-model" "$CAND_LOG"

# ── the RECORDED judge runner ──────────────────────────────────────────────
# Invoked as `<cmd> <prompt-file>` (judge.sh's own contract — no worktree).
JUDGE_LOG="$WORK/judge-calls.log"; : >"$JUDGE_LOG"
JUDGE_STUB="$WORK/stub-judge.sh"
cat >"$JUDGE_STUB" <<JEOF
#!/usr/bin/env bash
set -u
printf 'judge %s\n' "\$1" >>"$JUDGE_LOG"
resp='{"quality_score":72,"dimensions":{"correctness":70,"scope":74},"rationale":"recorded","concerns":[]}'
jq -cn --arg r "\$resp" '{type:"result", subtype:"success", is_error:false, duration_ms:77,
  result:\$r,
  modelUsage:{"recorded-judge-model":{inputTokens:10, outputTokens:5,
                                      cacheReadInputTokens:0, cacheCreationInputTokens:0}}}'
JEOF
chmod +x "$JUDGE_STUB"

# ── env every batch run gets: the quota gate deterministically "unavailable"
#    (fail open — it can never be the reason anything below stops), the
#    attribution lake and the disclosure log pointed INTO $WORK, never at the
#    checkout. ────────────────────────────────────────────────────────────
NOCACHE="$WORK/no-such-quota-cache.json"
LAKE="$WORK/lake"; mkdir -p "$LAKE"
DLOG="$WORK/disclosure-log.jsonl"
ALLOW="$WORK/allow.txt"; printf 'anthropic\nopenai\n' >"$ALLOW"
NOLOCAL="$WORK/no-such-local-override.txt"

# drive <sut-or-empty> <env-assignments-as-one-string> <args...> — runs the
# driver, captures stdout in $OUT and the exit code in $RC.
OUT=""; RC=0
drive() {
  local sut="$1"; shift
  [ -n "$sut" ] || sut="$SUT"
  RC=0
  OUT="$(env BUILD_QUOTA_CACHE="$NOCACHE" \
             MODEL_USAGE_RAW_DIR="$LAKE" \
             PROVIDER_ALLOWLIST_TEST_SEAM=1 \
             PROVIDER_ALLOWLIST_COMMITTED_FILE="$ALLOW" \
             PROVIDER_ALLOWLIST_LOCAL_FILE="$NOLOCAL" \
             PROVIDER_DISCLOSURE_LOG_FILE="$DLOG" \
             "$@" bash "$sut" run "${DRIVE_ARGS[@]}" 2>"$WORK/last-stderr.txt")" || RC=$?
}

lines() {  # line count of a file that may legitimately be empty or absent
  [ -f "$1" ] || { printf '0'; return 0; }
  wc -l <"$1" | tr -d ' '
}

wt_count() {  # how many mc-replay-* worktrees the fixture repo currently has
  local n=0 d
  for d in "${REPO}.wt"/mc-replay-*; do
    [ -e "$d" ] && n=$((n + 1))
  done
  printf '%s' "$n"
}

# ── FIXTURES THAT STRADDLE A GROUP BOUNDARY (temperloop#2163) ─────────────
# Defined here, with the rest of the fixture setup, rather than inside the
# first group that happens to use them — so a `--group N` shard starts from
# the same base as a whole-suite run. Nothing here DRIVES anything: these are
# paths and stubs only, and each group still produces its own state.

# Section A names these; section C populates them and E/F/G/H read them back.
A_OUT="$WORK/out-a"; A_STATE="$WORK/state-a"

# drive_a_happy_path — the judged, two-arm CORPUS_A batch. Section C1 asserts
# on it; sections E/F/G/H then resume, tear down, report on and judge that same
# run. It is a NAMED helper rather than inline in C1 so the G/H shard can
# rebuild the state it reads without re-running C1's assertions.
drive_a_happy_path() {
  : >"$CAND_LOG"
  DRIVE_ARGS=(--corpus-file "$CORPUS_A" --repo-root "$REPO" --out-dir "$A_OUT" --state-dir "$A_STATE"
              --baseline-runner "bash $BASE_STUB" --candidate-runner "bash $CAND_STUB"
              --judge-runner "bash $JUDGE_STUB" --confirm)
  drive ""
}

# CORPUS_CB — 4 eligible records (8 legs) driven at a threshold of 2, so the
# breaker trips on the second leg and 6 legs across 3 whole records are left
# un-attempted. The threshold is passed as the SETTING, never a flag: that is
# what proves it is config-named rather than a literal in the driver.
CORPUS_CB="$WORK/corpus-cb.jsonl"
{ mk_corpus_line 401 eligible "$BASE"
  mk_corpus_line 402 eligible "$BASE"
  mk_corpus_line 403 eligible "$BASE"
  mk_corpus_line 404 eligible "$BASE"; } >"$CORPUS_CB"

# The systemically-unavailable runner: every call fails the same way, which
# replay.sh execute turns into a `candidate-spawn` integration-error record.
CB_LOG="$WORK/cb-calls.log"; : >"$CB_LOG"
CB_STUB="$WORK/stub-cb-unavailable.sh"
cat >"$CB_STUB" <<STUBEOF
#!/usr/bin/env bash
set -u
printf 'cb %s\n' "\$1" >>"$CB_LOG"
echo "API error 429: rate limit exceeded" >&2
exit 1
STUBEOF
chmod +x "$CB_STUB"

if run_group 1; then  # sections A, B
# ═══════════════════════════════════════════════════════════════════════════
# SECTION A — THE SEAM. Every un-seamed arm refuses, before ANY spend.
# ═══════════════════════════════════════════════════════════════════════════
# A1 — no runner at all, no --live.
count
DRIVE_ARGS=(--corpus-file "$CORPUS_A" --repo-root "$REPO" --out-dir "$A_OUT" --state-dir "$A_STATE" --confirm)
drive ""
[ "$RC" -ne 0 ] || fail "A1: a batch with NO candidate runner and NO --live must refuse, got exit 0: $OUT"
[ "$(jq -r '.outcome' <<<"$OUT")" = "CANNOT_EVALUATE" ] || fail "A1: expected CANNOT_EVALUATE, got: $OUT"
grep -q 'NO implicit fallback' <<<"$OUT" || fail "A1: the refusal must name the absent seam: $OUT"
[ ! -e "$A_OUT/baseline.jsonl" ] || fail "A1: a refused batch wrote an arm file"
[ "$(wt_count)" = "0" ] || fail "A1: a refused batch prepared a worktree"
[ ! -e "$CANARY" ] || fail "A1: the refusal reached a 'claude' binary: $(cat "$CANARY")"
ok "A1 no candidate runner and no --live: CANNOT EVALUATE, non-zero, nothing prepared, nothing written"

# A2 — only ONE arm seamed. A batch is two arms; half a seam is no seam.
count
DRIVE_ARGS=(--corpus-file "$CORPUS_A" --repo-root "$REPO" --out-dir "$A_OUT" --state-dir "$A_STATE"
            --baseline-runner "bash $BASE_STUB" --confirm)
drive ""
[ "$RC" -ne 0 ] || fail "A2: a batch with only the baseline arm seamed must refuse: $OUT"
[ "$(jq -r '.outcome' <<<"$OUT")" = "CANNOT_EVALUATE" ] || fail "A2: expected CANNOT_EVALUATE, got: $OUT"
ok "A2 only one arm seamed: CANNOT EVALUATE (a two-arm run needs two seams)"

# A3 — --live AND a recorded runner: mutually exclusive, refused.
count
DRIVE_ARGS=(--corpus-file "$CORPUS_A" --repo-root "$REPO" --out-dir "$A_OUT" --state-dir "$A_STATE"
            --baseline-runner "bash $BASE_STUB" --candidate-runner "bash $CAND_STUB" --live --confirm)
drive ""
[ "$RC" -ne 0 ] || fail "A3: --live plus a recorded runner must refuse: $OUT"
grep -q 'mutually exclusive' <<<"$OUT" || fail "A3: expected a mutual-exclusion refusal, got: $OUT"
[ ! -e "$CANARY" ] || fail "A3: the refusal reached a 'claude' binary: $(cat "$CANARY")"
ok "A3 --live plus a recorded runner: mutually exclusive, refused before any spend"

# A4 — an unreadable corpus file is CANNOT EVALUATE, never an empty batch
#      reported as a completed one.
count
DRIVE_ARGS=(--corpus-file "$WORK/no-such-corpus.jsonl" --repo-root "$REPO" --out-dir "$A_OUT"
            --state-dir "$A_STATE" --baseline-runner "bash $BASE_STUB"
            --candidate-runner "bash $CAND_STUB" --confirm)
drive ""
[ "$RC" -eq 1 ] || fail "A4: an absent corpus file should be CANNOT_EVALUATE exit 1, got $RC: $OUT"
[ "$(jq -r '.outcome' <<<"$OUT")" = "CANNOT_EVALUATE" ] || fail "A4: expected CANNOT_EVALUATE, got: $OUT"
ok "A4 absent corpus file: CANNOT EVALUATE, never a vacuous 'complete' batch"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION B — THE GATE RUNS FIRST, and it is load-bearing.
# ═══════════════════════════════════════════════════════════════════════════

# B1 — --preflight-only prints the gate's own verdict and executes nothing.
count
DRIVE_ARGS=(--corpus-file "$CORPUS_A" --repo-root "$REPO" --out-dir "$A_OUT" --state-dir "$A_STATE"
            --baseline-runner "bash $BASE_STUB" --candidate-runner "bash $CAND_STUB"
            --confirm --preflight-only)
drive ""
[ "$RC" -eq 0 ] || fail "B1: --preflight-only should exit 0 on an un-stopped gate, got $RC: $OUT"
[ "$(jq -r '.outcome' <<<"$OUT")" = "PREFLIGHT" ] || fail "B1: expected the gate's own PREFLIGHT object, got: $OUT"
[ "$(jq -r '.planned_records_n' <<<"$OUT")" = "2" ] || fail "B1: expected 2 planned corpus records, got: $OUT"
[ "$(wc -l <"$CAND_LOG" | tr -d ' ')" = "0" ] || fail "B1: --preflight-only invoked a candidate runner"
ok "B1 --preflight-only: the gate's verdict, and not one replay executed"

# B2 — NO --confirm: STOPPED, spent:false, nothing prepared, nothing written.
count
DRIVE_ARGS=(--corpus-file "$CORPUS_A" --repo-root "$REPO" --out-dir "$A_OUT" --state-dir "$A_STATE"
            --baseline-runner "bash $BASE_STUB" --candidate-runner "bash $CAND_STUB")
drive ""
[ "$RC" -eq 3 ] || fail "B2: an unconfirmed batch should STOP with exit 3, got $RC: $OUT"
[ "$(jq -r '.outcome' <<<"$OUT")" = "STOPPED" ] || fail "B2: expected STOPPED, got: $OUT"
[ "$(jq -r '.stop_reason' <<<"$OUT")" = "confirmation_required" ] || fail "B2: expected stop_reason confirmation_required, got: $OUT"
[ "$(jq -r '.spent' <<<"$OUT")" = "false" ] || fail "B2: an unconfirmed batch must report spent:false: $OUT"
[ "$(wc -l <"$CAND_LOG" | tr -d ' ')" = "0" ] || fail "B2: an unconfirmed batch invoked a candidate runner"
[ ! -e "$A_OUT/baseline.jsonl" ] || fail "B2: an unconfirmed batch wrote an arm file"
ok "B2 no --confirm: STOPPED, spent:false, no runner invoked, no arm file"

# B3 — the gate itself says stop (a ceiling this batch cannot fit under).
count
DRIVE_ARGS=(--corpus-file "$CORPUS_A" --repo-root "$REPO" --out-dir "$A_OUT" --state-dir "$A_STATE"
            --baseline-runner "bash $BASE_STUB" --candidate-runner "bash $CAND_STUB" --confirm)
drive "" REPLAY_PREFLIGHT_CEILING_TOKENS=1
[ "$RC" -eq 3 ] || fail "B3: a ceiling-exceeded gate should STOP with exit 3, got $RC: $OUT"
[ "$(jq -r '.stop_reason' <<<"$OUT")" = "ceiling_exceeded" ] || fail "B3: expected stop_reason ceiling_exceeded, got: $OUT"
[ "$(wc -l <"$CAND_LOG" | tr -d ' ')" = "0" ] || fail "B3: a STOPPED batch invoked a candidate runner — it started spending on an un-gated batch"
[ "$(wt_count)" = "0" ] || fail "B3: a STOPPED batch prepared a worktree"
ok "B3 gate stop (ceiling exceeded): nothing prepared, nothing spent"

# B4 — MUTATION PROOF. The gate is what stopped B3, not luck: neuter the stop
#      check in a mirrored copy and the very same input DOES execute replays.
count
MUT_B="$WORK/mut-gate"; mk_mirror "$MUT_B"
MUT_B_SUT="$MUT_B/workflows/scripts/model-comparison/batch.sh"
unlink_and_copy "$MUT_B_SUT"
mutate_file "$MUT_B_SUT" \
  '  if [ "$(jq -r '"'"'.stop'"'"' <<<"$pf_json")" = "true" ]; then' \
  '  if false; then'
MUT_B_OUT="$WORK/out-mut-b"; MUT_B_STATE="$WORK/state-mut-b"
: >"$CAND_LOG"
DRIVE_ARGS=(--corpus-file "$CORPUS_A" --repo-root "$REPO" --out-dir "$MUT_B_OUT" --state-dir "$MUT_B_STATE"
            --baseline-runner "bash $BASE_STUB" --candidate-runner "bash $CAND_STUB" --confirm)
drive "$MUT_B_SUT" REPLAY_PREFLIGHT_CEILING_TOKENS=1
mut_b_calls="$(wc -l <"$CAND_LOG" | tr -d ' ')"
[ "$mut_b_calls" -gt 0 ] || fail "B4: the mutation proof did not fire — with the stop check neutered the batch should have executed replays, so B3 proves nothing. stderr: $(head -c 400 "$WORK/last-stderr.txt")"
: >"$CAND_LOG"
ok "B4 MUTATION PROOF: neutering the gate's stop check DOES execute replays ($mut_b_calls candidate calls) — B3's refusal is load-bearing"

fi

if run_group 2; then  # sections C, D, E, F
# ═══════════════════════════════════════════════════════════════════════════
# SECTION C — THE TWO-ARM UNIT CONTRACT (temperloop#1379) + THE BATCH CAP.
# ═══════════════════════════════════════════════════════════════════════════

# C1 — the happy path over CORPUS_A: 2 eligible records, BOTH arms.
count
drive_a_happy_path
[ "$RC" -eq 0 ] || fail "C1: the happy-path batch should exit 0, got $RC: $OUT / $(head -c 600 "$WORK/last-stderr.txt")"
[ "$(jq -r '.outcome' <<<"$OUT")" = "BATCH_COMPLETE" ] || fail "C1: expected BATCH_COMPLETE, got: $OUT"
[ "$(jq -r '.selection.selected_records_n' <<<"$OUT")" = "2" ] || fail "C1: expected 2 selected corpus records (the rejected one is never replayed), got: $OUT"
[ "$(jq -r '.legs.planned_n' <<<"$OUT")" = "4" ] || fail "C1: 2 records x 2 arms = 4 executed replays, got: $OUT"
[ "$(jq -r '.legs.completed_n' <<<"$OUT")" = "4" ] || fail "C1: expected 4 completed legs, got: $OUT"
[ "$(wc -l <"$CORPUS_A" | tr -d ' ')" = "3" ] || fail "C1: corpus fixture changed shape"
ok "C1 happy path: 2 eligible corpus records -> 4 executed replays, BATCH_COMPLETE"

# C2 — every selected record appears in BOTH arm files, keyed by outcome ref.
count
[ "$(lines "$A_OUT/baseline.jsonl")" = "2" ] || fail "C2: baseline.jsonl should carry 2 records: $(cat "$A_OUT/baseline.jsonl")"
[ "$(lines "$A_OUT/candidate.jsonl")" = "2" ] || fail "C2: candidate.jsonl should carry 2 records"
for ref in 101 103; do
  jq -e --argjson pr "$ref" 'select(.pr == $pr)' <"$A_OUT/baseline.jsonl" >/dev/null \
    || fail "C2: pr:$ref missing from the baseline arm"
  jq -e --argjson pr "$ref" 'select(.pr == $pr)' <"$A_OUT/candidate.jsonl" >/dev/null \
    || fail "C2: pr:$ref missing from the candidate arm"
done
A_PAIRED="$(jq -r '.pairing.paired_outcomes_n' <<<"$OUT")"
[ "$A_PAIRED" = "2" ] || fail "C2: expected 2 paired outcomes, got: $OUT"
ok "C2 both arms carry every selected record — 2 paired outcomes, the unit the report's floor is applied to"

# C3 — the two arms really are two DIFFERENT arms (the models differ), and the
#      driver's authorized figures are the GATE's own, in the GATE's own unit.
count
base_models="$(jq -r '.candidate.model' <"$A_OUT/baseline.jsonl" | sort -u | tr '\n' ',')"
cand_models="$(jq -r '.candidate.model' <"$A_OUT/candidate.jsonl" | sort -u | tr '\n' ',')"
[ "$base_models" = "recorded-baseline-model," ] || fail "C3: baseline arm models: $base_models"
[ "$cand_models" = "recorded-candidate-model," ] || fail "C3: candidate arm models: $cand_models"
pf_cost="$(jq -r '.preflight.estimated_cost' <<<"$OUT")"
pf_basis="$(jq -r '.preflight.cost_basis' <<<"$OUT")"
[ "$(jq -r '.authorized.estimated_cost' <<<"$OUT")" = "$pf_cost" ] || fail "C3: authorized.estimated_cost is not the gate's own figure: $OUT"
[ "$(jq -r '.authorized.cost_basis' <<<"$OUT")" = "$pf_basis" ] || fail "C3: authorized.cost_basis is not the gate's own unit: $OUT"
[ "$pf_basis" = "cost-weighted-token-units" ] || fail "C3: the cost unit is not the shared cost-weighted unit (temperloop#1380): $pf_basis"
[ "$(jq -r '.authorized.replays_n' <<<"$OUT")" = "4" ] || fail "C3: authorized.replays_n should be the gate's two-arm figure: $OUT"
[ "$(jq -r '.legs.planned_n' <<<"$OUT")" = "$(jq -r '.authorized.replays_n' <<<"$OUT")" ] \
  || fail "C3: the legs this driver PLANNED and the replays the gate AUTHORIZED must be the same number: $OUT"
ok "C3 the arms differ, and the authorized cost/records/replays are the gate's own figures in the gate's own unit"

# C4 — the BATCH CAP binds CORPUS RECORDS, and it comes from the gate.
count
CAP_OUT="$WORK/out-cap"; CAP_STATE="$WORK/state-cap"
: >"$CAND_LOG"
DRIVE_ARGS=(--corpus-file "$CORPUS_CAP" --repo-root "$REPO" --out-dir "$CAP_OUT" --state-dir "$CAP_STATE"
            --baseline-runner "bash $BASE_STUB" --candidate-runner "bash $CAND_STUB" --confirm)
drive "" REPLAY_PREFLIGHT_BATCH_CAP=2
[ "$RC" -eq 0 ] || fail "C4: the capped batch should exit 0, got $RC: $OUT / $(head -c 600 "$WORK/last-stderr.txt")"
[ "$(jq -r '.selection.selected_records_n' <<<"$OUT")" = "2" ] || fail "C4: the cap binds CORPUS RECORDS (3 eligible, cap 2), got: $OUT"
[ "$(jq -r '.authorized.batch_cap' <<<"$OUT")" = "2" ] || fail "C4: expected the gate's own batch_cap of 2, got: $OUT"
[ "$(jq -r '.legs.planned_n' <<<"$OUT")" = "4" ] || fail "C4: 2 capped records x 2 arms = 4 replays, got: $OUT"
[ "$(wc -l <"$CAND_LOG" | tr -d ' ')" = "4" ] || fail "C4: expected exactly 4 candidate-runner calls, got $(wc -l <"$CAND_LOG")"
ok "C4 REPLAY_PREFLIGHT_BATCH_CAP honoured in CORPUS RECORDS, and read off the gate that authorized the spend"

# C5 — MUTATION PROOF (two-arm): a driver that replays only one arm produces
#      an empty candidate arm and ZERO paired outcomes.
count
MUT_C="$WORK/mut-onearm"; mk_mirror "$MUT_C"
MUT_C_SUT="$MUT_C/workflows/scripts/model-comparison/batch.sh"
unlink_and_copy "$MUT_C_SUT"
# The execute loop iterates the COUNTERBALANCED pair (temperloop#1571), so
# the one-arm mutation pins it to the baseline arm literal — the same
# baseline-only batch this proof has always forced, expressed against the
# loop's current shape.
mutate_file "$MUT_C_SUT" \
  '  for arm in "$arm_first" "$arm_second"; do
    arm_pos=$((arm_pos + 1))' \
  '  for arm in "$BATCH_ARM_BASELINE"; do
    arm_pos=$((arm_pos + 1))'
MUT_C_OUT="$WORK/out-mut-c"; MUT_C_STATE="$WORK/state-mut-c"
DRIVE_ARGS=(--corpus-file "$CORPUS_A" --repo-root "$REPO" --out-dir "$MUT_C_OUT" --state-dir "$MUT_C_STATE"
            --baseline-runner "bash $BASE_STUB" --candidate-runner "bash $CAND_STUB" --confirm)
drive "$MUT_C_SUT"
mut_c_paired="$(jq -r '.pairing.paired_outcomes_n' <<<"$OUT" 2>/dev/null)"
[ "$mut_c_paired" = "0" ] || fail "C5: the mutation proof did not fire — a one-arm driver should produce 0 paired outcomes, got '$mut_c_paired': $OUT"
[ "$(lines "$MUT_C_OUT/candidate.jsonl")" = "0" ] || fail "C5: a one-arm driver still wrote a candidate arm"
ok "C5 MUTATION PROOF: a one-arm driver yields an EMPTY candidate arm and 0 paired outcomes — C2's two-arm assertion is load-bearing"

# C6 — MUTATION PROOF (the cap's provenance): a cap taken from anywhere but
#      the gate makes the executed batch disagree with the authorized one, and
#      the driver REFUSES rather than spending on the difference.
count
MUT_D="$WORK/mut-cap"; mk_mirror "$MUT_D"
MUT_D_SUT="$MUT_D/workflows/scripts/model-comparison/batch.sh"
unlink_and_copy "$MUT_D_SUT"
mutate_file "$MUT_D_SUT" \
  '    [ "$idx" -lt "$batch_cap" ] || break' \
  '    [ "$idx" -lt 9999 ] || break'
MUT_D_OUT="$WORK/out-mut-d"; MUT_D_STATE="$WORK/state-mut-d"
: >"$CAND_LOG"
DRIVE_ARGS=(--corpus-file "$CORPUS_CAP" --repo-root "$REPO" --out-dir "$MUT_D_OUT" --state-dir "$MUT_D_STATE"
            --baseline-runner "bash $BASE_STUB" --candidate-runner "bash $CAND_STUB" --confirm)
drive "$MUT_D_SUT" REPLAY_PREFLIGHT_BATCH_CAP=2
[ "$RC" -ne 0 ] || fail "C6: the mutation proof did not fire — ignoring the gate's cap should be refused, got exit 0: $OUT"
[ "$(jq -r '.outcome' <<<"$OUT")" = "CANNOT_EVALUATE" ] || fail "C6: expected CANNOT_EVALUATE, got: $OUT"
[ "$(wc -l <"$CAND_LOG" | tr -d ' ')" = "0" ] || fail "C6: a batch that disagreed with its authorization still spent"
ok "C6 MUTATION PROOF: a selection that ignores the gate's cap is REFUSED before any spend, never silently over-spent"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION D — one record's failure does not abort the batch, and the
# completion rate falls out of the driver's own output.
# ═══════════════════════════════════════════════════════════════════════════
FAIL_OUT="$WORK/out-fail"; FAIL_STATE="$WORK/state-fail"

# D1 — the middle record cannot be prepared; the batch carries on.
count
: >"$CAND_LOG"
DRIVE_ARGS=(--corpus-file "$CORPUS_FAIL" --repo-root "$REPO" --out-dir "$FAIL_OUT" --state-dir "$FAIL_STATE"
            --baseline-runner "bash $BASE_STUB" --candidate-runner "bash $CAND_STUB" --confirm)
drive ""
[ "$RC" -eq 4 ] || fail "D1: a batch with a failed leg should exit 4 (BATCH_DEGRADED), got $RC: $OUT"
[ "$(jq -r '.outcome' <<<"$OUT")" = "BATCH_DEGRADED" ] || fail "D1: expected BATCH_DEGRADED, got: $OUT"
[ "$(jq -r '.legs.planned_n' <<<"$OUT")" = "6" ] || fail "D1: 3 records x 2 arms = 6 planned replays, got: $OUT"
[ "$(jq -r '.legs.failed_n' <<<"$OUT")" = "2" ] || fail "D1: the unpreparable record fails in BOTH arms, got: $OUT"
[ "$(jq -r '.legs.completed_n' <<<"$OUT")" = "4" ] || fail "D1: the other two records must still have completed, got: $OUT"
[ "$(jq -r '[.failures[] | select(.outcome_ref == "pr:302")] | length' <<<"$OUT")" = "2" ] \
  || fail "D1: both failed legs must be NAMED in failures[] with their ref: $OUT"
jq -e '[.failures[] | select((.reason // "") | length > 0)] | length == 2' <<<"$OUT" >/dev/null \
  || fail "D1: every failure must carry a reason: $OUT"
[ "$(lines "$FAIL_OUT/baseline.jsonl")" = "2" ] || fail "D1: the surviving records must still reach the baseline arm"
[ "$(lines "$FAIL_OUT/candidate.jsonl")" = "2" ] || fail "D1: the surviving records must still reach the candidate arm"
jq -e 'select(.pr == 302)' <"$FAIL_OUT/baseline.jsonl" >/dev/null 2>&1 \
  && fail "D1: the failed record must not appear in an arm file"
ok "D1 a record that cannot be replayed is recorded as failed WITH its reason, and the batch continues"

# D2 — the completion rate is the driver's own output, not a hand count.
count
[ "$(jq -r '.completion.replay_completion_rate' <<<"$OUT")" = "0.6667" ] \
  || fail "D2: 4 of 6 executed replays completed -> 0.6667, got: $(jq -r '.completion.replay_completion_rate' <<<"$OUT")"
jq -e '.completion.basis | type == "string" and (length > 0)' <<<"$OUT" >/dev/null \
  || fail "D2: the completion rate must state its own basis: $OUT"
[ "$(jq -r '.units.replay_completion_rate' <<<"$OUT")" = "executed_replays completed / executed_replays planned" ] \
  || fail "D2: the completion rate must NAME its unit: $OUT"
ok "D2 replay completion rate (0.6667 = 4/6 executed replays) falls out of the driver's own output, unit named"

# D3 — MUTATION PROOF. A driver that counts a failed leg as completed reports
#      a perfect 1.0 — "could not evaluate" rendered as "evaluated, and fine".
#
#      The mutation targets bd_derive_counts, which is where the tally is made
#      since temperloop#1682 — it used to sit at the failure site inside the
#      execute loop. Note the mutated leg is STILL named in failures[]: the
#      point of the proof is a driver whose count disagrees with the failures
#      it is simultaneously reporting, which is exactly how "could not
#      evaluate" gets rendered as "evaluated, and fine".
count
MUT_E="$WORK/mut-rate"; mk_mirror "$MUT_E"
MUT_E_SUT="$MUT_E/workflows/scripts/model-comparison/batch.sh"
unlink_and_copy "$MUT_E_SUT"
mutate_file "$MUT_E_SUT" \
  '        *)
          legs_failed=$((legs_failed + 1))
          d_reason=' \
  '        *)
          legs_done=$((legs_done + 1))
          d_reason='
MUT_E_OUT="$WORK/out-mut-e"; MUT_E_STATE="$WORK/state-mut-e"
DRIVE_ARGS=(--corpus-file "$CORPUS_FAIL" --repo-root "$REPO" --out-dir "$MUT_E_OUT" --state-dir "$MUT_E_STATE"
            --baseline-runner "bash $BASE_STUB" --candidate-runner "bash $CAND_STUB" --confirm)
drive "$MUT_E_SUT"
mut_e_rate="$(jq -r '.completion.replay_completion_rate' <<<"$OUT" 2>/dev/null)"
[ "$mut_e_rate" = "1" ] || fail "D3: the mutation proof did not fire — counting a failed leg as completed should report a perfect rate, got '$mut_e_rate': $OUT"
ok "D3 MUTATION PROOF: counting an unreplayable leg as completed reports 1.0 — D2's rate is a measurement, not a formality"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION E — RESUMABILITY. A re-invocation re-spends nothing.
# ═══════════════════════════════════════════════════════════════════════════

# E1 — re-run the SAME batch against the SAME state dir.
count
: >"$CAND_LOG"
DRIVE_ARGS=(--corpus-file "$CORPUS_A" --repo-root "$REPO" --out-dir "$A_OUT" --state-dir "$A_STATE"
            --baseline-runner "bash $BASE_STUB" --candidate-runner "bash $CAND_STUB"
            --judge-runner "bash $JUDGE_STUB" --confirm)
drive ""
[ "$RC" -eq 0 ] || fail "E1: the resumed batch should exit 0, got $RC: $OUT"
[ "$(wc -l <"$CAND_LOG" | tr -d ' ')" = "0" ] || fail "E1: a resumed batch RE-SPENT $(wc -l <"$CAND_LOG") replays"
[ "$(jq -r '.legs.resumed_n' <<<"$OUT")" = "4" ] || fail "E1: expected all 4 legs resumed, got: $OUT"
[ "$(jq -r '.legs.completed_n' <<<"$OUT")" = "4" ] || fail "E1: a resumed batch must still report its completed legs, got: $OUT"
[ "$(lines "$A_OUT/baseline.jsonl")" = "2" ] || fail "E1: a resumed run must re-emit COMPLETE arm files, not just its own share"
[ "$(lines "$A_OUT/candidate.jsonl")" = "2" ] || fail "E1: a resumed run must re-emit COMPLETE arm files"
ok "E1 re-invocation: 0 replays re-spent, 4 legs resumed, arm files still complete"

# E2 — an interrupted batch: delete ONE leg's state and its record, then
#      resume. Exactly that one leg is re-executed — no more, no less.
count
: >"$CAND_LOG"
rm -f "$A_STATE/legs/candidate/002-pr-103.state.json" "$A_STATE/legs/candidate/002-pr-103.json"
drive ""
[ "$RC" -eq 0 ] || fail "E2: the partially-resumed batch should exit 0, got $RC: $OUT"
[ "$(wc -l <"$CAND_LOG" | tr -d ' ')" = "1" ] || fail "E2: exactly ONE leg should have been re-executed, got $(wc -l <"$CAND_LOG"): $(cat "$CAND_LOG")"
[ "$(jq -r '.legs.resumed_n' <<<"$OUT")" = "3" ] || fail "E2: expected 3 resumed legs, got: $OUT"
[ "$(lines "$A_OUT/candidate.jsonl")" = "2" ] || fail "E2: the re-executed leg must rejoin a COMPLETE candidate arm"
ok "E2 an interrupted leg is re-executed and ONLY that leg — the other three are not re-spent"

# E3 — MUTATION PROOF. Neuter the resume check and the same re-invocation
#      re-spends every leg.
count
MUT_F="$WORK/mut-resume"; mk_mirror "$MUT_F"
MUT_F_SUT="$MUT_F/workflows/scripts/model-comparison/batch.sh"
unlink_and_copy "$MUT_F_SUT"
mutate_file "$MUT_F_SUT" '    if [ -f "$leg_state" ]; then' '    if false; then'
: >"$CAND_LOG"
drive "$MUT_F_SUT"
mut_f_calls="$(wc -l <"$CAND_LOG" | tr -d ' ')"
[ "$mut_f_calls" = "4" ] || fail "E3: the mutation proof did not fire — with the resume check neutered all 4 legs should re-spend, got $mut_f_calls"
: >"$CAND_LOG"
ok "E3 MUTATION PROOF: neutering the resume check re-spends all 4 legs — E1's 'nothing re-spent' is a measurement"

# E4 — a state dir is bound to ONE batch: a different corpus is refused, never
#      silently mixed into the same arm files.
count
DRIVE_ARGS=(--corpus-file "$CORPUS_CAP" --repo-root "$REPO" --out-dir "$A_OUT" --state-dir "$A_STATE"
            --baseline-runner "bash $BASE_STUB" --candidate-runner "bash $CAND_STUB" --confirm)
drive ""
[ "$RC" -eq 1 ] || fail "E4: resuming a state dir against a DIFFERENT corpus should be CANNOT_EVALUATE, got $RC: $OUT"
grep -q 'DIFFERENT batch' <<<"$OUT" || fail "E4: the refusal must name the mismatch: $OUT"
[ "$(lines "$A_OUT/baseline.jsonl")" = "2" ] || fail "E4: the refused run corrupted the existing arm file"
ok "E4 a state dir bound to another batch is REFUSED — two batches never merge into one arm file"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION F — ISOLATION: teardown on both paths, and a clean parent.
# ═══════════════════════════════════════════════════════════════════════════

# F1 — after the DEGRADED batch of section D (a run with both a success and a
#      failure path), no replay worktree survives and the parent is clean.
count
[ "$(wt_count)" = "0" ] || fail "F1: $(wt_count) replay worktree(s) survived the batch: $(ls -d "${REPO}.wt"/mc-replay-* 2>/dev/null)"
[ "$(git -C "$REPO" worktree list | grep -c 'mc-replay')" = "0" ] || fail "F1: a replay worktree is still registered with git"
[ "$(git -C "$REPO" branch --list 'build/mc-replay-*' | wc -l | tr -d ' ')" = "0" ] || fail "F1: a replay branch survived teardown"
DRIVE_ARGS=(--corpus-file "$CORPUS_FAIL" --repo-root "$REPO" --out-dir "$FAIL_OUT" --state-dir "$FAIL_STATE"
            --baseline-runner "bash $BASE_STUB" --candidate-runner "bash $CAND_STUB" --confirm)
drive ""
[ "$(jq -r '.isolation.verify_clean_parent' <<<"$OUT")" = "CLEAN" ] \
  || fail "F1: replay.sh verify-clean-parent should pass after the batch, got: $(jq -c '.isolation' <<<"$OUT")"
ok "F1 every prepared worktree torn down on BOTH the success and the failure path; verify-clean-parent CLEAN"

# F2 — MUTATION PROOF. With teardown (and the end-of-batch sweep) neutered,
#      the worktrees survive — so F1 is measuring something real.
count
MUT_G="$WORK/mut-teardown"; mk_mirror "$MUT_G"
MUT_G_SUT="$MUT_G/workflows/scripts/model-comparison/batch.sh"
unlink_and_copy "$MUT_G_SUT"
mutate_file "$MUT_G_SUT" \
  '    bash "$REPLAY_SH" worktree-teardown "$repo_root" "$slug" >/dev/null 2>&1 || true' \
  '    : "$slug"'
mutate_file "$MUT_G_SUT" \
  '        bash "$REPLAY_SH" worktree-teardown "$repo_root" "$sweep_slug" >/dev/null 2>&1 || true' \
  '        : "$sweep_slug"'
MUT_G_OUT="$WORK/out-mut-g"; MUT_G_STATE="$WORK/state-mut-g"
DRIVE_ARGS=(--corpus-file "$CORPUS_A" --repo-root "$REPO" --out-dir "$MUT_G_OUT" --state-dir "$MUT_G_STATE"
            --baseline-runner "bash $BASE_STUB" --candidate-runner "bash $CAND_STUB" --confirm)
drive "$MUT_G_SUT"
mut_g_wt="$(wt_count)"
[ "$mut_g_wt" -gt 0 ] || fail "F2: the mutation proof did not fire — with teardown removed a replay worktree should survive, got $mut_g_wt"
# ...and clean the mutation's residue up so it cannot leak into later sections.
for d in "${REPO}.wt"/mc-replay-*; do
  [ -e "$d" ] || continue
  bash "$MC_DIR/replay.sh" worktree-teardown "$REPO" "$(basename "$d")" >/dev/null 2>&1 || true
done
[ "$(wt_count)" = "0" ] || fail "F2: could not clean up the mutation proof's leaked worktrees"
ok "F2 MUTATION PROOF: removing teardown leaks $mut_g_wt worktree(s) — F1's clean sweep is load-bearing"

fi

if run_group 3; then  # sections G, H
# Section C1 built $A_OUT/$A_STATE; on a SHARD that did not run section C,
# rebuild it here from the same drive before G reports on it and H judges it.
# Skipped on a whole-suite run, where C1 has already produced it — so `all`
# executes exactly the drives it always did (temperloop#2163).
if [ "$GROUP" != "all" ]; then
  drive_a_happy_path
  # C3 reads the authorized cost UNIT off that same run; G2 compares the
  # report's unit against it, so a shard has to re-derive it here.
  pf_basis="$(jq -r '.preflight.cost_basis' <<<"$OUT")"
fi
# ═══════════════════════════════════════════════════════════════════════════
# SECTION G — THE REPORT PRODUCER CONSUMES THE DRIVER'S OUTPUT UNCHANGED.
# ═══════════════════════════════════════════════════════════════════════════

# G1 — the real producer, on the driver's real fixture output, with no edits.
count
prod_out="$(cd "$WORK" && env MODEL_COMPARISON_REPORT_RECORDS_DIR="$A_OUT" bash "$PRODUCER" 2>/dev/null)"
prod_rc=$?
[ "$prod_rc" -eq 0 ] || fail "G1: the report producer must exit 0 (it is a report drop-in), got $prod_rc"
case "$prod_out" in
  "skipped -- "*) fail "G1: the producer SKIPPED the driver's own output — the driver is not producing that producer's input: $prod_out" ;;
esac
jq -e 'type == "object"' <<<"$prod_out" >/dev/null 2>&1 || fail "G1: the producer did not print one JSON object: $(head -c 400 <<<"$prod_out")"
[ "$(jq -r '.comparison.paired_outcomes_n' <<<"$prod_out")" = "2" ] \
  || fail "G1: the producer paired $(jq -r '.comparison.paired_outcomes_n' <<<"$prod_out") outcomes, the driver claimed 2"
[ "$(jq -r '.comparison.paired_outcomes_n' <<<"$prod_out")" = "$(jq -r '.pairing.paired_outcomes_n' <<<"$OUT")" ] \
  || fail "G1: the driver'"'"'s paired-outcome count and the producer'"'"'s disagree"
[ "$(jq -r '.arms.baseline.records_n' <<<"$prod_out")" = "2" ] || fail "G1: the producer read the wrong baseline arm size"
[ "$(jq -r '.arms.candidate.records_n' <<<"$prod_out")" = "2" ] || fail "G1: the producer read the wrong candidate arm size"
ok "G1 workflows/scripts/report-producers/model-comparison consumes the driver's arm files UNCHANGED (2 paired outcomes, both arms read)"

# G2 — the cost unit the driver authorized and the unit the report publishes
#      are the same string (temperloop#1380's identity, end to end).
count
case "$(jq -r '.arms.baseline.cost.unit' <<<"$prod_out")" in
  "cost-weighted token units"*) ;;
  *) fail "G2: unexpected report cost unit: $(jq -r '.arms.baseline.cost.unit' <<<"$prod_out")" ;;
esac
[ "$(jq -r '.cost_basis.unit' <<<"$prod_out")" = "$pf_basis" ] \
  || fail "G2: the report's cost_basis.unit ($(jq -r '.cost_basis.unit' <<<"$prod_out")) and the batch the driver authorized ($pf_basis) are different units"
ok "G2 the unit the driver authorized the batch in is byte-identically the unit the report publishes"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION H — JUDGING: wired, resumable, and a skip is NAMED.
# ═══════════════════════════════════════════════════════════════════════════

# H1 — the judge pass annotated every record in both arms.
count
[ "$(jq -s '[.[] | select(.judge.outcome == "JUDGED")] | length' <"$A_OUT/baseline.jsonl")" = "2" ] \
  || fail "H1: the baseline arm is not fully judged: $(jq -c '[.judge.outcome]' <"$A_OUT/baseline.jsonl")"
[ "$(jq -s '[.[] | select(.judge.outcome == "JUDGED")] | length' <"$A_OUT/candidate.jsonl")" = "2" ] \
  || fail "H1: the candidate arm is not fully judged"
[ "$(jq -r '.arms.baseline.judge_quality.judged_n' <<<"$prod_out")" = "2" ] \
  || fail "H1: the report did not see the driver's judge annotations: $(jq -c '.arms.baseline.judge_quality' <<<"$prod_out")"
ok "H1 the judge pass annotated both arms, and the report reads those annotations"

# H2 — a judge seam is REQUIRED to judge: with none, the arm files are written
#      UNJUDGED and the skip is NAMED, never silent.
count
NOJ_OUT="$WORK/out-nojudge"; NOJ_STATE="$WORK/state-nojudge"
DRIVE_ARGS=(--corpus-file "$CORPUS_A" --repo-root "$REPO" --out-dir "$NOJ_OUT" --state-dir "$NOJ_STATE"
            --baseline-runner "bash $BASE_STUB" --candidate-runner "bash $CAND_STUB" --confirm)
drive ""
[ "$RC" -eq 0 ] || fail "H2: an unjudged batch is still a complete batch, got $RC: $OUT"
[ "$(jq -r '.judge.ran' <<<"$OUT")" = "false" ] || fail "H2: expected judge.ran false, got: $(jq -c .judge <<<"$OUT")"
jq -e '.judge.reason | type == "string" and (length > 20)' <<<"$OUT" >/dev/null \
  || fail "H2: a skipped judge pass must carry a NAMED reason: $(jq -c .judge <<<"$OUT")"
[ "$(jq -s '[.[] | select(has("judge"))] | length' <"$NOJ_OUT/baseline.jsonl")" = "0" ] \
  || fail "H2: an unjudged arm must carry no judge sub-object at all"
ok "H2 no judge seam: the arms are written UNJUDGED and the skip is NAMED, never presented as judged"

# H3 — the judge pass is resumable too: a re-invocation makes no judge call.
count
: >"$JUDGE_LOG"
DRIVE_ARGS=(--corpus-file "$CORPUS_A" --repo-root "$REPO" --out-dir "$A_OUT" --state-dir "$A_STATE"
            --baseline-runner "bash $BASE_STUB" --candidate-runner "bash $CAND_STUB"
            --judge-runner "bash $JUDGE_STUB" --confirm)
drive ""
[ "$RC" -eq 0 ] || fail "H3: the resumed judged batch should exit 0, got $RC: $OUT"
[ "$(wc -l <"$JUDGE_LOG" | tr -d ' ')" = "0" ] || fail "H3: a resumed batch RE-SPENT $(wc -l <"$JUDGE_LOG") judge calls"
[ "$(jq -r '[.judge.per_arm[] | select(.outcome == "RESUMED")] | length' <<<"$OUT")" = "2" ] \
  || fail "H3: both arms should report a RESUMED judge pass: $(jq -c .judge <<<"$OUT")"
ok "H3 the judge pass is resumable: 0 judge calls re-spent on re-invocation"

# H4 — MUTATION PROOF, and the live-arm canary. Force the candidate arm to
#      `--live` in a mirrored copy and the canary `claude` DOES fire.
count
[ ! -e "$CANARY" ] || fail "H4: the canary fired before its own mutation proof: $(cat "$CANARY")"
MUT_H="$WORK/mut-live"; mk_mirror "$MUT_H"
MUT_H_SUT="$MUT_H/workflows/scripts/model-comparison/batch.sh"
unlink_and_copy "$MUT_H_SUT"
mutate_file "$MUT_H_SUT" \
  '        *) xa+=(--candidate-runner "$candidate_runner") ;;' \
  '        *) xa+=(--live) ;;'
MUT_H_OUT="$WORK/out-mut-h"; MUT_H_STATE="$WORK/state-mut-h"
DRIVE_ARGS=(--corpus-file "$CORPUS_A" --repo-root "$REPO" --out-dir "$MUT_H_OUT" --state-dir "$MUT_H_STATE"
            --baseline-runner "bash $BASE_STUB" --candidate-runner "bash $CAND_STUB" --confirm)
drive "$MUT_H_SUT"
[ -e "$CANARY" ] || fail "H4: the mutation proof did not fire — forcing the candidate arm live should have reached the canary 'claude', so the canary cannot detect a real live leak either"
rm -f "$CANARY"
ok "H4 MUTATION PROOF: forcing the candidate arm to --live DOES reach a bare 'claude' — the recorded seam is what keeps this suite hermetic"

# ...and the restored driver does not.
count
DRIVE_ARGS=(--corpus-file "$CORPUS_A" --repo-root "$REPO" --out-dir "$MUT_H_OUT" --state-dir "$WORK/state-mut-h2"
            --baseline-runner "bash $BASE_STUB" --candidate-runner "bash $CAND_STUB" --confirm)
drive ""
[ ! -e "$CANARY" ] || fail "H5: the unmutated driver reached a 'claude' binary: $(cat "$CANARY")"
ok "H5 the unmutated driver, on the same input, reaches no 'claude' at all"

fi

if run_group 4; then  # sections I, J
# ═══════════════════════════════════════════════════════════════════════════
# SECTION I — INTERRUPT SEMANTICS (temperloop#1527).
#
# This driver is the module's SPEND-BEARING entry point: the one thing that
# calls `replay.sh execute` in a loop. An operator's ^C (or a supervisor's
# `kill`) on such a loop means STOP SPENDING — so it must stop, not tear the
# in-flight worktree down and calmly start the next leg. The pre-fix shape
# registered ONE handler on `EXIT INT TERM`; a bash trap handler RETURNS, so
# the signal ran the cleanup and the script RESUMED. I3 mutates the fix back
# to exactly that shape and measures the batch continuing, so I1 is a
# measurement rather than a restatement of the code.
#
# Note what this section deliberately does NOT assert away: per-leg failure
# resilience. Section D still pins that a genuinely FAILED leg lets the batch
# continue — only an actual signal stops it.
# ═══════════════════════════════════════════════════════════════════════════

# mk_interrupt_stub <path> <log> <pidfile> — a recorded runner that behaves
# exactly like mk_stub's (same canned envelope, same worktree edits, so the
# leg it serves COMPLETES normally) and then, on its FIRST call only, sends
# SIGTERM to the batch driver whose pid the test wrote to <pidfile>. The kill
# therefore lands mid-batch, with legs still to go — precisely the state the
# fix is about. It is sent AFTER the envelope is printed, so the interrupted
# leg is a normal leg and the assertion is purely about what happens NEXT.
mk_interrupt_stub() {
  local p="$1" log="$2" pidfile="$3"
  cat >"$p" <<STUBEOF
#!/usr/bin/env bash
set -u
printf 'interrupt-stub %s\n' "\$1" >>"$log"
wt="\$2"
cp "$TRUTH_PY" "\$wt/workflows/scripts/drain/scan_stub.py"
mkdir -p "\$wt/workflows/scripts/drain/tests"
printf '#!/usr/bin/env bash\necho candidate-test\n' >"\$wt/workflows/scripts/drain/tests/test_scan_stub.sh"
jq -cn '{type:"result", subtype:"success", is_error:false, duration_ms:4242,
  modelUsage:{"recorded-interrupt-model":{inputTokens:1200, outputTokens:340,
                     cacheReadInputTokens:9000, cacheCreationInputTokens:120,
                     provider:"firstParty"}}}'
if [ "\$(wc -l <"$log" | tr -d ' ')" = "1" ]; then
  bp=""
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    bp="\$(cat "$pidfile" 2>/dev/null)" || bp=""
    [ -n "\$bp" ] && break
    sleep 0.2
  done
  [ -n "\$bp" ] && kill -TERM "\$bp" 2>/dev/null
fi
exit 0
STUBEOF
  chmod +x "$p"
}

# drive_bg <sut> <log> <pidfile> <out-dir> <state-dir> — start the driver in
# the BACKGROUND over CORPUS_A (2 records x 2 arms = 4 legs) with the
# interrupting stub on both arms, publish its pid for the stub to kill, and
# wait. No `env` wrapper: the var assignments prefix `bash` directly so `$!`
# is unambiguously the driver's own pid, which is what gets signalled.
# Sets BG_RC (the driver's wait status), BG_STDOUT, BG_STDERR.
BG_RC=0; BG_STDOUT=""; BG_STDERR=""
drive_bg() {
  local sut="$1" log="$2" pidfile="$3" odir="$4" sdir="$5" pid
  BG_STDOUT="$WORK/bg-stdout-$(basename "$sdir").txt"
  BG_STDERR="$WORK/bg-stderr-$(basename "$sdir").txt"
  : >"$log"; rm -f "$pidfile"
  BUILD_QUOTA_CACHE="$NOCACHE" \
  MODEL_USAGE_RAW_DIR="$LAKE" \
  PROVIDER_ALLOWLIST_TEST_SEAM=1 \
  PROVIDER_ALLOWLIST_COMMITTED_FILE="$ALLOW" \
  PROVIDER_ALLOWLIST_LOCAL_FILE="$NOLOCAL" \
  PROVIDER_DISCLOSURE_LOG_FILE="$DLOG" \
  bash "$sut" run --corpus-file "$CORPUS_A" --repo-root "$REPO" \
       --out-dir "$odir" --state-dir "$sdir" \
       --baseline-runner "bash $INT_STUB_FOR_RUN" \
       --candidate-runner "bash $INT_STUB_FOR_RUN" \
       --confirm >"$BG_STDOUT" 2>"$BG_STDERR" &
  pid=$!
  printf '%s\n' "$pid" >"$pidfile"
  BG_RC=0
  wait "$pid" || BG_RC=$?
}

# I1 — a SIGTERM mid-batch STOPS the run: the next leg never begins, no
#      summary object is printed, and the process dies OF the signal.
count
INT_LOG="$WORK/interrupt-calls.log"
INT_PIDFILE="$WORK/interrupt-batch.pid"
INT_STUB_FOR_RUN="$WORK/stub-interrupt.sh"
mk_interrupt_stub "$INT_STUB_FOR_RUN" "$INT_LOG" "$INT_PIDFILE"
INT_OUT="$WORK/out-interrupt"; INT_STATE="$WORK/state-interrupt"
drive_bg "$SUT" "$INT_LOG" "$INT_PIDFILE" "$INT_OUT" "$INT_STATE"
int_calls="$(wc -l <"$INT_LOG" | tr -d ' ')"
[ "$int_calls" = "1" ] \
  || fail "I1: the TERMed batch did NOT stop — exactly 1 leg should have executed before the interrupt, got $int_calls: $(tail -c 400 "$BG_STDERR")"
[ "$BG_RC" -eq 143 ] \
  || fail "I1: an interrupted batch must die OF the signal (128+15=143), got exit $BG_RC: $(tail -c 400 "$BG_STDERR")"
[ ! -s "$BG_STDOUT" ] \
  || fail "I1: an interrupted batch printed a summary object it never earned: $(head -c 300 "$BG_STDOUT")"
[ ! -e "$INT_OUT/baseline.jsonl" ] \
  || fail "I1: an interrupted batch assembled arm files — it ran on past the execution loop"
ok "I1 SIGTERM mid-leg STOPS the batch: 1 of 4 legs executed, no arm files, exit 143 (signal-derived, not an invented code)"

# I2 — the interrupt path still tears the IN-FLIGHT worktree down, and names
#      itself rather than dying mute.
count
[ "$(wt_count)" = "0" ] \
  || fail "I2: the in-flight replay worktree survived the interrupt: $(ls -d "${REPO}.wt"/mc-replay-* 2>/dev/null)"
[ "$(git -C "$REPO" worktree list | grep -c 'mc-replay')" = "0" ] \
  || fail "I2: an interrupted batch left a replay worktree registered with git"
grep -q 'INTERRUPTED' "$BG_STDERR" \
  || fail "I2: the interrupt path must NAME itself on stderr, never die mute: $(tail -c 400 "$BG_STDERR")"
ok "I2 the interrupt tears the in-flight worktree down (the pre-fix cleanup is preserved, not lost) and NAMES itself on stderr"

# I3 — MUTATION PROOF. Restore the pre-fix single `trap … EXIT INT TERM` in a
#      mirrored copy and the very same TERM cleans up and CONTINUES — which is
#      the defect, and is what makes I1 a measurement.
count
MUT_I="$WORK/mut-signal"; mk_mirror "$MUT_I"
MUT_I_SUT="$MUT_I/workflows/scripts/model-comparison/batch.sh"
unlink_and_copy "$MUT_I_SUT"
mutate_file "$MUT_I_SUT" \
  "trap bd_trap_cleanup EXIT
trap 'bd_trap_signal INT' INT
trap 'bd_trap_signal TERM' TERM" \
  "trap bd_trap_cleanup EXIT INT TERM"
MUT_I_LOG="$WORK/interrupt-calls-mut.log"
MUT_I_PIDFILE="$WORK/interrupt-batch-mut.pid"
INT_STUB_FOR_RUN="$WORK/stub-interrupt-mut.sh"
mk_interrupt_stub "$INT_STUB_FOR_RUN" "$MUT_I_LOG" "$MUT_I_PIDFILE"
MUT_I_OUT="$WORK/out-mut-i"; MUT_I_STATE="$WORK/state-mut-i"
drive_bg "$MUT_I_SUT" "$MUT_I_LOG" "$MUT_I_PIDFILE" "$MUT_I_OUT" "$MUT_I_STATE"
mut_i_calls="$(wc -l <"$MUT_I_LOG" | tr -d ' ')"
[ "$mut_i_calls" = "4" ] \
  || fail "I3: the mutation proof did not fire — with the pre-fix single trap the TERMed batch should have cleaned up and CONTINUED all 4 legs, got $mut_i_calls: $(tail -c 400 "$BG_STDERR")"
[ "$BG_RC" -ne 143 ] \
  || fail "I3: the mutation proof did not fire — the pre-fix shape should NOT have died of the signal"
ok "I3 MUTATION PROOF: the pre-fix single 'trap … EXIT INT TERM' runs the cleanup and CONTINUES all $mut_i_calls legs — I1's stop is load-bearing"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION J — ARM-FILE RECONCILIATION (temperloop#1556).
#
# Every count this driver publishes is derived from the LEG state files,
# which are written once and never touched again. The ARM FILE is rewritten
# in place by the judge pass. On the first live batch that gap was
# load-bearing: judge-batch replaced 14 of 21 records per arm with bare
# error objects while this driver reported `replay_completion_rate: 1` and
# 21 records per arm off the intact legs. The summary read healthy over an
# arm file that was already destroyed, and the operator learned otherwise
# only when the report producer refused to render.
#
# J1 pins the reconciled case over a batch that carries genuinely
# UNJUDGEABLE legs (an integration-error record has no candidate model and
# no diff, so no judge could ever score it) — the exact input the live run
# had. J2 is the MUTATION PROOF: with the pre-fix judge substitution
# restored in a mirrored judge.sh the arm file IS corrupted, and the driver
# must say so rather than hand back a clean 1.0 over it.
# ═══════════════════════════════════════════════════════════════════════════

# A candidate runner that FAILS: replay.sh execute turns a non-zero runner
# exit into a `candidate-spawn` integration-error record — a real record, so
# the leg COMPLETES, but one no judge can ever score.
IE_STUB="$WORK/stub-integration-error.sh"
cat >"$IE_STUB" <<STUBEOF
#!/usr/bin/env bash
set -u
printf 'ie-stub %s\n' "\$1" >>"$CAND_LOG"
echo "vendor connection reset" >&2
exit 3
STUBEOF
chmod +x "$IE_STUB"

# J1 — a batch whose candidate arm is entirely integration-error records
#      still reconciles: every leg record this driver counted is in the arm
#      file it wrote, the judge pass does not degrade over rows it was never
#      able to judge, and the report producer still renders.
count
IE_OUT="$WORK/out-ie"; IE_STATE="$WORK/state-ie"
DRIVE_ARGS=(--corpus-file "$CORPUS_A" --repo-root "$REPO" --out-dir "$IE_OUT" --state-dir "$IE_STATE"
            --baseline-runner "bash $BASE_STUB" --candidate-runner "bash $IE_STUB"
            --judge-runner "bash $JUDGE_STUB" --confirm)
drive ""
[ "$RC" -eq 0 ] \
  || fail "J1: a batch whose only non-JUDGED rows were unjudgeable BY CONSTRUCTION must not be degraded, got $RC: $(jq -c '.degradations' <<<"$OUT") $(tail -c 400 "$WORK/last-stderr.txt")"
[ "$(jq -r '.legs.integration_error_n' <<<"$OUT")" = "2" ] \
  || fail "J1: expected 2 integration-error legs in the candidate arm, got: $(jq -c .legs <<<"$OUT")"
[ "$(jq -r '.reconciliation.reconciled' <<<"$OUT")" = "true" ] \
  || fail "J1: both arms should reconcile: $(jq -c .reconciliation <<<"$OUT")"
[ "$(jq -r '[.reconciliation.per_arm[] | select(.leg_records_counted_n == .arm_records_n)] | length' <<<"$OUT")" = "2" ] \
  || fail "J1: the arm files must carry exactly the leg records counted: $(jq -c .reconciliation <<<"$OUT")"
[ "$(jq -r '[.reconciliation.per_arm[] | .foreign_records_n] | add' <<<"$OUT")" = "0" ] \
  || fail "J1: no arm file line may be a non-record (foreign) object: $(jq -c .reconciliation <<<"$OUT")"
[ "$(jq -r '.completion.rate_is_over_a_reconciled_arm' <<<"$OUT")" = "true" ] \
  || fail "J1: the completion rate must be flagged as being over a reconciled arm: $(jq -c .completion <<<"$OUT")"
[ "$(jq -r '.judge.degraded' <<<"$OUT")" = "false" ] \
  || fail "J1: judge.degraded must not fire for a batch whose only failures were never-judgeable records: $(jq -c .judge <<<"$OUT")"
[ "$(jq -s '[.[] | select(.candidate.outcome == "integration-error")] | length' <"$IE_OUT/candidate.jsonl")" = "2" ] \
  || fail "J1: the candidate arm lost its integration-error records: $(cat "$IE_OUT/candidate.jsonl")"
prod_ie="$(cd "$REPO" && env MODEL_COMPARISON_REPORT_RECORDS_DIR="$IE_OUT" bash "$SCRIPTS_DIR/report-producers/model-comparison" 2>&1)"
case "$prod_ie" in
  skipped\ --*) fail "J1: the report producer skipped over the driver's own mixed arms — the whole-report loss this item exists to fix: $prod_ie" ;;
esac
[ "$(jq -r '.arms.candidate.compatibility.integration_error_n' <<<"$prod_ie")" = "2" ] \
  || fail "J1: the report must state the candidate arm's compatibility split: $(jq -c '.arms.candidate.compatibility' <<<"$prod_ie")"
ok "J1 an unjudgeable-by-construction arm reconciles, does not degrade the judge pass, and still renders a report with its compatibility split"

# J2 — MUTATION PROOF. Restore the pre-fix judge substitution in a mirrored
#      judge.sh: the arm file IS corrupted, and the driver must REPORT the
#      mismatch rather than hand back a clean completion rate over it.
count
MUT_J="$WORK/mut-reconcile"; mk_mirror "$MUT_J"
MUT_J_SUT="$MUT_J/workflows/scripts/model-comparison/batch.sh"
MUT_J_JUDGE="$MUT_J/workflows/scripts/model-comparison/judge.sh"
unlink_and_copy "$MUT_J_JUDGE"
mutate_file "$MUT_J_JUDGE" \
  '    if _je_unjudgeable_by_construction "$row_file"; then' \
  '    if false; then'
mutate_file "$MUT_J_JUDGE" \
  '    printf '"'"'%s\n'"'"' "$row_final" >>"$out_stream"
    if [ "$row_rc" -ne 0 ]; then degraded=1; n_degraded=$((n_degraded + 1)); fi' \
  '    printf '"'"'%s\n'"'"' "$row_out" >>"$out_stream"
    if [ "$row_rc" -ne 0 ]; then degraded=1; n_degraded=$((n_degraded + 1)); fi'
MUT_J_OUT="$WORK/out-mut-j"; MUT_J_STATE="$WORK/state-mut-j"
DRIVE_ARGS=(--corpus-file "$CORPUS_A" --repo-root "$REPO" --out-dir "$MUT_J_OUT" --state-dir "$MUT_J_STATE"
            --baseline-runner "bash $BASE_STUB" --candidate-runner "bash $IE_STUB"
            --judge-runner "bash $JUDGE_STUB" --confirm)
drive "$MUT_J_SUT"
[ "$(jq -s '[.[] | select((.candidate | type) == "object")] | length' <"$MUT_J_OUT/candidate.jsonl")" = "0" ] \
  || fail "J2: the mutation proof did not fire — the pre-fix judge should have replaced both integration-error records with bare verdict objects: $(cat "$MUT_J_OUT/candidate.jsonl")"
[ "$RC" -eq 4 ] \
  || fail "J2: a batch that wrote a corrupt arm file must exit degraded (4), got $RC"
[ "$(jq -r '.reconciliation.reconciled' <<<"$OUT")" = "false" ] \
  || fail "J2: the reconciliation must FAIL over the corrupted arm: $(jq -c .reconciliation <<<"$OUT")"
[ "$(jq -r '[.reconciliation.per_arm[] | select(.arm == "candidate") | .foreign_records_n] | add' <<<"$OUT")" = "2" ] \
  || fail "J2: the reconciliation must NAME the 2 non-record lines: $(jq -c .reconciliation <<<"$OUT")"
[ "$(jq -r '[.reconciliation.per_arm[] | select(.arm == "candidate") | .missing_n] | add' <<<"$OUT")" = "2" ] \
  || fail "J2: the reconciliation must name the 2 counted records now absent: $(jq -c .reconciliation <<<"$OUT")"
[ "$(jq -r '[.degradations[] | select(.kind == "arm_reconciliation_mismatch")] | length' <<<"$OUT")" = "1" ] \
  || fail "J2: the mismatch must be a NAMED degradation: $(jq -c .degradations <<<"$OUT")"
[ "$(jq -r '.outcome' <<<"$OUT")" = "BATCH_DEGRADED" ] \
  || fail "J2: a corrupt arm file must not report BATCH_COMPLETE, got: $(jq -r .outcome <<<"$OUT")"
[ "$(jq -r '.completion.replay_completion_rate' <<<"$OUT")" = "1" ] \
  || fail "J2: the leg-derived rate is still 1 (every leg produced a record) — that is precisely why the caveat is needed: $(jq -c .completion <<<"$OUT")"
[ "$(jq -r '.completion.rate_is_over_a_reconciled_arm' <<<"$OUT")" = "false" ] \
  || fail "J2: a 1.0 rate over a corrupt arm file must be flagged, not handed back clean: $(jq -c .completion <<<"$OUT")"
jq -e '.completion.rate_caveat | type == "string" and (length > 20)' <<<"$OUT" >/dev/null \
  || fail "J2: the caveat must be NAMED, never a bare flag: $(jq -c .completion <<<"$OUT")"
ok "J2 MUTATION PROOF: the pre-fix judge substitution corrupts the arm file, and the driver REPORTS the mismatch instead of a clean 1.0 completion rate over it"

fi

if run_group 5; then  # section K
# ═══════════════════════════════════════════════════════════════════════════
# SECTION K — THE CIRCUIT BREAKER (temperloop#1554).
#
# Section D pins that ONE leg's failure does not abort the batch. This section
# pins the opposite end of the same axis: when the SPAWN PATH itself has gone
# systemically unavailable, continuing is the worst available response. On the
# first live batch 14 records replayed over ~3.1h and then every remaining leg
# fast-failed in ~4-5s — 28 consecutive `candidate-spawn` integration errors,
# almost certainly a rate limit, hammered ~5s apart to the end of the corpus.
#
# Four properties, each measured rather than asserted:
#   K1/K2  a runner that fails unconditionally STOPS the batch at the
#          configured threshold, reports the un-attempted remainder BY COUNT,
#          and is distinguishable from a completed-but-degraded run (its own
#          outcome and its own exit code, not 4)
#   K3     the skipped legs are recorded NOT ATTEMPTED, never integration
#          errors — and a --retry-failed resume re-drives exactly them
#   K4     isolated failures BELOW the threshold still run to completion
#          (the continue-on-error default survives underneath the breaker)
#   K5     the streak keys on the STAGE: six consecutive integration errors
#          whose stage alternates never trip a threshold of 2, which a
#          stage-blind counter would have tripped on the second leg
#   K6     MUTATION PROOF — with the breaker disarmed the very same input runs
#          the whole corpus out and exits 0, which is the pre-fix behaviour
# ═══════════════════════════════════════════════════════════════════════════

CB_OUT="$WORK/out-cb"; CB_STATE="$WORK/state-cb"

# K1 — the batch STOPS at the threshold instead of running the corpus out.
count
: >"$CB_LOG"
DRIVE_ARGS=(--corpus-file "$CORPUS_CB" --repo-root "$REPO" --out-dir "$CB_OUT" --state-dir "$CB_STATE"
            --baseline-runner "bash $CB_STUB" --candidate-runner "bash $CB_STUB"
            --judge-runner "bash $JUDGE_STUB" --confirm)
drive "" MODEL_COMPARISON_BATCH_MAX_CONSECUTIVE_STAGE_ERRORS=2
cb_calls="$(wc -l <"$CB_LOG" | tr -d ' ')"
[ "$(jq -r '.legs.planned_n' <<<"$OUT")" = "8" ] || fail "K1: 4 records x 2 arms = 8 planned replays, got: $(jq -c .legs <<<"$OUT")"
[ "$cb_calls" = "2" ] \
  || fail "K1: the driver should have stopped after 2 consecutive same-stage integration errors, but invoked the runner $cb_calls times — it ran the corpus out"
[ "$(jq -r '.circuit_breaker.tripped' <<<"$OUT")" = "true" ] \
  || fail "K1: the circuit breaker must report itself tripped: $(jq -c .circuit_breaker <<<"$OUT")"
[ "$(jq -r '.circuit_breaker.stage' <<<"$OUT")" = "candidate-spawn" ] \
  || fail "K1: the breaker must NAME the stage that kept failing: $(jq -c .circuit_breaker <<<"$OUT")"
[ "$(jq -r '.circuit_breaker.threshold' <<<"$OUT")" = "2" ] \
  || fail "K1: the threshold must be the configured one: $(jq -c .circuit_breaker <<<"$OUT")"
[ "$(jq -r '.circuit_breaker.setting' <<<"$OUT")" = "MODEL_COMPARISON_BATCH_MAX_CONSECUTIVE_STAGE_ERRORS" ] \
  || fail "K1: the breaker must name the SETTING it reads, so the threshold is never a literal: $(jq -c .circuit_breaker <<<"$OUT")"
[ "$(jq -r '.judge.ran' <<<"$OUT")" = "false" ] \
  || fail "K1: the judge pass spawns through the same seam that just went unavailable and must be skipped: $(jq -c .judge <<<"$OUT")"
grep -qi 'circuit breaker' <<<"$(jq -r '.judge.reason' <<<"$OUT")" \
  || fail "K1: the judge skip must NAME the circuit breaker as its reason, never skip silently: $(jq -c .judge <<<"$OUT")"
ok "K1 a systemically unavailable runner stops the batch after $cb_calls legs instead of all 8, and the judge pass is skipped with a NAMED reason"

# K2 — the stop is DISTINGUISHABLE from a completed-but-degraded batch, and
#      says how much was never attempted.
count
[ "$RC" -eq 5 ] \
  || fail "K2: an early stop must have its own exit code (5), not the completed-but-degraded 4, got $RC: $(jq -c .degradations <<<"$OUT")"
[ "$(jq -r '.outcome' <<<"$OUT")" = "BATCH_STOPPED_EARLY" ] \
  || fail "K2: expected BATCH_STOPPED_EARLY, got: $(jq -r .outcome <<<"$OUT")"
[ "$(jq -r '.legs.not_attempted_n' <<<"$OUT")" = "6" ] \
  || fail "K2: 6 of the 8 planned legs were never attempted: $(jq -c .legs <<<"$OUT")"
[ "$(jq -r '.circuit_breaker.records_not_attempted_n' <<<"$OUT")" = "3" ] \
  || fail "K2: 3 whole corpus records were never attempted at all: $(jq -c .circuit_breaker <<<"$OUT")"
[ "$(jq -r '.circuit_breaker.not_attempted | length' <<<"$OUT")" = "6" ] \
  || fail "K2: every un-attempted leg must be NAMED with its arm and ref: $(jq -c .circuit_breaker <<<"$OUT")"
[ "$(jq -r '[.degradations[] | select(.kind == "circuit_breaker_tripped")] | length' <<<"$OUT")" = "1" ] \
  || fail "K2: the early stop must be a NAMED degradation: $(jq -c .degradations <<<"$OUT")"
[ "$(jq -r '[.degradations[] | select(.kind == "leg_failures")] | length' <<<"$OUT")" = "0" ] \
  || fail "K2: an un-attempted leg is not a failed leg — leg_failures must not fire: $(jq -c .degradations <<<"$OUT")"
[ "$(jq -r '.legs.failed_n' <<<"$OUT")" = "0" ] \
  || fail "K2: no leg FAILED here (both attempted legs produced records): $(jq -c .legs <<<"$OUT")"
[ "$(jq -r '.legs.integration_error_n' <<<"$OUT")" = "2" ] \
  || fail "K2: exactly the 2 attempted legs are integration errors: $(jq -c .legs <<<"$OUT")"
ok "K2 the early stop is its own outcome (BATCH_STOPPED_EARLY / exit 5), names 6 un-attempted legs across 3 never-attempted records, and is not dressed as a degraded-but-complete run"

# K3 — the skipped legs are NOT ATTEMPTED on disk, never integration errors,
#      and a --retry-failed resume re-drives exactly them.
count
cb_na="$(grep -l '"not-attempted"' "$CB_STATE"/legs/*/*.state.json 2>/dev/null | wc -l | tr -d ' ')"
cb_ie="$(grep -l '"integration-error"' "$CB_STATE"/legs/*/*.state.json 2>/dev/null | wc -l | tr -d ' ')"
[ "$cb_na" = "6" ] || fail "K3: expected 6 not-attempted leg states on disk, got $cb_na"
[ "$cb_ie" = "2" ] || fail "K3: expected exactly 2 integration-error leg states on disk, got $cb_ie"
[ ! -e "$CB_STATE/legs/baseline/002-pr-402.json" ] \
  || fail "K3: an un-attempted leg must leave NO leg record — it produced nothing"
[ "$(lines "$CB_OUT/candidate.jsonl")" = "1" ] \
  || fail "K3: only the one attempted candidate leg may reach the arm file: $(cat "$CB_OUT/candidate.jsonl")"
: >"$CAND_LOG"
DRIVE_ARGS=(--corpus-file "$CORPUS_CB" --repo-root "$REPO" --out-dir "$CB_OUT" --state-dir "$CB_STATE"
            --baseline-runner "bash $BASE_STUB" --candidate-runner "bash $CAND_STUB"
            --judge-runner "bash $JUDGE_STUB" --retry-failed --confirm)
drive "" MODEL_COMPARISON_BATCH_MAX_CONSECUTIVE_STAGE_ERRORS=2
[ "$RC" -eq 0 ] || fail "K3: the resumed batch should complete, got $RC: $(jq -c '.degradations' <<<"$OUT") $(tail -c 400 "$WORK/last-stderr.txt")"
[ "$(wc -l <"$CAND_LOG" | tr -d ' ')" = "6" ] \
  || fail "K3: the resume must re-drive exactly the 6 un-attempted legs, got $(wc -l <"$CAND_LOG"): $(cat "$CAND_LOG")"
[ "$(jq -r '.legs.not_attempted_n' <<<"$OUT")" = "0" ] \
  || fail "K3: nothing should remain un-attempted after the resume: $(jq -c .legs <<<"$OUT")"
[ "$(jq -r '.legs.resumed_n' <<<"$OUT")" = "2" ] \
  || fail "K3: the 2 legs that DID produce integration-error records must be resumed, not re-spent: $(jq -c .legs <<<"$OUT")"
[ "$(jq -r '.circuit_breaker.tripped' <<<"$OUT")" = "false" ] \
  || fail "K3: the resumed run must not inherit the previous run's tripped breaker: $(jq -c .circuit_breaker <<<"$OUT")"
[ "$(jq -r '.outcome' <<<"$OUT")" = "BATCH_COMPLETE" ] \
  || fail "K3: the resumed run exhausted the corpus and must say so: $(jq -r .outcome <<<"$OUT")"
[ "$(lines "$CB_OUT/candidate.jsonl")" = "4" ] \
  || fail "K3: all 4 records must reach the candidate arm after the resume"
ok "K3 the breaker's skipped legs are recorded not-attempted (not integration errors), and a --retry-failed resume re-drives exactly those 6 without re-spending the 2 that produced records"

# K4 — an isolated failure BELOW the threshold still runs to completion: the
#      continue-on-error default of section D survives underneath the breaker.
count
CORPUS_SCATTER="$WORK/corpus-scatter.jsonl"
{ mk_corpus_line 501 eligible "$BASE"
  mk_corpus_line 502 eligible "$BASE"
  mk_corpus_line 503 eligible "$BASE"; } >"$CORPUS_SCATTER"
SCATTER_LOG="$WORK/scatter-calls.log"; : >"$SCATTER_LOG"
SCATTER_STUB="$WORK/stub-scatter.sh"
cat >"$SCATTER_STUB" <<STUBEOF
#!/usr/bin/env bash
set -u
printf 'scatter %s\n' "\$1" >>"$SCATTER_LOG"
n="\$(wc -l <"$SCATTER_LOG" | tr -d ' ')"
if [ \$(( n % 2 )) -eq 1 ]; then
  echo "API error 500: one-off upstream blip" >&2
  exit 1
fi
wt="\$2"
cp "$TRUTH_PY" "\$wt/workflows/scripts/drain/scan_stub.py"
mkdir -p "\$wt/workflows/scripts/drain/tests"
printf '#!/usr/bin/env bash\necho candidate-test\n' >"\$wt/workflows/scripts/drain/tests/test_scan_stub.sh"
jq -cn '{type:"result", subtype:"success", is_error:false, duration_ms:4242,
  modelUsage:{"recorded-scatter-model":{inputTokens:1200, outputTokens:340,
                     cacheReadInputTokens:9000, cacheCreationInputTokens:120,
                     provider:"firstParty"}}}'
STUBEOF
chmod +x "$SCATTER_STUB"
SC_OUT="$WORK/out-scatter"; SC_STATE="$WORK/state-scatter"
DRIVE_ARGS=(--corpus-file "$CORPUS_SCATTER" --repo-root "$REPO" --out-dir "$SC_OUT" --state-dir "$SC_STATE"
            --baseline-runner "bash $SCATTER_STUB" --candidate-runner "bash $SCATTER_STUB" --confirm)
drive "" MODEL_COMPARISON_BATCH_MAX_CONSECUTIVE_STAGE_ERRORS=2
[ "$(wc -l <"$SCATTER_LOG" | tr -d ' ')" = "6" ] \
  || fail "K4: every one of the 6 legs must still be attempted when no streak reaches the threshold, got $(wc -l <"$SCATTER_LOG")"
[ "$(jq -r '.circuit_breaker.tripped' <<<"$OUT")" = "false" ] \
  || fail "K4: alternating failure/success must never trip the breaker — a success resets the streak: $(jq -c .circuit_breaker <<<"$OUT")"
[ "$(jq -r '.legs.not_attempted_n' <<<"$OUT")" = "0" ] \
  || fail "K4: nothing may be skipped below the threshold: $(jq -c .legs <<<"$OUT")"
[ "$(jq -r '.legs.integration_error_n' <<<"$OUT")" = "3" ] \
  || fail "K4: the 3 isolated failures must still be recorded as integration errors: $(jq -c .legs <<<"$OUT")"
[ "$(jq -r '.legs.completed_n' <<<"$OUT")" = "6" ] \
  || fail "K4: the batch ran to completion, got: $(jq -c .legs <<<"$OUT")"
[ "$RC" -eq 0 ] \
  || fail "K4: a batch of isolated failures below the threshold is not an early stop, got $RC: $(jq -c .degradations <<<"$OUT")"
ok "K4 isolated failures below the threshold still run the corpus to completion — a success resets the streak and the continue-on-error default is preserved"

# K5 — the streak keys on the STAGE. Six CONSECUTIVE integration errors whose
#      stage alternates (candidate-spawn / envelope-parse) never trip a
#      threshold of 2; a stage-blind counter would have stopped at leg 2.
count
MIXED_LOG="$WORK/mixed-calls.log"; : >"$MIXED_LOG"
MIXED_STUB="$WORK/stub-mixed-stage.sh"
cat >"$MIXED_STUB" <<STUBEOF
#!/usr/bin/env bash
set -u
printf 'mixed %s\n' "\$1" >>"$MIXED_LOG"
n="\$(wc -l <"$MIXED_LOG" | tr -d ' ')"
if [ \$(( n % 2 )) -eq 1 ]; then
  echo "API error 429: rate limit exceeded" >&2
  exit 1
fi
printf 'this is not a JSON envelope at all\n'
exit 0
STUBEOF
chmod +x "$MIXED_STUB"
MX_OUT="$WORK/out-mixed"; MX_STATE="$WORK/state-mixed"
DRIVE_ARGS=(--corpus-file "$CORPUS_SCATTER" --repo-root "$REPO" --out-dir "$MX_OUT" --state-dir "$MX_STATE"
            --baseline-runner "bash $MIXED_STUB" --candidate-runner "bash $MIXED_STUB" --confirm)
drive "" MODEL_COMPARISON_BATCH_MAX_CONSECUTIVE_STAGE_ERRORS=2
[ "$(wc -l <"$MIXED_LOG" | tr -d ' ')" = "6" ] \
  || fail "K5: all 6 legs must run — no STAGE ever repeated consecutively, got $(wc -l <"$MIXED_LOG")"
[ "$(jq -r '.circuit_breaker.tripped' <<<"$OUT")" = "false" ] \
  || fail "K5: a stage-blind counter would have tripped here; the breaker must key on the stage: $(jq -c .circuit_breaker <<<"$OUT")"
[ "$(jq -r '.legs.integration_error_n' <<<"$OUT")" = "6" ] \
  || fail "K5: all 6 legs are integration errors, just not of the same stage: $(jq -c .legs <<<"$OUT")"
# The stub alternates on its own call index, so the EXECUTED sequence really is
# spawn, parse, spawn, parse, spawn, parse. Assert that shape rather than
# assume it: if the fixture ever stopped alternating leg by leg, K5 would be a
# tautology. The sequence is reconstructed from the records' OWN recorded
# execution order (temperloop#1571's `execution_order.record_index` +
# `.position`), never from the arm names — since counterbalancing the arm order
# means "baseline" is no longer a synonym for "ran first".
mx_seq="$(jq -s -r 'sort_by(.execution_order.record_index, .execution_order.position)
                    | map(.candidate.integration_error.stage) | join(",")' \
            "$MX_OUT/baseline.jsonl" "$MX_OUT/candidate.jsonl" 2>/dev/null)"
[ "$mx_seq" = "candidate-spawn,envelope-parse,candidate-spawn,envelope-parse,candidate-spawn,envelope-parse" ] \
  || fail "K5: the fixture did not actually alternate stages leg by leg, so this proves nothing: executed stage sequence = $mx_seq"
ok "K5 six CONSECUTIVE integration errors of ALTERNATING stage (${mx_seq}) never trip a threshold of 2 — the streak keys on the STAGE, which a stage-blind counter would have stopped at leg 2"

# K6 — MUTATION PROOF. Disarm the breaker (its own documented 0 value) and the
#      very same unconditionally-failing runner runs the whole corpus out and
#      exits 0 — which is exactly the pre-#1554 behaviour K1/K2 exist to end.
count
CB0_OUT="$WORK/out-cb-disarmed"; CB0_STATE="$WORK/state-cb-disarmed"
: >"$CB_LOG"
DRIVE_ARGS=(--corpus-file "$CORPUS_CB" --repo-root "$REPO" --out-dir "$CB0_OUT" --state-dir "$CB0_STATE"
            --baseline-runner "bash $CB_STUB" --candidate-runner "bash $CB_STUB" --confirm)
drive "" MODEL_COMPARISON_BATCH_MAX_CONSECUTIVE_STAGE_ERRORS=0
cb0_calls="$(wc -l <"$CB_LOG" | tr -d ' ')"
[ "$cb0_calls" = "8" ] \
  || fail "K6: the mutation proof did not fire — with the breaker disarmed all 8 legs should have been hammered, got $cb0_calls"
[ "$(jq -r '.circuit_breaker.armed' <<<"$OUT")" = "false" ] \
  || fail "K6: a threshold of 0 must report the breaker as DISARMED, never silently absent: $(jq -c .circuit_breaker <<<"$OUT")"
[ "$RC" -eq 0 ] \
  || fail "K6: the pre-fix shape reported a clean exit over 8 consecutive integration errors; got $RC"
[ "$(jq -r '.legs.not_attempted_n' <<<"$OUT")" = "0" ] \
  || fail "K6: a disarmed breaker skips nothing: $(jq -c .legs <<<"$OUT")"
ok "K6 MUTATION PROOF: with the breaker disarmed the same unavailable runner is hammered for all $cb0_calls legs and the run exits 0 — K1/K2's stop is a measurement, not a restatement"

fi

if run_group 6; then  # sections S, M
# ═══════════════════════════════════════════════════════════════════════════
# SECTION S — PROJECTED vs OBSERVED SPEND (temperloop#1555).
#
# The gate PROJECTS a batch's cost from a per-replay estimate; the batch then
# INCURS a real one. Until #1555 nothing ever put the two side by side, so a
# projection that was 1.49x low across a whole live run could only be caught
# by a human summing the raw attribution lake by hand. This section drives a
# real batch and asserts the summary reconciles the two — and, just as
# importantly, that a wrong PROJECTION never degrades a batch that ran fine.
#
# The lake is pinned EMPTY for this section so the gate is deterministically
# on its configured-literal arm: earlier sections have been spending into
# $LAKE, and a derivation that had picked those records up would make the
# drift here a function of test ordering rather than of the fixture.
# ═══════════════════════════════════════════════════════════════════════════
SPEND_LAKE="$WORK/lake-spend-section"; mkdir -p "$SPEND_LAKE"
SPEND_OUT="$WORK/out-spend"; SPEND_STATE="$WORK/state-spend"
: >"$CAND_LOG"
DRIVE_ARGS=(--corpus-file "$CORPUS_A" --repo-root "$REPO" --out-dir "$SPEND_OUT" --state-dir "$SPEND_STATE"
            --baseline-runner "bash $BASE_STUB" --candidate-runner "bash $CAND_STUB" --confirm)
drive "" MODEL_USAGE_RAW_DIR="$SPEND_LAKE"
[ "$RC" -eq 0 ] || fail "S0: the spend-reconciliation batch should exit 0, got $RC: $OUT / $(head -c 600 "$WORK/last-stderr.txt")"
SPEND_OUTPUT="$OUT"

# S1 — the summary STATES projected vs observed for this run, in the gate's
#      own unit, and the projected side is the gate's own figure (this driver
#      still computes no estimate of its own).
count
sr() { jq -r ".spend_reconciliation.$1" <<<"$SPEND_OUTPUT"; }
[ "$(jq -r 'has("spend_reconciliation")' <<<"$SPEND_OUTPUT")" = "true" ] \
  || fail "S1: the batch summary carries no spend_reconciliation block at all: $SPEND_OUTPUT"
[ "$(sr projected_total)" = "$(jq -r '.preflight.estimated_cost' <<<"$SPEND_OUTPUT")" ] \
  || fail "S1: projected_total is not the gate's own estimate: $(jq -c .spend_reconciliation <<<"$SPEND_OUTPUT")"
[ "$(sr unit)" = "$(jq -r '.preflight.cost_basis' <<<"$SPEND_OUTPUT")" ] \
  || fail "S1: the reconciliation is not denominated in the unit the gate authorized the batch in: $(jq -c .spend_reconciliation <<<"$SPEND_OUTPUT")"
[ "$(sr unit)" = "cost-weighted-token-units" ] \
  || fail "S1: expected the shared cost-weighted unit, got $(sr unit)"
case "$(sr observed_total)" in ''|null|*[!0-9]*) fail "S1: observed_total is not an integer: $(jq -c .spend_reconciliation <<<"$SPEND_OUTPUT")" ;; esac
ok "S1 the batch summary states PROJECTED vs OBSERVED total spend for the run, in the gate's own unit"

# S2 — the OBSERVED figure is a real measurement of these records, not a
#      restatement of the projection. The recorded envelope every stub replays
#      is input 1200 / output 340 / cache_read 9000 / cache_creation 120,
#      which under the SPEND_WEIGHT_* defaults (1 / 5 / 0.1 / 1.25) is
#      1200 + 1700 + 900 + 150 = 3950 cost-weighted units per executed replay.
#      Pinning that number pins the weighting EXPRESSION, which is the thing
#      that has to stay byte-identical across the gate, this driver and the
#      report producer.
count
[ "$(sr observed_costed_replays_n)" = "4" ] \
  || fail "S2: expected 4 costed executed replays (2 records x 2 arms), got $(sr observed_costed_replays_n)"
[ "$(sr observed_uncosted_replays_n)" = "0" ] \
  || fail "S2: no fixture record is missing a token block, so uncosted should be 0, got $(sr observed_uncosted_replays_n)"
[ "$(sr observed_mean_per_replay)" = "3950" ] \
  || fail "S2: the observed per-replay cost is not the SPEND_WEIGHT_* multiply-add over the recorded envelope (expected 3950), got $(sr observed_mean_per_replay)"
[ "$(sr observed_total)" = "15800" ] \
  || fail "S2: observed_total should be 4 x 3950 = 15800, got $(sr observed_total)"
[ "$(sr coverage_complete)" = "true" ] \
  || fail "S2: every projected replay produced a costed record, so coverage should be complete: $(jq -c .spend_reconciliation <<<"$SPEND_OUTPUT")"
ok "S2 the OBSERVED total is measured off this run's own records (4 x 3950 = 15800), not copied from the projection"

# S3 — the drift is quantified AND flagged. With the gate on its literal arm
#      the projection is orders of magnitude above what these recorded stubs
#      actually cost, so this is exactly the "the estimate is stale" signal
#      the alert exists to raise.
count
[ "$(sr drift_alert)" = "true" ] \
  || fail "S3: a projection this far from outturn must raise drift_alert: $(jq -c .spend_reconciliation <<<"$SPEND_OUTPUT")"
[ "$(sr alert_setting)" = "MODEL_COMPARISON_SPEND_DRIFT_ALERT_PCT" ] \
  || fail "S3: the alert threshold must be a NAMED setting, got $(sr alert_setting)"
case "$(sr drift_pct)" in ''|null) fail "S3: drift_pct was not computed: $(jq -c .spend_reconciliation <<<"$SPEND_OUTPUT")" ;; esac
case "$(sr ratio_observed_over_projected)" in ''|null) fail "S3: the observed/projected ratio was not computed" ;; esac
grep -q 'SPEND DRIFT' "$WORK/last-stderr.txt" \
  || fail "S3: the drift was flagged in the summary but never surfaced on stderr: $(tail -c 400 "$WORK/last-stderr.txt")"
ok "S3 the projected-vs-observed drift is quantified, flagged, and surfaced on stderr"

# S4 — AND YET THE BATCH IS NOT DEGRADED. A wrong projection is a fact about
#      the ESTIMATE, not a defect in the run that just completed; turning a
#      clean BATCH_COMPLETE into a BATCH_DEGRADED over a stale forecast would
#      report the wrong thing about the wrong artifact. This is the assertion
#      that keeps the alert from being quietly promoted into a gate.
count
[ "$(jq -r '.outcome' <<<"$SPEND_OUTPUT")" = "BATCH_COMPLETE" ] \
  || fail "S4: a spend-drift alert must not degrade an otherwise clean batch, got $(jq -r '.outcome' <<<"$SPEND_OUTPUT")"
[ "$(jq -r '[.degradations[].kind] | map(select(test("spend"))) | length' <<<"$SPEND_OUTPUT")" = "0" ] \
  || fail "S4: the drift was recorded as a degradation: $(jq -c .degradations <<<"$SPEND_OUTPUT")"
ok "S4 a spend-drift alert is reported without degrading an otherwise clean batch"

# S5 — MUTATION PROOF for the threshold: at a threshold of 0 the alert is
#      DISABLED (its own documented disable value) while every reconciliation
#      figure is still published — so S3's alert is a measurement of the
#      threshold, not something the block raises unconditionally.
count
SPEND0_LAKE="$WORK/lake-spend-disabled"; mkdir -p "$SPEND0_LAKE"
SPEND0_OUT="$WORK/out-spend-off"; SPEND0_STATE="$WORK/state-spend-off"
: >"$CAND_LOG"
DRIVE_ARGS=(--corpus-file "$CORPUS_A" --repo-root "$REPO" --out-dir "$SPEND0_OUT" --state-dir "$SPEND0_STATE"
            --baseline-runner "bash $BASE_STUB" --candidate-runner "bash $CAND_STUB" --confirm)
drive "" MODEL_USAGE_RAW_DIR="$SPEND0_LAKE" MODEL_COMPARISON_SPEND_DRIFT_ALERT_PCT=0
[ "$RC" -eq 0 ] || fail "S5: the threshold-0 batch should exit 0, got $RC: $OUT"
[ "$(jq -r '.spend_reconciliation.drift_alert' <<<"$OUT")" = "false" ] \
  || fail "S5: the mutation proof did not fire — a threshold of 0 must disable the alert: $(jq -c .spend_reconciliation <<<"$OUT")"
[ "$(jq -r '.spend_reconciliation.observed_total' <<<"$OUT")" = "15800" ] \
  || fail "S5: disabling the ALERT must not suppress the reconciliation FIGURES: $(jq -c .spend_reconciliation <<<"$OUT")"
ok "S5 MUTATION PROOF: a threshold of 0 disables the alert and keeps every figure — S3's alert is threshold-driven, not unconditional"

# S6 — the operator CONFIRMATION line carries the provenance of the number it
#      is asking about. This is the sentence a human actually reads before
#      authorizing spend, and a bare point estimate is exactly what #1555
#      found to be misleading.
count
CONF_OUT="$WORK/out-conf"; CONF_STATE="$WORK/state-conf"
DRIVE_ARGS=(--corpus-file "$CORPUS_A" --repo-root "$REPO" --out-dir "$CONF_OUT" --state-dir "$CONF_STATE"
            --baseline-runner "bash $BASE_STUB" --candidate-runner "bash $CAND_STUB")
drive "" MODEL_USAGE_RAW_DIR="$SPEND_LAKE"
[ "$RC" -eq 3 ] || fail "S6: an unconfirmed batch should stop with exit 3, got $RC: $OUT"
conf_detail="$(jq -r '.detail' <<<"$OUT")"
case "$conf_detail" in
  *UNMEASURED*) : ;;
  *) fail "S6: the confirmation line does not say the per-replay figure is unmeasured on this host: $conf_detail" ;;
esac
ok "S6 the operator confirmation line names where the per-replay figure came from"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION M — COUNTERBALANCED ARM ORDER (temperloop#1571).
#
# Until this item the driver ran the arms in ONE fixed order on every record —
# baseline first, candidate second — so ARM was perfectly confounded with
# EXECUTION POSITION and no N could separate them. The K#1262 A/A validation
# run, whose true arm effect is ZERO by construction, still showed a
# consistent second-arm advantage; the mechanism is an open question, and
# nothing here asserts one. Balancing the order removes the confound whatever
# the cause.
#
# Five properties, each MEASURED over a real 6-record fixture batch:
#   M1  the split is ~half and half, and it is a RULE rather than a coin flip:
#       the baseline arm runs first on exactly 3 of 6 records
#   M2  every leg carries its EXECUTION POSITION, and the baseline arm's
#       positions are no longer all 1 — which is the confound itself, gone
#   M3  the assignment is REPRODUCIBLE from the recorded rule + seed alone
#       (re-derived here from those two fields), and a resume reproduces it
#       without re-spending a leg
#   M4  MUTATION PROOF — a driver reverted to fixed order fails the very same
#       predicate M1/M2 pass, so those checks are a measurement rather than a
#       restatement of what the code happens to do
#   M5  no UNAUDITED fixed-order arm loop can be reintroduced silently
# ═══════════════════════════════════════════════════════════════════════════

# CORPUS_ORDER — 6 eligible records. Even N so a correct counterbalance is an
# EXACT 3/3 rather than a near miss, which makes a wrong split unmissable.
CORPUS_ORDER="$WORK/corpus-order.jsonl"
{ mk_corpus_line 601 eligible "$BASE"
  mk_corpus_line 602 eligible "$BASE"
  mk_corpus_line 603 eligible "$BASE"
  mk_corpus_line 604 eligible "$BASE"
  mk_corpus_line 605 eligible "$BASE"
  mk_corpus_line 606 eligible "$BASE"; } >"$CORPUS_ORDER"

# assert_counterbalanced <summary-json> <out-dir> — THE predicate M1/M2 assert
# and M4 mutates against. Returns 0 when arm order is genuinely counterbalanced
# and every leg carries a position; non-zero, with a reason on stdout, when it
# is not. Written as one reusable predicate on purpose: a mutation proof that
# runs a DIFFERENT check than the passing test proves nothing about that test.
assert_counterbalanced() {
  local summary="$1" outdir="$2" n bf cf cb reason a
  # `tostring`, never the `//` operator: jq treats a genuine `false` (and a
  # genuine 0) as absent, so `// "null"` would report a driver that correctly
  # said `counterbalanced: false` as if the field were missing — and M4's
  # failure reason would name the wrong defect.
  n="$(jq -r '.arm_order.records_n | tostring' <<<"$summary" 2>/dev/null)"
  bf="$(jq -r '.arm_order.baseline_first_n | tostring' <<<"$summary" 2>/dev/null)"
  cf="$(jq -r '.arm_order.candidate_first_n | tostring' <<<"$summary" 2>/dev/null)"
  cb="$(jq -r '.arm_order.counterbalanced | tostring' <<<"$summary" 2>/dev/null)"
  [ "$cb" = "true" ] || { echo "arm_order.counterbalanced is '$cb', not true"; return 1; }
  [ "$n" = "6" ] || { echo "arm_order.records_n is '$n', not 6"; return 1; }
  [ "$bf" = "3" ] || { echo "the baseline arm ran first on $bf of 6 records, not 3 — the split is not half and half"; return 1; }
  [ "$cf" = "3" ] || { echo "the candidate arm ran first on $cf of 6 records, not 3"; return 1; }
  # THE CONFOUND ITSELF: under the old fixed order every baseline leg was also
  # a first leg. Counterbalanced, the baseline arm must hold BOTH positions.
  for a in baseline candidate; do
    reason="$(jq -s -r --arg arm "$a" '
      [.[] | .execution_order.position] as $pos
      | if ($pos | length) != 6 then "the \($arm) arm has \($pos | length) positioned leg(s), not 6"
        elif ($pos | map(select(. == 1)) | length) != 3 then "the \($arm) arm ran FIRST on \($pos | map(select(. == 1)) | length) records, not 3 — arm is still a proxy for position"
        elif ($pos | map(select(. == 2)) | length) != 3 then "the \($arm) arm ran SECOND on \($pos | map(select(. == 2)) | length) records, not 3"
        else "" end' <"$outdir/$a.jsonl" 2>/dev/null)"
    [ -z "$reason" ] || { echo "$reason"; return 1; }
  done
  return 0
}

ORD_OUT="$WORK/out-order"; ORD_STATE="$WORK/state-order"
: >"$CAND_LOG"
DRIVE_ARGS=(--corpus-file "$CORPUS_ORDER" --repo-root "$REPO" --out-dir "$ORD_OUT" --state-dir "$ORD_STATE"
            --baseline-runner "bash $BASE_STUB" --candidate-runner "bash $CAND_STUB" --confirm)
drive ""
ORD_OUTPUT="$OUT"
[ "$RC" -eq 0 ] || fail "M-setup: the 6-record counterbalance batch should exit 0, got $RC: $(head -c 600 "$WORK/last-stderr.txt")"

# M1 — the split is an exact 3/3, and it is stated in the summary rather than
#      left for a reader to infer from the leg records.
count
ord_reason="$(assert_counterbalanced "$ORD_OUTPUT" "$ORD_OUT")" \
  || fail "M1: the batch was not counterbalanced: $ord_reason / $(jq -c .arm_order <<<"$ORD_OUTPUT")"
[ "$(jq -r '.arm_order.rule' <<<"$ORD_OUTPUT")" = "counterbalanced-by-record-index-v1" ] \
  || fail "M1: the summary must NAME the rule it counterbalanced under: $(jq -c .arm_order <<<"$ORD_OUTPUT")"
jq -e '.arm_order.balance_detail | type == "string" and (length > 40)' <<<"$ORD_OUTPUT" >/dev/null \
  || fail "M1: the realized balance must be STATED, never a bare flag: $(jq -c .arm_order <<<"$ORD_OUTPUT")"
[ "$(jq -r '[.arm_order.per_record[].first_arm] | join(",")' <<<"$ORD_OUTPUT")" \
  = "baseline,candidate,baseline,candidate,baseline,candidate" ] \
  || fail "M1: the per-record assignment is not the alternating rule: $(jq -c '[.arm_order.per_record[].first_arm]' <<<"$ORD_OUTPUT")"
ok "M1 over 6 records the baseline arm runs FIRST on exactly 3 and SECOND on 3 — a rule-guaranteed half-and-half split, named in the summary"

# M2 — the position rides on the LEG RECORD, which is what the report producer
#      reads. A split that never reached the records would be unmeasurable
#      downstream, so this asserts the field travels with the measurement.
count
[ "$(jq -s -r 'map(.execution_order.position) | sort | join(",")' <"$ORD_OUT/baseline.jsonl")" \
  = "1,1,1,2,2,2" ] \
  || fail "M2: the baseline arm's recorded positions are not 3x first / 3x second: $(jq -s -c 'map(.execution_order.position)' <"$ORD_OUT/baseline.jsonl")"
# Within EVERY record the two arms hold DIFFERENT positions, and the per-leg
# field agrees with the summary's own per-record ledger — the two surfaces
# cannot disagree about which arm ran first.
ord_i=1
while [ "$ord_i" -le 6 ]; do
  pos_b="$(jq -r --argjson i "$ord_i" 'select(.execution_order.record_index == $i) | .execution_order.position' <"$ORD_OUT/baseline.jsonl")"
  pos_c="$(jq -r --argjson i "$ord_i" 'select(.execution_order.record_index == $i) | .execution_order.position' <"$ORD_OUT/candidate.jsonl")"
  led_b="$(jq -r --argjson i "$ord_i" '.arm_order.per_record[] | select(.record_index == $i) | .positions.baseline' <<<"$ORD_OUTPUT")"
  led_c="$(jq -r --argjson i "$ord_i" '.arm_order.per_record[] | select(.record_index == $i) | .positions.candidate' <<<"$ORD_OUTPUT")"
  [ "$pos_b" != "$pos_c" ] \
    || fail "M2: record $ord_i has both arms at position $pos_b — the two legs of a pair cannot share a position"
  { [ "$pos_b" = "$led_b" ] && [ "$pos_c" = "$led_c" ]; } \
    || fail "M2: record $ord_i's legs (baseline=$pos_b candidate=$pos_c) disagree with the summary ledger (baseline=$led_b candidate=$led_c)"
  ord_i=$((ord_i + 1))
done
jq -s -e 'all(.[].execution_order.basis; type == "string" and (length > 40))' <"$ORD_OUT/candidate.jsonl" >/dev/null \
  || fail "M2: every leg record must carry a stated basis for its position, never a bare number"
ok "M2 every leg record carries its EXECUTION POSITION, the two arms differ within each record, and the per-leg field agrees with the summary ledger"

# M3 — REPRODUCIBILITY, proved two ways: the recorded rule+seed re-derive the
#      assignment here with no reference to the driver, and a resume reproduces
#      it without re-spending a single leg.
count
ord_seed="$(jq -r '.arm_order.seed' <<<"$ORD_OUTPUT")"
case "$ord_seed" in ''|*[!0-9]*) fail "M3: the summary must record an integer seed, got '$ord_seed'" ;; esac
ord_i=1
while [ "$ord_i" -le 6 ]; do
  # The published rule, re-applied by hand: baseline first iff
  # ((record_index + seed) % 2) == 1.
  if [ $(( (ord_i + ord_seed) % 2 )) -eq 1 ]; then expect_first=baseline; else expect_first=candidate; fi
  got_first="$(jq -r --argjson i "$ord_i" '.arm_order.per_record[] | select(.record_index == $i) | .first_arm' <<<"$ORD_OUTPUT")"
  [ "$got_first" = "$expect_first" ] \
    || fail "M3: the recorded rule+seed do not reproduce the recorded assignment at record $ord_i (rule says $expect_first, summary says $got_first)"
  ord_i=$((ord_i + 1))
done
ord_calls_before="$(wc -l <"$CAND_LOG" | tr -d ' ')"
drive ""
[ "$(wc -l <"$CAND_LOG" | tr -d ' ')" = "$ord_calls_before" ] \
  || fail "M3: the resume re-spent legs — reproducibility must not cost a re-run"
[ "$(jq -c '.arm_order.per_record' <<<"$OUT")" = "$(jq -c '.arm_order.per_record' <<<"$ORD_OUTPUT")" ] \
  || fail "M3: a resume assigned a DIFFERENT arm order: $(jq -c '.arm_order.per_record' <<<"$OUT")"
ok "M3 the recorded rule+seed re-derive the assignment independently, and a resume reproduces it byte-for-byte with 0 legs re-spent"

# M4 — MUTATION PROOF. Revert the order rule to the pre-#1571 fixed order in a
#      throwaway mirror and the SAME predicate M1/M2 pass must now FAIL —
#      otherwise those checks assert nothing about counterbalancing.
count
MUT_M="$WORK/mut-order"; mk_mirror "$MUT_M"
MUT_M_SUT="$MUT_M/workflows/scripts/model-comparison/batch.sh"
unlink_and_copy "$MUT_M_SUT"
mutate_file "$MUT_M_SUT" \
  '    *) printf '"'"'%s %s'"'"' "$BATCH_ARM_CANDIDATE" "$BATCH_ARM_BASELINE" ;;' \
  '    *) printf '"'"'%s %s'"'"' "$BATCH_ARM_BASELINE" "$BATCH_ARM_CANDIDATE" ;;'
MUT_M_OUT="$WORK/out-mut-m"; MUT_M_STATE="$WORK/state-mut-m"
DRIVE_ARGS=(--corpus-file "$CORPUS_ORDER" --repo-root "$REPO" --out-dir "$MUT_M_OUT" --state-dir "$MUT_M_STATE"
            --baseline-runner "bash $BASE_STUB" --candidate-runner "bash $CAND_STUB" --confirm)
drive "$MUT_M_SUT"
[ "$RC" -eq 0 ] || fail "M4: the fixed-order mutant should still run to completion (that is the point — it looks fine), got $RC"
if mut_m_reason="$(assert_counterbalanced "$OUT" "$MUT_M_OUT")"; then
  fail "M4: the mutation proof did not fire — a FIXED-order driver passed the counterbalance predicate, so M1/M2 prove nothing: $(jq -c .arm_order <<<"$OUT")"
fi
[ "$(jq -r '.arm_order.baseline_first_n' <<<"$OUT")" = "6" ] \
  || fail "M4: the fixed-order mutant should run the baseline first on all 6 records: $(jq -c .arm_order <<<"$OUT")"
[ "$(jq -s -r 'map(.execution_order.position) | unique | join(",")' <"$MUT_M_OUT/baseline.jsonl")" = "1" ] \
  || fail "M4: under a fixed order every baseline leg must sit at position 1 — that IS the confound"
[ "$(jq -r '.arm_order.counterbalanced' <<<"$OUT")" = "false" ] \
  || fail "M4: a fixed-order run must REPORT itself as not counterbalanced rather than stay silent: $(jq -c .arm_order <<<"$OUT")"
case "$(jq -r '.arm_order.balance_detail' <<<"$OUT")" in
  *CONFOUNDED*) : ;;
  *) fail "M4: a fixed-order run must NAME the confound in its summary: $(jq -r '.arm_order.balance_detail' <<<"$OUT")" ;;
esac
ok "M4 MUTATION PROOF: reverting to fixed order FAILS the same predicate M1/M2 pass ($mut_m_reason) and the summary says CONFOUNDED — the counterbalance checks are a measurement"

# M5 — no unaudited fixed-order arm loop can be reintroduced silently. Only the
#      EXECUTE loop's order can confound a result; every other arm loop in the
#      driver does per-arm bookkeeping over already-terminal state and carries
#      an ARM-ORDER AUDIT comment saying so. This check is what makes that a
#      structural property rather than a convention someone remembers.
count
m5_unaudited=""
while IFS=: read -r lineno _; do
  [ -n "$lineno" ] || continue
  # counterbalanced execute loop → fine; otherwise an ARM-ORDER AUDIT marker
  # must appear in the 8 lines above it.
  if sed -n "${lineno}p" "$SUT" | grep 'arm_first' >/dev/null; then continue; fi
  if sed -n "$(( lineno > 8 ? lineno - 8 : 1 )),$(( lineno - 1 ))p" "$SUT" | grep 'ARM-ORDER AUDIT' >/dev/null; then continue; fi
  m5_unaudited="$m5_unaudited $lineno"
done <<EOF
$(grep -n '^[[:space:]]*for arm in ' "$SUT")
EOF
[ -z "$m5_unaudited" ] \
  || fail "M5: fixed-order arm loop(s) at line(s)$m5_unaudited carry no ARM-ORDER AUDIT marker — every arm loop must be either the counterbalanced execute loop or explicitly audited as executing nothing"
m5_total="$(grep -c '^[[:space:]]*for arm in ' "$SUT")"
[ "$m5_total" -ge 4 ] \
  || fail "M5: expected at least 4 arm loops to audit in batch.sh, found $m5_total — this check may have stopped matching"
ok "M5 all $m5_total arm loop(s) in batch.sh are either the counterbalanced execute loop or carry an ARM-ORDER AUDIT marker"

fi

if run_group 7; then  # section N
# ═══════════════════════════════════════════════════════════════════════════
# SECTION N — RECORD-LEVEL CONCURRENCY (temperloop#1682).
#
#   N1  determinism: the same corpus and seed at N=1 and N=4 assign the SAME
#       arm order and produce the SAME records in both arms
#   N2  a record's two legs NEVER overlap in time — asserted from the recorded
#       per-leg started_at/ended_at, not by inspection
#   N3  ...and concurrency ACTUALLY HAPPENED, which is the converse N2 needs:
#       a pool that silently ran serially would satisfy N2 trivially
#   N4  the circuit breaker under concurrency: it still stops the batch, and
#       the summary states how many records were running when dispatch stopped
#   N5  the requested width is CLAMPED to the configured cap, and says so
#   N6  an unparseable width resolves to 1 — never to a concurrency nobody
#       asked for
#   N7  resume ACROSS WIDTHS: a batch run at N=4 and resumed at N=1 re-spends
#       nothing
#   N8  MUTATION PROOF — a driver that runs a record's two legs concurrently
#       FAILS N2's predicate, so N2 is a measurement rather than a formality
# ═══════════════════════════════════════════════════════════════════════════

# CORPUS_CONC — 4 eligible records (8 legs): enough to fill a 4-wide pool and
# to split the arm order two-and-two, and no more. Deliberately the smallest
# corpus that still exercises everything below, because the slow stubs these
# runs need make this suite the SLOWEST gate in scripts/quality-gates.sh — and
# the slowest gate sets the whole suite's floor.
CORPUS_CONC="$WORK/corpus-conc.jsonl"
{ mk_corpus_line 701 eligible "$BASE"
  mk_corpus_line 702 eligible "$BASE"
  mk_corpus_line 703 eligible "$BASE"
  mk_corpus_line 704 eligible "$BASE"; } >"$CORPUS_CONC"

# The SLOW recorded runners. started_at/ended_at are ISO-8601 at SECOND
# resolution — the right resolution for a leg that runs for minutes, and too
# coarse for a stub that finishes in milliseconds. A one-second floor per leg
# is what makes N2's ordering assertion and N8's mutation observable at all.
SLOW_LOG="$WORK/slow-calls.log"; : >"$SLOW_LOG"
mk_slow_stub() {  # mk_slow_stub <path> <model-key>
  mk_stub "$1" "$2" "$SLOW_LOG"
  MUT_OLD='set -u' MUT_NEW='set -u
sleep 1' perl -0777 -pi -e 's/\Qset -u\E/$ENV{MUT_NEW}/' "$1"
}
SLOW_BASE="$WORK/stub-slow-baseline.sh"
SLOW_CAND="$WORK/stub-slow-candidate.sh"
mk_slow_stub "$SLOW_BASE" "recorded-baseline-model"
mk_slow_stub "$SLOW_CAND" "recorded-candidate-model"

# assert_legs_sequential <state-dir> — THE predicate N2 asserts and N8 mutates
# against. Returns 0 when every record's two legs are strictly ordered in time
# (the leg at position 2 starts at or after the leg at position 1 ends);
# non-zero, with a reason on stdout, when any pair overlaps.
#
# Written as ONE reusable predicate on purpose, for the same reason
# assert_counterbalanced is: a mutation proof that runs a DIFFERENT check than
# the passing test proves nothing about that test.
assert_legs_sequential() {
  local sd="$1" f key bf cf verdict checked=0
  for f in "$sd"/legs/baseline/*.state.json; do
    [ -e "$f" ] || continue
    key="$(basename "$f" .state.json)"
    bf="$sd/legs/baseline/$key.state.json"
    cf="$sd/legs/candidate/$key.state.json"
    [ -f "$cf" ] || continue
    verdict="$(jq -n --slurpfile b "$bf" --slurpfile c "$cf" -r '
      [$b[0], $c[0]]
      | map(select((.started_at // null) != null and (.ended_at // null) != null))
      | sort_by(.execution_order.position)
      | if length < 2 then "skip"
        elif (.[1].started_at >= .[0].ended_at) then "ok"
        else "OVERLAP pos1 " + .[0].started_at + ".." + .[0].ended_at
             + " vs pos2 " + .[1].started_at + ".." + .[1].ended_at
        end' 2>/dev/null)"
    case "$verdict" in
      ok) checked=$((checked + 1)) ;;
      skip) ;;
      *) printf '%s: %s\n' "$key" "$verdict"; return 1 ;;
    esac
  done
  [ "$checked" -gt 0 ] || { printf 'no record had two timestamped legs to compare\n'; return 1; }
  printf '%s record(s) checked\n' "$checked"
  return 0
}

# N1 — determinism. Concurrency must not be able to change WHAT is measured.
count
: >"$SLOW_LOG"
SER_OUT="$WORK/out-conc-serial"; SER_STATE="$WORK/state-conc-serial"
DRIVE_ARGS=(--corpus-file "$CORPUS_CONC" --repo-root "$REPO" --out-dir "$SER_OUT" --state-dir "$SER_STATE"
            --baseline-runner "bash $SLOW_BASE" --candidate-runner "bash $SLOW_CAND" --confirm
            --concurrency 1)
drive ""
[ "$RC" -eq 0 ] || fail "N1: the serial reference run must exit 0, got $RC: $OUT"
CONC_SERIAL_OUT="$OUT"
PAR_OUT="$WORK/out-conc-par"; PAR_STATE="$WORK/state-conc-par"
DRIVE_ARGS=(--corpus-file "$CORPUS_CONC" --repo-root "$REPO" --out-dir "$PAR_OUT" --state-dir "$PAR_STATE"
            --baseline-runner "bash $SLOW_BASE" --candidate-runner "bash $SLOW_CAND" --confirm
            --concurrency 4)
drive ""
[ "$RC" -eq 0 ] || fail "N1: the concurrent run must exit 0, got $RC: $(cat "$WORK/last-stderr.txt")"
CONC_PAR_OUT="$OUT"
[ "$(jq -c '.arm_order.per_record' <<<"$CONC_PAR_OUT")" = "$(jq -c '.arm_order.per_record' <<<"$CONC_SERIAL_OUT")" ] \
  || fail "N1: N=4 assigned a DIFFERENT arm order than N=1 — the assignment must be a pure function of the record index: $(jq -c '.arm_order.per_record' <<<"$CONC_PAR_OUT")"
for a in baseline candidate; do
  [ "$(jq -s -c 'map(.outcome_ref) | sort' <"$PAR_OUT/$a.jsonl")" \
    = "$(jq -s -c 'map(.outcome_ref) | sort' <"$SER_OUT/$a.jsonl")" ] \
    || fail "N1: the $a arm holds different records at N=4 than at N=1"
done
[ "$(jq -r '.legs.scored_n' <<<"$CONC_PAR_OUT")" = "$(jq -r '.legs.scored_n' <<<"$CONC_SERIAL_OUT")" ] \
  || fail "N1: N=4 scored a different number of legs than N=1: $(jq -c .legs <<<"$CONC_PAR_OUT")"
ok "N1 the same corpus and seed produce the SAME arm order, the SAME records in both arms, and the same scored count at N=1 and N=4"

# N2 — a record's two legs never overlap. THE constraint that makes
#      record-level concurrency safe for temperloop#1571's position estimate.
count
if ! n2_reason="$(assert_legs_sequential "$PAR_STATE")"; then
  fail "N2: a record's two legs overlapped in time at N=4 — that destroys the execution_order.position estimate (temperloop#1571) and re-opens the arm-vs-position confound (temperloop#1606): $n2_reason"
fi
ok "N2 at N=4 every record's two legs are strictly ordered in time ($n2_reason) — concurrency is across records, never within a pair"

# N3 — ...and concurrency actually happened. Without this, N2 proves nothing:
#      a pool that silently ran serially satisfies it trivially.
count
n3_inflight="$(jq -r '.concurrency.max_records_in_flight' <<<"$CONC_PAR_OUT")"
[ "$n3_inflight" -ge 2 ] \
  || fail "N3: the N=4 run never had more than $n3_inflight record(s) in flight — it ran SERIALLY, so N2 above asserts nothing: $(jq -c .concurrency <<<"$CONC_PAR_OUT")"
[ "$(jq -r '.concurrency.effective' <<<"$CONC_PAR_OUT")" = "4" ] \
  || fail "N3: the summary must report the effective width: $(jq -c .concurrency <<<"$CONC_PAR_OUT")"
[ "$(jq -r '.concurrency.max_records_in_flight' <<<"$CONC_SERIAL_OUT")" = "1" ] \
  || fail "N3: the N=1 run must report exactly one record in flight: $(jq -c .concurrency <<<"$CONC_SERIAL_OUT")"
jq -e '.concurrency.observed | (.wall_secs | type) == "number" and (.serial_sum_secs | type) == "number"' \
  <<<"$CONC_PAR_OUT" >/dev/null \
  || fail "N3: the speedup must be MEASURED and published, not assumed: $(jq -c .concurrency <<<"$CONC_PAR_OUT")"
n3_meas="$(jq -r '"wall \(.concurrency.observed.wall_secs)s vs serial-sum \(.concurrency.observed.serial_sum_secs)s, speedup \(.concurrency.observed.speedup)x"' <<<"$CONC_PAR_OUT")"
n3_ser="$(jq -r '.concurrency.observed.wall_secs' <<<"$CONC_SERIAL_OUT")"
ok "N3 the N=4 run really did run $n3_inflight records at once (N=1 ran 1) — MEASURED on this host: $n3_meas (the N=1 reference run took ${n3_ser}s)"

# N4 — the circuit breaker under concurrency.
count
: >"$CB_LOG"
CBC_OUT="$WORK/out-cb-conc"; CBC_STATE="$WORK/state-cb-conc"
DRIVE_ARGS=(--corpus-file "$CORPUS_CB" --repo-root "$REPO" --out-dir "$CBC_OUT" --state-dir "$CBC_STATE"
            --baseline-runner "bash $CB_STUB" --candidate-runner "bash $CB_STUB"
            --judge-runner "bash $JUDGE_STUB" --confirm --concurrency 3)
drive "" MODEL_COMPARISON_BATCH_MAX_CONSECUTIVE_STAGE_ERRORS=2
[ "$RC" -eq 5 ] || fail "N4: a tripped breaker must still exit 5 (BATCH_STOPPED_EARLY) at N>1, got $RC: $OUT"
[ "$(jq -r '.circuit_breaker.tripped' <<<"$OUT")" = "true" ] \
  || fail "N4: the breaker must still trip at N>1: $(jq -c .circuit_breaker <<<"$OUT")"
cbc_calls="$(wc -l <"$CB_LOG" | tr -d ' ')"
[ "$cbc_calls" -lt 8 ] \
  || fail "N4: the breaker did not stop anything at N=3 — the runner was invoked $cbc_calls times, i.e. the whole corpus"
# The DOCUMENTED difference from N=1: dispatch stops, execution does not, so
# some legs legitimately finish after the trip. The summary must SAY so rather
# than let legs_not_attempted_n quietly disagree with what ran.
jq -e '.circuit_breaker | has("records_in_flight_when_dispatch_stopped") and has("concurrency")' \
  <<<"$OUT" >/dev/null \
  || fail "N4: at N>1 the breaker block must state how many records were in flight when dispatch stopped: $(jq -c .circuit_breaker <<<"$OUT")"
case "$(jq -r '.circuit_breaker.concurrency_note' <<<"$OUT")" in
  *"stops DISPATCH"*) : ;;
  *) fail "N4: the breaker must NAME the dispatch-vs-execution distinction at N>1: $(jq -r '.circuit_breaker.concurrency_note' <<<"$OUT")" ;;
esac
ok "N4 the breaker still stops the batch at N=3 (exit 5, $cbc_calls of 8 legs run) and the summary names the dispatch-vs-execution difference"

# N5 — the cap clamps, and says so.
count
CLAMP_OUT="$WORK/out-clamp"; CLAMP_STATE="$WORK/state-clamp"
DRIVE_ARGS=(--corpus-file "$CORPUS_A" --repo-root "$REPO" --out-dir "$CLAMP_OUT" --state-dir "$CLAMP_STATE"
            --baseline-runner "bash $BASE_STUB" --candidate-runner "bash $CAND_STUB" --confirm
            --concurrency 99)
drive "" MODEL_COMPARISON_BATCH_MAX_CONCURRENCY=2
[ "$RC" -eq 0 ] || fail "N5: a clamped run must still succeed, got $RC"
[ "$(jq -r '.concurrency.effective' <<<"$OUT")" = "2" ] \
  || fail "N5: --concurrency 99 must clamp to the cap of 2: $(jq -c .concurrency <<<"$OUT")"
[ "$(jq -r '.concurrency.requested' <<<"$OUT")" = "99" ] \
  || fail "N5: the summary must record what was REQUESTED alongside what ran: $(jq -c .concurrency <<<"$OUT")"
grep -q "clamped to 2" "$WORK/last-stderr.txt" \
  || fail "N5: a clamp must be announced on stderr, not applied silently: $(cat "$WORK/last-stderr.txt")"
ok "N5 --concurrency 99 clamps to MODEL_COMPARISON_BATCH_MAX_CONCURRENCY and the clamp is announced"

# N6 — an unparseable width resolves to SERIAL, never to a guess.
count
BADC_OUT="$WORK/out-badconc"; BADC_STATE="$WORK/state-badconc"
DRIVE_ARGS=(--corpus-file "$CORPUS_A" --repo-root "$REPO" --out-dir "$BADC_OUT" --state-dir "$BADC_STATE"
            --baseline-runner "bash $BASE_STUB" --candidate-runner "bash $CAND_STUB" --confirm)
drive "" MODEL_COMPARISON_BATCH_CONCURRENCY=four
[ "$RC" -eq 0 ] || fail "N6: an unparseable setting must degrade to serial, not abort, got $RC"
[ "$(jq -r '.concurrency.effective' <<<"$OUT")" = "1" ] \
  || fail "N6: an unparseable width must resolve to 1: $(jq -c .concurrency <<<"$OUT")"
ok "N6 an unparseable MODEL_COMPARISON_BATCH_CONCURRENCY resolves to 1 — a typo never silently widens a spend-bearing batch"

# N7 — resume ACROSS widths. The state dir is width-agnostic or it is broken.
count
: >"$SLOW_LOG"
DRIVE_ARGS=(--corpus-file "$CORPUS_CONC" --repo-root "$REPO" --out-dir "$PAR_OUT" --state-dir "$PAR_STATE"
            --baseline-runner "bash $SLOW_BASE" --candidate-runner "bash $SLOW_CAND" --confirm
            --concurrency 1)
drive ""
[ "$RC" -eq 0 ] || fail "N7: resuming an N=4 batch at N=1 must succeed, got $RC"
n7_calls="$(wc -l <"$SLOW_LOG" | tr -d ' ')"
[ "$n7_calls" = "0" ] \
  || fail "N7: resuming at a different width re-spent $n7_calls leg(s) — the state dir must be width-agnostic"
[ "$(jq -r '.legs.resumed_n' <<<"$OUT")" = "8" ] \
  || fail "N7: all 8 legs should have resumed: $(jq -c .legs <<<"$OUT")"
[ "$(jq -c '.arm_order.per_record' <<<"$OUT")" = "$(jq -c '.arm_order.per_record' <<<"$CONC_PAR_OUT")" ] \
  || fail "N7: the resume assigned a different arm order than the N=4 run it resumed"
ok "N7 a batch run at N=4 and resumed at N=1 re-spends nothing and reproduces its arm order"

# N8 — MUTATION PROOF. Run a record's two legs CONCURRENTLY in a throwaway
#      mirror and N2's own predicate must now FAIL. Without this, N2 is
#      satisfied by any driver that happens to be sequential for other reasons.
count
MUT_N="$WORK/mut-conc"; mk_mirror "$MUT_N"
MUT_N_SUT="$MUT_N/workflows/scripts/model-comparison/batch.sh"
unlink_and_copy "$MUT_N_SUT"
mutate_file "$MUT_N_SUT" \
  '  for arm in "$arm_first" "$arm_second"; do
    arm_pos=$((arm_pos + 1))' \
  '  for arm in "$arm_first" "$arm_second"; do
    { arm_pos=$((arm_pos + 1))'
mutate_file "$MUT_N_SUT" \
  '  done
  rm -rf "$leg_scratch"' \
  '  } &
  done
  wait
  rm -rf "$leg_scratch"'
MUT_N_OUT="$WORK/out-mut-n"; MUT_N_STATE="$WORK/state-mut-n"
DRIVE_ARGS=(--corpus-file "$CORPUS_CONC" --repo-root "$REPO" --out-dir "$MUT_N_OUT" --state-dir "$MUT_N_STATE"
            --baseline-runner "bash $SLOW_BASE" --candidate-runner "bash $SLOW_CAND" --confirm
            --concurrency 1)
drive "$MUT_N_SUT"
if mut_n_reason="$(assert_legs_sequential "$MUT_N_STATE")"; then
  fail "N8: the mutation proof did not fire — a driver running both legs of a record AT ONCE passed N2's predicate ($mut_n_reason), so N2 proves nothing"
fi
ok "N8 MUTATION PROOF: a driver that overlaps a record's two legs FAILS the same predicate N2 passes ($mut_n_reason) — N2 is a measurement"

fi

if run_group 8; then  # sections R, W
# ═══════════════════════════════════════════════════════════════════════════
# SECTION R — --retry-stage: a timed-out leg is recoverable (temperloop#1693)
# ═══════════════════════════════════════════════════════════════════════════
# An integration-error leg matched neither retry arm before this flag, so it
# fell through to legs_done and was PERMANENTLY unrecoverable against its state
# dir. On the #1656 A/A run that cost 10 of 28 records a leg — and with it the
# whole record, since a timed-out leg carries no token envelope and the report
# pairs only outcomes present in BOTH arms. 18 paired outcomes against a floor
# of 20, so the run returned `inconclusive` on sample size for a reason
# unrelated to what it set out to measure.
#
# The stub sleeps past a deliberately tiny REPLAY_CANDIDATE_TIMEOUT_SECS, so
# these are REAL candidate-timeout records produced by the real wall in
# replay.sh — not hand-written state files asserting the shape we hope for.
TO_STUB="$WORK/stub-timeout.sh"
cat >"$TO_STUB" <<STUBEOF
#!/usr/bin/env bash
set -u
printf 'timeout-stub %s\n' "\$1" >>"$CAND_LOG"
# EXEC, not a plain `sleep` (temperloop#2163): replay.sh bounds this runner
# with run_with_timeout, which kills the process it spawned — this bash. A
# forked `sleep` would be that bash's CHILD, survive its parent, and outlive
# the whole suite as an orphan (CI reported them by name at job teardown).
# `exec` makes the sleep BE the bounded process, so the timeout reaps it.
exec sleep 5
STUBEOF
chmod +x "$TO_STUB"

CORPUS_TO="$WORK/corpus-timeout.jsonl"
{ mk_corpus_line 601 eligible "$BASE"
  mk_corpus_line 602 eligible "$BASE"; } >"$CORPUS_TO"
TO_OUT="$WORK/out-timeout"; TO_STATE="$WORK/state-timeout"
mkdir -p "$TO_OUT" "$TO_STATE"

: >"$CAND_LOG"
DRIVE_ARGS=(--corpus-file "$CORPUS_TO" --repo-root "$REPO" --out-dir "$TO_OUT" --state-dir "$TO_STATE"
            --baseline-runner "bash $BASE_STUB" --candidate-runner "bash $TO_STUB"
            --judge-runner "bash $JUDGE_STUB" --confirm)
drive "" REPLAY_CANDIDATE_TIMEOUT_SECS=1

# R1 — the setup is genuinely candidate-timeout, not some other failure.
count
to_ie="$(grep -l '"candidate-timeout"' "$TO_STATE"/legs/*/*.state.json 2>/dev/null | wc -l | tr -d ' ')"
[ "$to_ie" = "2" ] \
  || fail "R1: expected 2 candidate-timeout leg states on disk, got $to_ie: $(cat "$TO_STATE"/legs/candidate/*.state.json 2>/dev/null)"
[ "$(jq -r '.legs.integration_error_n' <<<"$OUT")" = "2" ] \
  || fail "R1: expected 2 integration-error legs, got: $(jq -c .legs <<<"$OUT")"
ok "R1 the fixture produces REAL candidate-timeout records from replay.sh own wall, not hand-written state"

# R2 — --retry-failed ALONE still refuses them. This is today's protection,
#      and the flag must not quietly broaden it.
count
: >"$CAND_LOG"
DRIVE_ARGS=(--corpus-file "$CORPUS_TO" --repo-root "$REPO" --out-dir "$TO_OUT" --state-dir "$TO_STATE"
            --baseline-runner "bash $BASE_STUB" --candidate-runner "bash $TO_STUB"
            --judge-runner "bash $JUDGE_STUB" --retry-failed --confirm)
drive "" REPLAY_CANDIDATE_TIMEOUT_SECS=1
[ "$(grep -c 'timeout-stub' "$CAND_LOG" 2>/dev/null || true)" = "0" ] \
  || fail "R2: --retry-failed alone must NOT re-drive an integration-error leg, but it ran $(grep -c 'timeout-stub' "$CAND_LOG") leg(s)"
[ "$(jq -r '.legs.resumed_n' <<<"$OUT")" -ge 2 ] \
  || fail "R2: the timed-out legs must be resumed, not re-spent: $(jq -c .legs <<<"$OUT")"
ok "R2 --retry-failed alone still refuses an integration-error leg — the conservative default is untouched"

# R3 — --retry-stage candidate-timeout DOES re-drive them, and re-drives ONLY
#      them: the already-scored baseline partner keeps its terminal state.
count
: >"$CAND_LOG"
DRIVE_ARGS=(--corpus-file "$CORPUS_TO" --repo-root "$REPO" --out-dir "$TO_OUT" --state-dir "$TO_STATE"
            --baseline-runner "bash $BASE_STUB" --candidate-runner "bash $TO_STUB"
            --judge-runner "bash $JUDGE_STUB" --retry-stage candidate-timeout --confirm)
drive "" REPLAY_CANDIDATE_TIMEOUT_SECS=1
# Both stubs append to the same log, keyed by what they write, so one file
# measures BOTH halves of the claim: the timed-out legs re-ran, the scored
# partner did not.
[ "$(grep -c 'timeout-stub' "$CAND_LOG" 2>/dev/null || true)" = "2" ] \
  || fail "R3: --retry-stage candidate-timeout must re-drive both timed-out legs, got $(grep -c 'timeout-stub' "$CAND_LOG"): $(cat "$CAND_LOG")"
[ "$(grep -c 'recorded-baseline-model' "$CAND_LOG" 2>/dev/null || true)" = "0" ] \
  || fail "R3: the already-scored BASELINE partner must not be re-spent, but it ran $(grep -c 'recorded-baseline-model' "$CAND_LOG") leg(s): $(cat "$CAND_LOG")"
ok "R3 --retry-stage candidate-timeout re-drives exactly the timed-out legs, and never their already-scored partner"

# R4 — the recovery is real: with a wall the stub can finish under, the same
#      state dir reaches a SCORED leg. Without this the flag would only be
#      proved to re-run something, not to recover the run paired-N.
count
: >"$CAND_LOG"
DRIVE_ARGS=(--corpus-file "$CORPUS_TO" --repo-root "$REPO" --out-dir "$TO_OUT" --state-dir "$TO_STATE"
            --baseline-runner "bash $BASE_STUB" --candidate-runner "bash $CAND_STUB"
            --judge-runner "bash $JUDGE_STUB" --retry-stage candidate-timeout --confirm)
drive "" REPLAY_CANDIDATE_TIMEOUT_SECS=120
[ "$(jq -r '.legs.scored_n' <<<"$OUT")" -ge 2 ] \
  || fail "R4: re-driving at a longer wall must reach SCORED legs, got: $(jq -c .legs <<<"$OUT")"
[ "$(jq -r '.legs.integration_error_n' <<<"$OUT")" = "0" ] \
  || fail "R4: no integration-error leg should remain after a successful re-drive: $(jq -c .legs <<<"$OUT")"
ok "R4 re-driving at a longer wall RECOVERS the leg to scored — the paired outcome is restored, not merely re-attempted"

# R5 — an unrecognised stage is REFUSED, never accepted-and-ignored. A silent
#      no-op reads exactly like "there was nothing to retry", which is the
#      failure this validation exists to make impossible.
count
bad_rc=0
env BUILD_QUOTA_CACHE="$NOCACHE" MODEL_USAGE_RAW_DIR="$LAKE" \
  bash "$SUT" run --corpus-file "$CORPUS_TO" --repo-root "$REPO" \
  --out-dir "$TO_OUT" --state-dir "$TO_STATE" --retry-stage candidate-timout \
  >/dev/null 2>"$WORK/badstage.err" || bad_rc=$?
[ "$bad_rc" -eq 2 ] || fail "R5: an unknown --retry-stage must exit 2, got $bad_rc"
grep 'is not an integration-error stage' "$WORK/badstage.err" >/dev/null \
  || fail "R5: the refusal must name the problem: $(cat "$WORK/badstage.err")"
grep 'candidate-timeout' "$WORK/badstage.err" >/dev/null \
  || fail "R5: the refusal must list the known stages so the typo is fixable from the message"
ok "R5 an unknown --retry-stage exits 2 and lists the valid stages, rather than silently retrying nothing"

# R6 — MUTATION PROOF. Neuter the stage gate and R3 must go red: the re-drive
#      is that gate, not some pre-existing resume behaviour.
count
# Mirrored into a full tree (mk_mirror), NOT copied to a bare path: batch.sh
# resolves replay.sh relative to its own location, so a mutant sitting alone in
# $WORK cannot run at all — it exits CANNOT_EVALUATE with "replay.sh not found"
# and re-drives 0 legs for a reason that has nothing to do with the gate. That
# is exactly how this proof read as PASSING before the guards below were added.
MUT_R="$WORK/mut-retry-stage"; mk_mirror "$MUT_R"
MUT_R_SUT="$MUT_R/workflows/scripts/model-comparison/batch.sh"
unlink_and_copy "$MUT_R_SUT"
# mutate_file dies unless the old text matches EXACTLY once, so a refactor that
# moves this gate fails the suite loudly instead of quietly voiding the proof.
mutate_file "$MUT_R_SUT" \
  '          *" $prev_stage "*) [ -n "$prev_stage" ] && retryable=1 ;;' \
  '          *" $prev_stage "*) : ;;'

MUT_STATE="$WORK/state-timeout-mut"; MUT_OUT="$WORK/out-timeout-mut"
rm -rf "$MUT_STATE" "$MUT_OUT"; mkdir -p "$MUT_STATE" "$MUT_OUT"
# Build the timed-out state with the UNMUTATED driver, so the only difference
# at the retry step is the gate itself.
: >"$CAND_LOG"
DRIVE_ARGS=(--corpus-file "$CORPUS_TO" --repo-root "$REPO" --out-dir "$MUT_OUT" --state-dir "$MUT_STATE"
            --baseline-runner "bash $BASE_STUB" --candidate-runner "bash $TO_STUB"
            --judge-runner "bash $JUDGE_STUB" --confirm)
drive "" REPLAY_CANDIDATE_TIMEOUT_SECS=1
[ "$(grep -c 'candidate-timeout' "$MUT_STATE"/legs/*/*.state.json 2>/dev/null | grep -vc ':0$' || true)" != "0" ] \
  || fail "R6: the mutant fixture has no candidate-timeout legs to retry, so the proof would be vacuous"

: >"$CAND_LOG"
DRIVE_ARGS=(--corpus-file "$CORPUS_TO" --repo-root "$REPO" --out-dir "$MUT_OUT" --state-dir "$MUT_STATE"
            --baseline-runner "bash $BASE_STUB" --candidate-runner "bash $TO_STUB"
            --judge-runner "bash $JUDGE_STUB" --retry-stage candidate-timeout --confirm)
drive "$MUT_R_SUT" REPLAY_CANDIDATE_TIMEOUT_SECS=1
# The mutant must have RUN — reached its own summary — not died resolving a
# path. Without this the proof cannot tell "chose not to retry" from "crashed".
printf '%s' "$OUT" | jq -e '.outcome and (.outcome != "CANNOT_EVALUATE")' >/dev/null 2>&1 \
  || fail "R6: the mutant did not run to a summary (rc=$RC, outcome=$(printf '%s' "$OUT" | jq -r '.outcome // "unparseable"')) — its 0 re-drives measure a failure to start, not the gate"
[ "$(grep -c 'timeout-stub' "$CAND_LOG" 2>/dev/null || true)" = "0" ] \
  || fail "R6: the mutation proof did not fire — a batch with the stage gate neutered still re-drove $(grep -c 'timeout-stub' "$CAND_LOG") leg(s), so R3 proves nothing"
ok "R6 MUTATION PROOF: a driver that RAN to its own summary with the stage gate neutered re-drives nothing — R3 measures that gate"
# SECTION W — leg state writes are ATOMIC, torn files are named (#1764)
# ═══════════════════════════════════════════════════════════════════════════
# The five leg-state writes used a plain `>` redirect: truncate first, write
# second. An interrupt in between leaves a TORN file, and the resume path read
# no `.state` from it and dropped the leg into its generic failure arm --
# counted `legs_failed`, reason "no reason recorded", never re-driven. For a leg
# that may have SCORED, with a real record already in the arm file and real
# money already spent. The #1656 run survived exactly this: 49 of 49 state files
# happened to be valid JSON after an ENOSPC mid-write, which is luck.
ATOM_OUT="$WORK/out-atomic"; ATOM_STATE="$WORK/state-atomic"
mkdir -p "$ATOM_OUT" "$ATOM_STATE"
: >"$CAND_LOG"
DRIVE_ARGS=(--corpus-file "$CORPUS_A" --repo-root "$REPO" --out-dir "$ATOM_OUT" --state-dir "$ATOM_STATE"
            --baseline-runner "bash $BASE_STUB" --candidate-runner "bash $CAND_STUB"
            --judge-runner "bash $JUDGE_STUB" --confirm)
drive ""

count
# W1 — THE ACCEPTANCE CHECK: every state file on disk parses. Asserted over the
# whole state dir rather than a sampled one, because a partial write is exactly
# the thing that would hide in the file nobody happened to look at.
w_total=0; w_bad=0
for f in "$ATOM_STATE"/legs/*/*.state.json; do
  [ -f "$f" ] || continue
  w_total=$(( w_total + 1 ))
  jq -e 'type == "object" and (.state | type) == "string"' <"$f" >/dev/null 2>&1 || w_bad=$(( w_bad + 1 ))
done
[ "$w_total" -gt 0 ] || fail "W1: no leg state files were written, so this proves nothing"
[ "$w_bad" -eq 0 ] || fail "W1: $w_bad of $w_total leg state files do not parse as an object carrying a string .state"
ok "W1 every one of the $w_total leg state files on disk is whole and carries a readable state"

count
# W2 — no temp file is left behind. bd_write_state writes into the SAME
# directory as its target (a rename across filesystems is not atomic), so a
# leaked temp would sit right beside the real state files.
w_tmp="$(find "$ATOM_STATE" -name '.state.*' 2>/dev/null | wc -l | tr -d ' ')"
[ "$w_tmp" = "0" ] || fail "W2: $w_tmp temp state file(s) left behind in the state dir: $(find "$ATOM_STATE" -name '.state.*' | head -3)"
ok "W2 the atomic write leaves no temp file behind in the state dir"

count
# W3 — A TORN FILE IS NAMED, not swallowed. Truncate a SCORED leg's state and
# resume: the leg must be reported under its own reason saying the outcome is
# unknown, and must NOT carry the generic "no reason recorded".
TORN="$(find "$ATOM_STATE"/legs/candidate -name '*.state.json' | head -1)"
[ -n "$TORN" ] || fail "W3: no candidate leg state file to tear"
[ "$(jq -r '.state' <"$TORN")" = "scored" ] || fail "W3: the fixture leg is not scored, so tearing it proves nothing: $(cat "$TORN")"
printf '{"state":"sco' >"$TORN"     # a prefix, exactly what a truncate-then-write interrupt leaves
: >"$CAND_LOG"
drive ""
torn_reason="$(jq -r '.failures // [] | map(select(.reason | test("torn or damaged"))) | length' <<<"$OUT")"
[ "$torn_reason" -ge 1 ] \
  || fail "W3: a torn state file must be reported under its own reason, got: $(jq -c '.failures' <<<"$OUT")"
[ "$(jq -r '.failures // [] | map(select(.reason == "no reason recorded")) | length' <<<"$OUT")" = "0" ] \
  || fail "W3: a torn state file must NOT be reported as a generic failure with no reason"
ok "W3 a torn state file is reported as UNKNOWN with its own reason, never as a generic failure"

count
# W4 — …and it is not re-spent by default, but IS recoverable on an explicit
# ask. The leg may have been billed already, so the default protects; the
# operator asking is what makes the spend a decision.
[ "$(grep -c 'recorded-candidate-model' "$CAND_LOG" 2>/dev/null || true)" = "0" ] \
  || fail "W4: a torn leg must NOT be blindly re-spent on a plain resume"
: >"$CAND_LOG"
DRIVE_ARGS=(--corpus-file "$CORPUS_A" --repo-root "$REPO" --out-dir "$ATOM_OUT" --state-dir "$ATOM_STATE"
            --baseline-runner "bash $BASE_STUB" --candidate-runner "bash $CAND_STUB"
            --judge-runner "bash $JUDGE_STUB" --retry-failed --confirm)
drive ""
[ "$(grep -c 'recorded-candidate-model' "$CAND_LOG" 2>/dev/null || true)" -ge 1 ] \
  || fail "W4: --retry-failed must re-drive a torn leg — otherwise it is stranded forever"
ok "W4 a torn leg is not re-spent by default, and --retry-failed recovers it as a deliberate choice"

fi

# ═══════════════════════════════════════════════════════════════════════════
# SECTION L — the suite-wide no-live-call verdict.
# ═══════════════════════════════════════════════════════════════════════════
count
if [ -e "$CANARY" ]; then
  fail "L1: A LIVE MODEL CALL WAS ATTEMPTED during this suite: $(cat "$CANARY")"
fi
ok "L1 no test in this suite ever invoked a 'claude' binary"

count
"$WORK/bin/claude" --self-test >/dev/null 2>&1
[ -e "$CANARY" ] || fail "L2: the canary itself does not work, so L1 proves nothing"
rm -f "$CANARY"
ok "L2 the canary is genuinely capable of firing (so L1 is a measurement, not a tautology)"

echo
if [ "$GROUP" = "all" ]; then
  echo "test_replay_batch.sh: $pass/$total checks passed"
else
  echo "test_replay_batch.sh [group $GROUP]: $pass/$total checks passed"
fi
[ "$pass" -eq "$total" ] || exit 1
