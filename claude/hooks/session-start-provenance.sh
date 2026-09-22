#!/usr/bin/env bash
# SessionStart hook — unprompted toolkit-provenance notice (temperloop#1047,
# ADR 0021/0022).
#
# WHY UNPROMPTED. The audience for this verdict is the live operator watching
# a run, not someone auditing a machine — so it has to arrive without being
# asked for. Nothing else on the machine reports whether the toolkit code this
# session is about to execute is a released version or somebody's local
# modification, and a modification silently carries across engagements: the
# managed clone is shared by every project an adopter touches (bin/README.md
# § Running across multiple repos or clients), so one edit is live everywhere
# until it is restored.
#
# WHAT IT DOES. Runs workflows/scripts/toolkit-provenance.sh and, ONLY when
# the verdict is MODIFIED, contributes an `additionalContext` block naming the
# release the toolkit claims to be and every drifted path (uncommitted vs.
# committed, with the committing author and any `Upstream:` reference). It
# says NOTHING on RELEASED and NOTHING on UNKNOWN — a session that starts in
# the kernel's own development checkout, or anywhere with no release baseline,
# is not nagged. Default-to-silence, exactly like the drain probes.
#
# THIS IS HALF OF THE NOTICE, NOT ALL OF IT. A session-start check is
# structurally blind to the mid-session edit that motivates the whole design —
# the operator edits the vendored tree at minute 20 and this hook ran at minute
# 0. The other half is the re-probe on claude/hooks/subtree-edit-guard.sh's own
# fire, because the guard firing IS the moment drift begins. Neither half
# subsumes the other; both ship together.
#
# EVAL_RUN: exits 0 silently, like every other hook that owns an output
# channel — an eval run's transcript must not carry production provenance.
#
# FAILS OPEN, ALWAYS. No jq, no probe on disk, an erroring probe, an
# unreadable tree: exit 0 with no output. A hook that can wedge session start
# is worse than a hook that occasionally says nothing.
#
# READ-ONLY: contributes context and nothing else. It writes no file, no
# marker, and no state anywhere (ADR 0021 — the whole mechanism persists
# nothing, which is also why uninstall leaves no residue).
#
# Test seam: TOOLKIT_PROVENANCE_SH overrides the probe path.
set -uo pipefail

# EVAL_RUN suppression first — before any work at all.
# shellcheck source=eval-guard.sh
. "$(dirname "${BASH_SOURCE[0]}")/eval-guard.sh"
eval_guard_exit_if_eval

command -v jq >/dev/null 2>&1 || exit 0   # fail open: no jq, no notice

# Drain stdin so the harness never blocks writing to us; we need nothing from it.
cat >/dev/null 2>&1 || true

# Resolve the probe RELATIVE TO THIS FILE, never from $PWD — the same
# convention session-start-drain.sh uses for KS_LIB_DIR, and for the same
# reason: the production install symlinks the whole claude/hooks/ directory,
# and the OS resolves that symlinked directory before applying "..", so the
# relative climb lands in the real toolkit checkout. That is exactly what makes
# the cross-engagement case work — a session started in an unrelated project
# still resolves into the shared toolkit and still gets the verdict.
PROBE="${TOOLKIT_PROVENANCE_SH:-}"
if [ -z "$PROBE" ]; then
  PROBE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../workflows/scripts" 2>/dev/null && pwd)/toolkit-provenance.sh"
fi
[ -f "$PROBE" ] || exit 0

report="$(bash "$PROBE" --format report 2>/dev/null)" || exit 0
[ -n "$report" ] || exit 0

case "$report" in
  "Toolkit provenance: MODIFIED"*) ;;
  *) exit 0 ;;   # RELEASED or UNKNOWN — say nothing
esac

notice="TOOLKIT PROVENANCE: the toolkit code running this session is NOT the release it claims to be.

${report}

This is a sanctioned state, not an error — but it is yours to reconcile: either
land the change upstream in the kernel repo and pull it down, or restore the
released content. Until then every session on this machine, in every project,
runs the modified code. Full context: docs/features/toolkit-provenance.md"

jq -cn --arg c "$notice" \
  '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$c}}' \
  2>/dev/null || true
exit 0
