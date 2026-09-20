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

> **Part 5 of 7.** Split to stay under the per-file prose cap
> (`PROSE_BUDGET_TIER2_FILE_CAP`). Other parts: [`build-level.design-notes.md`](build-level.design-notes.md), [`build-level.design-notes-2.md`](build-level.design-notes-2.md), [`build-level.design-notes-3.md`](build-level.design-notes-3.md), [`build-level.design-notes-4.md`](build-level.design-notes-4.md), [`build-level.design-notes-6.md`](build-level.design-notes-6.md), [`build-level.design-notes-7.md`](build-level.design-notes-7.md).

## 3b. Pre-create the deterministic worktree (worktree.sh create).
<a id="3b-pre-create-the-deterministic-worktree-worktree-sh-create"></a>

```text
 3b. Pre-create the deterministic worktree (worktree.sh create).
 On a continuation we REUSE the existing worktree (MINOR fix): the escalated
 item's worktree + its committed build + the .build-guard marker are all
 intact, and worktree.sh create force-removes-and-re-adds (worktree.sh:113),
 which would DISCARD the escalated build. So skip create entirely and resume
 against the deterministic path. The injected verdict (3c) makes resuming on
 the existing worktree correct — the worker builds on its own prior work
 plus the human's decision, exactly the escalation-resume contract.

 temperloop#2080 adds TWO things to this one step, both of which leave a
 flag-less, residue-free run's OUTPUT byte-identical:

  (a) THE ARM FLAG. A dual-build arm creates `<repoRoot>.wt/<slug>@<arm>` on
      `build/<slug>@<arm>` via `create --arm <name>[:<sibling>]`
      (temperloop#2076). `item.slug` is already the ARM KEY here, so the
      command is built from `arm.slug` — the real plan slug — and the
      deterministic path worktree.sh returns equals `worktreePath` above by
      construction, exactly as it does on the arm-less path.

  (b) THE FLAG-LESS-RESUME REFUSAL (ADR 0038's "Consequences"). A `/build`
      re-run over a level a dual build left half-finished must refuse
      LEGIBLY — never silently complete it single-arm, and never pick a side
      by accident. The signal is the arm worktrees themselves:
      `<repoRoot>.wt/<slug>@*` exists only while an arm of THIS slug is
      mid-flight (the pick deletes the losing arm's tree and `worktree.sh
      prune` reaps the rest), so it is precisely "partially dual-built" and
      nothing else. The ledger is deliberately NOT consulted: its rows
      outlive the run by `DUAL_BUILD_ARCHIVE_RETENTION_DAYS`, so a slug
      dual-built last week would refuse every ordinary build since.

      The check is emitted INSIDE this step's own command rather than as a
      new probe step, and that is the load-bearing choice: a level-wide
      probe agent would add a spawn to every flag-less run, changing the
      very transcript this item's acceptance pins as unchanged. Here the
      clean path runs `worktree.sh create` and prints its CREATED line with
      nothing added — same step count, same agent count, same JSON.
```

## A depended-on PR has NOT merged to origin/<default>. Do NOT create the
<a id="a-depended-on-pr-has-not-merged-to-origin-default-do-not-cre"></a>

```text
 A depended-on PR has NOT merged to origin/<default>. Do NOT create the
 worktree and do NOT spawn a worker — surface it so the orchestrator/human
 resolves the ordering. Nothing is built against a stale base. (The batch's
 own short-circuit already refused to run the worktree-create step, so
 nothing was built against the pre-merge base either.)
```

## temperloop#2080 — the two fields a dual-build ledger row reads off the
<a id="temperloop-2080-the-two-fields-a-dual-build-ledger-row-reads"></a>

```text
 temperloop#2080 — the two fields a dual-build ledger row reads off the
 CREATED line: the base the arm branched from, and worktree.sh's OWN
 write-jail arming verdict (ARMED/UNARMED/UNKNOWN, its § Write-jail arming
 self-test). Captured here because this is the only place they exist;
 defaulted so a continuation (which skips create) still produces a
 well-formed row rather than one the ledger validator rejects.
```

## The flag-less-resume refusal (see the guard's own comment at 3b). This
<a id="the-flag-less-resume-refusal-see-the-guard-s-own-comment-at-"></a>

```text
 The flag-less-resume refusal (see the guard's own comment at 3b). This
 is NOT a worktree failure: nothing was attempted, nothing was
 destroyed, and the arm worktrees still hold their builds. It refuses
 under its own kind so the disposition is "re-run with --dual-build, or
 finish the pick", never "retry the create".
```

## temperloop#2006 — READ the sideline verdict the CREATED line already
<a id="temperloop-2006-read-the-sideline-verdict-the-created-line-a"></a>

```text
 temperloop#2006 — READ the sideline verdict the CREATED line already
 carries. `create` never refuses, so an occupied path yields CREATED
 either way; the only thing that distinguishes "created over nothing"
 from "shelved a resumable build and created over the freed path" is
 this field, and dropping it is what made the shelf invisible.
```

## 3c. Spawn the worker (NO isolation:'worktree' — DESIGN NOTE 3)
<a id="3c-spawn-the-worker-no-isolation-worktree-design-note-3"></a>

```text
 --- 3c. Spawn the worker (NO isolation:'worktree' — DESIGN NOTE 3) ------
 On a continuation, inject the captured human verdict (## Design verdict /
 ## User answers) as the worker's extra section so it sees the decision
 instead of re-forking forever (MAJOR fix). On a fresh drive verdictSection
 is undefined → workerPrompt emits no extra section, unchanged behavior.
```

## temperloop#2065 — the main worker's cost, accumulated across BOTH this
<a id="temperloop-2065-the-main-worker-s-cost-accumulated-across-bo"></a>

```text
 temperloop#2065 — the main worker's cost, accumulated across BOTH this
 call and the #993/#1219 foreground-cure retry below (see
 mergeWorkerCost()). Distinct from the CI-fix retry's own retryTokens/
 retryCount (ciPollLoop) — this accumulator is "worker tokens", the
 ledger's OTHER figure.
```

## No verdict — either agent() returned null (user skip, transient 5xx, o
<a id="no-verdict-either-agent-returned-null-user-skip-transient-5x"></a>

```text
 No verdict — either agent() returned null (user skip, transient 5xx, or the
 #1219 background-stall) or it THREW (StructuredOutput absent / retry cap
 blown). Neither tells us anything about the WORK, so before doing anything
 else, LOOK (temperloop#939): probe the observable side-effects. This runs
 BEFORE the retry deliberately — re-spawning a worker onto a worktree that
 already holds the finished commit is the duplicate-PR / stacked-commit
 hazard #939 names, and it costs a full worker run to discover.
```

## Nothing COMMITTED → this is the ordinary stall. Retry exactly once,
<a id="nothing-committed-this-is-the-ordinary-stall-retry-exactly-o"></a>

```text
 Nothing COMMITTED → this is the ordinary stall. Retry exactly once,
 appending FOREGROUND_CURE so the retry prompt DIFFERS from the first — a
 byte-identical retry re-stalls identically. A 5xx is transient (the extra
 section is harmless); a stall is cured by it.

 temperloop#993 — MECHANICAL detection of the incomplete-return shape:
 no verdict AND the worktree dirty with zero commits is the backgrounded-
 gate stall specifically (not a worker that never started). The probe
 reports it as RECOVER_DIRTY, and the auto-resume carries the dirty-resume
 note on top of the cure so the re-spawn CONTINUES on the work already in
 the worktree instead of rebuilding it. Detection is mechanical here so the
 prose clause in the worker prompt (prevention) is not the only guard —
 build.md §3c/§3d stay in lockstep with this block.
```

## GENUINELY nothing committed — the unchanged escalation path. When the
<a id="genuinely-nothing-committed-the-unchanged-escalation-path-wh"></a>

```text
 GENUINELY nothing committed — the unchanged escalation path. When the
 probe still sees a dirty worktree (temperloop#993), say so in the
 payload: the auto-resume did not cure it, and whoever disposes this
 escalation must know there is UNCOMMITTED WORK in the worktree before
 choosing "skip" (which prunes the worktree and destroys it).
```

## 3d. Branch on the verdict
<a id="3d-branch-on-the-verdict"></a>

```text
 --- 3d. Branch on the verdict -------------------------------------------
 Only `done` with all acceptance bullets passing continues. blocked /
 design-fork / failed escalate (the orchestrator drives the human round-trip
 and re-drives the item; we leave the worktree intact). A `done` with any
 passed:false is treated as blocked.
```

## 3e. Mandatory/routed pre-push review (temperloop#1430)
<a id="3e-mandatory-routed-pre-push-review-temperloop-1430"></a>

```text
 --- 3e. Mandatory/routed pre-push review (temperloop#1430) --------------
 Runs HERE — between 3d and 3e.5, inside this driver — spawning the routed
 reviewer(s) itself via `agent({agentType})`. See build.md §3e's own "why
 this runs inside the workflow, not the orchestrator" paragraph: by the
 time this driver RETURNS to the orchestrator, the item is already pushed
 with its PR open (irreversible), and the orchestrator's post-return
 partition removes the parked item's worktree — the tree a review would
 need to inspect. A loop-back to 3c is only reachable from INSIDE
 driveItem, never after. (This driver does NOT merge: build.md §3h.5's
 as-you-go merge is conversational-path-only — temperloop#1452.)

 temperloop#2127 — on a `review-blocking` continuation specifically (the
 ONLY escalation kind §3e's own convergence-bound loop below produces),
 `verdictSection` (computed above for 3c's worker re-spawn) IS the prior
 round's findings text: the orchestrator captured it off THIS SAME
 escalation's `findings: review.blocking` payload. Gated on
 `kind === 'review-blocking'` so a continuation resuming from a DIFFERENT
 escalation kind (design-fork/blocked/failed) — whose verdict block is
 about an unrelated human decision, not review findings — never leaks into
 the reviewer's prompt as if it were prior review output.
```

## Carried into the PR body at 3f below (verdictJson.summary) — the PR mu
<a id="carried-into-the-pr-body-at-3f-below-verdictjson-summary-the"></a>

```text
 Carried into the PR body at 3f below (verdictJson.summary) — the PR must
 carry REAL evidence a review ran (or a legible, non-guaranteed skip
 notice), never silently read as if the gate had passed by default.
 `notes` (temperloop#1450) is the reviewer's FULL findings text, rendered
 as its own `## Review notes` section so a non-blocking (MEDIUM/LOW-only)
 pass is still visible to the human reviewer — not computed, checked for
 HIGH, and thrown away. Rendered via reviewBodySuffix (temperloop#1846) —
 the SAME renderer 3g.5's post-CI-fix re-render uses, so the two surfaces
 can never drift; with the single round it renders the pre-#1846 shape
 byte-identically.
```

## Resolve the gate script from the WORKTREE, not repoRoot (temperloop#62
<a id="resolve-the-gate-script-from-the-worktree-not-reporoot-tempe"></a>

```text
 Resolve the gate script from the WORKTREE, not repoRoot (temperloop#626).
 The point of 3e.5 is to validate the worker's CHANGES, and the `cd ${wt}`
 below intends exactly that — but quality-gates.sh's first act is
 `cd "$REPO_ROOT"` where REPO_ROOT is derived from the SCRIPT's own path
 (BASH_SOURCE/..). If we ran repoRoot's copy, that cd would jump straight
 back to the main checkout and the gate would validate main's tree, not the
 worktree — silently defeating the cd. Running the worktree's own copy makes
 REPO_ROOT resolve to the worktree, so every gate (make targets, the
 diff-scoped leak guard that diffs the branch's additions, the freshness
 check) runs against the worker's tree — matching what CI sees on the PR's
 merge. The worktree is a full checkout of the branch, so this copy always
 exists whenever repoRoot's would (GATE_ABSENT still fires for a repo with
 no vendored gate). Only build-SPINE scripts (worktree.sh / pr.sh / …) route
 through machineryBin's foundation fallback; the repo-local gate resolves
 directly against the worktree.

 Resolved BEFORE the freshness step below (round 3, HIGH, temperloop#1937)
 so runGateFreshness() can gate itself behind the identical presence check
 gateCmd's own GATE_ABSENT arm makes — a project with no vendored gate
 script has nothing for the freshness step to protect.
```

## 3e.5-pre. Gate-freshness rebase (temperloop#1937)
<a id="3e-5-pre-gate-freshness-rebase-temperloop-1937"></a>

```text
 --- 3e.5-pre. Gate-freshness rebase (temperloop#1937) --------------------
 Bring the worktree up to current origin/main BEFORE the acceptance gate
 below runs — see runGateFreshness()'s own header for the full rationale
 (origin/main-ratcheted validators false-failing on a worktree that went
 stale mid-build; the live temperloop#1934 incident this item fixes).
 Strictly between §3e review and §3e.5: a conflicting rebase must escalate
 BEFORE quality-gates.sh ever runs, never after a wasted gate slice.
```

## gateCmd(startAt) — one SLICE of the suite (temperloop#1021).
<a id="gatecmd-startat-one-slice-of-the-suite-temperloop-1021"></a>

```text
 gateCmd(startAt) — one SLICE of the suite (temperloop#1021).

 The budget is handed to quality-gates.sh as ENV VARS, deliberately not
 flags: a consuming repo vendoring an OLDER quality-gates.sh ignores an
 unknown env var and runs the whole suite in one go (today's exact behavior,
 and still correct), whereas an unknown FLAG would exit 2 "usage" and read
 back here as a gate failure. So this is compatible with every vendored copy
 in the fleet with no probing.

 Exit-code protocol: 0 = finished green, 75 = budget spent with gates
 remaining (the script printed QUALITY_GATES_RESUME_AT= / QUALITY_GATES_FAILED=),
 anything else = red. Note the 75 arm is only ever taken by a slice-aware
 script, so an older copy can only ever produce GATE_PASS / GATE_FAIL.

 `set -o pipefail` is LOAD-BEARING (temperloop#68 — see build.md §3e.5).
 The gate verdict is derived from the subshell's own exit status, and since
 temperloop#2094 that subshell IS piped — through `tee`, so one slice's
 output can be isolated for trailer parsing while still STREAMING into the
 cumulative operator log (see gateSliceLog below for why both are required).
 A bare pipe's status reflects the LAST stage (tee's 0), which would swallow
 a RED gate and degrade 3e.5 to a silent no-op; with pipefail set, the gate's
 own non-zero exit propagates to `$?` and GATE_FAIL is still emitted. This is
 the exact case build.md §3e.5 permits ("if the gate must be piped, `set -o
 pipefail` first"), and the exit is read as a bare `$?` — NOT through
 PIPESTATUS[0], a bash array that expands empty under the zsh this harness's
 Bash tool actually runs, which is temperloop#801's misread.

 The log is truncated on the first slice and APPENDED to thereafter, so
 /tmp/qg-<slug>.log stays the single artifact an operator reads, carrying the
 union of every slice exactly as an unsliced run's log did.
```

## ONE SLICE'S OWN OUTPUT, kept separate from the cumulative log above
<a id="one-slice-s-own-output-kept-separate-from-the-cumulative-log"></a>

```text
 ONE SLICE'S OWN OUTPUT, kept separate from the cumulative log above
 (temperloop#2094). The trailers below (`QUALITY_GATES_FAILED=`,
 `QUALITY_GATES_RESUME_AT=`, `QUALITY_GATES_SELECTION=`) are read with
 `tail -1`, so reading them out of the APPENDED log silently answers a
 question about THIS slice with the previous slice's numbers whenever this
 slice printed none of its own — a slice killed before it could report, or
 one whose `cd`/`unset` prelude failed, inherits a resume point and a
 failure count it never established. The trailers are therefore parsed from
 HERE, never from the cumulative log: a trailer present in this file was
 printed by the slice just run, which is what makes the classifier below
 able to trust it.

 IT IS A TEE, NOT A REDIRECT-THEN-COPY (review round 1). Writing the slice
 to this file and `cat`-ing it into ${gateLog} afterwards bought the
 isolation above at the cost of the guarantee that matters most on the one
 path that has no other diagnostic: the executor KILLS this whole command at
 GATE_BASH_TIMEOUT_MS, and a copy step scheduled after the gate never runs.
 The killed slice's partial output — the only evidence a timeout produces —
 would never reach /tmp/qg-<slug>.log, the single artifact the escalation
 payload hands the operator; and with the first-slice truncation moved into
 that same copy, a timed-out first slice would leave the PREVIOUS run's log
 in place and the escalation would point at stale content presented as
 current. So ${gateLog} is truncated UP FRONT on slice 0 and the gate streams
 into both files through `tee` — per-slice isolation and live, kill-proof
 streaming at once. `set -o pipefail` is at the head of the command, so the
 pipeline's `$?` is still the gate's own status (`tee` exits 0); the bare
 `$?` read is deliberate and dialect-safe — PIPESTATUS[0] is a bash
 array that expands EMPTY under the zsh this harness's Bash tool runs
 (temperloop#801), which is the misread that swallows a red gate.
```

## SLICE-STABLE SELECTION (temperloop#1663). `QUALITY_GATES_START_AT` is 
<a id="slice-stable-selection-temperloop-1663-quality-gates-start-a"></a>

```text
 SLICE-STABLE SELECTION (temperloop#1663). `QUALITY_GATES_START_AT` is an
 ORDINAL into the gate list, and now that the list can be a SCOPED subset
 re-derived from a live working-tree probe, two slices of one suite could
 resolve DIFFERENT lists — leaving the ordinal pointing at a different gate,
 silently skipping one, and still exiting 0. Before scoping, §3e.5 always
 resolved the static full array, so the ordinal was stable by construction.

 The pin file is the prevention half: slice 0 writes the resolved changed set
 there and every later slice reads it instead of re-probing, so the selection's
 INPUT cannot move mid-suite. It is removed on slice 0 for the same reason the
 log is truncated there — a re-drive must not inherit a previous attempt's
 state.

 The fingerprint is the detection half behind it: each slice reports the
 identity of the list its resume index was measured in, and the next slice is
 handed it back. On a mismatch the gate restarts from 0 on the FULL set and
 says so, rather than resuming an index that no longer means anything.
```

## THE RESUME POINT IS LOAD-BEARING, SO ITS SHAPE IS CHECKED (review roun
<a id="the-resume-point-is-load-bearing-so-its-shape-is-checked-rev"></a>

```text
 THE RESUME POINT IS LOAD-BEARING, SO ITS SHAPE IS CHECKED (review round 1).
 Dropping the old `[ "$__rc" = 75 ]` co-condition removed the only
 cross-check on a value that is matched against the whole slice log, gate
 output included, and then interpolated RAW into JSON by `%s` below. A
 non-numeric or half-written trailer would emit a syntactically invalid
 line, which lands in the executor's "outside the closed set" path instead
 of being classified. Anchoring to digits here is the whole defense: a
 reading that is not a plain integer is treated as ABSENT, exactly as a
 missing trailer already is. (`0` is not a resume point either — the
 trailer is only ever printed with gates REMAINING — and gateSliceResumeAt()
 already drops it downstream.)
```

## AN UNKNOWN ELAPSED IS `null`, NEVER `0` (temperloop#1698). `__el` is a
<a id="an-unknown-elapsed-is-null-never-0-temperloop-1698-el-is-a"></a>

```text
 AN UNKNOWN ELAPSED IS `null`, NEVER `0` (temperloop#1698). `__el` is a
 best-effort sed over the slice log: a vendored gate whose summary line
 this pattern does not match, or a slice killed before printing one,
 leaves it EMPTY. The old `${__el:-0}` turned that straight into a
 confident `"elapsedSecs":0` — a plausible-looking number in place of an
 admission that the figure is unknown, on the one instrument built to make
 suite growth visible. Emitting JSON `null` instead makes the consumer's
 strict read (numOrNull) return null and render `?`.
```

## temperloop#865 — CLASSIFY THE WORKER'S OWN GATE SENTINEL, parent-side.
<a id="temperloop-865-classify-the-worker-s-own-gate-sentinel-paren"></a>

```text
 temperloop#865 — CLASSIFY THE WORKER'S OWN GATE SENTINEL, parent-side.
 The worker is handed a gate invocation that always writes a result
 sentinel (workerGateCmd below); this reads that artifact from the very
 worktree the acceptance gate is about and reports one of four words. It
 is how a worker that BACKGROUNDED its gate and abandoned it becomes
 distinguishable, in the driver's own log and in the gate payload, from a
 worker whose gate was merely slow — the #865 acceptance criterion that a
 re-worded warning cannot meet. Read-only, fail-open: a repo whose workers
 predate the sentinel reports 'absent' and nothing changes.
```

## A RESUME POINT THIS SLICE PRINTED IS THE VERDICT (temperloop#2094).
<a id="a-resume-point-this-slice-printed-is-the-verdict-temperloop-"></a>

```text
 A RESUME POINT THIS SLICE PRINTED IS THE VERDICT (temperloop#2094).
 quality-gates.sh emits `QUALITY_GATES_RESUME_AT=` on exactly one path:
 it spent its budget, stopped CLEANLY BETWEEN GATES, and is telling the
 caller where the remaining gates start. That is a PARTIAL slice by
 construction, and its own `QUALITY_GATES_FAILED=` line is the count it
 established. Keying the branch on the exit code INSTEAD made that fact
 conditional on a number the script prints the trailer before producing:
 one unexpected code — a SIGTERM after the trailer, a wrapper that
 remapped the status — and a clean partial was relabelled GATE_FAIL,
 where gateSliceFailed()'s "RED by construction" floor manufactured the
 one failure the slice had just reported as zero. Observed live: three
 slices, `QUALITY_GATES_FAILED=0` in every one, stopped at gate 152 of
 200, reported `verdict: RED, failedGates: 1, suiteFinished: true`.
 So the resume point is checked FIRST and on its own; `$__rc` rides along
 as `rc` for the record (75 is the protocol code, anything else is an
 anomaly worth seeing in the ledger, neither changes the classification).
 Safe against a stale trailer because ${gateSliceLog} holds THIS slice's
 output alone — see its declaration above.
```

## gateSliceLedger — the AUTHORITATIVE record of what this gate run found
<a id="gatesliceledger-the-authoritative-record-of-what-this-gate-r"></a>

```text
 gateSliceLedger — the AUTHORITATIVE record of what this gate run found
 (temperloop#1587): one entry per slice that actually ran, carrying that
 slice's own outcome and normalized failure count (gateSliceFailed()).
 Every failure figure reported below — the payload's `failedGates`, the
 verdict, the escalation kind — is DERIVED from this array by
 gateVerdict(); no independent running counter is maintained alongside it,
 because two counters that can disagree is exactly the defect #1587 filed.
```

## gateSliceCeiling — the EFFECTIVE loop bound, starting at GATE_MAX_SLIC
<a id="gatesliceceiling-the-effective-loop-bound-starting-at-gate-m"></a>

```text
 gateSliceCeiling — the EFFECTIVE loop bound, starting at GATE_MAX_SLICES
 and grantable up to GATE_RESUME_EXTENSIONS extra allotments of that SAME
 ceiling (temperloop#2135) — see GATE_RESUME_EXTENSIONS above for why. The
 loop's shape is unchanged; only its upper bound can grow, and only while
 zero failures have been observed (checked at the extension site below).
```

## temperloop#1071 — the gate slice outlived the workflow liveness ceilin
<a id="temperloop-1071-the-gate-slice-outlived-the-workflow-livenes"></a>

```text
 temperloop#1071 — the gate slice outlived the workflow liveness ceiling.
 Distinct from GATE_TIMEOUT (the Bash tool's own timeout, which #1021 gave
 its own outcome): this is the backstop BEHIND that one, for the case where
 the tool timeout does not fire at all. Disposed through the same probe as
 every other bounded step, and NOT re-sliced — re-running a gate slice whose
 process may still be alive is exactly the blind retry the rule forbids.
```

## temperloop#1698 — STRICT read of the canonical key. `Number(x) || 0` w
<a id="temperloop-1698-strict-read-of-the-canonical-key-number-x-0-"></a>

```text
 temperloop#1698 — STRICT read of the canonical key. `Number(x) || 0` was
 the defect: against a slice that reported the sibling snake_case spelling
 (or none at all) it produced `0`, and a gate whose own log said "passed in
 215s" was logged as "0s of gate wall time". canonicalizeOutcome() has
 already folded `elapsed_secs` into `elapsedSecs` at the transport
 boundary, so an unreadable figure here is genuinely unknown — and is
 carried as `null` through the ledger and payload, never as a zero.
```

## The RESUME POINT this slice reported, carried into the ledger
<a id="the-resume-point-this-slice-reported-carried-into-the-ledger"></a>

```text
 The RESUME POINT this slice reported, carried into the ledger
 (temperloop#2094) so gateVerdict() can read "the suite stopped with
 gates left" off the ledger itself rather than inferring it from the
 terminal outcome alone. Absent (undefined) when the slice reported
 none — which is what "the suite ran to the end" looks like.
```

## temperloop#2135 — RESUME instead of escalating. A slice that is about 
<a id="temperloop-2135-resume-instead-of-escalating-a-slice-that-is"></a>

```text
 temperloop#2135 — RESUME instead of escalating. A slice that is about to
 exhaust the CURRENT ceiling, with ZERO failures recorded anywhere in the
 ledger so far, gets one more allotment of GATE_MAX_SLICES rather than a
 manufactured acceptance-gate-timeout escalation — see
 GATE_RESUME_EXTENSIONS above for the sizing rationale. A failure
 anywhere in the ledger disarms this: that run is already headed for
 acceptance-gate-failed regardless of how many more slices it gets, so
 extending would only spend more wall time on a branch that is already
 known-RED — this is exactly what keeps bullet 2 (the failed-gate arm)
 UNCHANGED: it still escalates at the ORIGINAL GATE_MAX_SLICES ceiling.
```

## `verdict` is the field to trust: RED / UNKNOWN / GREEN. `outcome` is t
<a id="verdict-is-the-field-to-trust-red-unknown-green-outcome-is-t"></a>

```text
 `verdict` is the field to trust: RED / UNKNOWN / GREEN. `outcome` is the
 TERMINAL slice's own outcome — a per-slice fact, never the suite's
 verdict (a GATE_PASS terminal on a run whose slice 1 failed is exactly
 #1587's trap). `failedGates` is the sum of `sliceLedger[].failed`, the
 only failure record kept.
```

## Also derived from the ledger, not from the loop counter: on slice-cap
<a id="also-derived-from-the-ledger-not-from-the-loop-counter-on-sl"></a>

```text
 Also derived from the ledger, not from the loop counter: on slice-cap
 exhaustion the loop index has already advanced past the last slice, so
 `gateSlices + 1` reported one MORE slice than the payload's own ledger
 contained — a second, smaller field-vs-field contradiction in the same
 payload (temperloop#1587).
```

## temperloop#865 — THE LOUD HALF. A worker that backgrounded its gate an
<a id="temperloop-865-the-loud-half-a-worker-that-backgrounded-its-"></a>

```text
 temperloop#865 — THE LOUD HALF. A worker that backgrounded its gate and
 yielded leaves a sentinel still reading `running` (or, if it never issued
 the handed invocation at all, none). Today "waiting for the gate" is
 indistinguishable from a healthy long gate until the budget is gone; this
 is the one place in the run that can tell them apart, because it reads the
 artifact from the same worktree the acceptance gate just ran in. It is a
 NOTICE, never a block: 3e.5 is the acceptance authority and its verdict
 stands on its own, so a stale sentinel must not fail an otherwise-green
 item — it must be impossible to miss.
```

## A TIMEOUT is NOT a gate failure — its own escalation kind, so an opera
<a id="a-timeout-is-not-a-gate-failure-its-own-escalation-kind-so-a"></a>

```text
 A TIMEOUT is NOT a gate failure — its own escalation kind, so an operator
 (or the pipeline's escalation router) can tell "the budget ran out" from
 "this branch is broken" without reading a log. Same for exhausting the
 slice cap: the suite did not finish, which says nothing about the tree.
 temperloop#1021 is preserved exactly — and sharpened: this arm is now taken
 only when NOTHING failed in the slices that did run, so "the budget ran
 out" can never be the label on a run that already observed a real failure.
```

## ===== END OF PHASE 1 (temperloop#2080) ===============================
<a id="end-of-phase-1-temperloop-2080"></a>

```text
 ===== END OF PHASE 1 (temperloop#2080) ==================================
 Everything above is build + local verification; NOTHING above pushes,
 opens a PR or merges. The context handed to phase 2 is assembled here and
 the function returns null — the fall-through that says "no terminal record,
 proceed". On the single-arm path driveItem() calls phase 2 immediately, so
 the two halves are indistinguishable from the pre-split one. On a
 dual-build arm the caller STOPS here and holds the level barrier.
```

## preference "A" is the BASELINE arm and "B" the CANDIDATE arm — the
<a id="preference-a-is-the-baseline-arm-and-b-the-candidate-ar"></a>

```text
 preference "A" is the BASELINE arm and "B" the CANDIDATE arm — the
 record-a/record-b binding above, restated here once so the mapping lives
 beside the call that creates it rather than at the row writer.
```

## The LEVEL pick is `level-pick-and-operator-levers` (temperloop#2083), 
<a id="the-level-pick-is-level-pick-and-operator-levers-temper"></a>

```text
 The LEVEL pick is `level-pick-and-operator-levers` (temperloop#2083), by
 construction of the barrier: this row is written before any pick exists,
 so it says so rather than guessing one.
```

## The BUFFERED board write (see 3a's own comment). Recorded once per ITE
<a id="the-buffered-board-write-see-3a-s-own-comment-recorded-"></a>

```text
 The BUFFERED board write (see 3a's own comment). Recorded once per ITEM,
 never per arm, and carrying the exact command the pick will run.
```

## Phase 1's guard already converted this item's throw into an
<a id="phase-1-s-guard-already-converted-this-item-s-throw-int"></a>

```text
 Phase 1's guard already converted this item's throw into an
 escalation and it produced no arms — nothing to judge, no row to
 write. Straight to the level's disposition.
```

## A judged preference is a per-ITEM loss for the arm it did not prefer.
<a id="a-judged-preference-is-a-per-item-loss-for-the-arm-it-d"></a>

```text
 A judged preference is a per-ITEM loss for the arm it did not prefer.
 The LEVEL pick tallies these; it is not made here.
```

## Nothing to pick from for this item. This ESCALATES rather than parks:
<a id="nothing-to-pick-from-for-this-item-this-escalates-rathe"></a>

```text
 Nothing to pick from for this item. This ESCALATES rather than parks:
 a level pick over an item with no gate-passing arm is not a choice,
 and the two builds' worktrees are intact for a human to read.
```

## A throw in the JUDGE/LEDGER/RECORD phase is the same silent-loss risk
<a id="a-throw-in-the-judge-ledger-record-phase-is-the-same-si"></a>

```text
 A throw in the JUDGE/LEDGER/RECORD phase is the same silent-loss risk
 as one in the build phase — the item would be dropped to `null` after
 its arms had already been built. Surface it instead.
```

## The CLAIM entrypoint + --board are resolved by the orchestrator's Step
<a id="the-claim-entrypoint-board-are-resolved-by-the-orchestr"></a>

```text
 The CLAIM entrypoint + --board are resolved by the orchestrator's Step 0
 probe and passed in input.claimCmd (an absolute path to claim.sh).
```

## claim.sh exits 0 on success; we wrap a contention/no-op check into the
<a id="claim-sh-exits-0-on-success-we-wrap-a-contention-no-op-"></a>

```text
 claim.sh exits 0 on success; we wrap a contention/no-op check into the
 executor by asking it to emit a CLAIMED/CLAIM_CONFLICT line. The
 orchestrator's claim.sh itself sets In Progress + stamps Host/Session.
```

## temperloop#1819: deniedOrQuota — a quota death (canary cannot spawn) i
<a id="temperloop-1819-deniedorquota-a-quota-death-canary-cann"></a>

```text
 temperloop#1819: deniedOrQuota — a quota death (canary cannot spawn) is
 its own kind; a genuine denial keeps machinery-denied unchanged. The
 worktree may not exist yet (the prelude is what creates it) — the
 deterministic path is still named so the disposer knows where to look.
```

## kind: spike — read-only fork, NO push/PR (skip 3b–3h)
<a id="kind-spike-read-only-fork-no-push-pr-skip-3b-3h"></a>

```text
 --- kind: spike — read-only fork, NO push/PR (skip 3b–3h) ---------------
 Runs AFTER 3a (claim-first) above so the spike is claimed before its
 read-only verdict fork begins — matching build.md L312 and the kernel
 claim-first contract (temperloop#650).
```

## temperloop#982: item.model || undefined — see callWorker()'s
<a id="temperloop-982-item-model-undefined-see-callworker-s"></a>

```text
 temperloop#982: item.model || undefined — see callWorker()'s
 identical comment above; an empty-string item.model must collapse
 to the inherit-session sentinel, not ride through as a literal "".
```

## temperloop#1819 — a thrown quota-death message classifies directly;
<a id="temperloop-1819-a-thrown-quota-death-message-classifies"></a>

```text
 temperloop#1819 — a thrown quota-death message classifies directly;
 any other throw keeps its pre-#1819 path (the parallel() catch-all
 converts it to a worker-error escalation, unchanged).
```

## temperloop#1819 — the bare-null shape carries no text; ask the canary
<a id="temperloop-1819-the-bare-null-shape-carries-no-text-ask"></a>

```text
 temperloop#1819 — the bare-null shape carries no text; ask the canary
 whether the harness can spawn agents at all before calling this a
 content failure. A spike has no worktree (read-only), so `worktree: null`.
```

## agent() returned null — user skip or terminal API error. Spikes are
<a id="agent-returned-null-user-skip-or-terminal-api-error-spi"></a>

```text
 agent() returned null — user skip or terminal API error. Spikes are
 read-only so no retry applies; escalate immediately.
```

## Spike parks as a verdict marker (no pr/pushed_sha). The orchestrator
<a id="spike-parks-as-a-verdict-marker-no-pr-pushed-sha-the-or"></a>

```text
 Spike parks as a verdict marker (no pr/pushed_sha). The orchestrator
 turns this into a [v] sentinel + Done/close at the boundary.
```

## 3b-0 branch. Dep-merge precondition gate (#108)
<a id="3b-0-branch-dep-merge-precondition-gate-108"></a>

```text
 --- 3b-0 branch. Dep-merge precondition gate (#108) ---------------------
 The gate itself ran as prelude step `deps-merged` above; the DECISION is
 here, in .mjs, reading that step's own DEPS_MERGED/DEPS_UNMERGED object.
```

## worktree.sh's CREATED.path is the authoritative deterministic path; it
<a id="worktree-sh-s-created-path-is-the-authoritative-determi"></a>

```text
 worktree.sh's CREATED.path is the authoritative deterministic path; it
 equals worktreePath by construction, but trust the script's value.
```

## temperloop#1819 — classify a session-quota death FIRST, before the pro
<a id="temperloop-1819-classify-a-session-quota-death-first-be"></a>

```text
 temperloop#1819 — classify a session-quota death FIRST, before the probe
 and the retry: under an exhausted quota every further spawn (the probe,
 the retry, its probe) dies the same death, and the work already in the
 worktree is exactly what the quota-exhausted disposition preserves.
```

## temperloop#1819 — the RETRY can be the spawn that crosses the quota
<a id="temperloop-1819-the-retry-can-be-the-spawn-that-crosses"></a>

```text
 temperloop#1819 — the RETRY can be the spawn that crosses the quota
 boundary; classify it before spending another probe on a dead harness.
```

## temperloop#1319 degraded case: computed once here (empty when
<a id="temperloop-1319-degraded-case-computed-once-here-empty-"></a>

```text
 temperloop#1319 degraded case: computed once here (empty when
 REQUIRE_DISCRIMINATION_EVIDENCE is unarmed), logged as a named warning at
 3h below once `pr` is known, and threaded to park() for the Step 6 tally.
```

## Drive slices until the suite finishes. GATE_SLICE is the ONLY outcome 
<a id="drive-slices-until-the-suite-finishes-gate-slice-is-the"></a>

```text
 Drive slices until the suite finishes. GATE_SLICE is the ONLY outcome that
 continues the loop; everything else is terminal on the first pass, so a
 repo whose suite fits in one slice (or whose vendored gate predates the
 seam) behaves exactly as it did before — one call, one outcome.
```

## temperloop#1698 — sticky once ANY slice reported no usable elapsed fig
<a id="temperloop-1698-sticky-once-any-slice-reported-no-usabl"></a>

```text
 temperloop#1698 — sticky once ANY slice reported no usable elapsed figure.
 The total is then UNKNOWN, not a partial sum presented as the whole: a run
 that summed 140s of three slices because the other two reported nothing is
 the same confident-wrong-number defect one level up.
```

## The selection fingerprint the PREVIOUS slice reported (temperloop#1663
<a id="the-selection-fingerprint-the-previous-slice-reported-t"></a>

```text
 The selection fingerprint the PREVIOUS slice reported (temperloop#1663).
 Empty on the first slice — there is nothing to compare a fresh start against,
 and an older vendored quality-gates.sh reports none at all, in which case this
 stays empty forever and the gate behaves exactly as it did before.
```

## temperloop#115/#1021: without an explicit timeout the executor's Bash
<a id="temperloop-115-1021-without-an-explicit-timeout-the-exe"></a>

```text
 temperloop#115/#1021: without an explicit timeout the executor's Bash
 tool kills the suite at its 120s default. GATE_BASH_TIMEOUT_MS is now
 DERIVED from the slice budget (see the tunables block) and is an outer
 BACKSTOP — the slice's own soft budget is what normally ends a slice.
```

## …and if that backstop DOES fire, the executor reports GATE_TIMEOUT, no
<a id="and-if-that-backstop-does-fire-the-executor-reports-gat"></a>

```text
 …and if that backstop DOES fire, the executor reports GATE_TIMEOUT, not
 a guessed GATE_FAIL. This is the acceptance criterion of #1021: a
 budget-exhausted run must be distinguishable from real breakage.
```

## temperloop#1819: the #1819 incident's own machinery shape — a gate
<a id="temperloop-1819-the-1819-incident-s-own-machinery-shape"></a>

```text
 temperloop#1819: the #1819 incident's own machinery shape — a gate
 step killed by the session limit read as SPINE_DENIED. deniedOrQuota
 re-classifies it via the canary; a genuine denial is unchanged.
```

## The slice's own exit status, when the executor reported one. 75 is the
<a id="the-slice-s-own-exit-status-when-the-executor-reported-"></a>

```text
 The slice's own exit status, when the executor reported one. 75 is the
 budget-spent protocol code; anything else beside a resume point is an
 anomaly a reader should see rather than have silently normalized away.
```

## Carry the list identity forward with the index it belongs to. A slice 
<a id="carry-the-list-identity-forward-with-the-index-it-belon"></a>

```text
 Carry the list identity forward with the index it belongs to. A slice that
 reports no fingerprint (an older vendored gate script) leaves this empty,
 which disarms the check rather than tripping it.
```

## ONE verdict, derived once from the ledger (temperloop#1587), and ONE
<a id="one-verdict-derived-once-from-the-ledger-temperloop-158"></a>

```text
 ONE verdict, derived once from the ledger (temperloop#1587), and ONE
 payload shape shared by both escalation arms — so the kind an operator (or
 the escalation router) reads and the numbers underneath it are computed
 from the same input and cannot disagree.
```

## temperloop#2135 — how many extra GATE_MAX_SLICES allotments the RESUME
<a id="temperloop-2135-how-many-extra-gate-max-slices-allotmen"></a>

```text
 temperloop#2135 — how many extra GATE_MAX_SLICES allotments the RESUME
 path (above) already spent before this verdict was reached. 0 on every
 run that fit inside the original ceiling, exactly like today.
```

## temperloop#1698 — `null`, not a partial sum, when any slice's figure w
<a id="temperloop-1698-null-not-a-partial-sum-when-any-slice-s"></a>

```text
 temperloop#1698 — `null`, not a partial sum, when any slice's figure was
 unreadable. A payload that reports a multi-minute run as having taken no
 time is the exact shape this item removes.
```

## temperloop#865 — what the WORKER's own scoped gate left behind in this
<a id="temperloop-865-what-the-worker-s-own-scoped-gate-left-b"></a>

```text
 temperloop#865 — what the WORKER's own scoped gate left behind in this
 worktree: 'finished' | 'running' | 'absent' | 'unknown'.
```

## A genuinely RED suite still escalates exactly as before — including th
<a id="a-genuinely-red-suite-still-escalates-exactly-as-before"></a>

```text
 A genuinely RED suite still escalates exactly as before — including the
 case where a failure found in slice 1 is followed by green (or unfinished)
 later slices: the ledger keeps it, so it is never lost.
```

## GATE_PASS or GATE_ABSENT → proceed. Report the MARGIN, not just the ve
<a id="gate-pass-or-gate-absent-proceed-report-the-margin-not-"></a>

```text
 GATE_PASS or GATE_ABSENT → proceed. Report the MARGIN, not just the verdict:
 this is the decay signal that #115's bare number never had. A run that ate
 most of its slice budget, or needed several slices, says so on a GREEN run —
 before it becomes the next false failure.
```

## ======================================================================
<a id="note"></a>

```text
 =============================================================================
 driveItemPr — PHASE 2 (temperloop#2080): 3f push + PR → 3g CI → 3g.5 →  3h.
 =============================================================================
 The callable boundary ADR 0038's level barrier needs. Takes the context
 phase 1 produced and returns the item's terminal record. Every line below is
 the pre-split 3f–3h body, re-homed verbatim; the only edit is the
 destructuring header that replaces the closure it used to read from.

 On a dual-build level this is NOT called for an in-scope item's arms — that
 is the barrier. It is called (by driveItem, unchanged) for a not-in-scope
 item, and it is what `level-pick-and-operator-levers` will call for the
 winning arm once the pick is made.
```

## 3f-0a. Rebase onto fresh origin/<default> — the unconditional stale-ba
<a id="3f-0a-rebase-onto-fresh-origin-default-the-unconditional-sta"></a>

```text
 3f-0a. Rebase onto fresh origin/<default> — the unconditional stale-base
 guard (#525). EVERY worker (not just speculative ones) branched off the
 default at the start of its run; on a fast-moving default a long run lets
 the default advance mid-build, so by here the worker's base may be stale
 and a straight push would land a PR whose cumulative diff REVERTS whatever
 merged in between (W49/W52). pr.sh rebase fetches the default fresh and
 replays the worker's commits onto its tip (a no-op when already current).
 On REBASE_CONFLICT it has already `git rebase --abort`ed (worktree left
 clean, NEVER a silent revert) → escalate as a rebase conflict for a human.

 SKIPPED on a recovery whose branch is ALREADY on origin (temperloop#939).
 The rebase rewrites the worker's commits, so the plain (non-force) push
 below would then be a non-fast-forward and come back PUSH_REJECTED —
 converting a clean recovery of already-landed work into a spurious
 escalation, which is the exact class of failure #939 is about. The
 RECOVER_COMMITTED stage has pushed nothing yet, so it still rebases
 normally; so does every non-recovery drive.
```

## 3f-1. Push-by-SHA on the plan's branch.
<a id="3f-1-push-by-sha-on-the-plan-s-branch"></a>

```text
 3f-1. Push-by-SHA on the plan's branch.

 `--allow-rewrite` (temperloop#2103): 3f-0a above has just REWRITTEN this
 branch's history onto a fresh origin/<default>, and on a continuation round
 an earlier round has already pushed the pre-rebase history to origin. A
 plain push of a rewritten, already-pushed branch can NEVER fast-forward, so
 it came back PUSH_REJECTED every time — observed three times in one session,
 each recovered by hand with a lease-force push. The `recovery && pushed`
 skip above only covers the temperloop#939 lost-return path; an ordinary
 continuation round is not a `recovery` and never took it.

 This is a REQUEST, not a force: pr.sh downgrades to a plain push on any
 provable fast-forward (#335), issues nothing at all when the ref is absent
 or unreadable, and when it does rewrite it uses
 `--force-with-lease=<ref>:<sha>` over a value it read first — so a
 concurrent writer is rejected rather than overwritten. The flag is spelled
 `--allow-rewrite` rather than `--force` so the command line the orchestrator
 executes carries no classifier-visible force token (#437).

 AND NOT ON THE LEASE ALONE (temperloop#2103 round 3). Because this call site
 requests a rewrite on EVERY item — not only on a rescue — it is the busiest
 force path in the pipeline, and a lease protects only against a writer who
 moves the ref BETWEEN pr.sh's read and its push, never against content that
 was already there. So pr.sh gates the force on the SAME supersede check
 preserveCommittedWorkCmd (below) applies on the rescue path: a branch name
 colliding with unrelated work — a leftover manual branch, a reused slug, a
 planning bug — comes back PUSH_REJECTED with `refused_reason` rather than
 being overwritten and reported as an ordinary PUSHED straight into pr-open.
 The two force paths this file drives are symmetric; the asymmetry between
 them was the round-2 finding.
```

## 3f-2. Open the PR. The verification surface is read from the determini
<a id="3f-2-open-the-pr-the-verification-surface-is-read-from-the-d"></a>

```text
 3f-2. Open the PR. The verification surface is read from the deterministic
 file path (--verification-surface-file) so its body never enters context.
 The worker's verdict JSON is needed by pr.sh open (--verdict); we hand the
 executor a heredoc-built temp file so the (possibly large) verdict stays in
 the executor's process, not this workflow's. We pass only the fields pr.sh
 reads from the verdict — summary + acceptance_results — assembled compactly.
```

## temperloop#1430: the §3e review outcome rides the PR body via `summary
<a id="temperloop-1430-the-3e-review-outcome-rides-the-pr-body-via-"></a>

```text
 temperloop#1430: the §3e review outcome rides the PR body via `summary`
 (the one verdict field pr.sh always renders) — this is what lets a real
 review pass (or a genuine, non-guaranteed skip) be OBSERVED on the PR
 itself, rather than living only in this run's transcript.
 The worker's own prose is neutralized for the same reason reviewer prose
 is (see REVIEW_BLOCK_MARK): it is spliced verbatim ABOVE `## Review
 notes`, so an un-neutralized delimiter there would open a phantom first
 block whose span swallowed the `§3e review — ran:` line the cap must
 never cut.
```

## Cross-repo `Closes` qualification (temperloop#852, build.md 3f "Cross-
<a id="cross-repo-closes-qualification-temperloop-852-build-md-3f-c"></a>

```text
 Cross-repo `Closes` qualification (temperloop#852, build.md 3f "Cross-repo
 `repo:` honor point"). `item.repo` (plan-schema.md § Optional `repo:`
 field) names the repo THIS item's PR opens against; it is absent for the
 common same-repo case. `gh_issue:`/`also_closes:` numbers are tracked
 wherever the item was triaged — the plan's HOME repo, i.e. `ownerRepo` —
 NOT necessarily `item.repo` (the kernel-classified-item case is the
 mirror image of the `repo:` case: the PR lands in the kernel repo but the
 issue was triaged, and stays tracked, in the plan's home repo). So a
 cross-repo item (`item.repo` set AND different from `ownerRepo`) must
 emit the fully-qualified `owner/repo#N` form — a bare `Closes #N` is
 same-repo only and would resolve against the wrong repo (or nothing) once
 pushed. pr.sh's `closes_line()`/`validate_issue()` already accept either
 shape verbatim (do not change pr.sh) — the qualification decision belongs
 here, at the one call site that knows both repos. A same-repo item (no
 `repo:`, or `repo:` equal to `ownerRepo`) is unaffected: bare `Closes #N`
 exactly as before.
```

## THE FAILURE THIS BOUNDS — the sibling of temperloop#1071 one layer up.
<a id="the-failure-this-bounds-the-sibling-of-temperloop-1071-one-l"></a>

```text
 THE FAILURE THIS BOUNDS — the sibling of temperloop#1071 one layer up. Run
 `wf_f3b9c160-6ca` routed four §3e reviewers. Two returned. `shell-reviewer`
 was spawned and never returned: its own agent transcript ends mid-sentence at
 "Now compiling the final review output", the workflow stopped writing its
 journal, and ~41 minutes of silence followed until a human ran `TaskStop`.
 `workflow-reviewer` — MANDATORY for that item's `claude/commands/*.md` diff —
 never launched at all, because the §3e pass awaited each reviewer in turn and
 the second one never resolved.

 WHY THAT IS WORSE THAN A PLAIN HANG. The mandatory-reviewer contract
 (foundation#1007) guarantees `workflow-reviewer` RUNS, and `review.
 mandatory_ok` reports whether it did. A hang UPSTREAM of it in the same pass
 means neither the guarantee nor the tally is ever EVALUATED: the gate does not
 fail, it never resolves. An operator watching the tally sees nothing wrong,
 because there is no tally yet — which is exactly why the incident stayed
 invisible for 41 minutes. So the bound's job is not only to stop waiting; it
 is to make the pass ALWAYS produce a disposition.

 WHY THE BOUND CANNOT BE A TIMER. Same two runtime facts temperloop#1071 hit:
 `Date.now()` THROWS here and there is no timer primitive, so a deadline is not
 directly expressible. But `Promise.race` IS — what #1071 lacked was something
 that resolves ON A CLOCK to race against, and this file already owns one: a
 machinery executor running a WAIT. reviewWaitAgent() is that tick.

 TEMPERLOOP#2049 — WHERE THAT TICK HAS TO LIVE. The wait was first written as
 a bare inline `sleep N; printf '<json>'` Bash command. A harness permission
 control REFUSES that command shape in the machinery executor's seat, and the
 executor's prompt then told it to report the interval elapsed anyway: the
 nominal 1200s ceiling realized in ~30s, abandoning reviewers that were
 finishing normally at 177-257s. The wait now runs inside the named helper
 workflows/scripts/build/review-wait.sh (the shape ci-poll.sh already uses,
 observably honoured in the same seat for a 280s single call), and an elapse
 is honoured only when it carries the script's OWN `realized_secs`. See
 reviewWaitAgent() for the measurements and both halves of the fix.
 A reviewer is an `agent({agentType})` call, NOT a shell command, so #1071's
 emitted-shell watchdog cannot reach it; the race is the only seam that can.

 THE SHAPE, mirroring #1071's ceiling+observability pair exactly:
   • REVIEW_AGENT_CEILING_SECS — the wall-clock ceiling on the WHOLE §3e pass,
     measured from fanout start. Every routed reviewer is spawned CONCURRENTLY
     (they are independent read-only passes; nothing ordered them), so one
     hung agent can no longer keep a later one from launching — the observed
     failure — and the pass costs max(reviewer) rather than sum(reviewer).
     A reviewer still unsettled at the ceiling is ABANDONED, not killed: this
     runtime cannot cancel an agent, and the promise is simply never awaited
     again. Its disposition then respects mandatory-vs-advisory (runReviewers).
   • REVIEW_AGENT_SLOW_SECS — the observability half: a pass still running at
     this threshold emits a log() progress notice naming who is outstanding, so
     a long review is VISIBLE well before it is given up on. 0 disables it.
 Both are NAMED SETTINGS (BUILD_REVIEW_AGENT_CEILING_SECS /
 BUILD_REVIEW_AGENT_SLOW_SECS), handed in by the orchestrator at Step 0 on the
 SAME seam as GATE_SLICE_SECS / the #1071 pair above, for the same structural
 reason (this runtime has no shell to source build.config.sh).
```

## temperloop#2127 — the PRIOR reviewed SHA, kept beside build-review-rou
<a id="temperloop-2127-the-prior-reviewed-sha-kept-beside-build-rev"></a>

```text
 temperloop#2127 — the PRIOR reviewed SHA, kept beside build-review-rounds
 in the SAME worktree git dir (never the working tree — identical
 durability rationale as the round counter above: it must survive the
 escalate -> orchestrator -> re-invoke loop, and must never appear in
 `git status`, a `--scoped` gate's untracked-path resolution, or a
 coverage manifest). Read BEFORE the bump below writes this round's HEAD
 into it, so what this call emits is always the SHA that was HEAD at the
 START of the round that is about to run — i.e. the commit the PRIOR
 round actually reviewed.

 VALIDATE, DO NOT MERELY SANITISE (round 2, HIGH A). `tr -cd` is a
 FILTER, not a validator: it DELETES the bytes it dislikes and returns
 whatever survives, so a corrupted marker yields a plausible-but-bogus
 value that sails through any pure shape check downstream. Measured
 against the real generated shell: `not a sha at all` -> `aaaa`,
 `ref: refs/heads/main` -> `efefeada`, `deadbeefcafe deadbeefcafe` ->
 `deadbeefcafedeadbeefcafe`. Every one of those reaches the reviewer as
 a `git diff <bogus>..HEAD` instruction that dies `fatal: ambiguous
 argument` in the reviewer's own shell — SILENTLY, since §3e never sees
 that shell. So the filtered value is RESOLVED against this very repo
 before it is emitted:
   - `git rev-parse --verify --quiet '<sha>^{commit}'` rejects anything
     that is not a real commit object HERE (filtered garbage, a GC'd or
     never-existed sha, a sha carried in from another repo).
   - `git merge-base --is-ancestor <sha> HEAD` rejects a real-but-
     ORPHANED commit. That is round 2's HIGH B2: §3e writes this marker
     BEFORE 3e.5-pre's gate-freshness rebase, so on the §3g CI-fix
     re-review path the recorded SHA can be a pre-rebase commit that no
     longer sits on the branch, and `<orphan>..HEAD` would span the
     whole upstream delta PLUS the rebase rewrite PLUS the fix — the
     opposite of "what changed since the last review". Degrading is the
     honest outcome: a rewritten history has no delta to point at.
 Either rejection falls back to the empty string, which
 reviewContinuationSection() renders as its commit-range-FREE wording —
 the fails-SOFT contract every other marker step here already keeps.
```

## driveItem used to be ONE function that interleaved build → local gate
<a id="driveitem-used-to-be-one-function-that-interleaved-build-loc"></a>

```text
 driveItem used to be ONE function that interleaved build → local gate → PR →
 CI per item. The dual-build harness cannot: ADR 0038 fixes the PICK at the
 LEVEL, so every in-scope item's build, local gate and pairwise judge must be
 known BEFORE any PR opens for the level (the "level barrier"). That is a
 phase split, not a flag — so the split is made STRUCTURAL here rather than
 left as an `if (dualBuild)` branch threaded through 700 lines:

   driveItemBuildPhase()  3a claim → 3b worktree → 3c worker → 3d verdict →
                          3e review → 3e.5 gate → 3e.6 activation gate.
                          Returns a TERMINAL record (parked/escalation), or
                          null having filled `box.ctx` with everything the
                          second phase needs. NOTHING here pushes, opens a
                          PR, or merges — that property is what makes the
                          barrier expressible at all.
   driveItemPr()          3f push+PR → 3g CI → 3g.5 re-render → 3h park.

 THE SINGLE-ARM PATH IS UNCHANGED BY CONSTRUCTION: driveItem() below calls
 both phases back to back, in the same order, with nothing between them — so
 the stage transcript, the agent-spawn sequence and the machinery step
 ordering a flag-less run produces are byte-for-byte what they were before
 the split (workflows/scripts/build/tests/test_workflow.sh pins the ORDERING
 explicitly, not merely the return object).

 WHY A `box` RATHER THAN A RETURNED CONTEXT. The build phase has ~25 early
 `return escalate(...)` / `return park(...)` sites. Rewriting every one of
 them into `{ result: … }` would be 25 chances to typo a control-flow edge
 that only one specific failure fixture exercises. Instead the phase function
 keeps EVERY existing return statement byte-identical (a terminal record, or
 null on the fall-through) and hands its context out through the one
 out-parameter — so the diff touches the fall-through alone.
```
