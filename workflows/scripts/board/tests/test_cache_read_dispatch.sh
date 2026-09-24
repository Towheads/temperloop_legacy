#!/usr/bin/env bash
#
# test_cache_read_dispatch.sh — the cache-read-dispatch item's own suite
# (F#988 Contract, the split that wires board.sh's issues-only whole-board
# read to lib/cache.sh's on-disk issue-cache store). Extends the existing
# issues-only / cache-store coverage (test_issues_backend.sh, test_cache_
# store.sh) with the ONE thing neither of those files can prove alone: that
# _board_issues_item_list's NEW cache-store arm and its pre-existing live arm
# are a genuine "cached vs live" dual-adapter pair — same normalized output,
# selected purely by the `board.<N>.cache` boards.conf axis PLUS whether the
# calling process has separately sourced cache.sh.
#
# Coverage (mirrors the item's acceptance bullets):
#   1. Axis absent -> inert default OFF: byte-identical live read, ZERO
#      cache.sh gh calls, even though cache.sh IS sourced in this process.
#      Axis on + warm store -> ZERO gh calls of EITHER kind (GH_CALL_LOG
#      assert via two independent call logs, board-side and cache-side).
#   2. board_resolve_item stays always-live (claim-lock invariant) regardless
#      of the cache axis / a warm store. Every issues-only write path
#      (board_set_status / board_stamp, and board_create_many /
#      board_capture_item which route through them) calls cache_dirty —
#      grep-audit of lib/board.sh's call sites, plus a live behavioral proof
#      (a warm-and-fresh store goes stale immediately after a write).
#   3. (documented in lib/board.sh + lib/cache.sh headers, not re-asserted as
#      a runtime check here — see _board_issues_item_list's PLANE MAP comment
#      and cache.sh's own PLANE MAP addition.)
#   4. Cached-vs-live parity: the SAME three-issue fixture set fed through
#      the live arm (board 41, axis off) and the cache-store arm (board 40,
#      axis on, warm) produces byte-identical normalized item sets.
#      Degradation path: axis on but cache.sh not "sourced" (simulated by
#      unsetting its function symbols) falls back to the live read, with
#      exactly one stderr notice, output identical to the axis-absent case.
#   5. (documented in ISSUES-ONLY-BACKEND.md / CACHE-STORE.md, not a runtime
#      check here.)
#
# Zero network: overrides BOTH test-injection seams independently —
# `_board_gh` (board.sh's) and `_cache_gh` (cache.sh's) — each logging argv to
# its OWN call-count file, so a call can be attributed to the right layer.
# shellcheck disable=SC2317,SC2329
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$HERE/../lib" && pwd)"
FIX="$HERE/fixtures"

# shellcheck source=scripts/tests/fixtures/fake_gh.sh
# shellcheck disable=SC1091
FAKE_GH_SOURCE=1 source "$FIX/fake_gh.sh"

REPO="Acme/kernel-cache-dispatch-test"   # denylist:allow — generic placeholder org/repo, no personal token

# Isolated stores so this suite never touches a real ~/.cache or a real
# session's $TMPDIR board-item-plane cache.
CACHE_STORE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cache-read-dispatch-store-XXXXXX")"
export CACHE_STORE_ROOT
BOARD_CACHE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cache-read-dispatch-itemcache-XXXXXX")"
export BOARD_CACHE_DIR
export BOARD_CACHE_TTL=0
export BOARD_BUDGET_GUARD_THRESHOLD=0

WORK="$(mktemp -d "${TMPDIR:-/tmp}/cache-read-dispatch-conf-XXXXXX")"
BOARD_CALLS="$(mktemp "${TMPDIR:-/tmp}/cache-read-dispatch-board-calls-XXXXXX")"
CACHE_CALLS="$(mktemp "${TMPDIR:-/tmp}/cache-read-dispatch-cache-calls-XXXXXX")"
STDERR_LOG="$(mktemp "${TMPDIR:-/tmp}/cache-read-dispatch-stderr-XXXXXX")"
cleanup() {
  chmod -R u+w "$CACHE_STORE_ROOT" 2>/dev/null || true
  rm -rf "$CACHE_STORE_ROOT" "$BOARD_CACHE_DIR" "$WORK" \
         "$BOARD_CALLS" "$CACHE_CALLS" "$STDERR_LOG"
}
trap cleanup EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

# Board 40: issues-only + cache=on. Board 41: issues-only, cache axis absent
# (default OFF) — the live-arm control, same repo so the SAME fixture data
# feeds both arms for the parity check.
cat > "$WORK/boards.conf" <<EOF
board.40.repo=$REPO
board.40.backend=issues
board.40.cache=on
board.41.repo=$REPO
board.41.backend=issues
EOF
export BOARDS_CONF_REPO_LOCAL="$WORK/boards.conf"
export BOARDS_CONF_MACHINE="$WORK/no-such-machine-conf"

# shellcheck source=scripts/lib/board.sh
# shellcheck disable=SC1091
source "$LIB_DIR/board.sh"
# shellcheck source=scripts/lib/cache.sh
# shellcheck disable=SC1091
source "$LIB_DIR/cache.sh"

board_calls() { grep -c '^gh ' "$BOARD_CALLS" 2>/dev/null || true; }
list_calls()  { grep -c 'issues?state=all' "$CACHE_CALLS" 2>/dev/null || true; }
comment_calls() { grep -c '/comments?per_page=100 --paginate$' "$CACHE_CALLS" 2>/dev/null || true; }
reset_calls() { : >"$BOARD_CALLS"; : >"$CACHE_CALLS"; : >"$STDERR_LOG"; }

# --- fixture: the SAME three issues for both arms ---------------------------
# Live-arm shape: `gh issue list --json number,title,labels` (no .state field
# — the query already filters --state open, and issue_item() treats a missing
# .state as "open"). Cache-arm shape: raw REST issue rows (cache.sh's own
# storage shape) — DOES carry .state/.updated_at, exactly what a real
# `gh api repos/<r>/issues?state=all` response looks like.
LIVE_ISSUES='[
  {"number":201,"title":"Ready item","labels":[{"name":"fnd:status:ready"},{"name":"spike"}]},
  {"number":202,"title":"Unstatused item","labels":[]},
  {"number":203,"title":"In-progress + component","labels":[{"name":"fnd:status:in-progress"},{"name":"fnd:component:ingest"}]}
]'
CACHE_ISSUES='[
  {"number":201,"title":"Ready item","state":"open","updated_at":"2026-07-01T00:00:00Z","body":"",
   "labels":[{"name":"fnd:status:ready"},{"name":"spike"}]},
  {"number":202,"title":"Unstatused item","state":"open","updated_at":"2026-07-01T00:00:00Z","body":"","labels":[]},
  {"number":203,"title":"In-progress + component","state":"open","updated_at":"2026-07-01T00:00:00Z","body":"",
   "labels":[{"name":"fnd:status:in-progress"},{"name":"fnd:component:ingest"}]}
]'

_board_gh() {
  _fake_gh_log_argv "$@" >>"$BOARD_CALLS"
  case "$1 $2" in
    "issue list") printf '%s' "$LIVE_ISSUES" ;;
    "api repos/$REPO/issues/205")
      echo '{"number":205,"title":"resolve-item probe","state":"open","labels":[]}' ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
_cache_gh() {
  echo "$*" >>"$CACHE_CALLS"
  case "$*" in
    *"issues?state=all"*"--paginate"*) printf '%s' "$CACHE_ISSUES" ;;
    *"/comments?per_page=100 --paginate") echo '[]' ;;
    *) return 1 ;;
  esac
}

# --- 1a: axis ABSENT (board 41) is inert — live read, ZERO cache.sh calls,
# even though cache.sh IS sourced in this very process ----------------------
reset_calls
OUT_LIVE="$(board_item_list 41 2>"$STDERR_LOG")"
[ "$(board_calls)" -eq 1 ] || fail "board_item_list 41 (axis absent) should make exactly 1 gh call, got $(board_calls)"
grep -q '^gh issue list' "$BOARD_CALLS" || fail "board_item_list 41 wrong argv: $(cat "$BOARD_CALLS")"
[ "$(list_calls)" -eq 0 ] && [ "$(comment_calls)" -eq 0 ] \
  || fail "axis-absent board_item_list must make ZERO cache.sh calls (list=$(list_calls) comments=$(comment_calls))"
[ ! -s "$STDERR_LOG" ] || fail "axis-absent board_item_list should emit no stderr notice, got: $(cat "$STDERR_LOG")"
echo "PASS: board.<N>.cache absent is inert (live read, zero cache.sh calls, no stderr)"

# --- 1b: axis ON (board 40), cold store -> ONE cache.sh bulk call, ZERO
# board.sh live gh calls -------------------------------------------------
reset_calls
# Output discarded on purpose -- this case asserts call COUNTS (below), not
# the returned JSON itself.
board_item_list 40 >/dev/null 2>"$STDERR_LOG"
[ "$(board_calls)" -eq 0 ] || fail "board_item_list 40 (cache on, cold) must make ZERO board.sh gh calls, got $(board_calls): $(cat "$BOARD_CALLS")"
[ "$(list_calls)" -eq 1 ] || fail "board_item_list 40 (cold store) should trigger exactly 1 cache.sh bulk list call, got $(list_calls)"
echo "PASS: board.<N>.cache=on (cold store) reads via cache.sh, zero board.sh live gh calls"

# --- 1c: axis ON, WARM store -> ZERO gh calls of EITHER kind (the item's
# headline acceptance bullet) -------------------------------------------
reset_calls
OUT_WARM="$(board_item_list 40 2>"$STDERR_LOG")"
[ "$(board_calls)" -eq 0 ] || fail "board_item_list 40 (warm) must make ZERO board.sh gh calls, got $(board_calls)"
[ "$(list_calls)" -eq 0 ] && [ "$(comment_calls)" -eq 0 ] \
  || fail "board_item_list 40 (warm) must make ZERO cache.sh gh calls (list=$(list_calls) comments=$(comment_calls))"
[ ! -s "$STDERR_LOG" ] || fail "warm cache_read should be silent, got: $(cat "$STDERR_LOG")"
echo "PASS: board.<N>.cache=on + warm store -> board_item_list/board_resolve make ZERO gh calls"

# --- 4a: cached-vs-live parity -----------------------------------------------
NORM='[.items[] | {number: .content.number, title, status, component, labels: (.labels|sort)}]'
NORM_LIVE="$(jq -c "$NORM" <<<"$OUT_LIVE")"
NORM_WARM="$(jq -c "$NORM" <<<"$OUT_WARM")"
[ "$NORM_LIVE" = "$NORM_WARM" ] || fail "cached-vs-live parity: live=$NORM_LIVE${nl:-\n}cached=$NORM_WARM"
echo "PASS: cached-vs-live parity — identical normalized item set (live arm vs warm cache-store arm)"

# --- 4b: degradation path — axis on, cache.sh functions NOT in scope --------
# Simulate "cache.sh was never sourced" without a subshell: unset its public
# function symbols so `command -v cache_read` (the exact predicate board.sh's
# dispatcher checks) reports absent, then restore them afterward.
unset -f cache_read cache_dirty cache_refresh_snapshot cache_refresh_details \
         cache_refresh cache_stale cache_clear cache_read_details \
         cache_repo_dir cache_snapshot_file cache_meta_file cache_details_dir \
         cache_details_file
reset_calls
OUT_DEGRADED="$(board_item_list 40 2>"$STDERR_LOG")"
[ "$(board_calls)" -eq 1 ] || fail "degraded board_item_list 40 should fall back to exactly 1 live gh call, got $(board_calls)"
[ "$(list_calls)" -eq 0 ] || fail "degraded board_item_list 40 must make ZERO cache.sh calls (cache.sh not in scope), got $(list_calls)"
[ "$(grep -c . "$STDERR_LOG")" -eq 1 ] || fail "degraded path should emit exactly 1 stderr notice, got: $(cat "$STDERR_LOG")"
grep -q "cache.sh is not sourced" "$STDERR_LOG" || fail "degraded path stderr notice missing the documented hint: $(cat "$STDERR_LOG")"
NORM_DEGRADED="$(jq -c "$NORM" <<<"$OUT_DEGRADED")"
[ "$NORM_DEGRADED" = "$NORM_LIVE" ] || fail "degradation path output must match the axis-absent live output: degraded=$NORM_DEGRADED${nl:-\n}live=$NORM_LIVE"
echo "PASS: degradation path (cache.sh not sourced) falls back to the live read, one stderr notice, output identical to axis-off"

# Restore cache.sh for the remaining tests.
# shellcheck source=scripts/lib/cache.sh
# shellcheck disable=SC1091
source "$LIB_DIR/cache.sh"

# --- 2a: board_resolve_item stays ALWAYS-LIVE regardless of the cache axis
# or a warm store (the claim-lock invariant) ---------------------------------
reset_calls
board_resolve_item 40 205
[ "$(board_calls)" -eq 1 ] || fail "board_resolve_item 40 should make exactly 1 gh call even with cache=on + warm store, got $(board_calls)"
grep -q "api repos/$REPO/issues/205" "$BOARD_CALLS" || fail "board_resolve_item 40 wrong argv: $(cat "$BOARD_CALLS")"
[ "$(list_calls)" -eq 0 ] && [ "$(comment_calls)" -eq 0 ] \
  || fail "board_resolve_item must never touch the cache.sh store (list=$(list_calls) comments=$(comment_calls))"
echo "PASS: board_resolve_item (issues-only) stays always-live regardless of board.<N>.cache / a warm store"

# --- 2b: grep-audit — every issues-only write path calls cache_dirty -------
# Single-quoted on purpose: this is a grep PATTERN matching the literal text
# `"$repo"` in board.sh's source, not a shell expansion.
# shellcheck disable=SC2016
DIRTY_CALLSITES="$(grep -c '_board_cache_dirty_after_write "\$repo"' "$LIB_DIR/board.sh")"
# 4 sites: set_field + stamp_field (the original pair), plus
# board_add_sub_issue / board_remove_sub_issue (temperloop#1188 — the
# sub-issue linkage writers, matching the same busts-cache-on-write shape).
[ "$DIRTY_CALLSITES" -eq 4 ] || fail "expected exactly 4 _board_cache_dirty_after_write call sites in board.sh (set_field + stamp_field + add_sub_issue + remove_sub_issue), found $DIRTY_CALLSITES"
grep -q '^_board_cache_dirty_after_write() {' "$LIB_DIR/board.sh" || fail "_board_cache_dirty_after_write helper definition missing from board.sh"
echo "PASS: grep-audit — _board_cache_dirty_after_write is defined and called from exactly 4 issues-only write paths"

# --- 2c: live behavioral proof — a write goes through cache_dirty ----------
# Warm the store fresh, confirm it reports NOT stale, then drive a real
# issues-only write (board_set_status via BOARD_CURRENT=40) and confirm the
# store immediately reports stale again — proving cache_dirty actually fired,
# not just that the grep pattern exists.
FAKE_STATE="open"
FAKE_LABELS="fnd:status:ready"
_board_gh() {
  _fake_gh_log_argv "$@" >>"$BOARD_CALLS"
  case "$1 $2" in
    "api repos/$REPO/issues/206")
      local ljson='[]'
      if [ -n "$FAKE_LABELS" ]; then
        ljson="$(printf '%s\n' $FAKE_LABELS | jq -R . | jq -s 'map({name:.})')"
      fi
      printf '{"number":206,"title":"t","state":"%s","labels":%s}' "$FAKE_STATE" "$ljson" ;;
    "issue edit")
      shift 2
      local prev="" a
      for a in "$@"; do
        # shellcheck disable=SC2086  # intentional word-split: iterate the space-separated label list
        case "$prev" in
          --remove-label) FAKE_LABELS="$(printf '%s\n' $FAKE_LABELS | grep -vx "$a" | tr '\n' ' ')" ;;
          --add-label)    FAKE_LABELS="$FAKE_LABELS $a" ;;
        esac
        prev="$a"
      done ;;
    "issue close")  FAKE_STATE="closed" ;;
    "issue reopen") FAKE_STATE="open" ;;
    "label create") : ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
# Read by board_set_status (sourced board.sh) below, not in this file.
# shellcheck disable=SC2034
BOARD_CURRENT=40
cache_stale "$REPO" && fail "setup: store should be fresh (just warmed above) before the write"
board_set_status "ISSUE_206" "In Progress" || fail "board_set_status ISSUE_206 should succeed"
cache_stale "$REPO" || fail "cache_dirty did not fire: store still reports fresh immediately after an issues-only write"
echo "PASS: an issues-only board_set_status write calls cache_dirty (store goes stale immediately, not just at TTL)"

echo
echo "ALL PASS: test_cache_read_dispatch.sh"
