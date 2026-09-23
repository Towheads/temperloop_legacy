#!/usr/bin/env bash
#
# Tests for gate-selection.sh — the diff-scoped gate selector
# scripts/quality-gates.sh uses on `pull_request` runs (temperloop#1024).
#
# The whole value of this suite is that it proves the DEGRADATIONS, which are
# the only thing standing between diff-scoping and the silent-green failure
# class. Every case below asserts one of two things: either the selector
# narrowed correctly, or it refused to narrow and said why.
#
# Coverage:
#   1. Not a pull_request event -> FULL set (the merge_group / push:main /
#      local / worker path, i.e. everything that gates `main`).
#   2. QUALITY_GATES_SCOPE=full -> FULL set even on a pull_request.
#   3. An unrecognised QUALITY_GATES_SCOPE -> FULL set (fail toward coverage).
#   4. Happy path: changed paths select exactly their mapped gates, plus every
#      ALWAYS gate, in the caller's run order.
#   5. UNMAPPED PATH -> FULL set. The headline safety property.
#   6. ALL escalation glob -> FULL set.
#   7. `none` row: a recognised path that maps to no gate does NOT escalate,
#      and does NOT drag in unrelated gates.
#   8. An ALWAYS row is not a path recogniser — otherwise its implicit
#      whole-tree scope would match every path and case 5 could never fire.
#   9. UNMAPPED GATE still runs (over-run, never under-run).
#  10. Malformed map -> FULL set, with a stderr complaint.
#  11. Missing map file -> FULL set.
#  12. Unresolvable base -> FULL set (real git, real repo).
#  13. Empty diff -> FULL set.
#  14. End-to-end against a REAL git repo: a two-commit repo, a real
#      `git diff base...HEAD`, and a real narrowing decision.
#  15. Globs are never pathname-expanded against the working directory.
#
# temperloop#957 added a SECOND consumer — `quality-gates.sh --scoped`, the
# /build item worker's mid-work run — and with it two more things that must be
# proven, since a worker's run is read by a model rather than a CI dashboard:
#  16. `GATE_SELECTION_SKIPPED` is the EXACT complement of `_SELECTED` (the
#      scoped run can name everything it did not run).
#  17. A full run reports an EMPTY skip list.
#  18. `gate_selection_local_changed` unions committed + staged + unstaged +
#      untracked paths, and excludes ignored ones.
#  19. No resolvable default-branch base -> non-zero, so the caller runs the
#      FULL set rather than narrowing on the working-tree half alone.
#  20. A non-git directory -> non-zero (never an empty, silently-narrowing set).
#
# temperloop#1931 added GENERIC new-surface globs to gate-paths.tsv so a
# brand-new check-*/validate-*/test_* script selects the check-surface and
# exec-bit registry validators before it is even registered:
#  21. A depth-0 and a nested brand-new candidate-shaped path each select all
#      four registry-validator gates against the REAL gate-paths.tsv.
#
# temperloop#1933 carved the ONE content-checked exception to the ALL row: a
# registration-only scripts/quality-gates.sh diff selects the registry
# validators rather than the whole suite. Both shapes are proven:
#  22. a) registration-only  -> diff mode, registry validators + the newly
#         registered gate, an unrelated mapped gate still skipped;
#      b) a removed line, c) a non-registration addition, d) comments only,
#      e) a splat registration, f) no readable diff -> FULL escalation, each.
#      g/h) the same two verdicts end-to-end against a REAL git tree, with the
#         uncommitted half of the diff carrying its own veto;
#      i) the PINNED LATER SLICE — the default /build shape, where neither
#         $LEAK_GUARD_BASE nor GATE_SELECTION_LOCAL_BASE is set and the probe
#         must resolve its own base, or the selection moves between slices and
#         the #1663 drift guard restarts the whole suite on the full set;
#      j) diff.mnemonicPrefix / diff.noprefix cannot silently disable it;
#      k) a SKIPPED_KERNEL_GATES disclosure line is not a registration;
#      l/m) a bare element of the KERNEL_GATES array literal IS one — but only
#         when the literal names a gate the caller list already carries.
#
# temperloop#1695 pinned `--no-renames` on every changed-set diff, because git
# reports a rename as the DESTINATION path alone and a file leaving a gated tree
# therefore never selected that tree's gates:
#  23. a) a COMMITTED rename out of a gated tree still selects the source tree's
#         gate; b) an UNCOMMITTED (staged) one lists both paths in the local
#         changed set. Real git both times — it is a property of what git EMITS.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$HERE/.." && pwd)"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# shellcheck source=../gate-selection.sh
source "$LIB_DIR/gate-selection.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

MAP="$TMP/gate-paths.tsv"
cat >"$MAP" <<'EOF'
# fixture map
ALL	Makefile scripts/quality-gates.sh
none	LICENSE attic/**
make test-always	ALWAYS
make test-docs	docs/**
make test-lib	src/lib/** src/shared.sh
make test-cli	src/cli/**
EOF

ALL_GATES='make test-always
make test-docs
make test-lib
make test-cli
make test-unmapped'

reset_env() {
  unset QUALITY_GATES_SCOPE GITHUB_EVENT_NAME GATE_SELECTION_CHANGED GATE_SELECTION_DIFF_TEXT
  GATE_SELECTION_ROOT="$TMP"
  GATE_SELECTION_MAP_FILE="$MAP"
  GATE_SELECTION_ALL_GATES="$ALL_GATES"
  GATE_SELECTION_BASE=""
}

# --- 1. not a pull_request event ---------------------------------------------
reset_env
GITHUB_EVENT_NAME=merge_group
GATE_SELECTION_CHANGED='docs/a.md'
gate_selection_resolve
[ "$GATE_SELECTION_MODE" = "full" ] || fail "1: merge_group must run the FULL set (got $GATE_SELECTION_MODE)"
case "$GATE_SELECTION_REASON" in *"is not pull_request"*) : ;; *) fail "1: reason should name the event (got: $GATE_SELECTION_REASON)" ;; esac
echo "PASS: 1 a non-pull_request event runs the full set"

# --- 2. QUALITY_GATES_SCOPE=full ---------------------------------------------
reset_env
GITHUB_EVENT_NAME=pull_request
QUALITY_GATES_SCOPE=full
GATE_SELECTION_CHANGED='docs/a.md'
gate_selection_resolve
[ "$GATE_SELECTION_MODE" = "full" ] || fail "2: SCOPE=full must disable scoping"
echo "PASS: 2 QUALITY_GATES_SCOPE=full disables scoping"

# --- 3. unrecognised scope ---------------------------------------------------
reset_env
QUALITY_GATES_SCOPE=sideways
GATE_SELECTION_CHANGED='docs/a.md'
gate_selection_resolve
[ "$GATE_SELECTION_MODE" = "full" ] || fail "3: an unrecognised scope must fail toward the full set"
case "$GATE_SELECTION_REASON" in *unrecognised*) : ;; *) fail "3: reason should say unrecognised (got: $GATE_SELECTION_REASON)" ;; esac
echo "PASS: 3 an unrecognised QUALITY_GATES_SCOPE falls back to the full set"

# --- 4. happy path -----------------------------------------------------------
reset_env
QUALITY_GATES_SCOPE=diff
GATE_SELECTION_CHANGED='docs/a.md
src/lib/thing.sh'
gate_selection_resolve
[ "$GATE_SELECTION_MODE" = "diff" ] || fail "4: expected a diff-scoped run (got $GATE_SELECTION_MODE / $GATE_SELECTION_REASON)"
expected='make test-always
make test-docs
make test-lib
make test-unmapped'
[ "$GATE_SELECTION_SELECTED" = "$expected" ] || fail "4: wrong selection:
got:
$GATE_SELECTION_SELECTED
want:
$expected"
echo "PASS: 4 mapped paths select their gates (plus ALWAYS + unmapped), in run order"

# --- 5. an unmapped path escalates to the full set ---------------------------
reset_env
QUALITY_GATES_SCOPE=diff
GATE_SELECTION_CHANGED='docs/a.md
somewhere/nobody/mapped.txt'
gate_selection_resolve
[ "$GATE_SELECTION_MODE" = "full" ] || fail "5: an unmapped path MUST escalate to the full set (got $GATE_SELECTION_MODE)"
case "$GATE_SELECTION_REASON" in *"somewhere/nobody/mapped.txt"*) : ;; *) fail "5: reason must NAME the unmapped path (got: $GATE_SELECTION_REASON)" ;; esac
echo "PASS: 5 an unmapped changed path escalates to the full set, naming the path"

# --- 6. ALL escalation -------------------------------------------------------
reset_env
QUALITY_GATES_SCOPE=diff
GATE_SELECTION_CHANGED='docs/a.md
Makefile'
gate_selection_resolve
[ "$GATE_SELECTION_MODE" = "full" ] || fail "6: an ALL glob must escalate to the full set"
case "$GATE_SELECTION_REASON" in *"ALL escalation"*) : ;; *) fail "6: reason should name the ALL escalation (got: $GATE_SELECTION_REASON)" ;; esac
echo "PASS: 6 a path matching an ALL glob escalates to the full set"

# --- 7. `none` row -----------------------------------------------------------
reset_env
QUALITY_GATES_SCOPE=diff
GATE_SELECTION_CHANGED='LICENSE'
gate_selection_resolve
[ "$GATE_SELECTION_MODE" = "diff" ] || fail "7: a `none`-mapped path must not escalate (got $GATE_SELECTION_REASON)"
expected='make test-always
make test-unmapped'
[ "$GATE_SELECTION_SELECTED" = "$expected" ] || fail "7: a none-mapped path should select nothing beyond ALWAYS/unmapped, got:
$GATE_SELECTION_SELECTED"
echo "PASS: 7 a 'none'-mapped path is recognised but selects no gate"

# --- 8. an ALWAYS row is not a recogniser ------------------------------------
# `make test-always` carries no globs. If ALWAYS rows counted as recognisers
# (e.g. by being treated as `**`), the unmapped-path escalation in case 5 could
# never fire. Prove the recogniser set really excludes them.
reset_env
QUALITY_GATES_SCOPE=diff
GATE_SELECTION_CHANGED='totally/unmapped'
gate_selection_resolve
[ "$GATE_SELECTION_MODE" = "full" ] || fail "8: an ALWAYS row must not recognise arbitrary paths"
echo "PASS: 8 an ALWAYS row contributes nothing to path recognition"

# --- 9. an unmapped GATE always runs ----------------------------------------
# (asserted by cases 4 and 7 above, which both keep `make test-unmapped`.)
reset_env
QUALITY_GATES_SCOPE=diff
GATE_SELECTION_CHANGED='src/cli/main.sh'
gate_selection_resolve
case "$GATE_SELECTION_SELECTED" in *"make test-unmapped"*) : ;; *) fail "9: a gate with no map row must still run" ;; esac
case "$GATE_SELECTION_SELECTED" in *"make test-docs"*) fail "9: test-docs should not have been selected by a src/cli path" ;; esac
echo "PASS: 9 a gate with no row in the map still runs (over-run, never under-run)"

# --- 10. malformed map -------------------------------------------------------
BADMAP="$TMP/bad.tsv"
printf 'no-tab-here\n' >"$BADMAP"
reset_env
QUALITY_GATES_SCOPE=diff
GATE_SELECTION_MAP_FILE="$BADMAP"
GATE_SELECTION_CHANGED='docs/a.md'
# NB: stderr is redirected to a FILE, not captured by `$(...)` — a command
# substitution runs in a subshell, and the whole point of this call is the
# globals it sets in THIS shell.
gate_selection_resolve 2>"$TMP/err10"
err="$(cat "$TMP/err10")"
[ "$GATE_SELECTION_MODE" = "full" ] || fail "10: a malformed map must fall back to the full set"
case "$err" in *malformed*) : ;; *) fail "10: the malformed row should be announced on stderr (got: $err)" ;; esac
echo "PASS: 10 a malformed map falls back to the full set and says so"

# --- 11. missing map ---------------------------------------------------------
reset_env
QUALITY_GATES_SCOPE=diff
GATE_SELECTION_MAP_FILE="$TMP/does-not-exist.tsv"
GATE_SELECTION_CHANGED='docs/a.md'
gate_selection_resolve 2>"$TMP/err11"
err="$(cat "$TMP/err11")"
[ "$GATE_SELECTION_MODE" = "full" ] || fail "11: a missing map must fall back to the full set"
case "$err" in *"not found"*) : ;; *) fail "11: the missing map should be announced (got: $err)" ;; esac
echo "PASS: 11 a missing map falls back to the full set and says so"

# --- 12/13/14. real git repo -------------------------------------------------
REPO="$TMP/repo"
mkdir -p "$REPO/docs" "$REPO/src/lib"
git -C "$REPO" init -q
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name t
echo base >"$REPO/README.md"
git -C "$REPO" add -A
git -C "$REPO" commit -qm base
BASE="$(git -C "$REPO" rev-parse HEAD)"

# 12. unresolvable base
reset_env
QUALITY_GATES_SCOPE=diff
GATE_SELECTION_ROOT="$REPO"
GATE_SELECTION_BASE="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
gate_selection_resolve
[ "$GATE_SELECTION_MODE" = "full" ] || fail "12: an unresolvable base must fall back to the full set"
case "$GATE_SELECTION_REASON" in *"no resolvable diff base"*) : ;; *) fail "12: reason should name the base problem (got: $GATE_SELECTION_REASON)" ;; esac
echo "PASS: 12 an unresolvable diff base falls back to the full set"

# 13. empty diff (base == HEAD)
reset_env
QUALITY_GATES_SCOPE=diff
GATE_SELECTION_ROOT="$REPO"
GATE_SELECTION_BASE="$BASE"
gate_selection_resolve
[ "$GATE_SELECTION_MODE" = "full" ] || fail "13: an empty diff must fall back to the full set"
case "$GATE_SELECTION_REASON" in *"zero changed paths"*) : ;; *) fail "13: reason should name the empty diff (got: $GATE_SELECTION_REASON)" ;; esac
echo "PASS: 13 a diff with zero changed paths falls back to the full set"

# 14. a real narrowing decision over a real diff
echo hi >"$REPO/docs/guide.md"
git -C "$REPO" add -A
git -C "$REPO" commit -qm docs
reset_env
QUALITY_GATES_SCOPE=diff
GATE_SELECTION_ROOT="$REPO"
GATE_SELECTION_BASE="$BASE"
gate_selection_resolve
[ "$GATE_SELECTION_MODE" = "diff" ] || fail "14: a real docs-only diff should narrow (got $GATE_SELECTION_REASON)"
expected='make test-always
make test-docs
make test-unmapped'
[ "$GATE_SELECTION_SELECTED" = "$expected" ] || fail "14: wrong real-git selection:
$GATE_SELECTION_SELECTED"
echo "PASS: 14 a real git diff narrows the run to the docs-affected gates"

# --- 15. globs are never pathname-expanded -----------------------------------
# A bare `for glob in $globs` would expand `docs/**` against the CWD, silently
# replacing the author's pattern with whatever happens to exist on disk. Run
# from a directory that HAS a `docs/` and prove the pattern still behaves as a
# pattern (matching a path that does NOT exist on disk).
reset_env
QUALITY_GATES_SCOPE=diff
GATE_SELECTION_CHANGED='docs/never/created/on/disk.md'
( cd "$REPO" && gate_selection_resolve && [ "$GATE_SELECTION_MODE" = "diff" ] ) \
  || fail "15: a glob must be matched as a pattern, not pathname-expanded against the CWD"
echo "PASS: 15 globs are matched as patterns, never expanded against the working directory"

# --- 16. _SKIPPED is the exact complement of _SELECTED -----------------------
# The scoped run's whole safety story is that it can NAME what it did not run
# (temperloop#957). If _SKIPPED were computed loosely — or drifted from
# _SELECTED — a gate could be silently absent from both lists and a reader
# would have no way to notice. Assert the partition exactly.
reset_env
QUALITY_GATES_SCOPE=diff
GATE_SELECTION_CHANGED='docs/a.md'
gate_selection_resolve
[ "$GATE_SELECTION_MODE" = "diff" ] || fail "16: expected a diff-scoped run"
expected_skipped='make test-lib
make test-cli'
[ "$GATE_SELECTION_SKIPPED" = "$expected_skipped" ] || fail "16: wrong skipped set:
got:
$GATE_SELECTION_SKIPPED
want:
$expected_skipped"
union="$(printf '%s\n%s\n' "$GATE_SELECTION_SELECTED" "$GATE_SELECTION_SKIPPED" | sort)"
all_sorted="$(printf '%s\n' "$ALL_GATES" | sort)"
[ "$union" = "$all_sorted" ] || fail "16: selected+skipped must partition the full gate list exactly"
echo "PASS: 16 _SKIPPED names every un-run gate and partitions the list with _SELECTED"

# --- 17. a FULL run reports nothing skipped ----------------------------------
# A full run has nothing to disclose, and a stale _SKIPPED left over from a
# previous call would make one look scoped.
reset_env
QUALITY_GATES_SCOPE=diff
GATE_SELECTION_CHANGED='Makefile'
gate_selection_resolve
[ "$GATE_SELECTION_MODE" = "full" ] || fail "17: expected the ALL escalation"
[ -z "$GATE_SELECTION_SKIPPED" ] || fail "17: a full run must report an EMPTY skip list (got: $GATE_SELECTION_SKIPPED)"
echo "PASS: 17 a full run reports an empty skip list"

# --- 18. gate_selection_local_changed: commits + staged + unstaged + new -----
# The mid-work case (temperloop#957): a worker's changes are a MIX, and any
# source it misses is a gate it silently under-runs. Real git, real worktree.
LOCAL="$TMP/local"
mkdir -p "$LOCAL"
git -C "$LOCAL" init -q
git -C "$LOCAL" config user.email t@example.com
git -C "$LOCAL" config user.name t
mkdir -p "$LOCAL/src"
echo base >"$LOCAL/README.md"
git -C "$LOCAL" add -A && git -C "$LOCAL" commit -qm base
git -C "$LOCAL" branch -M main
git -C "$LOCAL" checkout -qb feature
echo committed >"$LOCAL/src/committed.sh"
git -C "$LOCAL" add -A && git -C "$LOCAL" commit -qm work
echo staged >"$LOCAL/src/staged.sh"
git -C "$LOCAL" add "$LOCAL/src/staged.sh"
echo unstaged >>"$LOCAL/README.md"
echo brand-new >"$LOCAL/src/untracked.sh"
printf 'ignored\n' >"$LOCAL/.gitignore"
git -C "$LOCAL" add "$LOCAL/.gitignore" && git -C "$LOCAL" commit -qm ignore
echo junk >"$LOCAL/ignored"
got="$(gate_selection_local_changed "$LOCAL")" || fail "18: local changed-set resolution failed"
for want in src/committed.sh src/staged.sh README.md src/untracked.sh; do
  case "$got" in *"$want"*) : ;; *) fail "18: local changed set is missing $want:
$got" ;; esac
done
case "$got" in *ignored*) fail "18: an IGNORED file must not enter the changed set:
$got" ;; esac
echo "PASS: 18 the local changed set unions committed, staged, unstaged and untracked (never ignored) paths"

# --- 19. no resolvable base -> non-zero (caller degrades to the FULL set) ----
# The one degradation that matters here: with no default-branch base, the
# committed half of the worker's change is invisible. Returning the
# working-tree half alone would be a SILENT NARROWING — the exact class this
# lib's five defenses exist for — so it must fail instead.
ORPHAN="$TMP/orphan"
mkdir -p "$ORPHAN"
git -C "$ORPHAN" init -q
git -C "$ORPHAN" config user.email t@example.com
git -C "$ORPHAN" config user.name t
git -C "$ORPHAN" checkout -qb sidetrack 2>/dev/null || true
echo x >"$ORPHAN/x.txt"
git -C "$ORPHAN" add -A && git -C "$ORPHAN" commit -qm x
if gate_selection_local_changed "$ORPHAN" >/dev/null 2>"$TMP/err19"; then
  fail "19: a checkout with no default-branch base must NOT report a changed set"
fi
case "$(cat "$TMP/err19")" in *merge-base*) : ;; *) fail "19: the failure should name the missing merge-base (got: $(cat "$TMP/err19"))" ;; esac
echo "PASS: 19 an unresolvable default-branch base fails loudly instead of narrowing on the working tree alone"

# --- 20. not a git checkout -> non-zero, named ------------------------------
NOTREPO="$TMP/notrepo"
mkdir -p "$NOTREPO"
if ( cd "$NOTREPO" && gate_selection_local_changed "$NOTREPO" >/dev/null 2>"$TMP/err20" ); then
  fail "20: a non-repo directory must not report a changed set"
fi
echo "PASS: 20 a non-git directory fails instead of reporting an empty (= narrowing) changed set"

# --- 21. the REAL gate-paths.tsv: depth-0 new-surface scripts select the
# check-surface and exec-bit registry validators (temperloop#1931) ----------
# The generic new-surface globs #1931 added are only useful if they also
# match a DEPTH-0 candidate (`workflows/scripts/validate-zzz.sh`), not just a
# nested one — `**/` needs an explicit depth-0 twin under this matcher (see
# gate-paths.tsv's own header note). Prove it against the REAL map, not a
# synthetic fixture, with a mix of depth-0 and nested new-surface paths.
REPO_ROOT="$(cd "$HERE/../../../.." && pwd)"
REAL_MAP="$REPO_ROOT/workflows/scripts/config/gate-paths.tsv"
[ -f "$REAL_MAP" ] || fail "21: real gate-paths.tsv not found at $REAL_MAP"
REAL_GATES='bash workflows/scripts/validate-check-surface-degenerate-coverage.sh
bash workflows/scripts/tests/test_check_surface_degenerate_coverage.sh
bash workflows/scripts/validate-exec-bit-registry.sh
bash workflows/scripts/tests/test_exec_bit_registry.sh'
for new_path in \
  workflows/scripts/validate-zzz.sh \
  workflows/scripts/tests/test_zzz.sh \
  workflows/scripts/config/check-zzz.sh
do
  reset_env
  QUALITY_GATES_SCOPE=diff
  GATE_SELECTION_MAP_FILE="$REAL_MAP"
  GATE_SELECTION_ALL_GATES="$REAL_GATES"
  GATE_SELECTION_CHANGED="$new_path"
  gate_selection_resolve
  [ "$GATE_SELECTION_MODE" = "diff" ] || fail "21 ($new_path): expected a diff-scoped run against the real map (got $GATE_SELECTION_MODE / $GATE_SELECTION_REASON)"
  [ "$GATE_SELECTION_SELECTED" = "$REAL_GATES" ] || fail "21 ($new_path): a brand-new candidate-shaped script must select all four check-surface/exec-bit registry-validator gates, got:
$GATE_SELECTION_SELECTED"
done
echo "PASS: 21 a brand-new check-*/validate-*/test_* script (depth-0 and nested) selects the check-surface and exec-bit registry validators against the real gate-paths.tsv"

# --- 22. a REGISTRATION-ONLY quality-gates.sh diff selects the registry
# validators instead of the ALL escalation (temperloop#1933) ----------------
# scripts/quality-gates.sh is on the ALL row, so adding ONE gate line escalated
# the whole run to the full ~110-gate set. A registration ADDS a gate; it cannot
# change what an existing gate runs. gate-selection.sh therefore reads the diff
# and, only when nothing was removed and every added line is a registration (or
# a comment/blank riding along), skips the ALL row FOR THAT PATH.
#
# Both shapes are proven here against the REAL gate-paths.tsv, because the
# narrowing is only correct if the map really routes scripts/quality-gates.sh to
# the registry validators: a synthetic fixture would prove the code path and
# hide a missing row. 22a is the registration-only shape; 22b/22c/22d are the
# "any other edit" shapes that must KEEP the full escalation.
REG_GATES='bash workflows/scripts/config/check-gate-paths.sh
bash workflows/scripts/config/tests/test_check_gate_paths.sh
bash workflows/scripts/validate-check-surface-degenerate-coverage.sh
bash workflows/scripts/tests/test_check_surface_degenerate_coverage.sh
bash workflows/scripts/config/check-setting-registry.sh
bash workflows/scripts/validate-feature-docs.sh
bash workflows/scripts/validate-exec-bit-registry.sh
bash workflows/scripts/tests/test_exec_bit_registry.sh
make test-kernel-manifest
make test-env-hygiene-report
bash workflows/scripts/tests/test_ready_pr_sweep.sh'
# Everything above except the last two: the last-but-one is the CONTROL (a real,
# mapped gate no quality-gates.sh path reaches, so narrowing must leave it out)
# and the last is the gate the fixture diff REGISTERS.
REG_CONTROL='make test-env-hygiene-report'
REG_NEW='bash workflows/scripts/tests/test_ready_pr_sweep.sh'

reg_env() {
  reset_env
  QUALITY_GATES_SCOPE=diff
  GATE_SELECTION_MAP_FILE="$REAL_MAP"
  GATE_SELECTION_ALL_GATES="$REG_GATES"
  GATE_SELECTION_CHANGED='scripts/quality-gates.sh'
}

# 22a — nothing removed, added lines are a comment plus one registration.
reg_env
GATE_SELECTION_DIFF_TEXT="$(cat <<'DIFF'
diff --git a/scripts/quality-gates.sh b/scripts/quality-gates.sh
index 1111111..2222222 100755
--- a/scripts/quality-gates.sh
+++ b/scripts/quality-gates.sh
@@ -1919,0 +1920,3 @@ KERNEL_GATES+=("bash workflows/scripts/lib/tests/test_gate_selection.sh")
+
+# A brand-new gate, registered the ordinary way (temperloop#1933 fixture).
+KERNEL_GATES+=("bash workflows/scripts/tests/test_ready_pr_sweep.sh")
DIFF
)"
gate_selection_resolve
[ "$GATE_SELECTION_MODE" = "diff" ] || fail "22a: a registration-only quality-gates.sh diff must NOT escalate (got $GATE_SELECTION_MODE / $GATE_SELECTION_REASON)"
case "$GATE_SELECTION_REASON" in *REGISTRATION-ONLY*) : ;; *) fail "22a: the reason must SAY the ALL escalation was declined (got: $GATE_SELECTION_REASON)" ;; esac
for want in \
  'bash workflows/scripts/config/check-gate-paths.sh' \
  'bash workflows/scripts/config/tests/test_check_gate_paths.sh' \
  'bash workflows/scripts/validate-check-surface-degenerate-coverage.sh' \
  'bash workflows/scripts/tests/test_check_surface_degenerate_coverage.sh' \
  'bash workflows/scripts/config/check-setting-registry.sh' \
  'bash workflows/scripts/validate-feature-docs.sh' \
  'bash workflows/scripts/validate-exec-bit-registry.sh' \
  'bash workflows/scripts/tests/test_exec_bit_registry.sh' \
  'make test-kernel-manifest'
do
  case "$GATE_SELECTION_SELECTED" in *"$want"*) : ;; *) fail "22a: the registry validator '$want' must be selected, got:
$GATE_SELECTION_SELECTED" ;; esac
done
case "$GATE_SELECTION_SELECTED" in *"$REG_NEW"*) : ;; *) fail "22a: the NEWLY REGISTERED gate must run on the PR that adds it, got:
$GATE_SELECTION_SELECTED" ;; esac
case "$GATE_SELECTION_SELECTED" in *"$REG_CONTROL"*) fail "22a: narrowing must still LEAVE OUT an unrelated mapped gate ($REG_CONTROL), got:
$GATE_SELECTION_SELECTED" ;; esac
case "$GATE_SELECTION_SKIPPED" in *"$REG_CONTROL"*) : ;; *) fail "22a: the skipped list must NAME the unrelated gate (got: $GATE_SELECTION_SKIPPED)" ;; esac
echo "PASS: 22a a registration-only quality-gates.sh diff selects the registry validators plus the newly registered gate, not the ALL escalation"

# 22b — ANY removed line means the edit is not a pure registration. This is the
# general case the exception must not weaken: an edited or deleted gate line can
# change what an EXISTING gate runs, which is exactly what the ALL row guards.
reg_env
GATE_SELECTION_DIFF_TEXT="$(cat <<'DIFF'
diff --git a/scripts/quality-gates.sh b/scripts/quality-gates.sh
index 1111111..2222222 100755
--- a/scripts/quality-gates.sh
+++ b/scripts/quality-gates.sh
@@ -1919 +1919,2 @@ KERNEL_GATES+=("bash a.sh")
-KERNEL_GATES+=("bash workflows/scripts/lib/tests/test_gate_selection.sh")
+KERNEL_GATES+=("bash workflows/scripts/tests/test_ready_pr_sweep.sh")
DIFF
)"
gate_selection_resolve
[ "$GATE_SELECTION_MODE" = "full" ] || fail "22b: a diff that REMOVES a line must keep the full escalation (got $GATE_SELECTION_MODE / $GATE_SELECTION_REASON)"
case "$GATE_SELECTION_REASON" in *"ALL escalation"*) : ;; *) fail "22b: the reason should name the ALL escalation (got: $GATE_SELECTION_REASON)" ;; esac
echo "PASS: 22b a quality-gates.sh diff with a removed line keeps the full escalation"

# 22c — an added line that is not a registration (here: real logic) escalates.
reg_env
GATE_SELECTION_DIFF_TEXT="$(cat <<'DIFF'
diff --git a/scripts/quality-gates.sh b/scripts/quality-gates.sh
index 1111111..2222222 100755
--- a/scripts/quality-gates.sh
+++ b/scripts/quality-gates.sh
@@ -1919,0 +1920,2 @@ KERNEL_GATES+=("bash a.sh")
+KERNEL_GATES+=("bash workflows/scripts/tests/test_ready_pr_sweep.sh")
+QG_BUDGET_SECS=1
DIFF
)"
gate_selection_resolve
[ "$GATE_SELECTION_MODE" = "full" ] || fail "22c: a non-registration added line must keep the full escalation (got $GATE_SELECTION_MODE / $GATE_SELECTION_REASON)"
echo "PASS: 22c a quality-gates.sh diff mixing real logic into the additions keeps the full escalation"

# 22d — comments and blanks alone are NOT a registration. The exception exists
# for registering a gate, so a diff with no registration in it escalates rather
# than narrowing on the strength of "well, nothing executable changed".
reg_env
GATE_SELECTION_DIFF_TEXT="$(cat <<'DIFF'
diff --git a/scripts/quality-gates.sh b/scripts/quality-gates.sh
index 1111111..2222222 100755
--- a/scripts/quality-gates.sh
+++ b/scripts/quality-gates.sh
@@ -1919,0 +1920,2 @@ KERNEL_GATES+=("bash a.sh")
+# Just a comment.
+
DIFF
)"
gate_selection_resolve
[ "$GATE_SELECTION_MODE" = "full" ] || fail "22d: a comment-only diff must keep the full escalation (got $GATE_SELECTION_MODE / $GATE_SELECTION_REASON)"
echo "PASS: 22d a comment-only quality-gates.sh diff keeps the full escalation"

# 22e — a splat registration (`+=("${ARRAY[@]}")`) names gates this probe cannot
# resolve, so it must NOT be read as a narrowable registration.
reg_env
GATE_SELECTION_DIFF_TEXT="$(cat <<'DIFF'
diff --git a/scripts/quality-gates.sh b/scripts/quality-gates.sh
index 1111111..2222222 100755
--- a/scripts/quality-gates.sh
+++ b/scripts/quality-gates.sh
@@ -1919,0 +1920 @@ KERNEL_GATES+=("bash a.sh")
+KERNEL_GATES+=("${SOME_OTHER_GATES[@]}")
DIFF
)"
gate_selection_resolve
[ "$GATE_SELECTION_MODE" = "full" ] || fail "22e: a splat registration must keep the full escalation (got $GATE_SELECTION_MODE / $GATE_SELECTION_REASON)"
echo "PASS: 22e a splat registration, whose gate names are unknowable, keeps the full escalation"

# 22f — no readable diff (no seam, no resolvable base) escalates. The probe
# fails CLOSED: an unreadable diff is not evidence that nothing was removed.
reg_env
gate_selection_resolve
[ "$GATE_SELECTION_MODE" = "full" ] || fail "22f: an unreadable quality-gates.sh diff must keep the full escalation (got $GATE_SELECTION_MODE / $GATE_SELECTION_REASON)"
echo "PASS: 22f an unreadable quality-gates.sh diff fails closed to the full escalation"

# 22g — END TO END against a REAL git repo, no fixture seam. 22a-22f drive the
# classifier through GATE_SELECTION_DIFF_TEXT, which leaves the half that
# actually produces the diff (_gs_qg_diff: base resolution, `<base>...HEAD`
# unioned with the working tree) unproven. Here the registration is a real
# commit, the base is a real SHA, and git renders the diff. Also covers the
# mid-work shape the /build worker hits: an UNCOMMITTED second registration.
REG_REPO="$TMP/regrepo"
mkdir -p "$REG_REPO/scripts"
git -C "$REG_REPO" init -q
git -C "$REG_REPO" config user.email t@example.com
git -C "$REG_REPO" config user.name t
printf 'KERNEL_GATES=()\nKERNEL_GATES+=("make test-kernel-manifest")\n' >"$REG_REPO/scripts/quality-gates.sh"
git -C "$REG_REPO" add -A && git -C "$REG_REPO" commit -qm base
REG_BASE="$(git -C "$REG_REPO" rev-parse HEAD)"
{
  printf '\n# A new gate, registered the ordinary way.\n'
  printf 'KERNEL_GATES+=("bash workflows/scripts/tests/test_ready_pr_sweep.sh")\n'
} >>"$REG_REPO/scripts/quality-gates.sh"
git -C "$REG_REPO" add -A && git -C "$REG_REPO" commit -qm register
# ...and one more, still uncommitted, as a mid-work worker would have it.
printf 'KERNEL_GATES+=("make test-env-hygiene-report")\n' >>"$REG_REPO/scripts/quality-gates.sh"
reg_env
GATE_SELECTION_ROOT="$REG_REPO"
GATE_SELECTION_BASE="$REG_BASE"
gate_selection_resolve
[ "$GATE_SELECTION_MODE" = "diff" ] || fail "22g: a REAL registration-only commit must not escalate (got $GATE_SELECTION_MODE / $GATE_SELECTION_REASON)"
for want in "$REG_NEW" "$REG_CONTROL" 'bash workflows/scripts/validate-exec-bit-registry.sh'; do
  case "$GATE_SELECTION_SELECTED" in *"$want"*) : ;; *) fail "22g: expected '$want' in the selection, got:
$GATE_SELECTION_SELECTED" ;; esac
done
echo "PASS: 22g a real registration-only diff (committed + uncommitted halves) narrows against a real git tree"

# 22h — the same real repo, with a line REMOVED in the working tree. The
# uncommitted half must be able to veto on its own, or a worker could delete a
# gate mid-work and still get the narrow run.
printf 'KERNEL_GATES=()\nKERNEL_GATES+=("bash workflows/scripts/tests/test_ready_pr_sweep.sh")\n' >"$REG_REPO/scripts/quality-gates.sh"
reg_env
GATE_SELECTION_ROOT="$REG_REPO"
GATE_SELECTION_BASE="$REG_BASE"
gate_selection_resolve
[ "$GATE_SELECTION_MODE" = "full" ] || fail "22h: an UNCOMMITTED removal must still keep the full escalation (got $GATE_SELECTION_MODE / $GATE_SELECTION_REASON)"
echo "PASS: 22h a removal in the uncommitted half alone still keeps the full escalation"

# 22i — THE PINNED SECOND SLICE (temperloop#1663 x #1933). This is the DEFAULT
# /build path, and the state 22a-22h all miss: build-level.mjs runs the
# acceptance gate in slices, and quality-gates.sh re-initialises
# GATE_SELECTION_LOCAL_BASE="" per process, filling it only on the FIRST slice.
# Slice 2..N reuses the PINNED changed set and never calls the resolver that
# fills it, and no $LEAK_GUARD_BASE exists on a local run — so the probe had NO
# base at all and the ALL row fired. The cost is not a lost narrowing: slice 1
# narrows, slice 2 widens, and the #1663 drift guard then RESTARTS FROM GATE 0
# ON THE FULL SET, so the feature made its own target diff SLOWER than before it
# existed. The selection must therefore be byte-identical across the two states.
REG_REPO2="$TMP/regrepo2"
mkdir -p "$REG_REPO2/scripts"
git -C "$REG_REPO2" init -q
git -C "$REG_REPO2" config user.email t@example.com
git -C "$REG_REPO2" config user.name t
printf 'KERNEL_GATES=()\nKERNEL_GATES+=("make test-kernel-manifest")\n' >"$REG_REPO2/scripts/quality-gates.sh"
git -C "$REG_REPO2" add -A && git -C "$REG_REPO2" commit -qm base
# Leave the default branch (main or master, whichever `git init` chose) parked on
# the base commit so the base fallback has a candidate to walk to, exactly as a
# /build worktree branched off origin/main does.
git -C "$REG_REPO2" checkout -q -b work
printf 'KERNEL_GATES+=("%s")\n' "$REG_NEW" >>"$REG_REPO2/scripts/quality-gates.sh"
git -C "$REG_REPO2" add -A && git -C "$REG_REPO2" commit -qm register

PIN="$TMP/pin-changed"
# --- slice 1: the resolver runs, publishes the base, and writes the pin.
reg_env
GATE_SELECTION_ROOT="$REG_REPO2"
GATE_SELECTION_LOCAL_BASE=""
gate_selection_local_changed_to_file "$REG_REPO2" "$PIN" ||
  fail "22i: fixture setup — no local changed set resolvable in $REG_REPO2"
[ -n "$GATE_SELECTION_LOCAL_BASE" ] || fail "22i: fixture setup — slice 1 published no local base"
GATE_SELECTION_CHANGED="$(cat "$PIN")"
gate_selection_resolve
[ "$GATE_SELECTION_MODE" = "diff" ] || fail "22i: slice 1 must narrow (got $GATE_SELECTION_MODE / $GATE_SELECTION_REASON)"
SLICE1_SELECTED="$GATE_SELECTION_SELECTED"

# --- slice 2..N: the SAME pin, in a fresh process. No base from either input.
reg_env
GATE_SELECTION_ROOT="$REG_REPO2"
GATE_SELECTION_LOCAL_BASE=""
GATE_SELECTION_CHANGED="$(cat "$PIN")"
gate_selection_resolve
[ "$GATE_SELECTION_MODE" = "diff" ] || fail "22i: a PINNED later slice must narrow identically to slice 1, not re-escalate (got $GATE_SELECTION_MODE / $GATE_SELECTION_REASON)"
[ "$GATE_SELECTION_SELECTED" = "$SLICE1_SELECTED" ] || fail "22i: the selection must be IDENTICAL across slices — a changed fingerprint restarts the whole suite from gate 0 on the FULL set (temperloop#1663). slice1:
$SLICE1_SELECTED
slice2:
$GATE_SELECTION_SELECTED"
echo "PASS: 22i a pinned later slice resolves its own probe base and selects exactly what slice 1 selected"

# 22j — the same pinned slice under diff.mnemonicPrefix / diff.noprefix. Those
# render the diff header as `--- c/… +++ w/…` or as bare paths, which the
# classifier would read as an added non-registration line: the exception fails
# closed and is SILENTLY dead for any developer or runner carrying those common
# settings. The call site pins the prefixes, so the config cannot reach it.
git -C "$REG_REPO2" config diff.mnemonicprefix true
git -C "$REG_REPO2" config diff.noprefix true
reg_env
GATE_SELECTION_ROOT="$REG_REPO2"
GATE_SELECTION_LOCAL_BASE=""
GATE_SELECTION_CHANGED="$(cat "$PIN")"
gate_selection_resolve
[ "$GATE_SELECTION_MODE" = "diff" ] || fail "22j: diff.mnemonicPrefix/diff.noprefix must not disable the exception (got $GATE_SELECTION_MODE / $GATE_SELECTION_REASON)"
git -C "$REG_REPO2" config --unset diff.mnemonicprefix
git -C "$REG_REPO2" config --unset diff.noprefix
echo "PASS: 22j the registration probe pins its own diff prefixes, so a mnemonic/no-prefix git config cannot silently kill the exception"

# 22n — the THIRD knob on the same seam: a configured `diff.external` replaces
# git's rendering wholesale, so the probe would read whatever that tool prints
# instead of a unified diff. Like 22j this fails CLOSED rather than wrong, but a
# capability that silently never fires is indistinguishable from one that found
# nothing — and unlike the prefix knobs, no prefix pin can defend against it.
# `--no-ext-diff` at the call site is what does; this pins that it is there.
cat >"$TMP/ext-diff.sh" <<'EXT'
#!/bin/sh
# A stand-in for any real external differ: valid output, but not a unified diff.
echo "<<< external diff tool output — not a unified diff >>>"
EXT
chmod +x "$TMP/ext-diff.sh"
git -C "$REG_REPO2" config diff.external "$TMP/ext-diff.sh"
reg_env
GATE_SELECTION_ROOT="$REG_REPO2"
GATE_SELECTION_LOCAL_BASE=""
GATE_SELECTION_CHANGED="$(cat "$PIN")"
gate_selection_resolve
[ "$GATE_SELECTION_MODE" = "diff" ] || fail "22n: a configured diff.external must not disable the exception — --no-ext-diff pins it (got $GATE_SELECTION_MODE / $GATE_SELECTION_REASON)"
git -C "$REG_REPO2" config --unset diff.external
echo "PASS: 22n a configured diff.external cannot silently kill the exception either"

# 22k — SKIPPED_KERNEL_GATES is a skip-DISCLOSURE array, not a run set, and its
# name also ends `_GATES`. Adding one of its human-sentence elements read as a
# registration: the ALL row was declined and the sentence was counted as a gate.
# That is the FAIL-OPEN direction the header promises cannot happen. The literal
# is not in the caller gate list, so it now escalates.
reg_env
GATE_SELECTION_DIFF_TEXT="$(cat <<'DIFF'
diff --git a/scripts/quality-gates.sh b/scripts/quality-gates.sh
index 1111111..2222222 100755
--- a/scripts/quality-gates.sh
+++ b/scripts/quality-gates.sh
@@ -1876,0 +1877 @@ KERNEL_GATES+=("bash a.sh")
+  SKIPPED_KERNEL_GATES+=("test_update_kernel.sh — not the seam-bearing version")
DIFF
)"
gate_selection_resolve
[ "$GATE_SELECTION_MODE" = "full" ] || fail "22k: a SKIPPED_KERNEL_GATES disclosure line is not a registration and must keep the full escalation (got $GATE_SELECTION_MODE / $GATE_SELECTION_REASON)"
echo "PASS: 22k a skip-disclosure line whose array name also ends _GATES keeps the full escalation"

# 22l — the CANONICAL registration site: a bare element of the KERNEL_GATES=( … )
# array literal, which quality-gates.sh calls the ONE place this list is typed.
# It diffs as `+  "make test-foo"` and was the one idiomatic shape the exception
# missed, so the most obvious way to register a gate got the widest possible run.
reg_env
GATE_SELECTION_DIFF_TEXT="$(cat <<'DIFF'
diff --git a/scripts/quality-gates.sh b/scripts/quality-gates.sh
index 1111111..2222222 100755
--- a/scripts/quality-gates.sh
+++ b/scripts/quality-gates.sh
@@ -119,0 +120 @@ KERNEL_GATES=(
+  "bash workflows/scripts/tests/test_ready_pr_sweep.sh"
DIFF
)"
gate_selection_resolve
[ "$GATE_SELECTION_MODE" = "diff" ] || fail "22l: a bare array-literal registration must narrow (got $GATE_SELECTION_MODE / $GATE_SELECTION_REASON)"
case "$GATE_SELECTION_SELECTED" in *"$REG_NEW"*) : ;; *) fail "22l: the newly registered gate must run on the PR that adds it, got:
$GATE_SELECTION_SELECTED" ;; esac
echo "PASS: 22l a bare element added to the KERNEL_GATES array literal is a registration too"

# 22m — ...and a bare quoted literal that is NOT a gate in the run list is just a
# string, so it must not buy the narrow run. This is what makes 22l safe: the
# membership requirement, not the line shape, is the load-bearing half.
reg_env
GATE_SELECTION_DIFF_TEXT="$(cat <<'DIFF'
diff --git a/scripts/quality-gates.sh b/scripts/quality-gates.sh
index 1111111..2222222 100755
--- a/scripts/quality-gates.sh
+++ b/scripts/quality-gates.sh
@@ -119,0 +120 @@ SOME_OTHER_LIST=(
+  "not a gate command at all"
DIFF
)"
gate_selection_resolve
[ "$GATE_SELECTION_MODE" = "full" ] || fail "22m: a bare literal that is not a gate in the caller list must keep the full escalation (got $GATE_SELECTION_MODE / $GATE_SELECTION_REASON)"
echo "PASS: 22m a bare quoted literal that names no gate in the run list keeps the full escalation"

# 22o — THE FAIL-OPEN THE BARE-ELEMENT SHAPE OPENED. `SERIAL_LANE_PINS=( … )` and
# `SLOW_DISPATCH_HINTS=( … )` are two OTHER arrays in quality-gates.sh whose
# elements are bare quoted gate command lines that ARE in the run set, so shape +
# membership classified a pure addition to either as registration-only. A
# serial-lane pin is not a registration: it is a correctness-bearing concurrency
# decision (temperloop#1379 measured a real data race there), and the narrow run
# it bought SKIPPED test_quality_gates_parallel.sh — the one gate that would prove
# a lane change safe. Driven against a REAL repo, not the fixture seam, because
# the defence is git's own hunk-header funcname context: a hand-written `@@` line
# would prove the branch and assume the rendering.
REG_REPO3="$TMP/regrepo3"
mkdir -p "$REG_REPO3/scripts"
git -C "$REG_REPO3" init -q
git -C "$REG_REPO3" config user.email t@example.com
git -C "$REG_REPO3" config user.name t
cat >"$REG_REPO3/scripts/quality-gates.sh" <<'QG'
KERNEL_GATES=(
  "make test-kernel-manifest"
)
SERIAL_LANE_PINS=(
  "make test-kernel-manifest"
)
QG
git -C "$REG_REPO3" add -A && git -C "$REG_REPO3" commit -qm base
REG_BASE3="$(git -C "$REG_REPO3" rev-parse HEAD)"
# ...and the reviewer's reproduction: ONE bare element added under SERIAL_LANE_PINS,
# naming a gate that really is in the run set.
awk -v line="  \"$REG_NEW\"" '{print} /^SERIAL_LANE_PINS=\(/{print line}' \
  "$REG_REPO3/scripts/quality-gates.sh" >"$TMP/qg3" && mv "$TMP/qg3" "$REG_REPO3/scripts/quality-gates.sh"
reg_env
GATE_SELECTION_ROOT="$REG_REPO3"
GATE_SELECTION_BASE="$REG_BASE3"
gate_selection_resolve
[ "$GATE_SELECTION_MODE" = "full" ] || fail "22o: a SERIAL_LANE_PINS addition is NOT a registration and must keep the full escalation (got $GATE_SELECTION_MODE / $GATE_SELECTION_REASON)"
echo "PASS: 22o a bare element added to the serial-lane pin list keeps the full escalation, so the parallel-scheduler gate still runs"

# 22p — the DISCRIMINATING other half of 22o, in the SAME real repo: the bare
# element goes into KERNEL_GATES=( … ) instead, and must still narrow. Without
# this, 22o passes just as well for a positional test that denies every bare
# element — i.e. for a silently dead capability.
git -C "$REG_REPO3" checkout -- scripts/quality-gates.sh
awk -v line="  \"$REG_NEW\"" '{print} /^KERNEL_GATES=\(/{print line}' \
  "$REG_REPO3/scripts/quality-gates.sh" >"$TMP/qg3" && mv "$TMP/qg3" "$REG_REPO3/scripts/quality-gates.sh"
reg_env
GATE_SELECTION_ROOT="$REG_REPO3"
GATE_SELECTION_BASE="$REG_BASE3"
gate_selection_resolve
[ "$GATE_SELECTION_MODE" = "diff" ] || fail "22p: the SAME bare element inside KERNEL_GATES=( … ) must still narrow (got $GATE_SELECTION_MODE / $GATE_SELECTION_REASON)"
case "$GATE_SELECTION_SELECTED" in *"$REG_NEW"*) : ;; *) fail "22p: the newly registered gate must run on the PR that adds it, got:
$GATE_SELECTION_SELECTED" ;; esac
echo "PASS: 22p the same bare element inside the KERNEL_GATES array literal still narrows — the positional test discriminates, it does not just deny"

# 22q — the FOURTH knob on the pinned-diff seam (22j pins two, 22n the third): a
# `.gitattributes` diff driver whose `textconv` rewrites every line's CONTENT
# before git diffs it. `--no-ext-diff` does NOT disable textconv; `--no-textconv`
# does. Like 22j/22n it fails CLOSED — the mangled literal fails membership — but
# a capability that silently never fires is indistinguishable from one that found
# nothing, which is the whole reason this seam is pinned rather than trusted.
git -C "$REG_REPO3" checkout -- scripts/quality-gates.sh
cat >"$TMP/textconv.sh" <<'TC'
#!/bin/sh
sed 's/test_ready_pr_sweep/MANGLED/' "$1"
TC
chmod +x "$TMP/textconv.sh"
printf 'scripts/quality-gates.sh diff=mangle\n' >"$REG_REPO3/.gitattributes"
git -C "$REG_REPO3" config diff.mangle.textconv "$TMP/textconv.sh"
awk -v line="  \"$REG_NEW\"" '{print} /^KERNEL_GATES=\(/{print line}' \
  "$REG_REPO3/scripts/quality-gates.sh" >"$TMP/qg3" && mv "$TMP/qg3" "$REG_REPO3/scripts/quality-gates.sh"
reg_env
GATE_SELECTION_ROOT="$REG_REPO3"
GATE_SELECTION_BASE="$REG_BASE3"
gate_selection_resolve
[ "$GATE_SELECTION_MODE" = "diff" ] || fail "22q: a configured textconv diff driver must not disable the exception — --no-textconv pins it (got $GATE_SELECTION_MODE / $GATE_SELECTION_REASON)"
rm -f "$REG_REPO3/.gitattributes"
git -C "$REG_REPO3" config --unset diff.mangle.textconv
git -C "$REG_REPO3" checkout -- scripts/quality-gates.sh
echo "PASS: 22q a .gitattributes textconv driver cannot silently kill the exception either"

# 22r — a REMOVED line must veto even when its own content looks like a diff
# header. With -U0, a removed `-- a/x` renders as `--- a/x` and a removed
# `++ b/x` as `+++ b/x`; the header skip matched on prefix alone and ran BEFORE
# the removal check, so the removal was swallowed and never vetoed. Header
# recognition is now confined to the region before a file's first `@@`, which is
# structural rather than a bet on what quality-gates.sh happens to contain.
reg_env
GATE_SELECTION_DIFF_TEXT="$(cat <<'DIFF'
diff --git a/scripts/quality-gates.sh b/scripts/quality-gates.sh
index 1111111..2222222 100755
--- a/scripts/quality-gates.sh
+++ b/scripts/quality-gates.sh
@@ -1919,0 +1920 @@ KERNEL_GATES+=("bash a.sh")
+KERNEL_GATES+=("bash workflows/scripts/tests/test_ready_pr_sweep.sh")
@@ -2000 +2000,0 @@ KERNEL_GATES=(
--- a/legacy-shim
DIFF
)"
gate_selection_resolve
[ "$GATE_SELECTION_MODE" = "full" ] || fail "22r: a removed line whose content reads like a diff header must still veto (got $GATE_SELECTION_MODE / $GATE_SELECTION_REASON)"
echo "PASS: 22r a removed line disguised as a --- header is not swallowed by the header skip"


# --- 23. a RENAME pulls the SOURCE tree's gates back in (temperloop#1695) ----
# git's rename detection is ON by default and reports a rename as ONE entry
# carrying the DESTINATION path. So moving a file OUT of a gated tree used to
# leave the SOURCE tree out of the changed set entirely: the tree lost a file
# and nothing re-ran its gates. `--no-renames` renders the same change as a
# delete plus an add, so both paths land in the changed set — defense 5 in
# gate-selection.sh's header, and the same widen-on-doubt bet as defenses 1/2/4.
#
# Both halves are real git, because this is a property of what `git diff`
# EMITS: a hand-seeded GATE_SELECTION_CHANGED would prove nothing at all here.
# The destination is `attic/` — a path the fixture map recognises via its `none`
# row — so a miss shows up as a NARROWED run rather than being masked by the
# unmapped-path escalation.

# 23a — the COMMITTED half: the `<base>...HEAD` three-dot form the CI path uses.
RENREPO="$TMP/renrepo"
mkdir -p "$RENREPO/src/lib" "$RENREPO/attic"
git -C "$RENREPO" init -q
git -C "$RENREPO" config user.email t@example.com
git -C "$RENREPO" config user.name t
git -C "$RENREPO" branch -M main
printf 'lib body\nline two\nline three\n' >"$RENREPO/src/lib/mod.sh"
git -C "$RENREPO" add -A && git -C "$RENREPO" commit -qm base
REN_BASE="$(git -C "$RENREPO" rev-parse HEAD)"
git -C "$RENREPO" mv src/lib/mod.sh attic/mod.sh
git -C "$RENREPO" commit -qm 'move mod.sh out of the gated tree'
# Sanity: git really DOES detect this as a rename, so the case is live rather
# than accidentally passing because the diff never looked like one.
case "$(git -C "$RENREPO" diff -M --name-status "${REN_BASE}...HEAD")" in
  R*) : ;;
  *) fail "23a: fixture is not a detected rename — the case would prove nothing:
$(git -C "$RENREPO" diff -M --name-status "${REN_BASE}...HEAD")" ;;
esac
reset_env
QUALITY_GATES_SCOPE=diff
GATE_SELECTION_ROOT="$RENREPO"
GATE_SELECTION_BASE="$REN_BASE"
gate_selection_resolve
[ "$GATE_SELECTION_MODE" = "diff" ] || fail "23a: expected a diff-scoped run (got $GATE_SELECTION_MODE / $GATE_SELECTION_REASON)"
case "$GATE_SELECTION_MATCHED" in *"src/lib/mod.sh"*) : ;; *) fail "23a: the RENAMED-AWAY source path must enter the changed set, got:
$GATE_SELECTION_MATCHED" ;; esac
case "$GATE_SELECTION_SELECTED" in *"make test-lib"*) : ;; *) fail "23a: a file leaving src/lib/ must still select that tree's gate, got:
$GATE_SELECTION_SELECTED" ;; esac
echo "PASS: 23a a committed rename out of a gated tree still selects the SOURCE tree's gate"

# 23b — the WORKING-TREE half: `git diff --name-only HEAD`, the mid-work
# `--scoped` path a /build worker runs. A worker who `git mv`s a file and has
# not committed yet must see the same widening; rename detection applies to
# this diff too.
RENLOCAL="$TMP/renlocal"
mkdir -p "$RENLOCAL/src/lib" "$RENLOCAL/attic"
git -C "$RENLOCAL" init -q
git -C "$RENLOCAL" config user.email t@example.com
git -C "$RENLOCAL" config user.name t
git -C "$RENLOCAL" branch -M main
printf 'lib body\nline two\nline three\n' >"$RENLOCAL/src/lib/mod.sh"
git -C "$RENLOCAL" add -A && git -C "$RENLOCAL" commit -qm base
git -C "$RENLOCAL" mv src/lib/mod.sh attic/mod.sh
got23="$(gate_selection_local_changed "$RENLOCAL")" || fail "23b: local changed-set resolution failed"
for want in src/lib/mod.sh attic/mod.sh; do
  case "$got23" in *"$want"*) : ;; *) fail "23b: an UNCOMMITTED rename must list BOTH paths, missing $want:
$got23" ;; esac
done
echo "PASS: 23b an uncommitted (staged) rename lists both the source and the destination path"

# --- 24. PATTERN KEYS (temperloop#2162) --------------------------------------
# quality-gates.sh now glob-expands two test directories into one gate PER
# SCRIPT. The map cannot carry a literal row per script without reinstating the
# hand-enumeration trap the expansion exists to remove, so a row key may be a
# PATTERN that globs a whole family of gates — with EXACT keys still winning,
# so one script inside a family can keep its own pinpoint row.
#
# ONE RULE, stated once: a gate runs when ANY row that names it was selected —
# its own literal row, a pattern row that globs it, or both, UNIONED. The rows
# are never ranked. 24b, 24c and 24e are the cases that make that rule
# load-bearing rather than decorative: 24c pins that a pinpoint row does not
# drag its siblings in, and 24e pins that it does not EXCLUDE its own family
# row either — the narrowing direction, which is the silent-green one.
PMAP="$TMP/gate-paths-pattern.tsv"
cat >"$PMAP" <<'EOF'
# fixture map: one family row, plus a pinpoint row for one family member
ALL	Makefile
none	LICENSE
make test-always	ALWAYS
bash suite.sh --run tests/test_*.sh	src/**
bash suite.sh --run tests/test_special.sh	fixtures/special.json
make test-docs	docs/**
EOF
PGATES='make test-always
bash suite.sh --run tests/test_alpha.sh
bash suite.sh --run tests/test_beta.sh
bash suite.sh --run tests/test_special.sh
make test-docs'

reset_pattern_env() {
  unset QUALITY_GATES_SCOPE GITHUB_EVENT_NAME GATE_SELECTION_CHANGED GATE_SELECTION_DIFF_TEXT
  GATE_SELECTION_ROOT="$TMP"
  GATE_SELECTION_MAP_FILE="$PMAP"
  GATE_SELECTION_ALL_GATES="$PGATES"
  GATE_SELECTION_BASE=""
  QUALITY_GATES_SCOPE=diff
}

# 24a — one pattern row maps a whole family. A `src/**` change selects EVERY
#       member the family row globs — INCLUDING test_special.sh, which also
#       carries its own pinpoint row. The pinpoint row ADDS a trigger
#       (fixtures/special.json); it must never SUBTRACT the family row's.
#       An exact-wins precedence here shipped in the first cut of #2162 and
#       silently dropped five real suites from a scoped CI run.
reset_pattern_env
GATE_SELECTION_CHANGED='src/thing.sh'
gate_selection_resolve
[ "$GATE_SELECTION_MODE" = "diff" ] || fail "24a: expected a diff-scoped run (got $GATE_SELECTION_MODE / $GATE_SELECTION_REASON)"
expected24a='make test-always
bash suite.sh --run tests/test_alpha.sh
bash suite.sh --run tests/test_beta.sh
bash suite.sh --run tests/test_special.sh'
[ "$GATE_SELECTION_SELECTED" = "$expected24a" ] || fail "24a: a pattern key must select EVERY family member it globs, a member's own pinpoint row notwithstanding:
got:
$GATE_SELECTION_SELECTED
want:
$expected24a"
echo "PASS: 24a a pattern row maps the whole family it globs, including a member that has its own row"

# 24b — the family is genuinely SCOPED, not merely unmapped. Without pattern
#       matching every member would have no row at all and defense 4 would keep
#       it unconditionally: the run would look narrowed while the biggest
#       family in the set ran on every diff. So an unrelated change must SKIP
#       the members, and the skip must be NAMED.
reset_pattern_env
GATE_SELECTION_CHANGED='docs/a.md'
gate_selection_resolve
case "$GATE_SELECTION_SELECTED" in
  *test_alpha*) fail "24b: an unrelated change must SKIP the family — the pattern row was not honoured as a mapping:
$GATE_SELECTION_SELECTED" ;;
esac
case "$GATE_SELECTION_SKIPPED" in
  *test_alpha*) : ;;
  *) fail "24b: the skipped list must NAME the un-run family member:
$GATE_SELECTION_SKIPPED" ;;
esac
echo "PASS: 24b a pattern-mapped gate is genuinely scoped (skipped, and named, on an unrelated change)"

# 24c — THE UNION ONLY WIDENS THE GATE THAT IS NAMED. `fixtures/special.json`
#       is claimed by the pinpoint row alone, so only test_special runs: the
#       union is over the rows that name ONE gate, never a transitive closure
#       that would drag alpha and beta in through their shared family row and
#       make the pinpoint row decorative.
reset_pattern_env
GATE_SELECTION_CHANGED='fixtures/special.json'
gate_selection_resolve
expected24c='make test-always
bash suite.sh --run tests/test_special.sh'
[ "$GATE_SELECTION_SELECTED" = "$expected24c" ] || fail "24c: a pinpoint row must select its own gate and no sibling:
got:
$GATE_SELECTION_SELECTED
want:
$expected24c"
echo "PASS: 24c a pinpoint row's own path selects that gate alone, not its whole family"

# 24d — pattern keys leave the reserved rows alone: a `none` path still selects
#       the ALWAYS floor and nothing else, rather than escalating.
reset_pattern_env
GATE_SELECTION_CHANGED='LICENSE'
gate_selection_resolve
[ "$GATE_SELECTION_MODE" = "diff" ] || fail "24d: a none-row path must not escalate (got $GATE_SELECTION_MODE)"
[ "$GATE_SELECTION_SELECTED" = "make test-always" ] || fail "24d: a recognised no-gate path must select the ALWAYS floor alone:
$GATE_SELECTION_SELECTED"
echo "PASS: 24d pattern keys leave the none/ALWAYS rows untouched"

# 24e — THE UNION PROPERTY, STATED DIRECTLY. For a gate named by BOTH a
#       pinpoint row and a family pattern row, either row selecting is enough.
#       This is the invariant 24a and 24c each pin one half of; asserting it
#       on its own makes a future re-ranking of the two rows fail HERE, with
#       the property named, rather than as a surprising diff in 24a's list.
for _u in src/thing.sh fixtures/special.json; do
  reset_pattern_env
  GATE_SELECTION_CHANGED="$_u"
  gate_selection_resolve
  case "$GATE_SELECTION_SELECTED" in
    *"tests/test_special.sh"*) : ;;
    *) fail "24e: '$_u' selects a row that names test_special.sh, so test_special.sh must run (union, not precedence):
$GATE_SELECTION_SELECTED" ;;
  esac
done
echo "PASS: 24e a gate named by both a pinpoint row and a family row runs when EITHER is selected"

# 24f — THE LIVE REGRESSION (temperloop#2162 round 2). Not a fixture: the real
#       gate-paths.tsv and the real gate list, driven by the one-file diff that
#       exposed the narrowing. Under exact-wins, `workflows/scripts/build/pr.sh`
#       stopped selecting the four state-graph suites and
#       test_dual_build_preflight.sh — five suites the `make test-build`
#       umbrella had always run, skipped on CI too, since `checks` is itself
#       diff-scoped. A green run that tested less is the exact silent-green
#       shape this selector's defenses exist to prevent, so it is pinned with
#       the production map rather than a model of it.
QG24F="$REPO_ROOT/scripts/quality-gates.sh"
if [ ! -x "$QG24F" ]; then
  echo "SKIP: 24f — no executable $QG24F to drive the live map against"
else
  # No subshell: fail() exits, and an exit inside `( )` would leave the suite
  # printing OK on a red case.
  out24f="$(GATE_SELECTION_CHANGED=workflows/scripts/build/pr.sh \
    QUALITY_GATES_SCOPE=diff "$QG24F" --list-selected 2>&1)" \
    || fail "24f: quality-gates.sh --list-selected failed:
$out24f"
  for want24f in test_state_graph.sh test_state_graph_local.sh \
                 test_state_graph_queries.sh test_state_graph_soak.sh \
                 test_dual_build_preflight.sh; do
    case "$out24f" in
      *"not run (out of scope): bash workflows/scripts/build/bounded-suite.sh --label $want24f "*)
        fail "24f: a workflows/scripts/build/pr.sh diff must still select $want24f — its own pinpoint row must not cancel the family row that globs it (the round-1 narrowing)" ;;
    esac
    case "$out24f" in
      *"--label $want24f "*) : ;;
      *) fail "24f: $want24f is absent from --list-selected output entirely — the gate list or its label changed:
$out24f" ;;
    esac
  done
  echo "PASS: 24f the live map still selects all five pinpoint-rowed suites on a build/pr.sh diff"
fi

echo "OK — gate-selection.sh: all cases passed"
