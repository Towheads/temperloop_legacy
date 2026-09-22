---
title: "0021: toolkit provenance is derived from git, never declared as stored state"
---

## Status

Accepted

## Context

epic: Towheads/temperloop#1047

The toolkit reaches an operator's machine by one of two paths: vendored into a
consuming repository as a git subtree pinned to a release tag, or cloned by the
CLI's bootstrap into a managed checkout sitting at a release tag. On both paths
the live machine surface resolves, through symlinks, into that tree — so editing
the tree changes the toolkit's behaviour in the next session, immediately.

Editing a vendored tree is discouraged but not prevented: the guard that
intercepts it asks rather than denies, fails open, and self-bypasses under an
acknowledgment environment variable, and the downstream drift check enforces a
waiver at merge time rather than a block. On the managed-clone path there is no
guard at all. The result is a state that is reachable, sometimes legitimate, and
entirely unreported: nothing tells an operator whether the code running right now
is a released version or their own modification.

Reporting that state requires knowing what "released" means for this checkout.
The obvious approach is to record it — write a marker when a fast-lane session
begins, or add a field to the pin file that names the expected content. Every
such approach introduces state that can disagree with reality.

## Decision

The provenance verdict is **derived** at read time from information git already
holds, and **no new state is persisted anywhere** — no marker file, no mode flag,
no channel record, no added field in the pin file.

This has three consequences the design depends on. There is nothing that can go
stale, because there is nothing stored to disagree with the tree. There is
nothing to remove at uninstall, so the feature's removal is a pure deletion.
And the verdict cannot be wrong because someone forgot to declare something —
an operator who edits the tree without announcing it is reported exactly the
same as one who announces it.

The pin file is read-only to this mechanism. Its format is a versioned contract
surface, and — more sharply — its mere *presence* is already load-bearing as the
signal that a checkout is a vendoring consumer, which class-gates the kernel's
self-distribution test suite. Writing to it, or giving the kernel's own checkout
one, would mis-classify that entire suite at once.

## Consequences

The mechanism can only report what git can see. Modifications outside the
vendored prefix or the managed clone are invisible to it, which means an
adopter's edits to their own repository and overlay are out of scope by
construction. This is a real capability limit and is stated rather than
papered over.

Deriving rather than declaring also means the verdict costs work at every read.
The probe therefore runs on paths where latency is visible to the operator —
session start, and the moment the edit guard fires — so its cost must stay small
and it must fail open rather than block, degrading to an explicit "unknown"
verdict whenever it cannot answer.

Because nothing is stored, the mechanism cannot report history: it answers "is
this modified now", never "how long has it been". Bounding how long an
unreconciled modification persists is left to a periodic drain step that reads
the derived verdict, not to a stored timestamp.
