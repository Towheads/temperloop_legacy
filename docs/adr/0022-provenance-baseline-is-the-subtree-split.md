---
title: "0022: the provenance baseline is the recorded-vs-recomputed subtree split, not the pin commit"
---

## Status

Accepted

## Context

epic: Towheads/temperloop#1047

Deriving a provenance verdict for a vendoring consumer (ADR 0021) requires a
baseline: the content the vendored tree is supposed to hold. The pin file records
the upstream release tag and the commit sha that tag resolved to at pull time —
but that sha names a commit in the *kernel* repository, which a consuming repo's
history does not necessarily contain. Comparing against it directly would require
a network fetch, which is unacceptable on a path that runs at every session start.

The apparently obvious local substitute is to use the consuming repo's own
pin-setting commit as the baseline: find the commit that most recently touched
the pin file, and diff the vendored prefix from there to `HEAD`. That reasoning
assumes the pin write and the subtree pull land together.

They do not. The update tool makes two commits — the subtree pull first, then a
separate commit touching only the pin file — and skips the second entirely on an
idempotent re-run at the current tag.

That gap is not academic. It was reproduced in a sandbox, using the workflow this
feature exists to support: hand-edit a file in the vendored tree and commit it;
later run the update tool for a newer release; the subtree merge preserves the
non-conflicting edit, and the pin commit lands *after* it. The baseline advances
past the modification, the diff comes back empty, and the probe reports the tree
as released while the edit is still present.

A probe that reports "released" for a modified tree is worse than no probe. It
re-creates exactly the invisibility the feature exists to remove, while asserting
that it has been removed.

## Decision

The baseline is the **subtree split sha**, compared recorded against recomputed.

A squashing subtree pull records the upstream content sha in the merge commit it
creates. The same content sha can be recomputed locally from the current tree at
any time. Comparing the recorded value against the recomputed one answers the
question exactly: identical means the tree holds the pulled content, differing
means it does not, and an unrecoverable record means the answer is unknown.

The pin-commit proxy is rejected outright. Besides the reproduced failure above,
it fails two further ways: the pin commit is skipped on idempotent re-runs, and
any commit touching the pin file for an unrelated reason silently advances the
baseline past existing drift — including, perversely, a commit adding a comment
to the pin file to document this very coupling.

This satisfies the three constraints that made the proxy tempting. It is local,
requiring no network. It requires no change to the pin file's format. And unlike
the proxy it is exact rather than heuristic.

## Consequences

The mechanism now depends on the update tool's use of a squashing subtree pull
and on the marker such a pull records. That coupling is real and must move
together; it is documented in the update tool's own generating block rather than
hand-written into the pin file, because that file's header is regenerated
wholesale on every update and a hand-added note there would not survive.

The managed-clone path needs its own baseline, since it has no subtree at all.
It resolves the nearest reachable release tag rather than requiring the checkout
to sit exactly at one — an adopter who commits a modification is no longer
exactly at the tag, and that is precisely the state most worth reporting.

Both paths inherit one governing polarity: when the baseline cannot be
established, the verdict is unknown, never released. Failing toward "I cannot
tell" keeps a future defect in this resolution a bug rather than a silent
misreport, which is what made the rejected proxy dangerous rather than merely
wrong.
