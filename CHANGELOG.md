# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/). See
[`VERSIONING.md`](VERSIONING.md) for the canonical bump rules and what each
tier signals.

Pre-1.0, the breaking signal rides the CHANGELOG, not the version number: a
release that changes the contract surface in a way an overlay must adapt to
**tags its section `BREAKING`** and includes a migration note. `update-kernel`
reads that marker; a stranger greps for it before pulling.

## [Unreleased]

**New-work dual-build harness (epic #2065) — minor, additive.** `/build
--dual-build <tier>=<candidate>` can now build every in-scope item of a
level under two models at once, judge each item pairwise, and ship the
winning arm's work — a comparison run on work the repo was already going
to do, rather than on a replayed corpus of already-closed history. The flag
is per-invocation and the only thing that arms it: a `/build` with no flag
is byte-identical to before this epic shipped, and every new setting,
script and trailer below is inert until an operator opts in. The
individual pieces (settings, worktree/branch arm naming, the read-isolation
guard, the ledger and patch archive, the pairwise judge mode, the
`Model-comparison-arms:` PR trailer, the spend pre-flight and consent gate,
the `--dual-build` flag itself, blind judge calibration, the level-pick tally
plus its two operator levers, and the cumulative report) each shipped as
their own entries below and in `changelog.d/`; this entry is the narrative
thread connecting them for a reader who was not following the epic item by
item. See [`docs/features/model-comparison.md`](docs/features/model-comparison.md)
for the full mechanism, and ADRs 0038–0041 for the architectural calls this
harness made along the way.

## [0.41.0] - 2026-09-15

### Added

- **`workflows/scripts/build/state-graph.sh soak` can now report how long its
  soak clock has been stopped** (#2016). `soak --status --board <N>` prints one
  JSON line carrying three figures — the days recorded so far, the days
  required (`STATE_GRAPH_SOAK_DAYS`), and how many days have passed since the
  most recent record — plus a `state` of `never-recorded`, `stale`, `current`
  or `unreadable`. A soak nothing has ever run and a soak that ran and then
  stopped six days ago now read differently; `soak --count` printed `0` for
  both, and for a soak nothing schedules that `0` never changes, so a stopped
  clock was invisible until someone thought to check. Reporting the elapsed
  days rather than a stale/not-stale flag is deliberate: the number grows while
  the clock is stopped, where a flag repeats itself forever. The new setting
  `STATE_GRAPH_SOAK_STALE_DAYS` (default `1`) sets how old the newest record
  may be before the clock reads stale. `--status` exits 0 in every state,
  including `unreadable` — it reports, it does not gate.

### Fixed

- **A build, fix or sweep run that quietly did nothing is now reported instead
  of counted as a success** (#2004). When the per-level driver was asked to
  work on at least one item and came back having produced no pull request, no
  parked item and no escalation for any of them, `/build`, `/fix` and `/sweep`
  had no branch for that combination and read it as "finished, nothing to
  report" — the item vanished with no signal at all, while its issue was still
  open and marked in progress under a live claim. A run whose own driver
  restarted mid-flight could land exactly there. `claude/workflows/build-level.mjs`
  now recognises the combination and returns it as its own named outcome,
  naming every item it was asked to work on and giving, for each, a ready-to-run
  command that re-checks the issue, any open pull request for its branch, and
  its worktree. The three commands each act on that outcome by running those
  checks and deciding from what they report, rather than concluding anything
  from the empty result. A run that was legitimately asked to do nothing, and a
  read-only investigation item that produces a verdict rather than a pull
  request, are both unaffected and report exactly as before.

- **A build that `worktree.sh create` shelves is now reported instead of
  silently dropped** (#2006). `create` never refuses: when the worktree path it
  needs already holds committed work that preservation could not capture, it
  moves that occupant aside to `<path>.unpreserved-<sha8>` and reports the fact
  on its `CREATED` line as `sidelined` / `sidelined_path` / `sidelined_branch`.
  Nothing downstream read those three fields, so an intact, committed build got
  shelved while a fresh worker rebuilt the same item and nothing said so — a
  wasted re-drive plus an orphaned worktree nobody knew to reclaim. The driver
  now reads them when it creates an item's worktree and tells you three ways: a
  named `SIDELINED BUILD` notice in the run log, carrying the shelved path, its
  branch and a reclaim command you can paste; the same fact travelling with the
  item all the way to the merge gate, whether it ends up parked or escalated;
  and a count on the run's summary. Because the reading lives in the one file
  `/build`, `/sweep` and `/fix` all route through, all three inherit it.
  `worktree.sh` is unchanged — its never-refuse contract still stands.

- **`agent_declared_state` now resolves the `reviewers/` catalog subdir at
  every agent directory it probes, not just the checkout's source tree**
  (#2026). A per-language reviewer installed at
  `~/.claude/agents/reviewers/<name>.md` — the shape on a host whose
  machine-global agent dir points at a kernel checkout's `claude/agents` —
  missed the machine surface's flat-only check and was reported
  `source-only`. Because `installed` is the documented spawn gate, a caller
  obeying the contract silently skipped a review seat that was live and
  spawnable. The project-scoped `.claude/agents/` surface gains the same arm,
  so the same layout resolves identically wherever it appears. Surface
  precedence is unchanged: a live install still outranks a shipped-only hit,
  and nothing moves out of `absent`.

- **`/build`, `/sweep` and `/fix` now run the orchestrator from your checkout
  instead of a stale copy in `~/.claude`** (#2027). All three commands used to
  name `~/.claude/workflows/build-level.mjs` as the script to run. That path
  had two problems. The Workflow tool refuses any script outside the working
  directory, so the path was never usable as written and each run quietly
  depended on whoever launched it noticing and substituting the in-repo copy.
  And when it was usable, nothing in this repo ever installed or refreshed
  that file — it was a plain copy with no owner, so it fell further behind on
  every merge (347 lines behind on the host that reported this, and six days
  behind during an overnight run in which every invocation executed superseded
  machinery and reported success). All three commands now resolve
  `claude/workflows/build-level.mjs` from the checkout you are working in, via
  the new `workflows/scripts/build/workflow-path.sh`, so there is only one
  copy to be right about. If something still points at an installed copy — a
  repo that vendors only the install, or an explicit path you pass — that same
  script checks it against your checkout first (reusing the existing
  `workflows/scripts/install/doctor.sh` drift check) and **refuses to hand
  back a path that differs**, rather than letting superseded machinery run and
  report success. A copy it cannot check is reported as unchecked, never as
  clean. Nothing installs `claude/workflows/*.mjs` and nothing should: the
  checkout copy is the only one these commands need.

- **`worktree.sh` now freshens `origin/<default>` before judging work unlanded,
  and records which basis it judged on** (#2030). Every landed-check in that
  script compares against the LOCAL `origin/<default>` ref, which only moves
  when something fetches; `preserve_unlanded` — the check whose verdict decides
  whether work is recorded as lost — never freshened it, and on the `create`
  path the hand-rolled fetch ran *after* the probe that needed it. Work merged
  minutes earlier therefore read as not-an-ancestor, and `remove` minted a
  `refs/parked/*` preservation for work already in the default branch. The
  freshen is now one shared helper (`create`, `prune` and `deps-merged` use it
  too), bounded by the new `WORKTREE_LANDED_FETCH_TIMEOUT_SECS` through the
  portable-timeout shim. It fails safe: a failed, timed-out or offline fetch is
  never fatal and leaves the local ref as the basis, which can only make work
  read as less landed — so "could not establish" still preserves, unchanged, and
  `remove` never depends on the network being up. Each preservation now carries
  `basis=refreshed` / `basis=unrefreshed` on its mint line and durably on the
  ref's own reflog, and `prune`'s `PARKED_REF` / `PARKED_REF_REAPED` lines
  report it — so a verdict reached against a stale comparison point is
  distinguishable after the fact from one reached against a fresh one.

- **A code review that finishes just after the review time limit is now used
  instead of discarded** (#2032). The pre-push review pass `/build`, `/fix` and
  `/sweep` run waits for its reviewers under a wall-clock limit
  (`BUILD_REVIEW_AGENT_CEILING_SECS`), and it checked exactly once — the instant
  that wait ended — whether each reviewer had come back. A reviewer whose
  finished review arrived a moment later was already past the only check there
  was: its findings were thrown away, and both the PR body and the run's review
  tally reported it as unavailable for exceeding the limit, with nothing
  recorded as having run. This was not a hang; the reviews arrived and were
  dropped, and one discarded review had already found a real defect that then
  had to be found again by hand. The limit is unchanged and still bounds how
  long the pass waits — what changed is what happens to a result that arrives
  anyway: the pass now reads each reviewer's state as late as it can before
  writing anything, so a review that landed late is reported as having run and
  its findings reach the PR body. A reviewer that genuinely never comes back is
  still reported as skipped, naming the limit as the reason, and a recovered
  review can no longer be counted as both.

- **`env-reconcile.sh` no longer describes a directory layout the host stopped
  having, and an abandoned operator checkout stops reading as a bare `OK`**
  (#2041). The comment beside the checkout registry asserted that the operator
  clone of the kernel repo "owns the `temperloop.wt/*` worktrees" — true when
  written, silently inverted once the `batch/` layout arrived: measured
  2026-09-15, the operator clone was 544 commits behind with zero worktrees
  while the cron clone held both live ones. It is rewritten to explain the ROLE
  distinction (which baseline each clone is classified against) and to assert
  nothing about which concrete directory currently holds worktrees or gets
  pulled, so it cannot go stale against one host's habits again — the
  classifier never read that claim anyway, since worktrees are discovered by
  scanning `<checkout>.wt/` beside every registered entry in both lists.
  Alongside it, the operator role gains one informational class,
  `DORMANT:<days>d-idle:<n>-behind`: being behind `origin/<default>` stays
  deliberately un-flagged for this role (a checkout may sit on other work), so
  the discriminator between "behind because busy" and "behind because
  abandoned" is LAST ACTIVITY — the newer of HEAD's committer date and the
  newest HEAD reflog ENTRY's own recorded timestamp. Neither mtime is used: the
  index's is refreshed by the reconciler's own `git status`, and the reflog
  FILE's is rewritten by `git gc --auto` (the motivating checkout's reflog was
  zero bytes and dated today while its last real activity was a month old, so
  an mtime reading would have called it active). A checkout that is behind AND idle past
  `ENV_RECONCILE_DORMANT_DAYS` (default 14) now prints its own `DORMANT` line
  instead of `OK`. It raises no alarm, appends nothing to the `--format entry`
  vault surface, and carries no remedy: disposing of an abandoned checkout is
  an operator decision, and the reconciler stays READ-ONLY and fail-open —
  unreadable activity signals emit nothing rather than guessing "abandoned".

- **Running the build test suite no longer spends a checkout's code-review
  budget** (#2046). `/build`, `/fix` and `/sweep` cap how many review rounds a
  single item may take before they stop waiting for it to converge — the cap
  is `BUILD_REVIEW_BLOCKING_MAX_ROUNDS` in
  `workflows/scripts/build/build.config.sh`, and the count is kept per
  checkout in a `build-review-rounds` file inside that checkout's git
  directory. Two cases in `workflows/scripts/build/tests/test_workflow.sh` ran
  the real code-review setup against whatever checkout the suite happened to
  be running in, and that counted as two rounds every time anyone ran the
  tests. Since the suite normally runs inside the same throwaway checkout the
  fix is built in, a change whose tests were run even twice was already over
  the cap before its first real review round. The cap then fired at once and
  carried unresolved review findings into the pull request body instead of
  letting the review finish — silently, because nothing failed; the count just
  climbed. The two cases now use the read-only form of the same step, and the
  suite fails if any test writes that count again.

## [0.40.0] - 2026-09-14 — BREAKING

### Added

- **`/build`, `/sweep` and `/fix` now tell you when the installed build engine
  is too old to understand a setting they are passing it** (#2018). Those three
  commands hand their work to a single installed script,
  `~/.claude/workflows/build-level.mjs`, along with a bag of settings. The
  hand-off has always been forgiving on purpose: a setting the installed script
  does not recognise is ignored and a built-in default takes over, so an older
  copy keeps working rather than crashing. The cost was that the same silence
  covered a copy that was simply **stale** — or, in a repo that vendors this
  kernel, an older **vendored** copy — which quietly ignored a setting the
  command believed it had applied, with nothing said on either side. Observed
  live: an installed copy 18 days behind ignored the setting that routes code
  reviewers, and the run fell back to the exact path it was in the middle of
  replacing.

  `claude/workflows/build-level.mjs` now publishes the list of settings that
  copy understands, and a new probe,
  `workflows/scripts/build/handoff-capability.sh`, compares that list against
  what a command is about to pass. All three commands run it immediately before
  handing off. Nothing is blocked — the fallback behaviour is unchanged — but
  you now get a one-line notice **naming each setting that will be ignored**,
  rather than a generic "your copy is old". The probe compares against whatever
  copy you point it at, so it works for a vendored copy in your own repo, not
  only for an overdue `make install`.

  If the probe cannot determine the answer at all — the file is missing or
  unreadable, or it is an older copy that publishes no list — it reports that
  as its own third result and says why. It never reports an undetermined check
  as a clean one.

- **The state-graph soak's required day count is now a named setting**
  (#2017). `STATE_GRAPH_SOAK_DAYS` in
  `workflows/scripts/build/build.config.sh` is the one place the soak length
  is stated: how many distinct recorded days `state-graph.sh soak --count`
  must reach before the cross-check against the independent
  `reconcile.sh --status` read is treated as trustworthy. The length was
  previously spelled out as a bare word across several comments, with no
  single place to change it and no recorded reason for the number. The
  default is unchanged, and its rationale now sits beside it — a judgment
  call about how many varied board situations a soak gets to observe (parks,
  merges, claims going stale, worktrees appearing and vanishing), not a
  derived sample size. Nothing in the tree reads the setting yet: the soak's
  own commands report the recorded day count and leave the sufficiency call
  to whoever is watching.

### Changed — BREAKING

- **`/build` §3e's per-item review tally now names every routed-but-unrun
  reviewer** (#1984). `park()`'s `review` record gains a `routed_not_run` field
  alongside `ran`/`skipped`/`mandatory_ok`, and `/build`'s Step 6 summary
  renders it. `mandatory_ok` covers only the `claude/commands/*.md` →
  `workflow-reviewer` rule (foundation#1007 — the workflow-reviewer mandatory rule), so an extension-axis reviewer
  routed by `reviewer-routing.tsv` — `shell-reviewer` for a `.sh` diff, say —
  could resolve, be skipped, and still leave the tally reading fully clean.
  `routed_not_run` is non-empty exactly when `skipped` is. It is a visibility
  field, not a second gate: a per-language reviewer is routinely inactive in a
  consuming checkout by design (ADR 0007), so blocking on one would go red in
  the ordinary case. Rationale and the rejected alternatives are in
  [ADR 0037](docs/adr/0037-routed-but-unrun-reviewers-are-visible-not-blocking.md).

- **`PROSE_BUDGET_TIER2_FILE_CAP` raised 1186 → 1201**, reseeded with zero
  headroom to `claude/commands/workshop.md`, which the `/workshop` two-phase
  rewrite (#1958) takes to 1201 lines — passing `claude/commands/build.md` at
  1186 as the largest tracked `claude/**/*.md` file (#1998). The cap is
  **uniform by design** ("never a per-file table"), so this relaxes the
  tier-2 budget for every tracked kernel doc by 15 lines, not `workshop.md`
  alone — an adopter vendoring `build.config.sh` picks up the looser cap for
  their whole kernel doc set. Epic #1938's plan projected the rewrite as net
  *negative* on line count (it removes the coverage walk); measured, it came
  in at **+136** (1065 → 1201), so the plan's own contingency fired — the
  raise ships as its own PR ahead of the item rather than as a mid-build
  config change. **No subtraction pass ran**, deliberately: trimming would
  not have avoided the raise (a ~1195 floor after re-wrapping the touched
  sections is still over 1186), and the spec had just been reviewed clean by
  `docs-reviewer` and `workflow-reviewer` with no redundancy finding, so
  cutting reviewed contract surface on the critical path would delete more
  contract than the ratchet step costs. A genuine subtraction pass over the
  rewritten `workshop.md` is filed as #1999, off the critical path — the same
  two-step #954 took when it filed #956, which then cut that file 1181 →
  1041. Worth stating plainly, since the ratchet is documented as moving both
  ways: since #956 lowered the cap to 1100 it has moved **up eight times** to
  1201 with no subtraction pass in between.

- **`changelog.d/README.md` now states who a changelog entry is written for,
  and the register that follows from it** (#2007). Fragments were being
  written for the person who had just made the change — leaning on step
  letters from a command spec, field names from an implementation file, and
  in one case a mechanism name that existed nowhere in the tree — and then
  folded verbatim into `CHANGELOG.md`, which is read by someone holding none
  of that context. The README now names that reader (the adopter deciding
  whether and how to pull an update), gives three concrete do-not rules, and
  shows a bad/good pair for each, drawn from real review findings. It also
  records the finding rate that prompted it, so the next check is a
  comparison rather than an impression. No gate or command behaviour
  changed: if you write changelog entries for this repo, read that file
  before the next one.

- **`/workshop` is now two phases with two operator gates, and its
  per-dimension coverage walk is removed** (temperloop#1958 — two-phase
  rewrite; epic #1938 — `/workshop` redesign; ADR 0035). The command used
  to walk a design brief's coverage dimensions one at a time, stopping the
  operator at each; a prototype run took 26 modal stops, 10 of which asked
  for nothing but an acknowledgement. It now stops twice. **Phase 1** is an
  interview: `/interview` runs inline in the same session, and its very
  first question is the **premise gate** — a chance to kill the idea
  outright before any design work happens. **Phase 2** then runs unattended
  start to finish: it drafts every dimension the interview did not reach
  (marking each as facilitator-drafted rather than operator-stated),
  validates the brief before spawning any reviewer, runs the adversarial
  review panel and the cross-dimension congruence pass, and ends at the
  second gate — a **delta report** that shows the operator, in roughly two
  batches, the full before/after of everything Phase 2 changed, and takes
  one verdict per dimension rather than one per batch. **Phase 3** ratifies
  and materializes the epic as before, additionally asking whether any
  batch of that report was rubber-stamped, and printing a per-run tally of
  how often the operator was interrupted. The pipeline diagrams in the two
  peer front-door specs — `claude/commands/triage.md` and
  `claude/commands/assess.md` — now name the new phases instead of the
  removed walk.

  **Removed in this release** (the BREAKING half — documented steps drop,
  per `VERSIONING.md` § The contract surface): the per-dimension coverage
  walk and its tier-split proposal stop, the per-dimension `walk` verdict,
  the three-free-rounds challenge bound, and the pre-ratify walkthrough
  pass.

  **Migration:** briefs ratified under the walk grammar keep validating
  (unstamped ⇒ legacy); a brief authored under the new grammar carries
  `record_grammar: delta` in its frontmatter. Nothing checks that stamp
  automatically — `workflows/scripts/validate-design-brief.sh --brief
  <path>` is an **on-demand lint you run yourself**, not a pipeline gate.

### Fixed

- **`/build`'s §3e pre-push review no longer loops unboundedly on serially-discovered HIGH findings** (#1970). Two halves. (1) `claude/agents/workflow-reviewer.md` now instructs the seat to enumerate **every** HIGH-severity finding it can identify on the diff in one pass before it ranks or narrows, and names a later pass surfacing a pre-existing HIGH as the failure the instruction exists to prevent; MEDIUM/LOW triage is unchanged. (2) `claude/workflows/build-level.mjs` carries a convergence bound — `BUILD_REVIEW_BLOCKING_MAX_ROUNDS` (default 3, handed in as `input.reviewBlockingMaxRounds` at `/build`, `/sweep` and `/fix` Step 0) — on the review rounds one item's worktree may spend. Past it, both blocking sites (the 3e pass and §3g's CI-fix re-review) stop re-escalating `review-blocking` and instead open the PR with the residual findings carried in its `## Review notes`, plus a `review.residual_blocking` entry on the parked record for the Step 6 tally. Findings are carried, never suppressed, and any item that converges within the bound behaves exactly as before. That tally is **rendered where its contract says it is**: `/build` Step 6's `Review (…)` summary line, `/sweep` Step 4's report and `/fix` Step 7's report each carry a `residual_blocking` case naming the affected slugs, each one's `round`/`max_rounds`, and that the PR's `## Review notes` must be read before merging — so an item that shipped with an unresolved HIGH no longer reads byte-identically to a clean one in the run summary. Previously unbounded: one live item spent five consecutive §3e passes, four distinct HIGHs, zero repeats, ~2h45m and ~1.05M subagent tokens, with pass 4's HIGH caused by pass 3's directed fix and the reviewed spec growing 447 → 635 lines across the rounds, so each pass enlarged the surface the next one read.

  The per-worktree round marker the bound reads degrades softly on a corrupted-but-present value as well as a missing one: its count is normalised to a bare decimal before the arithmetic, so a hand-edited or snapshot-restored marker holding `08`/`09` reads as 8/9 rather than aborting the whole review-diff step on a POSIX octal arithmetic error — the `review-diff-error` escalation §3e is least able to act on.

  `claude/agents/workflow-reviewer.md` is kernel **source**: the reviewer half takes effect in a session only once `workflows/scripts/install/project-agents.sh` re-installs the agent into `~/.claude/agents/`.

- **`state-graph.sh`'s `stale-claims` query now decides liveness from a new
  `transcripts` source — Claude Code's own per-session
  `$CLAUDE_PROJECTS_DIR/*/<sess>*.jsonl` mtime, within
  `RECONCILE_STALE_AFTER_SECS` — the SAME evidence `reconcile.sh --status`
  itself checks (`_reconcile_session_live`), instead of a tmux
  `@claimed_issue` marker or the journal's step-outcome ledger** (#1980).
  ADR 0033 (`docs/adr/0033-derived-state-graph-composes-one-way-with-one-
  independent-cross-check.md`) rests on `state-graph.sh soak` diffing this
  query against reconcile.sh's own claim-liveness class; two prior fixes each
  keyed liveness off a source that comparison never actually invokes — round
  1 off the journal (records *work done*, not *a session existing*: a
  genuinely live session with no step-outcome line yet read as a confident
  false positive), round 2 off tmux markers (`reconcile.sh --status` never
  touches tmux at all — that lens lives only in its separate `markers` mode,
  whose own `board-without-marker` class the soak never diffs). Both were
  scope artifacts manufacturing exactly the standing disagreement this
  cross-check exists to catch. The query now also **gates on host**: a claim
  stamped to another host is excluded from findings entirely, never reported
  stale from local transcript evidence that cannot speak to a foreign host's
  liveness — this host's claim-liveness lens (`reconcile.sh`'s
  `status_reconcile_main`) gates the exact same way before ever checking a
  session's mtime. This matters because the claim stamp is the cross-session
  work lock: a false stale verdict on a live claim invites a second session
  to pick up work already in flight, one host across if the gate were
  missing. The soak's per-class mapping is also narrowed: reconcile's
  `stranded claim stamps on closed issues` class is no longer folded into
  `stale-claims` — the board source's closed-issue residue read never
  attaches a claim stamp to a closed Issue node, so that reconcile class
  could only ever land in `only_in_reconcile`, a class that can never agree
  is not a cross-check. `status:"unknown"` is still reported only when the
  transcripts source itself cannot be read (no transcript directory at all),
  never a confident stale set computed against an incomplete or unrelated
  liveness signal. Scoped to `_sg_query_stale_claims` and
  `_sg_reconcile_class_set`'s awk mapping; `_sg_degraded`, `status-drift`,
  and `resume` are unchanged.
- **`stale-claims` now also gates its claim set on Status: In Progress**,
  matching reconcile.sh's own producer (`reconcile.sh:876-879`), which emits
  its "stale claims" class only for an In-Progress issue. Without this, a
  claim stamp left behind on an issue moved off In Progress — the ordinary
  "Park, don't abandon" residue, since `board_set_status` never clears the
  claim stamp (only `release.sh` does) — surfaced as a confident stale
  finding reconcile.sh structurally never reports, a standing false
  disagreement the mirror image of the closed-issue exclusion above. `_sg_now`
  is a new seam (mirrors `_sg_git`/`_sg_soak_day`) so a test can pin
  `_sg_read_transcripts`'s liveness cutoff comparison exactly on its boundary.

- **`state-graph.sh`'s `pr_list` source now routes its `gh pr list` payload
  through `_board_sanitize_control_chars` before any `jq` touches it** (#1981),
  so one stray control byte in a single PR no longer takes the whole source
  down. The read projects `title` and `body` — user-authored fields — and `jq`
  exits 5 on a literal control byte, which the `count` guard converted into a
  source-wide `error`. That error was **sticky**: it recurred on every run for
  as long as that one PR stayed open, out of up to 100 open PRs, and
  `_sg_query_unlinked_prs` correctly refuses to answer over a degraded source,
  so `unlinked-prs` reported `unknown` for the duration. Each run stayed
  individually legible. Nobody reads every run, so the practical effect was a
  query class silently contributing nothing across the fourteen-day soak that
  ADR 0033 / #1921 depends on. The sanitize stage is applied once, right after
  the read and after the empty-output default; that ordering is load-bearing
  because the `count` guard treats empty `jq` output as unparseable, so a
  payload of nothing but control bytes reports `error` — the honest answer for
  a page that could not be read — rather than being defaulted to `[]` and
  reported `absent`. Scoped to `_sg_read_pr_list`; `board.sh` is unchanged.

  **Also closed here: `_sg_read_pr_list` could return non-zero — PRE-EXISTING,
  not introduced by this change.** It was the lone `_sg_read_*` in the file
  able to escape the return-0 contract, and `_sg_build_snapshot` reads it with
  a bare `r_pr=$(...)` assignment, so under `set -euo pipefail` that return
  aborted the **whole snapshot build** rather than degrading one source. The
  `count` guard tested only `jq`'s exit status, and `jq` exits **zero with no
  output** on empty or whitespace-only input; it is now arity- and type-aware,
  yielding a count only for a single top-level JSON array. The
  `nodes=`/`edges=` transforms report `error` and return 0 on any failure
  rather than falling back to an empty array — they are modelled on the
  closed-residue block's belt-and-suspenders shape (`state-graph.sh`
  ~`:583-593`, where it guards `extra=`), and the difference is deliberate:
  `extra` there is supplementary data, whereas `nodes` here IS the answer, so
  an empty fallback would manufacture a confident false negative. The hole was
  already reachable pre-#1981 (SPACE is `0x20`, outside `tr -d '\000-\037'`,
  so a whitespace-bearing payload survived sanitizing and landed in it); what
  this change did was widen the trigger set, which is why it is closed here.

  **Behavior change:** a `null` PR-list payload now reports `error` rather than
  `absent` — `null` is not a legitimately empty PR list. A genuine `[]` still
  reports `absent`. Six new tests cover the recovered and honest-`error`
  routes; the five `error` cases each assert a zero return **and** valid JSON
  **and** status `error`, since the defects were a non-zero return with empty
  stdout and a confident `ok` over a payload that could not be projected.

  **Audit (confirmed, not assumed):** `pr_list` was the last unsanitized
  `gh → jq` seam in `state-graph.sh`, and is now covered. The other two `gh`
  reads reachable from this file were already sanitized — the closed-issue
  residue read (`state-graph.sh:583`/`:589`) and everything arriving via
  `BOARD_ITEMS_JSON`, which `board.sh`'s `_board_issues_item_list` sanitizes on
  **both** its cache-read and live-`gh` arms. The `worktrees` source parses git
  porcelain (not `gh`) and never feeds raw text to `jq`'s parser; `transcripts`
  reads local JSONL validated per line with `jq -e .`.

  The issue also asked for a lint flagging any unsanitized `_board_gh … | jq`.
  Deliberately **not** added, on kernel engineering principle 7 — after this
  fix there are zero remaining sites to catch, and a grep-shaped check cannot
  tell a user-content read from a structural-field projection. The full cost
  analysis is in the PR body.

- **The reviewer-routing table is now supplied by the caller instead of being
  copied back out of the build machinery** (#1982). Deciding which review
  agents a change needs requires two inputs: the list of files the change
  touched, and the routing table that maps file types to reviewers. Only the
  first genuinely has to be discovered while the build runs — the routing
  table is a fixed file in the repo, the same on every run. It was
  nevertheless being read inside the build and copied back out through an
  intermediate step, and that copy was unreliable: across eight observed
  occurrences it arrived empty, arrived as a sentence *describing* the table
  rather than the table, and arrived with its tab and line breaks turned into
  literal backslash characters so that eleven rows parsed as one. Each failure
  stalled the change with no review having run, and four of them landed
  consecutively on a single change. A count and a checksum sent alongside the
  table were correct every time, which is what identified the copying step —
  not the reading of the file — as the fault. The caller now reads the file
  directly and passes its contents in, so the unreliable copy is no longer
  part of the path. Earlier attempts guarded the copy (a row count, then a
  content checksum, then one automatic retry); those guards remain as a
  fallback for a caller that has not been updated, and nothing changes for
  such a caller. **No routing behavior changes** — the same table produces the
  same reviewers; only how it reaches the decision changes.

- **`/fix` no longer throws away a finished fix when something blocks it late**
  (#1988). A blocking review finding, or a single acceptance bullet coming
  back false, used to be handled like an unanswered question: the target was
  parked, its claim released and its worktree deleted — discarding a complete,
  committed fix so the whole thing had to be built again from scratch, often
  over a few lines. `/fix` now decides on **facts it can check** — does the
  worktree exist, does it hold a commit ahead of the base, and is it clean? —
  rather than on the name of the escalation, and it spells out every
  combination of those three readings in a single table so no state is left to
  judgement. A commit **and** a clean tree **resumes in place**: it keeps the
  worktree and the claim, hands the findings to the same worker, and carries
  on through the usual gates. Every other state parks, and the worktree is
  deleted only once the tree is **confirmed** to hold neither a commit nor
  uncommitted edits — a dirty tree is kept whatever else it holds, and so is a
  tree the check could not read at all — with its path reported on the issue,
  so parking can no longer quietly destroy work.
  The same table now also gates the *other* half of the hazard: **starting** a
  drive force-clears the worktree just as deleting it would, so every path
  that re-enters a drive — answering the parked question, answering an issue
  that arrived already carrying an open question, adopting an issue whose PR
  vanished, overriding a dependency block — reads the table first and resumes
  against the preserved build instead of rebuilding over it. Resuming also has
  to re-take the board claim that parking released, and that can lose a race to
  another session that picked the issue up in the meantime; if it does, `/fix`
  stops and reports the owning session and the path to the preserved build
  rather than driving on unclaimed or taking a claim that is not its own. And
  the comment `/fix` leaves on a parked issue now says which of the two will
  happen, so it can no longer point the operator at the action that throws the
  work away.

- **The reviewer-routing fix now covers `/fix` and `/sweep`, not just `/build`**
  (#1992). #1982 stopped the reviewer-routing table being copied back out of
  the build machinery — the caller reads the file and hands its contents in
  instead — but only `/build` was updated to do so. `/fix` and `/sweep` drive
  the same machinery and were still on the old, unreliable copying path, so the
  same three mangled shapes (empty, a sentence describing the table, tabs and
  line breaks turned into literal backslash characters) could still stall a
  change with no review having run. Both now read the table themselves and pass
  it in. This matters most for `/sweep`, which runs unattended by default —
  there the stall happens with nobody watching. If the file cannot be read,
  both omit it and the existing fallback path stands, so neither ever stops on
  this. **No routing behavior changes** — the same table produces the same
  reviewers.

- **`state-graph.sh soak` no longer manufactures a standing false
  disagreement for a status-drift finding kind `reconcile.sh --status`
  cannot report** (#1996). `_sg_query_status_drift` emits three finding
  kinds; only two have a counterpart in the `--status` lens the soak
  compares against. The third, `claimed_not_in_progress`, has its real
  counterpart in reconcile class (m) `PARKED claim stamps on OPEN issues` —
  which lives in `label_reconcile_main`, the `--labels` lens `_sg_soak_run`
  never invokes — so every parked-but-stamped item landed in
  `only_in_drift_query` and could never agree. That is not a corner case:
  the kernel's own "Park, don't abandon" flow produces the residue every
  time (`board_set_status` moves an issue off In Progress without clearing
  its claim stamp; only `release.sh` clears it). The soak now gates the
  comparison **per finding kind** and records the excluded kinds by name in
  each class entry's new `not_covered_kinds` field — the per-kind analogue
  of the class-level `"not-covered"` literal `unlinked-prs` /
  `orphan-worktrees` already read, and never a silent narrowing.
- The other two options #1996 listed were rejected on the record:
  narrowing the **query** would delete a true drift finding that
  `query status-drift` and `_sg_query_resume` both consume, and widening
  the soak to **also invoke `reconcile.sh --labels`** would add a second
  reconcile invocation and a second report-shape parser — more divergence
  surface in the one place divergence *is* the bug, the same reasoning
  #1980 round 3 — the stale-claims counterpart gap — rejected its analogue
  for. The reasoning is recorded beside the code
  (`_SG_SOAK_STATUS_DRIFT_KIND_COUNTERPART`) together with the
  kind-by-kind audit, and a test fails if a **fourth** kind is ever added
  without being dispositioned against what `--status` can emit — this is
  the third time this mismatch shape has been rediscovered.
- Run records stay at `schema:2` deliberately: this adds a field and
  narrows what `drift_query_set` contains, but does not change the
  per-class shape `soak --count` keys on, so the fourteen-day independence
  count is **not** reset a second time.

- **A `/build` pre-push review agent that hangs can no longer stall the whole
  level** (#2003). The reviewers picked for a change now run concurrently under
  one wall-clock ceiling (`BUILD_REVIEW_AGENT_CEILING_SECS`), with a progress
  notice first at `BUILD_REVIEW_AGENT_SLOW_SECS` so a genuinely slow review is
  visible rather than indistinguishable from a stuck one. A reviewer still
  unreturned at the ceiling is abandoned: an **advisory** one degrades to the
  documented `skipped — <agent> unavailable` notice and the run carries on, and
  a **required** one escalates to the human instead of silently marking the
  review passed. Previously a single reviewer that never returned kept every
  later reviewer from launching at all — including the required review of a
  change to a command spec under `claude/commands/` — and the run went quiet
  with no review verdict ever reached, which looked exactly like a review still
  in progress.

- **A too-long PR body no longer fails the build at its very last step** (#2009). `workflows/scripts/build/pr.sh` assembled the PR body and handed it straight to `gh`, and GitHub rejects a body over 65536 characters (`GraphQL: Body is too long`) — so an item whose worker, reviewers, quality gates and push had all already succeeded could not publish its result: the branch and commits were safe, only the PR failed to open, and an unattended run parked finished work. It happened to two items in one day, both recovered by hand. `pr.sh` now bounds the body locally before calling `gh`. The bound is a new setting, `BUILD_PR_BODY_MAX_BYTES` in `workflows/scripts/build/build.config.sh` (60000 bytes by default — below GitHub's limit, with headroom for the `Closes #N` linkage and attribution lines that follow). Over the bound, truncation runs in a fixed order: verbatim reviewer prose first, oldest review round first, then the newest round's prose tail, then the middle of the verification surface with its head and tail kept. The unit is a whole review round, not one reviewer's block — a round that routed three reviewers renders three blocks and they go together — and in the newest round every reviewer name and finding heading is kept even when its prose is trimmed, so a carried-over finding is never silently dropped. The `Closes #N` lines, the `## Acceptance` checklist, the `## Verification` section and the attribution footer are never cut. Every cut leaves an inline marker in the body naming what went, how many rounds and bytes, and where the full text can still be read. `pr.sh open --body-only` prints exactly the bounded body, so the preview and what is sent cannot disagree, and a body under the bound is passed through byte-for-byte. The `PR_OPENED` / `EXISTS` / `BODY_UPDATED` outcomes carry a new `body_truncated_bytes` count, normally 0.

  Where one review round's prose ends is decided by the producer, not inferred from the text. `reviewBodySuffix()` in `claude/workflows/build-level.mjs` now opens each reviewer's block with an explicit `<!-- 3e-review-block reviewer="…" round="N" -->` delimiter — invisible in rendered Markdown — and `pr.sh` matches that token exactly, at line start, consulting no heading. Reviewer text is spliced verbatim and routinely contains `### ` headings of its own, so any Markdown-shaped boundary is spoofable by ordinary prose: a bare `### Notes` was enough to mint a phantom round and make the newest round's carried-over findings droppable. Any occurrence of the delimiter inside spliced reviewer text is neutralized before splicing, so quoting it in a review cannot forge a boundary.

  This composes with the review-round bound added in #1970, which carries unresolved review findings into the PR body instead of looping another review round: the fix that reduces review rounds is also what raises body pressure, which is why reviewer prose is dropped oldest round first and the newest round — where a carried-over finding lives — is trimmed only after every older round is gone.

- **`/fix` no longer drops the open-question flag off an issue it turns out it
  cannot drive** (#2012). When `/fix` asks you about an issue's open question,
  it clears that question's label the moment you answer — and then re-checks
  the saved build before driving. If that check says the build cannot be safely
  driven over (it holds edits nobody has committed, or the check could not read
  it at all), `/fix` stops. Previously it stopped there and only reported, so
  the issue went back into the pool with its open question no longer recorded
  anywhere, and the next run picked it up as if the question had been settled.
  It now runs the same parking sequence every other stop uses: your answer and
  the saved build's path go on the issue as a comment, and the open-question
  label and assignment go back on. `claude/commands/fix.md` states the sequence
  once and every stop points at it by name.

- **A build item whose push succeeded but reported no head SHA is no longer
  reported as a failed CI run** (#2014). `/build` pins its CI poll to the
  commit SHA the push reported; when that value never arrived, the poll was
  handed the literal string `undefined`,
  `workflows/scripts/build/ci-poll.sh` refused to run on it, and the refusal
  came back as the `ci-failed` escalation — parking or re-driving a pull
  request that was open with its checks still running. The driver now checks
  the SHA before spawning a poll, on every path that can produce one, and an
  argument refusal escalates as `ci-poll-bad-argument`, whose disposition (in
  `claude/commands/build.md`) is to inspect the pull request rather than treat
  it as red. `ci-poll.sh` now marks every argument refusal with a
  `usage_error: true` field in its JSON output, so any caller can tell "the
  poll never ran" from "the poll ran and CI is red".

- **A build no longer stops — or loses committed work — because the reviewer
  routing table went missing in transit** (#2020). Choosing which review
  agents a change needs requires a small table of file-type-to-reviewer rules.
  On a caller that does not supply that table up front, the build reads it
  and passes it back through an intermediate step, and that copy has
  repeatedly arrived damaged or not at all. Three things change.

  The table is now passed back as a **list of its rows** rather than as one
  block of text. The same intermediate step has always carried the list of
  changed files in exactly that form, and that list has survived every
  observed failure that destroyed the block of text — so the table now
  travels the way the thing next to it already travels reliably. The block-of-
  text form is still accepted, so a caller or a stored result produced before
  this release keeps working, and the existing count and checksum still
  verify what arrives.

  When the table is still missing after one automatic retry, the build now
  **finishes on a reduced set of reviewers**, instead of stopping. Review is
  advisory here — it is not one of the checks that gate a merge — and it
  happens after the work is written, tested and committed, so stopping there
  abandoned a finished change over a step that was never allowed to block it.
  Only the rules that actually read the table are dropped: the rules decided
  from the change itself — above all the one that **always** requires a
  workflow review when a command document is edited — still pick their
  reviewer and still run it, so a missing table can never quietly turn a
  required review into no review. The pull request carries a plain line naming
  what was dropped, and the run summary counts the builds that reviewed on a
  reduced set, so a thin review section can no longer be misread as a clean
  review.

  And **whenever a build stops early, any commits it already made are pushed
  to the remote first**. Previously those commits existed only in a local
  working copy, and the cleanup path for a stopped build deletes that copy and
  its local branch; on one run that destroyed 515 lines of finished, verified
  work, recovered only by hand. The push happens at a single point every early
  stop passes through, so it covers every reason a build can stop, and the
  result — pushed, nothing to push, or push failed — is recorded on the
  stopped build's report so whoever cleans up can see whether a remote copy
  exists before deleting the local one.

  Two details of that rescue push matter to anyone reading its report. It goes
  to **the same remote branch the build's own pull request uses**, so a rescue
  after that pull request already exists adds nothing to the remote rather than
  leaving a second, orphaned branch that no pull request tracks and no cleanup
  ever reclaims. And **"nothing to push" is now reported only when the build
  could genuinely compare** the work against the branch it started from. On a
  repository whose main branch is named something other than `main` or
  `master`, and that records no default, that comparison is impossible — and it
  previously came back as a plain zero, so real unpushed work was reported as
  nothing to preserve, with none of the warning a stopped build otherwise
  prints when it cannot save your work. The build now pushes anyway in that
  case and says the comparison could not be made.

## [0.39.0] - 2026-09-13

### Added

- **The comparison report now carries inferential statistics on the quality axis, not just descriptive means** (#1609). Quality was two arm means and nothing else, while the cost axis got a bootstrap CI, an MDE and a verdict — so a future A/B claiming "quality +3%" was uninterpretable. `quality_comparison` now runs the **same `stats.sh` library** over the paired judge deltas (candidate minus baseline, in judge points), publishing the CI, the MDE, the observed standard deviation, and a **power projection**: how many outcomes judged in both arms would be needed to detect a difference of `MODEL_COMPARISON_QUALITY_TARGET_EFFECT_PCT`. On the #1656 A/A data that reads *132 judged pairs needed against 18 observed* — i.e. both validation runs were read against a 5% bar neither had the power to enforce, which is now stated on the report rather than left to be worked out by hand. **This axis mints no winner**: #1609 ships the statistics, and moving the verdict onto them is #1606 layered on top, so publishing an interval and deciding a comparison on it stay separable acts.
- **The quality axis publishes both of its bases and discloses when they disagree** (#1744). The arms rarely judge the same records, so a **paired** figure (judged in both arms) and an **unpaired** one (each arm's own judged rows) both exist and can differ materially — on the #1656 A/A run, −6.31% paired against −2.89% unpaired, **straddling the 5% A/A bar** on a run whose true effect is zero by construction. Publishing whichever happened to be computed is how a run clears a sanity bar on one quantity while reporting another. Both are now emitted, each labelled with its own record set, relative deltas computed against the baseline mean of their own basis, and a disclosure fires when they differ by more than `MODEL_COMPARISON_QUALITY_BASIS_DISAGREEMENT_PCT` percentage points. All statistics run on the paired basis, because a per-record delta exists only there.
- **An arm that judged nothing degrades the quality axis alone, not the whole report** (#1609). The relative-delta computation guarded its denominator (the baseline mean) but not its numerator, so a batch whose candidate legs are every one an integration-error record — no `judge` block at all — hit `null - 70` and aborted the entire derivation, taking the cost axis and every honesty disclosure down with it. The quality axis now reports null means and a named `statistics_unavailable_reason` while the cost axis pairs normally.

- **`batch.sh` can replay several corpus records at a time** (#1682). `--concurrency N` (default `1`, from `MODEL_COMPARISON_BATCH_CONCURRENCY`, clamped to `MODEL_COMPARISON_BATCH_MAX_CONCURRENCY`) runs up to N records concurrently, each record's two legs still sequential in their counterbalanced order. The cost of not having it was measured rather than assumed: the #1656 validation run took 29 min/leg, projecting **~27 hours for a 28-record comparison**, about a third of it not model time at all but the in-worktree `quality-gates.sh` run — enough to make the module impractical for the repeated comparisons it exists to support. Concurrency is deliberately **across records only, never within a pair**: #1571 stamps every leg with an `execution_order.position` that is meaningless if a record's two legs overlap, so parallelising inside a pair would silently undo that fix and re-open the arm-vs-position confound #1606 was filed against. Because the arm-order rule is a pure function of the record index, widening a batch cannot change *what* is measured — the same corpus and seed produce the same arm order and the same records in both arms at any N, and the summary's new `concurrency` block publishes the **measured** wall clock against the serial sum so the speedup is a number rather than a claim. The scheduler is a new module-local `batch-pool.sh` that borrows `lib/gate-pool.sh`'s mechanics (slot table, atomic done-markers, the `set -m` fork) but not its fail-closed gate verdict layer, its trap ownership, or its run-everything dispatch — all three of which a spend-bearing batch needs to differ; its header records why. One behaviour genuinely differs at N > 1 and the summary now says so rather than leaving it to be inferred: the **circuit breaker stops dispatch, not execution**, so records already running are allowed to finish rather than lose spend already committed, and `circuit_breaker.records_in_flight_when_dispatch_stopped` reports how many did. There is deliberately no `auto` width — the binding constraint is the provider's rate limit, which nothing local can read, and #1554's 28-leg outage happened on a strictly *sequential* run.

- **The order-effect decomposition now discloses whether it survives its own outliers** (#1741). `arm_effect` and `order_effect` are two **means** over a heavy-tailed cost-delta distribution, and the clean/not-clean verdict is a ratio between them — so the ratio is outlier-sensitive in a way nothing in the report admitted. On the #1656 A/A run the headline read `arm 6,596 / order 330,525`, a reassuring 50x that says *position is doing the work, not the model*. **Drop the single largest-|delta| record from each order group and it inverts to `arm 131,144 / order 47,696`** — the tidy near-zero arm effect was coincidental cancellation, and +131,144 on a run whose true arm effect is zero by construction is nearly the magnitude of #1262's false winner. A new `robustness` block recomputes the same estimator without those two records and states plainly whether the verdict flips. It is a **disclosure, not a gate**: it withholds nothing, changes no verdict, and says so — and a decomposition that *does* survive its outliers reports that positively, so the field is a finding rather than a permanent alarm. `comparable_rule` now warns that a near-zero arm effect can be cancellation rather than evidence of no arm effect.

- **Duplicate-entry lint on both governance manifests, plus a generalised
  two-manifest pre-claim contract** (#1801). `check-kernel-manifest.sh` and
  `validate-feature-docs.sh` (`DUPLICATE-CLAIM`) now each fail on a glob
  claimed by more than one manifest line — the residue a missed pre-claim
  leaves behind. The pre-claim convention is hoisted out of ADR-0000's
  ADR-only scope: any new-subtree pre-claim MUST add its claim to both
  `docs/features/feature-manifest.txt` and
  `workflows/scripts/kernel/kernel-manifest.txt` in the same change
  (canonical statement in feature-manifest.txt's header; ADR-0000
  § Manifest registration now defers to it). The two pre-existing
  kernel-manifest duplicates (`workflows/scripts/model-comparison/*`,
  `workflows/scripts/testbed/*`) are removed.

- **`build-level.mjs` reports a session-quota death as its own `quota-exhausted`
  escalation kind** (#1819), never collapsing it into `machinery-denied`/
  `SPINE_DENIED` (whose cure is rewriting the command) or a bare `worker-error`
  "agent returned null" (whose cure is re-driving from scratch — destructive,
  since a quota death usually leaves finished work intact in the worktree). The
  thrown-error-text shape is matched directly and carries the harness's reset
  time in the payload's `reset_time`; the bare-null shape — which carries no
  text at all — is classified by an agent-liveness canary (a classifier denial
  is per-command, a quota death kills every spawn), which re-probes on every
  bare-null and memoizes only a DEAD verdict — an alive reading is never
  cached, so a quota that dies late in a level cannot be misrouted through a
  stale early "alive". The payload states
  `worktree_left_intact: true`, and `claude/commands/build.md` documents the
  kind's wait-for-reset-then-resume disposition in the 3d-esc escalation-kind
  list plus an orchestrator-side `<failures>`-block cross-check.

- **`/fix` now probes native `blocked_by` edges before driving a target** (#1843).
  Step 2's state probe gains a dependency-block gate on the drive routes
  (`fresh` / `adopt` / `ambiguous`): `board_blocked_by_open` runs on the resolved
  target in the pipefail discriminating shape, and a target with open blockers is
  surfaced modally — blocker numbers named, with drive-anyway /
  drive-the-blocker-first / stop offered — never silently driven. An errored read
  is surfaced too, never treated as "unblocked." Aligns the third driving
  consumer with `/next`'s NX.3 skip and `/sweep`'s pool gate (#1835): the native
  `blocked_by` edge is the dependency-block representation. Both the new
  **blocked-stopped** stop and the pre-existing **epic-refused** stop (Step 3)
  now emit the Step 6 run-telemetry record with `--reported-no-op 1` — closing
  the absent-signal gap (the #1103/#1591 class) where a gate stop left no
  record the run happened at all.

- **`/build` Step 0.5 (resume reconcile) now records what it recovers** (#1908). A new
  `resume-recovery` raw-lake stream (`workflows/scripts/emit-resume-recovery.sh`,
  `meta/data/raw/resume-recovery-<YYYY-MM>.jsonl`) appends one record per
  `/build` resume that recovers or flags a Step 0.5 divergence — an orphaned
  worktree, a PR/sentinel mismatch, a self-claim reclaim, a workflow-journal
  `pr:`/`pushed_sha:` recovery, or a board/sentinel drift. This is a baseline
  instrument for the graph-of-record work; a `/build` resume is not a drive
  and never writes a `command-run`, so it gets its own stream rather than a
  new `command-runs` field. Presence-lint
  `workflows/scripts/validate-resume-recovery-emit.sh` (wired into
  `scripts/quality-gates.sh`) fails CI if the emitter disappears or its
  Step 0.5 call is removed from `claude/commands/build.md`.

- **Added the join-key registry** (`workflows/scripts/config/join-keys.tsv`),
  declaring every cross-stream join key the lake consumers use (session id
  forms, GitHub Actions run id, PR number, message id, plan-note stem) with
  its exact normalization rule and absent-versus-zero semantics, backed by
  one shell loader (`join-keys-lib.sh`) and one Python loader
  (`join_keys.py`) — the only two places a session id or other join key is
  normalized. `pr-linkage.sh`'s `Closes #N` probe now reads its
  closing-keyword pattern through the shared loader instead of restating the
  regex inline. A new config checker (`check-join-keys.sh`, wired into
  `scripts/quality-gates.sh`) lints the registry's structure and confirms
  both loaders agree on every fixture (#1910).

- **One ontology registry for the tracker and plan vocabularies** —
  ADR 0032 (ontology registry is source of truth); epic #1910 (graph-of-record
  ontology work), level 0.
  `workflows/scripts/config/ontology-registry.tsv` is now the single source
  of truth for the node types, edge types, the four state
  alphabets (issue-status `fnd:status:*` labels, plan sentinels, PR merge
  state + decision baton, the `issue-state.sh resolve` route enum) and the
  `source` axis naming every store the state graph reads. A new `checks` gate,
  `check-ontology-registry.sh`, scans the tracked tree for any `fnd:` label or
  plan sentinel the registry does not list (a shrink-only
  `ontology-grandfather-allowlist.tsv` absorbs adoption-day legacy tokens; the
  `x-` personal prefix is exempt), holds the route alphabet set-equal to
  `issue-state.sh`'s published enum, and fails a contract doc that drops its
  pointer or restates a vocabulary table. `ISSUES-ONLY-BACKEND.md`,
  `plan-schema.md`, `decision-queue-contract.md` and `work-class-policy.md`
  now carry a one-line pointer where each restated its table.

- **`state-graph.sh query <name> --board N` — five named queries over the
  derived state graph** (epic #1910, ADR 0033): `status-drift`,
  `stale-claims`, `unlinked-prs`, `orphan-worktrees`, and `resume`. Every
  query answers the literal string `"unknown"` for a part that depends on a
  source currently `error`/`stale`, never a bare empty result standing in
  for "nothing found". `resume` implements `/build` Step 0.5's authority
  ordering as a ranked merge (plan-note sentinel over workflow journal over
  git over board) and emits, per plan item, a route drawn from
  `ontology-registry.tsv`'s `state:route` alphabet — the same alphabet
  `issue-state.sh resolve` emits, now shared with both suites via one
  fixture (`tests/fixtures/state-graph-routes.json`). `/build` Step 0.5
  runs `build` then `query resume` beside the existing prose authority
  table for a soak comparison, non-authoritative at this level.

- **`state-graph.sh soak --board N` — the fourteen-day cross-check made
  mechanical** (epic #1910, ADR 0033): runs a fresh `build`, reads `query
  status-drift` off that same snapshot, separately runs `reconcile.sh
  --status` through a new overridable `_sg_reconcile` seam, reduces each
  side to a comparable sorted set of flagged issue numbers, and appends one
  `{day, drift_query_set, reconcile_set, diff}` record to a soak log kept
  through `lib/cache.sh`'s own path accessors (kind=`state-graph-soak`).
  Either set — and `diff` — reads the literal string `"unknown"`, never a
  false empty agreement, when its own side is degraded (a board-source
  error, or a failing `reconcile.sh` invocation). `soak --count --board N`
  prints the number of distinct days recorded; `soak --audit --board N
  --items <file>` logs a hand-audited item set against today for a human to
  compare against the mechanical diff. `bench --scale N` now also times
  each of the five named queries against its synthetic snapshot and appends
  one `{day, type:"bench", scale, query_ms, slow_queries}` record to the
  same log, naming the queries whose elapsed time exceeds
  `STATE_GRAPH_QUERY_SLOW_MS` at that scale.

- **Added a triples extractor over the registries and the raw lake**
  (`workflows/scripts/knowledge/triples.sh build|query`, #1910). `build`
  derives `{s, p, o, provenance}` records from the citation registry's
  `<!-- cite: ... -->` markers, the issue-touches/claims lake streams
  (session ids normalized through `join-keys-lib.sh`), and `docs/adr/*.md`'s
  own `## Status` supersession chain, appending them to the new
  `triples-<YYYY-MM>.jsonl` raw-lake stream (documented in
  `meta/data/raw/README.md`) — idempotently, so re-running `build` never
  doubles the lake. Every predicate is drawn from
  `workflows/scripts/config/ontology-registry.tsv`'s `edge` axis; an
  unlisted predicate is a hard error. `query cites <rule-id>`, `query
  touched_by <issue>`, and `query supersedes <adr-ref>` read the derived
  graph back.

- **`state-graph.sh build --board N`** derives one typed nodes+edges JSON
  snapshot per repo from exactly four sources — the board (`fnd:status:*`
  state and `claimed_by` claim-stamp edges), native `sub_issue_of` /
  `blocked_by` edges, open PRs (`closes` edges parsed from a bare
  `Closes #N` body line), and linked git worktrees (#1917, epic #1910, ADR
  0033). Every source is typed `ok`/`absent`/`error`/`stale`, never
  collapsed into an untyped empty result; the snapshot is written and
  invalidated through `lib/cache.sh`'s namespaced store (`kind=state-graph`).
  `clean --board N` removes one repo's snapshot; `bench --scale N` times a
  synthetic N-scaled build. Two new settings, `STATE_GRAPH_MAX_AGE_S` and
  `STATE_GRAPH_QUERY_SLOW_MS`, govern read-time staleness and the future
  query-speed threshold.

- **`state-graph.sh build --board N` now reads three HOST-LOCAL sources
  alongside the four `gh`/git-backed ones** (#1918, epic #1910, ADR 0033):
  `plan_notes` (approved/in-progress `Plans/` notes in the knowledge store,
  emitting `PlanItem` nodes with their sentinel state, `depends_on`/`after`
  edges, and `pr:`/`pushed_sha:` fields), `journal` (the Workflow runtime's
  `agent-<id>.jsonl` transcripts, emitting `Session` nodes with recorded
  step outcomes), and `tmux` (the per-window `@claimed_issue` claim marker,
  emitting `Marker` nodes and `marked_by` edges). Each is typed
  `ok`/`absent`/`error`/`stale` exactly like the original four sources — a
  host with no tmux binary or server is `absent`, but a reachable server
  holding zero claims is `ok`, never conflated with "nothing to report".

- **Added `/interview`** (`claude/commands/interview.md`, temperloop#1938): a standalone frontier-round interview that turns a topic, a knowledge-store pointer, or an issue number into a `## Shared understanding` section — the problem in the operator's words, facts the facilitator looked up itself, `D<n>` decisions in the operator's verbatim words where given, deferrals, risks — by asking the design tree's whole frontier each round through `AskUserQuestion` calls of at most four questions, recommended option first, the next call opening in the same turn as the previous answer. Designed as `/workshop`'s Phase-1 caller seam via the `--into` / `--first-question` / `--check-questions` parameter block (registered as one frozen row in `claude/presentation-plane.md`) — provisional, pending the workshop rewrite (temperloop#1958, `workshop-two-phase-rewrite`); until that lands `/interview` is hand-run only, and a hand-run lands the same section in `Context/<repo> - <topic>.md` with no brief created around it. Operator-present only.

- **Added the `INTERVIEW_PROBE_MODEL` setting** (`workflows/scripts/build/build.config.sh`,
  registered in `workflows/scripts/config/setting-registry.tsv`), naming the
  model tier for `/interview`'s fact-probe subagent — a `: "${VAR:=}"` seam
  defaulting to the same mechanical tier as `PIPELINE_DRIVE_MODEL`, so a
  personal or per-host override never touches the tracked file (#1938).

### Changed

- **The comparison's `winner` is now minted from the QUALITY axis; cost is descriptive** (#1606). The #1262 A/A run put the **same model in both arms** — so any winner is a false positive by construction — and the cost verdict minted one: paired delta −142,771 with a bootstrap CI excluding zero, ~80% of it cache_read volume, i.e. ordinary within-model variance in session length that a record-paired bootstrap reads as signal. #1741 then ruled out the obvious repairs: against the #1656 A/A deltas **every** robust estimator tested (trimmed mean, bootstrap median, sign test, Wilcoxon) minted a *confident false winner* where the raw mean correctly withheld, because the large outliers are the counterweight cancelling a tilt in the other 14 of 18 rather than contamination to discard. On that same known-zero data the **quality** deltas withhold under every one of those estimators and under all five per-dimension sub-scores. A winner now requires **three** independent conditions, any one of which withholds: the quality verdict names a direction, the run is at or above the sample floor, and the order-effect check **computed on the quality deltas** reads clean — never inherited from the cost axis, which pairs a different record set and can be clean where quality is confounded. The `winner` key keeps its documented location inside `comparison`, with a new `winner_axis` naming what decided.
- **The quality verdict is translated out of the statistics library's polarity** (#1606). `stats.sh` assumes **lower is better** — right for cost, backwards for quality. Confirmed against the library: `stats.sh verdict --deltas '[8,9,10]'` returns `baseline_better` on three deltas meaning the candidate scored 8–10 points *better*. Reading it straight through would have named the **loser** on every run. Both forms are published — `library_verdict` raw, `verdict` translated — with the delta array kept in quality polarity (positive = candidate better) so a reader can still re-run `stats.sh` over exactly what the report fed it.

- **`/check-in`'s environment-hygiene "acts" remedy no longer names `make install-kiosk`** (#1786). That worked example was a consumer-specific target being deleted downstream (foundation#1812); the remedy now leads with the consumer-neutral `launchctl bootstrap gui/$(id -u) <plist>` and refers generically to a checkout's own installer target where one exists.

- **`deploy-mini.sh` now auto-heals only cron/kernel-role checkouts** (#1828).
  Each checkout's role resolves through `env-reconcile.sh`'s role registry (the
  kernel's detection substrate, honoring `ENV_RECONCILE_CRON_CHECKOUTS` /
  `ENV_RECONCILE_OPERATOR_CHECKOUTS`); the mutating operations (HEAD switch,
  ff-merge, merged-branch prune, worktree prune) run only on cron/kernel-role
  checkouts. An operator/consumer-role checkout — or one in neither registry —
  gets its drift (non-main branch, dirty tree, behind-ness) printed on a
  `DRIFT (operator role — report-only)` line and is never mutated, conforming
  the session-start sweep to CLAUDE.kernel.md § Environment hygiene's
  aggressive-in-lane / report-cross-lane policy.

- **`cache.sh`'s path accessors and staleness/invalidation API now take an
  optional trailing `kind` argument** (`cache_repo_dir`, `cache_snapshot_file`,
  `cache_meta_file`, `cache_stale`, `cache_dirty`, `cache_clear`), defaulting
  to `issues` (#1910). A second store `kind` (e.g. a future state-graph
  snapshot) can now share `$CACHE_STORE_ROOT` with its own top-level directory
  and its own `meta.json`, without invalidating or clearing the issue cache.
  Every existing call site passes no `kind` and is unaffected.

- **The three separately-written graph traversals now share one library**
  (epic #1910, L0-a). `workflows/scripts/lib/graph.sh` (bash 3.2 + jq) answers
  `levels` (Kahn's-algorithm level partition), `cycle` (targeted BFS
  reachability, path-returning), and `reachable` (plain BFS) over one shared
  edge-list JSON shape. `plan.sh`'s toposort (previously an awk Kahn),
  `cycle-check.sh` (previously a hand-rolled bash BFS), and
  `sweep-pool-cycle-detect.sh` (previously a bespoke jq Kahn) are now thin
  wrappers over it — every caller's command line and output grammar is
  unchanged.

- **`validate-design-brief.sh`'s challenge-record completeness bar is now stamp-gated on frontmatter `record_grammar`, and `MISSING-WALK-VERDICT` retires** (temperloop#1938, `brief-validator-delta-rule`). A ratified brief whose frontmatter carries `record_grammar: delta` must now carry a `delta` stop line for every kernel dimension 0..16 (`MISSING-DELTA-VERDICT`, replacing the old unconditional `walk`-keyed check) rather than a `walk` line; a brief with no `record_grammar` field is legacy and exempt from the per-dimension bar entirely, whatever stop-line kinds its record carries. A new `delta`/`interview` stop line in a brief whose frontmatter lacks the `record_grammar: delta` stamp is flagged `RECORD-GRAMMAR-UNSTAMPED`, independent of `status`. `walk`/`walkthrough` stay valid, parsable kinds; `/workshop` Step 4.1c's ratify gate reuses the identical rule so the two can never diverge. **Compatibility:** legacy (unstamped) ratified briefs keep validating unchanged — only a brief that opts in via the `record_grammar: delta` stamp is held to the new bar.

- **`design-schema.md` gains a `## Shared understanding` section grammar and two new `## Challenge record` stop-line kinds, `delta` and `interview`** (temperloop#1938). `/interview`'s decisions (`D<n>`, verbatim operator words where given, facts found, deferrals, risks) now have a documented home at the top of a brief, ahead of dimension 0; the Challenge record's `dim-list` gains a `D<n>` decision-ref form for an `interview` line, and a `delta` line's `source` is always the literal `operator` — never a review lens, closing the fail-open gap a clustered `walkthrough` line would otherwise leave in the operator gate. § Record completeness documents the target rule for a stamped brief (`record_grammar: delta` in frontmatter): every kernel dimension needs a `delta` line, keyed on that frontmatter stamp rather than a ship-date constant (an earlier date-keyed draft, ADR 0036, broke a vendored adopter who kept ratifying walk-grammar briefs after the date; see the section's own provisional note). § Disposition grammar documents the `facilitator-drafted, not from interview` flag's required position — a line *after* the disposition line, never before it, since the validator reads the first non-blank line under a heading as the disposition. The Worked example now demonstrates the new grammar end to end.
- `workflows/scripts/validate-design-brief.sh`'s `CHALLENGE_STOP_RE` widens additively to parse the two new kinds and the `D<n>` dim-ref — **no change to the completeness bar**, which still requires a `walk` line per dimension pending a separate, dependent follow-on item; every pre-existing fixture and `test_validate_design_brief.sh` pass unchanged.

### Fixed

- **A green `validate-model-usage-emit.sh` run in CI now says which checks it did *not* run** (#1511). `meta/data/raw/*` is gitignored, so CI always sees an empty lake and always takes the legal-empty early return — meaning the **content** rules the script is named for (strict JSON parse, field shapes, model/provider enums, the no-cross-repo-identifier rule) never execute against a live record in CI at all. The early return was honest about what it did not *find*, and silent about what it therefore did not *check*, so a green run invited exactly the wrong inference. It now emits a `note` naming the skipped checks, stating that their CI coverage comes from the fixtures in `test_model_usage_emit.sh` and nothing else, and that a green run is not evidence about live record content. The note is **absent** when records were present, so it is a statement about the run rather than boilerplate. #1511 asked for a decision between "accepted gap" and "real gap": resolved as **accepted gap**, with the reasoning now in the validator's own header — a committed sample lake would be fixture data too, so it would relocate fixture coverage into a second file without validating a live record either. Live records are validated by an operator running the gate on a host that has done real replay work.

- **A comparison report no longer accuses itself of a wiring defect on every clean run** (#1534). `emit_coverage` collapsed three different situations into one hard `0%` under a disclosure asserting *"an emit-CAPABLE seat ran and did not write a record — a defect with a declared owner"*: an **unread** attribution stream, a **read** stream containing no emit-feasible seat, and the genuine defect. A standalone comparison always produces the middle case — `replay-candidate` and `replay-judge` are deliberately excluded from the numerator, so a run driving no `/build` pipeline work observes 0 of 3 seats *by construction* — so a reader following the report's own guidance concluded a defect existed every single time. The three are now distinct: an unread stream reports a **null** percentage with `unavailable_reason` naming the directory it could not read (an unread stream is not evidence of a wiring defect, and rounding it to zero manufactures one out of a missing file); a structural zero reports `zero_is_structural: true` with a statement saying the defect framing does not describe the run; and a real figure is unchanged. A new `lake` block publishes what the stream itself looked like — directory, files read, record count — so a reader can tell the cases apart without inferring. All existing disclosures remain on every run, per the issue's own constraint that unconditional honesty not be weakened to fix this; `below_100_means` now states its precondition rather than asserting a defect unconditionally.

- **`prompt_sha256` can now actually detect a prompt divergence between arms** (#1582). `replay.sh` embedded the per-leg worktree path in the worker prompt and hashed the result — and `$wt` is unique per leg by construction, so the hash **differed between the two arms of every pair, always**, even on byte-identical item content. Measured on the 2026-08-14 A/A run: **21 records, 0 identical hashes, 21 differing**. The field's one job, per its own comment, is comparability between replay legs; saturated at 100% noise it gave a **false negative on every genuine divergence** — a corpus record that changed between legs, a truncated acceptance list — while a reader who trusted the comment got nothing. The prompt is now rendered twice from **one generator**: once with the real path (what is **sent** — unchanged, since #1376 established that prompt prose plus the spawn cwd is how isolation is communicated) and once with a fixed `<REPLAY_WORKTREE>` token, which is what gets hashed. Sharing the generator is what keeps the hash sensitive: a change to the template text still moves it, as do title, scope, source and every acceptance bullet. The seam is documented where the field is defined.

- **The pre-flight fallback literal's "how low is it" figure no longer rots in config prose** (#1604). The block stated the literal was *"~1.49x LOW"* against a measured `699,963` from an n=14 batch. On this host it is now **~2.2x low on a 59-record basis** — the gap **widens** as the corpus grows, so a transcribed figure is stale the moment the next batch runs. That number is gone; the prose now points at where the live answer is published on **every** run (`replay.sh preflight | jq .observed_replay_cost`, plus `tokens_per_replay_basis` naming which figure is in force), and keeps the 2.2x only as a calibration datum with its provenance. The literal itself is **deliberately not retuned**: the block already argued that a second hand-transcribed constant would rot exactly as the n=1 one did, and that reasoning stands — the derive path is the fix, and this stays the honest unmeasured-host fallback. #1604's two fix directions both turn out to be **already built by #1555**: the derive-from-observed-records path, and a post-run drift nudge (`batch.sh`'s `spend_reconciliation` block raises `drift_alert` past `MODEL_COMPARISON_SPEND_DRIFT_ALERT_PCT` and prints a stderr notice, covered by tests S3/S4).

- **A truncated judge reply is now named, evidenced and retried instead of silently costing the run a quality row** (#1605). In the #1262 A/A run the judge returned a reply that **begins** as the contracted JSON object and is cut mid-string; it was classed `response-unparseable` — the same bucket as a judge that answered in prose — with only a head-300 excerpt, so an operator could not see *where* parsing failed, and there was no way to ask for another attempt. One lost judgment out of 56 flipped the whole batch to `BATCH_DEGRADED`. Three changes: a reply that begins as the contracted object is now `response-truncated`, a **distinct** diagnosis from `response-unparseable`; the notice carries the reply **length and TAIL** as well as the head (the head of a truncated reply looks perfect, which is exactly why head-only evidence was useless); and `MODEL_COMPARISON_JUDGE_MAX_ATTEMPTS` (default 2) retries a **reply-shaped** failure — truncated, unparseable, schema-invalid, or empty. A **structural** failure (no envelope, no usable `modelUsage`) is never retried: re-running cannot fix it and the attempt costs real spend. A recovered row carries `attempts`; a first-attempt row is byte-identical to before, so `attempts` means "this row was recovered" rather than a `1` on every record. Deliberately **no salvage** — reconstructing a score from a truncated rationale would fabricate a judgment the run never obtained.

- **The attribution validator now admits `model: "unknown"` on an unobservable spawn, and only there** (#1643). The emitter writes `usage_source: "unavailable"` with `provider`, `tokens` and `weighted_units` all null when a seat spawned and nothing about it could be observed — but it must still write *some* model, and the validator rejected the `unknown` sentinel it uses. Both halves ship in this repo, so one was wrong. **The epic settles it rather than taste**: #1225 Produces #1 requires "every kernel-spawned seat emits one record per run", and the emit-coverage percentage is computed from those records *existing* — suppressing one would hide the spawn rather than report it honestly. So the validator moved. The exemption is **narrow and discriminating**: the same `unknown` on a `cli-envelope` record still **fails**, because an observed call returned a real envelope, so a model *was* resolvable and the emitter failed to resolve it — a defect, not degradation. The rule is stated in `docs/features/telemetry.md` rather than living only in code. On a host with real replay history this takes `validate-model-usage-emit.sh` from **41 failures to 0**, and `test_model_usage_emit.sh` to 209/209 against the real lake.

- **The pre-flight spend gate no longer derives its per-replay cost from fixture output** (#1657). A stubbed replay emits a real attribution record into the same lake as live spend, carrying one hardcoded token block, and the derive filter keyed only on `seat` + `usage_source` — so on the host that surfaced this, **18 of 32 basis records were `recorded-stub-model`**, deflating the estimate 2.27x to a figure *further from truth than the 470,000 literal the derive path was built to replace*, while publishing a "DERIVED from this host's own observed records" provenance string that reads as a measurement. Records whose `model` matches `REPLAY_PREFLIGHT_STUB_MODEL_PATTERNS` are now excluded and **counted** as `excluded_stub_records_n`, and `tokens_per_replay_basis` states the exclusion, the count and the governing setting — or says positively that nothing was excluded. Measured on the real lake: basis **77 → 59 records**, mean **802,919 → 1,046,509**, and `spread_ratio` **913.59 → 17.79** — the 913x "observed spread" was almost entirely the gap between the stub block and real records, not variance the operator should have been sizing against. `REPLAY_PREFLIGHT_DERIVE_MIN_N` is applied to the **filtered** count, so fixture records can no longer lift a thin host over the floor. A denylist rather than an allowlist, so a new cross-vendor model is never silently excluded. The writer-side half — stubbed runs not reaching the production lake at all — is #1747 and is not fixed here.

- **A leg killed by the candidate timeout is recoverable instead of permanently stranded** (#1693). `--retry-failed` re-drives only `cannot-evaluate` legs, so an `integration-error` leg matched neither retry arm and fell through to `legs_done` — unrecoverable against its state dir, with no way to say "re-drive that one at a longer wall" short of discarding the whole batch. That conservatism is right for `envelope-parse` or `vendor-error`, where the candidate may already have run and been billed, but wrong for `candidate-timeout`, which is a leg cut off by **our own configured** `REPLAY_CANDIDATE_TIMEOUT_SECS`. The cost was concrete: on the #1656 A/A run 10 of 28 records lost a leg, and because a timed-out leg carries no token envelope the whole record dropped out of the paired set — 18 paired outcomes against a floor of 20, so the report returned `inconclusive` on sample size for a reason unrelated to what it was measuring. New repeatable **`--retry-stage <stage>`** names the failure class to re-drive (`batch.sh run … --retry-stage candidate-timeout`), leaving every other class protected exactly as today; the already-scored partner leg keeps its terminal state and is not re-spent, since the resume gate is per-leg. A stage name outside replay.sh's vocabulary is **refused with exit 2 and the valid list**, never accepted-and-ignored — a silent no-op there is indistinguishable from "there was nothing to retry".

- **The spend ceiling's stated real-terms loosening is corrected from ~5.4x to ~34x, and is now checkable** (#1710). The block above `REPLAY_PREFLIGHT_CEILING_TOKENS` exists to state the loosening plainly, and it stated it **~6x too small** — then contradicted itself six lines later. `5.4x` is `8,000,000 / 1,489,000`: the loosening of merely *reinterpreting* the old raw-token numeral in the new cost-weighted unit, **not** of the 50,000,000 actually set on the next line. The true figure, from the same block's own measured replay (`raw 2,506,371 → cost-weighted 466,530`, ratio `0.1861`), is `50,000,000 / 1,489,000 ≈ **33.6x**`. The section closes by telling an operator to lower the ceiling deliberately *"with those two numbers in view"* — so the wrong number was handed over at exactly the moment it was load-bearing, and understating a spend-ceiling relaxation is the wrong direction to be wrong in. The arithmetic is now spelled out inline, and a new check recomputes the multiplier **from the figures the block itself publishes**, so a future `SPEND_WEIGHT_*` retune or ceiling change that leaves the prose behind fails a test instead of misinforming someone.

- **`score.sh` no longer leaks a scratch directory per call — the mechanism was a subshell, not a missing trap** (#1724). The issue was filed with the mechanism deliberately unestablished, because the `trap _score_cleanup EXIT` at `score.sh:210` exists and is correctly wired, so the obvious diagnosis was wrong. The real cause: `scratch` is used as `x="$(scratch n.jsonl)"`, and **a command substitution is a subshell** — so the lazy `_SCORE_TMPDIR=...` assignment inside it ran in the subshell and never reached the parent. Two consequences, both invisible: the parent's variable stayed empty so the EXIT trap removed nothing, and every subsequent call found it empty and created **another** dir, so one `score` invocation leaked ~9 rather than 1. Pinned by an isolated repro — 3 calls → 3 dirs, parent variable empty, each call returning a path under a *different* directory. Creation now happens in `_score_ensure_tmpdir`, called directly (never inside `$( )`) once at the top of `cmd_score`, and `scratch` only reads the variable and fails closed. **Measured: one run of `test_replay_score.sh` went from leaking 174 dirs to 0**, and the 171,773 accumulated on the host took inode use from 56% to 1%.

- **A non-Anthropic candidate provider is now refused at preflight instead of writing a disclosure-log entry for a send that cannot happen** (#1743). `_CS_PROVIDER_TABLE` registers a key var for `openai`/`google`/`gemini`, but the live spawn is hardcoded to `${CLAUDE_BIN:-claude}`, which speaks Anthropic's API alone — so selecting a non-default provider passed preflight on the strength of a set API key, caused `replay.sh` to write a disclosure entry **attesting a cross-vendor send**, and then ran the Claude CLI anyway. The log whose entire job is truthful provider-exposure record-keeping (ADR 0028) was the thing producing the false record, and its pairing validator could not catch it: the allowlist↔log pairing was intact, it was the *send* that was fictional. The provider table gains a third **runner** column; an empty runner means "registered, but nothing here can run it" and `candidate_session_preflight` refuses — **before** the disclosure write, which `test_provider_runner_gate.sh` pins byte-for-byte on the log file rather than by reasoning about call order. The runner gate deliberately precedes the key gate, so an operator is never sent to supply a credential that was not what was missing. Per-provider *dispatch* remains unbuilt (spawn still execs `CLAUDE_BIN`), and a mutation guard fails the suite if a runner column is filled in without it. The gate is scoped to the **live** path via a new `preflight --execution live|recorded`: a `--candidate-runner` / `--judge-runner` IS a runner and never reaches a vendor, so refusing it would break every fixture while preventing nothing. Both call sites derive the mode from the same `$runner` the spawn dispatches on, so the gate cannot disagree with the path actually taken; an omitted `--execution` defaults to the strict gate, so a missed call site fails closed. The same fix covers **judge rotation**, which spawns through the identical seam — a rotated non-Anthropic judge was equally unable to reach its named vendor.

- **A stubbed replay no longer seeds the production attribution lake, and residue already there can be swept** (#1747). `emit-model-usage.sh` resolves its output dir from **its own location** (`raw_root="$here/../.."`), *not* from `--repo-root` — so a recorded run with no `MODEL_USAGE_RAW_DIR` wrote fixture tokens into the lake of whatever checkout the script lives in. 36 such records reached this repo's own lake on 2026-08-14, and three consumers read them as observed cost: the pre-flight derive basis priced batches off them (#1657), `validate-model-usage-emit.sh` rejected them on MODEL-ENUM and took `test_model_usage_emit.sh` down with it, and `test_replay_preflight.sh`'s verdict moved with the lake's contents (#1642). Because `meta/data/raw/*` is gitignored, **CI was always green on all three** — only hosts that actually run the harness went red, the inverse of where coverage is wanted. Three changes: `replay.sh` now **refuses to emit** on a recorded run with no explicit lake (a live run always emits — that spend is real), announcing the refusal rather than redirecting somewhere unnamed; new `lake-sweep.sh` removes residue already on disk, dry-run by default, keeping the original as `.pre-sweep-<n>.bak` and never dropping an unparseable line; and `validate-model-usage-emit.sh` reports a residue record as **`FIXTURE-RESIDUE` with the sweep command**, instead of as a bad model id that sends the reader to audit an emitter that is working correctly.

- **The attribution validator no longer rejects real models, and can express cross-vendor ones** (#1756). `validate-model-usage-emit.sh` gated `model` on a hand-kept family enum — `("opus", "sonnet", "haiku")` behind a required `claude-` prefix — on the premise that the family token is "the stable, enumerable part of a Claude model id". It isn't: **`claude-fable-5` is a real, current model this repo has replayed with, and all 14 of its records hard-FAILED a required gate**. The check was stricter than reality, so its failure mode was rejecting good data, and the reflex it trains ("the enum is stale, just add the family") is exactly wrong the day an id genuinely is malformed. Worse, the `claude-` prefix **cannot survive the module it guards**: epic #1225 exists to compare non-Anthropic candidates and #1743 adds the runner, so the enum would reject the attribution records of every cross-vendor comparison the harness was built to run. The check is now **structural** — lowercase alphanumeric segments joined by `-` `.` `_` or `/` — so `claude-fable-5`, `gpt-4.1-mini` and `meta-llama/llama-3` validate while `"Claude Opus"`, `"not a model"`, `claude-` and `x` still fail. The `unknown` sentinel gets its **own** `MODEL-UNRESOLVED` verdict naming #1643, rather than being swallowed into a malformed-id failure with a different owner and a different fix. Worth recording for the next reader: deriving the accepted set from configured model settings — this issue's original proposal — **would not have worked**, because `claude-fable-5` appears in no setting; it was chosen at run time via `--candidate-model`, and runtime candidate selection is the harness.

- **Leg state files are written atomically, so an interrupt can no longer turn a paid-for leg into an unrecoverable failure** (#1764). All five writes used a plain `>` redirect — truncate first, write second — and the resume path read the result with `jq ... 2>/dev/null`. An interrupt in between left a **torn file**, which parsed to no `.state`, matched none of the retryable arms, and fell into the generic failure branch: counted `legs_failed` with the reason *"no reason recorded"*, never re-driven by any resume, and potentially inconsistent with an arm file that already held the leg's record. A leg that genuinely **scored** — real money spent — could be reported as a knowable failure on nothing worse than a Ctrl-C landing in a millisecond-wide window. Not hypothetical: the #1656 run was killed by ENOSPC mid-flight and its 49 leg state files were all valid JSON *by luck*. Writes now go through `bd_write_state`, which writes a temp file in the **same directory**, parse-checks it, and renames it into place — so the only two states on disk are the old one and a well-formed new one. A torn file that is nonetheless found (an older state dir, or damage from elsewhere) is now reported under its **own** reason saying the outcome is genuinely unknown, is not re-spent by default because the candidate may already have been billed, and is recoverable through `--retry-failed` as a deliberate operator choice. Also satisfies **#1682 Produces #3**, removing one sub-unit from that parked epic.

- **`prune-merged-branches.sh` deletion now honors the `origin/main` classification it reports** (#1775). Previously a branch classified merged-into-`$base` could still be refused by `git branch -d` — which checks against HEAD, not `$base` — on a checkout whose local default branch is behind origin, silently under-deleting and mislabeling the refusal "skipped (in use / worktree-bound)". A `-d` refusal now escalates to `-D` only after re-confirming the branch merged into `$base` (tip is an ancestor of `$base`, or the merge-queue-safe helper confirmed its PR merged); an unconfirmed branch is still refused, and the in-use/worktree-bound skip is printed only when `-D` itself refuses — which git does only for a branch genuinely in use.

- **The `pending`-milestone workaround on the six retro trackers is unwound**
  (#1814, follow-up to the #1614 intake exclusion). The hand-applied `pending`
  milestone is cleared from trackers #851 #1346 #1361 #1396 #1576 #1598 (board
  write via `board_set_milestone`, precondition-checked per issue), now that the
  `retro-pending` process-record label exclusion keeps them out of `/triage`
  intake on its own. `/triage`'s inactive-milestone example no longer cites
  `pending` as a kernel-board milestone — `pending` is not a release phase, and
  citing it implied the superseded workaround. The `pending` milestone itself is
  left in place (other issues still carry it); `/build` 4d-retro already mints
  trackers with no milestone, unchanged.

- **`cache.sh` now paginates the per-issue comments fetch** (#1820).
  `cache_refresh_details` called `issues/<n>/comments` unpaginated, so any
  issue past GitHub's default page size of 30 comments was silently truncated
  in the durable corpus store (`details/<n>.json`). The fetch now uses
  `per_page=100` + `--paginate` (the same discipline as the bulk list fetch),
  and each record is stamped `commentsPaginated: true`; records written by the
  unpaginated code lack the marker and self-heal via a one-time re-fetch on
  the next details refresh, even when their `updatedAt` is unchanged.

- **`pr-enqueue --help` no longer leaks `set -euo pipefail` into the usage
  text** (#1821). The usage printer's hardcoded sed line range (`2,60p`) was
  off by one against the header comment block; it now prints the header
  structurally — every comment line after the shebang, stopping at the first
  non-comment line — so header growth or shrink can never re-introduce the
  leak. A regression test asserts `--help` ends at the header's exit-status
  lines with no trailing code line.

- **Raw-lake writers and the telemetry-brief reader now resolve the same
  directory by default** (#1822). `claim.sh`'s `CLAIMS_RAW_DIR_DEFAULT` and
  `capture.sh`'s `ISSUE_TOUCHES_RAW_DIR_DEFAULT` no longer pin the absolute
  `$HOME/dev/foundation/meta/data/raw` path — they resolve checkout-relative
  (git toplevel of the script's own resolved dir, then `meta/data/raw`), the
  same lake `telemetry-brief.sh` and `emit-issue-touch.sh` already resolve. A
  non-foundation checkout previously reported 0 claims and a fraction of its
  issue-touches (its own capture records all landed in the foreign pinned
  lake), and a bare kernel checkout silently grew a phantom
  `~/dev/foundation/` tree. Per-stream env overrides (`CLAIMS_RAW_DIR`,
  `ISSUE_TOUCHES_RAW_DIR`) still win when set; the deeper single-owner-of-
  resolution question for the issue-touches stream's two writers stays split
  to its follow-up, #1902.

- **Every claim-stamp derivation now routes through `board_own_stamp` /
  `board_host_label`** (#1823, completing #1220's centralization at 6/6 call
  sites). `issue-state.sh resolve` hand-rolled the stamp with no `:manual`
  arm, so a claim made by a session-id-less (manual) run read back as
  `by_me: false` / `claimed-elsewhere`; it, `release.sh`'s duplicate
  `release_own_stamp`, and `board-mirror.sh`'s two inline derivations now all
  call the single `lib/board.sh` owner, and a regression test covers the
  `<host>:manual` self-claim case.

- **`temperloop uninstall` now fails loudly when the manifest's `.paths` cannot
  be read, instead of reporting `done (no-op)`** (#1824). `manifest_load`
  validates that `.paths` exists and is an object — a malformed manifest
  (missing `.paths`, `null`, an array, or a string) is refused with a message
  naming the problem and a non-zero exit, so a manifest the build never
  actually understood can no longer read as "nothing was ever installed".
  `uninstall.sh` also checks the exit status of its `.paths` enumeration
  (previously discarded by a process substitution) as a second belt. A
  genuinely-empty `{}` paths object remains the legitimate no-op state.

- **The setting registry now validates that every setting name is a legal
  shell identifier** (`[A-Za-z_][A-Za-z0-9_]*`), and `temperloop config list`
  refuses loudly (exit 1, a `MALFORMED` diagnostic naming the row and its
  source file) when the kernel table or an operator-authored
  `setting-registry.overlay.tsv` carries an illegal name — e.g. hyphenated or
  leading-digit (#1825). Previously such a row slipped through
  `setting_registry_validate` and the `${!name}` indirect-expansion sites in
  `config list` silently dropped it while still exiting 0. Other
  malformations (unknown type/layer, bad op) keep the existing
  warn-and-continue best-effort union, but the diagnostics are now printed to
  stderr instead of being swallowed.

- **`milestone list` now exits 0 on a successful listing when every open
  milestone is active** (#1826). The inactive-section conditional
  (`[ -n "$inactive_out" ] && printf …`) was the function's last command, so an
  all-active board made a complete, correct listing return 1 — tripping any
  `set -e` caller. Printed output is unchanged in all three truth-table cases
  (all-active, mixed, all-inactive), each now covered by a fixture-replay test
  asserting exit 0.

- **`/build` no longer drops a CI-fix round's §3e review findings from the PR
  body** (#1846). The body suffix was rendered once at 3f from the original
  review round while the Step-6 tally merged every round — so a reviewer that
  ran only against the CI-fix diff (e.g. shell-reviewer on PR #1845, three real
  findings) was affirmatively omitted from the body's `ran:` line and
  `## Review notes`. `build-level.mjs` now renders both surfaces through one
  `reviewBodySuffix()` (the `ran:` line is the round-union of reviewers, every
  round's findings section is spliced — a repeat reviewer keeps both blocks,
  relabeled `(ci-fix round N)`), and a new 3g.5 step re-renders the open PR's
  body after CI resolves via `pr.sh open --update-pr <n>` — the same
  `assemble_body` path as create, backed by `gh pr edit`.

- **`issue_marker_probe`'s live gh fallback now verifies each search hit's
  body against the literal marker before returning it** (#1875). GitHub's
  `--search "<marker> in:body"` is tokenized, so a query for one marker could
  return an issue carrying a different marker sharing tokens (the
  #1849-vs-#1847 shape); an unverified hit made idempotency-guarded callers
  silently skip creations. The fallback now applies the same `grep -F`
  literal-body check the corpus path already used, so both paths agree on
  precision.

- **`/build` 4d's `emit-item-efficiency` step now passes every `build-level.mjs`
  invocation's wf id — comma-separated via `--build-run <WF[,WF...]>` — not just
  the initial one** (#1877). The bullet previously named "the wf_ id" (singular)
  of the invocation that drove the level, so on a level with 3d-esc
  escalation-continuation rounds each re-invocation's spend was structurally
  unattributed. The wording now matches `emit-item-efficiency.sh`'s own
  usage-header contract, and `test_item_efficiency.sh`'s prose-rot guard
  asserts the multi-invocation form so a drift back to a single wf id fails
  the gate.

- **A `/build` worker adding a new gate or validator script is now told to
  register it before running its own gate check** (temperloop#1931).
  Previously a worker could add a new check script without registering it
  anywhere the gate system would notice, so the omission surfaced only later,
  in the slower full-suite gate.

- **`/build`'s §3e.5 acceptance gate now runs on a worktree rebased onto
  current `origin/main`** (temperloop#1937). Previously a long-running or
  parallel-level item's worktree could fall behind `origin/main` by the time
  the gate ran, so a validator that ratchets against `origin/main` read rows
  main gained in the meantime as this item's own regression and lost a full
  gate round.

- **`/build`, `/fix`, and `/sweep` now print a dynamic launch/return line around every `build-level.mjs` Workflow invocation** (temperloop#1941), naming the caller, repo, item count, each item's slug and issue number, and the round number. Previously the only run-identifying text was the Workflow tool's static `meta.description`, so three concurrent drives — and a `/fix` single-item run in particular, which the wording claimed was "one dependency level" — were indistinguishable in the transcript.

- **The `/build` pre-push review's reviewer-routing table can no longer be silently dropped in transit** (temperloop#1976). The diff-fetch step's JSON result is hand-copied by a separate relay agent, and that relay has been observed dropping the (large) routing-table field while leaving the changed-file list intact, so the routing decision silently ran against an empty table and collapsed the reviewer roster to `docs-reviewer` alone. Previously nothing distinguished that drop from a worktree that genuinely ships no routing table, so it was never even retried. The diff-fetch step now also reports the table's own row count; a missing or undercounted table on a non-empty diff is retried once, and a still-incomplete table escalates instead of computing a roster from it.

- **`state-graph.sh soak` now compares PER CLASS instead of one flat set
  diff** (#1978). The soak is the one independent cross-check over the
  derived state graph (ADR 0033,
  `docs/adr/0033-derived-state-graph-composes-one-way-with-one-independent-cross-check.md`,
  which defines the query classes named below): it diffs the graph's own
  queries against `reconcile.sh --status`, a separately-derived view of the
  same board. Previously it compared the two as one flat set of issue
  numbers, so a hit that each side classified differently read as a
  disagreement even when both were right. Now each class is compared against
  its own counterpart — `status-drift` (issues whose board status label and
  claim state disagree) against reconcile.sh's status-label classes, and
  `stale-claims` (claims stamped to a session that is no longer live)
  against its claim-liveness classes. `unlinked-prs` / `orphan-worktrees`,
  which reconcile.sh never reports on, read the literal string
  `"not-covered"` rather than a false empty-set agreement.
- The appended soak record is now `{day, type:"run", schema:2,
  classes:{...}}`. A pre-existing flat-schema record (no `type` field) is
  excluded from `soak --count`'s day tally rather than misread as a
  per-class one. Practically: every day whose only record predates this
  rewrite drops out of `--count`, so the fourteen-day independence check
  restarts from zero and needs fourteen new `schema:2` days before it is
  trustworthy again — an expected reset, not a regression.
- The state-graph board source also now reads closed issues that still carry
  an `fnd:status:*` label (Done on the issues-only backend means closed with
  *no* status label) as their own residue nodes, so `status-drift` can flag
  that residue directly. This is scoped entirely to state-graph's own board
  source; `board.sh`'s `--state open` active-set convention is unchanged.

- **A `/build` worker whose item carries a class-A `activation:` block now sees
  its own reachability check spelled out verbatim in its brief**
  (temperloop#1934). Previously the worker never saw the check it would be
  gated on, so a correctly built and wired feature could still fail the gate
  over a name only the check's author had chosen.

- **The `/build` pre-push review's reviewer-routing table can now be corrupted in transit without being caught** (temperloop#1982) is closed. The temperloop#1976 guard only checked the routing table's row count, so a relay copy that reproduced a plausible-length table with the WRONG rows passed unnoticed — observed live: a diff touching four `.sh` files ran `docs-reviewer` alone, `shell-reviewer` never spawning, while the row-count check reported nothing wrong. The diff-fetch step now also reports the table's own content checksum, computed independently on both sides with no hashing primitive and, as of round 2, POSITION-SENSITIVE — each row's characters are weighted by their position in the table, not just summed, so a same-row-count row REASSIGNMENT (two rows trading reviewer/path columns, the exact shape of the live incident) changes the checksum instead of passing silently the way a round-1 commutative sum did. A row-count-valid but checksum-mismatched table is retried once and, if still wrong, escalates `review-diff-error` instead of computing a roster from it — exactly like a missing or undercounted table already did.

## [0.38.0] - 2026-08-27 — BREAKING

### Added

- **The kernel telemetry brief now reports epic funnel health class-
  conditionally** (`workflows/scripts/telemetry-brief.sh` § 2b, epic #1847
  "epic-as-metadata for operational work" Produces #9). A Foundational
  epic's healthy path stays epic → plan (assessed) → built, read from the
  existing `item-efficiency` per-epic merged-item rollup (`/build`'s sole
  emitter). An Operational epic's healthy path is epic →
  members-drained-via-sweep, with no plan-note step at all — read from
  `/sweep`'s end-of-run epic-closing gate tally
  (`epics_reviewed`/`epics_closed`/`epics_left_open` on the `command-runs`
  stream, which only ever covers Operational epics per the
  Foundational-wins mutual-exclusion guard). Plan-note absence on an
  Operational epic no longer has any path to reading as stalled-unassessed:
  each class is rendered from a stream only that class's machinery ever
  writes to. No new telemetry stream — both reads consume records already
  in the lake.

- **`/sweep`'s admitted Operational-epic members now get the same secret-seam
  scrutiny `/assess` gives a Foundational epic's members, before they can be
  driven at all** (epic #1847 (epic-as-metadata for operational work)).
  Phase 1's underspecification pass additionally scans an admitted member's
  issue body + acceptance text for a credential/token/DSN/API key the
  operator must supply on the host; one with no already-confirmed-set supply
  seam parks via `needs-clarification` rather than reaching Phase 2, at the
  same **confirmed-set, not merely location-named** bar `/assess`'s own
  host-config/secret-seam principle (foundation#716 (host-config/secret-seam
  principle)) uses. This is a pre-work static gate — Step 3's existing
  runtime host-config-deferral settlement (`isHostConfigDeferral`) remains
  unchanged as the merge-time backstop for anything Phase 1's text scan
  misses; the two compose, neither supersedes the other. Separately, an
  admitted member's worker prompt now carries its parent epic's own "group
  summary" as a `## Parent epic context` section (`build-level.mjs`'s new
  `parentSummarySection()`, gated on `item.parentSummary`) — plain
  singletons and ordinary `/build` plan items are unaffected and carry no
  such section.

- **`/sweep` can now optionally drain Operational-epic members, not just
  ungrouped singletons** (`SWEEP_ADMIT_OPERATIONAL_EPICS`, off by default;
  epic #1847 (epic-as-metadata for operational work)). With the setting on,
  a Ready sub-issue whose parent epic is labeled `Operational` — the
  established-pattern half of the Operational/Foundational work-class split —
  and carries no `Foundational` label anywhere in the group joins sweep's
  fix pool alongside singletons. Admission is re-checked live on every pool
  build: a single Foundational label anywhere in the group always wins, an
  epic with a plan note in ANY non-superseded status — under active
  `/assess` review, or already mid-`/build` or finished — is left alone
  (with a distinct reason for each case), and an epic whose member ordering
  triage never finished recording is refused rather than admitted on an
  unconsidered read. A genuinely mixed-class group is
  reported, never silently resolved either way. The setting is off by
  default, and a routine vendored config sync leaves the effective value
  unchanged. See `docs/features/sweep.md`.

- **`/assess` now refuses to decompose an epic that `/sweep` already owns**
  (epic #1847 (epic-as-metadata for operational work), item 5 of the
  mutual-exclusion pair). When the checkout-wide `SWEEP_ADMIT_OPERATIONAL_EPICS`
  setting is on, an Operational epic with no `Foundational` label anywhere
  in the group drains through `/sweep`, not through `/assess` → `/build` —
  running `/assess --epic <N>` on one now stops with a message naming the
  sweep path, `docs/features/sweep.md`, and the checkout-wide
  scope of the setting, rather than silently decomposing an epic two
  mechanisms could then double-drive. The autonomous pipeline driver's own
  `route-foundational` hand-off is exempted (it predates the sweep cutover,
  #1848 "pipeline-drive sweep-cutover rewiring"), and a new
  `--override-operational-refusal` flag lets an operator
  explicitly proceed anyway — the override is always logged, both as a
  comment on the epic and as a bullet in the written plan note.

- **`/triage` now stamps durable logical order between an Operational
  group's members as native `blocked_by` edges** (docs/adr/0031). At Step 4
  materialization, a genuine meaning-level precedence pair (never a
  merge-safety one) is written via the board adapter's `board_blocked_by_add`
  behind a script-backed cycle check (`workflows/scripts/board/cycle-check.sh`)
  that refuses any edge that would close a loop; each stamped edge carries a
  one-line rationale comment, and the epic receives an `edges-considered`
  marker once the sub-step completes (stamped, or legitimately none). The
  formerly-unqualified "edges never live on the board" invariant is narrowed
  accordingly — merge-safety edges and levels stay plan-resident and are
  still never stored — with the amended invariant stated once
  (`claude/commands/triage.md` § Operating principles) and pointed to from
  `/assess`'s recomputed-fresh line. `/triage`'s Step 3 requirements-auditor
  pass also now flags a group whose members carry mixed `Operational`/
  `Foundational` work-class labels at birth, before any stamping is
  attempted.

- **`/sweep` now reviews and offers to close fully-drained Operational
  epics at the end of every run** (epic #1847 (epic-as-metadata for
  operational work)). "Operational" is the established-pattern half of
  the Operational/Foundational work-class split (`claude/work-class-policy.md`).
  Once an epic's members admitted into sweep's pool
  have all reached a terminal state — every one of the epic's members, not
  just the ones this run drove — the parent is offered for close on an
  attended run (default: close), with a one-line closing comment pointing
  back at the run's report; a partially-drained epic is instead reported as
  progress, naming what's still open and, where known, what it's blocked
  on. An epic explicitly marked `keep-open` is reported but never offered
  for close, and that label is created on first use rather than assumed to
  already exist. On an unattended run a fully-drained epic's parent is left
  open, with one pending-decision entry recorded per epic ever (a re-run
  never posts a duplicate). A run that admitted no epics still runs the
  review and records a genuine zero. The tally (`epics_reviewed` /
  `epics_closed` / `epics_left_open`) rides the existing per-run
  `emit-command-run.sh` telemetry record as a purely additive schema
  extension, reconciled by its own independent accounting check. See
  `docs/features/sweep.md`.

### Changed — BREAKING

- **`/sweep`'s per-chunk merge pass now regime-selects member-bearing chunks
  before merging** (#1847 follow-on). A chunk containing at least one
  Operational-epic-admitted member (`SWEEP_ADMIT_OPERATIONAL_EPICS`) runs the
  mechanical `gate.sh risk` partition over its mergeable PR set before
  landing anything; a `RISKY` verdict is offered modally (an `AskUserQuestion`
  when attended, held with no auto-merge when operator-absent) rather than
  auto-merged, preserving the kernel merge-autonomy contract that only a
  clean, disjoint set is timed. A singleton-only chunk is unaffected — it
  skips the gate entirely and merges exactly as before.

- **The Operational/Foundational work-class labels widen from
  pipeline-driver autonomy policy to a pipeline-wide routing key** (epic
  #1847 (epic-as-metadata for operational work), docs/adr/0030). The
  sweep/assess partition now keys on the work-class label, not on epic
  membership: an `Operational` epic's members drain through `/sweep`
  (admission gated by `SWEEP_ADMIT_OPERATIONAL_EPICS`, default off), and a
  `Foundational` label anywhere in the group — parent or any member,
  evaluated live at every pool build — keeps the whole epic on the
  assess → plan → build ceremony path. Any consumer that read the labels
  as driver-private autonomy policy (the previous scope of
  `claude/work-class-policy.md`'s table) must now treat them as routing
  contract: mislabeling no longer only changes autonomy tier, it changes
  which pipeline drains the work. See
  `docs/features/operational-drain.md`.
- **Triage's edges-never-live-on-the-board charter is formally
  superseded** (docs/adr/0031, same epic). The old invariant — `/triage`
  forbidden to compute or store dependency edges, `/assess` recomputing
  everything fresh per plan note — is replaced by a narrower one: durable
  meaning-level order may live on the board as native `blocked_by` edges
  (stamped by `/triage` at materialization, Operational groups only, with
  a script-backed cycle check and an `edges-considered` marker sweep
  admission requires), while computed merge-safety edges and levels stay
  plan-resident and are still never stored. Tooling or prose that relied
  on the old charter's blanket prohibition must follow the amended
  invariant's single statement site (`claude/commands/triage.md`
  § Operating principles).

- **`work-class-policy.md` catches up to the Operational-epic sweep-admission
  machinery `/sweep`/`/triage` already ship** (epic #1847 ("epic-as-metadata
  for operational work")). The policy table's Operational autonomy path is
  now stated as `triage → sweep` (auto-merge per chunk once CI green;
  modal, never timed, for a correlated set — e.g. an
  epic-admitted member chunk `gate.sh risk` flags), not the stale
  `triage → assess → build`. The doc now also states explicitly that the
  work-class labels have widened from a driver-private setting into a
  pipeline-wide routing key (`/sweep`'s member-admission gate, `/triage`'s
  logical-order stamping both read it), and the `Foundational`-wins
  precedence rule is extended from per-item (a dual-labeled issue) to
  per-group (a mixed-class epic — one `Foundational` member refuses
  admission for the whole group).
- **`next.md` recommends `/sweep` for a triaged Operational epic** instead of
  routing every epic through `/assess`, matching the policy above.
- **`triage.md` and `sweep.md`'s pipeline diagrams now show the class-keyed
  partition** (Operational → `/sweep`, Foundational → `/assess` → `/build`).
- **`ISSUES-ONLY-BACKEND.md` documents the `edges-considered` marker, the
  `keep-open` label, and the durable-logical-vs-computed-merge-safety edge
  split** (docs/adr/0031) — vocabulary the sweep-admission and epic-closing
  gates already consume but that was previously undocumented outside the
  command specs themselves.

### Fixed

- **`/sweep` now honors native `blocked_by` for every pool item** (#1835).
  Step 1's fix pool previously ignored native GitHub issue `blocked_by`
  dependencies entirely — `/next`'s actionable-set build already dropped a
  Ready singleton with an open `blocked_by` edge, but `sweep` would claim
  and drive it anyway, risking a worker building against a base that
  assumed an unmerged blocker's fix. The pool build now calls
  `board_blocked_by_open` for every pooled item (member or singleton,
  forward-provisioned for epic-as-metadata's future Operational-epic
  admission) and defers any item with an open blocker — never co-chunked
  with, or driven ahead of, that blocker, and re-checked at every chunk
  boundary so a blocker that lands mid-run un-defers its dependents within
  the same sweep. The un-defer predicate is explicit and mechanized
  (`workflows/scripts/build/sweep-blocked-undefer.sh`): a blocker releases
  its dependents iff its issue is closed **and** its landing commit —
  resolved via the blocker's linked merged PR — is an ancestor of
  `origin/<default>` (`worktree.sh deps-merged`); a blocker closed with no
  linked merged PR releases its dependents (the ambiguity case), while a
  blocker whose own sweep disposition is `parked` never does. A new
  pool-level cycle walk (`workflows/scripts/build/sweep-pool-cycle-detect.sh`)
  catches a `blocked_by` cycle among pool members, which would otherwise
  defer every member forever with nothing ever explaining why, and the
  Step-4 report gains a blocked-frontier section (blocked item → open
  blockers, cycles called out separately, multi-run stalls noted via a
  durable comment trail on the issue).

- **The hook test suites no longer fail spuriously under load** (#1844). The
  `claude-p-spawn-guard` suite's `EVAL_RUN` case fed the hook through a pipe.
  The hook's `EVAL_RUN` arm exits before draining stdin — deliberately, so an
  unanswerable interactive `ask` cannot hang a headless eval run — which leaves
  the upstream `jq` writing into a closed pipe. Under the suite's `pipefail`
  that writer's status became the pipeline's, so the assertion measured `jq`
  rather than the hook and reported `EVAL_RUN exits 0 (got rc=2)` (`rc=141`
  locally). Because it is a race on the 64 KiB pipe buffer it fired only on a
  busy host, i.e. in the merge queue: it ejected an unrelated PR from the queue
  on a diff that never touched the file. Every assertion that measures the
  hook's exit status is now fed from a file, in this suite and in
  `test_write_lane_guard.sh` (which carried the same latent shape at both of
  its exit-status sites), and a structural guard fails if a future exit-status
  assertion in either suite is pipe-fed again — including through an indirect
  interpreter or with the `rc=$?` on the following line.

- **The exec-bit registry gate no longer fails a vendoring consumer for kernel
  rows naming content that consumer never adopted** (#1876). A consumer adopts
  a SUBSET of the kernel's hooks and scripts by design, so `claude/hooks/` in
  a downstream tree carries compat symlinks only for what it actually
  installed. `workflows/scripts/validate-exec-bit-registry.sh` inherited the
  registry+allowlist design from
  `validate-check-surface-degenerate-coverage.sh` but not the unadopted-row
  tolerance added to it in #1740, so the v0.37.0 vendor bump was red on
  arrival on 5 of 28 registered paths. It now tolerates such a row when
  **both** hold: the repo is a vendoring consumer (a repo-root `.kernel-pin`),
  **and** the row came from a kernel-owned source file. Each tolerated row is
  reported as a `note: … skipped (temperloop#1876)` line — never silently
  dropped.
- **`exec-bit-registry.overlay.tsv` is the new overlay-extension seam for the
  same gate** (#1876). A consumer's own directly-executable scripts now have a
  home that a subtree pull cannot overwrite, matching the
  `<base>.overlay.<ext>` seam `check-surface-registry.overlay.tsv` (#1738) and
  `setting-registry.overlay.tsv` already use. It is absent in a kernel-only
  checkout and its absence is never an error; an unreadable one is CANNOT
  EVALUATE rather than a silent pass. This is also what makes the tolerance's
  second condition real rather than vacuous: an overlay-authored row naming an
  absent path is genuine ledger rot and still fails `PATH-NOT-FOUND`, even
  under a `.kernel-pin`. The grandfather allowlist deliberately gets no
  overlay twin — it is a shrink-only ratchet, and an overlay copy would be a
  hole straight through it.
- **`PATH-NOT-FOUND` now carries a remediation line naming the adopted-subset
  case** (#1876), and explicitly warns off symlinking kernel content into a
  consumer to satisfy a row. That is the wrong remedy, and the analogous
  `WATERMARK-NOT-TRACKED` wording walked an operator straight into it — see
  temperloop#1840 for that incident.

## [0.37.0] - 2026-08-26

### Added

- **New `claude-p-spawn-guard.sh` PreToolUse hook — a bare `claude -p` in a
  Bash command now raises an `ask`** (#1836). A headless `claude -p`/`--print`
  spawn does not inherit the launching session's model; it resolves the
  *machine's* saved default, so a fan-out composed mid-run silently routes
  every worker to whatever tier that host was last set to.
  `validate-model-usage-emit.sh` §6e already covered committed `*.sh`; this
  covers spawn text composed at run time. It scans the **whole** command
  string, heredoc bodies included, so it fires on the heredoc that *authors* a
  `/tmp` fan-out script — before any spawn runs — rather than only on the
  leading command word. Command position is recognised after a separator, an
  assignment, a bare modifier, `sh -c`, and a short *named* set of
  argument-taking launchers (`timeout`, `gtimeout`, `xargs`, `parallel`).
  Quoting is tracked as one shell-accurate state, so a `;`, `&` or `&&` inside
  a quoted prompt is prompt text rather than a command break and the compliant
  `claude -p '…; …' --model …` form stays silent. That quote state gates flag
  recognition too — a flag-shaped word inside a quoted prompt is prompt text,
  so `claude -p "explain the --model flag"` still asks (it passes no `--model`)
  while `--append-system-prompt "always use -p mode"` stays silent (it passes
  no `-p`). The attached spellings `-p"hi"` / `--print'hi'` are recognised.
  `ask`, never `deny`; fails
  open; silent under `EVAL_RUN`. Its residual blind spots — a bare spawn inside
  an already-committed script invoked by path, one behind an unlisted launcher
  prefix, or anything launched outside the harness — are stated in the hook
  header and `claude/hooks/README.md`, and the two that can be pinned
  mechanically are asserted as silence tests rather than left implied.
- **New `test_hook_exec_bits.sh` hook check — every invoked hook must be
  committed executable** (#1836). `~/.claude/hooks` is a symlink into the
  tracked checkout and `settings.json` registers each hook as a bare absolute
  path, so a hook committed `100644` exits 126 on every matching tool call and
  silently never fires. No behavioural suite can catch that: they all drive
  their hook as `bash "$HOOK"`, which ignores the exec bit. This asserts the
  git index mode instead, deriving the sourced-helper exemption mechanically
  rather than from a hand-maintained list.

## [0.36.1] - 2026-08-25

### Fixed

- **v0.36.0's new `--model` gate no longer hard-requires an `AGENTS.md` at the
  CONSUMER repo root, which made that release unvendorable** (#1834). The
  #1829 assertion in `workflows/scripts/tests/test_model_usage_emit.sh` read
  `$REPO/AGENTS.md`, and `$REPO` is `$HERE/../../..` resolved with `cd -P`. In a
  composed overlay the *tests directory* is a real directory holding compat
  symlinks, so `$REPO` lands on the **consumer** repo root rather than the
  vendored kernel subtree — and nothing in the kernel contract requires an
  adopter to have a root `AGENTS.md` at all. foundation has `kernel/AGENTS.md`
  and no root copy, so its v0.36.0 vendor PR was red on arrival with
  `test_model_usage_emit: FAILED 1 of 213`; the sibling `claude/CLAUDE.kernel.md`
  assertion survived only because consumers carry a compat symlink for that one.
  A new `kernel_root_doc()` helper now resolves a kernel-root doc through
  `$REPO/<doc>`, falling back to `$REPO/kernel/<doc>`, and treats **neither
  copy present** as a hard FATAL so the assertions stay load-bearing rather than
  degrading to a silent skip. Applied to both `AGENTS.md` and
  `claude/CLAUDE.kernel.md`. Doc prose is untouched — this is a resolution fix,
  not a rule change. Known follow-up (#1838): the helper probes the consumer
  root *before* `kernel/`, which is correct against every adopter today but can
  retarget to a consumer's own root `AGENTS.md` if one is ever authored, and the
  new fallback/FATAL branches are not yet exercised by a test.

## [0.36.0] - 2026-08-25

### Added

- **Response-level grounding citations are now a registered kernel Capture/Backstop pair** (#1190).
  `CLAUDE.kernel.md` § Response-level grounding citations is the new capture half: an answer that
  knowledge-store content materially informed cites it inline (`[source: <note path>]`), and a
  context-dependent claim whose store query came back empty says so explicitly. `/tidy` Step 3
  § Missing grounding citations — which previously shipped as a backstop with no kernel rule to
  pair with — is now registered against it in `claude/commands/tidy.md`'s own kernel pairing table,
  so `validate-capture-backstop.sh` fails the build if either half goes missing. The scan adds no
  capture surface — no live instrumentation, no new ledger, no new lexicon tell: its input is
  confined to the one `Sessions/_inbox/` stub the drain has already opened (that stub's Step-1 scan
  report, its `## Transcript` section, and its own raw `.jsonl` via the Step-1.4 reach), and misses
  are recorded on the existing friction ledger. Because the scan report structurally carries no
  general assistant-response text, the step names candidate discovery explicitly as a routine
  assistant-turn skim of the stub body rather than a scan-report adjudication.
  `PROSE_BUDGET_TIER1_CAP` rises 347 → 351 to fund the four net-new kernel lines.

- **Work-class precedence: `Foundational` wins over a co-present `Operational`**
  (#1191). `claude/work-class-policy.md` now defines what the driver does with an
  issue carrying **both** work-class labels — a state no current writer produces
  (`capture.sh` and `/triage` both substitute rather than append), but one that
  pre-existing dual-labeled issues are still in. Such an item resolves
  `Foundational`, so `pipeline-tick.sh` gates it to the operator's decision queue
  (`route-foundational`) instead of routing it to autonomous drive: an ambiguous
  work class gets human judgment, never an autonomous merge. This is a **router
  precedence rule only** — no backfill and no mutual-exclusivity enforcement, and
  "exactly one work-class label" stays the authoring intent. `classify_item`
  already matched `Foundational` first; the rule is now stated at the definition
  site and pinned by a test asserting both label orders.

- **`plan-schema.md` § Optional `model:` field gains Carve-out (b) — silent
  failure mode** (#1286). An `S`/`M` `kind: code` item whose own failure mode is
  invisible to CI and to its own acceptance gates — a guard that can fail open, a
  detector that can fail to detect — now leaves `model:` absent (inherits the
  session model) instead of being stamped `sonnet`. The carve-out ships its own
  two-limb trigger condition, so `/assess` applies it uniformly rather than
  re-deriving the judgment per plan. The default S/M→`sonnet` stamp and the
  existing spec-prose Carve-out (a) are unchanged; the K#671 anti-pattern note now
  names a carve-out in this section as the *only* sanctioned route to a tier
  deviation, keeping inline per-plan exceptions discouraged.

- **`/build` now reports each level's composition and disposition in its own
  transcript, so `/workflows` is no longer the only progress surface** (#1310).
  Three blocks per level, printed by the orchestrator: a **launch roster**
  (new § 3-launch) before the level is driven, naming every item with its
  sentinel, issue ref, `kind`, stage and the 3a–3h step it enters; a **gate
  disposition roster** (§ 4a) that accounts for every item in the level rather
  than only the `[m]` merge set, so an item that merged as-you-go, captured a
  `[v]` verdict, was skipped or is still escalated no longer vanishes from the
  one block a reader sees at the level boundary; and a **close-out roster**
  (§ 4d) after the gate's writebacks, naming what actually happened to each
  item plus what comes next.
- **`plan.sh roster` renders those blocks** — a new subcommand of
  `workflows/scripts/build/plan.sh` (#1310). Rendering them in code rather than
  narrating them makes the guarantees structural: the row set is generated from
  the level's own membership so a row cannot be dropped, the header counts are
  derived from the rows rather than restated beside them, an unresolvable value
  is named (`no issue`, the report-only `[?]` marker) instead of inferred from a
  slug, and a roster that cannot account for the whole level exits non-zero
  (`ROSTER_INCOMPLETE`) rather than printing short. It reads the plan note the
  run already parsed and makes no `gh` call.

- **A denied action must now report every unblock path, grant first** (#1478).
  When a permission control refuses an action — the auto-mode safety
  classifier, a PreToolUse hook, a missing scope — `claude/CLAUDE.kernel.md`
  § Communication conventions now requires the operator-facing message to name
  all three paths in order: **grant the capability**, **run it yourself**,
  **drop or reroute it**. Previously the recurring shape was "here are the
  commands to run yourself", which silently picked the slowest option and
  quietly took a reversible policy choice — whether the session should hold the
  capability — away from the operator whose call it was. The message shape ships
  as the **denied-capability variant** of `claude/message-schema.md`
  § Degradation notice, extending that template's remedy-pointer slot rather
  than paralleling it; the same section records the deliberate call that this
  rule takes **no `/tidy` backstop**, since a denial leaves no durable artifact
  a drain could inspect. Reporting a denial honestly is explicitly not licence
  to re-attempt it in a different shape.

- **`/triage` Step 1 Adapter A gained a third naturally-excluded intake
  bucket: the process-record label filter** (#1614). A `Backlog` item carrying
  one of `TRIAGE_INTAKE_EXCLUDE_LABELS` (new setting, default: the
  `retro-pending` / `retro-info` process-retro tracker state labels `/build`
  4d-retro mints at epic close) is skipped from intake and reported on its own
  mandatory Step-5 summary line, alongside the existing inactive-milestone
  `deferred[]` and open-`blocked_by` `blocked[]` lines. These trackers are
  durable build-health *records* with no correct triage outcome — promoting
  one to `Ready` hands a build-health record to a `/sweep` fix worker, culling
  one closes a record its consumer still reads by label — so an exclusion, not
  a routing rule, is the right shape. The mechanical half is
  `workflows/scripts/build/triage-intake-exclusion.sh`, a side-effect-free
  classifier over the already-resolved board item list (zero extra REST calls,
  which is why it runs before its two per-candidate-REST siblings), covered by
  offline fixtures in
  `workflows/scripts/build/tests/test_triage_intake_exclusion.sh`.
  The invocation carries a **named failure path**: the classifier path is
  resolved dual-path and `-x`-tested (the shape Step 4.8a's `claim-guard.sh`
  already uses) with the run itself inside the guard, so a classifier that is
  absent **or** exits non-zero takes one explicit degraded arm — a `SKIPPED
  … intaken UNFILTERED` Step-5 line, `excluded[] = []`, and a refusal to cull
  or promote any candidate carrying an exclusion label. A missing script can
  never quietly degrade to unfiltered intake.

- **`pr.sh push` now reports a push that lands on a ref no open PR watches**
  (#1688). A new `PUSHED_UNWATCHED` outcome (non-zero exit) fires when the
  pushed ref has no open PR while an open PR for the same slug sits on a
  different head ref — the `build/<slug>` vs `fix/<slug>` split a worktree
  re-push falls into. It names both refs and classifies the cause
  (`stale_head_cause: "branch-mismatch"`), so the resulting "stale PR head" is
  distinguishable from GitHub's benign post-force-push head lag, which keeps
  the *same* ref. `build-level.mjs` escalates it as its own
  `push-unwatched-branch` kind rather than opening a PR or polling CI past it —
  the route by which a stale head's green checks become a false `CI_GREEN`. The
  ordinary push-then-open-PR path is unchanged (`PUSHED`, now carrying
  `pr_lookup`/`pr_number`), and an unavailable `gh` degrades fail-soft.

- **`Makefile` now routes to `shell-reviewer` in `/build`'s §3e pre-push
  review, and an unrouted changed path is now a reported figure** (#1705).
  `reviewer-routing.tsv` gains a third key shape alongside the extension and
  `dir/**` forms: a `**/<basename>` key matching that exact basename at any
  depth (never as a suffix, so `**/Makefile` cannot claim `NotAMakefile`).
  It is implemented in all three consumers of the table —
  `build-level.mjs`'s `reviewGlobMatch()` (the copy §3e actually routes
  through), `workflow-reviewer-coverage.sh`, and
  `reviewer-activation-coverage.sh`. `Makefile` was the 7th-highest-churn
  reviewable file in the repo (41 changes in 90 days) and had no extension
  and no directory prefix, so every one of those changes was pushed with no
  routed reviewer — on the file that decides what the gate set runs.
  `workflow-reviewer-coverage.sh` now also partitions the window's distinct
  changed paths into `routed_paths` / `prose_md_fallback_paths` /
  `unrouted_paths` (with `unrouted_path_examples`, and a matching text-mode
  line), so a path no rule matches is counted and named instead of being
  absent from the denominator entirely — the mirror of the reviewer-side gap
  #1446 closed. The next unrouted high-churn file shows up as a number
  rather than by someone reading the table by hand.

- **Every headless `claude -p` spawn must now pass an explicit `--model`, and a
  gate enforces it for the spawn sites that live in the repo** (#1829). A bare
  `claude -p` does not inherit the launching session's model — it resolves
  whatever default model the *machine* has saved — so a fan-out script composed
  mid-run silently routed its workers to an unintended tier, discarding the
  cost-tier choice `CLAUDE.kernel.md` § Subagent usage exists to make explicit.
  `validate-model-usage-emit.sh` gains section **6e**, the direct sibling of the
  existing generic emit net: any `*.sh` directly under
  `workflows/scripts/build/` whose comment-stripped body spawns a headless
  claude (a `claude -p` / `--print` invocation, or a `--output-format json`
  capture) must also carry a `--model`, or the `checks` gate goes red — caught
  by literal signature, never by having been enumerated in advance. The tier's
  value comes from a named `build.config.sh` setting, never a hard-coded model
  id.

  **Scope, stated honestly:** a repo-scanning net can only see spawn sites that
  live in the repo. The incident behind this change was an ad-hoc script written
  into `/tmp` and run once, which no validator would ever have seen; that case is
  carried by the prose halves alone (`CLAUDE.kernel.md` § Subagent usage
  cost-tier routing, `AGENTS.md` § Safety rails). A machine-level control — a
  `claude` wrapper refusing a bare `-p` — is deliberately out of scope. All seven
  files the issue flagged as invoking `claude -p` with no `--model` turned out to
  be comment/echo-string mentions rather than spawn sites, so the gate lands
  green; the disposition is recorded in section 6e's own header. Adopters:
  an overlay carrying a genuinely bare `claude -p` spawn under
  `workflows/scripts/build/` will go red until it passes the flag.

- **The macOS-vs-ubuntu CI slowdown is now measured and attributed to named
  gates** (#968, measurement phase only). `nightly-macos.yml` already published
  per-gate wall-clock on both legs; this adds a `Runner characterization` step
  to both (raw core count beside the pool's clamped width, plus process-spawn
  and filesystem throughput — asserts nothing, cannot fail the run), records
  five nights of both legs under
  `docs/validation/data/macos-ci-gate-timing/`, and writes up the verdict in
  `docs/validation/macos-ci-gate-timing.md`. `make macos-gate-timing-report`
  recomputes every table in that document from the committed data — zero
  network, and it refuses to print if a recorded file disagrees with the
  totals its own run reported.

  The finding: the gap is two independent multipliers — 3 workers vs 4 (a
  fixed 1.33x) and 1.36-1.71x more CPU-seconds for the same gates — whose
  product predicts the observed wall ratio within 0.05x on every night. The
  CPU half is concentrated: 12 of 180 gates carry 73% of a 1036s delta, 53
  gates are identical, and 15 (including `make shellcheck`) are *faster* on
  macOS. No reintroduction target is set and macOS is not restored to
  pre-merge gating; both are the follow-up's call.

### Changed

- **A host-config/secret acceptance criterion is now DEFERRED by the `/build`
  worker and verified parent-side by the orchestrator** (#1182). A worktree is
  populated from the git index, so a gitignored host-local file (a credential
  file, an operator-placed secret) is never carried into one — every worker read
  it as absent, on every host, always, and escalated `acceptance-incomplete`
  over a guaranteed false negative. The worker verdict schema gains a
  `deferred_host_config` field: paired with `passed: false` it marks the
  criterion deferred, which §3d treats as neither a pass nor a failure (a bare
  `passed: false` with no marker still blocks, unchanged), `park()` reports as
  `host_config_deferrals`, and `pr.sh` renders in the PR body so an unchecked
  box is not misread as a worker failure. **Every path that invokes the shared
  driver now carries its own parent-side verification seat**, because the worker
  instruction is ungated: `/build` §4a (the level merge gate — and §3h.5's
  as-you-go fast path is explicitly ineligible for such an item, since it never
  reaches §4a), `/sweep`'s per-chunk merge pass (verify before
  `gh pr merge --auto`; not-confirmed parks the issue instead of merging it),
  and `/fix` Step 5's one modal gate (the deferral rides that same single ask as
  a named state caveat). The `/assess` A.8 confirmed-set bar is unchanged — this
  moves who confirms, never whether — and the named file is still never copied
  into a worktree.

- **The provider disclosure log's watermark anchor is now committed to git**
  (#1316). The two-value anchor (`<max_seq> <last_hash>`) moved out of the
  gitignored `.temperloop/model-comparison/` runtime dir to a tracked file at
  `workflows/scripts/model-comparison/disclosure-log.watermark`, beside the
  committed provider allowlist. The **log itself stays gitignored**, so no
  provider history and no content enters the repo, and the anchor carries
  neither. `validate-provider-disclosure.sh` now also checks the live log
  against the anchor *as committed in git*
  (`WATERMARK-LOCATION` / `WATERMARK-NOT-TRACKED` / `WATERMARK-GIT-MALFORMED` /
  `WATERMARK-GIT-DIVERGED` / `REFORGED-VS-GIT`), so a full re-forge — which
  previously verified clean once the log and its on-disk anchor were rewritten
  together — must now rewrite git history too, which leaves its own trace.
  Commit the anchor when a run changes it; `pa_disclose` says so on stderr.
  New setting `PROVIDER_DISCLOSURE_WATERMARK_FILE` (fixture-test seam only).

### Fixed

- **`/tidy` § Contradiction detection now names an invocation `ks_search` actually
  accepts** (#1170). The step told the drain to run `ks_search` "scoped to
  `Decisions/` with a small `limit` (~5)", but `ks_search` accepts only `--limit`
  and `--partition` and rejects anything else with **exit 2 before any backend
  call** — so a session reaching for the implied folder argument
  (`--folders Decisions`) got a hard usage error, and the pass's degradation
  clause ("if `ks_search` is unavailable, skip") read that error as unavailability
  and silently disabled the whole cross-session supersession proposer. Step 1 now
  gives the literal call (`ks_search "<claim text>" --limit 15`), states that
  folder scoping is a **post-filter** on each result's store-relative `doc_id`
  rather than an argument, and the degradation clause now discriminates the exit
  codes: **exit 3** (backend unavailable) skips the pass, **exit 2** means the
  call was malformed and must be corrected and re-run, never skipped. The
  originally-reported site was `mcp__obsidian__search_vault_smart` with
  `folders`/`limit` written as top-level parameters when both live under `filter`;
  #1570's knowledge-store cutover had already migrated that site off the Obsidian
  MCP, but carried the same "names a parameter the tool does not take" defect
  across to the new transport.

- **`worktree.sh create` no longer loses a `.git/config` race when two items of
  one level start at once** (#1171). `git worktree add` writes the new branch's
  upstream into `.git/config` and git takes that lock without waiting, so
  concurrent creates — an ordinary `/build` level, a `/sweep` chunk at
  `SWEEP_FANOUT_WIDTH > 1` — failed outright with `could not lock config file
  .git/config: File exists`. Every config- and ref-mutating region of `create`,
  `remove` and `prune` now runs under one per-repo directory lock (portable:
  stock macOS ships no `flock`), so the losers queue instead of failing. A
  failed `git worktree add` is also rolled back now, so the `ERROR` outcome
  leaves no orphan `build/<slug>` branch to delete by hand and a naive retry is
  a clean create.
  A crashed `worktree.sh` no longer wedges the repo either: a lock whose owner
  process is provably gone is reclaimed at once, and one that never recorded an
  owner is reclaimed once it ages past `WORKTREE_LOCK_STALE_SECS`.

- **`/build`'s class-A activation gate (§3e.6) now actually runs on the default
  path** (#1219). `claude/workflows/build-level.mjs` — the default Step-3 driver
  since #998 — contained zero references to activation, and `activation` was
  missing from the Step 3 `items[]` args contract, so an item's `activation:`
  block never crossed the orchestrator→workflow boundary at all. Since
  `plan.sh` rule 14 hard-fails a product-source item that omits `activation:`,
  every such block was inert: an item could merge green with its feature
  dormant — a runner never registered, a flag never flipped, a rule nothing
  greps for — which is exactly what the activation-completeness contract exists
  to catch. `driveItem` now evaluates a `class: A` item's `proof:` predicate
  against the worker's worktree **between 3e.5 and 3f**, so a Fail loops back to
  3c instead of landing on an open PR, and an absence-asserting predicate gets
  the #944 merge-base control pass first — a proof that also passes at the merge
  base is reported vacuous rather than trusted. A control that cannot be
  *established* is its own outcome (`activation-control-unavailable`), never
  laundered into a pass. Items with no `activation:` block, or `class: B`/`C`,
  take a byte-identical path: the gate returns on its first line and spawns
  nothing.

- **`/triage`'s cull path no longer closes an issue another session is
  building** (#1220). The board claim is a cross-session lock, and the cull
  read straight past it: on 2026-08-08 a concurrent `/triage` closed an issue
  claimed 30 minutes earlier — with a green PR already open carrying its
  `Closes #N` — and stripped the foreign session's claim stamp as part of its
  own Done bookkeeping, silently orphaning the PR's issue linkage. A new
  `workflows/scripts/board/claim-guard.sh` partitions the cull set into
  `CULL` (unclaimed, or claimed by this session) and `SKIP` (a foreign
  `fnd:host/session:*` stamp), and Step 4.8a of the spec runs it before the
  first close write. A skipped candidate stays open, keeps its stamp
  untouched, and is named in the run report's new "Skipped (claimed by
  another session)" line. The guard issues no writes on any path, never
  blocks — a **stale** foreign claim reports and skips exactly like a live
  one, leaving disposal to `/tidy`'s stale-claim sweep — and fails **safe**
  rather than open, per candidate as well as per run: an unresolvable board, a
  pool that will not parse, and a candidate **missing from the resolved pool**
  (`board_item_list` reads only `--state open --limit "${BOARD_ITEM_LIMIT:-500}"`,
  so any board past that truncation drops issues out of it) all report
  `class=unreadable` and cull nothing. `claim=none` means a *matched* item
  carrying no stamp, never an empty lookup result.

- **A PR body's `## Acceptance` recap is now round-trippable** (#1267). `pr.sh`
  used to append each criterion's evidence inline after a bare ` — `, but that
  delimiter occurs inside real criteria *and* inside real evidence, so the only
  durable verbatim record of the acceptance contract a worker was handed had no
  unambiguous parse — a first-occurrence split silently truncated the criterion,
  a last-occurrence one ate the evidence. Evidence now rides its own nested line
  under the bullet, making the split positional, and the new
  `pr.sh acceptance-extract <bodyFile|->` reads a body back into its
  `acceptance_results` entries byte-exactly with no heuristic. GitHub renders the
  indented continuation as part of the same list item, so the body reads the same.
  `replay.sh corpus` consumes the new format through that extractor and keeps its
  last-em-dash workaround, and its `criterion-embedded-em-dash` flag, for bodies
  merged before this change.

- **The `make test-build-workflow` gate's K1071 step-ceiling case no longer
  depends on host load, and now ships a negative control** (#1335). The stalled
  step's verdict is read entirely off the bound's own structured result — the
  `STEP_TIMEOUT` payload plus the 137 (128+SIGKILL) exit status the driver acts
  on — rather than off a duration this harness measures, so a loaded parallel
  gate runner can no longer report a working watchdog as broken. To keep that
  from being a loosened bound, the case now also runs the same emitted shell on
  the same 60s stall body with **only the watchdog removed** and requires it to
  come out unbounded (no `STEP_TIMEOUT`, no kill); the rewrite that removes the
  watchdog is itself verified, so a control that silently stopped controlling
  fails the gate. A static guard pins the foundation#861 subshell-boundary
  redirect that the adjacent pipe-leak probe detects only by latency; it is
  anchored to the emitted watchdog line — first selecting that line, then
  requiring the redirect on it — so the prose comment that quotes the same
  redirect verbatim cannot satisfy it, and deleting the redirect from the
  emitted line alone turns the gate red.

- **`pipeline-spend-report.sh --run` no longer glob-expands against the
  caller's working directory** (#1393). The filter value is word-split
  unquoted so `--run a,b` yields two ids, which also exposed it to pathname
  expansion: `--run 'new-*'` selected a run when invoked from a directory
  that happened to hold a file named `new-007`, and selected nothing from
  anywhere else — the same command answering differently by cwd. The split
  now runs under `set -f` (restoring the caller's own `-f` state after), so a
  run id is always taken literally. Comma-splitting is unchanged in both the
  `wf_abc-123` and bare `abc-123` forms, and `--by-agent-type`, which routes
  through the same normalization, inherits the fix.

- **The Step-4a.5 combined-tree pre-check no longer false-fails under a
  symlinked `$TMPDIR`** (#773, #1678). `combined-tree-precheck.sh` built its
  throwaway worktree at the *logical* `mktemp -d` name, so on macOS — where
  `$TMPDIR` is `/var/folders/…` and `/var` is a symlink to `/private/var` — the
  gate suite ran with a cwd whose spelling differed from what any script inside
  it resolved with `pwd -P`. A test comparing the two spellings of the same file
  failed on string inequality alone, producing a `GATE_FAILED` for every
  multi-PR level; `/build` risk trigger (d) treats that verdict as unappealable,
  so batch merge was blocked and levels merged one PR at a time — leaving `main`
  transiently red whenever a level's members were only jointly consistent. The
  worktree root is now resolved physically before it is registered, added or
  used, so the whole suite sees one spelling and no individual test has to
  normalize defensively to survive this worktree.

## [0.35.3] - 2026-08-23

### Fixed

- **`validate-mandatory-step-signal.sh`'s pending ratchet now reads a
  symlinked ledger's *content* instead of its link target.** In a composed
  overlay the disposition ledgers are compat symlinks into the vendored
  `kernel/` subtree, and `git show <ref>:<symlink-path>` returns the link's
  target text — while exiting 0, so the script's `|| fallback` never fired. The
  base-ref side parsed to zero rows, every current `pending` row read as newly
  added, and the shrink-only ratchet false-failed on every run. The gate broke
  **on merge, not in the PR that introduced it**: the vendor that created the
  symlinks hit the bootstrap exemption and went green, and the exemption stopped
  applying once it landed — which took `foundation`'s `main` red and blocked
  every PR there. Both path seams are now physicalized before the ratchet math,
  and the vendored-kernel subtree arm from
  `validate-check-surface-degenerate-coverage.sh` (temperloop#1559) is ported
  across, so an upstream-owned row also passes when present in the kernel
  subtree's own pulled content. #1559 had fixed exactly this in one of the two
  sibling ratchets and not the other. The shrink-only intent is unchanged: a
  genuinely new `pending` row through a symlinked ledger still fails, and an
  unreachable subtree squash degrades fail-closed with an announced notice
  rather than reading as fully checked. Four regression cases cover the
  symlinked-ledger path, which the previous suite could not see because every
  fixture used a real file.

## [0.35.2] - 2026-08-23

### Fixed

- **`test_validate_mandatory_step_signal.sh` no longer reads real config while running against a scratch fixture** (#1755). Its `_run` helper pinned every config path inside the fixture root except the two overlay extensions added in v0.35.0, which fell back to the real `$SCRIPT_DIR/config/*.overlay.tsv`. Absent in a kernel-only checkout, so the suite looked green — but in a composed overlay the adopter's live rows were read against a scratch fixture root, and every one of their specs was reported missing. Six of its cases failed, none of them about the overlay seam. Both seams are now pinned, matching what the sibling `test_check_surface_degenerate_coverage.sh` harness already did, and a structural guard asserts that **every** `MANDATORY_STEP_*_FILE` seam is pinned inside `_run` — adding a third config file and forgetting it is exactly how this shipped.

## [0.35.1] - 2026-08-23

### Fixed

- **A kernel disposition row naming content a consumer never adopted no longer fails that consumer's build** (#1740). `validate-check-surface-degenerate-coverage.sh` and `validate-mandatory-step-signal.sh` both treat a row whose referenced path is absent as a stale row to prune. That is right in this repo — and wrong in a composed overlay, where an adopter takes a **subset** of the kernel's scripts and command specs. Foundation's vendor hit both: `SPEC-NOT-FOUND claude/commands/promote.md` (a kernel command it deliberately does not carry) and `SURFACE-NOT-FOUND workflows/scripts/dev/validate-clean-host-ks-search.sh` (a kernel dev helper it never symlinked).

  Both gates now tolerate such a row when **two** things hold: the repo is a vendoring consumer (a repo-root `.kernel-pin` — the same discriminator `validate-agent-charter-links.sh` already uses for "a consumer that did not adopt the review agents"), **and** the row came from a kernel-owned source file rather than an overlay extension. The row is reported as a note, never silently dropped.

  The second condition is the point: a row an adopter wrote **itself**, naming a file that is not there, is genuinely stale and still fails. Without that split the `.kernel-pin` would become a blanket mute, and real ledger rot would hide behind it. Pinned by test in both suites, alongside the no-`.kernel-pin` baseline where the same row stays red.

## [0.35.0] - 2026-08-23

### Added

- **A composed overlay can now disposition its OWN check surfaces and mandatory-step declarations, instead of having nowhere to put them** (#1738, #1740). `validate-check-surface-degenerate-coverage.sh` and `validate-mandatory-step-signal.sh` each read their registry and discovery ledger from a single path. In a consuming repo those are compat symlinks into the vendored `kernel/` subtree, so an adopter that owns a `validate-*.sh` or a command spec of its own had **no legal home for its rows**: editing the vendored copy is forbidden (the next subtree pull overwrites it), and replacing the symlink means owning a stale duplicate of every upstream row. v0.34.0 made both gates fail closed, which turned that gap into a hard block — foundation's composed tree reported 22 `UNREGISTERED-SURFACE` failures on a correctly-wired repo.

  Both gates now **union in an optional `<base>.overlay.<ext>` sibling** when present — `check-surface-registry.overlay.tsv`, `check-surface-discovery.overlay.tsv`, `mandatory-step-registry.overlay.tsv`, `mandatory-step-discovery.overlay.tsv` — the same seam shape the kernel already uses for `setting-registry.overlay.tsv` and `capture-backstop-registry.overlay.md`. Absent in a kernel-only checkout, which stays byte-identical in behaviour. Each is env-overridable as a test seam, and a present-but-unreadable extension is `CANNOT_EVALUATE`, never a silent pass.

  **The seam is not a debt parking lot.** The `pending` shrink-only ratchet now spans every disposition source rather than just the kernel half, so an overlay row is grandfathered from its own base ref but *growing* the overlay pending set still fails. Both gates' registry extensions are covered too, because registration is the only exit from `pending` and an adopter that could not register would be stuck there forever. The **allowlist deliberately gets no overlay twin**: §4a already holds that overlay-authored allowlist growth "is never a place to add a newly-discovered non-compliant surface".

  Failures now name the file a row actually came from, rather than hardcoding the kernel path and sending the reader hunting a row in a file that does not contain it.

### Fixed

- **`validate-agent-charter-links.sh` no longer reports zero charters in a composed overlay** (#1737). In a consuming repo `claude/agents` is a compat symlink into the vendored kernel subtree, and `find` does not descend a symlinked **start point** without `-L`. The `[[ -d ]]` guard above it *does* follow the symlink, so the two disagreed: the gate got past the "no agents dir" consumer no-op and fell into its "no `*.md` charters found" error path instead, failing a correctly-wired tree with 17 charters sitting in it. The walk now uses `find -L`, which also covers a symlinked individual charter. A new case pins the symlinked-directory shape — the one every consuming repo has, and the one no prior case covered.

## [0.34.1] - 2026-08-22

### Fixed

- **Two `KERNEL_GATES` suites added in v0.34.0 no longer fail in every consuming repo** (#1734). Both asserted things that are only true in the kernel repo's own tree, so a healthy composed tree went red the moment it vendored v0.34.0.

  `test_async_workflow_health.sh` case 13 asserted `nightly-macos.yml` and `install-tier2.yml` by name against "the real `.github/workflows` tree". The detector resolves its repo root from its own location, so through a consuming repo's compat symlink that is *that* repo's tree — foundation's holds only `ci.yml`, the detector correctly reported "no asynchronous workflows found", and the two assertions failed on a repo that was fine. The invariants stay unconditional (exit 0, nothing `UNREGISTERED`, no `STALE-ROW`, no synchronous workflow reported); only the per-file checks are now gated on the file existing, so they run exactly as before here and report the absence in a vendored tree. This is not a blanket skip — if `nightly-macos.yml` exists and stops classifying, the case still goes red.

  `test_argloop_trailing_flag.sh` excluded the three files that carry the fix idiom as example text using `^`-anchored, repo-root-relative paths. In a composed tree those live at `kernel/scripts/lint-argloop-shift2.sh` and friends, so none matched, all three were walked, and all three failed extraction (`FAILED 3 of 47`). The exclusion now matches at a path-component boundary (`(^|/)`) so the vendored copies are excluded too; it remains an exact three-path suffix list, never a prefix or glob, and the `T-CONTROL` case still goes red on a reintroduced `shift 2`.

## [0.34.0] - 2026-08-22

### Added

- **A red asynchronous workflow now reaches a surface someone actually reads**
  (#1297). Nothing surfaced a broken non-PR-triggered workflow, so a dead
  quality gate could sit on `main` for weeks — `nightly-macos.yml` was red for
  seven consecutive nights, and `install-tier2.yml` lost its only notification
  silently when its weekly cron was retired.
  `workflows/scripts/async-workflow-health.sh` classifies every workflow in
  `.github/workflows/` from its own `on:` triggers, reports each asynchronous
  one's **current** state (not just a red *transition* — both real instances
  were found while already red), and renders into the kernel telemetry brief's
  "1. Attention" section, which `/check-in` and `/telemetry` already render.
  `workflows/scripts/config/async-workflow-registry.tsv` records each
  workflow's disposition and **fails closed**: an unregistered asynchronous
  workflow, an absent registry, or a stale row all raise an alarm instead of
  going quiet.

- **`make doctor` now detects when the INSTALLED `~/.claude/workflows/*.mjs`
  has drifted from the checkout's own `claude/workflows/*.mjs`, instead of
  leaving it discoverable only by hand-diffing the two** (temperloop#1397).
  `/build` Step 3, `/sweep` Step 0.3 and `/fix` Step 3 all invoke the
  orchestrator by `scriptPath` at `"$HOME/.claude/workflows/build-level.mjs"`,
  so the INSTALLED copy is what executes — not the one being edited. Nothing
  compared them. Two live reproductions: 2026-08-10 (installed 153,468 bytes
  dated Aug 7 vs a repo copy of 169,056, 154 commits of machinery that never
  ran) and 2026-08-21, when an entire overnight run executed a six-day-stale
  orchestrator — including the batches that merged temperloop#1587's
  escalation-payload fix, whose payloads still showed the pre-fix
  contradiction because the installed copy never changed. Both were caught
  only because a session happened to diff by hand first. The existing surfaces
  structurally could not see it: `classify_entry()` compares a symlink's
  TARGET STRING and `check_cross_checkout_split()` compares PATH IDENTITY, so
  a correctly-targeted path whose CONTENT is weeks stale reads `OK` in both.
  The new `check_installed_workflow_drift()` compares CONTENT by sha256 (byte
  compare when no hasher is on PATH) and reports five distinct outcomes:
  `OK` (byte-identical, digest shown); `DRIFT`, which prints BOTH sizes, BOTH
  mtimes and BOTH digests, names which side is NEWER and by how much, and
  names the physical directory the installed copy really lives in; `ABSENT`,
  printed as its own outcome and explicitly neither drift nor in-sync, for a
  host that never installed; `UNKNOWN` for an installed path that exists but
  cannot be compared (dangling symlink, directory, unreadable) — indeterminate
  and non-zero, never a silent pass; and `SKIPPED` for a checkout shipping no
  workflows at all. `DRIFT` and `UNKNOWN` fail `make doctor`. It compares every
  `*.mjs` the checkout ships, not just `build-level.mjs`. **Detect and report
  only — it never writes to `~/.claude`**: installing is global shared state
  and a deliberately operator-run action, so the check names the remedy and
  leaves the decision to a human.

- **`workflow-reviewer-coverage.sh` now reports execution coverage for every
  routed reviewer, not only `workflow-reviewer`** (temperloop#1446). The gap in the
  mandatory pre-push review gate (`claude/commands/build.md` §3e) — temperloop#1387
  (routed reviews never ran) and temperloop#1430 (the gate moved into the
  driver) — stayed invisible for roughly a month because nothing measured
  whether reviews executed; temperloop#1450 (coverage measures execution, not
  prose) fixed that for one reviewer over one path class (command-doc PRs) — every other routed reviewer (`shell-reviewer`,
  `docs-reviewer`, `python-reviewer`, `typescript-reviewer`, …) still had no
  execution signal at all. For every merged PR in the window, the rollup now
  derives the reviewer SET `reviewer-routing.tsv`'s extension/path-glob axis
  routes for that PR's changed files (plus the in-prose
  `claude/commands/*.md -> workflow-reviewer` override), and checks each
  routed reviewer for the same machine-emitted evidence temperloop#1450 introduced —
  including its same-line skip-clause termination, generalized to every
  reviewer rather than only `workflow-reviewer`. `--json` gains a purely
  additive `by_reviewer` array, one row per reviewer in the tsv+override
  roster: a reviewer with zero routed PRs this window reports `routed:false`
  (nothing to review) and a reviewer that WAS routed but never documented as
  having run reports `routed:true, coverage_pct:0` — the two states are
  always distinguishable, and no routed reviewer is ever silently omitted
  from the table. Stays a reporting rollup, never a `checks` gate.
- A reviewer name from `reviewer-routing.tsv` is now escaped before it is used as a regex, and the coverage query's fail-open can no longer be silent. A name carrying a metacharacter made `jq`'s `test` throw, and the blanket `2>/dev/null || echo ''` rendered that throw as the all-zeros fallback — every count `0`, an empty `by_reviewer`, exit `0`: a false all-clear indistinguishable from a genuinely quiet window, on the one tool whose job is making an invisible gap visible. Because the pre-existing temperloop#1450 workflow-reviewer metric shares that single `jq` invocation, one bad routing row could take it down too. The fallback remains, but now prints what `jq` said and states that its figures measure nothing. Separately, an absent or unreadable routing table now warns that the per-reviewer roster is degraded and that other reviewers are **omitted, not measured as zero**. (temperloop#1446)

- **Declaring a pipeline step mandatory now requires shipping its execution
  signal in the same change, and CI enforces it** (temperloop#1448). A workflow
  spec could declare a step MANDATORY in prose while nothing observable proved
  it ever ran: `/build` §3e's command-doc reviewer pass read "mandatory" for
  ~a month while the default path structurally could not spawn a reviewer at
  all, and was found only when somebody wrote a coverage script after the fact.
  `claude/CLAUDE.kernel.md` § Mandatory-step birth rule states the contract and
  `workflows/scripts/validate-mandatory-step-signal.sh` enforces it, on the
  `validate-capture-backstop.sh` mold: every mandatory declaration in
  `claude/commands/*.md` is paired, in `mandatory-step-registry.tsv`, with an
  execution signal — a per-run tally, a gate-wired static guard, a runtime
  refusal, or a coverage rollup — and a HALF-PRESENT pair fails the build. The
  gate does not rely on anyone remembering to register: it enumerates every
  mandatory-marker line mechanically and fails any with no disposition, and its
  `pending` debt ledger is a shrink-only ratchet, so a NEW mandatory declaration
  cannot be parked as debt.

- **The degenerate-input check-surface registry stopped being opt-in: an
  unregistered check surface is now detected, not silently unchecked**
  (temperloop#1491). `validate-check-surface-degenerate-coverage.sh` gained a
  §5 **discovery pass** that enumerates the candidate set MECHANICALLY from
  the tree — every tracked file whose basename matches this repo's three
  check-script name families (`validate-*.sh`, `check-*.sh`, `lint-*.sh`),
  with `tests/`/`fixtures/`/`node_modules/` and a composed overlay's vendored
  `kernel/` pruned — and fails `UNREGISTERED-SURFACE` on any candidate that
  is in none of its three legal homes: the registry, the shrink-only
  allowlist, or the new `check-surface-discovery.tsv` disposition ledger.
  Silence is no longer a disposition. The ledger's `pending` set carries its
  own shrink-only ratchet (`PENDING-GREW`), so a newly discovered surface
  cannot be parked behind a one-line excuse instead of registered, and an
  enumeration that finds nothing fails `EMPTY-DISCOVERY` rather than passing
  vacuously. The registry's bulk growth — 4 registered surfaces to 21, with
  51 new fixtures in
  `workflows/scripts/tests/test_check_surface_degenerate_backfill.sh` — is
  the assertion's first OUTPUT, not the fix: a longer hand-written list is
  still a list somebody sampled. Of the 37 surfaces the enumeration found, 17
  carry a reasoned non-registration, three of them recording a MEASURED
  fail-open (`check-setting-prose.sh`, `check-gitleaks-kernel.sh`,
  `check-producer-egress.sh` each reported success on absent/unreadable/empty
  input) that needs its own fix before it can be registered.

- **`/assess` now audits plan sequencing for artifacts assumed to pre-exist untracked, and `/tidy` backstops it** (#697). New `claude/commands/assess.md` § Artifact-availability audit (Step 3) — **advisory, never a gate**, and run by `/assess` itself rather than a review subagent, so it still fires on a checkout with no review agents. It flags any plan-critical artifact on three tells — a session-scratch locator (`/tmp`, `$TMPDIR`, `…/scratchpad/…`), an untracked working-tree file, or no durable locator at all (consumed by an item, produced by none) — and resolves each hit into one of exactly two dispositions: stage the artifact durably (in-tree or in the knowledge store), or make authoring it from scratch part of the consuming item. Unresolvable hits ship as a `## Sequencing notes` bullet plus a new `artifact availability` row in the Step 5 `NEEDS ATTENTION` block. Its registered Capture/Backstop pair, `claude/commands/tidy.md` § Undurable plan artifacts, re-scans live `Plans/` notes for **all three** tells — the two textual ones mechanically, and the third by rebuilding the note's produces set from each item's `files:` / `acceptance:` and cross-referencing it against the artifacts items consume — and parks each finding on the pending-decisions surface for `/check-in`. Motivated by two observed near-misses that survived on sequencing luck alone (epic #606's "ADRs 0009/0010 are already authored (untracked)" against a clean tree; epic #671's L1 hand-off depending on a `/private/tmp/…/scratchpad/` draft) — a `/build` worker runs in a fresh, isolated worktree and inherits neither.

### Changed

- `/build`'s §3e.5 parent-side acceptance gate now runs **diff-scoped** — only the gates an item's changed paths can reach, resolved through `workflows/scripts/config/gate-paths.tsv`, the same map CI's `checks` job has used on the `pull_request` event since temperloop#1024. A full per-item suite could not survive within-level parallelism: a measured 3-item level spent 55 minutes and landed **zero** items, all three escalating `acceptance-gate-timeout` with every worker already finished and committed. N concurrent items meant N concurrent full suites, and the slice budget cannot absorb the contention because it is clamped by the executor agent's ~10-minute Bash cap. Typical single-file items now select 20–32 gates instead of 176. What gates the default branch is unchanged: the `merge_group` run of `checks` is unscoped and always runs everything. Set `BUILD_GATE_SCOPED=0` — in a config **file**, not the environment, which the hermeticity scrub erases — to restore the full-suite gate. (temperloop#1663)
- `scripts/quality-gates.sh` gained `QUALITY_GATES_SCOPED`, an environment twin of the `--scoped` flag, for callers whose only interface is environment variables. An older vendored copy ignores an unknown env var and runs the whole suite, whereas an unknown *flag* would exit 2 `usage` and read back to the caller as a gate **failure**. An explicit `QUALITY_GATES_SCOPE=full` beats a scoped request from either surface. (temperloop#1663)
- Sliced runs of a scoped suite are now selection-stable. `QUALITY_GATES_START_AT` is an ordinal into the gate list, and a scoped list is re-derived per slice, so a working tree that moved mid-run could leave the resume index addressing a *different* gate — silently skipping one while the suite still exited 0. `QUALITY_GATES_SELECTION_PIN` records slice 1's changed set for later slices to reuse, and a new `QUALITY_GATES_SELECTION=<count>:<digest>` marker is fed back as `QUALITY_GATES_EXPECT_SELECTION` so a drift that happens anyway restarts the run from gate 0 on the full set instead of resuming a stale index. (temperloop#1663)

### Fixed

- **`pr.sh open` no longer emits the issue-linkage block twice when a worker's
  verification surface carries its own copy** (temperloop#1023). Linkage lives
  in `pr.sh` alone, but the `## Verification` section is worker-authored content
  spliced in verbatim — so a worker that copied the block into its
  `.build-verification.md` produced a PR body declaring linkage twice (observed
  on PR #1019). `open` now strips from the spliced surface exactly the lines
  GitHub itself would honor *and* that can only duplicate its own emission: a
  whole line that is nothing but `<keyword> #N` / `<keyword> owner/repo#N`.
  Mid-sentence mentions, backticked and indented lines, and anything inside a
  fenced code block are left byte-for-byte intact, and the removal count rides
  the `PR_OPENED`/`EXISTS` outcome as `surface_closes_stripped` so the strip is
  observable rather than silent.

- **A stale tmux claim marker is now cleared automatically, in every window, and
  the window's name is un-frozen** (#1037). Nothing ever cleared the
  `@claimed_issue` marker that paints the `status-right` claim chip: `release.sh`
  is a manual same-window call the task workflow explicitly makes *optional and
  best-effort*, `reconcile --fix` repaired only the caller's own window, and the
  close→Done cascade never reached tmux at all. So a marker outlived its work
  indefinitely — observed live as one closed issue's marker branding all four
  windows of a session for over a month, the status bar asserting a claim that
  had not existed since the previous month. Three changes close it:
  **(a)** `reconcile --fix`'s marker lens now sweeps **every window on the tmux
  server** instead of just `$TMUX_PANE`'s, applying the *same* per-marker gates
  to each. GH #297 (a claim branding a concurrent session's window — the
  regression that pinned every marker *write* to the caller's own) is not
  reintroduced, because what makes a cross-window *clear* safe is the **proof**,
  not the ownership: an OPEN issue, an unreadable state, and a live same-host
  claim are each still refused, in every window, and there is no age-based or
  "looks stale" clear. Branding another window remains forbidden;
  `lib/claim_marker.sh` ships no targeted `set`.
  **(b)** The sweep no longer requires being *inside* tmux — the server is a
  socket, not an environment variable — so `/tidy`'s nightly now runs the marker
  lens with `--fix` and the repair happens without the operator noticing the
  drift and hand-running a command in each affected window. It is the one
  auto-applied repair in that step: unlike releasing a board claim, clearing a
  chip whose issue is provably CLOSED/MERGED touches no board state, no claim
  stamp and no work.
  **(c)** Every clear now also restores that window's `automatic-rename`, which
  `claim_marker_set`'s `rename-window` had turned off — previously the window
  name stayed frozen at the claim string forever. The restore *unsets* the
  window-local override rather than forcing `on`, so an operator who globally
  disabled it keeps their setting.

  Widening the sweep exposed a hazard that needed its own guard: a marker records
  `#<n>` but never which **repo** the number belongs to, and every board numbers
  into the same range, so a sweep of one board would misattribute — and wipe —
  a live claim's marker that came from another. `--fix` now refuses to clear any
  number that is a live In-Progress claim for this host on **any** registered
  board. Relatedly, `make test-board` now strips `TMUX`/`TMUX_PANE`/
  `CMUX_WORKSPACE_ID` from every test's environment, so a board test can no
  longer reach the operator's real tmux server whatever isolation seam it missed
  — the leak path that put a test fixture in the live status bar in the first
  place.

- **`pipeline-tick.sh`'s two optional-source guards are fail-open again** (#1132).
  The script is `set -euo pipefail` and sources `build.config.sh` and
  `../lib/command_declared.sh` behind `[ -f x ] && . x` guards so a checkout that
  vendors only a subset still runs. That form leaves the whole statement at exit
  status 1 when the file is absent — the guard whose job is to make the file
  optional is the thing that publishes a failure. Mid-file that status is
  survivable (bash suppresses errexit for a non-final `&&` operand, verified
  against the real script), but it is fatal the moment such a guard lands last in
  a file or a function, or an errexit caller sources the file, so the shape is a
  latent trap rather than a live one. Both sites now use the house `if [ -f x ];
  then . x; fi` form already used at `worklist.sh:50-53`, `gh-bench.sh:141` and in
  this file's own `read_ready_items()`. A regression test (`test_pipeline_tick.sh`
  test 33) pins the shape, demonstrates the terminal-position status difference
  between the two forms, and runs a lone copy of the script with neither optional
  file beside it through a full dry tick.

- **112 argument loops that spun at 100% CPU forever when a value-taking flag
  was the final argument are fixed, and the shape is now a build-failing lint**
  (#1342). Bash's `shift n` **fails** (`shift count out of range`) when `n > $#`,
  and a **failed shift does not shift** — the positional parameters are left
  completely untouched. So the ubiquitous
  `--format) format="${2:-brief}"; shift 2 ;;` inside `while [ $# -gt 0 ]`
  never terminates when the script is invoked with `--format` last: `$#` stays
  at 1, the same case arm re-matches, and the loop pins a core until something
  kills it. The `${2:-…}` default is precisely what makes it a **hang** rather
  than a crash — it removes the `set -u` unset-variable error that would
  otherwise have ended the loop, and these scripts deliberately run without
  `set -e`, so the non-zero shift is swallowed.

  **Blast radius, both halves live.** A hung script that *is* a `KERNEL_GATES`
  entry does **not fail** the gate — it burns the CI runner to the job timeout,
  so the signal reads as "slow", not "broken". Worse for the `emit-*.sh`
  telemetry family, whose own headers promise *"a telemetry emit must never fail
  or block the calling spawn site"*: a hang is strictly worse than the failure
  that contract exists to prevent, and the conventional `emit-… || true` call
  shape cannot save a caller from it — an unset trailing variable at a spawn
  site hangs the **spawn site** forever. `emit-item-efficiency.sh --slug` was
  confirmed hanging for >8s before being killed.

  **The sweep.** 112 sites across 26 files — the five `emit-*.sh` emitters the
  issue names, plus `promote/`, `probe/`, `drain/`, `build/`, `kernel/` and the
  telemetry/report scripts — now shift the **flag** first and the value only if
  one is actually there: `shift; if [ $# -gt 0 ]; then shift; fi`. No shift can
  be out of range, so no loop can spin.

  **The structural half.** `scripts/lint-argloop-shift2.sh` is a new static lint
  — fourth member of the family alongside `lint-bash32-ctlesc-ifs.sh`,
  `lint-bash32-cmdsubst-comment.sh` and `lint-pipe-grep-q.sh` — that fails the
  build on a `shift N` (N ≥ 2) reached inside a `$#`-conditioned loop with no
  preceding `$#` guard and a non-fatal `$2` expansion. A **lint** and not only a
  sweep because the defect was **independently re-derived in brand-new code**
  (`async-workflow-health.sh`, #1297) by a worker that had never seen the
  `emit-*.sh` sites: a sweep closes the instances, only a lint closes the class.
  Nothing already in the gate set catches it — shellcheck exits 0 (every
  affected file was shellcheck-clean), `bash -n` exits 0 (the line is
  syntactically perfect), and merely *running* the code is not detection either,
  because a hang does not fail a gate.

  The rule is deliberately narrow, and the narrowing is **measured, not
  assumed**: `${2:?…}` exits with its own message, and a bare `$2` under `set -u`
  exits `$2: unbound variable`, so neither can spin and neither is flagged — an
  earlier, wider cut would have false-positived ~58 live, correct
  `bin/subcommands/` sites. Also exempt: a loop whose *condition* already
  guarantees the arity (`while [ "$#" -ge 2 ]`, live in `board.sh`), and an
  `if [ $# -lt 2 ]; then … continue; fi` preflight (live in
  `emit-session-context.sh`) — a different, equally correct fix for the same
  defect, which it would be perverse to punish.

  **The runtime half.** `workflows/scripts/tests/test_argloop_trailing_flag.sh`
  extracts every repaired loop verbatim from its shipped file and runs it with
  each flag **last** (195 invocations across 27 files), plus the five `emit-*.sh`
  scripts end-to-end with their raw-lake sink in a tmpdir. Coverage is *derived*
  by grep from the fix idiom, so a new adopter is covered without anyone editing
  a registry. Every run is **bounded by a watchdog** — an unbounded assertion for
  this defect would hang the suite instead of failing it, which is worse than no
  test at all — and the suite carries its own discrimination control: a
  reintroduced `shift 2` must be killed by the watchdog *and* turn the lint red.

- **`env-reconcile.sh` now detects a leaked worktree whose branch simply
  LANDED — one whose commits are already contained in `origin/<default>`**
  (temperloop#1404). `classify_worktree` decided `LEAKED_WORKTREE:MERGED` from
  `merged_detect_is_merged` alone, and that helper is built for the opposite,
  merge-queue/squash topology where a merged branch's tip is *not* an ancestor
  of `origin/<default>`: its `gh pr view <branch>` probe returns nothing when
  no PR was ever opened under that head-branch name, and its patch-equivalence
  fallback is inconclusive over exactly the empty cumulative diff that
  "contained in `origin/main`" produces. Both fail open to `false`, so the
  whole class reported `OK` forever (observed 2026-08-13:
  `<repo>.wt/land-probe-cwd-873` — clean tree, no PR, tip an ancestor of
  `origin/main` — a leak the reconciler never surfaced, removed by hand). The
  classifier now carries the cheap, network-free plain-ancestor arm its sibling
  `scripts/prune-merged-branches.sh` has had since #173, emitting the same
  `MERGED` reason. Two guards keep it from calling live work a leak
  (temperloop#658's direction): ancestry must be **strict**, so a just-created
  worktree whose tip *equals* `origin/<default>` (no commits of its own) stays
  live, and an **`OPEN` PR** holds the arm back — GitHub saying the branch is
  still in flight outranks local containment. The verdict still routes through
  `_worktree_verdict`, so a landed worktree carrying uncommitted work is
  `DIRTY_WORKTREE:MERGED`, report-only.

- **`env-reconcile.sh` now surfaces harness agent worktrees as their own named
  class with a remedy pointer, instead of letting them hide inside the parent
  checkout's opaque `DIRTY`** (temperloop#1405). Claude Code's own agent
  isolation (`isolation: "worktree"`) creates worktrees under
  `<checkout>/.claude/worktrees/agent-<id>/` — inside the checkout, untracked,
  on a machine-made `worktree-agent-<id>` branch. The reconciler only ever
  walked the `<repo>.wt/<slug>` layout `worktree.sh` uses, so these were never
  classified at all; what an operator saw was the *parent* checkout reporting a
  bare `DIRTY` (cron role) or `STALE_UNTRACKED:.claude/worktrees/` (operator
  role) — a class with no remedy pointer that said something was there but not
  what to do, and masked any real drift beside it. Observed live on 2026-08-13
  across two checkouts (4 worktrees 8 days stale, 3 worktrees 27 days stale,
  plus their leftover `worktree-agent-*` branches). Three changes.
  **A second scanned layout:** `<checkout>/.claude/worktrees/` is now walked
  beside `<repo>.wt/`, under every cron and operator checkout that has one
  (path-configurable via `ENV_RECONCILE_HARNESS_WT_SUBDIR`). **Its own class,
  with the remedy on the finding line:** `HARNESS_WORKTREE:ACTIVE` (inside the
  staleness horizon — reported on its own line, never counted as drift, since a
  live agent may still be working in it), `HARNESS_WORKTREE:STALE` (past the
  horizon and confirmed clean — the only removable one, and its finding carries
  the exact `worktree remove` **plus** `branch -D` command, so the invisible
  half of the leak gets cleaned up too), and the report-only
  `HARNESS_WORKTREE:STALE_DIRTY` / `STALE_UNCERTAIN`. **No double-reporting:**
  the parent checkout's `DIRTY` / `STALE_UNTRACKED` tests now exclude that one
  path prefix *because* it is classified in its own right — every other dirty
  or untracked path still reports `DIRTY` exactly as before, so nothing real
  gets swallowed. `/tidy`'s env-hygiene step auto-heals `HARNESS_WORKTREE:STALE`
  only, on the same never-`--force` terms as `LEAKED_WORKTREE`.

- **`test_pipeline_retro_health.sh` tests 18 and 19 no longer read the real
  checkout's telemetry lake** (#1408). Both cases exercise the **retro-runs
  default** — so neither can pin `RETRO_RUNS_RAW_DIR` — and both ran
  `pipeline-retro-health.sh` *in place*, whose checkout-relative root resolution
  (`$here/../../..`) then pointed the assertion at the real `meta/data/raw/`.
  The verdict was therefore a function of whatever telemetry the host happened
  to hold: green on CI, which runs on a fresh clone where that lake is **always**
  empty, and red in any checkout that had ever collected a retro-runs row. Test
  18 flipped pass→fail with **no code change at all**, purely from the calendar
  advancing one real July row out of the 30-day window, making `make test-build`
  a deterministic local failure in any checkout old enough to have run a retro
  and then gone quiet. Because CI could never see it, the gate was structurally
  blind to its own non-hermeticity.

  Both cases now fabricate a **fixture checkout** (a copy of the script under
  `<fixture>/workflows/scripts/build/` plus a seeded `<fixture>/meta/data/raw/`,
  the technique test 14 already used for the symlink-climb case) and probe that
  copy, so the checkout-relative root they resolve is a directory the test owns.
  The suite's output is now byte-identical whether the real lake is empty,
  carries an out-of-window row, or carries an in-window one.

  The subject of each test is **sharpened, not hollowed out**. Each lake is
  seeded so the right root and every wrong root yield *different* verdicts: the
  fixture checkout root holds an in-window row (correct → `healthy`), while the
  decoy the test guards against — `$HOME/dev/foundation/meta/data/raw` for t18,
  `MODEL_USAGE_RAW_DIR` for t19 — holds an out-of-window one (leaked →
  `defect(stalled)`), and a `retro_dir` converged onto `$pipeline_dir` finds no
  stream at all (→ `defect(never-had-a-row)`). Where the old assertion could
  only observe that the retro-runs stream had *not* found the decoy, the new one
  proves it positively resolved the checkout root and read that root's row.

- **`lint-pipe-grep-q` no longer fires on the shape inside PRINTED TEXT — its
  own usage block included, which is what blocked the v0.29.0 vendor** (#1420).
  The lint already stripped `#` comments quote-aware, so it never fired on prose
  *describing* the `<writer> | grep -q <pat>` footgun it guards. It did not do
  the same for **quoted string literals or heredoc bodies**, so a `grep -q`
  inside an `echo`/`printf` help string was read as an executed pipeline. Two
  consequences, both live: the linter flagged **its own** error-message line
  (`echo "     <writer> | grep -Fxq \"\$needle\"" >&2`) wherever the vendored
  `kernel/scripts/lint-pipe-grep-q.sh` path is reachable, and it flagged
  ordinary overlay code that merely *echoes* a `curl … | grep -q …` probe
  instruction. Because the gate line is a **KERNEL_GATES** entry an overlay
  vendors as a symlink and cannot amend downstream, this was release-blocking
  rather than cosmetic — measured on the real composed overlay checkout it was
  **23 findings before, 0 after**, with every one of the 23 confirmed printed
  text rather than code.

  The scanner now reduces each line to its **executable part** before matching:
  the comment strip as before, plus the *contents* of every quoted string
  literal blanked, plus heredoc bodies skipped. **The exemption is by parse
  position, never by filename** — a filename allowlist would only move the
  defect to the next file that documents the shape. What decides is the simple
  command *consuming* the text: hand it to a shell (`bash -c`/`sh -c`, `eval`,
  `ssh`, `env`, `xargs`, `timeout`, a `bash <<EOF` heredoc) and it is still
  scanned, so the real in-a-string sites the #1050 sweep found stay flagged.
  The strip is content-only — quote *delimiters* survive — so `echo "x" | grep
  -q y` still reads as a pipeline and still fires. Heredoc detection is
  deliberately tight (a `<<<` herestring and an arithmetic `$(( a << B ))`
  shift are both rejected) because a false heredoc would swallow the rest of the
  file; a probe that appended a genuine violation to the end of all 404 tracked
  shell files confirmed **zero** files go blind that way.

  Both strips err toward a **missed site, never a false alarm on prose** — the
  stated safe direction for a guard whose false positives block a release. The
  bounded cost is spelled out in the script's own header: a heredoc body written
  to a file rather than printed is no longer scanned (~3.8% of the shell corpus,
  almost all test fixtures, hiding no site that exists today). `T8` asserts the
  discrimination on byte-identical text — code line named, printed and heredoc
  lines not — and `T9` reproduces the whole thing on a synthetic
  composed/vendoring overlay layout, where the defect actually fired.

- **`test_board_host_label.sh`'s "exactly one inlining site" check no longer
  depends on which `grep` is on `PATH` or on how the board toolkit was
  vendored** (#1422). The check enumerated its file set with `grep -rlE …
  "$BOARD_DIR"`, and a recursive grep's treatment of symlinks is not portable,
  so the *verdict* was a function of the host rather than of the code being
  audited. Two distinct failures, both measured:

  - **Board dir reached through a directory symlink** — the shape every
    vendoring overlay uses (`workflows/scripts/board -> ../../kernel/workflows/
    scripts/board` in foundation since 2026-07-03). GNU `grep -r` descends into
    a symlinked top-level argument; real macOS/BSD `grep` (`/usr/bin/grep`)
    does not, and `-R` does not help there either. The v0.29.0 test was
    therefore **green on Linux CI and red on every operator's Mac at the same
    commit**, reporting `found:` with an empty list — which reads as "the
    helper was deleted" when the truth is "the walk never entered the
    directory". `d3163bf` (#1490) had already made this particular arm pass by
    resolving `BOARD_DIR` with `pwd -P`, but only as a side effect of path
    resolution: the enumeration itself was still non-portable, and nothing
    tested that it stayed fixed.
  - **Board dir is a real directory whose *files* are per-file symlinks** into
    a vendored `kernel/` copy — the other shape in the fleet. `-r` on *neither*
    grep follows a symlink met during the walk, so this layout found **zero**
    sites on **both** platforms, which `pwd -P` cannot rescue. This arm was
    still red.

  The file set is now enumerated with `find -L` (which follows symlinks at the
  argument *and* during the walk) and grep is handed real files by name — the
  direct-file form that already matched on both platforms, which is exactly
  what made the recursive form's divergence look impossible at first read. Both
  sides of the "is this the one permitted site?" identity comparison are also
  canonicalized through a single `phys_path` helper, so a layout that reaches
  `lib/` or `tests/` through a symlink cannot make two spellings of the same
  file read as two sites.

  **The assertion is sharpened, not hollowed out.** A new sibling suite,
  `test_board_host_label_layouts.sh`, materializes all three layouts (real
  directory, directory symlink, per-file symlinks) and runs the subject test in
  each under every distinct `grep` the host can reach — the system `/usr/bin/
  grep` (BSD on macOS) and a `ggrep` if installed (GNU). For every
  layout × grep cell it proves three things in sequence: the clean tree is
  green, **adding a second inlining site turns it red and names that file**,
  and removing that site returns it to green. A portability fix that worked by
  weakening the check would pass the first assertion and fail the second. On a
  Homebrew Mac that is 6 cells; on Linux CI, where the flavors collapse, 3.

- **`workflow-reviewer-coverage.sh` now measures whether the reviewer RAN, not
  whether the PR body happens to contain the word `MAJOR`** (temperloop#1450).
  The rollup classified a merged command-doc PR as covered when its body matched
  `workflow-reviewer|BLOCKING|MAJOR`, which measured prose and was wrong in both
  directions: any changelog line, risk note or quoted finding scored as a
  documented pass, and — worst of all — the legible `skipped — workflow-reviewer
  …` degradation notice, which says in so many words that the reviewer did NOT
  run, contains the string `workflow-reviewer` and so scored as *covered*. Before
  temperloop#1430 that skip was structurally guaranteed on every Workflow-path
  command-doc PR (temperloop#1429), so the metric read highest exactly when the
  gate was most broken. It is now keyed on the two structured shapes
  `claude/workflows/build-level.mjs` §3e EMITS into the PR body via the verdict
  summary: the line-anchored tally `§3e review — ran: <reviewer>[, …]`, and the
  spliced `## Review notes` / `### <reviewer>` findings blocks. A prose heading
  such as `## The §3e review caught a destructive default` no longer matches —
  the tally must be at line start and carry the literal `ran:` list.
  Measured against `Towheads/temperloop` over the same 28-day window, the
  reported figure moves from `{command_doc_prs:51, with_workflow_reviewer:18,
  coverage_pct:35}` to `{command_doc_prs:51, with_workflow_reviewer:7,
  coverage_pct:13}` — 11 of the 18 were prose, two of them the skip notice.
  `--json` gains three purely additive fields that make the residue legible
  rather than silently folded into the numerator: `any_reviewer_ran` (a §3e
  record naming any reviewer), `skip_notice_only` (the gate degraded legibly —
  never counted as covered), and `no_review_record` (the build path emitted
  nothing at all); the three partition the denominator. The window fetch also
  collapses from an N+1 fan-out of `gh pr view` calls into a single
  `gh pr list --json number,body,files`, falling back to the old two-call path
  on a `gh` too old to accept `files` there — 112s to 13s against that same
  window, and ~200 fewer calls against the shared GraphQL budget.

- Review-agent charters no longer instruct the agent to read knowledge-store `[[wikilinks]]` its declared toolset cannot resolve. `requirements-auditor` and `architecture-reviewer` each opened with a "## Project context (read first)" section of vault links, while declaring `tools: Read, Grep, Glob, Bash` and no MCP — so both lenses reviewed *without* the governing decisions they were told to read first, and nothing in their output distinguished that from having read them. The load-bearing invariants are now vendored into the charters as prose, matching the shape `red-team-lens` and the persona agents already use. Affects `/triage` Step 3, `/assess` Step 3, and `/workshop` 3.3.2. (temperloop#1455)
- New `workflows/scripts/validate-agent-charter-links.sh` gate (wired into `KERNEL_GATES`) fails the build if any `claude/agents/**/*.md` charter reintroduces an unresolvable wikilink. Its match shape — `[[` followed by a non-space, non-bracket character — deliberately never matches the bash `[[ ... ]]` test syntax a shell-focused charter legitimately quotes. Both degenerate-input paths refuse rather than pass: an **unreadable** charter fails instead of counting as clean (a `grep` that cannot open a file returns no matches, which is byte-identical to "no wikilinks"), and an **absent** `claude/agents/` directory fails in the kernel's own checkout while staying a real no-op for a vendoring consumer, discriminated by a repo-root `.kernel-pin`. (temperloop#1455, epic temperloop#1409)

- **`architecture-reviewer` now pins its own model tier (`model: opus`)
  instead of declaring `model: inherit`** (temperloop#1456). The seat's own
  charter says its boundary calls "are the gate" and that it is therefore
  "never down-tiered" — but `inherit` resolves to whatever tier the *calling*
  context runs on, so the guarantee held only when a human happened to be
  driving on the strong tier. This went live the moment temperloop#1430 made
  the §3e reviewer gate actually run on the default Workflow path: an
  autonomous drive runs cheap by design (`$PIPELINE_DRIVE_MODEL`), and the
  seat would have silently inherited that tier on exactly the
  `kind: architectural` items it exists to protect — nothing errors, the
  review just runs weaker than designed. The declared intent was taken as
  authoritative and the mechanism corrected to match it. The tier is pinned in
  the agent's **frontmatter** rather than passed as a caller-side override,
  because the harness reads that file at every spawn: one declaration covers
  `/build` 3e, `/assess` Step 3 and `/workshop` Step 3.3/3.5 alike, and a
  future call site inherits the guarantee without knowing it needs to. This
  also brings the seat into line with the kernel's own § Subagent usage
  cost-tier rule, which asks that a seat's tier be set *explicitly* to fit the
  work — `inherit` being the one value that makes tier a function of the
  caller instead. `runReviewers()` in `claude/workflows/build-level.mjs` is
  unchanged and still passes no `model` override, so the change is a strict
  no-op for the three sibling reviewers that already pin `model: sonnet`
  (`workflow-reviewer`, `docs-reviewer`, `requirements-auditor`).

- **The review-agent availability probe no longer reports every reviewer
  unavailable on a checkout whose agents live in `~/.claude/agents/`** (#1462).
  The canonical predicate names two surfaces — `CLAUDE.md § Subagents` or
  `.claude/agents/` — and the kernel's own dogfooding checkout has neither:
  `.claude/agents/` is gitignored (`project-agents.sh` deploys it per-checkout,
  so a fresh clone has none) and `CLAUDE.md` carries no `## Subagents` heading.
  All eleven agents are nonetheless installed and spawnable from
  `$HOME/.claude/agents/`, so read literally the predicate returned
  *unavailable* for every one of them — and `build.md` §3e's **mandatory**
  `workflow-reviewer` pass and `/workshop` §3.3's adversarial panel both gate on
  it, so both emitted all-skip lines for agents that would have spawned fine. A
  skip line that fires for an available agent is itself a mandatory step
  silently not running: the temperloop#1387 all-skip outcome by a second,
  independent route. `docs/adr/0008-command-declared-probe.md` had documented
  this exact false-negative class for slash commands and noted the subagent
  probe lacked the equivalent; `workflows/scripts/lib/agent_declared.sh` (ADR
  0029) is that equivalent, mirroring `command_declared.sh`'s three-surface
  order with `agents/` for `commands/` rather than inventing a new one, and
  keeping the canonical predicate's `CLAUDE.md § Subagents` clause as a
  declaration surface probed first. Availability is now three-valued —
  `agent_declared_state` prints `installed`, `source-only`, or `absent` — so
  the two degradation-notice forms are *selected* rather than guessed:
  `installed` is the spawn gate, `source-only` gets the remedy-bearing "run
  `project-agents.sh` to enable" line, and `absent` still gets the bare
  `skipped — <agent> unavailable`. Absence and indeterminacy stay
  distinguishable on purpose: a probe that made everything look available would
  fabricate reviews that never ran, exactly as wrong as the bug it replaces. A
  live surface also outranks a source hit, so an agent that both ships and is
  installed reads `installed` — first-resolved-wins there would have
  re-introduced the same skip one layer in. `test_agent_declared.sh` pins each
  surface independently, the genuinely-absent case, the shipped-and-installed
  case, and the `AGENT_DECLARED_OVERRIDE` fixture seam.

- **The "cannot evaluate" idiom's `ONE emission path` claim is now true, and its one
  exception is named** (temperloop#1487). `claude/presentation-plane.md` froze
  `workflows/scripts/lib/cannot-evaluate.sh` as "the ONE emission path" while six sites
  still emitted the contract independently — the claim was aspirational. The blocker was
  structural: each model-comparison entry point's `command -v jq` bootstrap guard *is* a
  cannot-evaluate, and the helper built its JSON with `jq`, the very tool that was missing.
  So the guards hand-rolled their own shapes and drifted: `batch.sh` put the machine JSON on
  **stderr** with no human line, and `replay.sh` emitted `outcome:"ERROR"` there instead of
  `CANNOT_EVALUATE` — a consumer parsing stdout for the verdict saw nothing from either.
  `cannot_evaluate_emit` is now **jq-free** (it encodes with `jq` when present and with a
  pure-shell escaper when not, byte-identically), so all four guards in
  `{batch,judge,score,replay}.sh` route through it and emit both frozen shapes on the
  correct streams; each keeps its own documented process exit code (`1`). The fifth site,
  `tagging.sh crosscheck`'s `_cc_eval`, is a **registered carve-out** rather than a silent
  gap: its stdout is its own human `OK`/`FAIL` verdict stream, so it emits the frozen human
  line and *no* machine JSON on either stream, and returns its own documented `1`. That
  accepted shape is stated in the frozen row and pinned by a test, so a future drift into a
  partial emitter goes red.

- **The changelog gate no longer stops enforcing — while reporting success —
  when `VERSIONING.md` is absent** (temperloop#1494; epic #1620).
  `check-changelog-entry.sh` probes three files it needs, and two of them
  already discriminated an absent input from a clean one: no `CHANGELOG.md` and
  no `changelog.d/` each **fail loudly** in a tree carrying no `.kernel-pin`
  (the kernel's own checkout, which has lost one of its own files) and skip
  **legibly** in a tree that has one (a vendoring consumer that genuinely keeps
  neither). The `VERSIONING.md` probe was the odd one out: a bare
  `say "skipped …"; exit 0`, taken regardless of the pin.

  That is the "quietly narrows to zero" failure the script's own header refuses
  twice, applied to the one file whose absence causes it most directly.
  `VERSIONING.md § The contract surface` is the table this gate **parses** to
  decide what a PR owes a changelog entry for — it *is* the enforced surface
  set. Rename, move or lose that file in the kernel's own checkout and the set
  is empty, so every PR passes property (1) by default while the gate prints a
  skip and exits 0.

  The probe now carries the siblings' `.kernel-pin` discriminator verbatim in
  shape: **absent and unpinned FAILS** (naming the missing file, the
  discriminator, why an empty surface set is not a pass, and how to restore or
  repoint it); **absent and pinned still skips**, now naming the pinned kernel
  tag the way its two siblings do. The pinned arm is load-bearing, not a
  hedge — a composed overlay checkout legitimately carries no `VERSIONING.md`
  at its repo root, since it does not run the kernel's release workflow there,
  and breaking that layout was the one thing this fix had to avoid.

  Two cases pin the pair (36, 37), and both fail against the previous
  implementation: the unpinned tree exited 0 with `skipped —` where it now
  exits 1.

- **`archive-plan.sh` no longer reports success for a plan snapshot that never
  landed, and a later run no longer destroys one that is still pending**
  (temperloop#1523). The step printed one `plan-archive-pr-queued: <pr>` line
  that read as success while the snapshot sat only on `chore/plan-archive` —
  and because the shared protected-main kernel force-rebuilt that branch off
  `origin/main` every run, a prior run's snapshot whose PR had not merged was
  overwritten and gone (observed: the 2026-08-10 snapshot, PR #1395 open four
  days, discarded by the next run). Two changes. **Never-destroy:**
  `land-on-protected-main.sh` now bases the archive worktree on
  `origin/<branch>` whenever that branch carries commits `origin/main` does
  not, so an un-merged payload is carried forward and extended, and rebuilds
  off the default branch only when nothing unlanded sits on it.
  **Verdict-matches-payload:** the status vocabulary splits into
  `plan-archived:` (LANDED, the only success), `plan-archive-pending: <pr>`
  (on the PR, auto-merge armed, not on `main`), `plan-archive-failed: <why>`
  (nothing landed and nothing will), and `plan-archive-skipped:` (not
  attempted). The `gh pr merge --auto` result is no longer discarded with
  `|| true` — a PR whose auto-merge could not be armed reports failed instead
  of queued (an already-queued PR still counts as armed) — an empty staged
  diff is now read as "already present" only when the payload is genuinely
  tracked, so a snapshot the index refused (an ignored path) reports failed
  instead of `already current`, and the copy itself is checked and verified
  against the source rather than aborting the script mid-run.

- **`/build` workers are now told to add their own `changelog.d/` fragment for
  contract-surface changes** (#1530). Previously nothing told a worker about
  the fragment requirement, so a contract-surface PR passed every local gate
  (the changelog gate skips cleanly with no resolvable base outside a PR
  event) and then failed CI once, by design, on `check-changelog-entry.sh`
  alone — observed live on three separate PRs in one session. `workerPrompt()`
  (`claude/workflows/build-level.mjs`) now embeds a self-contained
  `## Changelog fragment` section pointing the worker at
  `changelog.d/README.md` for the filename shape and naming the
  `Changelog: none — <reason>` commit-trailer opt-out (the one escape hatch
  that works before a PR exists); `build.md` §3c carries the identical
  instruction, and a static guard in `test_workflow.sh` keeps the two in
  lockstep.

- **`check-changelog-entry.sh` now rejects a fragment shape
  `scripts/assemble-changelog.sh` will reject too** (temperloop#1542). A
  fragment body carrying its own `#`/`##`/`###` heading, or one of the
  assembler's control tokens (`##BEGIN##`, `##CATEGORY##`), used to pass the
  PR-time gate and only fail at release-cut time — the observed break:
  cutting v0.31.0 hit a hard stop on `changelog.d/1508-…fixed.md`, whose body
  opened with `### Fixed`, a shape this gate had already accepted.

  The two gates now share the SAME validation — `check-changelog-entry.sh`
  runs the exact functions `assemble-changelog.sh` calls
  (`changelog_fragment_body_offenders`, `changelog_fragment_empty` in
  `workflows/scripts/lib/changelog.sh`) against every fragment a PR adds or
  modifies, so the two copies of the rule this bug came from are now one. A
  malformed fragment is a cheap PR-time fix instead of a hard stop that writes
  nothing at the release cut.

- **A `/build` acceptance-gate escalation can no longer contradict its own
  payload** (#1587). `build-level.mjs` §3e.5 maintained **two** independent
  failure counters — an accumulated `failedGates` and the terminal slice's own
  `gateOut.failed` — and shipped both in one escalation:
  `{gateOut:{outcome:"GATE_PASS",failed:0,…}, failedGates:1}` under
  `kind=acceptance-gate-failed`. A consumer that trusted either field acted on a
  fiction, and the operator who read the gate log's closing
  `OK — gates 96..162 of 163 passed in 241s (final slice)` line reasonably
  concluded the escalation was a false positive. It was not — an earlier slice
  really had failed, and that green line covers only the gates the *last* slice
  ran — but nothing in the payload said so.

  There is now exactly one record of what a gate run found: a per-slice
  `sliceLedger` the loop appends to. Every figure reported anywhere derives from
  it — `verdict` (`RED` / `UNKNOWN` / `GREEN`, the one field a consumer may
  trust), `failedGates` (the ledger's sum), `slices` (its length), the escalation
  kind, and the reason prose, all computed in a single `gateVerdict()`
  reconciliation point. The raw terminal `gateOut` — whose `failed` was the
  contradicting field — is no longer embedded; its content survives as the
  ledger's last entry, which cannot disagree with the sum of the ledger it is
  part of. `slices` also stops over-reporting by one on slice-cap exhaustion,
  where it was read off the loop index rather than the ledger.

  Three behavior changes fall out, each closing a verdict/payload disagreement
  rather than widening the gate:

  - A `GATE_FAIL` whose failure count could not be parsed from the log (a stale
    or absent `QUALITY_GATES_FAILED=` trailer) now reports **at least one**
    failure. "Failed, 0 failures" was the mirror image of the same defect.
  - An **observed failure dominates an unfinished remainder**: a run that failed
    in slice 1 and was then killed by the executor's Bash ceiling escalates
    `acceptance-gate-failed`, with a reason naming both halves, instead of
    laundering a known-red branch into `acceptance-gate-timeout`. temperloop#1021
    is preserved exactly — and sharpened: the timeout kind is now reserved for
    runs where *nothing* failed in the slices that did run, which is the case
    this repo hits today (temperloop#1663).
  - A gate outcome outside the closed set no longer falls through to the
    pass arm and pushes a branch whose gate never returned a verdict. It
    escalates as `UNKNOWN`, with a reason naming the outcome verbatim.

  Covered by three new fixture cases in
  `workflows/scripts/build/tests/test_workflow.sh` (`1587 agreement` /
  `1587 observed` / `1587 honesty`) that construct all four gate outcomes
  against the .mjs's own offline harness — no live gate run — and assert the
  structural invariants on every escalation: no embedded `gateOut`, no second
  counter, `failedGates` equal to its own ledger's sum, `slices` equal to the
  ledger's length, the kind equal to the verdict in both directions, and a
  reason that agrees with the verdict it accompanies. All three fail against the
  pre-fix file.

- **`issue-state.sh resolve` can no longer fabricate a verdict for a target it
  never read** (temperloop#1591, #1518; epic #1626). The probe every `/fix` run
  starts with — before any mutation — collapsed *every* failure of
  `gh issue view` into `{}` (`... 2>/dev/null || echo '{}'`), and the next line's
  `jq -r '.state // "OPEN"'` then invented an open issue out of it. A
  **nonexistent** number resolved `route: fresh` with `issue_state: open`, so a
  consumer would claim-first and drive a target that does not exist (found live
  by `/fix 1710` in a temperloop checkout, aimed at `Towheads/foundation#1710`).
  A **transient** failure — auth, rate-limit, network — was indistinguishable
  from that genuine 404. And because the terminal arm tested one specific value
  (`= "closed"`), a **merged pull request** number fell through to the same
  `fresh` default, emitting `issue_state: merged` beside
  `reason: "open, unclaimed, no linked PR"` — the self-contradiction epic #1626
  is named for.

  The read is now a three-way envelope (`ok` / `not-found` / `error`) instead of
  a swallowed `{}`, and the route table gained three **terminal** arms ordered
  ahead of every other: `not-found` (`issue_state: absent`), `probe-failed`
  (`issue_state: unknown` — the state is genuinely unknown, which is not the
  same as open), and `not-an-issue` for a pull-request target, discriminated by
  the `url` field's `/pull/` vs `/issues/` at no extra API call. Only GitHub's
  own "could not resolve to an issue or pull request" signature counts as a 404;
  an unresolvable *repository*, an auth error and a network error all stay
  `probe-failed`, because asserting "this issue does not exist" off a read that
  never reached the issue is the same fabrication in a new costume.
  `already-done` widened from `closed` to any non-open state, a new
  `is_pull_request` field rides the verdict, the two failure routes print one
  human-readable line to stderr, and neither costs the second `gh` call the
  open-PR linkage probe would have made. `resolve` still always exits 0 once it
  has a verdict — failure is carried by `route`, never the exit code, so a
  caller capturing stdout under `set -e` cannot have the honest verdict killed
  out from under it.

  That ordering is what makes the fix structural rather than four patches: no
  arm below it — `fresh` above all — is reachable unless the target is a
  genuinely open issue, so the `reason` string can no longer name a state the
  `issue_state` field contradicts. Sixteen offline fixture cases pin it
  (nonexistent, merged PR, open PR, simulated auth/network/404/bad-repo
  failures, an unexpected non-open state, plus the open/closed baselines), each
  asserting the route *and* running a mechanical cross-field check that the
  `reason` asserts no lifecycle state other than the reported one; all of them
  fail against the previous implementation. `/fix`'s route table gained the
  matching **4g — no drivable target** arm, which touches nothing and reports.

- **The five macOS-only quality gates that had been red on `main` for eight
  nights now pass, and the shell-version footgun behind them is guarded
  mechanically** (#1649). `nightly-macos.yml` failed on every scheduled run from
  2026-08-14 onward — deterministically, byte-identically on retry — while the
  `ubuntu-timing` leg of the same workflow stayed green. Two distinct causes, one
  shared shape: **a bash-VERSION difference, not the BSD-vs-GNU userland dialect
  family** (#1549 / #1422) that this repo's macOS regressions usually belong to.
  The macos-latest runner's `bash scripts/quality-gates.sh` resolves to the
  system `/bin/bash`, which on macOS is **3.2.57**; ubuntu-latest ships bash 5.x.

  **(a)** `validate-check-surface-degenerate-coverage.sh` and
  `validate-exec-bit-registry.sh` (and therefore both of their test suites — four
  of the five gates) parsed their TSV registries by re-joining fields on `\x01`
  and reading them back with `IFS=$'\x01'`. **0x01 is bash's own CTLESC marker
  byte** (0x7f is CTLNUL), and bash 3.2's word splitting is not 8-bit clean for
  either: `read` returns the whole line — marker bytes included — in the *first*
  variable and leaves the rest empty. Every registry row therefore parsed as one
  field, and the gates reported `Checked 0 registered surface(s)` plus a
  `BAD-CASE` per row. Both now join on `\x1f` (ASCII US), which splits correctly
  on 3.2 and 5.x alike. The awk stage was never at fault: it emits byte-identical
  output under BSD and GNU awk, and holding awk fixed while swapping only the
  bash binary flips the result — which is how the dialect hypothesis was ruled
  out rather than assumed.

  **(b)** `test_model_usage_emit.sh`'s §47 mutation check asserted that removing
  `set +o posix` from `validate-model-usage-emit.sh` makes its CANNOT EVALUATE
  diagnostic vanish under `POSIXLY_CORRECT=1`. That is a bash 4+ behaviour: only
  bash 4+ aborts a posix-mode shell on a special-builtin redirection error inside
  an `if !` condition. Bash 3.2 does not, so the guard is provably *inert* there
  and the assertion was simply false. The check now **measures the host shell**
  with a minimal reproduction of the production shape, prints the verdict, and
  asserts the correct claim for that shell — the original strict "diagnostic is
  lost" on a bash that aborts, and the equally falsifiable inverse "diagnostic
  survives" on one that does not. Nothing is skipped or exempted, and the
  production guard is unchanged.

  **The structural half.** `scripts/lint-bash32-ctlesc-ifs.sh` is a new static
  lint — third member of the family alongside `lint-bash32-cmdsubst-comment.sh`
  and `lint-pipe-grep-q.sh` — that fails the build on any `IFS=` assignment
  naming byte 0x01 or 0x7f, in every spelling bash accepts. A static lint is the
  only detector that fires on *both* CI legs: shellcheck and `bash -n` exit 0 on
  the shape, and a runtime test only catches it under a bash 3.2 that the
  ubuntu-only pre-merge leg (#963) does not have. It deliberately does **not**
  flag the awk side (`awk -F'\1'`, `OFS="\x01"`) — measured 8-bit clean on both
  bashes, and live-and-correct in `validate-activation-registry.sh`, which an
  earlier, wider cut of the rule false-positived on. Its regression suite fires
  the lint at the verbatim pre-fix lines, fences the false positives, and — on
  any host that actually has a bash 3.2 — re-measures the lint's own premise so
  the claim cannot rot into folklore.

- **The knowledge-search backend home is now a declared, disclosed removal
  scope — and `test_install_lifecycle.sh` returns the same verdict with or
  without `uv` on the host** (temperloop#1658). Since temperloop#1113 the
  pinned `basic-memory` tool is *installed* rather than resolved per run,
  which materialises a full virtualenv (plus uv's cache, any managed CPython
  it downloaded, and the derived search index) under
  `${KNOWLEDGE_SEARCH_BM_HOME:-${XDG_STATE_HOME:-$HOME/.local/state}/foundation/basic-memory-home}`.
  Nothing recorded it, `temperloop uninstall` never removed it, and no
  removal surface named it — so case 7c failed on every workstation with
  `uv` while CI, which has none, stayed green and never exercised the path at
  all. The tree now has an explicit disposition: **deliberately unmanaged,
  regenerable tool state** — scope **(g)** of `bin/README.md` § Uninstall,
  alongside the issue-cache store root it most resembles. `temperloop
  uninstall` names the tree and prints its exact `rm -rf` whenever it is on
  disk (and stays silent when it is not, since a host without `uv` never
  grows one), honoring an explicit `KNOWLEDGE_SEARCH_BM_HOME`; the lifecycle
  suite's new case **7f** fails if the tree survives uninstall and the
  uninstall output did not name it, so the 7c exclusion cannot quietly become
  an *undisclosed* one.

- **Test sandbox roots can no longer leak on a failed, timed-out or cancelled
  run** (#1723). `sandbox_up` (`workflows/scripts/tests/lib/sandbox.sh`) now
  installs the cleanup traps **itself** — `EXIT`, `HUP`, `INT`, `TERM` — so all
  six existing caller suites became safe with **no edit**, and no future suite
  can forget. Previously every suite removed its ~1GB throwaway root with a
  single `sandbox_down` on its **last line**, reached only on the happy path
  (`fail()` is `exit 1`), so a failed assertion, a timeout kill, a CI
  cancellation or an ENOSPC walked straight past it. Measured: `$TMPDIR` held
  **215 leaked roots totalling ~180GB**, filling a 460GB disk and killing a
  validation batch at record 25/28.

  Three properties the guard holds. It is **registered, not latest-only** —
  every root the shell created is reclaimed, not just the one `$SANDBOX_ROOT`
  names at the moment of death (`test_uninstall.sh` calls `sandbox_up` 13
  times). It is **chained, never clobbering** — a caller's own handler is
  captured via `trap -p` (bash's own re-runnable quoting, so nothing is
  hand-unescaped) and runs **first**, while the root it may still need exists;
  traps are re-armed on every `sandbox_up`, so a trap installed *between* two
  `sandbox_up` calls is re-chained rather than left clobbered, and a signal the
  caller deliberately ignores (`trap '' TERM`) is left alone. And it is
  **idempotent** with the explicit trailing `sandbox_down` the suites already
  carry, so `test_install_lifecycle.sh`'s "the root is gone" assertion still
  means what it did.

  **`SANDBOX_KEEP=1`** retains every root (loudly, on stderr) for diagnosing a
  red suite; it applies to the explicit `sandbox_down` too, so *keep* means
  keep.

  **SIGKILL is not covered and is not claimed to be** — `kill -9`, an OOM kill
  and the SIGKILL leg of a candidate timeout are untrappable by construction.
  For that path, and for roots already stranded before this guard existed, the
  new sweeper `workflows/scripts/tests/lib/sandbox-sweep.sh` is the remedy: it
  recognises a root by the `.sandbox-root` marker `sandbox_up` now writes, or
  by `sandbox_up`'s exact directory signature for the pre-guard leaks — never a
  `mktemp`-prefix glob — skips roots newer than `--older-than` (default 60m) and
  roots whose recorded pid is still alive, and is a **dry run until `--apply`**.

  `workflows/scripts/tests/lib/tests/test_sandbox_trap.sh` (new
  `KERNEL_GATES` entry) asserts all of it from the OUTSIDE: each scenario runs a
  generated fixture suite as a separate process with `$TMPDIR` re-pointed at a
  throwaway scan dir, and checks that directory once the fixture is dead — mid-run
  `fail()`, SIGTERM (exit 143), `SANDBOX_KEEP` in **both** directions, trap
  chaining before and after `sandbox_up`, a deliberately-ignored signal staying
  ignored, `sandbox_down`+trap idempotence, and the sweeper's find/skip/apply
  behaviour.

- **`/sweep`'s unattended escalation park no longer reads as destroying the
  worker's unlanded work** (#1725). The park branch's `worktree.sh remove` now
  runs first in the branch — `cmd_remove`'s own unlanded-work guard (#1699)
  preserves committed and dirty state to a local `refs/parked/<slug>-<sha8>`
  ref before the force-remove — and the park comment names that ref plus the
  host holding it, since the ref is local-only and never pushed. The old
  "resume = re-run, so discard it" rationale, which justified the destroy by
  the very re-run it made lossy, is gone. A capture failure now surfaces as
  `REMOVE_REFUSED` plus a non-zero exit (#1730) — which this branch reads as
  the work-preservation SUCCESS case, not a park failure: it warns, keeps
  disposing the chunk, and lands a distinct sentence in the park comment naming
  the verbatim `preserved_detail`, the still-standing worktree path and the
  host, so the failure is durable on the issue rather than lost to an
  unattended run's stdout. The spec adds no destroy of its own after one. The
  spec also now states the ref's reap rule: a sweep-originated ref is never
  restored in place, so `prune` reaps it on the originating issue's terminal
  disposition, never on the ancestry gate — which can never fire for it — with
  `prune`'s `PARKED_REF` report and /tidy's stale-claim sweep named as the
  crash-window backstop.

- **`worktree.sh` no longer destroys work that preservation failed to capture**
  (#1730). #1729 taught both destroying primitives to preserve unlanded work to
  a local-only `refs/parked/*` ref first — but each then ran
  `preserve_unlanded … || true` and destroyed **unconditionally**, so the guard
  only ever protected the happy path: on `capture-failed:snapshot`,
  `capture-failed:no-commit`, `capture-failed:ref-mint` or
  `unclassifiable:no-default-branch` the worktree was force-removed and
  `build/<slug>` was `git branch -D`'d with **nothing captured**.

  `preserve_unlanded`'s **return value is now the destruction gate**: `0` means
  the loss window is closed (nothing to preserve, not needed, or preserved),
  non-zero means preservation was needed and failed. The `|| true` is gone from
  both call sites, and the two callers deliberately **diverge**, because their
  constraints do:

  - **`remove` refuses.** A leaked worktree is recoverable by hand; a
    force-deleted branch is not. It now emits
    `{"outcome":"REMOVE_REFUSED", …}` carrying the verbatim `preserved_detail`
    and the **still-standing** path, exits **non-zero**, and destroys nothing.
  - **`create` sidelines and still `CREATED`s.** A refusing `create` would turn
    `/build`'s prelude batch from *created* into *escalated*, so instead of
    destroying, the un-preservable occupant is **moved aside** — `git worktree
    move` to `<path>.unpreserved-<sha8>`, `git branch -m` to
    `<branch>.unpreserved-<sha8>` — which frees the deterministic path for a
    fresh worktree. The work survives **and** `create` still returns `CREATED`,
    with the verdict riding that line as the new
    `sidelined` / `sidelined_path` / `sidelined_branch` **fields** (never a new
    `outcome` string — `SPINE_OUTCOME_SCHEMA` is a closed enum).

  **`prune` owns the sidelined worktree's disposal**, reporting it as
  `SIDELINED_WT` / `SIDELINED_WT_REAPED` on the same two-gate contract it
  already applies to a preservation ref: ancestry of `origin/<default>` **or** a
  terminal (CLOSED) originating issue, with an unevaluable check treated as
  FALSE, an OPEN issue never reaped, a dirty tree never passing the ancestry
  gate, and `--force` deliberately not plumbed in. The outcome strings stay
  distinct from `PRUNED` so `deploy-mini.sh`'s counter is unaffected.

  `workflows/scripts/build/tests/test_worktree.sh` extends #1729's cases with
  the failure path: `remove`'s refusal is asserted against **each** of the four
  capture-failure details (worktree *and* branch intact, named outcome, verbatim
  detail, standing path, non-zero exit), `create`'s sideline is asserted to leave
  the prior work recoverable at both halves while still returning `CREATED`, the
  `prune` gates are asserted in all three dispositions, and an activation check
  asserts the `|| true` is gone from both destroying primitives.

- **`env-reconcile.sh` now classifies a worktree from its ACTUAL branch, and
  never hands a consumer a removable verdict it could not establish**
  (temperloop#658). `classify_worktree` computed the branch as
  `build/$(basename "$wt")` — the naming convention `worktree.sh` happens to
  use — so a worktree on any other prefix resolved to a branch name that had
  never existed, missed `show-ref`, and was reported
  `LEAKED_WORKTREE:BRANCH_GONE` while alive. `/tidy`'s env-hygiene auto-heal
  then `git worktree remove --force`d it: on 2026-07-21 a live `fix/` worktree
  — the isolated-worktree flow the kernel's own § Working-tree ownership rule
  *prescribes* — was destroyed along with its uncommitted edit. Two changes.
  **Classify from the real signal:** the branch is read from git's own
  `worktree list --porcelain` record for that path (falling back to the
  worktree's `HEAD` symref), so prefix has nothing to do with the verdict while
  the genuinely-deleted ref is still detected. **Never remove on an
  unestablished verdict:** the emitted class splits into `LEAKED_WORKTREE`
  (leak reason held *and* the tree confirmed clean — the only auto-removable
  one), `DIRTY_WORKTREE` (same reason, but uncommitted work present), and
  `UNCERTAIN_WORKTREE` (the verdict could not be established at all — a
  detached worktree, an unregistered directory, or a branch-gone worktree whose
  deleted ref leaves `git status` no base to diff against). Each finding line
  now carries its disposition, and `/tidy` removes only the clean class, run
  **without `--force`** so git's own refusal is the last belt.

- **`pr.sh rebase` now tells an unstaged-changes refusal apart from a genuine
  rebase conflict** (#735). git refuses to *start* a rebase while tracked files
  carry uncommitted edits, and that refusal exits non-zero exactly like a content
  clash — so a worker that had FINISHED (commit made, gates green) but left one
  tracked file unstaged was reported `{"outcome":"REBASE_CONFLICT","base":X,"tip":X}`:
  base == tip, no rebase needed, no conflict anywhere, and the rebase-conflict
  escalation would have discarded the finished work. The dirtiness is now probed
  from git's own `status --porcelain` before anything is attempted and reported as
  its own `DIRTY_WORKTREE` outcome (with `dirty_paths` and a `rebase_needed` flag
  that also rides `REBASED`); `REBASE_CONFLICT` is left meaning only what it says.
  `build-level.mjs` escalates it under a distinct `dirty-worktree` kind whose
  disposition is commit-the-leftover-and-re-drive, and `issue-state.sh reattach`
  no longer relabels it `stale-base-conflict`. A base that is already current now
  skips the rebase invocation entirely.

## [0.33.1] - 2026-08-19

### Fixed

- **The warm `basic-memory-mcp` backend terminates its MCP sessions instead of
  leaking one per query** (`Towheads/foundation#1710`). The backend opened an
  MCP streamable-HTTP session per search via `_ks_bm_mcp_open_session` — plus a
  second, bare-`initialize` session per query from the availability probe
  `ks_search` runs for its read-log gate — and never sent the `DELETE /mcp`
  teardown. The daemon retains per-session server state until told to drop it,
  so every search cost it ~1–3.6 MB permanently: **9.2 GB after 48 h**, and
  hidden from `ps` by memory compression, which is why it went unnoticed.

  A `_ks_bm_mcp_close_session` helper now sends the teardown (`DELETE /mcp`
  carrying `Mcp-Session-Id` + `MCP-Protocol-Version`) on **every** exit path.
  In `search` the close runs immediately after the `tools/call` round-trip
  returns and *before* parsing, so the parse-success, tool-error,
  unparseable-body and degraded-result-fallback paths all run after teardown;
  `|| true` on the curl/jq assignments keeps a timeout from skipping the close
  under a `set -e` caller. The availability probe closes its own bare-initialize
  session too (~50 KB each, opened on every query). The close is **fail-open**
  and always returns 0 — a failed `DELETE` can never turn a successful search
  into an error.

  Measured against the live daemon over a 10-query set: unfixed 880→897 MB
  (+1.7 MB/search); fixed 897→906→762→767→768 MB — the daemon reclaims the
  prior sessions' state and holds flat within noise. Four hermetic cases
  (`test_knowledge_search_mcp.sh` § 5) pin the success path, the error path,
  the fail-open `DELETE`, and the probe session; disabling the teardown fails
  the first of them.

  **Provenance:** this fix was originally written inside `foundation`'s
  vendored `kernel/` copy rather than here, so it never reached any other
  adopter — every stranger vendoring the kernel carried the leak. It is ported
  upstream unchanged (bar cross-repo issue qualification) so the fix lives in
  the one place that owns this file, per the kernel-edits-land-upstream-first
  rule; the divergence surfaced as a subtree-pull conflict while vendoring
  v0.33.0.

## [0.33.0] - 2026-08-19

### Added

- **`session-start-drain.sh`'s seam-unavailable fail-open branch is now
  covered by a test** (#1634). The hook exits 0 without draining when the
  knowledge_store seam was never sourced — a hooks-only vendor drop with no
  `workflows/scripts/lib/` two directories up — but no case in
  `claude/hooks/tests/test_session_start_drain.sh` could reach it, because
  `make_fixture` always copied both libs in. The new case removes `workflows/`
  from the fixture and pins all the properties a SessionStart hook owes: rc=0,
  the `.mind/` stub still on disk byte-identical, nothing written into the
  store, the session-id `hookSpecificOutput` JSON still on stdout, and the
  "knowledge_store seam unavailable" line in the log. It goes red if that
  branch ever exits non-zero — the regression would present as a broken
  session start on a vendored checkout, not as a skipped drain.

- **`temperloop install` now persists and verifies the knowledge-store root
  instead of leaving it to an untracked, operator-created file** (#1771). The
  rung-3 machine conf that `ks_root()` reads through `_ks_machine_conf_root`
  was written, installed and verified by nothing in this tree, so losing it
  dropped every consumer onto the XDG default — and because the plain-files
  backend's append does `mkdir -p`, the wrong root was silently *created* and
  written to rather than erroring. The install path now owns it, via
  `links_persist_knowledge_root` (`workflows/scripts/install/links.sh`), which
  **never guesses a root**: with an absolute `KNOWLEDGE_STORE_ROOT` in the
  install-time environment and no usable conf root, it appends
  `: "${KNOWLEDGE_STORE_ROOT:=<value>}"` to the conf (creating the file with a
  header when absent), so a value that was only ever an ephemeral env var
  becomes something a bare hook or launchd agent resolves too. A conf that
  already yields a usable absolute root is left byte-identical, which is also
  what makes a second install a no-op; a relative root is refused by name
  (`_ks_machine_conf_root` would reject it, so persisting one would be a
  silent no-op); and a conf that already *mentions* `KNOWLEDGE_STORE_ROOT`
  unusably is reported rather than appended behind (dead text) or rewritten (a
  clobber). With nothing configuring the root at all, the install prints the
  `default-fallback` / `conf-present-but-unusable` notice — the same
  provenance vocabulary `doctor.sh`'s `check_knowledge_root` established in
  #1340 — naming the root every consumer would otherwise use, and does **not**
  fail: a fresh install legitimately has no store yet. The conf is
  deliberately not manifest-managed, so `temperloop uninstall` never removes
  it, exactly as it never removes the store itself.

- **A migrating-from-Obsidian guide ships in `docs/`**
  (`Towheads/foundation#892`). The kernel documented what the knowledge-search
  adapter *is*, but not how a store gets moved onto it — that knowledge lived
  only in issue bodies, a private ledger, and committed eval JSON. The new
  `docs/migrating-from-obsidian.md` covers the four things that migration
  actually turned on: constructing a golden-query set, the parity-ledger
  method, the mutation tripwire, and the staggered writer migration order.

  **Its framing is that this is a migration of access paths, not of data** —
  the store stays canonical markdown throughout and nothing is converted,
  which is the single most common wrong expectation to arrive with.

  **The results are reported as measured, including where the incumbent won.**
  Read from the committed cutover-gate artifacts rather than recollection:
  basic-memory took hit@5 (0.974 vs 0.842) and recall (0.947 vs 0.790) but
  **lost MRR** (0.767 vs 0.829), and the guide leads with that row. Search was
  not a speed win either — cold p50 4.497s, which is why the warm-daemon
  supervisor unit exists at all.

  It also documents what went wrong, because a method section that only
  describes the happy path teaches an adopter to repeat the mistake: the
  parity ledger **failed as a gate** (its raw tally favoured the incumbent,
  three of its arms were broken instruments, and the weekly regression bench
  was later found comparing two corpora with zero overlap), and the cutover was
  re-gated on the golden-query eval instead. Each failure carries its
  transferable rule.

  A **When not to do this** section gives six self-select-out criteria, and a
  boundary section states plainly which pieces live in this kernel and which
  the adopter writes themselves — the harness, ledger, tripwire and scheduled
  reindex are *not* shipped here, so they are described as methods rather than
  linked as files a stranger's checkout does not have.

  Contract-surface note: this adds one `kernel` classification line to
  `workflows/scripts/kernel/kernel-manifest.txt` for the new page. Docs-only
  otherwise — no behavior, interface, or setting changes.

### Changed

- **The knowledge_search backend installs its pinned `basic-memory` as a uv
  tool instead of resolving it via `uvx` on every call** (#1113). `_ks_bm_run`
  used to invoke `uvx --from basic-memory==<pin> basic-memory …`, which has no
  permanent install location: uv resolves the package, unpacks a ready-to-run
  environment into its own cache, and executes out of that cache. Every
  distinct resolution adds another environment and nothing expires them —
  observed at 30 GB against a 273 MB knowledge store, with the root volume at
  0 bytes free, and unprunable (`Cache is currently in-use`) for as long as
  the warm `basic-memory-mcp` daemon held the cache lock. The adapter now
  installs the pin once (`uv tool install --python <pin> basic-memory==<pin>`)
  into its own isolated home — `UV_TOOL_DIR`, `UV_TOOL_BIN_DIR` and `HOME` all
  pinned there, so nothing reaches the operator's `~/.local/{share,bin}` — and
  invokes the installed entry point by absolute path. uv's cache then holds no
  live environment, holds no lock, and stays prunable while the daemon serves.

  **Upgrades still follow the pin.** Under `uvx` the pin was re-asserted on
  every invocation; an installed tool would otherwise keep serving the old
  build forever. The installed version *and* interpreter are stamped beside
  the entry point and re-checked on every call, so changing
  `KNOWLEDGE_SEARCH_BM_VERSION` or `KNOWLEDGE_SEARCH_BM_PYTHON` re-installs
  rather than silently continuing to run what is on disk.

  **Installing is hybrid, both halves shipped together.**
  `workflows/scripts/install/doctor.sh` gained a `knowledge_search
  basic-memory tool` section that installs the pin and reports its state
  (`INSTALLED` / `PIN DRIFT` / `ABSENT` / `UNAVAILABLE` / `INSTALL FAILED`) —
  advisory, never affecting doctor's own exit code. And the availability gate
  installs the pin lazily on first use when it is absent, so a stranger with
  only `uv` on `PATH` and no `doctor` run still gets a working first
  `ks_search` — the zero-setup property that made `uvx` the original default.
  `ks_search_available` is therefore no longer a pure predicate **by
  default** — pass the new `--probe` flag for a zero-side-effect check that
  never installs (a hermetic test, a graceful-skip capability probe). It
  accepts a
  new `--quiet` flag that suppresses only the `skipped —` notice (never
  install progress), which `ks_search`'s internal read-log probe now passes.

  Degradation is unchanged in shape: `uv` missing, or the install failing,
  still returns exit 3 with a `skipped — knowledge_search unavailable: …`
  line on stderr, nothing on stdout, and uv's own failure output surfaced
  rather than swallowed. The one-time install is bounded by the new
  `KNOWLEDGE_SEARCH_BM_INSTALL_TIMEOUT` setting when the caller has sourced
  `workflows/scripts/lib/portable-timeout.sh`.

- **`session-start-drain.sh` writes session stubs through the knowledge_store
  seam instead of a raw `curl` PUT** (#732). The SessionStart drain hook used
  to build its own Obsidian Local REST API request — read the plugin's API key
  file, `PUT /vault/Sessions/_inbox/<stub>`, branch on the HTTP code — which
  meant a stranger's plain-files install could never drain a stub at all: no
  Obsidian vault, no REST plugin, no key file, so every run fell open at
  "API key file missing". The write is now one `ks_write "Sessions/_inbox/…"`
  call and `KNOWLEDGE_STORE_BACKEND` decides the transport: `plain-files`
  (the default) writes atomically under `ks_root`, and `obsidian` reaches the
  same `PUT /vault/<path>` the hook used to hand-roll, so an Obsidian-backed
  install keeps its existing wire behaviour. `KS_LIB_DIR` resolution
  (temperloop#406, hook lib-path resolution) and the
  fail-open-when-the-seam-is-unreachable posture are unchanged.

  The stub search now prunes **two** store roots rather than one: `ks_root`
  (the plain-files root) and the vault the Obsidian key-file path names, each
  with trailing slashes stripped. Both halves are load-bearing — `find -path`
  never matches a trailing-slashed operand, and under the `obsidian` backend
  `ks_root` is documented as meaningless, so either gap let a `.mind/` file
  sitting inside the store be drained back into the store and deleted from
  source.

### Fixed

- **A freshly installed `ks_search` backend now indexes the corpus before it
  answers, instead of returning nothing forever** (#1635). Registering a
  basic-memory project does not scan it, and nothing else on the search path
  did either — so on a genuinely clean host the chain ran to completion and
  stopped one step short: install the pin, register the project, search an
  **empty index**, return zero results with exit 0. Nothing had failed, so
  nothing was reported; a stranger got "no matches" for every query they ever
  ran until something else happened to call `ks_search_reindex`. The search
  path now indexes once, in the same project-not-found branch where it
  registers, before it retries the query. That branch fires on first use and
  on a post-`reset` DB drop and never on a warm query, so no per-query cost is
  added. The index is best-effort — a failure warns on stderr, surfaces the
  subprocess's own cause, and lets the retry proceed rather than failing the
  search — and is bounded by the new `KNOWLEDGE_SEARCH_BM_INDEX_TIMEOUT`
  setting when the caller has sourced
  `workflows/scripts/lib/portable-timeout.sh`.

- **A clean-host validation of the stranger first-run path ships as an
  opt-in `make` target** (#1635). Every test of the #1113 uv-tool install
  switch stubs `uv`, deliberately — kernel principle 3 forbids a live-network
  install inside the gated suite — so the real path (clean host, only `uv` on
  `PATH`, no `doctor` run, first `ks_search`) had never been executed. `make
  validate-clean-host-ks-search` now executes it inside a throwaway Linux
  container: a real `uv tool install`, a first search over a fixture corpus, a
  second search that must install nothing, and a third with `uv` removed from
  `PATH` entirely. It is **manually invoked only** — absent from
  `scripts/quality-gates.sh`, from `KERNEL_GATES`, and from every CI job — and
  fails loudly (exit 2) when the Docker daemon is unreachable rather than
  reporting a skip. The run that found the indexing defect above is recorded
  verbatim in `docs/validation/clean-host-ks-search.md`.

## [0.32.0] - 2026-08-15 — BREAKING

### Changed — BREAKING

- `/fix` and `/build` now perform their close→Done writes through the `board_close_done` adapter helper instead of hand-rolling `board_resolve_item` + `board_set_status … Done` at four separate call sites, making the helper the single idiom for the operation. Each converted site keeps a `declare -F board_close_done` fallback guard, so a consuming repo whose vendored `board.sh` predates the helper degrades to the previous hand-rolled form rather than failing. The two sites that bundled `gh issue close --comment` now post the reason comment first and close through the helper, which takes no `--comment` by design.

- **Kernel command docs now instruct direct file reads + `ks_search` instead of the Obsidian MCP for reads and concept search** (#1570). The kernel half of foundation epic #951 Phase 3 (the knowledge-store cutover — its gate passed 2026-08-14, `basic-memory` beat Smart Connections head-to-head, and the store is markdown-canonical going forward: files are the truth, Obsidian is a viewer). Every `mcp__obsidian-builtin__vault_read` / `vault_list` / `vault_get_document_map` and read-purposed `mcp__obsidian__get_vault_file` / `list_vault_files` site across `claude/commands/{assess,build,check-in,init,next,tidy,triage}.md` now instructs `Read`/`Glob` on the path resolved against the knowledge store root (`workflows/scripts/lib/knowledge_store.contract.md`); every `mcp__obsidian__search_vault_smart` concept-search site now instructs `ks_search`. `workflows/scripts/lib/knowledge_store.contract.md`'s `### Obsidian-mode note` is rewritten to the post-cutover posture. Write instructions (`vault_append`/`vault_write`/`vault_patch`/`vault_move`/`vault_delete`/`create_vault_file`) are untouched — this cutover is reads and search only. One backstop site is deliberately left on the old transport: `tidy.md`'s "Knowledge-search parity misses" section, which detects missed `search_vault_smart`↔`ks_search` comparisons under the overlay-only, self-gated Phase 1 parity rule (`claude/CLAUDE.overlay.md`) — its own text defers retirement to foundation#956, the same change that removes that overlay rule, so it is intentionally out of scope here. Not a breaking change — no schema, contract, or write-side behavior changed; only the read/search transport in prose instructions.

- **`score.sh` now persists the candidate's real diff text and gives the X
  and R buckets the same per-path candidate-vs-truth attribution the N
  bucket already carried** (#1579). A scored replay record's
  `score.diff.text_excerpt` field captures the candidate's actual patch
  text — including untracked new files — while the leg's worktree is still
  live (`batch.sh` tears it down immediately after replay), truncated at
  `REPLAY_SCORE_DIFF_EXCERPT_MAX_BYTES` with an explicit marker when
  oversized. **BREAKING:** `score.diff.x.paths` and `score.diff.r.paths`
  changed shape from bare path-string arrays to the same per-path
  attribution objects `score.diff.n.files` already carries (`path`,
  `changed`, `matches_truth`, `truth_added`/`truth_removed`,
  `candidate_added`/`candidate_removed`, `formatting_only_truth_churn`) — a
  downstream reader of a pre-#1579 record's X/R paths as plain strings must
  update to read `.path` off each element instead.

- **`install-claude-md.sh`'s "Knowledge store routing" agent-plane rule now has an explicit override for the post-cutover posture, instead of relying forever on a mechanical `.obsidian` probe** (#1599, kernel half of foundation epic #951). The composed `~/.claude/CLAUDE.md`'s "Agent-plane access rule" line used to key purely on `[ -d "$root/.obsidian" ]` — correct pre-cutover, but wrong forever after, since Obsidian stays installed as a viewer post-cutover and `.obsidian/` never disappears. The new `KNOWLEDGE_STORE_AGENT_PLANE` setting (`workflows/scripts/build/build.config.sh`) selects the render: `auto` (default) leaves the `.obsidian` probe unchanged, so a stranger's fresh install renders byte-identical output to before this setting existed; `direct` forces the post-cutover rule (files canonical, agent-plane reads via `Read`/`Glob`, writes via `Write`/`Edit`, concept/idea search via `ks_search`, Obsidian a viewer only) regardless of `.obsidian` presence. Not breaking — the default preserves today's behavior exactly.

### Fixed

- **`test_allowlist.sh` case 19 now passes in a detached `$TMPDIR` worktree**
  (#1552), so `combined-tree-precheck.sh` no longer reports `GATE_FAILED` for
  every multi-PR level. Two environment assumptions fixed in the test, not the
  validator: case 19's untracked-ceiling fixture moves outside `.temperloop/`
  (its old path tripped `COMMITTED-LOCATION`, shadowing the
  `COMMITTED-NOT-TRACKED` assertion the case exists to pin — case 20 now
  carries its own `.temperloop/` fixture), and the in-repo fixture paths
  resolve through the physical repo root (`cd -P`), matching the validator's
  own resolution — under macOS's symlinked `$TMPDIR` (`/var` →
  `/private/var`) a logically-resolved fixture path never prefix-matched the
  validator's repo root, silently skipping the git-tracked check.

- **A failed candidate or judge spawn now reports the stdout envelope's diagnostic instead of a blank reason** (#1553). Both `replay.sh execute` and `judge.sh judge` run their spawn with stdout redirected to an envelope file and stderr to a scratch file, and both built their failure detail from **stderr alone** — then tore the scratch dir down, destroying the envelope unread. But `claude -p --output-format json` reports an API-level failure as a JSON object on **stdout** (`{"is_error":true,"subtype":"error_during_execution","api_error_status":529,…}`) and writes nothing to stderr, so an empty stderr is that CLI's expected failure shape, not an anomaly. The result was `"the candidate runner exited 1: "` — a detail trailing off after a colon, naming no cause — on **all 28 legs** of the first live batch, and the identical `"judge-spawn: the judge runner exited 1: "` on the judge side. Both sites now read the envelope **before** the scratch dir is removed and render both streams through one shared library (`workflows/scripts/lib/spawn-diagnostic.sh`): the envelope's `is_error`, `subtype` and `api_error_status` are surfaced by name, each stream's contribution is labelled so a reader knows which one carried the reason, and a spawn that was genuinely silent on both streams now says so explicitly (`"…exited 1 and produced no diagnostic on either stream"`) rather than ending at a colon. The existing 400-byte-per-stream bound is preserved, so a verbose failure cannot grow a record without limit.

- **`batch.sh` now stops the batch on consecutive same-stage integration errors instead of running the corpus out** (#1554). The driver had per-leg resilience and no upper bound on it: on the first live batch, 14 records replayed successfully over ~3.1h and then every remaining leg fast-failed in ~4–5s — **28 consecutive `candidate-spawn` integration errors**, almost certainly a rate or usage limit, hammered ~5s apart to the end of the corpus. Continuing is the worst available response to that particular cause. A circuit breaker now trips once `MODEL_COMPARISON_BATCH_MAX_CONSECUTIVE_STAGE_ERRORS` (defaulted in `build.config.sh`, registered in `setting-registry.tsv`; `0` disables it) consecutive integration errors carry the **same** `integration_error.stage`. Any leg that scores resets the streak and a different stage re-keys it to 1, so a scatter of unrelated per-record incompatibilities never trips it while a systemically unavailable spawn path does; only legs the current invocation executed are counted, so a resume is never pre-tripped by a previous run's record. The stop is reported distinguishably from a completed-but-degraded batch — outcome `BATCH_STOPPED_EARLY`, its **own exit code `5`** (not `4`), a named `circuit_breaker_tripped` degradation, and a `circuit_breaker` block carrying the stage, the streak, and how many legs *and whole corpus records* were never attempted. Every skipped leg is recorded `not-attempted` rather than as an integration error — it cost nothing and makes no compatibility claim about its record — and is always retryable, so a plain (or `--retry-failed`) resume against the same `--state-dir` re-drives exactly those legs without re-spending anything already done. The judge pass is skipped on a tripped run with a named reason, since it spawns through the same seam that just went unavailable. Below the threshold nothing changes: an isolated failure still leaves the batch running.

- **The replay spend gate now derives its per-replay cost estimate from observed records instead of an n=1 literal, and the batch reconciles projection against outturn** (#1555). `replay.sh preflight` authorized spend from `REPLAY_PREFLIGHT_TOKENS_PER_REPLAY` — an order-of-magnitude estimate from a **single** validation replay — while the records that contradicted it sat unread in the attribution lake. The first live batch measured **n=14, mean 699,963, range 309,700..1,476,744** (a 4.8x spread) against a configured 470,000: the literal was **1.49x low**. Because that figure is what the ceiling check *and* the operator confirmation are computed from, every batch's projected spend was understated by the same factor — at N=21 the gate projected 19.74M against a 50M ceiling where the observed mean projects 29.4M. Nothing was wrongly authorized, but the margin shown was about twice as generous as the truth, and nothing reconciled the projection against what a run actually cost. Now: **(a)** with at least `REPLAY_PREFLIGHT_DERIVE_MIN_N` observed `replay-candidate` / `cli-envelope` records on the host, the estimate is their **mean**, each record re-weighted from its raw token block under the `SPEND_WEIGHT_*` values *in force now* (never its stored `weighted_units`, which carries no weight vector and would silently mix retune epochs) — proven retune-independent by a test that doubles every weight and watches the derived figure double; **(b)** with fewer, behaviour is unchanged — the configured literal, with `tokens_per_replay_basis` stating the figure is UNMEASURED on this host. That field now always names **which mode produced the number in force**, naming `n` when derived, and never presents the literal as measured; **(c)** because a point estimate over a 4.8x spread is misleading on its own, `observed_replay_cost` publishes the whole distribution (n, min/p50/p90/max, stddev, spread) on every run — including the "n=0, nothing to derive from" case — and `estimated_total_tokens_range` projects the *same* batch at the observed p90 and maximum, saying out loud when a ceiling the mean clears the worst case would breach. The **stop** decision stays on the point estimate deliberately: a worst-case budget is a different claim from an expected one. **(d)** A completed batch's summary carries a new `spend_reconciliation` block stating **projected vs observed** total spend for the run in that same unit, raising `drift_alert` (and a stderr notice) past `MODEL_COMPARISON_SPEND_DRIFT_ALERT_PCT` — but never a degradation, because a wrong projection is a fact about the estimate, not a defect in the batch that just ran. The confirmation line an operator reads before authorizing now carries the provenance and the range rather than a bare number. The lake read is the one deliberately **fail-open** path in this fail-closed module: an absent or unreadable telemetry directory is "this host has observed nothing", never a refusal to price a batch.

- **`judge.sh judge-batch` no longer replaces a record it cannot judge with a bare error object** (#1556). It appended `_je_one_record`'s `{"outcome":"CANNOT_EVALUATE",…}` / `REFUSED` envelope *instead of* the row it was derived from, so the judge pass was a lossy transform: on the first live batch it destroyed 14 of the 21 records in each arm. Because a bare envelope carries no `.candidate`, `score.sh aggregate` then (correctly) refused the whole arm file and the comparison report emitted nothing at all — a partially-degraded batch became a total loss of reportable output. `judge-batch` is now an annotating transform only: a row it cannot judge is emitted **as its original record** carrying a judgment-absent `judge` sub-object (`scored:false`, `quality_score:null`, a named `degradation_notice`), and an input line that is not a JSON object — the one shape that cannot carry a merged field — is preserved verbatim in the emitted envelope's `original_line`. No input record is dropped or overwritten.
- **An unjudgeable-by-construction row is an expected shape, not a judge failure** (#1556). An integration-error record has no candidate model and no diff, because the candidate spawn failed before producing either; there was never anything for a judge to score. Such a row now passes through unjudged with a top-level `unjudged` marker, spends no judge call, and contributes no per-row failure — so `judge.degraded` stops firing for a batch whose only "failures" were rows that were never judgeable, and the comparison report counts them as unjudged rather than listing them as judge degradations.
- **`batch.sh` reconciles the arm file it wrote against the leg records it counted** (#1556). Every figure the driver publishes is derived from the leg state files, which are written once; the arm file is a separate artifact that the judge pass rewrites in place, and nothing checked the two against each other — which is how the live run reported `replay_completion_rate: 1` and 21 records per arm while the arm files it had just written were already corrupt. The summary now carries a `reconciliation` block (record count, per-record identity, and record shape per arm); a mismatch is a named `arm_reconciliation_mismatch` degradation, flips the run to `BATCH_DEGRADED`, and stamps `completion.rate_is_over_a_reconciled_arm:false` with a named caveat, so a clean-looking rate can never sit silently beside a corrupt arm file.

- **`validate-check-surface-degenerate-coverage.sh` no longer false-fails a
  composed overlay's vendor bump with `ALLOWLIST-GREW` on upstream-grown
  allowlist rows** (#1559). The ratchet now resolves the allowlist/registry
  paths to their physical form first (a base-ref `git show` on the overlay's
  symlink path was comparing the link's target text as if it were TSV), and
  when the repo root carries `.kernel-pin` and the allowlist resolves into
  the vendored `kernel/` subtree, subtree-sourced rows are additionally
  ratcheted against the kernel's own pulled content (the subtree squash
  commit identified by its `git-subtree-dir: kernel` trailer) rather than
  only the overlay's `origin/main` — so an allowlist-growing kernel bump
  merges without a manual `CHECK_SURFACE_ALLOWLIST_BASE_REF` override, while
  an overlay-authored row (present in neither comparison point) still fails,
  and a kernel checkout's own shrink-only ratchet is unchanged. With no
  reachable squash commit the arm degrades fail-closed to the plain
  base-ref ratchet and the verdict line says so.

- `telemetry-brief.sh` now resolves the **pipeline** telemetry stream the same way its sibling reader `pipeline-retro-health.sh` does: an explicit `PIPELINE_RAW_DIR` wins, else an explicitly-set `TELEMETRY_RAW_DIR` wins, else it falls back to the writer's own absolute pin (`pipeline-cron.sh`'s `$HOME/dev/foundation/meta/data/raw`). Previously it fell back to the checkout-relative `TELEMETRY_RAW_DIR` default, so from any checkout other than `$HOME/dev/foundation` the reader and writer resolved to different directories and the brief silently reported an empty pipeline stream. The three sibling streams (`command-runs`, `issue-touches`, `claims`) stay checkout-relative, matching their own writers. `setting-registry.tsv`'s `TELEMETRY_RAW_DIR` row is updated to note the pipeline stream's exception.

- The **model-usage attribution stream** now lands in the canonical raw lake instead of a vendored kernel stub. `emit-model-usage.sh` derives its sink by climbing two levels from its own file location, which is correct for a standalone kernel checkout but wrong for the pipeline, which runs the kernel copy **vendored** under a consuming checkout (`…/foundation.cron/kernel/`) — so every record went to `<checkout>/kernel/meta/data/raw/`, a stub dir holding only a README, and both real lakes held zero model-usage records while the drivers reported clean runs. The emitter's own default is deliberately unchanged (it must not guess a foreign path); instead its two pipeline callers — `pipeline-drive.sh` (seats A7/A8) and `pipeline-retro-judge-spawn.sh` (seat A9) — resolve `${PIPELINE_RAW_DIR:-$HOME/dev/foundation/meta/data/raw}`, byte-for-byte the literal `pipeline-cron.sh`'s `RAW_DIR=` pins its own stream to, and hand it to the emitter as a **per-command environment prefix** through the shared `model-usage-envelope.sh` helper. An explicitly-set `MODEL_USAGE_RAW_DIR` still wins, and an unset `$HOME` leaves the emitter on its own default rather than aborting the run. The **retro-runs** stream is untouched and stays checkout-relative.
- The pin is deliberately **never exported**. `MODEL_USAGE_RAW_DIR` is read by more than the emitter — `validate-model-usage-emit.sh`, `validate-provider-disclosure.sh`, `model-comparison/replay.sh`, `model-comparison/tagging.sh` and `report-producers/model-comparison` all consult it — and both drivers spawn a headless `claude -p` that inherits their environment and runs its own quality gates. An exported pin would silently turn two repo-scoped gates into production-data gates inside an autonomous drive: the emit validator would strict-parse a long-lived append-only stream written by several emitter versions, and the disclosure gate would join production sends against the *worktree's* disclosure log. Scoping the pin to the emit invocation keeps every spawned child reading its own checkout — asserted directly (a spawn double reports its inherited environment) and structurally (no `export MODEL_USAGE_RAW_DIR` in either caller).
- `pipeline-cron.sh` gains **Step 4.5**: after a live drive it runs `validate-model-usage-emit.sh` against the **production** lake (`$RAW_DIR`) and folds the verdict into the drive record as `model_usage_lake` — `{status, dir, files, records[, reason]}`. Nothing had ever pointed that validator at production, so a corrupt or absent production stream went undetected. It is gated to drive-wakes (the only wakes that write the stream) and skipped under `--dry-run`, so a frequently-running surface pays nothing for a lake nothing wrote; the reported file/record counts make an *empty* stream visible beside the drive that should have filled it, rather than an unqualified "ok". `CANNOT EVALUATE` is reported as `unavailable`, never as a schema failure, and a failing or missing validator never *fails* the wake. That shipped as an exit-status guarantee only, with the step documented in place as not time-bounded; #1592 closes that gap in this same release, so the **#1592** entry in this same section — not this one — describes the step's final behavior. `MODEL_USAGE_VALIDATE_BIN` is the test-double seam.
- `setting-registry.tsv`'s header gains a note on **caller-pinned settings** — a second, differently-shaped duplicate from the byte-identical `PIPELINE_OPERATOR` case — and the `MODEL_USAGE_RAW_DIR` row records both pin sites, the never-export rule, and why the `PIPELINE_RAW_DIR` chain inside the pin is kept: without it, a harness that isolates `PIPELINE_RAW_DIR` to a throwaway dir would fall through to the literal `$HOME/dev/foundation` lake and write test records into the real production stream. Neither pin adds a registry row — the owner's literal remains the registered default.

- **`batch.sh` now counterbalances arm execution order, so arm is no longer confounded with position** (#1571). The driver iterated the two arms in one fixed order inside its per-record loop — baseline first, candidate second, on every record — which made ARM perfectly confounded with EXECUTION POSITION: every baseline leg was also a first leg, so no sample size could separate "the candidate model is cheaper" from "the second leg of a pair is cheaper". This is not hypothetical. The K#1262 validation run was an **A/A** comparison, the same model in both arms and therefore a true arm effect of zero **by construction**, and the second arm still came out ahead on 6 of 7 records (cache_creation −15.9%, duration −15.2%). *What* attaches to position remains an open question — a prompt-cache TTL story is one **hypothesis**, asserted nowhere in the code — and the fix does not depend on the answer. Now: **(a)** the order is counterbalanced **deterministically by record index** (`counterbalanced-by-record-index-v1`, seed recorded — never wall-clock, never `$RANDOM`), so the baseline arm runs first on half the records and second on the other half; counterbalancing rather than randomization because it *guarantees* balance at every N instead of achieving it in expectation, which is what matters at this module's tens-of-records sample sizes. **(b)** Every leg record and leg state file carries an `execution_order` block with its **position** (1 or 2), so an order effect can be estimated **per leg** rather than only averaged over, and the batch summary carries an `arm_order` block whose recorded rule and seed reproduce the per-record assignment on their own. **(c)** `workflows/scripts/report-producers/model-comparison` reads those positions back and publishes an `execution_order` block: whether the order was counterbalanced, the estimated **order effect** beside the estimated **arm effect** — `arm = (mean_A + mean_B)/2`, `order = (mean_A − mean_B)/2` over the baseline-first and candidate-first halves — and the published ratio at which the two count as comparable. When the order effect **is** comparable in magnitude to the arm effect, or when every record ran in the same order (a pre-#1571 corpus, where the order effect is not identifiable at all), the report **says the comparison is not clean and names no winner**, with the reason stated in `comparison.winner_withheld_reason`. This is a second, independent condition on the `winner` key: it can only withhold a winner the sample floor already allowed, never mint one, and `MODEL_COMPARISON_MIN_SAMPLE_N` and the inconclusive behaviour are untouched. A corpus whose records carry **no** position at all is reported as *unknown*, not as *not clean* — it discloses the gap and withholds nothing, because inventing a position is exactly the laundering this change exists to stop.

- **`pipeline-cron.sh`'s Step 4.5 model-usage lake check is now time-bounded** (#1592), closing the gap #1565 documented in place as accepted. Its exit-status isolation was only half a guarantee: a validator that never *returns* cannot fail a wake, but it blocks one forever — and that validator reads a whole month file into a bash array plus a `printf -v` string, so an NFS-mounted or pathologically large lake could hang the hourly cron indefinitely. The call now runs under the shared `workflows/scripts/lib/portable-timeout.sh` shim (`run_with_timeout`), bounded by the new **`MODEL_USAGE_VALIDATE_TIMEOUT_SECS`** setting (default `60`). Fail-open is unchanged — the wake still exits 0 — and the bound is deliberately enforced through the shim's **dependency-free third tier**, so it holds on a stock macOS with neither GNU `timeout` nor `gtimeout` installed; a bound that evaporated where coreutils is absent would be a surface asserting a guarantee it never verified, which is the same defect class Step 4.5 itself exists to close.
- A timeout is reported as a **legible, distinguishable outcome**: `model_usage_lake` gains `timed_out: true` alongside `status: "unavailable"` and a reason naming the bound that fired. It rides with `unavailable` rather than `fail` because a timeout reaches no verdict about the data at all — reporting it as a schema failure would send an operator hunting corruption nobody observed — but the `timed_out` key is written **only** on that path, so its presence alone separates "the check ran out of time" from "the lake is unreadable", and a timeout can never render as an unqualified `ok`. A checkout missing the shim entirely is reported the same honest way (`unavailable`, refusing to run the validator unbounded) rather than silently dropping the bound.
- The setting is **sanitized**, because neither backend validates its argument and an unchecked value is one character of config away from destroying the guarantee it exists to impose. `timeout 0` means *no timeout* on the GNU tier — a 30s hang returns `rc=0` after the full 30s, so a validator would run completely unbounded and report a clean `ok`, reintroducing this issue's own defect through a typo — while on the watchdog tier the same `0` makes `sleep 0` return at once and kills a perfectly healthy validator. A non-numeric value is wrong *differently per platform*: the watchdog fires at 0s, but GNU `timeout` exits `125`, which matches neither `CANNOT EVALUATE` nor `^FAIL` and so lands in the schema-`fail` arm — the same typo reading as "the lake is **corrupt**" on Linux CI and "the lake is slow" on macOS. Anything that is not a positive integer now falls back to the default, and the rejected value is surfaced in the record as `timeout_config_invalid` on **every** status — a bad bound usually produces an ordinary-looking `ok`, which is exactly when an operator would otherwise never learn their setting was being ignored.
- The validator's output is captured through a **file, not a command substitution**, and that is load-bearing rather than stylistic. On the shim's watchdog tier the bound kills the validator process but cannot reap a child it forked (the real validator runs `python3`), and an orphaned grandchild holds a command substitution's pipe write-end open — so the natural `$(run_with_timeout …)` port returns its `137` on time while the wake still blocks for the **full** hang (measured 21s against a 2s bound). Under GNU `timeout` both shapes bound correctly, which is exactly the trap: the leak is invisible on any machine with coreutils installed. `test_pipeline_cron.sh` therefore pins the bound twice — once on whatever backend is present, and once with `timeout`/`gtimeout` stripped from `PATH` so the dependency-free tier is provably the one under test.

## [0.31.0] - 2026-08-14

### Added

A new gate catches a script that has lost its executable bit. Every gate invokes
scripts as `bash <path>` or through a make target, so the bit is invisible to CI
and a script could ship non-executable indefinitely and stay green — it was
caught twice by hand, both times surfacing only as an incidental `mode change`
line in rebase output.

Keyed to an explicit registry (`workflows/scripts/config/exec-bit-registry.tsv`)
rather than the shebang rule the originating issue proposed. Measured against
this tree, that rule fired on 96 files — roughly 35 sourced libraries, 58 test
harnesses invoked as `bash test_x.sh`, 2 sourced config files, and 15 others —
of which exactly one was a genuine defect. The registry lists the files that must
carry the bit, so absence of an entry is not a finding.

A grandfather allowlist exists with a shrink-only ratchet, and is currently
empty: an opt-in registry needs nothing grandfathered. The gate fails closed on
an absent, unreadable or empty registry rather than passing with nothing checked.

### Changed

`validate-model-usage-emit.sh` now validates every record in a raw-lake file
with a single batched `python3` process instead of spawning one `python3`
process per record. The old shape measured ~28ms/record of pure fork/exec
overhead: 100 records added ~3s to `make gates`, 500 added ~14s, and a
10,000-record raw lake (a lake that only grows, since `meta/data/raw/*` is
gitignored and nothing prunes it) added roughly 5 minutes locally. CI itself
paid nothing (the gitignored lake is always empty there), so this only ever
cost developers, silently, more every week.

Behavior is unchanged: the same per-record shape/enum/no-host checks run
against every record, `FAIL` lines still cite the exact same `file:line`,
and every degenerate-input case (a missing/unreadable raw-lake directory, a
closed stdin, an unresolvable repo root) still exits non-zero as
`CANNOT EVALUATE`. The batched call also fails closed if `python3` itself
crashes mid-batch, or returns fewer verdicts than records sent, rather than
risk silently treating an unvalidated tail of records as passing.

The contract-surface table in `VERSIONING.md` now carries a row for the changelog
machinery itself — `check-changelog-entry.sh`, `lib/changelog.sh`,
`assemble-changelog.sh` and `VERSIONING.md`. The gate parses that table at run
time to decide what counts as contract surface, and the table did not previously
cover the gate, so a change to the release-entry contract resolved to no
contract-surface path and required no entry. A breaking change to that machinery
shipped an entry only because its author volunteered one.

Categorised `changed` rather than `.breaking`: a vendoring overlay need do
nothing to keep working. The effect is that a pull request touching those paths
now owes an entry like any other contract-surface change, and the existing
opt-out marker still applies. Measured against the last ten merged pull
requests, none would newly owe an entry.

- **Kernel gates that assert the kernel's own product content are now a
  class-gated set, so a vendoring overlay can run a release green** (#1423).
  `KERNEL_GATES` had one tier — every gate the kernel declares, every adopter
  runs — but a handful of those gates assert the CONTENT of temperloop's own
  product surfaces and resolve, through a consumer's compat symlink, to the
  consumer's root. `validate-onramp-anchors.sh` asserts this repo's README
  quickstart, installer URL and `bin/temperloop` first-run banner;
  `validate-docs-footer.sh` asserts the AI-authorship footer on this repo's
  product-docs pages. An adopter's README is a different product's README, and
  no overlay wiring makes either pass there.

  These four gates (each validator plus its test) move into a new
  `KERNEL_CONTENT_GATES` array in `scripts/quality-gates.sh`, class-gated on
  the same single signal the existing `SELF_DISTRIBUTION_GATES` class already
  uses (temperloop#691): a repo-root `.kernel-pin`, present in a vendoring
  consumer and absent in the kernel's own checkout. No new signal, no new
  config knob. In this repo all four still run; in a consumer each is named on
  its own `SKIPPED_KERNEL_GATES` line with its reason, never dropped silently.

  Deliberately NOT moved: gates that go red in a vendored tree because of a
  real upstream defect — `lint-pipe-grep-q.sh` flagging its own help text
  (temperloop#1420), and the spend report finding zero agent definitions
  through a symlinked `claude/agents` (temperloop#1424). Those must keep
  failing until they are fixed; class-gating them would bury them. The bar for
  joining the class is a positive argument that an adopter's repo cannot and
  should not satisfy the assertion — never that the gate is currently red.

- **The merge-gate approval prompt now leads with the defect, not just the
  fix** (#1485). `claude/message-schema.md` § Question block gains one named
  conditionally-required slot — **Problem summary** — required whenever a
  block asks the operator to approve work that resolves a tracked item: a
  compressed one-to-two-line restatement of the linked issue's own defect
  statement (never its title, which the block already carries), ordered
  problem-first. The slot names a **real, reachable source** — one
  `gh issue view <n> -R <owner>/<repo> --json body` taken at ask time —
  because nothing earlier in a run holds the defect prose:
  `workflows/scripts/build/issue-state.sh resolve` fetches
  `state,labels,assignees` only, so a resolved issue *number* is not its
  defect statement. The read is negligible where the slot applies (the gate
  fires once per run, at a point already issuing `gh` calls for the
  `gate.sh backend` probe). The slot defines **three arms**, all reachable
  and all implemented at both consumer sites: the summary rendered;
  `no linked issue — <reason>` when there is no tracked item; and
  `summary unavailable — <reason>` when the read fails or returns an empty
  body — with an explicit **never-fabricate** rule, since a restatement
  inferred from a title or a diff is strictly worse than a stated absence in
  the one artifact meant to strengthen merge consent.
  `claude/commands/fix.md` Step 5 (the `decision_sink_ask` payload) and
  `claude/commands/build.md` 4a (the per-PR text block, where the 4b option
  labels' length/4-option cap cannot reach; 4b defers to 4a's rendering)
  both defer to that slot **by name** rather than restating its shape, and
  4a's `↳ defect #<n>: …` line is qualified `owner/repo#N` when the item's
  `repo:` differs from the plan's home repo, mirroring the rule 3f already
  applies to `Closes`. Previously every named payload slot described the
  *change* — PR #, title, CI state, the fix, the backend — so an operator
  approving hours or days after filing had to recall the defect or go read
  the issue, and consented to a merge without the one thing needed to judge
  whether it addressed the right problem.

### Fixed

- **The testbed source seam now resolves each provider's directory argument
  itself, instead of the driver forcing its own `--dir` default on every
  provider** (#1356): `workflows/scripts/testbed/source.sh` gains a fifth
  seam member, `dir_arg(dir, seed_dir)`, dispatched by provider kind exactly
  like the existing four, and `temperloop testbed` gains a `--seed-dir`
  flag. Before this, one positional argument meant "source repo directory"
  to `mirror-from-repo` and "seed directory" to `materialize-from-seed`, so
  the driver's `source_dir="."` default silently overrode the correctly
  computed in-tree seed default and a seed run produced the repo name
  `.-testbed` instead of `linkrot-testbed`. The defect was at the call site,
  not in either provider — `_TESTBED_SEED_DIR_DEFAULT` already resolved the
  in-tree seed correctly. The driver stays provider-agnostic: it resolves
  one provider-scoped value through the seam, with no `case` on provider
  kind anywhere in `bin/subcommands/testbed.sh` (the existing structural
  guard test still holds). `mirror-from-repo` is unchanged — `--dir` still
  selects the source repository directory.

  Worth recording next to the existing provider-equivalence test (#1232):
  that test drives two doubles and asserts an identical call sequence, and
  is **structurally incapable** of catching this defect — the call sequence
  genuinely *is* identical for both providers; only the argument's meaning
  differed. That is the honest limit of equivalence-by-doubles, not a flaw
  in how it was written. The new regression test therefore drives the
  **real** providers through the real driver, from two different working
  directories (including from inside an unrelated git checkout), and pins
  what "valid repository name" means — matches `^[A-Za-z0-9_.-]+$`, is
  neither `.` nor `..`, at most 100 characters — a constraint no validator
  in the tree asserted before now.

- **`temperloop testbed` no longer misattributes source identity on a
  `materialize-from-seed` run** (#1357). `source_slug` — the value feeding
  the handoff banner, the consent block's `source :` line, and
  `testbed_record_add`'s persisted `.source_repo` — was computed ONCE in the
  driver as a bare `git remote get-url origin` read in the DRIVER's own
  cwd, identically for both providers, rather than from either provider's
  own `describe()`. record.sh's own documented schema says `.source_repo`
  is null for a seed testbed — but running `materialize-from-seed` from
  inside any git checkout that happened to have an `origin` remote (the
  likely case for someone trying the demo from a real clone) silently
  captured that UNRELATED repository's slug instead: a schema violation,
  persisted, and — since `temperloop uninstall` (#1358) now prints teardown
  guidance sourced from that same record — not merely cosmetic. temperloop
  #1356's provider-scoped directory argument fix did not fix this on its
  own: `source_slug` was never derived from a provider's resolved directory
  at all.

  The fix folds source identity into `describe()`, the seam member the
  driver already calls exactly once, already dispatched by provider kind:
  `describe()`'s JSON payload now carries a `source_repo` field —
  `mirror-from-repo`'s own implementation resolves it from ITS OWN resolved
  source directory (the same read `base_name` already derived a slug from);
  `materialize-from-seed`'s implementation returns `null` unconditionally,
  since there is no upstream repository to name, ever, regardless of the
  cwd the command happens to run from. The driver reads `.source_repo` off
  the already-resolved `describe()` payload instead of re-deriving
  anything itself — no `case` on provider kind, no second slug parser (the
  existing structural guard against a provider-kind `case` in
  `bin/subcommands/testbed.sh` still holds). The handoff's "your real repo
  (...) is never touched" reassurance is now printed only when
  `describe()` actually resolved a real source repository — a seed run
  makes no claim about a real repo at all, rather than falsely reassuring
  about one. `mirror-from-repo` is unchanged in behavior: `--dir` still
  names the source repository, and the handoff/consent/record all still
  carry its slug.

- **`temperloop uninstall` now accounts for the machine-scoped testbed
  record as its own scope (f)** (#1358): when the record shows a testbed
  repository still live in the operator's GitHub account
  (`artifacts.repo_created = true`), uninstall names each repository
  explicitly and prints the exact `temperloop testbed --teardown --repo …
  --id …` command for it, instead of saying nothing at all. Before this,
  `bin/subcommands/uninstall.sh` contained zero occurrences of the string
  `testbed`, so the only pointer to a live private repo an operator's
  testbed run had created went unmentioned when they uninstalled. The gap
  was introduced by the record's own placement: #1227 deliberately put it
  in machine-scoped XDG state rather than `.temperloop/` (correct — `eject`
  deletes that directory and the CI round trip runs `eject` mid-flight),
  and that decision moved it outside every uninstall scope that existed at
  the time. **The new scope is print-only**, matching the posture of the
  three advisory scopes already there (bootstrap footprint, eject reminder,
  cache root): removing the pointer without removing the repo would convert
  a recoverable artifact into an unrecoverable one, so uninstall never
  deletes the record or the repo — teardown stays `temperloop testbed
  --teardown`'s job. That property is asserted, not assumed: the new test
  diffs the record file byte-for-byte across `uninstall --yes`. The
  no-record and empty-record cases print nothing rather than a dead-end
  "you may have leftover state" line.

- **`test_lint_pipe_grep_q.sh` T4 no longer false-fails on a composed overlay
  checkout** (#1505). T4 asserted that the lint's default file set includes
  five kernel-native paths (`bin/temperloop`, `bin/foundation`,
  `.temperloop/report.d/tokens`, `workflows/scripts/report-producers/tokens`,
  `workflows/scripts/lib/issue-marker-probe.sh`) by exact `git ls-files`
  granularity. On a consumer that vendors `kernel/` as a subtree behind
  compat directory symlinks (`bin -> kernel/bin`, etc.), git tracks each such
  top-level directory as ONE symlink entry, so `git ls-files` structurally
  cannot enumerate a path underneath it — the five checks failed for a
  reason unrelated to lint coverage. T4 now self-scopes: it detects a
  composed overlay (the same two signals `validate-onramp-anchors.sh` and
  `sandbox_skip_if_composed_tree` already use, temperloop#1490) and emits a
  NAMED skip there, while still running the five checks for real and
  strictly on a kernel-native checkout. A new T4-overlay case proves both
  directions on a synthetic fixture: the symptom reproduces, and the
  detection neither over- nor under-fires.

- **`test_lint_pipe_grep_q` T4-overlay used the running checkout as its negative
  control** (#1508, follow-up to #1505). The case added in #1505 asserted
  *"detection does not flag THIS checkout"* — true in the kernel repo, **false in
  every vendoring consumer**, so the suite failed for exactly the trees #1505
  set out to support. The negative control is now a synthetic **kernel-native**
  fixture (real directories, no `kernel/` subtree, no overlay marker), so both
  directions are proven by fixtures and the result no longer depends on where
  the suite is run from. The checkout's own arm is now reported as a `note:`,
  never asserted. Verified passing on both: 43/43 on a kernel-native checkout
  (T4 runs for real) and 38/38 on a composed overlay (T4's five coverage checks
  legibly skip).

- **A lone discovered epic-sized issue now has a pipeline door** (#1524, #1510):
  `/assess`'s two no-Contract stop sites branch three ways instead of
  unconditionally redirecting to `/triage` — an epic-shaped issue with missing
  members still routes to `/triage`; a plain small issue routes to `/fix <n>`
  (the #1510 misroute); and an epic-sized, Contract-less issue enters a new
  lone-issue decomposition arm that derives the contract from the issue's own
  body sections, reusing the existing hand-authored-Contract provenance ask and
  the `/build` sub-issue mint path. `/fix`'s discovered-epic redirect now names
  `/assess --epic <N>` rather than the circular `/triage`-first path, closing
  the redirect cycle in which every command pointed at another refuser.

- **A `^C` or `kill` on a running replay batch now STOPS it instead of
  cleaning up and continuing to spend** (#1527).
  `workflows/scripts/model-comparison/batch.sh` — the model-comparison
  module's spend-bearing entry point, and the only thing that calls
  `replay.sh execute` in a loop — registered one handler on `EXIT INT TERM`.
  A bash trap handler *returns*, which is right for EXIT and wrong for a
  signal: an interrupted batch tore its in-flight worktree down and then
  calmly started the next leg, so the operator's "stop spending" was
  acknowledged and ignored. The EXIT arm is unchanged; INT and TERM now run
  the same cleanup and then re-raise under the default disposition, so the
  process dies **of** the signal with the conventional signal-derived status
  (`130` / `143`, deliberately outside the driver's own closed exit-code set)
  and prints no summary object it never earned. Per-leg failure resilience is
  untouched — a leg that genuinely fails is still recorded and the batch still
  continues; only a real signal stops the run, and every leg already in a
  terminal state is on disk, so re-invoking resumes without re-spending it.
  `tests/test_replay_batch.sh` gains section I: a stub that TERMs the driver
  mid-leg proves exactly one of four legs ran, no arm files were assembled,
  the in-flight worktree was torn down, and the exit status was 143 — plus a
  mutation proof that restoring the single `trap … EXIT INT TERM` makes the
  same TERM clean up and run all four legs.

## [0.30.0] - 2026-08-14

### Added

- **A `/build` worker's acceptance self-report now requires — and surfaces —
  proof each check can actually FAIL, not just that it passed, and a missing
  proof is a visible degradation rather than a silent one.** A `passed: true`
  self-report was indistinguishable, from the returned verdict alone, between
  a genuine test and a vacuously-passing one (a mistargeted assertion, a
  fixture that never exercises the changed path). Every `acceptance_results[]`
  entry now carries an optional `discrimination_evidence` field — which
  mechanism was removed/broken, that the suite went RED without it, that
  restoring it went GREEN (`claude/workflows/build-level.mjs`
  `WORKER_VERDICT_SCHEMA`). On `/build` only, `workerPrompt()` requires it via
  a new, gated `## Discrimination evidence` section — armed by a new
  `requireDiscriminationEvidence` `args` key on the same Step-0/Step-3
  hand-off seam as `principlesSummaries`/`gateSliceSecs`; `sweep.md`/`fix.md`
  deliberately omit the key today (an operational scope decision — their own
  `acceptance:` field CAN carry a real per-criterion bullet array, same as
  `/build`'s, so this is not a structural exclusion), so the requirement does
  not leak to them. The load-bearing other half:
  `workflows/scripts/build/pr.sh`'s PR-body recap (`assemble_body`) now reads
  `.discrimination_evidence` alongside `.criterion`/`.passed`/`.evidence`, so
  the evidence reaches the human reviewing the PR instead of being silently
  dropped by a jq filter that read only the original three fields.
  **The field itself is schema-optional and unenforced by §3d/§3e.5 by
  design** (kernel principle 7, advisory over enforced discipline) — so a
  worker that simply omits it degrades LEGIBLY instead of silently: a new
  `discriminationGaps()` in `build-level.mjs` detects any `passed: true` entry
  with an empty/absent `discrimination_evidence` once `requireDiscriminationEvidence`
  is armed, logs a named warning at 3h once the PR number is known, and
  carries the gap list on the parked record's new `discrimination_gaps` field
  for the orchestrator to roll into the Step 6 summary — mirroring the
  existing `verification_surface` degraded-case pattern (build.md §3f step 2)
  exactly. A criterion deferred to the parent-side §3e.5 acceptance gate
  (build.md's pre-existing #997 carve-out) is a distinct, explicit exemption
  — its `discrimination_evidence` reads `deferred to §3e.5; discrimination not
  established worker-side` rather than being left empty or fabricated.
  `claude/presentation-plane.md` gains a kernel-table row registering the
  worker verdict JSON as a machine-parsed surface (schema in
  `build-level.mjs`, prose contract in `claude/commands/build.md` §3c/§3d,
  kept in lockstep by a new static guard in
  `workflows/scripts/build/tests/test_workflow.sh`). `PROSE_BUDGET_TIER2_FILE_CAP`
  (`workflows/scripts/build/build.config.sh`) is raised 1111 → 1130 to fund
  this item's degraded-case prose plus headroom for the concurrently-building
  sibling item #1430.

- **`/build` workers are now told the engineering principles they're expected
  to weigh against.** `claude/commands/build.md` §3c required embedding the
  effective (kernel ∪ project) engineering principle set in every worker
  prompt, but nothing implemented it. A new **§ Step 1.8** resolves the
  merged set once per run, per distinct `(repo, project)` pair — the kernel
  set from `claude/engineering-principles.md` merged with the project's own
  `## Principles` extension, per that file's § Merge semantics — and hands
  the rendered result to `claude/workflows/build-level.mjs` as two new
  `args` keys on the same Step-0 hand-off seam as `machinerySoloModel`/
  `gateSliceSecs`: `principlesSummaries` and `principlesDefaultRepo`.
  `workerPrompt()` embeds the resolved set as a tagged `[kernel]`/`[project]`
  numbered list in a new `## Effective engineering principles` section,
  reused (not re-resolved) by §3e's pre-push reviewer. A caller that omits
  the new args keys — `sweep.md`/`fix.md` today — still gets a bounded,
  legible prompt: `workerPrompt()` falls back to a static kernel-only
  snapshot plus an explicit `DEGRADED` notice, never a silent empty set.

- **`bin/bootstrap.sh` gains `TEMPERLOOP_KERNEL_REF`, so a CI dry run can
  finally test the ref it was dispatched against** (#1474). Bootstrap pins a
  fresh install to the newest `v*` tag it can see, never to the ref its caller
  checked out — which is exactly right for a newcomer's `curl … | sh`, and
  exactly wrong for `install-tier2`'s documented "pre-tag dry run against
  `main`". That second use silently reinstalled the *last release* and
  reported on it: a dispatch carrying a just-merged fix reproduced the very
  bug it fixed, because the fix was not in any tag yet. The new override is a
  sibling of `TEMPERLOOP_KERNEL_REPO` — `REPO` says which clone URL to install
  from, `REF` says which ref inside it to land on — and accepts any commit-ish
  (a SHA, tag, branch, `origin/main`). Two properties are deliberate: it
  applies to a **first install only**, never the re-run path (which still
  delegates entirely to `temperloop update`); and a set-but-unresolvable ref
  is a **hard failure naming the ref**, never a quiet demotion to the newest
  tag — a fallback would recreate the same "claims to test one thing, tests
  another" confusion. Unset *or empty* is the unchanged default. **If you
  install via bootstrap:** nothing changes unless you set the variable.
  `install-tier2` sets it to the checked-out commit on a `workflow_dispatch`
  run only; a tag-triggered release-gate run leaves it unset, so the gate
  keeps the exact newcomer code path with no CI-only knob in it.

- **`/tidy`'s drain findings emission is now mechanically corroborated, not
  self-reported** (#1576). A drain run's Step 6 summary once asserted
  "Findings records: 16 emitted (8 accepted, 8 rejected)" while **zero** rows
  actually existed in `meta/data/raw/findings-<YYYY-MM>.jsonl` that day — an
  unverified positive-work claim the run had no way to catch on its own. The
  new `workflows/scripts/drain/findings_integrity.py` checker (the single
  findings-integrity checker; a follow-up item extends this same file rather
  than adding a sibling script) compares a drain run's per-session
  self-reported accept/reject tally against the rows that actually landed in
  the append-only findings stream, printing the literal token
  `FINDINGS_EMITTED_MISMATCH` on any divergence — including the case where a
  processed transcript found candidates to adjudicate but landed zero rows
  (distinguished from a transcript with genuinely nothing to extract, which
  legitimately self-reports and lands zero). `claude/commands/tidy.md`'s
  Findings records step now runs this check before writing the summary line,
  and treats a mismatch as a run failure to surface, not a log line.

- **`findings_integrity.py` now catches a null `subject_model` that should
  have been populated** (#1584). Findings records have carried
  `subject_model: null` while `analyst_model` is populated, collapsing the
  attribution split that exists so a defect is credited to the model that
  *produced* it rather than the one that *found* it. A new `--check-subject-model`
  mode scans every `findings-*.jsonl` record with `subject_model: null`,
  resolves its `session_id` to the archived session stub
  (`meta/sessions/archive/`, matched on the same leading-8-char `id8` the
  archiver's own filename convention uses), and flags the record with the
  literal token `SUBJECT_MODEL_MISSING` only when that stub's frontmatter
  actually carried a `model:` line — a stub that genuinely had no `model:`
  line (38% of archived stubs, 312 of 814, measured) is never flagged, since
  a false-positive-happy guard here is worse than no guard. Extends the
  single findings-integrity checker (`workflows/scripts/drain/findings_integrity.py`,
  #1576) rather than adding a parallel mechanism.

- **`env-reconcile.sh` now detects a stale composed `~/.claude/CLAUDE.md`**
  (`COMPOSED_STALE`, #1618). The installed `CLAUDE.md` is a real generated
  file (kernel doc + overlay + a rendered knowledge-store-routing section) —
  deliberately not a symlink, so `make doctor`'s symlink classifier cannot
  see it drift. A composed file older, by mtime, than
  `claude/CLAUDE.kernel.md`, `claude/CLAUDE.overlay.md`, or
  `workflows/scripts/build/build.config.sh` under the checkout named by the
  new `ENV_RECONCILE_CLAUDE_MD_SOURCE_CHECKOUT` override now reports
  `COMPOSED_STALE:<input>` as operator-checkout-role drift, in both
  `--format report` and `--format entry`. The comparison is mtime,
  deliberately never `cmp` — the composed file has no expected-content
  baseline to diff against without re-running the compose. With
  `ENV_RECONCILE_CLAUDE_MD_SOURCE_CHECKOUT` unset (the default — this script
  never guesses which checkout produced the install), or with the composed
  file / any named input missing, the check reports `UNVERIFIABLE` rather
  than crashing or false-claiming clean. Report-only: never re-runs
  `install-claude-md.sh` / `make install-claude`, never touches `~/.claude/`.

`env-reconcile.sh` now reports **`AGENT_CHECKOUT_BEHIND`** — a new drift class on the launchd-agent role. Each declared `infra/launchd/*.plist`'s `WorkingDirectory` is read and, when it resolves to a git checkout, compared against the already-fetched `origin/<default>` (reusing the same `default_branch_of` → `git merge-base --is-ancestor` mechanism `BEHIND_MAIN` uses, now factored into a shared `_behind_origin_default` helper). This closes the gap where a merged fix can close its issue, move its board item to Done, and still never reach the nightly actually running from a stale checkout — every other signal reads green. Report-only and read-only: never fetches, never mutates the target checkout. Fails open on an absent `WorkingDirectory` key, a non-existent path, or a path that isn't a git checkout — reported as "can't verify," never a crash or a false BEHIND claim. Emitted in both `--format report` and `--format entry`.

- **A new CI gate now requires every registered check surface to prove it can
  fail — ship a fixture asserting a non-zero exit on absent, unreadable, and
  empty input — closing the class behind epic #1409's three motivating
  defects** (a validator that read `OK` / exit 0 off input it never actually
  read). `workflows/scripts/validate-check-surface-degenerate-coverage.sh`
  enforces a REGISTRY (`workflows/scripts/config/check-surface-registry.tsv`),
  not a `validate-*.sh` filename glob — a registry row names either a bare
  script or a `<script>:<subcommand>` pair, so `replay.sh diff-scope` (a
  subcommand of a general orchestration script, unreachable by any filename
  glob) is registerable. Surfaces not yet compliant ride an explicit,
  shrink-only ratchet (`workflows/scripts/config/check-surface-degenerate-allowlist.tsv`)
  — the gate FAILS if the allowlist grows, diffed against the committed copy
  at `origin/main`, with an explicit bootstrap exemption for the commit that
  introduces the file itself. Seeded with the epic's three motivating
  surfaces: `validate-provider-disclosure.sh` gets brand-new dedicated
  degenerate-input fixtures (`workflows/scripts/tests/test_validate_provider_disclosure.sh`
  — absent committed allowlist, unreadable disclosure log, and an
  emptied-in-place log whose watermark anchor still records entries);
  `validate-model-usage-emit.sh` and `replay.sh diff-scope` are registered
  as already-compliant against their existing fixtures (`test_model_usage_emit.sh`,
  `test_replay_isolation.sh`), unmodified. `tagging.sh` (#1480) and
  `batch.sh`'s line-141 bootstrap check (#1487) are named on the allowlist,
  explicitly out of this item's scope. The gate is itself fail-closed —
  routed through the shared `cannot_evaluate_emit` idiom
  (`workflows/scripts/lib/cannot-evaluate.sh`) on an unreadable registry/
  allowlist/registered test file or an unresolvable ratchet base ref — and
  every ordinary failure names the exact surface and case (`MISSING-FIXTURE`,
  `TEST-FILE-NOT-GATED`, `REGISTRY-INCOMPLETE`, `ALLOWLIST-GREW`, ...),
  never a bare non-zero exit. Its own fixture suite
  (`workflows/scripts/tests/test_check_surface_degenerate_coverage.sh`)
  proves the gate discriminates by mutation — delete a registered fixture's
  anchor, confirm RED naming the surface+case, restore, confirm GREEN — plus
  the allowlist-growth ratchet against a throwaway git fixture and every
  CANNOT-EVALUATE fail-closed path.

### Changed

- **Product docs rewritten end to end around a ratified value statement**
  (#1407). `README.md` and the top-level `docs/` pages now lead with what
  TemperLoop delivers (reviewed CI-gated PRs, collision-free parallel
  agents, an autonomous backlog with human-gated merges, free-repo support,
  a readable toolkit) in plain language; the README's opening essay moved to
  `docs/about.md`, and a new `docs/using-the-pipeline.md` carries the
  day-to-day operating guide. Every rewritten page ends with an
  AI-authorship footer (`*Written by <model-id> on <date>.*`), enforced by a
  new quality gate (`workflows/scripts/validate-docs-footer.sh`) whose
  exemption list covers the deliberately-untouched families
  (`docs/features/`, `docs/adr/`, `docs/failure-modes/`) and fails when an
  exempt page gains a footer, so the list can't go stale silently.

- **The tier-2 install round trip now runs on release tags, not weekly.**
  `.github/workflows/install-tier2.yml` drops its `schedule` (Mondays 05:00 UTC)
  and triggers on a `v*.*.0` tag push — minor and major cuts; a patch tag
  deliberately does not fire it. `workflow_dispatch` remains, for an ad-hoc
  drift probe during a release gap or a pre-tag dry run against `main`. The
  timing now matches semantics that were already there: `bin/bootstrap.sh` pins
  a fresh install to the newest `v*` tag rather than the checked-out ref, so the
  weekly run was already testing the last release tag, at an arbitrary moment.
  On a tag-triggered run the version leg additionally asserts that the tag
  bootstrap pinned to *is* the tag that triggered the run, so a green run proves
  the release being cut was the one tested. **If you cut kernel releases:**
  `VERSIONING.md` § Cutting a release step 4 now blocks propagation
  (`make update-kernel KERNEL_TAG=v<new>`) on that run being green — the tag is
  pushed by hand, so the gate lands on propagation rather than on tagging.
  Accepted trade-off: the weekly cron was the only thing catching drift external
  to the repo (a GitHub API change, a `gh` update, the demo repo rotting) with no
  commit involved; that now surfaces at cut time, and a long release gap should
  be covered by a manual `workflow_dispatch`.

`drain/vault_hygiene_report.sh --format entry` now rolls alarms up **by class** past `CLASS_ROLLUP_THRESHOLD` (default 10) instead of inlining every alarm line, so the vault-hygiene surface note stays readable as drift accumulates. A rolled-up class renders as one `CLASS ROLL-UP` line carrying the number of lines rolled up plus one example; a class at or under the threshold is emitted byte-identically to before. Class-**summary** lines (a running total, or an anti-truncation "N not shown") are recorded via a new `add_summary` seam and are never rolled up nor counted, so a capped list can never silently read as the whole list. The default `report` format is unchanged.

### Fixed

- **`validate-model-usage-emit.sh`'s stderr no longer goes silent after it
  opens a lake file to read.** The open used a bare `exec 3< "$src"
  2>/dev/null` — `exec` with no command word applies its redirects
  PERMANENTLY to the current shell once the open succeeds, which was quietly
  redirecting the validator's own stderr to `/dev/null` for the rest of the
  run. On the failure path this was harmless (bash stops at the first failed
  redirection, so the `CANNOT EVALUATE` message still printed) and the one
  surviving stderr writer already carried its own `2>/dev/null` — but any
  future diagnostic added after that line would have vanished with no test
  failure to catch it (temperloop#1370). The open is now scoped with a
  command group, `{ exec 3< "$src"; } 2>/dev/null`, matching the idiom
  `workflows/scripts/model-comparison/tagging.sh:357` already uses (and
  documents) for the identical hazard — the `2>/dev/null` now applies only to
  the open attempt, not to the shell for the remainder of the script. A
  repo-wide sweep confirms this was the only bare `exec N< ... 2>/dev/null`
  site left in the tree.

- **`/build`'s mandatory pre-push review now actually runs on the default
  Workflow path.** `claude/commands/build.md` §3e requires a `workflow-reviewer`
  pass on every item whose diff touches `claude/commands/*.md` (foundation#1007),
  but the 3c worker cannot spawn a nested subagent — so on the default
  (Workflow) build path the gate collapsed to a **structurally guaranteed**
  `skipped — unavailable`, indistinguishable from a genuine unavailability.
  `claude/workflows/build-level.mjs`'s `driveItem` now runs §3e itself, between
  3d and 3e.5: it fetches the item's changed-file list and the
  `reviewer-routing.tsv` off the worktree, resolves the full routing rule set
  (`determineReviewers` — the `review:` override, the `architectural` change
  kind, the tsv extension/glob axis, the prose `*.md` fallback, and the
  mandatory `claude/commands/*.md` → `workflow-reviewer` rule), and spawns each
  matching reviewer directly via `agent({agentType})`. A `HIGH`-severity finding
  escalates `review-blocking` before 3f (push); reviewer unavailability
  degrades legibly (reusing `machineryAgent`'s own resolution-failure catch),
  and a real pass's outcome now rides the PR body via the verdict `summary`, so
  `workflows/scripts/workflow-reviewer-coverage.sh` can actually observe
  coverage going forward. §3e also now records why this review runs *inside*
  the workflow rather than the conversational orchestrator: the
  orchestrator↔workflow boundary is irreversible-action-plus-single-writer, and
  by the time the workflow returns, the item is already pushed with its PR open
  and the orchestrator's post-return partition removes the worktree a review
  would need to inspect.

- **The tier-2 install round trip no longer dies at the proposal commit for
  want of a git identity, and the generator now says so in words.** A GitHub
  Actions runner ships with no `user.name`/`user.email`, and
  `workflows/scripts/proposal/proposal-pr.sh` commits the proposed tree before
  pushing it — so `install-tier2.yml`'s `init` leg failed with a raw "Author
  identity unknown / fatal: empty ident name" buried inside a JSON `error`
  string, after the proposal branch had already been cut. Two fixes, at two
  altitudes. The workflow configures the standard `github-actions[bot]`
  identity in a step of its own before the round trip. And the generator now
  **preflights** the identity before it touches the checkout: if neither
  `git config user.name`/`user.email` nor git's own
  `GIT_AUTHOR_*`/`GIT_COMMITTER_*` resolution yields one, it refuses with the
  usual structured `ERROR` outcome *plus* a plain-text remedy on stderr naming
  the exact two `git config --global` commands to run. It never invents an
  identity — authoring an adopter's first commit as someone they never chose
  is worse than a clear refusal — and because it refuses before the
  `checkout -B`, the checkout is no longer left stranded on a half-built
  proposal branch.

- **`temperloop init`'s first-epic idempotency probe no longer turns any API
  error into "already filed"** (#1444). The probe searches the adopter's repo
  for the design-brief / decline markers before offering the pre-designed first
  epic, and it was broken two ways at once. GitHub's `search/issues` endpoint
  now **requires** an `is:issue` or `is:pull-request` qualifier and 422s without
  one — external drift, no commit here caused it — and `gh` writes its error
  **body to stdout**, so the probe's fail-open (`2>/dev/null || true`) handed
  that raw JSON blob back as the issue number. It tested non-empty, so `init`
  printed `first-epic: already filed as #{"message":"Query must include
  'is:issue' …","status":"422"}` and passed the blob into the handoff too. Any
  probe error — rate limit, network blip, auth scope, outage — silently
  disabled the first-epic offer while claiming the epic existed. Both queries
  now carry `is:issue`, and — the durable half — the captured value is
  validated digits-only before it is ever treated as an issue number, so no
  future error body can be mistaken for a hit either. The probe is now
  three-valued: already-filed, not-filed, or **UNKNOWN**. An unanswerable probe
  withholds the offer rather than risk a duplicate epic, and says so on its own
  `first-epic:` line instead of skipping silently. `install-tier2`'s `init` leg
  additionally asserts the offer was disposed through a **legitimate arm** — a
  final `first-epic:` line of a known-good form, and, on the already-filed form,
  an issue number that is actually digits — so this exact corruption now fails
  the release gate instead of reading as a clean skip. That assertion
  deliberately does not pin the *ambient-CI* arm specifically: that arm is only
  reachable while the demo repo has no first epic filed, so pinning it would
  make a release gate hostage to demo-repo issue state.

- **`/build`'s class-A activation gate no longer has a dead arm that skips
  itself.** `claude/commands/build.md` §3e.6 routed a `class: A` activation
  block carrying no `proof:` predicate to "invoke the `/verify` skill", paired
  with a legible-degradation clause authorizing `skipped — /verify unavailable`
  when that skill was absent. No `/verify` has ever existed in this repo — no
  `claude/commands/verify.md`, no other definition — so that arm of a
  *mandatory* gate could only ever resolve to its own skip notice: the
  temperloop#1387 shape, a pre-authorized degradation clause dressing a
  structurally-dead route as an accepted fallback. Both bullets are now gone.
  The no-predicate case is instead **unreachable by construction** — plan-schema
  **rule 13** already fails validation for a class-A block with no `proof:`
  (`workflows/scripts/build/plan.sh`), and `/build` Step 1's validation
  checklist now names that rule explicitly, so the front door enforces the
  invariant 3e.6 depends on. Should such an item still arrive (a plan note
  hand-edited past Step 1), 3e.6 escalates `activation-proof-missing` and loops
  back to 3c exactly like a Fail — there is no fallback actor and no skip arm.
  `claude/plan-schema.md` § activation drops its matching "`/build` falls back
  to driving `/verify`" sentence and states that `proof:` is mandatory;
  `claude/message-schema.md` § degradation notice keeps its `/verify` reference
  only as the worked example of the failure, noting that the fix was deleting
  the route rather than keeping the notice. New static lockstep guards in
  `workflows/scripts/build/tests/test_plan.sh` (search `K1451`) sit beside the
  rule-13 behavior cases and fail if any half is reverted independently: the
  escalation token must be present, no `skipped — /verify` line may reappear in
  build.md, neither build.md nor plan-schema.md may route to `/verify` while
  `claude/commands/verify.md` is absent (the clause self-silences if a real
  `/verify` ever ships), and build.md must keep naming rule 13.

- **`/build` Step 3h.5's as-you-go merge is now explicitly scoped to the
  `--no-workflow` conversational path, instead of being owned by nobody on the
  default path.** `claude/commands/build.md` §3h.5 described an item merging at
  its own CI-green, but on the default Workflow path no actor could perform it:
  `build-level.mjs` **never merges and never writes the plan note** (both seats
  3h.5 needs — the `[>]` flip must be durable *before* the merge call), and the
  orchestrator's `parallel(driveItem)` returns only at the **level boundary**,
  by which time "its own green" has passed for every item. So a `[>]` sentinel
  was defined, consumed by the Step-4 gate and by resume, and produced by no
  one — while §3e's temperloop#1430 paragraph simultaneously claimed the
  workflow *owned* the as-you-go merge, contradicting the same file's
  "NEVER merges" contract. §3h.5 now opens with a SCOPE paragraph naming the
  conversational orchestrator as its actor and stating the **accepted
  trade-off** for the default path — every item parks `[m]` and takes the
  single level-boundary gate, re-paying the merge-queue pileup temperloop#1026
  measured — with `--no-workflow` as the way to get as-you-go merging, the same
  shape as the speculative-next-level NON-GOAL. §3e's #1430 paragraph drops the
  false merge-ownership claim (and its stale "3h has removed the worktree"
  clause: on this path the *orchestrator's* post-return partition removes it)
  while keeping the push-before-review reasoning that puts §3e inside
  `driveItem`. The Step-4 gate, the goal statement, the operating principle,
  the Step-1.4 resume rows, 4d, `claude/plan-schema.md`'s `[>]` and consent-line
  definitions, `docs/features/merge-gate.md`, `docs/features/build-machinery.md`,
  `gate.sh` / `emit-item-efficiency.sh` headers, and the
  `BUILD_MERGE_AS_YOU_GO` config comment + `setting-registry.tsv` row all now
  carry the same path scope — the setting is read on the conversational path
  and inert on the default one. No behavior change: nothing performed 3h.5 on
  the Workflow path before this either.

- **`/sweep` and `/fix` now pass the two `build-level.mjs` hand-offs they were
  silently dropping.** Both commands drive the shared
  `claude/workflows/build-level.mjs`, but only `claude/commands/build.md`
  resolved and passed `machineryBinDir` and
  `principlesSummaries`/`principlesDefaultRepo`. The two omissions degraded
  silently: without `machineryBinDir`, `machineryBin()` fell back to the nested
  `$(dirname "$(readlink -f …)")` command-substitution the auto-mode classifier
  denies as an obfuscated-command bypass on `--unattended` runs (temperloop#72)
  — and `--unattended` is `/sweep`'s default posture, so every push/worktree
  machinery step drew a denial burst; without the principles pair, every
  `/sweep` and `/fix` worker permanently ran `workerPrompt()`'s static
  kernel-only `DEGRADED` fallback with no project `## Principles` extension
  applied. Each command now resolves `machineryBinDir` in its own Step 0 with
  the same plain `cd`+`pwd` form `/build` uses, and resolves the effective
  (kernel ∪ project) principle set by pointing at `build.md` § Step 1.8 (the
  single implementation) with the one-pair simplification their single-repo
  scope allows. The existing three-caller guard in
  `workflows/scripts/build/tests/test_workflow.sh` — which already iterated
  build/fix/sweep for `gateSliceSecs` — now covers both new fields, and
  `build.md`'s prose no longer names the two commands as the un-wired
  exceptions.

`/tidy` Step 0 no longer deadlocks every subsequent drain on a stalled archive PR. It previously early-exited on **any** open archive PR with one line into a log nobody reads, so a PR that went red on a stale base blocked extraction indefinitely with no alarm and no recovery path (observed: 7–26 session stubs stranded for days). Step 0 now classifies the open PR using the same predicate `archive-session.sh` uses — stalled ⟺ its checks rollup is `FAILURE`, or its `mergeStateStatus` is `BEHIND` — and on a stalled PR invokes the archiver's `heal-stalled-pr` entry point to rebase its branch onto the default branch, so the next run finds it green. The drain still exits without extracting on every path (the efficiency early-exit is preserved), and the stalled outcome — healed or heal-failed — is now surfaced as a pending-decisions entry rather than a silent skip. The check remains fail-open on a `gh` error.

`/tidy`'s nightly headless run no longer dies at the cross-machine drain lock's sync-wait. Step 0's lock protocol previously had one arm: acquire → wait `TIDY_SYNC_WAIT` seconds via a **backgrounded** sleep → elect the earliest-timestamped lock. A `claude -p` one-shot has no re-invoke-on-background-completion loop (the same fact `build.md` § 3g keys its own headless branch on), so the nightly cron run ended the session *at* the wait and never resumed at the election — every night's drain lost to a zero-stub no-op. Step 0 item 4 now selects between two arms on exactly that predicate, `PIPELINE_OPERATOR_ABSENT=1`: a loop-capable run keeps the wait-and-elect path unchanged, while a headless run takes a new non-blocking arm (item 4f) with `--force-now` semantics — no sync wait, no election, never blocks. The headless arm still writes its own `.drain.lock.<HOST>` and still yields to a peer: it first does one cheap read of the lock files already listed, reaps any past `TIDY_LOCK_STALE_AFTER`, and skips the drain as a legible no-op if a live peer lock remains. Its residual risk is stated narrowly rather than implied away — Step 4's search-then-add dedup absorbs Things-task duplication **only**, so vault-note duplication in the check-then-write TOCTOU window is recorded as an accepted residual risk. The stale-lock reap (both arms) now names its failure path: the delete is best-effort, and a failed delete just leaves the lock for a later run to reap. The kernel ships no nightly plist — exporting `PIPELINE_OPERATOR_ABSENT=1` from the overlay's nightly wrapper is the install half of this fix, and a wrapper that omits it behaves exactly as before.

- **The "cannot evaluate" idiom now fails CLOSED instead of open when a
  caller forgets to branch on it** (#1475). Five independently reinvented
  `*_cannot_evaluate()` functions across
  `workflows/scripts/model-comparison/{batch,judge,score,replay}.sh` — four
  byte-identical modulo a script-name prefix — every one of them returning 0
  (a bare `jq`+`printf` body with no explicit `return`, so the function's
  own exit status was whatever `printf` happened to return). A caller that
  forgot to branch on the result fell straight through to the OK path — the
  exact defect shape epic #1409 targets, reinvented inside the idiom meant
  to prevent it. All five now delegate to one shared helper,
  `cannot_evaluate_emit` in the new `workflows/scripts/lib/cannot-evaluate.sh`,
  which returns the reserved `RC_CANNOT_EVALUATE` (2) as its OWN status —
  converging on the same value three sibling standalone conventions already
  used (`KERNEL_LIB_RC_CANNOT_EVALUATE`, `PA_RC_CANNOT_EVALUATE`,
  `FD_RC_CANNOT_EVALUATE`) rather than minting a fourth. `replay.sh`'s
  `preflight` — the one instance that previously printed the machine JSON
  verdict but no human-readable stderr diagnostic — now prints one, matching
  its four siblings. Every existing call site already followed the old
  helper with its own explicit `return 1`, so no observed exit behavior
  changes; the fix is forward-looking, for the next caller that doesn't.
  The reserved code and the two output shapes are registered as a
  machine-parsed surface in `claude/presentation-plane.md`.

- **Six kernel gates that broke in a composed overlay checkout (a repo
  vendoring this kernel as a subtree, e.g. foundation) now self-scope or work
  correctly there, while still running for real in the kernel's own
  checkout** (#1490):
  - `scripts/lint-pipe-grep-q.sh` matched its two self-exempt files by a
    literal `$REPO_ROOT`-prefixed path, so a vendoring overlay's compat
    symlink (`scripts/lint-pipe-grep-q.sh -> ../kernel/scripts/lint-pipe-
    grep-q.sh`) resolved `REPO_ROOT` to the overlay root and the lint's own
    vendored originals under `kernel/` never matched — producing false
    positives against the lint's own deliberate fixtures. Self-exemption is
    now by RESOLVED (symlink-followed) path on both sides of the comparison,
    so only the two named files are exempt — a genuine violation elsewhere
    under a vendored `kernel/` tree is still flagged.
  - `scripts/tests/test_assemble_changelog.sh` demanded a root
    `CHANGELOG.md` unconditionally; a consumer may not use the changelog
    fragment workflow at its own root at all. It now emits a legible SKIP
    when no `CHANGELOG.md` is present.
  - `workflows/scripts/validate-onramp-anchors.sh` (and its test) demanded
    the consumer's own `README.md`/`bin/README.md`/`bin/temperloop`/
    `docs/features/install-cli.md` carry the kernel's adopter onramp
    narrative — kernel-product prose a vendoring consumer repo has no
    obligation to carry. Both now detect a composed overlay tree (the same
    two-signal detection `sandbox_skip_if_composed_tree` already uses) and
    emit a legible SKIP there.
  - `workflows/scripts/pipeline-spend-report.sh`'s `--by-agent-type` agent
    allowlist walked `claude/agents` with a bare `find`, which macOS/BSD
    `find` silently refuses to descend into when the directory is a
    SYMLINK (the compat-symlink shape every vendoring consumer uses for
    `claude/agents`) — collapsing `recognized_agent_definitions` to 0 and
    every seat assertion to unattributed. Now uses `find -L` so a symlinked
    `claude/agents` resolves exactly like a real one.
  - `workflows/scripts/board/tests/test_board_host_label.sh` resolved its
    search root with plain `pwd` (not `pwd -P`), so a vendoring consumer's
    compat symlink (`workflows/scripts/board -> ../../kernel/workflows/
    scripts/board`) kept the symlink in the path — and real macOS/BSD grep
    (unlike GNU grep) silently refuses to descend into a symlinked
    top-level directory argument, so the structural "exactly one inline
    site" check found nothing and failed. Now resolves physical
    (`pwd -P`) throughout.
  - `workflows/scripts/model-comparison/tests/test_comparison_report.sh`'s
    `mkmirror()` helper used a plain `cp -R` to relocate the
    `model-comparison/` directory into a throwaway mutation-testing scratch
    dir. On a consumer whose files under that directory are individual
    relative symlinks into the vendored `kernel/` copy, `cp -R` preserves
    those symlinks as symlinks rather than copying their content — so once
    relocated to a scratch dir with no `kernel/` sibling, they go dangling
    and the mirrored producer degrades ("comparison-statistics library is
    missing") before the mutation under test is ever reached. Now uses
    `cp -RL` to dereference.

  Each fix ships a regression test that reproduces the exact composed-overlay
  symlink shape (a synthetic `kernel/` subtree plus compat symlinks at the
  overlay path) and proves both directions: the gate still catches a real
  problem there, and the kernel's own checkout is unaffected.

- **Two published contract documents corrected to match the code they
  document, both found by a spike measuring detection shapes rather than by
  review or CI** (#1495):
  - `workflows/scripts/lib/knowledge_store.contract.md` claimed "there is no
    second path setting" for the store root. `ks_root()` in
    `knowledge_store.sh` has, since temperloop#1328, resolved an unset
    `KNOWLEDGE_STORE_ROOT` through `_ks_machine_conf_root()` — a
    machine-local config file read — before falling back to the XDG
    default. The doc now states that precedence explicitly.
  - `workflows/scripts/lib/tracker.contract.md` documented
    `board_sub_issues <N> <issue#>` as taking two arguments. `board_sub_issues()`
    in `board.sh` has, since temperloop#1119, taken an optional third
    `[all|open|closed]` state-filter argument defaulting to `all`. The doc
    now shows the real arity.

## [0.29.0] - 2026-08-13 — BREAKING

### Changed — BREAKING

- **`/sweep`'s spike-close arm now lands a real board Done write via
  `board_close_done`, and both arms' false close→Done "cascade" claim is
  purged** (#1280). The spike arm (`pr` is `null`) previously ran a bare
  `gh issue close` that bypassed the adapter entirely, stranding a
  `fnd:status:*` label and a `fnd:host/session:*` claim stamp on every spike
  close — it now posts its verdict comment, then calls
  `board_close_done "$BOARD" <N>` (behind a `declare -F` fallback guard for a
  vendored `board.sh` predating the helper), which strips both and fires the
  adapter's own write-through cache invalidation, so the hand-rolled
  guarded-source `lib/cache.sh` / `cache_dirty` call is removed. The merge arm
  (`pr` set) deliberately gains **no** Done write — `gh pr merge --auto` only
  enqueues, so a Done write there would close the issue before the merge
  lands, breaking the `Closes #N` linkage; its Done write is deferred to a
  confirmed-`MERGED` point owned by temperloop#1268, mirroring the existing
  cache-bust deferral on that same arm. Both arms' prior "the close→Done
  cascade moves the card" claim — inaccurate on this issues-only backend,
  which has no such automation — is deleted throughout `claude/commands/sweep.md`
  and replaced with what actually happens: the close makes the item read Done
  immediately (checked before any label), but the status label and claim
  stamp stay standing unless the adapter's Done write runs.
- **`install-tier2.yml` is re-scoped off the retired `try` path onto the
  `init` -> `eject` adopt-path round trip against the persistent
  `Towheads/temperloop-demo` repo** (#1234). Drops the `temperloop try` step
  and `ANTHROPIC_API_KEY` entirely (no leg makes a model call), and no longer
  invokes the deleted `seed-demo-repo.sh`. The workflow never creates or
  deletes a repository — `DEMO_REPO_TOKEN` is a fine-grained PAT scoped to
  that one repo — and `eject`'s manifest-driven revert is what returns the
  repo to a reusable baseline each run. ADR 0025's "CI inherits the rule"
  consequence is amended to record the resulting accepted gap: no weekly
  automated coverage of `temperloop testbed` or its teardown.
- **The three `claude -p` seats in `bin/` now capture the `--output-format
  json` envelope instead of raw text** (#1264). `try.sh`'s shadow-triage call
  (C1) and `--demo` fix call (C2), and `configure.sh`'s AI-suggestions call
  (C3), all switch `--output-format text` → `json` and unwrap `.result` at the
  call site, so each call's own `usage` / `modelUsage` / `total_cost_usd` /
  `duration_ms` block is captured in a named variable for a future attribution
  emit. These seats pass `--no-session-persistence` and so write no transcript,
  which made them invisible to the tokens producer; the envelope is what makes
  them measurable without a one-off replay. `--tools ""`,
  `--no-session-persistence` and `--max-budget-usd` are unchanged at all three
  seats, and the model's own output is still printed/applied verbatim.

- **`/triage`'s cull, decision-route, and funnel-escalation close arms now
  route their Done writes through `board_close_done`** (#1217), guarded
  `if declare -F board_close_done` with a resolve-based fallback for a
  vendored `board.sh` that predates the helper. Each arm posts its reason
  comment first, then lands Done unconditionally — no more an `or`-branch a
  reader could take as optional, and no more a bare `gh issue close` in the
  funnel-escalation arm that left the board unstamped. Also deletes the
  false claim that a built-in close→Done automation reflects a close on the
  board (no such mechanism exists on this issues-only backend — see
  `workflows/scripts/board/ISSUES-ONLY-BACKEND.md` § Close→Done cascade) and
  corrects the Step 4.6 cache-bust note: the real hazard is that shell state
  does not persist between separate Bash tool calls, not a
  `board_set_milestone` cache-bust (it never dirties the cache).
- **`install-tier2.yml` is re-scoped off the retired `try` path onto the
  `init` -> `eject` adopt-path round trip against the persistent
  `Towheads/temperloop-demo` repo** (#1234). Drops the `temperloop try` step
  and `ANTHROPIC_API_KEY` entirely (no leg makes a model call), and no longer
  invokes the deleted `seed-demo-repo.sh`. The workflow never creates or
  deletes a repository — `DEMO_REPO_TOKEN` is a fine-grained PAT scoped to
  that one repo — and `eject`'s manifest-driven revert is what returns the
  repo to a reusable baseline each run. ADR 0025's "CI inherits the rule"
  consequence is amended to record the resulting accepted gap: no weekly
  automated coverage of `temperloop testbed` or its teardown.
- **The three `claude -p` seats in `bin/` now capture the `--output-format
  json` envelope instead of raw text** (#1264). `try.sh`'s shadow-triage call
  (C1) and `--demo` fix call (C2), and `configure.sh`'s AI-suggestions call
  (C3), all switch `--output-format text` → `json` and unwrap `.result` at the
  call site, so each call's own `usage` / `modelUsage` / `total_cost_usd` /
  `duration_ms` block is captured in a named variable for a future attribution
  emit. These seats pass `--no-session-persistence` and so write no transcript,
  which made them invisible to the tokens producer; the envelope is what makes
  them measurable without a one-off replay. `--tools ""`,
  `--no-session-persistence` and `--max-budget-usd` are unchanged at all three
  seats, and the model's own output is still printed/applied verbatim.

  **User-visible degradation lines** are the behavior change: a response the
  wrapper cannot read now says so specifically rather than failing opaquely,
  and each distinct cause gets its own message so a format change costs a
  *missing* number, never a wrong one — `returned an unparseable envelope`
  (the envelope itself did not parse), `returned an empty report` (C1: the
  envelope parsed and the model simply reported nothing), and `jq not on PATH`
  (C3: jq is an optional dependency of the wizard, and its absence is no
  longer misreported as a bad envelope). On every one of these the command
  degrades exactly as it did before — `try` skips the triage section and exits
  0, `configure` falls back to plain prompts and still writes. C2's
  parse-failure debug line now echoes the model's own `.result` when it is
  readable, falling back to the whole envelope only when it is not, so a
  first-run failure no longer prints `session_id` / `uuid` / cost internals.

  Not breaking: no overlay, config, or caller has to adapt.
- **Changelog entries can now be written as per-entry files under
  `changelog.d/` instead of edits to `CHANGELOG.md`** (#1321). `VERSIONING.md`
  requires an `## [Unreleased]` entry for every contract-surface change, so 25
  of the last 25 commits touched `CHANGELOG.md` and any two concurrent PRs
  collided structurally on it. A fragment is one file — `<slug>.<category>
  [.breaking].md`, e.g. `1321-changelog-fragment-format.changed.md` — so two
  concurrent PRs write disjoint files, share no line, and cannot conflict. The
  format is **index-free**: category, breakingness and sort key all derive from
  the filename, because a shared ordering file would recreate the identical
  hotspot one directory over. `scripts/assemble-changelog.sh` folds the
  accumulated fragments into `## [Unreleased]` at the release cut and deletes
  them; parsing lives in `workflows/scripts/lib/changelog.sh` beside the range
  helpers, as ADR-0002's layering rule requires. The assembler is **additive**
  — it merges into a non-empty `[Unreleased]` rather than replacing it, so
  nothing accumulated since the last tag is dropped and an in-flight PR still
  writing a direct entry stays harmless. The merge is also **insert-only**:
  every pre-existing line of `[Unreleased]` is re-emitted byte-for-byte, blank
  lines and consecutive blank runs included, and the only lines that differ
  from the input are the ones being added. That is a correctness property
  rather than tidiness — an emitter that RECONSTRUCTED the section instead
  made its output depend on incidental whitespace in the input, so the same
  code assembled purely additively against one `main` and silently dropped a
  line against another that happened to carry a stray double blank. Since
  `CHANGELOG.md` is a file every PR touches, that is a standing source of
  surprise diffs and merge-queue ejections. It refuses to write at all on an
  unrecognised filename, an empty fragment, a body carrying its own heading,
  or an entry it cannot read as a fragment (a subdirectory, a dangling
  symlink). The rewrite is staged beside `CHANGELOG.md` and renamed into
  place, and fragments are deleted only after that succeeds, so a failed run
  never loses an entry from both places at once. Fragment metadata travels
  out of band, so body text is never parsed as assembler control data — a
  fragment cannot forge the `BREAKING` marker the downstream update gate
  reads. **Additive and non-breaking on its own:**
  `workflows/scripts/check-changelog-entry.sh` is unchanged and a direct
  `## [Unreleased]` entry still satisfies it — nothing yet *requires* a
  fragment. Cutting the gate over to fragments (a BREAKING change for
  vendoring overlays, which must create their own `changelog.d/`) is #1322.

- **`pipeline-retro-health.sh` resolves its lake roots logically and pins the
  PIPELINE stream to the writer's own default** (#1185). Two independent
  defects made the probe report `no-lake` from the checkout the pipeline
  actually runs in. First, `$here`/`raw_root` were resolved with `cd -P`
  (physical), which walks THROUGH a vendored checkout's `workflows/scripts/
  build -> kernel/workflows/scripts/build` directory symlink and lands three
  levels up inside `kernel/` — verified live:
  `cd -P .../foundation.cron/workflows/scripts/build && cd -P ../../..`
  yields `.../foundation.cron/kernel`, whose `meta/data/raw` holds only a
  stub README — instead of the checkout that owns the real lake. Both roots
  now resolve with a logical `cd`/`pwd` (no `-P`), which collapses `..`
  textually against `$PWD` rather than following symlinks. Second, the
  PIPELINE stream's default stopped being re-derived from that
  checkout-relative root at all: `pipeline-cron.sh:299` pins its own
  `PIPELINE_RAW_DIR` default to the intentionally **absolute**,
  checkout-independent `$HOME/dev/foundation/meta/data/raw` (foundation#725's
  "canonical absolute sink" — the cron sandbox checkout must still write into
  the main checkout's lake), so a script-relative guess here would read a
  *different* lake than the one the writer filled whenever the probe runs
  from that sandbox. `pipeline-retro-health.sh` now duplicates that literal
  verbatim (setting-registry.tsv's existing `PIPELINE_RAW_DIR` row already
  covers it — a byte-identical, non-vendoring-checkout-fallback duplicate,
  same convention as `PIPELINE_OPERATOR`'s duplicate in `pipeline-drive.sh`),
  falling through to it only when neither `PIPELINE_RAW_DIR` nor an
  operator-set `TELEMETRY_RAW_DIR` override is present — both overrides still
  win exactly as before. The RETRO-RUNS stream deliberately stays
  checkout-relative (unpinned from the writer's absolute root): its writer,
  the overlay `/retro` judge, sets no override and inherits whichever
  checkout invoked it, so converging the two streams onto one root would make
  the probe miss rows the judge wrote under a different checkout.
  `workflows/scripts/config/setting-registry.tsv` needed no new row — the
  duplicate literal is already registered under `pipeline-cron.sh` and the
  registry's name-only unregistered-setting sweep passes unchanged. Not
  breaking — read-only, still fails open (`no-lake`/`unknown`, exit 0) when
  the resolved lake genuinely holds no month-files.
- **`build-level.mjs` now emits a `phase()` per STAGE of a level instead of one
  static heading for the whole run** (#1294). The level's progress heading
  advances `claim → build → gate → PR → CI` as items move, so a collapsed
  `/workflows` view that renders the ACTIVE phase tracks the run rather than
  freezing on one line, and the expanded tree groups agents by stage instead of
  dumping every executor into one `machinery` box. Every stage title still
  carries temperloop#903's run context — `build level · gate — owner/repo · 3
  items · slug (#N), … +K more` — bounded by the existing
  `PHASE_TITLE_MAX_ITEMS`; `levelPhaseTitle()` was extended with an optional
  `stage` argument rather than forked into a second title format. Each agent is
  assigned to its stage's group through the documented `opts.phase` argument
  (the global `phase()` cursor races inside `parallel()`), and the cursor itself
  advances monotonically, so an off-path recovery probe gets its own group
  without dragging the collapsed row backwards. `meta` stays a pure literal and
  deliberately declares no `phases:` key — entries there are matched against
  phase titles exactly, and every title here is dynamic by #903's requirement.
  No change to claim/worktree/gate/PR/CI mechanics; this is a progress-surface
  change only. This is the kernel-side half of #1294 — the collapsed row still
  renders from `meta.description` until the Claude Code Workflow progress UI
  draws from the active phase, which this repo does not control.
- **`gate.sh diagnose-queue` now persists every verdict to its own telemetry
  stream** (#1192). The subcommand decides whether a merge queue is stalled,
  dequeued, or hit a GitHub Actions infra failure — and until now wrote that
  verdict **nowhere a consumer could read**, so the per-run stall tally the
  overlay wants could not be built at all. Verdicts are emitted by a new
  `workflows/scripts/emit-diagnose-queue.sh`, a **sibling** of the existing
  `emit-*.sh` scripts rather than code inlined into `gate.sh`: telemetry is
  contractually *warn, don't drop*, while `gate.sh` is a closed outcome set
  that fails loud via `die()` and whose exit codes `/build` and `/fix` branch
  merge decisions on — so an emit bug must never be able to reach that
  contract. The emit fires from inside `cmd_diagnose_queue`, so it covers the
  internal call on `cmd_poll`'s TIMEOUT path as well as a direct invocation,
  and it records on **both** attended and unattended runs (the two rejected
  alternatives each covered only one arm). Coverage is the full current
  verdict set, including `QUEUE_STALLED` and `MERGE_GROUP_INFRA`, which landed
  earlier in this same release. A dedicated `validate-diagnose-queue-emit.sh`
  joins the three existing per-stream validators, since these verdicts feed
  merge decisions. **Contract surface:** `scripts/quality-gates.sh` gains the
  validator gate. Not breaking — the emit is purely additive and cannot alter
  `diagnose-queue`'s exit-code contract. The consumer half (the tally itself)
  is overlay-owned and stays open at foundation#1281.

- **`report` now renders a directional dollar line from a kernel-shipped,
  dated default price table when the target repo carries no
  `.temperloop/pricing.json`, replacing the previous "add
  `.temperloop/pricing.json`" nudge for that case (#1251).** The new table
  lives at `workflows/scripts/config/default-pricing.json` — a tracked,
  hand-dated `{as_of, prices}` snapshot, never a live pricing-API read and
  never recalculated at runtime, refreshed only by hand-editing the file in
  an upstream PR (same discipline as the existing user-supplied table and as
  `bin/lib/cost-estimates.conf`). Every dollar line the default table drives
  carries its own `as_of` date and an explicit, unmissable staleness label
  alongside the existing DIRECTIONAL marker, so nobody mistakes the figure
  for a real invoice or for their own configured prices. A user-supplied
  `.temperloop/pricing.json`, when present, is used **exclusively** — it
  overrides the default table outright rather than supplementing it, exactly
  as before; the malformed-pricing-file and no-model-matched degradation
  paths are unchanged. A missing/malformed default table (a broken kernel
  checkout) degrades to the old nudge line rather than crashing.
  **Classified ADDITIVE (minor), not BREAKING — grounded in VERSIONING.md's
  contract-surface table, not merely asserted.** Two of that table's rows
  are in play. **CLI surface** (`bin/subcommands/*`) is what an adopter
  actually calls, and none of it moves: exit code 0, every flag, every
  section heading, and the user-`.temperloop/pricing.json` override path
  (including its **per-key**, never-blended override behavior) are all
  unchanged — pinned by `bin/subcommands/tests/test_report.sh`'s
  6c-iii-b/6c-iii-b2 fixtures. An adopter who already wrote a pricing table
  sees byte-identical behavior; one who never wrote one merely starts
  seeing a new, clearly-labeled directional dollar line where a nudge used
  to render — an addition, not a removal or a reshaping of anything a
  caller depends on. **Published schemas/contracts** (`*.contract.md`) is
  the row that *does* move: `workflows/scripts/lib/report.contract.md`'s
  "Pricing table & dollar framing" section is updated in this same change
  to document the new default-table tier, its override order, and its
  degradation paths — a documentation update describing new capability, not
  a behavior change a caller must adapt to, so it stays additive rather
  than tipping this release into BREAKING. No `BREAKING` marker, no
  migration note owed.

- **The generated `/build` worker prompt now carries a structural
  no-context-inheriting-research-fork guardrail** (#1072). Both execution
  paths — `workerPrompt()` in `claude/workflows/build-level.mjs` (a new
  `## No context-inheriting research forks` section) and
  `claude/commands/build.md`'s conversational-path worker-prompt
  instructions — ban spawning a context-inheriting `fork` for a narrow
  read-only sub-task (it inherits the parent's drive-to-done-and-commit
  mission and may fabricate a completion report or commit to the shared
  worktree, as observed in temperloop#635), while sanctioning a fresh
  explicitly-scoped read-only subagent or a fork whose prompt explicitly
  overrides the inherited mission — and cross-references build.md's
  existing "Seat scoping — nested review delegation" clause by name so the
  two are not misread as conflicting. Previously this guardrail lived only
  in a vault note a session had to remember to re-paste.

- **`init`'s fresh-install board-1 default is now documented as intended
  standalone-kernel numbering, not fleet-collision drift** (foundation#1339).
  `docs/features/install-cli.md` § "Board number" states plainly that a
  repo with no prior `.temperloop/config` and no `--board` flag mints board
  1, names the two existing escapes (`--board <n>`, or a carried-forward
  `tracker.board` from a prior config), and records why detecting a fleet
  operator's own numbering was rejected — that convention is overlay
  knowledge about one operator's repos, and baking it into the kernel
  installer would violate the stranger test. `bin/subcommands/init.sh`'s
  `board_num=1` fallback now carries a one-line pointer to that section.
  Documentation only; no behavior change.

- **The on-ramp surfaces now run on `temperloop testbed`, and § 3 ends on
  `/promote` rather than on deleting the evaluation repo** (#1238).
  `README.md` § 3's hand-run block — `gh repo create`, a bare clone, `git
  push --mirror`, and a `gh issue list | jq | gh issue create` loop — is
  replaced by the single `temperloop testbed` command (#1117) plus the real
  handoff block it prints, and the section's exit changes from `gh repo
  delete` to **`/promote` first, `temperloop testbed --teardown` second**:
  the work a reader's evaluation produced comes home as a reviewable pull
  request in their real repo before the duplicate is reclaimed, closing the
  "a convinced reader had to throw everything away" gap this epic exists to
  fix. The **adoption-sense** noun is renamed throughout — `sandbox` ->
  `testbed`, including the § 3 heading and the `my-project-sandbox` repo
  name — across `README.md`, `bin/README.md`, `AGENTS.md`, `docs/pitch.md`,
  `docs/features/install-cli.md` and `docs/cost-and-autonomy.md`; every
  **harness-sense** use (the hermetic HOME/XDG test tree in
  `workflows/scripts/tests/**`, the `sandbox-core`/`sandbox-integrity`
  feature slugs and their docs) is deliberately untouched, since that word
  legitimately names a different thing there. `llms.txt`'s stale `try` ->
  `try --demo` -> `init` quickstart line is corrected to the real path.
  Documentation only; no behavior change.

- **The four command-spec sub-issue *reads* now route through the board
  adapter's `board_sub_issues` instead of a raw `gh api .../sub_issues`
  call** (#1140): `assess.md`'s candidate-item enumeration, `build.md`'s
  epic-close open-children count, `next.md`'s epic-state rollup, and
  `fix.md`'s epic-size refusal gate. Each site sources `lib/board.sh` plus a
  guarded `lib/cache.sh` in the same Bash call it reads from (shell state
  does not persist across calls) and, at the two gate-bearing sites
  (`build.md`'s epic-close count, `fix.md`'s refusal gate), carries an
  inline note that the read must stay LIVE — `board_sub_issues` has no
  cached arm today (removed in #1163), and a future cached arm pointed at
  either gate without re-litigating that is the #1030 failure mode (a
  cached read silently reporting 0 children armed a wrongful epic-close).
  This is the prose half of the routing #1119/PR #1139 already applied on
  the script side (`build/board-mirror.sh`), which also added the
  `[all|open|closed]` state filter `build.md`'s open-count now uses. No
  write site is touched.

- **`/sweep`'s shared-hotspot rule now records that `CHANGELOG.md` is no longer
  a universal hotspot, and why** (#1218). The rule tells the Phase-2 chunker to
  sequence singletons that touch the same file into *different* chunks. It could
  not do that for `CHANGELOG.md`, because every contract-surface kernel item
  touched it — so a multi-item kernel chunk collided by construction rather than
  by coincidence.

  That premise is now false. Under `changelog.d/` fragments (#1321) and the gate
  cutover that requires one (#1322), a contract-surface PR writes its own new
  file instead of editing `CHANGELOG.md`, so two `/sweep`-driven singletons in
  one chunk share no changelog line and cannot collide on one.

  The deliverable is therefore a **subtraction**: no CHANGELOG-specific chunker
  rule was added, and the general shared-hotspot heuristic is unchanged — it is
  still correct for composition roots and other genuinely shared files. What the
  spec gains is one paragraph marking the CHANGELOG case as *resolved at the
  source*, so a future reader sees a closed concern rather than a missing one and
  does not re-file it.

- **The model-usage attribution stream (#1253, epic #1225 "model comparison
  harness") is now actually wired into every emit-feasible spawn seat**
  (#1255). The L0 usage-capture-feasibility spike named three seats that can
  emit a token-bearing record today — `pipeline-drive.sh`'s level-5b safe
  driver (A7) and level-5c merge driver (A8), and
  `pipeline-retro-judge-spawn.sh`'s retro judge (A9) — and all three now
  call `emit-model-usage.sh` after every spawn, via a new shared extraction
  helper (`workflows/scripts/lib/model-usage-envelope.sh`) that turns the
  captured `claude -p --output-format json` envelope into one attribution
  record: resolved model, provider, token counts, duration, and an
  `issue:<n>` or board-scoped `issue:board-<n>` outcome ref for a batch
  spawn covering several issues at once. `validate-model-usage-emit.sh`
  gains a spawn-site coverage check (`--scan-dir` test seam): it fails CI if
  a wired seat's emit call is removed, or if a NEW spawn site captures the
  same `--output-format json` envelope shape without wiring emission — so
  future spawn sites owe an emission mechanically, not by convention. Every
  structurally un-emittable seat (the `.mjs` `agent()` class, harness-native
  `Task`/agent-frontmatter fan-out, interactive command sessions, and the
  `try.sh`/`configure.sh` text-output seats tracked by #1264) is named in
  the validator's own exclusion list with the spike's reason, rather than
  silently absent from the denominator.

- **The changelog completeness gate now requires a `changelog.d/` fragment
  rather than a line under `## [Unreleased]`** (#1322).
  `workflows/scripts/check-changelog-entry.sh` fails a PR that changes contract
  surface without adding a conforming
  `changelog.d/<slug>.<category>[.breaking].md` present at HEAD; a direct
  `## [Unreleased]` line no longer satisfies it. That is what removes the merge
  collision at its source rather than routing around it — a mandatory entry in
  one file at one anchor meant 25 of the last 25 commits touched `CHANGELOG.md`
  and any two concurrent PRs conflicted by construction, while two PRs writing
  two distinct new files share no line and cannot conflict.

  Unchanged: the escape-hatch grammar (`Changelog: none|amend — <reason>`, via
  a PR label, a PR-body line or a commit trailer, reason still required), and
  the released-section-scope property with its merge-base discriminator —
  though the latter's reason to exist now narrows to the release-cut PR, the
  only PR that still edits `CHANGELOG.md` at all.

  `VERSIONING.md` § Cutting a release is rewritten to the assembler-based flow.
  Its old merge-walking `^CHANGELOG.md$` backfill loop is replaced by
  `scripts/assemble-changelog.sh --assert-empty <rev>`, a deterministic
  assertion that no unassembled fragment survives at the tagged commit. That is
  both cheaper than the loop and catches what the loop never could: the
  cut-vs-sibling **omission** race, where a cut PR deleting fragments and a
  sibling PR adding one touch disjoint files, so git merges them clean and the
  sibling's entry goes missing — not wrong — from the shipped section.

  **Migration.** A vendoring overlay must create the directory at its **own**
  repo root, not `kernel/changelog.d/`: `mkdir -p changelog.d && touch
  changelog.d/.gitkeep && git add changelog.d/.gitkeep`, then author one
  fragment per contract-surface PR. Until it does, the gate degrades legibly
  rather than breaking the build: a tree carrying `.kernel-pin` gets an
  actionable skip of the completeness property — naming its pinned kernel tag
  and that exact command — while the section-scope property keeps running. A
  tree with **neither** `changelog.d/` nor `.kernel-pin` is not a vendoring
  consumer but a kernel checkout that lost the directory, and there the gate
  fails loudly: a bare skip would let the kernel silently disable its own gate,
  which is worse than having no gate.

  The **same `.kernel-pin` discriminator now governs the `CHANGELOG.md` probe**,
  which runs first. A tree with no `CHANGELOG.md` and no `.kernel-pin` fails
  loudly instead of skipping; one carrying the pin still gets the legible skip.
  Previously that probe exited 0 unconditionally, which made the fail-loud arm
  above unreachable whenever a checkout had lost `CHANGELOG.md` as well —
  probe order was the only thing holding the invariant up. An overlay that
  genuinely keeps no changelog needs `.kernel-pin` present at its own repo
  root, exactly as the `changelog.d/` degradation already required.

- **`docs/cost-and-autonomy.md` and `temperloop init`'s handoff now disclose
  the first-epic cost position instead of leaving it as "no fixed figure /
  none by default"** (#1130). The temperloop#1348 spike found no source in
  this repo's own telemetry supports a published spend band for the first
  epic (every candidate was either too thin or measured the wrong
  population — an operator's own established checkout, never a fresh
  testbed); § Cost at a glance now states that finding directly and routes
  the actual measurement to temperloop#1352, rather than publishing a
  fabricated number. It also states plainly, and explains why, there is no
  *tool-enforced* dollar ceiling on `/assess`/`/build`: `--max-budget-usd`
  only caps a **headless** `claude -p` call, and those commands instead run
  in your own **interactive** `claude` session. `temperloop testbed` and
  `temperloop init` are now priced at their verified **$0** (no `claude`
  invocation in either path) instead of being left unpriced next to the
  un-figured first-epic row, and the first epic is described accurately as a
  fixed, kernel-shipped 5-item/3-level epic rather than "scales w/ the
  work". `temperloop init`'s closing handoff block gains a new `cost:` line
  — distinct from the stable `next step:` marker `install-tier2.yml` greps —
  naming this cost position before handing the reader to `/assess`.

### Added

- **`board`: `board_close_done <board#> <issue#>` — a Done write that
  survives an already-closed issue** (temperloop#1217). One call lands a
  board item Done from ANY state — open, already closed (the case a
  whole-board `board_item_id`/`board_set_status` composition silently
  no-ops on, since that list is `--state open` only), or already Done
  (no-op, exit 0) — and needs no prior `board_resolve_item`/`BOARD_ITEMS_JSON`
  carried over from an earlier call, since shell state does not persist
  between separate Bash tool calls. It saves and restores `BOARD_CURRENT`,
  leaving no adapter global modified. A thin, guarded composition over the
  existing `board_set_status … Done` write path (`ISSUES-ONLY-BACKEND.md`
  § Close→Done cascade already documents that path as the primary
  mechanism on this backend) — no new write logic.

- **`/promote`'s issue correspondence is now resolved by a real script,
  never a prose lookup** (#1235). `workflows/scripts/promote/resolve-correspondence.sh`
  resolves a copied testbed issue back to its original by **exact lookup**
  on the `copied from <owner>/<repo>#<N>` line `mirror-from-repo` stamps at
  copy time — never by title matching, ordering, or any other inference —
  and refuses rather than guesses, with a distinct outcome for each of
  three bad states: the line is absent, malformed, or the body was edited
  after copying (no longer the fixed trailing shape the writer produces).
  Its `report` mode gives `/promote` one row per testbed issue to use
  verbatim. The mechanical half exists as a script rather than a markdown
  step because an LLM-executed prose lookup gets paraphrased away, and the
  failure mode of a paraphrased lookup is a silently absent or silently
  wrong record, not a caught error.
- **`/promote`'s API-state story is now diff, record, and handoff — never
  apply** (#1236). Branch protection, required checks, labels, and board
  configuration are GitHub API state, not tree state, so they cannot ride a
  pull request; `workflows/scripts/promote/api-state-diff.sh` shows a
  read-only current-versus-proposed settings diff before the operator is
  asked to run the adopt path (`temperloop init`) themselves, then — once
  that separately-consented step has run — leaves a durable, team-visible
  record as a comment or issue in the real repository, naming the source
  testbed as a temperloop evaluation. Its report is structurally three parts
  (migrated / re-applied / left-to-you), each required, with a uniform
  "migration complete"-shaped claim refused in any of the three rather than
  left to prose discipline — re-applying the state itself stays the adopt
  path's job, never this script's, so ADR 0023's biconditional (docs/adr/0023)
  holds.

- **A committed provider allowlist and a paired disclosure log gate what may
  be sent to a third-party vendor** (#1250, epic #1225, ADR 0028 decisions 1
  and 2). `workflows/scripts/model-comparison/provider-allowlist.txt` is the
  ceiling — git-tracked, repo-scoped, Anthropic-only by default, and changed
  only through a reviewed commit: never an env var, never a `$HOME` config,
  never anything under the gitignored `.temperloop/` runtime dir. A personal
  `.temperloop/model-comparison/allowlist.local.txt` may NARROW that set for
  one checkout and can never widen it; a widen attempt fails closed (nothing
  is allowed) rather than being silently dropped. Every send to a non-default
  provider writes exactly one append-only, hash-chained JSONL entry carrying
  provider, item reference and timestamp — never content — through
  `allowlist.sh`'s `pa_disclose`, the only writer the library exposes, which
  refuses to log a provider the allowlist does not currently allow and
  serializes concurrent writers behind a lock so a provider fan-out cannot
  interleave two appends into a broken chain. A new `checks` gate,
  `workflows/scripts/validate-provider-disclosure.sh` (plus its fixture suite
  `workflows/scripts/model-comparison/tests/test_allowlist.sh`), enforces all
  of it on every PR, and four new settings — `PROVIDER_ALLOWLIST_TEST_SEAM`,
  `PROVIDER_ALLOWLIST_COMMITTED_FILE`, `PROVIDER_ALLOWLIST_LOCAL_FILE`,
  `PROVIDER_DISCLOSURE_LOG_FILE` — are registered in `setting-registry.tsv`;
  the three path seams are honoured only alongside
  `PROVIDER_ALLOWLIST_TEST_SEAM=1`, so the ceiling cannot be repointed from
  the environment. **What the chain proves, stated precisely:** it makes an
  entry rewritten in place, or deleted from the interior of an intact file,
  mechanically detectable. It does not, on its own, detect truncation of the
  log's tail, deletion of the whole log, or a full re-forge — an unanchored
  chain records nothing about its own length, and an unkeyed one can be
  rebuilt end to end by anyone who can write it. A sibling
  `disclosure-log.watermark` anchor closes the first two and makes the third
  loud, but the anchor is itself an untracked local file: it raises the cost
  of casual tampering and does not defeat an attacker who can write both
  files. Anchoring it beyond local write reach is tracked separately. The
  send-vs-log coverage cross-check (proving every actual send produced an
  entry) is owned by a later item in the same epic.

- **A comparison-statistics library, so a model comparison reports what the
  numbers can actually support** (#1249, epic #1225 "model comparison
  harness"). `workflows/scripts/model-comparison/stats.sh` (a thin CLI over
  the `stats.py` numeric core, python3 stdlib only — no network call, no model
  call, every subcommand a pure function of the numbers it is given) answers
  the four questions a cost comparison has to answer honestly. `bootstrap-ci`
  puts a percentile bootstrap confidence interval around a cost-per-merged-
  outcome delta array. `verdict` adds the winner call and, above all, the
  **inconclusive floor**: below `MODEL_COMPARISON_MIN_SAMPLE_N` outcomes the
  answer is always `inconclusive` with no winner-shaped field populated, so a
  CI that happens to exclude zero on four data points can never be read as a
  result — and `bootstrap-ci` enforces the same floor, because the guarantee
  has to be a property of the module rather than of the one subcommand that
  spells the word "verdict". `mde` reports two deliberately distinct effect
  sizes, since conflating them is how a comparison gets under-powered: the CI
  half-width as `margin_of_error`, and the genuine minimum detectable effect
  as `mde` — `(z + z_power) · σ/√n` at a `--power` that defaults to the
  conventional 0.80, roughly 43% larger than the half-width. Sizing N against
  the half-width instead is how a team spends the whole budget and lands on
  `inconclusive`. `coverage` reports emit-coverage against the structural
  denominator the L0 usage-capture spike (#1246) defined — the emit-FEASIBLE
  seat subset, never the full seat inventory — and refuses an observed count
  above that denominator, because passing the inventory as the numerator is
  the most likely form of exactly the confusion the subcommand exists to
  prevent.

  Five operator tunables are registered in `setting-registry.tsv` with their
  defaults in `build.config.sh`, which `stats.sh` sources rather than
  duplicating: `MODEL_COMPARISON_MIN_SAMPLE_N`,
  `MODEL_COMPARISON_BOOTSTRAP_ITERATIONS`, `MODEL_COMPARISON_BOOTSTRAP_SEED`,
  `MODEL_COMPARISON_CI_WIDTH_PCT` and `MODEL_COMPARISON_EMIT_FEASIBLE_SEATS`.

  Two properties are load-bearing enough to name. **Input is finite or it is
  rejected**: `json.loads` accepts bare `NaN`/`Infinity` and overflows `1e400`
  to infinity, and `json.dumps` re-emits those as tokens RFC 8259 does not
  permit — which `jq` silently coerces to `null`, where `null < 0` makes a
  corrupted record read to a downstream `select(.upper < 0)` as "the candidate
  is significantly cheaper". Non-finite input therefore exits 2 with empty
  stdout. **Results reproduce across CPython versions**: resampling draws
  indices from `Random.random()` (the only method CPython documents as
  sequence-stable) and accumulates with `math.fsum` (builtin `sum()` changed
  strategy in 3.12, gh-100425, and does not agree across versions), and
  `stats.sh` enforces a python3 >= 3.8 floor rather than assuming it. The
  fixture suite (`make test-model-comparison-stats`, wired into the kernel
  gate set) was run green on CPython 3.9.6 and 3.14.6 with byte-identical
  output, and its five settings assertions were verified by mutation —
  deleting each setting's forwarding in turn fails the suite.

- **`/promote` carries work back out of a testbed and into your real
  repository, as your pipeline's actual commits** (#1233). Building the
  evaluation in a disposable duplicate is only half the story; the other half
  is getting the good parts out without hand-copying files. `/promote` is the
  judgment half (which work is worth promoting, and the honest three-way
  report — commits carried, issue correspondence resolved by lookup, API state
  explicitly not migrated), and `workflows/scripts/promote/push-testbed-branch.sh`
  is the mechanical half: it adds the testbed as a remote in a throwaway
  workspace, fetches, and pushes a branch carrying the testbed's real commits
  and authorship — deliberately not the proposal-PR generator, which rebuilds a
  branch off the base tip and would squash that away. Its own suite asserts the
  guarantee that matters: exactly one push, always to `refs/heads/<branch>`,
  never the target's default branch. Pre-flight checks the branch-create
  precondition (with the fork fallback named in the refusal) instead of
  discovering it at failure time, and refuses a `materialize-from-seed` testbed
  by reading `source_kind` from the artifact record — a seed testbed has no
  original to promote to. Every pull request it opens carries a one-line
  provenance note so a reviewer with no context can tell where the change came
  from.
- **`reported_no_op` — a fourth disposition count on the `command-run`
  telemetry stream, closing a `/fix` no-op run's guaranteed reconcile failure
  (#1103).** `workflows/scripts/emit-command-run.sh` could express `merged`,
  `resolved (verdict)`, and `parked`, but `/fix`'s two reported-no-op routes —
  `already-done` (4e) and `claimed-elsewhere` (4d) — had no disposition to
  claim: emitting `items_processed:1` with all three at `0` would trip the
  emitter's own accounting assertion (temperloop#1084), so `claude/commands/fix.md`
  Step 6 instead skipped the emit entirely on both routes, leaving a real
  `/fix 1100` `already-done` run with **no telemetry record at all** — the
  exact absent-signal failure this stream exists to prevent. New
  `--reported-no-op <N>` → a `reported_no_op` field, and the emitter now
  asserts **`merged + resolved + parked + reported_no_op == items_processed`**
  (still exiting **2** with the arithmetic named on a mismatch, after
  appending the record — never a dropped record). A caller that omits the
  flag (sweep/triage, and any pre-#1103 `/fix` call site) still gets an
  explicit `0` and still reconciles. `fix.md` 4d/4e now call the emit
  directly — the two routes that previously "went straight to the report" —
  and Step 6 §4's prose no longer denies a fourth field is needed.
  `workflows/scripts/validate-command-run-emit.sh` gains the analogous
  content-derived check for the `reported-no-op` disposition (mirroring its
  existing `resolved (verdict)` check), so a future doc that grows this
  disposition without wiring the flag is caught without editing the linter.
  Purely additive (no `schema_version` bump); ⚠ absent on a pre-#1103 record
  means UNKNOWN, never `0`, same convention as `resolved`. New tests in
  `workflows/scripts/tests/test_command_run_emit.sh`.

- **`temperloop testbed` builds a private, disposable evaluation copy of a
  repo in one command, then hands off to `temperloop init` inside it**
  (#1229). The repo worth evaluating temperloop on is the one you care about
  — which is exactly the repo you do not want an unfamiliar tool creating
  branches and pull requests in. This builds a throwaway instead (create the
  repository, mirror-push the history, carry the open issues across) and ends
  in an unmissable final block carrying the testbed URL in full plus the
  literal `git clone` / `cd` / `temperloop init` commands. It registers by
  file presence and its `# description:` line alone — no dispatch-table edit
  — and is the first consumer of both Level 0 seams (the machine-scoped
  artifact record and the four-function source provider): the driver is fixed
  and contains no `case` on provider kind, so the second provider will land
  without touching it. Pre-flight unions the driver's own all-reads checks
  with the provider's and refuses with a `cannot proceed —` / `skipped —`
  line naming the fix, having written nothing anywhere; consent refuses
  outright on a non-tty stdin with no `--yes` — the guard `try --demo`
  established, carried to a command that now creates real remote repositories
  — and `--dry-run` is proven zero-write structurally, by a fake `gh` and
  `git` on PATH logging every call plus a before/after file-tree diff. Each
  artifact is flushed to the record the instant its step completes, so a run
  killed partway stays enumerable by teardown instead of becoming an orphaned
  private repository.
- **The build write-jail guard now binds a worktree to the AGENT writing in
  it, and refuses an uncoordinated second writer** (#1187). Containment
  answered "does this write stay inside the worktree?" but never "is THIS
  agent the one supposed to be writing here?" — a sibling `/build` worker that
  `cd`s into a peer's worktree passed every existing check. The guard now
  records the `agent_id` of the FIRST qualifying in-tree write as that
  worktree's owner (binding at first write, not at worktree creation — the
  `.build-guard` marker is dropped at build step 3b, before any worker exists,
  and deliberately stays `{slug, branch, created}`) and denies a write from an
  agent that already owns a *different* armed worktree. An **absent**
  `agent_id` is a third, always-allowed state, never folded into "non-owning":
  the orchestrator's own post-spawn push/rebase/prune run main-thread and
  carry none, and rejecting them would deadlock every level's merge path. A
  nested read-only review subagent (the sanctioned nested-delegation pattern)
  is untouched, because only writes bind. The `agent_id` discriminator was
  confirmed live against real PreToolUse payloads before being built on.

- **A machine-scoped testbed artifact record tracks every artifact a
  `temperloop testbed` run creates** (#1227). The record is an append-only
  list resident in XDG state
  (`${XDG_STATE_HOME:-$HOME/.local/state}/temperloop/...`, not `.temperloop/`,
  so it survives `eject`), keyed by `owner/name` so a consumer resolves its
  own entry from `git remote get-url origin` with no filesystem scan. It owns
  the full schema up front — the artifact list (repo created, mirror pushed,
  issues copied) plus the source-provenance fields `source_kind`,
  `source_repo`, and `promotable` that promote-spec-and-tree-push reads two
  levels later — and carries a `schema_version`, refusing on an unknown
  version, following `workflows/scripts/install/manifest.sh`. Ships
  library-only with its own tests and no CLI caller yet, exactly as
  `manifest.sh` did when it landed.

- **A source-provider seam sits upstream of `temperloop testbed` pre-flight,
  plus its first implementation `mirror-from-repo`** (#1228). The seam is
  four functions, not one tuple — `describe()` (kind, base name, provenance
  capability, promotability), `preflight_checks()` (the provider's own
  all-reads checks), `produce_git(dest)`, and `produce_issues(dest)` — so the
  command never branches on provider kind to decide which checks to run, and
  `describe()` resolves with zero network writes so pre-flight still runs
  before anything is produced. `mirror-from-repo` stamps a machine-readable
  `copied from <owner>/<repo>#<N>` line into every issue it creates, inside
  its own `produce_issues` rather than in shared downstream code. Ships
  library-only with its own tests.

- **`/check-in` now reads and disposes the environment-hygiene surface**
  (#596). `/tidy`'s § Environment hygiene step already ran `env-reconcile.sh`
  and appended each drift finding to the environment hygiene report, and
  `CLAUDE.kernel.md` § Environment hygiene already promised that drift was
  appended "for `/check-in` to review and dispose" — but `check-in.md` carried
  no section that read the surface, so the propose half of the loop had no
  disposer and every finding sat unread. The motivating incident: a
  telemetry-regeneration LaunchAgent sat **unloaded for four days**;
  `env-reconcile.sh` detected it correctly and `/tidy` recorded it, and it
  still never reached the operator. Part 2 gains an
  `### Environment hygiene review` section, mirroring the existing
  `### Vault hygiene review`: for each `open` entry it presents the
  launchd/checkout/worktree drift, lets the operator act or dismiss, and
  patches the entry's `Status`. It **never** mechanically reloads an agent or
  resets a foreign checkout — per § Environment hygiene's aggressive-in-lane /
  report-cross-lane split, disposition of a foreign checkout stays the
  operator's call.

- **A second testbed source provider, `materialize-from-seed`, plus the in-tree
  seed it materializes** (#1230). It implements the same four seam functions as
  `mirror-from-repo` — no new dispatch, no `case` on provider kind, no second
  path downstream, so teardown reclaims a seed testbed by exactly the route it
  reclaims any other. `describe()` reports `provenance_capable: false` and
  `promotable: false`: there is no upstream issue to cite and no original to
  promote back to, and `produce_issues` correspondingly stamps no provenance
  line. Per ADR 0025 the seed is content **tracked in this repository** —
  `workflows/scripts/demo/seed/`, a fixture project plus one Markdown file per
  issue — built into a fresh repository locally and pushed into the operator's
  **own** account; no repository owned by this project exists at any point. The
  fixture replaces the retired `demo-seed` one-file synthetic defects with a
  small, coherent Markdown link checker: six issues that group into a real
  first epic for `/triage` and `/build`, a suite that ships green, and its own
  gate (`make test-demo`) asserting every defect the issues claim is still
  present and the seed still passes.

- **`temperloop testbed --teardown` deletes a testbed created by a prior run**
  (#1231). Teardown is a MODE on the existing command, not a second
  subcommand — it branches early and never touches the create-path driver's
  fixed step order or its four seam calls. The target resolves from
  `--repo OWNER/NAME`, or from `--dir`'s (default: cwd) `origin` remote read
  with `git -C` (never a `cd`), so it works from any cwd — inside the
  testbed's own clone, not only the checkout that created it — by keying
  straight into the machine-scoped artifact record (`record.sh`) rather than
  any tree-relative path. Every recorded entry has `repo_created=true` by
  construction, so a single `gh repo delete` removes whatever the record
  enumerates, complete or partial. `gh auth login`'s default scope set omits
  `delete_repo`; teardown checks for it first via a new reusable helper
  (`workflows/scripts/testbed/scope.sh`) and, when absent, degrades legibly —
  prints the one-line `gh auth refresh -s delete_repo` remedy and exits 0 —
  rather than failing on a `gh repo delete` call it can never make.
- **A provider-equivalence guard makes the epic's central structural claim
  mechanical: both testbed source providers drive one identical call
  sequence downstream of the seam** (#1232). Two test doubles — never the
  real `mirror-from-repo`/`materialize-from-seed` (their content differences
  are `test-testbed-source`'s job) — are driven through
  `bin/subcommands/testbed.sh`'s own driver, and the test asserts an
  identical seam-call sequence plus an identical driver
  step/pre-flight/flush/handoff trace between them, modulo the
  source-identity fields (kind, `provenance_capable`, `promotable`) that
  legitimately differ — excluded from the comparison by name, with a sanity
  check proving the exclusion is real rather than accidental. Asserting over
  the driver's own sequence, not either provider's internals, is what makes
  a provider-agnostic-orchestration bug fail here instead of surfacing as a
  seed-provider failure; this is the guard that stops the prepared-source
  option from drifting into a second path — precisely how `try --demo`
  became a dead end. States plainly, in its own header and in
  `docs/features/testbed.md`, what it does **not** prove: identical
  evaluation value — the two sources differ in content, promotability, and
  privacy exposure by design, and no test speaks to that. Zero network, its
  own `make test-testbed-equivalence` gate.

- **A positive on-ramp anchor-registry gate replaces the tree-wide-sweep
  instinct for cross-surface on-ramp coherence** (#1239, ADR 0024). The
  command a newcomer should run first is named in four unrelated places —
  `bin/temperloop`'s first-run banner, `README.md`'s quickstart,
  `bin/README.md`, `docs/features/install-cli.md` — that drifted silently
  once already (temperloop#1116). Rather than grep the tree for a retired
  name (a gate that ships with an exemption list on day one, since
  `CHANGELOG.md`/`docs/adr/**`/`Plans-archive/**` name the retired command
  legitimately, as history),
  `workflows/scripts/config/onramp-anchors.tsv` registers the four anchors
  and `workflows/scripts/validate-onramp-anchors.sh` asserts what each one
  MUST say against a small canonical-value table — installer command, first
  subcommand, and the `testbed` onramp noun itself — normalizing the
  Unicode/ASCII arrow-glyph difference between anchors rather than papering
  over it with a loose substring, and scoping its "no anchor names a
  retired value" check to the registered anchors only, never the tree. A
  new `checks` gate (`make validate-onramp-anchors`, its own
  `gate-paths.tsv` row) plus a fixture suite proving both the real tree's
  current agreement and the gate's red on a deliberately disagreeing
  anchor.

- **The model-comparison replay module gains corpus selection and an
  isolated replay worktree** (#1254, epic #1225 "model comparison harness").
  `workflows/scripts/model-comparison/replay.sh` adds `resolve-base`
  (fork-point base resolution — `git merge-base <merge>^1 <merge>^2`, never
  `<merge>^1` or the moving `baseRefOid`), `diff-scope` (the N/T/X/R
  solution-surface/test/policy-churn/residue partition, rejecting unnamed
  code residue and flagging an md-only residue rather than silently
  accepting or dropping it), `corpus` (real `gh` reads selecting eligible
  closed-issue + merged-PR pairs from a repo's own history, applying every
  contamination-trap disposition from the ground-truth spike and ranking
  eligible PRs by scored footprint — smaller/single-purpose first), and
  `worktree-prepare`/`worktree-teardown`/`verify-clean-parent` (an isolated
  replay worktree built on `workflows/scripts/build/worktree.sh`'s existing,
  unmodified lifecycle: a worktree-scoped push-remote disable so no
  `git push` from inside it can reach a real remote, the same per-worktree
  write-jail guard marker every `/build` worker worktree gets, and a
  deterministic per-repo scratch path — each asserted structurally and
  independently, with `verify-clean-parent` as a documented backstop, never
  the primary control). `schema` prints the versioned scored-record shape
  (`replay-record-v1`) downstream consumers can build against before replay
  execution/scoring lands. Four new registered settings
  (`REPLAY_CORPUS_LIMIT`, `REPLAY_CORPUS_SAMPLE_MULTIPLIER`,
  `REPLAY_NAMED_PATH_EXTENSIONS`, `REPLAY_PUSH_DISABLE_SENTINEL`) and a new
  `scripts/quality-gates.sh` entry
  (`workflows/scripts/model-comparison/tests/test_replay_isolation.sh`).

- **The model-comparison replay module gains a pre-flight spend gate** (#1256,
  epic #1225 "model comparison harness"). `workflows/scripts/model-comparison/
  replay.sh` adds a `preflight` subcommand that reads an already-computed
  `corpus` JSONL file and, before any replay token is spent, prints
  eligible-N, a batch-cap-bounded token/cost estimate (`cost_basis:
  "token_count"` — this module states no dollar figure), and whether that
  eligible-N can reach the module's significance threshold at all — by
  genuinely consuming `stats.sh`'s own `mde` primitive rather than a second,
  hand-rolled computation of it. A projected batch whose estimated cost
  exceeds the new `REPLAY_PREFLIGHT_CEILING_TOKENS`, or that lands while
  `workflows/scripts/build/quota-gate.sh` reports "pause" (the run now
  explicitly routes through that gate), **stops at pre-flight** rather than
  partway through a later execution step. Fails closed
  (`outcome:"CANNOT_EVALUATE"`, non-zero exit) on an absent, unreadable,
  empty, or malformed corpus file, or an unreachable `stats.sh` primitive —
  it never reports a cheap/reachable estimate it did not actually compute.
  Replay batches remain operator-initiated only: no autonomous or cron arm
  was added, proven by a fixture that scans every scheduled pipeline entry
  point for a reference to `replay.sh`. Four new registered settings
  (`REPLAY_PREFLIGHT_BATCH_CAP`, `REPLAY_PREFLIGHT_TOKENS_PER_REPLAY`,
  `REPLAY_PREFLIGHT_CEILING_TOKENS`, `REPLAY_PREFLIGHT_ASSUMED_STDDEV_TOKENS`)
  and a new `scripts/quality-gates.sh` entry
  (`workflows/scripts/model-comparison/tests/test_replay_preflight.sh`).

- **Live candidate tagging gains its provenance layer** (#1257, epic #1225
  "model comparison harness"). New
  `workflows/scripts/model-comparison/tagging.sh` adds no new model-selection
  mechanism — an operator still points the existing `SWEEP_WORKER_MODEL`
  setting at the candidate — and instead provides the provenance half: `tag`
  writes a bounded window record (provider/model/run id, keyed and
  timestamped per run) to a repo-local, gitignored ledger, emits a matching
  attribution-only telemetry tag through the existing
  `workflows/scripts/emit-model-usage.sh` raw lake (`seat sweep-live-tag`,
  `usage_source unavailable` — a `/sweep` fix-worker seat isn't
  token-capture-feasible per the L0 spike), and prints a PR provenance stamp
  naming model and provider only (never a key, never content). `crosscheck`
  mechanically cross-references a PR body/trailer's stamp against the
  recorded window and telemetry-lake records by run id and FAILS on any
  disagreement — a doctored stamp, a stamp with no matching record, or a
  live-tagged run with no stamp are all caught, fail-closed (a distinct
  `CANNOT EVALUATE` on any absent/unreadable/malformed/ambiguous input,
  never a silent pass). Designation is governed by the same committed
  provider allowlist (`workflows/scripts/model-comparison/allowlist.sh`)
  every other provider check in this module reads. One new registered
  setting (`LIVE_TAG_WINDOW_LOG`) and a new `scripts/quality-gates.sh` entry
  (`workflows/scripts/model-comparison/tests/test_live_tagging.sh`).

- **The model-comparison replay module can now RUN a candidate and SCORE it**
  (#1258, epic #1225 "model comparison harness"). `replay.sh execute` drives a
  candidate headlessly inside an already-prepared replay worktree and emits one
  schema-complete `replay-record-v1` record with its `candidate` and `score`
  sub-objects — the diff partition's outcome, the gate result, token counts and
  duration — populated. Those two sub-objects shipped in #1254 as documented
  placeholders for exactly this item; completing them is not a schema v2.

  Scoring lives in the new `workflows/scripts/model-comparison/score.sh` and
  takes its rules from the keystone spike (#1247) rather than re-deriving them:
  the named solution surface is diffed with `--ignore-all-space
  --ignore-blank-lines`, the test surface is scored on presence and pass rather
  than bytes, policy churn is neutral, and the mechanical outcome scorer is
  `scripts/quality-gates.sh` — specifically the copy inside the candidate's own
  base worktree, never today's tree, so a historical item is gated by the gate
  suite it actually shipped under. Contamination-suspect items are flagged in
  the record (template drift, whitespace-only truth churn, residual `.md`
  propagation, acceptance bullets carrying hard numeric literals).

  A record distinguishes an **integration error** from a scored outcome, and
  `score.sh aggregate` reports the two as separate metrics: an integration
  error contributes to a compatibility figure and to no quality figure at all
  — not the numerator, not the denominator — so a vendor integration failure
  can never be read as a model quality failure.

- **`validate-provider-disclosure.sh` now enforces send-vs-log coverage**
  (#1258). A send to a non-default provider — an attribution record in the
  per-seat model-usage stream whose `provider` is not the trusted default —
  with no matching disclosure-log entry for the same `(provider, item_ref)`
  now **fails** the gate. This is the half #1250's own acceptance explicitly
  deferred, unblocked by the `provider` field #1253 added. `replay.sh execute`
  discloses *before* it sends and refuses the send if the disclosure fails, so
  the log may legitimately run ahead of the sends and never behind them.

- **Replay records gain a judge pass** (#1259, epic #1225 "model comparison
  harness"). New `workflows/scripts/model-comparison/judge.sh` scores an
  already-executed `replay-record-v1` record (temperloop#1258) with a
  strong-tier judge model (`MODEL_COMPARISON_JUDGE_MODEL`, default
  `claude-opus-4-8`), attaching the result as a `judge` sub-object alongside
  the record's existing mechanical `score`. The rubric
  (`workflows/scripts/model-comparison/rubric.md`) is plain prompt text
  drawn from this repo's own reviewer-agent charters as source material — no
  reviewer agent is dispatched at judge time. A **judge≠candidate guard**
  compares the judge's provider+model against the record's candidate before
  any call and REFUSES an exact match structurally (no spend, no call); the
  guard is documented, at its own site, as preventing self-grading ONLY — it
  does not address model-family style bias (that is #1260, deliberately
  separate). `judge-batch` never silently drops a row: a judge that becomes
  unavailable mid-batch marks only the affected rows with a named
  `degradation_notice` (`judge.scored:false`, `judge.quality_score:null`),
  structurally distinct from a genuine `judge.quality_score:0` the judge
  actually rendered. Same hermetic-by-construction shape as replay-execute:
  every call routes through an injectable `--judge-runner` seam or the
  explicit `--live` flag, with no implicit fallback to a `claude` binary on
  PATH. Two new registered settings (`MODEL_COMPARISON_JUDGE_MODEL`,
  `MODEL_COMPARISON_JUDGE_TIMEOUT_SECS`) and a new
  `scripts/quality-gates.sh` entry
  (`workflows/scripts/model-comparison/tests/test_judge.sh`).

- **Optional cross-family judge rotation** (#1260, epic #1225 "model
  comparison harness"). New `judge.sh judge-rotate` subcommand scores one
  replay record with judges from more than one provider family (a
  comma-separated `--judges provider:model,provider:model,...` panel) and
  reports the **variance** of their `quality_score` across the panel —
  consumed from `stats.sh`'s own sample-stddev (squared here in a single line
  of jq arithmetic), never a second statistics implementation. **OFF by
  default** (`MODEL_COMPARISON_JUDGE_ROTATION_ENABLED=0`): with it off,
  `judge-rotate` refuses immediately (`CANNOT_EVALUATE`) and `judge`/
  `judge-batch`'s own behaviour is byte-identical to the pre-rotation module.
  Each rotation member is scored via the exact same judge≠candidate guard,
  non-default-provider allowlist+disclosure gate (the same committed
  allowlist and same disclosure log a candidate replay uses), and
  `candidate-session.sh` spawn (containment overlay + provider-key health
  check) the single-judge path already uses — reused verbatim, never
  reimplemented for the panel case. Every emitted record carries an explicit
  disclaimer: rotation **REPORTS** family-bias variance and does **NOT
  PROVE** the resulting judgment is free of model-family bias. Fail-closed
  throughout (temperloop#1365 class): too few JUDGED members, JUDGED members
  from only one provider family, or a genuine `stats.sh` failure all
  `CANNOT_EVALUATE` the variance rather than reporting a fabricated or
  zero-standing-in figure. Two new registered settings
  (`MODEL_COMPARISON_JUDGE_ROTATION_ENABLED`,
  `MODEL_COMPARISON_JUDGE_ROTATION_MIN_JUDGES`) and a new
  `scripts/quality-gates.sh` entry
  (`workflows/scripts/model-comparison/tests/test_judge_rotation.sh`).

- **A comparison report producer for the model-comparison harness** (#1261).
  `workflows/scripts/report-producers/model-comparison` rolls a baseline arm
  and a candidate arm of scored replay records into one JSON report: whole-job
  cost per merged outcome, judge quality scores, gate outcomes,
  intervention/rework proxies and durations, with a bootstrap confidence
  interval and a minimum-detectable-effect disclosure ("at this N, only deltas
  of at least X are detectable") on every run. Every statistic is taken from
  `model-comparison/stats.sh` and the scored-only quality split from
  `score.sh aggregate` — neither is recomputed here, so a bound in the report
  and a bound from the library cannot drift apart.

  The report is built to be honest about what it does not know. It states its
  emit-coverage percentage against the emit-feasible seat denominator (with
  the excluded seats named), its corpus window, its quality-gate versions and
  its cost basis — cost-weighted **token counts**, explicitly neither metered
  dollars nor a subscription-usage share — on every run, not only when those
  read well. A run below the sample threshold reports `inconclusive` and emits
  no `winner` key at all; a run it cannot evaluate renders a single
  `skipped -- model-comparison: <reason>` line at exit 0 and no report object,
  so "could not evaluate", "inconclusive" and "the candidate is better" stay
  three visibly different statements. A stale or absent price table degrades
  to a dated staleness label or a stated token-counts-only basis rather than a
  silently missing line, and a row hit by a mid-batch judge outage carries its
  own named degradation notice instead of being scored as a zero.

  Additive only: new files and new keys, no change to the existing `tokens`
  producer's slot format or to the headline spend figure ADR 0020 owns. Per
  ADR 0027 the kernel ships **no** `.temperloop/report.d/` shim for it, so
  `temperloop report` never runs it until an adopter opts in with the same
  one-file locator shim `tokens` uses.

- **`pipeline-spend-report.sh` gains an opt-in `--by-agent-type` flag** (#1314), a
  per-seat attribution side channel over Claude Code's own agent-frontmatter
  sidecars (`agent-<id>.meta.json`). Requires `--root` to name a single Claude
  Code project directory (one whose session subdirectories hold at least one
  `subagents/agent-*.jsonl` journal) and refuses with exit 2 otherwise, rather
  than ever walking machine-wide. The emitted `by_agent_type` JSON key is
  self-contained — its `agents`/`api_calls`/`units` totals are NEVER a
  decomposition of the existing `units_total` headline, which this flag leaves
  completely untouched (`schema_version` stays `1`). A sidecar's `agentType` is
  reported as a seat only when it matches a deployed `claude/agents/**/*.md`
  basename (an allowlist, not a passthrough — `general-purpose` and friends
  bucket to `unattributed`, with the raw value kept visible for distribution
  rather than asserted as a seat). See ADR 0026's temperloop#1314 corrections
  for the rationale.

- **The replay BATCH DRIVER — the thing that connects the model-comparison
  harness end to end** (#1401): `workflows/scripts/model-comparison/batch.sh`,
  operator-invoked, turns a `replay.sh corpus` file into the `baseline.jsonl`
  and `candidate.jsonl` arm files `workflows/scripts/report-producers/model-comparison`
  reads. Epic #1225 shipped sixteen components and nothing between the corpus
  at one end and the report at the other; this is that connection, and it
  ORCHESTRATES only — it derives no statistic and re-implements no scoring,
  judging, corpus selection or isolation.
  - **The spend gate runs FIRST, and consent is explicit.** `replay.sh
    preflight` is consulted before the first worktree is prepared: a `stop`
    verdict, or a missing `--confirm`, exits 3 having spent nothing. The batch
    cap, the planned-record/replay/pair counts and the cost basis are read
    verbatim off that gate rather than re-derived, so the batch executed and
    the batch authorized cannot drift apart — a selection that disagrees with
    the authorization is refused before any spend.
  - **The temperloop#1379 two-arm unit contract holds in EXECUTION, not just
    in the estimate.** The cap binds CORPUS RECORDS; every selected record is
    replayed in BOTH arms; the driver refuses outright if pre-flight budgeted a
    different `arms_n`.
  - **Fail-soft per record, fail-closed per run.** One record's failure is
    recorded with its reason and the batch continues (exit 4 `BATCH_DEGRADED`,
    with every failure named); an unreadable input, a missing sibling script or
    an unparseable gate verdict is `CANNOT EVALUATE` and non-zero. The replay
    completion rate falls out of the driver's own output, with its unit named.
  - **Resumable, by leg.** Re-invoking after an interruption re-spends no
    replay and no judge call that already completed; a state directory bound to
    a different corpus is refused rather than silently merged into one arm file.
  - **Isolation end to end.** Every worktree is torn down on the success path,
    the failure path, and (via an EXIT trap plus an end-of-batch sweep) the
    interrupted path; `replay.sh verify-clean-parent` runs after the batch and a
    dirty parent is a named degradation.
  - **No implicit model call, ever.** Each arm requires an explicit
    `--baseline-runner`/`--candidate-runner` seam or the single explicit
    `--live` flag; with neither, the driver refuses before it even reads the
    gate. `workflows/scripts/model-comparison/tests/test_replay_batch.sh`
    (registered in `scripts/quality-gates.sh` and `gate-paths.tsv`) drives every
    arm through recorded runners, runs the REAL report producer on the driver's
    own output, and carries eight mutation proofs plus a canary `claude` that
    the whole suite proves was never invoked.

### Changed

- **`write-lane-guard.sh` no longer prompts on the one cross-repo direction
  the architecture prescribes: a kernel checkout mutating its own declared
  allied overlay checkout** (#1028). The guard's verdict is unchanged
  everywhere else (still `ask`, never deny, on every other foreign canonical
  checkout — the epic #86 peer-session protection) — this only exempts an
  explicitly DECLARED pair from firing at all. The pairing is read from an
  optional, gitignored, repo-local config file,
  `claude/hooks/write-lane-allies.conf` (tracked `.example` at
  `claude/hooks/write-lane-allies.conf.example`, same
  tracked-example/gitignored-real-file shape as
  `workflows/scripts/board/boards.conf.example`) — a config file rather than
  an env var, since `KERNEL_EDIT_ACK`/`EVAL_RUN` are session-scoped
  acknowledgements and this is a durable, repo-level fact. Never a hardcoded
  org/repo string: this kernel ships to strangers whose overlay checkout is
  not necessarily named `foundation`. **Not breaking** — absent config is
  today's behavior exactly, byte-for-byte.

- **A queue-time `CONFLICTING` now takes a shared `rebase-and-retry`
  disposition instead of an unconditional park** (#1093). GitHub reports
  `CONFLICTING`/`DIRTY` both for a branch whose base merely *moved* while the
  PR sat in the merge gate and for a branch with a genuine content conflict —
  and `/build` Step 4c and `/fix` Step 5 parked on the label either way,
  spending an operator's merge approval on a base that had simply advanced.
  `/build` § 4c gains **`4c-retry`**, one implementation composed entirely from
  existing machinery (`pr.sh rebase` → `pr.sh push --force` → a `--sha`-pinned
  `ci-poll.sh` → the caller's already-probed `gate.sh queue` /
  `gate.sh managed-merge`), and `/fix` Step 5 references that section by name
  rather than carrying a second copy. A cleanly-rebasable PR is re-pushed,
  re-verified on the new head, and re-enqueued **within the same run with no
  second merge approval** — sound because the merge decision is unchanged (a
  clean rebase replays the approved commits without touching a hunk) and the
  one thing that moved, the base, is re-verified mechanically by the
  SHA-pinned poll before anything is enqueued. A **genuine content conflict
  still parks**, now naming the conflicting files, and is never auto-resolved;
  a `CI_FAILED` on the new base takes the existing `EJECTED` disposition set;
  a second `CONFLICTING` stops the retry rather than looping. `pr.sh rebase`'s
  own `REBASED`/`REBASE_CONFLICT` outcomes are the branch point, and its
  abort-and-restore on conflict is relied on, not reimplemented. Contract
  surface via `claude/commands/*.md`; **not** breaking — the park path and the
  `#130` confirmed-`MERGED` guard are unchanged, the retry only runs ahead of
  them. `/sweep` is deliberately **not** wired in: it fires
  `gh pr merge --auto` and immediately records the item fixed, with no
  merge-confirmation call site to hang a disposition on — that plumbing is
  tracked separately (#1268).

### Removed — BREAKING

- **The try-era demo-repo generator `workflows/scripts/demo/seed-demo-repo.sh`
  and its `SEED_DEMO_REPO` setting** (#1230). The generator seeded a scratch
  repository **this project owned**, which ADR 0025 retires: evaluation
  artifacts are now materialized into the operator's own account from the
  in-tree seed above. `workflows/scripts/demo/` is retained as the seed-content
  home. **Migration:** if you set `SEED_DEMO_REPO` in a host-local config or
  CI secret, drop it — it is no longer read by anything, and the testbed's
  target repository is resolved from the source provider's `base_name` in the
  operator's own account instead. The `try`-side settings and the CI
  round-trip's own use of the generator are retired with `try` itself
  (#1237/#1234).

- **`temperloop try` and `temperloop try --demo` are removed, and the CLI's
  front door is now `temperloop testbed`** (#1117). The old two-rung on-ramp
  (`try` -> `try --demo` -> `init`) was retired in favour of the sandbox walk
  (#1115): `try`'s shadow-triage ran with almost no context, so its output
  undersold the pipeline, and `--demo` ticked a canned repo of synthetic
  defects rather than the reader's own code. Deleted outright:
  `bin/subcommands/try.sh`, its two suites (`test_try.sh`,
  `test_try_demo.sh`), and `bin/lib/cost-estimates.conf` (every constant in
  it was a `TRY_*` band). `bin/temperloop`'s `Start here:` line and
  `temperloop help` now name `temperloop testbed`. `try`'s documentation goes
  with it, in the same change rather than a follow-up — `bin/README.md`'s
  legacy-commands section and `docs/features/install-cli.md`'s legacy rungs.

  **Migration — CLI surface.** `temperloop try` and `temperloop try --demo`
  no longer exist and exit as unknown subcommands; there is no compat shim
  and no drop-in replacement with the same shape. Evaluate on your own code
  with **`temperloop testbed`** instead (`docs/features/testbed.md`), which
  builds a private, disposable duplicate of a real repository of yours and
  hands off to `init` -> `/assess` -> `/build`. Note the deliberate trade:
  `try`/`try --demo` carried hard, tool-enforced USD caps ($1.00/run and
  $2.00/tick) and the testbed path does **not** — it runs the real pipeline
  and carries no dollar ceiling (temperloop#1130 tracks closing that gap).
  `VERSIONING.md`'s CLI-surface row no longer enumerates `try`.

  **Migration — setting registry.** Five `TRY_*` rows are gone from
  `workflows/scripts/config/setting-registry.tsv`, and they are **not** the
  same kind of removal — read which class yours is before pulling. Three are
  `kernel`-scoped test seams that only ever existed to let `try.sh`'s own
  suites inject doubles — `TRY_GH_BIN`, `TRY_DEMO_CLONE_URL`,
  `TRY_DEMO_BOARD_NUM`; a consumer setting them is a no-op today and their
  removal is harmless. The other two are `tracked-repo`-scoped model
  settings — `TRY_TRIAGE_MODEL` (defaulted `claude-haiku-4-5`) and
  `TRY_DEMO_FIX_MODEL` (inherit sentinel) — and this is the materially
  different case: a downstream overlay may carry a **live override** for
  either in its own `build.config.sh`, and that override now names a setting
  nothing reads. It will not error; it will silently do nothing. **Delete
  those two overrides from your overlay** rather than leave them as dead
  config. Their definitions and their entry in the export list are removed
  from `workflows/scripts/build/build.config.sh` in the same change, so the
  registry-to-source correspondence stays clean.

- **The `make test-try` gate is renamed `make test-cli-subcommands`, not
  deleted** (#1117). The target only ever carried `try`'s name incidentally:
  it globs the whole `bin/subcommands/tests/` directory and is the sole
  runner for 13 suites that have nothing to do with `try` (init, eject,
  config, configure, report, feedback, uninstall, update, baseline-snapshot,
  dispatch-rename, prereq-scoping, report-offer, tokens-producer). Deleting
  it would have silently dropped all of their coverage. The glob, and
  therefore the covered set, is unchanged; only the name moved, along with
  its `.PHONY` entry, its help line, its `gate-paths.tsv` row and its
  `scripts/quality-gates.sh` registration. A downstream repo invoking
  `make test-try` directly must call `make test-cli-subcommands` instead.


### Fixed

- **Board claim-stamp host labels no longer diverge by call site** (#1455).
  `claim.sh`, `release.sh`, `capture.sh`, and reconcile.sh's three read sites
  each inlined their own `${SUBSET_HOST_LABEL:-$(hostname -s)}` fallback,
  `board-mirror.sh` independently inlined a three-way variant that also
  nested the legacy `STAGEFIND_HOST_LABEL` override, and one reconcile.sh
  site added a fourth `|| echo unknown` variant on top — five inlined copies,
  three different shapes. `build.md`'s prose spec documented the three-way
  chain as canonical, but no script actually matched it. One real machine hit
  the resulting divergence live: some issues got claim-stamped `mini`, others
  `Mac-mini`, and `reconcile --status` then misclassified a same-host claim
  as foreign. Added `board_host_label()` to
  `workflows/scripts/board/lib/board.sh` as the one resolution chain every
  site now calls (`$SUBSET_HOST_LABEL` → legacy `$STAGEFIND_HOST_LABEL` →
  `hostname -s` → a literal `unknown`, never empty); the `build.md` and
  `decision-queue-contract.md` prose specs now name the helper instead of
  restating a chain, so they can't drift from the scripts again.
  `workflows/scripts/build/issue-state.sh` and `env-reconcile.sh` still
  inline a variant of this chain — left alone deliberately (issue-state.sh
  doesn't source board.sh today; env-reconcile.sh's host check answers a
  different question, launchd/cron role ownership, not claim stamps) — and
  is a follow-up, not part of this fix.
- **`ready-pr-sweep.sh` no longer misclassifies a PR whose `mergeStateStatus`
  simply hasn't been computed yet as `needs-attention`** (foundation#1504).
  GitHub computes `mergeStateStatus` asynchronously — right after a push, an
  enqueue, or any base-branch movement it reads `UNKNOWN`, meaning "not
  computed yet", not "computed, and problematic". Reading it exactly once
  meant the SAME PR could read `UNKNOWN` (→ `needs-attention`) on one sweep
  and `CLEAN` (→ `ready`) moments later on the next — the remedy flipped
  between back-to-back runs. The sweep now re-fetches ONLY a PR that reads
  `UNKNOWN` on the initial `gh pr list`, with a bounded retry
  (`READY_PR_SWEEP_UNKNOWN_RETRY_MAX`, default 3) and a short delay between
  attempts (`READY_PR_SWEEP_UNKNOWN_RETRY_DELAY`, default 2s) — a PR that
  reads a resolved status on the first fetch costs zero extra `gh` calls. A
  PR resolved on retry (e.g. UNKNOWN → CLEAN) now classifies normally; a PR
  still `UNKNOWN` after the bound gets its own `not-yet-computed` bucket,
  distinct from `needs-attention`, whose reason names the real cause and
  prescribes no operator action — it is deliberately excluded from
  `--format entry` since there is nothing to decide (it resolves on its own
  on a later sweep). Fail-open throughout: an errored or exhausted retry
  never aborts the run or drops the other PRs from the report.

- **The kernel/overlay classifier is shell-portable and fails closed — it no
  longer answers "not kernel" when it cannot evaluate at all** (#1177).
  `workflows/scripts/kernel/lib.sh` is *sourced*, so its `#!/usr/bin/env bash`
  shebang is inert and it runs under whatever shell the caller is. On macOS
  that is routinely zsh, and two bash-isms broke there **silently**:
  `${!ARRAY[@]}` (rejected with `bad substitution`) and — the nastier half —
  zsh's refusal to glob-match a pattern arriving via parameter expansion
  without `GLOB_SUBST`, which makes `case "$f" in $pat)` and
  `[[ "$f" == $pat ]]` evaluate to *no match* with no error whatsoever. The
  result was `kernel_lib_classify claude/commands/build.md` returning empty +
  rc 1 under zsh (`kernel` under bash) — bit-identical to the legitimate
  "no pattern matched" answer, so **every agent invocation** of `/assess`'s
  seam-straddling check and `/build` Step 3b's kernel backstop (the #1050
  guard) took the failing branch and passed everything it exists to stop. The
  lib now holds the manifest in one newline-delimited scalar instead of
  parallel arrays, sets `localoptions globsubst` under zsh, and keeps every
  construct POSIX-shaped (bash 3.2 / bash 5 / zsh). Fail-closed is now a
  *signal*, not better error handling: `kernel_lib_load_manifest` runs a
  known-answer `kernel_lib_selftest` before parsing and verifies its entry
  store populated, and `kernel_lib_classify` distinguishes **rc 1** ("no
  pattern matched") from **rc 2** (`CANNOT EVALUATE`). Every consumer treats
  rc 2 as a hard error rather than swallowing it: `check-kernel-manifest.sh`
  and `list-kernel-set.sh` abort instead of reporting a path unclassified or
  emitting a silently-truncated kernel set, `validate-feature-docs.sh` gains
  the same rc contract plus its own matcher selftest, and the two **prose**
  consumers (`claude/commands/assess.md`, `claude/commands/build.md`) carry
  identical fail-loud wording so the agent-executed surface behaves the same
  way. A new dual-shell regression gate,
  `workflows/scripts/kernel/tests/test_kernel_lib_portability.sh`, runs
  byte-identical asserts under bash, zsh, and macOS bash 3.2 against a
  **known-kernel control** (`claude/commands/build.md`) — the control being
  the point, since a run that checks only the files it just touched is exactly
  how this stayed invisible. Contract surface via `claude/commands/*.md`; not
  breaking.

- **The board issue cache no longer serves a merged item as still open/In
  Progress until its TTL expires** (#1164). The write-through invalidation
  hook `_board_cache_dirty_after_write` (`board.sh`, called from every
  `board_set_status`/`board_stamp` write) already existed and was already
  tested — it was a *designed* no-op whenever the calling bash block hadn't
  sourced `lib/cache.sh`, which none of the merge-confirmed Done-write sites
  did. `claude/commands/build.md` (4d's per-item Done write and 4d-epic's
  epic-close Done write), `claude/commands/fix.md` (Step 6's Board
  close→Done), and `claude/commands/sweep.md` (Phase 2's merge and spike-close
  arms, which bypass the adapter entirely and so take an explicit
  `cache_dirty` call) now guarded-source `lib/cache.sh` alongside
  `lib/board.sh` — the same `if [ -f … ]; then . …; fi` form
  `worklist.sh:50-53` already used, never `[ -f … ] && .` under `set -e`
  (temperloop#1118) — activating cache invalidation on the merge-confirmed
  Done write. `test_cache_command_wiring.sh`'s warm-cache/zero-`gh`-call
  assertion for `worklist.sh` is unchanged: this only makes the *next* read
  after a merge legitimately stale, so it refetches once, not on every warm
  no-change read. Contract surface via `claude/commands/*.md`; **not**
  breaking.

- **A transient GitHub Actions infra outage no longer permanently ejects a
  healthy PR onto the do-not-retry path** (#1175). `gate.sh diagnose-queue`
  splits its `MERGE_GROUP_FAILED` verdict on **per-job step data**
  (`repos/<owner>/<repo>/actions/runs/<run_id>/jobs`, never log text): a
  workflow-defined step — any step after the runner-provided "Set up job"
  step — itself concluding `failure` stays `MERGE_GROUP_FAILED` (exit 7, a
  real gate failure); the run concluding `failure` before ever reaching a
  workflow-defined step now reads a new `MERGE_GROUP_INFRA` verdict (exit 11,
  payload `{"pr":N,"run_id":N}`) instead. The motivating incident: foundation
  PR #1563's `merge_group` run logged `Set up job -> Failed to resolve action
  download info -> Service Unavailable` and was reported as a gate failure,
  routing a healthy PR to conflict-resolution with no conflict to resolve.
  Classification is purely structural — the step's position, never its name
  or any log string — so a CI step rename can never silently reclassify a
  result, and anything unclassifiable (the jobs lookup erroring, an
  empty/missing jobs array, missing step data) stays the conservative
  `MERGE_GROUP_FAILED` default: this split never widens what gets retried.
  `build.md` Step 4b routes `MERGE_GROUP_INFRA` to a **re-enqueue** (the same
  re-arm-once pattern `DEQUEUED` uses) rather than ejecting to 4c, and names
  it alongside `MERGE_GROUP_FAILED` in the unattended pending-decisions
  record. Contract surface via `claude/commands/build.md`; **not** breaking —
  `MERGE_GROUP_FAILED`'s existing exit code, payload shape, and 4c routing
  are unchanged for a real gate failure.

- **A stalled merge queue is now distinguishable from a merely slow one**
  (#1178). `gate.sh diagnose-queue` gains a `QUEUE_STALLED` verdict (exit 10,
  payload `{"pr":N,"enqueued_secs":S,"merge_group_runs":0}`): a PR that is
  *still* enqueued past the new `BUILD_QUEUE_STALL_AFTER` setting with **zero**
  `merge_group` runs ever dispatched for it is stuck, not slow — so a caller
  stops waiting instead of re-polling to the `BUILD_QUEUE_TIMEOUT` ceiling and
  then guessing. This is the probe that was hand-run during the incident
  (`gh run list --event merge_group` against the entry's `enqueuedAt`), now in
  the machinery. A healthy entry is untouched: under the threshold, or with any
  referencing run, it still reads `QUEUED`, so the ~2.5 min a queue's own
  checks legitimately take can never trip it. `gate.sh poll`'s `TIMEOUT` now
  runs the same probe and carries its verdict as `reason`/`diagnosis` rather
  than a bare `waited` count — the difference between "try again later" and
  "stop waiting, this needs a human" — falling back to the previous bare shape
  when the probe itself errors. `build.md` Step 4b routes the new verdict
  (dequeue + `managed-merge --strict` fallback) and names it in the unattended
  pending-decisions record.

- **The board scripts' remaining live Projects-v2 framing is corrected to the
  issues-only backend ADR 0004 shipped** (Towheads/foundation#1339). Two
  runtime-facing sites still described the removed backend: `capture.sh`'s
  not-landed error told the operator to wait out "a Projects-v2 index race"
  when the issues-only backend writes status synchronously — the real failure
  mode is a failing/transient `fnd:status:*` label write, which the message
  now names, along with a working remedy; and `release.sh`'s parking guidance
  named `gh project item-edit`, a Projects-v2-only command that cannot work on
  any registered board, replaced with the currently-valid options
  (`unclaim.sh`, `board_set_status`, or hand-editing the `fnd:status:*`
  label). Not breaking: comment/message wording only, no behavior or contract
  change.
- **`/build` Step 0a drains an answered plan-approval on attended ticks too, so
  an operator's `approve` no longer strands** (Towheads/foundation#1496). The
  step was gated on the operator-absent flag, so on a board no funnel ticks the
  answer was read by nobody: the decision issue went unassigned (= answered),
  the plan note stayed `status: draft`, and `/build` refused to pick it up —
  observed inert for six days with no surface anywhere showing it was stuck.
  Step 0a now runs on every work-selecting tick, in two arms. The
  operator-absent arm is unchanged (set `status: approved`, then invoke
  `/build --unattended`). The new **attended-tick drain** applies the same
  answer, stops at `status: approved`, reports the plan in one line, and is
  explicitly forbidden from invoking `/build` — widening *when* the step fires
  is already a fleet-wide change, and letting an attended tick auto-start a
  build would widen what that firing can *do* (`docs/principles.md` § 7 Bound
  the blast radius). Not breaking: no overlay must adapt, and the only
  behavioral delta for an attended argless `/build` is one extra `gh issue
  list` read plus the `status:` flip the operator already asked for.
  `/check-in` Part 1 gains a read-only § Stranded plan approvals probe as the
  backstop for a repo neither arm ticks.
- **Every piped `grep -q` is gone from the tracked shell set, and a new lint
  keeps the shape out** (#1050). `grep -q` exits zero at its *first* match
  without draining the pipe, so the writer upstream takes SIGPIPE (141) and,
  under `set -o pipefail`, the pipeline reports **141 — a failure — even though
  grep matched**. It is a race on whether the writer had already finished, which
  is why such a line passes for months and then fails once under a longer input.
  Every site is converted to the one sanctioned form — drop `q` from the flag
  cluster however it is clustered (`-Fxq`→`-Fx`, `-qF`→`-F`, `-Eiq`→`-Ei`, bare
  `-q`→ no flag) and append `>/dev/null`, which drains to EOF with bit-for-bit
  identical exit status. A `<<<` herestring and an intermediate variable were
  both rejected: each changes trailing-newline or word-splitting behaviour per
  site. **Contract surface:** `scripts/quality-gates.sh` gains a `KERNEL_GATES`
  pair, `bin/subcommands/{init,eject}.sh` change behaviourally under pipefail,
  and an overlay carrying its own shell scripts will see the new lint run
  against them. Not breaking — the new gate rejects a shape that was already
  wrong, and the fix is mechanical.
- **New `scripts/lint-pipe-grep-q.sh` gate** (#1050). Anchored, quote-aware, and
  self-exempt: it fires on `<writer> | grep -<cluster containing q>` (including
  `egrep`/`fgrep`/`zgrep` and `command grep`), and stays silent on an *unpiped*
  `grep -q file` — correct, and a pure win — and on a comment that merely names
  the shape. It reads every tracked `*.sh` **plus every tracked file with a
  sh/bash shebang**, with **no pipefail predicate**: a sourced lib sets no `set`
  line and inherits pipefail from its caller, which is exactly how
  `workflows/scripts/lib/issue-marker-probe.sh` hid a live site. Paired
  `scripts/tests/test_lint_pipe_grep_q.sh` demonstrates the lint firing on the
  real pre-sweep `bin/subcommands/init.sh` line and staying silent on prose.
  The sweep's completeness criterion is that lint exiting 0 over the tree — a
  predicate, deliberately not a site count.
- **`/sweep` now treats an issue with a later `Clarified (…)` answer comment
  as answered, not underspecified** (#1193). Phase 1's per-item fetch pulled
  only `title,body,labels`, so an issue whose question had already been
  answered in a comment — by triage, by a prior `/sweep` answer, or by the
  Phase-2 escalation-park path — carried no signal the detection fanout could
  see; a stale surviving `needs-clarification` label, or the self-judged-
  underspecified arm re-reading the same ambiguous body, could re-raise a
  question the operator already answered. The fetch now also pulls
  `comments`, and Step 2 states the exclusion explicitly: an issue carrying a
  `Clarified (…)` comment (`Clarified (sweep): …`, `Clarified (triage): …`,
  etc.) newer than its most recent flagging-type comment — either
  `needs-clarification: <question>` or the escalation-park path's
  `Parked by sweep — <question>` — is **answered, not underspecified**, and is
  excluded from the question batch. The rule applies to both detection arms
  (self-judged and already-labelled), so a stale label alone cannot re-raise
  an answered question. The comment-timestamp comparison itself is mechanical,
  not judgment, so it also ships as a standalone, independently testable
  script (`workflows/scripts/build/sweep-answered-exclusion.sh`, covered by
  `workflows/scripts/build/tests/test_sweep_answered_exclusion.sh`) rather
  than living only as prose.
- **The drain no longer lexicon-greps the expanded command spec as operator
  signal** (#1199). Claude Code writes a slash-command invocation as TWO user
  turns: the `<command-name>` tag block (~115 chars), then the **expanded
  command spec prose** (~133k chars in the cited stub) — which carries no
  `<command-*>` tag at all. `scan_stub.py`'s purely tag-based
  `_CMD_EXPANSION_PATTERNS` matched only the first, so the entire spec body was
  scanned as though the operator had typed it: the stub
  `2026-07-29-0254-foundation.cron-e5e70c47.md` yielded 38 lexicon matches, all
  from turn 1, all the tidy spec quoting its own tells. Every
  `claude -p "/<cmd>"` cron run (tidy, build, sweep, triage, check-in) hit this
  on every run, making it the drain's highest-volume false-positive source.
  `extract_user_turns` now also excludes the **single** user turn immediately
  adjacent to a `<command-name>` invocation. The rule is deliberately narrow:
  one turn of adjacency (a genuine operator turn later in the session is
  untouched), user-role only (an adjacent assistant turn means the command
  produced no expansion turn), and **no size threshold** — a bare length cutoff
  would silently drop long genuine operator turns. F#1137's
  `spec_authoring_context` damping does not cover this case: it keys on an
  Edit/Write to a tell-defining file, and here the session never *edited* a
  spec, it merely *received* one as its prompt.
- **The merge gate's hunk-overlap probe now trial-merges the pushed PR heads,
  not stale local refs** (#1198). `/build` Step 4a's condition-(a) probe decides
  whether a selected set is `risky` (modal hard-block) or
  `clean-disjoint-independent` (timed auto-merge), and it did so by running
  `git merge-tree --write-tree <branchA> <branchB>` on **bare** branch names.
  Git resolves a bare name against whatever the local clone last saw — a
  leftover from a removed worktree, or a ref diverged from what was actually
  force-pushed — so the probe could trial-merge the wrong trees and report a
  **spurious** conflict, converting an unattended timed merge into an operator
  interrupt. Both documented forms (the primary and the older-git
  `merge-base` fallback) are now `origin/`-qualified and preceded by an
  explicit `git fetch origin <branchA> <branchB>`, so the probe tests the
  pushed head the queue would actually integrate — the same reasoning § 4a.5
  already states for `combined-tree-precheck.sh`. Prose-only; the two-tier
  probe structure (cheap file-overlap advisory, then hunk-overlap on same-file
  pairs) is unchanged. Not a duplicate of #998, which concerns `--write-tree`
  *output* reuse rather than *input* ref resolution.

- **A draft PR is now a named state in the merge path, not GitHub's raw
  enqueue error** (#1180). `gate.sh queue` enqueued blind, so a draft PR — which
  GitHub refuses to auto-merge — failed with the raw string
  `GraphQL: Pull request is a draft (enablePullRequestAutoMerge)`: true, but
  naming neither the state nor the fix, and leaving behind a PR no re-run could
  ever land. The investigation this fix turned on: **draft-open is not a
  pipeline flow.** `pr.sh open` calls bare `gh pr create --head --title --body`
  with no `--draft` on any path, `build-level.mjs` adds none, `pr-enqueue.sh`
  drafts only on an explicit `--draft` opt-in (and already refused to enqueue
  one), and **no script in this repo runs `gh pr ready`** — so a draft reaching
  the merge gate is always a human decision. The disposition is therefore to
  **fail loudly, never to auto-flip**: `queue` reads `isDraft` before the
  enqueue and returns a distinct `DRAFT` outcome (exit code 9) whose message
  names the draft state and the remedy (`gh pr ready <n> -R <owner>/<repo>`);
  silently un-drafting would override the one party who chose it. The pre-flight
  probe **fails open** — an unreadable `isDraft` proceeds to the enqueue, never
  worse than before — and a second classifier, anchored on the draft phrase
  alone so an unrelated auto-merge rejection is not mis-named, returns the same
  `DRAFT` outcome when `gh` itself rejects the PR. Neither path can surface the
  raw GraphQL text.
- **`ready-pr-sweep.sh` gained a `stale-draft` drift class** (#1180). The sweep
  classified every draft as `skip`, and `--format entry`'s nothing-when-clean
  contract suppresses a skip-only repo entirely — so a draft nobody ever flipped
  ready was structurally invisible to the one surface that reports stuck work.
  That is how three drafts sat 1-3 weeks with real fixes in them, one a live
  correctness bug. A draft idle for `READY_PR_SWEEP_STALE_DRAFT_DAYS` or more is
  now its own named class and a genuine candidate, so it reaches `/check-in`
  through the pending-decisions entry; a *recent* draft stays `skip`, since an
  in-flight draft is a deliberate state and not drift. The sweep remains
  read-only and fail-open — it names the stale draft, it never flips or closes
  one.
- **The `pipefail` + `grep -q` SIGPIPE race is gone from the kernel test
  suite** (#1173). Under `set -o pipefail`, `echo "$var" | grep -q PATTERN` is
  a race, not a stable idiom: `grep -q` exits on its **first** match and closes
  the pipe while the producer may still be writing, the producer takes
  `SIGPIPE`, and `pipefail` promotes that non-zero status to the whole
  pipeline — so a **passing** assertion intermittently reports failure. Because
  it is a race it reproduces only sometimes, which is why a single green run
  was never evidence a site was safe. The confirmed instance reds CI:
  `test_issue_corpus.sh` line 211 printed `echo: write error: Broken pipe` and
  then `FAIL: 3: doc2 missing/wrong state field (closed issue)` in foundation CI
  run 31101856658. All **618** `<producer> | grep -q` constructs across **59**
  kernel test scripts — every `tests/` directory under `workflows/scripts/`,
  `claude/hooks/`, `bin/subcommands/` and `scripts/` — are rewritten to the
  race-free here-string form `grep -q PATTERN <<<"$var"`, which has no writer
  process to signal and no pipeline for `pipefail` to judge. Three multi-stage
  variants (`echo … | awk … | grep -q`, `printf … | jq … | grep -qv`) are
  de-piped the same way. The rewrite is deliberately a here-string rather than
  a `case` arm: a here-string preserves each assertion's **exact** semantics —
  every flag (`-F`, `-E`, `-i`, `-v`, `-x`, `--`), every anchor, and every
  negated `&& fail` — whereas a `case` glob would silently turn an anchored
  assertion like `^state: "closed"$` into a permissive substring test, weakening
  the suite in the name of fixing it. `bin/subcommands/tests/test_tokens_producer.sh`
  is deliberately untouched: #1168 / PR #1172 own that file.

- **`test_tokens_producer.sh` check 16 no longer fails at random on a
  consumer's Linux CI** (#1168). The check built its haystack twice with
  `grep -vE '^[[:space:]]*#' "$IMPL" | grep -q <pattern>`, under the file's own
  `set -uo pipefail`. `grep -q` exits on first match — for the
  `SPEND_TRANSCRIPT_ROOT` pattern that lands within the first few hundred bytes
  of a ~37KB producer — closing the pipe while the upstream `grep -vE` is still
  writing. GNU grep (every Linux CI runner) then reports `write error: Broken
  pipe` and exits 2, `pipefail` promotes that to the pipeline's status, `!`
  inverts it, and the check fails **a green tree**. BSD grep on macOS usually
  wins the race, which is why it reproduced only downstream and read as a flake
  locally. The comment-filtered source is now captured once into a variable and
  matched with `case` — no pipe, no race — matching the convention check 12
  already used. The assertions are otherwise untouched (same two patterns, same
  two failure messages), so this cannot mask a real disclosure regression. Found
  downstream while building foundation#1552, where a worker had fixed it inside
  foundation's *vendored* `kernel/` subtree; that commit was dropped and
  transplanted here, upstream-first. A sibling instance of the same
  `pipefail` + `grep -q` shape in `workflows/scripts/lib/tests/test_issue_corpus.sh`
  — which, not this one, is what had actually been reddening consumer CI — is
  fixed by #1173 above, in this same release.

- **A token carrying only the default `repo` scope is no longer refused by five
  command specs for a capability none of them uses** (#1159). `/fix`, `/sweep`,
  `/next`, `/assess` and `/triage` hard-stopped at Step 0 unless `gh auth
  status` listed the **`project`** scope, and offered `gh auth refresh -s
  project` as the remedy. That scope authorized the Projects-v2/GraphQL board
  arm, which ADR 0004 / epic #524 removed outright: every registered board now
  runs the issues-only backend, where Status, the claim stamp, Done and the
  epic mirror are plain-REST label writes, issue-closes and sub-issues calls —
  all covered by `repo`. The `gh auth status` check itself is unchanged in every
  spec that had one; only the scope *requirement* is gone, replaced by an
  explicit "never check for or require a `project` scope" statement matching the
  one `/triage` Step 0.2 and `/build` Step 0.5 already carried. `/build`'s two
  claim-failure notes drop the `-s project` remedy, and its Step 0.5 bullet is
  collapsed to state the single remaining backend rather than argue against a
  branch that no longer exists. The same dead framing is cleared from the
  `claim.sh`, `worklist.sh` and `unclaim.sh` headers (which all still advertised
  the `project` scope as a prerequisite) and from the `capture.sh` and
  `milestone.sh` headers (which described `--board` as selecting a "Projects-v2
  board"). Third instance of #524's decomposition gap, where a leg's enumerated
  `files:` list was treated as an inventory: `grep -rn 'auth refresh -s project'
  claude/ workflows/` now returns nothing.
- **`/sweep`'s Step 1 singleton fix pool no longer admits decomposed epic
  parents** (#1038). The pool was defined as Ready items with `board_parent_issue`
  empty, which correctly excludes epic *children* but not epic *parents* — a
  Ready item that is itself an epic head with native sub-issues passed the
  filter untouched and would be driven through a single fix worker instead of
  the `/assess` + `/build` path its decomposition calls for. Measured impact:
  11 of 46 pooled items were epic parents on board 7 and 13 of 31 on board 4
  (2026-08-02). The pool now also excludes any Ready item for which
  `board_sub_issues <board> <issue#>` returns non-empty, gated on the same
  Ready-slice-only scope the existing `board_parent_issue` check already used
  (no whole-board REST fan-out added), and the seam prose at every site that
  described the filter — the frontmatter `description:`, the header
  paragraph, and Step 1 itself — now reads "neither a sub-issue of an epic nor
  an epic parent" instead of "not a sub-issue of an epic".
- **`pipeline-tick.sh`'s Phase R retro-judge urgency bypass now fires against
  the real `gh` label shape, and a parked-but-not-due tracker set is no
  longer silent** (#1184). `read_retro_trackers`'s LIVE arm (`gh issue list
  --json …labels`) hands back `labels` as OBJECTS
  (`{id,name,description,color}`), never bare strings, while
  `retro_judge_due_reason`'s urgency check was `(.labels // []) |
  index("retro-urgent")` — always `null` against an object array, so the
  urgency bypass decided at mint (#533) never fired live even though the
  DRY_RUN fixture arm (already string-shaped) always passed. The LIVE arm now
  normalizes `labels` to a bare name array so both arms agree. Separately,
  Phase R's "not due yet" case (trackers parked, none urgent, the oldest
  hasn't crossed `RETRO_MIN_INTERVAL`) used to return silently — indistinguishable
  from a healthy no-op tick — and now emits a `skip-retro-judge` action with
  `reason: "not-due"` carrying the tracker count and the computed `due_at`, so
  a steady-state debounce wait reads distinctly from the two broken-judge
  skips (`not-declared`, `headless-unsupported`) instead of going quiet.

- **The board adapter now owns sub-issue linkage writes** (#1188). `board_add_sub_issue` / `board_remove_sub_issue` in `workflows/scripts/board/lib/board.sh` close the last sanctioned raw-`gh api .../sub_issues` bypass — `build.md`, `triage.md`, and `board-mirror.sh` all previously POSTed the sub-issues REST endpoint directly instead of going through the adapter. Both writers resolve the child issue's database id, bust the issue-cache store entry on success (matching `board_set_status`'s shape), and are covered by `test_sub_issue_write.sh`.

- **A live replay now actually runs inside the replay worktree** (#1376). `replay.sh execute`'s `--live` arm spawned the candidate through `candidate-session.sh` without ever changing directory, so the session worked in whatever cwd the caller happened to have and only the *prompt* named the prepared worktree — prose, not a mechanism. Every live replay therefore measured the wrong tree (on a host with the build-worktree guard armed the candidate was denied every write and returned "Blocked"; without that guard armed it would have committed into the operator's own checkout). The spawn is now wrapped in a subshell that `cd`s into the worktree, so a candidate's cwd-relative `git` resolves inside it regardless of whether any PreToolUse hook is armed. The offline `--candidate-runner` arm is unchanged — it was already handed the worktree explicitly, which is why no existing test could see the defect; the new `test_replay_live_cwd.sh` gate pins the live arm's spawn cwd directly.

- **The replay scorer runs its quality-gate subprocess under a constructed environment, not an inherited one** (#1378, #1377). `score.sh` sources `build.config.sh` for its own two settings, and that file reads the operator's machine conf and then `export`s ~83 pipeline settings — so the gate child simply inherited all of them (measured: 129 variables in the child, 13 after). Two symptoms, one seam. **(#1378)** Inside the child, `build.config.sh`'s `: "${VAR:=default}"` idiom makes an already-set *env* value outrank every lower precedence layer, so `bin/subcommands/tests/test_config.sh`'s `machine-conf-set BUILD_MERGE_GATE_WINDOW` case resolved `layer=env` under `score.sh` and `layer=machine-conf` bare — every replay recorded `gate_result.passed=false` regardless of candidate quality, so a model that fixed its issue perfectly and one that changed nothing scored identically and the mechanical outcome scorer contributed zero discriminating signal. **(#1377)** The leaked set included `KNOWLEDGE_STORE_ROOT` pointing at the operator's real knowledge store; an explicit root overrides the sandboxed default-root seam that `test_install_lifecycle.sh` step 4b relies on, so that suite's `ks_sync init` leg `git init`-ed the live store. The gate is now invoked through `env -i` plus a named, reviewable allowlist (`PATH HOME USER LOGNAME SHELL TERM TMPDIR TZ`, locale, and the XDG roots) — the same shape `candidate-session.sh` already uses for its own child — so every `BUILD_*`/`PIPELINE_*`/`REPLAY_*` setting and `KNOWLEDGE_STORE_ROOT` are absent by construction rather than by denylist, and a setting added to `build.config.sh` later cannot re-open the leak. `score.sh` still reads `build.config.sh` for `REPLAY_SCORE_GATE_RELPATH` and `REPLAY_SCORE_GATE_TIMEOUT_SECS`; only what the child inherits changed. The new `test_score_gate_env.sh` gate pins both properties, supplying its own machine conf so the leak is armed identically on a laptop and on CI, and comparing `score.sh`'s verdict against the same gate entry point invoked bare.

- **The replay pre-flight now budgets BOTH comparison arms, and tests
  significance against planned PAIRS** (#1379, epic #1225 "model comparison
  harness"). `workflows/scripts/model-comparison/replay.sh preflight` had two
  unit errors that its existing fixture suite could not see, because every
  number was wired correctly to the wrong quantity. **(a)** The token estimate
  multiplied the per-replay figure by the planned *corpus record* count,
  budgeting a single arm for a comparison that executes every record in
  **both** the baseline and the candidate arm — so every batch was projected at
  exactly half its real cost, and a batch between 1x and 2x
  `REPLAY_PREFLIGHT_CEILING_TOKENS` cleared the spend gate. The estimate is now
  over `planned_records_n * arms_n` executed replays, and that two-arm figure
  is what the ceiling is compared against. **(b)** `significance_reachable`
  compared the whole corpus's eligible-record pool to
  `MODEL_COMPARISON_MIN_SAMPLE_N`, ignoring the batch cap that bounds what the
  invocation will actually replay — so a capped run that could only ever
  produce 10 paired outcomes reported a floor of 20 as reachable. It is now
  decided in **paired outcomes** (`planned_pairs_n`), the same unit
  `workflows/scripts/report-producers/model-comparison` feeds `stats.sh
  verdict --deltas`, and the MDE disclosure is taken at that same n rather than
  at the flattering larger one. The emitted JSON gains a `units` map plus
  `arms_n` / `planned_records_n` / `planned_replays_n` / `planned_pairs_n` /
  `eligible_pairs_n` / `mde_n`, so a reader can tell at a glance whether a
  number counts corpus records, executed replays, or paired outcomes — the
  ground truth being `1 corpus record -> 2 executed replays -> 1 paired
  outcome`. A non-integer value for any setting the estimate multiplies or
  compares is now `outcome:"CANNOT_EVALUATE"` and non-zero rather than a
  silently-zero estimate that would read as "evaluated, and under budget".
  `cost_basis`, `REPLAY_PREFLIGHT_TOKENS_PER_REPLAY` and the `SPEND_WEIGHT_*`
  weighting are deliberately untouched here — that seam is #1380. New gate
  `workflows/scripts/model-comparison/tests/test_replay_preflight_two_arm.sh`
  pins both defects end to end on the emitted JSON and exit code, each with a
  mutation proof.

- **The replay spend gate and the comparison report now speak ONE cost unit,
  and the per-replay constant is grounded in measurement** (#1380, epic #1225
  "model comparison harness"). `workflows/scripts/model-comparison/replay.sh
  preflight` reported `cost_basis: "token_count"` — a RAW token sum — while
  `workflows/scripts/report-producers/model-comparison` reported
  `cost_basis.unit: "token-counts"`, meaning cost-WEIGHTED units (the
  `SPEND_WEIGHT_*` multiply-add). Two non-comparable units sharing the word
  "token", so the batch cost an operator authorized at the gate could not be
  reconciled against the cost the report handed back: on the one observed live
  replay they differ by 5.4x (raw 2,506,371 vs cost-weighted 466,530). Both
  surfaces now emit the same string, `cost-weighted-token-units`, and the gate
  additionally publishes the `SPEND_WEIGHT_*` values that unit is defined by
  (weighted figures are comparable only within one weight-retune epoch).
  **Cost-weighted is the side converged on** because it is the unit that
  tracks spend — the dominant term in a real replay is `cache_read`, 2.38M of
  2.51M raw, which the default weights price at a tenth — and because the
  report is the artifact an operator ultimately reconciles against.
- `REPLAY_PREFLIGHT_TOKENS_PER_REPLAY` moves from a hand-set placeholder to
  the measured cost-weighted figure, rounded up to the nearest 10,000. Its
  **provenance is stated wherever it appears** — in `build.config.sh`, in the
  setting registry, and in a new `tokens_per_replay_basis` field the gate
  emits on every run: it is an ESTIMATE from a SINGLE observed live replay
  (n=1, the #1262 harness validation run), not a fitted average and not
  derived from the operator's own records, so one sample carries no variance
  and it deserves order-of-magnitude confidence only. The old value was 3.1x
  low in the weighted unit and 16.7x low against the same replay's raw total.
  `REPLAY_PREFLIGHT_ASSUMED_STDDEV_TOKENS` follows it into the same unit (a
  stddev denominated differently from the mean it varies around is the same
  collision in miniature).
- **`REPLAY_PREFLIGHT_CEILING_TOKENS` changed MEANING, not just value** — read
  the setting's comment before reusing an old number. It is now denominated in
  cost-weighted units and re-derived under the design rule its predecessor was
  written to ("a default-cap batch sits comfortably under it; raising
  `REPLAY_PREFLIGHT_BATCH_CAP` well past default is what trips it"), with the
  corrected two-arm arithmetic and the measured constant. At the observed
  token mix this is a real-terms LOOSENING of roughly 5.4x versus the old
  literal read as raw tokens. That is deliberate and stated rather than
  silent: the old value was never an external quota or an independent budget —
  it was itself derived from batch cap x a per-replay constant now known to be
  3.1x low — and holding its real-terms strictness would have put the ceiling
  below the cost of the smallest statistically meaningful comparison
  (`MODEL_COMPARISON_MIN_SAMPLE_N` paired outcomes), i.e. a gate that stops
  every batch it could ever be asked about.
- Pre-flight now **FAILS CLOSED on the weights that define its unit**
  (the #1365 class): missing or malformed `SPEND_WEIGHT_*` is
  `outcome:"CANNOT_EVALUATE"` and non-zero, with no estimate and no stop
  verdict emitted — the same refusal the report producer already makes on the
  same input, so the two surfaces fail together rather than one publishing a
  unit the other could not resolve. A negative weight is refused too, which a
  JSON-parse check alone would accept and apply silently.
- New gate `workflows/scripts/model-comparison/tests/test_replay_preflight_cost_unit.sh`
  is the first suite that runs BOTH surfaces and compares what they printed:
  it fails if the two emitted `cost_basis` strings ever diverge (the two files
  share no sourceable seam, so the shared string is a documented duplicate
  held honest mechanically rather than by review). It also pins that the
  shipped per-replay default sits at the measured cost-weighted figure and
  below the raw one — the interval that distinguishes the two units — that the
  estimate scales over executed replays in the declared unit, that the
  ceiling re-derivation is load-bearing (the pre-fix ceiling literal stops a
  floor-sized batch under the new constant, so a half-fix that raised only the
  constant is caught), and the fail-closed weights floor. Two mutation proofs
  against the live `replay.sh`. The #1379 two-arm budget and paired-outcome
  significance check are untouched and still pinned by their own suite.

### Added

- **A restricted candidate-session overlay + provider-key health check**
  for the model-comparison harness epic (#1225). New
  `workflows/scripts/model-comparison/candidate-session.sh` is a reusable
  preflight/resolve/spawn CLI: `preflight` fails loudly at pre-flight
  (never a silent no-op) when a non-default provider's API key is unset,
  naming the exact env var and the concrete host-supply file
  (`build.config.local.sh`); `spawn` hands the child an EXPLICITLY
  CONSTRUCTED environment — `env -i` plus a named allowlist plus exactly one
  provider key, the selected provider's — so no other provider key and no
  other host secret the config ladder exports reaches a candidate session.
  (`env VAR=value cmd` ADDS to the inherited environment rather than
  replacing it, so an allowlist is what actually isolates; the forwarded key
  is chosen from the one provider table, so registering a provider later
  cannot silently start leaking.) `candidate.settings.json` is a
  deny-over-allow containment overlay removing every knowledge-store/vault
  MCP tool and every path/command reaching `build.config.local.sh`, its
  `build.config.machine.sh` sibling and its `.env`-shaped siblings, while
  keeping the ordinary replay/worker surface reachable. Its deny patterns are
  plain `*<needle>*` substring globs, never `**/`-anchored: the matcher is a
  shell `case`, which has no globstar, so a `**/` pattern requires a literal
  `/` in the subject and silently fails to deny a bare filename.

  `spawn` also REFUSES a permission-overriding passthrough argument (a second
  `--settings`, an allow/deny-tools override, a permission-mode or
  skip-permissions switch, an extra `--add-dir`, an alternate MCP/setting-source
  config) rather than forwarding it into the child, where it would override
  the very overlay being installed.

  Both `resolve` and `spawn` fail CLOSED on an overlay they cannot read:
  distinct exits `3` (absent), `4` (unreadable) and `5` (malformed), never
  `unspecified` at exit `0` — "I could not determine the restriction" is never
  reported as "no restriction applies". A flag given with no value (a trailing
  `--provider`) is exit `2`, not a silent fallback to the default provider.
  Registers the `make test-candidate-session` gate
  (`scripts/quality-gates.sh`, `Makefile`,
  `workflows/scripts/config/gate-paths.tsv`) and the `CANDIDATE_SETTINGS` and
  `CANDIDATE_ENV_PASSTHROUGH_EXTRA` setting-registry rows, and adds the
  missing kernel classification for `workflows/scripts/model-comparison/*` in
  `kernel-manifest.txt`. Not breaking — a new opt-in module with no
  default-path behavior change (the module has no caller yet).
- **The model-comparison harness's per-seat attribution stream: record
  schema, emit script, and its content-level validator** (#1253, epic
  #1225, ADR 0026/0028). New `workflows/scripts/emit-model-usage.sh` appends
  one JSONL record per spawned pipeline seat — seat role name, model,
  provider, input/output/cache-read/cache-creation token counts, a
  cost-weighted total, duration, and an outcome ref — to
  `meta/data/raw/model-usage-<YYYY-MM>.jsonl` (monthly rotation,
  `schema_version` from day one, the raw untruncated session id as the join
  key), following the L0 usage-capture-feasibility spike's verdict
  (temperloop#1246): a `usage_source` discriminator (`cli-envelope` vs
  `unavailable`) is required because only 3 of 12 pipeline seats can see
  both a seat identity and a token count at spawn time today. ADR 0020's
  requestId dedup is documented N/A (the CLI envelope is already a
  per-run aggregate with no `requestId` field — the declared owner of that
  divergence); cache-class weighting IS genuinely inherited, sourced from
  the existing `SPEND_WEIGHT_*` settings in `build.config.sh` rather than a
  second hardcoded copy. Per ADR 0028, the record carries no `host` field
  and no other cross-repo operator identifier, unlike every sibling
  raw-lake stream. New `workflows/scripts/validate-model-usage-emit.sh`
  schema-validates records at CONTENT level, not merely presence: a
  fixture record with valid shape but an out-of-enum `provider` (checked
  against the ADR 0028 committed allowlist via `allowlist.sh`'s
  `pa_is_allowed`, composed rather than re-parsed) or an unrecognized
  `model` family FAILS. JSON is parsed with a STRICT python3 parser (a
  `parse_constant` hook that rejects `NaN`/`Infinity`) rather than `jq -e .`,
  which silently coerces non-finite constants to `null` — demonstrated
  directly in the new test suite,
  `workflows/scripts/tests/test_model_usage_emit.sh`, which also includes a
  tamper-and-restore mutation test for every enforcement mechanism (the
  presence-lint, the strict-parse rejection, the model/provider enums, the
  no-host check, and the SPEND_WEIGHT_* inheritance). GATE SCOPE: this item
  ships the emit/validate pair and schema only — wiring the three
  emit-feasible seats (the pipeline-drive safe/merge drivers and the retro
  judge) is the later attribution-spawn-site-wiring item (temperloop#1255),
  so an absent/empty stream is legal here. Registers the
  `MODEL_USAGE_RAW_DIR` setting-registry row, two `scripts/quality-gates.sh`
  KERNEL_GATES entries, their `workflows/scripts/config/gate-paths.tsv`
  rows, two `workflows/scripts/kernel/kernel-manifest.txt` kernel rows, and
  documents the new stream in `docs/features/telemetry.md`. Not breaking —
  a new stream with no existing reader and no spawn site calling it yet.

## [0.28.0] - 2026-08-05 — BREAKING

### Migration — read this first

Two migrations, and one of them will break a consuming profile on the next
command if it is skipped.

**1. Delete any `board-adapter-guard.sh` registration from your
`settings.json`.** The hook is removed with the Projects-v2 arm it guarded. A
`PreToolUse` entry pointing at a missing script is a **per-command error**, so
this is not optional cleanup — grep your installed profile for
`board-adapter-guard` and remove the block. Nothing replaces it: with no
Projects arm there is no `gh project` call to intercept and no shared GraphQL
budget to protect.

**2. Stop calling the removed Projects-v2 adapter functions.** `lib/board.sh`
now speaks exactly one backend — issues-only, over REST — and
`board_project_number`, `board_field_id`, `board_option_id`, the
`_board_cached_read` family and the budget guard are gone. If your overlay
calls any of them directly, it must adapt. Every registered board has run
issues-only since 2026-07-18, so no tracking behaviour changes; only the
adapter's surface shrinks.

**Who does NOT have to act:** a consumer that only ever went through the public
`board_resolve_item` / `board_item_list` / `board_set_*` / board-command surface
and does not register the hook. That path is unchanged.

**Also in this release, and worth pulling for on its own:** a correctness fix to
the cached relationship reads (#1163). If you run with `board.<N>.cache=on`,
the pre-0.28.0 cached arm returned "no children" for **every** issue, which
`board-mirror.sh` reads as "epic fully drained" — it was armed to close epics
that still had open children. See the `### Fixed` entry below.

### Fixed

- **Relationship reads are live-only again; the cached arm was silently
  returning "no children" for every issue** (#1163). `board_sub_issues` /
  `board_parent_issue` gained a cached arm in #1030 on the premise — asserted in
  board.sh's own comment and in #1023's acceptance as "verified live" — that the
  bulk issues-list payload carries the parent link as a nested `.parent.number`.
  **It does not.** The bulk list carries `sub_issues_summary` (counts only);
  `parent_issue_url` comes from the *single-issue* endpoint. Measured against
  real stores: **0 of 911** rows in one repo's snapshot and **0 of 611** in
  another's carry any `parent` key. The arm read a field that was never there
  and returned empty, silently.

  **Why this mattered:** `build/board-mirror.sh` counts
  `board_sub_issues <b> <epic> open | wc -l` and treats **0 as "epic fully
  drained"**, closing the epic. Once board-mirror.sh began sourcing `cache.sh`
  (#1118) and the enable axis was switched on, that path was armed to close
  epics with open children — verified on a real open epic (live = 1 open child,
  cached = 0). Both accessors now always take the live path, like
  `board_blocked_by_open`.

  Its suite is why this survived: the fixture hand-wrote `"parent":{"number":300}`
  into snapshot rows, so it was strictly more capable than reality and green-lit
  a path production could never take. `test_relationship_cache.sh` is rebuilt
  around the **real** payload shape and carries a regression guard that fails
  against the old arm and passes against the fix.

  This is recoverable at zero API cost — `cache_refresh_details` already fetches
  the payload carrying `parent_issue_url` and discards it (#1165).

### Changed

- **A cached read no longer parses the whole snapshot just to validate it**
  (#1163). `cache_read`'s freshness guard ran `jq . "$snapshot"` — a full parse
  of a 3.7–5.1MB file whose result was **discarded** — on every read, before
  `cat` read the file again and the caller parsed it a third time. It now checks
  only the last line, which is the guard that matches the real failure mode
  (`_cache_persist_snapshot` writes to a temp file and `mv`s it into place, so
  partial content can only appear at the end). Measured on `board_item_list`
  p50: **452ms → 313ms** and **336ms → 214ms** on two real boards, ~1.5x.

### Removed — BREAKING

- **BREAKING — the Projects-v2/GraphQL arm is removed from the board adapter**
  (ADR 0004, epic #524). `lib/board.sh` now speaks exactly one tracking
  backend: issues-only, over REST. The tracking flow issues **no GraphQL call**
  and depends on no paid or org-level GitHub feature — a free account and a
  repo are sufficient.

  Gone from the adapter: every `gh project` argv and the single-item
  `gh api graphql` resolve; the 5,000-pt/hr GraphQL budget guard
  (`_board_budget_guard`); the whole cross-process structure/state read cache
  (`_board_cached_read`, `_board_cache_file`, `_board_cache_bust`,
  `_board_cache_patch_*`, `_board_file_age`, `_board_item_list_argv`,
  `_board_item_list_fresh`, `_board_drop_pr_cards`); and the public functions
  `board_project_number`, `board_field_id`, `board_option_id`,
  `board_add_to_board`, `board_bust_structure`. Settings `BOARD_CACHE_TTL`,
  `BOARD_STRUCTURE_TTL`, `BOARD_CACHE_DIR`, `BOARD_ITEM_QUERY`,
  `BOARD_BUDGET_GUARD`, `BOARD_BUDGET_GUARD_THRESHOLD`,
  `BOARD_CREATE_BUDGET_GUARD`, and `BOARD_CREATE_INDEX_RETRIES` left the
  setting registry with them.

  **Every surviving public accessor keeps its issues-only behavior
  byte-identical** — each function's Projects half sat behind an
  `_board_is_issues_only` early return, so this deletes tails rather than
  restructuring the live path. `BOARD_PROJECT_ID` and `BOARD_FIELDS_JSON` are
  now vestigial but are still set to their documented empty values (`""` and
  `{"fields":[]}`), so a caller reading them under `set -u` is unaffected.
  Item ids are `ISSUE_<n>`; a `PVTI_*` id is now rejected loud.

  **Soak evidence.** ADR 0004 required "at least one release of soak" between
  deprecating the Projects-v2 arm and removing it
  (`docs/adr/0004-issues-only-default-backend.md` § Decision). The arm was
  deprecated in **v0.15.0** (2026-07-23); all five registered boards — the
  four fleet repos (ssmobile, stageFind, subsetwiki, foundation) plus the
  kernel's own tracker (board 7) — have run issues-only since **2026-07-18**.
  **Ten releases** (v0.16.0 through v0.25.0) shipped between the deprecation
  and the v0.26.0 removal that actually deleted the Projects-v2 code path —
  ten times the one-release bar, with zero live Projects users observed
  during that window.

  **Migration — read this before pulling.** There is **no configuration path
  back** to Projects-v2; an adopter who wants it forks `board.sh`. A
  `boards.conf` line reading `board.<N>.backend=projects` **hard-fails** with a
  one-line error citing ADR 0004 — deliberately, rather than silently resolving
  to `issues`: a backend that changes under you with nothing telling you is the
  exact failure temperloop#908 recorded. If any board is still on the
  Projects arm, **check out v0.25.0 and run its
  `workflows/scripts/board/migrate-board-to-issues.sh` first** — v0.25.0 is the
  last release carrying that script, which was deleted in v0.26.0 per ADR
  0004's ordering pin — then delete the `backend=projects` line and pull. The `backend` axis otherwise remains
  accepted and inert; a stale `project=` axis is simply no longer read.

  This also lands the supersession ADR 0005 § Decision and § Consequences
  documented in advance: the built-in map's **additive-only** rule, and the
  "board 7 is the sole in-code issues-only exception" language, are retired
  here explicitly. Board 7 is no longer an exception to anything.

### Fixed

- **The nested retro-judge spawn carries its own credential instead of
  inheriting one it never gets** (temperloop#1148). Phase R's judge was spawned
  two levels deep — `pipeline-cron.sh` → the headless 5b driver → `claude -p
  "/retro --pending"` — and a Claude Code session does not forward credential
  environment to a child it launches from its Bash tool. On a headless host with
  an expired interactive OAuth session, hop one authenticated and did real work
  while hop two died before turn 1, visible only as a `safe_failed` counter.
  The 5b driver no longer types that command: each `retro-judge` action now
  carries an absolute `spawn_cmd` naming the new
  `workflows/scripts/build/pipeline-retro-judge-spawn.sh`, which sources the
  checkout's own config ladder (`build.config.sh` → the gitignored, mode-600
  `build.config.local.sh`) to **re-derive** the credential at the process that
  actually invokes `claude -p` — the same move `tidy-nightly.sh` already makes
  before its own nested invocation. A `claude -p` typed by hand in that session
  is now a hard-rule violation in the payload and in `pipeline-drive.md`.

  An auth failure there is **loud**, not a counter: classified by *shape* rather
  than exit code (a failed nested session can still exit `0`), pushed through the
  `PIPELINE_NOTIFY_CMD`/`osascript` channel `pipeline-cron.sh` already uses,
  echoed to stderr for the cron log, and returned as a distinct exit code (`3`
  auth-failed, `4` spawn-failed). The credential's **value** is never placed on an
  argv, printed, or logged — only presence and a source label are reported, and
  the wrapper redacts any credential value out of its child's pass-through
  output.

- **The retro-judge seam refuses legibly instead of exiting success having
  judged nothing** (temperloop#1150). The funnel tick's Phase R gated its nested
  `claude -p "/retro --pending"` spawn on command *presence* alone, so a host
  with `/retro` installed but no working headless mode spawned a judge that could
  not run: the nested session ended its turn and exited `subtype: success` /
  `is_error: false` having produced zero judgments and zero run-stream rows.
  Phase R now also requires the judge to **declare** the capability it is being
  driven under, and emits a reason-bearing `skip-retro-judge`
  (`reason: "headless-unsupported"`, remedy on the line) instead of spawning when
  it has not. Never silence: either the judge runs, or the tick says why it
  didn't. See the amendment in
  `docs/adr/0007-retrospection-mint-then-judge.md`.

### Added

- `command_declared_capability <name> <capability>` in
  `workflows/scripts/lib/command_declared.sh` — the capability companion to the
  ADR 0008 presence probe. Answers from a `capability:` marker line, alone on its
  line, in the first-resolved command file; fail-closed everywhere (no marker, no
  file, no answer ⇒ false), with a `COMMAND_CAPABILITY_OVERRIDE` fixture seam.
  Presence is discovered; capability is declared.
- `workflows/scripts/build/pipeline-retro-health.sh` — a read-only,
  always-exit-0 detector that separates the readings a zero-row `retro-runs`
  stream used to collapse into one: `no-signal` (nothing was due — the genuine
  steady state), `refused` (the tick declined, and why), `healthy`, and `defect`
  (a trigger fired and produced nothing, sub-typed `never-had-a-row` vs
  `stalled`), plus `no-lake` when the trigger history is unreadable. `/tidy`'s
  Retro mint backstop gains a fourth probe that runs it and files a `defect`
  verdict as a board defect.

### Changed

- `pipeline-retro-health.sh` gains an `auth_failures` count and a
  `defect_kind: "auth"` verdict that outranks `never-had-a-row`/`stalled`
  (temperloop#1148) — read from the stable `retro-judge-auth-failed` token the
  spawn wrapper emits into the drive record, so a credential problem is the
  durable, `/tidy`-visible half of the loud signal and is never re-diagnosed as
  a broken judge. The detail line names the remedy.

- `skip-retro-judge` tick actions now carry a machine-readable `reason` field
  (`not-declared` | `headless-unsupported`). A reader matching on the action name
  alone is unaffected.

- **The CHANGELOG gate now enforces SECTION SCOPE, not just completeness**
  (temperloop#1151). `workflows/scripts/check-changelog-entry.sh` fails a change
  that adds lines to — or removes lines from — a CHANGELOG section that was
  **already released at its merge base**, in both directions: an unmerged PR's
  entry drifting *into* a released section when a release is cut underneath it
  (temperloop#1138), and a released section *losing* an entry that legitimately
  shipped in it (the temperloop#1125 over-correction, the same class as
  temperloop#1143's four unrecorded PRs). The discriminator is the **base ref**:
  a version heading that did not exist at the merge base is one this change is
  *creating*, so a release cut — which looks identical at head — passes
  unmodified. The check runs whenever CHANGELOG.md is in the diff, independent
  of whether contract surface was touched. Deliberate amendment of a shipped
  release stays possible through a **sibling verb in the existing marker
  grammar** — `Changelog: amend — <reason>`, honored in the same three channels
  (the new `changelog-amend` PR label, a PR-body line, or a commit trailer) with
  the same reason requirement. The `none`/`skip` verb is unchanged and does not
  waive section scope. New setting: `CHANGELOG_GATE_AMEND_LABEL`.

- **BREAKING — `claude/hooks/board-adapter-guard.sh` is removed**, together with
  every kernel-plane rule that taught the two-backend model (epic #524). The
  hook existed to prompt on a direct `gh project` / Projects GraphQL call and
  protect the shared 5,000-pt/hr budget; with the Projects arm gone there is no
  such call to intercept and no such budget to protect. An installed profile
  that registers this hook by path in its `settings.json` must **delete that
  registration** — a `PreToolUse` entry pointing at a missing script is a
  per-command error. `EVAL_DENIAL_LOG` (its eval-mode denial log) leaves the
  setting registry; `EVAL_RUN` survives, now owned by
  `claude/hooks/eval-guard.sh`, and still self-suppresses every side-channel
  hook.

  **The adapter discipline itself is unchanged and still load-bearing.**
  `claude/CLAUDE.kernel.md` § "GitHub Projects boards — always via the board.sh
  adapter" is renamed to § "**Board reads and writes — always via the board.sh
  adapter**" and rewritten for one backend, keeping the rule and restating its
  rationale: the adapter owns the `fnd:` label encoding (a hand-rolled
  `gh issue close` leaves a stale `fnd:status:*` label and claim stamp behind)
  and the cross-process item cache. What went with the arm: the GraphQL-budget
  clause, the `board_bust_structure`-after-a-structural-edit rule, the
  structure/state cache-split paragraph, the guard-hook sentence, and the board
  glossary's org-project-URL column plus its "board ids and URL numbers are
  swapped for 3 and 4" warning.

  **Two corrected instructions, not just prose tidying.** § "Board hygiene is
  part of the gate" and `/build` 4d/4e + `/fix` no longer describe a
  backend-conditional Done write: **nothing moves an item to Done on its own**,
  so the explicit `board_set_status … Done` is the primary mechanism on every
  board. `/build`'s epic-close step previously said to *skip* that write and
  rely on the close→Done cascade — on the surviving backend that left the epic
  wearing its status label, so it now issues the write. Likewise the
  `project` gh scope is **never** checked (`/build` Step 0, `/triage` Step 0.2):
  the default `repo` scope runs everything, and requiring `project` would halt
  an otherwise-valid run. `Seq` writes are unconditionally skipped rather than
  guarded on a backend probe that can now only answer one way (ADR 0006).
  `board_set_status` takes an `ISSUE_*` item id, not `PVTI_*`.

### Changed

- **The stranger-facing docs plane now teaches one backend** (epic #524).
  `README.md`, `AGENTS.md`, `docs/architecture.md`, and the affected feature
  docs no longer present Projects-v2 as an available backend or the
  5,000-pt/hr GraphQL budget as a constraint a reader plans around.
  `docs/features/board-adapter.md` is rewritten for a single backend — its
  GraphQL-budget, structure/state cache-split, and dual-arm sections are
  removed rather than hedged — and now states plainly that board reads are
  live REST calls sharing one budget with CI polling and issue/PR porcelain.
  `docs/features/gh-perf.md`, `build-machinery.md`, `merge-gate.md`,
  `branch-hygiene.md`, `managed-merge-queue.md`, and `docs/principles.md`
  are retargeted onto that merged-budget framing, whose consequence — no
  second bucket left to route a noisy caller onto — is the subject of
  `docs/failure-modes/02-rest-budget-exhaustion.md`.

### Removed

- **`docs/features/install-cli.md` § "Manual Projects-v2 recipe" is deleted.**
  It walked an adopter through `gh project create` plus a hand-written
  `boards.conf` entry — a path that now reaches no code, since the adapter has
  no Projects arm to read it. The surrounding § Tracker mode states plainly
  that after this release there is **no configuration path back to
  Projects-v2** and that an adopter who wants it forks `board.sh`, and carries
  the v0.25.0 migration pointer. `bin/subcommands/init.sh`'s `--tracker-mode`
  and `--provision-*` rejection messages (and `bin/README.md`'s compat note)
  are repointed at that statement rather than the deleted recipe, so no
  user-visible error text names a section that no longer exists.

## [0.27.0] - 2026-08-05 — BREAKING

### Migration — read this first

One migration, and it is narrow: **`temperloop init` no longer accepts the
`--provision-*` flag family or `--tracker-mode`** — passing either now exits 2
instead of being silently ignored. This finishes the epic #524 arc v0.26.0
opened (ADR 0004, `docs/adr/0004-issues-only-default-backend.md`); the backend
itself did not move again in this release.

**Who has to act.** Only an adopter whose wrapper script, Makefile, or CI job
still passes `--provision-board`, `--provision-labels`, any other
`--provision-*`, or `--tracker-mode` to `temperloop init`. On v0.26.0 those
flags parsed and were discarded, so such a caller is green today and will exit
2 after pulling. **The fix is deletion — drop the flag from the invocation.**
There is no replacement flag and no behavior to preserve: every registered board
has run issues-only since 2026-07-18, so there has been nothing to select or
provision for some time. `grep -rn -- '--provision\|--tracker-mode'` over your
own scripts is the whole audit.

Nothing else in this release moves an adopter-facing contract. The rest is two
gate fixes that make a **vendoring consumer's** `make quality-gates` pass where
it previously could not — strictly a loosening, and the kernel's own checkout is
byte-for-byte unchanged by both.

### Fixed

- **`check-gate-paths.sh` no longer fails a vendoring consumer for being one**
  (#1144). The gate already detected a composed tree (repo-root `.kernel-pin`)
  and its checks 2/3 reported a legible `[skip]` for rows naming gates such a
  tree legitimately lacks — but **check 4 (reachability) honored neither the
  exemption nor the vendored layout**, so it hard-failed the very rows check 3
  had just skipped, and judged every kernel-authored path missing because in a
  consumer it is tracked under the subtree prefix. In foundation's tree that was
  **108 failures** (`VERSION`, `VERSIONING.md`, `AGENTS.md`, `make test-try`, …),
  and the remediation line told the consumer to edit a `gate-paths.tsv` that is a
  symlink to the kernel's own. Check 4 now (a) skips a row whose gate is absent
  from the composed tree, using the same predicate check 3 uses, and (b) resolves
  a row against `<prefix><path>` as well as `<path>`, where the prefix is the new
  `GATE_PATHS_KERNEL_PREFIX` seam (default `kernel/`). **Not a blanket consumer
  bypass:** a row whose gate *is* present in the tree keeps full literal-path and
  reachability checking, and the kernel's own checkout is byte-for-byte
  unchanged — both pinned by fixture cases.

- **`test_quality_gates_parallel.sh` no longer asserts the kernel's CI shape
  against a consumer's** (#1144). Its required-status-context check encoded the
  kernel's own single-entry matrix (`checks (ubuntu-latest)`); a consumer whose
  contract is a single non-matrix job named `checks` could never satisfy it. The
  assertion is now scoped to the kernel's own checkout and reports a `SKIP:` line
  in a consumer. Every other check in that section is a shared invariant and
  still runs everywhere.

### Removed — BREAKING

- **`init.sh --provision-*` (the whole board-provisioning flag family) and
  `--tracker-mode` are gone; both now exit non-zero** (ADR 0004, epic #524
  "retire the Projects-v2/GraphQL arm"). Every registered board has run
  issues-only since 2026-07-18, so there is nothing left to select or
  provision — a caller passing either flag now hits a dedicated case arm
  that names the removal release and exits 2, rather than the flag being
  silently accepted and ignored. No replacement flag: an adopter's script
  simply drops `--provision-*`/`--tracker-mode` from its `init` invocation.

## [0.26.0] - 2026-08-05 — BREAKING

### Migration — read this first

This release removes the Projects-v2/GraphQL board-adapter arm (epic #524,
"Remove the Projects-v2/GraphQL arm (BREAKING) — post-soak follow-on to epic
#460"; ADR 0004, `docs/adr/0004-issues-only-default-backend.md`). **Migration
to the issues-only backend must be completed on v0.25.0 or earlier.**
`migrate-board-to-issues.sh`, the dry-run-first Projects→issues migration
script, is deleted in this release (see `### Removed — BREAKING` below) —
past this point there is no script left in the tree to run it with. If you
have not already migrated a `backend=projects` board, check out v0.25.0 (or
earlier), run the script from there, then upgrade.

**Who has to act.** Only an adopter still running `backend=projects` on any
board. Nobody this repo's own maintainers govern is affected: all five
registered boards have run issues-only since 2026-07-18, the soak window ADR
0004 required before this removal. For an issues-only adopter this release
changes nothing observable — `lib/board.sh`, the board adapter interface,
hook names and signatures, and the `checks` gate contract are all untouched.
The one other adopter-facing consequence is `### Changed — BREAKING` below:
every backend-conditional branch in the board/build caller scripts is gone,
so a `backend=projects` board is no longer served the code path it used to
take through `claim.sh`, `reconcile.sh`, or `release.sh`.

### Added

- **`board_sub_issues` takes an optional state filter (temperloop#1119).**
  `board_sub_issues <board> <issue#> [all|open|closed]` — the third arg is new
  and **defaults to `all`, so every existing two-arg call is byte-identical**.
  Not breaking; no overlay has to adapt. It exists because the epic-close
  "how many children are still open?" count is a relationship read like any
  other, and without a state filter its only options were the raw REST
  endpoint — which bypasses the cached arm entirely — or one state lookup per
  child, which is N extra calls to answer what a single snapshot pass already
  knows. Both the cached and live arms apply the filter, so they stay
  byte-parity under every state value; a warm-only filter would have
  miscounted whenever the store was cold, and an epic-close miscount either
  strands an epic open forever or closes it with children still open.

- **`ks_search` can be scoped to a project partition, and the single-tenancy
  limitation is now documented for the stranger (temperloop#418).** The
  knowledge store is one flat corpus per `$HOME`; its only separation between
  projects is the `<project> - <title>.md` **filename convention**, and search
  did not respect it. For an operator running one machine account across
  several engagements that was a structural confidentiality hole: a query
  typed during client B's session could rank and return client A's
  confidential notes. Two halves land together.
  **(1) The capability.** `ks_search <query> [--limit N] [--partition <name>]`,
  plus a standing `KNOWLEDGE_SEARCH_PARTITION` setting (empty by default) for
  the route a multi-engagement operator actually uses — export once per
  engagement and every call in that session is scoped. A result is returned
  only if its `doc_id` **proves** membership: its basename starts with
  `<name> - `, or the `doc_id` starts with `<name>/`. Matching is exact and
  case-sensitive, and a document matching neither form is **excluded** — a
  confidentiality filter must not return what it cannot attribute.
  **(2) The documentation.** `docs/features/knowledge-store.md` gains a
  stranger-facing **§ Limitations — read this if you work across more than one
  client** naming the exposure in plain terms and both ways to handle it
  (separate `$HOME`s = the only hard boundary; partition-scoped search = the
  convenient one), and `docs/who-its-for.md` points the consultant persona it
  already names at that section.
  **Fail-closed is the load-bearing property**, and it is why this is not
  simply a new flag. The pre-existing argument loops ended in `*) shift ;;` —
  they silently discarded what they did not recognise. Under a *scope* flag
  that is not a degraded result but the exact bleed this closes, delivered
  under a flag that looked like it worked: the full unfiltered corpus, at exit
  0, to a caller that believes it asked for a scoped search. So: `ks_search`
  now parses its **own** arguments against an allowlist and rejects anything
  else with **exit 2** before any backend call (the same shape
  `ks_search_reindex` adopted in temperloop#888); an **empty** `--partition`
  value is rejected rather than read as "no partition"; the scope is
  **consumed at the `ks_search` seam and never forwarded**, so enforcement
  cannot depend on a backend honouring it (both shipped backends now *reject*
  the flag rather than ignore it); the degraded **ripgrep lexical fallback**
  runs through the same single filter point; a filter that cannot run returns
  nothing and **exit 4**, never the unfiltered stream; and
  `ks_search_partition_supported` exists purely so a caller can
  `declare -F`-probe a pre-#418 library — the one skew this file cannot close
  from the inside.
  **Scope, stated plainly rather than half-built:** this is a **search-layer
  filter, not a store-layer partition**. `ks_read` / `ks_write` / `ks_list` /
  `ks_sync` remain unpartitioned — a true multi-tenant store would have to
  reach the doc-id normalizer, every backend in the matrix, and the sync
  capability. It reduces *accidental* exposure through search, the dominant
  and hard-to-avoid failure; it is **not** at-rest isolation, and both the
  contract and the feature doc say so.
  **Classified ADDITIVE (minor), not BREAKING — the argument, explicitly.**
  The documented signature grows an optional flag; every call conforming to
  the previous documented surface (`ks_search <query> [--limit N]`) is
  byte-identical, and with no partition configured — the dominant
  single-tenant case — the whole pipeline including the fallback's trigger
  condition is unchanged (pinned by a no-regression case in the suite). The
  new `KNOWLEDGE_SEARCH_PARTITION` row is a **new setting name no reader
  already depended on**, which `VERSIONING.md` § Setting registry classifies
  as additive. The one genuine behaviour change is that an argument
  `ks_search` never documented now errors instead of being silently dropped —
  the identical judgement temperloop#888 made for `ks_search_reindex` and
  shipped the same way: no overlay using the documented surface must adapt,
  and the prior behaviour on that input was not a contract but an unsafe
  silent discard. No `BREAKING` marker, no migration note owed. Documented in
  `workflows/scripts/lib/knowledge_store.contract.md` § Project partition —
  scoped search; covered by ten new cases in
  `workflows/scripts/lib/tests/test_knowledge_search.sh`, led by a positive
  behavioural sentinel that seeds two partitions and asserts the other
  partition's note is **absent** (a no-op filter fails it).
- **Knowledge-store maintenance scans in the vault-hygiene probe, and a
  grounding-citation backstop anchor in `/tidy` Step 3 (foundation#1479,
  foundation#1478).** `vault_hygiene_report.sh` gains two propose-only
  checks. **`duplicate-overlap`** flags pairs of notes across
  `Decisions/`/`Patterns/`/`Mistakes/`/`Context/` whose titles share
  `DUP_OVERLAP_MIN`+ distinct terms — two pages on one concept that should
  merge or cross-link. It reuses the tokenizer and distinct-token counter
  `check_repeat_mistake` already ships rather than adding a similarity
  engine, and builds an inverted token→notes index instead of comparing note
  pairs, so it does not reintroduce the O(n²) whole-vault cost removed in
  foundation#1202; non-discriminative terms are skipped and the listed pairs
  are capped with an explicit "N not shown" line. **`orphan-note`** reports
  notes with no inbound wikilink anywhere in the store and no `Index.md`
  entry — **informational, never an alarm**, which is a measured choice: 560
  of 744 notes (75%) on the reference vault have no inbound link, so a
  per-note alarm would flag three quarters of the corpus nightly and bury the
  checks that do alarm, making the rate rather than the list the signal. The
  whole-vault walk and backlink index are now **memoized** (`_hyg_all_files`
  / `_hyg_link_index`) and shared by the heat score, orphan scan, and
  duplicate scan, so the two new checks cost no material runtime (measured
  119s vs 121s). `/tidy` Step 3 documents both under § Vault hygiene — and
  records that the third drift class, cross-note contradictions, is
  deliberately **not** rebuilt because § Contradiction detection already
  covers it — and gains a § Missing grounding citations section, the backstop
  anchor an overlay's response-level citation rule registers against. **Not
  breaking:** both checks are additive and propose-only, no existing finding
  changes shape, and a checkout with no vault still no-ops.

- **`ks_search_reindex` forwards `--search` / `--embeddings` to the backend,
  and rejects an unrecognised flag instead of swallowing it
  (temperloop#888).** The reindex seam parsed only `--full` and *silently
  shifted every other argument away*, so the one shape a drift-healing
  scheduled reindex actually wants — `basic-memory reindex --full --search`,
  a full filesystem rescan plus FTS rebuild that reconciles the entity table
  (re-paths moves, drops deletions) **without** the forced full re-embed —
  was unreachable through the public seam. Measured on a 977-note live store
  (foundation#1425, 2026-07-28): `--full --search` = **61s**, bare `--full` =
  **587s**. A caller needing the cheap shape had to reach into the
  library-**private** `_ks_bm_run` behind a `declare -F` probe; it can now
  drop the probe and call `ks_search_reindex --full --search`. Two more
  consequences: the flags are an explicit **allowlist** forwarded by name (not
  a blanket `"$@"`), emitted in a normalized order so the command line is the
  same whichever order the caller passed them; and an **unrecognised**
  argument is now an error — exit 2, the contract's invalid-usage code, with
  the offending argument named on stderr and no backend call made at all —
  where before a mistyped `--full --serch` silently degraded to bare `--full`,
  the 587s forced re-embed instead of the 61s shape the caller asked for, with
  no warning. **No behavior change for existing callers:** a bare
  `ks_search_reindex` and a bare `ks_search_reindex --full` emit exactly the
  command lines they did before. Documented in
  `workflows/scripts/lib/knowledge_store.contract.md` § `ks_search_reindex`
  flags; covered by four new cases in
  `workflows/scripts/lib/tests/test_knowledge_search.sh`.

### Changed — BREAKING

<!-- The `BREAKING` token appears on the `## [0.26.0]` heading above AND on
     this `### Changed` sub-heading, matching the belt-and-suspenders
     convention every other BREAKING release in this file follows.
     `changelog_breaking_sections()` (workflows/scripts/lib/changelog.sh)
     sets its `brk` flag ONLY from a heading line: `$0 ~ /BREAKING/` on the
     `## [x.y.z]` line, or `/^#+ .*BREAKING/` on a sub-heading. BODY TEXT
     NEVER SETS IT. Do not strip either marker when editing history. -->

- **BREAKING — every backend-conditional branch in the board/build caller
  scripts collapses to the issues-only path, and the budget-instrumentation
  probe retargets from GraphQL to REST (temperloop#1121, temperloop#1122;
  epic #524, ADR 0004).** `claim.sh`'s field-resolution pre-check,
  `reconcile.sh`'s conditional field-list widening, closed-issue tail scan,
  and label-hygiene early return, and `release.sh`'s claim-stamp clear guard
  no longer branch on the board's configured backend — each now takes the
  issues-only path unconditionally. The other eight in-scope callers
  (`capture.sh`, `milestone.sh`, `pr-enqueue.sh`, `worklist.sh`,
  `board-mirror.sh`, `ci-poll.sh`, `gate.sh`, `unclaim.sh`) already carried no
  such branch. `gh-bench.sh` and `gh-call-logger.sh`'s header/output framing
  moves from GraphQL-budget to REST/core-budget (the GraphQL figure is kept,
  now informational only), and
  `docs/failure-modes/02-graphql-budget-exhaustion.md` is rewritten and
  renamed to `02-rest-budget-exhaustion.md`. **No observable change on an
  issues-only board** — the collapsed branch was reachable only under
  `backend=projects`, and no registered board runs that: all five have run
  issues-only since 2026-07-18, the soak window ADR 0004 required before this
  removal. **BREAKING for a `backend=projects` adopter:** the code path these
  callers used to take for that backend is gone outright, not merely
  deprioritized. `lib/board.sh` itself is untouched — its Projects-only
  functions (`board_field_id`, `board_option_id`, `board_project_number`,
  `board_add_to_board`) still exist, they are simply no longer reached from
  any of these callers.

### Changed

- **Sub-issue reads in `board-mirror.sh` route through the board adapter
  instead of the raw REST endpoint (temperloop#1119).** temperloop#1030 gave
  `board_sub_issues` / `board_parent_issue` a cached arm, justified by the
  F#988 baseline's heaviest measured read class (the per-issue relationship
  fan-out: 4.1s p50, 12.6s total, against ~500ms for `resolve_item`). Nothing
  in production called them — `board-mirror.sh` read `repos/…/issues/N/sub_issues`
  directly, so the cached arm was exercised only by `gh-bench.sh`, the tool that
  measures it. The epic's largest justified win was unreachable in the running
  system. `_subissue_children` / `_subissue_open_children` now delegate to
  `board_sub_issues` and take a board id rather than a repo (both call sites
  already had one in scope). **The POST link path is deliberately untouched** —
  it is a mutation, not a read, and the adapter exposes no cached arm for it.
  `board-mirror.sh` also gains the `lib/cache.sh` source line: temperloop#1118
  excluded it on the reasoning that it called only the always-live
  `board_resolve_item`, which this change invalidates. Not breaking.

- **The README and the remaining docs surfaces carry the sandbox on-ramp
  (temperloop#1115, temperloop#1133).** `README.md`'s `try` / `--demo` on-ramp
  is replaced by a sandbox + first-epic walk, and that framing is propagated
  across `AGENTS.md`, `bin/README.md`, `docs/pitch.md`,
  `docs/cost-and-autonomy.md`, `docs/features/install-cli.md`, and
  `docs/features/ci-install-tier2.md` so a stranger meets one on-ramp rather
  than two competing ones. Docs only; no contract surface.

### Removed — BREAKING

<!-- The `BREAKING` token appears on the `## [0.26.0]` heading above AND on
     this `### Removed` sub-heading — see the comment on `### Changed —
     BREAKING` above for why both are load-bearing for
     `changelog_breaking_sections()`. Do not strip either one when editing
     history. -->

- **BREAKING — `migrate-board-to-issues.sh` and its fixture-replay test are
  deleted (temperloop#1123; epic #524, ADR 0004).** The dry-run-first
  Projects→issues migration script introduced in v0.14.0 (see that section's
  `### Added`) is gone, along with
  `workflows/scripts/board/tests/test_migrate_board_to_issues.sh`. ADR 0004
  required at least one release of soak between deprecating the Projects-v2
  arm and deleting the tooling that migrates off it; that window closed with
  ten releases behind it and zero live Projects users — every registered
  board has run issues-only since 2026-07-18. **Migration:** complete any
  outstanding Projects→issues migration on **v0.25.0 or earlier** — check out
  that tag (or an earlier one) and run the script from there. Past this
  release there is no script left in the tree to run it with; see
  `### Migration — read this first` above.

### Fixed

- **The issue read cache was unreachable from every board command
  (temperloop#1118).** `board.sh`'s cached read arms gate on
  `declare -F cache_read`, and `board.sh` never sources `cache.sh` itself — a
  deliberate one-way layering that is what keeps `reconcile.sh` permanently on
  the live arm. The consequence went unnoticed for weeks: **no production
  command sourced it**, so `board.<N>.cache=on` was inert everywhere. The axis
  could be turned on and every read would still take the live path, emitting
  one "cache.sh is not sourced" notice per call. `worklist.sh` and
  `pipeline-tick.sh` — the only two real callers of a cache-aware whole-board
  read arm — now source it, guarded on file existence so a consuming repo that
  vendors a subset still runs unchanged. `reconcile.sh` is deliberately still
  **not** wired (a drift detector fed cached data is self-defeating), asserted
  by a negative test. No behavior change with the axis off.
  The accompanying test is the point: the gap survived because the existing
  suite sourced `cache.sh` in its own process, proving the *mechanism* while
  structurally unable to observe whether any command was *wired*. The new
  `test_cache_command_wiring.sh` never sources it, and runs the real command
  against a booby-trapped `gh` that fails if called.

## [0.25.0] - 2026-08-03

### Fixed

- **`doctor.sh` parses again on macOS — and the class that broke it is now
  gated (temperloop#1098).** bash 3.2 (every macOS `/bin/bash`) does not treat
  `#` as starting a comment while it scans for the `)` that closes a
  `$( … )` command substitution, so an apostrophe inside such a comment reads as
  an *opening* quote and swallows the closing paren. A comment added in
  `workflows/scripts/install/doctor.sh` tripped exactly that, and the file was
  **completely unparseable — and therefore the install-verification step
  `temperloop install` itself prints on success
  (`bash <dir>/workflows/scripts/install/doctor.sh`) completely non-functional —
  for every macOS user on `main`**:
  `line 251: unexpected EOF while looking for matching ')'`, plus a bogus
  `line 611: syntax error` that names nothing useful. Reworded to drop the
  apostrophes. A tree-wide sweep found one sibling with the same break
  (`workflows/scripts/board/tests/test_boards_conf.sh`, failing at line 283) and
  one latent near-miss (`scripts/tests/test_stranger_config.sh`, saved only by an
  accidental even apostrophe count); both are fixed too, and **all 330 tracked
  shell scripts now parse clean under bash 3.2.57**.

### Added

- **First-epic Phase-A opt-in for the `tokens` producer — the adopter half of
  the consent answer (temperloop#1088).** `temperloop init` proposes the
  `.temperloop/report.d/tokens` producer in its tree-only proposal PR
  unconditionally and discloses it only afterwards, via the producer's own
  first-run notice (temperloop#986). That notice was built where an
  *interview question* had been asked for: the ratified design brief read the
  operator's phrase "the first epic" as "this epic", and a notice **discloses**
  where a question **consents**. `claude/templates/first-epic-setup.md` now
  carries **§ A4 — Token metering**, authored in the same shape as the existing
  A1/A2/A3 questions: an A0 read-only placement probe prices it three ways
  (place it / keep the one `init` proposed / leave one you wrote alone), the
  question names what is read (your own machine's Claude Code transcript files)
  and that no network call is made, and the answer composes into the Phase B
  change-set — so the producer is **placed on opt-in** rather than placed and
  disclosed. Declining is first-class: nothing is placed, an `init`-placed copy
  of the kernel's shim is *removed* by the same set wherever it sits (an
  unmerged proposal PR **or** the default branch — covering only the first
  would let a PR merged afterwards silently override the decline), an
  adopter-authored producer is left byte-for-byte alone on either answer, and
  nothing else in the epic consumes the producer, so no dangling reference
  survives a decline. Phase C gains a co-level L0 `tokens-producer-disposition` item
  (`kind: spike`, mirroring `ci-disposition`'s reasoning — the file lands as a
  consented change-set write, so a code worker would have nothing to commit and
  would open an empty PR on the decline branch), with its own § Consumes and
  § Acceptance entries. **Two things deliberately unchanged:** `init` stays
  non-interactive (no new prompt on any `init` code path — the interview belongs
  to the first epic and is driven by `/build`), and the producer's first-run
  notice stays unconditional. An interview question, exactly like a prompt,
  reaches only whoever runs the flow; the notice is what reaches the teammate
  who inherits the committed producer by a plain `git pull`. The two are
  complementary halves of one consent answer — adopter half and inheritor half
  — and the template, `docs/features/telemetry.md`, and ADR 0010 each now say so
  explicitly, so a later edit cannot mistake one for a replacement of the other.

- **`scripts/lint-bash32-cmdsubst-comment.sh` — a static lint for the
  hidden-apostrophe class above, plus its regression suite
  (temperloop#1098).** Registered in `scripts/quality-gates.sh` and
  `gate-paths.tsv`. It is deliberately a **textual** lint and not a parser
  invocation, because all three obvious detectors are blind here: `shellcheck`
  exits 0 on the pattern, `bash -n` under bash 5.x exits 0 (the bug was fixed in
  bash 4.0), and although `bash -n` under bash 3.2 *does* catch it, the
  pre-merge leg is ubuntu-only (temperloop#963) where bash 5.2 ships and bash
  3.2 is not installable — so a `bash -n` gate would pass unconditionally and
  read as coverage while never firing. Instead a small shell lexer tracks `$(`
  nesting through quotes, escapes, nested substitutions and here-docs. Two rules,
  for a reason spelled out in the script header: a `#` comment inside `$( … )`
  is **strict** (any apostrophe fails — comments are trivially rewordable, and
  an even-parity pair is only accidentally valid), while a here-doc body is
  **parity**-checked (odd count per region fails), so the LLM-prompt prose in
  `bin/subcommands/try.sh` / `bin/subcommands/configure.sh` is not mangled to
  satisfy a lint. The suite's load-bearing test feeds the lint the real pre-fix
  `doctor.sh` region and requires a non-zero exit — a lint asserted but never
  shown to fire on its known-bad input is the same failure over again — and,
  where a bash 3.x is present, re-measures every fixture against the real parser
  so the recorded BREAKS/PARSES expectations cannot silently rot.

## [0.24.0] - 2026-08-03

### Added

- **`clarification-rework` — a seventh friction-ledger category, so
  communication quality is visible to the self-learning loop
  (temperloop#1089).** The friction ledger's six categories were all
  *mechanical* (re-checked state, acted-before-ground-truth, wrong tool
  contract); the one failure the operator experiences most directly — having to
  stop and ask what the assistant's last message *meant* — was captured by
  `workflows/scripts/drain/lexicon.tsv` (as `trust-rupture`) and then dropped,
  because no consumer adjudicated that subset. `/tidy` § Tooling friction
  (fewer-steps) now takes `trust-rupture` **on user turns** as a third lexicon
  anchor and appends one `clarification-rework` row per genuine re-explanation,
  each carrying the verbatim operator line; the rows participate in the existing
  ≥5-in-14d frequent-stumble tally like any other category, so a recurring
  explanatory habit becomes tracked work. Two discriminations are spec'd
  explicitly: the **correctness-challenge** and **repeat-offence** subsets of
  `trust-rupture` stay with § Feedback memories (temperloop#1090's routing,
  whose "deferred to temperloop#1089 / skip these matches" placeholder is now
  replaced by a live pointer), and a **false-positive floor** bars ordinary
  domain questions — a row is logged only when the confusion is about what the
  assistant itself just said. **Contract-surface note for overlays:** the
  category set is enumerated in the `friction-slug` block of
  `workflows/scripts/drain/lexicon.tsv` (now seven rows) and in
  `claude/measurement-proxies.md` Proxy 2; an overlay carrying its own
  § Tooling friction capture live rule should add the seventh slug there too so
  the live rule and the `/tidy` backstop name the same set. The lexicon
  deliberately does **not** gain a new category — `trust-rupture` stays one
  category discriminated at consumption time, because the tells overlap and only
  the surrounding turn separates them.

- **Machinery-step wall-clock liveness bound — a stalled `/build` machinery
  step is now bounded and disposed, not waited on (temperloop#1071).** A
  `pr-batch` machinery agent was observed running 35,362,333ms — **9h49m** — on
  two tool calls: one Bash invocation blocked and then completed successfully
  (all four steps green, the PR opened). The Bash tool's own `timeout` parameter
  is capped at 600,000ms and `build-level.mjs` asks for less, so that call was
  structurally unreachable — the tool timeout simply did not fire, and nothing
  else bounded it. The root cause is **not** established, so the fix is
  deliberately root-cause-agnostic: a bound that holds regardless of which
  hypothesis is true. `claude/workflows/build-level.mjs` now compiles a per-step
  wall-clock **ceiling into the machinery command text itself** — a `sleep`/`kill`
  watchdog running *inside* the invoked shell (the dependency-free fallback tier
  of `workflows/scripts/lib/portable-timeout.sh`, pipe-leak redirect included),
  independent of and additional to the harness layer that failed. It applies to
  every machinery executor: the `prelude` / `pr-batch` / `ci-batch` batches and
  the solo `gate` / `recover-probe` / `push-retry` calls. A step that outlives the
  ceiling is killed, reports its own `STEP_TIMEOUT` line, and is treated as
  **LOST — never failed and never re-issued**: the driver runs the *existing*
  `pr.sh recover-probe` side-effect ladder (temperloop#939, the same disposal
  seam temperloop#1067 covers for the adjacent lost-return case), **adopts** a PR
  the timed-out step already opened rather than re-opening it, and otherwise
  escalates a legible `machinery-step-timeout` carrying the probe's verdict — so
  no bounded step can double-push or double-open. The observability half: a step
  slower than a second threshold emits a `STEP_SLOW` advisory that the driver
  partitions out of the results array and turns into a `log()` line, so a long
  stall becomes **visible** long before it reaches the ceiling instead of being
  the silent 9h49m the incident was. Both budgets are named settings —
  `BUILD_MACHINERY_STEP_CEILING_SECS` / `BUILD_MACHINERY_STEP_SLOW_SECS` in
  `workflows/scripts/build/build.config.sh` — resolved at `build.md` / `sweep.md`
  / `fix.md` Step 0 and handed in as `input.machineryStepCeilingSecs` /
  `input.machineryStepSlowSecs` on the same orchestrator→workflow seam
  `gateSliceSecs` uses (the Workflow runtime has no shell to source config, and
  no `Date.now()` to measure with — which is exactly why the bound lives in the
  emitted shell). The `.mjs` floors the ceiling at no less than one CI-poll/gate
  slice, so no operator value can manufacture a false timeout on healthy work.

- **`resolved` — a verdict-resolved disposition count on the `command-run`
  telemetry stream, plus the accounting assertion it makes possible
  (temperloop#1084).** `workflows/scripts/emit-command-run.sh` accepted only
  `--merged` and `--parked`, but `/sweep` and `/fix` both define a *third*
  terminal disposition — `resolved (verdict)`, a `kind: spike` closed on its
  verdict — which the record could not express. A 30-item sweep therefore
  emitted `{items_processed:30, merged:27, parked:1}`: two items simply
  unaccounted for, and no way for a reader to tell "resolved by verdict" from
  "silently dropped" or "lost to a crash" — the exact distinction the
  pre-report terminal-state assertion exists to make. New `--resolved <N>` →
  a `resolved` field, and the emitter now asserts
  **`merged + resolved + parked == items_processed`**, exiting **2** with the
  arithmetic named when it doesn't hold — *after* appending the record anyway,
  so an inconsistent record is preserved in the stream rather than dropped (a
  dropped record reopens the absent-stream ambiguity this emitter exists to
  close). Infrastructure failure (no `jq`, an unwritable sink, a malformed
  count) still warns and exits 0, so the emit never blocks its caller. All
  three callers updated: `claude/commands/sweep.md` Step 3.6 stops folding
  verdict resolutions into `--merged`; `claude/commands/fix.md` Step 6.4 gains
  the spike arm; and `claude/commands/triage.md` Step 4.9 gains `--resolved
  <C+D>` for its culled + decision-routed candidates, which had no field at
  all and so under-reported every run that culled anything by exactly the cull
  count. `workflows/scripts/validate-command-run-emit.sh` is extended with a
  **content-derived** check — any command doc whose prose declares the
  `resolved (verdict)` disposition must pass `--resolved`, so a doc that
  *gains* that disposition later is caught without editing the linter — plus
  assertions that the emitter still parses `--resolved` and still carries the
  sum check. New behaviour test at
  `workflows/scripts/tests/test_command_run_emit.sh` (registered in
  `scripts/quality-gates.sh`'s `KERNEL_GATES`), and
  `workflows/scripts/telemetry-brief.sh` Q5 renders the new count.

  **Consumer note — purely additive, so no `schema_version` bump** (per
  `meta/data/raw/README.md`'s convention: a new optional field is not a
  breaking change). But the stream is append-only and is **never backfilled**,
  so ⚠ **an ABSENT `resolved` field on a pre-#1084 record means UNKNOWN, never
  `0`** — that record's `merged` count may silently include verdict-resolved
  items, and the partition invariant does not hold for it. Every record
  written from now on carries the field explicitly, so its absence is a
  reliable pre-#1084 marker; read it with `has("resolved")`, not
  `(.resolved // 0)`, before asserting the invariant or reporting a rate. The
  brief's Q5 row does exactly that, printing "resolved unknown for N pre-#1084
  run(s)" rather than implying those runs resolved nothing.

- **Legacy host-config preflight — a registry-driven gate that asserts a
  removed legacy consumable ON THE HOST, not the repo artifact that merely
  describes it (temperloop#908).** New
  `workflows/scripts/install/legacy-host-preflight.sh`: a small registry of
  `id -> checker-function` rows, one per removed legacy host-config path,
  each checker inspecting host state directly and reporting `ABSENT`
  (never installed on this host — never a failure), `MIGRATED` (present but
  superseded), or `LIVE-UNMIGRATED` (present with no successor — the
  failure case). Wired into `workflows/scripts/install/doctor.sh`'s new
  `check_legacy_host_config()`, so it rides both `make doctor` and
  `temperloop update`'s post-checkout doctor run
  (`bin/subcommands/update.sh`) — the two points a release actually lands
  on an operator's host — and fails the overall exit code on any
  `LIVE-UNMIGRATED` entry. The registry ships two rows covering the two
  instances that motivated it: an installed
  `~/Library/LaunchAgents/com.foundation.funnel-cron.plist` still invoking
  the deleted `funnel-cron.sh` stub (foundation#1419 — the repo plist was
  repointed at `pipeline-cron.sh`, but the gate that would have caught the
  installed copy tested the repo file, not the host); and a legacy
  `$XDG_CONFIG_HOME/foundation/boards.conf` with no
  `$XDG_CONFIG_HOME/temperloop/boards.conf` successor in place
  (temperloop#165, v0.19.0 — the failure mode both instances share: a
  pre-removal advisory (`board.sh`'s "NOTE — legacy machine conf … is no
  longer read", `pipeline-cron.sh`'s "NOTE: … is deprecated") only fires
  from the deprecated-but-still-working state and disappears once the
  removal actually lands, flipping the failure from noisy-and-working to
  silent-and-wrong at exactly the moment nobody is warned anymore). A
  future removal extends coverage by adding one registry row plus its own
  `legacy_check_<id>` predicate — no other file changes. Demonstrated
  against reconstructed unmigrated fixtures for both instances (not merely
  asserted), plus a regression fixture proving a plist header comment that
  merely *names* the installer script `infra/launchd/install-funnel-cron.sh`
  does not false-positive a migrated plist — see
  `workflows/scripts/tests/test_legacy_host_preflight.sh`, registered in
  `scripts/quality-gates.sh`'s `KERNEL_GATES`.

- **Multiline-safe absence proofs plus red-at-merge-base validation
  (temperloop#944).** A `class: A` absence-asserting `proof:` predicate
  (`! grep -q '<phrase>' <file>`) silently passes on an untouched tree the
  moment the target phrase line-wraps — grep is strictly line-oriented, so a
  wrapped phrase can never match and the negated grep reads Pass whether or
  not the removal happened (demonstrated live: `! grep -q 'batched draft is
  still fine' claude/commands/workshop.md`, temperloop#930, passed on
  `main@f41a93a` before any work, because the phrase wrapped across lines
  386/387). Two fixes, both landed: (1) `plan-schema.md` § activation now
  documents the verified-portable, wrap-immune idiom — `! tr '\n' ' ' <
  <file> | tr -s ' ' | grep -q '<phrase>'` — for authoring an absence proof;
  (2) `build.md` § 3e.6 now runs any absence-asserting `proof:` against the
  item's merge-base first and fails the item
  (`absence-proof-vacuous-at-merge-base`) if it already passes there — a
  proof green before the work happened is by definition not proving the
  work. No code/schema changes; both fixes are prose-contract updates to
  `claude/commands/build.md` and `claude/plan-schema.md`.

- **`scripts/quality-gates.sh` gains an opt-in full per-gate wall-clock
  publication (temperloop#968, first deliverable only — a measurement, not a
  matrix/branch-protection change): `QUALITY_GATES_STEP_SUMMARY=1` appends
  every gate's own measured seconds (already tracked internally by the
  bounded-concurrency pool, temperloop#1025) as a Markdown table to
  `$GITHUB_STEP_SUMMARY`. Off by default and never set by `ci.yml`'s
  merge-gating `checks` job, so the leg that gates `main` is byte-identical.
  `.github/workflows/nightly-macos.yml` sets it on both its existing macOS
  job and a new, non-gating `ubuntu-timing` job (same script, `ubuntu-latest`
  — the runner `checks` already uses) so a night's macOS and ubuntu per-gate
  breakdowns land in the same workflow run's summary page, directly
  comparable, letting a future slowdown be localised to specific gates
  instead of attributed to "macOS is slow". `ubuntu-timing` produces no
  `checks (...)`-shaped status context and is not required by branch
  protection.

- **`scan_stub.py` emits `stub.model` in the scan report (temperloop#761),**
  satisfying two downstream contracts that already documented it:
  `findings-schema.md`'s `subject_model` ("taken from the stub's `model:`
  field (`report.stub.model`)") and `tidy.md`'s vault-provenance
  `source_model` stamp. Read from the stub frontmatter's `model:` line
  (written by the SessionEnd hook). The `model` key is now **always present**
  on `report.stub` — present-case: the frontmatter value; absent-case: an
  explicit `null`, never an omitted key or empty string — so a genuinely-
  absent model and a never-emitted field can no longer look identical
  downstream. `scan-report-schema.md` documents the new field; both the
  present and absent cases are covered by
  `workflows/scripts/drain/tests/test_scan_stub.sh`.

- **`scan_stub.py` gains two soft-error signatures (temperloop#770), promoted
  from the candidate-tells surface: `Unknown JSON field` (a `gh --json` query
  naming a field the installed `gh` rejects — the query "succeeds" at the
  shell level while the wrong branch is silently taken; recurred twice on
  2026-07-25, temperloop#762) is a straight addition to `_ERROR_SIGNATURES`.
  `has been denied` (a Bash permission-policy denial of a command a command
  SPEC requires — two consecutive drains hit this on `/tidy`'s `gh pr list`
  archive-PR check, temperloop#763) is a new structural detector instead: an
  isolated denial is noise, so it is gated by a cross-run same-command dedup
  guard — a small on-disk JSON state file (default under
  `${XDG_STATE_HOME:-$HOME/.local/state}/temperloop/`, overridable via
  `$SCAN_STUB_DENIED_STATE_PATH` or `--denied-state`) — and only promotes a
  command to a finding once the same command text has been denied across two
  or more distinct sessions. The scan report schema gains a new
  `tool_events.repeated_denials[]` bucket
  (`workflows/scripts/drain/scan-report-schema.md`) for these findings; both
  signatures are covered by `workflows/scripts/drain/tests/test_scan_stub.sh`.

- **`make doctor` gains a CROSS-checkout install-source split check
  (temperloop#777), the counterpart to temperloop#774's within-checkout
  plane-A/plane-B knowledge-root comparison.** #774's check is correct and
  stays, but it is scoped to the checkout doctor runs from (it sources
  `build.config.sh` / `knowledge_store.sh` straight out of `$FOUNDATION`) —
  it cannot see `~/.claude` itself resolving into a *different* checkout
  entirely. Live evidence (2026-07-26): after vendoring v0.18.0 into
  `~/dev/foundation`, `readlink -f ~/.claude/hooks/session-start-drain.sh`
  resolved into an unrelated, clean-on-main checkout still pinned to
  v0.17.0 — 25 drain skips in one day, with doctor reporting OK from
  *both* checkouts the entire time (neither was wrong about what it
  measured). The new `check_cross_checkout_split()` resolves the
  representative installed surface
  (`~/.claude/hooks/session-start-drain.sh`) to its real, symlink-resolved
  path, asks git which checkout owns it (`git -C <dir> rev-parse
  --show-toplevel`), and compares that against the checkout doctor is
  running in. A mismatch is reported as `MISMATCH`, naming both real paths
  and both `.kernel-pin` tags (reusing `env-reconcile.sh`'s
  `kernel_pin_tag_of()`, sourced in a subshell so its globals/arg-parse
  never leak into doctor's own). Degrades to `SKIPPED` — never a hard
  failure — when the installed surface doesn't exist yet (a fresh clone
  that hasn't run `make install-claude`) or doesn't resolve into any git
  checkout at all. New regression test
  `workflows/scripts/tests/test_doctor_cross_checkout_split.sh`, covering
  the mismatch-detected, no-mismatch, and absent-surface paths; registered
  in `scripts/quality-gates.sh` and `workflows/scripts/config/gate-paths.tsv`.

- **A consumer-parity shellcheck gate for the synced board file set
  (temperloop#915), closing the SYSTEMIC half of temperloop#905 left open
  after that fix addressed only one file.** `make shellcheck` (the kernel's
  own whole-tree lint) excludes `*/tests/*` and passes `-e SC1091`
  repo-wide — exactly the blind spot stageFind/ssmobile/subsetwiki fall
  into: they vendor `workflows/scripts/board/` verbatim (`make
  sync-*-board`) and lint their whole tree at plain shellcheck defaults, no
  exclusions. On 2026-07-29 the identical SC1091 at
  `test_board_cache.sh:66` was live simultaneously in all three consumers'
  required `checks` while the kernel's own gate stayed green throughout —
  it structurally could not see it. The new gate,
  `workflows/scripts/board-consumer-shellcheck.sh`, reproduces the
  consumer's own command (default severity, no `*/tests/*` exclusion, no
  `-e SC1091`) against the exact synced file set —
  `workflows/scripts/board/**` (top-level scripts, `lib/`, `tests/`, and
  `tests/fixtures/`) — so a finding that would red every vendored
  consumer's `checks` now fails at the source instead. Scoped, not
  whole-tree, so it stays low-noise and never fights `make shellcheck`'s
  existing repo-wide posture (unchanged). Registered in
  `scripts/quality-gates.sh` (`KERNEL_GATES`, sharing `make shellcheck`'s
  serial lane over the pinned-shellcheck cache) and
  `workflows/scripts/config/gate-paths.tsv`. Closing the gap required
  fixing the ~20 files it newly exposed (mostly targeted
  `# shellcheck disable=SC1091` directives above unresolvable `source`
  lines, plus a few pre-existing prose comments that happened to start
  with the literal `# shellcheck ` and were themselves being misparsed as
  directive attempts) — the tree is clean at consumer parity as of this
  change.

- **`scripts/quality-gates.sh --scoped` — a changed-file-scoped run for a
  `/build` item worker's iterative mid-work verification (temperloop#957).**
  Verification was measured at **79% of all item-worker shell wall-clock**
  (10.4h of 13.2h across 141 workers) with gates 85% of that — p90 **122s**,
  max **600s** — because a worker checking a three-file change had no way to
  ask for less than the whole suite. `--scoped` applies temperloop#1024's
  existing selector and `gate-paths.tsv` map to the **local working tree**
  (committed ∪ staged ∪ unstaged ∪ untracked, ignored files excluded) instead
  of a pull-request diff. **Wall-clock only — it saves approximately zero
  tokens**; the API call still happens, it just returns sooner. Nothing about
  the runs that gate `main` changes: the bare, repo-wide invocation — CI's
  `checks` job and `/build` §3e.5's parent-side acceptance gate — is
  byte-identical, and only the flag opts in. Every resolution failure (no base,
  not a checkout, an unmapped path, an `ALL` path, a malformed map) widens to
  the **full** set. A scoped run **names every gate it skipped and why**, twice
  (before the run and beside the verdict), and stamps its verdict line
  `[SCOPED SUBSET — NOT a full-suite pass]` so a one-line grep of a worker's
  log cannot read as a full-suite pass. `gate-paths.tsv` gains an enumerated,
  individually-justified **global-by-nature floor** — capture/backstop pairing,
  cross-file template-reference integrity, prose-budget totals, and
  manifest/registry completeness (contributor manifest, setting registry,
  activation registry, and the gate-path map's own lint) — which now `ALWAYS`
  runs on *every* scoped run, PR-scoped and worker-scoped alike; reports that
  cannot fail on their own findings are deliberately excluded, and the
  exclusion is justified in the map. New gate:
  `scripts/tests/test_quality_gates_scoped.sh`.

- **Two draft ADRs recording the toolkit-provenance design's architectural
  calls (temperloop#1047).** `docs/adr/0021-toolkit-provenance-is-derived-not-declared.md`
  records that whether the running toolkit code matches its release is
  **derived** from git at read time rather than declared as stored state — no
  marker file, no mode flag, no added pin field — so nothing can go stale and
  removal is a pure deletion. `docs/adr/0022-provenance-baseline-is-the-subtree-split.md`
  records that the baseline for a vendoring consumer is the **recorded-versus-
  recomputed subtree split sha**, and that the seemingly-obvious alternative
  (diffing from the commit that last touched `.kernel-pin`) is rejected: the
  update tool writes the pin in a *separate, later* commit and skips it
  entirely on an idempotent re-run, which was shown in a sandbox to report a
  hand-edited tree as unmodified. Both are `Proposed`; accepting them is a
  separate human act. Documents only — no behaviour change, and `docs/adr/*`
  was already claimed in both governance manifests, so no registry edit was
  needed.

- **`temperloop report` now says so when a `tokens` producer's stdout fails
  the headline parse, instead of degrading silently (temperloop#988).** A
  `tokens` drop-in that is present, executable, and exits 0 but whose stdout
  is not exactly one JSON object with a numeric `tokens_spent` field used to
  fall through to the kernel-tier headline with **no line explaining why** —
  the asymmetry temperloop#981 left behind when it added a `notice` channel
  for messages "that must not be silently dropped" while enlarging this mute
  population (checking `jq`'s exit status pulled JSON-plus-trailing-text
  stdout, which previously kept its headline by accident, into the
  falling-back set). `report.sh` now renders one line in the **existing
  per-producer skipped-line channel**, inside that producer's own `--
  report.d/tokens --` block: `skipped -- tokens: stdout did not parse as a
  single JSON object with a numeric tokens_spent field (headline fell back to
  the kernel tier -- not an error; see report.contract.md)`. **Not a
  tightening:** the kernel-tier fallback is byte-identical to before, the run
  still exits 0, and a non-conforming producer is still a legible degradation
  rather than an error. One suppression keeps the common path quiet — stdout
  whose first line already opens with `skipped -- ` (the shape the kernel's
  own shim prints when unresolvable or locally disabled) self-declared
  already, so it gets one skip line, not two. `report.contract.md` §
  "Overlay drop-in contract" / "Headline selection" state the new line and
  its exception.

- **Git stale-branch-guard hook test coverage expanded (temperloop#776,
  refiled from foundation#1138): regression test for the exact shape of
  a subsetwiki incident (18-commit stale branch, silent bypass of the
  guard) and install-verification fixtures.** Investigation of a 2026-07-10
  incident found that subsetwiki's project-level `.claude/settings.json` (a
  valid, intentional declaration skipping global hook re-declaration per
  Claude Code's documented hook-merge semantics) could not shadow the guard's
  global registration. The real root cause was prior to commit fe86e11
  (2026-07-25): the guard's awk parser had no case for `git worktree add -b`
  and silently skipped that branch-creation verb, even though subsetwiki's
  `/build` workflow uses worktree-based branching. The parser gap is already
  closed by an earlier commit in this tree, so this ticket closes the
  remaining **test coverage gap** rather than a logic gap: a fixture
  reproducing the subsetwiki shape (project-level `~/.claude/settings.json`
  declaring only `Edit|Write|MultiEdit` hooks) proves the guard still fires
  there (install-verification leg), and a behind-by-18 fixture reproduces the
  incident's exact behind-count rather than an arbitrary N (explicit regression
  naming the reason string's behind-by-N count, not just ask vs silent). New
  `check_reason()` helper in the test asserts both decision *and* the
  behind-count textually. Upstream: this test surface is outside the kernel
  proper (kernel #49, write-lane guard hook test file — part of the
  test-surface system Travis added, not part of the generic kernel shipped to
  strangers).

- **One-time first-run disclosure and a per-person local disable for the
  `tokens` report producer (temperloop#986).** The producer at
  `.temperloop/report.d/tokens` is a *committed* artifact, so a teammate who
  inherited it by a plain `git pull` never saw an `init` prompt and had no way
  to learn that `temperloop report` reads their own Claude Code transcripts.
  On that person's first run the producer now emits a one-time disclosure
  naming what it reads, that it makes **no network call**, and the exact
  command to switch it off. The disclosure rides the existing `notice` field
  (`report.contract.md`, temperloop#981) rather than a second stdout line, so
  it cannot defeat the `tokens_spent` parse — the headline still renders on
  the run where the notice fires. The disable is a marker file under
  `${XDG_STATE_HOME:-$HOME/.local/state}/temperloop/tokens-producer/`,
  **never a committed file**: a committed dismissal would silently disable the
  producer for every collaborator who clones the repo, and a bare env var
  would vanish between shells, so a cron tick or a second terminal would
  re-read transcripts anyway. Note the marker carries **no repo component** —
  it is global to you on this machine, so disabling it in one repo disables it
  in every adopted repo on that machine. A disabled run degrades through the
  ordinary `skip()` path, so only the *headline* matches an absent producer;
  the `-- report.d/tokens --` block itself still appears, carrying the skip
  line. See `docs/features/telemetry.md` § First-run notice and local disable.

- **`/build` merges each clean-disjoint PR as it goes green, instead of parking
  every item until the level boundary (temperloop#1026).** New Step 3h.5 in
  `claude/commands/build.md`, governed by the new `BUILD_MERGE_AS_YOU_GO`
  setting (`build.config.sh`, default on; `0` restores pure level batching).
  Measured motivation: three PRs opened together took 68/69/145 min
  open-to-merge against 10–33 min for solo PRs — level batching converted
  within-level parallelism into a merge-queue pileup. **Scoped, not a
  loosening:** eligibility reuses the *existing* Step-4a regime partition and
  is strictly narrower than it — the item's own `gate.sh risk` verdict must be
  clean, and it must be path-disjoint from every non-terminal sibling in its
  level, where a sibling that has not pushed yet counts as UNKNOWN and
  therefore *not* disjoint. Anything else parks `[m]` for the unchanged
  level-boundary gate, and a risky / structurally-overlapping set still
  hard-blocks modally there byte-identically to before. Consent does not move:
  an eligible item is a clean-disjoint set of one and takes the existing 4b
  timed/headless consent path, recording the same `## Merge gate log` line. The
  level boundary remains a dependency barrier for *starting* the next level.
  Because each as-you-go merge is its own invocation of `gate.sh queue`/`gate.sh
  managed-merge`, the stale-base re-validation now runs **per merge** rather
  than once per level — which is what an early merge moving the base under its
  still-open siblings requires. **New plan-note sentinel `[>]`** (merging
  as-you-go: consent recorded, merge issued, awaiting confirmed `MERGED`) —
  additive, deliberately *not* a repurposing of `[m]`, which keeps its
  "parked, awaiting consent" meaning. `plan.sh writeback` accepts it in
  bracketed and bare-char form; `plan-schema.md`, `presentation-plane.md`,
  `docs/architecture.md`, `docs/features/build-machinery.md`, and
  `docs/features/merge-gate.md` are reconciled. No existing sentinel's bytes,
  meaning, or parse changes, so an in-flight plan note written by an older
  kernel resumes unaffected.

- **Diff-scoped CI gate selection — a `pull_request` run of
  `scripts/quality-gates.sh` now executes only the suites its changed paths can
  affect (temperloop#1024).** The `checks` job ran the whole ~110-gate set on
  every `pull_request` and again on `merge_group` — ~5.5 min flat (measured
  2026-08-02 across the last 20 runs), so every merged PR paid >=11 min of CI
  even for a one-file docs change. A new registry,
  `workflows/scripts/config/gate-paths.tsv`, maps each gate to the path globs
  that reach it; `workflows/scripts/lib/gate-selection.sh` (sourced by
  `quality-gates.sh`, the same seam as `gate-retry.sh` /
  `checkout-freshness.sh`) narrows the run accordingly. A docs-only diff now
  selects 12 of 112 gates.
  **Nothing about what gates `main` changes:** scoping applies to the
  `pull_request` event ONLY, so `merge_group` — the run a PR must clear to
  merge — `push: main`, the nightly macOS leg, and `/build`'s 3e.5 acceptance
  gate all still run the full set. The required status-check context
  `checks (ubuntu-latest)` is unchanged (same job, same single-entry matrix,
  same one `run:` step); `.github/workflows/ci.yml`'s header now documents the
  by-event arrangement. The base SHA is REUSED from the existing
  `LEAK_GUARD_BASE` export rather than derived a second way.
  Against the silent-green class the map could otherwise reopen, every
  degradation resolves toward MORE coverage: an unrecognised changed path, an
  unresolvable base, an empty diff, or a missing/malformed map all fall back to
  the full set (announced, never silent); an explicit `ALL` row escalates
  outright for paths whose blast radius is the gate machinery itself; and a
  gate with no row runs unconditionally. The map ships its own gate,
  `workflows/scripts/config/check-gate-paths.sh`, which fails the build on a
  gate with no row, a row naming a gate that no longer exists, a literal path
  not in the tree, or — the load-bearing one — a row whose globs match no
  tracked path, i.e. a gate orphaned behind an unmatchable glob that would
  otherwise be skipped on every scoped run forever. Validator and selector
  share ONE glob matcher, so what is validated is byte-for-byte what is
  consumed. New settings: `QUALITY_GATES_SCOPE` (`auto`|`full`|`diff`) plus the
  `GATE_PATHS_*` fixture seams; new `--list-selected` flag prints the set an
  invocation would run, with its reason, without running it.
- **`scripts/quality-gates.sh` now runs its gate set through a bounded worker
  pool instead of one gate at a time (temperloop#1025).** The set is ~109
  *independent* suites and the `checks` job's ~5.5 min wall time was almost
  entirely that serialization — the measured baseline has no dominant gate
  (`test-try` 56s, `test-build` 55s, the whole-tree shell lint 29s,
  `test-board` 21s, prose budget ~20s, then a long tail of 1–5s suites), so
  only concurrency could recover it. New sourced lib
  `workflows/scripts/lib/gate-pool.sh` owns the scheduling; the new
  `QUALITY_GATES_JOBS` setting sets the width (`auto` = detected cores,
  clamped; `1` restores the exact pre-parallel serial loop for bisecting a
  gate or hunting an order-dependent flake). Unchanged by design: the gate
  **list**, the pass/fail **semantics** (every gate runs, every failure is
  collected, the run exits non-zero iff one failed), the **log shape** (each
  gate's output replayed whole, in list order, under the same
  `=== <gate> ===` header), and the **CI job** — this is a within-job pool,
  *not* a build matrix, because a matrix would rename and multiply the
  required `checks (ubuntu-latest)` status context and silently un-gate the
  branch. Exit-code integrity is fail-closed throughout: each child reports
  its verdict over two independent channels that must agree, a missing or
  disagreeing verdict is recorded as a **failure**, the parent asserts it
  recorded one verdict per gate handed in, completion markers are published
  from the child's `EXIT` trap so an abruptly-dying worker cannot wedge the
  run, and a scheduler that cannot allocate its scratch falls back — out loud
  — to the always-correct serial loop. Three gates that contend over one
  shared mutable resource (`make shellcheck` /
  `scripts/tests/test_ensure_shellcheck.sh` over the pinned-shellcheck cache,
  and `make docs` over the tree it rebuilds) are pinned to a dedicated serial
  lane that keeps them mutually exclusive with each other while still
  overlapping the pool; the shared-state audit behind that list is recorded in
  `docs/features/quality-gates.md` § Parallel execution. The auto-width cap is
  set at a **measured** knee rather than a guessed one: on a 10-core machine
  width 8 was both slower (176s vs 162s) *and* flakier (three gates failed
  their first attempt and only passed on retry, versus none at width 4), so
  oversubscription costs speed and correctness signal together. That audit also
  surfaced a pre-existing latent defect in the test suites themselves — the
  `echo "$x" | grep -q P` shape under `set -o pipefail` returns 141 when the
  writer loses a `SIGPIPE` race, which is invisible on an idle machine and
  ~5% likely at width 8 — documented but deliberately **not** papered over by
  the retry machinery; it is widespread (596 sites across 77 files) and is its
  own item. The pool forks each gate **under job control** (`set -m`), which is
  load-bearing rather than cosmetic: with job control off, bash sets `SIGINT`
  and `SIGQUIT` to `SIG_IGN` in an asynchronous child and hard-ignores them, so
  the disposition is inherited through `fork` *and* `exec` by the gate's whole
  process tree and cannot be reset from inside it. That silently turned
  `workflows/scripts/probe/tests/test_gh_call_logger.sh`'s `kill -INT $$`
  fixture into a no-op and failed `make test-conventions-probe` on a suite that
  is green serially — the one *observable* instance of the broader invariant a
  parallel run must hold, that a gate sees the same process environment it did
  in the foreground. Two deliberate consequences: each child now leads its own
  process group, so the cleanup trap kills the child's **group** and reaps the
  `make` subtree an interrupted run used to orphan; and a child's stdin is
  pinned to `/dev/null`, since a background process group that read the
  terminal would be stopped by `SIGTTIN` and wedge the poll.
- `scripts/tests/test_quality_gates_parallel.sh`, registered in the kernel gate
  set: covers exit-code integrity (a failing gate still returns non-zero and is
  attributed correctly; a verdict-less or abruptly-dying worker is recorded as
  a failure, never a pass, and never hangs the run), list-order replay, the
  serial lane's mutual exclusion, the slow-dispatch hint, real concurrency, the
  jobs-resolution degradations, the unchanged execution environment (a gate
  still observes the default `SIGINT` disposition, and the pool leaves the
  caller's own `set -m` state alone), and the wiring — including that CI is
  still a single non-matrix job.
- The pool **composes with the sliced execution seam** (temperloop#1021) by
  selection: the slice window picks the run set and the pool is handed exactly
  that array, with the soft budget checked between **chunks** of
  `QUALITY_GATES_JOBS` rather than between individual gates. A partial run
  therefore still stops on a gate boundary and still resumes at a whole number
  of gates in, while an unbudgeted run (CI, `make quality-gates`, a human run)
  stays a single full-overlap chunk. Chunking was chosen over giving the pool
  its own deadline specifically to avoid relaxing its fail-closed *one verdict
  per gate handed in* assertion to *per gate dispatched* — the check standing
  between a silently-dropped gate and a green CI run. Landing this also closed
  a latent hole in `scripts/tests/test_quality_gates_slice.sh`: its fixture
  never copied `gate-pool.sh` into the fake repo, so the `source` failed, every
  `gate_pool_*` call was a `command not found`, and the suite passed while
  exercising **none** of the parallel path it shares a run loop with. The
  fixture now copies the lib, the script announces that degradation instead of
  falling through silently, and two new cases cover the chunked partial and a
  full pooled slice loop.
- **`VERSIONING.md` § Cutting a release — the ordered release procedure
  (temperloop#1015).** The kernel had version *policy* (this file's bump rules)
  and tag *conventions* (`kernel-repo-layout.md` § Release-tag convention) but
  no ordered **procedure**, so the steps were reconstructed from memory each
  cut and some were skipped or deferred to the next one. The new section owns
  the steps and their order, referencing the conventions rather than restating
  them: the CHANGELOG-completeness check against merged PRs since the last tag,
  the **one-PR rule** (`main` is protected, so each cut costs a ~11-minute
  merge-queue round-trip — the v0.23.0 cut split a backfill from the version
  bump and paid an extra cycle for it), the heading rewrite plus `VERSION` bump
  in one commit, tagging the merge commit, and downstream propagation via
  `make update-kernel`. Two hazards are called out explicitly because both are
  silent: `changelog_breaking_sections()` sets its flag **only from a heading
  line**, so rewriting `## [Unreleased] — BREAKING` into a bare
  `## [x.y.z] - <date>` drops the release's breaking signal and makes both
  `update-kernel`'s acknowledgment gate and `temperloop update`'s warning no-op;
  and `## [Unreleased] — BREAKING` occurs more than once in this file (the live
  heading plus historical body prose), so a `replace_all` edit rewrites history.
  `kernel-repo-layout.md` § Release-tag convention gains a pointer to the new
  section. Documentation only — no behavior, no gate, no contract surface moves.
- `GATE_RETRY_BACKOFF`, `GATE_DETERMINISTIC_PATTERN` and
  `CI_POLL_API_DETERMINISTIC_PATTERN` settings, plus
  `workflows/scripts/build/build.config.sh` declarations for the existing
  `GATE_MAX_ATTEMPTS` / `CI_POLL_API_MAX_ATTEMPTS` /
  `CI_POLL_API_RETRY_BACKOFF` caps, so every retry bound in the gate and
  CI-poll machinery has one operator-facing home (temperloop#976). The
  consuming scripts keep byte-identical layer-6 fallbacks, so a repo that never
  sources `build.config.sh` behaves exactly as before.
- `scripts/tests/test_quality_gates_retry.sh`, registered in the kernel gate
  set: covers the cap, both classifiers, the backoff actually spacing attempts,
  and the wiring between `quality-gates.sh` and the new lib.
- **`docs/model-fanout-inventory.md` — every model-spawning site in the repo,
  each classified as explicit setting / justified inherit / silent inherit
  (temperloop#978).** The complement to temperloop#972, which wired levers at
  four *known* sites: this enumerates the seats nobody had listed. The find was
  three headless `claude -p` seats under `bin/subcommands/` that spawned with
  **no `--model` flag at all**, so each ran on whatever tier the invoking
  operator's CLI defaults to — the top tier, on a stranger's very first
  command. Each now names a setting whose default lives only in
  `build.config.sh` and is registered in `setting-registry.tsv`:
  `TRY_TRIAGE_MODEL` (`try.sh` Step 3 shadow triage), `TRY_DEMO_FIX_MODEL`
  (`try.sh --demo`'s live fix call) and `CONFIGURE_AI_MODEL` (`configure.sh`'s
  AI-guided suggestions). The doc also adopts **whole-job accounting** as the
  standing decision rule for any re-tier — a cheaper tier stays only if
  job-*including-repairs* beats the strong tier — and records the measurement
  gap rather than working around it: all three seats pass
  `--no-session-persistence`, so they write no transcript and the
  `.temperloop/report.d/tokens` producer structurally cannot see them.

### Changed

- **`/build`'s worker return value is now SIZE-bounded, not just
  shape-validated (temperloop#1080).** The worker verdict's shape has always
  been machine-enforced (`WORKER_VERDICT_SCHEMA`), but a JSON schema cannot
  bound a string's length, so its two free-prose slots were bounded by nothing.
  Measured across **83 real worker verdicts** recovered from subagent
  transcripts, `summary` ran to a median 119 words (max 557) against a spec
  asking for "1-3 sentences", and each `acceptance_results[].evidence` to a
  median 33 words (max 244) against a spec asking for "`file:line` or test
  name" — every word an output token (the weight-5 class) that the orchestrator
  then ingests. `claude/workflows/build-level.mjs`'s shared `workerPrompt()`
  now carries an `## Output shape` section stating both bounds and banning
  process narration outright, and the verdict schema's free-prose fields carry
  `description`s fixing what each slot is *for* (`evidence` is a **pointer**,
  not the argument). The bounds are the new named settings
  **`BUILD_WORKER_SUMMARY_MAX_WORDS`** / **`BUILD_WORKER_EVIDENCE_MAX_WORDS`**
  in `workflows/scripts/build/build.config.sh` (registered in
  `setting-registry.tsv`), resolved at `build.md` Step 0 item 6 and handed in
  as `input.workerSummaryMaxWords` / `input.workerEvidenceMaxWords` on the same
  seam `gateSliceSecs` uses — with in-file `.mjs` defaults, so `/sweep` and
  `/fix`, which do not resolve the settings, still inherit the bounded prompt.
  **Not information loss:** the worker already writes its full argument to
  `.build-verification.md`, which `pr.sh` splices into the PR body's
  `## Verification` section *by path*, so bounding the verdict moves prose off
  the expensive path rather than deleting it. A projected shrink of ~42% on the
  median verdict and ~75% on the largest observed one, with every reviewer-
  facing fact preserved. New static lockstep guards in
  `workflows/scripts/build/tests/test_workflow.sh` pin the prompt section, the
  narration ban, the interpolated (never hardcoded) bounds, and `build.md`
  §3c's matching prose.

- **`claude/commands/workshop.md` trimmed by a subtraction pass, and
  `PROSE_BUDGET_TIER2_FILE_CAP` lowered 1186 → 1100 (temperloop#956).**
  `workshop.md` had become the largest tracked kernel doc and had funded
  **three** raises of the uniform tier-2 cap in a single day (temperloop#925,
  #947, #954) — and because the cap is one value across all 42 tracked docs,
  each raise loosened the budget for every other doc purely to fund one file.
  This reverses that erosion: 1181 → 1041 lines (−11.9%) by consolidation and
  removal of restatement, never by deleting specified behavior — every step,
  sub-step, gate, disposition, and named rule the file specified before is
  still specified, and all 18 citation markers (`W.1`–`W.18`) survive
  unchanged. The repeated `vault_patch` frontmatter-scalar warning is now
  stated once and cross-referenced; the Failure-modes section is a one-line
  index back into each step rather than a second full restatement. The
  load-bearing `§ Step 2 — Coverage walk` heading — cited **by name** from
  `tidy.md`'s capture/backstop registry row (temperloop#933) — survives
  verbatim. The cap is reseeded to `build.md`'s current 1100 lines, the same
  zero-headroom convention it was originally seeded with, so the ratchet has
  now moved **down** for the first time.

- **The basic-memory config written by `ks_search` now carries
  `semantic_embedding_dimensions` alongside `semantic_embedding_model`, as one
  coupled setting (temperloop#907).** `_ks_bm_ensure_config` pinned the
  embedding model but left its vector width to basic-memory's default, so a
  future model flip would have written a model/width mismatch — which does not
  error: the index builds, every vector is zero, and every semantic search
  quietly returns nothing. The pair now has a single definition site: the model
  is authored once (`_ks_bm_embedding_model`) and the width is *derived* from
  it through a model→width table (`_ks_bm_embedding_dimensions`, `384` for the
  pinned `bge-small-en-v1.5`), which fails loudly rather than guessing for a
  model it has no width for. Setting one without the other is therefore
  unrepresentable, not merely discouraged. The write-once early return on an
  existing `config.json` is unchanged — an already-written config is still
  never touched, so this affects only freshly-created state dirs.
  `knowledge_store.contract.md` posture point 7 documents the coupling.

- **The `tokens` report producer now RESOLVES checkouts whose encoded path
  exceeds Claude Code's 200-character project-name cap, instead of degrading
  to machine-wide (temperloop#995).** Claude Code stores such a project under
  its first 200 encoded characters plus a `-<hash>` suffix that shell cannot
  reproduce, so since temperloop#983 those checkouts fell back to the
  machine-wide corpus under an honestly-labeled notice — correct, but never
  scoped. The producer now takes the same route Claude Code's own reverse
  lookup takes: it globs
  `$HOME/.claude/projects/<first-200-chars-of-encoded>-*` and scopes to the
  match. This is **not** the ambiguous reverse-decode the producer still
  refuses — the prefix is forward-encoded from a path it already knows (git's
  own toplevel); only the hash tail is unknown, and the tail is never guessed.
  **Exactly one match is scoped**; zero matches, or more than one (two
  checkouts identical across their first 200 encoded characters), still
  degrade to machine-wide rather than picking one — under a notice that now
  names the prefix **glob** it searched and says which of the two happened, so
  the operator can paste it straight into an `ls`. A successful prefix
  resolution says so in its own notice too, so a surprising number is
  attributable to the route that produced it. Five notice variants now, not
  four; see `workflows/scripts/lib/report.contract.md` § Kernel-shipped
  `tokens` producer's transcript scope.

- **`temperloop try`'s shadow-triage pass now runs on an explicitly cheaper
  tier by default (temperloop#978).** `TRY_TRIAGE_MODEL` defaults to a cheap
  tier rather than inheriting the operator's CLI default. This is the one seat
  of the three that is re-tiered, and the choice is measured rather than
  assumed: the pass emits free-form text the script prints verbatim, so there
  is no JSON contract to violate and no downstream parse a weaker model can
  fail; it is a zero-write dry run; and it is a stranger's *first* command,
  billed to the stranger's own account. Whole-job measurement: a valid,
  correctly-prefixed report 2/2 with no repair path invoked, ~5.5x cheaper per
  call in dollars. Stated honestly — the cost-*weighted*-unit delta is within
  noise on n=2, because the cheap tier is chattier and output carries the
  heavier weight, so the win is claimed on the dollar axis only. Set
  `TRY_TRIAGE_MODEL` to empty to restore the previous inherit behavior. The
  other two seats (`TRY_DEMO_FIX_MODEL`, `CONFIGURE_AI_MODEL`) keep inheriting
  and now carry a written justification instead of an accident —
  `configure.sh` in particular was measured and **refused**: the cheap tier is
  ~2.4x cheaper per seat but fenced its JSON on 4 of 4 runs, which makes `jq`
  exit 5 and silently drops every setting to the plain-prompt fallback. 2.4x
  cheaper, 0% of the job — the exact inversion whole-job accounting exists to
  catch, and one per-seat accounting would have scored a win.
- **Retry loops in `/build`'s gate and CI-poll machinery now classify before
  they retry, and back off between the retries that remain** (temperloop#976,
  with `Towheads/foundation#1297`). Re-running a *deterministically* failing
  operation cannot change its outcome; the live case was `/build`'s acceptance
  gate re-running a failing `shellcheck` three times before an operator
  intervened. Two loops changed:
  - `scripts/quality-gates.sh` — the per-gate retry policy moved into a new
    sourced lib, `workflows/scripts/lib/gate-retry.sh`, which now (a) fails a
    gate fast, with **no** retry, when its output matches
    `GATE_DETERMINISTIC_PATTERN` (a static-lint finding signature); (b)
    short-circuits any gate whose failure output is **byte-identical** to its
    previous failed attempt, capping every deterministic gate at two attempts
    regardless of what it prints; and (c) spaces the retries that *do* fire by
    a graduated `GATE_RETRY_BACKOFF`-per-attempt sleep, instead of firing the
    whole budget back-to-back too fast to outlast any real transient. Every
    short-circuit is logged per-attempt and summarised beside the verdict.
  - `workflows/scripts/build/ci-poll.sh` — `gh_retry()` now inspects a failure
    before spending an attempt on it. One matching
    `CI_POLL_API_DETERMINISTIC_PATTERN` (a permanent HTTP 4xx / auth / argument
    error; HTTP 429 is deliberately excluded, being transient) dies immediately
    with a new `deterministic_failure: true` field rather than retrying. The
    closed `.outcome` set is unchanged.

  No default's value changed, and `GATE_MAX_ATTEMPTS=1` still disables gate
  retries entirely. `claude/workflows/build-level.mjs` gained a documented
  retry-loop inventory beside its budgets — each loop's cap plus either its
  classification step or a stated reason none applies — and
  `workflows/scripts/build/gate.sh` records the same for its single
  mergeability re-poll.

- **A `checks` gate now requires a `## [Unreleased]` entry from any change
  that touches contract surface (temperloop#960).**
  `workflows/scripts/check-changelog-entry.sh`, registered in
  `scripts/quality-gates.sh`'s `KERNEL_GATES`, fails a change that edits a
  contract-surface path but adds nothing under `## [Unreleased]`. This closes
  a hole in the pre-1.0 breaking signal rather than a tidiness gap: the
  downstream acknowledgment gate in `scripts/update-kernel.sh` /
  `bin/subcommands/update.sh` decides whether a pull needs an explicit
  `KERNEL_ALLOW_BREAKING=1` by scanning the CHANGELOG range for a `BREAKING`
  marker, and an entry that was never written cannot carry one — so a breaking
  change merged without a CHANGELOG entry shipped with that gate silently
  passing. At the v0.22.0 cut, 1 of 14 merged PRs had touched `CHANGELOG.md`.
  - **"Contract surface" is not defined twice.** The gate parses the
    backticked paths out of `VERSIONING.md` § The contract surface's own
    "Where it lives" column at run time, so adding a row there extends the
    gate for free; a table it cannot parse fails the run loudly rather than
    silently enforcing nothing. `VERSIONING.md` now says so beside the table.
  - **Opting out is explicit and reason-bearing, never inferred.** A
    genuinely non-shipping change opts out with the `no-changelog` PR label,
    a `Changelog: none - <reason>` line in the PR body, or that same line as
    a commit-message trailer (the channel that works before a PR exists and
    inside a merge queue). The reason is required — the point is that a skip
    is a recorded choice.
  - **Where it runs.** Inside the existing required `checks` job, never a
    second required status. In CI it enforces on the `pull_request` event
    only and prints a legible skip on `merge_group`/`push`, because the
    opt-out channels are absent from those payloads. With no resolvable diff
    base, or in a tree carrying no `VERSIONING.md`/`CHANGELOG.md`, it skips
    cleanly with a notice.
- **`workflows/scripts/lib/changelog.sh` gains `changelog_unreleased_body()`
  and `changelog_version_headings()`** — the Unreleased-section body
  extractor and the version-heading lister the gate above diffs across a
  change's merge-base and head (the latter is what lets a release cut, which
  legitimately empties `## [Unreleased]`, pass without an opt-out). Additive:
  the three existing helpers are untouched.
- **Six `CHANGELOG_GATE_*` rows in
  `workflows/scripts/config/setting-registry.tsv`** for the new gate's
  seams (`CHANGELOG_GATE_ROOT`, `_HEAD`, `_BASE`, `_PR_BODY`, `_PR_LABELS`,
  `_SKIP_LABEL`). New rows only — no column change, no existing default
  moved.

### Changed

<!-- Non-breaking changes only. The `### Changed — BREAKING` section below is
     the one `changelog_breaking_sections()` keys on; do NOT merge these two
     sections, and do NOT add ` — BREAKING` to this heading for a change that
     is not breaking. -->

- **`/build`'s machinery executors now run as a Bash-only `machinery-executor`
  agent instead of `general-purpose` (temperloop#1014).** temperloop#997 removed
  the prompt-cache TTL misses from the *worker*; the waste relocated to the
  mechanical agents that exceed the ~300s TTL **by construction** — the CI poll
  (waiting is its whole job) and the minutes-scale 3e.5 gate. Their post-wait
  call re-*writes* the whole context at weight 1.25 instead of re-*reading* it at
  0.1, so the excess is proportional to **context size**, not to the length of
  the wait. The new `claude/agents/machinery-executor.md` carries a Bash-only
  tool surface and the standing "run it verbatim, return each step's JSON line"
  contract the per-call prompt used to restate. Measured first-call
  `cache_creation`, same prompts and machine: **37,428 → 30,856** tokens for a
  CI-poll batch and **37,201 → 30,734** for the 3e.5 gate (−17.5%; −56% of the
  context that is not the installed CLAUDE.md, which the harness injects into
  every non-built-in agent and no agent definition can decline). Behavior is
  unchanged — same commands, same JSON, same Bash-tool timeout, same escalation
  branches — and a checkout that has not run
  `workflows/scripts/install/project-agents.sh` falls back automatically, once
  per run, to the previous `general-purpose` executor with its full prompt.

### Fixed

- **The `trust-rupture` lexicon category now has a named `/tidy` consumer
  (temperloop#1090).** `workflows/scripts/drain/lexicon.tsv`'s largest
  user-turn category — 19 patterns for user pushback and expressed doubt — was
  fully wired on the *extraction* side (declared in the header, allowlisted in
  `validate-lexicon.sh`, emitted into `report.lexicon_matches[]` every run) and
  consumed by nothing: zero hits in `claude/commands/`, and none of its tells
  appeared even implicitly in `tidy.md`'s illustrative lists, so the matches
  were computed and dropped on every drain. `claude/commands/tidy.md`
  § Feedback memories — semantically the right home, but four lines of prose
  with no lexicon anchor at all — now carries the same
  `report.lexicon_matches[]` adjudication instruction its sibling extractors
  have (§ Tooling friction's `friction-slug`/`state-collision`, § Unfiled
  defects' `worked-around-defect`, § Self-correction moments'
  `self-correction`), and routes the category's **three distinct failure
  modes** to distinct destinations: a *correctness challenge* to a
  `feedback_<topic>.md` memory; a *repeat-offence* to that memory **plus** a
  rule-promotion candidate via the existing `feedback` findings record that
  § Recurrence → promotion already tallies; and a *communication failure* —
  the "I don't understand" / "is jargon" subset — explicitly **out of scope
  and deferred to temperloop#1089**, so the two issues never claim the same
  tells. Default-to-silence is preserved (a stub with no pushback produces no
  artifact) and every artifact must carry the verbatim transcript line as
  evidence. Prose-only change to one command spec: no lexicon pattern was
  edited, no new friction-ledger category added, and no capture/backstop
  registry row is needed (the routing targets are all existing artifacts).

- **`build.md`'s five misattributed issue citations now name the right tracker
  (temperloop#733).** Five incident references in `claude/commands/build.md`
  carried a `temperloop#` prefix for issues that live on the **foundation**
  tracker — `#865` (combined-tree pre-check), `#1007` (workflow-reviewer as a
  required gate for `claude/commands/*.md` diffs), `#1150` (merge-queue silent
  dequeues / `diagnose-queue`), `#1241` (non-hermetic §3e.5 gate) and `#1055`
  (machine-local config leak). None of those numbers exist on the kernel
  tracker, so each pointed either nowhere or — as kernel numbering catches up —
  at an unrelated issue, which is the worse failure. Each is now `foundation#N`,
  verified against the live issue's own title rather than assumed; the
  surrounding citation markers already recorded them as `incident:F#…`, so the
  prose and the citation registry now agree. Prose only — no behavior change.

- **`build.md` §3e.5/§3e.6's acceptance-gate exit capture is now dialect-safe
  (temperloop#801).** The prior prose named only `${PIPESTATUS[0]}` — a BASH
  array — as the fallback when the gate is piped, but this harness's Bash
  tool executes through **zsh** on macOS, where the equivalent variable is
  `$pipestatus`, lowercase AND 1-indexed; under zsh `${PIPESTATUS[0]}`
  silently expands to the **empty string**, not the gate's exit code. A
  caller following the old prose literally reads that empty value as
  "not a failure" and passes a red gate through — the exact silent-red class
  (temperloop#68 / PR #309) the rule exists to prevent, reintroduced on this
  platform. Both sites now **prefer the un-piped form** (branch on the gate's
  direct exit — dialect-agnostic) and, where piping is unavoidable, name
  **both** `${PIPESTATUS[0]}` (bash) and `${pipestatus[1]}` (zsh) together
  with the platform caveat, rather than one bash-only variable. Cites the
  kernel's existing § Tool invocation discipline rule ("check the platform's
  dialect before leaning on a flag or regex feature"), which already covers
  this class. `claude/workflows/build-level.mjs`'s own §3e.5 invocation was
  checked and needs no change: it captures the gate's exit via a redirect
  (`>gateLog 2>&1`), not a pipe, so its `$?` reaches the gate's own exit
  cleanly on any shell. No other kernel prose site names `${PIPESTATUS[0]}`.

- **`/check-in`'s in-place `Status`-line rewrite now preserves (or restores)
  a pipeline surface's trailing newline (temperloop#853), the agent-plane
  half of foundation#1308 — the store-seam half (`ks_append`'s own
  fresh-line-on-append guarantee in `workflows/scripts/lib/knowledge_store.sh`)
  was already fixed there and stays separate, as recommended during
  `/assess --epic 1324`.** A plain substring `Edit` only touches the bytes
  it matches, so patching a `Status:` line that happened to sit at the
  literal end of the file — routinely true, since the entry being resolved
  is usually the newest, i.e. last, thing appended — left the file exactly
  as unterminated as it started. The next appender then glued its
  `### heading` onto the end of that same line instead of starting a fresh
  one, silently arming an entry no `^### `-anchored scan would ever match
  (observed at `Context/pipeline - pending decisions.md` line 344, written
  by check-in's own rewrite). `claude/commands/check-in.md`'s Part 2
  preamble now requires one cheap, idempotent check after **every**
  `Status`-line `Edit` in the command — `[ -z "$(tail -c1 "<file>")" ] ||
  printf '\n' >> "<file>"` — the same conditional idiom the store seam
  already relies on for the identical byte. Pinned by the new
  `workflows/scripts/tests/test_checkin_status_trailing_newline.sh`
  (registered in `scripts/quality-gates.sh` / `gate-paths.tsv`), which
  reproduces the exact corruption unguarded and proves the guard prevents
  it: restores a missing trailing newline, is a true no-op on an
  already-terminated file, and — composed with a subsequent append — keeps
  the new heading on its own `^### `-matchable line.

- **`temperloop init --no-network` no longer attempts a `git push`
  (temperloop#969).** The flag gated Step 2's first-epic offer and nothing
  else, so a run in a repo with no reachable remote still invoked
  `proposal-pr.sh` at Step 3: it force-created and switched to
  `foundation-init/config`, committed onto it, and only then died on the push
  with a raw `fatal: 'origin' does not appear to be a git repository` — exiting
  non-zero and never reaching the Step 4/5 summary + handoff. A stranger was
  left parked on an unfamiliar branch, with a git error and no recovery
  guidance, by a flag whose name promises the opposite. Step 3 now carries the
  **same `no_network` gate, in the same shape, as the Step 2 offer already
  did**: one `skipped — network disabled (--no-network): no proposal branch, no
  commit, no push, no PR …` line in the kernel degradation-notice form (wording
  aligned with `conventions-probe.sh`'s own network-gated skips), then the run
  continues and prints its summary and handoff normally. The skip is the
  **whole step**, not just the push — `proposal-pr.sh` has no commit-locally-
  but-don't-push mode other than its own `--dry-run`, which still performs a
  real local checkout + commit, so suppressing only the push would have fixed
  the error message while leaving the stranded-branch half of the report
  standing. The run's other network reach, the best-effort base-tip
  `git fetch`, is gated on the same flag for the same reason. **Behaviour
  change to note:** `--no-network` now means what it says end to end, so a
  caller that passed it merely to keep the first-epic offer quiet no longer
  gets a proposal PR — closed stdin (or `--no-first-epic`) is the way to
  suppress the offer alone. `test_init.sh` gains the reproduction as coverage
  (exit 0, neither raw git-push string, the notice, the summary + `next step:`
  marker, original branch and HEAD untouched, no `foundation-init/*` branch,
  zero `pr create` calls) plus two controls: the same skip fires in a repo that
  *does* have a remote, and dropping the flag still opens the PR.

- **`temperloop eject` now also cleans up a stray `foundation-init/*` branch
  on the REMOTE, not only locally (temperloop#967).** `proposal-pr.sh` commits
  and pushes the proposal branch *before* it ever opens the PR, so a run that
  dies at or after the push — a failed `gh pr create`, a killed process —
  could leave the branch sitting on the remote with no PR ever opened to
  record it in `.temperloop/config`'s `installs[]` (that entry is only folded
  in once the PR outcome is known). The `.temperloop/.recovery.json` marker
  `temperloop#414` added already restored the original branch and deleted the
  stray *local* copy on `eject`, but never touched the remote — so a run that
  died after a successful push left a genuinely orphaned branch on the
  adopter's own GitHub repo that no `eject` run would ever remove.
  `restore_original_branch()` now also makes a best-effort `gh api --method
  DELETE .../git/refs/heads/<branch>` attempt against the remote, gated by the
  same `--no-network`/resolved-`gh_repo`/`gh`-availability checks every other
  API-state revert in this script already uses, and never treated as fatal on
  its own (a "nothing there" skip is the common, harmless case — the push
  itself failing, not landing at all). Both `eject.sh`'s own uninstall bullet
  (scope (c)) and `bin/README.md`'s Uninstall table now name this branch
  scope explicitly, local and remote, instead of leaving it implied by "a
  proposal PR." `test_eject.sh` gains an end-to-end repro: a real `init` run
  against a real bare-upstream fixture whose push genuinely lands but whose
  (stubbed) `gh pr create` fails, asserting the branch really is on the
  upstream beforehand and that `eject` reports and calls the remote deletion,
  in addition to the existing local-only recovery coverage.

- **A parked item's claim stamp no longer strands on an open issue —
  `release.sh` clears its own, and `reconcile.sh --labels` sweeps the rest
  (temperloop#979).** On the issues-only backend, parking a claimed item back to
  Ready left a live `fnd:host/session:<host>:<sess8>` label on the open issue,
  and NOTHING swept it: `release.sh` was local-only (no `host/session` or
  backend awareness at all) and `reconcile.sh --labels` classes (g)/(h)/(j) are
  scoped to closed issues or to label objects with zero open-issue attachments —
  so the item read as claimed by a session that is gone while both the release
  path and the reconcile sweep reported success (reproduced on foundation#1483).
  Both halves of the issue's fix landed. **`release.sh`**, when passed BOTH an
  `<issue#>` and `--board <N>`, now also clears that stamp via
  `board_stamp <item> Host/Session ""` — the adapter's one existing clearing
  implementation, never a second label-strip path — behind four deliberate
  guards: issues-only backend, item **not In Progress** (an In-Progress stamp is
  a live claim HELD until Done, K#275 — left in place with a notice), **this
  session's own** stamp only (a foreign stamp is reported and routed to
  `reconcile.sh`, so a peer's in-flight claim — the owner is stamped *before*
  the status flips — can never be erased), and never changing `release.sh`'s
  exit status (a park must never fail on a release; every board-side failure
  degrades to a stderr notice). The board half runs **before** the marker half,
  so neither the expected K#275 non-latest refusal nor an absent marker on a
  headless run can suppress it. Without `--board`, behaviour is byte-identical
  to before — zero `gh` calls — so `/build` 3h's `release.sh <n>` is untouched.
  **`reconcile.sh --labels`** gains class **(m)**: a `fnd:host/session:*` label
  on an OPEN issue whose `fnd:status:*` is not in-progress — reported by
  default, stripped by `--apply`, with the same immediate per-issue re-check
  every other class uses (still open, still labeled, still not In Progress, so a
  re-claim or close landing in the scan→apply gap is never undone). It reuses
  the existing open-issue bulk read (zero extra `gh` calls) and the now-shared
  `_label_reconcile_strip_rows` helper, never deletes the label OBJECT (still
  class (g)'s job), and records its count in the `--unattended`
  pending-decisions entry. This is the more robust half by construction: it
  catches the drift whether or not anyone ran `release.sh`.

- **`/build` now detects the backgrounded-quality-gate stall mechanically and
  auto-resumes the worker on its own worktree (temperloop#993).** A worker that
  ran `scripts/quality-gates.sh` in the background and yielded its turn was
  reaped before the gate finished: it returned real work on disk, ZERO commits
  and no verdict block (observed twice in one run — #982 with 8 modified files,
  #983 with 3). The `#1219` prose clause in the worker prompt is prevention only,
  and prose rots, so it is now paired with a machine check that needs no worker
  cooperation. `pr.sh recover-probe` splits its stage-0 bucket: **`RECOVER_DIRTY`**
  (no verdict, worktree dirty, zero commits, no PR) is now distinguished from
  `RECOVER_NONE` (nothing anywhere), and `dirty` / `dirty_files` ride every probe
  outcome. On `RECOVER_DIRTY`, `build-level.mjs` auto-resumes the item on the
  **same worktree** — the only inheritable context, since the harness has no
  resume-this-agent seam — with the foreground cure plus a dirty-resume note
  naming the uncommitted file count and telling the worker to read
  `git status`/`git diff` and continue from that work rather than rebuild it.
  If the resume still returns no verdict with the tree still dirty, the
  `worker-error` escalation payload carries `shape: "foreground-stall"`,
  `dirty_files` and `worktree`, so the escalation's **skip** option (which prunes
  the worktree) can no longer destroy uncommitted work unseen. `RECOVER_NONE`
  keeps its unchanged one-retry-then-escalate handling.

- **A `/build` acceptance-gate TIMEOUT is no longer reported as a gate FAILURE,
  and the gate's budget is now a named setting rather than a hardcoded literal
  (temperloop#1021).** `claude/workflows/build-level.mjs`'s §3e.5 gate carried a
  single flat `480_000ms` Bash-tool timeout for the whole `scripts/quality-gates.sh`
  suite. Once the gate list outgrew it, every drive on this repo SIGTERM'd the
  suite mid-run and escalated `acceptance-gate-failed` — on a tree whose suite,
  re-run uncapped, was green. Two defects in one: the wasted round-trip, and
  (the dangerous half) an escalation payload that could not be told apart from
  real breakage. **This was a recurrence:** temperloop#115 already raised the
  same number once, `2min → 8min`, for the same failure, and it decayed again —
  so a third raise is the patch already known to fail, and it is not even
  available, since the executor agent's ~10-minute Bash ceiling cannot be
  raised. Three changes. **(1)** A budget-exhausted run gets its own outcomes
  (`GATE_TIMEOUT` / `GATE_SLICE`) and its own escalation kind,
  `acceptance-gate-timeout`, whose payload states that the suite's verdict is
  UNKNOWN; the `runMachinery` executor prompt now names `GATE_TIMEOUT`
  explicitly, so a killed run stops being narrated as the nearest
  failure-shaped outcome. A genuinely red suite still escalates
  `acceptance-gate-failed`, unchanged. **(2)** `scripts/quality-gates.sh` gains
  a SLICED mode (`QUALITY_GATES_START_AT` / `QUALITY_GATES_BUDGET_SECS`, an
  exit-75 partial protocol and `QUALITY_GATES_RESUME_AT=` /
  `QUALITY_GATES_FAILED=` markers): it runs gates until its budget is spent,
  stops cleanly *between* gates, and reports where to resume, so the driver
  loops slices and total suite runtime is no longer bounded by any one Bash
  invocation. Growth therefore can no longer manufacture a false failure — the
  decay path is closed structurally, not deferred to the next raise. **(3)** The
  budget becomes the named setting `BUILD_GATE_SLICE_SECS`, registered in
  `setting-registry.tsv` and handed to the Workflow runtime by `build.md` /
  `fix.md` / `sweep.md` Step 0 as `input.gateSliceSecs` (the same hand-off
  `machinerySoloModel` uses, for the same reason: the Workflow runtime has no
  shell to source `build.config.sh`), clamped so no value can push the derived
  Bash timeout past the agent cap. Green runs now report elapsed time and slice
  count — the decay signal the bare number never had. Backward compatible in
  both directions: the two `quality-gates.sh` knobs are ENV VARS, so a consuming
  repo vendoring an older copy ignores them and runs the whole suite exactly as
  before, and a caller that omits `gateSliceSecs` lands on the `.mjs`'s in-file
  default.
- **`temperloop eject` no longer deletes a hand-authored
  `.temperloop/pricing.json` (temperloop#985).** Previously `eject` removed
  the whole `.temperloop/` directory unconditionally at all three of its
  removal sites (partial-init residue, an empty install manifest, and a
  fully resolved revert) — including a `pricing.json` price table an
  operator maintains by hand for `temperloop report`'s directional dollar
  line, even though nothing in `eject`'s install-manifest model ever
  produced that file. `pricing.json` is now preserved, byte-identical,
  across every one of those three removal paths, and `eject` prints one
  line naming the file it kept; with no `pricing.json` present, behavior is
  unchanged. `temperloop uninstall`'s eject reminder is updated to match —
  it now also names the `report.d/tokens` producer shim (removed by
  `eject`, same as before) and states explicitly that `pricing.json` is not
  among what `eject` removes. See `docs/features/telemetry.md` § Removal
  for the full disposition, including the honest scoping of "no residue" to
  an unmerged proposal PR.

- **`--remote` is validated before it reaches `git` in `temperloop init` and
  the proposal-PR generator (temperloop#996).** `--remote` parsed unvalidated
  in both `bin/subcommands/init.sh` and
  `workflows/scripts/proposal/proposal-pr.sh` and was then spliced into
  `git fetch "$remote" "$base"` as that call's **first positional** — the
  position git parses as an *option* whenever the word begins with `-`. A
  value like `--upload-pack=touch /tmp/PWNED; git-upload-pack` therefore
  EXECUTED at the fetch: the same injection the earlier `--base` guard
  (temperloop#413-era) closed on the *other* argument of the very same
  command, left open on this one. `--remote` is documented CLI surface
  (VERSIONING.md's CLI-surface row) that adopter wrapper scripts and CI jobs
  pass, so the value is not always a human's own keystroke, and downstream
  refusal was not a guard — `proposal-pr.sh` did reject the name, but only
  *after* `init`'s own fetch had already run it. Both scripts now refuse an
  option-shaped or otherwise malformed `--remote` **at parse time**, strictly
  before the first git invocation that consumes it (`init` exits 2;
  `proposal-pr.sh` emits its usual structured `ERROR`). A valid `--remote` is
  unaffected. Tests in both suites assert the *ordering*, not merely the
  refusal: the payload's marker file must never appear and no proposal branch
  may be cut.

- **`proposal-pr.sh` now lands every file it proposes newline-terminated
  (temperloop#992).** Both manifest readers are `$(…)` captures, and command
  substitution strips *every* trailing newline — so a bare `printf '%s'` at
  the single write site wrote each file with **no** final newline, whatever
  the manifest said. An adopter's very first `temperloop init` PR therefore
  showed `\ No newline at end of file` on every file in the diff
  (`.temperloop/config`, `boards.conf`, and — since temperloop#984 —
  `.temperloop/report.d/tokens`): harmless to execution, but the first
  impression the install path makes. The write is now **normalized to exactly
  one** trailing newline, so a `content` of `"a"`, `"a\n"`, or `"a\n\n\n"` all
  land identically and callers neither need nor should hand-append one. Two
  deliberate edges: **empty content still lands as a 0-byte file** rather than
  a lone newline (git reports no missing-newline marker for an empty blob), and
  a source ending in several blank lines has them collapsed to one — which is
  why `init`'s carry-forward line still claims "content and mode preserved"
  rather than "bytes". `NO_CHANGES` is unaffected in mechanism (still
  `git diff --cached --quiet` against the base tree) and strictly better in
  outcome: a base already carrying the correctly-terminated file now compares
  equal instead of manufacturing a one-byte diff on every re-run — asserted
  both ways in `workflows/scripts/proposal/tests/test_proposal_pr.sh`, and
  `test_init.sh`'s landed-shim check is tightened from a newline-stripping
  `$(…)` comparison to a byte-exact `cmp`. **One-time adopter effect:** a repo
  whose files were placed by an earlier `init` sees a one-byte diff per file on
  the next run, adding the newline that should always have been there.

- **`/build` and `plan-schema.md` now state the `<repo-root>` default the SAME
  way — the plan's home repo, never assumed to be the launch checkout
  (temperloop#835).** `build.md` 3b claimed the default was "the plan's own
  checkout (the orchestrator's parent tree)" while `plan-schema.md`'s `repo:`
  field (twice) already read "absent = the plan's home repo" — a genuine
  disagreement, not a wording nit: the parenthetical is only true when
  `/build` happens to run *from* the plan's home checkout, and the live
  incident this fixes (building `Plans/2026-07-27 temperloop - session-start
  context measurement`, epic #810, from a **foundation** session) had to be
  resolved by hand on 2026-07-27 because nothing in the doc said the home
  repo could differ from cwd. `build.md` 3b now drops the parenthetical and
  points at a new Step 0 resolution (folded into the existing board-probe
  item 5, no new numbered step): when the plan frontmatter carries `epic:`,
  `/build` resolves the epic's actual home repo by probing each registered
  board (`board_resolve_item` per board, then `board_repo`), and if it
  differs from the launch checkout's own repo, prints one `NOTE:` at run
  start — the same legibility bar Step 0's build-machinery-staleness check
  already sets. **Not a hard block:** cross-checkout invocation is legitimate
  (a plan can be built from any session) and the existing per-item `repo:`
  honor point (3b) already handles routing an item to a different checkout
  when set.

- **`/build`'s default Workflow path now qualifies a cross-repo item's
  `Closes` line, matching the conversational path (temperloop#852).**
  `claude/workflows/build-level.mjs`'s 3f pr-open call passed an item's
  `gh_issue:`/`also_closes:` numbers to `pr.sh --gh-issue`/`--also-closes`
  **verbatim**, always as bare digits — so an item whose `repo:` field routed
  its PR to a *different* repo than the plan's home (the kernel-classified-item
  case: a foundation-triaged issue, work landing in `Towheads/temperloop`)
  emitted a bare `Closes #N` into that PR. GitHub's `Closes #N` is same-repo
  only, so the home-repo issue never closed — silently, since the PR still
  merged clean. build.md 3f's own "Cross-repo `repo:` honor point" already
  documented the fix (pass the fully-qualified `owner/repo#N` form) for the
  conversational path; the Workflow path just never implemented it. Fixed at
  the one call site that knows both repos: when `item.repo` is set and differs
  from the level's `ownerRepo` (the plan's home repo — where the issue is
  tracked, since `gh_issue:` normally lives wherever the item was triaged),
  both flags now qualify each number as `<ownerRepo>#<N>` instead of bare;
  `pr.sh` itself needed no change — its `closes_line()`/`validate_issue()`
  already accept either shape. A same-repo item (no `repo:`, or `repo:` equal
  to `ownerRepo`) is unaffected — bare `Closes #N` exactly as before. Covered
  by a new `workflows/scripts/build/tests/test_workflow.sh` case pinning both
  the bare and qualified forms in one level.

- **`board_owner()` now fails legibly, instead of silently borrowing this
  kernel checkout's own org, for a `boards.conf` board that sets `repo=` or
  `project=` but omits `owner=` (temperloop#798).** Any board id outside the
  built-in 3-6 case map (an adopter's own board) fell through `board_owner()`'s
  `*)` branch to `$BOARD_OWNER` — this repo's own `"Towheads"` — whenever the
  adopter's `boards.conf` entry forgot the `owner=` line, so `gh project …
  --owner Towheads` silently targeted a **foreign org's project** instead of
  erroring: a cross-tenant misdirection with no diagnostic. `board_owner()` now
  checks whether the board actually has a `repo=`/`project=` entry in
  `boards.conf` before falling back; if it does and `owner=` is still missing,
  it prints `board.sh: board N sets repo=/project= in boards.conf but no
  resolvable owner= …` to stderr and returns non-zero instead of guessing. A
  board with **no** `boards.conf` entry at all (repo, project, and owner all
  absent — e.g. board 7, the temperloop tracker itself, whose repo/backend
  come from the built-in maps per #808) is unaffected and still resolves
  `$BOARD_OWNER` exactly as before. `board_project_number()`'s sibling
  `*) echo "$1"` identity fallback is deliberately left ungated — its own
  updated comment names why (a same-tenant wrong-project-number risk, not the
  cross-tenant misdirection `board_owner()` guards against) and its failure
  mode. Pinned by two new cases in `test_boards_conf.sh`. Not breaking: no
  correctly-configured `boards.conf` entry changes behavior — only a board
  that was already misconfigured (repo=/project= with no owner=) now fails
  instead of silently doing the wrong thing.

### Fixed

- **`install-claude-md.sh`'s `INSTALL_CLAUDE_MD_KERNEL_ONLY=1` render arm no
  longer leaks a `t0` tmpfile per invocation (temperloop#742).** That arm
  moves `$tmp` to `$target` but never consumes `$t0_tmp` (T0 is deliberately
  not written on a kernel-only render — its scope is the fully composed doc),
  and the script's final `trap - EXIT` clears the cleanup trap before exit
  without removing it, so every kernel-only render — the seam
  `count-prose.sh` calls for its tier-1 count — left one empty
  `install-claude-md-t0.XXXXXX` in `TMPDIR`. Verified at filing time: 6
  leaked files across one `test_validate_prose_budget.sh` run. Fixed with an
  explicit `rm -f "$t0_tmp"` on that arm, right after the `$target` move —
  same shape as the arm's existing explicit `rm -f "$target"` before its own
  move, not the temperloop#753 subshell-defeated-trap fix (that one restored
  a lost `EXIT`-trap visibility across a command substitution; here the trap
  fires correctly, it is just cleared before it can act on a file this arm
  never claims). The composed (non-kernel-only) arm is untouched. Verified
  with 5 consecutive kernel-only renders leaking 0 files (was 1 each), and
  `test_install_claude_md_t0_inventory.sh` / `test_validate_prose_budget.sh`
  staying green.

## [0.23.0] - 2026-08-02 — BREAKING

### Migration — read this first

One migration, and it is narrow: **`/build`'s Step 3 within-level loop now runs
the per-level Workflow path by default.** If you drive `/build`, or your overlay
documents its conversational two-sweep orchestration, read
`### Changed — BREAKING` below before pulling. Pass **`--no-workflow`** to keep
the previous behavior. Everything else in this release is additive or a fix.

**Who has to act.** Only an operator, wrapper, or overlay that depends on
`/build`'s Step 3 running conversationally — most concretely anyone relying on
**speculative next-level execution**, which is a conversational-path-only
NON-GOAL under the Workflow path and is therefore now off by default. Nothing
else moves: `--workflow` is still accepted (it now selects the default and is a
no-op), the board adapter interface, hook names and signatures, the `checks`
gate contract, `bin/temperloop`'s subcommand set, the `.kernel-pin`/compose
seam, and the setting-registry row shape are all untouched — and no setting
default changed, because the flip lives in the command spec, not in
`build.config.sh`.

### Release classification for the remaining epic-#923 items — MINOR

The `workshop collaborative decision walk` epic (temperloop#923) shipped its
first nine items in **0.22.0, marked BREAKING** — `/workshop`'s coverage walk
lost its minimal-interaction path under a hard cutover. Its **two trailing
items classify MINOR**, and the aggregate call for the epic therefore stands at
BREAKING on the strength of 0.22.0 alone; nothing below adds to *that epic's*
call. (The release-level `BREAKING` on the `## [Unreleased]` heading above comes
from a different change — the `/build` workflow-path default flip, temperloop#998
— not from these two items.)

Why these two are MINOR: the new ratify gate is satisfiable by every brief that
walks normally (the seeded-dimension rule gives dimensions 0, 1 and 3 their
`walk` verdict from Step 1's own confirms), and the migration carve-out exempts
every brief authored before the record existed. **No adopter config changes and
no existing brief is invalidated** — which is the test `VERSIONING.md` applies.

### Added

- **`report.d` producers gain a `notice` string-field channel, and
  `report.sh`'s stderr-discard behavior is now documented
  (temperloop#981).** Any `.temperloop/report.d/` producer's stdout may
  optionally parse as a JSON object carrying a string `notice` field; when
  present, `report.sh` renders it as its own line under that producer's `--
  report.d/<name> --` heading, alongside its normal verbatim stdout. This is
  the first documented way for a drop-in — the `tokens` producer's planned
  first-run disclosure (epic #972) being the motivating case — to address a
  human without colliding with the `tokens` name's stricter
  `tokens_spent`-only JSON rule; it is a contract-level field, not a
  `tokens` special case, so any current or future producer can carry one.
  `report.contract.md`'s "Overlay drop-in contract" section also now states
  explicitly that `report.sh` discards every producer's stderr and never
  inspects it — always true, previously undocumented, and exactly the trap a
  producer writing to stderr for a human's benefit fell into. Additive, for
  the `notice` half of this change specifically: existing producers with no
  `notice` field render exactly as before. (The companion `jq`-exit-status
  fix below is a separate change with its own, narrower behavior delta — see
  that entry.)
- **`/workshop` Step 4 gains check 4.1c — challenge-record completeness at
  ratify (temperloop#934).** Runs after 1b and gates the ratify ask, so ratify
  becomes the terminal act of the walkthrough. It enforces exactly the two
  rules in `claude/design-schema.md` § Record completeness **by reference, never
  by restatement**, so the in-session gate and `validate-design-brief.sh`'s
  check (C) cannot drift: every kernel dimension 0..16 carries at least one
  `walk` stop line, and every `operator-edited` stop line carries its verbatim
  `response:` field. The migration carve-out is semantically identical to the
  validator's — a `ratified` brief with no `### Challenge record` at all is
  exempt and never flagged, keyed on a per-brief `status:` signal rather than a
  global version flip; a draft or dropped brief is never held to either rule.
  The record-start-marker-present-but-empty defect is independent of status and
  applies regardless, which is the loophole that stops a crashed walk from
  masquerading as a migration case.
- **Pipeline spend profiler + the `.temperloop/report.d/tokens` drop-in
  producer (temperloop#958).** New `workflows/scripts/pipeline-spend-report.sh`
  — a cost-weighted spend profiler over Claude Code workflow-agent transcripts,
  with `--since` / `--until` / `--run` / `--root` / `--format json` / `--top` —
  plus the `tokens` producer that gives `temperloop report` a live
  `tokens_spent` headline. Validated byte-exactly against the #953 reference
  corpus: over the same 1,622 agents it reports 180,608,852 weighted units
  (the 180.6M baseline exactly) and 2.16x undeduped inflation (390,212,000 →
  180,608,852, matching #953's figure to the digit), splitting machinery 31.8%
  / item workers 68.2%. Note **two** call-count thresholds, not one:
  `SPEND_MACHINERY_MAX_CALLS` (6) drives the machinery-vs-worker attribution
  split, and `SPEND_WORKER_PROFILE_MIN_CALLS` (40) is a separate, higher floor
  for the typical-worker profile — a single threshold provably cannot produce
  both stated baselines.
- **Four plan-less model-tier literals are now named settings
  (temperloop#982).** `SWEEP_WORKER_MODEL` and `FIX_WORKER_MODEL` join the
  Named-setting shell seam in `build.config.sh` (read symbolically by
  `sweep.md` and `fix.md` Step 0.4); `BUILD_MACHINERY_SOLO_MODEL` and
  `BUILD_MACHINERY_BATCH_MODEL` ride the **orchestrator→workflow input** seam
  instead — resolved at `build.md` Step 0 and passed as
  `machinerySoloModel` / `machineryBatchModel`, because a config-file read is
  structurally impossible inside the Workflow runtime (no filesystem, Node, or
  shell — DESIGN NOTE 1). **No default moves:** the `'haiku'` literal remains
  at both `build-level.mjs` sites as the absent-input default, and the fallback
  uses `||` rather than `??` so an empty-string input collapses to the default
  too. Model selection is byte-identical when nothing is set, which is what the
  MINOR classification rests on.

- **`temperloop init` now proposes the `tokens` `report.d` producer shim
  (temperloop#984).** A fresh `init` run's existing proposal PR now also
  adds `.temperloop/report.d/tokens` (mode `755`) alongside its other tree
  changes, so a newly adopted repo gets `temperloop report`'s
  `tokens_spent` headline without a manual step; a repo that already has a
  producer at that path is left alone. See `docs/features/telemetry.md` §
  "Token spend" for what the shim does once in place.


### Changed — BREAKING

<!-- The `BREAKING` token appears TWICE for this release on purpose — on the
     `## [Unreleased]` heading above AND on this `### Changed` sub-heading.
     `changelog_breaking_sections()` (workflows/scripts/lib/changelog.sh) sets
     its `brk` flag ONLY from a heading line: `$0 ~ /BREAKING/` on the
     `## [x.y.z]` line, or `/^#+ .*BREAKING/` on a sub-heading. BODY TEXT
     NEVER SETS IT. The sub-heading marker is the belt-and-suspenders half: it
     survives a release cut that rewrites `## [Unreleased]` into
     `## [0.23.0] - <date>` without carrying the ` — BREAKING` suffix across.
     Without at least one of these, scripts/update-kernel.sh's acknowledgment
     gate and bin/subcommands/update.sh's BREAKING warning both silently no-op.
     Do not strip either one when editing history. -->

- **BREAKING — `/build`'s per-level Workflow path is now the DEFAULT for Step 3;
  `--no-workflow` is the opt-out (temperloop#998).** `claude/commands/build.md`
  previously documented `--workflow` as **Default OFF**, so Step 3's
  within-level loop ran the conversational two-sweep orchestration unless the
  operator opted in. That is inverted: with no flag, Step 3 now runs the
  per-level Workflow (`claude/workflows/build-level.mjs`), and the new
  **`--no-workflow`** flag selects the conversational two-sweep loop.
  `--workflow` itself is **retained and still accepted as a no-op** — it now
  asks for what `/build` already does — so an existing invocation, wrapper, or
  muscle-memory command line that passes it explicitly does not break. The
  mechanics of the two paths are unchanged (`build-level.mjs` was not touched);
  both still call the same deterministic machinery scripts, and the orchestrator
  still owns Step 4, all plan-note writeback, and escalation resolution on both.
  **Why:** the Workflow path's batched machinery executors (temperloop#942) cut
  mechanical weighted token spend **32.8%** (468,283 → 314,801 units) and raw
  tokens **56.9%** on a 1-item level — worth **-6.6% per build level** — but
  because the path was Default OFF that saving reached only opt-in runs, so
  #942's shipped benefit was ~0% corpus-wide. Duration impact is ~1%: this is a
  token change, not a speed change. **Classified BREAKING** per `VERSIONING.md`
  — `claude/commands/*.md` is the "Pipeline command contracts" published
  surface, and a *default*-behavior change is breaking by that document's own
  test ("a downstream overlay or a stranger's config must change to keep
  working"): an adopter who changes nothing gets different orchestration, and
  must add a flag to keep the old one. **Migration:** append **`--no-workflow`**
  to your `/build` invocation (or your wrapper's) to keep the conversational
  two-sweep loop. Do this in particular if you use **speculative next-level
  execution** — cross-level speculative overlap is a documented
  conversational-path-only NON-GOAL under the Workflow path in v1, so flipping
  the default **disables speculative overlap by default**, and `--no-workflow`
  is the only way to get it back. Lifting that NON-GOAL is separate work and is
  still deferred past v1.

### Changed

<!-- Non-breaking changes only. The `### Changed — BREAKING` section above is
     the one `changelog_breaking_sections()` keys on; do NOT merge these two
     sections, and do NOT add ` — BREAKING` to this heading for a change that
     is not breaking. -->

- **Build workers no longer run the bare, repo-wide quality gate in their own
  context (temperloop#997).** The minutes-long blocking turn exceeded the
  ~5-min prompt-cache TTL and forced a full-context cache re-write — a 12.5x
  penalty measured at **4.84% of all workflow-agent spend**. The worker now
  runs a **path-scoped subset** via `quality-gates.sh --list`, for fast local
  feedback only and **explicitly labelled NOT the acceptance authority**;
  `/build` 3e.5's own bare, repo-wide gate run is untouched and remains the
  sole authority. Both worker surfaces moved in lockstep per `build.md`'s
  schema↔prose mandate (`build.md` 3c and `build-level.mjs`'s
  `workerPrompt()`), and new static guards in `test_workflow.sh` bind both
  directions — the ban must appear in *both* worker surfaces, and 3e.5 must
  still invoke the gate bare. Trade accepted: the alternative (re-spawning the
  worker on a parent-side red) pays its cost on every red, commonly a
  seconds-to-catch lint slip, whereas the cache miss was paid on every item.
- **The `/build` spine's progress row now names its run (temperloop#903).**
  `build-level.mjs`'s `phase()` title carried an item *count* and nothing else,
  so concurrent spine runs rendered identical rows in the progress UI — a
  single `/fix` session drove three indistinguishable `build-level`
  invocations. It now emits repo, count, and per-item slug + issue:
  `build level — Towheads/foundation · 1 item · migrate-off-legacy-funnel-names-1419 (#1419)`.
  Bounded to 3 named slugs with `+K more`; every segment optional-safe (a
  missing `ownerRepo`/`ghIssue` drops its own segment rather than rendering
  `undefined`); and set **after** the `onlySlugs` filter, so a continuation
  names the slugs actually being re-driven. `meta.description` — a
  runtime-enforced pure literal that can never carry run context — was
  rewritten operator-facing, dropping return-shape detail that already lives
  in the file's I/O CONTRACT header. The `{parked, escalations}` return
  contract and every per-agent label (`worker:<slug>`, `gate:<slug>`,
  `ci-poll:<slug>#<slice>`, …) are untouched.
- **Pre-merge CI gates on ubuntu only; macOS coverage moved to a nightly run
  (temperloop#963).** `ci.yml`'s `checks` job keeps its `strategy.matrix` — a
  single entry `os: [ubuntu-latest]` — so **the required status context stays
  exactly `checks (ubuntu-latest)`** and no branch-protection change is needed.
  New `.github/workflows/nightly-macos.yml` runs the same gate script on
  `macos-latest` (`schedule: "17 9 * * *"` — 09:17 UTC, ~02:17
  America/Los_Angeles under PDT — plus `workflow_dispatch`); its job context is
  `nightly-macos`, non-matrix, so branch protection cannot latch onto it, and a
  Verdict step writes a `$GITHUB_STEP_SUMMARY` block plus an `::error::`
  annotation on failure. **Trade stated honestly:** ubuntu gates merges, so a
  **BSD-dialect regression can now reach `main`** and is caught within a day
  rather than at the gate.

### Fixed

- **`report.sh` now checks `jq`'s exit status when parsing the `tokens`
  producer's `tokens_spent` field (temperloop#981).** Previously the parse
  only tested `[ -n "$parsed" ]`; on stdout that mixed a valid JSON document
  with extra non-JSON text, `jq` could emit output for the first valid
  document and still exit non-zero once it hit the invalid remainder — so
  trailing garbage after a clean JSON object "accidentally" still drove the
  tokens headline, while the same shape with the garbage leading instead
  produced no output at all and silently fell back to the kernel-tier
  headline. Both now require `jq`'s exit status to be `0`, so leading and
  trailing malformed stdout degrade the same, deterministic way — the
  kernel-tier headline, never a partial or inconsistent read. **Migration:**
  if your `tokens` producer emitted text alongside its JSON object, its
  headline will now fall back to the kernel tier — emit exactly one JSON
  object and move the text into `notice` (see the `notice` field entry
  above).
- **`walk`-only, not both verdicts — a superseded premise purged from the
  0.22.0 entry above (temperloop#934, temperloop#935).** The 0.22.0 entry for
  check (C) described it as requiring "**both** a `walk` and a `walkthrough`
  verdict" for every dimension. **That was never what shipped, and it is not
  satisfiable:** a dimension no review lens reached cannot acquire a
  `walkthrough` verdict, so the stated rule would deadlock every brief. The
  shipped validator emits `MISSING-WALK-VERDICT` and checks `walk` lines only,
  exactly as `design-schema.md` § Record completeness specifies
  (`walkthrough` coverage "stays opportunistic … and is never required for
  every dimension"). The 0.22.0 line is corrected in place with its prior
  wording quoted, rather than silently rewritten.

## [0.22.0] - 2026-08-01 — BREAKING

### Migration — read this first

One migration, and it is narrow: **`/workshop`'s coverage walk no longer has a
minimal-interaction path.** Two documented behaviors were deleted under a hard
cutover — the ad-hoc batch-approval grouping license, and Step 4's exemption
from persist-then-ask — so if you drive `/workshop`, or your overlay documents
a lighter-touch design walk on top of it, read `### Removed — BREAKING` below
before pulling. Everything else in this release is additive.

**Who has to act.** Only an operator or overlay that relied on `/workshop`
Step 2's "draft several dimensions, then ask once over the batch" shortcut, or
on the ratify ask skipping the persist-and-re-present step. Nothing else moves:
the board adapter interface, hook names and signatures, the `checks` gate
contract, `bin/temperloop`'s subcommand set, the `.kernel-pin`/compose seam, and
the setting-registry **row shape** are all untouched. Two setting *defaults*
changed (both prose-budget caps — see `### Changed`); no row was added, renamed,
or removed, so nothing that parses the registry needs to adapt.

### Added

- **`/workshop` gains `## Step 3.5 — Congruence pass + walkthrough`
  (temperloop#932).** A third pass between the review panel and ratify, in
  three parts: (1) a facilitator-run, **agentless and unconditional**
  congruence seam checklist applied by reference from `claude/design-schema.md`
  § Congruence seams — it runs even when every agent is unavailable, so a
  probe-less checkout still gets the cross-dimension consistency check; (2) a
  capability-probed `congruence-lens` spawn against exactly one document, whose
  skip takes the **remedy-bearing** degradation form (`skipped — <agent>
  available as source; run workflows/scripts/install/project-agents.sh to
  enable`) rather than a bare dead-end; and (3) a tier-mirrored walkthrough
  whose step count **derives from the schema's current dimension list**, never
  a hardcoded count, where every dimension — clustered or not — is individually
  listed, delta-flagged and individually verdicted (N verdicts per cluster
  line), with the `deferred → <ref>` time-boxing valve open to every
  non-premise dimension and closed to dimension 0. Step 3.5's findings dispose
  under Step 4.1b's **existing** folded / `deferred → <ref>` / declined
  vocabulary — one record, one vocabulary, one check, no second ledger. Step
  3.1.4 now also registers the cold-read lens in the same per-lens coverage
  record the 3.3 panel uses, so a skip is stamped into the artifact instead of
  only narrated. **For an adopter:** a `/workshop` run costs one more pass, and
  a checkout that has not run `project-agents.sh` is told how to fix that on
  the live line. New standing rules `W.17` (parallel-finding-ledger) and `W.18`
  (cluster-collapsed-verdicts) ship with matching citation-registry rows.

- **`congruence-lens` — a fifth read-only advisory review agent
  (temperloop#927).** `claude/agents/congruence-lens.md` reads **exactly one**
  target document per invocation and reports internal contradictions between
  its parts, quoting both passages verbatim and naming the seam they cross. Its
  charter frames it honestly as a **fresh-context textual-consistency check,
  not an independent-priors reviewer** — the operator remains the only
  independent reviewer, stated in the agent's own text so a reader cannot
  mistake its verdict for independent judgment. Registered in
  `docs/features/review-agents.md`, `docs/features/feature-manifest.txt` and
  `workflows/scripts/config/contributor-manifest.tsv`, and exercised against a
  new planted-contradiction fixture brief
  (`workflows/scripts/tests/fixtures/congruence-lens/`) by the real deployed
  agent, not a simulation. **For an adopter:** like every other kernel review
  agent it ships as *source* — it is available to `/workshop` Step 3.5 only
  after `workflows/scripts/install/project-agents.sh` installs it; until then
  the step degrades legibly rather than silently.

- **`claude/design-schema.md` gains two contract grammars — § Congruence seams
  and § Challenge record (temperloop#926).** § Congruence seams is a five-row
  **named-minimum** table of cross-dimension consistency pairs
  (`contract↔mechanism-shape`, `adoption↔problem-statement`,
  `acceptance↔testability`, `deferred-refs-resolve`, `cost↔scope`), explicitly
  a floor and not a ceiling, add-only in the same sense § Overlay extensibility
  already is. § Challenge record pins the verdict vocabulary (`accepted` /
  `challenged → revised ×N` / `operator-edited`), the per-stop line grammar,
  the `walk` vs `walkthrough` kind discriminator, the verbatim `response:`
  field, the `challenge-record-start: <date>` marker with **both** readings of
  its absence (no section at all = nothing recorded yet; marker present with
  zero stop lines = a defect), and its home section `## Working notes`. It also
  resolves a gate-satisfiability deadlock outright: a Step-1-seeded dimension's
  (0, 1, 3) Step-1 confirm **counts as** that dimension's `walk` verdict
  (`source: step-1-seed`) — without which every brief would fail the completeness
  check below. Six stale "temperloop#216, forthcoming" sites were corrected to
  the shipped `validate-design-brief.sh`, being precise about what it does and
  does not yet check rather than overclaiming, and § Overlay extensibility's
  class-level override claim was narrowed so it no longer reads as an
  invocation of `message-schema.md`'s named-template carve-out. **For an
  adopter:** an `design-schema.overlay.md` dimension list is unaffected (the
  add-only rule is unchanged); briefs written before this release carry no
  challenge record and stay exempt — see check (C) below.

- **`claude/message-schema.md` gains `### Decision presentation`, and a
  **non-overridable** template set that CI enforces (temperloop#928).** The new
  mode-6 template pins the five required parts of any decision put to the
  operator — the decision in plain terms, the proposed answer, the reasoning,
  the alternatives and why they lost (with "none considered" named as a
  legitimate value), and what accepting it constrains downstream — under a
  governing plain-language rule. Because those parts *are* a challenge gate, a
  redeclaration could hollow the gate out, so the template is excluded from the
  overlay-override surface — and the exclusion is **mechanical, not prose**:
  `workflows/scripts/validate-template-refs.sh` now carries
  `NON_OVERRIDABLE_TEMPLATES`, tests it **before** the canonical-name check
  (the order is load-bearing — reversed, an excluded name reports `ok`), and
  self-checks that every excluded name is still a template `§ Templates`
  defines, so a rename in the doc reds CI instead of silently disarming the
  exclusion. `CLAUDE.kernel.md`'s § Kernel vs overlay routing rule carve-out is
  qualified to match ("most of them, not all"), and a 219-line test suite plus
  a `quality-gates.sh` entry ship with it. **For an adopter:** an overlay that
  redeclares `### Decision presentation` in its own message-schema overlay now
  fails the `checks` job. **Deliberately not tagged `BREAKING`** — the
  exclusion set currently holds exactly one name, and that name is the template
  introduced in this same release, so no existing overlay can already have
  redeclared it; the contract-surface shrink is vacuous in practice. Adding a
  *pre-existing* template name to that set later would be breaking and must be
  marked as such.

- **`validate-design-brief.sh` check (C) — challenge-record completeness, in CI
  (temperloop#929).** The record is now enforced by the validator, not only by
  `/workshop` at ratify time: every dimension must carry a `walk` verdict
  (`walkthrough` coverage stays opportunistic and is **not** required per
  dimension — corrected below under Unreleased; this line originally read
  "both a `walk` and a `walkthrough` verdict", which never shipped),
  verdict lines must match the § Challenge record
  grammar, and an `operator-edited` verdict must carry its verbatim `response:`
  field. The grammar is **read from** `design-schema.md` § Challenge record,
  never re-encoded locally — the same discipline checks (A) and (B) already
  apply to the dimension list and the disposition grammar, so the schema stays
  the single source of truth. **Migration carve-out for existing briefs:** a
  brief with no `### Challenge record` subheading is **exempt at any status**,
  implemented as a per-brief signal rather than a global flag — so every brief
  authored before this release passes untouched, and only briefs that already
  have a record are held to it. Seven fixtures (complete / empty / bad-grammar
  / missing-response / draft-partial / migration-exempt / walk-missing) lock
  both verdicts, including the negative state that closes the loophole the
  record-start marker exists for.

- **`/tidy` Step 3 gains the `### All-accepted-untouched briefs` sweep
  (temperloop#933).** The drain now reads each ratified brief's challenge
  record and flags any brief whose coverage-walk stops are **all** bare
  `accepted` — zero `challenged → revised`, zero `operator-edited` — to the
  pending-decisions surface for `/check-in` to dispose. The tell it is after:
  a walk that never actually engaged the operator looks identical to a walk
  that converged, except in the record. Registered as a Capture/Backstop pair
  in `tidy.md`'s own kernel registry table (capture anchor: `workshop.md`
  § `Step 2 — Coverage walk`), so `validate-capture-backstop.sh` fails the
  build if either half is ever removed alone. **For an adopter:** one new
  `### open` entry class appears on the pending-decisions surface; nothing
  else changes.

- **`pr.sh recover-probe <worktree> <branch>` — a read-only staged
  side-effect probe (temperloop#939).** A new subcommand on the shipped
  `workflows/scripts/build/pr.sh`, additive to its CLI surface: it walks a
  three-stage ladder — commits ahead of base (`git rev-list --count`), branch
  present on origin (`git ls-remote --heads`), open PR for the branch
  (`gh pr list --head`) — and reports the furthest stage reached as a closed
  `RECOVER_*` outcome. It writes nothing. Its consumer is the recovery path in
  `### Fixed` below, but it stands on its own as the deterministic answer to
  "did this worktree's work actually land?" Five new `test_pr.sh` cases cover
  every rung.

### Changed

- **`build-level.mjs` batches its mechanical machinery calls instead of
  spawning one agent per shell command (temperloop#942).** The `--workflow`
  path wrapped EVERY mechanical step in its own `agent({schema})` executor: a
  measured L0 level of 3 items spawned **40 agents** (3 real workers + 37 haiku
  micro-agents), each paying ~160K cache-read tokens and 4 API round-trips to
  run one shell one-liner — including 7 separate `ci-poll.sh` spawns and 8
  separate `gh pr view` merge-state spawns at one level. Mechanically-adjacent
  steps now ride ONE executor each via the new `runMachineryBatch()`:
  `prelude:<slug>` (claim + deps-merged + worktree create), `pr-batch:<slug>`
  (rebase + scan + push + pr-open), and `ci-batch:<slug>#n` (the interleaved
  merge-state probe + CI poll slices). The same L0 shape now costs **15 agent
  spawns** (3 workers + 4 machinery executors per item). The 3e.5 quality gate
  deliberately stays a solo call — its own runtime is minutes-scale (measured
  6:05 for this repo's suite), so batching it would put a single Bash
  invocation within reach of the executor's ~10-minute cap.
  **No behavior change:** the batched executor returns `{results:[…]}` — one
  closed-outcome JSON object per step that ran — and every branching decision
  (`SCAN_BLOCKED`, `PUSH_REJECTED`, `REBASE_CONFLICT`, `CI_GREEN`/`CI_FAILED`/
  `NO_CI`/`TIMEOUT`, `DEPS_MERGED`, `CLAIM_CONFLICT`, `GATE_FAIL`, `EXISTS`,
  the `RECOVER_*` ladder) still lives in legible `.mjs`, never in an agent
  prompt; the bash short-circuit is only a stop-early mirror of those branches.
  DESIGN NOTE 1's bridge contract and DESIGN NOTE 2's CI-poll cap are updated in
  the file header, and the cap is now enforced **arithmetically**:
  `CI_POLL_SLICES_PER_BATCH` is derived from `CI_POLL_MAX_BATCH_WALL_MS`, so no
  retuning of the slice length can produce a batch that outlives the Bash cap.
  Six new `test_workflow.sh` cases lock the reduced spawn count, the prelude
  batching, the CI-poll reuse, the cap invariant, the `sq()` quoting of every
  batched argument, and the in-`.mjs` legibility of every branch.

- **`/workshop` Step 2 is now a collaborative, challenge-driven coverage walk
  (temperloop#930, temperloop#931).** The walk is collaborative *by
  construction*: every decision that reaches the brief is presented with its
  reasoning and can be contested before it is recorded, and the operator's
  speed lever is how fast they accept at each stop — never whether content is
  shown. Four structural changes. **(1) A tier-split proposal is the walk's
  first stop and its first challengeable decision**: it names which dimensions
  are load-bearing (own stop) and which are mechanical (clustered 2–4 to a
  stop, every dimension's full content still shown — a cluster compresses the
  *asking*, never the *showing*), states the **total stop count** it commits
  the session to so the operator can time-box against it, and assigns **every**
  dimension a tier including the Step-1-seeded 0, 1 and 3, whose
  confirm-or-challenge stop records a real `walk` verdict with `source:
  step-1-seed`. Leave those out and the problem statement and the routing call
  are the only calls in the brief the operator never formally accepted.
  **(2) Every stop is presented by reference to `message-schema.md`'s
  **Decision presentation** template**, never a restated local copy — and
  Step 1.3b(iii)'s premise-gate ask is re-pointed at the same template
  (temperloop#931), so the two gates cannot drift apart. **(3) A bounded
  challenge loop**: rounds one through three fold in and re-present freely; a
  fourth does not loop, it escalates to an explicit operator fork — accept
  as-is, `deferred → <tracking ref>` (never available for dimension 0), or park
  the walk with the brief left `status: draft` and a later run resuming from
  the persisted record. A non-converging stop is a visible operator choice, not
  an invisible grind. **(4) Per-stop challenge-record appends** applied by
  reference to `design-schema.md` § Challenge record, with one verdict **per
  dimension** on a clustered stop and the record-start marker written in the
  same write as the first stop line. The hardcoded 17-dimension count is gone —
  the walk's size is the schema's list as it stands. **For an adopter:** the
  interaction shape changes and two documented shortcuts are removed; see
  `### Removed — BREAKING` below, which is the half that requires action.

- **Both prose-budget caps raised: `PROSE_BUDGET_TIER1_CAP` 335 → 347 and
  `PROSE_BUDGET_TIER2_FILE_CAP` 1057 → 1186 (temperloop#925, temperloop#947,
  temperloop#954).** Three sequential raises across the release, each sized
  from measurement rather than re-guessed — the third one re-derived from the
  whole landed level after the first two had sized off one- and zero-item
  samples (blended observed overrun 1.53×, driven by the congruence-walkthrough
  item at 1.76×). These are **default-value changes on two existing
  setting-registry rows** — no row added, renamed, removed, and no column
  change — which `VERSIONING.md` § Setting registry classes as **minor, never a
  bare patch**: an adopter who dot-sources the previous default should re-check
  it. **The consequence worth stating plainly:** `PROSE_BUDGET_TIER2_FILE_CAP`
  is ONE uniform cap over every tracked `claude/**/*.md` file — there is no
  per-file exemption table — so raising it to fund `claude/commands/workshop.md`
  relaxes the per-file budget for **every** kernel doc, not that one file.
  Recorded as debt rather than glossed: three raises inside a single epic is
  itself the signal, `workshop.md` at 1144 lines is now the largest tracked
  kernel doc, and the subtraction pass those raises deferred is owed before a
  fourth.

### Removed — BREAKING

<!-- The `BREAKING` token appears TWICE for this release on purpose — on the
     `## [0.22.0]` heading above AND on this `### Removed` sub-heading. See the
     long comment on v0.19.0's own `### Removed — BREAKING` section below for
     why both are required: `changelog_breaking_sections()`
     (workflows/scripts/lib/changelog.sh) sets its `brk` flag ONLY from a
     heading line, never from body text, and the sub-heading marker is the half
     that survives a release cut rewriting `## [Unreleased]`. Do not strip
     either one when editing history. -->

- **BREAKING — `/workshop` Step 2's ad-hoc batch-approval license is removed.**
  The old Step 2.7 explicitly permitted it: "A batched draft is still fine: you
  may walk and disposition several dimensions, then persist and echo the batch,
  then ask once over it." That sentence is gone, and the new Step 2.7 closes
  the door by name — "Nor is there an ad-hoc grouping license." **Migration:**
  the only sanctioned way to ask once over several dimensions is now a
  **mechanical cluster the operator accepted at the tier-split stop** (Step 2
  item 2) — every dimension still shown, every dimension separately verdicted.
  If you drive `/workshop` by hand, or your overlay documents a
  batch-then-ask-once shortcut, move it onto the accepted-cluster path; an
  unaccepted grouping is no longer a legal way to reach the operator.

- **BREAKING — Step 4's ratify ask is no longer exempt from persist-then-ask.**
  The old Step 2.7 carried a Scope carve-out: "Step 4.3's ratify ask is
  **exempt** — its precondition, Step 4.1's dimension-completeness check,
  already guarantees the note is current, so no re-echo is required there."
  That exemption is deleted. Persist-then-ask now governs **every** gate over
  brief content — the walk's own stops, the findings fold-back, and the ratify
  ask alike — with no exemptions, and both surfaces (the persisted note,
  read-back-confirmed; and the in-chat decision presentation over that same
  content) must be current before the question is posed. **Migration:** a
  ratify ask must re-persist and re-present the content it gates rather than
  relying on the completeness check having left the note current. An overlay
  that restated the exemption must drop it — it now contradicts a kernel
  contract.

### Fixed

- **A completed worker whose return channel failed no longer produces a
  spurious `worker-error` escalation — or risks a duplicate PR
  (temperloop#939).** `build-level.mjs`'s 3c worker spawn is now wrapped in
  `callWorker()`, because the real failure mode is an **exception, not a
  null**: `agent({schema})` *throws* on a StructuredOutput-absent subagent, so
  the pre-existing null-guard never saw it and the run fell through to the
  catch-all escalation even when the work had fully landed. On any absent
  verdict the driver now runs `pr.sh recover-probe` (see `### Added`)
  **before** anything else. If the work landed, the `{slug, pr, pushed_sha}`
  parked record is reconstructed from that ground truth and the machinery
  finishes from whatever stage the worker actually reached — adopting the
  existing PR via `pr.sh`'s `EXISTS` outcome (**never** a second PR) and never
  re-spawning the worker onto a worktree that already holds the finished
  commit. If nothing landed (`RECOVER_NONE`), or the probe is denied or errors,
  the pre-existing worker-error path is untouched: it **fails closed**.
  **The recovery stays honest, which is the part an adopter must not miss.** A
  recovered verdict carries **no `passed` key at all**, marks every acceptance
  criterion `UNVERIFIED`, synthesizes a PR verification surface that says so,
  and the parked record carries `acceptance_unverified: true` and
  `recovered_from: <stage>`; `build.md` 3h/4a require the orchestrator to stamp
  it, render it distinctly from a self-reported verdict, and **re-verify before
  the merge gate**. A recovered item is a rescued record, never a passed one.
  Two non-obvious traps are handled: an already-pushed recovery skips the 3f-0a
  rebase (whose rewrite would make the following push a non-fast-forward and
  manufacture a *fresh* spurious escalation), and `--verification-surface-file`
  is dropped when the probe saw no `.build-verification.md` (a given-but-missing
  file is a hard `pr.sh` ERROR). The pre-existing but undeclared `DEPS_MERGED` /
  `DEPS_UNMERGED` outcomes are named in the same enum.

## [0.21.0] - 2026-07-29

### Added

- **Per-query OUTCOME fields on the knowledge-search read-log (foundation#1449,
  foundation epic #1443). Additive; existing consumers unaffected.** `ks_search`
  (the one entrypoint shared by both the cold `basic-memory` backend and the
  warm `basic-memory-mcp` daemon backend) now appends six fields after its
  existing `" · "`-joined 5-field read-log line: `result_count`, `top_score`,
  `abstained`, `rg_fallback`, `mode`, and `wall_ms`. `mode` names the retrieval
  path actually taken — `hybrid` or `hybrid+rerank` (reflecting whether the
  temperloop#1446 post-fetch re-rank ran for that query), `rg-fallback` when
  the score-0 ripgrep lexical fallback (foundation#950) answered instead, or
  `error:<rc>` on a backend dispatch error. `abstained` was always `0` at the
  time this landed — no abstention mechanism shipped yet, the field was
  emitted so the record shape would be stable before one did (see the
  foundation#1450 entry below, in this same release, for the mechanism that
  now sets it). Every other read-log
  call site (`ks_read`/`ks_write`/`ks_append`/`ks_list`, every backend, and the
  agent-plane hook) is unchanged — only `ks_search`'s line grows, and only at
  the end, so any consumer keyed on field position (the SessionEnd one-liner,
  `/tidy`'s tally, `telemetry-brief.sh`) reads exactly as before.
  `workflows/scripts/validate-knowledge-search-emit.sh` is the new presence
  lint guarding this wiring (the `validate-issue-touch-emit.sh` mold applied
  to a pure-library emit with no markdown orchestration step).

- **Abstention floor below a measured per-mode score/lexical-coverage floor
  (foundation#1450, foundation epic #1443). Opt-in, both backends, off by
  default.** `ks_search` can now decline to answer a query at all: below a
  measured floor on the shipped hybrid+rerank surface (temperloop#1446), it
  returns the existing genuine-zero-result shape instead of confident-looking
  low-relevance hits. Set `KNOWLEDGE_SEARCH_ABSTAIN=1` to enable it (default
  `0` — see rationale below); `KNOWLEDGE_SEARCH_ABSTAIN_SCORE_FLOOR` (default
  `0.72`) and `KNOWLEDGE_SEARCH_ABSTAIN_LEX_FLOOR` (default `0.10`) tune the
  two floors. The gate looks only at the top-ranked, post-re-rank candidate
  and requires **both** floors to fail — a conjunction, not either surface
  alone.

  **Why a conjunction, not a single floor.** Measured on the 213-query
  engine-neutral golden-query bench (foundation's
  `workflows/scripts/evals/golden-queries/`; 204 labeled + 9
  correct-abstention queries), two single-surface floors were rejected first:
  raw `.score` is query-relative (the re-rank's own trap 1) and the 9
  correct-abstention queries' top score (0.65–0.76) sits *inside* genuine
  hits' own range (0.58–1.28, median 0.79) — a floor tight enough to catch
  most abstention cases costs 30%+ of genuine top-5 hits. The re-rank's own
  RRF fusion score is rank-dominated (its leading term is a near-constant
  `1/(rrfk+0)` for every query's top-ranked candidate, answerable or not) and
  carries almost no separating signal alone either. What separates, measured
  on that corpus, is the **conjunction** of the top-ranked candidate's raw
  score AND its lexical-coverage feature `L` (the re-rank's own title/path
  term-agreement score, already computed for the fusion) — because in this
  corpus a genuine hit is almost always a strong semantic match, a strong
  lexical match, or both, so requiring BOTH to be simultaneously weak is what
  isolates the unanswerable queries.

  **Measured result, two independent runs (byte-identical — the fused
  candidate order is deterministic; only *tie-breaking* among near-equal
  ranks jitters per trap 3):** at the shipped defaults, correct-abstention
  moved from the pre-existing 0/9 baseline to **4/9**, with **0/186** labeled
  top-5 hits lost (aggregate hit@5 unchanged — well inside the ~3% jitter
  budget). Ships opt-in rather than default-on because this is judged
  BREAKING-adjacent: it changes the result set an existing caller receives on
  any live query that happens to land in the low-score/low-lexical-coverage
  region, and the calibration set is small (all 9 correct-abstention examples
  that exist in the corpus — there is no held-out set to validate recall
  against). The zero-measured-cost property is the load-bearing safety claim
  here; the 4/9 recall figure is directional, not a guarantee against novel
  unanswerable queries.

  **The rg-fallback interaction (ratified L1 mode-sweep semantics, consumed
  here, not re-decided).** An abstention is a **post-re-rank empty**, never a
  **backend-empty** — the backend returned real candidates; the floor
  discarded them. The score-0 ripgrep lexical fallback (foundation#950) fires
  only on a genuine backend-empty, so it stays **suppressed** on a
  floor-triggered abstention even when a literal corpus match exists on disk
  (`abstained=1`, `rg_fallback=0` — both verified by test). Wires the
  previously-hardcoded `abstained` outcome field (foundation#1449) from `0`
  to `1` when this fires — its live misfire monitor.

  Implementation is a single shared point: `_ks_bm_rerank` (one
  implementation reused by both the cold `basic-memory` backend and the warm
  `basic-memory-mcp` daemon backend) signals an abstention with one sentinel
  line in place of its normal JSONL stream; `ks_search` is the one place that
  consumes it, converts it to the real empty-result shape, and suppresses the
  rg fallback — the sentinel never reaches a caller. The `ks_search` JSONL
  output shape and exit-code contract are byte-unchanged for every
  non-abstaining query, and off by default (`KNOWLEDGE_SEARCH_ABSTAIN=0`) is
  a true no-op, identical to pre-#1450 behavior.

## [0.20.0] - 2026-07-29

### Added

- **Post-fetch re-rank on both knowledge-search backends (temperloop#1446,
  foundation epic #1443's ranking lever). Additive; off-switch provided.**
  `ks_search` now asks the backend for a deeper candidate set than the caller
  requested (`KNOWLEDGE_SEARCH_RERANK_DEPTH`, default 20), re-orders those
  candidates with a thin deterministic re-ranker, and returns exactly `--limit`
  of them — the extra depth is internal, so a caller asking for 5 still gets 5.
  This is the lever the foundation#1445 mode-sweep verdict selected over every
  retrieval-mode alternative (a different default mode, intent routing, and
  multi-mode fusion were each measured and rejected): on that corpus the right
  document sat inside the backend's top-20 for 94.6% of queries but inside its
  top-5 for only 86.8%, so depth was buying coverage the returned window threw
  away. The re-ranker is jq-only — no cross-encoder, no model download, no new
  dependency — and scores each candidate on query-term agreement with its own
  title and path, weighted by how RARE each term is among that query's own
  candidates, with a bonus for a verbatim query match. A minimal suffix stemmer
  unifies inflections ("editor"/"Editing", "plan"/"Plans-archive") that an exact
  matcher could not see. Measured on the 214-query engine-neutral bench corpus
  against a same-index control: known-item hit@5 0.8056 -> 0.8611 and known-item
  MRR 0.5833 -> 0.7972, with no category regressing. **The published
  `{doc_id,title,score,snippet}` JSONL shape and the exit-code contract are
  unchanged** — the re-rank alters only the ORDER and therefore which `--limit`
  candidates survive; each surviving record is passed through byte-for-byte.
  Three invariants are test-pinned: it never reads `score` as evidence (hybrid
  scores are normalised within each query's own result set, so they are
  query-relative and no fixed threshold is well-founded — the fusion is over
  RANK lists instead); the `score: 0` rg-fallback sentinel is provenance, not
  relevance, and a candidate set carrying one is never reordered; and the cold
  CLI path and warm bm-mcp daemon path share ONE implementation so they cannot
  drift apart in ranking. Set `KNOWLEDGE_SEARCH_RERANK=0` to restore the
  backend's own ordering — the fetch depth then collapses back to `--limit`,
  making the off-switch a true no-op.

### Changed

- **The close→Done cascade is stated per backend; on issues-only the adapter's
  Done write is the PRIMARY mechanism, not a backstop (temperloop#902).** The
  cascade (GH #340) is a GitHub **Projects-v2 built-in** — it has no
  implementation in this repo, and on the issues-only backend (the default,
  ADR 0004) there is no such automation and nowhere to hook one: no project
  item for an automation to move, and no native GitHub "on issue close, strip
  a label" rule for a plain Issues repo. A close therefore makes the item
  *read* Done (the reshape's closed-state precedence) while leaving the
  residual `fnd:status:*` label — and the `fnd:host/session:*` claim stamp —
  standing, which is what left 9 of 9 board-7 closures across two runs still
  labelled `fnd:status:backlog`. Rather than wire a cascade with no hook
  point, the contract is corrected where it was inverted:
  `claude/CLAUDE.kernel.md` § Board hygiene is part of the gate,
  `workflows/scripts/board/ISSUES-ONLY-BACKEND.md` § Close→Done cascade,
  `docs/principles.md` § 8, and `docs/architecture.md` now state the split
  explicitly, and `/build` 4d + `/fix` Step 6 item 3 make the
  `board_set_status … Done` write **backend-conditional** (`board_backend`):
  omitted on Projects-v2 exactly as before, issued on issues-only after a
  **confirmed `MERGED`** (REST, no GraphQL budget, warn-and-continue on a
  non-zero return, and still gated on confirmed-merged so the #130
  premature-Done surface stays closed). Detection is unchanged and already
  shipped — `reconcile.sh --status` classes (k)/(l) and `--labels` classes
  (h)/(j) — and now carries a regression case for the exact reported shape: a
  closed issue wearing ONLY `fnd:status:backlog` and no claim stamp, flagged
  by both lenses.

## [0.19.0] - 2026-07-29 — BREAKING

### Migration — read this first

This release **closes both open compatibility windows at once** — the
`foundation` → `temperloop` rename window (opened v0.15.0, temperloop#165 /
temperloop#764) and the v0.17.0 terminology-consolidation window (opened
v0.17.0, epic temperloop#719 / temperloop#767). Both stated a v0.19.0 removal;
this is that removal. One adopter migration, not two.

**Who has to act.** Anyone whose machine, overlay, or scripts still name a
pre-rename identifier. If you installed or configured this kernel at v0.14.x or
earlier you almost certainly do. **The `boards.conf` item below has been
observed silently breaking a live host — do that one even if you believe you
are already migrated.**

The two lists below are **derived, one line per entry**, from the two
machine-readable window tables this release deletes:
`workflows/scripts/kernel/prerename-leak-verdicts.tsv`'s eight `windowed` rows
(plus the two legacy FORMS that file's own header records as always-sanctioned
by pattern rather than enumerated as rows), and
`workflows/scripts/kernel/terminology-leak-exempt-files.txt`'s thirteen-file
`window` class. Nothing here is hand-picked: if an entry was in a table, it has
a line.

#### A. `foundation` → `temperloop` names — 10 entries

Derived from `prerename-leak-verdicts.tsv`, verdict `windowed`. Every one of
these was a **read-old** fallback; each has been replaced by a legible refusal
or a named diagnostic, so nothing in this group degrades silently — **except
A7**, which has its own call-out below.

| # | Deleted window entry | What to do |
|---|---|---|
| A1 | env `FOUNDATION_HOME` | Rename the export to `TEMPERLOOP_HOME`. Setting only the legacy name now **exits non-zero** naming the replacement. |
| A2 | env `FOUNDATION_BIN_DIR` | Rename the export to `TEMPERLOOP_BIN_DIR`. Same refusal. |
| A3 | env `FOUNDATION_KERNEL_REPO` | Rename the export to `TEMPERLOOP_KERNEL_REPO`. Same refusal. |
| A4 | env `FOUNDATION_VERSION` | Rename the export to `TEMPERLOOP_VERSION`. Same refusal. |
| A5 | `bin/lib/common.sh`'s internal install-path *home* constant (legacy-prefixed spelling) | Now `TEMPERLOOP_CLI_HOME_DEFAULT`. Nothing to do unless you patch or source `bin/lib/common.sh` and reference the constant by name — then rename your reference. |
| A6 | `bin/lib/common.sh`'s internal install-path *bin* constant (legacy-prefixed spelling) | Now `TEMPERLOOP_CLI_BIN_DEFAULT`. Same. |
| A7 | machine conf leaf `boards.conf` — the legacy `~/.config/foundation/boards.conf` read | `mkdir -p ~/.config/temperloop && mv ~/.config/foundation/boards.conf ~/.config/temperloop/` — **read the call-out below before skipping this.** |
| A8 | knowledge-store root leaf `knowledge` — the legacy `~/.local/share/foundation/knowledge` store | `mkdir -p ~/.local/share/temperloop && mv ~/.local/share/foundation/knowledge ~/.local/share/temperloop/`, or point `KNOWLEDGE_STORE_ROOT` at the existing store. `knowledge_store.sh` **names** a stranded legacy store on stderr instead of reporting "no notes found" against an empty new root. |
| A9 | the committed per-repo `.foundation/` dir (`.foundation/config`, `.foundation/baseline.jsonl`, …) — sanctioned by pattern in the verdict table's header, never a row | Run `git mv .foundation .temperloop` in each repo. `temperloop init` **refuses** while a legacy `.foundation/config` is present and no `.temperloop/config` exists; `baseline-snapshot` **refuses** while a legacy `.foundation/baseline.jsonl` exists, rather than splitting one append-only history across two directories. |
| A10 | `bin/foundation`, the CLI compat shim — sanctioned by pattern in the verdict table's header, never a row | Invoke `temperloop <sub>`. **Forwarding is removed; the file is retained as a refusing tombstone** (see below), so the old name still *answers* — it just refuses and names the replacement. To retire the old name from your `PATH`, run `rm -f ~/.local/bin/foundation` **yourself**. |

**A10, precisely: `bin/foundation` is NOT deleted.** Its forwarding is removed
and the file is retained as a **refusing tombstone**. A pre-v0.19.0 install left
a `~/.local/bin/foundation` symlink pointing at that file, and `temperloop
update` moves the checkout underneath that symlink — so deleting the file would
turn the symlink into a dangling "no such file or directory" at exactly the
moment the operator needs to be *told* the name changed. A fresh `bootstrap.sh`
install no longer creates the symlink at all.

**Removing the stale symlink is MANUAL.** `temperloop uninstall` **prints** the
`rm -f ~/.local/bin/foundation` for you to run; it cannot remove it itself. The
symlink belongs to the bootstrap footprint (scope (a) of `bin/README.md`
§ Uninstall), written before any install manifest existed, so uninstall has no
record of it and deliberately will not infer one (`uninstall.sh:22-31`). Run the
`rm -f` by hand.

#### A7 in full — the machine `boards.conf`. Do this one first.

This is the **one migration in this release that fails silently**, and it has
already bitten a live host.

- **Exact old path (no longer read):** `~/.config/foundation/boards.conf`
  (`$XDG_CONFIG_HOME/foundation/boards.conf`)
- **Exact new path (the only one read):** `~/.config/temperloop/boards.conf`
  (`$XDG_CONFIG_HOME/temperloop/boards.conf`)
- **Fix:**
  `mkdir -p ~/.config/temperloop && mv ~/.config/foundation/boards.conf ~/.config/temperloop/`

**The failure is SILENT — no error, no log line, no non-zero exit.** Every
`--board N` simply resolves against the built-in maps instead of your conf, so
the boards quietly come up on the **wrong backend**. Nothing tells you. Measured
on the driver host during this very release cut (temperloop#908): that legacy
file was the *only* record of a four-board backend cutover
(`board.{3,4,5,6}.backend=issues`, temperloop#470–473), and a v0.19.0-era
checkout beside a v0.18.0 one read boards 3/4/5/6 as `projects` where the older
checkout read `issues` — a **silently reverted** cutover that would have put
every fleet board read and write back onto the Projects-v2 GraphQL path and back
into contention for the shared 5,000-pt/hr budget. It was found by hand, not by
any gate.

Do not rely on `board.sh`'s stderr `NOTE` to catch this for you. That note fires
only in the narrow case where **no** `~/.config/temperloop/boards.conf` exists at
all — a partially-migrated host with both files gets nothing — and library
stderr is routinely swallowed by the sourcing caller and by unattended runs.

#### B. v0.17.0 terminology names — 13 entries

Derived from `terminology-leak-exempt-files.txt`'s deleted `window` class, one
line per file. Unlike group A these arms **fail open by construction** — a
forwarding stub is invoked *by path* and the env shim was sourced under
`[ -f ]` — so there is no refusal to leave behind: a caller still on a legacy
name now gets "no such file or directory" from its own shell, or simply no
binding at all. The v0.17.0 `BREAKING` entry carries the full rename map.

| # | Deleted window file | What to do |
|---|---|---|
| B1 | `workflows/scripts/lib/rename-compat-0170.sh` (the env shim, plus **both** of its `[ -f ]`-guarded source blocks in `build.config.sh` and `setting-registry-lib.sh`) | Rename every variable you set: `FUNNEL_<NAME>` → `PIPELINE_<NAME>`, `KNOB_<NAME>` → `SETTING_<NAME>`. A pre-rename name now binds nothing and prints nothing — including one set from a layer-3 machine conf or a layer-4 repo-local conf. |
| B2 | `workflows/scripts/build/funnel-cron.sh` | Invoke `workflows/scripts/build/pipeline-cron.sh`. **Also repoint any installed launchd plist / cron entry** — the *installed* copy is what runs, not the repo file. |
| B3 | `workflows/scripts/build/funnel-drive.sh` | Invoke `workflows/scripts/build/pipeline-drive.sh`. |
| B4 | `workflows/scripts/build/funnel-tick.sh` | Invoke `workflows/scripts/build/pipeline-tick.sh`. |
| B5 | `workflows/scripts/build/funnel-overlap.sh` | Invoke `workflows/scripts/build/pipeline-overlap.sh`. |
| B6 | `workflows/scripts/build/funnel-schedule-gate.sh` | Invoke `workflows/scripts/build/pipeline-schedule-gate.sh`. |
| B7 | `workflows/scripts/build/build-config-knobs.sh` | Invoke `workflows/scripts/build/build-config-settings.sh`. |
| B8 | `workflows/scripts/config/check-knob-registry.sh` | Invoke `workflows/scripts/config/check-setting-registry.sh`. Update any overlay gate list naming the old path. |
| B9 | `workflows/scripts/config/check-knob-prose.sh` | Invoke `workflows/scripts/config/check-setting-prose.sh`. Update any overlay gate list naming the old path. |
| B10 | `workflows/scripts/config/knob-registry-lib.sh` (the source-forwarder, which also re-exposed the `knob_registry_*` function names) | Source `workflows/scripts/config/setting-registry-lib.sh` and call the `setting_registry_*` names. |
| B11 | `workflows/scripts/validate-live-drain.sh` | Invoke `workflows/scripts/validate-capture-backstop.sh` (or `make validate-capture-backstop`). |
| B12 | `workflows/scripts/validate-capture-backstop.sh`'s legacy **registry-filename** resolution and table spellings | Rename the overlay registry file `claude/live-drain-registry.overlay.md` → `claude/capture-backstop-registry.overlay.md`, its heading `## Live/Drain pairings` → `## Capture/Backstop pairings`, and its table's first column header `Live rule` → `Capture rule`. **This is the one arm in group B that degrades quietly:** an overlay still shipping the old filename now reads as "no overlay extension present", so its pairs are simply **not validated** and the gate stays green. |
| B13 | `workflows/scripts/tests/test_terminology_rename_compat.sh` | Nothing to do. The file is not deleted — it is inverted in place from a read-old-write-new proof into a window-**stays-shut** regression test. |

#### Contract surfaces this release touches

Five of the surfaces `VERSIONING.md` § The contract surface enumerates change
here. **Hook names and signatures are untouched** — the hook changes in this
release are behavior-only, inside the same I/O contract.

1. **CLI surface** — `bin/foundation`'s forwarding is removed and the file is
   retained as a refusing tombstone (A10); the four legacy `FOUNDATION_*` env
   vars now make `bin/temperloop` refuse rather than silently install at a path
   you did not ask for (A1–A4); `init` and `baseline-snapshot` refuse on legacy
   `.foundation/` state (A9).
2. **Board adapter interface** — the machine-level `boards.conf` layer reads one
   path only (A7). No `board_*` function name, argument, or `--board N` value
   changes; only where the layer-3 conf is read from.
3. **Setting registry** — **four rows are removed** (the four DEPRECATED
   legacy-prefixed env rows superseded by their `TEMPERLOOP_*` twins in
   v0.15.0), and the four surviving twins' `default` fields no longer transcribe
   a `${…:-…}` fallback to the legacy name. Row removal is now classified
   explicitly in `VERSIONING.md`'s setting-registry paragraph — it is
   **breaking**. No column changes, so the row *shape* readers parse is
   unchanged.
4. **Published schemas/contracts** — the capture/backstop overlay registry's
   filename, heading, and column header are now single-spelled (B12);
   `knowledge_store.contract.md`'s default store root no longer has a legacy
   fallback (A8); `docs/config-precedence.md` records the single `boards.conf`
   machine path.
5. **Quality-gate contract** — `KERNEL_GATES` **shrinks by 2**: the two gate
   entries that were still invocable at their pre-rename script paths
   (`check-knob-registry.sh`, `check-knob-prose.sh`) now exist only under their
   renamed spellings (B8, B9), so an overlay gate list naming either old path
   fails with "no such file or directory". Alongside them,
   `make validate-capture-backstop`'s script no longer answers to
   `validate-live-drain.sh` (B11), and the terminology-leak gate's exempt list
   drops two whole classes (`window`, `registry`) — so `make
   test-kernel-terminology` now guards surfaces the window used to be allowed to
   carry.

### Added

- **Per-contributor session-start surface measurement (temperloop#827, epic
  #810's sub-item "P1" — epic #810's OWN Produces-list numbering, a
  different axis from ADR 0018's Phase A/Phase B split of the same epic;
  P1 is Phase A work. Additive.).** `count-prose.sh` gains a third report
  section, "SESSION-START CONTRIBUTORS", driven entirely by a new tracked
  manifest, `workflows/scripts/config/contributor-manifest.tsv` (in the
  established registry mold: `setting-registry.tsv`, `reviewer-routing.tsv`,
  `citation-registry.tsv`) — every file (or file's YAML frontmatter
  `description:` field) Claude Code auto-loads into a fresh session before
  the agent reads anything, for a bare kernel-only checkout. Adding a
  contributor is a manifest row, never a script change. Reports each
  contributor in BYTES (not lines — the unit temperloop#719/#722 showed can
  move zero lines on a multi-kilobyte commit) plus a byte->token proxy ratio
  re-derived at runtime from a live byte count and a live word count (no
  tokenizer, no network — Phase A of epic #810 per its design brief). A new
  `check-contributor-manifest.sh` lint (wired into `scripts/quality-gates.sh`)
  reconciles the manifest against the tree: no duplicate/untracked/malformed
  row, every `frontmatter:description` row's field actually present and a
  single-line unquoted scalar (a YAML block/folded `|`/`>` indicator is
  rejected, not silently truncated), and every tracked
  `claude/commands/*.md` + `claude/agents/**/*.md` file (plus the root
  `CLAUDE.md` pointer) claimed by a row — this is a structural lint only,
  never a byte budget: **Phase A ships no cap, no target, and no gate that
  can fail a PR merely for growing the surface.** The manifest's `load`
  column (`harness-auto` | `pointer-turn1` | `none` | `n/a`) distinguishes
  the unconditional session-start-prefix cost from a conditional turn-1 read
  (e.g. `AGENTS.md`, out of scope here per epic #810's own "P7" sub-item,
  the AGENTS.md coverage decision) so the two are never silently summed
  together (temperloop#826). Additive: no existing row, column, gate name,
  or script behavior changes: a downstream consumer that has not yet pulled
  this kernel version has nothing that could fail the new lint.

  **Coverage caveat, stated in checkable terms (temperloop#826):** this
  manifest, together with TIER-1, covers 100% of a KERNEL-ONLY checkout's
  always-loaded surface and 0% of a CONSUMER checkout's (a downstream repo
  with an installed overlay + its own project `CLAUDE.md` — e.g.
  foundation). Do not read the "SESSION-START CONTRIBUTOR TOTAL" this
  section prints as a consumer checkout's session cost — it is off by
  roughly an order of magnitude for that case. A consumer-side measurement
  is future work, not yet built.

  **Known, disclosed contradiction with ADR 0007 (not a bug):** the manifest
  deliberately includes all seven `claude/agents/reviewers/*` inert-catalog
  files, because temperloop#825's still-open discovery-leak bug means they
  ARE, today, recursively discovered into every session's agent listing
  despite ADR 0007 specifying them as "not deployed until opted in" — this
  item measures the surface as it actually behaves, leak included; #825
  removes these rows once the leak itself is fixed, not this item.

- **Semantic-redundancy chunker + labelled fixture corpus (temperloop#854,
  half (a) of the P9 semantic-redundancy probe split from #830; epic #810
  contract amendment P9. Additive.).** A new `chunk-redundancy-surface.sh`
  splits the SAME manifest-driven always-loaded surface
  `count-prose.sh`'s SESSION-START CONTRIBUTORS section already reads
  (`workflows/scripts/config/contributor-manifest.tsv`) into rule-sized
  chunks and prints them as a JSON-Lines stream on stdout — one paragraph,
  one top-level list item (indented sub-content swept in as a continuation
  of its own item), or one opaque fenced code block per chunk; a markdown
  heading is never itself a chunk, it only updates the `section`
  breadcrumb every following chunk carries. The surface stays data, not
  code: a new manifest row needs no chunker change. This half deliberately
  does NOT score redundancy, compute similarity, or call an embedding/
  LLM-judge — that is #855's job; this script's only output is the
  segmentation itself, documented field-by-field in the companion
  `chunk-redundancy-surface.md` (the seam #855 consumes), so the scoring
  approach can change with zero changes to the chunker or its stream
  shape. Deterministic (byte-identical on macOS and Linux CI), following
  `count-prose.sh`'s own host-determinism technique (`LC_ALL=C`, tracked
  manifest order rather than a filesystem glob, BSD/GNU `wc` padding
  trimmed) — JSON construction itself goes through `jq -S -c` rather than
  a hand-rolled escaper, so backslash/quote/embedded-newline/non-ASCII
  prose bytes are never at risk of a bespoke-encoder bug.

  Ships alongside a labelled fixture corpus,
  `workflows/scripts/config/redundancy-fixtures.json`: a known-positive
  paraphrase pair (states the same rule in fully reworded language, sharing
  no 10-consecutive-word run — the exact case a verbatim-only detector
  would miss) and a known-negative deliberate-pointer pair modelled on the
  project `CLAUDE.md`'s own `## CI & branch policy` shape (names the
  canonical rule, then states only what is repo-specific), plus a second
  positive and a hard-topical-near-miss negative for a slightly richer
  seed corpus. Every entry carries a one-line rationale. A new
  `check-redundancy-fixtures.sh` lint (wired into `scripts/quality-gates.sh`)
  mechanically enforces the corpus's own acceptance property — every
  `positive`-labelled pair shares zero 10-word shingles — rather than
  leaving it a comment-only claim, plus the usual structural checks
  (required fields, closed label set, unique ids).

  **Phase A scope discipline holds throughout: no cap, no threshold, no
  redundancy verdict, nothing that can fail a contributor's build** — the
  two new gates only prove the chunker and the fixture lint themselves run
  correctly, never a judgment about any file's prose.

- **Realized-session-context probe (temperloop#828, epic #810).** A new
  opt-in (default OFF) `session-context` raw-lake stream, emitted by
  `workflows/scripts/emit-session-context.sh` from the SessionEnd hook seam
  (`claude/hooks/session-end-log.sh`), records the WHOLE session's realized
  token usage — not only the session-start prefix a prior scope measured —
  so a prose relocation's real value becomes measurable rather than
  assumed. The token-sum expression `claude/status-line.sh`'s "Tokens: NNk"
  display already computed is lifted verbatim into a new shared helper,
  `workflows/scripts/lib/token_sum.sh`, so the displayed and recorded
  figures cannot drift apart; its only jq selector is `.message.usage.*`
  (never message content), a structural privacy guarantee proven by a
  synthetic-recognizable-content fixture rather than merely asserted. The
  emit script also supports a one-off `--print-only` reading, independent of
  the passive opt-in gate, for a caller that needs a single on-demand
  measurement. New setting-registry.tsv rows: `SESSION_CONTEXT_RAW_ENABLED`
  (bool, default `0`) and `SESSION_CONTEXT_RAW_DIR` (the stream's sink-dir
  override, following the existing `<STREAM>_RAW_DIR` convention). **Not
  breaking**: the SessionEnd hook's stdin contract and output stub are
  unchanged, `status-line.sh`'s displayed figure is byte-identical to
  before under a normal full-tree sync (same expression, now shared —
  `status-line.sh` degrades to displaying `0` only under a hypothetical
  partial vendoring that ships it without `workflows/scripts/lib/`, which
  the kernel manifest already treats as one unit), and both new settings
  default to off/inert for an adopter who never opts in — Phase A is measurement only,
  with no cap, target, or CI gate on the recorded figure itself.

- **Declared-expiry check (temperloop#831, epic #810's "P10" sub-item, added
  by operator amendment at the epic's `/assess` gate).** A new report-only
  script, `workflows/scripts/declared-expiry-check.sh`, finds standing
  rules whose own stated end condition has already passed. A rule declares
  an expiry in two forms — an absolute date, or a named retirement issue —
  via a new optional `expires:<expiry>` field on its existing citation
  marker (`claude/citation-schema.md` § Declaring an expiry extends the
  marker grammar `validate-prose-budget.sh` already enforces; the field is
  additive and fully optional, never a second `class:ref` pair). The date
  form resolves with a plain lexical `YYYY-MM-DD` string comparison — 100%
  offline, no `date` arithmetic at all; the issue form resolves via `gh
  issue view` and degrades LEGIBLY when offline (an explicit UNRESOLVED
  bucket, never a silent drop or a hard failure). The check's surface is
  the intersection of `citation-registry.tsv` (the mechanical "standing
  rule" definition) and `contributor-manifest.tsv` (temperloop#827's
  always-loaded-file registry) — `claude/CLAUDE.kernel.md`'s own K.* rules
  are explicitly out of scope for this reason, and every run's report names
  the excluded file set rather than silently under-covering. **Reports
  coverage, not precision**: a date/issue either has passed or it has not,
  so resolution is exact within what the check can see, but its value is
  bounded entirely by adoption — the report gives both how many in-scope
  rules declare an expiry and how many read as temporary in prose (a
  small, fixed keyword heuristic) yet declare nothing, then compares
  measured adoption against a **pre-registered** threshold
  (`DECLARED_EXPIRY_ADOPTION_THRESHOLD_PCT`, new setting-registry.tsv row,
  default 50%, fixed before this item's own first real-tree measurement
  ran) and prints a GO/NO-GO verdict on whether a future Phase-B gate is
  warranted. States its own limit explicitly: an undeclared temporary rule
  with no recognizable temporal language is invisible to this check by
  construction. **Phase A ships no cap, no target, and no CI gate** — the
  script always exits 0 on its own findings; it fails only if its own
  required registry/manifest inputs are entirely absent, which never
  happens on a normal checkout.

- **`env-reconcile` reports a consumer carrying an out-of-date vendored guard
  (foundation#1353). Additive.** `workflows/scripts/build/env-reconcile.sh`
  gains a `STALE_VENDORED_HOOK:<hook>` drift class on its operator/consumer
  checkout role: a consumer repo whose vendored
  `.claude/hooks/build-worktree-guard.sh` differs from this kernel's canonical
  `claude/hooks/build-worktree-guard.sh` is now **reported**, with the exact
  command that re-syncs it. This closes a real blind spot rather than a
  hypothetical one — when the kernel's write-jail grew its Bash arm, the three
  consumers kept the pre-Bash-arm copy and *nothing* said so, which is how a
  worker's `rm -rf "$(dirname "$(pwd)")"` reached outside its worktree
  (foundation#932). Design choices that keep it from going stale itself: it
  compares **content**, not a version stamp, so it needs no kernel-side
  coordination; the sync's provenance banner lines are excluded from the
  comparison (counting them would mark every correctly-synced consumer
  permanently drifted); and the remedy string is read from the vendored copy's
  own banner, which already names the target that produced it, so there is no
  repo→target mapping table to drift. Emitted in **both** probe formats, so
  `/tidy` routes it to the environment-hygiene report for `/check-in` like any
  other cross-lane drift. Deliberately **not** a `make doctor` check: doctor's
  pinned contract is "non-zero → run `make install` to heal", and a stale hook
  in a *foreign* checkout is not healable by `make install`, so a class there
  would pin doctor non-zero forever and bury its real MISSING/DANGLING signal.
  Read-only and fail-open — an absent or unreadable checkout, a consumer that
  vendors no copy, or an unresolvable canonical reference is skipped silently,
  never an error. Detection half only; auto-sync on kernel merge
  (foundation#694) remains the durable fix and is referenced, not duplicated.
  Both new seams are registered in `setting-registry.tsv`
  (`ENV_RECONCILE_CANONICAL_HOOK_DIR`, `ENV_RECONCILE_VENDORED_HOOKS`) — new
  rows only, so nothing existing changes shape.

### Changed

- **`temperloop init` is scoped down to bootstrap → offer the first epic →
  hand off (temperloop#796).** `init` no longer applies any API state of its
  own. It bootstraps `.temperloop/config` (and its reviewable proposal PR),
  offers the kernel-shipped first epic, prints a `next step:` handoff line,
  and stops. Branch protection, head-branch auto-delete, the merge-queue
  disposition, the required `checks` status context, CI, and the adopter's
  review principles are all the first epic's work, applied later with
  per-write consent via `/assess --epic N` → `/build` (ADR 0010, amended in
  this release). Two of the retired applies were actively wrong where they
  stood: `init`'s required-check apply armed a `checks` context with no
  regard for whether a producer would ever post it — the self-brick the
  epic's structural-congruence rule makes unreachable — and its `fnd:` label
  pre-creation duplicated what the issues-only tracker backend already does
  lazily at point of use.
- **Issues-only is now the sole init-time tracker mode (temperloop#793).**
  Board provisioning is dropped from `init`. The retired `projects` arm
  rendered `# board.<N>.project=<FILL IN …>` into `boards.conf` *before* the
  step that learned the project number and never reassigned it, so even a
  fully-consented, successful run shipped a placeholder — and because it was
  a comment, the adapter's `^board\.N\.axis=` lookup missed it and fell
  through to a built-in default rather than failing loudly. The rendered
  entry is now always complete, pinned by a regression test asserting
  `board.<N>.backend=issues` present and `FILL IN` absent from both
  `.temperloop/config`'s `tracker.boards_conf_entry` and the proposed
  `boards.conf`. To run a real Projects-v2 board, create it and hand-write
  its three `boards.conf` axes — see `docs/features/install-cli.md`
  § "Manual Projects-v2 recipe".
- **Declining the first epic files the durable re-offer pointer and nothing
  else.** The inline principles interview `init` used to run on the decline
  path is retired: it was a second copy of an interview the epic already
  owns as its L0 (`record-principles`), asked by a different actor through a
  different write seam. Declining now defers it. The kernel principle set
  still applies at every review call site's point of use with zero
  configuration, so declining costs only the *recorded* choice.
- **`.temperloop/config` stays at schema 1.** A repo initialised before this
  change keeps its recorded `label` / `required_check` / `board` install
  entries: they are carried forward untouched on every re-run and
  `temperloop eject` still reverts them, even though `init` no longer
  creates any.
- **The uninstall map gained a fifth scope, because a four-scope table that
  presents itself as exhaustive now has a gap.** `bin/README.md` § Uninstall
  and `eject.sh`'s on-every-run removal bullet both carry **scope (e), the
  first-epic substrate** — branch protection, head-branch auto-delete, the
  merge-queue disposition, any scaffolded CI workflow, and the recorded
  `§ Principles` disposition. That state is applied by the first epic via
  `/assess` → `/build`, never by `init`, so it is in no manifest and
  `temperloop eject` does **not** revert it — and neither does reverting the
  epic's own PRs, since API state is not a tracked file. Undo is manual, in
  repo Settings; the step-by-step list is in
  `docs/features/engineering-principles.md` § "Uninstall / removal".
  Previously an adopter could eject, read `all N install(s) reverted` against
  a complete-looking table, and walk away with a protected branch and an
  armed merge queue nobody had told them eject would leave behind.
- **The first epic's consent questions now disclose their undo path.** Each
  A2 question and the A3 Actions branch in
  `claude/templates/first-epic-setup.md` carries an explicit **`Undo:`**
  clause naming the repo-settings path and stating that `temperloop eject`
  does not revert it; § Decline floors scopes its "nothing can leave your
  repo worse off" claim to match. ADR 0010's accepted-gap record resolves
  this irreversibility by pointing at consent-time disclosure, so that
  disclosure has to exist in the artifact the adopter actually reads, not
  only in a maintainer-facing ADR.
- **`init`'s handoff names its prerequisite.** `/assess` and `/build` are
  Claude Code slash commands that reach a machine only via `temperloop
  install`, while the `try` → `try --demo` → `init` ladder otherwise needs no
  machine-wide setup — so a stranger could reach the handoff pointing at a
  command they did not have, deferring all of this epic's value to a dead
  pointer. `init` now probes for `~/.claude/commands/assess.md` and prints an
  extra `prerequisite:` line when it is missing; `bin/README.md` and
  `docs/features/install-cli.md` no longer imply step 3 is self-contained.
  The `next step:` line itself is byte-identical either way (pinned by a
  test), since it is the marker the tier-2 workflow greps on a runner that
  has no `~/.claude/`.

- **The build-worktree write-jail now contains output redirects, not just
  destructive verbs (foundation#1355).** An output redirect is a write the
  *shell* performs before the verb ever runs — `> <path>` truncates that file
  whatever command follows — so the Bash arm's verb-only inspection left a
  whole write vector uninspected beside the inspected delete vector. Redirect
  targets (`>`, `>>`, `2>`, `2>>`, `&>`, `>|`, and the word-glued spellings) are
  now judged on the same terms as a destructive verb's path operand: a
  non-literal target is unprovable and denied, a target resolving outside the
  worktree root is an escape and denied, and the existing
  `/tmp`/`$TMPDIR`/gitignored allow-list applies unchanged — so the cd-context
  check covers redirects for free. Three shape rules carry the behavior: a
  **bare** operator still ends the preceding verb's operand run while a
  **glued** one does not (it does not end the argument list in a real shell
  either, and `rm -rf 2>/dev/null <outside>` really does delete `<outside>`);
  `>&WORD` names no file only when WORD is an fd number or `-`, so `2>&$FD`
  stays contained and `>(cmd)` is correctly read as process substitution; and
  character-device sinks (`/dev/null`, `/dev/stderr`, `/dev/fd/N`, …) are
  allow-listed **for redirects only**, because `2>/dev/null` is the most
  routine idiom on a worker command line and denying it is how a guard gets
  disarmed — `rm -rf /dev/null` is still judged normally. Hook **name and I/O
  signature are unchanged**; this is a widening of what the same hook denies.
  Verified against the differential harness (working copy vs. `origin/main`,
  failing on any `old=DENY new=allow`): 62 same, 12 tightened, 0 regressions.
  One incidental tightening falls out — `rsync`'s last-selector used to pick a
  trailing `2>/dev/null` as the destination and miss the real one. The harness
  itself is now a `KERNEL_GATES` entry
  (`claude/hooks/tests/differential-guard-vs-ref.sh`, foundation#1367), so a
  refactor that loses coverage can no longer arrive with a corpus that ratifies
  the loss.

- **The write-jail's operand walker is now a verb-to-operand-model table
  (foundation#1354).** The Bash arm modelled every destructive verb with one
  grammar — "every non-flag token is a path operand", plus a hand-branch for
  `dd`'s `of=` — which does not generalize past the flat
  `rm`/`rmdir`/`mv`/`shred`/`truncate` list, leaving three common
  worker-destructive shapes entirely unmodelled. The flat verb list is replaced
  by a MODEL table keyed by verb, each row carrying four data fields: which
  operands are targets, the predicate deciding whether the invocation is
  destructive at all, whether the cd-context directory is itself an implicit
  target, and the verb's token count. The walker dispatches on that data — no
  verb name appears in control flow — so a new shape reusing an existing
  select/arm pair is a table row and nothing else. Three rows added, each a
  different grammar: **`rsync`** is destructive only under `--delete*` and only
  its last operand (the destination) is checked; **`find`** is destructive only
  when its predicate run carries `-delete` or `-exec rm`/`rmdir`, and only the
  pre-predicate path operands are checked (`-delete` was previously swallowed
  by the leading-`-` flag skip); **`git clean`** has no target operand at all
  and is judged against the cd-context base. `rm`/`rmdir`/`mv`/`shred`/
  `truncate`/`dd` behavior is unchanged and the hook's I/O signature is
  untouched; deny reasons now name the offending verb instead of a hardcoded
  verb list. Corpus grew by 15 DENY cases and 10 ALLOW cases — the ALLOW side
  pinning that `git clean -xfd` and `find . -name '*.pyc' -delete` *inside* the
  worktree stay silent, since they are routine worker commands. A follow-on fix
  in the same window (`0077a46`) extends the walker to nested and following
  verbs so the table cannot lose coverage at a shell-operator boundary.

### Deprecated

- **`init`'s apply-gating flags are no-ops with named removal windows, not
  removals.** `--yes/--no-required-check`, `--yes/--no-labels`,
  `--yes/--no-board`, `--provision-board`, and `--tracker-mode projects` all
  still parse and still exit 0. Each now prints one line naming where its
  step went **and the release it is removed in**, then is ignored
  (`--tracker-mode projects` additionally coerces to `issues`);
  `--tracker-mode <anything-else>` is still refused with exit 2. **Nothing
  that passes them breaks** — this is deliberately not a breaking change.
  They are retained because of `VERSIONING.md`'s **CLI surface** contract
  row, which covers `bin/subcommands/*`: an *adopter's* own wrapper script,
  Makefile, or CI job may pass any of them, `init.sh` exits 2 on an unknown
  argument, and those callers cannot be enumerated from inside this repo.
  (The in-repo call sites are not the argument — this same change rewrote
  `install-tier2.yml` to stop passing them.) Two windows, because the flags
  do not share one story:
  - `--provision-board` and `--tracker-mode projects` are Projects-v2
    tracker-backend surface, and ride the **ADR-0004 Projects-arm removal
    release**.
  - The three consent pairs `--yes/--no-required-check`, `--yes/--no-labels`
    and `--yes/--no-board` gated a branch-protection PATCH and a label loop
    that existed on the issues-only path too, so ADR-0004's removal would
    never logically cover them — pinning them to it would leave them
    permanent no-ops wearing a deprecation label. They are removed at
    **v0.20.0, the pre-scope-down compat window**, together with `eject.sh`'s
    pre-scope-down `required_check`/`label`/`board` read-compat handlers:
    one window, because both halves serve exactly one cohort — a repo
    adopted before this change, whose config may still record that API state
    and whose wrapper scripts may still pass these flags.

  The affirmative forms (`--yes-*`, which *request* an action that no longer
  happens) warn and continue rather than exiting non-zero — a deliberate,
  reversible call consistent with the script's fail-open posture, revisited
  at the v0.20.0 removal.

### Removed — BREAKING

<!-- The `BREAKING` token appears TWICE for this release on purpose — on the
     `## [Unreleased]` heading above AND on this `### Removed` sub-heading.
     `changelog_breaking_sections()` (workflows/scripts/lib/changelog.sh) sets
     its `brk` flag ONLY from a heading line: `$0 ~ /BREAKING/` on the
     `## [x.y.z]` line, or `/^#+ .*BREAKING/` on a sub-heading. BODY TEXT
     NEVER SETS IT. So the sub-heading marker is the belt-and-suspenders half:
     it survives a release cut that rewrites `## [Unreleased]` into
     `## [0.19.0] - <date>` without carrying the ` — BREAKING` suffix across.
     Without at least one of these, `scripts/update-kernel.sh`'s acknowledgment
     gate (its `migration=` computation) and `bin/subcommands/update.sh`'s
     BREAKING warning both silently no-op, and a downstream overlay
     subtree-updates straight through this break with no acknowledgment.
     The v0.19.0 cut kept BOTH markers, and this section is what
     `changelog_breaking_sections v0.18.0 v0.19.0 CHANGELOG.md` prints — do
     not strip either one when editing history. -->

- **BREAKING — the `foundation` → `temperloop` rename compatibility window is
  CLOSED (temperloop#165, temperloop#764).** The read-old-write-new window
  opened in
  v0.15.0 with a stated v0.19.0 removal; this is that removal. Every legacy
  read is gone. **Nothing degrades silently** — each removed read was replaced
  by the legible refusal or diagnostic its window arm had already been
  simulating, so a caller still on a legacy name is *told*, by name, what to
  change:

  - **Legacy `FOUNDATION_*` env vars are no longer read.**
    `FOUNDATION_HOME`, `FOUNDATION_BIN_DIR`, `FOUNDATION_KERNEL_REPO`, and
    `FOUNDATION_VERSION` no longer act as fallbacks for their `TEMPERLOOP_*`
    twins in `bin/bootstrap.sh`, `bin/lib/common.sh`
    (`temperloop_env_compat`, `temperloop_resolve_version`),
    `bin/subcommands/feedback.sh`, or `claude/workflows/build-level.mjs`.
    Setting one *without* its `TEMPERLOOP_*` twin now **exits non-zero**
    naming the replacement — never a silent install at a path you did not ask
    for. Precedence is otherwise unchanged: a set `TEMPERLOOP_*` primary
    still wins **silently**, so a caller who has migrated but still carries a
    stale legacy export is unaffected.
    *Migration:* rename the variable (`FOUNDATION_HOME` → `TEMPERLOOP_HOME`,
    and so on).
  - **The `foundation` CLI shim no longer dispatches.** `bin/foundation`
    stops forwarding to `temperloop` and now refuses on every invocation,
    naming the replacement binary. The file itself is **deliberately kept**
    as a tombstone: a pre-v0.19.0 install left a `~/.local/bin/foundation`
    symlink pointing at it, and deleting the file would turn that symlink into
    a dangling "no such file or directory" instead of a message. A fresh
    `bootstrap.sh` install no longer creates the symlink at all. Disposing of
    an existing stale one is **manual**: `temperloop uninstall` does *not*
    remove it — it **prints the `rm -f` to run**, because the symlink is part
    of the bootstrap footprint (scope (a) of `bin/README.md` § Uninstall),
    written before any manifest existed, so uninstall has no record of it and
    deliberately will not infer one.
    *Migration:* invoke `temperloop <sub>`; to retire the old name on PATH,
    run the `rm -f ~/.local/bin/foundation` that `temperloop uninstall`
    prints.
  - **`init` no longer reads a legacy `.foundation/config`.** It **refuses**
    when one is present and no `.temperloop/config` exists, rather than
    restarting from a fresh install manifest on top of forgotten legacy state.
    *Migration:* `git mv .foundation .temperloop`.
  - **`baseline-snapshot` no longer appends to a legacy
    `.foundation/baseline.jsonl`.** It **refuses** when one exists, rather
    than silently splitting one append-only history across two directories
    (which truncates every later report's "before" anchor).
    *Migration:* `mkdir -p .temperloop && mv .foundation/baseline.jsonl
    .temperloop/`.
  - **The legacy `$XDG_CONFIG_HOME/foundation/boards.conf` machine conf is no
    longer read.** `board.sh` and `make doctor` now **name** a stranded legacy
    file on stderr instead of using it (or instead of silently falling through
    to the built-in maps with no explanation).
    *Migration:* `mkdir -p ~/.config/temperloop && mv
    ~/.config/foundation/boards.conf ~/.config/temperloop/`.
  - **The legacy `$XDG_DATA_HOME/foundation/knowledge` store root is no longer
    resolved.** `knowledge_store.sh` uses the `temperloop/` default and
    **names** a stranded legacy store on stderr — the case that would
    otherwise report "no notes found" against an empty new root while the real
    store sits one directory over.
    *Migration:* move the store, or set `KNOWLEDGE_STORE_ROOT`.

  **Deliberately NOT removed** (migration aids for an existing install, not
  window-scoped compat): `temperloop eject` / `temperloop uninstall` still
  clean a legacy `.foundation/` per-repo dir and a stale `foundation` PATH
  symlink, and the report auto-offer's read-only age probe still reads an
  un-migrated repo's legacy baseline.

  Registry/table follow-through in the same change: the four DEPRECATED
  `FOUNDATION_*` rows in `workflows/scripts/config/setting-registry.tsv` are
  removed and their four `TEMPERLOOP_*` twins' defaults no longer transcribe a
  `${FOUNDATION_*:-…}` fallback; the 8 `windowed` rows in
  `workflows/scripts/kernel/prerename-leak-verdicts.tsv` are removed and that
  verdict is retired in favour of `refusal`, which records the identifiers
  that legitimately survive *inside* the refusals and diagnostics above; and `bin/lib/common.sh`'s two internal
  install-path constants are renamed to `TEMPERLOOP_CLI_HOME_DEFAULT` /
  `TEMPERLOOP_CLI_BIN_DEFAULT`, dropping their pre-rename prefix.

- **BREAKING — the v0.17.0 terminology-consolidation compatibility window is
  CLOSED (epic temperloop#719, temperloop#767).** The read-old-write-new
  window opened in v0.17.0 with a stated v0.19.0 removal; this is that
  removal. The env shim, every forwarding stub at an old script path, the
  source-forwarder, and the legacy registry-filename resolution are deleted.
  Unlike the `foundation` → `temperloop` window above, these arms **fail
  silently by construction** — a stub is invoked by path and an env shim is
  sourced under `[ -f ]` — so there is no refusal to leave behind: a caller
  still on a legacy name now gets "no such file or directory" from its own
  shell, or simply no binding. The v0.17.0 `BREAKING` entry carries the full
  rename map; what is gone as of this release:

  - **Legacy `FUNNEL_*` / `KNOB_*` env vars are no longer read.**
    `workflows/scripts/lib/rename-compat-0170.sh` is deleted, along with
    **both** of its `[ -f ]`-guarded source blocks — the two in
    `workflows/scripts/build/build.config.sh` (including the second,
    post-conf-layer forwarding pass) and the one in
    `workflows/scripts/config/setting-registry-lib.sh`. A pre-rename env name
    now binds nothing and prints nothing, including one set by a layer-3
    machine conf or a layer-4 repo-local conf.
    *Migration:* rename the variable (`FUNNEL_<NAME>` → `PIPELINE_<NAME>`,
    `KNOB_<NAME>` → `SETTING_<NAME>`).
  - **The ten forwarding stubs at the old script paths are deleted.**
    `workflows/scripts/build/funnel-{cron,drive,tick,overlap,schedule-gate}.sh`,
    `workflows/scripts/build/build-config-knobs.sh`,
    `workflows/scripts/config/check-knob-{registry,prose}.sh`,
    `workflows/scripts/config/knob-registry-lib.sh` (the source-forwarder,
    which also re-exposed the `knob_registry_*` function names), and
    `workflows/scripts/validate-live-drain.sh`.
    *Migration:* invoke the renamed sibling (`pipeline-*.sh`,
    `build-config-settings.sh`, `check-setting-*.sh`,
    `setting-registry-lib.sh` + the `setting_registry_*` names, and
    `validate-capture-backstop.sh`).
  - **The legacy registry FILENAME and table spellings are no longer read.**
    `validate-capture-backstop.sh` stops resolving a pre-rename
    `claude/live-drain-registry.overlay.md` when the renamed
    `claude/capture-backstop-registry.overlay.md` is absent, and its table
    parser stops accepting the pre-rename `## Live/Drain pairings` heading and
    `| Live rule` column header. **This is the one arm that can degrade
    quietly:** an overlay checkout still shipping the old filename now reads
    as "no overlay extension present", so its rows are simply not validated.
    *Migration:* rename the file and its table heading/column.

  **Deliberately NOT removed** (not window-scoped compat): the
  `funnel-<YYYY-MM>.jsonl` telemetry read-union in
  `workflows/scripts/telemetry-brief.sh` and `pipeline-cron.sh --backfill`.
  The raw lake is append-only immutable history, so a pre-rename install's
  month-files can never be rewritten under the renamed prefix — that read is
  **permanent** and self-limiting (writers emit only `pipeline-*`), and is now
  documented as such in `meta/data/raw/README.md`. Also unchanged, exactly as
  the v0.17.0 rename promised: the persisted-state literal VALUES —
  the `funnel-merge-pending` / `funnel-escalated` GitHub labels, the
  `<!-- funnel:clarification-drained -->` / `<!-- funnel:decision-applied -->`
  issue markers, the `~/.claude/funnel/*` state paths, and the
  `/tmp/funnel-tick` lock dir.

  Registry follow-through in the same change (the fail-open arms above mean a
  half-removal fails nothing, so every registry that named a deleted path is
  pruned in lockstep): the `window` and `registry` exempt classes are deleted
  from `workflows/scripts/kernel/terminology-leak-exempt-files.txt`, leaving
  `record` + `self` — so `make test-kernel-terminology` now guards the
  surfaces the window used to own; `docs/features/feature-manifest.txt` and
  `workflows/scripts/kernel/kernel-manifest.txt` drop their claims on the
  deleted paths; and `workflows/scripts/tests/test_terminology_rename_compat.sh`
  is inverted from a READ-OLD-WRITE-NEW proof into a window-STAYS-SHUT
  regression test (a pre-rename name must bind nothing and say nothing, and no
  window file may reappear).

## [0.18.0] - 2026-07-26

### Added

- **`reconcile`: `--fix` gains a marker-lens repair (temperloop#748).** The
  marker lens could name a stale local claim marker every run forever without
  ever being able to clear one — `--fix` was `--status`-only. It now also
  applies one narrowly-scoped repair on the default marker lens: it clears
  **this window's** claim marker, via the same `claim_marker_clear` primitive
  `release.sh` uses, and only when that marker is `marker-without-board` drift
  **and** its issue is provably terminal (`CLOSED`/`MERGED` on GitHub). Still
  opt-in — without `--fix` the lens only reports. Deliberately never repaired:
  a marker whose issue is still open, any window other than the caller's own
  (the GH #297 doctrine), and the entire `board-without-marker` class, which
  temperloop#719 showed produces false stranded-claim signals. `--fix` remains
  rejected with `--labels` (that lens applies via `--apply`/`--unattended`).
  K#275 is untouched: `release.sh <n>` still refuses a non-latest claim, now
  pinned by `workflows/scripts/board/tests/test_release.sh`.

### Fixed

- **`ks_root()` resolves the rung-3 machine conf in the bare-env plane
  (temperloop#771, foundation#1328).** The store root resolved *differently*
  depending on whether the caller had sourced `build.config.sh`. A process that
  sources only `knowledge_store.sh` skipped the operator's rung-3 machine conf
  entirely and fell through to the kernel XDG default
  (`~/.local/share/foundation/knowledge`), while one that sourced
  `build.config.sh` resolved the real store — a split-brain that made the same
  helper return two different roots on one host. `ks_root()` now consults
  `KNOWLEDGE_STORE_MACHINE_CONF` (an isolated-subshell read, so the tracked
  `build.config.sh` is never sourced and no ordering is disturbed) between the
  env rung and the kernel default, so both planes agree. **Live impact:** this
  is the gap `session-start-drain.sh` fell into on every interactive session
  start — its vault path derives transitively from `ks_root()` via
  `KNOWLEDGE_STORE_OBSIDIAN_API_KEY_FILE` — silently failing **218 session
  drains across 16 consecutive days** on the reporting host before it was
  found. The new setting is registered in `setting-registry.tsv`;
  `knowledge_store.sh` test cases 3b–3f pin the rung (env still wins, machine
  conf beats the XDG default, and a missing/malformed/erroring conf falls
  through cleanly), and `test_stranger_config.sh` §§ G/H now pin
  `XDG_CONFIG_HOME` so their sandbox isolation is structural rather than
  accidental.

- **`doctor`'s knowledge-root check can actually see a split (temperloop#774,
  foundation#1332).** The check was degenerate: it compared `ks_root()` against
  a root *derived from* `KNOWLEDGE_STORE_OBSIDIAN_API_KEY_FILE`, whose own
  default is itself `$(ks_root)/…` — so it compared a value with itself and
  could never fail, including throughout the 16-day outage above. It now
  compares the two resolution planes directly (plane A, via `build.config.sh`,
  vs plane B, bare-env) and reports a genuine divergence. Covered by
  `test_doctor_knowledge_root.sh`; `docs/features/knowledge-store.md`'s
  "Agent-plane vs. script-plane routing" prose is updated to describe the
  plane-A/plane-B comparison instead of the retired key-file derivation.

- **`pipeline-schedule-gate.sh`: an unresolvable store root no longer reads as
  the operator's kill switch (foundation#1329).** Every skip verdict was
  already fail-closed alike, but a resolution bug (a stale/renamed
  `PIPELINE_SCHEDULE_FILE` path — the concrete instance behind this fix,
  temperloop#768) and the operator's deliberate `enabled: no` produced
  `reason` text that was easy to mistake for one another at a glance, so the
  live case went unnoticed: the pipeline was off for the wrong reason and
  nothing in the log said so. The gate's skip messages now carry one of two
  mutually-exclusive tags — `"store root did not resolve / control note
  unreachable"` for a missing/unreadable file or a missing fenced block, vs.
  `"control note present, not a resolution failure"` (with the existing
  `"kill switch"` wording preserved for the explicit `enabled: no` case) — so
  a resolution failure can never be reported as the kill switch, or vice
  versa. Both branches remain fail-closed (exit 1, zero `gh` calls); only the
  `reason` text changed. New gate 11 in `tests/test_pipeline_cron.sh` asserts
  the two reasons are distinct and never cross-tagged.

- **Issues-only backend: reaching Done clears the claim stamp
  (temperloop#744).** A closed issue kept its `fnd:host/session:<host>:<sess8>`
  label, so it read as permanently claimed — `issue-state.sh resolve` returns
  `claimed-elsewhere` off exactly that label, and nothing swept it. Fixed at
  both altitudes. **Root cause:** `_board_issues_set_field`'s Done arm now
  strips every `fnd:host/session:*` label alongside the `fnd:status:*` label
  before closing (a non-Done status write still leaves the stamp alone — a park
  back to Ready may legitimately still hold the claim). **Backstop:** the
  dominant close path is a merged PR's native `Closes #N`, which runs no adapter
  code at all, so `reconcile.sh --labels` gains class **(j)** — a
  `fnd:host/session:*` label on a CLOSED issue, stripped per-issue by `--apply`,
  with the same immediate re-check (an issue reopened in the scan→apply gap is
  never stripped) and idempotence as the other classes. It is not reachable by
  the existing orphaned-label class (g), which deletes a repo label *object*
  only when it is attached to zero OPEN issues: while any open issue still wears
  the stamp, the object is correctly kept and every closed issue wearing it stays
  stranded. Sweep the accumulated backlog with one command —
  `workflows/scripts/board/reconcile.sh --board 7 --labels --apply` (or
  `--labels` alone for the zero-write report).

- **Retargeted the temperloop#165 `.foundation/` rename-window close from
  v0.17.0 to v0.19.0 (temperloop#764).** ~86 markers across the tree stated the
  legacy `foundation`-named reads (the `bin/foundation` shim, `FOUNDATION_*`
  env vars, `.foundation/config`, `.foundation/baseline.jsonl`, the legacy
  machine `boards.conf` path, the legacy `foundation/knowledge` store) were
  "removed in v0.17.0" — but v0.17.0 shipped as the #719 terminology release
  without performing that removal, so every marker was stale. They now name the
  real close version, **v0.19.0**, where #719's own legacy window also closes
  (one adopter migration, not two). temperloop#764 stays **open** to track the
  actual `.foundation/` removal at the v0.19.0 cut — this entry records only the
  marker retarget. No behavior change — the legacy reads still resolve exactly as
  before; only the documented close version moved.

## [0.17.0] - 2026-07-25 — BREAKING

One-shot pre-GA terminology consolidation (temperloop#729, epic #719
(prose-plane subtraction and budget), ADR 0017): one name per concept,
plain words over coinages, applied as a single rename so adopters relearn
once instead of per-release. **An overlay or consuming checkout must
migrate by the map below before pulling** — `update-kernel` requires the
usual breaking ack (`KERNEL_ALLOW_BREAKING=1` or the interactive confirm).
A legacy read window (env vars, old script paths, the old overlay-registry
filename, the old telemetry month-file glob) forwards with deprecation
NOTEs until **v0.19.0**.

### Changed — the full rename map

**Vocabulary (one name per concept, everywhere):**

| Old term | New term |
|---|---|
| funnel (the bug→PR flow; the autonomous driver) | pipeline |
| knob (a tunable config value) | setting |
| `blocking-now` severity | `ask-now` |
| `batch-at-gate` severity | `ask-at-gate` |
| `batch-at-ritual` severity | `ask-at-checkin` |
| ritual | contextual, not 1:1 — check-in where it names the daily `/check-in` review; otherwise routine / review / step / session as the sentence requires |
| build spine (the shared build scripts) | build machinery |
| design spine (docs/cognitive-load.md only) | design backbone |
| precedence rung (config ladder) | precedence layer |
| funnel rung 5a/5b/5c (autonomy ladder) | autonomy level 5a/5b/5c |
| Live/Drain pairing (live half / drain backstop) | Capture/Backstop pairing (capture half / backstop) |
| logical board number | board id |

**Env / setting names (prefix rule — every var, registry-listed or not):**

- `FUNNEL_<NAME>` → `PIPELINE_<NAME>` (44 registry rows, plus e.g.
  `FUNNEL_OPERATOR_ABSENT` → `PIPELINE_OPERATOR_ABSENT`)
- `KNOB_<NAME>` → `SETTING_<NAME>` (the registry/prose-lint seams:
  `KNOB_REGISTRY_*` → `SETTING_REGISTRY_*`, `KNOB_PROSE_*` → `SETTING_PROSE_*`)
- Legacy env reads keep working through v0.19.0 via
  `workflows/scripts/lib/rename-compat-0170.sh` (NEW > OLD > default; one
  NOTE per legacy var used), sourced by `build.config.sh` and
  `setting-registry-lib.sh`.

**Renamed files (forwarding stubs at every old executable/sourceable path
through v0.19.0):**

- `workflows/scripts/build/funnel-cron.sh` → `pipeline-cron.sh`
- `workflows/scripts/build/funnel-drive.sh` → `pipeline-drive.sh`
- `workflows/scripts/build/funnel-tick.sh` → `pipeline-tick.sh`
- `workflows/scripts/build/funnel-overlap.sh` → `pipeline-overlap.sh`
- `workflows/scripts/build/funnel-schedule-gate.sh` → `pipeline-schedule-gate.sh`
- `workflows/scripts/build/funnel-drive.settings.json` → `pipeline-drive.settings.json` (no stub — data)
- `workflows/scripts/build/funnel-drive-merge.settings.json` → `pipeline-drive-merge.settings.json` (no stub — data)
- `workflows/scripts/build/build-config-knobs.sh` → `build-config-settings.sh`
- `workflows/scripts/config/knob-registry.tsv` → `setting-registry.tsv` (no stub — the lib resolves it)
- `workflows/scripts/config/knob-registry-lib.sh` → `setting-registry-lib.sh` (source-forwarder keeps the old path AND the old public `knob_registry_*` function names working)
- `workflows/scripts/config/knob-registry-exempt-files.txt` → `setting-registry-exempt-files.txt`
- `workflows/scripts/config/knob-prose-baseline.tsv` → `setting-prose-baseline.tsv`
- `workflows/scripts/config/check-knob-registry.sh` → `check-setting-registry.sh`
- `workflows/scripts/config/check-knob-prose.sh` → `check-setting-prose.sh`
- `workflows/scripts/validate-live-drain.sh` → `validate-capture-backstop.sh`
- `claude/commands/funnel-drive.md` → `pipeline-drive.md`
- `claude/commands/funnel-drive-merge.md` → `pipeline-drive-merge.md`
- `docs/features/build-spine.md` → `build-machinery.md`
- `docs/features/funnel-driver.md` → `pipeline-driver.md`
- test suites renamed alongside their subjects (`test_funnel_*` →
  `test_pipeline_*`, `test_build_config_knobs.sh` →
  `test_build_config_settings.sh`, `test_knob_registry.sh` →
  `test_setting_registry.sh`, `test_check_knob_*` → `test_check_setting_*`)
- **telemetry stream**: the pipeline tick's raw-lake month-files are now
  written `pipeline-<YYYY-MM>.jsonl` (previously `funnel-<YYYY-MM>.jsonl`).
  Writers emit only the new name; readers (`telemetry-brief.sh`, and
  `pipeline-cron.sh --backfill`) union the legacy `funnel-*.jsonl`
  month-files in read-only, with a one-line NOTE, through v0.19.0 — an
  existing install's accumulated history stays visible. Legacy files are
  never renamed in place.

**Pipeline command contracts:** the slash commands `/funnel-drive` and
`/funnel-drive-merge` are now `/pipeline-drive` and `/pipeline-drive-merge`.

**Message-schema template names: NONE renamed.** All five (`PR-body
skeleton`, `Parking note`, `Digest entry`, `Question block`, `Degradation
notice`) were already plain words — an overlay's named-template overrides
need no change.

**Parsed / structural surfaces:**

- `claude/CLAUDE.kernel.md` § `Prose-resident knob convention` →
  § `Named-setting convention` (every § pointer updated).
- `claude/commands/tidy.md`'s registry table: `## Live/Drain pairings` →
  `## Capture/Backstop pairings`, columns `Live rule | Live location |
  Drain backstop` → `Capture rule | Capture location | Backstop`.
  `validate-capture-backstop.sh` parses **both** spellings through v0.19.0.
- Overlay extension registry file: `claude/live-drain-registry.overlay.md`
  → `claude/capture-backstop-registry.overlay.md` (the validator reads the
  legacy filename with a NOTE when the new one is absent, through v0.19.0).
- `temperloop config list`: TSV column 2 renamed `rung` → `layer` (text
  header `RUNG` → `LAYER`) — aligns the CLI with the registry's own
  `layer` column.
- Annotations: `# knob:exempt` → `# setting:exempt`;
  `<!-- knob-prose:allow -->` → `<!-- setting-prose:allow -->`.
- Make targets: `validate-live-drain` → `validate-capture-backstop`.

### Added

- `make test-kernel-terminology` — leak gate
  (`workflows/scripts/kernel/check-terminology-leak-guard.sh`, in
  `KERNEL_GATES`): pre-rename identifiers cannot silently re-enter a
  stranger surface; only the reviewed exempt set (the compat window's own
  files + records) may carry them.
- `workflows/scripts/tests/test_terminology_rename_compat.sh` — the legacy
  window's behavior contract (6 hermetic cases), in `KERNEL_GATES`.

### Deliberately NOT renamed (migration note)

- **Persisted external state keeps its pre-rename values** (the temperloop#165
  `.foundation/` precedent — renaming them would orphan live state): the
  `funnel-merge-pending` / `funnel-escalated` GitHub labels, the
  `<!-- funnel:clarification-drained -->` / `<!-- funnel:decision-applied -->`
  issue markers, `~/.claude/funnel/*` state paths, and the
  `/tmp/funnel-tick` lock dir. Setting *names* renamed; *values* stable.
- `workflows/scripts/drain/` and the `session-start-drain.sh` hook —
  "drain a queue" is literal English there, and hook names are a contract
  surface with no confusion evidence.
- `claim`/`release`, `worktree`, `merge queue`, `sweep`, `gate` — already
  plain or industry-standard.
- Historical records (this CHANGELOG's earlier sections, `docs/adr/`,
  archived plans, knowledge-store notes) keep old terms — they are
  records, not live contracts.

## [0.16.0] - 2026-07-25

Non-breaking minor bump: several additive capabilities across the pipeline
commands, the board adapter, the report, and the plan schema, plus a batch of
fixes. **No contract surface is removed** — the temperloop#165 rename's legacy
reads remain through their v0.17.0 window, so no overlay must change to pull
this tag.

### Added

- **`report`: directional dollar framing from a user-supplied pricing table
  (temperloop#882).** The report can translate token/latency deltas into a
  directional `$` figure when the operator supplies a pricing table — opt-in,
  no pricing assumed by default.
- **`plan`: a `cost:` block flags expensive work (temperloop#1059).** A plan
  item may carry a `cost:` block so `/build` can surface and gate expensive
  work before it runs; the pre-check reads it at the level merge gate.
- **`build`: combined-tree pre-check at the level merge gate (F#865).** Before
  a level's merge set is approved, a combined-tree pre-check runs across the
  set; its opt-out knob is named symbolically and registered in
  `knob-registry.tsv`.
- **`build`: push-notify the operator on every `blocking-now` halt
  (temperloop#695).** Every modal halt now emits an operator push notification
  so an unattended run's blocking gate is not silent.
- **`capture`: `--title` accepted as an alias for the positional title
  (temperloop#1227).** `capture.sh` now takes `--title <t>` in addition to the
  positional form, removing a recurring invocation footgun.
- **`board`: `board_blocked_by_add` / `board_blocked_by_remove` writers
  complete the adapter contract.** The native `blocked_by` dependency edge is
  now writable through the adapter, not just readable.
- **`assess`: require an owned host-config/secret seam when acceptance names a
  credential (temperloop#716).** A plan item whose acceptance references a
  credential must declare an owned host-config/secret seam.
- **`demo`: de-personalize the seed-demo-repo default target
  (temperloop#871).** The demo seeder no longer defaults to a personal target.

### Changed

- **`ks_search`: register the basic-memory project lazily, not per query
  (temperloop#996).** Project registration moved out of the per-query hot path.
- **`deploy-mini`: route §3 conf discovery through `board.sh`'s resolver
  (temperloop#616).** Conf discovery reuses the adapter resolver instead of a
  bespoke path.
- **`kernel`: retire `seed-kernel-repo.sh` and trim `kernel-repo-layout.md`
  (temperloop#681).** Removes a superseded seeding script (not a contract
  surface — no adopter couples to it).
- Documentation: authored `tracker.contract.md` (the tracker-adapter interface
  contract, temperloop#891); ADR renumbering + premise-gate/principles-charter
  ADRs; `/workshop` persist-then-ask ordering contract and reviewer-finding
  folds; a kernel rule to disconfirm a root-cause diagnosis before
  institutionalizing it (temperloop#1090).

### Fixed

- **`build`: embed the FOREGROUND-ONLY gate contract in the worker prompt
  (temperloop#712).** `/build` workers backgrounded `quality-gates.sh` and
  ended their turn awaiting a Monitor notification a subagent never receives,
  returning no verdict. `build-level.mjs`'s generated `workerPrompt()` now
  embeds the FOREGROUND-ONLY contract (prevention, both the main and spike
  prompts) and the one null-verdict re-spawn appends `FOREGROUND_CURE` so the
  retry differs from the first attempt (cure); `build.md` §3c/§3d kept in
  lockstep.
- **`drain`: damp the lexicon on spec-authoring sessions (temperloop#1137).**
- **`hooks`: make the MCP preflight `/search/smart` probe body-aware
  (temperloop#1224 Part 1).**
- **`kernel`: resolve symlinks before kernel/overlay classification
  (temperloop#1050).**
- **`degradation`: bounded remedy pointer on the live Mode-2 agent-gate skip
  line.**
- **`plan-schema`: spec-prose model-stamping carve-out (temperloop#672).**

## [0.15.1] - 2026-07-23

### Fixed

- **`quality-gates.sh`: kernel self-distribution tests are now CLASS-gated on a
  vendoring-consumer signal (temperloop#691).** v0.15.0 guarded
  `test_update_subcommand` / `test_update_kernel` surface-conditionally so a
  bespoke-subtree vendoring consumer skips them, but left `test_rename_compat`,
  `test_bootstrap_tag_pinning`, and `test_version_embedding` **unconditional** —
  they require the `bin/bootstrap.sh` + repo-root `VERSION` surface a vendoring
  consumer does not carry, so no surface choice let such a consumer's
  `make quality-gates` go green (surfacing `bin/` to satisfy them also flips on
  `test_update_subcommand`, whose managed-clone CLI cannot traverse a composed
  tree's symlinked kernel dirs via `git show <ref>:<path>`). All four
  self-distribution / self-update tests are now gated as a CLASS on one signal —
  a repo-root `.kernel-pin` marks a vendoring consumer (the kernel's own
  checkout has none), so the kernel runs all four and every consumer skips all
  four legibly. Categorical by design: a future self-distribution test joins the
  list and is excluded from consumers with no per-test guard drift. **No
  behavior change in the kernel's own CI** — all four still run there.

## [0.15.0] - 2026-07-23 — BREAKING

**`BREAKING`** — ships as a **minor-breaking 0.x bump (v0.15.0)** per
VERSIONING.md's pre-1.0 rules: the foundation→temperloop identity rename
(temperloop#165), **read-old-write-new**. Every legacy `foundation` name
keeps working through the migration window with a one-line deprecation
notice, and the legacy reads are **removed in v0.17.0** — touch your
overlay/config/env before that release, not necessarily before this pull.

> **[Later correction — 2026-07]** The removal did **not** land in v0.17.0:
> that version shipped as the epic #719 terminology release. The temperloop#165
> `.foundation/` window was **retargeted to v0.19.0** (see the `[Unreleased]`
> entry above; temperloop#764). The original v0.17.0 dates below are left intact
> as the record of what was announced at v0.15.0.

### Changed

- **BREAKING — the stranger-facing `foundation` names are renamed
  `temperloop` (temperloop#165), read-old-write-new; legacy names are
  removed in v0.17.0.** The surfaces, each with new-name canonical + a
  windowed legacy read:
  - **Env-var prefix**: `TEMPERLOOP_HOME` / `TEMPERLOOP_BIN_DIR` /
    `TEMPERLOOP_KERNEL_REPO` / `TEMPERLOOP_VERSION` are the canonical env
    knobs (bootstrap, dispatcher, feedback, CI, sandbox). A set legacy
    `FOUNDATION_*` var still works while its twin is unset (precedence:
    new > old > default) and prints a one-line deprecation notice. Knob
    registry: four new `TEMPERLOOP_*` rows; the `FOUNDATION_*` rows are
    marked `DEPRECATED` in their doc column and are deleted in v0.17.0 — a
    removed row-name, i.e. BREAKING per the registry's own rule, which is
    exactly what this marked section signals.
  - **CLI compat shim**: `foundation <sub>` still dispatches (now printing
    one deprecation NOTE per invocation); the shim is removed in v0.17.0 —
    invoke `temperloop`.
  - **Committed per-repo config**: `temperloop init` writes
    `.temperloop/config` (recovery marker + self-managed `.gitignore`
    included); a legacy `.foundation/config` is still read on re-run, and
    `temperloop eject` cleans either dir (legacy cleanup deliberately
    survives the window). `baseline-snapshot` continues an existing legacy
    baseline in place; `report` and the 14-day offer probe new-then-legacy
    for `baseline.jsonl` and `report.d/`.
  - **Legacy `$XDG_CONFIG_HOME/foundation/` subdir**: the machine
    boards.conf default is now `$XDG_CONFIG_HOME/temperloop/boards.conf`;
    an existing legacy `foundation/boards.conf` is read as fallback at all
    seven reader sites (board.sh, funnel-drive/tick, deploy-mini, doctor,
    links).
  - **Knowledge-store default namespace** (published-contract change,
    `knowledge_store.contract.md`): the default root is now
    `${XDG_DATA_HOME:-$HOME/.local/share}/temperloop/knowledge`; an
    existing store at the legacy `foundation/knowledge` default is still
    found (one NOTE per process). Fresh installs create under
    `temperloop/`.
  - **Grandfathered machine-state paths deliberately NOT migrated here**
    (allowlisted-as-legacy; the gate-sweep item formalizes):
    `ENV_RECONCILE_AGENT_HEARTBEAT_DIR` and the
    `${XDG_STATE_HOME}/foundation/` machine-state family (hook state dirs,
    `KNOWLEDGE_READ_LOG`, `KNOWLEDGE_SEARCH_BM_HOME`, report-offer
    dismissals) — cross-host writers/readers (launchd agents,
    env-reconcile freshness oracles) update on their own cadence, and a
    split-state window is worse than a delayed coordinated move. `KS_LIB_DIR`
    needs no action (name-neutral, no foundation-named default).

  **Migration** (any time before v0.17.0): rename `FOUNDATION_*` env vars
  to `TEMPERLOOP_*` in your shell profile/CI/overlay config; switch
  `foundation <sub>` invocations to `temperloop <sub>`; `git mv .foundation
  .temperloop` in any repo you ran `init` in (or run `temperloop eject` /
  re-`init`); `mkdir -p ~/.config/temperloop && mv
  ~/.config/foundation/boards.conf ~/.config/temperloop/`; and `mv
  "${XDG_DATA_HOME:-$HOME/.local/share}/foundation/knowledge"
  "${XDG_DATA_HOME:-$HOME/.local/share}/temperloop/knowledge"` (or set
  `KNOWLEDGE_STORE_ROOT`). Until you migrate, everything keeps working —
  each legacy use tells you so on stderr. New hermetic gate:
  `test_rename_compat.sh` (legacy-env install, shim dispatch,
  adjacent-tag update through the shim, legacy on-disk artifact reads, and
  the window-closed legible-degradation simulation).

- **`/sweep` Phase 2 is now chunked parallel fanout (temperloop#671, the
  sweep-parallelization epic; tier 1 of ADR 0012).** The Ready-singleton fix loop no longer drives one issue at
  a time: the Phase-2 set partitions into chunks of up to
  `SWEEP_FANOUT_WIDTH` issues, each chunk one synchronous multi-item
  `build-level.mjs` invocation (the same within-level parallel path `/build`
  uses) followed by a per-chunk merge pass, with the quota gate moved from
  per-issue to per-chunk. Phase-1 underspecification detection fans out
  across parallel subagents at the `SWEEP_DETECT_MODEL` tier (empty default
  = inherit the session model). **Not BREAKING — `SWEEP_FANOUT_WIDTH=1` is
  the downstream opt-out lever**: setting it restores the prior behavior
  exactly (sequential drive, questions-first ordering), config-only, no
  spec revert. Resource-posture note for kernel-sync adopters: at the
  default width a sweep run now opens up to chunk-width **concurrent CI
  runs** (and board WIP rises to the chunk width) — a repo whose CI
  capacity can't absorb that sets the knob down (or to `1`). See
  `docs/adr/0012-sweep-two-tier-parallel-execution.md`; the background
  overlap tier (tier 2) is deliberately not included.

### Added

- **The release version is now embedded in the shipped files
  (temperloop#677).** A committed repo-root `VERSION` file (bare `x.y.z`) is
  the source of truth `temperloop version` reports, resolved by the shared
  `temperloop_resolve_version` helper in `bin/lib/common.sh` — precedence
  `TEMPERLOOP_VERSION` env > `FOUNDATION_VERSION` env (rename window) >
  `VERSION` file > `dev`. Previously a real tag-pinned install reported
  `temperloop dev` because nothing embedded the number; now the artifact
  carries its own version. A release cut **bumps `VERSION` in the tagged
  commit** (kernel-repo-layout.md § Release-tag convention), and
  `test_version_embedding.sh` (a `checks` gate) fails the build if `VERSION`
  drifts from the tag when HEAD is a release tag. The `install-tier2`
  round-trip gains a `version` leg asserting the installed CLI reports its
  embedded version, not `dev`. Additive: an explicit `TEMPERLOOP_VERSION`
  override still wins, so CI/test fixtures are unchanged.
- **`claude/design-schema.md` § Kernel dimension list gains dimension `0`
  — Premise & null hypothesis (temperloop#508, epic temperloop#498).**
  Additive, not breaking: no existing dimension is removed, reordered, or
  has its enforcing-gate binding changed — dimensions 1–16 keep their
  numbers and meaning unchanged. The new row records the do-nothing cost,
  the strongest subtraction/existing-surface alternative, and the
  operator's justification for proceeding (or the kill rationale), enforced
  by the forthcoming `/workshop` Step 1.3b premise gate (temperloop#509).
  **Dimension 0 spends the schema's only prepend slot**: numbering it `0`
  (rather than appending `17`) is what lets it sort and be walked *first*,
  ahead of every other dimension, without renumbering 1–16 — but that slot
  is a one-time move. A future *intake-time* dimension (one that must also
  walk before dimension 1) cannot reuse this trick a second time; it forces
  a real renumbering of the kernel list. Never reach for a negative number
  (`-1`) to dodge that — see § Overlay extensibility's numbering-namespace
  note in the schema doc for why the namespace is reserved the way it is.
  Dimension 0 is also the schema's first **`filled`-only** dimension: `n/a`
  and `deferred` are invalid dispositions for it (§ Disposition grammar) —
  a deferred premise is exactly the unexamined-idea gap the gate exists to
  close. The worked-example skeleton gains a matching `## 0.` section.
  **Migration note for in-flight `draft` briefs:** an existing `Designs/*.md`
  brief written before this change has no dimension-0 section; it needs a
  **one-touch migration** — add `## 0. Premise & null hypothesis` with a
  `filled` disposition — before it can pass a ratify-time coverage check
  that includes dimension 0. A brief already `status: ratified` is
  unaffected (ratified briefs are immutable per § Frontmatter; the gap is
  grandfathered, not retroactively invalid). Same-PR opportunistic cleanup:
  every stale `/design` command reference in `claude/design-schema.md` is
  updated to `/workshop` (the command was renamed in temperloop#354; this
  schema doc had not yet been swept), and the doc's dimension-count prose
  (`claude/design-schema.md`, `claude/commands/workshop.md`,
  `docs/features/workshop.md`) is updated from sixteen/16 to
  seventeen/17 throughout.

- **`claude/design-schema.md` § Frontmatter `status` enum gains `dropped`
  (temperloop#509, epic temperloop#498).** Additive, not breaking: `draft`
  and `ratified` keep their meaning and the `draft → ratified` ratify path is
  unchanged. `dropped` is a third **terminal** value a brief reaches only via
  the new `/workshop` Step 1.3b premise-gate **drop action** — a killed idea
  whose dimension 0 carries the kill rationale (disposition `filled`), neither
  ratified nor materialized. **A consumer or overlay that pattern-matches the
  `status` field on `draft|ratified` must be told about `dropped`** (a lint,
  dashboard, or reader enumerating brief states) — hence this additive marker,
  parallel to the dimension-0 additive note above. Reopening a `dropped` brief
  requires an explicit operator confirmation (`/workshop` Step 1.4 stops on a
  dropped brief rather than silently re-adopting it as a draft). The paired
  `/workshop` prose change — the Step 1.3b premise gate (composes the case
  *against* citing `docs/principles.md` by name, records the operator's
  justification into dimension 0, offers proceed/reshape/drop) plus the Step
  1.4 dropped-branch stop-and-reopen-confirm — ships in the same PR.
- **Release version embedded in shipped files (temperloop#677).** `temperloop
  version` now reports the tagged release version from a committed repo-root
  `VERSION` file (resolution order: env override > `FOUNDATION_VERSION` rename
  window > `VERSION` file > `dev`) instead of always printing `dev`. A
  `test_version_embedding.sh` drift guard asserts `VERSION == X.Y.Z` when HEAD
  is exactly a `vX.Y.Z` tag, and install-tier2 gains a `version` leg.
- **`sweep` gains chunked, tiered fan-out.** Phase 2 is rewritten as a chunked
  synchronous fan-out (tier 1, temperloop#683), with an added attended
  question-overlap pass (tier 2, temperloop#685); new `SWEEP_FANOUT_WIDTH` and
  `SWEEP_DETECT_MODEL` knobs tune fan-out width and the detection model
  (temperloop#676).
- **`tidy` delete-on-PR-record archive semantics (temperloop#667).** The
  session-archive step records its PR and cleans up on record (Step 5 plus a
  Step 0 early-exit); `check-in` now surfaces a pending (unmerged) tidy archive
  PR.

### Deprecated

- **The Projects-v2/GraphQL board adapter arm is deprecated (epic
  temperloop#460), removed by the follow-on BREAKING removal epic
  temperloop#524 "Remove the Projects-v2/GraphQL arm (BREAKING) —
  post-soak follow-on to epic #460".** Classified **non-breaking/minor**
  for *this* bullet: marking an arm deprecated changes no behavior — the
  GraphQL arm remains fully functional through the soak window this entry
  opens, and `changelog_breaking_sections()` (`workflows/scripts/lib/
  changelog.sh`) can't parse this untagged `## [Unreleased] — BREAKING`
  section's per-bullet classification (its `BREAKING`-marker scan is
  section-level, keyed off `VERSIONING.md`'s bump-rules table), so the
  classification is stated here in prose instead — precedent: the
  worklist-Seq-retire bullet above does the same. All four fleet boards
  (ssmobile, stageFind, subsetwiki, foundation) plus the kernel's own
  tracker now run issues-only per ADR 0004; the GraphQL arm (the budget
  guard, the structure/state cache split, `migrate-board-to-issues.sh`,
  and the rest of the Projects-v2 branchwork) stays live and supported for
  any adopter still migrating, and is removed outright — a real BREAKING
  cut — once the removal epic ships, per its own migration-ordering
  contract.

### Removed

- **`workflows/scripts/board/worklist.sh`: the Seq display column and its
  `.seq // 9999` sort key are retired (temperloop#474, epic
  temperloop#460) — the read-side completion of ADR 0006's Seq
  retirement.** Classified **non-breaking/minor** against VERSIONING.md's
  Board adapter interface contract-surface row: `worklist.sh`'s
  human-readable text output is not one of that row's coupling points
  (`board_resolve_item` / `board_resolve` / `board_item_list` /
  `board_set_*` function signatures and JSON shapes are all untouched), and
  by this level every registered board (all four fleet boards plus the
  temperloop issues-only tracker) is issues-backed per ADR 0006 — no board
  has carried a live Seq value since the write side (`board_set_number`)
  was already changed to fail loud at epic temperloop#460's L0, so the
  column has been permanently empty everywhere it could still render.
  Output is otherwise unchanged: the `--all` and default (In-Progress)
  views keep the same remaining columns, and sort order now falls back to
  ascending issue number (`sort_by(.content.number)`, replacing
  `sort_by(.seq // 9999)`) for deterministic ordering. The two header
  comments mentioning Seq are updated to match.

### Fixed

- `reconcile.sh`: shellcheck directive on the label-lens optional
  knowledge-store source is now `disable=SC1090,SC1091` (was `source=<path>`)
  — the sync deliberately omits that lib from consumer repos and the runtime
  already skips fail-open behind an `-f` guard, so a consumer's bare-shellcheck
  CI no longer fails on the synced copy (#495).
- **`check-kernel-manifest.sh` runs against a vendored subtree root
  (temperloop#680).** Its `.git` hard-guard is relaxed (via `git rev-parse
  --is-inside-work-tree`) so a downstream overlay can gate kernel-manifest
  coverage against its vendored `kernel/` subtree — the enabler a downstream
  coverage gate consumes. Running against the kernel repo's own root is
  unchanged; a subtree-root regression test covers both the classified (green)
  and unclassified (red, names the path) cases.
- **`build` pipeline robustness.** The 3e.5 acceptance gate is now hermetic
  against the pipeline's own config knobs (temperloop#684) and tests the
  worktree rather than repoRoot (temperloop#663); the conversational path is
  guarded against workers backgrounding the quality gate (temperloop#678);
  epic auto-close is guarded against body-only acceptance loss (temperloop#668);
  `build-level` claims spike items before the verdict-park (claim-first,
  temperloop#664) and wires the `NO_CI` outcome into the spine schema and CI
  poll loop (temperloop#662).

## [0.14.1] - 2026-07-18

Patch. Safe pull, no migration — no `BREAKING` marker. CI-portability fix
for composed consumer trees (temperloop#488): the two v0.14.0 gate
registrations that test kernel-context surfaces — the `bin/subcommands/
update.sh` managed-clone CLI gate and the `scripts/update-kernel.sh`
breaking-delta gate — are now **surface-conditional**. Each registers only
when its surface is actually present (a `bin/subcommands/update.sh` file;
the seam-bearing `update-kernel.sh`, detected by its `KERNEL_UPDATE_ROOT`
test seam) and otherwise prints a legible `skipped gate — <reason>` line,
in both the run output and `--list` (`[skipped]` rows). In the kernel's own
checkout both surfaces exist, so both gates always run — behavior there is
unchanged. A consuming repo whose composed tree legitimately lacks the
surface (no `bin/` adoption; a bespoke overlay vendoring flow) no longer
fails CI on tests for code it doesn't ship.

### Fixed
- `scripts/quality-gates.sh`: `test_update_subcommand.sh` and
  `test_update_kernel.sh` registrations guard on their surface, with
  legible skip lines — never a silent no-op (#488).

## [0.14.0] - 2026-07-18

Additive minor. Safe pull, no migration — no `BREAKING` marker. The headline
is the **issues-only tracking changes** (epic #460's first dependency
level): the `boards.conf`
backend axis now resolves per-key so a machine conf silent on a board no
longer shadows a committed repo-local `backend=issues` flip,
`board_set_number` fails loud on the issues-only backend (Seq retired by
design, ADR 0006), a dry-run-first Projects→issues migration script ships,
and `/tidy` gains a board label-hygiene sweep. Draft ADRs 0004–0006 (all
`Status: Proposed`) land alongside, recording the issues-only-default
decision, the repo-local conf-cutover mechanism, and the Seq retirement.
**Soak-window note:** the issues-only path is deliberately uncached and
always-live, and migrating the four maintainer boards onto it (this epic's
follow-on cutover work) is the first real volume test of that posture — REST
consumption is monitored during the soak window that follows this release,
with the existing per-board `cache=on` axis (`boards.conf`) as the ready
mitigation (ADR 0004 § Consequences).

The release also carries the `/check-in` pipeline-command contract
**growing** (its Part 1 telemetry brief now renders kernel-side on every
checkout; nothing existing changes shape — the overlay renderer keeps its
exact guarded invocation as an enrichment) plus the additions below.

### Fixed

- **`board_backend()` resolves the `boards.conf` backend axis per-key, not
  whole-file (#478, closes #465).** A machine-level conf that is silent on a
  given board's backend no longer shadows a committed repo-local
  `backend=issues` flip: a new `_board_conf_get_layered()` helper walks every
  existing conf file (machine, then repo-local) and returns the first
  per-key match, for the `backend` axis only — every other axis
  (`repo`/`owner`/`project`) keeps the original whole-file "first hit wins"
  behavior (`test_boards_conf.sh` section 3 pins it unchanged). An explicit
  machine-level `backend=` line still wins outright.
- **`board_set_number` fails loud on the issues-only backend — Seq retired
  by design, not emulated (#480, closes #464, ADR 0006).** A new `ISSUE_*`
  case branch replaces a silent `return 1` with a documented stderr message
  naming the retirement (ordering now lives in epic dependency levels and
  milestones); its test asserts on the message with stderr unsuppressed.
  `claude/commands/triage.md`'s three Seq special-case sites and
  `ISSUES-ONLY-BACKEND.md`'s two Seq rows are reworded from "deferred" to
  "retired by design"; `worklist.sh`'s Seq column/sort key is intentionally
  untouched (read-side retirement is a follow-on item).

### Added

- **`migrate-board-to-issues.sh` — dry-run-first Projects→issues migration
  script (#481, closes #466).** Reads a board's Status/Component via the
  Projects arm and writes `fnd:` labels via the existing issues-arm write
  path (`board_set_status`/`board_set_component`), with schema-level
  validation that refuses an unrecognized single-select field or Status
  option before any write. Dry-run is the default (prints the full
  field-to-label mapping table, zero writes); `--apply` writes and then
  verifies every open item reads identically through `backend=issues`;
  idempotent (a second `--apply` reports zero changes); emits a per-repo
  report. Covered by a fixture-replay test suite, zero network.
- **`reconcile.sh --labels` — board label-hygiene sweep (#482, closes
  #463).** A third `reconcile.sh` lens that reports and, on
  `--apply`/`--unattended`, deletes orphaned `fnd:host/session:*` repo
  labels (zero open-issue attachments, re-checked immediately before each
  delete) and strips stale `fnd:status:*` labels from closed issues (the
  bare-`Closes #N` adapter-bypass leak) — strictly `fnd:`-namespaced, never
  touching a non-`fnd:` label. Dry-run is the interactive default; unattended
  default is apply, with a `### open` pending-decisions append per the
  batch-at-ritual rule (never a silent auto-take). Wired into `tidy.md`'s
  "Stale board claims" step, invoked per governed board, plus the kernel
  tracker itself (board 7); a live dry-run against the real kernel tracker
  found 19 orphaned host/session labels and 155 stale status labels, confirming the
  gap was genuine.
- **Zero-GraphQL CLI-entrypoint test (#479, closes #467).**
  `test_cli_entrypoint_no_graphql.sh` runs
  `worklist.sh`/`claim.sh`/`capture.sh`/`reconcile.sh` as real subprocesses
  against a `backend=issues` board through a PATH-shadowed `gh` logging
  shim, asserting zero `gh project` and zero `gh api graphql` calls at the
  process level — complementing the existing function-level coverage in
  `test_issues_backend.sh` / `test_issues_claim_edges.sh` / `test_capture.sh`.
  Verified to actually catch a regression before landing (forced
  `board_backend` to answer `projects`, confirmed 7/9 checks failed, then
  reverted).
- **Draft ADRs 0004–0006 for issues-only-everywhere (epic #460, PR #461).**
  `docs/adr/0004-issues-only-default-backend.md`,
  `0005-repo-local-conf-cutover.md`, and `0006-seq-retired-on-issues-only.md`
  — all `Status: Proposed` — record the issues-only-default decision
  (Projects-v2 deprecated this release, removed in a follow-on breaking
  release after a soak), the repo-local `boards.conf`-entry cutover
  mechanism (per-repo commit, not the kernel's built-in map), and the
  Seq-retirement rationale this release's `board_set_number` fix
  implements.

- **Knowledge-store sync — optional backend capability (temperloop#430, ADR
  0003).** `ks_sync` (`init <remote-url>` / `push [-m <msg>]` / `pull` /
  `status`) plus the `ks_sync_available` probe: git-backed, **manual-only**
  replication of the `plain-files` store (the store directory becomes a git
  repo with one `origin` remote, private by default), so a second
  environment can `init` against the operator's remote and `pull` the real
  store. Sync is a *capability*, not a universal op: a backend that cannot
  implement it (`obsidian` never consults `KNOWLEDGE_STORE_ROOT`) degrades
  to exit 3 with `skipped — sync unavailable for backend <name>` — the
  `ks_search` availability-probe pattern, never a silent no-op or a hard
  failure. All sync ops route through the `ks_` dispatch; the store —
  including its `.git` and remote config — is user data `temperloop
  uninstall` keeps intact (`test_install_lifecycle.sh`'s residue diff now
  proves no sync-specific state survives outside the explicitly-kept store
  dir). EXPERIMENTAL: single-tenant per `$HOME` (per-project partition
  deferred — temperloop#418), single-writer (`pull` is `--ff-only`); the
  thin entry `workflows/scripts/lib/knowledge_sync.sh` is deliberately kept
  out of the stranger-facing CLI reference so the `temperloop sync`
  promotion decision stays open. New hermetic gate:
  `test_knowledge_store_sync.sh` (two-environment bootstrap against a local
  bare remote, zero network).

  *Published-contracts mark (`VERSIONING.md` § Published schemas/contracts):
  additive change to `workflows/scripts/lib/knowledge_store.contract.md` —
  new § Sync (optional backend capability), a backend-matrix Sync row, and
  the read-log `op` set gaining `sync`. Minor, not `BREAKING`: no existing
  backend, caller, or overlay must change (no backend inherits a new
  required op; the read-log line shape — field order/count/separator — is
  untouched).*

- **Kernel-side telemetry-brief renderer (temperloop#431).**
  `workflows/scripts/telemetry-brief.sh` renders the five-question telemetry
  brief (attention, funnel health & trust, spend, improvement, command
  effectiveness) from **kernel-only raw streams** — the `meta/data/raw/` lake
  (`command-runs`, `issue-touches` ∪ `claims`, `funnel`, `gh-calls`,
  `knowledge-search-fallback`) plus the knowledge-store read log
  (`ks__read_log_emit`) — so the brief and `/check-in`'s daily render work on
  a bare kernel checkout with no overlay, vault, or rollup pipeline. Every
  section names its source stream verbatim (numbers are reconcilable by
  reading the named file); an absent or empty stream degrades to an honest
  "no data yet — <stream> is empty" line, never a crash or a fabricated
  number; records with no in-window hits report the freshest record found
  instead of rendering zeros as current. Leads with cross-stream `DATA AGE`
  (alarming `DATA STALE` past 24h), matching the overlay renderer's contract.
  Reader follows the emitters' own `*_RAW_DIR` overrides first, falling back
  to the new `TELEMETRY_RAW_DIR` knob; window set by `TELEMETRY_LOOKBACK_DAYS`
  / `--lookback-days` (both registered in `knob-registry.tsv`). Covered by a
  new `KERNEL_GATES` test (`workflows/scripts/tests/test_telemetry_brief.sh`:
  fixture-lake reconciliation, empty-stream degradation, stale-window honesty,
  torn-line resilience, check-in wiring presence).
- **`/check-in` Part 1 renders kernel-first (contract change, additive).**
  `claude/commands/check-in.md` Part 1 previously skipped the telemetry brief
  entirely on a kernel-only checkout (`telemetry brief unavailable — no
  renderer in this checkout`); it now always renders the kernel brief via
  `workflows/scripts/telemetry-brief.sh`, then renders the overlay
  `build_telemetry_brief.py` digest as a guarded enrichment when present —
  same one-directional kernel→overlay reference rule as before (the overlay
  call stays behind its `[ -f … ]` existence guard).

- **`temperloop update` — the sole post-install HEAD mover of the managed
  clone (temperloop#429, ADR 0002 "Managed-clone state ownership").**
  `bin/subcommands/update.sh` fetches tags (auto-converting a `--depth 1`
  tagless clone — `bin/bootstrap.sh`'s current shape — via
  `git fetch --unshallow`), surfaces the full CHANGELOG delta with any
  `BREAKING` section called out BEFORE a consent-gated checkout (`--yes`, an
  interactive y/N, or a legible refusal on a non-interactive run — no
  timeout-as-consent), re-runs the manifest-backed `temperloop install`, and
  finishes with `doctor`. Before touching HEAD it also checks the on-disk
  install manifest's `schema_version` against the target tag's own
  `manifest.sh` — an incompatible schema halts with instructions rather than
  guessing. Never writes a repo-tracked path in any other repo (no `--dir`
  argument; its entire write surface is the managed clone's own git state
  plus the machine surface `install.sh` already owns).
- **`workflows/scripts/lib/changelog.sh` — shared CHANGELOG-range parsing.**
  `semver_major()`/`breaking_sections()` lifted out of
  `scripts/update-kernel.sh`'s own private helpers into a sourceable lib
  (`changelog_semver_major`/`changelog_sections_in_range`/
  `changelog_breaking_sections`) so both `update-kernel.sh` and the new
  `update` subcommand share one implementation instead of `bin/`
  back-channeling into `scripts/`. `update-kernel.sh` resolves it
  script-relative; behavior is unchanged (see its own regression suite,
  `scripts/tests/test_update_kernel.sh`).

- **`temperloop feedback` — consent-gated feedback submit mechanism (#428).**
  A new CLI subcommand (`bin/subcommands/feedback.sh`) that sends feedback to
  the kernel maintainers via a GitHub issue on the kernel's own upstream
  tracker — deliberately distinct from `temperloop report` (which only ever
  renders a stranger's own local before/after metrics and never transmits
  anything).
  Nothing repo-derived leaves the machine without: (1) composing the payload
  to a single artifact file, (2) running the same
  `personal-token-denylist.tsv` RULESET that guards the kernel file set
  against that composed payload itself — a hit blocks transmission and names
  the matching pattern, (3) previewing the exact payload bytes, and (4) an
  explicit, interactively-typed "yes" at a real prompt — there is no `--yes`
  bypass for this step. A closed/non-TTY stdin, or a `CI`/`GITHUB_ACTIONS`
  unattended-environment signal, always refuses to transmit with a legible
  message: a timeout or a flag is never consent for an external write. See
  `bin/subcommands/feedback.sh`'s own header for the full contract.

## [0.13.1] - 2026-07-17

Patch. Safe pull, no migration — no `BREAKING` marker. CI-resilience fix only:
the composed quality-gate run now absorbs transient macOS-runner flakiness
without letting a real breakage through.

### Fixed

- **Bounded per-gate retry in the composed gate run (#404, temperloop#403).**
  `scripts/quality-gates.sh` ran each gate exactly once, so a transient
  `macos-latest` runner failure (fork/exec/IO under load) in *any* hermetic
  gate failed the whole `checks` job and stalled the merge queue — observed
  across unrelated gates that share no code and pass locally and on Ubuntu.
  The serial gate loop is now wrapped in a bounded retry (`GATE_MAX_ATTEMPTS`,
  default `3`): a real breakage fails every attempt and still gates, while a
  flake clears on a retry. Retries are logged per-attempt and summarized at
  end-of-run so a flake stays visible rather than silently masked; set
  `GATE_MAX_ATTEMPTS=1` to disable when hunting a genuine intermittent bug.
  Green runs retry nothing, so there is no added CI time in the common case.
- **`GATE_MAX_ATTEMPTS` registered in the knob registry (#404).** The new
  `${VAR:-default}` retry seam carries its `knob-registry.tsv` row (kernel
  layer, int, default `3`, owning `scripts/quality-gates.sh`), so the
  unregistered-knob sweep passes and the registry↔shell equality lint's
  default matches the shell default.

## [0.13.0] - 2026-07-17

Additive minor. Safe pull, no migration — no `BREAKING` marker. The headline
is the **activation-completeness contract** (epic #317): a new capability an
overlay opts into, not a change to anything existing. Its one new hard-fail
(plan-schema rule 14) ships with a **grandfather cutover** deliberately
engineered to keep the release non-breaking — every plan authored before
`2026-07-17` is exempt, so no already-approved in-flight plan breaks on pull
(see `VERSIONING.md` and `plan-schema.md` § Rule 14).

### Added

- **Activation-completeness contract (epic #317).** Splits "done" into
  **merged** (code + CI) vs **activated** (the built thing provably live), so a
  correct-but-never-wired-in change can no longer read as complete. Three
  activation classes, each with its own discharge path:
  - **Class A — synchronous / in-repo.** `/build` gains a Step 3e.6 activation
    gate that runs an item's `activation: class: A` `proof:` predicate against
    its own reachability surface (the `__init__.py` entry, the flipped flag, the
    rendered panel) before the item counts as done. (#319)
  - **Pending-activations ledger.** New grammar in `/check-in`
    (`class` / `proof` / `locus` / `watermark` / `soak-until` / `soak_check` /
    `status`); only `/check-in` and `/tidy` mutate a record's `status`. (#392)
  - **plan-schema rule 14 — require `activation:` on product-source items.** A
    `kind: code` item whose `files:` touch `scripts/`, `workflows/`, or
    `claude/` must declare an `activation:` block. Shipped with a grandfather
    cutover (`RULE_14_CUTOVER_DATE`, `2026-07-17`) so pre-cutover plans stay
    exempt — the mechanism that keeps this release non-breaking. (#393)
  - **Epic-close activation accounting.** `/build`'s 4d-epic step refuses to
    close an epic while any `<epic>-*` record on the ledger is still `open`, and
    emits class-B/C records at child-close. (#394)
  - **Class-B discharge — cross-repo propagation.** `/check-in` reads each
    consumer's `.kernel-pin` tag and discharges a class-B record once every
    consumer's pin is at or past the shipping watermark. (#395)
  - **Class-A activation-registry CI validator.** `validate-activation-registry.sh`
    (a new quality gate, `validate-live-drain.sh`'s mold applied to
    `Plans-archive/*.md`'s `activation:` blocks) — reads archived plans only,
    never the live vault. (#396)
  - **Class-C discharge — time-deferred / soak.** `/tidy` + `/check-in`
    discharge a class-C record by concrete predicate: `AGENT_STALE` launchd
    liveness, or a `soak_check:` data predicate, after the soak-until window.
    (#397)
- **`/triage --feedback-only`.** Walk the decision queue without the full
  Backlog sweep; emits its own telemetry and closes its own review findings.
  (#371)

### Changed

- **Funnel board probes derive from `board_registered_boards`.** `/build` Step 0
  and the funnel-tick board reverse-lookup now iterate the adapter's own
  registered-board set instead of a hardcoded `3 4 5 6` literal, so the
  temperloop kernel tracker (board 7, issues-only) is no longer silently
  dropped — the drift that left `/build` board-OFF on the kernel's own tracker.
  (#381)
- **`env-reconcile` registers the temperloop operator checkout** in its
  default operator-checkout set, so kernel-repo drift is classified against the
  right baseline. (#374)

### Fixed

- **`/build` no longer requires `project` gh-scope for an issues-only board.**
  Step 0's board-integration probe gated the whole run on the `project` scope
  and stopped if missing — but an issues-only board (board 7) drives Status /
  claim / Done / mirror entirely through plain-REST label writes, issue-close,
  and the sub-issues API, none of which need it. The check is now
  backend-conditional on `board_backend`, so a board-7 run whose token carries
  only `repo` is no longer wrongly halted. (#398, closes #391)
- **`plan.sh` writeback resolves its REST config from the knowledge-store
  root** and fails soft when absent, and a personal-vault path literal was
  scrubbed from a `plan.sh` comment (stranger-test cleanliness). (#342)
- **`plan.sh` `_files_touch_shipped` is bash-3.2-safe** — an empty `files:`
  value no longer expands an empty array under `set -u` (which aborts on macOS
  system bash), the guard rule 14's product-source predicate needs. (#393)
- **`/tidy` Step 5 deletes per stub, not per batch — `Sessions/_inbox` can
  actually drain.** The archiver folds a whole run into one commit/PR and
  reports one durability verdict for the batch; Step 5 deleted stubs only on
  `archive-committed`, so any batch holding a genuinely-new stub retained
  **every** stub in it (109 of 123 stranded over 11 days behind two
  already-merged archive PRs). Step 5 now consumes the archiver's per-stub
  `archive-stub-durable:` / `archive-stub-pending:` lines and deletes the durable
  ones whatever the batch verdict says — falling back to the batch line for an
  older archiver, so no migration. (#372; the archiver half lives in the
  foundation overlay's #1161.)
- **`pr-enqueue` confirms the queued state via `autoMergeRequest`**, not the
  gh-rejected `isInMergeQueue` field. (#357)
- **`gate.sh` drops `--delete-branch` from both merge-queue paths** — the queue
  rejects the flag; head branches auto-delete via the repo setting. (#353)
- **`drain` normalizes naive-timezone timestamps** in `tally_recent_findings`
  so the recurring-issue tally doesn't skew on a naive-tz row. (#341)
- **Sandbox test suites prune the live basic-memory store** from their
  no-residue snapshots, so a populated local store no longer fails
  `test_sandbox.sh` / `test_sandbox_dry_run_legs.sh`. (#377, #382)
- **Test runners surface failed-test output; `test_eject.sh` is
  config-hermetic with git auto-maintenance off.** The 7 `test-*` Makefile
  runner loops ran each script with `>/dev/null 2>&1`, so a CI failure named
  only the script, never the assertion — which is why a `test_eject.sh` flake
  on the macos-latest runner couldn't be root-caused. The loops now dump the
  captured output (indented) on `[FAIL]`, pass path unchanged. `test_eject.sh`
  is additionally pinned to an isolated global / empty system git config with
  `gc` and `maintenance` auto **off** (the suspected flake: git's background
  maintenance racing fixture index/ref locks under macOS-runner I/O
  contention). (#401, closes #400)

## [0.12.1] - 2026-07-15

### Fixed

- **The composed gate set is now overlay-safe.** Vendoring v0.12.0 into a
  downstream overlay failed **6 of 74** gates, none of which this repo's own CI
  could see: every one assumed a **kernel-only layout** and broke on a composed
  tree. Not a contract change — an overlay pulling this needs no migration, it
  just stops being wrong. (foundation#1169 found all three.)
  - `validate-design-brief.sh` reported *resolved* citations as
    `DANGLING-CITATION`. `resolve_citation` piped `git ls-files` into
    `grep -q`; grep exits on first match, the producer takes SIGPIPE (141), and
    `set -o pipefail` promotes that 141 to the pipeline's status. It needs both
    a listing over the pipe buffer (~64KiB) **and** an early match — this repo's
    tree is ~15KiB, so it cannot reproduce here at all, while foundation's
    composed tree is ~74KiB. Now captured and matched with a here-string; the
    regression test builds an ~87KiB synthetic tree with a first-sorting
    sentinel, and asserts both conditions so it can't silently go vacuous. (#358)
  - Three suites calling `sandbox_bootstrap_checkout` (`test_install_cli.sh`,
    `test_sandbox_dry_run_legs.sh`, `lib/tests/test_sandbox.sh`) bootstrap this
    repo from `bin/bootstrap.sh` — a path that exists only when the repo root IS
    the kernel. `test_install_lifecycle.sh` already skipped for this reason
    (#267); its siblings never inherited the guard. The detection is now
    `sandbox_skip_if_composed_tree()` in `sandbox.sh`, shared by all four rather
    than pasted into three more files. (#363)
  - `test_install_project_agents.sh` inventoried kernel sources with bare
    `find`, which won't descend a symlink — so an overlay's compat-symlinked
    `claude/agents` counted 0 and failed the suite's first precondition. Four
    sites, now `find -L`; the two subtler ones handed `cmp` a *directory*
    instead of a file. (#364)

## [0.12.0] - 2026-07-14 — BREAKING

### Changed

- **BREAKING — the `/design` command is renamed `/workshop`** (temperloop#354,
  PR #355). The old name collides with Claude Code's builtin `/design` (the
  claude.ai design-system sync consent flow), which answers instead of the
  kernel command on any fresh install — a stranger-test failure. The rename is
  command-name only: `claude/commands/design.md` → `workshop.md`,
  `docs/features/design.md` → `workshop.md` (slug `workshop`), every `/design`
  invocation reference, and the feature/kernel manifests. The artifact
  vocabulary is unchanged — "design brief", `design-schema.md`,
  `design-measurement-proxies.md`, the `design-brief:` epic marker, and
  `validate-design-brief.sh` + fixtures all keep their names. **Migration:**
  rename any overlay/docs references to the `/design` command to `/workshop`,
  and re-run `workflows/scripts/install/project-agents.sh` in each live
  checkout — the deployed `.claude/commands/design.md` symlink dangles after
  the pull and must be removed/replaced by `workshop.md`.
- **BREAKING — funnel governor knob renamed `FUNNEL_WIP_CAP` →
  `FUNNEL_DRIVE_CONCURRENCY`**, and the human WIP-cap-3 standing rule is
  retired from the kernel prose (PR #334). The old rule conflated a
  human/cross-session governance bound with the autonomous funnel's mechanical
  drive-concurrency governor; only the latter was real, and it keeps the same
  default (3). **Migration:** grep your overlay config/env for
  `FUNNEL_WIP_CAP` and rename it, then re-run `make install-claude` — the
  composed `~/.claude/CLAUDE.md` otherwise keeps rendering the retired rule
  from the old placeholder.
- Standing-rule promotions from the drain lexicon (PRs #337–#342): recurring
  pattern/mistake/feedback extractions promoted into kernel standing rules
  (merge-autonomy & consent, cost-tier routing, guard rules) plus two new
  error signatures. Claim-until-Done blessed; the required release-at-park of
  a non-latest claim is dropped (temperloop#275, PR #333). The design-schema
  disposition grammar block is now prefixed `disposition:` (PR #350), and the
  provenance-net Contract-shaped scope is ratified as an accepted-gap decision
  (temperloop#349, PR #351).

### Added

- Funnel rung-5c gains a `_reclaim_abandoned` backstop (foundation#1157): when a
  one-shot `/funnel-drive-merge` session disobeys the synchronous-block guardrail —
  backgrounds a wait and dies before opening a PR — it leaves its board item
  stranded In Progress with no PR, and enough of those exceed the WIP cap and jam
  the funnel. The driver now releases such a claim back to Ready (driven this tick,
  no open PR, issue still open, no terminal status reported), so it re-enters the
  drive pool next tick. Adds `board/unclaim.sh` — the board-status half of undoing
  `claim.sh` (In Progress → Ready), the autonomous release-to-Ready primitive
  `release.sh` deliberately is not (release.sh clears only the local claim marker).
  The reclaim shells out to that CLI (new `FUNNEL_UNCLAIM_BIN` test-double seam),
  keeping `funnel-drive.sh` adapter-free. New wake-record fields `reclaimed` /
  `reclaimed_issues`. Additive — the synchronous-block guardrail stays the primary
  fix; this only makes its failure self-healing instead of a jam.
- `docs-reviewer` advisory agent (`claude/agents/docs-reviewer.md`) and its
  `/build` Step 3e wiring (temperloop#282, PR 261c22f): a read-only,
  `sonnet`-tier documentation reviewer — the fourth member of the advisory
  review family alongside `architecture-reviewer`, `requirements-auditor`, and
  `workflow-reviewer`. It scores stranger-facing prose (`docs/**`, READMEs,
  and other `*.md`) against named rules in `claude/message-schema.md`,
  `claude/measurement-proxies.md`, and the `docs/who-its-for.md` reader
  persona — never taste. `/build` 3e routes a PR touching `docs/**` or a prose
  `*.md` (except a `claude/commands/*.md` workflow spec, which routes to
  `workflow-reviewer`) to it. Advisory only — never a `checks` gate entry.
  Landed on `main` after the v0.11.0 tag, so this entry is the release-surface
  record that lets the next kernel tag ship it and `update-kernel` / a stranger
  grepping the CHANGELOG see it. Not `BREAKING` — the agent is additive and the
  3e routing degrades legibly (`skipped — docs-reviewer unavailable`) where the
  capability probe resolves false. Per-consumer activation (vendor the tag, then
  `make install`) is tracked as class-B propagation work under temperloop#318.
- The funnel tick's Phase-0 intake pre-gate warns once (instead of silently
  no-opping, observed ~19h unnoticed) when the signal-intake backend script is
  missing or present-but-unconfigured (temperloop#330, PR #345); the two knob
  seams the WARN added are registered/exempted in the knob registry.
- Collision-free parallel-append registries and check slots (temperloop#321,
  PR #346): append-only, order-independent registries (feature-manifest,
  kernel-manifest, the exempt-file lists) get a `merge=union` `.gitattributes`
  driver so two same-level sibling PRs appending at one insertion point
  auto-merge instead of textually colliding and costing a rebase-respawn.

### Fixed

- `/build`'s CI-retry push is a plain fast-forward instead of an unconditional
  `--force` (temperloop#335, PR #343): the retry commit is a fast-forward
  descendant by construction, and the needless force-push non-deterministically
  tripped the git-destructive safety classifier in auto mode, silently parking
  autonomous `/sweep` / `/build --unattended` / funnel-drive-merge runs.

## [0.11.0] - 2026-07-10

Minor — the registry-driven config lints land as quality gates, the ~10
remaining prose-only tunables migrate onto env seams + registry rows, and the
personal-token denylist's vault-path burn-down baseline (`\bdev/mind\b`,
temperloop#164/#169) is now empty: every pre-existing hit was routed through
the `knowledge_store` seam or genericized in prose (kernel-literal-scrub,
temperloop#189). Completes the D1–D5 config-architecture epic (temperloop#169)
kernel-side. Not tagged `BREAKING` — new gates are additive, new knobs default
to their prior prose values, and the one default-value change already had a
documented override path (machine conf / `build.config.local.sh` / a
downstream repo's own tracked-repo copy); only the *default value* moved.

### Added

- Registry-driven config lints (temperloop#186, ADR D2/D3), wired into
  `scripts/quality-gates.sh` (38 → 42 gates):
  `workflows/scripts/config/check-knob-registry.sh` — layer-aware
  registry↔shell equality + unregistered-knob sweep, strictly green with no
  baseline — and `workflows/scripts/config/check-knob-prose.sh` — fails a NEW
  literal restatement adjacent to a registered knob name in
  `claude/commands/*.md` / `claude/CLAUDE.kernel.md`, honors a
  `<!-- knob-prose:allow -->` marker — plus fixture test suites for both.
- The ~10 prose-only Bucket A tunables migrated onto env seams + registry rows
  at unchanged defaults (temperloop#187): assess/next/tidy/check-in cadences,
  inbox alarms, and `CLAUDE.kernel.md`'s epic-decomposition threshold via a
  new `{{EPIC_MIN_SUBUNITS}}` compose-time render token. The
  `knob-prose-baseline.tsv` burn-down baseline is now empty; the prose lint is
  strictly enforcing.
- Pre-claimed kernel-manifest globs for the docs-site epic's paths
  (`docs/adr/*`, `docs/architecture.md`, …) so the parallel doc items never
  collide editing the manifest (PR #204); inert until those files land.

### Changed

- `build.config.sh` no longer re-seeds `KNOWLEDGE_STORE_ROOT` to a personal
  vault path — the kernel's own tracked default now defers entirely to
  `knowledge_store.sh`'s generic `${XDG_DATA_HOME:-$HOME/.local/share}/foundation/knowledge`
  default. **A default-value change on an existing knob-registry row is
  `minor` per `VERSIONING.md`.** An operator who relied on the old bare
  default (no machine conf / `build.config.local.sh` / downstream tracked-repo
  override already set) must now set `KNOWLEDGE_STORE_ROOT` explicitly at one
  of those rungs to keep pointing at a real vault. The
  `workflows/scripts/config/knob-registry.tsv` row for this default was
  removed accordingly (the knob's remaining registry row is the kernel-layer
  one owned by `knowledge_store.sh`).
- `knowledge_store_obsidian.sh`'s `KNOWLEDGE_STORE_OBSIDIAN_API_KEY_FILE`
  default is now *derived* from `ks_root` (`$(ks_root)/.obsidian/plugins/obsidian-local-rest-api/data.json`)
  instead of an independently-hardcoded vault-path literal — so it can never
  silently drift from `KNOWLEDGE_STORE_ROOT`. `doctor.sh`'s knowledge-root
  split-brain check was updated to resolve its "expected" side the same way.
- `vault_hygiene_report.sh`'s `--root` default now resolves via the
  `knowledge_store` seam's `ks_root` instead of a duplicated
  `${KNOWLEDGE_STORE_ROOT:-<personal path>}` fallback.
- Command-spec prose (`claude/commands/*.md`), the `workflow-reviewer` agent
  spec, three hook header comments, and `claude/measurement-proxies.md` no
  longer name the operator's personal vault path as a literal — they refer
  to "the knowledge store root" (`workflows/scripts/lib/knowledge_store.contract.md`)
  or a store-relative doc-id instead. No behavior change (prose only).

## [0.10.0] - 2026-07-10

Additive — a config-precedence ladder, env/prose-knob seams, an env-hygiene
probe, and the overlay integration for the public-repo leak guard. **Contract
surface grows; nothing existing changes shape — safe pull, no overlay action.**
Deliberately **not** tagged `BREAKING`.

### Added

- A new **machine conf** rung in `build.config.sh`'s config precedence
  ladder: an optional `$XDG_CONFIG_HOME/temperloop/build.config.sh`, sourced
  before any checkout-local override, for a host-wide knob override that
  applies across every checkout on that host. Template:
  `workflows/scripts/build/build.config.machine.sh.example`. The full
  six-rung ladder (CLI flag > env var > machine conf > untracked repo-local
  conf > tracked repo conf > kernel built-in default) is documented in the
  new [`docs/config-precedence.md`](docs/config-precedence.md). (#192)
- An **env-hygiene-report** probe that emits a vault drift-entry. (#196)
- Runtime + compose-time **seams for prose-resident knobs**. (#193)

### Changed

- Generalized the stranger-cleanliness denylist and retired the `CANONICAL_USER`
  seam. (#195)

- The **kernel knob registry** (temperloop#164/#169, design decision D2): a
  new grep/cut-parseable `workflows/scripts/config/knob-registry.tsv`
  cataloging every existing tunable knob (162 rows) with its current shell
  default, plus `workflows/scripts/config/knob-registry-lib.sh`, a
  union-aware parse helper that reads the kernel table and unions an
  optional overlay extension TSV when present (mirroring
  `validate-live-drain.sh`'s kernel-table + overlay-extension pattern). A
  reserved `TEMPERLOOP_PROFILE` row (not yet read anywhere) holds the name
  for a later profile mechanism. This is populate-only: no caller routes
  through the registry yet, and no equality lint exists yet (a later item,
  registry-config-lints).

### Fixed

- `build.config.local.sh` (and its `.example` template) now use the `:=`
  set-only-if-unset idiom instead of plain assignments. Previously, because
  `build.config.sh` sourced it LAST with plain assignments, a value set in
  `build.config.local.sh` could silently beat an exported environment
  variable — inverting the intended precedence. Fixed together with
  reordering `build.config.sh` to source its conf-file rungs before applying
  its own built-in defaults, so source order now matches precedence order
  end to end. (#192)
- `check-pr-leak-guard.sh` gains a `--relative` / `LEAK_GUARD_RELATIVE` mode: a
  private overlay vendoring the guard scans only its `kernel/` subtree **and**
  emits kernel-root-relative paths, so the shared exempt list matches and the
  guard no longer false-positives on the kernel's own denylist tsv / test
  fixtures (which legitimately carry the token literals). Whole-tree behavior at
  the kernel repo root is unchanged (`--relative` is a no-op there). Completes
  the overlay integration begun with the `--path` scope in 0.9.2. (#74)
- Sweep merged/orphaned worktrees at session start. (#197)

