// build-level.mjs — foundation's FIRST saved Workflow.
// =============================================================================
// The per-level driver for /build. It re-homes build.md's 3a–3h
// per-item loop out of the conversational orchestrator and into a bounded
// Workflow process, so the orchestrator's context stays pinned to ONE small
// {parked, escalations} object per dependency level — regardless of how many
// items or machinery calls the level contains. The orchestrator invokes this once
// per level (via the Workflow tool), the workflow drives every item's machinery +
// worker, and returns only what to write back. The orchestrator still owns the
// MERGE GATE (Step 4) — this workflow never merges and never writes the plan
// note. Corollary (temperloop#1452): build.md §3h.5's as-you-go merge, which
// needs BOTH of those seats, is scoped to /build's `--no-workflow`
// conversational path and has no implementation here by design — a
// Workflow-path level batches every item to the Step-4 gate.
//
// -----------------------------------------------------------------------------
// DESIGN NOTES (read before editing — these three decisions are load-bearing)
// -----------------------------------------------------------------------------
//
// 1. THE runMachinery BRIDGE (spike #421 verdict §1; BATCHED per temperloop#942).
//    The deterministic bash machinery (worktree.sh / pr.sh / ci-poll.sh /
//    quality-gates.sh / board claim.sh) is the source of truth for every
//    mechanical step. But the Workflow runtime has NO filesystem, NO Node, NO
//    shell in the script body — so there is no `sh()` primitive. The bridge:
//    a machinery call becomes an `agent({schema})` whose entire job is "run
//    exactly this command text, return each step's closed-outcome JSON line as a
//    validated object." The runtime's agent() hook gives a subagent the normal
//    Bash tool and (with a schema) returns a validated object, not free text —
//    so an agent that runs a command IS the missing sh().
//
//    WHAT THE BRIDGE'S INVARIANT ACTUALLY IS: the BRANCHING LOGIC (if
//    SCAN_BLOCKED → escalate, if PUSH_REJECTED → escalate) stays in legible .mjs
//    here, never buried in an opaque agent prompt that returns a single verdict.
//    It is NOT "one agent per command" — that was only the cheapest way to keep
//    each step's outcome individually visible. temperloop#942 measured the cost
//    of taking it literally: an L0 level of 3 items spawned 40 agents (3 real
//    workers + 37 haiku micro-agents), each paying ~160K cache-read tokens and 4
//    API round-trips to execute one shell one-liner.
//
//    So mechanically-adjacent steps are now BATCHED into one executor agent via
//    `runMachineryBatch()`: one Bash invocation runs the steps in sequence and
//    prints ONE JSON line per step, and the agent returns them as
//    `{results:[…]}` — so the driver still sees EVERY step's own closed-outcome
//    object and branches on each of them, one `if` at a time, right here in .mjs.
//    The bash wrapper's only added logic is a `case` short-circuit that stops the
//    sequence when a step's outcome means the remaining steps must not run (a
//    stop-early mirror, never the decision: the .mjs re-reads the same JSON and
//    makes the authoritative call, and a truncated results array simply means the
//    .mjs already escalated on the earlier step). Three batch sites:
//      • `prelude:<slug>`  — 3a claim + 3b-0 deps-merged + 3b worktree create
//      • `pr-batch:<slug>` — 3f-0a rebase + 3f-0 scan + 3f-1 push + 3f-2 pr open
//      • `ci-batch:<slug>#n` — the interleaved merge-state probe + CI poll slices
//    The 3e.5 quality gate stays a SOLO call on purpose — it is the one machinery
//    step whose own runtime is minutes-scale (measured 6:05 for this repo's
//    suite), so folding it into a batch would put a single Bash invocation within
//    reach of the agent's ~10-min cap. See DESIGN NOTE 2.
//
//    The cost — ~4 executor spawns + 1 worker per item — lands entirely in THIS
//    discardable workflow process, never the orchestrator's context. That is the
//    whole point: orchestrator growth is bounded to one summary object per level.
//
//    CRITICAL (from the live probe in the spike): shell-quote every argument.
//    A spaced path (e.g. a vault plan path "Plans/2026-06-13 foo - bar.md")
//    MUST be single-quoted in the command string or the one-shot executor runs
//    the wrong command. Every command this file builds goes through `sq()` for
//    each interpolated value — and batching does NOT relax that: a batch is
//    literally the same per-step command strings joined by fixed shell syntax,
//    so every argument is still sq()-quoted exactly as before.
//
// 2. THE CI-POLL LOOP (spike #421 verdict §1 "ci-poll caveat").
//    ci-poll.sh can poll up to 1h, but an agent()'s foreground Bash has a
//    ~10-min cap — so we must NOT runMachinery a single long poll (it would die
//    mid-poll). Instead we drive SHORT-timeout polls (CI_POLL_SLICE_SECS,
//    default 240s) until the outcome resolves to CI_GREEN or CI_FAILED, bounded
//    by a total wall budget (CI_POLL_TOTAL_SECS). The short poll returns TIMEOUT
//    when the slice elapses with checks still pending — that is the signal to
//    poll again, NOT a failure. On CI_FAILED within a small retry budget we
//    re-spawn the worker, force-push, and re-poll PINNED to the new SHA (the #254
//    false-green guard — never let the poll re-resolve the head from the PR API
//    after a force-push). Past the budget without resolution → escalate
//    `ci-failed` so a human drives it.
//
//    temperloop#942 stopped spawning a FRESH agent per poll cycle (the measured
//    L0 run burned 7 ci-poll spawns + 8 `gh pr view` spawns at one level) — but
//    the ~10-min cap is unchanged and is now enforced ARITHMETICALLY rather than
//    by comment. One `ci-batch` agent runs CI_POLL_SLICES_PER_BATCH slices in one
//    Bash invocation, and that count is DERIVED: it is
//    floor(CI_POLL_MAX_BATCH_WALL_MS / CI_POLL_SLICE_SECS), so the poll wall a
//    single Bash invocation may occupy can never exceed CI_POLL_MAX_BATCH_WALL_MS
//    (< the AGENT_BASH_CAP_MS ceiling) no matter how the slice length is retuned.
//    Each individual ci-poll.sh invocation still carries its own
//    CI_POLL_SLICE_SECS `--timeout`; the batch never asks for one long poll.
//    The batch also short-circuits the moment a slice resolves, so a green PR
//    does not sit through the remaining slices.
//
// 3. DROP isolation:'worktree' (spike #421 verdict §5).
//    The worker agent() runs WITHOUT isolation:'worktree'. build has its
//    own worktree mechanism (worktree.sh create), and three contracts assume
//    IT, not the runtime's opaque isolation: (a) the deterministic path
//    <repoRoot>.wt/<slug> that pr.sh / quality-gates / the verification-surface
//    file all reference; (b) the .build-guard write-jail marker that arms
//    the PreToolUse guard per-worktree; (c) push-by-SHA on the plan's branch.
//    So we runMachinery('worktree.sh create …') first, then tell the worker (in its
//    prompt) that its cwd IS that deterministic path. The worker's writes are
//    confined by the .build-guard hook — the intended jail.
//
// -----------------------------------------------------------------------------
// I/O CONTRACT
// -----------------------------------------------------------------------------
//   Input  (via global `args`):
//     { repoRoot, planLink, board, items:[{ slug, branch, title, kind,
//        ghIssue, alsoCloses, repo, model, acceptance, source, scope, notes,
//        dependsOn, activation }],
//       ownerRepo, claimCmd, verdicts, onlySlugs }
//
//     repoRoot   — the parent checkout's top-level path; worktrees live at
//                  `<repoRoot>.wt/<slug>` and machinery scripts at
//                  `<repoRoot>/workflows/scripts/build/`.
//     planLink   — the plan note's vault link (passed to pr.sh --plan-link).
//     board      — board id (3/4) or null/false when board is OFF.
//     items      — this level's FULL item array (the onlySlugs filter, below,
//                  selects the active subset on a continuation). Per item,
//                  `dependsOn` is an array of { slug, sha } — the merged head
//                  SHA of each `depends-on` target (from that dep's plan-note
//                  `pushed_sha:`). It gates worktree creation (3b-0, #108): the
//                  worktree is created only once every dep SHA is an ancestor of
//                  origin/<default> (i.e. the depended-on PR has MERGED), so the
//                  worker builds and self-verifies against merged dependency
//                  code, not a pre-merge base. Absent/empty for level-0 items or
//                  items whose only cross-item edges are `after:` (no merge dep).
//                  `repo` is the item's plan-schema `repo:` field (owner/repo,
//                  absent for the common same-repo case) — the ONLY thing it
//                  drives today is the 3f cross-repo `Closes` qualification
//                  below (temperloop#852); it does NOT yet retarget worktree
//                  creation/`repoRoot` or CI polling per item, a separate,
//                  larger gap this fix does not attempt.
//                  `activation` is the item's plan-schema `activation:` block
//                  straight through — `{ class, proof, locus }`, absent on an
//                  item that declares none (temperloop#1219). ONLY `class: A`
//                  does anything here: §3e.6 runs its `proof:` predicate against
//                  the worktree between 3e.5 and 3f. Absent, or `class: B`/`C`
//                  (ledger-discharged at 4d-epic step 2a, orchestrator-side),
//                  is a no-op on this path. WITHOUT this field the §3e.6 gate
//                  cannot run at all — the defect temperloop#1219 filed.
//     ownerRepo  — "owner/repo" for ci-poll.sh / gh ops. The workflow has no
//                  shell to derive it, so the orchestrator passes it in (Step 0
//                  probe: `gh repo view --json nameWithOwner -q .nameWithOwner`).
//                  WITHOUT it every CI poll gets '' → ERROR. This is also the
//                  qualifier used for a cross-repo item's `Closes` line (3f,
//                  temperloop#852): `gh_issue:`/`also_closes:` numbers are
//                  tracked wherever the item was triaged — the plan's HOME repo
//                  (this value), not necessarily `item.repo` — so when
//                  `item.repo` is set and differs from `ownerRepo`, the issue
//                  ref is qualified as `<ownerRepo>#<N>` rather than emitted
//                  bare (build.md 3f "Cross-repo `repo:` honor point").
//     claimCmd   — absolute path to the board claim.sh entrypoint (Step 0 CLAIM
//                  probe). Used by 3a; defaults to bare 'claim.sh' if absent.
//     machineryAgentType
//                — optional override for the executor agent type. Absent (the
//                  norm) means 'machinery-executor', with an automatic one-time
//                  fallback to 'general-purpose' in a checkout that has not
//                  deployed the agent definition. Pass 'general-purpose' to pin
//                  the pre-#1014 behavior. See machineryAgent() below.
//     reviewBlockingMaxRounds
//                — the §3e convergence bound (temperloop#1970), resolved from
//                  $BUILD_REVIEW_BLOCKING_MAX_ROUNDS at build.md / sweep.md /
//                  fix.md Step 0 and handed in on the SAME seam, for the same
//                  structural reason, as gateSliceSecs (the Workflow runtime has
//                  no shell to source build.config.sh — DESIGN NOTE 1). Caps how
//                  many review ROUNDS one item's worktree may spend before a
//                  HIGH finding is carried into the PR body instead of
//                  escalating `review-blocking` again. Absent / empty /
//                  non-positive → the in-file default; never unbounded.
//     reviewAgentCeilingSecs / reviewAgentSlowSecs
//                — the §3e review-agent LIVENESS bound and its progress-notice
//                  threshold (temperloop#2003), resolved from
//                  $BUILD_REVIEW_AGENT_CEILING_SECS / $BUILD_REVIEW_AGENT_SLOW_SECS
//                  at build.md / sweep.md / fix.md Step 0 and handed in on the
//                  SAME seam as reviewBlockingMaxRounds above. The ceiling bounds
//                  the WHOLE §3e fanout's wall clock so a reviewer that never
//                  returns cannot stall the level; the slow threshold makes a
//                  long-but-alive review visible first. Both are clamped in this
//                  file (the ceiling floored at one CI-poll/gate slice) so no
//                  operator value can manufacture a false timeout on healthy
//                  work. Absent / empty / non-positive → the in-file defaults.
//     verdicts   — escalation-continuation map. Empty/absent on a fresh level;
//                  on a 3d-esc continuation, keyed by slug:
//                    { [slug]: { kind, verdict_section } }
//                  where `kind` is the escalation kind (design-fork/blocked/
//                  failed) and `verdict_section` is the FULL markdown block the
//                  orchestrator appended to the plan note (a `## Design verdict
//                  — <slug>` or `## User answers — <slug>` section, heading +
//                  body). driveItem injects it verbatim into the re-spawned
//                  worker's prompt (3c) so the worker sees the human's decision
//                  instead of re-forking. Read ONLY for slugs in onlySlugs.
//     onlySlugs  — optional continuation filter. Absent/empty on a fresh level
//                  (drive everything). On a continuation it is the array of
//                  still-unresolved slugs to re-drive; their siblings are
//                  already parked and are left untouched. A slug in onlySlugs is
//                  driven in CONTINUATION mode: claim (3a) and worktree create
//                  (3b) are SKIPPED (issue already claimed, worktree intact —
//                  re-creating it would discard the escalated build), and the
//                  captured verdict is injected at 3c.
//   Output (returned):
//     { parked:      [{ slug, pr, pushed_sha, acceptance_results }],
//       escalations: [{ slug, kind, payload }],
//       sidelined?:  [{ slug, path, branch, recovery }] }
//
//   `sidelined` (temperloop#2006) is present ONLY when `worktree.sh create`
//   shelved a resumable build for at least one item on this level. `create`
//   must never refuse (worktree.sh:783-787), so when the deterministic path
//   already holds committed work preservation could not capture, it MOVES that
//   occupant to `<path>.unpreserved-<sha8>` on `<branch>.unpreserved-<sha8>`
//   and creates over the freed path — reporting exactly that as the CREATED
//   line's `sidelined` / `sidelined_path` / `sidelined_branch` fields. This
//   driver reads them at 3b and surfaces the fact three ways: a named
//   `SIDELINED BUILD` log line at the moment of discovery, the same
//   `{ path, branch, recovery }` object stamped onto that item's OWN record
//   (`parked.sidelined`, or `escalation.payload.sidelined` — whichever the item
//   produced), and this level-wide rollup. `recovery` is the concrete reclaim
//   command, not a description of the event.
//
//   The reading lives HERE rather than in a driver's prose deliberately. It is
//   the same commit-ahead-of-base fact /fix's Step 4a worktree state table
//   reasons about, and /build and /sweep reach `worktree.sh create` through
//   this file's prelude with no table of their own — so all three inherit the
//   check from one place instead of each restating it (the per-instance-fix
//   smell: hoist the mechanism rather than patch the instance). A sideline is
//   NOT a failure and never stalls the level: the item is being rebuilt from
//   scratch and the shelved build stands until `worktree.sh prune`'s own
//   two-gate disposal owner reaps it. It is a notice a human should act on
//   before that happens.
//
//   A parked record MAY additionally carry `acceptance_unverified: true` +
//   `recovered_from: <RECOVER_* stage>` (temperloop#939). That pair means the
//   worker's return channel failed and this record was RECONSTRUCTED from
//   observable side-effects: the PR and SHA are ground truth, but the acceptance
//   results are UNKNOWN — never treat them as passing. The orchestrator MUST
//   re-verify that item's acceptance itself before the Step 4 merge gate.
//
//   A parked record MAY additionally carry `discrimination_gaps: [<criterion>,
//   ...]` (temperloop#1319) — present ONLY when this run armed
//   requireDiscriminationEvidence AND the done verdict had at least one
//   passed:true acceptance_results[] entry with an empty/absent
//   discrimination_evidence. Non-fatal (kernel principle 7 — advisory, never a
//   new blocking gate): already logged as a named warning at 3h; the
//   orchestrator rolls the list into the Step 6 summary tally (build.md §3f
//   step 2's sibling verification_surface degraded-case pattern).
//
//   A parked record MAY additionally carry `host_config_deferrals:
//   [{ criterion, host_config }, ...]` (temperloop#1182) — one entry per
//   acceptance criterion the worker reported DEFERRED because it turns on a
//   gitignored, host-local file (a credential file, an operator-placed
//   secret, an env var sourced from one). A worktree is populated from the
//   git INDEX, so such a file is NEVER carried into it: the worker's reading
//   is uninformative on every host, always — which is why a deferral is
//   neither a pass nor a failure here (it does not stall the level, and it
//   never reads as confirmed). These criteria are UNVERIFIED, exactly like
//   `acceptance_unverified` above: the orchestrator MUST verify each one
//   ITSELF, in the real checkout where the file actually exists, before that
//   item's merge gate — and MUST NOT resolve one by copying the named file
//   into the worktree, which is the secret-in-worktree exposure the
//   host-config seam (/assess A.8) exists to prevent.
//
//   Because this driver is SHARED, that obligation has THREE consumer seats,
//   one per invoking spec — keep all three in lockstep with the (deliberately
//   ungated) prompt section `hostConfigDeferralSection()` below:
//     /build -> claude/commands/build.md §4a, the level merge gate. §3h.5's
//               as-you-go fast path is explicitly INELIGIBLE for an item
//               carrying this field, precisely because it never reaches §4a.
//     /sweep -> claude/commands/sweep.md, the per-chunk merge pass: verify
//               before `gh pr merge --auto`; not-confirmed / cannot-establish
//               parks the issue instead of merging it.
//     /fix   -> claude/commands/fix.md Step 5, the ONE modal merge gate: the
//               deferral rides that same single ask as a named state caveat.
//   An ungated prompt section on a path with NO seat would let a deferral
//   auto-merge with nobody having verified it — the exact silent loss this
//   field exists to make impossible.
//
//   A parked record also carries
//   `review: { ran, skipped, mandatory_ok, routed_not_run }`
//   (temperloop#1450/#1984) — the §3e reviewer tally across every round this
//   item's build ran (the original 3e pass plus any CI-fix re-review), the
//   source for the Step 6 "reviewer outcome" summary build.md §3e promises.
//   `routed_not_run` names every routed-but-unrun reviewer, mandatory or not,
//   so the tally cannot read fully clean while a tsv-routed reviewer was
//   skipped. Absent only for a spike (kind:spike skips 3b-3h, never reviews).
//
//   That `review` object ALSO carries `residual_blocking: [{ round, max_rounds,
//   findings }]` (temperloop#1970) — present ONLY when a review round hit the
//   §3e convergence bound: HIGH findings that were CARRIED into the PR body's
//   `## Review notes` instead of escalating `review-blocking` for yet another
//   build-review round-trip. It is the bound's per-run execution signal, and it
//   marks an item a human should read the review notes on before merging; it is
//   NOT a failure (the gates, the activation gate and CI all still passed) and
//   it never stalls the level. Omitted entirely when no round hit the bound.
//
//   The workflow NEVER writes the plan note (race-safety: the orchestrator
//   serializes all plan-note writeback at the level boundary). It only RETURNS
//   what to write. Escalations leave the worktree INTACT (the orchestrator
//   re-drives them); parked items' worktree removal is the orchestrator's job
//   at the boundary too. The workflow removes no worktrees.
// =============================================================================

// `meta` MUST be a PURE literal — no vars, calls, or spreads (runtime co — see build-level.design-notes.md#meta-must-be-a-pure-literal-no-vars-calls-or-spreads-runtime
export const meta = {
  name: 'build-level',
  description:
    'Drives one invocation\'s worth of items — a /build dependency level, a /fix single-item level, or a /sweep chunk — through claim, isolated-worktree build, the acceptance gate, PR open, and CI watch.',
  version: '1.0.0',
};

// -----------------------------------------------------------------------------
// THE HAND-OFF CAPABILITY DECLARATION (temperloop#2018)
// -----------------------------------------------------------------------------
//
// Every key below is a top-level `input.*` key THIS COPY of the engine reads.
// The orchestrator->engine hand-off is deliberately ADDITIVE — an absent key
// falls back to an in-file default, so a new key can never regress an
// un-migrated caller (see the `machineryBinDir`, `principlesSummaries` and
// `reviewerRoutingTsv` comments below, which each say so in their own words).
// That property is correct and is NOT changed here. Its cost is that the
// converse is silent too: a STALE installed engine simply ignores a key a
// current orchestrator passes, and neither side says anything. Live case:
// an installed copy 18 days behind had zero `reviewerRoutingTsv` support, so
// following the driver spec literally dropped the key and fell back to the
// very agent relay the run was fixing.
//
// This list is what makes that DETECTABLE. It is read TEXTUALLY — never by
// importing this module, which cannot be imported at all outside the Workflow
// runtime (the `args` reference below throws ReferenceError) — by
// `workflows/scripts/build/handoff-capability.sh`, which a driver runs at
// Step 0 against the engine path it is about to invoke. That is why the
// sentinel comments are load-bearing and why the list is a flat array of
// single-quoted literals: the probe must work against ANY copy of this file,
// including a consuming repo's older VENDORED one, with no repo checkout to
// diff against and no Node available.
//
// KEEPING IT HONEST. A declaration that drifts from what the code actually
// reads would be a second list to maintain, so it is not maintained by hand:
// `workflows/scripts/build/tests/test_handoff_capability.sh` asserts SET
// EQUALITY between this block and every `input.<key>` occurrence in this file
// — add a key read without declaring it (or declare one nothing reads) and
// `make test-build` goes red.
//
// KNOWN BOUNDARY, stated rather than implied: this declares TOP-LEVEL keys
// only. Nested per-item fields (`items[].activation`, `items[].dependsOn`)
// are a real hand-off surface with the same drop-silently property — the
// `activation` block's own absence was temperloop#1219 — and are NOT covered
// by this declaration. The probe reports what it covers; it never implies
// more.
//
// CONVERGENCE WITH temperloop#2024 (the hand-off key REGISTRY + author-side
// lint): the same key set seen from the other side — #2024 asks "did the
// author wire this new key into all three drivers", this block answers "does
// THIS engine understand this key". This block is the per-ENGINE half and
// must stay in the file (a vendored copy travels alone); #2024's registry is
// the per-REPO half and adds the authoring columns (which drivers wire a key,
// since-version, owner). They converge by DERIVATION, not duplication: the
// registry's lint reads this declaration via `handoff-capability.sh declared`
// and asserts the two agree, exactly as the test above already does for the
// code. Do not create a second hand-maintained list.
//
// NOT `export`ed, deliberately. Nothing imports this — the probe reads it as
// TEXT — and `export const meta` is the ONE export the offline harness
// (workflows/scripts/build/tests/test_workflow.sh) strips before wrapping this
// file's body in an AsyncFunction, so a second top-level `export` is a
// SyntaxError there. A plain `const` runs identically in the Workflow runtime
// and in the harness.
//
// HANDOFF-CAPABILITIES-BEGIN (machine-parsed — workflows/scripts/build/handoff-capability.sh)
const inputCapabilities = [
  'board',
  'claimCmd',
  // temperloop#2080 — the dual-build descriptor { tier, baseline, candidat — see build-level.design-notes.md#temperloop-2080-the-dual-build-descriptor-tier-baseline-cand
  'dualBuild',
  'gateSliceSecs',
  'items',
  // temperloop#2083 — the operator's answer to a `level-pick` escalation
  // { verdict, arm?, items? }. Absent on a fresh level; on a continuation it is
  // what lets the pick route past the calibration gate. An engine without it
  // ignores the key and HOLDS the level for a confirm that can never arrive —
  // a visible stall, not a silent auto-merge, which is the safe staleness
  // direction for a key that gates merges.
  'levelPick',
  'machineryAgentType',
  'machineryBatchModel',
  'machineryBinDir',
  'machinerySoloModel',
  'machineryStepCeilingSecs',
  'machineryStepSlowSecs',
  'onlySlugs',
  'ownerRepo',
  'planLink',
  'principlesDefaultRepo',
  'principlesSummaries',
  'repoRoot',
  'requireDiscriminationEvidence',
  'reviewAgentCeilingSecs',
  'reviewAgentSlowSecs',
  'reviewBlockingMaxRounds',
  'reviewerRoutingTsv',
  'verdicts',
  'workerEvidenceMaxWords',
  'workerSummaryMaxWords',
];
// HANDOFF-CAPABILITIES-END

// `args` arrives from the Workflow tool as a JSON STRING, not a parsed o — see build-level.design-notes.md#args-arrives-from-the-workflow-tool-as-a-json-string-no
const input = typeof args === 'string' ? JSON.parse(args) : (args ?? {});

// Schemas — see build-level.design-notes.md#schemas

// SPINE_OUTCOME_SCHEMA — one permissive object keyed on `outcome` (the u — see build-level.design-notes.md#spine-outcome-schema-one-permissive-object-keyed-on-outcome-
const SPINE_OUTCOME_SCHEMA = {
  type: 'object',
  required: ['outcome'],
  additionalProperties: true,
  properties: {
    outcome: {
      type: 'string',
      // The union of the machinery's closed outcome sets (worktree / pr / ci-p — see build-level.design-notes.md#the-union-of-the-machinery-s-closed-outcome-sets-worktr
      enum: [
        'CREATED', 'REMOVED', 'NOT_FOUND', 'PRUNED', 'SKIPPED_FRESH', 'SKIPPED_DIRTY', 'SKIPPED_UNMERGED',
        'SCAN_CLEAN', 'SCAN_BLOCKED',
        'BASE_CURRENT', 'BASE_STALE',
        'REBASED', 'REBASE_CONFLICT', 'DIRTY_WORKTREE',
        // PUSHED_UNWATCHED (temperloop#1688): the push LANDED, but on a ref no — see build-level.design-notes.md#pushed-unwatched-temperloop-1688-the-push-landed-but-on-a-re
        'PUSHED', 'PUSHED_UNWATCHED', 'PUSH_REJECTED',
        'PR_OPENED', 'EXISTS',
        'CI_GREEN', 'CI_FAILED', 'NO_CI', 'TIMEOUT',
        // The 3e.5 acceptance gate. GATE_SLICE / GATE_TIMEOUT are temperloop#102 — see build-level.design-notes.md#the-3e-5-acceptance-gate-gate-slice-gate-timeout-are-temperl
        'GATE_PASS', 'GATE_FAIL', 'GATE_ABSENT', 'GATE_SLICE', 'GATE_TIMEOUT',
        // The §3e.5 PRE-gate freshness/rebase step (temperloop#1937): brings — see build-level.design-notes.md#the-3e-5-pre-gate-freshness-rebase-step-temperloop-1937-brin
        'FRESHNESS_NO_GATE', 'FRESHNESS_CURRENT', 'FRESHNESS_REBASED', 'FRESHNESS_DIRTY',
        'FRESHNESS_CONFLICT', 'FRESHNESS_REBASE_ERROR',
        'FRESHNESS_ERROR', 'FRESHNESS_TIMEOUT', 'FRESHNESS_TIMEOUT_PROBE', 'FRESHNESS_TIMEOUT_PROBE_ERROR',
        // The 3e.6 class-A activation gate (temperloop#1219). ACTIVATION_PASS / — see build-level.design-notes.md#the-3e-6-class-a-activation-gate-temperloop-1219-activation-
        'ACTIVATION_PASS', 'ACTIVATION_FAIL', 'ACTIVATION_TIMEOUT',
        'ACTIVATION_CONTROL_DISCRIMINATES', 'ACTIVATION_CONTROL_VACUOUS', 'ACTIVATION_CONTROL_ERROR',
        // The 3e pre-push review's diff/routing-data fetch (temperloop#1430). — see build-level.design-notes.md#the-3e-pre-push-review-s-diff-routing-data-fetch-temperloop-
        'REVIEW_DIFF',
        // The 3c already-fixed continuation probe (temperloop#2137). THREE
        // closed outcomes, and the asymmetry between them IS the design: only
        // ALREADY_FIXED skips a worker spawn, so it is the ONLY one the JS
        // reads as a skip, and it is emitted ONLY when EVERY finding location
        // was positively established to be gone from the tip.
        // NOT_ALREADY_FIXED (a named finding's line is demonstrably still on
        // the tip) and ALREADY_FIXED_UNKNOWN (the probe could not establish an
        // answer — no usable prior reviewed SHA, a file unreadable at either
        // revision, a fingerprint too weak to be evidence) both spawn the
        // worker exactly as today. A relay that drops or garbles this line
        // reads as none of the three, which is also a spawn — so the
        // fail-closed direction holds by construction, not by discipline.
        'ALREADY_FIXED', 'NOT_ALREADY_FIXED', 'ALREADY_FIXED_UNKNOWN',
        'CLAIMED', 'CLAIM_CONFLICT',
        // worktree.sh deps-merged (3b-0) — its outcomes were consumed at the — see build-level.design-notes.md#worktree-sh-deps-merged-3b-0-its-outcomes-were-consumed
        'DEPS_MERGED', 'DEPS_UNMERGED',
        // pr.sh recover-probe (3c lost-return recovery, temperloop#939) — the
        // staged observable-side-effect ladder: nothing / uncommitted work on
        // disk / committed / pushed / PR already open. RECOVER_DIRTY
        // (temperloop#993) splits the old stage-0 bucket: it is NOT a landed
        // stage (nothing is committed), it is the backgrounded-gate stall whose
        // cure is a foreground re-spawn on the SAME worktree.
        'RECOVER_NONE', 'RECOVER_DIRTY', 'RECOVER_COMMITTED', 'RECOVER_PUSHED', 'RECOVER_PR_OPEN',
        // The WORKFLOW-LEVEL step liveness bound (temperloop#1071). Neither of — see build-level.design-notes.md#the-workflow-level-step-liveness-bound-temperloop-1071-neith
        'STEP_TIMEOUT', 'STEP_SLOW',
        // temperloop#2020 — the post-commit work-preservation push that runs — see build-level.design-notes.md#temperloop-2020-the-post-commit-work-preservation-push-that-
        'WORK_PRESERVED', 'WORK_PRESERVE_SKIP', 'WORK_PRESERVE_FAILED',
        // The §3e REVIEW-AGENT liveness bound's timer (temperloop#2003), whose
        // executor runs workflows/scripts/build/review-wait.sh to give this
        // runtime the wall-clock tick it otherwise has none of (`Date.now()`
        // THROWS here — DESIGN NOTE 1). FOUR closed outcomes, each a pure
        // OBSERVATION the executor can make without inventing anything — the
        // distinction temperloop#2049 turned on, plus the fourth
        // temperloop#2064 had to split out of it:
        //   REVIEW_WAIT_ELAPSED       the script printed its line. It carries
        //                             `realized_secs`, the script's OWN measure
        //                             of the wait, which reviewWaitAgent()
        //                             checks against the interval it asked for.
        //   REVIEW_WAIT_TOOL_TIMEOUT  the Bash tool's own timeout killed the
        //                             command. That budget is secs+60s, so this
        //                             can only fire AFTER the interval — the
        //                             same fact, reported honestly.
        //   REVIEW_WAIT_BLOCKED       a harness PERMISSION CONTROL refused the
        //                             command outright ("<tool_use_error>Blocked:
        //                             …"). NO time passed. This is SPLIT OUT of
        //                             REVIEW_WAIT_UNAVAILABLE by temperloop#2064
        //                             because a block and a TOOL_TIMEOUT are the
        //                             same observation to the executor — "no JSON
        //                             line" — while only ONE of them (the tool
        //                             timeout) is the PERMISSIVE arm. Naming the
        //                             block is what lets reviewWaitAgent() refuse
        //                             to let a refusal land on that arm.
        //   REVIEW_WAIT_UNAVAILABLE   the command never ran to completion for any
        //                             OTHER reason (it errored; the helper was
        //                             missing). NO time passed either, so the
        //                             caller FAILS OPEN on both.
        // None of them says anything whatsoever about the review being bounded.
        'REVIEW_WAIT_ELAPSED', 'REVIEW_WAIT_TOOL_TIMEOUT', 'REVIEW_WAIT_BLOCKED',
        'REVIEW_WAIT_UNAVAILABLE',
        // temperloop#2065 "worker-cost-capture" — the per-item WORKER COST — see build-level.design-notes.md#temperloop-2065-worker-cost-capture-the-per-item-worker-cost
        'WORKER_CLOCK', 'WORKER_USAGE',
        'ERROR',
      ],
    },
    // Common passthrough fields the machinery emits (any subset, depending on cmd).
    // (recover-probe adds commits_ahead / pushed / remote_sha / dirty /
    // dirty_files / verification_surface_present; `additionalProperties: true`
    // already admits them, and the ones the .mjs branches on are declared below.)
    path: { type: 'string' },
    commits_ahead: { type: ['number', 'string'] },
    pushed: { type: 'boolean' },
    remote_sha: { type: 'string' },
    // temperloop#993 — uncommitted work on disk at the probe (the stall shape).
    dirty: { type: 'boolean' },
    dirty_files: { type: ['number', 'string'] },
    verification_surface_present: { type: 'boolean' },
    branch: { type: 'string' },
    base: { type: 'string' },
    sha: { type: 'string' },
    pr_number: { type: ['number', 'string'] },
    url: { type: 'string' },
    pr: { type: ['number', 'string'] },
    merge_base: { type: 'string' },
    tip: { type: 'string' },
    waited: { type: ['number', 'string'] },
    // temperloop#2049 — the §3e timer's own MEASURED wait, emitted by — see build-level.design-notes.md#temperloop-2049-the-3e-timer-s-own-measured-wait-emitted-by
    secs: { type: ['number', 'string'] },
    realized_secs: { type: ['number', 'string'] },
    // temperloop#2064 — the harness's OWN words when it REFUSED the timer — see build-level.design-notes.md#temperloop-2064-the-harness-s-own-words-when-it-refused-the-
    refusal_text: { type: 'string' },
    // temperloop#2065 — worker-usage.sh's WORKER_CLOCK/WORKER_USAGE fields. — see build-level.design-notes.md#temperloop-2065-worker-usage-sh-s-worker-clock-worker-usage-
    epoch_s: { type: ['number', 'string'] },
    usage_source: { type: 'string' },
    input_tokens: { type: ['number', 'null'] },
    output_tokens: { type: ['number', 'null'] },
    error: { type: 'string' },
    matches: { type: 'array', items: { type: 'string' } },
    failed_run_ids: { type: 'array', items: { type: ['number', 'string'] } },
    // free-form detail the executor may pass through (e.g. gate output tail)
    detail: { type: 'string' },
    // temperloop#1937 pre-gate freshness passthrough — the two SHAs a — see build-level.design-notes.md#temperloop-1937-pre-gate-freshness-passthrough-the-two-
    worktree_base: { type: 'string' },
    main: { type: 'string' },
    conflict_files: { type: 'array', items: { type: 'string' } },
    disposition: { type: 'string' },
    // round 2 (temperloop#1937): FRESHNESS_DIRTY's own file list (distinct
    // field from `dirty_files`, which elsewhere in this schema is a COUNT —
    // see recover-probe's passthrough above), and the timeout-probe's two
    // booleans.
    dirty_paths: { type: 'array', items: { type: 'string' } },
    rebase_in_progress: { type: 'boolean' },
    aborted: { type: 'boolean' },
    // 3e.6 activation-gate passthrough (temperloop#1219): the `proof:` — see build-level.design-notes.md#3e-6-activation-gate-passthrough-temperloop-1219-the-pr
    exitCode: { type: ['number', 'string'] },
    // REVIEW_DIFF passthrough (temperloop#1430) — the changed-file list (rep — see build-level.design-notes.md#review-diff-passthrough-temperloop-1430-the-changed-fil
    files: { type: 'array', items: { type: 'string' } },
    // temperloop#2129: the files that changed between `review_prior_sha` and
    // this round's HEAD — the CONTINUATION DELTA, narrower than `files` above
    // (which is the whole branch diff against origin/<default> and stays the
    // routing input). reviewCarryForward() reads it to decide which routed
    // seats a continuation round must actually re-spawn. Declared here rather
    // than left to `additionalProperties` for the same reason
    // `review_prior_sha` is: the driver branches on it. Empty array whenever
    // there is no usable prior sha, which the reader treats as "carry nobody".
    files_since_prior: { type: 'array', items: { type: 'string' } },
    // temperloop#2020: the routing table's DATA ROWS as an array of strings — see build-level.design-notes.md#temperloop-2020-the-routing-table-s-data-rows-as-an-array-of
    tsv_lines: { type: 'array', items: { type: 'string' } },
    // LEGACY (pre-#2020), still accepted so an un-migrated caller or a — see build-level.design-notes.md#legacy-pre-2020-still-accepted-so-an-un-migrated-caller
    tsv: { type: 'string' },
    // temperloop#1976: the tsv's own non-comment row count, computed by — see build-level.design-notes.md#temperloop-1976-the-tsv-s-own-non-comment-row-count-com
    tsv_rows: { type: ['number', 'string'] },
    // temperloop#1982: the tsv's own content checksum (tsvChecksum() below,
    // computed by reviewDiffCmd off the worktree file itself), independently
    // recomputable client-side from the RECEIVED `tsv` string with no hashing
    // primitive — closes exactly the same-length-garble gap tsv_rows alone
    // cannot (see reviewDiffTsvGap's comment for the observed case this
    // catches, temperloop#1978 round 4).
    tsv_checksum: { type: ['number', 'string'] },
    // temperloop#1970: how many §3e review rounds this worktree has ALREADY — see build-level.design-notes.md#temperloop-1970-how-many-3e-review-rounds-this-worktree-has-
    review_rounds: { type: ['number', 'string'] },
    // temperloop#2127: the SHA that was HEAD when this worktree's PRIOR §3e
    // round ran, read (and then, on the bumping call, re-written to the
    // CURRENT HEAD) by reviewDiffCmd from a marker kept beside
    // build-review-rounds — same durability contract, same worktree git dir.
    // Empty string on a fresh worktree's first round (nothing to carry) or
    // when the marker is absent/corrupted (fails soft, never a hard error).
    // runReviewers() branches on it to build a continuation reviewer's
    // `<prior-sha>..HEAD` diff instruction, so it is declared here rather
    // than left to `additionalProperties`.
    review_prior_sha: { type: 'string' },
    // 3e.5 sliced-gate fields (temperloop#1021). resumeAt — the 0-based gate — see build-level.design-notes.md#3e-5-sliced-gate-fields-temperloop-1021-resumeat-the-0-
    resumeAt: { type: ['number', 'string'] },
    failed: { type: ['number', 'string'] },
    // `'null'` IS LOAD-BEARING HERE, not defensive padding (temperloop#1698, — see build-level.design-notes.md#null-is-load-bearing-here-not-defensive-padding-temperloop-1
    elapsedSecs: { type: ['number', 'string', 'null'] },
    budgetSecs: { type: ['number', 'string'] },
    // temperloop#2094: the gate slice's own exit status. It is a FACT the — see build-level.design-notes.md#temperloop-2094-the-gate-slice-s-own-exit-status-it-is-a-fac
    rc: { type: ['number', 'string'] },
    // temperloop#1071 step-liveness fields, carried by STEP_TIMEOUT / STEP_S — see build-level.design-notes.md#temperloop-1071-step-liveness-fields-carried-by-step-ti
    step: { type: 'string' },
    // temperloop#1698 — these three are the NON-canonical (wire) spelling: t — see build-level.design-notes.md#temperloop-1698-these-three-are-the-non-canonical-wire-spell
    ceiling_secs: { type: ['number', 'string'] },
    elapsed_secs: { type: ['number', 'string'] },
    slow_secs: { type: ['number', 'string'] },
    ceilingSecs: { type: ['number', 'string'] },
    slowSecs: { type: ['number', 'string'] },
    // temperloop#865 — the WORKER's own scoped-gate sentinel, classified by  — see build-level.design-notes.md#temperloop-865-the-worker-s-own-scoped-gate-sentinel-cl
    workerGate: { type: 'string' },
  },
};

// STEP_OUTCOME_SCHEMA — one element of a BATCH's results array (temperlo — see build-level.design-notes.md#step-outcome-schema-one-element-of-a-batch-s-results-array-t
const STEP_OUTCOME_SCHEMA = {
  type: 'object',
  required: [],
  additionalProperties: true,
  properties: {
    ...SPINE_OUTCOME_SCHEMA.properties,
    mergeable: { type: 'string' },
    mergeStateStatus: { type: 'string' },
  },
};

// SPINE_BATCH_SCHEMA — the batched executor's return: the ordered array  — see build-level.design-notes.md#spine-batch-schema-the-batched-executor-s-return-the-or
const SPINE_BATCH_SCHEMA = {
  type: 'object',
  required: ['results'],
  additionalProperties: true,
  properties: {
    results: { type: 'array', items: STEP_OUTCOME_SCHEMA },
  },
};

// WORKER_VERDICT_SCHEMA — matches build.md §3c's return contract. The — see build-level.design-notes.md#worker-verdict-schema-matches-build-md-3c-s-return-contract-
const WORKER_VERDICT_SCHEMA = {
  type: 'object',
  required: ['status'],
  additionalProperties: true,
  properties: {
    status: { type: 'string', enum: ['done', 'blocked', 'design-fork', 'failed'] },
    summary: {
      type: 'string',
      description:
        'What changed and why it satisfies the item. Outcome only — never a narration of how you got there (what you read, what you ruled out, what you tried first). Word-bounded; see the prompt\'s "Output shape" section. Detail belongs in the verification-surface FILE, not here.',
    },
    acceptance_results: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: true,
        properties: {
          criterion: {
            type: 'string',
            description: 'The acceptance bullet, verbatim — quoted, never re-worded or summarized.',
          },
          passed: { type: 'boolean' },
          evidence: {
            type: 'string',
            description:
              'A POINTER to where the criterion is verifiable: file:line, test name, or command + its verdict. Not the argument for it — that belongs in the verification-surface FILE. Word-bounded; see the prompt\'s "Output shape" section.',
          },
          discrimination_evidence: {
            type: 'string',
            description:
              'Proof this criterion\'s own check can actually FAIL, not just that it currently passes: which mechanism you removed or broke, that the suite went RED without it, and that restoring it went GREEN. Required whenever the run\'s prompt carries the "Discrimination evidence" section (temperloop#1319; today: /build only — see REQUIRE_DISCRIMINATION_EVIDENCE); omit only when this criterion genuinely has no test to discriminate. Word-bounded; see the prompt\'s "Output shape" section.',
          },
          deferred_host_config: {
            type: 'string',
            description:
              'DEFERRAL MARKER (temperloop#1182): set this ONLY when the criterion turns on a gitignored, host-local file a worktree structurally never contains (a credential file, an operator-placed secret, an env var sourced from one), and name that file/env var here. Pair it with `passed: false` — you did not confirm it. The driver then treats the criterion as DEFERRED: neither a pass nor a failure, so it does not stall the level, and the orchestrating session verifies it parent-side in the real checkout. Never set it to route around a criterion you simply could not meet, and never copy the named file into the worktree.',
          },
        },
      },
    },
    commits: { type: 'array', items: { type: 'string' } },
    verification_surface_path: { type: 'string' },
    questions: {
      type: 'array',
      items: { type: 'string' },
      description: 'One self-contained question per entry — the missing FACT you need, stated as a question. No preamble, no recap of what you already did.',
    },
    design_fork: {
      type: 'object',
      additionalProperties: true,
      properties: {
        decision: { type: 'string' },
        options: {
          type: 'array',
          items: {
            type: 'object',
            additionalProperties: true,
            properties: { label: { type: 'string' }, tradeoff: { type: 'string' } },
          },
        },
        recommendation: { type: 'string' },
        evidence: { type: 'string' },
      },
    },
    failure_reason: {
      type: 'string',
      description: 'Why the item cannot be completed AS SPECIFIED — the blocking fact, not a transcript of the attempt. Word-bounded; see the prompt\'s "Output shape" section.',
    },
  },
};

// -----------------------------------------------------------------------------
// RETRY-LOOP INVENTORY (temperloop#976)
// -----------------------------------------------------------------------------
// Every loop in this file that can RE-ATTEMPT something, with its hard c — see build-level.design-notes-4.md#every-loop-in-this-file-that-can-re-attempt-something-with-i
//
// -----------------------------------------------------------------------------
// Tunables (no Date.now()/Math.random() — those THROW in the runtime; all
// budgets are expressed as counts/seconds the executor agent enforces itself).
// The Workflow runtime has no shell, so these stay named constants here rather
// than build.config.sh settings — the same structural constraint that forces
// machinerySoloModel/machineryBatchModel through build.md's Step-0 hand-off.
// A tunable that genuinely needs to be operator-configurable rides that SAME
// Step-0 hand-off (an `input.*` key with an in-file default), never a config
// read from inside this file: GATE_SLICE_SECS below is the worked example.
// -----------------------------------------------------------------------------
const CI_POLL_SLICE_SECS = 240;   // one ci-poll.sh slice; < the ~10-min agent Bash cap
const CI_POLL_TOTAL_SECS = 3600;  // total wall budget across slices before escalating
const CI_FAIL_RETRY_BUDGET = 1;   // re-spawn+force-push+re-poll attempts on CI_FAILED

// --- Batched-machinery budgets (temperloop#942) ------------------------------
// AGENT_BASH_CAP_MS — the executor agent's foreground Bash ceiling (== the Bash
// tool's own 600_000ms maximum). NOTHING this file emits may ask a single Bash
// invocation to run longer; every batch timeout below is clamped to it.
const AGENT_BASH_CAP_MS = 600_000;
// BATCH_BASH_TIMEOUT_MS — the FAST batches (prelude, pr-batch). Every st — see build-level.design-notes.md#batch-bash-timeout-ms-the-fast-batches-prelude-pr-batch-ever
const BATCH_BASH_TIMEOUT_MS = 300_000;
// CI_POLL_MAX_BATCH_WALL_MS / CI_POLL_SLICES_PER_BATCH — DESIGN NOTE 2's — see build-level.design-notes.md#ci-poll-max-batch-wall-ms-ci-poll-slices-per-batch-design-no
const CI_POLL_MAX_BATCH_WALL_MS = 480_000;
const CI_POLL_SLICES_PER_BATCH = Math.max(
  1,
  Math.floor(CI_POLL_MAX_BATCH_WALL_MS / (CI_POLL_SLICE_SECS * 1000)),
);
// The ci-batch's Bash-tool timeout: its poll wall plus headroom for the — see build-level.design-notes.md#the-ci-batch-s-bash-tool-timeout-its-poll-wall-plus-hea
const CI_BATCH_BASH_TIMEOUT_MS = Math.min(
  AGENT_BASH_CAP_MS,
  CI_POLL_SLICES_PER_BATCH * CI_POLL_SLICE_SECS * 1000 + 90_000,
);

// --- 3e.5 acceptance-gate budget (temperloop#1021) ---------------------------
// HISTORY, because the shape of this block IS the fix. The gate used to carry a
// single flat Bash-tool timeout for the WHOLE quality-gates.sh suite:
// temperloop#115 raised it 120_000 -> 480_000ms when a 2-minute suite was
// SIGTERM'd mid-run and reported as GATE_FAIL on a green tree; temperloop#1021
// is the identical failure again, because the suite outgrew 480s too. A third
// raise is not available: AGENT_BASH_CAP_MS is a HARD ceiling this file cannot
// exceed, and the suite is already near it — so "raise the number" is the patch
// that is already known to decay, twice.
//
// So the budget stops being a deadline for the suite and becomes the length of
// ONE SLICE, exactly as CI_POLL_SLICE_SECS is for the CI poll (DESIGN NOTE 2).
// quality-gates.sh runs gates until its own soft budget is spent, stops CLEANLY
// BETWEEN GATES, and reports where to resume; 3e.5 loops slices until the suite
// finishes. TOTAL suite runtime is therefore unbounded by the agent's Bash cap,
// and gate-list growth can no longer manufacture a false GATE_FAIL — the decay
// path is closed structurally rather than deferred to the next raise.
//
// GATE_SLICE_SECS is a NAMED SETTING (BUILD_GATE_SLICE_SECS), handed in by the
// orchestrator at Step 0 exactly like machinerySoloModel/machineryBatchModel —
// the Workflow runtime has no shell or filesystem, so it cannot source
// build.config.sh itself (DESIGN NOTE 1). `||`, not `??`, for the same
// empty-string-safety reason documented at the model settings: an orchestrator
// that resolves an unset setting to "" must land on the in-file default, not
// pass a literal empty string through.
const GATE_SLICE_SECS_DEFAULT = 300;
// GATE_SLICE_OVERRUN_MS — the budget is checked only BETWEEN gates, so a — see build-level.design-notes.md#gate-slice-overrun-ms-the-budget-is-checked-only-between-gat
const GATE_SLICE_OVERRUN_MS = 240_000;
// Clamp: a slice budget large enough that budget+overrun would exceed th — see build-level.design-notes.md#clamp-a-slice-budget-large-enough-that-budget-overrun-w
const GATE_SLICE_SECS_MAX = Math.floor((AGENT_BASH_CAP_MS - GATE_SLICE_OVERRUN_MS) / 1000);
const GATE_SLICE_SECS = Math.max(
  30,
  Math.min(
    GATE_SLICE_SECS_MAX,
    Number(input.gateSliceSecs) > 0 ? Math.floor(Number(input.gateSliceSecs)) : GATE_SLICE_SECS_DEFAULT,
  ),
);
// --- §3e review-blocking convergence bound (temperloop#1970) -----------------
// THE FAILURE THIS BOUNDS. §3e is a cold, one-shot advisory pass, and a HIGH
// finding escalates `review-blocking` → the orchestrator loops the item back to
// 3c → the worker fixes it → a FRESH reviewer reads the now-LARGER diff. Nothing
// bounded that loop. Measured on one live item (temperloop#1938 L1, item
// `interview-command-spec`/#1962): FIVE consecutive §3e passes, four DISTINCT
// HIGHs, ZERO repeats, ~2h45m and ~1.05M subagent tokens before convergence —
// and pass 4's HIGH was CAUSED by pass 3's directed fix, while the reviewed spec
// grew 447 → 635 lines across the rounds. So the loop is partly SELF-FEEDING,
// not merely serial discovery: each round enlarges the surface the next one
// reads, and the orchestrator had to invent a stopping rule by hand at pass 5.
//
// THE OTHER HALF IS THE REVIEWER SEAT, NOT THIS BOUND. claude/agents/
// workflow-reviewer.md now instructs the seat to enumerate EVERY HIGH it can
// identify in ONE pass before it ranks or narrows; this constant is the backstop
// for when that still does not converge. Deliberately NOT a model-tier change:
// that seat is pinned `model: sonnet` by its own frontmatter, on purpose.
//
// WHAT IT DOES, PRECISELY. `REVIEW_BLOCKING_MAX_ROUNDS` caps the number of
// review ROUNDS one item's worktree may spend. On the round that reaches the
// cap, a blocking finding no longer escalates: the item continues to 3e.5/3f
// with the findings carried in the return value — into the PR body's
// `## Review notes` (the same reviewBodySuffix() render every round uses) and
// into the parked record's `review.residual_blocking` tally — so the human at
// the merge gate reads exactly what the reviewer said. ADVISORY, NEVER A
// SUPPRESSION: what stops is the automatic build-review-build loop, not the
// findings. An item that converges in fewer rounds is byte-identical to
// pre-#1970 behaviour, which is why the default preserves today's path for
// everything under the bound.
//
// ROUND COUNTING IS DURABLE, because the loop spans PROCESSES: each
// review-blocking escalation returns to the orchestrator, which re-invokes this
// workflow. The Workflow runtime has no filesystem (DESIGN NOTE 1), so the
// counter lives in the worktree's own GIT DIR (never the working tree — it must
// not show up in `git status`, in a `--scoped` gate's untracked-path resolution,
// or in a coverage manifest) and is read+bumped by reviewDiffCmd in the SAME
// machinery call §3e already makes: zero extra agent spawns. A continuation
// re-uses the worktree (3b is skipped), so the count survives exactly the loop
// it bounds; a fresh item gets a fresh worktree and therefore a fresh count.
// The CI-fix re-review (§3g) shares the counter deliberately — it is the same
// item's review budget, and counting it is the conservative direction.
//
// REVIEW_BLOCKING_MAX_ROUNDS is a NAMED SETTING (BUILD_REVIEW_BLOCKING_MAX_ROUNDS),
// handed in by the orchestrator at Step 0 exactly like GATE_SLICE_SECS above —
// the Workflow runtime cannot source build.config.sh itself. A non-positive or
// unparseable value falls back to the in-file default rather than disabling the
// bound, and the floor of 1 means no caller can configure the loop back to
// unbounded.
const REVIEW_BLOCKING_MAX_ROUNDS_DEFAULT = 3;
const REVIEW_BLOCKING_MAX_ROUNDS = Math.max(
  1,
  Number(input.reviewBlockingMaxRounds) > 0
    ? Math.floor(Number(input.reviewBlockingMaxRounds))
    : REVIEW_BLOCKING_MAX_ROUNDS_DEFAULT,
);
// --- §3e review-agent LIVENESS BOUND (temperloop#2003) -----------------------
// THE FAILURE THIS BOUNDS — the sibling of temperloop#1071 one layer up. — see build-level.design-notes-5.md#the-failure-this-bounds-the-sibling-of-temperloop-1071-one-l
const REVIEW_AGENT_CEILING_SECS_DEFAULT = 1200;
const REVIEW_AGENT_SLOW_SECS_DEFAULT = 300;
// FLOOR — a ceiling below the longest LEGITIMATE wait would manufacture — see build-level.design-notes.md#floor-a-ceiling-below-the-longest-legitimate-wait-would-manu
const REVIEW_AGENT_CEILING_FLOOR_SECS = Math.max(CI_POLL_SLICE_SECS, GATE_SLICE_SECS);
const REVIEW_AGENT_CEILING_SECS = Math.max(
  REVIEW_AGENT_CEILING_FLOOR_SECS,
  Number(input.reviewAgentCeilingSecs) > 0
    ? Math.floor(Number(input.reviewAgentCeilingSecs))
    : REVIEW_AGENT_CEILING_SECS_DEFAULT,
);
// The SLOW threshold is advisory, so it only needs to be sane: non-negat — see build-level.design-notes.md#the-slow-threshold-is-advisory-so-it-only-needs-to-be-sane-n
const reviewSlowInput = input.reviewAgentSlowSecs;
const reviewSlowGiven =
  reviewSlowInput !== undefined && reviewSlowInput !== null && String(reviewSlowInput).trim() !== '';
const REVIEW_AGENT_SLOW_SECS = Math.min(
  REVIEW_AGENT_CEILING_SECS - 1,
  reviewSlowGiven && Number(reviewSlowInput) >= 0
    ? Math.floor(Number(reviewSlowInput))
    : REVIEW_AGENT_SLOW_SECS_DEFAULT,
);
// The longest single `sleep` one timer executor may hold: the Bash tool' — see build-level.design-notes.md#the-longest-single-sleep-one-timer-executor-may-hold-the-bas
const REVIEW_WAIT_SLICE_MAX_SECS = Math.floor((AGENT_BASH_CAP_MS - 60_000) / 1000);
// REVIEW_WAIT_REFUSAL_RE — the harness's OWN words for "I refused this command"
// (temperloop#2064). Matched against whatever text the timer executor relays
// (`refusal_text`, `error`, `detail`) BEFORE its own outcome label is read.
//
// WHY TEXT RATHER THAN THE EXECUTOR'S LABEL. A permission BLOCK and a Bash-tool
// TIMEOUT kill are the SAME observation to the executor — no JSON line came
// back — and exactly one of the two arms is PERMISSIVE: a tool timeout is
// honoured as elapsed, because its budget is secs+60s and can only fire AFTER
// the interval. So the executor is being asked to tell apart two states it
// cannot see, with a coin flip that lands, half the time, on "the ceiling
// expired". temperloop#2064 measured that: three slices asking 300s/540s/360s
// returned in 11s/11s/17s, a 1200s ceiling realized in ~41s, and a
// docs-reviewer that finished normally at 98s was discarded and reported as
// "unavailable". A refusal, unlike an elapse, leaves EVIDENCE the executor can
// only relay and never invent — the harness's own refusal text — so that is
// what the classification reads (kernel principle 5: counter a known AI failure
// mode STRUCTURALLY, not with a sharper instruction).
//
// FAIL-CLOSED DIRECTION. A match means "no usable timer", which makes the
// caller fail OPEN on the fanout (wait unbounded, the pre-#2003 behaviour) and
// say so. So a FALSE positive costs latency on a pathological hang; a false
// NEGATIVE discards finished reviews and reports a gate that never ran. The
// regex is therefore deliberately generous.
const REVIEW_WAIT_REFUSAL_RE =
  /<tool_use_error>|\bblocked\b|\bpermission (?:control|rule|denied)|\brefused\b|\bdenied\b|\bnot permitted\b/i;
// reviewWaitRefusalText — the first line of the refusal a timer result c — see build-level.design-notes.md#reviewwaitrefusaltext-the-first-line-of-the-refusal-a-t
function reviewWaitRefusalText(out) {
  for (const field of ['refusal_text', 'error', 'detail']) {
    const v = out && out[field];
    if (typeof v !== 'string' || v.trim() === '') continue;
    if (!REVIEW_WAIT_REFUSAL_RE.test(v)) continue;
    return v.split('\n')[0].trim().slice(0, 160);
  }
  return null;
}
// reviewWaitSlices() — the wait, expressed as the sequence of sleeps tha — see build-level.design-notes.md#reviewwaitslices-the-wait-expressed-as-the-sequence-of-sleep
function reviewWaitSlices() {
  const marks = [];
  if (REVIEW_AGENT_SLOW_SECS > 0 && REVIEW_AGENT_SLOW_SECS < REVIEW_AGENT_CEILING_SECS) {
    marks.push(REVIEW_AGENT_SLOW_SECS);
  }
  marks.push(REVIEW_AGENT_CEILING_SECS);
  const slices = [];
  let at = 0;
  for (const mark of marks) {
    let left = mark - at;
    while (left > 0) {
      const slice = Math.min(left, REVIEW_WAIT_SLICE_MAX_SECS);
      slices.push(slice);
      left -= slice;
    }
    at = mark;
  }
  return slices;
}
// The gate executor's Bash-tool timeout — derived, never typed twice. Ke — see build-level.design-notes.md#the-gate-executor-s-bash-tool-timeout-derived-never-typ
const GATE_BASH_TIMEOUT_MS = Math.min(
  AGENT_BASH_CAP_MS,
  GATE_SLICE_SECS * 1000 + GATE_SLICE_OVERRUN_MS,
);
// --- Machinery-step LIVENESS BOUND (temperloop#1071) -------------------------
// THE FAILURE THIS BOUNDS. A `pr-batch` machinery agent ran 35,362,333ms — see build-level.design-notes.md#the-failure-this-bounds-a-pr-batch-machinery-agent-ran-35-36
const STEP_CEILING_SECS_DEFAULT = 900;
const STEP_SLOW_SECS_DEFAULT = 300;
// FLOOR — a ceiling below the longest LEGITIMATE single step would manuf — see build-level.design-notes.md#floor-a-ceiling-below-the-longest-legitimate-single-step-wou
const STEP_CEILING_FLOOR_SECS = Math.max(CI_POLL_SLICE_SECS, GATE_SLICE_SECS) + 300;
const STEP_CEILING_SECS = Math.max(
  STEP_CEILING_FLOOR_SECS,
  Number(input.machineryStepCeilingSecs) > 0
    ? Math.floor(Number(input.machineryStepCeilingSecs))
    : STEP_CEILING_SECS_DEFAULT,
);
// The SLOW threshold is advisory, so it only needs to be sane: non-negat — see build-level.design-notes.md#the-slow-threshold-is-advisory-so-it-only-needs-to-be-sane-n-2
const stepSlowInput = input.machineryStepSlowSecs;
const stepSlowGiven =
  stepSlowInput !== undefined && stepSlowInput !== null && String(stepSlowInput).trim() !== '';
const STEP_SLOW_SECS = Math.min(
  STEP_CEILING_SECS - 1,
  stepSlowGiven && Number(stepSlowInput) >= 0
    ? Math.floor(Number(stepSlowInput))
    : STEP_SLOW_SECS_DEFAULT,
);

// GATE_MAX_SLICES — a bound, not a target: a suite that cannot finish in — see build-level.design-notes.md#gate-max-slices-a-bound-not-a-target-a-suite-that-canno
const GATE_MAX_SLICES = 8;
// GATE_RESUME_EXTENSIONS (temperloop#2135, split from #2130) — how many — see build-level.design-notes.md#gate-resume-extensions-temperloop-2135-split-from-2130-how-m
const GATE_RESUME_EXTENSIONS = 2;
// Warn when a completed run used at least this fraction of the slice bud — see build-level.design-notes.md#warn-when-a-completed-run-used-at-least-this-fraction-o
const GATE_MARGIN_WARN_RATIO = 0.75;
// GATE_SLICE_CLAMP_NEAR_RATIO (temperloop#1650) — at/above this fraction of
// GATE_SLICE_SECS_MAX the slice budget is treated as AT its clamp, so the
// UNKNOWN-verdict remedy stops naming a raise that cannot move.
const GATE_SLICE_CLAMP_NEAR_RATIO = 0.9;
// The ordinal->name probe below is a `--list-selected` dry run, seconds of work.
const GATE_INFLIGHT_NAME_TIMEOUT_MS = 120_000;

// 3c worker return-value output-shape bounds (temperloop#1080) — see build-level.design-notes.md#3c-worker-return-value-output-shape-bounds-temperloop-1080
const WORKER_SUMMARY_MAX_WORDS_DEFAULT = 60;
const WORKER_EVIDENCE_MAX_WORDS_DEFAULT = 30;
const WORKER_SUMMARY_MAX_WORDS = Math.max(
  20,
  Number(input.workerSummaryMaxWords) > 0
    ? Math.floor(Number(input.workerSummaryMaxWords))
    : WORKER_SUMMARY_MAX_WORDS_DEFAULT,
);
const WORKER_EVIDENCE_MAX_WORDS = Math.max(
  10,
  Number(input.workerEvidenceMaxWords) > 0
    ? Math.floor(Number(input.workerEvidenceMaxWords))
    : WORKER_EVIDENCE_MAX_WORDS_DEFAULT,
);

// --- §3c test-discrimination evidence requirement (temperloop#1319) ---------
// A worker reporting `passed: true` on its own say-so is exactly the class of
// self-report this pipeline has repeatedly had to distrust — a check that
// PASSES because it can never FAIL (a mistargeted assertion, a fixture that
// never exercises the changed path) looks identical, from the returned
// verdict alone, to a check that genuinely discriminates. The fix is not more
// prose asking the worker to "verify carefully" — it is asking for the
// specific artifact that PROVES discrimination happened: which mechanism was
// removed, that the suite went red without it, that restoring it went green.
//
// Gated on a per-run input flag (`requireDiscriminationEvidence`, boolean —
// `=== true`, not `||`/`??`, since an accidentally-truthy non-boolean must
// never silently arm a requirement the caller didn't intend) rather than
// baked unconditionally into the shared workerPrompt(), on the SAME Step-0
// hand-off seam as gateSliceSecs/principlesSummaries above. workerPrompt()
// is shared by THREE callers: `/build`, `/sweep`, and `/fix`.
//
// CORRECTION (the mechanical scoping below is accurate; an earlier version of
// this comment additionally claimed /sweep and /fix structurally CANNOT carry
// real per-criterion bullets — that claim was FALSE and has been removed).
// `sweep.md`/`fix.md` both define `acceptance:` as "checkable bullets from the
// issue body", falling back to the bare-string placeholder
// `"(self-verify the issue is resolved)"` ONLY when the issue body carries
// none — and `acceptanceList()` (below) already handles the array case for
// any caller. So a real, multi-bullet acceptance array from /sweep or /fix
// DOES have exactly the per-criterion shape this requirement targets; nothing
// here makes widening to them structurally impossible.
//
// The actual reason `/build` passes `requireDiscriminationEvidence: true`
// (claude/commands/build.md Step 3 args) while `/sweep` and `/fix` omit the
// key is an OPERATIONAL SCOPE DECISION, not a structural one: temperloop#1319
// scopes this requirement to `/build` only. `/sweep` and `/fix` inherit the
// OFF default — the same caller-scoped widening `principlesSummaries`
// already establishes for a different §3c requirement — until a future item
// makes the case for extending it to them.
const REQUIRE_DISCRIMINATION_EVIDENCE = input.requireDiscriminationEvidence === true;

// --- §3c effective engineering principles (temperloop#1432) ------------------
// build.md §3c requires embedding the EFFECTIVE (kernel ∪ project) engineering
// principle set in the worker's prompt, in summary form, so the worker weighs
// its own choices against it. This file cannot resolve that itself: resolving
// it needs `claude/engineering-principles.md` (a repo FILE) merged with a
// project's `Projects/<project>/Priorities.md` § Principles (a VAULT read via
// MCP) — and the Workflow runtime has neither a filesystem nor tool access
// (DESIGN NOTE 1, same structural wall GATE_SLICE_SECS/model-tier settings hit
// above). So this rides the SAME Step-0-hand-off seam: the orchestrator
// resolves the merge ONCE PER RUN, per distinct (repo, project) pair
// (`claude/commands/build.md` § Step 1.8), and hands the RENDERED text
// straight through as `input.principlesSummaries` — a map keyed by each
// pair's `repo` string (the plan's `ownerRepo` for the default/primary pair,
// an item's own `repo:` for a cross-repo pair) — plus `input.principlesDefaultRepo`
// (== `ownerRepo`) for the items that carry no `repo:` of their own.
const PRINCIPLES_SUMMARIES =
  input.principlesSummaries && typeof input.principlesSummaries === 'object'
    ? input.principlesSummaries
    : {};
const PRINCIPLES_DEFAULT_REPO = input.principlesDefaultRepo || '';

// REVIEWER_ROUTING_TSV — temperloop#1982, the STRUCTURAL close on the relay
// defect temperloop#1976/#1995 only mitigated. `workflows/scripts/config/
// reviewer-routing.tsv` is a STATIC repo file: its content is identical on
// every run and depends on nothing the worktree computes, so routing it
// through the machinery-executor agent's verbatim-echo contract was never
// necessary — only the CHANGED-FILE list genuinely has to come from the
// worktree. Relaying it anyway put a multi-line tab-delimited table in front
// of an LLM asked to reproduce it byte-for-byte, and it was mangled in three
// distinct ways across eight observed occurrences: silently omitted; replaced
// by an English sentence *describing* the table; and (2026-09-13) returned
// DOUBLE-JSON-ENCODED — surrounding quotes plus literal two-character \t/\n
// sequences instead of real tabs and newlines, which parses as one row rather
// than eleven. Note what survived every one of those: `tsv_rows` and
// `tsv_checksum`, both small integers, were correct in all three shapes. The
// string field is the unreliable part, not the step.
//
// So this rides the SAME Step-0-hand-off seam as principlesSummaries above
// (DESIGN NOTE 1 — the Workflow runtime has no filesystem access, the
// orchestrator does): the orchestrator reads the file ONCE and hands the text
// through as `input.reviewerRoutingTsv`. When present it is authoritative and
// the agent's copy is never consulted, removing the agent from this data's
// path entirely rather than adding a fourth guard behind it. Absent (an older
// orchestrator, or a consuming-repo caller that has not wired the hand-off)
// the previous relay + retry + row/checksum-gap path stands unchanged, so
// this is additive and cannot regress an un-migrated caller.
const REVIEWER_ROUTING_TSV =
  typeof input.reviewerRoutingTsv === 'string' && input.reviewerRoutingTsv.trim()
    ? input.reviewerRoutingTsv
    : '';

// PRINCIPLES_KERNEL_FALLBACK — last-resort degradation, used ONLY when the
// orchestrator supplied no `principlesSummaries` at all this run (an older
// orchestrator, or a consuming-repo caller that has not wired the hand-off —
// all three first-party callers of this file's shared `workerPrompt()`,
// build.md/sweep.md/fix.md, resolve and pass it; #1432 wired /build,
// temperloop#1460 wired the other two). A static snapshot of `claude/engineering-principles.md`'s
// kernel-only principle NAMES — this runtime cannot read that file itself to
// stay current, so a worker on the fallback path gets a legible floor (never
// a silently empty set, which from the outside would look identical to
// "principles applied") plus an explicit notice that the project extension
// was NOT applied. See principlesSection() below for the notice text.
const PRINCIPLES_KERNEL_FALLBACK = [
  '1. Every meaningful behavior tested for every state — no coverage-percentage gate [kernel]',
  '2. Quality bars strict from day one [kernel]',
  '3. Deterministic tests over recorded fixtures, never live-network [kernel]',
  '4. Verify at the human-AI seam [kernel]',
  '5. Counter AI failure modes structurally [kernel]',
  '6. Limit blast radius through boundaries [kernel]',
  '7. Advisory over enforced discipline [kernel]',
].join('\n');

// resolvePrinciplesSummary — per-item lookup: this item's own `repo:` fi — see build-level.design-notes.md#resolveprinciplessummary-per-item-lookup-this-item-s-ow
function resolvePrinciplesSummary(item) {
  const key = (item && item.repo) || PRINCIPLES_DEFAULT_REPO;
  if (key && Object.prototype.hasOwnProperty.call(PRINCIPLES_SUMMARIES, key)) {
    return { text: PRINCIPLES_SUMMARIES[key], degraded: false };
  }
  if (
    PRINCIPLES_DEFAULT_REPO &&
    Object.prototype.hasOwnProperty.call(PRINCIPLES_SUMMARIES, PRINCIPLES_DEFAULT_REPO)
  ) {
    return { text: PRINCIPLES_SUMMARIES[PRINCIPLES_DEFAULT_REPO], degraded: false };
  }
  return { text: PRINCIPLES_KERNEL_FALLBACK, degraded: true };
}

// Command-building helpers — EVERY interpolated value goes through sq(). — see build-level.design-notes.md#command-building-helpers-every-interpolated-value-goes-

// sq — POSIX-quote a value for safe shell interpolation. A spaced path MUST be
// quoted or the one-shot executor runs the wrong command (the live-probe
// finding). Numbers are coerced to string.
//
// TWO FORMS, CHOSEN BY CONTENT (temperloop#1806). The classic single-quote form
// escapes an embedded `'` via the `'\''` idiom, which is correct POSIX — and is
// exactly what killed a live item. The command text this file builds is not
// executed by this process: it is handed to an executor AGENT, whose Bash tool
// parses it first. A payload carrying escaped single quotes nests `'\''` inside
// a shell function inside a batch script, and that parser refused the whole
// command at PARSE time, before touching git:
//
//   {"outcome":"ERROR","step":"parse","error":"Shell parsing failed due to
//    deeply nested quotes. … multiple instances of '\'' embedded within a bash
//    function, creating an unresolvable quotation context …"}
//
// It is deterministic for a given item — a re-drive can never clear it, because
// the trigger is the item's own text — and it fires most readily on re-driven
// items whose notes quote reviewer findings or shell snippets, i.e. the items
// that have already cost the most work. sq() is the ONE definition behind all
// ~86 call sites, so the fix belongs here and nowhere else.
//
// So: a value with NO single quote keeps the single-quoted form, byte-identical
// to before (the overwhelming majority of call sites — paths, slugs, outcome
// globs). A value that DOES contain one is emitted DOUBLE-quoted instead, with
// the four characters that stay special inside double quotes (`"`, `\`, `$`,
// backtick) backslash-escaped. A double-quoted string may contain `'` verbatim,
// so no nesting is produced at any depth, and the round-trip is exact:
// everything else — newlines, `!` (history expansion is interactive-only),
// glob punctuation — is literal inside double quotes exactly as it is inside
// single ones. The two forms are interchangeable at every call site: each is a
// single self-contained shell word, including inside a `case` pattern (both
// quoting forms suppress glob expansion) and inside a `"$( … )"` substitution
// (which opens a fresh quoting context).
function sq(value) {
  const s = String(value);
  if (!s.includes("'")) return `'${s}'`;
  return `"${s.replace(/(["\\$`])/g, '\\$1')}"`;
}

// -----------------------------------------------------------------------------
// The step LIVENESS BOUND, compiled into the command text (temperloop#1071).
// -----------------------------------------------------------------------------
// See the STEP_CEILING_SECS block above for WHY the bound lives in the e — see build-level.design-notes-3.md#see-the-step-ceiling-secs-block-above-for-why-the-bound-live
function stepBoundPreamble(slowSecs) {
  return [
    `__lb_ceil=${STEP_CEILING_SECS}; __lb_slow=${slowSecs}`,
    '__lb() {',
    '  __lbk=$1; shift',
    '  __lbt=$(date +%s)',
    '  "$@" &',
    '  __lbp=$!',
    // Kill ORDER is load-bearing, and the obvious order is wrong. Killing th — see build-level.design-notes.md#kill-order-is-load-bearing-and-the-obvious-order-is-wrong-ki
    '  ( sleep "$__lb_ceil" 2>/dev/null; __lbc=$(pgrep -P "$__lbp" 2>/dev/null); kill -9 "$__lbp" 2>/dev/null; [ -n "$__lbc" ] && kill -9 $__lbc 2>/dev/null ) </dev/null >/dev/null 2>&1 &',
    '  __lbw=$!',
    '  wait "$__lbp" 2>/dev/null; __lbr=$?',
    '  kill "$__lbw" 2>/dev/null; wait "$__lbw" 2>/dev/null',
    '  __lbe=$(( $(date +%s) - __lbt ))',
    // Timed out iff BOTH the step died by SIGNAL and the wall clock actually — see build-level.design-notes-2.md#timed-out-iff-both-the-step-died-by-signal-and-the-wall
    '  if [ "$__lbr" -ge 128 ] && [ "$__lbe" -ge "$__lb_ceil" ]; then',
    `    printf '{"outcome":"STEP_TIMEOUT","step":"%s","ceiling_secs":%s,"elapsed_secs":%s}\\n' "$__lbk" "$__lb_ceil" "$__lbe"`,
    '    return 137',
    '  fi',
    '  if [ "$__lb_slow" -gt 0 ] && [ "$__lbe" -ge "$__lb_slow" ]; then',
    `    printf '{"outcome":"STEP_SLOW","step":"%s","elapsed_secs":%s,"slow_secs":%s,"ceiling_secs":%s}\\n' "$__lbk" "$__lbe" "$__lb_slow" "$__lb_ceil"`,
    '  fi',
    '  return "$__lbr"',
    '}',
  ].join('\n');
}

// stepFnDef — wrap a step's command text VERBATIM in a shell function, s — see build-level.design-notes-2.md#stepfndef-wrap-a-step-s-command-text-verbatim-in-a-shel
function stepFnDef(name, cmd) {
  return `${name}() {\n${cmd}\n}`;
}

// stepBoundInvoke — the call itself. `kind` is the batch step's own name — see build-level.design-notes-2.md#stepboundinvoke-the-call-itself-kind-is-the-batch-step-
function stepBoundInvoke(name, kind) {
  return `__lb ${sq(kind)} ${name}`;
}

// machineryBin — resolve a build-SPINE script (worktree.sh / pr.sh / ci- — see build-level.design-notes.md#machinerybin-resolve-a-build-spine-script-worktree-sh-pr-sh-
function machineryBin(repoRoot, name) {
  // De-obfuscated fast path (temperloop#72). When the orchestrator has already
  // resolved the build-machinery directory in its OWN shell (build.md Step 0, and
  // sweep.md/fix.md Step 0 as of temperloop#1460 — all three callers pass it) and
  // passed it as input.machineryBinDir, emit a PLAIN quoted absolute path. The
  // executed machinery command line then carries NO nested `$(readlink …)`
  // command-substitution — the very construct the auto-mode safety classifier
  // read (together with the runMachinery "run exactly" instruction) as an
  // obfuscated-command bypass, denying every push/worktree machinery step on
  // --unattended/pipeline runs. A literal path reads as an ordinary script call.
  if (typeof input.machineryBinDir === 'string' && input.machineryBinDir.length > 0) {
    return sq(input.machineryBinDir + '/' + name);
  }
  // Fallback (no pre-resolved dir — older invocations, or a consuming repo — see build-level.design-notes-2.md#fallback-no-pre-resolved-dir-older-invocations-or-a-con
  const local = sq(repoRoot + '/workflows/scripts/build');
  return '"$(d=' + local + '; ' +
    'if [ ! -d "$d" ]; then for c in ' +
    '"${FOUNDATION:-}/workflows/scripts/build" ' +
    '"$(dirname "$(readlink -f "$HOME/.claude/workflows/build-level.mjs" 2>/dev/null)" 2>/dev/null)/../../workflows/scripts/build" ' +
    '"${TEMPERLOOP_HOME:-$HOME/.local/share/temperloop}/workflows/scripts/build"; ' +
    'do [ -d "$c" ] && { d="$c"; break; }; done; fi; ' +
    "printf '%s' \"$d/" + name + '")"';
}

// Repo "owner/repo" — the orchestrator passes it in input.ownerRepo (the — see build-level.design-notes-2.md#repo-owner-repo-the-orchestrator-passes-it-in-input-own

// THE EXECUTOR AGENT TYPE — context size is the machinery agents' cost ( — see build-level.design-notes.md#the-executor-agent-type-context-size-is-the-machinery-agents
const MACHINERY_RESOLUTION_ERR = /agent\(\{agentType\}\)|agent type '[^']*' (?:not found|is denied)/;
const MACHINERY_AGENT_TYPE_DEFAULT = 'machinery-executor';
let machineryAgentType =
  typeof input.machineryAgentType === 'string' && input.machineryAgentType.length > 0
    ? input.machineryAgentType
    : MACHINERY_AGENT_TYPE_DEFAULT;

// machineryAgent — spawn a machinery executor. `promptFor(lean)` builds  — see build-level.design-notes-2.md#machineryagent-spawn-a-machinery-executor-promptfor-lea
async function machineryAgent(promptFor, opts) {
  const wanted = machineryAgentType;
  try {
    return await agent(promptFor(wanted !== 'general-purpose'), { ...opts, agentType: wanted });
  } catch (err) {
    const msg = String((err && err.message) || err);
    if (wanted === 'general-purpose' || !MACHINERY_RESOLUTION_ERR.test(msg)) throw err;
    log(`machinery executor '${wanted}' unavailable — using general-purpose (${msg})`);
    machineryAgentType = 'general-purpose';
    return await agent(promptFor(false), { ...opts, agentType: 'general-purpose' });
  }
}

// ONE MEANING, ONE NAME — the machinery-outcome key canonicalizer (tempe — see build-level.design-notes.md#one-meaning-one-name-the-machinery-outcome-key-canonicalizer
const OUTCOME_KEY_ALIASES = {
  elapsed_secs: 'elapsedSecs',
  ceiling_secs: 'ceilingSecs',
  slow_secs: 'slowSecs',
  budget_secs: 'budgetSecs',
};
function canonicalizeOutcome(o) {
  if (o == null || typeof o !== 'object') return o;
  for (const snake of Object.keys(OUTCOME_KEY_ALIASES)) {
    const camel = OUTCOME_KEY_ALIASES[snake];
    if (o[camel] === undefined && o[snake] !== undefined) o[camel] = o[snake];
  }
  return o;
}

// The STRICT numeric read this canonicalization needs — "the value, or n — see build-level.design-notes.md#the-strict-numeric-read-this-canonicalization-needs-the-valu

// runMachinery — the sh() replacement (spike §1). — see build-level.design-notes.md#runmachinery-the-sh-replacement-spike-1
async function runMachinery(cmd, { label, slug, bashTimeoutMs, timeoutOutcome, phase: phaseName } = {}) {
  // temperloop#1071: the command runs under the workflow's own wall-clock
  // ceiling. `slowSecs` is 0 on this path — a solo executor returns exactly ONE
  // object by schema, so an advisory second line has nowhere to go. The step
  // `kind` is the label's phase ('gate' / 'recover-probe' / 'push-retry'), which
  // is what a STEP_TIMEOUT payload then names.
  const soloKind = String(label ?? '').split(':')[0] || 'solo';
  const boundedCmd = [
    stepBoundPreamble(0),
    stepFnDef('__s0', cmd),
    stepBoundInvoke('__s0', soloKind),
  ].join('\n');
  // Wording (temperloop#72): describe the command as a KNOWN build-machine — see build-level.design-notes.md#wording-temperloop-72-describe-the-command-as-a-known-build-
  const promptFor = (lean) =>
    [
      'Run this single build-machinery helper command with the Bash tool, exactly as written.',
      'It is a known project script (worktree.sh / pr.sh / ci-poll.sh / claim.sh); do not add flags, chain extra commands, or rewrite it.',
      // temperloop#1071: the emitted text now opens with a few lines of inline — see build-level.design-notes-2.md#temperloop-1071-the-emitted-text-now-opens-with-a-few-l
      'It opens with a small inline wall-clock watchdog (a `sleep`/`kill` guard) that bounds how long the helper may run; that guard is PART of the command — run the whole thing, do not strip or shorten it.',
      // temperloop#115: for a legitimately long-running command (the 3e.5 gate — see build-level.design-notes-2.md#temperloop-115-for-a-legitimately-long-running-command-
      bashTimeoutMs
        ? lean
          ? `Set the Bash tool \`timeout\` parameter to ${bashTimeoutMs}.`
          : `This command runs longer than usual. When you invoke the Bash tool, set its \`timeout\` parameter to ${bashTimeoutMs} (milliseconds). That is a Bash tool parameter only — do NOT alter the command text — and it prevents the default 2-minute timeout from killing the run.`
        : null,
      // The three lines below are the executor's STANDING contract, identical  — see build-level.design-notes-2.md#the-three-lines-below-are-the-executor-s-standing-contr
      lean ? null : 'It prints a SINGLE JSON line on stdout describing its own result (a closed `outcome` set).',
      lean ? null : 'Return that JSON object verbatim as your result — the schema captures it.',
      lean ? null : 'If the command exits non-zero it STILL prints its JSON line; return that line.',
      // temperloop#1021: name the TIMEOUT case explicitly. NOT lean-guarded, a — see build-level.design-notes.md#temperloop-1021-name-the-timeout-case-explicitly-not-lean-gu
      timeoutOutcome
        ? `If the Bash tool's own timeout kills the command BEFORE it prints any JSON line, do NOT guess a failure outcome and do NOT re-run it: return exactly {"outcome":"${timeoutOutcome}"}. A timeout means the time budget ran out — it is NOT evidence that anything failed, and reporting it as a failure is a known defect (temperloop#1021).`
        : null,
      '',
      'Command:',
      boundedCmd,
    ].filter(Boolean).join('\n');
  const out = await machineryAgent(
    promptFor,
    {
      label: label ?? `machinery:${cmd.split(' ').slice(0, 2).join(' ')}`,
      phase: phaseName ?? 'machinery',
      // temperloop#982: orchestrator-supplied workflow input, NOT a config-fil — see build-level.design-notes.md#temperloop-982-orchestrator-supplied-workflow-input-not-a-co
      model: input.machinerySoloModel || 'haiku',
      schema: SPINE_OUTCOME_SCHEMA,
      // NB: deliberately NO isolation:'worktree' — see DESIGN NOTE 3.
    },
  );
  // Null-guard (temperloop#72): agent() returns null when the run is DENIE — see build-level.design-notes.md#null-guard-temperloop-72-agent-returns-null-when-the-run-is-
  return out == null ? { outcome: 'SPINE_DENIED', denied: true } : canonicalizeOutcome(out);
}

// runMachineryBatch — the BATCHED sh() replacement (temperloop#942). — see build-level.design-notes.md#runmachinerybatch-the-batched-sh-replacement-temperloop-942

// globPat — a `case` pattern matching any line CONTAINING `sub`. The lit — see build-level.design-notes-2.md#globpat-a-case-pattern-matching-any-line-containing-sub
function globPat(sub) {
  return `*${sq(sub)}*`;
}

// batchCommand — join the steps into ONE shell script: run, echo, gate,  — see build-level.design-notes-2.md#batchcommand-join-the-steps-into-one-shell-script-run-e
function batchCommand(steps) {
  // temperloop#1071: every step runs under the workflow's wall-clock ceili — see build-level.design-notes-2.md#temperloop-1071-every-step-runs-under-the-workflow-s-wa
  const lines = [stepBoundPreamble(STEP_SLOW_SECS)];
  steps.forEach((s, i) => {
    const v = `__o${i}`;
    const fn = `__s${i}`;
    lines.push(stepFnDef(fn, s.cmd));
    lines.push(`${v}=$( ${stepBoundInvoke(fn, s.kind)} )`);
    lines.push(`printf '%s\\n' "$${v}"`);
    if (i === steps.length - 1) return; // nothing follows — no gate needed
    if (s.stopGlobs && s.stopGlobs.length > 0) {
      // A timed-out step stops the sequence on BOTH gate forms. The — see build-level.design-notes.md#a-timed-out-step-stops-the-sequence-on-both-gate-forms-the
      const stops = [...s.stopGlobs.map(globPat), globPat('"outcome":"STEP_TIMEOUT"')];
      lines.push(`case "$${v}" in ${stops.join('|')}) exit 0 ;; esac`);
    } else if (s.continueOutcomes && s.continueOutcomes.length > 0) {
      const pats = s.continueOutcomes.map((o) => globPat(`"outcome":"${o}"`)).join('|');
      lines.push(`case "$${v}" in ${pats}) ;; *) exit 0 ;; esac`);
    }
  });
  return lines.join('\n');
}

// runMachineryBatch — returns { denied, results, steps, out }. `results[ — see build-level.design-notes.md#runmachinerybatch-returns-denied-results-steps-out-results
async function runMachineryBatch(steps, { label, slug, bashTimeoutMs, phase: phaseName } = {}) {
  if (!steps || steps.length === 0) {
    return { denied: false, results: [], steps: [] };
  }
  const kinds = steps.map((s) => s.kind);
  // Lean vs full prompt: see machineryAgent() above (#1014). The two #72 f — see build-level.design-notes-2.md#lean-vs-full-prompt-see-machineryagent-above-1014-the-t
  const promptFor = (lean) =>
    [
      'Run this build-machinery command sequence with the Bash tool, exactly as written, in ONE Bash invocation.',
      'It is a short shell script that calls known project helper scripts (worktree.sh / pr.sh / ci-poll.sh / claim.sh / gh) one after another; do not add flags, reorder or split the steps, or rewrite it.',
      `Steps: ${kinds.join(', ')}`,
      // temperloop#115 rationale, applied per batch: for a legitimately — see build-level.design-notes-2.md#temperloop-115-rationale-applied-per-batch-for-a-legiti
      bashTimeoutMs
        ? lean
          ? `Set the Bash tool \`timeout\` parameter to ${bashTimeoutMs}.`
          : `This sequence runs longer than usual. When you invoke the Bash tool, set its \`timeout\` parameter to ${bashTimeoutMs} (milliseconds). That is a Bash tool parameter only — do NOT alter the command text — and it prevents the default 2-minute timeout from killing the run.`
        : null,
      // Standing contract — carried by claude/agents/machinery-executor.md on — see build-level.design-notes-3.md#standing-contract-carried-by-claude-agents-machinery-ex
      lean ? null : 'Each helper prints a SINGLE JSON line on stdout describing its own result (a closed `outcome` set).',
      lean ? null : "The script deliberately STOPS EARLY when a step's result means the remaining steps must not run. FEWER JSON lines than steps is expected and correct — never an error, never something to re-run, retry, or work around.",
      lean ? null : 'Return every JSON object it printed on stdout, in stdout order, as {"results": [ ... ]}. Copy each object VERBATIM — do not merge, summarise, reorder, add, drop, or invent entries — and ignore any non-JSON output.',
      lean ? null : 'If a step exits non-zero it STILL prints its JSON line; include it.',
      '',
      'Command:',
      batchCommand(steps),
    ]
      .filter(Boolean)
      .join('\n');
  const out = await machineryAgent(
    promptFor,
    {
      label: label ?? `machinery-batch:${kinds.join('+')}`,
      phase: phaseName ?? 'machinery',
      // temperloop#982: orchestrator-supplied workflow input, NOT a config-fil — see build-level.design-notes.md#temperloop-982-orchestrator-supplied-workflow-input-not-a-co-2
      model: input.machineryBatchModel || 'haiku',
      schema: SPINE_BATCH_SCHEMA,
      // NB: deliberately NO isolation:'worktree' — see DESIGN NOTE 3.
    },
  );
  if (out == null || !Array.isArray(out.results)) {
    return {
      denied: true,
      results: [],
      steps: kinds,
      out: out ?? { outcome: 'SPINE_DENIED', denied: true },
    };
  }
  // temperloop#1071 — PARTITION the advisory notices out of the results ar — see build-level.design-notes.md#temperloop-1071-partition-the-advisory-notices-out-of-the-re
  out.results.forEach(canonicalizeOutcome);
  const notices = out.results.filter((r) => r && r.outcome === 'STEP_SLOW');
  const results = out.results.filter((r) => !(r && r.outcome === 'STEP_SLOW'));
  // …and LOG them. This is the observable-progress half of the bound: a st — see build-level.design-notes-3.md#and-log-them-this-is-the-observable-progress-half-of-th
  for (const n of notices) {
    log(
      // temperloop#1698: canonical camelCase reads, fed by canonicalizeOutcome — see build-level.design-notes-3.md#temperloop-1698-canonical-camelcase-reads-fed-by-canoni
      `[${slug ?? label ?? 'level'}] machinery step '${n.step ?? '?'}' took ${n.elapsedSecs ?? '?'}s ` +
      `— over the ${n.slowSecs ?? STEP_SLOW_SECS}s expected-duration mark, still under the ` +
      `${n.ceilingSecs ?? STEP_CEILING_SECS}s liveness ceiling (temperloop#1071). Not lost, not retried — ` +
      `raise BUILD_MACHINERY_STEP_SLOW_SECS if this step is legitimately this slow.`,
    );
  }
  return { denied: false, results, steps: kinds, out };
}

// batchStep — step i's outcome object, or a closed ERROR sentinel when t — see build-level.design-notes.md#batchstep-step-i-s-outcome-object-or-a-closed-error-sentinel
function batchStep(batch, i) {
  const r = batch.results[i];
  return r == null
    ? { outcome: 'ERROR', error: `machinery step '${batch.steps[i] ?? i}' produced no result` }
    : r;
}

// batchDeniedStep — what to name in a `machinery-denied` payload. A one- — see build-level.design-notes-3.md#batchdeniedstep-what-to-name-in-a-machinery-denied-payl
function batchDeniedStep(batch, batchName) {
  return batch.steps.length === 1 ? batch.steps[0] : batchName;
}

// Worker prompt assembly (3c). — see build-level.design-notes-2.md#worker-prompt-assembly-3c
function acceptanceList(item) {
  return Array.isArray(item.acceptance)
    ? item.acceptance
    : item.acceptance
      ? [item.acceptance]
      : [];
}

// principlesSection — the §3c "effective engineering principles" block — see build-level.design-notes-2.md#principlessection-the-3c-effective-engineering-principles-bl
function principlesSection(item) {
  const resolved = resolvePrinciplesSummary(item);
  const lines = [
    '## Effective engineering principles — weigh your choices against these',
    'This is the SAME merged (kernel ∪ project) principle set build.md § Step 1.8',
    'resolves once for this run and § 3e hands the pre-push reviewer for this',
    "item's (repo, project) pair — reused here, not re-derived. Weigh your own",
    'choices against it, and if your own summary cites a principle-shaped',
    'concern, name the principle and its origin (`kernel` or `project`).',
    '',
    resolved.text,
  ];
  if (resolved.degraded) {
    lines.push(
      '',
      'DEGRADED — no orchestrator-resolved principle set reached this worker this run',
      '(`principlesSummaries` was absent — an older orchestrator, or a consuming-repo',
      "caller that has not wired build.md's Step 1.8 hand-off; /build, /sweep and /fix",
      'all resolve and pass it). The list above is a STATIC KERNEL-ONLY',
      'snapshot — this runtime has no filesystem to read',
      '`claude/engineering-principles.md` itself — with NO project `## Principles`',
      'extension applied. Treat it as a floor, never as confirmation the project slot',
      'is empty.',
    );
  }
  return lines;
}

// discriminationEvidenceSection — the §3c "test-discrimination evidence" — see build-level.design-notes-2.md#discriminationevidencesection-the-3c-test-discrimination-evi
function discriminationEvidenceSection() {
  if (!REQUIRE_DISCRIMINATION_EVIDENCE) return [];
  return [
    '',
    '## Discrimination evidence — prove each check can actually FAIL (temperloop#1319)',
    'A self-report that a check "passed" is worthless if the check could never have',
    'failed. For EVERY acceptance criterion above, report — in that criterion\'s',
    '`acceptance_results[].discrimination_evidence` field — the evidence that your',
    'verification actually DISCRIMINATES pass from fail, at minimum:',
    '- **Which mechanism you removed or broke** to exercise the negative case (the',
    '  specific call, guard, assertion, or behavior the criterion depends on).',
    '- **That the suite went RED without it** — the failing run, command + verdict.',
    '- **That restoring it went GREEN** — the passing run, command + verdict.',
    'A criterion you never watched fail is unverified, no matter how confidently you',
    'report it `passed: true` — a vacuously-passing check is indistinguishable from a',
    'real one in the returned verdict alone, which is exactly the failure this field',
    'exists to close. If a criterion genuinely has no test to discriminate (a docs-only',
    'change, a config value with no behavior to break), say so explicitly in that field',
    'rather than leaving it empty. **Two DISTINCT exemptions, worded differently — do not',
    'conflate them:** (1) too coarse to discriminate (above) — say so in your own words;',
    '(2) a criterion naming the BARE repo-wide gate, which you never run (#997) and',
    'therefore never watched red or green — for that one write EXACTLY',
    '`deferred to §3e.5; discrimination not established worker-side` in the field, never',
    'left empty and never fabricated. Like `evidence`, keep it to a compact pointer — at',
    `most ${WORKER_EVIDENCE_MAX_WORDS} words — never a narrative.`,
  ];
}

// hostConfigDeferralSection — the §3c host-config/secret deferral contract
// (temperloop#1182), a SELF-CONTAINED section appended once into
// workerPrompt()'s array, mirroring discriminationEvidenceSection()'s shape.
//
// WHY IT IS UNGATED. Unlike discrimination evidence, this is not a discipline
// a caller opts into — it is a STRUCTURAL fact about every worktree on every
// path (/build, /sweep, /fix all route through this same prompt): `git
// worktree add` populates from the git INDEX, so a gitignored host-local file
// is never present, on any host, ever. foundation#1556 is the measured
// instance: an item whose acceptance was "`pipeline-retro-judge-spawn.sh
// --dry-run` reports credential_present" read `false` in the worktree and
// `true` in BOTH real checkouts moments later. The worker did the right thing
// (reported rather than went looking), but nothing structural stopped it from
// "helpfully" copying the token into a non-gitignored path — which is the
// exposure /assess A.8 exists to prevent, and a strictly worse failure than
// the unverified criterion.
//
// The bar is NOT relaxed (A.8 still demands confirmed-set, not location-named):
// what this changes is WHO confirms, not WHETHER. The worker defers; the
// orchestrating session, which runs in the real checkout, verifies parent-side
// after hand-back, fed by park()'s host_config_deferrals field.
//
// UNGATED IS ONLY SOUND BECAUSE ALL THREE PATHS HAVE A SEAT. Each invoking
// spec owns a parent-side verification step for the deferral this section
// produces — build.md §4a, sweep.md's per-chunk merge pass, fix.md Step 5's
// modal gate (and build.md §3h.5's as-you-go tier explicitly EXCLUDES an item
// carrying the field, since that path bypasses §4a). See the seat list in the
// I/O CONTRACT above. If a future path starts invoking this driver, it either
// grows its own seat or this section stops being ungated — shipping the
// instruction to a path with no seat is how a deferral auto-merges unverified.
function hostConfigDeferralSection() {
  return [
    '',
    '## Host-config / gitignored-file criteria — DEFER, never confirm (temperloop#1182)',
    'Your worktree is populated from the git INDEX, so a gitignored host-local file — a',
    'credential file such as `workflows/scripts/build/build.config.local.sh`, an',
    'operator-placed secret, an env var sourced from one — is NEVER present here. Any',
    'acceptance criterion that turns on such a file is structurally unverifiable from this',
    'worktree: an absent/`false` reading is UNINFORMATIVE, not a failure, and it reads',
    'identically on a host where the file IS correctly configured.',
    '- **Do NOT carry, copy, recreate, or hunt elsewhere for the named file.** Landing a',
    '  credential anywhere inside this worktree is the secret-in-worktree exposure the',
    '  host-config seam exists to prevent — a worse failure than the unverified criterion.',
    '- **Report the criterion as DEFERRED, never as passed.** Set `passed: false` (you did',
    '  not confirm it) AND set `deferred_host_config` to the file or env var it turns on',
    '  (e.g. `workflows/scripts/build/build.config.local.sh (SENTRY_AUTH_TOKEN)`). That',
    '  PAIR is the deferral marker: the driver reads it as neither a pass nor a failure, so',
    '  it does not stall the level, and the orchestrating session — which runs in the real',
    '  checkout and CAN see the file — verifies it parent-side after you hand back.',
    '- **`passed: false` WITHOUT `deferred_host_config` still means blocked.** Never claim a',
    '  pass you structurally cannot make, and never set the marker to route around a',
    '  criterion you merely failed to meet — it defers WHO verifies, never WHETHER.',
    '- If this run also asks for `discrimination_evidence`, a deferred criterion\'s reads',
    '  exactly `deferred to parent-side host-config verification` — never fabricated.',
  ];
}

// changelogFragmentSection — the §3c "add your own changelog.d/ fragment"
// instruction (temperloop#1530), a SELF-CONTAINED section appended once into
// workerPrompt()'s array, mirroring principlesSection()'s /
// discriminationEvidenceSection()'s shape so a sibling edit to workerPrompt()
// rebases cleanly. WHY THE WORKER, NOT A PARENT-SIDE CHECK: the issue's own
// prose names two options (tell the worker vs. run check-changelog-entry.sh
// parent-side before pr.sh open) — this instructs the worker because that is
// PREVENTION (the fragment lands in the same commit, no round trip) rather
// than DETECTION (a parent-side check still costs a re-spawn once it fires,
// just earlier than CI); it does not restate the fragment's filename grammar
// or body rules here — those live in ONE place, changelog.d/README.md — so
// this section and that file can't drift out of sync with each other. The
// escape hatch it names is the ONE opt-out channel that works before a PR
// exists (a commit-message trailer — check-changelog-entry.sh's own header),
// so a worker that judges its change non-shipping RECORDS that choice rather
// than silently omitting the fragment.
function changelogFragmentSection(item) {
  return [
    '',
    '## Changelog fragment — contract-surface changes need one (temperloop#1530)',
    'If this item touches contract surface (a public interface, schema, CLI flag,',
    'or gate behavior — see `VERSIONING.md` § The contract surface for the exact',
    'set), add your OWN changelog fragment as part of this change, in the same',
    'commit as the change or a follow-up commit on this branch — the same way you',
    'are told to run the gates. Read `changelog.d/README.md` for the filename',
    'grammar and body rules; this prompt does not restate them, so follow that',
    'file, not a guess. Name the file',
    `\`changelog.d/${item.slug}.<category>.md\` (prefix the item's own issue number`,
    "when you know it from the item block above, per the README's `<issue#>-<slug>`",
    "convention — the slug alone is still a valid filename if you don't).",
    '',
    'If this change genuinely ships nothing changelog-worthy, do not just omit the',
    'fragment — RECORD that choice: add a `Changelog: none — <reason>` line as a',
    'commit-message trailer (the one opt-out channel that works before a PR',
    'exists; see `changelog.d/README.md` § Status). An omitted fragment with no',
    'recorded reason reads as an oversight, not a decision — CI will fail on it',
    'exactly once (check-changelog-entry.sh), costing a re-spawn round trip this',
    'section exists to avoid.',
  ];
}

// gateRegistrationChecklistSection — the §3c "new gate script? register — see build-level.design-notes-2.md#gateregistrationchecklistsection-the-3c-new-gate-script-regi
function gateRegistrationChecklistSection() {
  return [
    '',
    '## New gate script? Register it before running the scoped gate (temperloop#1931)',
    'If this change adds or RENAMES a gate, validator, checker, test, or setting,',
    'register it FIRST — before your own `--scoped` run above — so that run can',
    'actually catch a mistake in the registration itself, not just in the script:',
    '- A new/renamed `check-*.sh` / `validate-*.sh` script (a "check surface") →',
    '  `workflows/scripts/config/check-surface-registry.tsv` (not yet shipping its',
    '  degenerate-input coverage? a `pending`/`excluded` row in',
    '  `workflows/scripts/config/check-surface-discovery.tsv` naming why, or a',
    '  documented row on `workflows/scripts/config/check-surface-degenerate-allowlist.tsv`).',
    '- Any new gate `scripts/quality-gates.sh` invokes → a row in',
    '  `workflows/scripts/config/gate-paths.tsv` (validated by `check-gate-paths.sh`).',
    '- A script meant to be run directly (the `workflows/scripts/validate-*.sh` /',
    '  `check-*.sh` family) → `workflows/scripts/config/exec-bit-registry.tsv`.',
    '- Any new tracked path at all → BOTH coverage manifests,',
    '  `workflows/scripts/kernel/kernel-manifest.txt` AND',
    '  `docs/features/feature-manifest.txt` (two independent, both-mandatory gates',
    '  over the same tree — a claim in only one leaves the other red).',
    '- A new `: "${SETTING_NAME:=default}"` this change introduces →',
    '  `workflows/scripts/config/setting-registry.tsv`.',
    'Registering after a parent-side red costs a full sliced acceptance-gate round',
    'trip (about 10-20 minutes) this checklist exists to avoid.',
  ];
}

// activationProofSection — the temperloop#1934 "show the worker its own — see build-level.design-notes-2.md#activationproofsection-the-temperloop-1934-show-the-worker-i
function activationProofSection(item) {
  if (activationClass(item) !== 'A') return [];
  const proof = typeof item.activation.proof === 'string' ? item.activation.proof.trim() : '';
  if (!proof) return [];
  return [
    '',
    '## Class-A activation gate — the reachability predicate you are gated on (temperloop#1934)',
    "This item's plan carries a class-A `activation:` block. Before your PR can be pushed,",
    'the orchestrator runs the EXACT command below — the reachability predicate — against',
    'this worktree (build.md §3e.6), strictly after your own acceptance self-check and gate',
    'run and before push. It reads false until your built code is genuinely reachable on the',
    'running path, not merely present:',
    '',
    '```',
    proof,
    '```',
    '',
    'Name and wire your artifacts so this predicate PASSES — treat the surface it names (a',
    'function/symbol name, a file path, a config key) as fixed, not a suggestion open to your',
    'own naming choice. If the predicate names a surface that genuinely CONTRADICTS the',
    'acceptance bullets above (the two disagree on what the consumer-facing name or shape',
    'should be), do NOT silently rename your own artifact to match and do NOT weaken or',
    'reinterpret the predicate — return `blocked` with a question naming the conflict so a',
    'human resolves it before any further work.',
  ];
}

// parentSummarySection — the epic #1847 Produces #7 companion: injects t — see build-level.design-notes-2.md#parentsummarysection-the-epic-1847-produces-7-companion-inje
function parentSummarySection(item) {
  if (!item.parentSummary) return [];
  const epicRef = item.parentEpic ? `#${item.parentEpic}` : 'the parent epic';
  return [
    '',
    '## Parent epic context',
    `This item is one member of a larger epic (${epicRef}) that drives its members`,
    "through /sweep's Operational-epic member admission path (temperloop#1847) —",
    'the epic itself carries no plan-note ceremony, so this is the only place its',
    "framing reaches you. It is context for WHY this item exists; it does not",
    "change or extend this item's own Acceptance bullets above.",
    '',
    String(item.parentSummary).trim(),
  ];
}

// THE WORKER GATE SENTINEL — a RESULT artifact, not a process (temperloo — see build-level.design-notes-2.md#the-worker-gate-sentinel-a-result-artifact-not-a-process-tem
function workerGateSentinel(slug) {
  return `/tmp/qg-${slug}.worker-gate.json`;
}

// workerGateLog — where the handed invocation tees the suite's own outpu — see build-level.design-notes-3.md#workergatelog-where-the-handed-invocation-tees-the-suit
function workerGateLog(slug) {
  return `/tmp/qg-${slug}.worker-gate.log`;
}

// workerGateState — the sentinel classification the 3e.5 gate reported, — see build-level.design-notes-2.md#workergatestate-the-sentinel-classification-the-3e-5-gate-re
const WORKER_GATE_STATES = ['finished', 'running', 'absent', 'unknown'];
function workerGateState(out) {
  const s = out && typeof out.workerGate === 'string' ? out.workerGate : '';
  return WORKER_GATE_STATES.includes(s) ? s : 'absent';
}

// workerGateCmd — the ONE invocation the worker is handed. Foreground by — see build-level.design-notes-2.md#workergatecmd-the-one-invocation-the-worker-is-handed-foregr
function workerGateCmd(slug, worktreePath) {
  const sent = sq(workerGateSentinel(slug));
  const glog = sq(workerGateLog(slug));
  return (
    `set -o pipefail || exit 1; ` +
    `cd ${sq(worktreePath)} || exit 1; ` +
    `[ -x ./scripts/quality-gates.sh ] || { echo 'no executable ./scripts/quality-gates.sh in this repo — no gate to run' >&2; exit 127; }; ` +
    `__t0=$(date +%s) || exit 1; ` +
    `printf '{"state":"running","startedAt":%s}\\n' "$__t0" > ${sent} || exit 1; ` +
    `./scripts/quality-gates.sh --scoped 2>&1 | tee ${glog}; __rc=$?; ` +
    `printf '{"state":"finished","rc":%s,"elapsedSecs":%s}\\n' "$__rc" "$(( $(date +%s) - __t0 ))" > ${sent}; ` +
    `cat ${sent}; exit $__rc`
  );
}

// workerGateSection — the prompt half, a SELF-CONTAINED section spliced — see build-level.design-notes-2.md#workergatesection-the-prompt-half-a-self-contained-section-s
function workerGateSection(slug, worktreePath) {
  const sent = workerGateSentinel(slug);
  return [
    '',
    '## Your scoped gate — run THIS EXACT command (temperloop#865)',
    'Do NOT compose your own gate invocation. Run this one, verbatim, in the',
    'FOREGROUND (one blocking Bash call, with the tool `timeout` parameter raised):',
    '',
    '```sh',
    workerGateCmd(slug, worktreePath),
    '```',
    '',
    `Once the suite actually STARTS it always writes a RESULT SENTINEL to \`${sent}\` —`,
    '`{"state":"running",…}` first, then `{"state":"finished","rc":<exit>,"elapsedSecs":<n>}`',
    'when it ends — and prints that sentinel as its last line. It refuses outright rather than',
    'starting the suite in the wrong place or without `pipefail` (the exit-code table below), and',
    'a refusal writes NO sentinel at all, so the sentinel never describes a run that did not happen.',
    '- **Poll the RESULT FILE, never a PID.** Waiting on a process id, a `kill -0`, or a',
    '  background-task notification is the stall this replaces: the exit status dies with',
    '  the process, and a subagent receives no background-task notification at all, so that',
    '  poll can never succeed. Reading the sentinel always can.',
    `- If your Bash call came back without the sentinel line, \`cat ${sent}\`.`,
    '  `state:"finished"` + `rc:0` is a PASS; `state:"finished"` + non-zero `rc` is a real',
    '  FAIL you can report; `state:"running"` means it is still going; no file at all means',
    '  it never started.',
    '- NEVER report a gate pass without a `state:"finished"` sentinel. If you cannot get one,',
    '  return `blocked` and quote the sentinel (or its absence). The orchestrator reads this',
    '  SAME file at §3e.5 and reports what it finds either way, so an unfinished gate is',
    '  visible whether you mention it or not.',
    '- **A missing sentinel is a REFUSAL, never a pass.** The command hard-refuses instead of',
    '  guessing, and every refusal happens BEFORE any sentinel is written, so `no file at all`',
    '  + a non-zero exit always means the suite never ran. The three refusals, by exit code:',
    `    - **127** — this repo has no executable \`scripts/quality-gates.sh\`. It prints`,
    '      `no executable ./scripts/quality-gates.sh` on stderr and leaves NO sentinel. Say so',
    '      and move on: that is not a gate failure, and it is the one case where a missing',
    '      sentinel is expected rather than a stall.',
    `    - **1, with a \`cd\` error on stderr** — the worktree moved or was pruned. The suite is`,
    '      NOT run somewhere else and passed off as this item\'s gate. Report it as blocked.',
    `    - **1–2, with a \`pipefail\` error on stderr** — it needs **bash** (it opens with`,
    '      `set -o pipefail`, which POSIX `sh` does not have). The Bash tool gives you one; if',
    '      some wrapper hands it to a plain `sh`, it aborts on that first line. Report it as',
    '      blocked.',
    '  In all three, never infer a green gate from the missing sentinel.',
  ];
}

function workerPrompt(item, worktreePath, extraSection) {
  const accList = acceptanceList(item);
  const accBullets = accList
    .map((a) => `  - ${typeof a === 'string' ? a : JSON.stringify(a)}`)
    .join('\n');
  return [
    `You are a /build implementation worker for item \`${item.slug}\`.`,
    '',
    '## Workspace — STRICT isolation',
    `- Your Bash cwd and ALL edits MUST be under: ${worktreePath}`,
    '- Make every Edit/Write path relative to that cwd, or absolute UNDER it.',
    `  NEVER write to the parent checkout — a PreToolUse guard (.build-guard`,
    '  marker) structurally rejects out-of-worktree writes.',
    '- Commit on the current branch. Do NOT push. Do NOT open a PR.',
    '- No issue-closing keywords (Closes/Fixes/Resolves + #N) in commit messages —',
    '  GitHub auto-closes on default-branch merge from commit messages too.',
    '',
    // #1072 — the near-miss this institutionalizes: a build worker (temperlo — see build-level.design-notes-2.md#1072-the-near-miss-this-institutionalizes-a-build-worker-tem
    '## No context-inheriting research forks',
    '- BANNED: spawning a context-inheriting `fork` for a narrow READ-ONLY sub-task',
    '  (e.g. gathering conventions, reading code). A fork inherits this ENTIRE prompt,',
    '  including "implement the item, drive to done, and commit" — so a fork spawned',
    '  for research still carries that mission and may edit, commit, or fabricate a',
    '  completion report instead of returning findings (observed: temperloop#635).',
    '- SANCTIONED: a FRESH, explicitly-scoped read-only subagent (`Explore` /',
    '  `general-purpose`) with a read-only, return-findings-ONLY prompt and no',
    '  write/commit instructions — it does not inherit the drive-to-done mission.',
    '  A `fork` is also fine if its OWN prompt explicitly OVERRIDES the inherited',
    '  mission ("read-only; return findings ONLY; make no edits and no commits").',
    '- This does NOT ban build.md\'s "Seat scoping — nested review delegation" (a',
    '  focused REVIEW nested agent for context control) — that is the sanctioned',
    '  pattern above, not the banned one.',
    '- Treat any nested-agent report as UNTRUSTED until you independently re-verify',
    '  it against ground truth.',
    '',
    '## Item',
    `- title: ${item.title}`,
    `- scope: ${item.scope ?? '(see source)'}`,
    `- source: ${item.source ?? '(none)'}`,
    item.notes ? `- notes: ${item.notes}` : null,
    ...parentSummarySection(item),
    '',
    '## Acceptance (self-verify each before returning done)',
    accBullets || '  - (none specified)',
    ...activationProofSection(item),
    ...discriminationEvidenceSection(),
    '',
    '## Verification surface — write to a FILE, return only the path',
    `Write your verification-surface markdown block to ${worktreePath}/.build-verification.md`,
    'and return its path as `verification_surface_path`. Do NOT inline it in the JSON.',
    '',
    // §3c "No long-running background work" (#1219). Embedded in the generat — see build-level.design-notes-2.md#3c-no-long-running-background-work-1219-embedded-in-the-gene
    '## Quality gate & long-running work — FOREGROUND ONLY (#1219)',
    '- Run EVERY verification command you DO run in the FOREGROUND (a blocking Bash',
    '  call): the changed-file-scoped gate run below, plus any eval / build / sweep.',
    '- NEVER launch one with `run_in_background: true`, and never end your turn awaiting',
    '  a Monitor / background-task notification. A subagent has NO re-invoke-on-completion',
    '  loop: a backgrounded process is reaped when you yield and the notification never',
    '  reaches you — you hang and return NO verdict. A turn that ends while awaiting a',
    '  background task is the #1219 bug, not a valid return.',
    '- Do NOT run the BARE, repo-wide `scripts/quality-gates.sh` (or a whole-suite `make`',
    '  equivalent) in your own context (#997). That suite is minutes-scale, and one',
    '  blocking turn that long blows the ~5-minute prompt-cache TTL: your ENTIRE',
    '  accumulated context is then re-written instead of re-read on the very next call,',
    '  a 12.5x token penalty. Run the CHANGED-FILE-SCOPED mode instead (#957):',
    '  `scripts/quality-gates.sh --scoped` selects the gates your own working-tree',
    '  changes reach (committed, staged, unstaged AND untracked), always runs the',
    '  enumerated global-by-nature floor, NAMES every gate it skipped, and stamps its',
    '  verdict `[SCOPED SUBSET — NOT a full-suite pass]`; anything it cannot resolve',
    '  widens to the full set. If the repo\'s gate script has no `--scoped` flag, fall',
    '  back to picking by hand: `scripts/quality-gates.sh --list` prints every gate as',
    '  `[layer] <make target>`; run only the few targets that cover the files you',
    '  touched. Keep EACH call to seconds. If you cannot cheaply tell which gates',
    '  apply, run none and say so.',
    '- That subset is FAST LOCAL FEEDBACK ONLY — it is NOT the acceptance authority.',
    '  The orchestrator runs the acceptance gate parent-side (build.md §3e.5) and THAT',
    '  run is the authority; a red there comes back to you as a re-spawn. So when an',
    '  acceptance criterion names the bare repo-wide suite, do NOT run it: report it',
    '  `passed: true` only if your targeted subset is green, and state plainly in its',
    '  `evidence` that the repo-wide check was DEFERRED to the parent-side 3e.5 gate',
    '  (itself diff-scoped since #1663 — the deferral is to a different ACTOR, the',
    '  orchestrator running against your commit, not to a wider PATH scope).',
    '  Never report `passed: false` for a merely DEFERRED criterion — that reads as',
    '  blocked and stalls the whole level on a check you were never meant to run.',
    '- If a single command would exceed the ~10-min Bash foreground cap — or the tighter',
    '  ~5-min cache-TTL budget above — NARROW or split it, or return `blocked` / `failed`',
    '  and let the orchestrator run it parent-side — never background-and-wait.',
    // temperloop#865 — the STRUCTURAL half of the same contract. The block a — see build-level.design-notes-3.md#temperloop-865-the-structural-half-of-the-same-contract
    ...workerGateSection(item.slug, worktreePath),
    // temperloop#1182 — the OTHER thing a worker structurally cannot verify. — see build-level.design-notes-2.md#temperloop-1182-the-other-thing-a-worker-structurally-cannot
    ...hostConfigDeferralSection(),
    '',
    // temperloop#1931 — placed right after the FOREGROUND-ONLY block's own — see build-level.design-notes-3.md#temperloop-1931-placed-right-after-the-foreground-only-
    ...gateRegistrationChecklistSection(),
    '',
    ...changelogFragmentSection(item),
    ...principlesSection(item),
    '',
    extraSection ?? '',
    '',
    // ## Output shape (temperloop#1080) — the SIZE half of the return contra — see build-level.design-notes-2.md#output-shape-temperloop-1080-the-size-half-of-the-return-con
    '## Output shape — your return value is a REPORT, not a transcript',
    'Everything you return is an output token the orchestrator then ingests, so the',
    'verdict stays small on purpose. It is not a place to show your work — you already',
    'have one, and it is free: the verification-surface FILE above never enters the',
    'orchestrator\'s context and is spliced verbatim into the PR body for a human. So:',
    '- **No process narration anywhere in the return value.** What you read, what you',
    '  ruled out, which approach you tried first, how long something took — none of it',
    '  belongs in the JSON. Report the OUTCOME and where it is checkable. If you feel a',
    '  step deserves recording, record it in the verification-surface file.',
    `- **\`summary\`: at most ${WORKER_SUMMARY_MAX_WORDS} words.** What changed and why it satisfies the item.`,
    '  Prose is unavoidable here, so the bound is the shape. Anything longer is detail —',
    '  put it in the verification-surface file, where the reviewer will actually read it.',
    `- **\`acceptance_results[].evidence\`: at most ${WORKER_EVIDENCE_MAX_WORDS} words EACH, and a POINTER, not an argument.**`,
    '  `file:line`, a test name, or a command plus its verdict. The reasoning that makes',
    '  the pointer convincing goes in the verification-surface file. `criterion` is the',
    '  acceptance bullet VERBATIM — quote it, never re-word or summarize it.',
    `- **\`failure_reason\` / \`design_fork\` free-text slots: at most ${WORKER_EVIDENCE_MAX_WORDS} words each**, and`,
    '  `questions[]`: one self-contained question per entry, no preamble and no recap.',
    '- **Never pad a slot to reach its bound.** These are ceilings, not targets — a',
    '  one-line `summary` and a bare `file:line` evidence pointer are ideal returns.',
    '',
    '## Return contract — your FINAL message must be EXACTLY this JSON and nothing after:',
    'Return the smallest object your status requires (status ALWAYS; the rest per status).',
    'status ∈ { done, blocked, design-fork, failed }.',
    '- done: summary, acceptance_results[], commits[], verification_surface_path',
    '- blocked: questions[]',
    '- design-fork: design_fork{decision,options[],recommendation,evidence}',
    '- failed: failure_reason',
  ]
    .filter((l) => l !== null)
    .join('\n');
}

// FOREGROUND_CURE (#1219) — appended to the ONE null-verdict re-spawn so — see build-level.design-notes-2.md#foreground-cure-1219-appended-to-the-one-null-verdict-re-spa
const FOREGROUND_CURE = [
  '## Re-spawn cure (#1219) — your previous turn returned NO verdict',
  'Your previous attempt ended without a parseable verdict. The usual cause is',
  'backgrounding the quality gate (`run_in_background: true`) or awaiting a Monitor',
  'notification a subagent never receives. Run EVERY command you DO run — the',
  'scoped gate run (`scripts/quality-gates.sh --scoped`) above all — in the FOREGROUND, never `run_in_background` /',
  'Monitor, and END this turn with exactly the fenced verdict JSON and nothing after',
  'it. Do NOT run the bare, repo-wide `scripts/quality-gates.sh` here either (#997) —',
  'acceptance is the orchestrator\'s, parent-side at build.md 3e.5, and THAT is the',
  'acceptance authority; a minutes-long blocking turn is what blows the prompt-cache',
  'TTL. A stall is never cured by running MORE gate.',
].join('\n');

// DIRTY_RESUME_CURE (temperloop#993) — appended ON TOP of FOREGROUND_CURE when
// the recover-probe confirmed the stall shape: zero commits, no PR, but real work
// left on disk. The re-spawn is a FRESH agent (the harness has no resume-this-
// agent seam), so its only inheritance is the worktree — and without being told,
// it re-derives the change from scratch, discarding or duplicating what is
// already there. Naming the state explicitly is what makes the re-spawn a
// continuation rather than a restart. Rendered as a function because the file
// count is run state, not a constant.
function dirtyResumeCure(dirtyFiles) {
  return [
    '## Resume — your previous attempt left UNCOMMITTED work in this worktree (#993)',
    `The worktree already holds ${dirtyFiles} uncommitted path(s) from your previous`,
    'attempt (`git status --porcelain`), and ZERO commits. That is the signature of a',
    'turn that ended while a backgrounded gate was still running. The work is still',
    'there: START by reading `git status` and `git diff` in your worktree, KEEP what',
    'is already correct rather than rebuilding it, then finish, verify in the',
    'FOREGROUND, COMMIT, and return the verdict JSON.',
  ].join('\n');
}

// GATE_SENTINEL_CURE (temperloop#865) — the re-spawn's RECOVERY half, an — see build-level.design-notes-2.md#gate-sentinel-cure-temperloop-865-the-re-spawn-s-recovery-ha
function gateSentinelCure(slug) {
  const sent = workerGateSentinel(slug);
  return [
    '## Your previous gate run may already have a RESULT (temperloop#865)',
    `Before re-running anything, \`cat ${sent}\`.`,
    '- `{"state":"finished","rc":0,…}` — your previous gate PASSED. Do not re-run it;',
    '  report it and quote the sentinel.',
    '- `{"state":"finished","rc":<non-zero>,…}` — it FAILED for real. Read',
    `  \`${workerGateLog(slug)}\` for the output, fix, then re-run the handed command.`,
    '- `{"state":"running",…}` — the previous turn ended while the gate was still going.',
    '  That is the stall. Re-run the handed command in the FOREGROUND and wait for it.',
    '- No such file — it never started. Run the handed command.',
  ].join('\n');
}

// Compose the retry `extraSection` = the original section (if any) + the — see build-level.design-notes-3.md#compose-the-retry-extrasection-the-original-section-if-
function withCure(section, dirtyFiles, slug) {
  const dirty = Number(dirtyFiles) > 0 ? dirtyResumeCure(Number(dirtyFiles)) : null;
  const sentinel = slug ? gateSentinelCure(slug) : null;
  return [section, FOREGROUND_CURE, sentinel, dirty].filter(Boolean).join('\n\n');
}

// Lost-return recovery (temperloop#939). — see build-level.design-notes-2.md#lost-return-recovery-temperloop-939

const RECOVERY_UNVERIFIED =
  'UNVERIFIED — the worker completed without returning a verdict (temperloop#939); ' +
  'this criterion was NOT self-verified and must be re-verified before merge.';

// The recover-probe outcomes that mean "work landed" (anything but RECOVER_NONE).
const RECOVER_STAGES = ['RECOVER_COMMITTED', 'RECOVER_PUSHED', 'RECOVER_PR_OPEN'];

// Worker cost capture (temperloop#2065, epic #2062's dual-build ledger). — see build-level.design-notes-2.md#worker-cost-capture-temperloop-2065-epic-2062-s-dual-build-l
function workerUsageBin() {
  return machineryBin(input.repoRoot, 'worker-usage.sh');
}

// numOrNull — coerce to a finite number, or null. Guards the JS `Number( — see build-level.design-notes-2.md#numornull-coerce-to-a-finite-number-or-null-guards-the-js-nu
function numOrNull(v) {
  if (v === null || v === undefined) return null;
  // temperloop#2065 review round 1 [LOW]: Number('') === 0 and — see build-level.design-notes-2.md#temperloop-2065-review-round-1-low-number-0-and
  if (typeof v === 'string' && v.trim() === '') return null;
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
}

async function workerClockNow(item, tag, phaseName) {
  const out = await runMachinery(`${workerUsageBin()} clock`, {
    label: `worker-clock:${item.slug}#${tag}`,
    slug: item.slug,
    phase: phaseName ?? 'worker',
  });
  return out && out.outcome === 'WORKER_CLOCK' ? numOrNull(out.epoch_s) : null;
}

// workerOutcomeRef — ADR 0026's outcome-ref vocabulary, "(issue|pr):<ref — see build-level.design-notes-3.md#workeroutcomeref-adr-0026-s-outcome-ref-vocabulary-issu
function workerOutcomeRef(item) {
  return item.ghIssue ? `issue:${item.ghIssue}` : `issue:${item.slug}`;
}

async function workerUsageEmit(item, tag, seat, phaseName) {
  const model = item.model || 'inherit';
  const repo = input.ownerRepo || '';
  const out = await runMachinery(
    `${workerUsageBin()} emit ${sq(seat)} ${sq(model)} ${sq(workerOutcomeRef(item))} ${sq(repo)}`,
    { label: `worker-usage:${item.slug}#${tag}`, slug: item.slug, phase: phaseName ?? 'worker' },
  );
  const ok = out && out.outcome === 'WORKER_USAGE';
  return {
    epochS: ok ? numOrNull(out.epoch_s) : null,
    tokensIn: ok ? numOrNull(out.input_tokens) : null,
    tokensOut: ok ? numOrNull(out.output_tokens) : null,
  };
}

// USAGE_UNAVAILABLE — the degraded reading every workerUsageEmit() CALL — see build-level.design-notes-2.md#usage-unavailable-the-degraded-reading-every-workerusageemit
const USAGE_UNAVAILABLE = Object.freeze({ epochS: null, tokensIn: null, tokensOut: null });

// temperloop#2065 review round 2 [HIGH]: workerClockNow()/workerUsageEmi — see build-level.design-notes-2.md#temperloop-2065-review-round-2-high-workerclocknow-workerusa
async function safeWorkerClockNow(item, tag, phaseName) {
  try {
    return await workerClockNow(item, tag, phaseName);
  } catch {
    return null;
  }
}

async function safeWorkerUsageEmit(item, tag, seat, phaseName) {
  try {
    return await workerUsageEmit(item, tag, seat, phaseName);
  } catch {
    return USAGE_UNAVAILABLE;
  }
}

// elapsedMs — plain integer arithmetic on two already-resolved epoch-SEC — see build-level.design-notes-3.md#elapsedms-plain-integer-arithmetic-on-two-already-resol
function elapsedMs(startS, endS) {
  return typeof startS === 'number' && typeof endS === 'number'
    ? Math.max(0, Math.round((endS - startS) * 1000))
    : null;
}

// mergeWorkerCost — accumulate a SECOND callWorker() reading onto the fi — see build-level.design-notes-2.md#mergeworkercost-accumulate-a-second-callworker-reading-onto-
function mergeWorkerCost(acc, add) {
  if (!add) return acc;
  const sum = (a, b) => (a == null && b == null ? null : (a ?? 0) + (b ?? 0));
  return {
    wallClockMs: sum(acc.wallClockMs, add.wallClockMs),
    tokensIn: sum(acc.tokensIn, add.tokensIn),
    tokensOut: sum(acc.tokensOut, add.tokensOut),
  };
}

// callWorker — spawn the implementation worker so a lost return channel — see build-level.design-notes-2.md#callworker-spawn-the-implementation-worker-so-a-lost-return-
async function callWorker(item, wt, extraSection, label, phaseName) {
  const startS = await safeWorkerClockNow(item, label, phaseName);
  try {
    const v = await agent(workerPrompt(item, wt, extraSection), {
      label,
      phase: phaseName ?? 'worker',
      // temperloop#982: item.model || undefined, NOT bare item.model — an — see build-level.design-notes-2.md#temperloop-982-item-model-undefined-not-bare-item-model-an
      model: item.model || undefined, // "" or undefined → inherit session model
      schema: WORKER_VERDICT_SCHEMA,
    });
    const usage = await safeWorkerUsageEmit(item, label, 'build-worker', phaseName);
    // `nullReturn` (temperloop#1819): true only for the bare-null shape, whe — see build-level.design-notes-3.md#nullreturn-temperloop-1819-true-only-for-the-bare-null-
    return {
      verdict: v ?? null,
      error: v == null ? 'agent returned null' : null,
      nullReturn: v == null,
      wallClockMs: elapsedMs(startS, usage.epochS),
      tokensIn: usage.tokensIn,
      tokensOut: usage.tokensOut,
    };
  } catch (err) {
    const usage = await safeWorkerUsageEmit(item, label, 'build-worker', phaseName);
    return {
      verdict: null,
      error: String((err && err.message) || err),
      nullReturn: false,
      wallClockMs: elapsedMs(startS, usage.epochS),
      tokensIn: usage.tokensIn,
      tokensOut: usage.tokensOut,
    };
  }
}

// workerQuotaDeath — the worker-path quota classifier (temperloop#1819): — see build-level.design-notes-3.md#workerquotadeath-the-worker-path-quota-classifier-tempe
async function workerQuotaDeath(w) {
  if (quotaDeath(w.error)) return true;
  return w.nullReturn === true && !(await harnessCanSpawnAgents());
}

// probeSideEffects — run the staged pr.sh recover-probe (its own header owns the
// ladder) and normalize it. Returns { landed, stage, sha, pushed, pr,
// surfacePresent, probeOut }. `landed:false` covers BOTH the genuine-failure
// case (RECOVER_NONE) and an unusable probe (denied / ERROR): either way the
// caller falls through to the unchanged `worker-error` escalation, so a broken
// probe can never manufacture a recovery.
async function probeSideEffects(item, wt) {
  const prBin = machineryBin(input.repoRoot, 'pr.sh');
  const out = await runMachinery(
    `${prBin} recover-probe ${sq(wt)} ${sq(item.branch)}`,
    // STAGE_RECOVER (temperloop#1294): an off-path diagnostic that can fire  — see build-level.design-notes-3.md#stage-recover-temperloop-1294-an-off-path-diagnostic-th
    { label: `recover-probe:${item.slug}`, slug: item.slug, phase: stagePhase(STAGE_RECOVER) },
  );
  if (machineryDenied(out) || !RECOVER_STAGES.includes(out.outcome)) {
    // Not landed — but temperloop#993 splits this bucket. RECOVER_DIRTY mean — see build-level.design-notes-2.md#not-landed-but-temperloop-993-splits-this-bucket-recover-dir
    const dirtyFiles = machineryDenied(out) ? 0 : Number(out.dirty_files ?? 0) || 0;
    return {
      landed: false,
      stage: machineryDenied(out) ? null : out.outcome,
      stalled: !machineryDenied(out) && out.outcome === 'RECOVER_DIRTY',
      dirtyFiles,
      probeOut: out,
    };
  }
  return {
    landed: true,
    stage: out.outcome,
    sha: out.sha,
    // A PR implies a push even if ls-remote was somehow unhelpful.
    pushed: out.pushed === true || out.outcome === 'RECOVER_PR_OPEN',
    pr: out.pr_number ?? null,
    surfacePresent: out.verification_surface_present === true,
    probeOut: out,
  };
}

// Step-liveness disposal (temperloop#1071). — see build-level.design-notes-2.md#step-liveness-disposal-temperloop-1071
function timedOutStep(results) {
  return (results ?? []).find((r) => r && r.outcome === 'STEP_TIMEOUT') ?? null;
}

// disposeStepTimeout — what happens when the ceiling fires.
//
// THE RULE: a bounded-out step is LOST, never FAILED and never RE-ISSUED. The
// ceiling proves the workflow stopped waiting; it proves nothing about what the
// step did or did not do before it was killed — a `push` may have completed on
// the remote, a `pr-open` may have created the PR (the #1071 incident's own
// 9h49m step in fact finished ALL FOUR steps green and opened PR #1070). So the
// disposal is the same side-effect probe the lost-return path already owns:
// `pr.sh recover-probe` (temperloop#939's staged ladder, and the seam
// temperloop#1067 covers for the adjacent lost-return case — deliberately ONE
// disposal path, not a second one invented here).
//
// Two dispositions, no third:
//   • the probe finds an OPEN PR → ADOPT it (`adopt`), exactly as 3f-2 adopts
//     pr.sh's own `EXISTS`. This is the case that must never be re-run: blindly
//     re-issuing the batch would double-push or double-open.
//   • anything else → a legible `machinery-step-timeout` escalation carrying the
//     probe's verdict, for a human/orchestrator to drive. Still no retry.
// `adoptable:false` (the CI-poll path) keeps the probe — its stage is real
// evidence for the payload — while refusing the adopt arm, because "a PR exists"
// is not, and must never become, evidence that CI passed.
async function disposeStepTimeout(item, wt, to, where, { adoptable = true } = {}) {
  log(
    `[${item.slug}] ${where} step '${to.step ?? '?'}' exceeded the ${to.ceilingSecs ?? STEP_CEILING_SECS}s ` +
    `liveness ceiling after ${to.elapsedSecs ?? '?'}s and was killed (temperloop#1071). Treating it as LOST — ` +
    `probing for side effects before disposing; it is NEVER blind-retried.`,
  );
  const payload = { step: to.step ?? null, where, timeoutOut: to, adoptable };
  if (!wt) {
    // No worktree exists yet (a prelude step timed out before/at worktree
    // creation), so there is nothing for recover-probe to read. Say so in the
    // payload rather than running a probe whose answer is structurally 'ERROR'.
    return {
      escalation: escalate(item.slug, 'machinery-step-timeout', {
        ...payload,
        probed: false,
        reason: 'the step outlived the workflow liveness ceiling before a worktree existed — nothing to recover, nothing re-issued',
        remedy: 'inspect the host for a stuck process, then re-drive the item; raise BUILD_MACHINERY_STEP_CEILING_SECS only if the step is legitimately this long',
      }),
    };
  }
  const probe = await probeSideEffects(item, wt);
  const probed = {
    ...payload,
    probed: true,
    probeStage: probe.stage ?? null,
    pushed: probe.pushed === true,
    sha: probe.sha ?? null,
    pr: probe.pr ?? null,
  };
  // `probe.sha` is REQUIRED for the adopt arm, not optional: the CI poll t — see build-level.design-notes-3.md#probe-sha-is-required-for-the-adopt-arm-not-optional-th
  if (adoptable && probe.stage === 'RECOVER_PR_OPEN' && probe.pr && probe.sha) {
    log(
      `[${item.slug}] recover-probe found PR #${probe.pr} already opened by the timed-out '${to.step ?? '?'}' step — ` +
      `ADOPTING it (no re-push, no re-open) and continuing.`,
    );
    return { adopt: { pr: probe.pr, sha: probe.sha ?? null, probe } };
  }
  return {
    escalation: escalate(item.slug, 'machinery-step-timeout', {
      ...probed,
      reason:
        `the '${to.step ?? '?'}' machinery step outlived the ${to.ceilingSecs ?? STEP_CEILING_SECS}s workflow ` +
        `liveness ceiling and was killed. Its result is UNKNOWN, not failed — recover-probe reports ` +
        `${probe.stage ?? 'no usable answer'}. Nothing was re-issued, so no double-push/double-open is possible.`,
      remedy:
        'read the probe stage above to see what actually landed, then re-drive or finish by hand; ' +
        'raise BUILD_MACHINERY_STEP_CEILING_SECS only if the step is legitimately this long',
    }),
  };
}

// -----------------------------------------------------------------------------
// pr-batch lost-return recovery (temperloop#1067).
// -----------------------------------------------------------------------------
// isLostReturn — true iff a batch step's outcome is the SYNTHESIZED sentinel
// batchStep() (line ~1158) mints for a missing `batch.results[i]` entry, never a
// genuine failure the machinery script itself reported. This is the fidelity
// signal that distinguishes "the step failed" from "the step's return value was
// lost pr-batch return" — a real `pr.sh` failure calls its own `die()` and
// carries a DIFFERENT `error` string, so this check can never mistake a genuine
// non-zero exit for a lost line. That distinction is what keeps the negative
// case (a real failure) escalating immediately, unprobed, exactly as before.
function isLostReturn(stepOut) {
  return Boolean(
    stepOut &&
      stepOut.outcome === 'ERROR' &&
      typeof stepOut.error === 'string' &&
      stepOut.error.includes('produced no result'),
  );
}

// isVerdictUnparseable — the pr-open outcome temperloop#1805 is about: p — see build-level.design-notes-2.md#isverdictunparseable-the-pr-open-outcome-temperloop-1805-is-
const VERDICT_UNPARSEABLE_ERR = /verdict (?:is not valid JSON|JSON missing|JSON has malformed)/i;
function isVerdictUnparseable(stepOut) {
  return Boolean(
    stepOut &&
      stepOut.outcome === 'ERROR' &&
      typeof stepOut.error === 'string' &&
      VERDICT_UNPARSEABLE_ERR.test(stepOut.error),
  );
}

// recoverLostReturn — the 3f push/pr-open twin of disposeStepTimeout's p — see build-level.design-notes-2.md#recoverlostreturn-the-3f-push-pr-open-twin-of-disposesteptim
async function recoverLostReturn(item, wt, openCmd) {
  const probe = await probeSideEffects(item, wt);
  if (probe.landed && probe.stage === 'RECOVER_PR_OPEN' && probe.pr && probe.sha) {
    log(
      `[${item.slug}] lost pr-batch return (temperloop#1067) — recover-probe found PR #${probe.pr} ` +
      'already open; ADOPTING it (no re-push, no re-open).',
    );
    return { kind: 'adopted', pr: probe.pr, pushedSha: probe.sha };
  }
  if (probe.landed && (probe.stage === 'RECOVER_PUSHED' || probe.stage === 'RECOVER_COMMITTED')) {
    const resumeFromPush = probe.stage === 'RECOVER_COMMITTED';
    log(
      `[${item.slug}] lost pr-batch return (temperloop#1067) — recover-probe reports ${probe.stage}; ` +
      `resuming at ${resumeFromPush ? 'push' : 'pr-open'} (no re-run of already-confirmed steps).`,
    );
    const resumeSteps = [];
    if (resumeFromPush) {
      const prBin = machineryBin(input.repoRoot, 'pr.sh');
      // `--allow-rewrite` for the same reason 3f-1 carries it (temperloop#2103 — see build-level.design-notes-2.md#allow-rewrite-for-the-same-reason-3f-1-carries-it-temperloop
      resumeSteps.push({ kind: 'push', cmd: `${prBin} push ${sq(wt)} ${sq(item.branch)} --allow-rewrite`, continueOutcomes: ['PUSHED'] });
    }
    resumeSteps.push({ kind: 'pr-open', cmd: openCmd });
    const resumeAt = {};
    resumeSteps.forEach((s, i) => { resumeAt[s.kind] = i; });
    const rb = await runMachineryBatch(resumeSteps, {
      label: `pr-batch-resume:${item.slug}`,
      slug: item.slug,
      bashTimeoutMs: BATCH_BASH_TIMEOUT_MS,
      phase: stagePhase(STAGE_RECOVER), // off-path recovery — own group, cursor untouched
    });
    if (rb.denied) {
      // temperloop#1819: quota death vs genuine denial — see deniedOrQuota.
      const esc = await deniedOrQuota(item.slug, {
        step: batchDeniedStep(rb, 'pr-batch-resume'),
        steps: rb.steps,
        out: rb.out,
      }, wt);
      return { kind: 'escalate', escKind: esc.escalation.kind, payload: esc.escalation.payload };
    }
    const resumeTimeout = timedOutStep(rb.results);
    if (resumeTimeout) {
      const disp = await disposeStepTimeout(item, wt, resumeTimeout, 'pr-batch-resume');
      if (disp.escalation) {
        return { kind: 'escalate', escKind: disp.escalation.escalation.kind, payload: disp.escalation.escalation.payload };
      }
      return { kind: 'adopted', pr: disp.adopt.pr, pushedSha: disp.adopt.sha };
    }
    // `resumedSha` starts at the probe's own reading (correct for the — see build-level.design-notes-2.md#resumedsha-starts-at-the-probe-s-own-reading-correct-for-the
    let resumedSha = probe.sha ?? null;
    if (resumeAt.push !== undefined) {
      const pushOut = batchStep(rb, resumeAt.push);
      if (pushOut.outcome === 'PUSH_REJECTED') {
        return { kind: 'escalate', escKind: 'push-rejected', payload: { pushOut } };
      }
      if (pushOut.outcome === 'PUSHED_UNWATCHED') {
        // temperloop#1688 — the push landed on a ref no open PR watches. Its own — see build-level.design-notes-3.md#temperloop-1688-the-push-landed-on-a-ref-no-open-pr-wat
        return { kind: 'escalate', escKind: 'push-unwatched-branch', payload: { pushOut } };
      }
      if (pushOut.outcome !== 'PUSHED') {
        return { kind: 'escalate', escKind: 'push-error', payload: { pushOut } };
      }
      resumedSha = pushOut.sha ?? resumedSha;
    }
    const openOut = batchStep(rb, resumeAt['pr-open']);
    if (openOut.outcome !== 'PR_OPENED' && openOut.outcome !== 'EXISTS') {
      return { kind: 'escalate', escKind: 'pr-open-failed', payload: { openOut } };
    }
    return { kind: 'adopted', pr: openOut.pr_number, pushedSha: resumedSha };
  }
  // RECOVER_NONE / RECOVER_DIRTY / denied / unusable probe — genuinely not — see build-level.design-notes-3.md#recover-none-recover-dirty-denied-unusable-probe-genuin
  return { kind: 'none' };
}

// recoveredVerdict — reconstruct the verdict object the worker never ret — see build-level.design-notes-2.md#recoveredverdict-reconstruct-the-verdict-object-the-worker-n
function recoveredVerdict(item, probe, reason) {
  const criteria = acceptanceList(item);
  const results = (criteria.length ? criteria : ['(no acceptance criteria carried on this plan item)']).map(
    (c) => ({
      criterion: typeof c === 'string' ? c : JSON.stringify(c),
      evidence: RECOVERY_UNVERIFIED,
    }),
  );
  const summary =
    `**Recovered record (temperloop#939) — acceptance NOT self-verified.** The worker for ` +
    `\`${item.slug}\` completed without returning a verdict (${reason ?? 'no verdict'}), so this ` +
    `PR was reconstructed from observable side-effects (probe stage: ${probe.stage}, ` +
    `HEAD ${probe.sha ?? 'unknown'}). The work itself is real and present on this branch; what was ` +
    `lost is the worker's own acceptance self-check. Re-verify every criterion below before merging.`;
  return {
    status: 'done',
    recovered: true,
    summary,
    acceptance_results: results,
    verification_surface: [
      '### Recovered — verification NOT performed by the worker',
      '',
      `The implementation worker for \`${item.slug}\` finished its run but never returned a`,
      'verdict (temperloop#939 — the StructuredOutput return channel failed). The branch content',
      'below is ground truth read back from the worktree and the remote; the acceptance results',
      'are **unknown**, not passing.',
      '',
      `- probe stage: \`${probe.stage}\``,
      `- worktree HEAD: \`${probe.sha ?? 'unknown'}\``,
      `- branch on origin: ${probe.pushed ? 'yes' : 'no (pushed by the recovery path)'}`,
      `- open PR at probe time: ${probe.pr ? `#${probe.pr}` : 'none (opened by the recovery path)'}`,
      `- worker verification surface written: ${probe.surfacePresent ? 'yes' : 'no'}`,
      '',
      '**Reviewer action required:** verify each acceptance criterion above directly — do not',
      'read the unchecked boxes as failures, and do not read this PR as self-verified.',
    ].join('\n'),
  };
}

// --- 3c already-fixed continuation close (temperloop#2137) -------------------
//
// THE WASTE THIS CLOSES. A `review-blocking` escalation loops the item b — see build-level.design-notes-4.md#the-waste-this-closes-a-review-blocking-escalation-loops-the

// A reviewer's finding location, per the reviewer agents' own output format:
// `**Where:** <file:line or function name>`. Only the file:line form is usable
// here — the function-name form names no line to check.
const WHERE_LINE_RE = /^\s*\*{0,2}Where:?\*{0,2}\s*(.+?)\s*$/i;
const WHERE_LOCATION_RE = /(?:^|[\s(`"'])([A-Za-z0-9][A-Za-z0-9._/-]*):(\d{1,7})(?![0-9])/;
// The BLOCKING-finding heading, the same shape reviewHasBlockingFinding() reads.
const HIGH_HEADING_RE = /^\s*###\s*\[\s*HIGH\b/gim;
// A bound on how much one probe may check. Past it the findings text is not the
// shape this predicate was built to read, so it declines rather than guesses.
const CONTINUATION_FIX_MAX_LOCATIONS = 12;
// THE FINGERPRINT FLOOR, and why it is not cosmetic. The probe's evidence is
// "the exact text of the reviewed line is no longer anywhere in the file at the
// tip". For a line like `fi`, `}` or `done` that test is meaningless — such a
// line is present in almost any version of almost any file, so its ABSENCE
// would be the only informative answer and its absence is vanishingly unlikely
// to mean what the probe would read into it. Below this many non-space
// characters the line is declared too weak to be evidence and the probe returns
// UNKNOWN, i.e. spawns the worker.
const CONTINUATION_FIX_MIN_FINGERPRINT = 12;

// continuationFindingLocations(findingsText) — the parsed `{ file, line }` set,
// or [] meaning "cannot establish". Never partial: an all-or-nothing read, for
// the fail-closed reason above.
function continuationFindingLocations(findingsText) {
  const text = String(findingsText ?? '');
  if (!text.trim()) return [];
  const highCount = (text.match(HIGH_HEADING_RE) ?? []).length;
  const out = [];
  const seen = new Set();
  let whereLines = 0;
  for (const raw of text.split('\n')) {
    const w = raw.match(WHERE_LINE_RE);
    if (!w) continue;
    whereLines += 1;
    const loc = w[1].match(WHERE_LOCATION_RE);
    // A `**Where:**` that names no line (a function name, a prose locator)
    // leaves that finding unverifiable, so the whole set is unverifiable.
    if (!loc) return [];
    const file = loc[1];
    const line = Number(loc[2]);
    // Reject anything that is not a plain in-tree relative path, and any line
    // number that is not a positive integer. Both are belt AND suspenders: the
    // value is interpolated into a `git show <rev>:<path>` argument below, and
    // the charset the regex already enforces excludes every shell metacharacter
    // — this rejects the two shapes that charset still admits.
    if (file.startsWith('/') || file.includes('..') || !Number.isInteger(line) || line < 1) return [];
    const key = `${file}:${line}`;
    if (seen.has(key)) continue;
    seen.add(key);
    out.push({ file, line });
    if (out.length > CONTINUATION_FIX_MAX_LOCATIONS) return [];
  }
  if (out.length === 0) return [];
  // Every HIGH must have contributed a location. A HIGH with no `**Where:**` at
  // all is exactly the finding this probe would otherwise skip past unchecked.
  if (whereLines < highCount) return [];
  return out;
}

// continuationAlreadyFixedCmd(wt, locations) — ONE machinery call, no worker.
// Emits exactly one of the three closed outcomes declared in the spine schema.
function continuationAlreadyFixedCmd(wt, locations) {
  const emit = (outcome, detail) =>
    `printf '%s\\n' '{"outcome":"${outcome}","detail":"${detail}"}'`;
  const probes = locations.map((l) => `probe ${sq(l.file)} ${sq(String(l.line))}`);
  const matchesJson = JSON.stringify(locations.map((l) => `${l.file}:${l.line}`));
  return [
    `cd ${sq(wt)} 2>/dev/null || { ${emit('ALREADY_FIXED_UNKNOWN', 'worktree-unreadable')}; exit 0; }`,
    `gd="$(git rev-parse --git-dir 2>/dev/null || true)"`,
    `prior=""`,
    `if [ -n "$gd" ] && [ -f "$gd/build-review-rounds-sha" ]; then`,
    `  prior="$( { tr -cd '0-9a-fA-F' < "$gd/build-review-rounds-sha"; } 2>/dev/null )"`,
    `fi`,
    // The SAME floor and the SAME two resolution checks reviewDiffCmd applies
    // to this marker: 7 is git's own minimum abbreviation length, and `tr -cd`
    // is a FILTER, so a corrupted marker survives it as plausible-looking hex
    // that only the repo itself can reject.
    `if [ "${'${#prior}'}" -lt 7 ]; then prior=""; fi`,
    `if [ -n "$prior" ]; then`,
    `  if ! git rev-parse --verify --quiet "$prior^{commit}" >/dev/null 2>&1; then`,
    `    prior=""`,
    `  elif ! git merge-base --is-ancestor "$prior" HEAD >/dev/null 2>&1; then`,
    `    prior=""`,
    `  fi`,
    `fi`,
    `if [ -z "$prior" ]; then ${emit('ALREADY_FIXED_UNKNOWN', 'no-usable-prior-reviewed-sha')}; exit 0; fi`,
    `head_sha="$(git rev-parse --verify --quiet HEAD 2>/dev/null || true)"`,
    `prior_full="$(git rev-parse --verify --quiet "$prior^{commit}" 2>/dev/null || true)"`,
    `if [ -z "$head_sha" ]; then ${emit('ALREADY_FIXED_UNKNOWN', 'head-unreadable')}; exit 0; fi`,
    // The degenerate case, checked explicitly rather than left to fall out of
    // the per-location test: a tip identical to the reviewed commit carries
    // NOTHING new, so it cannot carry a fix.
    `if [ "$head_sha" = "$prior_full" ]; then ${emit('NOT_ALREADY_FIXED', 'tip-unchanged-since-the-reviewed-commit')}; exit 0; fi`,
    `old_f="$(mktemp 2>/dev/null)" || { ${emit('ALREADY_FIXED_UNKNOWN', 'mktemp-failed')}; exit 0; }`,
    `new_f="$(mktemp 2>/dev/null)" || { rm -f "$old_f"; ${emit('ALREADY_FIXED_UNKNOWN', 'mktemp-failed')}; exit 0; }`,
    `verdict=ALREADY_FIXED`,
    `detail=every-named-finding-line-is-gone-from-the-tip`,
    `probe() {`,
    `  f="$1"; n="$2"`,
    `  if [ "$verdict" != ALREADY_FIXED ]; then return 0; fi`,
    `  if ! git show "$prior:$f" > "$old_f" 2>/dev/null; then`,
    `    verdict=ALREADY_FIXED_UNKNOWN; detail="unreadable-at-prior-sha-$f"; return 0`,
    `  fi`,
    `  old="$(sed -n "${'${n}'}p" "$old_f")"`,
    `  old="$(printf '%s' "$old" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"`,
    `  if [ "${'${#old}'}" -lt ${CONTINUATION_FIX_MIN_FINGERPRINT} ]; then`,
    `    verdict=ALREADY_FIXED_UNKNOWN; detail="fingerprint-too-weak-$f-$n"; return 0`,
    `  fi`,
    `  if ! printf '%s' "$old" | grep -E '[A-Za-z0-9]' >/dev/null 2>&1; then`,
    `    verdict=ALREADY_FIXED_UNKNOWN; detail="fingerprint-not-alphanumeric-$f-$n"; return 0`,
    `  fi`,
    `  if ! git show "HEAD:$f" > "$new_f" 2>/dev/null; then`,
    `    verdict=ALREADY_FIXED_UNKNOWN; detail="unreadable-at-tip-$f"; return 0`,
    `  fi`,
    // `grep -F --` never `-q`: a `-q` here would SIGPIPE nothing (the input is a
    // file, not a pipe) but the repo lints the flag out at sweep scale rather
    // than per-site, so the sanctioned form is used everywhere (temperloop#1050).
    `  if grep -F -- "$old" "$new_f" >/dev/null 2>&1; then`,
    `    verdict=NOT_ALREADY_FIXED; detail="finding-line-still-present-$f-$n"; return 0`,
    `  fi`,
    `  return 0`,
    `}`,
    ...probes,
    `rm -f "$old_f" "$new_f"`,
    `printf '{"outcome":"%s","detail":"%s","sha":"%s","matches":%s}\\n' "$verdict" "$detail" "$prior_full" ${sq(matchesJson)}`,
  ].join('\n');
}

// continuationAlreadyFixed(item, wt, priorVerdict, phaseName) — the predicate the
// 3c dispatch calls. Returns `{ fixed, reason, locations, sha }`; `fixed` is true
// ONLY on a positively-established ALREADY_FIXED.
async function continuationAlreadyFixed(item, wt, priorVerdict, phaseName) {
  if (!priorVerdict || priorVerdict.kind !== 'review-blocking') {
    return { fixed: false, reason: 'not-a-review-blocking-continuation', locations: [] };
  }
  const locations = continuationFindingLocations(priorVerdict.verdict_section);
  if (locations.length === 0) {
    // No machinery call at all on this arm — the cheap read declines first, so
    // a continuation whose findings name no line costs exactly what it costs
    // today (one worker spawn, no extra executor).
    return { fixed: false, reason: 'no-usable-finding-location-in-the-prior-findings', locations: [] };
  }
  const out = await runMachinery(continuationAlreadyFixedCmd(wt, locations), {
    label: `already-fixed:${item.slug}`,
    slug: item.slug,
    phase: phaseName,
  });
  if (machineryDenied(out)) {
    return { fixed: false, reason: 'probe-denied', locations };
  }
  if (!out || out.outcome !== 'ALREADY_FIXED') {
    return {
      fixed: false,
      reason: out && typeof out.detail === 'string' && out.detail
        ? `${out.outcome ?? 'no-outcome'}: ${out.detail}`
        : String((out && out.outcome) ?? 'no-outcome'),
      locations,
    };
  }
  return {
    fixed: true,
    reason: typeof out.detail === 'string' ? out.detail : 'every-named-finding-line-is-gone-from-the-tip',
    locations,
    sha: typeof out.sha === 'string' ? out.sha : null,
  };
}

// alreadyFixedVerdict(item, probe) — the verdict record the skipped worker would
// have returned. Shaped exactly like recoveredVerdict() above, and for the same
// reason: each criterion carries a CRITERION and an EVIDENCE line and NO
// `passed` boolean, so §3d reads no failure into it and discriminationGaps()
// reads no unproven pass out of it. The acceptance behind this tree was already
// self-verified by the round that got the item as far as §3e in the first place
// (a `review-blocking` escalation happens strictly AFTER 3d passes), and the
// worker's own `.build-verification.md` is still on disk and still rides the PR
// via 3f's `--verification-surface-file` — so nothing is lost here, and the
// summary says so rather than leaving the reviewer to infer it.
const ALREADY_FIXED_EVIDENCE =
  'carried forward — verified by the earlier round on this same tree; no worker ran this round ' +
  '(temperloop#2137, already-fixed continuation close)';

function alreadyFixedVerdict(item, probe) {
  const criteria = acceptanceList(item);
  const located = (probe.locations ?? []).map((l) => `\`${l.file}:${l.line}\``).join(', ');
  const results = (criteria.length ? criteria : ['(no acceptance criteria carried on this plan item)']).map(
    (c) => ({
      criterion: typeof c === 'string' ? c : JSON.stringify(c),
      evidence: ALREADY_FIXED_EVIDENCE,
    }),
  );
  const summary =
    `**No implementation worker ran on this round (temperloop#2137).** This \`${item.slug}\` round ` +
    'resumed from a §3e `review-blocking` escalation, and the branch tip ALREADY carried the fix: for ' +
    `every line the prior round's blocking finding(s) named (${located || 'none recorded'}), the exact ` +
    `source line as it stood at the prior reviewed commit \`${probe.sha ?? 'unknown'}\` is no longer ` +
    'present anywhere in that file at the tip. Re-spawning an implementation worker could only have had ' +
    'it report "no source change", so the spawn was skipped and §3e was re-run on its own. Acceptance ' +
    'was self-verified by the earlier round on this same tree (a `review-blocking` escalation is raised ' +
    'only after §3d passes) and that round\'s verification surface is the one attached below; the ' +
    'per-criterion table is therefore carried forward rather than re-asserted.';
  return {
    status: 'done',
    alreadyFixed: true,
    summary,
    acceptance_results: results,
  };
}

// Per-item driver (3a–3h for ONE item). Returns either a `parked` record — see build-level.design-notes-3.md#per-item-driver-3a-3h-for-one-item-returns-either-a-par

// escalationRoundKind(kind) — the ROUND_KIND VOCABULARY (temperloop#2135 — see build-level.design-notes-2.md#escalationroundkind-kind-the-round-kind-vocabulary-temperloo
function escalationRoundKind(kind) {
  if (typeof kind !== 'string' || kind === '') return 'other';
  if (kind === 'review-blocking') return 'review';
  if (kind === 'acceptance-gate-timeout') return 'gate-timeout';
  if (kind === 'acceptance-gate-failed' || kind === 'acceptance-incomplete') return 'gate-fail';
  if (kind.startsWith('activation-')) return 'activation';
  // "the CI-failure kinds" (temperloop#2135's own acceptance language) are — see build-level.design-notes-2.md#the-ci-failure-kinds-temperloop-2135-s-own-acceptance-langua
  if (kind.startsWith('ci-')) return 'ci';
  return 'other';
}

// A small helper to build an escalation result (worktree stays intact). — see build-level.design-notes-3.md#a-small-helper-to-build-an-escalation-result-worktree-s
function escalate(slug, kind, payload) {
  return {
    _kind: 'escalation',
    slug,
    escalation: { slug, kind, payload, round_kind: escalationRoundKind(kind) },
  };
}

// The SIDELINE notice — the consumer half of worktree.sh's CREATED verdi — see build-level.design-notes-2.md#the-sideline-notice-the-consumer-half-of-worktree-sh-s-creat
const SIDELINE_NOTICES = new Map(); // slug → { path, branch, recovery }

// sidelineRecoveryCmd — NAME THE RECOVERY, not merely the event. A sidel — see build-level.design-notes-2.md#sidelinerecoverycmd-name-the-recovery-not-merely-the-event-a
function sidelineRecoveryCmd(path, branch) {
  const at = path || '(path not reported)';
  const inspect = `git -C ${sq(at)} log --oneline --stat origin/HEAD..HEAD`;
  return branch
    ? `${inspect}   # then keep it: git -C ${sq(at)} push -u origin ${sq(branch)}`
    : `${inspect}   # no branch survived the sideline — those commits are reachable only from this worktree's HEAD`;
}

// noteSideline — read the CREATED outcome's sideline verdict, and when i — see build-level.design-notes-3.md#notesideline-read-the-created-outcome-s-sideline-verdic
function noteSideline(slug, wtOut) {
  if (!wtOut || wtOut.sidelined !== true) return;
  const path = wtOut.sidelined_path ? String(wtOut.sidelined_path) : '';
  const branch = wtOut.sidelined_branch ? String(wtOut.sidelined_branch) : '';
  const recovery = sidelineRecoveryCmd(path, branch);
  SIDELINE_NOTICES.set(slug, { path, branch, recovery });
  log(
    `[${slug}] SIDELINED BUILD — worktree.sh create found committed work it could not preserve at the ` +
      `deterministic path and MOVED it aside instead of destroying it (temperloop#1730). ` +
      `The shelved build is at ${path || '(path not reported)'}` +
      (branch ? ` on branch ${branch}` : ' with no surviving branch') +
      `. This run is REBUILDING the item from scratch; the shelved build is not lost, and ` +
      `worktree.sh prune leaves it standing while its issue is open. Reclaim it with: ${recovery}`,
  );
}

// stampSideline — the ONE choke point where the notice is attached to wh — see build-level.design-notes-2.md#stampsideline-the-one-choke-point-where-the-notice-is-attach
function stampSideline(item, r) {
  const notice = SIDELINE_NOTICES.get(item.slug);
  if (!notice || !r) return r;
  if (r._kind === 'parked' && r.parked) {
    r.parked.sidelined = notice;
  } else if (r._kind === 'escalation' && r.escalation) {
    r.escalation.payload = { ...(r.escalation.payload ?? {}), sidelined: notice };
  }
  return r;
}

// preserveCommittedWorkCmd / preserveOnEscalation — temperloop#2020. — see build-level.design-notes-2.md#preservecommittedworkcmd-preserveonescalation-temperloop-202
function preserveCommittedWorkCmd(wt, branch) {
  return [
    // No worktree (an escalation from before 3b, e.g. claim-conflict) — ther — see build-level.design-notes-3.md#no-worktree-an-escalation-from-before-3b-e-g-claim-conf
    `if [ ! -d ${sq(wt)} ]; then printf '{"outcome":"WORK_PRESERVE_SKIP","detail":"no worktree"}\\n'; exit 0; fi`,
    `cd ${sq(wt)} || { printf '{"outcome":"WORK_PRESERVE_SKIP","detail":"worktree unreadable"}\\n'; exit 0; }`,
    // Same default_branch() fallback chain reviewDiffCmd uses, for the same — see build-level.design-notes-3.md#same-default-branch-fallback-chain-reviewdiffcmd-uses-f
    `default="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')"`,
    `if [ -z "$default" ]; then`,
    `  for b in main master; do`,
    `    if git show-ref --verify --quiet "refs/remotes/origin/$b"; then default="$b"; break; fi`,
    `  done`,
    `fi`,
    // NO `|| default=main` guess. worktree.sh's own default_branch() (its — see build-level.design-notes-2.md#no-default-main-guess-worktree-sh-s-own-default-branch-its
    `base_resolved=false`,
    `ahead=0`,
    `if [ -n "$default" ] && count="$(git rev-list --count "origin/$default..HEAD" 2>/dev/null)"; then`,
    `  case "$count" in ''|*[!0-9]*) : ;; *) base_resolved=true; ahead="$count" ;; esac`,
    `fi`,
    `branch=${sq(branch)}`,
    // `$branch` goes into the hand-built JSON below through a bare printf — see build-level.design-notes-2.md#branch-goes-into-the-hand-built-json-below-through-a-bare-pr
    `if [ "$base_resolved" = true ] && [ "$ahead" = 0 ]; then`,
    `  printf '{"outcome":"WORK_PRESERVE_SKIP","branch":"%s","base_resolved":true,"commits_ahead":0,"detail":"no unlanded commits"}\\n' "$branch"`,
    `  exit 0`,
    `fi`,
    // The count rides along only when it is real; on the unresolved arm the — see build-level.design-notes-3.md#the-count-rides-along-only-when-it-is-real-on-the-unres
    `if [ "$base_resolved" = true ]; then`,
    `  extra=",\\"commits_ahead\\":$ahead"`,
    `else`,
    `  extra=",\\"detail\\":\\"base unresolved — pushed unconditionally\\""`,
    `fi`,
    // temperloop#2103 — THE REBASED-BRANCH-ALREADY-ON-ORIGIN ARM. — see build-level.design-notes-2.md#temperloop-2103-the-rebased-branch-already-on-origin-arm
    `head_sha="$(git rev-parse HEAD 2>/dev/null || true)"`,
    `case "$head_sha" in *[!0-9a-f]*) head_sha="" ;; esac`,
    `remote_sha="$(git ls-remote origin "refs/heads/$branch" 2>/dev/null | awk 'NR==1 {print $1}')"`,
    `case "$remote_sha" in ''|*[!0-9a-f]*) remote_sha="" ;; esac`,
    `pushed=false`,
    `forced=false`,
    `refused=false`,
    `probe_failed=false`,
    `if git push origin "HEAD:refs/heads/$branch" >/dev/null 2>&1; then`,
    `  pushed=true`,
    `elif [ -n "$remote_sha" ] && [ -n "$head_sha" ] && [ "$remote_sha" != "$head_sha" ]; then`,
    // Bring the remote tip's objects local so the supersede test can run at — see build-level.design-notes-3.md#bring-the-remote-tip-s-objects-local-so-the-supersede-test-c
    `  unique=""`,
    `  if git fetch --quiet origin "refs/heads/$branch" >/dev/null 2>&1; then`,
    `    unique="$(git rev-list --count --cherry-pick --right-only --no-merges "HEAD...$remote_sha" 2>/dev/null || true)"`,
    `  fi`,
    `  case "$unique" in ''|*[!0-9]*) unique="" ;; esac`,
    `  if [ "$unique" = 0 ]; then`,
    `    if git push --force-with-lease="refs/heads/$branch:$remote_sha" origin "HEAD:refs/heads/$branch" >/dev/null 2>&1; then`,
    `      pushed=true; forced=true`,
    `    fi`,
    `  elif [ -n "$unique" ]; then`,
    `    refused=true`,
    `  else`,
    `    probe_failed=true`,
    `  fi`,
    `fi`,
    // The outcome is the REMOTE's answer, not the push's. Re-read the ref: t — see build-level.design-notes-3.md#the-outcome-is-the-remote-s-answer-not-the-push-s-re-re
    `final_sha="$(git ls-remote origin "refs/heads/$branch" 2>/dev/null | awk 'NR==1 {print $1}')"`,
    `case "$final_sha" in ''|*[!0-9a-f]*) final_sha="" ;; esac`,
    `if [ -n "$head_sha" ] && [ "$final_sha" = "$head_sha" ]; then outcome=WORK_PRESERVED; else outcome=WORK_PRESERVE_FAILED; fi`,
    // `if` rather than `[ … ] && …`: a trailing AND-list that evaluates fals — see build-level.design-notes-3.md#if-rather-than-a-trailing-and-list-that-evaluates-fals
    `facts=""`,
    `if [ -n "$head_sha" ]; then facts="$facts,\\"head_sha\\":\\"$head_sha\\""; fi`,
    `if [ -n "$final_sha" ]; then facts="$facts,\\"remote_sha\\":\\"$final_sha\\""; fi`,
    `if [ "$forced" = true ]; then facts="$facts,\\"forced_with_lease\\":true,\\"rewrote_remote\\":\\"$remote_sha\\""; fi`,
    `if [ "$refused" = true ]; then facts="$facts,\\"stale_remote_not_superseded\\":true"; fi`,
    `if [ "$probe_failed" = true ]; then facts="$facts,\\"supersede_probe_failed\\":true"; fi`,
    `printf '{"outcome":"%s","branch":"%s","base_resolved":%s,"pushed":%s%s%s}\\n' "$outcome" "$branch" "$base_resolved" "$pushed" "$extra" "$facts"`,
  ].join('\n');
}

// preserveOnEscalation(item, result) — the ONE choke point. Applied at t — see build-level.design-notes-3.md#preserveonescalation-item-result-the-one-choke-point-applied
async function preserveOnEscalation(item, result) {
  if (!result || result._kind !== 'escalation') return result;
  const wt = `${input.repoRoot}.wt/${item.slug}`;
  // The plan's branch — the ref 3f pushes — not the worktree's local — see build-level.design-notes-3.md#the-plan-s-branch-the-ref-3f-pushes-not-the-worktree-s-
  const preserveBranch = item?.branch || `build/${item.slug}`;
  let out;
  try {
    out = await runMachinery(preserveCommittedWorkCmd(wt, preserveBranch), {
      label: `preserve-push:${item.slug}`,
      slug: item.slug,
    });
  } catch (err) {
    out = { outcome: 'ERROR', error: String((err && err.message) || err) };
  }
  const outcome = String(out?.outcome ?? 'ERROR');
  // `committed_work` is a FACT the escalation carries, never a verdict: it
  // says what is (or is not) on origin, so the human or agent disposing this
  // escalation decides about removal against evidence instead of an assumption
  // that "the worktree stays intact" means the work is safe.
  //
  // temperloop#2103 — `head_sha`/`remote_sha` ride the record because NEITHER
  // `preserved` nor "the branch exists on origin" is sufficient alone: the live
  // third occurrence had a stale pre-rebase sha sitting on the remote while the
  // flag read false, so one signal overstated and the other understated. With
  // both shas present a caller can settle it by comparison instead of guessing.
  const record = {
    outcome,
    branch: out?.branch ?? preserveBranch,
    preserved: outcome === 'WORK_PRESERVED',
    ...(out?.commits_ahead === undefined ? {} : { commits_ahead: out.commits_ahead }),
    ...(out?.head_sha ? { head_sha: out.head_sha } : {}),
    ...(out?.remote_sha ? { remote_sha: out.remote_sha } : {}),
    ...(out?.forced_with_lease ? { forced_with_lease: true, rewrote_remote: out.rewrote_remote } : {}),
    ...(out?.stale_remote_not_superseded ? { stale_remote_not_superseded: true } : {}),
    ...(out?.supersede_probe_failed ? { supersede_probe_failed: true } : {}),
    ...(out?.detail ? { detail: out.detail } : {}),
  };
  if (outcome === 'WORK_PRESERVED') {
    log(
      `[${item.slug}] escalating — pushed ${record.branch} to origin first (temperloop#2020): ` +
        `committed work is durable regardless of what disposes this escalation` +
        (record.forced_with_lease
          ? ` — the branch was already on origin at ${String(record.rewrote_remote).slice(0, 8)} ` +
            `(a pre-rebase copy of this same work), so the push was a LEASED force over it (temperloop#2103)`
          : ''),
    );
  } else if (outcome !== 'WORK_PRESERVE_SKIP') {
    log(
      `[${item.slug}] escalating — could NOT preserve committed work (${outcome}): ` +
        `the worktree may be the ONLY copy — do not remove it` +
        (record.stale_remote_not_superseded
          ? ` — origin's ${record.branch} is at ${String(record.remote_sha).slice(0, 8)} and carries commits this ` +
            `worktree does NOT, so the rescue push was REFUSED rather than overwrite them. Reconcile by hand ` +
            `(merge or confirm supersession), then: git push --force-with-lease=refs/heads/${record.branch}:${record.remote_sha} origin HEAD:refs/heads/${record.branch}`
          : '') +
        // NOT the sentence above. The refusal was the same, the reason is not: — see build-level.design-notes-3.md#not-the-sentence-above-the-refusal-was-the-same-the-rea
        (record.supersede_probe_failed
          ? ` — origin's ${record.branch} is at ${String(record.remote_sha).slice(0, 8)}, which differs from this ` +
            `worktree's HEAD, but whether this worktree's history supersedes it could NOT be established (the ` +
            `check could not reach origin). The rescue push was REFUSED on that uncertainty — no conflict is ` +
            `claimed here. Re-run the check by hand first (git fetch origin ${record.branch}), and only then ` +
            `decide whether to merge or to force over it`
          : ''),
    );
  }
  result.escalation.payload = { ...(result.escalation.payload ?? {}), committed_work: record };
  return result;
}

// 3e.5 gate verdict reconciliation (temperloop#1587) — see build-level.design-notes-3.md#3e-5-gate-verdict-reconciliation-temperloop-1587

// gateSliceFailed(out) — the failure count ONE slice actually ESTABLISHE — see build-level.design-notes-3.md#gateslicefailed-out-the-failure-count-one-slice-actually-est
function gateSliceFailed(out) {
  if (!out) return 0;
  if (out.outcome === 'GATE_FAIL') return Math.max(1, Number(out.failed) || 0);
  if (out.outcome === 'GATE_SLICE') return Math.max(0, Number(out.failed) || 0);
  return 0;
}

// gateSliceResumeAt(out) — the 0-based gate index ONE slice said the sui — see build-level.design-notes-3.md#gatesliceresumeat-out-the-0-based-gate-index-one-slice-said-
function gateSliceResumeAt(out) {
  if (!out) return undefined;
  const n = Number(out.resumeAt);
  return Number.isFinite(n) && n > 0 ? n : undefined;
}

// gateInFlightIndex(ledger) — WHICH gate the stopped run was ON (temperlo — see build-level.design-notes-6.md#gateinflightindex-ledger-which-gate-the-stopped-run-was-on-t
function gateInFlightIndex(ledger) {
  const last = Array.isArray(ledger) && ledger.length > 0 ? ledger[ledger.length - 1] : null;
  if (!last) return undefined;
  // A slice that REPORTED a resume point stopped cleanly BEFORE that index.
  const resume = gateSliceResumeAt(last);
  if (resume !== undefined) return resume;
  // A KILLED slice never reported: it began at `startAt`, so the overrun is there or after it.
  const startAt = Number(last.startAt);
  return Number.isFinite(startAt) && startAt >= 0 ? startAt : undefined;
}

// gateSliceClampNote() — what raising BUILD_GATE_SLICE_SECS can ACTUALLY  — see build-level.design-notes-6.md#gatesliceclampnote-what-raising-build-gate-slice-secs-can-act
function gateSliceClampNote() {
  const derived =
    `GATE_BASH_TIMEOUT_MS (${GATE_BASH_TIMEOUT_MS}ms, the deadline that killed the slice) is DERIVED from ` +
    `BUILD_GATE_SLICE_SECS — slice*1000 + ${GATE_SLICE_OVERRUN_MS}ms of between-gate overrun, 1.8x the slice at the ` +
    `${GATE_SLICE_SECS_DEFAULT}s default — and is itself clamped to AGENT_BASH_CAP_MS (${AGENT_BASH_CAP_MS}ms), the ` +
    `agent's hard foreground-Bash ceiling`;
  if (GATE_SLICE_SECS >= Math.floor(GATE_SLICE_SECS_MAX * GATE_SLICE_CLAMP_NEAR_RATIO)) {
    return `${derived}. BUILD_GATE_SLICE_SECS is ALREADY AT its clamp (${GATE_SLICE_SECS}s of a ` +
      `${GATE_SLICE_SECS_MAX}s maximum) — do NOT raise it, there is no headroom left to raise it into`;
  }
  return `${derived}. So BUILD_GATE_SLICE_SECS is CLAMPED: it can rise only ${GATE_SLICE_SECS}s -> ` +
    `${GATE_SLICE_SECS_MAX}s (+${Math.round((GATE_SLICE_SECS_MAX / GATE_SLICE_SECS - 1) * 100)}%), moving the kill ` +
    `deadline just ${GATE_BASH_TIMEOUT_MS}ms -> ${AGENT_BASH_CAP_MS}ms ` +
    `(+${Math.round((AGENT_BASH_CAP_MS / GATE_BASH_TIMEOUT_MS - 1) * 100)}%) — a one-time bounded gain, not a lever that scales`;
}

// gateUnknownRemedy(terminalOutcome, inFlight, slices) — the TWO failure  — see build-level.design-notes-6.md#gateunknownremedy-terminaloutcome-inflight-slices-the-two-fai
function gateUnknownRemedy(terminalOutcome, inFlight, slices) {
  const where = inFlight
    ? `The run stopped on gate ${inFlight.index} of the pinned selection` +
      (inFlight.gate ? ` — \`${inFlight.gate}\`.` : ` (name it with: ${inFlight.resolve}).`)
    : 'The gate in flight could not be identified from the slice ledger.';
  const clamp = gateSliceClampNote();
  if (terminalOutcome === 'GATE_TIMEOUT') {
    return `ONE SLOW GATE, not an aggregate-slow suite: the slice budget is honoured only BETWEEN gates, so the cap ` +
      `fired because a SINGLE gate ran past the whole ${GATE_BASH_TIMEOUT_MS}ms window. ${where} More slice budget ` +
      `CANNOT fix this shape — ${clamp}. Fix that gate instead: split it, speed it up, or narrow what reaches it; ` +
      `then re-run the gate to get a real verdict.`;
  }
  if (terminalOutcome === 'GATE_SLICE') {
    return `AGGREGATE-SLOW SUITE, not one overrunning gate: every slice returned cleanly and the run simply ran out ` +
      `of slices (${slices} x ${GATE_SLICE_SECS}s). ${where} MORE gate wall time genuinely helps this shape: raise ` +
      `BUILD_GATE_SLICE_SECS (${clamp}), and/or the slice ceiling (GATE_MAX_SLICES ${GATE_MAX_SLICES}, ` +
      `GATE_RESUME_EXTENSIONS ${GATE_RESUME_EXTENSIONS}), or split the gate list; then re-run the gate to get a real verdict.`;
  }
  return `NEITHER failure shape is established: the gate returned '${terminalOutcome}' and no verdict. ${where} Read ` +
    `the gate log before tuning any budget — raising one from here would be a guess.`;
}

// gateVerdict(terminalOutcome, ledger) — the ONE reconciliation point be — see build-level.design-notes-3.md#gateverdict-terminaloutcome-ledger-the-one-reconciliation-po
function gateVerdict(terminalOutcome, ledger) {
  // temperloop#2133 (a §3e review finding on the #2135 branch, no issue of its
  // own): read the ledger's failure count STRICTLY. `Number(x) || 0` collapses
  // BOTH `null` and `NaN` to 0 — the same laundering temperloop#1698 fixed for
  // elapsedSecs — so the day gateSliceFailed()'s contract grows an
  // "unreadable failure count" sentinel, an UNKNOWN count would read as a known
  // zero. The rule, applied at all three ledger-reading sites: a non-finite count
  // is never a known zero. Identical to the prior expression for every finite
  // input, which is all the single-writer ledger produces today.
  const failedGates = ledger.reduce((n, s) => n + (Number.isFinite(s.failed) ? s.failed : 0), 0);
  const failedInSlices = ledger
    .filter((s) => !Number.isFinite(s.failed) || s.failed > 0)
    .map((s) => s.slice);
  // A resume point in the LAST ledger entry is direct evidence that gates — see build-level.design-notes-3.md#a-resume-point-in-the-last-ledger-entry-is-direct-evidence-t
  const lastSliceResumeAt = ledger.length > 0
    ? gateSliceResumeAt(ledger[ledger.length - 1])
    : undefined;
  const finished = lastSliceResumeAt === undefined
    && (terminalOutcome === 'GATE_PASS'
      || terminalOutcome === 'GATE_FAIL'
      || terminalOutcome === 'GATE_ABSENT');
  let unfinished;
  if (terminalOutcome === 'GATE_TIMEOUT') {
    unfinished = `the quality-gates slice was killed by the executor's ${GATE_BASH_TIMEOUT_MS}ms Bash-tool timeout before it could report — a BUDGET exhaustion, NOT a gate failure`;
  } else if (terminalOutcome === 'GATE_SLICE') {
    // temperloop#2135: the LEDGER's own length, not the static GATE_MAX_SLIC — see build-level.design-notes-3.md#temperloop-2135-the-ledger-s-own-length-not-the-static-
    unfinished = `the suite did not finish within ${ledger.length} slice(s) of ${GATE_SLICE_SECS}s (~${Math.round(ledger.length * GATE_SLICE_SECS / 60)} min of gate wall time) — a BUDGET exhaustion, NOT a gate failure`;
  } else if (lastSliceResumeAt !== undefined) {
    // temperloop#2094: a terminal outcome whose NAME says "done" over a fina — see build-level.design-notes-3.md#temperloop-2094-a-terminal-outcome-whose-name-says-done
    unfinished = `the final slice reported a resume point (gate ${lastSliceResumeAt}) — gates REMAINED when the run stopped, so the suite did NOT finish, whatever its terminal outcome '${terminalOutcome}' is named`;
  } else {
    // Neither a finished verdict nor a recognized budget outcome: the execut — see build-level.design-notes-3.md#neither-a-finished-verdict-nor-a-recognized-budget-outcome-t
    unfinished = `the gate returned an unrecognized outcome '${terminalOutcome}' — no verdict was established (this is NOT a pass, and NOT a known budget exhaustion)`;
  }
  const found = `${failedGates} gate failure(s) recorded in slice(s) ${failedInSlices.join(', ')}`;

  if (failedGates > 0) {
    let reason;
    if (finished && terminalOutcome === 'GATE_FAIL') {
      reason = `the suite exited RED — ${found}`;
    } else if (finished) {
      // The temperloop#1587 shape: the FINAL slice passed, so the log's last — see build-level.design-notes-3.md#the-temperloop-1587-shape-the-final-slice-passed-so-the
      reason = `${found}; the FINAL slice reported ${terminalOutcome}, but its green line covers ONLY the gates that slice ran — the suite as a whole is RED`;
    } else {
      reason = `${found} BEFORE the run stopped early — ${unfinished}. The gates that never ran have no verdict, but the recorded failures are real, so the branch is known-RED, not unknown`;
    }
    return { verdict: 'RED', finished, failedGates, failedInSlices, reason };
  }
  if (!finished) {
    return {
      verdict: 'UNKNOWN',
      finished,
      failedGates: 0,
      failedInSlices,
      reason: `${unfinished}; no gate failed in the slices that DID run, and the suite's overall verdict is unknown`,
    };
  }
  return {
    verdict: 'GREEN',
    finished,
    failedGates: 0,
    failedInSlices,
    reason: `the suite finished and every gate passed (terminal outcome ${terminalOutcome})`,
  };
}

// discriminationGaps — the temperloop#1319 DEGRADED CASE. WORKER_VERDICT_SCHEMA
// does not (and per the "advisory, never a new blocking gate" ask, must not)
// mark `discrimination_evidence` required, §3d branches solely on `.status`,
// and §3e.5 never looks at it — so a worker that simply OMITS the field on an
// otherwise-`passed: true` entry produces a `done` verdict that sails through
// the whole pipeline and renders a PR body indistinguishable from "not
// applicable" or a pre-#1319 PR. THIS is the load-bearing half criterion 2
// actually requires: a missing field must be a NAMED, VISIBLE degradation, not
// a silent one. Mirrors the pre-existing `verification_surface` degraded-case
// pattern (build.md §3f step 2, "Surface the degraded case") exactly — a
// legible warning, never a hard failure (kernel principle 7, advisory over
// enforced discipline): a `passed: false`/`blocked`/`failed` entry is
// untouched (only a CLAIMED pass with no proof is suspect).
//
// Gated on REQUIRE_DISCRIMINATION_EVIDENCE — an unarmed run (today: /sweep,
// /fix) never required the field in the first place, so it has nothing to
// degrade FROM and this returns empty unconditionally, exactly like
// discriminationEvidenceSection() above.
function discriminationGaps(verdict) {
  if (!REQUIRE_DISCRIMINATION_EVIDENCE) return [];
  return (verdict.acceptance_results ?? [])
    .filter((r) => r && r.passed === true && !(r.discrimination_evidence && String(r.discrimination_evidence).trim()))
    .map((r) => (r.criterion ? String(r.criterion) : '(unlabeled criterion)'));
}

// isHostConfigDeferral / hostConfigDeferrals — the temperloop#1182 DEFERRAL,
// the THIRD disposition an acceptance criterion can carry. `passed` is a
// boolean and a worktree can never observe a gitignored host-local file, so
// without a third state a host-config criterion has only two bad answers: a
// claimed pass the worker structurally could not make, or a `passed: false`
// §3d reads as blocked and stalls the whole level on a check that was never
// runnable here (foundation#1556 — the worker escalated
// `acceptance-incomplete` over a `credential_present: false` that read `true`
// in both real checkouts moments later).
//
// The marker is the PAIR (`passed: false` + a non-empty `deferred_host_config`)
// so neither half alone changes anything: a bare `passed: false` still blocks
// exactly as before, and the marker on its own never manufactures a pass. It
// is deliberately NOT gated on a run-level flag — the worktree-vs-index fact
// it encodes is true on every path that spawns a worker.
function isHostConfigDeferral(r) {
  return !!(r && typeof r.deferred_host_config === 'string' && r.deferred_host_config.trim());
}

// The parked-record tally: [{ criterion, host_config }]. `host_config` c — see build-level.design-notes-3.md#the-parked-record-tally-criterion-host-config-host-conf
function hostConfigDeferrals(acceptanceResults) {
  return (acceptanceResults ?? []).filter(isHostConfigDeferral).map((r) => ({
    criterion: r.criterion ? String(r.criterion) : '(unlabeled criterion)',
    host_config: String(r.deferred_host_config).trim(),
  }));
}

// park()'s trailing three arguments (discriminationGapList, review, cost — see build-level.design-notes-3.md#park-s-trailing-three-arguments-discriminationgaplist-review
function park(slug, pr, pushedSha, acceptanceResults, noCi, recovery, discriminationGapList, review, cost) {
  const parked = { slug, pr, pushed_sha: pushedSha, acceptance_results: acceptanceResults ?? [] };
  // temperloop#939: a record reconstructed from observable side-effects after a
  // lost worker return carries its provenance EXPLICITLY. `acceptance_unverified`
  // is the load-bearing half — the acceptance results in this record are
  // UNKNOWN, not passing, and the orchestrator must verify them itself before
  // the merge gate rather than assuming the 3d self-check ran.
  if (recovery) {
    parked.acceptance_unverified = true;
    parked.recovered_from = recovery.stage;
  }
  // temperloop#605/#618: a NO_CI-outcome item parks identically to a green — see build-level.design-notes-3.md#temperloop-605-618-a-no-ci-outcome-item-parks-identically-to
  if (noCi === true) parked.no_ci = true;
  // temperloop#1319: the degraded-case tally, same durable-marker shape as — see build-level.design-notes-3.md#temperloop-1319-the-degraded-case-tally-same-durable-marker-
  if (discriminationGapList && discriminationGapList.length > 0) {
    parked.discrimination_gaps = discriminationGapList;
  }
  // temperloop#1450 — the §3e Step 6 tally build.md §3e promises needs
  // SOMEWHERE to read from. `review` is reviewTally()'d { ran, skipped,
  // mandatory_ok, routed_not_run } across every review round this item's
  // build actually ran (the 3e pass plus any CI-fix re-review) — absent for a
  // spike (skips 3b-3h, never reviews) or omitted by an older call site.
  // `mandatory_ok` is false iff a mandatory (foundation#1007) route was ever
  // genuinely skipped, not merely "an optional reviewer wasn't available";
  // `routed_not_run` (temperloop#1984) names every reviewer the routing
  // resolved that did not run, mandatory or not, so the tally cannot read
  // fully clean while a tsv-routed reviewer was skipped. See reviewTally().
  if (review) parked.review = review;
  // temperloop#2065 "worker-cost-capture" (epic #2062's dual-build ledger) —
  // per-item worker cost: tokens, wall-clock, retry cost and a `recovery`
  // flag, captured at callWorker()/ciPollLoop()'s emitted-shell seam (see
  // workerClockNow()/workerUsageEmit() above) and reconciled against the
  // model-usage envelope (workflows/scripts/build/worker-usage.sh →
  // model-usage-envelope.sh's model_usage_emit_from_envelope, seat
  // "build-worker"). `cost.recovery` is this record's OWN plain-boolean
  // projection of the `recovery` PARAMETER above (a probe object, or null) —
  // a DIFFERENT thing from `recovered_from`/`acceptance_unverified`, which
  // name WHICH stage the temperloop#939 probe landed at; `recovery` here only
  // says whether the cost figures above are trustworthy (a recovered record
  // never observed the worker's own return, so its tokens/wall-clock are
  // whatever the LOST call still managed to report through the fail-open
  // seam, never fabricated). Present iff the caller passed `cost` — the
  // spike call site (4 args) omits it, so a spike's parked record stays
  // byte-identical to before this item; the 3h main path always passes it,
  // so EVERY non-spike parked record carries all six keys, present even at
  // their null/zero baseline (never conditionally omitted like `no_ci`
  // above — a cost ledger with silently-missing rows is worse than one with
  // honest nulls).
  if (cost) {
    parked.tokens_in = cost.tokens_in ?? null;
    parked.tokens_out = cost.tokens_out ?? null;
    parked.wall_clock_ms = cost.wall_clock_ms ?? null;
    parked.retry_tokens = cost.retry_tokens ?? null;
    parked.retry_count = cost.retry_count ?? 0;
    parked.recovery = !!cost.recovery;
  }
  // temperloop#1182: derived from `acceptanceResults` rather than threaded in
  // as a 9th positional argument, so BOTH park() call sites (the 3h main path
  // and the spike path at 3b, which passes only four arguments) surface the
  // deferrals without a signature change. Same durable-marker shape as
  // `no_ci`/`discrimination_gaps` — omitted entirely when empty, so a run with
  // no host-config criterion produces byte-identical parked records to before.
  // NOT advisory, unlike discrimination_gaps: these criteria are UNVERIFIED
  // (the `acceptance_unverified` family), and the invoking spec's parent-side
  // seat must verify each one before the item is eligible to merge — build.md
  // §4a, sweep.md's per-chunk merge pass, or fix.md Step 5 (the seat list in
  // the I/O CONTRACT header). build.md §3h.5's as-you-go tier is INELIGIBLE
  // for an item carrying this field: that path never reaches §4a.
  const hostDeferrals = hostConfigDeferrals(acceptanceResults);
  if (hostDeferrals.length > 0) parked.host_config_deferrals = hostDeferrals;
  return {
    _kind: 'parked',
    slug,
    parked,
  };
}

// machineryDenied — a machinery step returned no usable outcome. runMach — see build-level.design-notes-3.md#machinerydenied-a-machinery-step-returned-no-usable-outcome-
function machineryDenied(out) {
  return out == null || out.outcome === 'SPINE_DENIED';
}

// Session-quota death classification (temperloop#1819). — see build-level.design-notes-3.md#session-quota-death-classification-temperloop-1819
const QUOTA_KIND = 'quota-exhausted';
const QUOTA_DEATH_RE =
  /\b(?:hit|reached|exceeded)\s+(?:your|the)\s+(?:session|usage|weekly|monthly|5-?hour|rate)\s+limit\b/i;

// quotaDeath — null when `text` is not the harness's quota-death message — see build-level.design-notes-3.md#quotadeath-null-when-text-is-not-the-harness-s-quota-de
function quotaDeath(text) {
  const s = String(text ?? '');
  if (!QUOTA_DEATH_RE.test(s)) return null;
  const m = s.match(/\bresets?\b[\s·:,–—-]*([^\n]+)/i);
  return { reset: m ? m[1].trim() : null };
}

// harnessCanSpawnAgents — the null-shape discriminator above. Memoizatio — see build-level.design-notes-3.md#harnesscanspawnagents-the-null-shape-discriminator-above-mem
let agentLivenessCheck = null;
function harnessCanSpawnAgents() {
  if (!agentLivenessCheck) {
    agentLivenessCheck = (async () => {
      try {
        const out = await agent(
          'Liveness probe: do nothing except return the JSON object {"ok": true} via StructuredOutput.',
          {
            label: 'canary:quota-probe',
            // Off-path diagnostic (temperloop#1294) — own group, cursor untouched.
            phase: stagePhase(STAGE_RECOVER),
            model: input.machinerySoloModel || 'haiku',
            schema: { type: 'object', properties: { ok: { type: 'boolean' } }, required: ['ok'] },
          },
        );
        return out != null;
      } catch (err) {
        return !quotaDeath(String((err && err.message) || err));
      }
    })().then((alive) => {
      // Alive → drop the cache so the NEXT bare-null probes afresh; dead → — see build-level.design-notes-3.md#alive-drop-the-cache-so-the-next-bare-null-probes-afres
      if (alive) agentLivenessCheck = null;
      return alive;
    });
  }
  return agentLivenessCheck;
}

// quotaEscalation — the quota-exhausted escalation record. `worktree_lef — see build-level.design-notes-3.md#quotaescalation-the-quota-exhausted-escalation-record-w
function quotaEscalation(slug, where, { errorText = null, worktree = null, extra = null } = {}) {
  const qd = errorText ? quotaDeath(errorText) : null;
  return escalate(slug, QUOTA_KIND, {
    where,
    classified_by: errorText ? 'error-text' : 'agent-liveness-canary',
    reset_time: qd ? qd.reset : null,
    error: errorText,
    worktree,
    worktree_left_intact: true,
    retryable: true,
    reason:
      'the harness session-usage quota ran out mid-run (temperloop#1819) — an ENVIRONMENTAL death, ' +
      'not a classifier refusal (machinery-denied) and not a content failure (worker-error): ' +
      'nothing was cleaned up, so any work the item had produced is still in the worktree' +
      (qd && qd.reset
        ? `; the quota resets ${qd.reset}`
        : '; no reset time was reported — check quota-gate.sh / ~/.claude/rate-limits.json') +
      '. Wait for the reset, then inspect the worktree (pr.sh recover-probe) and RESUME what landed ' +
      'rather than re-driving from scratch.',
    ...(extra ?? {}),
  });
}

// deniedOrQuota — every site that mints a `machinery-denied` escalation  — see build-level.design-notes-3.md#deniedorquota-every-site-that-mints-a-machinery-denied-
async function deniedOrQuota(slug, payload, worktree) {
  if (!(await harnessCanSpawnAgents())) {
    const step = typeof payload.step === 'string' ? payload.step : 'batch';
    return quotaEscalation(slug, `machinery:${step}`, {
      worktree,
      extra: { denied_out: payload.out ?? null, ...(payload.sha !== undefined ? { sha: payload.sha } : {}) },
    });
  }
  return escalate(slug, 'machinery-denied', payload);
}

// -----------------------------------------------------------------------------
// §3e — the mandatory/routed pre-push review (temperloop#1430).
// -----------------------------------------------------------------------------
// build.md §3e's routing rules, run for REAL inside this driver — see that
// section's own "why this runs inside the workflow" paragraph for the
// orchestrator↔workflow-boundary rationale. Before this item the review lived
// only as worker-discretion prose: the 3c worker CANNOT spawn a nested
// `agent({agentType})` (the "No context-inheriting research forks" contract in
// workerPrompt() forbids exactly that shape), so the mandatory
// `claude/commands/*.md` → `workflow-reviewer` rule (foundation#1007) could
// never actually run on the default Workflow path — every command-doc PR
// reported a STRUCTURALLY GUARANTEED "skipped — unavailable", which read as a
// legible degradation but was in fact a permanent no-op. This driver spawns
// the reviewer itself, so the same skip notice now fires only when the
// reviewer genuinely fails to resolve.

// reviewDiffCmd — ONE solo runMachinery call that reads the two raw inpu — see build-level.design-notes.md#reviewdiffcmd-one-solo-runmachinery-call-that-reads-the-two-
function reviewDiffCmd(wt, bump = true) {
  const tsvPath = `${wt}/workflows/scripts/config/reviewer-routing.tsv`;
  // The row-filter awk program (blank/`#` lines stripped) is reused for BOTH
  // tsv_rows (count) and tsv_checksum (position-weighted byte-sum via `od`)
  // — one filter definition, two consumers, so the two can never disagree
  // on WHICH lines count.
  const rowFilterAwk =
    `BEGIN{c=0} { l=$0; sub(/\\r$/,"",l); t=l; gsub(/^[ \\t]+|[ \\t]+$/,"",t); if (t != "" && substr(t,1,1) != "#") print l }`;
  return [
    `cd ${sq(wt)} || exit 1`,
    `rounds_file=""`,
    `gd="$(git rev-parse --git-dir 2>/dev/null)"`,
    `[ -n "$gd" ] && rounds_file="$gd/build-review-rounds"`,
    `review_rounds=0`,
    // DECIMAL, NEVER OCTAL (temperloop#1970, typescript-reviewer round 1). T — see build-level.design-notes-3.md#decimal-never-octal-temperloop-1970-typescript-reviewer-roun
    `if [ -n "$rounds_file" ] && [ -f "$rounds_file" ]; then`,
    `  review_rounds="$( { tr -cd '0-9' < "$rounds_file"; } 2>/dev/null | sed -E 's/^0+//')"`,
    `fi`,
    `[ -n "$review_rounds" ] || review_rounds=0`,
    // temperloop#2127 — the PRIOR reviewed SHA, kept beside build-review-rou — see build-level.design-notes-5.md#temperloop-2127-the-prior-reviewed-sha-kept-beside-build-rev
    `sha_file=""`,
    `[ -n "$gd" ] && sha_file="$gd/build-review-rounds-sha"`,
    `review_prior_sha=""`,
    `if [ -n "$sha_file" ] && [ -f "$sha_file" ]; then`,
    `  review_prior_sha="$( { tr -cd '0-9a-fA-F' < "$sha_file"; } 2>/dev/null )"`,
    `fi`,
    `if [ -n "$review_prior_sha" ]; then`,
    `  if ! git rev-parse --verify --quiet "$review_prior_sha^{commit}" >/dev/null 2>&1; then`,
    `    review_prior_sha=""`,
    `  elif ! git merge-base --is-ancestor "$review_prior_sha" HEAD >/dev/null 2>&1; then`,
    `    review_prior_sha=""`,
    `  fi`,
    `fi`,
    // temperloop#2129 — the DELTA the prior round did not see: the files that
    // changed between the commit the prior round reviewed and this round's
    // HEAD. `files` above is the whole branch diff against origin/<default>
    // and is what the ROUTING decision reads; this narrower list is what the
    // continuation-round CARRY decision reads (reviewCarryForward), so a seat
    // whose routed files are all absent from it is not re-spawned.
    //
    // Computed HERE, from the SAME validated `review_prior_sha` the field
    // above emits — never from a second, independently-resolved sha — so the
    // two can never disagree about which commit "the prior round" means. It
    // sits BEFORE the bump block below for the same reason that read does:
    // the bump overwrites the marker with THIS round's HEAD, and a delta
    // measured against that would be empty by construction.
    //
    // FAILS SOFT IN THE PERMISSIVE DIRECTION, like every other marker step
    // here. No prior sha (absent, corrupted, orphaned by a rebase) leaves the
    // field an empty array AND `review_prior_sha` empty, and the reader arms
    // the carry only when BOTH are usable — so a dropped or garbled field can
    // only ever cause MORE reviewers to re-run, never fewer. The one shape
    // that must not be conflated with it — a valid prior sha and a genuinely
    // empty delta — is distinguishable because `review_prior_sha` is non-empty
    // there.
    `since_json='[]'`,
    `if [ -n "$review_prior_sha" ]; then`,
    `  since_json="$(git diff --name-only "$review_prior_sha..HEAD" 2>/dev/null | jq -R -s -c 'split("\\n") | map(select(length>0))')"`,
    `fi`,
    `[ -n "$since_json" ] || since_json='[]'`,
    ...(bump
      ? [
          `if [ -n "$rounds_file" ]; then`,
          `  { printf '%s\\n' "$((review_rounds + 1))" > "$rounds_file"; } 2>/dev/null || true`,
          `fi`,
          // Record THIS round's HEAD for the NEXT round to read as its prior — see build-level.design-notes-3.md#record-this-round-s-head-for-the-next-round-to-read-as-its-p
          `__k2127_head="$(git rev-parse --verify --quiet HEAD 2>/dev/null || true)"`,
          `if [ -n "$sha_file" ] && [ -n "$__k2127_head" ]; then`,
          `  { printf '%s\\n' "$__k2127_head" > "$sha_file"; } 2>/dev/null || true`,
          `fi`,
        ]
      : []),
    `default="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')"`,
    `if [ -z "$default" ]; then`,
    `  for b in main master; do`,
    `    if git show-ref --verify --quiet "refs/remotes/origin/$b"; then default="$b"; break; fi`,
    `  done`,
    `fi`,
    `[ -n "$default" ] || default=main`,
    `files_json="$(git diff --name-only "origin/$default...HEAD" 2>/dev/null | jq -R -s -c 'split("\\n") | map(select(length>0))')"`,
    `[ -n "$files_json" ] || files_json='[]'`,
    `if [ -f ${sq(tsvPath)} ]; then`,
    // RELAY ONLY THE DATA ROWS (temperloop#1982 round 3). The field crosses — see build-level.design-notes-3.md#relay-only-the-data-rows-temperloop-1982-round-3-the-field-c
    `  tsv_json="$(awk ${sq(rowFilterAwk)} ${sq(tsvPath)} | jq -R -s -c 'split("\\n") | map(select(length>0))')"`,
    `  tsv_rows="$(awk 'BEGIN{c=0} { l=$0; sub(/\\r$/,"",l); t=l; gsub(/^[ \\t]+|[ \\t]+$/,"",t); if (t != "" && substr(t,1,1) != "#") c++ } END{print c+0}' ${sq(tsvPath)})"`,
    // POSITION-WEIGHTED (temperloop#1982 round 2): `n` is a running counter — see build-level.design-notes-3.md#position-weighted-temperloop-1982-round-2-n-is-a-running-cou
    `  tsv_checksum="$(awk ${sq(rowFilterAwk)} ${sq(tsvPath)} | od -An -v -tu1 | awk '{for(i=1;i<=NF;i++){n++; s+=$i*n}} END{print s+0}')"`,
    `else`,
    // The no-tsv worktree emits an EMPTY ARRAY, the `tsv_lines` analogue of  — see build-level.design-notes-3.md#the-no-tsv-worktree-emits-an-empty-array-the-tsv-lines-
    `  tsv_json='[]'`,
    `  tsv_rows=0`,
    `  tsv_checksum=0`,
    `fi`,
    `printf '{"outcome":"REVIEW_DIFF","files":%s,"files_since_prior":%s,"tsv_lines":%s,"tsv_rows":%s,"tsv_checksum":%s,"review_rounds":%s,"review_prior_sha":"%s"}\\n' "$files_json" "$since_json" "$tsv_json" "$tsv_rows" "$tsv_checksum" "$review_rounds" "$review_prior_sha"`,
  ].join('\n');
}

// parseTsvRows / reviewGlobMatch — the SAME extension/glob axis — see build-level.design-notes-3.md#parsetsvrows-reviewglobmatch-the-same-extension-glob-axis
function parseTsvRows(tsvText) {
  return String(tsvText ?? '')
    .split('\n')
    .map((l) => l.replace(/\r$/, ''))
    .filter((l) => l && !l.trim().startsWith('#'))
    .map((l) => l.split('\t'))
    .filter((cols) => cols.length >= 2 && cols[0] && cols[1])
    .map(([key, reviewer]) => ({ key: key.trim(), reviewer: reviewer.trim() }));
}

// tsvChecksum — temperloop#1982, made POSITION-SENSITIVE in round 2: a — see build-level.design-notes-3.md#tsvchecksum-temperloop-1982-made-position-sensitive-in-round
function tsvChecksum(tsvText) {
  // Trimmed-emptiness filter (`l.trim()`, not bare `l`) — matches — see build-level.design-notes-3.md#trimmed-emptiness-filter-l-trim-not-bare-l-matches
  const canon = String(tsvText ?? '')
    .split('\n')
    .map((l) => l.replace(/\r$/, ''))
    .filter((l) => l.trim() && !l.trim().startsWith('#'))
    .map((l) => `${l}\n`)
    .join('');
  let sum = 0;
  for (let i = 0; i < canon.length; i++) sum += canon.charCodeAt(i) * (i + 1);
  return sum;
}
function reviewGlobMatch(key, file) {
  // BASENAME form, e.g. '**/Makefile' (temperloop#1705) — the tsv key shap — see build-level.design-notes-3.md#basename-form-e-g-makefile-temperloop-1705-the-tsv-key-shap
  if (key.startsWith('**/')) {
    const base = key.slice(3);
    return file === base || file.endsWith(`/${base}`);
  }
  if (key.endsWith('/**')) return file.startsWith(key.slice(0, -2));
  return file.endsWith(key); // extension form, e.g. '.py'
}

const REVIEW_COMMANDS_DOC_RE = /^claude\/commands\/.*\.md$/;
const REVIEW_PROSE_MD_RE = /\.md$/;

// determineReviewers — build.md §3e's full routing rule set, applied to this
// item's changed-file set. Every matching axis is included (build.md: "A
// change matching more than one axis ... runs each matching reviewer").
// Returns [{ reviewer, mandatory, reasons[] }, ...], reviewer names deduped.
//
// temperloop#2020 — `opts.tableAvailable: false` runs the TABLE-INDEPENDENT
// axes ONLY. The rule set splits cleanly in two: the `review:` override, the
// `kind: architectural` axis and the MANDATORY command-doc rule
// (foundation#1007) are computed purely from `item`/`files` and never consult
// reviewer-routing.tsv at all; the extension axis and the prose-`*.md`
// fallback are the only ones that do. When the table does not survive the
// machinery relay, only that second half is unknowable — so asking for
// `tableAvailable: false` drops exactly those and keeps the rest, and a
// degraded relay can never silently swallow a route that never needed the
// table. The prose-`*.md` fallback is deliberately on the DROPPED side: it
// fires precisely when no row matched, and with a broken table "no row
// matched" is not a fact, it is an absence of evidence.
function determineReviewers(item, files, tsvText, opts = {}) {
  const tableAvailable = opts.tableAvailable !== false;
  const rows = tableAvailable ? parseTsvRows(tsvText) : [];
  // reviewer -> { reasons: Set, files: Set, fileScoped: boolean }
  //
  // temperloop#2129 adds the second and third fields. `files` is WHICH changed
  // files put this reviewer on the roster — the continuation carry decision
  // (reviewCarryForward) needs per-seat file attribution, and re-deriving it
  // there would be a second implementation of the very matching rule this
  // function owns. `fileScoped` is false as soon as ANY of a reviewer's
  // reasons came from an axis with no file behind it (the `review:` override,
  // `kind: architectural`), because such a seat's relevance is not a function
  // of which files moved and it must therefore always re-run.
  const matched = new Map();
  const add = (reviewer, reason, file) => {
    if (!reviewer) return;
    if (!matched.has(reviewer)) matched.set(reviewer, { reasons: new Set(), files: new Set(), fileScoped: true });
    const entry = matched.get(reviewer);
    entry.reasons.add(reason);
    if (file) entry.files.add(file);
    else entry.fileScoped = false;
  };

  if (item.review) add(item.review, 'review: override');
  if (item.kind === 'architectural') add('architecture-reviewer', 'kind: architectural');

  let anyCommandsDoc = false;
  const commandDocFiles = [];
  for (const f of files) {
    if (REVIEW_COMMANDS_DOC_RE.test(f)) {
      anyCommandsDoc = true;
      commandDocFiles.push(f);
      continue; // the mandatory rule below claims this file, never the tsv/prose fallback
    }
    // Both remaining axes read `rows`; with no trustworthy table there is — see build-level.design-notes-4.md#both-remaining-axes-read-rows-with-no-trustworthy-table
    if (!tableAvailable) continue;
    let tsvHit = false;
    for (const row of rows) {
      if (reviewGlobMatch(row.key, f)) {
        add(row.reviewer, `${row.key} -> ${row.reviewer}`, f);
        tsvHit = true;
      }
    }
    if (!tsvHit && REVIEW_PROSE_MD_RE.test(f)) {
      add('docs-reviewer', 'prose *.md fallback (no tsv row)', f);
    }
  }
  // Mandatory command-doc rule (foundation#1007) — always wins for a
  // claude/commands/*.md diff, regardless of any tsv row or the prose
  // fallback; never omitted, never worker-discretion.
  if (anyCommandsDoc) {
    for (const f of commandDocFiles) add('workflow-reviewer', 'claude/commands/*.md (foundation#1007 — mandatory)', f);
  }

  return Array.from(matched.entries()).map(([reviewer, entry]) => ({
    reviewer,
    mandatory: reviewer === 'workflow-reviewer' && anyCommandsDoc,
    reasons: Array.from(entry.reasons),
    // temperloop#2129 — carry-decision inputs. Consumed ONLY by
    // reviewCarryForward(); every other reader of a route ignores them.
    files: Array.from(entry.files),
    fileScoped: entry.fileScoped,
  }));
}

// reviewCarryForward — temperloop#2129. THE CONTINUATION-ROUND ROSTER RULE.
//
// THE COST THIS CUTS. temperloop#2127 made a continuation round DELTA-AWARE in
// the PROMPT — every routed seat still re-spawned, it was just told what had
// changed. On an item that loops the full REVIEW_BLOCKING_MAX_ROUNDS budget
// that re-runs every seat on every round, and the seats whose files the fix
// never touched re-read the same unchanged code and re-emit the same verdict.
// With build-level.mjs now carrying TWO seats (`.mjs` -> typescript-reviewer
// and `**/build-level.mjs` -> shell-reviewer, this same item), a shell-only fix
// round re-pays for a full ~9,000-line JavaScript review that cannot have
// changed. This narrows the ROSTER to match the prompt's delta.
//
// THE RULE, and why each clause is where the safety lives. A routed seat is
// CARRIED (not re-spawned) only when ALL of these hold:
//   - the carry is ARMED at all: round > 1, a VALIDATED prior sha, and a
//     `files_since_prior` array that actually arrived. Any of the three
//     missing arms nothing, so every seat re-runs — the same
//     permissive-on-degradation direction every other marker read here takes
//     (a relay that drops a field can only ever cause MORE review, never
//     less).
//   - the seat is NOT MANDATORY. foundation#1007's command-doc rule is a
//     GATE, and `review.mandatory_ok` means "workflow-reviewer actually ran on
//     this command-doc diff". Carrying it would report a gate as passed on the
//     strength of a previous round — the K.49/foundation#164 silent-skip class
//     dressed as an optimisation. Never carried, at any delta.
//   - the seat is FILE-SCOPED and has at least one routed file. A `review:`
//     override or a `kind: architectural` route has no file behind it, so
//     "did its files change" is not a question that can be asked about it.
//   - the seat did NOT raise the prior round's blocking finding. This is the
//     load-bearing one: the whole point of a `review-blocking` continuation is
//     for THAT seat to re-check the fix, and the fix routinely lands in files
//     that seat is not routed for (a JS-side fix for a shell finding, a doc
//     fix for a prose finding). Attribution is by reviewer NAME against the
//     prior findings text the orchestrator handed back, and it FAILS SAFE: if
//     that text is present but names no routed seat, the carry disarms
//     entirely rather than guess — better to re-run everything than to carry
//     the one seat that had to run.
//   - NONE of its routed files appear in the delta.
//
// A carried seat is never silent. It is recorded in `skipped` (so the tally's
// `routed_not_run` names it, exactly as that field's contract already says a
// seat skipped in one round and run in another should be) AND in `sections`,
// so the PR body still renders a block for it under `## Review notes` rather
// than losing the seat between rounds. See the carried disposition in
// disposeReviewSlot() for what that block says and what it honestly cannot.
//
// Mutates each carried route in place (`route.carriedFrom`) rather than
// returning a partition, so route ORDER — which fixes spawn order, `ran` order
// and section order — is preserved by construction with no second array to
// keep in step.
function reviewCarryForward(routes, ctx) {
  const priorSha = typeof ctx.priorSha === 'string' ? ctx.priorSha : '';
  const changedSince = Array.isArray(ctx.changedSince) ? ctx.changedSince : null;
  if (!(ctx.round > 1) || !priorSha || !changedSince) return { armed: false, carried: [] };

  const changed = new Set(changedSince.map((f) => String(f)));
  const priorText = typeof ctx.priorFindingsText === 'string' ? ctx.priorFindingsText : '';
  const blockingSeats = routes.filter((r) => priorText.includes(r.reviewer)).map((r) => r.reviewer);
  // FAIL SAFE (see the rule above): prior findings exist but name no routed
  // seat, so the seat that must re-run cannot be identified. Disarm.
  if (priorText.trim() && blockingSeats.length === 0) return { armed: false, carried: [] };

  const carried = [];
  for (const route of routes) {
    if (route.mandatory) continue;
    if (!route.fileScoped) continue;
    const routedFiles = Array.isArray(route.files) ? route.files : [];
    if (routedFiles.length === 0) continue;
    if (blockingSeats.includes(route.reviewer)) continue;
    if (routedFiles.some((f) => changed.has(f))) continue;
    route.carriedFrom = { round: ctx.round - 1, sha: priorSha, files: routedFiles };
    carried.push(route.reviewer);
  }
  return { armed: true, carried };
}

// reviewContinuationSection — temperloop#2127. The delta-aware instructi — see build-level.design-notes-3.md#reviewcontinuationsection-temperloop-2127-the-delta-aware-in
function reviewContinuationSection(priorContext) {
  const hasFindings = Boolean(priorContext.findings && priorContext.findings.trim());
  const premise = hasFindings
    ? `Round ${priorContext.round} found blocking finding(s), reproduced below; a fix round has since run.`
    : `Round ${priorContext.round} of this item's §3e review recorded NO blocking findings, so there is ` +
      'nothing from it for you to re-verify. This is a re-review after an unrelated change (a CI fix, a ' +
      'rebase, or another escalation that resumed through §3e). Treat it as a FULL review that is also ' +
      'delta-aware.';
  const steps = [];
  if (hasFindings) {
    steps.push('Verify each prior-round finding below is actually RESOLVED — re-check the exact code it named.');
  }
  steps.push(
    priorContext.sha
      ? `Review \`git diff ${priorContext.sha}..HEAD\` for regressions the work since that round introduced.`
      : 'Review the commits added since the prior round (no usable prior reviewed SHA was recorded — the ' +
        'marker was absent, or the commit it named no longer resolves or is no longer an ancestor of HEAD, ' +
        'e.g. after a rebase) for regressions the work since that round introduced.',
  );
  steps.push(
    'Then sweep the FULL branch once more, exactly as a round-1 review would. A pre-existing HIGH you find ' +
      'on this sweep is a MISS of the earlier round — report it explicitly as that, never silently as if ' +
      'newly introduced.',
  );
  return [
    `## Continuation — round ${priorContext.round + 1} of this item's §3e review (delta-aware)`,
    premise,
    steps.length === 3 ? 'Do all three of the following, IN ORDER:' : 'Do BOTH of the following, IN ORDER:',
    ...steps.map((step, i) => `${i + 1}. ${step}`),
    '',
    ...(hasFindings ? [`## Prior round ${priorContext.round} findings`, priorContext.findings, ''] : []),
  ];
}

// reviewPrompt — a read-only pass over THIS item's diff, carrying the sa — see build-level.design-notes-3.md#reviewprompt-a-read-only-pass-over-this-item-s-diff-carrying
function reviewPrompt(item, wt, route, files, priorContext) {
  const header = [
    `You are running build.md's §3e mandatory/routed pre-push review for /build`,
    `item \`${item.slug}\` (route: ${route.reasons.join('; ')}).`,
    '',
    '## Scope — READ-ONLY, advisory',
    `Review the changes on this branch relative to origin/<default>, in the worktree`,
    `at ${wt}. Run \`git diff\` / \`git log\` yourself there — the file list below is a`,
    'pointer, not the diff. Make no edits, no commits.',
    '',
  ];
  const continuation = priorContext ? reviewContinuationSection(priorContext) : [];
  const footer = [
    `Changed files (${files.length}):`,
    files.length ? files.map((f) => `  - ${f}`).join('\n') : '  (none reported)',
    '',
    ...principlesSection(item),
    '',
    "Follow your own agent definition's checklist and output format exactly.",
  ];
  return [...header, ...continuation, ...footer].join('\n');
}

// reviewHasBlockingFinding — this repo's reviewer catalog (workflow-revi — see build-level.design-notes-3.md#reviewhasblockingfinding-this-repo-s-reviewer-catalog-workfl
function reviewHasBlockingFinding(text) {
  return /^\s*###\s*\[\s*HIGH\b/im.test(String(text ?? ''));
}

// reviewDiffTsvGap — temperloop#1976 (row-count), extended by temperloop — see build-level.design-notes.md#reviewdifftsvgap-temperloop-1976-row-count-extended-by-tempe

// reviewDiffTsvText(diffOut) — temperloop#2020. The ONE place that turns — see build-level.design-notes-3.md#reviewdifftsvtext-diffout-temperloop-2020-the-one-place-that
function reviewDiffTsvText(diffOut) {
  if (Array.isArray(diffOut?.tsv_lines)) {
    return diffOut.tsv_lines.map((l) => String(l)).join('\n');
  }
  if (typeof diffOut?.tsv === 'string') return diffOut.tsv;
  return null;
}

function reviewDiffTsvGap(diffOut, files) {
  if (!files.length) return null;
  const tsvText = reviewDiffTsvText(diffOut);
  if (tsvText === null) return { missing: 'tsv', files };
  const expected = parseTsvRows(tsvText).length;
  const got = Number(diffOut.tsv_rows);
  if (expected !== got) return { mismatch: { expected, got: diffOut.tsv_rows ?? null }, files };
  const expectedChecksum = tsvChecksum(tsvText);
  const gotChecksum = Number(diffOut.tsv_checksum);
  if (expectedChecksum !== gotChecksum) {
    return { content_mismatch: { expected: expectedChecksum, got: diffOut.tsv_checksum ?? null }, files };
  }
  return null;
}

// runReviewers — the §3e driver. Fetches the routing inputs (one machine — see build-level.design-notes-2.md#runreviewers-the-3e-driver-fetches-the-routing-inputs-one-ma
async function runReviewers(item, wt, priorFindingsText) {
  const fetchReviewDiff = (phaseTitle, bump) =>
    runMachinery(reviewDiffCmd(wt, bump), { label: `review-diff:${item.slug}`, slug: item.slug, phase: phaseTitle });

  let diffOut = await fetchReviewDiff(enterStage(STAGE_REVIEW), true);
  if (machineryDenied(diffOut)) {
    // temperloop#1819: quota death vs genuine denial — see deniedOrQuota.
    return { escalation: await deniedOrQuota(item.slug, { step: 'review-diff', out: diffOut }, wt) };
  }
  if (diffOut.outcome !== 'REVIEW_DIFF') {
    return { escalation: escalate(item.slug, 'review-diff-error', { diffOut }) };
  }
  // temperloop#1970 — read the round counter from the BUMPING fetch only. A
  // relay that drops/garbles the field reads 0, i.e. "first round", which is
  // exactly the pre-#1970 behaviour: a DROPPED or GARBLED field can only ever
  // be MORE permissive, never a bound that fires early on a healthy item.
  //
  // That covers the relay, and ONLY the relay (temperloop#2046). The failure
  // shape it does NOT cover is an INFLATED counter: the marker is corrupted
  // UPSTREAM of the relay, by something other than this driver writing the
  // worktree's `build-review-rounds` file, so the field arrives as a
  // perfectly valid finite number and every check here accepts it. The bound
  // then fires EARLY on a healthy item — the exact case this comment once
  // claimed could not happen, observed live three times when two test cases
  // in test_workflow.sh ran the real review-diff pipeline against the repo
  // root with the bumping default and drove a fresh worktree's counter to 8
  // and 16 against a max of 3. Nothing here can distinguish an inflated count
  // from a genuine one, so the invariant is enforced at the WRITE side
  // instead: that suite now carries a structural + behavioural guard
  // (its "#2046" checks) that no test run may write this marker at all.
  const priorRounds = Number.isFinite(Number(diffOut.review_rounds))
    ? Math.max(0, Math.floor(Number(diffOut.review_rounds)))
    : 0;
  const round = priorRounds + 1;
  // temperloop#2127 — the SHA reviewDiffCmd read (and then, on this bumping
  // call, overwrote) from the marker kept beside build-review-rounds: the
  // commit that was HEAD when the PRIOR round ran. Sanitised defensively
  // (hex-only, non-empty) even though reviewDiffCmd's own `tr -cd` already
  // filters it — belt-and-suspenders against a relay that mangles the field
  // the same way `tsv`/`review_rounds` have each been observed to. `null`
  // (never a bogus value) when absent/corrupted, matching every other
  // fails-soft marker read in this pipeline.
  //
  // FLOOR OF 7, NOT 4 (round 2, HIGH A). The producing shell now resolves the
  // value against the repo itself, so this is the second belt — but the floor
  // still matters, because `{4,}` is wide enough to accept the residue `tr -cd`
  // leaves behind on a corrupted marker (`not a sha at all` filters down to the
  // perfectly well-shaped `aaaa`). 7 is git's own minimum abbreviation length,
  // so nothing this pipeline legitimately produces is excluded.
  const priorSha =
    typeof diffOut.review_prior_sha === 'string' && /^[0-9a-fA-F]{7,64}$/.test(diffOut.review_prior_sha)
      ? diffOut.review_prior_sha
      : null;
  // `priorContext` — null on round 1 (the ONLY thing that keeps reviewProm — see build-level.design-notes-3.md#priorcontext-null-on-round-1-the-only-thing-that-keeps-revie
  const isContinuationRound = round > 1;
  const priorContext = isContinuationRound
    ? {
        round: priorRounds,
        sha: priorSha,
        findings: typeof priorFindingsText === 'string' ? priorFindingsText : '',
      }
    : null;
  let files = Array.isArray(diffOut.files) ? diffOut.files : [];
  // temperloop#2020 — set (not returned from) the gap arm below, so a degr — see build-level.design-notes-4.md#temperloop-2020-set-not-returned-from-the-gap-arm-below
  let routingDegraded = null;
  let degradedSkip = null;
  // temperloop#1976: a dropped/truncated tsv relay is nondeterministic per — see build-level.design-notes-3.md#temperloop-1976-a-dropped-truncated-tsv-relay-is-nondetermin
  if (!REVIEWER_ROUTING_TSV && reviewDiffTsvGap(diffOut, files)) {
    diffOut = await fetchReviewDiff(stagePhase(STAGE_REVIEW), false);
    if (machineryDenied(diffOut)) {
      return { escalation: await deniedOrQuota(item.slug, { step: 'review-diff', out: diffOut }, wt) };
    }
    if (diffOut.outcome !== 'REVIEW_DIFF') {
      return { escalation: escalate(item.slug, 'review-diff-error', { diffOut }) };
    }
    files = Array.isArray(diffOut.files) ? diffOut.files : [];
    const gap = reviewDiffTsvGap(diffOut, files);
    if (gap) {
      // temperloop#2020 — DEGRADE, never halt. Before this item a persistent — see build-level.design-notes-2.md#temperloop-2020-degrade-never-halt-before-this-item-a-persis
      const note =
        'skipped — §3e extension-axis reviewer routing unavailable (reviewer-routing.tsv did not ' +
        'survive the machinery relay; only table-independent routes were resolved for this diff)';
      log(`[${item.slug}] §3e review — ${note} ${JSON.stringify(gap)}`);
      routingDegraded = gap;
      // `mandatory: false` is a statement about this ENTRY, not about the
      // item: this entry records the withdrawn TABLE-DEPENDENT axes, none of
      // which can ever be the foundation#1007 mandatory rule. The mandatory
      // rule is routed for real below and carries its own `mandatory: true`
      // into `ran`/`skipped`, so reviewTally()'s `mandatory_ok` reflects
      // whether workflow-reviewer actually ran — it is no longer a claim this
      // arm makes on its behalf.
      degradedSkip = { reviewer: '(routing)', note, mandatory: false };
    }
  }
  // The orchestrator-supplied table wins outright when present (#1982); th — see build-level.design-notes-4.md#the-orchestrator-supplied-table-wins-outright-when-pres
  const tsvText = REVIEWER_ROUTING_TSV || reviewDiffTsvText(diffOut) || '';
  const routes = determineReviewers(item, files, tsvText, { tableAvailable: !routingDegraded });
  // temperloop#2129 — narrow a CONTINUATION round's roster to the seats whose
  // routed files actually moved (plus the blocking seat and every mandatory
  // one, unconditionally). Mutates the routes it carries; see
  // reviewCarryForward() for the full rule and its fail-safe arms.
  const carryPlan = reviewCarryForward(routes, {
    round,
    priorSha,
    changedSince: Array.isArray(diffOut.files_since_prior) ? diffOut.files_since_prior : null,
    priorFindingsText,
  });
  if (carryPlan.carried.length > 0) {
    log(
      `[${item.slug}] §3e review round ${round} — carrying ${carryPlan.carried.join(', ')} forward from ` +
        `round ${round - 1}: no routed file changed since ${priorSha} (temperloop#2129)`,
    );
  }
  if (routes.length === 0) {
    return {
      summary: degradedSkip ? degradedSkip.note : '',
      notes: '',
      sections: [],
      blocking: [],
      ran: [],
      skipped: degradedSkip ? [degradedSkip] : [],
      round,
      ...(routingDegraded ? { routing_degraded: routingDegraded } : {}),
    };
  }

  const ran = [];
  // Seeded, not appended: the degradation notice must reach the PR body an — see build-level.design-notes-4.md#seeded-not-appended-the-degradation-notice-must-reach-t
  const skipped = degradedSkip ? [degradedSkip] : [];
  const blocking = [];
  // sections — the STRUCTURED per-reviewer findings ({ reviewer, text }, r — see build-level.design-notes-3.md#sections-the-structured-per-reviewer-findings-reviewer-text-
  const sections = [];
  // temperloop#2003 — SPAWN EVERY ROUTED REVIEWER FIRST, then wait on the — see build-level.design-notes-3.md#temperloop-2003-spawn-every-routed-reviewer-first-then-wait-
  const slots = routes.map((route) => {
    const slot = { route, done: false, value: undefined, error: undefined };
    // temperloop#2129 — a CARRIED seat keeps its place in route order but is
    // NOT SPAWNED: no agent() call is made for it at all, which is the whole
    // saving. It is seeded already-settled so awaitReviewFanout's `pending()`
    // never counts it (a carried seat must not hold the fanout open, nor be
    // read as a ceiling breach), and disposeReviewSlot() gives it its own
    // disposition kind.
    if (route.carriedFrom) {
      slot.done = true;
      slot.carried = route.carriedFrom;
      slot.promise = Promise.resolve();
      return slot;
    }
    // No `schema` — a plain read-only advisory pass, not a machine-validated — see build-level.design-notes-3.md#no-schema-a-plain-read-only-advisory-pass-not-a-machine-vali
    slot.promise = agent(reviewPrompt(item, wt, route, files, priorContext), {
      // `#<reviewer>` (not `:<reviewer>`) matches the label grammar every — see build-level.design-notes-4.md#reviewer-not-reviewer-matches-the-label-grammar-every
      label: `review:${item.slug}#${route.reviewer}`,
      phase: stagePhase(STAGE_REVIEW),
      agentType: route.reviewer,
    }).then(
      (v) => { slot.done = true; slot.value = v; },
      (e) => { slot.done = true; slot.error = e; },
    );
    return slot;
  });
  const waitedSecs = await awaitReviewFanout(item, slots);
  // temperloop#2032 — THE LAST-CHANCE READ, and the reason the disposition — see build-level.design-notes-3.md#temperloop-2032-the-last-chance-read-and-the-reason-the-disp
  await drainReviewSettlements(slots);

  // Pass 1 — consume every reviewer that has settled. disposeReviewSlot()  — see build-level.design-notes-4.md#pass-1-consume-every-reviewer-that-has-settled-disposer
  const dispositions = slots.map((slot) => (slot.done ? disposeReviewSlot(slot) : null));
  // Pass 2 — the stragglers get the settlement turns pass 1 just spent.
  if (dispositions.some((d) => d === null)) {
    await drainReviewSettlements(slots);
    for (let i = 0; i < slots.length; i++) {
      if (dispositions[i] === null && slots[i].done) dispositions[i] = disposeReviewSlot(slots[i]);
    }
  }

  // Pass 3 — apply the dispositions in ROUTE order, so `ran`/`skipped`/ — see build-level.design-notes-3.md#pass-3-apply-the-dispositions-in-route-order-so-ran-skipped
  for (let i = 0; i < slots.length; i++) {
    const slot = slots[i];
    const route = slot.route;
    const disposition = dispositions[i] ?? (slot.done ? disposeReviewSlot(slot) : null);
    if (disposition === null) {
      // temperloop#2003 — the CEILING BREACH. This reviewer is abandoned, neve — see build-level.design-notes-3.md#temperloop-2003-the-ceiling-breach-this-reviewer-is-abandone
      const note =
        `skipped — ${route.reviewer} timed out after ${waitedSecs}s ` +
        `(the §3e review ceiling of ${REVIEW_AGENT_CEILING_SECS}s — temperloop#2003; the agent is ` +
        `installed and was spawned, it did not return in time)`;
      log(`[${item.slug}] §3e review — ${note}`);
      // `timed_out` distinguishes this from the other three skip reasons for a — see build-level.design-notes-4.md#timed-out-distinguishes-this-from-the-other-three-skip-
      skipped.push({ reviewer: route.reviewer, note, mandatory: route.mandatory, timed_out: true });
      continue;
    }
    if (disposition.kind === 'skip') {
      log(`[${item.slug}] §3e review — ${disposition.note}`);
      skipped.push({ reviewer: route.reviewer, note: disposition.note, mandatory: route.mandatory });
      continue;
    }
    // temperloop#2129 — the CARRIED seat. TWO records, deliberately, because
    // they answer two different readers' questions and neither substitutes for
    // the other:
    //   - a `skipped` entry, so the Step 6 tally's `routed_not_run` names it
    //     (its contract already covers exactly this case: "a reviewer skipped
    //     in one round and run in another stays listed"), and so an operator
    //     reading the roster never sees a seat silently vanish between rounds;
    //   - a `sections` entry, so the PR body's `## Review notes` still renders
    //     a BLOCK for this seat. Without it a cold reader of the final PR sees
    //     only the seats that happened to run on the LAST round and has no way
    //     to tell a seat that was carried from one that was never routed.
    // `mandatory: false` is a statement of fact, not a choice: a mandatory
    // route is never carried (reviewCarryForward), so this branch cannot be
    // reached with one.
    if (disposition.kind === 'carried') {
      log(`[${item.slug}] §3e review — ${disposition.note}`);
      skipped.push({ reviewer: route.reviewer, note: disposition.note, mandatory: false, carried_forward: true });
      sections.push({ reviewer: route.reviewer, text: disposition.text });
      continue;
    }
    // EXHAUSTIVE on purpose. `disposeReviewSlot()` returns exactly two shape — see build-level.design-notes-3.md#exhaustive-on-purpose-disposereviewslot-returns-exactly-two-
    if (disposition.kind !== 'ran') {
      throw new Error(
        `§3e disposition for ${route.reviewer} has unknown kind ${JSON.stringify(disposition.kind)} — ` +
          'disposeReviewSlot() grew a shape this loop does not handle',
      );
    }
    const textStr = disposition.text;
    ran.push({ reviewer: route.reviewer, mandatory: route.mandatory });
    log(`[${item.slug}] §3e review — ${route.reviewer} ran (${route.reasons.join('; ')})`);
    // temperloop#1450 — keep the FULL text, not just the name: a MEDIUM/LOW- — see build-level.design-notes-4.md#temperloop-1450-keep-the-full-text-not-just-the-name-a-
    sections.push({ reviewer: route.reviewer, text: textStr });
    if (reviewHasBlockingFinding(textStr)) {
      blocking.push({ reviewer: route.reviewer, findings: textStr });
    }
  }

  const parts = [];
  if (ran.length) parts.push(`§3e review — ran: ${ran.map((r) => r.reviewer).join(', ')}`);
  if (skipped.length) parts.push(skipped.map((s) => s.note).join('; '));
  const result = {
    summary: parts.join(' · '),
    notes: sections.map((s) => `### ${s.reviewer}\n${s.text}`).join('\n\n'),
    sections,
    blocking,
    ran,
    skipped,
    round,
    ...(routingDegraded ? { routing_degraded: routingDegraded } : {}),
  };
  // temperloop#2003 — the MANDATORY half of the timeout disposition. An advisory
  // reviewer that timed out has already degraded to a legible skip notice above
  // and the item carries on; a MANDATORY route (foundation#1007's command-doc
  // rule) must never read as if its gate passed, so it escalates instead. The
  // payload carries the FULL tally — `mandatory_ok` computed, not left
  // unevaluated — which is precisely what the incident lacked: the pass never
  // resolved, so nothing ever reported that the mandatory reviewer had not run.
  const timedOut = skipped.filter((s) => s.timed_out);
  const mandatoryTimedOut = timedOut.filter((s) => s.mandatory);
  if (mandatoryTimedOut.length > 0) {
    log(
      `[${item.slug}] §3e review — MANDATORY reviewer(s) ` +
        `${mandatoryTimedOut.map((s) => s.reviewer).join(', ')} timed out after ${waitedSecs}s ` +
        `(the ${REVIEW_AGENT_CEILING_SECS}s review ceiling) — escalating (temperloop#2003)`,
    );
    result.escalation = escalate(item.slug, 'review-agent-timeout', {
      ceiling_secs: REVIEW_AGENT_CEILING_SECS,
      // temperloop#2064 — the tick actually honoured. A `waited_secs` far belo — see build-level.design-notes-4.md#temperloop-2064-the-tick-actually-honoured-a-waited-sec
      waited_secs: waitedSecs,
      slow_secs: REVIEW_AGENT_SLOW_SECS,
      mandatory: mandatoryTimedOut.map((s) => s.reviewer),
      timed_out: timedOut.map((s) => s.reviewer),
      review: reviewTally(result),
      round,
      remedy:
        'the mandatory §3e reviewer did not return within the ceiling — re-drive the item, ' +
        'or raise BUILD_REVIEW_AGENT_CEILING_SECS only if this review is legitimately this slow',
    });
  }
  return result;
}

// disposeReviewSlot — the verdict for ONE SETTLED reviewer slot, as a pu — see build-level.design-notes-4.md#disposereviewslot-the-verdict-for-one-settled-reviewer-slot-
function disposeReviewSlot(slot) {
  const route = slot.route;
  // temperloop#2129 — CARRIED, checked FIRST because a carried slot was never
  // spawned: it has no value and no error, and every branch below would read
  // that absence as a failure ("returned no verdict (skip/transient)").
  //
  // WHAT THE BLOCK CAN AND CANNOT SAY. It states the fact that settles the
  // question for a cold reader of the PR — this seat was routed, it ran in the
  // named round, and the files it is routed for have not moved since the
  // commit it reviewed. It does NOT reproduce that round's findings text,
  // because that text does not cross the round boundary: §3e escalates to the
  // orchestrator between rounds and the only review content handed back is the
  // BLOCKING findings (`verdicts[slug].verdict_section`, build.md Step 3). A
  // carried seat by construction raised none — the blocking seat is always
  // re-run (reviewCarryForward), and a continuation that did not come from a
  // `review-blocking` escalation had no blocking findings at all — so what is
  // unreproducible here is advisory MEDIUM/LOW prose, never a HIGH. The block
  // says that plainly rather than implying the seat produced nothing.
  if (slot.carried) {
    const carried = slot.carried;
    const shortSha = String(carried.sha).slice(0, 12);
    const note =
      `carried forward — ${route.reviewer} was not re-spawned this round: none of the ` +
      `${carried.files.length} file(s) routed to it changed since ${shortSha}, the commit its ` +
      `round ${carried.round} review already covered (temperloop#2129)`;
    const text = [
      `_Carried forward from round ${carried.round} (temperloop#2129) — this seat was NOT re-spawned._`,
      '',
      `Every file routed to \`${route.reviewer}\` on this branch is byte-identical to what it reviewed ` +
        `in round ${carried.round}, at commit \`${shortSha}\`, so re-running it could only reproduce that ` +
        'round\'s verdict. Its round ' + carried.round + ' review therefore stands for these files:',
      '',
      ...carried.files.map((f) => `- \`${f}\``),
      '',
      `Round ${carried.round}'s own findings text is not reproduced here: only BLOCKING findings cross ` +
        'the escalate/re-invoke boundary between rounds, and a seat is only ever carried when it raised ' +
        'none — so what is missing above is advisory MEDIUM/LOW prose from a round that did not block, ' +
        'never an unresolved HIGH. The seats whose files DID change this round are reviewed in the ' +
        'block(s) beside this one.',
    ].join('\n');
    return { kind: 'carried', note, text };
  }
  if (slot.error) {
    const err = slot.error;
    const msg = String((err && err.message) || err);
    // Reuse machineryAgent's own resolution-failure detection (temperloop#10 — see build-level.design-notes-4.md#reuse-machineryagent-s-own-resolution-failure-detection-temp
    if (MACHINERY_RESOLUTION_ERR.test(msg)) {
      // Every reviewer this repo names (the tsv's own agent-catalog-path — see build-level.design-notes-4.md#every-reviewer-this-repo-names-the-tsv-s-own-agent-catalog-p
      return {
        kind: 'skip',
        note: `skipped — ${route.reviewer} available as source; run workflows/scripts/install/project-agents.sh to enable`,
      };
    }
    // A genuine (non-resolution) error is not evidence the capability is — see build-level.design-notes-4.md#a-genuine-non-resolution-error-is-not-evidence-the-capa
    return { kind: 'skip', note: `skipped — ${route.reviewer} errored (${msg})` };
  }
  if (slot.value == null) {
    return { kind: 'skip', note: `skipped — ${route.reviewer} returned no verdict (skip/transient)` };
  }
  return { kind: 'ran', text: String(slot.value) };
}

// REVIEW_SETTLE_DRAIN_TICKS — how many settlement turns a drain yields b — see build-level.design-notes-4.md#review-settle-drain-ticks-how-many-settlement-turns-a-drain-
const REVIEW_SETTLE_DRAIN_TICKS = 16;

// drainReviewSettlements — give every reviewer whose promise has already — see build-level.design-notes-4.md#drainreviewsettlements-give-every-reviewer-whose-promise-has
async function drainReviewSettlements(slots) {
  for (let i = 0; i < REVIEW_SETTLE_DRAIN_TICKS; i++) {
    if (slots.every((s) => s.done)) return;
    await null;
  }
}

// awaitReviewFanout — temperloop#2003's ceiling, applied to the whole §3 — see build-level.design-notes-4.md#awaitreviewfanout-temperloop-2003-s-ceiling-applied-to-the-w
async function awaitReviewFanout(item, slots) {
  const allSettled = Promise.all(slots.map((s) => s.promise));
  const pending = () => slots.filter((s) => !s.done);
  // Drain already-resolved reviewer promises before paying for a timer spa — see build-level.design-notes-4.md#drain-already-resolved-reviewer-promises-before-paying-for-a
  await drainReviewSettlements(slots);

  let waited = 0;
  let slowLogged = false;
  for (const slice of reviewWaitSlices()) {
    if (pending().length === 0) return waited;
    const tick = await Promise.race([
      allSettled.then(() => 'SETTLED'),
      reviewWaitAgent(item, slice, waited + slice),
    ]);
    if (tick === 'SETTLED' || pending().length === 0) return waited;
    if (tick !== 'REVIEW_WAIT_ELAPSED') {
      // temperloop#2064 — name the REFUSAL case explicitly. "The timer is — see build-level.design-notes-4.md#temperloop-2064-name-the-refusal-case-explicitly-the-ti
      const blocked = /^timer-blocked/.test(String(tick));
      log(
        `[${item.slug}] §3e review — the wall-clock timer is unavailable (${tick}); ` +
          (blocked
            ? 'a harness permission control REFUSED the wait command, so NO time was waited and ' +
              'the ceiling is not applied (temperloop#2064); '
            : '') +
          `waiting on the fanout unbounded, as before temperloop#2003`,
      );
      await allSettled;
      return waited;
    }
    waited += slice;
    if (pending().length === 0) return waited;
    if (!slowLogged && REVIEW_AGENT_SLOW_SECS > 0 && waited >= REVIEW_AGENT_SLOW_SECS) {
      slowLogged = true;
      // The OBSERVABILITY half (mirrors #1071's STEP_SLOW notice): a long revi — see build-level.design-notes-4.md#the-observability-half-mirrors-1071-s-step-slow-notice-
      log(
        `[${item.slug}] §3e review — still running after ${waited}s: ` +
          `${pending().map((s) => s.route.reviewer).join(', ')} ` +
          `(ceiling ${REVIEW_AGENT_CEILING_SECS}s). Raise BUILD_REVIEW_AGENT_CEILING_SECS ` +
          `if this review is legitimately this slow.`,
      );
    }
  }
  log(
    `[${item.slug}] §3e review — wall-clock ceiling of ${REVIEW_AGENT_CEILING_SECS}s reached with ` +
      `${pending().map((s) => s.route.reviewer).join(', ')} still outstanding ` +
      `(${waited}s of tick actually honoured — temperloop#2003, temperloop#2064)`,
  );
  return waited;
}

// reviewWaitAgent — the wall-clock TICK this runtime does not otherwise — see build-level.design-notes.md#reviewwaitagent-the-wall-clock-tick-this-runtime-does-not-ot
async function reviewWaitAgent(item, secs, mark) {
  const waitBin = machineryBin(input.repoRoot, 'review-wait.sh');
  const cmd = `${waitBin} ${sq(secs)}`;
  const promptFor = (lean) =>
    [
      'Run ONE project helper script that waits for a fixed interval, and report what it printed.',
      'This is a TIMER, not a build step: it inspects nothing and changes nothing.',
      'Run this single command with the Bash tool, exactly as written — do not add flags, chain',
      'extra commands, substitute a `sleep`, or shorten the interval.',
      `Set the Bash tool \`timeout\` parameter to ${Math.min(AGENT_BASH_CAP_MS, secs * 1000 + 60_000)}.`,
      lean ? null : 'The command prints a SINGLE JSON line on stdout once the interval has elapsed;'
        + ' return that object verbatim as your result.',
      '`realized_secs` is the script\'s OWN measurement of how long it waited. Report only the'
        + ' number the command actually printed — NEVER a number you inferred, and never the'
        + ' interval that was requested.',
      'If a permission control REFUSED or BLOCKED the command — a `<tool_use_error>Blocked: …`'
        + ' result, or any other refusal — do NOT guess, do NOT re-run it, do NOT substitute a'
        + ' different wait, and do NOT report the interval as elapsed. Return'
        + ' {"outcome":"REVIEW_WAIT_BLOCKED","refusal_text":"<the FIRST LINE of the refusal,'
        + ' copied VERBATIM>"}. No time passed. A block is NOT a timeout: reporting one as the'
        + ' other makes a review ceiling fire ~30x early and throw away finished reviews'
        + ' (temperloop#2049, temperloop#2064).',
      'If the command failed for any OTHER reason — it errored, the helper was missing — return'
        + ' {"outcome":"REVIEW_WAIT_UNAVAILABLE","error":"<the FIRST LINE of the error, VERBATIM>"}.'
        + ' No time passed here either.',
      'If instead the Bash tool\'s OWN timeout killed the command WHILE IT WAS RUNNING, return'
        + ' exactly {"outcome":"REVIEW_WAIT_TOOL_TIMEOUT"} — that budget is longer than the interval,'
        + ' so the interval did elapse. Use this ONLY for a command that actually ran and was then'
        + ' killed: never for one that was refused before it started. If you cannot tell the two'
        + ' apart, you were BLOCKED — say so and quote the text.',
      '',
      'Command:',
      cmd,
    ].filter(Boolean).join('\n');
  let out;
  try {
    out = await machineryAgent(promptFor, {
      label: `review-wait:${item.slug}#${mark}`,
      phase: stagePhase(STAGE_REVIEW),
      model: input.machinerySoloModel || 'haiku',
      schema: SPINE_OUTCOME_SCHEMA,
    });
  } catch (err) {
    return `timer-error: ${String((err && err.message) || err)}`;
  }
  if (machineryDenied(out)) return 'timer-denied';
  // THE #2064 CHECK, and it runs FIRST — before any outcome label is read. A
  // refusal is recognised from the harness's own words (REVIEW_WAIT_REFUSAL_RE),
  // so a block the executor mislabelled REVIEW_WAIT_TOOL_TIMEOUT — the
  // permissive arm, and the label #2064 actually observed it choosing — cannot
  // reach that arm. Fails CLOSED: "no usable timer", never "the interval
  // elapsed". Ordering is the whole mechanism; moving this below the label
  // branches restores the defect exactly.
  const refusal = reviewWaitRefusalText(out);
  if (refusal) return `timer-blocked: ${refusal}`;
  if (out.outcome === 'REVIEW_WAIT_BLOCKED') {
    return 'timer-blocked: a harness permission control refused the wait command';
  }
  // The tool-timeout arm: an observation, honoured as elapsed (budget > in — see build-level.design-notes-4.md#the-tool-timeout-arm-an-observation-honoured-as-elapsed
  if (out.outcome === 'REVIEW_WAIT_TOOL_TIMEOUT') return 'REVIEW_WAIT_ELAPSED';
  if (out.outcome !== 'REVIEW_WAIT_ELAPSED') return `timer-outcome:${out.outcome}`;
  // THE #2049 CHECK. An elapse is a claim about wall clock, and this runti — see build-level.design-notes-4.md#the-2049-check-an-elapse-is-a-claim-about-wall-clock-and-thi
  const realized = Number(out.realized_secs);
  if (!(realized >= secs)) return `timer-unrealized:${out.realized_secs ?? 'absent'}`;
  return 'REVIEW_WAIT_ELAPSED';
}

// reviewBoundReached(review) — the §3e convergence bound's ONE predicate — see build-level.design-notes-4.md#reviewboundreached-review-the-3e-convergence-bound-s-one-pre
function reviewBoundReached(review) {
  return review.blocking.length > 0 && (review.round ?? 1) >= REVIEW_BLOCKING_MAX_ROUNDS;
}

// REVIEW_BLOCK_MARK — the EXPLICIT, machine-readable boundary of one rev — see build-level.design-notes-4.md#review-block-mark-the-explicit-machine-readable-boundary-of-
const REVIEW_BLOCK_MARK = '3e-review-block';
// Matches an opening comment whose first token is the mark and that has  — see build-level.design-notes-4.md#matches-an-opening-comment-whose-first-token-is-the-mar
const REVIEW_BLOCK_MARK_RE = new RegExp(`<!--(\\s*)${REVIEW_BLOCK_MARK}(?!-quoted)`, 'g');

// One block's opening delimiter. The reviewer name is reduced to the blo — see build-level.design-notes-4.md#one-block-s-opening-delimiter-the-reviewer-name-is-redu
function reviewBlockMarker(reviewer, round) {
  const name = String(reviewer ?? '').replace(/[^A-Za-z0-9_.-]/g, '-') || 'unknown';
  const n = Number.isFinite(Number(round)) ? Math.max(0, Math.trunc(Number(round))) : 0;
  return `<!-- ${REVIEW_BLOCK_MARK} reviewer="${name}" round="${n}" -->`;
}

// Strip the block delimiter's power out of text that is about to be spli — see build-level.design-notes-4.md#strip-the-block-delimiter-s-power-out-of-text-that-is-a
function neutralizeReviewBlockMark(text) {
  return String(text ?? '').replace(REVIEW_BLOCK_MARK_RE, `<!--$1${REVIEW_BLOCK_MARK}-quoted`);
}

// reviewBodySuffix — the ONE renderer of §3e evidence into the PR body — see build-level.design-notes-4.md#reviewbodysuffix-the-one-renderer-of-3e-evidence-into-the-pr
function reviewBodySuffix(rounds) {
  const ranNames = [];
  const skippedNotes = [];
  const sectionParts = [];
  rounds.filter(Boolean).forEach((r, i) => {
    for (const e of r.ran ?? []) {
      if (!ranNames.includes(e.reviewer)) ranNames.push(e.reviewer);
    }
    for (const s of r.skipped ?? []) {
      if (!skippedNotes.includes(s.note)) skippedNotes.push(s.note);
    }
    for (const sec of r.sections ?? []) {
      const heading = i === 0 ? sec.reviewer : `${sec.reviewer} (ci-fix round ${i})`;
      sectionParts.push(
        `${reviewBlockMarker(sec.reviewer, i)}\n### ${heading}\n${neutralizeReviewBlockMark(sec.text)}`,
      );
    }
  });
  const parts = [];
  if (ranNames.length) parts.push(`§3e review — ran: ${ranNames.join(', ')}`);
  if (skippedNotes.length) parts.push(skippedNotes.join('; '));
  const line = parts.join(' · ');
  return (
    (line ? `\n\n${line}` : '') +
    (sectionParts.length ? `\n\n## Review notes\n${sectionParts.join('\n\n')}` : '')
  );
}

// reviewTally — merge one or more runReviewers() rounds (the original 3e — see build-level.design-notes-2.md#reviewtally-merge-one-or-more-runreviewers-rounds-the-origin
function reviewTally(...rounds) {
  const ran = [];
  const skipped = [];
  const residual = [];
  // temperloop#2020 — the gap payload behind a routing degradation, carrie — see build-level.design-notes-4.md#temperloop-2020-the-gap-payload-behind-a-routing-degradation
  let routingDegraded = null;
  for (const r of rounds) {
    if (!r) continue;
    ran.push(...(r.ran ?? []));
    skipped.push(...(r.skipped ?? []));
    if (r.routing_degraded && !routingDegraded) routingDegraded = r.routing_degraded;
    if (r.residualBlocking) {
      residual.push({
        round: r.round ?? null,
        max_rounds: REVIEW_BLOCKING_MAX_ROUNDS,
        findings: r.blocking ?? [],
      });
    }
  }
  return {
    ran,
    skipped,
    mandatory_ok: !skipped.some((s) => s.mandatory),
    routed_not_run: Array.from(new Set(skipped.map((s) => s.reviewer))),
    ...(residual.length > 0 ? { residual_blocking: residual } : {}),
    ...(routingDegraded ? { routing_degraded: routingDegraded } : {}),
  };
}

// --- 3e.6. Class-A activation gate (temperloop#1219) -------------------------
// build.md §3e.6 specifies a synchronous, in-repo ACTIVATION check: an item
// carrying `activation: class: A` has its `proof:` predicate run against the
// worker's worktree BEFORE 3f pushes anything, and a Fail loops back to 3c.
// This driver — the DEFAULT Step-3 path since temperloop#998 — implemented none
// of it, and `activation` was not even in the items[] args contract, so the
// block never crossed the orchestrator→workflow boundary at all. Every gate
// plan.sh rule 14 forces onto a product-source item was therefore inert here:
// an item could merge green with its feature dormant (a runner never
// registered, a flag never flipped, a rule nothing greps for) — exactly the
// failure `Decisions/temperloop - Activation-completeness contract` exists to
// catch. THE PREDICATE IS THE GATE: there is no fallback actor and no skip arm
// (temperloop#1451), so an arriving class-A block with no `proof:` escalates
// rather than degrading to a no-op.
//
// WHY IN driveItem, BETWEEN 3e.5 AND 3f (the issue's candidate 1, chosen):
// running it parent-side after the workflow returns would put it AFTER push and
// PR-open, so a Fail would cost a re-push on an already-open PR instead of a
// loop-back to 3c. The gate's whole value is that it fires before the branch
// leaves the worktree.
//
// BYTE-IDENTICAL FOR EVERYONE ELSE: activationClass() returns '' for an item
// with no `activation` block and 'B'/'C' for a ledger-discharged one, and
// runActivationGate() returns null on the first line in those cases — zero
// agent spawns, zero log lines, zero stage transitions. B/C stay
// ledger-recorded at 4d-epic step 2a (orchestrator-side, off this path).

// activationClass(item) — the item's declared activation class, normaliz — see build-level.design-notes-4.md#activationclass-item-the-item-s-declared-activation-cla
function activationClass(item) {
  const a = item && item.activation;
  if (!a || typeof a !== 'object') return '';
  return String(a.class ?? '').trim().toUpperCase();
}

// isAbsenceProof(proof) — does the predicate ASSERT AN ABSENCE (temperlo — see build-level.design-notes-4.md#isabsenceproof-proof-does-the-predicate-assert-an-absence-te
function isAbsenceProof(proof) {
  return /^\s*!/.test(String(proof ?? ''));
}

// jsonSafeDetail — shell fragment that reduces "$__out" to a string safe — see build-level.design-notes-4.md#jsonsafedetail-shell-fragment-that-reduces-out-to-a-str
const ACTIVATION_DETAIL_FILTER =
  `__d="$(printf '%s' "$__out" | tr '\\n\\r\\t' '   ' | tr -d '\\\\"' | tr -cd '[:print:]' | tail -c 300)"`;

// activationProofCmd — run the class-A `proof:` predicate from <dir>'s r — see build-level.design-notes-4.md#activationproofcmd-run-the-class-a-proof-predicate-from-dir-
function activationProofCmd(dir, proof, passOutcome, failOutcome) {
  return [
    `cd ${sq(dir)} || { printf '{"outcome":"%s","detail":"cannot cd to the checkout root"}\\n' ${sq(failOutcome)}; exit 0; }`,
    `__out="$( { ${proof} ; } 2>&1 )"; __rc=$?`,
    ACTIVATION_DETAIL_FILTER,
    `if [ "$__rc" = 0 ]; then printf '{"outcome":"%s","exitCode":0,"detail":"%s"}\\n' ${sq(passOutcome)} "$__d";`,
    `else printf '{"outcome":"%s","exitCode":%s,"detail":"%s"}\\n' ${sq(failOutcome)} "$__rc" "$__d"; fi`,
  ].join('\n');
}

// activationControlCmd — the temperloop#944 MERGE-BASE CONTROL PASS.
// Materializes the item's merge-base as a throwaway detached worktree, runs the
// IDENTICAL predicate there, and reports which way it went:
//   ACTIVATION_CONTROL_DISCRIMINATES — the proof FAILS at the merge base, i.e.
//       it genuinely discriminates this item's work from an untouched tree.
//   ACTIVATION_CONTROL_VACUOUS      — the proof PASSES at the merge base, so it
//       would read Pass with no work done at all and proves nothing.
//   ACTIVATION_CONTROL_ERROR        — the control could not be ESTABLISHED
//       (no merge-base, worktree add failed). Never collapsed into either
//       verdict: an unestablished control is an UNKNOWN, and the #1021 lesson
//       is that an unknown must never wear a pass or a fail.
// Mirrors pr.sh's own default_branch() fallback chain (origin/HEAD, else
// main/master), the same way reviewDiffCmd does, so it never depends on pr.sh
// having run first. The temp worktree is removed plainly FIRST — git's own
// refusal is the last belt (kernel § Environment hygiene) — with --force and
// then rm -rf only as fallbacks, so a throwaway can never leak either way.
function activationControlCmd(wt, proof) {
  const err = (msg) =>
    `{ printf '{"outcome":"ACTIVATION_CONTROL_ERROR","detail":"%s"}\\n' ${sq(msg)}; exit 0; }`;
  // No `set -o pipefail` here either, and for the same reason as — see build-level.design-notes-4.md#no-set-o-pipefail-here-either-and-for-the-same-reason-a
  return [
    `cd ${sq(wt)} || ${err('cannot cd to the worktree')}`,
    `default="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')"`,
    `if [ -z "$default" ]; then`,
    `  for b in main master; do`,
    `    if git show-ref --verify --quiet "refs/remotes/origin/$b"; then default="$b"; break; fi`,
    `  done`,
    `fi`,
    `[ -n "$default" ] || default=main`,
    `__base="$(git merge-base HEAD "origin/$default" 2>/dev/null)"`,
    `[ -n "$__base" ] || ${err('cannot resolve the merge-base against origin/<default>')}`,
    `__tmp="$(mktemp -d)"`,
    `git worktree add --detach "$__tmp" "$__base" >/dev/null 2>&1 || { rm -rf "$__tmp"; ${err('cannot materialize the merge-base worktree')} }`,
    `__out="$( cd "$__tmp" && { ${proof} ; } 2>&1 )"; __rc=$?`,
    `git worktree remove "$__tmp" >/dev/null 2>&1 || git worktree remove --force "$__tmp" >/dev/null 2>&1 || rm -rf "$__tmp"`,
    `git worktree prune >/dev/null 2>&1 || true`,
    ACTIVATION_DETAIL_FILTER,
    `if [ "$__rc" = 0 ]; then printf '{"outcome":"ACTIVATION_CONTROL_VACUOUS","base":"%s","exitCode":0,"detail":"%s"}\\n' "$__base" "$__d";`,
    `else printf '{"outcome":"ACTIVATION_CONTROL_DISCRIMINATES","base":"%s","exitCode":%s,"detail":"%s"}\\n' "$__base" "$__rc" "$__d"; fi`,
  ].join('\n');
}

// gateFreshnessCmd — the §3e.5 pre-gate freshness step (temperloop#1937) — see build-level.design-notes-4.md#gatefreshnesscmd-the-3e-5-pre-gate-freshness-step-temperloop
function gateFreshnessCmd(wt, qgBin) {
  return [
    `cd ${sq(wt)} || { jq -cn '{outcome:"FRESHNESS_ERROR",detail:"cannot cd to the worktree"}'; exit 0; }`,
    // round 3 (HIGH, workflow, temperloop#1937): the SAME presence check — see build-level.design-notes-4.md#round-3-high-workflow-temperloop-1937-the-same-presence
    `[ -x ${sq(qgBin)} ] || { jq -cn '{outcome:"FRESHNESS_NO_GATE"}'; exit 0; }`,
    // round 3 (MEDIUM, shell): capture fetch stderr and retry once on a — see build-level.design-notes-4.md#round-3-medium-shell-capture-fetch-stderr-and-retry-onc
    `__ferr="$(git fetch origin main 2>&1 >/dev/null)"; __frc=$?`,
    `if [ "$__frc" -ne 0 ] && printf '%s' "$__ferr" | grep -q 'cannot lock ref'; then`,
    `  sleep 1`,
    `  __ferr="$(git fetch origin main 2>&1 >/dev/null)"; __frc=$?`,
    `fi`,
    `if [ "$__frc" -ne 0 ]; then`,
    `  jq -cn --arg detail "$__ferr" '{outcome:"FRESHNESS_ERROR",detail:("git fetch origin main failed: " + $detail)}'`,
    `  exit 0`,
    `fi`,
    `__main="$(git rev-parse origin/main 2>/dev/null)"`,
    `[ -n "$__main" ] || { jq -cn '{outcome:"FRESHNESS_ERROR",detail:"cannot resolve origin/main"}'; exit 0; }`,
    `if git merge-base --is-ancestor origin/main HEAD 2>/dev/null; then`,
    `  __base="$(git rev-parse HEAD 2>/dev/null)"`,
    `  jq -cn --arg base "$__base" --arg main "$__main" '{outcome:"FRESHNESS_CURRENT",worktree_base:$base,main:$main}'`,
    `  exit 0`,
    `fi`,
    // round 2 (HIGH, temperloop#1937): probe dirtiness BEFORE attempting the — see build-level.design-notes-4.md#round-2-high-temperloop-1937-probe-dirtiness-before-attempti
    `__dirty="$(git status --porcelain --untracked-files=no 2>/dev/null)"`,
    `if [ -n "$__dirty" ]; then`,
    `  jq -cn --arg main "$__main" --arg paths "$__dirty" '{outcome:"FRESHNESS_DIRTY",main:$main,dirty_paths:($paths|split("\\n")|map(select(length>0)))}'`,
    `  exit 0`,
    `fi`,
    `if __out="$(git rebase origin/main 2>&1)"; then`,
    `  __base="$(git rev-parse HEAD 2>/dev/null)"`,
    `  jq -cn --arg base "$__base" --arg main "$__main" '{outcome:"FRESHNESS_REBASED",worktree_base:$base,main:$main}'`,
    `else`,
    // round 3 (MEDIUM, shell): rename the captured var (was the unused `out` — see build-level.design-notes-4.md#round-3-medium-shell-rename-the-captured-var-was-the-un
    `  __conflicts_raw="$(git diff --name-only --diff-filter=U 2>/dev/null)"`,
    `  __tail="$(printf '%s' "$__out" | tail -n 8)"`,
    `  git rebase --abort >/dev/null 2>&1 || true`,
    `  if [ -n "$__conflicts_raw" ]; then`,
    `    jq -cn --arg main "$__main" --arg files "$__conflicts_raw" --arg detail "$__tail" --arg disposition "rebase aborted; worktree left intact on its pre-rebase commit" '{outcome:"FRESHNESS_CONFLICT",main:$main,conflict_files:($files|split("\\n")|map(select(length>0))),detail:$detail,disposition:$disposition}'`,
    `  else`,
    // round 3 (MEDIUM, shell): no conflicted files — NOT a content clash, so — see build-level.design-notes-4.md#round-3-medium-shell-no-conflicted-files-not-a-content-
    `    jq -cn --arg main "$__main" --arg detail "$__tail" --arg disposition "rebase failed for a reason other than a content conflict; rebase aborted, worktree left intact on its pre-rebase commit" '{outcome:"FRESHNESS_REBASE_ERROR",main:$main,detail:$detail,disposition:$disposition}'`,
    `  fi`,
    `fi`,
  ].join('\n');
}

// gateFreshnessTimeoutProbeCmd — round 2 (temperloop#1937 MEDIUM): what — see build-level.design-notes-4.md#gatefreshnesstimeoutprobecmd-round-2-temperloop-1937-medium-
function gateFreshnessTimeoutProbeCmd(wt) {
  return [
    `cd ${sq(wt)} || { jq -cn '{outcome:"FRESHNESS_ERROR",detail:"cannot cd to the worktree for the timeout probe"}'; exit 0; }`,
    `if git rebase --abort >/dev/null 2>&1; then`,
    `  jq -cn '{outcome:"FRESHNESS_TIMEOUT_PROBE",rebase_in_progress:true,aborted:true}'`,
    `else`,
    `  jq -cn '{outcome:"FRESHNESS_TIMEOUT_PROBE",rebase_in_progress:false,aborted:false}'`,
    `fi`,
  ].join('\n');
}

// runGateFreshness(item, wt, qgBin) — drives gateFreshnessCmd() as ONE solo
// machinery call and returns an ESCALATION object to return straight out of
// driveItem, or null to proceed to §3e.5 unchanged. Mirrors runActivationGate()'s
// own shape (denied/timeout handled identically) — deliberately the SAME
// pattern, not a new one. `qgBin` is the caller's already-resolved
// `<wt>/scripts/quality-gates.sh` path (temperloop#1937 round 3) — passed
// through rather than re-derived, so this function's own presence check can
// never drift from gateCmd's.
async function runGateFreshness(item, wt, qgBin) {
  const out = await runMachinery(gateFreshnessCmd(wt, qgBin), {
    label: `gate-freshness:${item.slug}`,
    slug: item.slug,
    phase: enterStage(STAGE_GATE),
    timeoutOutcome: 'FRESHNESS_TIMEOUT',
  });
  if (machineryDenied(out)) {
    // temperloop#1819: quota death vs genuine denial — see deniedOrQuota.
    return await deniedOrQuota(item.slug, { step: 'gate-freshness', out }, wt);
  }
  if (out.outcome === 'STEP_TIMEOUT') {
    return (await disposeStepTimeout(item, wt, out, 'gate-freshness', { adoptable: false })).escalation;
  }
  if (out.outcome === 'FRESHNESS_NO_GATE') {
    // round 3 (HIGH, workflow): no vendored gate script — byte-identical to — see build-level.design-notes-4.md#round-3-high-workflow-no-vendored-gate-script-byte-iden
    log(`[${item.slug}] pre-gate freshness — no vendored scripts/quality-gates.sh; skipping fetch/rebase (byte-identical pre-#1937 path)`);
    return null;
  }
  if (out.outcome === 'FRESHNESS_DIRTY') {
    // round 2 (HIGH, temperloop#1937): git refused to even START the rebase — see build-level.design-notes-4.md#round-2-high-temperloop-1937-git-refused-to-even-start-the-r
    return escalate(item.slug, 'dirty-worktree', {
      step: 'gate-freshness',
      main: out.main ?? null,
      dirty_paths: out.dirty_paths ?? [],
    });
  }
  if (out.outcome === 'FRESHNESS_CONFLICT') {
    // Never `acceptance-gate-failed` — the gate never ran, so a Fail verdict — see build-level.design-notes-4.md#never-acceptance-gate-failed-the-gate-never-ran-so-a-fail-ve
    return escalate(item.slug, 'stale-worktree', {
      main: out.main ?? null,
      conflict_files: out.conflict_files ?? [],
      detail: out.detail ?? null,
      disposition: out.disposition ?? 'rebase aborted; worktree left intact on its pre-rebase commit',
    });
  }
  if (out.outcome === 'FRESHNESS_REBASE_ERROR') {
    // round 3 (MEDIUM, shell): a rebase failure with NO conflicted files — see build-level.design-notes-4.md#round-3-medium-shell-a-rebase-failure-with-no-conflicte
    return escalate(item.slug, 'stale-worktree', {
      reason: 'rebase-failed',
      main: out.main ?? null,
      conflict_files: [],
      detail: out.detail ?? null,
      disposition: out.disposition ?? 'rebase failed for a reason other than a content conflict; rebase aborted, worktree left intact on its pre-rebase commit',
    });
  }
  if (out.outcome === 'FRESHNESS_TIMEOUT') {
    // round 2 (MEDIUM, temperloop#1937): the outer Bash-tool timeout can kil — see build-level.design-notes-4.md#round-2-medium-temperloop-1937-the-outer-bash-tool-timeout-c
    const probe = await runMachinery(gateFreshnessTimeoutProbeCmd(wt), {
      label: `gate-freshness:${item.slug}`,
      slug: item.slug,
      phase: enterStage(STAGE_GATE),
      timeoutOutcome: 'FRESHNESS_TIMEOUT_PROBE_ERROR',
    });
    if (machineryDenied(probe)) {
      // temperloop#1819: quota death vs genuine denial — see deniedOrQuota.
      return await deniedOrQuota(item.slug, { step: 'gate-freshness-timeout-probe', out: probe }, wt);
    }
    // round 3 (MEDIUM, workflow): trust `rebase_in_progress`/`aborted` ONLY — see build-level.design-notes-4.md#round-3-medium-workflow-trust-rebase-in-progress-aborted-onl
    const probeResolved = probe.outcome === 'FRESHNESS_TIMEOUT_PROBE';
    const rebaseInProgress = probeResolved ? probe.rebase_in_progress === true : null;
    const aborted = probeResolved ? probe.aborted === true : null;
    const disposition = !probeResolved
      ? 'probe timed out — rebase state unknown, check `git rev-parse --git-path rebase-merge` by hand before re-driving'
      : rebaseInProgress
        ? 'the fetch/rebase step outlived its time budget mid-rebase; the in-progress rebase was aborted and the worktree left on its pre-rebase commit'
        : 'the fetch/rebase step outlived its time budget; no rebase was left in progress on the worktree';
    log(`[${item.slug}] pre-gate freshness — outer timeout during fetch/rebase; timeout-probe outcome=${probe.outcome ?? 'none'} rebase_in_progress=${String(rebaseInProgress)} (aborted=${String(aborted)}); escalating stale-worktree`);
    return escalate(item.slug, 'stale-worktree', {
      reason: 'timeout',
      rebase_in_progress: rebaseInProgress,
      aborted,
      probe_outcome: probe.outcome ?? null,
      disposition,
    });
  }
  if (out.outcome === 'FRESHNESS_REBASED') {
    log(`[${item.slug}] pre-gate freshness — rebased onto origin/main (worktree_base ${String(out.worktree_base ?? '').slice(0, 12)}, main ${String(out.main ?? '').slice(0, 12)}) before running §3e.5`);
  } else if (out.outcome === 'FRESHNESS_CURRENT') {
    log(`[${item.slug}] pre-gate freshness — worktree already at or ahead of origin/main (${String(out.main ?? '').slice(0, 12)}); no rebase needed`);
  } else {
    // FRESHNESS_ERROR or any unrecognized outcome: fail OPEN. Not evidence — see build-level.design-notes-4.md#freshness-error-or-any-unrecognized-outcome-fail-open-n
    log(`[${item.slug}] pre-gate freshness — unresolved (${out.outcome ?? 'no outcome'}); proceeding to §3e.5 on the worktree as-is`);
  }
  return null;
}

// runActivationGate(item, wt) — the §3e.6 gate. Returns an ESCALATION object to
// return straight out of driveItem, or null to proceed to 3f.
//
// Ordering is the contract, not an implementation detail: for an absence-
// asserting predicate the control pass runs FIRST and a VACUOUS verdict
// escalates WITHOUT EVER RUNNING THE WORKTREE COPY (build.md §3e.6: "escalate
// … and loop back to 3c exactly like a Fail, without even checking the worktree
// copy"). That is why the control is its own machinery call rather than a
// branch inside one combined shell command — the ordering is then observable,
// and a test can assert the worktree run never happened.
async function runActivationGate(item, wt) {
  if (activationClass(item) !== 'A') return null; // no block, or class B/C — byte-identical path

  const proof = typeof item.activation.proof === 'string' ? item.activation.proof.trim() : '';
  if (!proof) {
    // temperloop#1451: plan.sh rule 13 fails a class-A block with no `proof: — see build-level.design-notes-4.md#temperloop-1451-plan-sh-rule-13-fails-a-class-a-block-w
    return escalate(item.slug, 'activation-proof-missing', {
      class: 'A',
      locus: item.activation.locus ?? null,
      reason: 'a class: A activation block reached §3e.6 with no proof: predicate; the predicate IS the gate (temperloop#1451) — author it, do not weaken or remove the block',
    });
  }

  const absence = isAbsenceProof(proof);
  const base = { class: 'A', proof, absenceAsserting: absence, locus: item.activation.locus ?? null };

  if (absence) {
    const ctl = await runMachinery(activationControlCmd(wt, proof), {
      label: `activation-control:${item.slug}`,
      slug: item.slug,
      phase: enterStage(STAGE_GATE),
      timeoutOutcome: 'ACTIVATION_TIMEOUT',
    });
    if (machineryDenied(ctl)) {
      // temperloop#1819: quota death vs genuine denial — see deniedOrQuota.
      return await deniedOrQuota(item.slug, { step: 'activation-control', out: ctl }, wt);
    }
    if (ctl.outcome === 'STEP_TIMEOUT') {
      return (await disposeStepTimeout(item, wt, ctl, 'activation-control', { adoptable: false })).escalation;
    }
    if (ctl.outcome === 'ACTIVATION_CONTROL_VACUOUS') {
      // The proof reads Pass on a tree where this item's work never happened,  — see build-level.design-notes-4.md#the-proof-reads-pass-on-a-tree-where-this-item-s-work-n
      return escalate(item.slug, 'absence-proof-vacuous-at-merge-base', {
        ...base,
        mergeBase: ctl.base ?? null,
        detail: ctl.detail ?? '',
        reason: 'the absence-asserting proof: ALSO passes at the merge base, so it proves nothing about this item\'s work (temperloop#944). Re-author it in the wrap-immune form plan-schema.md § activation documents; do NOT relax the gate.',
      });
    }
    if (ctl.outcome !== 'ACTIVATION_CONTROL_DISCRIMINATES') {
      // ACTIVATION_CONTROL_ERROR / ACTIVATION_TIMEOUT / anything unexpected: t — see build-level.design-notes-4.md#activation-control-error-activation-timeout-anything-un
      return escalate(item.slug, 'activation-control-unavailable', {
        ...base,
        outcome: ctl.outcome,
        detail: ctl.detail ?? '',
        reason: 'the merge-base control pass could not be established, so an absence-asserting proof cannot be trusted either way; re-run once the merge-base worktree can be materialized',
      });
    }
    log(`[${item.slug}] 3e.6 activation control PASS — the absence proof FAILS at merge base ${String(ctl.base ?? '').slice(0, 12)}, so it discriminates`);
  }

  const out = await runMachinery(activationProofCmd(wt, proof, 'ACTIVATION_PASS', 'ACTIVATION_FAIL'), {
    label: `activation:${item.slug}`,
    slug: item.slug,
    phase: enterStage(STAGE_GATE),
    timeoutOutcome: 'ACTIVATION_TIMEOUT',
  });
  if (machineryDenied(out)) {
    // temperloop#1819: quota death vs genuine denial — see deniedOrQuota.
    return await deniedOrQuota(item.slug, { step: 'activation', out }, wt);
  }
  if (out.outcome === 'STEP_TIMEOUT') {
    return (await disposeStepTimeout(item, wt, out, 'activation', { adoptable: false })).escalation;
  }
  if (out.outcome !== 'ACTIVATION_PASS') {
    // Fail (or an unknown/timeout outcome, which is equally not a Pass) → lo — see build-level.design-notes-4.md#fail-or-an-unknown-timeout-outcome-which-is-equally-not
    return escalate(item.slug, 'activation-failed', {
      ...base,
      outcome: out.outcome,
      exitCode: out.exitCode ?? null,
      detail: out.detail ?? '',
      reason: 'the class: A activation proof did not pass against the worker\'s worktree — the built thing is not reachable on the running path. Add the missing wiring; do NOT weaken the predicate.',
    });
  }
  log(`[${item.slug}] 3e.6 activation gate PASS — class A${absence ? ' (absence-asserting, control-verified at merge base)' : ''}`);
  return null;
}

// =============================================================================
// THE DUAL-BUILD HARNESS (temperloop#2080, epic #2065) — arms + level barrier
// =============================================================================
// WHAT THIS ITEM DOES, AND DELIBERATELY DOES NOT DO. Given a `dualBuild`
// workflow input, every IN-SCOPE item of the level is built TWICE — once per
// arm, each arm on its own model, in its own `@<arm>`-suffixed worktree and
// branch — locally gated per arm, then pairwise-judged. It records one ledger
// row per item per arm and STOPS: the level pick, the winner's route to PR, the
// two operator levers and the losing arm's archive/delete are
// `level-pick-and-operator-levers` (temperloop#2083). The barrier is exactly
// that stopping point, and it is the whole reason driveItem was split above:
// ADR 0038 fixes the unit of JUDGEMENT at the item and the unit of CHOICE at
// the level, so no PR may open for an in-scope item until every in-scope arm in
// the level has a gate result and every in-scope item has a judge disposition.
//
// A NOT-IN-SCOPE item of the same level is untouched by all of this: one build,
// the ordinary single-arm driveItem (PR, CI, park), plus one ledger row marking
// it out of scope so the level's ledger accounts for every item rather than
// only the compared ones.
//
// NOTHING BELOW RUNS WITHOUT `input.dualBuild`. dualBuildInput() returns null
// for every ordinary invocation, buildLevel() takes its pre-#2080 fan-out, and
// the only trace this code leaves on a flag-less run is the residue guard
// folded into the existing worktree-create step (which prints nothing of its
// own on a clean tree — see its comment at 3b).
// =============================================================================

// The two arm names, in START ORDER. `baseline` is arm A / `--record-a`  — see build-level.design-notes-4.md#the-two-arm-names-in-start-order-baseline-is-arm-a-reco
const DUAL_BUILD_ARMS = ['baseline', 'candidate'];

// The marker the arm-read-isolation guard (temperloop#2077) appends a li — see build-level.design-notes-4.md#the-marker-the-arm-read-isolation-guard-temperloop-2077
const DUAL_BUILD_ATTEMPTS_FILE = '.dual-build-cross-read-attempts.jsonl';

// dualBuildInput — normalize and VALIDATE `input.dualBuild`.
// Returns null (no dual build — every existing invocation), a normalized
// descriptor, or `{ invalid: <reason> }`. There is deliberately no third,
// silent arm: a `dualBuild` key that is present but unusable REFUSES the level
// rather than degrading to a single-arm build, because a level that was asked
// to compare two models and quietly compared none is exactly the result nobody
// can tell from a successful one after the fact.
function dualBuildInput() {
  const d = input.dualBuild;
  if (d == null) return null;
  if (typeof d !== 'object' || Array.isArray(d)) {
    return { invalid: 'dualBuild must be an object { tier, baseline, candidate, inScope: [slug…] }' };
  }
  const str = (v) => (typeof v === 'string' && v.trim() ? v.trim() : '');
  const tier = str(d.tier);
  const baseline = str(d.baseline);
  const candidate = str(d.candidate);
  const inScope = Array.isArray(d.inScope) ? d.inScope.map(str).filter(Boolean) : null;
  const missing = [];
  if (!tier) missing.push('tier');
  if (!baseline) missing.push('baseline');
  if (!candidate) missing.push('candidate');
  // An EMPTY inScope is as unusable as an absent one, and `![]` is false, so a
  // truthiness check alone lets it through (temperloop#2080 review round 3). A
  // present-but-empty array reaches here two ways: the caller passed `inScope: []`,
  // or every entry was blank/non-string and `.map(str).filter(Boolean)` scrubbed it.
  // Either way `dual.inScope` becomes an empty Set, EVERY item then misses
  // `inScope.has(slug)` and takes the single-arm path, and the level reports a
  // dualBuild summary having compared nothing — precisely the outcome this function
  // refuses rather than degrades into.
  if (!inScope || inScope.length === 0) missing.push('inScope');
  if (missing.length > 0) {
    return { invalid: `dualBuild is missing or empty: ${missing.join(', ')}` };
  }
  if (baseline === candidate) {
    // Not refused — an A/A instrument check (both arms the same model, the — see build-level.design-notes-4.md#not-refused-an-a-a-instrument-check-both-arms-the-same-
    log(
      `dual-build: baseline and candidate are the SAME model (${baseline}) — this is an A/A instrument ` +
        'check, not a candidate-vs-baseline comparison. No arm difference it reports is a model difference.',
    );
  }
  return { tier, baseline, candidate, inScope: new Set(inScope), inScopeList: inScope };
}

// dualBuildResidueGuard — wrap the worktree-create command in the flag-less
// resume refusal (see the 3b comment for WHY it lives inside this step rather
// than in a probe of its own). On a clean tree the emitted script runs the
// create command verbatim and prints its CREATED line and nothing else, so a
// flag-less run's output is byte-identical to the pre-#2080 one.
function dualBuildResidueGuard(repoRoot, slug, createCmd) {
  const armGlobPrefix = sq(`${repoRoot}.wt/${slug}@`);
  return [
    // The matched paths are interpolated into a JSON string field below, so — see build-level.design-notes-4.md#the-matched-paths-are-interpolated-into-a-json-string-field-
    `__dbres=$(ls -d ${armGlobPrefix}* 2>/dev/null | tr '\\n' ' ' | tr -d '\\\\"')`,
    'if [ -n "$__dbres" ]; then',
    `printf '{"outcome":"DUAL_BUILD_RESIDUE","arms":"%s"}\\n' "$__dbres"`,
    'else',
    createCmd,
    'fi',
  ].join('\n');
}

// armItem — the per-arm view of a plan item. Three fields move and nothing else
// does, which is what lets the ENTIRE phase-1 body run unmodified for an arm:
//   slug   → `<slug>@<arm>`  … every label, every /tmp/qg-<…> path and every
//            deterministic worktree path in phase 1 is derived from item.slug,
//            so suffixing it here is what stops two arms of one item colliding
//            on a gate log, a selection pin or a worktree — without threading an
//            "arm key" parameter through forty call sites.
//   branch → `build/<slug>@<arm>` … matches what `worktree.sh create --arm`
//            actually creates, so the recover-probe and any later push address
//            the arm's own ref rather than the item's shared one.
//   model  → that arm's model … and because callWorker() reads item.model on
//            BOTH the first spawn and the #1219 foreground-cure retry, the
//            retry stays on the arm's own model by construction. There is no
//            tier-escalation path here to opt out of: nothing in this driver
//            ever substitutes a stronger model for a failed worker.
function armItem(item, armName, model) {
  return {
    ...item,
    slug: `${item.slug}@${armName}`,
    branch: `build/${item.slug}@${armName}`,
    model,
  };
}

// dualBuildSplitModel — "<provider>/<model>" → { provider, model }; a bare model
// id means the host's default provider (candidate-session.sh's own
// `_CS_DEFAULT_PROVIDER`), which is also what an omitted `--provider` means to
// that script.
function dualBuildSplitModel(spec) {
  const i = String(spec).indexOf('/');
  return i > 0
    ? { provider: String(spec).slice(0, i), model: String(spec).slice(i + 1) }
    : { provider: '', model: String(spec) };
}

// -----------------------------------------------------------------------------
// candidateArmGate — the candidate arm's host-supply + containment seam.
// -----------------------------------------------------------------------------
// Every candidate arm passes through `candidate-session.sh` BEFORE it builds:
// `resolve` proves the containment overlay is present, readable and well-formed
// (the same fail-closed check judge.sh's own pairwise mode runs), and
// `preflight` proves the candidate provider's credential is actually SET rather
// than merely named. A refusal is an INFRA loss for that arm, recorded as such —
// never a silent single-arm level.
//
// WHY THE WORKER ITSELF IS NOT SPAWNED BY `candidate-session.sh spawn`, AND WHY
// A NON-DEFAULT PROVIDER IS THEREFORE REFUSED HERE. `spawn` runs a `claude` CLI
// child inside whatever shell invokes it. In this driver the only shell is an
// executor agent's Bash tool, hard-capped at AGENT_BASH_CAP_MS (~10 minutes) —
// DESIGN NOTE 1/2. A build worker is an hour-scale process, so routing it
// through `spawn` would not produce a contained candidate session; it would
// produce a worker killed mid-build on every non-trivial item. The reachable
// spawn seam with no such cap is the runtime's own `agent({ model })`, which
// addresses the host session's provider only.
//
// So the seam is honest about its edge rather than silently exceeding it: a
// candidate naming the DEFAULT provider builds through `agent({ model })` (the
// A/A instrument check and every same-provider tier comparison — the epic's own
// first live run), and a candidate naming a NON-DEFAULT provider is REFUSED by
// name with an `infra` row. It is never spawned uncontained, which is the one
// outcome that would defeat candidate-session.sh's whole purpose. Lifting that
// edge needs an uncapped spawn seam, which is its own piece of work, not a
// silent widening here.
async function candidateArmGate(ai, dual) {
  const { provider } = dualBuildSplitModel(dual.candidate);
  const csBin = sq(`${input.repoRoot}/workflows/scripts/model-comparison/candidate-session.sh`);
  const providerFlag = provider ? ` --provider ${sq(provider)}` : '';
  const cmd = [
    `__cs=${csBin}`,
    'if [ ! -f "$__cs" ]; then',
    `printf '{"outcome":"CANDIDATE_REFUSED","reason":"seam-absent","detail":"candidate-session.sh not found at %s"}\\n' "$__cs"`,
    'elif ! bash "$__cs" resolve Read >/dev/null 2>&1; then',
    `printf '{"outcome":"CANDIDATE_REFUSED","reason":"containment-unusable","detail":"candidate-session.sh resolve refused: the containment overlay is absent, unreadable or malformed"}\\n'`,
    `elif ! bash "$__cs" preflight${providerFlag} --execution live >/dev/null 2>&1; then`,
    `printf '{"outcome":"CANDIDATE_REFUSED","reason":"preflight-failed","detail":"candidate-session.sh preflight refused provider %s — its credential is unset or the provider is unregistered"}\\n' ${sq(provider || '(default)')}`,
    provider ? 'elif [ -n "x" ]; then' : 'else',
    ...(provider
      ? [
          `printf '{"outcome":"CANDIDATE_REFUSED","reason":"non-default-provider-unspawnable","detail":"candidate provider %s needs candidate-session.sh spawn, which cannot host an hour-scale build worker under the executor Bash cap — refusing rather than spawning it uncontained"}\\n' ${sq(provider)}`,
          'else',
          `printf '{"outcome":"CANDIDATE_READY"}\\n'`,
        ]
      : [`printf '{"outcome":"CANDIDATE_READY"}\\n'`]),
    'fi',
  ].join('\n');
  const out = await runMachinery(cmd, {
    label: `candidate-session:${ai.slug}`,
    slug: ai.slug,
    phase: enterStage(STAGE_CLAIM),
  });
  if (machineryDenied(out) || out.outcome !== 'CANDIDATE_READY') {
    return {
      ok: false,
      reason: (out && out.reason) || 'seam-unreachable',
      detail: (out && out.detail) || `candidate-session.sh gate returned ${JSON.stringify(out && out.outcome)}`,
    };
  }
  return { ok: true };
}

// -----------------------------------------------------------------------------
// dualBuildLossReason — the ONE mapping from a phase-1 terminal record to the
// ledger's closed `loss_reason` vocabulary (gate | judge | infra | incomplete).
// -----------------------------------------------------------------------------
// Kept as one function rather than inline at the two call sites so the ledger's
// vocabulary has a single author: a row that says `infra` when the branch was
// actually red is a comparison result nobody can trust afterwards.
//   gate        — the acceptance gate itself reported RED, or could not finish
//                 (a timeout is not evidence about the tree, but it IS the gate
//                 failing to produce a verdict for this arm, which is a loss).
//   incomplete  — the WORKER did not reach a gate-passing state: it escalated a
//                 verdict (blocked / design-fork / failed), left acceptance
//                 bullets failing, or its review round never converged. The arm
//                 built something; it just is not finishable without a human.
//   infra       — everything else: machinery, claim, worktree, quota, denial,
//                 dependency ordering, a lost return. Nothing was learned about
//                 the model from these, which is precisely why they are named
//                 apart from the two above.
const DUAL_BUILD_GATE_KINDS = new Set(['acceptance-gate-failed', 'acceptance-gate-timeout']);
const DUAL_BUILD_INCOMPLETE_KINDS = new Set([
  'blocked', 'design-fork', 'failed', 'acceptance-incomplete', 'review-blocking',
]);
function dualBuildLossReason(kind) {
  if (DUAL_BUILD_GATE_KINDS.has(kind)) return 'gate';
  if (DUAL_BUILD_INCOMPLETE_KINDS.has(kind)) return 'incomplete';
  return 'infra';
}

// driveArm — build ONE arm of ONE in-scope item through phase 1 only. — see build-level.design-notes-4.md#drivearm-build-one-arm-of-one-in-scope-item-through-phase-1-
async function driveArm(item, dual, armName, order) {
  const model = armName === 'baseline' ? dual.baseline : dual.candidate;
  const sibling = armName === 'baseline' ? 'candidate' : 'baseline';
  const ai = armItem(item, armName, model);
  const base = {
    arm: armName,
    order,
    model,
    key: ai.slug,
    wt: `${input.repoRoot}.wt/${ai.slug}`,
    branch: ai.branch,
    wtBase: '',
    guardArmed: 'UNKNOWN',
    ctx: null,
    cost: null,
    acceptanceResults: [],
  };

  if (armName === 'candidate') {
    const gate = await candidateArmGate(ai, dual);
    if (!gate.ok) {
      log(`[${ai.slug}] dual-build candidate arm REFUSED at the candidate-session seam (${gate.reason}): ${gate.detail}`);
      return { ...base, gate: 'fail', lossReason: 'infra', failure: { kind: `candidate-session:${gate.reason}`, detail: gate.detail } };
    }
  }

  const built = await driveItemBuild(ai, { name: armName, sibling, slug: item.slug, order });
  // temperloop#2080 round-1 review [MEDIUM]. driveItemBuildPhase returns a — see build-level.design-notes-4.md#temperloop-2080-round-1-review-medium-driveitembuildphase-re
  if (built.result && built.result._kind === 'parked') {
    log(`[${ai.slug}] dual-build arm completed as a read-only spike verdict (no worktree, no gate) — a passing arm, not a loss`);
    return {
      ...base,
      gate: 'pass',
      lossReason: null,
      spike: true,
      acceptanceResults: built.result.parked?.acceptance_results ?? [],
    };
  }
  if (built.result) {
    const kind = built.result.escalation.kind;
    const lossReason = dualBuildLossReason(kind);
    log(`[${ai.slug}] dual-build arm did not reach a gate-passing branch (${kind}) — recorded as a ${lossReason} loss`);
    return {
      ...base,
      gate: 'fail',
      lossReason,
      failure: { kind, payload: built.result.escalation.payload },
    };
  }
  const ctx = built.ctx;
  return {
    ...base,
    gate: 'pass',
    lossReason: null,
    ctx,
    wtBase: ctx.wtBase || '',
    guardArmed: ctx.wtGuard || 'UNKNOWN',
    acceptanceResults: ctx.verdict?.acceptance_results ?? [],
    cost: {
      tokens_in: ctx.mainCost?.tokensIn ?? null,
      tokens_out: ctx.mainCost?.tokensOut ?? null,
      wall_clock_ms: ctx.mainCost?.wallClockMs ?? null,
      retry_tokens: null,
      retry_count: 0,
      recovery: !!ctx.recovery,
    },
  };
}

// dualBuildCost — a row's cost object, always all six keys, honest nulls for an
// arm that never returned a worker verdict (same posture park()'s own cost
// block takes: a ledger with silently-missing rows is worse than one with
// honest nulls).
function dualBuildCost(armResult) {
  return armResult.cost ?? {
    tokens_in: null, tokens_out: null, wall_clock_ms: null,
    retry_tokens: null, retry_count: 0, recovery: false,
  };
}

// judgeArms — the pairwise judge call, run AT the barrier (temperloop#20 — see build-level.design-notes-4.md#judgearms-the-pairwise-judge-call-run-at-the-barrier-temperl
async function judgeArms(item, dual, arms) {
  const a = arms.find((x) => x.arm === 'baseline');
  const b = arms.find((x) => x.arm === 'candidate');
  if (!a || !b || a.gate !== 'pass' || b.gate !== 'pass') {
    const lost = [a, b].filter((x) => x && x.gate !== 'pass').map((x) => x.arm);
    return {
      judged: false,
      reason: 'one-arm-only',
      detail: `no pairwise comparison is possible: ${lost.join(' and ')} produced no gate-passing branch`,
      judge: null,
    };
  }
  // temperloop#2080 round-1 review [MEDIUM], the companion to driveArm's — see build-level.design-notes-4.md#temperloop-2080-round-1-review-medium-the-companion-to-drive
  if (a.spike || b.spike) {
    return {
      judged: false,
      reason: 'spike-arm',
      detail: `${item.slug} is a read-only spike: its arms produce a verdict note rather than a diff, so a pairwise code judge has nothing to compare`,
      judge: null,
    };
  }
  const mcDir = `${input.repoRoot}/workflows/scripts/model-comparison`;
  // The item half of both records, identical by construction — judge.sh's  — see build-level.design-notes-4.md#the-item-half-of-both-records-identical-by-construction
  const itemBlock = {
    issue: item.ghIssue ? Number(item.ghIssue) : null,
    title: item.title ?? item.slug,
    scope: item.scope ?? '',
    acceptance: acceptanceList(item),
  };
  const recordFor = (arm) => JSON.stringify({
    ...itemBlock,
    candidate: { provider: dualBuildSplitModel(arm.model).provider || 'anthropic', model: dualBuildSplitModel(arm.model).model },
    score: { diff: { text_excerpt: '' } },
  });
  const diffCmd = (arm) =>
    `git -C ${sq(arm.wt)} diff ${sq(arm.wtBase || 'HEAD')}..HEAD 2>/dev/null | head -c 200000`;
  const cmd = [
    `__mc=${sq(mcDir)}`,
    'if [ ! -f "$__mc/judge.sh" ]; then',
    `printf '{"outcome":"JUDGE_UNAVAILABLE","reason":"seam-absent"}\\n'`,
    'else',
    '__jd=$(mktemp -d) || __jd=""',
    'if [ -z "$__jd" ]; then',
    `printf '{"outcome":"JUDGE_UNAVAILABLE","reason":"scratch-dir-failed"}\\n'`,
    'else',
    `printf %s ${sq(recordFor(a))} | jq -c --arg d "$(${diffCmd(a)})" '.score.diff.text_excerpt=$d' > "$__jd/a.json"`,
    `printf %s ${sq(recordFor(b))} | jq -c --arg d "$(${diffCmd(b)})" '.score.diff.text_excerpt=$d' > "$__jd/b.json"`,
    // THE VERDICT IS READ UN-PIPED (temperloop#2080 round-2 review [HIGH]), — see build-level.design-notes-4.md#the-verdict-is-read-un-piped-temperloop-2080-round-2-review-
    `__jo=$(bash "$__mc/judge.sh" pairwise --record-a "$__jd/a.json" --record-b "$__jd/b.json" --live --repo ${sq(input.ownerRepo ?? '')} 2>/dev/null); __jr=$?`,
    `__jo=$(printf '%s\\n' "$__jo" | tail -1)`,
    'rm -rf "$__jd"',
    // A non-JSON last line is a NAMED refusal, never interpolated: this prin — see build-level.design-notes-4.md#a-non-json-last-line-is-a-named-refusal-never-interpola
    'if [ "$__jr" -eq 0 ] && [ -n "$__jo" ] && printf %s "$__jo" | jq -e . >/dev/null 2>&1; then',
    `printf '{"outcome":"JUDGED","judge":%s}\\n' "$__jo"`,
    'elif [ "$__jr" -eq 0 ] && [ -n "$__jo" ]; then',
    `printf '{"outcome":"JUDGE_UNAVAILABLE","reason":"judge-unparseable","rc":0}\\n'`,
    'else',
    `printf '{"outcome":"JUDGE_UNAVAILABLE","reason":"judge-refused","rc":%s}\\n' "$__jr"`,
    'fi',
    'fi',
    'fi',
  ].join('\n');
  const out = await runMachinery(cmd, {
    label: `judge:${item.slug}`,
    slug: item.slug,
    phase: enterStage(STAGE_GATE),
  });
  if (machineryDenied(out) || out.outcome !== 'JUDGED' || !out.judge || typeof out.judge !== 'object') {
    return {
      judged: false,
      reason: (out && out.reason) || 'judge-unavailable',
      detail: `judge.sh pairwise produced no verdict for ${item.slug} (${JSON.stringify(out && out.outcome)})`,
      judge: null,
    };
  }
  // preference "A" is the BASELINE arm and "B" the CANDIDATE arm — the — see build-level.design-notes-5.md#preference-a-is-the-baseline-arm-and-b-the-candidate-ar
  const pref = String(out.judge.preference ?? '');
  const prefersArm = pref === 'A' ? 'baseline' : pref === 'B' ? 'candidate' : null;
  return {
    judged: true,
    reason: null,
    judge: {
      preference: out.judge.preference ?? null,
      margin: out.judge.margin ?? null,
      order_agreement: out.judge.order_agreement ?? null,
    },
    prefersArm,
  };
}

// appendDualBuildRows — the ledger write (temperloop#2072). — see build-level.design-notes-4.md#appenddualbuildrows-the-ledger-write-temperloop-2072
async function appendDualBuildRows(item, dual, rows, labelHint) {
  if (rows.length === 0) return { appended: 0, rejected: 0, unavailable: false };
  const ledgerBin = sq(`${input.repoRoot}/workflows/scripts/model-comparison/dual-build-ledger.sh`);
  const versionFile = sq(`${input.repoRoot}/VERSION`);
  const steps = rows.map(({ row, wt, arm }) => ({
    kind: `row-${arm}`,
    cmd: [
      `__led=${ledgerBin}`,
      'if [ ! -f "$__led" ]; then',
      `printf '{"outcome":"ROW_UNAVAILABLE","arm":"%s","reason":"dual-build-ledger.sh not found"}\\n' ${sq(arm)}`,
      'else',
      `__ca=false; [ -s ${sq(`${wt}/${DUAL_BUILD_ATTEMPTS_FILE}`)} ] && __ca=true`,
      `__hs=$(git -C ${sq(wt)} rev-parse HEAD 2>/dev/null); [ -n "$__hs" ] || __hs=unknown`,
      `__mv=$(head -1 ${versionFile} 2>/dev/null | tr -d '[:space:]'); [ -n "$__mv" ] || __mv=unknown`,
      `__row=$(printf %s ${sq(row)} | jq -c --argjson ca "$__ca" --arg hs "$__hs" --arg mv "$__mv" '.cross_read_attempted=$ca | .head_sha=$hs | .machinery_version=$mv')`,
      'if [ -z "$__row" ]; then',
      `printf '{"outcome":"ROW_REJECTED","arm":"%s","reason":"row could not be assembled"}\\n' ${sq(arm)}`,
      'elif bash "$__led" append --row "$__row" >/dev/null 2>&1; then',
      `printf '{"outcome":"ROW_APPENDED","arm":"%s"}\\n' ${sq(arm)}`,
      'else',
      `printf '{"outcome":"ROW_REJECTED","arm":"%s","reason":"dual-build-ledger.sh append refused the row"}\\n' ${sq(arm)}`,
      'fi',
      'fi',
    ].join('\n'),
  }));
  const batch = await runMachineryBatch(steps, {
    label: `dual-build-rows${labelHint ? `-${labelHint}` : ''}:${item.slug}`,
    slug: item.slug,
    bashTimeoutMs: BATCH_BASH_TIMEOUT_MS,
    phase: enterStage(STAGE_GATE),
  });
  if (batch.denied) {
    log(`[${item.slug}] dual-build ledger write DENIED — no rows recorded for this item; the arms' builds stand, the comparison record does not`);
    return { appended: 0, rejected: 0, unavailable: true };
  }
  let appended = 0;
  let rejected = 0;
  batch.results.forEach((r) => {
    if (r && r.outcome === 'ROW_APPENDED') appended += 1;
    else rejected += 1;
  });
  if (rejected > 0) {
    log(
      `[${item.slug}] dual-build ledger: ${appended} row(s) appended, ${rejected} NOT recorded ` +
        `(${batch.results.filter((r) => r && r.outcome !== 'ROW_APPENDED').map((r) => `${r.arm ?? '?'}: ${r.reason ?? r.outcome}`).join('; ')}) ` +
        '— the comparison is incomplete for this item and the level pick must not treat it as judged',
    );
  }
  return { appended, rejected, unavailable: false };
}

// dualBuildRow — compose ONE ledger row. `cross_read_attempted`, `head_sha` and
// `machinery_version` are placeholders here; the executor overwrites all three
// (see appendDualBuildRows). Every other field is authored here.
function dualBuildRow(item, dual, armResult, judgeOutcome, extra) {
  return JSON.stringify({
    tier: dual.tier,
    model: armResult.model,
    slug: item.slug,
    arm: armResult.arm,
    base_sha: armResult.wtBase || 'unknown',
    head_sha: 'unknown',
    start_order: armResult.order,
    gate: armResult.gate,
    cost: dualBuildCost(armResult),
    judge: judgeOutcome && judgeOutcome.judged ? judgeOutcome.judge : null,
    // The LEVEL pick is `level-pick-and-operator-levers` (temperloop#2083),  — see build-level.design-notes-5.md#the-level-pick-is-level-pick-and-operator-levers-temper
    pick: null,
    override: { applied: false },
    loss_reason: armResult.lossReason ?? null,
    cross_read_attempted: false,
    guard_armed: armResult.guardArmed,
    machinery_version: 'unknown',
    ...(extra ?? {}),
  });
}

// driveInScopeItem — one in-scope item: two arms, the barrier's local ha — see build-level.design-notes-4.md#driveinscopeitem-one-in-scope-item-two-arms-the-barrier-s-lo
async function driveInScopeItem(item, dual, boardWrites) {
  // The BUFFERED board write (see 3a's own comment). Recorded once per ITE — see build-level.design-notes-5.md#the-buffered-board-write-see-3a-s-own-comment-recorded-
  if (input.board && item.ghIssue) {
    const claimBin = input.claimCmd ?? 'claim.sh';
    boardWrites.push({
      slug: item.slug,
      issue: item.ghIssue,
      board: input.board,
      cmd: `${claimBin} ${item.ghIssue} --board ${input.board}`,
      buffered_until: 'level-pick',
      reason:
        'an in-scope item is built under two arms; the claim is a statement about the ITEM and the ' +
        'Done/close cascade must follow the arm that WON, so the board write is held until the pick',
    });
  }
  // START ORDER. parallel() invokes its thunks in array order, synchronous — see build-level.design-notes-4.md#start-order-parallel-invokes-its-thunks-in-array-order-synch
  let order = 0;
  const arms = await parallel(
    DUAL_BUILD_ARMS.map((name) => () => {
      order += 1;
      return driveArm(item, dual, name, order).catch((err) => ({
        arm: name,
        order,
        model: name === 'baseline' ? dual.baseline : dual.candidate,
        key: `${item.slug}@${name}`,
        wt: `${input.repoRoot}.wt/${item.slug}@${name}`,
        branch: `build/${item.slug}@${name}`,
        wtBase: '',
        guardArmed: 'UNKNOWN',
        ctx: null,
        cost: null,
        acceptanceResults: [],
        gate: 'fail',
        lossReason: 'infra',
        failure: { kind: 'arm-throw', detail: String((err && err.stack) || err) },
      }));
    }),
  );
  return { item, inScope: true, arms };
}

// dualBuildArmSummary — the per-arm shape that rides the item's returned record
// (and, through it, the orchestrator's Step 6 summary and the eventual pick).
// Deliberately NOT the raw arm result: `ctx` holds the whole phase-1 context
// including the worker verdict, and shipping that back would put every arm's
// full acceptance prose into the orchestrator's context — the one cost this
// whole workflow exists to bound.
function dualBuildArmSummary(a) {
  return {
    arm: a.arm,
    model: a.model,
    start_order: a.order,
    worktree: a.wt,
    branch: a.branch,
    base_sha: a.wtBase || null,
    guard_armed: a.guardArmed,
    gate: a.gate,
    loss_reason: a.lossReason ?? null,
    acceptance_results: a.acceptanceResults ?? [],
    cost: dualBuildCost(a),
    ...(a.failure ? { failure: a.failure } : {}),
    ...(SIDELINE_NOTICES.get(a.key) ? { sidelined: SIDELINE_NOTICES.get(a.key) } : {}),
  };
}

// -----------------------------------------------------------------------------
// dualBuildGuarded — the #437 silent-loss guard, applied BY CONSTRUCTION.
// -----------------------------------------------------------------------------
// `parallel()` is not `Promise.all`: a REJECTED thunk is dropped to `null`
// rather than failing the batch, and buildLevel's consuming loop
// (`for (const r of results) { if (!r) continue; }`) then skips that slot in
// silence — leaving the item in NEITHER `parked` NOR `escalations`. That is
// temperloop#437 exactly (a real run hit `item.acceptance.map` on a string and
// the item vanished), and the single-arm fan-out was hardened against it with a
// per-item `.catch()`.
//
// temperloop#2080 round-1 review [HIGH]: that guard is a CONVENTION every
// fan-out site has to remember, and the dual-build fan-outs remembered it for
// the not-in-scope branch only — so an in-scope item whose drive threw was
// silently lost again. Wrapping the thunk here makes the guard structural
// instead: every dual-build fan-out builds its thunks through this, so a future
// edit that adds an un-caught `await` inside one cannot reintroduce the drop.
// The returned thunk is `async` deliberately — that converts a SYNCHRONOUS
// throw in `fn`'s body (not just a rejected promise) into a rejection this
// function itself catches, which a bare `fn().catch()` would let escape.
function dualBuildGuarded(fn, onError) {
  return async () => {
    try {
      return await fn();
    } catch (err) {
      return await onError(err);
    }
  };
}

// driveLevelDualBuild — the level driver, and the BARRIER itself. — see build-level.design-notes-4.md#driveleveldualbuild-the-level-driver-and-the-barrier-itself

// =============================================================================
// PHASE 4 — THE LEVEL PICK AND THE TWO OPERATOR LEVERS (temperloop#2083)
// =============================================================================
// The barrier above stops at "every in-scope item is judged and recorded". This
// is what happens next, and it is deliberately the ONLY place in this file that
// turns a comparison into a merge decision:
//
//   1. THE PRE-REGISTERED TALLY decides the level's winning arm from the item
//      dispositions alone — no per-run judgement, no tie-break invented after
//      seeing the numbers (tallyLevelPick below states the whole rule set).
//   2. THE CALIBRATION GATE decides whether that pick may route by itself. An
//      uncalibrated judge means the tally's per-item inputs are not yet known to
//      agree with a human, so the level STOPS and asks, with no default.
//   3. THE TWO OPERATOR LEVERS — a level-wide override and a per-item override —
//      ride the same `level-pick` verdict grammar, and a per-item override is
//      what makes the level's own pick `mixed`.
//   4. ROUTING hands the winning arm's phase-1 context to driveItemPr() — the
//      ordinary PR/CI/park path, unchanged — and only then archives and deletes
//      the losing arm's branch.
//
// Nothing here merges: the merge gate stays the orchestrator's (build.md Step 4),
// exactly as on the single-arm path.
// =============================================================================

// The level-pick verdict grammar, fixed here once. `claude/presentation-plane.md`
// carries the reader-facing row; build.md 3d-esc carries the handler prose.
const LEVEL_PICK_VERDICTS = ['confirm', 'override-level', 'override-item'];

// levelPickInput — normalize and VALIDATE `input.levelPick`, the continuation
// input that carries the operator's answer to a `level-pick` escalation.
// Returns null (no answer — a fresh level), a normalized verdict, or
// `{ invalid }`. Same posture as dualBuildInput(): a present-but-unusable
// answer REFUSES rather than degrading to "no answer", because silently
// discarding an operator's override and proceeding on the tally is
// indistinguishable, after the fact, from the operator having confirmed it.
function levelPickInput() {
  const lp = input.levelPick;
  if (lp == null) return null;
  if (typeof lp !== 'object' || Array.isArray(lp)) {
    return { invalid: 'levelPick must be an object { verdict, arm?, items? }' };
  }
  const verdict = typeof lp.verdict === 'string' ? lp.verdict.trim() : '';
  if (!LEVEL_PICK_VERDICTS.includes(verdict)) {
    return { invalid: `levelPick.verdict must be one of ${LEVEL_PICK_VERDICTS.join(' | ')} (got ${JSON.stringify(lp.verdict)})` };
  }
  if (verdict === 'override-level') {
    const arm = typeof lp.arm === 'string' ? lp.arm.trim() : '';
    if (!DUAL_BUILD_ARMS.includes(arm)) {
      return { invalid: `levelPick.arm must be ${DUAL_BUILD_ARMS.join(' or ')} for an override-level verdict (got ${JSON.stringify(lp.arm)})` };
    }
    return { verdict, arm, items: [], reason: typeof lp.reason === 'string' ? lp.reason.trim() : '' };
  }
  if (verdict === 'override-item') {
    const rows = Array.isArray(lp.items) ? lp.items : [];
    const items = [];
    for (const r of rows) {
      const slug = r && typeof r.slug === 'string' ? r.slug.trim() : '';
      const arm = r && typeof r.arm === 'string' ? r.arm.trim() : '';
      const reason = r && typeof r.reason === 'string' ? r.reason.trim() : '';
      if (!slug || !DUAL_BUILD_ARMS.includes(arm)) {
        return { invalid: `each levelPick.items[] entry needs { slug, arm ∈ ${DUAL_BUILD_ARMS.join('|')}, reason } (got ${JSON.stringify(r)})` };
      }
      items.push({ slug, arm, reason });
    }
    if (items.length === 0) {
      return { invalid: 'an override-item verdict needs at least one { slug, arm, reason } entry in levelPick.items' };
    }
    return { verdict, arm: '', items, reason: '' };
  }
  return { verdict, arm: '', items: [], reason: typeof lp.reason === 'string' ? lp.reason.trim() : '' };
}

// dualBuildArmCost — ONE arm's whole-job cost across the level, as the tally's
// tie-break reads it. "Whole-job" is deliberate: the comparison is between two
// ways of building the SAME level, so the tie-break is the level's total for
// that arm, never a per-item average that would let one cheap item outvote the
// rest. Tokens are the unit; wall-clock is the fallback ONLY when neither arm
// reported tokens at all, so a partly-instrumented level never silently
// compares tokens against milliseconds. `known` is false when the arm reported
// neither — which is what makes "the tie-break could not be evaluated" a state
// the caller names rather than a zero it mistakes for cheap.
function dualBuildArmCost(pickables, armName) {
  let tokens = 0;
  let wallClockMs = 0;
  let tokensSeen = false;
  let wallSeen = false;
  for (const p of pickables) {
    const a = p.arms.find((x) => x.arm === armName);
    const c = a && a.cost;
    if (!c) continue;
    if (typeof c.tokens_in === 'number' || typeof c.tokens_out === 'number') {
      tokensSeen = true;
      tokens += (c.tokens_in ?? 0) + (c.tokens_out ?? 0);
    }
    if (typeof c.wall_clock_ms === 'number') {
      wallSeen = true;
      wallClockMs += c.wall_clock_ms;
    }
  }
  return { tokens: tokensSeen ? tokens : null, wall_clock_ms: wallSeen ? wallClockMs : null, known: tokensSeen || wallSeen };
}

// -----------------------------------------------------------------------------
// tallyLevelPick — THE PRE-REGISTERED TALLY.
// -----------------------------------------------------------------------------
// Pre-registered means: every rule below is fixed BEFORE the level runs, and
// none of them reads anything but the item dispositions the barrier already
// produced. That is the whole point — a tie-break chosen after seeing which arm
// it would favour is not a measurement, and this function is the one place that
// property is checkable.
//
// PER ITEM, exactly one of three outcomes, in this order:
//   1. GATE FAIL = LOSS. An arm with no gate-passing branch loses the item
//      outright. If exactly one arm gated, that arm WINS the item (`gate`) — a
//      model that ships a green branch beat one that did not, and no judge is
//      needed to say so. If NEITHER gated, the item is UNRESOLVED
//      (`both-arms-failed`): there was nothing to compare.
//   2. A JUDGED TIE IS UNRESOLVED, counting for NEITHER arm. So is every
//      non-verdict (`one-arm-only`, `spike-arm`, `judge-unavailable`, …) — the
//      reason rides the item row, so an unresolved item is never silently
//      indistinguishable from a judged one.
//   3. Otherwise the judge's preferred arm wins the item (`judge`).
//
// LEVEL: the arm with more item wins. A TALLY TIE — including the 0–0 tie a
// wholly unresolved level produces — goes to the CHEAPER arm by whole-job cost
// (`tally-tie-cheaper`). When neither arm's cost is known, or the two are
// exactly equal, the tie goes to `baseline` (`tally-tie-incumbent`): the
// incumbent is what the level would have been built on with no harness at all,
// so "we learned nothing" resolves to changing nothing.
function tallyLevelPick(pickables) {
  const items = [];
  const tally = { baseline: 0, candidate: 0, unresolved: 0 };
  for (const p of pickables) {
    const byArm = (n) => p.arms.find((x) => x.arm === n);
    const passing = DUAL_BUILD_ARMS.filter((n) => (byArm(n) || {}).gate === 'pass');
    let winner = null;
    let reason;
    if (passing.length === 0) {
      reason = 'both-arms-failed';
    } else if (passing.length === 1) {
      winner = passing[0];
      reason = 'gate';
    } else if (p.judgeOutcome && p.judgeOutcome.judged && p.judgeOutcome.prefersArm) {
      winner = p.judgeOutcome.prefersArm;
      reason = 'judge';
    } else if (p.judgeOutcome && p.judgeOutcome.judged) {
      reason = 'judged-tie';
    } else {
      reason = `judge-${(p.judgeOutcome && p.judgeOutcome.reason) || 'unavailable'}`;
    }
    if (winner) tally[winner] += 1;
    else tally.unresolved += 1;
    items.push({ slug: p.item.slug, winner, reason });
  }
  const cost = {
    baseline: dualBuildArmCost(pickables, 'baseline'),
    candidate: dualBuildArmCost(pickables, 'candidate'),
  };
  let winner;
  let reason;
  if (tally.baseline > tally.candidate) {
    winner = 'baseline';
    reason = 'tally';
  } else if (tally.candidate > tally.baseline) {
    winner = 'candidate';
    reason = 'tally';
  } else {
    const cheaper = cheaperArm(cost);
    winner = cheaper ?? 'baseline';
    reason = cheaper ? 'tally-tie-cheaper' : 'tally-tie-incumbent';
  }
  return { winner, reason, tally, items, cost };
}

// cheaperArm — the tie-break's own comparison, split out so its "unknown and
// equal both yield null" rule is one readable statement rather than a nested
// ternary inside the tally. Tokens win over wall-clock when BOTH arms reported
// tokens; wall-clock is read only when neither did.
function cheaperArm(cost) {
  const b = cost.baseline;
  const c = cost.candidate;
  if (typeof b.tokens === 'number' && typeof c.tokens === 'number' && b.tokens !== c.tokens) {
    return b.tokens < c.tokens ? 'baseline' : 'candidate';
  }
  if (typeof b.wall_clock_ms === 'number' && typeof c.wall_clock_ms === 'number' && b.wall_clock_ms !== c.wall_clock_ms) {
    return b.wall_clock_ms < c.wall_clock_ms ? 'baseline' : 'candidate';
  }
  return null;
}

// -----------------------------------------------------------------------------
// readCalibrationStatus — the gate's one read (temperloop#2082's pinned file).
// -----------------------------------------------------------------------------
// FAILS CLOSED, and that direction is the whole point: an unreadable, absent or
// unparseable calibration file means we do not KNOW that this repo's pairwise
// judge agrees with a human, and "we do not know" must produce the same modal
// confirm an explicitly-uncalibrated judge does. Reading an unavailable seam as
// "calibrated" would let the one state the gate exists for — a judge nobody has
// ever checked — auto-route a level's merges.
async function readCalibrationStatus() {
  const ledgerBin = sq(`${input.repoRoot}/workflows/scripts/model-comparison/dual-build-ledger.sh`);
  const cmd = [
    `__led=${ledgerBin}`,
    'if [ ! -f "$__led" ]; then',
    `printf '{"outcome":"CALIBRATION_UNAVAILABLE","reason":"seam-absent"}\\n'`,
    'else',
    // Un-piped status read, the same shape judgeArms uses and for the same
    // reason: `$?` after a pipeline reports the LAST command's status, so a
    // piped read would structurally report 0 and a refusal would be recorded
    // as a verdict.
    '__c=$(bash "$__led" calibrate-status 2>/dev/null); __cr=$?',
    'if [ "$__cr" -eq 0 ] && [ -n "$__c" ]; then',
    '__cj=$(printf %s "$__c" | jq -c . 2>/dev/null)',
    'if [ -n "$__cj" ]; then',
    `printf '{"outcome":"CALIBRATION","calibration":%s}\\n' "$__cj"`,
    'else',
    `printf '{"outcome":"CALIBRATION_UNAVAILABLE","reason":"status-unparseable","rc":0}\\n'`,
    'fi',
    'else',
    `printf '{"outcome":"CALIBRATION_UNAVAILABLE","reason":"status-refused","rc":%s}\\n' "$__cr"`,
    'fi',
    'fi',
  ].join('\n');
  // The label carries a pseudo-slug (`:_level`) because this read is
  // LEVEL-scoped, not item-scoped — every other machinery label in this file is
  // `<kind>:<slug>`, and a label with no slug at all is the one shape the
  // transcript (and the offline harness's own label→queue routing) cannot place.
  const out = await runMachinery(cmd, { label: 'level-pick-calibration:_level', phase: enterStage(STAGE_GATE) });
  if (machineryDenied(out) || out.outcome !== 'CALIBRATION' || !out.calibration || typeof out.calibration !== 'object') {
    return {
      available: false,
      status: 'UNKNOWN',
      reason: (out && out.reason) || 'calibration-unreachable',
      n: null,
      agreement_pct: null,
      bar_pct: null,
      bar_n: null,
    };
  }
  const c = out.calibration;
  return {
    available: true,
    status: typeof c.status === 'string' ? c.status : 'UNKNOWN',
    reason: null,
    n: c.n ?? null,
    agreement_pct: c.agreement_pct ?? null,
    bar_pct: c.bar_pct ?? null,
    bar_n: c.bar_n ?? null,
  };
}

// calibrationBarMet — the bar is met ONLY on the literal `calibrated` status
// dual-build-ledger.sh writes, which is itself defined as n >= bar_n AND
// agreement_pct >= bar_pct (ADR 0041). Read as one field rather than
// re-deriving the two comparisons here: a second implementation of the bar is a
// second thing to drift.
function calibrationBarMet(cal) {
  return !!(cal && cal.available && cal.status === 'calibrated');
}

// -----------------------------------------------------------------------------
// resolvePickDecision — the two operator levers, applied to the tally.
// -----------------------------------------------------------------------------
// Returns { level, armFor(slug), overrideFor(slug), source }.
//   no answer / `confirm`  → every item takes the tally's winner; level = winner.
//   `override-level <arm>` → every item takes <arm>; level = <arm>; every row
//                            carries `override: { applied, scope: "level" }`.
//   `override-item …`      → the named items take their own arm, every other
//                            item takes the tally's winner, and the level's own
//                            pick becomes **`mixed`** — because it is: the level
//                            no longer shipped one arm's work, and recording the
//                            winner's name there would misreport what merged.
function resolvePickDecision(tally, lp) {
  if (!lp || lp.verdict === 'confirm') {
    return {
      level: tally.winner,
      source: lp ? 'confirm' : 'tally',
      armFor: () => tally.winner,
      overrideFor: () => ({ applied: false }),
    };
  }
  if (lp.verdict === 'override-level') {
    return {
      level: lp.arm,
      source: 'override-level',
      armFor: () => lp.arm,
      overrideFor: () => ({ applied: true, scope: 'level', reason: lp.reason || 'operator override-level' }),
    };
  }
  const bySlug = new Map(lp.items.map((r) => [r.slug, r]));
  return {
    level: 'mixed',
    source: 'override-item',
    armFor: (slug) => (bySlug.has(slug) ? bySlug.get(slug).arm : tally.winner),
    overrideFor: (slug) =>
      bySlug.has(slug)
        ? { applied: true, scope: 'item', reason: bySlug.get(slug).reason || 'operator override-item' }
        : { applied: false },
  };
}

// recordOverrideCalibrationPair — an override IS a human preference expressed
// against the same pair the judge saw, so it is recorded as a calibration pair
// (ADR 0041's `--source override`). It is recorded and EXCLUDED from the
// agreement statistic by that script, never smuggled into the blind corpus:
// an override-only corpus is a disagreement by construction and would measure
// 100% disagreement no matter how good the judge is.
async function recordOverrideCalibrationPair(slug, arm, reason) {
  const ledgerBin = sq(`${input.repoRoot}/workflows/scripts/model-comparison/dual-build-ledger.sh`);
  const cmd = [
    `__led=${ledgerBin}`,
    'if [ ! -f "$__led" ]; then',
    `printf '{"outcome":"CALIBRATION_PAIR_UNAVAILABLE","reason":"seam-absent"}\\n'`,
    `elif bash "$__led" calibrate-record --slug ${sq(slug)} --preference ${sq(arm)} --reason ${sq(reason)} --source override >/dev/null 2>&1; then`,
    `printf '{"outcome":"CALIBRATION_PAIR_RECORDED"}\\n'`,
    'else',
    `printf '{"outcome":"CALIBRATION_PAIR_REFUSED","reason":"calibrate-record refused the pair"}\\n'`,
    'fi',
  ].join('\n');
  const out = await runMachinery(cmd, { label: `level-pick-calibrate:${slug}`, slug, phase: enterStage(STAGE_GATE) });
  const ok = !machineryDenied(out) && out.outcome === 'CALIBRATION_PAIR_RECORDED';
  if (!ok) {
    log(`[${slug}] level-pick override: the calibration pair was NOT recorded (${(out && (out.reason || out.outcome)) || 'denied'}) — the override still stands; the judge's agreement record is short one pair`);
  }
  return ok;
}

// -----------------------------------------------------------------------------
// stampWinningPr — the `Model-comparison-arms:` disclosure trailer (ADR 0040).
// -----------------------------------------------------------------------------
// The trailer is written ALONGSIDE the existing `Model-provenance:` line, never
// in place of it. `tagging.sh stamp-arms` is the only authorized emitter of the
// grammar (`claude/presentation-plane.md` freezes it), so this composes nothing
// itself: it asks that script for the line, appends it, and then VERIFIES with
// `parse-arms`, the script's own owned inverse. A stamp that cannot be verified
// is reported as unstamped — and MERGE IS BLOCKED ON IT, because a dual-built PR
// that merges without the trailer publishes work from a model comparison the
// record no longer discloses.
async function stampWinningPr(slug, pr, dual, arm, reason) {
  const tagBin = sq(`${input.repoRoot}/workflows/scripts/model-comparison/tagging.sh`);
  // stamp-arms refuses a reason carrying a double-quote or a newline (the
  // grammar's own trailing `"$` anchor depends on exactly one quote pair), so
  // the reason is flattened HERE rather than letting the script refuse a line
  // this driver composed.
  const oneLine = String(reason).replace(/[\r\n]+/g, ' ').replace(/"/g, "'").slice(0, 200) || 'level pick';
  const repoFlag = input.ownerRepo ? ` --repo ${sq(input.ownerRepo)}` : '';
  const cmd = [
    `__tg=${tagBin}`,
    'if [ ! -f "$__tg" ]; then',
    `printf '{"outcome":"ARMS_STAMP_FAILED","reason":"seam-absent"}\\n'`,
    'else',
    `__line=$(bash "$__tg" stamp-arms --baseline ${sq(dual.baseline)} --candidate ${sq(dual.candidate)} --pick ${sq(arm)} --reason ${sq(oneLine)} 2>/dev/null); __sr=$?`,
    'if [ "$__sr" -ne 0 ] || [ -z "$__line" ]; then',
    `printf '{"outcome":"ARMS_STAMP_FAILED","reason":"stamp-arms refused the values","rc":%s}\\n' "$__sr"`,
    'else',
    `__body=$(gh pr view ${sq(String(pr))}${repoFlag} --json body -q .body 2>/dev/null); __br=$?`,
    'if [ "$__br" -ne 0 ]; then',
    `printf '{"outcome":"ARMS_STAMP_FAILED","reason":"pr-body-unreadable","rc":%s}\\n' "$__br"`,
    'else',
    // A `case` glob, not a piped `grep -q`: the body is already in a variable,
    // and an idempotent re-stamp must never depend on a pipeline's exit status.
    'case "$__body" in',
    '*Model-comparison-arms:*)',
    `printf '{"outcome":"ARMS_STAMPED","already":true}\\n'`,
    ';;',
    '*)',
    '__bf=$(mktemp) || __bf=""',
    'if [ -z "$__bf" ]; then',
    `printf '{"outcome":"ARMS_STAMP_FAILED","reason":"scratch-file-failed"}\\n'`,
    'else',
    `printf '%s\\n\\n%s\\n' "$__body" "$__line" > "$__bf"`,
    `if gh pr edit ${sq(String(pr))}${repoFlag} --body-file "$__bf" >/dev/null 2>&1; then`,
    '__chk=$(bash "$__tg" parse-arms --pr-body "$__bf" 2>/dev/null); __cr=$?',
    'if [ "$__cr" -eq 0 ] && [ -n "$__chk" ]; then',
    `printf '{"outcome":"ARMS_STAMPED","already":false}\\n'`,
    'else',
    `printf '{"outcome":"ARMS_STAMP_FAILED","reason":"parse-arms could not verify the appended trailer","rc":%s}\\n' "$__cr"`,
    'fi',
    'else',
    `printf '{"outcome":"ARMS_STAMP_FAILED","reason":"gh pr edit refused the body update"}\\n'`,
    'fi',
    'rm -f "$__bf"',
    'fi',
    ';;',
    'esac',
    'fi',
    'fi',
    'fi',
  ].join('\n');
  const out = await runMachinery(cmd, { label: `stamp-arms:${slug}`, slug, phase: enterStage(STAGE_PR) });
  if (machineryDenied(out) || out.outcome !== 'ARMS_STAMPED') {
    return { stamped: false, reason: (out && out.reason) || 'stamp-denied' };
  }
  return { stamped: true, already: !!out.already };
}

// -----------------------------------------------------------------------------
// archiveLosingArm — archive FIRST, verify, and only then delete.
// -----------------------------------------------------------------------------
// The ordering is the contract, not an implementation detail: `archive-check`
// runs `git am --check` against the saved patch, so a branch is deleted ONLY
// once its work has been proven recoverable from the archive. Every failure
// arm KEEPS the branch and the worktree — a losing arm whose patch did not
// archive is not garbage, it is the only copy.
async function archiveLosingArm(slug, loser) {
  const ledgerBin = sq(`${input.repoRoot}/workflows/scripts/model-comparison/dual-build-ledger.sh`);
  const repoRoot = sq(input.repoRoot);
  const wt = sq(loser.wt);
  const base = loser.wtBase || '';
  const cmd = [
    `__led=${ledgerBin}`,
    'if [ ! -f "$__led" ]; then',
    `printf '{"outcome":"LOSER_KEPT","reason":"ledger-absent"}\\n'`,
    `elif [ ! -d ${wt} ]; then`,
    `printf '{"outcome":"LOSER_KEPT","reason":"worktree-absent"}\\n'`,
    'else',
    base
      ? `__p=$(git -C ${wt} format-patch ${sq(base)}..HEAD --stdout 2>/dev/null); __pr=$?`
      : `__p=""; __pr=1`,
    'if [ "$__pr" -ne 0 ] || [ -z "$__p" ]; then',
    `printf '{"outcome":"LOSER_KEPT","reason":"no-patch-to-archive"}\\n'`,
    `elif ! printf '%s\\n' "$__p" | bash "$__led" archive ${sq(slug)} ${sq(loser.arm)} --from - >/dev/null 2>&1; then`,
    `printf '{"outcome":"LOSER_KEPT","reason":"archive-refused"}\\n'`,
    `elif ! bash "$__led" archive-check ${sq(slug)} ${sq(loser.arm)} --repo ${repoRoot} >/dev/null 2>&1; then`,
    `printf '{"outcome":"LOSER_KEPT","reason":"archive-check-failed"}\\n'`,
    'else',
    // archive-check PASSED — the patch applies, so the branch is now redundant.
    // No `--force` on either removal: git's own refusal is the last belt, the
    // same posture the kernel's worktree-disposal rule takes (temperloop#658).
    `git -C ${repoRoot} worktree remove ${wt} >/dev/null 2>&1; __wr=$?`,
    `git -C ${repoRoot} branch -D ${sq(loser.branch)} >/dev/null 2>&1; __dr=$?`,
    `printf '{"outcome":"LOSER_ARCHIVED","worktree_removed":%s,"branch_deleted":%s}\\n' "$([ "$__wr" -eq 0 ] && echo true || echo false)" "$([ "$__dr" -eq 0 ] && echo true || echo false)"`,
    'fi',
    'fi',
  ].join('\n');
  const out = await runMachinery(cmd, { label: `archive-loser:${slug}`, slug, phase: enterStage(STAGE_PR) });
  if (machineryDenied(out) || out.outcome !== 'LOSER_ARCHIVED') {
    const reason = (out && out.reason) || 'archive-denied';
    log(`[${slug}] level-pick: the losing ${loser.arm} arm was KEPT, not deleted (${reason}) — ${loser.branch} still holds its only copy`);
    return { archived: false, deleted: false, reason };
  }
  return { archived: true, deleted: !!out.branch_deleted, worktree_removed: !!out.worktree_removed, reason: null };
}

// appendPickRow — the ledger's record OF THE PICK, appended after the PR phase.
// The barrier's own rows are written before any pick exists and say `pick: null`
// by construction; this is the row that closes them out, carrying the chosen
// arm, the operator override (if any) and the POST-PICK CI outcome — which is
// the only place a CI failure that happened after the comparison was over can
// be recorded against the arm that caused it.
async function appendPickRow(item, dual, winner, judgeOutcome, pickFields) {
  const row = dualBuildRow(item, dual, winner, judgeOutcome, pickFields);
  const r = await appendDualBuildRows(item, dual, [{ row, wt: winner.wt, arm: winner.arm }], 'pick');
  return r;
}


// reKeyToItemSlug — a routed record comes back keyed by the ARM slug
// (`<slug>@<arm>`, which is what phase 1 and driveItemPr see), but the plan
// note, the board and the orchestrator's writeback all key on the ITEM's own
// slug. Re-key in ONE place rather than at each of the four return sites: a
// record that reaches the orchestrator under an arm slug matches no plan item,
// so its sentinel write silently lands nowhere.
function reKeyToItemSlug(record, slug) {
  if (!record) return record;
  record.slug = slug;
  if (record.parked) record.parked.slug = slug;
  if (record.escalation) record.escalation.slug = slug;
  return record;
}

// -----------------------------------------------------------------------------
// routePickedItem — ONE in-scope item, from the pick to its PR.
// -----------------------------------------------------------------------------
// Four things happen here and their ORDER is the contract:
//   1. a per-item override writes its calibration pair (before anything merges,
//      so the disagreement is on the record even if the PR later fails);
//   2. a WINNING-ARM-LOST item is re-driven ONCE on the winning arm's own model,
//      and parks `incomplete` if it still has no gate-passing branch — it is
//      never quietly shipped from the losing arm, which would silently reverse
//      the level's own pick for that item;
//   3. the winning arm's phase-1 context goes through driveItemPr — the ordinary
//      3f/3g/3h path, unchanged — and the PR is then STAMPED, with merge blocked
//      until it is;
//   4. only after the winner has a PR is the losing arm archived and deleted,
//      and only if `archive-check` passes.
async function routePickedItem(p, dual, decision, tally) {
  const slug = p.item.slug;
  const wantArm = decision.armFor(slug);
  const override = decision.overrideFor(slug);
  const loserArm = wantArm === 'baseline' ? 'candidate' : 'baseline';
  const pickReason = override.applied
    ? `${decision.source}: ${override.reason}`
    : `${tally.reason} ${tally.tally.baseline}-${tally.tally.candidate} (${tally.tally.unresolved} unresolved)`;

  // 1. A PER-ITEM override is a human preference over the same pair the judge
  //    saw, so it is recorded as an override-sourced calibration pair (ADR
  //    0041, `--source override`: recorded, and excluded from the blind
  //    agreement statistic). A LEVEL-wide override deliberately writes none —
  //    it is one decision about the level, not a per-pair preference, and
  //    fanning it out into N pairs would manufacture N disagreements from one
  //    click and corrupt the very statistic the pairs feed.
  if (override.applied && override.scope === 'item') {
    await recordOverrideCalibrationPair(slug, wantArm, override.reason || pickReason);
  }

  const basePick = {
    level: decision.level,
    arm: wantArm,
    reason: pickReason,
    source: decision.source,
    override,
    tally: tally.tally,
    item_reason: (tally.items.find((i) => i.slug === slug) || {}).reason ?? null,
  };
  const dualRecord = { ...p.dualBuildRecord, barrier: 'cleared', awaiting: null, pick: basePick };

  let winner = p.arms.find((a) => a.arm === wantArm);

  // A spike arm produced a verdict note, not a branch — there is nothing to
  // push. It already completed (driveArm's spike branch), so this is a normal
  // disposition, not a loss, and no PR, stamp or archive applies.
  // UNREACHABLE BY CONSTRUCTION, kept deliberately as a fail-safe: `spike`
  // derives from `item.kind`, which is identical across both arms of one item,
  // so a pair can never be half-spike, and `driveLevelDualBuild` excludes any
  // pair with `run.arms.some(a => a.spike)` from `pickables` before a pick is
  // ever attempted. If a future change makes a spike pair pickable, this branch
  // parks it cleanly instead of letting the winning-arm-lost path below re-drive
  // a spike (which has no `ctx`) as though its missing branch were a gate loss.
  if (winner && winner.spike) {
    const rec = park(slug, null, null, winner.acceptanceResults ?? []);
    rec.parked.dual_build = { ...dualRecord, pick: { ...basePick, outcome: 'spike-no-pr' } };
    return { record: rec, pick: { ...basePick, outcome: 'spike-no-pr', pr: null, stamped: null } };
  }

  // 2. WINNING-ARM-LOST — re-drive ONCE, on the winning arm's OWN model.
  let reDriven = false;
  if (!winner || winner.gate !== 'pass' || !winner.ctx) {
    reDriven = true;
    log(
      `[${slug}] level-pick: the winning ${wantArm} arm has no gate-passing branch ` +
        `(${(winner && winner.lossReason) || 'no arm result'}) — re-driving it ONCE on its own model (${wantArm === 'baseline' ? dual.baseline : dual.candidate})`,
    );
    const redo = await driveArm(p.item, dual, wantArm, (winner && winner.order) || 1).catch((err) => ({
      arm: wantArm, gate: 'fail', lossReason: 'infra',
      failure: { kind: 'arm-throw', detail: String((err && err.stack) || err) },
    }));
    if (redo && redo.gate === 'pass' && redo.ctx) {
      winner = redo;
    } else {
      // Still nothing. PARK INCOMPLETE — never fall back to the losing arm.
      log(`[${slug}] level-pick: the winning ${wantArm} arm failed its re-drive too — parking INCOMPLETE (the losing arm is NOT shipped in its place)`);
      const rec = park(slug, null, null, []);
      rec.parked.incomplete = true;
      rec.parked.dual_build = {
        ...dualRecord,
        pick: { ...basePick, outcome: 'incomplete', re_driven: true, re_drive_loss_reason: (redo && redo.lossReason) || 'infra' },
      };
      return { record: rec, pick: { ...basePick, outcome: 'incomplete', re_driven: true, pr: null, stamped: null } };
    }
  }

  // 3. The ordinary PR/CI/park path, on the winning arm's own context.
  let prRecord;
  try {
    prRecord = await driveItemPr(winner.ctx);
  } catch (err) {
    prRecord = escalate(winner.ctx.item.slug, 'worker-error', {
      error: String((err && err.stack) || err),
      phase: 'dual-build level-pick PR phase',
    });
  }
  reKeyToItemSlug(prRecord, slug);
  const pr = prRecord._kind === 'parked' ? prRecord.parked.pr ?? null : null;
  const ciFailed = prRecord._kind === 'escalation' && /^ci-/.test(String(prRecord.escalation.kind));

  let stamp = { stamped: false, reason: 'no-pr-opened' };
  if (pr) stamp = await stampWinningPr(slug, pr, dual, wantArm, pickReason);

  // 4. The losing arm — archived, verified, and only then deleted. Gated on the
  //    winner actually having a PR: until the winner's work is on origin, the
  //    loser's branch is not redundant, it is the level's second copy.
  let loserOutcome = null;
  const loser = p.arms.find((a) => a.arm === loserArm);
  if (pr && loser && !loser.spike) {
    loserOutcome = await archiveLosingArm(slug, loser);
  } else if (loser && !loser.spike) {
    loserOutcome = { archived: false, deleted: false, reason: 'winner-has-no-pr' };
    log(`[${slug}] level-pick: the losing ${loserArm} arm is KEPT — the winning arm opened no PR, so nothing here is redundant yet`);
  }

  // POST-PICK CI, recorded against the arm that shipped. The barrier's own rows
  // could not carry this (they are written before any PR exists), which is
  // exactly why the pick row is appended here rather than there.
  const postPickCi = prRecord._kind === 'parked'
    ? (prRecord.parked.no_ci ? 'no-ci' : 'green')
    : (ciFailed ? 'failed' : 'unknown');
  const pickFields = {
    pick: { arm: wantArm, reason: pickReason, level: decision.level },
    override,
    post_pick_ci: postPickCi,
    pr: pr ?? null,
    arms_trailer_stamped: !!stamp.stamped,
    re_driven: reDriven,
    // A CI failure AFTER the pick is a gate loss for the arm that shipped —
    // named on the arm rather than left as a level-wide footnote, so the report
    // can read "the candidate arm's picks went red in CI twice" from rows alone.
    ...(ciFailed ? { loss_reason: 'gate' } : {}),
  };
  const rowsOut = await appendPickRow(p.item, dual, winner, p.judgeOutcome, pickFields);

  const pickOut = {
    ...basePick,
    outcome: prRecord._kind === 'parked' ? 'routed' : 'escalated',
    pr,
    stamped: stamp.stamped,
    stamp_reason: stamp.stamped ? null : stamp.reason,
    post_pick_ci: postPickCi,
    re_driven: reDriven,
    loser: loser ? { arm: loserArm, branch: loser.branch, ...(loserOutcome ?? { archived: false, deleted: false, reason: 'no-losing-arm-build' }) } : null,
    pick_row_appended: rowsOut.appended,
  };

  if (prRecord._kind === 'parked') {
    prRecord.parked.dual_build = { ...dualRecord, pick: pickOut };
    // MERGE IS BLOCKED UNTIL THE TRAILER IS ON THE PR. Not advisory: a
    // dual-built PR that merges unstamped ships work chosen by a model
    // comparison the merged record no longer discloses (ADR 0040).
    if (!stamp.stamped) {
      prRecord.parked.merge_blocked = 'arms-trailer-unstamped';
      log(
        `[${slug}] level-pick: PR #${pr ?? '?'} is NOT stamped with Model-comparison-arms (${stamp.reason}) — ` +
          'MERGE IS BLOCKED for this item until `tagging.sh stamp-arms` lands its trailer on the PR body',
      );
    }
  } else {
    prRecord.escalation.payload = { ...(prRecord.escalation.payload ?? {}), dual_build: { ...dualRecord, pick: pickOut } };
  }
  return { record: prRecord, pick: pickOut };
}

// -----------------------------------------------------------------------------
// driveLevelPick — phase 4's entry point: tally, gate, levers, route.
// -----------------------------------------------------------------------------
async function driveLevelPick(pickables, dual) {
  const tally = tallyLevelPick(pickables);
  log(
    `dual-build LEVEL PICK — pre-registered tally: baseline=${tally.tally.baseline} ` +
      `candidate=${tally.tally.candidate} unresolved=${tally.tally.unresolved} → winner=${tally.winner} (${tally.reason}); ` +
      `whole-job cost baseline=${JSON.stringify(tally.cost.baseline)} candidate=${JSON.stringify(tally.cost.candidate)}`,
  );

  const lp = levelPickInput();
  // An override naming a slug this level never built is a TYPO, not a no-op.
  // levelPickInput() can only check the answer's SHAPE; membership needs the
  // level, so it is checked here — otherwise a mistyped slug silently leaves
  // every item on the tally's winner and the operator's override is lost with
  // no signal, which is the one outcome the refusal-over-degradation posture
  // above exists to prevent.
  if (lp && !lp.invalid && lp.verdict === 'override-item') {
    const known = new Set(pickables.map((p) => p.item.slug));
    const unknown = lp.items.map((r) => r.slug).filter((slug) => !known.has(slug));
    if (unknown.length > 0) {
      lp.invalid =
        `levelPick.items names slug(s) this level has no in-scope build for: ${unknown.join(', ')} ` +
        `(in scope: ${[...known].join(', ') || 'none'})`;
    }
  }
  if (lp && lp.invalid) {
    log(`dual-build level-pick INPUT INVALID — refusing to route: ${lp.invalid}`);
    return {
      records: pickables.map((p) =>
        escalate(p.item.slug, 'level-pick-input-invalid', {
          reason: lp.invalid,
          received: input.levelPick,
          remedy: `pass levelPick as { verdict: ${LEVEL_PICK_VERDICTS.join(' | ')}, arm?, items? } — see claude/commands/build.md 3d-esc's level-pick handler`,
        }),
      ),
      // `held: true` is NOT decoration — it is the discriminant every summary
      // shape this function returns must carry. A refusal IS a held state:
      // nothing routed, no PR opened, the level still owes a corrected
      // `levelPick`. Omitting it let the caller's `!pick.held` read
      // `!undefined === true` and report the level `cleared` (temperloop#2083
      // round-3 review), which is the permissive default in the one place the
      // design demands the conservative one.
      summary: { level: null, confirm_required: true, confirmed: false, refused: lp.invalid, held: true, tally: tally.tally, winner: tally.winner },
    };
  }

  const cal = await readCalibrationStatus();
  const calibrated = calibrationBarMet(cal);
  log(
    `dual-build level-pick calibration gate: status=${cal.status}` +
      (cal.available ? ` n=${cal.n} agreement=${cal.agreement_pct}% bar=${cal.bar_pct}%/${cal.bar_n}` : ` (UNAVAILABLE: ${cal.reason})`) +
      ` → an explicit confirm is ${calibrated ? 'OPTIONAL (the override lever)' : 'REQUIRED before any PR opens'}`,
  );

  // THE GATE. While the judge is not calibrated — or the bar is unmet, or the
  // status could not be read at all — the pick does not route itself. There is
  // NO DEFAULT here by construction: the whole reason to ask is that the
  // per-item inputs to this tally are not yet known to agree with a human, so
  // "proceed on silence" would be the harness asserting exactly the thing it
  // cannot yet support (kernel § Merge autonomy & consent: a no-safe-default
  // decision never auto-proceeds).
  if (!calibrated && !lp) {
    const shared = {
      winner: tally.winner,
      pick_reason: tally.reason,
      tally: tally.tally,
      items: tally.items,
      cost: tally.cost,
      calibration: cal,
      confirm_required: true,
      default: null,
      no_default_reason:
        'the pairwise judge is not calibrated against a human on this repo, so the tally that produced this pick is not yet known to be trustworthy — a timeout is not consent',
      verdict_grammar: 'confirm | override-level <arm> | override-item <slug> <arm> "<reason>"',
      in_scope: pickables.map((p) => p.item.slug),
      remedy: 'answer the level-pick question, then re-invoke build-level.mjs for this level with input.levelPick carrying the verdict',
    };
    log(`dual-build LEVEL PICK HELD — no PR opens for any in-scope item until the operator confirms (${pickables.length} item(s))`);
    return {
      records: pickables.map((p) => {
        const rec = escalate(p.item.slug, 'level-pick', {
          ...shared,
          item: {
            slug: p.item.slug,
            proposed_arm: tally.winner,
            item_reason: (tally.items.find((i) => i.slug === p.item.slug) || {}).reason ?? null,
          },
          // The SAME record the item would have parked with. Carried verbatim
          // so a held item is not a thinner surface than a routed one: the
          // arms, their gates, their costs and the judge disposition are all
          // the operator needs to answer the question this escalation asks.
          dual_build: p.dualBuildRecord,
          worktrees_intact: p.arms.map((a) => ({ arm: a.arm, worktree: a.wt, branch: a.branch })),
        });
        return rec;
      }),
      summary: {
        level: null,
        winner: tally.winner,
        reason: tally.reason,
        tally: tally.tally,
        items: tally.items,
        cost: tally.cost,
        calibration: cal,
        confirm_required: true,
        confirmed: false,
        held: true,
      },
    };
  }

  const decision = resolvePickDecision(tally, lp);
  log(
    `dual-build LEVEL PICK ${decision.source === 'tally' ? 'AUTO (calibrated judge — the confirm is today an optional override)' : `by operator ${decision.source}`}` +
      ` → level=${decision.level}` +
      (decision.level === 'mixed' ? ' (a per-item override means this level shipped BOTH arms — "mixed" is the honest level value, not a winner name)' : ''),
  );

  const routed = await parallel(
    pickables.map((p) =>
      dualBuildGuarded(
        () => routePickedItem(p, dual, decision, tally),
        (err) => ({
          record: escalate(p.item.slug, 'worker-error', {
            error: String((err && err.stack) || err),
            phase: 'dual-build level-pick routing phase',
          }),
          pick: { level: decision.level, arm: decision.armFor(p.item.slug), outcome: 'threw' },
        }),
      ),
    ),
  );

  return {
    records: routed.filter(Boolean).map((r) => r.record),
    summary: {
      level: decision.level,
      winner: tally.winner,
      reason: tally.reason,
      source: decision.source,
      tally: tally.tally,
      items: tally.items,
      cost: tally.cost,
      calibration: cal,
      confirm_required: !calibrated,
      confirmed: !!lp,
      held: false,
      picks: routed.filter(Boolean).map((r) => ({ slug: r.record.slug, ...r.pick })),
      merge_blocked: routed.filter(Boolean).filter((r) => r.pick && r.pick.pr && !r.pick.stamped).map((r) => r.record.slug),
    },
  };
}

async function driveLevelDualBuild(activeItems, dual) {
  const boardWrites = [];
  log(
    `dual-build: tier=${dual.tier} baseline=${dual.baseline} candidate=${dual.candidate} ` +
      `in-scope=${activeItems.filter((it) => dual.inScope.has(it.slug)).length}/${activeItems.length} ` +
      '— building in-scope items under two arms; NO PR opens for an in-scope item until the level barrier clears',
  );

  // --- Phase 1 + the barrier ----------------------------------------------
  const runs = await parallel(
    activeItems.map((item) =>
      dualBuildGuarded(
        () => {
          if (!dual.inScope.has(item.slug)) {
            // Not in scope: the unchanged single-arm drive, including its PR.
            return driveItem(item)
              .catch((err) => escalate(item.slug, 'worker-error', { error: String((err && err.stack) || err) }))
              .then((r) => preserveOnEscalation(item, r))
              .then((r) => stampSideline(item, r))
              .then((record) => ({ item, inScope: false, record }));
          }
          return driveInScopeItem(item, dual, boardWrites);
        },
        // The IN-SCOPE throw (the not-in-scope branch carries its own catch — see build-level.design-notes-4.md#the-in-scope-throw-the-not-in-scope-branch-carries-its-own-c
        (err) => ({
          item,
          inScope: false,
          escaped: true,
          record: escalate(item.slug, 'worker-error', {
            error: String((err && err.stack) || err),
            phase: 'dual-build build phase',
          }),
        }),
      ),
    ),
  );
  log(
    `dual-build: LEVEL BARRIER reached — every in-scope arm has a gate result ` +
      `(${runs.filter((r) => r.inScope).reduce((n, r) => n + r.arms.filter((a) => a.gate === 'pass').length, 0)} passing arm(s) ` +
      `of ${runs.filter((r) => r.inScope).length * DUAL_BUILD_ARMS.length}). Judging before any PR opens.`,
  );

  // --- Phase 3: judge, record, dispose -------------------------------------
  // `pickables` is phase 4's input, collected HERE rather than re-derived from
  // the disposed records: an arm's phase-1 `ctx` is the one thing the level
  // pick needs and the one thing a returned record deliberately never carries
  // (dualBuildArmSummary drops it, so the orchestrator never ingests a worker
  // verdict). Pushing from inside the fan-out is safe — the runtime is
  // single-threaded, so a push between awaits cannot interleave.
  const pickables = [];
  const ledger = { appended: 0, rejected: 0, unavailable: 0 };
  const disposed = await parallel(
    runs.map((run) =>
      dualBuildGuarded(async () => {
      if (run.escaped) {
        // Phase 1's guard already converted this item's throw into an — see build-level.design-notes-5.md#phase-1-s-guard-already-converted-this-item-s-throw-int
        return run.record;
      }
      if (!run.inScope) {
        // One row for the item that was built ONCE, so the level's ledger — see build-level.design-notes-4.md#one-row-for-the-item-that-was-built-once-so-the-level-s-ledg
        const single = {
          arm: 'baseline',
          order: 1,
          model: run.item.model ?? dual.baseline,
          wt: `${input.repoRoot}.wt/${run.item.slug}`,
          wtBase: '',
          guardArmed: 'UNKNOWN',
          gate: run.record && run.record._kind === 'parked' ? 'pass' : 'fail',
          lossReason: run.record && run.record._kind === 'parked' ? null : 'infra',
          cost: null,
        };
        const r = await appendDualBuildRows(run.item, dual, [{
          row: dualBuildRow(run.item, dual, single, null, {
            in_scope: false,
            not_in_scope_reason: 'this item is not in the dual-build tier for this run — built once, on its own model',
          }),
          wt: single.wt,
          arm: 'not-in-scope',
        }]);
        ledger.appended += r.appended;
        ledger.rejected += r.rejected;
        if (r.unavailable) ledger.unavailable += 1;
        return run.record;
      }

      const judgeOutcome = await judgeArms(run.item, dual, run.arms);
      if (judgeOutcome.judged) {
        log(
          `[${run.item.slug}] dual-build judge: preference=${judgeOutcome.judge.preference} ` +
            `margin=${judgeOutcome.judge.margin} order_agreement=${judgeOutcome.judge.order_agreement}` +
            (judgeOutcome.prefersArm ? ` (prefers the ${judgeOutcome.prefersArm} arm)` : ' (tie — counts for neither arm)'),
        );
      } else {
        log(`[${run.item.slug}] dual-build judge: NO verdict (${judgeOutcome.reason}) — ${judgeOutcome.detail}`);
      }
      // A judged preference is a per-ITEM loss for the arm it did not prefer. — see build-level.design-notes-5.md#a-judged-preference-is-a-per-item-loss-for-the-arm-it-d
      const armRows = run.arms.map((a) => {
        const lossReason = a.lossReason
          ?? (judgeOutcome.judged && judgeOutcome.prefersArm && judgeOutcome.prefersArm !== a.arm ? 'judge' : null);
        const withLoss = { ...a, lossReason };
        return { row: dualBuildRow(run.item, dual, withLoss, judgeOutcome, {}), wt: a.wt, arm: a.arm };
      });
      const r = await appendDualBuildRows(run.item, dual, armRows);
      ledger.appended += r.appended;
      ledger.rejected += r.rejected;
      if (r.unavailable) ledger.unavailable += 1;

      const armSummaries = run.arms.map(dualBuildArmSummary);
      const passing = run.arms.filter((a) => a.gate === 'pass');
      const dualBuildRecord = {
        tier: dual.tier,
        baseline: dual.baseline,
        candidate: dual.candidate,
        arms: armSummaries,
        judge: judgeOutcome.judged ? judgeOutcome.judge : null,
        judge_unavailable_reason: judgeOutcome.judged ? null : judgeOutcome.reason,
        prefers_arm: judgeOutcome.prefersArm ?? null,
        barrier: 'held',
        awaiting: 'level-pick',
        rows_appended: r.appended,
        rows_rejected: r.rejected,
      };
      if (passing.length === 0) {
        // Nothing to pick from for this item. This ESCALATES rather than parks: — see build-level.design-notes-5.md#nothing-to-pick-from-for-this-item-this-escalates-rathe
        return escalate(run.item.slug, 'dual-build-arms-failed', {
          reason:
            `both arms of ${run.item.slug} failed to reach a gate-passing branch ` +
            `(${run.arms.map((a) => `${a.arm}: ${a.lossReason}`).join(', ')}) — there is nothing for the level pick to choose between`,
          dual_build: dualBuildRecord,
        });
      }
      // PARKED WITH NO PR. This is the barrier's visible form on the return
      // object: the item is disposed of (so the zero-disposition guard is
      // satisfied — it was, and the guard is right that a level disposing of
      // NOTHING is a contradiction), it carries every arm's result, and it
      // carries `pr: null` because opening one is precisely what the barrier
      // forbids until the pick. `acceptance_results` is EMPTY on purpose: the
      // arms' results are per-arm and live in `dual_build.arms[]`, and hoisting
      // one arm's to the top level would read as a pick nobody made.
      // A SPIKE pair is not pickable (temperloop#2083). Its arms produce a
      // read-only verdict note rather than a branch, so there is no PR to route
      // and no diff a pick could be about — the item is already finished. It
      // would otherwise hold a whole level for a confirm over a choice that
      // changes nothing, and count as an `unresolved` item in a tally it
      // contributed no evidence to.
      const spikePair = run.arms.some((a) => a.spike);
      if (spikePair) {
        dualBuildRecord.barrier = 'cleared';
        dualBuildRecord.awaiting = null;
        dualBuildRecord.pick = {
          level: null,
          outcome: 'no-pick-needed',
          reason: 'a spike arm produces a verdict note, not a branch — there is nothing for a level pick to route to a PR',
        };
      }
      const record = park(run.item.slug, null, null, []);
      record.parked.dual_build = dualBuildRecord;
      record.parked.awaiting_pick = !spikePair;
      // Hand this item to phase 4. The parked record above is the FALLBACK
      // disposition — it stands only if the pick never routes this item (the
      // calibration gate holds the level, or the pick refuses).
      if (!spikePair) pickables.push({ item: run.item, arms: run.arms, judgeOutcome, dualBuildRecord });
      return record;
      },
      // A throw in the JUDGE/LEDGER/RECORD phase is the same silent-loss risk — see build-level.design-notes-5.md#a-throw-in-the-judge-ledger-record-phase-is-the-same-si
      (err) => escalate(run.item.slug, 'worker-error', {
        error: String((err && err.stack) || err),
        phase: 'dual-build judge/record phase',
      })),
    ),
  );

  // --- Phase 4: THE LEVEL PICK (temperloop#2083) ---------------------------
  // Runs only when the barrier produced something to choose between. Every
  // item it routes REPLACES that item's phase-3 parked record; an item phase 4
  // never reaches (both arms failed → escalated above) keeps the record it
  // already has.
  let pick = null;
  let results = disposed;
  if (pickables.length > 0) {
    const picked = await driveLevelPick(pickables, dual);
    pick = picked.summary;
    const bySlug = new Map(picked.records.filter(Boolean).map((r) => [r.slug, r]));
    results = disposed.map((r) => (r && bySlug.has(r.slug) ? bySlug.get(r.slug) : r));
  }

  return {
    results,
    summary: {
      tier: dual.tier,
      baseline: dual.baseline,
      candidate: dual.candidate,
      in_scope: activeItems.filter((it) => dual.inScope.has(it.slug)).map((it) => it.slug),
      not_in_scope: activeItems.filter((it) => !dual.inScope.has(it.slug)).map((it) => it.slug),
      // The barrier is CLEARED once phase 4 has routed the level's pick; it
      // stays `held` when the calibration gate held the level for a confirm, or
      // when there was nothing to pick between at all.
      // Name the SAFE branch positively (`=== false`), never negate an optional
      // field. `driveLevelPick` returns several summary shapes and a future one
      // that again omits `held` must fall to the CONSERVATIVE `'held'` reading,
      // not slip through on `!undefined`. Same falsy-coercion class as the
      // empty-`inScope` trap the dual-build validator already closed.
      barrier: pick && pick.held === false ? 'cleared' : 'held',
      awaiting: pick && pick.held === false ? null : 'level-pick',
      pick,
      rows_appended: ledger.appended,
      rows_rejected: ledger.rejected,
      ledger_unavailable_items: ledger.unavailable,
      board_writes: boardWrites,
    },
  };
}

// =============================================================================
// THE TWO PHASES OF driveItem (temperloop#2080, epic #2065 "dual-build")
// =============================================================================
// driveItem used to be ONE function that interleaved build → local gate — see build-level.design-notes-5.md#driveitem-used-to-be-one-function-that-interleaved-build-loc
// =============================================================================
async function driveItem(item) {
  const built = await driveItemBuild(item, null);
  if (built.result) return built.result;
  return await driveItemPr(built.ctx);
}

// driveItemBuild — the phase-1 wrapper. `arm` is null on the single-arm path
// (every /build, /fix and /sweep invocation that passes no `dualBuild` input)
// and a `{ name, sibling, slug, order }` descriptor on a dual-build arm, where
// `item` has ALREADY been arm-shaped by armItem() below (slug → `<slug>@<arm>`,
// branch → `build/<slug>@<arm>`, model → that arm's own model). Returns exactly
// one of `{ result }` (terminal) or `{ ctx }` (ready for phase 2).
async function driveItemBuild(item, arm) {
  const box = {};
  const terminal = await driveItemBuildPhase(item, arm ?? null, box);
  return terminal ? { result: terminal } : { ctx: box.ctx };
}

async function driveItemBuildPhase(item, arm, box) {
  const { repoRoot, board } = input;
  const worktreePath = `${repoRoot}.wt/${item.slug}`;

  // Continuation detection (escalation-resume loop, 3d-esc) — see build-level.design-notes-4.md#continuation-detection-escalation-resume-loop-3d-esc
  const isContinuation =
    Array.isArray(input.onlySlugs) && input.onlySlugs.includes(item.slug);
  const verdictSection = isContinuation
    ? input.verdicts?.[item.slug]?.verdict_section
    : undefined;

  // PRELUDE (3a claim + 3b-0 deps-merged + 3b worktree create) — see build-level.design-notes-4.md#prelude-3a-claim-3b-0-deps-merged-3b-worktree-create
  const preludeSteps = [];
  const preludeAt = {}; // kind → index into preludeSteps / batch.results
  const addPrelude = (kind, cmd, continueOutcomes) => {
    preludeAt[kind] = preludeSteps.length;
    preludeSteps.push({ kind, cmd, continueOutcomes });
  };

  // 3a. Claim (claim-first), board ON only.
  // Claim-first applies to EVERY kind, spike included (build.md L312: "For a
  // spike: run 3a (claim, mark `[~]`), then spawn a read-only worker"). It is
  // therefore the FIRST step of the prelude and is branched on BEFORE the
  // kind:spike verdict-park below, so a spike-labeled item takes the
  // cross-session board lock before any investigation begins — without it, two
  // concurrent drivers could each pull and investigate the same spike with no
  // lock (temperloop#650).
  // Skipped on a continuation: the issue is already claimed by this run (the
  // escalation never released it), and a re-claim is at best a self-owned
  // no-op (spec 3d-esc step 4: "does NOT re-run 3a").
  //
  // ALSO skipped for a dual-build ARM (temperloop#2080). An in-scope item is
  // built TWICE, and a board write is a statement about the ITEM, not about one
  // arm of it: claiming per arm would write the same issue twice (the second
  // claim reading as a self-conflict), and the Done/close cascade must reflect
  // the arm that WON, which is not known until the level pick. So every board
  // write for an in-scope item is BUFFERED — bufferBoardWrite() below records
  // one entry per item, returned on the level's `dualBuild.board_writes` for
  // the pick to flush. The cross-session lock this costs is real and is the
  // declared trade of the barrier: the level's claims land in one batch after
  // the pick rather than at first touch.
  if (board && item.ghIssue && !isContinuation && !arm) {
    // The CLAIM entrypoint + --board are resolved by the orchestrator's Step — see build-level.design-notes-5.md#the-claim-entrypoint-board-are-resolved-by-the-orchestr
    const claimBin = input.claimCmd ?? 'claim.sh';
    addPrelude(
      'claim',
      // claim.sh exits 0 on success; we wrap a contention/no-op check into the — see build-level.design-notes-5.md#claim-sh-exits-0-on-success-we-wrap-a-contention-no-op-
      `${sq(claimBin)} ${sq(item.ghIssue)} --board ${sq(board)} && ` +
        `echo '{"outcome":"CLAIMED"}' || echo '{"outcome":"CLAIM_CONFLICT"}'`,
      ['CLAIMED'],
    );
  }

  // 3b-0 / 3b are prelude steps only for a NON-spike item: a spike is read — see build-level.design-notes-4.md#3b-0-3b-are-prelude-steps-only-for-a-non-spike-item-a-spike-
  const depShas = isContinuation
    ? []
    : (item.dependsOn ?? []).map((d) => d && d.sha).filter(Boolean);
  if (item.kind !== 'spike' && depShas.length > 0) {
    const wtGateBin = machineryBin(repoRoot, 'worktree.sh');
    addPrelude(
      'deps-merged',
      `${wtGateBin} deps-merged ${sq(repoRoot)} ${sq(depShas.join(','))}`,
      ['DEPS_MERGED'],
    );
  }

  // 3b. Pre-create the deterministic worktree (worktree.sh create). — see build-level.design-notes-5.md#3b-pre-create-the-deterministic-worktree-worktree-sh-create
  if (item.kind !== 'spike' && !isContinuation) {
    const wtBin = machineryBin(repoRoot, 'worktree.sh');
    const realSlug = arm ? arm.slug : item.slug;
    const armFlag = arm
      ? ` --arm ${sq(arm.sibling ? `${arm.name}:${arm.sibling}` : arm.name)}`
      : '';
    const createCmd = `${wtBin} create ${sq(repoRoot)} ${sq(realSlug)}${armFlag}`;
    addPrelude(
      'worktree',
      arm ? createCmd : dualBuildResidueGuard(repoRoot, item.slug, createCmd),
      ['CREATED'],
    );
  }

  const prelude = await runMachineryBatch(preludeSteps, {
    label: `prelude:${item.slug}`,
    slug: item.slug,
    bashTimeoutMs: BATCH_BASH_TIMEOUT_MS,
    phase: enterStage(STAGE_CLAIM), // 3a claim + 3b-0 deps-merged + 3b worktree
  });
  if (prelude.denied) {
    // temperloop#1819: deniedOrQuota — a quota death (canary cannot spawn) i — see build-level.design-notes-5.md#temperloop-1819-deniedorquota-a-quota-death-canary-cann
    return await deniedOrQuota(item.slug, {
      step: batchDeniedStep(prelude, 'prelude'),
      steps: prelude.steps,
      out: prelude.out,
    }, worktreePath);
  }
  // temperloop#1071 — a prelude step that outlived the liveness ceiling. Probed
  // with NO worktree path on purpose: the prelude is what CREATES the worktree,
  // so at this point there is nothing for recover-probe to read (and no push or
  // PR could exist yet). Escalates rather than re-running claim/worktree, either
  // of which would be a blind retry of a non-idempotent step.
  const preludeTimeout = timedOutStep(prelude.results);
  if (preludeTimeout) {
    return (await disposeStepTimeout(item, null, preludeTimeout, 'prelude')).escalation;
  }

  // 3a branch — unchanged decisions, read off the batch's first result.
  if (preludeAt.claim !== undefined) {
    const claimOut = batchStep(prelude, preludeAt.claim);
    if (claimOut.outcome === 'CLAIM_CONFLICT' || claimOut.outcome === 'ERROR') {
      return escalate(item.slug, 'claim-conflict', { claimOut });
    }
  }

  // kind: spike — read-only fork, NO push/PR (skip 3b–3h) — see build-level.design-notes-5.md#kind-spike-read-only-fork-no-push-pr-skip-3b-3h
  if (item.kind === 'spike') {
    log(`[${item.slug}] spike — read-only verdict fork (no PR)`);
    let verdict;
    try {
      verdict = await agent(
        workerPrompt(
        item,
        worktreePath,
        '## Spike (read-only)\nProduce a verdict note + routed follow-up issue. ' +
          'No commits, no push, no PR. Return status=done with the note path/issue ' +
          'in `summary` and `verification_surface_path` pointing at your verdict note.',
      ),
      {
        label: `worker:${item.slug}`,
        phase: enterStage(STAGE_BUILD),
        // temperloop#982: item.model || undefined — see callWorker()'s — see build-level.design-notes-5.md#temperloop-982-item-model-undefined-see-callworker-s
        model: item.model || undefined, // "" or undefined → inherit session model
        schema: WORKER_VERDICT_SCHEMA,
      },
      );
    } catch (err) {
      // temperloop#1819 — a thrown quota-death message classifies directly; — see build-level.design-notes-5.md#temperloop-1819-a-thrown-quota-death-message-classifies
      const msg = String((err && err.message) || err);
      if (quotaDeath(msg)) {
        return quotaEscalation(item.slug, 'worker (spike)', { errorText: msg, worktree: null });
      }
      throw err;
    }
    if (verdict == null) {
      // temperloop#1819 — the bare-null shape carries no text; ask the canary — see build-level.design-notes-5.md#temperloop-1819-the-bare-null-shape-carries-no-text-ask
      if (!(await harnessCanSpawnAgents())) {
        return quotaEscalation(item.slug, 'worker (spike)', { worktree: null });
      }
      // agent() returned null — user skip or terminal API error. Spikes are — see build-level.design-notes-5.md#agent-returned-null-user-skip-or-terminal-api-error-spi
      return escalate(item.slug, 'worker-error', { retryable: true, reason: 'agent returned null (spike worker)' });
    }
    if (verdict.status !== 'done') {
      return escalate(item.slug, verdict.status, { verdict });
    }
    // Spike parks as a verdict marker (no pr/pushed_sha). The orchestrator — see build-level.design-notes-5.md#spike-parks-as-a-verdict-marker-no-pr-pushed-sha-the-or
    return park(item.slug, null, null, verdict.acceptance_results);
  }

  // 3b-0 branch. Dep-merge precondition gate (#108) — see build-level.design-notes-5.md#3b-0-branch-dep-merge-precondition-gate-108
  if (preludeAt['deps-merged'] !== undefined) {
    const depOut = batchStep(prelude, preludeAt['deps-merged']);
    if (depOut.outcome !== 'DEPS_MERGED') {
      // A depended-on PR has NOT merged to origin/<default>. Do NOT create the — see build-level.design-notes-5.md#a-depended-on-pr-has-not-merged-to-origin-default-do-not-cre
      return escalate(item.slug, 'dep-not-merged', { depOut });
    }
  }

  // --- 3b branch. The deterministic worktree (worktree.sh create) ----------
  let wt = worktreePath;
  // temperloop#2080 — the two fields a dual-build ledger row reads off the — see build-level.design-notes-5.md#temperloop-2080-the-two-fields-a-dual-build-ledger-row-reads
  let wtBase = '';
  let wtGuard = 'UNKNOWN';
  if (preludeAt.worktree !== undefined) {
    const wtOut = batchStep(prelude, preludeAt.worktree);
    if (wtOut.outcome === 'DUAL_BUILD_RESIDUE') {
      // The flag-less-resume refusal (see the guard's own comment at 3b). This — see build-level.design-notes-5.md#the-flag-less-resume-refusal-see-the-guard-s-own-comment-at-
      return escalate(item.slug, 'dual-build-residue', {
        slug: item.slug,
        arms: wtOut.arms ?? null,
        reason:
          `REFUSING to build ${item.slug} single-arm: this level was left PARTIALLY DUAL-BUILT — ` +
          `arm worktree(s) for this slug still stand at ${repoRoot}.wt/${item.slug}@*. A flag-less /build ` +
          'would either rebuild the item a third time on the session model or silently adopt one arm, ' +
          'and neither is a level pick (ADR 0038). Re-run /build with --dual-build to finish the pick, or ' +
          'dispose the arms deliberately first.',
        remedy:
          `ls -d ${repoRoot}.wt/${item.slug}@*   # then either: /build --dual-build <tier>=<candidate> ` +
          `(resume the comparison), or: worktree.sh remove ${repoRoot} '${item.slug}@<arm>' for each arm ` +
          'once you have archived what you want to keep',
      });
    }
    if (wtOut.outcome !== 'CREATED') {
      return escalate(item.slug, 'worktree-failed', { wtOut });
    }
    wtBase = typeof wtOut.base === 'string' ? wtOut.base : '';
    wtGuard = wtOut.guard === 'ARMED' || wtOut.guard === 'UNARMED' ? wtOut.guard : 'UNKNOWN';
    // worktree.sh's CREATED.path is the authoritative deterministic path; it — see build-level.design-notes-5.md#worktree-sh-s-created-path-is-the-authoritative-determi
    wt = wtOut.path ?? worktreePath;
    // temperloop#2006 — READ the sideline verdict the CREATED line already — see build-level.design-notes-5.md#temperloop-2006-read-the-sideline-verdict-the-created-line-a
    noteSideline(item.slug, wtOut);
  }

  // 3c. Spawn the worker (NO isolation:'worktree' — DESIGN NOTE 3) — see build-level.design-notes-5.md#3c-spawn-the-worker-no-isolation-worktree-design-note-3
  let recovery = null; // temperloop#939 — set only on a lost-return recovery
  // temperloop#2065 — the main worker's cost, accumulated across BOTH this — see build-level.design-notes-5.md#temperloop-2065-the-main-worker-s-cost-accumulated-across-bo
  let mainCost = { wallClockMs: null, tokensIn: null, tokensOut: null };
  // temperloop#2137 — the ALREADY-FIXED CONTINUATION CLOSE, and it sits HERE,
  // before the spawn, because that is the only place the spawn can still be
  // avoided. Runs at most one machinery call, and only on a `review-blocking`
  // continuation whose findings name a checkable `<path>:<line>`; every other
  // path (a fresh item, any other escalation kind, findings with no located
  // line) short-circuits in JS with no extra call at all. See
  // continuationAlreadyFixed() for the fail-closed contract — `fixed` is true
  // ONLY on a positively-established ALREADY_FIXED, so every uncertainty spawns
  // the worker exactly as before.
  const alreadyFixed = await continuationAlreadyFixed(
    item,
    wt,
    isContinuation ? input.verdicts?.[item.slug] : null,
    enterStage(STAGE_BUILD),
  );
  if (alreadyFixed.fixed) {
    log(
      `[${item.slug}] §3c worker spawn SKIPPED (temperloop#2137) — this \`review-blocking\` ` +
        `continuation's branch tip already carries the fix: ${alreadyFixed.reason} ` +
        `(prior reviewed SHA ${alreadyFixed.sha ?? 'unknown'}; checked ` +
        `${alreadyFixed.locations.map((l) => `${l.file}:${l.line}`).join(', ')}). ` +
        'Re-running §3e only; the PR body records that no worker ran and why.',
    );
  }
  let w = alreadyFixed.fixed
    ? null
    : await callWorker(item, wt, verdictSection, `worker:${item.slug}`, enterStage(STAGE_BUILD));
  if (w) mainCost = mergeWorkerCost(mainCost, w);
  // alreadyFixedVerdict() never returns null, so the whole lost-return recovery
  // ladder below is reachable ONLY on the spawning arm — `w` is non-null there.
  let verdict = alreadyFixed.fixed ? alreadyFixedVerdict(item, alreadyFixed) : w.verdict;
  if (verdict == null) {
    // temperloop#1819 — classify a session-quota death FIRST, before the pro — see build-level.design-notes-5.md#temperloop-1819-classify-a-session-quota-death-first-be
    if (await workerQuotaDeath(w)) {
      return quotaEscalation(item.slug, 'worker', {
        errorText: w.nullReturn ? null : w.error,
        worktree: wt,
      });
    }
    // No verdict — either agent() returned null (user skip, transient 5xx, o — see build-level.design-notes-5.md#no-verdict-either-agent-returned-null-user-skip-transient-5x
    let probe = await probeSideEffects(item, wt);
    if (probe.landed) {
      recovery = probe;
    } else {
      // Nothing COMMITTED → this is the ordinary stall. Retry exactly once, — see build-level.design-notes-5.md#nothing-committed-this-is-the-ordinary-stall-retry-exactly-o
      if (probe.stalled) {
        log(`[${item.slug}] worker returned no verdict; ${probe.dirtyFiles} uncommitted path(s), 0 commits — the #993 backgrounded-gate stall: auto-resuming on the same worktree (foreground cure)`);
      } else {
        log(`[${item.slug}] worker returned no verdict, no side-effects — retrying once (foreground cure #1219)`);
      }
      w = await callWorker(item, wt, withCure(verdictSection, probe.dirtyFiles, item.slug), `worker:${item.slug}#retry`, enterStage(STAGE_BUILD));
      mainCost = mergeWorkerCost(mainCost, w);
      verdict = w.verdict;
      if (verdict == null) {
        // temperloop#1819 — the RETRY can be the spawn that crosses the quota — see build-level.design-notes-5.md#temperloop-1819-the-retry-can-be-the-spawn-that-crosses
        if (await workerQuotaDeath(w)) {
          return quotaEscalation(item.slug, 'worker (retry)', {
            errorText: w.nullReturn ? null : w.error,
            worktree: wt,
          });
        }
        // The retry may itself have built and lost its return — probe again.
        probe = await probeSideEffects(item, wt);
        if (probe.landed) recovery = probe;
      }
    }
    if (verdict == null) {
      if (!recovery) {
        // GENUINELY nothing committed — the unchanged escalation path. When the — see build-level.design-notes-5.md#genuinely-nothing-committed-the-unchanged-escalation-path-wh
        return escalate(item.slug, 'worker-error', {
          retryable: true,
          reason: probe.stalled
            ? `worker returned no verdict after a foreground-instructed re-spawn; ${probe.dirtyFiles} uncommitted path(s) and 0 commits remain in the worktree (temperloop#993) — inspect the worktree before skipping (skip prunes it)`
            : (w.error ?? 'agent returned no verdict after one retry (main worker)'),
          ...(probe.stalled ? { shape: 'foreground-stall', dirty_files: probe.dirtyFiles, worktree: wt } : {}),
        });
      }
      log(`[${item.slug}] worker return lost (${w.error}) — recovered from side-effects at ${recovery.stage}; acceptance UNVERIFIED`);
      verdict = recoveredVerdict(item, recovery, w.error);
    }
  }

  // 3d. Branch on the verdict — see build-level.design-notes-5.md#3d-branch-on-the-verdict
  if (verdict.status !== 'done') {
    return escalate(item.slug, verdict.status, { verdict });
  }
  // temperloop#1182: a host-config DEFERRAL (`passed: false` + a non-empty
  // `deferred_host_config`) is excluded here — it is not a failure, it is a
  // criterion this worker structurally could not observe, re-homed to the
  // orchestrator's parent-side check at build.md §4a. Escalating it would
  // stall the level on a reading that is `false` in every worktree on every
  // host regardless of the truth (foundation#1556). A bare `passed: false`
  // with no marker escalates exactly as before — the exclusion is the pair,
  // never the boolean alone, so this cannot silently swallow a real failure.
  const anyFailed = (verdict.acceptance_results ?? []).some(
    (r) => r.passed === false && !isHostConfigDeferral(r),
  );
  if (anyFailed) {
    return escalate(item.slug, 'acceptance-incomplete', { verdict });
  }
  // temperloop#1319 degraded case: computed once here (empty when — see build-level.design-notes-5.md#temperloop-1319-degraded-case-computed-once-here-empty-
  const discGaps = discriminationGaps(verdict);

  // 3e. Mandatory/routed pre-push review (temperloop#1430) — see build-level.design-notes-5.md#3e-mandatory-routed-pre-push-review-temperloop-1430
  const priorReviewFindings =
    isContinuation && input.verdicts?.[item.slug]?.kind === 'review-blocking'
      ? input.verdicts[item.slug].verdict_section
      : undefined;
  const review = await runReviewers(item, wt, priorReviewFindings);
  if (review.escalation) return review.escalation;
  if (review.blocking.length > 0) {
    // temperloop#1970 — the convergence bound. Under it, a HIGH escalates
    // exactly as before (byte-identical for every item that converges within
    // its round budget). AT it, the loop stops: the item proceeds to 3e.5/3f
    // and the residual findings ride the PR body's `## Review notes` (via
    // reviewBodySuffix below, which already renders review.sections in full)
    // plus the parked record's `review.residual_blocking` tally, so the human
    // at the merge gate reads them. Findings are carried, never suppressed.
    if (!reviewBoundReached(review)) {
      return escalate(item.slug, 'review-blocking', {
        findings: review.blocking,
        round: review.round,
        max_rounds: REVIEW_BLOCKING_MAX_ROUNDS,
      });
    }
    review.residualBlocking = true;
    log(
      `[${item.slug}] §3e review round ${review.round}/${REVIEW_BLOCKING_MAX_ROUNDS} still has ` +
        `${review.blocking.length} BLOCKING finding(s) — convergence bound reached (temperloop#1970): ` +
        `opening the PR with them carried in ## Review notes instead of escalating again ` +
        `(${review.blocking.map((b) => b.reviewer).join(', ')})`,
    );
  }
  // Carried into the PR body at 3f below (verdictJson.summary) — the PR mu — see build-level.design-notes-5.md#carried-into-the-pr-body-at-3f-below-verdictjson-summary-the
  const reviewSummarySuffix = reviewBodySuffix([review]);

  // Resolve the gate script from the WORKTREE, not repoRoot (temperloop#62 — see build-level.design-notes-5.md#resolve-the-gate-script-from-the-worktree-not-reporoot-tempe
  const qgBin = `${wt}/scripts/quality-gates.sh`;

  // 3e.5-pre. Gate-freshness rebase (temperloop#1937) — see build-level.design-notes-5.md#3e-5-pre-gate-freshness-rebase-temperloop-1937
  const freshness = await runGateFreshness(item, wt, qgBin);
  if (freshness) return freshness;

  // --- 3e.5. Parent-side acceptance gate (quality-gates.sh) ----------------
  // Run the project's static gate SSOT against the worker's work. ABSENT ( — see build-level.design-notes-3.md#run-the-project-s-static-gate-ssot-against-the-worker-s-work
  const settingsBin = `${wt}/workflows/scripts/build/build-config-settings.sh`;
  // ONE LINE ON PURPOSE: the K2142 behavioural prong lifts this exact line out of
  // the file and executes it, so keep it a single `const` whose only interpolation
  // is `${sq(settingsBin)}` (which that prong rewrites to a fixture path).
  const gateScrub = `{ ( unset -v __qg_noop $(bash ${sq(settingsBin)} 2>/dev/null | grep -E '^[A-Za-z_][A-Za-z0-9_]*$') ) 2>/dev/null && unset -v __qg_noop $(bash ${sq(settingsBin)} 2>/dev/null | grep -E '^[A-Za-z_][A-Za-z0-9_]*$') 2>/dev/null || :; }`;
  // gateCmd(startAt) — one SLICE of the suite (temperloop#1021). — see build-level.design-notes-5.md#gatecmd-startat-one-slice-of-the-suite-temperloop-1021
  const gateLog = `/tmp/qg-${item.slug}.log`;
  // ONE SLICE'S OWN OUTPUT, kept separate from the cumulative log above — see build-level.design-notes-5.md#one-slice-s-own-output-kept-separate-from-the-cumulative-log
  const gateSliceLog = `${gateLog}.slice`;
  // temperloop#1663: run the acceptance gate DIFF-SCOPED — only the gates this
  // item's own changed paths can reach, resolved through gate-paths.tsv.
  //
  // WHY. The full per-item suite could not survive within-level parallelism, and
  // the ceiling it hit is not tunable. Measured on a 3-item level: 55 minutes,
  // 21 agents, 1.24M subagent tokens, ZERO items landed — all three escalated
  // `acceptance-gate-timeout` with every worker finished and committed and only
  // the verdict missing. Three concurrent full suites is 3x QUALITY_GATES_JOBS
  // workers on one machine; contention inflated the gate tail 200-300% (gates
  // that take seconds took 121s), while GATE_SLICE_SECS_MAX sits only 20% above
  // the budget that failed and CANNOT be raised past AGENT_BASH_CAP_MS. So the
  // suite has to get SHORTER, not the budget longer — and the map that knows
  // which gates a diff can reach already exists and was already trusted.
  //
  // WHY IT IS SAFE. This puts §3e.5 on exactly the same footing as the
  // `pull_request` run of CI's `checks` job, which has been scoped through this
  // same map since #1024 — so scoping here adds no failure mode that the PR
  // check does not already carry. What actually gates `main` is the UNSCOPED
  // merge_group run, and that is untouched. Every resolution failure in the
  // selector widens to the full set (gate-selection.sh's four silent-green
  // defenses), and a scoped run names every gate it skipped, twice.
  //
  // THE SEAM IS AN ENV VAR, NOT THE `--scoped` FLAG, for the same reason the
  // slice budget below is: a consuming repo vendoring an OLDER quality-gates.sh
  // ignores an unknown env var and runs the whole suite (the pre-#1663 behavior,
  // still correct), whereas an unknown FLAG exits 2 "usage" and reads back here
  // as a GATE FAILURE.
  //
  // BUILD_GATE_SCOPED is read HERE, in the emitted shell, rather than plumbed in
  // as an orchestrator `input.*` key like gateSliceSecs. That is deliberate and
  // is the narrower seam, not a shortcut: gateSliceSecs must reach the .mjs's
  // OWN control flow (it derives GATE_BASH_TIMEOUT_MS and bounds the slice
  // loop), and the Workflow runtime has no shell to source build.config.sh with
  // — DESIGN NOTE 1. This value is needed ONLY inside the command string, which
  // is bash, and it is read from the WORKTREE'S config, i.e. the version of the
  // setting the change under test actually ships. The read is a subshell so the
  // #1241 scrub below still governs the gate's own environment; an absent or
  // older config file leaves `${BUILD_GATE_SCOPED:-1}` at the default.
  const configBin = `${wt}/workflows/scripts/build/build.config.sh`;
  const gateScopeEnv =
    `QUALITY_GATES_SCOPED=$(. ${sq(configBin)} >/dev/null 2>&1; echo "\${BUILD_GATE_SCOPED:-1}")`;
  // SLICE-STABLE SELECTION (temperloop#1663). `QUALITY_GATES_START_AT` is — see build-level.design-notes-5.md#slice-stable-selection-temperloop-1663-quality-gates-start-a
  const gatePin = `/tmp/qg-${item.slug}.selection-pin`;
  // A THROWAWAY COPY of the pin, so the dry run cannot WRITE the shared  — see build-level.design-notes-6.md#a-throwaway-copy-of-the-pin-so-the-dry-run-cannot-write-the-sh
  const gateProbePin = `${gatePin}.probe`;
  // gateInFlightSelectCmd(idx) — the ONE builder the executed probe AND the — see build-level.design-notes-6.md#gateinflightselectcmd-idx-the-one-builder-the-executed-probe-a
  const gateInFlightSelectCmd = (idx) =>
    `( if [ -s ${sq(gatePin)} ]; then cp -f ${sq(gatePin)} ${sq(gateProbePin)}; else rm -f ${sq(gateProbePin)}; fi; ` +
    `cd ${sq(wt)} && ${gateScopeEnv} QUALITY_GATES_SELECTION_PIN=${sq(gateProbePin)} ` +
    `${sq(qgBin)} --list-selected` +
    (idx === null ? ' )' : ` | grep -E '^(make|bash) ' | sed -n '${idx + 1}p' )`);
  // gateInFlightNameCmd(idx, expectSel) — turn a stopped run's gate ORDINA — see build-level.design-notes-6.md#gateinflightnamecmd-idx-turn-a-stopped-run-s-gate-ordinal-into
  // The `2>/dev/null` lives HERE, on the machine path, never in the builder — see build-level.design-notes-6.md#the-resolve-line-is-the-one-that-must-speak-no-stderr-redirect
  const gateInFlightNameCmd = (idx, expectSel) =>
    `if [ ! -x ${sq(qgBin)} ]; then echo '{"outcome":"GATE_NAME_UNKNOWN"}'; else ` +
    `__L=$( ${gateInFlightSelectCmd(null)} 2>/dev/null ); ` +
    `__ls=$(printf '%s\\n' "$__L" | sed -n 's/^QUALITY_GATES_SELECTION=//p' | tail -1); ` +
    `__g=$(printf '%s\\n' "$__L" | grep -E '^(make|bash) ' | sed -n '${idx + 1}p' | tr -d '"\\\\'); ` +
    `if [ -n ${sq(expectSel ?? '')} ] && [ -n "$__ls" ] && [ "$__ls" != ${sq(expectSel ?? '')} ]; then __g=''; fi; ` +
    `if [ -n "$__g" ]; then printf '{"outcome":"GATE_NAMED","gate":"%s"}\\n' "$__g"; ` +
    `else echo '{"outcome":"GATE_NAME_UNKNOWN"}'; fi; fi`;
  const gateCmd = (startAt, expectSelection) =>
    `set -o pipefail; if [ ! -x ${sq(qgBin)} ]; then echo '{"outcome":"GATE_ABSENT"}'; ` +
    `else ${startAt === 0 ? `rm -f ${sq(gatePin)} ${sq(gateProbePin)} ${sq(gateSliceLog)}; : >${sq(gateLog)}; ` : ''}` +
    `( cd ${sq(wt)} && ${gateScrub} && ` +
    `${gateScopeEnv} QUALITY_GATES_SELECTION_PIN=${sq(gatePin)} ` +
    `${expectSelection ? `QUALITY_GATES_EXPECT_SELECTION=${sq(expectSelection)} ` : ''}` +
    `QUALITY_GATES_START_AT=${startAt} QUALITY_GATES_BUDGET_SECS=${GATE_SLICE_SECS} ${sq(qgBin)} ) ` +
    `2>&1 | tee ${sq(gateSliceLog)} >>${sq(gateLog)}; __rc=$?; ` +
    `__el=$(sed -n 's/.*passed in \\([0-9]*\\)s.*/\\1/p;s/.*of [0-9]* in \\([0-9]*\\)s.*/\\1/p' ${sq(gateSliceLog)} | tail -1); ` +
    `__f=$(sed -n 's/^QUALITY_GATES_FAILED=//p' ${sq(gateSliceLog)} | tail -1); ` +
    `__r=$(sed -n 's/^QUALITY_GATES_RESUME_AT=//p' ${sq(gateSliceLog)} | tail -1); ` +
    // THE RESUME POINT IS LOAD-BEARING, SO ITS SHAPE IS CHECKED (review roun — see build-level.design-notes-5.md#the-resume-point-is-load-bearing-so-its-shape-is-checked-rev
    `case "$__r" in ''|*[!0-9]*) __r='' ;; esac; ` +
    `__s=$(sed -n 's/^QUALITY_GATES_SELECTION=//p' ${sq(gateSliceLog)} | tail -1); ` +
    // AN UNKNOWN ELAPSED IS `null`, NEVER `0` (temperloop#1698). `__el` is a — see build-level.design-notes-5.md#an-unknown-elapsed-is-null-never-0-temperloop-1698-el-is-a
    `case "$__el" in ''|*[!0-9]*) __elj=null ;; *) __elj=$__el ;; esac; ` +
    // temperloop#865 — CLASSIFY THE WORKER'S OWN GATE SENTINEL, parent-side. — see build-level.design-notes-5.md#temperloop-865-classify-the-worker-s-own-gate-sentinel-paren
    `__wg=absent; if [ -f ${sq(workerGateSentinel(item.slug))} ]; then ` +
    `case "$(cat ${sq(workerGateSentinel(item.slug))} 2>/dev/null)" in ` +
    `*'"state":"finished"'*) __wg=finished ;; *'"state":"running"'*) __wg=running ;; *) __wg=unknown ;; esac; fi; ` +
    // A RESUME POINT THIS SLICE PRINTED IS THE VERDICT (temperloop#2094). — see build-level.design-notes-5.md#a-resume-point-this-slice-printed-is-the-verdict-temperloop-
    `if [ -n "$__r" ]; then ` +
    `printf '{"outcome":"GATE_SLICE","resumeAt":%s,"failed":%s,"elapsedSecs":%s,"selection":"%s","rc":%s,"workerGate":"%s","budgetSecs":${GATE_SLICE_SECS}}\\n' "$__r" "\${__f:-0}" "$__elj" "$__s" "$__rc" "$__wg"; ` +
    `elif [ "$__rc" = 0 ]; then ` +
    `printf '{"outcome":"GATE_PASS","failed":0,"elapsedSecs":%s,"workerGate":"%s","budgetSecs":${GATE_SLICE_SECS}}\\n' "$__elj" "$__wg"; ` +
    `else printf '{"outcome":"GATE_FAIL","failed":%s,"elapsedSecs":%s,"rc":%s,"workerGate":"%s","budgetSecs":${GATE_SLICE_SECS}}\\n' "\${__f:-1}" "$__elj" "$__rc" "$__wg"; fi; fi`;

  // Drive slices until the suite finishes. GATE_SLICE is the ONLY outcome  — see build-level.design-notes-5.md#drive-slices-until-the-suite-finishes-gate-slice-is-the
  let gateOut = null;
  let gateStartAt = 0;
  let gateElapsed = 0;
  // temperloop#1698 — sticky once ANY slice reported no usable elapsed fig — see build-level.design-notes-5.md#temperloop-1698-sticky-once-any-slice-reported-no-usabl
  let gateElapsedUnknown = false;
  let gateSlices = 0;
  // The selection fingerprint the PREVIOUS slice reported (temperloop#1663 — see build-level.design-notes-5.md#the-selection-fingerprint-the-previous-slice-reported-t
  let gateSelection = '';
  // gateSliceLedger — the AUTHORITATIVE record of what this gate run found — see build-level.design-notes-5.md#gatesliceledger-the-authoritative-record-of-what-this-gate-r
  const gateSliceLedger = [];
  // gateSliceCeiling — the EFFECTIVE loop bound, starting at GATE_MAX_SLIC — see build-level.design-notes-5.md#gatesliceceiling-the-effective-loop-bound-starting-at-gate-m
  let gateSliceCeiling = GATE_MAX_SLICES;
  let gateExtensionsUsed = 0;
  for (; gateSlices < gateSliceCeiling; gateSlices++) {
    gateOut = await runMachinery(gateCmd(gateStartAt, gateSelection), {
      label: `gate:${item.slug}`,
      slug: item.slug,
      phase: enterStage(STAGE_GATE),
      // temperloop#115/#1021: without an explicit timeout the executor's Bash — see build-level.design-notes-5.md#temperloop-115-1021-without-an-explicit-timeout-the-exe
      bashTimeoutMs: GATE_BASH_TIMEOUT_MS,
      // …and if that backstop DOES fire, the executor reports GATE_TIMEOUT, no — see build-level.design-notes-5.md#and-if-that-backstop-does-fire-the-executor-reports-gat
      timeoutOutcome: 'GATE_TIMEOUT',
    });
    if (machineryDenied(gateOut)) {
      // temperloop#1819: the #1819 incident's own machinery shape — a gate — see build-level.design-notes-5.md#temperloop-1819-the-1819-incident-s-own-machinery-shape
      return await deniedOrQuota(item.slug, { step: 'gate', out: gateOut }, wt);
    }
    // temperloop#1071 — the gate slice outlived the workflow liveness ceilin — see build-level.design-notes-5.md#temperloop-1071-the-gate-slice-outlived-the-workflow-livenes
    if (gateOut.outcome === 'STEP_TIMEOUT') {
      return (await disposeStepTimeout(item, wt, gateOut, 'gate', { adoptable: false })).escalation;
    }
    // temperloop#1698 — STRICT read of the canonical key. `Number(x) || 0` w — see build-level.design-notes-5.md#temperloop-1698-strict-read-of-the-canonical-key-number-x-0-
    const sliceElapsed = numOrNull(gateOut.elapsedSecs);
    if (sliceElapsed === null) {
      gateElapsedUnknown = true;
      log(
        `[${item.slug}] 3e.5 gate slice ${gateSlices + 1} reported NO usable elapsedSecs — the gate DECAY SIGNAL ` +
        `is blind for this slice and the run's wall time renders '?', never 0 (temperloop#1698). The verdict itself ` +
        `is unaffected; the authoritative elapsed figure is in ${gateLog}.`,
      );
    } else {
      gateElapsed += sliceElapsed;
    }
    gateSliceLedger.push({
      slice: gateSlices + 1,
      startAt: gateStartAt,
      outcome: gateOut.outcome,
      failed: gateSliceFailed(gateOut),
      elapsedSecs: sliceElapsed,
      // The RESUME POINT this slice reported, carried into the ledger — see build-level.design-notes-5.md#the-resume-point-this-slice-reported-carried-into-the-ledger
      ...(gateSliceResumeAt(gateOut) === undefined ? {} : { resumeAt: gateSliceResumeAt(gateOut) }),
      // The slice's own exit status, when the executor reported one. 75 is the — see build-level.design-notes-5.md#the-slice-s-own-exit-status-when-the-executor-reported-
      ...(gateOut.rc === undefined ? {} : { rc: Number(gateOut.rc) }),
      // The LIST IDENTITY this slice walked (temperloop#1650 round 3). Already — see build-level.design-notes-6.md#the-list-identity-this-slice-walked-temperloop-1650-round-3
      ...(typeof gateOut.selection === 'string' && gateOut.selection !== ''
        ? { selection: gateOut.selection }
        : {}),
    });
    if (gateOut.outcome !== 'GATE_SLICE') break;
    gateStartAt = Number(gateOut.resumeAt) || 0;
    // Carry the list identity forward with the index it belongs to. A slice  — see build-level.design-notes-5.md#carry-the-list-identity-forward-with-the-index-it-belon
    gateSelection = typeof gateOut.selection === 'string' ? gateOut.selection : '';
    // temperloop#2135 — RESUME instead of escalating. A slice that is about — see build-level.design-notes-5.md#temperloop-2135-resume-instead-of-escalating-a-slice-that-is
    if (
      gateSlices + 1 === gateSliceCeiling
      && gateExtensionsUsed < GATE_RESUME_EXTENSIONS
      // temperloop#2133 — the load-bearing one: this grants MORE budget on the
      // strength of "zero failures so far", so it must require a KNOWN zero.
      && gateSliceLedger.every((s) => Number.isFinite(s.failed) && s.failed === 0)
    ) {
      gateSliceCeiling += GATE_MAX_SLICES;
      gateExtensionsUsed++;
      log(
        `[${item.slug}] 3e.5 gate slice budget (${GATE_MAX_SLICES} slices) exhausted with 0 failures — ` +
        `resuming with another ${GATE_MAX_SLICES}-slice allotment (extension ${gateExtensionsUsed}/${GATE_RESUME_EXTENSIONS}) ` +
        `instead of escalating (temperloop#2135)`,
      );
    }
    log(`[${item.slug}] 3e.5 gate slice ${gateSlices + 1}/${gateSliceCeiling} spent its ${GATE_SLICE_SECS}s budget — resuming at gate ${gateStartAt}`);
  }

  // ONE verdict, derived once from the ledger (temperloop#1587), and ONE — see build-level.design-notes-5.md#one-verdict-derived-once-from-the-ledger-temperloop-158
  const gateReport = gateVerdict(gateOut.outcome, gateSliceLedger);
  const gatePayload = {
    // `verdict` is the field to trust: RED / UNKNOWN / GREEN. `outcome` is t — see build-level.design-notes-5.md#verdict-is-the-field-to-trust-red-unknown-green-outcome-is-t
    verdict: gateReport.verdict,
    outcome: gateOut.outcome,
    suiteFinished: gateReport.finished,
    failedGates: gateReport.failedGates,
    failedInSlices: gateReport.failedInSlices,
    reason: gateReport.reason,
    // Also derived from the ledger, not from the loop counter: on slice-cap — see build-level.design-notes-5.md#also-derived-from-the-ledger-not-from-the-loop-counter-on-sl
    slices: gateSliceLedger.length,
    // temperloop#2135 — how many extra GATE_MAX_SLICES allotments the RESUME — see build-level.design-notes-5.md#temperloop-2135-how-many-extra-gate-max-slices-allotmen
    resumeExtensionsUsed: gateExtensionsUsed,
    // temperloop#1698 — `null`, not a partial sum, when any slice's figure w — see build-level.design-notes-5.md#temperloop-1698-null-not-a-partial-sum-when-any-slice-s
    elapsedSecs: gateElapsedUnknown ? null : gateElapsed,
    sliceBudgetSecs: GATE_SLICE_SECS,
    sliceLedger: gateSliceLedger,
    log: gateLog,
    // temperloop#865 — what the WORKER's own scoped gate left behind in this — see build-level.design-notes-5.md#temperloop-865-what-the-worker-s-own-scoped-gate-left-b
    workerGate: workerGateState(gateOut),
  };
  // temperloop#865 — THE LOUD HALF. A worker that backgrounded its gate an — see build-level.design-notes-5.md#temperloop-865-the-loud-half-a-worker-that-backgrounded-its-
  const wgState = gatePayload.workerGate;
  if (wgState === 'running') {
    log(
      `[${item.slug}] WORKER GATE NEVER FINISHED (temperloop#865) — the worker's own scoped-gate sentinel at ` +
      `${workerGateSentinel(item.slug)} still reads state:"running", so the worker most likely BACKGROUNDED ` +
      `\`scripts/quality-gates.sh --scoped\` and yielded rather than reading its result. Its self-check is ` +
      `UNVERIFIED; the parent-side 3e.5 verdict above is the authority. A stalled worker now reads differently ` +
      `from a slow one — that distinction is this signal's whole job.`,
    );
  } else if (wgState === 'unknown') {
    log(
      `[${item.slug}] worker gate sentinel UNREADABLE (temperloop#865) — ${workerGateSentinel(item.slug)} exists but ` +
      `carries no state; treat the worker's own gate self-check as unverified.`,
    );
  }
  // A TIMEOUT is NOT a gate failure — its own escalation kind, so an opera — see build-level.design-notes-5.md#a-timeout-is-not-a-gate-failure-its-own-escalation-kind-so-a
  if (gateReport.verdict === 'UNKNOWN') {
    // temperloop#1650 — NAME the gate in flight and the CLAMP, so the remedy is — see build-level.design-notes-6.md#temperloop-1650-name-the-gate-in-flight-and-the-clamp-so-the
    const inFlightIndex = gateInFlightIndex(gateSliceLedger);
    let inFlightGate = null;
    if (inFlightIndex !== undefined) {
      // The list identity the STOPPED RUN walked — the oracle the probe's own — see build-level.design-notes-6.md#the-list-identity-the-stopped-run-walked-the-oracle-the-probe
      let expectSelection = '';
      for (const s of gateSliceLedger) {
        if (typeof s.selection === 'string' && s.selection !== '') expectSelection = s.selection;
      }
      inFlightGate = {
        index: inFlightIndex,
        slice: gateSliceLedger.length,
        resolve: gateInFlightSelectCmd(inFlightIndex),
        sliceLog: gateSliceLog,
        ...(expectSelection === '' ? {} : { selection: expectSelection }),
      };
      // Fail-SOFT: the escalation is the deliverable, the name is an enrichment.
      try {
        const named = await runMachinery(gateInFlightNameCmd(inFlightIndex, expectSelection), {
          label: `gate-inflight:${item.slug}`,
          slug: item.slug,
          bashTimeoutMs: GATE_INFLIGHT_NAME_TIMEOUT_MS,
        });
        const gateName = named && named.outcome === 'GATE_NAMED' ? String(named.gate ?? '').trim() : '';
        if (gateName !== '') inFlightGate.gate = gateName;
      } catch { /* an unresolved name never costs the escalation */ }
    }
    return escalate(item.slug, 'acceptance-gate-timeout', {
      ...gatePayload,
      inFlightGate,
      remedy: gateUnknownRemedy(gateOut.outcome, inFlightGate, gateSliceLedger.length),
    });
  }
  // A genuinely RED suite still escalates exactly as before — including th — see build-level.design-notes-5.md#a-genuinely-red-suite-still-escalates-exactly-as-before
  if (gateReport.verdict === 'RED') {
    return escalate(item.slug, 'acceptance-gate-failed', gatePayload);
  }
  // GATE_PASS or GATE_ABSENT → proceed. Report the MARGIN, not just the ve — see build-level.design-notes-5.md#gate-pass-or-gate-absent-proceed-report-the-margin-not-
  if (gateOut.outcome === 'GATE_PASS') {
    // temperloop#1698 — render an unknown total as `?`, never as a number. T — see build-level.design-notes-6.md#temperloop-1698-render-an-unknown-total-as-never-as-a-n
    const marginNote = gateSlices > 0 || (!gateElapsedUnknown && gateElapsed >= GATE_SLICE_SECS * GATE_MARGIN_WARN_RATIO)
      ? ` — NOTE: approaching the per-slice budget; raise BUILD_GATE_SLICE_SECS or split the gate list before it costs a re-slice`
      : '';
    const elapsedNote = gateElapsedUnknown ? '?' : String(gateElapsed);
    log(`[${item.slug}] 3e.5 gate PASS — ${gateSlices + 1} slice(s), ${elapsedNote}s of gate wall time (slice budget ${GATE_SLICE_SECS}s, ` +
      // temperloop#2133 — this line IS the decay signal an operator reads to decide
      // whether to raise BUILD_GATE_SLICE_SECS or split the gate list, so every
      // figure in it must mean the same thing on every run. `cap ${gateSliceCeiling}`
      // did not: on a run that spent an extension it rendered the MID-RUN ceiling,
      // which is neither the configured base cap nor the hard bound. Name the base
      // cap, the extension allowance, the hard bound and the extensions actually
      // spent, each derived from its constant — never a literal (kernel § Named-
      // setting convention).
      `base cap ${GATE_MAX_SLICES} slices (+${GATE_RESUME_EXTENSIONS} extension(s) allowed, ` +
      `hard cap ${GATE_MAX_SLICES * (GATE_RESUME_EXTENSIONS + 1)}; ${gateExtensionsUsed} used, ` +
      `ceiling this run ${gateSliceCeiling}))${marginNote}`);
  }

  // --- 3e.6. Class-A activation gate (temperloop#1219) ----------------------
  // Runs HERE — strictly between 3e.5 and 3f, before anything is pushed — so a
  // Fail costs a loop-back to 3c rather than a re-push onto an open PR. The
  // whole gate lives in runActivationGate() above (with its rationale); this is
  // the ONE line the ordering contract is about. A non-class-A item returns null
  // from its first line: no agent spawn, no log, path unchanged.
  const activationEscalation = await runActivationGate(item, wt);
  if (activationEscalation) return activationEscalation;

  // ===== END OF PHASE 1 (temperloop#2080) =============================== — see build-level.design-notes-5.md#end-of-phase-1-temperloop-2080
  box.ctx = {
    item,
    arm,
    wt,
    verdict,
    recovery,
    review,
    reviewSummarySuffix,
    discGaps,
    mainCost,
    // Read by the dual-build ledger row only; the PR phase ignores them.
    wtBase,
    wtGuard,
    gateReport,
    gateElapsedSecs: gateElapsedUnknown ? null : gateElapsed,
  };
  return null;
}

// ====================================================================== — see build-level.design-notes-5.md#note
async function driveItemPr(ctx) {
  const {
    item, wt, verdict, recovery, review, reviewSummarySuffix, discGaps, mainCost,
  } = ctx;
  const { repoRoot, planLink } = input;
  const ownerRepo = input.ownerRepo; // "owner/repo" — passed by the orchestrator

  // --- 3f. Push and open the PR (ONE batched executor — temperloop#942) -----
  // rebase → scan → push → pr-open are four adjacent, seconds-scale machinery
  // calls that used to cost four agent spawns. They now ride ONE
  // `pr-batch:<slug>` executor: the shell runs them in order and prints each
  // script's own JSON line, and every branch below still reads that step's own
  // object here in .mjs. The batch's `case` gates mirror those branches so a
  // REBASE_CONFLICT / SCAN_BLOCKED / PUSH_REJECTED never lets a later step run.
  const prBin = machineryBin(repoRoot, 'pr.sh');
  const prSteps = [];
  const prAt = {};
  const addPrStep = (kind, cmd, continueOutcomes) => {
    prAt[kind] = prSteps.length;
    prSteps.push({ kind, cmd, continueOutcomes });
  };

  // 3f-0a. Rebase onto fresh origin/<default> — the unconditional stale-ba — see build-level.design-notes-5.md#3f-0a-rebase-onto-fresh-origin-default-the-unconditional-sta
  if (!(recovery && recovery.pushed)) {
    addPrStep('rebase', `${prBin} rebase ${sq(wt)}`, ['REBASED']);
  } else {
    log(`[${item.slug}] recovery (${recovery.stage}) — skipping 3f-0a rebase (branch already on origin)`);
  }

  // 3f-0. Closing-keyword pre-push scan.
  addPrStep('scan', `${prBin} scan ${sq(wt)}`, ['SCAN_CLEAN']);

  // 3f-1. Push-by-SHA on the plan's branch. — see build-level.design-notes-5.md#3f-1-push-by-sha-on-the-plan-s-branch
  addPrStep('push', `${prBin} push ${sq(wt)} ${sq(item.branch)} --allow-rewrite`, ['PUSHED']);

  // 3f-2. Open the PR. The verification surface is read from the determini — see build-level.design-notes-5.md#3f-2-open-the-pr-the-verification-surface-is-read-from-the-d
  const verdictJson = JSON.stringify({
    status: 'done',
    // temperloop#1430: the §3e review outcome rides the PR body via `summary — see build-level.design-notes-5.md#temperloop-1430-the-3e-review-outcome-rides-the-pr-body-via-
    summary: neutralizeReviewBlockMark(verdict.summary ?? '') + reviewSummarySuffix,
    acceptance_results: verdict.acceptance_results ?? [],
    // temperloop#939: a recovered verdict carries a synthesized inline surfa — see build-level.design-notes-6.md#temperloop-939-a-recovered-verdict-carries-a-synthesize
    ...(verdict.verification_surface ? { verification_surface: verdict.verification_surface } : {}),
  });
  // Cross-repo `Closes` qualification (temperloop#852, build.md 3f "Cross- — see build-level.design-notes-5.md#cross-repo-closes-qualification-temperloop-852-build-md-3f-c
  const crossRepo = Boolean(item.repo && ownerRepo && item.repo !== ownerRepo);
  const qualifyIssueRef = (n) => (crossRepo ? `${ownerRepo}#${n}` : `${n}`);
  const ghIssueFlag = item.ghIssue ? ` --gh-issue ${sq(qualifyIssueRef(item.ghIssue))}` : '';
  const alsoClosesFlag = item.alsoCloses?.length
    ? ` --also-closes ${sq(item.alsoCloses.map(qualifyIssueRef).join(','))}`
    : '';
  // The surface-file flag is DROPPED on a recovery whose probe saw no — see build-level.design-notes-6.md#the-surface-file-flag-is-dropped-on-a-recovery-whose-probe-s
  const surfaceFlag =
    recovery && !recovery.surfacePresent
      ? ''
      : ` --verification-surface-file ${sq(`${wt}/.build-verification.md`)}`;
  const openCmd =
    `vf=$(mktemp) && printf %s ${sq(verdictJson)} > "$vf" && ` +
    `${prBin} open --repo ${sq(repoRoot)} --branch ${sq(item.branch)} ` +
    `--title ${sq(item.title)} --verdict "$vf"${ghIssueFlag}${alsoClosesFlag}${surfaceFlag} ` +
    `--plan-link ${sq(planLink)} --source ${sq(item.source ?? '')}; ` +
    `rc=$?; rm -f "$vf"; exit $rc`;
  addPrStep('pr-open', openCmd); // terminal step — nothing gates after it

  // 3f-2 FALLBACK: a PR-ready tree must not be stranded by a bad verdict — see build-level.design-notes-6.md#3f-2-fallback-a-pr-ready-tree-must-not-be-stranded-by-a-bad-
  const fallbackVerdictJson = JSON.stringify({
    status: 'done',
    summary:
      'The worker completed this item, but its verdict JSON did not survive the hand-off to `pr.sh open` ' +
      '(temperloop#1805). This body was assembled from the commit on the branch and the verification ' +
      'surface the worker wrote to disk; the per-criterion acceptance table is NOT reproduced here — ' +
      'read the verification surface below.' + reviewSummarySuffix,
    acceptance_results: [],
    ...(verdict.verification_surface ? { verification_surface: verdict.verification_surface } : {}),
  });
  const fallbackOpenCmd =
    `vf=$(mktemp) && printf %s ${sq(fallbackVerdictJson)} > "$vf" && ` +
    `${prBin} open --repo ${sq(repoRoot)} --branch ${sq(item.branch)} ` +
    `--title ${sq(item.title)} --verdict "$vf"${ghIssueFlag}${alsoClosesFlag}${surfaceFlag} ` +
    `--plan-link ${sq(planLink)} --source ${sq(item.source ?? '')}; ` +
    `rc=$?; rm -f "$vf"; exit $rc`;
  const fallbackHasSurface = Boolean(surfaceFlag) || Boolean(verdict.verification_surface);

  const prb = await runMachineryBatch(prSteps, {
    label: `pr-batch:${item.slug}`,
    slug: item.slug,
    bashTimeoutMs: BATCH_BASH_TIMEOUT_MS,
    phase: enterStage(STAGE_PR), // 3f rebase + scan + push + pr-open
  });
  if (prb.denied) {
    // temperloop#1819: quota death vs genuine denial — see deniedOrQuota.
    return await deniedOrQuota(item.slug, {
      step: batchDeniedStep(prb, 'pr-batch'),
      steps: prb.steps,
      out: prb.out,
    }, wt);
  }

  // temperloop#1071 — a pr-batch step that outlived the liveness ceiling. — see build-level.design-notes-6.md#temperloop-1071-a-pr-batch-step-that-outlived-the-liveness-c
  const prTimeout = timedOutStep(prb.results);
  let adopted = null;
  if (prTimeout) {
    const disp = await disposeStepTimeout(item, wt, prTimeout, 'pr-batch');
    if (disp.escalation) return disp.escalation;
    adopted = disp.adopt;
  }

  let pr;
  let pushedSha;
  if (adopted) {
    pr = adopted.pr;
    pushedSha = adopted.sha ?? null;
  } else {
    // 3f-0a branch — the rebase decision, unchanged, read off the batch.
    if (prAt.rebase !== undefined) {
      const rebaseOut = batchStep(prb, prAt.rebase);
      // DIRTY_WORKTREE is NOT a conflict (temperloop#735): git refused to star — see build-level.design-notes-6.md#dirty-worktree-is-not-a-conflict-temperloop-735-git-refused-
      if (rebaseOut.outcome === 'DIRTY_WORKTREE') {
        return escalate(item.slug, 'dirty-worktree', { rebaseOut });
      }
      if (rebaseOut.outcome === 'REBASE_CONFLICT') {
        return escalate(item.slug, 'rebase-conflict', { rebaseOut });
      }
      if (rebaseOut.outcome !== 'REBASED') {
        return escalate(item.slug, 'rebase-error', { rebaseOut });
      }
    }

    // 3f-0 branch — the closing-keyword scan decision, unchanged.
    const scanOut = batchStep(prb, prAt.scan);
    if (scanOut.outcome === 'SCAN_BLOCKED') {
      // A worker commit carries a closing keyword (the ec8d5fd class). Don't p — see build-level.design-notes-6.md#a-worker-commit-carries-a-closing-keyword-the-ec8d5fd-c
      return escalate(item.slug, 'closing-keyword', { scanOut });
    }
    if (scanOut.outcome !== 'SCAN_CLEAN') {
      return escalate(item.slug, 'scan-error', { scanOut });
    }

    // 3f-1 branch — the push decision. Before escalating a non-PUSHED, — see build-level.design-notes-6.md#3f-1-branch-the-push-decision-before-escalating-a-non-pushed
    const pushOut = batchStep(prb, prAt.push);
    if (pushOut.outcome === 'PUSH_REJECTED') {
      // Remote-branch collision / non-ff — orchestrator triages (force vs rename).
      return escalate(item.slug, 'push-rejected', { pushOut });
    }
    if (pushOut.outcome === 'PUSHED_UNWATCHED') {
      // temperloop#1688 — the push LANDED, on a ref no open PR references whil — see build-level.design-notes-6.md#temperloop-1688-the-push-landed-on-a-ref-no-open-pr-referenc
      return escalate(item.slug, 'push-unwatched-branch', { pushOut });
    }
    if (pushOut.outcome !== 'PUSHED') {
      const rec = isLostReturn(pushOut) ? await recoverLostReturn(item, wt, openCmd) : { kind: 'none' };
      if (rec.kind === 'adopted') {
        pr = rec.pr;
        pushedSha = rec.pushedSha;
      } else if (rec.kind === 'escalate') {
        return escalate(item.slug, rec.escKind, rec.payload);
      } else {
        return escalate(item.slug, 'push-error', { pushOut });
      }
    } else {
      pushedSha = pushOut.sha;
    }

    // 3f-2 branch — the PR-open decision. Skipped entirely when the push-bra — see build-level.design-notes-6.md#3f-2-branch-the-pr-open-decision-skipped-entirely-when-the-p
    if (pr == null) {
      let openOut = batchStep(prb, prAt['pr-open']);
      // temperloop#1805 — TOLERATE an unparseable verdict over a PR-ready tree — see build-level.design-notes-6.md#temperloop-1805-tolerate-an-unparseable-verdict-over-a-pr-re
      let verdictFallback = null;
      if (isVerdictUnparseable(openOut)) {
        if (!fallbackHasSurface) {
          log(
            `[${item.slug}] pr-open rejected the verdict (${openOut.error ?? '?'}) and there is NO verification ` +
            `surface to fall back on — escalating rather than opening a PR with an empty body (temperloop#1805).`,
          );
        } else {
          log(
            `[${item.slug}] pr-open rejected the verdict (${openOut.error ?? '?'}) — the tree is PR-READY, so this ` +
            `is a REPORTING failure, not a failed item (temperloop#1805). Re-opening with the commit's own title ` +
            `and .build-verification.md as the body, exactly as the manual recovery of #1803 did.`,
          );
          verdictFallback = await runMachinery(fallbackOpenCmd, {
            label: `pr-open-verdict-fallback:${item.slug}`,
            slug: item.slug,
            phase: stagePhase(STAGE_RECOVER),
          });
          if (verdictFallback.outcome === 'PR_OPENED' || verdictFallback.outcome === 'EXISTS') {
            log(
              `[${item.slug}] PR #${verdictFallback.pr_number} opened from the fallback body — the acceptance ` +
              `table is not reproduced on it (the verdict that carried it did not survive); the verification ` +
              `surface is (temperloop#1805).`,
            );
            openOut = verdictFallback;
          }
        }
      }
      if (openOut.outcome !== 'PR_OPENED' && openOut.outcome !== 'EXISTS') {
        const rec = isLostReturn(openOut) ? await recoverLostReturn(item, wt, openCmd) : { kind: 'none' };
        if (rec.kind === 'adopted') {
          pr = rec.pr;
          pushedSha = rec.pushedSha ?? pushedSha;
        } else if (rec.kind === 'escalate') {
          return escalate(item.slug, rec.escKind, rec.payload);
        } else if (isVerdictUnparseable(openOut)) {
          // temperloop#1805, the OBSERVABLE half. Even when the fallback cannot
          // land the PR, the escalation must let its reader tell "no work" from
          // "work done, reporting broke". A payload naming only the parse error
          // is what made a finished item look terminal — and on an unattended run
          // with no operator reading it, that is how landed-quality work gets
          // parked, pruned and redone. The three facts that settle it come from
          // the recover-probe, the same staged ladder every other disposal uses.
          const probe = await probeSideEffects(item, wt);
          return escalate(item.slug, 'verdict-unparseable', {
            openOut,
            fallbackOut: verdictFallback,
            committed_sha: pushedSha ?? probe.sha ?? null,
            dirty: probe.stage === 'RECOVER_DIRTY' || (probe.dirtyFiles ?? 0) > 0,
            verification_present: probe.surfacePresent === true || Boolean(surfaceFlag),
            probeStage: probe.stage ?? null,
            pushed: probe.pushed === true,
            reason:
              'the work is COMMITTED and the branch is pushed; only the worker verdict failed to parse, so ' +
              'pr.sh open refused to assemble a body. This is a reporting-layer failure, NOT a failed item — ' +
              'read committed_sha / dirty / verification_present before disposing of it.',
            remedy:
              'open the PR by hand from the committed branch with .build-verification.md as the body (the ' +
              'temperloop#1803 recovery), or re-drive ONLY the verdict — never rebuild the work.',
          });
        } else {
          return escalate(item.slug, 'pr-open-failed', {
            openOut,
            // The same three facts, best-effort and free (no extra probe): every — see build-level.design-notes-6.md#the-same-three-facts-best-effort-and-free-no-extra-prob
            committed_sha: pushedSha ?? null,
            verification_present: Boolean(surfaceFlag) || Boolean(verdict.verification_surface),
          });
        }
      } else {
        pr = openOut.pr_number;
      }
    }
  }

  // 3f→3g SHA hand-off guard (temperloop#2014) — see build-level.design-notes-6.md#3f-3g-sha-hand-off-guard-temperloop-2014
  if (hexSha(pushedSha) === null) {
    return escalate(
      item.slug,
      'ci-poll-bad-argument',
      badShaEscalation(
        pr,
        pushedSha,
        'push-to-poll-handoff',
        'push + PR-open reported success but produced no usable head SHA to pin the CI poll to',
      ),
    );
  }

  // --- 3g. CI poll (the bounded short-slice loop — DESIGN NOTE 2) ----------
  const ciResult = await ciPollLoop(item, ownerRepo, pr, pushedSha, wt);
  if (ciResult.escalation) {
    return escalate(item.slug, ciResult.escalation, { ...ciResult.payload, pr });
  }

  // --- 3g.5. Re-render §3e evidence after any CI-fix re-review (#1846) ------
  // The PR body was assembled at 3f from the ORIGINAL review round only, while
  // park()'s Step-6 tally merges every round — so a reviewer that ran only in
  // a CI-fix round (its diff includes the fix commit, which can touch file
  // classes the original diff never did) had real findings that reached ONLY
  // the tally: the body's "ran:" line affirmatively named a reviewer set that
  // omitted it, and its findings were invisible at the merge gate (issue
  // #1846 — body said "ran: docs-reviewer"; review.ran carried shell-reviewer
  // and its three findings). Rebuild the FULL body through pr.sh's own
  // assemble_body path (`open --update-pr` — never regex surgery on the live
  // body) with the suffix merged across every round. Skipped when the merged
  // suffix equals 3f's (no fix round, or fix rounds that routed no reviewer)
  // — the common path costs nothing. A failed update DEGRADES with a loud log
  // line rather than taking down a CI-green item: review is advisory (never a
  // `checks` gate), and the findings still ride the Step-6 tally below.
  const fixRounds = ciResult.fixReviewRounds ?? [];
  const mergedReviewSuffix = reviewBodySuffix([review, ...fixRounds]);
  if (mergedReviewSuffix !== reviewSummarySuffix) {
    const mergedVerdictJson = JSON.stringify({
      status: 'done',
      summary: neutralizeReviewBlockMark(verdict.summary ?? '') + mergedReviewSuffix,
      acceptance_results: verdict.acceptance_results ?? [],
      ...(verdict.verification_surface ? { verification_surface: verdict.verification_surface } : {}),
    });
    const updateCmd =
      `vf=$(mktemp) && printf %s ${sq(mergedVerdictJson)} > "$vf" && ` +
      `${prBin} open --repo ${sq(repoRoot)} --update-pr ${sq(String(pr))} --verdict "$vf"${ghIssueFlag}${alsoClosesFlag}${surfaceFlag} ` +
      `--plan-link ${sq(planLink)} --source ${sq(item.source ?? '')}; ` +
      `rc=$?; rm -f "$vf"; exit $rc`;
    const upd = await runMachinery(updateCmd, {
      label: `pr-body-update:${item.slug}`,
      slug: item.slug,
      phase: enterStage(STAGE_CI),
    });
    if (upd && upd.outcome === 'BODY_UPDATED') {
      log(`[${item.slug}] PR #${pr}: §3e evidence re-rendered across ${1 + fixRounds.length} review round(s) (temperloop#1846)`);
    } else {
      log(
        `[${item.slug}] PR #${pr}: §3e body re-render FAILED — the body's review line may omit CI-fix round ` +
          `reviewer(s)/findings; they still ride the Step-6 review tally (temperloop#1846): ${JSON.stringify(upd?.outcome ?? upd)}`,
      );
    }
  }

  // 3h. Park as [m] (the workflow returns the record; orchestrator writes) — see build-level.design-notes-6.md#3h-park-as-m-the-workflow-returns-the-record-orchestrat
  log(`[${item.slug}] parked — PR #${pr} ${ciResult.noCi ? 'no CI configured (skipped)' : 'CI green'}${recovery ? ' (RECOVERED — acceptance unverified)' : ''}`);
  // temperloop#1319: the named warning — mirrors the verification_surface
  // degraded-case wording (build.md §3f step 2) exactly, one line naming the
  // PR and every gap criterion, so it is visible in the run log AND (via the
  // parked.discrimination_gaps field above) tallied in the Step 6 summary —
  // never silently dropped.
  if (discGaps.length > 0) {
    log(
      `[${item.slug}] PR #${pr}: ${discGaps.length} acceptance criterion(s) passed with no discrimination evidence — ` +
      `the worker never proved these checks can fail (temperloop#1319): ${discGaps.map((c) => `"${c}"`).join(', ')}`,
    );
  }
  // temperloop#1182: the deferral warning — named and visible in the run log,
  // and (via the parked.host_config_deferrals field) carried to the merge gate
  // where the orchestrator MUST verify each one in the real checkout. Louder
  // wording than the #1319 line above on purpose: that one is advisory, this
  // one names work the orchestrator still owes before the item can merge.
  const hostDeferrals = hostConfigDeferrals(verdict.acceptance_results);
  if (hostDeferrals.length > 0) {
    log(
      `[${item.slug}] PR #${pr}: ${hostDeferrals.length} acceptance criterion(s) DEFERRED — host-config not visible ` +
      `from a worktree (temperloop#1182); VERIFY PARENT-SIDE before merge: ` +
      `${hostDeferrals.map((d) => `"${d.criterion}" (${d.host_config})`).join(', ')}`,
    );
  }
  // temperloop#1450 — merge the ORIGINAL 3e pass with any CI-fix re-review — see build-level.design-notes-6.md#temperloop-1450-merge-the-original-3e-pass-with-any-ci-fix-r
  const reviewSummary = reviewTally(review, ...(ciResult.fixReviewRounds ?? []));
  // temperloop#2065 — assemble the per-item cost ledger park() carries. Wa — see build-level.design-notes-6.md#temperloop-2065-assemble-the-per-item-cost-ledger-park-carri
  const cost = {
    tokens_in: mainCost.tokensIn,
    tokens_out: mainCost.tokensOut,
    wall_clock_ms:
      mainCost.wallClockMs == null && ciResult.retryWallClockMs == null
        ? null
        : (mainCost.wallClockMs ?? 0) + (ciResult.retryWallClockMs ?? 0),
    retry_tokens: ciResult.retryTokens ?? null,
    retry_count: ciResult.retryCount ?? 0,
    recovery: !!recovery,
  };
  return park(item.slug, pr, ciResult.finalSha ?? pushedSha, verdict.acceptance_results, ciResult.noCi === true, recovery, discGaps, reviewSummary, cost);
}

// ciPollLoop — bounded short-slice CI poll (DESIGN NOTE 2). — see build-level.design-notes-6.md#cipollloop-bounded-short-slice-ci-poll-design-note-2

// MERGE_CONFLICT_GLOBS — the substrings that make the batched merge-stat — see build-level.design-notes-6.md#merge-conflict-globs-the-substrings-that-make-the-batched-me
const MERGE_CONFLICT_GLOBS = ['"mergeable":"CONFLICTING"', '"mergeStateStatus":"DIRTY"'];

function mergeStateCmd(ownerRepo, pr) {
  // gh pr view returns JSON; if it fails (e.g. auth error) the executor ca — see build-level.design-notes-6.md#gh-pr-view-returns-json-if-it-fails-e-g-auth-error-the-execu
  return `gh pr view ${sq(pr)} --repo ${sq(ownerRepo)} --json mergeable,mergeStateStatus | tr -d ' \\n'`;
}

// The pushed-SHA hand-off guard (temperloop#2014). — see build-level.design-notes-6.md#the-pushed-sha-hand-off-guard-temperloop-2014
function hexSha(value) {
  return typeof value === 'string' && value !== '' && /^[0-9a-fA-F]+$/.test(value)
    ? value
    : null;
}

// badShaEscalation — the payload shared by both pre-flight sites (the 3f — see build-level.design-notes-6.md#badshaescalation-the-payload-shared-by-both-pre-flight-sites
function badShaEscalation(pr, seen, stage, detail) {
  return {
    pr,
    sha_seen: String(seen),
    stage,
    reason: detail,
    disposition:
      'NOT a CI verdict — the poll never ran. The PR itself is untouched and its checks ' +
      'may well be green: inspect it, and re-drive (or finish by hand) once the head SHA is known.',
  };
}

// isBadArgumentError — true iff a ci-poll.sh ERROR is the script REFUSIN — see build-level.design-notes-6.md#isbadargumenterror-true-iff-a-ci-poll-sh-error-is-the-script
function isBadArgumentError(out) {
  if (!out || out.outcome !== 'ERROR') return false;
  if (out.usage_error === true) return true;
  if (typeof out.error !== 'string') return false;
  return / invalid — must be /.test(out.error) || /^usage: ci-poll\.sh /.test(out.error);
}

function ciPollCmd(ownerRepo, pr, sha) {
  const ciBin = machineryBin(input.repoRoot, 'ci-poll.sh');
  // sha pins the head (REQUIRED on a re-poll after a force-push; harmless  — see build-level.design-notes-6.md#sha-pins-the-head-required-on-a-re-poll-after-a-force-p
  return (
    `${ciBin} ${sq(ownerRepo)} ${sq(pr)} --sha ${sq(sha)} ` +
    `--timeout ${sq(CI_POLL_SLICE_SECS)}`
  );
}

async function ciPollLoop(item, ownerRepo, pr, initialSha, wt) {
  let sha = initialSha;
  let retriesLeft = CI_FAIL_RETRY_BUDGET;
  // The runtime forbids Date.now(); we bound by SLICE COUNT instead of wal — see build-level.design-notes-6.md#the-runtime-forbids-date-now-we-bound-by-slice-count-in
  const maxSlices = Math.ceil(CI_POLL_TOTAL_SECS / CI_POLL_SLICE_SECS);

  // Buffered slices from the current ci-batch: one { mergeState, out } pai — see build-level.design-notes-6.md#buffered-slices-from-the-current-ci-batch-one-mergestat
  let buffer = [];
  let batchIdx = 0;
  // temperloop#1450 — one runReviewers() result per CI-fix commit re-revie — see build-level.design-notes-6.md#temperloop-1450-one-runreviewers-result-per-ci-fix-commit-re
  const fixReviewRounds = [];
  // temperloop#2065 — the CI_FAIL_RETRY_BUDGET loop's OWN cost tally, kept — see build-level.design-notes-6.md#temperloop-2065-the-ci-fail-retry-budget-loop-s-own-cost-tal
  let retryCount = 0;
  let retryTokens = null;
  let retryWallClockMs = null;

  for (let slice = 0; slice < maxSlices; slice++) {
    if (buffer.length === 0) {
      // One executor agent, CI_POLL_SLICES_PER_BATCH (merge-state, ci-poll) — see build-level.design-notes-6.md#one-executor-agent-ci-poll-slices-per-batch-merge-state
      const nSlices = Math.min(CI_POLL_SLICES_PER_BATCH, maxSlices - slice);
      const steps = [];
      for (let k = 0; k < nSlices; k++) {
        steps.push({
          kind: 'merge-state',
          cmd: mergeStateCmd(ownerRepo, pr),
          stopGlobs: MERGE_CONFLICT_GLOBS,
        });
        steps.push({
          kind: 'ci-poll',
          cmd: ciPollCmd(ownerRepo, pr, sha),
          continueOutcomes: ['TIMEOUT'], // only a still-pending slice polls again
        });
      }
      const batch = await runMachineryBatch(steps, {
        label: `ci-batch:${item.slug}#${batchIdx++}`,
        slug: item.slug,
        bashTimeoutMs: CI_BATCH_BASH_TIMEOUT_MS,
        phase: enterStage(STAGE_CI), // 3g merge-state probe + CI poll slices
      });
      if (batch.denied) {
        // temperloop#1819: quota death vs genuine denial — see deniedOrQuota.
        const esc = await deniedOrQuota(item.slug, {
          step: 'ci-batch',
          steps: batch.steps,
          out: batch.out,
          sha,
        }, wt);
        return { escalation: esc.escalation.kind, payload: esc.escalation.payload };
      }
      // temperloop#1071 — a ci-batch step that outlived the liveness ceiling. — see build-level.design-notes-6.md#temperloop-1071-a-ci-batch-step-that-outlived-the-liveness-c
      const ciTimeout = timedOutStep(batch.results);
      if (ciTimeout) {
        const disp = await disposeStepTimeout(item, wt, ciTimeout, 'ci-batch', { adoptable: false });
        return {
          escalation: 'machinery-step-timeout',
          payload: { ...disp.escalation.escalation.payload, sha },
        };
      }
      for (let k = 0; k < nSlices; k++) {
        const ms = batch.results[2 * k];
        const po = batch.results[2 * k + 1];
        if (ms === undefined && po === undefined) break; // short-circuited here
        buffer.push({ mergeState: ms ?? null, out: po });
      }
      if (buffer.length === 0) {
        // The executor came back with an empty results array — it ran nothing we — see build-level.design-notes-6.md#the-executor-came-back-with-an-empty-results-array-it-r
        return { escalation: 'ci-failed', payload: { reason: 'ci poll batch returned no results', sha } };
      }
    }

    const bufferedSlice = buffer.shift();
    const mergeState = bufferedSlice.mergeState;

    // CONFLICTING/DIRTY early-exit (#543) — see build-level.design-notes-6.md#conflicting-dirty-early-exit-543
    if (
      mergeState != null &&
      (mergeState.mergeable === 'CONFLICTING' || mergeState.mergeStateStatus === 'DIRTY')
    ) {
      log(`[${item.slug}] PR #${pr} is CONFLICTING/DIRTY — escalating merge-conflict (slice ${slice})`);
      return {
        escalation: 'merge-conflict',
        payload: { pr, mergeable: mergeState.mergeable, mergeStateStatus: mergeState.mergeStateStatus },
      };
    }

    // This slice's own ci-poll.sh object. Absent only if the batch truncated — see build-level.design-notes-6.md#this-slice-s-own-ci-poll-sh-object-absent-only-if-the-b
    const out =
      bufferedSlice.out ??
      { outcome: 'ERROR', error: 'ci-poll step produced no result in its batch' };

    if (out.outcome === 'CI_GREEN') {
      return { ok: true, finalSha: sha, fixReviewRounds, retryCount, retryTokens, retryWallClockMs };
    }

    if (out.outcome === 'NO_CI') {
      // temperloop#605/#618: ci-poll.sh's bounded grace window elapsed with — see build-level.design-notes-6.md#temperloop-605-618-ci-poll-sh-s-bounded-grace-window-elapsed
      log(`[${item.slug}] PR #${pr}: no CI configured on this SHA — skipping the CI gate (slice ${slice + 1})`);
      return { ok: true, finalSha: sha, noCi: true, fixReviewRounds, retryCount, retryTokens, retryWallClockMs };
    }

    if (out.outcome === 'TIMEOUT') {
      // Slice elapsed with checks still pending → poll the next slice. This is — see build-level.design-notes-6.md#slice-elapsed-with-checks-still-pending-poll-the-next-s
      log(`[${item.slug}] CI still pending after slice ${slice + 1}/${maxSlices}`);
      continue;
    }

    if (out.outcome === 'CI_FAILED') {
      if (retriesLeft <= 0) {
        return { escalation: 'ci-failed', payload: { ciOut: out, sha } };
      }
      retriesLeft--;
      retryCount++; // temperloop#2065 — counted at ATTEMPT time, not at success
      // Re-spawn the worker against the SAME worktree to fix CI, then — see build-level.design-notes-6.md#re-spawn-the-worker-against-the-same-worktree-to-fix-ci
      log(`[${item.slug}] CI failed — re-spawning worker (retries left ${retriesLeft})`);
      const cifixLabel = `worker-cifix:${item.slug}`;
      const cifixStartS = await safeWorkerClockNow(item, cifixLabel, enterStage(STAGE_CI));
      // temperloop#2065 review round 1 [HIGH]: agent({schema}) THROWS on a — see build-level.design-notes-6.md#temperloop-2065-review-round-1-high-agent-schema-throws-on-a
      let fixVerdict = null;
      let fixThrew = null;
      try {
        fixVerdict = await agent(
          workerPrompt(
            item,
            wt,
            '## CI failed\nThe pushed branch failed CI. First run ' +
              '`git fetch origin ' + item.branch + ' && git reset --hard FETCH_HEAD`, ' +
              'then fix the failure and commit (do NOT push). ' +
              'Failed run ids: ' + JSON.stringify(out.failed_run_ids ?? []) + '.',
          ),
          {
            label: cifixLabel,
            // A WORKER agent, but it belongs to the CI stage (temperloop#1294) — see build-level.design-notes-6.md#a-worker-agent-but-it-belongs-to-the-ci-stage-temperloo
            phase: enterStage(STAGE_CI),
            // Escalate-on-retry: a CI-failure re-spawn runs top tier (omit model).
            schema: WORKER_VERDICT_SCHEMA,
          },
        );
      } catch (err) {
        fixThrew = String((err && err.message) || err);
      }
      // temperloop#2065 — the retry's own cost, regardless of what fixVerdict — see build-level.design-notes-6.md#temperloop-2065-the-retry-s-own-cost-regardless-of-what-fixv
      {
        const cifixUsage = await safeWorkerUsageEmit(item, cifixLabel, 'build-worker', enterStage(STAGE_CI));
        const inT = cifixUsage.tokensIn ?? 0;
        const outT = cifixUsage.tokensOut ?? 0;
        retryTokens = (retryTokens ?? 0) + inT + outT;
        retryWallClockMs = (retryWallClockMs ?? 0) + (elapsedMs(cifixStartS, cifixUsage.epochS) ?? 0);
      }
      if (fixThrew != null) {
        // agent() threw — the same "no verdict" outcome as the bare-null — see build-level.design-notes-6.md#agent-threw-the-same-no-verdict-outcome-as-the-bare-nul
        return { escalation: 'ci-failed', payload: { reason: `ci-fix agent threw: ${fixThrew}`, retryable: true, sha } };
      }
      if (fixVerdict == null) {
        // agent() returned null — user skip or terminal API error in the CI-fix — see build-level.design-notes-6.md#agent-returned-null-user-skip-or-terminal-api-error-in-
        return { escalation: 'ci-failed', payload: { reason: 'ci-fix agent returned null', retryable: true, sha } };
      }
      if (fixVerdict.status !== 'done') {
        return { escalation: 'ci-failed', payload: { fixVerdict, sha } };
      }
      // temperloop#1450 — re-run §3e against the CI-fix DIFF before pushing it.
      // The fix worker can touch anything (including the very command doc
      // whose edit tripped the original lint failure): without this, a
      // CI-fix commit ships to the open PR with NO second pass through the
      // mandatory claude/commands/*.md -> workflow-reviewer rule
      // (foundation#1007) — the exact structurally-guaranteed-skip class this
      // item exists to close, just relocated one stage later than 3f. Reuses
      // the SAME runReviewers() the original 3e pass used; its own diff fetch
      // re-reads the worktree, whose HEAD now includes the fix commit, so the
      // diff naturally covers the fix on top of the original push.
      // No third argument, deliberately (temperloop#2127 round 2): the round-1
      // pass that got this item pushed had ZERO blocking findings, so there is
      // no prior-findings text to carry — and passing none is what selects
      // reviewContinuationSection()'s truthful clean-prior-round premise. This
      // call site bumps the SHARED §3e round counter, so it is the single most
      // frequent producer of a `round > 1` continuation whose prior round was
      // clean; the old `round > 1` premise asserted the opposite on every one
      // of them.
      const fixReview = await runReviewers(item, wt);
      if (fixReview.escalation) {
        const esc = fixReview.escalation.escalation;
        return { escalation: esc.kind, payload: { ...esc.payload, sha } };
      }
      if (fixReview.blocking.length > 0) {
        // temperloop#1970 — the SAME convergence bound the 3e pass applies, via — see build-level.design-notes-6.md#temperloop-1970-the-same-convergence-bound-the-3e-pass-appli
        if (!reviewBoundReached(fixReview)) {
          log(`[${item.slug}] §3e review on the CI-fix commit found a BLOCKING finding — escalating before push`);
          return {
            escalation: 'review-blocking',
            payload: {
              findings: fixReview.blocking,
              stage: 'ci-fix',
              sha,
              round: fixReview.round,
              max_rounds: REVIEW_BLOCKING_MAX_ROUNDS,
            },
          };
        }
        fixReview.residualBlocking = true;
        log(
          `[${item.slug}] §3e review on the CI-fix commit: round ${fixReview.round}/${REVIEW_BLOCKING_MAX_ROUNDS} ` +
            `still has ${fixReview.blocking.length} BLOCKING finding(s) — convergence bound reached ` +
            `(temperloop#1970): pushing the fix with them carried in ## Review notes instead of escalating again`,
        );
      }
      fixReviewRounds.push(fixReview);
      // Push the fixed SHA and pin the re-poll to it. This is a plain push — n — see build-level.design-notes-6.md#push-the-fixed-sha-and-pin-the-re-poll-to-it-this-is-a-plain
      const prBin = machineryBin(input.repoRoot, 'pr.sh');
      const fpush = await runMachinery(
        `${prBin} push ${sq(wt)} ${sq(item.branch)}`,
        { label: `push-retry:${item.slug}`, slug: item.slug, phase: enterStage(STAGE_CI) },
      );
      if (machineryDenied(fpush)) {
        // temperloop#1819: quota death vs genuine denial — see deniedOrQuota.
        const esc = await deniedOrQuota(item.slug, { step: 'push-retry', out: fpush, sha }, wt);
        return { escalation: esc.escalation.kind, payload: esc.escalation.payload };
      }
      // temperloop#1071 — the force-push outlived the liveness ceiling. It is — see build-level.design-notes-6.md#temperloop-1071-the-force-push-outlived-the-liveness-ceiling
      if (fpush.outcome === 'STEP_TIMEOUT') {
        const disp = await disposeStepTimeout(item, wt, fpush, 'push-retry', { adoptable: false });
        return {
          escalation: 'machinery-step-timeout',
          payload: { ...disp.escalation.escalation.payload, sha },
        };
      }
      if (fpush.outcome !== 'PUSHED') {
        return { escalation: 'ci-failed', payload: { fpush, sha } };
      }
      // temperloop#2014 — the FIFTH `--sha` assignment, and the one the issue' — see build-level.design-notes-6.md#temperloop-2014-the-fifth-sha-assignment-and-the-one-the-iss
      if (hexSha(fpush.sha) === null) {
        return {
          escalation: 'ci-poll-bad-argument',
          payload: badShaEscalation(
            pr,
            fpush.sha,
            'ci-fix-push',
            'the CI-fix re-push reported PUSHED but produced no usable head SHA to re-pin the poll to',
          ),
        };
      }
      sha = fpush.sha; // authoritative — pin the next poll to it (NOT the PR API)
      // FLUSH any slices still buffered from the pre-fix batch: they were poll — see build-level.design-notes-6.md#flush-any-slices-still-buffered-from-the-pre-fix-batch-
      buffer = [];
      continue;
    }

    // ERROR or any unexpected outcome (e.g. ci-poll.sh itself errored) → — see build-level.design-notes-6.md#error-or-any-unexpected-outcome-e-g-ci-poll-sh-itself-errore
    if (isBadArgumentError(out)) {
      return {
        escalation: 'ci-poll-bad-argument',
        payload: { ...badShaEscalation(pr, sha, 'ci-poll', 'ci-poll.sh rejected its own arguments'), ciOut: out },
      };
    }
    return { escalation: 'ci-failed', payload: { ciOut: out, sha } };
  }

  // Total budget exhausted without CI_GREEN/CI_FAILED resolution.
  return { escalation: 'ci-failed', payload: { reason: 'ci-poll budget exhausted', sha } };
}

// ====================================================================== — see build-level.design-notes-6.md#note-2
const PHASE_TITLE_MAX_ITEMS = 3;

// The level's stages, in the order an item passes through them. STAGE_RECOVER is
// deliberately NOT in STAGE_ORDER: the recovery probes (pr.sh recover-probe, the
// lost-return resume batch) are off-path diagnostics that can fire from any
// stage, so they get their own progress group but must never move the global
// cursor — otherwise a single item's recovery would drag the whole level's
// collapsed row backwards.
const STAGE_CLAIM = 'claim';
const STAGE_BUILD = 'build';
const STAGE_REVIEW = 'review';
const STAGE_GATE = 'gate';
const STAGE_PR = 'PR';
const STAGE_CI = 'CI';
const STAGE_RECOVER = 'recover';
const STAGE_ORDER = [STAGE_CLAIM, STAGE_BUILD, STAGE_REVIEW, STAGE_GATE, STAGE_PR, STAGE_CI];

// The items whose slugs/issues every stage heading names — the ACTIVE su — see build-level.design-notes-6.md#the-items-whose-slugs-issues-every-stage-heading-names-
let phaseItems = [];
// Index into STAGE_ORDER of the furthest stage any item has reached this run.
let stageReached = -1;

// itemTag — `<slug> (#<issue>)`, or the bare slug when the item has no i — see build-level.design-notes-6.md#itemtag-slug-issue-or-the-bare-slug-when-the-item-has-n
function itemTag(item) {
  const slug = (item && item.slug) || '(unnamed)';
  const issue = item && item.ghIssue;
  return issue ? `${slug} (#${issue})` : slug;
}

// levelPhaseTitle(list, stage) — the heading itself. `stage` is optional — see build-level.design-notes-6.md#levelphasetitle-list-stage-the-heading-itself-stage-is-
function levelPhaseTitle(list, stage) {
  const items = Array.isArray(list) ? list : [];
  const parts = [];
  if (typeof input.ownerRepo === 'string' && input.ownerRepo.length > 0) {
    parts.push(input.ownerRepo);
  }
  parts.push(`${items.length} item${items.length === 1 ? '' : 's'}`);
  const named = items.slice(0, PHASE_TITLE_MAX_ITEMS).map(itemTag);
  if (named.length > 0) {
    const rest = items.length - named.length;
    parts.push(named.join(', ') + (rest > 0 ? ` +${rest} more` : ''));
  }
  const head = stage ? `build level · ${stage}` : 'build level';
  return `${head} — ${parts.join(' · ')}`;
}

// stagePhase(stage) — the group name for `stage`, WITHOUT touching the g — see build-level.design-notes-6.md#stagephase-stage-the-group-name-for-stage-without-touch
function stagePhase(stage) {
  return levelPhaseTitle(phaseItems, stage);
}

// enterStage(stage) — returns the group name for `stage` (hand it straig — see build-level.design-notes-6.md#enterstage-stage-returns-the-group-name-for-stage-hand-it-st
function enterStage(stage) {
  const title = stagePhase(stage);
  const i = STAGE_ORDER.indexOf(stage);
  if (i > stageReached) {
    stageReached = i;
    phase(title);
  }
  return title;
}

// ====================================================================== — see build-level.design-notes-6.md#note-3
function zeroDispositionContradiction(activeItems, parked, escalations) {
  if (activeItems.length === 0) return null;                    // control 1
  if (parked.length > 0 || escalations.length > 0) return null; // control 2

  const ownerRepo = typeof input.ownerRepo === 'string' && input.ownerRepo.length > 0
    ? input.ownerRepo
    : null;
  const items = activeItems.map((it) => {
    const worktree = `${input.repoRoot}.wt/${it.slug}`;
    const headRef = it.branch ?? `build/${it.slug}`;
    const probes = [];
    if (ownerRepo && it.ghIssue) {
      probes.push(`gh issue view ${it.ghIssue} -R ${ownerRepo} --json state,labels,title`);
    }
    if (ownerRepo) {
      probes.push(`gh pr list -R ${ownerRepo} --head ${headRef} --state all --json number,state,headRefOid`);
    }
    probes.push(`git -C ${worktree} status --short --branch`);
    return {
      slug: it.slug,
      issue: it.ghIssue ?? null,
      branch: it.branch ?? null,
      worktree,
      // The caller acts on THIS: exactly what to look at before concluding — see build-level.design-notes-6.md#the-caller-acts-on-this-exactly-what-to-look-at-before-
      reprobe: probes.join(' ; '),
    };
  });

  return {
    // Which slugs were asked for and disposed of none — the whole point.
    slugs: items.map((i) => i.slug),
    items,
    requested: activeItems.length,
    parked: 0,
    escalations: 0,
    // True when this was a continuation run (onlySlugs scoped the set) — the — see build-level.design-notes-6.md#true-when-this-was-a-continuation-run-onlyslugs-scoped-
    continuation: Array.isArray(input.onlySlugs) && input.onlySlugs.length > 0,
    reason:
      `the level was asked to drive ${activeItems.length} item(s) and disposed of NONE — ` +
      'zero parked and zero escalations. This is a contradiction, not a completed level: ' +
      'nothing may be concluded from this return. Re-probe issue status, open PRs and the ' +
      'worktree for each slug below before deciding anything.',
  };
}

// ====================================================================== — see build-level.design-notes-6.md#note-4
const ITEM_KEY_ALIASES = {
  gh_issue: 'ghIssue',
  also_closes: 'alsoCloses',
  'depends-on': 'dependsOn',
  depends_on: 'dependsOn',
  parent_epic: 'parentEpic',
  parent_summary: 'parentSummary',
};
// Every key this file actually READS off an item. This list is not a — see build-level.design-notes-6.md#every-key-this-file-actually-reads-off-an-item-this-list-is-
const ITEM_KEYS_READ = [
  'slug', 'branch', 'title', 'kind', 'ghIssue', 'alsoCloses', 'repo', 'model',
  'acceptance', 'source', 'scope', 'notes', 'dependsOn', 'activation',
  'parentEpic', 'parentSummary', 'review',
];
// Documented plan-schema (and orchestrator bookkeeping) fields this file — see build-level.design-notes-6.md#documented-plan-schema-and-orchestrator-bookkeeping-fie
const ITEM_KEYS_IGNORED = [
  'after', 'epic', 'gate_check', 'gateCheck', 'size', 'files', 'seq',
  'status', 'pr', 'pushed_sha', 'pushedSha', 'no_ci', 'noCi', 'arm', 'id',
];
function normalizeItem(raw) {
  if (raw == null || typeof raw !== 'object') return raw;
  const item = { ...raw };
  const known = new Set([...ITEM_KEYS_READ, ...ITEM_KEYS_IGNORED, ...Object.keys(ITEM_KEY_ALIASES)]);
  const unknown = [];
  for (const key of Object.keys(raw)) {
    const canonical = ITEM_KEY_ALIASES[key];
    if (canonical) {
      // The camelCase spelling WINS when both are present — it is what this fi — see build-level.design-notes-6.md#the-camelcase-spelling-wins-when-both-are-present-it-is
      if (item[canonical] === undefined) {
        item[canonical] = raw[key];
        log(
          `[${raw.slug ?? '?'}] item key '${key}' accepted as '${canonical}' (temperloop#1700) — ` +
          `the documented plan-schema spelling; it used to be read by nothing and dropped in silence.`,
        );
      } else if (JSON.stringify(item[canonical]) !== JSON.stringify(raw[key])) {
        log(
          `[${raw.slug ?? '?'}] item carries BOTH '${key}' and '${canonical}' with DIFFERENT values ` +
          `(temperloop#1700) — using '${canonical}'; drop one in the caller.`,
        );
      }
      continue;
    }
    if (!known.has(key)) unknown.push(key);
  }
  if (unknown.length > 0) {
    // The generalization of the fix: a key nothing reads is named, once, rat — see build-level.design-notes-6.md#the-generalization-of-the-fix-a-key-nothing-reads-is-na
    log(
      `[${raw.slug ?? '?'}] item carries key(s) this workflow does not read: ${unknown.join(', ')} ` +
      `(temperloop#1700). If one of them is meant to drive behaviour, it is being IGNORED.`,
    );
  }
  return item;
}

// ====================================================================== — see build-level.design-notes-6.md#note-5
async function buildLevel() {
  // temperloop#1700 — normalize the DOCUMENTED plan-schema spellings into — see build-level.design-notes-6.md#temperloop-1700-normalize-the-documented-plan-schema-spellin
  const items = (input.items ?? []).map(normalizeItem);
  log(`repoRoot=${input.repoRoot} board=${input.board ?? 'OFF'} plan=${input.planLink}`);

  // onlySlugs — optional continuation filter (escalation-resume loop). — see build-level.design-notes-6.md#onlyslugs-optional-continuation-filter-escalation-resume-loo
  const slugFilter = Array.isArray(input.onlySlugs) && input.onlySlugs.length > 0
    ? new Set(input.onlySlugs)
    : null;
  const activeItems = slugFilter
    ? items.filter((item) => slugFilter.has(item.slug))
    : items;
  if (slugFilter) {
    log(`continuation mode — onlySlugs=[${[...slugFilter].join(',')}] active=${activeItems.length}/${items.length}`);
  }

  // Name the run in the progress row (temperloop#903). Set AFTER the onlyS — see build-level.design-notes-6.md#name-the-run-in-the-progress-row-temperloop-903-set-after-th
  phaseItems = activeItems;
  stageReached = -1;
  enterStage(STAGE_CLAIM);

  // Drive every active item through 3a–3h. The items in one level are — see build-level.design-notes-4.md#drive-every-active-item-through-3a-3h-the-items-in-one-level
  let dualSummary = null;
  let results;
  const dual = dualBuildInput();
  if (dual && dual.invalid) {
    // REFUSE, never degrade. A level asked to compare two models that quietl — see build-level.design-notes-6.md#refuse-never-degrade-a-level-asked-to-compare-two-model
    log(`dual-build INPUT INVALID — refusing the level: ${dual.invalid}`);
    results = activeItems.map((item) =>
      escalate(item.slug, 'dual-build-input-invalid', {
        reason: dual.invalid,
        received: input.dualBuild,
        remedy: 'pass dualBuild as { tier, baseline, candidate, inScope: [slug…] } (build.md Step 0/1 builds it from --dual-build via dual-build-preflight.sh), or drop the input entirely to build single-arm',
      }),
    );
  } else if (dual) {
    const driven = await driveLevelDualBuild(activeItems, dual);
    results = driven.results;
    dualSummary = driven.summary;
  } else {
  results = await parallel(
    activeItems.map((item) => () =>
      driveItem(item).catch((err) => {
        // temperloop#1819: a throw whose message carries the harness's — see build-level.design-notes-6.md#temperloop-1819-a-throw-whose-message-carries-the-harne
        const msg = String((err && err.message) || err);
        if (quotaDeath(msg)) {
          return quotaEscalation(item.slug, 'mid-item throw', {
            errorText: msg,
            worktree: `${input.repoRoot}.wt/${item.slug}`,
          });
        }
        return escalate(item.slug, 'worker-error', { error: String((err && err.stack) || err) });
      }).then((r) => preserveOnEscalation(item, r)).then((r) => stampSideline(item, r)),
    ),
  );
  }

  // Partition the per-item results into the small return object. NEVER wri — see build-level.design-notes-6.md#partition-the-per-item-results-into-the-small-return-ob
  const parked = [];
  const escalations = [];
  for (const r of results) {
    if (!r) continue;
    if (r._kind === 'parked') parked.push(r.parked);
    else if (r._kind === 'escalation') escalations.push(r.escalation);
  }

  // temperloop#2006 — the LEVEL-SUMMARY half of the sideline notice. Each — see build-level.design-notes-6.md#temperloop-2006-the-level-summary-half-of-the-sideline-notic
  const sidelined = [];
  for (const it of activeItems) {
    const plain = SIDELINE_NOTICES.get(it.slug);
    if (plain) sidelined.push({ slug: it.slug, ...plain });
    for (const armName of DUAL_BUILD_ARMS) {
      const armNotice = SIDELINE_NOTICES.get(`${it.slug}@${armName}`);
      if (armNotice) sidelined.push({ slug: it.slug, arm: armName, ...armNotice });
    }
  }
  if (sidelined.length > 0) {
    log(
      `level SIDELINED BUILD summary — ${sidelined.length} resumable build(s) shelved by worktree.sh create: ` +
        sidelined.map((s) => `${s.slug} → ${s.path}${s.branch ? ` (${s.branch})` : ''}`).join('; '),
    );
  }

  // temperloop#2004 — the ZERO-DISPOSITION guard, evaluated on the SETTLED — see build-level.design-notes-6.md#temperloop-2004-the-zero-disposition-guard-evaluated-on
  const zeroDisposition = zeroDispositionContradiction(activeItems, parked, escalations);
  if (zeroDisposition) {
    log(
      `level ZERO-DISPOSITION contradiction — ${zeroDisposition.requested} item(s) driven, ` +
        `0 parked, 0 escalations: ${zeroDisposition.slugs.join(', ')}. ` +
        'NOT a completed level — re-probe before concluding anything. ' +
        zeroDisposition.items.map((i) => `${i.slug} → ${i.reprobe}`).join(' || '),
    );
  }

  log(
    `level done — parked=${parked.length} escalations=${escalations.length}` +
      (sidelined.length > 0 ? ` sidelined=${sidelined.length}` : '') +
      (zeroDisposition ? ' ZERO-DISPOSITION (contradiction — see notice above)' : ''),
  );
  // Both extra keys are OMITTED when their condition does not hold, so an — see build-level.design-notes-6.md#both-extra-keys-are-omitted-when-their-condition-does-n
  const ret = { parked, escalations };
  if (sidelined.length > 0) ret.sidelined = sidelined;
  if (zeroDisposition) ret.zeroDisposition = zeroDisposition;
  // temperloop#2080 — the level's dual-build summary: which items were compared,
  // where the barrier stands, how many ledger rows landed, and the board writes
  // held back for the pick. Present ONLY on a dual-build run (same
  // omitted-unless-it-holds shape as `sidelined`/`zeroDisposition` above), so a
  // flag-less level's returned object is byte-identical to before this item.
  if (dualSummary) ret.dualBuild = dualSummary;
  return ret;
}

// Top-level entry (#437): the Workflow runtime wraps this script body in — see build-level.design-notes-6.md#top-level-entry-437-the-workflow-runtime-wraps-this-script-b
return await buildLevel();
