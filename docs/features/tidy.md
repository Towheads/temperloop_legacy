---
title: tidy
slug: tidy
---

## Problem

Every real-time extraction rule in this repo's standing instructions (decision
capture, feedback-memory capture, defect capture-at-source, stale-claim
hygiene, and so on) depends on a live session actually noticing the moment
and acting on it. Live capture misses things: a session ends before a
decision gets written down, an unattended run has no operator to ask a
clarifying question, a defect gets mentioned and never filed, a board claim
gets stranded when a session dies mid-work. Without a periodic backstop, all
of that signal simply evaporates — nothing ever re-reads old session
transcripts, so a missed capture is gone for good, and drift (an
ever-growing `_inbox` of unprocessed session stubs, an unbounded ledger, a
stale vault note) accumulates silently until someone trips over it.

## How it works

`tidy` is the nightly, unattended drain pass. It runs with **no live
operator**, so it never blocks on a question — it extracts liberally and
parks anything needing human judgment on a durable review surface instead
of asking.

Each run acquires a cross-machine lock — multiple hosts can share the same
session-stub backlog, so the protocol is acquire → wait for the store to
sync → elect the earliest-timestamped lock as the winner, discarding any
lock stale past a configured window (a discard whose delete fails is
best-effort: the lock is simply left for a later run to reap).

That lock protocol has **two arms**, selected on the same operator-absent
signal the build command uses for its own headless branch. A loop-capable
run — an interactive session, or a walk-away run whose harness re-invokes it
when a backgrounded wait finishes — takes the full wait-and-elect path above.
The **nightly headless one-shot has no such re-invoke loop**, so a
backgrounded sync wait would end the session *at* the wait and the drain
would never resume. That run instead takes a non-blocking arm: one cheap read
of the lock files, listed via its own filtered query (reaping any stale one), yield as a legible
no-op if a live peer lock is present, otherwise write its own lock and
proceed immediately — no wait, no election — releasing it at the end like any
other run. The residual cost is a narrow check-then-write race: the
task-generation step's search-then-add dedup absorbs duplicate *tasks* only,
so duplicate vault notes from two hosts draining in the very same second are
an **accepted residual risk** on that arm — the alternative is losing every
night's signal to a no-op drain. The nightly agent itself is not shipped by
this repo; an overlay install supplies it, and is what sets the
operator-absent signal.

Each run then: scans each pending session stub
through a pre-processing script that emits a compact JSON report instead of
requiring the full transcript to be read; adjudicates the report's
pre-matched extraction tells (lexicon hits) and skims the report's user-turn
digest for extraction candidates the tell lexicon missed (model-skim); and
routes each accepted extraction into one of several targets — architectural
decisions, feedback memories, patterns, mistakes, unfiled defects, stale
board-claim reports, and a vault-hygiene probe. A mandatory sensitivity scan
runs before any extraction, so a stub containing what looks like a credential
or personal data never gets copied into a durable artifact — only a flag
naming the *kind* of secret and its rough location is recorded.

Several passes are **drain-internal detectors** with no live counterpart at
all: a cross-session contradiction detector that proposes when a newly
banked decision appears to supersede an older one, a self-correction
detector that mines assistant-narrated reasoning reversals for reusable
patterns or pitfalls, and a vault-hygiene probe that periodically checks for
housekeeping and structural drift the vault otherwise never alarms on.

One of those drain-internal detectors also sweeps the **host filesystem**:
checkouts, worktrees, launchd agents, and the scratch directories background
job runs leave behind. Job scratch is the case with real bytes attached —
worker isolation gives each build its own scratch tree, but nothing reclaimed
those trees when the job ended, so regenerable build output and eval corpora
accumulated until a root volume filled completely. The sweep classifies each
job by its own recorded terminal state: a finished job past a grace window,
holding scratch over a size floor, is reclaimed in place (the run record is
kept; only the regenerable tree is deleted), while a job that has **not**
finished is reported for a human instead, because it may still resume. The
reclaimer is dry-run unless explicitly applied, re-verifies each target
against the job root before deleting it, and refuses obviously-wrong sweep
roots outright.

Every extraction is written as a **findings record** (one per drain-produced
artifact) so the whole extraction history — lexicon hits and model-skim
misses alike — is queryable rather than only visible inside the note it
produced.

### The Capture/Backstop pairing contract

Every extraction rule that *does* have a live counterpart is registered as a
**pair**: a capture rule (a real-time instruction, e.g. "capture a defect at the
moment it's noticed") and its backstop (the `tidy` step that re-derives
the same class of finding from a transcript after the fact). The pairing
registry lives in a table at the top of the `tidy` command spec itself — the
single source of truth for pairs generic enough that any checkout of this
repo needs them backstopped. A composed/overlay checkout may carry a second,
separate extension table for pairs that reference personal or
organization-specific capture rules with no meaning in a standalone checkout.

This is a **contract, not a convention**: a CI validator script parses both
tables — the base table always, and the extension table when present — and
checks that every capture anchor named in a row actually exists at the location
the row claims, and that every backstop anchor named in a row exists as a
`###`-level backstop step inside the drain command spec. It **fails the
build** if any pair is half-present in either direction: a capture rule added
with no backstop, or a drain step that references a capture rule no
longer in the source file it names. This is what makes "add a capture rule and
its backstop in the same change" mechanically enforced rather than a
review-time reminder that can silently lapse — a capture rule shipped without
its backstop half is caught by CI the same run it lands, not discovered months
later when the gap has already cost real signal.

## Integration

Consumes: the per-stub scan report (a preprocessing step that turns a raw
session transcript into a compact structured digest); the extraction-tell
lexicon (the canonical phrase/pattern list that drives lexicon-hit
adjudication); the board adapter's reconcile command, used for three things —
reporting (never fixing) stranded board claims, repairing drifted tracker
labels, and clearing the claim marker an already-closed issue leaves behind in
the operator's terminal status bar, which is the one repair this command
applies automatically, because nothing else ever clears it; a vault-hygiene
probe script.

Produces: durable vault artifacts (decisions, patterns, mistakes, feedback
memories); worklist issues (via the shared capture path) for unfiled
defects; several append-only review surfaces — pending decisions, proposed
supersessions, candidate tells, vault hygiene findings, sensitivity flags —
that this command **only ever appends to**, never mutates the `Status` of;
one findings record per accepted extraction.

The **check-in** feature is the read side of every surface this command
writes: it is the sole reader-and-disposer of the review surfaces above, and
it renders a status brief that summarizes what this command found overnight.
The **CI validator** for the Capture/Backstop pairing contract is a repo-level
quality gate, run alongside every other structural check.

## Resource impact

Runtime cost scales with the size of the pending session-stub backlog — each
stub costs one scan-report generation plus a bounded set of extraction
read/write calls, not a full-transcript read. The cross-machine lock adds a
fixed wait window per run to let a shared store settle before electing a
winner. Vault/store writes are small and targeted (one note or one append
per accepted extraction) rather than full-file rewrites. The board
stale-claim sweep costs one cached-bypassed board resolve plus two flat-cost
list reads per governed board — no per-item burst. Disk cost is the raw
findings-record stream, which grows by one line per accepted extraction and
is rotated monthly.

Disk is also **reclaimed** here rather than only consumed: the environment
sweep's job-scratch pass is the only thing that bounds background-job scratch,
which is otherwise write-only and unbounded (the motivating incident was two
finished job directories holding 38.5GB of regenerable build and eval
artifacts on a volume that then hit zero bytes free). Its own probe cost is
one directory-size measurement per job directory, gated by a size floor so a
routine host does no per-job work worth naming.

## Telemetry

Every accepted extraction appends one record to the findings raw-lake stream
(monthly-rotated JSONL), carrying the session id, the method that found it
(lexicon-hit vs. model-skim), the finding type, a reference to the artifact
it produced, and whether it was actually accepted or adjudicated as noise.
This is what makes the tell lexicon's measured miss rate (how often
model-skim catches something the lexicon didn't) directly queryable rather
than anecdotal, and it is what `check-in`'s candidate-tells review and any
downstream telemetry rollup read to show extraction throughput and lexicon
health over time.
