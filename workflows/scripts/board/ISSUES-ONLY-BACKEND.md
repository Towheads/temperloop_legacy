# Issues-only tracker backend — label/status/milestone contract

foundation #799, split 1/3 of the issues-only tracker adapter (Epic B, kernel
extraction). This is the contract the other two splits build on:

- **split 2/3 (claim/edges/cascade, foundation #800 — IMPLEMENTED)** — the
  cross-session claim lock (Host/Session equivalent), parent/child + blocking
  dependency edges, and the close→Done cascade, for a board that has no
  Projects-v2 fields to stamp. See § Claim lock, § Parent/child and
  dependency edges, and § Close→Done cascade below.
- **split 3/3 (pipeline integration)** — wiring `pipeline-tick.sh` /
  `pipeline-drive.sh` to drive an issues-only repo.

Both consume the vocabulary and function-level interface below. **Do not
invent a second label scheme or a second set of adapter functions** — extend
this one (subtraction over mechanism).

## What "issues-only" means

A board is either **issues-only** (no Projects board is ever provisioned or
queried; item CRUD and Status ride plain `fnd:`-namespaced GitHub **labels**
on the repo's Issues, and "Done" is simply **the issue being closed** — see
§ Issues-only is now the default backend, below) or **Projects-v2-backed**
(a GitHub Projects board provisioned, everything in `lib/board.sh`'s
pre-#799 code path — the deprecated legacy arm during the soak window
described below). Milestone intake (release-phase axis) is unaffected
either way — see below.

## Issues-only is now the default backend (temperloop#460 — issues-only tracking everywhere, ADR 0004/0005)

**Supersedes** every earlier framing in this file (and in
`docs/features/board-adapter.md`) that described issues-only as "board 7's
sole exception" to a Projects-v2 default. That framing is retired.
[ADR 0004](../../../docs/adr/0004-issues-only-default-backend.md) makes
issues-only the default tracking backend for every board; the four
maintainer repos (ssmobile / board 5, stageFind / board 3, subsetwiki /
board 6, foundation / board 4) have all migrated off their Projects-v2
boards, alongside the kernel tracker (board 7) that was already
issues-only from the start. Every board this project's own pipeline drives
today runs `backend=issues`.

Mechanically, per
[ADR 0005](../../../docs/adr/0005-repo-local-conf-cutover.md), the four
fleet boards (3–6) got there the same way: a **committed `boards.conf`
entry in its own consuming repo** (`board.<N>.backend=issues`), never a
change to this adapter's built-in fallback map. Board 7 got there
differently, and earlier — it was already registered directly in the
built-in map (foundation #808, § The temperloop tracker below), not via a
`boards.conf` entry, and this migration left that pre-existing registration
untouched. Either way, the adapter's own code-level fallback —
`board_backend` resolves an unconfigured board to `"projects"` — is
deliberately **untouched** by this migration (see § Selecting the backend
below), so "the default" above is a fleet/policy default (every board this
pipeline actually points at is configured issues-only, one way or the
other), not a change to the adapter's own code-level fallback. A brand-new
board registered with no `boards.conf` entry still needs `backend=issues`
written explicitly to get the same behavior — see the soak-period paragraph
below for what removing that fallback would take and who owns it.

**Soak-period rule.** Issues-only is the sole canonical path for all
tracking work from here on — every pipeline command (`worklist`, `claim`,
`capture`, `reconcile`, `/triage`, `/assess`, `/build`) is expected to run
against `backend=issues` boards only. The four fleet repos' frozen
Projects-v2 boards (temperloop/board 7 never had one to freeze — it was
issues-only from the start) stay provisioned and readable through a soak
window (any post-flip write to one of them is the tell of a lagging,
unsynced checkout still driving the dead arm — ADR 0005), but they are not
written to going forward and are not part of the supported path. The
Projects-v2/GraphQL arm itself (the budget guard, the structure/state cache
split, the dual-adapter branchwork) is **deprecated, not removed** — it
stays in the codebase only to serve that soak window and any
as-yet-unconverted board. Deprecation-marking the arm and filing the
follow-on breaking-change removal epic is tracked as temperloop#476
(Projects-arm deprecation) — #476 is the item that does that
marking-and-filing, it is **not itself the removal epic**, and the removal
epic doesn't exist yet as of this file. Neither this file, the migration
epic behind it, nor #476 performs the removal itself — nothing above or
below should be read as a removal timeline.

## Selecting the backend

**There is nothing to select. Issues-only is the only backend** (ADR 0004).
A board needs exactly one axis — its repo:

```
board.<N>.repo=<owner>/<repo>
```

`board_backend <N>` returns `issues` unconditionally.

### The `backend` axis is retained solely to REFUSE a stale `projects` line

The `board.<N>.backend=` axis still parses, but it no longer selects
anything. It has one job left: a conf line reading **`backend=projects`
hard-fails** with a one-line error naming ADR 0004 and the migration path,
and `board_backend` returns non-zero. Every public entry point
(`board_resolve`, `board_resolve_item`, `board_item_list`,
`board_create_many`) propagates that refusal rather than proceeding.

This deliberately does **not** silently resolve to `issues`. A stale
`backend=projects` line expresses a real operator intent this build can no
longer honour, and quietly reinterpreting it would move that board's state
onto a different substrate with no signal — which is precisely the failure
**temperloop#908** recorded: a silently reverted cutover put four boards on
the wrong path and was only found by hand. A backend that changes under you
with nothing telling you is the thing this refusal exists to prevent. There
is **no configuration path back** to Projects-v2; an adopter who wants it
forks `board.sh`.

### Superseded: "the built-in map is additive-only, with board 7 its sole in-code exception"

This section previously stated that the built-in case map was
**additive-only**, that an unconfigured board resolved `"projects"` and emitted
byte-identical `gh project …` argv, and that **board 7 was the sole in-code
issues-only exception**. **All of that is superseded, as of this release, by
the removal of the Projects-v2 arm.**

The supersession is the documented, deliberate one ADR 0005 anticipated
rather than an incidental drift. ADR 0005 § Decision records that the
additive-only rule and its config-selection test pin "survive intact and are
**superseded only by the follow-on removal epic, which retires the Projects
defaults explicitly**", and ADR 0005 § Consequences pins the same point: "the
supersession of the 'board 7 is the sole permanent exception' language is
deliberate and documented at removal time, not shipped silently mid-migration."
This is that removal (epic temperloop#524) and this is that documentation.

What replaces it: there is no Projects default left to be additive to, so
board 7 is no longer an *exception* to anything — it is simply one
issues-only board among all of them, and its built-in-map `repo` entry is now
its only special-cased axis (see § The temperloop tracker below).

`owner` remains a live axis (a board's owning login); `project` was retired
with `board_project_number()`.

## What `fnd:*` labels mean

Every `fnd:`-prefixed label on an issue is bookkeeping this board adapter
itself reads and writes — Status, Component, and claim ownership. If you
(or a teammate) don't run this tooling, you can simply **ignore them**:
they carry no special meaning to plain GitHub, don't affect notifications,
search, or any other GitHub feature, and nothing breaks if they're left
alone or even removed by hand (the adapter just re-derives state from
whatever's there, or isn't, on its next read/write).

**Adopting this on a shared repo is a team decision, not an individual
one.** The labels land in shared, repo-visible tracker state every
collaborator sees — not a private view scoped to whoever runs the tooling.
Bringing this pipeline onto a repo with other maintainers is worth raising
with them first, the same way you'd raise adopting any other shared
convention (a linter config, a commit-message format).

**The claim stamp is a real, verbatim hostname — said plainly.** The
`fnd:host/session:<host>:<session>` stamp (see § Claim lock below) is
stored **verbatim, never slugged or redacted**: whatever hostname the
claiming machine reports is what lands in a repo-visible label. On a repo
you don't fully control — a shared team repo, a client's repo — weigh that
exposure before claiming from a machine whose hostname you'd rather not
publish there. This is documented, intentional behavior (see § Claim lock's
"Storage" bullet for why it can't safely be slugged), not an oversight —
nothing in the adapter offers to mask it.

### The label vocabulary

The label set (the Status values, Component, the claim stamp) is tabled ONCE, in `workflows/scripts/config/ontology-registry.tsv` (`label-field` + `state:issue-status` rows; ADR 0032 (ontology registry is source of truth)) and enforced by `check-ontology-registry.sh` — never restated here.

General rule: a label is `fnd:<field-slug>:<value-slug>`, where `<field-slug>`
is the field name lowercased with spaces→hyphens (`Status`→`status`,
`Component`→`component`) and `<value-slug>` is the option name slugged the
same way (`"In Progress"`→`in-progress`) — so the three Status labels are
`fnd:status:backlog`, `fnd:status:ready` and `fnd:status:in-progress`, and
Done is the absence of any of them. This is generic over any future
single-select-shaped field — no new plumbing needed to add one, just start
writing `fnd:<new-field-slug>:*` labels.

**Done is the one exception.** It carries **no label at all** — closing the
issue *is* the Done signal. Moving an item to Done strips any residual
`fnd:status:*` label and closes the issue; moving it *off* Done (to any other
status) reopens the issue and writes the new label. A read of a **closed**
issue always reports `status: "Done"` regardless of what labels remain on it
(defensive against stale labels from before this convention, or a manual
close). An **open** issue with no `fnd:status:*` label reads as unstatused
(no `.status` key) — distinct from Done.

Because an unstatused open issue reads as `.status = ""`, **`/triage`'s Backlog
intake silently skips it** (Adapter A keeps only `.status == Backlog`), so a
genuine defect can fall out of the pipeline with no error (temperloop#376). The
capture path (`capture.sh` → `board_capture_item`) already stamps
`fnd:status:backlog` on every issue it files — so the normal front door never
produces one — but an issue reaching the tracker by any *other* route (a hand
`gh issue create`, an older/foreign tool) can land unstatused. `reconcile.sh
--labels` is the backstop: its third label-hygiene scan reports every unstatused
open issue, and `--apply` **backfills `fnd:status:backlog`** (the safe default —
it only makes the issue visible to the next Backlog sweep, reversible via a
later status write). See that file's Lens 3 header, class (i).

At most one `fnd:status:*` label and one `fnd:component:*` label are present
on an issue at a time (single-select emulation): a status/component write
removes every other label sharing its prefix before/without re-adding the
target, and re-setting the already-current value is a no-op at the gh-call
level (no duplicate add, no needless close/reopen).

**Round-trip fidelity:** a value's *display form* is reconstructed from its
slug by title-casing each hyphen-separated word (`in-progress` → `In
Progress`). This is exact for the built-in Status vocabulary above. For a
`Component` value, whatever slug you write is what you get back
title-cased — pick component slugs you're happy to see re-title-cased (e.g.
`fnd:component:ingest` round-trips as `"Ingest"`; a slug with an
internally-capitalized display form, e.g. an acronym, will NOT round-trip
exactly — this is a known, accepted limitation of the generic slug/unslug
convention, not a bug).

## Function-level interface parity

Every adapter function a caller already uses works **unchanged** — same
name, same signature, same return semantics — selected purely by
`board_backend`. A consuming script (claim.sh, capture.sh, worklist.sh,
board-mirror.sh, pipeline-tick.sh, …) needs **zero branching** on backend.

| Function | Issues-only behavior |
|---|---|
| `board_resolve <board#>` | No `gh project view/field-list`; `BOARD_ITEMS_JSON` = every OPEN issue reshaped (see below); `BOARD_PROJECT_ID=""`, `BOARD_FIELDS_JSON='{"fields":[]}'`. |
| `board_resolve_item <board#> <issue#>` | Single `gh api repos/<repo>/issues/<n>` read (always-live, sees Done too — unlike the whole-board read, which excludes closed issues the same way `-status:Done` excludes them on the Projects path). |
| `board_item_list <board#>` | `gh issue list -R <repo> --state open --json number,title,labels`, reshaped. Live only — no on-disk cache (REST's separate 5,000/hr bucket, not the Projects-v2 GraphQL budget the cache layer protects). |
| `board_item_id` / `board_item_title` | Unchanged — generic jq over `BOARD_ITEMS_JSON`, which carries the same shape either way. |
| `board_set_status <item-id> <option> [field]` | `item-id` is `ISSUE_<n>` (the issues-only counterpart to `PVTI_*`). Writes/removes `fnd:` labels + drives open/closed for Status; no Projects call. |
| `board_close_done <board#> <issue#>` (NEW, temperloop#1217) | Guarded, state-independent composition over `board_set_status … Done`: builds the deterministic `ISSUE_<n>` item id directly (no `board_item_id`/`board_resolve_item` lookup — the whole-board list is `--state open` only, so it would silently no-op on an already-closed issue) and saves/restores `BOARD_CURRENT`. Lands Done from ANY state — open, already closed, or already Done (no-op). See § Close→Done cascade below for why this is the primary write path on this backend, not a backstop. |
| `board_set_component <item-id> <name>` | Thin wrapper over `board_set_status`, unchanged. |
| `board_create_many` / `board_create_on_board` / `board_capture_item` | No `gh project item-add`, no index-lag retry (a label write is synchronous REST). Landing a fresh issue collapses to labeling it Backlog. **Return contract is identical across backends** (foundation #1226): 0 on full success, 1 on partial failure, 2 on total failure, with `BOARD_UNLANDED_ISSUES` carrying the space-separated un-landed issue numbers on any non-zero return — `_board_issues_create_many` (the issues-only twin of `board_create_many`) implements the same three-way return, it just never has an index-lag failure mode to hit (a label write is synchronous REST, so the only failure is the `gh` call itself erroring). |
| `board_active_milestones` / `board_set_milestone` / `board_set_milestone_description` | **Unchanged, no new code** — these were already REST-only (`repos/<repo>/milestones…`) and backend-agnostic before this split. Milestone intake (the `<!-- triage:active -->` marker convention) works identically on an issues-only board. |
| `board_blocked_by_open` / `board_parent_issue` | **Unchanged, no new code** — same reason (per-issue REST, never Projects). Backend-agnostic for free: works identically on a Projects-v2 or issues-only board. |
| `board_blocked_by_add` / `board_blocked_by_remove` (NEW, #1221) | Write-side counterpart to `board_blocked_by_open` — add/remove a native `blocked_by` dependency edge (resolve the blocker's REST db id → POST/DELETE the dependencies endpoint). Same shape as its reader sibling: per-issue REST, always live, backend-agnostic, no Projects call. Closes the reader-without-writer gap that forced dependency-edge writes through raw REST. |
| `board_sub_issues` (NEW, #800) | Read-side counterpart to `board_parent_issue` — child issue numbers via GitHub's native sub-issues REST endpoint. Same shape as its siblings: per-issue REST, always live, backend-agnostic. See § Parent/child and dependency edges. |
| `board_add_sub_issue` / `board_remove_sub_issue` (NEW, temperloop#1188) | Write-side counterpart to `board_sub_issues` — link/unlink a native sub-issue (resolve the child's REST db id → POST the collection endpoint / DELETE the singular `sub_issue` endpoint keyed by that id in the request body). Same shape as `board_blocked_by_add`/`_remove`: per-issue REST, always live, backend-agnostic, no Projects call. Closes the reader-without-writer gap that forced sub-issue linkage writes through raw REST in `build.md`/`triage.md`/`board-mirror.sh`. |
| `board_stamp` (#800 — now IMPLEMENTED) | `ISSUE_n` routes to a free-text `fnd:host/session:<verbatim-text>` label (single label of that prefix kept at a time; empty text clears). See § Claim lock. |
| `board_claim_contended` (NEW, #800; extended to Projects-v2) | Backend-agnostic pre-check: is `<issue#>` already In Progress under a DIFFERENT Host/Session stamp? See § Claim lock. Reads the already-resolved `BOARD_ITEMS_JSON` on either backend — no extra `gh`/GraphQL call. |
| `board_set_number` | **Retired by design (ADR 0006), not emulated.** Seq/worklist ordering is not owned by the claim/edges split and has no future item to land it — an `ISSUE_*` item-id has no Projects-v2 field schema to resolve a number field against, and no `fnd:seq:<n>` label encoding was introduced to fake one (that would mint an unbounded numeric label namespace, recreating the label sprawl this migration removes). Work ordering on this backend lives in epic dependency levels and milestones instead. On an issues-only board this **fails loud** (return 1, plus a documented stderr message naming the retirement — no silent no-op) — intentional, not a gap to route around. |

The item shape produced by the issues-only reshape:

```json
{"id":"ISSUE_105","content":{"number":105,"title":"…","type":"Issue"},"status":"Ready","component":"Ingest","labels":["fnd:status:ready","spike"],"milestone":{"title":"Phase 2"}}
```

— identical keys to the Projects-v2 shape (`id`, `content.number/title/type`,
flattened field values, **`labels`** — see § Pipeline integration below — **and
`milestone`** — see § Milestone read passthrough below),
so every existing jq-based reader of `BOARD_ITEMS_JSON` works without
modification. The `milestone` key is present only when the issue carries one
(omitted otherwise, the same optional-field style as `component`/`host/Session`).

### Milestone read passthrough (temperloop#154)

`board_item_milestone <n>` reads `.milestone.title` out of `BOARD_ITEMS_JSON`.
The Projects-v2 path gets that for free (`gh project item-list` emits
`.milestone = {title, description, dueOn}`), but the issues-only `issue_item`
reshape originally emitted **no** `milestone` key at all — the same class of
dropped-field bug the #801 `labels` passthrough fixed. The consequence was
silent: `board_item_milestone` always returned empty on an issues-only board, so
`/triage`'s active-milestone **intake filter** (intake IFF unmilestoned OR
milestone active) treated every item as unmilestoned and wrongly **intook** a
Backlog item sitting on an INACTIVE milestone instead of deferring it (and the
mandatory Step-5 deferred-at-intake count read zero). Fixed by (a) requesting
`milestone` in `_board_issues_item_list`'s `gh issue list --json` field list and
(b) emitting `{ title }` from the reshape, so `board_item_milestone` works
unchanged on both backends. The single-issue read
(`_board_issues_resolve_item`, `gh api …/issues/<n>`) already carried the full
issue object, so it only needed the reshape half. Pinned by
`tests/test_issues_backend.sh` case 3 (a milestoned issue's title round-trips;
an unmilestoned one reads empty and carries no `.milestone` key).

## What split 1/3 (#799) intentionally did not do

- **No caching.** The issues-only path is always-live. It draws on REST's own
  5,000/hr budget, not the Projects-v2 GraphQL budget the on-disk cache in
  `lib/board.sh` exists to protect, so the caching machinery is simply not
  needed here. A future perf pass can add it if an issues-only board's volume
  ever makes this the bottleneck.
- ~~No claim lock / Host/Session.~~ **Filled in by #800** — see § Claim lock.
- ~~No parent/child or dependency edges.~~ **Filled in by #800** (mostly for
  free — see § Parent/child and dependency edges) — see that section.
- **No Seq ordering.** Retired by design, not deferred (ADR 0006) — see
  `board_set_number` above.
- **No pipeline wiring.** That's the pipeline-integration split (3/3).

## Claim lock (Host/Session-equivalent, foundation #800)

The Projects-v2 path's cross-session lock is two ordered writes to a
project item: `board_stamp` (owner metadata, "Host/Session" free-text field)
then `board_set_status` (the observable commit, Status → In Progress) — see
`claim.sh`'s own header comment for the stamp-first/commit-last safety
ordering (foundation #103/#135). **Notably, the Projects-v2 path never checks
before writing** — a second claim silently overwrites the first; the only
backstop is `reconcile.sh`'s separate, report-only "foreign claim" sweep
(never auto-releases).

The issues-only backend reuses the exact same two calls unchanged
(`board_stamp` / `board_set_status`, now both implemented for `ISSUE_*`) but
additionally REFUSES a genuinely contended claim, because the check is cheap
here (the item is already resolved by `board_resolve_item` before `claim.sh`
writes anything — no extra `gh` call):

- **Storage.** The stamp (`"<host>:<session8>"`, e.g. `mini:c33dce41`) is
  written as a single `fnd:host/session:<verbatim-text>` label — the ONE
  exception to the general `fnd:<field-slug>:<value-slug>` single-select
  convention: the value is stored **verbatim, never slugged**. Slugging
  lowercases, which would corrupt a mixed-case hostname and silently break
  the foreign-host comparison below. At most one label of this prefix is
  kept at a time (same single-value-per-field mechanics as Status/Component);
  an empty stamp clears the label (mirrors the Projects-v2 `--clear`
  semantics, foundation #259 — this is what makes build's epic park-back
  stamp-clear work here too). Read back, the value surfaces under the flattened
  key `"host/Session"` — the SAME key `reconcile.sh` / `worklist.sh` already
  read on the Projects-v2 path, so neither needed a single line of
  backend-branching to work against an issues-only board.
- **Growth.** Distinct stamp VALUES accumulate as distinct repo-level label
  objects over the tracker's lifetime (there is no safe "still referenced
  elsewhere" check before a `gh label delete`, since the same host:session
  commonly claims several issues). Growth is bounded by the number of
  distinct sessions that have ever claimed something on this repo, not by the
  number of claims (`gh label create` is idempotent/memoized) — accepted as
  cosmetic for realistic tracker volume.
- **Contention check.** `board_claim_contended <board> <issue#> <new-stamp>`
  (new function) reads the already-resolved item: CONTENDED iff the issue is
  currently In Progress AND carries an existing stamp that is present and
  DIFFERENT from `<new-stamp>`. Two cases are deliberately NOT contended,
  matching the Projects-v2 adoption behavior `test_claim.sh` case 3 pins:
  re-claiming with your OWN stamp (idempotent), and adopting an In-Progress
  item with NO existing stamp (repairing a half-claim, the #103 failure
  mode). `claim.sh` calls this once, right after resolving the item and
  before writing anything; on a contended result it prints who holds the
  claim and refuses (non-zero, no writes) rather than silently overwriting.
  On a Projects-v2 board this always reports "not contended" — the
  historical silent-overwrite behavior is completely unchanged there.
- **Release is local-only PLUS one narrow board-side clear (temperloop#979).**
  `release.sh` originally never touched the board on either backend — it only
  cleared the terminal marker. That left a hole on exactly this backend's
  **park** path: the claim owner lives in a `fnd:host/session:*` LABEL, an item
  parked back to Ready never reaches Done (whose write is what strips the
  stamp), and `reconcile.sh --labels` swept only CLOSED issues — so the stamp
  sat on an open, Ready issue reading as a live claim by a session that is
  gone. `release.sh` now also clears that stamp, but only when **all** of:
  an `<issue#>` **and** `--board <N>` were passed, the board is issues-only,
  the item is **not In Progress** (an In-Progress stamp is a live claim HELD
  until Done — K#275 — and is left in place with a notice), and the stamp is
  **this session's own** (a foreign stamp is reported and routed to
  `reconcile.sh --labels`, never erased from here, so a peer's in-flight claim
  — `claim.sh` stamps the owner *before* it flips the status — can never be
  lost). It clears through `board_stamp <item> Host/Session ""`, the adapter's
  one existing clearing implementation, and it never changes `release.sh`'s
  exit status: every board-side failure degrades to a stderr notice, because a
  park must never fail on a release. It still never moves the board STATUS —
  that stays `unclaim.sh` or a deliberate park. The backstop for every park
  that did NOT run it (or ran it from a later session, whose foreign stamp it
  refuses to touch) is `reconcile.sh --labels`' class (m).

## Parent/child and dependency edges (foundation #800)

Both relationships ride GitHub-native, per-issue REST endpoints that work on
a **plain issue with no Projects board provisioned at all** — so almost
everything here was already backend-agnostic before this split touched it:

- **Parent** — `board_parent_issue <board> <issue#>` (pre-existing, foundation
  #159, unchanged) resolves a sub-issue's parent epic from
  `.parent_issue_url`. Empty output = a directly-workable singleton (or an
  epic itself, which has no parent of its own).
- **Children** — `board_sub_issues <board> <issue#>` (NEW) is the read-side
  counterpart: `repos/<repo>/issues/<n>/sub_issues`, one child issue number
  per line. Same per-issue REST, always-live, backend-agnostic shape as its
  sibling.
- **Blocking dependencies** — `board_blocked_by_open <board> <issue#>`
  (pre-existing, unchanged) already reads GitHub's native issue
  *dependencies* relationship (`repos/<repo>/issues/<n>/dependencies/blocked_by`)
  — a first-class GitHub relationship, entirely separate from Status/labels/
  sub-issues, that was **already representable and readable on a plain issue
  with zero adapter code needed for this split**. No body-marker or
  label-based dependency scheme was invented (there was nothing to invent) —
  this is the "simplest faithful mechanism" the item description anticipated
  might be needed; it turned out to already exist. The **write** counterpart —
  `board_blocked_by_add` / `board_blocked_by_remove` (NEW, foundation#1221) —
  closes the reader-without-writer gap that had forced every dependency-edge
  write through raw REST: they resolve the blocker's REST db id (the id the
  dependencies WRITE API keys by, not its number) and POST/DELETE the same
  endpoint, backend-agnostic per-issue REST like the reader.

All three functions gate on candidate items only (never the whole board) —
same caveat as every per-issue REST accessor in this file.

### Durable-logical vs computed-merge-safety edges (docs/adr/0031, epic #1847 ("epic-as-metadata for operational work"))

The `blocked_by` edges above are GitHub-native and always live — but not every
edge in the pipeline is meant to live *there*. Two kinds coexist, and mixing
them up (storing one where the other belongs) is exactly the bug this split
guards against:

- **Durable-logical order** — a **meaning-level** fact ("the schema item
  precedes its consumers") that does not churn run to run. `/triage`'s Step 4
  materialization sub-step stamps this kind, for an **Operational** group's
  members only, as native `blocked_by` edges on the board — the one
  deliberate exception to the older "edges never live on the board"
  invariant, which docs/adr/0031 formally narrows rather than removes.
- **Computed merge-safety order** — a **re-derivable physical** fact (which
  PR must land before another to rebase cleanly) that genuinely does churn,
  and stays **plan-resident**, never stored durably: `/assess` recomputes
  `depends-on`/`after:` edges and dependency levels fresh into each `Plans/`
  note every run, and a **Foundational** group's ordering lives there
  instead of as a board edge, so no ordering ever has two live
  representations.

The read side is unchanged either way: `board_blocked_by_open` doesn't care
*why* an edge was stamped, only that it exists and is open — a
drive-time consumer (`/sweep`'s pool-build defers on it, `/next` skips a
blocked item advisorily) honors both kinds identically. The distinction
matters only at **write** time, and only to `/triage`, which is the sole
writer of the durable-logical kind.

### The `edges-considered` marker

Reading an **empty** `blocked_by` set is ambiguous on its own — it means
either "this group is genuinely unordered" or "this group's order was never
evaluated." `/triage` Step 4 item 9 resolves that ambiguity by posting an
HTML-comment marker, `<!-- triage:edges-considered -->`, on an Operational
group's epic as an issue comment once it has actually run the group's
members through the script-backed cycle check and stamped (or refused) every
edge — so the marker asserts "this group's order was genuinely considered,"
never merely "no edges exist." A run that degrades before reaching the
writer or the cycle check (a missing `board_blocked_by_add` helper, a
missing `cycle-check.sh`) posts **no** marker for that group, by design —
a marker posted over a run that never actually considered the group's order
would be a false all-clear.

`/sweep`'s Operational-epic member-admission gate (`workflows/scripts/build/sweep-epic-admission.sh`,
epic #1847) is the marker's consumer: it treats the marker's presence as a
precondition for admitting an epic's Ready legs into the sweep pool at all —
an epic whose order was never considered cannot safely have its members
driven independently and merged out of order. An epic missing the marker
(never triaged through the edge-stamping sub-step, or degraded on a prior
run) is simply not yet admission-eligible via that arm; a later `/triage`
pass that successfully stamps + posts the marker makes it eligible on a
subsequent `/sweep` run.

### The `keep-open` label

`/sweep`'s epic-closing gate (`workflows/scripts/build/sweep-epic-closing-gate.sh`,
epic #1847) considers closing an Operational epic once every one of its
members has drained (merged or resolved) — but an epic can legitimately need
to stay open past that point (the operator is still using it to track
follow-on work, for example). `keep-open` is the escape hatch: a plain
GitHub repo label, provisioned idempotently by `/sweep` before its per-epic
closing loop runs (`_board_issues_ensure_label`, the same probe-and-create
idiom the work-class labels below already use), that an operator (or a prior
run) applies to an epic to opt it out of auto-close. The closing gate reads
it as one branch of its precedence order — present → **report only** (never
offered for close, and no board write of any kind), naming who to ask
(the epic's most recent assignee, comment author, or issue author) so a
human can decide whether to remove the label and let a future run close it,
or leave it in place indefinitely.

## Close→Done cascade (foundation #800)

On a Projects-v2 board, GH #340's "close→Done" automation is a real, async
GitHub-side workflow: closing an issue triggers the board's built-in
automation to move the linked project *item*'s Status to Done, which
`_board_cache_bust`/the 90s items-cache TTL eventually observes (foundation
#589's accepted residual staleness gap).

On an issues-only board there is **no such automation, and nowhere to hook
one**. There is no project *item* for a board automation to move, and GitHub
exposes no native "on issue close, strip a label" rule for a plain Issues repo
— the GH #340 cascade has exactly one implementation, the Projects-v2 built-in,
and [ADR 0004](../../../docs/adr/0004-issues-only-default-backend.md) retires
the arm it lives on. **On this backend the cascade is not a mechanism that can
be relied on, because it does not exist** (temperloop#902: 9 of 9 closures
across two runs left `fnd:status:backlog` standing on the closed issue — which
is precisely what "no cascade" looks like from the outside).

What stands in for it is the adapter's own Done write, and the substitution is
only partial, because the two halves of "Done" come apart here:

- **The READ half needs no cascade.** "Done" is not a separate field that has
  to be kept in sync with "closed" — it IS closed, by construction
  (`issue_item`'s jq reshape reports `status: "Done"` for any closed issue
  regardless of labels). *Any* close, by *any* route, makes the item read Done
  immediately, with no automation round-trip.
- **The LABEL half has no automation at all.** Done on this backend is defined
  as *closed with **no** `fnd:status:*` label* (§ Status vocabulary above).
  Only `board_set_status <item> Done` strips that label — and the
  `fnd:host/session:*` claim stamp with it (`_board_issues_set_field`'s Done
  arm). A close that **bypasses the adapter** — a merged PR's native
  `Closes #N`, a hand `gh issue close`, a web-UI close — closes the issue and
  leaves both labels standing.

**So on this backend `board_set_status … Done` is the PRIMARY mechanism, not a
redundant backstop** — the exact inverse of the Projects-v2 posture, and
`claude/CLAUDE.kernel.md` § Board hygiene is part of the gate now states that
split rather than the Projects-v2 case alone. A caller that closes an item by
any other route owes it the adapter Done write; `reconcile.sh` is the sweep for
the closes that skip it (classes **(h)**/**(k)** for the status label,
**(j)**/**(l)** for the claim stamp — below).

Concretely, what the GH #340 cascade does on Projects-v2 that this backend does
not need **for the read**:

- **No async lag for a WRITE made through this adapter.** A Projects-v2
  close→Done is eventually-consistent (the automation fires, then the cache
  TTL catches up); an issues-only close driven by `board_set_status … Done`
  is the SAME REST write, and the read-after-write is synchronous for any
  caller reading LIVE — no board.sh cache sits between the write and a live
  read (see § Read cache staleness bound below for the one path where a
  cache now CAN sit in between).
- **No separate "board card" to move.** There is no project item distinct
  from the issue to keep in sync — reading `.state` (open/closed) on the
  issue itself IS reading its board Status.
- **No stale-Done *read* is possible** the way it is on Projects-v2 (a card
  that says Ready/In-Progress but is actually closed) — a closed issue on this
  backend can never *report* anything but Done, by the jq reshape's own
  precedence (`if $state == "closed" then {status:"Done"}` is checked FIRST,
  before any label).

  ⚠️ That is a statement about the READ, and it was once written here as "no
  stale-Done *detection* needed" — which is false, and made
  `reconcile.sh --status` structurally blind for a while (temperloop#1410). The
  residual `fnd:status:*` label is still THERE on the closed issue; the reshape
  only shadows it. And because the whole-board read is the OPEN issue set, such
  an issue is *absent* from `board_item_list` entirely rather than misreported —
  so a lens that classifies board items saw nothing at all and printed
  "In sync" over real drift. Detection IS needed here; only its *shape* differs
  from the Projects-v2 one, because the candidate population is the closed-issue
  tail rather than a stale board card. `reconcile.sh --status` now scans that
  tail as classes **(k)** residual status label and **(l)** stranded claim stamp
  — see that file's "Lens 2, the CLOSED-ISSUE TAIL" header section.

### What close DOES have to clear: the claim stamp (temperloop#744)

The read-half argument above ("any close makes the item read Done") holds for
**Status** — but not for the **claim lock**. `fnd:host/session:<host>:<sess8>` is a real piece of state that
outlives the close: unlike `fnd:status:*`, no reader shadows it with a
closed-state precedence rule, so a stamp left on a closed issue is a
cross-session lock that can never be released. `issue-state.sh resolve` derives
`claimed-elsewhere` from exactly that label; `reconcile.sh --status`'s
foreign-claim bucket and `board_claim_contended` read it the same way. A closed
issue wearing one is indistinguishable from a live claim.

Two halves, both shipped:

- **Root cause — the adapter's own Done write clears it.**
  `_board_issues_set_field`'s Done arm strips every `fnd:host/session:*` label
  alongside the `fnd:status:*` label before closing, under the same
  retry-once/never-swallow contract. Reaching Done ends the claim by
  construction. A NON-Done target deliberately leaves the stamp alone — a park
  back to Ready/Backlog is exactly the case where the claim may legitimately
  still be held (kernel doc § Claim held until Done).
- **Backstop — the sweep, for every close that bypasses the adapter.** The
  dominant close path in this pipeline is a merged PR's native `Closes #N`,
  which runs no adapter code at all (same adapter-bypass leak that strands
  `fnd:status:*`), and there is no server-side automation on this backend to
  hook. So `reconcile.sh --labels` owns the residue as class **(j)**: a
  `fnd:host/session:*` label ON a closed issue, stripped per-issue by
  `--apply`. This is NOT covered by class (g) (orphaned repo *label objects*):
  (g) deletes a label object only when it is attached to zero OPEN issues, so
  while any open issue still wears the same stamp the object is correctly kept
  — and every closed issue wearing it stays stranded forever. One documented
  command sweeps the accumulated backlog:

  ```sh
  workflows/scripts/board/reconcile.sh --board 7 --labels          # report
  workflows/scripts/board/reconcile.sh --board 7 --labels --apply  # + strip
  ```

- **The IN-PROGRESS residue — a fourth lens, `--claims` (temperloop#2069).**
  Classes (j) and (m) both stop short of the one open-issue case that matters
  most: an item that is **In Progress** whose stamp names a session that is
  **dead**. (j) is scoped to CLOSED issues; (m) deliberately excludes
  In-Progress because there a stamp is a LIVE claim held until Done (K#275).
  That exclusion is right for a LIVE claim and is exactly what `--claims`
  narrows: when the stamp names a **same-host** session proved dead (its
  Claude transcript absent, or untouched beyond `RECONCILE_STALE_AFTER_SECS`),
  the stamp is dead information — and because `claim.sh` refuses a
  foreign-owned claim, it makes a live epic **unclaimable**. `--claims` strips
  that ONE label and nothing else: `fnd:status:*` is left byte-identical, the
  issue is never closed, and the Status is never moved to Ready. A
  FOREIGN-host stamp is never stripped (liveness is uncheckable from the
  sweeping machine) and stays report-only; a LIVE same-host session's own
  claim self-excludes. Candidates are reported with their staleness AGE.

  One further carve-out NARROWS that auto-apply (it does not reverse it): a
  candidate an **OPEN PR** would close is reported, never stripped — its work
  is delivered and its claim is held until Done (K#275), and `board.sh`'s
  `board_claim_contended()` opens `[ -n "$existing" ] || return 1`, so a
  stripped stamp lets the next claim overwrite the owner with no warning. The
  open-PR read is a failure path: if it errors or cannot be established, every
  candidate is reported rather than stripped.

  ```sh
  workflows/scripts/board/reconcile.sh --board 7 --claims          # report
  workflows/scripts/board/reconcile.sh --board 7 --claims --apply  # + strip
  ```

## Read cache staleness bound (cache-read-dispatch item)

The claim above — "this path has no cache at all" — was true before this
item and remains true by DEFAULT: `board.<N>.cache` is off unless a
`boards.conf` explicitly sets it, and even then only takes effect for a
caller that has also sourced `lib/cache.sh` (see `boards.conf.example`'s
`cache` axis comment and `lib/board.sh`'s `_board_cache_store_enabled`).
When both conditions hold, `_board_issues_item_list`'s whole-board read is
served from `lib/cache.sh`'s on-disk issue-cache store instead of a live
`gh issue list` call — and that store DOES carry a staleness bound, which
supersedes the Projects-v2 90s items-cache figure (foundation #589) for this
read path specifically:

- **A close/label change made THROUGH this adapter** (`board_set_status`,
  `board_stamp`, and anything routing through them — `board_create_many`,
  `board_capture_item`, claim/release) is synchronously reflected: the
  mutator calls `cache_dirty` on a successful write (see `_board_issues_
  set_field` / `_board_issues_stamp_field` in `lib/board.sh`), so the very
  next `cache_read` in ANY process pays exactly one live refresh rather than
  serving the pre-write snapshot — no fixed-window wait, unlike the
  Projects-v2 90s items-cache TTL.
- **A close made OUTSIDE this adapter** (e.g. a merged PR's own `Closes #N`
  GitHub-native auto-close, or a manual `gh issue close`/web-UI edit) is NOT
  synchronously reflected in the cache-store read path, because nothing
  calls `cache_dirty` for a mutation this adapter didn't itself make. The
  bound there is the store's own refresh cadence: `CACHE_STORE_TTL`
  (`lib/cache.sh`, default **3600s / 1 hour**) — up to an hour staler than a
  live read, by default, for a close this adapter never saw. This is a much
  LOOSER bound than the Projects-v2 90s figure it supersedes for this path,
  by deliberate design: the store trades a longer worst-case staleness
  window for a durable, cross-session, zero-GraphQL corpus cache serving a
  fundamentally different consumer (a corpus renderer / pipeline driver reading
  "every issue", not a single board's live Status page).
- **The always-live paths are unaffected regardless of this axis**:
  `board_resolve_item` (the claim lock) never reads through any cache on
  either backend, and `reconcile.sh` never sources `lib/cache.sh` at all —
  so setting `board.<N>.cache=on` in a `boards.conf` a reconcile run also
  reads has NO effect on reconcile's own live-read pin (see
  `reconcile.sh`'s `BOARD_CACHE_TTL=0` header comment and
  `tests/test_reconcile.sh`'s Lens 3).

Operationally: a consumer that wants a tighter bound than the 3600s default
overrides `CACHE_STORE_TTL` (an env var, never a `boards.conf` key — see
`CACHE-STORE.md`'s "Tuning settings"), or simply doesn't source `lib/cache.sh`
and stays on the always-synchronous live-read arm.

## Pipeline integration (foundation #801, split 3/3)

The final split: wiring `pipeline-tick.sh` to drive an issues-only repo, and
proving it via a dual-adapter test suite. `pipeline-tick.sh` itself needed
**zero backend branching** — it already only ever touches `BOARD_ITEMS_JSON`
through `board.sh`'s public accessors — but its Ready-item classification
(`classify_item`, `needs_clarification`, `pipeline_escalated`, `pending_merge`)
reads a Ready item's **raw GitHub labels** directly (`spike`, `Foundational`,
`needs-clarification`, `funnel-escalated`, `funnel-merge-pending` — every one
of them a PLAIN label, never `fnd:`-namespaced). That is the "D3 seam": the
pipeline's Ready-item read depends on `BOARD_ITEMS_JSON` carrying a `labels`
key, not just `status`/`component`.

**The gap split 1/3 left (now fixed).** The Projects-v2 path always had this
for free — `gh project item-list --format json`'s own default output already
carries a top-level `labels` array for Issue content, and `board_item_list` /
`_board_item_list_fresh` pass it through completely unreshaped (they only
strip PR cards and control characters). The issues-only `issue_item()` jq
def, by contrast, extracted ONLY the `fnd:`-prefixed labels into
`status`/`component`/`host/Session` and silently dropped every other label —
so a live pipeline-tick against an issues-only board could never see `spike` /
`Foundational` / `needs-clarification`, and every Ready item would
misclassify as a fresh Operational `kind:code` drive (worse: probing for an
open PR via `gh pr list`, a step that must never fire in a SAFE-tier-only
scenario). Fixed by adding a `labels: $labels` passthrough to `issue_item()`
— the raw, UNFILTERED label list (the `fnd:` bookkeeping labels stay in it
too; harmless, since an equality check like `. == "spike"` never matches
`"fnd:status:ready"`). This makes the issues-only item shape a structural
match for the Projects-v2 one on this key, the same way it already was for
`status`/`component`/`host/Session`.

**What "SAFE-TIER" means here.** pipeline-drive.sh's level-5b executor
auto-runs only route-*/drain-*/a `kind:spike` drive — never a merge
(foundation #604's SAFE/MERGING tier split). A full safe-tier tick therefore
never needs to open a PR, so proving it against an issues-only repo needs no
merge-capable adapter surface at all — only the read path (`board_resolve` /
`board_item_list`) plus the plain-REST reads `pipeline-tick.sh` already made
directly (`gh issue list --search …`, `gh issue view --json assignees`),
which were already backend-agnostic (per-issue/per-search REST, no Projects
call either way).

## Pruning GitHub's default labels (one-time operator act)

Migrating a repo onto the issues-only backend does **not** include pruning
GitHub's stock default label set (`bug`, `enhancement`, `wontfix`,
`invalid`, `duplicate`, `question`, `help wanted`, `good first issue`, …).
That prune is a **one-time act an operator performs by hand on their own
repo** — never kernel machinery, and never something `/triage`, `/build`,
the label-hygiene sweep, or any other pipeline command does on its own. The
label-hygiene sweep (`reconcile.sh`, surfaced in `/tidy`'s board-label
step) is strictly scoped to `fnd:`-namespaced labels — it never lists,
touches, or deletes a non-`fnd:` label, by construction.

If you do want to prune the defaults (the temperloop maintainers did this,
across all five of their repos):

- **Verify zero usage first, per repo.** Confirm no open or closed issue in
  that specific repo carries the default label before deleting it (`gh
  label delete` doesn't check for you) — a label used anywhere in the
  repo's history is still meaningful search/filter state for anyone
  browsing it later.
- **Keep contributor-facing labels wherever you want them.** `help wanted`
  and `good first issue` are conventions outside contributors and GitHub's
  own UI recognize on their own; keep them on any repo where drive-by
  contributions are welcome, independent of whether this tooling uses them.
- **Restoring a pruned label is one command.** `gh label create <name>
  --color <hex> --description "<text>"` — deleting a default label is not a
  one-way door.
- **The prunable defaults have native replacements, not new labels.**
  GitHub's own issue/PR close reasons (`completed`, `not planned`,
  `duplicate`) supersede the `wontfix` / `invalid` / `duplicate` labels —
  close with a reason instead of labeling-then-closing. `question` has no
  native close-reason equivalent, but this pipeline already carries a label
  that means the same thing: `needs-clarification` (there is deliberately
  no `Blocked` status either — a genuine dependency block is a native
  `blocked_by` edge, and an open question is the `needs-clarification`
  label, not a status; see `claude/CLAUDE.kernel.md` § Task workflow,
  "Park, don't abandon").

## The temperloop tracker (board 7, foundation #808)

**Status update (epic temperloop#524):** board 7 was once the sole board
hard-coded to issues-only in the built-in map. **It is no longer an exception
at all** — the Projects-v2 arm was removed (ADR 0004), so every board is
issues-only and there is no in-code Projects default for board 7 to be
carved out of. `board_backend()` no longer carries a board-7 case, because it
no longer carries any backend selection. What survives from this section is
board 7's `board_repo()` built-in-map entry and the `--repo kernel` routing
below; the `board_backend()` half of the argument is historical. See
§ Selecting the backend, above, for the superseded additive-only rule.

The kernel-vs-overlay routing rule (CLAUDE.kernel.md § Kernel vs overlay
routing rule) needed a concrete board number before it could be *followed*
mechanically rather than just stated in prose — the global glossary used to
say the kernel tracker "has no `--board N` because it is issues-only today".
Being issues-only was never actually a reason it needed no number (an
issues-only board only needs the `repo` axis, same as any other — see above);
this split (F#808, Guard #3 of the routing rule, epic B) gives the adapter a
real handle: **board 7**, registered directly in `lib/board.sh`'s
`board_repo()` and `board_backend()` built-in maps (`repo` → the
temperloop repo; `backend` → `"issues"`), the SAME place boards 3-6
already carry their real, org-qualified repo values. (The `board_backend()`
half of this is historical — that function no longer selects a backend; see
§ Selecting the backend.)

Not a committed `boards.conf` entry — deliberately. A real, org-qualified
`repo` value is exactly the class of literal this checkout's own
personal-token-denylist (`workflows/scripts/kernel/personal-token-denylist.tsv`)
forbids inside the kernel-vendored tree, with ONE sanctioned exception:
`board_repo()`'s own built-in case map, already carrying boards 3-6's real
values behind a trailing `# denylist:allow` marker for exactly this reason
(a `boards.conf`-less consumer must still resolve a real repo — see
§ Selecting the backend, above). Board 7 follows that SAME precedent rather
than inventing a second one: its case line in `board_repo()` carries the
same marker. (Historically `board_backend()` also carried a narrowly-scoped
`7 → "issues"` case, as the sole permanent exception to that function's
general "no board defaults to issues in-code" rule; both the rule and its
exception are retired — see § Selecting the backend.) A per-machine/per-repo
`boards.conf` can still override board 7's `repo` (checked FIRST, same
discovery order as any other board) exactly as it could for boards 3-6 —
this only hard-codes the DEFAULT a `boards.conf`-less consumer sees.
`test_boards_conf.sh`'s built-in-fallback assertions cover board 7 the same
way they already cover boards 3-6.

### `capture.sh --repo kernel` / `--repo ambiguous`

`capture.sh` gained a `--repo` flag — a conscious-routing peer to `--board`,
documented in the script's own header — rather than requiring every caller
to memorize board 7:

- `--repo kernel` — routes to board 7 outright (overrides `--board`). Use
  when the capture IS kernel-domain machinery (board adapter, build/sweep
  machinery, install/doctor, quality gates — the "stranger test" the routing
  rule names).
- `--repo ambiguous` — routes to the SAME board 7, for the routing rule's
  **ambiguity clause**: "Ambiguous foundation-domain captures default to
  kernel. When a new rule is genuinely unclear which side it belongs on,
  but it concerns foundation's own pipeline machinery … route it to
  kernel" (CLAUDE.kernel.md § Kernel vs overlay routing rule). This is
  intentionally a DISTINCT spelling from `kernel`, purely for provenance:
  `--repo ambiguous` appends a note to the filed issue's body recording
  that the route was a DEFAULT, not a deliberate classification, so a
  human triaging the kernel tracker can see at a glance which issues were
  auto-routed and re-file with `--board 4` if the default guessed wrong.

No interactive TTY prompt is implemented for the ambiguous case — the issue
contract treats a disambiguation prompt as optional; the required part
(satisfied here) is that the DEFAULT and its rationale are documented, both
in `capture.sh`'s own header comment and in this section, and that the
default behavior is exercised by a test (`test_capture.sh`'s `--repo
kernel`/`--repo ambiguous` full-flow section, see § Testing below). A
capture with NEITHER `--board` nor `--repo` is unaffected — it still goes to
board 3 (stageFind) exactly as before; the ambiguity default only applies
when the caller opts into it via `--repo ambiguous`, because capture.sh has
no way to infer "this is foundation-domain" on its own from a bare title.

## Testing

`workflows/scripts/board/tests/test_issues_backend.sh` (run via `make
test-board`) is the fixture-replay suite for the split-1/3 (#799) surface:
zero network, sources `lib/board.sh`, overrides its `_board_gh` seam. It also
carries the **config-selection proof** — an unconfigured board's `gh project
…` argv is byte-identical to `test_board_replay.sh`'s pinned Projects-v2 call
sequence, demonstrating the seam is additive-only. Its case 3 also pins the
`labels` passthrough (#801).

`workflows/scripts/board/tests/test_issues_claim_edges.sh` (also run via
`make test-board`) is the split-2/3 (#800) suite: `board_stamp` on `ISSUE_*`
(write, clear, round-trip through the `"host/Session"` flattened key),
`board_claim_contended` (contended / self-reclaim / half-claim-adoption /
unclaimed cases, plus the same contended/self-reclaim proof replayed on a
Projects-v2 board to pin the cross-backend parity), `board_sub_issues`, and
`claim.sh`'s end-to-end contention refusal against a fake issues-only repo
(mirrors `test_claim.sh`'s replay style, but for the `ISSUE_*` path).

`workflows/scripts/board/tests/test_board_dual_adapter.sh` (registered as its
own `make test-board-dual-adapter` gate — see `scripts/quality-gates.sh`) is
the split-3/3 (#801) suite: it runs `pipeline-tick.sh` LIVE (not
`--dry-run --fixture`, which bypasses `board.sh` entirely and so can never
catch a reshape gap like the one above) against the SAME scenario twice — once
with the board configured `backend=projects`, once `backend=issues` — and
asserts both the full SAFE-TIER action set (drain-answer, drain-clarification,
a `kind:spike` drive-ready, route-foundational, route-already-assigned) and
byte-for-byte cross-arm parity of the resulting tick plan. It also asserts,
directly against the recorded `gh` call log, that no PR/merge/write-capable
call ever fires in either arm — the structural proof of "no merges."

`workflows/scripts/board/tests/test_boards_conf.sh` § 6 (foundation #808)
pins `board_repo 7` / `board_backend 7`'s built-in-map defaults (mirroring
its existing boards-3-6 fallback assertions in § 1) and that a repo-local
`boards.conf` can still override board 7 like any other board.
`workflows/scripts/board/tests/test_capture.sh`'s `--repo kernel`/`--repo
ambiguous` full-flow section drives `capture.sh` as a real subprocess against
a bespoke fake `gh` (the shared `fixtures/fake_gh.sh` is Projects-v2 shaped
and doesn't understand the issues-only backend's REST verbs). To keep this
NON-exempt test file free of the real org literal (only `board_repo()`'s own
case line — see above — is a sanctioned exception), the test overrides board
7's `repo` to a placeholder via a scoped `boards.conf` (the same override
mechanism a real consumer would use), then pins: `gh issue create` targets
that repo; no `gh project …` call is ever made; the `fnd:status:backlog`
label is both ensured (`gh label create`) and applied (`gh issue edit
--add-label`); and `--repo ambiguous`'s filed issue body carries the
documented ambiguity-default provenance note verbatim.
