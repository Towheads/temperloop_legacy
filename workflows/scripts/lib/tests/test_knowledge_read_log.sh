#!/usr/bin/env bash
#
# Tests for the read-log telemetry seam (temperloop#229, Epic #226
# "script-plane read telemetry"): ks__read_log_emit and its two call sites —
# knowledge_store.sh's ks__dispatch (every ks_read/ks_write/ks_append/
# ks_list, for the plain-files backend) and knowledge_search.sh's ks_search
# entrypoint. Zero network: the ks_search case drives a FAKE `uv` binary on
# PATH, same fixture pattern as test_knowledge_search.sh. All state
# (KNOWLEDGE_STORE_ROOT, KNOWLEDGE_READ_LOG, KNOWLEDGE_SEARCH_BM_HOME) lives
# under a throwaway tmpdir; never touches a real vault, XDG dir, or the
# machine's real $HOME.
#
# Covers: log-path setting default + override, one normalized line per
# ks_write/ks_read/ks_append/ks_list call (plain-files backend), one line
# per ks_search call (op=search, query as the doc field), the
# " · "-joined 5-field line shape, session-id present vs. "-" fallback when
# CLAUDE_CODE_SESSION_ID is unset, newline/tab sanitization of the logged
# doc-path-or-query field, and fail-open behavior (an unwritable log dir
# WARNs on stderr but never fails the wrapped ks_* call).
#
# Also covers (foundation#1449, epic foundation#1443 "obs-outcome-emit"): the
# six additive OUTCOME fields ks_search appends after the query field —
# result_count, top_score, abstained, rg_fallback, mode, wall_ms — across a
# real hit (rerank off and on), a genuine no-match answered by the
# score-0 ripgrep lexical fallback, a genuine no-match with no fallback hit
# either, and a backend error (mode=error:<rc>, still exactly one logged
# line — the pre-#1449 count semantics are unchanged).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$HERE/.." && pwd)"
STORE_LIB="$LIB_DIR/knowledge_store.sh"
SEARCH_LIB="$LIB_DIR/knowledge_search.sh"
MCP_LIB="$LIB_DIR/knowledge_search_mcp.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/ks-read-log-test-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# --- 1. default log path honors XDG_STATE_HOME (no explicit override) -------
(
  unset KNOWLEDGE_READ_LOG
  export XDG_STATE_HOME="$TMP/xdg-state"
  export KNOWLEDGE_STORE_ROOT="$TMP/store-1"
  # shellcheck source=/dev/null
  source "$STORE_LIB"
  got="$(_ks_read_log_path)"
  want="$TMP/xdg-state/foundation/knowledge-reads.log"
  [ "$got" = "$want" ] || fail "1: default log path should honor XDG_STATE_HOME (got $got want $want)"
  echo "PASS: 1 default read-log path resolves under \$XDG_STATE_HOME/foundation/knowledge-reads.log"
)

# --- 2. KNOWLEDGE_READ_LOG is the ONE override; XDG_STATE_HOME is ignored when set --
(
  export XDG_STATE_HOME="$TMP/xdg-state-ignored"
  export KNOWLEDGE_READ_LOG="$TMP/explicit-read.log"
  export KNOWLEDGE_STORE_ROOT="$TMP/store-2"
  # shellcheck source=/dev/null
  source "$STORE_LIB"
  got="$(_ks_read_log_path)"
  [ "$got" = "$TMP/explicit-read.log" ] || fail "2: explicit KNOWLEDGE_READ_LOG must win (got $got)"
  echo "PASS: 2 KNOWLEDGE_READ_LOG overrides the default (single config setting)"
)

# From here on, all cases share one isolated store root + read log.
ROOT="$TMP/store"
LOG="$TMP/knowledge-reads.log"
export KNOWLEDGE_STORE_ROOT="$ROOT"
export KNOWLEDGE_READ_LOG="$LOG"
unset CLAUDE_CODE_SESSION_ID || true
# shellcheck source=/dev/null
source "$STORE_LIB"

# --- 3. ks_write appends one normalized line, session-id falls back to "-" ---
printf 'hello world\n' | ks_write "Decisions/foo" || fail "3: write should succeed"
[ -f "$LOG" ] || fail "3: read-log file should exist after the first dispatched call"
n="$(wc -l <"$LOG" | tr -d ' ')"
[ "$n" -eq 1 ] || fail "3: expected exactly 1 read-log line after one write (got $n)"
line="$(cat "$LOG")"
case "$line" in
  *" · - · script · write · Decisions/foo"*) : ;;
  *) fail "3: read-log line missing expected fields (got: $line)" ;;
esac
# timestamp field: first token, must look like an ISO-8601 UTC stamp
ts="${line%% *}"
case "$ts" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) : ;;
  *) fail "3: timestamp field does not look like YYYY-MM-DDTHH:MM:SSZ (got: $ts)" ;;
esac
echo "PASS: 3 ks_write appends one normalized line; session-id falls back to '-' when unset"

# --- 4. ks_read appends its own line (op=read), doc-id preserved -------------
ks_read "Decisions/foo" >/dev/null || fail "4: read should succeed"
n="$(wc -l <"$LOG" | tr -d ' ')"
[ "$n" -eq 2 ] || fail "4: expected 2 read-log lines after a write + a read (got $n)"
line="$(sed -n '2p' "$LOG")"
case "$line" in
  *" · - · script · read · Decisions/foo"*) : ;;
  *) fail "4: read-log line for ks_read missing expected fields (got: $line)" ;;
esac
echo "PASS: 4 ks_read appends its own read-log line (op=read)"

# --- 5. ks_append and ks_list each append their own line (plain-files backend) --
printf 'line1\n' | ks_append "Scratch/log" || fail "5: append should succeed"
ks_list "Decisions" >/dev/null || fail "5: list should succeed"
n="$(wc -l <"$LOG" | tr -d ' ')"
[ "$n" -eq 4 ] || fail "5: expected 4 read-log lines after write+read+append+list (got $n)"
append_line="$(sed -n '3p' "$LOG")"
list_line="$(sed -n '4p' "$LOG")"
case "$append_line" in
  *" · - · script · append · Scratch/log"*) : ;;
  *) fail "5: read-log line for ks_append missing expected fields (got: $append_line)" ;;
esac
case "$list_line" in
  *" · - · script · list · Decisions"*) : ;;
  *) fail "5: read-log line for ks_list missing expected fields (got: $list_line)" ;;
esac
echo "PASS: 5 ks_append and ks_list each append their own read-log line (op=append / op=list), plain-files backend"

# --- 6. CLAUDE_CODE_SESSION_ID, when set, is carried verbatim ----------------
(
  export CLAUDE_CODE_SESSION_ID="sess-abc123"
  printf 'v2\n' | ks_write "Decisions/foo"
)
n="$(wc -l <"$LOG" | tr -d ' ')"
[ "$n" -eq 5 ] || fail "6: expected 5 read-log lines after the session-id-set write (got $n)"
line="$(sed -n '5p' "$LOG")"
case "$line" in
  *" · sess-abc123 · script · write · Decisions/foo"*) : ;;
  *) fail "6: read-log line should carry CLAUDE_CODE_SESSION_ID verbatim (got: $line)" ;;
esac
echo "PASS: 6 CLAUDE_CODE_SESSION_ID, when set, is carried verbatim into the session-id field"

# --- 7. a logging failure never breaks the dispatch (fail-open) -------------
(
  # Point KNOWLEDGE_READ_LOG at a path whose PARENT is a plain file, not a
  # directory, so mkdir -p for the log dir is guaranteed to fail.
  blocker="$TMP/blocker-file"
  : >"$blocker"
  export KNOWLEDGE_READ_LOG="$blocker/nested/knowledge-reads.log"
  out_err="$TMP/write-stderr.txt"
  printf 'still lands\n' | ks_write "Decisions/failopen" 2>"$out_err"
  rc=$?
  [ "$rc" -eq 0 ] || fail "7: ks_write must still succeed even when the read-log dir is unwritable (rc=$rc)"
  grep -q "WARN read-log dir unavailable" "$out_err" \
    || fail "7: expected a WARN notice on stderr when the read-log dir can't be created (got: $(cat "$out_err"))"
)
got="$(ks_read "Decisions/failopen")" || fail "7b: the document itself must have been written despite the read-log failure"
[ "$got" = "still lands" ] || fail "7b: content mismatch after fail-open write (got: $got)"
echo "PASS: 7 a read-log write failure WARNs on stderr and never breaks the wrapped ks_write/ks_read call"

# --- 8. doc-path-or-query is sanitized to a single line (newlines/tabs -> spaces) --
printf 'x\n' | ks_write "$(printf 'weird\tid')" >/dev/null 2>&1 || true
n_before="$(wc -l <"$LOG" | tr -d ' ')"
line="$(tail -n1 "$LOG")"
n_after="$n_before"
[ "$n_after" -ge 1 ] || fail "8: expected at least one read-log line after the tab-containing write attempt"
case "$line" in
  *$'\t'*) fail "8: read-log line must not contain a raw tab (got: $line)" ;;
  *) : ;;
esac
echo "PASS: 8 the doc-path-or-query field is sanitized (no raw tabs/newlines survive into the log line)"

# --- 9. knowledge_search.sh's ks_search entrypoint logs op=search, same format --
SEARCH_TMP="$TMP/search"
mkdir -p "$SEARCH_TMP/store" "$SEARCH_TMP/bm-home" "$SEARCH_TMP/bin"
SEARCH_LOG="$SEARCH_TMP/knowledge-reads.log"
# ── fake `uv` + installed basic-memory entry point (temperloop#1113) ────────
# Since #1113 the adapter installs the pinned basic-memory as a uv tool and
# invokes the installed entry point by absolute path — nothing named
# `basic-memory` is ever resolved through PATH. So these cases put a fake `uv`
# on PATH instead, and it materialises the canned CLI stub below into
# $UV_TOOL_BIN_DIR exactly as a real `uv tool install` would. No network, no
# real install.
#
# _mk_fake_uv <bin-dir> <template-path>
_mk_fake_uv() {
  local bin_dir="$1" template="$2"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/uv" <<EOF
#!/usr/bin/env bash
set -euo pipefail
[ "\${1:-}" = "tool" ] && [ "\${2:-}" = "install" ] || { echo "fake-uv: unsupported: \$*" >&2; exit 9; }
: "\${UV_TOOL_BIN_DIR:?fake-uv: UV_TOOL_BIN_DIR must be pinned by the adapter}"
mkdir -p "\$UV_TOOL_BIN_DIR"
cp "$template" "\$UV_TOOL_BIN_DIR/basic-memory"
chmod +x "\$UV_TOOL_BIN_DIR/basic-memory"
exit 0
EOF
  chmod +x "$bin_dir/uv"
}

cat > "$SEARCH_TMP/basic-memory.template" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
case "$1 $2 $3" in
  "project add "*) exit 0 ;;
  "tool search-notes "*)
    printf '{"results":[]}\n'
    exit 0
    ;;
esac
exit 9
FAKE
_mk_fake_uv "$SEARCH_TMP/bin" "$SEARCH_TMP/basic-memory.template"

(
  export KNOWLEDGE_STORE_ROOT="$SEARCH_TMP/store"
  export KNOWLEDGE_SEARCH_BM_HOME="$SEARCH_TMP/bm-home"
  export KNOWLEDGE_SEARCH_BM_PROJECT="read-log-test-project"
  export KNOWLEDGE_READ_LOG="$SEARCH_LOG"
  export PATH="$SEARCH_TMP/bin:$PATH"
  unset CLAUDE_CODE_SESSION_ID || true
  # shellcheck source=/dev/null
  source "$STORE_LIB"
  # shellcheck source=/dev/null
  source "$SEARCH_LIB"
  ks_search "widget install guide" >/dev/null
)
[ -f "$SEARCH_LOG" ] || fail "9: ks_search should have created the read-log"
n="$(wc -l <"$SEARCH_LOG" | tr -d ' ')"
[ "$n" -eq 1 ] || fail "9: expected exactly 1 read-log line for one ks_search call (got $n)"
line="$(cat "$SEARCH_LOG")"
case "$line" in
  *" · - · script · search · widget install guide"*) : ;;
  *) fail "9: ks_search read-log line missing expected fields (got: $line)" ;;
esac
echo "PASS: 9 knowledge_search.sh's ks_search entrypoint logs op=search with the query, same line format"

# --- 10. an empty ks_search query (usage error) does NOT log ------------------
(
  export KNOWLEDGE_STORE_ROOT="$SEARCH_TMP/store"
  export KNOWLEDGE_READ_LOG="$SEARCH_LOG"
  export PATH="$SEARCH_TMP/bin:$PATH"
  # shellcheck source=/dev/null
  source "$STORE_LIB"
  # shellcheck source=/dev/null
  source "$SEARCH_LIB"
  set +e
  ks_search "" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || echo "10: WARN expected exit 2 for empty query (got $rc)" >&2
)
n="$(wc -l <"$SEARCH_LOG" | tr -d ' ')"
[ "$n" -eq 1 ] || fail "10: an empty-query usage error must not append a read-log line (line count changed: $n)"
echo "PASS: 10 an empty ks_search query (usage error) does not append a read-log line"

# --- 11-15. additive OUTCOME fields (foundation#1449, epic foundation#1443) --
# ks__read_log_emit now accepts optional trailing fields, and ks_search
# appends six of them after the query field: result_count, top_score,
# abstained, rg_fallback, mode, wall_ms. A richer fake basic-memory stub
# (FAKE_BM_MODE-selectable, same idiom as test_knowledge_search.sh) drives a
# real hit, a genuine no-match with a literal rg-fallback hit, a genuine
# no-match with no rg hit either, and a backend error.
OUT_TMP="$TMP/outcome"
mkdir -p "$OUT_TMP/store" "$OUT_TMP/bm-home" "$OUT_TMP/bin"
OUT_LOG="$OUT_TMP/knowledge-reads.log"
cat > "$OUT_TMP/basic-memory.template" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
sub="${1:-}"; shift || true
case "$sub" in
  project) exit 0 ;;
  tool)
    if [ "${1:-}" = "search-notes" ]; then
      case "${FAKE_BM_MODE:-hit}" in
        hit)
          echo '{"results":[{"title":"Foo","score":1.23,"matched_chunk":"c1","file_path":"Decisions/foo.md"},{"title":"Bar","score":0.9,"matched_chunk":"c2","file_path":"Decisions/bar.md"}]}'
          exit 0
          ;;
        empty)
          echo '{"results":[]}'
          exit 0
          ;;
        error)
          echo "fake-bm: simulated backend crash" >&2
          exit 1
          ;;
        low_conf)
          # Both candidates fail the abstention floor's DEFAULT thresholds
          # (score < 0.72; titles share no query terms so L == 0 < 0.10) --
          # foundation#1450 outcome-field wiring (cases 17-18 below).
          echo '{"results":[{"title":"unrelated thing","score":0.65,"matched_chunk":"c1","file_path":"Decisions/unrelated-thing.md"},{"title":"another unrelated","score":0.60,"matched_chunk":"c2","file_path":"Decisions/another-unrelated.md"}]}'
          exit 0
          ;;
      esac
    fi
    ;;
esac
exit 9
FAKE
_mk_fake_uv "$OUT_TMP/bin" "$OUT_TMP/basic-memory.template"

DOT="$(printf '\xc2\xb7')"
SEP=" ${DOT} "
field_n() { awk -v SEP="$SEP" -F"$SEP" -v n="$2" '{print $n}' <<<"$1"; }

# --- 11. a real hit populates result_count/top_score/mode; rg_fallback/abstained=0
(
  export KNOWLEDGE_STORE_ROOT="$OUT_TMP/store"
  export KNOWLEDGE_SEARCH_BM_HOME="$OUT_TMP/bm-home"
  export KNOWLEDGE_SEARCH_BM_PROJECT="outcome-test"
  export KNOWLEDGE_READ_LOG="$OUT_LOG"
  export PATH="$OUT_TMP/bin:$PATH"
  export FAKE_BM_MODE="hit"
  export KNOWLEDGE_SEARCH_RERANK=0
  unset CLAUDE_CODE_SESSION_ID || true
  # shellcheck source=/dev/null
  source "$STORE_LIB"
  # shellcheck source=/dev/null
  source "$SEARCH_LIB"
  ks_search "widget install guide" >/dev/null
)
line="$(tail -n1 "$OUT_LOG")"
[ "$(field_n "$line" 6)" = "2" ] || fail "11: expected result_count=2 (got: $(field_n "$line" 6)) — line: $line"
[ "$(field_n "$line" 7)" = "1.23" ] || fail "11: expected top_score=1.23 with rerank off (got: $(field_n "$line" 7))"
[ "$(field_n "$line" 8)" = "0" ] || fail "11: expected abstained=0 (got: $(field_n "$line" 8))"
[ "$(field_n "$line" 9)" = "0" ] || fail "11: expected rg_fallback=0 for a real hit (got: $(field_n "$line" 9))"
[ "$(field_n "$line" 10)" = "hybrid" ] || fail "11: expected mode=hybrid with rerank off (got: $(field_n "$line" 10))"
wall="$(field_n "$line" 11)"
case "$wall" in ''|*[!0-9]*) fail "11: wall_ms should be a non-negative integer (got: $wall)" ;; esac
echo "PASS: 11 a real hit's read-log line carries result_count/top_score/mode/rg_fallback/abstained/wall_ms"

# --- 12. mode reflects rerank when enabled (default) -------------------------
(
  export KNOWLEDGE_STORE_ROOT="$OUT_TMP/store"
  export KNOWLEDGE_SEARCH_BM_HOME="$OUT_TMP/bm-home"
  export KNOWLEDGE_SEARCH_BM_PROJECT="outcome-test"
  export KNOWLEDGE_READ_LOG="$OUT_LOG"
  export PATH="$OUT_TMP/bin:$PATH"
  export FAKE_BM_MODE="hit"
  unset KNOWLEDGE_SEARCH_RERANK || true
  unset CLAUDE_CODE_SESSION_ID || true
  # shellcheck source=/dev/null
  source "$STORE_LIB"
  # shellcheck source=/dev/null
  source "$SEARCH_LIB"
  ks_search "widget install guide" >/dev/null
)
line="$(tail -n1 "$OUT_LOG")"
[ "$(field_n "$line" 10)" = "hybrid+rerank" ] || fail "12: expected mode=hybrid+rerank with default rerank on (got: $(field_n "$line" 10))"
echo "PASS: 12 mode is 'hybrid+rerank' when KNOWLEDGE_SEARCH_RERANK is on (the default)"

# --- 13. a genuine no-match WITH a literal rg-fallback hit --------------------
# Guarded on rg being installed (foundation#950's fallback is a no-op without
# it — fail-open), same guard test_knowledge_search.sh's own case 14 uses.
if command -v rg >/dev/null 2>&1; then
  mkdir -p "$OUT_TMP/store/Decisions"
  printf 'a note mentioning zzzzuniqueneedle right here\n' > "$OUT_TMP/store/Decisions/hit.md"
  (
    export KNOWLEDGE_STORE_ROOT="$OUT_TMP/store"
    export KNOWLEDGE_SEARCH_BM_HOME="$OUT_TMP/bm-home"
    export KNOWLEDGE_SEARCH_BM_PROJECT="outcome-test"
    export KNOWLEDGE_READ_LOG="$OUT_LOG"
    export PATH="$OUT_TMP/bin:$PATH"
    export FAKE_BM_MODE="empty"
    unset CLAUDE_CODE_SESSION_ID || true
    # shellcheck source=/dev/null
    source "$STORE_LIB"
    # shellcheck source=/dev/null
    source "$SEARCH_LIB"
    ks_search "zzzzuniqueneedle" >/dev/null
  )
  line="$(tail -n1 "$OUT_LOG")"
  [ "$(field_n "$line" 6)" = "1" ] || fail "13: expected result_count=1 from the rg-fallback hit (got: $(field_n "$line" 6))"
  [ "$(field_n "$line" 7)" = "0" ] || fail "13: expected top_score=0 (the rg-fallback sentinel) (got: $(field_n "$line" 7))"
  [ "$(field_n "$line" 9)" = "1" ] || fail "13: expected rg_fallback=1 (got: $(field_n "$line" 9))"
  [ "$(field_n "$line" 10)" = "rg-fallback" ] || fail "13: expected mode=rg-fallback (got: $(field_n "$line" 10))"
  echo "PASS: 13 a genuine no-match with a literal rg-fallback hit reports result_count=1/top_score=0/rg_fallback=1/mode=rg-fallback"
else
  echo "SKIP: 13 rg-fallback outcome-field assertion (ripgrep not installed)"
fi

# --- 14. a genuine no-match with NO rg hit either -----------------------------
(
  export KNOWLEDGE_STORE_ROOT="$OUT_TMP/store"
  export KNOWLEDGE_SEARCH_BM_HOME="$OUT_TMP/bm-home"
  export KNOWLEDGE_SEARCH_BM_PROJECT="outcome-test"
  export KNOWLEDGE_READ_LOG="$OUT_LOG"
  export PATH="$OUT_TMP/bin:$PATH"
  export FAKE_BM_MODE="empty"
  unset CLAUDE_CODE_SESSION_ID || true
  # shellcheck source=/dev/null
  source "$STORE_LIB"
  # shellcheck source=/dev/null
  source "$SEARCH_LIB"
  ks_search "no-such-term-anywhere-nopenope" >/dev/null
)
line="$(tail -n1 "$OUT_LOG")"
[ "$(field_n "$line" 6)" = "0" ] || fail "14: expected result_count=0 on a genuine no-match (got: $(field_n "$line" 6))"
[ "$(field_n "$line" 7)" = "-" ] || fail "14: expected top_score=- placeholder on a genuine no-match (got: $(field_n "$line" 7))"
[ "$(field_n "$line" 9)" = "0" ] || fail "14: expected rg_fallback=0 when rg finds nothing either (got: $(field_n "$line" 9))"
echo "PASS: 14 a genuine no-match (rg finds nothing either) reports result_count=0/top_score=-/rg_fallback=0"

# --- 15. a backend error still logs one line, with mode=error:<rc> -----------
(
  export KNOWLEDGE_STORE_ROOT="$OUT_TMP/store"
  export KNOWLEDGE_SEARCH_BM_HOME="$OUT_TMP/bm-home"
  export KNOWLEDGE_SEARCH_BM_PROJECT="outcome-test"
  export KNOWLEDGE_READ_LOG="$OUT_LOG"
  export PATH="$OUT_TMP/bin:$PATH"
  export FAKE_BM_MODE="error"
  unset CLAUDE_CODE_SESSION_ID || true
  set +e
  # shellcheck source=/dev/null
  source "$STORE_LIB"
  # shellcheck source=/dev/null
  source "$SEARCH_LIB"
  ks_search "widget install guide" >/dev/null 2>/dev/null
  rc=$?
  set -e
  [ "$rc" -eq 4 ] || echo "15: WARN expected ks_search to return 4 on a backend error (got $rc)" >&2
)
line="$(tail -n1 "$OUT_LOG")"
[ "$(field_n "$line" 6)" = "-" ] || fail "15: expected result_count=- placeholder on a backend error (got: $(field_n "$line" 6))"
[ "$(field_n "$line" 7)" = "-" ] || fail "15: expected top_score=- placeholder on a backend error (got: $(field_n "$line" 7))"
case "$(field_n "$line" 10)" in
  error:*) : ;;
  *) fail "15: expected mode=error:<rc> on a backend error (got: $(field_n "$line" 10))" ;;
esac
echo "PASS: 15 a backend error still logs exactly one read-log line, with mode=error:<rc>"

# --- 16. the WARM basic-memory-mcp backend logs outcome fields too -----------
# ks_search is the ONE entrypoint both backends share (knowledge_search_mcp.sh
# registers "basic-memory-mcp" purely via the command -v dispatch seam, no
# separate read-log call site — see validate-knowledge-search-emit.sh). Point
# the daemon URL at a closed port so the warm path fails fast into its
# documented fail-open delegation to the cold CLI backend (the OUT_TMP fake
# uvx from cases 11-15) — no real daemon needed, exercising both backends'
# code paths through a single outcome-field assertion.
if command -v curl >/dev/null 2>&1; then
  (
    export KNOWLEDGE_STORE_ROOT="$OUT_TMP/store"
    export KNOWLEDGE_SEARCH_BM_HOME="$OUT_TMP/bm-home"
    export KNOWLEDGE_SEARCH_BM_PROJECT="outcome-test"
    export KNOWLEDGE_READ_LOG="$OUT_LOG"
    export PATH="$OUT_TMP/bin:$PATH"
    export FAKE_BM_MODE="hit"
    export KNOWLEDGE_SEARCH_BACKEND="basic-memory-mcp"
    export KNOWLEDGE_SEARCH_BM_MCP_URL="http://127.0.0.1:1/mcp"
    export KNOWLEDGE_SEARCH_BM_MCP_CONNECT_TIMEOUT="1"
    export KNOWLEDGE_SEARCH_RERANK=0
    export KS_SEARCH_FALLBACK_RAW_DIR="$OUT_TMP/mcp-raw"
    export KS_SEARCH_FALLBACK_STATE_DIR="$OUT_TMP/mcp-state"
    unset CLAUDE_CODE_SESSION_ID || true
    # shellcheck source=/dev/null
    source "$STORE_LIB"
    # shellcheck source=/dev/null
    source "$SEARCH_LIB"
    # shellcheck source=/dev/null
    source "$MCP_LIB"
    ks_search "widget install guide" >/dev/null 2>/dev/null
  )
  line="$(tail -n1 "$OUT_LOG")"
  [ "$(field_n "$line" 6)" = "2" ] || fail "16: expected result_count=2 via the warm-backend's cold fail-open (got: $(field_n "$line" 6))"
  [ "$(field_n "$line" 10)" = "hybrid" ] || fail "16: expected mode=hybrid (rerank off) regardless of which backend answered (got: $(field_n "$line" 10))"
  echo "PASS: 16 KNOWLEDGE_SEARCH_BACKEND=basic-memory-mcp's fail-open-to-cold path still logs the same outcome fields (one shared ks_search call site, both backends)"
else
  echo "SKIP: 16 warm basic-memory-mcp outcome-field assertion (curl not installed)"
fi

# --- 17. abstention floor wires the `abstained` outcome field (foundation#1450) ---
# Reuses the same OUT_TMP fixture; a new FAKE_BM_MODE returns two candidates
# that fail BOTH abstention floors for the query below (unrelated titles ->
# L==0; scores 0.65/0.60 < the 0.72 default). A literal-match file is ALSO
# planted so this proves the ratified L1 semantics (clause 4): the rg
# fallback stays SUPPRESSED because the backend returned a non-empty
# candidate set — an abstention is a post-re-rank empty, never a
# backend-empty, so it must not fall into the rg-fallback branch at all.
if command -v rg >/dev/null 2>&1; then
  mkdir -p "$OUT_TMP/store/Decisions"
  printf 'this note literally says widget install guide steps\n' > "$OUT_TMP/store/Decisions/literal-match.md"
  (
    export KNOWLEDGE_STORE_ROOT="$OUT_TMP/store"
    export KNOWLEDGE_SEARCH_BM_HOME="$OUT_TMP/bm-home"
    export KNOWLEDGE_SEARCH_BM_PROJECT="outcome-test"
    export KNOWLEDGE_READ_LOG="$OUT_LOG"
    export PATH="$OUT_TMP/bin:$PATH"
    export FAKE_BM_MODE="low_conf"
    export KNOWLEDGE_SEARCH_ABSTAIN=1
    unset CLAUDE_CODE_SESSION_ID || true
    # shellcheck source=/dev/null
    source "$STORE_LIB"
    # shellcheck source=/dev/null
    source "$SEARCH_LIB"
    stdout="$(ks_search "widget install guide" --limit 5 2>"$OUT_TMP/stderr17")"
    rc=$?
    [ "$rc" -eq 0 ] || fail "17: an abstained ks_search call must exit 0 (got $rc)"
    [ -z "$stdout" ] || fail "17: an abstained ks_search call must yield empty stdout (got: $stdout)"
    grep -q "rg-fallback" "$OUT_TMP/stderr17" \
      && fail "17: the rg-fallback notice must NOT fire on a floor-triggered abstention (backend was non-empty)"
    :
  )
  line="$(tail -n1 "$OUT_LOG")"
  [ "$(field_n "$line" 6)" = "0" ] || fail "17: expected result_count=0 on an abstained query (got: $(field_n "$line" 6))"
  [ "$(field_n "$line" 7)" = "-" ] || fail "17: expected top_score=- on an abstained query (got: $(field_n "$line" 7))"
  [ "$(field_n "$line" 8)" = "1" ] || fail "17: expected abstained=1 (got: $(field_n "$line" 8))"
  [ "$(field_n "$line" 9)" = "0" ] || fail "17: expected rg_fallback=0 -- suppressed per the L1 ratified semantics (got: $(field_n "$line" 9))"
  echo "PASS: 17 the abstention floor sets abstained=1, result_count=0/top_score=-, and suppresses the rg fallback even though a literal match exists on disk"
else
  echo "SKIP: 17 abstention-floor rg-suppression assertion (ripgrep not installed)"
fi

# --- 18. abstention floor is OFF by default -- byte-identical outcome fields --
(
  export KNOWLEDGE_STORE_ROOT="$OUT_TMP/store"
  export KNOWLEDGE_SEARCH_BM_HOME="$OUT_TMP/bm-home"
  export KNOWLEDGE_SEARCH_BM_PROJECT="outcome-test"
  export KNOWLEDGE_READ_LOG="$OUT_LOG"
  export PATH="$OUT_TMP/bin:$PATH"
  export FAKE_BM_MODE="low_conf"
  unset KNOWLEDGE_SEARCH_ABSTAIN || true
  unset CLAUDE_CODE_SESSION_ID || true
  # shellcheck source=/dev/null
  source "$STORE_LIB"
  # shellcheck source=/dev/null
  source "$SEARCH_LIB"
  ks_search "widget install guide" --limit 5 >/dev/null
)
line="$(tail -n1 "$OUT_LOG")"
[ "$(field_n "$line" 6)" = "2" ] || fail "18: KNOWLEDGE_SEARCH_ABSTAIN unset must not change result_count (got: $(field_n "$line" 6))"
[ "$(field_n "$line" 8)" = "0" ] || fail "18: KNOWLEDGE_SEARCH_ABSTAIN unset must leave abstained=0 (got: $(field_n "$line" 8))"
echo "PASS: 18 the abstention floor is off by default -- low-confidence results still return normally"

echo "ALL PASS: read-log telemetry (ks__dispatch + ks_search entrypoint, incl. outcome fields on both backends)"
