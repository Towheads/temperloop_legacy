#!/usr/bin/env bash
#
# test_quality_gates_scoped.sh — tests for scripts/quality-gates.sh's `--scoped`
# mode (temperloop#957): the CHANGED-FILE-scoped run a /build item worker uses
# for its ITERATIVE, mid-work verification.
#
# WHY THIS MODE EXISTS. Verification is 79% of all item-worker Bash wall-clock
# (10.4h of 13.2h measured across 141 workers, temperloop#953) and gates are 85%
# of that, with a p90 of 122s and a max of 600s — the full suite, run to check a
# three-file change. The worker's only previous lever was to hand-pick a subset
# out of `--list` output by judgment, which is exactly the kind of unwritten
# selection this repo already has a validated map for.
#
# WHAT MUST BE TRUE FOR THAT TO BE SAFE — the assertions below, in one line
# each: the bare invocation (CI's `checks`, /build §3e.5) is UNCHANGED; a scoped
# run NAMES what it skipped, twice, and stamps its own verdict line so a green
# scoped run cannot be read as a green full run; every resolution failure widens
# to the full set instead of narrowing; an uncommitted or brand-new file is in
# scope (this runs MID-work, not after a commit); and a red gate is still red.
#
# ALSO COVERED HERE (cases 19-21, temperloop#1423): the OTHER selector that
# decides which gates a run contains — the CLASS gating applied while the list
# is BUILT, on a repo-root `.kernel-pin`. Same contract, same reason to test it:
# a gate may only leave a run's set if the omission is NAMED. Those three cases
# run an UNPATCHED copy against the real gate list (via `--list`, which runs
# nothing); see their own block at the bottom of this file.
#
# HERMETIC. Every case runs a PATCHED COPY of the real quality-gates.sh in a
# throwaway git repo whose gate list is four synthetic scripts and whose
# gate-path map is a four-row fixture — so the REAL flag parsing, selector
# wiring, skip reporting and exit codes are exercised, and none of this repo's
# actual (minutes-scale) gates run. No network; never this repo's own checkout.
#
# Usage: scripts/tests/test_quality_gates_scoped.sh

set -uo pipefail

# Same hermeticity guard as the sibling slice suite: this file may itself run AS
# A GATE inside a sliced/scoped parent run, which exports its own state.
unset QUALITY_GATES_START_AT QUALITY_GATES_BUDGET_SECS QUALITY_GATES_SCOPE
# QUALITY_GATES_SCOPED specifically (temperloop#1663): since /build's §3e.5
# acceptance gate now runs SCOPED, it exports this var into the environment of
# every gate it runs — including this file. Inheriting it would silently turn
# case 1's BARE run into a scoped one and break the very assertion that the
# unscoped path is unchanged. Clearing it is what keeps this suite's verdict a
# statement about the code rather than about who invoked it.
unset QUALITY_GATES_SCOPED
unset GATE_SELECTION_CHANGED GITHUB_EVENT_NAME LEAK_GUARD_BASE

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SRC="$REPO_ROOT/scripts/quality-gates.sh"

[ -f "$SRC" ] || { echo "FAIL: quality-gates.sh not found at $SRC" >&2; exit 1; }

fail_count=0
fail() { echo "FAIL: $1" >&2; fail_count=$((fail_count + 1)); }
pass() { echo "PASS: $1"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/qg-scoped-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

FAKE="$WORK/repo"
mkdir -p "$FAKE/scripts" "$FAKE/workflows/scripts/lib" "$FAKE/workflows/scripts/config" \
         "$FAKE/src/lib" "$FAKE/src/cli" "$FAKE/docs"
for lib in checkout-freshness.sh gate-retry.sh gate-selection.sh gate-pool.sh; do
  cp "$REPO_ROOT/workflows/scripts/lib/$lib" "$FAKE/workflows/scripts/lib/"
done

# Four synthetic gates. g4 goes red when the $FAKE/g4.red sentinel exists.
for i in 1 2 3 4; do
  cat >"$FAKE/g$i.sh" <<EOF
#!/usr/bin/env bash
echo "g$i" >> "\$QG_SCOPED_MARK"
# A per-gate SLOW sentinel (temperloop#1663): lets a case burn the soft budget so
# the run SLICES, which is the only way to exercise the resume-ordinal path.
if [ -f "\$(dirname "\$0")/g$i.slow" ]; then sleep 2; fi
if [ "$i" = 4 ] && [ -f "\$(dirname "\$0")/g4.red" ]; then echo "g4 is red"; exit 1; fi
exit 0
EOF
  chmod +x "$FAKE/g$i.sh"
done

# The fixture map, at the path quality-gates.sh hardcodes. g1 is the ALWAYS
# floor (the "global by nature" class); g2/g3/g4 are path-scoped.
cat >"$FAKE/workflows/scripts/config/gate-paths.tsv" <<'EOF'
# fixture map
ALL	scripts/quality-gates.sh
none	LICENSE
bash g1.sh	ALWAYS
bash g2.sh	src/lib/**
bash g3.sh	docs/**
bash g4.sh	src/cli/**
EOF

# Patch the real script: same splice the sibling slice suite uses — replace the
# hardcoded gate-list region with the synthetic list, leaving the flag parsing,
# the selector wiring, the skip reporting, the run loop and the exit codes as
# the production code under test, byte for byte.
awk '
  /^KERNEL_GATES=\($/ { skipping = 1;
    print "KERNEL_GATES=("
    print "  \"bash g1.sh\""
    print "  \"bash g2.sh\""
    print "  \"bash g3.sh\""
    print "  \"bash g4.sh\""
    print ")"
    print "SKIPPED_KERNEL_GATES=()"
    next }
  skipping && /^# The overlay gate set/ { skipping = 0 }
  !skipping { print }
' "$SRC" >"$FAKE/scripts/quality-gates.sh"
chmod +x "$FAKE/scripts/quality-gates.sh"
bash -n "$FAKE/scripts/quality-gates.sh" \
  || { echo "FAIL: patched fixture does not parse — the awk splice needs updating" >&2; exit 1; }

# A real git repo, because the mode under test resolves its own base.
git -C "$FAKE" init -q
git -C "$FAKE" config user.email t@example.com
git -C "$FAKE" config user.name t
echo base >"$FAKE/README.md"
echo lib >"$FAKE/src/lib/thing.sh"
echo cli >"$FAKE/src/cli/main.sh"
echo doc >"$FAKE/docs/guide.md"
echo lic >"$FAKE/LICENSE"
# The red-gate sentinel and the per-run mark files are test scaffolding, not
# changes to the tree under test — ignore them so they never enter the changed
# set (and so case 8 tests a RED GATE rather than an unmapped-path escalation).
printf 'g4.red\n*.slow\n' >"$FAKE/.gitignore"
git -C "$FAKE" add -A
git -C "$FAKE" commit -qm base
git -C "$FAKE" branch -M main
git -C "$FAKE" checkout -qb feature

RUN_OUT=""; RUN_RC=0
run_qg() {
  local mark="$1"; shift
  RUN_RC=0
  RUN_OUT="$(env QG_SCOPED_MARK="$mark" QUALITY_GATES_SKIP_FRESHNESS=1 \
    GATE_MAX_ATTEMPTS=1 GATE_RETRY_BACKOFF=0 \
    bash "$FAKE/scripts/quality-gates.sh" "$@" 2>&1)" || RUN_RC=$?
}
ran() { grep -qx "$2" "$1" 2>/dev/null; }
# NB: an if/else, not `[ -f ] && … || …`. Under `set -o pipefail` a `grep -c`
# that counts ZERO exits 1, so the `||` arm would fire on top of the already-
# printed count and yield "00".
ran_count() { if [ -f "$1" ]; then grep -c . "$1" | tr -d ' '; else printf '0'; fi; }
reset_tree() {
  git -C "$FAKE" checkout -q -- . 2>/dev/null
  rm -f "$FAKE/src/cli/new.sh" "$FAKE/g4.red"
}

# --------------------------------------------------------------------------
# 1. BARE invocation is UNCHANGED — the whole safety case rests on this.
#    /build §3e.5 and CI's `checks` job call the script with no flags; they
#    must still get all four gates and a verdict with no scope qualifier.
# --------------------------------------------------------------------------
reset_tree
echo edited >>"$FAKE/src/lib/thing.sh"
M="$WORK/m1"; : >"$M"
run_qg "$M"
if [ "$RUN_RC" -eq 0 ] && [ "$(ran_count "$M")" = 4 ] \
   && ! grep -q 'SCOPED RUN' <<<"$RUN_OUT" \
   && ! grep -q 'SCOPED SUBSET' <<<"$RUN_OUT" \
   && grep -q 'OK — all 4 quality gate(s) passed' <<<"$RUN_OUT"; then
  pass "bare run is unchanged: all 4 gates, no scope qualifier on the verdict"
else
  fail "bare run: rc=$RUN_RC ran=$(ran_count "$M")
$RUN_OUT"
fi

# --------------------------------------------------------------------------
# 2. --scoped narrows to the ALWAYS floor + the gates the change reaches, and
#    the change here is UNCOMMITTED — the mid-work case the mode exists for.
# --------------------------------------------------------------------------
M="$WORK/m2"; : >"$M"
run_qg "$M" --scoped
if [ "$RUN_RC" -eq 0 ] && ran "$M" g1 && ran "$M" g2 \
   && ! ran "$M" g3 && ! ran "$M" g4; then
  pass "--scoped on an UNCOMMITTED edit runs the ALWAYS floor + the reached gate only"
else
  fail "--scoped narrowing: rc=$RUN_RC ran='$(cat "$M")'
$RUN_OUT"
fi

# --------------------------------------------------------------------------
# 3. It NAMES what it skipped, and why — the anti-false-green requirement.
#    Both un-run gates by name, the map named as the authority, and the
#    disclosure repeated at the verdict (a long run scrolls the first one off
#    screen, which is the same reason the staleness banner is repeated).
# --------------------------------------------------------------------------
disclosures="$(grep -c 'SCOPED RUN — ' <<<"$RUN_OUT")"
if grep -q 'not run (out of scope): bash g3.sh' <<<"$RUN_OUT" \
   && grep -q 'not run (out of scope): bash g4.sh' <<<"$RUN_OUT" \
   && grep -q 'gate-paths.tsv' <<<"$RUN_OUT" \
   && [ "$disclosures" -ge 2 ]; then
  pass "--scoped names every skipped gate and why, before the run AND at the verdict"
else
  fail "skip disclosure (found $disclosures):
$RUN_OUT"
fi

# --------------------------------------------------------------------------
# 4. The VERDICT LINE ITSELF is stamped. A one-line grep of a worker's log is
#    how this result actually gets read, so "OK — all N gates passed" must not
#    be greppable as a full-suite pass on a scoped run.
# --------------------------------------------------------------------------
if grep -q 'OK — all .* quality gate(s) passed .*\[SCOPED SUBSET — NOT a full-suite pass\]' <<<"$RUN_OUT"; then
  pass "--scoped stamps the verdict line itself with the scope"
else
  fail "verdict line is not scope-stamped:
$(grep 'OK — ' <<<"$RUN_OUT")"
fi

# --------------------------------------------------------------------------
# 5. A brand-new, never-added file is IN SCOPE. Without the untracked source
#    a worker's new file would select nothing and the run would silently
#    under-cover exactly the code most likely to be wrong.
# --------------------------------------------------------------------------
reset_tree
echo new >"$FAKE/src/cli/new.sh"
M="$WORK/m5"; : >"$M"
run_qg "$M" --scoped
if [ "$RUN_RC" -eq 0 ] && ran "$M" g1 && ran "$M" g4 && ! ran "$M" g2; then
  pass "--scoped puts an UNTRACKED new file in scope"
else
  fail "untracked file scoping: rc=$RUN_RC ran='$(cat "$M")'
$RUN_OUT"
fi

# --------------------------------------------------------------------------
# 6. An ALL-escalation path widens to the FULL set even under --scoped.
# --------------------------------------------------------------------------
reset_tree
echo '# touched' >>"$FAKE/scripts/quality-gates.sh"
M="$WORK/m6"; : >"$M"
run_qg "$M" --scoped
if [ "$(ran_count "$M")" = 4 ] && ! grep -q 'SCOPED RUN' <<<"$RUN_OUT"; then
  pass "--scoped still escalates an ALL path to the full set"
else
  fail "ALL escalation under --scoped: ran=$(ran_count "$M")
$RUN_OUT"
fi
git -C "$FAKE" checkout -q -- scripts/quality-gates.sh 2>/dev/null || true
# The commit above restored the tracked copy; re-apply the patched fixture.
awk '
  /^KERNEL_GATES=\($/ { skipping = 1;
    print "KERNEL_GATES=("
    print "  \"bash g1.sh\""
    print "  \"bash g2.sh\""
    print "  \"bash g3.sh\""
    print "  \"bash g4.sh\""
    print ")"
    print "SKIPPED_KERNEL_GATES=()"
    next }
  skipping && /^# The overlay gate set/ { skipping = 0 }
  !skipping { print }
' "$SRC" >"$FAKE/scripts/quality-gates.sh"
chmod +x "$FAKE/scripts/quality-gates.sh"

# --------------------------------------------------------------------------
# 7. An UNMAPPED path widens to the FULL set. The map's headline defense,
#    re-proved through this entry point rather than assumed from the lib's.
# --------------------------------------------------------------------------
reset_tree
mkdir -p "$FAKE/nowhere"
echo x >"$FAKE/nowhere/x.txt"
M="$WORK/m7"; : >"$M"
run_qg "$M" --scoped
if [ "$(ran_count "$M")" = 4 ] && grep -q 'matches no glob' <<<"$RUN_OUT"; then
  pass "--scoped widens to the full set on an unmapped path, naming it"
else
  fail "unmapped-path escalation: ran=$(ran_count "$M")
$RUN_OUT"
fi
rm -rf "$FAKE/nowhere"

# --------------------------------------------------------------------------
# 8. A RED selected gate is still RED, and the FAILED line carries the scope.
#    Scoping must never be able to convert a failure into a pass.
# --------------------------------------------------------------------------
reset_tree
echo new >"$FAKE/src/cli/new.sh"
touch "$FAKE/g4.red"
M="$WORK/m8"; : >"$M"
run_qg "$M" --scoped
if [ "$RUN_RC" -eq 1 ] && grep -q 'FAILED 1/.*\[SCOPED SUBSET — NOT a full-suite pass\]' <<<"$RUN_OUT" \
   && grep -q 'QUALITY_GATES_FAILED=1' <<<"$RUN_OUT"; then
  pass "a red gate inside a --scoped run still exits non-zero, scope-stamped"
else
  fail "red gate under --scoped: rc=$RUN_RC
$RUN_OUT"
fi
reset_tree

# --------------------------------------------------------------------------
# 9. --list-selected --scoped is a DRY RUN: it prints the selection and the
#    skip list and runs NOTHING.
# --------------------------------------------------------------------------
echo edited >>"$FAKE/src/lib/thing.sh"
M="$WORK/m9"; : >"$M"
run_qg "$M" --list-selected --scoped
if [ "$RUN_RC" -eq 0 ] && [ "$(ran_count "$M")" = 0 ] \
   && grep -q '^bash g2.sh$' <<<"$RUN_OUT" \
   && grep -q 'not run (out of scope): bash g3.sh' <<<"$RUN_OUT"; then
  pass "--list-selected --scoped previews the selection and the skips without running a gate"
else
  fail "dry run: rc=$RUN_RC ran=$(ran_count "$M")
$RUN_OUT"
fi
reset_tree

# --------------------------------------------------------------------------
# 10. NO RESOLVABLE BASE -> the FULL set, out loud. A worktree with no
#     default-branch base must never narrow on its working-tree half alone.
# --------------------------------------------------------------------------
ORPHAN="$WORK/orphan"
cp -R "$FAKE" "$ORPHAN"
rm -rf "$ORPHAN/.git"
git -C "$ORPHAN" init -q
git -C "$ORPHAN" config user.email t@example.com
git -C "$ORPHAN" config user.name t
git -C "$ORPHAN" checkout -qb sidetrack 2>/dev/null || true
git -C "$ORPHAN" add -A && git -C "$ORPHAN" commit -qm x
echo edited >>"$ORPHAN/src/lib/thing.sh"
M="$WORK/m10"; : >"$M"
RUN_RC=0
RUN_OUT="$(env QG_SCOPED_MARK="$M" QUALITY_GATES_SKIP_FRESHNESS=1 \
  GATE_MAX_ATTEMPTS=1 GATE_RETRY_BACKOFF=0 \
  bash "$ORPHAN/scripts/quality-gates.sh" --scoped 2>&1)" || RUN_RC=$?
if [ "$(ran_count "$M")" = 4 ] && grep -q 'could not resolve a local changed set' <<<"$RUN_OUT"; then
  pass "--scoped with no resolvable base runs the FULL set and says why"
else
  fail "no-base fallback: ran=$(ran_count "$M")
$RUN_OUT"
fi

# --------------------------------------------------------------------------
# 11. An unknown flag is still a usage error (exit 2), and the usage line
#     advertises --scoped.
# --------------------------------------------------------------------------
M="$WORK/m11"; : >"$M"
run_qg "$M" --nope
if [ "$RUN_RC" -eq 2 ] && grep -q -- '--scoped' <<<"$RUN_OUT"; then
  pass "an unknown flag exits 2 and the usage line advertises --scoped"
else
  fail "flag parsing: rc=$RUN_RC
$RUN_OUT"
fi

# --------------------------------------------------------------------------
# 12. --list is untouched by all of this: still the FULL set, never scoped.
# --------------------------------------------------------------------------
M="$WORK/m12"; : >"$M"
run_qg "$M" --list
if [ "$RUN_RC" -eq 0 ] && [ "$(grep -c '^\[kernel\]' <<<"$RUN_OUT")" = 4 ] \
   && [ "$(ran_count "$M")" = 0 ]; then
  pass "--list still prints the FULL gate set and runs nothing"
else
  fail "--list: rc=$RUN_RC
$RUN_OUT"
fi

# ==========================================================================
# THE ENV TWIN OF `--scoped`: $QUALITY_GATES_SCOPED (temperloop#1663)
#
# /build's §3e.5 parent-side acceptance gate needs this mode, and it reaches
# quality-gates.sh through a command string assembled by build-level.mjs whose
# whole interface is ENV VARS, not flags — because a consuming repo vendoring an
# OLDER quality-gates.sh ignores an unknown env var and runs the whole suite
# (still correct), whereas an unknown FLAG exits 2 "usage" and reads back to the
# caller as a GATE FAILURE. That makes the env var load-bearing for the SAFETY
# case, not just the ergonomics: if it ever narrowed a run the flag would not,
# or narrowed on a value it does not understand, §3e.5 would silently gate less
# than it reports. The three cases below are exactly those two properties.
# ==========================================================================

# --------------------------------------------------------------------------
# 13. $QUALITY_GATES_SCOPED=1 selects the SAME gates as the --scoped flag.
#     Equivalence, asserted against case 2's own expectation rather than
#     restated: same tree state, same reached gate, same skipped pair.
# --------------------------------------------------------------------------
reset_tree
echo edited >>"$FAKE/src/lib/thing.sh"
M="$WORK/m13"; : >"$M"
RUN_RC=0
RUN_OUT="$(env QG_SCOPED_MARK="$M" QUALITY_GATES_SKIP_FRESHNESS=1 \
  GATE_MAX_ATTEMPTS=1 GATE_RETRY_BACKOFF=0 QUALITY_GATES_SCOPED=1 \
  bash "$FAKE/scripts/quality-gates.sh" 2>&1)" || RUN_RC=$?
if [ "$RUN_RC" -eq 0 ] && ran "$M" g1 && ran "$M" g2 \
   && ! ran "$M" g3 && ! ran "$M" g4 \
   && grep -q 'SCOPED RUN' <<<"$RUN_OUT" \
   && grep -q 'SCOPED SUBSET' <<<"$RUN_OUT"; then
  pass "\$QUALITY_GATES_SCOPED=1 narrows exactly as --scoped does, and still names what it skipped"
else
  fail "env twin narrowing: rc=$RUN_RC ran='$(cat "$M")'
$RUN_OUT"
fi

# --------------------------------------------------------------------------
# 14. $QUALITY_GATES_SCOPED=0 leaves the run FULL. This is the escape hatch
#     ($BUILD_GATE_SCOPED=0 resolves to it) and the shape an older vendored
#     copy degrades to, so it must be byte-for-byte the bare run of case 1.
# --------------------------------------------------------------------------
M="$WORK/m14"; : >"$M"
RUN_RC=0
RUN_OUT="$(env QG_SCOPED_MARK="$M" QUALITY_GATES_SKIP_FRESHNESS=1 \
  GATE_MAX_ATTEMPTS=1 GATE_RETRY_BACKOFF=0 QUALITY_GATES_SCOPED=0 \
  bash "$FAKE/scripts/quality-gates.sh" 2>&1)" || RUN_RC=$?
if [ "$RUN_RC" -eq 0 ] && [ "$(ran_count "$M")" = 4 ] \
   && ! grep -q 'SCOPED RUN' <<<"$RUN_OUT" \
   && ! grep -q 'SCOPED SUBSET' <<<"$RUN_OUT"; then
  pass "\$QUALITY_GATES_SCOPED=0 runs the FULL set — the escape hatch is a real bare run"
else
  fail "env twin off: rc=$RUN_RC ran=$(ran_count "$M")
$RUN_OUT"
fi

# --------------------------------------------------------------------------
# 15. A value the parser does not understand WIDENS, never narrows. Every
#     other degradation in this selector defaults to the full set; a truthy-
#     looking "true"/"yes" that silently scoped would be the one place a typo
#     could quietly shrink §3e.5's coverage.
# --------------------------------------------------------------------------
for junk in true yes 2 " 1"; do
  M="$WORK/m15"; : >"$M"
  RUN_RC=0
  RUN_OUT="$(env QG_SCOPED_MARK="$M" QUALITY_GATES_SKIP_FRESHNESS=1 \
    GATE_MAX_ATTEMPTS=1 GATE_RETRY_BACKOFF=0 QUALITY_GATES_SCOPED="$junk" \
    bash "$FAKE/scripts/quality-gates.sh" 2>&1)" || RUN_RC=$?
  if [ "$RUN_RC" -eq 0 ] && [ "$(ran_count "$M")" = 4 ] \
     && ! grep -q 'SCOPED RUN' <<<"$RUN_OUT"; then
    : # widened, as required
  else
    fail "env twin junk value '$junk' did not widen to the full set: rc=$RUN_RC ran=$(ran_count "$M")
$RUN_OUT"
    junk_bad=1
  fi
done
[ -n "${junk_bad:-}" ] || pass "an unrecognised \$QUALITY_GATES_SCOPED value WIDENS to the full set (true/yes/2/' 1')"

# --------------------------------------------------------------------------
# 16. A scoped run DISCLOSES the base it scoped against, and how many paths it
#     found. This is the only line that tells an operator debugging a
#     wrongly-narrowed run WHICH tree state produced the narrowing — and it
#     could never print before temperloop#1663: the caller resolved the changed
#     set inside a command substitution, so gate_selection_local_changed()'s
#     GATE_SELECTION_LOCAL_BASE out-param died with the subshell and the guard
#     on that printf was permanently false. Latent since #957; it only became
#     load-bearing when scoping moved onto the acceptance path, and it had no
#     test, which is why it went unnoticed for that long.
# --------------------------------------------------------------------------
reset_tree
echo edited >>"$FAKE/src/lib/thing.sh"
M="$WORK/m16"; : >"$M"
run_qg "$M" --scoped
if [ "$RUN_RC" -eq 0 ] \
   && grep -qE 'scoped against local working tree \(base [0-9a-f]{7,}\): [0-9]+ changed path' <<<"$RUN_OUT"; then
  pass "a scoped run names the base it scoped against and the changed-path count"
else
  fail "base disclosure: rc=$RUN_RC
$RUN_OUT"
fi

# ==========================================================================
# SLICE-STABLE SELECTION (temperloop#1663) — the resume ordinal must keep
# meaning the same gate
#
# THE DEFECT. `$QUALITY_GATES_START_AT` is an ORDINAL into the gate list, and
# once §3e.5 runs SCOPED that list is re-derived from a LIVE working-tree probe
# on every invocation. Two slices of one suite could therefore resolve DIFFERENT
# lists, leaving the ordinal pointing at a different gate: one gate silently
# never runs and the suite still exits 0. Worse, the widening is the trigger —
# an untracked artifact appearing mid-run escalates slice 2 to the FULL set, and
# slice 2's banner then reads "full set", which is MORE reassuring than slice 1's.
# Before #1663 the acceptance gate always resolved mode=full, so the ordinal was
# stable by construction; scoping removed that guarantee silently.
#
# TWO MECHANISMS, TESTED SEPARATELY BECAUSE THEY FAIL SEPARATELY:
#   19. PREVENTION — the pin. Slice 1 records the changed set; slice 2 reuses it
#       instead of re-probing, so the selection cannot move and the resume is
#       still valid. This is the path every real run takes.
#   20. DETECTION — the fingerprint. With the pin deliberately absent (an older
#       vendored caller, a wiped /tmp), a drifted list must produce a LOUD full
#       restart, never a quiet resume into a stale index.
#
# Both run with QUALITY_GATES_JOBS=1: the ordinal only has a meaning in a serial
# walk, and a parallel pool would make which-gate-ran-when nondeterministic.
# ==========================================================================

# --------------------------------------------------------------------------
# 17. THE PIN keeps a sliced scoped run addressing the same gates.
#     g1 (the ALWAYS floor) is made slow so slice 1 spends its budget after it;
#     an unmapped untracked file then appears, which WOULD widen slice 2 to the
#     full set. With the pin, slice 2 reuses slice 1's changed set, resumes at
#     the right gate, and g1 is not re-run or skipped.
# --------------------------------------------------------------------------
reset_tree
rm -f "$FAKE/artifact.tmp" "$FAKE"/g*.slow "$WORK/pin19"
echo edited >>"$FAKE/src/lib/thing.sh"
: >"$FAKE/g1.slow"
M="$WORK/m19"; : >"$M"
RUN_RC=0
RUN_OUT="$(env QG_SCOPED_MARK="$M" QUALITY_GATES_SKIP_FRESHNESS=1 \
  GATE_MAX_ATTEMPTS=1 GATE_RETRY_BACKOFF=0 QUALITY_GATES_JOBS=1 \
  QUALITY_GATES_SCOPED=1 QUALITY_GATES_BUDGET_SECS=1 \
  QUALITY_GATES_SELECTION_PIN="$WORK/pin19" \
  bash "$FAKE/scripts/quality-gates.sh" 2>&1)" || RUN_RC=$?
sel19="$(printf '%s\n' "$RUN_OUT" | sed -n 's/^QUALITY_GATES_SELECTION=//p' | tail -1)"
res19="$(printf '%s\n' "$RUN_OUT" | sed -n 's/^QUALITY_GATES_RESUME_AT=//p' | tail -1)"
# The drift trigger: an untracked path no glob in the fixture map claims.
echo junk >"$FAKE/artifact.tmp"
RUN2_RC=0
RUN2_OUT="$(env QG_SCOPED_MARK="$M" QUALITY_GATES_SKIP_FRESHNESS=1 \
  GATE_MAX_ATTEMPTS=1 GATE_RETRY_BACKOFF=0 QUALITY_GATES_JOBS=1 \
  QUALITY_GATES_SCOPED=1 QUALITY_GATES_START_AT="${res19:-9}" \
  QUALITY_GATES_SELECTION_PIN="$WORK/pin19" \
  QUALITY_GATES_EXPECT_SELECTION="$sel19" \
  bash "$FAKE/scripts/quality-gates.sh" 2>&1)" || RUN2_RC=$?
if [ "$RUN_RC" -eq 75 ] && [ -n "$sel19" ] && [ "$res19" = 1 ] \
   && [ "$RUN2_RC" -eq 0 ] \
   && grep -q 'PINNED from an earlier slice' <<<"$RUN2_OUT" \
   && ! grep -q 'gate selection CHANGED between slices' <<<"$RUN2_OUT" \
   && [ "$(grep -cx g1 "$M")" = 1 ] && [ "$(grep -cx g2 "$M")" = 1 ]; then
  pass "the selection PIN survives a mid-run tree change: slice 2 resumes into the same list, every scoped gate ran exactly once"
else
  fail "slice-stable pin: rc1=$RUN_RC sel='$sel19' resume='$res19' rc2=$RUN2_RC ran='$(cat "$M")'
--- slice 1 ---
$RUN_OUT
--- slice 2 ---
$RUN2_OUT"
fi
rm -f "$FAKE/artifact.tmp" "$FAKE"/g*.slow

# --------------------------------------------------------------------------
# 18. WITHOUT the pin, a drifted selection must RESTART, loudly, on the full
#     set — never resume a stale ordinal. Same drift as case 19; the only
#     difference is that slice 2 gets no pin to reuse, so it re-probes and
#     resolves a DIFFERENT (wider) list than the index was measured in.
#
#     The failure this pins down is specific: resuming index 1 into the widened
#     4-gate list would run g2/g3/g4 and NEVER run g1, then exit 0. So the
#     assertion is not merely "it restarted" — it is that g1 RAN.
# --------------------------------------------------------------------------
reset_tree
rm -f "$FAKE/artifact.tmp" "$FAKE"/g*.slow "$WORK/pin20"
echo edited >>"$FAKE/src/lib/thing.sh"
: >"$FAKE/g1.slow"
M="$WORK/m20"; : >"$M"
RUN_RC=0
RUN_OUT="$(env QG_SCOPED_MARK="$M" QUALITY_GATES_SKIP_FRESHNESS=1 \
  GATE_MAX_ATTEMPTS=1 GATE_RETRY_BACKOFF=0 QUALITY_GATES_JOBS=1 \
  QUALITY_GATES_SCOPED=1 QUALITY_GATES_BUDGET_SECS=1 \
  QUALITY_GATES_SELECTION_PIN="$WORK/pin20" \
  bash "$FAKE/scripts/quality-gates.sh" 2>&1)" || RUN_RC=$?
sel20="$(printf '%s\n' "$RUN_OUT" | sed -n 's/^QUALITY_GATES_SELECTION=//p' | tail -1)"
res20="$(printf '%s\n' "$RUN_OUT" | sed -n 's/^QUALITY_GATES_RESUME_AT=//p' | tail -1)"
rm -f "$FAKE"/g*.slow          # let the restart finish fast
rm -f "$WORK/pin20"            # the pin is gone: slice 2 must re-probe
echo junk >"$FAKE/artifact.tmp"
: >"$M"                        # count only what the RESUMED slice runs
RUN2_RC=0
RUN2_OUT="$(env QG_SCOPED_MARK="$M" QUALITY_GATES_SKIP_FRESHNESS=1 \
  GATE_MAX_ATTEMPTS=1 GATE_RETRY_BACKOFF=0 QUALITY_GATES_JOBS=1 \
  QUALITY_GATES_SCOPED=1 QUALITY_GATES_START_AT="${res20:-9}" \
  QUALITY_GATES_EXPECT_SELECTION="$sel20" \
  bash "$FAKE/scripts/quality-gates.sh" 2>&1)" || RUN2_RC=$?
if [ "$RUN2_RC" -eq 0 ] \
   && grep -q 'gate selection CHANGED between slices' <<<"$RUN2_OUT" \
   && grep -q 'restarting from gate 0 on the FULL set' <<<"$RUN2_OUT" \
   && ran "$M" g1 && ran "$M" g2 && ran "$M" g3 && ran "$M" g4; then
  pass "a drifted selection RESTARTS on the full set and says so — the gate a stale ordinal would have skipped still runs"
else
  fail "stale-resume guard: rc1=$RUN_RC sel='$sel20' resume='$res20' rc2=$RUN2_RC ran='$(cat "$M")'
--- slice 2 ---
$RUN2_OUT"
fi
rm -f "$FAKE/artifact.tmp" "$FAKE"/g*.slow
reset_tree

# ==========================================================================
# CLASS-GATED GATE COMPOSITION (temperloop#691, temperloop#1423)
#
# Same subject as cases 1-18 above — WHICH gates a run contains, and whether
# every omission is NAMED — but keyed on the OTHER selector: the gate CLASS
# gating quality-gates.sh applies while it BUILDS the list, before any flag is
# parsed. Two classes share one signal, a repo-root `.kernel-pin` (present in a
# vendoring consumer, absent in the kernel's own checkout):
#   SELF_DISTRIBUTION_GATES  how the kernel bootstraps/renames/self-updates
#   KERNEL_CONTENT_GATES     assertions about the kernel's OWN product surfaces
#                            (its README's onramp narrative, its product-docs
#                            authorship footers) — a consumer's surfaces belong
#                            to a different product and can never satisfy them
#
# These cases run an UNPATCHED copy of the real script — the synthetic 4-gate
# splice used above would erase the very list under test — with `--list`, which
# prints the composed set and exits before a single gate runs (fast, hermetic,
# no `make`). Case 21 is the ANTI-BURIAL guard: a gate that goes red in a
# vendored tree because of a REAL BUG must stay in the consumer's set, red,
# rather than being swept into the skip class.
# ==========================================================================

# qg_list <root> — the real script's --list, run from <root>.
qg_list() { bash "$1/scripts/quality-gates.sh" --list 2>/dev/null; }

# The real kernel-content class members, verbatim as quality-gates.sh names
# them. Literal on purpose: this suite is the thing that would catch a member
# silently leaving (or joining) the class.
KC_GATES=(
  "bash workflows/scripts/validate-onramp-anchors.sh"
  "bash workflows/scripts/tests/test_validate_onramp_anchors.sh"
  "bash workflows/scripts/validate-docs-footer.sh"
  "bash workflows/scripts/tests/test_validate_docs_footer.sh"
)

# --------------------------------------------------------------------------
# 19. THE KERNEL'S OWN CHECKOUT (no .kernel-pin) keeps FULL coverage — every
#     kernel-content gate still runs. A regression here would silently shrink
#     the kernel's own gate set, which is the whole risk of adding a class.
#
#     Runs against a SYNTHESIZED pin-less fixture — the exact mirror of case
#     20's pinned one — never the real repo root (temperloop#1543): a
#     vendoring consumer structurally carries a root .kernel-pin, so the old
#     real-root "this checkout has no pin" precondition could never hold in a
#     composed overlay tree and false-failed there. The pin-less BRANCH of
#     the class gating is what's under test, and a fixture whose root has no
#     .kernel-pin exercises it wherever this suite runs.
# --------------------------------------------------------------------------
UNPINNED="$WORK/unpinned"
mkdir -p "$UNPINNED/scripts"
cp "$SRC" "$UNPINNED/scripts/quality-gates.sh"
KC_UNPINNED="$(qg_list "$UNPINNED")"
kc_missing=0
for g in "${KC_GATES[@]}"; do
  grep -qxF "[kernel]  $g" <<<"$KC_UNPINNED" || { kc_missing=$((kc_missing + 1)); echo "  missing: $g" >&2; }
done
if [ "$kc_missing" -eq 0 ] && ! grep -q 'kernel-content gate' <<<"$KC_UNPINNED"; then
  pass "no .kernel-pin: all ${#KC_GATES[@]} kernel-content gates RUN (none skipped)"
else
  fail "kernel checkout lost kernel-content coverage ($kc_missing missing, or a skip line was emitted)"
fi

# --------------------------------------------------------------------------
# 20. A VENDORING CONSUMER (.kernel-pin at the repo root) skips the class —
#     and NAMES every member it skipped, exactly as the self-distribution
#     class does. Never a silent drop.
# --------------------------------------------------------------------------
PINNED="$WORK/pinned"
mkdir -p "$PINNED/scripts"
cp "$SRC" "$PINNED/scripts/quality-gates.sh"
printf 'tag=v0.0.0\n' >"$PINNED/.kernel-pin"
KC_PINNED="$(qg_list "$PINNED")"
kc_leaked=0
kc_unnamed=0
for g in "${KC_GATES[@]}"; do
  if grep -qxF "[kernel]  $g" <<<"$KC_PINNED"; then
    kc_leaked=$((kc_leaked + 1)); echo "  still registered: $g" >&2
  fi
  kc_base="${g##*/}"
  grep -qxF "[skipped] $kc_base — kernel-content gate (vendoring consumer, .kernel-pin present)" <<<"$KC_PINNED" \
    || { kc_unnamed=$((kc_unnamed + 1)); echo "  unnamed skip: $kc_base" >&2; }
done
if [ "$kc_leaked" -eq 0 ] && [ "$kc_unnamed" -eq 0 ]; then
  pass ".kernel-pin present: kernel-content class is skipped AND every member is named"
else
  fail "consumer classing: $kc_leaked still registered, $kc_unnamed skipped without a name"
fi

# --------------------------------------------------------------------------
# 21. ANTI-BURIAL (the load-bearing one, temperloop#1423). A gate that goes red
#     in a vendored tree because of a REAL UPSTREAM BUG — lint-pipe-grep-q.sh
#     flagging its own help text (temperloop#1420), the spend report finding
#     zero agent definitions through a symlinked claude/agents (temperloop#1424)
#     — is NOT inapplicable-by-content and must stay in the consumer's set so it
#     keeps failing until it is fixed. Class-gating it would bury it.
#
#     temperloop#1516's residual-gate disposition pass (RUN 2) surfaced three
#     more real-bug members, added below on the same principle:
#       - temperloop#1421 — the four model-comparison mutation-proof suites
#         mutate their SUT ($REPO_ROOT/workflows/scripts/model-comparison/
#         replay.sh) in place; in a composed overlay that path is a symlink
#         into kernel/, and the in-place mutate+restore silently materializes
#         it into a 1,669-line forked copy. A live correctness bug, not a
#         content mismatch.
#       - temperloop#1543 — three kernel tests (this file's own case 19,
#         test_cannot_evaluate.sh case 3, test_check_changelog_entry.sh
#         case 35) assert against the REAL repo root for surfaces a composed
#         overlay legitimately lacks or relocates, and false-fail there. The
#         fix is case-level self-scoping, not class-gating — each test's
#         other cases already pass in the overlay and would be buried too.
# --------------------------------------------------------------------------
NOT_CLASSED=(
  "bash scripts/lint-pipe-grep-q.sh"
  "bash scripts/tests/test_lint_pipe_grep_q.sh"
  "bash workflows/scripts/tests/test_pipeline_spend_report.sh"
  # temperloop#1421 — symlinked-SUT mutation-proof corruption (see above)
  "bash workflows/scripts/model-comparison/tests/test_replay_isolation.sh"
  "bash workflows/scripts/model-comparison/tests/test_replay_preflight.sh"
  "bash workflows/scripts/model-comparison/tests/test_replay_preflight_two_arm.sh"
  "bash workflows/scripts/model-comparison/tests/test_replay_preflight_cost_unit.sh"
  # temperloop#1543 — real-repo-root assertions false-failing in an overlay
  "bash workflows/scripts/lib/tests/test_cannot_evaluate.sh"
  "bash workflows/scripts/tests/test_check_changelog_entry.sh"
  "bash scripts/tests/test_quality_gates_scoped.sh"
)
buried=0
for g in "${NOT_CLASSED[@]}"; do
  grep -qxF "[kernel]  $g" <<<"$KC_PINNED" || { buried=$((buried + 1)); echo "  buried: $g" >&2; }
done
if [ "$buried" -eq 0 ]; then
  pass "real-bug gates stay in a vendoring consumer's set (not swept into the skip class)"
else
  fail "anti-burial: $buried real-bug gate(s) left the consumer's gate set"
fi

# ==========================================================================
# PER-SCRIPT EXPANSION OF THE TWO FORMER UMBRELLA GATES (temperloop#2162)
#
# Third selector over "which gates a run contains", after the diff scoping
# (1-18) and the class gating (19-21): how the list is COMPOSED in the first
# place. `make test-build` and `make test-cli-subcommands` were each ONE entry
# that looped a whole directory glob SERIALLY, and the pool schedules per LIST
# ENTRY — so the two longest poles in the set were the two the pool could not
# spread. They are now glob-expanded into one gate per script at list time.
#
# 22b is the load-bearing case. It is what makes "glob-expanded at list time"
# a CHECKABLE property rather than a claim: an author who swaps the expansion
# for a hand-typed list of 73 filenames passes 22a and 22c and fails HERE the
# moment a test is added or renamed — which is the staleness the expansion
# exists to prevent, and the reason the issue rejected enumeration outright.
#
# Run against the REAL script through `--list`, which composes the set and
# exits before any gate runs (same hermetic trick cases 19-21 use).
# ==========================================================================
EXP_LIST="$(bash "$SRC" --list 2>/dev/null)"

# --------------------------------------------------------------------------
# 22a. Neither umbrella target is a gate any more.
# --------------------------------------------------------------------------
umbrella_left=0
for _u in 'make test-build' 'make test-cli-subcommands'; do
  # `grep -Fx … >/dev/null`, never `grep -Fxq`: scripts/lint-pipe-grep-q.sh
  # rejects the `q` form here, and the redirect is the fix it names.
  if grep -Fx "[kernel]  $_u" <<<"$EXP_LIST" >/dev/null 2>&1; then
    umbrella_left=$((umbrella_left + 1))
    echo "  still a gate: $_u" >&2
  fi
done
if [ "$umbrella_left" -ne 0 ]; then
  fail "22a an umbrella gate is still registered — the pool cannot spread it"
else
  pass "22a neither make test-build nor make test-cli-subcommands is a gate"
fi

# --------------------------------------------------------------------------
# 22b. The expanded set EQUALS the on-disk glob, in both directions, with each
#      script registered exactly ONCE. The once-each half is not decoration:
#      five of these scripts used to carry a second, hand-typed literal entry
#      and would otherwise run twice per suite run.
# --------------------------------------------------------------------------
exp_missing=0
exp_dupe=0
for _d in workflows/scripts/build/tests bin/subcommands/tests; do
  for _f in "$REPO_ROOT/$_d"/test_*.sh; do
    [ -e "$_f" ] || continue
    _rel="$_d/$(basename "$_f")"
    _n="$(grep -cF -- " -- bash $_rel" <<<"$EXP_LIST" | tr -d ' ')"
    case "$_n" in
      1) ;;
      0) exp_missing=$((exp_missing + 1)); echo "  not a gate: $_rel" >&2 ;;
      *) exp_dupe=$((exp_dupe + 1)); echo "  registered $_n times: $_rel" >&2 ;;
    esac
  done
done
exp_orphan=0
while IFS= read -r _g; do
  [ -n "$_g" ] || continue
  _p="${_g##* -- bash }"
  case "$_p" in
    workflows/scripts/build/tests/*|bin/subcommands/tests/*)
      [ -f "$REPO_ROOT/$_p" ] \
        || { exp_orphan=$((exp_orphan + 1)); echo "  gate names a missing script: $_p" >&2; } ;;
  esac
done < <(sed -n 's/^\[kernel\]  //p' <<<"$EXP_LIST" | grep -F -- ' -- bash ')
if [ "$exp_missing" -eq 0 ] && [ "$exp_dupe" -eq 0 ] && [ "$exp_orphan" -eq 0 ]; then
  pass "22b the expanded gate set equals the two directories' test_*.sh glob, exactly once each"
else
  fail "22b expansion drifted from the glob: $exp_missing missing, $exp_dupe duplicated, $exp_orphan orphaned"
fi

# --------------------------------------------------------------------------
# 22c. Every per-script gate keeps a WALL-CLOCK BOUND. temperloop#2184 wrapped
#      the umbrella targets in bounded-suite.sh because an unbounded suite hung
#      ~50h with nothing going red; once the GATE stops being the umbrella, an
#      unwrapped per-script gate reopens that defect at a finer granularity —
#      and this file's own gate list already states the house position on it
#      ("a HUNG gate does not FAIL — it burns the runner to the job timeout").
#      This is the case that stops a later "simplify" from dropping the wrapper.
# --------------------------------------------------------------------------
exp_unbounded=0
while IFS= read -r _g; do
  [ -n "$_g" ] || continue
  case "$_g" in
    "bash workflows/scripts/build/bounded-suite.sh --label "*" -- bash "*) ;;
    *) exp_unbounded=$((exp_unbounded + 1)); echo "  unbounded: $_g" >&2 ;;
  esac
done < <(sed -n 's/^\[kernel\]  //p' <<<"$EXP_LIST" \
  | grep -E -- ' bash (workflows/scripts/build|bin/subcommands)/tests/test_[^ ]*\.sh$')
if [ "$exp_unbounded" -eq 0 ]; then
  pass "22c every per-script gate runs through bounded-suite.sh (the #2184 bound survives the split)"
else
  fail "22c $exp_unbounded per-script gate(s) carry no wall-clock bound"
fi

# --------------------------------------------------------------------------
# 22d. The umbrella MAKE TARGETS still resolve. They are no longer the gate,
#      but four rows of workflows/scripts/config/mandatory-step-registry.tsv
#      still name `make test-build` as their execution signal, and a kernel dev
#      still runs both by hand.
# --------------------------------------------------------------------------
mk_missing=""
for _t in test-build test-cli-subcommands; do
  make -C "$REPO_ROOT" -n "$_t" >/dev/null 2>&1 \
    || mk_missing="${mk_missing:+$mk_missing }$_t"
done
if [ -z "$mk_missing" ]; then
  pass "22d make test-build and make test-cli-subcommands still resolve as targets"
else
  fail "22d umbrella target(s) no longer resolve: $mk_missing"
fi

echo
if [ "$fail_count" -eq 0 ]; then
  echo "OK — quality-gates.sh --scoped + gate classing: all cases passed"
  exit 0
fi
echo "FAILED $fail_count case(s)" >&2
exit 1
