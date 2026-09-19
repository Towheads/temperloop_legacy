---
title: "0041: The dual-build judge's verdict is withheld until blind-pair calibration clears a bar"
---

## Status

Accepted

## Context

epic: Towheads/temperloop#2065 — the new-work dual-build harness (design
brief: `Designs/temperloop - new-work dual-build harness.md`) picks a level's
winning arm using a new pairwise judge (D6): one prompt carrying the issue,
acceptance criteria, and both diffs, run twice with the diffs in swapped
positions, and a preference read from where the two runs agree. That judge
is, per the brief's dimension 15, "the whole quality signal for new work,"
and it has never been checked against a human preference (R1). K#2060
(Backlog) will eventually calibrate the harness's *absolute* rubric scores,
but it specifies neither a pairwise-preference metric nor a pass bar, and it
has not landed — so a pairwise judge deciding which model's code ships
cannot simply defer to it.

Two candidate sources of human-preference data exist for calibrating this
specific judge: **operator overrides** (an operator disagreeing with the
judge's pick, already captured as part of D5's override path) and a
dedicated **blind sampling mode** where a human states a preference without
seeing the judge's own verdict first. These are not equivalent as evidence:
an override is a disagreement *by construction* (the operator only overrides
when they disagree), so a corpus built solely from overrides would measure
100% disagreement no matter how good the judge actually is — it is
selection-biased toward exactly the cases where the judge and the human
diverge, and useless as an unbiased agreement estimate.

## Decision

A new `calibrate` mode presents sampled item pairs **blind** — both diffs
shown, the judge's own preference and margin withheld — and records a human
preference, agreement and disagreement alike, for a config-named count of
pairs per level (tunable per repo, not a fixed literal). **Override-derived
pairs are recorded** (item, both diffs, judge preference + margin, human
preference + reason) in the same shape K#2060 will eventually consume, **but
are excluded from the agreement statistic** — they are disagreements by
construction and would bias any bar computed from them.

The bar: the report may name a winning arm only once judge–human pairwise
agreement, measured from blind `calibrate`-mode pairs alone, is **≥70% over
≥20 pairs**. Below that bar — including the starting state, `NEVER
CALIBRATED` — every report renders the calibration status explicitly and the
verdict line reads "judge uncalibrated — verdict withheld," while the ledger
keeps accumulating rows regardless. Unresolved rows (a judged tie where
positions disagree, an unjudged item, or an infra failure) are excluded from
both the win-rate numerator and denominator and are instead counted and
reported in the report's honesty block — a judge outage or a genuine tie is
never silently folded into either arm's win count.

This epic — not K#2060 — produces the pairwise labels the 70%/≥20-pairs bar
is judged against. K#2060 calibrates absolute rubric scores against a
different, single-diff evaluation shape; the two calibration efforts are
related (both feed the same eventual trust question) but distinct in what
they measure and neither substitutes for the other.

While the judge remains uncalibrated (or the bar is otherwise unmet), a
second, independent teeth applies at the pick level (see the harness's
companion level-pick ADR): every level pick requires an explicit,
no-default operator confirmation before proceeding to PR, so an uncalibrated
judge's pick can influence what ships only with a human's active sign-off in
the loop — never unattended.

## Consequences

**Benefits.** The calibration statistic cannot be gamed by an operator's own
override history — a repo cannot back into a passing agreement rate just by
accumulating overrides, since only blind pairs count. The report is honest
by construction about the state the harness is actually in: "judge
uncalibrated — verdict withheld" and "below floor — keep accumulating"
(R3's significance-floor case) are first-class, expected outputs rather than
error states, and a reader is never shown a confident-sounding pick the
evidence doesn't support.

**Costs.** A solo repo produces 5–15 dual-built items per epic (R3), so
reaching even the 20-pair blind-calibration minimum — separate from and in
addition to clearing the significance floor for the win-rate statistic
itself — takes deliberate, repeated `calibrate`-mode runs across **several
epics** before any verdict can be named at all. This is a slow start by
design, not an oversight: the alternative (counting overrides, or lowering
the bar) would produce an earlier but untrustworthy number, which is exactly
the anecdote-over-telemetry failure mode this design (and kernel principle
10) exists to avoid.

**Follow-on work.** If R1's kill condition is triggered — calibration
agreement measured from blind pairs stays below the bar even after
substantial data — the design's own fallback is to treat the pick rule as
"judge advisory only" and fall back to human pick, recorded explicitly in
the ledger rather than silently continuing to trust an unproven judge. The
relationship between this epic's pairwise-agreement bar and K#2060's
eventual absolute-score calibration should be revisited once K#2060 lands,
in case the two calibration efforts turn out to share more infrastructure
(e.g. a common human-labelling UI) than the current design anticipates.
