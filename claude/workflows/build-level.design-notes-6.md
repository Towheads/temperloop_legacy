# build-level.mjs — design notes

Extracted from `claude/workflows/build-level.mjs` (temperloop#2126). The module is
invoked by the Workflow tool via `scriptPath`, which refuses a file over 524288
bytes. **Nothing here is decoration** — each note records why a mechanism works
the way it does, and several were cited by review agents. Each extraction site in
the module carries a one-line summary plus a pointer to its anchor here.

Keep a note with its code: when you change the mechanism, change its note.

**Never extract a MACHINE-PARSED comment block.** Some comments in the module are
read by tooling, not by people: the `HANDOFF-CAPABILITIES-BEGIN`/`-END` sentinel
that `workflows/scripts/build/handoff-capability.sh` parses, and several literals
`test_workflow.sh` pins by exact string. Moving the sentinel does not fail loudly —
it turns every `/fix`, `/sweep` and `/build` Step 0 capability probe into
`CAPABILITIES_INDETERMINATE`, which reads identically to a pass at every call site.
A comment is not automatically prose. Derive the exclusion set mechanically from the
`grep ... "$MJS"` literals in `test_workflow.sh`, and note its blind spot: a pin
added by a branch not yet on main is invisible to that derivation.

> **Part 6 of 6.** Split to stay under the per-file prose cap
> (`PROSE_BUDGET_TIER2_FILE_CAP`). Other parts: [`build-level.design-notes.md`](build-level.design-notes.md), [`build-level.design-notes-2.md`](build-level.design-notes-2.md), [`build-level.design-notes-3.md`](build-level.design-notes-3.md), [`build-level.design-notes-4.md`](build-level.design-notes-4.md), [`build-level.design-notes-5.md`](build-level.design-notes-5.md).

## The surface-file flag is DROPPED on a recovery whose probe saw no
<a id="the-surface-file-flag-is-dropped-on-a-recovery-whose-probe-s"></a>

```text
 The surface-file flag is DROPPED on a recovery whose probe saw no
 `.build-verification.md` (temperloop#939): pr.sh treats a given-but-missing
 surface file as a hard ERROR by contract, so passing it for a worker that
 died before writing one would turn the recovery into a pr-open-failed
 escalation. Without the flag pr.sh falls back to the synthesized inline
 surface above. Every non-recovery drive passes the flag exactly as before.
```

## 3f-2 FALLBACK: a PR-ready tree must not be stranded by a bad verdict
<a id="3f-2-fallback-a-pr-ready-tree-must-not-be-stranded-by-a-bad-"></a>

```text
 --- 3f-2 FALLBACK: a PR-ready tree must not be stranded by a bad verdict --
 temperloop#1805, disposition (a). `pr.sh open` REQUIRES a parseable
 `--verdict` and dies `verdict is not valid JSON` when it does not get one.
 That is a REPORTING-layer failure, and it was terminal for the item:

   {"slug":"disclosure-watermark-tracked-1316","kind":"pr-open-failed",
    "payload":{"openOut":{"step":"pr-open","outcome":"ERROR",
                          "error":"verdict is not valid JSON"}}}

 …against ONE clean commit, a zero-dirty tree, a full `.build-verification.md`
 and that item's own suite green 39/39. The orchestrator recovered it BY HAND
 — push, `gh pr create`, verification file as the body — and it became PR
 #1803. Every piece of information the PR needed was already on disk; only
 the hand-off failed. The preservation machinery means the commit survives,
 so this is not data loss — it is PROGRESS loss: the item parks, re-enters
 the next run, and a fresh worker redoes finished, correct work.

 So the fallback re-issues `open` with a MINIMAL, structurally-safe verdict:
 the title is the item's own (what `--title` already carried) and the body
 comes from `.build-verification.md` via the surface flag — exactly the shape
 the manual recovery used. Everything variable about the rich verdict —
 `acceptance_results`, the worker's own prose — is dropped, because that is
 precisely the content that failed to survive the hand-off; the §3e review
 evidence line is kept, since it is assembled by this file and must stay
 visible on the PR (temperloop#1430).

 A body-less fallback would be worse than the escalation, so it is attempted
 ONLY when there is a real surface to fall back ON — either the worktree file
 or the synthesized inline surface.
```

## temperloop#1071 — a pr-batch step that outlived the liveness ceiling. 
<a id="temperloop-1071-a-pr-batch-step-that-outlived-the-liveness-c"></a>

```text
 temperloop#1071 — a pr-batch step that outlived the liveness ceiling. THIS is
 the incident's own shape: the 9h49m call was a `pr-batch` whose steps all in
 fact completed (PR #1070 opened) while the workflow sat waiting. So the
 disposal probes for exactly that — an already-opened PR is ADOPTED and the
 item flows straight on to CI, never re-pushed and never re-opened. Any other
 probe stage escalates. Either way, the rebase/scan/push/pr-open branches
 below are SKIPPED: their step objects were destroyed by the kill, and
 re-deriving them from a truncated batch is how a double-push happens.
```

## DIRTY_WORKTREE is NOT a conflict (temperloop#735): git refused to star
<a id="dirty-worktree-is-not-a-conflict-temperloop-735-git-refused-"></a>

```text
 DIRTY_WORKTREE is NOT a conflict (temperloop#735): git refused to start
 the rebase because the worker left tracked-file edits uncommitted —
 often with base == tip, i.e. no rebase was needed at all. It escalates
 under its OWN kind so the disposition is "commit the edits and re-drive"
 rather than the rebase-conflict path, whose discard-and-respawn arm
 would throw a FINISHED worker's work away. Checked before
 REBASE_CONFLICT so the two can never collapse back into one.
```

## 3f-1 branch — the push decision. Before escalating a non-PUSHED,
<a id="3f-1-branch-the-push-decision-before-escalating-a-non-pushed"></a>

```text
 3f-1 branch — the push decision. Before escalating a non-PUSHED,
 non-PUSH_REJECTED outcome, probe for a LOST pr-batch return
 (temperloop#1067): batchStep synthesizes the same 'ERROR'/'produced no
 result' sentinel for both a genuine short-circuit and a dropped last JSON
 line, and by this point rebase+scan are ALREADY confirmed successful (the
 branches above), so a sentinel here specifically means push's own result
 line was lost, not that push never ran. A genuine PUSH_REJECTED (or any
 other real failure) is unaffected — it never reaches isLostReturn().
```

## temperloop#1688 — the push LANDED, on a ref no open PR references whil
<a id="temperloop-1688-the-push-landed-on-a-ref-no-open-pr-referenc"></a>

```text
 temperloop#1688 — the push LANDED, on a ref no open PR references while
 an open PR for the same slug sits on a different head ref. Its own
 escalation kind, checked BEFORE the lost-return probe: the result line
 was not lost (it says something specific), and 'push-error' would bury
 the one fact the operator needs — which ref the PR actually tracks,
 carried on the payload's pr_head_ref. Opening/CI-polling past this is
 exactly the false-green route #254 arrives by here.
```

## 3f-2 branch — the PR-open decision. Skipped entirely when the push-bra
<a id="3f-2-branch-the-pr-open-decision-skipped-entirely-when-the-p"></a>

```text
 3f-2 branch — the PR-open decision. Skipped entirely when the push-branch
 recovery above already adopted or opened a PR (`pr` is already set) —
 re-running open against a branch that already has one is exactly the
 duplicate-PR hazard this wiring must never cause.
 EXISTS means the branch already had an open PR (a create-retry after a
 succeeded first attempt). Treat it as PR_OPENED — adopt the existing PR and
 continue to CI-poll/park-with-pr. Any other non-PR_OPENED outcome is
 probed for the same lost-return sentinel (temperloop#1067) before it
 escalates as a genuine pr-open-failed.
```

## temperloop#1805 — TOLERATE an unparseable verdict over a PR-ready tree
<a id="temperloop-1805-tolerate-an-unparseable-verdict-over-a-pr-re"></a>

```text
 temperloop#1805 — TOLERATE an unparseable verdict over a PR-ready tree.
 Checked BEFORE the lost-return probe: this outcome says something
 specific (pr.sh's own `die`), so it is not a dropped result line, and
 `recoverLostReturn` would re-issue the SAME command with the SAME bad
 verdict and fail identically. Re-issue with the minimal verdict instead.
```

## 3f→3g SHA hand-off guard (temperloop#2014)
<a id="3f-3g-sha-hand-off-guard-temperloop-2014"></a>

```text
 --- 3f→3g SHA hand-off guard (temperloop#2014) --------------------------
 The ONE choke point every arm above converges on. FOUR paths can set
 `pushedSha` and all four are covered here rather than four times over:
   1. the timeout-ADOPT arm       — `adopted.sha ?? null` (probe.sha; the
      `?? null` makes a probe that landed a PR but resolved no SHA reach
      this guard as an explicit null rather than an `undefined`);
   2. the push lost-return RECOVERY arm      — `rec.pushedSha`;
   3. the pr-open lost-return RECOVERY arm   — `rec.pushedSha ?? pushedSha`;
   4. the plain PUSHED arm        — `pushOut.sha`, unguarded until now: the
      push outcome is transported through an executor agent's structured
      return, so a `sha` key that never makes it back leaves this
      `undefined` while the step still reports success — the temperloop#2014
      reproduction's own path.
 A guard at each assignment would have to be written (and kept) four times
 and would still miss a fifth arm added later; one guard on the value the
 poll actually receives cannot be bypassed by a new arm. The CI-fix re-push
 inside ciPollLoop re-pins `sha` after this point and carries its own copy.
```

## temperloop#1450 — merge the ORIGINAL 3e pass with any CI-fix re-review
<a id="temperloop-1450-merge-the-original-3e-pass-with-any-ci-fix-r"></a>

```text
 temperloop#1450 — merge the ORIGINAL 3e pass with any CI-fix re-review
 round(s) (ciResult.fixReviewRounds) into the ONE tally park() carries, so
 the Step 6 summary can render whether §3e actually discharged, across
 every review this item's build ran, not just the first. Two INDEPENDENT
 degraded-case tallies ride this one park() call now (discGaps from
 #1319, reviewSummary from #1450) — see park()'s own signature comment.
```

## temperloop#2065 — assemble the per-item cost ledger park() carries. Wa
<a id="temperloop-2065-assemble-the-per-item-cost-ledger-park-carri"></a>

```text
 temperloop#2065 — assemble the per-item cost ledger park() carries. Wall
 clock is ONE total across the main worker AND every CI-fix retry
 (mergeWorkerCost's same null-only-if-both-null rule, applied by hand here
 since ciResult's retryWallClockMs is a bare number|null, not a cost
 object); tokens stay split (worker) vs combined (retry) per the epic's
 own ledger vocabulary (item 5/11) — see park()'s own comment.
```

## ciPollLoop — bounded short-slice CI poll (DESIGN NOTE 2).
<a id="cipollloop-bounded-short-slice-ci-poll-design-note-2"></a>

```text
 -----------------------------------------------------------------------------
 ciPollLoop — bounded short-slice CI poll (DESIGN NOTE 2).
 -----------------------------------------------------------------------------
 Drives CI_POLL_SLICE_SECS-timeout ci-poll.sh calls until the outcome resolves.
 TIMEOUT on a slice = "still pending, poll again" (NOT a failure) — we keep
 looping while the total budget remains. On CI_FAILED, within
 CI_FAIL_RETRY_BUDGET, we re-spawn the worker + force-push + re-poll PINNED to
 the new SHA (#254 false-green guard).

 temperloop#942: the slices no longer cost an agent spawn EACH. One
 `ci-batch:<slug>#n` executor runs CI_POLL_SLICES_PER_BATCH
 (merge-state probe → poll slice) PAIRS in a single Bash invocation and returns
 all their JSON lines; this loop then consumes them one slice at a time from a
 buffer and branches on each exactly as it did when each came from its own
 agent. Interleaving is preserved: the merge-state probe still runs immediately
 before EVERY poll slice (#543), not once per batch. The buffer is FLUSHED
 whenever the head SHA changes (a CI-fix re-push), because buffered results are
 pinned to the OLD sha — keeping the #254 false-green guard intact. And the
 batch never runs one long poll: see DESIGN NOTE 2 for the derived slice count.
 Returns:
   { ok:true, finalSha }                         — CI green
   { ok:true, finalSha, noCi:true }              — NO_CI (temperloop#605/#618):
        no CI configured on this repo/SHA — a legible skip mirroring build.md
        3g, NOT a failure; 3h parks [m] with the no_ci sentinel stamped
   { escalation:'ci-failed', payload:{...} }      — budget exhausted / hard fail
   { escalation:'merge-conflict', payload:{...} } — PR is CONFLICTING/DIRTY
```

## MERGE_CONFLICT_GLOBS — the substrings that make the batched merge-stat
<a id="merge-conflict-globs-the-substrings-that-make-the-batched-me"></a>

```text
 MERGE_CONFLICT_GLOBS — the substrings that make the batched merge-state probe
 stop the sequence early. This is the STOP-EARLY MIRROR of the .mjs branch
 below (`mergeable === 'CONFLICTING' || mergeStateStatus === 'DIRTY'`), NOT the
 decision: it only spares a CONFLICTING PR the 4-minute poll slice that would
 otherwise run before the .mjs read the same object and escalated. The
 authoritative branch is, as always, the `if` in .mjs.
```

## gh pr view returns JSON; if it fails (e.g. auth error) the executor ca
<a id="gh-pr-view-returns-json-if-it-fails-e-g-auth-error-the-execu"></a>

```text
 gh pr view returns JSON; if it fails (e.g. auth error) the executor catches
 non-zero exit and returns whatever gh printed — the caller handles missing fields.

 `tr -d ' \n'` COMPACTS the object onto one line (temperloop#942). gh may
 pretty-print `--json` output, and a batched step's result must be a single
 JSON line for both the executor's line-per-step contract and the `case`
 stop-early glob above (which would miss `"mergeable": "CONFLICTING"` with a
 space). Only `mergeable`/`mergeStateStatus` are requested and both are
 space-free enum values, so stripping spaces cannot corrupt a value.
```

## The pushed-SHA hand-off guard (temperloop#2014).
<a id="the-pushed-sha-hand-off-guard-temperloop-2014"></a>

```text
 -----------------------------------------------------------------------------
 The pushed-SHA hand-off guard (temperloop#2014).
 -----------------------------------------------------------------------------
 ciPollCmd pins `--sha` to the SHA the push reported — the #254 false-green
 guard, and the one argument of the poll that this file, not the machinery,
 is responsible for. sq() stringifies whatever it is handed, so an ABSENT
 value does not crash: it renders as the literal `undefined` (or `null`),
 ci-poll.sh's own argument validation refuses to run on it, and the driver
 read that refusal back through the catch-all ERROR arm as `ci-failed` — i.e.
 reported a PR whose CI was still running (temperloop#2014: PR #2013 was OPEN
 with checks IN_PROGRESS) as a red one. Two halves close it:
   • hexSha() is the PRE-FLIGHT. Every value that can become the poll's
     `--sha` passes through it before a poll is spawned, so the driver never
     spends a slice on an argument ci-poll.sh is certain to reject.
   • a bad argument that reaches ci-poll.sh anyway (a vendored older copy, a
     validation this file does not model) comes back as its OWN escalation
     kind, `ci-poll-bad-argument`, never `ci-failed` — see isBadArgumentError
     and the ERROR arm at the bottom of ciPollLoop.
 The predicate is hex-only, matching ci-poll.sh's own `*[!0-9a-fA-F]*`
 rejection exactly. It must never be LOOSER than the check it protects, or
 the pre-flight passes something the poll then refuses — which is the whole
 failure being fixed, one layer down.
```

## badShaEscalation — the payload shared by both pre-flight sites (the 3f
<a id="badshaescalation-the-payload-shared-by-both-pre-flight-sites"></a>

```text
 badShaEscalation — the payload shared by both pre-flight sites (the 3f→3g
 hand-off and the CI-fix re-push). `sha_seen` is the value STRINGIFIED exactly
 as sq() would have rendered it, so the payload shows the literal
 `undefined`/`null` the poll would have been handed rather than dropping the
 key entirely (JSON.stringify eats an `undefined` value).
```

## isBadArgumentError — true iff a ci-poll.sh ERROR is the script REFUSIN
<a id="isbadargumenterror-true-iff-a-ci-poll-sh-error-is-the-script"></a>

```text
 isBadArgumentError — true iff a ci-poll.sh ERROR is the script REFUSING TO
 RUN on its own arguments, rather than a poll that ran and went wrong. The
 primary signal is the structured `usage_error:true` field ci-poll.sh stamps
 on every argument-validation die (its own header documents it alongside
 transient_retries_exhausted / deterministic_failure). The error-text fallback
 covers a vendored or older ci-poll.sh predating that stamp: every one of its
 argument dies renders as `<name> '<value>' invalid — must be …`, or the
 `usage: ci-poll.sh …` line — phrasings no API/transport error shares. Narrow
 on purpose: a genuine CI failure must never be laundered out of `ci-failed`.
```

## temperloop#1450 — one runReviewers() result per CI-fix commit re-revie
<a id="temperloop-1450-one-runreviewers-result-per-ci-fix-commit-re"></a>

```text
 temperloop#1450 — one runReviewers() result per CI-fix commit re-reviewed
 below (the CI_FAILED arm), so a green resolution can hand them back to
 driveItem for the Step 6 tally (park()'s `review` argument via
 reviewTally()). A CI-fix commit can touch anything — including the very
 command doc whose edit tripped the ORIGINAL lint failure — and without
 this it would ship unreviewed under a PR body that only describes the
 FIRST push.
```

## temperloop#2065 — the CI_FAIL_RETRY_BUDGET loop's OWN cost tally, kept
<a id="temperloop-2065-the-ci-fail-retry-budget-loop-s-own-cost-tal"></a>

```text
 temperloop#2065 — the CI_FAIL_RETRY_BUDGET loop's OWN cost tally, kept
 separate from the main worker's `mainCost` (driveItem): the ledger's
 "worker tokens" and "retry tokens" are two DIFFERENT figures (epic
 #2062's item 5/11). retryTokens stays null until a retry actually fires
 — "never attempted" and "attempted, zero tokens observed" are different
 facts, and only the latter earns a 0.
```

## temperloop#1071 — a ci-batch step that outlived the liveness ceiling.
<a id="temperloop-1071-a-ci-batch-step-that-outlived-the-liveness-c"></a>

```text
 temperloop#1071 — a ci-batch step that outlived the liveness ceiling.
 `adoptable:false` is load-bearing here: the probe still runs (its stage is
 real evidence for the payload), but "an open PR exists" is NOT and must
 never become evidence that CI passed, so there is no adopt arm on this
 path — a bounded-out poll always escalates rather than resolving green.
```

## CONFLICTING/DIRTY early-exit (#543)
<a id="conflicting-dirty-early-exit-543"></a>

```text
 --- CONFLICTING/DIRTY early-exit (#543) ---------------------------------
 GitHub never creates a CI check-suite for a PR whose merge ref can't be
 computed (CONFLICTING/DIRTY), so ci-poll.sh returns TIMEOUT indefinitely.
 The merge state is probed BEFORE each poll slice (it is the batched step
 immediately preceding this slice's poll); if CONFLICTING/DIRTY, escalate
 immediately rather than spinning the full CI_POLL_TOTAL_SECS budget.
```

## temperloop#605/#618: ci-poll.sh's bounded grace window elapsed with
<a id="temperloop-605-618-ci-poll-sh-s-bounded-grace-window-elapsed"></a>

```text
 temperloop#605/#618: ci-poll.sh's bounded grace window elapsed with
 ZERO check-runs ever configured on the head SHA — a repo with no CI,
 NOT a hang and NOT a failure. Mirror build.md 3g's legible skip: resolve
 as success carrying a `noCi` marker so 3h parks `[m]` with the
 `no_ci: true` sentinel, instead of falling through to the catch-all
 below and escalating `ci-failed` (the exact mis-escalation this fixes).
```

## temperloop#2065 review round 1 [HIGH]: agent({schema}) THROWS on a
<a id="temperloop-2065-review-round-1-high-agent-schema-throws-on-a"></a>

```text
 temperloop#2065 review round 1 [HIGH]: agent({schema}) THROWS on a
 StructuredOutput-absent / retry-cap-exceeded subagent — the SAME
 primitive callWorker() wraps in try/catch for exactly this reason
 (see that function's own comment). This call used to be bare: an
 uncaught throw here skipped the workerUsageEmit() block below
 entirely (never reaching it) AND propagated past this function
 uncaught, converting to a generic top-level `worker-error`
 escalation whose payload carries no cost field — silently dropping
 not just the retry's own tokens but the item's WHOLE ledger (the
 main worker's already-successful tokens/wall-clock too), since
 driveItem never reaches park(). Catch it here and normalize into the
 SAME "no verdict" shape the null-return arm below already handles,
 so the emit call is never skippable and this always resolves to a
 clean, in-band escalation instead of an uncaught throw.
```

## temperloop#2065 — the retry's own cost, regardless of what fixVerdict
<a id="temperloop-2065-the-retry-s-own-cost-regardless-of-what-fixv"></a>

```text
 temperloop#2065 — the retry's own cost, regardless of what fixVerdict
 turns out to be below (or whether agent() threw above instead): the
 tokens were spent (and the wall-clock burned) the moment agent()
 returned OR threw, and a fix that FAILS — or never returns a verdict
 at all — still cost real money. Tokens roll up into ONE combined
 `retryTokens` figure (the epic's ledger names "retry tokens" as a
 single number, unlike the main worker's split tokens_in/tokens_out —
 see park()); wall-clock rolls into the SAME total `wall_clock_ms` the
 main worker contributes to (driveItem sums it into mainCost at the
 ciPollLoop call site) — there is one wall-clock figure for the whole
 item, not a per-phase one.
```

## temperloop#1970 — the SAME convergence bound the 3e pass applies, via
<a id="temperloop-1970-the-same-convergence-bound-the-3e-pass-appli"></a>

```text
 temperloop#1970 — the SAME convergence bound the 3e pass applies, via
 the SAME predicate, over the SAME per-worktree round counter: this is
 one item's review budget, not a second independent one. Under the
 bound this escalates byte-identically to pre-#1970. At it, the fix is
 pushed and the residual findings ride 3g.5's merged body re-render
 (fixReviewRounds below feeds reviewBodySuffix) plus the parked tally.
```

## Push the fixed SHA and pin the re-poll to it. This is a plain push — n
<a id="push-the-fixed-sha-and-pin-the-re-poll-to-it-this-is-a-plain"></a>

```text
 Push the fixed SHA and pin the re-poll to it. This is a plain push — no
 --force — because the CI-fix worker's head is a fast-forward descendant
 by construction: it resets to the remote tip (`git reset --hard
 FETCH_HEAD`) and commits on top, so the local head strictly descends
 from the current remote tip. A plain push therefore always succeeds on
 the intended path. We deliberately do NOT pass a classifier-visible
 --force here: pr.sh's internal downgrade cannot prevent the git-
 destructive safety classifier from pre-emptively denying the command
 as SPINE_DENIED (#437), which would mask a routine retry as an opaque
 pre-execution denial. If the head is somehow a genuine non-fast-forward,
 the plain push surfaces as a visible PUSH_REJECTED outcome (triaged
 below), not an opaque SPINE_DENIED. (pr.sh's --force→plain downgrade is
 retained for other callers that legitimately rewrite history — #335.)
```

## temperloop#1071 — the force-push outlived the liveness ceiling. It is 
<a id="temperloop-1071-the-force-push-outlived-the-liveness-ceiling"></a>

```text
 temperloop#1071 — the force-push outlived the liveness ceiling. It is the
 single most dangerous step to guess about (a re-issue could push a second
 time over work the first push may already have landed), so it takes the
 probe-then-escalate disposal and never the retry the `ci-failed` arm
 below would otherwise imply. `adoptable:false`: this loop is polling a PR
 it already has — there is nothing to adopt, only a SHA to establish.
```

## temperloop#2014 — the FIFTH `--sha` assignment, and the one the issue'
<a id="temperloop-2014-the-fifth-sha-assignment-and-the-one-the-iss"></a>

```text
 temperloop#2014 — the FIFTH `--sha` assignment, and the one the issue's
 own audit list does not name: the re-push's reported SHA arrives
 through the same executor transport as the 3f push, so it can go
 missing the same way. Guarded BEFORE it is adopted, so the previous
 (still valid, but now stale) `sha` is never silently re-polled either —
 re-polling the pre-fix head is the #254 false-green this pin exists to
 prevent.
```

## ERROR or any unexpected outcome (e.g. ci-poll.sh itself errored) →
<a id="error-or-any-unexpected-outcome-e-g-ci-poll-sh-itself-errore"></a>

```text
 ERROR or any unexpected outcome (e.g. ci-poll.sh itself errored) →
 escalate rather than spin.

 temperloop#2014 — but NOT as `ci-failed` when ci-poll.sh refused to run on
 its own arguments. `ci-failed` means "this PR's CI is red", and a run
 disposing on it parks or re-drives a healthy PR; a bad argument means the
 poll never observed CI at all, so it is its own kind with its own
 disposition. The pre-flight above makes this unreachable from the
 driver's own hand-off — this arm catches the argument errors the driver
 does not own (a stale vendored ci-poll.sh, an owner/repo or PR number
 this file passed through from its input).
```

## ======================================================================
<a id="note-2"></a>

```text
 =============================================================================
 levelPhaseTitle — the run-identifying progress-row heading (temperloop#903),
 now emitted ONCE PER STAGE rather than once per level (temperloop#1294).
 =============================================================================
 The Workflow progress UI renders one row per workflow (labelled from the PURE
 LITERAL `meta.description`, which by runtime constraint is byte-identical on
 every run) plus a group heading per phase(). phase() is therefore the ONLY
 surface that can carry run context — and it used to read `build level — N
 item(s)`, which identifies nothing: not the repo, not the items, not the
 issues. Two concurrent spine runs (routine: one /fix session drives several
 back to back) rendered indistinguishable rows.

 The heading names, from context already in scope at the call site:
   build level · <stage> — <ownerRepo> · <N> item(s) · <slug> (#<ghIssue>), …
 e.g.  build level · gate — Towheads/foundation · 1 item · row-per-stage (#1294)

 temperloop#1294 added the `· <stage>` segment and made the level emit ONE
 phase() PER STAGE (claim → build → gate → PR → CI) instead of a single static
 heading for the whole level. Two independent effects, both wanted:
   • the ACTIVE phase now ADVANCES as the level progresses, so a collapsed view
     that renders it moves instead of sitting on one heading all run;
   • the expanded progress tree groups agents by stage instead of dumping every
     executor into one 'machinery' box.
 The #903 run context rides EVERY stage heading — dropping it from the later
 stages would re-open exactly the complaint #903 closed.

 TWO SURFACES, ONE STRING. `phase(t)` moves the GLOBAL cursor (what a collapsed
 view shows); `agent(…, {phase: t})` assigns one agent to the group named `t`.
 The Workflow docs are explicit that the global cursor RACES inside
 parallel()/pipeline() stages — this level fans its items out with parallel(),
 so item A can be at CI while item B is still at build. Every agent spawn below
 therefore passes opts.phase EXPLICITLY (same string → same group box) and never
 relies on whatever the global cursor happens to be. enterStage() returns that
 string and, as a side effect, advances the global cursor MONOTONICALLY (a stage
 already passed never re-fires), so the collapsed row tracks the level's
 furthest-reached stage and can never appear to run backwards when a straggler
 item is still on an earlier one.

 meta.phases: DELIBERATELY ABSENT. `meta` is a pure literal by runtime
 constraint, and meta.phases entries are matched against phase() titles
 EXACTLY. Every title here is dynamic by construction (#903 requires the repo,
 the item count and the item/issue list in it), so no static entry could ever
 match one — declaring the five stages statically would render five permanently
 EMPTY groups alongside the five real ones. Per the runtime's own contract a
 phase() call with no matching meta entry simply gets its own progress group,
 which is the correct outcome here; this is a noted, accepted consequence of
 #903's dynamic-title requirement, not an oversight to work around.

 BOUNDED BY CONSTRUCTION: a level can hold many items, so at most
 PHASE_TITLE_MAX_ITEMS slugs are named and the rest collapse to `+K more` — a
 20-item level can never emit a 20-slug heading that swamps the progress row.
 Every field is optional-safe (a missing ownerRepo / ghIssue simply drops its
 segment) because this is a cosmetic display string: it must never be the thing
 that throws and takes a level down.
```

## enterStage(stage) — returns the group name for `stage` (hand it straig
<a id="enterstage-stage-returns-the-group-name-for-stage-hand-it-st"></a>

```text
 enterStage(stage) — returns the group name for `stage` (hand it straight to
 opts.phase) and advances the global phase cursor to it the first time the
 level reaches that stage. Monotonic: a later item re-entering an earlier stage
 is a no-op on the cursor, and STAGE_RECOVER (not in STAGE_ORDER) never moves
 it at all. Cosmetic by construction — it must never throw.
```

## ======================================================================
<a id="note-3"></a>

```text
 =============================================================================
 The ZERO-DISPOSITION guard (temperloop#2004).

 /build Step 3, /fix Step 4a and /sweep Phase 2 all branch on the returned
 {parked, escalations}: each handles `parked` non-empty and `escalations`
 non-empty, and NONE had an arm for both being empty. A {parked:[],
 escalations:[]} return therefore matched no branch and fell through as "the
 level completed with nothing to report" — so an item that was asked for and
 disposed of nowhere vanished with no PR, no park, no escalation and no
 signal. (Observed 2026-09-13, run wf_f3b9c160-6ca: a stopped-and-resumed run
 returned an empty object in ~13 ms having re-run nothing, while the tracked
 issue was still in-progress with a live claim stamp.)

 The guard lives HERE, below the three drivers, so all three inherit it once
 rather than each restating it — the same hoist shape temperloop#2006 used
 for the sideline notice. It returns a NAMED, branchable value (never a bare
 throw): the drivers re-probe real state on it instead of concluding
 anything.

 The two CONTROLS are what make it discriminating rather than noisy — a guard
 that flags every legitimately empty level is worse than none:
   1. nothing was asked to drive (empty `items`, or an onlySlugs filter that
      matched no item) → disposing of nothing is a tautology, not a
      contradiction. Silent, and the returned object is byte-identical to
      before this item.
   2. something WAS disposed → any parked record or any escalation means the
      drive reported on the set. This is also what clears the kind:spike
      path: a spike opens no PR and pushes no SHA, but it still `park()`s a
      verdict marker (`park(slug, null, null, …)`), so a spike-only level
      lands in control 2 and is never flagged.
 Returns null when either control holds; otherwise the named outcome.
 =============================================================================
```

## ======================================================================
<a id="note-4"></a>

```text
 =============================================================================
 ITEM-KEY NORMALIZATION AT THE ORCHESTRATOR→WORKFLOW SEAM (temperloop#1700).
 =============================================================================
 This file reads the item's issue number as `item.ghIssue`. `claude/plan-schema.md`
 DOCUMENTS the field as `gh_issue:`, and `also_closes:` / `depends-on:` likewise.
 A caller that constructs items from the documented schema — a legitimate
 calling pattern, since the schema is what documents it — therefore gets:

   no `--gh-issue` flag on `pr.sh open` → no `Closes #N` in the body →
   a PR that merges green and leaves its issue OPEN → and no warning anywhere.

 Observed on PR #1697 (`closingIssuesReferences` empty); three PRs from one
 level merged closing nothing. The SILENCE is the defect: "this item has no
 tracked issue" is a legal state (`gh_issue:` is optional), so an unread key is
 indistinguishable from an absent one, and the merged-with-no-linkage PR leaves
 a stranded `fnd:status:in-progress` item wearing a live claim stamp.

 Same family as #1698 above — one meaning wearing two names across a seam, with
 the consumer's absent-key path producing a plausible-looking result instead of
 an error. Both halves the issue asks for are implemented, because each catches
 what the other cannot:
   (1) ACCEPT the documented spelling, normalizing once here. Fixes the three
       aliases we know about.
   (2) WARN on a key nothing reads. Catches the NEXT one — the class, not the
       instance.
```

## Every key this file actually READS off an item. This list is not a
<a id="every-key-this-file-actually-reads-off-an-item-this-list-is-"></a>

```text
 Every key this file actually READS off an item. This list is not a
 hand-maintained copy that drifts: the K1700 lockstep guard in
 test_workflow.sh greps THIS file for `item.<key>` dereferences and
 reconciles the resulting set against this array in BOTH directions — a read
 missing from the list, or a listed key nothing reads any more, fails the
 suite. (Round 2: the comment used to claim that guard before it existed,
 which is the same "a backstop that is only asserted in prose" defect this PR
 removes elsewhere. The guard is real now.)
```

## temperloop#1700 — normalize the DOCUMENTED plan-schema spellings into 
<a id="temperloop-1700-normalize-the-documented-plan-schema-spellin"></a>

```text
 temperloop#1700 — normalize the DOCUMENTED plan-schema spellings into the
 camelCase keys this file reads, ONCE, at the single point items enter. Every
 later `item.ghIssue` / `item.alsoCloses` / `item.dependsOn` read — including
 the 3f `--gh-issue` / `--also-closes` flags whose absence merged three PRs
 closing nothing — is fed from here.
```

## onlySlugs — optional continuation filter (escalation-resume loop).
<a id="onlyslugs-optional-continuation-filter-escalation-resume-loo"></a>

```text
 onlySlugs — optional continuation filter (escalation-resume loop).
 When the orchestrator re-invokes this workflow after capturing a human
 verdict for one or more escalated items, it passes input.onlySlugs as an
 array of slugs to re-drive. Only those items enter the pipeline; their
 sibling items are already parked ([m] with pr: on the plan note) and must
 not be re-driven. An absent or empty onlySlugs means "drive everything."
```

## Name the run in the progress row (temperloop#903). Set AFTER the onlyS
<a id="name-the-run-in-the-progress-row-temperloop-903-set-after-th"></a>

```text
 Name the run in the progress row (temperloop#903). Set AFTER the onlySlugs
 filter on purpose: on a continuation the heading must name the slugs actually
 being re-driven, not the level's full membership (whose siblings are already
 parked and untouched). Nothing above this point awaits, so the row is never
 observed unlabelled.

 temperloop#1294: `phaseItems` is the ONE assignment that binds every later
 stage heading to this run's active items — it must land before any agent
 spawns. enterStage() then opens the first stage (claim) and each later stage
 advances the cursor from its own spawn site inside driveItem().
```

## temperloop#2006 — the LEVEL-SUMMARY half of the sideline notice. Each
<a id="temperloop-2006-the-level-summary-half-of-the-sideline-notic"></a>

```text
 temperloop#2006 — the LEVEL-SUMMARY half of the sideline notice. Each
 per-item record already carries its own `sidelined` object (stampSideline
 at the fan-out above); this rolls the level's set up onto the returned
 object so the orchestrator's Step 6 summary and the merge gate see it
 without re-walking two arrays. Omitted entirely when nothing sidelined, so
 an ordinary level's return is byte-identical to before this item.

 temperloop#2080 — the map is keyed by the RECORD key, which for a
 dual-build arm is `<slug>@<arm>` (that is what phase 1 sees as item.slug).
 Walking `activeItems` alone would therefore find NEITHER arm's notice and
 the level would report zero sideline notices while two builds sat shelved.
 So the rollup walks the map's own keys and splits the arm back out: a
 two-arm item that sidelined both arms produces TWO entries, one per arm,
 and a single-arm level produces exactly the pre-#2080 list (same entries,
 same order, no `arm` key) because the arm lookups simply miss. The walk
 stays over `activeItems` rather than over the map's own insertion order so
 the list is deterministic — insertion order is parallel-completion order,
 which would reshuffle the rollup run to run.
```

## Top-level entry (#437): the Workflow runtime wraps this script body in
<a id="top-level-entry-437-the-workflow-runtime-wraps-this-script-b"></a>

```text
 Top-level entry (#437): the Workflow runtime wraps this script body in an async
 context and does NOT call a default export — it runs the top-level body. So we
 invoke the driver and return its value here, at top level. (This file is
 therefore a Workflow-runtime script, NOT a standalone ESM — top-level `return`
 means it cannot be `node --check`'d or `import()`'d; the test harness simulates
 the runtime wrap instead.)
```

## temperloop#1698 — render an unknown total as `?`, never as a number. T
<a id="temperloop-1698-render-an-unknown-total-as-never-as-a-n"></a>

```text
 temperloop#1698 — render an unknown total as `?`, never as a number. The
 margin warning is likewise suppressed on an unknown figure: a warning
 computed from a number nobody measured is the same confident-wrong
 instrument in the other direction.
```

## temperloop#939: a recovered verdict carries a synthesized inline surfa
<a id="temperloop-939-a-recovered-verdict-carries-a-synthesize"></a>

```text
 temperloop#939: a recovered verdict carries a synthesized inline surface.
 pr.sh resolves the surface by precedence (file flag → path key → inline),
 so this is used ONLY when no real `.build-verification.md` exists.
```

## A worker commit carries a closing keyword (the ec8d5fd class). Don't p
<a id="a-worker-commit-carries-a-closing-keyword-the-ec8d5fd-c"></a>

```text
 A worker commit carries a closing keyword (the ec8d5fd class). Don't push
 it as-is — escalate so the orchestrator re-words and re-drives.
```

## The same three facts, best-effort and free (no extra probe): every
<a id="the-same-three-facts-best-effort-and-free-no-extra-prob"></a>

```text
 The same three facts, best-effort and free (no extra probe): every
 pr-open failure deserves to be readable as "work done, reporting
 broke" rather than as "nothing landed".
```

## 3h. Park as [m] (the workflow returns the record; orchestrator writes)
<a id="3h-park-as-m-the-workflow-returns-the-record-orchestrat"></a>

```text
 --- 3h. Park as [m] (the workflow returns the record; orchestrator writes)
 A NO_CI resolution (temperloop#605/#618) parks the same, but the returned
 record carries `no_ci: true` so the orchestrator stamps the sentinel.
```

## sha pins the head (REQUIRED on a re-poll after a force-push; harmless 
<a id="sha-pins-the-head-required-on-a-re-poll-after-a-force-p"></a>

```text
 --sha pins the head (REQUIRED on a re-poll after a force-push; harmless on
 the first poll where it equals the pushed head). --timeout is the SLICE.
```

## The runtime forbids Date.now(); we bound by SLICE COUNT instead of wal
<a id="the-runtime-forbids-date-now-we-bound-by-slice-count-in"></a>

```text
 The runtime forbids Date.now(); we bound by SLICE COUNT instead of wall
 clock (slices * slice-secs ≈ total budget). Integer ceil.
```

## Buffered slices from the current ci-batch: one { mergeState, out } pai
<a id="buffered-slices-from-the-current-ci-batch-one-mergestat"></a>

```text
 Buffered slices from the current ci-batch: one { mergeState, out } pair per
 slice the batch actually ran. Refilled whenever it empties; FLUSHED whenever
 `sha` changes (buffered results are pinned to the previous head — #254).
```

## One executor agent, CI_POLL_SLICES_PER_BATCH (merge-state, ci-poll)
<a id="one-executor-agent-ci-poll-slices-per-batch-merge-state"></a>

```text
 One executor agent, CI_POLL_SLICES_PER_BATCH (merge-state, ci-poll)
 pairs, one Bash invocation. Never more slices than the budget has left.
```

## The executor came back with an empty results array — it ran nothing we
<a id="the-executor-came-back-with-an-empty-results-array-it-r"></a>

```text
 The executor came back with an empty results array — it ran nothing we
 can read. Escalate rather than spin the remaining budget on a batch
 that produces nothing.
```

## This slice's own ci-poll.sh object. Absent only if the batch truncated
<a id="this-slice-s-own-ci-poll-sh-object-absent-only-if-the-b"></a>

```text
 This slice's own ci-poll.sh object. Absent only if the batch truncated
 without the merge-state gate firing (a malformed executor return) — the
 ERROR sentinel then falls into the catch-all escalation at the bottom of
 the loop rather than being silently skipped.
```

## Slice elapsed with checks still pending → poll the next slice. This is
<a id="slice-elapsed-with-checks-still-pending-poll-the-next-s"></a>

```text
 Slice elapsed with checks still pending → poll the next slice. This is
 the normal "CI takes longer than one slice" path, NOT a failure.
```

## Re-spawn the worker against the SAME worktree to fix CI, then
<a id="re-spawn-the-worker-against-the-same-worktree-to-fix-ci"></a>

```text
 Re-spawn the worker against the SAME worktree to fix CI, then
 force-push and re-poll PINNED to the new SHA (#254 guard).
```

## A WORKER agent, but it belongs to the CI stage (temperloop#1294)
<a id="a-worker-agent-but-it-belongs-to-the-ci-stage-temperloo"></a>

```text
 A WORKER agent, but it belongs to the CI stage (temperloop#1294) —
 grouping it there is what makes the CI box read as "CI is being fixed"
 rather than dropping it back into a build box the level already left.
```

## agent() threw — the same "no verdict" outcome as the bare-null
<a id="agent-threw-the-same-no-verdict-outcome-as-the-bare-nul"></a>

```text
 agent() threw — the same "no verdict" outcome as the bare-null
 return handled just below, only reached via the throw arm instead.
 Escalate in-band rather than letting the throw propagate past this
 function uncaught (which would land as a generic worker-error).
```

## agent() returned null — user skip or terminal API error in the CI-fix
<a id="agent-returned-null-user-skip-or-terminal-api-error-in-"></a>

```text
 agent() returned null — user skip or terminal API error in the CI-fix
 worker. Already inside a CI-failure retry context; escalate cleanly.
```

## FLUSH any slices still buffered from the pre-fix batch: they were poll
<a id="flush-any-slices-still-buffered-from-the-pre-fix-batch-"></a>

```text
 FLUSH any slices still buffered from the pre-fix batch: they were polled
 against the OLD head and reading them now would re-resolve CI on a stale
 SHA — exactly the #254 false-green the --sha pin exists to prevent. The
 next iteration refills the buffer with polls pinned to the new sha.
```

## The items whose slugs/issues every stage heading names — the ACTIVE su
<a id="the-items-whose-slugs-issues-every-stage-heading-names-"></a>

```text
 The items whose slugs/issues every stage heading names — the ACTIVE subset
 (post-onlySlugs filter), assigned by buildLevel() before any fan-out. Empty
 until then, which is safe: nothing spawns an agent before it is set.
```

## itemTag — `<slug> (#<issue>)`, or the bare slug when the item has no i
<a id="itemtag-slug-issue-or-the-bare-slug-when-the-item-has-n"></a>

```text
 itemTag — `<slug> (#<issue>)`, or the bare slug when the item has no issue
 (kind:spike items and board-OFF runs legitimately carry no ghIssue).
```

## levelPhaseTitle(list, stage) — the heading itself. `stage` is optional
<a id="levelphasetitle-list-stage-the-heading-itself-stage-is-"></a>

```text
 levelPhaseTitle(list, stage) — the heading itself. `stage` is optional; absent
 it reproduces the pre-#1294 level-wide form byte-for-byte.
```

## stagePhase(stage) — the group name for `stage`, WITHOUT touching the g
<a id="stagephase-stage-the-group-name-for-stage-without-touch"></a>

```text
 stagePhase(stage) — the group name for `stage`, WITHOUT touching the global
 cursor. Used by the off-path recovery spawns.
```

## The caller acts on THIS: exactly what to look at before concluding
<a id="the-caller-acts-on-this-exactly-what-to-look-at-before-"></a>

```text
 The caller acts on THIS: exactly what to look at before concluding
 anything about this slug.
```

## True when this was a continuation run (onlySlugs scoped the set) — the
<a id="true-when-this-was-a-continuation-run-onlyslugs-scoped-"></a>

```text
 True when this was a continuation run (onlySlugs scoped the set) — the
 shape the observed replay took; false on a fresh level.
```

## Documented plan-schema (and orchestrator bookkeeping) fields this file
<a id="documented-plan-schema-and-orchestrator-bookkeeping-fie"></a>

```text
 Documented plan-schema (and orchestrator bookkeeping) fields this file
 deliberately does NOT read — the plan note carries them for its own use, and
 warning on them would drown the signal the warning exists to carry.
```

## The camelCase spelling WINS when both are present — it is what this fi
<a id="the-camelcase-spelling-wins-when-both-are-present-it-is"></a>

```text
 The camelCase spelling WINS when both are present — it is what this file
 has always read, so a caller passing both cannot be silently retargeted.
```

## The generalization of the fix: a key nothing reads is named, once, rat
<a id="the-generalization-of-the-fix-a-key-nothing-reads-is-na"></a>

```text
 The generalization of the fix: a key nothing reads is named, once, rather
 than absorbed. An item with NEITHER spelling of a known field stays legal
 and silent — a genuinely untracked item is a normal state, not a warning.
```

## ======================================================================
<a id="note-5"></a>

```text
 =============================================================================
 Entry point — drive the level, return {parked, escalations}.
 =============================================================================
```

## REFUSE, never degrade. A level asked to compare two models that quietl
<a id="refuse-never-degrade-a-level-asked-to-compare-two-model"></a>

```text
 REFUSE, never degrade. A level asked to compare two models that quietly
 compared none is indistinguishable, after the fact, from one that did.
```

## temperloop#1819: a throw whose message carries the harness's
<a id="temperloop-1819-a-throw-whose-message-carries-the-harne"></a>

```text
 temperloop#1819: a throw whose message carries the harness's
 session-limit text is a quota death, not a content failure — it gets
 its own kind here too, so no thrown shape can collapse back into
 worker-error. Anything else keeps the #437 conversion unchanged.
```

## Partition the per-item results into the small return object. NEVER wri
<a id="partition-the-per-item-results-into-the-small-return-ob"></a>

```text
 Partition the per-item results into the small return object. NEVER write
 the plan note here — only RETURN what to write (orchestrator serializes
 writeback at the level boundary).
```

## temperloop#2004 — the ZERO-DISPOSITION guard, evaluated on the SETTLED
<a id="temperloop-2004-the-zero-disposition-guard-evaluated-on"></a>

```text
 temperloop#2004 — the ZERO-DISPOSITION guard, evaluated on the SETTLED
 partition (after the loop above, so it sees what actually came back) and
 on `activeItems` (the post-onlySlugs set this run was actually asked to
 drive, which is the only set the contradiction is defined over).
```

## Both extra keys are OMITTED when their condition does not hold, so an
<a id="both-extra-keys-are-omitted-when-their-condition-does-n"></a>

```text
 Both extra keys are OMITTED when their condition does not hold, so an
 ordinary level's return stays byte-identical to before #2006/#2004.
```

## gateInFlightIndex(ledger) — WHICH gate the stopped run was ON (temperlo
<a id="gateinflightindex-ledger-which-gate-the-stopped-run-was-on-t"></a>

```text
 gateInFlightIndex(ledger) — WHICH gate the stopped run was ON, read off the
 LAST ledger entry (temperloop#1650).

 Two shapes, two readings. A slice that REPORTED a resume point stopped
 cleanly at a gate boundary, so the run's next gate IS that index. A slice
 the Bash cap KILLED reported nothing at all, so the only index anyone has
 is the `startAt` it was handed — the overrun is at that gate or after it
 (the pooled executor runs a CHUNK at a time, so the killed window can be
 wider than one gate; the payload's `sliceLog` is what narrows it further,
 since every gate that FINISHED printed its own `[ok]`/`[FAIL]` line).

 Ledger-derived, not loop-counter-derived, for the same reason gateVerdict()
 is: the ledger is the authoritative record of what the slices reported, and
 a second derivation path is a second thing that can disagree.
```

## gateSliceClampNote() — what raising BUILD_GATE_SLICE_SECS can ACTUALLY
<a id="gatesliceclampnote-what-raising-build-gate-slice-secs-can-act"></a>

```text
 gateSliceClampNote() — what raising BUILD_GATE_SLICE_SECS can ACTUALLY buy
 (temperloop#1650).

 The pre-#1650 remedy said "raise BUILD_GATE_SLICE_SECS (bounded by the agent
 Bash cap)" and stopped there, which reads as a lever with room in it. It is
 not one. GATE_BASH_TIMEOUT_MS — the deadline that actually killed the slice —
 is DERIVED from the slice budget (slice*1000 + GATE_SLICE_OVERRUN_MS, i.e.
 1.8x at the 300s default) and then clamped to AGENT_BASH_CAP_MS, the agent's
 hard foreground-Bash ceiling. At the default that leaves the slice 300s ->
 360s (+20%) and the kill deadline 540000ms -> 600000ms (+11%). A reader sent
 to a +11% lever to fix a gate that overran a 540s window has been sent on an
 errand that cannot succeed.

 So the note states the derivation and the arithmetic, and — at or within
 GATE_SLICE_CLAMP_NEAR_RATIO of GATE_SLICE_SECS_MAX — says plainly that there
 is no headroom left rather than naming the raise at all. Both figures are
 COMPUTED from the constants they describe, never typed as literals, so a
 retuned overrun or cap cannot leave the prose stating a stale percentage.
```

## gateUnknownRemedy(terminalOutcome, inFlight, slices) — the TWO failure
<a id="gateunknownremedy-terminaloutcome-inflight-slices-the-two-fai"></a>

```text
 gateUnknownRemedy(terminalOutcome, inFlight, slices) — the TWO failure
 shapes an UNKNOWN verdict can be in (temperloop#1650).

 One message covered both before, and their remedies are OPPOSITES:

   • GATE_TIMEOUT — the executor's Bash cap fired mid-slice. The slice budget
     is honoured only BETWEEN gates, so this can only mean ONE gate ran past
     the whole window. More slice budget cannot reach it (see the clamp note
     above); only splitting or speeding up THAT gate can.
   • GATE_SLICE — the slice CEILING was exhausted while every slice returned
     cleanly. This is the aggregate-slow suite, and more gate wall time
     genuinely does help: the slice budget, the slice ceiling, or a shorter
     list.

 A third arm covers the remaining UNKNOWN case (an unrecognized terminal
 outcome, or a "finished"-named outcome over a final resume point): it names
 NEITHER shape rather than guessing one, because a budget raise recommended
 on an unestablished shape is exactly the errand this item removed.
```

## gateInFlightSelectCmd(idx) — the ONE builder the executed probe AND
<a id="gateinflightselectcmd-idx-the-one-builder-the-executed-probe-a"></a>

```text
 gateInFlightSelectCmd(idx) — the ONE builder the executed probe AND the
 operator-facing `resolve` line are both made from (temperloop#1650 round 2).

 Round 1 emitted the ordinal->name pipeline TWICE: once inside the probe (with
 `${gateScopeEnv}` and every operand `sq()`-quoted) and once as the `resolve`
 string handed to the reader (with neither). That is not cosmetic drift. The
 scope env is what puts quality-gates.sh on its SCOPED arm, and the script
 consults `QUALITY_GATES_SELECTION_PIN` only inside `if (( SCOPED ))` — so
 without it the pin is ignored and `--list-selected` prints the FULL set
 (measured in this tree: 211 lines unscoped, 43 scoped). The escalation's
 ordinal indexes the 43-line list; the pasted command indexed the 211-line one,
 so for any index > 0 it named an unrelated gate with total confidence — the
 plausible-looking-wrong-answer failure this item exists to remove, on the only
 path `resolve` is ever rendered on (`BUILD_GATE_SCOPED` defaults to 1).

 So the two are ONE function, and the probe wraps it rather than restating it.
 Quoting follows for free: a checkout path with a space no longer breaks the
 pasted line. A fixture case executes BOTH strings against a stub
 quality-gates.sh whose selected and full lists differ, and asserts they name
 the same gate — the test that fails against round 1's code.
```

## gateInFlightNameCmd(idx) — turn a stopped run's gate ORDINAL into
<a id="gateinflightnamecmd-idx-turn-a-stopped-run-s-gate-ordinal-into"></a>

```text
 gateInFlightNameCmd(idx) — turn a stopped run's gate ORDINAL into its NAME
 (temperloop#1650).

 "Split the gate list" is only actionable if the reader knows WHICH gate to
 split; an ordinal alone sends them searching. The ordinal space is the
 PINNED selection (temperloop#1663), and `quality-gates.sh --list-selected`
 prints exactly that list, in that order, as a dry run — so the name is one
 filtered `sed -n` away. The gate lines are the ones starting `make ` or
 `bash `, which is what separates them from the selection banner, the pin
 notice and the trailing skipped-gate block.

 It runs as ONE machinery call on the escalation path only — never on the hot
 path, and never inside the slice loop, so the gate's own timing is untouched
 — and it is FAIL-SOFT in both directions: an unresolved name (an absent
 script, a refused command, a throw) leaves the payload carrying the ordinal
 and the `resolve` command line, and the escalation itself is never at risk.
```

## temperloop#1650 — NAME the gate in flight and the CLAMP, so the
<a id="temperloop-1650-name-the-gate-in-flight-and-the-clamp-so-the"></a>

```text
 temperloop#1650 — NAME the gate in flight and the CLAMP, so the remedy is a
 move the reader can make.

 `inFlightGate` rides the payload as a FACT the escalation carries, the same
 shape `committed_work` uses: `index` (always, when the ledger establishes
 one), `gate` (the resolved name, when the selection still resolves),
 `resolve` (the one command that turns the ordinal into the name by hand) and
 `sliceLog` (which gates had already finished). `null` when the ledger
 establishes no index — an honest absence, never a guessed ordinal.

 The GATE_TIMEOUT vs GATE_FAIL split (temperloop#1021) is untouched: this is
 the UNKNOWN-verdict branch only, the kind stays `acceptance-gate-timeout`,
 and a RED verdict still escalates `acceptance-gate-failed` exactly as before.
```

## A THROWAWAY COPY of the pin, so the dry run cannot WRITE the sh
<a id="a-throwaway-copy-of-the-pin-so-the-dry-run-cannot-write-the-sh"></a>

```text
 A THROWAWAY COPY of the pin, so the dry run cannot WRITE the shared one
 (temperloop#1650 round 3, review finding 3).

 The probe and the operator-facing `resolve` line are described as READ-ONLY
 enrichment, and that was true of the BRANCH but not of `/tmp`: when
 `/tmp/qg-<slug>.selection-pin` is absent or empty, quality-gates.sh's scoped
 path resolves the changed set and CREATES the caller-supplied pin — so a
 dry run, or an operator pasting the line, could author the very file the
 slice loop treats as slice 1's authoritative record, with nothing cleaning
 it up afterwards.

 So both forms copy the shared pin to `<pin>.probe` first and point
 QUALITY_GATES_SELECTION_PIN at the copy. An absent or empty shared pin
 leaves the copy REMOVED rather than stale, so the dry run resolves fresh
 into the throwaway exactly as it used to — same answer, no shared-state
 write. Slice 0's `rm -f` retires the copy along with the pin itself.

 The copy is guarded by `[ -s ]` rather than silenced with a redirect, which
 is finding 1's constraint: the operator-facing line carries NO `2>/dev/null`
 at all (see the next note), so it must not need one.
```

## The `resolve` line is the one that must SPEAK — no stderr redirect
<a id="the-resolve-line-is-the-one-that-must-speak-no-stderr-redirect"></a>

```text
 The `resolve` line is the one that must SPEAK (temperloop#1650 round 3,
 review finding 1).

 Round 2 folded the probe and the operator line into one builder and, with
 them, the probe's `2>/dev/null`. That silencing is wrong on the operator's
 half, and wrong precisely where it lands: `gateUnknownRemedy` renders
 `resolve` ONLY on the branch where `inFlight.gate` is absent — i.e. exactly
 when the automatic probe already came back empty — and the load-bearing
 explanations for that emptiness are the two lines quality-gates.sh writes to
 STDERR (`NOTE: --scoped could not resolve a local changed set — running the
 FULL set.`, `NOTE: a scoped run was requested but QUALITY_GATES_SCOPE=full is
 set`). Handing the reader a command whose whole job is to explain the
 emptiness, pre-silenced, is the worst place in the message to hide output.

 So the redirect moved to the PROBE'S CALL SITE (`$( <builder> 2>/dev/null )`)
 and the builder itself carries none. The operands stay shared — the round-2
 fix that matters — and only the machine path stays quiet. A fixture asserts
 the rendered `resolve` string contains no `2>/dev/null`.

 The builder is also a SUBSHELL (`( … )`, finding 4): the line starts with a
 `cd`, and pasting it must not leave the operator's own shell somewhere else.
```

## The list identity the STOPPED RUN walked — the oracle the probe
<a id="the-list-identity-the-stopped-run-walked-the-oracle-the-probe"></a>

```text
 The list identity the STOPPED RUN walked — the oracle the probe's own
 answer is checked against (temperloop#1650 round 3, review finding 2).

 An ordinal is only meaningful against the list it was measured in, and the
 probe RE-DERIVES a list rather than reading the one the run walked. Those
 can differ, and there is a live path that makes them differ: quality-gates.sh's
 stale-resume guard sets QG_START_AT=0, SCOPED=0, QUALITY_GATES_SCOPE=full and
 rebuilds GATES from the FULL set — and it does NOT remove the pin. The run
 then walks the full list and reports ordinals into it, while the probe, which
 exports QUALITY_GATES_SCOPED=1 and finds that still-populated pin, lists the
 SCOPED subset. Two lists, one ordinal, and a confidently WRONG gate name with
 nothing to distinguish it from a right one — kernel principle 5 (counter AI
 failure modes structurally) in the exact field this issue exists to make
 trustworthy.

 The oracle already existed: every GATE_SLICE reports QUALITY_GATES_SELECTION
 as `<count>:<digest>`, and that value now rides each ledger entry. The probe
 asks `--list-selected` for the SAME fingerprint (one additive `printf` in
 quality-gates.sh, changing no existing line and no exit code) and compares.

 Degrade, never error, in all three unverifiable directions:
   - fingerprints DISAGREE   -> GATE_NAME_UNKNOWN (the name is not trustworthy)
   - no slice recorded one   -> no comparison, today's behaviour exactly
   - the listing printed none (an older vendored quality-gates.sh) -> likewise
 The escalation itself is never at risk; the name has always been enrichment.
```

## The LIST IDENTITY this slice walked (temperloop#1650 round 3)
<a id="the-list-identity-this-slice-walked-temperloop-1650-round-3"></a>

```text
 The LIST IDENTITY this slice walked (temperloop#1650 round 3). Already
 reported by every GATE_SLICE and already carried forward in `gateSelection`
 for the NEXT slice's stale-resume check — but it was dropped on the floor
 afterwards, so the ledger (and the payload built from it) could not say
 which list an ordinal indexed. Recording it makes the escalation
 self-describing AND gives the in-flight probe its oracle. Omitted, never
 empty-stringed, when a slice reported none.
