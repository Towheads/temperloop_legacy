# cache.sh — canonical-layer issue-cache store

Sibling doc to `cache.sh` (F#988 Contract, epic "canonical-item cache layer").
This is the schema/contract note a later consumer (a corpus renderer, a
pipeline driver, anything that wants to read "every issue in this repo" without
re-paying GitHub every time) reads to know what's on disk and what it means.

## Why this exists — and why there is no longer another cache to differ from

`cache.sh` is a **durable, cross-session store of the full issue corpus** for
a repo — every issue, open and closed, with its body, parent linkage, and
comments — hoisted above board.sh's read path. It rides the REST issues-list
bucket exclusively, **never** GraphQL.

**This section used to contrast the store against a second cache; that second
cache no longer exists.** `board.sh` formerly carried its own read cache
(`BOARD_CACHE_TTL` / `_board_cached_read`): a narrow, `$TMPDIR`-resident,
short-TTL page of a single board's active (non-Done) Projects-v2 item-list,
whose entire purpose was relief for the Projects-v2 5,000-pt/hr **GraphQL**
budget. That cache — along with the structure/state TTL split
(`BOARD_STRUCTURE_TTL`, `board_bust_structure`) and the budget guard — was
removed together with the Projects-v2 arm it protected (ADR 0004, epic
temperloop#524). With one backend and no GraphQL, there is nothing left for it
to cache.

So `cache.sh` is now simply **the** cache in front of a board read: the
optional, per-board issue-corpus store described below. Its own behavior did
not change at that removal — it never rode GraphQL, never sourced `board.sh`,
and never consulted board.sh's cache — only this framing did. Its
**non-board consumers** (`workflows/scripts/lib/issue-corpus.sh`,
`workflows/scripts/lib/issue-marker-probe.sh`, `install/doctor.sh`) predate
the removal and are unaffected by it.

## Design seam: board number OR explicit repo

Every public function's first argument is either:
- an **"owner/repo" string** (contains a `/`) — used verbatim. This is the
  fully standalone path: `cache.sh` never sources `board.sh` and has zero
  hard dependency on it.
- a **bare board number** (e.g. `4`) — resolved via `board_repo()`, which
  must already be in scope (i.e. the caller sourced `board.sh` first, in the
  same shell, before sourcing `cache.sh`). If `board_repo` isn't defined,
  `cache.sh` fails loud with a one-line stderr hint rather than guessing.

This keeps the composition direction one-way: `cache.sh` may be layered on
top of `board.sh`, but `board.sh`'s own sync/vendor set stays self-contained
— a consumer checkout that sources only `board.sh` is completely unaffected
by `cache.sh` existing at all.

## On-disk layout

Every path accessor and the staleness/invalidation API (`cache_repo_dir`,
`cache_snapshot_file`, `cache_meta_file`, `cache_stale`, `cache_dirty`,
`cache_clear`) takes an optional trailing **`kind`** argument, defaulting to
`issues` — this file's own long-standing consumer, so every existing caller
(none of which passes a `kind`) is byte-for-byte unchanged. `kind` namespaces
the top-level store directory: a second kind (e.g. a state-graph snapshot
store) shares `$CACHE_STORE_ROOT` with the issue-corpus store but gets its
own top-level directory and its own `meta.json`, so `cache_dirty` /
`cache_clear` / `cache_stale` on one kind never touches a sibling kind's
staleness or contents (temperloop#1910). `cache_details_dir` /
`cache_details_file` and the refresh/read functions (`cache_refresh*`,
`cache_read*`) do not take a `kind` — they always resolve the default
`issues` kind, since per-issue detail fetches and the REST-issues refresh
pipeline are issue-corpus-specific; a non-`issues` kind is expected to be
populated by its own caller, not by this file's refresh machinery.

```
${CACHE_STORE_ROOT:-${XDG_CACHE_HOME:-$HOME/.cache}/temperloop}/<kind>/<owner>-<repo>/
  snapshot.jsonl        # one JSON object per line — the RAW REST issue row
                        # (GitHub's `gh api repos/<r>/issues` shape), PR rows
                        # filtered out, ALL states (open + closed) included.
                        # Parent linkage (`.parent`, `.sub_issues_summary`,
                        # present on the bulk REST payload as of 2026-07)
                        # rides through unmodified — this store does no
                        # reshaping, so any field GitHub adds to the issues
                        # REST payload is preserved for free.
  meta.json             # { "schema_version": 1, "repo": "owner/repo",
                        #   "last_refresh": <unix epoch of last successful
                        #   snapshot persist> }
  details/
    <issue-number>.json  # { "schema_version": 1, "number": <n>,
                        #   "updatedAt": "<snapshot row's updated_at>",
                        #   "body": "<issue body>",
                        #   "comments": [ <raw REST comment objects> ],
                        #   "commentsPaginated": true }
                        # `commentsPaginated` marks the record as written by
                        # the paginated comments fetch (complete comment
                        # list). A record without it predates pagination
                        # (may be truncated at 30) and is re-fetched once by
                        # the next cache_refresh_details — see below.
```

`<kind>` defaults to `issues`; `<owner>-<repo>` is the repo slug: `owner/repo`
with `/` replaced by `-` (`_cache_repo_slug`).

### schema_version

`CACHE_STORE_SCHEMA_VERSION` (currently `1`, a constant in `cache.sh`) is
stamped into every `meta.json` and every `details/<n>.json` this lib writes.
Bump it — and add a dated note here describing what changed and whether a
prior-version store needs `cache_clear` before re-use — before altering
either file's shape in a way an existing on-disk store wouldn't already
satisfy. `snapshot.jsonl` rows are raw GitHub REST payloads and are not
independently versioned; the store-level `schema_version` in `meta.json`
covers the snapshot file's *presence/location* contract, not its row shape
(that's GitHub's REST contract, not ours).

**2026-08-27 — additive field, no bump:** `details/<n>.json` gained
`commentsPaginated: true` (temperloop#1820) when the per-issue comments
fetch was paginated (`per_page=100` + `--paginate`; the unpaginated call
silently truncated at GitHub's default page size of 30). Purely additive —
existing readers keyed on the documented fields are unaffected, so
`schema_version` stays `1` and no `cache_clear` is needed: a prior-version
record lacks the marker, which `cache_refresh_details` treats as "needs
re-fetch" even when its `updatedAt` matches, so a truncated store self-heals
one issue at a time on the next details refresh.

## API surface

Path accessors (no I/O, no gh calls). `cache_repo_dir`, `cache_snapshot_file`
and `cache_meta_file` take an optional trailing `[kind]` (default `issues`);
`cache_details_dir`/`cache_details_file` always resolve the `issues` kind:
- `cache_repo_dir <board|owner/repo> [kind]` → the per-kind, per-repo store directory
- `cache_snapshot_file <board|owner/repo> [kind]` → `.../snapshot.jsonl`
- `cache_meta_file <board|owner/repo> [kind]` → `.../meta.json`
- `cache_details_dir <board|owner/repo>` → `.../details`
- `cache_details_file <board|owner/repo> <issue#>` → `.../details/<n>.json`

Refresh (write side):
- `cache_refresh_snapshot <board|owner/repo>` — one paginated REST list
  (`gh api repos/<r>/issues?state=all`, `--paginate`), PR rows filtered,
  written to `snapshot.jsonl` + `meta.json`. Zero per-issue calls, zero
  GraphQL. rc 0 persisted; rc 1 the live fetch itself failed (nothing to
  serve); rc 2 the fetch succeeded but the on-disk write failed.
- `cache_refresh_details <board|owner/repo>` — walks the current snapshot;
  for each issue whose `details/<n>.json` is missing, whose stored
  `updatedAt` differs from the snapshot row's `updated_at`, or which lacks
  the `commentsPaginated` marker (a pre-pagination, possibly-truncated
  record — re-fetched once, then sticky again), fetches
  `issues/<n>/comments` (one paginated REST fetch — `per_page=100` +
  `--paginate`, same discipline as the bulk list) and writes the details
  file (body is copied from the snapshot row — no extra call needed for
  it). An unchanged, complete issue costs zero calls.
- `cache_refresh <board|owner/repo>` — the above two in sequence.

Staleness + invalidation (each also takes an optional trailing `[kind]`,
default `issues`, scoped to that kind's own `meta.json`/directory only —
never a sibling kind under the same repo, temperloop#1910):
- `cache_stale <board|owner/repo> [kind]` — rc 0 (true) if no meta,
  unparseable meta, or age ≥ `CACHE_STORE_TTL` (default 3600s); rc 1 (false)
  otherwise.
- `cache_dirty <board|owner/repo> [kind]` — soft invalidation: zeroes
  `last_refresh` so the next `cache_read` refreshes regardless of age.
  No-op if no store exists yet (already maximally stale).
- `cache_clear <board|owner/repo> [kind]` — hard invalidation: deletes the
  entire per-repo, per-kind store (snapshot + meta + every cached detail
  file, for that kind).

Read (consumer-facing):
- `cache_read <board|owner/repo>` — the staleness-aware entrypoint. See
  "Degradation contract" below.
- `cache_read_details <board|owner/repo> <issue#>` — pure accessor for
  whatever `details/<n>.json` currently holds; not staleness-aware itself
  (call `cache_refresh_details` first for a guaranteed-fresh read).

## Tuning settings (ENV VARS only — no boards.conf axis in cache.sh itself)

- `CACHE_STORE_ROOT` — store root (default `${XDG_CACHE_HOME:-$HOME/.cache}/temperloop`)
- `CACHE_STORE_TTL` — max-stale window in seconds (default `3600`)

Deliberately environment-only in `cache.sh` itself: the per-board
`board.<N>.cache` *enable/disable* axis lives in `board.sh` (a different
concern — whether a board's whole-board issues-only read uses this store at
all — from these tuning settings, which govern the store's own behavior once in
use). See § Read dispatch (board.sh integration) below.

## Read dispatch (board.sh integration, cache-read-dispatch item)

`board.sh`'s `_board_issues_item_list` (the issues-only whole-board read) is
the one read call site this store is wired into. Dispatch requires BOTH:

1. `boards.conf` sets `board.<N>.cache=on` for that board (`_board_cache_
   store_enabled` in `board.sh`; see `boards.conf.example`'s `cache` axis),
   **and**
2. the calling process has separately `source`d this file — `board.sh` never
   sources `cache.sh` itself (kept one-way, per the "Design seam" section
   above); `_board_issues_item_list` checks `command -v cache_read` and, if
   it's absent, falls back to the plain live `gh issue list` read with one
   stderr notice (fail-safe: an enabled-but-unsourced axis degrades to
   exactly today's behavior, never a silent misread).

When both hold, the whole-board read becomes `cache_read <owner/repo>`
(zero `gh` calls on a warm store) instead of a live REST list call, and every
successful issues-only mutation (`board_set_status` / `board_stamp`, and
anything that routes through them) calls `cache_dirty` on that same repo —
see `_board_cache_dirty_after_write` in `board.sh`. `board_resolve_item` (the
claim lock) and `reconcile.sh` are structurally unaffected: the former never
reads through any cache, and the latter never sources this file, so it stays on
the live-read arm even if a `boards.conf` it shares sets `board.<N>.cache=on`.

**Staleness bound** (this read path's own figure; it superseded the
Projects-v2 90s items-cache figure of foundation #589, which is now moot —
that cache was removed with the arm, ADR 0004): a mutation made THROUGH `board.sh`
(`board_set_status`/`board_stamp`/claim/release) is reflected on the very
next `cache_read` in any process — no fixed wait, via the write-through
`cache_dirty` call above. A mutation made OUTSIDE this adapter (a PR-merge
auto-close, a manual `gh issue close`, a web-UI edit) is bounded only by the
refresh cadence `CACHE_STORE_TTL` names — **default 3600s / 1 hour** — since
nothing calls `cache_dirty` for a write this adapter never saw. See
`ISSUES-ONLY-BACKEND.md`'s § Read cache staleness bound for the full
rationale (this bound is deliberately looser than #589's retired 90s figure —
a durable corpus cache trades staleness budget for a fundamentally cheaper
read).

## Degradation contract

`cache_read`'s fallback chain, in order:

1. **Fresh + parseable cache exists** → served straight from disk, **zero**
   `gh` calls.
2. **Miss, stale, or unparseable (parse failure)** → triggers exactly one
   refresh attempt (one live REST fetch):
   - **the live fetch itself fails** (rate limit, auth, network) → print one
     stderr notice, return rc 1 with no stdout. Never fabricate or serve
     corrupt data.
   - **the fetch succeeds but persisting to disk fails** (permissions, full
     disk) → print one stderr notice, and serve the just-fetched data
     directly (uncached, "live") rather than failing the caller over a
     storage problem it doesn't need to care about.
   - **both succeed** → snapshot is persisted, `cache_refresh_details` runs
     best-effort (its own per-issue failures don't block the read — an
     individual issue's details simply stay whatever they were before), and
     the fresh snapshot is served.

`cache_dirty` is the lever a write-through caller uses: after mutating an
issue live (e.g. via `board.sh`'s `board_set_status`), call `cache_dirty` so
the next `cache_read` doesn't serve a pre-write snapshot for the remainder of
the TTL window. Rollback for the whole mechanism is a config flip — set
`CACHE_STORE_TTL=0` and never call the refresh functions, or simply don't
source `cache.sh` at all; nothing else in the toolkit depends on it existing.

## Invariants carried over from the epic contract

- `board_resolve_item` (board.sh) stays always-live — this store never
  substitutes for it and is never consulted by the claim-lock path. This
  survives the Projects-v2 removal unchanged (ADR 0004): the claim lock was
  always-live on both arms and remains so on the one that is left.
- Writes are write-through GitHub; this store is read-side only. A mutator
  calls `cache_dirty` after writing, it never writes issue state itself.
