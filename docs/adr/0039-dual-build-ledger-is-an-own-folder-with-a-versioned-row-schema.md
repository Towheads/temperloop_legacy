---
title: "0039: The dual-build ledger is its own folder, not a piggyback on the resume ledger"
---

## Status

Accepted

## Context

epic: Towheads/temperloop#2065 — the new-work dual-build harness (design
brief: `Designs/temperloop - new-work dual-build harness.md`) needs a durable
place to record every dual-built item's outcome: which arm won, the judge's
preference, the whole-job cost, and an operator override if one happened.
This data accumulates across epics and is what the harness's eventual
non-inferiority report reads.

K#1924 (Backlog, under K#1910) already defines a per-step **resume** ledger:
`runMachinery` appends `{slug, step, head_sha, base_sha, machinery_version,
outcome, ts}` to `<repo>.wt/.ledger/<slug>.jsonl` so a repeated build step can
be skipped on retry. The design brief's operator initially chose (D12) to
piggyback the dual-build rows onto that same ledger, against the
facilitator's stated recommendation, reasoning that reusing an existing seam
beats inventing a new one (kernel principle 8, subtraction over mechanism).
That choice was then reversed at the brief's delta report (§ 3, "D12's K#1924
piggyback was superseded at 3.7") once two costs became concrete:

1. **Location.** `<repo>.wt/` is a linked-worktree tree, and per the kernel's
   environment-hygiene contract a worktree is disposable by definition — its
   contents are swept once its PR merges or closes. Dual-build rows are
   measurement data meant to accumulate *across* epics; a location that is
   correctly cleaned up as leaked scratch is the wrong location for data that
   must survive past the run that produced it.
2. **Invalidation.** K#1924's own contract invalidates every record in the
   resume ledger on a `machinery_version` bump — the right behavior for a
   resume cache (a version bump means "don't trust stale per-step state"),
   but wrong for measurement rows: a `machinery_version` bump has nothing to
   do with whether a judge's pairwise preference from three epics ago is
   still valid data.

Piggybacking also created a hard dependency: the design could not start until
K#1924 landed, and K#1924 is Backlog under a different in-progress epic
(K#1910) — an external blocker with no relationship to what the dual-build
harness itself needs to ship.

## Decision

The dual-build ledger and its patch archives live in their own folder,
**`.temperloop/model-comparison/dual-build/`**, beside the existing replay
harness's records (ADR 0027's module) — not under `<repo>.wt/.ledger/`. This
folder sits inside `.temperloop/`, which the repo's own `.gitignore` already
ignores wholesale, so no new tracked ignore entry is needed. No dependency on
K#1924 remains; the design starts independently of when that ledger lands.

**Row schema (a versioned contract surface, per `VERSIONING.md`'s bump
rules — a field addition is additive, a field removal or type change is
breaking):** one row per item per arm, record kind `dual-build`, carrying:

- `tier`, `model` — which tier and which model this arm is.
- `base_sha`, `head_sha` — the arm's starting point and the branch it built.
- `start_order` — which arm's worker started first (residual position-effect
  measurability).
- `gate_result` — pass/fail from the arm's local `quality-gates.sh --scoped`
  run plus the item's acceptance checks.
- whole-job cost fields — worker tokens, wall-clock, retry tokens, retry
  count, a recovery flag (first attempt plus every retry, D14).
- judge fields — pairwise preference, margin, and order agreement (D6).
- `pick` / `override` — the level's pick, whether an operator overrode it,
  and the override reason if so.
- `loss_reason` — one of `gate | judge | infra | incomplete`, so a loss is
  always attributable to a specific failure class rather than collapsed into
  a bare loss.
- `operator`, `host` — who/where ran it.
- `seq` — a monotonic id, paired with an expected-count check so a truncated
  ledger reports "records missing" rather than silently reporting a smaller
  N as the true sample.

Rows deliberately **keep K#1924's key fields** (`slug`/item identity,
`base_sha`, `head_sha`) so the two ledgers can be joined later if a future
analysis wants to correlate dual-build outcomes with resume/retry history —
the independence from K#1924 is about *not depending on it to ship*, not
about foreclosing a future join.

**Removal path.** A `dual-build purge` command deletes the whole
`.temperloop/model-comparison/dual-build/` folder (rows and patch archives
together) as a single directory delete — the named, testable uninstall/
engagement-over step — plus a config-named archive retention default that
bounds how long an archive survives absent an explicit purge.

## Consequences

**Benefits.** The design ships independently of K#1924's timeline (removing
an external blocker this epic doesn't control). Measurement data lives
somewhere whose lifecycle matches its purpose — durable, cross-epic,
sweep-exempt — instead of a location whose defining property (disposable,
resume-cache-scoped, version-invalidated) actively works against it. The
schema being named as a versioned contract surface up front means a later
field addition doesn't require re-litigating whether the row shape is
"real" — it already is.

**Costs.** This is a reversal of an operator decision (D12) made earlier in
the same design session, and the brief records it as taken *against* the
original recommendation and then superseded — a visible instance of a design
changing its mind mid-process rather than a clean first call. It also means
the harness owns a second small piece of ledger machinery (its own append/
read/purge path) rather than getting resume-ledger machinery for free; the
subtraction-over-mechanism principle that motivated the original piggyback
is satisfied instead by reusing `callWorker`, `judge.sh`'s spawn seam,
`stats.sh`, and the report-producer/`render.sh` shape (per ADR-0027's
module), not by reusing K#1924's ledger.

**Follow-on work.** If K#1924 lands with a record-kind exemption from
`machinery_version` invalidation and a sweep-exemption for patch archives (the
kill condition the brief's R4 names as the alternative), a later change could
still choose to join or migrate dual-build rows into that ledger — this ADR
does not foreclose that, it only states that shipping #2065 does not wait on
it.
