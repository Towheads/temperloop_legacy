#!/usr/bin/env bash
#
# Fixture tests for check-gate-paths.sh — the completeness + reachability lint
# over the diff-scoped gate-selection map (temperloop#1024).
#
# The live gate (`bash workflows/scripts/config/check-gate-paths.sh`, registered
# in scripts/quality-gates.sh) only ever exercises the GREEN arm against this
# repo's own tree. Detection has to be proven deterministically here, or the
# guarantee the map's safety story rests on ships unproven — the same
# live-check-then-fixture-tests shape as check-setting-registry.sh and
# check-personal-token-denylist.sh.
#
# Coverage — each case drives the script through its two fixture seams
# (GATE_PATHS_GATE_LIST_FILE, GATE_PATHS_TRACKED_FILE) so no case depends on
# the real tree:
#   1. GREEN on a well-formed, complete, reachable map.
#   2. RED   on a kernel gate with no row (completeness).
#   3. RED   on a row naming a gate that does not exist (stale row).
#   4. RED   on a row whose globs match nothing (UNREACHABLE — the
#            anti-silent-green check the issue's constraint names).
#   5. RED   on a duplicate key.
#   6. RED   on a row with no TAB.
#   7. RED   on a literal (wildcard-free) path that does not exist.
#   8. GREEN when a WILDCARD matches nothing but the row is otherwise
#            reachable (an optional surface like scripts/quality-gates.d/**).
#   9. GREEN for an ALWAYS row (no globs to reach).
#  10. GREEN for `ALL` / `none` pseudo-keys, which are never required to name
#            a gate.
#  11. Vendoring-consumer arm: a stale row SKIPS instead of failing.
#  12. Vendoring-consumer arm reaches CHECK 4 as well — an absent gate's row is
#            exempt from the literal-path and reachability checks too, not just
#            from checks 2/3 (temperloop#1144). 12b: the same map stays hard in
#            the kernel's own checkout, so the exemption is keyed on consumer
#            mode, never on the map's content.
#  13. RED   in a consumer for an unreachable row whose gate DOES exist in that
#            tree — the #1144 exemption is not a blanket bypass.
#  14. Vendoring-consumer resolution against the vendored subtree prefix (14b:
#            the prefix is a seam; 14c: the kernel's own checkout never uses it).
#  15. GREEN against the REAL tree — the live gate's own invocation.
#  16. RED   on a gate command that begins neither `make ` nor `bash `
#            (CHECK 5, temperloop#1650) — the shape build-level.mjs's
#            ordinal->name filter silently drops, shifting every later ordinal.
#            16b: the same list passes once the gate is respelled.
#  18. A ROW-LESS map still REPORTS instead of aborting — `map has no usable
#            rows` is recorded, not fatal, so the completeness walk runs on an
#            empty KEY_BY_INDEX. Under bash 3.2 (macOS `/bin/bash`) that
#            expansion is an unbound-variable abort unless it is guarded
#            (temperloop#2194). 18a is the static anti-regression, 18b the
#            runtime probe under the oldest bash on the host.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$(cd "$HERE/.." && pwd)"
SCRIPT="$CONFIG_DIR/check-gate-paths.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat >"$TMP/gates.txt" <<'EOF'
[kernel]  make test-alpha
[kernel]  make test-beta
[kernel]  bash tools/gamma.sh
[overlay] make test-overlay-only
[skipped] test_something.sh — surface absent
EOF

cat >"$TMP/tracked.txt" <<'EOF'
Makefile
LICENSE
docs/intro.md
docs/adr/0001.md
src/alpha.sh
src/beta/thing.sh
tools/gamma.sh
kernel/src/alpha-vendored-only.sh
EOF

run_check() {  # run_check <map-file> [extra env assignments...]
  env GATE_PATHS_FILE="$1" \
      GATE_PATHS_GATE_LIST_FILE="$TMP/gates.txt" \
      GATE_PATHS_TRACKED_FILE="$TMP/tracked.txt" \
      GATE_PATHS_ROOT="$TMP" \
      "${@:2}" \
      bash "$SCRIPT" 2>&1
}

# --- 1. green ----------------------------------------------------------------
cat >"$TMP/good.tsv" <<'EOF'
# a good map
ALL	Makefile
none	LICENSE
make test-alpha	src/alpha.sh
make test-beta	src/beta/**
bash tools/gamma.sh	ALWAYS
EOF
out="$(run_check "$TMP/good.tsv")" || fail "1: a well-formed map should pass, got:
$out"
case "$out" in *'[ok]'*) : ;; *) fail "1: expected an [ok] line, got: $out" ;; esac
echo "PASS: 1 a well-formed, complete, reachable map passes"

# --- 2. missing row (completeness) -------------------------------------------
cat >"$TMP/incomplete.tsv" <<'EOF'
ALL	Makefile
make test-alpha	src/alpha.sh
bash tools/gamma.sh	ALWAYS
EOF
if out="$(run_check "$TMP/incomplete.tsv")"; then
  fail "2: a gate with no row must FAIL, got:
$out"
fi
case "$out" in *'make test-beta'*) : ;; *) fail "2: the failure must name the unmapped gate, got: $out" ;; esac
echo "PASS: 2 a kernel gate with no row fails, naming the gate"

# --- 3. stale row ------------------------------------------------------------
cat >"$TMP/stale.tsv" <<'EOF'
ALL	Makefile
make test-alpha	src/alpha.sh
make test-beta	src/beta/**
bash tools/gamma.sh	ALWAYS
make test-deleted	docs/**
EOF
if out="$(run_check "$TMP/stale.tsv")"; then
  fail "3: a row naming a non-existent gate must FAIL, got:
$out"
fi
case "$out" in *'stale row'*) : ;; *) fail "3: the failure should say stale row, got: $out" ;; esac
echo "PASS: 3 a row naming a gate that no longer exists fails"

# --- 4. unreachable row ------------------------------------------------------
cat >"$TMP/unreachable.tsv" <<'EOF'
ALL	Makefile
make test-alpha	src/alpha.sh
make test-beta	nowhere/at/all/**
bash tools/gamma.sh	ALWAYS
EOF
if out="$(run_check "$TMP/unreachable.tsv")"; then
  fail "4: a row whose globs match no tracked path must FAIL, got:
$out"
fi
case "$out" in *'unreachable row'*) : ;; *) fail "4: the failure should say unreachable row, got: $out" ;; esac
case "$out" in *'make test-beta'*) : ;; *) fail "4: the failure must name the orphaned gate, got: $out" ;; esac
echo "PASS: 4 a gate orphaned behind an unmatchable glob fails the build"

# --- 5. duplicate key --------------------------------------------------------
cat >"$TMP/dup.tsv" <<'EOF'
ALL	Makefile
make test-alpha	src/alpha.sh
make test-alpha	src/beta/**
make test-beta	src/beta/**
bash tools/gamma.sh	ALWAYS
EOF
if out="$(run_check "$TMP/dup.tsv")"; then
  fail "5: a duplicate key must FAIL, got:
$out"
fi
case "$out" in *'duplicate key'*) : ;; *) fail "5: the failure should say duplicate key, got: $out" ;; esac
echo "PASS: 5 a duplicate key fails"

# --- 6. no TAB ---------------------------------------------------------------
cat >"$TMP/notab.tsv" <<'EOF'
ALL	Makefile
make test-alpha src/alpha.sh
make test-beta	src/beta/**
bash tools/gamma.sh	ALWAYS
EOF
if out="$(run_check "$TMP/notab.tsv")"; then
  fail "6: a row with no TAB must FAIL, got:
$out"
fi
case "$out" in *'no TAB'*) : ;; *) fail "6: the failure should say no TAB, got: $out" ;; esac
echo "PASS: 6 a row with no TAB separator fails"

# --- 7. literal path that does not exist -------------------------------------
cat >"$TMP/typo.tsv" <<'EOF'
ALL	Makefile
make test-alpha	src/alpha.sh src/alhpa-typo.sh
make test-beta	src/beta/**
bash tools/gamma.sh	ALWAYS
EOF
if out="$(run_check "$TMP/typo.tsv")"; then
  fail "7: a literal path that does not exist must FAIL, got:
$out"
fi
case "$out" in *'src/alhpa-typo.sh'*) : ;; *) fail "7: the failure must name the typo'd path, got: $out" ;; esac
echo "PASS: 7 a literal (wildcard-free) path that does not exist fails as a typo"

# --- 8. an unmatched WILDCARD is tolerated when the row is otherwise reachable
cat >"$TMP/optional.tsv" <<'EOF'
ALL	Makefile scripts/quality-gates.d/**
make test-alpha	src/alpha.sh
make test-beta	src/beta/**
bash tools/gamma.sh	ALWAYS
EOF
out="$(run_check "$TMP/optional.tsv")" || fail "8: an optional-surface wildcard on an otherwise-reachable row should pass, got:
$out"
echo "PASS: 8 a wildcard naming an absent optional surface passes when its row is otherwise reachable"

# --- 9/10. ALWAYS + pseudo-keys ---------------------------------------------
# Covered by case 1 (which carries an ALWAYS row and both pseudo-keys and is
# green) — asserted explicitly here so a regression names the right thing.
case "$(run_check "$TMP/good.tsv")" in
  *'[FAIL]'*) fail "9/10: ALWAYS and the ALL/none pseudo-keys must not be treated as gates" ;;
esac
echo "PASS: 9/10 ALWAYS rows and the ALL/none pseudo-keys are exempt from the gate-existence checks"

# --- 11. vendoring-consumer arm ---------------------------------------------
out="$(run_check "$TMP/stale.tsv" GATE_PATHS_ASSUME_CONSUMER=1)" \
  || fail "11: in a vendoring consumer a stale row should SKIP, not fail, got:
$out"
case "$out" in *'[skip]'*) : ;; *) fail "11: expected a legible [skip] line, got: $out" ;; esac
echo "PASS: 11 a vendoring consumer skips (never fails) a row whose gate its composed tree lacks"

# --- 12. consumer arm reaches CHECK 4, not just checks 2/3 (temperloop#1144) --
# The regression: check 3 skipped an absent gate's row while check 4 still
# hard-failed the SAME row on its kernel-only literal paths. In foundation's
# composed tree that was 108 failures naming VERSION / VERSIONING.md / AGENTS.md
# — paths a consumer legitimately does not carry — and the remediation line told
# the consumer to edit a gate-paths.tsv that is a symlink to the kernel's own.
# Case 11's stale row has MATCHING globs, so it never exercised check 4; this
# case gives the absent gate unreachable, kernel-only literals.
cat >"$TMP/consumer-kernel-only.tsv" <<'EOF'
ALL	Makefile
make test-alpha	src/alpha.sh
make test-beta	src/beta/**
bash tools/gamma.sh	ALWAYS
make test-deleted	VERSION VERSIONING.md
EOF
if ! out="$(run_check "$TMP/consumer-kernel-only.tsv" GATE_PATHS_ASSUME_CONSUMER=1)"; then
  fail "12: a consumer must not fail an absent gate's row on its kernel-only literals, got:
$out"
fi
case "$out" in
  *'literal path'*) fail "12: check 4 still fired on an exempt row, got: $out" ;;
  *'unreachable row'*) fail "12: check 4 still fired on an exempt row, got: $out" ;;
esac
echo "PASS: 12 a vendoring consumer's check-4 exemption covers an absent gate's unreachable literals"

# The SAME map is still hard in the kernel's own checkout — the exemption is
# keyed on consumer mode, not on the map's content.
if out="$(run_check "$TMP/consumer-kernel-only.tsv")"; then
  fail "12b: outside a consumer the same map must FAIL, got:
$out"
fi
echo "PASS: 12b the kernel's own checkout keeps full check-4 coverage on that map"

# --- 13. the exemption is NOT a blanket consumer bypass ----------------------
# A row whose gate IS present in this composed tree keeps full reachability
# checking, so the anti-silent-green property survives where it can apply. If
# this case ever passes, the #1144 fix has been widened into a hole.
cat >"$TMP/consumer-present-unreachable.tsv" <<'EOF'
ALL	Makefile
make test-alpha	src/alpha.sh
make test-beta	nowhere/at/all/**
bash tools/gamma.sh	ALWAYS
EOF
if out="$(run_check "$TMP/consumer-present-unreachable.tsv" GATE_PATHS_ASSUME_CONSUMER=1)"; then
  fail "13: a consumer must STILL fail an unreachable row whose gate exists here, got:
$out"
fi
case "$out" in *'unreachable row'*) : ;; *) fail "13: expected an unreachable-row failure, got: $out" ;; esac
case "$out" in *'make test-beta'*) : ;; *) fail "13: the failure must name the orphaned gate, got: $out" ;; esac
echo "PASS: 13 a consumer still fails an unreachable row for a gate its own tree carries"

# --- 14. consumer resolves a row against the vendored subtree ----------------
# The other half of #1144, and the larger half: 87 of the 108 foundation
# failures were rows whose gate IS registered in the composed tree but whose
# path the map spells against the KERNEL's root layout. `scripts/tests/foo.sh`
# is tracked in a consumer as `kernel/scripts/tests/foo.sh`, so a root-only
# lookup calls a present file missing.
cat >"$TMP/kernel-prefixed.tsv" <<'EOF'
ALL	Makefile
make test-alpha	src/alpha-vendored-only.sh
make test-beta	src/beta/**
bash tools/gamma.sh	ALWAYS
EOF
if ! out="$(run_check "$TMP/kernel-prefixed.tsv" GATE_PATHS_ASSUME_CONSUMER=1)"; then
  fail "14: a consumer must resolve a row against the vendored subtree, got:
$out"
fi
echo "PASS: 14 a vendoring consumer resolves a kernel-layout row under the subtree prefix"

# The prefix is a SEAM, not a hardcode — an overlay vendoring elsewhere says so.
if ! out="$(run_check "$TMP/kernel-prefixed.tsv" GATE_PATHS_ASSUME_CONSUMER=1 GATE_PATHS_KERNEL_PREFIX=kernel/)"; then
  fail "14b: an explicit GATE_PATHS_KERNEL_PREFIX must work, got:
$out"
fi
if out="$(run_check "$TMP/kernel-prefixed.tsv" GATE_PATHS_ASSUME_CONSUMER=1 GATE_PATHS_KERNEL_PREFIX=elsewhere/)"; then
  fail "14b: a WRONG prefix must not resolve the row, got:
$out"
fi
echo "PASS: 14b the subtree prefix is an honored seam, and a wrong prefix still fails"

# And the kernel's own checkout never consults the prefix at all.
if out="$(run_check "$TMP/kernel-prefixed.tsv")"; then
  fail "14c: outside a consumer a kernel-layout-only path must FAIL, got:
$out"
fi
case "$out" in *'src/alpha-vendored-only.sh'*) : ;; *) fail "14c: the failure must name the path, got: $out" ;; esac
echo "PASS: 14c the kernel's own checkout does not fall back to a subtree prefix"

# --- 15. green against the real tree, DETERMINISTICALLY ----------------------
# Repeated deliberately. The first cut of this lint matched a literal path with
# `printf '%s\n' "$TRACKED" | grep -Fxq …`; under `pipefail`, grep -q's early
# exit SIGPIPEs the printf and the PIPELINE reports 141 even though the match
# succeeded — so a row passed or failed depending on where in the file its
# match happened to land. That reads as a flaky gate, which is exactly the
# thing this repo refuses to write off. Five runs must agree.
REPO_ROOT="$(cd "$CONFIG_DIR/../../.." && pwd)"
for run in 1 2 3 4 5; do
  if ! out="$(cd "$REPO_ROOT" && bash "$SCRIPT" 2>&1)"; then
    fail "15: the real gate-paths.tsv must be green (run $run of 5):
$out"
  fi
done
echo "PASS: 15 the real tree's gate-paths.tsv is complete and reachable, deterministically (5 runs)"

# --- 16. gate command shape (CHECK 5, temperloop#1650) -----------------------
# build-level.mjs turns a timed-out gate's ORDINAL into its NAME by filtering
# `--list-selected` through `grep -E '^(make|bash) '` and taking line idx+1. A
# gate spelled any other way is dropped by that filter and every LATER ordinal
# shifts by one, so the escalation names the wrong gate. Detection of that
# coupling is proven here.
cat >"$TMP/gates-badshape.txt" <<'EOF'
[kernel]  make test-alpha
[kernel]  npm run test-beta
[kernel]  bash tools/gamma.sh
[overlay] make test-overlay-only
EOF
cat >"$TMP/badshape.tsv" <<'EOF'
ALL	Makefile
make test-alpha	src/alpha.sh
npm run test-beta	src/beta/**
bash tools/gamma.sh	ALWAYS
EOF
if out="$(run_check "$TMP/badshape.tsv" GATE_PATHS_GATE_LIST_FILE="$TMP/gates-badshape.txt")"; then
  fail "16: a gate command beginning neither 'make ' nor 'bash ' must FAIL, got:
$out"
fi
case "$out" in *'npm run test-beta'*) : ;; *) fail "16: the failure must name the offending gate, got: $out" ;; esac
case "$out" in *'ordinal'*) : ;; *) fail "16: the failure must say WHY (the ordinal filter), got: $out" ;; esac
echo "PASS: 16 a gate command outside the make/bash vocabulary fails check 5, naming it"

# 16b — the SAME map and list pass once the gate is respelled, so case 16 is
# check 5 firing and not some other check tripping on the fixture.
cat >"$TMP/gates-goodshape.txt" <<'EOF'
[kernel]  make test-alpha
[kernel]  bash scripts/test-beta.sh
[kernel]  bash tools/gamma.sh
[overlay] make test-overlay-only
EOF
cat >"$TMP/goodshape.tsv" <<'EOF'
ALL	Makefile
make test-alpha	src/alpha.sh
bash scripts/test-beta.sh	src/beta/**
bash tools/gamma.sh	ALWAYS
EOF
if ! out="$(run_check "$TMP/goodshape.tsv" GATE_PATHS_GATE_LIST_FILE="$TMP/gates-goodshape.txt")"; then
  fail "16b: the respelled gate list must be green, got:
$out"
fi
echo "PASS: 16b the same fixture passes once every gate begins make/bash"

# --- 17. PATTERN ROW KEYS (temperloop#2162) ----------------------------------
# quality-gates.sh glob-expands two test directories into one gate per script,
# so the map's completeness check (check 2) had to stop demanding a literal row
# per gate — otherwise adding a test_*.sh would turn THIS gate red until
# someone also edited the map, which is the hand-enumeration trap the expansion
# removes. A key carrying a wildcard therefore maps a whole FAMILY.
#
# Two properties, and the second is what keeps the widening honest:
#  17a  a pattern row SATISFIES completeness for every gate it globs;
#  17b  a pattern row that globs NO current gate is still a STALE row (check 3)
#       — a family key is not a licence to leave dead rows in the map.
cat >"$TMP/gates-family.txt" <<'EOF'
[kernel]  make test-alpha
[kernel]  bash suite.sh --run tests/test_one.sh
[kernel]  bash suite.sh --run tests/test_two.sh
[kernel]  bash tools/gamma.sh
EOF

# 17a — the family row covers both expanded gates; no completeness failure.
cat >"$TMP/family.tsv" <<'EOF'
ALL	Makefile
make test-alpha	src/alpha.sh
bash suite.sh --run tests/test_*.sh	src/beta/**
bash tools/gamma.sh	ALWAYS
EOF
if ! out="$(run_check "$TMP/family.tsv" GATE_PATHS_GATE_LIST_FILE="$TMP/gates-family.txt")"; then
  fail "17a: a pattern row must satisfy completeness for every gate it globs, got:
$out"
fi
case "$out" in *'[ok]'*) : ;; *) fail "17a: expected an [ok] line, got: $out" ;; esac
echo "PASS: 17a a pattern row satisfies completeness for the whole family it globs"

# 17b — the DISCRIMINATION control: the same map against a gate list where the
# family no longer exists. A pattern key that matches nothing is exactly the
# rename/delete the staleness check exists to catch, and must still fail.
cat >"$TMP/gates-family-gone.txt" <<'EOF'
[kernel]  make test-alpha
[kernel]  bash tools/gamma.sh
EOF
if out="$(run_check "$TMP/family.tsv" GATE_PATHS_GATE_LIST_FILE="$TMP/gates-family-gone.txt")"; then
  fail "17b: a pattern row matching NO current gate must FAIL as stale, got:
$out"
fi
case "$out" in *'stale row'*) : ;; *) fail "17b: the failure must name it a stale row, got: $out" ;; esac
case "$out" in *'tests/test_*.sh'*) : ;; *) fail "17b: the failure must name the stale pattern key, got: $out" ;; esac
echo "PASS: 17b a pattern row that globs no current gate still fails as stale"

# --- 18. a ROW-LESS map reports, it does not abort (temperloop#2194) ---------
# `_gp_issue "map has no usable rows"` RECORDS and continues — it is not a die
# — so the completeness walk below it calls `_gp_gate_is_mapped` with
# KEY_BY_INDEX still empty. bash 3.2 treats `"${arr[@]}"` on a zero-length
# array as an unbound-variable error under `set -u`, so the unguarded form
# aborted the check mid-run: the operator saw one finding and a bash error
# instead of the 288 real ones. Both arms below, because neither alone holds:
# 18a survives a host with no bash 3.2, and 18b catches a guard that is present
# but spelled wrong.
cat >"$TMP/rowless.tsv" <<'EOF'
# every line a comment: a well-formed file with no usable rows at all
EOF

# 18a — static: the guarded-expansion idiom is still at the flagged site. A
#       revert to the bare `"${KEY_BY_INDEX[@]}"` removes the `[@]+` prefix.
if grep -q 'KEY_BY_INDEX\[@\]+"\${KEY_BY_INDEX\[@\]}"' "$SCRIPT"; then
  echo "PASS: 18a _gp_gate_is_mapped keeps the bash-3.2 nounset guard \${KEY_BY_INDEX[@]+...}"
else
  fail "18a: _gp_gate_is_mapped expands KEY_BY_INDEX without the bash-3.2 nounset guard (\${KEY_BY_INDEX[@]+...})"
fi

# 18b — runtime: drive the row-less map under the OLDEST bash on this host
#       (macOS `/bin/bash` is 3.2; elsewhere it is whatever `bash` resolves to,
#       where the case is a no-op green rather than a false red).
OLDBASH="bash"
[ -x /bin/bash ] && OLDBASH=/bin/bash
out18="$(env GATE_PATHS_FILE="$TMP/rowless.tsv" \
             GATE_PATHS_GATE_LIST_FILE="$TMP/gates.txt" \
             GATE_PATHS_TRACKED_FILE="$TMP/tracked.txt" \
             GATE_PATHS_ROOT="$TMP" \
             "$OLDBASH" "$SCRIPT" 2>&1)" && \
  fail "18b: a row-less map must still FAIL the check, got a pass:
$out18"
case "$out18" in
  *'unbound variable'*)
    fail "18b: the check ABORTED on an empty KEY_BY_INDEX under $OLDBASH ($("$OLDBASH" -c 'echo $BASH_VERSION')) instead of reporting:
$out18" ;;
esac
case "$out18" in *'map has no usable rows'*) : ;; *)
  fail "18b: the row-less map must be named as such, got: $out18" ;; esac
# The completeness walk must have RUN, not died before it — every kernel gate
# in the fixture list is unmapped, so each has to be reported by name.
case "$out18" in *'gate has no row in the map'*) : ;; *)
  fail "18b: the completeness walk never ran — no per-gate finding was reported:
$out18" ;; esac
echo "PASS: 18b a row-less map reports every unmapped gate under $OLDBASH ($("$OLDBASH" -c 'echo $BASH_VERSION')) instead of aborting on an empty array"

echo "OK — check-gate-paths.sh: all cases passed"
