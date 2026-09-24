#!/usr/bin/env bash
#
# knowledge_search_mcp.sh — an optional WARM search backend for the
# knowledge_search adapter: "basic-memory-mcp".
#
# Talks to a persistent, externally-supervised `basic-memory mcp`
# streamable-http daemon (launchd / systemd / any process supervisor — this
# library never launches it) instead of spawning a fresh basic-memory
# CLI subprocess per query. A warm daemon pays basic-memory's ~2s app/DB/embedding-model
# startup ONCE at load; each search is then a plain HTTP round-trip to an
# in-process handler — measured ~0.2s per fresh call (full initialize + search
# cycle) vs several seconds for the cold CLI path. The cold "basic-memory"
# backend (knowledge_search.sh) remains the zero-infrastructure default; this
# file is only useful where an adopter has stood up the daemon.
#
# ── Registration (extends via the dispatch seam — no core edit) ────────────
# knowledge_search.sh dispatches backends by `command -v` on
# `_ks_search_backend_<name>_<op>`. This file registers a NEW backend named
# "basic-memory-mcp" purely by DEFINING those functions, so it extends the
# adapter without modifying knowledge_search.sh. It MUST be sourced AFTER
# knowledge_search.sh: it reuses that file's cold
# `_ks_search_backend_basic_memory_*` functions for fail-open fallback, its
# JSONL reshape contract, and ks_root (from knowledge_store.sh). Select it
# with `export KNOWLEDGE_SEARCH_BACKEND=basic-memory-mcp`.
#
# ── Fail-open ─────────────────────────────────────────────────────────────
# If the daemon is unreachable / errors / returns an unparseable body, this
# backend DELEGATES to the cold "basic-memory" backend (a fresh subprocess
# against the adapter's uv-tool-installed basic-memory entry point). A slow answer, never a silent empty result — the adapter's
# legible-degradation posture (knowledge_search.sh exit-code contract) is
# preserved.
#
# The fallback is SURFACED to the operator, not just whispered to a swallowed
# stderr (temperloop#54). On each fallback the backend fires
# `_ks_bm_mcp_fallback_signal`, which — at most ONCE per session — emits a
# durable raw-lake telemetry record (stream `knowledge-search-fallback`, so a
# down daemon is observable/alertable by the same rollups that read the other
# kernel streams) AND prints a one-time-per-session "degraded —" stderr notice
# (no per-query spam). Every step is fail-open: any error there is swallowed, the
# cold path still runs, and the caller still gets results with exit 0.
#
# ── Session lifecycle ─────────────────────────────────────────────────────
# Every MCP session this file opens (_ks_bm_mcp_open_session) is terminated by
# a matching _ks_bm_mcp_close_session — the streamable-HTTP DELETE /mcp
# teardown — on EVERY exit path, error/timeout paths included. The daemon
# retains per-session state until told to drop it (~1-3.6MB per search,
# 9.2GB after 48h before this — foundation#1710), so open/close pairing is a hard
# invariant here, and the close itself is fail-open (a failed DELETE never
# breaks a successful search).
#
# ── AGPL boundary ─────────────────────────────────────────────────────────
# basic-memory (AGPL-3.0) is reached ONLY as a separate process over the MCP
# protocol (HTTP + JSON-RPC) — never imported or vendored, exactly as the cold
# backend reaches it as an installed CLI. This file itself NEVER runs `basic-memory mcp`
# (it is an HTTP *client* of an already-running daemon); starting the daemon is
# the supervisor's job, out of this repo's tree. So the adapter stays
# CLI-only-plus-HTTP-client and test_knowledge_search_agpl_boundary.sh's "no
# tracked shell script invokes basic-memory mcp" invariant holds unchanged.
#
# This file is SOURCED — it sets no shell options (the caller owns set -euo).
# Depends on: knowledge_search.sh (source FIRST), curl, jq.

# ── Config settings ──────────────────────────────────────────────────────────
#   KNOWLEDGE_SEARCH_BM_MCP_URL    daemon endpoint. Default is a loopback-only
#                                  streamable-http address; override to match
#                                  the supervised daemon's host/port/path.
#   KNOWLEDGE_SEARCH_BM_MCP_PROTO  MCP protocol version sent in the handshake.
#   *_CONNECT_TIMEOUT / *_MAX_TIME curl timeouts (seconds). CONNECT is kept
#                                  short so an unreachable daemon fails FAST to
#                                  the cold fallback instead of hanging a caller.
: "${KNOWLEDGE_SEARCH_BM_MCP_URL:=http://127.0.0.1:8766/mcp}"
: "${KNOWLEDGE_SEARCH_BM_MCP_PROTO:=2025-03-26}"
: "${KNOWLEDGE_SEARCH_BM_MCP_CONNECT_TIMEOUT:=2}"
: "${KNOWLEDGE_SEARCH_BM_MCP_MAX_TIME:=30}"

# ── Operator-visible cold-fallback signal (temperloop#54) ──────────────────
# The ONLY prior signal that the warm path fell back to the (much slower) cold
# CLI was a per-query stderr line — invisible whenever the caller swallows
# stderr (the common case in foundation's normal invocation path), and spammy
# when it ISN'T swallowed. This section adds a durable, de-duped signal that
# survives a swallowed stderr, without changing the fail-open contract.
#
# Config settings (tests only):
#   KS_SEARCH_FALLBACK_RAW_DIR    override the raw-lake dir (default: the
#                                 <repo>/meta/data/raw resolved from this file).
#   KS_SEARCH_FALLBACK_STATE_DIR  override the de-dup marker dir (default:
#                                 ${TMPDIR:-/tmp}).
#
# Self-location captured at SOURCE time, portably across bash and zsh — both
# libs here are sourced under zsh too (temperloop#40). bash populates
# BASH_SOURCE; zsh leaves it unset but sets $0 to the sourced file at top level.
# Resolved to an ABSOLUTE dir now (in a `$( )` subshell so the caller's cwd is
# untouched) so a later chdir can't strand a relative path.
_KS_BM_MCP_DIR=""  # fail-open default: empty if self-location can't resolve
_KS_BM_MCP_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd 2>/dev/null)" || true

# Raw-lake sink dir, resolved like emit-command-run.sh: explicit override first
# (tests), else <repo>/meta/data/raw computed from this file's location
# (workflows/scripts/lib/ -> repo root is ../../..).
_ks_bm_mcp_raw_dir() {
  if [ -n "${KS_SEARCH_FALLBACK_RAW_DIR:-}" ]; then
    printf '%s\n' "$KS_SEARCH_FALLBACK_RAW_DIR"; return 0
  fi
  local root
  [ -n "${_KS_BM_MCP_DIR:-}" ] || return 1
  root="$(cd -P "$_KS_BM_MCP_DIR/../../.." 2>/dev/null && pwd)" || return 1
  printf '%s/meta/data/raw\n' "$root"
}

# Session-keyed de-dup marker path. Keyed by the raw CLAUDE_CODE_SESSION_ID when
# present (the same join key the raw/ streams use), else `pid-$$` so a manual
# shell still de-dups within its process. The marker is a real on-disk file, so
# it survives the command-substitution subshells callers wrap ks_search in.
# Sanitized to filename-safe characters.
_ks_bm_mcp_fallback_marker() {
  local dir key
  dir="${KS_SEARCH_FALLBACK_STATE_DIR:-${TMPDIR:-/tmp}}"
  key="${CLAUDE_CODE_SESSION_ID:-pid-$$}"
  key="$(printf '%s' "$key" | tr -c 'A-Za-z0-9._-' '_')"
  printf '%s/knowledge-search-mcp-fallback.%s\n' "$dir" "$key"
}

# Append one raw-lake telemetry record for a cold-fallback event. Fail-open:
# missing jq / unwritable sink / a jq error all return 0 silently — a telemetry
# emit must never break the caller (same contract as emit-command-run.sh).
# Record shape (schema_version "1"), canonical sink spec meta/data/raw/README.md:
#   {schema_version, ts, session_id, host, backend, reason, detail, url, project}
_ks_bm_mcp_emit_fallback_telemetry() {
  local reason="$1" detail="$2"
  command -v jq >/dev/null 2>&1 || return 0
  local raw_dir ts month host sid raw_file record
  raw_dir="$(_ks_bm_mcp_raw_dir)" || return 0
  [ -n "$raw_dir" ] || return 0
  mkdir -p "$raw_dir" 2>/dev/null || return 0
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  month="$(date -u +%Y-%m)"
  host="${SUBSET_HOST_LABEL:-$(hostname -s 2>/dev/null || echo unknown)}"
  sid="${CLAUDE_CODE_SESSION_ID:-}"
  raw_file="$raw_dir/knowledge-search-fallback-${month}.jsonl"
  record="$(jq -nc \
    --arg ts "$ts" \
    --arg session_id "$sid" \
    --arg host "$host" \
    --arg backend "basic-memory-mcp" \
    --arg reason "$reason" \
    --arg detail "$detail" \
    --arg url "${KNOWLEDGE_SEARCH_BM_MCP_URL:-}" \
    --arg project "${KNOWLEDGE_SEARCH_BM_PROJECT:-}" \
    '{schema_version:"1", ts:$ts,
      session_id:(if $session_id=="" then null else $session_id end),
      host:$host, backend:$backend, reason:$reason, detail:$detail,
      url:$url, project:$project}' 2>/dev/null)" || return 0
  [ -n "$record" ] || return 0
  printf '%s\n' "$record" >> "$raw_file" 2>/dev/null || return 0
}

# THE operator-visible fallback signal. Called on every cold-fallback event but
# fires at most ONCE per session (marker-gated): emits the durable telemetry
# record AND a single "degraded —" stderr notice, then stays silent for the rest
# of the session. Fail-open throughout — always returns 0.
_ks_bm_mcp_fallback_signal() {
  local reason="$1" detail="$2" marker
  marker="$(_ks_bm_mcp_fallback_marker)"
  # Already signalled this session — stay silent (no per-query spam).
  [ -n "$marker" ] && [ -e "$marker" ] && return 0
  # Claim the marker FIRST so a re-entrant / looping caller de-dups even if the
  # telemetry write below is slow or fails.
  [ -n "$marker" ] && { : > "$marker" 2>/dev/null || true; }
  _ks_bm_mcp_emit_fallback_telemetry "$reason" "$detail" || true
  printf 'degraded — %s (warm bm-mcp search fell back to the cold CLI path; one-time-per-session notice, telemetry recorded for alerting)\n' "$detail" >&2
  return 0
}

# ── low-level MCP-over-HTTP helpers ───────────────────────────────────────
# streamable-http responses are SSE ("event: message\n data: {json}\n\n"); the
# single JSON-RPC reply for a request rides one `data:` line, extracted here.
#
# Opens a session: POST initialize, echo the Mcp-Session-Id response header
# (empty string + return 1 if the daemon is unreachable or gives no session).
_ks_bm_mcp_open_session() {
  local init hdrs sid
  init="$(jq -cn --arg p "$KNOWLEDGE_SEARCH_BM_MCP_PROTO" \
    '{jsonrpc:"2.0",id:1,method:"initialize",params:{protocolVersion:$p,capabilities:{},clientInfo:{name:"knowledge_search_mcp",version:"1"}}}')"
  hdrs="$(curl -s -o /dev/null -D - \
      --connect-timeout "$KNOWLEDGE_SEARCH_BM_MCP_CONNECT_TIMEOUT" \
      --max-time "$KNOWLEDGE_SEARCH_BM_MCP_MAX_TIME" \
      -H 'Content-Type: application/json' \
      -H 'Accept: application/json, text/event-stream' \
      -X POST --data "$init" "$KNOWLEDGE_SEARCH_BM_MCP_URL" 2>/dev/null)" || return 1
  sid="$(printf '%s' "$hdrs" | tr -d '\r' | awk -F': ' 'tolower($1)=="mcp-session-id"{print $2}')"
  [ -n "$sid" ] || return 1
  # Required by the MCP lifecycle before further requests (fire-and-forget).
  curl -s -o /dev/null \
    --connect-timeout "$KNOWLEDGE_SEARCH_BM_MCP_CONNECT_TIMEOUT" \
    --max-time "$KNOWLEDGE_SEARCH_BM_MCP_MAX_TIME" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -H "Mcp-Session-Id: $sid" -H "MCP-Protocol-Version: $KNOWLEDGE_SEARCH_BM_MCP_PROTO" \
    -X POST --data '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
    "$KNOWLEDGE_SEARCH_BM_MCP_URL" 2>/dev/null || true
  printf '%s' "$sid"
}

# Terminates an MCP session: DELETE /mcp carrying Mcp-Session-Id — the MCP
# streamable-HTTP teardown. WITHOUT this, the daemon retains per-session server
# state forever (measured ~1-3.6MB per search, 9.2GB after 48h — foundation#1710), so
# every session this file opens MUST reach a close on every exit path,
# including error/timeout paths. Fail-open: a failed DELETE must never turn a
# successful search into an error — always returns 0.
_ks_bm_mcp_close_session() {
  local sid="${1:-}"
  [ -n "$sid" ] || return 0
  curl -s -o /dev/null \
    --connect-timeout "$KNOWLEDGE_SEARCH_BM_MCP_CONNECT_TIMEOUT" \
    --max-time "$KNOWLEDGE_SEARCH_BM_MCP_MAX_TIME" \
    -H "Mcp-Session-Id: $sid" -H "MCP-Protocol-Version: $KNOWLEDGE_SEARCH_BM_MCP_PROTO" \
    -X DELETE "$KNOWLEDGE_SEARCH_BM_MCP_URL" >/dev/null 2>&1 || true
  return 0
}

# ── public backend interface (dispatched by knowledge_search.sh) ──────────

# available: warm daemon reachable OR the cold backend's tooling is present.
# Never worse than the cold backend — a down daemon still reports available
# when the cold path can run, because search will fail open to it.
# The probe session it opens is torn down immediately (foundation#1710): even a
# bare initialize costs the daemon ~50KB of retained state, and ks_search runs
# this probe on EVERY query (its read-log gate), so an unclosed probe leaks too.
#
# Argument passthrough (temperloop#1113): the cold gate now accepts `--quiet`
# (suppressing only its "skipped —" notice) AND lazily installs the pinned
# uv tool when it is absent, so this delegation must forward "$@" rather than
# swallow it — otherwise ks_search's own quiet read-log probe would print the
# cold notice through the warm backend. The daemon probe runs FIRST, so a
# healthy warm daemon never triggers the cold path's install.
_ks_search_backend_basic_memory_mcp_available() {
  local sid
  if sid="$(_ks_bm_mcp_open_session 2>/dev/null)" && [ -n "$sid" ]; then
    _ks_bm_mcp_close_session "$sid"
    return 0
  fi
  _ks_search_backend_basic_memory_available "$@"
}

# search <query> [--limit N] -> JSONL on stdout, SAME shape as the cold
# backend: one {doc_id,title,score,snippet} object per line.
_ks_search_backend_basic_memory_mcp_search() {
  local query="$1"; shift
  local limit=10
  # Allowlist, not a silent discard — kept in lockstep with the cold backend's
  # own loop (temperloop#418). `--partition` is not accepted here either: the
  # partition scope is enforced once, in ks_search, above both backends, so
  # neither the warm daemon path nor its cold fail-open fallback can widen it.
  while [ $# -gt 0 ]; do
    case "$1" in
      --limit) limit="${2:?knowledge_search: --limit requires a value}"; shift 2 ;;
      *)
        printf 'knowledge_search: basic-memory-mcp search: unrecognised argument "%s" (accepted: --limit)\n' "$1" >&2
        return 2
        ;;
    esac
  done

  # Post-fetch re-rank (#1446): fetch a DEEPER candidate set than the caller
  # asked for, then re-rank down to --limit. Kept in lockstep with the cold
  # path's identical depth computation — the two surfaces must fetch the same
  # depth and apply the same re-rank, or warm and cold silently diverge in
  # RANKING the way they were already prevented from diverging in search MODE
  # (see the search_type:"hybrid" note below).
  local depth="$limit"
  if [ "${KNOWLEDGE_SEARCH_RERANK:-1}" = "1" ] \
     && [ "${KNOWLEDGE_SEARCH_RERANK_DEPTH:-20}" -gt "$limit" ]; then
    depth="${KNOWLEDGE_SEARCH_RERANK_DEPTH:-20}"
  fi

  local sid call raw results
  if sid="$(_ks_bm_mcp_open_session)" && [ -n "$sid" ]; then
    # Daemon reachable. search_type:"hybrid" is passed EXPLICITLY to match the
    # cold path's `--hybrid`: bm's default is only a *dynamic* hybrid (and only
    # when the daemon's config has semantic search enabled), so pinning it keeps
    # warm and cold from silently diverging to text-only on a differently-
    # configured daemon — the fail-open safety argument is latency-only, not a
    # change in search mode.
    call="$(jq -cn --arg q "$query" --argjson lim "$depth" --arg proj "$KNOWLEDGE_SEARCH_BM_PROJECT" \
      '{jsonrpc:"2.0",id:2,method:"tools/call",params:{name:"search_notes",arguments:{query:$q,output_format:"json",search_type:"hybrid",page_size:$lim,project:$proj}}}')"
    raw="$(curl -s \
        --connect-timeout "$KNOWLEDGE_SEARCH_BM_MCP_CONNECT_TIMEOUT" \
        --max-time "$KNOWLEDGE_SEARCH_BM_MCP_MAX_TIME" \
        -H 'Content-Type: application/json' \
        -H 'Accept: application/json, text/event-stream' \
        -H "Mcp-Session-Id: $sid" -H "MCP-Protocol-Version: $KNOWLEDGE_SEARCH_BM_MCP_PROTO" \
        -X POST --data "$call" "$KNOWLEDGE_SEARCH_BM_MCP_URL" 2>/dev/null)" || true
    # The session's work is DONE the moment the tools/call round-trip returns
    # (or times out — the `|| true` above keeps a curl failure from skipping
    # this line under a `set -e` caller). Terminate it HERE, before parsing, so
    # every subsequent path — parse success, tool error, unparseable body, and
    # the degraded-result fallback — runs after the teardown: no exit path
    # leaks a session (foundation#1710).
    _ks_bm_mcp_close_session "$sid"
    # Extract the SSE data line, verify a non-error tool result, then reshape via
    # the shared _ks_bm_reshape_results (one owner of the JSONL contract, so warm
    # and cold can't drift apart).
    results="$(printf '%s' "$raw" | sed -n 's/^data: //p' \
      | jq -e 'if (.result.isError == true) then error("tool error")
               else (.result.content[0].text | fromjson) end' 2>/dev/null)" || true
    if [ -n "$results" ]; then
      # Same reshape AND same re-rank as the cold path — both stages have ONE
      # owner in knowledge_search.sh so a change can't land on one surface only.
      printf '%s' "$results" | _ks_bm_reshape_results | _ks_bm_rerank "$query" "$limit"
      return 0
    fi
    # Reachable but the tool returned an error / empty / unparseable body. The
    # most common cause is a PROJECT MISMATCH — the daemon serves a single
    # launch-time --project, but this client sent KNOWLEDGE_SEARCH_BM_PROJECT.
    # Name it so a misconfig is visible, never misread as "daemon down".
    _ks_bm_mcp_fallback_signal "degraded-result" \
      "bm mcp daemon reached but returned no usable result (check its --project matches KNOWLEDGE_SEARCH_BM_PROJECT='$KNOWLEDGE_SEARCH_BM_PROJECT')"
  else
    _ks_bm_mcp_fallback_signal "unreachable" \
      "bm mcp daemon unreachable at $KNOWLEDGE_SEARCH_BM_MCP_URL"
  fi
  _ks_search_backend_basic_memory_search "$query" --limit "$limit"
}

# reindex [--full] -> the daemon serves the same on-disk corpus; reindexing is
# an explicit maintenance op (not latency-sensitive), so delegate to the cold
# CLI reindex rather than duplicate it over MCP.
_ks_search_backend_basic_memory_mcp_reindex() {
  _ks_search_backend_basic_memory_reindex "$@"
}
