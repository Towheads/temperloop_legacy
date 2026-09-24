# `meta/data/raw/` — kernel telemetry raw-lake sink spec

This directory is the append-only, JSONL, monthly-rotated **raw lake** the
kernel's telemetry emit sites write to. It is gitignored and per-host: nothing
here is committed, and (absent a cross-host ingest) each host only sees the
records it personally emitted. This file is the **canonical sink spec** every
kernel emit site's header comment points at ("canonical sink spec:
`meta/data/raw/README.md`") — it documents the lake path convention, the
schema-version convention, and the per-stream record shapes for the streams
this kernel checkout emits.

**Scope.** This stub documents only the streams a bare kernel checkout
actually emits: `command-run`, `issue-touches` (plus its `claims` sibling,
unioned at read time), `pipeline` (plus its pre-rename `funnel-*` month-files,
also unioned at read time — see that stream below), `knowledge-search-fallback`,
`gh-calls`, `session-context`, `item-efficiency`, `resume-recovery`, and
`triples` (the derived {s,p,o,provenance} graph-of-record stream
`workflows/scripts/knowledge/triples.sh build` writes).
A downstream overlay checkout (e.g. the
composed foundation repo) layers additional, overlay-only telemetry streams
on top — with their own record shapes, for capabilities this bare kernel
checkout doesn't have (e.g. rework tracking, richer issue-metadata snapshots,
retrospective-verdict snapshots). Those overlay-only streams are **not**
documented here; the overlay's own README extends this stub additively
rather than replacing it.

## Lake path convention

Every stream lands in this directory (or wherever `<STREAM>_RAW_DIR` /
`PIPELINE_RAW_DIR` overrides point, tests only) as one file per calendar month:

```
meta/data/raw/<stream>-<YYYY-MM>.jsonl
```

- `command-runs-<YYYY-MM>.jsonl`
- `issue-touches-<YYYY-MM>.jsonl`
- `claims-<YYYY-MM>.jsonl`
- `pipeline-<YYYY-MM>.jsonl` (plus, on a lake that predates the v0.17.0
  rename, `funnel-<YYYY-MM>.jsonl` — a **permanent legacy-prefix read**, see
  below)
- `gh-calls-<YYYY-MM>.jsonl`
- `session-context-<YYYY-MM>.jsonl`
- `item-efficiency-<YYYY-MM>.jsonl`
- `triples-<YYYY-MM>.jsonl`

Each file is newline-delimited JSON (JSONL), one record per line, strictly
append-only — a reader unions across month-files as needed and never expects
in-place mutation of a written line.

## Schema-version convention

A stream's records MAY carry a top-level `schema_version` field: a **string**
(not a number), bumped only on a breaking shape change (a field removed, a
type changed, a meaning changed) — never on a purely additive change (a new
optional field is not a breaking change and does not require a bump).

Not every stream carries the field explicitly yet. `issue-touches` is the
precedent: every record explicitly carries `schema_version: "1"`. Streams
that don't yet emit the field (`command-run`, `claims`, `pipeline`) are
implicitly at their initial, unversioned shape — the convention going forward
is that the *first* breaking change to any of those streams is also the
change that introduces its `schema_version` field (starting at `"1"`), rather
than retrofitting it speculatively. A reader that cares about shape stability
should treat a record with no `schema_version` field as pre-versioning /
`"1"`-equivalent.

## Streams

### `command-run` — `command-runs-<YYYY-MM>.jsonl`

Emitted by `workflows/scripts/emit-command-run.sh` (foundation #729), one
record per `/sweep` or `/triage` command run — these commands have no
plan-note footer of their own (unlike `/build`), so this is their only
telemetry signal.

`/triage --feedback-only` (temperloop#369) is a **distinct run shape** rather
than a sweep, and carries its own `command` value: it walks the operator's
pending-feedback queue and never runs the Backlog sweep, so the counters
below describe the *queue walk* (items = queue size, merged = answered or
disposed, parked = deferred). It gets a separate value precisely so a reader
cannot mistake it for a sweep — recording it as `"triage"` would assert that
a sweep ran and considered N candidates, which is exactly what a `--feedback-only`
run did not do. A `/triage --feedback` run (sweep **plus** queue walk) still
emits one `"triage"` record for its sweep; giving its queue walk counters of
its own is a follow-on, not covered here.

Record shape: `{ts, session_id, run_id, command, board, items_processed, merged, resolved, parked, reported_no_op, epic?, epics_reviewed?, epics_closed?, epics_left_open?}`

| field | type | notes |
|---|---|---|
| `ts` | string | ISO-8601 UTC, `Z` suffix |
| `session_id` | string \| null | raw, untruncated `$CLAUDE_CODE_SESSION_ID` — the join key other raw/ streams key on; `null` for a non-Claude-Code/manual run |
| `run_id` | string, **absent on pre-#2220 records** | the stable id of the RUN this record belongs to (temperloop#2220), from `--run-id` or the run's own open-ledger marker. Several records can describe ONE run, so this is the key a consumer reduces on — see **Reduction** below. Absent means UNKNOWN, never "its own run by design"; purely additive, no `schema_version` bump |
| `command` | string | `"sweep"` \| `"triage"` \| `"triage-feedback"` \| `"fix"`, verbatim from `--command`. `"triage-feedback"` is a `/triage --feedback-only` run (queue walk, no sweep — see above); purely additive, no `schema_version` bump, but note a reader filtering on `command == "triage"` will **not** see these runs, which is intended |
| `board` | number \| string \| null | the logical board number (`--board`), or `null` if omitted |
| `items_processed` | integer | how many items the run drove/considered |
| `merged` | integer | how many landed a merged PR |
| `resolved` | integer, **absent on pre-#1084 records** | how many reached a terminal outcome that is **not** a merge — a `kind: spike` closed on its verdict (`/sweep`, `/fix`), a culled or decision-routed candidate (`/triage`). See the absent-means-unknown caveat below |
| `parked` | integer | how many were parked/deferred/escalated |
| `reported_no_op` | integer, **absent on pre-#1103 records** | how many were a terminal "nothing to do" outcome that is **not** a merge, a verdict-resolve, or a park — `/fix` only, today: an `already-done` target, or an `claimed-elsewhere` target owned by another session. See the absent-means-unknown caveat below |
| `epic` | number \| string, OPTIONAL | the epic issue number the run drove against (e.g. `/assess --epic N`, or `/build` on a plan note with an `epic:` frontmatter field), from `--epic`. ABSENT from the record entirely (not `null`) when the caller doesn't pass `--epic` — purely additive, no `schema_version` bump |
| `epics_reviewed` / `epics_closed` / `epics_left_open` | integer, OPTIONAL (epic #1847 "epic-as-metadata for operational work", item "epic-closing-gate") | `/sweep`'s end-of-run epic-closing gate tally: how many **Operational** epic parents the gate reviewed this run, how many it closed, and how many it left open (`epics_closed + epics_left_open == epics_reviewed`, enforced by the emitter). Present as a group only when `--epics-reviewed` was passed at all (the activation signal — a run with no epic-admitted members this cycle omits all three, not `0`s); `--epics-reviewed 0 --epics-closed 0 --epics-left-open 0` is itself a valid, explicit zero-epic record, distinct from the fields being altogether absent. This is the ONLY signal in this stream for an **Operational** epic's funnel stage: its healthy path is epic → members-drained-via-sweep, with no plan-note step, so an Operational epic appearing (or not appearing) here is never evidence of a stalled assessment — see `workflows/scripts/telemetry-brief.sh` § 2b, which reads this group class-conditionally alongside the (Foundational-only, `/build`-emitted) `item-efficiency` per-epic rollup. Purely additive, no `schema_version` bump |

**Reduction: one run, one record — group by `run_id` and take the LAST record
(temperloop#2220).** This stream is per-RECORD, not per-run: several records
can legitimately describe one run. The motivating case is `/fix` at the merge
gate — the run emits `parked: 1` when the merge is held, the operator approves
it later **in the same run**, and the run emits again with `merged: 1`. Both
lines are true when written and neither can retract the other (the stream is
append-only and is **never** backfilled), so the reconciliation happens at READ
time:

```sh
# the canonical reduction — exactly one record per run, last write wins.
# A run_id-less (pre-#2220) record keys on its own position, so it reduces as
# its OWN singleton run rather than collapsing with every other legacy line.
# (`input_line_number` does NOT work here: under -s it is the last line read,
# so every legacy record would share one key and silently merge.)
jq -s -c 'to_entries
          | map(.value + {_k: (.value.run_id // "legacy:\(.key)")})
          | group_by(._k)
          | map(sort_by(.ts) | last | del(._k))' meta/data/raw/command-runs-*.jsonl
```

`workflows/scripts/validate-command-run-reconcile.sh` is both the reference
implementation of that reduction (`--reduce`) and the **guard** over the
property it depends on — *exactly one reducible record per run*. That property
breaks in two directions and the guard fails on both: a record written after
this host's run-id cutover that carries no `run_id` (unreducible — several
records for one run that can never be collapsed), and an open-ledger marker
that never got a record at all (a run that started and silently emitted
nothing). Summing `items_processed` across raw lines, without reducing first,
double-counts every park→merge run.

**The open ledger** sits beside the stream at `command-run-open/` and is
**not** part of it — it is scratch state a run opens and closes, never an
append-only record. One marker file per run, keyed
`<session>__<command>[__<target>].json`, carrying
`{run_id, command, session_id, board, target, opened_at, opened_epoch, emitted}`.
The `target` component is load-bearing: a (session, command) key alone
collapsed two concurrent `/fix` runs in one session onto one marker and one
run id, so every caller passes the **same** `--target` on its `--open` call and
on its terminal emit (a `/fix` target, a `/sweep` or `/triage` board). `--open`
never overwrites a marker that is still live on its key, and never deletes a
stale un-emitted one — that marker *is* the missing-run alarm. The guard runs
over the live lake from `/tidy`'s environment-hygiene sweep, not from
`scripts/quality-gates.sh`: this lake is per-host mutable state, and one
abandoned marker must not turn the merge gate red for every later PR on that
host. Its hermetic fixture suite is what CI gates.

⚠ **Pre-#2220 records carry no `run_id`, and the backlog is never repaired.**
A record with no `run_id` reduces as **its own singleton run** — the tolerant
read, and the only one available: nothing in the data can say which legacy
lines belonged to one run, and stamping them now would assert a `ts` that is
not when the run happened. So a legacy park→merge pair still reduces to two
runs. A consumer should treat the legacy segment as approximate (it over-counts
multi-record runs) and the post-cutover segment — everything at or after the
earliest `run_id`-bearing record — as exact. The guard reports legacy runs by
count and never fails on them; it fails only on a run-id-less record written
*after* the cutover, which is the wiring regressing rather than history.

**Invariant: `merged + resolved + parked + reported_no_op == items_processed`.**
Every item a run drives reaches exactly one terminal disposition, so the four
counts partition the total. `emit-command-run.sh` asserts this and **exits 2**
on a mismatch (after appending the record anyway, so the inconsistency is
preserved in the stream rather than swallowed). The invariant is what makes a
*missing* disposition loud: if a command grows a further terminal outcome and
nobody adds a field for it, the arithmetic breaks on the very next run instead
of silently under-reporting. That silent under-report is what temperloop#1084
was filed for — a 30-item `/sweep` emitting
`{items_processed:30, merged:27, parked:1}`, with the two verdict-resolved
spikes expressible nowhere. temperloop#1103 was the same class one field
short: a `/fix` run resolving `already-done` had no fourth field to say
"nothing happened, on purpose," so it could not call the emitter at all
without tripping this very invariant — the fix.md spec instead just skipped
the call on that route, leaving the run with **no telemetry record whatsoever**
rather than a merely-inconsistent one.

⚠ **`resolved` is absent on records written before temperloop#1084, and absent
means UNKNOWN — never `0`.** This stream is strictly append-only and is
**never backfilled**, so historical records keep their original shape. A
consumer MUST distinguish:

- **no `resolved` key** — a pre-#1084 record. Its `merged` count may silently
  include verdict-resolved items (`/sweep` folded them in), or the record may
  simply not add up at all; the invariant above does **not** hold for it, and
  neither does `resolved == 0`.
- **`"resolved": 0`** — a post-#1084 run that genuinely resolved nothing.

Every record written from #1084 on carries the field explicitly, so its
absence is a reliable pre-#1084 marker. Read it defensively — e.g. in jq,
`(.resolved // 0)` is fine for a *sum*, but `has("resolved")` is what you need
before asserting the invariant or reporting a rate.

⚠ **`reported_no_op` is absent on records written before temperloop#1103, and
absent means UNKNOWN — never `0`, same convention as `resolved` above.** A
pre-#1103 record from `/fix` may not reconcile against the invariant at all
(a run that resolved `already-done` may show
`items_processed:1, merged:0, resolved:0, parked:0` with no fourth field to
account for the missing `1` — or, if `/fix`'s already-done/claimed-elsewhere
routes skipped the emit call entirely that run, there may be **no record for
that run at all**, not merely an inconsistent one). **Disposition of
pre-existing non-reconciling rows:** this stream is strictly per-host and
gitignored (nothing here is committed — see the lake path convention above),
so there is no committed history to migrate or backfill; any such rows live
only in an individual host's own local lake and are accepted **as legacy,
read defensively** exactly like the pre-#1084 `resolved`-absent rows above —
never backfilled, never treated as `reported_no_op: 0`. Every record written
from #1103 on carries the field explicitly, so its absence is a reliable
pre-#1103 marker.

This is a **purely additive** change (a new optional field, no field removed,
no type or meaning changed), so per the schema-version convention above it does
**not** bump `schema_version`, and this stream stays implicitly at its initial
unversioned shape. `merged`'s *documented* meaning did narrow from "reached a
successful terminal outcome" to "landed a merged PR" — but that is a
clarification of what the callers already emitted in the merge-carrying case,
not a re-typing of the field, and the absence marker above is what lets a
reader tell the two eras apart without a version bump.

Example record:

```json
{"ts":"2026-07-05T14:03:11Z","session_id":"a1b2c3d4-e5f6-7890-abcd-ef1234567890","run_id":"run-20260705T140016Z-3f9a2b1c","command":"sweep","board":3,"items_processed":4,"merged":3,"resolved":0,"parked":1,"reported_no_op":0}
```

Example record, run against an epic (`--epic` passed):

```json
{"ts":"2026-07-05T14:03:11Z","session_id":"a1b2c3d4-e5f6-7890-abcd-ef1234567890","run_id":"run-20260705T140016Z-3f9a2b1c","command":"sweep","board":3,"items_processed":4,"merged":3,"resolved":0,"parked":1,"reported_no_op":0,"epic":42}
```

Example record, a `/fix` run that resolved `already-done` (the temperloop#1103
case — `reported_no_op` is the only non-zero disposition count):

```json
{"ts":"2026-08-08T14:51:26Z","session_id":"a1b2c3d4-e5f6-7890-abcd-ef1234567890","run_id":"run-20260808T145101Z-c0ffee11","command":"fix","board":7,"items_processed":1,"merged":0,"resolved":0,"parked":0,"reported_no_op":1}
```

Example pre-#1084 record (no `resolved` key — the counts do **not** reconcile,
and that is the defect, preserved as written):

```json
{"ts":"2026-08-03T02:14:55Z","session_id":"e9d363cd-0000-0000-0000-000000000000","command":"sweep","board":7,"items_processed":30,"merged":27,"parked":1}
```

### `issue-touches` — `issue-touches-<YYYY-MM>.jsonl`

Emitted by two sites that both write the same record shape into the same
stream (foundation #916/#919):

- `workflows/scripts/emit-issue-touch.sh` — emits `kind:"pr-open"` (build.md
  Step 3f), `kind:"merge"` (build.md Step 4d) and `kind:"review-round"`
  (`claude/workflows/build-level.mjs`'s `emitReviewRounds()`, at 3h —
  temperloop#2131).
- `workflows/scripts/board/capture.sh`'s own `issue_touch_log_emit` — emits
  `kind:"capture"` at the moment a noticed-but-not-now item is captured.

Record shape: `{schema_version, ts, repo, issue, session_id, host, kind}`

| field | type | notes |
|---|---|---|
| `schema_version` | string | `"1"` — bump on a breaking shape change |
| `ts` | string | ISO-8601 UTC, `Z` suffix |
| `repo` | string | `"owner/repo"` the issue lives in |
| `issue` | integer | issue number |
| `session_id` | string \| null | raw, untruncated `$CLAUDE_CODE_SESSION_ID` — same join-key convention as `command-run`; deliberately NOT the truncated `host:sess8` board stamp |
| `host` | string | `$SUBSET_HOST_LABEL` if set, else `hostname -s` |
| `kind` | string | `"pr-open"` \| `"merge"` \| `"capture"` \| `"review-round"` |

Example record:

```json
{"schema_version":"1","ts":"2026-07-05T14:07:22Z","repo":"acme/widgets","issue":42,"session_id":"a1b2c3d4-e5f6-7890-abcd-ef1234567890","host":"mini","kind":"pr-open"}
```

#### `kind:"review-round"` — the §3e round history (temperloop#2131)

One record per §3e review round a `/build` item spent, appended at 3h from the
same per-round objects the item's parked record carries in `review.rounds` —
one producer, two sinks, so the lake and the parked record cannot disagree.

It rides **this** stream rather than a new one because rounds-to-merge is a
join against the `pr-open`/`merge` touches already here: the round records sit
in the same file, keyed on the same `issue`, so a rollup needs one file and no
GitHub call. A `review-round` record carries the seven fields below **in
addition to** the base shape; every other `kind` carries none of them, so a
consumer that predates this kind reads byte-identical lines.

| field | type | notes |
|---|---|---|
| `round` | integer \| null | the round ordinal, from the worktree's **durable** `build-review-rounds` counter — so a continuation round reports `3`, not `1` |
| `round_kind` | string | `"review"` \| `"gate-timeout"` \| `"gate-fail"` \| `"activation"` \| `"ci"` \| `"other"` — the closed vocabulary owned by `build-level.mjs`'s `escalationRoundKind()` (temperloop#2135), **the one place that mapping is stated**. An unrecognised value is recorded as `"other"`; nothing is re-derived here. |
| `pr` | integer \| null | the PR the round belongs to |
| `sha` | string \| null | the commit the round actually reviewed (7–64 hex); `null` rather than a plausible-but-wrong value when the relay dropped or garbled it |
| `wall_ms` | integer \| null | the round's measured §3e fanout wall-clock, in ms |
| `tokens` | integer \| null | the round's token cost. **`null` today by construction** — the Workflow runtime's `agent()` returns no usage envelope, the same honest degrade `worker-usage.sh` documents for the worker seat. Never a guess. |
| `reviewers` | array | one `{name, model, highs, mediums, lows}` object per reviewer that **ran** in the round (`[]` when none did) |

`reviewers[].model` is the **resolved** model that reviewer ran as —
self-reported by the reviewer itself — **not** the seat file's declared value: a
seat declaring `model: inherit` resolves per *session*, so the declared string
answers a different question than "what actually reviewed this". Unknown reads
`null`, never the declared value. `highs`/`mediums`/`lows` count that
reviewer's `### [HIGH] …` / `[MEDIUM]` / `[LOW]` findings in that round.

Example record:

```json
{"schema_version":"1","ts":"2026-09-19T22:18:23Z","repo":"acme/widgets","issue":42,"session_id":"a1b2c3d4-e5f6-7890-abcd-ef1234567890","host":"mini","kind":"review-round","round":3,"round_kind":"ci","pr":1207,"sha":"deadbeefcafe","wall_ms":12000,"tokens":null,"reviewers":[{"name":"shell-reviewer","model":"claude-opus-5","highs":1,"mediums":2,"lows":0}]}
```

**Rollup: rounds-per-PR for a week, with no GitHub call.** This is the query
temperloop#2131 exists to make possible, and it reads the lake alone:

```sh
# Rounds per PR for the week of 2026-09-14 (UTC bounds on the stored `ts`).
jq -s -c '
    map(select(.kind == "review-round"
               and .ts >= "2026-09-14T00:00:00Z"
               and .ts <  "2026-09-21T00:00:00Z"))
    | group_by(.pr)
    | map({pr: .[0].pr, issue: .[0].issue, rounds: length,
           kinds: (group_by(.round_kind) | map({(.[0].round_kind): length}) | add)})
    | sort_by(.pr)' meta/data/raw/issue-touches-2026-09.jsonl
```

`workflows/scripts/build/tests/test_workflow.sh` executes this exact query
against a fixture lake, so the recipe above is a tested surface rather than an
illustration. Dates rendered for a human go in `America/Los_Angeles`; the `ts`
values stored here are UTC by design (the stored/parsed carve-out), so convert
at display time, never in the file.

**Sibling: `claims` — `claims-<YYYY-MM>.jsonl`.** `workflows/scripts/board/claim.sh`'s
`claim_log_emit` writes claim touches (deliberately *not* emitted by
`emit-issue-touch.sh`, which only ever emits
`pr-open`/`merge`/`review-round`) into their own
`claims-<YYYY-MM>.jsonl` file, unioned at read time with `issue-touches` to
give the full touch history for an issue. Its record shape (documented in
full at `claim_log_emit`'s own header comment):
`{ts, host, session_id, board, issue, item_id}` — no `schema_version` field
yet (see the schema-version convention above for what that implies).

**Checkout-relative sink (temperloop#1822 — the earlier absolute pin is
superseded).** `claim.sh` (and its sibling `capture.sh`, for the
issue-touches stream) defaults its sink to the lake of the checkout the
script file itself lives in — `git rev-parse --show-toplevel` on the script's
own resolved dir, then `/meta/data/raw` (`CLAIMS_RAW_DIR_DEFAULT` in
`claim.sh`; `CLAIMS_RAW_DIR` overrides it, tests only) — the same directory
every other stream's writer and `telemetry-brief.sh`'s reader resolve, so
writer and reader converge with no env set. Before #1822 the sink was pinned
to `$HOME/dev/foundation/meta/data/raw` regardless of checkout, which made
every non-foundation checkout's telemetry read zero claims (and grew a
phantom `~/dev/foundation/` tree on hosts without that clone).
**Consequence for a reader:** claims recorded before that fix — and claims
recorded by *another* checkout's `claim.sh` — live in that checkout's (or the
old pinned) lake, not necessarily the local one; a full cross-checkout touch
history is a reader-side **union** of lakes. (In a composed/foundation
checkout, the overlay `/retro` command's Step 1 performs exactly this union —
foundation#1216.)

### `pipeline` — `pipeline-<YYYY-MM>.jsonl` (+ the permanent legacy prefix)

Emitted by `workflows/scripts/build/pipeline-cron.sh` (foundation #596), one
record per cron wake — every wake writes exactly one record via the script's
`emit_record` chokepoint, which stamps a shared `ts` onto whatever event
record Steps 1–4 built. Records are heterogeneous by `event`; the fields
below `event`/`ts` vary by event type.

**Permanent legacy-prefix read.** Before the v0.17.0 terminology
consolidation (temperloop#729) this stream was named `funnel-<YYYY-MM>.jsonl`.
The lake is **append-only immutable history**, so those month-files are never
rewritten under the new prefix — readers union both prefixes, read-only,
**permanently**. This deliberately survived the v0.19.0 close of the rest of
that rename's compat window (temperloop#767): the window's env shim and
forwarding stubs are gone, but this read is not part of the window. It is
self-limiting — writers emit only `pipeline-*`, so no new legacy month-file is
ever created — and it is exercised by `workflows/scripts/telemetry-brief.sh`
(`stream_files`) and preserved across lake moves by `pipeline-cron.sh
--backfill`.

Base shape: `{event, ts, ...event-specific fields}`

| `event` | when | notable fields |
|---|---|---|
| `skipped` | the schedule gate declined this wake | `date`, `reason`, optional `context` (gate error) |
| `ran` | the gate allowed the wake and a tick ran | `date`, `boards` (array), `nonop_actions` (integer), `duration_ms`, `plans` (array of per-board tick plans) |
| `drive` | rung 5b/5c auto-drive executed (only when `PIPELINE_DRIVE=1` and the tick found non-no-op work) | `status`, `date`, `duration_ms`, and on error: `reason`, `context` (captured driver stderr) |

Any record may also carry a `self_update` object (foundation #598's
self-update sandbox outcome) when a self-update was attempted that wake.

Example record (`ran`):

```json
{"event":"ran","date":"2026-07-05","boards":["3","4"],"nonop_actions":2,"duration_ms":8421,"plans":[{"board":"3","actions":[{"action":"route-foundational"}]}],"ts":"2026-07-05T15:00:03Z"}
```

Example record (`skipped`):

```json
{"event":"skipped","date":"2026-07-05","reason":"not-scheduled","ts":"2026-07-05T15:00:00Z"}
```

### `knowledge-search-fallback` — `knowledge-search-fallback-<YYYY-MM>.jsonl`

Emitted by the WARM search backend
`workflows/scripts/lib/knowledge_search_mcp.sh` (`_ks_bm_mcp_fallback_signal`,
temperloop#54), one record each time a `KNOWLEDGE_SEARCH_BACKEND=basic-memory-mcp`
search falls back from the warm `basic-memory mcp` daemon to the cold `uvx`
CLI path — because the daemon was unreachable, or reachable but returned no
usable result. This is the durable, alertable signal that a down daemon is
degrading every `ks_search` to the slow path; without it the only trace was a
per-query stderr line the caller usually swallows.

**De-dup:** emitted at most ONCE per session (keyed by
`$CLAUDE_CODE_SESSION_ID`, else the process id), the same gate that de-dupes
the one-time-per-session stderr notice — so a caller looping many queries
against a down daemon produces ONE record, not per-query spam. Fail-open: the
emit never blocks or fails the search (still returns cold-path results, exit
0).

Record shape: `{schema_version, ts, session_id, host, backend, reason, detail, url, project}`

| field | type | notes |
|---|---|---|
| `schema_version` | string | `"1"` — bump on a breaking shape change |
| `ts` | string | ISO-8601 UTC, `Z` suffix |
| `session_id` | string \| null | raw, untruncated `$CLAUDE_CODE_SESSION_ID` — same join-key convention as the other streams; `null` on a non-Claude-Code/manual run |
| `host` | string | `$SUBSET_HOST_LABEL` if set, else `hostname -s` |
| `backend` | string | `"basic-memory-mcp"` (the warm backend that fell back) |
| `reason` | string | `"unreachable"` (daemon not answering) \| `"degraded-result"` (reached, but no usable result — usually a `--project` mismatch) |
| `detail` | string | human-readable one-line cause (same text as the stderr notice) |
| `url` | string | the daemon endpoint (`KNOWLEDGE_SEARCH_BM_MCP_URL`) |
| `project` | string | `KNOWLEDGE_SEARCH_BM_PROJECT` the client asked for |

Example record:

```json
{"schema_version":"1","ts":"2026-07-05T15:11:04Z","session_id":"a1b2c3d4-e5f6-7890-abcd-ef1234567890","host":"mini","backend":"basic-memory-mcp","reason":"unreachable","detail":"bm mcp daemon unreachable at http://127.0.0.1:8766/mcp","url":"http://127.0.0.1:8766/mcp","project":"foundation-knowledge"}
```

### `gh-calls` — `gh-calls-<YYYY-MM>.jsonl`

Emitted by `workflows/scripts/gh-call-logger.sh` (the `gh`/`git-bug` TIMED
call-logger shim, F#988; lake promotion: temperloop `gh-logger-lake-stream`),
one record per wrapped `gh`/`git-bug` invocation. Unlike the other streams on
this page, the emit site is an **installed** shim (`temperloop install` /
`bin/subcommands/install.sh` copies it to `~/.local/bin/gh`, decoupled from
any repo checkout on disk), so its raw-dir resolution is
override-then-**fixed-fallback** — an explicit `GH_CALLS_RAW_DIR` first, else
an XDG-scoped default
(`${XDG_STATE_HOME:-$HOME/.local/state}/temperloop/gh-calls`, temperloop
#415) — rather than the BASH_SOURCE-relative trick the in-repo emit sites
use. A real foundation checkout that wants this stream unioned into its own
`meta/data/raw/` sets `GH_CALLS_RAW_DIR` explicitly; the default deliberately
never hardcodes a personal checkout path (temperloop#415 — the prior fixed
default, `$HOME/dev/foundation/meta/data/raw`, silently pre-populated the
very directory this project documents as the canonical downstream-clone
target on a fresh machine).

**Dual-write, not a replacement (yet).** This stream is written *alongside*
the shim's pre-existing self-truncating live TSV
(`${GH_CALL_LOG_FILE:-$HOME/.cache/gh-calls-v2.tsv}`), not instead of it —
`workflows/scripts/probe/gh-perf-report.sh` still reads that TSV directly for
the F#988 git-bug-tracker before/after evaluation's live-window tables, a
real current consumer. The TSV write retires once `gh-perf-report.sh` is
migrated to read this lake stream instead (or the F#988 evaluation
concludes), whichever comes first.

Record shape: `{schema_version, ts, host, start_ms, dur_ms, exit_code, pid, ppid, tool, context, op, cwd, args, session_id}`

| field | type | notes |
|---|---|---|
| `schema_version` | string | `"1"` — bump on a breaking shape change |
| `ts` | string | ISO-8601 UTC, `Z` suffix (wall-clock time the row was logged, i.e. after the wrapped call returned) |
| `host` | string | `$SUBSET_HOST_LABEL` if set, else `$HOSTNAME` (bash's own, domain-stripped) or `hostname -s` — same derivation as `claim.sh` / `emit-issue-touch.sh`, per-host as this whole directory is |
| `start_ms` | integer | epoch milliseconds the wrapped call started (ms-resolution via perl `Time::HiRes` when available, else whole-second) |
| `dur_ms` | integer | wall-clock duration of the wrapped call, in ms |
| `exit_code` | integer | the wrapped call's verbatim exit code, including 128+N signal deaths (e.g. Ctrl-C → 130) |
| `pid` / `ppid` | integer | the shim process's own pid / parent pid |
| `tool` | string | `"gh"` or `"git-bug"` — this shim's own install basename (basename-generic: the same script installed as either name logs+dispatches that same name) |
| `context` | string \| null | `$GH_CALL_CONTEXT` — the outermost command (`worklist` / `reconcile` / `pipeline-tick` / …), `null` when unset |
| `op` | string \| null | `$GH_CALL_OP` — fine-grained per-call attribution tag (e.g. the board adapter's calling function), `null` when unset |
| `cwd` | string | `$PWD` at call time |
| `args` | string | the wrapped call's arguments, space-joined, with embedded tabs/newlines flattened to spaces (same sanitization as the TSV's `args` column, so a GraphQL query arg can never split or corrupt the record) |
| `session_id` | string \| null | raw, untruncated `$CLAUDE_CODE_SESSION_ID` — same join-key convention as the other streams; `null` on a non-Claude-Code/manual run |

Example record:

```json
{"schema_version":"1","ts":"2026-07-10T18:22:47Z","host":"mini","start_ms":1783455767210,"dur_ms":143,"exit_code":0,"pid":41213,"ppid":41190,"tool":"gh","context":"worklist","op":"board:_board_item_list_fresh","cwd":"/home/dev/checkout","args":"issue list --repo o/r","session_id":"a1b2c3d4-e5f6-7890-abcd-ef1234567890"}
```

### `session-context` — `session-context-<YYYY-MM>.jsonl`

Emitted by `workflows/scripts/emit-session-context.sh` (temperloop#828, epic
#810 "session-start context growth") — **one record appended per session at
the SessionEnd hook seam** (`claude/hooks/session-end-log.sh`), recording
the whole session's realized token usage. This is the **realized-session-
context probe**: its job is measuring the WHOLE session's realized context,
not only the session-start prefix a prior scope measured — relocating
content out of an always-loaded document improves a t0
(before-the-agent-reads-anything) metric *by construction*, whether or not
the agent reads the relocated content two turns later. This stream is what
makes a relocation's *real* value measurable instead of assumed.

The SessionEnd hook calls the emit script with the transcript path ALREADY
resolved through the compaction-rollover chain (a compaction rolls the
conversation into a new `.jsonl`; re-deriving the path here would silently
undercount exactly the long sessions this probe exists to measure) and the
harness's `.context_window.*` fields already in hand — the emit script
never resolves either itself.

**Opt-in, default OFF** (setting-registry.tsv row `SESSION_CONTEXT_RAW_ENABLED`)
— an explicit switch, never sink-presence used as an implicit one. The
SessionEnd hook checks this gate before invoking the emit script at all; a
stranger's fresh kernel install therefore writes nothing to this stream
until they opt in.

**One-off reading.** `emit-session-context.sh --transcript <path> --print-only`
computes and prints the record to stdout without appending to the lake and
without checking the opt-in gate above — a direct, explicit invocation is
the consent for that one call. This is what lets another command (e.g. a
design that wants to measure realized context around a specific
intervention) take a single on-demand reading rather than only ever seeing
this stream fire passively at SessionEnd.

**Structural privacy.** Token counting is delegated entirely to
`workflows/scripts/lib/token_sum.sh`'s `token_sum_transcript()`, whose only
jq selector is `.message.usage.*` — never `.message.content` or any other
transcript field. This is the SAME expression `claude/status-line.sh`'s
"Tokens: NNk" display calls, so the displayed and recorded figures cannot
drift apart.

Record shape: `{schema_version, ts, session_id, host, project, cwd, transcript_tokens_total, context_window_size, context_window_remaining_pct}`

| field | type | notes |
|---|---|---|
| `schema_version` | string | `"1"` — bump on a breaking shape change |
| `ts` | string | ISO-8601 UTC, `Z` suffix |
| `session_id` | string \| null | raw, untruncated `$CLAUDE_CODE_SESSION_ID` — same join-key convention as the other streams; `null` when the caller omitted it |
| `host` | string | `$SUBSET_HOST_LABEL` if set, else `hostname -s` |
| `project` | string \| null | the caller's `--project` value (e.g. the session's `cwd` basename), or `null` |
| `cwd` | string \| null | the caller's `--cwd` value, or `null` |
| `transcript_tokens_total` | integer \| null | cumulative token sum (input + cache-creation + cache-read + output) across EVERY message in the whole (rollover-resolved) transcript — the realized-context figure this stream exists to record; `null` if no `--transcript` was passed |
| `context_window_size` | integer \| null | the harness's `.context_window.context_window_size` at SessionEnd, passed through verbatim; `null` if absent |
| `context_window_remaining_pct` | number \| null | the harness's `.context_window.remaining_percentage` at SessionEnd, passed through verbatim; `null` if absent |

Example record:

```json
{"schema_version":"1","ts":"2026-07-27T14:03:11Z","session_id":"a1b2c3d4-e5f6-7890-abcd-ef1234567890","host":"mini","project":"temperloop","cwd":"/home/dev/temperloop","transcript_tokens_total":83659,"context_window_size":200000,"context_window_remaining_pct":58.2}
```

### `item-efficiency` — `item-efficiency-<YYYY-MM>.jsonl`

Emitted by `workflows/scripts/emit-item-efficiency.sh` (temperloop#943), **one
record per plan item confirmed MERGED** — written from `claude/commands/build.md`
Step 4d, the same seam that emits the `merge` issue-touch. This is the
**overhead-per-shipped-change** stream: what one merged item actually cost in
tokens, wall-clock, and agent count, split by pipeline *phase*, so ceremony
growth is a number rather than a hunch (epic #923 spent ~55M tokens on
`/workshop`+`/assess` prep before a single worker ran, and nothing surfaced it).

**Composed, never re-derived.** Every token figure is selected out of
`workflows/scripts/pipeline-spend-report.sh --format json`, which owns the
cost-weighted per-agent transcript analysis *and* its four documented
correctness traps (dedupe-by-requestId above all). The emit script opens no
transcript and computes no token total of its own; when the profiler is
unreachable the phases are `null`, never a locally recomputed substitute.

Record shape: `{schema_version, ts, host, session_id, repo, slug, epic, issue, pr, level, phases, agent_counts, wall_ms, runs, spend_source}`

| field | type | notes |
|---|---|---|
| `schema_version` | string | `"1"` — bump on a breaking shape change |
| `ts` | string | ISO-8601 UTC, `Z` suffix |
| `host` | string | `$SUBSET_HOST_LABEL` if set, else `hostname -s` |
| `session_id` | string \| null | raw, untruncated `$CLAUDE_CODE_SESSION_ID` — same join-key convention as the other streams |
| `repo` | string \| null | `"owner/repo"` the item merged in |
| `slug` | string | the plan item's `slug:` — the per-item identity |
| `epic` | number \| string \| null | the epic issue number, the per-EPIC rollup key |
| `issue` / `pr` | number \| null | the item's `gh_issue:` and its merged PR |
| `level` | number \| null | the plan's dependency level, the per-LEVEL rollup key |
| `phases` | object | `{design, driver_prep, worker, mechanical}`; each is `null` (un-attributed) or `{agents, api_calls, units, wall_ms, tokens:{output, cache_create, cache_read, input}}`. `units` is cost-weighted; `tokens` is raw, so the cheap-cache-read distortion stays visible. `worker`/`mechanical` are the profiler's OWN `SPEND_MACHINERY_MAX_CALLS` class split, reused verbatim |
| `agent_counts` | object | `{worker, mechanical}` — agent counts by role, taken from the same class split, so counts and tokens can never disagree |
| `wall_ms` | object | `{worker, ci, merge_group, gate_wait, end_to_end}`, each an integer or `null`. **`null` means UNMEASURED, never zero** — the two mean opposite things to a reader deciding whether ceremony grew |
| `runs` | object | `{design, driver_prep, build}` — the workflow run ids each phase was attributed from, so any figure here is reproducible with `pipeline-spend-report.sh --run <id>` |
| `spend_source` | string | `"pipeline-spend-report.sh"` — the provenance marker |

Reader: `workflows/scripts/telemetry-brief.sh` § 3 Spend renders overhead per
merged item, the phase split, wall-clock medians, agent counts by role, and a
per-epic rollup — the surface `/telemetry` and `/check-in` Part 1 both show.

Example record:

```json
{"schema_version":"1","ts":"2026-08-02T19:51:53Z","host":"mini","session_id":"a1b2c3d4-e5f6-7890-abcd-ef1234567890","repo":"acme/widgets","slug":"telemetry-efficiency-metric","epic":923,"issue":943,"pr":1500,"level":1,"phases":{"design":{"agents":1,"api_calls":20,"units":6170,"wall_ms":1140000,"tokens":{"output":600,"cache_create":1000,"cache_read":18000,"input":120}},"driver_prep":null,"worker":{"agents":1,"api_calls":8,"units":2232,"wall_ms":420000,"tokens":{"output":160,"cache_create":800,"cache_read":4000,"input":32}},"mechanical":{"agents":3,"api_calls":9,"units":186,"wall_ms":120000,"tokens":{"output":30,"cache_create":0,"cache_read":300,"input":6}}},"agent_counts":{"worker":1,"mechanical":3},"wall_ms":{"worker":420000,"ci":300000,"merge_group":180000,"gate_wait":60000,"end_to_end":1800000},"runs":{"design":["wf_d-001"],"driver_prep":[],"build":["wf_b-001"]},"spend_source":"pipeline-spend-report.sh"}
```

### `diagnose-queue` — `diagnose-queue-<YYYY-MM>.jsonl`

Emitted by `workflows/scripts/emit-diagnose-queue.sh` (temperloop#1192), **one
record per `gate.sh diagnose-queue` verdict** — called from
`workflows/scripts/build/gate.sh`'s `cmd_diagnose_queue`, on every exit path
including its own internal error (`die()`) paths, so it fires whether
`diagnose-queue` runs as a standalone CLI invocation or as the internal probe
`cmd_poll`'s TIMEOUT path runs to classify a stalled native merge-queue poll.
This is the **decided-then-discarded** fix: `cmd_diagnose_queue` classifies a
stall into a structured verdict that `/build` and `/fix` branch their merge
decisions on, but until this stream existed nothing durable recorded which
verdicts actually fire, at what rate, or how often the queue stalls vs
genuinely fails.

**Emit is telemetry, never part of gate.sh's own contract.** The emit call is
a WARN-DON'T-DROP subprocess (see `emit-diagnose-queue.sh`'s own header) and
is deliberately never inlined into `gate.sh` itself: `gate.sh`'s whole design
is a closed outcome set that fails loud via `die()`, so a telemetry hiccup
must never be able to change `cmd_diagnose_queue`'s own exit code.

Record shape: `{schema_version, ts, repo, pr, outcome, detail, session_id, host}`

| field | type | notes |
|---|---|---|
| `schema_version` | string | `"1"` — bump on a breaking shape change |
| `ts` | string | ISO-8601 UTC, `Z` suffix |
| `repo` | string | `"owner/repo"` the PR lives in |
| `pr` | integer | PR number |
| `outcome` | string | one of `QUEUED` \| `MERGED` \| `MERGE_GROUP_FAILED` \| `MERGE_GROUP_INFRA` \| `DEQUEUED` \| `QUEUE_STALLED` \| `ERROR` — the full current `cmd_diagnose_queue` verdict set (`gate.sh`'s own header "diagnose-queue" section is the source of truth for this list) |
| `detail` | object | the verdict's own outcome-specific fields verbatim (e.g. `{"run_id":123}`, `{"enqueued_secs":900,"merge_group_runs":0}`, `{"error":"..."}`), or `{}` when the verdict carries none |
| `session_id` | string \| null | raw, untruncated `$CLAUDE_CODE_SESSION_ID` — same join-key convention as the other streams |
| `host` | string | `$SUBSET_HOST_LABEL` if set, else `hostname -s` |

Example record:

```json
{"schema_version":"1","ts":"2026-08-08T14:54:19Z","repo":"acme/widgets","pr":42,"outcome":"QUEUE_STALLED","detail":{"enqueued_secs":900,"merge_group_runs":0},"session_id":"a1b2c3d4-e5f6-7890-abcd-ef1234567890","host":"mini"}
```

### `resume-recovery` — `resume-recovery-<YYYY-MM>.jsonl`

Emitted by `workflows/scripts/emit-resume-recovery.sh` (temperloop#1908), one
record per `/build` **Step 0.5** (`claude/commands/build.md`) resume that
recovered or flagged at least one divergence. This is a **baseline
instrument** for the graph-of-record work: Step 0.5 cross-checks four state
stores on every resume (plan-note sentinels, git/remote, the board, the
workflow journal) — until this stream existed nothing durable recorded how
often a resume actually finds drift, of what kind, or how often the
crash-recovery paths (a held speculative worker, a journal `pr:` recovery, a
self-claim reclaim) fire in practice.

**Its own stream, not a `command-run` field.** `/build` never writes a
`command-run` record — its plan note IS the run record (see the `command-run`
section above, "these commands have no plan-note footer of their own (unlike
/build)") — and a resume is not a drive, so folding this into `command-runs`
would break that stream's `merged + resolved + parked + reported_no_op ==
items_processed` disposition-partition invariant, which has no slot for "a
resume found drift". A resume that recovered and flagged nothing emits no
record at all — this stream's population is exactly "resumes that found
something", never a per-resume heartbeat.

Record shape: `{ts, session_id, command, plan, recovered, recovered_count}`

| field | type | notes |
|---|---|---|
| `ts` | string | ISO-8601 UTC, `Z` suffix |
| `session_id` | string \| null | raw, untruncated `$CLAUDE_CODE_SESSION_ID` — same join-key convention as the other streams; `null` when unset |
| `command` | string | `"build"` — this stream has exactly one caller today |
| `plan` | string | the plan note's stem (its filename minus the leading `Plans/` path and the trailing `.md`) |
| `recovered` | array of `{kind, ref}` | one element per Step 0.5 divergence found, in the order given. `kind` is a CLOSED enum — `"worktree"` (item 1, an orphaned/unmapped worktree) \| `"pr"` (item 2, a PR/sentinel mismatch) \| `"claim"` (item 3, a self-claim reclaim) \| `"sentinel-journal"` (item 4, a `pr:`/`pushed_sha:` pointer recovered from the workflow journal) \| `"board-drift"` (item 3, a board/sentinel status or epic mismatch) — the five Step 0.5 checks. `ref` is an opaque caller-supplied pointer (a worktree path, a PR number, an issue/item slug) |
| `recovered_count` | integer | MUST equal `recovered`'s length (see the invariant below) |

**Invariant: `recovered_count == recovered.length`, and every `kind` must be
one of the five closed values above.** `emit-resume-recovery.sh` asserts both
and **exits 2** on either mismatch (after appending the record anyway, so the
inconsistency is preserved in the stream rather than swallowed) — the same
loud-invariant convention `emit-command-run.sh`'s disposition-partition check
uses. Any other failure (a missing required flag, jq absent, an unwritable
sink) is an infrastructure-class error: warn to stderr, exit 0, no record
appended — a telemetry emit must never fail or block the resume it hangs off.

Example record:

```json
{"ts":"2026-09-11T14:07:22Z","session_id":"a1b2c3d4-e5f6-7890-abcd-ef1234567890","command":"build","plan":"2026-05-16 stagefind - sweep follow-up","recovered":[{"kind":"worktree","ref":"temperloop.wt/foo-slug"},{"kind":"pr","ref":"1234"}],"recovered_count":2}
```

### `triples` — `triples-<YYYY-MM>.jsonl`

Emitted by `workflows/scripts/knowledge/triples.sh build` (temperloop#1910,
epic "Graph of record for work-item state", item "triples-extractor") — the
**derived graph-of-record stream**: one `{s, p, o, provenance}` record per
edge the extractor can derive from sources this kernel checkout already
carries (no new state, no network). Unlike every other stream on this page,
`triples` is not an event log of something that *happened* at emit time — it
is a batch re-derivation of the CURRENT state of its sources, safe to re-run
(`build` appends only records not already present in the current month's
file, so running it twice never doubles the lake).

**Predicates are drawn from `workflows/scripts/config/ontology-registry.tsv`'s
`edge` axis (ADR 0032) — an unlisted predicate is a hard build-time error,
never silently emitted.** Today's four sources/predicates:

| predicate | source | `s` | `o` |
|---|---|---|---|
| `cites` | `workflows/scripts/config/citation-registry.tsv`'s `<row-id, file>` rows, cross-checked against that file's own `<!-- cite: <row-id> <class>:<ref> ... -->` markers (`claude/citation-schema.md`) | the row id (e.g. `K.7`) | `"<class>:<ref>"` verbatim from the marker (e.g. `incident:F#1050`) |
| `touched_by` | the `issue-touches` stream above | `"<repo>#<issue>"` | the session, normalized through `join-keys-lib.sh`'s `jk_host_session_stamp` into the same `"<host>:<sess8>"` shape the board's own `fnd:host/session:*` claim stamp uses |
| `claimed_by` | the `claims` stream above (carries no `repo`, only a board number) | `"board:<board>#<issue>"` | the same host:sess8 stamp shape as `touched_by` |
| `supersedes` | `docs/adr/*.md`'s own `## Status` section (ADR 0000's MADR-lite process: an old ADR's Status becomes `Superseded by ADR-NNNN`) | the superseding ADR (e.g. `ADR-0033`) | the superseded ADR |

A `touched_by`/`claimed_by` source record whose session id is absent or not
UUID-shaped is skipped — never coerced into a triple with a made-up or
empty object. A `cites` marker whose `(row-id, file)` pair is not the
REGISTERED pair for that row id is likewise skipped — `query cites` answers
exactly what `workflows/scripts/validate-prose-budget.sh`'s own citation
reconciliation can enumerate for that row id, never a superset.

Record shape: `{schema_version, s, p, o, provenance}`

| field | type | notes |
|---|---|---|
| `schema_version` | string | `"1"` — bump on a breaking shape change |
| `s` | string | the triple's subject node id |
| `p` | string | the predicate — always a token from ontology-registry.tsv's `edge` axis |
| `o` | string | the triple's object node id |
| `provenance` | object | `{file, record}` — `file` is the repo-relative source file the triple was derived from; `record` is a locator inside it (`"L<n>"`, a 1-indexed line number, for every predicate above) |

`query cites <rule-id>` / `query touched_by <issue>` / `query supersedes
<adr-ref>` read this stream back (unioned across every `triples-*.jsonl`
month-file, matching the rest of this page's stream convention) — see
`triples.sh`'s own usage header for each verb's argument grammar (e.g.
`touched_by` accepts a bare issue number OR a fully-qualified
`owner/repo#N`).

Example records:

```json
{"schema_version":"1","s":"K.7","p":"cites","o":"incident:K#422","provenance":{"file":"claude/CLAUDE.kernel.md","record":"L312"}}
{"schema_version":"1","s":"acme/widgets#42","p":"touched_by","o":"mini:4d8b1d3e","provenance":{"file":"meta/data/raw/issue-touches-2026-07.jsonl","record":"L18"}}
{"schema_version":"1","s":"board:7#42","p":"claimed_by","o":"mini:4d8b1d3e","provenance":{"file":"meta/data/raw/claims-2026-07.jsonl","record":"L9"}}
{"schema_version":"1","s":"ADR-0033","p":"supersedes","o":"ADR-0031","provenance":{"file":"docs/adr/0031-durable-logical-order-lives-on-the-board-as-blocked-by.md","record":"L7"}}
```
