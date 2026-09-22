#!/usr/bin/env bash
#
# Tests for workflows/scripts/install/doctor.sh's check_toolkit_provenance()
# (temperloop#1047, ADR 0021/0022) — the non-fatal RELEASED / WARN-MODIFIED /
# SKIPPED-UNKNOWN health check.
#
# Covers:
#   1. An unmodified vendored fixture reports the tree as byte-identical to
#      its release and emits NO WARN — a released checkout passes quietly.
#   2. The same fixture with one edited file emits `WARN  MODIFIED` naming the
#      release it claims, and inlines the probe's own attribution block so the
#      reader never has to re-run anything.
#   3. The MODIFIED verdict is NON-FATAL — proven DIFFERENTIALLY: the same
#      fixture before vs. after the edit yields an IDENTICAL "Non-OK: N" count
#      and an IDENTICAL doctor exit code; only the provenance section differs.
#   4. A checkout with no release baseline (the kernel's own development
#      checkout shape) reports SKIPPED **with a reason** — never RELEASED.
#   5. The section appears unconditionally in doctor's output.
#
# Every case runs against a throwaway fixture root passed as doctor.sh's
# positional <foundation-root>; nothing under $HOME or the real checkout is
# read for the verdict or written at all.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
DOCTOR_SH="${REPO_ROOT}/workflows/scripts/install/doctor.sh"
PROBE="${REPO_ROOT}/workflows/scripts/toolkit-provenance.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-doctor-provenance-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "PASS: $1"; }

[ -f "$DOCTOR_SH" ] || fail "0: doctor.sh not found at $DOCTOR_SH"
[ -f "$PROBE" ] || fail "0: toolkit-provenance.sh not found at $PROBE"

# Never let a fixture accidentally resolve as the managed clone.
export TEMPERLOOP_HOME="$TMP/no-such-managed-home"

commit_as() {
  local repo="$1" name="$2" email="$3"; shift 3
  git -C "$repo" -c "user.name=$name" -c "user.email=$email" \
    commit -q --author="$name <$email>" -m "$*"
}

# _mk_vendored <name> — a git repo vendoring a tiny upstream at v0.1.0 via a
# real squashing subtree add, carrying a .kernel-pin, and holding a copy of
# the real probe at the path check_toolkit_provenance looks for. Prints the
# consumer path (which is what doctor is pointed at: `FOUNDATION` is the
# vendored kernel dir in a consuming repo).
_mk_vendored() {
  local name="$1"
  local up="$TMP/$name-up"
  local con="$TMP/$name-con"
  mkdir -p "$up"
  git -C "$up" init -q -b main
  # Fixture identity, set LOCALLY per repo (temperloop#1047 CI): `git subtree`
  # runs its own internal `git commit`, which uses AMBIENT config -- not the
  # `-c user.*` this suite passes to its own explicit commits. A CI runner has
  # no global identity and its `runner` account has no GECOS name, so that
  # internal commit died with "empty ident name" and the fixture silently lost
  # its subtree-split marker. A dev machine hid this by deriving a fallback
  # name from the user record.
  git -C "$up" config user.name "Fixture"
  git -C "$up" config user.email "fixture@example.invalid"
  git -C "$up" config commit.gpgsign false
  mkdir -p "$up/workflows/scripts"
  printf 'alpha\n' >"$up/a.txt"
  cp "$PROBE" "$up/workflows/scripts/toolkit-provenance.sh"
  git -C "$up" add -A
  commit_as "$up" Upstream up@example.invalid "kernel v0.1.0"
  git -C "$up" tag v0.1.0

  mkdir -p "$con"
  git -C "$con" init -q -b main
  # Fixture identity, set LOCALLY per repo (temperloop#1047 CI): `git subtree`
  # runs its own internal `git commit`, which uses AMBIENT config -- not the
  # `-c user.*` this suite passes to its own explicit commits. A CI runner has
  # no global identity and its `runner` account has no GECOS name, so that
  # internal commit died with "empty ident name" and the fixture silently lost
  # its subtree-split marker. A dev machine hid this by deriving a fallback
  # name from the user record.
  git -C "$con" config user.name "Fixture"
  git -C "$con" config user.email "fixture@example.invalid"
  git -C "$con" config commit.gpgsign false
  printf '# consumer\n' >"$con/README.md"
  git -C "$con" add -A
  commit_as "$con" Operator op@example.invalid "init"
# `-c protocol.file.allow=always`: git 2.38.1 (CVE-2022-39253) hardened the
# `file` transport, and CI runner images set `protocol.file.allow=never` in the
# SYSTEM gitconfig — so `git subtree add|pull` from a local fixture path dies
# with "transport 'file' not allowed". The fixture is entirely local and
# self-built, so re-allowing it here is scoped to the fixture, never production.
# The failure is also made LOUD: a silently-broken fixture used to surface as a
# wrong PROBE verdict (UNKNOWN instead of RELEASED), blaming the code under test
# for a setup failure (temperloop#1047 CI).
  git -C "$con" -c protocol.file.allow=always subtree add --prefix=kernel "$up" v0.1.0 --squash \
    -m "chore(kernel): subtree pull v0.1.0" >"$TMP/subtree-add.log" 2>&1 \
    || fail "fixture: 'git subtree add' failed, so no subtree-split marker exists — $(tr '\n' ' ' <"$TMP/subtree-add.log")"
  printf 'tag v0.1.0\nsha %s\n' "$(git -C "$up" rev-parse 'v0.1.0^{commit}')" >"$con/.kernel-pin"
  git -C "$con" add .kernel-pin
  commit_as "$con" Operator op@example.invalid "chore(kernel): pin v0.1.0"
  printf '%s\n' "$con"
}

# The vendored kernel dir is what an installed surface resolves into, so it is
# what doctor is pointed at in a consuming repo.
CON="$(_mk_vendored clean)"
FOUND="$CON/kernel"

section() {
  # section <doctor-output> — just the provenance block.
  sed -n '/^Toolkit provenance check/,/^$/p' <<<"$1"
}

# ---------------------------------------------------------------------------
# 1 + 3 (before) — unmodified
# ---------------------------------------------------------------------------
set +e
out_clean="$(bash "$DOCTOR_SH" "$FOUND" 2>&1)"
rc_clean=$?
set -e

sec="$(section "$out_clean")"
[ -n "$sec" ] || fail "5: doctor emitted no 'Toolkit provenance check' section at all — got: $out_clean"
grep -q 'byte-identical to the release it claims' <<<"$sec" \
  || fail "1: expected the RELEASED line — got: $sec"
grep -q 'v0.1.0' <<<"$sec" || fail "1: expected the claimed release named — got: $sec"
grep -q 'WARN' <<<"$sec" && fail "1: a released checkout must pass with no WARN — got: $sec"
pass "1: an unmodified vendored checkout reports byte-identical with no WARN"
pass "5: the provenance section appears unconditionally in doctor's output"

nonok_clean="$(sed -n 's/^OK: [0-9]*   Non-OK: \([0-9]*\)$/\1/p' <<<"$out_clean" | head -n1)"
[ -n "$nonok_clean" ] || fail "3: could not read the Non-OK tally from doctor's output"

# ---------------------------------------------------------------------------
# 2 + 3 (after) — one edited file
# ---------------------------------------------------------------------------
printf 'alpha-EDITED\n' >"$FOUND/a.txt"
set +e
out_mod="$(bash "$DOCTOR_SH" "$FOUND" 2>&1)"
rc_mod=$?
set -e

sec="$(section "$out_mod")"
grep -q 'WARN  MODIFIED' <<<"$sec" || fail "2: expected 'WARN  MODIFIED' — got: $sec"
grep -q 'v0.1.0' <<<"$sec" || fail "2: expected the claimed release named on the WARN — got: $sec"
grep -q 'uncommitted drift' <<<"$sec" \
  || fail "2: the probe's attribution block should be inlined, not summarised away — got: $sec"
grep -q 'kernel/a.txt' <<<"$sec" || fail "2: expected the drifted path named — got: $sec"
pass "2: a modified vendored checkout emits WARN MODIFIED with the drifted path inlined"

nonok_mod="$(sed -n 's/^OK: [0-9]*   Non-OK: \([0-9]*\)$/\1/p' <<<"$out_mod" | head -n1)"
[ "$nonok_clean" = "$nonok_mod" ] \
  || fail "3: the MODIFIED verdict changed doctor's Non-OK tally ($nonok_clean -> $nonok_mod)"
[ "$rc_clean" = "$rc_mod" ] \
  || fail "3: the MODIFIED verdict changed doctor's exit code ($rc_clean -> $rc_mod)"
pass "3: the MODIFIED verdict is non-fatal — identical Non-OK tally ($nonok_clean) and exit code ($rc_clean) before and after"

# ---------------------------------------------------------------------------
# 4 — no release baseline (the kernel's own development checkout shape)
# ---------------------------------------------------------------------------
BARE="$TMP/bare"
mkdir -p "$BARE/workflows/scripts/kernel"
git -C "$BARE" init -q -b main
# Fixture identity, set LOCALLY per repo (temperloop#1047 CI): `git subtree`
# runs its own internal `git commit`, which uses AMBIENT config -- not the
# `-c user.*` this suite passes to its own explicit commits. A CI runner has
# no global identity and its `runner` account has no GECOS name, so that
# internal commit died with "empty ident name" and the fixture silently lost
# its subtree-split marker. A dev machine hid this by deriving a fallback
# name from the user record.
git -C "$BARE" config user.name "Fixture"
git -C "$BARE" config user.email "fixture@example.invalid"
git -C "$BARE" config commit.gpgsign false
cp "$PROBE" "$BARE/workflows/scripts/toolkit-provenance.sh"
printf '# manifest\n' >"$BARE/workflows/scripts/kernel/kernel-manifest.txt"
git -C "$BARE" add -A
commit_as "$BARE" Operator op@example.invalid "kernel dev checkout"

set +e
out_bare="$(bash "$DOCTOR_SH" "$BARE" 2>&1)"
set -e
sec="$(section "$out_bare")"
grep -q 'SKIPPED (' <<<"$sec" || fail "4: expected SKIPPED with a reason — got: $sec"
grep -q 'no release baseline' <<<"$sec" \
  || fail "4: the SKIPPED reason should name the missing baseline — got: $sec"
grep -q 'byte-identical' <<<"$sec" \
  && fail "4: an unresolvable baseline must never read as released — got: $sec"
pass "4: a checkout with no release baseline reports SKIPPED with a reason, never RELEASED"

echo
echo "All doctor toolkit-provenance tests passed."
