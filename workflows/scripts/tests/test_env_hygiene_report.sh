#!/usr/bin/env bash
#
# test_env_hygiene_report.sh — tests for workflows/scripts/env-hygiene-report.sh,
# the thin wrapper over env-reconcile.sh (temperloop#176).
#
# Exercises the wrapper as a real subprocess (it is directly invoked, like its
# sibling env-reconcile.sh) against:
#   1. a drift fixture (real throwaway git repos, stubbed gh/launchctl on PATH,
#      zero network) — --format entry passes through a well-formed
#      `### … Status: open` block; --format report passes through the
#      human-readable report.
#   2. a clean fixture — --format entry emits nothing; --format report says OK.
#   3. env-reconcile.sh MISSING (wrapper pointed at an empty scripts/ dir) —
#      fail-open: exit 0, nothing in entry mode, a one-line notice in report
#      mode.
#   4. env-reconcile.sh present but NOT executable (100644) — wrapper still
#      produces output via `bash`, doesn't fail.
#   5. usage error (bad --format) — exit 2.
#
# Usage: bash workflows/scripts/tests/test_env_hygiene_report.sh

set -uo pipefail

REPO="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$REPO/workflows/scripts/env-hygiene-report.sh"
RECONCILE_SRC="$REPO/workflows/scripts/build/env-reconcile.sh"

pass=0
fail=0
ok() { echo "  ok    $1"; pass=$((pass + 1)); }
fail_test() { echo "  FAIL  $1: $2"; fail=$((fail + 1)); }

assert_has() {
  local haystack="$1" needle="$2" name="$3"
  case "$haystack" in
    *"$needle"*) ok "$name" ;;
    *) fail_test "$name" "expected to find: $needle" ;;
  esac
}

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@test \
       GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@test

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# ── Fixture: an "upstream" + an operator checkout parked on a merged branch ──
git init -q --initial-branch=main "$TMP/upstream"
git -C "$TMP/upstream" commit -q --allow-empty -m init
git clone -q "$TMP/upstream" "$TMP/operator1"
OP1="$(cd "$TMP/operator1" && pwd -P)"
git -C "$OP1" checkout -q -b feature-parked
printf 'work\n' > "$OP1/p.txt"
git -C "$OP1" add p.txt
git -C "$OP1" commit -q -m "feature-parked: work"

mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'FAKE_GH'
#!/usr/bin/env bash
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  branch="$3"
  case " ${GH_MOCK_MERGED_BRANCHES:-} " in
    *" $branch "*) echo MERGED ;;
    *) echo OPEN ;;
  esac
  exit 0
fi
exit 1
FAKE_GH
chmod +x "$TMP/bin/gh"

cat > "$TMP/bin/launchctl" <<'FAKE_LAUNCHCTL'
#!/usr/bin/env bash
[ "$1" = "list" ] && exit 0
exit 0
FAKE_LAUNCHCTL
chmod +x "$TMP/bin/launchctl"

# JOB_SCRATCH_ROOT is pinned at a path that does not exist, so the job-scratch
# drift class (temperloop#1111) can never leak the RUNNING HOST's real
# ~/.claude/jobs backlog into these fixtures' drift counts — this suite would
# otherwise pass or fail depending on how much scratch the developer's machine
# happens to be carrying.
DRIFT_ENV=(
  PATH="$TMP/bin:$PATH"
  GH_MOCK_MERGED_BRANCHES="feature-parked"
  ENV_RECONCILE_CRON_CHECKOUTS="$TMP/no-such-cron-checkout"
  ENV_RECONCILE_OPERATOR_CHECKOUTS="$OP1"
  ENV_RECONCILE_LAUNCHD_DIRS="$TMP/no-such-launchd-dir"
  JOB_SCRATCH_ROOT="$TMP/no-such-jobs-root"
)
CLEAN_ENV=(
  PATH="$TMP/bin:$PATH"
  ENV_RECONCILE_CRON_CHECKOUTS="$TMP/no-such-cron-checkout"
  ENV_RECONCILE_OPERATOR_CHECKOUTS="$TMP/no-such-operator-checkout"
  ENV_RECONCILE_LAUNCHD_DIRS="$TMP/no-such-launchd-dir"
  JOB_SCRATCH_ROOT="$TMP/no-such-jobs-root"
)

# ── Test 1: drift fixture → --format entry passthrough ───────────────────────
echo "--- test 1: drift -> entry passthrough ---"
rc=0
entry="$(env "${DRIFT_ENV[@]}" bash "$SCRIPT" --format entry)" || rc=$?
[ "$rc" -eq 0 ] || fail_test "drift entry exit code" "got $rc"
assert_has "$entry" "· env reconcile ·" "entry carries env-reconcile heading"
assert_has "$entry" "Status:** open"    "entry carries Status: open"
assert_has "$entry" "PARKED_ON_MERGED:feature-parked" "entry lists the parked-checkout finding"

# ── Test 1b: drift fixture → --format report passthrough ─────────────────────
echo "--- test 1b: drift -> report passthrough ---"
rc=0
report="$(env "${DRIFT_ENV[@]}" bash "$SCRIPT" --format report)" || rc=$?
[ "$rc" -eq 0 ] || fail_test "drift report exit code" "got $rc"
assert_has "$report" "PARKED_ON_MERGED:feature-parked" "report lists the parked-checkout finding"
assert_has "$report" "DRIFT:"                          "report ends with a DRIFT summary"

# ── Test 2: clean fixture → nothing / OK ──────────────────────────────────────
echo "--- test 2: clean fixture ---"
rc=0
clean_entry="$(env "${CLEAN_ENV[@]}" bash "$SCRIPT" --format entry)" || rc=$?
[ "$rc" -eq 0 ] || fail_test "clean entry exit code" "got $rc"
if [ -z "$clean_entry" ]; then ok "clean --format entry emits nothing"; else fail_test "clean entry" "expected empty, got: $clean_entry"; fi

rc=0
clean_report="$(env "${CLEAN_ENV[@]}" bash "$SCRIPT" --format report)" || rc=$?
[ "$rc" -eq 0 ] || fail_test "clean report exit code" "got $rc"
assert_has "$clean_report" "OK" "clean report says OK"

# ── Test 3: env-reconcile.sh MISSING → fail-open ─────────────────────────────
echo "--- test 3: env-reconcile.sh missing ---"
EMPTY_ROOT="$(mktemp -d)"
mkdir -p "$EMPTY_ROOT/workflows/scripts/build"
cp "$SCRIPT" "$EMPTY_ROOT/workflows/scripts/env-hygiene-report.sh"
# deliberately do NOT copy env-reconcile.sh into build/

rc=0
missing_entry="$(bash "$EMPTY_ROOT/workflows/scripts/env-hygiene-report.sh" --format entry)" || rc=$?
[ "$rc" -eq 0 ] || fail_test "missing-reconcile entry exit code" "got $rc"
if [ -z "$missing_entry" ]; then ok "missing env-reconcile.sh: --format entry emits nothing, exit 0"; else fail_test "missing entry" "expected empty, got: $missing_entry"; fi

rc=0
missing_report="$(bash "$EMPTY_ROOT/workflows/scripts/env-hygiene-report.sh" --format report)" || rc=$?
[ "$rc" -eq 0 ] || fail_test "missing-reconcile report exit code" "got $rc"
assert_has "$missing_report" "env-reconcile.sh not found" "missing env-reconcile.sh: report notes it"
rm -rf "$EMPTY_ROOT"

# ── Test 4: env-reconcile.sh present but NOT executable ──────────────────────
echo "--- test 4: env-reconcile.sh not executable ---"
NOEXEC_ROOT="$(mktemp -d)"
mkdir -p "$NOEXEC_ROOT/workflows/scripts/build"
cp "$SCRIPT" "$NOEXEC_ROOT/workflows/scripts/env-hygiene-report.sh"
cp "$RECONCILE_SRC" "$NOEXEC_ROOT/workflows/scripts/build/env-reconcile.sh"
chmod 644 "$NOEXEC_ROOT/workflows/scripts/build/env-reconcile.sh"
# lib/merged-detect.sh is sourced by env-reconcile.sh; copy it along.
mkdir -p "$NOEXEC_ROOT/workflows/scripts/build/lib"
cp "$REPO/workflows/scripts/build/lib/merged-detect.sh" "$NOEXEC_ROOT/workflows/scripts/build/lib/merged-detect.sh"

rc=0
noexec_report="$(env "${CLEAN_ENV[@]}" bash "$NOEXEC_ROOT/workflows/scripts/env-hygiene-report.sh" --format report)" || rc=$?
[ "$rc" -eq 0 ] || fail_test "not-executable report exit code" "got $rc"
assert_has "$noexec_report" "OK" "not-executable env-reconcile.sh still runs via bash fallback"
rm -rf "$NOEXEC_ROOT"

# ── Test 5: usage error → exit 2 ──────────────────────────────────────────────
echo "--- test 5: usage error ---"
rc=0
bash "$SCRIPT" --format bogus >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 2 ]; then
  ok "unknown --format exits 2"
else
  fail_test "usage error" "expected exit 2, got $rc"
fi

# ── Tally ─────────────────────────────────────────────────────────────────────
echo "---"
echo "pass: $pass | fail: $fail"
if [ "$fail" -ne 0 ]; then
  echo "test_env_hygiene_report: FAIL"
  exit 1
fi
echo "test_env_hygiene_report: OK"
