#!/usr/bin/env bash
# SessionStart hook — drains .mind/ session stubs from all dev roots into the
# knowledge store at Sessions/_inbox/<original-filename>.md, via the
# knowledge_store seam's `ks_write` op. Deletes each local stub once its
# document write reports success.
#
# Stubs that land in Sessions/_inbox/ are reviewed and processed by the
# /tidy slash command (extracts learnings, generates tasks, moves to
# Sessions/<filename>.md).
#
# Failures are logged to the XDG state dir (foundation #773):
# ${XDG_STATE_HOME:-$HOME/.local/state}/foundation/session-start-drain.log —
# and stubs are left in place for the next run. Never blocks session start.
#
# EVAL_RUN suppression: when EVAL_RUN is set (non-empty), the store drain is
# skipped entirely.  The session-id additionalContext is still emitted so eval
# runs can trace their own session; no store writes occur.

set -uo pipefail

# ── Transport is the SEAM's business, not this hook's (temperloop#732) ──────
# This hook used to hand-roll a `curl -X PUT` against the Obsidian Local REST
# API, with its own API-key read, TLS flag and HTTP-code branch. That was a
# caller-routing gap, NOT a deliberate by-backend-mode transport this file is
# supposed to branch on: knowledge_store.contract.md § Non-goals of this seam
# says plainly "This file defines the interface and both backends
# (`plain-files`, `obsidian`) — it does not itself route any hook, command,
# or script through the interface. Routing callers over ... is sibling-level
# work". So there is no mode for a caller to switch on; there is one op,
# `ks_write`, and KNOWLEDGE_STORE_BACKEND decides the wire format behind it:
#
#   plain-files (the default) -> an atomic file write under ks_root. This is
#     the transport a stranger's fresh install needs and the one the raw-curl
#     path could never provide — it required an Obsidian vault plus a running
#     Local REST API plugin just to drain a stub.
#   obsidian                  -> `PUT /vault/<path>` on the Local REST API
#     (contract § The obsidian backend, op-to-REST table), i.e. exactly the
#     request this hook used to build by hand — so an Obsidian-backed install
#     keeps its old wire behaviour, with the key file, base URL and
#     whole-file-replace semantics owned by one adapter instead of copied here.
#
# ── knowledge_store lib resolution ─────────────────────────────────────────
# Both libs are sourced: knowledge_store.sh for the interface itself, and
# knowledge_store_obsidian.sh so an operator running
# KNOWLEDGE_STORE_BACKEND=obsidian has that backend's four
# `_ks_backend_obsidian_*` functions in scope for ks__dispatch to find (the
# registration seam — the interface file itself never implements it).
#
# This hook therefore depends on ks_root() DIRECTLY now, in one hop, rather
# than transitively through the obsidian key-file default it used to strip a
# suffix off. That dependency is the load-bearing one to keep in mind: a
# ks_root() resolution bug in the bare-env plane (temperloop#1328 — a process
# that never sources build.config.sh, exactly this hook's own shape, falling
# through to the wrong default root) breaks this hook's drain outright.
# Measured cost before that fix: 218 skipped drains across 16 consecutive
# days on the operator's host. `workflows/scripts/install/doctor.sh`'s
# check_knowledge_root() is the standing guard on it.
#
# Resolution order (temperloop#406 — no shipped hook may default to a
# hardcoded personal checkout path):
#   1. KS_LIB_DIR env override — highest precedence, always wins.
#   2. BASH_SOURCE-relative: claude/hooks/<this file> -> ../../workflows/scripts/lib.
#      Works for both a plain checkout and the production whole-directory
#      symlink install (workflows/scripts/install/links.sh symlinks the
#      entire claude/hooks/ directory, not per-file — the OS resolves that
#      symlinked directory before applying "..", so the relative climb still
#      lands in the real checkout). Same convention as
#      session-end-read-summary.sh's own KS_LIB_DIR resolution in this
#      directory.
# No hardcoded personal-path default: on a checkout where neither resolves
# (a stripped-down tree with no workflows/scripts/lib/), KS_LIB_DIR stays
# empty, the sourcing below no-ops, and the "seam unavailable" check further
# down fails open onto "skipping drain" exactly as the old "API key file
# missing" check did.
KS_LIB_DIR="${KS_LIB_DIR:-}"
if [ -z "$KS_LIB_DIR" ]; then
  KS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../workflows/scripts/lib" 2>/dev/null && pwd)"
fi
if [ -n "$KS_LIB_DIR" ] && [ -f "$KS_LIB_DIR/knowledge_store.sh" ]; then
  # shellcheck source=/dev/null
  . "$KS_LIB_DIR/knowledge_store.sh"
fi
if [ -n "$KS_LIB_DIR" ] && [ -f "$KS_LIB_DIR/knowledge_store_obsidian.sh" ]; then
  # shellcheck source=/dev/null
  . "$KS_LIB_DIR/knowledge_store_obsidian.sh"
fi

# doc-id prefix, not a filesystem path — every write below is
# `ks_write "$INBOX_DIR/<filename>"`, which the seam normalizes and resolves
# against whatever the active backend calls its root.
INBOX_DIR="Sessions/_inbox"
XDG_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/foundation"
mkdir -p "$XDG_STATE_DIR" 2>/dev/null || true
LOG="$XDG_STATE_DIR/session-start-drain.log"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }

# Capture stdin (Claude Code sends session_id, transcript_path, cwd, etc. here).
INPUT=$(cat 2>/dev/null || true)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)
SHORT_ID=$(printf '%s' "$SESSION_ID" | cut -c1-8)

# Surface session ID to the model so live decision-capture can stamp `source_session`.
# See vault note [[Decisions/foundation - Vault provenance schema (note-level)]].
# Emitted early so it fires even when no stubs exist (drain section below has early exits).
if [ -n "$SHORT_ID" ]; then
  printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"<session-id>%s</session-id>"}}\n' "$SHORT_ID"
fi

# EVAL_RUN suppression: skip all store writes (the stub drain below).
# Session-id was already emitted above so eval runs can trace their session.
# shellcheck source=eval-guard.sh
. "$(dirname "${BASH_SOURCE[0]}")/eval-guard.sh"
eval_guard_exit_if_eval

# Fail open when the seam never got sourced (a hooks-only vendor drop with no
# workflows/scripts/lib/ two directories up). Stubs are left in place.
if ! command -v ks_write >/dev/null 2>&1; then
  log "knowledge_store seam unavailable (KS_LIB_DIR='$KS_LIB_DIR') — skipping drain"
  exit 0
fi

# The store's own root(s), resolved only to EXCLUDE them from the stub search
# — a .mind/ directory that happens to sit inside the store must never be
# drained back into the store. No content I/O uses these values; every write
# goes through ks_write's own doc-id resolution.
#
# TWO roots are pruned, not one, and both are best-effort. ks_root() is the
# plain-files root; under the obsidian backend that value is documented as
# meaningless (knowledge_store_obsidian.sh: "the vault IS the root"), and the
# vault is instead the tree KNOWLEDGE_STORE_OBSIDIAN_API_KEY_FILE points into
# — operator-overridable, so it does NOT necessarily agree with ks_root(). An
# operator who overrides the key-file path while leaving KNOWLEDGE_STORE_ROOT
# at its default would otherwise leave the real vault unpruned and have its
# own .mind/*.md drained out of it and deleted. Pruning both is two cheap
# -path terms and costs nothing when they coincide or when either is empty.
STORE_ROOTS=()

# Trailing slashes MUST be stripped: find -path compares against the walked
# path, which never carries one, and treats its operand as a glob — so a root
# set as '/path/' matches nothing, -prune silently falls through, and the
# store drains into itself. ks_root prints KNOWLEDGE_STORE_ROOT verbatim and
# strips nothing, so an operator-set trailing slash reaches here intact.
_add_store_root() {
  local root="${1%/}"
  [ -n "$root" ] || return 0
  local seen
  for seen in ${STORE_ROOTS[0]+"${STORE_ROOTS[@]}"}; do
    [ "$seen" = "$root" ] && return 0
  done
  STORE_ROOTS+=("$root")
}

if command -v ks_root >/dev/null 2>&1; then
  _add_store_root "$(ks_root 2>/dev/null || true)"
fi

# The obsidian vault root, derived by stripping the plugin-data suffix that
# KNOWLEDGE_STORE_OBSIDIAN_API_KEY_FILE's own default plants inside the vault.
_key_file="${KNOWLEDGE_STORE_OBSIDIAN_API_KEY_FILE:-}"
if [ -n "$_key_file" ]; then
  _add_store_root "${_key_file%/.obsidian/plugins/obsidian-local-rest-api/data.json}"
fi

# Find stubs across dev roots, excluding the store itself.
FIND_ARGS=("$HOME/dev" "$HOME/Cursor")
for _root in ${STORE_ROOTS[0]+"${STORE_ROOTS[@]}"}; do
  FIND_ARGS+=(-path "$_root" -prune -o)
done
FIND_ARGS+=(-type f -path '*/.mind/*.md' -print)
STUBS=$(find "${FIND_ARGS[@]}" 2>/dev/null)

if [ -z "$STUBS" ]; then
  exit 0  # nothing to drain, silent
fi

moved=0
failed=0

while IFS= read -r stub; do
  [ -z "$stub" ] && continue
  [ ! -f "$stub" ] && continue

  filename=$(basename "$stub")
  doc_id="$INBOX_DIR/$filename"

  # ks_write is a whole-document replace (contract § ks_write) — idempotent,
  # so a re-run after a partially-completed prior drain simply overwrites,
  # the same property the old PUT relied on. stdin is redirected explicitly
  # from the stub, so it never consumes this loop's own stdin.
  ks_err=$(ks_write "$doc_id" < "$stub" 2>&1 >/dev/null)
  rc=$?

  if [ "$rc" -eq 0 ]; then
    rm -f "$stub"
    moved=$((moved + 1))
    log "drained: $stub -> $doc_id"
  else
    failed=$((failed + 1))
    detail=$(printf '%s' "$ks_err" | tr '\n' ' ' | head -c 200)
    log "FAILED [ks_write rc=$rc]: $stub -> $doc_id | $detail"
  fi
done <<< "$STUBS"

if [ "$moved" -gt 0 ] || [ "$failed" -gt 0 ]; then
  log "summary: $moved moved, $failed failed"
fi

# Store snapshotting is NOT done here — the nightly /tidy command is the sole
# `mind_snapshot.sh` runner (its Step 8, temperloop K86). The session-start hook
# only drains SessionEnd stubs into _inbox; snapshotting the store's state is
# /tidy's job so the whole nightly run's writes land in one snapshot.

exit 0
