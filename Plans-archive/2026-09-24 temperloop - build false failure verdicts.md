---
tags: [plan, project/temperloop]
date: 2026-09-24
source_kind: claude-stamped
source_session: 25baf8ba
last_verified: 2026-09-24
sources:
  - "#2254"
epic: 2254
status: done
---

# temperloop - build false failure verdicts

## Run status

run started 2026-09-25T04:44:22Z · session 25baf8ba · level 1/1 active · items: 0 done / 0 parked / 0 in-flight / 0 skipped · path: conversational (--no-workflow; plan home repo temperloop, driven from the foundation checkout)

## Problem

Three verdict paths in the build engine turn a healthy run, or a machinery shape they do not handle, into a reported failure — or into no verdict at all. A green PR was escalated as `ci-failed` because the CI poll returned `ERROR` and the engine flattened "we never heard back" onto "CI said no". A merging PR on a slow-CI repo reports `TIMEOUT` by construction because one kernel-wide queue budget is smaller than that repo's round-trip. And the engine's own test suite hung for eleven hours on a stdin-reading `cat`, giving an unattended run nothing to report. Each was caught by an operator re-probing by hand; an unattended driver that trusted the verdict would have parked a mergeable PR, opened a duplicate, or waited forever.

## Summary

- **Stop reporting an unknown CI state as a CI failure.**
  - **L0** — Map a ci-poll `ERROR` to its own `ci-unknown` escalation with re-poll as the documented disposition, distinguishable from `ci-failed` by kind alone. (#2249)
- **Stop timing out a PR that is merging normally.**
  - **L0** — Raise the kernel-wide `BUILD_QUEUE_TIMEOUT` from 30 to 60 minutes so it exceeds the slowest healthy merge-queue round trip (foundation on hosted runners, ~42 min), state the sizing rule beside the setting, and pin the poll's `reason` stamp with a test. (#2055)
- **Guarantee the engine's own suite always yields a verdict.**
  - **L0** — Find and fix the stdin-reading `cat` at source, redirect the suite's own subprocess stdin, and make a direct (unwrapped) invocation self-bound. (#2245)

Build order: L0 first → L0 last; items in the same level ship together.

## Sequencing notes

- One level, no edges. Two items touch `workflows/scripts/build/tests/test_workflow.sh`, so their edit regions are pinned apart rather than assumed disjoint: `ci-poll-error-is-unknown` adds cases **beside the existing #2014 `ciPollLoop` classification block** (around line 12653 on `origin/main`) and nothing else in that file; `test-workflow-stdin-bound` edits only the suite's **preamble** (the self-bound re-exec and the stdin redirect, near the existing `bounded-suite.sh` comment at line 197) and the one offending `cat` call site, and puts its new test case in `test_bounded_suite.sh`, not in `test_workflow.sh`. `build.config.sh`, the setting registry and `test_gate.sh` belong to `queue-poll-awaiting-checks` alone.
- **Why a bigger clock, not a smarter poll (resolved at the approval gate, 2026-09-24).** The poll already stamps `reason` (`QUEUED` | `QUEUE_STALLED` | …) onto a deadline `TIMEOUT` (`gate.sh:550-565`, #1178), so the two states are distinguishable today; the only thing wrong is that the budget is smaller than a healthy hosted-runner round trip on foundation (21 min `checks` × 2 ≈ 42 min against 1800 s). The operator's call: a timeout is a sufficient verdict as long as it exceeds the slowest healthy round trip, so raise the one kernel-wide value to 3600 s and leave every caller (`fix.md:371`, `build.md` 4b, `cmd_managed_merge`'s 600 s confirm poll) untouched. Trade accepted: a genuinely stuck PR is reported 30 min later than today. Only two sites carry the literal (`build.config.sh:131`, `setting-registry.tsv:214`); the six other `1800` settings in the config are unrelated and stay. See [[Decisions/temperloop - queue timeout sized to the slowest healthy round trip]].
- **Escalation kinds have no enum.** `build-level.mjs`'s `SPINE_OUTCOME_SCHEMA` enum (and the #2205 lockstep guard over it) governs machinery-step *outcomes* (`CI_GREEN`, `ERROR`, …), not escalation *kinds* (`ci-failed`, kebab-case, free strings passed to `escalate()`); the only kind-aware code is `escalationRoundKind()`, which already classifies any `ci-*` kind as round-kind `ci`. So `ci-unknown` needs a new test case and a prose-list entry in `build.md`, and must not be added to the outcome enum.
- **Premise correction on #2245.** A wall-clock bound already exists for the suite's *wrapped* invocations: `workflows/scripts/build/bounded-suite.sh` (temperloop#2184) wraps `test_workflow.sh` in both `make test-build-workflow` and the `scripts/quality-gates.sh` slice, terminates a hang at the bound, and names the running case. The 11-hour hang was a *direct* invocation from an unattended mutation-test run, outside the wrapper. The item therefore owns the source fix and the direct-invocation gap, and does not rebuild the bound.
- **Cross-lane report, not a plan item.** #2245 names a sibling `test_workflow.sh` process that had been running 4 d 20 h in `~/dev/batch2/temperloop` — outside this session's lane. Dispose it by hand (`pkill -f batch2/temperloop/workflows/scripts/build/tests/test_workflow.sh` after confirming with `ps`), never from a worker.
- **Adjacent epics, deliberately not merged here:** #1779 (silent-pass guards — the mirror class), #2238 (gate-budget defects, incl. #2228's false GATE_TIMEOUT root cause), #2239 (orchestration boundary drops state), and the singleton #2210 (no armed wake source, In Progress under another session).

## Re-triage signals

- *Resolved at the approval gate (2026-09-24):* #2055's `needs-clarification` asked which of three directions to take (per-repo budget, derived budget, or progress-bounded callers). The operator chose a fourth, simpler one — raise the single kernel-wide `BUILD_QUEUE_TIMEOUT` to 3600 s — on the reasoning that a timeout is a sufficient verdict once it exceeds the slowest healthy round trip. Folded into the item; label cleared.
- none

## Items

- [x] **Map a ci-poll ERROR to a `ci-unknown` escalation, never `ci-failed`** `slug: ci-poll-error-is-unknown` — "we never heard back from CI" gets its own kind and its own disposition
  - branch: `fix/ci-poll-error-is-unknown`
  - size: S
  - model: opus
  - source: #2249
  - gh_issue: 2249
  - files: `claude/workflows/build-level.mjs`, `workflows/scripts/build/tests/test_workflow.sh`, `claude/commands/build.md`, `changelog.d/`
  - acceptance:
    - a `ci-poll` step returning `outcome: ERROR` (and the "batch returned no results" arm at `build-level.mjs:7500`) produces an escalation of kind `ci-unknown` whose payload carries **facts only** — the original `ciOut`, `sha`, and the poll's own state — never a `disposition` field (dispositions are owned by `build.md`'s kind list, as for every existing kind); it never produces kind `ci-failed`
    - a genuine `outcome: CI_FAILED` still produces `ci-failed`; a new `test_workflow.sh` node case, placed beside the existing #2014 `ciPollLoop` classification cases and built the same way, asserts both arms map to distinguishable kinds
    - the `ci-unknown` escalation's `claim_disposition` reads `hold` (its disposition is a resume, so worktree and board claim are kept — decided by `escalationResumableState()` off the `committed_work` record, never off the kind name), asserted in the same case; `escalationRoundKind('ci-unknown')` still resolves to round-kind `ci` via the existing `ci-*` prefix rule
    - `claude/commands/build.md`'s escalation-kind list (the prose list at its `ci-failed` entry) documents `ci-unknown` beside `ci-failed`, each with its disposition (`ci-failed`: fix the failure; `ci-unknown`: re-poll — CI state is unknown), and a `changelog.d/` fragment is present because `claude/commands/*.md` is contract surface (additive, not BREAKING)
  - activation:
    - class: A
    - proof: "grep -q \"'ci-unknown'\" claude/workflows/build-level.mjs && grep -q 'ci-unknown' claude/commands/build.md"
  - notes: A new *kind* is the right shape, not a payload flag on `ci-failed`: #2014 added the separate kind `ci-poll-bad-argument` for the sibling case, and `build-level.design-notes-6.md:471-472` fixes `ci-failed` as "this PR's CI is red". Every driver has a catch-all for non-enumerated kinds (`build.md:582,624`, `sweep.md:270`, `fix.md:257,279`), so only `build.md`'s list learns it. Adjacent to #1778 but the inverse — the two states are already distinct in `ci-poll.sh`'s vocabulary and the mapping discards the distinction. Distinct from the closed #2014 (undefined SHA).
  - pr: 2263
  - Run-status: run started 2026-09-25T04:45Z · session 25baf8ba · level 1/1 merging · items: 1 done / 2 parked / 0 in-flight / 0 skipped · path: conversational (--no-workflow)

- [x] **Raise `BUILD_QUEUE_TIMEOUT` to 3600 s and pin the poll's reason stamp** `slug: queue-poll-awaiting-checks` — the merge-queue budget exceeds the slowest healthy round trip, so a healthy PR on a slow-CI repo never reads TIMEOUT
  - branch: `fix/queue-poll-awaiting-checks`
  - size: S
  - model: opus
  - source: #2055
  - gh_issue: 2055
  - files: `workflows/scripts/build/build.config.sh`, `workflows/scripts/config/setting-registry.tsv`, `workflows/scripts/build/tests/test_gate.sh`, `changelog.d/`
  - acceptance:
    - `BUILD_QUEUE_TIMEOUT`'s default is 3600 in `build.config.sh` and in its `setting-registry.tsv` row, and both `check-setting-registry.sh` and `check-setting-prose.sh` are green; no other `1800` setting in the config is touched
    - the setting's comment block states the sizing rule — the value must exceed twice the slowest healthy `checks` run across the repos that vendor this kernel (foundation on hosted runners: 21 min per run, 2026-09-15) — and the accepted trade (a genuine stall is reported up to 60 min after enqueue)
    - a `test_gate.sh` fixture pins the existing #1178 behaviour the operator's verdict relies on: a deadline `TIMEOUT` carries `reason: "QUEUED"` and the full `diagnosis` when `cmd_diagnose_queue` reads `QUEUED`, and `reason: "QUEUE_STALLED"` on a zero-progress stall — so a future change cannot silently drop the stamp that makes the clock a sufficient verdict
    - `gate.sh poll`'s outcome set, exit codes and `--timeout` flag semantics are byte-identical; `cmd_managed_merge`'s confirm poll (`GATE_MERGE_POLL_TIMEOUT`) is untouched; a `changelog.d/` fragment records the default change (a tracked-repo setting is contract surface; additive, not BREAKING)
  - activation:
    - class: A
    - proof: "grep -q 'BUILD_QUEUE_TIMEOUT:=3600' workflows/scripts/build/build.config.sh"
  - notes: Direction chosen at the approval gate (Re-triage signals): the clock, not the callers. `foundation#1908` (2026-09-15) is the reproduction — `checks` 21m14s, `mergeStateStatus: CLEAN`, `TIMEOUT` with `reason: QUEUED` at 1803 s. [[Plans/2026-08-08 temperloop - merge gate recoverable states]] gave `poll` its `diagnosis` payload (temperloop#1178); this item pins it, never adds a second probe.
  - pr: 2264

- [x] **Fix the stdin-reading `cat` in `test_workflow.sh` and make a direct invocation self-bound** `slug: test-workflow-stdin-bound` — the engine's suite can no longer block on stdin or run unbounded outside the wrapper
  - branch: `fix/test-workflow-stdin-bound`
  - size: M
  - source: #2245
  - gh_issue: 2245
  - files: `workflows/scripts/build/tests/test_workflow.sh`, `workflows/scripts/build/tests/test_bounded_suite.sh`
  - acceptance:
    - the specific call site that degrades to a stdin read (a `cat "$var"` with an empty variable, or a subprocess inheriting the suite's stdin) is identified in the PR body with the evidence, and fixed at source — given an explicit input, not only papered over by a caller redirect
    - the suite redirects its own subprocess stdin from `/dev/null` (or equivalent) so a future call site that forgets an input cannot re-arm the hang
    - a test case in `test_bounded_suite.sh` runs the suite (or the offending section) with stdin held open by a never-closing source and asserts it terminates; mutation-tested both directions (revert the source fix → the case fails; keep it → passes)
    - a *direct* invocation of `test_workflow.sh` (not through `bounded-suite.sh`) is self-bound: the preamble re-execs itself under `bounded-suite.sh` behind a `WF_TEST_SELF_BOUND=1` guard variable the wrapper sets (so the wrapped path never re-wraps), naming the running case on breach — `make test-build-workflow` and the quality-gates slice stay byte-identical (already wrapped, temperloop#2184)
    - the stdin-held-open test case lives in `test_bounded_suite.sh` (not `test_workflow.sh`), so this item's only edits to the suite file are its preamble and the one `cat` site
  - activation:
    - class: A
    - proof: "grep -q 'WF_TEST_SELF_BOUND' workflows/scripts/build/tests/test_workflow.sh"
  - notes: `model:` deliberately absent — plan-schema carve-out (b): a bound that never fires is indistinguishable from a suite with nothing to bound. The hang was intermittent (same background mode completed before and after), so the reproduction must hold stdin open deliberately rather than rely on a background shell. The stale batch2 process is an operator disposal (Sequencing notes), not part of this item.
  - pr: 2265
  - Run-status: run started 2026-09-25T04:45Z · session 25baf8ba · level 1/1 closed · items: 3 done / 0 parked / 0 in-flight / 0 skipped · path: conversational (--no-workflow)

## Merge gate log

- consent: level 0 · 2026-09-25T11:55:14Z · mode: modal-approved (operator answered "Merge all three" at the level gate) · PRs: #2263 #2264 #2265
