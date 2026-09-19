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

> **Part 1 of 6.** Split to stay under the per-file prose cap
> (`PROSE_BUDGET_TIER2_FILE_CAP`). Other parts: [`build-level.design-notes-2.md`](build-level.design-notes-2.md), [`build-level.design-notes-3.md`](build-level.design-notes-3.md), [`build-level.design-notes-4.md`](build-level.design-notes-4.md), [`build-level.design-notes-5.md`](build-level.design-notes-5.md), [`build-level.design-notes-6.md`](build-level.design-notes-6.md).

## `meta` MUST be a PURE literal — no vars, calls, or spreads (runtime co
<a id="meta-must-be-a-pure-literal-no-vars-calls-or-spreads-runtime"></a>

```text
 `meta` MUST be a PURE literal — no vars, calls, or spreads (runtime constraint).
 Consequence (temperloop#903): `description` can NEVER carry run context — it is
 the same bytes on every run. So it is written for the operator as a plain
 statement of what the run DOES, deliberately WITHOUT asserting a scope (a
 "level") or a single caller: this script is invoked by THREE commands —
 /build (a full dependency level), /fix (a 1-item level), and /sweep (a
 chunk of singleton issues) — and a description that named only one of them,
 or asserted a single dependency-level scope, would misdescribe the other
 two invocations byte-for-byte identically (temperloop#1941 — the /fix and
 /sweep launch/completion lines used to inherit build's level-scoped wording
 on runs that drove neither a level nor a dependency edge). The
 run-IDENTIFYING half (caller, repo, items, issues, round) rides two
 dynamic surfaces instead:
 the phase() title — see levelPhaseTitle() near the entry point, emitted
 ONCE PER STAGE (temperloop#1294) — and, pushed unconditionally rather than
 left to the opt-in `/workflows` surface, the orchestrator's own Workflow
 launch/return line printed immediately around every invocation of this
 script (`claude/message-schema.md` §§ Workflow launch line / Workflow
 return line; `claude/commands/build.md` Step 3 + 3d-esc, `fix.md` Step 4a,
 `sweep.md` Phase 2). The optional `phases` key is deliberately ABSENT from
 this literal: meta.phases entries are matched against phase() titles
 EXACTLY, and every title this workflow emits is dynamic, so a static entry
 could only ever render an empty duplicate group. See the levelPhaseTitle
 block for the full reasoning. Return shape, the never-merges rule and
 the never-writes-the-plan-note rule are contract detail and live in the I/O
 CONTRACT block above; do not re-state them here.
```

## temperloop#2080 — the dual-build descriptor { tier, baseline, candidat
<a id="temperloop-2080-the-dual-build-descriptor-tier-baseline-cand"></a>

```text
 temperloop#2080 — the dual-build descriptor { tier, baseline, candidate,
 inScope: [slug…] }. ADDITIVE like every key here: absent means the
 single-arm path, unchanged. Its staleness cost is the sharpest on this
 list, which is exactly why it is declared: an engine without it ignores
 the key and builds the level ONCE while the orchestrator reports a
 two-model comparison that never happened.
```

## SPINE_OUTCOME_SCHEMA — one permissive object keyed on `outcome` (the u
<a id="spine-outcome-schema-one-permissive-object-keyed-on-outcome-"></a>

```text
 SPINE_OUTCOME_SCHEMA — one permissive object keyed on `outcome` (the union of
 every machinery script's closed set) plus passthrough fields. The .mjs branches
 on `.outcome` exactly as each script's header documents. Permissive on the
 passthrough so one schema covers worktree.sh / pr.sh / ci-poll.sh /
 quality-gates / claim outcomes without a per-script schema.
```

## PUSHED_UNWATCHED (temperloop#1688): the push LANDED, but on a ref no
<a id="pushed-unwatched-temperloop-1688-the-push-landed-but-on-a-re"></a>

```text
 PUSHED_UNWATCHED (temperloop#1688): the push LANDED, but on a ref no
 open PR references while a sibling PR for the same slug sits on a
 DIFFERENT head ref. NOT a push failure — a report about WHERE it
 landed, so a caller must never re-push believing nothing happened,
 and never route it through the lost-return probe (the result line was
 not lost; it says something specific).
```

## The 3e.5 acceptance gate. GATE_SLICE / GATE_TIMEOUT are temperloop#102
<a id="the-3e-5-acceptance-gate-gate-slice-gate-timeout-are-temperl"></a>

```text
 The 3e.5 acceptance gate. GATE_SLICE / GATE_TIMEOUT are temperloop#1021:
 a budget-exhausted run is its OWN outcome and must never collapse into
 GATE_FAIL — GATE_SLICE says "budget spent, gates remain, resume at
 resumeAt"; GATE_TIMEOUT says "the executor's Bash tool killed the run
 before it could report", which is a BUDGET fact, not evidence about the
 tree. Collapsing either into GATE_FAIL is what made an escalation
 payload indistinguishable from real breakage.
```

## The §3e.5 PRE-gate freshness/rebase step (temperloop#1937): brings
<a id="the-3e-5-pre-gate-freshness-rebase-step-temperloop-1937-brin"></a>

```text
 The §3e.5 PRE-gate freshness/rebase step (temperloop#1937): brings
 the worktree up to current origin/main before the gate runs, so an
 origin/main-ratcheted validator never false-fails on rows main
 gained after this worktree's base was cut. NO_GATE (round 3, HIGH)
 means the worktree carries no `scripts/quality-gates.sh` at all —
 the same presence check gateCmd's own GATE_ABSENT arm makes — so
 there is nothing for this step to protect and it takes the
 byte-identical pre-change path with no fetch/rebase attempted.
 CURRENT/REBASED are the two non-blocking outcomes (proceed to the
 gate); DIRTY (round 2, HIGH) means git refused to even start the
 rebase over uncommitted tracked-file edits, probed BEFORE the
 rebase and escalated as `dirty-worktree`, never misread as a
 conflict; CONFLICT means the rebase hit a real clash and was
 aborted (worktree left intact, escalates `stale-worktree` — the
 gate never runs); REBASE_ERROR (round 3, MEDIUM) is a rebase
 failure with NO conflicted files (a pre-rebase hook, a missing
 identity, a leftover in-progress rebase) — never misreported as
 CONFLICT's empty-list false positive, its own not-a-conflict
 outcome carrying git's own output tail; ERROR is a fail-open
 (fetch/resolve itself could not run; proceed on the tree as-is,
 exactly the pre-#1937 behavior); TIMEOUT (round 2, MEDIUM) is the
 OUTER Bash-tool kill mid-fetch/rebase — never fail-open, always
 routed through a follow-up abort-and-probe before escalating
 `stale-worktree`. TIMEOUT_PROBE(_ERROR) are that follow-up probe's
 own closed outcomes.
```

## The 3e.6 class-A activation gate (temperloop#1219). ACTIVATION_PASS /
<a id="the-3e-6-class-a-activation-gate-temperloop-1219-activation-"></a>

```text
 The 3e.6 class-A activation gate (temperloop#1219). ACTIVATION_PASS /
 ACTIVATION_FAIL are the `proof:` predicate's own exit status against
 the worker's worktree. The three CONTROL outcomes are the
 temperloop#944 merge-base control pass, run FIRST for an absence-
 asserting predicate: DISCRIMINATES (fails at the merge base — good,
 proceed to the worktree run), VACUOUS (passes at the merge base, so it
 would pass on an untouched tree and proves nothing), ERROR (the control
 could not be ESTABLISHED — an UNKNOWN, never laundered into either
 verdict, the same #1021 discipline GATE_TIMEOUT encodes).
 ACTIVATION_TIMEOUT is that same discipline for the Bash-tool timeout.
```

## The 3e pre-push review's diff/routing-data fetch (temperloop#1430).
<a id="the-3e-pre-push-review-s-diff-routing-data-fetch-temperloop-"></a>

```text
 The 3e pre-push review's diff/routing-data fetch (temperloop#1430).
 ONE outcome carrying both the changed-file list and the
 reviewer-routing.tsv text — the .mjs does the routing DECISION
 itself (DESIGN NOTE 1: branching logic stays in legible .mjs), this
 step only reads the two raw inputs off the worktree.
```

## The WORKFLOW-LEVEL step liveness bound (temperloop#1071). Neither of
<a id="the-workflow-level-step-liveness-bound-temperloop-1071-neith"></a>

```text
 The WORKFLOW-LEVEL step liveness bound (temperloop#1071). Neither of
 these comes from a machinery script — both are emitted by the shell
 watchdog THIS file wraps every machinery step in (see
 stepBoundPreamble()). STEP_TIMEOUT: the step outlived
 STEP_CEILING_SECS and was killed, so its result is LOST (never
 "failed" — the ceiling says nothing about the work, exactly as
 GATE_TIMEOUT says nothing about the tree). STEP_SLOW: an ADVISORY
 notice riding alongside a step's real result, never a result itself —
 runMachineryBatch partitions it out and logs it.
```

## temperloop#2020 — the post-commit work-preservation push that runs
<a id="temperloop-2020-the-post-commit-work-preservation-push-that-"></a>

```text
 temperloop#2020 — the post-commit work-preservation push that runs
 at the ONE escalation choke point (preserveOnEscalation). Three
 outcomes, deliberately distinct so a payload never has to infer
 which: WORK_PRESERVED (the branch is on origin), WORK_PRESERVE_SKIP
 (there was PROVABLY nothing to preserve — no worktree, or a RESOLVED
 default branch with no commit ahead of it; an unresolvable base is
 never a skip, it pushes), WORK_PRESERVE_FAILED (there WAS unlanded work
 and the push did not land it — the one shape that must stay visible,
 because a later `worktree.sh remove` is then the last copy's last
 chance).
```

## temperloop#2065 "worker-cost-capture" — the per-item WORKER COST
<a id="temperloop-2065-worker-cost-capture-the-per-item-worker-cost"></a>

```text
 temperloop#2065 "worker-cost-capture" — the per-item WORKER COST
 seam. Neither comes from a machinery script proper; both are
 workflows/scripts/build/worker-usage.sh, the SAME emitted-shell
 pattern review-wait.sh established for giving this runtime a
 wall-clock tick it otherwise has none of. WORKER_CLOCK is a bare
 `date` read (no side effect); WORKER_USAGE is that same reading
 PLUS the durable per-seat attribution write (model-usage-
 envelope.sh's model_usage_emit_from_envelope, seat "build-worker" —
 see that file's own header). See workerClockNow()/workerUsageEmit().
```

## temperloop#2049 — the §3e timer's own MEASURED wait, emitted by
<a id="temperloop-2049-the-3e-timer-s-own-measured-wait-emitted-by"></a>

```text
 temperloop#2049 — the §3e timer's own MEASURED wait, emitted by
 review-wait.sh after the interval genuinely elapsed. Declared here (not
 left to `additionalProperties`) because reviewWaitAgent() BRANCHES on it:
 a REVIEW_WAIT_ELAPSED without a realized_secs that reaches the interval
 is not honoured as elapsed. `secs` rides alongside it as the echo of what
 was asked, so the two can be compared.
```

## temperloop#2064 — the harness's OWN words when it REFUSED the timer
<a id="temperloop-2064-the-harness-s-own-words-when-it-refused-the-"></a>

```text
 temperloop#2064 — the harness's OWN words when it REFUSED the timer
 command, relayed verbatim (first line). Declared rather than left to
 `additionalProperties` because reviewWaitAgent() CLASSIFIES on it: a
 refusal is recognised from this text before the executor's own outcome
 label is consulted, so a block mislabelled as a tool timeout can never
 reach the permissive arm.
```

## temperloop#2065 — worker-usage.sh's WORKER_CLOCK/WORKER_USAGE fields.
<a id="temperloop-2065-worker-usage-sh-s-worker-clock-worker-usage-"></a>

```text
 temperloop#2065 — worker-usage.sh's WORKER_CLOCK/WORKER_USAGE fields.
 Declared (not left to `additionalProperties`) because
 workerClockNow()/workerUsageEmit() BRANCH on them: a non-numeric
 epoch_s or a non-numeric token count degrades to null rather than
 being coerced, exactly like every other machinery passthrough here.
```

## temperloop#2020: the routing table's DATA ROWS as an array of strings
<a id="temperloop-2020-the-routing-table-s-data-rows-as-an-array-of"></a>

```text
 temperloop#2020: the routing table's DATA ROWS as an array of strings —
 the shape reviewDiffCmd emits today, chosen because this exact jq
 array-of-strings idiom (`files` above) survived every relay mangling
 that dropped, paraphrased or double-encoded the `tsv` scalar. See
 reviewDiffCmd's own comment for the evidence and reviewDiffTsvText for
 the reader.
```

## temperloop#1970: how many §3e review rounds this worktree has ALREADY
<a id="temperloop-1970-how-many-3e-review-rounds-this-worktree-has-"></a>

```text
 temperloop#1970: how many §3e review rounds this worktree has ALREADY
 run, read (and then bumped) by reviewDiffCmd from a marker in the
 worktree's own git dir. The REVIEW_BLOCKING convergence bound reads it;
 absent/unparseable means 0 (an older machinery relay, or a worktree
 predating the marker) — i.e. exactly today's unbounded first round.
```

## `'null'` IS LOAD-BEARING HERE, not defensive padding (temperloop#1698,
<a id="null-is-load-bearing-here-not-defensive-padding-temperloop-1"></a>

```text
 `'null'` IS LOAD-BEARING HERE, not defensive padding (temperloop#1698,
 review round 2). The gate emitter below deliberately prints a bareword
 `null` when the elapsed figure is unreadable — that IS the fix: an
 unknown duration must degrade to "I don't know", never to a plausible
 `0`. This object is what `agent({schema})` validates the executor's
 returned line against, so leaving `null` out of the type array would
 reject (or silently coerce) the ONE shape the fix exists to produce —
 reintroducing the same degrade-to-a-believable-value defect one layer
 up, on the path that only fires when the figure is already unknown.
 Same precedent as `input_tokens` / `output_tokens` above, declared
 `['number', 'null']` for exactly this reason. Kept honest by the K1698
 producer↔schema case in test_workflow.sh, which runs the REAL emitted
 shell fragment and validates the REAL line it prints against THIS object
 rather than against an injected outcome object.
```

## temperloop#2094: the gate slice's own exit status. It is a FACT the
<a id="temperloop-2094-the-gate-slice-s-own-exit-status-it-is-a-fac"></a>

```text
 temperloop#2094: the gate slice's own exit status. It is a FACT the
 ledger carries, never the classifier's input — a slice that printed a
 resume-point trailer is a PARTIAL slice whatever code it exited with
 (see gateCmd's own comment), and this field is what makes an anomalous
 code visible in the escalation instead of silently re-labelling the
 slice.
```

## temperloop#1698 — these three are the NON-canonical (wire) spelling: t
<a id="temperloop-1698-these-three-are-the-non-canonical-wire-spell"></a>

```text
 temperloop#1698 — these three are the NON-canonical (wire) spelling: the
 emitted `__lb` shell prints them, so the schema must keep admitting them
 or the bound's own STEP_TIMEOUT would fail validation. They are
 canonicalized to `ceilingSecs` / `elapsedSecs` / `slowSecs` by
 canonicalizeOutcome() at the transport boundary, and NO consumer in this
 file reads a snake_case duration key any more. The camelCase twins are
 declared alongside so an emitter that already speaks canonical (the 3e.5
 gate does, for `elapsedSecs`/`budgetSecs` above) validates unchanged.
```

## STEP_OUTCOME_SCHEMA — one element of a BATCH's results array (temperlo
<a id="step-outcome-schema-one-element-of-a-batch-s-results-array-t"></a>

```text
 STEP_OUTCOME_SCHEMA — one element of a BATCH's results array (temperloop#942).
 Same permissive shape as SPINE_OUTCOME_SCHEMA (whose `properties` it reuses
 verbatim — #543's "do NOT touch SPINE_OUTCOME_SCHEMA" still holds; this derives
 from it, it does not mutate it) with two differences:
   - `outcome` is NOT required, because one batched step is the read-only
     merge-state probe (`gh pr view --json mergeable,mergeStateStatus`), whose
     object carries no `outcome` key at all. When `outcome` IS present the
     closed enum still applies.
   - the merge-state fields are declared so the .mjs can branch on them.
```

## WORKER_VERDICT_SCHEMA — matches build.md §3c's return contract. The
<a id="worker-verdict-schema-matches-build-md-3c-s-return-contract-"></a>

```text
 WORKER_VERDICT_SCHEMA — matches build.md §3c's return contract. The
 worker owns only these fields (never branch/pr/pushed_sha — orchestrator-
 owned). `status` is a closed enum, 1:1 with the 3d handling branches.

 Output shape (temperloop#1080): the `description` on each free-prose field
 states what that field is FOR, so the shape rule reaches the worker on the
 schema surface too, not only in the prompt. Deliberately NO word numbers
 here — a JSON schema cannot enforce a string length, so the numeric bounds
 live in exactly one place (the WORKER_*_MAX_WORDS constants, interpolated
 into the prompt's `## Output shape` section) rather than being restated in a
 second surface that could drift. The two surfaces are complementary: the
 schema fixes the SHAPE (machine-validated), the prompt fixes the SIZE.
```

## BATCH_BASH_TIMEOUT_MS — the FAST batches (prelude, pr-batch). Every st
<a id="batch-bash-timeout-ms-the-fast-batches-prelude-pr-batch-ever"></a>

```text
 BATCH_BASH_TIMEOUT_MS — the FAST batches (prelude, pr-batch). Every step there
 is a seconds-scale git/gh call, so 5 minutes is generous and far inside the
 cap. (Each of these commands previously ran alone under the Bash tool's 120s
 DEFAULT; batching several into one invocation would otherwise creep up on it,
 so the timeout is made explicit rather than inherited.)
```

## CI_POLL_MAX_BATCH_WALL_MS / CI_POLL_SLICES_PER_BATCH — DESIGN NOTE 2's
<a id="ci-poll-max-batch-wall-ms-ci-poll-slices-per-batch-design-no"></a>

```text
 CI_POLL_MAX_BATCH_WALL_MS / CI_POLL_SLICES_PER_BATCH — DESIGN NOTE 2's cap
 invariant, expressed as arithmetic instead of a comment. A ci-batch may occupy
 at most CI_POLL_MAX_BATCH_WALL_MS of POLLING in one Bash invocation; the number
 of CI_POLL_SLICE_SECS slices it runs is derived from that, so retuning the
 slice length can never produce a batch that outlives the agent's Bash cap
 (a 600s slice would simply yield 1 slice per batch).
```

## GATE_SLICE_OVERRUN_MS — the budget is checked only BETWEEN gates, so a
<a id="gate-slice-overrun-ms-the-budget-is-checked-only-between-gat"></a>

```text
 GATE_SLICE_OVERRUN_MS — the budget is checked only BETWEEN gates, so a slice's
 real wall time is its budget PLUS however long the gate that crossed it takes
 to finish, plus process startup. This is the headroom for that tail; it is what
 keeps the emitted Bash-tool timeout an outer BACKSTOP rather than the thing
 that routinely fires.
```

## FLOOR — a ceiling below the longest LEGITIMATE wait would manufacture 
<a id="floor-a-ceiling-below-the-longest-legitimate-wait-would-manu"></a>

```text
 FLOOR — a ceiling below the longest LEGITIMATE wait would manufacture false
 timeouts on healthy work, which is strictly worse than the stall it bounds.
 The reference length for "one legitimate long-running unit of this pipeline"
 is one CI-poll slice or one 3e.5 gate slice, so the floor is the larger of the
 two and no operator value can go under it. Derived, never typed twice —
 retuning either slice length carries here automatically.
```

## The SLOW threshold is advisory, so it only needs to be sane: non-negat
<a id="the-slow-threshold-is-advisory-so-it-only-needs-to-be-sane-n"></a>

```text
 The SLOW threshold is advisory, so it only needs to be sane: non-negative (0
 disables the notice) and never at/above the ceiling, where it could never
 fire. The explicit blank check is NOT redundant with the `> 0` form used
 above: 0 is a MEANINGFUL value here (disable), and `Number('')` is 0 — so an
 orchestrator that resolves an unset setting to "" would otherwise silently
 disable the notice instead of landing on the in-file default. Same
 empty-vs-absent hazard STEP_SLOW_SECS spells out, for the same reason.
```

## The longest single `sleep` one timer executor may hold: the Bash tool'
<a id="the-longest-single-sleep-one-timer-executor-may-hold-the-bas"></a>

```text
 The longest single `sleep` one timer executor may hold: the Bash tool's own
 hard cap less headroom for process startup and the executor's own turn. A
 longer wait is SLICED across several timer spawns rather than asking one Bash
 invocation to outlive the cap — the same arithmetic-not-comment discipline
 CI_POLL_SLICES_PER_BATCH uses. It also stays under STEP_CEILING_FLOOR_SECS, so
 the #1071 watchdog wrapped around every machinery command never kills a timer
 that is doing exactly what it was asked to do.
```

## reviewWaitSlices() — the wait, expressed as the sequence of sleeps tha
<a id="reviewwaitslices-the-wait-expressed-as-the-sequence-of-sleep"></a>

```text
 reviewWaitSlices() — the wait, expressed as the sequence of sleeps that reach
 first the SLOW mark and then the CEILING. Deriving it from the two marks (not
 from a fixed slice length) is what keeps the timer CHEAP: a healthy pass that
 finishes inside the slow threshold pays for exactly ONE timer spawn, and a
 genuinely hung one pays a handful — never one spawn per poll interval, the
 micro-agent cost temperloop#942 exists to prevent.
```

## FLOOR — a ceiling below the longest LEGITIMATE single step would manuf
<a id="floor-a-ceiling-below-the-longest-legitimate-single-step-wou"></a>

```text
 FLOOR — a ceiling below the longest LEGITIMATE single step would manufacture
 false timeouts on healthy work, which is strictly worse than the stall it
 bounds. The longest legitimate step is one CI poll slice or one gate slice, so
 the floor is the larger of the two plus headroom; no operator value can go
 under it. (Derived, never typed twice — retuning either slice length carries.)
```

## The SLOW threshold is advisory, so it only needs to be sane: non-negat
<a id="the-slow-threshold-is-advisory-so-it-only-needs-to-be-sane-n-2"></a>

```text
 The SLOW threshold is advisory, so it only needs to be sane: non-negative (0
 disables the notice) and never at/above the ceiling, where it could never fire.
 The explicit blank check is NOT redundant with the `> 0` form used above: 0 is
 a MEANINGFUL value here (disable), and `Number('')` is 0 — so an orchestrator
 that resolves an unset setting to "" would otherwise silently disable the
 notice instead of landing on the in-file default. Same empty-vs-absent hazard
 the model settings' `||` guards, spelled out because `>= 0` cannot collapse it.
```

## GATE_RESUME_EXTENSIONS (temperloop#2135, split from #2130) — how many
<a id="gate-resume-extensions-temperloop-2135-split-from-2130-how-m"></a>

```text
 GATE_RESUME_EXTENSIONS (temperloop#2135, split from #2130) — how many
 EXTRA allotments of the SAME GATE_MAX_SLICES ceiling the loop below grants
 itself before it finally gives up, but ONLY while the suite has produced
 ZERO observed failures. A clean slice-budget exhaustion with `failed: 0`
 is not a stuck gate — quality-gates.sh is still reporting real forward
 progress (a fresh resume index every slice); it is a suite that outgrew
 ONE allotment of the existing per-loop ceiling. #2130's own evidence is
 what a full worker re-spawn costs to merely re-verify nothing broke
 (~0.5M subagent tokens, 30-50 minutes) against what ANOTHER allotment of
 pure machinery-only slicing costs (no agent spawn at all) — so extending
 is cheap where escalating is not. The multiplier is not invented: the
 #1663 scoping comment above (§3e.5, "WHY") already measured contention
 inflating the gate tail 200-300% on a 3-item concurrent level, i.e. up to
 ~3x a clean run's slice count — two extensions gives a total of 3x
 GATE_MAX_SLICES, matching that already-observed worst case exactly. A
 suite that STILL has not finished after 3x the original ceiling, with
 zero failures the whole way, is genuinely the "looped on forever" case
 GATE_MAX_SLICES's own comment above warns about, and escalates exactly as
 before — see the dynamic ceiling in the 3e.5 slice loop below.
```

## 3c worker return-value output-shape bounds (temperloop#1080)
<a id="3c-worker-return-value-output-shape-bounds-temperloop-1080"></a>

```text
 --- 3c worker return-value output-shape bounds (temperloop#1080) ------------
 The verdict's SHAPE is already machine-enforced (WORKER_VERDICT_SCHEMA below,
 passed to every worker agent({schema}) call) — but a JSON schema can constrain
 a field's TYPE and never its LENGTH, so the two free-prose slots were bounded
 by nothing but the worker's judgment. Measured across 83 real /build worker
 verdicts recovered from subagent transcripts: `summary` ran to a median 119
 words (mean 145, max 557) against a spec asking for "1-3 sentences", and each
 `acceptance_results[].evidence` to a median 33 words (max 244) against a spec
 asking for "<file:line or test name>". Every one of those words is an OUTPUT
 token — the weight-5 class, the most expensive token this pipeline emits — and
 the orchestrator then ingests all of them.

 The bound is NOT information loss, and that is the whole reason it is safe:
 the worker already writes its full argument to `.build-verification.md`, a
 FILE whose path (not content) rides the verdict, and pr.sh splices that file
 into the PR body's `## Verification` section by path (`--verification-surface-
 file`) so it reaches the human reviewer WITHOUT ever entering orchestrator
 context. Bounding the verdict moves prose off the expensive path; it does not
 delete it. What must NOT survive anywhere is process narration — the worker's
 route to the answer ("first I read X, then ruled out Y") is not a finding.

 NAMED SETTINGS (BUILD_WORKER_SUMMARY_MAX_WORDS / BUILD_WORKER_EVIDENCE_MAX_
 WORDS), handed in by the orchestrator at Step 0 exactly like GATE_SLICE_SECS
 above — the Workflow runtime has no shell to source build.config.sh itself
 (DESIGN NOTE 1). `||`, not `??`, for the documented empty-string reason. A
 caller that omits the keys (sweep.md / fix.md today) still emits a BOUNDED
 prompt: the shape is inherited by every caller of the shared workerPrompt(),
 only the tuning is build.md's.
```

## Kill ORDER is load-bearing, and the obvious order is wrong. Killing th
<a id="kill-order-is-load-bearing-and-the-obvious-order-is-wrong-ki"></a>

```text
 Kill ORDER is load-bearing, and the obvious order is wrong. Killing the
 step's children FIRST unblocks the step body — which then races ahead and
 runs its NEXT command (printing a result the workflow must not believe)
 before the kill of the body itself lands. Measured, not theorised: with
 children-first, a `sleep 30; printf …` step still printed its `printf`.
 So: SNAPSHOT the direct children, kill the body, THEN kill the snapshot
 (once the body dies its children reparent, and `pgrep -P` can no longer
 find them — hence the snapshot rather than a second lookup).
```

## machineryBin — resolve a build-SPINE script (worktree.sh / pr.sh / ci-
<a id="machinerybin-resolve-a-build-spine-script-worktree-sh-pr-sh-"></a>

```text
 machineryBin — resolve a build-SPINE script (worktree.sh / pr.sh / ci-poll.sh),
 which lives in the FOUNDATION repo (workflows/scripts/build/). A consuming repo
 (stageFind) normally reaches it via a dev-local `workflows/` symlink into
 foundation — but that symlink is NOT guaranteed in every checkout (#560: a
 stageFind checkout lacking it escalated at pr.sh with `push-error: script path
 does not exist`). We run in the Workflow sandbox (no fs / Node API), so the
 fallback is done in BASH, emitted as a quoted command-substitution: prefer
 <repoRoot>/workflows/scripts/build; if that dir is absent, locate the
 foundation checkout via $FOUNDATION, the deployed workflow symlink
 ($HOME/.claude/workflows/build-level.mjs → foundation, best-effort — a BSD
 readlink without -f just fails that candidate), or the TEMPERLOOP_HOME
 bootstrap-clone convention (bin/bootstrap.sh's own default,
 $HOME/.local/share/temperloop — never a hardcoded personal dev path,
 temperloop#406; the legacy FOUNDATION_HOME fallback was removed in
 v0.19.0 with the rest of the temperloop#165 window). If none resolve, the
 emitted path points at the missing
 repo-local dir and the machinery script's own "not found" (exit 127) surfaces
 loudly. NOTE:
 only machinery scripts route through here; the project's OWN vendored gate
 (scripts/quality-gates.sh) is repo-local and is resolved directly against
 the WORKTREE checkout (see 3e.5, temperloop#626), never via this fallback.
```

## THE EXECUTOR AGENT TYPE — context size is the machinery agents' cost (
<a id="the-executor-agent-type-context-size-is-the-machinery-agents"></a>

```text
 -----------------------------------------------------------------------------
 THE EXECUTOR AGENT TYPE — context size is the machinery agents' cost (#1014).
 -----------------------------------------------------------------------------
 A machinery executor's whole job is one Bash call, but a `general-purpose`
 agent carries the FULL harness surface to make it: every tool schema, the
 skill listing, the deferred-tool listing. That is dead weight on every spawn
 and it is charged TWICE for the two executors that exceed the ~300s
 prompt-cache TTL by construction — the CI poll (waiting IS its job) and the
 minutes-scale 3e.5 gate. Their post-wait call is a total cache miss: the whole
 context is re-WRITTEN at weight 1.25 instead of re-READ at 0.1, so the excess
 is proportional to CONTEXT SIZE, not to the length of the wait (#1014).

 So machinery executors run as `machinery-executor` (claude/agents/), whose
 tool surface is Bash alone (+ the runtime's own StructuredOutput, appended
 automatically when a schema is passed) and whose system prompt carries the
 standing "run it verbatim, return each step's JSON line" contract that every
 per-call prompt used to restate. Measured on this harness, same prompts, same
 machine (temperloop#1014): ci-batch 37,428 -> 30,856 first-call
 cache_creation tokens, 3e.5 gate 37,201 -> 30,734 (-17.5%). The residual is
 almost entirely the installed CLAUDE.md (measured at 25,714 tokens, identical
 under both agent types) — which the harness injects into every non-built-in
 agent and NO agent definition can decline, so it is out of this file's reach.
 Of the context this file CAN reach, the lean type removes 56%.

 FALLBACK, NOT A DEPENDENCY. A checkout that has not deployed the agent
 definition (`workflows/scripts/install/project-agents.sh`) must still build.
 agent() rejects an unresolvable (or permission-denied) agentType at RESOLUTION
 time — before any subagent is spawned, so nothing has run and re-issuing the
 call is safe — with a message naming `agent({agentType})` and the type it could
 not resolve. machineryAgent() catches exactly that shape once, pins the type to
 'general-purpose' for the rest of the run, and re-issues with the full prompt.
 Any OTHER failure propagates untouched: a blind retry of a machinery command is
 NEVER safe (push / pr-create are not idempotent), so the match is deliberately
 narrow — two independent markers of a resolution failure, never a catch-all.
 An explicit input.machineryAgentType (orchestrator-supplied) overrides the
 default and disables the probe.
```

## ONE MEANING, ONE NAME — the machinery-outcome key canonicalizer (tempe
<a id="one-meaning-one-name-the-machinery-outcome-key-canonicalizer"></a>

```text
 -----------------------------------------------------------------------------
 ONE MEANING, ONE NAME — the machinery-outcome key canonicalizer (temperloop#1698).
 -----------------------------------------------------------------------------
 The closed outcome set carries TWO names for one concept. The step-liveness
 bound (temperloop#1071) emits `elapsed_secs` / `ceiling_secs` / `slow_secs`;
 the 3e.5 gate emits `elapsedSecs` / `budgetSecs`; and the permissive
 passthrough schema admits BOTH on ANY outcome. An executor that normalizes a
 GATE_PASS toward the sibling spelling therefore produces a structurally VALID
 object that the consumer — `Number(gateOut.elapsedSecs) || 0` — reads as
 `Number(undefined) || 0` → **0**. Observed live (run wf_9ce4bd0c-58b): a gate
 whose own log said "passed in 215s" was reported as "0s of gate wall time".

 That figure is the DECAY SIGNAL — the instrument whose whole job is to make
 suite growth visible on GREEN runs, before it blows a budget (the failure
 #1021 and #1663 both exist because of). An instrument that reads zero when it
 does not know is worse than one that reads nothing.

 The fix is a single normalization at the TRANSPORT boundary rather than a
 `??` chain at each read site (which re-opens the defect for the next field):
 CANONICAL = camelCase, everywhere downstream of here. The snake_case key is
 left in place on the object — it is what the emitted shell actually prints and
 what escalation payloads echo verbatim — but no CONSUMER in this file reads it
 any more, so the two spellings can no longer disagree about one value.
```

## The STRICT numeric read this canonicalization needs — "the value, or n
<a id="the-strict-numeric-read-this-canonicalization-needs-the-valu"></a>

```text
 The STRICT numeric read this canonicalization needs — "the value, or null when
 it is absent, empty or unparseable" — already exists as numOrNull() (defined
 with the cost-ledger helpers below, hoisted, and written for exactly this
 class of defect: "a machinery field that is genuinely absent must degrade to
 null, never a false zero"). #1698's gate read below calls it rather than
 declaring a second one, so the two can never drift apart.
```

## runMachinery — the sh() replacement (spike §1).
<a id="runmachinery-the-sh-replacement-spike-1"></a>

```text
 -----------------------------------------------------------------------------
 runMachinery — the sh() replacement (spike §1).
 -----------------------------------------------------------------------------
 Spawns a one-shot executor agent that runs EXACTLY one machinery command via Bash
 and returns its single closed-outcome JSON line, schema-validated. No model
 override beyond haiku (cheapest tier — the executor does no reasoning); NO
 isolation:'worktree' (the machinery scripts manage their own worktrees, §5).
 `phase` (temperloop#1294) is the caller's STAGE group name — the string
 enterStage()/stagePhase() returned. It is passed EXPLICITLY rather than read
 off the global phase() cursor, which races under parallel(). The `?? 'machinery'`
 fallback keeps a caller that omits it on the pre-#1294 flat group rather than
 on whatever stage happens to be current.
```

## Wording (temperloop#72): describe the command as a KNOWN build-machine
<a id="wording-temperloop-72-describe-the-command-as-a-known-build-"></a>

```text
 Wording (temperloop#72): describe the command as a KNOWN build-machinery helper
 script that self-reports its result, rather than telling the sub-agent to
 "run exactly / do NOT interpret" an opaque line. The old phrasing, paired
 with the nested-readlink path resolution, read to the auto-mode safety
 classifier as an instruction to blindly execute an obfuscated command.
 BOTH framing lines stay in the LEAN prompt too: the auto-mode classifier
 sees the prompt (and the agent type), never the agent's system prompt, so
 the #72 framing is not something the executor definition can absorb.
```

## temperloop#1021: name the TIMEOUT case explicitly. NOT lean-guarded, a
<a id="temperloop-1021-name-the-timeout-case-explicitly-not-lean-gu"></a>

```text
 temperloop#1021: name the TIMEOUT case explicitly. NOT lean-guarded, and
 deliberately so: unlike the three standing lines above, this one is
 per-call (it fires only when a caller passes `timeoutOutcome`) and it
 interpolates a dynamic outcome name, so it cannot live in the static
 machinery-executor.md agent definition the lean prompt relies on.
 Without this line the executor, having been killed by the Bash tool
 before any JSON line was
 printed, picks the closest failure-shaped enum member it knows — which
 for the gate is GATE_FAIL. That silently reported a GREEN suite as
 BROKEN and made a budget-exhaustion escalation indistinguishable from a
 real gate failure. The timeout is a fact about the BUDGET, never about
 the tree, so it gets its own outcome and the executor is told to use it
 rather than guess.
```

## temperloop#982: orchestrator-supplied workflow input, NOT a config-fil
<a id="temperloop-982-orchestrator-supplied-workflow-input-not-a-co"></a>

```text
 temperloop#982: orchestrator-supplied workflow input, NOT a config-file
 read (this runtime has no shell — DESIGN NOTE 1). `||`, NOT `??` —
 `??` only falls through on null/undefined, and a caller (or an
 omitted-vs-empty prose mistake upstream) can easily hand this an
 empty string, which `??` would pass straight through as a literal
 "" model and silently defeat the fallback. `||` collapses BOTH the
 absent-input case (build.md didn't resolve BUILD_MACHINERY_SOLO_MODEL,
 or the key was omitted) AND an empty-string input to the same
 'haiku' default — UNCHANGED from before this setting existed, the
 byte-identical-when-unset contract this item ships under. This is the
 load-bearing invariant; it lives here (the consumer), not in the
 orchestrator prose (the producer), so it holds regardless of how
 build.md/sweep.md/fix.md construct the input.
```

## Null-guard (temperloop#72): agent() returns null when the run is DENIE
<a id="null-guard-temperloop-72-agent-returns-null-when-the-run-is-"></a>

```text
 Null-guard (temperloop#72): agent() returns null when the run is DENIED by
 the auto-mode safety classifier (or a user skip / transient API error).
 Every consumer below dereferences `.outcome`, so a raw null crashed the
 whole level with `null is not an object`. Normalize it to a closed
 SPINE_DENIED sentinel — a well-formed outcome object every call site can
 detect (via machineryDenied()) and turn into a parkable `machinery-denied`
 escalation instead of a TypeError.
 temperloop#1698 — canonicalize the duration keys ONCE, here at the
 transport boundary, so every consumer below reads exactly one spelling.
```

## runMachineryBatch — the BATCHED sh() replacement (temperloop#942).
<a id="runmachinerybatch-the-batched-sh-replacement-temperloop-942"></a>

```text
 -----------------------------------------------------------------------------
 runMachineryBatch — the BATCHED sh() replacement (temperloop#942).
 -----------------------------------------------------------------------------
 Runs SEVERAL machinery commands inside ONE executor agent (one Bash
 invocation), returning each step's own closed-outcome JSON object so the
 driver keeps branching per-step in .mjs. See DESIGN NOTE 1 for why this does
 not weaken the bridge's invariant.

 A step is { kind, cmd, continueOutcomes?, stopGlobs? }:
   kind             — a short name; it appears in the prompt's `Steps:` manifest
                      and in a denial payload, and is what the .mjs indexes by.
   cmd              — the fully sq()-quoted command text, byte-identical to what
                      the un-batched runMachinery call used to send.
   continueOutcomes — the outcome(s) that permit the NEXT step to run. Anything
                      else stops the sequence (the .mjs then branches on this
                      step's object and escalates, exactly as before).
   stopGlobs        — the inverse form, for a step with no `outcome` key (the
                      merge-state probe): raw substrings that, if present, stop
                      the sequence.
 The last step needs neither — nothing follows it.

 The bash short-circuit is a STOP-EARLY MIRROR, not the decision: it only
 avoids running steps whose result the .mjs is about to discard anyway. The
 authoritative branch is always the `if` in .mjs reading the same JSON.
```

## A timed-out step stops the sequence on BOTH gate forms. The
<a id="a-timed-out-step-stops-the-sequence-on-both-gate-forms-the"></a>

```text
 A timed-out step stops the sequence on BOTH gate forms. The
 continueOutcomes form gets it for free (STEP_TIMEOUT is not a continue
 outcome); the stopGlobs form is a stop-LIST, so the bound's own outcome
 has to be named in it or a bounded merge-state probe would let the poll
 slice behind it run against a step whose result was destroyed.
```

## runMachineryBatch — returns { denied, results, steps, out }. `results[
<a id="runmachinerybatch-returns-denied-results-steps-out-results"></a>

```text
 runMachineryBatch — returns { denied, results, steps, out }. `results[i]` is
 step i's object; the array is SHORTER than `steps` whenever the sequence
 short-circuited (expected). `denied:true` is the batched twin of
 machineryDenied() — agent() returned null (auto-mode classifier DENIED the
 command / user skip / terminal API error) or gave back no usable array.
 `phase` (temperloop#1294): the caller's STAGE group name — see runMachinery().
```

## temperloop#982: orchestrator-supplied workflow input, NOT a config-fil
<a id="temperloop-982-orchestrator-supplied-workflow-input-not-a-co-2"></a>

```text
 temperloop#982: orchestrator-supplied workflow input, NOT a config-file
 read (this runtime has no shell — DESIGN NOTE 1). `||`, NOT `??` — see
 the twin runMachinery() comment above for why: `??` lets an
 empty-string input sail through as a literal "" model, silently
 defeating the fallback; `||` collapses both absent AND empty-string
 input to 'haiku', UNCHANGED from before this setting existed. The
 invariant lives here (the consumer), not in orchestrator prose.
```

## temperloop#1071 — PARTITION the advisory notices out of the results ar
<a id="temperloop-1071-partition-the-advisory-notices-out-of-the-re"></a>

```text
 temperloop#1071 — PARTITION the advisory notices out of the results array
 BEFORE anyone indexes it. A STEP_SLOW line is emitted alongside a real
 result, not in place of one, so leaving it in would shift every later step's
 index by one and silently mis-branch the whole batch. Filtering here (once,
 at the transport) is what lets every `batchStep(batch, i)` call site below
 stay exactly as it was.
 temperloop#1698 — canonicalize every step's duration keys at this same
 transport boundary (the batch twin of runMachinery's call above), BEFORE
 the partition below and before any `batchStep(batch, i)` consumer.
```

## batchStep — step i's outcome object, or a closed ERROR sentinel when t
<a id="batchstep-step-i-s-outcome-object-or-a-closed-error-sentinel"></a>

```text
 batchStep — step i's outcome object, or a closed ERROR sentinel when the batch
 returned nothing for it. A missing entry normally means the .mjs has ALREADY
 escalated on an earlier step (the short-circuit); the sentinel exists so a
 malformed executor return degrades into the step's own error branch rather
 than a TypeError on `.outcome`.
```

## `args` arrives from the Workflow tool as a JSON STRING, not a parsed o
<a id="args-arrives-from-the-workflow-tool-as-a-json-string-no"></a>

```text
 `args` arrives from the Workflow tool as a JSON STRING, not a parsed object
 (established by live probe, #437). Parse it once into `input` and read input.*
 throughout. Helpers below close over `input`; it is assigned before any of
 them is called (the top-level invocation at the end runs last).
```

## Schemas
<a id="schemas"></a>

```text
 -----------------------------------------------------------------------------
 Schemas
 -----------------------------------------------------------------------------
```

## The union of the machinery's closed outcome sets (worktree / pr / ci-p
<a id="the-union-of-the-machinery-s-closed-outcome-sets-worktr"></a>

```text
 The union of the machinery's closed outcome sets (worktree / pr / ci-poll /
 gate) plus the gate-pass/fail and claim markers we synthesize below.
```

## worktree.sh deps-merged (3b-0) — its outcomes were consumed at the
<a id="worktree-sh-deps-merged-3b-0-its-outcomes-were-consumed"></a>

```text
 worktree.sh deps-merged (3b-0) — its outcomes were consumed at the
 call site (~line 595) but never listed here; an omitted outcome is
 schema-invalid, so name them alongside the rest of the closed set.
```

## temperloop#1937 pre-gate freshness passthrough — the two SHAs a
<a id="temperloop-1937-pre-gate-freshness-passthrough-the-two-"></a>

```text
 temperloop#1937 pre-gate freshness passthrough — the two SHAs a
 FRESHNESS_CURRENT/FRESHNESS_REBASED line names, and the conflict
 files + disposition a FRESHNESS_CONFLICT line names.
```

## 3e.6 activation-gate passthrough (temperloop#1219): the `proof:`
<a id="3e-6-activation-gate-passthrough-temperloop-1219-the-pr"></a>

```text
 3e.6 activation-gate passthrough (temperloop#1219): the `proof:`
 predicate's own exit status, carried into the escalation payload so an
 operator sees WHY it failed without opening a log.
```

## REVIEW_DIFF passthrough (temperloop#1430) — the changed-file list (rep
<a id="review-diff-passthrough-temperloop-1430-the-changed-fil"></a>

```text
 REVIEW_DIFF passthrough (temperloop#1430) — the changed-file list (repo-
 relative paths, from `git diff --name-only` in the worktree) and the
 reviewer-routing table's data rows (an empty array when the worktree
 ships no tsv — never an omitted key).
```

## LEGACY (pre-#2020), still accepted so an un-migrated caller or a
<a id="legacy-pre-2020-still-accepted-so-an-un-migrated-caller"></a>

```text
 LEGACY (pre-#2020), still accepted so an un-migrated caller or a
 replayed older payload keeps routing: the raw reviewer-routing.tsv text
 (empty string when the worktree ships none). No longer emitted.
```

## temperloop#1976: the tsv's own non-comment row count, computed by
<a id="temperloop-1976-the-tsv-s-own-non-comment-row-count-com"></a>

```text
 temperloop#1976: the tsv's own non-comment row count, computed by
 reviewDiffCmd off the worktree file itself — the guard runReviewers()
 uses to detect the relay dropping/truncating `tsv`. Row-count only: it
 catches a dropped or truncated table, not a same-length garble.
```

## 3e.5 sliced-gate fields (temperloop#1021). resumeAt — the 0-based gate
<a id="3e-5-sliced-gate-fields-temperloop-1021-resumeat-the-0-"></a>

```text
 3e.5 sliced-gate fields (temperloop#1021). resumeAt — the 0-based gate
 index the NEXT slice starts at; failed — failures seen in THIS slice (the
 driver accumulates); elapsedSecs / budgetSecs — the margin pair that makes
 suite growth observable on every run, not only when it blows a budget.
```

## temperloop#1071 step-liveness fields, carried by STEP_TIMEOUT / STEP_S
<a id="temperloop-1071-step-liveness-fields-carried-by-step-ti"></a>

```text
 temperloop#1071 step-liveness fields, carried by STEP_TIMEOUT / STEP_SLOW.
 `step` is the batch step's own `kind` (or 'solo'), so an escalation payload
 names WHICH machinery call the ceiling bounded without any correlation work.
```

## temperloop#865 — the WORKER's own scoped-gate sentinel, classified by 
<a id="temperloop-865-the-worker-s-own-scoped-gate-sentinel-cl"></a>

```text
 temperloop#865 — the WORKER's own scoped-gate sentinel, classified by the
 3e.5 gate command inside the worktree it is about: 'finished' | 'running'
 | 'absent' | 'unknown'. Parent-side evidence that the worker's gate
 reached a RESULT rather than being backgrounded and abandoned.
```

## SPINE_BATCH_SCHEMA — the batched executor's return: the ordered array 
<a id="spine-batch-schema-the-batched-executor-s-return-the-or"></a>

```text
 SPINE_BATCH_SCHEMA — the batched executor's return: the ordered array of the
 JSON lines the batched command printed, ONE PER STEP THAT RAN. Shorter than
 the step list whenever the bash short-circuit stopped the sequence early (the
 normal, expected case — see DESIGN NOTE 1).
```

## The ci-batch's Bash-tool timeout: its poll wall plus headroom for the
<a id="the-ci-batch-s-bash-tool-timeout-its-poll-wall-plus-hea"></a>

```text
 The ci-batch's Bash-tool timeout: its poll wall plus headroom for the
 interleaved `gh pr view` probes and process startup, clamped to the cap.
```

## Clamp: a slice budget large enough that budget+overrun would exceed th
<a id="clamp-a-slice-budget-large-enough-that-budget-overrun-w"></a>

```text
 Clamp: a slice budget large enough that budget+overrun would exceed the agent's
 Bash cap is silently reduced, so no operator setting can reintroduce the
 hard-kill failure this item removes.
```

## reviewWaitRefusalText — the first line of the refusal a timer result c
<a id="reviewwaitrefusaltext-the-first-line-of-the-refusal-a-t"></a>

```text
 reviewWaitRefusalText — the first line of the refusal a timer result carries,
 or null when it carries none. Bounded in length because it lands in a log line
 and in the `timer-*` string the caller reports.
```

## The gate executor's Bash-tool timeout — derived, never typed twice. Ke
<a id="the-gate-executor-s-bash-tool-timeout-derived-never-typ"></a>

```text
 The gate executor's Bash-tool timeout — derived, never typed twice. Kept under
 this name because it is still exactly that: the tool-level timeout threaded to
 the gate runMachinery call (and only that call).
```

## GATE_MAX_SLICES — a bound, not a target: a suite that cannot finish in
<a id="gate-max-slices-a-bound-not-a-target-a-suite-that-canno"></a>

```text
 GATE_MAX_SLICES — a bound, not a target: a suite that cannot finish in this
 many slices is escalated as a TIMEOUT (honestly named) rather than looped on
 forever. At the default slice budget this is ~40 minutes of gate wall time,
 several times today's suite.
```

## Warn when a completed run used at least this fraction of the slice bud
<a id="warn-when-a-completed-run-used-at-least-this-fraction-o"></a>

```text
 Warn when a completed run used at least this fraction of the slice budget —
 the DECAY SIGNAL. Growth becomes visible as a margin warning on green runs,
 long before it becomes a blown budget (the thing #115 had no way to see).
```

## resolvePrinciplesSummary — per-item lookup: this item's own `repo:` fi
<a id="resolveprinciplessummary-per-item-lookup-this-item-s-ow"></a>

```text
 resolvePrinciplesSummary — per-item lookup: this item's own `repo:` first
 (a cross-repo item's pair), else the default pair, else the static
 fallback. Returns { text, degraded } so the caller can append the
 degradation notice only when the fallback actually fired.
```

## Command-building helpers — EVERY interpolated value goes through sq().
<a id="command-building-helpers-every-interpolated-value-goes-"></a>

```text
 -----------------------------------------------------------------------------
 Command-building helpers — EVERY interpolated value goes through sq().
 -----------------------------------------------------------------------------
```
