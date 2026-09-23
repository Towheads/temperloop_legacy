# Model fan-out inventory

Every site in this repo that spawns a model seat, and what decides which tier
that seat runs on.

This is the **complement** to temperloop#972, which wired tier levers at four
*known* sites. #972 answered "give these four seats a lever." This document
answers the question nobody had asked: **which seats exist at all, and does each
one's tier come from a decision or from an accident?** Its job is to leave no
seat undispositioned — including the ones that turned out to be fine.

Scope: `claude/commands/*.md`, `claude/workflows/*.mjs`, `claude/agents/**`,
`workflows/scripts/**`, `bin/**`, cron/launchd drivers, and eval/bench
harnesses.

## The three dispositions

Every seat below is classified as exactly one of:

| disposition | meaning |
|---|---|
| **explicit setting** | The tier is named by a setting or a schema field. Changing it is a config edit, not a code edit. |
| **justified inherit** | The seat inherits the session model *on purpose*, and the reason is written down at the seat. |
| **silent inherit** | The seat inherits because nobody chose. No lever, no stated reason. This is the class this document exists to find. |

The distinction that matters is **justified vs. silent**, not *explicit vs.
inherit*. Inheriting the top tier is frequently the right answer — the defect is
inheriting it without anyone having decided to.

## The decision rule: whole-job accounting

**A cheaper tier stays only if job-including-repairs beats the strong tier.**

Per-seat token cost is not the unit that matters. A weaker model that triggers a
retry, a fallback, a re-spawn, or a human repair can lower per-seat spend while
*raising* total spend — and in the limit it can lower per-seat spend while
delivering none of the job at all. Both failure modes were observed while
measuring for this document (§ Measurement); neither is hypothetical.

Three corollaries, each earned from a measurement rather than assumed:

1. **Price the repair, not the call.** A seat whose output is parsed, gated, or
   re-run has a repair path, and the repair path is part of its cost. A seat
   whose output is printed verbatim does not.
2. **Provider tier is not a proxy for weighted units.** The pre-registered
   baseline weights output tokens at **5** and cache reads at **0.1**. A cheaper
   model that is *chattier* can cost the same or more in weighted units while
   costing far less in dollars. Measured: 5.5x cheaper in dollars, within noise
   in units, on the same prompt (§ Measurement).
3. **Tier by verification, not by difficulty.** A seat whose output is checked
   by a mechanical gate can be down-tiered. A seat whose output *is* the gate
   cannot. This is the existing kernel policy (`claude/CLAUDE.kernel.md`
   § Cost-tier routing, `claude/commands/build.md` 3c § Seat tiers); this
   document applies it rather than restating it.

This rule is why two of the three seats this item gave levers to were
deliberately **not** re-tiered, and why one of those refusals is backed by
measurement rather than caution.

## A. Batch-pipeline seats — explicit setting

Each names its tier symbolically; the default lives only in
`workflows/scripts/build/build.config.sh`.

| # | seat | setting | notes |
|---|---|---|---|
| A1 | `/build` 3c per-item worker | plan-item `model:` field | Stamped by `/assess` from `size`+`kind` (`claude/plan-schema.md`). Absent → inherit, itself a justified default (§ B1). |
| A2 | `/sweep` Phase-1 detection fan-out | `$SWEEP_DETECT_MODEL` | Contract-pinned to the inherit sentinel: detection is judgment, and a missed ambiguity reaching Phase 2 is the costly failure. |
| A3 | `/sweep` Phase-2 fix worker | `$SWEEP_WORKER_MODEL` | temperloop#972. |
| A4 | `/fix` Step-4 single-issue worker | `$FIX_WORKER_MODEL` | temperloop#972. |
| A5 | `build-level.mjs` `runMachinery` (solo) | `$BUILD_MACHINERY_SOLO_MODEL` | temperloop#972. Passed as workflow input; the `.mjs` has no shell to source config from. |
| A6 | `build-level.mjs` `runMachineryBatch` | `$BUILD_MACHINERY_BATCH_MODEL` | temperloop#972. Paired with A5, not a default for it. |
| A7 | `pipeline-drive.sh` level-5b safe driver | `$PIPELINE_DRIVE_MODEL` | Mechanical drives. |
| A8 | `pipeline-drive.sh` level-5c merge driver | `$PIPELINE_DRIVE_MERGE_MODEL` | High-judgment; strong tier by policy. |
| A9 | retro judge (`pipeline-tick.sh`, `/pipeline-drive`) | `$RETRO_JUDGE_MODEL` | Own setting, distinct from A7. |

**A5/A6 carry a `'haiku'` fallback literal inside `build-level.mjs`.** That is
a code default in the one file that structurally cannot source shell config
(no filesystem, no Node, no shell), not a prose restatement — it is the
sanctioned form, and it is `||` rather than `??` so an empty setting collapses
to it exactly like an absent one.

## B. Session and agent seats

### B1. Command sessions — justified inherit

The `/build`, `/assess`, `/triage`, `/workshop`, `/sweep`, `/fix`, `/check-in`,
`/next` and `/tidy` sessions themselves always keep the session model. Stated at
`claude/commands/build.md` 3c § Seat tiers: *they are sessions, not agent defs,
and their judgment is what everything else gates on.* Nothing downstream checks
an orchestrator's reasoning, so rule 3 forbids down-tiering them.

### B2. Agent-frontmatter seats — explicit setting

Every agent under `claude/agents/**` declares its own tier in frontmatter. This
is a **harness-native** declaration surface: the agent file is read by the
harness at spawn time, and there is no shell seam to source `build.config.sh`
from — so a literal here is the analogue of A5/A6's `.mjs` fallback, not a
Named-setting-convention violation.

Declaring **`sonnet`** — findings are advisory inputs the orchestrator and a
human filter, so a mechanical gate stands behind them:
`congruence-lens`, `consultant-persona`, `docs-reviewer`, `hobbyist-persona`,
`red-team-lens`, `requirements-auditor`, `team-member-persona`, and the four
adopter-catalog language reviewers for languages this repo does not itself
ship (`go`, `java`, `rust`, `swift`).

Declaring **`inherit`** — gate-bearing seats kept on the session model by
`/build` 3c § Model tiering absent a paired measurement (temperloop#2132):
`workflow-reviewer`, `typescript-reviewer`. (Both left the `sonnet` roster
above at that item; the roster is corrected here rather than left to disagree
with the charters.)

Declaring **`opus`** — the seat's own output *is* the gate, so no cheaper tier
is admissible under rule 3: `architecture-reviewer`, and — since
temperloop#2179 — `shell-reviewer` and `python-reviewer` (§ B3).

This seat was a **justified inherit** until temperloop#1456, which found the
justification and the mechanism disagreeing: the seat's own charter said it is
"never down-tiered", but `inherit` resolves to whatever tier the *calling*
context runs on — so an autonomous drive on a cheap tier down-tiered it
silently. Justified inherit is only sound where the caller is guaranteed to be
the top tier; for a never-down-tier seat it is not, and a declared tier is.
Note the direction of the fix: the seat's *intent* was authoritative and the
mechanism was corrected to match it — the tier moved from caller-dependent to
declared, not from strong to cheap.

These cover the review panels spawned by `/workshop` Step 3.2/3.3/3.5,
`/assess` Step 3, `/triage` Step 3, and `/build` 3e. **All of those panels
inherit their tier from the agent definitions above, not from the command
prose** — which is why `/workshop`, despite being the single largest
non-`/build` spender in the baseline (11.1% of command-attributed spend, seven
review lenses per design walk), has no un-tiered seat. Its cost is lens
*count* and context size, not tier. That is a real finding: the seeded
hypothesis that `/workshop` had "NO tier control of any kind" was wrong, and
the corrected picture routes its cost question to fan-out width rather than to
a tier lever.

### B3. `python-reviewer` / `shell-reviewer` — silent inherit, then justified, now pinned

Both declared `model: inherit` while their five sibling language reviewers
declared `sonnet`, with **no stated reason for the divergence** — the textbook
silent-inherit signature: an inconsistency inside one catalog that nobody had
decided.

**Disposed by writing the justification, with no behavior change.** The
principled basis was already in each file's own description: these two are
**kernel-native** reviewers (shell and Python are the kernel's own
implementation languages — the board adapter, build machinery and install
scripts are `.sh`; the telemetry rollups and transcript parsers that produce
every spend figure are `.py`), while the other five are **adopter-catalog**
entries for languages this repo does not itself ship. A false negative in a
kernel-native reviewer ships a defect into the pipeline itself, and no second
reviewer stands behind it. The justification is now written at both seats.

**Was open, temperloop#1456 → #2179 (closed at the end of this section): is
that justification enough on its own?** It
is the same "no second reviewer stands behind it" argument
`architecture-reviewer` ran on, and there it turned out to argue for a
*declared* tier rather than an inherited one — a caller can be a cheap
autonomous drive, so `inherit` cannot deliver "not down-tiered" (§ B2). These
two were left as-is rather than swept along: unlike `architecture-reviewer`
they are inert catalog entries that run only in an adopter repo that opted in,
so the tier they resolve to depends on that adopter's session rather than on
this repo's pipeline, and re-tiering them is a change to somebody else's spend
that this repo should decide deliberately rather than as a side effect. Worth
noting the asymmetry cuts both ways: an adopter driving them from a cheap
autonomous session gets the same silent down-tier, with even less visibility
into it than the kernel had.

**Update (temperloop#2132) — two corrections to the paragraph above.** First,
the roster changed: `typescript-reviewer` moved from `sonnet` to `model:
inherit`, alongside `workflow-reviewer`, so the catalog is no longer
"kernel-native inherit, adopter-catalog sonnet". The basis for that move is
**not** the kernel-native argument — it is that a §3e HIGH now loops the item
back to 3c rather than reaching a human filter, so those seats' output *is* the
gate, and `/build` 3c § Model tiering (as rewritten by temperloop#2140 — *tier
by measured rounds, not by an assumed gate*) keeps a gate-bearing seat on the
session model unless a **paired measurement** shows a cheaper one costs less
per merged item. No such measurement exists yet; it is parked to
temperloop#2134, and the issue's own caveat stands — seat and surface are
confounded, so this is a lead to measure, not a proven win.

Second, and more consequentially for this section's reasoning: the premise that
these are "**inert** catalog entries that run only in an adopter repo that
opted in" **does not hold in this repo**. `workflows/scripts/config/
reviewer-routing.tsv` routes `.sh`, `**/Makefile` and `**/build-level.mjs` to
`shell-reviewer`, `.py` to `python-reviewer`, and `.ts`/`.js`/`.mjs` to
`typescript-reviewer` — so all three are live §3e seats here, gating the
kernel's own machinery, not dormant files awaiting an adopter. The "somebody
else's spend" framing that justified leaving them as-is was therefore resting
on a factual error about where they run. The open question this section raises
was unchanged and still open at that point — whether a **pin** is owed where
`inherit` only buys parity with the caller — but it needed re-arguing on the
correct premise, and it applies to `shell-reviewer`/`python-reviewer` for the same
reason it now applies to `typescript-reviewer`.

**CLOSED (temperloop#2179) — both seats are pinned to `opus`.** Re-argued on
the corrected premise, the open question above resolves in one direction. The
"somebody else's spend" objection was the only thing holding the pin back, and
it rested on the factual error the update above corrects: these are live §3e
seats in this repo, routed by `workflows/scripts/config/reviewer-routing.tsv`
(`.sh`, `**/Makefile` and `**/build-level.mjs` → `shell-reviewer`; `.py` →
`python-reviewer`), gating this repo's own machinery — `**/build-level.mjs` is
the `/build` engine itself. A seat reviewing the pipeline's own engine is the
least plausible candidate for spend that belongs to someone else.

With that objection gone, what remains is the B2 argument unchanged: `inherit`
buys **parity with the caller**, never a floor, so an autonomous or mechanical
drive on a cheap tier down-tiers the seat silently — and the seat's own charter
already claimed the stronger position ("no second reviewer stands behind it"),
which only a declared tier can deliver. The live evidence is direct rather than
hypothetical: in two consecutive §3e passes `shell-reviewer` ran as
`claude-opus-5[1m]` while `docs-reviewer` ran as `claude-sonnet-5` — strong
only because the driving session happened to be strong. Right by accident; the
pin makes it right by construction.

Note the direction of the fix, exactly as in § B2: the seats' *intent* was
authoritative and the mechanism was corrected to match it — the tier moved from
caller-dependent to declared, not from cheap to strong. `typescript-reviewer`
is deliberately **not** swept along: its `inherit` rests on temperloop#2132's
gate-bearing argument with a paired measurement parked to temperloop#2134, not
on the "no second reviewer" argument these two and `architecture-reviewer`
share. The pin is asserted mechanically by
`workflows/scripts/tests/test_reviewer_seat_tiers.sh` (case 6), so it cannot
drift back silently.

## C. Headless `claude -p` seats under `bin/` — the find

**These are what this item actually discovered.** Three seats outside the batch
pipeline spawned headless sessions **with no `--model` flag at all**, so each
ran on whatever tier the invoking operator's CLI defaults to — the top tier, on
a stranger's very first command. None appeared in any prior enumeration.

All three share a shape that makes them safe to tier: `--tools ""` (structurally
zero tool access, so none can write), an existing `--max-budget-usd` cap, and a
graceful degradation path.

| # | seat | setting | disposition |
|---|---|---|---|
| C1 | `try.sh` Step 3 — SHADOW/DRY-RUN triage classification | `$TRY_TRIAGE_MODEL` | **re-tiered** (measured) — **seat RETIRED** (#1237) |
| C2 | `try.sh --demo` — live judgment call producing a fixed file | `$TRY_DEMO_FIX_MODEL` | justified inherit — **seat RETIRED** (#1237) |
| C3 | `configure.sh` — AI-guided starting-value suggestion | `$CONFIGURE_AI_MODEL` | justified inherit (measured refusal) |

> **Retirement note (temperloop#1237).** C1 and C2 lived in
> `bin/subcommands/try.sh`, which was deleted when `try` / `try --demo` were
> retired in favour of `temperloop testbed`; their `$TRY_TRIAGE_MODEL` and
> `$TRY_DEMO_FIX_MODEL` settings went with them. **C3 (`configure.sh`) is the
> only seat in this table that still exists.** The measurements below are kept
> as the record of how the tiering call was made — they are history, not a
> description of current behaviour.

**C1 — re-tiered.** Its output is free-form text the script prints *verbatim*:
no JSON contract to violate, no downstream parse a weaker model can fail, so it
has no repair path to price. It is an explicitly labelled zero-write dry run,
and it lands on a stranger's own first-run bill. Measured before/after below.

**C2 — inherit, not re-tiered.** Its output is a file's full corrected content
that the script then applies, commits, and pushes to a real PR. Committed code
that no mechanical gate checks before it reaches a human's repo is exactly
rule 3's "output is the gate" case.

**C3 — inherit, and the refusal is measured, not cautious.** See below.

## D. Scanned, confirmed not a model fan-out site

Recorded so the next sweep does not re-derive them:

- `workflows/scripts/probe/gh-bench.sh` — the only bench harness in the repo;
  zero `claude`/model references. A `gh`/REST latency probe, not a model seat.
- `claude/hooks/session-end-log.sh` — its `model` references *parse* a
  transcript's `.message.model`; it spawns nothing.
- `claude/commands/tidy.md` — no subagent spawn. Its `source_model` /
  `extracted_by_model` references are vault provenance fields.
- `claude/hooks/README.md` — documents how an *adopter's* eval runner launches
  a headless session. Adopter-facing instruction, no kernel-side seat.
- **cron / launchd** — this repo ships no `*.plist` and no nightly-`/tidy`
  installer. The nightly `claude -p "/tidy"` invocation and its tier are
  **overlay-owned** (foundation#1089), out of kernel scope by construction.

## E. Known gap — one bare model literal in prose

`claude/commands/build.md` 3c § Seat tiers routes Explore-style
locate-and-report fan-outs by writing the tier **inline as a literal** rather
than naming a setting, because the built-in Explore agent has no definition file
in this repo to carry frontmatter. It is a *decided* tier — not a silent
inherit — but it is stated as a value in prose, which the Named-setting
convention forbids.

**Left in place deliberately, and named here rather than fixed**, because the
fix belongs with the four-known-sites lever work (temperloop#972 / the deferred
default flip, temperloop#971) rather than with this inventory: it is a `/build`
seat, and editing `build.md` widens this change well past an inventory. Its
disposition is **explicit-but-unnamed**; the remedy is one setting whose default
lives in `build.config.sh` like every other. Recorded as a live gap so it is not
rediscovered as a finding.

No **new** bare model literal is introduced anywhere by this change.

## Measurement

### The instrument, and its gap

The pre-registered denominator is the token-spend baseline note (2026-08-02),
and the shipped instrument is the `.temperloop/report.d/tokens` producer.
Weighted units throughout are that note's `WEIGHTS_V1`:

```
units = input×1 + cache_creation×1.25 + cache_read×0.1 + output×5
```

**The instrument does not reach the seats measured here, and this is stated
rather than worked around.** All three § C seats pass
`--no-session-persistence`, so they write **no transcript**. The tokens
producer reads transcripts. Therefore:

- No spend from C1/C2/C3 has *ever* appeared in the corpus behind the baseline
  note. Their contribution to its § A command-attribution table is **zero — not
  small, structurally absent.**
- A before/after for these seats could not be obtained by reading the producer.
  Doing so would have reported "no change" for the trivial reason that it
  reports nothing at all for these seats.

**Update (temperloop#1264 — envelope capture):** all three seats now run
with `--output-format json` instead of `text`, so the transcript-corpus
absence above still holds unchanged — `--no-session-persistence` is
untouched, no transcript is written, and the tokens producer's contribution
for these three seats stays **zero, structurally**. What changes is that
each live call's own `usage` / `modelUsage` / `total_cost_usd` /
`duration_ms` block is now captured into a named shell variable at the call
site (`triage_envelope` in `try.sh`'s C1, `fix_envelope` in its C2,
`ai_envelope` in `configure.sh`'s C3), in scope for a future attribution
emit. These seats are therefore no longer invisible to **both** measurement
paths at once — they remain invisible to the transcript/tokens-producer
path, but are now **envelope-capable**: the direct per-call measurement
the "Method actually used" below already relies on is no longer a one-off
replay technique, it is what every real call already returns.

**Method actually used** — a direct per-call measurement, at the same weight
vector so the numbers are comparable to the baseline even though they are not
*in* it: each seat's real production prompt was replayed through
`claude -p --tools "" --output-format json --no-session-persistence`, and the
returned `modelUsage` block was weighted with `WEIGHTS_V1`. This measures the
same quantity the producer would, at the one place the producer cannot see.

Every figure below is an observed measurement. Sample sizes are small and are
stated inline; none is extrapolated.

### C1 — `try.sh` shadow triage: the re-tier (seat since retired)

Prompt: the script's real Step-3 shadow-triage prompt over a 5-issue sample.

| tier | weighted units | dollars/call | output tokens | valid report? |
|---|---|---|---|---|
| inherit (top tier), n=1 | 58,669 | $0.4281 | 1,912 | yes |
| cheap tier, n=2 | 58,383 / 48,109 (mean 53,246) | $0.0783 / $0.0680 | 4,375 / 2,320 | yes, 2/2 |

**Whole-job verdict: re-tier.** Correct, correctly-prefixed SHADOW/DRY-RUN
report at the cheap tier on 2 of 2 runs, with **no repair path invoked** —
nothing parses this output, so there is no failure mode for a weaker model to
trigger. Cost: **~5.5x cheaper per call in dollars**, and **within noise on
weighted units** (−9% on a mean of two, against a spread wider than the delta).

**The units result is the interesting one, and it is why rule 2 exists.** The
cheap tier is *far* cheaper per token but materially chattier — 4,375 vs 1,912
output tokens on the same prompt — and output carries weight **5**. Verbosity
almost exactly cancels the per-token saving. Anyone pricing this re-tier on
provider list price alone would have booked a 5.5x win that the baseline's own
unit vector does not show.

The re-tier is justified on the **dollar** axis, which is the load-bearing one
for this seat specifically: a budget-capped first-run demo billed to a
stranger's own account. It is explicitly *not* claimed as a weighted-units win.
Reversible by setting `$TRY_TRIAGE_MODEL` empty.

### C3 — `configure.sh` AI-guided suggestions: the refusal

Prompt: the script's real suggestion prompt over its four curated settings.

| tier | weighted units | dollars/call | output parses? |
|---|---|---|---|
| inherit (top tier), n=1 | 98,177 | $0.7810 | yes — bare JSON |
| mid tier, n=1 | 101,366 | $0.4838 | yes — bare JSON |
| cheap tier, n=4 | 40,572 / 40,522 / 57,606 / 77,321 | ~$0.06–0.12 | **no — fenced, 4/4** |

The seat's whole job is to emit a single bare JSON object that the script parses
with `jq`. At the cheap tier the model wrapped that object in a fenced markdown
code block on **4 of 4 runs**, despite the prompt explicitly forbidding fences.
Verified directly: `jq` exits **5** on the fenced form, so
`jq -r '.[$k].value // empty'` yields empty for **every** setting, and all four
fall through to the plain-prompt fallback.

**Whole-job verdict: do not re-tier — this is the inversion the rule names.**
The cheap tier is ~2.4x cheaper per seat and delivers **0% of the job**. Its
whole-job cost is its own spend *plus* the entire fallback, which is strictly
worse than paying once for a pass that completes. Per-seat accounting would have
scored it a 2.4x win.

A secondary finding worth recording: the **mid tier cost slightly more in
weighted units than the top tier** (101,366 vs 98,177) while costing less in
dollars. Same mechanism as C1 — more output tokens at weight 5. There is no
weighted-units saving available at this seat at any tier that completes the job.

### What this measurement does and does not license

- It prices **three seats**, at n=1–4 each. It is not a corpus-wide claim.
- It says nothing about the § A pipeline seats, whose spend *is* in the corpus
  and whose default flip remains temperloop#971's, gated on its own measurement.
- Both § C refusals (C2, C3) and the single re-tier (C1) are one-line config
  edits in `build.config.sh`. Nothing here is hard to reverse.

## Adding a new model-spawning site

1. Give it a tier setting whose default lives **only** in
   `workflows/scripts/build/build.config.sh`; reference it symbolically
   (`$SETTING_NAME`) everywhere else. Register it in
   `workflows/scripts/config/setting-registry.tsv`.
2. Or, if it inherits, **write the reason at the seat.** An undocumented
   `inherit` is a silent inherit, and the next sweep will correctly flag it
   (§ B3 is exactly this case). One reason is never sufficient on its own:
   *"this seat must never be down-tiered."* `inherit` delegates the tier to
   the caller, and a caller can be a cheap autonomous drive — so a
   never-down-tier seat needs a **declared** tier, not a justified inherit
   (§ B2, temperloop#1456). Justified inherit is for seats that genuinely
   want to track whatever the caller is running.
3. If you propose a cheaper tier, price the **whole job including repairs** —
   and measure both axes, because dollars and weighted units can disagree by
   5x (§ Measurement).
4. If the seat passes `--no-session-persistence`, note that it is invisible to
   the tokens producer — but run it with `--output-format json` and unwrap
   `.result` (never `.result.<field>` directly; `.result` is a JSON
   **string**, so a parsed field needs `.result | fromjson | .field`, done
   in the SAME `jq` call — round-tripping an already-`-r`-decoded value
   through a second `jq`/`fromjson` call re-parses it as an object first
   and silently yields empty) so the call's own `usage` / `modelUsage` /
   `total_cost_usd` / `duration_ms` block is captured for free. That is now
   the standard remedy (see C3 in `configure.sh`,
   temperloop#1264), not a one-off direct measurement — reach for a
   one-off replay only if the seat cannot be moved to `--output-format
   json` at all.
