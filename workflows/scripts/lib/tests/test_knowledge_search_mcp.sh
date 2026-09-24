#!/usr/bin/env bash
#
# Tests for workflows/scripts/lib/knowledge_search_mcp.sh — the optional WARM
# search backend "basic-memory-mcp".
#
# Hermetic: no daemon, no network, no uvx. The happy path (a live daemon
# answering ~0.2s) is proven by an adopter's live measurement; here we lock the
# CI-checkable invariants that fail SILENTLY otherwise:
#   1. the lib registers the three backend ops via the command -v seam,
#   2. the backend is selectable by KNOWLEDGE_SEARCH_BACKEND,
#   3. FAIL-OPEN: an unreachable daemon delegates to the cold basic-memory
#      backend (search), and available/reindex delegate too — proven by
#      stubbing the cold functions, so no real bm subprocess is needed.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$HERE/.." && pwd)"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
command -v jq   >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }
command -v curl >/dev/null 2>&1 || { echo "SKIP: curl not installed"; exit 0; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/ks-search-mcp-test-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/store" "$TMP/raw" "$TMP/state"

# Point the backend at a definitely-closed port so the warm path fails FAST
# (connection refused) into the fail-open branch — no daemon required.
export KNOWLEDGE_STORE_ROOT="$TMP/store"
# Isolate the read-log (temperloop#229) under the throwaway tmpdir too — any
# ks_search call below goes through ks__read_log_emit; without this override
# it would default to the real machine's $XDG_STATE_HOME/foundation/
# knowledge-reads.log.
export KNOWLEDGE_READ_LOG="$TMP/knowledge-reads.log"
export KNOWLEDGE_SEARCH_BM_MCP_URL="http://127.0.0.1:1/mcp"
export KNOWLEDGE_SEARCH_BM_MCP_CONNECT_TIMEOUT="1"
export KNOWLEDGE_SEARCH_BM_PROJECT="test-project"
# Keep the fallback telemetry + de-dup marker HERMETIC (temperloop#54): land the
# raw-lake record and the session marker inside TMP, never the real repo tree /
# system TMPDIR.
export KS_SEARCH_FALLBACK_RAW_DIR="$TMP/raw"
export KS_SEARCH_FALLBACK_STATE_DIR="$TMP/state"

# shellcheck source=/dev/null
source "$LIB_DIR/knowledge_store.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/knowledge_search.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/knowledge_search_mcp.sh"

# ── 1. the three backend ops are registered ────────────────────────────────
for op in search available reindex; do
  command -v "_ks_search_backend_basic_memory_mcp_$op" >/dev/null \
    || fail "backend op '$op' not registered (missing _ks_search_backend_basic_memory_mcp_$op)"
done
echo "PASS: 1 backend registers search/available/reindex via the command -v seam"

# ── 2. selectable by KNOWLEDGE_SEARCH_BACKEND ──────────────────────────────
export KNOWLEDGE_SEARCH_BACKEND="basic-memory-mcp"
got="$(ks_search__backend_fn search)"
[ "$got" = "_ks_search_backend_basic_memory_mcp_search" ] \
  || fail "dispatch resolved to '$got', expected _ks_search_backend_basic_memory_mcp_search"
echo "PASS: 2 KNOWLEDGE_SEARCH_BACKEND=basic-memory-mcp dispatches to the warm backend"

# ── 3. FAIL-OPEN: unreachable daemon delegates to the cold backend ─────────
# Stub the cold functions the warm backend falls back to, so we assert
# delegation without a real bm subprocess.
_ks_search_backend_basic_memory_search()   { echo "COLD_SEARCH_MARKER limit=$3"; }
_ks_search_backend_basic_memory_available() { return 7; }
_ks_search_backend_basic_memory_reindex()   { echo "COLD_REINDEX_MARKER args=$*"; }

# 3a. search: prints the "degraded —" notice AND the cold marker.
err="$(_ks_search_backend_basic_memory_mcp_search "some query" --limit 5 2>"$TMP/err.txt" )"
notice="$(cat "$TMP/err.txt")"
case "$notice" in *"degraded —"*) : ;; *) fail "expected 'degraded —' fail-open notice, got: [$notice]" ;; esac
case "$err" in *"COLD_SEARCH_MARKER limit=5"*) : ;; *) fail "search did not delegate to cold backend (with --limit), got: [$err]" ;; esac
echo "PASS: 3a search fail-open: notice on stderr + delegates to cold path (limit preserved)"

# 3d. DURABLE SIGNAL: the fallback emitted exactly one raw-lake telemetry record
# — the surface that survives a swallowed stderr (temperloop#54).
month="$(date -u +%Y-%m)"
tfile="$TMP/raw/knowledge-search-fallback-${month}.jsonl"
[ -f "$tfile" ] || fail "no fallback telemetry record written to $tfile"
n="$(wc -l < "$tfile" | tr -d ' ')"
[ "$n" = "1" ] || fail "expected exactly 1 fallback telemetry record, got $n"
jq -e '.schema_version=="1" and .backend=="basic-memory-mcp" and .reason=="unreachable"' \
  < "$tfile" >/dev/null || fail "telemetry record shape/reason invalid: $(cat "$tfile")"
echo "PASS: 3d fallback emits one raw-lake telemetry record (reason=unreachable, schema_version=1)"

# 3e. DE-DUPED one-time-per-session: a SECOND fallback in the same session emits
# NEITHER a second 'degraded —' stderr line NOR a second telemetry record — but
# still fails open to the cold path.
err2="$(_ks_search_backend_basic_memory_mcp_search "another query" --limit 3 2>"$TMP/err2.txt")"
notice2="$(cat "$TMP/err2.txt")"
case "$notice2" in *"degraded —"*) fail "second fallback re-emitted the stderr notice (not de-duped): [$notice2]" ;; esac
case "$err2" in *"COLD_SEARCH_MARKER limit=3"*) : ;; *) fail "second fallback did not still delegate to cold path: [$err2]" ;; esac
n2="$(wc -l < "$tfile" | tr -d ' ')"
[ "$n2" = "1" ] || fail "second fallback wrote another telemetry record (expected still 1, got $n2)"
echo "PASS: 3e fallback signal de-duped one-time-per-session (no notice/telemetry spam; still fails open)"

# 3b. available: unreachable daemon returns the cold backend's verdict (7).
rc=0; _ks_search_backend_basic_memory_mcp_available || rc=$?
[ "$rc" = "7" ] || fail "available did not delegate to cold backend (expected rc=7, got $rc)"
echo "PASS: 3b available fail-open: delegates to cold availability verdict"

# 3c. reindex: delegates to cold reindex, passing args through.
out="$(_ks_search_backend_basic_memory_mcp_reindex --full)"
case "$out" in *"COLD_REINDEX_MARKER args=--full"*) : ;; *) fail "reindex did not delegate with args, got: [$out]" ;; esac
echo "PASS: 3c reindex delegates to cold reindex (args passed through)"

# ── 4. BOTH SURFACES CARRY THE RE-RANK (temperloop#1446) ──────────────────
# The warm happy path needs a live daemon, so it is out of this hermetic
# suite's reach (see the header). But the failure this guards against is not a
# runtime bug — it is a MAINTENANCE drift: someone changes the ranking on the
# cold path and forgets the warm one, and the two backends silently disagree
# about ordering the way they were already prevented from disagreeing about
# search MODE. That is a STRUCTURAL property of the source, so assert it
# structurally (same idiom as test_knowledge_search_agpl_boundary.sh).
MCP_LIB="$LIB_DIR/knowledge_search_mcp.sh"

grep -q '_ks_bm_reshape_results | _ks_bm_rerank "\$query" "\$limit"' "$MCP_LIB" \
  || fail "4: the warm MCP search path must pipe results through _ks_bm_rerank, exactly as the cold path does"
echo "PASS: 4a warm MCP search path applies the shared post-fetch re-rank"

# The warm path must request the SAME fetch depth as the cold path, or the
# re-rank operates on a shallower candidate set over there and the whole
# fetch-deeper premise silently degrades on production's fastest surface.
grep -q 'KNOWLEDGE_SEARCH_RERANK_DEPTH' "$MCP_LIB" \
  || fail "4: the warm MCP search path must compute fetch depth from KNOWLEDGE_SEARCH_RERANK_DEPTH"
grep -q -- '--argjson lim "\$depth"' "$MCP_LIB" \
  || fail "4: the warm MCP search path must send the computed depth as page_size, not the caller's limit"
echo "PASS: 4b warm MCP search path fetches the same re-rank depth as the cold path"

# ── 5. SESSION TEARDOWN (foundation#1710) ─────────────────────────────────
# Every MCP session the backend opens must be terminated with a DELETE /mcp
# carrying its Mcp-Session-Id, on EVERY exit path — the daemon retains
# ~1-3.6MB per unterminated session (9.2GB after 48h). Hermetic: shadow the
# curl binary with a shell function that plays the daemon and logs every
# request, so we can assert exactly which sessions were opened and closed.
CURL_LOG="$TMP/curl.log"
curl() {
  local i method="GET" data="" dump=0 sid=""
  local args=("$@")
  for ((i = 0; i < ${#args[@]}; i++)); do
    case "${args[$i]}" in
      -X)     method="${args[$((i + 1))]}" ;;
      --data) data="${args[$((i + 1))]}" ;;
      -D)     dump=1 ;;
      -H)     case "${args[$((i + 1))]}" in
                "Mcp-Session-Id: "*) sid="${args[$((i + 1))]#Mcp-Session-Id: }" ;;
              esac ;;
    esac
  done
  if [ "$method" = "DELETE" ]; then
    printf 'DELETE %s\n' "$sid" >> "$CURL_LOG"
    return "${CURL_STUB_DELETE_RC:-0}"
  fi
  case "$data" in
    *'"initialize"'*)
      printf 'INIT\n' >> "$CURL_LOG"
      [ "$dump" = 1 ] && printf 'HTTP/1.1 200 OK\r\nmcp-session-id: stub-sid-42\r\n\r\n'
      return 0 ;;
    *'notifications/initialized'*)
      printf 'INITIALIZED %s\n' "$sid" >> "$CURL_LOG"
      return 0 ;;
    *'tools/call'*)
      printf 'CALL %s\n' "$sid" >> "$CURL_LOG"
      if [ "${CURL_STUB_CALL_MODE:-ok}" = "ok" ]; then
        printf 'event: message\ndata: %s\n\n' \
          "$(jq -cn '{result:{isError:false,content:[{text:({results:[{file_path:"notes/a.md",title:"alpha note",score:0.9,matched_chunk:"alpha snippet"}]}|tojson)}]}}')"
      fi
      return 0 ;;
  esac
  return 0
}

# 5a. SUCCESS path: the search session is opened once and DELETEd once, with
# the daemon-issued session id — and results still come back.
: > "$CURL_LOG"
out="$(_ks_search_backend_basic_memory_mcp_search "alpha" --limit 5)"
case "$out" in *'notes/a.md'*) : ;; *) fail "5a: warm success path returned no results through the stub daemon: [$out]" ;; esac
[ "$(grep -c '^DELETE ' "$CURL_LOG")" = "1" ] \
  || fail "5a: expected exactly 1 DELETE on the success path, log: [$(cat "$CURL_LOG")]"
grep -q '^DELETE stub-sid-42$' "$CURL_LOG" \
  || fail "5a: DELETE did not carry the daemon-issued Mcp-Session-Id, log: [$(cat "$CURL_LOG")]"
echo "PASS: 5a success path terminates its session (one DELETE, correct Mcp-Session-Id)"

# 5b. ERROR path: daemon reachable but the tool returns an unusable body — the
# search falls back to the cold path AND still tears the session down (a
# failed query must not leak a session either).
: > "$CURL_LOG"
export CURL_STUB_CALL_MODE="empty"
out="$(_ks_search_backend_basic_memory_mcp_search "alpha" --limit 5 2>/dev/null)"
unset CURL_STUB_CALL_MODE
case "$out" in *"COLD_SEARCH_MARKER"*) : ;; *) fail "5b: degraded-result path did not fall back to cold, got: [$out]" ;; esac
grep -q '^DELETE stub-sid-42$' "$CURL_LOG" \
  || fail "5b: error/fallback path leaked its session (no DELETE), log: [$(cat "$CURL_LOG")]"
echo "PASS: 5b error path still terminates the session before falling back cold"

# 5c. FAIL-OPEN teardown: a failing DELETE must never turn a successful search
# into an error.
: > "$CURL_LOG"
export CURL_STUB_DELETE_RC=7
rc=0; out="$(_ks_search_backend_basic_memory_mcp_search "alpha" --limit 5)" || rc=$?
unset CURL_STUB_DELETE_RC
[ "$rc" = "0" ] || fail "5c: a failed DELETE broke a successful search (rc=$rc)"
case "$out" in *'notes/a.md'*) : ;; *) fail "5c: a failed DELETE dropped the results: [$out]" ;; esac
echo "PASS: 5c fail-open: a failed DELETE never breaks a successful search"

# 5d. AVAILABILITY probe: ks_search runs the available op on every query (its
# read-log gate), and even a bare initialize costs the daemon ~50KB — so the
# probe session must be torn down too.
: > "$CURL_LOG"
_ks_search_backend_basic_memory_mcp_available \
  || fail "5d: available returned non-zero against a reachable stub daemon"
grep -q '^DELETE stub-sid-42$' "$CURL_LOG" \
  || fail "5d: availability probe leaked its bare-initialize session, log: [$(cat "$CURL_LOG")]"
echo "PASS: 5d availability probe terminates its bare-initialize session"

unset -f curl

echo "ALL PASS: knowledge_search_mcp.sh (registration + selection + fail-open + session teardown, hermetic)"
