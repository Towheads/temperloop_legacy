#!/usr/bin/env bash
#
# Tests for `temperloop doctor` (bin/subcommands/doctor.sh, temperloop#1047).
#
# Covers:
#   1. `temperloop doctor` produces output BYTE-IDENTICAL to invoking
#      workflows/scripts/install/doctor.sh directly, and the SAME exit code —
#      the subcommand delegates, it does not reimplement, filter or re-print.
#   2. A positional <toolkit-root> passes straight through: pointed at a
#      throwaway fixture, both invocations agree there too (so the pass-through
#      is proven on a root that is NOT the default).
#   3. The subcommand is DISCOVERED — it appears in `temperloop help` with its
#      `# description:` text, with no dispatcher edit.
#   4. bin/README.md no longer states that no such subcommand exists. This is
#      the documented-statement supersession the contract calls for: the file
#      used to say so outright, and a release that ships the subcommand while
#      its own docs deny it is the failure this asserts against.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
CLI="${REPO_ROOT}/bin/temperloop"
SUB="${REPO_ROOT}/bin/subcommands/doctor.sh"
DOCTOR_SH="${REPO_ROOT}/workflows/scripts/install/doctor.sh"
README="${REPO_ROOT}/bin/README.md"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-doctor-subcommand-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "PASS: $1"; }

[ -f "$CLI" ] || fail "0: CLI not found at $CLI"
[ -f "$SUB" ] || fail "0: subcommand not found at $SUB"
[ -f "$DOCTOR_SH" ] || fail "0: health check not found at $DOCTOR_SH"

# ---------------------------------------------------------------------------
# 1 — identical output and exit code on the default root
#
# A warm-up run first: doctor's reviewer-coverage check owns a documented
# one-time INFO whose marker write makes run 1 differ from run 2 on a checkout
# that has never run it. Settling that first is what makes this an
# apples-to-apples comparison rather than a flake.
# ---------------------------------------------------------------------------
set +e
bash "$DOCTOR_SH" >/dev/null 2>&1
out_sub="$(bash "$CLI" doctor 2>&1)"; rc_sub=$?
out_direct="$(bash "$DOCTOR_SH" 2>&1)"; rc_direct=$?
set -e

[ "$rc_sub" = "$rc_direct" ] \
  || fail "1: exit codes differ — 'temperloop doctor'=$rc_sub, direct=$rc_direct"
if [ "$out_sub" != "$out_direct" ]; then
  diff <(printf '%s\n' "$out_direct") <(printf '%s\n' "$out_sub") >"$TMP/diff.txt" 2>&1 || true
  fail "1: output differs between 'temperloop doctor' and the direct script path:
$(cat "$TMP/diff.txt")"
fi
pass "1: 'temperloop doctor' output and exit code are identical to the direct script path"

# ---------------------------------------------------------------------------
# 2 — positional <toolkit-root> passes through
# ---------------------------------------------------------------------------
FIX="$TMP/fixture-root"
mkdir -p "$FIX"
set +e
out_sub2="$(bash "$CLI" doctor "$FIX" 2>&1)"; rc_sub2=$?
out_direct2="$(bash "$DOCTOR_SH" "$FIX" 2>&1)"; rc_direct2=$?
set -e
[ "$rc_sub2" = "$rc_direct2" ] \
  || fail "2: exit codes differ on a passed-through root — $rc_sub2 vs $rc_direct2"
[ "$out_sub2" = "$out_direct2" ] \
  || fail "2: output differs on a passed-through root"
grep -q "$FIX" <<<"$out_sub2" \
  || fail "2: the passed-through root was not honoured — got: $out_sub2"
pass "2: a positional <toolkit-root> passes straight through to the health check"

# ---------------------------------------------------------------------------
# 3 — discovered, not dispatch-table'd
# ---------------------------------------------------------------------------
help_out="$(bash "$CLI" help 2>&1)"
grep -q '^  doctor  ' <<<"$help_out" \
  || fail "3: 'doctor' is not listed in 'temperloop help' — got: $help_out"
grep -q 'toolkit provenance' <<<"$help_out" \
  || fail "3: the subcommand's own '# description:' text is not what help printed — got: $help_out"
grep -q 'doctor' "$CLI" \
  && fail "3: the dispatcher names 'doctor' — discovery, not a dispatch table, must do the registering"
pass "3: 'temperloop doctor' is discovered from its file, with no dispatcher edit"

# ---------------------------------------------------------------------------
# 4 — the superseded documented statement is gone
# ---------------------------------------------------------------------------
[ -f "$README" ] || fail "4: $README not found"
grep -q 'no .temperloop doctor. subcommand' "$README" \
  && fail "4: bin/README.md still states that no 'temperloop doctor' subcommand exists"
grep -q 'temperloop doctor' "$README" \
  || fail "4: bin/README.md does not mention the new 'temperloop doctor' subcommand at all"
pass "4: bin/README.md no longer denies the subcommand and documents it instead"

echo
echo "All temperloop-doctor subcommand tests passed."
