#!/usr/bin/env bash
#
# lint-shell-dialect-probe.sh — mechanical guard against the temperloop#1776
# footgun: a CAPABILITY PROBE that is unconditionally TRUE under zsh.
#
# THE BUG. `declare -F <name>` is a bash idiom meaning "is <name> a defined
# function?". zsh implements `declare` as `typeset`, whose `-F` flag means
# "floating-point with N digits" — so under zsh the probe DECLARES A FLOAT and
# exits 0 for a name that does not exist:
#
#   $ zsh  -c 'declare -F definitely_not_a_function >/dev/null 2>&1; echo $?'  -> 0
#   $ bash -c 'declare -F definitely_not_a_function >/dev/null 2>&1; echo $?'  -> 1
#
# `type -t <name>` (and `typeset -F <name>`, the same builtin spelled out) is
# bash-only in the same way. The failure mode is not "falls back" — it is
# "calls a function that does not exist", with the fallback branch written
# directly beneath the guard rendered structurally unreachable.
#
# WHY IT BITES HERE AND NOT IN CI. A `#!/usr/bin/env bash` shebang protects a
# script that is EXECUTED. It does nothing for a lib that is SOURCED, and this
# repo's command specs (`claude/commands/{triage,build,fix,sweep}.md`) mandate
# exactly that — "`source "$BOARD_LIB"` at the top of every board bash block".
# On macOS the agent's Bash tool runs zsh (ZSH_VERSION=5.9 observed), so every
# such guard is INVERTED on the primary agent-facing path. Measured live twice:
# `board.sh` died `_board_issues_item_list: command not found: cache_read` at
# Step 0 of a `/triage` run on 2026-08-23 and again on 2026-09-24.
#
# THE REPLACEMENT. `command -v <name> >/dev/null 2>&1` — POSIX, correct in bash
# and zsh alike, and false for an absent name in both. It is deliberately WIDER
# than "is a function" (it is also true for a builtin or a binary on PATH), and
# that width is fine for every probe in this tree because the probed names are
# namespaced library symbols (`cache_read`, `ks_write`, `board_close_done`) with
# no binary of the same name. `typeset -f <name>` is the strictly-is-a-function
# form that IS portable (verified on bash 3.2/5.x and zsh 5.9) and is not
# flagged — reach for it only when the wider sense genuinely matters.
#
# WHAT IS FLAGGED — and only this: `declare -F`, `typeset -F` or `type -t`
# FOLLOWED BY AN OPERAND (a name, a quote, or a `$`-expansion). The operand is
# required because the bare listing forms (`declare -F | grep …`) are not
# capability probes and are not dialect-dependent in the same way.
#
# WHAT IS NOT FLAGGED, and why:
#   * `declare -f` / `typeset -f` (lowercase) — portable, see above.
#   * a `#` COMMENT in a shell file that merely NAMES the idiom. Several fixed
#     sites now carry a header explaining exactly why `declare -F` was wrong,
#     and a guard that fires on the documentation of the thing it guards is the
#     temperloop#1152 defect class. The comment strip is quote-aware (shared
#     with lint-bash32-ctlesc-ifs.sh / lint-pipe-grep-q.sh).
#   * a line carrying the `shell-dialect-probe:exempt` pragma plus a reason.
#   * this script and its own regression test, which hold the shape as data.
#
# FILE SET — the tracked shell files, PLUS `claude/commands/*.md`. The specs are
# in scope deliberately: their fenced snippets are pasted verbatim into the
# agent's (zsh) Bash tool, so a spec is an EXECUTION surface for this bug, not
# just prose about it. Markdown lines are scanned raw (no `#` strip — `#` is a
# heading there); a spec that must discuss the idiom uses the pragma.
#
# WHY A LINT AND NOT A TEST. `shellcheck` exits 0 on `declare -F foo` (it is
# valid bash). `bash -n` exits 0. A runtime test under bash passes, because the
# code IS correct there — and pre-merge CI is ubuntu-only (temperloop#963) and
# runs bash. Only a textual detector fires on the leg that actually ships.
# Same family and the same file-set machinery as its three siblings:
# scripts/lint-zsh-param-tie.sh, scripts/lint-bash32-ctlesc-ifs.sh and
# scripts/lint-pipe-grep-q.sh.
#
# USAGE
#   scripts/lint-shell-dialect-probe.sh                # lint the tracked set
#   scripts/lint-shell-dialect-probe.sh FILE [FILE...] # lint explicit files
#   scripts/lint-shell-dialect-probe.sh --list         # print the resolved set
#
# EXIT CODES — a degenerate input is CANNOT EVALUATE, never a silent pass
# (epic temperloop#1409):
#   0  clean
#   1  at least one dialect-dependent capability probe found
#   2  CANNOT EVALUATE — a named file is absent or unreadable, or the resolved
#      file set is empty. A lint with nothing to lint has proven nothing, so it
#      must not exit 0.
# Runs fully offline and shells out to nothing but `awk` and `git ls-files`.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# _resolve_symlinks <path> — canonicalize a path by following every symlink,
# both a symlinked LEAF file and any symlinked directory COMPONENT, without
# relying on GNU `readlink -f` or `realpath` (neither is guaranteed on the
# macOS/BSD userland this repo also runs on). Same helper, and same reason, as
# lint-bash32-ctlesc-ifs.sh: the self-exemption below must recognize this file
# through a vendoring overlay's compat symlink as well as its vendored original.
_resolve_symlinks() {
  local p="$1" dir target hops=0
  while [ -L "$p" ]; do
    hops=$((hops + 1))
    [ "$hops" -gt 40 ] && break # symlink-loop guard; give up and use what we have
    dir="$(dirname "$p")"
    target="$(readlink "$p")"
    case "$target" in
      /*) p="$target" ;;
      *) p="$dir/$target" ;;
    esac
  done
  dir="$(dirname "$p")"
  if dir="$(cd "$dir" 2>/dev/null && pwd -P)"; then
    printf '%s/%s\n' "$dir" "$(basename "$p")"
  else
    printf '%s\n' "$p"
  fi
}

SELF="$REPO_ROOT/scripts/lint-shell-dialect-probe.sh"
SELF_TEST="$REPO_ROOT/scripts/tests/test_lint_shell_dialect_probe.sh"
SELF_RESOLVED="$(_resolve_symlinks "$SELF")"
SELF_TEST_RESOLVED="$(_resolve_symlinks "$SELF_TEST")"

LIST_ONLY=0
if [ "${1:-}" = "--list" ]; then
  LIST_ONLY=1
  shift
fi

# ---------------------------------------------------------------------------
# File set. Explicit arguments win (the mode the regression test uses) and are
# validated: an absent or unreadable named file is CANNOT EVALUATE (exit 2),
# because silently skipping it is precisely the "a check that could not run
# reports success" defect (epic temperloop#1409).
# ---------------------------------------------------------------------------
files=()
if [ "$#" -gt 0 ]; then
  bad=0
  for f in "$@"; do
    if [ ! -e "$f" ]; then
      echo "lint-shell-dialect-probe: CANNOT EVALUATE — no such file: $f" >&2
      bad=1
      continue
    fi
    if [ ! -r "$f" ]; then
      echo "lint-shell-dialect-probe: CANNOT EVALUATE — unreadable file: $f" >&2
      bad=1
      continue
    fi
    files+=("$f")
  done
  [ "$bad" -eq 0 ] || exit 2
else
  while IFS= read -r f; do
    [ -f "$REPO_ROOT/$f" ] || continue
    case "$f" in
      claude/commands/*.md) files+=("$REPO_ROOT/$f") ;;
      *.md) ;;
      *.sh) files+=("$REPO_ROOT/$f") ;;
      *)
        if head -n 1 "$REPO_ROOT/$f" 2>/dev/null \
          | grep -E '^#!.*[ /](ba)?sh( |$)' >/dev/null; then
          files+=("$REPO_ROOT/$f")
        fi
        ;;
    esac
  done < <(git -C "$REPO_ROOT" ls-files 2>/dev/null)
fi

# Drop the two self-exempt files (by resolved path — see _resolve_symlinks).
kept=()
if [ "${#files[@]}" -gt 0 ]; then
  for f in "${files[@]}"; do
    abs="$f"
    case "$abs" in /*) ;; *) abs="$PWD/$abs" ;; esac
    resolved="$(_resolve_symlinks "$abs")"
    [ "$resolved" = "$SELF_RESOLVED" ] && continue
    [ "$resolved" = "$SELF_TEST_RESOLVED" ] && continue
    kept+=("$f")
  done
fi

# An empty resolved set is the VACUOUS PASS this class exists to close.
if [ "${#kept[@]}" -eq 0 ]; then
  echo "lint-shell-dialect-probe: CANNOT EVALUATE — resolved file set is empty (nothing was linted)" >&2
  exit 2
fi
files=("${kept[@]}")

if [ "$LIST_ONLY" -eq 1 ]; then
  for f in "${files[@]}"; do
    printf '%s\n' "${f#"$REPO_ROOT"/}"
  done
  exit 0
fi

# ---------------------------------------------------------------------------
# The scanner. For a shell file, strip any `#` comment that is genuinely a
# comment (a `#` at a word boundary, outside single/double quotes) and match
# against what is left. For a `claude/commands/*.md` spec, scan the raw line —
# `#` there is a heading, and the fenced snippets ARE the execution surface.
# Either way a `shell-dialect-probe:exempt` pragma on the RAW line opts out.
#
# The match requires `-F`/`-t` to be followed by an OPERAND, so the bare
# listing form `declare -F | grep …` (not a capability probe, and not
# dialect-dependent in this way) does not match. The leading
# `[^[:alnum:]_-]` keeps it off an identifier that merely ends in the word.
# ---------------------------------------------------------------------------
report="$(
  awk '
    # Return the line with any trailing `#` comment removed.
    function strip_comment(s,   n, i, c, sq, dq, prev) {
      n = length(s); i = 1; sq = 0; dq = 0
      while (i <= n) {
        c = substr(s, i, 1)
        if (sq) { if (c == "\047") sq = 0; i++; continue }
        if (c == "\\") { i += 2; continue }
        if (dq) { if (c == "\"") dq = 0; i++; continue }
        if (c == "\047") { sq = 1; i++; continue }
        if (c == "\"")   { dq = 1; i++; continue }
        if (c == "#") {
          # `#` opens a comment only at a word boundary — this is what keeps
          # `${#arr}`, `$#` and `a#b` from truncating the line.
          prev = (i == 1) ? "" : substr(s, i - 1, 1)
          if (i == 1 || prev == " " || prev == "\t" || prev == ";" ||
              prev == "|" || prev == "&" || prev == "(" || prev == ")" ||
              prev == "<" || prev == ">") {
            return substr(s, 1, i - 1)
          }
        }
        i++
      }
      return s
    }

    FNR == 1 { is_md = (FILENAME ~ /\.md$/) }

    {
      if (index($0, "shell-dialect-probe:exempt") > 0) next
      code = is_md ? $0 : strip_comment($0)
      if (code ~ /(^|[^[:alnum:]_-])(declare|typeset)[[:space:]]+-F[[:space:]]+["\047$[:alnum:]_]/) {
        printf "%s:%d: `declare -F <name>` is a BASH-ONLY function probe — under zsh it declares a float and always succeeds\n", FILENAME, FNR
        printf "%s:%d:     %s\n", FILENAME, FNR, $0
      } else if (code ~ /(^|[^[:alnum:]_-])type[[:space:]]+-t[[:space:]]+["\047$[:alnum:]_]/) {
        printf "%s:%d: `type -t <name>` is a BASH-ONLY capability probe — it is not available in every shell these files are sourced into\n", FILENAME, FNR
        printf "%s:%d:     %s\n", FILENAME, FNR, $0
      }
    }
  ' "${files[@]}"
)"

if [ -n "$report" ]; then
  echo "lint-shell-dialect-probe: FAIL — a shell-dialect-dependent capability probe was found:" >&2
  echo "  (zsh implements \`declare\` as \`typeset\`, whose \`-F\` means \"float with N digits\" — so" >&2
  echo "   \`declare -F some_absent_fn\` exits 0 under zsh and the fallback written beneath the" >&2
  echo "   guard is unreachable. These libs are SOURCED into the agent's shell, which is zsh on" >&2
  echo "   macOS, so the shebang does not protect them. \`type -t\` is bash-only in the same way." >&2
  echo "   Fix: use the POSIX form, correct in both shells —" >&2
  echo "     declare -F some_fn >/dev/null 2>&1   ->   command -v some_fn >/dev/null 2>&1" >&2
  echo "   (need STRICTLY \"is a function\"? \`typeset -f some_fn\` is portable and is not flagged.)" >&2
  echo "   A line that must carry the idiom as data adds \`shell-dialect-probe:exempt — <why>\`." >&2
  echo "   See temperloop#1776.)" >&2
  printf '%s\n' "$report" | sed "s|^${REPO_ROOT}/||; s|^|  |" >&2
  exit 1
fi

echo "lint-shell-dialect-probe: OK — no shell-dialect-dependent capability probes in the tracked shell + command-spec set"
