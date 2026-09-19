---
title: "0040: Dual-build authorship is disclosed via a new trailer line, not a widened Model-provenance"
---

## Status

Accepted

## Context

epic: Towheads/temperloop#2065 — the new-work dual-build harness (design
brief: `Designs/temperloop - new-work dual-build harness.md`) must disclose,
on every winning PR, which two models built the level and which one won —
the same disclosure obligation live-tagging already enforces for a
single-model PR via the `Model-provenance:` trailer.

`workflows/scripts/model-comparison/tagging.sh:459` parses that existing
trailer with a strict single-model regex:

```
^Model-provenance: model=[^[:space:]]+ provider=[^[:space:]]+ run=[^[:space:]]+$
```

Reshaping this line in place to carry two models and a pick would be a
**breaking** change under `VERSIONING.md`'s contract-surface bump rules:
every existing consumer of the trailer — most concretely `tagging.sh`'s own
disclosure-log check — parses today's single-model shape and would need to
be rewritten to understand a two-model line, and any other tool that has
learned to expect exactly one `model=`/`provider=`/`run=` triple would break
silently on a dual-build PR.

## Decision

Winning PRs from a dual-built level carry a **second, new, additive trailer
line**, `Model-comparison-arms:` — naming both arms' models, which one won,
and a one-line pick reason (gate-pass + judge preference/margin, or the
override reason if an operator overrode the pick) — written **alongside** an
entirely **unchanged** `Model-provenance:` line for whichever arm's work was
checked in. The existing single-model disclosure path is untouched: a reader
that has never heard of dual-build still sees a valid, single-model
`Model-provenance:` line and its existing disclosure check still passes
unmodified.

This is **always-on**, never a per-repo opt-in. The design considered and
rejected making the trailer conditional on a repo's own disclosure
preferences: disclosure of which models authored merged code is the entire
point of the mechanism, mirroring why `Model-provenance:` itself is not
optional under live-tagging today. A repo that cannot or will not disclose
which models wrote its code is not a repo that should run dual-build in the
first place — the flag and the trailer travel together, not separably.

**Merged-PR trailers are accepted residue on uninstall.** Removing the
dual-build feature (deleting the flag's code path, purging the ledger
folder, dropping the setting-registry rows) does not retroactively scrub
`Model-comparison-arms:` lines from PRs merged while the feature was live —
exactly as an uninstalled feature never rewrites history to remove its own
`Model-provenance:` lines. A merged PR's trailer is as permanent a record as
any other trailer already accepted into a repo's git history.

**Enforcement mechanic.** If the trailer write itself fails, the PR is
**not merged** until the `Model-comparison-arms:` line lands — merging
without it would silently reopen the exact undisclosed-authorship hole
`tagging.sh`'s existing check exists to catch, just for the second arm
instead of the first.

## Consequences

**Benefits.** No existing consumer of `Model-provenance:` — including
`tagging.sh`'s own disclosure-log check — needs to change to keep working
correctly on a dual-build PR; the additive trailer is invisible to anything
that doesn't know to look for it, and visible (parseable) to anything that
does. The always-on rule closes off a foreseeable failure mode (a repo
quietly opting out of disclosure while still running dual-build) before it
can exist, rather than needing a later enforcement pass to catch it.

**Costs.** A reader of a dual-built PR who wants the full authorship picture
now has to know to look for two trailer lines instead of one — the
information is disclosed, but not unified into a single line a naive grep
for `Model-provenance:` would fully capture. This is treated as an
acceptable cost because a grep for `Model-provenance:` alone still returns a
true (if partial) statement — which arm's code is checked in — rather than a
false one.

**Follow-on work.** If a future design wants a single unified trailer that
carries both single- and dual-build provenance in one line, that would
require a genuinely breaking change to the `Model-provenance:` format and a
migration of every existing consumer — out of scope for this epic, and not
motivated by anything this design currently needs. `VERSIONING.md`'s
contract-surface table should be checked at that point, since this decision
already treats the trailer format as belonging in that table's discipline
even though it is not itself a named row there today.
