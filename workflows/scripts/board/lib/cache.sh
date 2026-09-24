#!/usr/bin/env bash
#
# cache.sh — canonical-layer issue-cache store: a read cache hoisted ABOVE
# board.sh's backend dispatch (F#988 Contract). One cache mechanism, keyed
# per-repo, backed by the REST issues-list bucket. It is a durable,
# cross-session, two-layer on-disk store of the full issue corpus
# (title/body/state/labels/parent linkage + comments) a later corpus renderer
# or pipeline driver can read without ever hitting GitHub. See CACHE-STORE.md
# (sibling file) for the full on-disk layout, schema, and design rationale.
#
# THE ONLY CACHE IN FRONT OF A BOARD READ. This file's header used to frame
# itself against board.sh's OWN cross-process cache (BOARD_CACHE_TTL /
# _board_cached_read) — a separate, narrower mechanism that existed to relieve
# the Projects-v2 5,000-pt/hr GraphQL budget. That cache was REMOVED together
# with the Projects-v2 arm it protected (ADR 0004, epic temperloop#524), so
# there is no longer another board cache to contrast with: this store is it.
# Nothing about THIS file's behavior changed with that removal — it never rode
# GraphQL and never consulted board.sh's cache; only the framing above did.
#
# PLANE MAP (cache-read-dispatch item): this store serves the ISSUE PLANE —
# the whole GitHub-Issues corpus for a repo — which, now that the Projects-v2
# ITEM PLANE (board-item field values as GraphQL saw them) is gone, is the only
# plane there is (see board.sh's _board_issues_item_list header comment for the
# read-side half of this map).
# board.sh dispatches into THIS store from its issues-only whole-board read
# (_board_issues_item_list) when the caller has sourced cache.sh AND the
# board's boards.conf sets the enable axis `board.<N>.cache=on` — that axis
# lives in board.sh (`_board_cache_store_enabled`), not here: cache.sh itself
# stays boards.conf-agnostic, exactly as before this item (see "Standalone-
# usable seam" below) — board.sh's dispatcher is the only thing that knows
# this axis exists.
#
# Sourced, not executed — same convention as board.sh:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/lib/cache.sh"
#
# Standalone-usable seam: every public function takes a BOARD NUMBER *or* an
# explicit "owner/repo" string as its first argument (_cache_resolve_repo).
#   - "owner/repo" (contains a "/")            -> used verbatim, no board.sh
#     needed. This is the standalone path: cache.sh has ZERO hard dependency
#     on board.sh and never sources it.
#   - a bare board number (e.g. "4")           -> resolved via board.sh's
#     `board_repo()`, IF board.sh has already been sourced in this shell
#     (checked with `command -v board_repo`). If it hasn't, this fails loud
#     with a one-line stderr hint rather than guessing — cache.sh never
#     sources board.sh itself; the caller decides whether to compose them.
# This is what keeps board.sh's own sync set self-contained: a consumer that
# sources ONLY board.sh (no cache.sh) is completely unaffected — cache.sh is
# a pure addition layered on top, never a dependency FROM board.sh.
#
# Function prefix: `cache_` (public), `_cache_` (internal / test seam),
# mirroring board.sh's `board_` / `_board_` split. No side effects on source
# (no directories created, no network) — every write happens lazily inside a
# cache_refresh*/cache_read call.

# --- tuning settings: ENV VARS only (no boards.conf axis here — the per-board
# `board.<N>.cache` enable/disable axis lives in board.sh, which is the sole
# reader of boards.conf; cache.sh stays boards.conf-agnostic, only ever
# governed by env vars and by whichever caller decides to source+call it)
# --------------------------------------------------------------------------
# Store root. Defaults to the XDG cache dir; override wholesale for tests or
# a non-standard layout.
CACHE_STORE_ROOT="${CACHE_STORE_ROOT:-${XDG_CACHE_HOME:-$HOME/.cache}/temperloop}"
# Max-stale window in seconds before a read triggers a refresh. Deliberately
# its OWN var — this is a durable corpus store, with a typically much longer
# staleness budget than the short-TTL GraphQL-relief cache the Projects-v2 arm
# used to carry (removed with that arm — ADR 0004).
CACHE_STORE_TTL="${CACHE_STORE_TTL:-3600}"
# On-disk schema version stamped into every meta.json / details/<n>.json this
# lib writes (CACHE-STORE.md documents the shape each version implies). Bump
# this — and add a migration note in CACHE-STORE.md — before changing the
# on-disk shape in a way an existing store on disk wouldn't already satisfy.
CACHE_STORE_SCHEMA_VERSION=1

# --- the ONE test-injection seam (mirrors board.sh's _board_gh) ----------
# Production runs real gh; tests override this after sourcing to replay
# fixtures / fail on demand, with zero network.
_cache_gh() { gh "$@"; }

# board number OR "owner/repo" -> "owner/repo". See the standalone-seam
# comment above this file's header for the full contract.
_cache_resolve_repo() {
  local arg="$1"
  case "$arg" in
    */*) printf '%s' "$arg"; return 0 ;;
    '')
      echo "cache.sh: empty board/repo argument" >&2
      return 1
      ;;
  esac
  if command -v board_repo >/dev/null 2>&1; then
    board_repo "$arg"
    return $?
  fi
  echo "cache.sh: '$arg' is not an 'owner/repo' and board_repo() is not available — source board.sh first, or pass an explicit owner/repo" >&2
  return 1
}

_cache_repo_slug() {
  printf '%s' "$1" | tr '/' '-'
}

# board number OR "owner/repo", plus an optional store KIND (default
# "issues") -> the top-level store directory name for that kind. Kept as its
# own accessor so the on-disk top-level dir name (currently identical to the
# kind string) is a single decision point, not repeated in cache_repo_dir.
_cache_kind_dir() {
  printf '%s' "${1:-issues}"
}

# --- path accessors (public — a consumer/renderer may want these paths
# directly rather than going through cache_read) --------------------------
# cache_repo_dir <board|owner/repo> [kind]
#
# `kind` namespaces the store by CALLER/PURPOSE, not by data shape — it
# defaults to "issues" (this file's own long-standing consumer) so every
# existing caller (none of which passes a second argument) is byte-for-byte
# unchanged. A second kind (e.g. a state-graph snapshot store) shares
# $CACHE_STORE_ROOT with its own top-level directory and its own meta.json,
# so cache_dirty/cache_clear/cache_stale on one kind never touches the
# other's staleness or contents (temperloop#1910).
cache_repo_dir() {
  local repo kind
  repo="$(_cache_resolve_repo "$1")" || return 1
  kind="$(_cache_kind_dir "${2:-}")"
  printf '%s/%s/%s' "${CACHE_STORE_ROOT%/}" "$kind" "$(_cache_repo_slug "$repo")"
}

cache_snapshot_file() {
  local dir
  dir="$(cache_repo_dir "$1" "${2:-}")" || return 1
  printf '%s/snapshot.jsonl' "$dir"
}

cache_meta_file() {
  local dir
  dir="$(cache_repo_dir "$1" "${2:-}")" || return 1
  printf '%s/meta.json' "$dir"
}

cache_details_dir() {
  local dir
  dir="$(cache_repo_dir "$1")" || return 1
  printf '%s/details' "$dir"
}

cache_details_file() {
  local dir
  dir="$(cache_details_dir "$1")" || return 1
  printf '%s/%s.json' "$dir" "$2"
}

# --- staleness + invalidation API ------------------------------------------
# cache_stale <board|owner/repo> [kind]
# rc 0 = stale (no meta, unparseable meta, or age >= CACHE_STORE_TTL); rc 1 = fresh.
cache_stale() {
  local meta ttl last age
  meta="$(cache_meta_file "$1" "${2:-}")" || return 0
  ttl="${CACHE_STORE_TTL:-3600}"
  [ -f "$meta" ] || return 0
  last="$(jq -r '.last_refresh // 0' "$meta" 2>/dev/null)"
  case "$last" in '' | *[!0-9]*) return 0 ;; esac
  age=$(( $(date +%s) - last ))
  [ "$age" -ge "$ttl" ]
}

# cache_dirty <board|owner/repo> [kind]
# Force the next cache_read to refresh, regardless of age — the soft
# invalidation lever (a write-through caller that just changed an issue calls
# this so the next read doesn't serve a pre-write snapshot). No-op if no
# store exists yet (a miss is already maximally stale). `kind` scopes the
# invalidation to that kind's own meta.json only — dirtying one kind never
# marks a sibling kind under the same repo stale (temperloop#1910).
cache_dirty() {
  local meta tmp
  meta="$(cache_meta_file "$1" "${2:-}")" || return 1
  [ -f "$meta" ] || return 0
  tmp="${meta}.tmp.$$"
  if jq -c --argjson sv "$CACHE_STORE_SCHEMA_VERSION" \
       '.last_refresh = 0 | .schema_version = $sv' "$meta" >"$tmp" 2>/dev/null; then
    mv "$tmp" "$meta"
  else
    rm -f "$tmp" 2>/dev/null
    return 1
  fi
}

# cache_clear <board|owner/repo> [kind]
# Hard invalidation: wipe the entire per-repo store for that kind (snapshot +
# meta + every cached detail). Rarely needed (cache_dirty is the routine
# lever) — for a schema migration or a known-corrupt store. Scoped to `kind`'s
# own directory only — clearing one kind leaves a sibling kind under the same
# repo untouched (temperloop#1910).
cache_clear() {
  local dir
  dir="$(cache_repo_dir "$1" "${2:-}")" || return 1
  rm -rf "$dir"
}

# --- internal: one live REST fetch, filtered, never persisted -------------
# Paginated `gh api repos/<r>/issues?state=all` — includes closed issues,
# excludes PRs (a PR row carries a `.pull_request` key the plain-issues REST
# endpoint doesn't otherwise have). NEVER touches GraphQL, and issues no
# per-issue calls: this is the one bulk call the whole snapshot rides on.
# `--paginate` on an array-returning endpoint emits one JSON array per page;
# `jq -s 'add'` slurps however many top-level arrays came back (one or many)
# and concatenates them into a single array — correct whether gh paginated
# once or a dozen times.
_cache_live_list_raw() {
  local repo="$1" raw
  if ! raw="$(_cache_gh api "repos/$repo/issues?state=all&per_page=100" --paginate 2>/dev/null)"; then
    return 1
  fi
  [ -n "$raw" ] || raw="[]"
  printf '%s' "$raw" | jq -s -c 'add // [] | map(select(has("pull_request") | not))' 2>/dev/null
}

# Persist an already-fetched, already-filtered JSON array to the on-disk
# snapshot + meta. Kept separate from the fetch so a caller (cache_read) can
# tell "the gh call failed" (nothing to serve) apart from "the gh call
# succeeded but the WRITE failed" (disk full / permissions — still have live
# data in hand to serve uncached).
_cache_persist_snapshot() {
  local arg="$1" raw="$2" repo dir snap tmp
  repo="$(_cache_resolve_repo "$arg")" || return 1
  dir="$(cache_repo_dir "$arg")" || return 1
  mkdir -p "$dir/details" 2>/dev/null || return 1
  snap="$dir/snapshot.jsonl"
  tmp="$dir/.snapshot.tmp.$$"
  # stderr-to-null MUST precede the output redirect: if `>"$tmp"` itself
  # fails to open (e.g. a read-only dir), bash reports that failure to
  # whichever stderr is in effect AT THAT POINT in left-to-right redirection
  # processing — a trailing `2>/dev/null` written after `>"$tmp"` is applied
  # too late to catch it, leaking a raw "Permission denied" line that would
  # double up the single stderr notice cache_read's degradation contract
  # promises. Silencing stderr first, then attempting the write, keeps any
  # such shell-level open failure silent so the caller's own one-line notice
  # is the only thing on stderr.
  if ! printf '%s' "$raw" | jq -c '.[]' 2>/dev/null >"$tmp"; then
    rm -f "$tmp" 2>/dev/null
    return 1
  fi
  mv "$tmp" "$snap" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  jq -nc --arg repo "$repo" --argjson ts "$(date +%s)" \
    --argjson sv "$CACHE_STORE_SCHEMA_VERSION" \
    '{schema_version:$sv, repo:$repo, last_refresh:$ts}' \
    >"$dir/meta.json" 2>/dev/null || return 1
}

# --- refresh API ------------------------------------------------------------
# Populate snapshot.jsonl from the bulk REST list (fetch + persist). Public
# so a caller can refresh the cheap snapshot layer without paying the
# per-issue detail-fetch phase (cache_refresh_details, below).
#   rc 0 = fetched and persisted
#   rc 1 = the live gh fetch itself failed (rate limit / auth / network) —
#          nothing to serve
#   rc 2 = the fetch succeeded but the on-disk WRITE failed — the caller
#          still has the fetched data (cache_read's live-fallback path uses
#          this distinction; a direct cache_refresh_snapshot caller that
#          only cares about the store being warm can treat 1 and 2 alike)
cache_refresh_snapshot() {
  local arg="$1" repo raw
  repo="$(_cache_resolve_repo "$arg")" || return 1
  if ! raw="$(_cache_live_list_raw "$repo")"; then
    echo "cache.sh: live read failed (snapshot, $repo) — rate limit or auth?" >&2
    return 1
  fi
  if ! _cache_persist_snapshot "$arg" "$raw"; then
    echo "cache.sh: cache persist failed for $repo (disk/permission?) — not cached" >&2
    return 2
  fi
  return 0
}

# Delta-fetch details (body + comments) for every issue in the CURRENT
# snapshot whose updated_at has advanced past its own cached details copy —
# an issue with no details file yet, or whose stored updatedAt differs from
# the snapshot's, gets ONE paginated `issues/<n>/comments` REST fetch
# (per_page=100 + --paginate, the same pagination discipline as the bulk
# list fetch above — an unpaginated call silently truncates at GitHub's
# default page size of 30, corrupting the durable corpus; body is already
# present in the snapshot row, so it costs nothing extra to copy in). An
# unchanged issue costs ZERO calls. Requires a snapshot to already exist
# (run cache_refresh_snapshot, or cache_refresh, first).
#
# Self-heal for pre-pagination records: every details file this code writes
# carries `commentsPaginated: true`, and the delta short-circuit below only
# skips a record that BOTH matches the snapshot's updated_at AND carries
# that marker. A record written by the old unpaginated code lacks the
# marker, so it gets exactly one re-fetch (now paginated, so complete) the
# next time this runs, after which it is sticky again.
#   rc 0 = every needed detail fetched cleanly; rc 1 = at least one failed
#          (that issue's stale/absent details file is simply left as-is —
#          never partially written, never corrupted)
cache_refresh_details() {
  local arg="$1" repo dir snap line n updated_at details_file comments body tmp rc=0
  repo="$(_cache_resolve_repo "$arg")" || return 1
  dir="$(cache_repo_dir "$arg")" || return 1
  snap="$dir/snapshot.jsonl"
  [ -f "$snap" ] || {
    echo "cache.sh: refresh_details — no snapshot for $repo yet (run cache_refresh_snapshot first)" >&2
    return 1
  }
  mkdir -p "$dir/details" 2>/dev/null || return 1

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    n="$(printf '%s' "$line" | jq -r '.number // empty' 2>/dev/null)"
    [ -n "$n" ] || continue
    updated_at="$(printf '%s' "$line" | jq -r '.updated_at // ""' 2>/dev/null)"
    details_file="$dir/details/${n}.json"
    # Skip only a record that is BOTH up to date (updatedAt matches the
    # snapshot row) AND marked complete (commentsPaginated:true — stamped
    # by the paginated fetch below). A pre-pagination record has no marker,
    # so it falls through to a one-time re-fetch here even when its
    # updatedAt matches (the self-heal described in the header).
    if [ -f "$details_file" ] &&
      jq -e --arg u "$updated_at" \
        '($u != "") and (.updatedAt == $u) and (.commentsPaginated == true)' \
        "$details_file" >/dev/null 2>&1; then
      continue
    fi
    # Paginated like the bulk list fetch above: `--paginate` emits one JSON
    # array per page; `jq -s 'add'` concatenates however many came back.
    if ! comments="$(_cache_gh api "repos/$repo/issues/$n/comments?per_page=100" --paginate 2>/dev/null)"; then
      rc=1
      continue
    fi
    [ -n "$comments" ] || comments="[]"
    if ! comments="$(printf '%s' "$comments" | jq -s -c 'add // []' 2>/dev/null)" || [ -z "$comments" ]; then
      rc=1
      continue
    fi
    body="$(printf '%s' "$line" | jq -c '.body // ""' 2>/dev/null)"
    tmp="$dir/details/.tmp.$$.${n}"
    if jq -nc --argjson n "$n" --arg u "$updated_at" --argjson body "$body" \
         --argjson comments "$comments" --argjson sv "$CACHE_STORE_SCHEMA_VERSION" \
         '{schema_version:$sv, number:$n, updatedAt:$u, body:$body, comments:$comments, commentsPaginated:true}' \
         >"$tmp" 2>/dev/null; then
      mv "$tmp" "$details_file"
    else
      rm -f "$tmp" 2>/dev/null
      rc=1
    fi
  done <"$snap"

  return "$rc"
}

# Convenience: snapshot + details, in order. Returns the snapshot phase's
# failure code if it fails (details is meaningless with no snapshot);
# otherwise returns the details phase's result.
cache_refresh() {
  local arg="$1" rc
  cache_refresh_snapshot "$arg"
  rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  cache_refresh_details "$arg"
}

# --- the consumer-facing read entrypoint -----------------------------------
# Degradation contract (F#988 Contract): any cache miss, staleness-beyond-
# limit, or parse failure triggers exactly one refresh attempt; if that
# attempt's live fetch itself fails, return nonzero/empty with one stderr
# notice (nothing to serve — never fabricate data); if the fetch succeeds
# but persisting it fails, fall through to serving that just-fetched live
# data directly (uncached) with one stderr notice, rather than erroring out
# on a disk/permission problem the caller doesn't need to care about.
#   stdout: snapshot.jsonl content (one JSON object per line)
#   rc 0 = data returned (cached, refreshed, or live-fallback); rc 1 = none
cache_read() {
  local arg="$1" repo snap raw
  repo="$(_cache_resolve_repo "$arg")" || return 1
  snap="$(cache_snapshot_file "$arg")" || return 1

  # The validity guard is deliberately O(1), not O(corpus) (temperloop#1163).
  # This was `jq . "$snap"` — a full parse of a multi-MB file whose result was
  # DISCARDED, on every read, before `cat` read the file a second time and the
  # caller parsed it a third. Measured: snapshots are 3.7–5.1MB, and that single
  # thrown-away parse was the largest component of a cached read.
  #
  # Checking the LAST line instead is the guard that matches the actual failure
  # mode. _cache_persist_snapshot writes a temp file and `mv`s it into place, so
  # a snapshot is either wholly absent or wholly written; partial content can
  # only come from a truncated or interrupted write, which manifests at the END
  # of the file. A mid-file corruption a full parse would have caught is not
  # reachable through this store's own write path, and if one ever arises the
  # consumer's own jq fails loudly rather than silently serving wrong data.
  if [ -f "$snap" ] && [ -s "$snap" ] && ! cache_stale "$arg" &&
    tail -n 1 "$snap" | jq -e . >/dev/null 2>&1; then
    cat "$snap"
    return 0
  fi

  if ! raw="$(_cache_live_list_raw "$repo")"; then
    echo "cache.sh: refresh failed for $repo — no data available" >&2
    return 1
  fi

  if _cache_persist_snapshot "$arg" "$raw"; then
    cache_refresh_details "$arg" || true
    cat "$snap"
  else
    echo "cache.sh: cache persist failed for $repo — falling through to a live (uncached) read" >&2
    printf '%s' "$raw" | jq -c '.[]'
  fi
  return 0
}

# Read one issue's cached details (body + comments), if present. Not
# staleness-aware itself — a caller wanting fresh details calls
# cache_refresh_details (or cache_refresh) first; this is a pure accessor for
# whatever is currently on disk (empty stdout + rc 1 if nothing cached yet).
cache_read_details() {
  local f
  f="$(cache_details_file "$1" "$2")" || return 1
  [ -f "$f" ] || return 1
  jq -c . "$f" 2>/dev/null
}
