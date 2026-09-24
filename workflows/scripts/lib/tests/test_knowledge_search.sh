#!/usr/bin/env bash
#
# Tests for workflows/scripts/lib/knowledge_search.sh — the knowledge_search
# concept-level retrieval surface (foundation #776, Epic A #762) and its
# basic-memory backend. Zero network, zero real embeddings: every case drives
# a FAKE `uvx` binary on PATH (the pattern board/tests/test_capture.sh uses
# for `gh`), never the real basic-memory CLI. All state lives under a
# throwaway tmpdir; never touches a real vault, XDG dir, or Travis's HOME.
#
# Covers: dispatch to an unregistered backend (exit 2), empty-query usage
# error (exit 2), posture assembly (config.json carries every no-mutation
# key from the spike verdict, BEFORE the first index; the belt-and-suspenders
# env var reaches the subprocess), corpus-root binding (project registration
# always uses ks_root, no independent path setting), a successful hybrid-search
# round-trip reshaped into JSONL, the backend-error path (subprocess exits
# non-zero / emits unparseable output -> exit 4), the reindex entry point,
# and the legible-degradation path (no `uvx` on PATH -> exit 3, "skipped —"
# on stderr, nothing on stdout, never a silent empty result).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$HERE/.." && pwd)"
STORE_LIB="$LIB_DIR/knowledge_store.sh"
SEARCH_LIB="$LIB_DIR/knowledge_search.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/ks-search-test-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

ROOT="$TMP/store"          # the knowledge_store corpus (ks_root)
BM_HOME="$TMP/bm-home"     # isolated basic-memory HOME (point 6)
BIN="$TMP/bin"             # fake-`uv` PATH dir
FAKE_BM_LOG="$TMP/bm-calls.log"   # every call to the INSTALLED basic-memory shim
FAKE_UV_LOG="$TMP/uv-calls.log"   # every call to `uv` itself (i.e. tool installs)
FAKE_BM_TEMPLATE="$TMP/basic-memory.template"
# Where the adapter installs its uv tool, derived from BM_HOME exactly as
# knowledge_search.sh's own _ks_bm_tool_bin_dir/_ks_bm_bin_path do. Asserted
# rather than assumed: case 18a below proves the adapter really writes here.
TOOL_BIN_DIR="$BM_HOME/uv-tool-bin"
BM_BIN="$TOOL_BIN_DIR/basic-memory"
PIN_STAMP="$TOOL_BIN_DIR/.ks-installed-pin"
mkdir -p "$ROOT" "$BIN"

# -- the fake basic-memory ENTRY POINT (temperloop#1113) -------------------
# Written to disk as a TEMPLATE, not directly onto PATH: since #1113 the
# adapter no longer resolves `uvx --from basic-memory==<ver>` per run -- it
# installs the pin once as a uv tool and invokes the installed entry point by
# absolute path. So the fake `uv` below is what materialises this template
# into $UV_TOOL_BIN_DIR/basic-memory, exactly as a real `uv tool install`
# would, and NOTHING named `basic-memory` is ever placed on PATH.
#
# The template is stamped with the spec/interpreter that installed it
# (@SPEC@/@PY@), which is what lets case 18c prove a PIN CHANGE re-installed
# rather than silently keeping the old build alive -- the sharpest regression
# risk of moving off per-run resolution.
#
# Logs every invocation's argv + the resolved $0 + the
# HOME/BASIC_MEMORY_DISABLE_PERMALINKS env it saw, so the test can assert
# posture (points 1 and 6) after the fact. FAKE_BM_MODE selects canned
# behavior for `tool search-notes`:
#   ok (default) -> canned 2-result hybrid JSON on stdout
#   search_fail  -> exit 1, message on stderr (subprocess-error path)
#   bad_json     -> exit 0, non-JSON on stdout (parse-error path)
cat > "$FAKE_BM_TEMPLATE" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
: "${FAKE_BM_LOG:?}"
INSTALLED_SPEC='@SPEC@'
INSTALLED_PY='@PY@'
{
  printf 'ARGS: %s\n' "$*"
  printf 'BIN=%s\n' "$0"
  printf 'INSTALLED=%s python=%s\n' "$INSTALLED_SPEC" "$INSTALLED_PY"
  printf 'HOME=%s\n' "${HOME:-<unset>}"
  printf 'BASIC_MEMORY_DISABLE_PERMALINKS=%s\n' "${BASIC_MEMORY_DISABLE_PERMALINKS:-<unset>}"
} >> "$FAKE_BM_LOG"

sub="${1:-}"; shift || true

case "$sub" in
  project)
    action="${1:-}"; shift || true
    if [ "$action" = "add" ]; then
      name="${1:-}"; path="${2:-}"
      printf 'PROJECT_ADD name=%s path=%s\n' "$name" "$path" >> "$FAKE_BM_LOG"
      if [ "${FAKE_BM_MODE:-ok}" = "project_add_fail" ]; then
        echo "Error adding project: simulated registration failure detail" >&2
        exit 1
      fi
      # register_then_ok (#996 lazy-on-miss cold path): registration drops a
      # marker so a subsequent search-notes succeeds where the pre-register one
      # failed (project-not-found → register → retry).
      [ "${FAKE_BM_MODE:-ok}" = "register_then_ok" ] && : > "${FAKE_BM_LOG}.registered"
      echo "Project '$name' added successfully"
      exit 0
    fi
    ;;
  reindex)
    printf 'REINDEX args=%s\n' "$*" >> "$FAKE_BM_LOG"
    # FAKE_BM_REINDEX_FAIL is orthogonal to FAKE_BM_MODE on purpose: the
    # cold-start index (temperloop#1635) runs INSIDE the register_then_ok
    # chain, so its failure has to be selectable without disturbing the
    # search/registration behaviour that same chain depends on.
    if [ "${FAKE_BM_REINDEX_FAIL:-0}" = "1" ]; then
      echo "fake-bm: simulated reindex failure detail" >&2
      exit 1
    fi
    echo "Reindex complete!"
    exit 0
    ;;
  tool)
    if [ "${1:-}" = "search-notes" ]; then
      shift
      printf 'SEARCH args=%s\n' "$*" >> "$FAKE_BM_LOG"
      case "${FAKE_BM_MODE:-ok}" in
        search_fail|project_add_fail)
          # project_add_fail must also MISS the search: under #996's lazy-on-miss
          # flow, `project add` is only attempted after a search miss, so a
          # registration-failure test needs the search to fail first.
          echo "fake-bm: simulated backend crash / miss" >&2
          exit 1
          ;;
        bad_json)
          echo "this is not json"
          exit 0
          ;;
        empty_results)
          # A zero-match query: basic-memory returns a non-empty {"results":[]}
          # ENVELOPE (exit 0), NOT empty stdout — the load-bearing #996 contract.
          echo '{"results":[],"current_page":1,"page_size":10,"total":0,"has_more":false}'
          exit 0
          ;;
        low_conf)
          # Both candidates fail the abstention floor's DEFAULT thresholds
          # (score < 0.72, and titles share no query terms so L == 0 < 0.10)
          # — used to exercise KNOWLEDGE_SEARCH_ABSTAIN (foundation#1450).
          cat <<'JSON'
{"results":[{"title":"unrelated thing","type":"entity","score":0.65,"content":"c1","matched_chunk":"c1","file_path":"Decisions/unrelated-thing.md","metadata":{},"entity_id":1},{"title":"another unrelated","type":"entity","score":0.60,"content":"c2","matched_chunk":"c2","file_path":"Decisions/another-unrelated.md","metadata":{},"entity_id":2}],"current_page":1,"page_size":10,"total":0,"has_more":false}
JSON
          exit 0
          ;;
        two_partitions)
          # temperloop#418 partition fixture: FOUR notes spanning both
          # membership forms plus the unpartitioned case, so one canned
          # response drives every scoping assertion.
          #   Decisions/acme - retainer terms.md   -> partition `acme`   (filename form)
          #   Decisions/zenith - retainer terms.md -> partition `zenith` (filename form)
          #   zenith/Decisions/rates.md            -> partition `zenith` (directory form)
          #   Index.md                             -> UNPARTITIONED
          cat <<'JSON'
{"results":[{"title":"acme - retainer terms","type":"entity","score":1.20,"content":"acme confidential","matched_chunk":"acme confidential","file_path":"Decisions/acme - retainer terms.md","metadata":{},"entity_id":1},{"title":"zenith - retainer terms","type":"entity","score":1.10,"content":"zenith confidential","matched_chunk":"zenith confidential","file_path":"Decisions/zenith - retainer terms.md","metadata":{},"entity_id":2},{"title":"rates","type":"entity","score":0.95,"content":"zenith rates","matched_chunk":"zenith rates","file_path":"zenith/Decisions/rates.md","metadata":{},"entity_id":3},{"title":"Index","type":"entity","score":0.90,"content":"index","matched_chunk":"index","file_path":"Index.md","metadata":{},"entity_id":4}],"current_page":1,"page_size":10,"total":4,"has_more":false}
JSON
          exit 0
          ;;
        register_then_ok)
          # Fail until the project has been registered (marker present), then
          # return results — the #996 lazy-on-miss cold/reset path.
          if [ ! -f "${FAKE_BM_LOG}.registered" ]; then
            echo "fake-bm: project not registered (register_then_ok, pre-registration)" >&2
            exit 1
          fi
          cat <<'JSON'
{"results":[{"title":"Foo","type":"entity","score":1.23,"content":"c1 full text","matched_chunk":"c1 snippet","file_path":"Decisions/foo.md","metadata":{},"entity_id":1},{"title":"Bar","type":"entity","score":0.9,"content":"c2 full text","matched_chunk":"c2 snippet","file_path":"Decisions/bar.md","metadata":{},"entity_id":2}],"current_page":1,"page_size":10,"total":0,"has_more":false}
JSON
          exit 0
          ;;
        *)
          cat <<'JSON'
{"results":[{"title":"Foo","type":"entity","score":1.23,"content":"c1 full text","matched_chunk":"c1 snippet","file_path":"Decisions/foo.md","metadata":{},"entity_id":1},{"title":"Bar","type":"entity","score":0.9,"content":"c2 full text","matched_chunk":"c2 snippet","file_path":"Decisions/bar.md","metadata":{},"entity_id":2}],"current_page":1,"page_size":10,"total":0,"has_more":false}
JSON
          exit 0
          ;;
      esac
    fi
    ;;
esac
echo "fake-bm: unhandled invocation: $*" >&2
exit 9
FAKE

# -- the fake `uv` (the ONLY thing this test puts on PATH) -----------------
# Implements exactly the one call the adapter makes: `uv tool install --force
# --python <ver> basic-memory==<ver>`, materialising the template above into
# $UV_TOOL_BIN_DIR. It hard-REQUIRES UV_TOOL_DIR/UV_TOOL_BIN_DIR to be set,
# which is itself an assertion: if the adapter ever stopped pinning the tool
# dirs into its own isolated home, this fake would fail loudly instead of
# quietly installing into the operator's real ~/.local/bin.
#
# FAKE_UV_MODE selects the install outcome:
#   ok (default) -> installs the entry point, exit 0
#   install_fail -> exit 1 with a message on stderr (degradation path)
#   install_noop -> exit 0 but write NO entry point (the "reported success,
#                   produced nothing" case the adapter must still catch)
cat > "$BIN/uv" <<'FAKEUV'
#!/usr/bin/env bash
set -euo pipefail
: "${FAKE_UV_LOG:?}"
{
  printf 'ARGS: %s\n' "$*"
  printf 'HOME=%s\n' "${HOME:-<unset>}"
  printf 'UV_TOOL_DIR=%s\n' "${UV_TOOL_DIR:-<unset>}"
  printf 'UV_TOOL_BIN_DIR=%s\n' "${UV_TOOL_BIN_DIR:-<unset>}"
} >> "$FAKE_UV_LOG"

[ "${1:-}" = "tool" ] && [ "${2:-}" = "install" ] || {
  echo "fake-uv: unsupported invocation: $*" >&2; exit 9; }
shift 2
py=""; spec=""; forced=0
while [ $# -gt 0 ]; do
  case "$1" in
    --force)  forced=1; shift ;;
    --python) py="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
    *)        spec="$1"; shift ;;
  esac
done
printf 'TOOL_INSTALL spec=%s python=%s force=%s\n' "$spec" "$py" "$forced" >> "$FAKE_UV_LOG"

case "${FAKE_UV_MODE:-ok}" in
  install_fail)
    echo "fake-uv: simulated resolution failure for $spec" >&2
    exit 1
    ;;
  install_noop)
    exit 0
    ;;
esac

: "${UV_TOOL_DIR:?fake-uv: UV_TOOL_DIR must be pinned by the adapter}"
: "${UV_TOOL_BIN_DIR:?fake-uv: UV_TOOL_BIN_DIR must be pinned by the adapter}"
: "${FAKE_BM_TEMPLATE:?}"
mkdir -p "$UV_TOOL_DIR/basic-memory" "$UV_TOOL_BIN_DIR"
sed -e "s|@SPEC@|$spec|g" -e "s|@PY@|$py|g" "$FAKE_BM_TEMPLATE" > "$UV_TOOL_BIN_DIR/basic-memory"
chmod +x "$UV_TOOL_BIN_DIR/basic-memory"
exit 0
FAKEUV
chmod +x "$BIN/uv"

# A PATH-visible `uvx` that can only FAIL. Since #1113 nothing in the adapter
# may reach basic-memory by per-run resolution; this tripwire turns a
# regression back to `uvx --from ...` into a loud, named failure instead of a
# silent (and, on a host with a real uvx, network-touching) success.
cat > "$BIN/uvx" <<'FAKEUVX'
#!/usr/bin/env bash
: "${FAKE_UV_LOG:?}"
printf 'FORBIDDEN_UVX: %s\n' "$*" >> "$FAKE_UV_LOG"
echo "fake-uvx: the adapter must not resolve basic-memory per run (temperloop#1113)" >&2
exit 9
FAKEUVX
chmod +x "$BIN/uvx"

# ── shared env for every case below ─────────────────────────────────────
export KNOWLEDGE_STORE_ROOT="$ROOT"
export KNOWLEDGE_SEARCH_BM_HOME="$BM_HOME"
export KNOWLEDGE_SEARCH_BM_PROJECT="test-project"
export FAKE_BM_LOG FAKE_UV_LOG FAKE_BM_TEMPLATE
# Isolate the read-log (temperloop#229) under the throwaway tmpdir too — every
# ks_search call below goes through ks__read_log_emit; without this override
# it would default to the real machine's $XDG_STATE_HOME/foundation/
# knowledge-reads.log.
export KNOWLEDGE_READ_LOG="$TMP/knowledge-reads.log"

# shellcheck source=/dev/null
source "$STORE_LIB"
# shellcheck source=/dev/null
source "$SEARCH_LIB"

# --- 1. empty query -> exit 2, no subprocess call ----------------------------
rm -f "$FAKE_BM_LOG"
set +e
out="$(PATH="$BIN:$PATH" ks_search "" 2>&1)"
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "1: empty query should exit 2 (got $rc)"
[ ! -e "$FAKE_BM_LOG" ] || fail "1: empty query must not reach the backend subprocess"
echo "PASS: 1 ks_search with an empty query exits 2 without touching the backend"

# --- 2. unregistered backend -> dispatch error, exit 2 ------------------------
set +e
out="$(KNOWLEDGE_SEARCH_BACKEND="does-not-exist" PATH="$BIN:$PATH" ks_search "hello" 2>&1)"
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "2: unknown backend should exit 2 (got $rc)"
case "$out" in
  *does-not-exist*) : ;;
  *) fail "2: error message should name the unknown backend (got: $out)" ;;
esac
echo "PASS: 2 selecting an unimplemented search backend fails dispatch with exit 2"

# --- 3. degradation path: no uvx on PATH -> exit 3, skipped notice, no stdout -
EMPTY_BIN="$TMP/empty-bin"
mkdir -p "$EMPTY_BIN"
set +e
out="$(PATH="$EMPTY_BIN" ks_search "hello" 2>/dev/null)"
rc=$?
err="$(PATH="$EMPTY_BIN" ks_search "hello" 2>&1 1>/dev/null)"
set -e
[ "$rc" -eq 3 ] || fail "3: missing uv should exit 3 (got $rc)"
[ -z "$out" ] || fail "3: missing uv must print NOTHING to stdout (got: $out)"
case "$err" in
  "skipped — knowledge_search unavailable"*) : ;;
  *) fail "3: stderr must begin with the 'skipped —' notice (got: $err)" ;;
esac
case "$err" in
  *"uv not found on PATH"*) : ;;
  *) fail "3: the notice must name the missing tool (got: $err)" ;;
esac
echo "PASS: 3 ks_search with no uv on PATH degrades legibly (exit 3, skipped notice, empty stdout)"

# --- 3b. ks_search_available mirrors the same probe --------------------------
set +e
PATH="$EMPTY_BIN" ks_search_available >/dev/null 2>/dev/null
rc=$?
PATH="$BIN:$PATH" ks_search_available >/dev/null 2>/dev/null
rc_ok=$?
set -e
[ "$rc" -eq 3 ] || fail "3b: ks_search_available should exit 3 when uv is missing (got $rc)"
[ "$rc_ok" -eq 0 ] || fail "3b: ks_search_available should exit 0 when uv is present (got $rc_ok)"
echo "PASS: 3b ks_search_available exit-code probe matches ks_search's own gate (3 missing / 0 present)"

# --- 3b2. --probe is ZERO-SIDE-EFFECT: it must never invoke uv --------------
# The default arm lazily installs (the ratified hybrid, temperloop#1113), which
# silently repurposed every caller that used this as a cheap predicate -- most
# sharply scripts/tests/test_stranger_config.sh, a KERNEL_GATES entry running in
# a fresh sandbox, which started firing a real `uv tool install` from inside a
# test asserting it makes no network call (kernel principle 3). --probe is the
# sweepable public answer, and THIS case is what keeps it honest: a spy `uv`
# that records every invocation, asserted to record none.
SPY_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ks-probe-spy-XXXXXX")"
mkdir -p "$SPY_DIR/bin" "$SPY_DIR/home"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/uv.calls"\nexit 0\n' "$SPY_DIR" > "$SPY_DIR/bin/uv"
chmod +x "$SPY_DIR/bin/uv"
: > "$SPY_DIR/uv.calls"
set +e
( PATH="$SPY_DIR/bin:$PATH" HOME="$SPY_DIR/home" \
  KNOWLEDGE_SEARCH_BM_HOME="$SPY_DIR/home/bm" \
  ks_search_available --probe >/dev/null 2>/dev/null )
rc_probe=$?
set -e
spy_calls="$(wc -l < "$SPY_DIR/uv.calls" | tr -d '[:space:]')"
[ "$rc_probe" -eq 3 ] || fail "3b2: --probe should exit 3 when the pinned tool is not installed (got $rc_probe)"
[ "$spy_calls" -eq 0 ] || fail "3b2: --probe invoked uv $spy_calls time(s) — it must be zero-side-effect (calls: $(cat "$SPY_DIR/uv.calls"))"
rm -rf "$SPY_DIR"
echo "PASS: 3b2 ks_search_available --probe reports not-ready without invoking uv (no install, no writes)"

# --- 3c. --quiet suppresses the notice and NOTHING ELSE (temperloop#1113) ----
# ks_search's own read-log probe passes --quiet so the "skipped —" line isn't
# printed twice. It must suppress exactly that line and keep the same exit
# code -- a blanket 2>/dev/null there would also swallow install progress,
# which is the only signal an operator gets on a cold first run.
set +e
err_quiet="$(PATH="$EMPTY_BIN" ks_search_available --quiet 2>&1 1>/dev/null)"
rc_quiet=$?
err_bogus="$(PATH="$EMPTY_BIN" ks_search_available --no-such-flag 2>&1 1>/dev/null)"
rc_bogus=$?
set -e
[ "$rc_quiet" -eq 3 ] || fail "3c: --quiet must not change the exit code (got $rc_quiet)"
[ -z "$err_quiet" ] || fail "3c: --quiet must suppress the skipped notice (got: $err_quiet)"
[ "$rc_bogus" -eq 2 ] || fail "3c: an unrecognised available flag should exit 2 (got $rc_bogus)"
case "$err_bogus" in
  *"unrecognised argument"*) : ;;
  *) fail "3c: an unrecognised available flag must say so (got: $err_bogus)" ;;
esac
echo "PASS: 3c ks_search_available --quiet suppresses only the notice; an unknown flag is rejected (exit 2)"

# --- 4. successful hybrid search -> JSONL reshape, ranked order preserved ----
rm -rf "$BM_HOME"
rm -f "$FAKE_BM_LOG" "$FAKE_BM_LOG.registered"
out="$(PATH="$BIN:$PATH" FAKE_BM_MODE=ok ks_search "orchard" --limit 5)" || fail "4: ks_search should succeed"
lines="$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
[ "$lines" -eq 2 ] || fail "4: expected 2 JSONL result lines (got $lines): $out"
line1="$(printf '%s\n' "$out" | sed -n '1p')"
line2="$(printf '%s\n' "$out" | sed -n '2p')"
doc1="$(printf '%s' "$line1" | jq -r '.doc_id')"
score1="$(printf '%s' "$line1" | jq -r '.score')"
snippet1="$(printf '%s' "$line1" | jq -r '.snippet')"
doc2="$(printf '%s' "$line2" | jq -r '.doc_id')"
[ "$doc1" = "Decisions/foo.md" ] || fail "4: first result doc_id wrong (got $doc1)"
[ "$score1" = "1.23" ] || fail "4: first result score wrong (got $score1)"
[ "$snippet1" = "c1 snippet" ] || fail "4: first result snippet wrong (got $snippet1)"
[ "$doc2" = "Decisions/bar.md" ] || fail "4: second result doc_id wrong (got $doc2) -- ranked order not preserved"
echo "PASS: 4 ks_search reshapes basic-memory's hybrid-search JSON into ranked JSONL"

# --- 4b. warm path issues ONE subprocess: no per-query project add (#996) -----
# The warm/ok path (project already registered) must NOT call `project add` —
# the ~1.9s re-register #996 drops — and must issue exactly one search-notes.
if grep -q '^PROJECT_ADD ' "$FAKE_BM_LOG"; then
  fail "4b: warm path must NOT call project add (#996); log:\n$(cat "$FAKE_BM_LOG")"
fi
warm_search_calls="$(grep -c '^SEARCH ' "$FAKE_BM_LOG" || true)"
[ "$warm_search_calls" -eq 1 ] \
  || fail "4b: warm path should issue exactly ONE search-notes (got $warm_search_calls); log:\n$(cat "$FAKE_BM_LOG")"
echo "PASS: 4b warm path issues one subprocess — no per-query project add (#996)"

# --- 4c. warm no-match: exit 0 + empty stdout, still NO re-register (#996) -----
# The load-bearing #996 correctness contract: bm returns a non-empty
# {"results":[]} envelope for a zero-match query, so `[ -z "$raw" ]` is false →
# NOT a miss → no re-register, and the empty envelope reshapes to zero output
# lines + exit 0 (NOT a backend error). If this ever broke, a no-match would
# both slow to a needless register+retry AND wrongly report exit 4.
rm -rf "$BM_HOME"; rm -f "$FAKE_BM_LOG" "$FAKE_BM_LOG.registered"
out4c="$(PATH="$BIN:$PATH" FAKE_BM_MODE=empty_results ks_search "no-such-term" --limit 5)" \
  || fail "4c: a warm no-match must exit 0 (empty {\"results\":[]} envelope is not a failure)"
[ -z "$out4c" ] || fail "4c: a warm no-match must print nothing to stdout (got: $out4c)"
if grep -q '^PROJECT_ADD ' "$FAKE_BM_LOG"; then
  fail "4c: a warm no-match must NOT re-register (#996); log:\n$(cat "$FAKE_BM_LOG")"
fi
nomatch_search="$(grep -c '^SEARCH ' "$FAKE_BM_LOG" || true)"
[ "$nomatch_search" -eq 1 ] \
  || fail "4c: warm no-match should issue exactly ONE search (got $nomatch_search); log:\n$(cat "$FAKE_BM_LOG")"
echo "PASS: 4c warm no-match → exit 0, empty stdout, no re-register (#996 empty-envelope contract)"

# --- 5. cold/reset path: lazy register-on-miss, bound to ks_root, then retry --
# When the first search misses (project not registered on first use, or a
# `basic-memory reset` dropped the DB while config still lists it), ks_search
# registers (bound to ks_root — the corpus-root binding still holds, now on the
# cold path) and retries the search ONCE.
rm -rf "$BM_HOME"
rm -f "$FAKE_BM_LOG" "$FAKE_BM_LOG.registered"
out5="$(PATH="$BIN:$PATH" FAKE_BM_MODE=register_then_ok ks_search "orchard" --limit 5)" \
  || fail "5: cold-path ks_search should recover via register+retry"
[ "$(printf '%s\n' "$out5" | wc -l | tr -d ' ')" -eq 2 ] \
  || fail "5: cold-path search should return 2 results after register+retry; got: $out5"
grep -q "PROJECT_ADD name=test-project path=$ROOT\$" "$FAKE_BM_LOG" \
  || fail "5: cold-path register must bind project to ROOT ($ROOT); log:\n$(cat "$FAKE_BM_LOG")"
cold_add_calls="$(grep -c '^PROJECT_ADD ' "$FAKE_BM_LOG" || true)"
cold_search_calls="$(grep -c '^SEARCH ' "$FAKE_BM_LOG" || true)"
[ "$cold_add_calls" -eq 1 ] \
  || fail "5: cold path should register exactly once (got $cold_add_calls); log:\n$(cat "$FAKE_BM_LOG")"
[ "$cold_search_calls" -eq 2 ] \
  || fail "5: cold path should search twice — miss then retry (got $cold_search_calls); log:\n$(cat "$FAKE_BM_LOG")"
echo "PASS: 5 cold/reset path lazily registers (bound to ks_root) and retries the search once (#996)"

# --- 5b. cold path INDEXES once, between registration and the retry (#1635) --
# `project add` registers; it does NOT scan the corpus. Measured on a clean
# Debian container (docs/validation/clean-host-ks-search.md), that left a
# stranger's first search answering out of an EMPTY index: exit 0, zero
# results, nothing wrong to report. The order is the whole assertion — an
# index before registration would index an unregistered project, and an index
# after the retry would be one search too late.
cold_reindex_calls="$(grep -c '^REINDEX ' "$FAKE_BM_LOG" || true)"
[ "$cold_reindex_calls" -eq 1 ] \
  || fail "5b: cold path should index exactly once (got $cold_reindex_calls); log:\n$(cat "$FAKE_BM_LOG")"
grep -q '^REINDEX args=--project test-project$' "$FAKE_BM_LOG" \
  || fail "5b: the cold-start index must target the adapter's project; log:\n$(cat "$FAKE_BM_LOG")"
order5b="$(grep -nE '^(PROJECT_ADD|REINDEX|SEARCH) ' "$FAKE_BM_LOG" | sed -E 's/^[0-9]+:([A-Z_]+) .*/\1/' | tr '\n' ',')"
[ "$order5b" = "SEARCH,PROJECT_ADD,REINDEX,SEARCH," ] \
  || fail "5b: cold-path order must be miss → register → index → retry (got: $order5b); log:\n$(cat "$FAKE_BM_LOG")"
echo "PASS: 5b cold path indexes exactly once, between registration and the retry (#1635)"

# --- 5c. the warm path NEVER indexes (#1635 costs nothing per query) ---------
# The cold-start index rides the project-not-found miss branch, which a warm
# query never enters — so neither a warm hit nor a warm no-match may pay for
# an index. A per-query reindex would be far worse than the per-query
# `project add` #996 removed.
rm -rf "$BM_HOME"; rm -f "$FAKE_BM_LOG" "$FAKE_BM_LOG.registered"
PATH="$BIN:$PATH" FAKE_BM_MODE=ok ks_search "orchard" --limit 5 >/dev/null \
  || fail "5c: the warm path should succeed"
PATH="$BIN:$PATH" FAKE_BM_MODE=empty_results ks_search "no-such-term" --limit 5 >/dev/null \
  || fail "5c: a warm no-match should exit 0"
if grep -q '^REINDEX ' "$FAKE_BM_LOG"; then
  fail "5c: a warm query must NEVER index (#1635); log:\n$(cat "$FAKE_BM_LOG")"
fi
echo "PASS: 5c a warm hit and a warm no-match never trigger the cold-start index (#1635)"

# --- 5d. a failing cold-start index is best-effort, loud, never fatal --------
# The retry may still be answerable (another process may have indexed the same
# store), and a zero-result search that then reaches the ripgrep fallback beats
# exit 4. What it must never be is silent — a silent index failure recreates
# the invisible-empty state the index exists to remove.
rm -rf "$BM_HOME"; rm -f "$FAKE_BM_LOG" "$FAKE_BM_LOG.registered"
set +e
err5d="$(PATH="$BIN:$PATH" FAKE_BM_MODE=register_then_ok FAKE_BM_REINDEX_FAIL=1 \
  ks_search "orchard" --limit 5 2>&1 1>/dev/null)"
set -e
rm -rf "$BM_HOME"; rm -f "$FAKE_BM_LOG" "$FAKE_BM_LOG.registered"
out5d="$(PATH="$BIN:$PATH" FAKE_BM_MODE=register_then_ok FAKE_BM_REINDEX_FAIL=1 \
  ks_search "orchard" --limit 5 2>/dev/null)" \
  || fail "5d: a failed cold-start index must NOT fail the search (#1635)"
[ "$(printf '%s\n' "$out5d" | wc -l | tr -d ' ')" -eq 2 ] \
  || fail "5d: the retry should still return its results after a failed index; got: $out5d"
case "$err5d" in
  *"cold-start index failed"*) : ;;
  *) fail "5d: a failed cold-start index must say so on stderr (got: $err5d)" ;;
esac
case "$err5d" in
  *"simulated reindex failure detail"*) : ;;
  *) fail "5d: the index failure's own cause must be surfaced, not swallowed (got: $err5d)" ;;
esac
echo "PASS: 5d a failed cold-start index warns loudly, surfaces its cause, and never fails the search (#1635)"

# --- 5e. the cold-start index is BOUNDED when a timeout helper is in scope ---
# Same probe-don't-depend posture as the install bound (18f below): an
# unbounded index runs INSIDE a search call, so a wedged one turns "my first
# search is slow" into "my first search never returns".
rm -rf "$BM_HOME"; rm -f "$FAKE_BM_LOG" "$FAKE_BM_LOG.registered"
INDEX_TIMEOUT_WITNESS="$TMP/index-timeout-witness"
rm -f "$INDEX_TIMEOUT_WITNESS"
run_with_timeout() { printf '%s\n' "$1" >> "$INDEX_TIMEOUT_WITNESS"; shift; "$@"; }
PATH="$BIN:$PATH" FAKE_BM_MODE=register_then_ok ks_search "orchard" --limit 5 >/dev/null 2>&1 \
  || fail "5e: the bounded cold-start index path should still succeed"
unset -f run_with_timeout
grep -qx "$KNOWLEDGE_SEARCH_BM_INDEX_TIMEOUT" "$INDEX_TIMEOUT_WITNESS" \
  || fail "5e: the cold-start index was not bounded by KNOWLEDGE_SEARCH_BM_INDEX_TIMEOUT (witness: $(cat "$INDEX_TIMEOUT_WITNESS" 2>/dev/null))"
echo "PASS: 5e the one-time cold-start index is bounded by KNOWLEDGE_SEARCH_BM_INDEX_TIMEOUT when a timeout helper is in scope"

# --- 6. posture assembly: config.json carries every no-mutation key ----------
CONFIG="$BM_HOME/.basic-memory/config.json"
[ -f "$CONFIG" ] || fail "6: expected config.json to exist at $CONFIG after a search"
got_disable_permalinks="$(jq -r '.disable_permalinks' "$CONFIG")"
got_ensure_frontmatter="$(jq -r '.ensure_frontmatter_on_sync' "$CONFIG")"
got_format_on_save="$(jq -r '.format_on_save' "$CONFIG")"
got_update_permalinks="$(jq -r '.update_permalinks_on_move' "$CONFIG")"
got_kebab="$(jq -r '.kebab_filenames' "$CONFIG")"
got_sync_changes="$(jq -r '.sync_changes' "$CONFIG")"
got_auto_update="$(jq -r '.auto_update' "$CONFIG")"
got_model="$(jq -r '.semantic_embedding_model' "$CONFIG")"
got_dims="$(jq -r '.semantic_embedding_dimensions' "$CONFIG")"
got_dims_type="$(jq -r '.semantic_embedding_dimensions | type' "$CONFIG")"
got_cache_dir="$(jq -r '.semantic_embedding_cache_dir' "$CONFIG")"
got_projects_key="$(jq -r 'has("projects")' "$CONFIG")"
[ "$got_disable_permalinks" = "true" ]  || fail "6 point1: disable_permalinks should be true (got $got_disable_permalinks)"
[ "$got_ensure_frontmatter" = "false" ] || fail "6 point2: ensure_frontmatter_on_sync should be false (got $got_ensure_frontmatter)"
[ "$got_format_on_save" = "false" ]     || fail "6 point2: format_on_save should be false (got $got_format_on_save)"
[ "$got_update_permalinks" = "false" ]  || fail "6 point2: update_permalinks_on_move should be false (got $got_update_permalinks)"
[ "$got_kebab" = "false" ]              || fail "6 point2: kebab_filenames should be false (got $got_kebab)"
[ "$got_sync_changes" = "false" ]       || fail "6 point3: sync_changes should be false (got $got_sync_changes)"
[ "$got_auto_update" = "false" ]        || fail "6 point5: auto_update should be false (got $got_auto_update)"
[ "$got_model" = "bge-small-en-v1.5" ]  || fail "6 point7: semantic_embedding_model wrong (got $got_model)"
# temperloop#907: the dimensions key must be present, a JSON *number* (not a
# string — basic-memory reads it as the vector width), and must match the
# pinned model. A model written without its matching width yields a silent
# zero-embedding index.
[ "$got_dims_type" = "number" ] || fail "6 point7: semantic_embedding_dimensions must be a JSON number (got type $got_dims_type, value $got_dims)"
[ "$got_dims" = "384" ]         || fail "6 point7: semantic_embedding_dimensions should be 384 for bge-small-en-v1.5 (got $got_dims)"
case "$got_cache_dir" in
  "$BM_HOME"/*) : ;;
  *) fail "6 point6: semantic_embedding_cache_dir should live under the isolated BM home (got $got_cache_dir)" ;;
esac
[ "$got_projects_key" = "false" ] || fail "6 point9: config.json must not carry a hand-written 'projects' map (registration is CLI-only)"
echo "PASS: 6 config.json carries the full no-mutation posture set (points 1,2,3,5,6,7,9), written before the first index"

# --- 6a. point 7 coupling: dimensions are DERIVED from the model pin (temperloop#907) ---
# The whole guard is that the pair has ONE definition site: the config writer
# must not spell the model or the width itself, and the width must come from
# the model name. Assert the derivation directly, plus the loud-failure arm
# for a model with no known width (the case a future flip would otherwise
# ship as a zero-embedding index).
[ "$(_ks_bm_embedding_model)" = "$got_model" ] \
  || fail "6a: config.json's model must come from _ks_bm_embedding_model (pin=$(_ks_bm_embedding_model), config=$got_model)"
[ "$(_ks_bm_embedding_dimensions)" = "$got_dims" ] \
  || fail "6a: config.json's dimensions must come from _ks_bm_embedding_dimensions (derived=$(_ks_bm_embedding_dimensions), config=$got_dims)"
[ "$(_ks_bm_embedding_dimensions bge-base-en-v1.5)" = "768" ] \
  || fail "6a: a model flip must re-derive its own width (bge-base-en-v1.5 should be 768)"
if unknown_dims="$(_ks_bm_embedding_dimensions not-a-real-model 2>/dev/null)"; then
  fail "6a: an unknown embedding model must fail loudly, not emit a width (got $unknown_dims)"
fi
# Static half of the coupling: the config writer itself must spell NEITHER a
# model name NOR a width — it interpolates the pin and the derived value, so
# there is no second literal to fall out of sync with the first.
cfg_writer="$(sed -n '/^_ks_bm_ensure_config()/,/^}/p' "$SEARCH_LIB")"
grep -qF '"semantic_embedding_model": "$model"' <<<"$cfg_writer" \
  || fail "6a: the config writer must interpolate the model pin, not restate it"
grep -qF '"semantic_embedding_dimensions": $dims' <<<"$cfg_writer" \
  || fail "6a: the config writer must interpolate the derived dimensions, not restate them"
grep -qE 'bge-|semantic_embedding_dimensions": *[0-9]' <<<"$cfg_writer" \
  && fail "6a: the config writer must not hardcode a model name or a width (temperloop#907)"
echo "PASS: 6a model/dimensions are one pin + one derivation; unknown model fails loudly (temperloop#907)"

# --- 6b. .bmignore: upstream base set written, no store-specific extras by default (F#946 seam) ---
IGN="$BM_HOME/.basic-memory/.bmignore"
[ -f "$IGN" ] || fail "6b: expected .bmignore to exist at $IGN after a search"
grep -qxF '.obsidian'   "$IGN" || fail "6b: base set missing .obsidian"
grep -qxF 'node_modules' "$IGN" || fail "6b: base set missing node_modules"
grep -qxF 'config.json' "$IGN" || fail "6b: base set missing config.json"
grep -qxF '_inbox' "$IGN" && fail "6b: _inbox must NOT be present by default (KNOWLEDGE_SEARCH_BM_EXTRA_IGNORES empty for a stranger install)"
echo "PASS: 6b .bmignore carries the upstream base set; overlay seam empty by default (no _inbox)"

# --- 6c. EXTRA_IGNORES seam appends store-specific bare segments (the overlay path) ---
rm -f "$IGN"
KNOWLEDGE_SEARCH_BM_EXTRA_IGNORES="_inbox scratch" _ks_bm_ensure_ignore || fail "6c: _ks_bm_ensure_ignore failed"
grep -qxF '.obsidian' "$IGN" || fail "6c: base set still present alongside extras"
grep -qxF '_inbox'    "$IGN" || fail "6c: _inbox extra not appended"
grep -qxF 'scratch'   "$IGN" || fail "6c: scratch extra not appended"
echo "PASS: 6c KNOWLEDGE_SEARCH_BM_EXTRA_IGNORES appends store-specific bare segments (foundation sets _inbox)"

# --- 6d. idempotent: an existing .bmignore is never clobbered (write-only-if-absent) ---
KNOWLEDGE_SEARCH_BM_EXTRA_IGNORES="should-not-appear" _ks_bm_ensure_ignore || fail "6d: repeat call failed"
grep -qxF '_inbox' "$IGN"          || fail "6d: existing .bmignore must be preserved"
grep -qxF 'should-not-appear' "$IGN" && fail "6d: must NOT append to a pre-existing .bmignore (write-only-if-absent)"
echo "PASS: 6d .bmignore is write-only-if-absent (idempotent, never clobbers a prior run's file)"

# ── config.json is VERIFY-AND-REPAIR, not write-if-absent (foundation#1211) ──
# The old _ks_bm_ensure_config early-returned on `[ -f "$cfg_path" ]`, so an
# EXISTING config was trusted to still carry the posture. A live host was found
# carrying bm's own defaults there instead (sync_changes: true,
# ensure_frontmatter_on_sync: true, auto_update: true, cache dir null) — the
# vault-MUTATION class the posture exists to prevent. Cases 6e-6i pin the
# replacement: repair the drift, preserve adapter-UNOWNED state, stay
# idempotent, keep the absent-config path unchanged, and keep the
# model/dimensions pair-resolution failure non-writing.
#
# assert_full_posture <case-label> <config-path> — the posture set case 6 pins,
# reused so a repaired config is held to exactly the same bar as a fresh one.
assert_full_posture() {
  local label="$1" cfg="$2"
  [ "$(jq -r '.disable_permalinks'         "$cfg")" = "true"  ] || fail "$label point1: disable_permalinks should be true"
  [ "$(jq -r '.ensure_frontmatter_on_sync' "$cfg")" = "false" ] || fail "$label point2: ensure_frontmatter_on_sync should be false"
  [ "$(jq -r '.format_on_save'             "$cfg")" = "false" ] || fail "$label point2: format_on_save should be false"
  [ "$(jq -r '.update_permalinks_on_move'  "$cfg")" = "false" ] || fail "$label point2: update_permalinks_on_move should be false"
  [ "$(jq -r '.kebab_filenames'            "$cfg")" = "false" ] || fail "$label point2: kebab_filenames should be false"
  [ "$(jq -r '.sync_changes'               "$cfg")" = "false" ] || fail "$label point3: sync_changes should be false"
  [ "$(jq -r '.auto_update'                "$cfg")" = "false" ] || fail "$label point5: auto_update should be false"
  [ "$(jq -r '.semantic_embedding_model'   "$cfg")" = "$(_ks_bm_embedding_model)" ] \
    || fail "$label point7: semantic_embedding_model must come from the pin"
  [ "$(jq -r '.semantic_embedding_dimensions | type' "$cfg")" = "number" ] \
    || fail "$label point7: semantic_embedding_dimensions must be a JSON number"
  [ "$(jq -r '.semantic_embedding_dimensions' "$cfg")" = "$(_ks_bm_embedding_dimensions)" ] \
    || fail "$label point7: semantic_embedding_dimensions must be derived from the model pin"
  case "$(jq -r '.semantic_embedding_cache_dir' "$cfg")" in
    "$BM_HOME"/*) : ;;
    *) fail "$label point6: semantic_embedding_cache_dir should live under the isolated BM home" ;;
  esac
}

# --- 6e. a DRIFTED existing config.json is repaired, unowned state preserved --
# The drift seeded here is the exact live-host shape from the issue (bm's own
# defaults back in place), widened to every posture key so no key is repaired
# only by luck. Alongside it: a `projects` map (bm registers projects via the
# CLI — clobbering it deregisters the live store), a `default_project`, and an
# unrelated bookkeeping key. All three MUST survive byte-equivalent.
jq '.disable_permalinks            = false
  | .ensure_frontmatter_on_sync    = true
  | .format_on_save                = true
  | .update_permalinks_on_move     = true
  | .kebab_filenames               = true
  | .sync_changes                  = true
  | .auto_update                   = true
  | .semantic_embedding_model      = "not-the-pinned-model"
  | .semantic_embedding_dimensions = 1
  | .semantic_embedding_cache_dir  = null
  | .projects           = {"mind": "/vault/mind", "test-project": "/kb", "main": "/stray"}
  | .default_project    = "mind"
  | .bm_bookkeeping_key = 42' "$CONFIG" > "$TMP/cfg-drifted.json"
cp "$TMP/cfg-drifted.json" "$CONFIG"
_ks_bm_ensure_config || fail "6e: ensure_config must succeed on a drifted existing config"
assert_full_posture "6e" "$CONFIG"
[ "$(jq -Sc '.projects' "$CONFIG")" = '{"main":"/stray","mind":"/vault/mind","test-project":"/kb"}' ] \
  || fail "6e: the CLI-registered projects map must survive repair unchanged (got $(jq -Sc '.projects' "$CONFIG"))"
[ "$(jq -r '.default_project' "$CONFIG")" = "mind" ] \
  || fail "6e: default_project must survive repair unchanged"
[ "$(jq -r '.bm_bookkeeping_key' "$CONFIG")" = "42" ] \
  || fail "6e: unrelated bm bookkeeping keys must survive repair unchanged"
echo "PASS: 6e a drifted existing config.json is REPAIRED to the no-mutation posture, adapter-unowned state (projects/default_project/bookkeeping) preserved (foundation#1211)"

# --- 6f. idempotent: a second consecutive call changes nothing ----------------
# Two independent assertions, because either alone is weak: byte-equality shows
# the FILE did not change, and the absent "repaired" stderr notice shows the
# write branch was never even entered (a rewrite-to-identical-bytes would pass
# the first check but not the second).
cp "$CONFIG" "$TMP/cfg-after-repair.json"
err6f="$(_ks_bm_ensure_config 2>&1 1>/dev/null)" || fail "6f: repeat call failed"
cmp -s "$CONFIG" "$TMP/cfg-after-repair.json" \
  || fail "6f: a second consecutive call must leave the file byte-identical"
grep -q 'repaired drifted' <<<"$err6f" \
  && fail "6f: a second call must not take the write branch (stderr: $err6f)"
echo "PASS: 6f verify-and-repair is idempotent — a second consecutive call rewrites nothing and reports no repair"

# --- 6g. the ABSENT-config path still writes the same config as before --------
rm -f "$CONFIG"
_ks_bm_ensure_config || fail "6g: ensure_config must still write an absent config"
[ -f "$CONFIG" ] || fail "6g: absent config was not written"
assert_full_posture "6g" "$CONFIG"
[ "$(jq -r 'has("projects")' "$CONFIG")" = "false" ] \
  || fail "6g point9: a freshly written config must not carry a hand-written projects map (registration is CLI-only)"
echo "PASS: 6g the absent-config path is unchanged — same full posture, still no hand-written projects map"

# --- 6h. model/dimensions resolution failure returns non-zero WITHOUT writing --
# The pre-#1211 ordering guarantee (resolve the pair before anything is
# written) has to survive the new repair path too: an unknown model must fail
# BOTH arms — writing nothing when the config is absent, and repairing nothing
# when it exists — rather than leaving a mismatched width behind, which indexes
# every note to a zero vector (temperloop#907).
_ks_bm_saved_model_fn="$(declare -f _ks_bm_embedding_model)"
_ks_bm_embedding_model() { printf 'not-a-real-model\n'; }
rm -f "$CONFIG"
set +e
_ks_bm_ensure_config 2>/dev/null
rc6h_absent=$?
set -e
[ "$rc6h_absent" -ne 0 ] || fail "6h: an unknown embedding model must fail the absent-config path"
[ ! -f "$CONFIG" ] || fail "6h: nothing may be written when the model/dimensions pair does not resolve"
cp "$TMP/cfg-drifted.json" "$CONFIG"
set +e
_ks_bm_ensure_config 2>/dev/null
rc6h_existing=$?
set -e
[ "$rc6h_existing" -ne 0 ] || fail "6h: an unknown embedding model must fail the existing-config path too"
cmp -s "$CONFIG" "$TMP/cfg-drifted.json" \
  || fail "6h: an existing config must be left untouched when the model/dimensions pair does not resolve"
eval "$_ks_bm_saved_model_fn"
[ "$(_ks_bm_embedding_model)" = "bge-small-en-v1.5" ] || fail "6h: failed to restore the real model pin"
rm -f "$CONFIG"
_ks_bm_ensure_config || fail "6h: ensure_config should succeed again once the pin is restored"
assert_full_posture "6h" "$CONFIG"
echo "PASS: 6h an unresolvable model/dimensions pair fails BOTH paths non-zero and writes/repairs nothing (temperloop#907 ordering guarantee survives)"

# --- 6i. the repair set is one pin + one derivation, like the writer (6a) -----
# Static half, mirroring 6a: the repair path must interpolate the SAME pin and
# derivation rather than restating a model name or a width, or the two writers
# could drift apart into a half-updated pair.
repair_fn="$(sed -n '/^_ks_bm_repair_config()/,/^}/p' "$SEARCH_LIB")"
[ -n "$repair_fn" ] || fail "6i: could not extract _ks_bm_repair_config from $SEARCH_LIB"
grep -qE '\.semantic_embedding_model[[:space:]]*=[[:space:]]*\$model' <<<"$repair_fn" \
  || fail "6i: the repair path must interpolate the model pin, not restate it"
grep -qE '\.semantic_embedding_dimensions[[:space:]]*=[[:space:]]*\$dims' <<<"$repair_fn" \
  || fail "6i: the repair path must interpolate the derived dimensions, not restate them"
grep -qE 'bge-|\.semantic_embedding_dimensions[[:space:]]*=[[:space:]]*[0-9]' <<<"$repair_fn" \
  && fail "6i: the repair path must not hardcode a model name or a width (temperloop#907)"
# Every key the absent-config writer sets must also be VERIFIED by the repair
# path — otherwise a posture key could be written once and never checked again,
# which is the whole #1211 defect in miniature.
cfg_writer_keys="$(sed -n '/^_ks_bm_ensure_config()/,/^}/p' "$SEARCH_LIB" \
  | sed -nE 's/^[[:space:]]*"([a-z_]+)":.*/\1/p' | sort -u)"
[ -n "$cfg_writer_keys" ] || fail "6i: could not extract the writer's posture keys"
while read -r k; do
  [ -n "$k" ] || continue
  grep -qE "\\.${k}[[:space:]]*=" <<<"$repair_fn" \
    || fail "6i: posture key '$k' is written by the absent-config path but never verified by the repair path"
done <<<"$cfg_writer_keys"
echo "PASS: 6i the repair path verifies EVERY key the absent-config writer sets, and derives model+dimensions from the same single pin"

# --- 6j. a config that is NOT a JSON object degrades: warn, leave alone, rc=0 --
# The header contracts a warn-and-leave-alone path for a config the repair
# cannot safely merge onto, and two shapes reaching it are easy to get wrong:
#   * EMPTY / whitespace-only — `jq . ` exits 0 with EMPTY output on these, so a
#     bare parseability guard reports the posture verified while bm, reading a
#     truncated config, falls back to ITS OWN defaults (sync_changes and
#     ensure_frontmatter_on_sync true) — the vault-MUTATION posture. That is the
#     #1211 defect in its worst form: the check is present but cannot see the
#     state it exists to detect, so it must never pass silently.
#   * valid-but-NON-OBJECT (`[]`, `"str"`, a bare number) — parses fine, then
#     fails the key-wise merge with jq's own "Cannot index array", which would
#     turn a recoverable config problem into exit 4 for EVERY search.
# All of them must warn, touch nothing, and return 0.
for bad_case in 'garbage:not json at all' 'empty:' 'blank:   ' 'array:[]' 'string:"str"' 'number:42'; do
  bad_label="${bad_case%%:*}"
  bad_body="${bad_case#*:}"
  printf '%s' "$bad_body" > "$CONFIG"
  bad_before="$(cksum < "$CONFIG")"
  set +e
  err6j="$(_ks_bm_ensure_config 2>&1 1>/dev/null)"
  rc6j=$?
  set -e
  [ "$rc6j" -eq 0 ] \
    || fail "6j/$bad_label: a non-object config must degrade (rc=0), not fail the search outright (rc=$rc6j)"
  [ "$(cksum < "$CONFIG")" = "$bad_before" ] \
    || fail "6j/$bad_label: a config the repair cannot merge onto must be left byte-identical"
  grep -q 'UNVERIFIED' <<<"$err6j" \
    || fail "6j/$bad_label: the degradation must WARN on stderr, never pass silently (got: $err6j)"
done
rm -f "$CONFIG"
_ks_bm_ensure_config || fail "6j: ensure_config should succeed again once the bad configs are cleared"
assert_full_posture "6j" "$CONFIG"
echo "PASS: 6j a non-object config (garbage/empty/whitespace/array/string/number) warns UNVERIFIED, is left byte-identical, and never fails the search"

# --- 7. env belt-and-suspenders (point 1) + isolated HOME (point 6) reach the subprocess -
grep -q "BASIC_MEMORY_DISABLE_PERMALINKS=true" "$FAKE_BM_LOG" \
  || fail "7: subprocess never saw BASIC_MEMORY_DISABLE_PERMALINKS=true"
grep -q "HOME=$BM_HOME\$" "$FAKE_BM_LOG" \
  || fail "7: subprocess HOME was not pinned to the isolated basic-memory home ($BM_HOME)"
echo "PASS: 7 the subprocess env carries the belt-and-suspenders disable-permalinks flag and the isolated HOME"

# --- 8. never invokes the mcp subcommand (point 4) ---------------------------
! grep -qE '^ARGS:.* mcp( |$)' "$FAKE_BM_LOG" || fail "8: found a 'basic-memory mcp' invocation -- adapter must be CLI-only"
echo "PASS: 8 no call in this test run ever invoked 'basic-memory mcp' (sidesteps upstream #1017)"

# --- 9. every invocation runs the PINNED, INSTALLED entry point (point 5) ----
# Since temperloop#1113 the pins are asserted at INSTALL time rather than
# re-passed per run, so the per-call assertion moves with them: every call
# must be the adapter's own installed shim (absolute path under the isolated
# home, never a PATH lookup), and that shim must be the one the configured
# pins installed.
total_calls="$(grep -c '^ARGS:' "$FAKE_BM_LOG")"
[ "$total_calls" -gt 0 ] || fail "9: expected at least one subprocess call in the log"
bin_calls="$(grep -c "^BIN=$BM_BIN\$" "$FAKE_BM_LOG" || true)"
[ "$total_calls" -eq "$bin_calls" ] \
  || fail "9: not every call ran the installed entry point at $BM_BIN (total=$total_calls installed=$bin_calls)"
pinned_calls="$(grep -c "^INSTALLED=basic-memory==$KNOWLEDGE_SEARCH_BM_VERSION python=$KNOWLEDGE_SEARCH_BM_PYTHON\$" "$FAKE_BM_LOG" || true)"
[ "$total_calls" -eq "$pinned_calls" ] \
  || fail "9: not every call ran a shim installed at both pins (total=$total_calls pinned=$pinned_calls; expected basic-memory==$KNOWLEDGE_SEARCH_BM_VERSION python=$KNOWLEDGE_SEARCH_BM_PYTHON)"
echo "PASS: 9 every subprocess invocation runs the installed entry point built from the version AND interpreter pins (point 5 + K#368)"

# --- 9b. per-run resolution is GONE (temperloop#1113) ------------------------
# The whole point of the switch: uv's cache must hold no live environment for
# basic-memory, which is only true if nothing resolves it per run. The `uvx`
# tripwire on PATH logs any such attempt.
! grep -q '^FORBIDDEN_UVX' "$FAKE_UV_LOG" \
  || fail "9b: something resolved basic-memory through uvx (log:\n$(grep '^FORBIDDEN_UVX' "$FAKE_UV_LOG"))"
grep -q "^UV_TOOL_DIR=$BM_HOME/" "$FAKE_UV_LOG" \
  || fail "9b: uv tool install did not pin UV_TOOL_DIR inside the isolated home (log:\n$(cat "$FAKE_UV_LOG"))"
grep -q "^UV_TOOL_BIN_DIR=$TOOL_BIN_DIR\$" "$FAKE_UV_LOG" \
  || fail "9b: uv tool install did not pin UV_TOOL_BIN_DIR to $TOOL_BIN_DIR (log:\n$(cat "$FAKE_UV_LOG"))"
grep -q "^HOME=$BM_HOME\$" "$FAKE_UV_LOG" \
  || fail "9b: uv tool install did not run under the isolated HOME ($BM_HOME)"
echo "PASS: 9b nothing resolves basic-memory per run; the install is pinned entirely inside the adapter's isolated home"

# --- 10. backend error: subprocess exits non-zero -> exit 4 -------------------
set +e
out="$(PATH="$BIN:$PATH" FAKE_BM_MODE=search_fail ks_search "anything" 2>/tmp/ks-search-test-err.$$)"
rc=$?
err="$(cat "/tmp/ks-search-test-err.$$")"
rm -f "/tmp/ks-search-test-err.$$"
set -e
[ "$rc" -eq 4 ] || fail "10: a failing subprocess should propagate exit 4 (got $rc)"
[ -z "$out" ] || fail "10: a failing subprocess must print nothing to stdout (got: $out)"
[ -n "$err" ] || fail "10: a failing subprocess should leave a message on stderr"
echo "PASS: 10 a failing basic-memory subprocess call returns exit 4 with nothing on stdout"

# --- 10b. registration failure surfaces the subprocess's own error (K#368) ----
set +e
out="$(PATH="$BIN:$PATH" FAKE_BM_MODE=project_add_fail ks_search "anything" 2>/tmp/ks-search-test-err10b.$$)"
rc=$?
err="$(cat "/tmp/ks-search-test-err10b.$$")"
rm -f "/tmp/ks-search-test-err10b.$$"
set -e
[ "$rc" -eq 4 ] || fail "10b: a failing project registration should exit 4 (got $rc)"
[ -z "$out" ] || fail "10b: a failing registration must print nothing to stdout (got: $out)"
case "$err" in
  *"simulated registration failure detail"*) : ;;
  *) fail "10b: stderr must surface the subprocess's own error, not only the adapter's opaque message (got: $err)" ;;
esac
case "$err" in
  *"project registration failed"*) : ;;
  *) fail "10b: stderr must still carry the adapter's registration-failed message (got: $err)" ;;
esac
echo "PASS: 10b a failing project registration surfaces the subprocess's own error alongside exit 4"

# --- 11. backend error: unparseable output -> exit 4 --------------------------
set +e
out="$(PATH="$BIN:$PATH" FAKE_BM_MODE=bad_json ks_search "anything" 2>/dev/null)"
rc=$?
set -e
[ "$rc" -eq 4 ] || fail "11: unparseable backend output should exit 4 (got $rc)"
[ -z "$out" ] || fail "11: unparseable backend output must print nothing to stdout (got: $out)"
echo "PASS: 11 unparseable basic-memory output returns exit 4 with nothing on stdout"

# --- 12. reindex entry point: incremental (default) and --full ----------------
rm -f "$FAKE_BM_LOG"
PATH="$BIN:$PATH" FAKE_BM_MODE=ok ks_search_reindex >/dev/null || fail "12: incremental reindex should succeed"
grep -q '^REINDEX args=--project test-project$' "$FAKE_BM_LOG" \
  || fail "12: incremental reindex should call reindex WITHOUT --full (log:\n$(cat "$FAKE_BM_LOG"))"
rm -f "$FAKE_BM_LOG"
PATH="$BIN:$PATH" FAKE_BM_MODE=ok ks_search_reindex --full >/dev/null || fail "12b: --full reindex should succeed"
grep -q '^REINDEX args=--full --project test-project$' "$FAKE_BM_LOG" \
  || fail "12b: --full reindex should pass --full through (log:\n$(cat "$FAKE_BM_LOG"))"
echo "PASS: 12 ks_search_reindex drives both incremental (default) and --full rebuilds"

# --- 12c. flag passthrough: --search / --embeddings reach the backend CLI -----
# temperloop#888: the arg loop used to parse ONLY --full and silently shift
# every other argument away, so the 61s `reindex --full --search` shape (full
# rescan + FTS rebuild, no forced full re-embed) was unreachable through the
# public seam — a caller had to reach into the private _ks_bm_run.
rm -f "$FAKE_BM_LOG"
PATH="$BIN:$PATH" FAKE_BM_MODE=ok ks_search_reindex --full --search >/dev/null \
  || fail "12c: --full --search reindex should succeed"
grep -q '^REINDEX args=--full --search --project test-project$' "$FAKE_BM_LOG" \
  || fail "12c: --full --search should reach the CLI as 'reindex --full --search' (log:\n$(cat "$FAKE_BM_LOG"))"

rm -f "$FAKE_BM_LOG"
PATH="$BIN:$PATH" FAKE_BM_MODE=ok ks_search_reindex --full --embeddings >/dev/null \
  || fail "12d: --full --embeddings reindex should succeed"
grep -q '^REINDEX args=--full --embeddings --project test-project$' "$FAKE_BM_LOG" \
  || fail "12d: --full --embeddings should reach the CLI as 'reindex --full --embeddings' (log:\n$(cat "$FAKE_BM_LOG"))"

# Order is normalized, not caller-dependent: --search alone, and the flags
# passed in the reverse order, both emit the same canonical command line.
rm -f "$FAKE_BM_LOG"
PATH="$BIN:$PATH" FAKE_BM_MODE=ok ks_search_reindex --search >/dev/null \
  || fail "12e: --search alone should succeed"
grep -q '^REINDEX args=--search --project test-project$' "$FAKE_BM_LOG" \
  || fail "12e: --search alone should reach the CLI without --full (log:\n$(cat "$FAKE_BM_LOG"))"

rm -f "$FAKE_BM_LOG"
PATH="$BIN:$PATH" FAKE_BM_MODE=ok ks_search_reindex --search --full >/dev/null \
  || fail "12f: reversed flag order should succeed"
grep -q '^REINDEX args=--full --search --project test-project$' "$FAKE_BM_LOG" \
  || fail "12f: flag order should be normalized to --full --search (log:\n$(cat "$FAKE_BM_LOG"))"
echo "PASS: 12c ks_search_reindex forwards --search/--embeddings through to the backend CLI"

# --- 12g. an UNRECOGNISED flag is rejected, never silently discarded ----------
# The pre-#888 loop shifted unknown args away, so a mistyped `--ful` quietly
# ran a reindex the caller never asked for. Now: exit 2 (the contract's
# invalid-usage code), nothing on stdout, and NO backend call at all.
rm -f "$FAKE_BM_LOG"
set +e
out12g="$(PATH="$BIN:$PATH" FAKE_BM_MODE=ok ks_search_reindex --ful 2>/tmp/ks-search-test-err12g.$$)"
rc12g=$?
set -e
err12g="$(cat /tmp/ks-search-test-err12g.$$)"
rm -f /tmp/ks-search-test-err12g.$$
[ "$rc12g" -eq 2 ] || fail "12g: an unrecognised reindex flag should exit 2 (got $rc12g)"
[ -z "$out12g" ] || fail "12g: an unrecognised reindex flag must print nothing to stdout (got: $out12g)"
case "$err12g" in
  *'unrecognised argument "--ful"'*) : ;;
  *) fail "12g: stderr must name the offending argument (got: $err12g)" ;;
esac
[ ! -s "$FAKE_BM_LOG" ] \
  || fail "12g: an unrecognised flag must NOT reach the backend at all (log:\n$(cat "$FAKE_BM_LOG"))"
echo "PASS: 12g ks_search_reindex rejects an unrecognised flag (exit 2) instead of silently discarding it"

# --- 13. reindex degrades the same way as search when uvx is missing ----------
set +e
out="$(PATH="$EMPTY_BIN" ks_search_reindex 2>/tmp/ks-search-test-err2.$$)"
rc=$?
err="$(cat /tmp/ks-search-test-err2.$$)"
rm -f /tmp/ks-search-test-err2.$$
set -e
[ "$rc" -eq 3 ] || fail "13: reindex with no uvx should exit 3 (got $rc)"
[ -z "$out" ] || fail "13: reindex with no uvx must print nothing to stdout (got: $out)"
case "$err" in
  "skipped — knowledge_search unavailable"*) : ;;
  *) fail "13: reindex stderr must begin with the 'skipped —' notice (got: $err)" ;;
esac
echo "PASS: 13 ks_search_reindex degrades legibly the same way ks_search does (exit 3, skipped notice)"

# --- 14. rg fallback surfaces a literal corpus match on a backend zero-result -
# foundation#950: when the backend returns a legitimate zero-result (exit 0,
# empty), ks_search falls back to ripgrep over the corpus and reshapes hits into
# the SAME JSONL contract, with score=0 marking a lexical fallback. Guarded on
# rg being installed (the feature is a no-op without it — fail-open).
if command -v rg >/dev/null 2>&1; then
  mkdir -p "$ROOT/Decisions"
  printf '# Widget cache decision\n\nThe frobnicator uses a widget cache.\n' > "$ROOT/Decisions/widget-cache.md"
  rm -f "$FAKE_BM_LOG" "$FAKE_BM_LOG.registered"
  out14="$(PATH="$BIN:$PATH" FAKE_BM_MODE=empty_results ks_search "frobnicator" --limit 5 2>/dev/null)" \
    || fail "14: rg fallback path should exit 0"
  [ -n "$out14" ] || fail "14: rg fallback should surface the literal match (got empty)"
  fdoc="$(printf '%s\n' "$out14" | sed -n '1p' | jq -r '.doc_id')"
  fscore="$(printf '%s\n' "$out14" | sed -n '1p' | jq -r '.score')"
  [ "$fdoc" = "Decisions/widget-cache.md" ] \
    || fail "14: fallback doc_id should be the corpus-relative path (got: $fdoc)"
  [ "$fscore" = "0" ] || fail "14: fallback score should be the 0 sentinel (got: $fscore)"
  fb_search="$(grep -c '^SEARCH ' "$FAKE_BM_LOG" || true)"
  [ "$fb_search" -eq 1 ] \
    || fail "14: fallback must not issue extra backend subprocesses (got $fb_search); log:\n$(cat "$FAKE_BM_LOG")"
  echo "PASS: 14 rg fallback surfaces a literal corpus match on a backend zero-result (foundation#950)"
else
  echo "SKIP: 14 rg fallback assertion (ripgrep not installed)"
fi

# --- 14b. rg fallback is fail-open: zero-result with no corpus match -> empty --
rm -rf "${ROOT:?}/Decisions"
rm -f "$FAKE_BM_LOG" "$FAKE_BM_LOG.registered"
out14b="$(PATH="$BIN:$PATH" FAKE_BM_MODE=empty_results ks_search "no-such-literal-xyzzy" --limit 5 2>/dev/null)" \
  || fail "14b: a zero-result with no fallback match must still exit 0"
[ -z "$out14b" ] || fail "14b: no backend match and no rg match must print nothing (got: $out14b)"
echo "PASS: 14b rg fallback is fail-open — no backend match and no corpus match yields empty, exit 0"

# --- 14c. fallback must not trip a caller's set -e on the no-match path --------
# The lib is SOURCED into scripts owning `set -euo pipefail`. On a no-match rg
# exits 1, so the fallback's `hits=$(… rg … | jq | head)` pipeline exits non-zero
# under pipefail — unguarded, it would abort the caller (foundation#950 shell-
# review; the `|| true` is the guard). This runs in a SEPARATE process where
# set -e is genuinely active (an inline `$(…) || fail` would put the subshell in
# a set-e-IGNORED context — bash: an explicit `set -e` there has no effect — and
# could never catch the regression), and calls the fallback DIRECTLY (the via-
# ks_search command-substitution layer masks the abort; the direct call is the
# proven-teeth form). Pointed at a guaranteed-EMPTY store so rg deterministically
# misses. Verified: with the `|| true` guard this exits 0 + SURVIVED; without it,
# the consumer aborts (exit 1, no SURVIVED).
if command -v rg >/dev/null 2>&1; then
  mkdir -p "$TMP/empty-store-14c"
  CONSUMER="$TMP/consumer_14c.sh"
  cat > "$CONSUMER" <<EOF
#!/usr/bin/env bash
set -euo pipefail
export KNOWLEDGE_STORE_ROOT="$TMP/empty-store-14c"
source "$STORE_LIB"
source "$SEARCH_LIB"
ks_search__rg_fallback "no-such-literal-xyzzy" --limit 5
printf 'SURVIVED:[]\n'
EOF
  set +e
  cons_out="$(bash "$CONSUMER" 2>/dev/null)"
  cons_rc=$?
  set -e
  [ "$cons_rc" -eq 0 ] \
    || fail "14c: the rg-fallback no-match path aborted a set -e caller (exit $cons_rc) — missing '|| true' guard?"
  [ "$cons_out" = "SURVIVED:[]" ] \
    || fail "14c: caller should survive to the marker with an empty result (got: $cons_out)"
  echo "PASS: 14c rg-fallback no-match does not trip a sourced caller's set -e (caller survives)"
else
  echo "SKIP: 14c set -e no-match survival (ripgrep not installed)"
fi

# --- 15. post-fetch re-rank (temperloop#1446) ---------------------------------
# The re-rank is the ranking lever from the #1445 mode-sweep verdict: fetch
# deeper than the caller asked for, reorder, return exactly --limit. These cases
# pin the three properties the frozen contract depends on — record shape is
# passed through untouched, the score-0 rg sentinel is NEVER reordered, and the
# off-switch restores byte-identical pre-#1446 behavior — plus the fetch-depth
# wiring on the cold CLI path.
rr_in() {
  printf '%s\n' \
    '{"doc_id":"Decisions/unrelated thing.md","title":"unrelated thing","score":1.28,"snippet":"a"}' \
    '{"doc_id":"Decisions/board adapter cache split.md","title":"board adapter cache split","score":0.61,"snippet":"b"}'
}

# 15a. a title-agreeing candidate is promoted over a higher-SCORING one. This is
# the whole point of the lever, and it also proves the re-ranker never reads
# .score (trap 1: hybrid scores are query-relative, so 1.28 > 0.61 must not be
# treated as evidence across candidates).
out15a="$(rr_in | _ks_bm_rerank "board adapter cache split" 5)"
[ "$(printf '%s' "$out15a" | head -1 | jq -r '.doc_id')" = "Decisions/board adapter cache split.md" ] \
  || fail "15a: the title-agreeing candidate should re-rank to the top (got: $out15a)"
echo "PASS: 15a re-rank promotes a title-agreeing candidate over a higher-scoring one"

# 15b. RECORD SHAPE IS FROZEN — each surviving record must come out byte-for-byte
# as it went in (only the ORDER and which k survive may change). A re-ranker that
# rebuilt records instead of passing them through would silently break the
# published {doc_id,title,score,snippet} JSONL contract.
in15b="$(rr_in)"
out15b="$(rr_in | _ks_bm_rerank "board adapter cache split" 5 | sort)"
[ "$out15b" = "$(printf '%s' "$in15b" | sort)" ] \
  || fail "15b: re-rank altered record bytes; the JSONL contract is frozen (got: $out15b)"
echo "PASS: 15b re-rank preserves every record byte-for-byte (order-only change)"

# 15c. TRAP 2 — the score-0 rg-fallback sentinel is a PROVENANCE marker, not a
# relevance value. A set carrying one is passed through in backend order, so a
# fallback hit can never be reordered against (or above) backend results.
out15c="$(printf '%s\n' \
  '{"doc_id":"z.md","title":"zzz nothing","score":0,"snippet":"a"}' \
  '{"doc_id":"board adapter.md","title":"board adapter","score":0,"snippet":"b"}' \
  | _ks_bm_rerank "board adapter" 5)"
[ "$(printf '%s' "$out15c" | head -1 | jq -r '.doc_id')" = "z.md" ] \
  || fail "15c: a score-0 sentinel set must NOT be reordered (got: $out15c)"
echo "PASS: 15c the score-0 rg-fallback sentinel is never reordered"

# 15d. the off-switch is a true no-op, and k truncation still applies.
out15d="$(rr_in | KNOWLEDGE_SEARCH_RERANK=0 _ks_bm_rerank "board adapter cache split" 5)"
[ "$out15d" = "$in15b" ] \
  || fail "15d: KNOWLEDGE_SEARCH_RERANK=0 must return the backend order untouched (got: $out15d)"
n15d="$(rr_in | _ks_bm_rerank "board adapter cache split" 1 | wc -l | tr -d ' ')"
[ "$n15d" = "1" ] || fail "15d: re-rank must return exactly k records (got $n15d)"
echo "PASS: 15d re-rank off-switch is a no-op; on, it returns exactly k records"

# 15e. FETCH DEPTH reaches the subprocess: the caller asks for 5, the backend is
# asked for KNOWLEDGE_SEARCH_RERANK_DEPTH. Asserted against the fake uvx's own
# argv log, so this pins the wiring rather than the intent.
rm -f "$FAKE_BM_LOG" "$FAKE_BM_LOG.registered"
PATH="$BIN:$PATH" KNOWLEDGE_SEARCH_RERANK=1 KNOWLEDGE_SEARCH_RERANK_DEPTH=20 \
  ks_search "hybrid probe" --limit 5 >/dev/null 2>&1 || true
grep -q -- "--page-size 20" "$FAKE_BM_LOG" \
  || fail "15e: cold path must fetch RERANK_DEPTH (20), not the caller's --limit (log: $(cat "$FAKE_BM_LOG"))"
rm -f "$FAKE_BM_LOG" "$FAKE_BM_LOG.registered"
PATH="$BIN:$PATH" KNOWLEDGE_SEARCH_RERANK=0 \
  ks_search "hybrid probe" --limit 5 >/dev/null 2>&1 || true
grep -q -- "--page-size 5" "$FAKE_BM_LOG" \
  || fail "15e: with the re-rank off, fetch depth must collapse back to --limit (log: $(cat "$FAKE_BM_LOG"))"
echo "PASS: 15e fetch depth is RERANK_DEPTH when on and the caller's --limit when off"

# --- 16. abstention floor (foundation#1450, epic foundation#1443) ------------
# Below the measured floor (both the top-ranked candidate's score AND its
# lexical-coverage feature L must fail — see knowledge_search.sh's
# "## Abstention floor" comment for the measured rationale), _ks_bm_rerank
# emits the {"__ks_abstain":true} sentinel instead of the normal stream.

abstain_low_in() {
  printf '%s\n' \
    '{"doc_id":"Decisions/unrelated thing.md","title":"unrelated thing","score":0.65,"snippet":"a"}' \
    '{"doc_id":"Decisions/another unrelated.md","title":"another unrelated","score":0.60,"snippet":"b"}'
}

# 16a. default (KNOWLEDGE_SEARCH_ABSTAIN unset) is a true no-op — byte-identical
# to pre-#1450 behavior even when every candidate is low-confidence.
out16a="$(abstain_low_in | _ks_bm_rerank "widget install guide" 5)"
[ "$out16a" = "$(abstain_low_in)" ] \
  || fail "16a: KNOWLEDGE_SEARCH_ABSTAIN unset must be a true no-op (got: $out16a)"
echo "PASS: 16a abstention floor is a true no-op when KNOWLEDGE_SEARCH_ABSTAIN is unset (default)"

# 16b. enabled + both floors fail -> the sentinel, and ONLY the sentinel.
out16b="$(abstain_low_in | KNOWLEDGE_SEARCH_ABSTAIN=1 _ks_bm_rerank "widget install guide" 5)"
[ "$out16b" = '{"__ks_abstain":true}' ] \
  || fail "16b: both floors failing should abstain (got: $out16b)"
echo "PASS: 16b enabled + both floors fail -> the {__ks_abstain:true} sentinel"

# 16c. enabled but the SCORE floor clears -> no abstain (score alone is enough
# to save a candidate; the gate is a conjunction, not a single surface).
out16c="$(printf '%s\n' \
    '{"doc_id":"Decisions/unrelated thing.md","title":"unrelated thing","score":0.90,"snippet":"a"}' \
    '{"doc_id":"Decisions/another unrelated.md","title":"another unrelated","score":0.60,"snippet":"b"}' \
  | KNOWLEDGE_SEARCH_ABSTAIN=1 _ks_bm_rerank "widget install guide" 5)"
[ "$(printf '%s' "$out16c" | head -1 | jq -r '.doc_id')" = "Decisions/unrelated thing.md" ] \
  || fail "16c: a cleared score floor must not abstain (got: $out16c)"
echo "PASS: 16c enabled + score floor clears -> no abstain"

# 16d. enabled but the LEX floor clears (title agrees with the query) -> no
# abstain, even though the score is low.
out16d="$(printf '%s\n' \
    '{"doc_id":"Decisions/widget install guide.md","title":"widget install guide","score":0.65,"snippet":"a"}' \
    '{"doc_id":"Decisions/another unrelated.md","title":"another unrelated","score":0.60,"snippet":"b"}' \
  | KNOWLEDGE_SEARCH_ABSTAIN=1 _ks_bm_rerank "widget install guide" 5)"
[ "$(printf '%s' "$out16d" | head -1 | jq -r '.doc_id')" = "Decisions/widget install guide.md" ] \
  || fail "16d: a cleared lexical floor must not abstain (got: $out16d)"
echo "PASS: 16d enabled + lexical floor clears -> no abstain"

# 16e. TRAP 2 still holds with the gate enabled: a score-0 rg-sentinel set is
# the bypass branch, never reaches the abstention gate at all.
out16e="$(printf '%s\n' '{"doc_id":"z.md","title":"zzz nothing","score":0,"snippet":"a"}' \
  | KNOWLEDGE_SEARCH_ABSTAIN=1 _ks_bm_rerank "widget install guide" 5)"
[ "$(printf '%s' "$out16e" | jq -r '.doc_id')" = "z.md" ] \
  || fail "16e: the score-0 sentinel bypass must never reach the abstention gate (got: $out16e)"
echo "PASS: 16e the abstention gate never touches the score-0 rg-fallback bypass"

# 16f. FULL ks_search integration: the sentinel never leaks to a real caller —
# enabled + failing floors returns genuine empty stdout, exit 0, via the
# fake uvx's low_conf canned response.
rm -f "$FAKE_BM_LOG" "$FAKE_BM_LOG.registered"
out16f="$(PATH="$BIN:$PATH" FAKE_BM_MODE=low_conf KNOWLEDGE_SEARCH_ABSTAIN=1 \
  ks_search "widget install guide" --limit 5)"
rc16f=$?
[ "$rc16f" -eq 0 ] || fail "16f: an abstained ks_search call must still exit 0 (got $rc16f)"
[ -z "$out16f" ] || fail "16f: the sentinel must never reach a real ks_search caller (got: $out16f)"
echo "PASS: 16f ks_search never leaks the abstention sentinel; exit 0 with empty stdout"

# --- 17. project partition / scoped search (temperloop#418) ------------------
# The confidentiality seam: ks_search's corpus is the whole resolved ks_root,
# so an operator running one $HOME across engagements could have a query typed
# in client B's session rank and return client A's notes. These cases are
# BEHAVIOURAL — each asserts what came back and, critically, what did NOT.

# 17a. THE POSITIVE BEHAVIOURAL SENTINEL. Two partitions are in the corpus and
# both are in the backend's candidate set; a search scoped to `acme` returns
# acme's note and the OTHER partition's notes are ABSENT. A no-op filter, or a
# scope flag silently discarded somewhere down the stack, fails here — which a
# flag-parses-only assertion would not catch.
rm -f "$FAKE_BM_LOG" "$FAKE_BM_LOG.registered"
out17a="$(PATH="$BIN:$PATH" FAKE_BM_MODE=two_partitions \
  ks_search "retainer terms" --limit 5 --partition acme)" \
  || fail "17a: a scoped ks_search should succeed"
docs17a="$(printf '%s\n' "$out17a" | jq -r '.doc_id' | sort | tr '\n' '|')"
[ "$docs17a" = "Decisions/acme - retainer terms.md|" ] \
  || fail "17a: scoped search must return ONLY the acme partition (got: $docs17a)"
grep -q 'zenith' <<<"$out17a" \
  && fail "17a: CROSS-PARTITION BLEED — a zenith note reached an acme-scoped search:\n$out17a"
grep -q 'Index.md' <<<"$out17a" \
  && fail "17a: an UNPARTITIONED note reached a scoped search (must fail closed):\n$out17a"
echo "PASS: 17a a scoped ks_search returns only its own partition — the other partition's note is ABSENT"

# 17b. NO REGRESSION for the dominant single-tenant user: with no partition
# configured, the identical query returns the whole unfiltered candidate set,
# exactly as it did pre-#418.
rm -f "$FAKE_BM_LOG" "$FAKE_BM_LOG.registered"
out17b="$(PATH="$BIN:$PATH" FAKE_BM_MODE=two_partitions ks_search "retainer terms" --limit 5)" \
  || fail "17b: an unscoped ks_search should succeed"
n17b="$(printf '%s\n' "$out17b" | wc -l | tr -d ' ')"
[ "$n17b" -eq 4 ] \
  || fail "17b: unpartitioned search must return all 4 candidates untouched (got $n17b): $out17b"
echo "PASS: 17b default (no partition configured) is unchanged — the whole corpus, no filtering"

# 17c. the DIRECTORY membership form is honoured alongside the filename form:
# scoping to `zenith` returns both `Decisions/zenith - …md` and `zenith/…`.
rm -f "$FAKE_BM_LOG" "$FAKE_BM_LOG.registered"
out17c="$(PATH="$BIN:$PATH" FAKE_BM_MODE=two_partitions \
  ks_search "retainer terms" --limit 5 --partition zenith)" \
  || fail "17c: a zenith-scoped ks_search should succeed"
docs17c="$(printf '%s\n' "$out17c" | jq -r '.doc_id' | sort | tr '\n' '|')"
[ "$docs17c" = "Decisions/zenith - retainer terms.md|zenith/Decisions/rates.md|" ] \
  || fail "17c: both membership forms should match for zenith (got: $docs17c)"
grep -q 'acme' <<<"$out17c" \
  && fail "17c: CROSS-PARTITION BLEED — an acme note reached a zenith-scoped search:\n$out17c"
echo "PASS: 17c partition membership matches both the '<project> - ' filename form and the '<project>/' directory form"

# 17d. the ENV route (KNOWLEDGE_SEARCH_PARTITION) scopes just as hard as the
# flag — this is the route a consultant actually uses (export once per
# engagement), so it must not be a second, weaker path.
rm -f "$FAKE_BM_LOG" "$FAKE_BM_LOG.registered"
out17d="$(PATH="$BIN:$PATH" FAKE_BM_MODE=two_partitions KNOWLEDGE_SEARCH_PARTITION=acme \
  ks_search "retainer terms" --limit 5)" \
  || fail "17d: an env-scoped ks_search should succeed"
[ "$(printf '%s\n' "$out17d" | jq -r '.doc_id' | sort | tr '\n' '|')" = "Decisions/acme - retainer terms.md|" ] \
  || fail "17d: KNOWLEDGE_SEARCH_PARTITION must scope as hard as --partition (got: $out17d)"
echo "PASS: 17d KNOWLEDGE_SEARCH_PARTITION scopes every call, identically to the per-call flag"

# --- 17e-17h. FAIL-CLOSED: the load-bearing half ------------------------------
# An unrecognised or unhonoured scope argument must ERROR, never widen the
# corpus. The pre-#418 loop ended in `*) shift ;;`, so a scope flag a layer did
# not understand was DISCARDED and the full corpus came back at exit 0 — a
# silent confidentiality failure dressed as a successful scoped search. Same
# rejection shape as ks_search_reindex's (temperloop#888, case 12g).

# 17e. an unrecognised ks_search argument -> exit 2, nothing on stdout, and NO
# backend call at all.
rm -f "$FAKE_BM_LOG" "$FAKE_BM_LOG.registered"
set +e
out17e="$(PATH="$BIN:$PATH" FAKE_BM_MODE=two_partitions ks_search "retainer terms" --scope acme 2>/tmp/ks-search-test-err17e.$$)"
rc17e=$?
set -e
err17e="$(cat /tmp/ks-search-test-err17e.$$)"; rm -f /tmp/ks-search-test-err17e.$$
[ "$rc17e" -eq 2 ] || fail "17e: an unrecognised ks_search argument must exit 2 (got $rc17e)"
[ -z "$out17e" ] || fail "17e: an unrecognised argument must return NOTHING, never the unfiltered corpus (got: $out17e)"
case "$err17e" in
  *'unrecognised argument "--scope"'*) : ;;
  *) fail "17e: stderr must name the offending argument (got: $err17e)" ;;
esac
[ ! -s "$FAKE_BM_LOG" ] \
  || fail "17e: an unrecognised argument must not reach the backend (log:\n$(cat "$FAKE_BM_LOG"))"
echo "PASS: 17e ks_search rejects an unrecognised argument (exit 2, no results, no backend call)"

# 17f. an EMPTY --partition value is rejected, never read as "no partition" —
# the `--partition "$CLIENT"` that expanded to nothing must fail loudly rather
# than silently widen back to the whole corpus.
rm -f "$FAKE_BM_LOG" "$FAKE_BM_LOG.registered"
set +e
out17f="$(PATH="$BIN:$PATH" FAKE_BM_MODE=two_partitions ks_search "retainer terms" --partition "" 2>/dev/null)"
rc17f=$?
out17f2="$(PATH="$BIN:$PATH" FAKE_BM_MODE=two_partitions ks_search "retainer terms" --partition 2>/dev/null)"
rc17f2=$?
set -e
[ "$rc17f" -eq 2 ]  || fail "17f: an empty --partition value must exit 2, never widen the corpus (got $rc17f)"
[ -z "$out17f" ]    || fail "17f: an empty --partition must return nothing (got: $out17f)"
[ "$rc17f2" -eq 2 ] || fail "17f: a valueless --partition must exit 2 (got $rc17f2)"
[ -z "$out17f2" ]   || fail "17f: a valueless --partition must return nothing (got: $out17f2)"
[ ! -s "$FAKE_BM_LOG" ] \
  || fail "17f: a malformed --partition must not reach the backend (log:\n$(cat "$FAKE_BM_LOG"))"
echo "PASS: 17f an empty or valueless --partition is rejected (exit 2), never silently widened to the whole corpus"

# 17g. the BACKENDS refuse the scope flag rather than swallowing it. Enforcement
# lives in ks_search, above every backend, precisely so a backend cannot fail
# open by not implementing the scope — and each backend loop now rejects what it
# does not recognise, so the old `*) shift ;;` widening cannot come back through
# a direct backend call either.
set +e
PATH="$BIN:$PATH" FAKE_BM_MODE=two_partitions \
  _ks_search_backend_basic_memory_search "retainer terms" --partition acme >/dev/null 2>&1
rc17g=$?
set -e
[ "$rc17g" -eq 2 ] \
  || fail "17g: the cold backend must REJECT --partition (exit 2), not silently discard it (got $rc17g)"
echo "PASS: 17g the backend rejects a scope flag it does not implement instead of returning the unfiltered corpus"

# 17h. the capability probe exists, so a caller can tell a library that HONOURS
# the scope from a pre-#418 one that would silently ignore it (the one skew the
# adapter cannot close from inside).
command -v ks_search_partition_supported >/dev/null \
  || fail "17h: ks_search_partition_supported must be defined as the version-skew probe"
ks_search_partition_supported || fail "17h: ks_search_partition_supported should exit 0 on this library"
echo "PASS: 17h ks_search_partition_supported is the command -v version-skew probe for scope support"

# --- 17i. the filter itself fails CLOSED --------------------------------------
# If the filter cannot run at all (no jq), it must yield NOTHING and a non-zero
# return — never pass the unfiltered stream through. Driven directly, with jq
# removed from PATH, since that is the only way to force the failure.
PART_IN="$TMP/part-in.jsonl"
cat > "$PART_IN" <<'JSONL'
{"doc_id":"Decisions/acme - retainer terms.md","title":"acme - retainer terms","score":1.2,"snippet":"a"}
{"doc_id":"Decisions/zenith - retainer terms.md","title":"zenith - retainer terms","score":1.1,"snippet":"z"}
JSONL
set +e
out17i="$(PATH="$EMPTY_BIN" ks_search__partition_filter acme < "$PART_IN" 2>/dev/null)"
rc17i=$?
set -e
[ "$rc17i" -ne 0 ] || fail "17i: a filter that cannot run must return non-zero (got $rc17i)"
[ -z "$out17i" ] || fail "17i: a failed filter must emit NOTHING, never the unfiltered stream (got: $out17i)"
# And a record with no usable doc_id is excluded rather than trusted.
out17i2="$(printf '%s\n' '{"title":"no doc id","score":1.0,"snippet":"x"}' \
  | ks_search__partition_filter acme)"
[ -z "$out17i2" ] || fail "17i: a record with no doc_id must be excluded (got: $out17i2)"
echo "PASS: 17i the partition filter fails closed — a filter it cannot run, or a record it cannot attribute, returns nothing"

# --- 17j. the rg LEXICAL FALLBACK stream is filtered too ----------------------
# The degraded path is a real leak surface: a backend zero-result falls back to
# a ripgrep sweep of the corpus, and an unfiltered fallback would hand back the
# other client's notes precisely when the semantic path found nothing. Driven
# in a SEPARATE process with the fallback stubbed to a known two-partition
# stream, so this holds whether or not ripgrep is installed on the host.
CONSUMER17="$TMP/consumer_17j.sh"
cat > "$CONSUMER17" <<EOF
#!/usr/bin/env bash
set -euo pipefail
export KNOWLEDGE_STORE_ROOT="$ROOT"
export KNOWLEDGE_SEARCH_BM_HOME="$BM_HOME"
export KNOWLEDGE_SEARCH_BM_PROJECT="test-project"
export KNOWLEDGE_READ_LOG="$TMP/knowledge-reads-17j.log"
export FAKE_BM_LOG="$TMP/bm-17j.log"
export FAKE_UV_LOG="$TMP/uv-17j.log"
export FAKE_BM_TEMPLATE="$FAKE_BM_TEMPLATE"
export FAKE_BM_MODE=empty_results
export PATH="$BIN:\$PATH"
source "$STORE_LIB"
source "$SEARCH_LIB"
# Stub the fallback with a canned two-partition lexical hit set (score 0 is the
# fallback provenance sentinel, exactly as the real one emits).
ks_search__rg_fallback() {
  printf '%s\n' \\
    '{"doc_id":"Decisions/acme - retainer terms.md","title":"acme - retainer terms","score":0,"snippet":"a"}' \\
    '{"doc_id":"Decisions/zenith - retainer terms.md","title":"zenith - retainer terms","score":0,"snippet":"z"}'
}
ks_search "retainer terms" --limit 5 --partition acme
EOF
out17j="$(bash "$CONSUMER17" 2>/dev/null)" || fail "17j: the scoped fallback path should exit 0"
[ "$(printf '%s\n' "$out17j" | jq -r '.doc_id' | sort | tr '\n' '|')" = "Decisions/acme - retainer terms.md|" ] \
  || fail "17j: the rg lexical fallback must be partition-filtered too (got: $out17j)"
grep -q 'zenith' <<<"$out17j" \
  && fail "17j: CROSS-PARTITION BLEED via the rg lexical fallback:\n$out17j"
echo "PASS: 17j the rg lexical-fallback stream is partition-filtered too — the degraded path cannot leak"

# ── 18. uv-tool install lifecycle (temperloop#1113) ─────────────────────────
# Four states the install seam can be in, each discriminated independently:
# pin-absent-then-installed, pin-already-installed, pin-changed-so-repinned,
# and install-fails-so-degrades. Every one is driven by the fake `uv` above —
# no network, no real `uv tool install`, no live index (kernel principle 3).

# --- 18a. pin ABSENT -> the availability gate installs it on first use --------
# The zero-setup guarantee: a stranger with only uv on PATH and no doctor run
# still answers their first ks_search. Nothing is pre-installed here.
rm -rf "$BM_HOME"
rm -f "$FAKE_BM_LOG" "$FAKE_BM_LOG.registered" "$FAKE_UV_LOG"
[ ! -e "$BM_BIN" ] || fail "18a: fixture error — the entry point should not exist yet"
out18a="$(PATH="$BIN:$PATH" FAKE_BM_MODE=ok ks_search "orchard" --limit 5 2>/dev/null)" \
  || fail "18a: a first ks_search with nothing installed should still succeed"
[ -n "$out18a" ] || fail "18a: the lazily-installed first search returned no results"
[ -x "$BM_BIN" ] || fail "18a: the gate did not install an entry point at $BM_BIN"
[ -f "$PIN_STAMP" ] || fail "18a: the gate did not record the installed pin at $PIN_STAMP"
[ "$(cat "$PIN_STAMP")" = "basic-memory==$KNOWLEDGE_SEARCH_BM_VERSION python=$KNOWLEDGE_SEARCH_BM_PYTHON" ] \
  || fail "18a: the pin stamp does not name both pins (got: $(cat "$PIN_STAMP"))"
installs18a="$(grep -c '^TOOL_INSTALL ' "$FAKE_UV_LOG" || true)"
[ "$installs18a" -eq 1 ] \
  || fail "18a: expected exactly ONE tool install for a cold first search (got $installs18a); log:\n$(cat "$FAKE_UV_LOG")"
grep -q "^TOOL_INSTALL spec=basic-memory==$KNOWLEDGE_SEARCH_BM_VERSION python=$KNOWLEDGE_SEARCH_BM_PYTHON force=1\$" "$FAKE_UV_LOG" \
  || fail "18a: the install did not carry both pins (log:\n$(cat "$FAKE_UV_LOG"))"
echo "PASS: 18a a cold first ks_search lazily installs the pinned uv tool and answers normally (zero-setup preserved)"

# --- 18b. pin ALREADY installed -> no second install, no subprocess cost ------
rm -f "$FAKE_BM_LOG" "$FAKE_BM_LOG.registered" "$FAKE_UV_LOG"
out18b="$(PATH="$BIN:$PATH" FAKE_BM_MODE=ok ks_search "orchard" --limit 5 2>/dev/null)" \
  || fail "18b: a warm ks_search should succeed"
[ -n "$out18b" ] || fail "18b: the warm search returned no results"
[ ! -s "$FAKE_UV_LOG" ] \
  || fail "18b: an already-installed pin must not re-invoke uv at all (log:\n$(cat "$FAKE_UV_LOG"))"
echo "PASS: 18b an already-installed pin is a pure filesystem check — uv is never invoked again"

# --- 18c. pin CHANGED -> re-installed, never silently the old build -----------
# THE regression this switch introduces if left unguarded: under uvx the pin
# was re-asserted every run, so a bump took effect for free. An installed tool
# would happily keep serving the old build forever.
rm -f "$FAKE_BM_LOG" "$FAKE_BM_LOG.registered" "$FAKE_UV_LOG"
out18c="$(PATH="$BIN:$PATH" FAKE_BM_MODE=ok KNOWLEDGE_SEARCH_BM_VERSION=0.23.0 \
  ks_search "orchard" --limit 5 2>/dev/null)" || fail "18c: a search after a pin bump should succeed"
[ -n "$out18c" ] || fail "18c: the re-pinned search returned no results"
grep -q '^TOOL_INSTALL spec=basic-memory==0.23.0 ' "$FAKE_UV_LOG" \
  || fail "18c: a version bump did not re-install (log:\n$(cat "$FAKE_UV_LOG"))"
grep -q '^INSTALLED=basic-memory==0.23.0 ' "$FAKE_BM_LOG" \
  || fail "18c: the bumped search still ran the OLD installed build (log:\n$(cat "$FAKE_BM_LOG"))"
[ "$(cat "$PIN_STAMP")" = "basic-memory==0.23.0 python=$KNOWLEDGE_SEARCH_BM_PYTHON" ] \
  || fail "18c: the pin stamp was not updated to the new pin (got: $(cat "$PIN_STAMP"))"
# The INTERPRETER pin is half of the identity too — bumping it alone re-installs.
rm -f "$FAKE_BM_LOG" "$FAKE_BM_LOG.registered" "$FAKE_UV_LOG"
PATH="$BIN:$PATH" FAKE_BM_MODE=ok KNOWLEDGE_SEARCH_BM_PYTHON=3.12 \
  ks_search "orchard" --limit 5 >/dev/null 2>&1 || fail "18c: a search after an interpreter bump should succeed"
grep -q '^TOOL_INSTALL spec=basic-memory==.* python=3.12 ' "$FAKE_UV_LOG" \
  || fail "18c: an interpreter bump did not re-install (log:\n$(cat "$FAKE_UV_LOG"))"
# Restore the tree to the configured pins for the remaining cases.
rm -f "$FAKE_UV_LOG"
PATH="$BIN:$PATH" FAKE_BM_MODE=ok ks_search "orchard" --limit 5 >/dev/null 2>&1 \
  || fail "18c: restoring the configured pins should succeed"
echo "PASS: 18c changing EITHER pin re-installs and re-stamps — an upgrade never silently keeps running the old build"

# --- 18d. install FAILS -> legible degradation, exit 3, no stdout -------------
# Run inside a command substitution so the adapter's per-process
# failure memo cannot leak into the cases below.
rm -rf "$BM_HOME"
rm -f "$FAKE_BM_LOG" "$FAKE_BM_LOG.registered" "$FAKE_UV_LOG"
set +e
out18d="$(PATH="$BIN:$PATH" FAKE_UV_MODE=install_fail ks_search "orchard" --limit 5 2>/dev/null)"
rc18d=$?
err18d="$(PATH="$BIN:$PATH" FAKE_UV_MODE=install_fail ks_search "orchard" --limit 5 2>&1 1>/dev/null)"
set -e
[ "$rc18d" -eq 3 ] || fail "18d: a failed install should degrade with exit 3 (got $rc18d)"
[ -z "$out18d" ] || fail "18d: a failed install must print NOTHING to stdout (got: $out18d)"
case "$err18d" in
  *"skipped — knowledge_search unavailable"*) : ;;
  *) fail "18d: a failed install must still emit the 'skipped —' notice (got: $err18d)" ;;
esac
case "$err18d" in
  *"simulated resolution failure"*) : ;;
  *) fail "18d: uv's own failure output must be surfaced, not swallowed (got: $err18d)" ;;
esac
[ ! -e "$PIN_STAMP" ] || fail "18d: a failed install must not write a pin stamp"
# ONE attempt per process, not one per gate call (ks_search runs the gate
# twice: the read-log probe and the backend's own gate).
installs18d="$(grep -c '^TOOL_INSTALL ' "$FAKE_UV_LOG" || true)"
[ "$installs18d" -eq 2 ] \
  || fail "18d: expected exactly one install attempt per process (2 processes ran; got $installs18d)"
echo "PASS: 18d a failed install degrades legibly (exit 3, 'skipped —' notice, uv's cause surfaced, no stdout) and is not retried within the process"

# --- 18e. install reports success but produces NO entry point ----------------
rm -rf "$BM_HOME"
rm -f "$FAKE_BM_LOG" "$FAKE_UV_LOG"
set +e
out18e="$(PATH="$BIN:$PATH" FAKE_UV_MODE=install_noop ks_search "orchard" --limit 5 2>/dev/null)"
rc18e=$?
err18e="$(PATH="$BIN:$PATH" FAKE_UV_MODE=install_noop ks_search "orchard" --limit 5 2>&1 1>/dev/null)"
set -e
[ "$rc18e" -eq 3 ] || fail "18e: a no-op install should degrade with exit 3 (got $rc18e)"
[ -z "$out18e" ] || fail "18e: a no-op install must print NOTHING to stdout (got: $out18e)"
case "$err18e" in
  *"no entry point exists at"*) : ;;
  *) fail "18e: the adapter must name the missing entry point (got: $err18e)" ;;
esac
echo "PASS: 18e an install that reports success but writes no entry point is caught, not trusted"

# --- 18f. the install is BOUNDED when a timeout helper is in scope -----------
# knowledge_search.sh refuses to grow a dependency on portable-timeout.sh (it
# is sourced under zsh too, where BASH_SOURCE does not exist), so it probes for
# run_with_timeout and uses it only when the caller already provided one.
rm -rf "$BM_HOME"
rm -f "$FAKE_BM_LOG" "$FAKE_UV_LOG"
TIMEOUT_WITNESS="$TMP/timeout-witness"
rm -f "$TIMEOUT_WITNESS"
run_with_timeout() { printf '%s\n' "$1" > "$TIMEOUT_WITNESS"; shift; "$@"; }
PATH="$BIN:$PATH" FAKE_BM_MODE=ok ks_search "orchard" --limit 5 >/dev/null 2>&1 \
  || fail "18f: the bounded install path should still succeed"
unset -f run_with_timeout
[ -f "$TIMEOUT_WITNESS" ] || fail "18f: run_with_timeout was in scope but the install did not route through it"
[ "$(cat "$TIMEOUT_WITNESS")" = "$KNOWLEDGE_SEARCH_BM_INSTALL_TIMEOUT" ] \
  || fail "18f: the install was not bounded by KNOWLEDGE_SEARCH_BM_INSTALL_TIMEOUT (got: $(cat "$TIMEOUT_WITNESS"))"
echo "PASS: 18f the one-time install is bounded by KNOWLEDGE_SEARCH_BM_INSTALL_TIMEOUT when a timeout helper is in scope"

echo "ALL PASS: knowledge_search.sh (interface + basic-memory backend, mocked subprocess)"
