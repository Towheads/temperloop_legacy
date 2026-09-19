---
title: model-comparison
slug: model-comparison
---

# Model comparison

An inert, opt-in module that measures how a candidate model performs against
this repo's own real, closed-out work — before anyone re-routes a seat's
model in production. It ships in two halves with different standing: an
always-on **attribution telemetry stream** that every kernel-spawned seat
writes to (kernel, uncontroversial, costs nothing), and a **comparison
half** — replay runner, judge pass, comparison report — that does nothing
until an operator deliberately invokes it ([ADR
0027](../adr/0027-model-comparison-ships-as-an-inert-opt-in-module.md)).
Provider exposure (sending real repo content to a non-Anthropic vendor) is
governed separately by a committed allowlist and an append-only disclosure
log ([ADR
0028](../adr/0028-provider-exposure-rides-a-committed-allowlist-and-disclosure-log.md)).

## Problem

Deciding whether a cheaper model tier, or a non-Anthropic vendor model, is
good enough for a given pipeline seat is currently a guess: nobody re-runs
the same real work under two models and compares cost and quality
side-by-side, so a routing change either never happens (leaving spend on the
table) or happens on anecdote (risking quality nobody measured). Provider
routing itself — actually pointing a seat at a different vendor by default —
is a separate, later design decision; this module exists to give that later
decision an evidence base, on this repo's own history, rather than on a
synthetic benchmark that may not resemble what this pipeline's seats
actually do.

A second, sharper problem is honesty about what such a comparison can and
can't prove. A typical repo closes a modest number of issues in any given
window, a replay corpus never recovers 100% of that history cleanly (see
"Replay corpus and ground truth" below), and a small-N comparison invites
exactly the failure mode this module is built to avoid: a confident-sounding
verdict from statistically indistinguishable numbers. Every report this
module produces is required to say plainly when it can't tell winner from
noise, rather than pick one anyway.

## How it works

The module has five moving parts: an always-on attribution stream, a
replay runner, a live-tagging provenance layer, a judge pass, and a
comparison report that turns the first four into a number an operator can
act on. Each is described below, in the order a comparison actually flows.

### Per-seat attribution telemetry

Every kernel-spawned seat (a drive-tier machinery call, the retro judge, and
so on) writes one record per spawn to a dedicated attribution stream: seat
name, model, provider, input and output token counts, duration, and an
outcome reference (the issue or PR the spawn was working on). This is a
**second, narrower producer alongside**
the existing transcript-based cost measurement documented in
[`telemetry.md`](telemetry.md) — that producer keeps sole ownership of the
report's headline dollar/spend figure; the attribution stream exists only to
answer a question transcripts structurally cannot: *which seat, working on
which outcome, spent this?* ([ADR
0026](../adr/0026-attribution-telemetry-coexists-with-transcript-cost.md)).
Records are validated at content level (model/provider enums, field shapes),
not merely checked for presence, and the stream is schema-versioned from day
one.

One correction to that ADR's original text, surfaced by the L0
usage-capture-feasibility spike (temperloop#1246): the transcript producer's
request-id dedup rule does not carry over to this stream. Dedup exists to
collapse a transcript's redundant retries into one countable call when
*scanning* a transcript after the fact; a per-seat attribution record is
instead written once, at the spawn site, so there is no duplicate record for
dedup to collapse. The rule is **inapplicable** to attribution, not silently
inherited by it — worth stating plainly because the ADR's consequences
section reads as if both counting rules transfer unchanged, and only one of
them does.

See "Emit coverage is structurally partial" under Telemetry below for the
honest state of how many seats can actually emit this record today.

### Replay runner

Given a closed issue or merged PR from this repo's own history, the replay
runner re-runs that work item headlessly under a named candidate model, in
an isolated worktree, and produces a scored result: a diff against the
merged ground truth, quality-gate outcomes, tokens, and duration. Isolation
is structural rather than trust-based: the worktree carries no configured
push remote, runs under the kernel's write-guard class, lives under a
per-repo-derived scratch path, and is torn down on both success and
failure — a post-run probe backstops that, it isn't the primary control.

Before a batch of replays runs, a pre-flight estimate prints the eligible-N
for the requested window, the estimated cost of the batch, and whether that
N can realistically reach the module's significance threshold — so an
operator sees the tradeoff before spending anything, not after. That estimate
is stated in **cost-weighted token units** — the same unit, named by the same
string, that the comparison report publishes as its own cost basis, so the
batch you authorize and the figure the report hands back are directly
reconcilable (temperloop#1380; before it the two spoke different units under
the same word "token"). It is neither raw token counts nor dollars. The
per-replay figure the estimate scales is an **n=1 estimate** from a single
observed live replay and says so on every run — treat it as
order-of-magnitude until more replays have been executed.

**Replay corpus and ground truth.** The L0 replay/ground-truth spike
(temperloop#1247) measured this end to end against real history rather than
assuming it: of the closed issues sampled, only **about 52%** yielded a
usable replay (a reconstructable prompt, a resolvable pre-merge base, and a
scoped diff) — the rest were excluded for reasons the spike catalogs. The
dominant cause is the diff-scope rule's Tier C: **22 of 46 PRs (48%)** were
rejected for diff residue touching code the issue never named, concentrated
in broad refactor/propagation epics. Other exclusion paths include PRs
closing more than one issue (filtered out before sampling) and
base-resolution ambiguity (below). Two further traps the spike checked for —
squash merges bundling unrelated refactors, and formatting-only churn from
an autoformatter — were guarded against but measured **absent** in this
repo's own corpus (all 60 sampled merged PRs have two parents, so zero
squash merges; the gate suite runs shellcheck only, so there is no
autoformatter to produce such churn) — they did not contribute to the 48%.
Two traps the spike found genuinely real here: gate-version drift (the
gate-paths map moved 136 → 139 entries across the corpus window, "the one
that bites" per the spike) and post-hoc issue mutation, where the original
run writes back to its own issue after the fact (sweep `Clarified` answers,
triage cull notes, a PR cross-reference) — the runner cuts at `T_cut =
min(first branch commit author date, PR createdAt)`, drops every comment at
or after it, and rejects a candidate whose body was edited post-cut and is
unretrievable. Base resolution itself has more than
one defensible answer: the runner uses `git merge-base $MC^1 $MC^2` (the
fork point) as its rule, but of three plausible base-resolution strategies
the spike compared, they disagreed on **21 of 60** real merged PRs — meaning
the choice of base is not a formality, it measurably changes what "the
candidate's diff" is scored against.

**The yield is not a fixed constant — it drops on more recent history.**
The 52% figure above held for the spike's own 60-issue window
(temperloop#1247). A later, larger measurement (temperloop#1400, taken for
the temperloop#1262 validation run) built the corpus with `replay.sh corpus
--repo Towheads/temperloop` at two window sizes and found materially lower
yield on both, worsening as the window narrows toward the present:

| corpus | PRs sampled | single-issue | eligible | yield |
|---|---|---|---|---|
| spike (temperloop#1247) | 60 | 46 | 24 | 52% |
| deep sweep (this repo, 220) | 220 | 191 | 64 | **33%** |
| recent window (this repo, 80) | 80 | 72 | 18 | **25%** |

On the deep sweep, Tier-C `unnamed-code-residue` rejections rose to **65%
of all rejections** (spike: 48%) — 125 of 154 total rejections, against 29
`multi-or-zero-issue-pr` and 2 `post-cut-issue-body-edit`. The likely cause
is **corpus drift, not a scoring defect**: recent history is dominated by
broad multi-file changes (config + tests + docs + changelog fragment
landing in one PR — this epic's own pattern among them), which trip the
diff-scope rule's Tier C by construction. That means the rule is working
as designed against a corpus that has genuinely gotten harder to replay —
a real property of this repo's recent commit shape, not a bug in the
runner or a regression to fix. This is why the replay corpus is described
here as yielding **33% over the deep 220-PR window, 25% over the most
recent 80** — not a single "~52%" — and why a comparison report states its
corpus window and gate versions rather than implying yield is stable
across windows.

**Low-volume guidance.** Below roughly the module's configured sample
threshold, statistical significance is very likely unreachable — and the
measured yields above change how much headroom that requires. A rule of
thumb of "budget ~2x your target replay count" was implied by the spike's
52%; at the deep-sweep 33% an operator instead needs roughly **3x**, and at
the recent-window 25% roughly **4x** — so **budget ~3-4x your target**, not
2x, and weight toward 4x when the corpus window skews recent. Concretely,
the recent-80 window yielded only 18 eligible pairs against the module's
`MODEL_COMPARISON_MIN_SAMPLE_N` floor of 20: pre-flight correctly returned
`significance_reachable: false`, and reaching 40 eligible pairs required
sweeping 220 PRs, not the ~80 a 2x rule of thumb would have implied. Treat
a report generated from a low-N window as directional at best, or skip
running the comparison until enough history has accumulated to say
something with a straight face. The report itself enforces this rather
than leaving it to the reader's judgment: a run below the configured
threshold returns an explicit `inconclusive` verdict and never returns a
winner.

### Batch driver

The replay runner, the spend gate, the judge and the report producer are
separate components on purpose — and `workflows/scripts/model-comparison/batch.sh`
is the operator-invoked thing that connects them. Given a corpus file it runs
the pre-flight spend gate, replays every gate-authorized record in **both**
arms, judges each arm, and writes the two arm files the report producer reads.
It orchestrates only: it derives no statistic and re-implements no scoring,
judging, corpus selection or isolation.

Ten properties are worth knowing before you run one:

- **Arm order is counterbalanced, so arm is not confounded with position.**
  The driver used to run the arms in one fixed order on every record —
  baseline first, candidate second — which made ARM a perfect proxy for
  EXECUTION POSITION: every baseline leg was also a first leg, so no sample
  size could separate "the candidate model is cheaper" from "the second leg of
  a pair is cheaper". That is not a theoretical worry. The K#1262 validation
  run was an **A/A** comparison — the same model in both arms, so the true arm
  effect is zero *by construction* — and the second arm still came out ahead
  on 6 of 7 records (cache_creation −15.9%, duration −15.2%). Something real
  attaches to position; **what** it is remains an open question (a
  prompt-cache TTL story is one *hypothesis*, and nothing in this module
  asserts it), and the fix does not depend on the answer. The order is now
  assigned by a deterministic rule — the baseline arm runs first iff
  `((record_index + seed) % 2) == 1` — so it lands half and half, and the
  recorded rule and seed reproduce the assignment exactly. Counterbalancing
  rather than randomization on purpose: at tens of records a coin flip can
  hand you seven first-legs out of seven, while alternation *guarantees*
  balance at every N. Each leg record carries an `execution_order` block with
  its **position** (1 or 2), and the summary carries an `arm_order` block with
  the rule, the seed, the realized balance and the per-record assignment — so
  the effect of position can be **estimated** rather than assumed away
  (temperloop#1571).

- **The gate runs first, and consent is explicit.** Nothing is prepared or
  executed until pre-flight has returned a non-`stop` verdict *and* you have
  passed `--confirm`. The batch cap, the planned record/replay/pair counts and
  the cost basis are read verbatim off that gate rather than re-derived, so the
  batch you authorize and the batch that runs cannot drift apart — a selection
  that disagrees with the authorization is refused rather than partly spent.
  `--preflight-only` prints the gate's verdict and executes nothing.
- **The per-replay cost estimate is derived from what replays actually cost,
  when there is enough evidence to derive it.** That estimate is what the
  ceiling check and the confirmation prompt are computed *from*, so its
  provenance is a spend-gate correctness property rather than a footnote. The
  gate reads this host's own attribution records (seat `replay-candidate`,
  `usage_source: cli-envelope`) out of the raw lake, re-weights each one's raw
  token block under the `SPEND_WEIGHT_*` values in force *now* — so a weight
  retune never silently mixes epochs — and uses their **mean** once at least
  `REPLAY_PREFLIGHT_DERIVE_MIN_N` of them exist. Below that (a fresh host,
  usually zero) it falls back to the `REPLAY_PREFLIGHT_TOKENS_PER_REPLAY`
  literal. Either way `tokens_per_replay_basis` says **which mode produced the
  number in force** — naming `n` when derived, and saying the figure is
  UNMEASURED on this host when not. It never presents the literal as a
  measurement. Because the observed spread is wide (4.8x on the first live
  batch), the gate also publishes the whole observed distribution
  (`observed_replay_cost`) and projects the *same* batch at the observed p90
  and maximum (`estimated_total_tokens_range`), so a batch whose mean clears
  the ceiling but whose worst case does not says so out loud. The **stop**
  decision stays on the point estimate deliberately: a worst-case budget is a
  different claim from an expected one, and enforcing the former would refuse
  batches that are, in expectation, affordable (temperloop#1555, where an n=1
  literal was found 1.49x low against 14 real replays — nothing was wrongly
  authorized, but every margin shown was about twice as generous as the
  truth).
- **The projection is reconciled against the outturn.** A completed batch's
  summary carries a `spend_reconciliation` block stating **projected vs
  observed** total spend for the run, in the same cost-weighted unit the gate
  authorized it in: projected is the gate's own figure, observed is the
  `SPEND_WEIGHT_*` multiply-add over both arms' records. Past
  `MODEL_COMPARISON_SPEND_DRIFT_ALERT_PCT` in either direction it raises
  `drift_alert` and prints a stderr notice — so a stale estimate is caught by
  the pipeline rather than by someone summing the lake by hand. It is
  deliberately **not** a degradation: a wrong projection is a fact about the
  estimate, not a defect in the batch that just ran, so it never turns a
  `BATCH_COMPLETE` into a `BATCH_DEGRADED` (temperloop#1555).
- **A single record's failure does not lose the run.** That record is recorded
  as failed with its reason and the batch continues; the run exits `4`
  (`BATCH_DEGRADED`) with every failure named, and the **replay completion
  rate** falls out of the summary rather than needing hand-reconstruction.
- **A systemically unavailable spawn path stops the batch instead of being
  hammered.** Per-leg resilience is right for one bad record and wrong for an
  outage: on the first live batch, 14 records replayed over ~3.1h and then
  every remaining leg fast-failed in ~4–5s — 28 consecutive `candidate-spawn`
  integration errors, almost certainly a rate limit, driven to the end of the
  corpus. The driver now carries a **circuit breaker**: once
  `MODEL_COMPARISON_BATCH_MAX_CONSECUTIVE_STAGE_ERRORS` consecutive
  integration errors carry the **same** `integration_error.stage`, it stops.
  Any leg that scores resets the streak and a different stage re-keys it, so a
  scatter of unrelated per-record incompatibilities never trips it (set the
  threshold to `0` to disable the breaker entirely). The stop is deliberately
  *not* a degraded run: outcome `BATCH_STOPPED_EARLY`, exit **`5`**, a named
  `circuit_breaker_tripped` degradation, and a `circuit_breaker` block giving
  the stage, the streak, and how many legs and whole records were never
  attempted — so "the corpus was exhausted and some records were incompatible"
  and "the driver stopped early because the endpoint went unavailable" are
  never the same reading. Every skipped leg is recorded `not-attempted`
  rather than as an integration error (it makes no compatibility claim about
  its record), and a plain re-run against the same `--state-dir` re-drives
  exactly those legs without re-spending anything already done. The judge pass
  is skipped too, with a named reason — it spawns through the same seam
  (temperloop#1554).
- **A failed spawn's reason comes from both streams, not just stderr.** A
  candidate or judge spawn runs with stdout captured to an envelope file and
  stderr to a scratch file. `claude -p --output-format json` reports an
  API-level failure as a JSON object on **stdout** and writes nothing to
  stderr, so a failure detail built from stderr alone is blank by
  construction — the shape that produced `the candidate runner exited 1: `
  on all 28 legs of the first live batch, with the envelope carrying the
  actual reason deleted unread alongside the scratch dir. Both spawn sites
  now read the envelope *before* teardown and render both streams through
  `workflows/scripts/lib/spawn-diagnostic.sh`: the envelope's `is_error`,
  `subtype` and `api_error_status` are named, each fragment is labelled with
  the stream it came from, each stream is bounded at 400 bytes, and a spawn
  silent on both streams says so explicitly rather than trailing off after a
  colon (temperloop#1553).
- **The completion rate is reconciled against the artifact it describes.**
  Every count the driver publishes is derived from the *leg* records, which
  are written once; the *arm file* is a separate artifact that the judge pass
  rewrites in place. The summary therefore carries a `reconciliation` block
  checking the arm file on disk against the leg records the driver counted —
  record count, per-record identity, and record shape. A mismatch is a named
  degradation (`arm_reconciliation_mismatch`) and flips the run to
  `BATCH_DEGRADED`, so a healthy-looking rate can never sit silently beside an
  arm file that no longer holds what was counted (temperloop#1556, where a
  `replay_completion_rate: 1` was reported over arm files whose records the
  judge pass had already replaced with error objects).
- **The judge annotates; it never replaces.** `judge.sh judge-batch` emits one
  output line per input line and each one *is* the input record, with a `judge`
  sub-object attached. A row it could not judge keeps its record and carries a
  named judgment-absent marker instead of being swapped for a bare error
  object. A row that was never judgeable — an integration-error record, which
  has no candidate model and no diff because the spawn failed — passes through
  unjudged, spends no judge call, and does not count as a degradation; the
  report consumes it as a compatibility fact.
- **It is resumable.** The unit of work is a *leg* — one record in one arm,
  i.e. one `replay.sh execute`. Re-invoking after an interruption re-spends
  no leg and no judge call that already completed. A state directory is bound
  to one corpus and refuses to resume against a different one.
- **An interrupt stops it.** `^C` or a `kill` tears the in-flight replay
  worktree down and **stops the batch before the next leg begins** — it does
  not clean up and carry on spending — exiting with the conventional
  signal-derived status (`130` for SIGINT, `143` for SIGTERM) rather than a
  verdict of its own. That status is deliberately outside the driver's own
  closed exit-code set, and no summary object is printed: an interrupted batch
  never reached one. This is distinct from the failure resilience above — a
  leg that *fails* is recorded and the batch continues; only a real signal
  stops the run. Re-invoke to resume; nothing already terminal is re-spent.
- **There is no implicit model call.** Each arm needs an explicit recorded
  runner (`--baseline-runner` / `--candidate-runner`) or the single explicit
  `--live` flag; with neither, the driver refuses before it even reads the
  gate. Nothing scheduled invokes it (ADR 0027).
- **It can run several records at once — and a record's two legs never
  overlap.** `--concurrency N` (default `1`, from
  `MODEL_COMPARISON_BATCH_CONCURRENCY`, clamped to
  `MODEL_COMPARISON_BATCH_MAX_CONCURRENCY`) runs up to N corpus **records**
  at a time. The cost of not having it was measured, not guessed: the
  temperloop#1656 validation run took 29 min/leg, projecting **~27 hours for
  a 28-record batch**, about a third of it the in-worktree `quality-gates.sh`
  run rather than model time.

  Concurrency is across **records only**, never within a pair, and that is a
  correctness constraint rather than a simplification: the counterbalancing
  above stamps every leg with an `execution_order.position` of 1 or 2, which
  is meaningless if a record's two legs overlap — losing it would silently
  undo the fix and re-open the arm-vs-position confound. Because the
  assignment rule is a pure function of the record index, widening the batch
  cannot change *what* is measured: the same corpus and seed produce the same
  arm order and the same records in both arms at any N, and the summary's
  `concurrency` block publishes the **measured** wall-clock against the
  serial sum so the speedup is a number rather than a claim.

  **What raising it trades is the provider's rate limit, not CPU.** The
  28-leg outage that motivated the circuit breaker happened on a strictly
  *sequential* run; N concurrent records multiply request rate against one
  account's quota, so a higher N makes a trip **more** likely. There is a
  second, smaller local cost: each leg forks its own `quality-gates.sh`,
  which itself pools up to 4 wide, so N records is already roughly 4N
  concurrent processes. Raise it a rung at a time.

  One behaviour genuinely differs at N > 1, and the summary says so rather
  than leaving it to be inferred: **the breaker stops dispatch, not
  execution.** Records already running when it fires are allowed to finish —
  their legs may have spend committed against them, and killing one throws
  that away with no record to show for it — so `circuit_breaker` carries
  `records_in_flight_when_dispatch_stopped`, and `legs_not_attempted_n`
  counts only what was never started.

### Live candidate tagging

Live tagging adds **no new model-selection mechanism**: an operator points
the existing declared setting `$SWEEP_WORKER_MODEL` at the candidate for a
bounded, recorded window, exactly as they would to change the default tier.
What this module adds is provenance — a window record, a stamp on the
resulting PR naming which model produced it, and a matching telemetry tag —
so a live-tagged singleton's outcome can be correlated back to the model
that produced it after the fact.

### Judge-scored quality assessment

Every replayed or live-tagged output is scored by a judge model, extending
the same rubric/verdict lineage `judge.py` already uses (its `JUDGE_BIN`
seam) rather than inventing a second scoring mechanism. The judge is never
the candidate being scored (`judge != candidate`, enforced on every record).
That guard is stated honestly for what it is: it prevents **self-grading**,
it does **not** neutralize model-family style bias — a judge from the same
family as the candidate can still systematically favor that family's
phrasing. For a cross-vendor comparison, an optional judge-rotation mode
scores the same output with judges from more than one family and reports
the per-judge variance, rather than presenting one judge's opinion as
ground truth. A rotated judge outside the default provider is the one named
exception to "judge stays on the trusted default provider" — it goes
through the same allowlist and disclosure log as a candidate replay, never
as a silent carve-out ([ADR 0028](../adr/0028-provider-exposure-rides-a-committed-allowlist-and-disclosure-log.md)).

The judge's rubric borrows the reviewer-agent charters' checklists as prompt
*content* (the shell/architecture/language checklists inform the rubric
text); there is no runtime reviewer-agent invocation from this module —
reviewer agents stay live-session, human-facing tools.

### Comparison report

Given baseline and candidate records, the report emits whole-job cost per
merged outcome, judge quality scores, gate outcomes, intervention/rework
counts, and duration — with the uncertainty stated up front rather than
buried: a bootstrap confidence interval, the explicit `inconclusive` verdict
below the sample threshold described above, and a **minimum-detectable-effect
disclosure** ("at this N, only deltas of at least X are detectable") so a
comparison that can never reach a verdict at its current sample size is
visible before anyone reads a number as a conclusion. It also states the
emit-coverage percentage the underlying attribution records achieved (see
Telemetry below), the corpus window and quality-gate versions the comparison
ran under, and a **stated cost basis**: whether the dollar figure it shows
is *metered dollars* (what the vendor actually billed for that call), a
*token count* (the model-independent unit, comparable across providers that
bill per token differently), or a *subscription-usage share* (quota consumed
against a flat-rate plan like Claude Max/Pro, which has no per-call dollar
figure at all). These are not interchangeable units, and a report that
didn't name which one it's using would let a reader silently compare
apples to a subscription quota.

**Arm order, and the order effect.** Because the batch driver counterbalances
which arm runs first (see Batch driver above), the report can do more than
hope the confound away — it can measure it. An `execution_order` block states
whether the order was counterbalanced and publishes an **order-effect
estimate beside the arm effect**, both in the same cost-weighted token units:
the baseline-first and candidate-first halves of the corpus give two readings
of the same paired delta under opposite orders, so `arm = (mean_A + mean_B)/2`
and `order = (mean_A − mean_B)/2`. When the order effect turns out to be
**comparable in magnitude** to the arm effect — the published
`comparable_ratio` says at what fraction that starts — the report says
outright that **the comparison is not clean** and names no winner, with the
reason in `comparison.winner_withheld_reason`; the same holds when every
record ran in the same order, where the order effect is not identifiable at
all. This is a second, independent condition on the `winner` key: it can only
withhold a winner the sample floor already allowed, never mint one, and the
floor and the `inconclusive` behaviour are unchanged. A corpus whose records
carry no position at all (anything replayed before counterbalancing existed)
is reported as **unknown** rather than as not-clean — it discloses the gap and
withholds nothing, because inventing a position would launder exactly the
confound this measures (temperloop#1571).

**Capability limits, stated plainly.** At the sample sizes a real repo can
realistically supply — tens of replays per window, not thousands — this
module can detect large deltas and cannot reliably detect small ones; a
report showing "no significant difference" is evidence of *no large
difference*, not evidence of equivalence at every margin. Just as
importantly, a verdict from this repo's own replay corpus **does not
transfer** to another pipeline, another repo's issue mix, or another
prompt shape — it is a measurement of this pipeline's actual seats doing
this repo's actual work, not a general claim about either candidate model.

### Inert by design (ADR 0027)

The comparison half — replay runner, judge pass, comparison report — ships
as inert kernel source, the same shape the language-reviewer catalog
already uses: present in every kernel install, documented, zero standing
cost, and it does nothing until an operator deliberately invokes it.
`/sweep`, `/build`, and `/fix` behave identically whether or not this module
has ever been run. Replay batches are operator-initiated only; the module
adds no autonomous or cron arm of its own. Which candidate models and
vendors an operator actually tests, and their API keys, are overlay/operator
configuration, never a kernel default.

### Dual-build cumulative report (temperloop#2084, epic #2065)

A sibling to the comparison report above, over a different corpus: rather
than a replayed corpus of closed issues, `/build --dual-build` builds *new*
work under two models and judges each item pairwise (ADR 0038). The
`dual-build-ledger.sh` ledger those runs write to
(`.temperloop/model-comparison/dual-build/`, gitignored, single-host) feeds
its own drop-in producer, `workflows/scripts/report-producers/dual-build`,
which `temperloop report` renders per tier: a candidate item-win rate with
an exact binomial interval (never a bootstrap — `stats.sh exact-binom`),
the level-pick tally (which arm's code actually shipped, override-inclusive
— a distinct number from the win rate above, which is override-blind by
design), whole-job cost per arm, the override rate, and the judge's own
calibration status. A winner is only ever named once the judge is
`calibrated` (≥70% pairwise agreement over ≥20 human-labelled blind pairs,
ADR 0041) *and* the sample clears `MODEL_COMPARISON_MIN_SAMPLE_N` *and* the
unresolved rate (tied/unjudged/infra/incomplete items, excluded from the
win-rate numerator and denominator) stays under
`DUAL_BUILD_UNRESOLVED_THRESHOLD_PCT` — otherwise it prints "below floor -
keep accumulating" or "judge uncalibrated - verdict withheld" rather than a
number it cannot support.

**Unlike this module's own shim (above), the dual-build producer's locator
shim IS wired by `temperloop init`** — an adopter repo gets
`.temperloop/report.d/dual-build` unconditionally, the same treatment as
the kernel's `tokens` shim. This is still zero standing cost: a repo that
has never run `/build --dual-build` carries an empty ledger, and the
producer degrades to one `skipped -- dual-build: ...` line, exactly as an
absent `tokens` producer would.

## Integration

**Consumes:**

- The existing transcript-based cost producer and its counting rules
  ([ADR 0020](../adr/0020-cost-measurement-reads-session-transcripts.md),
  via [`telemetry.md`](telemetry.md)) — the sole owner of the headline
  dollar figure this module's report reads from, never re-derives.
- The declared per-seat model settings (`$SWEEP_WORKER_MODEL` and its
  siblings) and the setting-registry convention — there is no separate
  model-selection mechanism for live tagging.
- `judge.py`'s rubric/judge lineage and foundation's `workflow-eval.sh`
  spawn/score/emit patterns — **lineage only**: those files are overlay
  assets, absent from a kernel-only install, and this module's replay
  isolation regime is deliberately incompatible with the eval harness's
  shim-based isolation (replay does real, remote reads against this repo's
  own history; the eval harness does not).
- The reviewer-agent charters, as rubric source *text* only — never a
  runtime reviewer-agent call.
- `scripts/quality-gates.sh` as the mechanical outcome scorer for a
  replayed diff.
- This repo's own closed issues and merged PRs as the replay corpus.
- The `claude -p` CLI contract at every spawn site (`CLAUDE_BIN`
  overridable), and the kernel write-guard class for replay-worktree
  isolation.

- The kernel's **report drop-in seam** — the comparison report ships as a
  `.temperloop/report.d/` producer implementation
  (`workflows/scripts/report-producers/model-comparison`), the same shape and
  the same directory as the existing `tokens` producer, and reads the shared
  price table on the same two-tier override order
  ([`report.contract.md`](../../workflows/scripts/lib/report.contract.md)).
- `stats.sh` for every statistic it publishes and `score.sh aggregate` for
  the scored-only quality/compatibility split — the report derives neither
  itself, so a bound in the report and a bound from the library can never
  disagree.

**Produces:**

- The per-seat attribution stream, joinable with the rest of the raw
  telemetry lake ([`telemetry.md`](telemetry.md)) by the same session-id
  join key every other stream uses.
- Scored replay records, comparison reports, and (for any non-default-provider
  send) an append-only disclosure log entry ([ADR
  0028](../adr/0028-provider-exposure-rides-a-committed-allowlist-and-disclosure-log.md)).
- A provider allowlist file the report and the disclosure-log validator both
  read — repo-scoped, committed, default Anthropic-only.

**Running a comparison batch.** Select a corpus, look at what it would cost,
then authorize it:

```sh
# 1. select the corpus from this repo's own merged history
workflows/scripts/model-comparison/replay.sh corpus --repo <owner/repo> \
    --target 20 --out /tmp/corpus.jsonl

# 2. see what a batch over it would cost — executes nothing
workflows/scripts/model-comparison/batch.sh run \
    --corpus-file /tmp/corpus.jsonl --repo-root "$PWD" \
    --live --preflight-only

# 3. run it: both arms, judged, into .temperloop/model-comparison/
workflows/scripts/model-comparison/batch.sh run \
    --corpus-file /tmp/corpus.jsonl --repo-root "$PWD" \
    --live --baseline-model <baseline-id> --candidate-model <candidate-id> \
    --confirm
```

The driver prints one JSON object: the gate verdict it passed, the batch it
executed, every failure by name, the replay completion rate, and the paired
outcome count. Re-run the identical command to resume an interrupted batch —
completed legs are not re-spent. Its output lands as `baseline.jsonl` and
`candidate.jsonl` in `$MODEL_COMPARISON_REPORT_RECORDS_DIR`, which is exactly
what the report producer below reads.

**Running the comparison report.** The report producer reads two arms —
`baseline.jsonl` and `candidate.jsonl` — from
`.temperloop/model-comparison/` (repo-local and already gitignored; the
directory is `$MODEL_COMPARISON_REPORT_RECORDS_DIR` if you keep the corpus
elsewhere). Each line is one scored replay record, i.e. what `replay.sh
execute` writes and `judge.sh` annotates. With both arms in place the
producer can be run directly:

```sh
cd <your repo> && workflows/scripts/report-producers/model-comparison
```

It prints one JSON object on stdout and exits 0. **Nothing runs it for
you**: consistent with ADR 0027, the kernel deliberately ships **no**
`.temperloop/report.d/model-comparison` shim, so `temperloop report` never
invokes it in a bare checkout and this module adds no standing cost. To wire
it into `temperloop report`, add the same one-file locator + `exec` shim the
`tokens` producer uses to your own `.temperloop/report.d/` — an explicit,
reversible opt-in that touches one file and adds no new keys to any existing
producer's output.

**Rendering the report for a human.** The producer's JSON is the data,
not the page. `workflows/scripts/model-comparison/render.sh` (temperloop#2058)
lays the same object out decision-first — the verdict and the winner, or
exactly why no winner is named (the sample floor, an order-confounded quality
comparison, or no significant difference), in the first lines; one
at-a-glance table across quality, cost, gates, rework, compatibility and
duration; the honesty block (floor, intervals, minimum detectable effect,
order effect, corpus window, gate versions, cost basis, emit coverage); and
a short "what would change this verdict" list. It derives no statistic:
every figure is copied from the JSON, a withheld figure renders `n/a` with
its stated reason, and the `winner` key is read as the producer minted it,
never inferred from a verdict string or an interval. `batch.sh run` prints
the exact render command for the arms it just wrote:

```sh
workflows/scripts/model-comparison/render.sh \
    --records-dir .temperloop/model-comparison --out .temperloop/model-comparison/report.md \
    --summary-out .temperloop/model-comparison/report.summary.json
```

Unlike the producer, the renderer is **fail-closed** (the module's own
convention): a `skipped --` producer line, an absent, empty, unreadable or
non-JSON input, or a `schema_version` it does not understand is `CANNOT
EVALUATE` at exit 2 with no Markdown written — a rendering of nothing would
read as a report. The optional `--summary-out` sidecar
(`model-comparison-summary-v1`: arms, verdict, winner or withheld reason,
paired N against the floor) is the feed the `/telemetry` and `/check-in`
surfacing item (temperloop#2061) reads, so a finished comparison can reach
the daily brief without anyone re-parsing Markdown.

No existing command's default behavior changes by this module existing.
`/sweep`, `/build`, and `/fix` gain no new prompts, gates, or spend from a
bare checkout that never runs a replay or points `$SWEEP_WORKER_MODEL` at a
candidate.

## Resource impact

Running nothing costs nothing: a checkout that never invokes the comparison
half pays zero standing resource cost beyond the source files themselves
(ADR 0027). Two paths do carry real cost once an operator opts in:

- **Attribution emission** — one local file append per spawned seat per run,
  the same shape and the same negligible cost as every other stream in
  [`telemetry.md`](telemetry.md). No network call.
- **Replay and judge runs** — these make **real model API calls** under the
  candidate model (and the judge model), so they spend real tokens and real
  dollars, exactly like any other model invocation. This spend is bounded on
  two sides: the pre-flight estimate (see "Replay runner" above) shows the
  expected cost before a batch runs, and every comparison run enforces a
  config-named **per-comparison cost ceiling**, in the same cost-weighted
  token units as the estimate, routed through the existing quota gate — a run
  that would exceed the ceiling stops at pre-flight rather than partway
  through.

The disclosure log and the provider allowlist are both local, append-only
files with no network cost of their own; only the model calls they gate
carry real spend.

**The log's anchor is committed; the log is not.** The disclosure log is
hash-chained, and a two-value watermark anchor (`<max_seq> <last_hash>`)
records how long the chain is meant to be and what its tail hash is. That
anchor is a **tracked** file at
`workflows/scripts/model-comparison/disclosure-log.watermark`, beside the
committed provider allowlist; the **log itself stays gitignored** under
`.temperloop/`, so no provider history and no content ever enters the repo,
and the anchor carries neither. Committing the anchor is what makes a full
re-forge of the log detectable at all: rewriting the log and its on-disk
anchor together used to verify clean, whereas now the validator also checks
the live log against the anchor *as committed in git*, so hiding a re-forge
means rewriting git history too — which leaves its own trace. Commit the
anchor when a run changes it; `pa_disclose` says so on stderr each time
([ADR 0028](../adr/0028-provider-exposure-rides-a-committed-allowlist-and-disclosure-log.md),
amendment).

## Telemetry

**Emit coverage is structurally partial — by design, not by omission.**
The L0 usage-capture-feasibility spike (temperloop#1246) found that today,
only **3 of the pipeline's 12 spawn seats** can emit a **token-bearing**
attribution record (three more become emit-feasible with a one-flag
change; the remainder cannot, as things stand). The reason is structural:
the seat's **name** and the spawn's **token counts** currently sit on
opposite sides of a boundary with no join key between them.
`build-level.mjs`'s machinery calls are the clearest case: the harness
drops the per-seat label before the run journal is written, so the
`.mjs` caller that knows the seat name never sees the journal's usage
figures.

**Update (temperloop#2065 "worker-cost-capture").** `build-level.mjs`'s
per-item WORKER call (shared by `/build`, `/sweep` and `/fix`) closes that
specific gap differently: rather than correlating a journal after the
fact, its own emitted-shell seam (`workflows/scripts/build/
worker-usage.sh`) supplies the seat label and outcome ref directly,
joining the attribution stream as a fourth emit-feasible seat,
`build-worker`. It is emit-feasible but **never** token-bearing — a
worker spawned through the harness's built-in subagent call, rather than
through the `claude -p` command-line contract described above, has no usage
envelope to read tokens from,
so its own record is permanently attribution-only — so the "3 of 12 can
emit a token-bearing record" sentence above still holds; only the emit-
feasible *denominator* (`MODEL_COMPARISON_EMIT_FEASIBLE_SEATS`, 4) grew.
A comparison report's emit-coverage percentage is therefore expected to
read below 100%; that is not itself a defect to chase to zero, it is an
honest denominator this module states outright rather than silently
rounding up.
The full seat-by-seat inventory and mechanism is recorded in the operator's
knowledge store as `Context/temperloop - per-seat usage capture
feasibility.md` (not part of this repo's tracked tree); a stranger without
access to that store can instead read the spike itself, temperloop#1246.

**Every emit-feasible seat is now wired.** temperloop#1255 wired all three
(A7/A8/A9) into their real spawn sites — `pipeline-drive.sh`'s level-5b/5c
drivers and `pipeline-retro-judge-spawn.sh`'s judge — through a shared
extraction (`workflows/scripts/lib/model-usage-envelope.sh`) that turns the
captured `claude -p --output-format json` envelope into one record per
spawn. A mechanical coverage gate (`validate-model-usage-emit.sh`'s own
"spawn-site coverage" check) fails CI if a wired site's emit call is ever
removed, or if a future spawn site captures the same kind of envelope
without wiring emission — so "every emit-feasible seat stays wired" doesn't
depend on anyone remembering to check.

**What the attribution telemetry collects, in plain terms.** This is
written to be readable by a teammate or a client's reviewer opening this
file cold, with no other context:

- **What is collected:** for each pipeline seat that spawns (a `/sweep` or
  `/fix` worker, a `/build` item worker, a machinery or drive-tier call,
  and so on), one record per run naming which seat it was, which model and
  provider ran it, how many input and output tokens it used, how long it
  took, and which issue or PR it was working on.
- **Where it lands:** a repo-local, gitignored file on the machine that ran
  the work — the same raw-lake convention every other stream in
  [`telemetry.md`](telemetry.md) uses. Nothing here is transmitted off that
  machine by this module itself. A send to a **non-default model
  provider** additionally appends one line to a separate, repo-local
  disclosure log — provider name, an item reference, and a timestamp, never
  content — so a teammate or a client's reviewer can audit which vendors
  ever saw this repo's work, without needing to trust anyone's memory of it
  ([ADR 0028](../adr/0028-provider-exposure-rides-a-committed-allowlist-and-disclosure-log.md)).
- **What it never contains:** no source code, no prompt text, no model
  output, no issue or PR body text. The record is metadata about a spend
  event (who, what model, how much, how long, which reference number) —
  never the content of the work itself.

**Correctness checks.** Attribution records are schema-validated at content
level (model/provider enums, field shapes) by a paired emit-site validator,
the same emit/validate pairing convention every other telemetry stream in
this repo follows — a spawn site missing its emission, or emitting a
malformed record, fails the gate rather than silently under-counting.

**How the coverage figure reaches the report.** The comparison report reads
the attribution stream from the raw lake, counts the **distinct emit-feasible
seats** that actually wrote a record, and divides by the emit-feasible seat
count — the same `stats.sh coverage` primitive the rest of the module uses,
never a local division. Two consequences worth stating plainly:

- Seats **outside** the emit-feasible set never enter the numerator. The
  module's own replay and judge seats emit records too, and counting them
  would push the numerator past its denominator and turn the percentage into
  a meaningless number above 100%.
- The report prints the **named exclusion list** beside the figure — which
  seats are out and why — plus, in the same block, what a sub-100% reading
  does mean (an emit-capable seat ran without writing a record: a defect with
  an owner) and what it does not (that the rest of the pipeline's spend is
  unmeasured — it is not). Without that list a 100% reading would imply a
  coverage claim this module does not make.

**What the report discloses on every run, flattering or not.** Alongside
coverage, each report states its corpus window (which records it ran over,
timestamps stored in UTC and rendered for a human in the configured display
timezone), its quality-gate versions (there is no single one: each replayed
record's gate ran from that record's own base worktree, so the set of
(gate script, base commit) pairs actually exercised is reported), and its
cost basis. These are emitted unconditionally, never only when they look
poor — a disclosure that appears only on a bad run teaches a reader to treat
its absence as reassurance. The suite pins that by asserting all four appear
on a deliberately *flattering* run and deleting each in turn to prove the
assertion notices.

**Cost basis, and the figures the report refuses to print.** A replay record
carries token counts and no vendor cost field, so the report's cost figures
are **cost-weighted token counts** — the SPEND_WEIGHT_* weighting, taken as
values from the same settings the attribution emit uses so the two producers
can never disagree about how a token is counted. The report says so
explicitly on every run, because token counts, *metered dollars* (what a
vendor billed) and a *subscription-usage share* (quota against a flat-rate
plan) are not interchangeable units. An optional directional dollar overlay
is layered on when a price table resolves, always carrying that table's date
and an explicit staleness label; an absent, stale or malformed table degrades
to a stated token-counts-only basis rather than a silently missing line.
Three figures the report will not print at all: a whole-job cost per merged
outcome when some scored records carry no token counts (a figure over a
partial cost corpus is derived from missing data), a confidence interval or
minimum-detectable-effect it could not obtain from the statistics library,
and a **winner** on any run that is below the sample threshold or shows no
significant difference. A run that cannot be evaluated at all renders one
`skipped -- model-comparison: <reason>` line at exit 0 and no report object —
so "could not evaluate", "inconclusive" and "the candidate is better" stay
three visibly different statements rather than collapsing into one.
