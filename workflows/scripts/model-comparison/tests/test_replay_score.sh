#!/usr/bin/env bash
#
# test_replay_score.sh — fixture suite for replay EXECUTION and SCORING
# (temperloop#1258, epic #1225 "model comparison harness"): `replay.sh
# execute`, `score.sh score|gates|aggregate`, and the send-vs-log
# cross-check `validate-provider-disclosure.sh` gained here.
#
# ── HERMETIC BY CONSTRUCTION, NOT BY PROMISE ───────────────────────────────
# This is the item whose whole job is spawning real model calls, so its own
# suite must never make one. Two independent mechanisms, both asserted:
#
#   1. THE SEAM. Every `execute` invocation below drives a RECORDED candidate
#      runner (`--candidate-runner "bash $STUB"`) whose stdout is a canned
#      `claude -p --output-format json`-shaped envelope on disk. `--live` is
#      never passed by any test in this file.
#   2. THE CANARY. `$WORK/bin` is prepended to PATH for the WHOLE suite and
#      contains a `claude` that records its own invocation to
#      `$WORK/CANARY`. Section K asserts that file never came into
#      existence — so "no live call" is a measured property of the whole
#      run, not a claim about the tests I remembered to check. Section C7
#      then MUTATES `execute`'s refusal branch (in a throwaway mirror of the
#      module) to fall back to a bare `claude`, and proves the canary DOES
#      fire — i.e. the refusal is load-bearing and the canary can detect its
#      absence.
#
# No network, no `gh`, no model call, no writes outside $TMPDIR.
#
# Sections:
#   A   score.sh gates — runs the WORKTREE'S OWN gate script (trap C), and
#       fails CLOSED when there is no gate to run
#   B   score.sh score — the N/T/X/R scoring treatment from the L0 spike
#   C   replay.sh execute — the candidate-runner seam, its REFUSAL when
#       unset, and the mutation proof that the refusal is load-bearing
#   D   execute — a schema-complete scored record (diff, gate, tokens,
#       duration all populated)
#   E   execute — integration-error vs scored, in every failure shape
#   F   score.sh aggregate — integration errors excluded from quality,
#       reported as their own compatibility metric, + mutation proof
#   G   contamination flags, per the spike's enumerated traps
#   H   the send-vs-log cross-check + its mutation proof
#   I   fail-closed: absent / unreadable / empty / malformed, everywhere
#   J   arg hygiene (trailing flag, flag-like value) under a bounded timeout
#   K   the suite-wide no-live-call canary verdict
#
# Usage: bash workflows/scripts/model-comparison/tests/test_replay_score.sh
#
# shellcheck disable=SC2016

set -uo pipefail

# Physical derivation (`cd -P`) — dir-symlink-composition-safe (temperloop#1557).
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MC_DIR="$(cd -P "$HERE/.." && pwd)"
SCRIPTS_DIR="$(cd -P "$MC_DIR/.." && pwd)"
REPLAY="$MC_DIR/replay.sh"
SCORE="$MC_DIR/score.sh"
VALIDATOR="$SCRIPTS_DIR/validate-provider-disclosure.sh"

# shellcheck source=../../lib/portable-timeout.sh
. "$SCRIPTS_DIR/lib/portable-timeout.sh"

pass=0
total=0
ok() { pass=$((pass + 1)); echo "PASS: $1"; }
count() { total=$((total + 1)); }
fail() { echo "FAIL: $1" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-replay-score-XXXXXX")"
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
# it. Section K fails the whole suite if this file exists at the end.
printf 'INVOKED %s\n' "\$*" >>"$CANARY"
exit 0
EOF
chmod +x "$WORK/bin/claude"
PATH="$WORK/bin:$PATH"
export PATH

# mutate_file <file> <old-literal> <new-literal> — exact, literal,
# single-occurrence replacement (same helper, same rationale, as
# test_replay_preflight.sh / test_replay_isolation.sh). Dies loudly if the
# old text is missing or not unique, so a mutation proof can never silently
# become a no-op that "passes".
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

# mk_mirror <dest> — a throwaway, symlink-backed mirror of workflows/scripts
# under <dest>, so a mutation proof can edit ONE real copy of a script
# without ever writing into the checkout. Relative resolution (HERE/../build,
# SCRIPT_DIR/model-comparison/allowlist.sh, ../../ for the repo root) all
# still work because the DIRECTORIES are real and only the leaves are links.
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
  local p="$1" target
  target="$(cd -P "$(dirname "$p")" && pwd)/$(basename "$p")"
  local real; real="$(readlink "$target")"
  rm -f "$target"
  cp "$real" "$target"
  chmod u+w "$target"
}

# ═══════════════════════════════════════════════════════════════════════════
# THE FIXTURE REPO — base, merged truth, and a gate script that lives INSIDE
# the tree (so `score.sh gates` runs the worktree's own, per trap C).
# ═══════════════════════════════════════════════════════════════════════════
REPO="$WORK/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name  T
git -C "$REPO" config commit.gpgsign false

mkdir -p "$REPO/workflows/scripts/drain" "$REPO/scripts" "$REPO/claude/workflows"
cat >"$REPO/workflows/scripts/drain/scan_stub.py" <<'PY'
def _is_command_expansion_turn(turn_text):
    return False
PY
printf '# changelog\n' >"$REPO/CHANGELOG.md"
printf '// build-level at base\n' >"$REPO/claude/workflows/build-level.mjs"
# The in-tree gate entry point. Deliberately signal-driven by a file in the
# worktree root rather than by an env var, so a test controls it the same way
# a real gate is controlled: by the state of the tree it runs against.
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
git -C "$REPO" checkout -q master 2>/dev/null || git -C "$REPO" checkout -q main

TEMPLATE_SHA="$(git -C "$REPO" rev-parse "$BASE:claude/workflows/build-level.mjs")"

# The truth file content the "good" stub reproduces byte-for-byte.
TRUTH_PY="$WORK/truth-scan_stub.py"
git -C "$REPO" show "$TRUTH:workflows/scripts/drain/scan_stub.py" >"$TRUTH_PY"

# ── the corpus record fixture ──────────────────────────────────────────────
# mk_record <file> [--status S] [--flags JSON] [--template SHA] [--acceptance JSON]
mk_record() {
  local file="$1"; shift
  local status="eligible" flags='[]' template="$TEMPLATE_SHA"
  local acceptance='["A named path is fixed.","The lexicon-match count drops from 40 to 0."]'
  while [ $# -gt 0 ]; do
    case "$1" in
      --status) status="$2"; shift 2 ;;
      --flags) flags="$2"; shift 2 ;;
      --template) template="$2"; shift 2 ;;
      --acceptance) acceptance="$2"; shift 2 ;;
      *) echo "mk_record: bad arg $1" >&2; return 2 ;;
    esac
  done
  jq -cn --arg base "$BASE" --arg head "$TRUTH" --arg st "$status" \
    --argjson flags "$flags" --arg tpl "$template" --argjson acc "$acceptance" \
    '{schema_version:"replay-record-v1", pr:999, issue:"#4242",
      merge_commit:null, base:$base, head:$head,
      title:"Exclude the expanded command-spec turn", scope:"drain scan_stub.py",
      acceptance:$acc, notes:"", status:$st, reject_reason:"", flags:$flags,
      buckets:{N:["workflows/scripts/drain/scan_stub.py"],
               T:["workflows/scripts/drain/tests/test_scan_stub.sh"],
               X:["CHANGELOG.md"], R:[]},
      template_sha:$tpl, file_count:2,
      worktree:{path:null,branch:null,prepared_at:null},
      candidate:{provider:null,model:null,diff_ref:null},
      score:{verdict:null,acceptance_results:null,gate_result:null}}' >"$file"
}
RECORD="$WORK/record.json"
mk_record "$RECORD"

# ── the RECORDED candidate runner (the test seam) ──────────────────────────
# Invoked as `<cmd> <prompt-file> <worktree>`; behaviour picked by
# $STUB_MODE. It never reaches a network — its "response" is the canned
# envelope below plus a set of edits it makes in the worktree.
ENVELOPE="$WORK/recorded-envelope.json"
jq -cn '{type:"result", subtype:"success", is_error:false, duration_ms:4242,
         modelUsage:{"claude-recorded-candidate":
           {inputTokens:1200, outputTokens:340,
            cacheReadInputTokens:9000, cacheCreationInputTokens:120,
            provider:"firstParty"}}}' >"$ENVELOPE"

STUB="$WORK/stub-runner.sh"
cat >"$STUB" <<STUBEOF
#!/usr/bin/env bash
# Recorded candidate runner. Reads no network; replays a canned envelope.
set -u
wt="\$2"
case "\${STUB_MODE:-good}" in
  good)
    cp "$TRUTH_PY" "\$wt/workflows/scripts/drain/scan_stub.py"
    mkdir -p "\$wt/workflows/scripts/drain/tests"
    printf '#!/usr/bin/env bash\necho candidate-test\n' >"\$wt/workflows/scripts/drain/tests/test_scan_stub.sh"
    ;;
  different)
    printf 'import re\n\n\ndef _is_command_expansion_turn(t):\n    return bool(re.search("<command-name>", t))\n' \\
      >"\$wt/workflows/scripts/drain/scan_stub.py"
    mkdir -p "\$wt/workflows/scripts/drain/tests"
    printf '#!/usr/bin/env bash\necho candidate-test\n' >"\$wt/workflows/scripts/drain/tests/test_scan_stub.sh"
    ;;
  notest)
    cp "$TRUTH_PY" "\$wt/workflows/scripts/drain/scan_stub.py"
    ;;
  notouch) : ;;
  gatered)
    cp "$TRUTH_PY" "\$wt/workflows/scripts/drain/scan_stub.py"
    mkdir -p "\$wt/workflows/scripts/drain/tests"
    printf '#!/usr/bin/env bash\necho candidate-test\n' >"\$wt/workflows/scripts/drain/tests/test_scan_stub.sh"
    : >"\$wt/GATE_FAIL"
    ;;
  testshapes)
    mkdir -p "\$wt/a/tests" "\$wt/b"
    printf 'x\n' >"\$wt/a/tests/thing.sh"
    printf 'x\n' >"\$wt/b/test_thing.sh"
    printf 'x\n' >"\$wt/b/plain.sh"
    cp "$TRUTH_PY" "\$wt/workflows/scripts/drain/scan_stub.py"
    ;;
  spawnfail) echo "vendor connection reset" >&2; exit 3 ;;
  # ── the three temperloop#1553 spawn-failure shapes ─────────────────────
  # THE REAL ONE: claude -p --output-format json reports an API-level
  # failure as a JSON object on STDOUT and writes NOTHING to stderr. This
  # mode reproduces that exactly — an empty stderr is not an anomaly here,
  # it is the CLI's documented shape, and it is what made all 28 legs of the
  # first live batch record "the candidate runner exited 1: ".
  spawnfail_stdout)
    jq -cn '{type:"result", subtype:"error_during_execution", is_error:true,
             api_error_status:529, duration_ms:812,
             result:"API Error: 529 upstream overloaded"}'
    exit 1
    ;;
  # Genuinely silent on BOTH streams — the only case where there is no
  # diagnostic to report, and the detail must SAY so.
  spawnfail_silent) exit 1 ;;
  # Verbose on both streams — the bound has to hold.
  spawnfail_verbose)
    head -c 5000 /dev/zero | tr '\0' 'E' >&2
    jq -cn --arg r "\$(head -c 5000 /dev/zero | tr '\0' 'R')" \\
      '{type:"result", subtype:"error_during_execution", is_error:true, result:\$r}'
    exit 1
    ;;
  badjson)   printf 'not json at all\n'; exit 0 ;;
  vendorerror)
    jq -cn '{type:"result", is_error:true, subtype:"api_error_overloaded"}'
    exit 0
    ;;
  nousage)
    jq -cn '{type:"result", subtype:"success", is_error:false, duration_ms:11}'
    exit 0
    ;;
  hang) sleep 30; ;;
esac
cat "$ENVELOPE"
STUBEOF
chmod +x "$STUB"

# ── a fresh candidate worktree per run ─────────────────────────────────────
# NOTE: this is called inside `$( )`, so it runs in a SUBSHELL — a counter
# variable incremented here would never reach the parent and every call would
# hand back the SAME path (a fixture reusing a dirty worktree silently makes
# "the candidate touched nothing" indistinguishable from "the candidate did
# the work"). The name therefore comes from mktemp, which is subshell-safe.
mk_wt() {  # prints a FRESH worktree path rewound to $BASE
  local p slug
  p="$(mktemp -d "$WORK/wt-XXXXXX")" || return 1
  rm -rf "$p"
  slug="cand-$(basename "$p")"
  git -C "$REPO" worktree add -q -b "$slug" "$p" "$BASE" >/dev/null 2>&1 || return 1
  printf '%s\n' "$p"
}

# ── env every execute run gets: the disclosure log and the attribution lake
#    both point INTO $WORK, never at the checkout. ───────────────────────────
LAKE="$WORK/lake"
DLOG="$WORK/disclosure-log.jsonl"
ALLOW="$WORK/allow.txt"
NOLOCAL="$WORK/no-such-local-override.txt"
printf 'anthropic\nopenai\n' >"$ALLOW"
mkdir -p "$LAKE"

run_exec() {  # run_exec <STUB_MODE> <args...>
  local mode="$1"; shift
  env STUB_MODE="$mode" \
      MODEL_USAGE_RAW_DIR="$LAKE" \
      PROVIDER_ALLOWLIST_TEST_SEAM=1 \
      PROVIDER_ALLOWLIST_COMMITTED_FILE="$ALLOW" \
      PROVIDER_ALLOWLIST_LOCAL_FILE="$NOLOCAL" \
      PROVIDER_DISCLOSURE_LOG_FILE="$DLOG" \
      OPENAI_API_KEY="fixture-key-never-sent-anywhere" \
      bash "$REPLAY" execute "$@"
}

run_validator() {  # run_validator [<script-path>]
  local script="${1:-$VALIDATOR}"
  env MODEL_USAGE_RAW_DIR="$LAKE" \
      PROVIDER_ALLOWLIST_TEST_SEAM=1 \
      PROVIDER_ALLOWLIST_COMMITTED_FILE="$ALLOW" \
      PROVIDER_ALLOWLIST_LOCAL_FILE="$NOLOCAL" \
      PROVIDER_DISCLOSURE_LOG_FILE="$DLOG" \
      bash "$script"
}

# ═══════════════════════════════════════════════════════════════════════════
# SECTION A — score.sh gates: the worktree's OWN gate script, fail-closed
# ═══════════════════════════════════════════════════════════════════════════

WT="$(mk_wt)"

count
out="$(bash "$SCORE" gates --worktree "$WT")"
rc=$?
[ "$rc" -eq 0 ] || fail "A1: a green gate run should exit 0, got $rc: $out"
[ "$(jq -r .outcome <<<"$out")" = "GATES" ] || fail "A1: expected GATES, got: $out"
[ "$(jq -r .passed <<<"$out")" = "true" ] || fail "A1: expected passed=true, got: $out"
[ "$(jq -r .exit_code <<<"$out")" = "0" ] || fail "A1: expected exit_code 0, got: $out"
ok "A1 gates runs the worktree's own scripts/quality-gates.sh and reports its pass"

count
: >"$WT/GATE_FAIL"
out="$(bash "$SCORE" gates --worktree "$WT")"
rc=$?
[ "$rc" -eq 0 ] || fail "A2: a RED gate is still a RAN gate — exit must be 0, got $rc: $out"
[ "$(jq -r .passed <<<"$out")" = "false" ] || fail "A2: expected passed=false, got: $out"
[ "$(jq -r .exit_code <<<"$out")" = "1" ] || fail "A2: expected the fixture gate's own exit 1, got: $out"
rm -f "$WT/GATE_FAIL"
ok "A2 a failing gate is reported as ran+failed (exit 0), never confused with 'no gate'"

count
# THE trap-C property: the script that runs is the worktree's, not this
# checkout's. Proven by editing the WORKTREE's copy and watching the verdict
# follow it — a run against today's tree could not change.
cat >"$WT/scripts/quality-gates.sh" <<'G'
#!/usr/bin/env bash
echo "worktree-local gate speaking"
exit 7
G
out="$(bash "$SCORE" gates --worktree "$WT")"
[ "$(jq -r .exit_code <<<"$out")" = "7" ] || fail "A3: the WORKTREE's own gate script must be the one that runs, got: $out"
git -C "$WT" checkout -- scripts/quality-gates.sh
ok "A3 the gate that runs is the candidate worktree's own copy (trap C: never mix trees)"

count
out="$(bash "$SCORE" gates --worktree "$WT" --gate-relpath scripts/no-such-gate.sh)"
rc=$?
[ "$rc" -ne 0 ] || fail "A4: an absent gate script must be non-zero, got 0: $out"
[ "$(jq -r .outcome <<<"$out")" = "CANNOT_EVALUATE" ] || fail "A4: expected CANNOT_EVALUATE, got: $out"
ok "A4 an absent gate entry point is CANNOT_EVALUATE + non-zero, never a silent pass"

count
err="$(bash "$SCORE" gates --worktree "$WT" --gate-relpath scripts/no-such-gate.sh 2>&1 >/dev/null)"
case "$err" in *"CANNOT EVALUATE"*) ;; *) fail "A5: expected a distinct 'CANNOT EVALUATE' line on stderr, got: $err" ;; esac
ok "A5 the fail-closed path prints a distinct CANNOT EVALUATE line on stderr"

count
out="$(bash "$SCORE" gates --worktree "$WT" --gate-relpath ../escape.sh)"
rc=$?
[ "$rc" -ne 0 ] || fail "A6: a '..' gate relpath must be refused, got 0: $out"
ok "A6 a gate relpath escaping the worktree is refused"

count
# The timeout budget is WIRED, and a timeout is not a pass. Non-default
# value on purpose (never pinned equal to the shipped default).
cat >"$WT/scripts/quality-gates.sh" <<'G'
#!/usr/bin/env bash
# EXEC, not a plain `sleep` (temperloop#2163): score.sh bounds this gate with
# run_with_timeout, whose portable bash backend (a stock macOS runner, with
# neither `timeout` nor `gtimeout`) `kill -9`s the process it spawned — this
# bash. A forked `sleep` would be that bash's CHILD, be re-parented to init,
# and outlive the suite as an orphan the CI runner names at job teardown.
# `exec` makes the sleep BE the bounded process, so the timeout reaps it.
exec sleep 20
G
out="$(env REPLAY_SCORE_GATE_TIMEOUT_SECS=1 bash "$SCORE" gates --worktree "$WT")"
[ "$(jq -r .timed_out <<<"$out")" = "true" ] || fail "A7: expected timed_out=true, got: $out"
[ "$(jq -r .passed <<<"$out")" = "false" ] || fail "A7: a timed-out gate must NEVER read as passed, got: $out"
[ "$(jq -r .timeout_secs <<<"$out")" = "1" ] || fail "A7: REPLAY_SCORE_GATE_TIMEOUT_SECS not wired, got: $out"
git -C "$WT" checkout -- scripts/quality-gates.sh
ok "A7 REPLAY_SCORE_GATE_TIMEOUT_SECS is wired and a timed-out gate is not a pass"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION B — score.sh score: the spike's N/T/X/R treatment
# ═══════════════════════════════════════════════════════════════════════════

count
WT_GOOD="$(mk_wt)"
STUB_MODE=good bash "$STUB" /dev/null >/dev/null "$WT_GOOD"
out="$(bash "$SCORE" score --repo-root "$REPO" --candidate-worktree "$WT_GOOD" --record "$RECORD")"
rc=$?
[ "$rc" -eq 0 ] || fail "B1: scoring should exit 0, got $rc: $out"
[ "$(jq -r .outcome <<<"$out")" = "SCORED" ] || fail "B1: expected SCORED, got: $out"
[ "$(jq -r .verdict <<<"$out")" = "pass" ] || fail "B1: expected verdict pass, got: $out"
[ "$(jq -r '.diff.n.total' <<<"$out")" = "1" ] || fail "B1: expected 1 N path, got: $out"
[ "$(jq -r '.diff.n.changed' <<<"$out")" = "1" ] || fail "B1: expected the N path changed, got: $out"
[ "$(jq -r '.diff.n.matched_truth' <<<"$out")" = "1" ] || fail "B1: the good stub reproduces truth byte-for-byte, got: $out"
ok "B1 a candidate matching merged truth on the named surface scores verdict=pass"

count
WT_DIFF="$(mk_wt)"
STUB_MODE=different bash "$STUB" /dev/null >/dev/null "$WT_DIFF"
out="$(bash "$SCORE" score --repo-root "$REPO" --candidate-worktree "$WT_DIFF" --record "$RECORD")"
[ "$(jq -r .verdict <<<"$out")" = "pass" ] || fail "B2: a DIFFERENT but complete fix still passes (N is scored on change+gate, not bytes), got: $out"
[ "$(jq -r '.diff.n.matched_truth' <<<"$out")" = "0" ] || fail "B2: expected matched_truth 0 for a different implementation, got: $out"
ok "B2 matched_truth is reported separately from the verdict — a different-but-working fix is not penalised for bytes"

count
WT_NT="$(mk_wt)"
STUB_MODE=notouch bash "$STUB" /dev/null >/dev/null "$WT_NT"
out="$(bash "$SCORE" score --repo-root "$REPO" --candidate-worktree "$WT_NT" --record "$RECORD")"
rc=$?
[ "$rc" -eq 0 ] || fail "B3: 'scored and failed' must exit 0, got $rc"
[ "$(jq -r .verdict <<<"$out")" = "fail" ] || fail "B3: an untouched named surface must fail, got: $out"
[ "$(jq -r .scored <<<"$out")" = "true" ] || fail "B3: it IS scored, just failing, got: $out"
[ "$(jq -r '.components.named_surface_all_changed' <<<"$out")" = "false" ] || fail "B3: expected the N component false, got: $out"
ok "B3 'scored, and it failed' is exit 0 with scored=true — distinct from 'couldn't score'"

count
WT_NTEST="$(mk_wt)"
STUB_MODE=notest bash "$STUB" /dev/null >/dev/null "$WT_NTEST"
out="$(bash "$SCORE" score --repo-root "$REPO" --candidate-worktree "$WT_NTEST" --record "$RECORD")"
[ "$(jq -r '.diff.t.present' <<<"$out")" = "false" ] || fail "B4: expected T present=false, got: $out"
[ "$(jq -r '.diff.t.required' <<<"$out")" = "true" ] || fail "B4: truth carries a T path, so T is required, got: $out"
[ "$(jq -r .verdict <<<"$out")" = "fail" ] || fail "B4: a missing test surface must fail the verdict, got: $out"
[ "$(jq -r '.diff.t.scored_on' <<<"$out")" = "presence+pass" ] || fail "B4: T must be scored on presence+pass, got: $out"
ok "B4 T is scored on presence (+pass), never bytes, and its absence fails the verdict"

count
WT_GATE="$(mk_wt)"
STUB_MODE=gatered bash "$STUB" /dev/null >/dev/null "$WT_GATE"
out="$(bash "$SCORE" score --repo-root "$REPO" --candidate-worktree "$WT_GATE" --record "$RECORD")"
[ "$(jq -r '.gate_result.passed' <<<"$out")" = "false" ] || fail "B5: expected the gate to fail, got: $out"
[ "$(jq -r .verdict <<<"$out")" = "fail" ] || fail "B5: a red gate must fail the verdict, got: $out"
[ "$(jq -r '.components.named_surface_all_changed' <<<"$out")" = "true" ] || fail "B5: N was fine; only the gate failed, got: $out"
ok "B5 quality-gates.sh IS the mechanical outcome scorer — a red gate fails the verdict on its own"

count
[ "$(jq -r '.diff.x.treatment' <<<"$out")" = "neutral" ] || fail "B6: X must be neutral, got: $out"
[ "$(jq -r '.diff.x.paths | length' <<<"$out")" = "1" ] || fail "B6: expected the X path recorded, got: $out"
[ "$(jq -r '.diff.r.treatment' <<<"$out")" = "flagged-only" ] || fail "B6: R must be flagged-only, got: $out"
ok "B6 X is recorded-but-neutral and R is flagged-only, per the spike's scoring table"

count
WT_SHAPES="$(mk_wt)"
STUB_MODE=testshapes bash "$STUB" /dev/null >/dev/null "$WT_SHAPES"
out="$(bash "$SCORE" score --repo-root "$REPO" --candidate-worktree "$WT_SHAPES" --record "$RECORD")"
cand_t="$(jq -r '.diff.t.candidate_paths | sort | join(",")' <<<"$out")"
[ "$cand_t" = "a/tests/thing.sh,b/test_thing.sh" ] || fail "B7: expected exactly the two test-surface paths, got '$cand_t' in: $out"
# The same two shapes, through replay.sh's OWN T-bucket classifier: the two
# definitions agree behaviourally, which is the property that matters.
ds="$(bash "$REPLAY" diff-scope "$REPO" "$BASE" "$TRUTH")"
[ "$(jq -r '.buckets.T | join(",")' <<<"$ds")" = "workflows/scripts/drain/tests/test_scan_stub.sh" ] \
  || fail "B7: replay.sh diff-scope disagrees about the T surface: $ds"
ok "B7 score.sh's candidate test-surface detection agrees with replay.sh's own T bucket"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION B8-B10 — candidate diff text: score.diff.text_excerpt (temperloop#1579)
# ═══════════════════════════════════════════════════════════════════════════

count
out="$(bash "$SCORE" score --repo-root "$REPO" --candidate-worktree "$WT_GOOD" --record "$RECORD")"
te="$(jq -r '.diff.text_excerpt' <<<"$out")"
[ -n "$te" ] || fail "B8: expected a non-empty text_excerpt for a candidate that made edits, got: $out"
case "$te" in *"diff --git"*) ;; *) fail "B8: text_excerpt does not look like real diff text, got: [$te]" ;; esac
[ "$(jq -r '.diff.text_excerpt_truncated' <<<"$out")" = "false" ] || fail "B8: expected text_excerpt_truncated=false under the default cap, got: $out"
ok "B8 the persisted score record carries real, non-empty candidate diff text in text_excerpt"

count
out="$(bash "$SCORE" score --repo-root "$REPO" --candidate-worktree "$WT_NT" --record "$RECORD")"
[ "$(jq -r '.diff.text_excerpt' <<<"$out")" = "" ] || fail "B9: expected an empty text_excerpt for a candidate that touched nothing, got: $out"
[ "$(jq -r '.diff.text_excerpt_truncated' <<<"$out")" = "false" ] || fail "B9: an empty diff cannot be truncated, got: $out"
ok "B9 a zero-change candidate yields an empty (not fabricated) text_excerpt"

count
WT_BIG="$(mk_wt)"
STUB_MODE=good bash "$STUB" /dev/null >/dev/null "$WT_BIG"
out="$(env REPLAY_SCORE_DIFF_EXCERPT_MAX_BYTES=40 bash "$SCORE" score --repo-root "$REPO" --candidate-worktree "$WT_BIG" --record "$RECORD")"
[ "$(jq -r '.diff.text_excerpt_truncated' <<<"$out")" = "true" ] || fail "B10: expected text_excerpt_truncated=true under a 40-byte cap, got: $out"
full_b="$(jq -r '.diff.text_excerpt_full_bytes' <<<"$out")"
[ "$full_b" -gt 40 ] || fail "B10: expected text_excerpt_full_bytes > 40, got: $out"
case "$(jq -r '.diff.text_excerpt' <<<"$out")" in
  *"TRUNCATED"*) ;;
  *) fail "B10: expected an explicit truncation marker in text_excerpt, got: $out" ;;
esac
ok "B10 an oversized diff is excerpted at REPLAY_SCORE_DIFF_EXCERPT_MAX_BYTES with an explicit truncation marker"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION B11-B13 — X and R buckets carry the SAME per-path attribution N
# does (temperloop#1579, score.sh:422-477's logic extended)
# ═══════════════════════════════════════════════════════════════════════════

count
REC_XR="$WORK/record-xr.json"
jq -c '.buckets.R = ["CHANGELOG.md"]' "$RECORD" >"$REC_XR"
WT_XR_NT="$(mk_wt)"
STUB_MODE=notouch bash "$STUB" /dev/null >/dev/null "$WT_XR_NT"
out="$(bash "$SCORE" score --repo-root "$REPO" --candidate-worktree "$WT_XR_NT" --record "$REC_XR")"
[ "$(jq -r '.diff.x.paths[0].path' <<<"$out")" = "CHANGELOG.md" ] || fail "B11: expected the X path attributed, got: $out"
[ "$(jq -r '.diff.x.paths[0].changed' <<<"$out")" = "false" ] || fail "B11: an untouched X path must read changed=false, got: $out"
[ "$(jq -r '.diff.r.paths[0].path' <<<"$out")" = "CHANGELOG.md" ] || fail "B11: expected the R path attributed, got: $out"
[ "$(jq -r '.diff.r.paths[0].changed' <<<"$out")" = "false" ] || fail "B11: an untouched R path must read changed=false, got: $out"
[ "$(jq -r '.diff.n.files[0].changed' <<<"$out")" = "false" ] || fail "B11: (notouch) N must also read changed=false, got: $out"
ok "B11 a zero-change candidate reads changed=false in EVERY bucket alike -- N, X and R"

count
[ "$(jq -r '.diff.x.paths[0] | has("truth_added") and has("matches_truth") and has("formatting_only_truth_churn")' <<<"$out")" = "true" ] \
  || fail "B12: X path attribution is missing fields N's own attribution carries, got: $out"
[ "$(jq -r '.diff.r.paths[0] | has("truth_added") and has("matches_truth") and has("formatting_only_truth_churn")' <<<"$out")" = "true" ] \
  || fail "B12: R path attribution is missing fields N's own attribution carries, got: $out"
ok "B12 X and R per-path records carry the SAME attribution shape N's own does"

count
WT_XR_TOUCH="$(mk_wt)"
STUB_MODE=good bash "$STUB" /dev/null >/dev/null "$WT_XR_TOUCH"
printf '# changelog\n\n- the candidate ALSO edited this truth-partition path\n' >"$WT_XR_TOUCH/CHANGELOG.md"
out="$(bash "$SCORE" score --repo-root "$REPO" --candidate-worktree "$WT_XR_TOUCH" --record "$REC_XR")"
[ "$(jq -r '.diff.x.paths[0].changed' <<<"$out")" = "true" ] || fail "B13: a candidate-touched X path must read changed=true, got: $out"
[ "$(jq -r '.diff.r.paths[0].changed' <<<"$out")" = "true" ] || fail "B13: a candidate-touched R path must read changed=true, got: $out"
[ "$(jq -r '.diff.x.treatment' <<<"$out")" = "neutral" ] || fail "B13: X treatment must stay neutral even when touched, got: $out"
[ "$(jq -r '.diff.r.treatment' <<<"$out")" = "flagged-only" ] || fail "B13: R treatment must stay flagged-only even when touched, got: $out"
ok "B13 a candidate-touched truth-partition path is mechanically distinguishable (changed=true) from an untouched one, in both X and R"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION C — execute: the candidate-runner seam and its REFUSAL
# ═══════════════════════════════════════════════════════════════════════════

count
WT_E="$(mk_wt)"
out="$(run_exec good --record "$RECORD" --repo-root "$REPO" --worktree "$WT_E")"
rc=$?
[ "$rc" -ne 0 ] || fail "C1: execute with NO runner and NO --live must refuse, got 0: $out"
[ "$(jq -r .outcome <<<"$out")" = "CANNOT_EVALUATE" ] || fail "C1: expected CANNOT_EVALUATE, got: $out"
case "$(jq -r .error <<<"$out")" in
  *"no candidate runner configured"*) ;;
  *) fail "C1: expected the refusal to name the missing seam, got: $out" ;;
esac
ok "C1 an UNSET candidate seam REFUSES — it does not fall back to a 'claude' on PATH"

count
[ ! -e "$CANARY" ] || fail "C2: the refusal in C1 still reached a 'claude' binary: $(cat "$CANARY")"
ok "C2 the refusal reached no binary at all (canary still absent)"

count
out="$(run_exec good --record "$RECORD" --repo-root "$REPO" --worktree "$WT_E" \
        --candidate-runner "bash $STUB" --live)"
rc=$?
[ "$rc" -ne 0 ] || fail "C3: --candidate-runner with --live must be refused, got 0: $out"
case "$(jq -r .error <<<"$out")" in
  *"mutually exclusive"*) ;;
  *) fail "C3: expected a mutual-exclusion refusal, got: $out" ;;
esac
ok "C3 --candidate-runner and --live are mutually exclusive"

count
out="$(run_exec good --record "$RECORD" --repo-root "$REPO" --worktree "$WT_E" \
        --candidate-runner "bash $STUB")"
rc=$?
[ "$rc" -eq 0 ] || fail "C4: a recorded runner should score cleanly, got $rc: $out"
[ "$(jq -r '.candidate.outcome' <<<"$out")" = "scored" ] || fail "C4: expected candidate.outcome scored, got: $out"
ok "C4 the recorded-runner seam drives the whole execute path with no network"

count
[ ! -e "$CANARY" ] || fail "C5: a stubbed execute reached a 'claude' binary: $(cat "$CANARY")"
ok "C5 a stubbed execute reached no 'claude' binary"

count
# The containment overlay and the key health check are BOTH consulted, on the
# stubbed path too. An absent overlay is candidate-session.sh's exit 3.
WT_OV="$(mk_wt)"
out="$(env CANDIDATE_SETTINGS="$WORK/no-such-overlay.json" \
      STUB_MODE=good MODEL_USAGE_RAW_DIR="$LAKE" \
      PROVIDER_ALLOWLIST_TEST_SEAM=1 PROVIDER_ALLOWLIST_COMMITTED_FILE="$ALLOW" \
      PROVIDER_ALLOWLIST_LOCAL_FILE="$NOLOCAL" PROVIDER_DISCLOSURE_LOG_FILE="$DLOG" \
      bash "$REPLAY" execute --record "$RECORD" --repo-root "$REPO" --worktree "$WT_OV" \
        --candidate-runner "bash $STUB")"
rc=$?
[ "$rc" -ne 0 ] || fail "C6: an absent containment overlay must refuse the run, got 0: $out"
case "$(jq -r .error <<<"$out")" in
  *"containment overlay is unusable"*) ;;
  *) fail "C6: expected the overlay refusal, got: $out" ;;
esac
ok "C6 execute routes through candidate-session.sh's overlay validator (absent overlay = refused)"

count
out="$(run_exec good --record "$RECORD" --repo-root "$REPO" --worktree "$WT_OV" \
        --provider not-a-registered-provider --candidate-runner "bash $STUB")"
rc=$?
[ "$rc" -ne 0 ] || fail "C6b: an unregistered provider must be refused by preflight, got 0: $out"
case "$(jq -r .error <<<"$out")" in
  *"preflight refused provider"*) ;;
  *) fail "C6b: expected the preflight refusal, got: $out" ;;
esac
ok "C6b execute routes through candidate-session.sh's provider health check"

# --- MUTATION PROOF: the refusal branch is load-bearing --------------------
count
MIRROR_C="$WORK/mirror-c"
mk_mirror "$MIRROR_C"
unlink_and_copy "$MIRROR_C/workflows/scripts/model-comparison/replay.sh"
mutate_file "$MIRROR_C/workflows/scripts/model-comparison/replay.sh" \
  'if [ -z "$runner" ] && [ "$live" -eq 0 ]; then' \
  'if [ -z "$runner" ] && [ "$live" -eq 0 ]; then runner="claude"; fi
  if false; then'
WT_MUT="$(mk_wt)"
env STUB_MODE=good MODEL_USAGE_RAW_DIR="$LAKE" \
    PROVIDER_ALLOWLIST_TEST_SEAM=1 PROVIDER_ALLOWLIST_COMMITTED_FILE="$ALLOW" \
    PROVIDER_ALLOWLIST_LOCAL_FILE="$NOLOCAL" PROVIDER_DISCLOSURE_LOG_FILE="$DLOG" \
    bash "$MIRROR_C/workflows/scripts/model-comparison/replay.sh" execute \
      --record "$RECORD" --repo-root "$REPO" --worktree "$WT_MUT" >/dev/null 2>&1
[ -e "$CANARY" ] || fail "C7: the mutation proof did not fire — removing the refusal should have reached the canary 'claude', so the canary cannot detect a real regression either"
rm -f "$CANARY"
rm -rf "$MIRROR_C"
ok "C7 MUTATION PROOF: removing the no-runner refusal DOES reach a bare 'claude' — the refusal is load-bearing and the canary can see it"

count
[ ! -e "$CANARY" ] || fail "C8: canary not reset after the mutation proof"
out="$(run_exec good --record "$RECORD" --repo-root "$REPO" --worktree "$(mk_wt)" \
        --candidate-runner "bash $STUB")"
[ "$(jq -r '.candidate.outcome' <<<"$out")" = "scored" ] || fail "C8: restored behaviour should score again, got: $out"
[ ! -e "$CANARY" ] || fail "C8: restored run reached a 'claude' binary"
ok "C8 RESTORED: the unmutated execute scores again and still reaches no binary"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION D — a schema-complete scored record
# ═══════════════════════════════════════════════════════════════════════════

count
WT_D="$(mk_wt)"
REC_OUT="$WORK/executed.json"
out="$(run_exec good --record "$RECORD" --repo-root "$REPO" --worktree "$WT_D" \
        --model recorded-baseline --repo Towheads/temperloop \
        --candidate-runner "bash $STUB" --out "$REC_OUT")"
rc=$?
[ "$rc" -eq 0 ] || fail "D1: expected a scored run, got $rc: $out"
# EVERY top-level key of the canonical schema is present in the produced
# record — asserted against `replay.sh schema` itself, never a hand-copied list.
missing="$(jq -rn --argjson s "$(bash "$REPLAY" schema)" --argjson r "$out" \
  '($s | keys_unsorted) - ($r | keys_unsorted) | join(",")' )"
[ -z "$missing" ] || fail "D1: the executed record is missing schema keys: $missing"
ok "D1 the executed record carries every top-level key of replay.sh's own schema"

count
[ "$(jq -r '.candidate.tokens.input' <<<"$out")" = "1200" ] || fail "D2: tokens.input not populated, got: $out"
[ "$(jq -r '.candidate.tokens.output' <<<"$out")" = "340" ] || fail "D2: tokens.output not populated, got: $out"
[ "$(jq -r '.candidate.tokens.cache_read' <<<"$out")" = "9000" ] || fail "D2: tokens.cache_read not populated, got: $out"
[ "$(jq -r '.candidate.tokens.cache_creation' <<<"$out")" = "120" ] || fail "D2: tokens.cache_creation not populated, got: $out"
ok "D2 TOKENS are populated from the candidate envelope, all four classes"

count
[ "$(jq -r '.candidate.duration_ms' <<<"$out")" = "4242" ] || fail "D3: duration_ms not taken from the envelope, got: $out"
ok "D3 DURATION is populated"

count
[ "$(jq -r '.score.gate_result.ran' <<<"$out")" = "true" ] || fail "D4: gate outcome not populated, got: $out"
[ "$(jq -r '.score.gate_result.passed' <<<"$out")" != "null" ] || fail "D4: gate outcome null, got: $out"
[ "$(jq -r '.score.diff.n.total' <<<"$out")" = "1" ] || fail "D5: diff not populated, got: $out"
[ "$(jq -r '.score.verdict' <<<"$out")" = "pass" ] || fail "D4: expected verdict pass, got: $out"
ok "D4 GATE OUTCOME and DIFF are populated in the same record"

count
[ "$(jq -r '.candidate.model' <<<"$out")" = "claude-recorded-candidate" ] \
  || fail "D5: model must be RESOLVED from the envelope's modelUsage key, got: $out"
[ "$(jq -r '.candidate.diff_ref' <<<"$out")" != "null" ] || fail "D5: diff_ref null, got: $out"
[ "$(jq -r '.worktree.path' <<<"$out")" = "$WT_D" ] || fail "D5: worktree path not recorded, got: $out"
ok "D5 the resolved model, the diff ref and the worktree are all recorded"

count
[ -f "$REC_OUT" ] || fail "D6: --out did not write a file"
[ "$(jq -r '.candidate.outcome' "$REC_OUT")" = "scored" ] || fail "D6: --out content wrong"
ok "D6 --out writes the same record to disk"

count
n_lake="$(cat "$LAKE"/model-usage-*.jsonl 2>/dev/null | jq -sr 'map(select(.seat == "replay-candidate")) | length')"
[ "${n_lake:-0}" -ge 1 ] || fail "D7: execute emitted no attribution record into the raw lake"
lake_line="$(cat "$LAKE"/model-usage-*.jsonl | jq -c 'select(.seat == "replay-candidate" and .usage_source == "cli-envelope")' | tail -1)"
[ -n "$lake_line" ] || fail "D7: no cli-envelope attribution record found"
[ "$(jq -r '.provider' <<<"$lake_line")" = "anthropic" ] || fail "D7: attribution record provider wrong: $lake_line"
[ "$(jq -r '.outcome_ref' <<<"$lake_line")" = "issue:4242" ] || fail "D7: attribution record outcome_ref wrong: $lake_line"
ok "D7 execute emits the attribution record through emit-model-usage.sh (no second stream)"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION E — integration-error vs scored, in every failure shape
# ═══════════════════════════════════════════════════════════════════════════

ERR_RECS="$WORK/err-records.jsonl"
: >"$ERR_RECS"

assert_integration_error() {  # <mode> <expected-stage> <label>
  local mode="$1" stage="$2" label="$3" o r
  count
  o="$(run_exec "$mode" --record "$RECORD" --repo-root "$REPO" --worktree "$(mk_wt)" \
        --candidate-runner "bash $STUB")"
  r=$?
  [ "$r" -eq 4 ] || fail "$label: expected exit 4 (integration error), got $r: $o"
  [ "$(jq -r '.candidate.outcome' <<<"$o")" = "integration-error" ] || fail "$label: outcome wrong: $o"
  [ "$(jq -r '.candidate.integration_error.stage' <<<"$o")" = "$stage" ] || fail "$label: stage wrong: $o"
  [ "$(jq -r '.score.scored' <<<"$o")" = "false" ] || fail "$label: score.scored must be false: $o"
  [ "$(jq -r '.score.verdict' <<<"$o")" = "null" ] || fail "$label: score.verdict must be null: $o"
  printf '%s\n' "$o" >>"$ERR_RECS"
  ok "$label"
}

assert_integration_error spawnfail   candidate-spawn        "E1 a non-zero candidate runner is an integration-error (exit 4), not a scored fail"
assert_integration_error badjson     envelope-parse         "E2 an unparseable envelope is an integration-error"
assert_integration_error vendorerror vendor-error           "E3 an envelope reporting is_error is an integration-error"
assert_integration_error nousage     envelope-usage-missing "E4 an envelope with no usable token block is an integration-error, never a scored record with a hole"

count
o="$(env REPLAY_CANDIDATE_TIMEOUT_SECS=1 STUB_MODE=hang MODEL_USAGE_RAW_DIR="$LAKE" \
      PROVIDER_ALLOWLIST_TEST_SEAM=1 PROVIDER_ALLOWLIST_COMMITTED_FILE="$ALLOW" \
      PROVIDER_ALLOWLIST_LOCAL_FILE="$NOLOCAL" PROVIDER_DISCLOSURE_LOG_FILE="$DLOG" \
      bash "$REPLAY" execute --record "$RECORD" --repo-root "$REPO" --worktree "$(mk_wt)" \
        --candidate-runner "bash $STUB")"
r=$?
[ "$r" -eq 4 ] || fail "E5: expected exit 4 on timeout, got $r: $o"
[ "$(jq -r '.candidate.integration_error.stage' <<<"$o")" = "candidate-timeout" ] || fail "E5: stage wrong: $o"
ok "E5 REPLAY_CANDIDATE_TIMEOUT_SECS is wired and a timed-out candidate is an integration-error"

count
[ "$(jq -r '.candidate.tokens' <<<"$o")" = "null" ] || fail "E6: an integration-error record must carry null tokens: $o"
[ "$(jq -r '.score.contamination_flags | type' <<<"$o")" = "array" ] || fail "E6: the score object shape must be stable across outcomes: $o"
ok "E6 an integration-error record is the SAME shape as a scored one, with every score figure null"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION E2 — the spawn-failure DETAIL carries a reason (temperloop#1553)
#
# These runs deliberately do NOT feed $ERR_RECS: section F's aggregate counts
# are pinned to the four shapes E1-E4 produced, and adding records here would
# move a figure that has nothing to do with what this section asserts.
# ═══════════════════════════════════════════════════════════════════════════

# detail_of <stub-mode> <label> — run execute, assert it is a candidate-spawn
# integration error, and leave the detail string in $DET.
#
# NOTE: this sets a GLOBAL rather than printing, and is therefore called
# directly, never as `$(detail_of …)`. `fail` is an `exit 1`, and an exit
# inside a command substitution kills only the SUBSHELL — the suite would
# sail past a failed precondition with an empty $DET and report a confusing
# downstream failure instead of the real one.
DET=""
detail_of() {
  local mode="$1" label="$2" o r
  o="$(run_exec "$mode" --record "$RECORD" --repo-root "$REPO" --worktree "$(mk_wt)" \
        --candidate-runner "bash $STUB")"
  r=$?
  [ "$r" -eq 4 ] || fail "$label: expected exit 4 (integration error), got $r: $o"
  [ "$(jq -r '.candidate.integration_error.stage' <<<"$o")" = "candidate-spawn" ] \
    || fail "$label: expected stage candidate-spawn, got: $o"
  DET="$(jq -r '.candidate.integration_error.detail' <<<"$o")"
}

# assert_no_trailing_colon <label> <detail>
assert_no_trailing_colon() {
  local label="$1" d="$2" trimmed
  trimmed="${d%"${d##*[![:space:]]}"}"   # right-trim whitespace
  case "$trimmed" in
    *:) fail "$label: the detail TRAILS OFF after a colon with no reason — this is the exact #1553 shape: [$d]" ;;
  esac
  [ -n "$trimmed" ] || fail "$label: the detail is empty"
}

count
detail_of spawnfail_stdout E7; D_STDOUT="$DET"
case "$D_STDOUT" in *"is_error=true"*) ;; *) fail "E7: detail must name the envelope's is_error, got: [$D_STDOUT]" ;; esac
case "$D_STDOUT" in *"subtype=error_during_execution"*) ;; *) fail "E7: detail must name the envelope's subtype, got: [$D_STDOUT]" ;; esac
case "$D_STDOUT" in *"api_error_status=529"*) ;; *) fail "E7: detail must name the envelope's api_error_status, got: [$D_STDOUT]" ;; esac
assert_no_trailing_colon "E7" "$D_STDOUT"
ok "E7 FIXTURE 1: a runner that exits non-zero with a claude-JSON error object on STDOUT and NOTHING on stderr yields a detail naming the stdout-side error (is_error, subtype, api_error_status)"

count
case "$D_STDOUT" in *"wrote nothing to stderr"*) ;; *) fail "E8: an empty stderr must be stated, not silently dropped, got: [$D_STDOUT]" ;; esac
ok "E8 the empty-stderr half is stated explicitly, so a reader knows WHICH stream carried the reason"

count
detail_of spawnfail_silent E9; D_SILENT="$DET"
case "$D_SILENT" in *"no diagnostic on either stream"*) ;; *) fail "E9: both-streams-empty must yield the explicit no-diagnostic wording, got: [$D_SILENT]" ;; esac
assert_no_trailing_colon "E9" "$D_SILENT"
ok "E9 FIXTURE 2: both streams empty yields an explicit 'produced no diagnostic on either stream' reason, never a detail ending at a colon"

count
detail_of spawnfail_verbose E10; D_VERBOSE="$DET"
[ "${#D_VERBOSE}" -le 1000 ] \
  || fail "E10: the detail is unbounded (${#D_VERBOSE} chars) — a verbose failure must not grow a record without limit"
case "$D_VERBOSE" in *"EEEE"*) ;; *) fail "E10: the stderr half went missing entirely, got: [$D_VERBOSE]" ;; esac
case "$D_VERBOSE" in *"RRRR"*) ;; *) fail "E10: the stdout half went missing entirely, got: [$D_VERBOSE]" ;; esac
ok "E10 a 5000-byte stderr AND a 5000-byte envelope still produce a BOUNDED detail (<=1000 chars) that carries both halves"

count
detail_of spawnfail E11; D_STDERR="$DET"
case "$D_STDERR" in *"vendor connection reset"*) ;; *) fail "E11: the stderr-only shape regressed, got: [$D_STDERR]" ;; esac
assert_no_trailing_colon "E11" "$D_STDERR"
ok "E11 the pre-existing stderr-only shape is unchanged — this widens the detail, it does not replace it"

# --- MUTATION PROOF: reading the envelope is load-bearing ------------------
count
MIRROR_E="$WORK/mirror-e"
mk_mirror "$MIRROR_E"
unlink_and_copy "$MIRROR_E/workflows/scripts/model-comparison/replay.sh"
mutate_file "$MIRROR_E/workflows/scripts/model-comparison/replay.sh" \
  '    _exec_integration_error "candidate-spawn" \
      "$(spawn_failure_detail "$run_rc" "$scratch_dir/stderr.txt" "$envelope_file" "the candidate runner")"' \
  '    _exec_integration_error "candidate-spawn" "the candidate runner exited $run_rc: $(head -c 400 "$scratch_dir/stderr.txt" 2>/dev/null)"'
mut_out="$(env STUB_MODE=spawnfail_stdout MODEL_USAGE_RAW_DIR="$LAKE" \
    PROVIDER_ALLOWLIST_TEST_SEAM=1 PROVIDER_ALLOWLIST_COMMITTED_FILE="$ALLOW" \
    PROVIDER_ALLOWLIST_LOCAL_FILE="$NOLOCAL" PROVIDER_DISCLOSURE_LOG_FILE="$DLOG" \
    bash "$MIRROR_E/workflows/scripts/model-comparison/replay.sh" execute \
      --record "$RECORD" --repo-root "$REPO" --worktree "$(mk_wt)" \
      --candidate-runner "bash $STUB")"
mut_detail="$(jq -r '.candidate.integration_error.detail' <<<"$mut_out")"
[ "$mut_detail" = "the candidate runner exited 1: " ] \
  || fail "E12 MUTATION PROOF did not fire — restoring the stderr-only detail should reproduce the blank #1553 shape verbatim, got: [$mut_detail]"
rm -rf "$MIRROR_E"
ok "E12 MUTATION PROOF: restoring the stderr-only detail reproduces the exact blank 'the candidate runner exited 1: ' the live batch recorded 28 times — reading the envelope is load-bearing"

count
detail_of spawnfail_stdout E13; D_RESTORED="$DET"
case "$D_RESTORED" in *"api_error_status=529"*) ;; *) fail "E13: RESTORED behaviour should name the reason again, got: [$D_RESTORED]" ;; esac
ok "E13 RESTORED: the unmutated execute names the stdout-side reason again"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION E3 — pre-flight model resolution (temperloop#1383)
#
# The whole point: a default-model (--model omitted) integration error has
# NO envelope to resolve a model from (a vendor-error returns before token
# extraction; a candidate-timeout produces no envelope at all), so the model
# must be known BEFORE the spawn — mirrored, read-only, from the
# CANDIDATE-SCOPED settings only: the containment overlay the child is
# spawned under (${CANDIDATE_SETTINGS:-candidate.settings.json}), then
# worktree-local, then worktree-project settings. NEVER the invoking host's
# user-global ~/.claude/settings.json — a hermetic fixture run must never
# have its records shaped by the operator's personal config (the
# environment-dependent-verdict class, temperloop#1552; a HOME fallback
# here flipped test_replay_batch.sh J2 on hosts with a configured default
# model). Every run below still uses the recorded STUB runner (never
# --live) — this is a plain file read, not a model call.
# ═══════════════════════════════════════════════════════════════════════════

count
WT_E14="$(mk_wt)"
mkdir -p "$WT_E14/.claude"
printf '{"model":"stub-resolved-project"}\n' >"$WT_E14/.claude/settings.json"
printf '{"model":"stub-resolved-local"}\n' >"$WT_E14/.claude/settings.local.json"
FAKEHOME_E14="$WORK/fakehome-e14"
mkdir -p "$FAKEHOME_E14/.claude"
printf '{"model":"stub-resolved-home-should-lose"}\n' >"$FAKEHOME_E14/.claude/settings.json"
out="$(HOME="$FAKEHOME_E14" run_exec spawnfail --record "$RECORD" --repo-root "$REPO" --worktree "$WT_E14" \
        --candidate-runner "bash $STUB")"
rc=$?
[ "$rc" -eq 4 ] || fail "E14: expected exit 4 (integration error), got $rc: $out"
[ "$(jq -r '.candidate.integration_error.stage' <<<"$out")" = "candidate-spawn" ] || fail "E14: stage wrong: $out"
[ "$(jq -r '.candidate.model' <<<"$out")" = "stub-resolved-local" ] \
  || fail "E14: a default-model integration error must carry the PRE-FLIGHT-resolved model (worktree settings.local.json outranking settings.json and HOME), got: $out"
ok "E14 a default-model (--model omitted) integration error resolves the model pre-flight from worktree settings, settings.local.json taking precedence over settings.json and HOME"

count
lake_line_e14="$(cat "$LAKE"/model-usage-*.jsonl | jq -c 'select(.seat == "replay-candidate" and .usage_source == "unavailable")' | tail -1)"
[ "$(jq -r '.model' <<<"$lake_line_e14")" = "stub-resolved-local" ] \
  || fail "E14b: the attribution-lake record must carry the SAME pre-flight-resolved model, got: $lake_line_e14"
ok "E14b the raw-lake attribution record (usage_source:unavailable) carries the resolved model too, not 'unknown'"

count
# E15 — HERMETICITY PIN: the user-global config is NEVER consulted. A HOME
# whose settings.json names a model, with no candidate-scoped settings
# anywhere, must resolve NOTHING — this is exactly the host-config leak
# that made test_replay_batch.sh J2 environment-dependent before the fix.
WT_E15="$(mk_wt)"
FAKEHOME_E15="$WORK/fakehome-e15"
mkdir -p "$FAKEHOME_E15/.claude"
printf '{"model":"host-personal-model-must-not-leak"}\n' >"$FAKEHOME_E15/.claude/settings.json"
out="$(HOME="$FAKEHOME_E15" run_exec spawnfail --record "$RECORD" --repo-root "$REPO" --worktree "$WT_E15" \
        --candidate-runner "bash $STUB")"
[ "$(jq -r '.candidate.model' <<<"$out")" = "null" ] \
  || fail "E15: the invoking host's user-global settings.json must NEVER shape a record — expected null model, got: $out"
ok "E15 HERMETICITY: a model named only in HOME settings.json is NOT resolved — host personal config never leaks into records"

count
# E15b — the candidate containment overlay IS a resolution source: it is the
# `--settings` file the child actually runs under (CLI-arg settings outrank
# project settings), and CANDIDATE_SETTINGS is the same env seam
# candidate-session.sh itself honours. Built from the real overlay (so the
# resolve/preflight containment checks still pass) plus a model key.
WT_E15B="$(mk_wt)"
OVERLAY_E15B="$WORK/candidate-settings-e15b.json"
jq '. + {model:"stub-resolved-overlay"}' "$MC_DIR/candidate.settings.json" >"$OVERLAY_E15B"
out="$(HOME="$FAKEHOME_E15" CANDIDATE_SETTINGS="$OVERLAY_E15B" \
        run_exec spawnfail --record "$RECORD" --repo-root "$REPO" --worktree "$WT_E15B" \
        --candidate-runner "bash $STUB")"
[ "$(jq -r '.candidate.model' <<<"$out")" = "stub-resolved-overlay" ] \
  || fail "E15b: with no worktree-level settings, resolution must fall back to the candidate containment overlay's own model key (the --settings file the child is spawned under), got: $out"
ok "E15b with no worktree-level settings, pre-flight resolution reads the candidate containment overlay (CANDIDATE_SETTINGS) — candidate-scoped, never host-scoped"

count
WT_E16="$(mk_wt)"
FAKEHOME_E16="$WORK/fakehome-e16-empty"
mkdir -p "$FAKEHOME_E16"
out="$(HOME="$FAKEHOME_E16" run_exec spawnfail --record "$RECORD" --repo-root "$REPO" --worktree "$WT_E16" \
        --candidate-runner "bash $STUB")"
[ "$(jq -r '.candidate.model' <<<"$out")" = "null" ] \
  || fail "E16: with NO settings anywhere (worktree or HOME), pre-flight resolution has nothing to resolve — 'unknown' must stand, got: $out"
lake_line_e16="$(cat "$LAKE"/model-usage-*.jsonl | jq -c 'select(.seat == "replay-candidate" and .usage_source == "unavailable")' | tail -1)"
[ "$(jq -r '.model' <<<"$lake_line_e16")" = "unknown" ] \
  || fail "E16b: with resolution genuinely impossible, the lake record must still fall back to the literal 'unknown', got: $lake_line_e16"
ok "E16 'unknown' remains ONLY where pre-flight resolution is genuinely impossible (no settings anywhere), usage_source:unavailable unchanged"

count
WT_E17="$(mk_wt)"
mkdir -p "$WT_E17/.claude"
printf '{"model":"stub-resolved-project-e17"}\n' >"$WT_E17/.claude/settings.json"
out="$(run_exec spawnfail --record "$RECORD" --repo-root "$REPO" --worktree "$WT_E17" \
        --provider openai --candidate-runner "bash $STUB")"
[ "$(jq -r '.candidate.model' <<<"$out")" = "null" ] \
  || fail "E17: a non-default provider's model vocabulary is NOT this host's claude settings — resolution must be skipped even though the worktree carries a 'model' key, got: $out"
ok "E17 pre-flight resolution is scoped to the default provider only; a non-default provider stays 'unknown' rather than borrowing an unrelated host model id"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION F — aggregate: integration errors excluded from quality
# ═══════════════════════════════════════════════════════════════════════════

# Built from REAL execute output, never hand-written records: two scored runs
# (one pass, one fail) and then the integration errors from section E.
SCORED_RECS="$WORK/scored-records.jsonl"
: >"$SCORED_RECS"
run_exec good    --record "$RECORD" --repo-root "$REPO" --worktree "$(mk_wt)" --candidate-runner "bash $STUB" >>"$SCORED_RECS"
run_exec notouch --record "$RECORD" --repo-root "$REPO" --worktree "$(mk_wt)" --candidate-runner "bash $STUB" >>"$SCORED_RECS"

count
base_agg="$(bash "$SCORE" aggregate --records-file "$SCORED_RECS")"
[ "$(jq -r '.quality.scored_n' <<<"$base_agg")" = "2" ] || fail "F1: expected 2 scored, got: $base_agg"
[ "$(jq -r '.quality.pass_n' <<<"$base_agg")" = "1" ] || fail "F1: expected 1 pass, got: $base_agg"
[ "$(jq -r '.quality.fail_n' <<<"$base_agg")" = "1" ] || fail "F1: expected 1 fail, got: $base_agg"
[ "$(jq -r '.quality.pass_rate' <<<"$base_agg")" = "0.5" ] || fail "F1: expected pass_rate 0.5, got: $base_agg"
ok "F1 aggregate rolls up real scored records (1 pass, 1 fail -> 0.5)"

count
MIXED="$WORK/mixed-records.jsonl"
cat "$SCORED_RECS" "$ERR_RECS" >"$MIXED"
mixed_agg="$(bash "$SCORE" aggregate --records-file "$MIXED")"
for f in scored_n pass_n fail_n pass_rate; do
  a="$(jq -r ".quality.$f" <<<"$base_agg")"
  b="$(jq -r ".quality.$f" <<<"$mixed_agg")"
  [ "$a" = "$b" ] || fail "F2: quality.$f MOVED when integration errors were added ($a -> $b). The metric is lying in exactly the way the acceptance forbids. mixed: $mixed_agg"
done
ok "F2 adding integration errors moves NO quality figure (scored_n/pass_n/fail_n/pass_rate all unchanged)"

count
[ "$(jq -r '.compatibility.integration_error_n' <<<"$mixed_agg")" = "4" ] \
  || fail "F3: expected the 4 integration errors under compatibility, got: $mixed_agg"
[ "$(jq -r '.compatibility.attempted_n' <<<"$mixed_agg")" = "6" ] || fail "F3: attempted_n wrong: $mixed_agg"
[ "$(jq -r '.compatibility.by_stage["candidate-spawn"]' <<<"$mixed_agg")" = "1" ] || fail "F3: by_stage wrong: $mixed_agg"
[ "$(jq -r '.compatibility.integration_error_n' <<<"$base_agg")" = "0" ] || fail "F3: base should carry no errors: $base_agg"
ok "F3 integration errors ARE reported, as their own compatibility metric with a per-stage breakdown"

# --- MUTATION PROOF: the exclusion is load-bearing -------------------------
count
MIRROR_F="$WORK/mirror-f"
mk_mirror "$MIRROR_F"
MUT_SCORE="$MIRROR_F/workflows/scripts/model-comparison/score.sh"
unlink_and_copy "$MUT_SCORE"
mutate_file "$MUT_SCORE" \
  '(map(select(.candidate.outcome == "scored"))) as $scored' \
  '(.) as $scored'
mut_agg="$(bash "$MUT_SCORE" aggregate --records-file "$MIXED")"
[ "$(jq -r '.quality.scored_n' <<<"$mut_agg")" != "$(jq -r '.quality.scored_n' <<<"$base_agg")" ] \
  || fail "F4: the mutation did not move scored_n — the exclusion cannot be shown load-bearing. mutant: $mut_agg"
[ "$(jq -r '.quality.pass_rate' <<<"$mut_agg")" != "$(jq -r '.quality.pass_rate' <<<"$base_agg")" ] \
  || fail "F4: the mutation did not move pass_rate — the exclusion cannot be shown load-bearing. mutant: $mut_agg"
rm -rf "$MIRROR_F"
ok "F4 MUTATION PROOF: removing the 'scored only' filter DOES move the quality figures — the exclusion is load-bearing"

count
restored_agg="$(bash "$SCORE" aggregate --records-file "$MIXED")"
[ "$(jq -r '.quality.pass_rate' <<<"$restored_agg")" = "0.5" ] || fail "F5: restored aggregate wrong: $restored_agg"
ok "F5 RESTORED: the unmutated aggregate reports 0.5 again"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION G — contamination flags, per the spike's enumerated traps
# ═══════════════════════════════════════════════════════════════════════════

count
WT_G="$(mk_wt)"
STUB_MODE=good bash "$STUB" /dev/null >/dev/null "$WT_G"
REC_DRIFT="$WORK/record-drift.json"
mk_record "$REC_DRIFT" --template 0000000000000000000000000000000000000000 \
  --flags '["residue-md-only","post-cut-edit-unverified","criterion-embedded-em-dash"]'
out="$(bash "$SCORE" score --repo-root "$REPO" --candidate-worktree "$WT_G" --record "$REC_DRIFT")"
flags="$(jq -r '.contamination_flags | sort | join(",")' <<<"$out")"
for want in residue-md-only post-cut-edit-unverified criterion-embedded-em-dash template-sha-drift; do
  case ",$flags," in *",$want,"*) ;; *) fail "G1: expected flag '$want' in '$flags': $out" ;; esac
done
ok "G1 corpus-time trap flags are carried through, and trap C (template-sha-drift) is detected here"

count
REC_NODRIFT="$WORK/record-nodrift.json"
mk_record "$REC_NODRIFT"
out2="$(bash "$SCORE" score --repo-root "$REPO" --candidate-worktree "$WT_G" --record "$REC_NODRIFT")"
flags2="$(jq -r '.contamination_flags | join(",")' <<<"$out2")"
case ",$flags2," in
  *",template-sha-drift,"*) fail "G2: template-sha-drift must NOT fire when the record's template matches the tree: $out2" ;;
esac
ok "G2 template-sha-drift does NOT fire when the trees agree (the flag discriminates)"

count
case ",$flags2," in
  *",acceptance-carries-literal-numbers,"*) ;;
  *) fail "G3: the '40 to 0' acceptance bullet must raise the literal-numbers flag: $out2" ;;
esac
[ "$(jq -r '.acceptance_results[1].carries_literal_numbers' <<<"$out2")" = "true" ] \
  || fail "G3: the per-criterion flag is not set: $out2"
[ "$(jq -r '.acceptance_results[0].carries_literal_numbers' <<<"$out2")" = "false" ] \
  || fail "G3: a literal-free criterion must NOT be flagged: $out2"
ok "G3 the spike's 40-vs-38 lesson is encoded: a bullet with hard numbers is flagged, one without is not"

count
[ "$(jq -r '.acceptance_results | length' <<<"$out2")" = "2" ] || fail "G4: acceptance carried through wrong: $out2"
[ "$(jq -r '.acceptance_results[0].mechanically_scored' <<<"$out2")" = "false" ] \
  || fail "G4: acceptance bullets must be declared NOT mechanically scored: $out2"
ok "G4 acceptance criteria ride the record verbatim, honestly marked as not mechanically scored"

count
# Trap B — formatting-only truth churn, detected rather than assumed absent.
git -C "$REPO" checkout -qb fmtonly "$BASE"
sed -e 's/^def /def  /' "$REPO/workflows/scripts/drain/scan_stub.py" >"$WORK/fmt.py"
printf 'def _is_command_expansion_turn(turn_text):\n\n    return False\n' >"$REPO/workflows/scripts/drain/scan_stub.py"
git -C "$REPO" add -A && git -C "$REPO" commit -qm "whitespace only"
FMT_HEAD="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" checkout -q master 2>/dev/null || git -C "$REPO" checkout -q main
REC_FMT="$WORK/record-fmt.json"
jq -c --arg h "$FMT_HEAD" '.head = $h' "$RECORD" >"$REC_FMT"
WT_F="$(mk_wt)"
STUB_MODE=notouch bash "$STUB" /dev/null >/dev/null "$WT_F"
out3="$(bash "$SCORE" score --repo-root "$REPO" --candidate-worktree "$WT_F" --record "$REC_FMT")"
case ",$(jq -r '.contamination_flags | join(",")' <<<"$out3")," in
  *",formatting-only-churn,"*) ;;
  *) fail "G5: a whitespace-only truth diff must raise formatting-only-churn: $out3" ;;
esac
[ "$(jq -r '.diff.n.files[0].truth_added_raw' <<<"$out3")" != "0" ] || fail "G5: the RAW truth diff should be non-empty: $out3"
[ "$(jq -r '.diff.n.files[0].truth_added' <<<"$out3")" = "0" ] || fail "G5: the whitespace-insensitive truth diff should be empty: $out3"
ok "G5 trap B is DETECTED: whitespace-only truth churn is flagged and the ignore-space diff is what is scored"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION H — the send-vs-log cross-check (the half #1250 deferred)
# ═══════════════════════════════════════════════════════════════════════════

# A clean slate for this section: its own lake and log.
HLAKE="$WORK/hlake"; mkdir -p "$HLAKE"
HLOG="$WORK/h-disclosure-log.jsonl"

h_validate() {
  env MODEL_USAGE_RAW_DIR="$HLAKE" \
      PROVIDER_ALLOWLIST_TEST_SEAM=1 \
      PROVIDER_ALLOWLIST_COMMITTED_FILE="$ALLOW" \
      PROVIDER_ALLOWLIST_LOCAL_FILE="$NOLOCAL" \
      PROVIDER_DISCLOSURE_LOG_FILE="$HLOG" \
      bash "${1:-$VALIDATOR}"
}
h_disclose() {  # <provider> <item_ref>
  env PROVIDER_ALLOWLIST_TEST_SEAM=1 \
      PROVIDER_ALLOWLIST_COMMITTED_FILE="$ALLOW" \
      PROVIDER_ALLOWLIST_LOCAL_FILE="$NOLOCAL" \
      PROVIDER_DISCLOSURE_LOG_FILE="$HLOG" \
      bash -c 'source "$1"; pa_disclose "$2" "$3"' _ "$MC_DIR/allowlist.sh" "$1" "$2"
}
h_send() {  # <provider-or-empty> <outcome-ref>
  local p="$1" ref="$2"
  if [ -z "$p" ]; then
    jq -cn --arg r "$ref" '{schema_version:"1", ts:"2026-08-08T00:00:00Z", session_id:null,
      repo:null, seat:"replay-candidate", model:"m", provider:null,
      usage_source:"unavailable", tokens:null, weighted_units:null,
      duration_ms:1, outcome_ref:$r}' >>"$HLAKE/model-usage-2026-08.jsonl"
  else
    jq -cn --arg p "$p" --arg r "$ref" '{schema_version:"1", ts:"2026-08-08T00:00:00Z",
      session_id:null, repo:null, seat:"replay-candidate", model:"m", provider:$p,
      usage_source:"cli-envelope", tokens:{input:1,output:1,cache_read:0,cache_creation:0},
      weighted_units:2, duration_ms:1, outcome_ref:$r}' >>"$HLAKE/model-usage-2026-08.jsonl"
  fi
}

count
out="$(h_validate)"; rc=$?
[ "$rc" -eq 0 ] || fail "H1: an empty lake + empty log must pass, got $rc: $out"
ok "H1 a checkout that never sent anything passes the cross-check"

count
h_send openai issue:4242
out="$(h_validate)"; rc=$?
[ "$rc" -ne 0 ] || fail "H2: a non-default-provider send with NO disclosure entry must FAIL the validator, got 0: $out"
case "$out" in
  *SEND-WITHOUT-DISCLOSURE*) ;;
  *) fail "H2: expected a SEND-WITHOUT-DISCLOSURE failure line, got: $out" ;;
esac
case "$out" in
  *"validate-provider-disclosure: FAIL"*) ;;
  *) fail "H2: expected the FAIL verdict line, got: $out" ;;
esac
ok "H2 a non-default-provider SEND with no disclosure-log entry FAILS the validator"

count
h_disclose openai issue:4242 || fail "H3: pa_disclose failed"
out="$(h_validate)"; rc=$?
[ "$rc" -eq 0 ] || fail "H3: adding the matching disclosure entry must restore green, got $rc: $out"
case "$out" in *"validate-provider-disclosure: OK"*) ;; *) fail "H3: expected OK, got: $out" ;; esac
ok "H3 RESTORED: adding the matching disclosure entry makes the same send pass"

count
# The join is on BOTH provider AND item_ref — a disclosure for a different
# item does not cover this send.
h_send openai issue:9999
out="$(h_validate)"; rc=$?
[ "$rc" -ne 0 ] || fail "H4: a send for an UNDISCLOSED item_ref must fail even when the provider was disclosed elsewhere: $out"
case "$out" in *"issue:9999"*) ;; *) fail "H4: expected the offending item_ref named, got: $out" ;; esac
h_disclose openai issue:9999 || fail "H4: pa_disclose failed"
out="$(h_validate)"; rc=$?
[ "$rc" -eq 0 ] || fail "H4: expected green after disclosing issue:9999, got: $out"
ok "H4 the cross-check joins on (provider, item_ref) — a disclosure for another item does not cover a send"

count
h_send anthropic issue:7777
out="$(h_validate)"; rc=$?
[ "$rc" -eq 0 ] || fail "H5: a DEFAULT-provider send needs no disclosure entry (ADR 0028 decision 3), got $rc: $out"
ok "H5 a default-provider send is not required to be disclosed"

count
h_send "" issue:8888
out="$(h_validate)"; rc=$?
[ "$rc" -eq 0 ] || fail "H6: an attribution-only record (no provider) carries no provider to check, got $rc: $out"
ok "H6 an attribution-only record with a null provider is not treated as a non-default send"

count
jq -cn '{schema_version:"1", ts:"2026-08-08T00:00:00Z", session_id:null, repo:null,
         seat:"replay-candidate", model:"m", provider:"openai",
         usage_source:"cli-envelope", tokens:{input:1,output:1,cache_read:0,cache_creation:0},
         weighted_units:2, duration_ms:1}' >>"$HLAKE/model-usage-2026-08.jsonl"
out="$(h_validate)"; rc=$?
[ "$rc" -ne 0 ] || fail "H7: a non-default send with no outcome_ref cannot be cross-referenced and must fail: $out"
case "$out" in *SEND-UNREFERENCED*) ;; *) fail "H7: expected SEND-UNREFERENCED, got: $out" ;; esac
ok "H7 a non-default send carrying no outcome_ref is a failure, not a silent skip"

# --- MUTATION PROOF: the cross-check is load-bearing -----------------------
count
# Rebuild a clean, undisclosed non-default send.
rm -f "$HLAKE"/model-usage-*.jsonl "$HLOG" "${HLOG%.jsonl}.watermark"
h_send openai issue:4242
out="$(h_validate)"; rc=$?
[ "$rc" -ne 0 ] || fail "H8 setup: expected RED before mutating"
MIRROR_H="$WORK/mirror-h"
mk_mirror "$MIRROR_H"
MUT_VAL="$MIRROR_H/workflows/scripts/validate-provider-disclosure.sh"
unlink_and_copy "$MUT_VAL"
mutate_file "$MUT_VAL" \
  'failures+=("SEND-WITHOUT-DISCLOSURE  $send_file' \
  '_mutation_proof_sink=("SEND-WITHOUT-DISCLOSURE  $send_file'
mut_out="$(h_validate "$MUT_VAL")"; mut_rc=$?
[ "$mut_rc" -eq 0 ] || fail "H8: the mutation did not flip the verdict to green (rc=$mut_rc) — the cross-check cannot be shown load-bearing: $mut_out"
rm -rf "$MIRROR_H"
ok "H8 MUTATION PROOF: suppressing the SEND-WITHOUT-DISCLOSURE failure turns the same input GREEN — the cross-check is what makes it red"

count
out="$(h_validate)"; rc=$?
[ "$rc" -ne 0 ] || fail "H9: the real validator must still be RED on the same input after the mutation proof: $out"
case "$out" in *SEND-WITHOUT-DISCLOSURE*) ;; *) fail "H9: expected the failure back, got: $out" ;; esac
h_disclose openai issue:4242 >/dev/null
out="$(h_validate)"; rc=$?
[ "$rc" -eq 0 ] || fail "H9: expected green after disclosing, got: $out"
ok "H9 RESTORED: the unmutated validator is red again on the undisclosed send and green once disclosed"

count
# execute's own DISCLOSE-BEFORE-SEND ordering, end to end: a non-default
# provider run leaves BOTH a disclosure entry and a send behind, and the
# validator is green on the pair.
E2ELAKE="$WORK/e2e-lake"; mkdir -p "$E2ELAKE"
E2ELOG="$WORK/e2e-disclosure-log.jsonl"
env STUB_MODE=good MODEL_USAGE_RAW_DIR="$E2ELAKE" \
    PROVIDER_ALLOWLIST_TEST_SEAM=1 PROVIDER_ALLOWLIST_COMMITTED_FILE="$ALLOW" \
    PROVIDER_ALLOWLIST_LOCAL_FILE="$NOLOCAL" PROVIDER_DISCLOSURE_LOG_FILE="$E2ELOG" \
    OPENAI_API_KEY="fixture-key-never-sent-anywhere" \
    bash "$REPLAY" execute --record "$RECORD" --repo-root "$REPO" --worktree "$(mk_wt)" \
      --provider openai --candidate-runner "bash $STUB" >"$WORK/e2e-record.json"
e2e_rc=$?
[ "$e2e_rc" -eq 0 ] || fail "H10: the openai run should score, got $e2e_rc"
[ "$(jq -r '.candidate.disclosed' "$WORK/e2e-record.json")" = "true" ] || fail "H10: the record must show it disclosed"
[ -s "$E2ELOG" ] || fail "H10: no disclosure entry was written before the send"
out="$(env MODEL_USAGE_RAW_DIR="$E2ELAKE" PROVIDER_ALLOWLIST_TEST_SEAM=1 \
      PROVIDER_ALLOWLIST_COMMITTED_FILE="$ALLOW" PROVIDER_ALLOWLIST_LOCAL_FILE="$NOLOCAL" \
      PROVIDER_DISCLOSURE_LOG_FILE="$E2ELOG" bash "$VALIDATOR")"
rc=$?
[ "$rc" -eq 0 ] || fail "H10: execute's own disclose-before-send output must satisfy the cross-check, got $rc: $out"
ok "H10 execute discloses BEFORE it sends, and its own output passes the cross-check end to end"

count
# And a non-default provider that the committed allowlist does NOT name is
# refused outright — no send, no record.
NARROW="$WORK/narrow-allow.txt"
printf 'anthropic\n' >"$NARROW"
out="$(env STUB_MODE=good MODEL_USAGE_RAW_DIR="$WORK/refused-lake" \
      PROVIDER_ALLOWLIST_TEST_SEAM=1 PROVIDER_ALLOWLIST_COMMITTED_FILE="$NARROW" \
      PROVIDER_ALLOWLIST_LOCAL_FILE="$NOLOCAL" PROVIDER_DISCLOSURE_LOG_FILE="$WORK/refused-log.jsonl" \
      OPENAI_API_KEY="fixture-key-never-sent-anywhere" \
      bash "$REPLAY" execute --record "$RECORD" --repo-root "$REPO" --worktree "$(mk_wt)" \
        --provider openai --candidate-runner "bash $STUB")"
rc=$?
[ "$rc" -ne 0 ] || fail "H11: a provider outside the committed allowlist must be refused, got 0: $out"
[ ! -s "$WORK/refused-log.jsonl" ] || fail "H11: nothing should have been disclosed"
[ ! -d "$WORK/refused-lake" ] || [ -z "$(ls -A "$WORK/refused-lake" 2>/dev/null)" ] || fail "H11: nothing should have been sent"
ok "H11 a disallowed provider is refused before any send — disclosure failure blocks the send"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION I — fail-closed: absent / unreadable / empty / malformed
# ═══════════════════════════════════════════════════════════════════════════

expect_cannot_evaluate() {  # <label> <cmd...>
  count
  local label="$1"; shift
  local o r
  o="$("$@" 2>"$WORK/ce-stderr.txt")"
  r=$?
  [ "$r" -ne 0 ] || fail "$label: expected non-zero, got 0: $o"
  [ "$(jq -r .outcome <<<"$o" 2>/dev/null)" = "CANNOT_EVALUATE" ] || fail "$label: expected CANNOT_EVALUATE on stdout, got: $o"
  case "$(cat "$WORK/ce-stderr.txt")" in
    *"CANNOT EVALUATE"*) ;;
    *) fail "$label: expected a distinct 'CANNOT EVALUATE' line on stderr, got: $(cat "$WORK/ce-stderr.txt")" ;;
  esac
  ok "$label"
}

WT_I="$(mk_wt)"
mkdir -p "$WORK/a-directory"
: >"$WORK/empty.json"
printf 'this is not json\n' >"$WORK/malformed.json"
jq -cn '{status:"eligible"}' >"$WORK/incomplete.json"
jq -c '.status = "rejected"' "$RECORD" >"$WORK/rejected.json"
jq -c '.base = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"' "$RECORD" >"$WORK/badbase.json"
jq -c '.base = null' "$RECORD" >"$WORK/nullbase.json"

expect_cannot_evaluate "I1  score: absent record"      bash "$SCORE" score --repo-root "$REPO" --candidate-worktree "$WT_I" --record "$WORK/nope.json"
expect_cannot_evaluate "I2  score: record is a dir"    bash "$SCORE" score --repo-root "$REPO" --candidate-worktree "$WT_I" --record "$WORK/a-directory"
expect_cannot_evaluate "I3  score: empty record"       bash "$SCORE" score --repo-root "$REPO" --candidate-worktree "$WT_I" --record "$WORK/empty.json"
expect_cannot_evaluate "I4  score: malformed record"   bash "$SCORE" score --repo-root "$REPO" --candidate-worktree "$WT_I" --record "$WORK/malformed.json"
expect_cannot_evaluate "I5  score: record missing base/head/buckets" bash "$SCORE" score --repo-root "$REPO" --candidate-worktree "$WT_I" --record "$WORK/incomplete.json"
expect_cannot_evaluate "I6  score: null base"          bash "$SCORE" score --repo-root "$REPO" --candidate-worktree "$WT_I" --record "$WORK/nullbase.json"
expect_cannot_evaluate "I7  score: unresolvable base"  bash "$SCORE" score --repo-root "$REPO" --candidate-worktree "$WT_I" --record "$WORK/badbase.json"
expect_cannot_evaluate "I8  score: absent worktree"    bash "$SCORE" score --repo-root "$REPO" --candidate-worktree "$WORK/no-such-wt" --record "$RECORD"
expect_cannot_evaluate "I9  score: worktree is not a git tree" bash "$SCORE" score --repo-root "$REPO" --candidate-worktree "$WORK/a-directory" --record "$RECORD"
expect_cannot_evaluate "I10 aggregate: absent file"    bash "$SCORE" aggregate --records-file "$WORK/nope.jsonl"
expect_cannot_evaluate "I11 aggregate: empty file"     bash "$SCORE" aggregate --records-file "$WORK/empty.json"
expect_cannot_evaluate "I12 aggregate: malformed line" bash "$SCORE" aggregate --records-file "$WORK/malformed.json"
expect_cannot_evaluate "I13 execute: absent record"    run_exec good --record "$WORK/nope.json" --repo-root "$REPO" --worktree "$WT_I" --candidate-runner "bash $STUB"
expect_cannot_evaluate "I14 execute: empty record"     run_exec good --record "$WORK/empty.json" --repo-root "$REPO" --worktree "$WT_I" --candidate-runner "bash $STUB"
expect_cannot_evaluate "I15 execute: malformed record" run_exec good --record "$WORK/malformed.json" --repo-root "$REPO" --worktree "$WT_I" --candidate-runner "bash $STUB"
expect_cannot_evaluate "I16 execute: rejected item"    run_exec good --record "$WORK/rejected.json" --repo-root "$REPO" --worktree "$WT_I" --candidate-runner "bash $STUB"
expect_cannot_evaluate "I17 execute: absent worktree"  run_exec good --record "$RECORD" --repo-root "$REPO" --worktree "$WORK/no-such-wt" --candidate-runner "bash $STUB"
expect_cannot_evaluate "I18 execute: base unresolvable in the worktree" run_exec good --record "$WORK/badbase.json" --repo-root "$REPO" --worktree "$WT_I" --candidate-runner "bash $STUB"

count
# A record with an aggregate-unknown candidate.outcome is refused rather than
# silently dropped from BOTH metrics (the shape that would quietly move a
# denominator).
jq -c '.candidate.outcome = "who-knows"' "$WORK/e2e-record.json" >"$WORK/unknown-outcome.jsonl"
o="$(bash "$SCORE" aggregate --records-file "$WORK/unknown-outcome.jsonl")"; r=$?
[ "$r" -ne 0 ] || fail "I19: an unknown candidate.outcome must be refused, got 0: $o"
[ "$(jq -r .outcome <<<"$o")" = "CANNOT_EVALUATE" ] || fail "I19: expected CANNOT_EVALUATE, got: $o"
ok "I19 aggregate refuses a record whose outcome it cannot classify, rather than dropping it from both metrics"

count
# The gate is UNRUNNABLE -> the whole score is CANNOT_EVALUATE, never a
# partial score computed from the diff half it could read.
o="$(bash "$SCORE" score --repo-root "$REPO" --candidate-worktree "$WT_I" --record "$RECORD" \
      --gate-relpath scripts/absent-gate.sh 2>"$WORK/ce2.txt")"; r=$?
[ "$r" -ne 0 ] || fail "I20: an unrunnable gate must not yield a score, got 0: $o"
[ "$(jq -r .outcome <<<"$o")" = "CANNOT_EVALUATE" ] || fail "I20: expected CANNOT_EVALUATE, got: $o"
[ "$(jq -r '.verdict // "absent"' <<<"$o")" = "absent" ] || fail "I20: a partial score leaked out: $o"
ok "I20 an unrunnable gate CANNOT_EVALUATEs the whole score — no partial score from the half it could read"

count
# ...and execute propagates that as "couldn't score" (exit 1, NO record),
# never as an integration error or a scored fail.
o="$(run_exec good --record "$RECORD" --repo-root "$REPO" --worktree "$(mk_wt)" \
      --candidate-runner "bash $STUB" --gate-relpath scripts/absent-gate.sh)"; r=$?
[ "$r" -eq 1 ] || fail "I21: expected exit 1 (CANNOT_EVALUATE), got $r: $o"
case "$o" in
  *'"candidate"'*) fail "I21: a record leaked out of a run that could not be scored: $o" ;;
esac
ok "I21 execute reports 'couldn't score' as exit 1 with NO record — distinct from exit 4 and exit 0"

count
# Unreadable send-lake file -> CANNOT EVALUATE, not a pass.
mkdir -p "$WORK/badlake/model-usage-2026-08.jsonl"
o="$(env MODEL_USAGE_RAW_DIR="$WORK/badlake" PROVIDER_ALLOWLIST_TEST_SEAM=1 \
      PROVIDER_ALLOWLIST_COMMITTED_FILE="$ALLOW" PROVIDER_ALLOWLIST_LOCAL_FILE="$NOLOCAL" \
      PROVIDER_DISCLOSURE_LOG_FILE="$WORK/badlake-log.jsonl" bash "$VALIDATOR" 2>&1)"; r=$?
[ "$r" -ne 0 ] || fail "I22: an unreadable send stream must abort, got 0: $o"
case "$o" in *"CANNOT EVALUATE"*) ;; *) fail "I22: expected CANNOT EVALUATE, got: $o" ;; esac
ok "I22 an unreadable attribution-stream file is CANNOT EVALUATE, never a cross-check pass"

count
mkdir -p "$WORK/malformedlake"
printf 'not json\n' >"$WORK/malformedlake/model-usage-2026-08.jsonl"
o="$(env MODEL_USAGE_RAW_DIR="$WORK/malformedlake" PROVIDER_ALLOWLIST_TEST_SEAM=1 \
      PROVIDER_ALLOWLIST_COMMITTED_FILE="$ALLOW" PROVIDER_ALLOWLIST_LOCAL_FILE="$NOLOCAL" \
      PROVIDER_DISCLOSURE_LOG_FILE="$WORK/malformedlake-log.jsonl" bash "$VALIDATOR" 2>&1)"; r=$?
[ "$r" -ne 0 ] || fail "I23: a malformed send line must abort, got 0: $o"
case "$o" in *"CANNOT EVALUATE"*) ;; *) fail "I23: expected CANNOT EVALUATE, got: $o" ;; esac
ok "I23 a malformed attribution line is CANNOT EVALUATE — the provider is undeterminable, so it is never skipped"

count
o="$(env MODEL_USAGE_RAW_DIR="$WORK/never-created-lake" PROVIDER_ALLOWLIST_TEST_SEAM=1 \
      PROVIDER_ALLOWLIST_COMMITTED_FILE="$ALLOW" PROVIDER_ALLOWLIST_LOCAL_FILE="$NOLOCAL" \
      PROVIDER_DISCLOSURE_LOG_FILE="$WORK/absent-lake-log.jsonl" bash "$VALIDATOR")"; r=$?
[ "$r" -eq 0 ] || fail "I24: an ABSENT lake dir is legal (nothing sent), got $r: $o"
ok "I24 an absent attribution lake is legal — 'nothing was sent' is an answer, not an inability"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION J — arg hygiene, under a BOUNDED timeout
# ═══════════════════════════════════════════════════════════════════════════

count
run_with_timeout 15 bash "$REPLAY" execute --record >/dev/null 2>&1
rc=$?
[ "$rc" -eq 2 ] || fail "J1: a trailing --record must exit 2 fast, got $rc"
ok "J1 a value-taking flag as the FINAL argument fails fast (exit 2), bounded, never spins"

count
run_with_timeout 15 bash "$SCORE" score --record >/dev/null 2>&1
rc=$?
[ "$rc" -eq 2 ] || fail "J2: score.sh trailing flag must exit 2, got $rc"
run_with_timeout 15 bash "$SCORE" gates --worktree >/dev/null 2>&1
[ "$?" -eq 2 ] || fail "J2: score.sh gates trailing flag must exit 2"
run_with_timeout 15 bash "$SCORE" aggregate --records-file >/dev/null 2>&1
[ "$?" -eq 2 ] || fail "J2: score.sh aggregate trailing flag must exit 2"
ok "J2 every score.sh subcommand fails fast on a trailing value-taking flag"

count
out="$(run_with_timeout 15 bash "$REPLAY" execute --record "$RECORD" --provider --live 2>&1)"
rc=$?
[ "$rc" -eq 2 ] || fail "J3: a flag-like value must be refused, not silently consumed, got $rc: $out"
case "$out" in *"flag-like"*) ;; *) fail "J3: expected the flag-like diagnostic, got: $out" ;; esac
ok "J3 a flag-like value ('--provider --live') is refused rather than consumed as the value"

count
out="$(run_with_timeout 15 bash "$SCORE" score --repo-root --record x 2>&1)"
rc=$?
[ "$rc" -eq 2 ] || fail "J4: score.sh must refuse a flag-like value, got $rc: $out"
ok "J4 score.sh refuses a flag-like value too"

count
run_with_timeout 15 bash "$REPLAY" execute --bogus-flag x >/dev/null 2>&1
[ "$?" -eq 2 ] || fail "J5: an unknown flag must exit 2"
run_with_timeout 15 bash "$SCORE" bogus-subcommand >/dev/null 2>&1
[ "$?" -eq 2 ] || fail "J5: an unknown subcommand must exit 2"
ok "J5 unknown flags and subcommands exit 2"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION K — the suite-wide no-live-call verdict
# ═══════════════════════════════════════════════════════════════════════════

count
if [ -e "$CANARY" ]; then
  fail "K1: A LIVE MODEL CALL WAS ATTEMPTED during this suite: $(cat "$CANARY")"
fi
ok "K1 NO LIVE MODEL CALL: the 'claude' canary on PATH was never invoked by any test in this suite"

count
# ...and the canary is genuinely capable of firing (C7 proved it does when the
# refusal is removed), so K1 is a measurement, not a tautology.
"$WORK/bin/claude" --self-test >/dev/null 2>&1
[ -e "$CANARY" ] || fail "K2: the canary itself does not work, so K1 proves nothing"
rm -f "$CANARY"
ok "K2 the canary is functional — K1 is a measurement, not a tautology"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION L — a RECORDED run does not seed the production lake (temperloop#1747)
# ═══════════════════════════════════════════════════════════════════════════
# emit-model-usage.sh resolves its output dir from ITS OWN location --
# `raw_root="$here/../.."` -- NOT from --repo-root. So a stubbed replay with no
# MODEL_USAGE_RAW_DIR writes into the lake of the checkout the SCRIPT lives in,
# which is how 36 fixture records reached this repo's own lake on 2026-08-14.
#
# That detail is why this test runs against a MIRRORED tree. The first draft
# asserted on the fixture repo's meta/data/raw and passed against a neutered
# guard -- because the records were never going there; they were going to the
# real checkout. It was measuring nothing, and it polluted the real lake to do
# it. The mirror makes `$here/../..` land inside $WORK, so the assertion is
# about the place the records would actually be written.
count
LMIRROR="$WORK/lake-mirror"
mkdir -p "$LMIRROR/workflows/scripts/model-comparison"
for _f in "$SCRIPTS_DIR"/*; do
  [ "$(basename "$_f")" = "model-comparison" ] && continue
  ln -s "$_f" "$LMIRROR/workflows/scripts/$(basename "$_f")"
done
for _f in "$MC_DIR"/*; do
  ln -s "$_f" "$LMIRROR/workflows/scripts/model-comparison/$(basename "$_f")"
done
LMIRROR_LAKE="$LMIRROR/meta/data/raw"

# Control FIRST: with the lake explicitly named, the mirrored driver DOES
# emit. Without this, L1 below would pass equally against a change that broke
# emission outright -- a different and worse bug.
MIRROR_LAKE_SET="$WORK/mirror-lake-set"; mkdir -p "$MIRROR_LAKE_SET"
env MODEL_USAGE_RAW_DIR="$MIRROR_LAKE_SET" STUB_MODE=good \
    PROVIDER_ALLOWLIST_TEST_SEAM=1 PROVIDER_ALLOWLIST_COMMITTED_FILE="$ALLOW" \
    PROVIDER_ALLOWLIST_LOCAL_FILE="$NOLOCAL" PROVIDER_DISCLOSURE_LOG_FILE="$DLOG" \
    bash "$LMIRROR/workflows/scripts/model-comparison/replay.sh" execute \
      --record "$RECORD" --repo-root "$REPO" --worktree "$(mk_wt)" \
      --candidate-runner "bash $STUB" >/dev/null 2>&1 || true
[ "$(cat "$MIRROR_LAKE_SET"/model-usage-*.jsonl 2>/dev/null | wc -l | tr -d ' ')" -ge 1 ] \
  || fail "L1: the control failed — a recorded run with the lake SET emitted nothing, so the unset case proves nothing"

# THE MEASUREMENT: same driver, same stub, lake UNSET.
rm -rf "$LMIRROR_LAKE"
env -u MODEL_USAGE_RAW_DIR STUB_MODE=good \
    PROVIDER_ALLOWLIST_TEST_SEAM=1 PROVIDER_ALLOWLIST_COMMITTED_FILE="$ALLOW" \
    PROVIDER_ALLOWLIST_LOCAL_FILE="$NOLOCAL" PROVIDER_DISCLOSURE_LOG_FILE="$DLOG" \
    bash "$LMIRROR/workflows/scripts/model-comparison/replay.sh" execute \
      --record "$RECORD" --repo-root "$REPO" --worktree "$(mk_wt)" \
      --candidate-runner "bash $STUB" >/dev/null 2>"$WORK/lakeguard.err" || true
leaked="$(cat "$LMIRROR_LAKE"/model-usage-*.jsonl 2>/dev/null | wc -l | tr -d ' ')"
[ "${leaked:-0}" = "0" ] \
  || fail "L1: a recorded run with MODEL_USAGE_RAW_DIR unset wrote ${leaked} record(s) into the checkout's own lake: $(cat "$LMIRROR_LAKE"/model-usage-*.jsonl 2>/dev/null | head -1)"
grep -F 'temperloop#1747' "$WORK/lakeguard.err" >/dev/null \
  || fail "L1: the refusal must be ANNOUNCED — a run that silently stops emitting is indistinguishable from one where emission broke: $(cat "$WORK/lakeguard.err")"
ok "L1 a recorded run with no explicit lake writes NOTHING into its own checkout's lake, announces the refusal, and still emits when a lake IS named"
# SECTION P — prompt_sha256 is invariant to per-leg incidentals (#1582)
# ═══════════════════════════════════════════════════════════════════════════
# The worktree path was hashed into prompt_sha256, and $wt is unique per leg by
# construction — so the hash differed between the two arms of EVERY pair, always,
# even on byte-identical item content. Measured on the 2026-08-14 A/A run:
# records=21, identical_sha=0, differing_sha=21. The field exists to tell a
# reader whether two legs got the same prompt; saturated at 100% noise it gave a
# false negative on every genuine divergence instead.

count
# P1 — THE ACCEPTANCE CHECK: the same record, replayed under two DIFFERENT
# worktree paths, produces the SAME hash.
pw1="$(mk_wt)"; pw2="$(mk_wt)"
[ "$pw1" != "$pw2" ] || fail "P1: the two fixture worktrees are the same path, so this proves nothing"
run_exec good --record "$RECORD" --repo-root "$REPO" --worktree "$pw1" \
  --candidate-runner "bash $STUB" >"$WORK/p1a.json" 2>/dev/null || true
run_exec good --record "$RECORD" --repo-root "$REPO" --worktree "$pw2" \
  --candidate-runner "bash $STUB" >"$WORK/p1b.json" 2>/dev/null || true
p_sha_a="$(jq -r '.candidate.prompt_sha256 // ""' "$WORK/p1a.json")"
p_sha_b="$(jq -r '.candidate.prompt_sha256 // ""' "$WORK/p1b.json")"
[ -n "$p_sha_a" ] || fail "P1: no prompt_sha256 on the first leg: $(head -c 200 "$WORK/p1a.json")"
[ "$p_sha_a" = "$p_sha_b" ] \
  || fail "P1: the same record under two worktree paths must hash identically, got $p_sha_a vs $p_sha_b — the per-leg path is still in the hash"
ok "P1 the same record replayed under two different worktree paths produces the SAME prompt_sha256"

count
# P2 — and the hash is still SENSITIVE. Hashing a constant would satisfy P1 and
# destroy the field, so every substantive input must still move it.
p_prev="$p_sha_a"
for fld in title scope issue; do
  MUT_REC="$WORK/rec-mut-$fld.json"
  jq --arg f "$fld" '.[$f] = "MUTATED-\($f)"' "$RECORD" >"$MUT_REC"
  run_exec good --record "$MUT_REC" --repo-root "$REPO" --worktree "$(mk_wt)" \
    --candidate-runner "bash $STUB" >"$WORK/p2.json" 2>/dev/null || true
  p_sha_m="$(jq -r '.candidate.prompt_sha256 // ""' "$WORK/p2.json")"
  [ -n "$p_sha_m" ] || fail "P2: no prompt_sha256 after mutating $fld"
  [ "$p_sha_m" != "$p_prev" ] \
    || fail "P2: mutating '$fld' did not change prompt_sha256 — the hash has lost its sensitivity"
done
MUT_REC="$WORK/rec-mut-acceptance.json"
jq '.acceptance = ["A completely different acceptance bullet."]' "$RECORD" >"$MUT_REC"
run_exec good --record "$MUT_REC" --repo-root "$REPO" --worktree "$(mk_wt)" \
  --candidate-runner "bash $STUB" >"$WORK/p2.json" 2>/dev/null || true
[ "$(jq -r '.candidate.prompt_sha256 // ""' "$WORK/p2.json")" != "$p_prev" ] \
  || fail "P2: mutating the acceptance list did not change prompt_sha256"
ok "P2 …and the hash still moves on title, scope, source and acceptance — sensitivity is preserved, not traded away"

count
# P3 — the prompt actually SENT still names the real worktree. This is a change
# to what is HASHED, never to what is sent: temperloop#1376 established that the
# prompt prose plus the spawn cwd is how isolation is communicated, so quietly
# dropping the path would break isolation to fix a diagnostic.
P_OUT="$WORK/prompt-sent.txt"
run_exec good --record "$RECORD" --repo-root "$REPO" --worktree "$pw1" \
  --candidate-runner "bash $STUB" --prompt-out "$P_OUT" >/dev/null 2>&1 || true
if [ -s "$P_OUT" ]; then
  grep -F "$pw1" "$P_OUT" >/dev/null \
    || fail "P3: the SENT prompt no longer names the real worktree path — isolation is communicated through that line"
  grep -F '<REPLAY_WORKTREE>' "$P_OUT" >/dev/null \
    && fail "P3: the canonical placeholder leaked into the prompt that is SENT"
  ok "P3 the prompt SENT still names the real worktree path, and the canonical placeholder never leaks into it"
else
  fail "P3: --prompt-out produced nothing, so the sent prompt could not be inspected"
fi
# SECTION T — score.sh leaves no scratch dir behind (temperloop#1724)
# ═══════════════════════════════════════════════════════════════════════════
# `scratch` is used as `x="$(scratch n.jsonl)"`, and a command substitution is a
# SUBSHELL. The lazy `_SCORE_TMPDIR=...` assignment therefore ran in the
# subshell and never reached the parent: the EXIT trap -- correctly installed,
# which is why this was invisible -- removed nothing, and every call made
# ANOTHER dir. One run of THIS suite leaked 174; 171,591 had accumulated on the
# host, taking inode use to 56%.
#
# Measured over the whole suite rather than one call, because the leak is per
# scratch call and a single-invocation check would understate it ~9x.
count
T_DIR="${TMPDIR:-/tmp}"
t_before="$(find "$T_DIR" -maxdepth 1 -name 'replay-score.*' 2>/dev/null | wc -l | tr -d ' ')"
run_exec good --record "$RECORD" --repo-root "$REPO" --worktree "$(mk_wt)" \
  --candidate-runner "bash $STUB" >/dev/null 2>&1 || true
run_exec good --record "$RECORD" --repo-root "$REPO" --worktree "$(mk_wt)" \
  --candidate-runner "bash $STUB" >/dev/null 2>&1 || true
t_after="$(find "$T_DIR" -maxdepth 1 -name 'replay-score.*' 2>/dev/null | wc -l | tr -d ' ')"
[ "$t_after" = "$t_before" ] \
  || fail "T1: two scored replays leaked $(( t_after - t_before )) replay-score scratch dir(s) under $T_DIR — the scratch dir is being created in a subshell again (temperloop#1724)"
ok "T1 two scored replays leave ZERO replay-score scratch dirs behind"

count
# The guard that keeps T1 from passing for the wrong reason: `scratch` must NOT
# create the dir itself. If it regains that ability the subshell bug returns and
# T1 goes quiet again, because each subshell would clean up its own dir only
# when it happens to be the last one.
grep -F '_score_ensure_tmpdir' "$MC_DIR/score.sh" >/dev/null \
  || fail "T2: score.sh has no _score_ensure_tmpdir — the parent-shell creation seam is gone"
awk '/^scratch\(\) \{/,/^\}/' "$MC_DIR/score.sh" | grep -F 'mktemp' >/dev/null \
  && fail "T2: scratch() creates the dir again — inside a \$( ) that assignment never reaches the parent (temperloop#1724)"
ok "T2 scratch() only READS the scratch dir; creation lives in the parent shell where the assignment survives"

echo
echo "test_replay_score.sh: $pass/$total checks passed"
[ "$pass" -eq "$total" ] || exit 1
