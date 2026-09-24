#!/usr/bin/env bash
#
# Regression test for temperloop#1776: a CAPABILITY PROBE must return FALSE for
# an absent function in EVERY shell these libs are sourced into — not just bash.
#
# THE DEFECT. `declare -F <name>` is bash's "is this a defined function?". zsh
# implements `declare` as `typeset`, whose `-F` means "float with N digits", so
# under zsh the probe DECLARES A FLOAT and exits 0 for a name that does not
# exist. board.sh's cache arm was guarded that way, and because every command
# spec mandates `source "$BOARD_LIB"` inside the agent's Bash tool (zsh on
# macOS), the FIRST board call of a `/triage` run died
# `_board_issues_item_list: command not found: cache_read` — twice, on
# 2026-08-23 and again on 2026-09-24. The documented fallback written directly
# beneath the guard was structurally unreachable.
#
# WHAT THIS PINS, in three lenses:
#   1. the IDIOM, measured in both shells — `command -v` is false-for-absent in
#      bash AND zsh, while `declare -F` is true-for-absent in zsh (the bug,
#      asserted so it cannot silently stop being the reason).
#   2. the BEHAVIOR — `board_resolve 7` with ONLY board.sh sourced and
#      `board.7.cache=on` takes the documented uncached fallback under both
#      shells, printing the notice instead of dying.
#   3. the NEGATIVE CONTROL — the same call against a copy of board.sh with the
#      old `declare -F` probe restored DOES die under zsh. Without this lens,
#      lens 2 could pass for a reason unrelated to the fix.
#
# Lenses 1 (zsh half) and 3 need a real zsh; where none is installed the test
# says so on the line rather than reporting a silent pass, and the bash halves
# still run. CI runners for this repo carry zsh.
set -uo pipefail

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/board.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/capability-probe-dialect.XXXXXX")"
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

HAVE_ZSH=0
command -v zsh >/dev/null 2>&1 && HAVE_ZSH=1

SHELLS=(bash)
[ "$HAVE_ZSH" -eq 1 ] && SHELLS+=(zsh)

# ── Lens 1: the probe idiom itself, measured per shell ──────────────────────
# `_no_such_fn_1776` is never defined anywhere; `_yes_fn_1776` is defined inline.
for sh in "${SHELLS[@]}"; do
  out="$("$sh" -c '
    _yes_fn_1776() { :; }
    if command -v _no_such_fn_1776 >/dev/null 2>&1; then echo "absent:cv=TRUE"; else echo "absent:cv=FALSE"; fi
    if command -v _yes_fn_1776     >/dev/null 2>&1; then echo "present:cv=TRUE"; else echo "present:cv=FALSE"; fi
    if declare -F _no_such_fn_1776 >/dev/null 2>&1; then echo "absent:df=TRUE"; else echo "absent:df=FALSE"; fi  # shell-dialect-probe:exempt — measures the defect, does not rely on it
  ' 2>/dev/null)"

  case "$out" in
    *"absent:cv=FALSE"*) ;;
    *) fail "lens 1 ($sh): \`command -v\` on an ABSENT function was TRUE — a capability guard built on it cannot fail:
$out" ;;
  esac
  case "$out" in
    *"present:cv=TRUE"*) ;;
    *) fail "lens 1 ($sh): \`command -v\` on a DEFINED function was FALSE — the replacement idiom does not detect real functions:
$out" ;;
  esac
done
echo "PASS: lens 1a — \`command -v\` is false-for-absent and true-for-present in: ${SHELLS[*]}"

# The bug itself, asserted so the WHY stays measured rather than remembered.
if [ "$HAVE_ZSH" -eq 1 ]; then
  zsh_df="$(zsh -c 'if declare -F _no_such_fn_1776 >/dev/null 2>&1; then echo TRUE; else echo FALSE; fi' 2>/dev/null)"  # shell-dialect-probe:exempt — measures the defect, does not rely on it
  [ "$zsh_df" = "TRUE" ] \
    || fail "lens 1b: expected \`declare -F <absent>\` to be TRUE under zsh (the temperloop#1776 defect). Got '$zsh_df' — if zsh changed, this test's premise needs revisiting, but the \`command -v\` fix stays correct either way."
  bash_df="$(bash -c 'if declare -F _no_such_fn_1776 >/dev/null 2>&1; then echo TRUE; else echo FALSE; fi' 2>/dev/null)"  # shell-dialect-probe:exempt — measures the defect, does not rely on it
  [ "$bash_df" = "FALSE" ] \
    || fail "lens 1b: expected \`declare -F <absent>\` to be FALSE under bash. Got '$bash_df'."
  echo "PASS: lens 1b — the defect is real and measured: \`declare -F <absent>\` is TRUE under zsh, FALSE under bash"
else
  echo "NOTE: lens 1b + lens 3 not measured — zsh is not installed on this host (lens 1a ran bash-only)"
fi

# ── Fixture: an offline board 7 with the cache axis ON ──────────────────────
# The axis is what puts the read on the guarded arm. No cache.sh is sourced, so
# the guard MUST be false and the read MUST fall back to the live arm — which
# the stub `gh` below serves offline.
CONF="$WORK/boards.conf"
cat > "$CONF" <<'CONF_EOF'
board.7.repo=Towheads/temperloop
board.7.cache=on
CONF_EOF

mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'GH_EOF'
#!/usr/bin/env bash
# offline stub: the live arm's only call is `gh issue list … --json …`
case "$*" in
  *"issue list"*) printf '%s\n' '[{"number":1,"title":"stub","labels":[],"milestone":null}]' ;;
  *) printf '%s\n' '[]' ;;
esac
GH_EOF
chmod +x "$WORK/bin/gh"

NOTICE='falling back to a live (uncached) read'

# _resolve_under <shell> <lib-path> — run `board_resolve 7` with ONLY that lib
# sourced; echo "rc=<n>" then the merged output.
_resolve_under() {
  local sh="$1" lib="$2" out rc
  out="$(PATH="$WORK/bin:$PATH" BOARDS_CONF_MACHINE="$CONF" \
        "$sh" -c "source '$lib'; board_resolve 7 >/dev/null" 2>&1)"
  rc=$?
  printf 'rc=%s\n%s\n' "$rc" "$out"
}

# ── Lens 2: the fixed adapter falls back cleanly in every shell ─────────────
for sh in "${SHELLS[@]}"; do
  res="$(_resolve_under "$sh" "$LIB")"
  case "$res" in
    *"command not found"*)
      fail "lens 2 ($sh): board_resolve 7 died on the guarded cache arm — the capability probe is still dialect-dependent:
$res" ;;
  esac
  case "$res" in
    rc=0*) ;;
    *) fail "lens 2 ($sh): board_resolve 7 exited non-zero with only board.sh sourced:
$res" ;;
  esac
  case "$res" in
    *"$NOTICE"*) ;;
    *) fail "lens 2 ($sh): the documented uncached-fallback notice is missing — the fallback branch is still unreachable:
$res" ;;
  esac
done
echo "PASS: lens 2 — board_resolve 7 (cache=on, cache.sh NOT sourced) takes the documented uncached fallback in: ${SHELLS[*]}"

# ── Lens 3: negative control — the OLD idiom still breaks under zsh ─────────
if [ "$HAVE_ZSH" -eq 1 ]; then
  OLD_LIB="$WORK/board-old-idiom.sh"
  # Restore the pre-fix probe in a THROWAWAY copy. Anchored on the replacement
  # line so this control fails loudly if the probe is ever moved or respelled,
  # rather than silently controlling nothing.
  sed 's/if command -v cache_read >\/dev\/null 2>&1; then/if declare -F cache_read >\/dev\/null 2>\&1; then/' "$LIB" > "$OLD_LIB"  # shell-dialect-probe:exempt — synthesizes the pre-fix probe into a throwaway fixture copy
  if ! grep -F 'declare -F cache_read' "$OLD_LIB" >/dev/null; then  # shell-dialect-probe:exempt — anchors the synthesized fixture
    fail "lens 3: could not synthesize the pre-fix probe — board.sh's cache guard no longer matches the anchored replacement line, so this negative control proves nothing. Update the sed anchor above."
  fi

  res="$(_resolve_under zsh "$OLD_LIB")"
  case "$res" in
    *"command not found"*)
      echo "PASS: lens 3 — negative control: the pre-fix \`declare -F\` probe DOES still die under zsh, so lens 2 is passing because of the fix" ;;
    *)
      fail "lens 3: the pre-fix \`declare -F\` probe did NOT fail under zsh. Lens 2 therefore proves nothing about the fix:
$res" ;;
  esac
fi

echo "PASS: temperloop#1776 — capability probes are shell-dialect-safe"
