#!/usr/bin/env bash
# PreToolUse hook (matcher: Edit|Write|MultiEdit) — subtree-edit guard.
# Guard #1 of the kernel-routing rule (foundation #806, epic #763 "kernel
# split: fresh-history extraction + overlay + routing guards").
#
# WHY: post-cutover (F#804), the kernel file set lives PHYSICALLY under
# kernel/ in every repo that vendors it via `git subtree` (pinned by a
# `.kernel-pin` file at the repo root) — foundation, and any downstream
# consumer that adopts the same layout. Every pre-split path (claude/hooks/*,
# workflows/scripts/board/*, ...) is now a COMPAT SYMLINK pointing INTO
# kernel/. Editing through either the physical path or a compat symlink
# mutates the vendored subtree directly — but the ONLY sanctioned way to
# change kernel/ content is upstream-first: land the change in the
# temperloop (kernel) repo, then `make update-kernel` pulls it down and bumps
# `.kernel-pin` atomically (see CUTOVER-RUNBOOK.md). A stray Edit/Write
# through a symlink is easy to miss (a worker editing
# `workflows/scripts/board/lib/board.sh` may not notice it resolves into
# `kernel/`) — this hook is the "make it a conscious choice" nudge at edit
# time. The mechanical backstop that actually blocks an unwaived merge is
# Guard #2 (`scripts/kernel-drift-check.sh`, #807), which the batched-waiver
# bare `Upstream: <kernel-PR-url>` PR-body line satisfies.
#
# DETECTION: resolves the tool's target path to its REAL physical location
# (following every symlink in both the directory components AND a symlinked
# leaf file, portable — no GNU `realpath -f`) and tests it for containment
# under the resolved `kernel/` dir at the repo root IFF that root carries a
# `.kernel-pin` file (a repo with no pin is not kernel-vendored — e.g. every
# other repo on the machine — and the hook is inert there).
#
# VERDICT: ask (never deny) — a kernel/ edit is sometimes exactly what's
# wanted (an operator-approved batched waiver — CUTOVER-RUNBOOK.md), so this
# only forces a conscious beat, not a hard stop.
#
# PROVENANCE RE-PROBE (temperloop#1047): whichever way this guard resolves —
# ask or bypass — it first re-runs workflows/scripts/toolkit-provenance.sh and
# folds the current verdict into the message it emits. This guard's fire IS
# the moment drift begins, so it is the only place a MID-SESSION provenance
# notice can be delivered at all: the SessionStart provenance hook
# (session-start-provenance.sh) ran before this edit existed and is
# structurally blind to it. The two halves ship together; neither subsumes the
# other. The re-probe is fail-open and contributes nothing if the probe is
# absent or errors.
#
# BUILD-WORKER BYPASS (documented, deliberate — does not deadlock the build
# pipeline): a build worker operating inside a `.build-guard`-armed worktree
# (workflows/scripts/build/worktree.sh create) is ALREADY working under
# supervision — a scoped issue, an isolated worktree, PR review, and Guard
# #2's mechanical Upstream: waiver check downstream. Forcing an interactive
# `ask` on every kernel/ touch there would either hang an unattended worker
# (no live human to answer) or add nothing Guard #2 doesn't already enforce
# at merge time. So the hook goes SILENT (exit 0, no verdict — a normal
# permitted write) whenever EITHER holds, and logs a stderr note + state-log
# line either way so the bypass is never literally invisible:
#   - KERNEL_EDIT_ACK=1 is set in the hook's environment (a human or a
#     scripted caller opting out explicitly), OR
#   - the resolved worktree root (`git rev-parse --show-toplevel` from the
#     tool's cwd) carries a `.build-guard` marker file.
#
# EVAL_RUN: exits 0 silently, matching git-stale-branch-guard.sh — an
# unanswerable interactive `ask` would hang a headless eval session.
#
# FAILS OPEN: any internal error (missing jq, unparseable input, no git,
# unresolvable path) exits 0 immediately — a guard bug must never block a
# legitimate edit.
set -uo pipefail

# Hook logs live in the XDG state dir (foundation #773), not ~/.claude/hooks/
# — runtime state, not config.
XDG_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/foundation"
mkdir -p "$XDG_STATE_DIR" 2>/dev/null || true
LOG="$XDG_STATE_DIR/subtree-edit-guard.log"
log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG" 2>/dev/null || true; }

INPUT=$(cat 2>/dev/null || true)
[ -n "$INPUT" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0   # fail open: no jq, no guard

[ -n "${EVAL_RUN:-}" ] && exit 0          # no interactive prompt under eval

tool=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
case "$tool" in
  Edit|Write|MultiEdit) ;;
  *) exit 0 ;;   # matcher should scope this, but double-check
esac

# The tool's working directory (where relative paths resolve). Falls back to
# PWD if the harness omits it.
cwd=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
[ -n "$cwd" ] || cwd="$PWD"

# Repo root + kernel-pin gate: inert unless THIS checkout vendors a kernel/
# subtree (a .kernel-pin file at the git toplevel).
root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || true)
[ -n "$root" ] || exit 0
if rp=$(cd "$root" 2>/dev/null && pwd -P); then root="$rp"; fi
root="${root%/}"
[ -f "$root/.kernel-pin" ] || exit 0
[ -d "$root/kernel" ] || exit 0
kernel_dir=$(cd "$root/kernel" 2>/dev/null && pwd -P) || exit 0
kernel_dir="${kernel_dir%/}"

# --- BUILD-WORKER BYPASS (see header) -----------------------------------
bypass_reason=""
if [ -n "${KERNEL_EDIT_ACK:-}" ]; then
  bypass_reason="KERNEL_EDIT_ACK=1"
elif [ -f "$root/.build-guard" ]; then
  bypass_reason=".build-guard marker present at $root"
fi

# resolve <path> — the tool-input target's REAL physical location: fully
# follow symlinks in every directory component (cd -P) AND a symlinked leaf
# file, iteratively (a compat symlink's own target may itself be relative
# and pass through further symlinked directories). Portable — no GNU
# `realpath -f`; mirrors board-mirror.sh's readlink loop composed with
# build-worktree-guard.sh's cd-P-the-parent resolution.
resolve() {
  local p="$1" dir base cur suffix rcur target hops=0
  case "$p" in
    /*) ;;
    *) p="$cwd/$p" ;;
  esac

  # Each hop: split into dir/base (NEVER `cd` the leaf itself — it may be a
  # plain file), walk `dir` up to its nearest EXISTING ancestor DIRECTORY
  # (a Write may create several levels of new directory at once, so this is
  # a loop, not a single dirname step), physically resolve that ancestor
  # (cd -P) and re-attach whatever didn't exist + the leaf. If the leaf
  # itself is then a symlink (file- or dir-level), follow it — its target
  # may be relative and pass through further symlinked directories, so the
  # next hop re-runs the same dir-resolution from scratch.
  while [ "$hops" -lt 40 ]; do
    hops=$((hops + 1))
    dir=$(dirname -- "$p")
    base=$(basename -- "$p")
    cur="$dir"; suffix=""
    while [ ! -d "$cur" ] && [ "$cur" != "/" ]; do
      suffix="/$(basename -- "$cur")$suffix"
      cur=$(dirname -- "$cur")
    done
    if rcur=$(cd "$cur" 2>/dev/null && pwd -P); then
      p="$rcur$suffix/$base"
    else
      printf '%s\n' "$p"   # unresolvable (shouldn't happen: "/" always exists)
      return 0
    fi
    if [ -n "$suffix" ]; then
      # A directory component doesn't exist yet (new nested path) — the
      # leaf can't be a symlink in a meaningful sense; nothing more to do.
      printf '%s\n' "$p"
      return 0
    fi
    if [ -L "$p" ]; then
      target=$(readlink -- "$p") || { printf '%s\n' "$p"; return 0; }
      case "$target" in
        /*) p="$target" ;;
        *)  p="$rcur/$target" ;;
      esac
      continue
    fi
    printf '%s\n' "$p"
    return 0
  done
  printf '%s\n' "$p"   # symlink-loop guard — return best-effort
}

# Collect every target path the tool would write. Edit/Write/MultiEdit all
# carry a single `file_path` in tool_input; gather defensively in case a
# variant adds more.
targets=()
while IFS= read -r _t; do
  [ -n "$_t" ] && targets+=("$_t")
done < <(printf '%s' "$INPUT" | jq -r '
  (.tool_input // {}) as $i
  | [ $i.file_path?, $i.path?, ($i.edits // [])[].file_path? ]
  | map(select(. != null and . != ""))
  | .[]' 2>/dev/null)
[ "${#targets[@]}" -gt 0 ] || exit 0

hit=""
for t in "${targets[@]}"; do
  ap=$(resolve "$t")
  case "$ap" in
    "$kernel_dir"/*|"$kernel_dir")
      hit="$ap"
      break
      ;;
  esac
done
[ -n "$hit" ] || exit 0

# --- PROVENANCE RE-PROBE (temperloop#1047) -------------------------------
# This guard firing IS the moment drift begins, which makes it the one place
# a mid-session notice can be delivered at all: the SessionStart provenance
# hook ran before this edit was conceived and is structurally blind to it.
# So re-probe here and fold the current verdict into whichever message this
# guard is about to emit — the ask prompt, or the bypass note.
#
# Deliberately reports the state as it is RIGHT NOW, before the edit lands: on
# a clean tree that reads RELEASED, and the line says plainly that this edit
# is what begins the drift. Claiming MODIFIED for an edit that has not
# happened yet would be a false report, and this whole mechanism is built on
# never reporting a state the tree is not actually in.
#
# Fail-open and best-effort, like every other line in this file: a missing or
# erroring probe simply contributes nothing. Test seam:
# TOOLKIT_PROVENANCE_SH.
provenance_note=""
_probe="${TOOLKIT_PROVENANCE_SH:-}"
if [ -z "$_probe" ]; then
  _probe="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../workflows/scripts" 2>/dev/null && pwd)/toolkit-provenance.sh"
fi
if [ -f "$_probe" ]; then
  _verdict=$(bash "$_probe" --root "$root" --format verdict 2>/dev/null) || _verdict=""
  case "$_verdict" in
    RELEASED)
      provenance_note=" TOOLKIT PROVENANCE: this checkout currently reports RELEASED — this edit is the moment it stops being the release it claims. Run 'temperloop doctor' (or workflows/scripts/toolkit-provenance.sh) at any point to see the verdict and every drifted path."
      ;;
    MODIFIED)
      provenance_note=" TOOLKIT PROVENANCE: this checkout ALREADY reports MODIFIED — it is not the release it claims to be, and this edit adds to that. Run 'temperloop doctor' (or workflows/scripts/toolkit-provenance.sh) for every drifted path, with the commit and author behind each."
      ;;
  esac
fi

if [ -n "$bypass_reason" ]; then
  log "BYPASS ($bypass_reason) :: $hit"
  echo "subtree-edit-guard: kernel/ edit at '$hit' permitted without an interactive ask — bypass: $bypass_reason. Reminder: this content is vendored from temperloop; the PR must carry a bare 'Upstream: <kernel-PR-url>' line (or ride an operator-approved batched waiver — see CUTOVER-RUNBOOK.md), or Guard #2 (scripts/kernel-drift-check.sh) will flag it at merge time.${provenance_note}" >&2
  exit 0
fi

reason="This Edit/Write/MultiEdit targets '$hit', which is INSIDE the vendored kernel/ subtree (pinned by .kernel-pin at $root) — either a direct kernel/... path or a pre-split compat symlink that resolves into it. Kernel content is upstream-first: land this change in the temperloop repo and pull it down via 'make update-kernel' (bumps .kernel-pin atomically), rather than editing the vendored copy here. Editing it in place is a SANCTIONED, VISIBLE exception rather than a forbidden one: set KERNEL_EDIT_ACK=1 to acknowledge it up front, and carry the change back upstream with a bare 'Upstream: <kernel-PR-url>' line in the PR body (or an operator-approved batched waiver — see CUTOVER-RUNBOOK.md); scripts/kernel-drift-check.sh (Guard #2) enforces that waiver at merge time.${provenance_note}"
log "ASK :: $hit"
jq -cn --arg r "$reason" \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:$r}}' \
  2>/dev/null || true
exit 0
