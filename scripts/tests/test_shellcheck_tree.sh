#!/usr/bin/env bash
# Regression tests for scripts/shellcheck-tree.sh (temperloop#2164).
#
# What this backstops: `make shellcheck` was one serial shellcheck process over
# the whole tree and is pinned to the gate pool's serial lane, so its full wall
# time sat on the critical path. It is now a bounded fan-out — and a fanned-out
# linter has exactly three ways to go wrong silently, one per test group below:
#
#   1. It reports DIFFERENT findings from the serial pass. This is not
#      hypothetical: shellcheck follows a `source`d file only when that file is
#      also an input on the SAME command line, so a naive shard changes the
#      verdict. T4 pins both halves of that — the naive shard really does drift,
#      and the shipped `-x` invocation does not.
#   2. It loses a verdict — a failing file, or a chunk that died, that does not
#      turn the target red (T2, T3). A silent green here is the worst outcome
#      available to a lint gate.
#   3. It reorders or interleaves its report, so a human diff is unreadable even
#      when the findings match (T1).
#
# T1-T3 and T5-T6 use a STUB linter and are hermetic and instant. T4 needs the
# REAL pinned binary and SKIPS cleanly (exit 0) when it cannot be provisioned —
# the same offline posture as scripts/tests/test_ensure_shellcheck.sh.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/scripts/shellcheck-tree.sh"
PASS=0
FAIL=0

pass() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# Fixtures: a stub linter that names every file it was handed (so ORDER is
# directly observable) and fails on any file called bad.sh, plus a small tree.
# ---------------------------------------------------------------------------
STUB="$TMP/stub-linter"
cat > "$STUB" <<'STUB'
#!/usr/bin/env bash
rc=0
for a in "$@"; do
  case "$a" in *.sh) ;; *) continue ;; esac
  printf 'CHECK %s\n' "$a"
  case "$a" in */bad.sh | bad.sh) rc=1 ;; esac
done
exit "$rc"
STUB
chmod +x "$STUB"

TREE="$TMP/tree"
mkdir -p "$TREE/a" "$TREE/b/c" "$TREE/tests"
i=0
while [ "$i" -lt 40 ]; do
  printf '#!/usr/bin/env bash\ntrue\n' > "$TREE/a/f$i.sh"
  printf '#!/usr/bin/env bash\ntrue\n' > "$TREE/b/c/g$i.sh"
  i=$((i + 1))
done

# The file list in find order — the reference the runner's output must match.
tree_files() {
  (cd "$TREE" && find . -name '*.sh' -not -path './.git/*' -not -path '*/tests/*' -print0)
}

serial_reference() {
  ref_files=()
  while IFS= read -r -d '' f; do ref_files+=("$f"); done < <(tree_files)
  (cd "$TREE" && "$STUB" -x -e SC1091 "${ref_files[@]}")
}

# ---------------------------------------------------------------------------
# T1 — the fan-out's report is BYTE-IDENTICAL to one serial invocation over the
# same file list, at several widths. Ordered reassembly, never interleaving.
# ---------------------------------------------------------------------------
serial_reference > "$TMP/ref.out" 2>&1
for jobs in 1 2 4 8; do
  bash "$SCRIPT" --root "$TREE" --shellcheck "$STUB" --jobs "$jobs" > "$TMP/par.$jobs.out" 2>&1
  if diff -q "$TMP/ref.out" "$TMP/par.$jobs.out" >/dev/null 2>&1; then
    pass "jobs=$jobs: report byte-identical to the serial reference"
  else
    fail "jobs=$jobs: report DIFFERS from the serial reference"
    diff "$TMP/ref.out" "$TMP/par.$jobs.out" | head -10 | sed 's/^/      /'
  fi
done

if [ "$(wc -l < "$TMP/ref.out")" -eq 80 ]; then
  pass "reference covers all 80 fixture files (the diff above is not vacuous)"
else
  fail "reference covered $(wc -l < "$TMP/ref.out") files, expected 80"
fi

# ---------------------------------------------------------------------------
# T2 — EXIT-CODE SEMANTICS. One failing file anywhere must turn the whole run
# red, at every width. The file is planted LAST so it lands in a late chunk —
# the case a naive `xargs -P` fan-out is most likely to swallow.
# ---------------------------------------------------------------------------
printf '#!/usr/bin/env bash\ntrue\n' > "$TREE/b/c/bad.sh"
for jobs in 1 2 4 8; do
  bash "$SCRIPT" --root "$TREE" --shellcheck "$STUB" --jobs "$jobs" > "$TMP/bad.$jobs.out" 2>&1
  rc=$?
  if [ "$rc" -ne 0 ]; then
    pass "jobs=$jobs: a failing file turns the run red (exit $rc)"
  else
    fail "jobs=$jobs: a failing file was SWALLOWED — run exited 0"
  fi
done
if grep -Fq './b/c/bad.sh' "$TMP/bad.4.out"; then
  pass "the failing file's own output is still reported, not dropped"
else
  fail "the failing file's output was dropped from the report"
fi
rm -f "$TREE/b/c/bad.sh"

# ---------------------------------------------------------------------------
# T3 — FAIL-CLOSED on a LOST VERDICT. A chunk that dies without recording a
# status must fail the run, never pass it. Simulated by a linter that kills its
# own parent (the shard) before the shard can write its status file.
# ---------------------------------------------------------------------------
KILLER="$TMP/killer-linter"
cat > "$KILLER" <<'KILLER'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in *.sh) ;; *) continue ;; esac
  case "$a" in */a/f0.sh | ./a/f0.sh) kill -9 "$PPID" 2>/dev/null; sleep 5 ;; esac
  printf 'CHECK %s\n' "$a"
done
exit 0
KILLER
chmod +x "$KILLER"
bash "$SCRIPT" --root "$TREE" --shellcheck "$KILLER" --jobs 4 > "$TMP/lost.out" 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then
  pass "a chunk that dies without a status fails the run (exit $rc), never passes"
else
  fail "a LOST VERDICT passed the run — silent green"
fi
if grep -Fq 'verdict lost' "$TMP/lost.out"; then
  pass "the lost verdict is reported out loud, not just counted"
else
  fail "the lost verdict was not named in the output"
fi

# ---------------------------------------------------------------------------
# T5 — an empty tree is a clean pass, not a crash or a spurious failure.
# ---------------------------------------------------------------------------
mkdir -p "$TMP/empty"
out="$(bash "$SCRIPT" --root "$TMP/empty" --shellcheck "$STUB" --jobs 4 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
  pass "an empty tree exits 0 with no output"
else
  fail "empty tree: exit $rc, output [$out]"
fi

# ---------------------------------------------------------------------------
# T6 — the `*/tests/*` exclusion is PRESERVED verbatim. Narrowing it is tracked
# separately (temperloop#2191) and must not ride in on a performance change: a
# planted failing file under tests/ must stay unlinted and the run stay green.
# ---------------------------------------------------------------------------
printf '#!/usr/bin/env bash\ntrue\n' > "$TREE/tests/bad.sh"
out="$(bash "$SCRIPT" --root "$TREE" --shellcheck "$STUB" --jobs 4 2>&1)"
rc=$?
if [ "$rc" -eq 0 ]; then
  case "$out" in
    *tests/bad.sh*) fail "*/tests/* exclusion LOST — a tests/ file was linted" ;;
    *) pass "*/tests/* exclusion preserved (a failing tests/ file is not linted)" ;;
  esac
else
  fail "*/tests/* exclusion LOST — a failing tests/ file turned the run red"
fi
rm -f "$TREE/tests/bad.sh"

# ---------------------------------------------------------------------------
# T4 — THE INVOCATION-INDEPENDENCE INVARIANT, against the REAL pinned linter.
#
# This is the one property the whole design rests on, so it is pinned in BOTH
# directions: the naive shard (no -x) MUST drift from the whole-tree run, and
# the shipped invocation (-x, as SHELLCHECK_TREE_FLAGS spells it) MUST NOT. The
# positive half alone would still pass if shellcheck ever stopped doing
# cross-file source resolution, and the test would then be proving nothing.
# ---------------------------------------------------------------------------
if ! BIN="$(bash "$ROOT/scripts/ensure-shellcheck.sh" 2>/dev/null)"; then
  echo "  SKIP: could not provision the pinned shellcheck (offline, cold cache)"
  echo "  ---"
  echo "  PASS=$PASS FAIL=$FAIL (T4 skipped)"
  [ "$FAIL" -eq 0 ] || exit 1
  exit 0
fi

SRCTREE="$TMP/srctree"
mkdir -p "$SRCTREE"
cat > "$SRCTREE/main.sh" <<'MAIN'
#!/usr/bin/env bash
MYVAR="x"
. ./lib.sh
MAIN
cat > "$SRCTREE/lib.sh" <<'LIB'
#!/usr/bin/env bash
echo "${MYVAR:-}"
LIB

whole="$(cd "$SRCTREE" && "$BIN" -e SC1091 ./main.sh ./lib.sh 2>&1)"
naive="$(cd "$SRCTREE" && "$BIN" -e SC1091 ./main.sh 2>&1)"
sharded_x="$(cd "$SRCTREE" && "$BIN" -x -e SC1091 ./main.sh 2>&1)"

case "$whole" in
  *SC2034*) fail "fixture is wrong: the whole-tree run already reports SC2034" ;;
  *) pass "whole-tree run: no SC2034 (the sourced file is followed as an input)" ;;
esac
case "$naive" in
  *SC2034*) pass "naive shard WITHOUT -x really does drift (SC2034 appears) — the hazard is live" ;;
  *) fail "naive shard did not drift; this test can no longer discriminate" ;;
esac
case "$sharded_x" in
  *SC2034*) fail "-x did NOT restore invocation-independence — sharding would change findings" ;;
  *) pass "-x restores invocation-independence: a lone file matches the whole-tree verdict" ;;
esac

# ...and that the shipped runner is the invocation just proven safe, not a
# third variant that merely resembles it.
flags_line="$(grep -n 'SHELLCHECK_TREE_FLAGS=' "$SCRIPT" | head -1)"
case "$flags_line" in
  *'(-x -e SC1091)'*) pass "the shipped runner really passes -x -e SC1091" ;;
  *) fail "SHELLCHECK_TREE_FLAGS is not (-x -e SC1091): [$flags_line]" ;;
esac

echo "  ---"
echo "  PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
