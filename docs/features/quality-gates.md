---
title: Quality gates — one script both CI and a local run execute
slug: quality-gates
---

## Problem

A repository's continuous-integration job and a contributor's local
pre-merge check are, in principle, supposed to run the exact same tests
before anything lands on the default branch. In practice, that guarantee
tends to erode the moment the gate list is typed out more than once — once
in a CI workflow file, once in a project's own dev-workflow instructions,
maybe a third time in an automated build tool's own acceptance step. Each
copy drifts independently: a gate added to CI but not to the local list
means a contributor's "it passes locally" is not actually predictive of
what CI will do, and a gate added locally but never wired into CI means it
silently stops mattering. The failure is invisible until the day CI catches
something a local run swore was clean, and by then nobody can say which
copy was stale.

## How it works

`scripts/quality-gates.sh` is the single source of truth for the repository's
static, zero-network, repo-wide gate set. There is exactly one place the
list of gates is typed — every consumer runs *this script*, never a
hand-copied list of its contents, so "local gates mirror CI" is true by
construction rather than by three copies kept in sync through discipline.
Each entry is one full command line (almost always a `make` target); the
script runs every gate unconditionally — never stopping at the first
failure — and only exits non-zero at the end if anything failed, which
surfaces every broken gate in one run instead of one per CI restart.

**The kernel/overlay layering.** The gate set is two arrays unioned at run
time:

- `KERNEL_GATES` is typed directly in the script and covers exactly the
  suites a stranger's kernel-only install would have: board, build,
  install, hooks, PR-hygiene, and tidy mechanical-owner suites, none of
  which reference anything specific to a downstream fork's own private
  subject matter.
- `OVERLAY_GATES` starts empty and is populated only by sourcing every
  `scripts/quality-gates.d/*.sh` file present, in glob order. Each drop-in's
  only job is to **append** its own entries onto the array — never replace
  or reorder a sibling drop-in's entries — so more than one downstream
  contributor can extend the gate set without fighting over one shared
  file. An absent or empty `quality-gates.d/` directory (a genuine
  kernel-only checkout with no overlay) degrades to zero overlay gates with
  no conditional logic required anywhere in the script.

Gates are ordered `KERNEL_GATES` then `OVERLAY_GATES`, and run from
the repository root regardless of the caller's own working directory (a
build worker running from a throwaway worktree still resolves every `make`
target correctly). `--list` prints every gate's full command line prefixed
`[kernel]`, `[overlay]`, or `[skipped]`, without running anything — useful
for auditing exactly what a run will execute before it executes it.

**Kernel-only gate classes.** Some kernel gates cannot apply in a repo that
*vendors* the kernel as a subtree, so they are gated by **class** on one
signal — a repo-root `.kernel-pin`, present in a vendoring consumer and
absent in the kernel's own checkout. Gating the class, rather than guarding
each gate on its own surface probe, is what keeps the rule from drifting the
moment a new sibling gate is added without one. There are two classes:

- `SELF_DISTRIBUTION_GATES` — how the kernel bootstraps, rename-migrates,
  version-embeds and self-updates a fresh install of *itself*
  (`bin/bootstrap.sh`, the rename shim, the repo-root `VERSION`,
  `bin/subcommands/update.sh`). A consumer pulls the kernel through its own
  subtree flow and carries none of that surface.
- `KERNEL_CONTENT_GATES` — assertions about the *content of the kernel's own
  product surfaces*: its README's on-ramp narrative and installer command,
  its CLI's first-run banner, the AI-authorship footers on its product-docs
  pages. Reached through a consumer's compat symlink, those gates read the
  *consumer's* README and `docs/`, which belong to a different product and
  are under no obligation to say any of it.

"Fails in a vendored tree" is deliberately **not** the test for either class.
A gate whose *logic* is vendoring-blind — a path assumption or a discovery
pass that will not traverse a symlinked directory — is a real bug that must
keep failing until it is fixed upstream; class-gating it would bury it. A
skipped class is never silent: every member is named on its own `[skipped]`
line and in the run's `skipped gate — …` preamble, with the reason.

### Parallel execution

The gate set is ~109 *independent* suites, and the `checks` job's wall time
was almost entirely the cost of running them one after another. The measured
baseline (2026-08-02, from run-log timestamps) has no dominant gate —
`test-cli-subcommands` (then named `test-try`) 56s, `test-build` 55s, the whole-tree shell lint 29s, `test-board` 21s, the
prose budget ~20s, then a long tail of 1–5s suites — so no single-gate
optimization could recover it. Only concurrency could.

Gates therefore run through a bounded worker pool
(`workflows/scripts/lib/gate-pool.sh`) rather than a bare loop.
`QUALITY_GATES_JOBS` sets the width (`auto` = detected cores, clamped; `1`
restores the exact pre-parallel serial loop, which is the right mode for
bisecting a gate or hunting an order-dependent flake). Three things are
deliberately unchanged: the gate **list**, the pass/fail **semantics** (every
gate still runs, every failure is still collected, the run still exits non-zero
iff at least one gate failed), and the **log shape** — each gate's output is
captured whole and replayed in list order under the same `=== <gate> ===`
header, so a failing suite is exactly as easy to find as before. A one-line
`[ok]`/`[FAIL]` progress marker goes to stderr as each gate is reaped, and the
end-of-run summary reports measured wall time against the summed per-gate time
(which *is* what a serial run of the same set costs) plus the five slowest
gates, so the speedup is measured rather than assumed.

**Per-gate wall-clock publication (temperloop#968).** `QUALITY_GATES_STEP_SUMMARY=1`
appends the *full* per-gate table (every gate, not just the five slowest) to
`$GITHUB_STEP_SUMMARY` — off by default, and a no-op unless GitHub Actions has
actually set that path. `ci.yml`'s merge-gating `checks` job never sets it, so
this adds no cost or behavior change to the leg that gates `main`. Only
`nightly-macos.yml`'s macOS job and its ubuntu comparison job opt in, which is
what makes the two runners' breakdowns land in the *same* workflow run's
summary page — the localisation surface the macOS-vs-ubuntu slowdown
investigation needs (#968's first deliverable: measurement before any
matrix/branch-protection change).

This is a **within-job pool, not a build matrix**. Splitting `checks` into a
matrix would rename and multiply the required status-check context
(`checks (ubuntu-latest)`) and silently un-gate the branch; the single-entry
matrix in `ci.yml` exists precisely to hold that context stable.

Because the classification keys off each gate's own command line rather than
its position in the full set, it applies unchanged to any *subset* selected for
a run — diff-scoped gate selection composes with parallelism for free.

**Composing with sliced execution.** `/build`'s §3e.5 acceptance gate drives
this script as a *slice loop* (`QUALITY_GATES_START_AT` /
`QUALITY_GATES_BUDGET_SECS` and the exit-75 partial protocol). The two features
compose by **selection**: the slice window picks the run set, and the pool is
handed exactly that array. The budget is then checked between **chunks** of
`QUALITY_GATES_JOBS` gates rather than between individual gates, so a partial
run still stops on a gate boundary and still resumes at a whole number of gates
in. An *unbudgeted* run — CI, `make quality-gates`, a human run — is a single
chunk, i.e. full overlap with no barrier; only a budgeted caller pays the
per-chunk sync.

Chunking is deliberately preferred over teaching the pool a deadline of its
own. The pool's central fail-closed guarantee is *exactly one verdict per gate
handed in*; a deadline inside the pool would have to relax that to *per gate
dispatched*, and that assertion is what stands between a silently-dropped gate
and a green CI run. One barrier per chunk, on the rare budgeted path, is the
cheaper thing to spend. In practice the budget now rarely binds: the parallel
suite finishes well inside `/build`'s slice budget, so most sliced runs
complete in a single slice.

**Exit-code integrity.** The whole value of the gate is its exit code, so every
choice in the scheduler is fail-closed: each child writes its verdict to its own
meta file *and* exits with the gate's own status, and the parent requires the
two to agree — a disagreement, a missing verdict, or a child that died without
writing one is recorded as a **failure**, never a pass. The parent asserts it
recorded exactly as many verdicts as it was handed gates, so a gate cannot be
silently dropped. Completion markers are published from the child's `EXIT` trap,
so even a worker that dies abruptly cannot wedge the run (a hang would burn the
whole job timeout and report nothing — worse than any red gate). If the
scheduler cannot allocate its scratch directory it says so and falls back to the
serial loop, which is always correct.

**The unchanged-execution-environment invariant — and the signal trap it hid.**
"Identical pass/fail semantics" covers more than the gate list: a gate must also
*observe* the same process environment it did in the foreground, or a suite can
change verdict without anyone changing the suite. Backgrounding is not
transparent in bash, and one divergence broke a gate in CI:

- When job control is off — the default in a script — bash runs every
  asynchronous command with `SIGINT` and `SIGQUIT` set to `SIG_IGN`, and marks
  them *hard-ignored*. The disposition is inherited through both `fork` and
  `exec`, so it reaches `make`, the suite `make` forks, and every fixture below
  that; nothing inside the gate can undo it (`trap - INT` cannot restore a
  disposition bash considers ignored-on-entry).
- `workflows/scripts/probe/tests/test_gh_call_logger.sh` asserts that the
  `gh` timing shim propagates a signal death as 130, using a fake tool that
  `kill -INT $$`es itself. Under the pool that `kill` became a no-op, the fake
  exited 0, and `make test-conventions-probe` failed — deterministically, on
  both attempts, on a suite that is green serially. Note the shape of the near
  miss: the failure was *loud*, but the same mechanism applied to an assertion
  written the other way round (expecting a survival, not a death) would have
  been a silent false green.
- The fix is to fork **under job control** (`set -m` in `_gate_pool_spawn`),
  which is precisely the condition under which bash does not install that
  ignore — verified on bash 3.2 and 5.x, with and without a controlling
  terminal, with no job-status notices in a non-interactive shell. It is
  regression-pinned by case 11 of `scripts/tests/test_quality_gates_parallel.sh`
  (a synthetic gate that self-kills and asserts it observes 130), which fails
  if the `set -m` is ever removed.
- Two consequences, both deliberate. Each child now leads its own process
  group, so the cleanup trap kills the child's **group** and finally reaps the
  `make` subtree an interrupted run used to orphan. And a background process
  group that reads the terminal would be stopped by `SIGTTIN` and wedge the
  poll, so a child's stdin is pinned to `/dev/null` — which also removes a
  pre-existing local-only trap where `scripts/update-kernel.sh`'s `[ -t 0 ]`
  interactive prompt could block a run started from a terminal.

An audit of the rest of the set for the same class found no other exposure:
`test_gh_call_logger.sh` is the only suite that sends a signal and asserts on
the resulting status, none inspects its own process group, and the only
stdin-reading path is the `[ -t 0 ]`-guarded prompt above.

**The shared-state audit.** Concurrency is only safe for suites that do not
contend over shared mutable state, so the set was audited rather than assumed
independent. What the audit found:

- Every test suite isolates itself — `mktemp` scratch dirs, an overridden
  `$HOME`, stubbed `gh`/`claude`/`uvx` on a private `PATH`. No suite listens on
  a port (the few that name one point at a deliberately-unreachable address),
  and no suite mutates the checkout's git
  state (the one `git fetch` in the set is the freshness guard, which runs once
  in the parent before any gate starts). The one exception to "writes nothing
  into the repository tree" is the replay suites' mutation proofs, which edit
  `workflows/scripts/model-comparison/replay.sh` in place and restore it —
  which is exactly why they are pinned to the serial lane below
  (temperloop#1379).
- **Six gates are pinned to a dedicated serial lane** (`SERIAL_LANE_PINS` in
  `scripts/quality-gates.sh`). The lane makes them mutually exclusive *with each
  other* while still overlapping the rest of the pool, so pinning costs
  essentially no wall time:
  - `make shellcheck` and `bash scripts/tests/test_ensure_shellcheck.sh` both
    resolve the pinned shellcheck through `scripts/ensure-shellcheck.sh`, which
    downloads and `mv`s the binary into one shared cache path. On a cold cache —
    which is every CI run, since nothing restores it — two concurrent resolvers
    would race over the same file.
  - `make docs` rmtree's and rebuilds `workflows/scripts/docs/_site` in the
    live checkout, and the whole-tree shell lint walks every `*.sh` with
    `find` from the repository root. A whole-tree write
    racing a whole-tree walk is the classic transient "No such file or
    directory"; `docs` is the only tree-mutating gate in the set, so sharing a
    lane with the only whole-tree-walking gate closes it entirely.
  - The three replay suites whose mutation proofs edit the LIVE
    `workflows/scripts/model-comparison/replay.sh` in place
    (`test_replay_isolation.sh`, `test_replay_preflight.sh`,
    `test_replay_preflight_two_arm.sh`) contend over that one shared file:
    concurrently, one suite executes a copy another has temporarily broken, or
    its `mutate_file` finds the anchor text already rewritten. Measured, not
    assumed — six concurrent runs of two of them produced four failures
    (temperloop#1379). `test_replay_score.sh` mutates a mirror copy instead and
    needs no pin; that is the pattern a new replay suite should prefer.
- A second, purely advisory list (`SLOW_DISPATCH_HINTS`) names the measured long
  poles so the pool dispatches them first. Makespan is
  `max(total/width, longest-gate-start + its length)`, so a ~1 min gate sitting
  near the end of the list would otherwise straggle long after every other
  worker went idle. A stale hint costs a little scheduling efficiency and can
  never change a verdict.

**Per-script gates: splitting the two umbrella entries (temperloop#2162).**
The pool schedules per **list entry**, so an entry that loops a directory glob
*serially inside one slot* is indivisible no matter how wide the pool gets —
and the two biggest entries in the set were exactly that shape.
`make test-build` looped 58 `workflows/scripts/build/tests/test_*.sh` scripts
and `make test-cli-subcommands` looped 15 under `bin/subcommands/tests/`. Both
are now **glob-expanded at list time** into one gate per script (73 gates;
`_qg_expand_case_gates` in `scripts/quality-gates.sh`). Measured serially on
the item's host, those two entries cost 335s and 125s while their slowest
*individual* script cost 77s and 71s — that gap is the straggler the pool
could not touch. The `make` targets still exist and still work for local use;
they are simply no longer the gate.

Four properties are worth knowing:

- **Glob-expanded, never enumerated.** The expansion globs the same two
  directories the Makefile recipes glob, on every invocation, so a newly added
  `test_*.sh` becomes a gate with no edit to `quality-gates.sh` and none to
  `gate-paths.tsv` — whose two rows for these families are **pattern keys**
  (`bash …/bounded-suite.sh --label * -- bash …/tests/test_*.sh`) for the same
  reason. Exact keys still win, so a single script can keep its own pinpoint
  row; the four state-graph suites and `test_dual_build_preflight.sh` do.
  `scripts/tests/test_quality_gates_scoped.sh` case 22b asserts the expanded
  set **equals** the on-disk glob, which is what makes "glob-expanded" a
  checkable property rather than a claim.
- **Each gate keeps its own wall-clock bound.** Every expanded gate runs
  through `workflows/scripts/build/bounded-suite.sh` under
  `$BUILD_SUITE_TIMEOUT_SECS`, not just the umbrella `make` targets. Leaving
  the bound on the umbrella alone would have left it on a target the gate set
  no longer runs, reopening temperloop#2184's unbounded-hang defect at a finer
  granularity and 73 gates wide. The guard's poll cadence was tightened in the
  same change (a fast first poll, then 1s) so that paying the wrapper 73 times
  costs ~0.25s each rather than ~1.0s.
- **Independence was measured, not assumed.** A static pass over all 73 scripts
  first: every one sandboxes under its own `mktemp -d`, none mutates a live
  repo file in place, none binds a port, and none writes a fixed shared path.
  Then twelve full concurrent runs of the pooled set at widths 8/16/24/32.
- **It found a real coupling, which is the point of running it.** At 32-way,
  `bin/subcommands/tests/test_tokens_producer.sh` case 15 — which asserts the
  **whole repo's** `git status` is unchanged across its own run — went red
  naming `workflows/scripts/build/tests/.review-wait-early.<pid>`, a transient
  file `test_review_wait.sh` wrote *into the checkout*. Serially the two could
  never overlap; pooled, they did. The fix was the root cause (move that
  scratch file to a `mktemp` dir), not a serial-lane pin, because a test
  writing into a git-tracked directory is a defect in its own right. Four
  further runs at widths 24–32 were clean afterwards. Note the standing
  consequence: case 15 *reads global state*, so it is the tripwire any future
  tree-writing test will hit — its failure message now says so, so the next
  occurrence is attributed to the writer rather than to the producer.

**The SIGPIPE-under-pipefail hazard — a latent test-suite defect that
concurrency exposes.** The audit turned up one genuine hazard that isolation
and lane pinning cannot fix, because it does not live in the scheduler at all.
Many suites assert with the shape

```sh
set -euo pipefail
echo "$out" | grep -q "SOME PATTERN" || fail "not detected"
```

`grep -q` exits the instant it matches, which can leave `echo` writing into a
closed pipe; `echo` then dies of `SIGPIPE` (141), and `pipefail` promotes that
to the *pipeline's* status — so the assertion fails on output that visibly
contains the pattern. Whether the race is lost depends purely on scheduling, so
it is invisible on an idle machine and increasingly likely under load. Measured
on a 10-core machine with a synthetic probe: **0 failures in 800 tries
unloaded, ~0.25% at 4 concurrent, ~5% at 8 concurrent.** In the real suite at
width 8 it produced three first-attempt gate failures — `make test-build`,
`make test-cli-subcommands` (then named `make test-try`), and the design-brief
lint — each of which then passed on
retry, and two of which were the slowest gates in that run *because* of the
retry.

Two consequences, both deliberate:

1. The auto-width cap sits at the measured knee (`_gate_pool_auto_cap` in
   `gate-pool.sh`): width 8 was both **slower** (176s vs 162s) and **flakier**
   (3 retried gates vs 0) than width 4 on the same machine, so the cap costs
   nothing to hold.
2. The underlying defect is **not** fixed here, and must not be considered
   fixed by the retry machinery absorbing it — a retry that makes it pass is a
   workaround, not a root fix. It is widespread (596 occurrences of the shape,
   across 77 files that also set `pipefail`) and mechanically repairable
   (`grep -q PATTERN <<<"$out"` is a single command, so `pipefail` has no
   writer status to promote), which makes it its own item rather than a rider
   on this one.

A second, smaller load-sensitive transient was observed once at width 4:
`test_claim_marker.sh` generates a socket path with `mktemp -u`, and BSD
`mktemp` intermittently reports `mkstemp failed … File exists` under load. It
is **not** a cross-gate race — exactly one gate uses that path, and no leftover
files accumulate — so it is not a lane-pinning candidate; it belongs with the
same suite-hardening follow-up as the `SIGPIPE` shape above. Both are recorded
here rather than left to be rediscovered, because the retry policy makes them
invisible in an otherwise-green run.

**Diff-scoped gates.** Most gates read the working tree as it stands. Two
read the *change* instead — the added lines of a pull request's diff (the
public-repo leak guard) and the set of files it touches (the changelog
gate). Both resolve a base ref the same way (an explicitly supplied base,
else `origin/main`, else `main`, else a clean skip with a notice), and both
ride this same gate set rather than a second CI job, so they gate on the
already-required status with no branch-protection change.

The changelog gate answers two questions. The first: does this change touch
**contract surface** — the seams a downstream adopter couples to — and if so, does it
add anything under `## [Unreleased]`? That matters because pre-1.0 the
breaking signal rides the changelog rather than the version number: the
kernel updater decides whether a downstream pull needs explicit
acknowledgment by scanning changelog sections for a `BREAKING` marker, and
an entry that was never written cannot carry one. The definition of
"contract surface" is not typed a second time here — it is parsed at run
time out of the versioning policy's own table, so extending that table
extends the gate, and a table the gate cannot parse fails the run loudly
instead of quietly enforcing nothing. Genuinely non-shipping work (a prose
chore, a comment rewording) opts out by *recording* the choice — a label on
the pull request, a marker line in its body, or the same marker as a commit
trailer — with a reason required in the marker forms, so a skip is always a
decision someone made rather than something nobody noticed.

The second question is where the entry landed. An entry written under
`## [Unreleased]` does not stay there if a release is cut on the default
branch while the pull request is open: the cut creates the new version
section directly beneath `[Unreleased]` and moves the accumulated entries
down, so on rebase the pull request's own added lines resolve into the top of
a release that does not contain its work. The mirror failure is worse and
harder to see — correcting that drift by hand, and pulling someone else's
entry out of the released section along with your own, erasing the record of
work that genuinely shipped there. So the gate also fails a change that adds
lines to, or removes lines from, a section that was **already released at its
merge base**. The base ref is the whole discriminator: at head a release cut
and a stolen entry look identical, but a version heading that did not exist
at the merge base is one this change is *creating*, which is precisely what a
cut does — so a cut passes untouched while an edit to a section that shipped
earlier does not. Deliberately amending a shipped release — marking it
breaking after the fact, adding the migration note it should have carried —
stays possible through the same marker grammar with a different verb,
recorded in the same three channels and requiring the same reason.

**Diff-scoped gate *selection*.** The gates above describe *what* runs; a
second layer decides *which of them* runs. Running every suite on every pull
request charged each one a flat several minutes, and because a merged change is
validated twice — once on the pull request and again in the merge queue — every
merge paid that bill twice, even when the diff was a single documentation file
no suite could possibly be affected by. So on a pull-request event with a
resolvable base commit, the run is narrowed to the gates the changed paths can
actually reach, using a registry that maps each gate to the path globs that
affect it. Everywhere else — the merge queue, a push to the default branch, the
nightly run, the build pipeline's acceptance step, any local run — the full set
runs exactly as before. **The run that gates the default branch is never
scoped**, so a narrowing bug can at worst let a pull request go green early; it
cannot let an unproven commit land.

That is only safe if the map cannot quietly fall behind, which is the whole
design problem: a map that misses a dependency runs a smaller set and still
reports green. Four properties prevent it, and all four resolve *toward* more
coverage:

- A changed path matching no glob anywhere in the map escalates the run to the
  full set. Narrowing is opt-in per path; the fallback is never a smaller run.
- Any resolution failure — no base commit, a base the repository cannot
  resolve, an empty diff, a missing or malformed map — falls back to the full
  set and says so on stdout, next to the verdict as well as at the top, since
  "all gates passed" means something different on a scoped run.
- Paths whose blast radius is the gate machinery itself (the gate script, the
  selector, the map, the build file, the CI workflows, the tree-classification
  manifest) are listed explicitly and force the full set outright.
- A gate the map does not mention runs unconditionally, so a stale map
  over-runs rather than under-runs.

The third of those has exactly one exception, and it is decided by reading the
diff rather than the path. Registering a new gate means adding a line to the
gate script, and the gate script is on that escalation list — so adding a single
line to register one gate ran all hundred-odd suites. But a registration *adds* a
gate; it cannot change what an existing gate runs, nor how the tree is
classified, which is the only reason the gate script is listed there. So when the
diff to that file removes nothing and its additions are exclusively registration
lines (comments and blank lines may ride along), the escalation is declined *for
that one path* and the run instead takes the validators a registration has to
satisfy — the map's own completeness check and its test, the check-surface and
executable-bit registry pairs, the setting registry, the feature-docs check and
the tree-classification manifest — plus the newly registered gate itself, by
name, so a new gate runs on the pull request that adds it. Every other edit to
that file escalates as before, and so does a diff the probe cannot read: an
unreadable diff is not evidence that nothing was removed. A registration line is
recognised by position as well as by shape — the gate script holds other arrays
of bare quoted gate command lines, and an addition to one of those is a
concurrency decision rather than a registration, so it escalates like any other
edit. The exception fails
closed in every direction, and the run's reason line says when it was taken,
because a scoped run that quietly declined an escalation would be
indistinguishable from one whose diff never touched the gate machinery.

The map ships with its own gate. It fails the build if any gate lacks a row, if
a row names a gate that no longer exists, if a literal path in a row is not in
the tree, or — the one that matters most — if a row's globs match *nothing*,
because a gate orphaned behind an unmatchable glob would otherwise be skipped
on every scoped run forever with nothing else in the repository noticing. The
validator and the selector share one glob matcher rather than each carrying
their own, so the patterns that are validated are byte-for-byte the patterns
that are consumed. `--list-selected` prints the set a given invocation would
run, with its one-line reason, without running anything.

**The same map, applied to a local working tree.** Continuous-integration runs
are not where most of the gate time is actually spent. Across a corpus of build
workers, verification was 79% of all shell wall-clock and gate runs were 85% of
that — a distribution with a median of three seconds but a ninetieth percentile
of two minutes and a maximum of ten, because a worker checking a three-file
change had no way to ask for less than everything. `--scoped` gives it one: the
same selector, the same map, the same five defenses, fed the *local* changed
set instead of a pull request's diff. That set is the union of what has been
committed on the branch, what is staged, what is edited but unstaged, and what
is newly created and never added — because this mode runs *mid*-work, and a
brand-new file is exactly the code most likely to need a gate. Ignored files
are excluded, so the build harness's own scratch never widens the run.

Two things keep this from being a way to go green cheaply. First, it is
strictly a *fast-feedback* mode: the build pipeline's parent-side acceptance
step and every continuous-integration invocation remain bare and repo-wide, and
that run is the authority. Second, a scoped run is made impossible to mistake
for a full one — it names every gate it did not run and why, before the run and
again beside the verdict, and stamps the verdict line itself, so even a
one-line grep of a worker's log reads `[SCOPED SUBSET — NOT a full-suite pass]`
rather than an unqualified success. If no base commit resolves, or the working
tree is not a checkout at all, it says so and runs everything.

**What may never be scoped away.** Some gates are whole-tree *scanners*: they
read every tracked file, so every change is in scope for them by construction.
A second group is subtler and matters more here — gates whose verdict is a
*whole-surface claim* rather than a per-file one: is this registry complete, do
these two files still agree, is this total under its cap. A path glob can
enumerate a gate's inputs; it cannot keep a completeness claim true when the
thing that breaks it lands somewhere the map never thought to look. Both groups
are enumerated explicitly in the map, each with its reason written next to it,
and both run on every scoped run. Reports that cannot fail on their own
findings are deliberately left out of that floor: skipping one costs a report,
never a false pass, and a floor that collects everything would erase the very
saving it is guarding.

**The per-gate retry policy** lives in `workflows/scripts/lib/gate-retry.sh`,
sourced by the script (the same seam it already uses for the checkout-freshness
guard) so the policy can be tested without running the whole gate list. A gate
that fails is retried up to `GATE_MAX_ATTEMPTS` times, because the hosted macOS
runner intermittently fails unrelated hermetic gates under load — but a retry
only ever helps a *transient* failure, so the policy classifies before it
retries:

- **Deterministic signature.** The failed attempt's output matches
  `GATE_DETERMINISTIC_PATTERN` (an ERE; the shipped default names a static-lint
  finding code). The gate is not retried at all — it fails straight to
  escalation on the first attempt.
- **Byte-identical output.** The attempt printed exactly what the previous
  failed attempt printed. Nothing about the run changed, so nothing about the
  next one will either. This is the general net beneath the signature
  classifier: it needs no per-lint pattern and caps *every* deterministic gate
  at two attempts regardless of what it prints.
- **Otherwise** the failure is presumed transient and the retry fires — spaced
  by a graduated `GATE_RETRY_BACKOFF`-per-attempt sleep, so a slow-clearing
  transient actually gets time to clear rather than having the whole budget
  burned back-to-back inside a fraction of a second.

Every attempt, retry, and deterministic short-circuit is logged as it happens
and again in an end-of-run summary beside the pass/fail verdict, so neither a
masked flake nor a saved retry is invisible. All three settings are declared
with their defaults in `workflows/scripts/build/build.config.sh`; the script
keeps byte-identical fallbacks so it still runs standalone in a consuming repo
that never sources that file.

## Integration

The CI workflow's `checks` job (`.github/workflows/ci.yml`) runs one step:
`bash scripts/quality-gates.sh`, on `ubuntu-latest` only — that is the
required status check merges gate on. macOS coverage runs the *identical*
step on a nightly schedule against the default branch instead
(`.github/workflows/nightly-macos.yml`, plus a manual `workflow_dispatch`
trigger), a deliberate trade of gate-time BSD-dialect safety for pre-merge
latency: a macOS-only regression can land and is caught within a day rather
than blocked at the gate, and it surfaces only as a red run in the Actions
tab plus GitHub's built-in scheduled-failure email to the repository's
default recipients. The same workflow also runs a second, non-gating
`ubuntu-timing` job — same script, same `ubuntu-latest` runner the merge gate
already uses, with `QUALITY_GATES_STEP_SUMMARY=1` set on both jobs
(temperloop#968) — purely so a night's macOS and ubuntu per-gate breakdowns
land in the same run's summary page for direct comparison; it produces no
`checks (...)`-shaped context and is not required by branch protection. Both
jobs additionally run a `Runner characterization` step
(`workflows/scripts/dev/runner-characterization.sh`) recording what hardware
each leg actually got — raw core count beside the clamped pool width, plus
process-spawn and filesystem throughput — which, like the timing table,
asserts nothing and can never fail the run. What five nights of those two legs
showed is written up, with the recorded per-gate datasets and a
`make macos-gate-timing-report` command that recomputes every table in it,
at [`docs/validation/macos-ci-gate-timing.md`](../validation/macos-ci-gate-timing.md).
A contributor's local pre-merge check runs the identical invocation. The
automated build pipeline's own parent-side
acceptance step, before it will consider a plan item's changes ready to
merge, also shells out to this same script rather than re-implementing any
part of the gate list. Adding, removing, or changing a gate is a one-line
edit to this file (or to an overlay drop-in) and every one of those three
callers picks it up on their very next invocation, with nothing else to
update.

## Resource impact

Every gate is a fast, zero-network, repo-local check — test suites, static
lints, and validator scripts that read only the working tree, never call
out to a remote API, and never require a package install beyond what the
repository already vendors. Total *gate time* scales linearly with the number
of gates (today ~109), but wall time does not: gates run through a bounded
worker pool (§ Parallel execution), so a run costs roughly
`total-gate-time / width` plus whatever the longest single gate adds to the
tail. Each gate is independently isolated with no shared fixture or generated
artifact a later gate depends on — which is what makes both reordering and
concurrency safe — apart from the three lane-pinned gates that share one
mutable resource and are held mutually exclusive by the scheduler.
Overlay drop-ins add to this linearly as well — an overlay carrying no
drop-ins costs nothing beyond the one directory-existence check.

Pull-request runs no longer pay that full linear cost: the selection layer
above reduces them to the affected subset, which for a documentation-only
change is a small fraction of the whole set (the handful of whole-tree
scanners, plus the documentation-site build and its coverage validator). The
selection itself costs one `git diff --name-only` and a linear scan of the map,
both negligible against any single gate. Merge-queue and nightly runs are
unaffected and still pay the full cost, by design.

## Telemetry

None as a dedicated stream. The script's own stdout is the observable
surface: the run opens by naming which set it is about to execute and why
(diff-scoped with a count, or full with the reason it declined to narrow), each
gate prints a `=== <command> ===` banner as it runs, a scoped run repeats its
scope beside the verdict, and a failing run ends with an explicit
`FAILED N/M quality gate(s)` summary
naming every gate that failed (not just the first) — that summary, and CI's
own red `checks` status derived from the script's non-zero exit, are how a
broken gate is noticed.
