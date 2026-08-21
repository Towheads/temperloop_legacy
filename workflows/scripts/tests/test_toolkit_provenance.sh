#!/usr/bin/env bash
#
# Tests for workflows/scripts/toolkit-provenance.sh (temperloop#1047, ADR
# 0021/0022) — the read-only, network-free toolkit-provenance probe.
#
# Every case runs against a throwaway, git-initialized fixture built here; no
# network, no HOME mutation, no real checkout touched.
#
# Covers, in order:
#   1. THE REGRESSION FIXTURE the whole design turns on — a vendored tree
#      hand-edited AND COMMITTED, then carried forward by a real
#      `git subtree pull --squash` to a NEWER tag with the pin commit landing
#      AFTER the edit. Asserts MODIFIED, and asserts in the same case that the
#      REJECTED pin-commit heuristic would have reported an empty diff (i.e.
#      RELEASED) on this exact tree. That second assertion is what makes the
#      fixture discriminating rather than merely passing.
#   2. Unmodified vendored tree -> RELEASED.
#   3. One hand-modified (uncommitted) file -> MODIFIED naming exactly it.
#   4. A COMMITTED modification authored by a SECOND identity -> committed
#      drift naming the commit and that author, not the running operator; and
#      an `Upstream:` waiver reference in the commit body is surfaced.
#   5. Managed clone: at a tag -> RELEASED; uncommitted edit -> MODIFIED; a
#      COMMITTED edit (so HEAD is no longer exactly at the tag) -> MODIFIED
#      with attribution — the "must not require exact tag detachment" case.
#   6. The kernel's own development checkout -> UNKNOWN, with a reason.
#   7. Fail-open polarity: a non-git dir, and a vendored tree with NO
#      subtree-split marker, both -> UNKNOWN. Never RELEASED.
#   8. Cross-engagement: invoked with cwd inside a SECOND, unrelated project
#      tree, the probe still reports the toolkit's own verdict (the subject is
#      the script's own tree, not $PWD).
#   9. `--format entry` prints a `Status: open` block on MODIFIED and NOTHING
#      on RELEASED/UNKNOWN.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
PROBE="${REPO_ROOT}/workflows/scripts/toolkit-provenance.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-toolkit-provenance-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "PASS: $1"; }

[ -f "$PROBE" ] || fail "0: probe not found at $PROBE"

# A managed-clone home that no fixture is ever equal to, so the managed-clone
# backend is never selected by accident, and $HOME is never consulted.
export TEMPERLOOP_HOME="$TMP/no-such-managed-home"

git_c() { git -C "$1" "${@:2}"; }

commit_as() {
  # commit_as <repo> <name> <email> <message...>
  local repo="$1" name="$2" email="$3"; shift 3
  git -C "$repo" \
    -c "user.name=$name" -c "user.email=$email" \
    commit -q --author="$name <$email>" -m "$*"
}

mk_upstream() {
  # mk_upstream <dir> — a minimal kernel-like upstream repo tagged v0.1.0.
  local d="$1"
  mkdir -p "$d"
  git -C "$d" init -q -b main
  # Fixture identity, set LOCALLY per repo (temperloop#1047 CI): `git subtree`
  # runs its own internal `git commit`, which uses AMBIENT config -- not the
  # `-c user.*` this suite passes to its own explicit commits. A CI runner has
  # no global identity and its `runner` account has no GECOS name, so that
  # internal commit died with "empty ident name" and the fixture silently lost
  # its subtree-split marker. A dev machine hid this by deriving a fallback
  # name from the user record.
  git -C "$d" config user.name "Fixture"
  git -C "$d" config user.email "fixture@example.invalid"
  git -C "$d" config commit.gpgsign false
  git -C "$d" config commit.gpgsign false
  mkdir -p "$d/workflows/scripts"
  printf 'alpha\n' >"$d/a.txt"
  printf 'beta\n' >"$d/workflows/scripts/b.sh"
  git -C "$d" add -A
  commit_as "$d" Upstream up@example.invalid "kernel v0.1.0"
  git -C "$d" tag v0.1.0
}

mk_consumer() {
  # mk_consumer <dir> <upstream> — a repo vendoring <upstream> at v0.1.0 via a
  # real squashing subtree add, plus the .kernel-pin update-kernel.sh writes.
  local d="$1" up="$2"
  mkdir -p "$d"
  git -C "$d" init -q -b main
  # Fixture identity, set LOCALLY per repo (temperloop#1047 CI): `git subtree`
  # runs its own internal `git commit`, which uses AMBIENT config -- not the
  # `-c user.*` this suite passes to its own explicit commits. A CI runner has
  # no global identity and its `runner` account has no GECOS name, so that
  # internal commit died with "empty ident name" and the fixture silently lost
  # its subtree-split marker. A dev machine hid this by deriving a fallback
  # name from the user record.
  git -C "$d" config user.name "Fixture"
  git -C "$d" config user.email "fixture@example.invalid"
  git -C "$d" config commit.gpgsign false
  git -C "$d" config commit.gpgsign false
  printf '# consumer\n' >"$d/README.md"
  git -C "$d" add -A
  commit_as "$d" Operator op@example.invalid "init"
# `-c protocol.file.allow=always`: git 2.38.1 (CVE-2022-39253) hardened the
# `file` transport, and CI runner images set `protocol.file.allow=never` in the
# SYSTEM gitconfig — so `git subtree add|pull` from a local fixture path dies
# with "transport 'file' not allowed". The fixture is entirely local and
# self-built, so re-allowing it here is scoped to the fixture, never production.
# The failure is also made LOUD: a silently-broken fixture used to surface as a
# wrong PROBE verdict (UNKNOWN instead of RELEASED), blaming the code under test
# for a setup failure (temperloop#1047 CI).
  git -C "$d" -c protocol.file.allow=always subtree add --prefix=kernel "$up" v0.1.0 --squash \
    -m "chore(kernel): subtree pull v0.1.0" >"$TMP/subtree-add.log" 2>&1 \
    || fail "fixture: 'git subtree add' failed, so no subtree-split marker exists — $(tr '\n' ' ' <"$TMP/subtree-add.log")"
  printf 'tag v0.1.0\nsha %s\n' "$(git -C "$up" rev-parse 'v0.1.0^{commit}')" >"$d/.kernel-pin"
  git -C "$d" add .kernel-pin
  commit_as "$d" Operator op@example.invalid "chore(kernel): pin v0.1.0"
}

verdict_of() { bash "$PROBE" --root "$1" --format verdict 2>/dev/null; }
report_of()  { bash "$PROBE" --root "$1" --format report  2>&1; }

# ===========================================================================
# 2 (built first — case 1 layers on top of this same fixture shape)
# ===========================================================================
UP="$TMP/up"; CON="$TMP/con"
mk_upstream "$UP"
mk_consumer "$CON" "$UP"

v="$(verdict_of "$CON")"
[ "$v" = "RELEASED" ] || fail "2: unmodified vendored tree should be RELEASED, got '$v' — $(report_of "$CON")"
out="$(report_of "$CON")"
grep -q 'claims:    v0.1.0' <<<"$out" || fail "2: report should name the pinned release — got: $out"
pass "2: an unmodified vendored tree reports RELEASED and names the release it claims"

# ===========================================================================
# 3 — one hand-modified (uncommitted) file
# ===========================================================================
printf 'alpha-EDITED\n' >"$CON/kernel/a.txt"
v="$(verdict_of "$CON")"
[ "$v" = "MODIFIED" ] || fail "3: an uncommitted edit should be MODIFIED, got '$v'"
out="$(report_of "$CON")"
grep -q 'uncommitted drift' <<<"$out" || fail "3: expected an uncommitted-drift section — got: $out"
grep -q 'kernel/a.txt' <<<"$out" || fail "3: expected the edited path named — got: $out"
grep -q 'kernel/workflows/scripts/b.sh' <<<"$out" && fail "3: an untouched path must not be named — got: $out"
pass "3: one hand-modified file reports MODIFIED naming exactly that path"

# --- 9a: entry format on MODIFIED -----------------------------------------
entry="$(bash "$PROBE" --root "$CON" --format entry 2>&1)"
grep -q '^### .* · toolkit provenance · ' <<<"$entry" || fail "9: entry block header missing — got: $entry"
grep -q '\*\*Status:\*\* open' <<<"$entry" || fail "9: entry block must carry Status: open — got: $entry"
pass "9a: --format entry emits a Status: open pending-decisions block on MODIFIED"

git -C "$CON" checkout -- kernel/a.txt
[ -z "$(bash "$PROBE" --root "$CON" --format entry 2>&1)" ] \
  || fail "9: --format entry must print NOTHING when the verdict is not MODIFIED"
pass "9b: --format entry prints nothing when the tree is clean (default-to-silence)"

# ===========================================================================
# 1 — THE REGRESSION FIXTURE (ADR 0022): edit + commit, THEN a subtree pull to
#     a newer tag, THEN the separate pin commit. The rejected pin-commit
#     heuristic reports RELEASED here; the split baseline must report MODIFIED.
# ===========================================================================
printf 'alpha-HAND-EDIT\n' >"$CON/kernel/a.txt"
git -C "$CON" add -A
commit_as "$CON" Operator op@example.invalid "hand edit inside kernel/ (fast lane)"

printf 'gamma\n' >"$UP/c.txt"
git -C "$UP" add -A
commit_as "$UP" Upstream up@example.invalid "kernel v0.2.0"
git -C "$UP" tag v0.2.0

git -C "$CON" -c protocol.file.allow=always subtree pull --prefix=kernel "$UP" v0.2.0 --squash \
  -m "chore(kernel): subtree pull v0.2.0" >"$TMP/subtree-pull.log" 2>&1 \
  || fail "1: the subtree pull to v0.2.0 failed to set up the fixture — $(tr '\n' ' ' <"$TMP/subtree-pull.log")"
printf 'tag v0.2.0\nsha %s\n' "$(git -C "$UP" rev-parse 'v0.2.0^{commit}')" >"$CON/.kernel-pin"
git -C "$CON" add .kernel-pin
commit_as "$CON" Operator op@example.invalid "chore(kernel): pin v0.2.0"

# The rejected heuristic, computed here so the fixture is proven DISCRIMINATING
# rather than merely passing: baseline = the commit that last touched
# .kernel-pin, diffed over the vendored prefix to HEAD.
pin_commit="$(git -C "$CON" log -n 1 --format=%H -- .kernel-pin)"
heuristic_diff="$(git -C "$CON" diff --name-only "$pin_commit" HEAD -- kernel 2>/dev/null)"
[ -z "$heuristic_diff" ] \
  || fail "1: fixture no longer reproduces the rejected heuristic's blind spot (it saw: $heuristic_diff)"

[ -f "$CON/kernel/c.txt" ] || fail "1: the v0.2.0 pull did not land (fixture broken)"
grep -q 'HAND-EDIT' "$CON/kernel/a.txt" || fail "1: the hand edit did not survive the pull (fixture broken)"

v="$(verdict_of "$CON")"
[ "$v" = "MODIFIED" ] \
  || fail "1: FALSE RELEASED regression — a hand-edited tree carried through a later update-kernel pull reported '$v'"
out="$(report_of "$CON")"
grep -q 'kernel/a.txt' <<<"$out" || fail "1: expected the still-modified path named — got: $out"
grep -q 'claims:    v0.2.0' <<<"$out" || fail "1: expected the NEW pinned tag as the claim — got: $out"
pass "1: hand-edit + later subtree pull + separate pin commit still reports MODIFIED (the rejected pin-commit heuristic reports an empty diff on this same tree)"

# ===========================================================================
# 4 — committed modification by a SECOND identity, with an Upstream: waiver
# ===========================================================================
UP2="$TMP/up2"; CON2="$TMP/con2"
mk_upstream "$UP2"
mk_consumer "$CON2" "$UP2"

printf 'beta-COLLEAGUE\n' >"$CON2/kernel/workflows/scripts/b.sh"
git -C "$CON2" add -A
git -C "$CON2" -c user.name=Colleague -c user.email=colleague@example.invalid \
  commit -q --author='Colleague <colleague@example.invalid>' \
  -m "fix(board): patch b.sh

Upstream: https://github.com/Towheads/temperloop/pull/9999"

v="$(verdict_of "$CON2")"
[ "$v" = "MODIFIED" ] || fail "4: a committed modification should be MODIFIED, got '$v'"
out="$(report_of "$CON2")"
grep -q 'committed drift' <<<"$out" || fail "4: expected a committed-drift section — got: $out"
grep -q 'uncommitted drift' <<<"$out" && fail "4: a committed change must NOT be reported as the operator's uncommitted drift — got: $out"
grep -q 'Colleague' <<<"$out" || fail "4: expected the second identity named as the author — got: $out"
grep -q 'pull/9999' <<<"$out" || fail "4: expected the Upstream: waiver reference surfaced — got: $out"
sha_short="$(git -C "$CON2" log -n 1 --format=%h)"
grep -q "$sha_short" <<<"$out" || fail "4: expected the commit named — got: $out"
pass "4: a committed modification by a second identity reports as committed drift, naming the commit, its author, and its Upstream: reference"

# ===========================================================================
# 5 — managed clone
# ===========================================================================
MUP="$TMP/mup"; MHOME="$TMP/managed"
mk_upstream "$MUP"
# Same `file`-transport hardening as the subtree fixtures above: a clone from a
# local fixture path is blocked under the CI runners' system gitconfig.
git -c protocol.file.allow=always clone -q "$MUP" "$MHOME" \
  || fail "fixture: the managed-clone 'git clone' failed, so case 5 has no subject tree"
git -C "$MHOME" config commit.gpgsign false
git -C "$MHOME" checkout -q v0.1.0 2>/dev/null

TEMPERLOOP_HOME="$MHOME" v="$(TEMPERLOOP_HOME="$MHOME" bash "$PROBE" --root "$MHOME" --format verdict)"
[ "$v" = "RELEASED" ] \
  || fail "5: a managed clone sitting at a release tag should be RELEASED, got '$v' — $(TEMPERLOOP_HOME="$MHOME" bash "$PROBE" --root "$MHOME" --format report 2>&1)"
pass "5a: a managed clone at a release tag reports RELEASED"

printf 'alpha-ADOPTER\n' >"$MHOME/a.txt"
v="$(TEMPERLOOP_HOME="$MHOME" bash "$PROBE" --root "$MHOME" --format verdict)"
[ "$v" = "MODIFIED" ] || fail "5: an uncommitted managed-clone edit should be MODIFIED, got '$v'"
pass "5b: a managed clone with an uncommitted edit reports MODIFIED"

# Commit it — HEAD is now NO LONGER exactly at the tag. The backend must still
# resolve a baseline (nearest reachable tag), because this is precisely the
# state most worth reporting.
git -C "$MHOME" add -A
git -C "$MHOME" -c user.name=Adopter -c user.email=adopter@example.invalid \
  commit -q --author='Adopter <adopter@example.invalid>' -m "local tweak"
exact="$(git -C "$MHOME" describe --tags --exact-match HEAD 2>/dev/null || true)"
[ -z "$exact" ] || fail "5: fixture broken — HEAD is still exactly at a tag"
out="$(TEMPERLOOP_HOME="$MHOME" bash "$PROBE" --root "$MHOME" --format report 2>&1)"
grep -q '^Toolkit provenance: MODIFIED' <<<"$out" \
  || fail "5: a committed managed-clone modification must still report MODIFIED — got: $out"
grep -q 'Adopter' <<<"$out" || fail "5: expected the committing adopter named — got: $out"
grep -q 'v0.1.0' <<<"$out" || fail "5: expected the nearest reachable release tag as the baseline — got: $out"
pass "5c: a managed clone whose adopter COMMITTED the modification still reports MODIFIED (no exact tag detachment required)"

# ===========================================================================
# 6 — the kernel's own development checkout
# ===========================================================================
out="$(bash "$PROBE" --root "$REPO_ROOT" --format report 2>&1)"
grep -q '^Toolkit provenance: UNKNOWN' <<<"$out" \
  || fail "6: the kernel's own checkout must report UNKNOWN — got: $out"
grep -q 'reason:' <<<"$out" || fail "6: UNKNOWN must always carry a reason — got: $out"
[ ! -f "$REPO_ROOT/.kernel-pin" ] \
  || fail "6: the kernel checkout grew a .kernel-pin — that would mis-class the self-distribution suite"
pass "6: the kernel's own development checkout reports UNKNOWN with a reason, and still carries no .kernel-pin"

# ===========================================================================
# 7 — fail-open polarity: UNKNOWN, never RELEASED
# ===========================================================================
mkdir -p "$TMP/notgit"
v="$(verdict_of "$TMP/notgit")"
[ "$v" = "UNKNOWN" ] || fail "7: a non-git directory must be UNKNOWN, got '$v'"

v="$(verdict_of "$TMP/definitely-absent-path")"
[ "$v" = "UNKNOWN" ] || fail "7: a nonexistent path must be UNKNOWN, got '$v'"

# A tree that LOOKS vendored (pin + kernel/) but was never produced by a
# squashing subtree pull: no recorded baseline exists, so the answer is
# UNKNOWN — emphatically not RELEASED.
NOSPLIT="$TMP/nosplit"
mkdir -p "$NOSPLIT/kernel"
git -C "$NOSPLIT" init -q -b main
# Fixture identity, set LOCALLY per repo (temperloop#1047 CI): `git subtree`
# runs its own internal `git commit`, which uses AMBIENT config -- not the
# `-c user.*` this suite passes to its own explicit commits. A CI runner has
# no global identity and its `runner` account has no GECOS name, so that
# internal commit died with "empty ident name" and the fixture silently lost
# its subtree-split marker. A dev machine hid this by deriving a fallback
# name from the user record.
git -C "$NOSPLIT" config user.name "Fixture"
git -C "$NOSPLIT" config user.email "fixture@example.invalid"
git -C "$NOSPLIT" config commit.gpgsign false
git -C "$NOSPLIT" config commit.gpgsign false
printf 'x\n' >"$NOSPLIT/kernel/a.txt"
printf 'tag v9.9.9\nsha 0000000\n' >"$NOSPLIT/.kernel-pin"
git -C "$NOSPLIT" add -A
commit_as "$NOSPLIT" Operator op@example.invalid "hand-assembled vendored tree"
v="$(verdict_of "$NOSPLIT")"
[ "$v" = "UNKNOWN" ] \
  || fail "7: a vendored tree with no subtree-split marker must be UNKNOWN (never RELEASED), got '$v'"
out="$(report_of "$NOSPLIT")"
grep -q 'reason:' <<<"$out" || fail "7: UNKNOWN must always carry a reason — got: $out"
pass "7: every unresolvable baseline lands on UNKNOWN with a reason — never RELEASED"

# ===========================================================================
# 8 — cross-engagement: the subject is the toolkit's own tree, not $PWD
# ===========================================================================
# Copy the probe into the MODIFIED consumer's vendored tree (where a real
# install's symlinks resolve to), then invoke it with cwd inside a SECOND,
# unrelated project checkout and no --root at all.
cp "$PROBE" "$CON/kernel/workflows/scripts/toolkit-provenance.sh"
OTHER="$TMP/other-project"
mkdir -p "$OTHER"
git -C "$OTHER" init -q -b main
# Fixture identity, set LOCALLY per repo (temperloop#1047 CI): `git subtree`
# runs its own internal `git commit`, which uses AMBIENT config -- not the
# `-c user.*` this suite passes to its own explicit commits. A CI runner has
# no global identity and its `runner` account has no GECOS name, so that
# internal commit died with "empty ident name" and the fixture silently lost
# its subtree-split marker. A dev machine hid this by deriving a fallback
# name from the user record.
git -C "$OTHER" config user.name "Fixture"
git -C "$OTHER" config user.email "fixture@example.invalid"
git -C "$OTHER" config commit.gpgsign false
printf 'unrelated\n' >"$OTHER/x.txt"
git -C "$OTHER" add -A
commit_as "$OTHER" Operator op@example.invalid "unrelated project"

v="$(cd "$OTHER" && bash "$CON/kernel/workflows/scripts/toolkit-provenance.sh" --format verdict)"
[ "$v" = "MODIFIED" ] \
  || fail "8: a session in a second, unrelated project tree must still see the toolkit's own MODIFIED verdict, got '$v'"
# Control: scoping to $PWD's own repo would have answered UNKNOWN, so the
# assertion above is discriminating rather than incidental.
v_pwd="$(bash "$PROBE" --root "$OTHER" --format verdict)"
[ "$v_pwd" = "UNKNOWN" ] \
  || fail "8: control failed — the unrelated project tree itself should be UNKNOWN, got '$v_pwd'"
pass "8: the probe reports the running toolkit's verdict from an unrelated project tree (cross-engagement case)"

# ===========================================================================
# Read-only contract
# ===========================================================================
before="$(git -C "$CON2" status --porcelain)"
bash "$PROBE" --root "$CON2" --format report >/dev/null 2>&1
after="$(git -C "$CON2" status --porcelain)"
[ "$before" = "$after" ] || fail "R: the probe mutated the tree it probed (before='$before' after='$after')"
pass "R: the probe writes nothing — no marker, no state, no pin-file touch"

echo
echo "All toolkit-provenance tests passed."
