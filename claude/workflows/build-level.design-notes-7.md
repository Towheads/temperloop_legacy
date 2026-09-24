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
`test_workflow.sh` pins by exact string. Derive the exclusion set mechanically
from the `grep ... "$MJS"` sites across `workflows/**/*.sh`, and replay every one
of them against the before/after module — a pin added by a branch not yet on main
is invisible to a by-eye read. Dashed and boxed section banners
(`// --- Title ---`, `// === Title ===`) are navigation structure, not prose:
they stay in the module.

**Leave merge slack.** Keep every part of this note set under ~1180 lines, well
short of `PROSE_BUDGET_TIER2_FILE_CAP`. Two branches appending to the same tail
merge cleanly as keep-both, and the merged result can breach a cap that neither
side breached on its own.

> **Part 7 of 7.** Split to stay under the per-file prose cap
> (`PROSE_BUDGET_TIER2_FILE_CAP`). Other parts: [`build-level.design-notes.md`](build-level.design-notes.md), [`build-level.design-notes-2.md`](build-level.design-notes-2.md), [`build-level.design-notes-3.md`](build-level.design-notes-3.md), [`build-level.design-notes-4.md`](build-level.design-notes-4.md), [`build-level.design-notes-5.md`](build-level.design-notes-5.md), [`build-level.design-notes-6.md`](build-level.design-notes-6.md).

## The 3c already-fixed continuation probe (temperloop#2137). THREE
<a id="the-3c-already-fixed-continuation-probe-temperloop-2137-thre"></a>

```text
 The 3c already-fixed continuation probe (temperloop#2137). THREE
 closed outcomes, and the asymmetry between them IS the design: only
 ALREADY_FIXED skips a worker spawn, so it is the ONLY one the JS
 reads as a skip, and it is emitted ONLY when EVERY finding location
 was positively established to be gone from the tip.
 NOT_ALREADY_FIXED (a named finding's line is demonstrably still on
 the tip) and ALREADY_FIXED_UNKNOWN (the probe could not establish an
 answer — no usable prior reviewed SHA, a file unreadable at either
 revision, a fingerprint too weak to be evidence) both spawn the
 worker exactly as today. A relay that drops or garbles this line
 reads as none of the three, which is also a spawn — so the
 fail-closed direction holds by construction, not by discipline.
```

## OBSERVATION the executor can make without inventing anything — the
<a id="observation-the-executor-can-make-without-inventing-anything"></a>

```text
 OBSERVATION the executor can make without inventing anything — the
 distinction temperloop#2049 turned on, plus the fourth
 temperloop#2064 had to split out of it:
   REVIEW_WAIT_ELAPSED       the script printed its line. It carries
                             `realized_secs`, the script's OWN measure
                             of the wait, which reviewWaitAgent()
                             checks against the interval it asked for.
   REVIEW_WAIT_TOOL_TIMEOUT  the Bash tool's own timeout killed the
                             command. That budget is secs+60s, so this
                             can only fire AFTER the interval — the
                             same fact, reported honestly.
   REVIEW_WAIT_BLOCKED       a harness PERMISSION CONTROL refused the
                             command outright ("<tool_use_error>Blocked:
                             …"). NO time passed. This is SPLIT OUT of
                             REVIEW_WAIT_UNAVAILABLE by temperloop#2064
                             because a block and a TOOL_TIMEOUT are the
                             same observation to the executor — "no JSON
                             line" — while only ONE of them (the tool
                             timeout) is the PERMISSIVE arm. Naming the
                             block is what lets reviewWaitAgent() refuse
                             to let a refusal land on that arm.
   REVIEW_WAIT_UNAVAILABLE   the command never ran to completion for any
                             OTHER reason (it errored; the helper was
                             missing). NO time passed either, so the
                             caller FAILS OPEN on both.
 None of them says anything whatsoever about the review being bounded.
```

## temperloop#2129: the files that changed between `review_prior_sha` and
<a id="temperloop-2129-the-files-that-changed-between-review-prior"></a>

```text
 temperloop#2129: the files that changed between `review_prior_sha` and
 this round's HEAD — the CONTINUATION DELTA, narrower than `files` above
 (which is the whole branch diff against origin/<default> and stays the
 routing input). reviewCarryForward() reads it to decide which routed
 seats a continuation round must actually re-spawn. Declared here rather
 than left to `additionalProperties` for the same reason
 `review_prior_sha` is: the driver branches on it. Empty array whenever
 there is no usable prior sha, which the reader treats as "carry nobody".
```

## Tunables (no Date.now()/Math.random() — those THROW in the runtime; al
<a id="tunables-no-date-now-math-random-those-throw-in-the-runtime"></a>

```text
 Tunables (no Date.now()/Math.random() — those THROW in the runtime; all
 budgets are expressed as counts/seconds the executor agent enforces itself).
 The Workflow runtime has no shell, so these stay named constants here rather
 than build.config.sh settings — the same structural constraint that forces
 machinerySoloModel/machineryBatchModel through build.md's Step-0 hand-off.
 A tunable that genuinely needs to be operator-configurable rides that SAME
 Step-0 hand-off (an `input.*` key with an in-file default), never a config
 read from inside this file: GATE_SLICE_SECS below is the worked example.
```

## HISTORY, because the shape of this block IS the fix. The gate used to 
<a id="history-because-the-shape-of-this-block-is-the-fix-the-gate"></a>

```text
 HISTORY, because the shape of this block IS the fix. The gate used to carry a
 single flat Bash-tool timeout for the WHOLE quality-gates.sh suite:
 temperloop#115 raised it 120_000 -> 480_000ms when a 2-minute suite was
 SIGTERM'd mid-run and reported as GATE_FAIL on a green tree; temperloop#1021
 is the identical failure again, because the suite outgrew 480s too. A third
 raise is not available: AGENT_BASH_CAP_MS is a HARD ceiling this file cannot
 exceed, and the suite is already near it — so "raise the number" is the patch
 that is already known to decay, twice.

 So the budget stops being a deadline for the suite and becomes the length of
```

## quality-gates.sh runs gates until its own soft budget is spent, stops 
<a id="quality-gates-sh-runs-gates-until-its-own-soft-budget-is-spe"></a>

```text
 quality-gates.sh runs gates until its own soft budget is spent, stops CLEANLY
 BETWEEN GATES, and reports where to resume; 3e.5 loops slices until the suite
 finishes. TOTAL suite runtime is therefore unbounded by the agent's Bash cap,
 and gate-list growth can no longer manufacture a false GATE_FAIL — the decay
 path is closed structurally rather than deferred to the next raise.

 GATE_SLICE_SECS is a NAMED SETTING (BUILD_GATE_SLICE_SECS), handed in by the
 orchestrator at Step 0 exactly like machinerySoloModel/machineryBatchModel —
 the Workflow runtime has no shell or filesystem, so it cannot source
```

## THE FAILURE THIS BOUNDS. §3e is a cold, one-shot advisory pass, and a 
<a id="the-failure-this-bounds-3e-is-a-cold-one-shot-advisory-pass"></a>

```text
 THE FAILURE THIS BOUNDS. §3e is a cold, one-shot advisory pass, and a HIGH
 finding escalates `review-blocking` → the orchestrator loops the item back to
 3c → the worker fixes it → a FRESH reviewer reads the now-LARGER diff. Nothing
 bounded that loop. Measured on one live item (temperloop#1938 L1, item
 `interview-command-spec`/#1962): FIVE consecutive §3e passes, four DISTINCT
 HIGHs, ZERO repeats, ~2h45m and ~1.05M subagent tokens before convergence —
 and pass 4's HIGH was CAUSED by pass 3's directed fix, while the reviewed spec
 grew 447 → 635 lines across the rounds. So the loop is partly SELF-FEEDING,
 not merely serial discovery: each round enlarges the surface the next one
 reads, and the orchestrator had to invent a stopping rule by hand at pass 5.

 THE OTHER HALF IS THE REVIEWER SEAT, NOT THIS BOUND. claude/agents/
 workflow-reviewer.md now instructs the seat to enumerate EVERY HIGH it can
 identify in ONE pass before it ranks or narrows; this constant is the backstop
 for when that still does not converge. Deliberately NOT a model-tier change:
 that seat is pinned `model: sonnet` by its own frontmatter, on purpose.

 WHAT IT DOES, PRECISELY. `REVIEW_BLOCKING_MAX_ROUNDS` caps the number of
 review ROUNDS one item's worktree may spend. On the round that reaches the
 cap, a blocking finding no longer escalates: the item continues to 3e.5/3f
 with the findings carried in the return value — into the PR body's
 `## Review notes` (the same reviewBodySuffix() render every round uses) and
 into the parked record's `review.residual_blocking` tally — so the human at
 the merge gate reads exactly what the reviewer said. ADVISORY, NEVER A
 SUPPRESSION: what stops is the automatic build-review-build loop, not the
 findings. An item that converges in fewer rounds is byte-identical to
 pre-#1970 behaviour, which is why the default preserves today's path for
 everything under the bound.

 ROUND COUNTING IS DURABLE, because the loop spans PROCESSES: each
 review-blocking escalation returns to the orchestrator, which re-invokes this
```

## counter lives in the worktree's own GIT DIR (never the working tree — 
<a id="counter-lives-in-the-worktree-s-own-git-dir-never-the-workin"></a>

```text
 counter lives in the worktree's own GIT DIR (never the working tree — it must
 not show up in `git status`, in a `--scoped` gate's untracked-path resolution,
 or in a coverage manifest) and is read+bumped by reviewDiffCmd in the SAME
 machinery call §3e already makes: zero extra agent spawns. A continuation
 re-uses the worktree (3b is skipped), so the count survives exactly the loop
 it bounds; a fresh item gets a fresh worktree and therefore a fresh count.
 The CI-fix re-review (§3g) shares the counter deliberately — it is the same
 item's review budget, and counting it is the conservative direction.

 REVIEW_BLOCKING_MAX_ROUNDS is a NAMED SETTING (BUILD_REVIEW_BLOCKING_MAX_ROUNDS),
 handed in by the orchestrator at Step 0 exactly like GATE_SLICE_SECS above —
 the Workflow runtime cannot source build.config.sh itself. A non-positive or
 unparseable value falls back to the in-file default rather than disabling the
 bound, and the floor of 1 means no caller can configure the loop back to
 unbounded.
```

## REVIEW_WAIT_REFUSAL_RE — the harness's OWN words for "I refused this c
<a id="review-wait-refusal-re-the-harness-s-own-words-for-i-refused"></a>

```text
 REVIEW_WAIT_REFUSAL_RE — the harness's OWN words for "I refused this command"
 (temperloop#2064). Matched against whatever text the timer executor relays
 (`refusal_text`, `error`, `detail`) BEFORE its own outcome label is read.

 WHY TEXT RATHER THAN THE EXECUTOR'S LABEL. A permission BLOCK and a Bash-tool
 TIMEOUT kill are the SAME observation to the executor — no JSON line came
 back — and exactly one of the two arms is PERMISSIVE: a tool timeout is
 honoured as elapsed, because its budget is secs+60s and can only fire AFTER
 the interval. So the executor is being asked to tell apart two states it
 cannot see, with a coin flip that lands, half the time, on "the ceiling
 expired". temperloop#2064 measured that: three slices asking 300s/540s/360s
 returned in 11s/11s/17s, a 1200s ceiling realized in ~41s, and a
 docs-reviewer that finished normally at 98s was discarded and reported as
 "unavailable". A refusal, unlike an elapse, leaves EVIDENCE the executor can
 only relay and never invent — the harness's own refusal text — so that is
 what the classification reads (kernel principle 5: counter a known AI failure
 mode STRUCTURALLY, not with a sharper instruction).

 FAIL-CLOSED DIRECTION. A match means "no usable timer", which makes the
 caller fail OPEN on the fanout (wait unbounded, the pre-#2003 behaviour) and
 say so. So a FALSE positive costs latency on a pathological hang; a false
 NEGATIVE discards finished reviews and reports a gate that never ran. The
 regex is therefore deliberately generous.
```

## REVIEWER_ROUTING_TSV — temperloop#1982, the STRUCTURAL close on the re
<a id="reviewer-routing-tsv-temperloop-1982-the-structural-close-on"></a>

```text
 REVIEWER_ROUTING_TSV — temperloop#1982, the STRUCTURAL close on the relay
 defect temperloop#1976/#1995 only mitigated. `workflows/scripts/config/
 reviewer-routing.tsv` is a STATIC repo file: its content is identical on
 every run and depends on nothing the worktree computes, so routing it
 through the machinery-executor agent's verbatim-echo contract was never
 necessary — only the CHANGED-FILE list genuinely has to come from the
 worktree. Relaying it anyway put a multi-line tab-delimited table in front
 of an LLM asked to reproduce it byte-for-byte, and it was mangled in three
 distinct ways across eight observed occurrences: silently omitted; replaced
 by an English sentence *describing* the table; and (2026-09-13) returned
 DOUBLE-JSON-ENCODED — surrounding quotes plus literal two-character \t/\n
 sequences instead of real tabs and newlines, which parses as one row rather
 than eleven. Note what survived every one of those: `tsv_rows` and
 `tsv_checksum`, both small integers, were correct in all three shapes. The
 string field is the unreliable part, not the step.

 So this rides the SAME Step-0-hand-off seam as principlesSummaries above
```

## PRINCIPLES_KERNEL_FALLBACK — last-resort degradation, used ONLY when t
<a id="principles-kernel-fallback-last-resort-degradation-used-only"></a>

```text
 PRINCIPLES_KERNEL_FALLBACK — last-resort degradation, used ONLY when the
 orchestrator supplied no `principlesSummaries` at all this run (an older
 orchestrator, or a consuming-repo caller that has not wired the hand-off —
 all three first-party callers of this file's shared `workerPrompt()`,
 build.md/sweep.md/fix.md, resolve and pass it; #1432 wired /build,
 temperloop#1460 wired the other two). A static snapshot of `claude/engineering-principles.md`'s
 kernel-only principle NAMES — this runtime cannot read that file itself to
 stay current, so a worker on the fallback path gets a legible floor (never
 a silently empty set, which from the outside would look identical to
 "principles applied") plus an explicit notice that the project extension
 was NOT applied. See principlesSection() below for the notice text.
```

## changelogFragmentSection — the §3c "add your own changelog.d/ fragment
<a id="changelogfragmentsection-the-3c-add-your-own-changelog-d-fra"></a>

```text
 changelogFragmentSection — the §3c "add your own changelog.d/ fragment"
 instruction (temperloop#1530), a SELF-CONTAINED section appended once into
 workerPrompt()'s array, mirroring principlesSection()'s /
 discriminationEvidenceSection()'s shape so a sibling edit to workerPrompt()
 rebases cleanly. WHY THE WORKER, NOT A PARENT-SIDE CHECK: the issue's own
 prose names two options (tell the worker vs. run check-changelog-entry.sh
 parent-side before pr.sh open) — this instructs the worker because that is
 PREVENTION (the fragment lands in the same commit, no round trip) rather
 than DETECTION (a parent-side check still costs a re-spawn once it fires,
 just earlier than CI); it does not restate the fragment's filename grammar
 or body rules here — those live in ONE place, changelog.d/README.md — so
 this section and that file can't drift out of sync with each other. The
 escape hatch it names is the ONE opt-out channel that works before a PR
 exists (a commit-message trailer — check-changelog-entry.sh's own header),
 so a worker that judges its change non-shipping RECORDS that choice rather
 than silently omitting the fragment.
```

## THE RULE: a bounded-out step is LOST, never FAILED and never RE-ISSUED
<a id="the-rule-a-bounded-out-step-is-lost-never-failed-and-never-r"></a>

```text
 THE RULE: a bounded-out step is LOST, never FAILED and never RE-ISSUED. The
 ceiling proves the workflow stopped waiting; it proves nothing about what the
 step did or did not do before it was killed — a `push` may have completed on
 the remote, a `pr-open` may have created the PR (the #1071 incident's own
 9h49m step in fact finished ALL FOUR steps green and opened PR #1070). So the
 disposal is the same side-effect probe the lost-return path already owns:
 `pr.sh recover-probe` (temperloop#939's staged ladder, and the seam
 temperloop#1067 covers for the adjacent lost-return case — deliberately ONE
 disposal path, not a second one invented here).

 Two dispositions, no third:
   • the probe finds an OPEN PR → ADOPT it (`adopt`), exactly as 3f-2 adopts
     pr.sh's own `EXISTS`. This is the case that must never be re-run: blindly
     re-issuing the batch would double-push or double-open.
   • anything else → a legible `machinery-step-timeout` escalation carrying the
     probe's verdict, for a human/orchestrator to drive. Still no retry.
 `adoptable:false` (the CI-poll path) keeps the probe — its stage is real
 evidence for the payload — while refusing the adopt arm, because "a PR exists"
 is not, and must never become, evidence that CI passed.
```

## isLostReturn — true iff a batch step's outcome is the SYNTHESIZED sent
<a id="islostreturn-true-iff-a-batch-step-s-outcome-is-the-synthesi"></a>

```text
 isLostReturn — true iff a batch step's outcome is the SYNTHESIZED sentinel
 batchStep() (line ~1158) mints for a missing `batch.results[i]` entry, never a
 genuine failure the machinery script itself reported. This is the fidelity
 signal that distinguishes "the step failed" from "the step's return value was
 lost pr-batch return" — a real `pr.sh` failure calls its own `die()` and
 carries a DIFFERENT `error` string, so this check can never mistake a genuine
 non-zero exit for a lost line. That distinction is what keeps the negative
 case (a real failure) escalating immediately, unprobed, exactly as before.
```

## alreadyFixedVerdict(item, probe) — the verdict record the skipped work
<a id="alreadyfixedverdict-item-probe-the-verdict-record-the-skippe"></a>

```text
 alreadyFixedVerdict(item, probe) — the verdict record the skipped worker would
 have returned. Shaped exactly like recoveredVerdict() above, and for the same
 reason: each criterion carries a CRITERION and an EVIDENCE line and NO
 `passed` boolean, so §3d reads no failure into it and discriminationGaps()
 reads no unproven pass out of it. The acceptance behind this tree was already
 self-verified by the round that got the item as far as §3e in the first place
 (a `review-blocking` escalation happens strictly AFTER 3d passes), and the
 worker's own `.build-verification.md` is still on disk and still rides the PR
 via 3f's `--verification-surface-file` — so nothing is lost here, and the
 summary says so rather than leaving the reviewer to infer it.
```

## `committed_work` is a FACT the escalation carries, never a verdict: it
<a id="committed-work-is-a-fact-the-escalation-carries-never-a-verd"></a>

```text
 `committed_work` is a FACT the escalation carries, never a verdict: it
 says what is (or is not) on origin, so the human or agent disposing this
 escalation decides about removal against evidence instead of an assumption
 that "the worktree stays intact" means the work is safe.

 temperloop#2103 — `head_sha`/`remote_sha` ride the record because NEITHER
 `preserved` nor "the branch exists on origin" is sufficient alone: the live
 third occurrence had a stale pre-rebase sha sitting on the remote while the
 flag read false, so one signal overstated and the other understated. With
 both shas present a caller can settle it by comparison instead of guessing.
```

## temperloop#2133 (a §3e review finding on the #2135 branch, no issue of
<a id="temperloop-2133-a-3e-review-finding-on-the-2135-branch-no-is"></a>

```text
 temperloop#2133 (a §3e review finding on the #2135 branch, no issue of its
 own): read the ledger's failure count STRICTLY. `Number(x) || 0` collapses
 BOTH `null` and `NaN` to 0 — the same laundering temperloop#1698 fixed for
 elapsedSecs — so the day gateSliceFailed()'s contract grows an
 "unreadable failure count" sentinel, an UNKNOWN count would read as a known
 zero. The rule, applied at all three ledger-reading sites: a non-finite count
 is never a known zero. Identical to the prior expression for every finite
 input, which is all the single-writer ledger produces today.
```

## discriminationGaps — the temperloop#1319 DEGRADED CASE. WORKER_VERDICT
<a id="discriminationgaps-the-temperloop-1319-degraded-case-worker"></a>

```text
 discriminationGaps — the temperloop#1319 DEGRADED CASE. WORKER_VERDICT_SCHEMA
 does not (and per the "advisory, never a new blocking gate" ask, must not)
 mark `discrimination_evidence` required, §3d branches solely on `.status`,
 and §3e.5 never looks at it — so a worker that simply OMITS the field on an
 otherwise-`passed: true` entry produces a `done` verdict that sails through
 the whole pipeline and renders a PR body indistinguishable from "not
 applicable" or a pre-#1319 PR. THIS is the load-bearing half criterion 2
 actually requires: a missing field must be a NAMED, VISIBLE degradation, not
 a silent one. Mirrors the pre-existing `verification_surface` degraded-case
 pattern (build.md §3f step 2, "Surface the degraded case") exactly — a
 legible warning, never a hard failure (kernel principle 7, advisory over
 enforced discipline): a `passed: false`/`blocked`/`failed` entry is
 untouched (only a CLAIMED pass with no proof is suspect).

 Gated on REQUIRE_DISCRIMINATION_EVIDENCE — an unarmed run (today: /sweep,
 /fix) never required the field in the first place, so it has nothing to
 degrade FROM and this returns empty unconditionally, exactly like
 discriminationEvidenceSection() above.
```

## isHostConfigDeferral / hostConfigDeferrals — the temperloop#1182 DEFER
<a id="ishostconfigdeferral-hostconfigdeferrals-the-temperloop-1182"></a>

```text
 isHostConfigDeferral / hostConfigDeferrals — the temperloop#1182 DEFERRAL,
 the THIRD disposition an acceptance criterion can carry. `passed` is a
 boolean and a worktree can never observe a gitignored host-local file, so
 without a third state a host-config criterion has only two bad answers: a
 claimed pass the worker structurally could not make, or a `passed: false`
 §3d reads as blocked and stalls the whole level on a check that was never
 runnable here (foundation#1556 — the worker escalated
 `acceptance-incomplete` over a `credential_present: false` that read `true`
 in both real checkouts moments later).

 The marker is the PAIR (`passed: false` + a non-empty `deferred_host_config`)
 so neither half alone changes anything: a bare `passed: false` still blocks
 exactly as before, and the marker on its own never manufactures a pass. It
 is deliberately NOT gated on a run-level flag — the worktree-vs-index fact
 it encodes is true on every path that spawns a worker.
```

## temperloop#2065 "worker-cost-capture" (epic #2062's dual-build ledger)
<a id="temperloop-2065-worker-cost-capture-epic-2062-s-dual-build-l"></a>

```text
 temperloop#2065 "worker-cost-capture" (epic #2062's dual-build ledger) —
 per-item worker cost: tokens, wall-clock, retry cost and a `recovery`
 flag, captured at callWorker()/ciPollLoop()'s emitted-shell seam (see
 workerClockNow()/workerUsageEmit() above) and reconciled against the
 model-usage envelope (workflows/scripts/build/worker-usage.sh →
 model-usage-envelope.sh's model_usage_emit_from_envelope, seat
 "build-worker"). `cost.recovery` is this record's OWN plain-boolean
 projection of the `recovery` PARAMETER above (a probe object, or null) —
 a DIFFERENT thing from `recovered_from`/`acceptance_unverified`, which
 name WHICH stage the temperloop#939 probe landed at; `recovery` here only
 says whether the cost figures above are trustworthy (a recovered record
 never observed the worker's own return, so its tokens/wall-clock are
 whatever the LOST call still managed to report through the fail-open
 seam, never fabricated). Present iff the caller passed `cost` — the
 spike call site (4 args) omits it, so a spike's parked record stays
 byte-identical to before this item; the 3h main path always passes it,
 so EVERY non-spike parked record carries all six keys, present even at
 their null/zero baseline (never conditionally omitted like `no_ci`
 above — a cost ledger with silently-missing rows is worse than one with
 honest nulls).
```

## temperloop#1182: derived from `acceptanceResults` rather than threaded
<a id="temperloop-1182-derived-from-acceptanceresults-rather-than-t"></a>

```text
 temperloop#1182: derived from `acceptanceResults` rather than threaded in
 as a 9th positional argument, so BOTH park() call sites (the 3h main path
 and the spike path at 3b, which passes only four arguments) surface the
 deferrals without a signature change. Same durable-marker shape as
 `no_ci`/`discrimination_gaps` — omitted entirely when empty, so a run with
 no host-config criterion produces byte-identical parked records to before.
 NOT advisory, unlike discrimination_gaps: these criteria are UNVERIFIED
 (the `acceptance_unverified` family), and the invoking spec's parent-side
 seat must verify each one before the item is eligible to merge — build.md
 §4a, sweep.md's per-chunk merge pass, or fix.md Step 5 (the seat list in
 the I/O CONTRACT header). build.md §3h.5's as-you-go tier is INELIGIBLE
 for an item carrying this field: that path never reaches §4a.
```

## build.md §3e's routing rules, run for REAL inside this driver — see th
<a id="build-md-3e-s-routing-rules-run-for-real-inside-this-driver"></a>

```text
 build.md §3e's routing rules, run for REAL inside this driver — see that
 section's own "why this runs inside the workflow" paragraph for the
 orchestrator↔workflow-boundary rationale. Before this item the review lived
 only as worker-discretion prose: the 3c worker CANNOT spawn a nested
 `agent({agentType})` (the "No context-inheriting research forks" contract in
 workerPrompt() forbids exactly that shape), so the mandatory
 `claude/commands/*.md` → `workflow-reviewer` rule (foundation#1007) could
 never actually run on the default Workflow path — every command-doc PR
 reported a STRUCTURALLY GUARANTEED "skipped — unavailable", which read as a
 legible degradation but was in fact a permanent no-op. This driver spawns
 the reviewer itself, so the same skip notice now fires only when the
 reviewer genuinely fails to resolve.
```

## temperloop#2129 — the DELTA the prior round did not see: the files tha
<a id="temperloop-2129-the-delta-the-prior-round-did-not-see-the-fi"></a>

```text
 temperloop#2129 — the DELTA the prior round did not see: the files that
 changed between the commit the prior round reviewed and this round's
 HEAD. `files` above is the whole branch diff against origin/<default>
 and is what the ROUTING decision reads; this narrower list is what the
 continuation-round CARRY decision reads (reviewCarryForward), so a seat
 whose routed files are all absent from it is not re-spawned.

 Computed HERE, from the SAME validated `review_prior_sha` the field
 above emits — never from a second, independently-resolved sha — so the
 two can never disagree about which commit "the prior round" means. It
 sits BEFORE the bump block below for the same reason that read does:
 the bump overwrites the marker with THIS round's HEAD, and a delta
 measured against that would be empty by construction.

 FAILS SOFT IN THE PERMISSIVE DIRECTION, like every other marker step
 here. No prior sha (absent, corrupted, orphaned by a rebase) leaves the
 field an empty array AND `review_prior_sha` empty, and the reader arms
 the carry only when BOTH are usable — so a dropped or garbled field can
 only ever cause MORE reviewers to re-run, never fewer. The one shape
 that must not be conflated with it — a valid prior sha and a genuinely
 empty delta — is distinguishable because `review_prior_sha` is non-empty
 there.
```

## determineReviewers — build.md §3e's full routing rule set, applied to 
<a id="determinereviewers-build-md-3e-s-full-routing-rule-set-appli"></a>

```text
 determineReviewers — build.md §3e's full routing rule set, applied to this
 item's changed-file set. Every matching axis is included (build.md: "A
 change matching more than one axis ... runs each matching reviewer").
 Returns [{ reviewer, mandatory, reasons[] }, ...], reviewer names deduped.

 temperloop#2020 — `opts.tableAvailable: false` runs the TABLE-INDEPENDENT
 axes ONLY. The rule set splits cleanly in two: the `review:` override, the
 `kind: architectural` axis and the MANDATORY command-doc rule
 (foundation#1007) are computed purely from `item`/`files` and never consult
 reviewer-routing.tsv at all; the extension axis and the prose-`*.md`
 fallback are the only ones that do. When the table does not survive the
 machinery relay, only that second half is unknowable — so asking for
 `tableAvailable: false` drops exactly those and keeps the rest, and a
 degraded relay can never silently swallow a route that never needed the
 table. The prose-`*.md` fallback is deliberately on the DROPPED side: it
 fires precisely when no row matched, and with a broken table "no row
 matched" is not a fact, it is an absence of evidence.
```

## reviewer -> { reasons: Set, files: Set, fileScoped: boolean }
<a id="reviewer-reasons-set-files-set-filescoped-boolean"></a>

```text
 reviewer -> { reasons: Set, files: Set, fileScoped: boolean }

 temperloop#2129 adds the second and third fields. `files` is WHICH changed
 files put this reviewer on the roster — the continuation carry decision
 (reviewCarryForward) needs per-seat file attribution, and re-deriving it
 there would be a second implementation of the very matching rule this
 function owns. `fileScoped` is false as soon as ANY of a reviewer's
 reasons came from an axis with no file behind it (the `review:` override,
 `kind: architectural`), because such a seat's relevance is not a function
 of which files moved and it must therefore always re-run.
```

## reviewCarryForward — temperloop#2129. THE CONTINUATION-ROUND ROSTER RU
<a id="reviewcarryforward-temperloop-2129-the-continuation-round-ro"></a>

```text
 reviewCarryForward — temperloop#2129. THE CONTINUATION-ROUND ROSTER RULE.

 THE COST THIS CUTS. temperloop#2127 made a continuation round DELTA-AWARE in
 the PROMPT — every routed seat still re-spawned, it was just told what had
 changed. On an item that loops the full REVIEW_BLOCKING_MAX_ROUNDS budget
 that re-runs every seat on every round, and the seats whose files the fix
 never touched re-read the same unchanged code and re-emit the same verdict.
 With build-level.mjs now carrying TWO seats (`.mjs` -> typescript-reviewer
 and `**/build-level.mjs` -> shell-reviewer, this same item), a shell-only fix
 round re-pays for a full ~9,000-line JavaScript review that cannot have
 changed. This narrows the ROSTER to match the prompt's delta.

 THE RULE, and why each clause is where the safety lives. A routed seat is
 CARRIED (not re-spawned) only when ALL of these hold:
   - the carry is ARMED at all: round > 1, a VALIDATED prior sha, and a
     `files_since_prior` array that actually arrived. Any of the three
     missing arms nothing, so every seat re-runs — the same
     permissive-on-degradation direction every other marker read here takes
     (a relay that drops a field can only ever cause MORE review, never
     less).
   - the seat is NOT MANDATORY. foundation#1007's command-doc rule is a
     GATE, and `review.mandatory_ok` means "workflow-reviewer actually ran on
     this command-doc diff". Carrying it would report a gate as passed on the
     strength of a previous round — the K.49/foundation#164 silent-skip class
     dressed as an optimisation. Never carried, at any delta.
   - the seat is FILE-SCOPED and has at least one routed file. A `review:`
     override or a `kind: architectural` route has no file behind it, so
     "did its files change" is not a question that can be asked about it.
   - the seat did NOT raise the prior round's blocking finding. This is the
     load-bearing one: the whole point of a `review-blocking` continuation is
     for THAT seat to re-check the fix, and the fix routinely lands in files
     that seat is not routed for (a JS-side fix for a shell finding, a doc
     fix for a prose finding). Attribution is by reviewer NAME against the
     prior findings text the orchestrator handed back, and it FAILS SAFE: if
     that text is present but names no routed seat, the carry disarms
     entirely rather than guess — better to re-run everything than to carry
     the one seat that had to run.
   - NONE of its routed files appear in the delta.

 A carried seat is never silent. It is recorded in `skipped` (so the tally's
 `routed_not_run` names it, exactly as that field's contract already says a
 seat skipped in one round and run in another should be) AND in `sections`,
 so the PR body still renders a block for it under `## Review notes` rather
 than losing the seat between rounds. See the carried disposition in
 disposeReviewSlot() for what that block says and what it honestly cannot.

 Mutates each carried route in place (`route.carriedFrom`) rather than
 returning a partition, so route ORDER — which fixes spawn order, `ran` order
 and section order — is preserved by construction with no second array to
 keep in step.
```

## temperloop#2129 — the CARRIED seat. TWO records, deliberately, because
<a id="temperloop-2129-the-carried-seat-two-records-deliberately-be"></a>

```text
 temperloop#2129 — the CARRIED seat. TWO records, deliberately, because
 they answer two different readers' questions and neither substitutes for
 the other:
   - a `skipped` entry, so the Step 6 tally's `routed_not_run` names it
     (its contract already covers exactly this case: "a reviewer skipped
     in one round and run in another stays listed"), and so an operator
     reading the roster never sees a seat silently vanish between rounds;
   - a `sections` entry, so the PR body's `## Review notes` still renders
     a BLOCK for this seat. Without it a cold reader of the final PR sees
     only the seats that happened to run on the LAST round and has no way
     to tell a seat that was carried from one that was never routed.
 `mandatory: false` is a statement of fact, not a choice: a mandatory
 route is never carried (reviewCarryForward), so this branch cannot be
 reached with one.
```

## temperloop#2129 — CARRIED, checked FIRST because a carried slot was ne
<a id="temperloop-2129-carried-checked-first-because-a-carried-slot"></a>

```text
 temperloop#2129 — CARRIED, checked FIRST because a carried slot was never
 spawned: it has no value and no error, and every branch below would read
 that absence as a failure ("returned no verdict (skip/transient)").

 WHAT THE BLOCK CAN AND CANNOT SAY. It states the fact that settles the
 question for a cold reader of the PR — this seat was routed, it ran in the
 named round, and the files it is routed for have not moved since the
 commit it reviewed. It does NOT reproduce that round's findings text,
 because that text does not cross the round boundary: §3e escalates to the
 orchestrator between rounds and the only review content handed back is the
 BLOCKING findings (`verdicts[slug].verdict_section`, build.md Step 3). A
 carried seat by construction raised none — the blocking seat is always
 re-run (reviewCarryForward), and a continuation that did not come from a
 `review-blocking` escalation had no blocking findings at all — so what is
 unreproducible here is advisory MEDIUM/LOW prose, never a HIGH. The block
 says that plainly rather than implying the seat produced nothing.
```

## build.md §3e.6 specifies a synchronous, in-repo ACTIVATION check: an i
<a id="build-md-3e-6-specifies-a-synchronous-in-repo-activation-che"></a>

```text
 build.md §3e.6 specifies a synchronous, in-repo ACTIVATION check: an item
 carrying `activation: class: A` has its `proof:` predicate run against the
 worker's worktree BEFORE 3f pushes anything, and a Fail loops back to 3c.
 This driver — the DEFAULT Step-3 path since temperloop#998 — implemented none
 of it, and `activation` was not even in the items[] args contract, so the
 block never crossed the orchestrator→workflow boundary at all. Every gate
 plan.sh rule 14 forces onto a product-source item was therefore inert here:
 an item could merge green with its feature dormant (a runner never
 registered, a flag never flipped, a rule nothing greps for) — exactly the
 failure `Decisions/temperloop - Activation-completeness contract` exists to
 catch. THE PREDICATE IS THE GATE: there is no fallback actor and no skip arm
 (temperloop#1451), so an arriving class-A block with no `proof:` escalates
 rather than degrading to a no-op.

 WHY IN driveItem, BETWEEN 3e.5 AND 3f (the issue's candidate 1, chosen):
 running it parent-side after the workflow returns would put it AFTER push and
 PR-open, so a Fail would cost a re-push on an already-open PR instead of a
 loop-back to 3c. The gate's whole value is that it fires before the branch
 leaves the worktree.

 BYTE-IDENTICAL FOR EVERYONE ELSE: activationClass() returns '' for an item
 with no `activation` block and 'B'/'C' for a ledger-discharged one, and
 runActivationGate() returns null on the first line in those cases — zero
 agent spawns, zero log lines, zero stage transitions. B/C stay
 ledger-recorded at 4d-epic step 2a (orchestrator-side, off this path).
```

## activationControlCmd — the temperloop#944 MERGE-BASE CONTROL PASS.
<a id="activationcontrolcmd-the-temperloop-944-merge-base-control-p"></a>

```text
 activationControlCmd — the temperloop#944 MERGE-BASE CONTROL PASS.
 Materializes the item's merge-base as a throwaway detached worktree, runs the
 IDENTICAL predicate there, and reports which way it went:
   ACTIVATION_CONTROL_DISCRIMINATES — the proof FAILS at the merge base, i.e.
       it genuinely discriminates this item's work from an untouched tree.
   ACTIVATION_CONTROL_VACUOUS      — the proof PASSES at the merge base, so it
       would read Pass with no work done at all and proves nothing.
   ACTIVATION_CONTROL_ERROR        — the control could not be ESTABLISHED
       (no merge-base, worktree add failed). Never collapsed into either
       verdict: an unestablished control is an UNKNOWN, and the #1021 lesson
       is that an unknown must never wear a pass or a fail.
 Mirrors pr.sh's own default_branch() fallback chain (origin/HEAD, else
 main/master), the same way reviewDiffCmd does, so it never depends on pr.sh
 having run first. The temp worktree is removed plainly FIRST — git's own
 refusal is the last belt (kernel § Environment hygiene) — with --force and
 then rm -rf only as fallbacks, so a throwaway can never leak either way.
```

## runActivationGate(item, wt) — the §3e.6 gate. Returns an ESCALATION ob
<a id="runactivationgate-item-wt-the-3e-6-gate-returns-an-escalatio"></a>

```text
 runActivationGate(item, wt) — the §3e.6 gate. Returns an ESCALATION object to
 return straight out of driveItem, or null to proceed to 3f.

 Ordering is the contract, not an implementation detail: for an absence-
 asserting predicate the control pass runs FIRST and a VACUOUS verdict
 escalates WITHOUT EVER RUNNING THE WORKTREE COPY (build.md §3e.6: "escalate
 … and loop back to 3c exactly like a Fail, without even checking the worktree
 copy"). That is why the control is its own machinery call rather than a
 branch inside one combined shell command — the ordering is then observable,
 and a test can assert the worktree run never happened.
```

## An EMPTY inScope is as unusable as an absent one, and `![]` is false, 
<a id="an-empty-inscope-is-as-unusable-as-an-absent-one-and-is-fals"></a>

```text
 An EMPTY inScope is as unusable as an absent one, and `![]` is false, so a
 truthiness check alone lets it through (temperloop#2080 review round 3). A
 present-but-empty array reaches here two ways: the caller passed `inScope: []`,
 or every entry was blank/non-string and `.map(str).filter(Boolean)` scrubbed it.
 Either way `dual.inScope` becomes an empty Set, EVERY item then misses
 `inScope.has(slug)` and takes the single-arm path, and the level reports a
 dualBuild summary having compared nothing — precisely the outcome this function
 refuses rather than degrades into.
```

## armItem — the per-arm view of a plan item. Three fields move and nothi
<a id="armitem-the-per-arm-view-of-a-plan-item-three-fields-move-an"></a>

```text
 armItem — the per-arm view of a plan item. Three fields move and nothing else
 does, which is what lets the ENTIRE phase-1 body run unmodified for an arm:
   slug   → `<slug>@<arm>`  … every label, every /tmp/qg-<…> path and every
            deterministic worktree path in phase 1 is derived from item.slug,
            so suffixing it here is what stops two arms of one item colliding
            on a gate log, a selection pin or a worktree — without threading an
            "arm key" parameter through forty call sites.
   branch → `build/<slug>@<arm>` … matches what `worktree.sh create --arm`
            actually creates, so the recover-probe and any later push address
            the arm's own ref rather than the item's shared one.
   model  → that arm's model … and because callWorker() reads item.model on
            BOTH the first spawn and the #1219 foreground-cure retry, the
            retry stays on the arm's own model by construction. There is no
            tier-escalation path here to opt out of: nothing in this driver
            ever substitutes a stronger model for a failed worker.
```

## Every candidate arm passes through `candidate-session.sh` BEFORE it bu
<a id="every-candidate-arm-passes-through-candidate-session-sh-befo"></a>

```text
 Every candidate arm passes through `candidate-session.sh` BEFORE it builds:
 `resolve` proves the containment overlay is present, readable and well-formed
 (the same fail-closed check judge.sh's own pairwise mode runs), and
 `preflight` proves the candidate provider's credential is actually SET rather
 than merely named. A refusal is an INFRA loss for that arm, recorded as such —
 never a silent single-arm level.

 WHY THE WORKER ITSELF IS NOT SPAWNED BY `candidate-session.sh spawn`, AND WHY
 A NON-DEFAULT PROVIDER IS THEREFORE REFUSED HERE. `spawn` runs a `claude` CLI
 child inside whatever shell invokes it. In this driver the only shell is an
 executor agent's Bash tool, hard-capped at AGENT_BASH_CAP_MS (~10 minutes) —
```

## through `spawn` would not produce a contained candidate session; it wo
<a id="through-spawn-would-not-produce-a-contained-candidate-sessio"></a>

```text
 through `spawn` would not produce a contained candidate session; it would
 produce a worker killed mid-build on every non-trivial item. The reachable
 spawn seam with no such cap is the runtime's own `agent({ model })`, which
 addresses the host session's provider only.

 So the seam is honest about its edge rather than silently exceeding it: a
 candidate naming the DEFAULT provider builds through `agent({ model })` (the
 A/A instrument check and every same-provider tier comparison — the epic's own
 first live run), and a candidate naming a NON-DEFAULT provider is REFUSED by
 name with an `infra` row. It is never spawned uncontained, which is the one
 outcome that would defeat candidate-session.sh's whole purpose. Lifting that
 edge needs an uncapped spawn seam, which is its own piece of work, not a
 silent widening here.
```

## Kept as one function rather than inline at the two call sites so the l
<a id="kept-as-one-function-rather-than-inline-at-the-two-call-site"></a>

```text
 Kept as one function rather than inline at the two call sites so the ledger's
 vocabulary has a single author: a row that says `infra` when the branch was
 actually red is a comparison result nobody can trust afterwards.
   gate        — the acceptance gate itself reported RED, or could not finish
                 (a timeout is not evidence about the tree, but it IS the gate
                 failing to produce a verdict for this arm, which is a loss).
   incomplete  — the WORKER did not reach a gate-passing state: it escalated a
                 verdict (blocked / design-fork / failed), left acceptance
                 bullets failing, or its review round never converged. The arm
                 built something; it just is not finishable without a human.
   infra       — everything else: machinery, claim, worktree, quota, denial,
                 dependency ordering, a lost return. Nothing was learned about
                 the model from these, which is precisely why they are named
                 apart from the two above.
```

## `parallel()` is not `Promise.all`: a REJECTED thunk is dropped to `nul
<a id="parallel-is-not-promise-all-a-rejected-thunk-is-dropped-to-n"></a>

```text
 `parallel()` is not `Promise.all`: a REJECTED thunk is dropped to `null`
 rather than failing the batch, and buildLevel's consuming loop
 (`for (const r of results) { if (!r) continue; }`) then skips that slot in
 silence — leaving the item in NEITHER `parked` NOR `escalations`. That is
 temperloop#437 exactly (a real run hit `item.acceptance.map` on a string and
 the item vanished), and the single-arm fan-out was hardened against it with a
 per-item `.catch()`.

 temperloop#2080 round-1 review [HIGH]: that guard is a CONVENTION every
 fan-out site has to remember, and the dual-build fan-outs remembered it for
 the not-in-scope branch only — so an in-scope item whose drive threw was
 silently lost again. Wrapping the thunk here makes the guard structural
 instead: every dual-build fan-out builds its thunks through this, so a future
 edit that adds an un-caught `await` inside one cannot reintroduce the drop.
 The returned thunk is `async` deliberately — that converts a SYNCHRONOUS
 throw in `fn`'s body (not just a rejected promise) into a rejection this
 function itself catches, which a bare `fn().catch()` would let escape.
```

## The barrier above stops at "every in-scope item is judged and recorded
<a id="the-barrier-above-stops-at-every-in-scope-item-is-judged-and"></a>

```text
 The barrier above stops at "every in-scope item is judged and recorded". This
 is what happens next, and it is deliberately the ONLY place in this file that
 turns a comparison into a merge decision:

   1. THE PRE-REGISTERED TALLY decides the level's winning arm from the item
      dispositions alone — no per-run judgement, no tie-break invented after
      seeing the numbers (tallyLevelPick below states the whole rule set).
   2. THE CALIBRATION GATE decides whether that pick may route by itself. An
      uncalibrated judge means the tally's per-item inputs are not yet known to
      agree with a human, so the level STOPS and asks, with no default.
   3. THE TWO OPERATOR LEVERS — a level-wide override and a per-item override —
      ride the same `level-pick` verdict grammar, and a per-item override is
      what makes the level's own pick `mixed`.
   4. ROUTING hands the winning arm's phase-1 context to driveItemPr() — the
      ordinary PR/CI/park path, unchanged — and only then archives and deletes
      the losing arm's branch.

 Nothing here merges: the merge gate stays the orchestrator's (build.md Step 4),
 exactly as on the single-arm path.
```

## dualBuildArmCost — ONE arm's whole-job cost across the level, as the t
<a id="dualbuildarmcost-one-arm-s-whole-job-cost-across-the-level-a"></a>

```text
 dualBuildArmCost — ONE arm's whole-job cost across the level, as the tally's
 tie-break reads it. "Whole-job" is deliberate: the comparison is between two
 ways of building the SAME level, so the tie-break is the level's total for
 that arm, never a per-item average that would let one cheap item outvote the
 rest. Tokens are the unit; wall-clock is the fallback ONLY when neither arm
 reported tokens at all, so a partly-instrumented level never silently
 compares tokens against milliseconds. `known` is false when the arm reported
 neither — which is what makes "the tie-break could not be evaluated" a state
 the caller names rather than a zero it mistakes for cheap.
```

## Pre-registered means: every rule below is fixed BEFORE the level runs,
<a id="pre-registered-means-every-rule-below-is-fixed-before-the-le"></a>

```text
 Pre-registered means: every rule below is fixed BEFORE the level runs, and
 none of them reads anything but the item dispositions the barrier already
 produced. That is the whole point — a tie-break chosen after seeing which arm
 it would favour is not a measurement, and this function is the one place that
 property is checkable.

 PER ITEM, exactly one of three outcomes, in this order:
   1. GATE FAIL = LOSS. An arm with no gate-passing branch loses the item
      outright. If exactly one arm gated, that arm WINS the item (`gate`) — a
      model that ships a green branch beat one that did not, and no judge is
      needed to say so. If NEITHER gated, the item is UNRESOLVED
      (`both-arms-failed`): there was nothing to compare.
   2. A JUDGED TIE IS UNRESOLVED, counting for NEITHER arm. So is every
      non-verdict (`one-arm-only`, `spike-arm`, `judge-unavailable`, …) — the
      reason rides the item row, so an unresolved item is never silently
      indistinguishable from a judged one.
   3. Otherwise the judge's preferred arm wins the item (`judge`).

 LEVEL: the arm with more item wins. A TALLY TIE — including the 0–0 tie a
 wholly unresolved level produces — goes to the CHEAPER arm by whole-job cost
 (`tally-tie-cheaper`). When neither arm's cost is known, or the two are
 exactly equal, the tie goes to `baseline` (`tally-tie-incumbent`): the
 incumbent is what the level would have been built on with no harness at all,
 so "we learned nothing" resolves to changing nothing.
```

## Returns { level, armFor(slug), overrideFor(slug), source }.
<a id="returns-level-armfor-slug-overridefor-slug-source"></a>

```text
 Returns { level, armFor(slug), overrideFor(slug), source }.
   no answer / `confirm`  → every item takes the tally's winner; level = winner.
   `override-level <arm>` → every item takes <arm>; level = <arm>; every row
                            carries `override: { applied, scope: "level" }`.
   `override-item …`      → the named items take their own arm, every other
                            item takes the tally's winner, and the level's own
                            pick becomes **`mixed`** — because it is: the level
                            no longer shipped one arm's work, and recording the
                            winner's name there would misreport what merged.
```

## A spike arm produced a verdict note, not a branch — there is nothing t
<a id="a-spike-arm-produced-a-verdict-note-not-a-branch-there-is-no"></a>

```text
 A spike arm produced a verdict note, not a branch — there is nothing to
 push. It already completed (driveArm's spike branch), so this is a normal
 disposition, not a loss, and no PR, stamp or archive applies.
 UNREACHABLE BY CONSTRUCTION, kept deliberately as a fail-safe: `spike`
 derives from `item.kind`, which is identical across both arms of one item,
 so a pair can never be half-spike, and `driveLevelDualBuild` excludes any
 pair with `run.arms.some(a => a.spike)` from `pickables` before a pick is
 ever attempted. If a future change makes a spike pair pickable, this branch
 parks it cleanly instead of letting the winning-arm-lost path below re-drive
 a spike (which has no `ctx`) as though its missing branch were a gate loss.
```

## PARKED WITH NO PR. This is the barrier's visible form on the return
<a id="parked-with-no-pr-this-is-the-barrier-s-visible-form-on-the"></a>

```text
 PARKED WITH NO PR. This is the barrier's visible form on the return
 object: the item is disposed of (so the zero-disposition guard is
 satisfied — it was, and the guard is right that a level disposing of
 NOTHING is a contradiction), it carries every arm's result, and it
 carries `pr: null` because opening one is precisely what the barrier
 forbids until the pick. `acceptance_results` is EMPTY on purpose: the
 arms' results are per-arm and live in `dual_build.arms[]`, and hoisting
 one arm's to the top level would read as a pick nobody made.
 A SPIKE pair is not pickable (temperloop#2083). Its arms produce a
 read-only verdict note rather than a branch, so there is no PR to route
 and no diff a pick could be about — the item is already finished. It
 would otherwise hold a whole level for a confirm over a choice that
 changes nothing, and count as an `unresolved` item in a tally it
 contributed no evidence to.
```

## Claim-first applies to EVERY kind, spike included (build.md L312: "For
<a id="claim-first-applies-to-every-kind-spike-included-build-md-l3"></a>

```text
 Claim-first applies to EVERY kind, spike included (build.md L312: "For a
 spike: run 3a (claim, mark `[~]`), then spawn a read-only worker"). It is
 therefore the FIRST step of the prelude and is branched on BEFORE the
 kind:spike verdict-park below, so a spike-labeled item takes the
 cross-session board lock before any investigation begins — without it, two
 concurrent drivers could each pull and investigate the same spike with no
 lock (temperloop#650).
 Skipped on a continuation: the issue is already claimed by this run (the
 escalation never released it), and a re-claim is at best a self-owned
 no-op (spec 3d-esc step 4: "does NOT re-run 3a").

 ALSO skipped for a dual-build ARM (temperloop#2080). An in-scope item is
 built TWICE, and a board write is a statement about the ITEM, not about one
 arm of it: claiming per arm would write the same issue twice (the second
 claim reading as a self-conflict), and the Done/close cascade must reflect
 the arm that WON, which is not known until the level pick. So every board
 write for an in-scope item is BUFFERED — bufferBoardWrite() below records
 one entry per item, returned on the level's `dualBuild.board_writes` for
 the pick to flush. The cross-session lock this costs is real and is the
 declared trade of the barrier: the level's claims land in one batch after
 the pick rather than at first touch.
```

## temperloop#2137 — the ALREADY-FIXED CONTINUATION CLOSE, and it sits HE
<a id="temperloop-2137-the-already-fixed-continuation-close-and-it"></a>

```text
 temperloop#2137 — the ALREADY-FIXED CONTINUATION CLOSE, and it sits HERE,
 before the spawn, because that is the only place the spawn can still be
 avoided. Runs at most one machinery call, and only on a `review-blocking`
 continuation whose findings name a checkable `<path>:<line>`; every other
 path (a fresh item, any other escalation kind, findings with no located
 line) short-circuits in JS with no extra call at all. See
 continuationAlreadyFixed() for the fail-closed contract — `fixed` is true
 ONLY on a positively-established ALREADY_FIXED, so every uncertainty spawns
 the worker exactly as before.
```

## temperloop#1182: a host-config DEFERRAL (`passed: false` + a non-empty
<a id="temperloop-1182-a-host-config-deferral-passed-false-a-non-em"></a>

```text
 temperloop#1182: a host-config DEFERRAL (`passed: false` + a non-empty
 `deferred_host_config`) is excluded here — it is not a failure, it is a
 criterion this worker structurally could not observe, re-homed to the
 orchestrator's parent-side check at build.md §4a. Escalating it would
 stall the level on a reading that is `false` in every worktree on every
 host regardless of the truth (foundation#1556). A bare `passed: false`
 with no marker escalates exactly as before — the exclusion is the pair,
 never the boolean alone, so this cannot silently swallow a real failure.
```

## temperloop#1663: run the acceptance gate DIFF-SCOPED — only the gates 
<a id="temperloop-1663-run-the-acceptance-gate-diff-scoped-only-the"></a>

```text
 temperloop#1663: run the acceptance gate DIFF-SCOPED — only the gates this
 item's own changed paths can reach, resolved through gate-paths.tsv.

 WHY. The full per-item suite could not survive within-level parallelism, and
 the ceiling it hit is not tunable. Measured on a 3-item level: 55 minutes,
 21 agents, 1.24M subagent tokens, ZERO items landed — all three escalated
 `acceptance-gate-timeout` with every worker finished and committed and only
 the verdict missing. Three concurrent full suites is 3x QUALITY_GATES_JOBS
 workers on one machine; contention inflated the gate tail 200-300% (gates
 that take seconds took 121s), while GATE_SLICE_SECS_MAX sits only 20% above
 the budget that failed and CANNOT be raised past AGENT_BASH_CAP_MS. So the
 suite has to get SHORTER, not the budget longer — and the map that knows
 which gates a diff can reach already exists and was already trusted.

 WHY IT IS SAFE. This puts §3e.5 on exactly the same footing as the
 `pull_request` run of CI's `checks` job, which has been scoped through this
 same map since #1024 — so scoping here adds no failure mode that the PR
 check does not already carry. What actually gates `main` is the UNSCOPED
 merge_group run, and that is untouched. Every resolution failure in the
 selector widens to the full set (gate-selection.sh's four silent-green
 defenses), and a scoped run names every gate it skipped, twice.

 THE SEAM IS AN ENV VAR, NOT THE `--scoped` FLAG, for the same reason the
 slice budget below is: a consuming repo vendoring an OLDER quality-gates.sh
 ignores an unknown env var and runs the whole suite (the pre-#1663 behavior,
 still correct), whereas an unknown FLAG exits 2 "usage" and reads back here
 as a GATE FAILURE.

 BUILD_GATE_SCOPED is read HERE, in the emitted shell, rather than plumbed in
 as an orchestrator `input.*` key like gateSliceSecs. That is deliberate and
 is the narrower seam, not a shortcut: gateSliceSecs must reach the .mjs's
 OWN control flow (it derives GATE_BASH_TIMEOUT_MS and bounds the slice
 loop), and the Workflow runtime has no shell to source build.config.sh with
```

## temperloop#2133 — this line IS the decay signal an operator reads to d
<a id="temperloop-2133-this-line-is-the-decay-signal-an-operator-re"></a>

```text
 temperloop#2133 — this line IS the decay signal an operator reads to decide
 whether to raise BUILD_GATE_SLICE_SECS or split the gate list, so every
 figure in it must mean the same thing on every run. `cap ${gateSliceCeiling}`
 did not: on a run that spent an extension it rendered the MID-RUN ceiling,
 which is neither the configured base cap nor the hard bound. Name the base
 cap, the extension allowance, the hard bound and the extensions actually
 spent, each derived from its constant — never a literal (kernel § Named-
 setting convention).
```

## The PR body was assembled at 3f from the ORIGINAL review round only, w
<a id="the-pr-body-was-assembled-at-3f-from-the-original-review-rou"></a>

```text
 The PR body was assembled at 3f from the ORIGINAL review round only, while
 park()'s Step-6 tally merges every round — so a reviewer that ran only in
 a CI-fix round (its diff includes the fix commit, which can touch file
 classes the original diff never did) had real findings that reached ONLY
 the tally: the body's "ran:" line affirmatively named a reviewer set that
 omitted it, and its findings were invisible at the merge gate (issue
 #1846 — body said "ran: docs-reviewer"; review.ran carried shell-reviewer
 and its three findings). Rebuild the FULL body through pr.sh's own
 assemble_body path (`open --update-pr` — never regex surgery on the live
 body) with the suffix merged across every round. Skipped when the merged
 suffix equals 3f's (no fix round, or fix rounds that routed no reviewer)
 — the common path costs nothing. A failed update DEGRADES with a loud log
 line rather than taking down a CI-green item: review is advisory (never a
 `checks` gate), and the findings still ride the Step-6 tally below.
```

## temperloop#1450 — re-run §3e against the CI-fix DIFF before pushing it
<a id="temperloop-1450-re-run-3e-against-the-ci-fix-diff-before-pus"></a>

```text
 temperloop#1450 — re-run §3e against the CI-fix DIFF before pushing it.
 The fix worker can touch anything (including the very command doc
 whose edit tripped the original lint failure): without this, a
 CI-fix commit ships to the open PR with NO second pass through the
 mandatory claude/commands/*.md -> workflow-reviewer rule
 (foundation#1007) — the exact structurally-guaranteed-skip class this
 item exists to close, just relocated one stage later than 3f. Reuses
 the SAME runReviewers() the original 3e pass used; its own diff fetch
 re-reads the worktree, whose HEAD now includes the fix commit, so the
 diff naturally covers the fix on top of the original push.
 No third argument, deliberately (temperloop#2127 round 2): the round-1
 pass that got this item pushed had ZERO blocking findings, so there is
 no prior-findings text to carry — and passing none is what selects
 reviewContinuationSection()'s truthful clean-prior-round premise. This
 call site bumps the SHARED §3e round counter, so it is the single most
 frequent producer of a `round > 1` continuation whose prior round was
 clean; the old `round > 1` premise asserted the opposite on every one
 of them.
```

## killNotDetachWatchdog — one watchdog, and why it cannot depend on what it watches (temperloop#2210)
<a id="why-it-is-one-function-and-not-two-copies-bash-timeout-detach"></a>

```text
 WHY IT IS ONE FUNCTION AND NOT TWO COPIES. `Bash timeout:` DETACHES, it does
 not kill — a 500s-bounded command was moved to the background at its bound
 and then ran UNBOUNDED for 12.5h on epic #2065. The only thing that actually
 stops that is a watchdog compiled INTO the command text, so it rides along
 into the detached process and fires there. This file now arms one in two
 places (the #1071 machinery-step bound below, and the worker's own scoped
 gate), and a second hand-rolled copy is how one of them silently loses the
 property the other keeps.

 THE WATCHDOG DOES NOT DEPEND ON WHAT IT WATCHES. The #2065 post-mortem's
 third cause was a guard written as `until ! pgrep -f <pattern>` — it asked
 the WATCHED process's own liveness for permission to fire, so the hang took
 the guard down with it. This one knows exactly one fact, a pid: it never
 greps for a command pattern, never re-reads the child's state, and never
 waits on the child's cooperation. It sleeps for the bound and signals.

 Kill ORDER is load-bearing, and the obvious order is wrong — see the design
 note carried at the #1071 call site below. Children are ENUMERATED (by
 parent pid, not by pattern) BEFORE the parent dies, because reparenting
 makes them unfindable the moment it does.

 `</dev/null >/dev/null 2>&1` at the subshell boundary is the foundation#861
 pipe-leak fix: without it the watchdog's `sleep` inherits the write end of
 any command substitution wrapping the call, and every FAST call stalls for
 the full bound on an EOF the orphaned sleep is holding open.
 `opts.group` — for a command started under `set -m`, whose pid IS therefore
 its own process-group id, so ONE signal reaps the WHOLE tree. Without it the
 kill reaches the direct child and its immediate children only, which is
 enough for a machinery step (a single helper script) but NOT for the worker's
 scoped gate, whose suite fans out a pool of grandchildren — exactly the
 orphaned process trees bounded-suite.sh was written for. The group signal is
 emitted BEFORE the single-pid kill and both are kept: a host where job
 control could not give the child its own group degrades to the direct-child
 kill rather than to nothing. Omitting `opts` emits the pre-#2210 line
 byte-for-byte, so the #1071 call site below is unchanged.
```

## The worker scoped-gate liveness bound (temperloop#2210)
<a id="the-failure-this-bounds-workergatecmd-hands-the-worker-one-gate"></a>

```text
 THE FAILURE THIS BOUNDS. workerGateCmd() below hands the worker ONE gate
 invocation and tells it to raise the Bash tool's `timeout` parameter. That
 parameter DETACHES, it does not kill: at the bound the Bash tool moves the
 command to the background and the worker's turn ends, so a `quality-gates.sh`
 that WEDGES keeps running with nobody waiting on it and nothing that will
 ever stop it. Measured cost on epic #2065: one such run went 12.5 HOURS, and
 on epic #2133 level 0 fourteen concurrent `quality-gates.sh` trees were
 inventoried, six stacked in ONE worktree — so the next run there contended
 with its own predecessors and reported false REDs that both passed in clean
 isolation with no code change between. The worker's sentinel meanwhile sat at
 `{"state":"running"}` forever, which is indistinguishable from a gate that is
 merely slow. That ambiguity IS the defect.

 THE BOUND IS THE #1071 CEILING, NOT A NEW SETTING. The worker's gate is one
 step of the workflow's work, so it takes the workflow's own per-step
 wall-clock liveness ceiling — already repo-sized, already floored at one
 CI-poll/gate slice + 300s, already tunable through the named
 BUILD_MACHINERY_STEP_CEILING_SECS setting handed in as
 input.machineryStepCeilingSecs. Minting a second number here would be a
 tunable this file owns twice. It deliberately sits ABOVE the harness's
 foreground Bash ceiling: the Bash tool detaches first, and the compiled
 watchdog — which rode along INTO the detached process — is what then kills
 it. A bound at or below the detach point would never get the chance.
```
