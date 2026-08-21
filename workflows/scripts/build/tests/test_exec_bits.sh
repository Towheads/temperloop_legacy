#!/usr/bin/env bash
# test_exec_bits.sh — guard for #628 (sibling of #476): every directly-invoked
# build-machinery script MUST be tracked with the executable bit (100755). A script
# committed 100644 fails a bare-path `workflows/scripts/build/foo.sh` invocation
# with permission-denied (exit 126) and forces an on-disk-copy fallback each run
# — the recurring /build & /sweep friction #628 fixed for plan.sh + board-mirror.sh.
#
# Rule: every tracked *.sh under workflows/scripts/build/ (excluding tests/) that
# carries a #! shebang MUST be tracked 100755, EXCEPT files that are sourced-only
# (listed in SOURCED_ONLY below — they keep a shebang for shellcheck/editor
# detection but are `. sourced`, never executed by bare path).
#
# The allowlist enumerates the EXEMPTIONS, not the covered set: a newly-added
# invoked script is required-executable by default, so it is caught here rather
# than shipping 100644 — the exact recurrence this guard exists to prevent.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$(cd "$HERE/.." && pwd)"
REPO_ROOT="$(git -C "$BUILD_DIR" rev-parse --show-toplevel)"

# Sourced-only scripts: `. build.config.sh` never runs by path, so its exec bit
# is intentionally off. Add a new sourced-only config here (rare); direct-invoked
# scripts stay off this list and are required-executable by default.
SOURCED_ONLY=(
  "build.config.sh"
  "merged-detect.sh"   # lib/ helper, `. sourced` by worktree.sh prune + env-reconcile.sh — never run by bare path
  "pr-linkage.sh"      # lib/ helper, `. sourced` by issue-state.sh (temperloop #635) — never run by bare path
  "job-scratch.sh"     # lib/ helper, `. sourced` by env-reconcile.sh + job-scratch-reclaim.sh (temperloop#1111) — never run by bare path
)

is_sourced_only() {
  local base="$1" s
  for s in "${SOURCED_ONLY[@]}"; do [ "$base" = "$s" ] && return 0; done
  return 1
}

fail=0
checked=0
while IFS= read -r rel; do
  case "$rel" in */tests/*) continue ;; esac
  # only build-machinery scripts with a shebang carry executable intent
  head -1 "$REPO_ROOT/$rel" | grep '^#!' >/dev/null || continue
  base="$(basename "$rel")"
  is_sourced_only "$base" && continue
  checked=$((checked + 1))
  mode="$(git -C "$REPO_ROOT" ls-files -s -- "$rel" | awk '{print $1}')"
  if [ "$mode" != "100755" ]; then
    echo "  ✗ $rel tracked $mode (expected 100755 — directly-invoked script needs the exec bit; see #628)"
    fail=1
  fi
done < <(git -C "$REPO_ROOT" ls-files -- 'workflows/scripts/build/*.sh')

if [ "$checked" -eq 0 ]; then
  echo "FAIL: no build-machinery scripts matched — pathspec/layout drift?"
  exit 1
fi

if [ "$fail" -ne 0 ]; then
  echo "FAIL: one or more directly-invoked build-machinery scripts lack the exec bit (see #628)"
  exit 1
fi
echo "PASS: all $checked directly-invoked build-machinery scripts are tracked 100755 (#628 guard)"
