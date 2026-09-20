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

> **Part 3 of 7.** Split to stay under the per-file prose cap
> (`PROSE_BUDGET_TIER2_FILE_CAP`). Other parts: [`build-level.design-notes.md`](build-level.design-notes.md), [`build-level.design-notes-2.md`](build-level.design-notes-2.md), [`build-level.design-notes-4.md`](build-level.design-notes-4.md), [`build-level.design-notes-5.md`](build-level.design-notes-5.md), [`build-level.design-notes-6.md`](build-level.design-notes-6.md), [`build-level.design-notes-7.md`](build-level.design-notes-7.md).

## Bring the remote tip's objects local so the supersede test can run at
<a id="bring-the-remote-tip-s-objects-local-so-the-supersede-test-c"></a>

```text
 Bring the remote tip's objects local so the supersede test can run at
 all; a fetch failure leaves `unique` unset and the arm refuses.

 `--no-merges` is a DELIBERATE, acknowledged narrowing, not an oversight:
 an ordinary merge commit's underlying unique commits are still counted
 (so a normal merge is not a blind spot), but an "evil merge" — one whose
 own conflict-resolution edits exist nowhere else — carries content this
 count cannot see. Accepted because a `/build` worker branch does not
 normally carry merge commits at all, and because dropping the flag would
 count every merge's whole second parent as remote-only work and refuse
 essentially every rescue. The narrowing is bounded by property 1: the
 push is still leased, so it can only ever land on the exact sha read here.

 THREE outcomes, not two (temperloop#2103 review round 1). A refusal on an
 UNANSWERABLE probe is right, but it must not be reported as a refusal on
 an ESTABLISHED conflict: `stale_remote_not_superseded` is what the log
 turns into the flat assertion "origin carries commits this worktree does
 NOT", and a human disposes the escalation against that sentence. When the
 fetch simply failed (the network dropped between the `ls-remote` above
 and this fetch), that sentence is unproven. So `unique` empty ⇒
 `supersede_probe_failed`, `unique > 0` ⇒ `stale_remote_not_superseded`.
 Both refuse identically — only the claim made about why differs.
```

## preserveOnEscalation(item, result) — the ONE choke point. Applied at t
<a id="preserveonescalation-item-result-the-one-choke-point-applied"></a>

```text
 preserveOnEscalation(item, result) — the ONE choke point. Applied at the
 `parallel()` call site over driveItem's settled result, so it covers EVERY
 escalation kind this driver can return, including ones added later: there is
 no per-call-site list to keep in sync, which is exactly the maintenance
 failure a 30-site sprinkle would re-introduce. A `parked` result passes
 through untouched (3f already pushed it and opened its PR).
```

## 3e.5 gate verdict reconciliation (temperloop#1587)
<a id="3e-5-gate-verdict-reconciliation-temperloop-1587"></a>

```text
 --- 3e.5 gate verdict reconciliation (temperloop#1587) ----------------------
 The defect this pair of helpers closes: the slice loop maintained TWO
 independent failure counters — an accumulated `gateFailed` and the terminal
 slice's own `gateOut.failed` — and shipped BOTH in one escalation payload
 (`{gateOut:{outcome:'GATE_PASS',failed:0,…}, failedGates:1}`). A consumer
 that trusted either field acted on a fiction: the kind said the gate failed,
 the embedded object said it passed. Two counters that CAN disagree is the
 defect, not merely the run on which they did — so there is now exactly ONE
 record of failure (the per-slice ledger the loop appends to) and every
 figure reported anywhere — `failedGates`, the verdict, the escalation kind,
 the reason prose — is DERIVED from it by gateVerdict() below. No second
 counter is maintained, and the raw terminal `gateOut` (whose `failed` was
 the contradicting field) is no longer embedded in the payload: its content
 survives as the ledger's last entry, which cannot disagree with the sum of
 the ledger it is part of.
```

## gateSliceFailed(out) — the failure count ONE slice actually ESTABLISHE
<a id="gateslicefailed-out-the-failure-count-one-slice-actually-est"></a>

```text
 gateSliceFailed(out) — the failure count ONE slice actually ESTABLISHED.
 This is the only place a slice's failure count is read, so the ledger's
 entries are normalized on the way in rather than clamped at each reader:
   GATE_SLICE — the count the suite's own `QUALITY_GATES_FAILED=` trailer
                reported for that slice (exit 75 always prints it).
   GATE_FAIL  — a RED suite by construction, so the floor is 1: an unparseable
                or stale trailer must never produce a "failed, 0 failures"
                ledger entry (the mirror image of #1587's contradiction).
   everything else (GATE_PASS / GATE_ABSENT / GATE_TIMEOUT) — 0. A pass is
                zero by construction; a TIMEOUT establishes NOTHING (the slice
                was killed before it could report), and unknown-ness is carried
                by the verdict, never smuggled into a count.
```

## gateSliceResumeAt(out) — the 0-based gate index ONE slice said the sui
<a id="gatesliceresumeat-out-the-0-based-gate-index-one-slice-said-"></a>

```text
 gateSliceResumeAt(out) — the 0-based gate index ONE slice said the suite
 still has to reach, or undefined when it reported none (temperloop#2094).

 Read off the outcome REGARDLESS of its kind, deliberately. `suiteFinished`
 is a claim about whether every gate ran, and the only evidence anyone has
 for that is the suite's own `QUALITY_GATES_RESUME_AT=` trailer; deriving it
 from the terminal outcome's NAME instead is what let a run that stopped at
 gate 152 of 200 ship `suiteFinished: true`. A resume point is that claim's
 direct counter-evidence whether the slice carrying it was classified
 GATE_SLICE or (as in the #2094 incident) something else.

 `0` is not a resume point: the trailer is only ever printed with gates
 REMAINING, so a 0 here is an unparsed/absent field, not "resume at gate 0".
```

## gateVerdict(terminalOutcome, ledger) — the ONE reconciliation point be
<a id="gateverdict-terminaloutcome-ledger-the-one-reconciliation-po"></a>

```text
 gateVerdict(terminalOutcome, ledger) — the ONE reconciliation point between
 the slice loop's terminal outcome and its failure ledger. Every arm's kind,
 counts and reason are computed HERE, from one input, so no arm can ship a
 payload that contradicts its own verdict.

 `verdict` is the single field a consumer may trust:
   RED     — at least one gate FAILED. The branch is known-broken.
   UNKNOWN — nothing failed and the suite never finished (Bash-tool timeout or
             slice-cap exhaustion). It says NOTHING about the tree — the whole
             point of temperloop#1021, preserved exactly: this and only this
             verdict escalates `acceptance-gate-timeout`.
   GREEN   — the suite finished and every gate that ran passed.

 Precedence: an OBSERVED failure dominates an UNFINISHED remainder. A run that
 failed in slice 1 and then timed out in slice 3 is RED — the failures are
 real evidence, the missing verdict for the un-run gates cannot un-fail them —
 and the reason says both halves. This is the same precedence the pre-#1587
 code already applied to a GATE_PASS terminal after a failing slice, now
 applied to the TIMEOUT arm too, so "timeout" never launders a known failure
 into an unknown. A timeout with NO observed failure is untouched.
```

## A resume point in the LAST ledger entry is direct evidence that gates
<a id="a-resume-point-in-the-last-ledger-entry-is-direct-evidence-t"></a>

```text
 A resume point in the LAST ledger entry is direct evidence that gates
 remained when the run stopped, and it OVERRIDES the terminal outcome's own
 name (temperloop#2094). The incident: the final slice came back with an
 unexpected exit code and was classified GATE_FAIL, whose name put it in
 the `finished` set below — so an escalation for a run that stopped at gate
 152 of 200 reported `suiteFinished: true`, and the next reader had no way
 to tell a whole-suite verdict from a 76%-of-the-way-through one. The
 trailer is the only first-hand evidence about coverage that exists; a
 classification derived downstream of it can never outrank it.
```

## Standing contract — carried by claude/agents/machinery-executor.md on
<a id="standing-contract-carried-by-claude-agents-machinery-ex"></a>

```text
 Standing contract — carried by claude/agents/machinery-executor.md on
 the lean path, restated per call on the general-purpose fallback.
```

## …and LOG them. This is the observable-progress half of the bound: a st
<a id="and-log-them-this-is-the-observable-progress-half-of-th"></a>

```text
 …and LOG them. This is the observable-progress half of the bound: a step
 that outran its expected duration but has NOT hit the ceiling is not lost
 and is not disposed — it is simply made visible, which is the one thing the
 9h49m stall never was.
```

## temperloop#1698: canonical camelCase reads, fed by canonicalizeOutcome
<a id="temperloop-1698-canonical-camelcase-reads-fed-by-canoni"></a>

```text
 temperloop#1698: canonical camelCase reads, fed by canonicalizeOutcome
 above — the `?? '?'` fallback is now the ONLY zero-free way an unknown
 figure can render here, never a silent 0.
```

## batchDeniedStep — what to name in a `machinery-denied` payload. A one-
<a id="batchdeniedstep-what-to-name-in-a-machinery-denied-payl"></a>

```text
 batchDeniedStep — what to name in a `machinery-denied` payload. A one-step
 batch names its only step (so a solo worktree/gate denial reads exactly as it
 did before batching); a multi-step batch names the batch itself and carries
 the full step list alongside.
```

## workerGateLog — where the handed invocation tees the suite's own outpu
<a id="workergatelog-where-the-handed-invocation-tees-the-suit"></a>

```text
 workerGateLog — where the handed invocation tees the suite's own output, so a
 worker that must explain a red gate has the text as well as the exit code.
```

## temperloop#865 — the STRUCTURAL half of the same contract. The block a
<a id="temperloop-865-the-structural-half-of-the-same-contract"></a>

```text
 temperloop#865 — the STRUCTURAL half of the same contract. The block above
 is the warning that failed 2/2; this hands over a pre-composed invocation
 and a result ARTIFACT to poll, so the failure it names is no longer the
 worker's to make. See workerGateSection()'s own header.
```

## temperloop#1931 — placed right after the FOREGROUND-ONLY block's own
<a id="temperloop-1931-placed-right-after-the-foreground-only-"></a>

```text
 temperloop#1931 — placed right after the FOREGROUND-ONLY block's own
 `--scoped` instructions (a few lines up) and its hostConfig sibling, so
 the worker reads "register first" while "then run --scoped" is still
 fresh. build.md §3c carries the prose half in lockstep.
```

## Compose the retry `extraSection` = the original section (if any) + the
<a id="compose-the-retry-extrasection-the-original-section-if-"></a>

```text
 Compose the retry `extraSection` = the original section (if any) + the cure,
 plus the dirty-resume note when the probe saw uncommitted work (#993), plus
 the #865 sentinel-recovery note when a slug is known.
```

## workerOutcomeRef — ADR 0026's outcome-ref vocabulary, "(issue|pr):<ref
<a id="workeroutcomeref-adr-0026-s-outcome-ref-vocabulary-issu"></a>

```text
 workerOutcomeRef — ADR 0026's outcome-ref vocabulary, "(issue|pr):<ref>".
 The item's own tracking issue is the one stable ref known at worker-spawn
 time (a PR may not exist yet); an issue-less item (boardless work) falls
 back to its slug rather than emitting an empty ref.
```

## elapsedMs — plain integer arithmetic on two already-resolved epoch-SEC
<a id="elapsedms-plain-integer-arithmetic-on-two-already-resol"></a>

```text
 elapsedMs — plain integer arithmetic on two already-resolved epoch-SECONDS
 readings (never Date.now() — see above). null when either edge is
 unavailable, so a partial reading never manufactures a false zero.
```

## `nullReturn` (temperloop#1819): true only for the bare-null shape, whe
<a id="nullreturn-temperloop-1819-true-only-for-the-bare-null-"></a>

```text
 `nullReturn` (temperloop#1819): true only for the bare-null shape, where
 NO error text exists — the caller's quota classification then falls back
 to the agent-liveness canary instead of text matching.
```

## workerQuotaDeath — the worker-path quota classifier (temperloop#1819):
<a id="workerquotadeath-the-worker-path-quota-classifier-tempe"></a>

```text
 workerQuotaDeath — the worker-path quota classifier (temperloop#1819): the
 thrown-text shape matches directly; the bare-null shape asks the canary.
```

## STAGE_RECOVER (temperloop#1294): an off-path diagnostic that can fire 
<a id="stage-recover-temperloop-1294-an-off-path-diagnostic-th"></a>

```text
 STAGE_RECOVER (temperloop#1294): an off-path diagnostic that can fire from
 any stage, so it gets its own group and never moves the global cursor.
```

## `probe.sha` is REQUIRED for the adopt arm, not optional: the CI poll t
<a id="probe-sha-is-required-for-the-adopt-arm-not-optional-th"></a>

```text
 `probe.sha` is REQUIRED for the adopt arm, not optional: the CI poll that
 follows is PINNED to a SHA (#254's false-green guard), so adopting a PR whose
 head we could not read would poll an unpinned ref. No SHA → escalate instead.
```

## temperloop#1688 — the push landed on a ref no open PR watches. Its own
<a id="temperloop-1688-the-push-landed-on-a-ref-no-open-pr-wat"></a>

```text
 temperloop#1688 — the push landed on a ref no open PR watches. Its own
 escalation kind, never 'push-error': the push did not fail, and the
 disposition (re-push onto the PR's head ref, named in the payload) is
 specific to this state.
```

## RECOVER_NONE / RECOVER_DIRTY / denied / unusable probe — genuinely not
<a id="recover-none-recover-dirty-denied-unusable-probe-genuin"></a>

```text
 RECOVER_NONE / RECOVER_DIRTY / denied / unusable probe — genuinely nothing
 landed (or the probe itself gave no usable answer); the caller falls
 through to its own UNCHANGED escalation, exactly as before this wiring.
```

## Per-item driver (3a–3h for ONE item). Returns either a `parked` record
<a id="per-item-driver-3a-3h-for-one-item-returns-either-a-par"></a>

```text
 -----------------------------------------------------------------------------
 Per-item driver (3a–3h for ONE item). Returns either a `parked` record or an
 `escalation` record — NEVER both. The pipeline collects these.
 -----------------------------------------------------------------------------
```

## A small helper to build an escalation result (worktree stays intact).
<a id="a-small-helper-to-build-an-escalation-result-worktree-s"></a>

```text
 A small helper to build an escalation result (worktree stays intact).
 `round_kind` rides alongside `kind` on every escalation record — see
 escalationRoundKind() above for the one place that mapping is computed.
```

## noteSideline — read the CREATED outcome's sideline verdict, and when i
<a id="notesideline-read-the-created-outcome-s-sideline-verdic"></a>

```text
 noteSideline — read the CREATED outcome's sideline verdict, and when it fired
 emit the NAMED notice and record it for the choke-point stamp below. A clean
 create over an empty path reports `sidelined: false` (or omits the field on an
 older worktree.sh), and this is a total no-op on that arm.
```

## No worktree (an escalation from before 3b, e.g. claim-conflict) — ther
<a id="no-worktree-an-escalation-from-before-3b-e-g-claim-conf"></a>

```text
 No worktree (an escalation from before 3b, e.g. claim-conflict) — there
 is nothing to preserve and that is a normal, expected arm.
```

## Same default_branch() fallback chain reviewDiffCmd uses, for the same
<a id="same-default-branch-fallback-chain-reviewdiffcmd-uses-f"></a>

```text
 Same default_branch() fallback chain reviewDiffCmd uses, for the same
 reason: this must not depend on pr.sh having run first.
```

## The count rides along only when it is real; on the unresolved arm the
<a id="the-count-rides-along-only-when-it-is-real-on-the-unres"></a>

```text
 The count rides along only when it is real; on the unresolved arm the
 detail says so instead, so `commits_ahead` is never a fabricated figure
 and never a non-number in a JSON number position.
```

## The outcome is the REMOTE's answer, not the push's. Re-read the ref: t
<a id="the-outcome-is-the-remote-s-answer-not-the-push-s-re-re"></a>

```text
 The outcome is the REMOTE's answer, not the push's. Re-read the ref: the
 work is preserved iff origin now carries this worktree's exact HEAD.
```

## `if` rather than `[ … ] && …`: a trailing AND-list that evaluates fals
<a id="if-rather-than-a-trailing-and-list-that-evaluates-fals"></a>

```text
 `if` rather than `[ … ] && …`: a trailing AND-list that evaluates false
 is the whole command's status, which `set -e` (wherever this text is
 sourced) would take as a failure of the preservation step itself.
```

## The plan's branch — the ref 3f pushes — not the worktree's local
<a id="the-plan-s-branch-the-ref-3f-pushes-not-the-worktree-s-"></a>

```text
 The plan's branch — the ref 3f pushes — not the worktree's local
 `build/<slug>` HEAD; see preserveCommittedWorkCmd's header for why. The
 fallback is the worktree's own name only for a malformed item that somehow
 reached here without the schema-required `branch:`.
```

## NOT the sentence above. The refusal was the same, the reason is not:
<a id="not-the-sentence-above-the-refusal-was-the-same-the-rea"></a>

```text
 NOT the sentence above. The refusal was the same, the reason is not:
 nothing was established about the remote, so claiming it "carries
 commits this worktree does NOT" would be a fabricated fact — and it
 is the sentence a human disposes the escalation against.
```

## temperloop#2135: the LEDGER's own length, not the static GATE_MAX_SLIC
<a id="temperloop-2135-the-ledger-s-own-length-not-the-static-"></a>

```text
 temperloop#2135: the LEDGER's own length, not the static GATE_MAX_SLICES
 constant — a zero-failure run can run past GATE_MAX_SLICES on the
 GATE_RESUME_EXTENSIONS allotments the 3e.5 loop grants itself, and this
 message must say how many slices actually ran, not the base ceiling.
```

## temperloop#2094: a terminal outcome whose NAME says "done" over a fina
<a id="temperloop-2094-a-terminal-outcome-whose-name-says-done"></a>

```text
 temperloop#2094: a terminal outcome whose NAME says "done" over a final
 slice that printed a resume point. Say which one is being believed, and
 why, rather than letting the name win silently.
```

## The temperloop#1587 shape: the FINAL slice passed, so the log's last
<a id="the-temperloop-1587-shape-the-final-slice-passed-so-the"></a>

```text
 The temperloop#1587 shape: the FINAL slice passed, so the log's last
 line reads "OK — gates N..M passed (final slice)". Say plainly that the
 green line covers only the gates that slice ran, or the next reader
 repeats #1587's mis-read and calls the escalation a false positive.
```

## The parked-record tally: [{ criterion, host_config }]. `host_config` c
<a id="the-parked-record-tally-criterion-host-config-host-conf"></a>

```text
 The parked-record tally: [{ criterion, host_config }]. `host_config` carries
 the file/env var the worker named, because that is precisely what the
 orchestrator needs to run the parent-side check (build.md §4a) — a bare
 criterion list would make the parent re-derive it from prose.
```

## quotaDeath — null when `text` is not the harness's quota-death message
<a id="quotadeath-null-when-text-is-not-the-harness-s-quota-de"></a>

```text
 quotaDeath — null when `text` is not the harness's quota-death message;
 otherwise { reset: <string|null> } with the reset time when the message
 carries one ("… · resets 5:30pm" → "5:30pm").
```

## Alive → drop the cache so the NEXT bare-null probes afresh; dead →
<a id="alive-drop-the-cache-so-the-next-bare-null-probes-afres"></a>

```text
 Alive → drop the cache so the NEXT bare-null probes afresh; dead →
 leave the resolved promise in place (the sticky verdict).
```

## quotaEscalation — the quota-exhausted escalation record. `worktree_lef
<a id="quotaescalation-the-quota-exhausted-escalation-record-w"></a>

```text
 quotaEscalation — the quota-exhausted escalation record. `worktree_left_intact`
 is load-bearing (issue #1819 acceptance): it is what tells the disposer this
 is a recover-vs-re-drive decision — the escalation cleaned up NOTHING, so
 whatever the item had built is still in the worktree.
```

## deniedOrQuota — every site that mints a `machinery-denied` escalation 
<a id="deniedorquota-every-site-that-mints-a-machinery-denied-"></a>

```text
 deniedOrQuota — every site that mints a `machinery-denied` escalation routes
 through this instead: a SPINE_DENIED whose real cause is the quota death
 (the canary cannot spawn either) becomes quota-exhausted; a genuine denial
 keeps the byte-identical machinery-denied escalation it always produced.
```

## The no-tsv worktree emits an EMPTY ARRAY, the `tsv_lines` analogue of 
<a id="the-no-tsv-worktree-emits-an-empty-array-the-tsv-lines-"></a>

```text
 The no-tsv worktree emits an EMPTY ARRAY, the `tsv_lines` analogue of the
 `tsv:""` it used to emit — still never an OMITTED key, so "missing" keeps
 meaning "the relay dropped it", never "this worktree ships no table".
```

## Neither a finished verdict nor a recognized budget outcome: the execut
<a id="neither-a-finished-verdict-nor-a-recognized-budget-outcome-t"></a>

```text
 Neither a finished verdict nor a recognized budget outcome: the executor
 returned something outside the gate's own closed set. Pre-#1587 this fell
 through to the GATE_PASS/GATE_ABSENT arm and PUSHED a branch whose gate
 never returned a verdict — the permissive-default hole this epic exists
 to close. It is UNKNOWN, and the reason names the outcome verbatim rather
 than dressing it up as a budget fact.
```

## park()'s trailing three arguments (discriminationGapList, review, cost
<a id="park-s-trailing-three-arguments-discriminationgaplist-review"></a>

```text
 park()'s trailing three arguments (discriminationGapList, review, cost) are
 INDEPENDENT tallies (temperloop#1319, temperloop#1450, temperloop#2065)
 that happened to land on the same function in the same window — none
 supersedes another; each is optional and independently omitted when
 empty/absent, exactly like `no_ci` above.
```

## temperloop#605/#618: a NO_CI-outcome item parks identically to a green
<a id="temperloop-605-618-a-no-ci-outcome-item-parks-identically-to"></a>

```text
 temperloop#605/#618: a NO_CI-outcome item parks identically to a green one,
 but carries a durable `no_ci` marker so the orchestrator stamps the
 `  - no_ci: true` sub-line (build.md 3h) and renders `CI —  (no CI
 configured)` rather than `CI ✓` in the 4a summary — never letting an
 untested-by-CI PR look confirmed-green.
```

## temperloop#1319: the degraded-case tally, same durable-marker shape as
<a id="temperloop-1319-the-degraded-case-tally-same-durable-marker-"></a>

```text
 temperloop#1319: the degraded-case tally, same durable-marker shape as
 `no_ci` above — carried on the parked record so the orchestrator can
 stamp it on the plan item and roll it into the Step 6 summary (build.md
 §3f step 2's sibling "Surface the degraded case" pattern). Omitted
 entirely when empty, exactly like `no_ci` is omitted when false, so an
 unarmed run's parked records are byte-identical to before this item.
```

## machineryDenied — a machinery step returned no usable outcome. runMach
<a id="machinerydenied-a-machinery-step-returned-no-usable-outcome-"></a>

```text
 machineryDenied — a machinery step returned no usable outcome. runMachinery already
 normalizes agent()'s null (auto-mode classifier DENIED the command / user
 skip / terminal API error) to a SPINE_DENIED sentinel; this recognizes both
 that sentinel and a bare null. Either means "the mechanical step did not run"
 — so the caller escalates `machinery-denied` (a clean, parkable escalation the
 orchestrator can drive to a human) instead of dereferencing `.outcome` on a
 null/absent result and crashing the level (temperloop#72).
```

## Session-quota death classification (temperloop#1819).
<a id="session-quota-death-classification-temperloop-1819"></a>

```text
 -----------------------------------------------------------------------------
 Session-quota death classification (temperloop#1819).
 -----------------------------------------------------------------------------
 A step or worker that dies because the SESSION hit its usage limit ("You've
 hit your session limit · resets 5:30pm") used to collapse into the two
 pre-existing kinds — `machinery-denied`/SPINE_DENIED (whose documented cure
 is rewriting the command for the auto-mode classifier) and `worker-error`
 "agent returned null" (whose cure is re-driving with sharper instructions).
 BOTH cures are wrong for a quota death: the command was never the problem
 and the work is usually INTACT in the worktree (the #1819 incident's item
 held three clean commits and a finished verification surface — re-driving
 would have discarded a finished item). So a quota death gets its OWN kind,
 `quota-exhausted`, whose disposition is wait-for-reset then RESUME.

 The death reaches this script through TWO shapes, classified differently:
   • agent() THREW and the error text carries the harness's limit message —
     quotaDeath(text) matches it directly and extracts the reset time.
   • agent() returned a bare NULL (the #1819 incident's shape) — no text
     reaches this script at all (the truth lives only in the harness's own
     <failures> block, a channel the orchestrator reads, not this script).
     The one in-process discriminator left is BEHAVIORAL: a classifier
     denial is per-command (an innocuous probe still spawns), while a quota
     death kills EVERY spawn. harnessCanSpawnAgents() runs that probe — a
     cheap canary agent, re-run per bare-null with only its DEAD verdict
     memoized (see its own comment) — and a failed canary reclassifies the
     null as quota-exhausted. A canary that spawns fine leaves the pre-#1819
     kinds untouched, so genuine denials/skips keep their meanings.
```

## harnessCanSpawnAgents — the null-shape discriminator above. Memoizatio
<a id="harnesscanspawnagents-the-null-shape-discriminator-above-mem"></a>

```text
 harnessCanSpawnAgents — the null-shape discriminator above. Memoization is
 deliberately ASYMMETRIC (temperloop#1819 attempt-2 review finding 1): only a
 DEAD verdict is sticky. The quota is monotone within one exhaustion window —
 once every spawn dies, they keep dying — so one dead probe answers for the
 whole level's burst of deaths. (A window that resets mid-level could make the
 cached "dead" stale for a later item; that item still escalates with its work
 intact — exactly what the wait-then-resume disposition handles — so the dead
 cache stays.) An ALIVE verdict is NOT cached: "alive at probe time" says
 nothing about a spawn that dies LATER in the same level, and a memoized alive
 would misroute that later quota death back into machinery-denied/worker-error
 — the destructive mis-cure this whole classifier exists to prevent. So every
 bare-null re-probes; concurrent callers still share one in-flight probe (the
 promise is the cache entry until it resolves alive). Fails OPEN: an
 inconclusive canary (a non-quota throw) reads as "alive" so the pre-#1819
 kinds stand rather than inventing a quota verdict from a probe that merely
 misbehaved.
```

## DECIMAL, NEVER OCTAL (temperloop#1970, typescript-reviewer round 1). T
<a id="decimal-never-octal-temperloop-1970-typescript-reviewer-roun"></a>

```text
 DECIMAL, NEVER OCTAL (temperloop#1970, typescript-reviewer round 1). The
 `tr` filter strips non-digits but NOT leading zeros, and POSIX `$(( ))`
 reads a leading-`0` numeral as OCTAL — so a marker file someone
 hand-edited, or restored from a stale snapshot, holding `08`/`09` is not
 a wrong count but a HARD shell error that aborts the whole step and
 surfaces as exactly the `review-diff-error` escalation §3e is least able
 to act on. This code path cannot write such a value itself, but the file
 is an ordinary file in the worktree's git dir and the surrounding
 contract is explicit that every marker step fails SOFT — a
 corrupted-but-present marker was the one case that story did not cover.
 `sed -E 's/^0+//'` normalises to a bare decimal (an all-zeros value
 collapses to the empty string, which the `[ -n … ]` fallback below then
 reads as 0), so a corrupted marker degrades to "first round" exactly as a
 missing one does. `sed -E` over `\\?`-style BRE: the same portable dialect
 the `origin/` strip below already relies on.
 A MISPLACED `2>/dev/null` CANNOT SUPPRESS A REDIRECTION FAILURE
 (temperloop#2127 round 2, MEDIUM 1). Redirections are applied left to
 right, so when the INPUT redirection `< "$rounds_file"` is itself what
 fails (an unreadable marker — `chmod 000`, a dangling symlink), the
 shell reports `Permission denied` on its OWN stderr BEFORE a trailing
 `2>/dev/null` on the same simple command is ever in scope. Measured:
 two stray `Permission denied` lines, rc=0. That is loose text sitting
 beside the ONE JSON line the machinery-executor relay is specified to
 echo verbatim, and this file's history (#1976, #1982, #2020) is a
 catalogue of that relay mangling the line whenever it is handed extra
 text. A brace group puts the suppression in scope for the redirection
 itself, which is the only form that actually silences it.
```

## Record THIS round's HEAD for the NEXT round to read as its prior
<a id="record-this-round-s-head-for-the-next-round-to-read-as-its-p"></a>

```text
 Record THIS round's HEAD for the NEXT round to read as its prior
 SHA. Written only on the bumping call (temperloop#2046 — the SAME
 no-test-writes-production-state guard the round counter already
 carries: a non-bumping call, e.g. the #1976 tsv-gap re-fetch or
 any test harness invocation, must never touch either marker).

 `--verify --quiet`, never a bare `git rev-parse HEAD` (round 2,
 HIGH A, second path). On an UNBORN HEAD — a worktree whose branch
 has no commit yet — a bare `git rev-parse HEAD` prints the literal
 string `HEAD` on STDOUT and exits 128, so `|| true` swallows the
 status and the `[ -n … ]` guard below happily accepts `HEAD` and
 writes it into the marker. The next round's `tr -cd` then filters
 that to `EAD`. `--verify --quiet` yields the empty string instead,
 so nothing is written at all and the next round reads a clean
 absent marker.
```

## POSITION-WEIGHTED (temperloop#1982 round 2): `n` is a running counter
<a id="position-weighted-temperloop-1982-round-2-n-is-a-running-cou"></a>

```text
 POSITION-WEIGHTED (temperloop#1982 round 2): `n` is a running counter
 over EVERY byte of the row-filtered stream, NOT reset between od's own
 output lines — so each byte's contribution depends on where it sits,
 not just what it is. A bare sum (the round-1 shape) is commutative and
 therefore blind to two same-length rows trading places; weighting by
 position closes that — see tsvChecksum()'s own comment for the exact
 corruption shape this defeats.
```

## parseTsvRows / reviewGlobMatch — the SAME extension/glob axis
<a id="parsetsvrows-reviewglobmatch-the-same-extension-glob-axis"></a>

```text
 parseTsvRows / reviewGlobMatch — the SAME extension/glob axis
 reviewer-routing.tsv declares (ADR 0008), read fresh off the worktree's own
 copy each run so this never drifts from the tracked source of truth (never
 a hardcoded restatement — the exact drift check-reviewer-routing.sh guards
 against in build.md prose applies here too, just enforced by reading the
 file instead of a lint).
```

## tsvChecksum — temperloop#1982, made POSITION-SENSITIVE in round 2: a
<a id="tsvchecksum-temperloop-1982-made-position-sensitive-in-round"></a>

```text
 tsvChecksum — temperloop#1982, made POSITION-SENSITIVE in round 2: a
 pure-arithmetic content checksum over the SAME row-count-filtered lines
 parseTsvRows()'s first stage keeps (blank and `#`-comment lines stripped),
 so a corrupted comment header (which carries this repo's own non-ASCII
 punctuation, e.g. em dashes) never enters the sum and cannot desync the
 two independent implementations of this algorithm — this one, and
 reviewDiffCmd's bash pipeline (`od`-computed byte values, weighted and
 summed in awk).

 WHY POSITION-WEIGHTED, NOT A BARE SUM (round 1's shape): a bare sum of
 character codes is COMMUTATIVE — invariant under any rearrangement of the
 same characters. The round-2 reviewer reproduced this against this repo's
 OWN tracked reviewer-routing.tsv: swapping the reviewer+path columns
 between the `.sh` row and the `docs/**` row (same row count, same overall
 character multiset — a plausible hand-copy slip, and the exact shape of
 the temperloop#1978 round-4 incident: a .sh diff silently routed to
 docs-reviewer) left the bare-sum checksum byte-IDENTICAL. Multiplying each
 character's code by its 1-based position in the canonicalized stream
 before summing breaks that: the SAME characters at DIFFERENT offsets sum
 to a different total (verified against this repo's live tsv — see
 test_workflow.sh's "K1982 position-sensitive: transposed columns" case).
 This is still an INTEGRITY check against relay noise, not a cryptographic
 one — collisions are not the concern, only whether the `tsv` string
 runReviewers() received is the same content, in the same arrangement,
 reviewDiffCmd actually read off the worktree.

 Needs no hashing primitive: canonicalize (kept lines, each with its own
 trailing newline — matching awk's `print`, ORS appended after every line,
 none added at the very end beyond that, so a run over zero lines sums to
 0), then `sum += code * (i + 1)` over that string. Verified — by an
 automated test that executes reviewDiffCmd's REAL bash pipeline, not a
 restated comment — to agree with the bash side against this repo's own
 reviewer-routing.tsv (test_workflow.sh's "bash/JS parity" case). That
 agreement holds only while every DATA row (not the comment header, which
 is filtered out before either side sums) is pure ASCII — reviewer-routing
 .tsv's own header names that constraint for whoever next edits a data row.
```

## Trimmed-emptiness filter (`l.trim()`, not bare `l`) — matches
<a id="trimmed-emptiness-filter-l-trim-not-bare-l-matches"></a>

```text
 Trimmed-emptiness filter (`l.trim()`, not bare `l`) — matches
 reviewDiffCmd's bash `t != ""` check (`t` is the TRIMMED line) exactly,
 so a whitespace-only line is filtered identically on both sides. This
 deliberately does NOT reuse parseTsvRows's own first-stage filter (bare
 `l`), which answers a different question (is this a candidate data row
 for the routing decision) — tsvChecksum answers "did the bash side count
 this line," and those two must agree bit-for-bit or the checksum could
 disagree with a perfectly faithful relay.
```

## BASENAME form, e.g. '**/Makefile' (temperloop#1705) — the tsv key shap
<a id="basename-form-e-g-makefile-temperloop-1705-the-tsv-key-shap"></a>

```text
 BASENAME form, e.g. '**/Makefile' (temperloop#1705) — the tsv key shape
 for an extensionless, path-independent file neither other form can key
 on. Match the basename EXACTLY, never as a bare suffix: leaning on the
 extension arm's `file.endsWith('Makefile')` would also claim
 `NotAMakefile`, routing an unrelated file to a reviewer chosen for this
 one. Checked FIRST — a '**/x' key never ends in '/**', so the two glob
 shapes stay disjoint.
```

## reviewContinuationSection — temperloop#2127. The delta-aware instructi
<a id="reviewcontinuationsection-temperloop-2127-the-delta-aware-in"></a>

```text
 reviewContinuationSection — temperloop#2127. The delta-aware instructions
 spliced into reviewPrompt() ONLY on a continuation round (round > 1),
 carrying the PRIOR round's number, the SHA that was HEAD when that round
 ran, and — WHEN THERE WERE ANY — its findings text (already captured; see
 runReviewers()'s own comment on where priorFindingsText comes from, this
 function never re-derives it).

 TWO PREMISES, AND THE SECTION MUST TELL THE TRUTH ABOUT WHICH ONE IT IS
 (round 2, HIGH B1). `round` is the SHARED per-worktree §3e invocation
 counter, bumped by every bumping reviewDiffCmd call — NOT a count of
 review-blocking escalations. Per build.md's 3d-esc loop, ANY escalation kind
 (rebase-conflict, push-rejected, dirty-worktree, ci-failed, pr-open-failed…)
 resumes through 3c -> 3e and bumps it, and §3g's CI-fix re-review bumps it
 again on essentially every CI-fix retry. On all of those paths the PRIOR
 round was CLEAN — that is precisely why the item got as far as 3f/3g.
 Asserting "Round N found blocking finding(s), reproduced below" there is
 simply FALSE, and the old code then followed it with "(no findings text was
 recorded for the prior round)" — a self-contradiction handed to a reviewer
 as its premise. So the opening sentence, the step list and the numbering all
 branch on whether findings are ACTUALLY present:
   - findings present -> a review-blocking continuation: (1) verify each
     prior finding is resolved, (2) delta, (3) full sweep.
   - findings absent  -> a clean-prior-round re-review: (1) delta, (2) full
     sweep. Nothing to re-verify, and the prompt says so outright rather than
     implying a blocking round that never happened.
 The delta instruction is worth keeping on BOTH arms — a re-review after a CI
 fix benefits from "what changed since the last review" exactly as much as a
 fix round does; only the premise differs.

 `priorContext.sha` can be null (no marker was ever written, or reviewDiffCmd
 rejected it as unresolvable or as no longer an ancestor of HEAD — see its own
 comment) — the diff instruction then degrades to a commit-range-FREE
 instruction rather than emitting a bogus `..HEAD` range.
```

## reviewPrompt — a read-only pass over THIS item's diff, carrying the sa
<a id="reviewprompt-a-read-only-pass-over-this-item-s-diff-carrying"></a>

```text
 reviewPrompt — a read-only pass over THIS item's diff, carrying the same
 effective (kernel ∪ project) principle set §3c hands the worker (build.md
 §3e: "Reuse that resolution; do not re-resolve it here") as additional
 evaluation criteria. The reviewer's own agent definition (claude/agents/…)
 owns its checklist/output-format contract; this prompt only scopes it.

 `priorContext` (temperloop#2127) — undefined/null on round 1, which keeps
 this branch's output BYTE-IDENTICAL to pre-#2127 (the `continuation` array
 below is empty and contributes nothing to the join). On a continuation
 round it is `{ round, sha, findings }` (see runReviewers()) and splices in
 reviewContinuationSection()'s delta-aware instructions between the scope
 header and the changed-files list.
```

## reviewHasBlockingFinding — this repo's reviewer catalog (workflow-revi
<a id="reviewhasblockingfinding-this-repo-s-reviewer-catalog-workfl"></a>

```text
 reviewHasBlockingFinding — this repo's reviewer catalog (workflow-reviewer,
 docs-reviewer, architecture-reviewer, the per-language reviewers) all share
 one output contract: `### [HIGH | MEDIUM | LOW] <name> in <file>`. A HIGH
 finding is the blocking bar — build.md §3e: "Blocking issues loop back to
 3c with the review feedback as context."
```

## reviewDiffTsvText(diffOut) — temperloop#2020. The ONE place that turns
<a id="reviewdifftsvtext-diffout-temperloop-2020-the-one-place-that"></a>

```text
 reviewDiffTsvText(diffOut) — temperloop#2020. The ONE place that turns a
 REVIEW_DIFF result's routing-table field into the text parseTsvRows() and
 tsvChecksum() consume, so the gap check and the routing decision can never
 read two different renderings of the same payload.

 Accepts BOTH wire shapes, in this precedence:
   `tsv_lines` — the current shape (an array of data-row strings, #2020).
                 Joined on `\n`, which is byte-identical to the string the
                 previous `tsv` scalar carried: reviewDiffCmd's awk `print`
                 emitted one kept line per row, and both consumers re-append
                 their own trailing newline per kept line, so a joined array
                 and the old blob canonicalize to the same bytes and hence
                 the same row count and the same checksum.
   `tsv`       — the legacy scalar, still ACCEPTED (never emitted). An
                 un-migrated caller, a replayed older payload, or a relay
                 that reconstructed the old field keeps routing normally
                 instead of degrading.
 Returns null when NEITHER shape is present in a usable form — the caller
 distinguishes "dropped" from "legitimately empty" (`tsv_lines: []` is an
 empty ARRAY, a real zero-row table, not a missing field).
```

## `priorContext` — null on round 1 (the ONLY thing that keeps reviewProm
<a id="priorcontext-null-on-round-1-the-only-thing-that-keeps-revie"></a>

```text
 `priorContext` — null on round 1 (the ONLY thing that keeps reviewPrompt()'s
 round-1 output byte-identical to pre-#2127, acceptance bullet 3). Built from
 data already in hand: `priorRounds`/`priorSha` read above off THIS SAME
 diffOut, `priorFindingsText` the caller optionally supplied (never
 re-derived here).

 `isContinuationRound` is the honest precondition and is deliberately NOT a
 claim about findings (round 2, HIGH B1). `round > 1` establishes exactly one
 fact — a prior §3e pass really did run against this worktree — which is what
 makes a delta instruction meaningful, and nothing more. Whether that prior
 pass BLOCKED is a separate question, answered solely by whether the caller
 handed us its findings text; reviewContinuationSection() branches its whole
 premise on that, so neither arm can assert something untrue. `findings` is
 normalised to '' (never undefined) so that branch has a single predicate to
 test.
```

## temperloop#1976: a dropped/truncated tsv relay is nondeterministic per
<a id="temperloop-1976-a-dropped-truncated-tsv-relay-is-nondetermin"></a>

```text
 temperloop#1976: a dropped/truncated tsv relay is nondeterministic per
 copy (the same command, re-run, has been observed to carry it intact) —
 re-run the SAME diff-fetch command once before treating it as a genuine
 failure, so determineReviewers() is never called with an empty table for
 a worktree that actually ships a real one. The re-fetch is NON-BUMPING
 (temperloop#1970): one driver round must advance the round counter once.
```

## sections — the STRUCTURED per-reviewer findings ({ reviewer, text }, r
<a id="sections-the-structured-per-reviewer-findings-reviewer-text-"></a>

```text
 sections — the STRUCTURED per-reviewer findings ({ reviewer, text }, ran
 order), alongside the pre-joined `notes` string (temperloop#1846). The
 structure is what lets reviewBodySuffix() relabel a CI-fix round's block
 (`### <reviewer> (ci-fix round N)`) without regex surgery on reviewer
 text that may itself contain `### ` lines.
```

## temperloop#2003 — SPAWN EVERY ROUTED REVIEWER FIRST, then wait on the 
<a id="temperloop-2003-spawn-every-routed-reviewer-first-then-wait-"></a>

```text
 temperloop#2003 — SPAWN EVERY ROUTED REVIEWER FIRST, then wait on the set
 under one wall-clock ceiling. Before this the pass awaited each reviewer in
 turn, so a single agent that never returned kept every LATER one from
 launching at all: in the observed incident the mandatory `workflow-reviewer`
 for a `claude/commands/*.md` diff was never spawned, because the reviewer
 ahead of it in the loop hung. Spawning is synchronous and in route order, so
 the call ORDER (what the journal and a resume's cached prefix key on) and
 the per-reviewer result ORDER are both byte-identical to the old loop's.
```

## No `schema` — a plain read-only advisory pass, not a machine-validated
<a id="no-schema-a-plain-read-only-advisory-pass-not-a-machine-vali"></a>

```text
 No `schema` — a plain read-only advisory pass, not a machine-validated
 verdict (build.md §3e: "docs-reviewer is advisory only ... never a
 checks gate entry"). Deliberately no `model` override either: the
 reviewer's OWN agent definition sets its tier (e.g.
 claude/agents/workflow-reviewer.md declares `model: sonnet`).

 The two-arm `.then` is the settlement RECORDER, not error handling: it
 makes each reviewer's own outcome readable WITHOUT awaiting it, which is
 what lets the ceiling below keep every settled reviewer's findings while
 abandoning only the unsettled ones. It also means a rejected reviewer
 promise is always handled, so a reviewer that throws after the ceiling has
 passed can never surface as an unhandled rejection.
```

## temperloop#2032 — THE LAST-CHANCE READ, and the reason the disposition
<a id="temperloop-2032-the-last-chance-read-and-the-reason-the-disp"></a>

```text
 temperloop#2032 — THE LAST-CHANCE READ, and the reason the disposition
 below is three passes rather than one loop. `slot.done` is set by the
 settlement recorder attached at the spawn above, which runs as a MICROTASK
 on the reviewer's own promise — so the ceiling's race can return with a
 reviewer whose result has ALREADY arrived but whose recorder has not run
 yet. The pre-#2032 loop read `!slot.done` exactly once, immediately after
 that await, and never again: such a reviewer was reported
 `skipped — exceeded the §3e review ceiling` while its full review sat in
 hand, unread. That is not a hang — the result ARRIVES and is thrown away
 (run wf_c71d1576-e9d discarded two complete reviews that way, one of which
 had already found the defect a hand-routed reviewer re-found later and
 PR #2039 then fixed).

 The ceiling is NOT at fault and is untouched: it still bounds how long the
 pass WAITS, and this changes only what happens to a result that arrives
 anyway. Every read below is therefore as late as it can HONESTLY be —
 bounded settlement drains only (no wall clock, no timer spawn, and never a
 re-spawn of a reviewer whose result is already in hand), never a second
 wait: re-introducing one would be exactly the unbounded stall
 temperloop#2003 removed.
```

## Pass 3 — apply the dispositions in ROUTE order, so `ran`/`skipped`/
<a id="pass-3-apply-the-dispositions-in-route-order-so-ran-skipped"></a>

```text
 Pass 3 — apply the dispositions in ROUTE order, so `ran`/`skipped`/
 `sections` and the log lines keep the ordering the single loop produced. A
 straggler is read ONE final time here, at the instant its skip would be
 written: that read, not the one after the await, is what decides a timeout.
 Exactly one disposition is written per slot, which is what keeps `ran` and
 `skipped` disjoint by construction — a recovered reviewer can never also
 appear as `timed_out`, and `mandatory_ok` (derived from `skipped`) reports
 what actually happened rather than what the ceiling guessed.
```

## temperloop#2003 — the CEILING BREACH. This reviewer is abandoned, neve
<a id="temperloop-2003-the-ceiling-breach-this-reviewer-is-abandone"></a>

```text
 temperloop#2003 — the CEILING BREACH. This reviewer is abandoned, never
 killed: the runtime offers no cancellation, so the promise is simply
 never awaited again and the pass proceeds. The note names the cause, so
 an operator reading the PR body sees a bounded outcome rather than the
 silence the incident actually produced. Disposition splits
 mandatory-vs-advisory below: this is the ADVISORY half (a degraded
 notice + a `mandatory_ok`-preserving tally entry); a MANDATORY route
 additionally ESCALATES after the loop.

 TEMPERLOOP#2064 — WHY THIS LINE NO LONGER SAYS "unavailable". It used to,
 to match the documented `skipped — <agent> unavailable` shape
 (CLAUDE.kernel.md § Subagent usage, legible agent-gate degradation) —
 but in that rule `unavailable` is the CAPABILITY-PROBE verdict: the
 agent is not declared in `CLAUDE.md § Subagents` or `.claude/agents/`,
 so it could not be spawned at all. A ceiling breach is the OPPOSITE
 fact: the agent IS installed and WAS spawned, and did not return in
 time. Conflating them sent the #2064 investigator at the agent roster
 while the defect sat one layer below, in the timer — and cost a live
 session ~1200s of apparent hang. disposeReviewSlot() still emits the
 true capability-probe form for the real thing (an agent-resolution
 failure), so the two senses now carry two distinct wordings, which is
 what makes either of them diagnostic. The duration reported is the tick
 this pass actually HONOURED, never the nominal ceiling: when those two
 numbers disagree, that gap IS the bug (#2064 measured 41s against 1200s).
```

## EXHAUSTIVE on purpose. `disposeReviewSlot()` returns exactly two shape
<a id="exhaustive-on-purpose-disposereviewslot-returns-exactly-two-"></a>

```text
 EXHAUSTIVE on purpose. `disposeReviewSlot()` returns exactly two shapes
 today, and falling through on anything else would launder a future third
 kind into `ran` with an `undefined` .text — a reviewer reported as having
 run, carrying no findings, which is the same reads-like-a-clean-pass
 failure this whole item exists to end. Fail loudly instead.
```

## Run the project's static gate SSOT against the worker's work. ABSENT (
<a id="run-the-project-s-static-gate-ssot-against-the-worker-s-work"></a>

```text
 Run the project's static gate SSOT against the worker's work. ABSENT (the
 script doesn't exist, e.g. foundation itself) → skip. FAIL → escalate
 (do NOT push a known-red branch). The executor synthesizes GATE_PASS /
 GATE_FAIL / GATE_ABSENT so the .mjs branches on a closed outcome.
 temperloop#1241: SCRUB the pipeline's own build.config.sh settings from the
 gate's environment before running the suite. Under pipeline-drive the session
 exports ~40 build.config.sh settings; the config-precedence tests the gate runs
 (test_config.sh / test_stranger_config.sh / test_pipeline_cron.sh) assert layer
 precedence (env > machine-conf > repo-local > tracked-default), so an
 inherited setting wins the env layer and false-FAILs a change CI's `checks`
 passes green. `build-config-settings.sh` prints the (SSOT-derived) setting names;
 unsetting them makes the gate hermetic — tracked defaults, matching CI.
 temperloop#2142: A FAILING SCRUB MUST NEVER STOP THE GATE FROM RUNNING. The
 scrub is best-effort environment hygiene, so its failure is not evidence the
 branch under test is broken — yet, chained under `&&`, its exit status decides
 whether quality-gates.sh runs at all. When it short-circuits, no
 QUALITY_GATES_FAILED=/QUALITY_GATES_RESUME_AT= trailer is printed, `${__f:-1}`
 floors to 1, and §3e.5 escalates `acceptance-gate-failed` — "this branch is
 broken" — on a tree whose gates never executed.

 The INSTANCE that bit: a missing/older helper prints NOTHING, and a bare
 `unset $(…)` resolving to zero arguments is a silent no-op in bash but rc=1 in
 zsh ("not enough arguments") — and the executor's Bash tool is zsh on macOS,
 the same dialect premise the PIPESTATUS note relies on (temperloop#801). That
 is the STRANGER case: every consuming repo on an older vendored toolkit.

 `__qg_noop` alone closes only that one path, and a fix scoped to one instance
 is a smell (kernel § Fix the real problem, not the symptom). The CLASS is ANY
 failing `unset`, and it has three members — MEASURED, not reasoned about,
 against bash 5 and zsh 5.9:
   zero arguments        bash: no-op, rc=0      zsh: rc=1, CATCHABLE
   invalid parameter name  bash: rc=1           zsh: FATAL — kills the shell
   readonly parameter      bash: rc=1           zsh: FATAL — kills the shell
 The zsh "FATAL" rows are the finding that shaped the form below: a fatal
 parameter error is NOT an exit status, so `||`, `;`, a brace group and a
 function wrapper are all powerless against it (all four measured). Only a
 SUBSHELL contains it. So the scrub is three layers, each closing one row:
   1. `grep -E '^[A-Za-z_][A-Za-z0-9_]*$'` drops anything that is not a shell
      NAME before `unset` ever sees it — closes the invalid-name row at source,
      including the day this helper's name parser is loosened.
   2. A PROBE in a subshell: if unsetting this name set would kill the shell
      (the readonly row), it kills the throwaway subshell instead and the real
      scrub is skipped. Hygiene is forfeited for that run; the gate still runs,
      which is the correct trade for a best-effort scrub.
   3. `{ … || :; }` swallows whatever status survives, in a brace group rather
      than a `;` terminator so `cd`'s OWN rc stays in the chain — a failed `cd`
      must still stop the gate from running against the wrong tree.
 `unset -v` restricts the scrub to VARIABLES so bash cannot fall through to
 unsetting a same-named function; `-v` is accepted by bash, zsh and sh.
 `__qg_noop` stays: it costs nothing and is what the K2142 guard anchors on.
 The helper runs twice (probe + real) because the probe's effects cannot escape
 its subshell; it is one short bash fork against a gate slice measured in
 minutes. Sibling scrub sites (workflows/scripts/count-prose.sh,
 workflows/scripts/build/tests/test_build_config_settings.sh) carry the same
 shape. The K2142 guard scans THIS FILE only, so the repo-wide static lint that
 would enforce the rule everywhere is temperloop#2157, not shipped here.
```

## RELAY ONLY THE DATA ROWS (temperloop#1982 round 3). The field crosses
<a id="relay-only-the-data-rows-temperloop-1982-round-3-the-field-c"></a>

```text
 RELAY ONLY THE DATA ROWS (temperloop#1982 round 3). The field crosses a
 machinery-executor agent, which is specified to return the command's JSON
 line verbatim and has instead been observed omitting this one field
 outright, and once replacing it with an English sentence describing the
 table ("The reviewer-routing.tsv file contains 11 data rows routing files
 to review subagents…"). Rounds 1 and 2 added receiving-end checks — a row
 count, then a position-weighted checksum — which detect the substitution
 but cannot prevent it: no check on this side stops a model on the other
 side from paraphrasing. What CAN be reduced is the bait. The raw file is
 3,834 bytes of which 699 are data (11 rows); the other 82% is comment
 prose, i.e. the executor was being handed ~4KB of mostly-English text and
 asked to echo it. Sending `rowFilterAwk`'s output instead ships only the
 rows the routing decision actually reads.

 Invariant-neutral by construction, which is why this needs no JS or test
 change: BOTH receiving-end readers already apply this same filter before
 they compute anything — parseTsvRows() drops blank/`#` lines, and
 tsvChecksum() canonicalises with the identical trimmed-emptiness rule —
 so filtering here is idempotent and every gap check yields the same value
 it did on the unfiltered text. The filter itself is `rowFilterAwk`, the
 SAME expression the checksum below already uses, so this adds no second
 implementation of the row rule to drift against.

 MITIGATION, NOT A PROOF: a model can still paraphrase 699 bytes. The
 structural fix — keeping the table out of the relay entirely, or emitting
 parsed rows the executor has no prose reading of — stayed open on #1982
 and is closed HERE (temperloop#2020, second half): the field is no longer
 a `tsv` SCALAR holding a multi-line table, it is `tsv_lines`, a JSON
 ARRAY OF ROW STRINGS built by the SAME
 `jq -R -s -c 'split("\n") | map(select(length>0))'` idiom `files_json`
 above already uses. The shape is chosen on evidence, not taste: across
 every observed mangling (#1976 wf_cbc556f5-7be; #1982's three shapes;
 #2020's own foundation#1869 reproduction, where BOTH retry agents
 dropped it identically) `files` — a jq array of strings produced by this
 exact idiom — arrived INTACT in the same JSON line whose `tsv` blob was
 dropped, paraphrased, or double-encoded. An array of short opaque row
 strings offers no English reading to paraphrase into and no "quote the
 table" framing to re-encode; a ~700-byte tab-delimited blob offers both.

 Invariant-neutral for the SECOND time by construction: the array's rows
 joined on `\n` are byte-identical to the string this used to emit (see
 reviewDiffTsvText), so `tsv_rows`, `tsv_checksum`, parseTsvRows() and
 tsvChecksum() all yield exactly the values they did before — the
 #1976/#1982 gap checks are untouched DETECTORS, not weakened ones.
 `tsv` itself is no longer emitted; the reader still ACCEPTS it
 (reviewDiffTsvText) so a relay or caller that yields the legacy scalar
 keeps routing rather than degrading.
```

## See the STEP_CEILING_SECS block above for WHY the bound lives in the e
<a id="see-the-step-ceiling-secs-block-above-for-why-the-bound-live"></a>

```text
 See the STEP_CEILING_SECS block above for WHY the bound lives in the emitted
 shell rather than in this file's control flow (no Date.now(), no timer, and
 the layer that failed to fire IS the tool-timeout layer). These three helpers
 are the HOW.

 stepBoundPreamble(slowSecs) — the prologue every bounded command carries: the
 two budgets as plain shell variables, then `__lb`, which runs ONE step body
 under them. `__lb` is the dependency-free fallback tier of
 `workflows/scripts/lib/portable-timeout.sh`, reproduced here (that library's
 preferred `timeout`/`gtimeout` backends `exec` a BINARY and cannot run a shell
 FUNCTION, which is what a step body is). Two details are load-bearing and both
 come straight from that file's header:
   • the watchdog subshell is redirected AT THE SUBSHELL BOUNDARY
     (`) </dev/null >/dev/null 2>&1 &`). Without it, its `sleep` grandchild
     inherits the caller's `$( … )` pipe write-end and every FAST, successful
     step stalls for the full ceiling waiting on EOF (foundation #861).
   • the watchdog is killed AND reaped on the fast path, so a completed step
     leaves nothing behind.
 The kill is best-effort DEEP: direct children first (`pkill -P`, so the helper
 script dies before the subshell that owns it), then the subshell itself. A
 deeper grandchild (a `gh` inside a `pr.sh`) can still outlive the bound — which
 is exactly why a timed-out step is disposed through the recover-probe rather
 than blind-retried: the workflow stops WAITING on it without ever assuming it
 did nothing.

 The step body's own stdout is untouched — it flows to wherever the caller put
 it (a `$( … )` capture in a batch, the script's stdout for a solo call), so the
 machinery's "one JSON line per step" contract is preserved byte for byte on
 every healthy run. `__lb` only ADDS a line, and only in the two abnormal cases:
 STEP_TIMEOUT (replacing a result the kill destroyed) and STEP_SLOW (an advisory
 riding alongside a real result — hence `slowSecs` is 0 on the SOLO path, whose
 schema admits exactly one object).
```
