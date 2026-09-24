#!/usr/bin/env bash
# Regression tests for scripts/lint-shell-dialect-probe.sh (temperloop#1776).
#
# The class this backstops: `declare -F <name>` / `type -t <name>` are BASH-ONLY
# capability probes. Under zsh `declare` is `typeset` and `-F` means "float with
# N digits", so `declare -F some_absent_fn` exits 0 — the guard is
# unconditionally TRUE and the fallback beneath it is unreachable. board.sh's
# cache arm shipped that way and killed the first board call of a `/triage` run
# twice (2026-08-23, 2026-09-24), because every command spec mandates sourcing
# the lib into the agent's shell and on macOS that shell is zsh.
#
# WHY THESE TESTS EXIST AT ALL. A lint ASSERTED to cover a class without ever
# being shown to fire on it is not coverage (the reasoning its three siblings'
# suites already state). T1 is therefore load-bearing: it feeds the lint the
# VERBATIM pre-fix lines from board.sh and scripts/quality-gates.sh and requires
# a non-zero exit. The rest fence in the false positives a wider rule produces —
# in particular the prose that NAMES the idiom, which several repaired files now
# carry in a header and which a naive rule would flag (the temperloop#1152
# guard-fires-on-its-own-documentation class).
#
# T-DEGENERATE pins the epic temperloop#1409 contract: an input the lint could
# not evaluate (absent file, unreadable file, empty resolved set) exits non-zero,
# never a silent 0. Those three cases are what this surface's rows in
# workflows/scripts/config/check-surface-registry.tsv point at.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LINT="$ROOT/scripts/lint-shell-dialect-probe.sh"
PASS=0
FAIL=0

pass() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/lint-shell-dialect-probe.XXXXXX")"
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

FIXN=0
FIX_NAME=(); FIX_EXPECT=(); FIX_PATH=()
# fixture <name> <expect: fail|ok> <content> [extension]
fixture() {
  FIXN=$((FIXN + 1))
  FIX_NAME[FIXN]="$1"; FIX_EXPECT[FIXN]="$2"
  FIX_PATH[FIXN]="$WORK/$1.${4:-sh}"
  printf '%s\n' "$3" >"${FIX_PATH[FIXN]}"
}

# ── T1: the REAL pre-fix inputs, verbatim from the two files this item fixed.
#    A lint that does not fire on THESE is not a guard for this class. ───────
fixture real_prefix_board_sh fail '#!/usr/bin/env bash
  if _board_cache_store_enabled "$board"; then
    if declare -F cache_read >/dev/null 2>&1; then
      raw="$(cache_read "$repo")" || return 1
    fi
  fi'
fixture real_prefix_quality_gates fail 'if ! type -t gate_pool_resolve_jobs >/dev/null 2>&1; then
  echo "missing" >&2
fi'

# ── Must FIRE: the shapes the tree actually used ───────────────────────────
fixture df_bare_command      fail 'declare -F cache_dirty >/dev/null 2>&1 && cache_dirty "$1"'
fixture df_negated           fail 'if ! declare -F ks_write >/dev/null 2>&1; then exit 1; fi'
fixture df_expansion_operand fail 'if ! declare -F "$fn" >/dev/null 2>&1; then return 1; fi'
fixture df_or_exit           fail 'declare -F ks__read_log_emit >/dev/null 2>&1 || exit 0'
fixture typeset_F_operand    fail 'typeset -F board_repo >/dev/null 2>&1 || return 1'
fixture type_t_operand       fail 'if [ "$(type -t foo)" = function ]; then :; fi'

# ── Must NOT fire: the sanctioned replacements ─────────────────────────────
fixture cv_replacement   ok 'if command -v cache_read >/dev/null 2>&1; then raw="$(cache_read "$repo")"; fi'
fixture typeset_f_lower  ok 'typeset -f cache_read >/dev/null 2>&1 || return 1'
fixture declare_f_lower  ok 'declare -f cache_read >/dev/null 2>&1 || return 1'

# ── Must NOT fire: the bare LISTING form. `declare -F` with no operand is not
#    a capability probe and is not dialect-dependent in this way; a live site
#    (workflows/scripts/tests/test_terminology_rename_compat.sh) uses it inside
#    an explicit `bash -c`. ─────────────────────────────────────────────────
fixture df_listing_no_operand ok 'n="$(bash -c "source $CFG >/dev/null 2>&1; declare -F | grep -c rename_compat" || true)"'

# ── Must NOT fire: prose naming the idiom. Several repaired files now carry a
#    header explaining exactly why `declare -F` was wrong; a guard that fires on
#    its own documentation is the temperloop#1152 defect class. ─────────────
fixture comment_naming_idiom ok '# `command -v`, NOT `declare -F`: under zsh `declare` is `typeset` and its
# `-F` flag means "float with N digits", so `declare -F run_with_timeout` is
# unconditionally true. Use the POSIX form instead.
command -v run_with_timeout >/dev/null 2>&1 || run_with_timeout() { shift; "$@"; }'
fixture trailing_comment_naming_idiom ok 'command -v cache_read >/dev/null 2>&1  # was declare -F cache_read before temperloop#1776'

# ── Must NOT fire: the explicit pragma, for a line that must carry the shape
#    as data (the fixture-synthesising sed in the board dual-shell suite). ──
fixture pragma_exempt ok 'sed "s/command -v cache_read/declare -F cache_read/" "$LIB" > "$OLD"  # shell-dialect-probe:exempt — synthesizes the pre-fix probe'

# ── Must NOT fire: an identifier that merely CONTAINS the word ─────────────
fixture identifier_lookalike ok 'my_declare -F foo >/dev/null 2>&1 || true
retype -t bar >/dev/null 2>&1 || true'

# ── Command specs are scanned RAW (their fenced snippets are pasted into the
#    agent's zsh Bash tool), so the same rule applies inside a .md. ─────────
fixture spec_md_probe fail '## Step 4.8

   Land the Done write:

   ```sh
   if declare -F board_close_done >/dev/null 2>&1; then
     board_close_done "$BOARD" "$N"
   fi
   ```' md
fixture spec_md_fixed ok '## Step 4.8

   ```sh
   if command -v board_close_done >/dev/null 2>&1; then
     board_close_done "$BOARD" "$N"
   fi
   ```' md

echo "── lint-shell-dialect-probe: fixture verdicts ──"
i=1
while [ "$i" -le "$FIXN" ]; do
  name="${FIX_NAME[$i]}"; expect="${FIX_EXPECT[$i]}"; path="${FIX_PATH[$i]}"
  bash "$LINT" "$path" >/dev/null 2>&1
  rc=$?
  if [ "$expect" = "fail" ]; then
    if [ "$rc" -eq 1 ]; then pass "$name — FIRES (rc=1), as required"
    else fail "$name — lint exited $rc on a known-bad dialect-dependent probe (want 1)"; fi
  else
    if [ "$rc" -eq 0 ]; then pass "$name — silent, as required"
    else fail "$name — FALSE POSITIVE: lint exited $rc on legal code"; fi
  fi
  i=$((i + 1))
done

echo
echo "── the lint names the offending file, line and the fix ──"
REPORT="$(bash "$LINT" "${FIX_PATH[1]}" 2>&1 1>/dev/null || true)"
case "$REPORT" in
  *real_prefix_board_sh.sh:*) pass "the report cites the offending file:line" ;;
  *) fail "the report does not cite file:line — got: $REPORT" ;;
esac
case "$REPORT" in
  *'command -v'*) pass "the report names the sanctioned replacement idiom" ;;
  *) fail "the report does not name the replacement idiom" ;;
esac
case "$REPORT" in
  *1776*) pass "the report cites the governing issue" ;;
  *) fail "the report does not cite temperloop#1776" ;;
esac

echo
echo "── T-DEGENERATE: an un-evaluatable input is non-zero, never a silent 0 ──"
bash "$LINT" "$WORK/definitely-absent.sh" >/dev/null 2>&1
[ "$?" -eq 2 ] && pass "absent file: exit 2 (CANNOT EVALUATE), not 0" \
               || fail "absent file did not exit 2"
UNREADABLE="$WORK/unreadable.sh"
: >"$UNREADABLE"
chmod 000 "$UNREADABLE"
if [ -r "$UNREADABLE" ]; then
  # running as root, or a filesystem that ignores the mode — the case is not
  # measurable here, and saying so beats recording a pass that proved nothing.
  echo "  – unreadable file: not measurable on this host (mode 000 still readable)"
else
  bash "$LINT" "$UNREADABLE" >/dev/null 2>&1
  [ "$?" -eq 2 ] && pass "unreadable file: exit 2 (CANNOT EVALUATE), not 0" \
                 || fail "unreadable file did not exit 2"
fi
chmod 644 "$UNREADABLE"
# Empty resolved set: the lint's own path is self-exempt, so passing only that
# leaves nothing to scan — the vacuous pass epic temperloop#1409 exists to close.
bash "$LINT" "$LINT" >/dev/null 2>&1
[ "$?" -eq 2 ] && pass "empty resolved file set: exit 2 (CANNOT EVALUATE), not 0" \
               || fail "empty resolved file set did not exit 2"

echo
echo "── the tracked set is clean, and --list resolves it ──"
if [ "$(bash "$LINT" --list 2>/dev/null | wc -l | tr -d ' ')" -gt 10 ]; then
  pass "--list resolves the tracked shell + command-spec set"
else
  fail "--list resolved an implausibly small file set"
fi
# `grep … >/dev/null`, never `grep -q`: under `set -o pipefail` a `-q` that
# exits on the first match SIGPIPEs the producer and the pipeline reports 141
# (scripts/lint-pipe-grep-q.sh guards exactly this).
if bash "$LINT" --list 2>/dev/null | grep '^claude/commands/' >/dev/null; then
  pass "--list includes claude/commands/*.md (the agent-executed spec surface)"
else
  fail "--list does not include the command specs"
fi
# The lint must never flag ITSELF or this file, both of which carry the shape as
# data — self-exemption is by resolved path, so a vendored copy is covered too.
if bash "$LINT" >/dev/null 2>&1; then
  pass "the whole tracked set is clean (self-exemption holds)"
else
  fail "the lint is not clean over the tracked set"
fi

echo
echo "── T-GROUND: re-measure the lint's PREMISE in a real zsh, if present ──"
if ! command -v zsh >/dev/null 2>&1; then
  echo "  – skipped — no zsh on this host; the recorded fixture expectations above"
  echo "    still gate, and workflows/scripts/board/tests/test_capability_probe_shell_dialect.sh"
  echo "    carries the behavioral half."
else
  zsh_df="$(zsh -c 'if declare -F _no_such_fn_1776 >/dev/null 2>&1; then echo TRUE; else echo FALSE; fi' 2>/dev/null)"
  bash_df="$(bash -c 'if declare -F _no_such_fn_1776 >/dev/null 2>&1; then echo TRUE; else echo FALSE; fi' 2>/dev/null)"
  [ "$zsh_df" = "TRUE" ] && pass "premise: \`declare -F <absent>\` is TRUE under zsh (the defect)" \
                         || fail "premise broken: \`declare -F <absent>\` is $zsh_df under zsh"
  [ "$bash_df" = "FALSE" ] && pass "premise: \`declare -F <absent>\` is FALSE under bash" \
                           || fail "premise broken: \`declare -F <absent>\` is $bash_df under bash"
fi

echo
echo "── summary: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ] || exit 1
