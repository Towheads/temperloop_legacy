---
title: Toolkit provenance
slug: toolkit-provenance
---

## Problem

The toolkit reaches a machine one of two ways: vendored into a consuming
repository as a git subtree pinned to a release tag, or cloned by the CLI's
bootstrap into a managed checkout sitting at a release tag. On both paths the
live machine surface — the symlinks under `~/.claude/` — resolves into that
working tree. Editing the tree changes the toolkit's behaviour in the next
session, immediately.

That path is reachable and sometimes legitimate. The guard that intercepts an
edit into a vendored tree *asks* rather than denies, fails open, and
self-bypasses under an acknowledgment environment variable; the downstream
drift check enforces a waiver at merge time rather than blocking. On the
managed-clone path there is no guard at all. What was missing is not a
prohibition — it is a **readout**: nothing on the machine reported whether the
code running right now was a released version or somebody's local
modification.

Two consequences made that gap worth closing rather than tolerating.

**A modification travels further than the person who made it.** The managed
clone is shared across every project an adopter touches, by default. One edit
is live for every engagement until it is restored, and nothing says so. In a
vendoring repository the same edit reaches every collaborator through an
ordinary `git pull` — so the person running modified code is frequently not
the person who modified it.

**The workflow this supports is deliberate, not accidental.** Editing the live
tree to watch a toolkit change take effect immediately — live troubleshooting,
convergence work — is the fast path, and it is the *right* path for learning
from a running system. What made it furtive rather than deliberate was that it
left no trace anybody could see. Making the state visible and attributable is
what lets it be used on purpose.

## How it works

The verdict is **derived from git at read time**, and nothing is persisted
anywhere — no marker file, no mode flag, no channel record, no added field in
the pin file ([ADR 0021](../adr/0021-toolkit-provenance-is-derived-not-declared.md)).
There is nothing that can go stale, nothing to remove at uninstall, and no way
for the verdict to be wrong because somebody forgot to declare something.

One vocabulary, three verdicts:

| Verdict | Meaning |
|---|---|
| `RELEASED` | The toolkit tree is byte-identical to the release it claims. |
| `MODIFIED` | It is not — and every differing path is named. |
| `UNKNOWN` | The baseline could not be established. Always carries a reason. |

**The governing polarity: an unresolvable baseline is `UNKNOWN`, never
`RELEASED`.** A probe that reports "released" for a modified tree is worse
than no probe — it re-creates the invisibility it exists to remove while
asserting it has been removed. Every failure path lands on `UNKNOWN`.

### The baseline, per backend

**A vendoring consumer** (repo-root `.kernel-pin` plus a `kernel/` subtree)
claims the release named on the pin file's `tag` line. Its baseline is the
**subtree split, recorded against recomputed**
([ADR 0022](../adr/0022-provenance-baseline-is-the-subtree-split.md)): a
squashing `git subtree pull --squash` synthesises a commit carrying
`git-subtree-dir:` / `git-subtree-split:` in its message, whose own tree *is*
the pulled subtree content. That commit stays reachable from `HEAD` forever, so
its tree is a durable, local, network-free record of what was pulled. The
recomputed side is the current tree.

The obvious cheaper substitute — "diff the vendored prefix from the commit that
last touched the pin file" — is rejected outright, because it is *wrong* rather
than merely coarse. The update tool makes two commits (the subtree pull, then a
separate pin commit) and skips the second entirely on an idempotent re-run. So
a hand edit committed *before* a later update is silently jumped over: the
baseline advances past the modification, the diff comes back empty, and the
probe reports a modified tree as released. `test_toolkit_provenance.sh` case 1
reproduces that exact sequence, and asserts in the same case that the rejected
heuristic *does* return an empty diff on the fixture — so the test fails if it
ever stops discriminating.

**A managed clone** (`$TEMPERLOOP_HOME`) has no subtree, so its baseline is the
**nearest reachable release tag**, not exact tag detachment. An adopter who
commits a modification is no longer sitting exactly at the tag — and that is
precisely the state most worth reporting.

**Anything else** — most importantly the kernel's own development checkout —
has no release baseline and reports `UNKNOWN` naming that. Giving the kernel
checkout a `.kernel-pin` to make it comparable would mis-classify the whole
self-distribution test suite at once, since that file's *presence* is the
signal that gates it.

### Attribution

A bare file count is not actionable for someone who inherited a change via a
pull. So `MODIFIED` splits two ways:

- **Uncommitted drift** — the running operator's, right now.
- **Committed drift** — a shared git-history fact, reported with the commit,
  its author, and any `Upstream: <kernel-PR-url>` reference in its body (the
  same waiver the merge-time drift check enforces).

### Where the verdict surfaces

- **`temperloop doctor`** — the health check's `check_toolkit_provenance`
  step. `RELEASED` passes quietly; `MODIFIED` is a `WARN` with the full
  attribution block inlined; `UNKNOWN` is a `SKIPPED` with its reason. It is
  **non-fatal** and never touches doctor's exit code — a modified checkout may
  be exactly what the operator intended.
- **Session start** — `claude/hooks/session-start-provenance.sh` contributes
  an unprompted context block **only** on `MODIFIED`. Silent on `RELEASED` and
  on `UNKNOWN`.
- **The moment drift begins** — `claude/hooks/subtree-edit-guard.sh` re-probes
  on its own fire and folds the verdict into its prompt. This half is not
  redundant with the one above: a session-start check is structurally blind to
  an edit made at minute 20 of the same session, which is the motivating
  workflow.
- **A periodic drain step** — `/tidy` § Toolkit provenance runs the probe's
  `--format entry` mode and appends to the pipeline's pending-decisions
  surface on `MODIFIED`, so a long-lived modified checkout on a host nobody
  starts sessions on does not stay invisible.

### The sanctioned parts of the workflow

Two existing seams are named here as supported rather than tolerated:

- **`KERNEL_EDIT_ACK=1`** — acknowledge up front that you are editing the
  vendored tree, and the edit guard stops asking for this session. It still
  logs, and the provenance verdict is unaffected: acknowledging an edit does
  not make the tree released.
- **`Upstream: <kernel-PR-url>`** — a bare line in the PR body waiving the
  merge-time drift check for a change already landed upstream. The probe
  surfaces it on the committed-drift report, so a waived change reads as
  reconciled-in-flight rather than anonymous.

Neither makes a modified tree released. They make the modification *declared*;
provenance reports what is *true*.

### Capability limit

This can only report what git can see inside the vendored prefix or the
managed clone. An adopter's edits to their own repository, or to their private
overlay, are out of scope by construction. And because nothing is stored, the
mechanism answers "is this modified now" — never "how long has it been". The
drain step above is what bounds how long an unreconciled modification persists.

## Integration

`workflows/scripts/toolkit-provenance.sh` is the single implementation; every
surface above calls it and none reimplements it.

```sh
workflows/scripts/toolkit-provenance.sh                    # human report
workflows/scripts/toolkit-provenance.sh --format verdict   # RELEASED|MODIFIED|UNKNOWN
workflows/scripts/toolkit-provenance.sh --format entry     # drain block, or nothing
workflows/scripts/toolkit-provenance.sh --root <dir>       # probe another tree
temperloop doctor                                          # the health check
```

The subject it probes by default is **the tree the script itself lives in**,
resolved through symlinks — the toolkit that is actually running — not `$PWD`.
That is what makes the shared-managed-clone case work: a session started in a
second, unrelated project still resolves into the same toolkit and still gets
the verdict.

**Coupling to declare.** The vendored backend depends on `update-kernel.sh`
using a *squashing* subtree pull and on the marker such a pull records. That
coupling is real and must move together; it is documented in the probe's own
header and in ADR 0022 rather than in `.kernel-pin`, whose header is
regenerated wholesale on every update and would not carry a hand-added note.

**Uninstall / removal.** Nothing to do. The feature persists no state, so its
removal is a pure deletion of the script, the check, the hook and the drain
step — there is no residue attributable to it on any machine, by construction
(ADR 0021).

## Resource impact

A handful of local git plumbing calls — `rev-list`, `rev-parse`, `diff
--name-only`, `status --porcelain`, plus one `log` per drifted path (capped at
three commits each). No network, no GitHub API, no GraphQL, and therefore no
share of the API budget.

**Measured**, on a faithful fixture of the real shape (a vendoring consumer
built with a real squashing `git subtree add`, its content reached through a
machine-surface symlink), five consecutive runs: **72–76 ms per probe**, median
75 ms. That is the whole cost added to the two latency-visible paths — session
start, and the edit guard's fire — and it is why the probe is affordable there
at all. It is read-only: it never writes, fetches, or mutates the tree it
reports on, which `test_toolkit_provenance.sh` asserts directly.

## Telemetry

Three proxies, in the order they disconfirm the premise:

1. **Is the state ever reached?** Does the probe ever report `MODIFIED`? If
   the fast lane is never entered, the premise behind this feature was wrong.
   Cheapest and most disconfirming signal available.
2. **The edit→observe loop, before and after.** A one-time executed
   measurement, not an automated metric — nothing here times anything, and
   nothing should.

   **Before** (design brief, dimension 0, measured 2026-08-02): a toolkit
   change reaches an observable effect through a pull request, a ~5.5-minute CI
   gate run, a merge queue that re-runs it, a release-tag cut, a pin bump in
   the consuming repo (itself a PR through the same path) and an install. Solo
   PRs landed 10–33 minutes after opening; three opened in the same minute took
   68, 69 and 145 minutes. End to end: tens of minutes to over an hour.

   **After**, timed end to end over five consecutive iterations of the
   documented fast-lane path — edit the live toolkit through the machine
   surface, invoke it and observe the new behaviour, then read the provenance
   verdict: **0.116–0.119 s per iteration** (edit 18 ms, observe 23–26 ms,
   provenance 73–76 ms), verdict `MODIFIED` on every one.

   **Read that number honestly.** It is not evidence that new machinery made
   anything faster — the edit-and-observe path was *already* instant, which is
   exactly what dimension 0 said. What the measurement establishes is the claim
   this feature actually makes: the readout that turns that path from furtive
   into deliberate costs **75 ms**, so visibility was added without
   re-introducing the latency the whole exercise exists to avoid. Had the probe
   come in at seconds, it would have had to leave the session-start and
   edit-guard paths, and the design would have failed on its own terms.
3. **Disposition of modified state.** Of the checkouts that report `MODIFIED`,
   what fraction end reconciled — upstreamed or restored — versus neither?
   That third number is the silent-fork rate, the risk this must not worsen.
   Its collection point is the `/tidy` drain step's pending-decisions entries,
   which is why that step exists: without it the metric has no collector.

A fourth proxy — stamping the verdict onto existing run telemetry, so no run
is credited to a release when modified code produced it — is **out of scope
here and named as such**. It needs a run-record seam this feature does not
build.
