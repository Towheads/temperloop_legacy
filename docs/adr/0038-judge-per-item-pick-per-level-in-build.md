---
title: "0038: The dual-build harness judges every item but picks a winner per level"
---

## Status

Proposed

## Context

epic: Towheads/temperloop#2065 — the new-work dual-build harness (design
brief: `Designs/temperloop - new-work dual-build harness.md`) lets `/build`
build each in-scope plan item with two models (a baseline and a candidate
under test) and decide, per level, which arm's work ships. The open question
this ADR resolves is the **unit of the pick**: does the harness decide a
winner per item, or per level?

A naive per-item pick is what the brief's operator first proposed (D2): the
better branch wins for each item independently, and `main` accumulates
whichever arm won each item's judged comparison. The operator then raised a
concern mid-design (round 4): building a level as a mix of two models risks a
quality drop from model-inconsistency within a single level's work, distinct
from either model's individual quality. That reopened the pick unit (D11):
the harness still **judges** every item pairwise (so per-item signal for the
report survives), but the arm that **ships** is chosen once per level, by
tallying item wins across the level's in-scope items.

This is a real architectural fork in `/build`'s control flow, not a policy
knob: today `driveItem` interleaves build → gate → PR per item, one item at a
time. A level-scoped pick requires every in-scope item's build, local gate,
and judge result to be known *before* any PR opens for the level — a phase
split the brief calls the **level barrier** (dimension 4 #1, dimension 5 step
3a).

## Decision

Pick unit is **the level**, not the item. Both arms build, locally gate, and
get pairwise-judged on **every** in-scope item in the level (so per-item
signal is never lost); the arm with more item wins is the level's winner (a
gate failure counts as a loss for that arm on that item; a judged tie —
positions disagree — counts for neither arm and is recorded `unresolved`; a
level-wins tie goes to the cheaper arm by whole-job cost). Only the winning
arm's branches proceed through `/build`'s existing PR → CI → merge gate for
every item in the level; the losing arm's patches are archived (ADR-adjacent
to D7) and its branches deleted once the archive is confirmed readable.

This requires a **level barrier**: `driveItem` is phase-split so that build +
local gate + judge complete for every in-scope arm before any PR opens for
the level. `main` therefore stays single-arm-authored per level — no level
ships a mix of two models' code — while the per-item build and judgment
(the harness's actual measurement unit) is unchanged and still recorded row
by row.

Two operator levers sit on `build-level.mjs`'s existing escalation →
verdict → continuation seam (a level re-drive carrying `input.verdicts`),
deliberately not a new mid-workflow prompt:

1. **Override.** The operator may route an arm the tally did not pick, with a
   recorded reason. It has two scopes, and the shipped verdict grammar names
   both: `override-level <arm>` routes that arm for every item in the level
   (the level stays single-arm-authored, so the pick's own invariant holds);
   `override-item <slug> <arm> "<reason>"` routes it for the named items only,
   which marks the level `mixed` and stamps `override: item` on each named
   item's row.
2. **Mandatory no-default confirmation while uncalibrated.** While the
   judge's calibration status reads `NEVER CALIBRATED` (or the calibration
   bar is unmet — see the harness's companion calibration ADR), every level
   pick requires an explicit operator confirmation before proceeding to
   PR — there is no default that lets it proceed on the tally alone. Once
   the bar is met, this reverts to the optional override above.

So the shipped grammar is a closed set of **three** verdicts — `confirm`,
`override-level`, `override-item` — which is lever 2 plus lever 1's two
scopes, not a third lever. `override-level` is named explicitly here because
it was implicit in "the operator may merge the losing arm's branch" when this
ADR was first drafted (temperloop#2083), and a design-of-record that names
only the per-item scope reads as if the level-wide one were out of contract.

An item on which the winning arm has no gate-passing branch is re-driven once
on the winner's own model; if still none, the item parks with an
`incomplete` row rather than silently borrowing the losing arm's branch.

**Rejected alternatives:**

- **Per-item pick (D4's original shape).** Rejected because it lets `main`
  accumulate a mixed-model level — exactly the quality-drift risk the
  operator raised. A level built from two different models' independent
  picks has no single authorial voice to reason about when something breaks.
- **Per-level judging (one judged comparison for the whole level's diff).**
  Rejected because N — the sample size the report's statistics depend on —
  collapses from one row per item to one row per level; a solo repo's
  5–15-items-per-epic already sits below any significance floor (R3), and
  judging at the level would shrink that further before any verdict could be
  trusted.
- **Randomized single-build assignment** (flip a coin per item, build once
  with the assigned model, compare across items rather than within them).
  Rejected on dimension 0's premise gate: this is a between-items design, so
  it answers "did items built with model X tend to score higher than items
  built with model Y" but never produces a per-item head-to-head signal —
  exactly the prospective, item-level comparison the premise (D1) requires.

## Consequences

**Benefits.** `main` never carries a level authored by a model mix nobody
chose, closing the drift risk that reopened D4 in round 4. The report still
gets full per-item signal (every item is judged, win/loss/tie recorded) so
the eventual win-rate statistic (D9) isn't starved by the level-level pick.
The two operator levers are both cheap: they reuse an existing seam rather
than adding new interactive machinery, and the no-default confirmation gate
means a candidate model can never ship unattended on an unproven judge.

**Costs.** The level barrier is a genuine restructure of `driveItem`'s
control flow, not a bolt-on: single-arm `/build` interleaves build → gate →
PR per item today, and dual-build cannot, because the level pick needs every
item's judged result first. That coupling has to be preserved by any future
change to `driveItem`'s control flow, or dual-build silently regresses to
racing PRs open before every arm is judged (see the harness's maintainability
dimension, § 7 of the brief). A flag-less `/build` resume over a level left
partially dual-built (the barrier interrupted mid-level) must refuse legibly
rather than silently completing single-arm or picking a side — that refusal
path is part of what this epic builds, not a pre-existing behavior it can
assume.

**Follow-on work.** The per-item override and the mandatory-confirmation
lever both live on the existing escalation/continuation seam; if either
proves too coarse in practice (e.g. an operator wanting to override more than
one item per level without re-litigating the whole pick), a richer
per-item-override UX is a natural extension of #2065, tracked against the
epic rather than reopened here.
