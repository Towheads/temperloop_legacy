---
title: The merge gate — native and managed backends, ejection, and landed-merge confirmation
slug: merge-gate
---

## Problem

A build pipeline that opens pull requests automatically also has to land
them safely, and "safely" has two separate failure classes to avoid.

First, GitHub's native merge queue — the platform feature that lets a batch
of pull requests be queued for merge and re-validated against each other
automatically — is only provisionable on an organization-owned repository
on a paid plan. A personal account, or a free organization, can turn on
branch protection and required status checks, but cannot arm a merge queue.
A pipeline that assumes a native queue is always available simply doesn't
work on a free personal repository at all.

Second, whichever backend lands a merge, a merge *call* returning success
only means the merge was **initiated**, not that the code has actually
landed. Treating "merge requested" as "merge complete" — closing a tracking
issue, or moving a board card to done, on the strength of the API call alone
— can close out work against code that was never merged at all: the call
can be rejected, the PR can go stale and get closed without merging, or the
queue can simply take a while.

## How it works

`workflows/scripts/build/gate.sh` is the deterministic-machinery script that
owns the merge-gate steps of `/build` — at the level boundary, and per item
as each PR goes green: reading a PR's live
mergeability, detecting whether the repo's default branch is under a
*strict* status-check requirement, computing a mechanical risk verdict over
a batch of PRs, queuing a merge, nudging a stale branch, and polling until a
merge is actually confirmed. It never decides *whether* to merge — the
go/no-go stays a human or orchestrator seat; `gate.sh` only executes the
mechanics once consent is given.

**The backend seam.** `gate.sh backend <owner>/<repo>` answers exactly one
question — does this repository have a native merge queue available —
without merging anything itself:

- `BUILD_MERGE_BACKEND` (default `auto`, in `build.config.sh`) can force
  `native` or `managed` outright, skipping the probe entirely.
- Under `auto`, the script probes the repository's branch ruleset for a
  `merge_queue` rule on the default branch. Finding one resolves to
  `NATIVE`; not finding one, or the probe itself failing (a `gh` error, a
  404, an empty response), resolves to `MANAGED`. This direction is
  deliberate: defaulting to `NATIVE` on an unreadable probe risks queuing a
  native `--auto` merge on a repo that turns out to have no queue armed at
  all (branch protection simply rejects it, loudly); defaulting to
  `MANAGED` on a queue-armed repo the probe merely failed to *see* is safe,
  because `MANAGED` never silently arms an auto-merge nobody chose — it
  just does a little more work by hand than strictly necessary. A
  `probe_failed: true` flag on the `MANAGED` outcome lets the caller tell
  "confirmed no queue" apart from "couldn't tell."

**Managed-merge mechanics and EJECTED semantics.** When the backend is
`MANAGED`, `gate.sh managed-merge <owner>/<repo> <pr>` replicates the native
queue's re-validate-then-land behavior per PR, in `--strict` mode by
default:

1. Fold the current default branch into the PR's head (`gh pr
   update-branch`) — the same re-test-against-current-tip a native queue
   performs before landing.
2. Resolve the **updated** head SHA — never poll a stale one, since the
   pre-update SHA's checks may already read green for code that is about to
   be superseded.
3. Poll that SHA's check-runs (again over REST, not the GraphQL-backed
   watch helper) until every run completes or the deadline passes.
4. **Green** → merge directly (not queued — mergeability was already
   established by the re-poll) and confirm. **Red** → the PR is `EJECTED`
   (a distinct outcome, exit code 5): no merge is attempted, and no
   plan-note sentinel or label is written, because consent and writeback
   both stay orchestrator-side. Ejection does not stop the rest of the
   batch — the caller moves on to the next PR and can return to the ejected
   one once its head is fixed. `--non-strict` skips the update-branch and
   re-poll entirely and merges directly, trading the extra CI run for a
   cheaper, less-revalidated merge.

**A draft PR is a named state, not a raw platform error.** GitHub refuses
`enablePullRequestAutoMerge` on a draft, so an enqueue against one failed with
the raw string `GraphQL: Pull request is a draft (enablePullRequestAutoMerge)` —
true, but naming neither the state nor the fix, and leaving behind a PR no
re-run could ever land. `gate.sh queue` now reads `isDraft` **before** the
enqueue and returns a distinct `DRAFT` outcome (exit code 9) whose message names
the draft state and the remedy (`gh pr ready <n> -R <owner>/<repo>`). It
deliberately does **not** flip the PR ready itself: nothing in this repo opens a
draft (`pr.sh open` passes no `--draft` on any path, and no script runs `gh pr
ready`), so a draft reaching the merge gate is always a human decision, and
silently un-drafting it would override the one party who made it. The pre-flight
probe fails open — an unreadable `isDraft` proceeds to the enqueue — and a second
classifier names the same `DRAFT` outcome if `gh` itself rejects the draft, so
neither path can surface the raw GraphQL text.

**Landed-merge confirmation.** Both the native path (`gate.sh queue`, which
enqueues via the platform's own `--auto` merge, followed by `gate.sh poll`)
and the managed path's post-merge step confirm a merge the same way: poll
`gh pr view` until `state == "MERGED"` **and** a non-null `mergedAt` — the
sole success check. A `CONFLICTING` mergeable state or a `DIRTY`
merge-state status is treated as terminal-bad rather than retried
indefinitely; running out the poll's deadline is a distinct `TIMEOUT`
outcome. Because `MERGED` is checked directly rather than inferred from
"closed" or "checks green," a PR that gets closed without merging can never
be mistaken for landed work — closing a tracking issue or moving a board
card only happens after this confirmation, never on the strength of the
merge call alone.

**Classify before retrying.** The CI poll (`ci-poll.sh`) absorbs a transient
`gh`/API hiccup — an HTML error page, a 5xx — by re-issuing the same call up to
`CI_POLL_API_MAX_ATTEMPTS` times with a graduated `CI_POLL_API_RETRY_BACKOFF`
between attempts, instead of surfacing a blip as an immediate `ERROR` the
orchestrator would escalate like a genuine CI failure. But it inspects the
failure *first*: one matching `CI_POLL_API_DETERMINISTIC_PATTERN` — a permanent
HTTP 4xx, an auth failure, a bad argument — cannot change on a re-issue, so it
dies at once carrying `deterministic_failure: true` and spends neither attempts
nor backoff seconds. The default pattern deliberately excludes HTTP 429, which
*is* transient and keeps its retries. The three `ERROR` shapes are therefore
distinguishable by field: a hard argument error (neither flag), a permanent
remote error refused a retry (`deterministic_failure`), and an outage that
outlasted every attempt (`transient_retries_exhausted`). The mergeability read's
single re-poll needs no such classifier — the only states it re-polls
(`UNKNOWN`, a lone `BEHIND`) are by definition not-yet-computed server-side
values, and every deterministic answer is returned on the first read.

## The armed wake (`wake-guard.sh`, temperloop#2210)

The queue and CI are **pull-only**: nothing notifies a session that a PR
merged, went green, or fell `BEHIND`. So a turn that ended with an open PR and
no armed wake source never learned anything again, and silence became
indistinguishable from "still queued" — the shape that stalled the `/build` of
epic #2065 three times (~20 min, **12.5 h**, and once more), each one caught by
the operator asking rather than by any mechanism.

`workflows/scripts/build/wake-guard.sh` closes that structurally rather than by
instruction:

- **`arm <owner>/<repo> <pr>…`** — the wake source, armed. A **blocking**,
  bounded, foreground poll that drives `gate.sh poll` per PR. Because it
  blocks, the turn *cannot* end while the PR is still open, and a merge that
  lands after the session would otherwise have yielded is seen within one
  `$BUILD_WAKE_POLL_INTERVAL`. `RESUMED` (exit 0) / `CONFLICTING` (3) /
  `TIMEOUT` (4) — gate.sh's own verdicts, relayed.
- **`bound --label <l> --timeout-secs <s> -- <cmd>`** — the watchdog that
  **kills** rather than detaches. The `Bash` tool's `timeout` parameter only
  moves a command to the background at its bound; that is how a 500 s-bounded
  command ran 12.5 h. This wrapper runs the command in its own process group
  and signals the group, so nothing is left orphaned. It never asks the
  watched process for permission to fire — no `pgrep -f`, no liveness poll,
  just a pid captured up front and a `sleep`.
- **`assert --open <n> --wake <kind>`** — the refusal. Open work with nothing
  scheduled exits non-zero instead of yielding into silence.

`claude/workflows/build-level.mjs` compiles the same kill-not-detach bound into
the worker's own scoped-gate command, so a wedged `quality-gates.sh` is killed
at the workflow's `#1071` step ceiling and its sentinel reports
`{"state":"finished","rc":137,"outcome":"TIMEOUT","timedOut":true,…}` rather
than sitting at `"running"` while the suite runs on unwatched.

Sizing is two named settings — `BUILD_WAKE_POLL_INTERVAL` and
`BUILD_WAKE_POLL_TIMEOUT` (a bound on **one call**, kept under the harness's
foreground `Bash` cap). Neither is the merge-queue ceiling: how long a PR may
legitimately sit in the queue stays `BUILD_QUEUE_TIMEOUT`, whose own sizing
rule is stated at its definition in `workflows/scripts/build/build.config.sh`
(temperloop#2055).

Covered by `workflows/scripts/build/tests/test_wake_guard.sh`.

## Integration

`/build`'s batch merge gate (`claude/commands/build.md`, the level-boundary
steps) is the sole caller: it reads each candidate PR's state with `gate.sh
read`, checks strictness with `gate.sh strict`, computes the batch's risk
verdict with `gate.sh risk` before asking for consent, and — once consent is
given — either queues a native merge (`gate.sh queue` + `gate.sh poll`) or
walks the batch through `gate.sh managed-merge` on the managed backend.

On `/build`'s `--no-workflow` **conversational** path it also calls that
identical sequence **per item, as each PR goes green** (build.md Step 3h.5),
over a *one-PR* set — but only for an item the same
`gate.sh risk` predicate already classes clean and disjoint, so a level's
merges spread over its duration instead of arriving as one burst. A risky
verdict is never landed this way; it waits for the batched gate. Because
each such merge is its own invocation of the per-PR mechanics, the
re-validate-against-the-current-tip step runs once per merge rather than
once per level — which matters precisely because an early merge moves the
base out from under its still-open siblings.

Step 3h.5 is scoped to that path deliberately (temperloop#1452). On the
**default Workflow path** the per-level `build-level.mjs` neither merges nor
writes the plan note, and it returns to the orchestrator only at the level
boundary — so no actor there can land a PR "at its own green", and every
item batches to the level-boundary gate above. That is the documented,
accepted trade-off, not a gap: the alternative is a merge-capable workflow
runtime, which would put an un-consented irreversible merge inside a process
with no consent surface.

The sweep pipeline reuses the same script for its own per-fix merges. Poll
tunables (`GATE_CI_POLL_INTERVAL` / `GATE_CI_POLL_TIMEOUT`,
`GATE_MERGE_POLL_INTERVAL` / `GATE_MERGE_POLL_TIMEOUT`) live in
`build.config.sh` alongside every other build setting, so a slower or faster
poll cadence is a single config edit rather than a script change.

## Resource impact

Every read, poll, and merge call is a `gh` invocation against GitHub's REST
API — the same rate-limit bucket `ci-poll.sh` and the board adapter both
use, so poll cadence here competes directly with board traffic for one
shared budget. A managed-backend merge costs one extra CI run per PR (the
SHA-pinned re-poll after the branch update) compared to a native-queue
merge, which is the price of replicating the queue's re-validation without
platform support for it. Polling wall-clock time is bounded by each
command's own timeout, so a stalled merge parks the run rather than
spinning forever.

## Telemetry

None as a dedicated stream — every `gate.sh` invocation emits one
structured JSON outcome line on completion, and that outcome *is* the
observable signal: an `EJECTED` result names the failed check-run IDs, a
`MERGE_REJECTED` result carries the platform's own rejection message, and a
`TIMEOUT` reports how long the poll waited. A merge that never confirms
`MERGED` shows up as a PR left open with no plan-note `[x]` sentinel, which
is the durable, at-a-glance signal that something needs attention.
