# knowledge_store interface contract

`knowledge_store` is the document-I/O seam between a caller (a script, hook,
or command) and wherever structured project notes actually live. A caller
that wants to read, write, append to, or list a note does so through this
interface — never by hardcoding a filesystem path to a particular vault or
tool. That indirection is what lets a fresh install default to a plain
markdown directory while a different install points the same calls at a
different backend (e.g. an Obsidian vault), with zero changes to callers.

Implementation: `knowledge_store.sh` (same directory). It is a **sourced**
shell library, not an executable — `source knowledge_store.sh` to bring the
interface into scope. It sets no shell options; the sourcing script owns
`set -euo pipefail` (or whatever discipline it uses).

## Configuration

Exactly one environment variable selects the store root, and one selects the
backend — but an unset root does not resolve straight to the default below.
Every operation resolves its target location through `ks_root`, and `ks_root`
itself checks a machine-local config file before falling back to the XDG
default: when `KNOWLEDGE_STORE_ROOT` is unset, it tries
`_ks_machine_conf_root()`, which reads `KNOWLEDGE_STORE_ROOT` back out of the
file named by `KNOWLEDGE_STORE_MACHINE_CONF` (default
`${XDG_CONFIG_HOME:-$HOME/.config}/temperloop/build.config.sh`), sourced in an
isolated subshell; only if that file is missing, unreadable, or yields no
absolute path does resolution fall through to the XDG default. An explicitly
set `KNOWLEDGE_STORE_ROOT` is always honored verbatim, ahead of both.

| Variable | Default | Meaning |
|---|---|---|
| `KNOWLEDGE_STORE_ROOT` | `${XDG_DATA_HOME:-$HOME/.local/share}/temperloop/knowledge` | Absolute path to the store root. |
| `KNOWLEDGE_STORE_BACKEND` | `plain-files` | Backend name (kebab-case). Selects which backend's functions the interface dispatches to. |

The default root follows the XDG base-directory convention: it is a
per-user data directory, not tied to any particular git checkout, so a
plain-files store survives independent of which repo clone is active and
does not risk being accidentally committed inside a project tree.

**Legacy default root (window CLOSED in v0.19.0).** The default namespace
renamed from `.../foundation/knowledge` to `.../temperloop/knowledge` in
v0.15.0 (temperloop#165). Through the v0.15.0 → v0.19.0 window, a store
existing at the legacy default was resolved as a fallback; **that fallback is
removed**. When `KNOWLEDGE_STORE_ROOT` is unset, resolution now always yields
the **new** default. What survives is the *diagnostic*: if nothing exists at
the new default but a store directory **exists at the legacy default**, one
`NOTE` per process names the stranded store on stderr — without it a
pre-rename install would silently resolve an empty new root and report "no
notes found" while the real store sits one directory over. Migrate with
`mv "${XDG_DATA_HOME:-$HOME/.local/share}/foundation/knowledge" "${XDG_DATA_HOME:-$HOME/.local/share}/temperloop/knowledge"`
(or pin `KNOWLEDGE_STORE_ROOT`). An explicitly set `KNOWLEDGE_STORE_ROOT`
is always honored verbatim — this logic applies to the *default* only.

### `ks_root`

```
ks_root
```

Prints the resolved store root (no trailing slash) to stdout. Always
succeeds. Does not create the directory — that happens lazily, on the first
write, inside a backend.

## Backend registration seam

A backend is a set of four functions named `_ks_backend_<name>_<op>`, where
`<name>` is `KNOWLEDGE_STORE_BACKEND` with every `-` replaced by `_`, and
`<op>` is one of `read`, `write`, `append`, `list`:

```
_ks_backend_<name>_read    <doc-id>
_ks_backend_<name>_write   <doc-id> [--no-clobber]     # content on stdin
_ks_backend_<name>_append  <doc-id>                    # content on stdin
_ks_backend_<name>_list    [prefix]
```

To register a new backend: define those four functions (matching the
semantics below), make sure they're sourced/available before first use, and
set `KNOWLEDGE_STORE_BACKEND` to `<name>` (with `_` written back as `-`,
e.g. a function prefix of `_ks_backend_obsidian_*` is selected by
`KNOWLEDGE_STORE_BACKEND=obsidian`). No change to `knowledge_store.sh`
itself is required. Selecting a backend with no matching functions defined
is a dispatch-time error (exit 2), not a load-time error — nothing checks
that every op is implemented until it's actually called.

This file documents one backend, `plain-files` (the default), fully.

## Public interface

All four operations are shell functions exported by `knowledge_store.sh`
once sourced. None of them take content as a positional argument; `write`
and `append` read content from **stdin**. `doc-id` is a caller-chosen
relative identifier for a document (see "doc-id normalization" below) — not
a raw filesystem path.

### `ks_read <doc-id>`

Prints the document's full content to stdout.

- **Exit 0** — found; content on stdout.
- **Exit 1** — not found; nothing on stdout, a message on stderr.
- **Exit 2** — invalid `doc-id` (see normalization rules); nothing on
  stdout, a message on stderr.

### `ks_write <doc-id> [--no-clobber]`

Reads content from stdin and writes it as the document's full, sole
content — a **replace**, not a merge. Creates parent directories as
needed. Creates the document if absent.

- **Default (no `--no-clobber`)**: if the document already exists, it is
  overwritten (same semantics as `cat > file`). The write is performed
  atomically — content is staged to a sibling temp file, then renamed into
  place — so a killed or interrupted write can never leave a half-written
  document at the target path; a reader either sees the old content in
  full or the new content in full, never a mix.
- **`--no-clobber`**: refuses to touch an existing document — used for
  create-only semantics.

Exit codes:
- **Exit 0** — written (created or overwritten).
- **Exit 2** — invalid `doc-id`.
- **Exit 3** — `--no-clobber` given and the document already exists;
  nothing written.
- **Exit 1** — other I/O failure (e.g. parent directory not creatable).

### `ks_append <doc-id>`

Reads content from stdin and appends it to the end of the document. Creates
parent directories and the document itself if absent (so `ks_append` alone
is sufficient to start a new document — no separate "create" call exists).

Not staged through a temp file: this is a plain append-mode open, chosen
because append's use case is incremental logs where "atomic whole-file
replace" is the wrong cost/semantic for a call that may run many times
against the same document.

**Trailing-newline guarantee (temperloop#1308).** Appended content always
begins on a fresh line — `ks_append` never lands a mid-line concatenation
onto an unterminated last line. This matters concretely for a caller that
appends a `### heading` block to a log-like document: a consumer that
enumerates entries by matching `^### ` at line-start (e.g. a pending-
decisions review scan) silently skips an entry whose heading got fused onto
the previous line, because it is then no longer a real line-leading
heading. The guarantee is **conditional, not unconditional**: a separating
newline is inserted only when the target already exists, is non-empty, and
its last byte is not itself a newline. Appending to an already
well-terminated document is therefore byte-identical to appending without
this guarantee — no stray blank line is ever introduced, and a caller that
already emits its own leading `\n` (as most existing callers do) sees no
behavior change. See the Backend matrix below for how each backend
satisfies this.

- **Exit 0** — appended (document created if it did not exist).
- **Exit 2** — invalid `doc-id`.
- **Exit 1** — other I/O failure.

### `ks_list [prefix]`

Prints one `doc-id` per line, sorted, for every document under the store
root — or, when `prefix` is given, every document under
`<root>/<prefix>`. `prefix` is a plain relative path segment, not a glob.

- **Exit 0** — always, even when the root (or the prefix subdirectory)
  does not exist yet; in that case nothing is printed. Listing is
  read-only and never creates the root.

## doc-id normalization

Every operation normalizes its `doc-id` the same way before touching
storage:

1. Must be non-empty.
2. Must be a **relative** path (no leading `/`).
3. Must not contain a `..` path segment (guards against escaping the store
   root).
4. A trailing `.md` is appended if not already present — so `Decisions/foo`
   and `Decisions/foo.md` name the same document.

A `doc-id` failing rules 1–3 is a validation error: every operation returns
exit 2 without touching storage. This is a **best-effort textual guard**,
not a full path canonicalization library — it does not resolve symlinks,
collapse repeated slashes, or handle every path-traversal trick; it is
enough to keep the plain-files backend (and any well-behaved future
backend) from writing outside the resolved root under normal use.

## The `plain-files` backend

Stores each document as a markdown file — optionally carrying a YAML
frontmatter block at its top — under `ks_root`. The relative filesystem
path of a document IS its `doc-id` (after normalization).

The backend treats document content as **opaque bytes**: it does not parse,
validate, or otherwise interpret any YAML frontmatter a caller chooses to
put at the top of a document's content. Frontmatter-aware operations (e.g.
"read just the `status:` field") are out of this seam's scope — a caller
that needs that composes it on top of `ks_read`. This "opaque bytes" claim
is about content *interpretation*, not about `ks_append` touching nothing
but stdin: `ks_append`'s trailing-newline guarantee (above) does read the
existing document's last byte before writing, purely to decide whether to
insert a separating newline — it never inspects, parses, or reacts to
anything else about the content (frontmatter, headings, structure).

No locking is implemented — the atomic-rename write and O_APPEND append
are each individually safe against a torn write, but there is no
cross-process mutual exclusion between concurrent writers to the same
`doc-id`. Concurrent use should serialize at a level above this interface
(e.g. a caller-owned lock file) if that matters for a given caller.

## The `obsidian` backend

Implementation: `knowledge_store_obsidian.sh` (same directory), a **separate
file from `knowledge_store.sh`** — per the registration seam above, no
change to `knowledge_store.sh` is required to add a backend. Source it
*after* `knowledge_store.sh`, then set `KNOWLEDGE_STORE_BACKEND=obsidian`:

```
source knowledge_store.sh
source knowledge_store_obsidian.sh
KNOWLEDGE_STORE_BACKEND=obsidian
ks_read "Decisions/foo"
```

Stores each document as a note in an Obsidian vault, via the [Obsidian
Local REST API](https://github.com/coddingtonbear/obsidian-local-rest-api)
plugin — the same API foundation's hooks already use (see
`claude/hooks/session-start-drain.sh` and `workflows/scripts/build/plan.sh`
for the established base-URL/auth/TLS conventions this backend reuses
verbatim, rather than inventing new plumbing).

**Root mapping: the vault itself is the root, not `KNOWLEDGE_STORE_ROOT`.**
This is the one deliberate deviation from the "ONE setting for the root"
framing at the top of this file — `KNOWLEDGE_STORE_ROOT` is a *filesystem*
path setting and is simply not consulted by this backend. A normalized
`doc-id` (e.g. `Decisions/foo.md`) is used directly as the REST API's
vault-relative path (`/vault/Decisions/foo.md`); `ks_root` still resolves
to its filesystem default/override but that value is meaningless for this
backend and must not be used to build obsidian paths. There is no
sub-vault "store root" concept — every doc-id addresses a path relative to
the vault's own root.

Additional config, specific to this backend (beyond the two universal
settings):

| Variable | Default | Meaning |
|---|---|---|
| `KNOWLEDGE_STORE_OBSIDIAN_API_BASE` | `https://127.0.0.1:27124` | Obsidian Local REST API base URL. |
| `KNOWLEDGE_STORE_OBSIDIAN_API_KEY_FILE` | `$(ks_root)/.obsidian/plugins/obsidian-local-rest-api/data.json` (derived from `KNOWLEDGE_STORE_ROOT`, not a second literal) | Path to the plugin's own key file (`.apiKey` field is the bearer token). |

Op-to-REST mapping:

| Op | HTTP | Notes |
|---|---|---|
| `ks_read` | `GET /vault/<path>` | Body is the document content verbatim. |
| `ks_write` | `PUT /vault/<path>` | Whole-file replace; Obsidian creates missing parent folders. |
| `ks_write --no-clobber` | `GET` then `PUT` | The REST API has no native create-only verb, so `--no-clobber` is **emulated** with a pre-flight `GET`: exit 3 (untouched) if it returns 200, otherwise proceed to `PUT`. This is a check-then-act race under concurrent writers — no worse than this seam's documented "no locking" guarantee, but worth naming explicitly: two concurrent `--no-clobber` writers to the same `doc-id` can both pass the pre-flight check and both `PUT`. |
| `ks_append` | `POST /vault/<path>` | Local REST API POST semantics are already create-or-append, matching this op exactly. **Trailing-newline guarantee: inherited, not enforced by this adapter.** Whether an append lands on a fresh line is a property of the Local REST API server's own POST separator semantics — this backend does not pre-flight a `GET` to inspect the target's last byte and decide whether to inject a separator itself (unlike the deliberate `--no-clobber` pre-flight above, adding a network round trip and a check-then-act race here would only re-achieve a property the upstream POST already delivers for free). If a future Local REST API release changed its POST-append separator behavior, this adapter's conformance to the guarantee would change with it — that is an explicit, accepted upstream dependency, not a gap this seam silently papers over. |
| `ks_list [prefix]` | `GET /vault/<dir>/` (recursive) | The REST API has no recursive-listing endpoint, only a per-directory `GET` returning `{"files":[...]}` (subfolder entries end in `/`); this backend walks the tree breadth-first, one request per directory, filtering to `*.md` entries. |

Error-mode deviations from the plain-files table above (both driven by the
same principle: an unreachable/erroring REST API must fail loud, mirroring
how `plan.sh`'s `_plan_vault_write` treats an unreachable REST endpoint —
never a silent no-op):

- **`ks_read`'s exit-1 bucket widens.** Plain-files' exit 1 means "not
  found" only. This backend's exit 1 covers "not found" (404) **or** any
  other non-2xx response, **or** the REST API being unreachable — the same
  "other I/O failure" bucket `ks_write`/`ks_append` already define, now
  also covering `ks_read`. The specific cause is always on stderr; exit 2
  (invalid doc-id) is unchanged and still checked before any HTTP call.
- **`ks_list`'s "always exit 0" guarantee does not hold.** Plain-files'
  `ks_list` never fails (a local `[ -d ... ]` check can't really fail). A
  network-backed backend can: an unreachable REST API or a non-2xx
  response mid-walk causes this backend's `ks_list` to fail loud (exit 1).
  The "root/prefix directory does not exist yet → exit 0, nothing printed"
  behavior is preserved for the one case that maps cleanly (a 404 on the
  requested root/prefix directory itself).

No locking, same as plain-files (see above) — plus the `--no-clobber`
race noted in the table.

## Backend matrix

| | `plain-files` (default) | `obsidian` |
|---|---|---|
| Selected by | `KNOWLEDGE_STORE_BACKEND=plain-files` (or unset) | `KNOWLEDGE_STORE_BACKEND=obsidian` |
| Implementation file | `knowledge_store.sh` | `knowledge_store_obsidian.sh` (separate file, sourced additionally) |
| Storage | Markdown files under `ks_root` (`KNOWLEDGE_STORE_ROOT`, filesystem) | Notes in an Obsidian vault, via the Local REST API |
| Root semantics | `KNOWLEDGE_STORE_ROOT` names the store root directory | `KNOWLEDGE_STORE_ROOT` is **not consulted**; the vault root IS the store root |
| Extra config | none | `KNOWLEDGE_STORE_OBSIDIAN_API_BASE`, `KNOWLEDGE_STORE_OBSIDIAN_API_KEY_FILE` |
| Network dependency | none | requires the Local REST API plugin reachable + authenticated |
| `ks_read` exit 1 | not found only | not found, OR any other read failure (incl. unreachable) |
| `ks_write --no-clobber` | atomic filesystem check (`[ -e "$path" ]`) | emulated via pre-flight `GET` (TOCTOU race under concurrent writers) |
| `ks_list` exit code | always 0 | 0 when the target dir 404s; **1** on any other failure mid-walk |
| `ks_append` trailing-newline guarantee | enforced directly (conditional last-byte check + separator insert, see § `ks_append`) | **inherited** from the Local REST API's own POST-append semantics — not independently checked/enforced by this adapter (no pre-flight `GET`, no TOCTOU race added) |
| Locking | none | none (plus the `--no-clobber` pre-flight race) |
| Sync (optional capability, see § Sync) | implemented (git-backed, manual) | not implemented — `ks_sync` exits 3, `skipped — sync unavailable for backend obsidian` |

## Sync — optional backend capability (EXPERIMENTAL)

Sync (temperloop#430, ADR 0003) is **not** a universal op like
`read`/`write`/`append`/`list` — it is an **optional backend capability**,
following the availability-probe precedent `ks_search` established. It is a
*store-level* operation only coherent for a backend whose store is a
directory under `ks_root`; the `obsidian` backend never consults
`KNOWLEDGE_STORE_ROOT` at all (the vault root IS the store root), so a
git-under-root sync has no meaning there and it degrades legibly rather
than inheriting an unimplementable obligation.

**Status: EXPERIMENTAL.** Single-tenant per `$HOME` — one flat store root,
one remote. The **search** half of temperloop#418 has landed (§ Project
partition — `ks_search` can be scoped); the **store** half has not: `ks_sync`
replicates the whole root and knows nothing about partitions, so a synced
remote carries every project's notes together.
Single-writer assumption — there is no conflict story beyond git's own:
`pull` is fast-forward-only, and a diverged store fails loud for the
operator to resolve with git directly, never an auto-merge.

### Public interface

```
ks_sync init <remote-url>     -> make the store a git repo + wire remote `origin`
ks_sync push [-m <msg>]       -> stage all, commit (iff changes), push
ks_sync pull                  -> fast-forward-only pull from `origin`
ks_sync status                -> read-only summary (store, remote, branch, unsynced count)
ks_sync_available             -> exit 0/3 probe, no stdout
```

Exit codes (mirroring `knowledge_search`'s shape):

| Exit | Meaning |
|---|---|
| 0 | Success (for `status`: it answered — including the legible "not initialized" answer; `status` is a probe, not a gate). |
| 2 | Invalid usage (missing/unknown sub-op, `init` without `<remote-url>`, an unknown `push` argument). |
| 3 | Capability unavailable ("skipped"). A message beginning `skipped — sync unavailable for backend <name>` is printed to stderr; **nothing is ever printed to stdout**. Same legible-degradation contract as `ks_search`'s exit 3. |
| 4 | Sync-operation failure: the backend can sync but the operation failed (store not initialized, no remote wired, non-fast-forward pull, rejected push). Cause on stderr. |

`ks_sync_available` is the standalone probe (exit 0 = ready, exit 3 = the
same `skipped —` notice on stderr). It checks two layers: the current
backend defines a `sync` op at all (a backend registers the capability by
defining `_ks_backend_<name>_sync`, optionally plus
`_ks_backend_<name>_sync_available` as its tooling probe — the same
registration seam as the universal ops), and — when the backend provides
one — that tooling probe passes (`plain-files`: `git` on `PATH`).

### Hard rules (all backends)

- **Every sync op routes through `ks_sync`** — no caller may shell
  `git -C "$(ks_root)"` (or equivalent) directly. Under a backend that
  never consults `KNOWLEDGE_STORE_ROOT` (obsidian), that back-channel would
  "sync" a directory that is not the store at all; the dispatch gate is
  what makes the exit-3 degradation reachable.
- **Manual invocation only.** `ks_sync` is an operator action, like
  `git push` itself — it is never wired into a scheduled or background job
  (launchd, cron, a watcher, a hook).
- **The store is user data.** `temperloop uninstall` never deletes or
  de-remotes the store: the store directory — including its `.git` and
  remote config — survives uninstall intact, and no sync-specific state
  lives anywhere *outside* the store directory (asserted end-to-end by
  `workflows/scripts/tests/test_install_lifecycle.sh`'s residue diff).

### The `plain-files` implementation

The store directory itself becomes a git repository (`$(ks_root)/.git`)
with one remote, `origin`:

- **`init <remote-url>`** — `git init` (if the root has no `.git` of its
  own) pinned to branch `main` regardless of the host's
  `init.defaultBranch`, then `remote add`/`set-url origin <remote-url>`.
  Idempotent; never clones or pulls by itself. **The remote should be
  private by default** — the store is personal working notes; the worked
  example creates it with `gh repo create <owner>/knowledge-store
  --private`.
- **`push [-m <msg>]`** — `add -A`, commit only if there are changes
  (default message `knowledge-store sync: <UTC timestamp>`), push the
  current branch with `-u`. Commit identity: the operator's own git
  identity when configured (config or `GIT_COMMITTER_*` env); a neutral
  `knowledge-store-sync` fallback is injected only when `user.email`
  resolves to nothing, so a fresh CI/sandbox `$HOME` never fails on
  identity.
- **`pull`** — `pull --ff-only origin <branch>`. On a freshly-`init`-ed
  store (unborn `HEAD`) this receives the operator's real store from the
  remote — the **second-environment bootstrap**: `ks_sync init
  <remote-url>` then `ks_sync pull` in a fresh environment reproduces the
  store, in-beta the cheap path to fresh-install validation against real
  data.
- **Enclosing-repo guard** — `push`/`pull` require the root to carry its
  *own* `.git` (exit 4 otherwise): a store directory that merely sits
  inside some outer git repository is never operated on through that outer
  repo.

### Thin operator entry

`workflows/scripts/lib/knowledge_sync.sh` is an executable wrapper (source
the lib, pass through to `ks_sync`, exit codes untouched) so an operator
can run a manual sync without hand-sourcing the library. It is
**deliberately not** a `bin/temperloop` subcommand and **not listed in the
stranger-facing CLI reference** — whether this experimental surface is
promoted to a first-class `temperloop sync` subcommand is a decision kept
open; adding it to the CLI reference now would freeze a contract surface
(`VERSIONING.md` § CLI surface) around an experimental capability.

## Read-log telemetry (script plane)

`knowledge_store.sh` also implements `ks__read_log_emit <plane> <op>
<doc-path-or-query>` (temperloop#229, Epic #226 "script-plane read
telemetry") — every `ks__dispatch` call (so every `ks_read`/`ks_write`/
`ks_append`/`ks_list`, for every backend) and `knowledge_search.sh`'s
`ks_search` entrypoint append one normalized line to a log kept deliberately
**outside** the store itself (no embed churn from the log becoming a
document the search index has to chew on, no self-observation loop). Line
shape, fields joined by `" · "`:

```
<timestamp> · <session-id> · <plane> · <op> · <doc-path-or-query>
```

- `timestamp` — UTC, `date -u +%Y-%m-%dT%H:%M:%SZ`.
- `session-id` — `$CLAUDE_CODE_SESSION_ID`, or `-` when unset.
- `plane` — `script` for every call in `knowledge_store.sh` /
  `knowledge_search.sh`. The agent-plane read-telemetry hook
  (`claude/hooks/ks-agent-read-log.sh`, temperloop#236) calls the SAME
  `ks__read_log_emit` function with `plane=agent` rather than getting a new
  setting.
- `op` — `read` | `write` | `append` | `list` | `search` | `sync` (the
  optional sync capability's dispatches, temperloop#430 — its
  `doc-path-or-query` field carries the sub-op, e.g. `push`), plus `other` from
  the agent-plane hook only, for a matched MCP tool name its simple
  name-based mapping can't classify (see that hook's own header for the
  mapping table) — logged rather than dropped, per the epic's "unknown
  knowledge-store tools log with a generic op rather than being dropped
  silently" contract.
- `doc-path-or-query` — the dispatched doc-id, or the `ks_search` query,
  newline/tab-sanitized to a single line.

Config: `KNOWLEDGE_READ_LOG` (path), default
`${XDG_STATE_HOME:-$HOME/.local/state}/foundation/knowledge-reads.log` — the
ONE override point for the log's location. Logging is fail-open: a write
failure (log dir uncreatable, disk full, etc.) is WARNed to stderr and never
propagates into the wrapped `ks_*` call's own exit code.

This line format is a stable contract — later telemetry items (a SessionEnd
one-liner, a `/tidy` tally) are documented to consume it as-is; changing the
field order/count/separator means updating every consumer.

### Additive outcome fields (search only)

`ks_search` (`knowledge_search.sh` — the ONE entrypoint shared by both the
cold `basic-memory` backend and the warm `basic-memory-mcp` daemon backend in
`knowledge_search_mcp.sh`, selected via `KNOWLEDGE_SEARCH_BACKEND`) appends
SIX further fields after the 5-field prefix above (foundation#1449, epic
foundation#1443 "obs-outcome-emit"), same `" · "` separator:

```
<timestamp> · <session-id> · <plane> · search · <query> · <result_count> · <top_score> · <abstained> · <rg_fallback> · <mode> · <wall_ms>
```

- `result_count` — number of results the caller actually received (post
  re-rank, post rg-fallback). An integer, `0` on a genuine no-match, or `-`
  when the dispatch itself errored (no result set to describe).
- `top_score` — the first result's `.score` field verbatim (query-relative —
  never compared across queries, per `_ks_bm_rerank`'s trap 1), or `-` when
  `result_count` is `0` or `-`.
- `abstained` — `1` when the `KNOWLEDGE_SEARCH_ABSTAIN` floor
  (foundation#1450, off by default) dropped every candidate below the
  measured floor and `ks_search` returned the genuine empty-result shape
  instead of a low-confidence hit; `0` otherwise. See "### Abstention floor"
  below.
- `rg_fallback` — `1` when the score:0 ripgrep lexical fallback
  (`ks_search__rg_fallback`, foundation#950) fired and surfaced a hit; `0`
  otherwise.
- `mode` — the retrieval path actually taken: `hybrid` (the only mode this
  adapter implements) or `hybrid+rerank` when `KNOWLEDGE_SEARCH_RERANK=1`
  actually ran (outcome fields record the POST-re-rank result); `rg-fallback`
  when the lexical fallback is what answered the query instead (overrides the
  hybrid/rerank label); or `error:<rc>` when the backend dispatch itself
  errored (`rc` 3 = unavailable mid-flight, 4 = backend error).
- `wall_ms` — wall-clock milliseconds the backend dispatch call took (perl
  `Time::HiRes` when available, whole-second×1000 fallback).

Only `ks_search`'s call passes these — every `ks__dispatch` call
(`ks_read`/`ks_write`/`ks_append`/`ks_list`, every backend) and the
agent-plane hook still call `ks__read_log_emit` with exactly the 3-field
prefix, so their lines are byte-identical to the pre-#1449 5-field shape.
This is additive by construction: a consumer keyed on field position (e.g.
`telemetry-brief.sh`'s `$4`/`NF>=4`, or `vault_hygiene_report.sh`'s
`NF<5{next}` reassembly of the doc field from `$5..NF`, which only runs on
`op=="read"` lines and so never sees a search line's extra fields) is
unaffected either way.

`ks_search` logs exactly once per call it dispatches (gated on the same
backend-availability probe the pre-#1449 code used) — including a call whose
dispatch errors, so the pre-#1449 count semantics (one line per
available-gated call) are unchanged; a dispatch error is itself a countable
outcome (`mode=error:<rc>`), not one dropped from the tally.

**Agent plane.** `claude/hooks/ks-agent-read-log.sh` is a PostToolUse hook
that appends the same-format line for a knowledge-store MCP tool call. Which
`tool_name` values count is read from `KNOWLEDGE_READ_LOG_AGENT_MATCHERS`
(space-separated `case`-glob patterns, defined right next to
`KNOWLEDGE_STORE_BACKEND` in this file) — today `mcp__obsidian*
mcp__obsidian-builtin*`; enabling a future `mcp__basic-memory__*` transport
at the `mcp__obsidian__*` EOL cutover is a one-line edit to that setting, no
hook change. The hook sources this file (`knowledge_store.sh`) to resolve
both that matcher list and `ks__read_log_emit` itself; on a checkout where
this file isn't reachable (no knowledge-store config at all) the hook is
inert and fails open — it emits nothing rather than guessing a format.

## Non-goals of this seam (deliberately out of scope)

- **No caller routing (this file's own scope).** This file defines the
  interface and both backends (`plain-files`, `obsidian`) — it does not
  itself route any hook, command, or script through the interface.
  Routing callers over (so no hook/command names an operator's vault path
  as a hardcoded literal) is sibling-level work tracked to completion by
  temperloop#164/#169 (kernel-literal-scrub).
- **No frontmatter parsing/query API.** See above.
- **No search.** `ks_list` enumerates by path/prefix only; it does not
  grep content or rank relevance.

## knowledge_search

`knowledge_search` (foundation #776, Epic A #762 "kernel split") is the
concept-level (semantic/hybrid) retrieval seam layered on top of
`knowledge_store`. Where `ks_list` enumerates documents by path/prefix,
`ks_search` ranks documents by relevance to a natural-language query.

Implementation: `knowledge_search.sh` (same directory), a second **sourced**
shell library — `source knowledge_search.sh` after `source knowledge_store.sh`
(it calls `ks_root`, so `knowledge_store.sh` must already be sourced). It
sets no shell options of its own.

### Corpus binding — no independent path setting

The **indexed** corpus is **always** the store's resolved root, `ks_root`
(defined by `knowledge_store.sh`). There is no `KNOWLEDGE_SEARCH_ROOT` or
equivalent — this is a deliberate split-brain guard: a search index that
could be pointed somewhere other than the document store would silently
drift from what `ks_read`/`ks_write`/`ks_list` actually see. Whatever
backend `KNOWLEDGE_STORE_BACKEND` resolves documents to, `ks_search` reads
back that same root from disk.

What a **given call returns** is a narrower question, and since
temperloop#418 it is no longer unconditionally "everything under `ks_root`":
a call carrying a **partition scope** returns only the subset whose
documents prove membership in the named partition (§ Project partition
below). The *index* stays bound to that one root — the split-brain guard is
unchanged — and the scope is a **result filter over that one index**, never
a second corpus or a second root setting. Unscoped, which is the default,
the returned set is the whole root exactly as it was before.

### Public interface

```
ks_search <query> [--limit N] [--partition <name>]
                                  -> ranked results, JSON Lines on stdout
ks_search_reindex [--full] [--search] [--embeddings]
                                  -> rebuild the backend's index for ks_root
ks_search_available [--probe]     -> exit 0/3 probe, no stdout.
                                     BARE: lazily installs the pin if
                                     absent (side-effecting).
                                     --probe: zero-side-effect, never
                                     installs — use this for a cheap
                                     predicate / graceful-skip check.
ks_search_partition_supported     -> exit 0 iff THIS library implements the
                                     --partition scope (a `command -v`
                                     version-skew probe — § Project partition)
```

`ks_search` prints one JSON object per line (JSON Lines, not a single JSON
array), ranked highest-relevance first:

```json
{"doc_id": "Decisions/foo.md", "title": "Foo", "score": 1.23, "snippet": "…matched excerpt…"}
```

`doc_id` is the same relative-path identifier `knowledge_store` uses, so a
result can be handed straight to `ks_read <doc_id>`.

Exit codes (both `ks_search` and `ks_search_reindex`):

| Exit | Meaning |
|---|---|
| 0 | Success. For `ks_search`, this includes a legitimate **zero-result** match — an empty JSONL stream with exit 0 is a real "no matches," never confused with "backend unavailable." |
| 2 | Invalid usage (empty query, an **unrecognised `ks_search` or `ks_search_reindex` flag**, a `--limit`/`--partition` with no value, an **empty `--partition` value**, or `KNOWLEDGE_SEARCH_BACKEND` names a backend with no matching functions defined). |
| 3 | Backend unavailable ("skipped"). The backend's required subprocess tooling is not on `PATH`. A message beginning `skipped — knowledge_search unavailable` is printed to stderr; **nothing is ever printed to stdout** in this case. This is the legible-degradation contract: a caller must never mistake "backend not installed" for "searched and found nothing." |
| 4 | Backend error: the subprocess ran but exited non-zero, or its output could not be parsed into the expected shape — **including a partition filter that could not run** (see § Project partition: a filter that cannot run returns nothing, never the unscoped set). |

`ks_search_available` runs the same availability check `ks_search` and
`ks_search_reindex` use internally, standalone, so a caller can probe
before calling either (exit 0 = ready, exit 3 = the same "skipped —"
notice on stderr, no stdout either way).

### Project partition — scoped search (temperloop#418)

Without a scope, one `ks_root` is one flat, undivided search corpus. The
store's only separation between projects is the `<project> - <title>.md`
**filename convention**, and search did not respect it — so for an operator
running a single `$HOME` across several engagements, a query typed during
client B's session could rank and return client A's confidential notes. That
was structural, not incidental. The partition scope is the seam that closes
it.

**Setting the scope.** Two routes, same enforcement:

| Route | Shape | Use |
|---|---|---|
| `KNOWLEDGE_SEARCH_PARTITION` | env/config setting, **empty by default** | the standing scope — set once per engagement, every `ks_search` in that session is scoped |
| `ks_search … --partition <name>` | per-call flag | overrides the setting for one call |

**Membership is proven by the `doc_id`, never assumed.** A result belongs to
partition `<p>` iff its `doc_id` satisfies **either**:

- **filename convention** — its basename starts with `<p> - `, e.g.
  `Decisions/acme - retainer terms.md` is in partition `acme`. This is the
  convention the store already uses.
- **directory convention** — the `doc_id` starts with `<p>/`, e.g.
  `acme/Decisions/retainer terms.md`, for a store organised by top-level
  project directory instead.

Matching is **exact and case-sensitive**. There is no fuzzy, normalized, or
prefix-ish match: a near-miss here is a confidentiality failure, not a
ranking miss.

**Unpartitioned documents are EXCLUDED from a scoped search**, deliberately.
A document matching neither form (`Index.md`, `Sessions/2026-08-04.md`) is
one whose ownership the store cannot prove, and a confidentiality filter must
not return what it cannot attribute. The cost is real and stated rather than
hidden: a scoped search also hides your generic, cross-project notes. The
alternative — an "unpartitioned notes are always visible" opt-out — is
exactly the fail-open lever this seam exists in order not to have.

**Fail-closed is the load-bearing property.** An unrecognised or unhonoured
scope argument must **error**, never widen the corpus:

- `ks_search` parses its **own** arguments against an allowlist and rejects
  anything else with **exit 2** before any backend call — the same shape as
  `ks_search_reindex`'s rejection above. The pre-#418 loops ended in
  `*) shift ;;`, so a scope flag a layer did not understand was *discarded*
  and the full corpus came back at exit 0: a silent confidentiality failure
  dressed as a successful scoped search.
- An **empty** `--partition` value is rejected too, never read as "no
  partition" — a `--partition "$CLIENT"` that expanded to nothing fails
  loudly instead of silently widening back to the whole corpus.
- The scope is **consumed at the `ks_search` seam and never forwarded to a
  backend**. Enforcement therefore cannot depend on a backend choosing to
  honour it, and both shipped backends (`basic-memory`, `basic-memory-mcp`)
  *reject* the flag rather than ignore it.
- Every result stream a caller can receive is filtered at that one point —
  the backend's own results **and** the degraded **ripgrep lexical fallback**
  (which would otherwise leak the other client's notes precisely when the
  semantic path found nothing).
- A filter that **cannot run** (no `jq`) returns nothing and **exit 4** — it
  never falls back to the unfiltered stream.
- A **version-skew** caller probes `command -v ks_search_partition_supported`
  first. On a pre-#418 copy of the library that function does not exist, and
  that is the only reliable way to distinguish a library that *honours* the
  scope from one that would silently ignore it. No care inside this library
  can close that gap for a caller running an older one.

**Scope of this seam — a search filter, not a store partition.** This is
stated plainly rather than half-built. It scopes `ks_search` only.
`ks_read`, `ks_write`, `ks_append`, `ks_list`, and `ks_sync` are
**unpartitioned**: a caller that knows a `doc_id` can still read it, and
`ks_list` still enumerates the whole root. A true multi-tenant *store*
partition would have to reach the doc-id normalizer, every backend in the
matrix, and the sync capability — a store-layer redesign, not this change.
What this closes is the bleed the issue is actually about: **search
surfacing another project's notes**. What it does **not** provide is
at-rest isolation; for that, the mitigation remains a **separate `$HOME`
(and therefore a separate store root) per engagement**.

**No regression when unscoped.** With no partition configured — the dominant
single-tenant case — behaviour is byte-identical to pre-#418: the whole
corpus, no filtering, the same fallback trigger conditions. The fallback in
particular still fires only on a **backend**-empty result, never on a set the
partition filter emptied (a post-filter empty is not a backend-empty, the
same distinction the abstention floor already draws).

### `ks_search_reindex` flags

`ks_search_reindex` takes an **allowlist** of flags and forwards each one, by
name, to the backend's own reindex CLI. It is deliberately not a blanket
`"$@"` forward: the allowlist is what makes the unknown-flag rejection below
possible.

| Flag | Meaning |
|---|---|
| *(none)* | Incremental reindex — the cheap default. |
| `--full` | Full filesystem rescan **and** a forced full re-embed. |
| `--search` | Rebuild the full-text (FTS) index and reconcile the entity table — re-paths moved documents, drops deleted ones. |
| `--embeddings` | Rebuild the semantic embeddings. |

The flags compose, so the shape a **drift-healing scheduled reindex** wants is
`ks_search_reindex --full --search`: the full filesystem rescan plus the FTS
rebuild, **without** the forced full re-embed. Measured on a 977-note live
store (foundation#1425, 2026-07-28): `--full --search` = **61s**, bare
`--full` = **587s**. Before temperloop#888 that shape was unreachable through
this seam — a caller had to reach into the library-private `_ks_bm_run` behind
a `command -v` probe — so any consumer that still does so can drop the probe
and call the public seam.

An **unrecognised** argument is rejected: exit 2 (the invalid-usage code
above) with a one-line stderr message naming the offending argument and the
accepted set, and no backend call is made at all. It is never silently
discarded — the pre-#888 loop shifted every non-`--full` argument away, so a
mistyped `ks_search_reindex --full --serch` silently degraded to bare `--full`,
the 587s forced re-embed instead of the 61s shape the caller asked for, with no
warning.

### Post-fetch re-rank

`ks_search` does not return the backend's own ordering unchanged. It asks the
backend for a **deeper** candidate set than the caller requested
(`KNOWLEDGE_SEARCH_RERANK_DEPTH`, default 20), re-orders those candidates, and
returns exactly `--limit` of them. The extra depth is **internal**: a caller
that asks for 5 still receives 5.

This is the ranking lever chosen by the mode-sweep verdict (foundation#1445):
on that corpus the right document was inside the backend's top-20 for 94.6% of
queries but inside its top-5 for only 86.8%, while MRR stayed flat across the
same depth increase — so depth was buying coverage the returned window threw
away.

What the re-rank is allowed to change, and what it is not:

| | |
|---|---|
| **May change** | the ORDER of results, and therefore WHICH `--limit` candidates survive |
| **Never changes** | the record shape, the field set, the `score` values, or any exit code — each surviving record is passed through byte-for-byte as the backend's reshape emitted it |

Three invariants the implementation is built around, each pinned by a test in
`tests/test_knowledge_search.sh` (case 15) and
`tests/test_knowledge_search_mcp.sh` (case 4):

1. **It never reads `score` as evidence.** basic-memory's hybrid scores are
   normalised **within each query's own result set**, so they are query-relative
   and not comparable across queries or against any fixed threshold. The
   re-ranker therefore fuses **rank lists** (reciprocal-rank fusion), which is
   scale-free.
2. **The `score: 0` rg-fallback sentinel is never reordered.** A `0` there is a
   *provenance marker* (a ripgrep lexical hit surfaced when the backend found
   nothing), not a relevance value. A candidate set containing one is passed
   through in backend order.
3. **Both backends apply the same re-rank.** The cold `basic-memory` CLI path
   and the warm `basic-memory-mcp` daemon path share one implementation, so
   they cannot drift apart in ranking.

Set `KNOWLEDGE_SEARCH_RERANK=0` to restore the backend's own ordering; the fetch
depth then collapses back to `--limit`, making the off-switch a true no-op.

### Abstention floor

`ks_search` can decline to answer a query at all: below a **measured** floor on
the shipped hybrid+rerank surface, it returns the same genuine
**zero-result** shape a backend-empty query gets, instead of confident-looking
low-relevance hits (foundation#1450, epic foundation#1443). **Off by default**
— set `KNOWLEDGE_SEARCH_ABSTAIN=1` to enable it.

The gate looks only at the **top-ranked, post-re-rank candidate** (if the best
one fails, none of the rest can pass either) and requires **both** of the
following to fail — a conjunction, not either surface alone:

| Setting | Default | What it gates |
|---|---|---|
| `KNOWLEDGE_SEARCH_ABSTAIN_SCORE_FLOOR` | `0.72` | the candidate's own backend `.score` |
| `KNOWLEDGE_SEARCH_ABSTAIN_LEX_FLOOR` | `0.10` | the candidate's lexical-coverage feature `L` (the re-rank's own title/path term-agreement score) |

**Why a conjunction, and why these two surfaces.** Two single-surface floors
were measured and rejected on the 213-query engine-neutral golden-query bench
(foundation's `workflows/scripts/evals/golden-queries/`, 204 labeled + 9
correct-abstention queries): raw `.score` alone is query-relative (the
re-rank's own trap 1) and the 9 correct-abstention queries' top score
(0.65–0.76) sits inside genuine hits' own range (0.58–1.28); the re-rank's RRF
fusion score `.f` is rank-dominated and near-constant for every query's
top-ranked candidate regardless of relevance, so it carries almost no
separating signal either. The conjunction of raw score AND lexical coverage
does separate, because a genuine hit in this corpus is almost always a strong
semantic match, a strong lexical match, or both.

**Measured result** (two independent runs, byte-identical — the fused
candidate order is deterministic here; only *tie-breaking* among near-equal
ranks jitters, per trap 3): at the shipped defaults, **4 of the 9
correct-abstention queries newly abstain, and 0 of the 186 labeled top-5 hits
are lost.** See the CHANGELOG `[Unreleased]` entry for the full numbers and
the small-*n* caveat (only 9 correct-abstention examples exist at all, so the
floors are calibrated to, not validated against a held-out set of, them — the
zero-measured-cost property is the load-bearing safety claim; the 4/9 recall
figure is directional).

**The rg-fallback interaction (ratified L1 mode-sweep semantics).** An
abstention here is a **post-re-rank empty**, never a **backend-empty** — the
backend returned real candidates; the floor discarded them. The score-0
ripgrep lexical fallback (`ks_search__rg_fallback`, foundation#950) fires
*only* on a genuine backend-empty, so it stays **suppressed** on a
floor-triggered abstention even when a literal corpus match exists
(`abstained=1`, `rg_fallback=0`) — returning nothing is the intended,
scored-correct outcome, not a fallback opportunity.

Internally, `_ks_bm_rerank` signals an abstention with one sentinel line,
`{"__ks_abstain":true}`, in place of its normal JSONL stream; `ks_search` is
the one place that consumes it, converts it to the real empty-result shape,
sets the `abstained` outcome field, and suppresses the rg fallback. The
sentinel never reaches a caller. Both backends share this — one
implementation (`_ks_bm_rerank`), reused by the warm `basic-memory-mcp` path
exactly as the re-rank itself is.

### Backend registration seam

Mirrors `knowledge_store`'s: `KNOWLEDGE_SEARCH_BACKEND` (kebab-case,
default `basic-memory`) selects a set of `_ks_search_backend_<name>_<op>`
functions, `<op>` ∈ `search`, `reindex`, `available`. This file implements
one backend, `basic-memory`, fully.

### The `basic-memory` backend (spike verdict, F#776, 2026-07-02)

The Phase-0 spike selected [basic-memory](https://github.com/basicmachines-co/basic-memory)
v0.22.1 as the kernel default search backend (over a thin-indexer
fallback). It runs **strictly as an external CLI subprocess** — never
imported or vendored in this repo's source — because basic-memory is
licensed AGPL-3.0 and this repo is not. See "AGPL boundary" below.

The adapter's required posture, every point implemented in
`knowledge_search.sh`:

1. **`disable_permalinks: true`** in `config.json` **and**
   `BASIC_MEMORY_DISABLE_PERMALINKS=true` in the subprocess environment
   (belt and suspenders — `_ks_bm_run`).
2. The full no-mutation config set, written **before** the first index:
   `ensure_frontmatter_on_sync: false`, `format_on_save: false`,
   `update_permalinks_on_move: false`, `kebab_filenames: false`.
3. **`sync_changes: false`** — the watcher is never run (sidesteps upstream
   basic-memory #1016 and watcher-side mutation). Sync is always an
   explicit `ks_search_reindex` call (a post-pull hook / cron entry point),
   never a background daemon.
4. The adapter **never runs `basic-memory mcp`** (sidesteps upstream
   #1017). Every call is `basic-memory tool ...` / `basic-memory project
   ...` / `basic-memory reindex ...` — CLI-only, JSON-shaped stdout parsed
   by `jq`.
5. **`auto_update: false`**; the version is pinned by INSTALLING it as a uv
   tool — `uv tool install --python <ver> basic-memory==0.22.1`
   (`KNOWLEDGE_SEARCH_BM_VERSION`, default `0.22.1`) — and invoking the
   installed entry point, rather than resolving `uvx --from
   basic-memory==<pin>` on every call (temperloop#1113: `uvx` has no
   permanent install location, so uv unpacked a live environment into its
   cache per resolution with nothing expiring them — 30 GB against a 273 MB
   store, and unprunable for as long as a warm daemon held the cache lock).
   The installed pin's identity (version **and** interpreter) is stamped
   beside the entry point and re-checked on every call, so **changing either
   pin re-installs** rather than silently continuing to run the old build.
   Upgrading the pin is a deliberate adapter change, not silent drift. The
   **interpreter is pinned too** (`--python <ver>`,
   `KNOWLEDGE_SEARCH_BM_PYTHON`, default
   `3.13`): the version pin alone still let uv resolve the host's newest
   CPython, and a resolution onto a version some dependency ships no
   prebuilt wheel for triggers a from-source native build that can fail on
   hosts without the build toolchain (temperloop#368 / foundation#1176 —
   litellm had no cp314 wheel and its maturin/PyO3 build failed). Bump the
   two pins together, deliberately.
6. **Isolated state**: a dedicated `HOME` for the `basic-memory` subprocess
   (`KNOWLEDGE_SEARCH_BM_HOME`, default
   `${XDG_STATE_HOME:-$HOME/.local/state}/foundation/basic-memory-home`),
   so `~/.basic-memory/{config.json,memory.db}` under that isolated HOME is
   adapter-owned and never touches Travis's real home directory. The uv tool
   install of point 5 is pinned into the same isolated home
   (`UV_TOOL_DIR`, `UV_TOOL_BIN_DIR`, and `HOME` all point inside it), so
   nothing lands in the operator's `~/.local/{share,bin}` and the invocation
   is by absolute path — a system-wide `basic-memory` can neither be picked
   up by accident nor shadowed by the adapter's.
   `semantic_embedding_cache_dir` is pinned inside it too (confirmed live:
   the fastembed model download lands under the pinned cache dir, not the
   machine's shared HF cache).
7. **`semantic_embedding_model: bge-small-en-v1.5`** kept as the default
   explicitly (avoids upstream #1023's non-bge normalization bug) — written
   together with the **`semantic_embedding_dimensions`** that model requires
   (`384`). The two are a **single setting with two config keys**, not two
   independent literals: the model is authored once
   (`_ks_bm_embedding_model`) and the width is *derived* from it through a
   model→width table (`_ks_bm_embedding_dimensions`), which fails loudly on
   a model it has no width for. A config that names a model but carries a
   mismatched (or absent, hence defaulted) width silently produces a
   **zero-embedding index** — it builds without error and every semantic
   search then returns nothing — so a model flip that could set one without
   the other is structurally prevented rather than caught by review
   (temperloop#907). Flipping the model means editing one literal and adding
   its width to that table in the same edit.
8. **CI caching guidance**: cache `memory.db` and the fastembed model cache
   (`semantic_embedding_cache_dir`) as build artifacts across CI runs.
   Approximate cost, from basic-memory's own documentation: a cold rebuild
   runs ~23 min per 1k dense notes; an incremental `reindex` (the default,
   no `--full`) runs 2-3 min; `reindex` is safe to re-invoke on a CI-timeout
   retry — it resumes rather than restarting.
9. **Project registration via the CLI only**: `basic-memory project add
   <name> <path>` — never by editing `config.json`'s `projects` map
   directly (config-only edits to that map are not honored in 0.22.1;
   confirmed live). `project add` is idempotent — a repeat call against an
   already-registered project prints "already exists" and exits 0 — so
   `ks_search`/`ks_search_reindex` call it unconditionally on every
   invocation rather than tracking registration state separately.

All nine points were verified against the real 0.22.1 CLI during adapter
authoring (network-available session, 2026-07-02): a 3-note temp corpus was
registered, indexed, and queried via `basic-memory tool search-notes
--hybrid`, confirming the config-merge behavior (a `config.json` holding
only the override keys above is merged with the tool's own defaults — no
need to restate its full schema), the clean stdout/stderr split (progress
and model-download chatter go to stderr; `tool search-notes` stdout is pure
JSON), and the cache-dir pinning. See `.build-verification.md` in the
adapter's worktree for the full transcript.

### Legible degradation

When the pinned tool cannot be made available, `ks_search`/
`ks_search_reindex`/`ks_search_available` all return exit 3 with a message
beginning `skipped — knowledge_search unavailable:` on stderr and **print
nothing to stdout**. Two causes reach it: `uv` is not on `PATH`, or the
one-time `uv tool install` of the pinned version failed (uv's own output is
surfaced, tail-bounded, rather than swallowed).

`ks_search_available` is therefore **not a pure predicate** since
temperloop#1113: on the basic-memory backend it LAZILY INSTALLS the pin when
it is absent, so "available" means "can answer a search", including after a
one-time install. That is the second half of the hybrid install design —
`workflows/scripts/install/doctor.sh` installs and reports the pin for an
installed checkout, and this gate keeps the zero-setup first run working for
a stranger who never runs doctor. `ks_search_available --quiet` suppresses
only the `skipped —` notice (never install progress), for a caller that
probes before dispatching and does not want the notice printed twice.

**`ks_search_available --probe` is the zero-side-effect arm** — it answers
"is the pin installed right now" (exit 0 ready / exit 3 not) and never
installs, never writes. Any caller using this as a *cheap predicate* rather
than as "I am about to search" MUST pass `--probe`: a hermetic test, a
graceful-skip capability check, a dry-run gate. The bare op inside a test
sandbox will otherwise perform a real network install, which is how the
KERNEL_GATES entry `scripts/tests/test_stranger_config.sh` briefly became
network-dependent during this change (kernel principle 3). A caller that pipes `ks_search` output into further processing
without checking the exit code would see an empty stream either way (zero
matches vs. unavailable) — checking the exit code is required to
distinguish them; this is why the contract calls out exit 3 as a distinct,
documented code rather than folding it into the zero-results case.

### AGPL boundary

basic-memory is AGPL-3.0. This repo holds no AGPL-3.0 code and must not —
so the adapter's only contact with basic-memory is spawning it as a
subprocess and reading its stdout. No basic-memory source is vendored, no
Python import of `basic_memory` exists anywhere in this repo, and no
build/dependency manifest here declares it as a package dependency (it is
installed by `uv` into the adapter's own isolated home, out of tree — never
into this repo's own environment). `workflows/scripts/lib/tests/test_knowledge_search_agpl_boundary.sh`
enforces this mechanically: it fails if a vendored `basic-memory`/
`basic_memory` path appears in the tracked tree, if a Python `import
basic_memory` appears anywhere, or if any shell line invokes `basic-memory`
as a bare command word (which could only mean a `PATH` lookup escaping the
adapter's pinned, absolute-path entry point).

### Obsidian-mode note

Post-cutover (temperloop#1570, the kernel half of foundation epic #951
Phase 3), the knowledge store is **markdown-canonical**: the files under
`ks_root` are the source of truth, and Obsidian — where a store happens to
be an Obsidian vault — is a *viewer* onto them, not the agent-plane's
transport. **Agent-plane** access — a Claude session reading or
concept-searching its own project's notes — no longer routes through
Obsidian's MCP tools for those two ops:

- A **read** resolves the doc's path against `ks_root` (per this contract's
  `ks_root` / doc-id normalization above) and uses the `Read`/`Glob` file
  tools directly, exactly as it would read any other file in a checkout.
- A **concept/idea search** uses `ks_search` (§ `knowledge_search` above) —
  the same script-plane / headless path a script or hook already used, now
  also the agent-plane default. There is no longer a separate
  `search_vault_smart` index to keep in parity with `ks_search`'s; the
  Phase-1 parity-comparison era (both engines run, results compared) is
  over — `ks_search` is the one path.

A **write** (`vault_append` / `vault_write` / `vault_patch` / `vault_move` /
`vault_delete`) is **unaffected by this note** and stays on the Obsidian MCP
tools — this cutover is reads and search only; see
`~/.claude/CLAUDE.md` § Obsidian vault for the write-side contract.

**The script-plane backend choice is a separate, orthogonal axis and is
unchanged by this note.** `KNOWLEDGE_STORE_BACKEND=plain-files` (direct
filesystem I/O, the default) vs. `KNOWLEDGE_STORE_BACKEND=obsidian`
(document I/O routed through the Obsidian Local REST API — see `## The
obsidian backend` above) still governs how `ks_read`/`ks_write`/`ks_append`/
`ks_list` themselves talk to storage; nothing above changes that matrix. The
agent-plane posture in this note is about how a live Claude session reads
and searches — it applies whenever the store resolves to a filesystem path
the session can `Read`/`Glob` directly (the ordinary case for a local vault,
`KNOWLEDGE_STORE_BACKEND` notwithstanding), independent of which backend a
script uses to reach the same bytes over REST.

### Non-goals of this seam (search)

- **No search over non-store content.** `ks_search`'s index is exactly
  `ks_root`'s documents — it does not index code, board issues, or
  anything outside the knowledge store. (A **partition scope** narrows what
  a given call *returns* from that index; it never widens what is indexed.)
- **No store-layer tenancy.** The partition scope is a search filter only —
  `ks_read`/`ks_write`/`ks_list`/`ks_sync` remain unpartitioned, and the
  store offers no at-rest isolation between projects. Separate `$HOME`s (and
  therefore separate roots) remain the only hard boundary.
- **No live-watch indexing.** Point 3 above — indexing is always an
  explicit `ks_search_reindex` call.
- **No caller routing.** Like the document-I/O interface, no existing
  hook/command in this repo calls `ks_search` yet; that is later,
  sibling-level work.
