#!/usr/bin/env bash
# SessionEnd hook — prints one summary line tallying this session's
# knowledge-store activity from the script-plane read log:
#
#   knowledge store: N reads, M searches
#
# temperloop#237 (SessionEnd read one-liner), consuming the read-log
# telemetry seam landed by temperloop#229 (ks__read_log_emit,
# workflows/scripts/lib/knowledge_store.sh). This hook does NOT re-implement
# that log's path/format contract — it sources knowledge_store.sh and calls
# its _ks_read_log_path() setting resolver, so KNOWLEDGE_READ_LOG (or its
# XDG_STATE_HOME-based default) is resolved in exactly one place in the repo.
#
# Reads JSON on stdin: {session_id, ...} (the Claude Code hooks contract).
# Writes: one line to stdout, nothing else — no file, no vault write.
#
# ── Classification (documented per the acceptance contract) ────────────────
# The read log's `op` field is one of read | write | append | list | search
# (knowledge_store.sh's ks__dispatch covers the first four; knowledge_search.sh's
# ks_search emits the fifth). This hook counts op=search lines as "searches"
# and every other op (read/write/append/list) as "reads" — a coarse two-bucket
# split by design; a future consumer wanting a finer per-op breakdown reads the
# log directly rather than this summary line.
#
# ── Zero-activity vs. fail-open (two DIFFERENT behaviors, both intentional) ─
#   * Read log present and readable, but zero lines match this session id
#     -> EXPLICIT zero line: "knowledge store: 0 reads, 0 searches". The
#     telemetry seam is wired up; zero is a real, meaningful answer.
#   * Read log missing/unreadable, knowledge_store.sh not found/sourceable,
#     stdin JSON unparsable, or any other error -> SILENT, no line at all,
#     exit 0. This is the stranger-test case: a fresh checkout with no read
#     log yet (or no jq, or a stripped-down tree missing
#     workflows/scripts/lib/) must be completely inert here, never noisy and
#     never fatal to session end.
#
# EVAL_RUN suppression: mirrors session-end-log.sh — eval sessions must not
# emit this line (deterministic eval transcripts, no stray side-channel text).
# shellcheck source=eval-guard.sh
. "$(dirname "${BASH_SOURCE[0]}")/eval-guard.sh"
eval_guard_exit_if_eval

set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0

INPUT="$(cat)"
SESSION_ID="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)"
[ -n "$SESSION_ID" ] || exit 0

# --- Locate + source knowledge_store.sh (reuse its _ks_read_log_path setting) --
# Resolution order:
#   1. KS_LIB_DIR env override — same convention already used by
#      session-start-drain.sh / mcp-health-preflight.sh in this directory
#      (e.g. for the eval harness's per-file-symlinked hook config, see
#      claude/hooks/README.md § Eval profile contract).
#   2. BASH_SOURCE-relative: claude/hooks/<this file> -> ../../workflows/scripts/lib.
#      Works for both a plain checkout and the production whole-directory
#      symlink install (workflows/scripts/install/links.sh symlinks the
#      entire claude/hooks/ directory, not per-file — the OS resolves that
#      symlinked directory before applying "..", so the relative climb still
#      lands in the real checkout).
# No hardcoded personal path default: on a checkout where neither resolves
# (e.g. a stripped-down tree with no workflows/scripts/lib/, or a
# per-file-symlinked layout that breaks the relative climb), KS_LIB_DIR stays
# empty and this hook falls through to the fail-open exit below.
KS_LIB_DIR="${KS_LIB_DIR:-}"
if [ -z "$KS_LIB_DIR" ]; then
  KS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../workflows/scripts/lib" 2>/dev/null && pwd)"
fi
if [ -n "$KS_LIB_DIR" ] && [ -f "$KS_LIB_DIR/knowledge_store.sh" ]; then
  # shellcheck source=/dev/null
  . "$KS_LIB_DIR/knowledge_store.sh"
fi
command -v _ks_read_log_path >/dev/null 2>&1 || exit 0

LOG="$(_ks_read_log_path 2>/dev/null)"
[ -n "$LOG" ] && [ -f "$LOG" ] && [ -r "$LOG" ] || exit 0

# --- Tally: filter to this session, split by op=search vs. everything else --
# Line format (knowledge_store.sh): one event per line, fields joined by
# " · " (U+00B7 MIDDLE DOT, written as the \xc2\xb7 UTF-8 byte escape so the
# separator is pinned exactly regardless of locale):
#   <timestamp> · <session-id> · <plane> · <op> · <doc-path-or-query>
DOT="$(printf '\xc2\xb7')"
SEP=" ${DOT} "
SESSION_FIELD="${SEP}${SESSION_ID}${SEP}"

# TOTAL: every read-log line for this session, any op. grep -F treats
# SESSION_ID as a literal string (no regex-metachar risk from an unusual
# session id).
TOTAL="$(grep -c -F -- "$SESSION_FIELD" "$LOG" 2>/dev/null)"
case "$TOTAL" in ''|*[!0-9]*) TOTAL=0 ;; esac

# SEARCHES: of this session's lines, those whose op field is "search". The
# plane token (script today, a future agent-plane caller later) is matched
# generically via a non-space run rather than an enumerated literal, so a
# new plane value never silently miscounts as "not search". SESSION_ID never
# reaches this second grep's -E pattern (only fixed literals + a bracket
# class), so it stays regex-injection-safe even though the first stage used
# -F for the untrusted part.
SEARCHES="$(grep -F -- "$SESSION_FIELD" "$LOG" 2>/dev/null | grep -c -E -- "${SEP}[^ ]+${SEP}search${SEP}" 2>/dev/null)"
case "$SEARCHES" in ''|*[!0-9]*) SEARCHES=0 ;; esac

READS=$((TOTAL - SEARCHES))
[ "$READS" -ge 0 ] 2>/dev/null || READS=0

printf 'knowledge store: %d reads, %d searches\n' "$READS" "$SEARCHES"
exit 0
