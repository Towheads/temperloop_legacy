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

> **Part 2 of 7.** Split to stay under the per-file prose cap
> (`PROSE_BUDGET_TIER2_FILE_CAP`). Other parts: [`build-level.design-notes.md`](build-level.design-notes.md), [`build-level.design-notes-3.md`](build-level.design-notes-3.md), [`build-level.design-notes-4.md`](build-level.design-notes-4.md), [`build-level.design-notes-5.md`](build-level.design-notes-5.md), [`build-level.design-notes-6.md`](build-level.design-notes-6.md), [`build-level.design-notes-7.md`](build-level.design-notes-7.md).

## Timed out iff BOTH the step died by SIGNAL and the wall clock actually
<a id="timed-out-iff-both-the-step-died-by-signal-and-the-wall"></a>

```text
 Timed out iff BOTH the step died by SIGNAL and the wall clock actually
 reached the ceiling. The second test is what keeps a step that legitimately
 exits on a signal of its own from being mislabelled LOST.
```

## stepFnDef — wrap a step's command text VERBATIM in a shell function, s
<a id="stepfndef-wrap-a-step-s-command-text-verbatim-in-a-shel"></a>

```text
 stepFnDef — wrap a step's command text VERBATIM in a shell function, so `__lb`
 can background it as one unit. The body is placed on its own line (never
 `{ <cmd>; }`) precisely so a command that already ends in `;` or `fi` stays
 valid, and so not one byte of the sq()-quoted command text is rewritten.
```

## stepBoundInvoke — the call itself. `kind` is the batch step's own name
<a id="stepboundinvoke-the-call-itself-kind-is-the-batch-step-"></a>

```text
 stepBoundInvoke — the call itself. `kind` is the batch step's own name (or the
 solo call's phase), and it rides through to the STEP_TIMEOUT payload so an
 escalation names WHICH step the ceiling bounded.
```

## Fallback (no pre-resolved dir — older invocations, or a consuming repo
<a id="fallback-no-pre-resolved-dir-older-invocations-or-a-con"></a>

```text
 Fallback (no pre-resolved dir — older invocations, or a consuming repo that
 does not yet pass machineryBinDir): resolve in BASH, exactly as before (#560).
```

## Repo "owner/repo" — the orchestrator passes it in input.ownerRepo (the
<a id="repo-owner-repo-the-orchestrator-passes-it-in-input-own"></a>

```text
 Repo "owner/repo" — the orchestrator passes it in input.ownerRepo (the
 workflow has no shell to derive it). ci-poll.sh / gate ops take owner/repo;
 push/scan take the worktree path. WITHOUT input.ownerRepo every ci-poll gets
 '' → ERROR, so the orchestrator MUST pass it (Step 0 probe). See the I/O note.
```

## machineryAgent — spawn a machinery executor. `promptFor(lean)` builds 
<a id="machineryagent-spawn-a-machinery-executor-promptfor-lea"></a>

```text
 machineryAgent — spawn a machinery executor. `promptFor(lean)` builds the
 prompt for the resolved agent type: `lean` is true when the executor's own
 definition already carries the standing contract, false for the
 general-purpose fallback, which needs it spelled out per call as before.
```

## temperloop#1071: the emitted text now opens with a few lines of inline
<a id="temperloop-1071-the-emitted-text-now-opens-with-a-few-l"></a>

```text
 temperloop#1071: the emitted text now opens with a few lines of inline
 `sleep`/`kill` watchdog before the helper call. Name it, so the executor
 reads the wrapper as part of the command rather than as noise to strip
 (the same #72 lesson that made the two framing lines above explicit).
```

## temperloop#115: for a legitimately long-running command (the 3e.5 gate
<a id="temperloop-115-for-a-legitimately-long-running-command-"></a>

```text
 temperloop#115: for a legitimately long-running command (the 3e.5 gate),
 raise the Bash TOOL's timeout parameter — NOT the command text — so the
 executor does not kill it at the default 2 minutes.
```

## The three lines below are the executor's STANDING contract, identical 
<a id="the-three-lines-below-are-the-executor-s-standing-contr"></a>

```text
 The three lines below are the executor's STANDING contract, identical on
 every call — claude/agents/machinery-executor.md carries them, so the
 lean prompt omits them (#1014).
```

## globPat — a `case` pattern matching any line CONTAINING `sub`. The lit
<a id="globpat-a-case-pattern-matching-any-line-containing-sub"></a>

```text
 globPat — a `case` pattern matching any line CONTAINING `sub`. The literal is
 single-quoted (via sq) so the shell never glob-expands the JSON punctuation.
```

## batchCommand — join the steps into ONE shell script: run, echo, gate, 
<a id="batchcommand-join-the-steps-into-one-shell-script-run-e"></a>

```text
 batchCommand — join the steps into ONE shell script: run, echo, gate, repeat.
 Each command's stdout is captured with `$( … )` (stderr flows through to the
 executor's transcript untouched, as before) and echoed verbatim, so the
 machinery's own "single JSON line" contract is preserved per step.
```

## temperloop#1071: every step runs under the workflow's wall-clock ceili
<a id="temperloop-1071-every-step-runs-under-the-workflow-s-wa"></a>

```text
 temperloop#1071: every step runs under the workflow's wall-clock ceiling, and
 the batch path DOES carry the STEP_SLOW advisory (its schema is an ARRAY of
 objects, so an extra notice line has somewhere to go — runMachineryBatch
 partitions it back out before the driver ever indexes a step).
```

## Lean vs full prompt: see machineryAgent() above (#1014). The two #72 f
<a id="lean-vs-full-prompt-see-machineryagent-above-1014-the-t"></a>

```text
 Lean vs full prompt: see machineryAgent() above (#1014). The two #72 framing
 lines and the `Steps:` manifest stay on BOTH paths — the classifier reads
 the prompt, and the manifest is per-call, not standing contract.
```

## temperloop#115 rationale, applied per batch: for a legitimately
<a id="temperloop-115-rationale-applied-per-batch-for-a-legiti"></a>

```text
 temperloop#115 rationale, applied per batch: for a legitimately
 long-running sequence raise the Bash TOOL's timeout parameter — NOT the
 command text — so the executor does not kill it at the default 2 minutes.
```

## Worker prompt assembly (3c).
<a id="worker-prompt-assembly-3c"></a>

```text
 -----------------------------------------------------------------------------
 Worker prompt assembly (3c).
 -----------------------------------------------------------------------------
 acceptanceList — `acceptance` may be an array of bullets (the /build plan
 path) OR a single string (/sweep passes one string) — normalize to an array
 (#437). Shared by workerPrompt and the #939 recovery record, so the criteria
 a recovered record marks UNVERIFIED are exactly the ones the worker was given.
```

## principlesSection — the §3c "effective engineering principles" block
<a id="principlessection-the-3c-effective-engineering-principles-bl"></a>

```text
 principlesSection — the §3c "effective engineering principles" block
 (temperloop#1432), a SELF-CONTAINED section appended once into
 workerPrompt()'s array (below) rather than threaded through existing
 lines, so a sibling edit to workerPrompt() (e.g. #1319) rebases cleanly on
 this one. Embeds the orchestrator-resolved (or, on the degraded path,
 static-fallback) summary verbatim — this file never re-derives the merge
 itself (see the PRINCIPLES_* block above for why it can't).
```

## discriminationEvidenceSection — the §3c "test-discrimination evidence"
<a id="discriminationevidencesection-the-3c-test-discrimination-evi"></a>

```text
 discriminationEvidenceSection — the §3c "test-discrimination evidence"
 requirement (temperloop#1319), a SELF-CONTAINED section appended once into
 workerPrompt()'s array, mirroring principlesSection()'s shape so a sibling
 edit to workerPrompt() rebases cleanly. Gated on REQUIRE_DISCRIMINATION_
 EVIDENCE (see that constant's own comment above for the full rationale,
 including the correction on why /sweep and /fix are excluded — an
 operational scope decision, not a structural one) — returns an EMPTY
 array, not a degraded/notice variant, when the caller didn't ask for it:
 unlike principlesSummaries' "never silence" rule, an unrequired discipline
 staying silent is correct here, since REQUIRE_DISCRIMINATION_EVIDENCE is
 false for any caller that never armed the requirement in the first place.
```

## gateRegistrationChecklistSection — the §3c "new gate script? register 
<a id="gateregistrationchecklistsection-the-3c-new-gate-script-regi"></a>

```text
 gateRegistrationChecklistSection — the §3c "new gate script? register it"
 checklist (temperloop#1931), a SELF-CONTAINED section appended once into
 workerPrompt()'s array, mirroring discriminationEvidenceSection()'s shape.
 UNGATED, like hostConfigDeferralSection() — every /build, /sweep and /fix
 worker can add a new check-*.sh/validate-*.sh/test_*.sh, so every worker
 needs the checklist, not just an opted-in caller.

 WHY THIS EXISTS: #1931's observed instance — three of five workers in one
 /build level shipped a new validator/test that went RED on
 validate-check-surface-degenerate-coverage.sh (and its test), and two also
 missed gate-paths.tsv/setting-registry.tsv rows, because the worker's own
 `--scoped` run (temperloop#957) selects gates by DIFF PATH: a brand-new
 script's path matched no row in gate-paths.tsv until the worker itself
 registered one, so the very gates that would have caught the omission
 never ran worker-side — each miss cost a full parent-side sliced
 acceptance-gate round trip (about 10-20 minutes). gate-paths.tsv now also
 carries generic new-surface globs closing the SELECTION half of that gap
 (see its own header, temperloop#1931) — this section is the PREVENTION
 half: naming the registries up front so the worker registers before its
 own scoped run ever needs to catch the omission after the fact.
```

## activationProofSection — the temperloop#1934 "show the worker its own
<a id="activationproofsection-the-temperloop-1934-show-the-worker-i"></a>

```text
 activationProofSection — the temperloop#1934 "show the worker its own
 class-A activation predicate" section, a SELF-CONTAINED section appended
 once into workerPrompt()'s array, mirroring gateRegistrationChecklistSection()'s
 shape so a sibling edit to workerPrompt() rebases cleanly. Gated on
 activationClass(item) === 'A' (defined below — hoisted, so the forward
 reference from here is fine): an absent `activation` block, or a class
 B/C block, renders NOTHING, so this section changes zero bytes of the
 prompt for those items (the acceptance's byte-identical requirement).

 WHY THIS EXISTS: the live instance (epic #1910, item join-key-registry) —
 the worker built and wired `join-keys-lib.sh`, but the plan's `proof:`
 predicate grepped for the producer-chosen literal `join_keys`, a name the
 worker never saw and had no reason to preserve. The worker's own
 acceptance bullets all passed; §3e.6 then failed the whole item on a name
 mismatch the worker was never shown, costing a full re-drive round trip.
 Rendering the `proof:` command VERBATIM — not a paraphrase of what it
 checks — lets the worker see the exact reachability surface the
 orchestrator will run and either name its own artifacts to match, or, if
 the predicate genuinely conflicts with the acceptance bullets, say so
 (`blocked`) instead of guessing a silent rename that may or may not agree
 with what §3e.6 actually runs.
```

## parentSummarySection — the epic #1847 Produces #7 companion: injects t
<a id="parentsummarysection-the-epic-1847-produces-7-companion-inje"></a>

```text
 parentSummarySection — the epic #1847 Produces #7 companion: injects the
 parent epic's own "group summary" into an admitted epic member's worker
 prompt, a SELF-CONTAINED section appended once into workerPrompt()'s
 array, mirroring changelogFragmentSection()'s shape so a sibling edit to
 workerPrompt() rebases cleanly. Gated on `item.parentSummary` — set ONLY
 by /sweep's Step 3 items[] construction for a member it admitted via Step
 1 item 6 (Operational-epic member admission); a plain singleton, and every
 /build plan item, never carries the field, so this returns an empty array
 and the section is silently absent. Unlike principlesSection()'s DEGRADED
 notice, there is no "missing" case to flag here: an item with no parent
 epic genuinely has no group summary to inject, so silence is correct, not
 a degradation.
```

## THE WORKER GATE SENTINEL — a RESULT artifact, not a process (temperloo
<a id="the-worker-gate-sentinel-a-result-artifact-not-a-process-tem"></a>

```text
 -----------------------------------------------------------------------------
 THE WORKER GATE SENTINEL — a RESULT artifact, not a process (temperloop#865).
 -----------------------------------------------------------------------------
 Both Level-1 workers of epic #810 backgrounded `scripts/quality-gates.sh`,
 then polled for a PID to exit instead of reading the run's result, and ended
 their turn with no verdict. 2/2 — AGAINST A PROMPT THAT NAMED THE EXACT
 FAILURE AND PRESCRIBED THE FIX, and one of them re-stalled after being told in
 so many words to go read the output file. The issue's own acceptance forbids
 the obvious response: "demonstrated by whatever mechanism is chosen, not by a
 re-worded warning". A third wording is not a fix; this is kernel principle 5
 (counter AI failure modes STRUCTURALLY) applied to the engine's own seam.

 So THREE structural changes replace the warning:

  1. THE WORKER NO LONGER COMPOSES ITS OWN GATE INVOCATION. workerGateCmd()
     below is built by the orchestrator and handed over verbatim, so the shape
     of the run is not a choice the worker makes turn by turn.
  2. THAT INVOCATION ALWAYS LEAVES A RESULT. It writes `{"state":"running"}`
     before the suite starts and overwrites it with
     `{"state":"finished","rc":N,"elapsedSecs":S}` when the suite ends, then
     prints the sentinel as its final line. A worker that loses the tool output
     — backgrounded, reaped, timed out — polls the FILE and gets a verdict. A
     PID poll cannot ever succeed (the exit status is gone with the process,
     and a subagent receives no background-task notification at all); an
     ARTIFACT poll can. That is the issue's candidate 2, and candidate 1's
     "hand the worker an invocation" half.
  3. THE RESIDUAL FAILURE IS LOUD. The parent-side 3e.5 gate command classifies
     this same file from the same worktree and reports `workerGate` on its own
     outcome, so the driver logs a NAMED notice when the sentinel still reads
     `running`. Today "waiting for the gate" is indistinguishable from a
     healthy long gate until the budget is gone; after this, a stalled worker
     reads differently from a slow one in the run log and in the gate payload.

 NOT IN SCOPE (recorded, deliberately not implemented): the issue's candidate 3
 — move the gate out of the worker entirely. It is an architectural subtraction
 touching every worker on every run and must not ride a five-defect PR.

 WHY /tmp, NOT THE WORKTREE. It mirrors the 3e.5 gate's own `/tmp/qg-<slug>.log`
 convention, and it keeps a machine-written file out of the tree `pr.sh rebase`
 and the leak guard inspect — an untracked artifact inside the worktree would
 need a matching `info/exclude` entry in worktree.sh, which is outside this
 item's scope and would make the fix a cross-script change.
```

## workerGateState — the sentinel classification the 3e.5 gate reported, 
<a id="workergatestate-the-sentinel-classification-the-3e-5-gate-re"></a>

```text
 workerGateState — the sentinel classification the 3e.5 gate reported, or
 'absent'. An older vendored path, a spike, or a worker that legitimately ran
 no gate all read 'absent', which is deliberately NOT a warning: the prompt
 itself permits "if you cannot cheaply tell which gates apply, run none and
 say so". Only `running` (started, never finished) and `unknown` (a sentinel
 with no state) mean something went wrong.
```

## workerGateCmd — the ONE invocation the worker is handed. Foreground by
<a id="workergatecmd-the-one-invocation-the-worker-is-handed-foregr"></a>

```text
 workerGateCmd — the ONE invocation the worker is handed. Foreground by
 construction (it ends by printing its own result), always-sentinel-writing by
 construction (both the `running` and the `finished` writes are unconditional
 steps of the same command line), and it exits with the gate's own status so a
 worker that only reads the exit code still gets the truth.

 `set -o pipefail` is load-bearing for the same reason it is in gateCmd
 (temperloop#68): the suite is piped through `tee`, and without it `$?` would
 be tee's 0 and a RED gate would write `"rc":0` into the sentinel — a silent
 green, which is the single worst thing this artifact could do. The exit status
 is read as a bare `$?`, never PIPESTATUS[0], which expands empty under the zsh
 this harness's Bash tool actually runs (temperloop#801).

 EVERY PROLOGUE STEP HARD-REFUSES; NONE OF THEM IS `&&`-CHAINED INTO THE RUN
 (review round 2, the HIGH). `A && B && C; D` is NOT a guard: it skips `B..C`
 on `A`'s failure and then runs `D` anyway. That shape — which this function
 shipped in its first cut — meant a failed `cd` (worktree pruned, moved, or an
 unresolvable path) skipped both the `running` sentinel AND `set -o pipefail`
 and then ran `./scripts/quality-gates.sh` in whatever directory the worker's
 shell happened to start in, recording a RED suite in the WRONG repo as
 `{"state":"finished","rc":0}` with a nonsense `elapsedSecs` (`__t0` unset, so
 the arithmetic read it as 0). That is precisely the silent green the comment
 above calls the worst thing this artifact could do, reintroduced by the fix
 for it. So each prologue step is now its own statement ending in an explicit
 `|| exit`, and `set -o pipefail` comes FIRST — before anything it protects —
 rather than being `&&`-chained after work that has already happened:

   - `set -o pipefail || exit 1` — a shell without pipefail refuses here. A
     POSIX special builtin's failure exits a non-interactive shell outright
     (dash), and the `|| exit 1` catches the lenient shells that merely return
     non-zero. Either way nothing downstream runs unprotected.
   - `[ -x ./scripts/quality-gates.sh ] || exit 127` — "this repo has no gate"
     refuses BEFORE any sentinel is written, so `absent` (never `finished`)
     is what both the worker and §3e.5 see. Before this, a missing script ran
     as an ENOENT through the pipe and the NEXT statement wrote
     `{"state":"finished","rc":127}` unconditionally — which the handed prompt
     then told the worker to report as "a real FAIL", turning a repo with no
     gate into a gate failure (review round 2, the MEDIUM).
   - `cd … || exit 1` and the `running` write's own `|| exit 1` — the suite
     can never run outside the worktree, and can never run with no artifact to
     poll.

 The invariant to preserve on any future edit: a `finished` sentinel is
 reachable ONLY after the suite actually ran, in the worktree, under pipefail.
```

## workerGateSection — the prompt half, a SELF-CONTAINED section spliced 
<a id="workergatesection-the-prompt-half-a-self-contained-section-s"></a>

```text
 workerGateSection — the prompt half, a SELF-CONTAINED section spliced into
 workerPrompt()'s array (the same shape principlesSection() /
 changelogFragmentSection() use) so a sibling edit to workerPrompt rebases
 cleanly on this one. It does not re-warn: it hands over the command and names
 the artifact to poll.
```

## #1072 — the near-miss this institutionalizes: a build worker (temperlo
<a id="1072-the-near-miss-this-institutionalizes-a-build-worker-tem"></a>

```text
 #1072 — the near-miss this institutionalizes: a build worker (temperloop#635)
 spawned a context-inheriting fork for a narrow read-only sub-task; the fork
 INHERITED the "drive to done and commit" mission, fabricated a completion
 report, and committed to the shared worktree (self-recovered — see
 Mistakes/foundation - research fork inherits drive-to-done context and
 commits to shared worktree). Embedded here, structurally, rather than left
 to a vault note someone has to remember to re-paste — mirrors how the
 foreground-only contract below is embedded rather than left to prose alone.
```

## §3c "No long-running background work" (#1219). Embedded in the generat
<a id="3c-no-long-running-background-work-1219-embedded-in-the-gene"></a>

```text
 §3c "No long-running background work" (#1219). Embedded in the generated
 prompt — NOT left to prose the caller may forget — so every worker (main
 AND spike, both route through workerPrompt) is told up front to foreground
 the gate. Without this the worker backgrounds quality-gates.sh, yields, and
 returns no verdict (build.md §3c/§3d must stay in lockstep with this block).

 temperloop#997 adds the SCOPE half of the same contract: the worker must not
 run the BARE, repo-wide suite in its own context at all. That run is minutes-
 scale, and one blocking turn that long blows the ~5-min prompt-cache TTL — the
 worker's whole ~213K-token context is then re-WRITTEN (weight 1.25) instead of
 re-READ (0.1) on the next call. The ACCEPTANCE run stays parent-side at 3e.5
 (unchanged, still the authority — the PR #309 silent-red lesson; since
 temperloop#1663 that run is itself diff-scoped through the same map, which
 changes WHICH gates it runs but not WHO decides acceptance). The two
 halves live in ONE section on purpose: foreground-only governs HOW the worker
 runs its checks, #997 governs WHICH checks it runs, and dropping either one
 re-opens a measured defect. build.md §3c carries both in lockstep.
```

## temperloop#1182 — the OTHER thing a worker structurally cannot verify.
<a id="temperloop-1182-the-other-thing-a-worker-structurally-cannot"></a>

```text
 temperloop#1182 — the OTHER thing a worker structurally cannot verify.
 Deliberately its own section, not a bullet inside the block above: that
 block is about the COST of a check (minutes-scale, cache-TTL); this one
 is about a check that cannot produce a meaningful reading here at all,
 and whose "helpful" resolution leaks a secret. Ungated — see the
 function's own comment. build.md §3c carries the prose half in lockstep.
```

## ## Output shape (temperloop#1080) — the SIZE half of the return contra
<a id="output-shape-temperloop-1080-the-size-half-of-the-return-con"></a>

```text
 ## Output shape (temperloop#1080) — the SIZE half of the return contract.
 The schema below fixes the shape; nothing fixed the length, and measured
 across 83 real worker verdicts the two prose slots ran 2-4x past what the
 spec asked for. Stated as an explicit bound here — the one surface the
 worker actually reads — with the routing rule that makes the bound safe:
 detail goes to the verification-surface FILE, which reaches the PR body
 without entering orchestrator context. build.md §3c carries the same
 contract; the two must stay in lockstep (static guard in test_workflow.sh).
```

## FOREGROUND_CURE (#1219) — appended to the ONE null-verdict re-spawn so
<a id="foreground-cure-1219-appended-to-the-one-null-verdict-re-spa"></a>

```text
 FOREGROUND_CURE (#1219) — appended to the ONE null-verdict re-spawn so the
 retry prompt DIFFERS from the first attempt (a byte-identical retry re-stalls
 identically). Names the failure explicitly; the workerPrompt foreground block
 above is prevention, this is the backstop cure. build.md §3d must stay in
 lockstep. Kept as its own section so the test can assert its presence.
 Carries the #997 scope half too: the cure must not re-issue the very directive
 (a bare repo-wide gate run) the prevention block just removed.
```

## GATE_SENTINEL_CURE (temperloop#865) — the re-spawn's RECOVERY half, an
<a id="gate-sentinel-cure-temperloop-865-the-re-spawn-s-recovery-ha"></a>

```text
 GATE_SENTINEL_CURE (temperloop#865) — the re-spawn's RECOVERY half, and the
 reason the cure is no longer prose alone. The #865 incident's second worker
 re-stalled after being told, in words, to go read the output file; there was
 no machine-readable file to read. Now there is, at a known path, so the cure
 hands over the path and the three states rather than repeating the
 instruction. If the previous attempt's gate in fact FINISHED, the re-spawn
 reads its verdict off the sentinel instead of paying for the suite twice.
```

## Lost-return recovery (temperloop#939).
<a id="lost-return-recovery-temperloop-939"></a>

```text
 -----------------------------------------------------------------------------
 Lost-return recovery (temperloop#939).
 -----------------------------------------------------------------------------
 The 3c worker can die in TWO different ways that look identical from here:
   (a) it genuinely failed — nothing was built, and escalating is correct;
   (b) it did the whole job and only the RETURN CHANNEL failed — the subagent
       completed without calling StructuredOutput, or blew the StructuredOutput
       retry cap, so `agent({schema})` THROWS (it does not return null).
 Case (b) is not hypothetical: in the #939 run it hit 2 of 5 workers. One had
 committed, pushed, opened PR #936 and gone green; the other had committed but
 not pushed. Both were reported as `worker-error` — a `ask-now` halt over work
 that had already landed, with a live risk of re-spawning a worker onto a
 worktree that already held the finished commit (a second PR, a stacked commit).

 The fix is to STOP GUESSING from the exception and go LOOK: probe the
 observable side-effects (commit / push / PR) before classifying. What we can
 never recover is the worker's own self-verification — so a recovered record is
 honest about that and marks its acceptance results UNVERIFIED rather than
 letting them read as passing.
```

## Worker cost capture (temperloop#2065, epic #2062's dual-build ledger).
<a id="worker-cost-capture-temperloop-2065-epic-2062-s-dual-build-l"></a>

```text
 -----------------------------------------------------------------------------
 Worker cost capture (temperloop#2065, epic #2062's dual-build ledger).
 -----------------------------------------------------------------------------
 The worker `agent()` spawn is the Workflow runtime's own subagent primitive:
 it returns no usage envelope, and the runtime has no timer (`Date.now()`
 throws — see the STEP CEILING block, DESIGN NOTE 1's sibling). Both gaps
 are closed the SAME way every other shell-only fact this file needs is:
 an emitted-shell machinery call (DESIGN NOTE 1's runMachinery bridge).
 workflows/scripts/build/worker-usage.sh is that bridge — the SAME pattern
 review-wait.sh established for giving this runtime a wall-clock tick it
 otherwise has none of (temperloop#2049).

   workerClockNow()  — a bare `date` read, no side effect. Returns epoch
                       SECONDS (a plain number — safe to subtract, since
                       only Date.now()/Math.random() throw here, never
                       arithmetic on a value already in hand) or null on
                       anything but a clean numeric reading.
   workerUsageEmit() — the SAME reading PLUS the durable per-seat
                       attribution write: model-usage-envelope.sh's shared
                       model_usage_emit_from_envelope, seat "build-worker" —
                       the SAME helper pipeline-drive.sh's A7/A8 and
                       pipeline-retro-judge-spawn.sh's A9 already call, so
                       the build worker joins their attribution stream as a
                       FOURTH emitting seat (ADR 0026) — the coverage
                       denominator in report-producers/model-comparison
                       names it. No `claude -p --output-format json`
                       envelope exists for a Workflow agent() call, so this
                       degrades to usage_source:"unavailable" (no tokens) on
                       every REAL call today — worker-usage.sh's own header
                       carries that honesty disclosure; the fields still
                       flow through byte-for-byte the day a real envelope
                       becomes available, and the offline test harness
                       exercises exactly that path.

 Both are FAIL-OPEN and never escalate: a cost-ledger entry must never be
 the thing that stalls a build. A malformed/absent reading degrades to
 null, never a thrown error or a denial.
```

## numOrNull — coerce to a finite number, or null. Guards the JS `Number(
<a id="numornull-coerce-to-a-finite-number-or-null-guards-the-js-nu"></a>

```text
 numOrNull — coerce to a finite number, or null. Guards the JS `Number(null)
 === 0` / `Number(undefined) === NaN` quirks explicitly rather than relying
 on Number.isFinite() to catch the first one (it would not: 0 IS finite) —
 a machinery field that is genuinely absent (usage_source:"unavailable"'s
 null input_tokens/output_tokens) must degrade to null, never a false zero.
```

## temperloop#2065 review round 1 [LOW]: Number('') === 0 and
<a id="temperloop-2065-review-round-1-low-number-0-and"></a>

```text
 temperloop#2065 review round 1 [LOW]: Number('') === 0 and
 Number('   ') === 0 are both finite, so an empty/whitespace string would
 otherwise manufacture a false zero instead of degrading to null — the
 exact failure mode this function exists to prevent (epoch_s is
 schema-typed as string|number; a future envelope wiring could emit one).
```

## USAGE_UNAVAILABLE — the degraded reading every workerUsageEmit() CALL 
<a id="usage-unavailable-the-degraded-reading-every-workerusageemit"></a>

```text
 USAGE_UNAVAILABLE — the degraded reading every workerUsageEmit() CALL SITE
 falls back to when the call itself throws (see the guards below). Distinct
 from workerUsageEmit()'s own internal "malformed response" null-collapse
 (numOrNull()) — this is the "the machinery invocation never completed at
 all" arm.
```

## temperloop#2065 review round 2 [HIGH]: workerClockNow()/workerUsageEmi
<a id="temperloop-2065-review-round-2-high-workerclocknow-workerusa"></a>

```text
 temperloop#2065 review round 2 [HIGH]: workerClockNow()/workerUsageEmit()
 both bottom out in runMachinery() -> machineryAgent(), which explicitly
 re-throws (does not degrade) an unresolvable-agentType / StructuredOutput-
 absent / retry-cap-exceeded executor spawn — the exact throw shape
 callWorker()'s own agent({schema}) call is documented as capable of, two
 blocks below. The block comment above these two functions promises they
 are FAIL-OPEN and "never a thrown error" — that promise covers only a
 malformed VALUE in a successful response (numOrNull()'s job); it does not
 cover the underlying machinery spawn itself throwing. These two guards are
 what backs the promise with code: every call site below goes through one
 of these instead of calling workerClockNow()/workerUsageEmit() bare, so a
 cost-ledger bookkeeping failure can never abort the item build it is only
 supposed to be measuring.
```

## mergeWorkerCost — accumulate a SECOND callWorker() reading onto the fi
<a id="mergeworkercost-accumulate-a-second-callworker-reading-onto-"></a>

```text
 mergeWorkerCost — accumulate a SECOND callWorker() reading onto the first
 (the temperloop#993/#1219 no-verdict foreground-cure retry re-spawns the
 SAME worker for the SAME item, so its cost is additive, not a replacement).
 A field stays null only when BOTH readings are null — one real reading
 plus one degraded (null) reading reports the real one, never manufacturing
 a false total by treating a missing edge as zero.
```

## callWorker — spawn the implementation worker so a lost return channel 
<a id="callworker-spawn-the-implementation-worker-so-a-lost-return-"></a>

```text
 callWorker — spawn the implementation worker so a lost return channel can
 never escape as a throw. agent({schema}) THROWS on a StructuredOutput-absent
 / retry-cap-exceeded subagent and returns null on a skip / terminal API error;
 both are the same thing to the caller ("no verdict"), and neither is evidence
 about the work. Normalize both into { verdict, error } so driveItem decides
 what they MEAN only after the side-effect probe has run.
 `phaseName` (temperloop#1294) — the STAGE group this worker belongs to,
 passed explicitly (the global phase() cursor races under parallel()).

 temperloop#2065 — every call also brackets the worker in the clock/usage
 seam above and returns its reading as { wallClockMs, tokensIn, tokensOut },
 on BOTH the return and the throw arm: a re-spawned worker that itself
 blows its return channel still spent real tokens, and the ledger records
 that spend rather than silently dropping it.
```

## temperloop#982: item.model || undefined, NOT bare item.model — an
<a id="temperloop-982-item-model-undefined-not-bare-item-model-an"></a>

```text
 temperloop#982: item.model || undefined, NOT bare item.model — an
 empty-string item.model (e.g. an orchestrator that resolved
 SWEEP_WORKER_MODEL/FIX_WORKER_MODEL to "" and passed it through
 unfiltered) must collapse to undefined here, the sentinel the agent()
 hook reads as "inherit session model" — a bare "" would instead be
 sent as a literal (invalid) model name. undefined/absent item.model
 already coerces to undefined via `||`, so this is a strict
 widening (covers "" too), never a behavior change for the existing
 undefined case.
```

## Not landed — but temperloop#993 splits this bucket. RECOVER_DIRTY mean
<a id="not-landed-but-temperloop-993-splits-this-bucket-recover-dir"></a>

```text
 Not landed — but temperloop#993 splits this bucket. RECOVER_DIRTY means the
 worker left uncommitted work behind (the backgrounded-gate stall); the
 caller resumes it on this worktree with the dirty-resume cure instead of
 treating it like a worker that touched nothing. A denied/ERROR probe
 reports neither flag and falls through to the unchanged escalation.
```

## Step-liveness disposal (temperloop#1071).
<a id="step-liveness-disposal-temperloop-1071"></a>

```text
 -----------------------------------------------------------------------------
 Step-liveness disposal (temperloop#1071).
 -----------------------------------------------------------------------------
 timedOutStep — the first STEP_TIMEOUT in a batch's results, or null. A batch
 stops at the timed-out step (both `case` gate forms treat STEP_TIMEOUT as a
 stop), so there is at most one.
```

## isVerdictUnparseable — the pr-open outcome temperloop#1805 is about: p
<a id="isverdictunparseable-the-pr-open-outcome-temperloop-1805-is-"></a>

```text
 isVerdictUnparseable — the pr-open outcome temperloop#1805 is about: pr.sh's
 own `die` when the verdict file it was handed is not usable JSON. It is
 deliberately NARROW — three literal messages pr.sh emits about the VERDICT
 (`open`'s `jq -e .` guard, and assemble_body's two field checks) — because the
 tolerance path below re-issues the PR-open command, and a blind re-issue of a
 non-idempotent machinery step on any broader class is exactly the double-open
 hazard the rest of this file is built to avoid. Anything else — a `gh` failure,
 a push race, a missing surface file — keeps the unchanged escalation.
```

## recoverLostReturn — the 3f push/pr-open twin of disposeStepTimeout's p
<a id="recoverlostreturn-the-3f-push-pr-open-twin-of-disposesteptim"></a>

```text
 recoverLostReturn — the 3f push/pr-open twin of disposeStepTimeout's probe,
 for the NON-timeout case: a pr-batch step's own JSON line was dropped (lost
 pr-batch return) with every step before it in the SAME batch already
 confirmed successful (the caller only reaches this after its own
 rebase/scan/push branches above already passed) — temperloop#1067, distinct
 from #1071's liveness-kill. Reuses the EXISTING probeSideEffects/RECOVER_*
 ladder — no second probe, no new machinery. Returns one of:
   { kind: 'adopted', pr, pushedSha }   — landed; caller skips re-push/re-open
   { kind: 'escalate', escKind, payload } — a resume attempt itself failed
   { kind: 'none' }                      — RECOVER_NONE/RECOVER_DIRTY/unusable
                                            probe; caller does its UNCHANGED
                                            escalation exactly as before this
                                            wiring existed.
```

## `--allow-rewrite` for the same reason 3f-1 carries it (temperloop#2103
<a id="allow-rewrite-for-the-same-reason-3f-1-carries-it-temperloop"></a>

```text
 `--allow-rewrite` for the same reason 3f-1 carries it (temperloop#2103):
 the lost batch already ran 3f-0a's rebase, so this resumed push may be
 of a rewritten history over a branch an earlier round put on origin.
 pr.sh downgrades it to a plain push unless the rewrite is genuine, and
 leases it against a value it read when it is.
```

## `resumedSha` starts at the probe's own reading (correct for the
<a id="resumedsha-starts-at-the-probe-s-own-reading-correct-for-the"></a>

```text
 `resumedSha` starts at the probe's own reading (correct for the
 RECOVER_PUSHED case, which resumes at pr-open only — nothing pushes
 again) and is overwritten by the RESUMED push's own sha when
 RECOVER_COMMITTED actually re-runs push — the freshest ground truth, not
 the pre-resume probe reading.
```

## recoveredVerdict — reconstruct the verdict object the worker never ret
<a id="recoveredverdict-reconstruct-the-verdict-object-the-worker-n"></a>

```text
 recoveredVerdict — reconstruct the verdict object the worker never returned,
 from ground truth plus an explicit UNVERIFIED marker on every acceptance
 criterion. Deliberately carries NO `passed` key: pr.sh renders each result as
 `- [ ]` (unchecked) and driveItem's `passed === false` check does not trip, so
 the item flows on WITHOUT ever being reported as passing. The synthesized
 `verification_surface` is the fallback for a worker that died before writing
 `.build-verification.md` (pr.sh's `open` prefers the real file when one exists).
```

## escalationRoundKind(kind) — the ROUND_KIND VOCABULARY (temperloop#2135
<a id="escalationroundkind-kind-the-round-kind-vocabulary-temperloo"></a>

```text
 escalationRoundKind(kind) — the ROUND_KIND VOCABULARY (temperloop#2135,
 split from #2130). Every escalation starts a build ROUND that will be
 revisited — by a human at the merge gate, by the orchestrator's own
 continuation logic, or by a re-spawned worker — and a retrospective needs
 to tell a MACHINERY round (the gate ran out of budget, CI failed,
 activation's own proof checks failed) from a REVIEW round (a reviewer
 found something) without reading every PR body by hand (the motivating
 evidence in #2130: 4 of 9 same-epic PRs' `-r2`/`-r3` rounds were machinery
 continuations that changed nothing).

 THIS IS THE ONE PLACE THE MAPPING IS STATED. Every one of this file's
 escalate() call sites — ~51 of them, spanning ~30 distinct kind strings —
 funnels through escalate() below, so no call site classifies its own kind
 by hand and none can drift from this table. The closed set is deliberately
 SMALL: `review | gate-timeout | gate-fail | activation | ci | other`. The
 ~25 singleton kinds (`rebase-conflict`, `push-rejected`, `dual-build-*`,
 `claim-conflict`, `dep-not-merged`, `verdict-unparseable`, `worker-error`,
 `stale-worktree`, `quota-exhausted`, a worker's own returned `.status`, …)
 are DELIBERATELY not enumerated one by one — they fall through to `other`
 by construction, which is what keeps this classifier bounded: a NEW
 escalate() kind added later needs no edit here to stay correctly (if
 coarsely) classified, and the catch-all never silently mis-labels a new
 machinery kind as `review` or vice versa.
```

## "the CI-failure kinds" (temperloop#2135's own acceptance language) are
<a id="the-ci-failure-kinds-temperloop-2135-s-own-acceptance-langua"></a>

```text
 "the CI-failure kinds" (temperloop#2135's own acceptance language) are
 every kind ciPollLoop/the 3g CI-poll seam emits: ci-failed and the
 argument-validation refusal ci-poll-bad-argument both start with `ci-`.
 `merge-conflict` (also from ciPollLoop) is deliberately EXCLUDED — it is
 a PR mergeability fact, not a CI verdict, so it falls to `other`.
```

## The SIDELINE notice — the consumer half of worktree.sh's CREATED verdi
<a id="the-sideline-notice-the-consumer-half-of-worktree-sh-s-creat"></a>

```text
 -----------------------------------------------------------------------------
 The SIDELINE notice — the consumer half of worktree.sh's CREATED verdict
 (temperloop#2006).
 -----------------------------------------------------------------------------
 `worktree.sh create` must NEVER refuse (its own contract at worktree.sh:783-787
 — a refusing create turns /build's prelude batch from CREATED into escalated),
 so when the deterministic path is already occupied by committed work that
 preservation could not capture, it SIDELINES: the occupant is MOVED — never
 copied, never removed — to `<path>.unpreserved-<sha8>` on branch
 `<branch>.unpreserved-<sha8>`, which frees the path so create still CREATES.
 It already REPORTS that, as fields on the CREATED line it was always going to
 print: `sidelined` / `sidelined_path` / `sidelined_branch`.

 This driver used to DROP all three. That is the whole of the defect #2006
 names: an intact, committed, reviewed build gets shelved while a fresh worker
 rebuilds the same item from scratch, and nothing reports it — not because the
 information is missing, but because nobody read it. The cost is a wasted
 re-drive plus an orphaned worktree nobody knows to reclaim, and it silently
 defeats the point of temperloop#1988's preserve-the-build fix.

 WHY THE CONSUMER LIVES HERE, below the drivers. The "is there a commit ahead
 of base at the deterministic path?" reading is the same fact /fix's Step 4a
 worktree state table reasons about in prose. /build and /sweep have no such
 table: they invoke this file on its normal `fresh` route (no onlySlugs, no
 verdicts) and reach `worktree.sh create` through the prelude batch below. A
 guard that lives in one driver's prose holds only for that driver — the
 per-instance-fix smell the kernel names ("hoist the mechanism rather than
 patch the instance, or you re-patch every sibling in turn"). Putting the
 consumer in the ONE file all three drivers route through is what lets /build
 and /sweep inherit what /fix has without any of them restating the rule.

 NOTHING here touches worktree.sh. `create` still never refuses, still
 sidelines rather than destroys, and still emits the identical CREATED line;
 this is purely the reading half that was missing.

 Keyed by slug rather than threaded through driveItem's ~30 return points:
 the notice is discovered at 3b and must ride whichever record the item
 eventually produces (parked OR escalation), which is exactly the shape
 preserveOnEscalation already solved with one choke point at the fan-out.
```

## sidelineRecoveryCmd — NAME THE RECOVERY, not merely the event. A sidel
<a id="sidelinerecoverycmd-name-the-recovery-not-merely-the-event-a"></a>

```text
 sidelineRecoveryCmd — NAME THE RECOVERY, not merely the event. A sidelined
 worktree is still a REGISTERED git worktree holding real commits (worktree.sh
 moves it with `git worktree move`, falling back to `mv` + `worktree repair`),
 so the concrete reclaim is: read what is in it, then get its branch somewhere
 durable before `worktree.sh prune`'s two-gate disposal owner ever reaches it.
 A sideline that could not carry the branch across reports an empty
 `sidelined_branch`; say so rather than emitting a command with an empty ref.
```

## stampSideline — the ONE choke point where the notice is attached to wh
<a id="stampsideline-the-one-choke-point-where-the-notice-is-attach"></a>

```text
 stampSideline — the ONE choke point where the notice is attached to whatever
 record this item produced, parked or escalation, so it survives the return to
 the orchestrator and reaches the merge gate rather than living only in a
 transient log line. Same placement (and same rationale) as
 preserveOnEscalation: one seam beats N call sites.
```

## preserveCommittedWorkCmd / preserveOnEscalation — temperloop#2020.
<a id="preservecommittedworkcmd-preserveonescalation-temperloop-202"></a>

```text
 -----------------------------------------------------------------------------
 preserveCommittedWorkCmd / preserveOnEscalation — temperloop#2020.
 -----------------------------------------------------------------------------
 THE DATA-LOSS SEAM. An escalation leaves the worktree intact, and every
 downstream spec says so — but "intact" is a promise about a LOCAL directory
 and a LOCAL `build/<slug>` branch, and the specs that dispose an escalated
 item are AI-executed prose. On Towheads/foundation (kernel v0.39.0, run
 wf_967c2878-0a7 driving foundation#1869) a §3e `review-diff-error` fired
 with the worker's work committed but un-pushed and un-PR'd; /fix's 4a
 escalation-park path then ran `worktree.sh remove`, taking the directory and
 the only branch pointing at those commits with it. 515 verified lines were
 hand-rescued from the parent session's transcript. fix.md's prose guard for
 exactly this hazard (its `FX.8 class:escalated-work-destruction` cite, and a
 worktree state table that permits removal on one row only) was already in
 place and did not hold — which is the whole argument for fixing it HERE:
 kernel principle 5, counter a known AI failure mode STRUCTURALLY rather than
 with more prose the next agent may also misread.

 So: before an escalation LEAVES this driver, any commit the worker made that
 is not yet on origin is PUSHED. After that, every destructive disposition a
 caller can take — `worktree.sh remove`, its `git branch -D`, a force-clearing
 `worktree.sh create` on a later run — destroys only a local copy of work that
 already exists on the remote. This protects callers whose escalation paths
 this file cannot see, which a fix in any one caller's prose cannot.

 Fail-soft in every direction, and deliberately so — this runs on a path that
 is ALREADY failing, and must never convert an escalation into a worse one:
 no worktree, no commits, a rejected push, a denied executor, a thrown
 machinery call — each returns the original escalation unchanged, annotated
 with what happened. The annotation is the point on the failing arm:
 WORK_PRESERVE_FAILED tells the operator disposing this escalation that the
 worktree IS the only copy.

 NOT a substitute for 3f: this pushes the BRANCH only — no PR, no CI, no
 rebase, no closing-keyword scan. A pushed branch with no PR merges into
 nothing; it is a durable copy, not a landing.

 `branch` is the PLAN's `item.branch` (`<type>/<slug>`), NOT the worktree's
 throwaway local `build/<slug>` HEAD (worktree.sh's own header). It has to be:
 3f pushes via `pr.sh push <wt> <item.branch>`, which sends
 `$sha:refs/heads/$branch` — so preserving `HEAD` under its LOCAL name would
 mint a SECOND remote ref (`build/<slug>`) on every post-3f escalation
 (ci-failed, gate-fail, review-blocking), one that no PR watches and that
 neither `delete_branch_on_merge` nor prune-merged-branches.sh can ever
 reclaim. That is precisely the two-ref split pr.sh's PUSHED_UNWATCHED logic
 (temperloop#1688) exists to make visible. Pushing the ref 3f already owns
 makes the idempotency claim below TRUE of what the code does, and leaves the
 rescue copy on a ref a human already has a handle for.
```

## NO `|| default=main` guess. worktree.sh's own default_branch() (its
<a id="no-default-main-guess-worktree-sh-s-own-default-branch-its"></a>

```text
 NO `|| default=main` guess. worktree.sh's own default_branch() (its
 "The repo's default branch" helper) `return 1`s rather than inventing a
 base, and this path must do the same, because the guess does not fail
 LOUDLY here — it fails into a rev-list that errors, `ahead` that reads 0
 and a WORK_PRESERVE_SKIP "no unlanded commits". Verified against a
 throwaway fixture (bare origin defaulting to `trunk`, origin/HEAD
 deleted, one real unpushed commit): the old chain emitted
 `{"outcome":"WORK_PRESERVE_SKIP","commits_ahead":0}` over real work. And
 because preserveOnEscalation logs its "the worktree may be the ONLY
 copy" warning on every outcome EXCEPT the skip, that false negative
 silenced the one warning this whole seam exists to raise.

 So: `base_resolved` splits "genuinely zero commits ahead" from "could
 not compute". Only the FIRST may skip. The second PUSHES ANYWAY —
 pushing is the fail-safe direction on a preservation path: the cost of a
 needless push is one ref on the branch 3f already owns, while the cost
 of a needless skip is the destroyed-work incident this file documents.
 `ahead` is normalized before it is ever read as a number, so nothing
 non-numeric can reach the unquoted `"commits_ahead":%s` position and
 make the line unparseable (the pr.sh `case` idiom, e.g. its cmd_push
 ahead-count normalization).
```

## `$branch` goes into the hand-built JSON below through a bare printf
<a id="branch-goes-into-the-hand-built-json-below-through-a-bare-pr"></a>

```text
 `$branch` goes into the hand-built JSON below through a bare printf
 `%s`, deliberately NOT through the `jq -R -s -c .` idiom reviewDiffCmd
 uses for tsv_lines/files. The reason it is safe here: this is the PLAN's
 `branch:` field, which plan-schema pins to `<type>/<slug>` with type in
 a closed set {feat,fix,chore,refactor,docs,test} and slug kebab-case
 ([a-z0-9-]+), validated at Step 1 — so it carries neither a double quote
 nor a backslash. Note what is NOT an argument: `git check-ref-format`
 bans a backslash in a ref name but ACCEPTS a double quote
 (`git check-ref-format 'refs/heads/build/a"b'` exits 0), and a double
 quote alone terminates a JSON string. The ref grammar is therefore not a
 JSON-safety guarantee; the plan schema is. Adding jq would also put a new
 binary dependency on the one path whose entire job is to work when things
 are already failing — the opposite of fail-soft.
 Nothing committed beyond a RESOLVED base — 3f never ran and never needed
 to. Pushing here would mint an empty remote branch for no benefit.
```

## temperloop#2103 — THE REBASED-BRANCH-ALREADY-ON-ORIGIN ARM.
<a id="temperloop-2103-the-rebased-branch-already-on-origin-arm"></a>

```text
 temperloop#2103 — THE REBASED-BRANCH-ALREADY-ON-ORIGIN ARM.

 The plain push below is right on the ordinary path and CANNOT work on the
 one that produced this issue three times in a single session: a
 continuation round whose branch an EARLIER round already pushed, which
 3f-0a then rebased onto a newer origin/<default>. The rewritten history
 does not contain the remote tip, so a plain push is a non-fast-forward by
 construction — not a transient — and the seam whose entire job is to make
 the work durable reported WORK_PRESERVE_FAILED over four commits that
 existed nowhere else.

 Three properties the arm below holds to, in this order:

   1. READ THE REMOTE VALUE FIRST. Nothing here ever issues a bare
      `--force`. The retry is `--force-with-lease=refs/heads/$branch:$sha`
      against the value `git ls-remote` just returned, so a concurrent
      writer that moved the ref in between gets a REJECTION, not a silent
      overwrite. An unreadable remote means no force at all.
   2. ONLY OVER WORK THE LOCAL HISTORY SUPERSEDES. This path runs
      unattended on an already-failing item and nobody ASKED it to rewrite
      anything (unlike 3f, which force-requests the rebase it just
      performed). So the force is gated on the operator's own manual
      recovery criterion from the issue — "after confirming the local
      history superseded the remote tip": every commit reachable from the
      remote tip but not from HEAD must have a patch-equivalent in HEAD
      (`rev-list --cherry-pick --right-only`, `git cherry`'s own test).
      Zero such commits ⇒ the remote holds a stale pre-rebase copy of
      exactly this work ⇒ overwriting it destroys nothing. Otherwise the
      remote carries commits this worktree does not, and the arm REFUSES
      and says so — a loud WORK_PRESERVE_FAILED naming the remote sha is
      recoverable; destroying someone else's commits is not.
   3. `preserved` IS READ BACK FROM ORIGIN, NEVER INFERRED FROM AN EXIT
      CODE. The third occurrence recorded the exact reason: a push from
      the same run HAD landed a pre-rebase state on origin while the field
      read false, so "the branch exists on origin" overstated and
      `preserved:false` understated. The final `ls-remote` below decides
      the outcome by comparing the remote value to this worktree's HEAD,
      and BOTH shas ride the record, so neither signal has to be trusted
      alone.

 Idempotent, and TRULY so: this pushes the same `refs/heads/$branch` 3f
 pushes, so when 3f already pushed this sha git reports "Everything
 up-to-date" and exits 0 — a post-3f escalation (a CI failure, say) costs
 one no-op push and reports WORK_PRESERVED truthfully, minting no second
 ref. No `-u`: this is a one-shot rescue push and has no business writing
 branch.<name>.remote/.merge into the worktree's config.

 Still no jq (the fail-soft argument above): every value interpolated into
 the JSON below is either the plan's validated `branch:`, a literal, or a
 40-hex sha normalized through the `case` guard before it is read.
```

## runReviewers — the §3e driver. Fetches the routing inputs (one machine
<a id="runreviewers-the-3e-driver-fetches-the-routing-inputs-one-ma"></a>

```text
 runReviewers — the §3e driver. Fetches the routing inputs (one machinery
 call), resolves the matching reviewer set, and spawns EACH directly via
 `agent({agentType})` — never delegated to the 3c worker. Every routed reviewer
 is spawned CONCURRENTLY and the whole fanout waits under one wall-clock
 ceiling (temperloop#2003, awaitReviewFanout), so one agent that never returns
 can neither block a later one from launching nor stall the level. Returns:
   { escalation }                                   — the diff fetch itself failed
   { summary, notes, blocking: [], ran, skipped }   — normal return (blocking may be non-empty)
 A THIRD shape (temperloop#2020) is a normal return, not a third branch: when
 the routing table does not survive the relay even after the one-shot retry,
 this returns the normal shape with one extra `skipped` degradation notice
 and `routing_degraded` carrying the gap payload — the drive continues to
 3e.5/3f with the skip notice on the PR body. A post-commit advisory pass
 that cannot route is a DEGRADATION, never a halt. The degradation is
 PARTIAL: only the table-dependent axes are withdrawn, so the mandatory
 command-doc route (foundation#1007), the `review:` override and the
 `kind: architectural` axis — all computed from `item`/`files`, never from
 the table — still route and still run, and `ran` is therefore NOT
 necessarily empty in this shape.
   { …the normal return, plus `escalation` }        — a MANDATORY reviewer hit
     the ceiling (temperloop#2003): the tally is still computed and returned,
     AND the item escalates `review-agent-timeout` rather than reading as if the
     mandatory gate had passed. Callers check `.escalation` first either way.
 `summary` is a short tally line for the PR body (criterion: the PR must
 carry real evidence of a real pass, never a guaranteed-skip default).
 `notes` (temperloop#1450) is the FULL findings text for every reviewer that
 ran, one `### <reviewer>` block each — a non-blocking (MEDIUM/LOW-only)
 review is still advisory OUTPUT, not silently discarded after the HIGH
 check. Empty string when nothing ran. Callers splice `notes` into a durable
 surface (the PR body, at the 3f call site) rather than letting it evaporate
 once the blocking check has read it.

 `round` (temperloop#1970) is this pass's 1-based round number for THIS item's
 worktree, durable across the escalate→re-invoke loop (see reviewDiffCmd). The
 two blocking call sites compare it against REVIEW_BLOCKING_MAX_ROUNDS.

 `priorFindingsText` (temperloop#2127, optional) — the PRIOR round's findings
 text, when the caller already has it. The ONLY caller that ever has this is
 driveItemBuildPhase's 3e call site on a `review-blocking` continuation: the
 orchestrator captured `findings: review.blocking` off THIS SAME escalation
 (see the `escalate(item.slug, 'review-blocking', …)` call below) and handed
 it back as `input.verdicts[item.slug].verdict_section` — the identical seam
 3c already reads for the worker's re-spawn prompt (driveItemBuildPhase's own
 `verdictSection`). This function never re-derives that text; it only decides
 WHETHER to use it (never on round 1 — see `priorContext` below) and hands it
 to reviewPrompt(). The CI-fix re-review call site (§3g) passes nothing: its
 round bump comes from the SAME shared per-worktree counter, but a round-1
 pass that reached CI-fix by definition had zero BLOCKING findings (that is
 why it was pushed), so there is nothing to carry forward there — and since
 round 2 that ABSENCE is itself load-bearing, not merely tolerated: it is what
 selects reviewContinuationSection()'s clean-prior-round premise instead of
 the false "round N found blocking finding(s)" one. Same for a continuation
 resuming from a non-`review-blocking` escalation kind, which the 3e call site
 deliberately passes nothing for.
```

## temperloop#2020 — DEGRADE, never halt. Before this item a persistent
<a id="temperloop-2020-degrade-never-halt-before-this-item-a-persis"></a>

```text
 temperloop#2020 — DEGRADE, never halt. Before this item a persistent
 gap escalated `review-diff-error`, and that disposition was the
 reported harm, not the drop: by the time §3e runs the worker has
 ALREADY COMMITTED (3c) and passed acceptance (3d), so escalating here
 stops a drive whose work is complete, for the sake of an ADVISORY pass
 that is explicitly never a `checks` gate (build.md §3e). On
 Towheads/foundation at kernel v0.39.0 (run wf_967c2878-0a7, driving
 foundation#1869) that cost 515 verified lines: the item escalated
 committed-but-un-PR'd, and /fix's escalation-park path removed the
 worktree and its local `build/` branch.

 The DETECTORS are untouched — the row/checksum gap check and the
 one-shot retry above both still run, and this arm is reached only
 after both have fired. What changed is what happens next: the
 TABLE-DEPENDENT part of the routing decision cannot be made (routing
 off a missing/partial table is the #1976/#1982 silent-misroute this
 whole mechanism exists to prevent), so the extension axis and the
 prose-`*.md` fallback are withdrawn and that is said out loud — never
 implied by silence. The notice is a mode-2 `skipped — …` line per
 `claude/message-schema.md` § Degradation notice, carried into the PR
 body by reviewBodySuffix() exactly like every other skip notice, so a
 cold reader of the PR sees which part of §3e did not route rather than
 reading a thin review section as a clean pass.

 NOT a return (temperloop#2020 round 2). Returning here conflated "the
 extension-axis table is broken" with "no route can be determined" and
 silently dropped the one route that never needed the table: the
 MANDATORY command-doc rule (foundation#1007) is computed purely from
 `files`, the field that relays reliably, and fires regardless of any
 tsv row. A `claude/commands/*.md` diff whose relay dropped would then
 have reported `mandatory_ok: true` with workflow-reviewer never run —
 byte-identical to a clean pass, i.e. the K.49/foundation#164 silent-skip
 class reintroduced through this very fallback. So the arm now falls
 THROUGH with `tableAvailable: false`: every table-independent route
 still runs, and `mandatory_ok` is computed from real routes again.

 Deliberately NOT the remedy-bearing variant: that one clause is
 sanctioned only for a subagent that ships as source under
 claude/agents/ and is merely uninstalled. This is a relay fault with
 no in-the-moment operator fix, so it takes the bare default shape.
```

## reviewTally — merge one or more runReviewers() rounds (the original 3e
<a id="reviewtally-merge-one-or-more-runreviewers-rounds-the-origin"></a>

```text
 reviewTally — merge one or more runReviewers() rounds (the original 3e pass
 plus any CI-fix re-review, temperloop#1450) into the ONE summary object
 park() threads through to the orchestrator's Step 6 tally. `mandatory_ok`
 is false iff any SKIPPED entry across every round carried `mandatory: true`
 — i.e. the foundation#1007 command-doc rule was genuinely degraded at least
 once, never merely "some optional reviewer wasn't available".

 temperloop#1984 — `routed_not_run`, the WEAKER companion field.
 `mandatory: true` is set by determineReviewers() for `workflow-reviewer` on a
 command-doc diff and for nothing else, so EVERY extension-axis route
 (shell-reviewer for `.sh`, typescript-reviewer for `.mjs`, …) could be
 skipped with `mandatory_ok` still reading `true` — a tally that reads fully
 clean while the shell diff went unreviewed (observed live: six unrun §3e
 shell reviews across three items, every one caught by a human reading the
 roster, never by this tally). `routed_not_run` is the distinct set of
 reviewer names the routing RESOLVED but that did not run in the round they
 were routed for — deliberately a VISIBILITY field, not a second gate (ADR
 0037; kernel principle 7: a hard block here deadlocks legitimate work in a
 consuming checkout where a reviewer agent is genuinely absent, which is the
 ordinary case, not the pathological one). Invariant that closes the hole:
 `routed_not_run` is non-empty exactly when `skipped` is, so the tally can
 never read fully clean while any routed reviewer was skipped. A reviewer
 skipped in one round and run in another stays listed — the skip was real,
 and which round covered which diff is exactly what a reader needs to see.

 temperloop#1970 adds `residual_blocking` — the convergence bound's PER-RUN
 EXECUTION SIGNAL (§ Mandatory-step birth rule): one entry per round that hit
 the bound, carrying the round number and the findings that were CARRIED into
 the PR body rather than re-escalated. So an operator reading the Step 6
 summary can see the bound firing, on which items, with what still outstanding
 — never a prose-only declaration that it exists. OMITTED ENTIRELY when no
 round hit the bound, so an ordinary item's parked record stays byte-identical.
```
