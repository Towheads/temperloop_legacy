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

> **Part 4 of 7.** Split to stay under the per-file prose cap
> (`PROSE_BUDGET_TIER2_FILE_CAP`). Other parts: [`build-level.design-notes.md`](build-level.design-notes.md), [`build-level.design-notes-2.md`](build-level.design-notes-2.md), [`build-level.design-notes-3.md`](build-level.design-notes-3.md), [`build-level.design-notes-5.md`](build-level.design-notes-5.md), [`build-level.design-notes-6.md`](build-level.design-notes-6.md), [`build-level.design-notes-7.md`](build-level.design-notes-7.md).

## disposeReviewSlot — the verdict for ONE SETTLED reviewer slot, as a pu
<a id="disposereviewslot-the-verdict-for-one-settled-reviewer-slot-"></a>

```text
 disposeReviewSlot — the verdict for ONE SETTLED reviewer slot, as a pure
 descriptor: `{ kind: 'ran', text }` or `{ kind: 'skip', note }`. Purity is the
 point (temperloop#2032): runReviewers reads its slots in more than one pass so
 a reviewer that settles late is still consumed, and a disposition step that
 pushed straight into `ran`/`skipped`/`sections` would emit those in
 settlement order instead of route order. The caller writes exactly one
 disposition per slot, in route order, which is what keeps `ran` and `skipped`
 disjoint. Never call it on an unsettled slot — `slot.done` is the caller's
 precondition, and the caller re-reads it as late as it possibly can.
```

## Reuse machineryAgent's own resolution-failure detection (temperloop#10
<a id="reuse-machineryagent-s-own-resolution-failure-detection-temp"></a>

```text
 Reuse machineryAgent's own resolution-failure detection (temperloop#1014)
 as the precedent — the SAME two markers of "agent() could not resolve
 this agentType at all", never a broader catch. This is what makes the
 skip notice fire on GENUINE unavailability only, never as a guaranteed
 default.
```

## Every reviewer this repo names (the tsv's own agent-catalog-path
<a id="every-reviewer-this-repo-names-the-tsv-s-own-agent-catalog-p"></a>

```text
 Every reviewer this repo names (the tsv's own agent-catalog-path
 column; workflow-reviewer/docs-reviewer/architecture-reviewer/
 requirements-auditor) ships as source under claude/agents/ — so the
 remedy-bearing form (message-schema.md § Degradation notice's one
 sanctioned mode-2 variant) always applies here, never the bare form.
```

## REVIEW_SETTLE_DRAIN_TICKS — how many settlement turns a drain yields b
<a id="review-settle-drain-ticks-how-many-settlement-turns-a-drain-"></a>

```text
 REVIEW_SETTLE_DRAIN_TICKS — how many settlement turns a drain yields before
 giving up. A tick is one microtask (`await null`), never a wall-clock wait:
 under-draining can only cost one extra timer spawn (before the ceiling) or
 one reviewer left unrecovered (after it), never a wrong verdict, and
 over-draining costs nothing but empty turns.
```

## drainReviewSettlements — give every reviewer whose promise has already
<a id="drainreviewsettlements-give-every-reviewer-whose-promise-has"></a>

```text
 drainReviewSettlements — give every reviewer whose promise has already
 resolved the chance to RECORD that fact, then return. `slot.done` is set in a
 `.then` recorder, so a reviewer can be resolved-but-unrecorded for a few
 microtasks; this is the only honest way to read the fanout later than the
 instant an await hands back, and it is bounded by construction (no clock, no
 spawn, no wait). Used twice: before the ceiling's first timer spawn (a pure
 cost optimisation — a reviewer that already returned need not be paid for),
 and again by the disposition passes (temperloop#2032 — a reviewer that
 settled after the ceiling must not be reported as a timeout).
```

## awaitReviewFanout — temperloop#2003's ceiling, applied to the whole §3
<a id="awaitreviewfanout-temperloop-2003-s-ceiling-applied-to-the-w"></a>

```text
 awaitReviewFanout — temperloop#2003's ceiling, applied to the whole §3e
 fanout. Returns once every reviewer has settled OR the ceiling elapses,
 whichever comes first; it never rejects and never throws, and the caller reads
 each slot's own `done` flag to decide the per-reviewer disposition.

 RETURNS the seconds of wall clock this pass ACTUALLY waited — the sum of the
 slices whose ticks were honoured, never the nominal ceiling (temperloop#2064).
 That number is the `<actual>` the ceiling-breach notice reports, so a reader
 of the notice is told what was measured rather than what was budgeted: the
 #2064 incident is precisely a run whose two numbers differed by ~30x while
 only the budgeted one was ever printed.

 HOW IT MEASURES TIME WITHOUT A CLOCK. `Date.now()` throws in this runtime and
 there is no timer primitive, so the wait is raced against something that
 resolves ON a clock: reviewWaitAgent(), a machinery executor whose entire job
 is one `sleep`. Each slice is a separate spawn, so the elapsed total is the
 sum of the slices that have RETURNED — an accounting this file can do with
 integers alone.

 FAIL-OPEN, DELIBERATELY. If the timer itself cannot run (the auto-mode safety
 classifier denies it, the executor returns something else), the bound is
 simply unavailable and we fall back to the pre-#2003 behaviour — await the
 fanout — with a legible notice. A timer that resolved without actually
 sleeping would otherwise manufacture an INSTANT false ceiling breach on
 perfectly healthy reviews, which is far worse than the stall it bounds
 (kernel principle 7: advisory over enforced discipline).
```

## Drain already-resolved reviewer promises before paying for a timer spa
<a id="drain-already-resolved-reviewer-promises-before-paying-for-a"></a>

```text
 Drain already-resolved reviewer promises before paying for a timer spawn: a
 reviewer that has ALREADY returned is only pending as a MICROTASK here
 (spawning is synchronous). Pure cost optimisation — under-draining can only
 cost one extra timer spawn, never a wrong verdict, because the race below
 resolves immediately on a settled fanout either way. Shares the one drain
 helper with the post-ceiling disposition read (temperloop#2032), so the two
 reads of the same slot state cannot drift apart.
```

## THE #2049 CHECK. An elapse is a claim about wall clock, and this runti
<a id="the-2049-check-an-elapse-is-a-claim-about-wall-clock-and-thi"></a>

```text
 THE #2049 CHECK. An elapse is a claim about wall clock, and this runtime has
 no clock to audit it with — so the audit is the script's own measurement,
 which only a completed run can produce. `Number('')`/`Number(undefined)` are
 0/NaN and both fail the comparison, so an absent field fails CLOSED (to
 "no usable timer" → fail open on the fanout), never open into a false breach.
```

## reviewBoundReached(review) — the §3e convergence bound's ONE predicate
<a id="reviewboundreached-review-the-3e-convergence-bound-s-one-pre"></a>

```text
 reviewBoundReached(review) — the §3e convergence bound's ONE predicate
 (temperloop#1970), so both blocking call sites (the 3e pass and §3g's CI-fix
 re-review) ask the identical question and cannot drift apart. True when this
 round has blocking findings AND the item has spent its budget of review
 rounds: past that, the findings are CARRIED (PR body + parked tally) instead
 of escalating for another build-review round-trip. `review.round` is absent
 only on a return shape older than this item; `?? 1` then reads "first round",
 which can never trip the bound early.
```

## REVIEW_BLOCK_MARK — the EXPLICIT, machine-readable boundary of one rev
<a id="review-block-mark-the-explicit-machine-readable-boundary-of-"></a>

```text
 REVIEW_BLOCK_MARK — the EXPLICIT, machine-readable boundary of one reviewer's
 block inside `## Review notes` (temperloop#2009 review round 2).

 The `### <reviewer>` heading below is for a HUMAN. It is not a parseable
 boundary and never was: reviewBodySuffix splices `sec.text` VERBATIM, and a
 reviewer's own findings text carries `### ` headings of its own (ADR 0007's
 `### [HIGH] <name> in <file>`) plus free prose headings — a single-word
 `### Notes` is indistinguishable from `### docs-reviewer` by shape alone, and
 a fenced code block can contain literally anything. pr.sh's PR-body cap has to
 know where one round's prose ends to drop the OLDEST rounds first, and two
 successive passes at inferring that from Markdown were both spoofable by
 ordinary reviewer prose (the second dropped the NEWEST round's residual HIGH
 findings — precisely what temperloop#1970 routes into this section for the
 human at the merge gate).

 So the PRODUCER marks its own blocks. An HTML comment renders as nothing on
 GitHub, is anchored at line start, and carries the two facts the consumer
 needs (which reviewer, which round) as attributes rather than as prose to be
 re-derived. `sec.text` is neutralized before splicing, so a reviewer QUOTING
 this very design — entirely likely, since one already did — cannot inject a
 boundary. Consumer: review_notes() in workflows/scripts/build/pr.sh, which
 matches this token exactly, at line start, and never guesses from a heading.
 The two literals are kept in lockstep by a static guard in test_pr.sh.
```

## reviewBodySuffix — the ONE renderer of §3e evidence into the PR body
<a id="reviewbodysuffix-the-one-renderer-of-3e-evidence-into-the-pr"></a>

```text
 reviewBodySuffix — the ONE renderer of §3e evidence into the PR body
 (temperloop#1846), across EVERY round handed to it: rounds[0] is the
 original 3f pass, rounds[1..] are ciPollLoop's CI-fix re-reviews. Before
 this, the body suffix was built from rounds[0] alone while park()'s tally
 merged every round — so a reviewer that ran only in a CI-fix round (its
 diff includes the fix commit, which can touch file classes the original
 diff never did) had its findings affirmatively OMITTED from the body's
 "ran:" line and ## Review notes, the exact #1846 failure (body said
 "ran: docs-reviewer" while review.ran carried shell-reviewer and its three
 findings). Rendering rules:
   - the "ran:" line names every DISTINCT reviewer across all rounds — a
     name-set union, so it can never be a subset of the tally's review.ran;
   - every round's findings section is spliced, none de-duped away: a
     CI-fix round's block is relabeled `### <reviewer> (ci-fix round N)` so
     a reviewer that ran in two rounds keeps BOTH blocks, distinguishable;
   - skip notices are de-duped by their full note text only (byte-identical
     notices from re-running the same degraded route add no information);
   - each block opens with a REVIEW_BLOCK_MARK delimiter line (above) that
     names its reviewer and round, so the PR-body cap can find block edges
     without parsing Markdown out of reviewer prose.
 For a single round this renders the pre-#1846 shape plus those delimiters.
```

## temperloop#2020 — the gap payload behind a routing degradation, carrie
<a id="temperloop-2020-the-gap-payload-behind-a-routing-degradation"></a>

```text
 temperloop#2020 — the gap payload behind a routing degradation, carried
 into the parked record so the Step 6 tally (and a human reading it) can
 tell "no reviewer matched this diff" (a legitimate empty roster) from
 "the routing table never arrived" (a degraded one). The skip notice says
 it in prose; this says it in a field, with the expected/got figures the
 #1976/#1982 detectors actually computed.
```

## isAbsenceProof(proof) — does the predicate ASSERT AN ABSENCE (temperlo
<a id="isabsenceproof-proof-does-the-predicate-assert-an-absence-te"></a>

```text
 isAbsenceProof(proof) — does the predicate ASSERT AN ABSENCE (temperloop#944)?
 build.md §3e.6 / plan-schema § activation define this by shape: the predicate
 "negates its check (opens with `!`)". An absence proof passes trivially
 against a tree where the thing never existed, so it — and only it — needs the
 merge-base control pass below. A PRESENCE proof is false on an untouched tree
 by construction and has nothing to vacuously pass.
```

## activationProofCmd — run the class-A `proof:` predicate from <dir>'s r
<a id="activationproofcmd-run-the-class-a-proof-predicate-from-dir-"></a>

```text
 activationProofCmd — run the class-A `proof:` predicate from <dir>'s root and
 report Pass/Fail as the predicate's OWN exit code.

 THE VERDICT IS READ UN-PIPED, WHICH IS §3e.5'S *PREFERRED* SHAPE, NOT A
 WEAKER ONE (temperloop#68/#801). The predicate runs inside a command
 substitution — not a pipe — so `$?` is already the predicate's own status
 under both bash and zsh, with no PIPESTATUS/pipestatus read to get
 dialect-wrong and no `tee` to swallow it. build.md §3e.5 names exactly this:
 "prefer running the gate un-piped and branching on its exit directly".

 DO NOT ADD `set -o pipefail` HERE. It looks like belt-and-suspenders and is
 the opposite: it silently rewrites the meaning of the AUTHOR'S OWN predicate,
 in the one direction that makes this gate theater. `pipefail` reports the
 rightmost NON-ZERO status, and a predicate whose tail exits early on a match
 (`grep -q`, `head`) SIGPIPEs its upstream writer, which dies 141. For the
 wrap-immune ABSENCE idiom plan-schema.md documents
 (`! tr '\n' ' ' < f | tr -s ' ' | grep -q '<phrase>'`) that inverts the
 verdict on the case that matters:
   phrase PRESENT (must FAIL):  pipefail -> 141 -> `!` -> 0  == false PASS
                                no pipefail -> 0 -> `!` -> 1 == correct FAIL
 Reproduced deterministically, and asserted by the "pipefail" case in
 test_workflow.sh. `scripts/lint-pipe-grep-q.sh` (temperloop#1050) is the
 tree-wide guard for the same footgun. A false PASS on an absence proof is
 precisely what the temperloop#944 control pass exists to stop, so
 reintroducing it here would defeat the control one layer up.
```

## gateFreshnessCmd — the §3e.5 pre-gate freshness step (temperloop#1937)
<a id="gatefreshnesscmd-the-3e-5-pre-gate-freshness-step-temperloop"></a>

```text
 -----------------------------------------------------------------------------
 gateFreshnessCmd — the §3e.5 pre-gate freshness step (temperloop#1937).
 -----------------------------------------------------------------------------
 build.md §3e.5 runs `scripts/quality-gates.sh` against the worktree, and a
 handful of its gates (validate-check-surface-degenerate-coverage.sh,
 validate-exec-bit-registry.sh, validate-mandatory-step-signal.sh) RATCHET
 against the CURRENT `origin/main` — they diff the worktree's registry rows
 against main's own, and flag any row main gained that the worktree never
 touched as REGRESSED. A worktree branched from main hours or days earlier
 (a long worker run, or a slow level) can be behind by the time the gate
 runs, so those rows are false positives: real work that landed on main
 AFTER this branch was cut, misread as this item's own regression. The live
 incident: the temperloop#1934 fix (a sibling item on this same level) merged
 while this worktree was mid-build and cost it a full gate round.

 Fetch origin and bring the worktree up to `origin/main` HERE, strictly
 before the gate runs, so the gate always measures against a tree that is
 least as current as main — never behind it. ONE combined shell script
 (fetch, ancestor-check, conditional rebase): this is always exactly ONE
 runMachinery call, never a separate check-then-rebase pair, so handling the
 stale case costs no additional machinery step beyond the check itself.

 `origin/main` is hardcoded rather than resolved through the
 default_branch()-style fallback chain reviewDiffCmd/activationControlCmd
 use (origin/HEAD, else main/master): this step exists specifically to match
 the exact ratchet target the named §3e.5 validators use — `origin/main`,
 by their own construction — not a generic default branch. A repo whose
 protected branch is genuinely not `main` needs a different fix than this
 one, not a guessed fallback here.

 Eight outcomes:
   FRESHNESS_NO_GATE  — round 3 (temperloop#1937 HIGH, workflow): the
     worktree carries no `scripts/quality-gates.sh` at all — the SAME
     `[ -x … ]` presence test gateCmd's own GATE_ABSENT arm makes, checked
     HERE first, before the fetch. There is nothing for this step to
     protect on a gate-absent project, so it takes the byte-identical
     pre-change path: no fetch, no rebase, no follow-on machinery.
   FRESHNESS_CURRENT  — `git merge-base --is-ancestor origin/main HEAD`
     already true (the worktree is at or ahead of main). No rebase is
     attempted — the JSON line still names both SHAs for the record.
   FRESHNESS_REBASED  — origin/main was ahead; `git rebase origin/main`
     replayed the worker's commits onto it cleanly. The JSON line names both
     SHAs (`worktree_base` = the worktree's HEAD after the rebase,
     `main` = the origin/main tip it was rebased onto).
   FRESHNESS_DIRTY    — round 2 (temperloop#1937 HIGH): origin/main was
     ahead, but the worktree carries uncommitted TRACKED-file edits, so git
     would refuse to even START the rebase ("cannot rebase: You have
     unstaged changes") — a non-zero exit exactly like a real content
     clash. Probed via `git status --porcelain --untracked-files=no`
     immediately BEFORE the rebase is attempted (never after), mirroring
     `pr.sh cmd_rebase`'s DIRTY_WORKTREE vs REBASE_CONFLICT split
     (temperloop#735) — untracked files are deliberately not dirt here
     (the worktree always carries at least the untracked `.build-guard`).
     The rebase is NEVER attempted on this path, so it can never be
     misread as FRESHNESS_CONFLICT (which would report an empty
     `conflict_files` and a false "rebase aborted" disposition).
   FRESHNESS_CONFLICT — the rebase hit a real content clash: `git diff
     --name-only --diff-filter=U` (read BEFORE the abort — the merge
     markers vanish once it runs) names at least one conflicted path. Then
     `git rebase --abort` runs so the worktree is left intact on its
     PRE-rebase commit — never a half-applied rebase, never a silent
     revert, and NEVER pushed as a known-stale branch. The JSON line's
     `detail` (round 3, MEDIUM) carries the tail of the rebase's own
     stdout+stderr, and `disposition` names exactly what was done, so a
     human resolving `stale-worktree` by hand knows the worktree was not
     touched.
   FRESHNESS_REBASE_ERROR — round 3 (temperloop#1937 MEDIUM): the rebase
     failed (non-zero exit) but `--diff-filter=U` found NO conflicted
     files — a pre-rebase hook, a missing commit identity, or a leftover
     in-progress rebase, none of which are a content clash. Reported as its
     OWN outcome (never collapsed into FRESHNESS_CONFLICT's shape, which
     would report an empty `conflict_files` and falsely claim a clash was
     aborted) with the same abort + `detail` tail treatment.
   FRESHNESS_ERROR    — the fetch/resolve step itself could not run (no
     network, no `origin/main`, or `git fetch` itself failed after one
     retry). This step's job is to PREVENT a false gate failure, never to
     manufacture one of its own — runGateFreshness() below treats this as
     fail-OPEN (log and proceed to the gate on the tree as it stands),
     exactly the pre-#1937 behavior. `detail` carries the fetch's own
     stderr (round 3, MEDIUM) so a genuine outage is diagnosable rather than
     a bare constant string.
   FRESHNESS_TIMEOUT  — round 2 (temperloop#1937 MEDIUM): the OUTER Bash-tool
     timeout killed this whole script before it printed any JSON line —
     possibly mid-`git rebase`, leaving a rebase in progress on disk. Unlike
     FRESHNESS_ERROR (nothing ran), the tree may now be mid-rebase, so
     fail-open would run the gate against a half-rebased tree — worse than
     the pre-#1937 behavior. runGateFreshness() below gives this its OWN
     arm: a follow-up probe checks for an in-progress rebase and aborts it,
     then ALWAYS escalates `stale-worktree` — never the fail-open
     FRESHNESS_ERROR path.

 `git fetch origin main`'s stderr is captured rather than discarded (round 3,
 MEDIUM): under `parallel()` sibling worktrees fetch concurrently, and a
 transient `cannot lock ref` race is retried ONCE (short sleep) before it is
 reported as FRESHNESS_ERROR — a race is not evidence the network or
 `origin/main` itself is unreachable, and silently swallowing it would fail
 open back to the pre-#1937 behavior for no real reason.

 Every JSON line below is built with `jq -cn --arg …`, never a raw `printf`
 substitution (round 3, LOW) — the same discipline `pr.sh cmd_rebase` uses —
 so no interpolated value (a path, a git-output tail) can break the line's
 JSON shape. All payload field names are snake_case throughout (round 3, LOW).
```

## round 2 (HIGH, temperloop#1937): probe dirtiness BEFORE attempting the
<a id="round-2-high-temperloop-1937-probe-dirtiness-before-attempti"></a>

```text
 round 2 (HIGH, temperloop#1937): probe dirtiness BEFORE attempting the
 rebase — git's own refusal-to-start is a non-zero exit indistinguishable
 from a content conflict, so the split has to happen here, from git's
 state, rather than from the rebase's exit code or its (reworded-between-
 releases) stderr prose.
```

## gateFreshnessTimeoutProbeCmd — round 2 (temperloop#1937 MEDIUM): what 
<a id="gatefreshnesstimeoutprobecmd-round-2-temperloop-1937-medium-"></a>

```text
 gateFreshnessTimeoutProbeCmd — round 2 (temperloop#1937 MEDIUM): what to run
 when the OUTER Bash-tool timeout (FRESHNESS_TIMEOUT) kills gateFreshnessCmd()
 mid-flight, possibly mid-`git rebase`. A second, cheap machinery call —
 mirroring the shape of disposeStepTimeout()'s own follow-up probe for the
 inner STEP_TIMEOUT path, not that function itself (its probeSideEffects()
 ladder is push/PR-open specific and has nothing to say about a rebase). If a
 rebase is left in progress it is aborted, restoring the worktree to its
 pre-rebase commit exactly like gateFreshnessCmd's own FRESHNESS_CONFLICT
 arm; either way the caller escalates rather than proceeding blind.

 round 3 (HIGH, shell, temperloop#1937): every /build worktree is a LINKED
 worktree (`git worktree add`), whose `.git` is a pointer FILE, not a
 directory — `[ -d .git/rebase-merge ]` is therefore ALWAYS false here; the
 real state lives under `git rev-parse --git-dir` (…/.git/worktrees/<slug>/
 rebase-merge). Rather than resolve and test that path by hand, run
 `git rebase --abort` UNCONDITIONALLY and read ITS OWN exit status as the
 in-progress verdict: exit 0 means a rebase WAS in progress and is now
 aborted; a non-zero "no rebase in progress" exit means there was none to
 abort, which is not itself an error worth surfacing.
```

## round 2 (HIGH, temperloop#1937): git refused to even START the rebase
<a id="round-2-high-temperloop-1937-git-refused-to-even-start-the-r"></a>

```text
 round 2 (HIGH, temperloop#1937): git refused to even START the rebase
 because the worktree carries uncommitted tracked-file edits — probed
 BEFORE the rebase was attempted, so this is never a content conflict
 (gateFreshnessCmd's own header). Route into the EXISTING dirty-worktree
 kind (never stale-worktree with an empty conflict list): the fix is
 committing/discarding the edits, not resolving a rebase.
```

## Never `acceptance-gate-failed` — the gate never ran, so a Fail verdict
<a id="never-acceptance-gate-failed-the-gate-never-ran-so-a-fail-ve"></a>

```text
 Never `acceptance-gate-failed` — the gate never ran, so a Fail verdict
 would be a lie. This is its own kind: the worktree's BASE is stale, not
 its work broken. The worktree is intact (see gateFreshnessCmd's own
 header) on its pre-rebase commit; the fix is always resolving the
 rebase by hand (or re-driving once main settles), never re-reading the
 conflict as a code defect.
```

## round 2 (MEDIUM, temperloop#1937): the outer Bash-tool timeout can kil
<a id="round-2-medium-temperloop-1937-the-outer-bash-tool-timeout-c"></a>

```text
 round 2 (MEDIUM, temperloop#1937): the outer Bash-tool timeout can kill
 gateFreshnessCmd() mid-`git rebase`, leaving a rebase in progress on
 disk. FRESHNESS_ERROR's fail-open is sound only when the fetch/resolve
 step never ran at all; here the tree may be mid-rebase, so proceeding
 blind is exactly the false-signal risk #1937 exists to prevent. Run the
 follow-up probe, abort any in-progress rebase it finds, and ALWAYS
 escalate `stale-worktree` — regardless of what the probe itself
 reports — never falling into the fail-open FRESHNESS_ERROR path.
```

## round 3 (MEDIUM, workflow): trust `rebase_in_progress`/`aborted` ONLY
<a id="round-3-medium-workflow-trust-rebase-in-progress-aborted-onl"></a>

```text
 round 3 (MEDIUM, workflow): trust `rebase_in_progress`/`aborted` ONLY
 when the probe itself actually resolved (FRESHNESS_TIMEOUT_PROBE) —
 otherwise (FRESHNESS_TIMEOUT_PROBE_ERROR, or the probe's own inner
 STEP_TIMEOUT watchdog) those fields are simply absent, and reading
 `undefined === true` as `false` would confidently — and wrongly —
 assert nothing was in progress. Report the unknown state as its own
 disposition instead of guessing.
```

## Both remaining axes read `rows`; with no trustworthy table there is
<a id="both-remaining-axes-read-rows-with-no-trustworthy-table"></a>

```text
 Both remaining axes read `rows`; with no trustworthy table there is
 nothing to decide for this file, and guessing is the #1976/#1982
 silent-misroute. The command-doc rule above has already been recorded.
```

## temperloop#2020 — set (not returned from) the gap arm below, so a degr
<a id="temperloop-2020-set-not-returned-from-the-gap-arm-below"></a>

```text
 temperloop#2020 — set (not returned from) the gap arm below, so a degraded
 relay falls THROUGH to the routing decision with only the table-dependent
 axes withdrawn. See the arm's own comment for why an early return here was
 wrong.
```

## The orchestrator-supplied table wins outright when present (#1982); th
<a id="the-orchestrator-supplied-table-wins-outright-when-pres"></a>

```text
 The orchestrator-supplied table wins outright when present (#1982); the
 relayed table (`tsv_lines`, or the legacy `tsv` scalar — reviewDiffTsvText
 normalizes both) is the legacy path, kept for an un-migrated caller.
```

## Seeded, not appended: the degradation notice must reach the PR body an
<a id="seeded-not-appended-the-degradation-notice-must-reach-t"></a>

```text
 Seeded, not appended: the degradation notice must reach the PR body and
 the Step 6 tally whether or not any table-independent route then ran.
```

## `#<reviewer>` (not `:<reviewer>`) matches the label grammar every
<a id="reviewer-not-reviewer-matches-the-label-grammar-every"></a>

```text
 `#<reviewer>` (not `:<reviewer>`) matches the label grammar every
 other multi-part label in this file already uses (e.g.
 `ci-batch:<slug>#<n>`) — the slug is always the run of characters up
 to the first `#`, never a second `:`-delimited segment.
```

## Pass 1 — consume every reviewer that has settled. disposeReviewSlot() 
<a id="pass-1-consume-every-reviewer-that-has-settled-disposer"></a>

```text
 Pass 1 — consume every reviewer that has settled. disposeReviewSlot() is
 PURE: it returns a descriptor and writes nothing, so a straggler can be
 re-read afterwards without the tally having been half-written out of route
 order in the meantime.
```

## `timed_out` distinguishes this from the other three skip reasons for a
<a id="timed-out-distinguishes-this-from-the-other-three-skip-"></a>

```text
 `timed_out` distinguishes this from the other three skip reasons for a
 reader of the parked tally; `mandatory` is what drives mandatory_ok, so
 the tally reflects reality here exactly as it does on every other skip.
```

## temperloop#1450 — keep the FULL text, not just the name: a MEDIUM/LOW-
<a id="temperloop-1450-keep-the-full-text-not-just-the-name-a-"></a>

```text
 temperloop#1450 — keep the FULL text, not just the name: a MEDIUM/LOW-only
 review is still real advisory output and must not evaporate once the HIGH
 check below has read it.
```

## temperloop#2064 — the tick actually honoured. A `waited_secs` far belo
<a id="temperloop-2064-the-tick-actually-honoured-a-waited-sec"></a>

```text
 temperloop#2064 — the tick actually honoured. A `waited_secs` far below
 `ceiling_secs` in an escalation payload IS the timer defect, reported
 without anyone having to correlate agent transcripts by hand.
```

## A genuine (non-resolution) error is not evidence the capability is
<a id="a-genuine-non-resolution-error-is-not-evidence-the-capa"></a>

```text
 A genuine (non-resolution) error is not evidence the capability is
 unavailable, but review is advisory (never a `checks` gate) — degrade
 rather than take the whole item down over an LLM-judgment pass.
```

## temperloop#2064 — name the REFUSAL case explicitly. "The timer is
<a id="temperloop-2064-name-the-refusal-case-explicitly-the-ti"></a>

```text
 temperloop#2064 — name the REFUSAL case explicitly. "The timer is
 unavailable" is true of every unusable tick, but a permission control
 refusing the wait command is the one shape an operator can actually act
 on, and the one that silently collapsed the ceiling before this split.
```

## The OBSERVABILITY half (mirrors #1071's STEP_SLOW notice): a long revi
<a id="the-observability-half-mirrors-1071-s-step-slow-notice-"></a>

```text
 The OBSERVABILITY half (mirrors #1071's STEP_SLOW notice): a long review
 becomes visible here, well before the ceiling gives up on it.
```

## The tool-timeout arm: an observation, honoured as elapsed (budget > in
<a id="the-tool-timeout-arm-an-observation-honoured-as-elapsed"></a>

```text
 The tool-timeout arm: an observation, honoured as elapsed (budget > interval).
 Reachable ONLY past the refusal check above — that is what keeps it honest.
```

## Matches an opening comment whose first token is the mark and that has 
<a id="matches-an-opening-comment-whose-first-token-is-the-mar"></a>

```text
 Matches an opening comment whose first token is the mark and that has not
 already been neutralized, so re-neutralizing is idempotent rather than
 accreting `-quoted` suffixes.
```

## One block's opening delimiter. The reviewer name is reduced to the blo
<a id="one-block-s-opening-delimiter-the-reviewer-name-is-redu"></a>

```text
 One block's opening delimiter. The reviewer name is reduced to the block
 grammar's own character set so it can never close the comment early or break
 the attribute quoting; `round` is 0 for the original 3f pass and N for
 ciPollLoop's Nth CI-fix re-review, matching the `(ci-fix round N)` label.
```

## Strip the block delimiter's power out of text that is about to be spli
<a id="strip-the-block-delimiter-s-power-out-of-text-that-is-a"></a>

```text
 Strip the block delimiter's power out of text that is about to be spliced
 verbatim. The mark is kept legible (a human reading the PR still sees what the
 reviewer wrote) but can no longer match the consumer's token.
```

## activationClass(item) — the item's declared activation class, normaliz
<a id="activationclass-item-the-item-s-declared-activation-cla"></a>

```text
 activationClass(item) — the item's declared activation class, normalized and
 upper-cased ('' when the item declares no block). Read off the plan-schema
 `activation:` block the orchestrator now passes through (build.md Step 3).
```

## jsonSafeDetail — shell fragment that reduces "$__out" to a string safe
<a id="jsonsafedetail-shell-fragment-that-reduces-out-to-a-str"></a>

```text
 jsonSafeDetail — shell fragment that reduces "$__out" to a string safe to
 interpolate into a JSON string literal: newlines/tabs to spaces, quotes and
 backslashes deleted, non-printables dropped, tail-truncated. Deliberately no
 jq dependency (the predicate runs in a bare worktree, on any host).
```

## No `set -o pipefail` here either, and for the same reason as
<a id="no-set-o-pipefail-here-either-and-for-the-same-reason-a"></a>

```text
 No `set -o pipefail` here either, and for the same reason as
 activationProofCmd above — the control MUST evaluate the identical
 predicate under identical semantics, or it is not a control at all.
```

## round 3 (HIGH, workflow, temperloop#1937): the SAME presence check
<a id="round-3-high-workflow-temperloop-1937-the-same-presence"></a>

```text
 round 3 (HIGH, workflow, temperloop#1937): the SAME presence check
 gateCmd() makes below (`[ ! -x <qgBin> ]` → GATE_ABSENT) — a project
 with no vendored gate script has nothing for this step to protect.
```

## round 3 (MEDIUM, shell): capture fetch stderr and retry once on a
<a id="round-3-medium-shell-capture-fetch-stderr-and-retry-onc"></a>

```text
 round 3 (MEDIUM, shell): capture fetch stderr and retry once on a
 concurrent-fetch lock race before reporting FRESHNESS_ERROR.
```

## round 3 (MEDIUM, shell): rename the captured var (was the unused `out`
<a id="round-3-medium-shell-rename-the-captured-var-was-the-un"></a>

```text
 round 3 (MEDIUM, shell): rename the captured var (was the unused `out`)
 and keep it for a `detail` tail on EITHER failure shape below.
```

## round 3 (MEDIUM, shell): no conflicted files — NOT a content clash, so
<a id="round-3-medium-shell-no-conflicted-files-not-a-content-"></a>

```text
 round 3 (MEDIUM, shell): no conflicted files — NOT a content clash, so
 this is its own not-a-conflict outcome, never FRESHNESS_CONFLICT's
 shape (which would report an empty `conflict_files` and a false
 "conflict" disposition for, say, a pre-rebase hook failure).
```

## round 3 (HIGH, workflow): no vendored gate script — byte-identical to
<a id="round-3-high-workflow-no-vendored-gate-script-byte-iden"></a>

```text
 round 3 (HIGH, workflow): no vendored gate script — byte-identical to
 the pre-#1937 path. §3e.5's own gateCmd() will independently make the
 identical presence check and report GATE_ABSENT; nothing to do here.
```

## round 3 (MEDIUM, shell): a rebase failure with NO conflicted files
<a id="round-3-medium-shell-a-rebase-failure-with-no-conflicte"></a>

```text
 round 3 (MEDIUM, shell): a rebase failure with NO conflicted files —
 still `stale-worktree` (the worktree's base is still what's wrong, and
 it is still intact on its pre-rebase commit), but a DISTINCT reason so
 a human resolving it by hand knows this was not a content clash.
```

## FRESHNESS_ERROR or any unrecognized outcome: fail OPEN. Not evidence
<a id="freshness-error-or-any-unrecognized-outcome-fail-open-n"></a>

```text
 FRESHNESS_ERROR or any unrecognized outcome: fail OPEN. Not evidence
 the tree is stale or broken — proceed to the gate on the tree as it
 stands, exactly as every run did before this step existed.
```

## temperloop#1451: plan.sh rule 13 fails a class-A block with no `proof:
<a id="temperloop-1451-plan-sh-rule-13-fails-a-class-a-block-w"></a>

```text
 temperloop#1451: plan.sh rule 13 fails a class-A block with no `proof:` at
 Step 1, so this is only reachable via a hand-edited/mutated plan note. No
 fallback actor exists, so it escalates rather than skipping.
```

## The proof reads Pass on a tree where this item's work never happened, 
<a id="the-proof-reads-pass-on-a-tree-where-this-item-s-work-n"></a>

```text
 The proof reads Pass on a tree where this item's work never happened, so
 running it on the worker's copy would tell us nothing. Same disposition
 as a Fail: loop back to 3c and fix the PREDICATE, never the gate.
```

## ACTIVATION_CONTROL_ERROR / ACTIVATION_TIMEOUT / anything unexpected: t
<a id="activation-control-error-activation-timeout-anything-un"></a>

```text
 ACTIVATION_CONTROL_ERROR / ACTIVATION_TIMEOUT / anything unexpected: the
 control was never ESTABLISHED. Not a Fail (it says nothing about the
 tree) and emphatically not a Pass — proceeding would let a possibly
 vacuous proof wave the item through, which is the whole defect. Halt.
```

## Fail (or an unknown/timeout outcome, which is equally not a Pass) → lo
<a id="fail-or-an-unknown-timeout-outcome-which-is-equally-not"></a>

```text
 Fail (or an unknown/timeout outcome, which is equally not a Pass) → loop
 back to 3c with the activation output as context. Do NOT push a branch
 whose feature is dormant. The worker's fix is the missing WIRING
 (register / flip / render), never a weaker predicate.
```

## The two arm names, in START ORDER. `baseline` is arm A / `--record-a` 
<a id="the-two-arm-names-in-start-order-baseline-is-arm-a-reco"></a>

```text
 The two arm names, in START ORDER. `baseline` is arm A / `--record-a` for the
 pairwise judge and `candidate` is arm B / `--record-b`, fixed here once so the
 ledger's `start_order`, the judge's A/B mapping and the worktree suffixes
 cannot drift apart across the three sites that read them.
```

## The marker the arm-read-isolation guard (temperloop#2077) appends a li
<a id="the-marker-the-arm-read-isolation-guard-temperloop-2077"></a>

```text
 The marker the arm-read-isolation guard (temperloop#2077) appends a line to
 on every DENIED cross-arm read, beside the `.dual-build-arm` marker in the
 arm's own worktree. Its mere presence is the ledger's `cross_read_attempted`.
```

## Not refused — an A/A instrument check (both arms the same model, the
<a id="not-refused-an-a-a-instrument-check-both-arms-the-same-"></a>

```text
 Not refused — an A/A instrument check (both arms the same model, the
 epic's own first-live-run shape) is a legitimate and deliberate use. It
 is LOGGED so a reader never mistakes it for a real comparison.
```

## The item half of both records, identical by construction — judge.sh's 
<a id="the-item-half-of-both-records-identical-by-construction"></a>

```text
 The item half of both records, identical by construction — judge.sh's own
 same-item precondition refuses two records that disagree on
 issue/title/scope/acceptance, so building both from ONE literal here is
 what makes that precondition pass for a legitimate pair.
```

## A non-JSON last line is a NAMED refusal, never interpolated: this prin
<a id="a-non-json-last-line-is-a-named-refusal-never-interpola"></a>

```text
 A non-JSON last line is a NAMED refusal, never interpolated: this printf
 splices "$__jo" raw into a JSON object the driver parses as one line, so
 an unparseable line would turn a legible refusal into malformed
 machinery output the caller reports as a bare parse failure.
```

## The matched paths are interpolated into a JSON string field below, so 
<a id="the-matched-paths-are-interpolated-into-a-json-string-field-"></a>

```text
 The matched paths are interpolated into a JSON string field below, so the
 two characters that would make that object unparseable are deleted first
 (temperloop#2080 round-2 review [LOW], the same filter
 ACTIVATION_DETAIL_FILTER applies for the identical reason). The `-n` test
 is unaffected: a path is never made empty by dropping a quote.
```

## driveArm — build ONE arm of ONE in-scope item through phase 1 only.
<a id="drivearm-build-one-arm-of-one-in-scope-item-through-phase-1-"></a>

```text
 driveArm — build ONE arm of ONE in-scope item through phase 1 only.
 Returns a normalized arm result; it NEVER returns a parked/escalation record
 to the level, because a per-arm failure is not an item failure (the epic's
 sequencing note: "No per-arm failure ever escalates across the driveItem
 boundary — it degrades to a ledger row with a loss_reason instead").
```

## temperloop#2080 round-1 review [MEDIUM]. driveItemBuildPhase returns a
<a id="temperloop-2080-round-1-review-medium-driveitembuildphase-re"></a>

```text
 temperloop#2080 round-1 review [MEDIUM]. driveItemBuildPhase returns a
 TERMINAL record on two paths that mean OPPOSITE things: escalate() (a real
 failure) and — for kind:spike alone — park() (the read-only verdict marker,
 that item's NORMAL completion, and the only park() the build phase returns
 at all). Folding "any terminal record" into the loss path recorded a
 successful spike arm as `gate:'fail' loss_reason:'infra'`, corrupting
 exactly the ledger this feature exists to produce and making judgeArms
 report `one-arm-only` for a pair where BOTH arms finished. A spike creates
 no worktree and runs no gate, so this arm honestly carries no
 base_sha/guard/cost — but it completed, so it is a passing arm.
```

## judgeArms — the pairwise judge call, run AT the barrier (temperloop#20
<a id="judgearms-the-pairwise-judge-call-run-at-the-barrier-temperl"></a>

```text
 -----------------------------------------------------------------------------
 judgeArms — the pairwise judge call, run AT the barrier (temperloop#2073).
 -----------------------------------------------------------------------------
 One `judge.sh pairwise` per in-scope item whose TWO arms both gate-passed:
 record-a is the baseline arm, record-b is the candidate arm, and the script
 sends the same prompt twice in both position orders and reports
 { preference, margin, order_agreement }. The two record files are assembled
 in the executor's own shell from this driver's item metadata plus each arm's
 diff against its recorded base, because that diff exists only on disk.

 A judged item ALWAYS gets a DISPOSITION, never silence: a real verdict, or a
 named reason there is none (one arm never gated, the seam is absent, the
 judge refused or was unavailable). That is what makes "every in-scope item has
 a judge result" checkable at the barrier rather than a hope.
```

## temperloop#2080 round-1 review [MEDIUM], the companion to driveArm's
<a id="temperloop-2080-round-1-review-medium-the-companion-to-drive"></a>

```text
 temperloop#2080 round-1 review [MEDIUM], the companion to driveArm's
 spike-park branch: a spike arm produces a VERDICT NOTE, not a diff, and its
 worktree does not exist — so `judge.sh pairwise`, which compares the two
 arms' diffs against their recorded bases, would compare two empty excerpts
 and return a verdict about nothing. That is a named DISPOSITION (this
 function's own contract: never silence), not a judgement.
```

## THE VERDICT IS READ UN-PIPED (temperloop#2080 round-2 review [HIGH]), 
<a id="the-verdict-is-read-un-piped-temperloop-2080-round-2-review-"></a>

```text
 THE VERDICT IS READ UN-PIPED (temperloop#2080 round-2 review [HIGH]), the
 same shape activationProofCmd uses and for the same reason: `$?` after a
 pipeline is the LAST command's status, so `… | tail -1; __jr=$?` reads
 tail's status — effectively always 0 — and judge.sh's own exit never
 reaches the branch below. That mis-reads BOTH ways: a judge.sh that dies
 AFTER writing a line would have its garbage recorded as a real pairwise
 verdict, and the refusal's `rc` field — whose whole job is to report that
 status — would be structurally 0. So: capture whole, read `$?`, THEN trim
 to the last line in a separate step. Deliberately no PIPESTATUS (zsh
 spells it `$pipestatus` and 1-indexes it) and no `set -o pipefail` (see
 activationProofCmd's comment for why that is worse, not safer).
```

## appendDualBuildRows — the ledger write (temperloop#2072).
<a id="appenddualbuildrows-the-ledger-write-temperloop-2072"></a>

```text
 -----------------------------------------------------------------------------
 appendDualBuildRows — the ledger write (temperloop#2072).
 -----------------------------------------------------------------------------
 One `dual-build-ledger.sh append` per row, batched into ONE executor for the
 item (two rows in scope, one row out of scope). Three of the row's fields
 cannot be known in this runtime and are filled by the executor's own shell
 from the arm's worktree:
   cross_read_attempted — whether the arm-read guard recorded a DENIED
                          cross-arm read beside the `.dual-build-arm` marker;
   head_sha             — the arm branch's tip, which exists only on disk;
   machinery_version    — the checkout's VERSION, the join key K#1924's own
                          per-step resume ledger uses.
 Everything else is composed here, in legible .mjs, and handed over as a JSON
 literal — the same division of labour every other machinery call in this file
 uses (DESIGN NOTE 1: the branching stays here, the shell only executes).
```

## driveInScopeItem — one in-scope item: two arms, the barrier's local ha
<a id="driveinscopeitem-one-in-scope-item-two-arms-the-barrier-s-lo"></a>

```text
 -----------------------------------------------------------------------------
 driveInScopeItem — one in-scope item: two arms, the barrier's local half.
 -----------------------------------------------------------------------------
 Returns the arm results; the judge, the rows and the item's record are the
 caller's post-barrier job, because a judge that ran here would judge one item
 while a sibling item's arms were still building — which is a per-item barrier,
 not the level barrier ADR 0038 requires.
```

## START ORDER. parallel() invokes its thunks in array order, synchronous
<a id="start-order-parallel-invokes-its-thunks-in-array-order-synch"></a>

```text
 START ORDER. parallel() invokes its thunks in array order, synchronously up
 to each one's first await, so the counter below assigns baseline=1 and
 candidate=2 deterministically — a recorded fact about which arm started
 first, not a guess re-derived later from timestamps that this runtime
 cannot read anyway.
```

## driveLevelDualBuild — the level driver, and the BARRIER itself.
<a id="driveleveldualbuild-the-level-driver-and-the-barrier-itself"></a>

```text
 -----------------------------------------------------------------------------
 driveLevelDualBuild — the level driver, and the BARRIER itself.
 -----------------------------------------------------------------------------
 Three phases, in this order, and the order IS the contract:
   1. BUILD. Every item in parallel. An in-scope item fans out two arms and
      stops at the end of phase 1; a not-in-scope item takes the ordinary
      single-arm driveItem, PR and all.
   2. THE BARRIER. The `await` on phase 1 is the barrier — past it, EVERY
      in-scope arm in the level has a gate result. Only now does any judging
      happen, and no PR has opened for any in-scope item.
   3. JUDGE + RECORD. Per item: the pairwise judge, then the ledger rows, then
      the item's own record. Still no PR for an in-scope item — routing the
      winner to PR is `level-pick-and-operator-levers`.
```

## The IN-SCOPE throw (the not-in-scope branch carries its own catch
<a id="the-in-scope-throw-the-not-in-scope-branch-carries-its-own-c"></a>

```text
 The IN-SCOPE throw (the not-in-scope branch carries its own catch
 above, so this is what it adds). `escaped` marks a run that produced
 NO arms: phase 3 hands its record straight to the level's disposition
 rather than judging arms that do not exist or inventing a
 not-in-scope ledger row for an item that IS in scope. No
 preserveOnEscalation here on purpose — an in-scope item's commits
 live in `<slug>@baseline` / `<slug>@candidate`, not the `<slug>`
 worktree that helper pushes from, so calling it would push the wrong
 (or an absent) tree.
```

## One row for the item that was built ONCE, so the level's ledger
<a id="one-row-for-the-item-that-was-built-once-so-the-level-s-ledg"></a>

```text
 One row for the item that was built ONCE, so the level's ledger
 accounts for every item rather than only the compared ones. `arm` is
 a closed two-value field in the ledger schema, so an uncompared build
 is recorded on the BASELINE arm with an explicit `in_scope:false` —
 never a third arm value the reader's schema does not know.
```

## Continuation detection (escalation-resume loop, 3d-esc)
<a id="continuation-detection-escalation-resume-loop-3d-esc"></a>

```text
 --- Continuation detection (escalation-resume loop, 3d-esc) --------------
 On a 3d-esc continuation the orchestrator re-invokes this workflow with
 input.onlySlugs = [<this slug>, ...] and input.verdicts[<slug>] carrying the
 human's captured decision. A continued item's worktree + .build-guard
 marker are ALREADY in place (the escalation left them intact) and its
 board issue is ALREADY claimed — so we MUST NOT re-run 3a (claim) or 3b
 (worktree.sh create force-recreates the path, discarding the escalated
 build, MINOR fix). We resume at 3c, injecting the captured verdict so the
 re-spawned worker sees the human's decision instead of re-forking forever
 (MAJOR fix). verdicts map shape: { [slug]: { kind, verdict_section } }.
```

## PRELUDE (3a claim + 3b-0 deps-merged + 3b worktree create)
<a id="prelude-3a-claim-3b-0-deps-merged-3b-worktree-create"></a>

```text
 --- PRELUDE (3a claim + 3b-0 deps-merged + 3b worktree create) ------------
 ONE batched executor agent for the whole per-item mechanical prelude
 (temperloop#942) instead of one agent spawn per command. Ordering, skip
 conditions and every branch below are unchanged — only the transport is.
 The batch's own bash short-circuit refuses to run a later step once an
 earlier one's outcome means it must not (a failed claim never reaches
 worktree create; an unmerged dep never creates a worktree), so the results
 array is simply shorter and the .mjs escalates on the step that stopped it.
```

## 3b-0 / 3b are prelude steps only for a NON-spike item: a spike is read
<a id="3b-0-3b-are-prelude-steps-only-for-a-non-spike-item-a-spike-"></a>

```text
 3b-0 / 3b are prelude steps only for a NON-spike item: a spike is read-only
 and skips 3b–3h entirely, so it must never create a worktree. Its prelude is
 the claim alone (or nothing at all when the board is OFF).

 3b-0. Dep-merge precondition gate (#108).
 A `depends-on` edge REQUIRES its target be [x] MERGED before this item's
 worker starts — the worker must build and self-verify against the merged
 dependency code, NOT a pre-merge base. The orchestrator's level ordering
 (it runs level k's merge gate before invoking build-level for level k+1) is
 the primary guarantee; this is the mechanical backstop that refuses to
 create the worktree until every depended-on PR has actually landed in
 origin/<default> (guarding a resume race, a partial merge, an ordering bug).
 Without it, worktree.sh create bases the branch on an origin/<default> that
 LACKS the dep, the worker self-verifies against stale code, and the 3f
 unconditional rebase (#525) only repairs the branch TEXTUALLY at push —
 too late for the worker's own build/verify. item.dependsOn is [{slug,sha}]
 (each dep's merged head SHA, from the plan note's pushed_sha:); an
 absent/empty list (level-0 or after:-only deps) is a no-op. Skipped on a
 continuation — the worktree already exists and its base was gated at first
 create; re-gating would need SHAs the continuation input does not carry.
```

## Every loop in this file that can RE-ATTEMPT something, with its hard c
<a id="every-loop-in-this-file-that-can-re-attempt-something-with-i"></a>

```text
 Every loop in this file that can RE-ATTEMPT something, with its hard cap and
 its transient-vs-deterministic disposition. Repeating a deterministically-
 failing operation cannot change its outcome, so a loop either classifies
 before retrying or states why classification does not apply. The audit is
 kept HERE, beside the budgets, so a new loop cannot be added without a
 reviewer seeing the shape it has to satisfy.

   1. ciPollLoop slice loop — CAP: maxSlices = ceil(CI_POLL_TOTAL_SECS /
      CI_POLL_SLICE_SECS). NOT A RETRY: each slice waits on external state
      (pending check-runs) that genuinely changes between polls, and every
      terminal verdict (CI_GREEN / CI_FAILED / NO_CI) exits the loop on the
      spot. The deterministic cases it MUST not spin on are already short-
      circuited by name, not by budget: CONFLICTING/DIRTY escalates
      merge-conflict immediately (#543), a NO_CI SHA resolves through
      ci-poll.sh's bounded grace window (temperloop#605), and any ERROR
      escalates rather than re-polls. No classification step applies.
   2. CI_FAILED worker re-spawn — CAP: CI_FAIL_RETRY_BUDGET (below), past
      which the item escalates `ci-failed` for a human. NOT A RETRY EITHER, in
      the sense that matters here: the re-attempt does not re-issue the failed
      operation, it spawns a worker to FIX the failure and pushes a NEW SHA, so
      the input to the next CI run differs by construction. That is what makes
      a classify-before-retry step inapplicable — and the budget is already at
      its floor of one, so a deterministic repeat cannot cost a second one.
   3. null-verdict main-worker re-spawn (driveItem, ~1145) — CAP: exactly one,
      and CLASSIFIED BEFORE IT FIRES on both axes: the recover-probe runs FIRST
      and adopts any work that already landed (so a lost return is never re-
      built), and the retry prompt is deliberately DIFFERENT from the first
      (FOREGROUND_CURE appended) because a byte-identical retry re-stalls
      identically. The read-only spike worker's null escalates with NO retry.
   4. pr.sh `EXISTS` adoption (3f) — not a loop: a create-retry whose first
      attempt in fact succeeded is ADOPTED as PR_OPENED rather than re-issued.
   5. STEP_TIMEOUT disposal (temperloop#1071) — NOT A RETRY AT ALL, and named
      here so a future edit cannot quietly make it one. A machinery step killed
      by the workflow liveness ceiling is CLASSIFIED FIRST (pr.sh recover-probe,
      the same ladder rule 3 uses) and then either ADOPTED (rule 4's shape: an
      already-opened PR is taken, never re-opened) or ESCALATED. There is no arm
      that re-issues the bounded step — push and pr-create are not idempotent,
      and the ceiling firing is precisely the case where you cannot know whether
      the first attempt landed.

 The two loops this file DELEGATES to carry their own caps + classification
 and are documented in their own scripts, not restated here: ci-poll.sh's
 gh_retry (CI_POLL_API_MAX_ATTEMPTS / _RETRY_BACKOFF / _DETERMINISTIC_PATTERN)
 and quality-gates.sh's per-gate retry via workflows/scripts/lib/gate-retry.sh
 (GATE_MAX_ATTEMPTS / GATE_RETRY_BACKOFF / GATE_DETERMINISTIC_PATTERN). The
 3e.5 acceptance gate itself does NOT retry: a GATE_FAIL escalates
 `acceptance-gate-failed` on the first failure.
```

## THE WASTE THIS CLOSES. A `review-blocking` escalation loops the item b
<a id="the-waste-this-closes-a-review-blocking-escalation-loops-the"></a>

```text
 THE WASTE THIS CLOSES. A `review-blocking` escalation loops the item back
 through 3c → 3e. Sometimes the branch ALREADY carries the fix by the time the
 continuation runs, so the re-spawned worker reads the finding, reads the code,
 finds nothing to do, and returns "no source change" — a full implementation
 agent spent to learn that. Four PRs in the 2026-09-18 dual-build epic
 (#2096, #2100, #2101, #2102) had `-r2`/`-r3` branches that changed nothing at
 all. temperloop#1934 closed the WORKER side of this for the join-key-registry
 case (the worker recognising it has nothing to do); this is the ORCHESTRATOR
 side — not spawning it in the first place.

 WHAT IT CONSUMES, AND WHY THERE IS EXACTLY ONE SOURCE. The prior reviewed SHA
 is the marker `reviewDiffCmd` writes beside `build-review-rounds` in the
 worktree's own git dir (temperloop#2127, merged in level 0 — see that
 function's comment for the durability contract and the two resolution checks).
 This probe re-reads THAT marker with THAT file's own validation, never a
 second SHA source: a parallel notion of "the commit the last round reviewed"
 would drift against the one the continuation reviewer is already being handed.

 FAIL CLOSED — THE ONLY DIRECTION THAT MATTERS. This predicate decides whether
 to skip real work. A FALSE POSITIVE (claiming the fix is present when it is
 not) silently drops the fix round and lets a branch that still carries a HIGH
 reach the merge gate LOOKING reviewed, which is strictly worse than the waste
 it is trying to avoid. A false NEGATIVE costs one worker spawn — exactly
 today's behaviour. So every step below that cannot POSITIVELY establish "this
 finding's line is gone from the tip" returns not-fixed:
   - the escalation is not `review-blocking`, or carries no findings text
   - no `**Where:** <path>:<line>` location parses out of the findings
   - a `**Where:**` line is present but does NOT yield a usable path:line
     (a function name, a prose locator like `build.md - Step 3`): one
     unlocatable finding means the SET cannot be established
   - fewer located findings than `### [HIGH` headings
   - the machinery call is denied, times out, or returns anything other than
     the single `ALREADY_FIXED` outcome
 and the emitted shell applies the same rule to everything it alone can see
 (no usable prior SHA, tip identical to the reviewed commit, a file unreadable
 at either revision, a fingerprint too weak to be evidence).
```

## Drive every active item through 3a–3h. The items in one level are
<a id="drive-every-active-item-through-3a-3h-the-items-in-one-level"></a>

```text
 Drive every active item through 3a–3h. The items in one level are
 independent by construction (no merge edge between them), so we fan them
 out with parallel() — the substrate caps concurrency (~cores-2). This
 matches build.md's "express each item's pipeline as a parallel() over
 the level's items" (within-level execution). parallel() returns the array
 of per-item results in item order; a blocked/failed item escalates rather
 than halting its siblings (the orchestrator batches escalations at the
 boundary). On a continuation run only the named slugs enter parallel(); the
 rest are already parked and are left untouched.
 A thrown exception in driveItem must NOT vanish: parallel() drops a rejected
 thunk to null, which would leave the item in NEITHER parked NOR escalations —
 silently lost, violating the no-silent-stall invariant. Convert any throw into
 a generic `worker-error` escalation so it always surfaces. (#437: a real run
 hit item.acceptance.map on a string and the item was silently dropped.)
 temperloop#2020: `.then(preserveOnEscalation)` is applied to the SETTLED
 result — after the #437/#1819 catch above, so a THROWN item's synthesized
 escalation gets the same work-preservation push a returned one does. This
 is the single choke point for "an escalation is about to leave this
 driver"; see preserveOnEscalation's own comment for why it lives here and
 not at the ~30 individual escalate() call sites.

 temperloop#2080 — the DUAL-BUILD fan-out is an alternative to this one, not
 a flag inside it. A `dualBuild` input restructures the level into build →
 barrier → judge → record (driveLevelDualBuild), which is a different
 control flow, not a different parameter; keeping the two apart is what
 makes "no dualBuild input → this exact fan-out, unchanged" true by reading
 the code rather than by tracing a branch through it.
```
