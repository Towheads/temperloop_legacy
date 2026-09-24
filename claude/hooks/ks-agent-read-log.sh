#!/usr/bin/env bash
# PostToolUse hook — agent-plane knowledge-store read-telemetry emitter
# (temperloop#236, Epic #226 "Vault IA v2 kernel machinery" capture point 2:
# "agent-plane read telemetry").
#
# Companion to the SCRIPT-plane read-log (`ks__read_log_emit`, PR #249, in
# workflows/scripts/lib/knowledge_store.sh) — that one fires for every
# ks_read/ks_write/ks_append/ks_list/ks_search call made by shell tooling.
# THIS hook fires for the other caller of the knowledge store: a Claude
# session reading/writing it directly through an MCP tool (Obsidian today).
# Both emit the exact same normalized line shape, via the exact same
# function, so a reader of the log never needs to know which plane produced
# a given line except by its `plane` field.
#
#   <timestamp> · <session-id> · <plane> · <op> · <doc-path-or-query>
#
# See workflows/scripts/lib/knowledge_store.contract.md § "Read-log
# telemetry (script plane)" / "Agent plane" for the full format contract.
#
# ── Transport matcher seam ──────────────────────────────────────────────
# WHICH tool_name values count as "a knowledge-store MCP call" is NOT
# hardcoded here — it is read from KNOWLEDGE_READ_LOG_AGENT_MATCHERS, a
# space-separated list of shell `case`-glob patterns defined right next to
# KNOWLEDGE_STORE_BACKEND in knowledge_store.sh (today:
# `mcp__obsidian* mcp__obsidian-builtin*`). Enabling a future
# `mcp__basic-memory__*` transport at the mcp_obsidian EOL cutover
# (F#946/#947) is a one-line edit to that setting — no edit to this file. The
# PostToolUse `matcher` this hook is registered under (in the consuming
# repo's settings.json — see claude/hooks/README.md) may be broader than
# this list (e.g. `mcp__.*`) since this in-hook check is authoritative and
# re-applied on every event regardless of the harness-level matcher string.
#
# ── op derivation ────────────────────────────────────────────────────────
# tool_input schemas vary per MCP tool and aren't documented in this repo,
# so op derivation is a SIMPLE, best-effort name-keyword mapping over the
# matched tool_name (never the tool's arguments/response):
#
#   *search*                                          -> search
#   *list*  (incl. *tag_list, *command_list)          -> list
#   *append*                                          -> append
#   *write* | *create* | *patch* | *delete* | *move*  -> write
#   *read* | *get_vault_file | *get_document_map |
#     *get_active_file | *active_file_get_path |
#     *periodic_note_get_path | *get_server_info |
#     *open_file                                      -> read
#   anything else matched by the transport seam        -> other
#
# `other` is deliberate, not a bug: an unrecognized-but-matched tool (e.g. a
# future MCP tool this mapping hasn't been taught yet) is logged with a
# generic op rather than silently dropped — the epic's own acceptance
# wording ("unknown knowledge-store tools log with a generic op rather than
# being dropped silently").
#
# doc-path-or-query is extracted from tool_input by trying, in order, the
# common single-value argument names seen across Obsidian-MCP-shaped tools:
# path / filePath / filepath / file / query / q / directory / dir / tag /
# newPath / destination. Falls back to the literal "-" placeholder (same
# convention the script-plane emitter uses for a missing session id) when
# none is present — never blocks or drops the event over an unmapped field
# name.
#
# ── Fail-open discipline ─────────────────────────────────────────────────
# A hook/logging error must NEVER block the tool call it observes (the tool
# call already completed by the time PostToolUse runs, but a non-zero exit
# or malformed hook output can still surface as a spurious error to the
# session). Every exit path below is `exit 0`; the one delegated failure
# mode (ks__read_log_emit's own log-append failure) is already fail-open by
# construction (see that function's own header) and additionally never
# reached at all on a checkout with no knowledge-store config — this hook
# is INERT (no knowledge_store.sh to source) rather than reimplementing the
# line format from a hardcoded guess. Never hardcodes a personal path: the
# knowledge_store.sh location is resolved relative to this file's own
# (symlink-resolved) directory, never a hardcoded personal checkout literal.
set -uo pipefail

# shellcheck source=eval-guard.sh
. "$(dirname "${BASH_SOURCE[0]}")/eval-guard.sh"
eval_guard_exit_if_eval

# Hook debug log (distinct from the knowledge-store read-log itself) lives
# in the XDG state dir (foundation #773), not ~/.claude/hooks/ — runtime
# state, not config.
XDG_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/foundation"
mkdir -p "$XDG_STATE_DIR" 2>/dev/null || true
LOG="$XDG_STATE_DIR/ks-agent-read-log.log"
log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG" 2>/dev/null || true; }

INPUT=$(cat 2>/dev/null || true)
[ -n "$INPUT" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0   # fail open: no jq, no telemetry

tool=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
[ -n "$tool" ] || exit 0

# ── Resolve knowledge_store.sh relative to THIS file's real directory ─────
# Never a hardcoded personal checkout path — that would fail the stranger
# test for any checkout whose owner isn't the machine the literal was
# authored on. `cd ... && pwd -P` follows a symlinked hooks/
# directory (this hook is typically reached via a `~/.claude/hooks ->
# <repo>/claude/hooks` directory symlink, per this repo's install
# convention) back to the real repo tree, so `../..` correctly climbs to
# the real repo root rather than ~/.claude's parent.
hook_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)" || exit 0
repo_root="$(cd "$hook_dir/../.." 2>/dev/null && pwd -P)" || exit 0
ks_lib="$repo_root/workflows/scripts/lib/knowledge_store.sh"

# INERT on a checkout with no knowledge-store config at all (a kernel-hooks
# -only vendor, or any tree that hasn't wired up workflows/scripts/lib) —
# fail open rather than reimplement the log-line format from a guess.
[ -f "$ks_lib" ] || exit 0
# shellcheck source=/dev/null
. "$ks_lib" || exit 0
command -v ks__read_log_emit >/dev/null 2>&1 || exit 0

# ── Transport matcher check (the config seam) ──────────────────────────
matched=0
# Intentional word-splitting: KNOWLEDGE_READ_LOG_AGENT_MATCHERS is a
# space-separated list of case-glob patterns by design (see this file's own
# header and the setting's definition in knowledge_store.sh).
# shellcheck disable=SC2086
for pat in ${KNOWLEDGE_READ_LOG_AGENT_MATCHERS:-}; do
  # shellcheck disable=SC2254  # $pat is deliberately unquoted: it's a glob
  # pattern from the matcher-seam list, not a literal to match verbatim.
  case "$tool" in
    $pat) matched=1; break ;;
  esac
done
[ "$matched" -eq 1 ] || exit 0

# ── op derivation (simple, name-keyword based — see header) ─────────────
op="other"
case "$tool" in
  *search*) op="search" ;;
  *list*) op="list" ;;
  *append*) op="append" ;;
  *write*|*create*|*patch*|*delete*|*move*) op="write" ;;
  *read*|*get_vault_file|*get_document_map|*get_active_file|*active_file_get_path|*periodic_note_get_path|*get_server_info|*open_file) op="read" ;;
  *) op="other" ;;
esac

# ── doc-path-or-query extraction (best-effort, see header) ──────────────
doc=$(printf '%s' "$INPUT" | jq -r '
  (.tool_input // {}) as $i
  | ($i.path // $i.filePath // $i.filepath // $i.file
     // $i.query // $i.q
     // $i.directory // $i.dir
     // $i.tag
     // $i.newPath // $i.destination
     // empty)
  | tostring' 2>/dev/null)
[ -n "$doc" ] || doc="-"

log "EMIT tool=$tool op=$op doc=$doc"
ks__read_log_emit agent "$op" "$doc" || true

exit 0
