#!/usr/bin/env bash
#
# Offline fixture harness for claude/workflows/build-level.mjs — the
# per-level Workflow driver for /build (foundation epic #419, item #423).
#
# Approach: The .mjs is a standard ES module with `export default async function
# buildLevel()` and ambient hooks (agent/parallel/log/phase) resolved via the
# Workflow runtime. We inject those hooks as globalThis properties BEFORE the
# dynamic import(), so the same module runs deterministically under plain Node
# (v26, zero network). No modifications to the .mjs are needed.
#
# parallel() in the runtime maps to Promise.all — items in one level run
# concurrently. The mock infrastructure therefore keys per-item machinery/worker
# response sequences by slug (extracted from opts.label), not by global
# position in a flat queue. This makes the mock deterministic regardless of
# which item's agent() calls land first.
#
# Covers:
#   - happy: 3 green items → 3 parked, empty escalations, no plan-note write
#   - design-fork: one item returns design-fork → escalations[], siblings park
#   - failed verdict: one item returns failed → escalation, sibling parks
#   - ci-failed within budget: CI_FAILED then fix-worker + force-push → CI_GREEN → parked
#   - ci-failed past budget: CI_FAILED, retries exhausted → ci-failed escalation
#   - ci-poll TIMEOUT loop: TIMEOUT slices then CI_GREEN → parked
#   - claim-conflict: CLAIM_CONFLICT → claim-conflict escalation
#   - push-rejected: PUSH_REJECTED → push-rejected escalation
#   - push-unwatched (temperloop#1688): PUSHED_UNWATCHED → its own
#     push-unwatched-branch escalation carrying the PR's real head ref, and NO
#     pr-open/CI-poll past it
#   - scan-blocked: SCAN_BLOCKED → closing-keyword escalation
#   - 2-level e2e smoke: two buildLevel() calls (stateless), each produces parked/escalations
#   - deploy-discovery: ~/.claude/workflows/build-level.mjs resolves (install-claude)
#   - spike kind: spike items skip push/PR/CI, park with null pr/pushed_sha
#   - gate-fail: GATE_FAIL → acceptance-gate-failed escalation
#   - pre-gate freshness rebase (temperloop#1937): a worktree behind
#     origin/main rebases cleanly and reaches the gate on the rebased tree; a
#     rebase conflict escalates its own stale-worktree kind (never
#     acceptance-gate-failed) and the gate never runs; a worktree already at
#     main takes the byte-identical pre-#1937 path (one freshness check, no
#     extra rebase spawn); plus a static guard pinning the call order
#     (freshness step before the gate call in driveItem)
#   - gate verdict/payload agreement (#1587): the escalation kind, its verdict,
#     its failure count and its reason all derive from ONE slice ledger, in all
#     four gate outcomes — no payload field may contradict the kind it ships under
#   - 3e.6 class-A activation gate (temperloop#1219): a class-A proof that fails
#     never reaches 3f; an absence-asserting proof gets the temperloop#944
#     merge-base control FIRST (both arms — vacuous escalates without ever
#     running the worktree copy, discriminating proceeds); no block / class B/C
#     take the byte-identical pre-#1219 path with zero activation agent spawns;
#     and the GENERATED shell is executed for real against a git fixture
#   - worktree-failed: worktree.sh non-CREATED → worktree-failed escalation
#   - continuation: onlySlugs+verdicts → verdict injected into worker prompt,
#     existing worktree reused (no create/claim), only continued slug driven
#   - sideline notice (temperloop#2006): a CREATED outcome carrying
#     `sidelined:true` produces a named SIDELINED BUILD log notice with the
#     path, the branch and a concrete recovery command, stamps the same object
#     onto the item's parked record AND onto an escalating item's payload, and
#     rolls up onto the returned level summary; `sidelined:false` is silent and
#     byte-identical to the pre-#2006 return
#   - zero-disposition guard (temperloop#2004): a level that disposed of
#     NOTHING for a non-empty driven set returns a named `zeroDisposition`
#     outcome (which slugs, plus a concrete re-probe of issue status / open PRs
#     / the worktree) alongside a named notice, and the three driver specs each
#     carry an arm for it; the three CONTROLS — an empty level, an onlySlugs
#     filter matching nothing, and a spike-only verdict-park level — stay
#     silent and byte-identical to the pre-#2004 return
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && cd ../../../.. && pwd)"
MJS="$REPO_ROOT/claude/workflows/build-level.mjs"
[ -f "$MJS" ] || { echo "FAIL: build-level.mjs not found at $MJS" >&2; exit 1; }

# temperloop#2046 — PRODUCTION-STATE SNAPSHOT (the behavioural half of the
# no-bump guard at the end of this file). Running this suite must leave the
# repo's §3e review-round marker exactly as it found it. Two cases here execute
# the REAL generated review-diff pipeline against REPO_ROOT, and when the suite
# runs inside a build worktree — which is exactly where a /build, /fix or
# /sweep worker runs it — REPO_ROOT IS that worktree, so a bumping call
# increments the worktree's own production round counter. That failure is
# SILENT (nothing goes red, the counter just drifts), which is why it survived
# until it had inflated the counter far enough to fire #1970's convergence
# bound on the first real review round. Snapshot it here, compare at the end.
REVIEW_ROUNDS_MARKER=""
_rr_gitdir="$(git -C "$REPO_ROOT" rev-parse --absolute-git-dir 2>/dev/null || true)"
[ -n "$_rr_gitdir" ] && REVIEW_ROUNDS_MARKER="$_rr_gitdir/build-review-rounds"
REVIEW_ROUNDS_BEFORE="ABSENT"
if [ -n "$REVIEW_ROUNDS_MARKER" ] && [ -f "$REVIEW_ROUNDS_MARKER" ]; then
  REVIEW_ROUNDS_BEFORE="$(cat "$REVIEW_ROUNDS_MARKER" 2>/dev/null || echo UNREADABLE)"
fi
# temperloop#2127 — the SAME treatment for the sibling marker: it is written
# by the identical bumping code path (reviewDiffCmd), beside build-review-
# rounds, in the SAME worktree git dir, so it needs the SAME before/after
# production-state snapshot or a test run could inflate/corrupt it silently
# exactly like #2046 named for the round counter.
REVIEW_ROUNDS_SHA_MARKER=""
[ -n "$_rr_gitdir" ] && REVIEW_ROUNDS_SHA_MARKER="$_rr_gitdir/build-review-rounds-sha"
REVIEW_ROUNDS_SHA_BEFORE="ABSENT"
if [ -n "$REVIEW_ROUNDS_SHA_MARKER" ] && [ -f "$REVIEW_ROUNDS_SHA_MARKER" ]; then
  REVIEW_ROUNDS_SHA_BEFORE="$(cat "$REVIEW_ROUNDS_SHA_MARKER" 2>/dev/null || echo UNREADABLE)"
fi

# temperloop#1014: the machinery executors run as the `machinery-executor` agent,
# whose definition carries the standing contract the lean prompt no longer
# restates. The suite asserts against that file, so its absence is a hard fail
# (the driver would silently fall back to general-purpose and the context win
# would vanish unnoticed).
AGENT_DEF="$REPO_ROOT/claude/agents/machinery-executor.md"
[ -f "$AGENT_DEF" ] || { echo "FAIL: machinery-executor agent definition not found at $AGENT_DEF" >&2; exit 1; }

# Node preflight (#436): this harness runs build-level.mjs under Node. Without it
# the suite fails mid-case with a cryptic "node: command not found"; fail LOUDLY and
# actionably instead so a node-less dev machine is obvious, not confusing. CI runners
# ship Node, so this passes there and the suite runs normally. (Do NOT skip-and-pass
# on absence — that would falsely green `make quality-gates` while the gate never ran,
# breaking local==CI parity.)
command -v node >/dev/null 2>&1 || {
  echo "FAIL: 'node' not found — this gate executes claude/workflows/build-level.mjs under Node." >&2
  echo "      Install it: 'brew install node' (macOS). See Towheads/foundation#436." >&2
  exit 1
}

fail() { echo "FAIL: $1" >&2; exit 1; }

# Unique per-run temp root (#258): a fixed /tmp/wf-test-* path collides when
# two `quality-gates.sh` runs execute this suite concurrently in separate
# worktrees on the same host (parallel /build workers). mktemp -d gives each
# invocation its own PID/random-suffixed directory, and the EXIT trap sweeps
# it — no shared prefix for a sibling run to clobber or race against.
WF_TEST_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/wf-test.XXXXXX")"
# A case that must write OUTSIDE $WF_TEST_TMPDIR — because the path under test
# is chosen by the code under test, not by the harness (the #865 worker-gate
# sentinel is the only one today) — registers its artifacts HERE, at creation
# time, so the same EXIT trap sweeps them. `fail()` is `exit 1`, so a cleanup
# line written at the END of a block never runs on the failing path; that is
# exactly the run that leaves litter behind, and with per-run unique names the
# litter is no longer self-overwriting.
WF_TEST_SWEEP=()
wf_test_sweep_add() { WF_TEST_SWEEP+=("$@"); }
wf_test_cleanup() {
  rm -rf "$WF_TEST_TMPDIR"
  [ "${#WF_TEST_SWEEP[@]}" -gt 0 ] && rm -f "${WF_TEST_SWEEP[@]}"
  return 0
}
# INT/TERM as well as EXIT (review round 2, the LOW). An untrapped SIGINT or
# SIGTERM kills bash WITHOUT running an EXIT-only trap, and unlike
# $WF_TEST_TMPDIR (a mktemp -d under $TMPDIR the OS eventually reclaims) the
# swept paths are per-run-unique names in shared /tmp that nothing else will
# ever reclaim — so a CI job timeout or a Ctrl-C during a long gate run would
# accumulate them permanently. The function ends `return 0`, so it composes
# fine on all three; the shell's own exit status after the signal handler is
# not load-bearing for any caller of this suite (it reports via `fail`/exit 1).
trap wf_test_cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# run_node_case <description> <node-es-module-body>
# Writes a temp .mjs, runs it with node, reads the last stdout line as a JSON
# { ok: true } / { ok: false, reason: "..." } verdict.
# ---------------------------------------------------------------------------
run_node_case() {
  local desc="$1"
  local tmpf
  tmpf="$(mktemp "$WF_TEST_TMPDIR/case-XXXXXX.mjs")"
  printf '%s\n' "$2" > "$tmpf"
  local out rc=0
  out="$(node "$tmpf" 2>&1)" || rc=$?
  rm -f "$tmpf"
  if [ $rc -ne 0 ]; then
    echo "FAIL: $desc — node exited $rc" >&2
    echo "$out" >&2
    exit 1
  fi
  local last
  last="$(printf '%s\n' "$out" | tail -1)"
  local verdict
  verdict="$(printf '%s' "$last" | node -e "
    let s='';
    process.stdin.setEncoding('utf8');
    process.stdin.on('data',c=>s+=c);
    process.stdin.on('end',()=>{
      try {
        const r=JSON.parse(s);
        process.stdout.write(r.ok ? 'ok' : 'fail:' + JSON.stringify(r.reason||'false'));
      } catch(e) {
        process.stdout.write('parse-err:' + s.slice(0,200));
      }
    });
  " 2>/dev/null)" 2>/dev/null || verdict="parse-err"

  if [[ "$verdict" == ok ]]; then
    echo "PASS: $desc"
  else
    echo "FAIL: $desc — $verdict" >&2
    echo "Full node output:" >&2
    printf '%s\n' "$out" >&2
    exit 1
  fi
}

# ============================================================================
# Shared harness preamble injected at the start of every Node test case.
#
# Mock infrastructure design:
#   - machineryMap: Map<slug, outcome[]> — per-item ordered machinery returns
#   - workerMap: Map<slug, verdict[]> — per-item ordered worker returns
#   - agent() routes by opts.schema (machinery) vs no schema (worker), extracting
#     slug from opts.label (format: "phase:slug[#extra]")
#   - parallel() = Promise.all (matches runtime behaviour)
#   - log(), phase() = no-ops
#   - callLog: records every agent() call for plan-note-write assertions
#
# loadLevel() imports the .mjs fresh with a cache-busting query param so
# each test case gets a clean module instance.
# ============================================================================
read -r -d '' PREAMBLE << 'PREAMBLE_END' || true
import { readFileSync } from 'fs';
const MJS = process.env.MJS_PATH;

// temperloop#1014: the machinery executor's STANDING contract (run it verbatim,
// one JSON line per step, an early stop is expected) lives in the executor
// agent's own definition, so the lean per-call prompt no longer restates it. A
// test that asserts the contract reaches the executor must therefore look at
// whichever surface carries it on the path under test — this prompt for the
// general-purpose fallback, this file for the lean default.
const AGENT_DEF = readFileSync(process.env.AGENT_DEF_PATH, 'utf8');
globalThis.AGENT_DEF = AGENT_DEF;

const callLog = [];

// --- temperloop#1294: agent-KIND classifiers --------------------------------
// opts.phase is no longer the flat 'machinery'/'worker' constant — it is the
// per-STAGE progress heading (`build level · <stage> — <repo> · N items · …`),
// dynamic by construction because it carries #903's run context. So the mock can
// no longer route (and cases can no longer assert) on the phase STRING.
//
// Route on the LABEL instead: every spawn site already encodes the agent kind
// there — `worker:` / `worker-cifix:` is the implementation worker, everything
// else is a machinery executor. Deliberately NOT derived from the phase string:
// a label-based classifier keeps working if the heading format is retuned again,
// and an agent spawned with NO label matches neither, which is exactly what the
// "no third agent kind" assertion wants to catch.
globalThis.isWorkerCall = (o) => /^(worker|worker-cifix):/.test(String((o && o.label) || ''));
// temperloop#1430: a THIRD agent kind — the §3e reviewer(s), spawned directly
// by driveItem (never via the worker). Label grammar: `review:<slug>#<reviewer>`
// (the `#`-delimited extra form every other multi-part label already uses —
// see slugFromLabel below). Excluded from isMachineryCall so a review spawn
// never falls into the machinery batch/solo dispatcher (it returns free
// advisory TEXT, not a closed-outcome JSON object).
globalThis.isReviewCall = (o) => /^review:/.test(String((o && o.label) || ''));
globalThis.isMachineryCall = (o) => !!(o && o.label) && !globalThis.isWorkerCall(o) && !globalThis.isReviewCall(o);

// machineryMap: slug → [outcome, ...] — consumed in order per slug
const machineryMap = new Map();
// workerMap: slug → [verdict, ...] — consumed in order per slug
const workerMap = new Map();
// reviewMap: slug → [response, ...] — consumed in order per slug, one entry
// PER MATCHED REVIEWER (routes run in Map-insertion order — see
// determineReviewers()). A response is a review-text STRING, `null` (models
// agent() returning null — skip/transient), or `{__throw: msg}` (models
// agent() THROWING — a resolution failure when msg matches
// MACHINERY_RESOLUTION_ERR's shape, any other error otherwise). Default
// (map miss): null — "reviewer ran but returned nothing", never a crash.
// temperloop#2003 adds `{__hang: true}` — a reviewer that is SPAWNED and never
// returns: agent() resolves to a promise that never settles, which is the whole
// failure class the §3e wall-clock ceiling exists to bound. A mock that can only
// return or throw cannot model it at all.
const reviewMap = new Map();
// reviewWaitMap: slug → [outcome, ...] — the §3e ceiling's own TIMER executor
// (`review-wait:<slug>#<mark>`, temperloop#2003) keeps its OWN queue, mirroring
// freshnessMap/mergeCheckMap and for the identical reason: routing it through
// the shared per-slug machineryMap FIFO would consume the entry every existing
// test wrote for something else and desync every step after it. Default (map
// miss): REVIEW_WAIT_ELAPSED — the timer did its job — so a case that models a
// hung reviewer needs no wiring at all, and a case whose reviewers all return
// never reaches the timer in the first place.
const reviewWaitMap = new Map();
// mergeCheckMap: slug → [mergeState, ...] — consumed in order per slug.
// Default (map miss): { mergeable: 'MERGEABLE', mergeStateStatus: 'CLEAN' }
// so existing tests need no changes — only CONFLICTING tests override this.
const mergeCheckMap = new Map();
// freshnessMap: slug → [outcome, ...] — consumed in order per slug, its OWN
// queue (temperloop#1937), mirroring mergeCheckMap's precedent exactly and for
// the same reason: the pre-gate freshness solo call (`gate-freshness:<slug>`)
// sits strictly between REVIEW_DIFF and the gate call in EVERY item's real
// call sequence, so routing it through the shared machineryMap FIFO would
// consume the queue entry every existing test wrote for something else (the
// gate call itself, most directly) and desync every step after it. Default
// (map miss): FRESHNESS_CURRENT, so the hundred-plus existing tests that never
// call setFreshness() — none of which model a stale worktree — need no changes.
const freshnessMap = new Map();
// preserveMap: slug → [outcome, ...] — temperloop#2020's post-commit
// work-preservation push (`preserve-push:<slug>`), which fires at the ONE
// escalation choke point. Its OWN queue, mirroring freshnessMap/mergeCheckMap
// and for the identical reason: it runs AFTER every other machinery step of an
// escalating item, so routing it through the shared per-slug machineryMap FIFO
// would consume whatever entry that test queued for something else (and, on the
// common exhausted-queue case, silently turn a fixture's ERROR default into a
// preservation reading). Default (map miss): WORK_PRESERVED — every escalation
// case predating this item models a worktree holding the worker's commits,
// which is exactly the case the push preserves, so none of them need changing.
const preserveMap = new Map();
// workerClockMap / workerUsageMap: slug → [outcome, ...] — temperloop#2065's
// worker-cost-capture seam (`worker-clock:<slug>#<tag>` / `worker-usage:
// <slug>#<tag>`), each its OWN queue, mirroring freshnessMap/preserveMap/
// reviewWaitMap exactly and for the identical reason: these solo calls now
// fire on EVERY item's happy path (callWorker() brackets every worker spawn,
// and the CI_FAILED retry brackets its own re-spawn), so routing them through
// the shared per-slug machineryMap FIFO would consume whatever entry every
// EXISTING test queued for something else. Default (map miss): a FIXED epoch
// (1000) on every reading, so an unmocked item's wall_clock_ms comes out to a
// deterministic 0 rather than an arbitrary value, and usage_source
// "unavailable" (tokens null) — the SAME honest degrade the real
// worker-usage.sh reports when no envelope exists (see that script's header).
const workerClockMap = new Map();
const workerUsageMap = new Map();

function slugFromLabel(label) {
  // Labels from runMachineryBatch (temperloop#942): "prelude:slug",
  // "pr-batch:slug", "ci-batch:slug#N".
  // Labels from the remaining solo runMachinery calls: "gate:slug",
  // "recover-probe:slug", "push-retry:slug", "machinery:cmd ..."
  // Labels from worker: "worker:slug", "worker-cifix:slug"
  if (!label) return null;
  const m = label.match(/^[^:]+:([^#\s]+)/);
  return m ? m[1] : null;
}

// --- temperloop#942: batched-machinery mock ---------------------------------
// The driver now sends SEVERAL machinery commands per executor agent
// (`prelude:` / `pr-batch:` / `ci-batch:` labels) and the agent returns
// { results: [...] } — ONE object per step that actually RAN (shorter than the
// step list whenever the real bash short-circuit stopped the sequence).
//
// The mock replays the SAME flat per-slug outcome queue the solo path uses: one
// entry per step, stopping where bash would. BATCH_CONTINUE_ON is the harness's
// own INDEPENDENT restatement of each step kind's continue rule — deliberately
// not read from the .mjs, so if production's `continueOutcomes` and this table
// ever diverge a case desyncs and fails, which is the point.
const BATCH_CONTINUE_ON = {
  claim: ['CLAIMED'],
  'deps-merged': ['DEPS_MERGED'],
  worktree: null,   // terminal within the prelude
  rebase: ['REBASED'],
  scan: ['SCAN_CLEAN'],
  push: ['PUSHED'],
  'pr-open': null,  // terminal within the pr-batch
  'ci-poll': ['TIMEOUT'],
};

// machineryStepLog — every batched step the mock actually RAN, in order:
// { slug, kind }. This is the batching-era replacement for the old per-command
// label assertions (there is no longer a `worktree:`/`depcheck:`/`ci-poll:`
// agent label to filter callLog on — the step lives inside one batch).
const machineryStepLog = [];
globalThis.machineryStepLog = machineryStepLog;
globalThis.stepsRun = (slug) => machineryStepLog.filter(s => s.slug === slug).map(s => s.kind);

// The prompt's own `Steps: a, b, c` manifest identifies a batched call and names
// its steps in order.
function batchStepKinds(prompt) {
  const m = String(prompt).match(/^Steps: (.+)$/m);
  return m ? m[1].split(', ') : null;
}

function nextFromMap(map, slug, fallback) {
  const q = map.get(slug);
  if (q && q.length > 0) return q.shift();
  if (fallback !== undefined) return fallback;
  throw new Error(`No mock entry for slug="${slug}" in map; label exhausted`);
}

// reviewWaitLog — every §3e timer spawn the mock served, in order
// (temperloop#2003). The ceiling's slicing is asserted against this rather than
// against wall-clock time, which the Workflow runtime cannot measure anyway.
const reviewWaitLog = [];
globalThis.reviewWaitLog = reviewWaitLog;
globalThis.reviewWaitMap = reviewWaitMap;
globalThis.setReviewWait = (slug, ...outcomes) => { reviewWaitMap.set(slug, outcomes); };
globalThis.callLog = callLog;
globalThis.machineryMap = machineryMap;
globalThis.workerMap = workerMap;
globalThis.mergeCheckMap = mergeCheckMap;
globalThis.reviewMap = reviewMap;
globalThis.freshnessMap = freshnessMap;
globalThis.preserveMap = preserveMap;
globalThis.workerClockMap = workerClockMap;
globalThis.workerUsageMap = workerUsageMap;
globalThis.setWorkerClock = (slug, ...outcomes) => { workerClockMap.set(slug, outcomes); };
globalThis.setWorkerUsage = (slug, ...outcomes) => { workerUsageMap.set(slug, outcomes); };

globalThis.agent = async function agent(prompt, opts = {}) {
  callLog.push({ prompt: String(prompt).slice(0, 120), promptFull: String(prompt), opts: { label: opts.label, phase: opts.phase, model: opts.model, agentType: opts.agentType } });
  const slug = slugFromLabel(opts.label);
  if (isMachineryCall(opts)) {
    const kinds = batchStepKinds(prompt);
    if (!kinds) {
      // temperloop#1937: the pre-gate freshness step keeps its OWN queue
      // (freshnessMap, mirroring mergeCheckMap) so it never consumes an entry
      // from the shared per-slug machineryMap FIFO — see freshnessMap's own
      // comment for why that sharing would desync every existing test.
      if (/^gate-freshness:/.test(String(opts.label || ''))) {
        return nextFromMap(freshnessMap, slug, { outcome: 'FRESHNESS_CURRENT', worktree_base: 'wt-base', main: 'main-tip' });
      }
      // temperloop#2020: the escalation-path work-preservation push keeps its
      // OWN queue too — see preserveMap's comment for why it must not share
      // the machineryMap FIFO.
      if (/^preserve-push:/.test(String(opts.label || ''))) {
        return nextFromMap(preserveMap, slug, { outcome: 'WORK_PRESERVED', branch: 'build/' + slug, commits_ahead: 1, pushed: true });
      }
      // temperloop#2065: the worker-cost-capture seam's OWN queues — see
      // workerClockMap/workerUsageMap's comment above for why they cannot
      // share machineryMap's FIFO.
      // temperloop#2065 review round 2 [HIGH]: a queued { __throw: msg } entry
      // here models runMachinery()/machineryAgent()'s OWN re-throw (an
      // unresolvable agentType, a StructuredOutput-absent/retry-capped
      // executor) — the exact throw shape safeWorkerClockNow()/
      // safeWorkerUsageEmit() exist to catch. Without that guard this
      // propagates past callWorker()/ciPollLoop() uncaught, per the same
      // #939 __throw precedent the worker-call branch below already uses.
      if (/^worker-clock:/.test(String(opts.label || ''))) {
        const v = nextFromMap(workerClockMap, slug, { outcome: 'WORKER_CLOCK', epoch_s: 1000 });
        if (v && v.__throw) throw new Error(v.__throw);
        return v;
      }
      if (/^worker-usage:/.test(String(opts.label || ''))) {
        const v = nextFromMap(workerUsageMap, slug, {
          outcome: 'WORKER_USAGE', epoch_s: 1000, usage_source: 'unavailable', input_tokens: null, output_tokens: null,
        });
        if (v && v.__throw) throw new Error(v.__throw);
        return v;
      }
      // temperloop#2003: the §3e ceiling's timer executor, on its own queue
      // (see reviewWaitMap). Default REVIEW_WAIT_ELAPSED = "the interval
      // elapsed", which is the only fact this call ever reports.
      // temperloop#2049: the default now also carries `realized_secs` — the
      // MEASURED wait review-wait.sh prints — because reviewWaitAgent() honours
      // an elapse only when that field reaches the interval it asked for. A
      // deliberately huge value models "the timer genuinely waited" for every
      // slice length; a case that wants the #2049 defect (an elapse CLAIMED
      // without a realized wait) wires that shape explicitly via setReviewWait.
      if (/^review-wait:/.test(String(opts.label || ''))) {
        reviewWaitLog.push({ slug, label: String(opts.label) });
        return nextFromMap(reviewWaitMap, slug, { outcome: 'REVIEW_WAIT_ELAPSED', realized_secs: 1e9 });
      }
      // Solo executor (gate / recover-probe / push-retry) — routed by slug.
      return nextFromMap(machineryMap, slug, { outcome: 'ERROR', error: 'unexpected machinery call for ' + slug });
    }
    // Batched executor (temperloop#942): consume one queued outcome per step and
    // stop exactly where the emitted bash `case` gate would.
    const results = [];
    for (const kind of kinds) {
      // The merge-state probe is `gh pr view`, not a machinery script — it keeps
      // its own map (default non-conflicting) so pre-batching cases that call
      // setMergeCheck() need no changes.
      const r = kind === 'merge-state'
        ? nextFromMap(mergeCheckMap, slug, { mergeable: 'MERGEABLE', mergeStateStatus: 'CLEAN' })
        : nextFromMap(machineryMap, slug, { outcome: 'ERROR', error: 'unexpected machinery step ' + kind + ' for ' + slug });
      machineryStepLog.push({ slug, kind });
      // A queued null models the auto-mode classifier DENYING the command: the
      // whole executor call comes back null, not a partial results array.
      if (r === null) return null;
      // temperloop#1067: a queued { __lostReturn: true } entry models the step
      // RUNNING (its real bash command executed — machineryStepLog already
      // recorded it above) but the executor's own JSON line for it never
      // reaching the driver (a dropped/truncated last line), NOT a short-circuit
      // stop. No entry is pushed to `results` for this step, so batchStep()
      // synthesizes its 'produced no result' sentinel — exactly the fidelity
      // drop this wiring probes for, distinct from every prior test's
      // short-circuit stop (which always includes an entry for the stopping
      // step itself).
      if (r.__lostReturn) break;
      results.push(r);
      if (kind === 'merge-state') {
        if (r.mergeable === 'CONFLICTING' || r.mergeStateStatus === 'DIRTY') break;
      } else {
        const cont = BATCH_CONTINUE_ON[kind];
        if (cont && !cont.includes(r.outcome)) break;
      }
    }
    return { results };
  }
  if (isWorkerCall(opts)) {
    // Worker call — implementation agent, routed by slug.
    // temperloop#939: a queued { __throw: '<msg>' } entry makes agent() THROW
    // instead of returning — faithfully simulating the real runtime when a
    // subagent completes without calling StructuredOutput, or blows the
    // StructuredOutput retry cap. That is an EXCEPTION, not a null return, so a
    // mock that can only return null cannot exercise the #939 path at all.
    const v = nextFromMap(workerMap, slug, { status: 'done', summary: 'default', acceptance_results: [], commits: [] });
    if (v && v.__throw) throw new Error(v.__throw);
    return v;
  }
  if (isReviewCall(opts)) {
    // §3e reviewer call (temperloop#1430) — routed by slug, ONE queued entry
    // consumed per matched reviewer (in the order determineReviewers() found
    // them). Default (map miss): null — a reviewer that ran but returned
    // nothing, never a crash. A string models a normal advisory-text return;
    // { __throw: msg } models agent() THROWING (msg matching
    // MACHINERY_RESOLUTION_ERR's shape models a genuine resolution failure —
    // the same precedent machineryAgent() uses).
    const v = nextFromMap(reviewMap, slug, null);
    if (v && v.__throw) throw new Error(v.__throw);
    // temperloop#2003 — the HANG. Not a slow return and not an error: a promise
    // that never settles, exactly like the reviewer whose transcript stopped
    // mid-sentence in run wf_f3b9c160-6ca.
    if (v && v.__hang) return new Promise(() => {});
    return v;
  }
  // Fallback (should not happen in well-formed test cases)
  return nextFromMap(workerMap, slug, { status: 'done', summary: 'fallback', acceptance_results: [], commits: [] });
};

globalThis.log = () => {};
globalThis.phase = () => {};
globalThis.parallel = async (fns) => Promise.all(fns.map(f => f()));

// Helpers to register sequences
globalThis.setMachinery = (slug, ...outcomes) => { machineryMap.set(slug, outcomes); };
globalThis.setWorker = (slug, ...verdicts) => { workerMap.set(slug, verdicts); };
globalThis.setMergeCheck = (slug, ...states) => { mergeCheckMap.set(slug, states); };
globalThis.setFreshness = (slug, ...outcomes) => { freshnessMap.set(slug, outcomes); };
globalThis.setPreserve = (slug, ...outcomes) => { preserveMap.set(slug, outcomes); };
globalThis.setReview = (slug, ...responses) => { reviewMap.set(slug, responses); };
// tsvRows(text) — temperloop#1976: the harness's OWN independent restatement
// of reviewDiffCmd's row-count rule (non-blank, non-`#` lines — the same
// first-stage filter parseTsvRows() applies before its column check),
// deliberately re-derived here rather than imported from the .mjs, so a
// fixture's `tsv_rows` is a real count of ITS OWN `tsv` text, not a copy of
// production's counting code that could silently drift alongside it.
globalThis.tsvRows = (t) => String(t ?? '')
  .split('\n')
  .map((l) => l.replace(/\r$/, ''))
  .filter((l) => l.trim() && !l.trim().startsWith('#'))
  .length;
// tsvChecksum(text) — temperloop#1982, POSITION-WEIGHTED as of round 2: the
// harness's OWN independent restatement of reviewDiffCmd's content-checksum
// rule (SAME row filter as tsvRows, then a running sum of character codes,
// each weighted by its 1-based position, over each kept line plus its own
// trailing newline), deliberately re-derived here rather than imported from
// the .mjs — same rationale as tsvRows above, so a fixture's `tsv_checksum`
// is computed from ITS OWN `tsv` text, not a copy of production's summing
// code that could silently drift alongside it. Position-weighting (not a
// bare sum) is load-bearing: a bare sum is commutative and cannot see two
// same-length rows trading places — see the K1982 position-sensitive test
// below for the reproduction this defeats.
globalThis.tsvChecksum = (t) => {
  const canon = String(t ?? '')
    .split('\n')
    .map((l) => l.replace(/\r$/, ''))
    .filter((l) => l.trim() && !l.trim().startsWith('#'))
    .map((l) => l + '\n')
    .join('');
  let sum = 0;
  for (let i = 0; i < canon.length; i++) sum += canon.charCodeAt(i) * (i + 1);
  return sum;
};
// tsvLines(text) — temperloop#2020: the harness's OWN independent restatement
// of reviewDiffCmd's `tsv_lines` wire shape (the row-filtered data rows as a
// JSON array of strings, the same filter tsvRows/tsvChecksum apply). Fixtures
// use it to build the CURRENT shape from the same text they hand tsvRows() and
// tsvChecksum(), so a case's three fields stay mutually consistent by
// construction and a production change that broke the "joined rows == the old
// blob" equivalence would desync the checksum and fail here.
globalThis.tsvLines = (t) => String(t ?? '')
  .split('\n')
  .map((l) => l.replace(/\r$/, ''))
  .filter((l) => l.trim() && !l.trim().startsWith('#'));
// reviewResolutionFailure — the SAME two-marker shape machineryAgent()'s own
// MACHINERY_RESOLUTION_ERR regex matches (temperloop#1014/#1430): agent()
// rejecting an unresolvable/denied agentType BEFORE any subagent spawns.
globalThis.reviewUnavailable = (agentType) => ({ __throw: `agent type '${agentType}' not found. Available agents: general-purpose` });
// temperloop#939 mock shorthands.
// throwingWorker(msg) — the #939 return-channel failure (agent() throws).
globalThis.throwingWorker = (msg) => ({ __throw: msg || 'agent({schema}): subagent completed without calling StructuredOutput (after in-conversation nudge)' });
// noSideEffects — the recover-probe answer for a genuinely-failed worker.
globalThis.noSideEffects = () => ({ outcome: 'RECOVER_NONE', commits_ahead: 0, pushed: false, dirty: false, dirty_files: 0, verification_surface_present: false });
// temperloop#993 shorthand — dirtyStall(n): the recover-probe answer for a worker
// reaped mid-flight by a backgrounded gate: n uncommitted paths, ZERO commits.
globalThis.dirtyStall = (n) => ({ outcome: 'RECOVER_DIRTY', commits_ahead: 0, pushed: false, dirty: true, dirty_files: n ?? 8, verification_surface_present: false });
// temperloop#1067 shorthand — lostReturn(): queue this in place of a step's
// outcome to model a DROPPED JSON line (the step ran; its result never
// reached the driver) rather than a genuine failure or a short-circuit stop.
// See the __lostReturn handling in the batched-executor mock above.
globalThis.lostReturn = () => ({ __lostReturn: true });

// Canonical happy-path machinery sequence for a green item
globalThis.happyMachinery = (slug, prNum, sha) => setMachinery(slug,
  { outcome: 'CREATED', path: '/tmp/repo.wt/' + slug },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha, branch: 'build/' + slug },
  { outcome: 'PR_OPENED', pr_number: prNum },
  { outcome: 'CI_GREEN' },
);
globalThis.happyWorker = (slug, extra) => setWorker(slug,
  { status: 'done', summary: slug + ' done', acceptance_results: [{ criterion: 'c', passed: true, evidence: 'e' }], commits: [], ...(extra||{}) }
);

let _loadCount = 0;
// Faithful runtime simulation (#437): the Workflow runtime does NOT import the
// .mjs as an ES module — it strips `export const meta`, wraps the remaining body
// in an async function (so top-level await + top-level `return` work), supplies
// agent/parallel/log/phase as ambient hooks, and delivers `args` as a JSON
// STRING. We replicate that exactly, so this harness exercises the REAL
// invocation format. A plain import() silently passes a non-runnable file — that
// was the #437 false-green (it cannot even parse a top-level `return`). Each load
// gets a fresh AsyncFunction instance.
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
const MJS_SRC = readFileSync(MJS, 'utf8').replace(/^export const meta/m, 'const meta');
globalThis.loadLevel = async () => {
  _loadCount++;
  const fn = new AsyncFunction(MJS_SRC);
  return {
    default: async () => {
      const a = globalThis.args;
      globalThis.args = typeof a === 'string' ? a : JSON.stringify(a); // runtime delivers args as a JSON string
      return await fn();
    },
  };
};

const baseArgs = {
  repoRoot: '/tmp/repo',
  board: null,
  planLink: 'Plans/test.md',
  ownerRepo: 'owner/repo',
};
globalThis.baseArgs = baseArgs;
PREAMBLE_END

export MJS_PATH="$MJS"
export AGENT_DEF_PATH="$AGENT_DEF"

# ============================================================================
# TEST 1: happy — 3 green items → 3 parked, empty escalations, no plan-note write
# ============================================================================
run_node_case "happy: 3 green items → 3 parked, empty escalations, no plan-note write" "
$PREAMBLE

happyMachinery('item101', 101, 'a160');
happyMachinery('item102', 102, 'a261');
happyMachinery('item103', 103, 'a362');
happyWorker('item101');
happyWorker('item102');
happyWorker('item103');

globalThis.args = { ...baseArgs, items: [
  { slug: 'item101', branch: 'build/item101', title: 'Item 101', kind: 'impl', acceptance: ['c'] },
  { slug: 'item102', branch: 'build/item102', title: 'Item 102', kind: 'impl', acceptance: ['c'] },
  { slug: 'item103', branch: 'build/item103', title: 'Item 103', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();

const parked = result.parked ?? [];
const escalations = result.escalations ?? [];

if (parked.length !== 3)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 3 parked, got ' + parked.length + '; ' + JSON.stringify(result) })); process.exit(0); }
if (escalations.length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 0 escalations, got ' + JSON.stringify(escalations) })); process.exit(0); }

const p101 = parked.find(p => p.slug === 'item101');
const p102 = parked.find(p => p.slug === 'item102');
const p103 = parked.find(p => p.slug === 'item103');
if (!p101 || p101.pr !== 101 || p101.pushed_sha !== 'a160')
  { console.log(JSON.stringify({ ok: false, reason: 'item101 mismatch: ' + JSON.stringify(p101) })); process.exit(0); }
if (!p102 || p102.pr !== 102 || p102.pushed_sha !== 'a261')
  { console.log(JSON.stringify({ ok: false, reason: 'item102 mismatch: ' + JSON.stringify(p102) })); process.exit(0); }
if (!p103 || p103.pr !== 103 || p103.pushed_sha !== 'a362')
  { console.log(JSON.stringify({ ok: false, reason: 'item103 mismatch: ' + JSON.stringify(p103) })); process.exit(0); }

// temperloop#2065 'worker-cost-capture': a level with NO CI-fail retry is
// unchanged except for the six added cost keys — every pre-existing field
// (slug/pr/pushed_sha/acceptance_results, already asserted above) is
// untouched, and every parked record now ALSO carries tokens_in, tokens_out,
// wall_clock_ms, retry_tokens, retry_count and recovery, present even at
// their honest-degrade baseline (never conditionally omitted like no_ci).
// The mock's default WORKER_CLOCK/WORKER_USAGE reading is a FIXED epoch
// (1000) on every call, so an unmocked item's wall_clock_ms comes out to a
// deterministic 0 — proving the arithmetic runs, not merely that the keys
// exist — and usage_source 'unavailable' degrades tokens_in/tokens_out to
// null, the same honest degrade the real worker-usage.sh reports absent a
// captured envelope.
for (const p of [p101, p102, p103]) {
  if (p.tokens_in !== null || p.tokens_out !== null)
    { console.log(JSON.stringify({ ok: false, reason: p.slug + ': expected tokens_in/tokens_out null (no envelope), got ' + JSON.stringify({in: p.tokens_in, out: p.tokens_out}) })); process.exit(0); }
  if (p.wall_clock_ms !== 0)
    { console.log(JSON.stringify({ ok: false, reason: p.slug + ': expected wall_clock_ms 0 (fixed-epoch mock default), got ' + p.wall_clock_ms })); process.exit(0); }
  if (p.retry_tokens !== null)
    { console.log(JSON.stringify({ ok: false, reason: p.slug + ': expected retry_tokens null (no retry attempted), got ' + p.retry_tokens })); process.exit(0); }
  if (p.retry_count !== 0)
    { console.log(JSON.stringify({ ok: false, reason: p.slug + ': expected retry_count 0, got ' + p.retry_count })); process.exit(0); }
  if (p.recovery !== false)
    { console.log(JSON.stringify({ ok: false, reason: p.slug + ': expected recovery false, got ' + p.recovery })); process.exit(0); }
}

// No plan-note write from inside the workflow (workflow only RETURNS; orchestrator writes)
const planWrites = callLog.filter(c =>
  !isMachineryCall(c.opts) && !isWorkerCall(c.opts) &&
  (String(c.prompt).toLowerCase().includes('write the plan') || String(c.prompt).toLowerCase().includes('update the plan note'))
);
if (planWrites.length > 0)
  { console.log(JSON.stringify({ ok: false, reason: 'plan-note write detected: ' + JSON.stringify(planWrites) })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 1b: worker-cost-capture guard — a throwing worker-clock/worker-usage
# call degrades the ITEM's cost fields to null, it never aborts the item
# (temperloop#2065 review round 2 [HIGH])
# ============================================================================
run_node_case "worker-cost-capture guard: workerClockNow()/workerUsageEmit() THROWING never aborts the item — cost fields degrade to null instead" "
$PREAMBLE

happyMachinery('clockthrow', 201, 'c500');
happyWorker('clockthrow');
// The main worker's OWN clock start throws (models machineryAgent()'s
// re-throw on an unresolvable/retry-capped executor) — the SAME shape
// callWorker() wraps the real agent({schema}) call in try/catch for.
setWorkerClock('clockthrow', { __throw: 'agent type not found' });

happyMachinery('usagethrow', 202, 'c600');
happyWorker('usagethrow');
// The main worker's OWN post-return usage-emit throws.
setWorkerUsage('usagethrow', { __throw: 'agent type not found' });

globalThis.args = { ...baseArgs, items: [
  { slug: 'clockthrow', branch: 'build/clockthrow', title: 'Clock throws', kind: 'impl', acceptance: ['c'] },
  { slug: 'usagethrow', branch: 'build/usagethrow', title: 'Usage throws', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();

const parked = result.parked ?? [];
const escalations = result.escalations ?? [];

// Pre-fix (bare workerClockNow()/workerUsageEmit() calls): the throw
// propagates past callWorker() uncaught and the item never parks at all —
// it either escalates as a generic worker-error or the whole level rejects.
// Post-fix: BOTH items park normally, with the real worker verdict intact and
// only the cost fields degraded.
if (escalations.length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 0 escalations (the throw must degrade, not escalate), got ' + JSON.stringify(escalations) })); process.exit(0); }
if (parked.length !== 2)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 2 parked (both items survive the throw), got ' + parked.length + '; ' + JSON.stringify(result) })); process.exit(0); }

const pClock = parked.find(p => p.slug === 'clockthrow');
const pUsage = parked.find(p => p.slug === 'usagethrow');
if (!pClock || pClock.pr !== 201)
  { console.log(JSON.stringify({ ok: false, reason: 'clockthrow did not park with its real verdict: ' + JSON.stringify(pClock) })); process.exit(0); }
if (!pUsage || pUsage.pr !== 202)
  { console.log(JSON.stringify({ ok: false, reason: 'usagethrow did not park with its real verdict: ' + JSON.stringify(pUsage) })); process.exit(0); }

// A thrown clock read means startS is null, so elapsedMs() (both-null-safe)
// degrades wall_clock_ms to null rather than a bogus arithmetic result.
if (pClock.wall_clock_ms !== null)
  { console.log(JSON.stringify({ ok: false, reason: 'clockthrow: expected wall_clock_ms null (clock threw), got ' + pClock.wall_clock_ms })); process.exit(0); }
if (pClock.tokens_in !== null || pClock.tokens_out !== null)
  { console.log(JSON.stringify({ ok: false, reason: 'clockthrow: expected tokens_in/out null, got ' + JSON.stringify({in: pClock.tokens_in, out: pClock.tokens_out}) })); process.exit(0); }
// A thrown usage-emit means the WHOLE usage reading degrades (epochS/tokensIn/
// tokensOut all null) — never a partial object that manufactures a false zero.
if (pUsage.tokens_in !== null || pUsage.tokens_out !== null)
  { console.log(JSON.stringify({ ok: false, reason: 'usagethrow: expected tokens_in/out null (usage-emit threw), got ' + JSON.stringify({in: pUsage.tokens_in, out: pUsage.tokens_out}) })); process.exit(0); }
if (pUsage.wall_clock_ms !== null)
  { console.log(JSON.stringify({ ok: false, reason: 'usagethrow: expected wall_clock_ms null (usage-emit threw, so the end edge is unavailable), got ' + pUsage.wall_clock_ms })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 2: design-fork — one item returns design-fork, siblings still park
# ============================================================================
run_node_case "design-fork: one design-fork item → escalations[], siblings park" "
$PREAMBLE

happyMachinery('item-a', 201, 'aa02');
happyMachinery('item-b', 202, 'ab06');
// item-fork: CREATED only (worker escalates immediately after worktree step)
setMachinery('item-fork',
  { outcome: 'CREATED', path: '/tmp/repo.wt/item-fork' }
);
happyWorker('item-a');
setWorker('item-fork',
  { status: 'design-fork', design_fork: { decision: 'need a seam', options: [{ label: 'opt1', tradeoff: 'fast' }], recommendation: 'opt1', evidence: 'ev' } }
);
happyWorker('item-b');

globalThis.args = { ...baseArgs, items: [
  { slug: 'item-a',    branch: 'build/item-a',    title: 'Item A',    kind: 'impl' },
  { slug: 'item-fork', branch: 'build/item-fork', title: 'Item Fork', kind: 'impl' },
  { slug: 'item-b',    branch: 'build/item-b',    title: 'Item B',    kind: 'impl' },
]};

const mod = await loadLevel();
const result = await mod.default();

if ((result.parked ?? []).length !== 2)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 2 parked: ' + JSON.stringify(result) })); process.exit(0); }
if ((result.escalations ?? []).length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 1 escalation: ' + JSON.stringify(result) })); process.exit(0); }
if (result.escalations[0].kind !== 'design-fork')
  { console.log(JSON.stringify({ ok: false, reason: 'escalation kind wrong: ' + result.escalations[0].kind })); process.exit(0); }
if (result.escalations[0].slug !== 'item-fork')
  { console.log(JSON.stringify({ ok: false, reason: 'escalation slug wrong: ' + result.escalations[0].slug })); process.exit(0); }

const parkedSlugs = (result.parked ?? []).map(p => p.slug).sort();
if (JSON.stringify(parkedSlugs) !== JSON.stringify(['item-a','item-b']))
  { console.log(JSON.stringify({ ok: false, reason: 'wrong slugs parked: ' + JSON.stringify(parkedSlugs) })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 3: failed verdict → escalation, sibling still parks
# ============================================================================
run_node_case "failed verdict: one item returns failed → escalation, sibling parks" "
$PREAMBLE

happyMachinery('item-good', 301, 'ad26');
setMachinery('item-bad', { outcome: 'CREATED', path: '/tmp/repo.wt/item-bad' });
happyWorker('item-good');
setWorker('item-bad', { status: 'failed', failure_reason: 'could not compile' });

globalThis.args = { ...baseArgs, items: [
  { slug: 'item-good', branch: 'build/item-good', title: 'Good Item', kind: 'impl' },
  { slug: 'item-bad',  branch: 'build/item-bad',  title: 'Bad Item',  kind: 'impl' },
]};

const mod = await loadLevel();
const result = await mod.default();

if ((result.parked ?? []).length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 1 parked: ' + JSON.stringify(result) })); process.exit(0); }
if ((result.escalations ?? []).length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 1 escalation: ' + JSON.stringify(result) })); process.exit(0); }
if (result.escalations[0].kind !== 'failed')
  { console.log(JSON.stringify({ ok: false, reason: 'escalation kind wrong: ' + result.escalations[0].kind })); process.exit(0); }
if (result.parked[0].slug !== 'item-good')
  { console.log(JSON.stringify({ ok: false, reason: 'wrong item parked: ' + result.parked[0].slug })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 4: ci-failed within budget → re-spawn + force-push + CI_GREEN → parked
# The CI-failure re-spawn worker must run top-tier (no model specified).
# pushed_sha must be the re-pushed sha, not the initial push.
# ============================================================================
run_node_case "ci-failed within budget: re-spawn + force-push + re-poll CI_GREEN → parked" "
$PREAMBLE

setMachinery('item-cifix',
  { outcome: 'CREATED', path: '/tmp/repo.wt/item-cifix' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'a15e' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'a15e', branch: 'build/item-cifix' },
  { outcome: 'PR_OPENED', pr_number: 401 },
  // First CI poll: CI_FAILED
  { outcome: 'CI_FAILED', failed_run_ids: [9001] },
  // temperloop#1450: §3e re-review of the CI-fix commit, before the retry push
  { outcome: 'REVIEW_DIFF' },
  // Retry push after fix worker (plain push — ff descendant, no --force)
  { outcome: 'PUSHED', sha: 'a25f', branch: 'build/item-cifix' },
  // Re-poll pinned to sha-v2: CI_GREEN
  { outcome: 'CI_GREEN' },
);

let ciFixWorkerModel = undefined;
const origAgent = globalThis.agent;
globalThis.agent = async function(prompt, opts={}) {
  // Track model on the CI-fix worker call
  if (isWorkerCall(opts) && String(prompt).includes('CI failed')) {
    ciFixWorkerModel = opts.model;
  }
  return origAgent(prompt, opts);
};

setWorker('item-cifix',
  { status: 'done', summary: 'initial', acceptance_results: [], commits: [] },
  // Fix worker (for the 'worker-cifix:item-cifix' label):
  { status: 'done', summary: 'ci fixed', acceptance_results: [], commits: [] }
);
// worker-cifix label also routes to the same slug via slugFromLabel
workerMap.set('item-cifix', workerMap.get('item-cifix'));  // already set above

// temperloop#2065 'worker-cost-capture' — the CI_FAIL_RETRY_BUDGET loop's OWN
// cost tally. This item makes exactly TWO worker calls (the main worker, then
// ONE CI-fix retry): workerClockMap/workerUsageMap are per-slug FIFOs
// consumed in call order, so entry 1 = the main worker's readings and entry 2
// = the retry's. Distinct epochs on each so a wrong pairing (e.g. summing the
// WRONG usage entry into tokens_in/tokens_out instead of retry_tokens) would
// produce a wall_clock_ms/token total this test does not expect.
setWorkerClock('item-cifix',
  { outcome: 'WORKER_CLOCK', epoch_s: 1000 },  // main worker: start
  { outcome: 'WORKER_CLOCK', epoch_s: 5000 },  // ci-fix retry: start
);
setWorkerUsage('item-cifix',
  { outcome: 'WORKER_USAGE', epoch_s: 1100, usage_source: 'cli-envelope', input_tokens: 500, output_tokens: 200 },  // main: end
  { outcome: 'WORKER_USAGE', epoch_s: 5050, usage_source: 'cli-envelope', input_tokens: 80, output_tokens: 20 },    // retry: end
);

globalThis.args = { ...baseArgs, items: [
  { slug: 'item-cifix', branch: 'build/item-cifix', title: 'CI Fix Item', kind: 'impl', model: 'haiku' },
]};

const mod = await loadLevel();
const result = await mod.default();

if ((result.parked ?? []).length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 1 parked: ' + JSON.stringify(result) })); process.exit(0); }
if ((result.escalations ?? []).length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'unexpected escalation: ' + JSON.stringify(result) })); process.exit(0); }
if (result.parked[0].pushed_sha !== 'a25f')
  { console.log(JSON.stringify({ ok: false, reason: 'pushed_sha not re-pushed sha: ' + result.parked[0].pushed_sha })); process.exit(0); }
// CI-fix worker must omit model (top tier = undefined)
if (ciFixWorkerModel !== undefined)
  { console.log(JSON.stringify({ ok: false, reason: 'ci-fix worker had model: ' + ciFixWorkerModel })); process.exit(0); }

// temperloop#2065 — the ONE CI-fix re-spawn this item made must persist as
// retry_count=1 (never rolled into the main worker's own tokens_in/tokens_out),
// and its own tokens (80+20=100) as retry_tokens — distinct from the main
// worker's split tokens_in=500/tokens_out=200. wall_clock_ms is the TOTAL
// across both calls: main (1100-1000=100)s + retry (5050-5000=50)s = 150s =
// 150000ms — proving retry wall-clock rolls into the ONE combined figure
// rather than being dropped or double-counted.
if (result.parked[0].retry_count !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'expected retry_count 1, got ' + result.parked[0].retry_count })); process.exit(0); }
if (result.parked[0].retry_tokens !== 100)
  { console.log(JSON.stringify({ ok: false, reason: 'expected retry_tokens 100 (80 in + 20 out), got ' + result.parked[0].retry_tokens })); process.exit(0); }
if (result.parked[0].tokens_in !== 500 || result.parked[0].tokens_out !== 200)
  { console.log(JSON.stringify({ ok: false, reason: 'expected main worker tokens_in=500/tokens_out=200 (never mixed with the retry entry), got ' + JSON.stringify({in: result.parked[0].tokens_in, out: result.parked[0].tokens_out}) })); process.exit(0); }
if (result.parked[0].wall_clock_ms !== 150000)
  { console.log(JSON.stringify({ ok: false, reason: 'expected wall_clock_ms 150000 (main 100000 + retry 50000), got ' + result.parked[0].wall_clock_ms })); process.exit(0); }
if (result.parked[0].recovery !== false)
  { console.log(JSON.stringify({ ok: false, reason: 'expected recovery false (this item never hit the #939 lost-return path), got ' + result.parked[0].recovery })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 5: ci-failed past budget → ci-failed escalation
# CI_FAIL_RETRY_BUDGET=1, so after 1 retry: second CI_FAILED → escalate
# ============================================================================
run_node_case "ci-failed past budget: retries exhausted → ci-failed escalation" "
$PREAMBLE

setMachinery('item-cibust',
  { outcome: 'CREATED', path: '/tmp/repo.wt/item-cibust' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'a15e' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'a15e', branch: 'build/item-cibust' },
  { outcome: 'PR_OPENED', pr_number: 501 },
  { outcome: 'CI_FAILED', failed_run_ids: [9002] },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'PUSHED', sha: 'a25f', branch: 'build/item-cibust' },
  // Retry budget=1 used up; second CI_FAILED → escalate
  { outcome: 'CI_FAILED', failed_run_ids: [9003] },
);
setWorker('item-cibust',
  { status: 'done', summary: 'initial', acceptance_results: [], commits: [] },
  { status: 'done', summary: 'fix attempt', acceptance_results: [], commits: [] }
);

globalThis.args = { ...baseArgs, items: [
  { slug: 'item-cibust', branch: 'build/item-cibust', title: 'CI Bust Item', kind: 'impl' },
]};

const mod = await loadLevel();
const result = await mod.default();

if ((result.escalations ?? []).length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 1 escalation: ' + JSON.stringify(result) })); process.exit(0); }
if (result.escalations[0].kind !== 'ci-failed')
  { console.log(JSON.stringify({ ok: false, reason: 'escalation kind wrong: ' + result.escalations[0].kind })); process.exit(0); }
if ((result.parked ?? []).length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 0 parked: ' + JSON.stringify(result) })); process.exit(0); }
// temperloop#2135: 'ci-failed' is one of 'the CI-failure kinds' the round_kind
// mapping rule buckets into 'ci' (every kind starting 'ci-').
if (result.escalations[0].round_kind !== 'ci')
  { console.log(JSON.stringify({ ok: false, reason: 'ci-failed round_kind must be ci, got: ' + result.escalations[0].round_kind })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 6: CI_POLL TIMEOUT loop — multiple TIMEOUT slices then CI_GREEN → parked
# TIMEOUT is NOT a failure; the loop continues until budget or resolution.
# ============================================================================
run_node_case "ci-poll TIMEOUT loop: multiple TIMEOUT slices then CI_GREEN → parked" "
$PREAMBLE

setMachinery('item-timeout',
  { outcome: 'CREATED', path: '/tmp/repo.wt/item-timeout' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'a5a' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'a5a', branch: 'build/item-timeout' },
  { outcome: 'PR_OPENED', pr_number: 601 },
  { outcome: 'TIMEOUT' },
  { outcome: 'TIMEOUT' },
  { outcome: 'CI_GREEN' },
);
happyWorker('item-timeout');

globalThis.args = { ...baseArgs, items: [
  { slug: 'item-timeout', branch: 'build/item-timeout', title: 'Timeout Item', kind: 'impl' },
]};

const mod = await loadLevel();
const result = await mod.default();

if ((result.parked ?? []).length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 1 parked after timeout+green: ' + JSON.stringify(result) })); process.exit(0); }
if ((result.escalations ?? []).length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'TIMEOUT slices should not escalate: ' + JSON.stringify(result) })); process.exit(0); }
if (result.parked[0].pushed_sha !== 'a5a')
  { console.log(JSON.stringify({ ok: false, reason: 'pushed_sha wrong: ' + result.parked[0].pushed_sha })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 6b: NO_CI outcome → parked [m] with no_ci:true, NOT ci-failed (#605/#618)
# A zero-CI repo's head SHA resolves NO_CI on the --workflow machinery path; it must
# park like a green item (legible 'no CI configured' skip mirroring build.md 3g)
# carrying the no_ci sentinel, never fall through to the escalate-ci-failed
# catch-all.
# ============================================================================
run_node_case "no-ci: NO_CI outcome → parked with no_ci:true, no escalation (#618)" "
$PREAMBLE

setMachinery('item-noci',
  { outcome: 'CREATED', path: '/tmp/repo.wt/item-noci' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'a3f' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'a3f', branch: 'build/item-noci' },
  { outcome: 'PR_OPENED', pr_number: 618 },
  { outcome: 'NO_CI', pr: 618, sha: 'a3f', waited: 90 },
);
happyWorker('item-noci');

globalThis.args = { ...baseArgs, items: [
  { slug: 'item-noci', branch: 'build/item-noci', title: 'No-CI Item', kind: 'impl' },
]};

const mod = await loadLevel();
const result = await mod.default();

if ((result.escalations ?? []).length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'NO_CI must NOT escalate (regression: escalate-ci-failed catch-all): ' + JSON.stringify(result) })); process.exit(0); }
if ((result.parked ?? []).length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 1 parked for NO_CI: ' + JSON.stringify(result) })); process.exit(0); }
if (result.parked[0].pr !== 618)
  { console.log(JSON.stringify({ ok: false, reason: 'parked pr wrong: ' + JSON.stringify(result.parked[0]) })); process.exit(0); }
if (result.parked[0].pushed_sha !== 'a3f')
  { console.log(JSON.stringify({ ok: false, reason: 'parked pushed_sha wrong: ' + JSON.stringify(result.parked[0]) })); process.exit(0); }
if (result.parked[0].no_ci !== true)
  { console.log(JSON.stringify({ ok: false, reason: 'NO_CI item must carry no_ci:true sentinel: ' + JSON.stringify(result.parked[0]) })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 7: claim-conflict → claim-conflict escalation (board ON, ghIssue set)
# ============================================================================
run_node_case "claim-conflict: CLAIM_CONFLICT → claim-conflict escalation" "
$PREAMBLE

// Board ON + ghIssue → claim machinery fires first (before worktree.sh).
// Label: 'claim:item-conflict'
setMachinery('item-conflict',
  { outcome: 'CLAIM_CONFLICT' }
);

globalThis.args = { ...baseArgs, board: 3, claimCmd: '/fake/claim.sh', items: [
  { slug: 'item-conflict', branch: 'build/item-conflict', title: 'Conflict Item', kind: 'impl', ghIssue: 99 },
]};

const mod = await loadLevel();
const result = await mod.default();

if ((result.escalations ?? []).length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 1 escalation: ' + JSON.stringify(result) })); process.exit(0); }
if (result.escalations[0].kind !== 'claim-conflict')
  { console.log(JSON.stringify({ ok: false, reason: 'escalation kind wrong: ' + result.escalations[0].kind })); process.exit(0); }
if ((result.parked ?? []).length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 0 parked: ' + JSON.stringify(result) })); process.exit(0); }
// temperloop#2135: 'claim-conflict' is one of the ~25 singleton kinds the
// round_kind mapping deliberately does NOT enumerate — it must fall through
// to the catch-all 'other', proving the catch-all actually fires rather than
// every kind silently landing in a named bucket.
if (result.escalations[0].round_kind !== 'other')
  { console.log(JSON.stringify({ ok: false, reason: 'claim-conflict round_kind must be the other catch-all, got: ' + result.escalations[0].round_kind })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 8: push-rejected → push-rejected escalation
# ============================================================================
run_node_case "push-rejected: PUSH_REJECTED → push-rejected escalation" "
$PREAMBLE

setMachinery('item-rejected',
  { outcome: 'CREATED', path: '/tmp/repo.wt/item-rejected' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'a4d' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSH_REJECTED', error: 'non-fast-forward' },
);
happyWorker('item-rejected');

globalThis.args = { ...baseArgs, items: [
  { slug: 'item-rejected', branch: 'build/item-rejected', title: 'Rejected Item', kind: 'impl' },
]};

const mod = await loadLevel();
const result = await mod.default();

if ((result.escalations ?? []).length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 1 escalation: ' + JSON.stringify(result) })); process.exit(0); }
if (result.escalations[0].kind !== 'push-rejected')
  { console.log(JSON.stringify({ ok: false, reason: 'escalation kind wrong: ' + result.escalations[0].kind })); process.exit(0); }
if ((result.parked ?? []).length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 0 parked: ' + JSON.stringify(result) })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 8b (temperloop#1688): PUSHED_UNWATCHED → its OWN escalation kind
# ============================================================================
# The push LANDED — on a ref no open PR watches, while the item's PR sits on a
# different head ref. It must NOT ride 'push-error' (which reads as "the push
# failed / its result was lost") and must NOT proceed to pr-open + CI-poll: that
# is the route by which a stale PR head's green checks become a false CI_GREEN
# for content that is not what would merge (#254 by a new path). The escalation
# payload has to carry the PR's real head ref, since that is the whole fix.
run_node_case "push-unwatched (#1688): PUSHED_UNWATCHED → push-unwatched-branch escalation, no PR opened" "
$PREAMBLE

setMachinery('item-unwatched',
  { outcome: 'CREATED', path: '/tmp/repo.wt/item-unwatched' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'a4d' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED_UNWATCHED', sha: 'a4d', branch: 'build/item-unwatched', forced: true,
    pr_lookup: 'ok', pr_number: 1404, pr_head_ref: 'fix/item-unwatched',
    stale_head_cause: 'branch-mismatch', error: 'no open PR references build/item-unwatched' },
);
happyWorker('item-unwatched');

globalThis.args = { ...baseArgs, items: [
  { slug: 'item-unwatched', branch: 'build/item-unwatched', title: 'Unwatched Item', kind: 'impl' },
]};

const mod = await loadLevel();
const result = await mod.default();

if ((result.escalations ?? []).length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 1 escalation: ' + JSON.stringify(result) })); process.exit(0); }
if (result.escalations[0].kind !== 'push-unwatched-branch')
  { console.log(JSON.stringify({ ok: false, reason: 'escalation kind wrong: ' + result.escalations[0].kind })); process.exit(0); }
if (result.escalations[0].payload?.pushOut?.pr_head_ref !== 'fix/item-unwatched')
  { console.log(JSON.stringify({ ok: false, reason: 'payload lost the PR head ref: ' + JSON.stringify(result.escalations[0].payload) })); process.exit(0); }
if ((result.parked ?? []).length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 0 parked (no PR must be opened): ' + JSON.stringify(result) })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 9: scan-blocked → closing-keyword escalation
# ============================================================================
run_node_case "scan-blocked: SCAN_BLOCKED → closing-keyword escalation" "
$PREAMBLE

setMachinery('item-scan',
  { outcome: 'CREATED', path: '/tmp/repo.wt/item-scan' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'aca58' },
  { outcome: 'SCAN_BLOCKED', matches: ['Closes #42'] },
);
happyWorker('item-scan');

globalThis.args = { ...baseArgs, items: [
  { slug: 'item-scan', branch: 'build/item-scan', title: 'Scan Blocked Item', kind: 'impl' },
]};

const mod = await loadLevel();
const result = await mod.default();

if ((result.escalations ?? []).length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 1 escalation: ' + JSON.stringify(result) })); process.exit(0); }
if (result.escalations[0].kind !== 'closing-keyword')
  { console.log(JSON.stringify({ ok: false, reason: 'escalation kind wrong: ' + result.escalations[0].kind })); process.exit(0); }
if ((result.parked ?? []).length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 0 parked: ' + JSON.stringify(result) })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 9b: rebase-conflict → rebase-conflict escalation (#525)
# The 3f rebase onto fresh origin/<default> conflicts; pr.sh has already
# aborted (clean worktree). build-level escalates rebase-conflict — never a
# silent revert — and the scan/push never run (the level item escalates).
# ============================================================================
run_node_case "rebase-conflict: REBASE_CONFLICT → rebase-conflict escalation (#525)" "
$PREAMBLE

setMachinery('item-rb',
  { outcome: 'CREATED', path: '/tmp/repo.wt/item-rb' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASE_CONFLICT', base: 'b', tip: 't', error: 'CONFLICT (content): shared.txt' },
  // No SCAN/PUSH entries: if the machinery advanced past the conflict it would
  // consume an unexpected entry and desync — guarding that the escalation
  // halts the item at the rebase boundary.
);
happyWorker('item-rb');

globalThis.args = { ...baseArgs, items: [
  { slug: 'item-rb', branch: 'build/item-rb', title: 'Rebase Conflict Item', kind: 'impl' },
]};

const mod = await loadLevel();
const result = await mod.default();

if ((result.escalations ?? []).length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 1 escalation: ' + JSON.stringify(result) })); process.exit(0); }
if (result.escalations[0].kind !== 'rebase-conflict')
  { console.log(JSON.stringify({ ok: false, reason: 'escalation kind wrong: ' + result.escalations[0].kind })); process.exit(0); }
if ((result.parked ?? []).length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 0 parked: ' + JSON.stringify(result) })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 9c: DIRTY_WORKTREE → dirty-worktree escalation (temperloop#735)
# The finished-worker case: pr.sh reports base == tip (no rebase was needed)
# and a tracked file left uncommitted. That is NOT a conflict, so it must NOT
# escalate as rebase-conflict — whose discard-and-respawn disposition would
# throw the finished work away. It gets its own kind, and the payload keeps the
# base==tip / dirty_paths evidence so the disposition can be 'commit and
# re-drive'. The scan/push still never run.
# ============================================================================
run_node_case "dirty-worktree: DIRTY_WORKTREE → dirty-worktree escalation (temperloop#735)" "
$PREAMBLE

setMachinery('item-dw',
  { outcome: 'CREATED', path: '/tmp/repo.wt/item-dw' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'DIRTY_WORKTREE', base: 'x', tip: 'x', rebase_needed: false,
    dirty_files: 1, dirty_paths: [' M workflows/scripts/config/setting-registry.tsv'] },
  // No SCAN/PUSH entries — same desync guard as 9b: the item must halt here.
);
happyWorker('item-dw');

globalThis.args = { ...baseArgs, items: [
  { slug: 'item-dw', branch: 'build/item-dw', title: 'Dirty Worktree Item', kind: 'impl' },
]};

const mod = await loadLevel();
const result = await mod.default();

if ((result.escalations ?? []).length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 1 escalation: ' + JSON.stringify(result) })); process.exit(0); }
if (result.escalations[0].kind !== 'dirty-worktree')
  { console.log(JSON.stringify({ ok: false, reason: 'escalation kind wrong: ' + result.escalations[0].kind })); process.exit(0); }
if (result.escalations[0].payload?.rebaseOut?.dirty_paths?.length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'dirty_paths evidence not carried into the payload' })); process.exit(0); }
if ((result.parked ?? []).length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 0 parked: ' + JSON.stringify(result) })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 10: spike kind — skip push/PR/CI, park with null pr/pushed_sha
# ============================================================================
run_node_case "spike kind: spike items park with null pr/pushed_sha (no push/PR/CI)" "
$PREAMBLE

// Spike path: worker is called directly (no machinery calls).
// machineryMap for 'spike-item' is intentionally empty — any machinery call is an error.
setMachinery('spike-item' /* empty — no calls expected */);
setWorker('spike-item',
  { status: 'done', summary: 'spike verdict produced', acceptance_results: [{ criterion: 'verdict-written', passed: true, evidence: 'v.md' }], verification_surface_path: '/tmp/verdict.md' }
);

globalThis.args = { ...baseArgs, items: [
  { slug: 'spike-item', branch: 'build/spike-item', title: 'Spike Item', kind: 'spike', acceptance: ['verdict-written'] },
]};

const initialMachinerySize = (machineryMap.get('spike-item') || []).length;

const mod = await loadLevel();
const result = await mod.default();

if ((result.parked ?? []).length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 1 parked: ' + JSON.stringify(result) })); process.exit(0); }
if ((result.escalations ?? []).length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'unexpected escalation: ' + JSON.stringify(result) })); process.exit(0); }

const sp = result.parked[0];
if (sp.pr !== null)
  { console.log(JSON.stringify({ ok: false, reason: 'spike pr should be null: ' + sp.pr })); process.exit(0); }
if (sp.pushed_sha !== null)
  { console.log(JSON.stringify({ ok: false, reason: 'spike pushed_sha should be null: ' + sp.pushed_sha })); process.exit(0); }

// Verify no machinery calls were made for the spike item
const machineryCallsForSpike = callLog.filter(c => c.opts.schema && (c.opts.label||'').includes('spike-item'));
if (machineryCallsForSpike.length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'spike made machinery calls: ' + JSON.stringify(machineryCallsForSpike.map(c=>c.opts.label)) })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 10b: spike claim-first (temperloop#650) — a board-ON spike claims its
# issue (3a) BEFORE the read-only verdict fork spawns its worker. Guards the
# regression where the kind:spike branch returned via park ahead of the 3a
# claim, leaving a spike un-claimed and racing two concurrent drivers.
# ============================================================================
run_node_case "spike claim-first: 3a claim precedes the spike verdict-worker (#650)" "
$PREAMBLE

// Claim machinery call for the spike returns CLAIMED (board ON, ghIssue present).
setMachinery('spike-claim', { outcome: 'CLAIMED' });
setWorker('spike-claim',
  { status: 'done', summary: 'spike verdict produced', acceptance_results: [{ criterion: 'verdict-written', passed: true, evidence: 'v.md' }], verification_surface_path: '/tmp/verdict.md' }
);

globalThis.args = { ...baseArgs, board: 3, claimCmd: '/fake/claim.sh', items: [
  { slug: 'spike-claim', branch: 'build/spike-claim', title: 'Spike Claim', kind: 'spike', ghIssue: '650', acceptance: ['verdict-written'] },
]};

const mod = await loadLevel();
const result = await mod.default();

// Parks (spike verdict), no escalation.
if ((result.parked ?? []).length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 1 parked: ' + JSON.stringify(result) })); process.exit(0); }
if ((result.escalations ?? []).length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'unexpected escalation: ' + JSON.stringify(result) })); process.exit(0); }

// Ordering assertion: the claim MUST run before the worker. The claim now rides
// the batched prelude executor (temperloop#942), so assert on the prelude call
// and on the step the mock actually ran inside it.
const claimIdx = callLog.findIndex(c => (c.opts.label||'') === 'prelude:spike-claim');
const workerIdx = callLog.findIndex(c => (c.opts.label||'') === 'worker:spike-claim');
if (claimIdx === -1)
  { console.log(JSON.stringify({ ok: false, reason: 'no prelude (claim) call for spike: ' + JSON.stringify(callLog.map(c=>c.opts.label)) })); process.exit(0); }
if (workerIdx === -1)
  { console.log(JSON.stringify({ ok: false, reason: 'no worker call for spike: ' + JSON.stringify(callLog.map(c=>c.opts.label)) })); process.exit(0); }
if (!(claimIdx < workerIdx))
  { console.log(JSON.stringify({ ok: false, reason: 'claim did not precede worker: claimIdx=' + claimIdx + ' workerIdx=' + workerIdx })); process.exit(0); }
// A SPIKE's prelude is the claim ALONE — it must never create a worktree.
if (JSON.stringify(stepsRun('spike-claim')) !== JSON.stringify(['claim']))
  { console.log(JSON.stringify({ ok: false, reason: 'spike prelude steps wrong (expected [claim]): ' + JSON.stringify(stepsRun('spike-claim')) })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 11: gate-fail → acceptance-gate-failed escalation
# ============================================================================
run_node_case "gate-fail: GATE_FAIL → acceptance-gate-failed escalation" "
$PREAMBLE

setMachinery('item-gate',
  { outcome: 'CREATED', path: '/tmp/repo.wt/item-gate' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_FAIL', detail: 'mypy found type errors' },
);
happyWorker('item-gate');

globalThis.args = { ...baseArgs, items: [
  { slug: 'item-gate', branch: 'build/item-gate', title: 'Gate Fail Item', kind: 'impl' },
]};

const mod = await loadLevel();
const result = await mod.default();

if ((result.escalations ?? []).length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 1 escalation: ' + JSON.stringify(result) })); process.exit(0); }
if (result.escalations[0].kind !== 'acceptance-gate-failed')
  { console.log(JSON.stringify({ ok: false, reason: 'escalation kind wrong: ' + result.escalations[0].kind })); process.exit(0); }
if ((result.parked ?? []).length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 0 parked: ' + JSON.stringify(result) })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TESTS (temperloop#1937): pre-§3e.5 gate-freshness rebase.
#
# §3e.5's validate-check-surface-degenerate-coverage.sh / validate-exec-bit-
# registry.sh / validate-mandatory-step-signal.sh ratchet against origin/main;
# a worktree that fell behind main mid-build reads rows main gained as its OWN
# regression. driveItem now runs a pre-gate freshness step (runGateFreshness /
# gateFreshnessCmd) strictly before the gate that fetches origin and rebases
# onto origin/main when behind. It keeps its OWN mock queue (freshnessMap,
# `setFreshness()`) rather than the shared per-slug machineryMap FIFO, so the
# hundred-plus EXISTING tests above (none of which model a stale worktree)
# need no changes — see freshnessMap's own comment for why sharing the queue
# would desync every one of them.
# ============================================================================
run_node_case "freshness-rebased (temperloop#1937): worktree behind main rebases cleanly and reaches the gate on the rebased tree" "
$PREAMBLE

setFreshness('item-fresh-reb', { outcome: 'FRESHNESS_REBASED', worktree_base: 'reb-sha', main: 'main-sha' });
setMachinery('item-fresh-reb',
  { outcome: 'CREATED', path: '/tmp/repo.wt/item-fresh-reb' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'a44' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'a44', branch: 'build/item-fresh-reb' },
  { outcome: 'PR_OPENED', pr_number: 501 },
  { outcome: 'CI_GREEN' },
);
happyWorker('item-fresh-reb');

globalThis.args = { ...baseArgs, items: [
  { slug: 'item-fresh-reb', branch: 'build/item-fresh-reb', title: 'Freshness Rebased Item', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();

if ((result.parked ?? []).length !== 1 || (result.escalations ?? []).length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 1 parked / 0 escalations: ' + JSON.stringify(result) })); process.exit(0); }
if (result.parked[0].pr !== 501)
  { console.log(JSON.stringify({ ok: false, reason: 'wrong PR parked (gate must have run on the rebased tree): ' + JSON.stringify(result.parked[0]) })); process.exit(0); }
const freshIdx = callLog.findIndex(c => (c.opts.label||'').startsWith('gate-freshness:item-fresh-reb'));
const gateIdx = callLog.findIndex(c => (c.opts.label||'') === 'gate:item-fresh-reb');
if (freshIdx === -1 || gateIdx === -1 || !(freshIdx < gateIdx))
  { console.log(JSON.stringify({ ok: false, reason: 'freshness call missing or not before the gate call: fresh=' + freshIdx + ' gate=' + gateIdx })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

run_node_case "freshness-conflict (temperloop#1937): a rebase conflict escalates stale-worktree — never acceptance-gate-failed — and the gate never runs" "
$PREAMBLE

setFreshness('item-fresh-conf', { outcome: 'FRESHNESS_CONFLICT', main: 'main-sha', conflict_files: ['a.txt', 'b.txt'], detail: 'CONFLICT (content): Merge conflict in a.txt', disposition: 'rebase aborted; worktree left intact on its pre-rebase commit' });
setMachinery('item-fresh-conf',
  { outcome: 'CREATED', path: '/tmp/repo.wt/item-fresh-conf' },
  { outcome: 'REVIEW_DIFF' },
  // Deliberately NO gate/pr/CI entries queued: if the driver mistakenly ran
  // past the conflict it would hit the 'unexpected machinery call' default,
  // which the assertions below (escalation kind + zero gate calls) catch
  // either way.
);
happyWorker('item-fresh-conf');

globalThis.args = { ...baseArgs, items: [
  { slug: 'item-fresh-conf', branch: 'build/item-fresh-conf', title: 'Freshness Conflict Item', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();

if ((result.parked ?? []).length !== 0 || (result.escalations ?? []).length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 0 parked / 1 escalation: ' + JSON.stringify(result) })); process.exit(0); }
const esc = result.escalations[0];
if (esc.kind !== 'stale-worktree')
  { console.log(JSON.stringify({ ok: false, reason: 'escalation kind must be stale-worktree, never acceptance-gate-failed: got ' + esc.kind })); process.exit(0); }
if (JSON.stringify(esc.payload.conflict_files) !== JSON.stringify(['a.txt','b.txt']))
  { console.log(JSON.stringify({ ok: false, reason: 'payload must name the conflicting files: ' + JSON.stringify(esc.payload) })); process.exit(0); }
if (!/aborted/i.test(String(esc.payload.disposition || '')))
  { console.log(JSON.stringify({ ok: false, reason: 'payload must name the rebase disposition: ' + JSON.stringify(esc.payload) })); process.exit(0); }
if (!esc.payload.detail || !/conflict/i.test(String(esc.payload.detail)))
  { console.log(JSON.stringify({ ok: false, reason: 'round 3: payload must carry git\\'s own rebase output tail as detail: ' + JSON.stringify(esc.payload) })); process.exit(0); }
const gateCalls = callLog.filter(c => (c.opts.label||'') === 'gate:item-fresh-conf').length;
if (gateCalls !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'the gate must never run on a conflicting rebase, but it ran ' + gateCalls + ' time(s)' })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

run_node_case "freshness-current (temperloop#1937): a worktree already at/ahead of main takes the byte-identical pre-#1937 path — one freshness check, no extra rebase spawn" "
$PREAMBLE

happyMachinery('item-fresh-cur', 601, 'ac14');
happyWorker('item-fresh-cur');
// No setFreshness() call — the default (FRESHNESS_CURRENT) models the common
// case every pre-#1937 test above already exercises, unchanged.

globalThis.args = { ...baseArgs, items: [
  { slug: 'item-fresh-cur', branch: 'build/item-fresh-cur', title: 'Freshness Current Item', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();

if ((result.parked ?? []).length !== 1 || (result.escalations ?? []).length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 1 parked / 0 escalations: ' + JSON.stringify(result) })); process.exit(0); }
// Exactly ONE freshness-labeled call — never a second spawn to re-check or
// re-rebase once the tree is known current.
const freshCalls = callLog.filter(c => (c.opts.label||'').startsWith('gate-freshness:item-fresh-cur')).length;
if (freshCalls !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'expected exactly 1 freshness call, got ' + freshCalls })); process.exit(0); }
// The gate call itself still ran on its own byte-identical slot — the 8-step
// happyMachinery() sequence needed NO changes for this, the common, case.
const gateCalls = callLog.filter(c => (c.opts.label||'') === 'gate:item-fresh-cur').length;
if (gateCalls !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'expected exactly 1 gate call, got ' + gateCalls })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

run_node_case "freshness-dirty (temperloop#1937 round 2, HIGH): a dirty tree never attempts the rebase — routes to dirty-worktree, never stale-worktree with an empty conflict list" "
$PREAMBLE

setFreshness('item-fresh-dirty', { outcome: 'FRESHNESS_DIRTY', main: 'main-sha', dirty_paths: [' M worker.txt'] });
setMachinery('item-fresh-dirty',
  { outcome: 'CREATED', path: '/tmp/repo.wt/item-fresh-dirty' },
  { outcome: 'REVIEW_DIFF' },
  // Deliberately NO gate/pr/CI entries queued — if the driver mistakenly ran
  // past the dirty check it would hit the 'unexpected machinery call'
  // default, which the assertions below (escalation kind + zero gate calls)
  // catch either way.
);
happyWorker('item-fresh-dirty');

globalThis.args = { ...baseArgs, items: [
  { slug: 'item-fresh-dirty', branch: 'build/item-fresh-dirty', title: 'Freshness Dirty Item', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();

if ((result.parked ?? []).length !== 0 || (result.escalations ?? []).length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 0 parked / 1 escalation: ' + JSON.stringify(result) })); process.exit(0); }
const esc = result.escalations[0];
if (esc.kind !== 'dirty-worktree')
  { console.log(JSON.stringify({ ok: false, reason: 'a dirty tree must escalate dirty-worktree, never stale-worktree: got ' + esc.kind })); process.exit(0); }
if (esc.kind === 'stale-worktree' && JSON.stringify(esc.payload.conflict_files || []) === '[]')
  { console.log(JSON.stringify({ ok: false, reason: 'must never be the stale-worktree-with-empty-conflict-list misclassification' })); process.exit(0); }
const gateCalls = callLog.filter(c => (c.opts.label||'') === 'gate:item-fresh-dirty').length;
if (gateCalls !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'the gate must never run on a dirty tree, but it ran ' + gateCalls + ' time(s)' })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

run_node_case "freshness-timeout (temperloop#1937 round 2, MEDIUM): the outer Bash-tool timeout probes for and aborts an in-progress rebase, then ALWAYS escalates stale-worktree — never the fail-open FRESHNESS_ERROR path" "
$PREAMBLE

// Two queued freshnessMap entries, consumed in order by the SAME
// 'gate-freshness:<slug>' label: the first call is killed by the outer
// Bash-tool timeout (FRESHNESS_TIMEOUT); runGateFreshness's own timeout arm
// then issues a SECOND gate-freshness call (the follow-up probe), which finds
// and aborts an in-progress rebase.
setFreshness('item-fresh-to',
  { outcome: 'FRESHNESS_TIMEOUT' },
  { outcome: 'FRESHNESS_TIMEOUT_PROBE', rebase_in_progress: true, aborted: true },
);
setMachinery('item-fresh-to',
  { outcome: 'CREATED', path: '/tmp/repo.wt/item-fresh-to' },
  { outcome: 'REVIEW_DIFF' },
  // No gate/pr/CI entries — the gate must never run.
);
happyWorker('item-fresh-to');

globalThis.args = { ...baseArgs, items: [
  { slug: 'item-fresh-to', branch: 'build/item-fresh-to', title: 'Freshness Timeout Item', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();

if ((result.parked ?? []).length !== 0 || (result.escalations ?? []).length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 0 parked / 1 escalation: ' + JSON.stringify(result) })); process.exit(0); }
const esc = result.escalations[0];
if (esc.kind !== 'stale-worktree')
  { console.log(JSON.stringify({ ok: false, reason: 'an outer freshness timeout must escalate stale-worktree, never fail open: got ' + esc.kind })); process.exit(0); }
if (esc.payload.reason !== 'timeout' || esc.payload.rebase_in_progress !== true || esc.payload.aborted !== true)
  { console.log(JSON.stringify({ ok: false, reason: 'payload must name the timeout reason and the probe verdict (snake_case): ' + JSON.stringify(esc.payload) })); process.exit(0); }
const freshCalls = callLog.filter(c => (c.opts.label||'').startsWith('gate-freshness:item-fresh-to')).length;
if (freshCalls !== 2)
  { console.log(JSON.stringify({ ok: false, reason: 'expected exactly 2 gate-freshness calls (the timed-out attempt + the follow-up probe), got ' + freshCalls })); process.exit(0); }
const gateCalls = callLog.filter(c => (c.opts.label||'') === 'gate:item-fresh-to').length;
if (gateCalls !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'the gate must never run after an outer freshness timeout, but it ran ' + gateCalls + ' time(s)' })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

run_node_case "freshness-error (temperloop#1937): the fetch/resolve step itself failing (FRESHNESS_ERROR) fails OPEN — proceeds to the gate on the tree as-is, exactly the pre-#1937 behavior" "
$PREAMBLE

setFreshness('item-fresh-err', { outcome: 'FRESHNESS_ERROR', detail: 'git fetch origin main failed' });
happyMachinery('item-fresh-err', 701, 'ae1e');
happyWorker('item-fresh-err');

globalThis.args = { ...baseArgs, items: [
  { slug: 'item-fresh-err', branch: 'build/item-fresh-err', title: 'Freshness Error Item', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();

if ((result.parked ?? []).length !== 1 || (result.escalations ?? []).length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'FRESHNESS_ERROR must fail OPEN (1 parked / 0 escalations), got: ' + JSON.stringify(result) })); process.exit(0); }
if (result.parked[0].pr !== 701)
  { console.log(JSON.stringify({ ok: false, reason: 'wrong PR parked: ' + JSON.stringify(result.parked[0]) })); process.exit(0); }
const gateCalls = callLog.filter(c => (c.opts.label||'') === 'gate:item-fresh-err').length;
if (gateCalls !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'the gate must still run once on a fail-open FRESHNESS_ERROR, got ' + gateCalls })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

run_node_case "freshness-step-timeout (temperloop#1937 round 2 coverage gap): the INNER wall-clock watchdog (STEP_TIMEOUT) on the gate-freshness step routes through the existing disposeStepTimeout recover-probe, never fails open, never runs the gate" "
$PREAMBLE

setFreshness('item-fresh-stto', { outcome: 'STEP_TIMEOUT', step: 'gate-freshness', ceiling_secs: 900, elapsed_secs: 901 });
setMachinery('item-fresh-stto',
  { outcome: 'CREATED', path: '/tmp/repo.wt/item-fresh-stto' },
  { outcome: 'REVIEW_DIFF' },
  noSideEffects(),
);
happyWorker('item-fresh-stto');

globalThis.args = { ...baseArgs, items: [
  { slug: 'item-fresh-stto', branch: 'build/item-fresh-stto', title: 'Freshness Step-Timeout Item', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();

if ((result.parked ?? []).length !== 0 || (result.escalations ?? []).length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 0 parked / 1 escalation: ' + JSON.stringify(result) })); process.exit(0); }
const esc = result.escalations[0];
if (esc.kind !== 'machinery-step-timeout')
  { console.log(JSON.stringify({ ok: false, reason: 'an inner STEP_TIMEOUT on gate-freshness must escalate machinery-step-timeout: got ' + esc.kind })); process.exit(0); }
if (esc.payload.where !== 'gate-freshness')
  { console.log(JSON.stringify({ ok: false, reason: 'payload must name gate-freshness as the timed-out step: ' + JSON.stringify(esc.payload) })); process.exit(0); }
if (!callLog.some(c => c.opts.label === 'recover-probe:item-fresh-stto'))
  { console.log(JSON.stringify({ ok: false, reason: 'disposal must go through the EXISTING pr.sh recover-probe path, never a bespoke one' })); process.exit(0); }
const gateCalls = callLog.filter(c => (c.opts.label||'') === 'gate:item-fresh-stto').length;
if (gateCalls !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'the gate must never run after a bounded-out freshness step, but it ran ' + gateCalls + ' time(s)' })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# ROUND 3 (temperloop#1937): review-blocking findings — no-gate presence gate,
# non-conflict rebase failures, and the probe-outcome trust boundary.
# ============================================================================
run_node_case "freshness-no-gate (temperloop#1937 round 3, HIGH): a project with no vendored quality-gates.sh takes the byte-identical pre-change path — one freshness check, no extra spawn, the gate call independently reports GATE_ABSENT" "
$PREAMBLE

setFreshness('item-fresh-nogate', { outcome: 'FRESHNESS_NO_GATE' });
setMachinery('item-fresh-nogate',
  { outcome: 'CREATED', path: '/tmp/repo.wt/item-fresh-nogate' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_ABSENT' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'aae41' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'aae41', branch: 'build/item-fresh-nogate' },
  { outcome: 'PR_OPENED', pr_number: 801 },
  { outcome: 'CI_GREEN' },
);
happyWorker('item-fresh-nogate');

globalThis.args = { ...baseArgs, items: [
  { slug: 'item-fresh-nogate', branch: 'build/item-fresh-nogate', title: 'Freshness No-Gate Item', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();

if ((result.parked ?? []).length !== 1 || (result.escalations ?? []).length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'a no-gate project must fail open all the way to parked: ' + JSON.stringify(result) })); process.exit(0); }
const freshCalls = callLog.filter(c => (c.opts.label||'').startsWith('gate-freshness:item-fresh-nogate')).length;
if (freshCalls !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'expected exactly 1 freshness call (no extra spawn for a no-gate project), got ' + freshCalls })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

run_node_case "freshness-rebase-error (temperloop#1937 round 3, MEDIUM): a rebase failure with NO conflicted files is its own not-a-conflict outcome — never misread as FRESHNESS_CONFLICT's empty-list shape — and carries git's output as detail" "
$PREAMBLE

setFreshness('item-fresh-rberr', { outcome: 'FRESHNESS_REBASE_ERROR', main: 'main-sha', detail: 'error: cannot rebase: Your local changes would be overwritten (pre-rebase hook)', disposition: 'rebase failed for a reason other than a content conflict; rebase aborted, worktree left intact on its pre-rebase commit' });
setMachinery('item-fresh-rberr',
  { outcome: 'CREATED', path: '/tmp/repo.wt/item-fresh-rberr' },
  { outcome: 'REVIEW_DIFF' },
  // Deliberately no gate/pr/CI entries — the gate must never run.
);
happyWorker('item-fresh-rberr');

globalThis.args = { ...baseArgs, items: [
  { slug: 'item-fresh-rberr', branch: 'build/item-fresh-rberr', title: 'Freshness Rebase-Error Item', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();

if ((result.parked ?? []).length !== 0 || (result.escalations ?? []).length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 0 parked / 1 escalation: ' + JSON.stringify(result) })); process.exit(0); }
const esc = result.escalations[0];
if (esc.kind !== 'stale-worktree')
  { console.log(JSON.stringify({ ok: false, reason: 'a non-conflict rebase failure must still escalate stale-worktree (the base is still what is wrong): got ' + esc.kind })); process.exit(0); }
if (JSON.stringify(esc.payload.conflict_files || []) !== '[]')
  { console.log(JSON.stringify({ ok: false, reason: 'a non-conflict failure must never fabricate conflict files: ' + JSON.stringify(esc.payload) })); process.exit(0); }
if (!esc.payload.detail || !/pre-rebase hook/.test(String(esc.payload.detail)))
  { console.log(JSON.stringify({ ok: false, reason: 'payload must carry git\\'s own output as detail: ' + JSON.stringify(esc.payload) })); process.exit(0); }
if (esc.payload.reason !== 'rebase-failed')
  { console.log(JSON.stringify({ ok: false, reason: 'payload must name this a non-conflict rebase failure, distinct from a real conflict: ' + JSON.stringify(esc.payload) })); process.exit(0); }
const gateCalls = callLog.filter(c => (c.opts.label||'') === 'gate:item-fresh-rberr').length;
if (gateCalls !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'the gate must never run on an unresolved rebase failure, but it ran ' + gateCalls + ' time(s)' })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

run_node_case "freshness-probe-unknown (temperloop#1937 round 3, MEDIUM): when the follow-up timeout-probe ITSELF fails to resolve, the disposition reports the rebase state as UNKNOWN rather than confidently asserting nothing was in progress" "
$PREAMBLE

// First call: the outer Bash-tool timeout. Second call (the follow-up probe):
// the probe's OWN outer timeout — FRESHNESS_TIMEOUT_PROBE_ERROR, never
// FRESHNESS_TIMEOUT_PROBE — so rebase_in_progress/aborted are simply ABSENT
// from this outcome, not false.
setFreshness('item-fresh-punk',
  { outcome: 'FRESHNESS_TIMEOUT' },
  { outcome: 'FRESHNESS_TIMEOUT_PROBE_ERROR' },
);
setMachinery('item-fresh-punk',
  { outcome: 'CREATED', path: '/tmp/repo.wt/item-fresh-punk' },
  { outcome: 'REVIEW_DIFF' },
);
happyWorker('item-fresh-punk');

globalThis.args = { ...baseArgs, items: [
  { slug: 'item-fresh-punk', branch: 'build/item-fresh-punk', title: 'Freshness Probe-Unknown Item', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();

if ((result.parked ?? []).length !== 0 || (result.escalations ?? []).length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 0 parked / 1 escalation: ' + JSON.stringify(result) })); process.exit(0); }
const esc = result.escalations[0];
if (esc.kind !== 'stale-worktree')
  { console.log(JSON.stringify({ ok: false, reason: 'a probe that itself fails to resolve must still escalate stale-worktree: got ' + esc.kind })); process.exit(0); }
if (esc.payload.rebase_in_progress !== null || esc.payload.aborted !== null)
  { console.log(JSON.stringify({ ok: false, reason: 'an unresolved probe must report the rebase state as UNKNOWN (null), never confidently false: ' + JSON.stringify(esc.payload) })); process.exit(0); }
if (!/unknown/i.test(String(esc.payload.disposition || '')))
  { console.log(JSON.stringify({ ok: false, reason: 'disposition must say the rebase state is unknown, not assert nothing was in progress: ' + JSON.stringify(esc.payload) })); process.exit(0); }
const gateCalls = callLog.filter(c => (c.opts.label||'') === 'gate:item-fresh-punk').length;
if (gateCalls !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'the gate must never run after an unresolved freshness timeout probe, but it ran ' + gateCalls + ' time(s)' })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# Static guard: the freshness step must run BEFORE the §3e.5 gate call in
# driveItem — mirrors the K1219 ordering guard's shape exactly (grep the two
# call sites' own line numbers rather than re-deriving order at runtime).
# `|| true` inside each substitution (round 2, shell-reviewer MEDIUM): under
# `set -e`/`pipefail` a grep MISS here is a non-zero exit that would abort the
# whole script before the `[ -n ]` guard below ever gets to report it
# legibly — the fallthrough to empty is what lets that guard actually fire.
K1937_FRESH_LINE="$(grep -n 'const freshness = await runGateFreshness(item, wt, qgBin);' "$MJS" | head -1 | cut -d: -f1 || true)"
K1937_GATE_LINE="$(grep -n 'gateOut = await runMachinery(gateCmd(gateStartAt, gateSelection), {' "$MJS" | head -1 | cut -d: -f1 || true)"
[ -n "$K1937_FRESH_LINE" ] || fail "#1937: could not locate the pre-gate freshness call site in driveItem"
[ -n "$K1937_GATE_LINE" ] || fail "#1937: could not locate the §3e.5 gate call site in driveItem"
[ "$K1937_FRESH_LINE" -lt "$K1937_GATE_LINE" ] \
  || fail "#1937: the pre-gate freshness step must run BEFORE the §3e.5 gate call — an origin/main-ratcheted validator would false-fail on a stale worktree otherwise"
echo "PASS: #1937 ordering guard — the pre-gate freshness step runs strictly before the §3e.5 gate call in driveItem"

# ============================================================================
# TEST 11b: gate-timeout — 3e.5 gate executor prompt carries the long Bash-tool
#           timeout directive (temperloop#115). Without it the executor's Bash
#           tool defaults to 120s and SIGTERMs a >2min quality-gates suite →
#           false GATE_FAIL on every drive. The prompt directive is the fix; a
#           happy item must still park green (the directive doesn't disrupt flow).
# ============================================================================
run_node_case "gate-timeout: 3e.5 gate prompt carries the Bash-timeout directive (#115)" "
$PREAMBLE

happyMachinery('item-gto', 115, 'a2a');
happyWorker('item-gto');

// Wrap the mock agent to capture the FULL gate prompt (the shared callLog slices
// to 120 chars, which truncates before the directive; mirror the continuation
// case's full-prompt capture). Delegate every call to the original mock so machinery
// routing (GATE_PASS from happyMachinery) is unchanged.
let gatePromptSeen = null;
const origAgent = globalThis.agent;
globalThis.agent = async function(prompt, opts = {}) {
  if ((opts.label || '').startsWith('gate:item-gto')) gatePromptSeen = String(prompt);
  return origAgent(prompt, opts);
};

globalThis.args = { ...baseArgs, items: [
  { slug: 'item-gto', branch: 'build/item-gto', title: 'Gate Timeout Item', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();

// Happy path: the gate passed, so the item parks with no escalation — proof the
// timeout directive is additive and does not perturb the normal gate flow.
if ((result.parked ?? []).length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 1 parked: ' + JSON.stringify(result) })); process.exit(0); }
if ((result.escalations ?? []).length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 0 escalations: ' + JSON.stringify(result) })); process.exit(0); }

// The core regression: the gate executor prompt MUST carry the long Bash-tool
// timeout (temperloop#115) — both the numeric value and the 'timeout' framing.
// The VALUE is now DERIVED from the slice budget (temperloop#1021), not typed:
// the default 300s slice + 240s single-gate overrun headroom = 540000ms, still
// under the agent's 600000ms Bash cap.
if (!gatePromptSeen)
  { console.log(JSON.stringify({ ok: false, reason: 'gate agent call never observed' })); process.exit(0); }
if (!gatePromptSeen.includes('540000'))
  { console.log(JSON.stringify({ ok: false, reason: 'gate prompt missing the derived 540000 Bash timeout: ' + gatePromptSeen })); process.exit(0); }
if (!/timeout/i.test(gatePromptSeen))
  { console.log(JSON.stringify({ ok: false, reason: 'gate prompt missing timeout directive: ' + gatePromptSeen })); process.exit(0); }
// temperloop#1021: the prompt must ALSO name GATE_TIMEOUT as the answer when the
// Bash tool's timeout fires. Without it the executor picks the nearest
// failure-shaped enum member — GATE_FAIL — and a GREEN suite escalates as
// broken. That conflation is the dangerous half of #1021, not the wasted time.
if (!gatePromptSeen.includes('GATE_TIMEOUT'))
  { console.log(JSON.stringify({ ok: false, reason: '#1021: gate prompt does not name GATE_TIMEOUT for the Bash-timeout case: ' + gatePromptSeen })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 11c: gate-worktree — the 3e.5 acceptance gate must run the WORKTREE's copy
#           of quality-gates.sh, not repoRoot's (temperloop#626). quality-gates.sh
#           begins by cd'ing to its own REPO_ROOT (BASH_SOURCE/..); if the gate
#           ran repoRoot's copy, that cd would jump back to the MAIN checkout and
#           validate main's tree instead of the worker's changes — silently
#           defeating the intended `cd \$wt`. Resolving the script from the
#           worktree makes REPO_ROOT the worktree, so the gate validates the
#           worker's tree (matching CI on the PR's merge). Regression assert: the
#           gate command names the worktree's quality-gates.sh and NEVER the bare
#           repoRoot copy.
# ============================================================================
run_node_case "gate-worktree: 3e.5 gate runs the worktree's quality-gates.sh, not repoRoot's (#626)" "
$PREAMBLE

happyMachinery('item-qgwt', 626, 'a4c');
happyWorker('item-qgwt');

// Capture the FULL gate prompt (the shared callLog truncates to 120 chars,
// which cuts off the script path; mirror 11b's full-prompt capture). Delegate
// to the original mock so machinery routing (GATE_PASS from happyMachinery) is intact.
let gatePromptSeen = null;
const origAgent = globalThis.agent;
globalThis.agent = async function(prompt, opts = {}) {
  if ((opts.label || '').startsWith('gate:item-qgwt')) gatePromptSeen = String(prompt);
  return origAgent(prompt, opts);
};

globalThis.args = { ...baseArgs, items: [
  { slug: 'item-qgwt', branch: 'build/item-qgwt', title: 'Gate Worktree Item', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();

// Happy path: the gate passed, so the item parks with no escalation — the
// worktree-copy resolution must not perturb the normal gate flow.
if ((result.parked ?? []).length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 1 parked: ' + JSON.stringify(result) })); process.exit(0); }
if ((result.escalations ?? []).length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 0 escalations: ' + JSON.stringify(result) })); process.exit(0); }

if (!gatePromptSeen)
  { console.log(JSON.stringify({ ok: false, reason: 'gate agent call never observed' })); process.exit(0); }

// The mock repoRoot is '/tmp/repo'; the worktree (happyMachinery CREATED.path) is
// '/tmp/repo.wt/item-qgwt'. These two script paths are cleanly distinguishable
// (the char after '/tmp/repo' is '/' vs '.'), so the buggy repoRoot copy is not
// a substring of the correct worktree copy.
const repoRootQg = '/tmp/repo/scripts/quality-gates.sh';
const worktreeQg = '/tmp/repo.wt/item-qgwt/scripts/quality-gates.sh';

// CORE regression: the gate must invoke the worktree's copy…
if (!gatePromptSeen.includes(worktreeQg))
  { console.log(JSON.stringify({ ok: false, reason: 'gate does not run the worktree quality-gates.sh (' + worktreeQg + '): ' + gatePromptSeen })); process.exit(0); }
// …and must NEVER reference the bare repoRoot copy (whose cd \$REPO_ROOT would
// jump back to main and defeat the worktree validation).
if (gatePromptSeen.includes(repoRootQg))
  { console.log(JSON.stringify({ ok: false, reason: 'gate still references repoRoot quality-gates.sh (' + repoRootQg + '), which validates main not the worktree: ' + gatePromptSeen })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 11d (temperloop#1021): a gate TIMEOUT is NOT a gate FAILURE.
#   The dangerous half of #1021: a budget-exhausted 3e.5 run and a genuinely red
#   suite both collapsed to {"outcome":"GATE_FAIL"} → `acceptance-gate-failed`,
#   so an escalation payload could not be told apart from real breakage. A
#   GATE_TIMEOUT must escalate under its OWN kind, with a payload that says the
#   suite's verdict is UNKNOWN rather than implying the tree is broken.
# ============================================================================
run_node_case "1021 timeout: GATE_TIMEOUT → acceptance-gate-timeout (NOT acceptance-gate-failed)" "
$PREAMBLE

setMachinery('item-gt1021',
  { outcome: 'CREATED', path: '/tmp/repo.wt/item-gt1021' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_TIMEOUT' },
);
happyWorker('item-gt1021');

globalThis.args = { ...baseArgs, items: [
  { slug: 'item-gt1021', branch: 'build/item-gt1021', title: 'Gate Timeout', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();

if ((result.escalations ?? []).length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 1 escalation: ' + JSON.stringify(result) })); process.exit(0); }
const esc = result.escalations[0];
if (esc.kind !== 'acceptance-gate-timeout')
  { console.log(JSON.stringify({ ok: false, reason: 'timeout escalated as \'' + esc.kind + '\', not acceptance-gate-timeout' })); process.exit(0); }
// The payload must SAY it is a budget fact, so a reader (human or router) never
// has to infer 'green suite vs broken tree' from the kind alone.
if (!/BUDGET/.test(esc.payload?.reason ?? ''))
  { console.log(JSON.stringify({ ok: false, reason: 'timeout payload does not name the budget cause: ' + JSON.stringify(esc.payload) })); process.exit(0); }
// And it must NOT push a branch on an unknown verdict.
if ((result.parked ?? []).length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 0 parked: ' + JSON.stringify(result) })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 11e (temperloop#1021): the SLICE loop — a suite too big for one budget
#   still passes the gate. GATE_SLICE resumes at the reported index and the item
#   parks green. This is what makes 'the budget decayed again' structurally
#   impossible: total suite runtime is no longer bounded by one Bash invocation.
# ============================================================================
run_node_case "1021 slice: GATE_SLICE → resume → GATE_PASS parks green" "
$PREAMBLE

setMachinery('item-gs1021',
  { outcome: 'CREATED', path: '/tmp/repo.wt/item-gs1021' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_SLICE', resumeAt: 47, failed: 0, elapsedSecs: 301 },
  { outcome: 'GATE_PASS', failed: 0, elapsedSecs: 120 },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'a29' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'a29', branch: 'build/item-gs1021' },
  { outcome: 'PR_OPENED', pr_number: 1021 },
  { outcome: 'CI_GREEN' },
);
happyWorker('item-gs1021');

const gatePrompts = [];
const origAgent = globalThis.agent;
globalThis.agent = async function(prompt, opts = {}) {
  if ((opts.label || '').startsWith('gate:item-gs1021')) gatePrompts.push(String(prompt));
  return origAgent(prompt, opts);
};

globalThis.args = { ...baseArgs, items: [
  { slug: 'item-gs1021', branch: 'build/item-gs1021', title: 'Gate Slice', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();

if ((result.escalations ?? []).length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'unexpected escalation: ' + JSON.stringify(result) })); process.exit(0); }
if ((result.parked ?? []).length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 1 parked: ' + JSON.stringify(result) })); process.exit(0); }
if (gatePrompts.length !== 2)
  { console.log(JSON.stringify({ ok: false, reason: 'expected exactly 2 gate slices, saw ' + gatePrompts.length })); process.exit(0); }
// Slice 1 starts at 0 and TRUNCATES the log UP FRONT; every slice then STREAMS
// into it through tee, so /tmp/qg-<slug>.log carries the union of both slices
// and keeps filling even when the executor kills the command (temperloop#2094
// review round 1 — a truncate-and-copy scheduled AFTER the gate never runs on
// the one path where the partial output is the only diagnostic there is).
if (!gatePrompts[0].includes('QUALITY_GATES_START_AT=0'))
  { console.log(JSON.stringify({ ok: false, reason: 'slice 1 does not start at 0: ' + gatePrompts[0] })); process.exit(0); }
if (!gatePrompts[1].includes('QUALITY_GATES_START_AT=47'))
  { console.log(JSON.stringify({ ok: false, reason: 'slice 2 does not resume at the reported index 47: ' + gatePrompts[1] })); process.exit(0); }
// sq() shell-quotes both log paths in the composed command, so the expected
// text carries apostrophes. This case is itself a double-quoted shell string,
// so the character is built rather than written, to keep the escaping obvious.
const Q = String.fromCharCode(39);
const QGLOG = Q + '/tmp/qg-item-gs1021.log' + Q;
const QGSLICE = Q + '/tmp/qg-item-gs1021.log.slice' + Q;
if (!gatePrompts[0].includes(': >' + QGLOG + ';'))
  { console.log(JSON.stringify({ ok: false, reason: 'slice 1 must TRUNCATE the gate log UP FRONT, before the gate runs: ' + gatePrompts[0] })); process.exit(0); }
if (gatePrompts[1].includes(': >' + QGLOG + ';'))
  { console.log(JSON.stringify({ ok: false, reason: 'slice 2 must NOT truncate the gate log: ' + gatePrompts[1] })); process.exit(0); }
// STREAMING, not a post-hoc copy: the gate's output must reach BOTH the
// per-slice file (which the trailers are parsed from) and the cumulative
// operator log WHILE the gate runs. A `cat` after the gate is the regression.
for (const i of [0, 1]) {
  if (!gatePrompts[i].includes('| tee ' + QGSLICE + ' >>' + QGLOG))
    { console.log(JSON.stringify({ ok: false, reason: 'slice ' + (i + 1) + ' must STREAM into the cumulative log through tee, not copy into it after the gate: ' + gatePrompts[i] })); process.exit(0); }
  if (/cat\s+\S*qg-item-gs1021\.log\.slice/.test(gatePrompts[i]))
    { console.log(JSON.stringify({ ok: false, reason: 'slice ' + (i + 1) + ' copies the slice log after the gate; a kill on timeout skips that step: ' + gatePrompts[i] })); process.exit(0); }
}
// The budget must reach the script as an ENV VAR (an older vendored
// quality-gates.sh ignores an unknown env var and runs the whole suite; an
// unknown FLAG would exit 2 and read back as a gate failure).
if (!gatePrompts[0].includes('QUALITY_GATES_BUDGET_SECS=300'))
  { console.log(JSON.stringify({ ok: false, reason: 'slice does not carry the budget env var: ' + gatePrompts[0] })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 11f (temperloop#1021): a failure found in slice 1 is NOT lost when a
#   later slice finishes green. Slicing must preserve quality-gates.sh's
#   collect-all-failures property — otherwise the fix would silently WEAKEN the
#   gate, which acceptance criterion 5 forbids.
# ============================================================================
run_node_case "1021 slice: a failure in an early slice still escalates acceptance-gate-failed" "
$PREAMBLE

setMachinery('item-gsf1021',
  { outcome: 'CREATED', path: '/tmp/repo.wt/item-gsf1021' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_SLICE', resumeAt: 12, failed: 1, elapsedSecs: 300 },
  { outcome: 'GATE_PASS', failed: 0, elapsedSecs: 60 },
);
happyWorker('item-gsf1021');

globalThis.args = { ...baseArgs, items: [
  { slug: 'item-gsf1021', branch: 'build/item-gsf1021', title: 'Gate Slice Fail', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();

if ((result.escalations ?? []).length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 1 escalation: ' + JSON.stringify(result) })); process.exit(0); }
if (result.escalations[0].kind !== 'acceptance-gate-failed')
  { console.log(JSON.stringify({ ok: false, reason: 'early-slice failure escalated as \'' + result.escalations[0].kind + '\', not acceptance-gate-failed' })); process.exit(0); }
if ((result.parked ?? []).length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'a red suite must never park/push: ' + JSON.stringify(result) })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 11g (temperloop#1021, disposition changed by #2135): the slice loop is
#   still BOUNDED — a suite that TRULY never finishes still escalates as a
#   TIMEOUT (honestly named) rather than looping forever, and still never as a
#   gate failure. What #2135 changes: a ZERO-FAILURE exhaustion of the
#   ORIGINAL GATE_MAX_SLICES ceiling (8) no longer escalates on its own — the
#   loop grants itself GATE_RESUME_EXTENSIONS (2) more full allotments of that
#   SAME ceiling before finally giving up, so this suite (30 clean slices
#   offered, none of them the last one) only escalates once ALL 3 allotments
#   (3 * 8 = 24 slices) are spent.
# ============================================================================
run_node_case "2135 slice: exhausting the EXTENDED slice cap (3x GATE_MAX_SLICES) still escalates acceptance-gate-timeout, not -failed" "
$PREAMBLE

const slices = [];
for (let i = 0; i < 30; i++) slices.push({ outcome: 'GATE_SLICE', resumeAt: i + 1, failed: 0, elapsedSecs: 300 });
setMachinery('item-gsc1021',
  { outcome: 'CREATED', path: '/tmp/repo.wt/item-gsc1021' },
  { outcome: 'REVIEW_DIFF' },
  ...slices,
);
happyWorker('item-gsc1021');

const gateCalls = [];
const origAgent = globalThis.agent;
globalThis.agent = async function(prompt, opts = {}) {
  if ((opts.label || '').startsWith('gate:item-gsc1021')) gateCalls.push(1);
  return origAgent(prompt, opts);
};

globalThis.args = { ...baseArgs, items: [
  { slug: 'item-gsc1021', branch: 'build/item-gsc1021', title: 'Gate Slice Cap', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();

if ((result.escalations ?? []).length !== 1 || result.escalations[0].kind !== 'acceptance-gate-timeout')
  { console.log(JSON.stringify({ ok: false, reason: 'expected one acceptance-gate-timeout: ' + JSON.stringify(result) })); process.exit(0); }
if (gateCalls.length !== 24)
  { console.log(JSON.stringify({ ok: false, reason: 'slice loop must resume through 2 extensions before escalating at 24 (8 * 3): ran ' + gateCalls.length })); process.exit(0); }
if (result.escalations[0].payload.resumeExtensionsUsed !== 2)
  { console.log(JSON.stringify({ ok: false, reason: 'expected both GATE_RESUME_EXTENSIONS spent: ' + JSON.stringify(result.escalations[0].payload) })); process.exit(0); }
if (result.escalations[0].round_kind !== 'gate-timeout')
  { console.log(JSON.stringify({ ok: false, reason: 'acceptance-gate-timeout round_kind must be gate-timeout, got: ' + result.escalations[0].round_kind })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 11g2 (temperloop#2135): the POSITIVE case — a suite that exhausts the
#   ORIGINAL GATE_MAX_SLICES ceiling (8 slices) with zero failures, then
#   finishes on the very next (extended) slice, resumes and parks GREEN with
#   NO escalation at all. This is bullet 1's core claim made concrete: the
#   run costs one extra cheap machinery call, never a worker re-spawn.
# ============================================================================
run_node_case "2135 slice: zero-fail cap exhaustion RESUMES past GATE_MAX_SLICES and parks green (no escalation)" "
$PREAMBLE

const slices = [];
for (let i = 0; i < 8; i++) slices.push({ outcome: 'GATE_SLICE', resumeAt: i + 1, failed: 0, elapsedSecs: 300 });
slices.push({ outcome: 'GATE_PASS', failed: 0, elapsedSecs: 60 });
setMachinery('item-gsr2135',
  { outcome: 'CREATED', path: '/tmp/repo.wt/item-gsr2135' },
  { outcome: 'REVIEW_DIFF' },
  ...slices,
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'b29' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'b29', branch: 'build/item-gsr2135' },
  { outcome: 'PR_OPENED', pr_number: 2135 },
  { outcome: 'CI_GREEN' },
);
happyWorker('item-gsr2135');

const gateCalls = [];
const origAgent = globalThis.agent;
globalThis.agent = async function(prompt, opts = {}) {
  if ((opts.label || '').startsWith('gate:item-gsr2135')) gateCalls.push(1);
  return origAgent(prompt, opts);
};

globalThis.args = { ...baseArgs, items: [
  { slug: 'item-gsr2135', branch: 'build/item-gsr2135', title: 'Gate Slice Resume', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();

if ((result.escalations ?? []).length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'a zero-fail cap exhaustion that later finishes must NOT escalate: ' + JSON.stringify(result) })); process.exit(0); }
if ((result.parked ?? []).length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 1 parked: ' + JSON.stringify(result) })); process.exit(0); }
if (gateCalls.length !== 9)
  { console.log(JSON.stringify({ ok: false, reason: 'expected exactly 9 gate slices (8 to exhaust GATE_MAX_SLICES + 1 resumed), saw ' + gateCalls.length })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 11g3 (temperloop#2135, acceptance bullet 2): a FAILED gate at the
#   ORIGINAL GATE_MAX_SLICES cap is UNCHANGED — no extension is granted once
#   any failure is on the ledger, so it still escalates acceptance-gate-failed
#   at exactly 8 slices, never resuming further to chase a verdict that is
#   already known RED.
# ============================================================================
run_node_case "2135 slice: a failed gate at the cap is unchanged — still escalates acceptance-gate-failed at exactly 8 slices" "
$PREAMBLE

const slices = [];
for (let i = 0; i < 30; i++) slices.push({ outcome: 'GATE_SLICE', resumeAt: i + 1, failed: 1, elapsedSecs: 300 });
setMachinery('item-gscf2135',
  { outcome: 'CREATED', path: '/tmp/repo.wt/item-gscf2135' },
  { outcome: 'REVIEW_DIFF' },
  ...slices,
);
happyWorker('item-gscf2135');

const gateCalls = [];
const origAgent = globalThis.agent;
globalThis.agent = async function(prompt, opts = {}) {
  if ((opts.label || '').startsWith('gate:item-gscf2135')) gateCalls.push(1);
  return origAgent(prompt, opts);
};

globalThis.args = { ...baseArgs, items: [
  { slug: 'item-gscf2135', branch: 'build/item-gscf2135', title: 'Gate Slice Cap Fail', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();

if ((result.escalations ?? []).length !== 1 || result.escalations[0].kind !== 'acceptance-gate-failed')
  { console.log(JSON.stringify({ ok: false, reason: 'expected one acceptance-gate-failed: ' + JSON.stringify(result) })); process.exit(0); }
if (gateCalls.length !== 8)
  { console.log(JSON.stringify({ ok: false, reason: 'a RED suite must never be granted a resume extension — expected exactly 8 slices, ran ' + gateCalls.length })); process.exit(0); }
if (result.escalations[0].payload.resumeExtensionsUsed !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'a RED suite must spend 0 resume extensions: ' + JSON.stringify(result.escalations[0].payload) })); process.exit(0); }
if (result.escalations[0].round_kind !== 'gate-fail')
  { console.log(JSON.stringify({ ok: false, reason: 'acceptance-gate-failed round_kind must be gate-fail, got: ' + result.escalations[0].round_kind })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 11h (temperloop#1021): the gate budget is a NAMED SETTING handed in via
#   the Step-0 seam (input.gateSliceSecs), not a literal in this file — and it
#   is CLAMPED so no operator value can push the derived Bash-tool timeout past
#   the agent's hard 600000ms cap (which would trade a legible timeout for an
#   opaque agent death).
# ============================================================================
run_node_case "1021 setting: input.gateSliceSecs drives the budget and is clamped to the agent Bash cap" "
$PREAMBLE

async function budgetAndTimeoutFor(sliceSecs, slug) {
  happyMachinery(slug, 1, 'a01');
  happyWorker(slug);
  let seen = null;
  const origAgent = globalThis.agent;
  globalThis.agent = async function(prompt, opts = {}) {
    if ((opts.label || '').startsWith('gate:' + slug)) seen = String(prompt);
    return origAgent(prompt, opts);
  };
  globalThis.args = { ...baseArgs, gateSliceSecs: sliceSecs, items: [
    { slug, branch: 'build/' + slug, title: 'x', kind: 'impl', acceptance: ['c'] },
  ]};
  const mod = await loadLevel();
  await mod.default();
  globalThis.agent = origAgent;
  const budget = (seen.match(/QUALITY_GATES_BUDGET_SECS=(\\d+)/) || [])[1];
  const timeout = (seen.match(/\`timeout\` parameter to (\\d+)/) || [])[1];
  return { budget: Number(budget), timeout: Number(timeout) };
}

// An explicit setting is honored end to end.
const a = await budgetAndTimeoutFor(120, 'setting-a');
if (a.budget !== 120 || a.timeout !== 120 * 1000 + 240000)
  { console.log(JSON.stringify({ ok: false, reason: 'setting not honored: ' + JSON.stringify(a) })); process.exit(0); }

// An absurdly large setting is CLAMPED — the derived Bash-tool timeout must
// never exceed AGENT_BASH_CAP_MS (600000).
const b = await budgetAndTimeoutFor(99999, 'setting-b');
if (b.timeout > 600000)
  { console.log(JSON.stringify({ ok: false, reason: 'clamp failed — derived Bash timeout ' + b.timeout + ' exceeds the 600000ms agent cap' })); process.exit(0); }

// Unset/empty falls back to the in-file default, so an un-updated caller works.
const c = await budgetAndTimeoutFor('', 'setting-c');
if (c.budget !== 300)
  { console.log(JSON.stringify({ ok: false, reason: 'empty setting did not fall back to the in-file default: ' + JSON.stringify(c) })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 11i (temperloop#1587): the escalation's KIND and its PAYLOAD must agree,
#   in every one of the four gate outcomes. #1587 shipped
#   {gateOut:{outcome:'GATE_PASS',failed:0,…}, failedGates:1} under
#   kind=acceptance-gate-failed: two independent counters, one saying the gate
#   passed and one saying it failed, so a consumer trusting either acted on a
#   fiction. This case drives GATE_PASS / GATE_FAIL / GATE_SLICE(cap) /
#   GATE_TIMEOUT in one level and asserts the SAME structural invariants on
#   every gate escalation it produces.
# ============================================================================
run_node_case "1587 agreement: kind and payload agree across GATE_PASS/FAIL/SLICE/TIMEOUT" "
$PREAMBLE

// GATE_PASS — the green arm: parks, no escalation at all.
happyMachinery('g1587-pass', 1587, 'aa46');
happyWorker('g1587-pass');

// GATE_FAIL — note failed:0 in the executor's own line (a stale/absent
// QUALITY_GATES_FAILED= trailer). A RED suite reporting ZERO failures is the
// MIRROR image of #1587's contradiction, so the payload must floor it at 1.
setMachinery('g1587-fail',
  { outcome: 'CREATED', path: '/tmp/repo.wt/g1587-fail' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_FAIL', failed: 0, elapsedSecs: 42 },
);
happyWorker('g1587-fail');

// GATE_SLICE — the cap-exhaustion arm, every slice green.
const capSlices = [];
for (let i = 0; i < 30; i++) capSlices.push({ outcome: 'GATE_SLICE', resumeAt: i + 1, failed: 0, elapsedSecs: 300 });
setMachinery('g1587-slice',
  { outcome: 'CREATED', path: '/tmp/repo.wt/g1587-slice' },
  { outcome: 'REVIEW_DIFF' },
  ...capSlices,
);
happyWorker('g1587-slice');

// GATE_TIMEOUT — the arm that fires on this repo today (temperloop#1663): the
// suite cannot finish inside the executor's Bash ceiling.
setMachinery('g1587-timeout',
  { outcome: 'CREATED', path: '/tmp/repo.wt/g1587-timeout' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_TIMEOUT' },
);
happyWorker('g1587-timeout');

globalThis.args = { ...baseArgs, items: [
  { slug: 'g1587-pass', branch: 'build/g1587-pass', title: 'Pass', kind: 'impl', acceptance: ['c'] },
  { slug: 'g1587-fail', branch: 'build/g1587-fail', title: 'Fail', kind: 'impl', acceptance: ['c'] },
  { slug: 'g1587-slice', branch: 'build/g1587-slice', title: 'Slice', kind: 'impl', acceptance: ['c'] },
  { slug: 'g1587-timeout', branch: 'build/g1587-timeout', title: 'Timeout', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();
const bad = (why) => { console.log(JSON.stringify({ ok: false, reason: why })); process.exit(0); };

const escalations = result.escalations ?? [];
const parked = result.parked ?? [];
const by = {};
for (const e of escalations) by[e.slug] = e;

// GATE_PASS: green all the way through — the reconciliation must not perturb it.
if (parked.length !== 1 || parked[0].slug !== 'g1587-pass')
  bad('GATE_PASS arm did not park cleanly: ' + JSON.stringify(result));
if (by['g1587-pass']) bad('GATE_PASS escalated: ' + JSON.stringify(by['g1587-pass']));
if (escalations.length !== 3) bad('expected 3 gate escalations: ' + JSON.stringify(escalations));

// --- The structural invariants, asserted on EVERY gate escalation ----------
for (const e of escalations) {
  const p = e.payload || {};
  // (1) ONE failure counter. The embedded raw gate object — whose own
  //     'failed' was #1587's contradicting field — must be gone, and no bare
  //     top-level 'failed' peer may replace it.
  if ('gateOut' in p) bad(e.slug + ': payload still embeds the raw gateOut (its .failed is the second counter #1587 filed): ' + JSON.stringify(p));
  if ('failed' in p) bad(e.slug + ': payload carries a bare top-level failed counter beside failedGates: ' + JSON.stringify(p));
  // (2) failedGates DERIVES from the ledger — it cannot disagree with it.
  const ledger = p.sliceLedger || [];
  const sum = ledger.reduce((n, s) => n + (Number(s.failed) || 0), 0);
  if (sum !== p.failedGates) bad(e.slug + ': failedGates ' + p.failedGates + ' disagrees with its own ledger sum ' + sum);
  if (p.slices !== ledger.length) bad(e.slug + ': slices ' + p.slices + ' disagrees with the ledger it ships (' + ledger.length + ')');
  // (3) The KIND is exactly the verdict, both ways.
  if (e.kind === 'acceptance-gate-failed' && p.verdict !== 'RED')
    bad(e.slug + ': escalated FAILED with verdict ' + p.verdict);
  if (e.kind === 'acceptance-gate-timeout' && p.verdict !== 'UNKNOWN')
    bad(e.slug + ': escalated TIMEOUT with verdict ' + p.verdict);
  // (3b) temperloop#2135 — round_kind is present on every escalation and
  //      agrees with the mapping rule for both gate kinds.
  if (!e.round_kind) bad(e.slug + ': escalation carries no round_kind: ' + JSON.stringify(e));
  if (e.kind === 'acceptance-gate-failed' && e.round_kind !== 'gate-fail')
    bad(e.slug + ': acceptance-gate-failed round_kind must be gate-fail, got ' + e.round_kind);
  if (e.kind === 'acceptance-gate-timeout' && e.round_kind !== 'gate-timeout')
    bad(e.slug + ': acceptance-gate-timeout round_kind must be gate-timeout, got ' + e.round_kind);
  if (p.verdict === 'RED' && p.failedGates < 1)
    bad(e.slug + ': verdict RED with ' + p.failedGates + ' failed gates — a failure with no failures');
  if (p.verdict === 'UNKNOWN' && p.failedGates !== 0)
    bad(e.slug + ': verdict UNKNOWN while ' + p.failedGates + ' gate(s) are known to have failed');
  if (p.verdict === 'GREEN') bad(e.slug + ': escalated at all on a GREEN verdict: ' + JSON.stringify(p));
  // (4) The REASON prose agrees with the verdict it accompanies.
  const reason = String(p.reason || '');
  if (!reason) bad(e.slug + ': payload carries no reason');
  if (p.verdict === 'UNKNOWN' && !/unknown/i.test(reason))
    bad(e.slug + ': UNKNOWN verdict whose reason never says the verdict is unknown: ' + reason);
  if (p.verdict === 'RED' && /NOT a gate failure/.test(reason))
    bad(e.slug + ': RED verdict whose reason denies a gate failed: ' + reason);
}

// GATE_FAIL: RED, and floored at one failure despite the executor's failed:0.
const f = by['g1587-fail'];
if (!f || f.kind !== 'acceptance-gate-failed') bad('GATE_FAIL did not escalate acceptance-gate-failed: ' + JSON.stringify(f));
if (f.payload.failedGates !== 1) bad('GATE_FAIL with an unparseable count must floor at 1, got ' + f.payload.failedGates);

// GATE_SLICE (cap): UNKNOWN, named as a BUDGET fact, and the slice count is the
// ledger's own length — not the loop index, which ran one PAST the last slice.
// temperloop#2135: a zero-fail exhaustion resumes through GATE_RESUME_EXTENSIONS
// (2) extra allotments before escalating, so the 30 clean slices this fixture
// offers only escalate once all 3 allotments (24 slices) are spent.
const s = by['g1587-slice'];
if (!s || s.kind !== 'acceptance-gate-timeout') bad('slice-cap did not escalate acceptance-gate-timeout: ' + JSON.stringify(s));
if (!/BUDGET/.test(s.payload.reason)) bad('slice-cap reason does not name the budget cause: ' + s.payload.reason);
if (s.payload.slices !== 24) bad('slice-cap must report the 24 slices it actually ran (3 * GATE_MAX_SLICES), got ' + s.payload.slices);
if (s.payload.resumeExtensionsUsed !== 2) bad('slice-cap must spend both resume extensions, got ' + JSON.stringify(s.payload.resumeExtensionsUsed));

// GATE_TIMEOUT: UNKNOWN, and still clearly NOT a gate failure (temperloop#1021).
const t = by['g1587-timeout'];
if (!t || t.kind !== 'acceptance-gate-timeout') bad('GATE_TIMEOUT did not escalate acceptance-gate-timeout: ' + JSON.stringify(t));
if (t.payload.verdict !== 'UNKNOWN') bad('GATE_TIMEOUT verdict is not UNKNOWN: ' + JSON.stringify(t.payload));
if (!/NOT a gate failure/.test(t.payload.reason)) bad('GATE_TIMEOUT reason no longer distinguishes itself from a real failure: ' + t.payload.reason);
if (t.payload.failedGates !== 0) bad('GATE_TIMEOUT invented a failure count: ' + JSON.stringify(t.payload));

console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 11j (temperloop#1587): the EXACT observed payload — a failure in an early
#   slice followed by a green FINAL slice. Pre-fix this shipped
#   failedGates:1 alongside gateOut:{outcome:'GATE_PASS',failed:0}, and the
#   operator who read the log's closing 'OK — gates 96..162 passed (final
#   slice)' line concluded the escalation was a false positive. The escalation
#   is correct; its payload has to SAY so.
# ============================================================================
run_node_case "1587 observed: an early-slice failure + green final slice ships ONE self-consistent payload" "
$PREAMBLE

setMachinery('g1587-obs',
  { outcome: 'CREATED', path: '/tmp/repo.wt/g1587-obs' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_SLICE', resumeAt: 96, failed: 1, elapsedSecs: 300 },
  { outcome: 'GATE_PASS', failed: 0, elapsedSecs: 241 },
);
happyWorker('g1587-obs');

globalThis.args = { ...baseArgs, items: [
  { slug: 'g1587-obs', branch: 'build/g1587-obs', title: 'Observed', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();
const bad = (why) => { console.log(JSON.stringify({ ok: false, reason: why })); process.exit(0); };

if ((result.escalations ?? []).length !== 1) bad('expected 1 escalation: ' + JSON.stringify(result));
const e = result.escalations[0];
const p = e.payload || {};
if (e.kind !== 'acceptance-gate-failed') bad('kind wrong: ' + e.kind);
if ((result.parked ?? []).length !== 0) bad('a red suite must never park/push: ' + JSON.stringify(result));

// The contradiction itself: NO field in this payload may read as 'the gate passed'.
if ('gateOut' in p) bad('the GATE_PASS payload object is still embedded: ' + JSON.stringify(p));
if (p.verdict !== 'RED') bad('verdict is not RED: ' + JSON.stringify(p));
if (p.failedGates !== 1) bad('failedGates is not 1: ' + JSON.stringify(p));
if (JSON.stringify(p.failedInSlices) !== '[1]') bad('failedInSlices does not name slice 1: ' + JSON.stringify(p));
if (p.suiteFinished !== true) bad('the suite DID finish (final slice GATE_PASS); suiteFinished says otherwise: ' + JSON.stringify(p));

// The terminal slice's own outcome is still reported — but SCOPED as a slice
// fact under 'outcome', never as the suite's verdict.
if (p.outcome !== 'GATE_PASS') bad('the terminal slice outcome is no longer reported: ' + JSON.stringify(p));
if (!/FINAL slice/.test(String(p.reason))) bad('the reason does not explain the green final slice: ' + p.reason);
if (!/RED/.test(String(p.reason))) bad('the reason does not state the suite is RED: ' + p.reason);

// The ledger is the single record both numbers come from.
if ((p.sliceLedger || []).length !== 2) bad('ledger does not carry both slices: ' + JSON.stringify(p.sliceLedger));
if (p.sliceLedger[0].failed !== 1 || p.sliceLedger[0].outcome !== 'GATE_SLICE') bad('slice 1 ledger entry wrong: ' + JSON.stringify(p.sliceLedger));
if (p.sliceLedger[1].failed !== 0 || p.sliceLedger[1].outcome !== 'GATE_PASS') bad('slice 2 ledger entry wrong: ' + JSON.stringify(p.sliceLedger));
if (p.sliceLedger[1].startAt !== 96) bad('slice 2 did not record its resume index: ' + JSON.stringify(p.sliceLedger));

console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 11k (temperloop#1587 + #1021): a TIMEOUT must never LAUNDER an observed
#   failure into an unknown. A slice that failed, followed by a slice the Bash
#   ceiling killed, is a KNOWN-red branch — so it escalates as a failure, and
#   its reason still names the unfinished remainder. The mirror (a timeout with
#   nothing failed) stays acceptance-gate-timeout — asserted in 11i, and that
#   is the case #1663 hits on this repo today.
# ============================================================================
run_node_case "1587 honesty: an observed failure + a killed later slice is RED, and says both halves" "
$PREAMBLE

setMachinery('g1587-mix',
  { outcome: 'CREATED', path: '/tmp/repo.wt/g1587-mix' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_SLICE', resumeAt: 40, failed: 2, elapsedSecs: 300 },
  { outcome: 'GATE_TIMEOUT' },
);
happyWorker('g1587-mix');

globalThis.args = { ...baseArgs, items: [
  { slug: 'g1587-mix', branch: 'build/g1587-mix', title: 'Mixed', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();
const bad = (why) => { console.log(JSON.stringify({ ok: false, reason: why })); process.exit(0); };

if ((result.escalations ?? []).length !== 1) bad('expected 1 escalation: ' + JSON.stringify(result));
const e = result.escalations[0];
const p = e.payload || {};
if (e.kind !== 'acceptance-gate-failed') bad('an observed failure must dominate the unfinished remainder, got kind ' + e.kind);
if (p.verdict !== 'RED') bad('verdict is not RED: ' + JSON.stringify(p));
if (p.failedGates !== 2) bad('the observed failures were lost or double-counted: ' + JSON.stringify(p));
if (p.suiteFinished !== false) bad('the suite did NOT finish; suiteFinished says otherwise: ' + JSON.stringify(p));
// Both halves, in the same sentence: the failures are real AND the rest has no verdict.
if (!/BUDGET/.test(String(p.reason))) bad('the reason drops the unfinished half: ' + p.reason);
if (!/known-RED/.test(String(p.reason))) bad('the reason drops the known-failure half: ' + p.reason);
// The killed slice establishes nothing, so it contributes NO count of its own.
if (p.sliceLedger[1].outcome !== 'GATE_TIMEOUT' || p.sliceLedger[1].failed !== 0)
  bad('a killed slice must contribute 0, not a guess: ' + JSON.stringify(p.sliceLedger));

console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 11m (temperloop#2094): the 3e.5 gate's SHELL classifier, EXECUTED.
#
#   Every other gate case above stubs the executor's JSON line, so none of them
#   can see the branch that PRODUCES it. This one runs the real composed
#   command — the exact text driveItem hands the executor — against a stub
#   quality-gates.sh whose exit code and trailers are scripted, and reads the
#   JSON it prints.
#
#   The defect: the classifier keyed GATE_SLICE off `exit 75` AND a resume
#   point. quality-gates.sh prints `QUALITY_GATES_RESUME_AT=` on exactly one
#   path — budget spent, stopped cleanly between gates — and prints it BEFORE
#   it exits, so one unexpected status turned a clean partial into GATE_FAIL,
#   where gateSliceFailed()'s "RED by construction" floor manufactured the one
#   failure the slice had just reported as zero. Observed live: three slices,
#   QUALITY_GATES_FAILED=0 in all three, stopped at gate 152 of 200, reported
#   RED with one failure and suiteFinished:true.
#
#   Reading 5 is the guard on the fix: the trailers are now read from THIS
#   slice's own log, so a later slice that prints nothing cannot inherit an
#   earlier slice's resume point and loop on it forever.
# ============================================================================
K2094_WT="$(mktemp -d "$WF_TEST_TMPDIR/k2094-XXXXXX")"
mkdir -p "$K2094_WT/scripts"
# PER-RUN SLUG (#258, found while proving the #865 fix in review round 2). This
# case EXECUTES the composed gate command, and build-level.mjs derives that
# command's three artifacts from the item slug: /tmp/qg-<slug>.log, its .slice
# sibling and the .selection-pin. A hard-coded slug therefore made them fixed,
# process-global paths — and the assertions below read the cumulative log back
# and even plant a STALE marker in it, so two concurrent suite runs (the
# documented parallel-/build-worker case) read each other's writes. Reproduced:
# with the slug fixed, two concurrent runs failed reading 1 with a GATE_FAIL
# where the fixture scripted a clean partial; with it uniquified, both pass.
K2094_SLUG="k2094cls-$$-${RANDOM}"
export K2094_SLUG
wf_test_sweep_add "/tmp/qg-$K2094_SLUG.log" "/tmp/qg-$K2094_SLUG.log.slice" "/tmp/qg-$K2094_SLUG.selection-pin"
cat >"$K2094_WT/scripts/quality-gates.sh" <<'K2094_STUB'
#!/usr/bin/env bash
# Stub quality-gates.sh: exit status and trailers scripted by ../.qgstub.
# FAIL LOUDLY if that script is missing (review round 1). Sourcing it blind left
# RC unset, so the stub exited 0 with no trailers — byte-for-byte reading 4's
# green run. A fixture-wiring mistake would then read as a PASSING assertion.
# 99 is outside the gate protocol's codes (0 / 75 / red), so it cannot be
# mistaken for a real outcome.
__qgstub="$(dirname "$0")/../.qgstub"
[ -f "$__qgstub" ] || { echo "stub quality-gates.sh: $__qgstub missing" >&2; exit 99; }
. "$__qgstub"
[ -n "${OUT:-}" ] && printf '%s\n' "$OUT"
# SLEEP lets a case hold the gate open AFTER it has written output, so a test can
# kill the composed command mid-slice the way the executor does on a timeout.
[ -n "${SLEEP:-}" ] && sleep "$SLEEP"
[ -n "${FAILED:-}" ] && printf 'QUALITY_GATES_FAILED=%s\n' "$FAILED"
[ -n "${RESUME:-}" ] && printf 'QUALITY_GATES_RESUME_AT=%s\n' "$RESUME"
exit "${RC:-0}"
K2094_STUB
chmod +x "$K2094_WT/scripts/quality-gates.sh"
export K2094_WT

run_node_case "2094 classifier: a printed resume point is a PARTIAL slice, whatever the exit code" "
$PREAMBLE

import { writeFileSync } from 'node:fs';
import { execFileSync, spawn } from 'node:child_process';

const WT = process.env.K2094_WT;
// PER-RUN SLUG (#258). build-level.mjs derives this executed command's three
// artifacts — /tmp/qg-<slug>.log, its .slice sibling and the .selection-pin —
// from the item slug, so a hard-coded one made them fixed, process-global
// paths that two concurrent suite runs share. The readings below read that
// cumulative log back and one even plants a STALE marker in it, so the sharing
// is not theoretical: with a fixed slug, two concurrent runs read each other's
// writes and reading 1 fails with a GATE_FAIL over a scripted clean partial.
const SLUG = process.env.K2094_SLUG;
const GATELOG = '/tmp/qg-' + SLUG + '.log';

// Two gate calls: the first slice reports a resume point, the second finishes.
// That is what puts a startAt>0 command in callLog for reading 5.
setMachinery(SLUG,
  { outcome: 'CREATED', path: WT },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_SLICE', resumeAt: 152, failed: 0, elapsedSecs: 300, selection: '200:abc' },
  { outcome: 'GATE_PASS', failed: 0, elapsedSecs: 10 },
);
happyWorker(SLUG);

globalThis.args = { ...baseArgs, items: [
  { slug: SLUG, branch: 'build/' + SLUG, title: 'Classifier', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
await mod.default();
const bad = (why) => { console.log(JSON.stringify({ ok: false, reason: why })); process.exit(0); };

const gateCalls = callLog.filter((c) => String(c.opts.label || '').startsWith('gate:' + SLUG));
if (gateCalls.length !== 2) bad('expected 2 gate calls to harvest, got ' + gateCalls.length);
const cmdOf = (c) => {
  const parts = String(c.promptFull).split('\nCommand:\n');
  if (parts.length < 2) bad('gate prompt carries no Command: section');
  return parts[1];
};
const cmdSlice0 = cmdOf(gateCalls[0]);
const cmdResume = cmdOf(gateCalls[1]);
if (!/QUALITY_GATES_START_AT=0 /.test(cmdSlice0)) bad('first gate call is not startAt=0: ' + cmdSlice0.slice(0, 400));
if (!/QUALITY_GATES_START_AT=152 /.test(cmdResume)) bad('second gate call is not startAt=152: ' + cmdResume.slice(0, 400));

const script = (o) => {
  writeFileSync(WT + '/.qgstub',
    'RC=' + o.rc + '\n'
    + 'FAILED=' + (o.failed === undefined ? '' : o.failed) + '\n'
    + 'RESUME=' + (o.resume === undefined ? '' : o.resume) + '\n'
    + 'SLEEP=' + (o.sleep === undefined ? '' : o.sleep) + '\n'
    + 'OUT=' + JSON.stringify(o.out === undefined ? '' : o.out) + '\n');
};
const run = (cmd) => {
  let out = '';
  try {
    out = execFileSync('bash', ['-c', cmd], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
  } catch (err) {
    out = String((err && err.stdout) || '');
  }
  const lines = out.split('\n').map((l) => l.trim()).filter((l) => l.startsWith('{') && l.endsWith('}'));
  if (lines.length === 0) bad('the composed gate command printed no JSON line; stdout was: ' + JSON.stringify(out.slice(-400)));
  try { return JSON.parse(lines[lines.length - 1]); }
  catch (e) { return bad('unparseable JSON line: ' + lines[lines.length - 1]); }
};

// --- Reading 1: the PROTOCOL path. exit 75 + a resume point = GATE_SLICE. ---
script({ rc: 75, failed: 0, resume: 152, out: 'PARTIAL — ran gates 0..151 of 200 in 300s (budget 300s); resuming at 152' });
const r1 = run(cmdSlice0);
if (r1.outcome !== 'GATE_SLICE') bad('reading 1 (rc 75 + resume point) is not GATE_SLICE: ' + JSON.stringify(r1));
if (Number(r1.resumeAt) !== 152) bad('reading 1 lost the resume point: ' + JSON.stringify(r1));
if (Number(r1.failed) !== 0) bad('reading 1 invented a failure: ' + JSON.stringify(r1));

// --- Reading 2: THE DEFECT. An UNEXPECTED exit code over the SAME clean
//     partial. It is still a partial slice: the suite said where to resume and
//     said zero gates failed, and neither fact is the exit code's to overturn.
script({ rc: 2, failed: 0, resume: 152, out: 'PARTIAL — ran gates 0..151 of 200 in 300s (budget 300s); resuming at 152' });
const r2 = run(cmdSlice0);
if (r2.outcome !== 'GATE_SLICE') bad('reading 2 (unexpected rc over a clean partial) must be GATE_SLICE, got: ' + JSON.stringify(r2));
if (Number(r2.resumeAt) !== 152) bad('reading 2 lost the resume point: ' + JSON.stringify(r2));
if (Number(r2.failed) !== 0) bad('reading 2 manufactured a failure count: ' + JSON.stringify(r2));
if (Number(r2.rc) !== 2) bad('reading 2 did not carry the anomalous exit code for the record: ' + JSON.stringify(r2));

// --- Reading 3: a genuinely RED slice — no resume point — is still GATE_FAIL,
//     carrying the suite's OWN count. The fix must not soften a real failure.
script({ rc: 1, failed: 3, out: 'FAILED 3/200 quality gate(s):' });
const r3 = run(cmdSlice0);
if (r3.outcome !== 'GATE_FAIL') bad('reading 3 (red, no resume point) is not GATE_FAIL: ' + JSON.stringify(r3));
if (Number(r3.failed) !== 3) bad('reading 3 lost the suite own failure count: ' + JSON.stringify(r3));

// --- Reading 4: green stays green. ---
script({ rc: 0, out: 'OK — all 200 quality gate(s) passed in 120s' });
const r4 = run(cmdSlice0);
if (r4.outcome !== 'GATE_PASS') bad('reading 4 (exit 0) is not GATE_PASS: ' + JSON.stringify(r4));

// --- Reading 5: THE STALENESS GUARD behind reading 2. Slice 1 leaves a resume
//     point in the cumulative log; slice 2 then prints NOTHING and dies. The
//     classifier must NOT inherit slice 1's trailer and resume at 152 forever —
//     a slice that established nothing is a failure, not a partial.
script({ rc: 75, failed: 0, resume: 152, out: 'PARTIAL — ran gates 0..151 of 200 in 300s (budget 300s); resuming at 152' });
run(cmdSlice0);
script({ rc: 2 });
const r5 = run(cmdResume);
if (r5.outcome !== 'GATE_FAIL') bad('reading 5: a silent, failed resume slice inherited the PREVIOUS slice trailer instead of failing: ' + JSON.stringify(r5));
if (r5.resumeAt !== undefined) bad('reading 5 carried a stale resume point: ' + JSON.stringify(r5));

// …and the cumulative operator log still holds BOTH slices, unchanged in meaning.
const cum = readFileSync(GATELOG, 'utf8');
if (!/QUALITY_GATES_RESUME_AT=152/.test(cum)) bad('the cumulative gate log lost slice 1 own output: ' + cum.slice(0, 300));

// --- Reading 6: A NON-NUMERIC RESUME TRAILER (review round 1). The resume point
//     became the load-bearing classifier input, is matched against the WHOLE
//     slice log (gate output included), and is interpolated RAW into the JSON by
//     %s — so a half-written or non-numeric trailer would emit a syntactically
//     invalid line that lands outside the executor's closed outcome set instead
//     of being classified at all. It must be read as ABSENT, exactly as a
//     missing trailer already is, and the line must still parse.
script({ rc: 75, failed: 0, resume: 'notanumber', out: 'PARTIAL — garbage trailer' });
const r6 = run(cmdSlice0);          // run() already fails the case on unparseable JSON
if (r6.outcome === 'GATE_SLICE') bad('reading 6: a non-numeric resume trailer was accepted as a partial slice: ' + JSON.stringify(r6));
if (r6.resumeAt !== undefined) bad('reading 6 carried a non-numeric resume point into the payload: ' + JSON.stringify(r6));
if (r6.outcome !== 'GATE_FAIL') bad('reading 6 (rc 75, unusable trailer) must fall through to GATE_FAIL, got: ' + JSON.stringify(r6));

// --- Reading 7: a resume-LOOKING line in the gate's own OUTPUT is not a
//     trailer. The sed anchors to start-of-line, and this tree really does nest
//     quality-gates.sh inside itself as a fixture, so an echoed captured run
//     must not be able to reclassify a genuinely RED slice as a clean partial.
script({ rc: 1, failed: 2, out: '  QUALITY_GATES_RESUME_AT=152 (echoed from a nested fixture run)' });
const r7 = run(cmdSlice0);
if (r7.outcome !== 'GATE_FAIL') bad('reading 7: an indented resume-looking line in gate OUTPUT reclassified a red slice: ' + JSON.stringify(r7));
if (Number(r7.failed) !== 2) bad('reading 7 lost the suite own failure count: ' + JSON.stringify(r7));

// --- Reading 8: THE TIMEOUT PATH (review round 1). The executor KILLS this whole
//     command at GATE_BASH_TIMEOUT_MS, so anything the command does AFTER the
//     gate — a copy step, a deferred truncation — never runs. Two guarantees must
//     therefore hold while the gate is still running, and this reading is the one
//     that can tell: the killed slice's partial output is the ONLY diagnostic a
//     timeout produces and must already be in the cumulative log the escalation
//     payload hands the operator, and a previous run's log must already be GONE
//     rather than presented as this run's.
script({ rc: 0, failed: 0, out: 'STREAMED-BEFORE-THE-KILL', sleep: 6 });
writeFileSync(GATELOG, 'STALE-FROM-A-PREVIOUS-RUN\n');
await new Promise((resolve) => {
  // detached + a NEGATIVE pid kills the whole process GROUP, so the composed
  // command's own inline wall-clock watchdog (a backgrounded `sleep`) dies with
  // it instead of being orphaned for its full ceiling. That is also the truer
  // simulation: the executor's timeout takes down the command, not one pid.
  const child = spawn('bash', ['-c', cmdSlice0], { stdio: ['ignore', 'ignore', 'ignore'], detached: true });
  const t = setTimeout(() => { try { process.kill(-child.pid, 'SIGKILL'); } catch (e) { child.kill('SIGKILL'); } }, 2000);
  child.on('exit', () => { clearTimeout(t); resolve(); });
  child.on('error', () => { clearTimeout(t); resolve(); });
});
const killedLog = readFileSync(GATELOG, 'utf8');
if (/STALE-FROM-A-PREVIOUS-RUN/.test(killedLog)) bad('reading 8: a killed first slice left the PREVIOUS run log in place, and the escalation would point an operator at stale content presented as current: ' + JSON.stringify(killedLog.slice(0, 200)));
if (!/STREAMED-BEFORE-THE-KILL/.test(killedLog)) bad('reading 8: the killed slice output never reached the cumulative log the escalation hands the operator — the only diagnostic a timeout produces was lost: ' + JSON.stringify(killedLog.slice(0, 200)));

console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 11n (temperloop#2094): suiteFinished is a claim about COVERAGE, and the
#   only first-hand evidence for it is the suite's own resume trailer. Both
#   readings, so the flag is neither hardwired nor inferred from a name:
#     - a final slice that REPORTS a resume point → suiteFinished FALSE, even
#       though its terminal outcome (GATE_FAIL) is in the "finished" set by
#       name. This is the live escalation: three clean slices, stopped at gate
#       152 of 200, shipped suiteFinished:true.
#     - the same shape WITHOUT a resume point → suiteFinished TRUE, unchanged.
# ============================================================================
run_node_case "2094 coverage: suiteFinished follows the resume trailer, not the terminal outcome name" "
$PREAMBLE

// Reading A — the terminal slice carries a resume point.
setMachinery('k2094unfin',
  { outcome: 'CREATED', path: '/tmp/repo.wt/k2094unfin' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_SLICE', resumeAt: 96, failed: 0, elapsedSecs: 300 },
  { outcome: 'GATE_FAIL', failed: 0, resumeAt: 152, elapsedSecs: 300, rc: 2 },
);
happyWorker('k2094unfin');

// Reading B — the SAME terminal outcome with no resume point: finished.
setMachinery('k2094fin',
  { outcome: 'CREATED', path: '/tmp/repo.wt/k2094fin' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_SLICE', resumeAt: 96, failed: 0, elapsedSecs: 300 },
  { outcome: 'GATE_FAIL', failed: 2, elapsedSecs: 300 },
);
happyWorker('k2094fin');

globalThis.args = { ...baseArgs, items: [
  { slug: 'k2094unfin', branch: 'build/k2094unfin', title: 'Unfinished', kind: 'impl', acceptance: ['c'] },
  { slug: 'k2094fin', branch: 'build/k2094fin', title: 'Finished', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();
const bad = (why) => { console.log(JSON.stringify({ ok: false, reason: why })); process.exit(0); };

const by = {};
for (const e of (result.escalations ?? [])) by[e.slug] = e;

const a = by['k2094unfin'];
if (!a) bad('the unfinished item did not escalate: ' + JSON.stringify(result));
const pa = a.payload || {};
if (pa.suiteFinished !== false) bad('a run whose final slice reported a resume point claims the suite finished: ' + JSON.stringify(pa));
if (!/resume point/.test(String(pa.reason))) bad('the reason never names the resume point that contradicts the terminal outcome: ' + pa.reason);
const la = (pa.sliceLedger || [])[(pa.sliceLedger || []).length - 1] || {};
if (Number(la.resumeAt) !== 152) bad('the ledger did not carry the terminal slice resume point: ' + JSON.stringify(pa.sliceLedger));
if (Number(la.rc) !== 2) bad('the ledger did not carry the terminal slice exit code: ' + JSON.stringify(pa.sliceLedger));

const b = by['k2094fin'];
if (!b) bad('the finished item did not escalate: ' + JSON.stringify(result));
const pb = b.payload || {};
if (pb.suiteFinished !== true) bad('the INVERTED reading failed: no resume point, yet suiteFinished is not true: ' + JSON.stringify(pb));
if (pb.verdict !== 'RED') bad('a finished GATE_FAIL is not RED: ' + JSON.stringify(pb));
if (pb.failedGates !== 2) bad('the finished reading lost its failure count: ' + JSON.stringify(pb));
if (((pb.sliceLedger || [])[1] || {}).resumeAt !== undefined) bad('a slice with no resume point invented one: ' + JSON.stringify(pb.sliceLedger));

console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 12: worktree-failed — worktree.sh returns non-CREATED → worktree-failed escalation
# ============================================================================
run_node_case "worktree-failed: worktree.sh non-CREATED → worktree-failed escalation" "
$PREAMBLE

setMachinery('item-wt',
  { outcome: 'ERROR', error: 'repo root is not top-level' }
);

globalThis.args = { ...baseArgs, items: [
  { slug: 'item-wt', branch: 'build/item-wt', title: 'Worktree Fail Item', kind: 'impl' },
]};

const mod = await loadLevel();
const result = await mod.default();

if ((result.escalations ?? []).length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 1 escalation: ' + JSON.stringify(result) })); process.exit(0); }
if (result.escalations[0].kind !== 'worktree-failed')
  { console.log(JSON.stringify({ ok: false, reason: 'escalation kind wrong: ' + result.escalations[0].kind })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 13: 2-level e2e smoke — buildLevel() is stateless; two sequential
# calls each produce independent {parked, escalations}. The second call
# picks up globalThis.args for level-2 items.
# ============================================================================
run_node_case "2-level e2e smoke: two buildLevel() calls, each independent and stateless" "
$PREAMBLE

// Level 1: 2 green items
happyMachinery('l1a', 701, 'a1a31');
happyMachinery('l1b', 702, 'a1b32');
happyWorker('l1a');
happyWorker('l1b');

// Level 2: 2 green items (different slugs)
happyMachinery('l2a', 703, 'a2a33');
happyMachinery('l2b', 704, 'a2b34');
happyWorker('l2a');
happyWorker('l2b');

const mod = await loadLevel();

// --- Level 1 ---
globalThis.args = { ...baseArgs, items: [
  { slug: 'l1a', branch: 'build/l1a', title: 'L1 A', kind: 'impl' },
  { slug: 'l1b', branch: 'build/l1b', title: 'L1 B', kind: 'impl' },
]};
const r1 = await mod.default();

if ((r1.parked ?? []).length !== 2)
  { console.log(JSON.stringify({ ok: false, reason: 'L1 expected 2 parked: ' + JSON.stringify(r1) })); process.exit(0); }
if ((r1.escalations ?? []).length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'L1 unexpected escalation: ' + JSON.stringify(r1) })); process.exit(0); }

// --- Level 2 ---
globalThis.args = { ...baseArgs, items: [
  { slug: 'l2a', branch: 'build/l2a', title: 'L2 A', kind: 'impl' },
  { slug: 'l2b', branch: 'build/l2b', title: 'L2 B', kind: 'impl' },
]};
const r2 = await mod.default();

if ((r2.parked ?? []).length !== 2)
  { console.log(JSON.stringify({ ok: false, reason: 'L2 expected 2 parked: ' + JSON.stringify(r2) })); process.exit(0); }
if ((r2.escalations ?? []).length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'L2 unexpected escalation: ' + JSON.stringify(r2) })); process.exit(0); }

// The two parked sets are disjoint (no slug collision)
const allSlugs = [...r1.parked, ...r2.parked].map(p => p.slug);
const uniqueSlugs = new Set(allSlugs);
if (uniqueSlugs.size !== 4)
  { console.log(JSON.stringify({ ok: false, reason: 'slug collision between levels: ' + JSON.stringify(allSlugs) })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 13.5: dep-merge precondition gate (#108) — a level's worktree is created
# only after every depends-on target has MERGED to origin/<default>.
#
# Root cause of #108 is level ORDERING: a dependent item's worker must build and
# self-verify against MERGED dependency code, not a pre-merge base. driveItem's
# 3b-0 gate runs `worktree.sh deps-merged` BEFORE `worktree.sh create` whenever
# item.dependsOn carries SHAs. This test drives ONE level with two independent
# dependent items:
#   - l2ok:      deps-merged → DEPS_MERGED → worktree created, item parks [m].
#   - l2blocked: deps-merged → DEPS_UNMERGED → item escalates 'dep-not-merged'
#                with NO worktree create and NO worker spawned (nothing is built
#                against a stale/pre-merge base). Its sibling still parks.
# ============================================================================
run_node_case "dep-merge gate (#108): DEPS_UNMERGED blocks worktree create + worker; DEPS_MERGED proceeds; sibling parks" "
$PREAMBLE

// l2ok: dep gate passes, then the normal green machinery sequence.
setMachinery('l2ok',
  { outcome: 'DEPS_MERGED' },
  { outcome: 'CREATED', path: '/tmp/repo.wt/l2ok' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'a235' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'a235', branch: 'build/l2ok' },
  { outcome: 'PR_OPENED', pr_number: 811 },
  { outcome: 'CI_GREEN' },
);
happyWorker('l2ok');

// l2blocked: dep gate reports an unmerged dependency — the ONLY machinery call it
// should ever make. No CREATED registered: if the code wrongly reached
// worktree.sh create, the machinery mock would throw 'label exhausted'.
setMachinery('l2blocked', { outcome: 'DEPS_UNMERGED', unmerged: ['adeeed17'] });

globalThis.args = { ...baseArgs, items: [
  { slug: 'l2ok',      branch: 'build/l2ok',      title: 'L2 OK',      kind: 'impl', acceptance: ['c'],
    dependsOn: [{ slug: 'l1', sha: 'a1eed2f' }] },
  { slug: 'l2blocked', branch: 'build/l2blocked', title: 'L2 Blocked', kind: 'impl', acceptance: ['c'],
    dependsOn: [{ slug: 'l1', sha: 'a1eed30' }] },
]};

const mod = await loadLevel();
const result = await mod.default();

const parked = result.parked ?? [];
const escalations = result.escalations ?? [];

// l2ok parks; l2blocked escalates.
if (parked.length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 1 parked, got ' + JSON.stringify(result) })); process.exit(0); }
if (parked[0].slug !== 'l2ok' || parked[0].pr !== 811)
  { console.log(JSON.stringify({ ok: false, reason: 'wrong item parked: ' + JSON.stringify(parked[0]) })); process.exit(0); }
if (escalations.length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 1 escalation, got ' + JSON.stringify(escalations) })); process.exit(0); }
if (escalations[0].slug !== 'l2blocked' || escalations[0].kind !== 'dep-not-merged')
  { console.log(JSON.stringify({ ok: false, reason: 'wrong escalation: ' + JSON.stringify(escalations[0]) })); process.exit(0); }

// The gate is ORDERED before create and SHORT-CIRCUITS it: l2blocked must run its
// deps-merged step but NEVER the worktree-create step, and NEVER spawn a worker
// — nothing was built against the pre-merge base. Both steps now ride ONE
// prelude executor (temperloop#942), so this asserts on the steps the batch
// actually RAN rather than on per-command agent labels.
const blockedSteps = stepsRun('l2blocked');
if (JSON.stringify(blockedSteps) !== JSON.stringify(['deps-merged']))
  { console.log(JSON.stringify({ ok: false, reason: 'l2blocked must run deps-merged and STOP (no worktree create): ' + JSON.stringify(blockedSteps) })); process.exit(0); }
const blockedPrelude = callLog.filter(c => c.opts.label === 'prelude:l2blocked');
if (blockedPrelude.length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'expected exactly 1 prelude executor for l2blocked, got ' + blockedPrelude.length })); process.exit(0); }
const blockedWorker = callLog.filter(c => c.opts.label === 'worker:l2blocked');
if (blockedWorker.length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'l2blocked spawned a worker despite unmerged dep: ' + JSON.stringify(blockedWorker) })); process.exit(0); }

// And the gate runs BEFORE create for the passing item too — in ONE prelude
// executor whose steps are ordered deps-merged → worktree.
const okSteps = stepsRun('l2ok').slice(0, 2);
if (JSON.stringify(okSteps) !== JSON.stringify(['deps-merged', 'worktree']))
  { console.log(JSON.stringify({ ok: false, reason: 'gate not ordered before create for l2ok: ' + JSON.stringify(okSteps) })); process.exit(0); }
if (callLog.filter(c => c.opts.label === 'prelude:l2ok').length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'l2ok prelude must be ONE executor call, not one per command' })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 14: deploy-discovery — ~/.claude/workflows/build-level.mjs resolves
# The install-claude Makefile target symlinks claude/* into ~/.claude/.
# We verify the source file exists and the installed path resolves.
# ============================================================================
echo ""
echo "--- deploy-discovery: ~/.claude/workflows/build-level.mjs resolves ---"
INSTALL_TARGET="$HOME/.claude/workflows/build-level.mjs"
WORKFLOWS_LINK="$HOME/.claude/workflows"

if [ -f "$INSTALL_TARGET" ]; then
  echo "PASS: deploy-discovery — $INSTALL_TARGET exists and resolves"
elif [ -L "$WORKFLOWS_LINK" ] && [ -f "$WORKFLOWS_LINK/build-level.mjs" ]; then
  echo "PASS: deploy-discovery — $WORKFLOWS_LINK is a symlink dir containing build-level.mjs"
else
  # Install not yet run in this environment. Verify the source .mjs is present
  # and the Makefile's install-claude target would place it at the right path.
  # (The target symlinks claude/* → ~/.claude/*; claude/workflows/ → ~/.claude/workflows.)
  REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && cd ../../../.. && pwd)"
  SOURCE="$REPO_ROOT/claude/workflows/build-level.mjs"
  if [ -f "$SOURCE" ]; then
    echo "PASS: deploy-discovery — source $SOURCE exists; make install-claude links claude/workflows → ~/.claude/workflows"
  else
    echo "FAIL: deploy-discovery — source .mjs not found at $SOURCE" >&2
    exit 1
  fi
fi

# ============================================================================
# TEST 15: continuation (3d-esc escalation-resume) — onlySlugs + verdicts
# Given args.onlySlugs=[slug] + args.verdicts[slug].verdict_section, the
# re-spawned worker prompt CONTAINS the injected verdict block, the existing
# worktree is REUSED (NO worktree.sh create force-recreate, NO claim re-run),
# and the item drives to parked. Siblings NOT in onlySlugs are left untouched.
# ============================================================================
run_node_case "continuation: onlySlugs+verdicts → verdict injected, worktree reused, no re-claim" "
$PREAMBLE

// The continued item resumes at 3c (worker). Its machinery sequence therefore has
// NO 'CREATED' (worktree create is skipped) and NO claim — it begins at the
// gate (3e.5). If driveItem wrongly ran worktree.sh create or claim.sh, it
// would consume an extra machinery entry here and the outcome would desync.
setMachinery('item-cont',
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'ac12' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'ac12', branch: 'build/item-cont' },
  { outcome: 'PR_OPENED', pr_number: 901 },
  { outcome: 'CI_GREEN' },
);
setWorker('item-cont',
  { status: 'done', summary: 'resumed with verdict', acceptance_results: [{ criterion: 'c', passed: true, evidence: 'e' }], commits: [] }
);

const VERDICT_BLOCK = '## Design verdict — item-cont\\nDecision: use option A (the seam interface).\\nRationale: keeps the contract stable.';

// Capture the worker prompt to assert the verdict block is injected, and any
// claim/worktree machinery call to assert it was skipped.
let workerPromptSeen = '';
let sawCreateOrClaim = false;
const origAgent = globalThis.agent;
globalThis.agent = async function(prompt, opts={}) {
  const label = opts.label || '';
  if (isWorkerCall(opts) && label.startsWith('worker:item-cont')) {
    workerPromptSeen = String(prompt);
  }
  // temperloop#942: claim + worktree create ride the batched prelude executor.
  // A continuation must emit NO prelude executor at all (both its steps are
  // skipped, so the step list is empty and runMachineryBatch spawns nothing).
  if (label.startsWith('prelude:item-cont')) {
    sawCreateOrClaim = true;
  }
  return origAgent(prompt, opts);
};

// Board ON + ghIssue would normally fire a claim; on a continuation it must be
// skipped. Full items array passed; onlySlugs selects only the continued slug.
globalThis.args = {
  ...baseArgs,
  board: 3,
  claimCmd: '/fake/claim.sh',
  items: [
    { slug: 'item-parked', branch: 'build/item-parked', title: 'Already Parked', kind: 'impl', ghIssue: 70 },
    { slug: 'item-cont',   branch: 'build/item-cont',   title: 'Continued Item', kind: 'impl', ghIssue: 71, acceptance: ['c'] },
  ],
  onlySlugs: ['item-cont'],
  verdicts: { 'item-cont': { kind: 'design-fork', verdict_section: VERDICT_BLOCK } },
};

const mod = await loadLevel();
const result = await mod.default();

// Only the continued slug is driven; the parked sibling is untouched.
if ((result.parked ?? []).length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 1 parked (only continued slug): ' + JSON.stringify(result) })); process.exit(0); }
if ((result.escalations ?? []).length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'unexpected escalation: ' + JSON.stringify(result) })); process.exit(0); }
if (result.parked[0].slug !== 'item-cont')
  { console.log(JSON.stringify({ ok: false, reason: 'wrong slug driven: ' + result.parked[0].slug })); process.exit(0); }
if (result.parked[0].pushed_sha !== 'ac12')
  { console.log(JSON.stringify({ ok: false, reason: 'pushed_sha wrong: ' + result.parked[0].pushed_sha })); process.exit(0); }

// The verdict block must be injected into the re-spawned worker's prompt.
if (!workerPromptSeen.includes('use option A (the seam interface)'))
  { console.log(JSON.stringify({ ok: false, reason: 'verdict block NOT injected into worker prompt: ' + workerPromptSeen.slice(0,300) })); process.exit(0); }
if (!workerPromptSeen.includes('Design verdict — item-cont'))
  { console.log(JSON.stringify({ ok: false, reason: 'verdict heading missing from worker prompt' })); process.exit(0); }

// The existing worktree must be REUSED: no worktree.sh create, no claim.sh.
if (sawCreateOrClaim)
  { console.log(JSON.stringify({ ok: false, reason: 'continuation ran a prelude executor (worktree create / claim) — should reuse/skip' })); process.exit(0); }

// Belt-and-suspenders: no claim/worktree STEP ran for the continued slug — an
// empty prelude step list means runMachineryBatch spawns no executor at all.
const preludeSteps = stepsRun('item-cont').filter(k => k === 'claim' || k === 'worktree' || k === 'deps-merged');
if (preludeSteps.length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'continuation ran prelude steps: ' + JSON.stringify(preludeSteps) })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 16: acceptance-string — item.acceptance as a single STRING (the shape
# /sweep passes) must work, not throw on .map (#437 real-run bug).
# ============================================================================
run_node_case "acceptance-string: item.acceptance as a string → parks, no .map throw (#437)" "
$PREAMBLE
happyMachinery('strone', 201, 'a7c');
happyWorker('strone');
globalThis.args = { ...baseArgs, items: [
  { slug: 'strone', branch: 'build/strone', title: 'String acc', kind: 'impl', acceptance: '(self-verify the issue is resolved)' },
]};
const mod = await loadLevel();
const result = await mod.default();
const parked = result.parked ?? [];
const escalations = result.escalations ?? [];
if (parked.length !== 1 || escalations.length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'string acceptance: expected 1 parked / 0 esc, got ' + JSON.stringify(result) })); process.exit(0); }
console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 17: worker-throw — a THROW inside driveItem must become a worker-error
# escalation, never silently dropped to null by parallel() (#437 no-silent-stall).
# ============================================================================
run_node_case "worker-throw: a driveItem throw → worker-error escalation, not silently dropped (#437)" "
$PREAMBLE
globalThis.agent = async () => { throw new Error('boom from agent'); };
globalThis.args = { ...baseArgs, items: [
  { slug: 'boomer', branch: 'build/boomer', title: 'Throws', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
const result = await mod.default();
const parked = result.parked ?? [];
const escalations = result.escalations ?? [];
if (parked.length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'throw: expected 0 parked, got ' + JSON.stringify(parked) })); process.exit(0); }
if (escalations.length !== 1 || escalations[0].kind !== 'worker-error')
  { console.log(JSON.stringify({ ok: false, reason: 'throw: expected 1 worker-error escalation, got ' + JSON.stringify(escalations) })); process.exit(0); }
console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 18: null worker verdict — main path. agent() returns null once, auto-retry
# returns a valid done verdict → item parks successfully.
# ============================================================================
run_node_case "null-worker-retry: agent returns null once, retries, parks on second call (#542)" "
$PREAMBLE
// Machinery: normal happy path, plus the temperloop#939 recover-probe that now
// runs on the null return BEFORE the retry (RECOVER_NONE → retry exactly as before).
setMachinery('retryitem',
  { outcome: 'CREATED', path: '/tmp/repo.wt/retryitem' },
  noSideEffects(),
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'ae50' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'ae50', branch: 'build/retryitem' },
  { outcome: 'PR_OPENED', pr_number: 10 },
  { outcome: 'CI_GREEN' },
);
// Worker: first call null (transient API error), second call done (retry succeeds)
setWorker('retryitem',
  null,
  { status: 'done', summary: 'retry worked', acceptance_results: [{ criterion: 'c', passed: true, evidence: 'e' }], commits: [] }
);
globalThis.args = { ...baseArgs, items: [
  { slug: 'retryitem', branch: 'build/retryitem', title: 'Retry item', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
const result = await mod.default();
const parked = result.parked ?? [];
const escalations = result.escalations ?? [];
if (parked.length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'null-retry: expected 1 parked, got ' + JSON.stringify({ parked, escalations }) })); process.exit(0); }
if (escalations.length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'null-retry: expected 0 escalations, got ' + JSON.stringify(escalations) })); process.exit(0); }
console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 19: null worker verdict — persistent null (both calls return null) must
# escalate as worker-error, not throw a TypeError.
# Machinery must be seeded through worktree creation (3b) since that runs before 3c.
# ============================================================================
run_node_case "null-worker-persistent: agent returns null twice → worker-error escalation, no TypeError (#542)" "
$PREAMBLE
// Machinery: only worktree creation is needed; worker escalates before gate/scan/push/PR/CI
setMachinery('nullitem', { outcome: 'CREATED', path: '/tmp/repo.wt/nullitem' });
// Worker: both initial call and the one auto-retry return null
setWorker('nullitem', null, null);
globalThis.args = { ...baseArgs, items: [
  { slug: 'nullitem', branch: 'build/nullitem', title: 'Null item', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
const result = await mod.default();
const parked = result.parked ?? [];
const escalations = result.escalations ?? [];
if (parked.length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'null-persistent: expected 0 parked, got ' + JSON.stringify(parked) })); process.exit(0); }
if (escalations.length !== 1 || escalations[0].kind !== 'worker-error')
  { console.log(JSON.stringify({ ok: false, reason: 'null-persistent: expected 1 worker-error escalation, got ' + JSON.stringify(escalations) })); process.exit(0); }
if (!escalations[0].payload.retryable)
  { console.log(JSON.stringify({ ok: false, reason: 'null-persistent: expected retryable:true in payload, got ' + JSON.stringify(escalations[0].payload) })); process.exit(0); }
console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 20: null spike verdict — spike worker returning null escalates as
# worker-error with retryable:true (no retry on spike path since read-only).
# ============================================================================
run_node_case "null-spike: spike agent returns null → worker-error escalation (#542)" "
$PREAMBLE
// Spike: no machinery calls (spikes skip all machinery steps); worker returns null
setWorker('spikenull', null);
globalThis.args = { ...baseArgs, items: [
  { slug: 'spikenull', branch: 'build/spikenull', title: 'Null spike', kind: 'spike', acceptance: ['c'] },
]};
const mod = await loadLevel();
const result = await mod.default();
const parked = result.parked ?? [];
const escalations = result.escalations ?? [];
if (parked.length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'null-spike: expected 0 parked, got ' + JSON.stringify(parked) })); process.exit(0); }
if (escalations.length !== 1 || escalations[0].kind !== 'worker-error')
  { console.log(JSON.stringify({ ok: false, reason: 'null-spike: expected 1 worker-error escalation, got ' + JSON.stringify(escalations) })); process.exit(0); }
if (!escalations[0].payload.retryable)
  { console.log(JSON.stringify({ ok: false, reason: 'null-spike: expected retryable:true in payload, got ' + JSON.stringify(escalations[0].payload) })); process.exit(0); }
console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 21: null cifix verdict — CI-fix agent returning null escalates as
# ci-failed with retryable:true, not a TypeError.
# ============================================================================
run_node_case "null-cifix: ci-fix agent returns null → ci-failed escalation, no TypeError (#542)" "
$PREAMBLE
// Machinery: normal path up to CI_FAILED, then fix-spawn (worker) returns null
happyMachinery('cifixnull', 20, 'acf0f');
// Override ci-poll in machineryMap to return CI_FAILED
machineryMap.set('cifixnull', [
  { outcome: 'CREATED', path: '/tmp/repo.wt/cifixnull' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'acf0f' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'acf0f', branch: 'build/cifixnull' },
  { outcome: 'PR_OPENED', pr_number: 20 },
  { outcome: 'CI_FAILED', failed_run_ids: [1] },
]);
// Worker: first call (main) succeeds; second call (ci-fix re-spawn) returns null
setWorker('cifixnull',
  { status: 'done', summary: 'main done', acceptance_results: [{ criterion: 'c', passed: true, evidence: 'e' }], commits: [] },
  null
);
// ci-fix worker label is 'worker-cifix:slug' — routes via workerMap under same slug
// but needs to handle the cifix label too; override slugFromLabel isn't possible here
// so we rely on the workerMap fallback logic (shift from same queue)
globalThis.args = { ...baseArgs, items: [
  { slug: 'cifixnull', branch: 'build/cifixnull', title: 'CI fix null', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
const result = await mod.default();
const parked = result.parked ?? [];
const escalations = result.escalations ?? [];
if (parked.length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'null-cifix: expected 0 parked, got ' + JSON.stringify(parked) })); process.exit(0); }
if (escalations.length !== 1 || escalations[0].kind !== 'ci-failed')
  { console.log(JSON.stringify({ ok: false, reason: 'null-cifix: expected 1 ci-failed escalation, got ' + JSON.stringify(escalations) })); process.exit(0); }
if (!escalations[0].payload.retryable)
  { console.log(JSON.stringify({ ok: false, reason: 'null-cifix: expected retryable:true in payload, got ' + JSON.stringify(escalations[0].payload) })); process.exit(0); }
console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 21b: THROWING cifix verdict — CI-fix agent() THROWING (a
# StructuredOutput-absent / retry-cap-exceeded subagent, #939's __throw shape)
# escalates as ci-failed with retryable:true, exactly like the sibling
# bare-null case above — NOT an uncaught exception, and NOT a generic
# top-level worker-error (temperloop#2065 review round 1 [HIGH]). Also proves
# the worker-usage.sh emit call for the CI-fix retry actually ran despite the
# throw, by checking callLog for its label — before the fix this call was
# skipped entirely (never reached), silently dropping the retry's cost.
# ============================================================================
run_node_case "throw-cifix: ci-fix agent THROWS → ci-failed escalation (not worker-error), and its usage-emit call still ran (temperloop#2065 review round 1 HIGH)" "
$PREAMBLE
happyMachinery('cifixthrow', 21, 'acf1f');
machineryMap.set('cifixthrow', [
  { outcome: 'CREATED', path: '/tmp/repo.wt/cifixthrow' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'acf1f' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'acf1f', branch: 'build/cifixthrow' },
  { outcome: 'PR_OPENED', pr_number: 21 },
  { outcome: 'CI_FAILED', failed_run_ids: [1] },
]);
// Worker: first call (main) succeeds; second call (ci-fix re-spawn) THROWS —
// the #939 __throw shape, faithfully simulating a StructuredOutput-absent /
// retry-cap-exceeded subagent (an EXCEPTION, not a null return).
setWorker('cifixthrow',
  { status: 'done', summary: 'main done', acceptance_results: [{ criterion: 'c', passed: true, evidence: 'e' }], commits: [] },
  { __throw: 'ci-fix boom' }
);
globalThis.args = { ...baseArgs, items: [
  { slug: 'cifixthrow', branch: 'build/cifixthrow', title: 'CI fix throw', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
const result = await mod.default();
const parked = result.parked ?? [];
const escalations = result.escalations ?? [];
if (parked.length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'throw-cifix: expected 0 parked, got ' + JSON.stringify(parked) })); process.exit(0); }
// Before the fix: this throw propagated uncaught past ciPollLoop/driveItem to
// the top-level driveItem(item).catch(...), which converts ANY throw into a
// generic 'worker-error' escalation — NOT 'ci-failed'. That mismatch is the
// discriminating assertion.
if (escalations.length !== 1 || escalations[0].kind !== 'ci-failed')
  { console.log(JSON.stringify({ ok: false, reason: 'throw-cifix: expected 1 ci-failed escalation (got a generic worker-error before the fix), got ' + JSON.stringify(escalations) })); process.exit(0); }
if (!escalations[0].payload.retryable)
  { console.log(JSON.stringify({ ok: false, reason: 'throw-cifix: expected retryable:true in payload, got ' + JSON.stringify(escalations[0].payload) })); process.exit(0); }
// The retry's own workerUsageEmit() call must have run despite the throw —
// before the fix it was skipped entirely (unreachable code after the bare
// agent() call that threw), so this label never appeared in callLog.
const cifixUsageCalls = callLog.filter(c => c.opts.label === 'worker-usage:cifixthrow#worker-cifix:cifixthrow');
if (cifixUsageCalls.length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'throw-cifix: expected the ci-fix retry usage-emit call to have run exactly once despite the throw, got ' + cifixUsageCalls.length + ' — callLog labels: ' + JSON.stringify(callLog.map(c => c.opts.label)) })); process.exit(0); }
console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 22: CONFLICTING merge state — escalates merge-conflict on first slice,
# no full CI_POLL_TOTAL_SECS spin (#543). ci-poll.sh is never called.
# ============================================================================
run_node_case "merge-conflict: CONFLICTING PR escalates merge-conflict without spinning (#543)" "
$PREAMBLE

// Machinery through push + PR open; NO ci-poll entry (merge-check fires first, escalates)
setMachinery('item-conflict543',
  { outcome: 'CREATED', path: '/tmp/repo.wt/item-conflict543' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'acf0b' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'acf0b', branch: 'build/item-conflict543' },
  { outcome: 'PR_OPENED', pr_number: 543 },
  // No CI_GREEN/CI_FAILED/TIMEOUT entries: if ci-poll.sh fires, it consumes
  // from an exhausted machineryMap → ERROR fallback → test would see ci-failed, not
  // merge-conflict. The absence of an entry here proves ci-poll was skipped.
);
happyWorker('item-conflict543');
// Override merge-check to return CONFLICTING on the first poll slice.
setMergeCheck('item-conflict543', { mergeable: 'CONFLICTING', mergeStateStatus: 'DIRTY' });

globalThis.args = { ...baseArgs, items: [
  { slug: 'item-conflict543', branch: 'build/item-conflict543', title: 'Conflict PR', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();

const parked = result.parked ?? [];
const escalations = result.escalations ?? [];

if (parked.length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'merge-conflict: expected 0 parked, got ' + JSON.stringify(parked) })); process.exit(0); }
if (escalations.length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'merge-conflict: expected 1 escalation, got ' + JSON.stringify(escalations) })); process.exit(0); }
if (escalations[0].kind !== 'merge-conflict')
  { console.log(JSON.stringify({ ok: false, reason: 'merge-conflict: escalation kind wrong: ' + escalations[0].kind })); process.exit(0); }
if (escalations[0].slug !== 'item-conflict543')
  { console.log(JSON.stringify({ ok: false, reason: 'merge-conflict: escalation slug wrong: ' + escalations[0].slug })); process.exit(0); }
if (escalations[0].payload.mergeable !== 'CONFLICTING')
  { console.log(JSON.stringify({ ok: false, reason: 'merge-conflict: payload.mergeable wrong: ' + JSON.stringify(escalations[0].payload) })); process.exit(0); }
if (escalations[0].payload.pr !== 543)
  { console.log(JSON.stringify({ ok: false, reason: 'merge-conflict: payload.pr wrong: ' + JSON.stringify(escalations[0].payload) })); process.exit(0); }

// Confirm ci-poll was NOT run. The merge-state probe and the poll slices share
// ONE ci-batch executor now (temperloop#942), so the assertion is on the STEPS
// the batch actually ran: the conflicting merge-state must short-circuit the
// batch before any ci-poll.sh slice burns 4 minutes.
const ciSteps = stepsRun('item-conflict543');
if (ciSteps.includes('ci-poll'))
  { console.log(JSON.stringify({ ok: false, reason: 'merge-conflict: ci-poll.sh ran (should be short-circuited): ' + JSON.stringify(ciSteps) })); process.exit(0); }
if (!ciSteps.includes('merge-state'))
  { console.log(JSON.stringify({ ok: false, reason: 'merge-conflict: merge-state probe never ran: ' + JSON.stringify(ciSteps) })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 23: DIRTY merge state (MERGEABLE field absent, only mergeStateStatus=DIRTY)
# Also verifies a non-conflicting sibling parks normally (existing poll unaffected).
# ============================================================================
run_node_case "merge-conflict: mergeStateStatus=DIRTY alone escalates merge-conflict (#543)" "
$PREAMBLE

// Item that is DIRTY (mergeStateStatus only, mergeable field missing/UNKNOWN)
setMachinery('item-dirty',
  { outcome: 'CREATED', path: '/tmp/repo.wt/item-dirty' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'ad18' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'ad18', branch: 'build/item-dirty' },
  { outcome: 'PR_OPENED', pr_number: 544 },
);
happyWorker('item-dirty');
setMergeCheck('item-dirty', { mergeable: 'UNKNOWN', mergeStateStatus: 'DIRTY' });

// Clean sibling parks normally
happyMachinery('item-clean', 545, 'acea10');
happyWorker('item-clean');
// No setMergeCheck → default { mergeable: 'MERGEABLE', mergeStateStatus: 'CLEAN' }

globalThis.args = { ...baseArgs, items: [
  { slug: 'item-dirty', branch: 'build/item-dirty', title: 'Dirty PR',  kind: 'impl', acceptance: ['c'] },
  { slug: 'item-clean', branch: 'build/item-clean', title: 'Clean PR', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();

const parked = result.parked ?? [];
const escalations = result.escalations ?? [];

if (parked.length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'dirty: expected 1 parked (clean sibling), got ' + JSON.stringify(parked) })); process.exit(0); }
if (parked[0].slug !== 'item-clean')
  { console.log(JSON.stringify({ ok: false, reason: 'dirty: wrong slug parked: ' + parked[0].slug })); process.exit(0); }

if (escalations.length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'dirty: expected 1 escalation, got ' + JSON.stringify(escalations) })); process.exit(0); }
if (escalations[0].kind !== 'merge-conflict')
  { console.log(JSON.stringify({ ok: false, reason: 'dirty: escalation kind wrong: ' + escalations[0].kind })); process.exit(0); }
if (escalations[0].payload.mergeStateStatus !== 'DIRTY')
  { console.log(JSON.stringify({ ok: false, reason: 'dirty: payload.mergeStateStatus wrong: ' + JSON.stringify(escalations[0].payload) })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 24: EXISTS outcome — pr-open returns EXISTS → routed to CI-poll/park-with-pr
# (NOT pr-open-failed escalation). This covers the #544 "already exists" retry
# path: when gh pr create fails because a PR already exists, pr.sh returns
# {outcome:"EXISTS",pr_number,url} and build-level.mjs must adopt it.
# ============================================================================
run_node_case "pr-open EXISTS: EXISTS outcome routes to CI-poll/park-with-pr, not pr-open-failed (#544)" "
$PREAMBLE

setMachinery('item-exists',
  { outcome: 'CREATED', path: '/tmp/repo.wt/item-exists' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'ae1f' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'ae1f', branch: 'build/item-exists' },
  // EXISTS: branch already had an open PR (e.g. create retry after first create succeeded)
  { outcome: 'EXISTS', pr_number: 163, url: 'https://github.com/Towheads/foundation/pull/163' },
  { outcome: 'CI_GREEN' },
);
happyWorker('item-exists');

globalThis.args = { ...baseArgs, items: [
  { slug: 'item-exists', branch: 'build/item-exists', title: 'Existing PR Item', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();

const parked = result.parked ?? [];
const escalations = result.escalations ?? [];

if (parked.length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'EXISTS: expected 1 parked, got ' + JSON.stringify(result) })); process.exit(0); }
if (escalations.length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'EXISTS: expected 0 escalations (should not pr-open-failed), got ' + JSON.stringify(escalations) })); process.exit(0); }
if (parked[0].slug !== 'item-exists')
  { console.log(JSON.stringify({ ok: false, reason: 'EXISTS: wrong slug parked: ' + parked[0].slug })); process.exit(0); }
if (parked[0].pr !== 163)
  { console.log(JSON.stringify({ ok: false, reason: 'EXISTS: pr should be 163 (from EXISTS outcome), got: ' + parked[0].pr })); process.exit(0); }
if (parked[0].pushed_sha !== 'ae1f')
  { console.log(JSON.stringify({ ok: false, reason: 'EXISTS: pushed_sha wrong: ' + parked[0].pushed_sha })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 25: ERROR from pr-open still escalates as pr-open-failed (genuine failure)
# Ensures the EXISTS routing change does NOT swallow real ERROR outcomes.
# ============================================================================
run_node_case "pr-open ERROR: genuine pr-open failure still escalates pr-open-failed (not swallowed by #544)" "
$PREAMBLE

setMachinery('item-prfail',
  { outcome: 'CREATED', path: '/tmp/repo.wt/item-prfail' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'afa4a' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'afa4a', branch: 'build/item-prfail' },
  // Genuine failure (not the already-exists case) → must escalate
  { outcome: 'ERROR', error: 'authentication required' },
);
happyWorker('item-prfail');

globalThis.args = { ...baseArgs, items: [
  { slug: 'item-prfail', branch: 'build/item-prfail', title: 'PR Open Fail Item', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();

const parked = result.parked ?? [];
const escalations = result.escalations ?? [];

if (parked.length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'pr-open-fail: expected 0 parked, got ' + JSON.stringify(parked) })); process.exit(0); }
if (escalations.length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'pr-open-fail: expected 1 escalation, got ' + JSON.stringify(escalations) })); process.exit(0); }
if (escalations[0].kind !== 'pr-open-failed')
  { console.log(JSON.stringify({ ok: false, reason: 'pr-open-fail: escalation kind wrong: ' + escalations[0].kind })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 26: null machinery return at the WORKTREE step (temperloop#72). When the
# auto-mode safety classifier DENIES a machinery command, agent() returns null and
# runMachinery normalizes it to a SPINE_DENIED sentinel. driveItem must escalate a
# clean 'machinery-denied' rather than dereference wtOut.outcome and crash with
# 'null is not an object'.
# ============================================================================
run_node_case "null-machinery-worktree: worktree machinery returns null → machinery-denied escalation, no TypeError (#72)" "
$PREAMBLE
// First machinery call (worktree.sh create, board OFF) returns null (classifier denied).
setMachinery('wtdenied', null);
happyWorker('wtdenied');
globalThis.args = { ...baseArgs, items: [
  { slug: 'wtdenied', branch: 'build/wtdenied', title: 'WT denied', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
const result = await mod.default();
const parked = result.parked ?? [];
const escalations = result.escalations ?? [];
if (parked.length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'null-machinery-worktree: expected 0 parked, got ' + JSON.stringify(parked) })); process.exit(0); }
if (escalations.length !== 1 || escalations[0].kind !== 'machinery-denied')
  { console.log(JSON.stringify({ ok: false, reason: 'null-machinery-worktree: expected 1 machinery-denied escalation, got ' + JSON.stringify(escalations) })); process.exit(0); }
if (escalations[0].payload.step !== 'worktree')
  { console.log(JSON.stringify({ ok: false, reason: 'null-machinery-worktree: expected payload.step=worktree, got ' + JSON.stringify(escalations[0].payload) })); process.exit(0); }
console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 27: null machinery return at the PUSH step (temperloop#72). Same null-guard,
# exercised at 3f-1 push after a clean worker+gate+rebase+scan. Guards the
# second site the crash was reported at (~453/push).
#
# temperloop#942: rebase/scan/push/pr-open now ride ONE 'pr-batch' executor, and a
# classifier denial denies the WHOLE executor call — so the escalation names the
# batch plus its step list rather than a single command. The guard is the same:
# a denied machinery step must park as 'machinery-denied', never crash.
# ============================================================================
run_node_case "null-machinery-push: push machinery returns null → machinery-denied escalation, no TypeError (#72)" "
$PREAMBLE
setMachinery('pushdenied',
  { outcome: 'CREATED', path: '/tmp/repo.wt/pushdenied' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'ad47' },
  { outcome: 'SCAN_CLEAN' },
  null,   // push → classifier denied
);
happyWorker('pushdenied');
globalThis.args = { ...baseArgs, items: [
  { slug: 'pushdenied', branch: 'build/pushdenied', title: 'Push denied', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
const result = await mod.default();
const parked = result.parked ?? [];
const escalations = result.escalations ?? [];
if (parked.length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'null-machinery-push: expected 0 parked, got ' + JSON.stringify(parked) })); process.exit(0); }
if (escalations.length !== 1 || escalations[0].kind !== 'machinery-denied')
  { console.log(JSON.stringify({ ok: false, reason: 'null-machinery-push: expected 1 machinery-denied escalation, got ' + JSON.stringify(escalations) })); process.exit(0); }
if (escalations[0].payload.step !== 'pr-batch')
  { console.log(JSON.stringify({ ok: false, reason: 'null-machinery-push: expected payload.step=pr-batch, got ' + JSON.stringify(escalations[0].payload) })); process.exit(0); }
// The denial must still name WHICH steps were in flight — otherwise the operator
// cannot tell a denied push from a denied rebase.
if (!(escalations[0].payload.steps || []).includes('push'))
  { console.log(JSON.stringify({ ok: false, reason: 'null-machinery-push: payload.steps must name the batched steps, got ' + JSON.stringify(escalations[0].payload) })); process.exit(0); }
// And the mock DID reach the push step before returning null.
if (!stepsRun('pushdenied').includes('push'))
  { console.log(JSON.stringify({ ok: false, reason: 'null-machinery-push: push step never reached: ' + JSON.stringify(stepsRun('pushdenied')) })); process.exit(0); }
console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 28: machineryBinDir de-obfuscation (temperloop#72, root cause 1). When the
# orchestrator passes a pre-resolved input.machineryBinDir, machineryBin emits a PLAIN
# absolute path — the executed worktree/push command line must carry NO nested
# \$(readlink …) command-substitution (what the classifier read as an obfuscated
# bypass). We capture the machinery prompts and assert the resolved path is present
# and no readlink substitution leaks into the executed line.
# ============================================================================
run_node_case "machineryBinDir: pre-resolved dir → plain paths, no readlink in executed machinery command (#72)" "
$PREAMBLE
happyMachinery('deobf', 260, 'adebf15');
happyWorker('deobf');
let machineryPrompts = [];
const origAgent = globalThis.agent;
globalThis.agent = async function(prompt, opts={}) {
  if (isMachineryCall(opts)) machineryPrompts.push(String(prompt));
  return origAgent(prompt, opts);
};
globalThis.args = { ...baseArgs, machineryBinDir: '/resolved/machinery/bin', items: [
  { slug: 'deobf', branch: 'build/deobf', title: 'Deobf', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
const result = await mod.default();
if ((result.parked ?? []).length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'machineryBinDir: expected 1 parked, got ' + JSON.stringify(result) })); process.exit(0); }
// The worktree + push machinery commands must use the plain resolved dir...
const wtPrompt = machineryPrompts.find(p => p.includes('worktree.sh'));
const pushPrompt = machineryPrompts.find(p => p.includes('pr.sh') && p.includes(' push '));
if (!wtPrompt || !wtPrompt.includes('/resolved/machinery/bin/worktree.sh'))
  { console.log(JSON.stringify({ ok: false, reason: 'machineryBinDir: worktree cmd missing plain resolved path: ' + (wtPrompt||'<none>').slice(0,300) })); process.exit(0); }
if (!pushPrompt || !pushPrompt.includes('/resolved/machinery/bin/pr.sh'))
  { console.log(JSON.stringify({ ok: false, reason: 'machineryBinDir: push cmd missing plain resolved path: ' + (pushPrompt||'<none>').slice(0,300) })); process.exit(0); }
// ...and NO nested readlink command-substitution in any machinery command line.
const leaked = machineryPrompts.find(p => p.includes('readlink'));
if (leaked)
  { console.log(JSON.stringify({ ok: false, reason: 'machineryBinDir: readlink substitution leaked into executed machinery command: ' + leaked.slice(0,300) })); process.exit(0); }
console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# Root-cause-1 static guards (temperloop#72).
# (1) machineryBin must PREFER a pre-resolved input.machineryBinDir (plain-path branch),
#     so the executed pr.sh/worktree.sh line need not carry nested readlink.
# (2) The runMachinery / merge-check sub-agent instruction must no longer read as
#     'blindly execute an opaque command' — the 'Do NOT interpret it' phrasing
#     that (with the readlink substitution) tripped the auto-mode classifier is
#     gone.
grep -q 'input.machineryBinDir' "$MJS" \
  || fail "#72: machineryBin must prefer a pre-resolved input.machineryBinDir (de-obfuscated plain-path branch)"
if grep -q 'Do NOT interpret it' "$MJS"; then
  fail "#72: sub-agent instruction still reads as blind-execute ('Do NOT interpret it') — soften it"
fi
# (3) The null-guard must exist: a machineryDenied() detector + a machinery-denied escalation.
grep -q 'function machineryDenied(' "$MJS" \
  || fail "#72: machineryDenied() null/denied detector missing from build-level.mjs"
grep -q "'machinery-denied'" "$MJS" \
  || fail "#72: no 'machinery-denied' escalation emitted — a denied machinery step must park, not crash"
echo "PASS: #72 classifier-detrip + null-guard static guards — machineryBinDir plain-path branch, softened instruction, machineryDenied() + machinery-denied escalation present"

# ============================================================================
# Machinery-resolution regression guard (foundation #560).
# build-level.mjs runs in the Workflow sandbox (no fs/Node API), so the
# build-machinery scripts (worktree.sh/pr.sh/ci-poll.sh) MUST be resolved via the
# bash `machineryBin` fallback (repo-local → foundation), never the old hardcoded
# `${repoRoot}/workflows/scripts/build/<script>` template that broke in a
# stageFind checkout lacking the workflows→foundation symlink. Static-assert the
# fix stays in place. (The runtime behaviour of the emitted resolver is proven
# separately in the PR's executed 4-scenario matrix.)
grep -q '^function machineryBin(' "$MJS" \
  || fail "#560: machineryBin() resolver missing from build-level.mjs"
# The project's OWN vendored gate is resolved DIRECTLY (machineryBin is machinery-only) —
# and against the WORKTREE checkout, not repoRoot, so quality-gates.sh's own
# `cd "$REPO_ROOT"` stays in the worker's tree rather than jumping back to main
# (temperloop#626). It still never routes through machineryBin's foundation fallback.
# shellcheck disable=SC2016  # grepping for the LITERAL ${wt} token in source
grep -q 'const qgBin = `${wt}/scripts/quality-gates.sh`' "$MJS" \
  || fail "#560/#626: qgBin (repo-local quality-gates) must resolve from the worktree (\${wt}), directly — never repoRoot, never machineryBin"
# No machinery call site may regress to the hardcoded `.../workflows/scripts/build/<script>` template.
if grep -nE '\}/workflows/scripts/build/(worktree|pr|ci-poll)\.sh' "$MJS"; then
  fail "#560: a machinery script is still hardcoded to \${repoRoot}/workflows/scripts/build/ — route it through machineryBin()"
fi
# Every machinery invocation (worktree/pr×2/ci-poll) must go through machineryBin — 4 call sites + the def.
sb_refs="$(grep -c 'machineryBin(' "$MJS")"
[ "$sb_refs" -ge 5 ] \
  || fail "#560: expected >=5 machineryBin references (1 def + 4 call sites), found $sb_refs"
echo "PASS: #560 machinery-resolution guard — machineryBin() resolves all machinery scripts; no hardcoded paths; qgBin stays repo-local"

# --- temperloop#68: the 3e.5 gate command must carry `set -o pipefail` so a RED
# quality-gates run can never be swallowed by a downstream pipe/filter (the
# pipe-ate-exit-code defect). A future hand-edit that pipes the gate to capture
# its output would otherwise mask a non-zero gate exit behind the last stage's 0,
# degrading 3e.5 to a silent no-op. Guard the prefix statically. ------------
grep -q 'set -o pipefail; if \[ ! -x' "$MJS" \
  || fail "#68: 3e.5 gate command must prefix 'set -o pipefail' (pipe-ate-exit guard)"
echo "PASS: #68 gate-pipefail guard — 3e.5 gate invocation carries set -o pipefail"

# --- temperloop#115: the 3e.5 gate runMachinery call must pass an explicit Bash-tool
# timeout. The full quality-gates.sh suite runs >2min; without a raised timeout
# the executor's Bash tool SIGTERMs it at the default 120s → a false GATE_FAIL on
# every drive. Guard both the named constant and that the gate call threads it,
# so a future edit can't silently drop the timeout and re-break every drive. ----
grep -q 'const GATE_BASH_TIMEOUT_MS' "$MJS" \
  || fail "#115: GATE_BASH_TIMEOUT_MS constant missing — 3e.5 gate would SIGTERM at 120s"
grep -q 'bashTimeoutMs: GATE_BASH_TIMEOUT_MS' "$MJS" \
  || fail "#115: 3e.5 gate runMachinery call must pass bashTimeoutMs: GATE_BASH_TIMEOUT_MS"
echo "PASS: #115 gate-timeout guard — 3e.5 gate carries an explicit long Bash-tool timeout"

# --- temperloop#2103: the ORDINARY 3f-1 push must carry --allow-rewrite, and so
# must the pr-batch resume push. This is the site the whole issue is about: a
# continuation round's branch was already pushed by an earlier round, 3f-0a then
# rebased it, and a plain push of a rewritten ref can never fast-forward — it
# came back PUSH_REJECTED three times in one live session. The flag is also the
# non-classifier-tripping spelling of the force request (#437), so dropping it
# in favour of a literal `--force` re-opens a second failure mode on the same
# line. The mocked-outcome cases route on step KIND and never look at the
# constructed command text, so without this static floor a future edit could
# drop the flag from either call and nothing would fail until it recurs live. --
_k2103_push_sites="$(grep -cE "push \\$\{sq\(wt\)\} \\$\{sq\(item\.branch\)\} --allow-rewrite" "$MJS")"
[ "$_k2103_push_sites" -eq 2 ] \
  || fail "#2103: expected BOTH push call sites (3f-1 and the pr-batch resume push) to carry --allow-rewrite on the constructed command line, found $_k2103_push_sites"
grep -qF "addPrStep('push', \`\${prBin} push \${sq(wt)} \${sq(item.branch)} --allow-rewrite\`" "$MJS" \
  || fail "#2103: driveItem's 3f-1 addPrStep('push', ...) must literally carry --allow-rewrite — a plain push of a rebased continuation branch is PUSH_REJECTED"
grep -qF "kind: 'push', cmd: \`\${prBin} push \${sq(wt)} \${sq(item.branch)} --allow-rewrite\`" "$MJS" \
  || fail "#2103: recoverLostReturn's resumed push must literally carry --allow-rewrite for the same reason 3f-1 does"
if grep -nE "push \\$\{sq\(wt\)\} \\$\{sq\(item\.branch\)\} --force" "$MJS"; then
  fail "#2103: an item push reverted to a literal --force — use --allow-rewrite (same request, no classifier-visible force token, #437)"
fi
echo "PASS: #2103 both item-push call sites statically carry --allow-rewrite on the constructed command line"

# --- temperloop#1021: the gate budget is a NAMED SETTING, not a bare literal, and
# EVERY caller wires it. The Workflow runtime has no shell, so the .mjs cannot
# source build.config.sh itself — the setting rides the same Step-0 hand-off as
# machinerySoloModel/machineryBatchModel, which means all THREE orchestrators must
# resolve and pass it or the seam silently reverts to the in-file default for that
# caller. Guard the consumer, the config seam, and each producer. ---------------
grep -qF 'input.gateSliceSecs' "$MJS" \
  || fail "#1021: build-level.mjs must read the gate budget from the orchestrator hand-off (input.gateSliceSecs), not a bare literal"
grep -q 'const GATE_MAX_SLICES' "$MJS" \
  || fail "#1021: the 3e.5 slice loop must be BOUNDED (GATE_MAX_SLICES) so a never-finishing suite escalates instead of looping forever"
grep -qF "escalate(item.slug, 'acceptance-gate-timeout'" "$MJS" \
  || fail "#1021: a budget-exhausted 3e.5 run must escalate its OWN kind (acceptance-gate-timeout), never collapse into acceptance-gate-failed"
grep -qF "escalate(item.slug, 'acceptance-gate-failed'" "$MJS" \
  || fail "#1021: a genuinely RED suite must STILL escalate acceptance-gate-failed — the timeout split must not weaken the gate"
_cfg="$(cd "$(dirname "${BASH_SOURCE[0]}")" && cd ../../../.. && pwd)/workflows/scripts/build/build.config.sh"
grep -q 'BUILD_GATE_SLICE_SECS' "$_cfg" \
  || fail "#1021: BUILD_GATE_SLICE_SECS must be declared in build.config.sh (the named-setting seam)"
for _md in build fix sweep; do
  _p="$(cd "$(dirname "${BASH_SOURCE[0]}")" && cd ../../../.. && pwd)/claude/commands/$_md.md"
  grep -q 'BUILD_GATE_SLICE_SECS' "$_p" \
    || fail "#1021: $_md.md Step 0 must resolve BUILD_GATE_SLICE_SECS (every build-level.mjs caller wires it, not /build alone)"
  grep -q 'gateSliceSecs' "$_p" \
    || fail "#1021: $_md.md must pass gateSliceSecs in its build-level.mjs args"
done
unset _md _p _cfg
echo "PASS: #1021 gate-budget guard — named setting, bounded slice loop, timeout/fail split, all three callers wired"

# --- temperloop#1460: the SAME three-caller invariant, for the two hand-offs
# build.md passed alone while sweep.md/fix.md silently omitted them. Both ride
# the identical Step-0 seam as gateSliceSecs above, and both DEGRADE SILENTLY
# when a caller drops them — which is exactly why they need a mechanical guard
# rather than review:
#   (a) machineryBinDir — omitting it makes machineryBin() fall back to the
#       nested $(dirname "$(readlink -f …)") command-substitution the auto-mode
#       classifier denied as an obfuscated-command bypass on --unattended runs
#       (temperloop#72). /sweep's DEFAULT posture is --unattended, so the
#       omission produced recurring machinery-denied bursts on every push step.
#   (b) principlesSummaries / principlesDefaultRepo — omitting them pins that
#       caller's workers on workerPrompt()'s static kernel-only DEGRADED
#       fallback permanently (PR #1439), with no project § Principles applied.
# Guard the resolution site (the plain cd+pwd form / the Step 1.8 reference)
# AND the args hand-off, per caller — a spec that names the value but never
# passes it is the half-wired shape this item found.
for _md in build fix sweep; do
  _p="$(cd "$(dirname "${BASH_SOURCE[0]}")" && cd ../../../.. && pwd)/claude/commands/$_md.md"
  grep -q 'machineryBinDir' "$_p" \
    || fail "#1460: $_md.md must pass machineryBinDir in its build-level.mjs args (every caller wires it — omitting it re-arms the temperloop#72 classifier denial)"
  grep -qF 'cd workflows/scripts/build 2>/dev/null && pwd' "$_p" \
    || fail "#1460: $_md.md Step 0 must resolve machineryBinDir with the plain cd+pwd form (a nested readlink substitution here is the very shape #72 denied)"
  grep -q 'principlesSummaries' "$_p" \
    || fail "#1460: $_md.md must pass principlesSummaries in its build-level.mjs args (omitting it pins that caller's workers on the DEGRADED kernel-only fallback)"
  grep -q 'principlesDefaultRepo' "$_p" \
    || fail "#1460: $_md.md must pass principlesDefaultRepo alongside principlesSummaries (the lookup key workerPrompt() falls back to)"
  grep -q 'Step 1.8' "$_p" \
    || fail "#1460: $_md.md must reference build.md § Step 1.8 as the single principle-resolution implementation (pointer, never a re-derivation)"
done
unset _md _p
echo "PASS: #1460 machineryBinDir + principles hand-off guard — all three callers resolve and pass both"

# ============================================================================
# TEST (K712): worker background-gate stall — prevention + cure
#   The worker prompt MUST embed the FOREGROUND-ONLY contract (prevention), and
#   a null-verdict retry MUST append FOREGROUND_CURE so the retry prompt DIFFERS
#   from the first attempt (cure), then escalate worker-error only after TWO nulls.
# ============================================================================
run_node_case "K712 prevention: workerPrompt embeds the FOREGROUND-ONLY (#1219) contract" "
$PREAMBLE

happyMachinery('fg-item', 900, 'af70');
happyWorker('fg-item');
globalThis.args = { ...baseArgs, items: [
  { slug: 'fg-item', branch: 'build/fg-item', title: 'FG item', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
await mod.default();
const w = callLog.find(c => (c.opts.label||'') === 'worker:fg-item');
if (!w) { console.log(JSON.stringify({ ok: false, reason: 'no worker call logged' })); process.exit(0); }
if (!w.promptFull.includes('FOREGROUND ONLY (#1219)')) { console.log(JSON.stringify({ ok: false, reason: 'worker prompt missing FOREGROUND-ONLY contract' })); process.exit(0); }
console.log(JSON.stringify({ ok: true }));
"

run_node_case "K712 cure: null verdict → retry prompt carries FOREGROUND_CURE, first does not → parked" "
$PREAMBLE

// temperloop#939: the null verdict now runs a recover-probe BEFORE the retry, so
// the machinery sequence carries a RECOVER_NONE (no side-effects → retry as before).
setMachinery('cure-item',
  { outcome: 'CREATED', path: '/tmp/repo.wt/cure-item' },
  noSideEffects(),
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'ace68' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'ace68', branch: 'build/cure-item' },
  { outcome: 'PR_OPENED', pr_number: 901 },
  { outcome: 'CI_GREEN' },
);
setWorker('cure-item', null, { status: 'done', summary: 'cured', acceptance_results: [{ criterion: 'c', passed: true, evidence: 'e' }], commits: [] });
globalThis.args = { ...baseArgs, items: [
  { slug: 'cure-item', branch: 'build/cure-item', title: 'Cure item', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
const result = await mod.default();
const parked = result.parked ?? [];
const first = callLog.find(c => (c.opts.label||'') === 'worker:cure-item');
const retry = callLog.find(c => (c.opts.label||'') === 'worker:cure-item#retry');
let reason = null;
if (!retry) reason = 'no retry call after null verdict';
else if (!retry.promptFull.includes('Re-spawn cure (#1219)')) reason = 'retry prompt missing FOREGROUND_CURE';
else if (first && first.promptFull.includes('Re-spawn cure (#1219)')) reason = 'first prompt must NOT carry the cure';
else if (parked.length !== 1) reason = 'expected 1 parked item after cured retry, got ' + parked.length;
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K712 regression: null verdict TWICE → worker-error escalation (unchanged)" "
$PREAMBLE

// Two nulls with a RECOVER_NONE probe after each (temperloop#939) — no
// observable side-effects, so the escalation path is unchanged.
setMachinery('err-item',
  { outcome: 'CREATED', path: '/tmp/repo.wt/err-item' },
  noSideEffects(),
  noSideEffects(),
);
setWorker('err-item', null, null);
globalThis.args = { ...baseArgs, items: [
  { slug: 'err-item', branch: 'build/err-item', title: 'Err item', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
const result = await mod.default();
const esc = result.escalations ?? [];
if (esc.length !== 1 || esc[0].kind !== 'worker-error') { console.log(JSON.stringify({ ok: false, reason: 'expected 1 worker-error escalation, got ' + JSON.stringify(esc.map(e => e.kind)) })); process.exit(0); }
console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST (K1530): workerPrompt must tell the worker to add its own
#   changelog.d/ fragment for contract-surface changes — the same way it is
#   told to run the gates (temperloop#1530). Asserts the section reaches the
#   worker's actual prompt (not just that the function exists — that's the
#   static guard below), and that it names both the README pointer (shape
#   lives in ONE place) and the commit-trailer opt-out (the channel that
#   works before a PR exists).
# ============================================================================
run_node_case "K1530 prevention: workerPrompt embeds the changelog-fragment instruction" "
$PREAMBLE

happyMachinery('cl-item', 900, 'ac66');
happyWorker('cl-item');
globalThis.args = { ...baseArgs, items: [
  { slug: 'cl-item', branch: 'build/cl-item', title: 'CL item', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
await mod.default();
const w = callLog.find(c => (c.opts.label||'') === 'worker:cl-item');
let reason = null;
if (!w) reason = 'no worker call logged';
else if (!w.promptFull.includes('Changelog fragment — contract-surface changes need one (temperloop#1530)')) reason = 'worker prompt missing the changelog-fragment section';
else if (!w.promptFull.includes('changelog.d/README.md')) reason = 'worker prompt must point at changelog.d/README.md rather than restate the fragment shape';
else if (!w.promptFull.includes('Changelog: none — <reason>')) reason = 'worker prompt must name the recorded commit-trailer opt-out';
else if (!w.promptFull.includes('changelog.d/cl-item.<category>.md')) reason = 'worker prompt must name a concrete fragment path derived from the item slug';
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

# --- K1530 static lockstep guards: build.md §3c and workerPrompt() must carry
# the SAME changelog-fragment instruction, so a future edit to either one
# cannot silently drop the other half — the exact defect this item fixes (a
# worker never told to add a fragment, so every contract-surface PR fails CI
# once by design). Mirrors the K1432/K1319 lockstep idiom above. -------------
grep -q 'function changelogFragmentSection' "$MJS" \
  || fail "#1530: changelogFragmentSection() missing — workerPrompt must embed the changelog-fragment instruction as its own self-contained section"
grep -q '## Changelog fragment — contract-surface changes need one (temperloop#1530)' "$MJS" \
  || fail "#1530: workerPrompt() must embed the '## Changelog fragment' section"
grep -q 'changelog.d/README.md' "$MJS" \
  || fail "#1530: workerPrompt() must point the worker at changelog.d/README.md rather than restate the fragment's filename grammar"
grep -q 'Changelog: none — <reason>' "$MJS" \
  || fail "#1530: workerPrompt() must name the recorded commit-trailer opt-out (the channel that works before a PR exists)"
grep -q '\.\.\.changelogFragmentSection(item)' "$MJS" \
  || fail "#1530: workerPrompt()'s returned array must splice in changelogFragmentSection(item) — a defined-but-unused function never reaches the worker"
K1530_BUILD_MD="$REPO_ROOT/claude/commands/build.md"
[ -f "$K1530_BUILD_MD" ] \
  || fail "#1530: claude/commands/build.md is missing — the prose half of this contract pair cannot be verified"
grep -q 'temperloop#1530' "$K1530_BUILD_MD" \
  || fail "#1530: build.md §3c must name temperloop#1530 alongside the changelog-fragment instruction (lockstep with build-level.mjs)"
grep -q 'changelog.d/README.md' "$K1530_BUILD_MD" \
  || fail "#1530: build.md §3c must point the worker at changelog.d/README.md rather than restate the fragment's filename grammar"
grep -q 'Changelog: none — <reason>' "$K1530_BUILD_MD" \
  || fail "#1530: build.md §3c must name the recorded commit-trailer opt-out (lockstep with build-level.mjs)"
echo "PASS: #1530 changelog-fragment guard — workerPrompt embeds the add-a-fragment instruction (README pointer + recorded opt-out); build.md §3c in lockstep"

# ============================================================================
# TEST (K1931): workerPrompt must tell the worker to register a new/renamed
#   gate, validator, checker, test, or setting in the relevant registry
#   BEFORE running its own `--scoped` gate (temperloop#1931). Asserts the
#   section reaches the worker's actual prompt (not just that the function
#   exists — that's the static guard below) and names every registry the
#   issue's observed instance actually missed.
# ============================================================================
run_node_case "K1931 prevention: workerPrompt embeds the gate-registration checklist" "
$PREAMBLE

happyMachinery('gr-item', 900, 'a71');
happyWorker('gr-item');
globalThis.args = { ...baseArgs, items: [
  { slug: 'gr-item', branch: 'build/gr-item', title: 'GR item', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
await mod.default();
const w = callLog.find(c => (c.opts.label||'') === 'worker:gr-item');
let reason = null;
if (!w) reason = 'no worker call logged';
else if (!w.promptFull.includes('New gate script? Register it before running the scoped gate (temperloop#1931)')) reason = 'worker prompt missing the gate-registration checklist section';
else if (!w.promptFull.includes('check-surface-registry.tsv')) reason = 'worker prompt must name check-surface-registry.tsv';
else if (!w.promptFull.includes('check-surface-discovery.tsv')) reason = 'worker prompt must name check-surface-discovery.tsv';
else if (!w.promptFull.includes('check-surface-degenerate-allowlist.tsv')) reason = 'worker prompt must name check-surface-degenerate-allowlist.tsv';
else if (!w.promptFull.includes('gate-paths.tsv')) reason = 'worker prompt must name gate-paths.tsv';
else if (!w.promptFull.includes('exec-bit-registry.tsv')) reason = 'worker prompt must name exec-bit-registry.tsv';
else if (!w.promptFull.includes('kernel-manifest.txt')) reason = 'worker prompt must name kernel-manifest.txt';
else if (!w.promptFull.includes('docs/features/feature-manifest.txt')) reason = 'worker prompt must name docs/features/feature-manifest.txt';
else if (!w.promptFull.includes('setting-registry.tsv')) reason = 'worker prompt must name setting-registry.tsv';
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

# --- K1931 static lockstep guards: build.md §3c and workerPrompt() must carry
# the SAME gate-registration-checklist pointer, so a future edit to either
# one — or a registry rename that falls out of the list — cannot silently
# drop or stale-out the other half. Mirrors the K1530 lockstep idiom above,
# plus a per-registry-name check so a renamed/removed registry in the list
# is caught even if the section header itself survives. --------------------
grep -q 'function gateRegistrationChecklistSection' "$MJS" \
  || fail "#1931: gateRegistrationChecklistSection() missing — workerPrompt must embed the gate-registration checklist as its own self-contained section"
grep -q '## New gate script? Register it before running the scoped gate (temperloop#1931)' "$MJS" \
  || fail "#1931: workerPrompt() must embed the '## New gate script?' section"
for _k1931_registry in \
  'check-surface-registry.tsv' \
  'check-surface-discovery.tsv' \
  'check-surface-degenerate-allowlist.tsv' \
  'gate-paths.tsv' \
  'exec-bit-registry.tsv' \
  'kernel-manifest.txt' \
  'docs/features/feature-manifest.txt' \
  'setting-registry.tsv'
do
  grep -q -- "$_k1931_registry" "$MJS" \
    || fail "#1931: workerPrompt()'s gate-registration checklist must name $_k1931_registry — a registry dropped from the list is exactly the silent-miss class temperloop#1931 closes"
done
grep -q '\.\.\.gateRegistrationChecklistSection()' "$MJS" \
  || fail "#1931: workerPrompt()'s returned array must splice in gateRegistrationChecklistSection() — a defined-but-unused function never reaches the worker"
K1931_BUILD_MD="$REPO_ROOT/claude/commands/build.md"
[ -f "$K1931_BUILD_MD" ] \
  || fail "#1931: claude/commands/build.md is missing — the prose half of this contract pair cannot be verified"
grep -q 'temperloop#1931' "$K1931_BUILD_MD" \
  || fail "#1931: build.md §3c must name temperloop#1931 alongside the gate-registration-checklist pointer (lockstep with build-level.mjs)"
grep -q 'gateRegistrationChecklistSection' "$K1931_BUILD_MD" \
  || fail "#1931: build.md §3c must name gateRegistrationChecklistSection() rather than restate its registry list (pointer, not restatement — ADR 0015 prose ratchet)"
echo "PASS: #1931 gate-registration-checklist guard — workerPrompt embeds the new-gate-script checklist naming every observed-missed registry; build.md §3c in lockstep"

# ============================================================================
# TEST (K1934): a class-A item's worker prompt renders its `activation.proof`
#   VERBATIM as the reachability predicate the orchestrator will run at §3e.6
#   (the join-key-registry near-miss, epic #1910 — the worker built and wired
#   `join-keys-lib.sh` while the plan's proof: grepped the producer-chosen
#   literal `join_keys`, a name the worker never saw). A class-B item and a
#   PLAIN item carrying no `activation` block at all get NO such section —
#   the proof line is present only for class A. One buildLevel() call drives
#   all three items so the assertion is a same-run contrast.
# ============================================================================
run_node_case "K1934 prevention: workerPrompt renders a class-A activation.proof verbatim as the reachability predicate; class-B/absent get no such section" "
$PREAMBLE

happyMachinery('act-a-item', 930, 'aaca63');
happyWorker('act-a-item');
happyMachinery('act-b-item', 931, 'aacb64');
happyWorker('act-b-item');
happyMachinery('act-none-item', 932, 'aace65');
happyWorker('act-none-item');
globalThis.args = { ...baseArgs, items: [
  { slug: 'act-a-item', branch: 'build/act-a-item', title: 'Act A item', kind: 'code', acceptance: ['c'],
    activation: { class: 'A', proof: 'grep -q JoinKeysRegistry join-keys-lib.sh' } },
  { slug: 'act-b-item', branch: 'build/act-b-item', title: 'Act B item', kind: 'code', acceptance: ['c'],
    activation: { class: 'B', watermark: 'v0.36.0' } },
  { slug: 'act-none-item', branch: 'build/act-none-item', title: 'Act none item', kind: 'code', acceptance: ['c'] },
]};
const mod = await loadLevel();
await mod.default();
const a = callLog.find(c => (c.opts.label||'') === 'worker:act-a-item');
const b = callLog.find(c => (c.opts.label||'') === 'worker:act-b-item');
const n = callLog.find(c => (c.opts.label||'') === 'worker:act-none-item');
let reason = null;
if (!a) reason = 'no worker call logged for act-a-item';
else if (!b) reason = 'no worker call logged for act-b-item';
else if (!n) reason = 'no worker call logged for act-none-item';
else if (!a.promptFull.includes('reachability predicate')) reason = 'class-A worker prompt must contain the phrase reachability predicate';
else if (!a.promptFull.includes('grep -q JoinKeysRegistry join-keys-lib.sh')) reason = 'class-A worker prompt must render item.activation.proof VERBATIM';
else if (!a.promptFull.includes('temperloop#1934')) reason = 'class-A worker prompt must name temperloop#1934';
else if (!a.promptFull.includes('with a question naming the conflict')) reason = 'class-A worker prompt must tell the worker to return blocked (never a silent rename) on a genuine conflict';
else if (b.promptFull.includes('reachability predicate')) reason = 'class-B worker prompt must NOT carry the reachability-predicate section';
else if (n.promptFull.includes('reachability predicate')) reason = 'no-activation worker prompt must NOT carry the reachability-predicate section';
else if (b.promptFull.includes('Class-A activation gate')) reason = 'class-B worker prompt must not carry the Class-A activation gate heading';
else if (n.promptFull.includes('Class-A activation gate')) reason = 'no-activation worker prompt must not carry the Class-A activation gate heading';
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

# --- K1934 static lockstep guards: build.md §3c/Step-3 and workerPrompt() must
# carry the SAME activation-proof pass-through, so a future edit to either
# one cannot silently drop the other half. Mirrors the K1931/K1530 lockstep
# idiom above. ----------------------------------------------------------------
grep -q 'function activationProofSection' "$MJS" \
  || fail "#1934: activationProofSection() missing — workerPrompt must embed the class-A reachability predicate as its own self-contained, gated section"
grep -q '## Class-A activation gate — the reachability predicate you are gated on (temperloop#1934)' "$MJS" \
  || fail "#1934: workerPrompt() must embed the '## Class-A activation gate' section"
grep -q "if (activationClass(item) !== 'A') return \[\];" "$MJS" \
  || fail "#1934: activationProofSection() must be gated on activationClass(item) === 'A' — ungated would leak the section for class-B/C/absent items"
grep -q '\.\.\.activationProofSection(item)' "$MJS" \
  || fail "#1934: workerPrompt()'s returned array must splice in activationProofSection(item) — a defined-but-unused function never reaches the worker"
K1934_BUILD_MD="$REPO_ROOT/claude/commands/build.md"
[ -f "$K1934_BUILD_MD" ] \
  || fail "#1934: claude/commands/build.md is missing — the prose half of this contract pair cannot be verified"
grep -q 'activationProofSection' "$K1934_BUILD_MD" \
  || fail "#1934: build.md Step 3's activation arg description must name activationProofSection() — the worker-brief pass-through must be documented, not just implemented"
grep -q 'temperloop#1934' "$K1934_BUILD_MD" \
  || fail "#1934: build.md Step 3 must name temperloop#1934 alongside the activation-proof pass-through pointer (lockstep with build-level.mjs)"
K1934_ASSESS_MD="$REPO_ROOT/claude/commands/assess.md"
[ -f "$K1934_ASSESS_MD" ] \
  || fail "#1934: claude/commands/assess.md is missing — the activation-authoring doc pointer cannot be verified"
grep -q "consumer's call-site symbol" "$K1934_ASSESS_MD" \
  || fail "#1934: assess.md's activation-authoring guidance must prefer a presence proof pinned on the consumer's call-site symbol over a producer filename (the join-key-registry lesson)"
# --- K1934 round-2 guard: the §3c conversational-path mirror. build.md Step 3
# (above) only covers the Workflow path's items[] contract; §3c is the
# separate prose site the `--no-workflow` conversational path actually reads
# before its first worker spawn, and it never gained the mirror instruction —
# a `--no-workflow` run left a class-A worker never seeing its `proof:` at
# all. Pinned the same way changelogFragmentSection()'s and the
# foreground-only clause's §3c mirrors are pinned above. -----------------------
grep -q "the worker returns \`blocked\` with a question naming the conflict — never a silent rename" "$K1934_BUILD_MD" \
  || fail "#1934: build.md §3c must carry the class-A activation-proof mirror sentence (verbatim proof + blocked-on-conflict, never a silent rename)"
grep -q "the conversational path MUST include it, verbatim per the item's \`proof:\`, in the \*\*first\*\* worker prompt it authors for a class-A item" "$K1934_BUILD_MD" \
  || fail "#1934: build.md §3c must state the conversational path renders activation.proof verbatim in the first worker prompt for a class-A item"
echo "PASS: #1934 activation-proof guard — workerPrompt embeds the class-A item's activation.proof verbatim as the reachability predicate, present only for class A; build.md Step 3, §3c's conversational-path mirror, and assess.md's activation-authoring guidance are all in lockstep"

# ============================================================================
# TEST (K1847): a /sweep-admitted epic member's worker prompt carries the
#   parent epic's group summary (Produces #7, epic #1847) — a distinct
#   "## Parent epic context" section rendered from `item.parentSummary` /
#   `item.parentEpic` — while a PLAIN SINGLETON item, carrying neither field,
#   gets no such section at all. One buildLevel() call drives both items so
#   the assertion is a same-run contrast, not two separately-plausible runs.
# ============================================================================
run_node_case "K1847 prevention: workerPrompt carries the parent epic's group summary for a member item, and omits it for a singleton" "
$PREAMBLE

happyMachinery('member-item', 910, 'aebe77');
happyWorker('member-item');
happyMachinery('singleton-item', 911, 'ae7d');
happyWorker('singleton-item');
globalThis.args = { ...baseArgs, items: [
  { slug: 'member-item', branch: 'build/member-item', title: 'Member item', kind: 'code', acceptance: ['c'],
    parentSummary: 'This epic materializes the ratified design brief for operational work.',
    parentEpic: 1847 },
  { slug: 'singleton-item', branch: 'build/singleton-item', title: 'Singleton item', kind: 'code', acceptance: ['c'] },
]};
const mod = await loadLevel();
await mod.default();
const member = callLog.find(c => (c.opts.label||'') === 'worker:member-item');
const singleton = callLog.find(c => (c.opts.label||'') === 'worker:singleton-item');
let reason = null;
if (!member) reason = 'no worker call logged for member-item';
else if (!singleton) reason = 'no worker call logged for singleton-item';
else if (!member.promptFull.includes('## Parent epic context')) reason = 'member worker prompt missing the Parent epic context section';
else if (!member.promptFull.includes('temperloop#1847')) reason = 'member worker prompt must name temperloop#1847';
else if (!member.promptFull.includes('#1847')) reason = 'member worker prompt must name the parent epic issue number from item.parentEpic';
else if (!member.promptFull.includes('This epic materializes the ratified design brief for operational work.')) reason = 'member worker prompt missing the injected group-summary text verbatim';
else if (singleton.promptFull.includes('## Parent epic context')) reason = 'singleton worker prompt must NOT carry a Parent epic context section';
else if (singleton.promptFull.includes('ratified design brief')) reason = 'singleton worker prompt leaked the OTHER item\\'s group-summary text';
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

# --- K1847 static lockstep guard: parentSummarySection() exists, is spliced
# into workerPrompt()'s array, and is gated on item.parentSummary (never
# ungated — an ungated section would leak into every singleton's prompt). ---
grep -q 'function parentSummarySection' "$MJS" \
  || fail "#1847: parentSummarySection() missing — workerPrompt must embed the parent-epic group summary as its own self-contained, gated section"
grep -q '## Parent epic context' "$MJS" \
  || fail "#1847: workerPrompt() must embed the '## Parent epic context' section"
grep -q '\.\.\.parentSummarySection(item)' "$MJS" \
  || fail "#1847: workerPrompt()'s returned array must splice in parentSummarySection(item) — a defined-but-unused function never reaches the worker"
grep -q "if (!item.parentSummary) return \[\];" "$MJS" \
  || fail "#1847: parentSummarySection() must be gated on item.parentSummary — ungated would leak the section into every singleton's prompt"
K1847_SWEEP_MD="$REPO_ROOT/claude/commands/sweep.md"
[ -f "$K1847_SWEEP_MD" ] \
  || fail "#1847: claude/commands/sweep.md is missing — the prose half of this contract pair cannot be verified"
grep -q 'parentSummary' "$K1847_SWEEP_MD" \
  || fail "#1847: sweep.md's Step-3 items[] schema must name parentSummary (lockstep with build-level.mjs)"
grep -q 'group_summary' "$K1847_SWEEP_MD" \
  || fail "#1847: sweep.md Step 1 item 6 must derive group_summary from the epic's own body for admitted members to carry forward"
grep -q 'secret-seam scrutiny' "$K1847_SWEEP_MD" \
  || fail "#1847: sweep.md Step 2 must carry the ported member secret-seam scrutiny (foundation#716) for admitted epic members"
echo "PASS: #1847 member-scrutiny guard — workerPrompt carries the parent epic's group summary for an admitted member and omits it for a singleton; sweep.md's Phase-1 secret-seam scrutiny and Step-3 parentSummary threading are in lockstep"

# ============================================================================
# TEST (K993): the backgrounded-gate stall is detected MECHANICALLY and
# auto-resumed — worker returned NO verdict AND its worktree is dirty with ZERO
# commits (the #982/#983 shape). The probe reports RECOVER_DIRTY; driveItem must
# resume the SAME worktree with the foreground cure PLUS a dirty-resume note
# naming the uncommitted count, rather than escalating "nothing happened".
# ============================================================================
run_node_case "K993 auto-resume: null verdict + RECOVER_DIRTY → resume prompt carries the dirty-resume note → parked" "
$PREAMBLE

setMachinery('stall-item',
  { outcome: 'CREATED', path: '/tmp/repo.wt/stall-item' },
  dirtyStall(8),                       // the #982 shape: 8 modified files, 0 commits
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'aa7e' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'aa7e', branch: 'build/stall-item' },
  { outcome: 'PR_OPENED', pr_number: 993 },
  { outcome: 'CI_GREEN' },
);
setWorker('stall-item', null, { status: 'done', summary: 'resumed', acceptance_results: [{ criterion: 'c', passed: true, evidence: 'e' }], commits: [] });
globalThis.args = { ...baseArgs, items: [
  { slug: 'stall-item', branch: 'build/stall-item', title: 'Stall item', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
const result = await mod.default();
const parked = result.parked ?? [];
const esc = result.escalations ?? [];
const first = callLog.find(c => (c.opts.label||'') === 'worker:stall-item');
const retry = callLog.find(c => (c.opts.label||'') === 'worker:stall-item#retry');
let reason = null;
if (!retry) reason = 'no auto-resume call after the RECOVER_DIRTY probe';
else if (!retry.promptFull.includes('Re-spawn cure (#1219)')) reason = 'resume prompt missing FOREGROUND_CURE';
else if (!retry.promptFull.includes('UNCOMMITTED work in this worktree (#993)')) reason = 'resume prompt missing the #993 dirty-resume note';
else if (!retry.promptFull.includes('8 uncommitted path(s)')) reason = 'dirty-resume note must name the uncommitted file count from the probe';
else if (first && first.promptFull.includes('UNCOMMITTED work in this worktree (#993)')) reason = 'first prompt must NOT carry the dirty-resume note';
else if (esc.length !== 0) reason = 'auto-resume must not escalate, got ' + JSON.stringify(esc.map(e => e.kind));
else if (parked.length !== 1) reason = 'expected 1 parked item after the auto-resume, got ' + parked.length;
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K993 split: a CLEAN RECOVER_NONE stall gets the cure but NOT the dirty-resume note" "
$PREAMBLE

setMachinery('clean-item',
  { outcome: 'CREATED', path: '/tmp/repo.wt/clean-item' },
  noSideEffects(),
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'acea67' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'acea67', branch: 'build/clean-item' },
  { outcome: 'PR_OPENED', pr_number: 994 },
  { outcome: 'CI_GREEN' },
);
setWorker('clean-item', null, { status: 'done', summary: 'ok', acceptance_results: [{ criterion: 'c', passed: true, evidence: 'e' }], commits: [] });
globalThis.args = { ...baseArgs, items: [
  { slug: 'clean-item', branch: 'build/clean-item', title: 'Clean item', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
await mod.default();
const retry = callLog.find(c => (c.opts.label||'') === 'worker:clean-item#retry');
let reason = null;
if (!retry) reason = 'no retry call after the RECOVER_NONE probe';
else if (!retry.promptFull.includes('Re-spawn cure (#1219)')) reason = 'retry prompt missing FOREGROUND_CURE';
else if (retry.promptFull.includes('UNCOMMITTED work in this worktree (#993)')) reason = 'a CLEAN worktree must NOT get the dirty-resume note';
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K993 escalation: resume also returns null + still dirty → worker-error names shape/dirty_files/worktree" "
$PREAMBLE

setMachinery('stuck-item',
  { outcome: 'CREATED', path: '/tmp/repo.wt/stuck-item' },
  dirtyStall(3),                       // the #983 shape: 3 modified files, 0 commits
  dirtyStall(3),
);
setWorker('stuck-item', null, null);
globalThis.args = { ...baseArgs, items: [
  { slug: 'stuck-item', branch: 'build/stuck-item', title: 'Stuck item', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
const result = await mod.default();
const esc = result.escalations ?? [];
let reason = null;
if (esc.length !== 1 || esc[0].kind !== 'worker-error') reason = 'expected 1 worker-error escalation, got ' + JSON.stringify(esc.map(e => e.kind));
else {
  const p = esc[0].payload ?? {};
  if (p.shape !== 'foreground-stall') reason = 'escalation payload must carry shape:foreground-stall, got ' + JSON.stringify(p.shape);
  else if (p.dirty_files !== 3) reason = 'escalation payload must carry the uncommitted count, got ' + JSON.stringify(p.dirty_files);
  else if (p.worktree !== '/tmp/repo.wt/stuck-item') reason = 'escalation payload must name the worktree holding the uncommitted work, got ' + JSON.stringify(p.worktree);
  else if (!String(p.reason || '').includes('skip prunes it')) reason = 'escalation reason must warn that skip prunes the worktree';
}
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

# --- K993 static lockstep guards: the mechanical half of the #993 pair. build.md
# §3c pairs the prose foreground clause with THIS detection; a future edit that
# drops the RECOVER_DIRTY rung or the dirty-resume cure leaves only the rotting
# prose behind. -------------------------------------------------------------
grep -q "'RECOVER_DIRTY'" "$MJS" \
  || fail "#993: SPINE_OUTCOME_SCHEMA must admit RECOVER_DIRTY (the probe's stall rung)"
grep -q 'function dirtyResumeCure' "$MJS" \
  || fail "#993: dirtyResumeCure() missing — the auto-resume must tell the worker its uncommitted work is still on disk"
# NB the trailing `)` is deliberately NOT part of this pattern: temperloop#865
# added a third `item.slug` argument (the gate-sentinel cure). What #993 pins is
# that the probe's dirty-file count is THREADED into the cure as argument 2 —
# not the arity of the call.
grep -q 'withCure(verdictSection, probe.dirtyFiles' "$MJS" \
  || fail "#993: the auto-resume must thread the probe's dirty-file count into the cure"
grep -q "shape: 'foreground-stall'" "$MJS" \
  || fail "#993: an uncured stall must escalate with shape:foreground-stall so the worktree's uncommitted work is not silently pruned"
echo "PASS: #993 detection guard — RECOVER_DIRTY rung + dirty-resume cure + stall-shaped escalation"

# --- K712 static lockstep guards (grep the MJS source directly, matching the
# tail-guard idiom above). These lock the code SHAPE build.md §3c/§3d cite, so a
# future edit cannot silently drop the prevention section or the retry cure. -----
grep -q 'FOREGROUND ONLY (#1219)' "$MJS" \
  || fail "#712: workerPrompt must embed the '## Quality gate … FOREGROUND ONLY (#1219)' contract (prevention)"
echo "PASS: #712 prevention guard — workerPrompt embeds the foreground-only gate contract"
grep -q 'const FOREGROUND_CURE' "$MJS" \
  || fail "#712: FOREGROUND_CURE constant missing — null-retry cure"
# (temperloop#993 widened the call to withCure(verdictSection, probe.dirtyFiles);
# this guard matches the prefix so it survives that added argument — the #993
# guard above pins the argument itself.)
grep -q 'withCure(verdictSection' "$MJS" \
  || fail "#712: main-worker null-retry must append the cure via withCure(verdictSection, …) so the retry prompt differs"
echo "PASS: #712 cure guard — null-verdict re-spawn appends FOREGROUND_CURE (retry prompt differs from first)"

# --- K997 static lockstep guards: the worker must NOT be told to run the bare,
# repo-wide quality-gates.sh in its own context (a minutes-long blocking turn
# blows the ~5-min prompt-cache TTL and re-writes the worker's whole context).
# Both surfaces build.md §3c names — workerPrompt()'s FOREGROUND-ONLY section and
# FOREGROUND_CURE — must carry the ban AND the non-authority caveat, so a future
# edit cannot quietly reinstate the bare run on either. Runtime shape (that the
# prompt actually reaches the worker) is already covered by the K712 prevention
# case above, which asserts the same section is present in promptFull. ---------
qg_ban_hits="$(grep -ci 'bare, repo-wide `scripts/quality-gates.sh`' "$MJS")"
[ "$qg_ban_hits" -ge 2 ] \
  || fail "#997: expected the bare-repo-wide-gate ban in BOTH workerPrompt()'s FOREGROUND-ONLY section and FOREGROUND_CURE (found $qg_ban_hits)"
grep -q 'FAST LOCAL FEEDBACK ONLY — it is NOT the acceptance authority' "$MJS" \
  || fail "#997: worker prompt must state the path-scoped subset is fast local feedback only, NOT the acceptance authority (3e.5 is)"
grep -q 'DEFERRED to the parent-side 3e.5 gate' "$MJS" \
  || fail "#997: worker prompt must tell the worker how to report a criterion naming the bare repo-wide suite (passed:true + deferred evidence, never passed:false)"
# The #997 narrowing applies to the WORKER only. 3e.5's parent-side gate remains
# the acceptance authority — and what makes it one is that it is the ORCHESTRATOR'S
# OWN run against the worker's commit, not the worker's self-report (the PR #309
# silent-red lesson turns on that, not on the gate's breadth).
#
# The invariant guarded here, unchanged since #997, is that NO PATH ARGUMENTS are
# ever appended to the invocation: the subshell must CLOSE immediately after the
# script path, so which gates run is decided by the VALIDATED map
# (gate-paths.tsv, linted by check-gate-paths.sh) and never by a hand-written
# path list at this call site. Both env-var prefixes ride in front of it and
# neither weakens that: #1021's budget/resume pair scopes the run in TIME, and
# #1663's QUALITY_GATES_SCOPED scopes it through that same validated map, whose
# every resolution failure widens to the full set.
# shellcheck disable=SC2016  # grepping for the LITERAL ${sq(qgBin)} token in source
grep -q 'QUALITY_GATES_BUDGET_SECS=${GATE_SLICE_SECS} ${sq(qgBin)} ) ' "$MJS" \
  || fail "#997/#309: the 3e.5 parent-side gate must invoke quality-gates.sh with NO path arguments — selection belongs to the validated map, not this call site"
# shellcheck disable=SC2016  # literal-token grep
grep -q 'QUALITY_GATES_START_AT=${startAt}' "$MJS" \
  || fail "#1021: the 3e.5 gate must pass its resume index as an ENV VAR (a FLAG would exit 2 'usage' on an older vendored quality-gates.sh and read back as a gate failure)"
echo "PASS: #997 worker-gate-scope guard — worker prompt + cure ban the bare repo-wide worker run; 3e.5's own invocation takes no path arguments"

# --- K1663: the 3e.5 gate is DIFF-SCOPED, and the seam is an ENV VAR ----------
# A full per-item suite could not survive within-level parallelism: a measured
# 3-item level burned 55 min / 1.24M subagent tokens and landed ZERO items, all
# three escalating acceptance-gate-timeout with every worker already finished and
# committed. Two properties have to hold at this call site, and both are the kind
# a well-meaning simplification would quietly drop:
#
#   1. The seam is $QUALITY_GATES_SCOPED, NOT the `--scoped` FLAG. A consuming
#      repo vendoring an OLDER quality-gates.sh IGNORES an unknown env var and
#      runs the whole suite (the pre-#1663 behavior, still correct), whereas an
#      unknown FLAG exits 2 "usage" and reads back here as a GATE FAILURE — it
#      would red every item in the fleet's un-updated repos at once.
#   2. The value comes from $BUILD_GATE_SCOPED with a DEFAULT, read from the
#      WORKTREE'S build.config.sh, so the escape hatch exists and an absent or
#      older config file still resolves.
# shellcheck disable=SC2016  # literal-token grep
grep -q 'QUALITY_GATES_SCOPED=\$(\. ${sq(configBin)}' "$MJS" \
  || fail "#1663: the 3e.5 gate must scope via the QUALITY_GATES_SCOPED ENV VAR resolved from the worktree's build.config.sh (a --scoped FLAG exits 2 'usage' on an older vendored quality-gates.sh and reads back as a gate failure)"
grep -q 'BUILD_GATE_SCOPED:-1' "$MJS" \
  || fail "#1663: the 3e.5 gate's scope must come from \$BUILD_GATE_SCOPED with a default, so the escape hatch exists and an absent/older build.config.sh still resolves"
# ...and pin the SPLICE, not just the DECLARATION. Both greps above match
# `gateScopeEnv`'s definition; deleting the line that interpolates it into
# `gateCmd` leaves them BOTH green while silently reverting 3e.5 to the full
# per-item suite — the exact 55-min/zero-items failure #1663 exists to fix, under
# a green guard suite. #1021's analogous guard cannot drift this way because its
# token lives inside the template itself; this branch introduced the indirection,
# so the indirection needs its own assertion. -qF: fixed-string, no BRE escaping.
grep -qF '`${gateScopeEnv} QUALITY_GATES_SELECTION_PIN=' "$MJS" \
  || fail "#1663: gateScopeEnv must be SPLICED INTO gateCmd, not merely declared — a defined-but-unused const silently restores the full per-item suite"
# The slice-stability half (temperloop#1663 HIGH): a scoped gate list is
# re-derived per slice, so QUALITY_GATES_START_AT -- an ORDINAL into that list --
# can point at a different gate on a later slice, silently skipping one while the
# suite still exits 0. Both halves must be present: the PIN that stops the input
# drifting, and the FINGERPRINT that makes a drift loud if it happens anyway.
grep -q 'QUALITY_GATES_SELECTION_PIN=' "$MJS" \
  || fail "#1663: the 3e.5 gate must pin the scoped changed set across slices — without it a resume index can silently address a different gate"
grep -q 'QUALITY_GATES_EXPECT_SELECTION=' "$MJS" \
  || fail "#1663: the 3e.5 gate must feed the previous slice's selection fingerprint back, so a drifted list restarts loudly instead of resuming a stale ordinal"
echo "PASS: #1663 scoped-acceptance-gate guard — 3e.5 scopes through QUALITY_GATES_SCOPED (env, not flag) from \$BUILD_GATE_SCOPED"

# --- K1663 superseded-premise guard: the OLD contract must not come back ------
# Before #1663, §3e.5 was documented in SEVEN live artifacts as the BARE,
# repo-wide run, and two of them stated a safety property that scoping REMOVED:
# that a repo-wide red the worker's scoped subset missed would be caught at
# §3e.5. It is not, and cannot be — §3e.5 and the worker's own `--scoped` run
# now resolve the same diff through the same map, so they select nearly the same
# gates. A red outside that set is caught by the UNSCOPED merge_group run, before
# `main` but after push.
#
# Six of the seven sites were rewritten by hand for #1663; the seventh survived
# the sweep and had to be caught in review. That is precisely the "purge the
# superseded premise from every live artifact" failure the kernel names, and a
# prose contradiction has no other test — so it gets a mechanical one here.
#
# These patterns are the FALSE CLAIMS, not the topic: prose that accurately
# describes what §3e.5 does and does not catch (including the words "repo-wide")
# is expected and must keep passing.
BUILD_MD="$REPO_ROOT/claude/commands/build.md"
[ -f "$BUILD_MD" ] || fail "#1663: claude/commands/build.md not found at $BUILD_MD"
for stale_claim in \
  'repo-wide red the subset missed is caught' \
  'bare repo-wide run was DEFERRED' \
  'bare repo-wide run was \*\*deferred'
do
  for surface in "$BUILD_MD" "$MJS"; do
    if grep -q "$stale_claim" "$surface"; then
      fail "#1663: '$(basename "$surface")' still asserts the pre-#1663 contract ('$stale_claim') — §3e.5 is diff-scoped and does NOT catch a repo-wide red outside the item's scoped set; the unscoped merge_group run does"
    fi
  done
done
# The positive half: §3e.5 must still be named as the acceptance AUTHORITY, so a
# future edit cannot "fix" the above by deleting the deferral contract wholesale
# and leaving the worker with no instruction at all.
grep -q 'DEFERRED to the parent-side 3e.5 gate' "$MJS" \
  || fail "#1663/#997: the worker prompt must still route a repo-wide acceptance criterion to §3e.5 — removing the stale WORDING must not remove the deferral CONTRACT"
echo "PASS: #1663 superseded-premise guard — no live artifact still claims §3e.5 is the bare repo-wide catch; the deferral contract survives"

# --- K1694: gateScopeEnv's emitted shell fragment is EXECUTED, not merely --
#   grepped for ------------------------------------------------------------
# The grep guards above prove the SOURCE mentions the right tokens. They
# cannot catch a dropped backslash that turns the JS template literal's
# \${BUILD_GATE_SCOPED:-1} escape into a REAL js interpolation against an
# undefined `BUILD_GATE_SCOPED` binding — a change every grep above still
# passes, while the gate silently reverts to the full per-item suite (the
# exact #1663 failure, back under a green guard suite).
#
# This test extracts sq() and the gateScopeEnv template-literal expression
# VERBATIM from build-level.mjs's own source (not a hand-copied re-encoding
# of it — a re-encoding would only test itself), evaluates that extracted
# JS against a caller-supplied `configBin`, and RUNS the resulting shell
# fragment under bash against three fixtures.
GATE_SCOPE_EXTRACT="$WF_TEST_TMPDIR/extract-gate-scope.cjs"
cat > "$GATE_SCOPE_EXTRACT" <<'NODE_EOF'
'use strict';
const fs = require('fs');
const [, , mjsPath, configBin] = process.argv;
if (!mjsPath || configBin === undefined) {
  console.error('usage: extract-gate-scope.cjs <build-level.mjs path> <configBin>');
  process.exit(2);
}
const src = fs.readFileSync(mjsPath, 'utf8');
// sq() is a top-level function declaration; its closing brace is the first
// line consisting solely of "}" after the opening line.
const sqMatch = src.match(/^function sq\(value\) \{[\s\S]*?^\}/m);
if (!sqMatch) {
  console.error('EXTRACT_FAILED: sq() function not found');
  process.exit(2);
}
// gateScopeEnv is a single-line-declared, backtick-delimited template
// literal expression. Capture just the expression (with its backticks), not
// the `const gateScopeEnv =` binding, so it can be eval'd as a bare
// expression below.
const gateMatch = src.match(/const gateScopeEnv =\s*\n\s*(`[\s\S]*?`);/);
if (!gateMatch) {
  console.error('EXTRACT_FAILED: gateScopeEnv template literal not found');
  process.exit(2);
}
let gateScopeEnv;
try {
  // new Function isolates evaluation in a fresh scope — configBin is the
  // only free variable the extracted expression needs, passed as a real
  // parameter rather than relying on any scope-leak trick. A dropped
  // backslash in the source turns \${BUILD_GATE_SCOPED:-1} into a real JS
  // interpolation; ":-1" is not valid JS in expression position, so this
  // throws a SyntaxError right here — the RED half of the discrimination.
  const factory = new Function('configBin', `${sqMatch[0]}\nreturn ${gateMatch[1]};`);
  gateScopeEnv = factory(configBin);
} catch (e) {
  console.error(`EVAL_FAILED: ${e.constructor.name}: ${e.message}`);
  process.exit(3);
}
process.stdout.write(gateScopeEnv);
NODE_EOF

# resolve_gate_scoped <mjs-path> <configBin-path>
# Extracts the fragment from <mjs-path> and actually RUNS it under bash,
# printing the resolved QUALITY_GATES_SCOPED value. Returns non-zero (with
# the extraction/eval diagnostic on stderr) if extraction or eval failed —
# the caller distinguishes "wrong value" from "couldn't even build it".
resolve_gate_scoped() {
  local mjs="$1" configBin="$2" out rc errfile
  errfile="$(mktemp "$WF_TEST_TMPDIR/gate-scope-err.XXXXXX")"
  out="$(node "$GATE_SCOPE_EXTRACT" "$mjs" "$configBin" 2>"$errfile")"
  rc=$?
  if [ $rc -ne 0 ]; then
    echo "EXTRACTION_FAILED: $(cat "$errfile")" >&2
    rm -f "$errfile"
    return 1
  fi
  rm -f "$errfile"
  bash -c "$out; echo \"\${QUALITY_GATES_SCOPED}\""
}

GATE_FIX_DIR="$WF_TEST_TMPDIR/gate-scope-fixtures"
mkdir -p "$GATE_FIX_DIR"

# Fixture 1: build.config.sh does not exist at all.
GATE_FIX_MISSING="$GATE_FIX_DIR/does-not-exist/build.config.sh"

# Fixture 2: an ordinary config carrying the explicit override.
GATE_FIX_ZERO="$GATE_FIX_DIR/zero.sh"
printf 'BUILD_GATE_SCOPED=0\n' > "$GATE_FIX_ZERO"

# Fixture 3: a config that sets `set -euo pipefail` (mirroring a plausible
# future hardening of build.config.sh) and then genuinely FAILS mid-file —
# `false` is a real, unguarded failing command, not an if-condition trick.
# It runs with -e disabled (`set +e`) specifically so the failure survives
# to be sourcing's own nonzero return rather than an -e-triggered abort of
# the containing subshell (an abort would kill the fragment's inner
# `$(...)` outright and produce NO value at all under either separator —
# that failure mode can't discriminate ';' from '&&', so it's not what this
# fixture is for). BUILD_GATE_SCOPED is never assigned, so the default must
# carry the result home.
GATE_FIX_POISON="$GATE_FIX_DIR/poison.sh"
cat > "$GATE_FIX_POISON" <<'POISON_EOF'
set -euo pipefail
echo "probing" >/dev/null
set +e
false
POISON_EOF

# --- GREEN: the real, unmodified build-level.mjs ---------------------------
v="$(resolve_gate_scoped "$MJS" "$GATE_FIX_MISSING")" \
  || fail "gate-scope-exec: extraction from the real .mjs must succeed (missing-config fixture)"
[ "$v" = "1" ] || fail "gate-scope-exec: a missing build.config.sh must resolve QUALITY_GATES_SCOPED=1 (got '$v')"

v="$(resolve_gate_scoped "$MJS" "$GATE_FIX_ZERO")" \
  || fail "gate-scope-exec: extraction from the real .mjs must succeed (zero fixture)"
[ "$v" = "0" ] || fail "gate-scope-exec: a BUILD_GATE_SCOPED=0 fixture must resolve QUALITY_GATES_SCOPED=0 (got '$v')"

v="$(resolve_gate_scoped "$MJS" "$GATE_FIX_POISON")" \
  || fail "gate-scope-exec: extraction from the real .mjs must succeed (poison fixture)"
[ "$v" = "1" ] || fail "gate-scope-exec: a set -euo pipefail mid-source failure must still resolve QUALITY_GATES_SCOPED=1 (got '$v')"
echo "PASS: gate-scope-exec — the real gateScopeEnv fragment resolves correctly under bash for all three fixtures (missing/zero/poisoned)"

# The load-bearing half of fixture 3 (per the item notes): prove the ';'
# (not '&&') separator between `. configBin` and `echo` is what makes the
# poisoned fixture resolve at all. Swap the SAME extracted fragment's ';'
# for '&&' and confirm it stops resolving to the default — demonstrating
# fixture 3 actually exercises that design choice rather than passing
# vacuously regardless of it.
frag_semi="$(node "$GATE_SCOPE_EXTRACT" "$MJS" "$GATE_FIX_POISON")" \
  || fail "gate-scope-exec: extraction for the &&-vs-; check must succeed"
# Prefix/suffix split rather than ${var/pat/repl} — an unescaped '&' in a
# parameter-expansion REPLACEMENT is special (it re-inserts the matched
# text), so a naive `/; echo/ && echo/` silently corrupts the fragment.
gate_and_prefix="${frag_semi%%; echo*}"
gate_and_suffix="${frag_semi#*; echo}"
frag_and="${gate_and_prefix} && echo${gate_and_suffix}"
[ "$frag_semi" != "$frag_and" ] \
  || fail "gate-scope-exec: could not construct the '&&' variant — the fragment shape changed unexpectedly"
v_and="$(bash -c "$frag_and; echo \"\${QUALITY_GATES_SCOPED}\"")"
[ "$v_and" != "1" ] \
  || fail "gate-scope-exec: the '&&' variant must NOT also resolve to 1 — otherwise fixture 3 isn't discriminating the ';' choice at all"
echo "PASS: gate-scope-exec — fixture 3 is load-bearing: swapping ';' for '&&' changes the resolved value (got '$v_and' instead of '1')"

# --- RED: the same extraction against a MUTATED copy where the backslash
# escape is dropped — \${BUILD_GATE_SCOPED:-1} becomes ${BUILD_GATE_SCOPED:-1},
# a REAL js interpolation. ":-1" is not valid JS in expression position, so
# this must fail extraction/eval outright (not silently produce a wrong
# value) — proving this suite is RED without the escape and GREEN with it,
# demonstrated both ways rather than asserted.
GATE_MUTANT="$WF_TEST_TMPDIR/build-level.mutant.mjs"
node -e '
const fs = require("fs");
const [, mjsPath, outPath] = process.argv;
const src = fs.readFileSync(mjsPath, "utf8");
const needle = "\\${BUILD_GATE_SCOPED:-1}";
if (!src.includes(needle)) {
  console.error("mutant: escaped token not found in source");
  process.exit(2);
}
fs.writeFileSync(outPath, src.split(needle).join("${BUILD_GATE_SCOPED:-1}"));
' "$MJS" "$GATE_MUTANT" || fail "gate-scope-exec: could not construct the dropped-backslash mutant"
if resolve_gate_scoped "$GATE_MUTANT" "$GATE_FIX_MISSING" >/dev/null 2>&1; then
  fail "gate-scope-exec: the dropped-backslash mutant must NOT extract/eval cleanly — it should throw at eval time, proving this test goes RED without the escape"
fi
echo "PASS: gate-scope-exec — RED demonstrated: dropping the backslash breaks extraction/eval of gateScopeEnv where the real .mjs passes clean"

# ============================================================================
# TEST (K1080): worker return-value OUTPUT SHAPE reaches the prompt, and its
#   bounds come from the orchestrator hand-off (Step 0) — not a hardcoded
#   literal. Runtime twin of the static guards below: the static half proves the
#   source interpolates the constants, this half proves an operator-supplied
#   input.workerSummaryMaxWords / workerEvidenceMaxWords actually lands in the
#   prompt the worker reads, and that an OMITTED key still yields a bounded
#   prompt (the /sweep + /fix inheritance path).
# ============================================================================
run_node_case "K1080: output-shape bounds ride input.* into the worker prompt; omitted keys fall back to the in-file defaults" "
$PREAMBLE

happyMachinery('os-item', 900, 'a78');
happyWorker('os-item');
globalThis.args = { ...baseArgs, workerSummaryMaxWords: 41, workerEvidenceMaxWords: 23, items: [
  { slug: 'os-item', branch: 'build/os-item', title: 'OS item', kind: 'impl', acceptance: ['c'] },
]};
let mod = await loadLevel();
await mod.default();
let w = callLog.find(c => (c.opts.label||'') === 'worker:os-item');
let reason = null;
if (!w) reason = 'no worker call logged';
else if (!w.promptFull.includes('## Output shape')) reason = 'worker prompt missing the Output shape section';
else if (!w.promptFull.includes('No process narration anywhere in the return value')) reason = 'worker prompt missing the process-narration ban';
else if (!w.promptFull.includes('at most 41 words')) reason = 'summary bound did not come from input.workerSummaryMaxWords';
else if (!w.promptFull.includes('at most 23 words')) reason = 'evidence bound did not come from input.workerEvidenceMaxWords';
if (reason) { console.log(JSON.stringify({ ok: false, reason })); process.exit(0); }

// Second pass, keys OMITTED — sweep.md/fix.md today. Still bounded.
callLog.length = 0;
happyMachinery('os2-item', 901, 'a279');
happyWorker('os2-item');
globalThis.args = { ...baseArgs, items: [
  { slug: 'os2-item', branch: 'build/os2-item', title: 'OS2 item', kind: 'impl', acceptance: ['c'] },
]};
mod = await loadLevel();
await mod.default();
w = callLog.find(c => (c.opts.label||'') === 'worker:os2-item');
if (!w) reason = 'no worker call logged (defaults pass)';
else if (!w.promptFull.includes('## Output shape')) reason = 'omitted-keys prompt lost the Output shape section';
else if (!/\`summary\`: at most [0-9]+ words/.test(w.promptFull)) reason = 'omitted-keys prompt carries no summary bound';
else if (!/evidence\`: at most [0-9]+ words/.test(w.promptFull)) reason = 'omitted-keys prompt carries no evidence bound';
else if (w.promptFull.includes('at most 41 words')) reason = 'omitted-keys prompt leaked the previous run\\'s override';
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

# --- K1080 static guards: worker return-value OUTPUT SHAPE -------------------
# The verdict's SHAPE is schema-enforced; its SIZE is not (a JSON schema cannot
# bound a string's length), so workerPrompt() must carry an explicit `## Output
# shape` section stating the two word bounds and banning process narration. The
# bounds must be INTERPOLATED from the named-setting constants, never typed as
# literals in the prompt text — a literal would drift from build.config.sh the
# first time the setting is retuned. build.md §3c carries the same contract, so
# both surfaces are pinned here (the runtime half — that the section actually
# reaches the worker — rides the K712 prevention case's promptFull assertion).
grep -q '## Output shape — your return value is a REPORT, not a transcript' "$MJS" \
  || fail "#1080: workerPrompt() must embed the '## Output shape' section (the SIZE half of the 3c return contract)"
grep -q 'No process narration anywhere in the return value' "$MJS" \
  || fail "#1080: worker prompt must ban process narration in the return value"
# shellcheck disable=SC2016  # grepping for the LITERAL ${WORKER_*_MAX_WORDS} tokens in source
grep -q '${WORKER_SUMMARY_MAX_WORDS} words' "$MJS" \
  || fail "#1080: the summary bound must be INTERPOLATED from WORKER_SUMMARY_MAX_WORDS, never a literal in the prompt text"
# shellcheck disable=SC2016  # literal-token grep
grep -q '${WORKER_EVIDENCE_MAX_WORDS} words' "$MJS" \
  || fail "#1080: the evidence bound must be INTERPOLATED from WORKER_EVIDENCE_MAX_WORDS, never a literal in the prompt text"
grep -q 'input.workerSummaryMaxWords' "$MJS" \
  || fail "#1080: WORKER_SUMMARY_MAX_WORDS must read the orchestrator-supplied input.workerSummaryMaxWords (Step-0 hand-off seam)"
grep -q 'input.workerEvidenceMaxWords' "$MJS" \
  || fail "#1080: WORKER_EVIDENCE_MAX_WORDS must read the orchestrator-supplied input.workerEvidenceMaxWords (Step-0 hand-off seam)"
K1080_BUILD_MD="$REPO_ROOT/claude/commands/build.md"
if [ -f "$K1080_BUILD_MD" ]; then
  grep -q 'BUILD_WORKER_SUMMARY_MAX_WORDS' "$K1080_BUILD_MD" \
    || fail "#1080: build.md §3c must NAME BUILD_WORKER_SUMMARY_MAX_WORDS (prose names the setting, never its value)"
  grep -q 'BUILD_WORKER_EVIDENCE_MAX_WORDS' "$K1080_BUILD_MD" \
    || fail "#1080: build.md §3c must NAME BUILD_WORKER_EVIDENCE_MAX_WORDS (prose names the setting, never its value)"
fi
echo "PASS: #1080 output-shape guard — workerPrompt bounds summary/evidence from named settings and bans process narration; build.md §3c in lockstep"

# ============================================================================
# TEST (K939): lost-return recovery — a worker that completed WITHOUT calling
# StructuredOutput must not manufacture a `worker-error` escalation for work
# that demonstrably landed. Covers all three observable stages plus the
# genuine-failure case (which stays exactly as it was).
# ============================================================================

run_node_case "K939 L0 shape: throw + RECOVER_PR_OPEN → parked from ground truth, no escalation, no re-spawn" "
$PREAMBLE

// The #939 L0 incident: commit authored, branch pushed, PR #936 open, CI green
// — and the worker's agent() threw because it never called StructuredOutput.
setMachinery('prose-budget-headroom',
  { outcome: 'CREATED', path: '/tmp/repo.wt/prose-budget-headroom' },
  { outcome: 'RECOVER_PR_OPEN', sha: 'bca3824', commits_ahead: 1, pushed: true, remote_sha: 'bca3824', pr_number: 936, verification_surface_present: true },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  // NOTE: no REBASED entry — the branch is already on origin, so 3f-0a is skipped.
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'bca3824', branch: 'chore/prose-budget-headroom' },
  { outcome: 'EXISTS', pr_number: 936 },
  { outcome: 'CI_GREEN' },
);
setWorker('prose-budget-headroom', throwingWorker());

globalThis.args = { ...baseArgs, items: [
  { slug: 'prose-budget-headroom', branch: 'chore/prose-budget-headroom', title: 'Prose budget headroom', kind: 'impl', acceptance: ['crit one', 'crit two'] },
]};
const mod = await loadLevel();
const result = await mod.default();
const parked = result.parked ?? [];
const esc = result.escalations ?? [];
let reason = null;
if (esc.length !== 0) reason = 'expected 0 escalations, got ' + JSON.stringify(esc);
else if (parked.length !== 1) reason = 'expected 1 parked, got ' + JSON.stringify(result);
else if (parked[0].pr !== 936) reason = 'pr not reconstructed from ground truth: ' + JSON.stringify(parked[0]);
else if (parked[0].pushed_sha !== 'bca3824') reason = 'pushed_sha not reconstructed: ' + JSON.stringify(parked[0]);
else if (parked[0].acceptance_unverified !== true) reason = 'parked record must flag acceptance_unverified';
else if (parked[0].recovered_from !== 'RECOVER_PR_OPEN') reason = 'recovered_from stage missing/wrong: ' + parked[0].recovered_from;
else if ((parked[0].acceptance_results || []).some(r => r.passed === true)) reason = 'recovered acceptance results must NEVER read as passing';
else if (!(parked[0].acceptance_results || []).every(r => String(r.evidence||'').includes('UNVERIFIED'))) reason = 'every recovered acceptance result must be marked UNVERIFIED';
// No re-spawn: exactly ONE worker call, and no #retry label.
else if (callLog.filter(c => isWorkerCall(c.opts)).length !== 1) reason = 'worker was re-spawned after a recovered return (must not be)';
else if (callLog.some(c => String(c.opts.label||'').includes('#retry'))) reason = 'retry worker spawned despite observable side-effects';
// No second PR: the open call went out and pr.sh answered EXISTS (adopted).
// No second PR: the pr-open step ran exactly once and pr.sh answered EXISTS.
else if (stepsRun('prose-budget-headroom').filter(k => k === 'pr-open').length !== 1) reason = 'expected exactly one pr-open step';
// An already-pushed recovery must NOT rebase (the plain push would be rejected).
else if (stepsRun('prose-budget-headroom').includes('rebase')) reason = 'an already-pushed recovery must NOT rebase';
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K939 L1 shape: throw + RECOVER_COMMITTED → rebase/push/open run, parked unverified" "
$PREAMBLE

// The #939 L1 variant: work committed in the worktree, NOT pushed, no PR. The
// recovery must complete the machinery (rebase IS run here — nothing is on the
// remote yet) rather than escalating.
setMachinery('brief-record-completeness-lint',
  { outcome: 'CREATED', path: '/tmp/repo.wt/brief-record-completeness-lint' },
  { outcome: 'RECOVER_COMMITTED', sha: '140fc64', commits_ahead: 1, pushed: false, remote_sha: '', verification_surface_present: false },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: '140fc64' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: '140fc64', branch: 'feat/brief-record-completeness-lint' },
  { outcome: 'PR_OPENED', pr_number: 941 },
  { outcome: 'CI_GREEN' },
);
setWorker('brief-record-completeness-lint', throwingWorker('StructuredOutput retry cap (5) exceeded — 5 failed calls with no valid output'));

globalThis.args = { ...baseArgs, items: [
  { slug: 'brief-record-completeness-lint', branch: 'feat/brief-record-completeness-lint', title: 'Brief record completeness lint', kind: 'impl', acceptance: ['crit one'] },
]};
const mod = await loadLevel();
const result = await mod.default();
const parked = result.parked ?? [];
const esc = result.escalations ?? [];
// temperloop#942: rebase/scan/push/pr-open share ONE 'pr-batch' executor, so the
// pr-open command text is inspected on that call's prompt.
const openCall = callLog.find(c => String(c.opts.label||'').startsWith('pr-batch:'));
let reason = null;
if (esc.length !== 0) reason = 'expected 0 escalations, got ' + JSON.stringify(esc);
else if (parked.length !== 1) reason = 'expected 1 parked, got ' + JSON.stringify(result);
else if (parked[0].pr !== 941) reason = 'pr not adopted from the recovery open: ' + JSON.stringify(parked[0]);
else if (parked[0].recovered_from !== 'RECOVER_COMMITTED') reason = 'recovered_from wrong: ' + parked[0].recovered_from;
else if (parked[0].acceptance_unverified !== true) reason = 'acceptance_unverified flag missing';
// The rebase step DID run for the unpushed stage.
else if (!stepsRun('brief-record-completeness-lint').includes('rebase')) reason = 'RECOVER_COMMITTED must still rebase (nothing pushed yet)';
// No surface file existed → the flag must be dropped, and an inline synthesized
// surface handed to pr.sh instead (a given-but-missing file is a hard ERROR).
else if (!openCall) reason = 'no pr-open call logged';
else if (openCall.promptFull.includes('--verification-surface-file')) reason = 'surface-file flag must be dropped when the probe saw no .build-verification.md';
else if (!openCall.promptFull.includes('verification_surface')) reason = 'recovery must hand pr.sh a synthesized inline verification_surface';
else if (!openCall.promptFull.includes('temperloop#939')) reason = 'recovered PR body must name its recovered provenance';
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K939 RECOVER_PUSHED: surface file present → flag kept, rebase skipped, PR opened" "
$PREAMBLE

setMachinery('pushed-item',
  { outcome: 'CREATED', path: '/tmp/repo.wt/pushed-item' },
  { outcome: 'RECOVER_PUSHED', sha: 'a7a', commits_ahead: 2, pushed: true, remote_sha: 'a7a', verification_surface_present: true },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'a7a', branch: 'build/pushed-item' },
  { outcome: 'PR_OPENED', pr_number: 950 },
  { outcome: 'CI_GREEN' },
);
setWorker('pushed-item', throwingWorker());
globalThis.args = { ...baseArgs, items: [
  { slug: 'pushed-item', branch: 'build/pushed-item', title: 'Pushed item', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
const result = await mod.default();
const parked = result.parked ?? [];
const openCall = callLog.find(c => String(c.opts.label||'').startsWith('pr-batch:'));
let reason = null;
if ((result.escalations ?? []).length !== 0) reason = 'expected 0 escalations, got ' + JSON.stringify(result.escalations);
else if (parked.length !== 1 || parked[0].pr !== 950) reason = 'expected 1 parked at PR 950: ' + JSON.stringify(result);
else if (parked[0].recovered_from !== 'RECOVER_PUSHED') reason = 'recovered_from wrong: ' + parked[0].recovered_from;
else if (stepsRun('pushed-item').includes('rebase')) reason = 'an already-pushed branch must NOT be rebased (the push would be rejected)';
else if (!/^Steps: scan, push, pr-open$/m.test(String(openCall && openCall.promptFull || ''))) reason = 'the pr-batch must DROP the rebase step for an already-pushed recovery: ' + String(openCall && openCall.promptFull || '').split('\n').find(l => l.startsWith('Steps:'));
else if (!openCall || !openCall.promptFull.includes('--verification-surface-file')) reason = 'surface-file flag must be kept when the probe saw .build-verification.md';
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K939 genuine failure: throw + RECOVER_NONE twice → worker-error escalation (unchanged)" "
$PREAMBLE

setMachinery('dead-item',
  { outcome: 'CREATED', path: '/tmp/repo.wt/dead-item' },
  noSideEffects(),
  noSideEffects(),
);
setWorker('dead-item', throwingWorker(), throwingWorker());
globalThis.args = { ...baseArgs, items: [
  { slug: 'dead-item', branch: 'build/dead-item', title: 'Dead item', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
const result = await mod.default();
const esc = result.escalations ?? [];
let reason = null;
if ((result.parked ?? []).length !== 0) reason = 'a no-side-effect worker must not park';
else if (esc.length !== 1 || esc[0].kind !== 'worker-error') reason = 'expected 1 worker-error escalation, got ' + JSON.stringify(esc);
else if (!String(esc[0].payload && esc[0].payload.reason || '').includes('StructuredOutput')) reason = 'escalation payload must carry the real return-channel error: ' + JSON.stringify(esc[0].payload);
// The retry DID happen (nothing landed, so the #1219 cure still applies).
else if (!callLog.some(c => String(c.opts.label||'').includes('#retry'))) reason = 'with no side-effects the #1219 cure retry must still run';
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K939 probe unusable (denied/ERROR) → falls back to the unchanged worker-error escalation" "
$PREAMBLE

// A broken probe must never manufacture a recovery — fail CLOSED to the old path.
setMachinery('probe-broken',
  { outcome: 'CREATED', path: '/tmp/repo.wt/probe-broken' },
  { outcome: 'ERROR', error: 'pr.sh: recover-probe not found' },
  { outcome: 'ERROR', error: 'pr.sh: recover-probe not found' },
);
setWorker('probe-broken', throwingWorker(), throwingWorker());
globalThis.args = { ...baseArgs, items: [
  { slug: 'probe-broken', branch: 'build/probe-broken', title: 'Probe broken', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
const result = await mod.default();
const esc = result.escalations ?? [];
let reason = null;
if ((result.parked ?? []).length !== 0) reason = 'an unusable probe must not park anything';
else if (esc.length !== 1 || esc[0].kind !== 'worker-error') reason = 'expected worker-error, got ' + JSON.stringify(esc);
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

# --- K939 static lockstep guards (same tail-guard idiom as the K712 block) -----
grep -q 'recover-probe' "$MJS" \
  || fail "#939: driveItem must probe observable side-effects via 'pr.sh recover-probe' before classifying a lost worker return"
echo "PASS: #939 probe guard — build-level.mjs runs the staged recover-probe"
grep -q 'acceptance_unverified' "$MJS" \
  || fail "#939: a recovered parked record must carry acceptance_unverified (its acceptance results are UNKNOWN, never 'pass')"
echo "PASS: #939 honesty guard — a recovered parked record flags acceptance_unverified"
grep -q 'async function callWorker' "$MJS" \
  || fail "#939: the worker spawn must be wrapped so a THROWN lost-return (StructuredOutput absent) is caught, not propagated as worker-error"
echo "PASS: #939 throw guard — callWorker() normalizes a thrown lost return"

# ============================================================================
# TEST (K942): batched machinery. build-level.mjs used to spawn ONE haiku
# executor agent per mechanical shell command — an L0 level of 3 items measured
# 40 agents (3 real workers + 37 micro-agents), each paying ~160K cache-read
# tokens and 4 API round-trips to run one one-liner (temperloop#942). The
# mechanically-adjacent steps are now batched into one executor each, WITHOUT
# moving any branching decision out of the .mjs.
# ============================================================================

run_node_case "K942 spawn count: an L0-shaped 3-item level spends 6 machinery executors per item, not one per command" "
$PREAMBLE

// Board ON + ghIssue → the full L0 shape: claim, worktree, gate, rebase, scan,
// push, pr-open, then a CI poll that needs two slices (TIMEOUT then CI_GREEN).
for (const [slug, pr, sha] of [['a1', 11, 'aa103'], ['a2', 12, 'aa204'], ['a3', 13, 'aa305']]) {
  setMachinery(slug,
    { outcome: 'CLAIMED' },
    { outcome: 'CREATED', path: '/tmp/repo.wt/' + slug },
    { outcome: 'REVIEW_DIFF' },
    { outcome: 'GATE_PASS' },
    { outcome: 'REBASED', base: 'b', tip: 't', sha },
    { outcome: 'SCAN_CLEAN' },
    { outcome: 'PUSHED', sha, branch: 'build/' + slug },
    { outcome: 'PR_OPENED', pr_number: pr },
    { outcome: 'TIMEOUT' },
    { outcome: 'CI_GREEN' },
  );
  happyWorker(slug);
}

globalThis.args = { ...baseArgs, board: 3, claimCmd: '/fake/claim.sh', items: [
  { slug: 'a1', branch: 'build/a1', title: 'A1', kind: 'impl', ghIssue: 1, acceptance: ['c'] },
  { slug: 'a2', branch: 'build/a2', title: 'A2', kind: 'impl', ghIssue: 2, acceptance: ['c'] },
  { slug: 'a3', branch: 'build/a3', title: 'A3', kind: 'impl', ghIssue: 3, acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();

let reason = null;
if ((result.parked ?? []).length !== 3) reason = 'expected 3 parked, got ' + JSON.stringify(result);
else if ((result.escalations ?? []).length !== 0) reason = 'expected 0 escalations, got ' + JSON.stringify(result.escalations);

const machineryCalls = callLog.filter(c => isMachineryCall(c.opts));
const workerCalls = callLog.filter(c => isWorkerCall(c.opts));

// The number of agent spawns the OLD one-agent-per-command bridge would have
// paid for exactly this run: one per batched step actually executed, plus one
// per solo (unbatched) machinery call. Derived from the run, not hardcoded.
const soloCalls = machineryCalls.filter(c => !/^Steps: /m.test(c.promptFull)).length;
const unbatched = machineryStepLog.length + soloCalls;

if (!reason && workerCalls.length !== 3) reason = 'expected 3 worker spawns, got ' + workerCalls.length;
// 8 machinery executors per item: prelude, worker-clock + worker-usage
// (temperloop#2065 — bracketing the worker call excluded from this filtered
// view), review-diff (temperloop#1430), gate-freshness (temperloop#1937),
// gate, pr-batch, ci-batch.
if (!reason && machineryCalls.length !== 24) reason = 'expected 24 machinery executors (8/item), got ' + machineryCalls.length + ': ' + JSON.stringify(machineryCalls.map(c => c.opts.label));
if (!reason && callLog.length !== 27) reason = 'expected 27 total agent spawns for the level, got ' + callLog.length;
// …and that is a real reduction against the un-batched equivalent of this run.
if (!reason && unbatched !== 45) reason = 'expected the un-batched equivalent to be 45 spawns, got ' + unbatched;
if (!reason && !(machineryCalls.length < unbatched)) reason = 'batching did not reduce machinery spawns: ' + machineryCalls.length + ' vs ' + unbatched;

// Per item, the executors are exactly these eight, in this order — the
// temperloop#2065 clock/usage seam brackets the (filtered-out) worker call,
// strictly between prelude and review; the temperloop#1937 freshness check
// runs strictly between review and the gate.
for (const slug of ['a1', 'a2', 'a3']) {
  const labels = machineryCalls.filter(c => (c.opts.label||'').includes(slug)).map(c => c.opts.label);
  const want = ['prelude:' + slug, 'worker-clock:' + slug + '#worker:' + slug, 'worker-usage:' + slug + '#worker:' + slug, 'review-diff:' + slug, 'gate-freshness:' + slug, 'gate:' + slug, 'pr-batch:' + slug, 'ci-batch:' + slug + '#0'];
  if (!reason && JSON.stringify(labels) !== JSON.stringify(want))
    reason = slug + ' machinery executors wrong: ' + JSON.stringify(labels);
  // Every mechanical step still RAN — batching removed spawns, not work.
  const want2 = ['claim','worktree','rebase','scan','push','pr-open','merge-state','ci-poll','merge-state','ci-poll'];
  if (!reason && JSON.stringify(stepsRun(slug)) !== JSON.stringify(want2))
    reason = slug + ' batched steps wrong: ' + JSON.stringify(stepsRun(slug));
}
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K942 prelude batching: claim + deps-merged + worktree ride ONE executor, each still branched in .mjs" "
$PREAMBLE

// All three prelude steps present, all green → ONE executor, three steps.
setMachinery('pre-ok',
  { outcome: 'CLAIMED' },
  { outcome: 'DEPS_MERGED' },
  { outcome: 'CREATED', path: '/tmp/repo.wt/pre-ok' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'ae49' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'ae49', branch: 'build/pre-ok' },
  { outcome: 'PR_OPENED', pr_number: 942 },
  { outcome: 'CI_GREEN' },
);
happyWorker('pre-ok');

// Claim conflict inside the SAME batch: the .mjs must still make the
// claim-conflict decision, and the batch must never reach worktree create.
setMachinery('pre-claimfail', { outcome: 'CLAIM_CONFLICT' });

globalThis.args = { ...baseArgs, board: 3, claimCmd: '/fake/claim.sh', items: [
  { slug: 'pre-ok', branch: 'build/pre-ok', title: 'Pre OK', kind: 'impl', ghIssue: 10, acceptance: ['c'],
    dependsOn: [{ slug: 'dep', sha: 'ade16' }] },
  { slug: 'pre-claimfail', branch: 'build/pre-claimfail', title: 'Pre claim fail', kind: 'impl', ghIssue: 11, acceptance: ['c'],
    dependsOn: [{ slug: 'dep', sha: 'ade16' }] },
]};

const mod = await loadLevel();
const result = await mod.default();

const preludeCalls = callLog.filter(c => (c.opts.label||'').startsWith('prelude:'));
const okPrelude = preludeCalls.find(c => c.opts.label === 'prelude:pre-ok');
let reason = null;
if ((result.parked ?? []).length !== 1 || result.parked[0].slug !== 'pre-ok') reason = 'pre-ok should park: ' + JSON.stringify(result);
else if ((result.escalations ?? []).length !== 1 || result.escalations[0].kind !== 'claim-conflict') reason = 'expected 1 claim-conflict escalation: ' + JSON.stringify(result.escalations);
// ONE executor per item covers the whole prelude — not three.
else if (preludeCalls.length !== 2) reason = 'expected exactly 2 prelude executors (1/item), got ' + preludeCalls.length;
else if (JSON.stringify(stepsRun('pre-ok').slice(0,3)) !== JSON.stringify(['claim','deps-merged','worktree'])) reason = 'pre-ok prelude steps wrong: ' + JSON.stringify(stepsRun('pre-ok'));
// The failing claim short-circuits the batch — worktree create never runs.
else if (JSON.stringify(stepsRun('pre-claimfail')) !== JSON.stringify(['claim'])) reason = 'a CLAIM_CONFLICT must stop the prelude before deps/worktree: ' + JSON.stringify(stepsRun('pre-claimfail'));
// The executor prompt names its steps, and the executor is told an early stop is
// expected — by its own definition on the lean default (temperloop#1014), by the
// per-call prompt on the general-purpose fallback.
else if (!/^Steps: claim, deps-merged, worktree$/m.test(okPrelude.promptFull)) reason = 'prelude prompt missing the Steps manifest';
else if (okPrelude.opts.agentType !== 'machinery-executor') reason = 'prelude executor should run as machinery-executor, got ' + okPrelude.opts.agentType;
else if (!/stops early/i.test(AGENT_DEF + okPrelude.promptFull)) reason = 'the executor must be told an early stop is expected, not an error';
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K942 ci-poll reuse: 5 poll slices cost 3 ci-batch executors, not 5 polls + 5 merge-checks" "
$PREAMBLE

setMachinery('slow-ci',
  { outcome: 'CREATED', path: '/tmp/repo.wt/slow-ci' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'a59' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'a59', branch: 'build/slow-ci' },
  { outcome: 'PR_OPENED', pr_number: 700 },
  { outcome: 'TIMEOUT' },
  { outcome: 'TIMEOUT' },
  { outcome: 'TIMEOUT' },
  { outcome: 'TIMEOUT' },
  { outcome: 'CI_GREEN' },
);
happyWorker('slow-ci');

globalThis.args = { ...baseArgs, items: [
  { slug: 'slow-ci', branch: 'build/slow-ci', title: 'Slow CI', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();

const ciBatches = callLog.filter(c => (c.opts.label||'').startsWith('ci-batch:'));
const polls = stepsRun('slow-ci').filter(k => k === 'ci-poll').length;
const probes = stepsRun('slow-ci').filter(k => k === 'merge-state').length;
let reason = null;
if ((result.parked ?? []).length !== 1) reason = 'expected 1 parked after 5 slices: ' + JSON.stringify(result);
else if (polls !== 5) reason = 'expected 5 ci-poll slices to run, got ' + polls;
// #543 interleaving is PRESERVED: one merge-state probe immediately before EVERY slice.
else if (probes !== 5) reason = 'expected one merge-state probe per slice (5), got ' + probes;
// …but 5 slices + 5 probes cost only ceil(5/2)=3 executor spawns, not 10.
else if (ciBatches.length !== 3) reason = 'expected 3 ci-batch executors for 5 slices, got ' + ciBatches.length + ': ' + JSON.stringify(ciBatches.map(c=>c.opts.label));
else if (!(ciBatches.length < polls + probes)) reason = 'ci polling did not reduce spawns';
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K942 cap invariant: no ci-batch may ask a single Bash invocation to outlive the ~10-min cap (DESIGN NOTE 2)" "
$PREAMBLE

happyMachinery('cap-item', 800, 'aca0a');
happyWorker('cap-item');
globalThis.args = { ...baseArgs, items: [
  { slug: 'cap-item', branch: 'build/cap-item', title: 'Cap item', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
await mod.default();

const AGENT_BASH_CAP_MS = 600000; // the Bash tool's own maximum timeout
let reason = null;
const batches = callLog.filter(c => (c.opts.label||'').startsWith('ci-batch:'));
if (batches.length === 0) reason = 'no ci-batch executor observed';
for (const b of batches) {
  if (reason) break;
  const p = b.promptFull;
  // Only the emitted COMMAND body counts — the standing instruction lines above
  // it name ci-poll.sh too, and those are prose, not invocations.
  const body = p.slice(p.indexOf('\nCommand:\n'));
  // Every ci-poll.sh invocation in the batch carries its OWN short --timeout…
  const slices = (body.match(/ci-poll\.sh/g) || []).length;
  const timeouts = [...body.matchAll(/--timeout '(\\d+)'/g)].map(m => Number(m[1]));
  if (slices === 0) { reason = 'ci-batch runs no ci-poll.sh'; break; }
  if (timeouts.length !== slices) { reason = 'every ci-poll.sh slice must carry its own --timeout: ' + slices + ' slices, ' + timeouts.length + ' timeouts'; break; }
  const worst = timeouts.reduce((a, b2) => a + b2, 0) * 1000; // whole batch, worst case
  if (worst >= AGENT_BASH_CAP_MS) { reason = 'batched poll wall ' + worst + 'ms reaches the ' + AGENT_BASH_CAP_MS + 'ms Bash cap (slices=' + slices + ', timeouts=' + JSON.stringify(timeouts) + ')'; break; }
  // …and no single slice is itself a long poll.
  if (timeouts.some(t => t * 1000 >= AGENT_BASH_CAP_MS)) { reason = 'a single poll slice reaches the Bash cap: ' + JSON.stringify(timeouts); break; }
  // The Bash-tool timeout the executor is told to use must cover the poll wall
  // and still stay at or under the cap.
  const m = p.match(/\`timeout\` parameter to (\\d+)/);
  if (!m) { reason = 'ci-batch prompt does not set an explicit Bash-tool timeout — the default 120s would kill a 240s slice'; break; }
  const declared = Number(m[1]);
  if (declared > AGENT_BASH_CAP_MS) { reason = 'declared Bash timeout ' + declared + ' exceeds the cap'; break; }
  if (declared < worst) { reason = 'declared Bash timeout ' + declared + ' is under the batch poll wall ' + worst; break; }
}
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K942 quoting: every interpolated value in a BATCHED command is still sq()-quoted" "
$PREAMBLE

// Spaced repo root / plan link / branch, and an apostrophe in the title — the
// live-probe shapes DESIGN NOTE 1 marks CRITICAL. Batching joins the same
// per-step command strings, so the quoting must survive verbatim.
const WT = '/tmp/re po.wt/q-item';
setMachinery('q-item',
  { outcome: 'CLAIMED' },
  { outcome: 'DEPS_MERGED' },
  { outcome: 'CREATED', path: WT },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'a4b' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'a4b', branch: 'feat/spaced branch' },
  { outcome: 'PR_OPENED', pr_number: 942 },
  { outcome: 'CI_GREEN' },
);
happyWorker('q-item');

globalThis.args = {
  ...baseArgs,
  repoRoot: '/tmp/re po',
  planLink: 'Plans/2026-08-01 kernel - batch machinery.md',
  board: 3,
  claimCmd: '/fake/cl aim.sh',
  machineryBinDir: '/mb dir',
  items: [
    { slug: 'q-item', branch: 'feat/spaced branch', title: \"It's a spaced title\", kind: 'impl', ghIssue: 942, acceptance: ['c'],
      dependsOn: [{ slug: 'dep', sha: 'sha dep' }] },
  ],
};

const mod = await loadLevel();
const result = await mod.default();

const pre = callLog.find(c => c.opts.label === 'prelude:q-item');
const prb = callLog.find(c => c.opts.label === 'pr-batch:q-item');
let reason = null;
if ((result.parked ?? []).length !== 1) reason = 'expected 1 parked: ' + JSON.stringify(result);
else if (!pre || !prb) reason = 'missing batched executor calls';
else {
  const need = [
    [pre, \"'/fake/cl aim.sh'\"],
    [pre, \"'/mb dir/worktree.sh'\"],
    [pre, \"'/tmp/re po'\"],
    [prb, \"'/mb dir/pr.sh'\"],
    [prb, \"'\" + WT + \"'\"],
    [prb, \"'feat/spaced branch'\"],
    // temperloop#1806: a value CONTAINING a single quote is now emitted
    // DOUBLE-quoted (\"It's a spaced title\") rather than via the '\\'' idiom,
    // whose nesting the executor's own shell parser refused outright. Still
    // exactly ONE quoted shell word — which is what this case pins.
    [prb, '\\\"' + \"It's a spaced title\" + '\\\"'],
    [prb, \"'Plans/2026-08-01 kernel - batch machinery.md'\"],
  ];
  for (const [call, frag] of need) {
    if (!call.promptFull.includes(frag)) { reason = 'batched command lost the sq() quoting for: ' + frag; break; }
  }
  // Nothing may appear UNQUOTED: a bare spaced path in the command body would
  // split into two argv words and run the wrong command.
  if (!reason) {
    for (const [call, bare] of [[pre, ' /tmp/re po '], [prb, ' feat/spaced branch '], [pre, ' /mb dir/worktree.sh ']]) {
      if (call.promptFull.includes(bare)) { reason = 'an interpolated value appears UNQUOTED in a batched command: ' + JSON.stringify(bare); break; }
    }
  }
}
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

# --- K942 static lockstep guards (same tail-guard idiom as the K712/K939 blocks).
# These lock the SHAPE the batching depends on so a future edit cannot silently
# regress to one-agent-per-command or break the cap derivation. -----------------
grep -q 'async function runMachineryBatch(' "$MJS" \
  || fail "#942: runMachineryBatch() missing — the batched executor bridge"
grep -q 'function batchStep(' "$MJS" \
  || fail "#942: batchStep() missing — the driver must read EACH step's own outcome object out of the batch, not a single collapsed verdict"
echo "PASS: #942 batch-bridge guard — runMachineryBatch() + per-step batchStep() accessor present"
# The three batch sites must exist by label.
for lbl in 'prelude:' 'pr-batch:' 'ci-batch:'; do
  grep -q "label: \`${lbl}" "$MJS" \
    || fail "#942: batch site '${lbl}' missing — a mechanical sequence regressed to one agent per command"
done
echo "PASS: #942 batch-site guard — prelude / pr-batch / ci-batch executors all present"
# The cap invariant is DERIVED, never a literal: the slices-per-batch count must
# be computed from the max batch wall, so retuning the slice length can't produce
# a batch that outlives the agent's Bash cap (DESIGN NOTE 2).
grep -q 'CI_POLL_SLICES_PER_BATCH = Math.max(' "$MJS" \
  || fail "#942/DESIGN NOTE 2: CI_POLL_SLICES_PER_BATCH must be DERIVED from CI_POLL_MAX_BATCH_WALL_MS, not a hardcoded count"
grep -q 'CI_POLL_MAX_BATCH_WALL_MS / (CI_POLL_SLICE_SECS \* 1000)' "$MJS" \
  || fail "#942/DESIGN NOTE 2: the slices-per-batch derivation must divide the max batch wall by the slice length"
grep -q 'AGENT_BASH_CAP_MS' "$MJS" \
  || fail "#942/DESIGN NOTE 2: AGENT_BASH_CAP_MS ceiling missing — batch timeouts must be clamped to the Bash tool's max"
echo "PASS: #942 cap-derivation guard — the CI batch's slice count is derived from the Bash-cap budget, not hardcoded"
# The branching must NOT have moved into the agent prompt (DESIGN NOTE 1's real
# invariant): every closed-outcome decision still appears as .mjs source.
for tok in "outcome === 'SCAN_BLOCKED'" "outcome === 'PUSH_REJECTED'" "outcome === 'REBASE_CONFLICT'" "outcome === 'CI_GREEN'" "outcome === 'CI_FAILED'" "outcome === 'NO_CI'" "outcome === 'TIMEOUT'" "outcome !== 'DEPS_MERGED'" "outcome !== 'CREATED'" "outcome === 'CLAIM_CONFLICT'" "outcome === 'GATE_FAIL'" "outcome !== 'EXISTS'"; do
  grep -qF "$tok" "$MJS" \
    || fail "#942: branching decision \"$tok\" is no longer in legible .mjs — a batch must never collapse decisions into an opaque agent verdict"
done
echo "PASS: #942 legibility guard — every machinery branch (SCAN_BLOCKED / PUSH_REJECTED / REBASE_CONFLICT / CI_* / DEPS_MERGED / CREATED / CLAIM_CONFLICT / GATE_FAIL / EXISTS) still lives in .mjs"

# ============================================================================
# TEST (temperloop#982): machinerySoloModel / machineryBatchModel model-tier
# overrides, plus the item.model worker seat. build.md/sweep.md/fix.md Step 0
# resolve BUILD_MACHINERY_SOLO_MODEL / BUILD_MACHINERY_BATCH_MODEL and pass
# them as input.machinerySoloModel / input.machineryBatchModel — NOT a
# config-file read from inside the .mjs (the Workflow runtime has no shell,
# DESIGN NOTE 1). Three things to prove, across THREE seats (gate: = solo
# runMachinery, prelude: = batched runMachineryBatch, worker: = item.model):
#   (a) when SET, the override reaches the spawned agent's opts.model at
#       each of the three seats;
#   (b) when UNSET (omitted from args — the default), all three seats spawn
#       at their pre-existing default — 'haiku' for gate:/prelude:, undefined
#       (inherit session) for worker: — byte-identical to before this item;
#   (c) when set to an EMPTY STRING (not omitted — the failure mode a
#       careless caller can trivially produce), all three seats STILL fall
#       back to their default, never spawn with a literal '' model. This is
#       the load-bearing case: build-level.mjs reads `|| 'haiku'` /
#       `|| undefined`, not `?? 'haiku'` / `item.model` bare, specifically so
#       an empty string collapses the same as an absent value — `??` alone
#       would let '' sail through as a literal (invalid) model name.
# ============================================================================
run_node_case "machinerySoloModel/machineryBatchModel/item.model SET → override reaches gate:/prelude:/worker: agent().opts.model (#982)" "
$PREAMBLE
happyMachinery('mtier', 270, 'ae3c');
happyWorker('mtier');
globalThis.args = { ...baseArgs, machinerySoloModel: 'opus', machineryBatchModel: 'sonnet', items: [
  { slug: 'mtier', branch: 'build/mtier', title: 'Mtier', kind: 'impl', acceptance: ['c'], model: 'haiku-worker-tier' },
]};
const mod = await loadLevel();
const result = await mod.default();
if ((result.parked ?? []).length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 1 parked, got ' + JSON.stringify(result) })); process.exit(0); }
const gateCall = callLog.find(c => c.opts.label === 'gate:mtier');
const preludeCall = callLog.find(c => c.opts.label === 'prelude:mtier');
const workerCall = callLog.find(c => isWorkerCall(c.opts) && c.opts.label === 'worker:mtier');
if (!gateCall) { console.log(JSON.stringify({ ok: false, reason: 'no gate:mtier call recorded' })); process.exit(0); }
if (!preludeCall) { console.log(JSON.stringify({ ok: false, reason: 'no prelude:mtier call recorded' })); process.exit(0); }
if (!workerCall) { console.log(JSON.stringify({ ok: false, reason: 'no worker:mtier call recorded' })); process.exit(0); }
if (gateCall.opts.model !== 'opus')
  { console.log(JSON.stringify({ ok: false, reason: 'gate: (runMachinery/machinerySoloModel) opts.model=' + gateCall.opts.model + ', expected opus' })); process.exit(0); }
if (preludeCall.opts.model !== 'sonnet')
  { console.log(JSON.stringify({ ok: false, reason: 'prelude: (runMachineryBatch/machineryBatchModel) opts.model=' + preludeCall.opts.model + ', expected sonnet' })); process.exit(0); }
if (workerCall.opts.model !== 'haiku-worker-tier')
  { console.log(JSON.stringify({ ok: false, reason: 'worker: (item.model) opts.model=' + workerCall.opts.model + ', expected haiku-worker-tier' })); process.exit(0); }
console.log(JSON.stringify({ ok: true }));
"

run_node_case "machinerySoloModel/machineryBatchModel/item.model UNSET (omitted) → gate:/prelude: 'haiku', worker: undefined (inherit session), byte-identical (#982)" "
$PREAMBLE
happyMachinery('mtierdef', 271, 'aedef3d');
happyWorker('mtierdef');
globalThis.args = { ...baseArgs, items: [
  { slug: 'mtierdef', branch: 'build/mtierdef', title: 'Mtierdef', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
const result = await mod.default();
if ((result.parked ?? []).length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 1 parked, got ' + JSON.stringify(result) })); process.exit(0); }
const gateCall = callLog.find(c => c.opts.label === 'gate:mtierdef');
const preludeCall = callLog.find(c => c.opts.label === 'prelude:mtierdef');
const workerCall = callLog.find(c => isWorkerCall(c.opts) && c.opts.label === 'worker:mtierdef');
if (!gateCall || gateCall.opts.model !== 'haiku')
  { console.log(JSON.stringify({ ok: false, reason: 'gate: opts.model=' + (gateCall && gateCall.opts.model) + ', expected unchanged haiku default' })); process.exit(0); }
if (!preludeCall || preludeCall.opts.model !== 'haiku')
  { console.log(JSON.stringify({ ok: false, reason: 'prelude: opts.model=' + (preludeCall && preludeCall.opts.model) + ', expected unchanged haiku default' })); process.exit(0); }
if (!workerCall || workerCall.opts.model !== undefined)
  { console.log(JSON.stringify({ ok: false, reason: 'worker: opts.model=' + JSON.stringify(workerCall && workerCall.opts.model) + ', expected undefined (inherit session)' })); process.exit(0); }
console.log(JSON.stringify({ ok: true }));
"

run_node_case "machinerySoloModel/machineryBatchModel/item.model set to EMPTY STRING → all three seats still fall back to their default, never spawn at '' (#982 BLOCKING fix)" "
$PREAMBLE
happyMachinery('mtierempty', 272, 'aee3e');
happyWorker('mtierempty');
globalThis.args = { ...baseArgs, machinerySoloModel: '', machineryBatchModel: '', items: [
  { slug: 'mtierempty', branch: 'build/mtierempty', title: 'Mtierempty', kind: 'impl', acceptance: ['c'], model: '' },
]};
const mod = await loadLevel();
const result = await mod.default();
if ((result.parked ?? []).length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 1 parked, got ' + JSON.stringify(result) })); process.exit(0); }
const gateCall = callLog.find(c => c.opts.label === 'gate:mtierempty');
const preludeCall = callLog.find(c => c.opts.label === 'prelude:mtierempty');
const workerCall = callLog.find(c => isWorkerCall(c.opts) && c.opts.label === 'worker:mtierempty');
console.log('EMPTY-STRING PROBE  gate.model=' + JSON.stringify(gateCall && gateCall.opts.model) + '  prelude.model=' + JSON.stringify(preludeCall && preludeCall.opts.model) + '  worker.model=' + JSON.stringify(workerCall && workerCall.opts.model));
if (!gateCall || gateCall.opts.model !== 'haiku')
  { console.log(JSON.stringify({ ok: false, reason: 'gate: opts.model=' + JSON.stringify(gateCall && gateCall.opts.model) + ', expected haiku (empty string must collapse to the default, not ride through as \"\")' })); process.exit(0); }
if (!preludeCall || preludeCall.opts.model !== 'haiku')
  { console.log(JSON.stringify({ ok: false, reason: 'prelude: opts.model=' + JSON.stringify(preludeCall && preludeCall.opts.model) + ', expected haiku (empty string must collapse to the default, not ride through as \"\")' })); process.exit(0); }
if (!workerCall || workerCall.opts.model !== undefined)
  { console.log(JSON.stringify({ ok: false, reason: 'worker: opts.model=' + JSON.stringify(workerCall && workerCall.opts.model) + ', expected undefined (empty string must collapse to inherit-session, not ride through as \"\")' })); process.exit(0); }
console.log(JSON.stringify({ ok: true }));
"

# Static guard: the 'haiku' literal must remain at BOTH machinery-executor
# sites as the absent/empty-input default (epic Contract clause superseded —
# #982 acceptance). Matches the `||` form (NOT `??` — `??` does not close the
# empty-string hole the BLOCKING fix above exists to close, so a guard that
# still matched `?? 'haiku'` would silently stop guarding the real invariant).
haikuHits="$(grep -c "|| 'haiku'" "$MJS" || true)"
if [ "$haikuHits" -lt 2 ]; then
  fail "#982: expected 'haiku' literal to remain as the absent/empty-input default (via \`|| 'haiku'\`) at BOTH runMachinery/runMachineryBatch sites (found $haikuHits, want >=2)"
fi
if grep -qF "?? 'haiku'" "$MJS"; then
  fail "#982: found a lingering \`?? 'haiku'\` — this must be \`|| 'haiku'\` (the empty-string-safety BLOCKING fix); \`??\` lets an empty-string input defeat the fallback"
fi
echo "PASS: #982 haiku-literal-retained guard — found $haikuHits '|| '\''haiku'\''' fallback site(s), no lingering '?? '\''haiku'\'''"

# ============================================================================
# temperloop#1014 — machinery executors carry a LEAN context
# ============================================================================

run_node_case "K1014 lean default: every machinery executor runs as machinery-executor, with the standing contract dropped from the prompt but the #72 framing and the Bash timeout kept" "
$PREAMBLE
happyMachinery('lean1', 1014, 'aea136');
happyWorker('lean1');
globalThis.args = { ...baseArgs, items: [
  { slug: 'lean1', branch: 'build/lean1', title: 'Lean', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
const result = await mod.default();
const mach = callLog.filter(c => isMachineryCall(c.opts));
const gate = mach.find(c => c.opts.label === 'gate:lean1');
const ci = mach.find(c => (c.opts.label||'').startsWith('ci-batch:lean1'));
let reason = null;
if ((result.parked ?? []).length !== 1) reason = 'expected 1 parked, got ' + JSON.stringify(result);
else if (mach.length === 0) reason = 'no machinery executors spawned';
else if (mach.some(c => c.opts.agentType !== 'machinery-executor')) reason = 'every machinery executor must run as machinery-executor, got ' + JSON.stringify(mach.map(c => c.opts.agentType));
// The two #72 classifier-facing framing lines survive on the lean path — the
// classifier reads the PROMPT, never the agent definition.
else if (!/^Run this single build-machinery helper command with the Bash tool, exactly as written\.$/m.test(gate.promptFull)) reason = 'lean solo prompt lost the #72 opening framing line';
else if (!/known project script/.test(gate.promptFull)) reason = 'lean solo prompt lost the #72 known-project-script framing line';
else if (!/^It is a short shell script that calls known project helper scripts/m.test(ci.promptFull)) reason = 'lean batch prompt lost the #72 framing line';
else if (!/^Steps: /m.test(ci.promptFull)) reason = 'lean batch prompt lost the Steps manifest';
// #115 stays enforced: the long-running gate still names an explicit Bash-tool timeout.
else if (!/Set the Bash tool \`timeout\` parameter to [0-9]+\./.test(gate.promptFull)) reason = 'lean solo prompt lost the explicit Bash-tool timeout instruction';
else if (!/Set the Bash tool \`timeout\` parameter to [0-9]+\./.test(ci.promptFull)) reason = 'lean batch prompt lost the explicit Bash-tool timeout instruction';
// The standing contract is gone from the prompt — it lives in the definition.
else if (/prints a SINGLE JSON line/.test(gate.promptFull)) reason = 'lean solo prompt still restates the standing JSON-line contract';
else if (/STOPS EARLY|Copy each object VERBATIM/.test(ci.promptFull)) reason = 'lean batch prompt still restates the standing verbatim/stop-early contract';
else if (!/JSON line/.test(AGENT_DEF) || !/verbatim/i.test(AGENT_DEF)) reason = 'the machinery-executor definition must carry the standing JSON-line/verbatim contract';
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K1014 fallback: an unresolvable machinery-executor re-issues ONCE as general-purpose with the FULL prompt, and the level completes unchanged" "
$PREAMBLE
happyMachinery('fb1', 1015, 'afb120');
happyWorker('fb1');
// Simulate a checkout where the agent definition was never deployed: the runtime
// rejects the agentType at RESOLUTION time, before any subagent runs.
const origAgent = globalThis.agent;
let rejected = 0;
globalThis.agent = async function(prompt, opts = {}) {
  if (opts.agentType === 'machinery-executor') {
    rejected++;
    callLog.push({ prompt: String(prompt).slice(0,120), promptFull: String(prompt), opts: { label: opts.label, phase: opts.phase, model: opts.model, agentType: opts.agentType, rejected: true } });
    throw new Error(\"agent({agentType}): agent type 'machinery-executor' not found. Available agents: general-purpose\");
  }
  return origAgent(prompt, opts);
};
globalThis.args = { ...baseArgs, items: [
  { slug: 'fb1', branch: 'build/fb1', title: 'Fallback', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
const result = await mod.default();
const served = callLog.filter(c => isMachineryCall(c.opts) && !c.opts.rejected);
const gate = served.find(c => c.opts.label === 'gate:fb1');
const ci = served.find(c => (c.opts.label||'').startsWith('ci-batch:fb1'));
let reason = null;
if ((result.parked ?? []).length !== 1 || result.parked[0].pr !== 1015) reason = 'the level must complete unchanged under fallback: ' + JSON.stringify(result);
// Sticky: exactly ONE rejected probe for the whole level, not one per call.
else if (rejected !== 1) reason = 'the unavailable agent type must be probed once and then pinned, got ' + rejected + ' rejections';
else if (served.some(c => c.opts.agentType !== 'general-purpose')) reason = 'every served machinery call must fall back to general-purpose, got ' + JSON.stringify(served.map(c => c.opts.agentType));
// The fallback prompt restates the standing contract, exactly as before #1014.
else if (!/prints a SINGLE JSON line/.test(gate.promptFull)) reason = 'fallback solo prompt must restate the standing JSON-line contract';
else if (!/STOPS EARLY/.test(ci.promptFull) || !/Copy each object VERBATIM/.test(ci.promptFull)) reason = 'fallback batch prompt must restate the standing stop-early/verbatim contract';
else if (!/This command runs longer than usual/.test(gate.promptFull)) reason = 'fallback solo prompt must restate the long-form #115 timeout instruction';
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K1014 narrow catch: a NON-resolution executor failure propagates — the fallback never re-runs a machinery command" "
$PREAMBLE
happyMachinery('nar1', 1017, 'aa140');
happyWorker('nar1');
// A mid-agent failure (the #939 StructuredOutput-cap shape): the subagent DID
// run, so re-issuing the command under another agent type would re-execute a
// non-idempotent machinery step. It must propagate, not fall back.
const origAgent = globalThis.agent;
let attempts = 0;
// temperloop#2020: count the PIPELINE's machinery attempts only. The
// escalation-path work-preservation push (\`preserve-push:<slug>\`) is a
// DIFFERENT command issued after the item has already escalated, not a
// re-issue of the failed one — counting it here would silently convert this
// assertion from 'never retried' into 'never touched machinery again'. It is
// asserted separately below, including that it too throws and is swallowed.
let preserveAttempts = 0;
globalThis.agent = async function(prompt, opts = {}) {
  if (isMachineryCall(opts)) {
    if (/^preserve-push:/.test(String(opts.label || ''))) preserveAttempts++; else attempts++;
    callLog.push({ prompt: '', promptFull: String(prompt), opts: { label: opts.label, phase: opts.phase, agentType: opts.agentType } });
    throw new Error('agent({schema}): StructuredOutput retry cap (3) exceeded');
  }
  return origAgent(prompt, opts);
};
globalThis.args = { ...baseArgs, items: [
  { slug: 'nar1', branch: 'build/nar1', title: 'Narrow', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
const result = await mod.default();
let reason = null;
if (attempts !== 1) reason = 'a non-resolution failure must NOT be retried under another agent type, got ' + attempts + ' machinery attempts';
else if ((result.escalations ?? []).length !== 1 || result.escalations[0].kind !== 'worker-error') reason = 'the throw must surface as a worker-error escalation: ' + JSON.stringify(result);
// #2020 fail-soft: the preservation push ran once and THREW, and that throw
// must not have changed the escalation the item was already carrying.
else if (preserveAttempts !== 1) reason = 'the escalation path must attempt work preservation exactly once, got ' + preserveAttempts;
else if (result.escalations[0].payload.committed_work.outcome !== 'ERROR') reason = 'a THROWN preservation push must be swallowed and recorded as ERROR, never re-thrown: ' + JSON.stringify(result.escalations[0].payload.committed_work);
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K1014 pin: input.machineryAgentType='general-purpose' reproduces the pre-#1014 executor prompts byte-identically, with no probe spawn" "
$PREAMBLE
happyMachinery('pin1', 1016, 'a148');
happyWorker('pin1');
globalThis.args = { ...baseArgs, machineryAgentType: 'general-purpose', items: [
  { slug: 'pin1', branch: 'build/pin1', title: 'Pin', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
const result = await mod.default();
const mach = callLog.filter(c => isMachineryCall(c.opts));
const gate = mach.find(c => c.opts.label === 'gate:pin1');
let reason = null;
if ((result.parked ?? []).length !== 1) reason = 'expected 1 parked, got ' + JSON.stringify(result);
else if (mach.some(c => c.opts.agentType !== 'general-purpose')) reason = 'an explicit pin must be honoured with no lean attempt, got ' + JSON.stringify(mach.map(c => c.opts.agentType));
else if (!/prints a SINGLE JSON line/.test(gate.promptFull) || !/This command runs longer than usual/.test(gate.promptFull)) reason = 'a pinned general-purpose run must send the full pre-#1014 prompt';
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

# Static guard: the executor agent definition must stay Bash-only — the whole
# context win is the tool surface it does NOT carry, and a widened `tools:` line
# silently gives it back (plus hands a mechanical executor the file-editing
# powers the bridge deliberately does not want it to have).
defTools="$(awk '/^---$/{n++; next} n==1 && /^tools:/' "$AGENT_DEF" | head -1)"
if [ "$defTools" != "tools: Bash" ]; then
  fail "#1014: claude/agents/machinery-executor.md must declare exactly 'tools: Bash' (found: '${defTools:-<none>}')"
fi
# Exactly ONE `agentType: 'general-purpose'` may remain — machineryAgent()'s
# fallback re-issue. A second one is an executor call site that bypassed the
# resolved type and would keep paying the full-context spawn forever.
gpHits="$(grep -c "agentType: 'general-purpose'" "$MJS" || true)"
if [ "$gpHits" -ne 1 ]; then
  fail "#1014: expected exactly 1 \`agentType: 'general-purpose'\` (machineryAgent()'s fallback re-issue), found $gpHits — every executor call site must route through machineryAgent()'s resolved type"
fi
echo "PASS: #1014 lean-executor guards — machinery-executor is Bash-only; the only general-purpose executor type is machineryAgent()'s fallback"

# ============================================================================
# TEST (temperloop#852): cross-repo `Closes` qualification. build.md 3f's
# "Cross-repo `repo:` honor point" requires a fully-qualified `owner/repo#N`
# Closes ref whenever an item's `gh_issue:`/`also_closes:` numbers are tracked
# in a DIFFERENT repo than the one the PR opens against — pr.sh itself already
# handles either shape verbatim (closes_line()/validate_issue()); the defect
# was build-level.mjs always passing the bare number to --gh-issue/
# --also-closes regardless of `item.repo`. Three items, one level:
#   - 'same-repo'  — no `repo:` field  → bare Closes #N (unchanged default)
#   - 'same-explicit' — `repo:` EQUAL to ownerRepo → still bare (exact-match,
#     not merely "repo: present")
#   - 'cross-repo' — `repo:` DIFFERENT from ownerRepo → qualified
#     `owner/repo#N` on BOTH --gh-issue and --also-closes
# ============================================================================
run_node_case "temperloop#852: item.repo != ownerRepo qualifies --gh-issue/--also-closes as owner/repo#N; same-repo (absent or equal repo:) stays bare" "
$PREAMBLE
happyMachinery('same-repo', 852, 'aae56');
happyMachinery('same-explicit', 853, 'aae257');
happyMachinery('cross-repo', 854, 'ac13');
happyWorker('same-repo');
happyWorker('same-explicit');
happyWorker('cross-repo');

globalThis.args = { ...baseArgs, items: [
  { slug: 'same-repo', branch: 'build/same-repo', title: 'Same Repo', kind: 'impl', acceptance: ['c'],
    ghIssue: 500, alsoCloses: [501, 502] },
  { slug: 'same-explicit', branch: 'build/same-explicit', title: 'Same Explicit', kind: 'impl', acceptance: ['c'],
    repo: 'owner/repo', ghIssue: 550, alsoCloses: [551] },
  { slug: 'cross-repo', branch: 'build/cross-repo', title: 'Cross Repo', kind: 'impl', acceptance: ['c'],
    repo: 'other/repo', ghIssue: 600, alsoCloses: [601, 602] },
]};

const mod = await loadLevel();
const result = await mod.default();

let reason = null;
if ((result.parked ?? []).length !== 3) reason = 'expected 3 parked: ' + JSON.stringify(result);
if (!reason) {
  const sameCall = callLog.find(c => c.opts.label === 'pr-batch:same-repo');
  const sameExplicitCall = callLog.find(c => c.opts.label === 'pr-batch:same-explicit');
  const crossCall = callLog.find(c => c.opts.label === 'pr-batch:cross-repo');
  if (!sameCall || !sameExplicitCall || !crossCall) { reason = 'missing pr-batch executor call(s)'; }
  else {
    // The qualifier is ownerRepo (the plan's HOME repo, where the issue was
    // triaged) — NOT item.repo (the repo the PR opens against). See the #852
    // build.md 3f honor-point rationale quoted at the .mjs call site.
    const checks = [
      [sameCall, \"--gh-issue '500'\", true],
      [sameCall, \"--also-closes '501,502'\", true],
      [sameCall, \"'owner/repo#\", false],
      [sameExplicitCall, \"--gh-issue '550'\", true],
      [sameExplicitCall, \"--also-closes '551'\", true],
      [sameExplicitCall, \"'owner/repo#\", false],
      [crossCall, \"--gh-issue 'owner/repo#600'\", true],
      [crossCall, \"--also-closes 'owner/repo#601,owner/repo#602'\", true],
      [crossCall, \"--gh-issue '600'\", false],
    ];
    for (const [call, frag, want] of checks) {
      const has = call.promptFull.includes(frag);
      if (has !== want) { reason = (want ? 'missing expected ' : 'unexpectedly found ') + JSON.stringify(frag) + ' in ' + call.opts.label; break; }
    }
  }
}
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

# ============================================================================
# TEST: temperloop#1071 — the machinery-step WALL-CLOCK LIVENESS BOUND.
#
# The incident: a `pr-batch` machinery agent ran 35,362,333ms (9h49m) on TWO
# tool calls. One Bash invocation blocked and then completed successfully (all
# four steps green, the PR opened). The Bash tool's own `timeout` is capped at
# 600,000ms, so a 9.8h call is supposed to be unreachable — it did not fire, and
# nothing else bounded the call.
#
# The seam under test is deliberately ROOT-CAUSE-AGNOSTIC (the stall's cause is
# NOT established): a per-step ceiling compiled into the emitted shell, plus a
# disposal that treats a bounded-out step as LOST and routes it through the
# EXISTING pr.sh recover-probe rather than re-issuing a non-idempotent command.
# ============================================================================

run_node_case "K1071 adopt: a timed-out pr-batch step whose PR already opened is ADOPTED, never re-opened" "
$PREAMBLE
// The #1071 shape exactly: the batch's push step outlives the ceiling and is
// killed, but the work in fact LANDED (this is what the real incident did — the
// 9h49m call opened PR #1070). recover-probe sees the open PR, so the item must
// adopt it and flow on to CI — never re-push, never re-open.
setMachinery('to-item',
  { outcome: 'CREATED', path: '/tmp/repo.wt/to-item' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'a5b' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'STEP_TIMEOUT', step: 'push', ceiling_secs: 900, elapsed_secs: 35362 },
  { outcome: 'RECOVER_PR_OPEN', pr_number: 1070, sha: 'a5b', pushed: true, verification_surface_present: true },
  { outcome: 'CI_GREEN' },
);
happyWorker('to-item');
globalThis.args = { ...baseArgs, items: [{ slug: 'to-item', branch: 'b/to', title: 'T', kind: 'impl', acceptance: ['c'] }] };
const mod = await loadLevel();
const result = await mod.default();
const parked = result.parked ?? [];
const steps = stepsRun('to-item');
let reason = null;
if ((result.escalations ?? []).length !== 0) reason = 'a recoverable step timeout must NOT escalate: ' + JSON.stringify(result.escalations);
else if (parked.length !== 1) reason = 'expected the item to park on the adopted PR: ' + JSON.stringify(result);
else if (parked[0].pr !== 1070) reason = 'must park on the PR the timed-out step actually opened, got ' + parked[0].pr;
else if (steps.includes('pr-open')) reason = 'DOUBLE-OPEN: pr-open ran after the batch was bounded out at push';
else if (!callLog.some(c => c.opts.label === 'recover-probe:to-item')) reason = 'disposal must go through the EXISTING pr.sh recover-probe path';
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K1071 escalate: a timed-out step with NO landed side-effect escalates machinery-step-timeout, never retries" "
$PREAMBLE
setMachinery('to2',
  { outcome: 'CREATED', path: '/tmp/repo.wt/to2' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'a261' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'STEP_TIMEOUT', step: 'push', ceiling_secs: 900, elapsed_secs: 901 },
  noSideEffects(),
);
happyWorker('to2');
globalThis.args = { ...baseArgs, items: [{ slug: 'to2', branch: 'b/to2', title: 'T', kind: 'impl', acceptance: ['c'] }] };
const mod = await loadLevel();
const result = await mod.default();
const esc = (result.escalations ?? [])[0];
const steps = stepsRun('to2');
let reason = null;
if (!esc) reason = 'expected an escalation: ' + JSON.stringify(result);
else if (esc.kind !== 'machinery-step-timeout') reason = 'wrong escalation kind: ' + esc.kind;
else if (esc.payload.step !== 'push') reason = 'the payload must name WHICH step the ceiling bounded, got ' + JSON.stringify(esc.payload.step);
else if (esc.payload.probeStage !== 'RECOVER_NONE') reason = 'the payload must carry the recover-probe verdict, got ' + JSON.stringify(esc.payload.probeStage);
else if (steps.filter(k => k === 'push').length !== 1) reason = 'BLIND RETRY: push ran more than once';
else if (steps.includes('pr-open')) reason = 'pr-open must not run after a bounded-out push';
else if ((result.parked ?? []).length !== 0) reason = 'a bounded-out step must never park as though it succeeded';
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K1071 notice: a STEP_SLOW advisory is logged and PARTITIONED OUT — step indices must not shift" "
$PREAMBLE
// STEP_SLOW rides ALONGSIDE a real result, so if it were left in the results
// array every later step's index would shift by one and the driver would branch
// on the wrong object (here: 'scan' would read the notice and escalate
// scan-error). The item parking green IS the assertion.
const logged = [];
globalThis.log = (m) => logged.push(String(m));
globalThis.agent = async (prompt, opts = {}) => {
  const label = opts.label || '';
  if (isWorkerCall(opts)) return { status: 'done', summary: 's', acceptance_results: [], commits: [] };
  if (label.startsWith('prelude:')) return { results: [{ outcome: 'CREATED', path: '/tmp/repo.wt/sl' }] };
  if (label.startsWith('review-diff:')) return { outcome: 'REVIEW_DIFF', files: [] };
  if (label.startsWith('gate-freshness:')) return { outcome: 'FRESHNESS_CURRENT', worktree_base: 'x', main: 'y' };
  if (label.startsWith('gate:')) return { outcome: 'GATE_PASS' };
  if (label.startsWith('pr-batch:')) return { results: [
    { outcome: 'REBASED', sha: 'abcdef' },
    { outcome: 'STEP_SLOW', step: 'rebase', elapsed_secs: 420, slow_secs: 300, ceiling_secs: 900 },
    { outcome: 'SCAN_CLEAN' },
    { outcome: 'PUSHED', sha: 'abcdef' },
    { outcome: 'PR_OPENED', pr_number: 77 },
  ] };
  if (label.startsWith('ci-batch:')) return { results: [{ mergeable: 'MERGEABLE', mergeStateStatus: 'CLEAN' }, { outcome: 'CI_GREEN' }] };
  return null;
};
globalThis.args = { ...baseArgs, items: [{ slug: 'sl', branch: 'b/sl', title: 'T', kind: 'impl', acceptance: ['c'] }] };
const mod = await loadLevel();
const result = await mod.default();
let reason = null;
if ((result.escalations ?? []).length !== 0) reason = 'the advisory leaked into the results array and shifted the step indices: ' + JSON.stringify(result.escalations);
else if ((result.parked ?? [])[0]?.pr !== 77) reason = 'expected a clean park on PR 77: ' + JSON.stringify(result);
else if (!logged.some(m => /machinery step 'rebase' took 420s/.test(m))) reason = 'the slow step must emit an observable log() progress notice; logged: ' + JSON.stringify(logged);
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K1071 setting: input.machineryStepCeilingSecs drives the ceiling and is floored, never below one slice" "
$PREAMBLE
// The ceiling reaches the emitted command text (it is a SHELL variable there —
// this runtime has no Date.now() to measure with), and a too-small operator
// value is floored rather than honoured: a ceiling under one legitimate slice
// would manufacture false timeouts on healthy work, which is worse than the
// stall it bounds.
const seen = [];
globalThis.agent = async (prompt, opts = {}) => {
  seen.push({ label: opts.label, prompt: String(prompt) });
  if (isWorkerCall(opts)) return { status: 'done', summary: 's', acceptance_results: [], commits: [] };
  const l = opts.label || '';
  if (l.startsWith('prelude:')) return { results: [{ outcome: 'CREATED', path: '/tmp/repo.wt/c' }] };
  if (l.startsWith('review-diff:')) return { outcome: 'REVIEW_DIFF', files: [] };
  if (l.startsWith('gate-freshness:')) return { outcome: 'FRESHNESS_CURRENT', worktree_base: 'x', main: 'y' };
  if (l.startsWith('gate:')) return { outcome: 'GATE_PASS' };
  if (l.startsWith('pr-batch:')) return { results: [{ outcome: 'REBASED', sha: 'abcdef' }, { outcome: 'SCAN_CLEAN' }, { outcome: 'PUSHED', sha: 'abcdef' }, { outcome: 'PR_OPENED', pr_number: 9 }] };
  if (l.startsWith('ci-batch:')) return { results: [{ mergeable: 'MERGEABLE', mergeStateStatus: 'CLEAN' }, { outcome: 'CI_GREEN' }] };
  return null;
};
globalThis.args = { ...baseArgs, machineryStepCeilingSecs: 4321, items: [{ slug: 'c', branch: 'b/c', title: 'T', kind: 'impl', acceptance: ['c'] }] };
const mod = await loadLevel();
await mod.default();
const prb = seen.find(c => (c.label || '').startsWith('pr-batch:'));
let reason = null;
if (!prb) reason = 'no pr-batch call';
else if (!/__lb_ceil=4321\b/.test(prb.prompt)) reason = 'the orchestrator-supplied ceiling did not reach the emitted command text';
else if (!/__lb\(\) \{/.test(prb.prompt)) reason = 'the emitted command carries no watchdog at all';
else {
  // Second load: a 1-second ceiling must be FLOORED, not honoured.
  seen.length = 0;
  globalThis.args = { ...baseArgs, machineryStepCeilingSecs: 1, items: [{ slug: 'c', branch: 'b/c', title: 'T', kind: 'impl', acceptance: ['c'] }] };
  const mod2 = await loadLevel();
  await mod2.default();
  const prb2 = seen.find(c => (c.label || '').startsWith('pr-batch:'));
  const m = /__lb_ceil=([0-9]+)/.exec(prb2 ? prb2.prompt : '');
  if (!m) reason = 'no ceiling in the second run';
  else if (Number(m[1]) < 300) reason = 'a 1s operator ceiling was honoured instead of floored (got ' + m[1] + 's) — that manufactures false timeouts';
}
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

# --- K1071 EMITTED-SHELL behavioural probe -------------------------------------
# The bound is enforced by shell the .mjs GENERATES, so asserting on the .mjs
# alone would prove nothing about whether it actually bounds anything. Generate
# the real preamble from the real source and RUN it.
_lb_gen="$WF_TEST_TMPDIR/lb-gen.mjs"
cat > "$_lb_gen" <<'LBGEN'
import { readFileSync, writeFileSync } from 'fs';
globalThis.args = JSON.stringify({ repoRoot: '/tmp/repo', ownerRepo: 'o/r', items: [] });
globalThis.agent = async () => null;
globalThis.log = () => {};
globalThis.phase = () => {};
globalThis.parallel = async (fns) => Promise.all(fns.map(f => f()));
const src = readFileSync(process.env.MJS_PATH, 'utf8')
  .replace(/^export const meta/m, 'const meta')
  .replace('const GATE_MAX_SLICES = 8;',
    'const GATE_MAX_SLICES = 8;\nglobalThis.__p = { pre: stepBoundPreamble, def: stepFnDef, inv: stepBoundInvoke, batch: batchCommand };');
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
await new AsyncFunction(src)();
const P = globalThis.__p;
const out = process.env.LB_OUT;
// A step that BLOCKS forever, under a 2s ceiling (the preamble's own ceiling is
// rewritten below — the point is the watchdog's behaviour, not its budget).
writeFileSync(out + '/stall.sh', [P.pre(0), P.def('__s0', "sleep 60; printf '{\"outcome\":\"PUSHED\"}\\n'"), P.inv('__s0', 'push')].join('\n'));
// A fast step: must NOT be delayed by the watchdog (the #861 pipe-leak trap).
writeFileSync(out + '/fast.sh', [P.pre(0), P.def('__s0', "printf '{\"outcome\":\"PUSHED\",\"sha\":\"abc\"}\\n'"), P.inv('__s0', 'push')].join('\n'));
// A batch whose SECOND step stalls: the third step must never run.
writeFileSync(out + '/batch.sh', P.batch([
  { kind: 'scan', cmd: "printf '{\"outcome\":\"SCAN_CLEAN\"}\\n'", continueOutcomes: ['SCAN_CLEAN'] },
  { kind: 'push', cmd: "sleep 60; printf '{\"outcome\":\"PUSHED\"}\\n'", continueOutcomes: ['PUSHED'] },
  { kind: 'pr-open', cmd: "printf '{\"outcome\":\"PR_OPENED\",\"pr_number\":7}\\n'" },
]));
LBGEN
_lb_out="$WF_TEST_TMPDIR/lb"; mkdir -p "$_lb_out"
MJS_PATH="$MJS" LB_OUT="$_lb_out" node "$_lb_gen" \
  || fail "#1071: could not generate the emitted watchdog shell from build-level.mjs"
# Ceilings are rewritten PER PROBE, and the two numbers differ on purpose
# (temperloop#1367):
#   • the two STALL probes get a 2s ceiling, which their 60s stall body outruns
#     by 30x — the stall's verdict is read off the bound's OWN payload below, so
#     the ceiling only has to be small enough to keep the probe quick.
#   • the FAST probe gets a deliberately LARGE ceiling. The #861 pipe leak's
#     signature is that a healthy step's capture stalls for the WHOLE ceiling, so
#     the ceiling IS the separation between the passing and failing cases: at 2s
#     those two were one scheduling hiccup apart on a loaded runner. 30s against
#     the 10s assertion below leaves a healthy step ~10x of headroom while a leak
#     still misses by 3x — a wider gap, not a looser bound.
for _f in stall.sh batch.sh; do
  sed 's/^__lb_ceil=[0-9]*/__lb_ceil=2/' "$_lb_out/$_f" > "$_lb_out/t-$_f"
done
sed 's/^__lb_ceil=[0-9]*/__lb_ceil=30/' "$_lb_out/fast.sh" > "$_lb_out/t-fast.sh"
for _f in stall.sh fast.sh batch.sh; do
  bash -n "$_lb_out/t-$_f" || fail "#1071: the emitted watchdog shell is not valid bash ($_f)"
done

# NB the `|| _lb_stall_rc=$?` capture: a bounded-out step exits 137 BY CONTRACT
# (the watchdog SIGKILLs it), and this suite runs under `set -e` — without the
# guard the suite itself would die with the very exit code the feature is
# supposed to produce. The status is KEPT rather than discarded (temperloop#1335)
# because 137 is the other half of the bound's structured result: the payload
# says the watchdog decided to time the step out, the status says the step
# actually died on SIGKILL. Both are read off the run itself; neither is a
# wall-clock comparison this harness performs.
#
# NB the stall probe is read from a FILE, never a `$( … )` capture, and its
# verdict is the bound's OWN payload rather than this harness's wall clock
# (temperloop#1367). What the bound promises is that the WORKFLOW stops waiting
# on a stalled step at the ceiling; it explicitly does NOT promise that every
# descendant dies with it — the kill is best-effort DEEP, and a deeper grandchild
# that outlives it is disposed through the recover-probe instead (see
# stepBoundPreamble's own header in build-level.mjs). A command substitution
# reads until EOF, so ONE surviving grandchild holding the inherited pipe
# write-end makes the harness wait out the entire 60s stall even though the step
# was killed on time — which is exactly what a loaded 4-worker CI runner produced
# (60s observed, while the bound had reported STEP_TIMEOUT at elapsed_secs=2).
# Reading `elapsed_secs` — the field the driver itself consumes — measures the
# bound; timing the capture measures a descendant's lifetime.
_lb_stall_rc=0
bash "$_lb_out/t-stall.sh" >"$_lb_out/stall.out" 2>/dev/null || _lb_stall_rc=$?
_lb_stall="$(cat "$_lb_out/stall.out")"
[ "$_lb_stall_rc" -eq 137 ] \
  || fail "#1071: a bounded-out step must exit 137 (128+SIGKILL) — the KILL half of the bound's result — got $_lb_stall_rc with output: $_lb_stall"
case "$_lb_stall" in
  *'"outcome":"STEP_TIMEOUT"'*) : ;;
  *) fail "#1071: a bounded-out step must report STEP_TIMEOUT, got: $_lb_stall" ;;
esac
case "$_lb_stall" in
  *'"outcome":"PUSHED"'*) fail "#1071: the killed step still printed a result the driver would have believed: $_lb_stall" ;;
esac
case "$_lb_stall" in
  *'"ceiling_secs":2'*) : ;;
  *) fail "#1071: the STEP_TIMEOUT payload must name the ceiling it enforced, got: $_lb_stall" ;;
esac
_lb_bounded_at="$(printf '%s' "$_lb_stall" | sed -n 's/.*"elapsed_secs":\([0-9][0-9]*\).*/\1/p')"
[ -n "$_lb_bounded_at" ] \
  || fail "#1071: the STEP_TIMEOUT payload carries no elapsed_secs — that field IS the bound's observable: $_lb_stall"
[ "$_lb_bounded_at" -ge 2 ] \
  || fail "#1071: a STEP_TIMEOUT reporting elapsed_secs=${_lb_bounded_at} below its own 2s ceiling is not a timeout: $_lb_stall"
[ "$_lb_bounded_at" -lt 20 ] \
  || fail "#1071: a stalled step was NOT bounded at its ceiling — the watchdog let it run ${_lb_bounded_at}s against a 2s ceiling (this is the 9h49m bug)"
echo "PASS: K1071 emitted shell: a stalled step is killed at the ceiling and reports STEP_TIMEOUT, not a result"

# --- K1071 DISCRIMINATION CONTROL (temperloop#1335) ---------------------------
# The cheap way to stop a timing test flaking is to loosen it until it cannot
# fail — which disarms the guard while leaving every PASS line in place. So the
# assertions above ship with their own negative control: the SAME emitted shell,
# on the SAME 60s stall body, under the SAME 2s ceiling, with ONLY the watchdog
# removed. If that arm also came out STEP_TIMEOUT/137, the assertions above were
# proving something other than the bound.
#
# The watchdog is removed by rewriting the one line that IS the watchdog — the
# `( sleep "$__lb_ceil" … kill -9 … ) &` subshell — into an inert `( : ) &`. The
# rewrite is verified two ways before the arm runs (the line is gone AND the file
# actually changed), because a sed that silently matched nothing would turn this
# control into a second copy of the live arm and quietly report a fake PASS.
#
# Only the WATCHDOG differs between the two arms; the body is held constant, so
# the control cannot be explained away by a shorter stall. Its own bound is
# external — run_with_timeout, the repo's shared portable watchdog — set to 6s,
# 3x the ceiling being tested, so the verdict does not depend on host load: it
# reads "still running at 3x its own ceiling", not "took longer than N".
#
# KNOWN, DELIBERATE, BACKEND-DEPENDENT residue: on run_with_timeout's third-tier
# dependency-free bash fallback (a stock macOS with neither `timeout` nor
# `gtimeout`), this arm leaves its stall body's `sleep` running for the remainder
# of the 60s. That tier `kill -9`s only its DIRECT child, and killing the
# grandchildren under it is precisely the watchdog this arm exists to remove. The
# `timeout`/`gtimeout` tiers do NOT leak: GNU timeout runs the child in its own
# process group and signals the group, so the grandchild is reaped with it
# (measured both ways on this host — 1 survivor on the fallback tier, 0 on the
# GNU tier). Either way it is inert: a sleeping process holding no CPU, and this
# arm's output goes to a FILE rather than a `$( … )` capture, so nothing blocks
# on its EOF — the #861 shape needs a pipe. Don't diagnose it as a watchdog
# defect. Three tempting cleanups are rejected on purpose: re-adding any killer
# here would reintroduce the very thing the control removes; a harness-side
# `pkill -f 'sleep 60'` is free to kill an unrelated sleep belonging to a sibling
# gate worker or another session on a shared host, which is strictly worse than
# the orphan; and shortening only the CONTROL's stall body would break the
# body-held-constant property above, the property that makes the difference
# between the two arms attributable to the watchdog alone.
# shellcheck source=workflows/scripts/lib/portable-timeout.sh
. "$REPO_ROOT/workflows/scripts/lib/portable-timeout.sh"
_lb_nowd="$_lb_out/t-stall-nowatchdog.sh"
sed 's|^ *( sleep "\$__lb_ceil".*|  ( : ) </dev/null >/dev/null 2>\&1 \&|' \
  "$_lb_out/t-stall.sh" > "$_lb_nowd"
if grep -q 'sleep "\$__lb_ceil"' "$_lb_nowd"; then
  fail "#1335: the discrimination control still carries the watchdog — its rewrite of stepBoundPreamble's killer subshell did not match, so the control proves nothing"
fi
if cmp -s "$_lb_out/t-stall.sh" "$_lb_nowd"; then
  fail "#1335: the discrimination control is byte-identical to the live arm — the watchdog-removal rewrite matched nothing"
fi
bash -n "$_lb_nowd" || fail "#1335: the watchdog-removed control is not valid bash"
_lb_nowd_rc=0
run_with_timeout 6 bash "$_lb_nowd" >"$_lb_out/nowatchdog.out" 2>/dev/null \
  || _lb_nowd_rc=$?
_lb_nowd_out="$(cat "$_lb_out/nowatchdog.out")"
[ "$_lb_nowd_rc" -eq 137 ] \
  || fail "#1335: with the watchdog removed the step should still have been running at 6s (3x its 2s ceiling); it exited $_lb_nowd_rc instead, so the live arm's kill is not what this case measures: $_lb_nowd_out"
case "$_lb_nowd_out" in
  *'STEP_TIMEOUT'*) fail "#1335: STEP_TIMEOUT was reported with the watchdog REMOVED — the live arm's assertion is not armed and would pass a broken bound: $_lb_nowd_out" ;;
esac
case "$_lb_nowd_out" in
  *'PUSHED'*) fail "#1335: the control's step reported a result inside its window — the stall body no longer outruns the ceiling, so neither arm tests the bound: $_lb_nowd_out" ;;
esac
echo "PASS: K1071 discrimination control: removing ONLY the watchdog leaves the same step unbounded — no STEP_TIMEOUT, no kill, so the assertions above are armed"

# The fast path must be FAST: portable-timeout.sh's #861 pipe-leak (the watchdog's
# `sleep` grandchild holding the caller's `$( … )` pipe open) turns every quick,
# successful step into a full-ceiling stall. Regression-guard it directly — and
# here the `$( … )` capture IS the point, since the caller's pipe is what the leak
# holds open.
_lb_start=$(date +%s)
_lb_fast="$(bash "$_lb_out/t-fast.sh" 2>/dev/null || true)"
_lb_elapsed=$(( $(date +%s) - _lb_start ))
[ "$_lb_elapsed" -lt 10 ] \
  || fail "#1071: a FAST step took ${_lb_elapsed}s under a 30s ceiling — the watchdog is holding the pipe open (#861 pipe-leak regression)"
case "$_lb_fast" in
  '{"outcome":"PUSHED","sha":"abc"}') : ;;
  *) fail "#1071: a healthy step's output must pass through byte-identically, got: $_lb_fast" ;;
esac
echo "PASS: K1071 emitted shell: a healthy step is neither delayed nor altered by the bound"

_lb_batch="$(bash "$_lb_out/t-batch.sh" 2>/dev/null || true)"
case "$_lb_batch" in
  *'"outcome":"PR_OPENED"'*) fail "#1071: DOUBLE-OPEN — pr-open ran after the batch was bounded out at push: $_lb_batch" ;;
esac
case "$_lb_batch" in
  *'"outcome":"STEP_TIMEOUT","step":"push"'*) : ;;
  *) fail "#1071: the batch must stop at the timed-out step and name it, got: $_lb_batch" ;;
esac
echo "PASS: K1071 emitted shell: a bounded-out batch step stops the sequence — no step after it runs"

# --- K1071 static lockstep guards ---------------------------------------------
grep -q 'input.machineryStepCeilingSecs' "$MJS" \
  || fail "#1071: build-level.mjs must read the step ceiling from the orchestrator hand-off (input.machineryStepCeilingSecs), not a bare literal"
grep -q 'function stepBoundPreamble(' "$MJS" \
  || fail "#1071: the emitted-shell watchdog (stepBoundPreamble) is missing — the bound would live only in the Bash tool timeout that already failed to fire"
# The #861 pipe leak's CAUSE, guarded statically (temperloop#1335). The fast-path
# probe above catches the leak by latency, which is the only observable a leak
# HAS — but latency is also the one thing a loaded runner perturbs. This grep
# pins the fix itself: the watchdog subshell must be redirected AT THE SUBSHELL
# BOUNDARY so its `sleep` grandchild never inherits a caller's `$( … )` pipe
# write-end.
#
# The guard is a PAIR of greps, and the pairing is the whole point. The redirect
# string `) </dev/null >/dev/null 2>&1 &` appears TWICE in build-level.mjs: once
# on the emitted watchdog line, and once inside the prose comment above
# stepBoundPreamble() that quotes it verbatim while explaining why it is there.
# A single `grep -qF` on that string is therefore satisfied by the COMMENT, and
# stays green when the redirect is deleted from the emitted line — i.e. it is
# green in exactly the state it exists to catch (found in review of this very
# change; the first cut of this guard had that hole). So: first SELECT the one
# line that opens the watchdog subshell, then require the boundary redirect ON
# THAT LINE. A comment can quote either half, but only the emitted line carries
# both. Anchoring to the subshell opener rather than to a longer incidental
# substring also keeps the guard from going spuriously red if the kill sequence
# INSIDE the subshell is ever reordered — the redirect is what #861 is about.
#
# The trailing `>/dev/null` on the second grep — rather than a `-q` — is the
# temperloop#1050 form scripts/lint-pipe-grep-q.sh enforces: a piped `grep -q`
# exits at the first match and SIGPIPEs the upstream grep, which under pipefail
# reports 141 as a race. Draining to EOF gives the identical exit status with no
# signal. Don't "simplify" it back to `-qF`; the lint will catch it.
grep -F '( sleep "$__lb_ceil"' "$MJS" | grep -F ') </dev/null >/dev/null 2>&1 &' >/dev/null \
  || fail "#1071/#861: the emitted watchdog subshell is no longer redirected at the subshell boundary — its sleep grandchild will hold every caller's capture open for the full ceiling"
grep -q 'async function disposeStepTimeout(' "$MJS" \
  || fail "#1071: disposeStepTimeout() missing — a bounded-out step has no disposal"
grep -q "recover-probe \${sq(wt)}" "$MJS" \
  || fail "#1071: the timeout disposal must reuse the EXISTING pr.sh recover-probe path, not invent a second one"
_cfg1071="$REPO_ROOT/workflows/scripts/build/build.config.sh"
for _s in BUILD_MACHINERY_STEP_CEILING_SECS BUILD_MACHINERY_STEP_SLOW_SECS; do
  grep -q "$_s" "$_cfg1071" \
    || fail "#1071: $_s must be declared in build.config.sh (the named-setting seam)"
  for _md in build sweep fix; do
    grep -q "$_s" "$REPO_ROOT/claude/commands/$_md.md" \
      || fail "#1071: $_md.md Step 0 must resolve $_s (every build-level.mjs caller wires it, not /build alone)"
  done
done
for _md in build sweep fix; do
  grep -q 'machineryStepCeilingSecs' "$REPO_ROOT/claude/commands/$_md.md" \
    || fail "#1071: $_md.md must pass machineryStepCeilingSecs in its build-level.mjs args"
done
echo "PASS: #1071 liveness-bound guard — named settings, emitted watchdog, recover-probe disposal, all three callers wired"

# ============================================================================
# TEMPERLOOP#2003 — the §3e REVIEW-AGENT liveness bound. The sibling of #1071
# one layer up: that bound wraps a machinery STEP in an emitted-shell watchdog,
# but a §3e reviewer is an `agent({agentType})` call with no shell to wrap, so
# it had no bound at all. Observed (run wf_f3b9c160-6ca): four reviewers routed,
# two returned, `shell-reviewer` spawned and never returned, the workflow stopped
# writing its journal for ~41 minutes, and the MANDATORY `workflow-reviewer` for
# that item's claude/commands/*.md diff never launched — so review.mandatory_ok
# was never even evaluated.
#
# The mock's `{__hang: true}` reviewer entry is the failure verbatim: a promise
# that never settles. Without the bound every case below hangs the node process
# forever rather than failing — which is itself the point.
# ============================================================================
run_node_case "K2003 ceiling: an ADVISORY reviewer that never returns is bounded, and the LATER mandatory reviewer still runs" "
$PREAMBLE
const tsv = readFileSync('$REPO_ROOT/workflows/scripts/config/reviewer-routing.tsv', 'utf8');
const logged = [];
globalThis.log = (m) => logged.push(String(m));

setMachinery('hang-adv',
  { outcome: 'CREATED', path: '/tmp/repo.wt/hang-adv' },
  { outcome: 'REVIEW_DIFF', files: ['workflows/scripts/x.sh', 'claude/commands/build.md'], tsv, tsv_rows: tsvRows(tsv), tsv_checksum: tsvChecksum(tsv) },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'ada0' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'ada0', branch: 'build/hang-adv' },
  { outcome: 'PR_OPENED', pr_number: 2003 },
  { outcome: 'CI_GREEN' },
);
happyWorker('hang-adv');
// Route order is [shell-reviewer (the .sh tsv row), workflow-reviewer (the
// mandatory command-doc rule, added last)] — so the hung one is spawned FIRST,
// reproducing the incident's ordering exactly.
setReview('hang-adv', { __hang: true }, 'no findings');

globalThis.args = { ...baseArgs, items: [
  { slug: 'hang-adv', branch: 'build/hang-adv', title: 'Hung advisory reviewer', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
const result = await mod.default();
const parked = (result.parked ?? [])[0];
const spawned = callLog.filter(c => isReviewCall(c.opts)).map(c => c.opts.agentType);
let reason = null;
if ((result.escalations ?? []).length !== 0) reason = 'an advisory timeout must NOT escalate: ' + JSON.stringify(result.escalations);
else if (!parked || parked.pr !== 2003) reason = 'the level must still resolve and park the item: ' + JSON.stringify(result);
else if (spawned.indexOf('workflow-reviewer') === -1) reason = 'the reviewer AFTER the hung one never launched — the observed failure: ' + JSON.stringify(spawned);
else if (!(parked.review || {}).ran.some(r => r.reviewer === 'workflow-reviewer')) reason = 'the later reviewer must still RUN and be tallied: ' + JSON.stringify(parked.review);
else if ((parked.review || {}).mandatory_ok !== true) reason = 'no MANDATORY route timed out, so mandatory_ok must stay true: ' + JSON.stringify(parked.review);
else {
  const skip = (parked.review.skipped || []).find(s => s.reviewer === 'shell-reviewer');
  if (!skip) reason = 'the hung reviewer must appear in the tally as skipped: ' + JSON.stringify(parked.review);
  else if (!/^skipped — shell-reviewer timed out after [0-9]+s /.test(skip.note)) reason = 'the advisory timeout must degrade to the documented timed-out notice (temperloop#2064 split it from the capability-probe \`unavailable\` sense), got: ' + skip.note;
  else if (!/ceiling of 1200s/.test(skip.note)) reason = 'the notice must name the ceiling it breached, got: ' + skip.note;
  else if (skip.timed_out !== true) reason = 'the tally entry must distinguish a timeout from the other skip reasons: ' + JSON.stringify(skip);
  else if ((parked.review.routed_not_run || []).indexOf('shell-reviewer') === -1) reason = 'routed_not_run must name the timed-out reviewer: ' + JSON.stringify(parked.review);
  else if (!logged.some(m => /still running after 300s: shell-reviewer/.test(m))) reason = 'the progress notice must fire at the SLOW threshold, before the ceiling; logged: ' + JSON.stringify(logged);
  else if (!logged.some(m => /ceiling of 1200s reached with shell-reviewer still outstanding/.test(m))) reason = 'the ceiling breach itself must be logged; logged: ' + JSON.stringify(logged);
  else if (reviewWaitLog.length !== 3) reason = 'the wait must be SLICED under the agent Bash cap (300 + 540 + 360), got marks: ' + JSON.stringify(reviewWaitLog.map(w => w.label));
}
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K2003 isolation: one hung reviewer does not take the FANOUT down — every other routed reviewer still resolves and is tallied" "
$PREAMBLE
// The case above proves the reviewer AFTER the hung one still LAUNCHES. This
// one proves the stronger, separate property the ceiling is built on: the other
// routed reviewers still RESOLVE — their verdicts are collected, tallied and
// spliced into the PR body — while one of their siblings is permanently stuck.
// Asserted directly rather than inferred from the concurrent-spawn shape, since
// a future restructure could reintroduce a per-reviewer await and still look
// concurrent at the spawn site.
//
// Three ADVISORY routes, the hang deliberately in the MIDDLE of route order
// (.sh -> shell-reviewer, .mjs -> typescript-reviewer, docs/** -> docs-reviewer):
// a hang that only ever sat first or last would leave 'does a hang block the
// ones BEFORE it from being collected' untested.
const tsv = readFileSync('$REPO_ROOT/workflows/scripts/config/reviewer-routing.tsv', 'utf8');

setMachinery('hang-mid',
  { outcome: 'CREATED', path: '/tmp/repo.wt/hang-mid' },
  { outcome: 'REVIEW_DIFF', files: ['workflows/scripts/x.sh', 'claude/workflows/build-level.mjs', 'docs/guide.md'], tsv, tsv_rows: tsvRows(tsv), tsv_checksum: tsvChecksum(tsv) },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'adb1' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'adb1', branch: 'build/hang-mid' },
  { outcome: 'PR_OPENED', pr_number: 2006 },
  { outcome: 'CI_GREEN' },
);
happyWorker('hang-mid');
setReview('hang-mid', 'SHELL-SIBLING-RESOLVED', { __hang: true }, 'DOCS-SIBLING-RESOLVED');

globalThis.args = { ...baseArgs, items: [
  { slug: 'hang-mid', branch: 'build/hang-mid', title: 'Hung reviewer mid-fanout', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
const result = await mod.default();
const parked = (result.parked ?? [])[0];
const spawned = callLog.filter(c => isReviewCall(c.opts)).map(c => c.opts.agentType);
const prBatch = callLog.find(c => (c.opts.label||'').startsWith('pr-batch:hang-mid'));
let reason = null;
if ((result.escalations ?? []).length !== 0) reason = 'three advisory routes: a hang must not escalate: ' + JSON.stringify(result.escalations);
else if (!parked) reason = 'the level must still resolve: ' + JSON.stringify(result);
else if (JSON.stringify(spawned) !== JSON.stringify(['shell-reviewer', 'typescript-reviewer', 'docs-reviewer'])) reason = 'all three routed reviewers must be spawned, in route order: ' + JSON.stringify(spawned);
else {
  const ran = (parked.review.ran || []).map(r => r.reviewer);
  const notRun = parked.review.routed_not_run || [];
  if (ran.indexOf('shell-reviewer') === -1) reason = 'the sibling spawned BEFORE the hung one must still resolve and be tallied as ran: ' + JSON.stringify(parked.review);
  else if (ran.indexOf('docs-reviewer') === -1) reason = 'the sibling spawned AFTER the hung one must still resolve and be tallied as ran: ' + JSON.stringify(parked.review);
  else if (ran.indexOf('typescript-reviewer') !== -1) reason = 'the HUNG reviewer must not be tallied as ran: ' + JSON.stringify(parked.review);
  else if (JSON.stringify(notRun) !== JSON.stringify(['typescript-reviewer'])) reason = 'exactly the hung reviewer must be routed_not_run: ' + JSON.stringify(notRun);
  else if (parked.review.mandatory_ok !== true) reason = 'no mandatory route here, so mandatory_ok must stay true: ' + JSON.stringify(parked.review);
  else if (!prBatch) reason = 'the item must still reach 3f — no pr-batch call was made';
  else if (prBatch.promptFull.indexOf('SHELL-SIBLING-RESOLVED') === -1) reason = 'the pre-hang sibling VERDICT TEXT must survive into the PR body, not just its name: ' + prBatch.promptFull.slice(0, 600);
  else if (prBatch.promptFull.indexOf('DOCS-SIBLING-RESOLVED') === -1) reason = 'the post-hang sibling VERDICT TEXT must survive into the PR body: ' + prBatch.promptFull.slice(0, 600);
}
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K2003 ceiling: a MANDATORY reviewer that never returns ESCALATES with mandatory_ok EVALUATED, never a silent pass" "
$PREAMBLE
const tsv = readFileSync('$REPO_ROOT/workflows/scripts/config/reviewer-routing.tsv', 'utf8');

setMachinery('hang-mand',
  { outcome: 'CREATED', path: '/tmp/repo.wt/hang-mand' },
  { outcome: 'REVIEW_DIFF', files: ['claude/commands/build.md'], tsv, tsv_rows: tsvRows(tsv), tsv_checksum: tsvChecksum(tsv) },
);
happyWorker('hang-mand');
setReview('hang-mand', { __hang: true });

globalThis.args = { ...baseArgs, items: [
  { slug: 'hang-mand', branch: 'build/hang-mand', title: 'Hung mandatory reviewer', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
const result = await mod.default();
const esc = (result.escalations ?? [])[0];
let reason = null;
if (!esc) reason = 'a mandatory-reviewer timeout must ESCALATE, got: ' + JSON.stringify(result);
else if (esc.kind !== 'review-agent-timeout') reason = 'wrong escalation kind: ' + esc.kind;
else if ((esc.payload.mandatory || []).indexOf('workflow-reviewer') === -1) reason = 'the payload must name the mandatory reviewer that timed out: ' + JSON.stringify(esc.payload);
else if ((esc.payload.review || {}).mandatory_ok !== false) reason = 'mandatory_ok must be EVALUATED and false — being left unevaluated is what made the incident invisible: ' + JSON.stringify(esc.payload.review);
else if (esc.payload.ceiling_secs !== 1200) reason = 'the payload must name the ceiling: ' + JSON.stringify(esc.payload);
else if (stepsRun('hang-mand').indexOf('push') !== -1) reason = 'the item must NOT be pushed when its mandatory gate never ran: ' + JSON.stringify(stepsRun('hang-mand'));
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K2003 setting: input.reviewAgentCeilingSecs drives the ceiling and is FLOORED, never below one slice" "
$PREAMBLE
const tsv = readFileSync('$REPO_ROOT/workflows/scripts/config/reviewer-routing.tsv', 'utf8');

setMachinery('floor-item',
  { outcome: 'CREATED', path: '/tmp/repo.wt/floor-item' },
  { outcome: 'REVIEW_DIFF', files: ['workflows/scripts/x.sh'], tsv, tsv_rows: tsvRows(tsv), tsv_checksum: tsvChecksum(tsv) },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'f100' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'f100', branch: 'build/floor-item' },
  { outcome: 'PR_OPENED', pr_number: 2004 },
  { outcome: 'CI_GREEN' },
);
happyWorker('floor-item');
setReview('floor-item', { __hang: true });

// A 1-second operator ceiling would manufacture a false timeout on every
// healthy review — strictly worse than the stall it bounds. It must be floored
// to one CI-poll/gate slice.
globalThis.args = { ...baseArgs, reviewAgentCeilingSecs: 1, items: [
  { slug: 'floor-item', branch: 'build/floor-item', title: 'Floored ceiling', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
const result = await mod.default();
const parked = (result.parked ?? [])[0];
let reason = null;
if (!parked) reason = 'expected a parked item: ' + JSON.stringify(result);
else {
  const skip = (parked.review.skipped || [])[0];
  if (!skip) reason = 'expected the hung reviewer in the tally: ' + JSON.stringify(parked.review);
  else if (/ceiling of 1s/.test(skip.note)) reason = 'a 1s operator ceiling was HONOURED instead of floored: ' + skip.note;
  else if (!/ceiling of 300s/.test(skip.note)) reason = 'expected the floored ceiling (one gate slice), got: ' + skip.note;
}
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K2003 fail-open: a timer that cannot run falls back to the pre-#2003 wait, never an instant false breach" "
$PREAMBLE
const tsv = readFileSync('$REPO_ROOT/workflows/scripts/config/reviewer-routing.tsv', 'utf8');
const logged = [];
globalThis.log = (m) => logged.push(String(m));

setMachinery('failopen',
  { outcome: 'CREATED', path: '/tmp/repo.wt/failopen' },
  { outcome: 'REVIEW_DIFF', files: ['workflows/scripts/x.sh'], tsv, tsv_rows: tsvRows(tsv), tsv_checksum: tsvChecksum(tsv) },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'f0be' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'f0be', branch: 'build/failopen' },
  { outcome: 'PR_OPENED', pr_number: 2005 },
  { outcome: 'CI_GREEN' },
);
happyWorker('failopen');
// The reviewer is SLOW (it settles only after a few microtask ticks — more than
// the pre-timer drain allows), so the timer is genuinely reached; the timer
// itself is then DENIED. A bound that treated a non-elapsed timer as an elapsed
// one would report an instant, false ceiling breach on a review that is fine.
let slow = Promise.resolve();
for (let i = 0; i < 40; i++) slow = slow.then(() => undefined);
setReview('failopen', slow.then(() => 'no findings'));
setReviewWait('failopen', null);

globalThis.args = { ...baseArgs, items: [
  { slug: 'failopen', branch: 'build/failopen', title: 'Timer denied', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
const result = await mod.default();
const parked = (result.parked ?? [])[0];
let reason = null;
if (!parked) reason = 'expected a parked item: ' + JSON.stringify(result);
else if ((parked.review.skipped || []).some(s => s.timed_out)) reason = 'a denied timer must NEVER be read as a ceiling breach: ' + JSON.stringify(parked.review);
else if (!parked.review.ran.some(r => r.reviewer === 'shell-reviewer')) reason = 'the reviewer ran — it must be tallied as ran: ' + JSON.stringify(parked.review);
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K2003 discrimination control: with the bound removed, the SAME hung reviewer never resolves — so the cases above are armed" "
$PREAMBLE
// The three K2003 cases above assert that a hung reviewer produces a BOUNDED
// outcome. That proves nothing unless the unbounded case genuinely does not —
// so this control loads the SAME .mjs with awaitReviewFanout()'s body replaced
// by the pre-#2003 unbounded await, feeds it the identical hung reviewer, and
// requires the level NOT to resolve. (A plain Node test HAS a timer to race
// against; the Workflow runtime, which does not, is exactly why the production
// bound races a sleep executor instead.)
const tsv = readFileSync('$REPO_ROOT/workflows/scripts/config/reviewer-routing.tsv', 'utf8');
const MARKER = 'async function awaitReviewFanout(item, slots) {';
if (MJS_SRC.indexOf(MARKER) === -1) {
  console.log(JSON.stringify({ ok: false, reason: 'awaitReviewFanout() not found — this control is no longer testing what it claims' }));
} else {
  const unbounded = MJS_SRC.replace(MARKER, MARKER + '\n  await Promise.all(slots.map((s) => s.promise)); return;');
  const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
  const fn = new AsyncFunction(unbounded);

  setMachinery('control-item',
    { outcome: 'CREATED', path: '/tmp/repo.wt/control-item' },
    { outcome: 'REVIEW_DIFF', files: ['workflows/scripts/x.sh'], tsv, tsv_rows: tsvRows(tsv), tsv_checksum: tsvChecksum(tsv) },
  );
  happyWorker('control-item');
  setReview('control-item', { __hang: true });
  globalThis.args = JSON.stringify({ ...baseArgs, items: [
    { slug: 'control-item', branch: 'build/control-item', title: 'Control', kind: 'impl', acceptance: ['c'] },
  ]});
  const raced = await Promise.race([
    fn().then(() => 'RESOLVED'),
    new Promise((r) => setTimeout(() => r('STILL-HUNG'), 3000)),
  ]);
  const reason = raced === 'STILL-HUNG' ? null
    : 'the unbounded build resolved anyway (' + raced + ') — the hung-reviewer fixture is not actually hanging, so the K2003 assertions prove nothing';
  console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
  process.exit(0);
}
"

# --- K2003 static lockstep guards ---------------------------------------------
grep -q 'input.reviewAgentCeilingSecs' "$MJS" \
  || fail "#2003: build-level.mjs must read the review ceiling from the orchestrator hand-off (input.reviewAgentCeilingSecs), not a bare literal"
grep -q 'async function awaitReviewFanout(' "$MJS" \
  || fail "#2003: awaitReviewFanout() missing — the §3e fanout would be awaited unbounded again, which is the whole defect"
grep -q "escalate(item.slug, 'review-agent-timeout'" "$MJS" \
  || fail "#2003: a MANDATORY reviewer that times out must ESCALATE, never read as if the gate passed"
_cfg2003="$REPO_ROOT/workflows/scripts/build/build.config.sh"
for _s in BUILD_REVIEW_AGENT_CEILING_SECS BUILD_REVIEW_AGENT_SLOW_SECS; do
  grep -q "$_s" "$_cfg2003" \
    || fail "#2003: $_s must be declared in build.config.sh (the named-setting seam)"
  grep -qE "^${_s}[[:space:]]" "$REPO_ROOT/workflows/scripts/config/setting-registry.tsv" \
    || fail "#2003: $_s must carry a setting-registry.tsv row"
  for _md in build sweep fix; do
    grep -q "$_s" "$REPO_ROOT/claude/commands/$_md.md" \
      || fail "#2003: $_md.md Step 0 must resolve $_s (every build-level.mjs caller wires it, not /build alone)"
  done
done
for _md in build sweep fix; do
  grep -q 'reviewAgentCeilingSecs' "$REPO_ROOT/claude/commands/$_md.md" \
    || fail "#2003: $_md.md must pass reviewAgentCeilingSecs in its build-level.mjs args"
done
echo "PASS: #2003 review-agent liveness bound — named settings, bounded fanout, mandatory escalation, all three callers wired"

# ============================================================================
# TEMPERLOOP#2032 — a §3e review result that SETTLES AFTER THE CEILING was
# DISCARDED. #2003's bound is correct and untouched: it bounds the WAIT. The
# defect was one layer later — runReviewers() read `slot.done` exactly once,
# immediately after awaitReviewFanout() returned, so a reviewer that settled a
# moment later was already past the only check there was. Observed (run
# wf_c71d1576-e9d): the ceiling elapsed, then BOTH reviewers returned full
# reviews into the journal, and the tally still reported them
# `skipped — exceeded the §3e review ceiling` with `timed_out: true`, `ran: []`
# — one of the discarded reviews had already found the calendar-validator
# defect a hand-routed reviewer re-found later and PR #2039 fixed.
#
# The three cases below are the three states a reviewer slot can be in at
# disposition time: settled BEFORE the ceiling, settled AFTER it (the bug), and
# never settled (a genuine skip, which must STILL be reported as one).
# ============================================================================
run_node_case "K2032 before the ceiling: a reviewer that returns promptly is consumed and never pays for a timer" "
$PREAMBLE
const tsv = readFileSync('$REPO_ROOT/workflows/scripts/config/reviewer-routing.tsv', 'utf8');

setMachinery('early-settle',
  { outcome: 'CREATED', path: '/tmp/repo.wt/early-settle' },
  { outcome: 'REVIEW_DIFF', files: ['workflows/scripts/x.sh'], tsv, tsv_rows: tsvRows(tsv), tsv_checksum: tsvChecksum(tsv) },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'ea11' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'ea11', branch: 'build/early-settle' },
  { outcome: 'PR_OPENED', pr_number: 2032 },
  { outcome: 'CI_GREEN' },
);
happyWorker('early-settle');
setReview('early-settle', '## Summary\\nclean\\n\\n## Findings\\n(none)\\n');

globalThis.args = { ...baseArgs, items: [
  { slug: 'early-settle', branch: 'build/early-settle', title: 'Prompt reviewer', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
const result = await mod.default();
const parked = (result.parked ?? [])[0];
let reason = null;
if (!parked) reason = 'expected a parked item: ' + JSON.stringify(result);
else if (!parked.review.ran.some(r => r.reviewer === 'shell-reviewer')) reason = 'a reviewer that returned before the ceiling must be tallied ran: ' + JSON.stringify(parked.review);
else if ((parked.review.skipped || []).length !== 0) reason = 'nothing was skipped in this state: ' + JSON.stringify(parked.review);
else if (reviewWaitLog.length !== 0) reason = 'the ceiling timer must not be spawned at all when the fanout is already settled: ' + JSON.stringify(reviewWaitLog);
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K2032 after the ceiling: a review that SETTLES post-ceiling is consumed, never reported as a timeout" "
$PREAMBLE
const tsv = readFileSync('$REPO_ROOT/workflows/scripts/config/reviewer-routing.tsv', 'utf8');
const REVIEW_TEXT = '## Summary\\n1 finding.\\n\\n## Findings\\n### [LOW] Impossible calendar dates pass the date validator\\nreal late finding text.\\n';
let release;
const late = new Promise((r) => { release = r; });
// The window, modelled without a clock (the Workflow runtime has none): the
// release fires from awaitReviewFanout's OWN ceiling-breach log line — the
// ceiling has already given up — and then waits six microtask hops, strictly
// more than the await that hands control back to the disposition read. So the
// result settles AFTER the pass stopped waiting and BEFORE the slot is read,
// which is temperloop#2032 verbatim. (The discrimination control below runs
// this same fixture with the last-chance read neutered and REQUIRES the
// discard, so a fixture that drifted out of this window cannot pass silently.)
globalThis.log = (m) => {
  if (!/wall-clock ceiling of .* reached with/.test(String(m))) return;
  let hop = Promise.resolve();
  for (let i = 0; i < 6; i++) hop = hop.then(() => undefined);
  hop.then(() => release(REVIEW_TEXT));
};

setMachinery('late-settle',
  { outcome: 'CREATED', path: '/tmp/repo.wt/late-settle' },
  { outcome: 'REVIEW_DIFF', files: ['workflows/scripts/x.sh'], tsv, tsv_rows: tsvRows(tsv), tsv_checksum: tsvChecksum(tsv) },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: '1a7e' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: '1a7e', branch: 'build/late-settle' },
  { outcome: 'PR_OPENED', pr_number: 2033 },
  { outcome: 'CI_GREEN' },
);
happyWorker('late-settle');
setReview('late-settle', late);

globalThis.args = { ...baseArgs, items: [
  { slug: 'late-settle', branch: 'build/late-settle', title: 'Late reviewer', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
const result = await mod.default();
const parked = (result.parked ?? [])[0];
const prBatch = callLog.find(c => (c.opts.label||'').startsWith('pr-batch:late-settle'));
let reason = null;
if (!parked) reason = 'expected a parked item: ' + JSON.stringify(result);
else if (reviewWaitLog.length === 0) reason = 'the fixture never reached the ceiling — this case is testing the WRONG state: ' + JSON.stringify(parked.review);
else if ((parked.review.skipped || []).some(s => s.timed_out)) reason = 'the review ARRIVED and was still reported as a ceiling timeout — temperloop#2032 verbatim: ' + JSON.stringify(parked.review);
else if (!parked.review.ran.some(r => r.reviewer === 'shell-reviewer')) reason = 'a settled review must be tallied ran: ' + JSON.stringify(parked.review);
else if ((parked.review.routed_not_run || []).indexOf('shell-reviewer') !== -1) reason = 'routed_not_run must never name a reviewer whose findings were used: ' + JSON.stringify(parked.review);
else if (parked.review.mandatory_ok !== true) reason = 'nothing was skipped, so mandatory_ok must be true: ' + JSON.stringify(parked.review);
else if (!prBatch || !prBatch.promptFull.includes('real late finding text')) reason = 'the recovered FINDINGS text must reach the PR body, not just the tally: ' + String(prBatch && prBatch.promptFull).slice(0, 400);
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K2032 never settles: a reviewer that genuinely never returns is STILL a timed_out skip" "
$PREAMBLE
const tsv = readFileSync('$REPO_ROOT/workflows/scripts/config/reviewer-routing.tsv', 'utf8');

setMachinery('never-settle',
  { outcome: 'CREATED', path: '/tmp/repo.wt/never-settle' },
  { outcome: 'REVIEW_DIFF', files: ['workflows/scripts/x.sh'], tsv, tsv_rows: tsvRows(tsv), tsv_checksum: tsvChecksum(tsv) },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'beef' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'beef', branch: 'build/never-settle' },
  { outcome: 'PR_OPENED', pr_number: 2034 },
  { outcome: 'CI_GREEN' },
);
happyWorker('never-settle');
setReview('never-settle', { __hang: true });

globalThis.args = { ...baseArgs, items: [
  { slug: 'never-settle', branch: 'build/never-settle', title: 'Hung reviewer', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
const result = await mod.default();
const parked = (result.parked ?? [])[0];
let reason = null;
if (!parked) reason = 'expected a parked item: ' + JSON.stringify(result);
else {
  const skip = (parked.review.skipped || []).find(s => s.reviewer === 'shell-reviewer');
  if (!skip) reason = 'a reviewer that never settles must still be reported skipped: ' + JSON.stringify(parked.review);
  else if (skip.timed_out !== true) reason = 'the genuine skip must keep its timed_out reason: ' + JSON.stringify(skip);
  else if (!/§3e review ceiling/.test(skip.note)) reason = 'the skip note must name the ceiling: ' + skip.note;
  else if (parked.review.ran.some(r => r.reviewer === 'shell-reviewer')) reason = 'ran and skipped must stay disjoint: ' + JSON.stringify(parked.review);
  else if ((parked.review.routed_not_run || []).indexOf('shell-reviewer') === -1) reason = 'routed_not_run must name the reviewer that never ran: ' + JSON.stringify(parked.review);
}
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K2032 discrimination control: with the last-chance read neutered, the SAME late review is DISCARDED" "
$PREAMBLE
// Arms the case above. The post-ceiling fixture proves nothing unless the
// pre-#2032 shape genuinely fails it — so this loads the SAME .mjs with
// drainReviewSettlements() turned into a no-op (the single seam the fix adds),
// feeds it the identical late-settling reviewer, and REQUIRES the discard the
// issue reported: skipped, timed_out, ran empty.
const tsv = readFileSync('$REPO_ROOT/workflows/scripts/config/reviewer-routing.tsv', 'utf8');
const MARKER = 'async function drainReviewSettlements(slots) {';
if (MJS_SRC.indexOf(MARKER) === -1) {
  console.log(JSON.stringify({ ok: false, reason: 'drainReviewSettlements() not found — this control is no longer testing what it claims' }));
} else {
  const neutered = MJS_SRC.replace(MARKER, MARKER + '\\n  return;');
  const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
  const fn = new AsyncFunction(neutered);

  const REVIEW_TEXT = '## Summary\\n1 finding.\\n\\n## Findings\\n### [LOW] late\\nreal late finding text.\\n';
  let release;
  const late = new Promise((r) => { release = r; });
  globalThis.log = (m) => {
    if (!/wall-clock ceiling of .* reached with/.test(String(m))) return;
    let hop = Promise.resolve();
    for (let i = 0; i < 6; i++) hop = hop.then(() => undefined);
    hop.then(() => release(REVIEW_TEXT));
  };

  setMachinery('control-late',
    { outcome: 'CREATED', path: '/tmp/repo.wt/control-late' },
    { outcome: 'REVIEW_DIFF', files: ['workflows/scripts/x.sh'], tsv, tsv_rows: tsvRows(tsv), tsv_checksum: tsvChecksum(tsv) },
    { outcome: 'GATE_PASS' },
    { outcome: 'REBASED', base: 'b', tip: 't', sha: 'c07e' },
    { outcome: 'SCAN_CLEAN' },
    { outcome: 'PUSHED', sha: 'c07e', branch: 'build/control-late' },
    { outcome: 'PR_OPENED', pr_number: 2035 },
    { outcome: 'CI_GREEN' },
  );
  happyWorker('control-late');
  setReview('control-late', late);

  globalThis.args = JSON.stringify({ ...baseArgs, items: [
    { slug: 'control-late', branch: 'build/control-late', title: 'Late reviewer, no last-chance read', kind: 'impl', acceptance: ['c'] },
  ]});
  const result = await fn();
  const parked = (result.parked ?? [])[0];
  let reason = null;
  if (!parked) reason = 'expected a parked item: ' + JSON.stringify(result);
  else if (!(parked.review.skipped || []).some(s => s.timed_out)) reason = 'the neutered build kept the late review anyway — the fixture does not settle inside the #2032 window, so the case above proves nothing: ' + JSON.stringify(parked.review);
  else if (parked.review.ran.length !== 0) reason = 'the neutered build must discard the late review entirely: ' + JSON.stringify(parked.review);
  console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
  process.exit(0);
}
"

# --- K2032 static lockstep guards ---------------------------------------------
grep -q 'async function drainReviewSettlements(' "$MJS" \
  || fail "#2032: drainReviewSettlements() missing — the §3e disposition would read slot.done once again and discard a review that settled after the ceiling"
grep -q 'function disposeReviewSlot(' "$MJS" \
  || fail "#2032: disposeReviewSlot() missing — the disposition must be a PURE per-slot descriptor so a straggler can be re-read before its skip is written"
grep -qF 'dispositions[i] ?? (slot.done ? disposeReviewSlot(slot) : null)' "$MJS" \
  || fail "#2032: the ceiling-breach branch must re-read slot.done at the instant the skip is written, not inherit a stale read"
echo "PASS: #2032 late review results — settled-after-the-ceiling reviews are consumed, genuine hangs still skip"

# ============================================================================
# TEMPERLOOP#2049 — the §3e ceiling's TIMER was not waiting. #2003's bound and
# #2032's late-result read are both correct and untouched; the defect was one
# layer below BOTH of them. The tick was a bare inline 'sleep N; printf <json>'
# Bash command, which a harness permission control REFUSES in the machinery
# executor's seat ("Blocked: sleep 300 followed by: printf …") in about a
# millisecond — and the executor's prompt then told it to report the interval
# elapsed anyway. Measured in run wf_ebd4b5e0-3a8's own agent transcripts:
# slices asking 300s/540s/360s returned in 8s/9s/9s, so a nominal 1200s ceiling
# realized in ~30s while the reviewers it bounded completed normally at 177s and
# 257s. Three consecutive items reported `ran: []` with every routed reviewer
# "timed out" — not because anything was slow, but because the ceiling was ~40x
# fast.
#
# The fix is two halves and BOTH are asserted here: the wait now runs inside
# workflows/scripts/build/review-wait.sh (a named helper, the shape ci-poll.sh
# already uses and which the same seat observably honours), and an elapse is
# honoured only when it carries the script's OWN measured `realized_secs`
# reaching the interval — so a tick that did not wait can no longer claim it did.
# ============================================================================

run_node_case "K2049 fabricated elapse: a timer that reports ELAPSED without a REALIZED wait is not honoured — no false ceiling breach" "
$PREAMBLE
const tsv = readFileSync('$REPO_ROOT/workflows/scripts/config/reviewer-routing.tsv', 'utf8');
const logged = [];
globalThis.log = (m) => logged.push(String(m));

setMachinery('fake-elapse',
  { outcome: 'CREATED', path: '/tmp/repo.wt/fake-elapse' },
  { outcome: 'REVIEW_DIFF', files: ['workflows/scripts/x.sh'], tsv, tsv_rows: tsvRows(tsv), tsv_checksum: tsvChecksum(tsv) },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'fa1e' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'fa1e', branch: 'build/fake-elapse' },
  { outcome: 'PR_OPENED', pr_number: 2049 },
  { outcome: 'CI_GREEN' },
);
happyWorker('fake-elapse');
// A reviewer that settles well after the whole ceiling has been walked — the
// harness's stand-in for the healthy 177-257s reviewer that #2049's ~30s
// realized ceiling was throwing away. The SAME hop count is used by the
// discrimination control below, so the two runs differ in exactly one thing:
// whether reviewWaitAgent() audits the elapse.
let slow = Promise.resolve();
for (let i = 0; i < 400; i++) slow = slow.then(() => undefined);
setReview('fake-elapse', slow.then(() => 'no findings'));
// THE #2049 PAYLOAD, verbatim: the shape the refused-command executor actually
// returned — ELAPSED, echoing the interval it was ASKED for, with no measured
// wait behind it.
setReviewWait('fake-elapse', { outcome: 'REVIEW_WAIT_ELAPSED', secs: '300' });

globalThis.args = { ...baseArgs, items: [
  { slug: 'fake-elapse', branch: 'build/fake-elapse', title: 'Timer claimed an elapse it never made', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
const result = await mod.default();
const parked = (result.parked ?? [])[0];
let reason = null;
if (!parked) reason = 'expected a parked item: ' + JSON.stringify(result);
else if ((parked.review.skipped || []).some(s => s.timed_out)) reason = 'a timer that never waited must NEVER read as a ceiling breach — this is temperloop#2049 verbatim: ' + JSON.stringify(parked.review);
else if (!parked.review.ran.some(r => r.reviewer === 'shell-reviewer')) reason = 'the reviewer completed — it must be tallied as ran: ' + JSON.stringify(parked.review);
else if (!logged.some(m => /wall-clock timer is unavailable/.test(m))) reason = 'an unusable timer must DEGRADE LEGIBLY, never silently: ' + JSON.stringify(logged);
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K2049 the bound SURVIVES: with a timer that really waited, a hung reviewer is still a bounded timed_out skip" "
$PREAMBLE
const tsv = readFileSync('$REPO_ROOT/workflows/scripts/config/reviewer-routing.tsv', 'utf8');

setMachinery('real-elapse',
  { outcome: 'CREATED', path: '/tmp/repo.wt/real-elapse' },
  { outcome: 'REVIEW_DIFF', files: ['workflows/scripts/x.sh'], tsv, tsv_rows: tsvRows(tsv), tsv_checksum: tsvChecksum(tsv) },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'dea1' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'dea1', branch: 'build/real-elapse' },
  { outcome: 'PR_OPENED', pr_number: 2050 },
  { outcome: 'CI_GREEN' },
);
happyWorker('real-elapse');
setReview('real-elapse', { __hang: true });
// A TRUTHFUL tick: the script's own measurement reaches every slice the ceiling
// asks for. Deleting the timer would 'fix' #2049's latency by reintroducing the
// #2003 hang; this case is the assertion that it did not.
setReviewWait('real-elapse',
  { outcome: 'REVIEW_WAIT_ELAPSED', secs: 300, realized_secs: 301 },
  { outcome: 'REVIEW_WAIT_ELAPSED', secs: 540, realized_secs: 541 },
  { outcome: 'REVIEW_WAIT_ELAPSED', secs: 360, realized_secs: 361 },
);

globalThis.args = { ...baseArgs, items: [
  { slug: 'real-elapse', branch: 'build/real-elapse', title: 'Hung reviewer, honest timer', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
const result = await mod.default();
const parked = (result.parked ?? [])[0];
let reason = null;
if (!parked) reason = 'expected a parked item: ' + JSON.stringify(result);
else {
  const skip = (parked.review.skipped || []).find(s => s.reviewer === 'shell-reviewer');
  if (!skip) reason = 'a reviewer that never settles must still be reported skipped: ' + JSON.stringify(parked.review);
  else if (skip.timed_out !== true) reason = 'the #2003 bound must survive the #2049 fix — a genuine hang is still timed_out: ' + JSON.stringify(skip);
}
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K2049 discrimination control: with the realized-wait check neutered, the SAME fabricated elapse DOES breach the ceiling" "
$PREAMBLE
// Arms the first case. 'Not honoured' proves nothing unless the pre-#2049 shape
// genuinely IS honoured — so this loads the SAME .mjs with reviewWaitAgent()'s
// realized-wait check removed (the single seam the fix adds), feeds it the
// identical fabricated elapse and the identical healthy reviewer, and REQUIRES
// the outcome the issue reported: skipped, timed_out, ran empty.
const tsv = readFileSync('$REPO_ROOT/workflows/scripts/config/reviewer-routing.tsv', 'utf8');
const MARKER = 'const realized = Number(out.realized_secs);';
if (MJS_SRC.indexOf(MARKER) === -1) {
  console.log(JSON.stringify({ ok: false, reason: 'the realized-wait check was not found — this control is no longer testing what it claims' }));
} else {
  const neutered = MJS_SRC.replace(MARKER, MARKER + \" return 'REVIEW_WAIT_ELAPSED';\");
  const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
  const fn = new AsyncFunction(neutered);

  setMachinery('control-fake',
    { outcome: 'CREATED', path: '/tmp/repo.wt/control-fake' },
    { outcome: 'REVIEW_DIFF', files: ['workflows/scripts/x.sh'], tsv, tsv_rows: tsvRows(tsv), tsv_checksum: tsvChecksum(tsv) },
    { outcome: 'GATE_PASS' },
    { outcome: 'REBASED', base: 'b', tip: 't', sha: 'c0fa' },
    { outcome: 'SCAN_CLEAN' },
    { outcome: 'PUSHED', sha: 'c0fa', branch: 'build/control-fake' },
    { outcome: 'PR_OPENED', pr_number: 2051 },
    { outcome: 'CI_GREEN' },
  );
  happyWorker('control-fake');
  // IDENTICAL fixture to the case above — same hop count, same fabricated tick.
  let slow = Promise.resolve();
  for (let i = 0; i < 400; i++) slow = slow.then(() => undefined);
  setReview('control-fake', slow.then(() => 'no findings'));
  setReviewWait('control-fake', { outcome: 'REVIEW_WAIT_ELAPSED', secs: '300' });

  globalThis.args = JSON.stringify({ ...baseArgs, items: [
    { slug: 'control-fake', branch: 'build/control-fake', title: 'Fabricated elapse, check removed', kind: 'impl', acceptance: ['c'] },
  ]});
  const result = await fn();
  const parked = (result.parked ?? [])[0];
  let reason = null;
  if (!parked) reason = 'expected a parked item: ' + JSON.stringify(result);
  else if (!(parked.review.skipped || []).some(s => s.timed_out)) reason = 'the neutered build did NOT breach the ceiling — the fixture does not reproduce temperloop#2049, so the case above proves nothing: ' + JSON.stringify(parked.review);
  else if (parked.review.ran.length !== 0) reason = 'the neutered build must discard the healthy review entirely, as the run journals show: ' + JSON.stringify(parked.review);
  console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
  process.exit(0);
}
"

# --- K2049 static lockstep guards ---------------------------------------------
_wait_sh="$REPO_ROOT/workflows/scripts/build/review-wait.sh"
[ -f "$_wait_sh" ] \
  || fail "#2049: workflows/scripts/build/review-wait.sh missing — the ceiling's tick would have nothing to run"
[ -x "$_wait_sh" ] \
  || fail "#2049: review-wait.sh must be executable — the executor invokes it by path, not via 'bash'"
grep -qF "machineryBin(input.repoRoot, 'review-wait.sh')" "$MJS" \
  || fail "#2049: the §3e timer must invoke the review-wait.sh helper — an inline 'sleep' command is REFUSED in the machinery executor's seat and the ceiling then fires ~40x early"
if grep -qF 'sleep ${secs};' "$MJS"; then
  fail "#2049: the bare inline 'sleep N; printf' timer command is back — that is the refused shape that made a 1200s ceiling realize in ~30s"
fi
grep -q 'REVIEW_WAIT_UNAVAILABLE' "$MJS" \
  || fail "#2049: the timer must be able to report that it could NOT run — without that outcome a refused command is indistinguishable from an elapsed interval"
grep -qF 'const realized = Number(out.realized_secs);' "$MJS" \
  || fail "#2049: reviewWaitAgent() must CHECK the script's own measured wait — an elapse taken on trust is exactly the defect"
# The helper's own bound must stay the CALLER's (no second, independently
# drifting ceiling) — it validates its argument and waits, nothing more.
grep -q 'REVIEW_WAIT_ELAPSED' "$_wait_sh" \
  || fail "#2049: review-wait.sh must print the REVIEW_WAIT_ELAPSED line the executor relays"
grep -q 'realized_secs' "$_wait_sh" \
  || fail "#2049: review-wait.sh must print its OWN measured realized_secs — that field is what the .mjs audits the elapse against"
echo "PASS: #2049 review-ceiling timer — the wait is real, the elapse is measured, the #2003 bound survives"

# ============================================================================
# TEMPERLOOP#2064 — A BLOCK IS NOT A TIMEOUT. #2049 made the wait REAL and made
# an elapse carry the script's own measurement. One coin flip survived it: when
# the timer command produces NO JSON line, the executor must say WHY, and the
# two reasons it cannot tell apart are "a permission control refused it" and
# "the Bash tool's own timeout killed it mid-run" — of which exactly one, the
# tool timeout, is the PERMISSIVE arm (its budget is secs+60s, so it can only
# fire after the interval). Measured in run wf_1b4c373b-8c1: slices asking
# 300s/540s/360s returned in 11s/11s/17s, so a 1200s ceiling realized in ~41s,
# a docs-reviewer that returned a full clean review at 98s was DISCARDED, and
# the item reported `skipped — docs-reviewer unavailable` — the kernel's
# CAPABILITY-PROBE word (CLAUDE.kernel.md § Subagent usage) for an agent that is
# installed, was spawned, and ran fine. That wording cost a live session ~1200s
# of apparent hang aimed at the agent roster instead of the timer.
#
# Three seams, all asserted below:
#   1. the refusal is classified from the HARNESS'S OWN TEXT before any outcome
#      label is read, so a block the executor mislabelled TOOL_TIMEOUT still
#      fails closed;
#   2. a GENUINE tool timeout is untouched and still reads as elapsed — the fix
#      is a distinction, not a blanket distrust of the permissive arm;
#   3. the ceiling-breach notice says `timed out after <actual>s` and reserves
#      `unavailable` for the capability-probe sense.
# ============================================================================

run_node_case "K2064 blocked-vs-timeout: a refusal MISLABELLED as a tool timeout must NOT read as an elapse" "
$PREAMBLE
const tsv = readFileSync('$REPO_ROOT/workflows/scripts/config/reviewer-routing.tsv', 'utf8');
const logged = [];
globalThis.log = (m) => logged.push(String(m));

setMachinery('blocked-tick',
  { outcome: 'CREATED', path: '/tmp/repo.wt/blocked-tick' },
  { outcome: 'REVIEW_DIFF', files: ['workflows/scripts/x.sh'], tsv, tsv_rows: tsvRows(tsv), tsv_checksum: tsvChecksum(tsv) },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'b10c' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'b10c', branch: 'build/blocked-tick' },
  { outcome: 'PR_OPENED', pr_number: 2064 },
  { outcome: 'CI_GREEN' },
);
happyWorker('blocked-tick');
// The healthy reviewer #2064 measured: it returns well after the whole ceiling
// would have been walked (98s against a ~41s realized ceiling), and its full
// review was thrown away. Same hop count as the discrimination control below,
// so the two runs differ in exactly one thing: whether the refusal is detected.
let slow = Promise.resolve();
for (let i = 0; i < 400; i++) slow = slow.then(() => undefined);
setReview('blocked-tick', slow.then(() => 'no findings'));
// THE #2064 PAYLOAD, verbatim: the harness's refusal, wearing the label the
// executor actually chose for it. Both facts are load-bearing — the label is
// the PERMISSIVE arm, and the text is the only evidence a refusal leaves.
setReviewWait('blocked-tick', {
  outcome: 'REVIEW_WAIT_TOOL_TIMEOUT',
  refusal_text: '<tool_use_error>Blocked: sleep 300 followed by: printf ... To wait for a condition, use Monitor with an until-loop.',
});

globalThis.args = { ...baseArgs, items: [
  { slug: 'blocked-tick', branch: 'build/blocked-tick', title: 'A refused wait wearing a timeout label', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
const result = await mod.default();
const parked = (result.parked ?? [])[0];
let reason = null;
if (!parked) reason = 'expected a parked item: ' + JSON.stringify(result);
else if ((parked.review.skipped || []).some(s => s.timed_out)) reason = 'a REFUSED wait must never read as a ceiling breach — this is temperloop#2064 verbatim: ' + JSON.stringify(parked.review);
else if (!parked.review.ran.some(r => r.reviewer === 'shell-reviewer')) reason = 'the review ARRIVED and must be tallied as ran, never discarded: ' + JSON.stringify(parked.review);
else if (!logged.some(m => /permission control REFUSED the wait command/.test(m))) reason = 'the refusal must degrade LEGIBLY and name itself, not hide behind a generic notice: ' + JSON.stringify(logged);
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K2064 the explicit REVIEW_WAIT_BLOCKED outcome fails closed even with no refusal text to read" "
$PREAMBLE
const tsv = readFileSync('$REPO_ROOT/workflows/scripts/config/reviewer-routing.tsv', 'utf8');

setMachinery('blocked-label',
  { outcome: 'CREATED', path: '/tmp/repo.wt/blocked-label' },
  { outcome: 'REVIEW_DIFF', files: ['workflows/scripts/x.sh'], tsv, tsv_rows: tsvRows(tsv), tsv_checksum: tsvChecksum(tsv) },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'b1ab' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'b1ab', branch: 'build/blocked-label' },
  { outcome: 'PR_OPENED', pr_number: 2065 },
  { outcome: 'CI_GREEN' },
);
happyWorker('blocked-label');
let slow = Promise.resolve();
for (let i = 0; i < 400; i++) slow = slow.then(() => undefined);
setReview('blocked-label', slow.then(() => 'no findings'));
// The executor labelled it correctly but relayed no text. The label alone must
// still fail closed — the text classifier is the belt, this is the braces.
setReviewWait('blocked-label', { outcome: 'REVIEW_WAIT_BLOCKED' });

globalThis.args = { ...baseArgs, items: [
  { slug: 'blocked-label', branch: 'build/blocked-label', title: 'Blocked, labelled, untexted', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
const result = await mod.default();
const parked = (result.parked ?? [])[0];
let reason = null;
if (!parked) reason = 'expected a parked item: ' + JSON.stringify(result);
else if ((parked.review.skipped || []).some(s => s.timed_out)) reason = 'REVIEW_WAIT_BLOCKED must never read as a ceiling breach: ' + JSON.stringify(parked.review);
else if (!parked.review.ran.some(r => r.reviewer === 'shell-reviewer')) reason = 'the review must be kept: ' + JSON.stringify(parked.review);
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K2064 the OTHER half of the distinction: a GENUINE tool timeout still reads as elapsed" "
$PREAMBLE
const tsv = readFileSync('$REPO_ROOT/workflows/scripts/config/reviewer-routing.tsv', 'utf8');

setMachinery('real-tool-timeout',
  { outcome: 'CREATED', path: '/tmp/repo.wt/real-tool-timeout' },
  { outcome: 'REVIEW_DIFF', files: ['workflows/scripts/x.sh'], tsv, tsv_rows: tsvRows(tsv), tsv_checksum: tsvChecksum(tsv) },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: '7007' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: '7007', branch: 'build/real-tool-timeout' },
  { outcome: 'PR_OPENED', pr_number: 2066 },
  { outcome: 'CI_GREEN' },
);
happyWorker('real-tool-timeout');
setReview('real-tool-timeout', { __hang: true });
// No refusal text: the command RAN and the Bash tool's own budget (secs+60s)
// killed it, so the interval did elapse. The #2064 fix must not launder this
// into 'unusable timer' — that would reintroduce the #2003 unbounded hang under
// a new name.
setReviewWait('real-tool-timeout',
  { outcome: 'REVIEW_WAIT_TOOL_TIMEOUT' },
  { outcome: 'REVIEW_WAIT_TOOL_TIMEOUT' },
  { outcome: 'REVIEW_WAIT_TOOL_TIMEOUT' },
);

globalThis.args = { ...baseArgs, items: [
  { slug: 'real-tool-timeout', branch: 'build/real-tool-timeout', title: 'Honest tool timeout, hung reviewer', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
const result = await mod.default();
const parked = (result.parked ?? [])[0];
let reason = null;
if (!parked) reason = 'expected a parked item: ' + JSON.stringify(result);
else {
  const skip = (parked.review.skipped || []).find(s => s.reviewer === 'shell-reviewer');
  if (!skip) reason = 'a reviewer that never settles must still be reported skipped: ' + JSON.stringify(parked.review);
  else if (skip.timed_out !== true) reason = 'a genuine tool timeout still bounds the fanout — the #2003 bound must survive #2064: ' + JSON.stringify(skip);
}
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K2064 the ceiling-breach notice names a TIMEOUT, never the capability-probe word" "
$PREAMBLE
const tsv = readFileSync('$REPO_ROOT/workflows/scripts/config/reviewer-routing.tsv', 'utf8');

setMachinery('timeout-wording',
  { outcome: 'CREATED', path: '/tmp/repo.wt/timeout-wording' },
  { outcome: 'REVIEW_DIFF', files: ['workflows/scripts/x.sh'], tsv, tsv_rows: tsvRows(tsv), tsv_checksum: tsvChecksum(tsv) },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'd00d' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'd00d', branch: 'build/timeout-wording' },
  { outcome: 'PR_OPENED', pr_number: 2067 },
  { outcome: 'CI_GREEN' },
);
happyWorker('timeout-wording');
setReview('timeout-wording', { __hang: true });
// Honest ticks (the mock default carries a huge realized_secs), so the ceiling
// is genuinely walked and the breach notice is genuinely written.

globalThis.args = { ...baseArgs, items: [
  { slug: 'timeout-wording', branch: 'build/timeout-wording', title: 'Ceiling breach wording', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
const result = await mod.default();
const parked = (result.parked ?? [])[0];
let reason = null;
if (!parked) reason = 'expected a parked item: ' + JSON.stringify(result);
else {
  const skip = (parked.review.skipped || []).find(s => s.reviewer === 'shell-reviewer');
  if (!skip) reason = 'expected a ceiling-breach skip: ' + JSON.stringify(parked.review);
  else if (/unavailable/.test(skip.note)) reason = 'a ceiling breach must NOT claim the capability-probe sense — the agent is installed and was spawned (temperloop#2064): ' + skip.note;
  else if (!/timed out after [0-9]+s/.test(skip.note)) reason = 'the notice must report the wall clock actually waited: ' + skip.note;
}
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K2064 discrimination control: with the refusal classifier neutered, the SAME refusal DOES breach the ceiling" "
$PREAMBLE
// Arms the first case. 'Not honoured' proves nothing unless the pre-#2064 shape
// genuinely IS honoured — so this loads the SAME .mjs with the refusal
// classification removed (the single seam the fix adds), feeds it the identical
// mislabelled refusal and the identical healthy reviewer, and REQUIRES the
// outcome run wf_1b4c373b-8c1 reported: skipped, timed_out, ran empty.
const tsv = readFileSync('$REPO_ROOT/workflows/scripts/config/reviewer-routing.tsv', 'utf8');
const MARKER = 'const refusal = reviewWaitRefusalText(out);';
if (MJS_SRC.indexOf(MARKER) === -1) {
  console.log(JSON.stringify({ ok: false, reason: 'the refusal classifier was not found — this control is no longer testing what it claims' }));
} else {
  const neutered = MJS_SRC.replace(MARKER, 'const refusal = null;');
  const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
  const fn = new AsyncFunction(neutered);

  setMachinery('control-blocked',
    { outcome: 'CREATED', path: '/tmp/repo.wt/control-blocked' },
    { outcome: 'REVIEW_DIFF', files: ['workflows/scripts/x.sh'], tsv, tsv_rows: tsvRows(tsv), tsv_checksum: tsvChecksum(tsv) },
    { outcome: 'GATE_PASS' },
    { outcome: 'REBASED', base: 'b', tip: 't', sha: 'c0b1' },
    { outcome: 'SCAN_CLEAN' },
    { outcome: 'PUSHED', sha: 'c0b1', branch: 'build/control-blocked' },
    { outcome: 'PR_OPENED', pr_number: 2068 },
    { outcome: 'CI_GREEN' },
  );
  happyWorker('control-blocked');
  // IDENTICAL fixture to the first case — same hop count, same mislabelled refusal.
  let slow = Promise.resolve();
  for (let i = 0; i < 400; i++) slow = slow.then(() => undefined);
  setReview('control-blocked', slow.then(() => 'no findings'));
  setReviewWait('control-blocked', {
    outcome: 'REVIEW_WAIT_TOOL_TIMEOUT',
    refusal_text: '<tool_use_error>Blocked: sleep 300 followed by: printf ... To wait for a condition, use Monitor with an until-loop.',
  });

  globalThis.args = JSON.stringify({ ...baseArgs, items: [
    { slug: 'control-blocked', branch: 'build/control-blocked', title: 'Refusal, classifier removed', kind: 'impl', acceptance: ['c'] },
  ]});
  const result = await fn();
  const parked = (result.parked ?? [])[0];
  let reason = null;
  if (!parked) reason = 'expected a parked item: ' + JSON.stringify(result);
  else if (!(parked.review.skipped || []).some(s => s.timed_out)) reason = 'the neutered build did NOT breach the ceiling — the fixture does not reproduce temperloop#2064, so the case above proves nothing: ' + JSON.stringify(parked.review);
  else if (parked.review.ran.length !== 0) reason = 'the neutered build must discard the healthy review entirely, as the run journals show: ' + JSON.stringify(parked.review);
  console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
  process.exit(0);
}
"

# --- K2064 static lockstep guards ---------------------------------------------
grep -q 'REVIEW_WAIT_BLOCKED' "$MJS" \
  || fail "#2064: the timer must be able to report that it was REFUSED — without its own outcome a block is indistinguishable from the permissive tool-timeout arm"
grep -q 'REVIEW_WAIT_REFUSAL_RE' "$MJS" \
  || fail "#2064: the refusal classifier is gone — the executor's own label is then the only evidence, which is the coin flip the issue measured"
grep -qF 'const refusal = reviewWaitRefusalText(out);' "$MJS" \
  || fail "#2064: reviewWaitAgent() must classify the harness's own refusal text, not trust the outcome label it was given"
# ORDERING is the mechanism, not a detail: the refusal check must run BEFORE the
# permissive tool-timeout arm, or a mislabelled block reaches it unchanged.
_k2064_refusal_ln="$(grep -n 'const refusal = reviewWaitRefusalText(out);' "$MJS" | head -1 | cut -d: -f1)"
_k2064_toolto_ln="$(grep -n "out.outcome === 'REVIEW_WAIT_TOOL_TIMEOUT'" "$MJS" | head -1 | cut -d: -f1)"
if [ -z "$_k2064_refusal_ln" ] || [ -z "$_k2064_toolto_ln" ] || [ "$_k2064_refusal_ln" -ge "$_k2064_toolto_ln" ]; then
  fail "#2064: the refusal check must precede the permissive REVIEW_WAIT_TOOL_TIMEOUT arm in reviewWaitAgent()"
fi
grep -qF 'skipped — ${route.reviewer} timed out after ${waitedSecs}s' "$MJS" \
  || fail "#2064: the ceiling-breach notice must report the wall clock actually waited, and must not reuse the capability-probe word 'unavailable'"
grep -qF 'waited_secs: waitedSecs' "$MJS" \
  || fail "#2064: the mandatory-timeout escalation must carry the tick actually honoured — a waited_secs far below ceiling_secs IS the timer defect"
echo "PASS: #2064 blocked-vs-elapsed — a refused wait fails closed, a real tool timeout still elapses, the notice names a timeout"

# ============================================================================
# TEMPERLOOP#1067 — probe for a LOST pr-batch return before escalating it as a
# failure. Distinct from #1071 (a liveness-KILL): here every step in the batch
# through the one under test has ALREADY been confirmed successful, and the
# batch's own JSON line for the very next step was simply dropped
# (batchStep()'s 'produced no result' sentinel) — not timed out, not a
# short-circuit. lostReturn() (see the PREAMBLE mock) models exactly that: the
# step's machineryStepLog entry is recorded (it ran) but no results[] entry is
# pushed for it.
#
# The four-rung disposition (the EXISTING probeSideEffects/RECOVER_* ladder,
# not a new one): RECOVER_PR_OPEN → adopt; RECOVER_PUSHED → resume at pr-open;
# RECOVER_COMMITTED → resume at push; RECOVER_NONE → escalate unchanged. Rungs
# are exercised at BOTH the push-error site and the pr-open-failed site. A
# genuine (non-sentinel) failure at either site must escalate immediately with
# NO probe call — the load-bearing negative case.
# ============================================================================

run_node_case "K1067 push/RECOVER_PR_OPEN: a LOST push-batch return whose PR already opened is ADOPTED, never re-pushed/re-opened" "
$PREAMBLE
setMachinery('lost-push-adopt',
  { outcome: 'CREATED', path: '/tmp/repo.wt/lost-push-adopt' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'a39' },
  { outcome: 'SCAN_CLEAN' },
  lostReturn(),
  { outcome: 'RECOVER_PR_OPEN', pr_number: 5001, sha: 'a39', pushed: true, verification_surface_present: true },
  { outcome: 'CI_GREEN' },
);
happyWorker('lost-push-adopt');
globalThis.args = { ...baseArgs, items: [{ slug: 'lost-push-adopt', branch: 'b/lp', title: 'T', kind: 'impl', acceptance: ['c'] }] };
const mod = await loadLevel();
const result = await mod.default();
const parked = result.parked ?? [];
const steps = stepsRun('lost-push-adopt');
let reason = null;
if ((result.escalations ?? []).length !== 0) reason = 'a recoverable lost push return must NOT escalate: ' + JSON.stringify(result.escalations);
else if (parked.length !== 1) reason = 'expected the item to park on the adopted PR: ' + JSON.stringify(result);
else if (parked[0].pr !== 5001) reason = 'must park on the PR recover-probe actually found, got ' + parked[0].pr;
else if (steps.includes('pr-open')) reason = 'DOUBLE-OPEN: pr-open ran even though the probe adopted an existing PR';
else if (steps.filter(s => s === 'push').length !== 1) reason = 'DOUBLE-PUSH: push must run exactly once, got ' + steps.filter(s => s === 'push').length;
else if (!callLog.some(c => c.opts.label === 'recover-probe:lost-push-adopt')) reason = 'must probe via the EXISTING pr.sh recover-probe path';
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K1067 push/RECOVER_PUSHED: resumes at pr-open only, no re-push" "
$PREAMBLE
setMachinery('lost-push-resume-open',
  { outcome: 'CREATED', path: '/tmp/repo.wt/lost-push-resume-open' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'a51' },
  { outcome: 'SCAN_CLEAN' },
  lostReturn(),
  { outcome: 'RECOVER_PUSHED', sha: 'a51', pushed: true, remote_sha: 'a51', verification_surface_present: true },
  { outcome: 'PR_OPENED', pr_number: 5002 },
  { outcome: 'CI_GREEN' },
);
happyWorker('lost-push-resume-open');
globalThis.args = { ...baseArgs, items: [{ slug: 'lost-push-resume-open', branch: 'b/rp', title: 'T', kind: 'impl', acceptance: ['c'] }] };
const mod = await loadLevel();
const result = await mod.default();
const parked = result.parked ?? [];
const steps = stepsRun('lost-push-resume-open');
let reason = null;
if ((result.escalations ?? []).length !== 0) reason = 'RECOVER_PUSHED must resume, not escalate: ' + JSON.stringify(result.escalations);
else if (parked.length !== 1) reason = 'expected the item to park on the resumed PR: ' + JSON.stringify(result);
else if (parked[0].pr !== 5002) reason = 'must park on the PR the resumed pr-open step opened, got ' + parked[0].pr;
else if (parked[0].pushed_sha !== 'a51') reason = 'pushed_sha must come from the probe (already-pushed sha), got ' + parked[0].pushed_sha;
else if (steps.filter(s => s === 'push').length !== 1) reason = 'RECOVER_PUSHED must NOT re-push, got push count ' + steps.filter(s => s === 'push').length;
else if (steps.filter(s => s === 'pr-open').length !== 1) reason = 'must resume at pr-open exactly once, got ' + steps.filter(s => s === 'pr-open').length;
else if (!callLog.some(c => c.opts.label === 'recover-probe:lost-push-resume-open')) reason = 'must probe via the EXISTING pr.sh recover-probe path';
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K1067 push/RECOVER_COMMITTED: resumes at push then pr-open, no re-rebase" "
$PREAMBLE
setMachinery('lost-push-resume-both',
  { outcome: 'CREATED', path: '/tmp/repo.wt/lost-push-resume-both' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'ac4e' },
  { outcome: 'SCAN_CLEAN' },
  lostReturn(),
  { outcome: 'RECOVER_COMMITTED', sha: 'ac4e', pushed: false, verification_surface_present: false },
  { outcome: 'PUSHED', sha: 'ac24f', branch: 'b/rc' },
  { outcome: 'PR_OPENED', pr_number: 5003 },
  { outcome: 'CI_GREEN' },
);
happyWorker('lost-push-resume-both');
globalThis.args = { ...baseArgs, items: [{ slug: 'lost-push-resume-both', branch: 'b/rc', title: 'T', kind: 'impl', acceptance: ['c'] }] };
const mod = await loadLevel();
const result = await mod.default();
const parked = result.parked ?? [];
const steps = stepsRun('lost-push-resume-both');
let reason = null;
if ((result.escalations ?? []).length !== 0) reason = 'RECOVER_COMMITTED must resume, not escalate: ' + JSON.stringify(result.escalations);
else if (parked.length !== 1) reason = 'expected the item to park on the resumed PR: ' + JSON.stringify(result);
else if (parked[0].pr !== 5003) reason = 'must park on the PR the resumed pr-open step opened, got ' + parked[0].pr;
else if (parked[0].pushed_sha !== 'ac24f') reason = 'pushed_sha must come from the RESUMED push (fresh ground truth), got ' + parked[0].pushed_sha;
else if (steps.filter(s => s === 'rebase').length !== 1) reason = 'RECOVER_COMMITTED must NOT re-rebase, got rebase count ' + steps.filter(s => s === 'rebase').length;
else if (steps.filter(s => s === 'push').length !== 2) reason = 'must resume at push (original lost attempt + one resumed push), got ' + steps.filter(s => s === 'push').length;
else if (steps.filter(s => s === 'pr-open').length !== 1) reason = 'must open exactly once via the resume batch, got ' + steps.filter(s => s === 'pr-open').length;
else if (!callLog.some(c => c.opts.label === 'recover-probe:lost-push-resume-both')) reason = 'must probe via the EXISTING pr.sh recover-probe path';
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K1067 push/RECOVER_NONE: a lost push return with nothing landed escalates push-error, unchanged" "
$PREAMBLE
setMachinery('lost-push-none',
  { outcome: 'CREATED', path: '/tmp/repo.wt/lost-push-none' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'a37' },
  { outcome: 'SCAN_CLEAN' },
  lostReturn(),
  noSideEffects(),
);
happyWorker('lost-push-none');
globalThis.args = { ...baseArgs, items: [{ slug: 'lost-push-none', branch: 'b/ln', title: 'T', kind: 'impl', acceptance: ['c'] }] };
const mod = await loadLevel();
const result = await mod.default();
const escalations = result.escalations ?? [];
let reason = null;
if ((result.parked ?? []).length !== 0) reason = 'RECOVER_NONE must not park: ' + JSON.stringify(result.parked);
else if (escalations.length !== 1) reason = 'expected exactly 1 escalation, got ' + JSON.stringify(escalations);
else if (escalations[0].kind !== 'push-error') reason = 'wrong escalation kind: ' + escalations[0].kind;
else if (!callLog.some(c => c.opts.label === 'recover-probe:lost-push-none')) reason = 'RECOVER_NONE must still have been reached via the EXISTING recover-probe path';
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K1067 push negative: a GENUINE push failure (not a lost return) escalates immediately with NO probe call" "
$PREAMBLE
setMachinery('genuine-push-fail',
  { outcome: 'CREATED', path: '/tmp/repo.wt/genuine-push-fail' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'a27' },
  { outcome: 'SCAN_CLEAN' },
  // A REAL pr.sh die() — a genuine failure, NOT the batchStep sentinel.
  { outcome: 'ERROR', error: 'git push: remote end hung up unexpectedly' },
);
happyWorker('genuine-push-fail');
globalThis.args = { ...baseArgs, items: [{ slug: 'genuine-push-fail', branch: 'b/gp', title: 'T', kind: 'impl', acceptance: ['c'] }] };
const mod = await loadLevel();
const result = await mod.default();
const escalations = result.escalations ?? [];
let reason = null;
if ((result.parked ?? []).length !== 0) reason = 'a genuine push failure must not park: ' + JSON.stringify(result.parked);
else if (escalations.length !== 1) reason = 'expected exactly 1 escalation, got ' + JSON.stringify(escalations);
else if (escalations[0].kind !== 'push-error') reason = 'wrong escalation kind: ' + escalations[0].kind;
else if (callLog.some(c => c.opts.label === 'recover-probe:genuine-push-fail')) reason = 'a GENUINE failure must NEVER be routed through recover-probe — this would silently convert it into a possible adoption';
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K1067 pr-open/RECOVER_PR_OPEN: a LOST pr-open-batch return whose PR already opened is ADOPTED, never re-opened" "
$PREAMBLE
setMachinery('lost-open-adopt',
  { outcome: 'CREATED', path: '/tmp/repo.wt/lost-open-adopt' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'a38' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'a38', branch: 'b/lo' },
  lostReturn(),
  { outcome: 'RECOVER_PR_OPEN', pr_number: 5004, sha: 'a38', pushed: true, verification_surface_present: true },
  { outcome: 'CI_GREEN' },
);
happyWorker('lost-open-adopt');
globalThis.args = { ...baseArgs, items: [{ slug: 'lost-open-adopt', branch: 'b/lo', title: 'T', kind: 'impl', acceptance: ['c'] }] };
const mod = await loadLevel();
const result = await mod.default();
const parked = result.parked ?? [];
const steps = stepsRun('lost-open-adopt');
let reason = null;
if ((result.escalations ?? []).length !== 0) reason = 'a recoverable lost pr-open return must NOT escalate: ' + JSON.stringify(result.escalations);
else if (parked.length !== 1) reason = 'expected the item to park on the adopted PR: ' + JSON.stringify(result);
else if (parked[0].pr !== 5004) reason = 'must park on the PR recover-probe actually found, got ' + parked[0].pr;
else if (steps.filter(s => s === 'pr-open').length !== 1) reason = 'DOUBLE-OPEN: pr-open must run exactly once (the lost original attempt), got ' + steps.filter(s => s === 'pr-open').length;
else if (steps.filter(s => s === 'push').length !== 1) reason = 'DOUBLE-PUSH: push must run exactly once, got ' + steps.filter(s => s === 'push').length;
else if (!callLog.some(c => c.opts.label === 'recover-probe:lost-open-adopt')) reason = 'must probe via the EXISTING pr.sh recover-probe path';
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K1067 pr-open negative: a GENUINE pr-open failure (not a lost return) escalates immediately with NO probe call" "
$PREAMBLE
setMachinery('genuine-open-fail',
  { outcome: 'CREATED', path: '/tmp/repo.wt/genuine-open-fail' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'a25' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'a25', branch: 'b/go' },
  // A REAL pr.sh die() — a genuine failure, NOT the batchStep sentinel.
  { outcome: 'ERROR', error: 'authentication required' },
);
happyWorker('genuine-open-fail');
globalThis.args = { ...baseArgs, items: [{ slug: 'genuine-open-fail', branch: 'b/go', title: 'T', kind: 'impl', acceptance: ['c'] }] };
const mod = await loadLevel();
const result = await mod.default();
const escalations = result.escalations ?? [];
let reason = null;
if ((result.parked ?? []).length !== 0) reason = 'a genuine pr-open failure must not park: ' + JSON.stringify(result.parked);
else if (escalations.length !== 1) reason = 'expected exactly 1 escalation, got ' + JSON.stringify(escalations);
else if (escalations[0].kind !== 'pr-open-failed') reason = 'wrong escalation kind: ' + escalations[0].kind;
else if (callLog.some(c => c.opts.label === 'recover-probe:genuine-open-fail')) reason = 'a GENUINE failure must NEVER be routed through recover-probe — this would silently convert it into a possible adoption';
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

# --- K1067 static lockstep guards -----------------------------------------
grep -q 'lost pr-batch return' "$MJS" \
  || fail "#1067: build-level.mjs must carry the literal phrase 'lost pr-batch return' so the intent is greppable"
grep -q 'async function recoverLostReturn(' "$MJS" \
  || fail "#1067: recoverLostReturn() missing — the push-error/pr-open-failed sites have no lost-return disposal"
grep -q 'function isLostReturn(' "$MJS" \
  || fail "#1067: isLostReturn() missing — the sentinel-vs-genuine-failure distinction must be a named, testable predicate"
[ "$(grep -c 'await probeSideEffects(item, wt)' "$MJS")" -ge 3 ] \
  || fail "#1067: recoverLostReturn must reuse the EXISTING probeSideEffects, not invent a second probe"
echo "PASS: #1067 lost-return guard — recoverLostReturn/isLostReturn present, reusing the existing probe, greppable by name"

# ===========================================================================
# temperloop#1294 — one phase() PER STAGE, each still carrying #903's context
# ===========================================================================
# The /workflows collapsed row identified nothing about a running level: it sat
# on one static heading for the whole run. The kernel-side mitigation is a
# phase() per stage (claim → build → gate → PR → CI) whose title still names the
# repo, the item count and each item's <slug> (#<issue>) — #903's contract — so a
# collapsed view that renders the ACTIVE phase advances instead of freezing, and
# the expanded tree groups agents by stage instead of by 'machinery'/'worker'.

run_node_case "K1294 stages: a level emits one phase() per stage, in order, and EVERY stage title still carries #903's repo/count/item context" "
$PREAMBLE
const phases = [];
globalThis.phase = (t) => phases.push(String(t));
happyMachinery('alpha', 201, 'aa02');
happyMachinery('beta', 202, 'ab06');
happyMachinery('gamma', 203, 'ac09');
happyWorker('alpha'); happyWorker('beta'); happyWorker('gamma');
globalThis.args = { ...baseArgs, items: [
  { slug: 'alpha', branch: 'b/alpha', title: 'A', kind: 'impl', ghIssue: 11, acceptance: ['c'] },
  { slug: 'beta',  branch: 'b/beta',  title: 'B', kind: 'impl', ghIssue: 12, acceptance: ['c'] },
  { slug: 'gamma', branch: 'b/gamma', title: 'C', kind: 'impl', ghIssue: 13, acceptance: ['c'] },
]};
const mod = await loadLevel();
const result = await mod.default();
const CTX = 'owner/repo · 3 items · alpha (#11), beta (#12), gamma (#13)';
const EXPECTED = ['claim','build','review','gate','PR','CI'].map(s => 'build level · ' + s + ' — ' + CTX);
let reason = null;
if ((result.parked ?? []).length !== 3) reason = 'expected 3 parked, got ' + JSON.stringify(result);
// One phase() per stage, in pipeline order, no repeats and no regressions.
else if (JSON.stringify(phases) !== JSON.stringify(EXPECTED))
  reason = 'phase() sequence must be exactly the six stages in order, each carrying the #903 context.\n  got:      ' + JSON.stringify(phases) + '\n  expected: ' + JSON.stringify(EXPECTED);
// #903 non-regression, restated positively: EVERY stage title names repo, count and items.
else if (!phases.every(p => p.includes('owner/repo') && p.includes('3 items') && p.includes('alpha (#11)')))
  reason = 'a stage phase dropped the #903 run context: ' + JSON.stringify(phases);
// Every agent is assigned to its OWN stage's group via opts.phase — never left
// on the global cursor (which races under parallel()) and never on the old flat
// 'machinery'/'worker' constant.
else {
  const STAGE_OF_LABEL = [
    [/^prelude:/,      'claim'],
    [/^worker:/,       'build'],
    // temperloop#2065 — the worker-cost-capture seam's own labels carry the
    // SAME phase as whichever worker call they bracket (see
    // workerClockNow()/workerUsageEmit()'s \`phaseName\` param): the CI-fix
    // variant (tag names \`worker-cifix:\`) belongs to 'CI', so its more
    // specific pattern is checked FIRST; anything else (the main worker's
    // \`worker:<slug>\`/\`worker:<slug>#retry\` tag) belongs to 'build'.
    [/^worker-(?:clock|usage):[^#]*#worker-cifix:/, 'CI'],
    [/^worker-(?:clock|usage):/, 'build'],
    [/^review-diff:/,  'review'],
    [/^gate-freshness:/, 'gate'],
    [/^gate:/,         'gate'],
    [/^pr-batch:/,     'PR'],
    [/^ci-batch:/,     'CI'],
    [/^worker-cifix:/, 'CI'],
  ];
  for (const c of callLog) {
    const label = String(c.opts.label || '');
    const hit = STAGE_OF_LABEL.find(([re]) => re.test(label));
    if (!hit) { reason = 'unclassified agent label (a new spawn site needs a stage): ' + label; break; }
    const want = 'build level · ' + hit[1] + ' — ' + CTX;
    if (c.opts.phase !== want) { reason = label + ' assigned to the wrong progress group: ' + JSON.stringify(c.opts.phase) + ', expected ' + JSON.stringify(want); break; }
  }
}
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K1294 bounding: a level wider than PHASE_TITLE_MAX_ITEMS collapses the tail to '+K more' on EVERY stage title, not just the first" "
$PREAMBLE
const phases = [];
globalThis.phase = (t) => phases.push(String(t));
const slugs = ['i1','i2','i3','i4','i5'];
slugs.forEach((s, n) => { happyMachinery(s, 300 + n, 'a01' + n.toString(16)); happyWorker(s); });
globalThis.args = { ...baseArgs, items: slugs.map((s, n) => (
  { slug: s, branch: 'b/' + s, title: s, kind: 'impl', ghIssue: 400 + n, acceptance: ['c'] }
))};
const mod = await loadLevel();
const result = await mod.default();
let reason = null;
if ((result.parked ?? []).length !== 5) reason = 'expected 5 parked, got ' + JSON.stringify(result);
else if (phases.length !== 6) reason = 'expected 6 stage phases, got ' + JSON.stringify(phases);
else if (!phases.every(p => p.includes('5 items') && p.includes('i1 (#400), i2 (#401), i3 (#402) +2 more')))
  reason = 'every stage title must name at most PHASE_TITLE_MAX_ITEMS items and collapse the rest: ' + JSON.stringify(phases);
else if (phases.some(p => p.includes('i4') || p.includes('i5')))
  reason = 'the bound leaked — a 20-item level would swamp the progress row: ' + JSON.stringify(phases);
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K1294 monotonic: an off-path recovery probe gets its OWN group and never drags the collapsed row backwards" "
$PREAMBLE
const phases = [];
globalThis.phase = (t) => phases.push(String(t));
// A worker whose return channel is lost at the build stage: the recover-probe
// fires while the level is mid-flight. It must NOT re-fire phase().
setMachinery('rec1',
  { outcome: 'CREATED', path: '/tmp/repo.wt/rec1' },
  { outcome: 'RECOVER_PR_OPEN', sha: 'a4d', commits_ahead: 1, pushed: true, remote_sha: 'a4d', pr_number: 4242, verification_surface_present: true },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  // No REBASED entry — an already-pushed recovery skips 3f-0a.
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'a4d', branch: 'b/rec1' },
  { outcome: 'EXISTS', pr_number: 4242 },
  { outcome: 'CI_GREEN' },
);
setWorker('rec1', throwingWorker());
globalThis.args = { ...baseArgs, items: [
  { slug: 'rec1', branch: 'b/rec1', title: 'R', kind: 'impl', ghIssue: 77, acceptance: ['c'] },
]};
const mod = await loadLevel();
const result = await mod.default();
const probe = callLog.find(c => c.opts.label === 'recover-probe:rec1');
let reason = null;
if ((result.parked ?? []).length !== 1) reason = 'expected the recovered item to park: ' + JSON.stringify(result);
else if (!probe) reason = 'expected a recover-probe spawn';
else if (probe.opts.phase !== 'build level · recover — owner/repo · 1 item · rec1 (#77)')
  reason = 'the recovery probe must get its own named group: ' + JSON.stringify(probe.opts.phase);
else if (phases.some(p => p.includes('· recover —')))
  reason = 'an off-path recovery must NEVER move the global phase cursor: ' + JSON.stringify(phases);
// Cursor advanced monotonically over the stages it did reach.
else if (JSON.stringify(phases) !== JSON.stringify(['claim','build','review','gate','PR','CI'].map(s => 'build level · ' + s + ' — owner/repo · 1 item · rec1 (#77)')))
  reason = 'stage cursor must advance monotonically over the stages actually reached: ' + JSON.stringify(phases);
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

# --- K1294 static lockstep guards ------------------------------------------
# meta stays a PURE LITERAL and deliberately declares NO phases: meta.phases
# entries are matched against phase() titles EXACTLY, and every title this
# workflow emits is dynamic (#903 requires the repo/count/items in it), so a
# static entry could only ever render an empty duplicate group.
node -e "
  const fs = require('fs');
  const src = fs.readFileSync(process.env.MJS_PATH, 'utf8');
  const m = src.match(/export const meta = \{[\s\S]*?\n\};/);
  if (!m) { console.error('meta literal not found'); process.exit(1); }
  if (/phases\s*:/.test(m[0])) { console.error('meta declares phases: — every phase() title here is dynamic, so a static entry can only render an empty duplicate group'); process.exit(1); }
  if (/\\\$\{|\.\.\.|\(\)/.test(m[0])) { console.error('meta is no longer a pure literal'); process.exit(1); }
" || fail "#1294: meta must stay a pure literal with no phases: key"
grep -q 'function levelPhaseTitle(list, stage)' "$MJS" \
  || fail "#1294: levelPhaseTitle() must take the stage — a second title-formatting path would re-fork #903"
grep -q 'function enterStage(stage)' "$MJS" \
  || fail "#1294: enterStage() missing — the stage cursor must be one named, monotonic helper"
[ "$(grep -c '^[^/]*`build level' "$MJS")" -eq 1 ] \
  || fail "#1294: exactly one non-comment 'build level' title literal expected — a second one means the heading was hand-rolled somewhere instead of going through levelPhaseTitle()"
# Every agent spawn names its stage explicitly; the two flat constants survive
# ONLY as the `??` fallbacks inside the transport helpers.
[ "$(grep -c "phase: phaseName ?? 'machinery'" "$MJS")" -eq 2 ] \
  || fail "#1294: runMachinery/runMachineryBatch must take an explicit phase with a flat fallback"
grep -q "phase: phaseName ?? 'worker'" "$MJS" \
  || fail "#1294: callWorker must take an explicit phase with a flat fallback"
[ "$(grep -c "phase: enterStage(STAGE_" "$MJS")" -ge 7 ] \
  || fail "#1294: every stage-owning spawn site must pass opts.phase via enterStage() (global phase() state races inside parallel())"
# 4 = recover-probe + pr-batch-resume + the temperloop#1819 quota canary + the
# temperloop#1805 pr-open verdict fallback (all off-path recoveries that must
# never move the stage cursor — the fallback re-issues `pr.sh open` from inside
# the PR stage, so advancing the cursor would misreport the run's progress).
[ "$(grep -c "phase: stagePhase(STAGE_RECOVER)" "$MJS")" -eq 4 ] \
  || fail "#1294: the off-path recovery spawns must use stagePhase(), which never moves the cursor"
echo "PASS: #1294 stage-phase guard — one monotonic enterStage() cursor, explicit opts.phase at every spawn, meta.phases deliberately absent"

# ============================================================================
# TEST (K1432): §3c "effective engineering principles" — the orchestrator-
#   resolved (kernel ∪ project) set rides input.principlesSummaries /
#   input.principlesDefaultRepo into workerPrompt(), keyed per (repo, project)
#   pair. Four sub-cases in one node case (mirrors K1080's shape): the default
#   pair, a cross-repo item's OWN pair, an item whose repo has no resolved
#   pair (falls back to default, NOT degraded), and principlesSummaries
#   omitted entirely (falls back to the static kernel-only snapshot, WITH an
#   explicit degradation notice — never a silent empty set).
# ============================================================================
run_node_case "K1432: effective engineering principles ride input.principlesSummaries into the worker prompt, keyed by (repo, project) pair" "
$PREAMBLE

// Pass 1: default pair resolved and supplied — embedded verbatim, no DEGRADED notice.
happyMachinery('pr-item', 910, 'a7b');
happyWorker('pr-item');
globalThis.args = { ...baseArgs, principlesSummaries: {
  'owner/repo': '1. Test Kernel Principle — do the thing [kernel]\\n2. Test Project Principle — do the other thing [project]\\n\\n(kernel (7) ∪ project (Projects/repo/Priorities.md: 1))',
}, principlesDefaultRepo: 'owner/repo', items: [
  { slug: 'pr-item', branch: 'build/pr-item', title: 'PR item', kind: 'impl', acceptance: ['c'] },
]};
let mod = await loadLevel();
await mod.default();
let w = callLog.find(c => (c.opts.label||'') === 'worker:pr-item');
let reason = null;
if (!w) reason = 'no worker call logged (default pair)';
else if (!w.promptFull.includes('## Effective engineering principles')) reason = 'worker prompt missing the principles section (default pair)';
else if (!w.promptFull.includes('Test Kernel Principle')) reason = 'worker prompt missing the resolved kernel entry (default pair)';
else if (!w.promptFull.includes('Test Project Principle')) reason = 'worker prompt missing the resolved project entry (default pair)';
else if (w.promptFull.includes('DEGRADED')) reason = 'default-pair prompt must NOT carry the degradation notice';
if (reason) { console.log(JSON.stringify({ ok: false, reason })); process.exit(0); }

// Pass 2: a cross-repo item (its own repo: differs from ownerRepo) picks ITS
// pair's summary, not the default's.
callLog.length = 0;
happyMachinery('xr-item', 911, 'a80');
happyWorker('xr-item');
globalThis.args = { ...baseArgs, principlesSummaries: {
  'owner/repo': '1. Home Principle [kernel]',
  'other/repo': '1. Foreign Kernel Principle [kernel]\\n\\n(kernel (7) only — no project § Principles declared)',
}, principlesDefaultRepo: 'owner/repo', items: [
  { slug: 'xr-item', branch: 'build/xr-item', title: 'XR item', kind: 'impl', acceptance: ['c'], repo: 'other/repo' },
]};
mod = await loadLevel();
await mod.default();
w = callLog.find(c => (c.opts.label||'') === 'worker:xr-item');
if (!w) reason = 'no worker call logged (cross-repo pair)';
else if (!w.promptFull.includes('Foreign Kernel Principle')) reason = 'cross-repo item must embed ITS OWN pair\\'s summary';
else if (w.promptFull.includes('Home Principle')) reason = 'cross-repo item must NOT fall back to the default pair when its own pair is resolved';
if (reason) { console.log(JSON.stringify({ ok: false, reason })); process.exit(0); }

// Pass 3: an item whose OWN repo: has no resolved pair falls back to the
// default pair's summary (never the static fallback, never DEGRADED — a
// resolved principlesSummaries map WAS supplied this run).
callLog.length = 0;
happyMachinery('unk-item', 912, 'a7f');
happyWorker('unk-item');
globalThis.args = { ...baseArgs, principlesSummaries: {
  'owner/repo': '1. Home Principle [kernel]',
}, principlesDefaultRepo: 'owner/repo', items: [
  { slug: 'unk-item', branch: 'build/unk-item', title: 'Unknown-repo item', kind: 'impl', acceptance: ['c'], repo: 'unresolved/repo' },
]};
mod = await loadLevel();
await mod.default();
w = callLog.find(c => (c.opts.label||'') === 'worker:unk-item');
if (!w) reason = 'no worker call logged (unresolved-repo fallback)';
else if (!w.promptFull.includes('Home Principle')) reason = 'an item whose own repo pair was not resolved must fall back to the DEFAULT pair\\'s summary';
else if (w.promptFull.includes('DEGRADED')) reason = 'falling back to the default pair is NOT the degraded path — principlesSummaries WAS supplied this run';
if (reason) { console.log(JSON.stringify({ ok: false, reason })); process.exit(0); }

// Pass 4: principlesSummaries entirely OMITTED (an older orchestrator or a
// consuming-repo caller — all three first-party callers pass it, temperloop#1460) —
// worker still gets a bounded, legible list: the static kernel-only fallback
// PLUS an explicit DEGRADED notice, never a silent empty set.
callLog.length = 0;
happyMachinery('deg-item', 913, 'ade69');
happyWorker('deg-item');
globalThis.args = { ...baseArgs, items: [
  { slug: 'deg-item', branch: 'build/deg-item', title: 'Degraded item', kind: 'impl', acceptance: ['c'] },
]};
mod = await loadLevel();
await mod.default();
w = callLog.find(c => (c.opts.label||'') === 'worker:deg-item');
if (!w) reason = 'no worker call logged (degraded fallback)';
else if (!w.promptFull.includes('## Effective engineering principles')) reason = 'omitted principlesSummaries must still carry the principles section (never silently drop it)';
else if (!w.promptFull.includes('Every meaningful behavior tested for every state')) reason = 'omitted principlesSummaries must fall back to the static kernel-only snapshot';
else if (!w.promptFull.includes('DEGRADED')) reason = 'omitted principlesSummaries must carry an explicit DEGRADED notice — never a silent kernel-only set';
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

# --- K1432 static lockstep guards: §3c \"effective engineering principles\" ---
# build.md's Step 1.8 resolves the merged set once per run; §3c/build-level.mjs
# embed it; a future edit that drops either surface leaves the other rotting.
grep -q 'function principlesSection' "$MJS" \
  || fail "#1432: principlesSection() missing — workerPrompt must embed the resolved principle set as its own self-contained section"
grep -q '## Effective engineering principles — weigh your choices against these' "$MJS" \
  || fail "#1432: workerPrompt() must embed the '## Effective engineering principles' section"
grep -q 'input.principlesSummaries' "$MJS" \
  || fail "#1432: PRINCIPLES_SUMMARIES must read the orchestrator-supplied input.principlesSummaries (Step-0/Step-1.8 hand-off seam)"
grep -q 'input.principlesDefaultRepo' "$MJS" \
  || fail "#1432: PRINCIPLES_DEFAULT_REPO must read the orchestrator-supplied input.principlesDefaultRepo"
grep -q 'PRINCIPLES_KERNEL_FALLBACK' "$MJS" \
  || fail "#1432: a static kernel-only fallback must exist for when principlesSummaries is entirely absent (never a silent empty set)"
grep -q "'DEGRADED —" "$MJS" \
  || fail "#1432: the fallback path must emit a legible DEGRADED notice, not a silent kernel-only list"
K1432_BUILD_MD="$REPO_ROOT/claude/commands/build.md"
# An absent build.md is a HARD FAIL, never a skip (temperloop#1409's own
# failure class: a check that cannot run must not report PASS). The .mjs
# side above is already guaranteed present by this file's top-of-file `[ -f
# "$MJS" ]` guard; build.md carries no such guard, so this line is what
# keeps a deleted/renamed prose file from silently dropping its half of the
# lockstep pair instead of going red.
[ -f "$K1432_BUILD_MD" ] \
  || fail "#1432: claude/commands/build.md is missing — the prose half of this contract pair cannot be verified"
grep -q 'principlesSummaries' "$K1432_BUILD_MD" \
  || fail "#1432: build.md must name principlesSummaries in its Step 3 args hand-off (lockstep with build-level.mjs)"
grep -q 'principlesDefaultRepo' "$K1432_BUILD_MD" \
  || fail "#1432: build.md must name principlesDefaultRepo in its Step 3 args hand-off (lockstep with build-level.mjs)"
grep -q 'Step 1.8' "$K1432_BUILD_MD" \
  || fail "#1432: build.md must define Step 1.8 — the once-per-run orchestrator resolution §3c/§3e both reuse"
echo "PASS: #1432 principles guard — workerPrompt embeds the resolved (or legibly degraded) effective principle set; build.md Step 1.8/§3c/§3e in lockstep"

# ============================================================================
# TEST (K1319): test-discrimination evidence — a worker must report, per
#   acceptance criterion, proof its own check can actually FAIL (which
#   mechanism it removed, that the suite went RED without it, that restoring
#   it went GREEN) — and that evidence must reach a human via the PR body,
#   not stop at the schema. Gated on input.requireDiscriminationEvidence so
#   it reaches /build's real per-criterion bullets but does NOT leak to
#   /sweep's / /fix's bare-string acceptance placeholder (mirrors K1432's
#   shape: an armed pass, a leak-check pass, then static lockstep guards).
# ============================================================================
run_node_case "K1319: requireDiscriminationEvidence arms the Discrimination-evidence section; omitted/false leaves it OFF (no leak to /sweep, /fix)" "
$PREAMBLE

// Pass 1: armed (/build's own hand-off) — section present, names the
// mechanism/RED/GREEN requirement, and bounds the field from the SAME named
// setting as .evidence (WORKER_EVIDENCE_MAX_WORDS), not a hardcoded literal.
happyMachinery('discrim-on', 920, 'adc6e');
happyWorker('discrim-on');
globalThis.args = { ...baseArgs, requireDiscriminationEvidence: true, workerEvidenceMaxWords: 23, items: [
  { slug: 'discrim-on', branch: 'build/discrim-on', title: 'Discrim on', kind: 'impl', acceptance: ['c'] },
]};
let mod = await loadLevel();
await mod.default();
let w = callLog.find(c => (c.opts.label||'') === 'worker:discrim-on');
let reason = null;
if (!w) reason = 'no worker call logged (armed pass)';
else if (!w.promptFull.includes('## Discrimination evidence')) reason = 'armed run missing the Discrimination evidence section';
else if (!w.promptFull.includes('discrimination_evidence')) reason = 'armed run does not name the discrimination_evidence field';
else if (!/went RED without it/.test(w.promptFull)) reason = 'armed run missing the RED-without-it requirement';
else if (!/went GREEN/.test(w.promptFull)) reason = 'armed run missing the restored-GREEN requirement';
else if (!/[Ww]hich mechanism you removed/.test(w.promptFull)) reason = 'armed run missing the removed-mechanism requirement';
else if (!w.promptFull.includes('at most 23 words')) reason = 'discrimination_evidence bound did not come from input.workerEvidenceMaxWords (same seam as .evidence)';
if (reason) { console.log(JSON.stringify({ ok: false, reason })); process.exit(0); }

// Pass 2: omitted entirely — the /sweep, /fix inheritance path. Section must
// be ABSENT, not degraded-and-present — an unrequired discipline must stay
// silent, unlike principlesSummaries' always-present-with-notice shape.
callLog.length = 0;
happyMachinery('discrim-off', 921, 'adcff6d');
happyWorker('discrim-off');
globalThis.args = { ...baseArgs, items: [
  { slug: 'discrim-off', branch: 'build/discrim-off', title: 'Discrim off', kind: 'impl', acceptance: ['(self-verify the issue is resolved)'] },
]};
mod = await loadLevel();
await mod.default();
w = callLog.find(c => (c.opts.label||'') === 'worker:discrim-off');
if (!w) reason = 'no worker call logged (omitted pass)';
else if (w.promptFull.includes('## Discrimination evidence')) reason = 'omitted requireDiscriminationEvidence must NOT arm the Discrimination evidence section (the /sweep, /fix leak this item forbids)';
if (reason) { console.log(JSON.stringify({ ok: false, reason })); process.exit(0); }

// Pass 3: explicitly false — same OFF outcome as omitted (=== true, not a
// truthy check), proving the gate is strict equality.
callLog.length = 0;
happyMachinery('discrim-false', 922, 'adcfae6b');
happyWorker('discrim-false');
globalThis.args = { ...baseArgs, requireDiscriminationEvidence: false, items: [
  { slug: 'discrim-false', branch: 'build/discrim-false', title: 'Discrim false', kind: 'impl', acceptance: ['c'] },
]};
mod = await loadLevel();
await mod.default();
w = callLog.find(c => (c.opts.label||'') === 'worker:discrim-false');
if (!w) reason = 'no worker call logged (false pass)';
else if (w.promptFull.includes('## Discrimination evidence')) reason = 'requireDiscriminationEvidence: false must leave the section OFF (=== true gate, not truthy)';
if (reason) { console.log(JSON.stringify({ ok: false, reason })); process.exit(0); }

// Pass 4 (the [HIGH] gap): armed run, a done verdict with ONE criterion that
// reported discrimination_evidence and ONE that claimed passed:true with the
// field empty. The gap must NOT block the item (advisory, kernel principle
// 7 — the item still parks, no escalation) but MUST be named on the parked
// record so the orchestrator can surface + tally it — never silently
// dropped, which is exactly the failure criterion 2 exists to close.
callLog.length = 0;
happyMachinery('discrim-gap', 923, 'adca6c');
setWorker('discrim-gap', { status: 'done', summary: 'gap item done', commits: [], acceptance_results: [
  { criterion: 'proven criterion', passed: true, evidence: 'e1', discrimination_evidence: 'removed X -> RED; restored -> GREEN' },
  { criterion: 'unproven criterion', passed: true, evidence: 'e2' },
  { criterion: 'blank-string criterion', passed: true, evidence: 'e3', discrimination_evidence: '   ' },
]});
globalThis.args = { ...baseArgs, requireDiscriminationEvidence: true, items: [
  { slug: 'discrim-gap', branch: 'build/discrim-gap', title: 'Discrim gap', kind: 'impl', acceptance: ['proven criterion', 'unproven criterion', 'blank-string criterion'] },
]};
mod = await loadLevel();
let result = await mod.default();
let p = (result.parked ?? []).find(x => x.slug === 'discrim-gap');
if (!p) reason = 'gap item did not park (a degraded discrimination_evidence must be advisory, never a hard failure)';
else if ((result.escalations ?? []).length !== 0) reason = 'gap item must not escalate — advisory only (kernel principle 7)';
else if (!Array.isArray(p.discrimination_gaps)) reason = 'parked record missing discrimination_gaps array for an armed run with a real gap';
else if (p.discrimination_gaps.length !== 2) reason = 'expected exactly 2 gap criteria (empty + whitespace-only), got ' + JSON.stringify(p.discrimination_gaps);
else if (!p.discrimination_gaps.includes('unproven criterion')) reason = 'discrimination_gaps missing the criterion with an absent discrimination_evidence';
else if (!p.discrimination_gaps.includes('blank-string criterion')) reason = 'discrimination_gaps must treat a whitespace-only discrimination_evidence as empty';
else if (p.discrimination_gaps.includes('proven criterion')) reason = 'discrimination_gaps wrongly included a criterion that DID report discrimination_evidence';
if (reason) { console.log(JSON.stringify({ ok: false, reason })); process.exit(0); }

// Pass 5: armed run, EVERY criterion carries discrimination_evidence — no
// spurious tally when nothing is actually missing.
callLog.length = 0;
happyMachinery('discrim-clean', 924, 'adccea6a');
setWorker('discrim-clean', { status: 'done', summary: 'clean item done', commits: [], acceptance_results: [
  { criterion: 'c', passed: true, evidence: 'e', discrimination_evidence: 'removed X -> RED; restored -> GREEN' },
]});
globalThis.args = { ...baseArgs, requireDiscriminationEvidence: true, items: [
  { slug: 'discrim-clean', branch: 'build/discrim-clean', title: 'Discrim clean', kind: 'impl', acceptance: ['c'] },
]};
mod = await loadLevel();
result = await mod.default();
p = (result.parked ?? []).find(x => x.slug === 'discrim-clean');
if (!p) reason = 'clean item did not park';
else if ('discrimination_gaps' in p) reason = 'clean item (no gaps) must not carry a discrimination_gaps field at all — expected 0, got ' + JSON.stringify(p.discrimination_gaps);

// Pass 6: UNARMED run (requireDiscriminationEvidence omitted) with a
// passed:true criterion carrying no discrimination_evidence — must NOT tally
// a gap, since the requirement was never in force for this run (mirrors
// Pass 2's 'no leak' shape, at the park-record layer instead of the prompt).
if (!reason) {
  callLog.length = 0;
  happyMachinery('discrim-unarmed', 925, 'adcaed6f');
  setWorker('discrim-unarmed', { status: 'done', summary: 'unarmed item done', commits: [], acceptance_results: [
    { criterion: '(self-verify the issue is resolved)', passed: true, evidence: 'e' },
  ]});
  globalThis.args = { ...baseArgs, items: [
    { slug: 'discrim-unarmed', branch: 'build/discrim-unarmed', title: 'Discrim unarmed', kind: 'impl', acceptance: ['(self-verify the issue is resolved)'] },
  ]};
  mod = await loadLevel();
  result = await mod.default();
  p = (result.parked ?? []).find(x => x.slug === 'discrim-unarmed');
  if (!p) reason = 'unarmed item did not park';
  else if ('discrimination_gaps' in p) reason = 'unarmed run (requireDiscriminationEvidence omitted) must never tally discrimination_gaps — the requirement was never in force';
}
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

# --- K1319 static lockstep guards: test-discrimination evidence --------------
# Three surfaces must move together: the .mjs schema + prompt section, build.md's
# §3c prose + Step 3 args hand-off, and pr.sh's recap consumer (the load-bearing
# half — this is the item whose whole point is that the evidence reaches a human
# instead of being silently dropped by a jq filter that reads only the three
# original fields). Every check below HARD FAILS on an absent file — no
# `if [ -f ... ]` skip-and-PASS (the K1080 anti-pattern, temperloop#1438).
grep -q 'function discriminationEvidenceSection' "$MJS" \
  || fail "#1319: discriminationEvidenceSection() missing — workerPrompt must embed the discrimination-evidence requirement as its own self-contained, gated section"
grep -q '## Discrimination evidence — prove each check can actually FAIL' "$MJS" \
  || fail "#1319: workerPrompt() must embed the '## Discrimination evidence' section when armed"
grep -q 'input.requireDiscriminationEvidence' "$MJS" \
  || fail "#1319: REQUIRE_DISCRIMINATION_EVIDENCE must read the orchestrator-supplied input.requireDiscriminationEvidence (Step-0/Step-3 hand-off seam)"
grep -q 'REQUIRE_DISCRIMINATION_EVIDENCE = input.requireDiscriminationEvidence === true' "$MJS" \
  || fail "#1319: the gate must be strict === true, never a truthy/|| check — a non-boolean must not accidentally arm it"
grep -q 'discrimination_evidence' "$MJS" \
  || fail "#1319: WORKER_VERDICT_SCHEMA's acceptance_results items must declare a discrimination_evidence property"
K1319_BUILD_MD="$REPO_ROOT/claude/commands/build.md"
[ -f "$K1319_BUILD_MD" ] \
  || fail "#1319: claude/commands/build.md is missing — the prose half of this contract pair cannot be verified"
grep -q 'discrimination_evidence' "$K1319_BUILD_MD" \
  || fail "#1319: build.md §3c must name discrimination_evidence in its return-contract prose (lockstep with build-level.mjs)"
grep -q 'requireDiscriminationEvidence' "$K1319_BUILD_MD" \
  || fail "#1319: build.md must name requireDiscriminationEvidence in its Step 3 args hand-off (lockstep with build-level.mjs)"
grep -q 'does NOT widen to' "$K1319_BUILD_MD" \
  || fail "#1319: build.md must state the /sweep, /fix scoping explicitly — this is the leak this item forbids"
K1319_PR_SH="$REPO_ROOT/workflows/scripts/build/pr.sh"
[ -f "$K1319_PR_SH" ] \
  || fail "#1319: workflows/scripts/build/pr.sh is missing — the PR-body consumer half of this contract cannot be verified"
grep -q 'discrimination_evidence' "$K1319_PR_SH" \
  || fail "#1319: pr.sh's assemble_body recap must read .discrimination_evidence — the whole point of this item is that it reaches the PR body a human reviews, not just the schema"

# --- K1319b: the [HIGH] §3e finding — a missing field must be a NAMED,
# VISIBLE degradation (a warning + a Step-6 tally), never silent, since
# neither WORKER_VERDICT_SCHEMA nor §3d/§3e.5 enforce the field's presence
# (advisory, kernel principle 7 — never a new blocking gate). Covers the
# implementation (discriminationGaps()/park()'s discrimination_gaps field,
# runtime-proven above by the K1319 case's passes 4-6) AND the prose (the
# 3f-step-2 degraded-case clause + the Step 6 summary tally line).
grep -q 'function discriminationGaps' "$MJS" \
  || fail "#1319b: discriminationGaps() missing — the degraded-case detector (a passed:true entry with an empty/absent discrimination_evidence)"
grep -q 'discrimination_gaps' "$MJS" \
  || fail "#1319b: park()'s returned record must carry discrimination_gaps — the durable marker the orchestrator tallies (mirrors the no_ci pattern)"
grep -q 'discrimination_gaps' "$K1319_BUILD_MD" \
  || fail "#1319b: build.md must name discrimination_gaps (Step 6 summary tally / the 3f-step-2 degraded-case clause) — lockstep with build-level.mjs"
grep -q 'Surface the degraded case here too' "$K1319_BUILD_MD" \
  || fail "#1319b: build.md §3f step 2 must carry the discrimination-evidence degraded-case clause, mirroring the sibling verification_surface clause"
grep -q 'Discrimination-evidence gaps (temperloop#1319' "$K1319_BUILD_MD" \
  || fail "#1319b: build.md Step 6 summary template must carry a discrimination-evidence-gaps tally line"

# --- K1319c: the [MEDIUM] rationale-correctness finding — the /sweep, /fix
# exclusion must be stated as an OPERATIONAL SCOPE decision, never as a
# structural impossibility (sweep.md/fix.md's acceptance: CAN be a real
# per-criterion array — acceptanceList() already handles it). Guard against
# the corrected claim regressing back to the false one.
grep -q 'operational scope decision' "$K1319_BUILD_MD" \
  || fail "#1319c: build.md must state the /sweep, /fix exclusion is an operational scope decision, not a structural one (the corrected rationale)"
grep -qi 'OPERATIONAL SCOPE DECISION' "$MJS" \
  || fail "#1319c: build-level.mjs's REQUIRE_DISCRIMINATION_EVIDENCE comment must state the /sweep, /fix exclusion is an operational scope decision, not a structural one"

# --- K1319d: the [MEDIUM] deferred-bare-gate ambiguity finding — a criterion
# naming the bare repo-wide suite (deferred to §3e.5 per #997) never ran
# red/green at all, which is a DIFFERENT exemption than "too coarse to
# discriminate" and must say so in exactly this wording, both in the prose
# contract and in the actual worker prompt.
grep -q 'deferred to §3e.5; discrimination not established worker-side' "$K1319_BUILD_MD" \
  || fail "#1319d: build.md must reconcile the deferred-bare-gate carve-out with discrimination_evidence — state the exact exempt-field wording"
grep -q 'deferred to §3e.5; discrimination not established worker-side' "$MJS" \
  || fail "#1319d: workerPrompt()'s Discrimination evidence section must tell the worker the exact wording for a deferred-bare-gate criterion (lockstep with build.md)"

echo "PASS: #1319 discrimination-evidence guard — workerPrompt gates the requirement on requireDiscriminationEvidence (no /sweep, /fix leak); build.md §3c/Step-3 args and pr.sh's recap consumer in lockstep; the degraded-case warning+tally, the corrected /sweep,/fix rationale, and the deferred-bare-gate reconciliation are all in lockstep too (§3e spec-review follow-up)"

# ============================================================================
# TEST (K1182): host-config / secret acceptance criteria are DEFERRED by the
#   worker and verified PARENT-SIDE by the orchestrator. A worktree is
#   populated from the git INDEX, so a gitignored host-local file is never
#   carried in: the worker's reading is absent/false in every worktree on
#   every host regardless of the truth (foundation#1556 — `credential_present:
#   false` in the worktree, `true` in BOTH real checkouts moments later). The
#   deferral is the PAIR `passed: false` + a non-empty `deferred_host_config`:
#   neither half alone changes anything, so this can never swallow a real
#   failure, and it never manufactures a pass.
# ============================================================================
run_node_case "K1182: a host-config deferral parks with a host_config_deferrals tally; a bare passed:false still escalates" "
$PREAMBLE

// Pass 1: the instruction reaches the worker prompt, UNGATED (no
// requireDiscriminationEvidence-style arming — the worktree-vs-index fact
// holds on /build, /sweep and /fix alike), and carries both load-bearing
// halves: the no-carry prohibition and the passed:false + marker pair.
happyMachinery('hostcfg-prompt', 940, 'a76');
happyWorker('hostcfg-prompt');
globalThis.args = { ...baseArgs, items: [
  { slug: 'hostcfg-prompt', branch: 'build/hostcfg-prompt', title: 'Host cfg prompt', kind: 'impl', acceptance: ['c'] },
]};
let mod = await loadLevel();
await mod.default();
let w = callLog.find(c => (c.opts.label||'') === 'worker:hostcfg-prompt');
let reason = null;
if (!w) reason = 'no worker call logged (prompt pass)';
else if (!w.promptFull.includes('## Host-config / gitignored-file criteria')) reason = 'worker prompt missing the host-config deferral section (must be UNGATED — every worker gets it)';
else if (!w.promptFull.includes('deferred_host_config')) reason = 'worker prompt does not name the deferred_host_config marker field';
else if (!/Do NOT carry, copy, recreate/.test(w.promptFull)) reason = 'worker prompt missing the no-carry prohibition (the secret-in-worktree exposure A.8 prevents)';
else if (!/DEFERRED, never as passed/.test(w.promptFull)) reason = 'worker prompt must say the criterion is reported DEFERRED, never as passed';
if (reason) { console.log(JSON.stringify({ ok: false, reason })); process.exit(0); }

// Pass 2 (the load-bearing case): a done verdict whose host-config criterion
// is DEFERRED. It must NOT escalate acceptance-incomplete (that is the
// foundation#1556 stall over a reading nobody could take), must park, and the
// parked record must carry the criterion AND the file the parent needs to run
// the check — never a silent pass.
callLog.length = 0;
happyMachinery('hostcfg-defer', 941, 'adefe75');
setWorker('hostcfg-defer', { status: 'done', summary: 'deferred item done', commits: [], acceptance_results: [
  { criterion: 'spawn --dry-run reports credential_present', passed: false, evidence: 'not observable from a worktree', deferred_host_config: 'workflows/scripts/build/build.config.local.sh (SENTRY_AUTH_TOKEN)' },
  { criterion: 'the spawn reads the credential from config', passed: true, evidence: 'unit test green' },
]});
globalThis.args = { ...baseArgs, items: [
  { slug: 'hostcfg-defer', branch: 'build/hostcfg-defer', title: 'Host cfg defer', kind: 'impl', acceptance: ['spawn --dry-run reports credential_present', 'the spawn reads the credential from config'] },
]};
mod = await loadLevel();
let result = await mod.default();
let p = (result.parked ?? []).find(x => x.slug === 'hostcfg-defer');
if ((result.escalations ?? []).length !== 0) reason = 'a marked host-config deferral must NOT escalate acceptance-incomplete — got ' + JSON.stringify(result.escalations);
else if (!p) reason = 'deferred item did not park';
else if (!Array.isArray(p.host_config_deferrals)) reason = 'parked record missing the host_config_deferrals array';
else if (p.host_config_deferrals.length !== 1) reason = 'expected exactly 1 deferral (the passed:true sibling must not be tallied), got ' + JSON.stringify(p.host_config_deferrals);
else if (p.host_config_deferrals[0].criterion !== 'spawn --dry-run reports credential_present') reason = 'deferral entry lost its criterion';
else if (!/build\\.config\\.local\\.sh/.test(p.host_config_deferrals[0].host_config)) reason = 'deferral entry must carry the host_config file/env the orchestrator needs to run the parent-side check';
if (reason) { console.log(JSON.stringify({ ok: false, reason })); process.exit(0); }

// Pass 3: a BARE passed:false with no marker escalates exactly as before. The
// exclusion is the PAIR, never the boolean — otherwise this item would have
// quietly turned every failed criterion into a park.
callLog.length = 0;
happyMachinery('hostcfg-bare', 942, 'abae72');
setWorker('hostcfg-bare', { status: 'done', summary: 'bare fail', commits: [], acceptance_results: [
  { criterion: 'a genuinely failed criterion', passed: false, evidence: 'test RED' },
]});
globalThis.args = { ...baseArgs, items: [
  { slug: 'hostcfg-bare', branch: 'build/hostcfg-bare', title: 'Host cfg bare', kind: 'impl', acceptance: ['a genuinely failed criterion'] },
]};
mod = await loadLevel();
result = await mod.default();
let esc = (result.escalations ?? []).find(x => x.slug === 'hostcfg-bare');
if (!esc) reason = 'a bare passed:false (no deferred_host_config) must STILL escalate — the deferral exclusion must not swallow real failures';
else if (esc.kind !== 'acceptance-incomplete') reason = 'expected acceptance-incomplete for a bare passed:false, got ' + esc.kind;
if (reason) { console.log(JSON.stringify({ ok: false, reason })); process.exit(0); }

// Pass 4: a whitespace-only marker is NOT a marker (same trim rule as
// discrimination_evidence) — it escalates like any bare failure.
callLog.length = 0;
happyMachinery('hostcfg-blank', 943, 'aba73');
setWorker('hostcfg-blank', { status: 'done', summary: 'blank marker', commits: [], acceptance_results: [
  { criterion: 'blank-marker criterion', passed: false, evidence: 'e', deferred_host_config: '   ' },
]});
globalThis.args = { ...baseArgs, items: [
  { slug: 'hostcfg-blank', branch: 'build/hostcfg-blank', title: 'Host cfg blank', kind: 'impl', acceptance: ['blank-marker criterion'] },
]};
mod = await loadLevel();
result = await mod.default();
esc = (result.escalations ?? []).find(x => x.slug === 'hostcfg-blank');
if (!esc || esc.kind !== 'acceptance-incomplete') reason = 'a whitespace-only deferred_host_config must not count as a marker — expected acceptance-incomplete, got ' + JSON.stringify(result.escalations);
if (reason) { console.log(JSON.stringify({ ok: false, reason })); process.exit(0); }

// Pass 5: an item with no host-config criterion carries no field at all —
// byte-identical parked records to before this item.
callLog.length = 0;
happyMachinery('hostcfg-clean', 944, 'acea74');
happyWorker('hostcfg-clean');
globalThis.args = { ...baseArgs, items: [
  { slug: 'hostcfg-clean', branch: 'build/hostcfg-clean', title: 'Host cfg clean', kind: 'impl', acceptance: ['c'] },
]};
mod = await loadLevel();
result = await mod.default();
p = (result.parked ?? []).find(x => x.slug === 'hostcfg-clean');
if (!p) reason = 'clean item did not park';
else if ('host_config_deferrals' in p) reason = 'an item with no deferral must not carry a host_config_deferrals field at all — got ' + JSON.stringify(p.host_config_deferrals);
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

# --- K1182 static lockstep guards: host-config deferral ----------------------
# Five surfaces move together: the .mjs (schema field + prompt section +
# detector + park tally + anyFailed exclusion), build.md's §3c/§3d/§4a/Step-6
# prose, assess.md's A.8 (the bar this must NOT relax), pr.sh's PR-body
# consumer, and worktree.sh's standing no-carry prohibition. Every check HARD
# FAILS on an absent file — no skip-and-PASS.
grep -q 'function hostConfigDeferralSection' "$MJS" \
  || fail "#1182: hostConfigDeferralSection() missing — workerPrompt must embed the deferral contract as its own self-contained section"
grep -q '## Host-config / gitignored-file criteria — DEFER, never confirm' "$MJS" \
  || fail "#1182: workerPrompt() must embed the '## Host-config / gitignored-file criteria' section"
grep -q 'function isHostConfigDeferral' "$MJS" \
  || fail "#1182: isHostConfigDeferral() missing — the pair detector §3d's anyFailed exclusion and the park tally both read"
grep -q 'r.passed === false && !isHostConfigDeferral(r)' "$MJS" \
  || fail "#1182: §3d's anyFailed must exclude a MARKED deferral only — the pair, never the boolean alone (a bare passed:false must still escalate)"
grep -q 'host_config_deferrals' "$MJS" \
  || fail "#1182: park()'s returned record must carry host_config_deferrals — the durable marker the orchestrator verifies parent-side"
grep -q 'deferred_host_config' "$MJS" \
  || fail "#1182: WORKER_VERDICT_SCHEMA's acceptance_results items must declare a deferred_host_config property"
K1182_BUILD_MD="$REPO_ROOT/claude/commands/build.md"
[ -f "$K1182_BUILD_MD" ] \
  || fail "#1182: claude/commands/build.md is missing — the prose half of this contract pair cannot be verified"
grep -q 'deferred_host_config' "$K1182_BUILD_MD" \
  || fail "#1182: build.md §3c must name the deferred_host_config marker (lockstep with build-level.mjs)"
grep -q 'host_config_deferrals' "$K1182_BUILD_MD" \
  || fail "#1182: build.md §4a must name host_config_deferrals — the parked field the parent-side verification reads"
grep -q 'verified PARENT-SIDE by the orchestrator' "$K1182_BUILD_MD" \
  || fail "#1182: build.md §3c must state that the orchestrator verifies a host-config criterion parent-side, after the worker hands back"
grep -q 'Verify every host-config deferral HERE, parent-side' "$K1182_BUILD_MD" \
  || fail "#1182: build.md §4a must carry the parent-side verification step itself — naming the field is not the same as disposing it before merge"
grep -q 'Host-config deferrals (temperloop#1182' "$K1182_BUILD_MD" \
  || fail "#1182: build.md Step 6 summary template must carry a host-config-deferral tally line (V + U + E == D)"
# §3h.5's as-you-go fast path BYPASSES §4a by construction ("its own green" is
# long past by the level boundary), so an item carrying host_config_deferrals
# must be INELIGIBLE for it. Gate 3 is the eligibility slot that already
# excludes the sibling `acceptance_unverified: true` field; this asserts the
# SAME LINE also names host_config_deferrals — a different, non-overlapping
# field, so excluding one does not exclude the other. Scoped to gate 3's own
# line so a stray mention elsewhere in the file cannot satisfy it.
K1182_GATE3_LN="$(grep -n '^3\. \*\*No unverified acceptance' "$K1182_BUILD_MD" | head -1 | cut -d: -f1)"
[ -n "$K1182_GATE3_LN" ] \
  || fail "#1182: build.md §3h.5 eligibility gate 3 ('No unverified acceptance') not found — the as-you-go exclusion cannot be verified"
sed -n "${K1182_GATE3_LN}p" "$K1182_BUILD_MD" | grep 'host_config_deferrals' >/dev/null \
  || fail "#1182: build.md §3h.5 eligibility gate 3 must exclude an item carrying host_config_deferrals — the as-you-go path never reaches §4a, so a deferral riding it merges with NOBODY having verified it"
sed -n "${K1182_GATE3_LN}p" "$K1182_BUILD_MD" | grep 'acceptance_unverified' >/dev/null \
  || fail "#1182: build.md §3h.5 eligibility gate 3 must still exclude acceptance_unverified — the #939 exclusion is not replaced by the #1182 one"
# The worker-prompt section is UNGATED across /build, /sweep and /fix, so each
# of those specs owes its own parent-side verification seat. build.md's is §4a
# (checked above); these are the other two. Without them an ungated deferral
# instruction auto-merges unverified on those paths.
K1182_SWEEP_MD="$REPO_ROOT/claude/commands/sweep.md"
[ -f "$K1182_SWEEP_MD" ] \
  || fail "#1182: claude/commands/sweep.md is missing — /sweep's parent-side verification seat cannot be verified"
grep -q 'settle every host-config deferral parent-side' "$K1182_SWEEP_MD" \
  || fail "#1182: sweep.md's per-chunk merge pass must settle host-config deferrals parent-side BEFORE 'gh pr merge --auto' — /sweep has no §4a, so this is its only seat"
grep -q 'host_config_deferrals' "$K1182_SWEEP_MD" \
  || fail "#1182: sweep.md must name host_config_deferrals — the parked field its merge pass reads to find the deferrals it owes verification"
K1182_FIX_MD="$REPO_ROOT/claude/commands/fix.md"
[ -f "$K1182_FIX_MD" ] \
  || fail "#1182: claude/commands/fix.md is missing — /fix's parent-side verification seat cannot be verified"
grep -q 'Settle every host-config deferral parent-side BEFORE this ask' "$K1182_FIX_MD" \
  || fail "#1182: fix.md Step 5's modal merge gate must settle host-config deferrals parent-side before the ask — /fix has no §4a, so its one human-gated moment is the seat"
grep -q 'host_config_deferrals' "$K1182_FIX_MD" \
  || fail "#1182: fix.md must name host_config_deferrals — Step 4a carries it forward to the Step 5 gate"
# The .mjs's own ungated rationale must name the seats it depends on, so a
# future path added to the driver cannot inherit the instruction with no seat.
grep -q 'UNGATED IS ONLY SOUND BECAUSE ALL THREE PATHS HAVE A SEAT' "$MJS" \
  || fail "#1182: build-level.mjs's hostConfigDeferralSection() rationale must name the three consumer seats — an ungated instruction on a seatless path is how a deferral auto-merges unverified"
K1182_ASSESS_MD="$REPO_ROOT/claude/commands/assess.md"
[ -f "$K1182_ASSESS_MD" ] \
  || fail "#1182: claude/commands/assess.md is missing — the A.8 half of this contract cannot be verified"
grep -q 'confirmed set,\" not merely \"location named' "$K1182_ASSESS_MD" \
  || fail "#1182: assess.md A.8's confirmed-set bar must stay INTACT — this item moves WHO confirms, never WHETHER"
grep -q 'Who verifies such a criterion — the orchestrator, parent-side' "$K1182_ASSESS_MD" \
  || fail "#1182: assess.md A.8 must route host-config verification to the orchestrator parent-side (so an author stops writing worker-unverifiable criteria)"
K1182_PR_SH="$REPO_ROOT/workflows/scripts/build/pr.sh"
[ -f "$K1182_PR_SH" ] \
  || fail "#1182: workflows/scripts/build/pr.sh is missing — the PR-body consumer half of this contract cannot be verified"
grep -q 'deferred_host_config' "$K1182_PR_SH" \
  || fail "#1182: pr.sh's assemble_body recap must read .deferred_host_config — otherwise a deferral renders as a bare unchecked box, indistinguishable from a worker FAILURE"
K1182_WORKTREE_SH="$REPO_ROOT/workflows/scripts/build/worktree.sh"
[ -f "$K1182_WORKTREE_SH" ] \
  || fail "#1182: workflows/scripts/build/worktree.sh is missing — the no-carry half of this contract cannot be verified"
grep -q 'DO NOT GENERALIZE THIS INTO A HOST-CONFIG CARRY' "$K1182_WORKTREE_SH" \
  || fail "#1182: worktree.sh must carry the standing no-carry prohibition beside materialize_agents — the rejected 'allowlisted host-config carry' proposal must not be silently re-opened"
# The load-bearing half of the prohibition: no ACTIVE (non-comment) line in
# worktree.sh may copy a host-local config/secret file into the worktree.
# Comments naming build.config.local.sh are the documentation above; a real
# `cp`/`install` of one would be the exposure itself.
if grep -nE '^[[:space:]]*[^#[:space:]].*(\.env|\.local\.sh)' "$K1182_WORKTREE_SH" | grep -E '\b(cp|install|rsync|cat)\b' >/dev/null; then
  fail "#1182: worktree.sh has an ACTIVE line copying a host-local config/secret file into the worktree — that is the secret-in-worktree exposure /assess A.8 exists to prevent"
fi
echo "PASS: #1182 host-config deferral guard — the worker DEFERS (passed:false + deferred_host_config, never a claimed pass), a bare passed:false still escalates, park() tallies host_config_deferrals, EVERY consumer path has a parent-side seat (build.md §4a + §3h.5 exclusion, sweep.md per-chunk merge pass, fix.md Step 5), and assess.md A.8 / pr.sh / worktree.sh are in lockstep"

# ============================================================================
# TEST (K1430): §3e mandatory/routed pre-push review runs INSIDE driveItem —
#   the review is spawned by driveItem itself via agent({agentType}), never
#   delegated to the 3c worker (which cannot spawn a nested subagent at all).
#   Before this item the mandatory claude/commands/*.md -> workflow-reviewer
#   rule (foundation#1007) was worker-discretion prose with no code path to
#   discharge it — every command-doc PR reported a STRUCTURALLY GUARANTEED
#   "skipped — unavailable". These four cases exercise the real thing: a
#   mandatory run, a genuine unavailability degrade, a BLOCKING escalation,
#   and tsv-driven routing for a non-command-doc file.
# ============================================================================
run_node_case "K1430 mandatory: a claude/commands/*.md diff spawns workflow-reviewer directly (never via the worker), and a clean pass carries into the PR body" "
$PREAMBLE

setMachinery('cmd-md-item',
  { outcome: 'CREATED', path: '/tmp/repo.wt/cmd-md-item' },
  { outcome: 'REVIEW_DIFF', files: ['claude/commands/build.md'], tsv: '', tsv_rows: 0, tsv_checksum: 0 },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'acd11' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'acd11', branch: 'build/cmd-md-item' },
  { outcome: 'PR_OPENED', pr_number: 999 },
  { outcome: 'CI_GREEN' },
);
happyWorker('cmd-md-item');
setReview('cmd-md-item', '## Summary\\nAll good, no invariant violations.\\n\\n## Findings\\n(none)\\n');

globalThis.args = { ...baseArgs, items: [
  { slug: 'cmd-md-item', branch: 'build/cmd-md-item', title: 'Touch build.md', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();
let reason = null;
if ((result.parked ?? []).length !== 1) reason = 'expected 1 parked: ' + JSON.stringify(result);
else if ((result.escalations ?? []).length !== 0) reason = 'expected 0 escalations: ' + JSON.stringify(result.escalations);
const reviewCall = callLog.find(c => isReviewCall(c.opts));
if (!reason && !reviewCall) reason = 'no review agent() call spawned for a claude/commands/*.md diff — the mandatory rule never fired';
else if (!reason && reviewCall.opts.label !== 'review:cmd-md-item#workflow-reviewer')
  reason = 'unexpected review label: ' + reviewCall.opts.label;
else if (!reason && reviewCall.opts.agentType !== 'workflow-reviewer')
  reason = 'review agent() spawned with the wrong agentType: ' + reviewCall.opts.agentType;
if (!reason) {
  const prBatch = callLog.find(c => (c.opts.label||'').startsWith('pr-batch:cmd-md-item'));
  if (!prBatch) reason = 'no pr-batch call logged';
  else if (!prBatch.promptFull.includes('workflow-reviewer'))
    reason = 'the PR body-assembling command must carry evidence the review actually RAN (never a guaranteed default skip): ' + prBatch.promptFull.slice(0, 400);
}
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K1430 unavailable: reviewer resolution failure degrades legibly (never a hard fail, never silently invisible)" "
$PREAMBLE
const logged = [];
globalThis.log = (m) => logged.push(String(m));

setMachinery('unavail-item',
  { outcome: 'CREATED', path: '/tmp/repo.wt/unavail-item' },
  { outcome: 'REVIEW_DIFF', files: ['claude/commands/build.md'], tsv: '', tsv_rows: 0, tsv_checksum: 0 },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'a5d' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'a5d', branch: 'build/unavail-item' },
  { outcome: 'PR_OPENED', pr_number: 1000 },
  { outcome: 'CI_GREEN' },
);
happyWorker('unavail-item');
setReview('unavail-item', reviewUnavailable('workflow-reviewer'));

globalThis.args = { ...baseArgs, items: [
  { slug: 'unavail-item', branch: 'build/unavail-item', title: 'Touch build.md', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();
let reason = null;
if ((result.parked ?? []).length !== 1) reason = 'a genuinely unavailable reviewer must not block the item: ' + JSON.stringify(result);
else if ((result.escalations ?? []).length !== 0) reason = 'unavailability must degrade, never escalate: ' + JSON.stringify(result.escalations);
else if (!logged.some(m => m.includes('workflow-reviewer available as source; run workflows/scripts/install/project-agents.sh to enable')))
  reason = 'missing the remedy-bearing degradation notice (message-schema.md § Degradation notice): ' + JSON.stringify(logged);
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K1430 blocking: a HIGH finding escalates review-blocking BEFORE 3f push, never silently proceeds" "
$PREAMBLE

setMachinery('blocking-item',
  { outcome: 'CREATED', path: '/tmp/repo.wt/blocking-item' },
  { outcome: 'REVIEW_DIFF', files: ['claude/commands/build.md'], tsv: '', tsv_rows: 0, tsv_checksum: 0 },
);
happyWorker('blocking-item');
setReview('blocking-item', '## Summary\\n1 finding.\\n\\n## Findings\\n### [HIGH] Silent failure mode in claude/commands/build.md Step 3\\n**Where:** claude/commands/build.md — Step 3\\n**Issue:** x\\n');

globalThis.args = { ...baseArgs, items: [
  { slug: 'blocking-item', branch: 'build/blocking-item', title: 'Touch build.md', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();
let reason = null;
if ((result.parked ?? []).length !== 0) reason = 'a BLOCKING review finding must never park the item: ' + JSON.stringify(result);
else if ((result.escalations ?? []).length !== 1) reason = 'expected exactly 1 escalation: ' + JSON.stringify(result.escalations);
else if (result.escalations[0].kind !== 'review-blocking') reason = 'wrong escalation kind: ' + result.escalations[0].kind;
// temperloop#2135: the ONE named-by-string mapping entry — review-blocking is
// the sole kind that buckets to round_kind 'review'.
else if (result.escalations[0].round_kind !== 'review') reason = 'review-blocking round_kind must be review, got: ' + result.escalations[0].round_kind;
else {
  const prBatch = callLog.find(c => (c.opts.label||'').startsWith('pr-batch:blocking-item'));
  if (prBatch) reason = 'a blocking review must stop BEFORE 3f (push/PR) — pr-batch must never spawn: ' + JSON.stringify(prBatch.opts.label);
}
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K1430 routing: a tsv-matched extension routes to ITS reviewer (not workflow-reviewer, not docs-reviewer)" "
$PREAMBLE
const TAB = String.fromCharCode(9);
const tsv = '.py' + TAB + 'python-reviewer' + TAB + 'claude/agents/reviewers/python-reviewer.md\\n';

setMachinery('routed-item',
  { outcome: 'CREATED', path: '/tmp/repo.wt/routed-item' },
  { outcome: 'REVIEW_DIFF', files: ['workflows/scripts/foo.py'], tsv, tsv_rows: tsvRows(tsv), tsv_checksum: tsvChecksum(tsv) },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'a54' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'a54', branch: 'build/routed-item' },
  { outcome: 'PR_OPENED', pr_number: 1001 },
  { outcome: 'CI_GREEN' },
);
happyWorker('routed-item');
setReview('routed-item', '## Summary\\nclean\\n\\n## Findings\\n(none)\\n');

globalThis.args = { ...baseArgs, items: [
  { slug: 'routed-item', branch: 'build/routed-item', title: 'Touch a .py file', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();
let reason = null;
if ((result.parked ?? []).length !== 1) reason = 'expected 1 parked: ' + JSON.stringify(result);
const reviewCall = callLog.find(c => isReviewCall(c.opts));
if (!reason && (!reviewCall || reviewCall.opts.agentType !== 'python-reviewer'))
  reason = 'a .py-only diff must route via the tsv to python-reviewer, got: ' + JSON.stringify(reviewCall && reviewCall.opts.agentType);
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

# ============================================================================
# TEST (K1984): a routed-but-UNRUN reviewer is visible in the per-run tally.
#   determineReviewers() marks `mandatory: true` for workflow-reviewer on a
#   claude/commands/*.md diff and for NOTHING else, so before #1984 every
#   tsv-routed reviewer could resolve, be skipped, and still leave
#   `mandatory_ok: true` — the tally reading fully clean while the .sh diff
#   went unreviewed (six live instances across three items, temperloop#1982,
#   every one caught by a human reading the roster, never by the tally).
#   `routed_not_run` closes that: non-empty exactly when `skipped` is.
#   Two items in ONE level so the field is proven to DISCRIMINATE — the
#   skipped route lists its reviewer, the ran route lists nothing — and so
#   the assertion cannot pass on a field that is simply always non-empty.
#   mandatory_ok stays `true` on BOTH: neither diff touches a command doc, so
#   the foundation#1007 rule is untouched (ADR 0037 — visibility, not a gate).
# ============================================================================
run_node_case "K1984 routed-not-run: a skipped tsv-routed reviewer is named in the tally, while mandatory_ok stays scoped to the command-doc rule" "
$PREAMBLE
const TAB = String.fromCharCode(9);
const tsv = '.sh' + TAB + 'shell-reviewer' + TAB + 'claude/agents/reviewers/shell-reviewer.md\\n';

setMachinery('sh-unrun',
  { outcome: 'CREATED', path: '/tmp/repo.wt/sh-unrun' },
  { outcome: 'REVIEW_DIFF', files: ['workflows/scripts/thing.sh'], tsv, tsv_rows: tsvRows(tsv), tsv_checksum: tsvChecksum(tsv) },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'a5c' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'a5c', branch: 'build/sh-unrun' },
  { outcome: 'PR_OPENED', pr_number: 1984 },
  { outcome: 'CI_GREEN' },
);
happyWorker('sh-unrun');
setReview('sh-unrun', reviewUnavailable('shell-reviewer'));

setMachinery('sh-ran',
  { outcome: 'CREATED', path: '/tmp/repo.wt/sh-ran' },
  { outcome: 'REVIEW_DIFF', files: ['workflows/scripts/other.sh'], tsv, tsv_rows: tsvRows(tsv), tsv_checksum: tsvChecksum(tsv) },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'a4d' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'a4d', branch: 'build/sh-ran' },
  { outcome: 'PR_OPENED', pr_number: 1985 },
  { outcome: 'CI_GREEN' },
);
happyWorker('sh-ran');
setReview('sh-ran', '## Summary\\nclean\\n\\n## Findings\\n(none)\\n');

globalThis.args = { ...baseArgs, items: [
  { slug: 'sh-unrun', branch: 'build/sh-unrun', title: 'Touch a .sh file', kind: 'impl', acceptance: ['c'] },
  { slug: 'sh-ran', branch: 'build/sh-ran', title: 'Touch another .sh file', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();
const byslug = (s) => (result.parked ?? []).find(p => p.slug === s);
let reason = null;
if ((result.parked ?? []).length !== 2) reason = 'expected 2 parked (a skipped reviewer degrades, never blocks): ' + JSON.stringify(result);
const unrun = byslug('sh-unrun');
const ranrec = byslug('sh-ran');
if (!reason && (!unrun || !unrun.review)) reason = 'sh-unrun must park with a review tally: ' + JSON.stringify(unrun);
else if (!reason && unrun.review.skipped.length !== 1)
  reason = 'expected exactly 1 skipped route on sh-unrun: ' + JSON.stringify(unrun.review);
else if (!reason && JSON.stringify(unrun.review.routed_not_run) !== JSON.stringify(['shell-reviewer']))
  reason = '#1984: a routed-then-skipped shell-reviewer MUST be named in routed_not_run: ' + JSON.stringify(unrun.review);
else if (!reason && unrun.review.mandatory_ok !== true)
  reason = 'the foundation#1007 rule is command-doc-scoped — a .sh diff must NOT flip mandatory_ok: ' + JSON.stringify(unrun.review);
// The discriminator: the same field on the round where the SAME reviewer ran.
if (!reason && (!ranrec || !ranrec.review)) reason = 'sh-ran must park with a review tally: ' + JSON.stringify(ranrec);
else if (!reason && (ranrec.review.routed_not_run ?? null) === null)
  reason = '#1984: routed_not_run must be present on every tally, not only degraded ones: ' + JSON.stringify(ranrec.review);
else if (!reason && ranrec.review.routed_not_run.length !== 0)
  reason = 'a fully-run route must leave routed_not_run EMPTY (else the field discriminates nothing): ' + JSON.stringify(ranrec.review);
else if (!reason && ranrec.review.ran.length !== 1)
  reason = 'sh-ran must record its shell-reviewer as ran: ' + JSON.stringify(ranrec.review);
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

# Lockstep guard (the convention every feature in this suite follows, e.g. the
# K1982 block below): the behavioral case above proves routed_not_run
# DISCRIMINATES, this pins the field's existence in the .mjs so a rename or a
# revert fails loudly here rather than silently un-covering the case.
grep -q 'routed_not_run' "$MJS" \
  || fail "#1984: reviewTally() must emit routed_not_run — the visibility field naming every routed-but-unrun reviewer, so the tally cannot read fully clean while a routed reviewer was skipped (ADR 0037)"

# ============================================================================
# TEST (K1705): a Makefile-only diff routes to a reviewer through THIS SAME
#   resolution path — determineReviewers() reading the LIVE tracked
#   reviewer-routing.tsv, not a fixture restatement of it. Makefile has no
#   extension and no directory prefix, so before the tsv gained its
#   `**/Makefile` basename row it matched nothing at all and every one of its
#   41 changes in 90 days was pushed with no routed reviewer.
#   Deliberately reads the real tsv: this case is the guard that the ROW is
#   present, not merely that the matcher could handle one.
# ============================================================================
run_node_case "K1705 routing: a Makefile-only diff routes to shell-reviewer via the LIVE tsv basename row" "
$PREAMBLE
const tsv = readFileSync('$REPO_ROOT/workflows/scripts/config/reviewer-routing.tsv', 'utf8');

setMachinery('makefile-item',
  { outcome: 'CREATED', path: '/tmp/repo.wt/makefile-item' },
  { outcome: 'REVIEW_DIFF', files: ['Makefile'], tsv, tsv_rows: tsvRows(tsv), tsv_checksum: tsvChecksum(tsv) },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'a3a' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'a3a', branch: 'build/makefile-item' },
  { outcome: 'PR_OPENED', pr_number: 1705 },
  { outcome: 'CI_GREEN' },
);
happyWorker('makefile-item');
setReview('makefile-item', '## Summary\\nclean\\n\\n## Findings\\n(none)\\n');

globalThis.args = { ...baseArgs, items: [
  { slug: 'makefile-item', branch: 'build/makefile-item', title: 'Touch the Makefile', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();
let reason = null;
if ((result.parked ?? []).length !== 1) reason = 'expected 1 parked: ' + JSON.stringify(result);
const reviewCalls = callLog.filter(c => isReviewCall(c.opts));
if (!reason && reviewCalls.length !== 1)
  reason = 'a Makefile-only diff must route to exactly one reviewer, got: ' + JSON.stringify(reviewCalls.map(c => c.opts.agentType));
if (!reason && reviewCalls[0].opts.agentType !== 'shell-reviewer')
  reason = 'expected shell-reviewer, got: ' + JSON.stringify(reviewCalls[0].opts.agentType);
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

# DISCRIMINATION for the case above: strip the one basename row from the very
# same tsv text and the very same diff must route to NOBODY — proving the ROW
# is what routes it (and that this suite would go red if the row were dropped),
# not some incidental suffix match elsewhere in the table.
run_node_case "K1705 discrimination: with the basename row removed, the identical Makefile diff routes to no reviewer at all" "
$PREAMBLE
const live = readFileSync('$REPO_ROOT/workflows/scripts/config/reviewer-routing.tsv', 'utf8');
const stripped = live.split('\\n').filter(l => l.indexOf('**/Makefile') !== 0).join('\\n');
if (stripped === live) { console.log(JSON.stringify({ ok: false, reason: 'setup: no **/Makefile row found to strip — this case would be vacuous' })); }
else {
setMachinery('makefile-item',
  { outcome: 'CREATED', path: '/tmp/repo.wt/makefile-item' },
  { outcome: 'REVIEW_DIFF', files: ['Makefile'], tsv: stripped, tsv_rows: tsvRows(stripped), tsv_checksum: tsvChecksum(stripped) },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'a3a' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'a3a', branch: 'build/makefile-item' },
  { outcome: 'PR_OPENED', pr_number: 1705 },
  { outcome: 'CI_GREEN' },
);
happyWorker('makefile-item');

globalThis.args = { ...baseArgs, items: [
  { slug: 'makefile-item', branch: 'build/makefile-item', title: 'Touch the Makefile', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
await mod.default();
const reviewCalls = callLog.filter(c => isReviewCall(c.opts));
const reason = reviewCalls.length === 0 ? null
  : 'without the basename row nothing should route, got: ' + JSON.stringify(reviewCalls.map(c => c.opts.agentType));
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
}
"

# The basename key must match a BASENAME, never a bare suffix: an
# endsWith('Makefile') shortcut would also claim NotAMakefile and route an
# unrelated file to a reviewer chosen for this one. A nested Makefile at any
# depth DOES route.
run_node_case "K1705 precision: the basename key claims sub/dir/Makefile but never tools/NotAMakefile" "
$PREAMBLE
const tsv = readFileSync('$REPO_ROOT/workflows/scripts/config/reviewer-routing.tsv', 'utf8');

setMachinery('nested-item',
  { outcome: 'CREATED', path: '/tmp/repo.wt/nested-item' },
  { outcome: 'REVIEW_DIFF', files: ['sub/dir/Makefile'], tsv, tsv_rows: tsvRows(tsv), tsv_checksum: tsvChecksum(tsv) },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'a3f' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'a3f', branch: 'build/nested-item' },
  { outcome: 'PR_OPENED', pr_number: 1706 },
  { outcome: 'CI_GREEN' },
);
happyWorker('nested-item');
setReview('nested-item', 'clean');

setMachinery('suffix-item',
  { outcome: 'CREATED', path: '/tmp/repo.wt/suffix-item' },
  { outcome: 'REVIEW_DIFF', files: ['tools/NotAMakefile'], tsv, tsv_rows: tsvRows(tsv), tsv_checksum: tsvChecksum(tsv) },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'a55' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'a55', branch: 'build/suffix-item' },
  { outcome: 'PR_OPENED', pr_number: 1707 },
  { outcome: 'CI_GREEN' },
);
happyWorker('suffix-item');

globalThis.args = { ...baseArgs, items: [
  { slug: 'nested-item', branch: 'build/nested-item', title: 'Nested Makefile', kind: 'impl', acceptance: ['c'] },
  { slug: 'suffix-item', branch: 'build/suffix-item', title: 'Suffix lookalike', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
await mod.default();
const forSlug = (s) => callLog.filter(c => isReviewCall(c.opts) && String(c.opts.label).indexOf('review:' + s) === 0);
let reason = null;
const nested = forSlug('nested-item').map(c => c.opts.agentType);
const suffix = forSlug('suffix-item').map(c => c.opts.agentType);
if (nested.length !== 1 || nested[0] !== 'shell-reviewer')
  reason = 'sub/dir/Makefile must route to shell-reviewer, got: ' + JSON.stringify(nested);
else if (suffix.length !== 0)
  reason = 'tools/NotAMakefile must route to NOBODY (basename match, not suffix), got: ' + JSON.stringify(suffix);
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

# ============================================================================
# TEST (K1450): the CI-fix re-spawn does NOT bypass §3e. A CI-fix commit can
#   touch anything — including the very command doc whose edit tripped the
#   original lint failure — and ciPollLoop's CI_FAILED arm plain-pushes it
#   straight to the open PR. Neither of these live cases is exercised by the
#   four K1430 tests (all pre-CI) nor by the pre-existing CI-fail tests (which
#   predate §3e's existence and never touch review at all).
# ============================================================================
run_node_case "K1450 ci-fix clean: a CLEAN CI-fix commit still gets re-reviewed (two review rounds), and both land in the Step 6 tally" "
$PREAMBLE

setMachinery('cifix-clean',
  { outcome: 'CREATED', path: '/tmp/repo.wt/cifix-clean' },
  { outcome: 'REVIEW_DIFF', files: ['claude/commands/build.md'], tsv: '', tsv_rows: 0, tsv_checksum: 0 },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'a15e' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'a15e', branch: 'build/cifix-clean' },
  { outcome: 'PR_OPENED', pr_number: 700 },
  { outcome: 'CI_FAILED', failed_run_ids: [1] },
  // The re-review's OWN diff fetch — a SEPARATE machinery call from the first.
  { outcome: 'REVIEW_DIFF', files: ['claude/commands/build.md'], tsv: '', tsv_rows: 0, tsv_checksum: 0 },
  { outcome: 'PUSHED', sha: 'a25f', branch: 'build/cifix-clean' },
  { outcome: 'CI_GREEN' },
  // temperloop#1846: the fix round ran a reviewer, so 3g.5 re-renders the PR
  // body (pr-body-update solo call) with the merged review evidence.
  { outcome: 'BODY_UPDATED', pr_number: 700 },
);
setWorker('cifix-clean',
  { status: 'done', summary: 'initial', acceptance_results: [{ criterion: 'c', passed: true, evidence: 'e' }], commits: [] },
  { status: 'done', summary: 'ci fixed', acceptance_results: [], commits: [] },
);
setReview('cifix-clean',
  '## Summary\\nclean on the original push.\\n\\n## Findings\\n(none)\\n',
  '## Summary\\nclean on the CI-fix commit too.\\n\\n## Findings\\n(none)\\n',
);

globalThis.args = { ...baseArgs, items: [
  { slug: 'cifix-clean', branch: 'build/cifix-clean', title: 'CI-fix clean', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();
let reason = null;
if ((result.parked ?? []).length !== 1) reason = 'expected 1 parked: ' + JSON.stringify(result);
else if ((result.escalations ?? []).length !== 0) reason = 'expected 0 escalations: ' + JSON.stringify(result.escalations);
const reviewCalls = callLog.filter(c => isReviewCall(c.opts));
if (!reason && reviewCalls.length !== 2)
  reason = 'expected TWO review agent() calls (original push + CI-fix commit), got ' + reviewCalls.length + ': ' + JSON.stringify(reviewCalls.map(c => c.opts.label));
const rec = (result.parked ?? [])[0];
if (!reason && (!rec || !rec.review || rec.review.ran.length !== 2))
  reason = 'park() must carry BOTH review rounds in its review.ran tally (temperloop#1450): ' + JSON.stringify(rec && rec.review);
if (!reason && rec.review.mandatory_ok !== true)
  reason = 'a fully-run mandatory review must report mandatory_ok:true: ' + JSON.stringify(rec.review);
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K1450 ci-fix blocking: a HIGH finding on the CI-fix commit escalates review-blocking, never force-pushes the fix" "
$PREAMBLE

setMachinery('cifix-block',
  { outcome: 'CREATED', path: '/tmp/repo.wt/cifix-block' },
  { outcome: 'REVIEW_DIFF', files: ['claude/commands/build.md'], tsv: '', tsv_rows: 0, tsv_checksum: 0 },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'a15e' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'a15e', branch: 'build/cifix-block' },
  { outcome: 'PR_OPENED', pr_number: 701 },
  { outcome: 'CI_FAILED', failed_run_ids: [1] },
  { outcome: 'REVIEW_DIFF', files: ['claude/commands/build.md'], tsv: '', tsv_rows: 0, tsv_checksum: 0 },
  // Deliberately NO 'PUSHED' entry after this: if the code wrongly proceeds
  // past a blocking CI-fix review to push, the mock's queue is exhausted and
  // throws 'No mock entry' — a LOUD failure, never a silent pass-through.
);
setWorker('cifix-block',
  { status: 'done', summary: 'initial', acceptance_results: [{ criterion: 'c', passed: true, evidence: 'e' }], commits: [] },
  { status: 'done', summary: 'ci fixed', acceptance_results: [], commits: [] },
);
setReview('cifix-block',
  '## Summary\\nclean on the original push.\\n\\n## Findings\\n(none)\\n',
  '## Summary\\n1 finding.\\n\\n## Findings\\n### [HIGH] Silent failure mode introduced by the fix in claude/commands/build.md\\n',
);

globalThis.args = { ...baseArgs, items: [
  { slug: 'cifix-block', branch: 'build/cifix-block', title: 'CI-fix blocking', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();
let reason = null;
if ((result.parked ?? []).length !== 0) reason = 'a BLOCKING CI-fix review must never park the item: ' + JSON.stringify(result);
else if ((result.escalations ?? []).length !== 1) reason = 'expected exactly 1 escalation: ' + JSON.stringify(result.escalations);
else if (result.escalations[0].kind !== 'review-blocking') reason = 'wrong escalation kind: ' + result.escalations[0].kind;
else if (result.escalations[0].payload.stage !== 'ci-fix') reason = 'the escalation must name its stage as ci-fix: ' + JSON.stringify(result.escalations[0].payload);
if (!reason) {
  const retryPush = callLog.find(c => (c.opts.label||'').startsWith('push-retry:cifix-block'));
  if (retryPush) reason = 'a blocking CI-fix review must stop BEFORE the retry push — push-retry must never spawn: ' + JSON.stringify(retryPush.opts.label);
}
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

# --- K1450 static lockstep guard: the CI-fix path re-runs §3e ---------------
grep -q 'const fixReview = await runReviewers(item, wt);' "$MJS" \
  || fail "#1450: ciPollLoop's CI_FAILED arm must re-run runReviewers() against the CI-fix diff before the retry push"
# temperloop#1970 reflowed this return across several lines when it wrapped the
# escalation in the convergence bound, so the guard now pins the two halves that
# actually carry the contract (the kind, and that it ships fixReview.blocking)
# rather than one exact source line.
grep -q "escalation: 'review-blocking'," "$MJS" \
  || fail "#1450: a blocking CI-fix review must escalate review-blocking before the retry push, exactly like the original 3e pass"
grep -q 'findings: fixReview.blocking,' "$MJS" \
  || fail "#1450: the CI-fix review-blocking escalation must carry fixReview.blocking as its findings payload"
echo "PASS: #1450 ci-fix re-review guard — the CI_FAILED arm re-runs §3e against the fix commit before pushing it"

# ============================================================================
# TEST (K1846): a reviewer that ran only in the CI-FIX round reaches the PR
#   body. Before this item the body suffix was rendered ONCE at 3f from the
#   original §3e round, while park()'s tally merged every round — so on PR
#   #1845 shell-reviewer's three findings existed in the journal and in
#   review.ran, yet the body affirmatively read "ran: docs-reviewer" and
#   carried only docs-reviewer's section. The 3g.5 re-render must hand pr.sh
#   `open --update-pr` a body whose §3e line is the ROUND-UNION of reviewers
#   (never a subset of review.ran) and whose ## Review notes splices EVERY ran
#   reviewer's findings — a repeat reviewer keeps BOTH blocks, relabeled
#   `(ci-fix round N)`, never de-duped/last-writer-wins away.
# ============================================================================
run_node_case "K1846 two-reviewer body: a CI-fix round's shell-reviewer findings land in the PR body (ran-line union + spliced sections)" "
$PREAMBLE
const TAB = String.fromCharCode(9);
const tsv = '.sh' + TAB + 'shell-reviewer' + TAB + 'claude/agents/reviewers/shell-reviewer.md\\n';

setMachinery('two-rev',
  { outcome: 'CREATED', path: '/tmp/repo.wt/two-rev' },
  // Original round: an .md-only diff — docs-reviewer alone.
  { outcome: 'REVIEW_DIFF', files: ['docs/notes.md'], tsv: '', tsv_rows: 0, tsv_checksum: 0 },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'a15e' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'a15e', branch: 'build/two-rev' },
  { outcome: 'PR_OPENED', pr_number: 1846 },
  { outcome: 'CI_FAILED', failed_run_ids: [1] },
  // CI-fix round: the fix touches a .sh file too — docs-reviewer AND
  // shell-reviewer (tsv-routed) both run against the fix diff.
  { outcome: 'REVIEW_DIFF', files: ['docs/notes.md', 'workflows/scripts/thing.sh'], tsv, tsv_rows: tsvRows(tsv), tsv_checksum: tsvChecksum(tsv) },
  { outcome: 'PUSHED', sha: 'a25f', branch: 'build/two-rev' },
  { outcome: 'CI_GREEN' },
  // 3g.5 re-render (the fix under test): pr.sh open --update-pr.
  { outcome: 'BODY_UPDATED', pr_number: 1846 },
);
setWorker('two-rev',
  { status: 'done', summary: 'initial', acceptance_results: [{ criterion: 'c', passed: true, evidence: 'e' }], commits: [] },
  { status: 'done', summary: 'ci fixed', acceptance_results: [], commits: [] },
);
setReview('two-rev',
  '## docs r1\\nprose fine.\\n',
  '## docs r2\\nprose still fine.\\n',
  '## shell findings\\n### [MEDIUM] pipe-fed rc capture\\nreal finding text.\\n',
);

globalThis.args = { ...baseArgs, items: [
  { slug: 'two-rev', branch: 'build/two-rev', title: 'Two reviewers', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();
let reason = null;
if ((result.parked ?? []).length !== 1) reason = 'expected 1 parked: ' + JSON.stringify(result);
else if ((result.escalations ?? []).length !== 0) reason = 'expected 0 escalations: ' + JSON.stringify(result.escalations);
const rec = (result.parked ?? [])[0];
if (!reason && (!rec.review || rec.review.ran.length !== 3))
  reason = 'tally must carry all three ran entries (docs, docs, shell): ' + JSON.stringify(rec && rec.review);
const upd = callLog.find(c => (c.opts.label||'') === 'pr-body-update:two-rev');
if (!reason && !upd)
  reason = 'no pr-body-update call — the CI-fix round reviewer evidence never re-rendered into the PR body (the #1846 drop)';
if (!reason && !upd.promptFull.includes('--update-pr'))
  reason = 'body re-render must go through pr.sh open --update-pr (shared assemble_body path): ' + upd.promptFull.slice(0, 300);
if (!reason && !upd.promptFull.includes('ran: docs-reviewer, shell-reviewer'))
  reason = 'the re-rendered §3e line must name the ROUND-UNION of ran reviewers, never a subset of review.ran: ' + upd.promptFull.slice(0, 600);
if (!reason && !upd.promptFull.includes('shell-reviewer (ci-fix round 1)'))
  reason = 'shell-reviewer findings section missing (or unlabeled) in the re-rendered body: ' + upd.promptFull.slice(0, 600);
if (!reason && !upd.promptFull.includes('real finding text'))
  reason = 'shell-reviewer FINDINGS text must be spliced into the body, not just its name';
if (!reason && !(upd.promptFull.includes('### docs-reviewer') && upd.promptFull.includes('docs-reviewer (ci-fix round 1)')))
  reason = 'a reviewer that ran in BOTH rounds must keep BOTH sections (no de-dup/last-writer-wins): ' + upd.promptFull.slice(0, 600);
// The ORIGINAL 3f body (pr-batch) must be unchanged by this fix: round-1 only.
const prBatch = callLog.find(c => (c.opts.label||'').startsWith('pr-batch:two-rev'));
if (!reason && prBatch && prBatch.promptFull.includes('shell-reviewer'))
  reason = '3f body must render only the rounds that have RUN by push time (shell-reviewer had not yet)';
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

# TEST (K1846 no-op): a CI-fix round that routes NO reviewer adds no evidence,
#   so 3g.5 must SKIP the body update entirely (no pr-body-update call) — the
#   common path costs nothing and older CI-fix tests' machinery queues stay
#   valid as-is.
run_node_case "K1846 no-op: an empty CI-fix review round skips the body re-render" "
$PREAMBLE

setMachinery('norev-fix',
  { outcome: 'CREATED', path: '/tmp/repo.wt/norev-fix' },
  { outcome: 'REVIEW_DIFF', files: ['docs/notes.md'], tsv: '', tsv_rows: 0, tsv_checksum: 0 },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'a15e' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'a15e', branch: 'build/norev-fix' },
  { outcome: 'PR_OPENED', pr_number: 1847 },
  { outcome: 'CI_FAILED', failed_run_ids: [1] },
  // CI-fix round routes nothing (no files in the fix diff match any axis).
  { outcome: 'REVIEW_DIFF', files: [] },
  { outcome: 'PUSHED', sha: 'a25f', branch: 'build/norev-fix' },
  { outcome: 'CI_GREEN' },
  // Deliberately NO BODY_UPDATED entry: if 3g.5 wrongly fires, the solo-call
  // fallback returns ERROR and the assertion below catches the spurious call.
);
setWorker('norev-fix',
  { status: 'done', summary: 'initial', acceptance_results: [{ criterion: 'c', passed: true, evidence: 'e' }], commits: [] },
  { status: 'done', summary: 'ci fixed', acceptance_results: [], commits: [] },
);
setReview('norev-fix', '## docs r1\\nfine.\\n');

globalThis.args = { ...baseArgs, items: [
  { slug: 'norev-fix', branch: 'build/norev-fix', title: 'No-reviewer fix round', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();
let reason = null;
if ((result.parked ?? []).length !== 1) reason = 'expected 1 parked: ' + JSON.stringify(result);
const upd = callLog.find(c => (c.opts.label||'') === 'pr-body-update:norev-fix');
if (!reason && upd)
  reason = 'an evidence-free CI-fix round must not trigger a body re-render (identical suffix → skip)';
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

# --- K1846 static lockstep guard: ONE renderer for both body surfaces --------
grep -q 'const reviewSummarySuffix = reviewBodySuffix(\[review\]);' "$MJS" \
  || fail "#1846: 3f's body suffix must render through reviewBodySuffix — the same renderer 3g.5 uses, or the two surfaces drift"
grep -q 'reviewBodySuffix(\[review, ...fixRounds\])' "$MJS" \
  || fail "#1846: 3g.5 must merge EVERY review round (original + CI-fix) through reviewBodySuffix before updating the PR body"
grep -q -- '--update-pr' "$MJS" \
  || fail "#1846: the 3g.5 re-render must go through pr.sh open --update-pr (the shared assemble_body path), never regex surgery on the live body"
echo "PASS: #1846 review-evidence re-render guard — one renderer for 3f and 3g.5, re-render via pr.sh open --update-pr"

# ============================================================================
# TEST (K1976): the review-diff relay can drop the reviewer-routing tsv while
#   leaving `files` intact (evidence: wf_cbc556f5-7be — a REVIEW_DIFF result
#   with files but no `tsv` key at all ran only docs-reviewer, never the
#   shell-reviewer a later run of the SAME item routed to via an intact tsv).
#   reviewDiffCmd now also emits `tsv_rows`, computed off the worktree file
#   itself; runReviewers treats a missing table or a received-row-count
#   disagreeing with `tsv_rows` as a relay drop on any non-empty `files` diff
#   and re-runs the SAME review-diff command once.
#
#   temperloop#2020 changed only what happens AFTER that retry still comes back
#   incomplete: the item DEGRADES (no reviewer routed, a legible skip notice on
#   the PR body) instead of escalating `review-diff-error`. The detectors below
#   are unchanged — every case still asserts the gap is SEEN, the retry fires
#   exactly once, and NO roster is ever computed from a missing/partial table.
#   A worktree that genuinely ships no tsv (`tsv_lines: []`/`tsv:''`,
#   `tsv_rows:0`) is unaffected — 0 rows is a COMPLETE table, not a dropped one.
# ============================================================================
run_node_case "K1976/K2020 drop: REVIEW_DIFF with no table on a non-empty .sh diff retries once, then DEGRADES (no escalation, no reviewer roster) with a legible skip notice" "
$PREAMBLE

setMachinery('droptsv-a',
  { outcome: 'CREATED', path: '/tmp/repo.wt/droptsv-a' },
  { outcome: 'REVIEW_DIFF', files: ['workflows/scripts/state-graph.sh'] },
  { outcome: 'REVIEW_DIFF', files: ['workflows/scripts/state-graph.sh'] },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'ada19' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'ada19', branch: 'build/droptsv-a' },
  { outcome: 'PR_OPENED', pr_number: 2020 },
  { outcome: 'CI_GREEN' },
);
happyWorker('droptsv-a');

globalThis.args = { ...baseArgs, items: [
  { slug: 'droptsv-a', branch: 'build/droptsv-a', title: 'Touch a shell script', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();
let reason = null;
const diffCalls = callLog.filter(c => (c.opts.label||'').startsWith('review-diff:droptsv-a'));
if (diffCalls.length !== 2) reason = 'expected exactly one retry (2 review-diff calls total), got ' + diffCalls.length;
else if ((result.escalations ?? []).length !== 0) reason = 'K2020: a dropped table must DEGRADE, never halt a drive whose work is complete: ' + JSON.stringify(result.escalations);
else if ((result.parked ?? []).length !== 1) reason = 'expected the item to park (drive completed): ' + JSON.stringify(result);
const rec = (result.parked ?? [])[0];
if (!reason && (!rec.review || (rec.review.ran ?? []).length !== 0)) reason = 'no reviewer roster may ever be computed from a dropped table: ' + JSON.stringify(rec && rec.review);
if (!reason && !(rec.review.skipped ?? []).some(s => /^skipped — /.test(s.note) && /routing unavailable/.test(s.note)))
  reason = 'the degradation must be LEGIBLE — a mode-2 skip notice naming that no reviewer was routed: ' + JSON.stringify(rec.review);
const reviewCalls = callLog.filter(c => isReviewCall(c.opts));
if (!reason && reviewCalls.length !== 0) reason = 'no reviewer may be spawned from a dropped table: ' + JSON.stringify(reviewCalls.map(c => c.opts.agentType));
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

# ============================================================================
# TEST (K2020 round 2 — THE MANDATORY ROUTE SURVIVES A TABLE GAP): every drop/
#   garble case in this file pairs a broken table with a `.sh`/`.py` diff, i.e.
#   with routes that genuinely need the table. That left the most dangerous
#   pairing untested. determineReviewers()'s mandatory command-doc rule
#   (foundation#1007) is computed PURELY from `files` — the field that relays
#   reliably — and fires regardless of any tsv row; the table is needed only by
#   the extension axis and the prose-`*.md` fallback. A degraded arm that
#   withdrew ALL routing therefore reported a `claude/commands/*.md` diff as
#   `mandatory_ok: true` with workflow-reviewer never run — byte-identical to a
#   clean pass, which is the K.49 / foundation#164 silent-skip class and the
#   K.52 mandatory-step birth rule reintroduced through this very fallback.
#   Two arms, because `mandatory_ok` has to track reality in BOTH directions:
#     1  the reviewer is available  -> it RUNS, mandatory_ok stays true HONESTLY
#     2  the reviewer is unavailable -> mandatory_ok goes FALSE, as it would on
#                                       an intact table
#   Both also assert the extension-axis route (`.sh` -> shell-reviewer) is
#   still withdrawn — the degradation is partial, not cancelled.
# ============================================================================
run_node_case "K2020 mandatory survives a gap: a DROPPED table on a diff touching claude/commands/*.md still routes and RUNS workflow-reviewer (the rule never needed the table), while the .sh extension-axis route stays withdrawn" "
$PREAMBLE

setMachinery('gapcmddoc-a',
  { outcome: 'CREATED', path: '/tmp/repo.wt/gapcmddoc-a' },
  { outcome: 'REVIEW_DIFF', files: ['claude/commands/build.md', 'workflows/scripts/state-graph.sh'] },
  { outcome: 'REVIEW_DIFF', files: ['claude/commands/build.md', 'workflows/scripts/state-graph.sh'] },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'acd22' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'acd22', branch: 'build/gapcmddoc-a' },
  { outcome: 'PR_OPENED', pr_number: 2021 },
  { outcome: 'CI_GREEN' },
);
happyWorker('gapcmddoc-a');
setReview('gapcmddoc-a', '## Summary\\nno findings\\n');

globalThis.args = { ...baseArgs, items: [
  { slug: 'gapcmddoc-a', branch: 'build/gapcmddoc-a', title: 'Touch a command doc and a shell script', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();
let reason = null;
const diffCalls = callLog.filter(c => (c.opts.label||'').startsWith('review-diff:gapcmddoc-a'));
const reviewCalls = callLog.filter(c => isReviewCall(c.opts));
if (diffCalls.length !== 2) reason = 'the gap detectors must be unchanged — exactly one retry, got ' + diffCalls.length + ' review-diff calls';
else if ((result.escalations ?? []).length !== 0) reason = 'a dropped table must still DEGRADE, never halt: ' + JSON.stringify(result.escalations);
else if ((result.parked ?? []).length !== 1) reason = 'expected the item to park: ' + JSON.stringify(result);
const rec = (result.parked ?? [])[0];
if (!reason && !(rec.review.ran ?? []).some(r => r.reviewer === 'workflow-reviewer'))
  reason = 'THE ACCEPTANCE: the MANDATORY command-doc route is computed from files, never from the table — it must still RUN on a dropped relay: ' + JSON.stringify(rec.review);
if (!reason && !(rec.review.ran ?? []).some(r => r.reviewer === 'workflow-reviewer' && r.mandatory === true))
  reason = 'the surviving route must still be flagged mandatory, or reviewTally cannot tell a real pass from an optional one: ' + JSON.stringify(rec.review.ran);
if (!reason && rec.review.mandatory_ok !== true)
  reason = 'mandatory_ok must read true HONESTLY here — the reviewer actually ran: ' + JSON.stringify(rec.review);
if (!reason && (rec.review.ran ?? []).some(r => r.reviewer === 'shell-reviewer'))
  reason = 'the extension-axis route DOES need the table — it must stay withdrawn, never guessed: ' + JSON.stringify(rec.review.ran);
if (!reason && !reviewCalls.some(c => c.opts.agentType === 'workflow-reviewer'))
  reason = 'the mandatory reviewer must actually be SPAWNED, not merely listed: ' + JSON.stringify(reviewCalls.map(c => c.opts.agentType));
if (!reason && reviewCalls.length !== 1)
  reason = 'exactly one reviewer (the table-independent one) may be spawned from a dropped table: ' + JSON.stringify(reviewCalls.map(c => c.opts.agentType));
if (!reason && !rec.review.routing_degraded)
  reason = 'the degradation must still be recorded — a partially-routed roster is not a clean one: ' + JSON.stringify(rec.review);
if (!reason && !(rec.review.skipped ?? []).some(s => /^skipped — /.test(s.note) && /routing unavailable/.test(s.note)))
  reason = 'the withdrawn axes must still be named in a mode-2 skip notice: ' + JSON.stringify(rec.review.skipped);
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K2020 mandatory honesty on a gap: when workflow-reviewer is UNAVAILABLE the same dropped-table command-doc diff reports mandatory_ok FALSE — the degraded arm may never launder a real mandatory skip into a clean tally" "
$PREAMBLE

setMachinery('gapcmddoc-b',
  { outcome: 'CREATED', path: '/tmp/repo.wt/gapcmddoc-b' },
  { outcome: 'REVIEW_DIFF', files: ['claude/commands/fix.md'] },
  { outcome: 'REVIEW_DIFF', files: ['claude/commands/fix.md'] },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'acdb23' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'acdb23', branch: 'build/gapcmddoc-b' },
  { outcome: 'PR_OPENED', pr_number: 2022 },
  { outcome: 'CI_GREEN' },
);
happyWorker('gapcmddoc-b');
setReview('gapcmddoc-b', reviewUnavailable('workflow-reviewer'));

globalThis.args = { ...baseArgs, items: [
  { slug: 'gapcmddoc-b', branch: 'build/gapcmddoc-b', title: 'Touch a command doc', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();
let reason = null;
if ((result.parked ?? []).length !== 1) reason = 'expected the item to park: ' + JSON.stringify(result);
const rec = (result.parked ?? [])[0];
if (!reason && rec.review.mandatory_ok !== false)
  reason = 'THE ACCEPTANCE: a genuinely-skipped mandatory reviewer must read mandatory_ok:false even on a degraded relay — the tally is a real signal, not a default: ' + JSON.stringify(rec.review);
if (!reason && !(rec.review.skipped ?? []).some(s => s.reviewer === 'workflow-reviewer' && s.mandatory === true))
  reason = 'the mandatory route must be recorded as a mandatory SKIP, which is what makes mandatory_ok false: ' + JSON.stringify(rec.review.skipped);
if (!reason && !(rec.review.routed_not_run ?? []).includes('workflow-reviewer'))
  reason = 'a resolved-then-skipped reviewer must appear in routed_not_run: ' + JSON.stringify(rec.review);
if (!reason && !rec.review.routing_degraded)
  reason = 'the routing degradation must still be carried alongside the mandatory skip: ' + JSON.stringify(rec.review);
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"


run_node_case "K1976 recovered: a retry that returns a complete tsv routes normally — shell-reviewer runs, no escalation" "
$PREAMBLE
const TAB = String.fromCharCode(9);
const tsv = '.sh' + TAB + 'shell-reviewer' + TAB + 'claude/agents/reviewers/shell-reviewer.md\\n';

setMachinery('droptsv-b',
  { outcome: 'CREATED', path: '/tmp/repo.wt/droptsv-b' },
  { outcome: 'REVIEW_DIFF', files: ['workflows/scripts/state-graph.sh'] },
  { outcome: 'REVIEW_DIFF', files: ['workflows/scripts/state-graph.sh'], tsv, tsv_rows: tsvRows(tsv), tsv_checksum: tsvChecksum(tsv) },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'adb1a' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'adb1a', branch: 'build/droptsv-b' },
  { outcome: 'PR_OPENED', pr_number: 1976 },
  { outcome: 'CI_GREEN' },
);
happyWorker('droptsv-b');
setReview('droptsv-b', '## Summary\\nclean\\n\\n## Findings\\n(none)\\n');

globalThis.args = { ...baseArgs, items: [
  { slug: 'droptsv-b', branch: 'build/droptsv-b', title: 'Touch a shell script', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();
let reason = null;
const diffCalls = callLog.filter(c => (c.opts.label||'').startsWith('review-diff:droptsv-b'));
if (diffCalls.length !== 2) reason = 'expected exactly one retry (2 review-diff calls total), got ' + diffCalls.length;
else if ((result.parked ?? []).length !== 1) reason = 'expected 1 parked once the retry recovers a complete tsv: ' + JSON.stringify(result);
else if ((result.escalations ?? []).length !== 0) reason = 'a recovered retry must never escalate: ' + JSON.stringify(result.escalations);
const rec = (result.parked ?? [])[0];
if (!reason && (!rec.review || !rec.review.ran.some(r => r.reviewer === 'shell-reviewer')))
  reason = 'shell-reviewer must have run once the retry recovered a complete tsv: ' + JSON.stringify(rec && rec.review);
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K1976 mismatch: tsv present but tsv_rows disagrees with its own row count follows the SAME retry-then-escalate path as a missing tsv" "
$PREAMBLE
const TAB = String.fromCharCode(9);
const tsv = '.py' + TAB + 'python-reviewer' + TAB + 'claude/agents/reviewers/python-reviewer.md\\n' +
            '.rb' + TAB + 'ruby-reviewer' + TAB + 'claude/agents/reviewers/ruby-reviewer.md\\n';

setMachinery('droptsv-c',
  { outcome: 'CREATED', path: '/tmp/repo.wt/droptsv-c' },
  { outcome: 'REVIEW_DIFF', files: ['workflows/scripts/foo.py'], tsv, tsv_rows: 0 },
  { outcome: 'REVIEW_DIFF', files: ['workflows/scripts/foo.py'], tsv, tsv_rows: 0 },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'adc1b' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'adc1b', branch: 'build/droptsv-c' },
  { outcome: 'PR_OPENED', pr_number: 2021 },
  { outcome: 'CI_GREEN' },
);
happyWorker('droptsv-c');

globalThis.args = { ...baseArgs, items: [
  { slug: 'droptsv-c', branch: 'build/droptsv-c', title: 'Touch a python file', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();
let reason = null;
const diffCalls = callLog.filter(c => (c.opts.label||'').startsWith('review-diff:droptsv-c'));
if (diffCalls.length !== 2) reason = 'expected exactly one retry (2 review-diff calls total), got ' + diffCalls.length;
else if ((result.escalations ?? []).length !== 0) reason = 'K2020: a persistent row-count mismatch must DEGRADE, not halt: ' + JSON.stringify(result.escalations);
else if ((result.parked ?? []).length !== 1) reason = 'expected the item to park (drive completed): ' + JSON.stringify(result);
const reviewCalls = callLog.filter(c => isReviewCall(c.opts));
if (!reason && reviewCalls.length !== 0) reason = 'no reviewer roster may ever be computed from a mismatched tsv: ' + JSON.stringify(reviewCalls.map(c => c.opts.agentType));
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K1976/K2020 mismatch (tsv_rows absent): a table with no tsv_rows key follows the same retry-then-DEGRADE path, and the parked record's routing_degraded keeps 'got' as null through JSON serialization rather than vanishing as undefined" "
$PREAMBLE
const TAB = String.fromCharCode(9);
const tsv = '.py' + TAB + 'python-reviewer' + TAB + 'claude/agents/reviewers/python-reviewer.md\\n';

setMachinery('droptsv-cc',
  { outcome: 'CREATED', path: '/tmp/repo.wt/droptsv-cc' },
  { outcome: 'REVIEW_DIFF', files: ['workflows/scripts/foo.py'], tsv },
  { outcome: 'REVIEW_DIFF', files: ['workflows/scripts/foo.py'], tsv },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'adcc1c' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'adcc1c', branch: 'build/droptsv-cc' },
  { outcome: 'PR_OPENED', pr_number: 2022 },
  { outcome: 'CI_GREEN' },
);
happyWorker('droptsv-cc');

globalThis.args = { ...baseArgs, items: [
  { slug: 'droptsv-cc', branch: 'build/droptsv-cc', title: 'Touch a python file', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();
let reason = null;
const diffCalls = callLog.filter(c => (c.opts.label||'').startsWith('review-diff:droptsv-cc'));
if (diffCalls.length !== 2) reason = 'expected exactly one retry (2 review-diff calls total), got ' + diffCalls.length;
else if ((result.escalations ?? []).length !== 0) reason = 'K2020: this must DEGRADE, not halt: ' + JSON.stringify(result.escalations);
else if ((result.parked ?? []).length !== 1) reason = 'expected the item to park: ' + JSON.stringify(result);
else {
  const serialized = JSON.parse(JSON.stringify(result.parked[0].review));
  const deg = serialized.routing_degraded;
  if (!deg) reason = 'the parked record must carry the gap payload behind the degradation: ' + JSON.stringify(serialized);
  else {
    const mm = deg.mismatch;
    if (!mm || !('got' in mm) || mm.got !== null) reason = 'got must survive JSON serialization as null, never vanish as undefined: ' + JSON.stringify(deg);
    else if (mm.expected !== 1) reason = 'expected must still be the real row count: ' + JSON.stringify(deg);
    else if (!Array.isArray(deg.files) || deg.files[0] !== 'workflows/scripts/foo.py') reason = 'the gap payload must carry the changed-file list it would have routed: ' + JSON.stringify(deg);
  }
}
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K1976 no-tsv worktree: tsv:'' with tsv_rows:0 on a .md diff is COMPLETE, not dropped — docs-reviewer runs once, no retry, no escalation" "
$PREAMBLE

setMachinery('droptsv-d',
  { outcome: 'CREATED', path: '/tmp/repo.wt/droptsv-d' },
  { outcome: 'REVIEW_DIFF', files: ['docs/plain.md'], tsv: '', tsv_rows: 0, tsv_checksum: 0 },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'add1d' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'add1d', branch: 'build/droptsv-d' },
  { outcome: 'PR_OPENED', pr_number: 1977 },
  { outcome: 'CI_GREEN' },
);
happyWorker('droptsv-d');
setReview('droptsv-d', '## Summary\\nclean\\n\\n## Findings\\n(none)\\n');

globalThis.args = { ...baseArgs, items: [
  { slug: 'droptsv-d', branch: 'build/droptsv-d', title: 'Touch a doc', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();
let reason = null;
const diffCalls = callLog.filter(c => (c.opts.label||'').startsWith('review-diff:droptsv-d'));
if (diffCalls.length !== 1) reason = 'a genuinely empty tsv must never trigger a retry: ' + diffCalls.length;
else if ((result.parked ?? []).length !== 1) reason = 'expected 1 parked: ' + JSON.stringify(result);
else if ((result.escalations ?? []).length !== 0) reason = 'expected 0 escalations: ' + JSON.stringify(result.escalations);
const reviewCalls = callLog.filter(c => isReviewCall(c.opts));
if (!reason && (reviewCalls.length !== 1 || reviewCalls[0].opts.agentType !== 'docs-reviewer'))
  reason = 'expected exactly docs-reviewer to run via the prose fallback, got: ' + JSON.stringify(reviewCalls.map(c => c.opts.agentType));
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

# ============================================================================
# TEST (K1982): PATH B — a row-count-VALID but content-corrupted tsv. The
#   temperloop#1976 guard above (reviewDiffTsvGap) is a ROW-COUNT check only;
#   it cannot see a relay copy that reproduces the right LENGTH table with the
#   WRONG rows. Observed live (temperloop#1978 round 4): the escalation kind
#   was `review-blocking`, not `review-diff-error` — the row-count check
#   PASSED (tsv present, row count matched) — yet a diff touching four `.sh`
#   files ran docs-reviewer ONLY; shell-reviewer never spawned. Root cause
#   probe (direct, before this fix was built): parseTsvRows()/reviewGlobMatch()
#   were run against this repo's REAL reviewer-routing.tsv and correctly
#   produced 11 rows matching a `.sh` file to shell-reviewer — the routing
#   LOGIC was never the defect; only a garbled RELAY COPY explains the
#   observed roster. `tsv_checksum` (reviewDiffCmd/tsvChecksum, above) closes
#   this: a content check needing no hashing primitive, recomputable from the
#   RECEIVED `tsv` string and compared against the reliably-short relayed
#   scalar exactly like `tsv_rows` already is.
# ============================================================================
run_node_case "K1982/K2020 content-mismatch: row count agrees but content disagrees — retries once, then DEGRADES naming the checksum gap, no reviewer roster ever computed (temperloop#1978 round 4 shape)" "
$PREAMBLE
const TAB = String.fromCharCode(9);
const realTsv = '.sh' + TAB + 'shell-reviewer' + TAB + 'claude/agents/reviewers/shell-reviewer.md\\n';
// Same row COUNT as realTsv (one data row) but a DIFFERENT reviewer — models
// a relay that reproduced a plausible-length table that was not the real
// one, never a dropped/truncated field (that is K1976's path A, above).
const corruptTsv = '.sh' + TAB + 'docs-reviewer' + TAB + 'claude/agents/docs-reviewer.md\\n';
if (tsvRows(corruptTsv) !== tsvRows(realTsv)) {
  console.log(JSON.stringify({ ok: false, reason: 'setup: corruptTsv must share realTsv row count or this case tests path A, not path B' }));
} else {

setMachinery('contentgarble-a',
  { outcome: 'CREATED', path: '/tmp/repo.wt/contentgarble-a' },
  // tsv_checksum is the relayed SOURCE-FILE checksum (realTsv) — reliable,
  // like tsv_rows. tsv itself is the corrupted content the relay actually
  // delivered. tsv_rows agrees (by construction) so the K1976 guard is silent.
  { outcome: 'REVIEW_DIFF', files: ['workflows/scripts/foo.sh'], tsv: corruptTsv, tsv_rows: tsvRows(corruptTsv), tsv_checksum: tsvChecksum(realTsv) },
  { outcome: 'REVIEW_DIFF', files: ['workflows/scripts/foo.sh'], tsv: corruptTsv, tsv_rows: tsvRows(corruptTsv), tsv_checksum: tsvChecksum(realTsv) },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'aca0c' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'aca0c', branch: 'build/contentgarble-a' },
  { outcome: 'PR_OPENED', pr_number: 2023 },
  { outcome: 'CI_GREEN' },
);
happyWorker('contentgarble-a');

globalThis.args = { ...baseArgs, items: [
  { slug: 'contentgarble-a', branch: 'build/contentgarble-a', title: 'Touch a shell script', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();
let reason = null;
const diffCalls = callLog.filter(c => (c.opts.label||'').startsWith('review-diff:contentgarble-a'));
if (diffCalls.length !== 2) reason = 'expected exactly one retry (2 review-diff calls total), got ' + diffCalls.length;
else if ((result.escalations ?? []).length !== 0) reason = 'K2020: a persistent content mismatch must DEGRADE, not halt: ' + JSON.stringify(result.escalations);
else if ((result.parked ?? []).length !== 1) reason = 'expected the item to park: ' + JSON.stringify(result);
else {
  const payload = result.parked[0].review.routing_degraded;
  const cm = payload && payload.content_mismatch;
  if (!cm || typeof cm.expected !== 'number' || cm.expected === cm.got) reason = 'the degradation payload must name a real checksum disagreement: ' + JSON.stringify(payload);
  else if (!Array.isArray(payload.files) || payload.files[0] !== 'workflows/scripts/foo.sh') reason = 'the degradation payload must carry the changed-file list: ' + JSON.stringify(payload);
  else if (payload.mismatch) reason = 'a row-count-VALID case must never carry the row-count mismatch field too: ' + JSON.stringify(payload);
}
const reviewCalls = callLog.filter(c => isReviewCall(c.opts));
if (!reason && reviewCalls.length !== 0) reason = 'no reviewer roster may ever be computed from a content-garbled tsv, even with a matching row count: ' + JSON.stringify(reviewCalls.map(c => c.opts.agentType));
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
}
"

run_node_case "K1982 content-mismatch recovered: a retry that returns the REAL (checksum-matching) tsv routes normally — shell-reviewer runs, no escalation" "
$PREAMBLE
const TAB = String.fromCharCode(9);
const realTsv = '.sh' + TAB + 'shell-reviewer' + TAB + 'claude/agents/reviewers/shell-reviewer.md\\n';
const corruptTsv = '.sh' + TAB + 'docs-reviewer' + TAB + 'claude/agents/docs-reviewer.md\\n';

setMachinery('contentgarble-b',
  { outcome: 'CREATED', path: '/tmp/repo.wt/contentgarble-b' },
  { outcome: 'REVIEW_DIFF', files: ['workflows/scripts/foo.sh'], tsv: corruptTsv, tsv_rows: tsvRows(corruptTsv), tsv_checksum: tsvChecksum(realTsv) },
  { outcome: 'REVIEW_DIFF', files: ['workflows/scripts/foo.sh'], tsv: realTsv, tsv_rows: tsvRows(realTsv), tsv_checksum: tsvChecksum(realTsv) },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'acb0d' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'acb0d', branch: 'build/contentgarble-b' },
  { outcome: 'PR_OPENED', pr_number: 1982 },
  { outcome: 'CI_GREEN' },
);
happyWorker('contentgarble-b');
setReview('contentgarble-b', '## Summary\\nclean\\n\\n## Findings\\n(none)\\n');

globalThis.args = { ...baseArgs, items: [
  { slug: 'contentgarble-b', branch: 'build/contentgarble-b', title: 'Touch a shell script', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();
let reason = null;
const diffCalls = callLog.filter(c => (c.opts.label||'').startsWith('review-diff:contentgarble-b'));
if (diffCalls.length !== 2) reason = 'expected exactly one retry (2 review-diff calls total), got ' + diffCalls.length;
else if ((result.parked ?? []).length !== 1) reason = 'expected 1 parked once the retry recovers matching content: ' + JSON.stringify(result);
else if ((result.escalations ?? []).length !== 0) reason = 'a recovered retry must never escalate: ' + JSON.stringify(result.escalations);
const rec = (result.parked ?? [])[0];
if (!reason && (!rec.review || !rec.review.ran.some(r => r.reviewer === 'shell-reviewer')))
  reason = 'shell-reviewer must have run once the retry recovered matching content: ' + JSON.stringify(rec && rec.review);
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

# ============================================================================
# TEST (K1982 round 2 — POSITION-SENSITIVE): the round-1 checksum (a bare sum
#   of character codes) is COMMUTATIVE — invariant under any rearrangement of
#   the same characters. The round-2 reviewer reproduced this against this
#   repo's OWN tracked reviewer-routing.tsv: swapping the reviewer+path
#   columns between the \`.sh\` row and the \`docs/**\` row (same row count,
#   same overall character multiset) left the bare-sum checksum
#   byte-IDENTICAL (67458 before and after) — the K1982-round-1 test above
#   corrupts \`.sh -> docs-reviewer\` WITHOUT compensating elsewhere, which
#   changes the character inventory and so is a strawman for THIS threat
#   model: a same-inventory row REASSIGNMENT, the exact shape of the
#   temperloop#1978 round-4 incident (a .sh diff silently routed to
#   docs-reviewer alone). This case builds the transposition directly off the
#   LIVE tracked tsv (not a fixture restatement), asserts the row count is
#   unchanged, asserts the position-weighted checksum DIFFERS, and asserts
#   the guard escalates content_mismatch — never silently computing a roster
#   off the transposed table.
# ============================================================================
run_node_case "K1982 round 2 position-sensitive: transposing reviewer+path columns between the .sh and docs/** rows of the REAL tsv (same row count, same character multiset) changes the checksum and escalates" "
$PREAMBLE
const tsv = readFileSync('$REPO_ROOT/workflows/scripts/config/reviewer-routing.tsv', 'utf8');
const TAB = String.fromCharCode(9);
const lines = tsv.split('\\n');
const shIdx = lines.findIndex(l => l.startsWith('.sh' + TAB));
const docsIdx = lines.findIndex(l => l.startsWith('docs/**' + TAB));
let reason = null;
if (shIdx < 0 || docsIdx < 0) {
  reason = 'setup: the live tsv no longer carries a .sh row and/or a docs/** row — this case needs both';
} else {
  const shCols = lines[shIdx].split(TAB);
  const docsCols = lines[docsIdx].split(TAB);
  // Transpose columns 2+3 (reviewer name, agent path) between the two rows —
  // column 1 (the key) stays put on each row, exactly the reviewer's
  // reproduction: '.sh -> docs-reviewer' and 'docs/** -> shell-reviewer'.
  const swapped = lines.slice();
  swapped[shIdx] = [shCols[0], docsCols[1], docsCols[2]].join(TAB);
  swapped[docsIdx] = [docsCols[0], shCols[1], shCols[2]].join(TAB);
  const swappedTsv = swapped.join('\\n');

  if (tsvRows(swappedTsv) !== tsvRows(tsv)) {
    reason = 'setup: the transposition must preserve row count or this case tests path A, not this threat model: ' + tsvRows(tsv) + ' vs ' + tsvRows(swappedTsv);
  } else if (tsvChecksum(swappedTsv) === tsvChecksum(tsv)) {
    reason = 'THE DEFECT ITSELF: a same-row-count, same-inventory row transposition must change a position-sensitive checksum, but it did not — ' + tsvChecksum(tsv);
  } else {

setMachinery('rowswap-a',
  { outcome: 'CREATED', path: '/tmp/repo.wt/rowswap-a' },
  // tsv_checksum is the relayed SOURCE-FILE checksum (the REAL, untransposed
  // tsv) — reliable, like tsv_rows. tsv itself is the transposed content the
  // relay actually delivered, same row count, same character multiset.
  { outcome: 'REVIEW_DIFF', files: ['workflows/scripts/foo.sh'], tsv: swappedTsv, tsv_rows: tsvRows(swappedTsv), tsv_checksum: tsvChecksum(tsv) },
  { outcome: 'REVIEW_DIFF', files: ['workflows/scripts/foo.sh'], tsv: swappedTsv, tsv_rows: tsvRows(swappedTsv), tsv_checksum: tsvChecksum(tsv) },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'aa53' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'aa53', branch: 'build/rowswap-a' },
  { outcome: 'PR_OPENED', pr_number: 2024 },
  { outcome: 'CI_GREEN' },
);
happyWorker('rowswap-a');

globalThis.args = { ...baseArgs, items: [
  { slug: 'rowswap-a', branch: 'build/rowswap-a', title: 'Touch a shell script', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();
const diffCalls = callLog.filter(c => (c.opts.label||'').startsWith('review-diff:rowswap-a'));
if (diffCalls.length !== 2) reason = 'expected exactly one retry (2 review-diff calls total), got ' + diffCalls.length;
else if ((result.escalations ?? []).length !== 0) reason = 'K2020: a persistent content mismatch must DEGRADE, not halt: ' + JSON.stringify(result.escalations);
else if ((result.parked ?? []).length !== 1) reason = 'expected the item to park: ' + JSON.stringify(result);
else {
  const payload = result.parked[0].review.routing_degraded;
  const cm = payload && payload.content_mismatch;
  if (!cm || typeof cm.expected !== 'number' || cm.expected === cm.got) reason = 'the degradation payload must name a real checksum disagreement: ' + JSON.stringify(payload);
  else if (payload.mismatch) reason = 'a row-count-VALID case must never carry the row-count mismatch field too: ' + JSON.stringify(payload);
}
const reviewCalls = callLog.filter(c => isReviewCall(c.opts));
if (!reason && reviewCalls.length !== 0) reason = 'the guard must catch a same-inventory row transposition BEFORE any reviewer roster is computed from it — shell-reviewer must never silently miss: ' + JSON.stringify(reviewCalls.map(c => c.opts.agentType));
  }
}
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

# ============================================================================
# TEST (K1982 round 2 — bash/JS parity, EXECUTED not asserted): round 1's
#   parity claim ("verified byte-for-byte identical") was prose only — no
#   test ran the actual bash side; every fixture recomputed the checksum
#   through the harness's OWN JS reimplementation. This case runs the REAL
#   reviewDiffCmd()-generated bash pipeline (via bash, against this repo's
#   own working tree) and compares its tsv_checksum against tsvChecksum(),
#   both loaded fresh from the production .mjs source (not the harness's
#   independent restatement above) — a genuine cross-implementation check,
#   not a copy of one side asserting agreement with itself.
# ============================================================================
run_node_case "K1982 round 2 bash/JS parity: reviewDiffCmd's REAL bash pipeline (executed via bash, not reimplemented) agrees with tsvChecksum() over the SAME tracked file" "
$PREAMBLE
const { execFileSync } = await import('node:child_process');
let reason = null;
const internalsSrc = MJS_SRC.replace(/return await buildLevel\(\);\s*\$/, 'return { reviewDiffCmd, tsvChecksum };');
if (internalsSrc === MJS_SRC) {
  reason = 'internals-splice failed: the literal tail \\'return await buildLevel();\\' was not found in build-level.mjs — this test needs updating alongside that refactor';
} else {
  globalThis.args = '{}'; // module-scope \`const input = JSON.parse(args)\` needs SOME value
  const internalsFn = new AsyncFunction(internalsSrc);
  const { reviewDiffCmd, tsvChecksum: prodTsvChecksum } = await internalsFn();
  const wt = '$REPO_ROOT';
  // NON-BUMPING second argument (temperloop#2046) — NOT optional, do not drop
  // it. wt here is the REAL repo root, which when this suite runs inside a
  // build worktree IS that worktree, so the bumping default writes the
  // production review-round marker (build-review-rounds, in the worktree's own
  // git dir) as a side effect of merely running the tests, inflating #1970's
  // convergence bound before the first real review round ever happens. The
  // non-bumping arm is the same one production uses for the #1976 re-fetch and
  // changes nothing this case measures: bump only adds the marker WRITE;
  // tsv_checksum, tsv_rows, tsv_lines and the emitted review_rounds read are
  // identical either way. A static guard at the end of this file pins it.
  const script = reviewDiffCmd(wt, false);
  let out;
  try {
    out = execFileSync('bash', ['-c', script], { encoding: 'utf8', cwd: wt });
  } catch (e) {
    reason = 'the REAL bash pipeline threw: ' + ((e && e.message) || e);
  }
  if (!reason) {
    const outLines = out.trim().split('\\n').filter(Boolean);
    let parsed;
    try { parsed = JSON.parse(outLines[outLines.length - 1]); }
    catch (e) { reason = 'the real bash pipeline did not emit parseable JSON on its last line: ' + out; }
    if (!reason) {
      if (parsed.outcome !== 'REVIEW_DIFF') reason = 'unexpected outcome from the real bash pipeline: ' + JSON.stringify(parsed);
      else if (typeof parsed.tsv_checksum !== 'number') reason = 'tsv_checksum missing/non-numeric from the REAL bash pipeline: ' + JSON.stringify(parsed);
      else {
        const realTsv = readFileSync(wt + '/workflows/scripts/config/reviewer-routing.tsv', 'utf8');
        const jsChecksum = prodTsvChecksum(realTsv);
        if (parsed.tsv_checksum !== jsChecksum) {
          reason = 'PARITY BROKEN: the real bash pipeline computed tsv_checksum=' + parsed.tsv_checksum + ' but production tsvChecksum() computed ' + jsChecksum + ' over the IDENTICAL tracked file';
        }
      }
    }
  }
}
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

# ============================================================================
# TEST (K2020 — wire shape, EXECUTED not asserted): temperloop#2020 stopped
#   shipping the routing table as an inline `tsv` SCALAR and ships `tsv_lines`
#   — a JSON array of data-row strings, the same jq idiom `files` uses, which
#   is the field observed to survive every relay mangling that destroyed the
#   blob. Two properties have to hold together or the change is unsafe:
#     (1) the step no longer emits `tsv` at all, and emits `tsv_lines` as a
#         real ARRAY (not a stringified one);
#     (2) the array is EQUIVALENT to the old blob — joined on newlines it
#         reproduces, bit for bit, the SAME tsv_rows and tsv_checksum the
#         #1976/#1982 detectors compare against, so neither detector is
#         weakened by the reshape.
#   Both are checked against the REAL reviewDiffCmd()-generated bash pipeline
#   executed over this repo's own realistically-sized tracked tsv (~3.8KB, 11
#   data rows — the exact file whose relay was dropped in production), with
#   production's own reviewDiffTsvText/parseTsvRows/tsvChecksum spliced out of
#   the .mjs source rather than reimplemented here.
# ============================================================================
run_node_case "K2020 wire shape: the REAL bash pipeline emits tsv_lines as an ARRAY and no tsv scalar, and the array joined on newlines reproduces the SAME tsv_rows/tsv_checksum the #1976/#1982 detectors compare against" "
$PREAMBLE
const { execFileSync } = await import('node:child_process');
let reason = null;
const internalsSrc = MJS_SRC.replace(/return await buildLevel\(\);\s*\$/, 'return { reviewDiffCmd, tsvChecksum, parseTsvRows, reviewDiffTsvText, reviewDiffTsvGap };');
if (internalsSrc === MJS_SRC) {
  reason = 'internals-splice failed: the literal tail \\'return await buildLevel();\\' was not found in build-level.mjs — this test needs updating alongside that refactor';
} else {
  globalThis.args = '{}';
  const internalsFn = new AsyncFunction(internalsSrc);
  const I = await internalsFn();
  const wt = '$REPO_ROOT';
  let out;
  try {
    // NON-BUMPING second argument (temperloop#2046) — see the K1982 round 2
    // parity case above for why: wt is the real repo root, so the bumping
    // default writes the production review-round marker just by running the
    // suite. It changes nothing this case measures.
    out = execFileSync('bash', ['-c', I.reviewDiffCmd(wt, false)], { encoding: 'utf8', cwd: wt });
  } catch (e) {
    reason = 'the REAL bash pipeline threw: ' + ((e && e.message) || e);
  }
  if (!reason) {
    const outLines = out.trim().split('\\n').filter(Boolean);
    let parsed;
    try { parsed = JSON.parse(outLines[outLines.length - 1]); }
    catch (e) { reason = 'the real bash pipeline did not emit parseable JSON on its last line: ' + out; }
    if (!reason) {
      const realTsv = readFileSync(wt + '/workflows/scripts/config/reviewer-routing.tsv', 'utf8');
      // Guard the fixture itself: a shrunken table would make this case pass
      // for the wrong reason (a 1-row table was never the relay's problem).
      if (realTsv.length < 1000 || I.parseTsvRows(realTsv).length < 5) {
        reason = 'setup: the tracked reviewer-routing.tsv is no longer realistically sized (' + realTsv.length + ' bytes, ' + I.parseTsvRows(realTsv).length + ' rows) — this case needs a table big enough to be the relay drop it models';
      } else if ('tsv' in parsed) {
        reason = 'K2020: the step must NOT ship the table as an inline scalar any more — found a tsv key: ' + JSON.stringify(String(parsed.tsv).slice(0, 80));
      } else if (!Array.isArray(parsed.tsv_lines)) {
        reason = 'K2020: tsv_lines must be a real JSON ARRAY (the shape \`files\` uses), got ' + typeof parsed.tsv_lines + ': ' + JSON.stringify(parsed.tsv_lines).slice(0, 120);
      } else if (parsed.tsv_lines.length !== Number(parsed.tsv_rows)) {
        reason = 'K2020: tsv_lines must carry exactly the rows tsv_rows counted — ' + parsed.tsv_lines.length + ' vs ' + parsed.tsv_rows;
      } else {
        // THE EQUIVALENCE INVARIANT: reshaping the field must not move either
        // detector's value. Recompute both from the received array through
        // PRODUCTION's own normalizer.
        const text = I.reviewDiffTsvText(parsed);
        if (I.parseTsvRows(text).length !== Number(parsed.tsv_rows)) {
          reason = 'K2020: the #1976 row-count detector no longer agrees with the reshaped payload — ' + I.parseTsvRows(text).length + ' vs ' + parsed.tsv_rows;
        } else if (I.tsvChecksum(text) !== Number(parsed.tsv_checksum)) {
          reason = 'K2020: the #1982 checksum detector no longer agrees with the reshaped payload — ' + I.tsvChecksum(text) + ' vs ' + parsed.tsv_checksum + ' (the joined array must be byte-identical to the blob this used to emit)';
        } else if (I.tsvChecksum(text) !== I.tsvChecksum(realTsv)) {
          reason = 'K2020: the relayed rows must canonicalize to the SAME checksum as the source file itself — ' + I.tsvChecksum(text) + ' vs ' + I.tsvChecksum(realTsv);
        } else if (I.reviewDiffTsvGap(parsed, ['workflows/scripts/foo.sh']) !== null) {
          reason = 'K2020: an INTACT reshaped payload must read as complete, never as a gap: ' + JSON.stringify(I.reviewDiffTsvGap(parsed, ['workflows/scripts/foo.sh']));
        }
      }
    }
  }
}
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K2020 relay-shape routing: a REVIEW_DIFF carrying the LIVE tsv in the tsv_lines array shape routes normally — shell-reviewer runs, no retry, no degradation" "
$PREAMBLE
const realTsv = readFileSync('$REPO_ROOT/workflows/scripts/config/reviewer-routing.tsv', 'utf8');
setMachinery('k2020-lines',
  { outcome: 'CREATED', path: '/tmp/repo.wt/k2020-lines' },
  { outcome: 'REVIEW_DIFF', files: ['workflows/scripts/foo.sh'], tsv_lines: tsvLines(realTsv), tsv_rows: tsvRows(realTsv), tsv_checksum: tsvChecksum(realTsv) },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'a20202d' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'a20202d', branch: 'build/k2020-lines' },
  { outcome: 'PR_OPENED', pr_number: 2025 },
  { outcome: 'CI_GREEN' },
);
happyWorker('k2020-lines');
setReview('k2020-lines', '## Summary\\nclean\\n');

globalThis.args = { ...baseArgs, items: [
  { slug: 'k2020-lines', branch: 'build/k2020-lines', title: 'Touch a shell script', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();
let reason = null;
const diffCalls = callLog.filter(c => (c.opts.label||'').startsWith('review-diff:k2020-lines'));
if (diffCalls.length !== 1) reason = 'an INTACT tsv_lines payload must need no retry, got ' + diffCalls.length + ' review-diff calls';
else if ((result.escalations ?? []).length !== 0) reason = 'no escalation expected: ' + JSON.stringify(result.escalations);
else if ((result.parked ?? []).length !== 1) reason = 'expected 1 parked: ' + JSON.stringify(result);
const rec = (result.parked ?? [])[0];
if (!reason && (!rec.review || !(rec.review.ran ?? []).some(r => r.reviewer === 'shell-reviewer')))
  reason = 'the routing decision must be reached from the array shape — shell-reviewer must run: ' + JSON.stringify(rec && rec.review);
if (!reason && rec.review.routing_degraded) reason = 'an intact payload must never be reported as degraded: ' + JSON.stringify(rec.review.routing_degraded);
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

# ============================================================================
# TEST (K2020 — THE REGRESSION CASE, acceptance 3): drive the review-diff step
#   with a REALISTICALLY-SIZED table (the live tracked reviewer-routing.tsv,
#   the same ~3.8KB/11-row file the production relay dropped on
#   Towheads/foundation run wf_967c2878-0a7) and model the drop itself — the
#   REVIEW_DIFF line arrives with `files` intact and NO table field at all,
#   byte-for-byte the observed failure shape. Two arms, because "the routing
#   decision is still reached" means different things depending on whether a
#   table is reachable at all:
#     ARM 1 (orchestrator hand-off present, #1982): the decision is reached in
#       full — shell-reviewer routes off the authoritative copy, the relay is
#       not consulted, and no retry is even attempted.
#     ARM 2 (no hand-off — an un-migrated caller, the foundation v0.39.0 case):
#       the decision that is reached is the DEGRADATION — a legible skip, and
#       the drive still completes to a PR. Never a halt.
#   Deterministic: the fixture is a tracked file plus queued outcomes; nothing
#   here depends on a live relay.
# ============================================================================
run_node_case "K2020 regression ARM 1: a realistically-sized table DROPPED from the relay still reaches the routing decision when the orchestrator supplied it — shell-reviewer runs, zero retries, no degradation" "
$PREAMBLE
const realTsv = readFileSync('$REPO_ROOT/workflows/scripts/config/reviewer-routing.tsv', 'utf8');
if (realTsv.length < 1000 || tsvRows(realTsv) < 5) {
  console.log(JSON.stringify({ ok: false, reason: 'setup: the tracked tsv is no longer realistically sized — this case must model a table big enough to be the observed drop' }));
} else {

setMachinery('k2020-arm1',
  { outcome: 'CREATED', path: '/tmp/repo.wt/k2020-arm1' },
  // The observed drop: files intact, the table field gone entirely.
  { outcome: 'REVIEW_DIFF', files: ['workflows/scripts/foo.sh'], tsv_rows: tsvRows(realTsv), tsv_checksum: tsvChecksum(realTsv) },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'a2020a2b' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'a2020a2b', branch: 'build/k2020-arm1' },
  { outcome: 'PR_OPENED', pr_number: 2026 },
  { outcome: 'CI_GREEN' },
);
happyWorker('k2020-arm1');
setReview('k2020-arm1', '## Summary\\nclean\\n');

globalThis.args = { ...baseArgs, reviewerRoutingTsv: realTsv, items: [
  { slug: 'k2020-arm1', branch: 'build/k2020-arm1', title: 'Touch a shell script', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();
let reason = null;
const diffCalls = callLog.filter(c => (c.opts.label||'').startsWith('review-diff:k2020-arm1'));
if (diffCalls.length !== 1) reason = 'the authoritative hand-off must skip the relay gap-check and its retry entirely, got ' + diffCalls.length + ' review-diff calls';
else if ((result.escalations ?? []).length !== 0) reason = 'a dropped relay with an authoritative table must never escalate: ' + JSON.stringify(result.escalations);
else if ((result.parked ?? []).length !== 1) reason = 'expected 1 parked: ' + JSON.stringify(result);
const rec = (result.parked ?? [])[0];
if (!reason && !(rec.review.ran ?? []).some(r => r.reviewer === 'shell-reviewer'))
  reason = 'THE ACCEPTANCE: the routing decision must still be REACHED despite the drop — shell-reviewer must run: ' + JSON.stringify(rec.review);
if (!reason && rec.review.routing_degraded) reason = 'the decision was reachable, so nothing may be reported degraded: ' + JSON.stringify(rec.review.routing_degraded);
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
}
"

run_node_case "K2020 regression ARM 2: the same realistically-sized drop with NO orchestrator hand-off degrades legibly and the drive still completes to a PR — never the review-diff-error halt that stranded committed work" "
$PREAMBLE
const realTsv = readFileSync('$REPO_ROOT/workflows/scripts/config/reviewer-routing.tsv', 'utf8');
if (realTsv.length < 1000 || tsvRows(realTsv) < 5) {
  console.log(JSON.stringify({ ok: false, reason: 'setup: the tracked tsv is no longer realistically sized — this case must model a table big enough to be the observed drop' }));
} else {

setMachinery('k2020-arm2',
  { outcome: 'CREATED', path: '/tmp/repo.wt/k2020-arm2' },
  { outcome: 'REVIEW_DIFF', files: ['workflows/scripts/foo.sh'], tsv_rows: tsvRows(realTsv), tsv_checksum: tsvChecksum(realTsv) },
  { outcome: 'REVIEW_DIFF', files: ['workflows/scripts/foo.sh'], tsv_rows: tsvRows(realTsv), tsv_checksum: tsvChecksum(realTsv) },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'a2020a2c' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'a2020a2c', branch: 'build/k2020-arm2' },
  { outcome: 'PR_OPENED', pr_number: 2027 },
  { outcome: 'CI_GREEN' },
);
happyWorker('k2020-arm2');

globalThis.args = { ...baseArgs, items: [
  { slug: 'k2020-arm2', branch: 'build/k2020-arm2', title: 'Touch a shell script', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();
let reason = null;
const diffCalls = callLog.filter(c => (c.opts.label||'').startsWith('review-diff:k2020-arm2'));
if (diffCalls.length !== 2) reason = 'the #1976 one-shot retry must still fire on the drop, got ' + diffCalls.length + ' review-diff calls';
else if ((result.escalations ?? []).length !== 0) reason = 'THE ACCEPTANCE: a drop must not halt a drive whose work is complete: ' + JSON.stringify(result.escalations);
else if ((result.parked ?? []).length !== 1) reason = 'the drive must still reach a PR and park: ' + JSON.stringify(result);
const rec = (result.parked ?? [])[0];
if (!reason && rec.pr !== 2027) reason = 'the PR must still have been opened: ' + JSON.stringify(rec);
if (!reason && (rec.review.ran ?? []).length !== 0) reason = 'no roster may be computed from a table that never arrived: ' + JSON.stringify(rec.review);
if (!reason && !(rec.review.skipped ?? []).some(s => /^skipped — /.test(s.note)))
  reason = 'the degradation must be legible as a mode-2 skip notice: ' + JSON.stringify(rec.review);
if (!reason && !rec.review.routing_degraded) reason = 'the gap payload must ride the record so the degradation is diagnosable: ' + JSON.stringify(rec.review);
if (!reason && rec.review.routing_degraded.missing !== 'tsv') reason = 'the gap payload must name WHICH detector fired: ' + JSON.stringify(rec.review.routing_degraded);
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
}
"

# ============================================================================
# TEST (K2020 — acceptance 4, THE DATA-LOSS CRITERION): an escalation that
#   fires AFTER the 3c worker has committed must not hand the caller a state
#   where the only copy of that work is a local worktree a downstream prose
#   step may delete. driveItem's result passes through preserveOnEscalation at
#   the parallel() choke point, which pushes the branch first and records what
#   happened on the escalation payload. Three cases: the push succeeds, the
#   push FAILS (the payload must say so — that is when the worktree is the
#   last copy), and a PARKED item is never touched by any of this.
# ============================================================================
run_node_case "K2020 preserve: a post-commit escalation pushes the branch to origin BEFORE returning, and records committed_work on the payload" "
$PREAMBLE
setMachinery('k2020-presv',
  { outcome: 'CREATED', path: '/tmp/repo.wt/k2020-presv' },
);
// A failing acceptance verdict — an escalation raised AFTER 3c committed.
setWorker('k2020-presv', { status: 'done', summary: 'built it', acceptance_results: [{ criterion: 'c', passed: false, evidence: 'e' }], commits: ['abc1234'] });

globalThis.args = { ...baseArgs, items: [
  { slug: 'k2020-presv', branch: 'build/k2020-presv', title: 'Committed then escalated', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();
let reason = null;
if ((result.escalations ?? []).length !== 1) reason = 'expected exactly 1 escalation: ' + JSON.stringify(result);
else {
  const pushCalls = callLog.filter(c => (c.opts.label||'') === 'preserve-push:k2020-presv');
  const cw = result.escalations[0].payload.committed_work;
  if (pushCalls.length !== 1) reason = 'THE ACCEPTANCE: an escalation must attempt exactly one work-preservation push before returning, got ' + pushCalls.length;
  else if (!cw || cw.preserved !== true) reason = 'the escalation payload must record that the committed work is on origin: ' + JSON.stringify(cw);
  else if (cw.outcome !== 'WORK_PRESERVED') reason = 'committed_work must name the outcome it observed: ' + JSON.stringify(cw);
  else if (result.escalations[0].kind !== 'acceptance-incomplete') reason = 'preservation must not change the escalation the item was carrying: ' + result.escalations[0].kind;
}
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K2020 preserve FAILED: when the push does not land the work, the escalation says so — preserved:false, so a caller deciding about worktree removal reads the worktree as the last copy" "
$PREAMBLE
setMachinery('k2020-presvf',
  { outcome: 'CREATED', path: '/tmp/repo.wt/k2020-presvf' },
);
setPreserve('k2020-presvf', { outcome: 'WORK_PRESERVE_FAILED', branch: 'build/k2020-presvf', commits_ahead: 3, pushed: false });
setWorker('k2020-presvf', { status: 'done', summary: 'built it', acceptance_results: [{ criterion: 'c', passed: false, evidence: 'e' }], commits: ['abc1234'] });

globalThis.args = { ...baseArgs, items: [
  { slug: 'k2020-presvf', branch: 'build/k2020-presvf', title: 'Committed then escalated', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();
let reason = null;
if ((result.escalations ?? []).length !== 1) reason = 'expected exactly 1 escalation: ' + JSON.stringify(result);
else {
  const cw = result.escalations[0].payload.committed_work;
  if (!cw || cw.preserved !== false) reason = 'a failed push must be reported as NOT preserved — never silently optimistic: ' + JSON.stringify(cw);
  else if (cw.outcome !== 'WORK_PRESERVE_FAILED') reason = 'committed_work must name the failing outcome: ' + JSON.stringify(cw);
  else if (Number(cw.commits_ahead) !== 3) reason = 'committed_work must carry HOW MUCH work is at risk: ' + JSON.stringify(cw);
  else if (result.escalations[0].kind !== 'acceptance-incomplete') reason = 'a failed preservation must not change the escalation kind: ' + result.escalations[0].kind;
}
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K2020 preserve scope: a PARKED item never pays a preservation push — 3f already pushed it and opened its PR" "
$PREAMBLE
happyMachinery('k2020-park', 2028, 'a20202e');
happyWorker('k2020-park');

globalThis.args = { ...baseArgs, items: [
  { slug: 'k2020-park', branch: 'build/k2020-park', title: 'Green', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();
let reason = null;
if ((result.parked ?? []).length !== 1) reason = 'expected 1 parked: ' + JSON.stringify(result);
else if (callLog.some(c => (c.opts.label||'').startsWith('preserve-push:')))
  reason = 'a green, parked item must not pay an extra machinery spawn: ' + JSON.stringify(callLog.filter(c => (c.opts.label||'').startsWith('preserve-push:')).map(c => c.opts.label));
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K2020 preserve DENIED: the auto-mode classifier denying the preservation push is recorded as SPINE_DENIED with preserved:false — the arm the function's own comment lists and the one that must never read as a silent success" "
$PREAMBLE
setMachinery('k2020-presvd',
  { outcome: 'CREATED', path: '/tmp/repo.wt/k2020-presvd' },
);
// A queued null models agent() coming back DENIED for the preserve-push label.
// runMachinery() normalises that to { outcome: 'SPINE_DENIED', denied: true }
// rather than throwing, so this arm reaches preserveOnEscalation as a
// well-formed outcome object — and must be reported as NOT preserved.
setPreserve('k2020-presvd', null);
setWorker('k2020-presvd', { status: 'done', summary: 'built it', acceptance_results: [{ criterion: 'c', passed: false, evidence: 'e' }], commits: ['abc1234'] });

globalThis.args = { ...baseArgs, items: [
  { slug: 'k2020-presvd', branch: 'build/k2020-presvd', title: 'Committed then escalated', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();
let reason = null;
if ((result.escalations ?? []).length !== 1) reason = 'expected exactly 1 escalation: ' + JSON.stringify(result);
else {
  const cw = result.escalations[0].payload.committed_work;
  if (!cw) reason = 'a denied preservation push must still record committed_work — an absent field reads as an older workflow, not as a denial';
  else if (cw.outcome !== 'SPINE_DENIED') reason = 'a denied executor must be named as such, never flattened to a generic ERROR: ' + JSON.stringify(cw);
  else if (cw.preserved !== false) reason = 'a DENIED push landed nothing — preserved must be false so the disposing caller reads the worktree as the last copy: ' + JSON.stringify(cw);
  else if (cw.branch !== 'build/k2020-presvd') reason = 'committed_work must still name the branch at risk even when the push never ran: ' + JSON.stringify(cw);
  else if (result.escalations[0].kind !== 'acceptance-incomplete') reason = 'a denied preservation must not change the escalation the item was carrying: ' + result.escalations[0].kind;
}
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

# ============================================================================
# TEST (K2020 round 2 — preserveCommittedWorkCmd's GENERATED BASH, EXECUTED
#   not mocked): every case above drives the JS CONSUMER of this step against a
#   hand-written JSON object, so none of them executes a single line of the
#   shell text preserveCommittedWorkCmd() actually emits. That text is the
#   data-loss mechanism itself — it exists because a prose guard failed and 515
#   verified lines were destroyed — so a quoting bug, a misresolving \`default\`
#   chain, a silently-failing \`git rev-list --count\` or an off-by-one in the
#   \`ahead -eq 0\` skip would surface only in production, on the one path built
#   to prevent loss. The sibling tsv_lines change got a real-bash test for
#   exactly this reason; this is its counterpart.
#
#   Runs the REAL generated command under bash against throwaway git repos (a
#   bare 'origin' plus local clones, all under mkdtemp, git config fully
#   isolated via GIT_CONFIG_GLOBAL/SYSTEM=/dev/null), splicing
#   preserveCommittedWorkCmd out of the .mjs source rather than reimplementing
#   it. Six arms, one per branch of the generated script:
#     A  committed-but-unpushed  -> WORK_PRESERVED, and the branch REALLY lands
#                                   in the bare origin (asserted against origin,
#                                   not against the script's own claim)
#     B  clean clone at base     -> WORK_PRESERVE_SKIP, commits_ahead 0
#     C  push rigged to fail     -> WORK_PRESERVE_FAILED, pushed false
#     D  no worktree at all      -> WORK_PRESERVE_SKIP, detail 'no worktree'
#     E  no refs/remotes/origin/HEAD -> the main/master show-ref fallback still
#                                   resolves (a misresolve makes rev-list
#                                   fail, ahead read 0, and the arm silently
#                                   become a SKIP — the quiet failure)
#     F  re-run over an already-pushed branch -> still WORK_PRESERVED
#                                   (the documented idempotency claim)
#     G  (round 3) NO origin/HEAD **and** a default branch that is neither main
#                                   nor master ('trunk'), over a REAL unpushed
#                                   commit -> the base is unresolvable, so the
#                                   arm must NOT skip: it pushes anyway and
#                                   reports base_resolved:false. Arm E only ever
#                                   covered the case where the fallback SUCCEEDS;
#                                   this is the state E's own comment described
#                                   and left unasserted, and it is a FALSE
#                                   NEGATIVE on the data-loss path — a skip is
#                                   the ONE outcome preserveOnEscalation does not
#                                   warn about, so real unpushed work read as
#                                   'nothing to preserve' with no warning at all.
#
#   Every arm passes an EXPLICIT branch (the plan's `item.branch`, e.g.
#   `fix/<slug>`) that is deliberately DIFFERENT from the worktree's local
#   `build/<slug>` HEAD, and asserts the ref lands on origin under the PASSED
#   name — the round-3 MEDIUM: pushing HEAD under its local name mints a second,
#   PR-less `build/<slug>` ref on every post-3f escalation.
# ============================================================================
run_node_case "K2020/K2103 preserve bash: the REAL generated shell (executed, not mocked) preserves an unpushed commit to origin under the PLAN's branch, skips a clean tree, reports a failed push, handles a missing worktree, resolves default without origin/HEAD, pushes rather than skipping when the base is unresolvable, is idempotent, LANDS a rebased branch already on origin under a lease over a value it read first, REFUSES to overwrite a remote carrying work this worktree does not have, and REFUSES WITHOUT CLAIMING A CONFLICT when the supersede probe cannot be answered" "
$PREAMBLE
const { execFileSync } = await import('node:child_process');
const { mkdtempSync, rmSync, writeFileSync, chmodSync } = await import('node:fs');
const { tmpdir } = await import('node:os');
let reason = null;
const internalsSrc = MJS_SRC.replace(/return await buildLevel\(\);\s*\$/, 'return { preserveCommittedWorkCmd };');
if (internalsSrc === MJS_SRC) {
  reason = 'internals-splice failed: the buildLevel() tail was not found in build-level.mjs — this test needs updating alongside that refactor';
} else {
  globalThis.args = '{}';
  const I = await (new AsyncFunction(internalsSrc))();
  // Fully isolated git: no user/system config can lend this test an identity,
  // a hooksPath, or a default branch, so it asserts the SCRIPT's behaviour.
  const GITENV = { ...process.env, GIT_CONFIG_GLOBAL: '/dev/null', GIT_CONFIG_SYSTEM: '/dev/null', GIT_TERMINAL_PROMPT: '0' };
  const G = 'git -c user.email=t@example.invalid -c user.name=T -c commit.gpgsign=false -c init.defaultBranch=main';
  const root = mkdtempSync(tmpdir() + '/k2020-presv-');
  const sh = (cmd, cwd) => execFileSync('bash', ['-c', cmd], { encoding: 'utf8', cwd: cwd || root, env: GITENV });
  const run = (wt, branch) => {
    const out = execFileSync('bash', ['-c', I.preserveCommittedWorkCmd(wt, branch)], { encoding: 'utf8', cwd: root, env: GITENV });
    const lines = out.trim().split('\\n').filter(Boolean);
    return JSON.parse(lines[lines.length - 1]);
  };
  // Same as run(), but with a \`git\` on PATH that fails ONE subcommand. Arm J
  // needs a remote that answers \`ls-remote\` and then refuses \`fetch\` — the
  // real mid-flight network drop — which no static fixture can stage.
  const runWithGitStub = (wt, branch) => {
    const out = execFileSync('bash', ['-c', I.preserveCommittedWorkCmd(wt, branch)],
      { encoding: 'utf8', cwd: root, env: { ...GITENV, PATH: root + '/stub:' + process.env.PATH } });
    const lines = out.trim().split('\\n').filter(Boolean);
    return JSON.parse(lines[lines.length - 1]);
  };
  const commitOn = (name, br, f) =>
    sh('cd ' + name + ' && ' + G + ' checkout -q -b ' + br + ' && printf work > ' + f + ' && ' + G + ' add -A && ' + G + ' commit -q -m work');
  try {
    sh(G + ' init -q --bare origin.git');
    sh(G + ' init -q seed');
    sh('cd seed && printf base > f.txt && ' + G + ' add -A && ' + G + ' commit -q -m base && ' + G + ' remote add origin ../origin.git && ' + G + ' push -q -u origin HEAD:main');
    const clone = (name) => sh(G + ' clone -q origin.git ' + name);

    // --- A: a real committed-but-unpushed commit --------------------------
    // The local HEAD is \`build/wta\` (what worktree.sh mints); the PLAN branch
    // handed to the step is \`fix/wta\` (what 3f pushes). They differ on
    // purpose — the ref must land under the PLAN name.
    clone('wtA');
    commitOn('wtA', 'build/wta', 'g.txt');
    const a = run(root + '/wtA', 'fix/wta');
    if (a.outcome !== 'WORK_PRESERVED') reason = 'A: an unpushed commit must be preserved, got ' + JSON.stringify(a);
    else if (a.branch !== 'fix/wta') reason = 'A: the generated shell must report the PLAN branch it was handed, not the worktree HEAD, got ' + JSON.stringify(a);
    else if (Number(a.commits_ahead) !== 1) reason = 'A: commits_ahead must count the real unlanded commits, got ' + JSON.stringify(a);
    else if (a.base_resolved !== true) reason = 'A: with origin/HEAD present the base is resolved and must say so, got ' + JSON.stringify(a);
    else if (a.pushed !== true) reason = 'A: pushed must be true on the success arm, got ' + JSON.stringify(a);
    else {
      // THE POINT: assert against ORIGIN, not against the script's own claim.
      const landed = sh(G + ' --git-dir=' + root + '/origin.git show-ref --verify --quiet refs/heads/fix/wta && printf YES || printf NO');
      if (landed !== 'YES') reason = 'A: WORK_PRESERVED must mean the branch really exists on origin — it does not, so the report was optimistic';
      else {
        // The round-3 MEDIUM: pushing HEAD under its LOCAL name would mint a
        // second, PR-less \`build/<slug>\` ref that nothing reclaims.
        const stray = sh(G + ' --git-dir=' + root + '/origin.git show-ref --verify --quiet refs/heads/build/wta && printf YES || printf NO');
        if (stray === 'YES') reason = 'A: the preserve push must target the PLAN branch ONLY — a second build/<slug> ref on origin is the PR-less two-ref split temperloop#1688 exists to avoid, and nothing ever reclaims it';
      }
    }

    // --- B: a clean clone sitting at base ---------------------------------
    if (!reason) {
      clone('wtB');
      const b = run(root + '/wtB', 'fix/wtb');
      if (b.outcome !== 'WORK_PRESERVE_SKIP') reason = 'B: nothing ahead of base must SKIP, never mint an empty remote branch, got ' + JSON.stringify(b);
      else if (Number(b.commits_ahead) !== 0) reason = 'B: the skip arm must report commits_ahead 0, got ' + JSON.stringify(b);
      else if (b.base_resolved !== true) reason = 'B: a SKIP is only legitimate over a RESOLVED base — the skip line must prove it resolved one, got ' + JSON.stringify(b);
      else if (b.branch !== 'fix/wtb') reason = 'B: the skip arm must still name the branch it looked at, got ' + JSON.stringify(b);
      else {
        // Origin holds exactly main + fix/wta from arm A at this point; the
        // skip arm must not add a third head.
        const heads = Number(sh(G + ' --git-dir=' + root + '/origin.git for-each-ref refs/heads/ | wc -l').trim());
        if (heads !== 2) reason = 'B: the skip arm must push nothing — origin should still hold exactly main and fix/wta, got ' + heads + ' heads';
      }
    }

    // --- C: a push rigged to fail -----------------------------------------
    if (!reason) {
      clone('wtC');
      commitOn('wtC', 'build/wtc', 'h.txt');
      // Push URL only — the fetch refs (and so origin/main) stay intact, so the
      // ahead count is real and ONLY the push fails.
      sh('cd wtC && ' + G + ' remote set-url --push origin ' + root + '/no-such-repo.git');
      const c = run(root + '/wtC', 'fix/wtc');
      if (c.outcome !== 'WORK_PRESERVE_FAILED') reason = 'C: a rejected push must be reported as FAILED — never silently optimistic, got ' + JSON.stringify(c);
      else if (c.pushed !== false) reason = 'C: the failing arm must say pushed:false, got ' + JSON.stringify(c);
      else if (Number(c.commits_ahead) !== 1) reason = 'C: the failing arm must still carry HOW MUCH work is at risk, got ' + JSON.stringify(c);
    }

    // --- D: no worktree at all --------------------------------------------
    if (!reason) {
      const d = run(root + '/never-created', 'fix/wtd');
      if (d.outcome !== 'WORK_PRESERVE_SKIP' || d.detail !== 'no worktree') reason = 'D: a missing worktree is a normal, named skip, got ' + JSON.stringify(d);
    }

    // --- E: main/master fallback with no refs/remotes/origin/HEAD ---------
    if (!reason) {
      clone('wtE');
      sh('cd wtE && ' + G + ' remote set-head origin -d >/dev/null 2>&1 || true');
      commitOn('wtE', 'build/wte', 'i.txt');
      const e = run(root + '/wtE', 'fix/wte');
      // origin/main still exists here, so the show-ref fallback must resolve it
      // and count for real — a misresolve is arm G's territory.
      if (e.outcome !== 'WORK_PRESERVED' || Number(e.commits_ahead) !== 1 || e.base_resolved !== true) reason = 'E: with origin/HEAD absent the main/master show-ref fallback must still resolve the default branch and count for real, got ' + JSON.stringify(e);
    }

    // --- F: idempotent re-run over an already-pushed branch ---------------
    if (!reason) {
      const headCount = () => Number(sh(G + ' --git-dir=' + root + '/origin.git for-each-ref refs/heads/ | wc -l').trim());
      const before = headCount();
      const f = run(root + '/wtA', 'fix/wta');
      if (f.outcome !== 'WORK_PRESERVED' || f.pushed !== true) reason = 'F: a second preserve on an already-pushed branch is Everything up-to-date and must still report WORK_PRESERVED, got ' + JSON.stringify(f);
      else if (headCount() !== before) reason = 'F: the idempotent re-run must push to the SAME ref 3f owns and add NO new head — origin went from ' + before + ' to ' + headCount() + ' heads';
    }

    // --- G: UNRESOLVABLE base (round 3 HIGH) ------------------------------
    // Its own origin, defaulting to \`trunk\`: no origin/HEAD, and neither
    // origin/main nor origin/master exists, so nothing the resolver knows can
    // name a base. There IS one real unpushed commit. Before the fix, rev-list
    // failed, \`|| echo 0\` swallowed it, and this emitted
    // {\"outcome\":\"WORK_PRESERVE_SKIP\",\"commits_ahead\":0,\"detail\":\"no
    // unlanded commits\"} — and because preserveOnEscalation warns on every
    // outcome EXCEPT the skip, the operator saw nothing at all.
    if (!reason) {
      sh(G + ' init -q --bare origin2.git');
      sh(G + ' init -q seed2');
      sh('cd seed2 && printf base > f.txt && ' + G + ' add -A && ' + G + ' commit -q -m base && ' + G + ' remote add origin ../origin2.git && ' + G + ' push -q origin HEAD:trunk');
      sh(G + ' clone -q origin2.git wtG');
      sh('cd wtG && ' + G + ' remote set-head origin -d >/dev/null 2>&1 || true');
      commitOn('wtG', 'build/wtg', 'j.txt');
      const g = run(root + '/wtG', 'fix/wtg');
      if (g.outcome === 'WORK_PRESERVE_SKIP') reason = 'G: an UNRESOLVABLE base must never read as a genuine zero — a SKIP here is a false negative over real unpushed work, and it is the one outcome that suppresses the \"the worktree may be the ONLY copy\" warning, got ' + JSON.stringify(g);
      else if (g.outcome !== 'WORK_PRESERVED') reason = 'G: pushing is the fail-safe direction when the base cannot be computed — the work must reach origin, got ' + JSON.stringify(g);
      else if (g.base_resolved !== false) reason = 'G: the line must say the base was unresolved, so commits_ahead being absent is legible rather than a mystery, got ' + JSON.stringify(g);
      else if (g.commits_ahead !== undefined) reason = 'G: with no base there is no honest count — commits_ahead must be OMITTED, never fabricated and never a non-number in an unquoted JSON number position, got ' + JSON.stringify(g);
      else if (!/base unresolved/.test(String(g.detail || ''))) reason = 'G: the detail must name the unresolved base, got ' + JSON.stringify(g);
      else {
        const landed = sh(G + ' --git-dir=' + root + '/origin2.git show-ref --verify --quiet refs/heads/fix/wtg && printf YES || printf NO');
        if (landed !== 'YES') reason = 'G: WORK_PRESERVED on the unresolved-base arm must mean the branch really reached origin';
      }
    }

    // --- H: THE REBASED-BRANCH-ALREADY-ON-ORIGIN SHAPE (temperloop#2103) --
    // The shape that defeated this seam three times in one session. A
    // CONTINUATION round: an earlier round already pushed \`fix/wth\`, then
    // origin/main advanced and 3f-0a rebased the work onto the new tip. The
    // rewritten history does not contain the remote tip, so the plain push is a
    // non-fast-forward BY CONSTRUCTION and came back WORK_PRESERVE_FAILED over
    // commits that existed nowhere but the worktree.
    //
    // This arm pins BOTH halves of the claim:
    //   * the work actually reaches origin with no hand intervention, via a
    //     LEASE over the value the step read first (\`forced_with_lease\`,
    //     \`rewrote_remote\`) — never a bare force;
    //   * \`preserved\` is read BACK from origin, not inferred from an exit
    //     code: \`remote_sha\` must equal this worktree's own HEAD. The live
    //     third occurrence is exactly why — a stale pre-rebase sha sat on the
    //     remote while the flag read false, so the branch's existence
    //     overstated and the flag understated, in the same run.
    if (!reason) {
      clone('wtH');
      commitOn('wtH', 'build/wth', 'k.txt');
      const h1 = run(root + '/wtH', 'fix/wth');
      if (h1.outcome !== 'WORK_PRESERVED') reason = 'H: fixture setup — the round-1 preserve must land, got ' + JSON.stringify(h1);
      else {
        const pre = sh(G + ' --git-dir=' + root + '/origin.git rev-parse refs/heads/fix/wth').trim();
        // A sibling item merges while this item builds; the continuation round
        // then rebases onto the advanced tip — 3f-0a, exactly.
        sh('cd seed && printf advance >> f.txt && ' + G + ' add -A && ' + G + ' commit -q -m advance && ' + G + ' push -q origin HEAD:main');
        sh('cd wtH && ' + G + ' fetch -q origin && ' + G + ' rebase -q origin/main');
        const head = sh('cd wtH && ' + G + ' rev-parse HEAD').trim();
        const headsBefore = Number(sh(G + ' --git-dir=' + root + '/origin.git for-each-ref refs/heads/ | wc -l').trim());
        if (head === pre) reason = 'H: fixture error — the rebase did not rewrite the branch, so this arm proves nothing';
        else {
          const h = run(root + '/wtH', 'fix/wth');
          if (h.outcome !== 'WORK_PRESERVED') reason = 'H: a rebased branch already on origin must still be PRESERVED — a plain push can never fast-forward here, and reporting FAILED leaves the worktree as the only copy, got ' + JSON.stringify(h);
          else if (h.pushed !== true) reason = 'H: the rebased arm must report pushed:true, got ' + JSON.stringify(h);
          else if (h.forced_with_lease !== true) reason = 'H: the rewrite must be recorded as a LEASED force — an unrecorded force is indistinguishable from a bare one, got ' + JSON.stringify(h);
          else if (h.rewrote_remote !== pre) reason = 'H: the lease must name the remote value it was taken against (the pre-rebase tip), got ' + JSON.stringify(h) + ' (expected ' + pre + ')';
          else if (h.head_sha !== head || h.remote_sha !== head) reason = 'H: preserved must be READ BACK from origin — head_sha and remote_sha must both be this worktree HEAD, got ' + JSON.stringify(h) + ' (HEAD ' + head + ')';
          else if (sh(G + ' --git-dir=' + root + '/origin.git rev-parse refs/heads/fix/wth').trim() !== head) reason = 'H: WORK_PRESERVED must mean origin REALLY carries the rebased tip, not the pre-rebase copy';
          else if (Number(sh(G + ' --git-dir=' + root + '/origin.git for-each-ref refs/heads/ | wc -l').trim()) !== headsBefore) reason = 'H: the rescue must land on the ref 3f owns — no second head may be minted on origin';
        }
      }
    }

    // --- I: THE REFUSAL — origin carries work this worktree does not ------
    // The other half of #2103's bar: lease-guarded, never unguarded, and never
    // against a ref whose expected value was not read first. A lease stops a
    // CONCURRENT writer; it does not make overwriting a remote that holds
    // genuinely different work correct. This path runs unattended on an
    // already-failing item and nobody asked it to rewrite anything, so it
    // applies the operator's own manual-recovery criterion from the issue —
    // local history must SUPERSEDE the remote tip — and refuses otherwise.
    // A loud WORK_PRESERVE_FAILED naming the remote sha is recoverable;
    // destroying another writer's commits is not.
    if (!reason) {
      clone('wtI');
      commitOn('wtI', 'build/wti', 'm.txt');
      sh('cd wtI && ' + G + ' checkout -q -b theirs origin/main && printf theirs > theirs.txt && ' + G + ' add -A && ' + G + ' commit -q -m theirs && ' + G + ' push -q origin HEAD:refs/heads/fix/wti && ' + G + ' checkout -q build/wti');
      const theirs = sh(G + ' --git-dir=' + root + '/origin.git rev-parse refs/heads/fix/wti').trim();
      const i = run(root + '/wtI', 'fix/wti');
      if (i.outcome !== 'WORK_PRESERVE_FAILED') reason = 'I: the rescue must REFUSE when origin carries commits this worktree does not — a lease does not make that overwrite correct, got ' + JSON.stringify(i);
      else if (i.stale_remote_not_superseded !== true) reason = 'I: the refusal must be NAMED, so the operator disposing this escalation knows it is a reconcile and not a dead remote, got ' + JSON.stringify(i);
      else if (i.remote_sha !== theirs) reason = 'I: the refusal must report the remote value it read, so neither the flag nor the branch existence has to be trusted alone, got ' + JSON.stringify(i);
      else if (sh(G + ' --git-dir=' + root + '/origin.git rev-parse refs/heads/fix/wti').trim() !== theirs) reason = 'I: THE REFUSAL DID NOT HOLD — origin fix/wti was overwritten, destroying commits this worktree never had';
    }

    // --- J: THE PROBE THAT COULD NOT BE ANSWERED (#2103 review round 1) ---
    // Arm I refuses because the supersede check RAN and said no. This arm
    // refuses because the check could not run at all: the remote answered
    // \`ls-remote\` and then the \`fetch\` one step later failed (a network drop
    // mid-step, an expired credential). Refusing is right either way — but the
    // two must not be reported with the SAME flag, because
    // \`stale_remote_not_superseded\` is what the escalation log turns into the
    // flat assertion 'origin carries commits this worktree does NOT', and a
    // human disposes the parked item against that sentence. Here nothing was
    // established, so asserting it would be a fabricated fact handed to the
    // person least able to check it.
    if (!reason) {
      clone('wtJ');
      commitOn('wtJ', 'build/wtj', 'n.txt');
      sh('cd wtJ && ' + G + ' checkout -q -b theirsj origin/main && printf theirs > theirsj.txt && ' + G + ' add -A && ' + G + ' commit -q -m theirsj && ' + G + ' push -q origin HEAD:refs/heads/fix/wtj && ' + G + ' checkout -q build/wtj');
      const theirsJ = sh(G + ' --git-dir=' + root + '/origin.git rev-parse refs/heads/fix/wtj').trim();
      sh('mkdir -p stub');
      const realGit = sh('command -v git').trim();
      writeFileSync(root + '/stub/git',
        '#!/bin/sh\\n' +
        'sub=\"\"\\n' +
        'for a in \"\$@\"; do case \"\$a\" in -*) ;; *) sub=\"\$a\"; break ;; esac; done\\n' +
        'if [ \"\$sub\" = fetch ]; then exit 128; fi\\n' +
        'exec ' + realGit + ' \"\$@\"\\n');
      chmodSync(root + '/stub/git', 0o755);
      const j = runWithGitStub(root + '/wtJ', 'fix/wtj');
      if (j.outcome !== 'WORK_PRESERVE_FAILED') reason = 'J: an unanswerable supersede probe must still REFUSE — fail-safe is the whole point, got ' + JSON.stringify(j);
      else if (j.supersede_probe_failed !== true) reason = 'J: a refusal on an UNANSWERABLE probe must be named as one (supersede_probe_failed), got ' + JSON.stringify(j);
      else if (j.stale_remote_not_superseded !== undefined) reason = 'J: an unanswerable probe must NOT claim the remote carries unsuperseded work — that fact was never established, got ' + JSON.stringify(j);
      else if (j.remote_sha !== theirsJ) reason = 'J: the refusal must still report the remote value it read, got ' + JSON.stringify(j);
      else if (sh(G + ' --git-dir=' + root + '/origin.git rev-parse refs/heads/fix/wtj').trim() !== theirsJ) reason = 'J: THE REFUSAL DID NOT HOLD — origin fix/wtj was overwritten on a probe that never answered';
    }
  } catch (err) {
    reason = 'the REAL generated shell (or its git fixture) threw: ' + ((err && err.message) || err);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"


# --- K2020 static lockstep guards ------------------------------------------
grep -q '"tsv_lines":%s' "$MJS" \
  || fail "#2020: reviewDiffCmd's printf must emit tsv_lines (the surviving array shape), not the table as an inline scalar"
if grep -q '"tsv":%s' "$MJS"; then
  fail "#2020: reviewDiffCmd must no longer ship the routing table inline as a \`tsv\` scalar — that blob is the field the relay drops, paraphrases and double-encodes"
fi
grep -q 'function reviewDiffTsvText' "$MJS" \
  || fail "#2020: build-level.mjs must define reviewDiffTsvText() — the ONE normalizer for both wire shapes, so the gap check and the routing decision can never read the payload differently"
grep -q 'function preserveCommittedWorkCmd' "$MJS" \
  || fail "#2020: build-level.mjs must define preserveCommittedWorkCmd() — the post-commit branch push that makes an escalated item's work durable on origin"
grep -q 'function preserveOnEscalation' "$MJS" \
  || fail "#2020: build-level.mjs must define preserveOnEscalation() — the ONE escalation choke point, so every escalation kind (including ones added later) is covered without a per-call-site list"
grep -q '.then((r) => preserveOnEscalation(item, r))' "$MJS" \
  || fail "#2020: preserveOnEscalation must be applied to driveItem's SETTLED result at the parallel() call site — after the #437/#1819 catch, so a THROWN item's synthesized escalation is preserved too"
# Round-3 guards read the preservation step's OWN body, not the whole file:
# reviewDiffCmd and the merge-base builder each carry their own `default` chain
# (and may legitimately keep guessing `main` — a misresolve there costs a review
# route, not committed work), so a whole-file grep would bind the wrong code.
PRESERVE_BODY="$(awk '/^function preserveCommittedWorkCmd\(/,/^}$/' "$MJS")"
[ -n "$PRESERVE_BODY" ] \
  || fail "#2020: could not extract preserveCommittedWorkCmd()'s body — the guards below would silently pass over nothing"
printf '%s\n' "$PRESERVE_BODY" | grep 'git push origin "HEAD:refs/heads/\$branch"' >/dev/null \
  || fail "#2020: the preservation step must push HEAD to an EXPLICIT refs/heads/\$branch on origin — a local preservation ref does not survive \`git branch -D\`, and a bare \`git push origin HEAD\` sends the worktree's throwaway build/<slug> name instead of the plan branch 3f owns, minting a PR-less second ref nothing reclaims (temperloop#1688)"
if printf '%s\n' "$PRESERVE_BODY" | grep 'git push -u ' >/dev/null; then
  fail "#2020: the preservation push must not use -u — it is a one-shot rescue push and has no business writing branch.<name>.remote/.merge into the worktree config"
fi
grep -q 'preserveCommittedWorkCmd(wt, preserveBranch)' "$MJS" \
  || fail "#2020: preserveOnEscalation must hand preserveCommittedWorkCmd the PLAN's item.branch — the ref 3f pushes — not let the step read the worktree's local HEAD name"
printf '%s\n' "$PRESERVE_BODY" | grep 'base_resolved' >/dev/null \
  || fail "#2020: the preservation step must split 'zero commits ahead' from 'could not resolve a base' — a rev-list that failed because origin/\$default does not exist must never read as a genuine zero and take the WORK_PRESERVE_SKIP arm, which is the one outcome that suppresses the 'the worktree may be the ONLY copy' warning"
# Anchored at a template-literal backtick so it reads the emitted SHELL, not the
# comment that quotes the retired line.
if printf '%s\n' "$PRESERVE_BODY" | grep -E '^[[:space:]]*`.*default=main' >/dev/null; then
  fail "#2020: the preservation step must not GUESS a default branch — worktree.sh's default_branch() returns 1 rather than inventing one, and a wrong guess here degrades silently into a false 'no unlanded commits'"
fi
echo "PASS: #2020 review-diff relay + data-loss guards — the table ships as a tsv_lines ARRAY (no inline scalar), reviewDiffTsvText normalizes both shapes, a persistent gap DEGRADES instead of halting, and every escalation pushes committed work to origin at one choke point before returning"

# ============================================================================
# TEST (K1982 multi-match): build.md 3e's run-both rule ("A change matching
#   more than one axis ... runs each matching reviewer") exercised in ONE
#   review round against a diff that matches BOTH the tsv extension axis
#   (.sh -> shell-reviewer) AND the in-prose *.md fallback (a stranger-facing
#   .md with no tsv row of its own -> docs-reviewer) — the exact pairing
#   Path B's live failure collapsed down to (shell-reviewer silently missing,
#   docs-reviewer alone). Uses the LIVE tracked reviewer-routing.tsv, like the
#   K1705 cases above, so this is the routing TABLE's real content, not a
#   fixture restatement of it.
# ============================================================================
run_node_case "K1982 multi-match: a diff touching both .sh and a prose *.md resolves BOTH shell-reviewer and docs-reviewer in the SAME round, never just one" "
$PREAMBLE
const tsv = readFileSync('$REPO_ROOT/workflows/scripts/config/reviewer-routing.tsv', 'utf8');

setMachinery('multi-match',
  { outcome: 'CREATED', path: '/tmp/repo.wt/multi-match' },
  { outcome: 'REVIEW_DIFF', files: ['workflows/scripts/thing.sh', 'CONTRIBUTING.md'], tsv, tsv_rows: tsvRows(tsv), tsv_checksum: tsvChecksum(tsv) },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'a3b' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'a3b', branch: 'build/multi-match' },
  { outcome: 'PR_OPENED', pr_number: 1983 },
  { outcome: 'CI_GREEN' },
);
happyWorker('multi-match');
setReview('multi-match', 'shell: clean', 'docs: clean');

globalThis.args = { ...baseArgs, items: [
  { slug: 'multi-match', branch: 'build/multi-match', title: 'Touch a script and a doc', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();
let reason = null;
if ((result.parked ?? []).length !== 1) reason = 'expected 1 parked: ' + JSON.stringify(result);
const reviewCalls = callLog.filter(c => isReviewCall(c.opts));
const types = reviewCalls.map(c => c.opts.agentType).sort();
if (!reason && JSON.stringify(types) !== JSON.stringify(['docs-reviewer', 'shell-reviewer']))
  reason = 'expected exactly shell-reviewer AND docs-reviewer, both, in one round, got: ' + JSON.stringify(types);
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

# --- K1982 static lockstep guard: the content-checksum guard wiring ---------
grep -q 'function tsvChecksum' "$MJS" \
  || fail "#1982: build-level.mjs must define tsvChecksum() — the content-integrity check reviewDiffTsvGap uses to close path B (row-count-valid, content-garbled)"
grep -q 'tsv_checksum' "$MJS" \
  || fail "#1982: reviewDiffCmd must emit tsv_checksum alongside tsv_rows, and reviewDiffTsvGap must check it — the content guard against a relay copy that preserves row count but not content"
grep -q 'content_mismatch' "$MJS" \
  || fail "#1982: a row-count-valid but checksum-mismatched tsv must be reported naming content_mismatch, distinct from the row-count mismatch field"
# Round 2: the checksum must be POSITION-SENSITIVE, not a bare (commutative)
# sum — a commutative sum is blind to a same-row-count row REASSIGNMENT, the
# exact corruption shape temperloop#1978 round 4 showed. Pinning the literal
# weighting expression on BOTH sides (JS `* (i + 1)`, bash awk `s+=$i*n`)
# guards against a regression back to round 1's bare-sum shape.
grep -q 'canon.charCodeAt(i) \* (i + 1)' "$MJS" \
  || fail "#1982 round 2: tsvChecksum() must be POSITION-WEIGHTED (index-multiplied), not a bare commutative sum — see tsvChecksum()'s own comment for the row-transposition it must catch"
grep -Eq 's\+=\$i\*n' "$MJS" \
  || fail "#1982 round 2: reviewDiffCmd's bash checksum pipeline must weight each byte by its running position (n), matching tsvChecksum()'s JS-side weighting — a bare od|awk sum is commutative"
echo "PASS: #1982 review-diff content-checksum guard — reviewDiffCmd emits a POSITION-SENSITIVE tsv_checksum alongside tsv_rows, reviewDiffTsvGap detects a row-count-valid but content-garbled OR row-transposed tsv (path B), runReviewers retries once through the same command before escalating, and no roster is ever computed from a mismatched table"

# --- K1976 static lockstep guard: the relay-drop retry-then-escalate wiring --
grep -q 'function reviewDiffTsvGap' "$MJS" \
  || fail "#1976: build-level.mjs must define reviewDiffTsvGap() — the missing/mismatched-tsv guard, kept in legible .mjs rather than buried in prompt text"
grep -q 'tsv_rows' "$MJS" \
  || fail "#1976: reviewDiffCmd must emit tsv_rows alongside tsv, and runReviewers must check it — the row-count guard against a relay-truncated table"
# temperloop#1970 gave the closure a `bump` argument (the re-fetch must NOT
# advance the §3e round counter a second time within one driver round), so the
# guard pins the closure call WITH that argument rather than the bare form.
grep -q 'fetchReviewDiff(stagePhase(STAGE_REVIEW), false)' "$MJS" \
  || fail "#1976/#1970: the relay-drop guard must re-run the review-diff step through the SAME fetchReviewDiff() closure (never a re-derived command), and NON-BUMPING so one driver round advances the review-round counter exactly once"
# temperloop#2020 replaced the DISPOSITION after the retry: the still-incomplete
# gap now degrades (no reviewer routed, a legible skip notice) instead of
# escalating `review-diff-error`. The gap payload is still carried, now as
# `routing_degraded`, so the expected/got figures the detectors computed remain
# on the record — pin THAT, so a regression back to a fatal escalation (or to a
# silent drop of the payload) fails here.
grep -q 'routingDegraded = gap' "$MJS" \
  || fail "#1976/#2020: a still-incomplete tsv after the retry must DEGRADE carrying the gap payload as routing_degraded (never escalate review-diff-error, and never discard the missing/mismatch figures)"
grep -q 'routing_degraded: routingDegraded' "$MJS" \
  || fail "#1976/#2020: the carried gap payload must reach the returned record as routing_degraded — the field the Step 6 tally and the parked record read"
# temperloop#2020 round 2: the gap arm must FALL THROUGH to the routing
# decision with only the table-dependent axes withdrawn, never return early.
# Returning early dropped the MANDATORY command-doc route (foundation#1007),
# which is computed from `files` and never needed the table at all — so a
# `claude/commands/*.md` diff whose relay dropped reported mandatory_ok:true
# with workflow-reviewer never run. Pin the option that keeps them apart.
grep -q 'tableAvailable: !routingDegraded' "$MJS" \
  || fail "#2020: the degraded arm must call determineReviewers with tableAvailable:false (withdrawing ONLY the extension axis and the prose-*.md fallback) rather than returning before the routing decision — the mandatory command-doc rule never needed the table"
# `if grep`, never `grep && fail`: under `set -euo pipefail` a grep MISS is a
# non-zero exit that would abort the suite on the GOOD case (the same trap the
# comment at the top of this file's static-guard block already names).
if grep -q "escalate(item.slug, 'review-diff-error', gap)" "$MJS"; then
  fail "#2020: the post-retry gap must NOT escalate review-diff-error — that disposition halted a drive whose work was already committed (foundation#1869, run wf_967c2878-0a7)"
fi
echo "PASS: #1976/#2020 review-diff tsv-guard wiring — reviewDiffCmd emits tsv_rows, reviewDiffTsvGap detects a missing/mismatched tsv, runReviewers retries once through the same command and then DEGRADES with the gap payload rather than halting the drive"

# --- temperloop#1982 STRUCTURAL close: the reviewer-routing table is a STATIC
# repo file, so it rides the Step-0 orchestrator hand-off (the same seam as
# principlesSummaries / gateSliceSecs) instead of crossing the
# machinery-executor agent's verbatim-echo contract at all. The relay was
# mangled three distinct ways across eight occurrences — omitted, replaced by
# prose describing the table, and returned double-JSON-encoded (quotes plus
# literal \t/\n instead of real tabs/newlines, parsing as 1 row not 11).
# Guarding a value the agent should never have been carrying is the wrong
# layer; these assert the agent is OUT of the path, not better-checked.
grep -q 'REVIEWER_ROUTING_TSV' "$MJS" \
  || fail "#1982: build-level.mjs must define REVIEWER_ROUTING_TSV — the orchestrator-supplied routing table that removes the machinery-executor agent from this data's path"
grep -q "input.reviewerRoutingTsv" "$MJS" \
  || fail "#1982: REVIEWER_ROUTING_TSV must read input.reviewerRoutingTsv — the Step-0 hand-off seam, same shape as input.principlesSummaries"
grep -q '!REVIEWER_ROUTING_TSV && reviewDiffTsvGap' "$MJS" \
  || fail "#1982: the relay gap-check + retry must be SKIPPED when the orchestrator supplied the table — otherwise a run still pays a retry round-trip guarding a value it is not using"
grep -q 'const tsvText = REVIEWER_ROUTING_TSV' "$MJS" \
  || fail "#1982: determineReviewers must prefer REVIEWER_ROUTING_TSV over diffOut.tsv — the supplied table is authoritative when present"
# temperloop#2020 moved the relayed-table reader behind reviewDiffTsvText(),
# which accepts BOTH the current `tsv_lines` array and the legacy `tsv` scalar.
# The fallback this guard protects is unchanged in substance — an un-migrated
# caller must keep routing — so it now pins the normalizer and its legacy arm.
grep -q 'const tsvText = REVIEWER_ROUTING_TSV || reviewDiffTsvText(diffOut)' "$MJS" \
  || fail "#1982/#2020: the relayed-table fallback must REMAIN, read through reviewDiffTsvText() — an un-migrated caller (older orchestrator, consuming repo) must keep working unchanged"
grep -q "typeof diffOut?.tsv === 'string') return diffOut.tsv" "$MJS" \
  || fail "#2020: reviewDiffTsvText must still ACCEPT the legacy \`tsv\` scalar — dropping it would break a caller or replayed payload that carries the pre-#2020 wire shape"
echo "PASS: #1982 reviewer-routing hand-off — the static routing table is supplied by the orchestrator (input.reviewerRoutingTsv), is authoritative when present, skips the relay gap-check/retry it makes moot, and leaves the legacy relay path intact for an un-migrated caller"


# --- K1430 static lockstep guards: §3e mandatory/routed pre-push review ------
# build.md §3e is the SPEC; build-level.mjs's driveItem is the as-built
# encoding (the same lockstep discipline as every other *_BUILD_MD guard in
# this file). This asserts the CLASSIFICATION — the review is declared and
# ordered between 3d and 3e.5, spawning the reviewer directly — never the
# implementation details. An absent build.md is a HARD FAIL (temperloop#1438's
# own anti-pattern: a check that cannot run must never report PASS), never a
# skip-if-absent.
grep -q 'async function runReviewers' "$MJS" \
  || fail "#1430: build-level.mjs must define runReviewers() — the §3e driver that spawns the routed reviewer(s) itself"
grep -q 'function determineReviewers' "$MJS" \
  || fail "#1430: build-level.mjs must define determineReviewers() — the routing DECISION (kept in legible .mjs, DESIGN NOTE 1), never buried in an opaque agent prompt"
grep -q 'agentType: route.reviewer' "$MJS" \
  || fail "#1430: the reviewer must be spawned via agent({agentType}) directly — never delegated to the 3c worker"
grep -q 'foundation#1007' "$MJS" \
  || fail "#1430: the mandatory claude/commands/*.md -> workflow-reviewer rule (foundation#1007) must be named in build-level.mjs, not left to worker discretion"
grep -q 'MACHINERY_RESOLUTION_ERR.test(msg)' "$MJS" \
  || fail "#1430: reviewer-unavailability detection must reuse machineryAgent's own MACHINERY_RESOLUTION_ERR precedent (temperloop#1014), not a new ad hoc check"

# Ordering — §3e runs BETWEEN 3d (the anyFailed check) and 3e.5 (the gate), and
# 3e.5 still precedes 3f. A future edit that reorders these blocks — moving
# rather than removing the exact defect this item fixes — must fail here,
# unconditionally.
ANYFAILED_LINE="$(grep -n 'const anyFailed = ' "$MJS" | head -1 | cut -d: -f1)"
# temperloop#2127 widened this call site with an optional 3rd argument
# (priorReviewFindings) — matched as a PREFIX (no trailing `);`) so the
# ordering guard survives that widening without caring about its own arity.
REVIEW_CALL_LINE="$(grep -nE 'const review = await runReviewers\(item, wt' "$MJS" | head -1 | cut -d: -f1)"
GATE_MARKER_LINE="$(grep -n -- '--- 3e.5. Parent-side acceptance gate' "$MJS" | head -1 | cut -d: -f1)"
PR_MARKER_LINE="$(grep -n -- '--- 3f. Push and open the PR' "$MJS" | head -1 | cut -d: -f1)"
[ -n "$ANYFAILED_LINE" ] || fail "#1430: could not locate 3d's anyFailed check in build-level.mjs"
[ -n "$REVIEW_CALL_LINE" ] || fail "#1430: could not locate the runReviewers() call site in build-level.mjs"
[ -n "$GATE_MARKER_LINE" ] || fail "#1430: could not locate the 3e.5 acceptance-gate marker in build-level.mjs"
[ -n "$PR_MARKER_LINE" ] || fail "#1430: could not locate the 3f push/PR marker in build-level.mjs"
[ "$ANYFAILED_LINE" -lt "$REVIEW_CALL_LINE" ] \
  || fail "#1430: the §3e review must run AFTER 3d's anyFailed check, not before"
[ "$REVIEW_CALL_LINE" -lt "$GATE_MARKER_LINE" ] \
  || fail "#1430: the §3e review must run BEFORE 3e.5's acceptance gate — this is the ordering the whole item exists to fix"
[ "$GATE_MARKER_LINE" -lt "$PR_MARKER_LINE" ] \
  || fail "#1430: 3e.5 must still precede 3f — the review must not reorder the rest of the pipeline"
echo "PASS: #1430 review-ordering guard — determineReviewers/runReviewers spawn agent({agentType}) directly, reusing MACHINERY_RESOLUTION_ERR, strictly between 3d and 3e.5"

K1430_BUILD_MD="$REPO_ROOT/claude/commands/build.md"
[ -f "$K1430_BUILD_MD" ] \
  || fail "#1430: claude/commands/build.md is missing — the prose half of this contract pair cannot be verified"
grep -q 'foundation#1007' "$K1430_BUILD_MD" \
  || fail "#1430: build.md §3e must still name the mandatory command-doc rule (foundation#1007)"
grep -q 'workflow-reviewer' "$K1430_BUILD_MD" \
  || fail "#1430: build.md §3e must name workflow-reviewer"
grep -q 'orchestrator↔workflow boundary is irreversible-action plus single-writer' "$K1430_BUILD_MD" \
  || fail "#1430: build.md §3e must record WHY the review runs inside the workflow rather than the orchestrator (temperloop#1430's own rationale)"
echo "PASS: #1430 build.md rationale guard — §3e records why the review runs inside build-level.mjs, not the orchestrator"

# ============================================================================
# TEST 1219: §3e.6 class-A activation gate (temperloop#1219)
#
# The defect: build.md §3e.6 specified this gate; build-level.mjs — the DEFAULT
# Step-3 path since temperloop#998 — contained zero references to activation, and
# `activation` was absent from the items[] args contract, so the block never even
# crossed the orchestrator->workflow boundary. Every `activation: class: A` block
# plan.sh rule 14 forces onto a product-source item was inert on the default path.
#
# The four arms below are the whole contract:
#   a. a class-A proof that FAILS never reaches 3f (the gate actually runs)
#   b. an absence-asserting proof gets the temperloop#944 merge-base CONTROL pass
#      FIRST, and a control that PASSES (vacuous) escalates without ever running
#      the worktree copy
#   c. the OTHER control arm — a control that FAILS at the merge base
#      (discriminates) lets the worktree run proceed, and a Pass reaches 3f
#   d. no block / class B / class C take the byte-identical pre-#1219 path:
#      ZERO activation agent spawns, item parks green
# ============================================================================

# --- a. class-A proof FAILS → activation-failed, item never reaches 3f -------
run_node_case "1219 activation: a class-A proof that FAILS escalates activation-failed and never reaches 3f" "
$PREAMBLE

setMachinery('item-act-fail',
  { outcome: 'CREATED', path: '/tmp/repo.wt/item-act-fail' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'ACTIVATION_FAIL', exitCode: 1, detail: 'GeminiRunner not registered' },
);
happyWorker('item-act-fail');

globalThis.args = { ...baseArgs, items: [
  { slug: 'item-act-fail', branch: 'build/item-act-fail', title: 'Dormant feature', kind: 'impl',
    activation: { class: 'A', proof: 'grep -q GeminiRunner evals/runners/__init__.py' } },
]};

const mod = await loadLevel();
const result = await mod.default();
const bad = (r) => { console.log(JSON.stringify({ ok: false, reason: r })); process.exit(0); };

if ((result.escalations ?? []).length !== 1) bad('expected 1 escalation: ' + JSON.stringify(result));
const e = result.escalations[0];
if (e.kind !== 'activation-failed') bad('escalation kind wrong: ' + e.kind);
// temperloop#2135: every 'activation-*' kind buckets to round_kind 'activation'.
if (e.round_kind !== 'activation') bad('activation-failed round_kind must be activation, got: ' + e.round_kind);
if (e.payload.class !== 'A') bad('payload must name the class it gated: ' + JSON.stringify(e.payload));
if (e.payload.absenceAsserting !== false) bad('a presence proof must NOT be flagged absence-asserting');
if ((result.parked ?? []).length !== 0) bad('a dormant item must not park: ' + JSON.stringify(result.parked));

// The whole point of candidate 1: the gate fires BEFORE push/PR-open, so a Fail
// costs a loop-back to 3c, not a re-push onto an already-open PR.
const ran = stepsRun('item-act-fail');
if (ran.includes('push') || ran.includes('rebase') || ran.includes('pr-open'))
  bad('a failed activation gate must not reach 3f; steps ran: ' + JSON.stringify(ran));
// And it really was OUR gate that stopped it — one activation agent spawn.
const acts = callLog.filter(c => /^activation:/.test(String(c.opts.label || '')));
if (acts.length !== 1) bad('expected exactly 1 activation machinery call, got ' + acts.length);

console.log(JSON.stringify({ ok: true }));
"

# --- b. absence proof VACUOUS at the merge base ------------------------------
# temperloop#944's control pass is the criterion easiest to skip and the one that
# makes an absence proof mean anything: a proof that asserts a phrase is GONE
# passes trivially against a tree where it never existed. So it is run at the
# merge base FIRST, and a Pass there is a vacuity verdict — escalated WITHOUT
# even running the worker's copy (build.md §3e.6).
run_node_case "1219 activation: an absence proof that ALSO passes at the merge base is vacuous — escalated without running the worktree copy" "
$PREAMBLE

setMachinery('item-act-vac',
  { outcome: 'CREATED', path: '/tmp/repo.wt/item-act-vac' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'ACTIVATION_CONTROL_VACUOUS', base: 'deadbeefcafe', exitCode: 0, detail: '' },
);
happyWorker('item-act-vac');

globalThis.args = { ...baseArgs, items: [
  { slug: 'item-act-vac', branch: 'build/item-act-vac', title: 'Vacuous absence proof', kind: 'impl',
    activation: { class: 'A', proof: \"! tr '\\\\n' ' ' < claude/commands/workshop.md | tr -s ' ' | grep 'batched draft is still fine' >/dev/null\" } },
]};

const mod = await loadLevel();
const result = await mod.default();
const bad = (r) => { console.log(JSON.stringify({ ok: false, reason: r })); process.exit(0); };

if ((result.escalations ?? []).length !== 1) bad('expected 1 escalation: ' + JSON.stringify(result));
const e = result.escalations[0];
if (e.kind !== 'absence-proof-vacuous-at-merge-base') bad('escalation kind wrong: ' + e.kind);
if (e.payload.absenceAsserting !== true) bad('a proof opening with ! must be flagged absence-asserting');
if (e.payload.mergeBase !== 'deadbeefcafe') bad('payload must carry the merge base it controlled against');
if ((result.parked ?? []).length !== 0) bad('a vacuously-proven item must not park');

// The ordering IS the contract: control first, and on VACUOUS the worktree copy
// is never even consulted.
const ctl = callLog.filter(c => /^activation-control:/.test(String(c.opts.label || '')));
const acts = callLog.filter(c => /^activation:/.test(String(c.opts.label || '')));
if (ctl.length !== 1) bad('expected exactly 1 merge-base control call, got ' + ctl.length);
if (acts.length !== 0) bad('VACUOUS must escalate WITHOUT running the worktree copy; worktree runs: ' + acts.length);
const ran = stepsRun('item-act-vac');
if (ran.includes('push') || ran.includes('pr-open')) bad('a vacuous absence proof must not reach 3f: ' + JSON.stringify(ran));

console.log(JSON.stringify({ ok: true }));
"

# --- c. the OTHER control arm: DISCRIMINATES → worktree run → Pass → 3f ------
# Both arms of the control must be exercised. A control that FAILS at the merge
# base is the GOOD case: the predicate genuinely discriminates this item's work
# from an untouched tree, so the gate proceeds to the worker's copy.
run_node_case "1219 activation: an absence proof that FAILS at the merge base discriminates — the worktree run then proceeds and a Pass reaches 3f" "
$PREAMBLE

setMachinery('item-act-ok',
  { outcome: 'CREATED', path: '/tmp/repo.wt/item-act-ok' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'ACTIVATION_CONTROL_DISCRIMINATES', base: 'deadbeefcafe', exitCode: 1, detail: '' },
  { outcome: 'ACTIVATION_PASS', exitCode: 0, detail: '' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'a43' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'a43', branch: 'build/item-act-ok' },
  { outcome: 'PR_OPENED', pr_number: 777 },
  { outcome: 'CI_GREEN' },
);
happyWorker('item-act-ok');

globalThis.args = { ...baseArgs, items: [
  { slug: 'item-act-ok', branch: 'build/item-act-ok', title: 'Sound absence proof', kind: 'impl',
    activation: { class: 'A', proof: \"! tr '\\\\n' ' ' < claude/commands/build.md | tr -s ' ' | grep 'a phrase this item removed' >/dev/null\" } },
]};

const mod = await loadLevel();
const result = await mod.default();
const bad = (r) => { console.log(JSON.stringify({ ok: false, reason: r })); process.exit(0); };

if ((result.escalations ?? []).length !== 0) bad('expected 0 escalations: ' + JSON.stringify(result.escalations));
if ((result.parked ?? []).length !== 1) bad('expected the item to park: ' + JSON.stringify(result));
if (result.parked[0].pr !== 777) bad('parked PR wrong: ' + JSON.stringify(result.parked[0]));

const ctl = callLog.filter(c => /^activation-control:/.test(String(c.opts.label || '')));
const acts = callLog.filter(c => /^activation:/.test(String(c.opts.label || '')));
if (ctl.length !== 1) bad('expected exactly 1 merge-base control call, got ' + ctl.length);
if (acts.length !== 1) bad('expected exactly 1 worktree proof run, got ' + acts.length);
// Control BEFORE the worktree run, always.
if (callLog.indexOf(ctl[0]) > callLog.indexOf(acts[0])) bad('the merge-base control must run BEFORE the worktree copy');
// …and both must carry the identical predicate — a control run against a
// DIFFERENT command controls nothing.
if (!/a phrase this item removed/.test(ctl[0].promptFull)) bad('the control ran a different predicate than the item declared');
if (!/a phrase this item removed/.test(acts[0].promptFull)) bad('the worktree run used a different predicate than the item declared');

console.log(JSON.stringify({ ok: true }));
"

# --- c2. the control could not be ESTABLISHED → its own UNKNOWN kind ---------
run_node_case "1219 activation: a merge-base control that cannot be ESTABLISHED is an UNKNOWN, not a pass — activation-control-unavailable, no push" "
$PREAMBLE

setMachinery('item-act-err',
  { outcome: 'CREATED', path: '/tmp/repo.wt/item-act-err' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'ACTIVATION_CONTROL_ERROR', detail: 'cannot materialize the merge-base worktree' },
);
happyWorker('item-act-err');

globalThis.args = { ...baseArgs, items: [
  { slug: 'item-act-err', branch: 'build/item-act-err', title: 'Control unavailable', kind: 'impl',
    activation: { class: 'A', proof: \"! grep 'gone' file.md >/dev/null\" } },
]};

const mod = await loadLevel();
const result = await mod.default();
const bad = (r) => { console.log(JSON.stringify({ ok: false, reason: r })); process.exit(0); };

if ((result.escalations ?? []).length !== 1) bad('expected 1 escalation: ' + JSON.stringify(result));
if (result.escalations[0].kind !== 'activation-control-unavailable') bad('escalation kind wrong: ' + result.escalations[0].kind);
if ((result.parked ?? []).length !== 0) bad('an unestablished control must not park the item');
const ran = stepsRun('item-act-err');
if (ran.includes('push') || ran.includes('pr-open')) bad('must not reach 3f: ' + JSON.stringify(ran));
const acts = callLog.filter(c => /^activation:/.test(String(c.opts.label || '')));
if (acts.length !== 0) bad('an unestablished control must not fall through to the worktree run');

console.log(JSON.stringify({ ok: true }));
"

# --- c3. a class-A block with no proof: is a hard escalation, never a skip ---
run_node_case "1219 activation: a class-A block that arrives with NO proof: escalates activation-proof-missing (no fallback actor, temperloop#1451)" "
$PREAMBLE

setMachinery('item-act-nop',
  { outcome: 'CREATED', path: '/tmp/repo.wt/item-act-nop' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
);
happyWorker('item-act-nop');

globalThis.args = { ...baseArgs, items: [
  { slug: 'item-act-nop', branch: 'build/item-act-nop', title: 'No predicate', kind: 'impl',
    activation: { class: 'A' } },
]};

const mod = await loadLevel();
const result = await mod.default();
const bad = (r) => { console.log(JSON.stringify({ ok: false, reason: r })); process.exit(0); };

if ((result.escalations ?? []).length !== 1) bad('expected 1 escalation: ' + JSON.stringify(result));
if (result.escalations[0].kind !== 'activation-proof-missing') bad('escalation kind wrong: ' + result.escalations[0].kind);
if ((result.parked ?? []).length !== 0) bad('a no-predicate class-A item must not park (that is the #1451 silent no-op)');
const ran = stepsRun('item-act-nop');
if (ran.includes('push')) bad('must not reach 3f: ' + JSON.stringify(ran));

console.log(JSON.stringify({ ok: true }));
"

# --- d. regression guard: no block / class B / class C are UNAFFECTED --------
# build-level.mjs is the default driver for EVERY item; a change that perturbs
# the common path would be worse than the gap it closes. All three items below
# run the UNMODIFIED 8-outcome happy queue — if the gate spawned even one agent
# for them, that queue would desync and the case would fail.
run_node_case "1219 activation: an item with NO block, or class B/C, takes the byte-identical path — zero activation agent spawns" "
$PREAMBLE

happyMachinery('item-none', 201, 'ae42');
happyMachinery('item-b', 202, 'ab06');
happyMachinery('item-c', 203, 'ac09');
happyWorker('item-none');
happyWorker('item-b');
happyWorker('item-c');

globalThis.args = { ...baseArgs, items: [
  { slug: 'item-none', branch: 'build/item-none', title: 'No activation block', kind: 'impl' },
  { slug: 'item-b', branch: 'build/item-b', title: 'Class B', kind: 'impl',
    activation: { class: 'B', watermark: 'v0.36.0' } },
  { slug: 'item-c', branch: 'build/item-c', title: 'Class C', kind: 'impl',
    activation: { class: 'C', 'soak-until': '2026-09-01' } },
]};

const mod = await loadLevel();
const result = await mod.default();
const bad = (r) => { console.log(JSON.stringify({ ok: false, reason: r })); process.exit(0); };

if ((result.escalations ?? []).length !== 0) bad('expected 0 escalations: ' + JSON.stringify(result.escalations));
if ((result.parked ?? []).length !== 3) bad('all three must park green: ' + JSON.stringify(result));
const touched = callLog.filter(c => /^activation(-control)?:/.test(String(c.opts.label || '')));
if (touched.length !== 0) bad('the gate must not spawn ANY agent for a non-class-A item, got ' + touched.length);

console.log(JSON.stringify({ ok: true }));
"

# --- Static guards: the boundary crossing and the ORDERING -------------------
# The items[] args contract is where the defect actually lived: the gate could
# not run because `activation` was not on it. Assert the crossing in BOTH
# surfaces (the orchestrator prose that produces it, the workflow header that
# consumes it), so removing either half fails here.
K1219_BUILD_MD="$REPO_ROOT/claude/commands/build.md"
[ -f "$K1219_BUILD_MD" ] || fail "#1219: claude/commands/build.md is missing"
grep -q 'notes, dependsOn, activation }' "$K1219_BUILD_MD" \
  || fail "#1219: build.md Step 3's items[] element must name \`activation\` — without it the block never crosses the orchestrator->workflow boundary and §3e.6 is dead"
grep -q '\*\*`activation`\*\* — the item' "$K1219_BUILD_MD" \
  || fail "#1219: build.md Step 3 must document how the \`activation\` arg is resolved, like every other item arg"
grep -q 'dependsOn, activation }' "$MJS" \
  || fail "#1219: build-level.mjs's I/O CONTRACT must name \`activation\` on the items[] element it consumes"
grep -q 'runActivationGate' "$MJS" \
  || fail "#1219: build-level.mjs must implement the §3e.6 class-A activation gate (runActivationGate)"
grep -q 'ACTIVATION_CONTROL_VACUOUS' "$MJS" \
  || fail "#1219/#944: the merge-base control pass must be implemented — an absence proof with no control run proves nothing"
echo "PASS: #1219 boundary guard — \`activation\` crosses the orchestrator->workflow contract in both surfaces, and the gate + its #944 control exist"

# Ordering — §3e.6 runs strictly BETWEEN 3e.5's gate and 3f's push/PR-open. This
# is candidate 1 (the operator-chosen fix) as opposed to candidate 2: run it
# after 3f and a Fail costs a re-push onto an already-open PR instead of a
# loop-back to 3c. A future edit that MOVES the call — rather than removing it —
# must fail here, unconditionally.
# round 2 (temperloop#1937 shell-reviewer MEDIUM, applied here too so the two
# mirrored ordering guards stay identical in shape): under `set -e`/`pipefail`
# a grep MISS inside this substitution pipeline is a non-zero exit that aborts
# the whole script before the `[ -n ]` guard below ever gets to report it
# legibly. `|| true` inside each substitution lets a miss fall through to an
# EMPTY variable instead, so the `[ -n ]` guard is what actually fires.
K1219_GATE_LINE="$(grep -n -- '--- 3e.5. Parent-side acceptance gate' "$MJS" | head -1 | cut -d: -f1 || true)"
K1219_ACT_LINE="$(grep -n 'const activationEscalation = await runActivationGate' "$MJS" | head -1 | cut -d: -f1 || true)"
K1219_PR_LINE="$(grep -n -- '--- 3f. Push and open the PR' "$MJS" | head -1 | cut -d: -f1 || true)"
[ -n "$K1219_GATE_LINE" ] || fail "#1219: could not locate the 3e.5 acceptance-gate marker in build-level.mjs"
[ -n "$K1219_ACT_LINE" ] || fail "#1219: could not locate the §3e.6 activation-gate call site in driveItem"
[ -n "$K1219_PR_LINE" ] || fail "#1219: could not locate the 3f push/PR marker in build-level.mjs"
[ "$K1219_GATE_LINE" -lt "$K1219_ACT_LINE" ] \
  || fail "#1219: the §3e.6 activation gate must run AFTER 3e.5's acceptance gate"
[ "$K1219_ACT_LINE" -lt "$K1219_PR_LINE" ] \
  || fail "#1219: the §3e.6 activation gate must run BEFORE 3f pushes — that is the whole reason candidate 1 was chosen over a parent-side check after the workflow returns"
echo "PASS: #1219 ordering guard — the class-A activation gate is called from driveItem strictly between 3e.5 and 3f"

# ============================================================================
# TEST 1219-e2e: the gate's GENERATED SHELL, executed for real
#
# Every case above drives the .mjs through the mock, which never RUNS the shell
# the driver synthesizes — so a quoting or dialect bug in activationProofCmd() /
# activationControlCmd() would be invisible to all of them (kernel principle 4:
# verify at the human-AI seam; the seam here is "the .mjs writes shell text a
# subagent then executes"). This case closes that: it drives the real driver,
# lifts the command text out of the executor prompt it produced, and runs it
# against a REAL git fixture — asserting the JSON outcome the driver would
# branch on. It is also the only place the temperloop#944 control pass is
# exercised end-to-end, materializing an actual merge-base worktree.
# ============================================================================
K1219_E2E="$WF_TEST_TMPDIR/e2e"
mkdir -p "$K1219_E2E"

# --- fixture: a repo whose branch REMOVES a phrase origin/main still has ------
# Built as ONE checkout with a bare `origin` pushed from it, never `git clone`:
# a clone of a bare repo whose HEAD names a branch that does not exist leaves an
# UNBORN head, and the next `checkout -b` then silently produces an ORPHAN branch
# with no merge-base at all — a broken fixture that would make every assertion
# below measure nothing (it did, on the first draft of this case).
mkdir -p "$K1219_E2E/repo.wt/x"
git init --quiet --bare "$K1219_E2E/origin.git"
(
  set -e
  cd "$K1219_E2E/repo.wt/x"
  git init --quiet .
  git symbolic-ref HEAD refs/heads/main
  git config user.email t@example.com
  git config user.name t
  # The phrase is WRAPPED across two physical lines on purpose: a bare
  # `! grep -q '<phrase>'` can never match it (grep is line-oriented), which is
  # exactly the temperloop#930 vacuity this fixture must be able to expose.
  printf 'intro line\nthe batched draft\nis still fine here\ntail line\n' > doc.md
  printf 'placeholder\n' > reg.py
  git add -A && git commit --quiet -m base
  git remote add origin "$K1219_E2E/origin.git"
  git push --quiet -u origin main
  # The item's "work": remove the wrapped phrase, and register the runner.
  git checkout --quiet -b build/x
  printf 'intro line\ntail line\n' > doc.md
  printf 'from .gemini import GeminiRunner\n' > reg.py
  git add -A && git commit --quiet -m work
) || fail "#1219-e2e: could not build the git fixture"
# Fixture self-check — an orphan branch has no merge-base, so assert one exists
# before trusting anything the control pass reports.
git -C "$K1219_E2E/repo.wt/x" merge-base HEAD origin/main >/dev/null 2>&1 \
  || fail "#1219-e2e: the fixture branch has no merge-base against origin/main — the fixture is broken, not the gate"

# --- lift the generated command text out of the driver's own executor prompt --
k1219_emit() { # <label> <proof> <outfile-prefix>
  # The case body is written to a temp .mjs and run with `node <file>` — the
  # same shape run_node_case uses, and for the same reason: $PREAMBLE contains
  # backticks and `$`, which a `node -e "…"` double-quoted bash argument would
  # let the SHELL expand before node ever saw them.
  local k1219_case="$WF_TEST_TMPDIR/e2e-$1.mjs"
  printf '%s\n' "$PREAMBLE" > "$k1219_case"
  printf '%s\n' "$K1219_EMIT_BODY" >> "$k1219_case"
  MJS_PATH="$MJS" AGENT_DEF_PATH="$AGENT_DEF" \
  K1219_ROOT="$K1219_E2E/repo" K1219_PROOF="$2" K1219_OUT="$3" \
  node "$k1219_case" >/dev/null || fail "#1219-e2e: could not emit the generated command for $1 (node failed)"
}

read -r -d '' K1219_EMIT_BODY << 'K1219_EMIT_END' || true
import { writeFileSync } from 'fs';
setMachinery('x',
  { outcome: 'CREATED', path: process.env.K1219_ROOT + '.wt/x' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  // Both activation calls are answered VACUOUS/FAIL so the driver stops after
  // emitting them — we only want the command TEXT, not a full drive.
  { outcome: 'ACTIVATION_CONTROL_VACUOUS', base: 'x' },
);
happyWorker('x');
globalThis.args = { ...baseArgs, repoRoot: process.env.K1219_ROOT, items: [
  { slug: 'x', branch: 'build/x', title: 'e2e', kind: 'impl',
    activation: { class: 'A', proof: process.env.K1219_PROOF } },
]};
const mod = await loadLevel();
await mod.default();
for (const c of callLog) {
  const l = String(c.opts.label || '');
  if (!/^activation(-control)?:/.test(l)) continue;
  const body = c.promptFull.split(/\nCommand:\n/)[1];
  if (!body) { console.error('no Command: section in the executor prompt'); process.exit(1); }
  writeFileSync(process.env.K1219_OUT + (l.startsWith('activation-control') ? '.control.sh' : '.proof.sh'), body);
}
K1219_EMIT_END

# A control-only emit (absence proof) — the driver stops at the control call, so
# only .control.sh is written. Run it for real against the fixture.
# NB: every stage is `|| true`-guarded. This file runs under `set -euo pipefail`,
# so a generated command that is BROKEN (prints no JSON at all — the exact
# regression this case exists to catch) would otherwise make the command
# substitution non-zero and abort the whole suite SILENTLY, with no failing test
# name. Swallowing the status here lets the explicit `|| fail` below name it.
k1219_run() { { bash "$1" 2>/dev/null || true; } | { grep -o '"outcome":"[A-Z_]*"' || true; } | head -1; }

# 1. ABSENCE proof, wrap-immune form, phrase genuinely removed by the branch.
#    At the MERGE BASE the phrase is present (wrapped!), so the predicate must
#    FAIL there → DISCRIMINATES. This is the arm that makes an absence proof mean
#    something, and the one a bare `! grep -q` would get wrong.
k1219_emit sound "! tr '\n' ' ' < doc.md | tr -s ' ' | grep 'batched draft is still fine' >/dev/null" "$K1219_E2E/sound"
[ -f "$K1219_E2E/sound.control.sh" ] || fail "#1219-e2e: no control command was generated for an absence-asserting proof"
K1219_R="$(k1219_run "$K1219_E2E/sound.control.sh")"
[ "$K1219_R" = '"outcome":"ACTIVATION_CONTROL_DISCRIMINATES"' ] \
  || fail "#1219-e2e/#944: a sound absence proof must FAIL at the merge base (DISCRIMINATES); got $K1219_R"
echo "PASS: #1219-e2e control/sound — the generated merge-base control runs for real and the wrap-immune absence proof FAILS at the base"

# 2. ABSENCE proof for a phrase that NEVER existed — passes at the merge base,
#    so it proves nothing about this item's work. The vacuity arm.
k1219_emit vac "! tr '\n' ' ' < doc.md | tr -s ' ' | grep 'a phrase that never existed' >/dev/null" "$K1219_E2E/vac"
K1219_R="$(k1219_run "$K1219_E2E/vac.control.sh")"
[ "$K1219_R" = '"outcome":"ACTIVATION_CONTROL_VACUOUS"' ] \
  || fail "#1219-e2e/#944: an absence proof for a never-present phrase must read VACUOUS at the merge base; got $K1219_R"
echo "PASS: #1219-e2e control/vacuous — a proof that also passes at the merge base is caught as vacuous, not waved through"

# 3. The merge-base worktree must be CLEANED UP — a gate that leaks a worktree
#    per class-A item is its own drift class (kernel § Environment hygiene).
K1219_WT_COUNT="$(git -C "$K1219_E2E/repo.wt/x" worktree list | wc -l | tr -d ' ')"
[ "$K1219_WT_COUNT" = "1" ] \
  || fail "#1219-e2e: the throwaway merge-base worktree leaked ($K1219_WT_COUNT entries in 'git worktree list')"
echo "PASS: #1219-e2e cleanup — the throwaway merge-base worktree is removed, leaking nothing"

# 3b. THE PREDICATE MUST NOT BE RUN UNDER `set -o pipefail`.
#     Imposing pipefail on the AUTHOR'S OWN predicate silently rewrites its
#     meaning, in the one direction that makes this gate theater. pipefail
#     reports the rightmost NON-ZERO status, and any predicate whose tail exits
#     early (`grep -q`, `head`) SIGPIPEs its upstream writer, which dies 141 —
#     so an ABSENCE proof that should FAIL inverts to a PASS:
#         `! <big writer> | head -1 >/dev/null`
#            with pipefail: 141 -> `!` -> 0  == false PASS
#            correct:         0 -> `!` -> 1  == FAIL
#     The predicate below is tree-independent and deterministic, so at the merge
#     base it must read DISCRIMINATES (predicate failed). Under pipefail it would
#     read VACUOUS instead — which is how this case discriminates.
#     `scripts/lint-pipe-grep-q.sh` (temperloop#1050) guards the same footgun
#     tree-wide; this pins it for generated predicate text, which that lint
#     cannot see.
k1219_emit nopipefail "! seq 1 3000000 | head -1 >/dev/null" "$K1219_E2E/nopf"
K1219_R="$(k1219_run "$K1219_E2E/nopf.control.sh")"
[ "$K1219_R" = '"outcome":"ACTIVATION_CONTROL_DISCRIMINATES"' ] \
  || fail "#1219-e2e: the proof: predicate must NOT run under \`set -o pipefail\` — an early-exiting tail SIGPIPEs its writer and inverts an absence proof into a false PASS; got $K1219_R"
for k1219_fn in activationProofCmd activationControlCmd; do
  # Comment lines are stripped first: both builders explain in prose WHY they
  # omit pipefail, and a guard that fires on documentation of the thing it
  # guards is the temperloop#1152 defect class (lint-pipe-grep-q.sh's own header
  # names it).
  if awk "/^function $k1219_fn/,/^}/" "$MJS" | grep -v '^[[:space:]]*//' | grep 'pipefail' >/dev/null; then
    fail "#1219-e2e: $k1219_fn must not impose \`set -o pipefail\` on the author's own proof: predicate (see the DO NOT ADD note in build-level.mjs)"
  fi
done
echo "PASS: #1219-e2e no-pipefail — the author's predicate runs with its own pipeline semantics; an early-exiting tail cannot invert an absence proof into a false pass"

# 4. PRESENCE proof (no control run) — Pass and Fail, executed for real. This is
#    where a quoting bug in activationProofCmd() would surface, and it confirms
#    the un-piped exit read reports the predicate's OWN status.
k1219_emit pass "grep GeminiRunner reg.py >/dev/null" "$K1219_E2E/pass"
[ -f "$K1219_E2E/pass.control.sh" ] && fail "#1219-e2e: a PRESENCE proof must NOT get a merge-base control run (#944 is absence-only)"
K1219_R="$(k1219_run "$K1219_E2E/pass.proof.sh")"
[ "$K1219_R" = '"outcome":"ACTIVATION_PASS"' ] \
  || fail "#1219-e2e: a presence proof whose wiring IS in place must report ACTIVATION_PASS; got $K1219_R"
k1219_emit fail "grep NeverRegisteredRunner reg.py >/dev/null" "$K1219_E2E/fail"
K1219_R="$(k1219_run "$K1219_E2E/fail.proof.sh")"
[ "$K1219_R" = '"outcome":"ACTIVATION_FAIL"' ] \
  || fail "#1219-e2e: a presence proof whose wiring is ABSENT must report ACTIVATION_FAIL; got $K1219_R"
echo "PASS: #1219-e2e proof — the generated worktree predicate runs for real, reports the predicate's own exit status, and skips the control on a presence proof"

# ============================================================================
# TEST 1937-e2e: the gate-freshness step's GENERATED SHELL, executed for real
# against REAL LINKED worktrees (temperloop#1937 round 3, HIGH).
#
# Every mock-level case above intercepts the 'gate-freshness:' label and never
# runs the shell gateFreshnessCmd()/gateFreshnessTimeoutProbeCmd() actually
# generate — so the round-3 HIGH defect (`[ -d .git/rebase-merge ]`, which is
# ALWAYS false in a `git worktree add` worktree because its `.git` is a
# pointer FILE, not a directory) was invisible to every one of them. This case
# closes that: it drives the real driver, lifts the generated command text out
# of the executor prompt it produced (mirroring the #1219-e2e pattern above),
# and runs it against REAL linked worktrees off a real bare origin.
# ============================================================================
K1937_E2E="$WF_TEST_TMPDIR/freshness-e2e"
mkdir -p "$K1937_E2E"

git init --quiet --bare "$K1937_E2E/origin.git"
mkdir -p "$K1937_E2E/main-checkout"
(
  set -e
  cd "$K1937_E2E/main-checkout"
  git init --quiet .
  git symbolic-ref HEAD refs/heads/main
  git config user.email t@example.com
  git config user.name t
  mkdir -p scripts
  printf '#!/bin/sh\nexit 0\n' > scripts/quality-gates.sh
  chmod +x scripts/quality-gates.sh
  printf 'line1\nSHARED\nline3\n' > f.txt
  git add -A && git commit --quiet -m base
  git remote add origin "$K1937_E2E/origin.git"
  git push --quiet -u origin main
) || fail "#1937-e2e: could not build the base fixture"

# Three REAL LINKED worktrees (`git worktree add`, never a plain `git init`
# checkout) — one per scenario — all branched from main BEFORE main moves on.
git -C "$K1937_E2E/main-checkout" worktree add --quiet "$K1937_E2E/repo.wt/conf" -b build/conf main \
  || fail "#1937-e2e: could not create the conflict-scenario linked worktree"
git -C "$K1937_E2E/main-checkout" worktree add --quiet "$K1937_E2E/repo.wt/mid" -b build/mid main \
  || fail "#1937-e2e: could not create the mid-rebase-scenario linked worktree"
git -C "$K1937_E2E/main-checkout" worktree add --quiet "$K1937_E2E/repo.wt/nogate" -b build/nogate main \
  || fail "#1937-e2e: could not create the no-gate-scenario linked worktree"

# Fixture self-check — a linked worktree's `.git` is a POINTER FILE, never a
# directory. This is the EXACT condition the round-3 HIGH fix depends on: a
# fixture that got this wrong (a plain `git init` checkout, say) would let the
# pre-fix `[ -d .git/rebase-merge ]` test pass by accident and prove nothing.
[ -f "$K1937_E2E/repo.wt/conf/.git" ] \
  || fail "#1937-e2e: fixture worktree's .git is not a pointer FILE — this fixture does not exercise the linked-worktree shape this item fixes"

for k1937_d in conf mid; do
  (
    set -e
    cd "$K1937_E2E/repo.wt/$k1937_d"
    printf 'line1\nWORKER-%s\nline3\n' "$k1937_d" > f.txt
    git add -A && git commit --quiet -m "work-$k1937_d"
  ) || fail "#1937-e2e: could not commit the worker-side change for $k1937_d"
done

# origin/main moves on with a CONFLICTING edit to the SAME line, after every
# worktree above branched from the old tip — the live #1934 shape this item fixes.
(
  set -e
  cd "$K1937_E2E/main-checkout"
  printf 'line1\nMAIN-MOVED-ON\nline3\n' > f.txt
  git add -A && git commit --quiet -m main-moved-on
  git push --quiet origin main
) || fail "#1937-e2e: could not advance origin/main past the fixture worktrees"

# The no-gate scenario's own branch removes the vendored gate script, so its
# worktree genuinely has none (round 3 HIGH: the presence-gated no-op path).
(
  set -e
  cd "$K1937_E2E/repo.wt/nogate"
  git rm --quiet -f scripts/quality-gates.sh
  git commit --quiet -m "remove gate script for the e2e no-gate scenario"
) || fail "#1937-e2e: could not remove the gate script on the no-gate branch"

# --- lift the generated command text out of the driver's own executor prompt --
# Mirrors the #1219-e2e emit pattern exactly: a single static heredoc body,
# parameterized through env vars (never textual interpolation), run via
# `node <file>` for the same reason #1219-e2e uses it — $PREAMBLE contains
# backticks and `$`, which a `node -e "…"` bash argument would let the shell
# expand before node ever saw them.
read -r -d '' K1937_EMIT_BODY << 'K1937_EMIT_END' || true
import { writeFileSync } from 'fs';
const k1937Slug = process.env.K1937_SLUG;
setFreshness(k1937Slug,
  { outcome: 'FRESHNESS_TIMEOUT' },
  { outcome: 'FRESHNESS_TIMEOUT_PROBE', rebase_in_progress: false, aborted: false },
);
setMachinery(k1937Slug,
  { outcome: 'CREATED', path: process.env.K1937_ROOT + '/repo.wt/' + process.env.K1937_DIR },
  { outcome: 'REVIEW_DIFF' },
);
happyWorker(k1937Slug);
globalThis.args = { ...baseArgs, repoRoot: process.env.K1937_ROOT + '/repo', items: [
  { slug: k1937Slug, branch: 'build/' + k1937Slug, title: 'e2e', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
await mod.default();
const freshCalls = callLog.filter(c => /^gate-freshness:/.test(String(c.opts.label || '')));
if (freshCalls[0]) writeFileSync(process.env.K1937_OUT + '.main.sh', freshCalls[0].promptFull.split(/\nCommand:\n/)[1] || '');
if (freshCalls[1]) writeFileSync(process.env.K1937_OUT + '.probe.sh', freshCalls[1].promptFull.split(/\nCommand:\n/)[1] || '');
K1937_EMIT_END

k1937_emit() { # <slug> <worktree-dir-name> <outfile-prefix> [fixture-root, default $K1937_E2E]
  local k1937_case="$WF_TEST_TMPDIR/e2e-fresh-$1.mjs"
  printf '%s\n' "$PREAMBLE" > "$k1937_case"
  printf '%s\n' "$K1937_EMIT_BODY" >> "$k1937_case"
  MJS_PATH="$MJS" AGENT_DEF_PATH="$AGENT_DEF" \
  K1937_ROOT="${4:-$K1937_E2E}" K1937_SLUG="$1" K1937_DIR="$2" K1937_OUT="$3" \
  node "$k1937_case" >/dev/null || fail "#1937-e2e: could not emit the generated command for $1 (node failed)"
}

k1937_run() { { bash "$1" 2>/dev/null || true; } | { grep -o '"outcome":"[A-Z_]*"' || true; } | head -1; }

# 1. CONFLICT scenario: run the REAL generated gateFreshnessCmd() shell against
#    the real conflicting linked worktree.
k1937_emit conf conf "$K1937_E2E/conf"
[ -s "$K1937_E2E/conf.main.sh" ] || fail "#1937-e2e: no gate-freshness command was generated for the conflict scenario"
K1937_FULL="$(bash "$K1937_E2E/conf.main.sh" 2>/dev/null || true)"
K1937_R="$(printf '%s' "$K1937_FULL" | grep -o '"outcome":"[A-Z_]*"' | head -1)"
[ "$K1937_R" = '"outcome":"FRESHNESS_CONFLICT"' ] \
  || fail "#1937-e2e: a real conflicting rebase must report FRESHNESS_CONFLICT; got $K1937_R (full: $K1937_FULL)"
printf '%s' "$K1937_FULL" | grep '"conflict_files":\["f.txt"\]' >/dev/null \
  || fail "#1937-e2e: FRESHNESS_CONFLICT must name f.txt as the conflicting file: $K1937_FULL"
printf '%s' "$K1937_FULL" | grep -i 'conflict' >/dev/null \
  || fail "#1937-e2e (round 3 MEDIUM): FRESHNESS_CONFLICT must carry git's own rebase output as detail: $K1937_FULL"
# The worktree must be left INTACT on its pre-rebase commit — never a
# half-applied rebase, never a silent revert.
git -C "$K1937_E2E/repo.wt/conf" status --porcelain | grep . >/dev/null \
  && fail "#1937-e2e: the worktree must be clean after the abort, but git status reports changes"
[ "$(git -C "$K1937_E2E/repo.wt/conf" log -1 --format=%s)" = "work-conf" ] \
  || fail "#1937-e2e: the worktree must be left on its own pre-rebase commit (work-conf), not mid-rebase or reverted"
echo "PASS: #1937-e2e conflict — the real generated gate-freshness shell detects and reports a genuine conflict, with detail, and leaves the worktree intact"

# 2. NO-GATE scenario: the presence check short-circuits before any fetch, on
#    a worktree with a REAL missing gate script (round 3 HIGH).
k1937_emit nogate nogate "$K1937_E2E/nogate"
[ -s "$K1937_E2E/nogate.main.sh" ] || fail "#1937-e2e: no gate-freshness command was generated for the no-gate scenario"
K1937_R="$(k1937_run "$K1937_E2E/nogate.main.sh")"
[ "$K1937_R" = '"outcome":"FRESHNESS_NO_GATE"' ] \
  || fail "#1937-e2e (round 3 HIGH): a worktree with no vendored quality-gates.sh must report FRESHNESS_NO_GATE without attempting a fetch/rebase; got $K1937_R"
echo "PASS: #1937-e2e no-gate — the real generated shell's presence check short-circuits before any fetch on a genuinely gate-absent worktree"

# 3. MID-REBASE scenario: start a REAL rebase by hand so it stops mid-conflict
#    (an actual in-progress rebase on disk), THEN run the generated
#    gateFreshnessTimeoutProbeCmd() shell for real and assert it detects and
#    aborts it via `git rebase --abort`'s own exit status — round 3 HIGH: a
#    literal `[ -d .git/rebase-merge ]` test is ALWAYS false in this linked
#    worktree (its `.git` is a pointer file), so this is the one assertion
#    that would have caught the pre-fix defect red-handed.
k1937_emit mid mid "$K1937_E2E/mid"
[ -s "$K1937_E2E/mid.probe.sh" ] || fail "#1937-e2e: no timeout-probe command was generated for the mid-rebase scenario"
(
  cd "$K1937_E2E/repo.wt/mid"
  git fetch --quiet origin main
  # This rebase is EXPECTED to conflict and exit non-zero (that is the whole
  # point — it is what leaves a real in-progress rebase on disk) — `|| true`
  # so its non-zero exit under this script's inherited `set -e` does not
  # abort the whole test suite.
  git rebase origin/main >/dev/null 2>&1 || true
)
# Fixture self-check: the hand-run rebase above must actually be stuck
# mid-conflict before the probe is asked to find it.
K1937_GD="$(git -C "$K1937_E2E/repo.wt/mid" rev-parse --git-dir)"
if [ ! -d "$K1937_GD/rebase-merge" ] && [ ! -d "$K1937_GD/rebase-apply" ]; then
  fail "#1937-e2e: fixture self-check failed — the hand-run rebase did not leave an in-progress rebase on disk for the probe to find"
fi
# ONE invocation only — the probe's own job is to ABORT what it finds, so a
# second run against the same tree would find nothing and silently pass for
# the wrong reason. Capture the full output once and assert on both fields
# from that single execution.
K1937_PROBE_OUT="$(bash "$K1937_E2E/mid.probe.sh" 2>/dev/null || true)"
K1937_R="$(printf '%s' "$K1937_PROBE_OUT" | grep -o '"outcome":"[A-Z_]*"' | head -1)"
[ "$K1937_R" = '"outcome":"FRESHNESS_TIMEOUT_PROBE"' ] \
  || fail "#1937-e2e: the timeout-probe shell must report FRESHNESS_TIMEOUT_PROBE; got $K1937_R (full: $K1937_PROBE_OUT)"
printf '%s' "$K1937_PROBE_OUT" | grep '"rebase_in_progress":true' >/dev/null \
  || fail "#1937-e2e (round 3 HIGH): the probe must detect the REAL in-progress rebase via git's own exit status, not a literal .git/rebase-merge test that is always false in a linked worktree: $K1937_PROBE_OUT"
if [ -d "$K1937_GD/rebase-merge" ] || [ -d "$K1937_GD/rebase-apply" ]; then
  fail "#1937-e2e: the probe must have ABORTED the in-progress rebase, but rebase state is still on disk"
fi
echo "PASS: #1937-e2e mid-rebase — the real generated timeout-probe shell detects and aborts a genuine in-progress rebase in a LINKED worktree via git's own exit status, never the always-false directory test"

# 4. NON-CONFLICT rebase failure (round 3, MEDIUM): a REAL rebase failure with
#    NO conflicted files — a rejecting `pre-rebase` hook, standing in for a
#    missing-identity or leftover-in-progress-rebase failure — must report
#    FRESHNESS_REBASE_ERROR, never FRESHNESS_CONFLICT's empty-`conflict_files`
#    shape. An ISOLATED fixture (its own origin/worktree) because a
#    `pre-rebase` hook lives in the repo's shared git-dir and would otherwise
#    also fire for the conf/mid scenarios above.
K1937_HOOK_E2E="$WF_TEST_TMPDIR/freshness-e2e-hookfail"
mkdir -p "$K1937_HOOK_E2E"
git init --quiet --bare "$K1937_HOOK_E2E/origin.git"
mkdir -p "$K1937_HOOK_E2E/main-checkout"
(
  set -e
  cd "$K1937_HOOK_E2E/main-checkout"
  git init --quiet .
  git symbolic-ref HEAD refs/heads/main
  git config user.email t@example.com
  git config user.name t
  mkdir -p scripts
  printf '#!/bin/sh\nexit 0\n' > scripts/quality-gates.sh
  chmod +x scripts/quality-gates.sh
  printf 'line1\nSHARED\nline3\n' > f.txt
  git add -A && git commit --quiet -m base
  git remote add origin "$K1937_HOOK_E2E/origin.git"
  git push --quiet -u origin main
) || fail "#1937-e2e: could not build the hookfail base fixture"
git -C "$K1937_HOOK_E2E/main-checkout" worktree add --quiet "$K1937_HOOK_E2E/repo.wt/hookfail" -b build/hookfail main \
  || fail "#1937-e2e: could not create the hookfail-scenario linked worktree"
# A REAL pre-rebase hook that unconditionally refuses — the SHARED git-dir
# hooks/ directory a linked worktree's rebase actually consults.
K1937_HOOKDIR="$(git -C "$K1937_HOOK_E2E/repo.wt/hookfail" rev-parse --git-common-dir)/hooks"
mkdir -p "$K1937_HOOKDIR"
printf '#!/bin/sh\necho "pre-rebase hook: rejecting for e2e-hookfail" >&2\nexit 1\n' > "$K1937_HOOKDIR/pre-rebase"
chmod +x "$K1937_HOOKDIR/pre-rebase"
(
  set -e
  cd "$K1937_HOOK_E2E/repo.wt/hookfail"
  printf 'line1\nWORKER-hookfail\nline3\n' > f.txt
  git add -A && git commit --quiet -m work-hookfail
) || fail "#1937-e2e: could not commit the worker-side change for hookfail"
(
  set -e
  cd "$K1937_HOOK_E2E/main-checkout"
  printf 'line1\nMAIN-MOVED-ON\nline3\n' > f.txt
  git add -A && git commit --quiet -m main-moved-on
  git push --quiet origin main
) || fail "#1937-e2e: could not advance origin/main past the hookfail fixture worktree"

k1937_emit hookfail hookfail "$K1937_HOOK_E2E/hookfail" "$K1937_HOOK_E2E"
[ -s "$K1937_HOOK_E2E/hookfail.main.sh" ] || fail "#1937-e2e: no gate-freshness command was generated for the hookfail scenario"
K1937_FULL="$(bash "$K1937_HOOK_E2E/hookfail.main.sh" 2>/dev/null || true)"
K1937_R="$(printf '%s' "$K1937_FULL" | grep -o '"outcome":"[A-Z_]*"' | head -1)"
[ "$K1937_R" = '"outcome":"FRESHNESS_REBASE_ERROR"' ] \
  || fail "#1937-e2e (round 3 MEDIUM): a rebase failure with NO conflicted files (a rejecting pre-rebase hook) must report FRESHNESS_REBASE_ERROR, never FRESHNESS_CONFLICT's empty-conflict-files shape; got $K1937_R (full: $K1937_FULL)"
printf '%s' "$K1937_FULL" | grep '"conflict_files"' >/dev/null \
  && fail "#1937-e2e: a non-conflict outcome must never carry a conflict_files field at all (that shape is FRESHNESS_CONFLICT's alone): $K1937_FULL"
printf '%s' "$K1937_FULL" | grep -i 'pre-rebase hook' >/dev/null \
  || fail "#1937-e2e (round 3 MEDIUM): FRESHNESS_REBASE_ERROR must carry git's own hook-rejection output as detail: $K1937_FULL"
echo "PASS: #1937-e2e hookfail — a real non-conflict rebase failure (a rejecting pre-rebase hook) reports its own FRESHNESS_REBASE_ERROR outcome with detail, never misread as a content conflict"

# 5. FETCH FAILURE (round 3, MEDIUM): a REAL `git fetch` failure must carry
#    git's own stderr as `detail`, never a bare constant string — the pre-fix
#    shape discarded it entirely (`>/dev/null 2>&1`). Point `origin` at a
#    path that does not exist so the fetch fails for real.
git -C "$K1937_E2E/repo.wt/conf" remote set-url origin "$K1937_E2E/does-not-exist.git"
k1937_emit conf conf "$K1937_E2E/fetchfail"
K1937_FULL="$(bash "$K1937_E2E/fetchfail.main.sh" 2>/dev/null || true)"
K1937_R="$(printf '%s' "$K1937_FULL" | grep -o '"outcome":"[A-Z_]*"' | head -1)"
[ "$K1937_R" = '"outcome":"FRESHNESS_ERROR"' ] \
  || fail "#1937-e2e: a real fetch failure must report FRESHNESS_ERROR; got $K1937_R (full: $K1937_FULL)"
printf '%s' "$K1937_FULL" | grep '"detail":"git fetch origin main failed: [^"]' >/dev/null \
  || fail "#1937-e2e (round 3 MEDIUM): FRESHNESS_ERROR's detail must carry git's own fetch stderr, never a bare constant string: $K1937_FULL"
# Restore origin for anything else that might still touch this worktree.
git -C "$K1937_E2E/repo.wt/conf" remote set-url origin "$K1937_E2E/origin.git"
echo "PASS: #1937-e2e fetchfail — a real fetch failure's FRESHNESS_ERROR carries git's own stderr as detail, never a bare constant string"

# ============================================================================
# TESTS (temperloop#1819): session-quota death → its OWN escalation kind
# (quota-exhausted), never machinery-denied/SPINE_DENIED and never a bare
# worker-error 'agent returned null'. Two seams, classified differently:
#   • agent() THREW with the harness's limit text — matched directly, reset
#     time extracted from the message;
#   • agent() returned a bare NULL (no text reaches the script) — classified
#     by the agent-liveness canary: a classifier denial is per-command (an
#     innocuous probe still spawns) while a quota death kills EVERY spawn.
# Discrimination: the same null with a LIVE canary keeps the pre-#1819 kinds
# (K1819d below + the unchanged #72/#542 cases above).
# ============================================================================

run_node_case "K1819a worker throw with quota text → quota-exhausted carrying the reset time; no retry, no probe, no canary" "
$PREAMBLE
setMachinery('qworker', { outcome: 'CREATED', path: '/tmp/repo.wt/qworker' });
setWorker('qworker', { __throw: \"You've hit your session limit · resets 5:30pm\" });
globalThis.args = { ...baseArgs, items: [
  { slug: 'qworker', branch: 'build/qworker', title: 'Quota worker', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
const result = await mod.default();
const esc = result.escalations ?? [];
if ((result.parked ?? []).length !== 0 || esc.length !== 1 || esc[0].kind !== 'quota-exhausted')
  { console.log(JSON.stringify({ ok: false, reason: 'expected 1 quota-exhausted escalation, got ' + JSON.stringify(result) })); process.exit(0); }
const p = esc[0].payload;
if (p.reset_time !== '5:30pm')
  { console.log(JSON.stringify({ ok: false, reason: 'payload must carry the reset time from the harness message, got ' + JSON.stringify(p) })); process.exit(0); }
if (p.worktree_left_intact !== true || p.worktree !== '/tmp/repo.wt/qworker')
  { console.log(JSON.stringify({ ok: false, reason: 'payload must state the worktree was left intact, got ' + JSON.stringify(p) })); process.exit(0); }
if (p.classified_by !== 'error-text')
  { console.log(JSON.stringify({ ok: false, reason: 'expected classified_by=error-text, got ' + JSON.stringify(p) })); process.exit(0); }
// Short-circuit: under an exhausted quota nothing further is spawned — no
// worker retry, no recover-probe, no canary (the text was decisive).
const workers = callLog.filter(c => isWorkerCall(c.opts)).length;
const probes = callLog.filter(c => /^recover-probe:/.test(String(c.opts.label))).length;
const canaries = callLog.filter(c => /^canary:/.test(String(c.opts.label))).length;
if (workers !== 1 || probes !== 0 || canaries !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 1 worker / 0 probes / 0 canaries, got ' + workers + '/' + probes + '/' + canaries })); process.exit(0); }
console.log(JSON.stringify({ ok: true }));
"

run_node_case "K1819b worker bare null + dead canary → quota-exhausted (canary-classified), reset unknown, no retry" "
$PREAMBLE
setMachinery('qnull', { outcome: 'CREATED', path: '/tmp/repo.wt/qnull' });
setMachinery('quota-probe', null);   // the canary itself cannot spawn — quota is dead
setWorker('qnull', null);            // agent() returned a bare null: no text at all
globalThis.args = { ...baseArgs, items: [
  { slug: 'qnull', branch: 'build/qnull', title: 'Quota null', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
const result = await mod.default();
const esc = result.escalations ?? [];
if (esc.length !== 1 || esc[0].kind !== 'quota-exhausted')
  { console.log(JSON.stringify({ ok: false, reason: 'expected 1 quota-exhausted escalation, got ' + JSON.stringify(result) })); process.exit(0); }
const p = esc[0].payload;
if (p.classified_by !== 'agent-liveness-canary' || p.reset_time !== null)
  { console.log(JSON.stringify({ ok: false, reason: 'null shape must be canary-classified with no invented reset time, got ' + JSON.stringify(p) })); process.exit(0); }
if (p.worktree_left_intact !== true)
  { console.log(JSON.stringify({ ok: false, reason: 'payload must state the worktree was left intact, got ' + JSON.stringify(p) })); process.exit(0); }
const workers = callLog.filter(c => isWorkerCall(c.opts)).length;
if (workers !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'no retry against a dead harness — expected 1 worker call, got ' + workers })); process.exit(0); }
console.log(JSON.stringify({ ok: true }));
"

run_node_case "K1819c machinery (gate) null + dead canary → quota-exhausted, never machinery-denied (the #1819 incident shape)" "
$PREAMBLE
setMachinery('qgate',
  { outcome: 'CREATED', path: '/tmp/repo.wt/qgate' },
  { outcome: 'REVIEW_DIFF' },
  null,   // gate step dies on the session limit → agent() returns null
);
setMachinery('quota-probe', null);
happyWorker('qgate');
globalThis.args = { ...baseArgs, items: [
  { slug: 'qgate', branch: 'build/qgate', title: 'Quota gate', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
const result = await mod.default();
const esc = result.escalations ?? [];
if (esc.length !== 1 || esc[0].kind !== 'quota-exhausted')
  { console.log(JSON.stringify({ ok: false, reason: 'expected quota-exhausted (never machinery-denied), got ' + JSON.stringify(result) })); process.exit(0); }
const p = esc[0].payload;
if (p.where !== 'machinery:gate')
  { console.log(JSON.stringify({ ok: false, reason: 'payload.where must name the machinery step, got ' + JSON.stringify(p) })); process.exit(0); }
if (!p.denied_out || p.denied_out.outcome !== 'SPINE_DENIED')
  { console.log(JSON.stringify({ ok: false, reason: 'payload.denied_out must carry the normalized sentinel for the audit trail, got ' + JSON.stringify(p) })); process.exit(0); }
console.log(JSON.stringify({ ok: true }));
"

run_node_case "K1819d discrimination: the SAME gate null with a LIVE canary keeps machinery-denied — genuine denials retain their meaning" "
$PREAMBLE
setMachinery('gdenied',
  { outcome: 'CREATED', path: '/tmp/repo.wt/gdenied' },
  { outcome: 'REVIEW_DIFF' },
  null,   // gate denied by the classifier; the harness itself is fine
);
// NO quota-probe override: the canary hits the mock default (non-null) → alive.
happyWorker('gdenied');
globalThis.args = { ...baseArgs, items: [
  { slug: 'gdenied', branch: 'build/gdenied', title: 'Gate denied', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
const result = await mod.default();
const esc = result.escalations ?? [];
if (esc.length !== 1 || esc[0].kind !== 'machinery-denied' || esc[0].payload.step !== 'gate')
  { console.log(JSON.stringify({ ok: false, reason: 'expected machinery-denied step=gate unchanged, got ' + JSON.stringify(result) })); process.exit(0); }
// The canary DID run and answered alive — that is what kept the kind.
const canaries = callLog.filter(c => /^canary:/.test(String(c.opts.label))).length;
if (canaries !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'expected exactly 1 canary probe, got ' + canaries })); process.exit(0); }
console.log(JSON.stringify({ ok: true }));
"

run_node_case "K1819e spike worker null + dead canary → quota-exhausted, never the bare 'agent returned null (spike worker)'" "
$PREAMBLE
setMachinery('quota-probe', null);
setWorker('qspike', null);
globalThis.args = { ...baseArgs, items: [
  { slug: 'qspike', branch: 'build/qspike', title: 'Quota spike', kind: 'spike', acceptance: ['c'] },
]};
const mod = await loadLevel();
const result = await mod.default();
const esc = result.escalations ?? [];
if (esc.length !== 1 || esc[0].kind !== 'quota-exhausted')
  { console.log(JSON.stringify({ ok: false, reason: 'expected quota-exhausted for the spike quota death, got ' + JSON.stringify(result) })); process.exit(0); }
if (esc[0].payload.where !== 'worker (spike)')
  { console.log(JSON.stringify({ ok: false, reason: 'payload.where must name the spike worker, got ' + JSON.stringify(esc[0].payload) })); process.exit(0); }
console.log(JSON.stringify({ ok: true }));
"

# ----------------------------------------------------------------------------
# temperloop#1819 attempt-2 finding 1 (HIGH): the canary memoization must be
# ASYMMETRIC — only a DEAD verdict is sticky. An ALIVE verdict answered early
# in a level says nothing about a spawn that dies LATER in the same level; if
# it were cached, that later quota death would be misrouted back into
# worker-error/machinery-denied — the destructive mis-cure #1819 exists to
# prevent. Discriminator: this case FAILS against the attempt-1 build (whole-
# level alive cache → 1 canary, worker-error kind).
# ----------------------------------------------------------------------------

run_node_case "K1819f stale-cache: an early ALIVE canary is NOT memoized — a later bare-null re-probes and a now-dead quota classifies quota-exhausted" "
$PREAMBLE
setMachinery('qstale',
  { outcome: 'CREATED', path: '/tmp/repo.wt/qstale' },
  noSideEffects(),                       // recover-probe after the first (alive-canary) null
);
// Canary #1 (first worker null): ALIVE. Canary #2 (retry null): the quota has
// since died — the canary itself cannot spawn.
setMachinery('quota-probe', { ok: true }, null);
setWorker('qstale', null, null);         // worker null, then retry null
globalThis.args = { ...baseArgs, items: [
  { slug: 'qstale', branch: 'build/qstale', title: 'Stale canary', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
const result = await mod.default();
const esc = result.escalations ?? [];
if (esc.length !== 1 || esc[0].kind !== 'quota-exhausted')
  { console.log(JSON.stringify({ ok: false, reason: 'a quota death AFTER an alive canary must still classify quota-exhausted (stale-cache bug), got ' + JSON.stringify(result) })); process.exit(0); }
const p = esc[0].payload;
if (p.where !== 'worker (retry)' || p.classified_by !== 'agent-liveness-canary')
  { console.log(JSON.stringify({ ok: false, reason: 'expected the retry-site canary classification, got ' + JSON.stringify(p) })); process.exit(0); }
const canaries = callLog.filter(c => /^canary:/.test(String(c.opts.label))).length;
if (canaries !== 2)
  { console.log(JSON.stringify({ ok: false, reason: 'the second bare-null must RE-PROBE (alive is never cached) — expected 2 canaries, got ' + canaries })); process.exit(0); }
const workers = callLog.filter(c => isWorkerCall(c.opts)).length;
if (workers !== 2)
  { console.log(JSON.stringify({ ok: false, reason: 'expected worker + one retry (2 calls), got ' + workers })); process.exit(0); }
console.log(JSON.stringify({ ok: true }));
"

# ----------------------------------------------------------------------------
# temperloop#1819 attempt-2 finding 2 (MEDIUM): the three deniedOrQuota call
# sites that had no coverage — ciPollLoop's batch.denied, the push-retry
# machineryDenied(fpush) branch, and recoverLostReturn's rb.denied branch —
# each exercised in BOTH classifications (dead canary → quota-exhausted, live
# canary → machinery-denied unchanged), asserting the esc.escalation.* unwrap
# plumbing carries the payload (sha/pr/step) through each site's own return
# shape.
# ----------------------------------------------------------------------------

run_node_case "K1819g ci-batch denied + dead canary → quota-exhausted; the unwrap carries sha and pr through ciPollLoop's return shape" "
$PREAMBLE
setMachinery('qcib',
  { outcome: 'CREATED', path: '/tmp/repo.wt/qcib' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'acb0e' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'acb0e', branch: 'build/qcib' },
  { outcome: 'PR_OPENED', pr_number: 601 },
  null,   // ci-poll slice dies on the session limit → the whole ci-batch is denied
);
setMachinery('quota-probe', null);
happyWorker('qcib');
globalThis.args = { ...baseArgs, items: [
  { slug: 'qcib', branch: 'build/qcib', title: 'Quota ci-batch', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
const result = await mod.default();
const esc = result.escalations ?? [];
if ((result.parked ?? []).length !== 0 || esc.length !== 1 || esc[0].kind !== 'quota-exhausted')
  { console.log(JSON.stringify({ ok: false, reason: 'expected 1 quota-exhausted escalation from the ci-batch site, got ' + JSON.stringify(result) })); process.exit(0); }
const p = esc[0].payload;
if (p.where !== 'machinery:ci-batch')
  { console.log(JSON.stringify({ ok: false, reason: 'payload.where must name the ci-batch step, got ' + JSON.stringify(p) })); process.exit(0); }
if (p.sha !== 'acb0e' || p.pr !== 601)
  { console.log(JSON.stringify({ ok: false, reason: 'the unwrap must carry sha + pr through ciPollLoop\\'s {escalation, payload} return, got ' + JSON.stringify(p) })); process.exit(0); }
if (p.worktree_left_intact !== true || !p.denied_out || p.denied_out.outcome !== 'SPINE_DENIED')
  { console.log(JSON.stringify({ ok: false, reason: 'payload must state worktree_left_intact and carry denied_out for the audit trail, got ' + JSON.stringify(p) })); process.exit(0); }
console.log(JSON.stringify({ ok: true }));
"

run_node_case "K1819h ci-batch denied + LIVE canary keeps machinery-denied with sha and pr — genuine CI-stage denials retain their meaning" "
$PREAMBLE
setMachinery('gcib',
  { outcome: 'CREATED', path: '/tmp/repo.wt/gcib' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'acb24' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'acb24', branch: 'build/gcib' },
  { outcome: 'PR_OPENED', pr_number: 602 },
  null,   // ci-batch denied by the classifier; the harness itself is fine
);
// NO quota-probe override: the canary hits the mock default (non-null) → alive.
happyWorker('gcib');
globalThis.args = { ...baseArgs, items: [
  { slug: 'gcib', branch: 'build/gcib', title: 'Genuine ci denial', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
const result = await mod.default();
const esc = result.escalations ?? [];
if (esc.length !== 1 || esc[0].kind !== 'machinery-denied')
  { console.log(JSON.stringify({ ok: false, reason: 'expected machinery-denied unchanged at the ci-batch site, got ' + JSON.stringify(result) })); process.exit(0); }
const p = esc[0].payload;
if (p.step !== 'ci-batch' || p.sha !== 'acb24' || p.pr !== 602)
  { console.log(JSON.stringify({ ok: false, reason: 'machinery-denied payload must keep step=ci-batch with sha + pr, got ' + JSON.stringify(p) })); process.exit(0); }
const canaries = callLog.filter(c => /^canary:/.test(String(c.opts.label))).length;
if (canaries !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'expected exactly 1 canary probe, got ' + canaries })); process.exit(0); }
console.log(JSON.stringify({ ok: true }));
"

run_node_case "K1819i push-retry denied + dead canary → quota-exhausted; the unwrap carries the pinned sha and pr through the CI-fix return shape" "
$PREAMBLE
setMachinery('qpret',
  { outcome: 'CREATED', path: '/tmp/repo.wt/qpret' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'a145' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'a145', branch: 'build/qpret' },
  { outcome: 'PR_OPENED', pr_number: 603 },
  { outcome: 'CI_FAILED', failed_run_ids: [9101] },
  { outcome: 'REVIEW_DIFF' },   // temperloop#1450 re-review of the CI-fix commit
  null,                          // the retry push dies on the session limit
);
setMachinery('quota-probe', null);
setWorker('qpret',
  { status: 'done', summary: 'initial', acceptance_results: [{ criterion: 'c', passed: true, evidence: 'e' }], commits: [] },
  { status: 'done', summary: 'ci fixed', acceptance_results: [], commits: [] },
);
globalThis.args = { ...baseArgs, items: [
  { slug: 'qpret', branch: 'build/qpret', title: 'Quota push-retry', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
const result = await mod.default();
const esc = result.escalations ?? [];
if (esc.length !== 1 || esc[0].kind !== 'quota-exhausted')
  { console.log(JSON.stringify({ ok: false, reason: 'expected 1 quota-exhausted escalation from the push-retry site, got ' + JSON.stringify(result) })); process.exit(0); }
const p = esc[0].payload;
if (p.where !== 'machinery:push-retry')
  { console.log(JSON.stringify({ ok: false, reason: 'payload.where must name the push-retry step, got ' + JSON.stringify(p) })); process.exit(0); }
if (p.sha !== 'a145' || p.pr !== 603 || p.worktree_left_intact !== true)
  { console.log(JSON.stringify({ ok: false, reason: 'the unwrap must carry the pre-fix pinned sha + pr with worktree_left_intact, got ' + JSON.stringify(p) })); process.exit(0); }
console.log(JSON.stringify({ ok: true }));
"

run_node_case "K1819j push-retry denied + LIVE canary keeps machinery-denied step=push-retry — a genuine push-retry denial retains its meaning" "
$PREAMBLE
setMachinery('gpret',
  { outcome: 'CREATED', path: '/tmp/repo.wt/gpret' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'a121' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'a121', branch: 'build/gpret' },
  { outcome: 'PR_OPENED', pr_number: 604 },
  { outcome: 'CI_FAILED', failed_run_ids: [9102] },
  { outcome: 'REVIEW_DIFF' },
  null,   // push-retry denied by the classifier; the harness itself is fine
);
// NO quota-probe override → alive.
setWorker('gpret',
  { status: 'done', summary: 'initial', acceptance_results: [{ criterion: 'c', passed: true, evidence: 'e' }], commits: [] },
  { status: 'done', summary: 'ci fixed', acceptance_results: [], commits: [] },
);
globalThis.args = { ...baseArgs, items: [
  { slug: 'gpret', branch: 'build/gpret', title: 'Genuine push-retry denial', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
const result = await mod.default();
const esc = result.escalations ?? [];
if (esc.length !== 1 || esc[0].kind !== 'machinery-denied')
  { console.log(JSON.stringify({ ok: false, reason: 'expected machinery-denied unchanged at the push-retry site, got ' + JSON.stringify(result) })); process.exit(0); }
const p = esc[0].payload;
if (p.step !== 'push-retry' || p.sha !== 'a121' || p.pr !== 604)
  { console.log(JSON.stringify({ ok: false, reason: 'machinery-denied payload must keep step=push-retry with sha + pr, got ' + JSON.stringify(p) })); process.exit(0); }
const canaries = callLog.filter(c => /^canary:/.test(String(c.opts.label))).length;
if (canaries !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'expected exactly 1 canary probe, got ' + canaries })); process.exit(0); }
console.log(JSON.stringify({ ok: true }));
"

run_node_case "K1819k pr-batch-resume denied + dead canary → quota-exhausted through recoverLostReturn's {kind, escKind, payload} return shape" "
$PREAMBLE
setMachinery('qres',
  { outcome: 'CREATED', path: '/tmp/repo.wt/qres' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'a52' },
  { outcome: 'SCAN_CLEAN' },
  lostReturn(),   // push ran; its JSON line was dropped (temperloop#1067)
  { outcome: 'RECOVER_COMMITTED', sha: 'a52', pushed: false, verification_surface_present: false },
  null,           // the resume batch (push + pr-open) dies on the session limit
);
setMachinery('quota-probe', null);
happyWorker('qres');
globalThis.args = { ...baseArgs, items: [
  { slug: 'qres', branch: 'build/qres', title: 'Quota resume', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
const result = await mod.default();
const esc = result.escalations ?? [];
if ((result.parked ?? []).length !== 0 || esc.length !== 1 || esc[0].kind !== 'quota-exhausted')
  { console.log(JSON.stringify({ ok: false, reason: 'expected 1 quota-exhausted escalation from the pr-batch-resume site, got ' + JSON.stringify(result) })); process.exit(0); }
const p = esc[0].payload;
if (p.where !== 'machinery:pr-batch-resume')
  { console.log(JSON.stringify({ ok: false, reason: 'payload.where must name the resume batch, got ' + JSON.stringify(p) })); process.exit(0); }
if (p.worktree_left_intact !== true || !p.denied_out || p.denied_out.outcome !== 'SPINE_DENIED')
  { console.log(JSON.stringify({ ok: false, reason: 'payload must state worktree_left_intact and carry denied_out, got ' + JSON.stringify(p) })); process.exit(0); }
console.log(JSON.stringify({ ok: true }));
"

run_node_case "K1819l pr-batch-resume denied + LIVE canary keeps machinery-denied naming the resume batch and its steps" "
$PREAMBLE
setMachinery('gres',
  { outcome: 'CREATED', path: '/tmp/repo.wt/gres' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'a28' },
  { outcome: 'SCAN_CLEAN' },
  lostReturn(),
  { outcome: 'RECOVER_COMMITTED', sha: 'a28', pushed: false, verification_surface_present: false },
  null,   // resume batch denied by the classifier; the harness itself is fine
);
// NO quota-probe override → alive.
happyWorker('gres');
globalThis.args = { ...baseArgs, items: [
  { slug: 'gres', branch: 'build/gres', title: 'Genuine resume denial', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
const result = await mod.default();
const esc = result.escalations ?? [];
if (esc.length !== 1 || esc[0].kind !== 'machinery-denied')
  { console.log(JSON.stringify({ ok: false, reason: 'expected machinery-denied unchanged at the pr-batch-resume site, got ' + JSON.stringify(result) })); process.exit(0); }
const p = esc[0].payload;
if (p.step !== 'pr-batch-resume' || JSON.stringify(p.steps) !== JSON.stringify(['push','pr-open']))
  { console.log(JSON.stringify({ ok: false, reason: 'machinery-denied payload must name the resume batch and its steps, got ' + JSON.stringify(p) })); process.exit(0); }
const canaries = callLog.filter(c => /^canary:/.test(String(c.opts.label))).length;
if (canaries !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'expected exactly 1 canary probe, got ' + canaries })); process.exit(0); }
console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST (K1941): static lockstep guard on meta.description — the Workflow
# tool's `meta` block must be a pure literal (temperloop#903), so this string
# is byte-identical whether /build, /fix, or /sweep invokes the script. It
# must therefore describe one invocation generically: never assert a single
# dependency-level scope (that reads as false on a /fix 1-item level or a
# /sweep chunk — the exact temperloop#1941 regression, where the /fix and
# /sweep launch/completion lines inherited build's level-scoped wording), and
# it must name all three callers so a reader of the description alone knows
# which commands share this script. Static, not run_node_case: meta is
# stripped before the harness's AsyncFunction load (see loadLevel() above),
# so this is a plain grep against the source file, mirroring the K1530/
# K1931/K1934 lockstep idiom's grep-based checks. ---------------------------
DESC_BLOCK="$(awk '/^export const meta = \{/,/^\};/' "$MJS")"
[ -n "$DESC_BLOCK" ] \
  || fail "#1941: could not locate the 'export const meta = { ... };' block in $MJS"
echo "$DESC_BLOCK" | grep "one dependency level" >/dev/null \
  && fail "#1941: meta.description must not assert a single dependency-level scope — /fix (1-item level) and /sweep (a chunk) invoke this same script"
for caller in '/build' '/fix' '/sweep'; do
  echo "$DESC_BLOCK" | grep -F "$caller" >/dev/null \
    || fail "#1941: meta.description must name $caller as a caller of this script"
done
echo "PASS: #1941 meta.description guard — names /build, /fix, and /sweep as callers and never asserts a single dependency-level scope"

# ============================================================================
# TEST (K1970): the §3e REVIEW-BLOCKING CONVERGENCE BOUND.
#
#   Before this item nothing bounded the §3e loop: a HIGH finding escalated
#   `review-blocking`, the orchestrator looped the item back to 3c, the worker
#   fixed it, and a fresh cold reviewer read the now-LARGER diff — repeat. One
#   live item (temperloop#1938 L1, `interview-command-spec`/#1962) spent FIVE
#   consecutive passes, four DISTINCT HIGHs, zero repeats, ~2h45m and ~1.05M
#   subagent tokens, with the reviewed spec growing 447 -> 635 lines across the
#   rounds; the orchestrator invented a stopping rule by hand at pass 5.
#
#   Three behaviours, deliberately covering BOTH sides of the bound so the
#   suite discriminates rather than merely observing the new code exists:
#     - UNDER the bound, a HIGH escalates exactly as it did before (this is the
#       negative case: if the bound fires early, this case goes red).
#     - AT the bound, the item proceeds to 3f and the findings are CARRIED into
#       the PR body's ## Review notes plus the parked review.residual_blocking
#       tally — never discarded, never escalated again.
#     - the ORCHESTRATOR SETTING (input.reviewBlockingMaxRounds, from
#       $BUILD_REVIEW_BLOCKING_MAX_ROUNDS) actually moves where the bound sits.
# ============================================================================
run_node_case "K1970 under the bound: round 2 of 3 with a HIGH still escalates review-blocking (the bound must never fire early)" "
$PREAMBLE

setMachinery('bound-under',
  { outcome: 'CREATED', path: '/tmp/repo.wt/bound-under' },
  // review_rounds:1 = one round already spent on this worktree, so THIS is
  // round 2 of the default bound of 3 — still inside the budget.
  { outcome: 'REVIEW_DIFF', files: ['claude/commands/build.md'], tsv: '', tsv_rows: 0, tsv_checksum: 0, review_rounds: 1 },
  // Deliberately NO further entries: if the bound wrongly fires here the
  // driver proceeds to the gate, the queue is exhausted and the mock throws.
);
happyWorker('bound-under');
setReview('bound-under', '## Summary\\n1 finding.\\n\\n## Findings\\n### [HIGH] Silent failure mode in claude/commands/build.md Step 3\\n**Where:** claude/commands/build.md — Step 3\\n');

globalThis.args = { ...baseArgs, items: [
  { slug: 'bound-under', branch: 'build/bound-under', title: 'Touch build.md', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();
let reason = null;
if ((result.escalations ?? []).length !== 1) reason = 'a HIGH under the bound must still escalate: ' + JSON.stringify(result);
else if (result.escalations[0].kind !== 'review-blocking') reason = 'wrong escalation kind: ' + result.escalations[0].kind;
else if (result.escalations[0].payload.round !== 2) reason = 'the escalation must name its round number: ' + JSON.stringify(result.escalations[0].payload.round);
else if (result.escalations[0].payload.max_rounds !== 3) reason = 'the escalation must name the bound it is under: ' + JSON.stringify(result.escalations[0].payload.max_rounds);
else if ((result.parked ?? []).length !== 0) reason = 'a blocking round under the bound must not park the item: ' + JSON.stringify(result.parked);
if (!reason) {
  const prBatch = callLog.find(c => (c.opts.label||'').startsWith('pr-batch:bound-under'));
  if (prBatch) reason = 'an escalating round must stop BEFORE 3f (push/PR): ' + prBatch.opts.label;
}
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K1970 at the bound: round 3 of 3 opens the PR with the HIGH carried into ## Review notes, never a further escalation" "
$PREAMBLE

setMachinery('bound-at',
  { outcome: 'CREATED', path: '/tmp/repo.wt/bound-at' },
  // review_rounds:2 = two rounds already spent, so THIS is round 3 == the
  // default bound: the loop stops here and the item ships with its notes.
  { outcome: 'REVIEW_DIFF', files: ['claude/commands/build.md'], tsv: '', tsv_rows: 0, tsv_checksum: 0, review_rounds: 2 },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'aba07' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'aba07', branch: 'build/bound-at' },
  { outcome: 'PR_OPENED', pr_number: 1970 },
  { outcome: 'CI_GREEN' },
);
happyWorker('bound-at');
setReview('bound-at', '## Summary\\n1 finding.\\n\\n## Findings\\n### [HIGH] Residual invariant gap in claude/commands/build.md Step 3\\n**Issue:** UNRESOLVED-AT-BOUND\\n');

globalThis.args = { ...baseArgs, items: [
  { slug: 'bound-at', branch: 'build/bound-at', title: 'Touch build.md', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();
let reason = null;
if ((result.escalations ?? []).length !== 0) reason = 'at the bound the item must NOT escalate again: ' + JSON.stringify(result.escalations);
else if ((result.parked ?? []).length !== 1) reason = 'at the bound the item must park with its PR open: ' + JSON.stringify(result);
const rec = (result.parked ?? [])[0];
if (!reason && rec.pr !== 1970) reason = 'parked record must carry the opened PR: ' + JSON.stringify(rec);
// The bound's PER-RUN EXECUTION SIGNAL: the tally names the round and carries
// what was left outstanding, so Step 6 can surface it (mandatory-step birth rule).
if (!reason && !(rec.review && Array.isArray(rec.review.residual_blocking) && rec.review.residual_blocking.length === 1))
  reason = 'the parked tally must carry review.residual_blocking: ' + JSON.stringify(rec.review);
else if (!reason && rec.review.residual_blocking[0].round !== 3)
  reason = 'residual_blocking must name the round that hit the bound: ' + JSON.stringify(rec.review.residual_blocking[0]);
else if (!reason && rec.review.residual_blocking[0].max_rounds !== 3)
  reason = 'residual_blocking must name the bound: ' + JSON.stringify(rec.review.residual_blocking[0]);
else if (!reason && !JSON.stringify(rec.review.residual_blocking[0].findings).includes('UNRESOLVED-AT-BOUND'))
  reason = 'residual_blocking must carry the findings themselves, not just a count: ' + JSON.stringify(rec.review.residual_blocking[0]);
// CARRIED, NOT SUPPRESSED: the HIGH text must reach the human via the PR body.
const prBatch = callLog.find(c => (c.opts.label||'').startsWith('pr-batch:bound-at'));
if (!reason && !prBatch) reason = 'at the bound the item must reach 3f (push/PR) — no pr-batch call was made';
if (!reason && !prBatch.promptFull.includes('## Review notes'))
  reason = 'the PR body must carry a ## Review notes section at the bound: ' + prBatch.promptFull.slice(0, 400);
if (!reason && !prBatch.promptFull.includes('UNRESOLVED-AT-BOUND'))
  reason = 'the residual HIGH findings TEXT must be spliced into the PR body, never dropped: ' + prBatch.promptFull.slice(0, 600);
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K1970 setting wired: reviewBlockingMaxRounds=1 makes the FIRST blocking round the last (input.* actually moves the bound)" "
$PREAMBLE

setMachinery('bound-cfg',
  { outcome: 'CREATED', path: '/tmp/repo.wt/bound-cfg' },
  // No review_rounds field at all -> 0 prior rounds -> this is round 1, which
  // under the DEFAULT bound of 3 would escalate. The orchestrator-supplied
  // setting is the only thing that can make it ship instead.
  { outcome: 'REVIEW_DIFF', files: ['claude/commands/build.md'], tsv: '', tsv_rows: 0, tsv_checksum: 0 },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'abc08' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'abc08', branch: 'build/bound-cfg' },
  { outcome: 'PR_OPENED', pr_number: 1971 },
  { outcome: 'CI_GREEN' },
);
happyWorker('bound-cfg');
setReview('bound-cfg', '## Summary\\n1 finding.\\n\\n## Findings\\n### [HIGH] Silent failure mode in claude/commands/build.md Step 3\\n');

globalThis.args = { ...baseArgs, reviewBlockingMaxRounds: 1, items: [
  { slug: 'bound-cfg', branch: 'build/bound-cfg', title: 'Touch build.md', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();
let reason = null;
if ((result.escalations ?? []).length !== 0) reason = 'with the bound set to 1 the first blocking round must not escalate: ' + JSON.stringify(result.escalations);
else if ((result.parked ?? []).length !== 1) reason = 'expected the item to park: ' + JSON.stringify(result);
const rec = (result.parked ?? [])[0];
if (!reason && !(rec.review && rec.review.residual_blocking && rec.review.residual_blocking[0].max_rounds === 1))
  reason = 'the tally must report the CONFIGURED bound, not the in-file default: ' + JSON.stringify(rec.review);
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

# --- K1970 static lockstep guards (the mandatory-step-birth-rule signal) -----
# These go RED the moment the bound's enforcement is deleted from either
# blocking call site, or the named setting stops being the seam it reads from.
grep -q 'const REVIEW_BLOCKING_MAX_ROUNDS = ' "$MJS" \
  || fail "#1970: build-level.mjs must define the REVIEW_BLOCKING_MAX_ROUNDS convergence bound"
grep -q 'input.reviewBlockingMaxRounds' "$MJS" \
  || fail "#1970: the bound must be a NAMED SETTING handed in as input.reviewBlockingMaxRounds (kernel § Named-setting convention), never an unreachable literal"
grep -q 'function reviewBoundReached(review)' "$MJS" \
  || fail "#1970: both blocking call sites must share ONE reviewBoundReached() predicate so they cannot drift apart"
grep -q 'if (!reviewBoundReached(review)) {' "$MJS" \
  || fail "#1970: the §3e blocking site must gate its review-blocking escalation on the convergence bound"
grep -q 'if (!reviewBoundReached(fixReview)) {' "$MJS" \
  || fail "#1970: the §3g CI-fix blocking site must gate its review-blocking escalation on the SAME convergence bound"
grep -q 'residual_blocking' "$MJS" \
  || fail "#1970: reaching the bound must surface a per-run tally (review.residual_blocking), never a prose-only declaration"
grep -q 'build-review-rounds' "$MJS" \
  || fail "#1970: the round counter must be persisted per-worktree so it survives the escalate -> re-invoke loop it bounds"
grep -q 'review_rounds' "$MJS" \
  || fail "#1970: reviewDiffCmd must emit review_rounds for the bound to read"
grep -q ': "\${BUILD_REVIEW_BLOCKING_MAX_ROUNDS:=' "$REPO_ROOT/workflows/scripts/build/build.config.sh" \
  || fail "#1970: BUILD_REVIEW_BLOCKING_MAX_ROUNDS must be declared in build.config.sh (the ONE place the default lives)"
grep -q 'BUILD_REVIEW_BLOCKING_MAX_ROUNDS' "$REPO_ROOT/workflows/scripts/config/setting-registry.tsv" \
  || fail "#1970: BUILD_REVIEW_BLOCKING_MAX_ROUNDS must carry a setting-registry.tsv row"
grep -qiE 'every HIGH|all HIGH' "$REPO_ROOT/claude/agents/workflow-reviewer.md" \
  || fail "#1970: the workflow-reviewer seat must be instructed to enumerate EVERY HIGH in one pass — the bound alone only truncates serial discovery, it does not fix it"
echo "PASS: #1970 convergence-bound guards — the bound is enforced at both blocking sites from a named setting, tallied per run, and the reviewer seat is told to enumerate every HIGH in one pass"

# --- K1970 REPORT-SURFACE lockstep guards (the tally's declared READER) ------
# The guards above pin the tally's PRODUCER (build-level.mjs emits
# review.residual_blocking). A per-run tally is only an execution signal if the
# human-facing report DECLARED to read it actually names it — the exact failure
# class mandatory-step-registry.tsv's own header names, and the one this item
# exists to fix. Without these, an item that shipped a PR with an UNRESOLVED
# HIGH reads byte-identically to a clean one in every orchestrator summary and
# the only trace is buried in that one PR's ## Review notes.
#
# SECTION-SCOPED on purpose: a stray `residual_blocking` mention anywhere else
# in the spec must not satisfy the guard, so each check is confined to the
# report step's own line range (heading -> next `## ` heading, or EOF).
k1970_section() { # <file> <heading-regex> -> that section's text on stdout
  local _f="$1" _h="$2" _start _end
  _start="$(grep -nE "$_h" "$_f" | head -1 | cut -d: -f1)"
  [ -n "$_start" ] || return 1
  _end="$(awk -v s="$_start" 'NR>s && /^## /{print NR-1; exit}' "$_f")"
  [ -n "$_end" ] || _end="$(wc -l <"$_f")"
  sed -n "${_start},${_end}p" "$_f"
}

K1970_BUILD_MD="$REPO_ROOT/claude/commands/build.md"
[ -f "$K1970_BUILD_MD" ] \
  || fail "#1970: claude/commands/build.md is missing — the report-surface half of this contract pair cannot be verified"
K1970_STEP6="$(k1970_section "$K1970_BUILD_MD" '^## Step 6 — Final summary')" \
  || fail "#1970: build.md '## Step 6 — Final summary' heading not found — the tally's declared reader cannot be section-scoped"
printf '%s\n' "$K1970_STEP6" | grep 'residual_blocking' >/dev/null \
  || fail "#1970: build.md Step 6's summary must name residual_blocking — a tally the .mjs emits and the Step 6 prose never renders is a signal that dead-ends, which is exactly the defect this item fixes"
printf '%s\n' "$K1970_STEP6" | grep 'max_rounds' >/dev/null \
  || fail "#1970: build.md Step 6's residual_blocking case must name each affected item's round/max_rounds, not just a count"
printf '%s\n' "$K1970_STEP6" | grep '## Review notes' >/dev/null \
  || fail "#1970: build.md Step 6's residual_blocking case must tell the operator to read the PR's ## Review notes before merging — that is where the carried findings live"

K1970_SWEEP_MD="$REPO_ROOT/claude/commands/sweep.md"
[ -f "$K1970_SWEEP_MD" ] \
  || fail "#1970: claude/commands/sweep.md is missing — the report-surface half of this contract pair cannot be verified"
K1970_SWEEP_REPORT="$(k1970_section "$K1970_SWEEP_MD" '^## Step 4 — Report')" \
  || fail "#1970: sweep.md '## Step 4 — Report' heading not found — the tally's declared reader cannot be section-scoped"
printf '%s\n' "$K1970_SWEEP_REPORT" | grep 'residual_blocking' >/dev/null \
  || fail "#1970: sweep.md Step 4's report must name residual_blocking — /sweep passes reviewBlockingMaxRounds, so it can strand a residual HIGH exactly like /build"
printf '%s\n' "$K1970_SWEEP_REPORT" | grep '## Review notes' >/dev/null \
  || fail "#1970: sweep.md Step 4's residual_blocking block must point at the PR's ## Review notes"

K1970_FIX_MD="$REPO_ROOT/claude/commands/fix.md"
[ -f "$K1970_FIX_MD" ] \
  || fail "#1970: claude/commands/fix.md is missing — the report-surface half of this contract pair cannot be verified"
K1970_FIX_REPORT="$(k1970_section "$K1970_FIX_MD" '^## Step 7 — Report the terminal disposition')" \
  || fail "#1970: fix.md '## Step 7 — Report the terminal disposition' heading not found — the tally's declared reader cannot be section-scoped"
printf '%s\n' "$K1970_FIX_REPORT" | grep 'residual_blocking' >/dev/null \
  || fail "#1970: fix.md Step 7's report must name residual_blocking — /fix passes reviewBlockingMaxRounds, so it can strand a residual HIGH exactly like /build"
printf '%s\n' "$K1970_FIX_REPORT" | grep '## Review notes' >/dev/null \
  || fail "#1970: fix.md Step 7's residual_blocking line must point at the PR's ## Review notes"
echo "PASS: #1970 report-surface guards — build.md Step 6, sweep.md Step 4 and fix.md Step 7 each render the residual_blocking tally the .mjs emits, section-scoped"

# --- temperloop#2020 report-surface guards: routing_degraded ----------------
# The SAME failure shape as #1970's above, one field over. `routing_degraded`
# is emitted by reviewTally() on every parked record whose reviewer-routing
# relay did not survive, and that item's `ran`/`mandatory_ok` read clean — the
# table-independent routes really did run. So without a rollup clause a
# partially-routed roster is visible ONLY inside one PR body's skip notice, and
# an unreviewed .sh/.mjs diff reads byte-identically to a fully-reviewed one.
# Section-scoped against the SAME three declared readers, reusing #1970's own
# k1970_section helper so the two guards cannot drift apart.
printf '%s\n' "$K1970_STEP6" | grep 'routing_degraded' >/dev/null \
  || fail "#2020: build.md Step 6's summary must name routing_degraded — a degraded roster the .mjs emits and the Step 6 prose never renders is a signal that dead-ends, exactly the #1970 shape one field over"
printf '%s\n' "$K1970_SWEEP_REPORT" | grep 'routing_degraded' >/dev/null \
  || fail "#2020: sweep.md Step 4's report must name routing_degraded — /sweep drives the same build-level.mjs review path, so it can ship a partially-routed roster exactly like /build"
printf '%s\n' "$K1970_FIX_REPORT" | grep 'routing_degraded' >/dev/null \
  || fail "#2020: fix.md Step 7's report must name routing_degraded — /fix drives the same build-level.mjs review path, so it can ship a partially-routed roster exactly like /build"
grep -q 'routing_degraded: routingDegraded' "$MJS" \
  || fail "#2020: the report surfaces above render a field build-level.mjs must actually emit — reviewTally's producer half is missing"
echo "PASS: #2020 report-surface guards — build.md Step 6, sweep.md Step 4 and fix.md Step 7 each render the routing_degraded tally the .mjs emits, section-scoped"

# --- temperloop#2020 disposition-surface guards: committed_work -------------
# The routing_degraded guards above cover the REPORT surface. This pair covers
# the DISPOSITION surface: every spec that removes an escalated item's worktree
# must first consult `committed_work`, the remote-durability signal
# preserveOnEscalation() records on the payload. The failure this closes is the
# named incident itself — a review-blocking escalation whose work was committed
# but un-PR'd reached a caller's removal step and 515 verified lines were
# destroyed (Towheads/foundation, wf_967c2878-0a7). fix.md carried the guard
# from the first commit; build.md's 3d-esc skip/abort and sweep.md's
# escalation-park step did not, which left the DEFAULT build path unguarded.
#
# Deliberately file-scoped, not section-scoped: unlike the report surfaces
# above (one named heading each), the removal decision points are mid-section
# bullets with no stable heading to anchor on. A file-level assertion is the
# honest guard here — it catches a spec that never mentions the signal at all,
# and does not pretend to a precision it cannot deliver.
for spec_rel in claude/commands/build.md claude/commands/sweep.md claude/commands/fix.md; do
  spec_abs="$REPO_ROOT/$spec_rel"
  [ -f "$spec_abs" ] \
    || fail "#2020: $spec_rel is missing — the disposition-surface half of this contract pair cannot be verified"
  grep -q 'committed_work' "$spec_abs" \
    || fail "#2020: $spec_rel removes an escalated item's worktree but never names committed_work — the remote-durability signal must be read BEFORE the removal, or the 515-line data-loss incident this mechanism exists to close can recur through this caller"
done
grep -q 'committed_work' "$MJS" \
  || fail "#2020: the disposition surfaces above read a field build-level.mjs must actually emit — preserveOnEscalation's producer half is missing"
echo "PASS: #2020 disposition-surface guards — build.md, sweep.md and fix.md each consult committed_work before removing an escalated worktree"

# ============================================================================
# TEST (K2127): delta-aware continuation reviewer prompt.
#
#   temperloop#2127 — on a `review-blocking` continuation, reviewPrompt() must
#   carry the prior round's number, the prior reviewed SHA and the prior
#   findings, so the reviewer (a) verifies each prior finding is resolved,
#   (b) reviews `git diff <prior-sha>..HEAD` for fix-introduced regressions,
#   then (c) sweeps the full branch once more. Round 1 must carry none of
#   this — the regression case (acceptance bullet 3) that keeps today's
#   prompt byte-identical.
#
#   Two drives in one case: ROUND 1 (fresh, no onlySlugs/verdicts) proves the
#   negative (no continuation section, no `..HEAD` range); ROUND 2 (onlySlugs
#   + verdicts[slug].kind === 'review-blocking', reviewDiffCmd fixture reports
#   review_rounds:1 + review_prior_sha) proves the positive.
# ============================================================================
run_node_case "K2127: round-2 continuation prompt carries round-1 findings + <prior-sha>..HEAD; round-1 carries neither" "
$PREAMBLE

// --- ROUND 1: fresh review, no continuation ---------------------------------
setMachinery('rp-round1',
  { outcome: 'CREATED', path: '/tmp/repo.wt/rp-round1' },
  { outcome: 'REVIEW_DIFF', files: ['claude/commands/build.md'], tsv: '', tsv_rows: 0, tsv_checksum: 0 },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'c0ffee01' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'c0ffee01', branch: 'build/rp-round1' },
  { outcome: 'PR_OPENED', pr_number: 2101 },
  { outcome: 'CI_GREEN' },
);
happyWorker('rp-round1');
setReview('rp-round1', '## Summary\\nClean.\\n\\n## Findings\\nNone.\\n');

globalThis.args = { ...baseArgs, items: [
  { slug: 'rp-round1', branch: 'build/rp-round1', title: 'Round1', kind: 'impl', acceptance: ['c'] },
]};
const mod1 = await loadLevel();
const result1 = await mod1.default();

let reason = null;
const round1Review = callLog.find(c => (c.opts.label||'').startsWith('review:rp-round1#'));
if (!round1Review) reason = 'round1: no reviewer call captured: ' + JSON.stringify(result1);
else if (round1Review.promptFull.indexOf('## Continuation') !== -1)
  reason = 'round1 prompt must NOT carry a continuation section: ' + round1Review.promptFull.slice(0,400);
else if (round1Review.promptFull.indexOf('..HEAD') !== -1)
  reason = 'round1 prompt must NOT carry a prior-sha diff range: ' + round1Review.promptFull.slice(0,400);
else if ((result1.parked ?? []).length !== 1)
  reason = 'round1: expected exactly one parked item: ' + JSON.stringify(result1);

// --- ROUND 2: a review-blocking continuation --------------------------------
// input.verdicts[slug].verdict_section is the SAME text the orchestrator
// captured off the round-1 escalation's findings payload (temperloop#2127 —
// reused verbatim, never re-derived by driveItemBuildPhase or runReviewers).
const PRIOR_FINDINGS = '### workflow-reviewer\\n### [HIGH] Silent failure mode in claude/commands/build.md Step 3\\n**Where:** claude/commands/build.md - Step 3\\n';
setMachinery('rp-round2',
  { outcome: 'REVIEW_DIFF', files: ['claude/commands/build.md'], tsv: '', tsv_rows: 0, tsv_checksum: 0, review_rounds: 1, review_prior_sha: 'deadbeef01' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'c0ffee02' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'c0ffee02', branch: 'build/rp-round2' },
  { outcome: 'PR_OPENED', pr_number: 2102 },
  { outcome: 'CI_GREEN' },
);
setWorker('rp-round2', { status: 'done', summary: 'fix applied', acceptance_results: [{ criterion: 'c', passed: true, evidence: 'e' }], commits: [] });
setReview('rp-round2', '## Summary\\nClean after fix.\\n\\n## Findings\\nNone.\\n');

globalThis.args = { ...baseArgs, items: [
  { slug: 'rp-round2', branch: 'build/rp-round2', title: 'Round2', kind: 'impl', acceptance: ['c'] },
], onlySlugs: ['rp-round2'], verdicts: { 'rp-round2': { kind: 'review-blocking', verdict_section: PRIOR_FINDINGS } } };
const mod2 = await loadLevel();
const result2 = await mod2.default();

const round2Review = callLog.find(c => (c.opts.label||'').startsWith('review:rp-round2#'));
if (!reason && !round2Review) reason = 'round2: no reviewer call captured: ' + JSON.stringify(result2);
else if (!reason && round2Review.promptFull.indexOf('deadbeef01..HEAD') === -1)
  reason = 'round2 prompt missing the <prior-sha>..HEAD range: ' + round2Review.promptFull.slice(0,600);
else if (!reason && round2Review.promptFull.indexOf('Silent failure mode in claude/commands/build.md Step 3') === -1)
  reason = 'round2 prompt missing the round-1 findings TEXT (must be reused verbatim, never re-derived): ' + round2Review.promptFull.slice(0,900);
else if (!reason && !/MISS of the earlier round/.test(round2Review.promptFull))
  reason = 'round2 prompt missing the pre-existing-HIGH-is-a-miss-of-the-earlier-pass instruction';
else if (!reason && round2Review.promptFull.indexOf('## Continuation') === -1)
  reason = 'round2 prompt missing the continuation heading';
else if (!reason && (result2.parked ?? []).length !== 1)
  reason = 'round2: expected the continuation to park cleanly: ' + JSON.stringify(result2);

console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

# ============================================================================
# TEST (K2127-truthful): a continuation whose PRIOR round was CLEAN must not be
#   told it found blocking findings.
#
#   Round 2, HIGH B1 — the state this covers had NO coverage at all, so the
#   suite passed with the defect fully present. `round` is the shared
#   per-worktree §3e invocation counter, bumped by EVERY bumping reviewDiffCmd
#   call — not a count of review-blocking escalations. build.md's 3d-esc loop
#   resumes through 3c -> 3e for ANY escalation kind (rebase-conflict,
#   push-rejected, dirty-worktree, ci-failed, pr-open-failed…), each of which
#   bumps it while the review itself was CLEAN the round before — that is why
#   the item got as far as 3f/3g in the first place. Gating the continuation
#   section on `round > 1` alone therefore opened with the flatly false "Round N
#   found blocking finding(s), reproduced below" and then, because the 3e call
#   site correctly withholds a non-`review-blocking` verdict block, followed it
#   with "(no findings text was recorded for the prior round)" — a
#   self-contradiction handed to the reviewer AS ITS PREMISE.
#
#   Delta-awareness is still wanted here (that is the whole item); only the
#   premise changes. So this case asserts the positive (continuation heading,
#   the real <prior-sha>..HEAD range) AND the negatives (no false blocking
#   claim, no contradictory placeholder, no leaked unrelated verdict text).
# ============================================================================
run_node_case "K2127-truthful: a round>1 continuation resuming from a NON-review-blocking escalation is told the prior round was CLEAN, never that it found blocking findings" "
$PREAMBLE

// The verdict block for a rebase-conflict escalation is about an unrelated
// human/mechanical decision, NOT review output — driveItemBuildPhase gates the
// third runReviewers() argument on kind === 'review-blocking' precisely so this
// text can never reach the reviewer dressed up as prior review findings.
const UNRELATED_VERDICT = 'REBASE CONFLICT in workflows/scripts/build/gate.sh — resolved by taking ours.';
setMachinery('rp-clean',
  { outcome: 'REVIEW_DIFF', files: ['claude/commands/build.md'], tsv: '', tsv_rows: 0, tsv_checksum: 0, review_rounds: 1, review_prior_sha: 'cafe1234abcd' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'c0ffee03' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'c0ffee03', branch: 'build/rp-clean' },
  { outcome: 'PR_OPENED', pr_number: 2103 },
  { outcome: 'CI_GREEN' },
);
setWorker('rp-clean', { status: 'done', summary: 'rebase resolved', acceptance_results: [{ criterion: 'c', passed: true, evidence: 'e' }], commits: [] });
setReview('rp-clean', '## Summary\\nClean.\\n\\n## Findings\\nNone.\\n');

globalThis.args = { ...baseArgs, items: [
  { slug: 'rp-clean', branch: 'build/rp-clean', title: 'Clean continuation', kind: 'impl', acceptance: ['c'] },
], onlySlugs: ['rp-clean'], verdicts: { 'rp-clean': { kind: 'rebase-conflict', verdict_section: UNRELATED_VERDICT } } };

const mod = await loadLevel();
const result = await mod.default();
const call = callLog.find(c => (c.opts.label||'').startsWith('review:rp-clean#'));
let reason = null;
if (!call) reason = 'no reviewer call captured: ' + JSON.stringify(result);
else {
  const p = call.promptFull;
  if (p.indexOf('## Continuation') === -1)
    reason = 'a round>1 pass must still get the delta-aware continuation section: ' + p.slice(0,600);
  else if (p.indexOf('cafe1234abcd..HEAD') === -1)
    reason = 'the continuation must still carry the real <prior-sha>..HEAD range (delta-awareness is the point of the item): ' + p.slice(0,900);
  else if (p.indexOf('found blocking finding(s)') !== -1)
    reason = 'FALSE PREMISE: the prior round was CLEAN (no findings text supplied), so the prompt must NOT claim it found blocking findings: ' + p.slice(0,900);
  else if (p.indexOf('recorded NO blocking findings') === -1)
    reason = 'the prompt must state the TRUTHFUL clean-prior-round premise: ' + p.slice(0,900);
  else if (p.indexOf('no findings text was recorded') !== -1)
    reason = 'the self-contradictory placeholder must be gone — a clean prior round has no findings SECTION at all, not an empty one: ' + p.slice(0,900);
  else if (p.indexOf('## Prior round') !== -1)
    reason = 'a clean prior round must not emit a Prior-round-findings heading at all: ' + p.slice(0,900);
  else if (p.indexOf('Verify each prior-round finding') !== -1)
    reason = 'there is nothing to re-verify on a clean prior round — that step must be dropped, not left dangling: ' + p.slice(0,900);
  else if (p.indexOf(UNRELATED_VERDICT) !== -1)
    reason = 'a NON-review-blocking verdict block must never leak into the reviewer prompt as if it were prior review findings: ' + p.slice(0,900);
  else if (p.indexOf('Do BOTH of the following') === -1)
    reason = 'the step list must renumber to two steps on the clean-prior arm, not leave a 1./3. gap: ' + p.slice(0,900);
}
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

# ============================================================================
# TEST (K2127-cifix): the §3g CI-fix re-review call site — runReviewers(item,
#   wt) with NO third argument — is the single most frequent producer of a
#   `round > 1` continuation whose prior round was clean, and it too had no
#   coverage of the prompt it generates (round 2, MEDIUM 5). It bumps the SAME
#   shared per-worktree counter, so before the fix EVERY CI-fix retry opened its
#   re-review prompt with the false blocking-findings premise.
#
#   Built on the K1450 ci-fix-clean fixture, with the re-review's OWN diff fetch
#   now reporting review_rounds:1 + a prior sha (which is what the real marker
#   does on that path).
# ============================================================================
run_node_case "K2127-cifix: the CI-fix re-review (runReviewers with no prior-findings argument) gets a delta-aware but TRUTHFUL clean-prior-round prompt" "
$PREAMBLE

setMachinery('cifix-truth',
  { outcome: 'CREATED', path: '/tmp/repo.wt/cifix-truth' },
  { outcome: 'REVIEW_DIFF', files: ['claude/commands/build.md'], tsv: '', tsv_rows: 0, tsv_checksum: 0 },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'a15e' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'a15e', branch: 'build/cifix-truth' },
  { outcome: 'PR_OPENED', pr_number: 701 },
  { outcome: 'CI_FAILED', failed_run_ids: [1] },
  // The re-review's OWN diff fetch — a SEPARATE machinery call, and on the real
  // path it reads the marker §3e stamped before the push, hence round 1 + a sha.
  { outcome: 'REVIEW_DIFF', files: ['claude/commands/build.md'], tsv: '', tsv_rows: 0, tsv_checksum: 0, review_rounds: 1, review_prior_sha: 'beef5678cdef' },
  { outcome: 'PUSHED', sha: 'a25f', branch: 'build/cifix-truth' },
  { outcome: 'CI_GREEN' },
  { outcome: 'BODY_UPDATED', pr_number: 701 },
);
setWorker('cifix-truth',
  { status: 'done', summary: 'initial', acceptance_results: [{ criterion: 'c', passed: true, evidence: 'e' }], commits: [] },
  { status: 'done', summary: 'ci fixed', acceptance_results: [], commits: [] },
);
setReview('cifix-truth',
  '## Summary\\nclean on the original push.\\n\\n## Findings\\n(none)\\n',
  '## Summary\\nclean on the CI-fix commit too.\\n\\n## Findings\\n(none)\\n',
);

globalThis.args = { ...baseArgs, items: [
  { slug: 'cifix-truth', branch: 'build/cifix-truth', title: 'CI-fix truthful re-review', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();
let reason = null;
const reviewCalls = callLog.filter(c => isReviewCall(c.opts));
if (reviewCalls.length !== 2)
  reason = 'expected TWO review agent() calls (original push + CI-fix commit), got ' + reviewCalls.length + ': ' + JSON.stringify(reviewCalls.map(c => c.opts.label));
else {
  const first = reviewCalls[0].promptFull;
  const second = reviewCalls[1].promptFull;
  if (first.indexOf('## Continuation') !== -1)
    reason = 'the ORIGINAL round-1 review must carry no continuation section: ' + first.slice(0,400);
  else if (second.indexOf('## Continuation') === -1)
    reason = 'the CI-fix re-review is round 2 and must carry the delta-aware continuation section: ' + second.slice(0,600);
  else if (second.indexOf('beef5678cdef..HEAD') === -1)
    reason = 'the CI-fix re-review must carry the <prior-sha>..HEAD range so it can see what the fix changed: ' + second.slice(0,900);
  else if (second.indexOf('found blocking finding(s)') !== -1)
    reason = 'FALSE PREMISE on the CI-fix path: a round-1 pass that reached CI-fix had ZERO blocking findings (that is why it was pushed), so the re-review must not be told otherwise: ' + second.slice(0,900);
  else if (second.indexOf('recorded NO blocking findings') === -1)
    reason = 'the CI-fix re-review must state the truthful clean-prior-round premise: ' + second.slice(0,900);
  else if (second.indexOf('no findings text was recorded') !== -1)
    reason = 'the self-contradictory placeholder must be gone from the CI-fix path too: ' + second.slice(0,900);
}
if (!reason && (result.escalations ?? []).length !== 0)
  reason = 'expected 0 escalations: ' + JSON.stringify(result.escalations);
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

# --- K2127 static lockstep guards --------------------------------------------
# ACTIVATION, ANCHORED AT THE CALL SITE (round 2, MEDIUM 4). The round-1 guard
# here was `reviewPrompt\([^)]*prior`, which matches TWO lines in build-level.mjs
# — the function DEFINITION (`function reviewPrompt(item, wt, route, files,
# priorContext)`) as well as the spawning call site. Deleting the 5th argument at
# the call site would have fully DE-ACTIVATED the feature while leaving this
# guard green off the definition alone: a guard that cannot go red reads as
# coverage while providing none. `agent(reviewPrompt(` picks out the one spawning
# call site (a definition can never carry that prefix), and is the same predicate
# the plan note's Class-A activation criterion now names. Sibling precedent: the
# #2046 structural prong later in this file, which defends its own scan pattern
# against exactly this drift.
grep -qE 'agent\(reviewPrompt\([^)]*priorContext' "$MJS" \
  || fail "#2127: the reviewPrompt() CALL SITE — agent(reviewPrompt(…)) — must pass priorContext; that is the Class-A activation proof, and a match on the function DEFINITION alone does not prove the feature is wired"
# Two-step belt, #2046's shape: EVERY reviewPrompt invocation that is not the
# definition must carry the argument, so a second, unwired call site cannot be
# added later without going red. `\([^)]` excludes bare prose mentions
# (`reviewPrompt()`), which carry no argument by construction.
_k2127_uses="$(grep -nE 'reviewPrompt\([^)]' "$MJS" | grep -v 'function reviewPrompt' || true)"
[ -n "$_k2127_uses" ] \
  || fail "#2127: the activation scan found NO reviewPrompt invocation at all — the pattern has drifted away from the shape it is meant to catch and can no longer go red; fix the pattern rather than deleting the guard"
_k2127_bare="$(printf '%s\n' "$_k2127_uses" | grep -v 'priorContext' || true)"
[ -z "$_k2127_bare" ] \
  || fail "#2127: a reviewPrompt() invocation does not pass priorContext, so the continuation context is silently dropped at that call site. Offending line(s):
$_k2127_bare"
unset _k2127_uses _k2127_bare
grep -q 'function reviewContinuationSection(priorContext)' "$MJS" \
  || fail "#2127: build-level.mjs must define reviewContinuationSection(), the delta-aware instructions block spliced into a continuation prompt"
grep -q 'build-review-rounds-sha' "$MJS" \
  || fail "#2127: the prior-reviewed-SHA marker must be persisted BESIDE build-review-rounds so it survives the same escalate -> re-invoke loop"
grep -q 'review_prior_sha' "$MJS" \
  || fail "#2127: reviewDiffCmd must emit review_prior_sha for the continuation prompt to read"
# The continuation gate, pinned by NAME rather than by exact formatting (round 2,
# LOW 2 — the round-1 pin was the literal `round > 1 ?`, which a reflow would
# break for a no-op change). The invariant is that the gate exists and is a named
# predicate, never that it is spelled on one line; the behavioural round-1
# negative arm in the K2127 node case above is what actually proves round 1 stays
# byte-identical.
grep -qE 'const isContinuationRound = round[[:space:]]*>[[:space:]]*1' "$MJS" \
  || fail "#2127: priorContext must stay gated on the named continuation predicate (isContinuationRound = round > 1) — round 1 must never carry a prior-round argument (the byte-identical-output invariant)"
# The gate establishes only that a prior round RAN; whether it BLOCKED is decided
# solely by the presence of findings text. reviewContinuationSection() must
# therefore carry BOTH premises (round 2, HIGH B1) — a single hard-coded "found
# blocking finding(s)" opening is false on every CI-fix and non-review-blocking
# resume.
grep -q 'const hasFindings = ' "$MJS" \
  || fail "#2127: reviewContinuationSection() must branch its premise on whether prior findings are ACTUALLY present (hasFindings) — a fixed 'round N found blocking finding(s)' opening is FALSE on a CI-fix or non-review-blocking continuation"
echo "PASS: #2127 static lockstep guards — the reviewPrompt() CALL SITE carries priorContext (no definition-only match), reviewContinuationSection() exists and branches on findings presence, and the prior-reviewed-SHA marker/field are wired end to end"

# ============================================================================
# TEST (K1970-e2e): the round counter's GENERATED SHELL, executed for real
#   against a REAL LINKED worktree.
#
#   Every mock case above hands the driver a `review_rounds` fixture and never
#   runs the shell reviewDiffCmd() actually generates — so the durability half
#   (does the counter survive the escalate -> orchestrator -> re-invoke loop at
#   all?) would be entirely untested by them. This case closes that, mirroring
#   the #1219-e2e / #1937-e2e lift-the-generated-command pattern: it asserts
#   the counter advances across SEPARATE invocations, and that the marker lands
#   in the worktree's GIT DIR rather than its working tree (a stray untracked
#   file there would show up in `git status`, in the 3e.5 gate's --scoped
#   untracked-path resolution, and in the tracked-path coverage manifests).
# ============================================================================
K1970_E2E="$WF_TEST_TMPDIR/review-rounds-e2e"
mkdir -p "$K1970_E2E"
mkdir -p "$K1970_E2E/main-checkout"
(
  set -e
  cd "$K1970_E2E/main-checkout"
  git init --quiet .
  git symbolic-ref HEAD refs/heads/main
  git config user.email t@example.com
  git config user.name t
  printf 'base\n' > f.txt
  git add -A && git commit --quiet -m base
) || fail "#1970-e2e: could not build the base fixture"
git -C "$K1970_E2E/main-checkout" worktree add --quiet "$K1970_E2E/repo.wt/rounds" -b build/rounds main \
  || fail "#1970-e2e: could not create the linked worktree"
# Fixture self-check: a LINKED worktree's .git is a pointer FILE, so
# `git rev-parse --git-dir` (not a literal .git/ path) is the only correct way
# to reach its private git dir — the same shape #1937 was burned by.
[ -f "$K1970_E2E/repo.wt/rounds/.git" ] \
  || fail "#1970-e2e: fixture worktree's .git is not a pointer FILE — this fixture does not exercise the linked-worktree shape"

read -r -d '' K1970_EMIT_BODY << 'K1970_EMIT_END' || true
import { writeFileSync } from 'fs';
setMachinery('rounds',
  { outcome: 'CREATED', path: process.env.K1970_WT },
  { outcome: 'REVIEW_DIFF', files: [], tsv: '', tsv_rows: 0 },
);
happyWorker('rounds');
globalThis.args = { ...baseArgs, repoRoot: process.env.K1970_ROOT + '/repo', items: [
  { slug: 'rounds', branch: 'build/rounds', title: 'e2e', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
await mod.default();
const rd = callLog.find(c => /^review-diff:/.test(String(c.opts.label || '')));
writeFileSync(process.env.K1970_OUT, rd ? (rd.promptFull.split(/\nCommand:\n/)[1] || '') : '');
K1970_EMIT_END

K1970_CASE="$WF_TEST_TMPDIR/e2e-rounds.mjs"
printf '%s\n' "$PREAMBLE" > "$K1970_CASE"
printf '%s\n' "$K1970_EMIT_BODY" >> "$K1970_CASE"
MJS_PATH="$MJS" AGENT_DEF_PATH="$AGENT_DEF" \
K1970_ROOT="$K1970_E2E" K1970_WT="$K1970_E2E/repo.wt/rounds" K1970_OUT="$K1970_E2E/review-diff.sh" \
  node "$K1970_CASE" >/dev/null || fail "#1970-e2e: could not emit the generated review-diff command (node failed)"
[ -s "$K1970_E2E/review-diff.sh" ] || fail "#1970-e2e: no review-diff command was generated"

K1970_GD="$(git -C "$K1970_E2E/repo.wt/rounds" rev-parse --git-dir)"
[ -e "$K1970_GD/build-review-rounds" ] \
  && fail "#1970-e2e: fixture self-check failed — the round marker already exists before any run"
[ -e "$K1970_GD/build-review-rounds-sha" ] \
  && fail "#2127-e2e: fixture self-check failed — the prior-sha marker already exists before any run"
K2127_HEAD="$(git -C "$K1970_E2E/repo.wt/rounds" rev-parse HEAD)"

# temperloop#2127 — captured ONCE per round (not re-invoked per field): the
# generated script BUMPS on every call, so grep'ing review_rounds and
# review_prior_sha from two SEPARATE invocations would read two DIFFERENT
# rounds' output and desync the two assertions below from each other.
# CAPTURE FAILURES MUST NOT KILL THE SUITE (round 2, MEDIUM 3). This file runs
# under `set -euo pipefail`, so without the trailing `|| true` a `grep -o` that
# matches NOTHING — i.e. the single most likely regression, the field being
# dropped from the JSON line by the relay or by an edit to reviewDiffCmd — exits
# 1, pipefail propagates it, and `set -e` terminates the run AT THE ASSIGNMENT,
# before the `|| fail "… got '…'"` on the very next line can name what went
# wrong. The result was a bare non-zero exit with no clue which of ~13,000 lines
# died. `|| true` lets the capture yield the empty string so the diagnostic
# assertion below actually runs. Same treatment for the three K1970_Rn captures,
# which carried the identical latent bug. (Precedent: the K1970-octal captures
# further down already do this.)
#
# THE STRAY `\"` IS ALSO GONE (round 2, LOW 1). These patterns are SINGLE-quoted,
# so a `\"` reaches grep as an undefined BRE escape. BSD grep is silent about it;
# GNU grep warns `stray \ before "` twice per call, and GNU 3.8 promoted several
# sibling stray-escape warnings to hard errors. A bare `"` inside single quotes
# needs no escaping at all.
K1970_OUT1="$(bash "$K1970_E2E/review-diff.sh" 2>/dev/null || true)"
K1970_R1="$(printf '%s' "$K1970_OUT1" | grep -o '"review_rounds":[0-9]*' | head -1 || true)"
[ "$K1970_R1" = '"review_rounds":0' ] \
  || fail "#1970-e2e: a fresh worktree's FIRST review round must report 0 prior rounds; got '$K1970_R1'"
K2127_SHA1="$(printf '%s' "$K1970_OUT1" | grep -o '"review_prior_sha":"[0-9a-f]*"' | head -1 || true)"
[ "$K2127_SHA1" = '"review_prior_sha":""' ] \
  || fail "#2127-e2e: a fresh worktree's FIRST review round has nothing to carry yet and must report an EMPTY prior sha, never a bogus value; got '$K2127_SHA1'"

K1970_OUT2="$(bash "$K1970_E2E/review-diff.sh" 2>/dev/null || true)"
K1970_R2="$(printf '%s' "$K1970_OUT2" | grep -o '"review_rounds":[0-9]*' | head -1 || true)"
[ "$K1970_R2" = '"review_rounds":1' ] \
  || fail "#1970-e2e: the round counter must be DURABLE across separate invocations (that is the escalate -> re-invoke loop it bounds); got '$K1970_R2'"
K2127_SHA2="$(printf '%s' "$K1970_OUT2" | grep -o '"review_prior_sha":"[0-9a-f]*"' | head -1 || true)"
[ "$K2127_SHA2" = "\"review_prior_sha\":\"$K2127_HEAD\"" ] \
  || fail "#2127-e2e: round 2 must report the SHA round 1 actually reviewed (this fixture's one commit); got '$K2127_SHA2' (want review_prior_sha:\"$K2127_HEAD\")"

# THE DISCRIMINATING COMMIT (round 2, MEDIUM 2). Up to this point the fixture has
# exactly ONE commit, so `$K2127_HEAD` is simultaneously what round 1 reviewed,
# what round 2 reviewed, and current HEAD — which means an implementation that
# read the marker AFTER the bump (reporting CURRENT HEAD as the prior SHA, which
# destroys the entire point of this item: the delta range would always be empty)
# would satisfy every assertion above. Read-before-bump is the load-bearing
# property, and it is only observable once HEAD MOVES BETWEEN ROUNDS. Adding a
# second commit here splits the two values apart: round 3 must report the round-2
# HEAD (the OLD commit), and round 4 the new one. A read-after-bump build reports
# the new commit on round 3 and goes red.
K2127_HEAD2_PRE="$(git -C "$K1970_E2E/repo.wt/rounds" rev-parse HEAD)"
[ "$K2127_HEAD2_PRE" = "$K2127_HEAD" ] \
  || fail "#2127-e2e: fixture self-check failed — HEAD moved before the discriminating commit was made, so the round-3 assertion below would not measure what it claims"
printf 'second\n' >> "$K1970_E2E/repo.wt/rounds/f.txt"
git -C "$K1970_E2E/repo.wt/rounds" add -A >/dev/null 2>&1 \
  && git -C "$K1970_E2E/repo.wt/rounds" commit --quiet -m 'round-3 delta' \
  || fail "#2127-e2e: could not add the discriminating second commit to the fixture worktree"
K2127_HEAD2="$(git -C "$K1970_E2E/repo.wt/rounds" rev-parse HEAD)"
[ "$K2127_HEAD2" != "$K2127_HEAD" ] \
  || fail "#2127-e2e: fixture self-check failed — the second commit did not move HEAD, so rounds 3 and 4 cannot discriminate read-before-bump from read-after-bump"

K1970_OUT3="$(bash "$K1970_E2E/review-diff.sh" 2>/dev/null || true)"
K1970_R3="$(printf '%s' "$K1970_OUT3" | grep -o '"review_rounds":[0-9]*' | head -1 || true)"
[ "$K1970_R3" = '"review_rounds":2' ] \
  || fail "#1970-e2e: the round counter must keep advancing; got '$K1970_R3'"
K2127_SHA3="$(printf '%s' "$K1970_OUT3" | grep -o '"review_prior_sha":"[0-9a-f]*"' | head -1 || true)"
[ "$K2127_SHA3" = "\"review_prior_sha\":\"$K2127_HEAD\"" ] \
  || fail "#2127-e2e: round 3 must report the SHA round 2 actually reviewed ($K2127_HEAD), NOT current HEAD ($K2127_HEAD2) — reporting current HEAD is the read-AFTER-bump defect that would make every continuation diff range empty; got '$K2127_SHA3'"

K1970_OUT4="$(bash "$K1970_E2E/review-diff.sh" 2>/dev/null || true)"
K1970_R4="$(printf '%s' "$K1970_OUT4" | grep -o '"review_rounds":[0-9]*' | head -1 || true)"
[ "$K1970_R4" = '"review_rounds":3' ] \
  || fail "#1970-e2e: the round counter must keep advancing; got '$K1970_R4'"
K2127_SHA4="$(printf '%s' "$K1970_OUT4" | grep -o '"review_prior_sha":"[0-9a-f]*"' | head -1 || true)"
[ "$K2127_SHA4" = "\"review_prior_sha\":\"$K2127_HEAD2\"" ] \
  || fail "#2127-e2e: round 4 must report the NEW commit round 3 reviewed ($K2127_HEAD2) — the marker must ADVANCE with HEAD, not stay pinned to the first commit; got '$K2127_SHA4'"

[ -f "$K1970_GD/build-review-rounds" ] \
  || fail "#1970-e2e: the round marker must live in the worktree's private GIT DIR"
[ -f "$K1970_GD/build-review-rounds-sha" ] \
  || fail "#2127-e2e: the prior-reviewed-SHA marker must live BESIDE build-review-rounds, in the same private GIT DIR"
[ "$(cat "$K1970_GD/build-review-rounds-sha")" = "$K2127_HEAD2" ] \
  || fail "#2127-e2e: the on-disk sha marker must hold the most recently reviewed HEAD verbatim; got '$(cat "$K1970_GD/build-review-rounds-sha")'"
git -C "$K1970_E2E/repo.wt/rounds" status --porcelain | grep . >/dev/null \
  && fail "#1970-e2e/#2127-e2e: neither marker may appear in the worktree's working tree (git status must stay clean — a stray untracked file would reach the --scoped gate and the coverage manifests)"
echo "PASS: #1970-e2e round counter — the real generated review-diff shell reads and advances a DURABLE per-worktree counter kept in the private git dir, leaving the working tree clean"
echo "PASS: #2127-e2e prior-reviewed-sha marker — the real generated review-diff shell reads and advances a DURABLE per-worktree prior-reviewed-SHA marker kept beside build-review-rounds, leaving the working tree clean"

# ============================================================================
# TEST (K1970-octal): a CORRUPTED-BUT-PRESENT marker degrades SOFT.
#
#   The `tr -cd '0-9'` filter strips non-digits but not leading zeros, and
#   POSIX `$(( ))` reads a leading-`0` numeral as OCTAL — so a marker holding
#   `08`/`09` is not an off-by-N count but a HARD arithmetic error. Under
#   `sh` that error is FATAL: the shell exits before the closing printf, so
#   the machinery executor receives NO JSON line and §3e escalates
#   `review-diff-error` — the one escalation kind the loop this item bounds is
#   least able to act on. This code path never writes such a value itself, but
#   the marker is an ordinary file in the worktree's git dir (hand-editable,
#   restorable from a stale snapshot) and the whole marker contract is
#   "every step fails SOFT".
#
#   Executed against the SAME real generated shell the case above lifted, and
#   asserted under BOTH shells: `sh` (where the unfixed form aborts outright)
#   and `bash` (where it survives but emits `"review_rounds":08` — invalid
#   JSON, so the relay breaks one layer later instead).
# ============================================================================
printf '08\n' > "$K1970_GD/build-review-rounds"
K1970_OCT_SH="$(sh "$K1970_E2E/review-diff.sh" 2>/dev/null | grep -o '"review_rounds":[0-9]*' | head -1 || true)"
[ "$K1970_OCT_SH" = '"review_rounds":8' ] \
  || fail "#1970-octal: a marker holding '08' must read as DECIMAL 8 under sh, not abort the step on an octal arithmetic error; got '$K1970_OCT_SH'"
printf '09\n' > "$K1970_GD/build-review-rounds"
K1970_OCT_BASH="$(bash "$K1970_E2E/review-diff.sh" 2>/dev/null | grep -o '"review_rounds":[0-9]*' | head -1 || true)"
[ "$K1970_OCT_BASH" = '"review_rounds":9' ] \
  || fail "#1970-octal: a marker holding '09' must read as DECIMAL 9 under bash — a leading zero also makes the emitted JSON unparseable; got '$K1970_OCT_BASH'"
[ "$(cat "$K1970_GD/build-review-rounds")" = "10" ] \
  || fail "#1970-octal: the bump must write back a normalised DECIMAL count (9 -> 10), not re-corrupt the marker; got '$(cat "$K1970_GD/build-review-rounds")'"
# All-zeros: stripping leading zeros leaves the EMPTY string, so the existing
# `[ -n … ] || review_rounds=0` fallback is what must catch it — the same soft
# degradation a missing or unwritable marker already gets.
printf '000\n' > "$K1970_GD/build-review-rounds"
K1970_ZEROS="$(sh "$K1970_E2E/review-diff.sh" 2>/dev/null | grep -o '"review_rounds":[0-9]*' | head -1 || true)"
[ "$K1970_ZEROS" = '"review_rounds":0' ] \
  || fail "#1970-octal: an all-zeros marker must fall back to 0 (the empty result of stripping leading zeros), never emit an empty field; got '$K1970_ZEROS'"
echo "PASS: #1970-octal corrupted marker — a leading-zero count reads as decimal and an all-zeros one degrades to 0, so a hand-edited marker never aborts the step with an octal arithmetic error"

# ============================================================================
# TEST (K2127-corrupt): a CORRUPTED prior-SHA marker must degrade to EMPTY,
#   never to a plausible-but-bogus hex string.
#
#   The sibling of K1970-octal above, for the sibling marker, and the round-2
#   HIGH A this case exists to keep closed. `tr -cd '0-9a-fA-F'` is a FILTER,
#   not a validator: it DELETES the bytes it dislikes and hands back whatever
#   survives, and the survivors are frequently well-shaped hex. Measured
#   against this very generated shell before the fix:
#
#     marker content              emitted        looks like a sha?
#     `not a sha at all`       -> `aaaa`         yes
#     `ref: refs/heads/main`   -> `efefeada`     yes
#     `deadbeefcafe deadb…`    -> `deadbeefcafedeadbeefcafe`  yes
#
#   Every one of those reaches the reviewer as `git diff <bogus>..HEAD`, which
#   dies `fatal: ambiguous argument` in the REVIEWER's shell — somewhere §3e
#   never looks. The fix resolves the filtered value against the repo
#   (`git rev-parse --verify --quiet '<sha>^{commit}'`) and additionally
#   requires it to still be an ANCESTOR of HEAD, so a real-but-orphaned
#   pre-rebase commit degrades too (round 2, HIGH B2).
#
#   Asserted under BOTH shells, exactly as K1970-octal is, since the marker
#   block is `sh`-portable by contract.
# ============================================================================
# A plain function, NOT a `while read` over a pipe: `fail` exits, and an exit
# inside a pipeline's subshell would only kill the subshell, turning a genuine
# regression into a silently-passing case.
_k2127_expect_empty() {
  printf '%s\n' "$1" > "$K1970_GD/build-review-rounds-sha"
  _k2127_got="$(sh "$K1970_E2E/review-diff.sh" 2>/dev/null | grep -o '"review_prior_sha":"[0-9a-fA-F]*"' | head -1 || true)"
  [ "$_k2127_got" = '"review_prior_sha":""' ] \
    || fail "#2127-corrupt: a marker holding '$1' must degrade to an EMPTY prior sha — tr -cd is a sanitiser, not a validator, and its surviving bytes are frequently well-shaped hex that would pass straight through to a 'git diff <bogus>..HEAD' the reviewer cannot run; got '$_k2127_got'"
  # Under bash too — the marker block is sh-portable by contract, and the
  # K1970-octal sibling asserts under both shells for the same reason.
  printf '%s\n' "$1" > "$K1970_GD/build-review-rounds-sha"
  _k2127_got="$(bash "$K1970_E2E/review-diff.sh" 2>/dev/null | grep -o '"review_prior_sha":"[0-9a-fA-F]*"' | head -1 || true)"
  [ "$_k2127_got" = '"review_prior_sha":""' ] \
    || fail "#2127-corrupt (bash): a marker holding '$1' must degrade to an EMPTY prior sha; got '$_k2127_got'"
}
_k2127_expect_empty 'not a sha at all'
_k2127_expect_empty 'ref: refs/heads/main'
_k2127_expect_empty 'deadbeefcafe deadbeefcafe'
_k2127_expect_empty 'zzzz not hex zzzz'
_k2127_expect_empty '0000000000000000000000000000000000000000'
# A REAL commit object that is NOT an ancestor of HEAD must also degrade — this
# is the pre-rebase-orphan shape (HIGH B2): §3e stamps the marker BEFORE
# 3e.5-pre's gate-freshness rebase, so on the §3g CI-fix re-review path the
# recorded commit can have been rewritten off the branch. `<orphan>..HEAD` would
# then span the whole upstream delta plus the rebase rewrite plus the fix.
K2127_ORPHAN="$(git -C "$K1970_E2E/repo.wt/rounds" commit-tree "$(git -C "$K1970_E2E/repo.wt/rounds" rev-parse 'HEAD^{tree}')" -m 'orphan, not on this branch' 2>/dev/null || true)"
[ -n "$K2127_ORPHAN" ] \
  || fail "#2127-corrupt: fixture self-check failed — could not mint a real-but-unreachable commit object to exercise the ancestry rejection"
git -C "$K1970_E2E/repo.wt/rounds" rev-parse --verify --quiet "$K2127_ORPHAN^{commit}" >/dev/null \
  || fail "#2127-corrupt: fixture self-check failed — the minted orphan is not a resolvable commit, so this case would pass for the WRONG reason (it would be rejected as unresolvable, not as non-ancestor)"
printf '%s\n' "$K2127_ORPHAN" > "$K1970_GD/build-review-rounds-sha"
K2127_ORPHAN_GOT="$(sh "$K1970_E2E/review-diff.sh" 2>/dev/null | grep -o '"review_prior_sha":"[0-9a-fA-F]*"' | head -1 || true)"
[ "$K2127_ORPHAN_GOT" = '"review_prior_sha":""' ] \
  || fail "#2127-corrupt: a REAL commit that is no longer an ancestor of HEAD (the pre-rebase orphan a gate-freshness rebase leaves behind) must degrade to an EMPTY prior sha so the prompt falls back to its commit-range-free wording; got '$K2127_ORPHAN_GOT'"
# Positive control: the SAME machinery must still pass a genuine ancestor
# through. Without this the four negatives above would also be satisfied by an
# implementation that simply never emits a sha at all.
K2127_GOODSHA="$(git -C "$K1970_E2E/repo.wt/rounds" rev-parse HEAD)"
printf '%s\n' "$K2127_GOODSHA" > "$K1970_GD/build-review-rounds-sha"
K2127_GOOD_GOT="$(sh "$K1970_E2E/review-diff.sh" 2>/dev/null | grep -o '"review_prior_sha":"[0-9a-fA-F]*"' | head -1 || true)"
[ "$K2127_GOOD_GOT" = "\"review_prior_sha\":\"$K2127_GOODSHA\"" ] \
  || fail "#2127-corrupt: positive control failed — a genuine, resolvable, ancestor SHA must still be emitted verbatim; got '$K2127_GOOD_GOT'"
# An UNBORN HEAD must not write the literal string 'HEAD' into the marker
# (round 2, HIGH A, second path): a bare `git rev-parse HEAD` prints `HEAD` on
# STDOUT and exits 128 there, which `|| true` swallows and `[ -n … ]` accepts.
# `--verify --quiet` yields the empty string instead, so nothing is written.
K2127_UNBORN="$WF_TEST_TMPDIR/k2127-unborn"
mkdir -p "$K2127_UNBORN"
git -C "$K2127_UNBORN" init --quiet .
git -C "$K2127_UNBORN" symbolic-ref HEAD refs/heads/main
[ "$(git -C "$K2127_UNBORN" rev-parse HEAD 2>/dev/null || true)" = "HEAD" ] \
  || fail "#2127-corrupt: fixture self-check failed — this git does NOT print the literal 'HEAD' for a bare rev-parse on an unborn branch, so the unborn-HEAD case below cannot discriminate the defect it targets"
MJS_PATH="$MJS" AGENT_DEF_PATH="$AGENT_DEF" \
K1970_ROOT="$K1970_E2E" K1970_WT="$K2127_UNBORN" K1970_OUT="$K1970_E2E/review-diff-unborn.sh" \
  node "$K1970_CASE" >/dev/null || fail "#2127-corrupt: could not emit a review-diff command for the unborn-HEAD fixture (node failed)"
bash "$K1970_E2E/review-diff-unborn.sh" >/dev/null 2>&1 || true
K2127_UNBORN_GD="$(git -C "$K2127_UNBORN" rev-parse --absolute-git-dir)"
if [ -f "$K2127_UNBORN_GD/build-review-rounds-sha" ]; then
  fail "#2127-corrupt: on an UNBORN HEAD nothing may be written to the prior-sha marker — a bare 'git rev-parse HEAD' prints the literal string HEAD there (exit 128), which a later round's tr -cd filters to 'EAD'; marker holds '$(cat "$K2127_UNBORN_GD/build-review-rounds-sha")'"
fi
echo "PASS: #2127-corrupt prior-sha marker — a corrupted marker, a real-but-orphaned (pre-rebase) commit, and an unborn HEAD each degrade to an EMPTY prior sha, while a genuine ancestor still passes through verbatim"

# ============================================================================
# temperloop#2014: the push -> ci-poll SHA hand-off
# ============================================================================
# `ci-poll.sh --sha` is the #254 false-green pin, and build-level.mjs — not the
# machinery — owns the value. sq() stringifies whatever it is handed, so a
# `pushedSha` that never got populated reaches the poll as the LITERAL string
# `undefined`; ci-poll.sh refuses to run on it, and the driver used to read that
# refusal back through its catch-all ERROR arm as `ci-failed` — reporting a
# healthy, still-running PR (the reproduction: PR #2013, OPEN, checks
# IN_PROGRESS) as a red one. Four cases, one per half of the fix.

# --- 1. the hand-off itself: the poll is pinned to the SHA the push reported --
run_node_case "#2014 hand-off: the ci-poll --sha is the SAME sha the push step reported" "
$PREAMBLE

setMachinery('item-handoff',
  { outcome: 'CREATED', path: '/tmp/repo.wt/item-handoff' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'c0ffee1' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: '4f96deb', branch: 'build/item-handoff' },
  { outcome: 'PR_OPENED', pr_number: 2013 },
  { outcome: 'CI_GREEN' },
);
happyWorker('item-handoff');

globalThis.args = { ...baseArgs, items: [
  { slug: 'item-handoff', branch: 'build/item-handoff', title: 'Handoff Item', kind: 'impl' },
]};

const mod = await loadLevel();
const result = await mod.default();

if ((result.escalations ?? []).length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'expected no escalation: ' + JSON.stringify(result) })); process.exit(0); }
// The ci-batch prompt carries the literal ci-poll.sh command line; the pin is
// asserted on the EMITTED ARGUMENT, not on an internal variable, because the
// argument is what ci-poll.sh validates and what went wrong.
const ciCall = callLog.find(c => /^ci-batch:item-handoff/.test(String(c.opts.label || '')));
if (!ciCall)
  { console.log(JSON.stringify({ ok: false, reason: 'no ci-batch call was made' })); process.exit(0); }
if (!/--sha '4f96deb'/.test(ciCall.promptFull))
  { console.log(JSON.stringify({ ok: false, reason: 'poll not pinned to the pushed sha: ' + (ciCall.promptFull.match(/ci-poll[^\n]*/) || [''])[0] })); process.exit(0); }
if (/--sha '(undefined|null)'/.test(ciCall.promptFull))
  { console.log(JSON.stringify({ ok: false, reason: 'poll pinned to a stringified nullish value' })); process.exit(0); }
// …and the same sha is what the item parks with, so the PR body and the merge
// gate agree with what was actually polled.
if (result.parked[0].pushed_sha !== '4f96deb')
  { console.log(JSON.stringify({ ok: false, reason: 'parked pushed_sha diverged from the polled sha: ' + JSON.stringify(result.parked[0]) })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# --- 2. push reports PUSHED but no sha → its OWN kind, and NO poll is spawned --
run_node_case "#2014 pre-flight: a PUSHED with no sha escalates ci-poll-bad-argument, never ci-failed, and spawns no poll" "
$PREAMBLE

setMachinery('item-nosha',
  { outcome: 'CREATED', path: '/tmp/repo.wt/item-nosha' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'c0ffee2' },
  { outcome: 'SCAN_CLEAN' },
  // The reproduction's shape: the step reports success, its sha key is absent.
  { outcome: 'PUSHED', branch: 'build/item-nosha' },
  { outcome: 'PR_OPENED', pr_number: 2013 },
);
happyWorker('item-nosha');

globalThis.args = { ...baseArgs, items: [
  { slug: 'item-nosha', branch: 'build/item-nosha', title: 'No-Sha Item', kind: 'impl' },
]};

const mod = await loadLevel();
const result = await mod.default();

if ((result.escalations ?? []).length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 1 escalation: ' + JSON.stringify(result) })); process.exit(0); }
const esc = result.escalations[0];
if (esc.kind === 'ci-failed')
  { console.log(JSON.stringify({ ok: false, reason: 'a bad argument was reported as a red CI run (the #2014 regression)' })); process.exit(0); }
if (esc.kind !== 'ci-poll-bad-argument')
  { console.log(JSON.stringify({ ok: false, reason: 'escalation kind wrong: ' + esc.kind })); process.exit(0); }
if (esc.payload?.sha_seen !== 'undefined')
  { console.log(JSON.stringify({ ok: false, reason: 'payload must show the literal value the poll would have received: ' + JSON.stringify(esc.payload) })); process.exit(0); }
if (esc.payload?.pr !== 2013)
  { console.log(JSON.stringify({ ok: false, reason: 'payload must name the PR that is actually open: ' + JSON.stringify(esc.payload) })); process.exit(0); }
// The pre-flight half: no poll slice may be spent on an argument ci-poll.sh is
// certain to reject.
if (stepsRun('item-nosha').includes('ci-poll'))
  { console.log(JSON.stringify({ ok: false, reason: 'a ci-poll step ran on an unusable sha: ' + JSON.stringify(stepsRun('item-nosha')) })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# --- 3. a bad-argument ERROR from ci-poll.sh itself is NOT ci-failed ----------
# The belt to the pre-flight's braces: a vendored/older ci-poll.sh, or a
# validation this driver does not model, still refuses to run. That refusal
# carries no information about CI, so it must not ride `ci-failed`.
run_node_case "#2014 classify: a ci-poll.sh usage_error ERROR escalates ci-poll-bad-argument, not ci-failed" "
$PREAMBLE

setMachinery('item-usageerr',
  { outcome: 'CREATED', path: '/tmp/repo.wt/item-usageerr' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'c0ffee3' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'beef123', branch: 'build/item-usageerr' },
  { outcome: 'PR_OPENED', pr_number: 2013 },
  { outcome: 'ERROR', error: \"sha 'undefined' invalid — must be a hex commit SHA\", usage_error: true },
);
happyWorker('item-usageerr');

globalThis.args = { ...baseArgs, items: [
  { slug: 'item-usageerr', branch: 'build/item-usageerr', title: 'Usage Error Item', kind: 'impl' },
]};

const mod = await loadLevel();
const result = await mod.default();

if ((result.escalations ?? []).length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 1 escalation: ' + JSON.stringify(result) })); process.exit(0); }
if (result.escalations[0].kind !== 'ci-poll-bad-argument')
  { console.log(JSON.stringify({ ok: false, reason: 'escalation kind wrong: ' + result.escalations[0].kind })); process.exit(0); }
if (!/invalid/.test(String(result.escalations[0].payload?.ciOut?.error)))
  { console.log(JSON.stringify({ ok: false, reason: 'payload lost ci-poll.sh own error: ' + JSON.stringify(result.escalations[0].payload) })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# --- 4. the DISCRIMINATING control: a genuine ci-poll ERROR is STILL ci-failed -
# If every ERROR were re-routed the new kind would classify nothing. An ERROR
# that is not an argument refusal keeps its unchanged `ci-failed` path.
run_node_case "#2014 control: a NON-argument ci-poll ERROR still escalates ci-failed (the new kind discriminates)" "
$PREAMBLE

setMachinery('item-realerr',
  { outcome: 'CREATED', path: '/tmp/repo.wt/item-realerr' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'c0ffee4' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'beef456', branch: 'build/item-realerr' },
  { outcome: 'PR_OPENED', pr_number: 2013 },
  { outcome: 'ERROR', error: 'gh api failed after 3 attempts', transient_retries_exhausted: true },
);
happyWorker('item-realerr');

globalThis.args = { ...baseArgs, items: [
  { slug: 'item-realerr', branch: 'build/item-realerr', title: 'Real Error Item', kind: 'impl' },
]};

const mod = await loadLevel();
const result = await mod.default();

if ((result.escalations ?? []).length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 1 escalation: ' + JSON.stringify(result) })); process.exit(0); }
if (result.escalations[0].kind !== 'ci-failed')
  { console.log(JSON.stringify({ ok: false, reason: 'a non-argument ERROR was re-routed away from ci-failed: ' + result.escalations[0].kind })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# --- 5. the CI-fix re-push: the FIFTH sha assignment, guarded the same way ----
# Not on the issue's own audit list: the re-push's sha arrives through the same
# executor transport as the 3f push and can go missing the same way. It must not
# silently re-poll the PRE-FIX head either — that is the #254 false green.
run_node_case "#2014 ci-fix re-push: a PUSHED re-push with no sha escalates ci-poll-bad-argument, never re-polls the stale head" "
$PREAMBLE

setMachinery('item-fixnosha',
  { outcome: 'CREATED', path: '/tmp/repo.wt/item-fixnosha' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'ddd1' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'ddd1', branch: 'build/item-fixnosha' },
  { outcome: 'PR_OPENED', pr_number: 2013 },
  { outcome: 'CI_FAILED', failed_run_ids: [7] },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'PUSHED', branch: 'build/item-fixnosha' },   // re-push, sha absent
);
setWorker('item-fixnosha',
  { status: 'done', summary: 'first', acceptance_results: [{ criterion: 'c', passed: true, evidence: 'e' }], commits: [] },
  { status: 'done', summary: 'ci fix', acceptance_results: [{ criterion: 'c', passed: true, evidence: 'e' }], commits: [] },
);

globalThis.args = { ...baseArgs, items: [
  { slug: 'item-fixnosha', branch: 'build/item-fixnosha', title: 'Fix No-Sha Item', kind: 'impl' },
]};

const mod = await loadLevel();
const result = await mod.default();

if ((result.escalations ?? []).length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 1 escalation: ' + JSON.stringify(result) })); process.exit(0); }
const e5 = result.escalations[0];
if (e5.kind !== 'ci-poll-bad-argument')
  { console.log(JSON.stringify({ ok: false, reason: 'escalation kind wrong: ' + e5.kind + ' ' + JSON.stringify(e5.payload) })); process.exit(0); }
if (e5.payload?.stage !== 'ci-fix-push')
  { console.log(JSON.stringify({ ok: false, reason: 'payload must name the ci-fix-push stage: ' + JSON.stringify(e5.payload) })); process.exit(0); }
// Exactly one poll ran — the pre-fix one. A second would be pinned to the stale
// head the re-push replaced.
const polls = stepsRun('item-fixnosha').filter(k => k === 'ci-poll').length;
if (polls !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'expected exactly 1 ci-poll before the escalation, got ' + polls })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# --- 6. static guard: the hand-off choke point stays wired --------------------
# The pre-flight is one `if` in a 6000-line file. Without a guard, a future edit
# to the 3f->3g seam can drop it and every case above still passes, because they
# all exercise the arms that DO set a sha. Pin the call site by name.
K2014_MJS="$(cat "$MJS")"
case "$K2014_MJS" in
  *"if (hexSha(pushedSha) === null)"*) : ;;
  *) fail "#2014: the 3f->3g pre-flight guard on pushedSha is gone from build-level.mjs — every arm that sets pushedSha is unprotected again" ;;
esac
case "$K2014_MJS" in
  *"if (hexSha(fpush.sha) === null)"*) : ;;
  *) fail "#2014: the CI-fix re-push pre-flight guard is gone from build-level.mjs" ;;
esac
case "$K2014_MJS" in
  *"if (isBadArgumentError(out))"*) : ;;
  *) fail "#2014: ci-poll.sh argument refusals are no longer split out of the ci-failed catch-all" ;;
esac
echo "PASS: #2014 static guard — both pushedSha pre-flights and the bad-argument split are wired in build-level.mjs"

# ============================================================================
# TEST (K2006-silent): a CLEAN create over an empty path stays SILENT.
#
#   worktree.sh `create` reports `sidelined:false` when nothing occupied the
#   deterministic path. The driver must then emit NO notice, stamp NO field on
#   the parked record, and return the byte-identical pre-#2006 object — i.e.
#   this fix costs an ordinary level exactly nothing. This is the control that
#   makes the reporting case below discriminating rather than vacuous.
# ============================================================================
run_node_case "K2006: clean create over an empty path — no sideline notice, no parked field, no level rollup" "
$PREAMBLE

const logLines = [];
globalThis.log = (m) => { logLines.push(String(m)); };

setMachinery('item-k2006-clean',
  { outcome: 'CREATED', path: '/tmp/repo.wt/item-k2006-clean', branch: 'build/item-k2006-clean', sidelined: false, sidelined_path: '', sidelined_branch: '' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'c1ea4c0' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'c1ea4c0', branch: 'build/item-k2006-clean' },
  { outcome: 'PR_OPENED', pr_number: 2006 },
  { outcome: 'CI_GREEN' },
);
happyWorker('item-k2006-clean');

globalThis.args = { ...baseArgs, items: [
  { slug: 'item-k2006-clean', branch: 'build/item-k2006-clean', title: 'Clean create', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();

const parked = result.parked ?? [];
if (parked.length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 1 parked, got ' + JSON.stringify(result) })); process.exit(0); }
if ('sidelined' in parked[0])
  { console.log(JSON.stringify({ ok: false, reason: 'a clean create must stamp NO sidelined field on the parked record: ' + JSON.stringify(parked[0].sidelined) })); process.exit(0); }
if ('sidelined' in result)
  { console.log(JSON.stringify({ ok: false, reason: 'a clean create must omit the level rollup entirely: ' + JSON.stringify(result.sidelined) })); process.exit(0); }
const noisy = logLines.filter(l => l.includes('SIDELINED BUILD'));
if (noisy.length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'a clean create must emit NO sideline notice; got: ' + JSON.stringify(noisy) })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST (K2006-reports): a create over a COMMIT-BEARING worktree sidelines AND
# reports — the defect temperloop#2006 filed.
#
#   worktree.sh MOVES the un-preservable occupant to
#   `<path>.unpreserved-<sha8>` on `<branch>.unpreserved-<sha8>` and still
#   returns CREATED (its never-refuse contract, worktree.sh:783-787), carrying
#   the verdict as FIELDS. build-level.mjs had zero occurrences of `sidelined`
#   and dropped all three, so an intact committed build was shelved while a
#   fresh worker rebuilt the same item and nothing said so.
#
#   Asserted on all three surfaces the fix must reach, because a transient log
#   line alone does not survive to the merge gate:
#     1. a NAMED log notice carrying the path, the branch AND the recovery;
#     2. the parked record's own `sidelined` object (what flows back to the
#        orchestrator and rides to Step 4's gate);
#     3. the level-summary rollup on the returned object.
#   The recovery assertion is the load-bearing one: 'a sideline happened' is
#   exactly the notice that leaves an operator with nowhere to go.
# ============================================================================
run_node_case "K2006: create over a commit-bearing worktree — sidelines AND reports path, branch and recovery" "
$PREAMBLE

const logLines = [];
globalThis.log = (m) => { logLines.push(String(m)); };

const SP = '/tmp/repo.wt/item-k2006-side.unpreserved-deadbeef';
const SB = 'build/item-k2006-side.unpreserved-deadbeef';

setMachinery('item-k2006-side',
  { outcome: 'CREATED', path: '/tmp/repo.wt/item-k2006-side', branch: 'build/item-k2006-side', sidelined: true, sidelined_path: SP, sidelined_branch: SB },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: '51de1ed' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: '51de1ed', branch: 'build/item-k2006-side' },
  { outcome: 'PR_OPENED', pr_number: 20061 },
  { outcome: 'CI_GREEN' },
);
happyWorker('item-k2006-side');

globalThis.args = { ...baseArgs, items: [
  { slug: 'item-k2006-side', branch: 'build/item-k2006-side', title: 'Sidelining create', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();

// 1. the NAMED log notice
const notices = logLines.filter(l => l.includes('SIDELINED BUILD') && l.includes('item-k2006-side'));
if (notices.length === 0)
  { console.log(JSON.stringify({ ok: false, reason: 'no named SIDELINED BUILD notice was logged; log was ' + JSON.stringify(logLines) })); process.exit(0); }
const n0 = notices[0];
if (!n0.includes(SP))
  { console.log(JSON.stringify({ ok: false, reason: 'the notice omits the sidelined PATH verbatim: ' + n0 })); process.exit(0); }
if (!n0.includes(SB))
  { console.log(JSON.stringify({ ok: false, reason: 'the notice omits the sidelined BRANCH verbatim: ' + n0 })); process.exit(0); }
if (!/git -C /.test(n0) || !/push -u origin /.test(n0))
  { console.log(JSON.stringify({ ok: false, reason: 'the notice names no concrete RECOVERY command: ' + n0 })); process.exit(0); }

// 2. the parked record — what flows back to the orchestrator and survives to the merge gate
const parked = result.parked ?? [];
if (parked.length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 1 parked, got ' + JSON.stringify(result) })); process.exit(0); }
const sl = parked[0].sidelined;
if (!sl)
  { console.log(JSON.stringify({ ok: false, reason: 'the parked record carries no sidelined field — the notice died as a log line: ' + JSON.stringify(parked[0]) })); process.exit(0); }
if (sl.path !== SP || sl.branch !== SB)
  { console.log(JSON.stringify({ ok: false, reason: 'parked.sidelined path/branch are not verbatim: ' + JSON.stringify(sl) })); process.exit(0); }
if (!sl.recovery || !sl.recovery.includes(SP) || !sl.recovery.includes(SB))
  { console.log(JSON.stringify({ ok: false, reason: 'parked.sidelined.recovery does not name where the build is and how to reclaim it: ' + JSON.stringify(sl) })); process.exit(0); }

// 3. the level-summary rollup
const roll = result.sidelined ?? [];
if (roll.length !== 1 || roll[0].slug !== 'item-k2006-side' || roll[0].path !== SP || roll[0].branch !== SB)
  { console.log(JSON.stringify({ ok: false, reason: 'level rollup missing or wrong: ' + JSON.stringify(roll) })); process.exit(0); }
const summaryLines = logLines.filter(l => l.startsWith('level SIDELINED BUILD summary'));
if (summaryLines.length !== 1 || !summaryLines[0].includes(SP))
  { console.log(JSON.stringify({ ok: false, reason: 'no level-summary line naming the shelved build: ' + JSON.stringify(logLines) })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST (K2006-escalation): the notice rides an ESCALATION too.
#
#   The shelving happens at 3b, before the worker runs, so the item that
#   sidelined a build is at least as likely to escalate as to park. If the
#   notice only ever reached the parked arm, the loudest case — a sideline
#   followed by a blocked/failed worker — would still report nothing. The stamp
#   is therefore applied at the ONE fan-out choke point, and this pins that.
# ============================================================================
run_node_case "K2006: an escalating item still carries the sideline notice on its payload" "
$PREAMBLE

const SP = '/tmp/repo.wt/item-k2006-esc.unpreserved-cafebabe';
const SB = 'build/item-k2006-esc.unpreserved-cafebabe';

setMachinery('item-k2006-esc',
  { outcome: 'CREATED', path: '/tmp/repo.wt/item-k2006-esc', branch: 'build/item-k2006-esc', sidelined: true, sidelined_path: SP, sidelined_branch: SB },
);
setWorker('item-k2006-esc',
  { status: 'blocked', questions: ['what now?'] }
);
setPreserve('item-k2006-esc', { outcome: 'WORK_PRESERVE_SKIP', detail: 'no worktree' });

globalThis.args = { ...baseArgs, items: [
  { slug: 'item-k2006-esc', branch: 'build/item-k2006-esc', title: 'Escalating after sideline', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();

const esc = result.escalations ?? [];
if (esc.length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 1 escalation, got ' + JSON.stringify(result) })); process.exit(0); }
const sl = esc[0].payload && esc[0].payload.sidelined;
if (!sl || sl.path !== SP || sl.branch !== SB || !sl.recovery)
  { console.log(JSON.stringify({ ok: false, reason: 'the escalation payload lost the sideline notice: ' + JSON.stringify(esc[0]) })); process.exit(0); }
if (!esc[0].payload.verdict || esc[0].payload.verdict.status !== 'blocked')
  { console.log(JSON.stringify({ ok: false, reason: 'stamping the notice clobbered the escalation payload: ' + JSON.stringify(esc[0].payload) })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# --- K2046 no-production-state guard (structural + behavioural) -------------
# THE SHAPE THIS PINS: a test case that executes the REAL generated
# review-diff pipeline against the REAL repo root with reviewDiffCmd's BUMPING
# default. That is not a stylistic preference — it writes production state
# (`<git-dir>/build-review-rounds`, the §3e round counter #1970's convergence
# bound reads) from a test run, and does so SILENTLY: no case fails, the
# counter just drifts upward every time anyone runs the suite, until a real
# review round opens at round 9 or 17 against a max of 3 and #1970 carries
# unresolved HIGH findings into the PR body instead of converging. Both live
# occurrences (temperloop#2003, temperloop#2006) were diagnosed only by hand.
#
# Prong 1 is STRUCTURAL: scan this suite's OWN source for the offending call
# shape. Prose mentions (`reviewDiffCmd()`, `reviewDiffCmd's`) carry no
# argument and are excluded by construction — `\([^)]` matches only a call with
# a real first argument — so every hit is a genuine invocation and must carry
# the explicit non-bumping arm.
_k2046_self="${BASH_SOURCE[0]}"
_k2046_calls="$(grep -nE 'reviewDiffCmd\([^)]' "$_k2046_self" || true)"
[ -n "$_k2046_calls" ] \
  || fail "#2046: the structural no-bump guard found NO reviewDiffCmd call at all — the scan pattern has drifted away from the shape it is supposed to catch, so it can no longer go red; fix the pattern rather than deleting the guard"
_k2046_bumping="$(printf '%s\n' "$_k2046_calls" | grep -vE 'reviewDiffCmd\([^)]*,[[:space:]]*false[[:space:]]*\)' || true)"
[ -z "$_k2046_bumping" ] \
  || fail "#2046: a test case invokes the REAL reviewDiffCmd against the repo root with the BUMPING default — that writes the production §3e review-round marker as a side effect of running the tests and fires #1970's convergence bound on the first real review round. Fix: pass the explicit non-bumping second argument, false, which production already uses for the #1976 re-fetch and which changes nothing these parity cases measure. Offending call site(s):
$_k2046_bumping"
unset _k2046_self _k2046_calls _k2046_bumping
echo "PASS: #2046 structural no-bump guard — every reviewDiffCmd invocation in this suite passes the explicit non-bumping arm, so no case can write the production review-round marker"

# Prong 2 is BEHAVIOURAL and shape-independent: whatever a future case does,
# by whatever name, the suite must leave the marker exactly as it found it.
# This catches the general failure the structural prong only catches one
# spelling of — a test writing production state.
_k2046_after="ABSENT"
if [ -n "$REVIEW_ROUNDS_MARKER" ] && [ -f "$REVIEW_ROUNDS_MARKER" ]; then
  _k2046_after="$(cat "$REVIEW_ROUNDS_MARKER" 2>/dev/null || echo UNREADABLE)"
fi
[ "$_k2046_after" = "$REVIEW_ROUNDS_BEFORE" ] \
  || fail "#2046: running this suite CHANGED the production §3e review-round marker at $REVIEW_ROUNDS_MARKER (before: $REVIEW_ROUNDS_BEFORE, after: $_k2046_after). A test run must never write production state; when the suite runs inside a build worktree this counter is that worktree's own, and inflating it fires #1970's convergence bound before the first real review round."
unset _k2046_after
echo "PASS: #2046 production-state guard — a full suite run leaves the §3e review-round marker byte-identical to how it found it (${REVIEW_ROUNDS_BEFORE})"

# temperloop#2127 — the SAME treatment, same reasoning, for the sibling
# prior-reviewed-SHA marker: it is written by the identical bumping code path,
# so it needs the identical behavioural (shape-independent) after-snapshot.
_k2127_after="ABSENT"
if [ -n "$REVIEW_ROUNDS_SHA_MARKER" ] && [ -f "$REVIEW_ROUNDS_SHA_MARKER" ]; then
  _k2127_after="$(cat "$REVIEW_ROUNDS_SHA_MARKER" 2>/dev/null || echo UNREADABLE)"
fi
[ "$_k2127_after" = "$REVIEW_ROUNDS_SHA_BEFORE" ] \
  || fail "#2127: running this suite CHANGED the production §3e prior-reviewed-SHA marker at $REVIEW_ROUNDS_SHA_MARKER (before: $REVIEW_ROUNDS_SHA_BEFORE, after: $_k2127_after). Same production-state contract as #2046's round counter — a test run must never write it."
unset _k2127_after
echo "PASS: #2127 production-state guard — a full suite run leaves the §3e prior-reviewed-SHA marker byte-identical to how it found it (${REVIEW_ROUNDS_SHA_BEFORE})"

# ============================================================================
# TEST (K2004-control-empty): a LEGITIMATELY empty level stays SILENT.
#
#   This is the DISCRIMINATION CONTROL, and it runs first on purpose: a guard
#   that flags every empty level is worse than no guard at all. A level asked
#   to drive nothing — an empty `items` array — disposes of nothing as a
#   tautology, not a contradiction. It must produce NO zeroDisposition field,
#   NO notice, and a return byte-identical to the pre-#2004 object (exactly the
#   two keys `parked` and `escalations`).
# ============================================================================
run_node_case "K2004: a legitimately empty level (nothing asked to drive) is NOT flagged" "
$PREAMBLE

const logLines = [];
globalThis.log = (m) => { logLines.push(String(m)); };

globalThis.args = { ...baseArgs, items: [] };

const mod = await loadLevel();
const result = await mod.default();

if ('zeroDisposition' in result)
  { console.log(JSON.stringify({ ok: false, reason: 'an empty level must NOT be flagged: ' + JSON.stringify(result.zeroDisposition) })); process.exit(0); }
const keys = Object.keys(result);
if (keys.length !== 2 || keys[0] !== 'parked' || keys[1] !== 'escalations')
  { console.log(JSON.stringify({ ok: false, reason: 'an empty level must return the byte-identical pre-#2004 object; got keys ' + JSON.stringify(keys) })); process.exit(0); }
const noisy = logLines.filter(l => l.includes('ZERO-DISPOSITION'));
if (noisy.length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'an empty level must emit NO zero-disposition notice; got: ' + JSON.stringify(noisy) })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST (K2004-control-filtered): an onlySlugs filter that matches NOTHING is
# the same control, reached by the other route.
#
#   The driven set is `activeItems` — the POST-onlySlugs set — not `items`. A
#   continuation whose onlySlugs names no item in the level has a non-empty
#   `items` array and an empty driven set, so a guard keyed on `items` would
#   fire here falsely. This pins the guard to the set actually driven.
# ============================================================================
run_node_case "K2004: an onlySlugs filter matching no item is NOT flagged (driven set, not items)" "
$PREAMBLE

const logLines = [];
globalThis.log = (m) => { logLines.push(String(m)); };

globalThis.args = { ...baseArgs,
  items: [
    { slug: 'item-k2004-other', branch: 'build/item-k2004-other', title: 'Sibling', kind: 'impl', acceptance: ['c'] },
  ],
  onlySlugs: ['item-k2004-absent'],
};

const mod = await loadLevel();
const result = await mod.default();

if ('zeroDisposition' in result)
  { console.log(JSON.stringify({ ok: false, reason: 'an empty DRIVEN set must NOT be flagged even when items is non-empty: ' + JSON.stringify(result.zeroDisposition) })); process.exit(0); }
const noisy = logLines.filter(l => l.includes('ZERO-DISPOSITION'));
if (noisy.length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'an empty driven set must emit NO notice; got: ' + JSON.stringify(noisy) })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST (K2004-control-spike): a SPIKE-ONLY level is NOT flagged.
#
#   A kind:spike item opens no PR and pushes no SHA — it disposes of nothing
#   through the push/PR/CI arms — which is exactly the shape a naive guard
#   would misread as 'disposed of nothing'. It does, however, park a verdict
#   marker (park(slug, null, null, …)), so it lands on control 2. This test is
#   the explicit check that the by-design-nothing-merged level stays silent.
# ============================================================================
run_node_case "K2004: a spike-only level (verdict-park, no PR) is NOT flagged" "
$PREAMBLE

const logLines = [];
globalThis.log = (m) => { logLines.push(String(m)); };

setMachinery('item-k2004-spike' /* empty — a spike makes no machinery calls */);
setWorker('item-k2004-spike',
  { status: 'done', summary: 'verdict produced', acceptance_results: [{ criterion: 'verdict-written', passed: true, evidence: 'v.md' }], verification_surface_path: '/tmp/verdict.md' }
);

globalThis.args = { ...baseArgs, items: [
  { slug: 'item-k2004-spike', branch: 'build/item-k2004-spike', title: 'Spike only', kind: 'spike', acceptance: ['verdict-written'] },
]};

const mod = await loadLevel();
const result = await mod.default();

const parked = result.parked ?? [];
if (parked.length !== 1 || parked[0].pr !== null || parked[0].pushed_sha !== null)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 1 verdict-only park, got ' + JSON.stringify(result) })); process.exit(0); }
if ('zeroDisposition' in result)
  { console.log(JSON.stringify({ ok: false, reason: 'a spike-only level disposes of nothing BY DESIGN and must NOT be flagged: ' + JSON.stringify(result.zeroDisposition) })); process.exit(0); }
const noisy = logLines.filter(l => l.includes('ZERO-DISPOSITION'));
if (noisy.length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'a spike-only level must emit NO notice; got: ' + JSON.stringify(noisy) })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST (K2004-flagged): zero disposition against a NON-EMPTY driven set is a
# NAMED contradiction — the defect temperloop#2004 filed.
#
#   The observed case (run wf_f3b9c160-6ca) was a resumed run that re-ran
#   nothing and returned {parked:[], escalations:[]} in ~13 ms while the
#   tracked issue was still in-progress with a live claim. The in-process shape
#   of the same partition is parallel() dropping every settled result to null —
#   the exact null-drop buildLevel's own fan-out comment names — so the mock
#   drops them here and the partition comes back empty for a level that WAS
#   asked to drive an item.
#
#   Asserted on the two surfaces a caller can act on:
#     1. the NAMED, branchable `zeroDisposition` field on the return (not a
#        throw, not a bare failure) — carrying which slugs were asked for and
#        a concrete re-probe for issue status, open PRs and the worktree;
#     2. a named log notice, so a transcript reader sees it too.
#   The re-probe assertion is the load-bearing one: 'nothing was disposed' with
#   no slugs and nowhere to look leaves a driver exactly where it started.
# ============================================================================
run_node_case "K2004: zero disposition against a non-empty driven set is a NAMED contradiction" "
$PREAMBLE

const logLines = [];
globalThis.log = (m) => { logLines.push(String(m)); };
// Every settled result dropped — parallel()'s documented null-drop, the
// in-process shape of a drive that disposed of nothing.
globalThis.parallel = async (fns) => fns.map(() => null);

globalThis.args = { ...baseArgs, items: [
  { slug: 'item-k2004-lost', branch: 'build/item-k2004-lost', title: 'Vanishing item', kind: 'impl', acceptance: ['c'], ghIssue: 2004 },
]};

const mod = await loadLevel();
const result = await mod.default();

// The partition really is empty — the precondition this guard exists for.
if ((result.parked ?? []).length !== 0 || (result.escalations ?? []).length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'test precondition broken — the partition was not empty: ' + JSON.stringify(result) })); process.exit(0); }

// 1. the NAMED, branchable outcome
const zd = result.zeroDisposition;
if (!zd)
  { console.log(JSON.stringify({ ok: false, reason: 'a zero-disposition return for a non-empty driven set fell through as a clean level: ' + JSON.stringify(result) })); process.exit(0); }
if (!Array.isArray(zd.slugs) || zd.slugs.length !== 1 || zd.slugs[0] !== 'item-k2004-lost')
  { console.log(JSON.stringify({ ok: false, reason: 'the outcome does not name which slugs were asked for: ' + JSON.stringify(zd) })); process.exit(0); }
if (zd.requested !== 1 || zd.parked !== 0 || zd.escalations !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'the outcome does not state the asked-for vs disposed-of counts: ' + JSON.stringify(zd) })); process.exit(0); }
const one = (zd.items ?? [])[0];
if (!one || one.slug !== 'item-k2004-lost' || one.issue !== 2004 || one.branch !== 'build/item-k2004-lost')
  { console.log(JSON.stringify({ ok: false, reason: 'the outcome does not carry the per-slug identity a caller re-probes with: ' + JSON.stringify(zd.items) })); process.exit(0); }
if (!one.worktree || !one.worktree.includes('item-k2004-lost'))
  { console.log(JSON.stringify({ ok: false, reason: 'the outcome names no worktree to re-probe: ' + JSON.stringify(one) })); process.exit(0); }
// the load-bearing one: a concrete re-probe of issue status, open PRs AND the worktree
if (!one.reprobe || !/gh issue view 2004/.test(one.reprobe) || !/gh pr list/.test(one.reprobe) || !/git -C /.test(one.reprobe))
  { console.log(JSON.stringify({ ok: false, reason: 'the outcome names no concrete RE-PROBE of issue status, open PRs and the worktree: ' + JSON.stringify(one.reprobe) })); process.exit(0); }

// 2. the named log notice
const notices = logLines.filter(l => l.includes('ZERO-DISPOSITION') && l.includes('item-k2004-lost'));
if (notices.length === 0)
  { console.log(JSON.stringify({ ok: false, reason: 'no named ZERO-DISPOSITION notice was logged; log was ' + JSON.stringify(logLines) })); process.exit(0); }

// and the 'level done' line must not read as a clean pass
const doneLine = logLines.filter(l => l.startsWith('level done'))[0] || '';
if (!doneLine.includes('ZERO-DISPOSITION'))
  { console.log(JSON.stringify({ ok: false, reason: \"the 'level done' line still reads as a clean level: \" + doneLine })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST (K2004-flagged-continuation): the same contradiction on a CONTINUATION
# run names the onlySlugs set, not the level's full membership.
#
#   The observed case was a RESUME, so this is the shape most likely to recur:
#   the driven set is the onlySlugs subset, and a sibling already parked in an
#   earlier round must not be reported as lost.
# ============================================================================
run_node_case "K2004: a continuation's contradiction names the onlySlugs set, and flags continuation:true" "
$PREAMBLE

globalThis.log = () => {};
globalThis.parallel = async (fns) => fns.map(() => null);

globalThis.args = { ...baseArgs,
  items: [
    { slug: 'item-k2004-resumed', branch: 'build/item-k2004-resumed', title: 'Resumed', kind: 'impl', acceptance: ['c'], ghIssue: 20041 },
    { slug: 'item-k2004-sibling', branch: 'build/item-k2004-sibling', title: 'Already parked sibling', kind: 'impl', acceptance: ['c'], ghIssue: 20042 },
  ],
  onlySlugs: ['item-k2004-resumed'],
  verdicts: { 'item-k2004-resumed': 'go' },
};

const mod = await loadLevel();
const result = await mod.default();

const zd = result.zeroDisposition;
if (!zd)
  { console.log(JSON.stringify({ ok: false, reason: 'a continuation that disposed of nothing fell through as a clean level: ' + JSON.stringify(result) })); process.exit(0); }
if (zd.slugs.length !== 1 || zd.slugs[0] !== 'item-k2004-resumed')
  { console.log(JSON.stringify({ ok: false, reason: 'the outcome must name the onlySlugs set, not the full level: ' + JSON.stringify(zd.slugs) })); process.exit(0); }
if (zd.continuation !== true)
  { console.log(JSON.stringify({ ok: false, reason: 'a continuation contradiction must say so: ' + JSON.stringify(zd) })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# --- temperloop#2004 zero-disposition driver-arm guards ---------------------
# The runtime cases above pin the PRODUCER: build-level.mjs names the
# contradiction. This pins the three CONSUMERS. The whole point of hoisting the
# guard below the drivers is that /build, /fix and /sweep each inherit it — a
# named outcome nobody branches on is the same silent fall-through the item
# filed, just with a field attached. So every spec that branches on the
# {parked, escalations} return must name `zeroDisposition`, and the .mjs must
# actually emit the field those arms read.
#
# Deliberately file-scoped, like the #2020 disposition guards above: the three
# arms live as mid-section bullets (build.md Step 3 / 3d-esc, fix.md Step 4a,
# sweep.md Phase 2) with no stable heading to anchor on. A file-level assertion
# catches a spec that never mentions the outcome at all and claims no more.
for spec_rel in claude/commands/build.md claude/commands/sweep.md claude/commands/fix.md; do
  spec_abs="$REPO_ROOT/$spec_rel"
  [ -f "$spec_abs" ] \
    || fail "#2004: $spec_rel is missing — the consumer half of this contract pair cannot be verified"
  grep -q 'zeroDisposition' "$spec_abs" \
    || fail "#2004: $spec_rel branches on the {parked, escalations} return but never names zeroDisposition — a zero-disposition return would fall through this driver as a completed level, which is the silent item-loss temperloop#2004 filed"
  grep -qi 'reprobe\|re-probe' "$spec_abs" \
    || fail "#2004: $spec_rel names zeroDisposition but never says to RE-PROBE real state on it — naming the outcome without acting on it leaves the item exactly as lost"
done
grep -q 'zeroDisposition' "$MJS" \
  || fail "#2004: the driver arms above read a field build-level.mjs must actually emit — the zero-disposition producer half is missing"
grep -qi 'zero-disposition' "$MJS" \
  || fail "#2004: build-level.mjs emits no named zero-disposition notice — the field alone leaves a transcript reader with nothing"
echo "PASS: #2004 driver-arm guards — build.md, sweep.md and fix.md each carry a zeroDisposition re-probe arm over the field build-level.mjs emits"

# ============================================================================
# temperloop#2080 — dual-build arms + the level barrier
#
# The phase split (driveItemBuild / driveItemPr) and the dual-build fan-out.
# The first case is the load-bearing CONTROL: with no `dualBuild` input the
# single-arm path must be unchanged in its TRANSCRIPT, not merely in its return
# object — same machinery steps in the same order, same agent spawns in the same
# order, no extra probe anywhere. Everything after it exercises the dual path.
# ============================================================================

# ---------------------------------------------------------------------------
# K2080 CONTROL: the single-arm transcript is unchanged by the phase split
# ---------------------------------------------------------------------------
run_node_case "K2080 control: no dualBuild input — the single-arm machinery step order AND agent-spawn order are byte-identical to the pre-split path" "
$PREAMBLE

happyMachinery('k2080ctl', 2080, 'c2080');
happyWorker('k2080ctl');

globalThis.args = { ...baseArgs, items: [
  { slug: 'k2080ctl', branch: 'build/k2080ctl', title: 'Control', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();

// The machinery STEP order — the 3b worktree create, then 3f's four-step
// pr-batch, then 3g's interleaved merge-state/ci-poll pair. A phase split that
// reordered, duplicated or dropped any of these would show up here first.
const steps = stepsRun('k2080ctl').join(',');
const EXPECT_STEPS = 'worktree,rebase,scan,push,pr-open,merge-state,ci-poll';
if (steps !== EXPECT_STEPS)
  { console.log(JSON.stringify({ ok: false, reason: 'single-arm step ORDER changed: expected [' + EXPECT_STEPS + '] got [' + steps + ']' })); process.exit(0); }

// The agent-SPAWN order — every executor, worker, review and cost-seam call in
// the order the pre-split driver made them. This is the half a return-object
// assertion cannot see: an extra level-wide probe (the obvious way to detect a
// partially dual-built level) would land here and nowhere else.
const labels = callLog.map(c => c.opts.label).join(',');
const EXPECT_LABELS = [
  'prelude:k2080ctl',
  'worker-clock:k2080ctl#worker:k2080ctl',
  'worker:k2080ctl',
  'worker-usage:k2080ctl#worker:k2080ctl',
  'review-diff:k2080ctl',
  'gate-freshness:k2080ctl',
  'gate:k2080ctl',
  'pr-batch:k2080ctl',
  'ci-batch:k2080ctl#0',
].join(',');
if (labels !== EXPECT_LABELS)
  { console.log(JSON.stringify({ ok: false, reason: 'single-arm agent-spawn ORDER changed: expected [' + EXPECT_LABELS + '] got [' + labels + ']' })); process.exit(0); }

// …and the return object keeps its pre-#2080 shape: no dualBuild key at all.
if ('dualBuild' in result)
  { console.log(JSON.stringify({ ok: false, reason: 'a flag-less level must not carry a dualBuild key: ' + JSON.stringify(result.dualBuild) })); process.exit(0); }
if ((result.parked ?? []).length !== 1 || result.parked[0].pr !== 2080)
  { console.log(JSON.stringify({ ok: false, reason: 'control item did not park through the PR phase: ' + JSON.stringify(result.parked) })); process.exit(0); }
if ('dual_build' in result.parked[0] || 'awaiting_pick' in result.parked[0])
  { console.log(JSON.stringify({ ok: false, reason: 'a single-arm parked record must carry no dual-build fields: ' + JSON.stringify(result.parked[0]) })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ---------------------------------------------------------------------------
# The shared dual-build fixture helper, injected per case.
#
# The mock routes every agent call by the slug embedded in its label, and a
# dual-build arm's label carries the ARM KEY (`<slug>@<arm>`) — so an arm's
# machinery queue is registered under that key, and the ITEM-level calls that
# happen at/after the barrier (judge:<slug>, dual-build-rows:<slug>) share the
# plain-slug queue. The candidate arm's candidate-session gate is labelled
# `candidate-session:<slug>@candidate`, so it is the FIRST entry of the
# candidate arm's own queue.
# ---------------------------------------------------------------------------
read -r -d '' DUAL_FIXTURE << 'DUAL_FIXTURE_END' || true
globalThis.dualArgs = (slugs, extra) => ({
  ...baseArgs,
  dualBuild: { tier: 'sonnet', baseline: 'model-base', candidate: 'model-cand', inScope: slugs, ...(extra?.dualBuild ?? {}) },
  ...(extra ?? {}),
});
// A green arm: the candidate-session gate (candidate arm only), worktree
// create, the §3e review diff, and a passing acceptance gate.
globalThis.greenArm = (slug, arm, over) => {
  const created = { outcome: 'CREATED', path: '/tmp/repo.wt/' + slug + '@' + arm, base: 'base-' + slug, guard: 'ARMED', ...(over?.created ?? {}) };
  const gate = over?.gate ?? { outcome: 'GATE_PASS' };
  const head = arm === 'candidate' ? [{ outcome: 'CANDIDATE_READY' }] : [];
  setMachinery(slug + '@' + arm, ...head, created, { outcome: 'REVIEW_DIFF' }, gate);
  happyWorker(slug + '@' + arm);
};
// The post-barrier item-level queue: the pairwise judge, then one ledger-row
// append per arm.
globalThis.itemBarrier = (slug, judgeOut, rows) => setMachinery(slug,
  judgeOut ?? { outcome: 'JUDGED', judge: { preference: 'A', margin: 30, order_agreement: true } },
  ...(rows ?? [{ outcome: 'ROW_APPENDED', arm: 'baseline' }, { outcome: 'ROW_APPENDED', arm: 'candidate' }]),
);
// dualRows(slug) — the ledger row LITERALS this driver handed the executor,
// parsed back out of the emitted shell. The row is composed in .mjs and
// sq()-quoted into the command text, so this reads exactly what
// dual-build-ledger.sh would have received (modulo the three fields the shell
// itself fills — see the row writer's own comment). A plain index scan rather
// than a regex: the row is JSON with braces and quotes in it, which a lazy
// regex gets wrong the moment a row grows a nested object.
globalThis.dualRows = (slug, hint) => {
  const call = callLog.find(c => c.opts.label === 'dual-build-rows' + (hint ? '-' + hint : '') + ':' + slug);
  if (!call) return [];
  const text = call.promptFull;
  const open = "printf %s '";
  const close = "' | jq";
  const out = [];
  let i = 0;
  for (;;) {
    const a = text.indexOf(open, i);
    if (a < 0) break;
    const b = text.indexOf(close, a + open.length);
    if (b < 0) break;
    const raw = text.slice(a + open.length, b);
    i = b + close.length;
    if (raw.indexOf('{"tier') !== 0) continue;
    try { out.push(JSON.parse(raw.split("'\\''").join("'"))); } catch (e) { /* not a row literal */ }
  }
  return out;
};
globalThis.rowFor = (slug, arm) => dualRows(slug).find(r => r.arm === arm && r.in_scope !== false && r.pick == null) ?? null;
globalThis.notInScopeRow = (slug) => dualRows(slug).find(r => r.in_scope === false) ?? null;
// temperloop#2083 — phase 4 (the LEVEL PICK) runs after the barrier. With no
// calibration seam in a fixture, readCalibrationStatus() fails CLOSED, so the
// gate HOLDS the level and every in-scope item comes back as a `level-pick`
// escalation carrying the same `dual_build` record it used to park with. These
// two read through either disposition, so a K2080 case keeps asserting the
// BARRIER's own claims rather than accidentally asserting the pick's.
globalThis.dualRecordOf = (result, slug) => {
  const p = (result.parked ?? []).find(x => x.slug === slug);
  if (p && p.dual_build) return p.dual_build;
  const e = (result.escalations ?? []).find(x => x.slug === slug);
  return (e && e.payload && e.payload.dual_build) || null;
};
globalThis.disposedSlugs = (result) =>
  [...(result.parked ?? []).map(p => p.slug), ...(result.escalations ?? []).map(e => e.slug)].sort().join(',');
globalThis.heldForPick = (result) => (result.escalations ?? []).filter(e => e.kind === 'level-pick').map(e => e.slug).sort().join(',');
// Queue the level-pick phase's own machinery for a level that should ROUTE:
// one calibration read (level-wide), then per item the override pair (optional),
// the stamp, the loser archive and the pick row. Registered on the fixture's
// label-derived slug queues, same convention as itemBarrier above.
globalThis.calibrated = (over) => setMachinery('_level',
  { outcome: 'CALIBRATION', calibration: { n: 12, agreement_pct: 90, status: 'calibrated', bar_pct: 70, bar_n: 5, ...(over ?? {}) } });
globalThis.uncalibrated = (over) => setMachinery('_level',
  { outcome: 'CALIBRATION', calibration: { n: 1, agreement_pct: 0, status: 'uncalibrated', bar_pct: 70, bar_n: 5, ...(over ?? {}) } });
globalThis.pickRow = (slug) => dualRows(slug, 'pick').find(r => r.pick != null) ?? null;
// addMachinery — APPEND to a slug's queue (setMachinery replaces it). The pick
// phase's own steps (stamp-arms, archive-loser, the pick row) ride the ITEM's
// queue, after the barrier's judge + row appends, so a case composes them.
globalThis.addMachinery = (slug, ...o) => { machineryMap.set(slug, [...(machineryMap.get(slug) ?? []), ...o]); };
// winningArm — greenArm PLUS the PR-phase queue the level pick routes it
// through (3f rebase/scan/push/pr-open, then 3g CI). An arm queued with
// greenArm alone stops at its gate, which is exactly what a LOSING arm does.
globalThis.winningArm = (slug, arm, prNum, sha, over) => {
  const created = { outcome: 'CREATED', path: '/tmp/repo.wt/' + slug + '@' + arm, base: 'base-' + slug, guard: 'ARMED', ...(over?.created ?? {}) };
  const head = arm === 'candidate' ? [{ outcome: 'CANDIDATE_READY' }] : [];
  setMachinery(slug + '@' + arm, ...head, created, { outcome: 'REVIEW_DIFF' }, over?.gate ?? { outcome: 'GATE_PASS' },
    { outcome: 'REBASED', base: 'b', tip: 't', sha }, { outcome: 'SCAN_CLEAN' },
    { outcome: 'PUSHED', sha, branch: 'build/' + slug + '@' + arm }, { outcome: 'PR_OPENED', pr_number: prNum },
    ...(over?.ci ?? [{ outcome: 'CI_GREEN' }]));
  happyWorker(slug + '@' + arm);
};
// pickPhase — the per-item machinery the pick runs AFTER the barrier, in the
// order routePickedItem runs it: [calibrate-pair] → stamp-arms → archive-loser
// → the pick row.
globalThis.pickPhase = (slug, over) => addMachinery(slug,
  ...(over?.pair ? [over.pair] : []),
  over?.stamp ?? { outcome: 'ARMS_STAMPED', already: false },
  over?.loser ?? { outcome: 'LOSER_ARCHIVED', worktree_removed: true, branch_deleted: true },
  over?.pickRow ?? { outcome: 'ROW_APPENDED', arm: 'baseline' },
);
globalThis.pickOf = (result, slug) => (dualRecordOf(result, slug) || {}).pick ?? null;
DUAL_FIXTURE_END

# ---------------------------------------------------------------------------
# K2080: two arms, the barrier, and no PR
# ---------------------------------------------------------------------------
run_node_case "K2080 dual-build: an in-scope item builds two arms via 'worktree.sh create --arm', records start order, and the level barrier holds every gate before any judge and any PR" "
$PREAMBLE
$DUAL_FIXTURE

for (const s of ['d1','d2']) {
  greenArm(s, 'baseline'); greenArm(s, 'candidate');
  itemBarrier(s);
}

globalThis.args = { ...dualArgs(['d1','d2']), items: [
  { slug: 'd1', branch: 'build/d1', title: 'D1', kind: 'impl', acceptance: ['c'] },
  { slug: 'd2', branch: 'build/d2', title: 'D2', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();

// NO PR — for any item, at any point. This is the barrier's whole claim, and
// it is asserted on the SPAWN, not only on the steps: a PR phase that runs and
// fails on its first step records no push/pr-open step at all, so a step-only
// assertion would sit green through exactly the regression that matters.
const prPhase = callLog.filter(c => /^(pr-batch|ci-batch|pr-body-update):/.test(String(c.opts.label)));
if (prPhase.length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'the barrier let the PR phase run: ' + JSON.stringify(prPhase.map(c => c.opts.label)) })); process.exit(0); }
const prSteps = machineryStepLog.filter(s => s.kind === 'pr-open' || s.kind === 'push' || s.kind === 'ci-poll');
if (prSteps.length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'the barrier let a push/PR/CI step run: ' + JSON.stringify(prSteps) })); process.exit(0); }

// Two arms per item, each on its OWN arm-suffixed worktree and branch, created
// with the --arm flag naming its sibling.
for (const s of ['d1','d2']) {
  for (const arm of ['baseline','candidate']) {
    const pre = callLog.find(c => c.opts.label === 'prelude:' + s + '@' + arm);
    if (!pre)
      { console.log(JSON.stringify({ ok: false, reason: 'no prelude for arm ' + s + '@' + arm })); process.exit(0); }
    const sib = arm === 'baseline' ? 'candidate' : 'baseline';
    if (!pre.promptFull.includes(\"--arm '\" + arm + ':' + sib + \"'\"))
      { console.log(JSON.stringify({ ok: false, reason: s + '@' + arm + \" create carries no --arm '\" + arm + ':' + sib + \"': \" + pre.promptFull.slice(0, 400) })); process.exit(0); }
    if (!pre.promptFull.includes(\"create '/tmp/repo' '\" + s + \"' --arm\"))
      { console.log(JSON.stringify({ ok: false, reason: s + '@' + arm + ' create must name the REAL slug, not the arm key: ' + pre.promptFull.slice(0, 400) })); process.exit(0); }
  }
}

// THE BARRIER, read off the spawn order: every gate call in the level precedes
// every judge call. A per-item barrier (judge d1 while d2 still builds) passes
// every other assertion here and fails this one.
const order = callLog.map(c => String(c.opts.label));
const lastGate = order.reduce((n, l, i) => (/^gate:/.test(l) ? i : n), -1);
const firstJudge = order.findIndex(l => /^judge:/.test(l));
if (lastGate < 0 || firstJudge < 0)
  { console.log(JSON.stringify({ ok: false, reason: 'expected both gate and judge calls: ' + JSON.stringify(order) })); process.exit(0); }
if (firstJudge < lastGate)
  { console.log(JSON.stringify({ ok: false, reason: 'a judge ran BEFORE the level finished gating — that is a per-item barrier, not the level barrier: ' + JSON.stringify(order) })); process.exit(0); }

// Start order recorded, per arm, baseline first. (temperloop#2083: with no
// calibration seam the level-pick gate fails closed and HOLDS, so the item's
// record rides the level-pick escalation rather than a parked record — the
// barrier's own claims below are identical either way.)
const d1 = dualRecordOf(result, 'd1');
if (!d1)
  { console.log(JSON.stringify({ ok: false, reason: 'd1 produced no dual_build record: ' + JSON.stringify(result) })); process.exit(0); }
if (heldForPick(result) !== 'd1,d2')
  { console.log(JSON.stringify({ ok: false, reason: 'an uncalibrated level must HOLD every in-scope item for the pick: ' + JSON.stringify(result.escalations) })); process.exit(0); }
const orders = d1.arms.map(a => a.arm + ':' + a.start_order).join(',');
if (orders !== 'baseline:1,candidate:2')
  { console.log(JSON.stringify({ ok: false, reason: 'start order not recorded per arm: ' + orders })); process.exit(0); }
if (d1.barrier !== 'held' || d1.awaiting !== 'level-pick')
  { console.log(JSON.stringify({ ok: false, reason: 'barrier state missing: ' + JSON.stringify(d1) })); process.exit(0); }
if (!d1.judge || d1.judge.order_agreement !== true)
  { console.log(JSON.stringify({ ok: false, reason: 'judge result missing from the item record: ' + JSON.stringify(d1) })); process.exit(0); }
if (result.dualBuild.in_scope.join(',') !== 'd1,d2' || result.dualBuild.barrier !== 'held')
  { console.log(JSON.stringify({ ok: false, reason: 'level summary wrong: ' + JSON.stringify(result.dualBuild) })); process.exit(0); }

// …and the barriered level is NOT a zero-disposition contradiction: it disposed
// of both items, it just disposed of them as parked-awaiting-pick.
if (result.zeroDisposition)
  { console.log(JSON.stringify({ ok: false, reason: 'a barriered level was flagged zero-disposition: ' + JSON.stringify(result.zeroDisposition) })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ---------------------------------------------------------------------------
# K2080: the ledger row's own content
# ---------------------------------------------------------------------------
run_node_case "K2080 rows: one row per item per arm carrying cost, loss_reason, guard_armed and start_order, with cross_read_attempted read from the guard's attempt marker" "
$PREAMBLE
$DUAL_FIXTURE

greenArm('r1', 'baseline'); greenArm('r1', 'candidate');
// The judge prefers arm A (baseline) — so the CANDIDATE arm's row carries the
// per-item judge loss, and the baseline arm's carries none.
itemBarrier('r1', { outcome: 'JUDGED', judge: { preference: 'A', margin: 40, order_agreement: true } });

globalThis.args = { ...dualArgs(['r1']), items: [
  { slug: 'r1', branch: 'build/r1', title: 'R1', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();

const base = rowFor('r1', 'baseline');
const cand = rowFor('r1', 'candidate');
if (!base || !cand)
  { console.log(JSON.stringify({ ok: false, reason: 'expected one row per arm; got ' + JSON.stringify({ base, cand }) })); process.exit(0); }
if (base.slug !== 'r1' || base.arm !== 'baseline' || base.tier !== 'sonnet' || base.model !== 'model-base')
  { console.log(JSON.stringify({ ok: false, reason: 'baseline row identity wrong: ' + JSON.stringify(base) })); process.exit(0); }
if (cand.model !== 'model-cand' || cand.start_order !== 2 || base.start_order !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'row model/start_order wrong: ' + JSON.stringify({ base, cand }) })); process.exit(0); }
if (base.gate !== 'pass' || cand.gate !== 'pass')
  { console.log(JSON.stringify({ ok: false, reason: 'gate result missing from rows: ' + JSON.stringify({ base, cand }) })); process.exit(0); }
if (base.guard_armed !== 'ARMED' || cand.guard_armed !== 'ARMED')
  { console.log(JSON.stringify({ ok: false, reason: 'guard_armed not taken from the CREATED line: ' + JSON.stringify({ base, cand }) })); process.exit(0); }
for (const k of ['tokens_in','tokens_out','wall_clock_ms','retry_tokens','retry_count','recovery']) {
  if (!(k in base.cost))
    { console.log(JSON.stringify({ ok: false, reason: 'row cost missing ' + k + ': ' + JSON.stringify(base.cost) })); process.exit(0); }
}
if (base.loss_reason !== null)
  { console.log(JSON.stringify({ ok: false, reason: 'the JUDGE-PREFERRED arm must carry no loss: ' + JSON.stringify(base) })); process.exit(0); }
if (cand.loss_reason !== 'judge')
  { console.log(JSON.stringify({ ok: false, reason: 'the arm the judge did not prefer must lose on judge: ' + JSON.stringify(cand) })); process.exit(0); }
if (!base.judge || base.judge.margin !== 40 || base.pick !== null || base.override.applied !== false)
  { console.log(JSON.stringify({ ok: false, reason: 'row judge/pick/override wrong: ' + JSON.stringify(base) })); process.exit(0); }

// cross_read_attempted is READ FROM THE ARM'S WORKTREE by the emitted shell —
// the guard's own attempt marker — and overwrites the literal placeholder. The
// row literal alone cannot carry it, so the assertion is on the emitted
// command: the marker path, the -s test, and the jq that injects the reading.
const cmd = callLog.find(c => c.opts.label === 'dual-build-rows:r1').promptFull;
if (!cmd.includes('.dual-build-cross-read-attempts.jsonl'))
  { console.log(JSON.stringify({ ok: false, reason: \"the row writer never reads the guard's attempt marker\" })); process.exit(0); }
if (!cmd.includes('/tmp/repo.wt/r1@candidate/.dual-build-cross-read-attempts.jsonl'))
  { console.log(JSON.stringify({ ok: false, reason: \"the attempt marker must be read from the ARM'S OWN worktree\" })); process.exit(0); }
if (!/cross_read_attempted=\\\$ca/.test(cmd))
  { console.log(JSON.stringify({ ok: false, reason: 'the reading is never injected into the row: ' + cmd.slice(0, 600) })); process.exit(0); }
if (!/head_sha=\\\$hs/.test(cmd) || !/machinery_version=\\\$mv/.test(cmd))
  { console.log(JSON.stringify({ ok: false, reason: 'head_sha/machinery_version are never resolved from the worktree' })); process.exit(0); }
if (result.dualBuild.rows_appended !== 2 || result.dualBuild.rows_rejected !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'row tally wrong: ' + JSON.stringify(result.dualBuild) })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ---------------------------------------------------------------------------
# K2080: a not-in-scope item on a dual-build level
# ---------------------------------------------------------------------------
run_node_case "K2080 not-in-scope: an item outside the tier is built ONCE through the ordinary single-arm path (PR and all) and gets one not-in-scope row" "
$PREAMBLE
$DUAL_FIXTURE

greenArm('n1', 'baseline'); greenArm('n1', 'candidate');
itemBarrier('n1');

// The out-of-scope item takes the UNCHANGED single-arm queue, and its own
// post-barrier queue holds exactly one row append.
happyMachinery('n2', 909, 'ab909');
happyWorker('n2');

globalThis.args = { ...dualArgs(['n1']), items: [
  { slug: 'n1', branch: 'build/n1', title: 'N1', kind: 'impl', acceptance: ['c'] },
  { slug: 'n2', branch: 'build/n2', title: 'N2', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();

const n2 = (result.parked ?? []).find(p => p.slug === 'n2');
if (!n2 || n2.pr !== 909 || n2.pushed_sha !== 'ab909')
  { console.log(JSON.stringify({ ok: false, reason: 'the not-in-scope item did not take the ordinary PR path: ' + JSON.stringify(result.parked) })); process.exit(0); }
if ('dual_build' in n2)
  { console.log(JSON.stringify({ ok: false, reason: 'a not-in-scope item must carry no dual_build record: ' + JSON.stringify(n2) })); process.exit(0); }
// Built ONCE: no arm worktrees for it anywhere.
if (machineryStepLog.some(s => String(s.slug).startsWith('n2@')))
  { console.log(JSON.stringify({ ok: false, reason: 'the not-in-scope item was built under an arm: ' + JSON.stringify(machineryStepLog) })); process.exit(0); }
const row = notInScopeRow('n2');
if (!row || row.in_scope !== false)
  { console.log(JSON.stringify({ ok: false, reason: 'no not-in-scope row was written: ' + JSON.stringify(row) })); process.exit(0); }
if (row.slug !== 'n2' || row.arm !== 'baseline' || row.gate !== 'pass')
  { console.log(JSON.stringify({ ok: false, reason: 'not-in-scope row shape wrong: ' + JSON.stringify(row) })); process.exit(0); }
if (result.dualBuild.not_in_scope.join(',') !== 'n2')
  { console.log(JSON.stringify({ ok: false, reason: 'level summary must name the not-in-scope set: ' + JSON.stringify(result.dualBuild) })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ---------------------------------------------------------------------------
# K2080: board writes are buffered until after the pick
# ---------------------------------------------------------------------------
run_node_case "K2080 board: an in-scope item's claim is BUFFERED (no claim step runs) while a not-in-scope item on the same level claims normally" "
$PREAMBLE
$DUAL_FIXTURE

greenArm('b1', 'baseline'); greenArm('b1', 'candidate');
itemBarrier('b1');
setMachinery('b2',
  { outcome: 'CLAIMED' },
  { outcome: 'CREATED', path: '/tmp/repo.wt/b2' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'b222' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'b222', branch: 'build/b2' },
  { outcome: 'PR_OPENED', pr_number: 222 },
  { outcome: 'CI_GREEN' },
  { outcome: 'ROW_APPENDED', arm: 'baseline' },
);
happyWorker('b2');

globalThis.args = { ...dualArgs(['b1']), board: 4, claimCmd: '/x/claim.sh', items: [
  { slug: 'b1', branch: 'build/b1', title: 'B1', kind: 'impl', acceptance: ['c'], ghIssue: 101 },
  { slug: 'b2', branch: 'build/b2', title: 'B2', kind: 'impl', acceptance: ['c'], ghIssue: 102 },
]};

const mod = await loadLevel();
const result = await mod.default();

const claims = machineryStepLog.filter(s => s.kind === 'claim');
if (claims.length !== 1 || claims[0].slug !== 'b2')
  { console.log(JSON.stringify({ ok: false, reason: 'exactly the not-in-scope item may claim; got ' + JSON.stringify(claims) })); process.exit(0); }
const bw = result.dualBuild.board_writes ?? [];
if (bw.length !== 1 || bw[0].slug !== 'b1' || bw[0].issue !== 101)
  { console.log(JSON.stringify({ ok: false, reason: \"the in-scope item's board write was not buffered: \" + JSON.stringify(bw) })); process.exit(0); }
if (!String(bw[0].cmd).includes('/x/claim.sh 101 --board 4'))
  { console.log(JSON.stringify({ ok: false, reason: 'the buffered write must carry the exact command to run after the pick: ' + JSON.stringify(bw[0]) })); process.exit(0); }
if (bw[0].buffered_until !== 'level-pick')
  { console.log(JSON.stringify({ ok: false, reason: 'the buffer must say when it is flushed: ' + JSON.stringify(bw[0]) })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ---------------------------------------------------------------------------
# K2080: the three per-arm loss reasons
# ---------------------------------------------------------------------------
run_node_case "K2080 losses: a gate-failed arm records loss_reason gate; an infra failure records infra; neither escalates across the driveItem boundary and the judge reports one-arm-only" "
$PREAMBLE
$DUAL_FIXTURE

// g1: the CANDIDATE arm's acceptance gate goes RED.
greenArm('g1', 'baseline');
greenArm('g1', 'candidate', { gate: { outcome: 'GATE_FAIL', failed: 2 } });
itemBarrier('g1', { outcome: 'JUDGE_UNAVAILABLE', reason: 'never-called' }, [
  { outcome: 'ROW_APPENDED', arm: 'baseline' }, { outcome: 'ROW_APPENDED', arm: 'candidate' },
]);

// f1: the CANDIDATE arm's worktree create fails outright — machinery, not the
// model. That must never read as a quality signal.
greenArm('f1', 'baseline');
setMachinery('f1@candidate',
  { outcome: 'CANDIDATE_READY' },
  { outcome: 'ERROR', error: 'worktree add refused' },
);
itemBarrier('f1', { outcome: 'JUDGE_UNAVAILABLE', reason: 'never-called' }, [
  { outcome: 'ROW_APPENDED', arm: 'baseline' }, { outcome: 'ROW_APPENDED', arm: 'candidate' },
]);

globalThis.args = { ...dualArgs(['g1','f1']), items: [
  { slug: 'g1', branch: 'build/g1', title: 'G1', kind: 'impl', acceptance: ['c'] },
  { slug: 'f1', branch: 'build/f1', title: 'F1', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();

// A per-arm failure is a ROW, never an escalation OF ITS OWN. (The level-pick
// hold is a different, level-scoped escalation — filtered out here so this case
// keeps asserting the driveItem-boundary property it was written for.)
const armEsc = (result.escalations ?? []).filter(e => e.kind !== 'level-pick');
if (armEsc.length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'a per-arm failure escalated across the driveItem boundary: ' + JSON.stringify(armEsc) })); process.exit(0); }

const gcand = dualRecordOf(result, 'g1').arms.find(a => a.arm === 'candidate');
if (gcand.gate !== 'fail' || gcand.loss_reason !== 'gate')
  { console.log(JSON.stringify({ ok: false, reason: 'a gate-failed arm must be a gate loss: ' + JSON.stringify(gcand) })); process.exit(0); }
if (rowFor('g1', 'candidate').loss_reason !== 'gate')
  { console.log(JSON.stringify({ ok: false, reason: 'the gate loss never reached the row: ' + JSON.stringify(rowFor('g1','candidate')) })); process.exit(0); }
if (dualRecordOf(result, 'g1').judge !== null || dualRecordOf(result, 'g1').judge_unavailable_reason !== 'one-arm-only')
  { console.log(JSON.stringify({ ok: false, reason: 'with one arm down the judge must report one-arm-only, never a verdict: ' + JSON.stringify(dualRecordOf(result, 'g1')) })); process.exit(0); }
if (callLog.some(c => String(c.opts.label) === 'judge:g1'))
  { console.log(JSON.stringify({ ok: false, reason: 'the judge was spent on a pair that cannot be compared' })); process.exit(0); }

const fcand = dualRecordOf(result, 'f1').arms.find(a => a.arm === 'candidate');
if (fcand.loss_reason !== 'infra')
  { console.log(JSON.stringify({ ok: false, reason: 'a machinery failure must be an infra loss, never gate: ' + JSON.stringify(fcand) })); process.exit(0); }
if (rowFor('f1', 'candidate').loss_reason !== 'infra')
  { console.log(JSON.stringify({ ok: false, reason: 'the infra loss never reached the row: ' + JSON.stringify(rowFor('f1','candidate')) })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ---------------------------------------------------------------------------
# K2080: both arms down
# ---------------------------------------------------------------------------
run_node_case "K2080 both arms down: an item with no gate-passing arm ESCALATES (there is nothing for a pick to choose between) rather than parking as if it were comparable" "
$PREAMBLE
$DUAL_FIXTURE

greenArm('z1', 'baseline', { gate: { outcome: 'GATE_FAIL', failed: 1 } });
greenArm('z1', 'candidate', { gate: { outcome: 'GATE_FAIL', failed: 3 } });
itemBarrier('z1', { outcome: 'JUDGE_UNAVAILABLE', reason: 'never-called' });

globalThis.args = { ...dualArgs(['z1']), items: [
  { slug: 'z1', branch: 'build/z1', title: 'Z1', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();

const esc = (result.escalations ?? []).find(e => e.slug === 'z1');
if (!esc || esc.kind !== 'dual-build-arms-failed')
  { console.log(JSON.stringify({ ok: false, reason: 'expected a dual-build-arms-failed escalation: ' + JSON.stringify(result) })); process.exit(0); }
if (!esc.payload.dual_build || esc.payload.dual_build.arms.length !== 2)
  { console.log(JSON.stringify({ ok: false, reason: 'the escalation must carry both arms: ' + JSON.stringify(esc.payload) })); process.exit(0); }
if ((result.parked ?? []).length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'an item with no passing arm must not also park: ' + JSON.stringify(result.parked) })); process.exit(0); }
if (result.zeroDisposition)
  { console.log(JSON.stringify({ ok: false, reason: 'an escalating dual-build level is disposed of, not a contradiction: ' + JSON.stringify(result.zeroDisposition) })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ---------------------------------------------------------------------------
# K2080 round-1 review [MEDIUM]: a spike arm's park is a SUCCESS, not a loss
# ---------------------------------------------------------------------------
run_node_case "K2080 spike arms: an in-scope kind:spike item's read-only verdict park is recorded as a PASSING arm (never a gate:fail infra loss), and the pairwise judge is not spent on a pair with no diffs" "
$PREAMBLE
$DUAL_FIXTURE

// A spike skips 3b-3h entirely: no worktree, no review diff, no gate. With the
// board OFF its prelude is EMPTY, so the baseline arm makes no machinery call at
// all and the candidate arm's only one is the candidate-session seam.
setMachinery('sp1@candidate', { outcome: 'CANDIDATE_READY' });
happyWorker('sp1@baseline');
happyWorker('sp1@candidate');
// The item-level queue is the ledger rows ALONE — a spike pair must never reach
// the judge, so no JUDGED entry is queued for it.
setMachinery('sp1', { outcome: 'ROW_APPENDED', arm: 'baseline' }, { outcome: 'ROW_APPENDED', arm: 'candidate' });

globalThis.args = { ...dualArgs(['sp1']), items: [
  { slug: 'sp1', branch: 'build/sp1', title: 'SP1', kind: 'spike', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();

if ((result.escalations ?? []).length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'two completed spike arms must not escalate: ' + JSON.stringify(result.escalations) })); process.exit(0); }
const sp = dualRecordOf(result, 'sp1');
if (!sp)
  { console.log(JSON.stringify({ ok: false, reason: 'the spike item produced no dual_build record: ' + JSON.stringify(result) })); process.exit(0); }
const bad = sp.arms.filter(a => a.gate !== 'pass' || a.loss_reason !== null);
if (bad.length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: \"a spike's successful park was recorded as an arm loss: \" + JSON.stringify(bad) })); process.exit(0); }
if (sp.judge !== null || sp.judge_unavailable_reason !== 'spike-arm')
  { console.log(JSON.stringify({ ok: false, reason: 'a spike pair must get the named spike-arm disposition, never a verdict: ' + JSON.stringify(sp) })); process.exit(0); }
if (callLog.some(c => String(c.opts.label ?? '').indexOf('judge:') === 0))
  { console.log(JSON.stringify({ ok: false, reason: 'the pairwise judge was spent on a pair that produces no diffs' })); process.exit(0); }
const rb = rowFor('sp1', 'baseline');
const rc = rowFor('sp1', 'candidate');
if (!rb || !rc || rb.gate !== 'pass' || rc.gate !== 'pass' || rb.loss_reason !== null || rc.loss_reason !== null)
  { console.log(JSON.stringify({ ok: false, reason: 'the ledger recorded a completed spike arm as a loss: ' + JSON.stringify([rb, rc]) })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ---------------------------------------------------------------------------
# K2080 round-1 review [HIGH]: no item is silently lost to an uncaught throw
# ---------------------------------------------------------------------------
# parallel() drops a REJECTED thunk to null and buildLevel's consuming loop then
# skips it ('if (!r) continue'), so an item whose in-scope drive throws lands in
# NEITHER parked NOR escalations — the temperloop#437 silent-loss defect. The
# single-arm fan-out was hardened against it; these two cases hold the dual-build
# fan-outs to the same invariant, one per phase.
# ---------------------------------------------------------------------------
run_node_case "K2080 no silent loss (build phase): an in-scope item whose drive THROWS surfaces as an escalation, and its healthy sibling still completes" "
$PREAMBLE
$DUAL_FIXTURE

greenArm('t2', 'baseline');
greenArm('t2', 'candidate');
itemBarrier('t2');

// Blow up the ARM fan-out of the first in-scope item, inside driveInScopeItem
// but OUTSIDE the per-arm catch — the exact region the item fan-out's own guard
// has to cover. Call 1 is the item fan-out; call 2 is t1's arm fan-out.
const realParallel = globalThis.parallel;
let outerSeen = false;
let blown = false;
globalThis.parallel = async (fns) => {
  if (!outerSeen) { outerSeen = true; return realParallel(fns); }
  if (!blown) { blown = true; throw new Error('boom: the arm fan-out substrate failed for t1'); }
  return realParallel(fns);
};

globalThis.args = { ...dualArgs(['t1','t2']), items: [
  { slug: 't1', branch: 'build/t1', title: 'T1', kind: 'impl', acceptance: ['c'] },
  { slug: 't2', branch: 'build/t2', title: 'T2', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();

const esc = (result.escalations ?? []).find(e => e.slug === 't1');
if (!esc || esc.kind !== 'worker-error')
  { console.log(JSON.stringify({ ok: false, reason: 'a thrown in-scope item must surface as a worker-error escalation: ' + JSON.stringify(result) })); process.exit(0); }
if (!dualRecordOf(result, 't2'))
  { console.log(JSON.stringify({ ok: false, reason: 'one item throwing took its healthy sibling down with it: ' + JSON.stringify(result) })); process.exit(0); }
const seen = disposedSlugs(result);
if (seen !== 't1,t2')
  { console.log(JSON.stringify({ ok: false, reason: 'an item was silently lost — disposed set was: ' + seen })); process.exit(0); }
if (result.zeroDisposition)
  { console.log(JSON.stringify({ ok: false, reason: 'a level that disposed of both items reported a zero-disposition contradiction' })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

run_node_case "K2080 no silent loss (judge/record phase): an in-scope item whose post-barrier judge THROWS surfaces as an escalation, and its healthy sibling still parks" "
$PREAMBLE
$DUAL_FIXTURE

greenArm('j1', 'baseline');
greenArm('j1', 'candidate');
greenArm('j2', 'baseline');
greenArm('j2', 'candidate');
itemBarrier('j2');

// The judge seam throws for j1 ONLY, past the barrier — after both its arms
// already built. machineryAgent() re-throws anything that is not an agent-type
// resolution failure, so this reaches driveLevelDualBuild's phase-3 thunk.
const realAgent = globalThis.agent;
globalThis.agent = async (prompt, opts = {}) => {
  if (String(opts.label ?? '') === 'judge:j1') throw new Error('boom: the judge seam blew up');
  return realAgent(prompt, opts);
};

globalThis.args = { ...dualArgs(['j1','j2']), items: [
  { slug: 'j1', branch: 'build/j1', title: 'J1', kind: 'impl', acceptance: ['c'] },
  { slug: 'j2', branch: 'build/j2', title: 'J2', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();

const esc = (result.escalations ?? []).find(e => e.slug === 'j1');
if (!esc || esc.kind !== 'worker-error')
  { console.log(JSON.stringify({ ok: false, reason: 'a throw past the barrier must surface as a worker-error escalation: ' + JSON.stringify(result) })); process.exit(0); }
if (!dualRecordOf(result, 'j2'))
  { console.log(JSON.stringify({ ok: false, reason: 'the healthy sibling was lost: ' + JSON.stringify(result) })); process.exit(0); }
const seen2 = disposedSlugs(result);
if (seen2 !== 'j1,j2')
  { console.log(JSON.stringify({ ok: false, reason: 'an item was silently lost past the barrier — disposed set was: ' + seen2 })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ---------------------------------------------------------------------------
# K2080: the two-arm sideline notice
# ---------------------------------------------------------------------------
run_node_case "K2080 sideline: when BOTH arms of one item sideline a resumable build, the level rollup keeps BOTH notices, named by arm" "
$PREAMBLE
$DUAL_FIXTURE

greenArm('s2', 'baseline', { created: { outcome: 'CREATED', path: '/tmp/repo.wt/s2@baseline', base: 'base-s2', guard: 'ARMED', sidelined: true, sidelined_path: '/tmp/repo.wt/s2@baseline.unpreserved-aaa', sidelined_branch: 'build/s2@baseline.unpreserved-aaa' } });
greenArm('s2', 'candidate', { created: { outcome: 'CREATED', path: '/tmp/repo.wt/s2@candidate', base: 'base-s2', guard: 'ARMED', sidelined: true, sidelined_path: '/tmp/repo.wt/s2@candidate.unpreserved-bbb', sidelined_branch: 'build/s2@candidate.unpreserved-bbb' } });
itemBarrier('s2');

globalThis.args = { ...dualArgs(['s2']), items: [
  { slug: 's2', branch: 'build/s2', title: 'S2', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();

const sl = result.sidelined ?? [];
if (sl.length !== 2)
  { console.log(JSON.stringify({ ok: false, reason: 'both arms sidelined but the rollup kept ' + sl.length + ': ' + JSON.stringify(sl) })); process.exit(0); }
if (sl.map(s => s.arm).join(',') !== 'baseline,candidate')
  { console.log(JSON.stringify({ ok: false, reason: 'each notice must name its arm: ' + JSON.stringify(sl) })); process.exit(0); }
if (sl[0].path !== '/tmp/repo.wt/s2@baseline.unpreserved-aaa' || sl[1].path !== '/tmp/repo.wt/s2@candidate.unpreserved-bbb')
  { console.log(JSON.stringify({ ok: false, reason: 'the two notices collapsed onto one path: ' + JSON.stringify(sl) })); process.exit(0); }
if (!sl[0].recovery || !sl[1].recovery)
  { console.log(JSON.stringify({ ok: false, reason: 'each notice must carry its own recovery command: ' + JSON.stringify(sl) })); process.exit(0); }
const armNotices = dualRecordOf(result, 's2').arms.map(a => (a.sidelined ? a.arm : null)).filter(Boolean).join(',');
if (armNotices !== 'baseline,candidate')
  { console.log(JSON.stringify({ ok: false, reason: \"each arm's own summary must carry its notice: \" + JSON.stringify(dualRecordOf(result, 's2').arms) })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ---------------------------------------------------------------------------
# K2080: the flag-less resume refusal
# ---------------------------------------------------------------------------
run_node_case "K2080 flag-less resume: a level left PARTIALLY DUAL-BUILT refuses legibly under its own kind — never a silent single-arm completion, never a worktree-failed" "
$PREAMBLE

setMachinery('res1', { outcome: 'DUAL_BUILD_RESIDUE', arms: '/tmp/repo.wt/res1@baseline /tmp/repo.wt/res1@candidate ' });
happyWorker('res1');

globalThis.args = { ...baseArgs, items: [
  { slug: 'res1', branch: 'build/res1', title: 'Res1', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();

const esc = (result.escalations ?? []).find(e => e.slug === 'res1');
if (!esc || esc.kind !== 'dual-build-residue')
  { console.log(JSON.stringify({ ok: false, reason: 'expected a dual-build-residue refusal: ' + JSON.stringify(result) })); process.exit(0); }
if (!/PARTIALLY DUAL-BUILT/.test(String(esc.payload.reason)))
  { console.log(JSON.stringify({ ok: false, reason: 'the refusal must SAY what it found: ' + JSON.stringify(esc.payload) })); process.exit(0); }
if (!/--dual-build/.test(String(esc.payload.remedy)) || !/worktree.sh remove/.test(String(esc.payload.remedy)))
  { console.log(JSON.stringify({ ok: false, reason: 'the refusal must name BOTH ways out: ' + JSON.stringify(esc.payload) })); process.exit(0); }
if (esc.payload.arms !== '/tmp/repo.wt/res1@baseline /tmp/repo.wt/res1@candidate ')
  { console.log(JSON.stringify({ ok: false, reason: 'the refusal must carry the arms it found: ' + JSON.stringify(esc.payload) })); process.exit(0); }
// Nothing was built, pushed or PR'd past the refusal.
if (callLog.some(c => /^worker:/.test(String(c.opts.label))))
  { console.log(JSON.stringify({ ok: false, reason: 'a worker was spawned past the refusal' })); process.exit(0); }
if (machineryStepLog.some(s => s.kind === 'pr-open' || s.kind === 'push'))
  { console.log(JSON.stringify({ ok: false, reason: 'the refusal did not stop the pipeline: ' + JSON.stringify(machineryStepLog) })); process.exit(0); }

// The DETECTION is emitted inside the create step itself — the property that
// keeps the flag-less transcript unchanged. If it ever becomes a probe step of
// its own, the control case above goes red and so does this.
const pre = callLog.find(c => c.opts.label === 'prelude:res1').promptFull;
if (!pre.includes('DUAL_BUILD_RESIDUE') || !pre.includes(\"ls -d '/tmp/repo.wt/res1@'*\"))
  { console.log(JSON.stringify({ ok: false, reason: 'the residue check is not folded into the create step: ' + pre.slice(0, 600) })); process.exit(0); }
if (!pre.includes('Steps: worktree'))
  { console.log(JSON.stringify({ ok: false, reason: 'the residue check added a step to the prelude: ' + pre.slice(0, 200) })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ---------------------------------------------------------------------------
# K2080: the arm's model, and the retry that must stay on it
# ---------------------------------------------------------------------------
run_node_case "K2080 arm model: each arm's worker spawns on its OWN model, and a no-verdict retry re-spawns on that SAME model — never escalating to the other arm's tier" "
$PREAMBLE
$DUAL_FIXTURE

// The candidate arm's first worker returns nothing, then succeeds on the
// #1219 foreground-cure retry.
setMachinery('m1@baseline',
  { outcome: 'CREATED', path: '/tmp/repo.wt/m1@baseline', base: 'base-m1', guard: 'ARMED' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
);
happyWorker('m1@baseline');
setMachinery('m1@candidate',
  { outcome: 'CANDIDATE_READY' },
  { outcome: 'CREATED', path: '/tmp/repo.wt/m1@candidate', base: 'base-m1', guard: 'ARMED' },
  { outcome: 'RECOVER_NONE', commits_ahead: 0, pushed: false, dirty: false, dirty_files: 0, verification_surface_present: false },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
);
setWorker('m1@candidate',
  null,
  { status: 'done', summary: 'retried', acceptance_results: [{ criterion: 'c', passed: true, evidence: 'e' }], commits: [] },
);
itemBarrier('m1');

globalThis.args = { ...dualArgs(['m1']), items: [
  { slug: 'm1', branch: 'build/m1', title: 'M1', kind: 'impl', acceptance: ['c'], model: 'plan-item-model' },
]};

const mod = await loadLevel();
const result = await mod.default();

const workerCalls = callLog.filter(c => isWorkerCall(c.opts));
const byLabel = Object.fromEntries(workerCalls.map(c => [c.opts.label, c.opts.model]));
if (byLabel['worker:m1@baseline'] !== 'model-base')
  { console.log(JSON.stringify({ ok: false, reason: 'the baseline arm did not spawn on the baseline model: ' + JSON.stringify(byLabel) })); process.exit(0); }
if (byLabel['worker:m1@candidate'] !== 'model-cand')
  { console.log(JSON.stringify({ ok: false, reason: 'the candidate arm did not spawn on the candidate model: ' + JSON.stringify(byLabel) })); process.exit(0); }
if (byLabel['worker:m1@candidate#retry'] !== 'model-cand')
  { console.log(JSON.stringify({ ok: false, reason: \"the retry left the arm's own model: \" + JSON.stringify(byLabel) })); process.exit(0); }
if (workerCalls.some(c => c.opts.model === 'plan-item-model'))
  { console.log(JSON.stringify({ ok: false, reason: \"an arm inherited the plan item's model instead of its arm model\" })); process.exit(0); }
if (disposedSlugs(result) !== 'm1' || !dualRecordOf(result, 'm1'))
  { console.log(JSON.stringify({ ok: false, reason: 'the retried arm did not complete: ' + JSON.stringify(result) })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ---------------------------------------------------------------------------
# K2080: the candidate-session seam
# ---------------------------------------------------------------------------
run_node_case "K2080 candidate-session: every candidate arm passes the containment+preflight seam first, and a refusal is an infra loss — never an uncontained spawn" "
$PREAMBLE
$DUAL_FIXTURE

greenArm('c1', 'baseline');
setMachinery('c1@candidate', { outcome: 'CANDIDATE_REFUSED', reason: 'preflight-failed', detail: 'key unset' });
itemBarrier('c1', { outcome: 'JUDGE_UNAVAILABLE', reason: 'never-called' });

globalThis.args = { ...dualArgs(['c1']), items: [
  { slug: 'c1', branch: 'build/c1', title: 'C1', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();

const gateCall = callLog.find(c => c.opts.label === 'candidate-session:c1@candidate');
if (!gateCall)
  { console.log(JSON.stringify({ ok: false, reason: 'the candidate arm never consulted candidate-session.sh' })); process.exit(0); }
if (!gateCall.promptFull.includes('candidate-session.sh') || !gateCall.promptFull.includes('resolve Read') || !gateCall.promptFull.includes('preflight'))
  { console.log(JSON.stringify({ ok: false, reason: 'the seam must check BOTH containment and the credential: ' + gateCall.promptFull.slice(0, 500) })); process.exit(0); }
// A refused candidate never builds.
if (callLog.some(c => String(c.opts.label) === 'worker:c1@candidate'))
  { console.log(JSON.stringify({ ok: false, reason: 'a refused candidate arm spawned a worker anyway' })); process.exit(0); }
const cand = dualRecordOf(result, 'c1').arms.find(a => a.arm === 'candidate');
if (cand.loss_reason !== 'infra' || !/candidate-session/.test(String(cand.failure.kind)))
  { console.log(JSON.stringify({ ok: false, reason: 'a seam refusal must be a named infra loss: ' + JSON.stringify(cand) })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ---------------------------------------------------------------------------
# K2080: a malformed dualBuild input
# ---------------------------------------------------------------------------
run_node_case "K2080 input: a present-but-unusable dualBuild REFUSES the level rather than silently degrading to a single-arm build" "
$PREAMBLE

globalThis.args = { ...baseArgs, dualBuild: { tier: 'sonnet', baseline: 'b' }, items: [
  { slug: 'bad1', branch: 'build/bad1', title: 'Bad', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();

const esc = (result.escalations ?? []).find(e => e.slug === 'bad1');
if (!esc || esc.kind !== 'dual-build-input-invalid')
  { console.log(JSON.stringify({ ok: false, reason: 'expected a dual-build-input-invalid refusal: ' + JSON.stringify(result) })); process.exit(0); }
if (!/candidate/.test(String(esc.payload.reason)) || !/inScope/.test(String(esc.payload.reason)))
  { console.log(JSON.stringify({ ok: false, reason: 'the refusal must name WHAT is missing: ' + JSON.stringify(esc.payload) })); process.exit(0); }
if (callLog.length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'a refused level must spawn nothing: ' + JSON.stringify(callLog.map(c => c.opts.label)) })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

run_node_case "K2080 input: a PRESENT-BUT-EMPTY inScope REFUSES the level (an empty array is not a valid comparison set)" "
$PREAMBLE

// Two shapes reach the same state: an explicitly empty array, and an array whose
// every entry is scrubbed away by the map(str).filter(Boolean) normalisation.
globalThis.args = { ...baseArgs, dualBuild: { tier: 'sonnet', baseline: 'b', candidate: 'c', inScope: [] }, items: [
  { slug: 'e1', branch: 'build/e1', title: 'Empty', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();

const esc = (result.escalations ?? []).find(e => e.slug === 'e1');
if (!esc || esc.kind !== 'dual-build-input-invalid')
  { console.log(JSON.stringify({ ok: false, reason: 'an empty inScope must REFUSE, not silently run single-arm: ' + JSON.stringify(result) })); process.exit(0); }
if (!/inScope/.test(String(esc.payload.reason)))
  { console.log(JSON.stringify({ ok: false, reason: 'the refusal must name inScope: ' + JSON.stringify(esc.payload) })); process.exit(0); }
if (callLog.length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'a refused level must spawn nothing: ' + JSON.stringify(callLog.map(c => c.opts.label)) })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

run_node_case "K2080 input: an inScope whose every entry scrubs to empty REFUSES the level" "
$PREAMBLE

globalThis.args = { ...baseArgs, dualBuild: { tier: 'sonnet', baseline: 'b', candidate: 'c', inScope: ['  ', '', 42] }, items: [
  { slug: 'e2', branch: 'build/e2', title: 'Scrubbed', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();

const esc = (result.escalations ?? []).find(e => e.slug === 'e2');
if (!esc || esc.kind !== 'dual-build-input-invalid')
  { console.log(JSON.stringify({ ok: false, reason: 'an all-blank inScope must REFUSE: ' + JSON.stringify(result) })); process.exit(0); }
if (callLog.length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'a refused level must spawn nothing: ' + JSON.stringify(callLog.map(c => c.opts.label)) })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# --- temperloop#2080 static guards ------------------------------------------
# The runtime cases above prove the behaviour. These pin the two STRUCTURAL
# facts a future edit could undo while every case above still passed: that the
# PR phase really is a callable boundary driveItem composes (rather than a
# second copy of the code), and that the barrier's ordering has not been
# re-inlined back into the per-item drive.
grep -q 'async function driveItemPr' "$MJS" \
  || fail "#2080: build-level.mjs has no driveItemPr — the PR/CI/merge phase is not behind a callable boundary, so the level barrier has nothing to hold back"
grep -q 'async function driveItemBuild' "$MJS" \
  || fail "#2080: build-level.mjs has no driveItemBuild — the build phase is not separately callable"
# driveItem must COMPOSE the two, in order, and nothing else.
DRIVE_ITEM_BODY="$(awk '/^async function driveItem\(item\) \{$/,/^\}$/' "$MJS")"
printf '%s' "$DRIVE_ITEM_BODY" | grep -F 'driveItemBuild(item, null)' >/dev/null \
  || fail "#2080: driveItem no longer calls driveItemBuild — the single-arm path must run BOTH phases through the same boundary the dual path uses, or the two drift"
printf '%s' "$DRIVE_ITEM_BODY" | grep -F 'driveItemPr(built.ctx)' >/dev/null \
  || fail "#2080: driveItem no longer calls driveItemPr — a single-arm item would never reach push/PR/CI"
# The dual path exists, is reachable from the level driver, and holds the
# barrier BEFORE judging (the ordering the runtime case asserts, pinned here
# against a refactor that moves the judge inside the per-item drive).
grep -q "const dual = dualBuildInput();" "$MJS" \
  || fail "#2080: buildLevel never reads the dualBuild input — the flag would be inert"
grep -q 'async function driveLevelDualBuild' "$MJS" \
  || fail "#2080: build-level.mjs has no driveLevelDualBuild — there is no level-scoped driver to hold a level barrier in"
grep -q 'LEVEL BARRIER reached' "$MJS" \
  || fail "#2080: the barrier leaves no named notice in the run log — a barrier nobody can see in a transcript is indistinguishable from none"
grep -q 'dualBuild' "$MJS" \
  || fail "#2080: build-level.mjs never names dualBuild"
echo "PASS: #2080 static guards — the PR phase is a callable boundary driveItem composes, and the dual-build level driver + barrier notice are wired"

# ---------------------------------------------------------------------------
# K2080 EXECUTION test: the residue guard's own emitted shell, run for real.
#
# Every assertion above reads the guard's TEXT. This one RUNS it, twice, against
# a real filesystem — once with an arm worktree present and once without —
# because the whole claim ("byte-identical output on a clean tree, a refusal on
# a dirty one") is a claim about what that shell DOES, and a text assertion
# cannot tell a working `ls -d …@*` test from a broken one that always matches
# (or never does).
# ---------------------------------------------------------------------------
K2080_EXEC_ROOT="$WF_TEST_TMPDIR/k2080-exec"
mkdir -p "$K2080_EXEC_ROOT/bin" "$K2080_EXEC_ROOT/repo"
# A stub worktree.sh that prints the CREATED line the real one would.
cat > "$K2080_EXEC_ROOT/bin/worktree.sh" <<'STUB'
#!/usr/bin/env bash
printf '{"outcome":"CREATED","path":"%s.wt/%s","branch":"build/%s","guard":"ARMED"}\n' "$2" "$3" "$3"
STUB
chmod +x "$K2080_EXEC_ROOT/bin/worktree.sh"

# Emit the driver's OWN create command for a flag-less item, exactly as the
# executor would receive it.
k2080_emit_create() {
  # stderr goes to a FILE, not into "$out": the fail branch must be able to
  # print node's own stack trace (a command substitution captures stdout only,
  # so `echo "$out"` in that branch would print an empty line), while the
  # SUCCESS path must stay pure stdout — the emitted command is executed
  # verbatim below, and a node warning folded into it would be run as shell.
  local out
  local err="$WF_TEST_TMPDIR/k2080-emit.err"
  out="$(MJS_PATH="$MJS" AGENT_DEF_PATH="$AGENT_DEF" K2080_ROOT="$K2080_EXEC_ROOT" node --input-type=module -e "
$PREAMBLE
const root = process.env.K2080_ROOT + '/repo';
setMachinery('execslug', { outcome: 'CREATED', path: root + '.wt/execslug' }, { outcome: 'REVIEW_DIFF' }, { outcome: 'GATE_FAIL' });
happyWorker('execslug');
globalThis.args = { ...baseArgs, repoRoot: root, machineryBinDir: process.env.K2080_ROOT + '/bin', items: [
  { slug: 'execslug', branch: 'build/execslug', title: 'Exec', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
await mod.default();
const c = callLog.find(x => x.opts.label === 'prelude:execslug');
process.stdout.write(c.promptFull.split('\\nCommand:\\n')[1]);
")" 2>"$err" || fail "#2080-exec: could not emit the create command: $(cat "$err" 2>/dev/null)"
  printf '%s' "$out"
}
K2080_CREATE_CMD="$(k2080_emit_create)"
[ -n "$K2080_CREATE_CMD" ] || fail "#2080-exec: the emitted create command is empty"

# (a) CLEAN tree — no arm worktrees. The guard must be invisible: the create
#     runs and its CREATED line is the ONLY output.
rm -rf "$K2080_EXEC_ROOT/repo.wt"
k2080_clean_out="$(bash -c "$K2080_CREATE_CMD" 2>&1)" \
  || fail "#2080-exec: the generated create command exited non-zero on a clean tree: $k2080_clean_out"
printf '%s' "$k2080_clean_out" | grep -F '"outcome":"CREATED"' >/dev/null \
  || fail "#2080-exec: on a clean tree the residue guard swallowed the create (got: $k2080_clean_out)"
printf '%s' "$k2080_clean_out" | grep -F 'DUAL_BUILD_RESIDUE' >/dev/null \
  && fail "#2080-exec: the residue guard fired on a tree with NO arm worktrees — every ordinary /build would refuse"
[ "$(printf '%s\n' "$k2080_clean_out" | grep -c .)" = "1" ] \
  || fail "#2080-exec: the clean path printed more than the create's own line, so a flag-less run's output is NOT byte-identical (got: $k2080_clean_out)"

# (b) PARTIALLY DUAL-BUILT — an arm worktree for this slug stands. The guard
#     must refuse and the create must never run.
mkdir -p "$K2080_EXEC_ROOT/repo.wt/execslug@candidate"
k2080_dirty_out="$(bash -c "$K2080_CREATE_CMD" 2>&1)" \
  || fail "#2080-exec: the generated create command exited non-zero with an arm worktree standing: $k2080_dirty_out"
printf '%s' "$k2080_dirty_out" | grep -F '"outcome":"DUAL_BUILD_RESIDUE"' >/dev/null \
  || fail "#2080-exec: an arm worktree stands and the guard did not refuse (got: $k2080_dirty_out)"
printf '%s' "$k2080_dirty_out" | grep -F '"outcome":"CREATED"' >/dev/null \
  && fail "#2080-exec: the create ran anyway — a flag-less resume would rebuild over a half-finished dual build"
printf '%s' "$k2080_dirty_out" | grep -F 'execslug@candidate' >/dev/null \
  || fail "#2080-exec: the refusal does not name the arm worktree it found (got: $k2080_dirty_out)"

# (c) DISCRIMINATION — an UNRELATED slug's arm worktree must not refuse this
#     one. Without this the guard could be a bare "any @ dir anywhere" test.
rm -rf "$K2080_EXEC_ROOT/repo.wt"
mkdir -p "$K2080_EXEC_ROOT/repo.wt/otherslug@baseline"
k2080_other_out="$(bash -c "$K2080_CREATE_CMD" 2>&1)" \
  || fail "#2080-exec: the generated create command exited non-zero with an unrelated arm worktree present: $k2080_other_out"
printf '%s' "$k2080_other_out" | grep -F 'DUAL_BUILD_RESIDUE' >/dev/null \
  && fail "#2080-exec: another slug's arm worktree refused THIS slug's build — the guard is not slug-scoped"
printf '%s' "$k2080_other_out" | grep -F '"outcome":"CREATED"' >/dev/null \
  || fail "#2080-exec: an unrelated arm worktree blocked the create (got: $k2080_other_out)"
rm -rf "$K2080_EXEC_ROOT/repo.wt"

# (d) JSON VALIDITY — the refusal interpolates the matched paths into a JSON
#     string field, and the driver parses that line as JSON. A repoRoot holding
#     a `"` (or a `\`) therefore has to come out ESCAPED-OR-DROPPED, or a
#     refusal that exists to be legible becomes a bare parse error. Round-2
#     review [LOW]; asserted by PARSING the line, not by reading the filter.
if command -v jq >/dev/null 2>&1; then
  K2080_Q_ROOT="$WF_TEST_TMPDIR/k2080-quote"
  mkdir -p "$K2080_Q_ROOT/bin"
  cp "$K2080_EXEC_ROOT/bin/worktree.sh" "$K2080_Q_ROOT/bin/worktree.sh"
  k2080_q_repo='re"po'
  mkdir -p "$K2080_Q_ROOT/$k2080_q_repo" "$K2080_Q_ROOT/$k2080_q_repo.wt/execslug@candidate"
  k2080_q_err="$WF_TEST_TMPDIR/k2080-quote.err"
  K2080_Q_CMD="$(MJS_PATH="$MJS" AGENT_DEF_PATH="$AGENT_DEF" K2080_QROOT="$K2080_Q_ROOT/$k2080_q_repo" K2080_QBIN="$K2080_Q_ROOT/bin" node --input-type=module -e "
$PREAMBLE
const root = process.env.K2080_QROOT;
setMachinery('execslug', { outcome: 'CREATED', path: root + '.wt/execslug' }, { outcome: 'REVIEW_DIFF' }, { outcome: 'GATE_FAIL' });
happyWorker('execslug');
globalThis.args = { ...baseArgs, repoRoot: root, machineryBinDir: process.env.K2080_QBIN, items: [
  { slug: 'execslug', branch: 'build/execslug', title: 'Exec', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
await mod.default();
const c = callLog.find(x => x.opts.label === 'prelude:execslug');
process.stdout.write(c.promptFull.split('\\nCommand:\\n')[1]);
" 2>"$k2080_q_err")" || fail "#2080-exec: could not emit the create command for a quote-bearing repoRoot: $(cat "$k2080_q_err" 2>/dev/null)"
  k2080_q_out="$(bash -c "$K2080_Q_CMD" 2>&1)" \
    || fail "#2080-exec: the generated create command exited non-zero for a quote-bearing repoRoot: $k2080_q_out"
  printf '%s' "$k2080_q_out" | grep -F '"outcome":"DUAL_BUILD_RESIDUE"' >/dev/null \
    || fail "#2080-exec: the guard did not refuse for a quote-bearing repoRoot (got: $k2080_q_out)"
  printf '%s' "$k2080_q_out" | jq -e . >/dev/null 2>&1 \
    || fail "#2080-exec: the refusal is not parseable JSON when repoRoot holds a quote — the line the driver reads is malformed (got: $k2080_q_out)"
  rm -rf "$K2080_Q_ROOT"
fi

echo "PASS: #2080-exec — the residue guard's generated shell, executed for real: silent and byte-identical on a clean tree, refusing on this slug's arm worktrees, and not fooled by another slug's"

# ---------------------------------------------------------------------------
# K2080 JUDGE-EXEC test: the pairwise judge's own emitted shell, run for real.
#
# Round-2 review [HIGH]+[MEDIUM]: every other JUDGE_UNAVAILABLE assertion in
# this file INJECTS the outcome as a mock, so the judge command's actual shell —
# a mktemp -d, two jq writes, a judge.sh call and an rc branch — had no coverage
# of any kind, and the `| tail -1); __jr=$?` exit-status loss it shipped with was
# invisible to a green suite. These four cases RUN the emitted command against a
# stub judge.sh, which is the only way to tell a working rc branch from one that
# reads tail's status and therefore can never see a refusal at all.
# ---------------------------------------------------------------------------
if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: #2080-judge-exec — jq is absent on this host, and the emitted judge command builds both records with it"
else
K2080_JUDGE_ROOT="$WF_TEST_TMPDIR/k2080-judge"
K2080_MC_DIR="$K2080_JUDGE_ROOT/repo/workflows/scripts/model-comparison"
mkdir -p "$K2080_MC_DIR"

# k2080_stub_judge <exit-code> [stdout-line] — a judge.sh that prints at most
# one line and exits as told. The two-line variant is the case that matters:
# a judge that writes SOMETHING and then dies is exactly what a pipeline's `$?`
# cannot distinguish from a judge that succeeded.
k2080_stub_judge() {
  local rc="$1" line="${2-}"
  {
    echo '#!/usr/bin/env bash'
    if [ -n "$line" ]; then
      printf "cat <<'JUDGE_OUT'\n%s\nJUDGE_OUT\n" "$line"
    fi
    printf 'exit %s\n' "$rc"
  } > "$K2080_MC_DIR/judge.sh"
  chmod +x "$K2080_MC_DIR/judge.sh"
}

# Emit the driver's OWN judge command for an in-scope dual-build item, exactly
# as the executor would receive it.
k2080_emit_judge() {
  local out
  local err="$WF_TEST_TMPDIR/k2080-judge-emit.err"
  out="$(MJS_PATH="$MJS" AGENT_DEF_PATH="$AGENT_DEF" K2080_JROOT="$K2080_JUDGE_ROOT" node --input-type=module -e "
$PREAMBLE
$DUAL_FIXTURE
greenArm('jx', 'baseline'); greenArm('jx', 'candidate');
itemBarrier('jx');
globalThis.args = { ...dualArgs(['jx']), repoRoot: process.env.K2080_JROOT + '/repo', items: [
  { slug: 'jx', branch: 'build/jx', title: 'JX', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
await mod.default();
const c = callLog.find(x => x.opts.label === 'judge:jx');
if (!c) { process.stderr.write('no judge:jx call was spawned'); process.exit(1); }
process.stdout.write(c.promptFull.split('\\nCommand:\\n')[1]);
")" 2>"$err" || fail "#2080-judge-exec: could not emit the judge command: $(cat "$err" 2>/dev/null)"
  printf '%s' "$out"
}
K2080_JUDGE_CMD="$(k2080_emit_judge)"
[ -n "$K2080_JUDGE_CMD" ] || fail "#2080-judge-exec: the emitted judge command is empty"

# The static pin for the same defect, so a refactor that re-pipes the capture
# fails even before the four runtime cases below get to prove it.
printf '%s' "$K2080_JUDGE_CMD" | grep -E 'judge\.sh.*\| *tail[^)]*\); *__jr=' >/dev/null \
  && fail "#2080-judge-exec: the judge's exit status is read after a pipe — \$? is tail's status, so judge.sh's own rc never reaches the branch"

# (a) REFUSAL WITH NO STDOUT — the plain failure. rc must be reported as the
#     judge's own, not a structural 0.
k2080_stub_judge 3
k2080_judge_a="$(bash -c "$K2080_JUDGE_CMD" 2>&1)" \
  || fail "#2080-judge-exec: the emitted judge command exited non-zero on the silent-refusal case: $k2080_judge_a"
printf '%s' "$k2080_judge_a" | grep -F '"outcome":"JUDGE_UNAVAILABLE"' >/dev/null \
  || fail "#2080-judge-exec: a judge.sh exiting 3 with no output did not produce JUDGE_UNAVAILABLE (got: $k2080_judge_a)"
printf '%s' "$k2080_judge_a" | grep -F '"rc":3' >/dev/null \
  || fail "#2080-judge-exec: the refusal reports the wrong rc — the field exists to report judge.sh's own status (got: $k2080_judge_a)"

# (b) REFUSAL AFTER WRITING A LINE — the [HIGH] itself. A judge that dies after
#     printing must still be a refusal; under the piped capture it was recorded
#     as a genuine pairwise verdict.
k2080_stub_judge 3 '{"preference":"A","margin":30}'
k2080_judge_b="$(bash -c "$K2080_JUDGE_CMD" 2>&1)" \
  || fail "#2080-judge-exec: the emitted judge command exited non-zero on the noisy-refusal case: $k2080_judge_b"
printf '%s' "$k2080_judge_b" | grep -F '"outcome":"JUDGED"' >/dev/null \
  && fail "#2080-judge-exec: a judge.sh that exited 3 AFTER writing a line was recorded as a real verdict — \$? is being read from a pipe"
printf '%s' "$k2080_judge_b" | grep -F '"rc":3' >/dev/null \
  || fail "#2080-judge-exec: the noisy refusal did not report judge.sh's own rc (got: $k2080_judge_b)"

# (c) A REAL VERDICT still passes through — without this the two cases above
#     would be satisfied by a branch that refuses unconditionally.
k2080_stub_judge 0 '{"preference":"B","margin":40,"order_agreement":true}'
k2080_judge_c="$(bash -c "$K2080_JUDGE_CMD" 2>&1)" \
  || fail "#2080-judge-exec: the emitted judge command exited non-zero on the happy case: $k2080_judge_c"
printf '%s' "$k2080_judge_c" | grep -F '"outcome":"JUDGED"' >/dev/null \
  || fail "#2080-judge-exec: a clean judge.sh verdict was not recorded as JUDGED (got: $k2080_judge_c)"
printf '%s' "$k2080_judge_c" | grep -F '"preference":"B"' >/dev/null \
  || fail "#2080-judge-exec: the verdict's own JSON did not reach the outcome line (got: $k2080_judge_c)"

# (d) A NON-JSON LAST LINE is a NAMED refusal, never spliced into the outcome
#     object — otherwise the driver's one-JSON-line-per-step contract breaks and
#     a legible refusal becomes a parse error.
k2080_stub_judge 0 'judge.sh: the provider returned no usable response'
k2080_judge_d="$(bash -c "$K2080_JUDGE_CMD" 2>&1)" \
  || fail "#2080-judge-exec: the emitted judge command exited non-zero on the non-JSON case: $k2080_judge_d"
printf '%s' "$k2080_judge_d" | grep -F '"reason":"judge-unparseable"' >/dev/null \
  || fail "#2080-judge-exec: a non-JSON last line was not named as unparseable (got: $k2080_judge_d)"
printf '%s\n' "$k2080_judge_d" | while IFS= read -r l; do
  [ -z "$l" ] || printf '%s' "$l" | jq -e . >/dev/null 2>&1 || exit 7
done || fail "#2080-judge-exec: the unparseable path emitted a line that is not valid JSON (got: $k2080_judge_d)"

rm -rf "$K2080_JUDGE_ROOT"
echo "PASS: #2080-judge-exec — the judge's generated shell, executed for real: judge.sh's own exit status reaches the rc branch with and without stdout, a clean verdict still passes, and a non-JSON line becomes a named refusal"
fi

# ============================================================================
# temperloop#1805 / #865 / #1806 / #1698 / #1700 — THE WORKER HAND-OFF.
#
# One failure class, five instances: a hand-off that FAILS SILENTLY toward a
# plausible-looking value instead of erroring. An unparseable verdict reads as a
# failed item; a backgrounded gate reads as a slow one; a missing elapsedSecs
# reads as 0s; a `gh_issue` key reads as no linkage; and a payload's escaped
# quotes read as an unparseable command. Kernel principle 5 (counter AI failure
# modes structurally) applied to the engine's own seams.
# ============================================================================

# ---------------------------------------------------------------------------
# TEST (K1806): sq() must not emit the '\'' nesting idiom, and the value must
#   still survive a REAL shell round-trip. The live failure was the executor's
#   own shell parser refusing "deeply nested quotes" at PARSE time, before git
#   was touched — deterministic for the item, so no re-drive could clear it.
#   Two assertions, because either alone is satisfiable by a broken fix:
#   ZERO `'\''` in the composed command (the trigger — RED before), AND an
#   exact byte round-trip through bash (correctness — the control).
# ---------------------------------------------------------------------------
run_node_case "K1806: an item payload carrying escaped single quotes composes a command with NO nested-quote idiom, and round-trips exactly" "
$PREAMBLE
import { execFileSync, } from 'child_process';
import { writeFileSync, mkdtempSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';

// The OBSERVED live shape (temperloop#1806, slug sweep-try-sh-citations-1334):
// an item payload whose text already carries the '\\'' escape sequence, plus a
// plain apostrophe. Both must survive.
const TITLE = \"fix sq() so a payload's '\\\\'' escape can't break the parse\";
happyMachinery('q1806', 1806, 'a806');
happyWorker('q1806');
globalThis.args = { ...baseArgs, machineryBinDir: '/mb', items: [
  { slug: 'q1806', branch: 'build/q1806', title: TITLE, kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
const result = await mod.default();
const prb = callLog.find(c => (c.opts.label||'') === 'pr-batch:q1806');
let reason = null;
if (!prb) reason = 'no pr-batch call logged: ' + JSON.stringify(result);
else {
  const body = prb.promptFull.slice(prb.promptFull.indexOf('\\nCommand:\\n'));
  // (1) THE TRIGGER. The '\\''-style idiom must appear nowhere in the emitted
  //     command text — that nesting is what the executor's parser refused.
  const NEST = String.fromCharCode(39) + String.fromCharCode(92) + String.fromCharCode(39) + String.fromCharCode(39);
  if (body.includes(NEST)) reason = 'the composed command still carries the nested-quote idiom that broke the parse';
  // (2) THE CONTROL. Extract the --title argument as emitted and execute it.
  //     A fix that merely stripped quoting would pass (1) and fail here.
  if (!reason) {
    const m = body.match(/--title ([\\s\\S]*?) --verdict /);
    if (!m) reason = 'could not locate the --title argument in the composed command';
    else {
      const dir = mkdtempSync(join(tmpdir(), 'k1806-'));
      const f = join(dir, 'rt.sh');
      writeFileSync(f, 'printf %s ' + m[1] + '\\n');
      const got = execFileSync('bash', [f], { encoding: 'utf8' });
      if (got !== TITLE) reason = 'round-trip mismatch: wanted ' + JSON.stringify(TITLE) + ' got ' + JSON.stringify(got);
    }
  }
}
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

grep -q 'if (!s.includes(\"'\''\")) return' "$MJS" \
  || fail "#1806: sq() must keep the single-quoted form for values with no single quote (byte-identical to the pre-#1806 emission at ~86 call sites)"
grep -q 'temperloop#1806' "$MJS" \
  || fail "#1806: sq() must name the defect it fixes — the nesting the executor's own shell parser refuses"
echo "PASS: #1806 static guard — sq() keeps the single-quoted form when nothing needs escaping"

# ---------------------------------------------------------------------------
# TEST (K1698): a GATE_PASS returning the SNAKE_CASE spelling must report the
#   REAL wall time, and a GATE_PASS returning NEITHER spelling must render '?'
#   — never 0. The silent zero disabled the gate decay signal on the one
#   instrument built to make suite growth visible.
# ---------------------------------------------------------------------------
run_node_case "K1698: a GATE_PASS bearing elapsed_secs reports the real wall time, not 0s" "
$PREAMBLE
const logged = [];
globalThis.log = (m) => logged.push(String(m));
setMachinery('el-snake',
  { outcome: 'CREATED', path: '/tmp/repo.wt/el-snake' },
  { outcome: 'REVIEW_DIFF' },
  // The OBSERVED shape (run wf_9ce4bd0c-58b): the gate's own log said 215s.
  { outcome: 'GATE_PASS', failed: 0, elapsed_secs: 215, ceiling_secs: 300 },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'a69' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'a69', branch: 'build/el-snake' },
  { outcome: 'PR_OPENED', pr_number: 1698 },
  { outcome: 'CI_GREEN' },
);
happyWorker('el-snake');
globalThis.args = { ...baseArgs, items: [
  { slug: 'el-snake', branch: 'build/el-snake', title: 'T', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
const result = await mod.default();
const passLine = logged.find(m => /3e\\.5 gate PASS/.test(m)) || '';
let reason = null;
if ((result.parked ?? []).length !== 1) reason = 'expected the item to park green: ' + JSON.stringify(result);
else if (!passLine) reason = 'no 3e.5 gate PASS line logged: ' + JSON.stringify(logged);
else if (/0s of gate wall time/.test(passLine)) reason = 'THE DEFECT: a 215s gate was reported as 0s — ' + passLine;
else if (!/215s of gate wall time/.test(passLine)) reason = 'the real elapsed figure did not reach the log: ' + passLine;
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K1698: a GATE_PASS bearing NEITHER spelling renders '?', never a plausible 0 — and says so" "
$PREAMBLE
const logged = [];
globalThis.log = (m) => logged.push(String(m));
setMachinery('el-none',
  { outcome: 'CREATED', path: '/tmp/repo.wt/el-none' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS', failed: 0 },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'a70' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'a70', branch: 'build/el-none' },
  { outcome: 'PR_OPENED', pr_number: 1699 },
  { outcome: 'CI_GREEN' },
);
happyWorker('el-none');
globalThis.args = { ...baseArgs, items: [
  { slug: 'el-none', branch: 'build/el-none', title: 'T', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
const result = await mod.default();
const passLine = logged.find(m => /3e\\.5 gate PASS/.test(m)) || '';
let reason = null;
if ((result.parked ?? []).length !== 1) reason = 'expected the item to park green: ' + JSON.stringify(result);
else if (/0s of gate wall time/.test(passLine)) reason = 'THE SILENT ZERO MOVED ONE FIELD OVER: an unknown elapsed rendered as 0s — ' + passLine;
else if (!/\\?s of gate wall time/.test(passLine)) reason = \"an unknown elapsed must render '?': \" + passLine;
else if (!logged.some(m => /NO usable elapsedSecs/.test(m))) reason = 'a blind decay signal must say so out loud; logged: ' + JSON.stringify(logged);
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K1698: the escalation PAYLOAD carries the real elapsed figure, not 0 — a snake_case GATE_FAIL" "
$PREAMBLE
setMachinery('el-pay',
  { outcome: 'CREATED', path: '/tmp/repo.wt/el-pay' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_FAIL', failed: 2, elapsed_secs: 188, rc: 1 },
);
happyWorker('el-pay');
globalThis.args = { ...baseArgs, items: [
  { slug: 'el-pay', branch: 'build/el-pay', title: 'T', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
const result = await mod.default();
const esc = (result.escalations ?? [])[0];
let reason = null;
if (!esc) reason = 'expected an acceptance-gate-failed escalation: ' + JSON.stringify(result);
else if (esc.kind !== 'acceptance-gate-failed') reason = 'wrong kind: ' + esc.kind;
else if (esc.payload.elapsedSecs === 0) reason = 'THE DEFECT: a 188s gate run is reported in the payload as 0s';
else if (esc.payload.elapsedSecs !== 188) reason = 'payload elapsedSecs should be 188, got ' + JSON.stringify(esc.payload.elapsedSecs);
else if ((esc.payload.sliceLedger ?? [])[0]?.elapsedSecs !== 188) reason = 'the slice ledger must carry the same figure: ' + JSON.stringify(esc.payload.sliceLedger);
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

# --- K1698 static guards: the PRODUCER half. The emitted gate command must not
# default an unreadable elapsed to 0, and the canonicalizer must exist at the
# transport boundary rather than as a per-consumer `??` chain. ---------------
grep -q 'function canonicalizeOutcome' "$MJS" \
  || fail "#1698: canonicalizeOutcome() missing — one spelling must be established ONCE at the transport boundary, not per read site"
grep -q '__elj=null' "$MJS" \
  || fail "#1698: the emitted gate command must report an unreadable elapsed as JSON null, never \${__el:-0} (a plausible zero)"
grep -q 'elapsedSecs\":%s,\"workerGate' "$MJS" \
  || fail "#1698/#865: the GATE_SLICE/GATE_PASS/GATE_FAIL emitters must carry the canonical elapsedSecs plus the worker-gate classification"
# The real invariant is not a count but a CLASS: no JS property READ of a
# snake_case duration key may remain. The wire spelling lives on in the emitted
# shell, the schema and the alias table; a `.elapsed_secs` / `.ceiling_secs` /
# `.slow_secs` dereference is a consumer, and a consumer is the defect.
grep -nE '\.(elapsed_secs|ceiling_secs|slow_secs)\b' "$MJS" \
  && fail "#1698: a consumer still READS a snake_case duration key — canonicalizeOutcome() establishes one spelling at the boundary precisely so no read site has to chain \`??\`"
grep -q "elapsed_secs: 'elapsedSecs'" "$MJS" \
  || fail "#1698: OUTCOME_KEY_ALIASES must map the wire spelling onto the canonical one"
echo "PASS: #1698 producer guard — canonicalizeOutcome() at the boundary, JSON null for an unreadable elapsed, no snake_case consumer left"

# --- K1698 PRODUCER↔SCHEMA case: the REAL emitted line, against the REAL schema.
#
# WHY THIS EXISTS (review round 2). Every K1698 node case above calls
# setMachinery() to inject an already-PARSED outcome object, so they all enter
# the file downstream of the one seam this fix actually crosses: the emitted
# shell prints a JSON line, and `agent({ schema: SPINE_OUTCOME_SCHEMA })`
# validates THAT line before any consumer sees it. A producer that legitimately
# emits `"elapsedSecs":null` against a schema whose type array omits `null` is
# this PR's own defect class one layer up — a fixed "report null honestly" path
# that the contract rejects — and it fires only when the figure is ALREADY
# unknown, i.e. in the hardest case to notice. A mocked harness structurally
# cannot see it, so this case runs the producer for real and checks the schema.
K1698_ELCASE="$(sed -n 's/^ *`\(case "\$__el" in .*esac; \)` *+$/\1/p' "$MJS")"
[ -n "$K1698_ELCASE" ] \
  || fail "#1698: could not extract the __elj producer fragment from $MJS — the emitted gate command no longer classifies \$__el, or the extraction anchor moved"
K1698_PASSFMT="$(sed -n "s/^ *\`\(printf '{\"outcome\":\"GATE_PASS\".*\)\` *+\$/\1/p" "$MJS" \
  | sed 's/\\\\n/\\n/; s/\${GATE_SLICE_SECS}/300/')"
[ -n "$K1698_PASSFMT" ] \
  || fail "#1698: could not extract the GATE_PASS emitter from $MJS"
# `__el` EMPTY is the unknown-elapsed path: a vendored gate whose summary line
# the emitter's sed does not match, or a slice killed before printing one.
K1698_LINE="$(__el='' __wg=absent bash -c "$K1698_ELCASE $K1698_PASSFMT")" \
  || fail "#1698: the emitted GATE_PASS fragment failed to execute under bash"
printf '%s\n' "$K1698_LINE" | grep -F '"elapsedSecs":null' >/dev/null \
  || fail "#1698: the emitted GATE_PASS line must carry a JSON null for an unknown elapsed, never a plausible 0 — got: $K1698_LINE"
# And the KNOWN path still emits the real number, so the null above is a
# discrimination, not a constant.
K1698_LINE_OK="$(__el=215 __wg=finished bash -c "$K1698_ELCASE $K1698_PASSFMT")" \
  || fail "#1698: the emitted GATE_PASS fragment failed to execute on the readable-elapsed path"
printf '%s\n' "$K1698_LINE_OK" | grep -F '"elapsedSecs":215' >/dev/null \
  || fail "#1698: a READABLE elapsed must be reported verbatim — got: $K1698_LINE_OK"
k1698_schema="$(K1698_LINE="$K1698_LINE" MJS_PATH="$MJS" node -e "
  const { readFileSync } = require('fs');
  const src = readFileSync(process.env.MJS_PATH, 'utf8').replace(/^export const meta/m, 'const meta');
  const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
  globalThis.args = JSON.stringify({ repoRoot: '/tmp/repo', planLink: 'p', board: null, ownerRepo: 'o/r', items: [] });
  globalThis.agent = async () => null; globalThis.log = () => {}; globalThis.phase = () => {};
  globalThis.parallel = async (fns) => Promise.all(fns.map(f => f()));
  const probe = src.replace(/return await buildLevel\(\);\s*\$/, 'return SPINE_OUTCOME_SCHEMA;');
  new AsyncFunction(probe)().then(schema => {
    const line = JSON.parse(process.env.K1698_LINE);
    const bad = [];
    for (const [k, v] of Object.entries(line)) {
      const decl = schema.properties[k];
      // additionalProperties:true — an UNDECLARED key is legal, so only a
      // declared key whose type array excludes the produced value is a defect.
      if (!decl) continue;
      const actual = v === null ? 'null' : Array.isArray(v) ? 'array' : typeof v;
      const types = decl.type === undefined ? null : [].concat(decl.type);
      if (types && !types.includes(actual))
        bad.push(k + ': the producer emits ' + actual + ' but the schema admits only ' + JSON.stringify(types));
      if (decl.enum && !decl.enum.includes(v)) bad.push(k + ': ' + JSON.stringify(v) + ' is outside the declared enum');
    }
    process.stdout.write(bad.length ? bad.join('; ') : 'ok');
  }).catch(e => process.stdout.write('probe-error: ' + e.message));
")" || fail "#1698: the producer↔schema probe failed to run"
[ "$k1698_schema" = ok ] \
  || fail "#1698: the REAL line the gate emitter prints on the unknown-elapsed path does NOT validate against the REAL SPINE_OUTCOME_SCHEMA — $k1698_schema (line: $K1698_LINE)"
echo "PASS: #1698 producer↔schema — the emitted GATE_PASS line degrades to JSON null for an unknown elapsed, reports a known one verbatim, and both validate against SPINE_OUTCOME_SCHEMA"

# ---------------------------------------------------------------------------
# TEST (K1700): an item carrying the DOCUMENTED plan-schema key `gh_issue:`
#   must produce a --gh-issue flag. Three PRs from one level merged with no
#   `Closes` line because the number sat under a key nothing read.
# ---------------------------------------------------------------------------
run_node_case "K1700: an item carrying gh_issue (the documented plan-schema spelling) still emits --gh-issue and --also-closes" "
$PREAMBLE
happyMachinery('gh-snake', 1700, 'a17');
happyWorker('gh-snake');
globalThis.args = { ...baseArgs, machineryBinDir: '/mb', items: [
  { slug: 'gh-snake', branch: 'build/gh-snake', title: 'T', kind: 'impl', acceptance: ['c'],
    gh_issue: 1700, also_closes: [1698, 1806] },
]};
const mod = await loadLevel();
const result = await mod.default();
const prb = callLog.find(c => (c.opts.label||'') === 'pr-batch:gh-snake');
let reason = null;
if (!prb) reason = 'no pr-batch call logged: ' + JSON.stringify(result);
else if (!prb.promptFull.includes(\"--gh-issue '1700'\")) reason = 'THE DEFECT: the documented gh_issue key produced no --gh-issue flag, so the PR closes nothing';
else if (!prb.promptFull.includes(\"--also-closes '1698,1806'\")) reason = 'the documented also_closes key produced no --also-closes flag';
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K1700: an unrecognized item key is NAMED, and an item with neither spelling stays legal and silent" "
$PREAMBLE
const logged = [];
globalThis.log = (m) => logged.push(String(m));
happyMachinery('gh-unk', 1701, 'a18');
happyWorker('gh-unk');
happyMachinery('gh-quiet', 1702, 'a19');
happyWorker('gh-quiet');
globalThis.args = { ...baseArgs, machineryBinDir: '/mb', items: [
  { slug: 'gh-unk', branch: 'build/gh-unk', title: 'T', kind: 'impl', acceptance: ['c'], ghIsue: 99 },
  { slug: 'gh-quiet', branch: 'build/gh-quiet', title: 'T', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
const result = await mod.default();
const prbQuiet = callLog.find(c => (c.opts.label||'') === 'pr-batch:gh-quiet');
let reason = null;
if ((result.parked ?? []).length !== 2) reason = 'expected both items to park: ' + JSON.stringify(result);
else if (!logged.some(m => /gh-unk.*does not read.*ghIsue/.test(m))) reason = 'a key nothing reads must be NAMED — that is the half that catches the NEXT alias; logged: ' + JSON.stringify(logged);
else if (logged.some(m => /gh-quiet.*does not read/.test(m))) reason = 'an item with no issue number is a legal, normal state and must stay silent';
else if (prbQuiet && prbQuiet.promptFull.includes('--gh-issue')) reason = 'an item with neither spelling must emit no --gh-issue flag';
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

grep -q 'function normalizeItem' "$MJS" \
  || fail "#1700: normalizeItem() missing — the snake/camel reconciliation must happen ONCE where items enter"
grep -q '(input.items ?? \[\]).map(normalizeItem)' "$MJS" \
  || fail "#1700: buildLevel() must run every item through normalizeItem() — a defined-but-unapplied normalizer changes nothing"
# PIN THE MAPPING, NOT THE MENTION (review round 2). The previous form was a
# four-alternative BRE whose last branch matched a bare `gh_issue:` ANYWHERE in
# the file — and build-level.mjs discusses all three spellings in prose comments,
# so the guard passed off those regardless of what ITEM_KEY_ALIASES actually
# held. Verified unfalsifiable: it stayed green against a fixture whose alias
# table was `{ nothing: 'here' }` but which carried one such comment. A guard
# that cannot go red for the thing its failure message names is not coverage.
# These are exact-literal reads of the TABLE ENTRY, so deleting a row is red.
for _k1700_pair in \
  "gh_issue: 'ghIssue'" \
  "also_closes: 'alsoCloses'" \
  "'depends-on': 'dependsOn'"; do
  grep -qF -- "$_k1700_pair" "$MJS" \
    || fail "#1700: ITEM_KEY_ALIASES must map the documented plan-schema spelling — missing the literal entry \`$_k1700_pair\` (a prose MENTION of the key does not satisfy this; the table row must exist)"
done
echo "PASS: #1700 static guard — normalizeItem() exists, is applied at the entry point, and the alias TABLE (not a comment) carries every documented spelling"

# --- K1700 lockstep guard: ITEM_KEYS_READ vs. the reads that actually exist --
# build-level.mjs's comment above ITEM_KEYS_READ claims this guard by name; it
# is real. Both directions matter and neither is redundant: a read missing from
# the list makes normalizeItem() WARN about a key the file does read (noise that
# trains readers to ignore the warning), and a listed key nothing reads any more
# silences the warning for a key that has become genuinely unread — which is the
# #1700 defect itself, back again.
k1700_lockstep="$(MJS_PATH="$MJS" node -e "
  const { readFileSync } = require('fs');
  const src = readFileSync(process.env.MJS_PATH, 'utf8').replace(/^export const meta/m, 'const meta');
  const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
  globalThis.args = JSON.stringify({ repoRoot: '/tmp/repo', planLink: 'p', board: null, ownerRepo: 'o/r', items: [] });
  globalThis.agent = async () => null; globalThis.log = () => {}; globalThis.phase = () => {};
  globalThis.parallel = async (fns) => Promise.all(fns.map(f => f()));
  const probe = src.replace(/return await buildLevel\(\);\s*\$/, 'return { read: ITEM_KEYS_READ, ignored: ITEM_KEYS_IGNORED, aliases: ITEM_KEY_ALIASES };');
  new AsyncFunction(probe)().then(t => {
    const declared = new Set(t.read);
    const known = new Set([...t.read, ...t.ignored, ...Object.values(t.aliases)]);
    const actual = new Set((src.match(/\bitem\.[A-Za-z_][A-Za-z0-9_]*/g) || []).map(s => s.slice(5)));
    const bad = [];
    for (const k of actual) if (!known.has(k)) bad.push('the file READS item.' + k + ' but no key list knows it');
    for (const k of declared) if (!actual.has(k)) bad.push('ITEM_KEYS_READ lists ' + k + ' but nothing reads item.' + k + ' any more');
    process.stdout.write(bad.length ? bad.join('; ') : 'ok');
  }).catch(e => process.stdout.write('probe-error: ' + e.message));
")" || fail "#1700: the ITEM_KEYS_READ lockstep probe failed to run"
[ "$k1700_lockstep" = ok ] \
  || fail "#1700: ITEM_KEYS_READ has drifted from the reads that actually exist — $k1700_lockstep"
echo "PASS: #1700 lockstep guard — every item.<key> read is accounted for, and every ITEM_KEYS_READ entry is still read"

# ---------------------------------------------------------------------------
# TEST (K1805): an unparseable verdict over a PR-READY tree must not abort the
#   item. Observed live (slug disclosure-watermark-tracked-1316): one clean
#   commit, zero-dirty tree, full .build-verification.md, own suite 39/39 — and
#   the item reported `pr-open-failed`. The orchestrator recovered it by hand
#   into PR #1803.
# ---------------------------------------------------------------------------
run_node_case "K1805: an unparseable verdict falls back to the verification surface and the item PARKS on a real PR" "
$PREAMBLE
const logged = [];
globalThis.log = (m) => logged.push(String(m));
setMachinery('vu-ok',
  { outcome: 'CREATED', path: '/tmp/repo.wt/vu-ok' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS', elapsedSecs: 12 },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'a1803' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'a1803', branch: 'build/vu-ok' },
  // pr.sh's own die() over the verdict file it was handed.
  { outcome: 'ERROR', step: 'pr-open', error: 'verdict is not valid JSON' },
  // …the fallback re-issue, which is what the manual recovery did by hand.
  { outcome: 'PR_OPENED', pr_number: 1803 },
  { outcome: 'CI_GREEN' },
);
happyWorker('vu-ok');
globalThis.args = { ...baseArgs, items: [
  { slug: 'vu-ok', branch: 'build/vu-ok', title: 'T', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
const result = await mod.default();
const parked = result.parked ?? [];
const fb = callLog.find(c => (c.opts.label||'') === 'pr-open-verdict-fallback:vu-ok');
let reason = null;
if ((result.escalations ?? []).length !== 0) reason = 'THE DEFECT: complete, committed work was reported as a failed item — ' + JSON.stringify(result.escalations);
else if (parked.length !== 1) reason = 'expected the item to park: ' + JSON.stringify(result);
else if (parked[0].pr !== 1803) reason = 'must park on the PR the fallback opened, got ' + parked[0].pr;
else if (!fb) reason = 'the fallback must RE-ISSUE pr.sh open rather than re-running the same bad verdict';
else if (!fb.promptFull.includes('--verification-surface-file')) reason = 'the fallback body must come from .build-verification.md, exactly as the manual recovery did';
else if (!fb.promptFull.includes('temperloop#1805')) reason = 'the fallback PR body must say WHY its acceptance table is missing';
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K1805: when the fallback cannot land it either, the escalation distinguishes 'no work' from 'work done, reporting broke'" "
$PREAMBLE
setMachinery('vu-esc',
  { outcome: 'CREATED', path: '/tmp/repo.wt/vu-esc' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS', elapsedSecs: 12 },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'a81d' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'a81d', branch: 'build/vu-esc' },
  { outcome: 'ERROR', step: 'pr-open', error: 'verdict is not valid JSON' },
  { outcome: 'ERROR', step: 'pr-open', error: 'verdict is not valid JSON' },
  // The recover-probe behind the enriched payload.
  { outcome: 'RECOVER_COMMITTED', commits_ahead: 1, pushed: true, dirty: false, dirty_files: 0, sha: 'a81d', verification_surface_present: true },
);
happyWorker('vu-esc');
globalThis.args = { ...baseArgs, items: [
  { slug: 'vu-esc', branch: 'build/vu-esc', title: 'T', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
const result = await mod.default();
const esc = (result.escalations ?? [])[0];
let reason = null;
if (!esc) reason = 'expected an escalation: ' + JSON.stringify(result);
else if (esc.kind !== 'verdict-unparseable') reason = \"a reporting failure must not wear the generic pr-open-failed kind, got: \" + esc.kind;
else if (esc.payload.committed_sha !== 'a81d') reason = 'the payload must name the commit that exists, got ' + JSON.stringify(esc.payload.committed_sha);
else if (esc.payload.dirty !== false) reason = 'the payload must report tree cleanliness, got ' + JSON.stringify(esc.payload.dirty);
else if (esc.payload.verification_present !== true) reason = 'the payload must report that a verification surface exists, got ' + JSON.stringify(esc.payload.verification_present);
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K1805 control: a pr-open failure that is NOT about the verdict keeps the unchanged pr-open-failed path (no blind re-issue)" "
$PREAMBLE
setMachinery('vu-ctl',
  { outcome: 'CREATED', path: '/tmp/repo.wt/vu-ctl' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS', elapsedSecs: 12 },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'a91d' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'a91d', branch: 'build/vu-ctl' },
  { outcome: 'ERROR', step: 'pr-open', error: 'gh pr create failed: authentication required' },
);
happyWorker('vu-ctl');
globalThis.args = { ...baseArgs, items: [
  { slug: 'vu-ctl', branch: 'build/vu-ctl', title: 'T', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
const result = await mod.default();
const esc = (result.escalations ?? [])[0];
let reason = null;
if (!esc) reason = 'expected an escalation: ' + JSON.stringify(result);
else if (esc.kind !== 'pr-open-failed') reason = 'a non-verdict pr-open failure must keep its own kind, got ' + esc.kind;
else if (callLog.some(c => /pr-open-verdict-fallback/.test(c.opts.label||''))) reason = 'BLIND RE-ISSUE: a non-idempotent pr-open was re-run for a failure the fallback cannot fix';
else if (esc.payload.committed_sha !== 'a91d') reason = 'even the unchanged path must say what landed, got ' + JSON.stringify(esc.payload.committed_sha);
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

grep -q 'function isVerdictUnparseable' "$MJS" \
  || fail "#1805: isVerdictUnparseable() missing — the tolerance arm must key on pr.sh's OWN verdict-parse messages, never a catch-all"
grep -qF "escalate(item.slug, 'verdict-unparseable'" "$MJS" \
  || fail "#1805: a reporting-layer failure must escalate under its own kind, not the generic pr-open-failed"
echo "PASS: #1805 static guard — narrow verdict-parse detection + its own escalation kind"

# ---------------------------------------------------------------------------
# TEST (K865): the worker is HANDED a gate invocation that always leaves a
#   RESULT SENTINEL, and polls that artifact rather than a PID — and a sentinel
#   still reading `running` at §3e.5 produces a LOUD, named notice. Both Level-1
#   workers of epic #810 stalled 2/2 against a prompt that named the exact
#   failure, so the issue's acceptance explicitly refuses a third wording.
# ---------------------------------------------------------------------------
run_node_case "K865 prevention: the worker prompt HANDS OVER a sentinel-writing gate command and names the artifact to poll" "
$PREAMBLE
happyMachinery('gs-item', 865, 'a865');
happyWorker('gs-item');
globalThis.args = { ...baseArgs, items: [
  { slug: 'gs-item', branch: 'build/gs-item', title: 'T', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
await mod.default();
const w = callLog.find(c => (c.opts.label||'') === 'worker:gs-item');
let reason = null;
if (!w) reason = 'no worker call logged';
else if (!w.promptFull.includes('/tmp/qg-gs-item.worker-gate.json')) reason = 'THE FIX IS ABSENT: the worker is given no result-sentinel path, so its only poll target is still a PROCESS';
else if (!w.promptFull.includes('run THIS EXACT command (temperloop#865)')) reason = 'the worker must be HANDED the invocation, not asked to compose one';
else if (!/state\\\\\"?:\\\\\"?running/.test(w.promptFull) && !w.promptFull.includes('\\\"state\\\":\\\"running\\\"')) reason = 'the handed command must write a running sentinel BEFORE the suite starts';
else if (!w.promptFull.includes('Poll the RESULT FILE, never a PID')) reason = 'the worker must be told to poll the ARTIFACT — a PID poll is the stall this replaces';
else if (!w.promptFull.includes('set -o pipefail')) reason = 'the handed command tees the suite, so pipefail is load-bearing or a RED gate writes rc:0';
else if (!w.promptFull.includes('NEVER report a gate pass without a')) reason = 'a missing sentinel must not be reportable as a pass';
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K865 detection: a sentinel still reading 'running' at 3e.5 is LOUD — a stalled worker reads differently from a slow one" "
$PREAMBLE
const logged = [];
globalThis.log = (m) => logged.push(String(m));
setMachinery('gs-stall',
  { outcome: 'CREATED', path: '/tmp/repo.wt/gs-stall' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS', elapsedSecs: 40, workerGate: 'running' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'a86' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'a86', branch: 'build/gs-stall' },
  { outcome: 'PR_OPENED', pr_number: 865 },
  { outcome: 'CI_GREEN' },
);
happyWorker('gs-stall');
globalThis.args = { ...baseArgs, items: [
  { slug: 'gs-stall', branch: 'build/gs-stall', title: 'T', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
const result = await mod.default();
let reason = null;
if ((result.parked ?? []).length !== 1) reason = 'the notice is advisory — 3e.5 is the acceptance authority and a green item must still park: ' + JSON.stringify(result);
else if (!logged.some(m => /WORKER GATE NEVER FINISHED \\(temperloop#865\\)/.test(m))) reason = 'SILENT: an abandoned gate is indistinguishable from a slow one; logged: ' + JSON.stringify(logged);
else if (!logged.some(m => /worker-gate\\.json/.test(m))) reason = 'the notice must name the artifact a human can read';
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K865 control: a FINISHED (or absent) sentinel is silent — the notice discriminates, it does not fire on every run" "
$PREAMBLE
const logged = [];
globalThis.log = (m) => logged.push(String(m));
setMachinery('gs-fin',
  { outcome: 'CREATED', path: '/tmp/repo.wt/gs-fin' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS', elapsedSecs: 40, workerGate: 'finished' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'a87' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'a87', branch: 'build/gs-fin' },
  { outcome: 'PR_OPENED', pr_number: 866 },
  { outcome: 'CI_GREEN' },
);
happyWorker('gs-fin');
setMachinery('gs-abs',
  { outcome: 'CREATED', path: '/tmp/repo.wt/gs-abs' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS', elapsedSecs: 40 },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'a88' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'a88', branch: 'build/gs-abs' },
  { outcome: 'PR_OPENED', pr_number: 867 },
  { outcome: 'CI_GREEN' },
);
happyWorker('gs-abs');
globalThis.args = { ...baseArgs, items: [
  { slug: 'gs-fin', branch: 'build/gs-fin', title: 'T', kind: 'impl', acceptance: ['c'] },
  { slug: 'gs-abs', branch: 'build/gs-abs', title: 'T', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
const result = await mod.default();
let reason = null;
if ((result.parked ?? []).length !== 2) reason = 'expected both items to park: ' + JSON.stringify(result);
else if (logged.some(m => /WORKER GATE NEVER FINISHED/.test(m))) reason = 'the notice fired on a finished/absent sentinel — it would be noise on every run, which is how a real signal gets ignored';
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

# --- K865 EXECUTED-SHELL case: the handed invocation is run FOR REAL against a
# stub gate, in both the green and the red arm. A prompt that merely MENTIONS a
# sentinel is what #865 forbids; this proves the command actually writes one,
# and that a RED suite is not recorded as rc:0 through the tee. --------------
#
# THE SLUG IS PER-RUN, NOT THE LITERAL `k865` (#258, review round 2). The
# sentinel path is chosen by workerGateSentinel() from the slug, so a fixed slug
# means a fixed, world-writable `/tmp/qg-k865.worker-gate.json` — precisely the
# shared-path collision the header above says this suite does not have. Two
# concurrent runs (the documented parallel-/build-worker case) would interleave
# on one file: run A's `rm -f` between B's write and B's read reads as "the
# handed command left NO result sentinel", and A's RED-arm `"rc":4` read by B's
# GREEN-arm assertion reports a green gate recorded as red — a flake wearing the
# costume of the real defect. A per-run slug also removes the EPERM case (`rm -f`
# suppresses ENOENT, not EACCES, so another uid's leftover would abort the suite
# under `set -e` with no `fail` message).
K865_ROOT="$(mktemp -d "$WF_TEST_TMPDIR/k865-XXXXXX")"
mkdir -p "$K865_ROOT/scripts"
K865_SLUG="k865-$$-${RANDOM}"
K865_SENTINEL="/tmp/qg-${K865_SLUG}.worker-gate.json"
K865_GATELOG="/tmp/qg-${K865_SLUG}.worker-gate.log"
# Registered for the EXIT trap AT CREATION TIME: every `|| fail` below is an
# `exit 1`, so a cleanup line at the end of the block is exactly the one that
# never runs on a failing run.
wf_test_sweep_add "$K865_SENTINEL" "$K865_GATELOG"
# k865_emit_cmd <worktree-path> — emit the REAL handed invocation for that path.
# Parameterized (review round 2) because the failed-`cd` arm below has to emit
# the command for a worktree that does NOT exist; hard-coding $K865_ROOT would
# have made that arm unwritable, which is why the defect survived round 1.
k865_emit_cmd() {
  K865_WT="$1" node -e "
    globalThis.args = JSON.stringify({ repoRoot: process.env.K865_WT, planLink: 'p', board: null, ownerRepo: 'o/r', items: [] });
    globalThis.agent = async () => null; globalThis.log = () => {}; globalThis.phase = () => {};
    globalThis.parallel = async (fns) => Promise.all(fns.map(f => f()));
    const { readFileSync } = require('fs');
    const src = readFileSync(process.env.MJS_PATH, 'utf8').replace(/^export const meta/m, 'const meta');
    const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
    // Re-declare the emitted body, then reach the helper by re-evaluating the
    // file with a trailing expression instead of its own top-level return.
    const probe = src.replace(/return await buildLevel\(\);\s*$/, 'return workerGateCmd(' + JSON.stringify('$K865_SLUG') + ', process.env.K865_WT);');
    new AsyncFunction(probe)().then(c => process.stdout.write(c));
  "
}
K865_CMD="$(k865_emit_cmd "$K865_ROOT")" || fail "#865: could not emit the handed worker gate command"
[ -n "$K865_CMD" ] || fail "#865: the handed worker gate command is empty"
case "$K865_CMD" in
  *"$K865_SENTINEL"*) : ;;
  *) fail "#865: the handed command does not write the sentinel path the prompt names ($K865_SENTINEL): $K865_CMD" ;;
esac
# The prologue must be a chain of HARD REFUSALS, not an `&&` chain feeding a
# `;`-separated run. Arm (c) below is what actually catches the regression; this
# names the invariant at the point of emission so a future edit reads the rule
# without having to run the suite to discover it.
case "$K865_CMD" in
  "set -o pipefail || exit 1; cd "*" || exit 1; "*) : ;;
  *) fail "#865: the handed command must OPEN with 'set -o pipefail || exit 1' and hard-refuse a failed cd — an '&&'-chained prologue still runs the suite when cd fails: $K865_CMD" ;;
esac

# (a) GREEN suite → a finished sentinel with rc 0.
printf '#!/bin/sh\necho "OK — all 3 quality gate(s) passed in 4s"\nexit 0\n' > "$K865_ROOT/scripts/quality-gates.sh"
chmod +x "$K865_ROOT/scripts/quality-gates.sh"
rm -f "$K865_SENTINEL"
bash -c "$K865_CMD" >/dev/null 2>&1 || fail "#865: the handed command exited non-zero on a GREEN gate"
[ -f "$K865_SENTINEL" ] \
  || fail "#865: the handed command left NO result sentinel — an artifact poll can only succeed if the artifact exists"
grep -F '"state":"finished"' "$K865_SENTINEL" >/dev/null \
  || fail "#865: the sentinel does not report a finished state: $(cat "$K865_SENTINEL")"
grep -F '"rc":0' "$K865_SENTINEL" >/dev/null \
  || fail "#865: a green gate must record rc 0: $(cat "$K865_SENTINEL")"

# (b) RED suite → a finished sentinel carrying the gate's OWN non-zero status.
#     Without `set -o pipefail` the tee's 0 would be recorded and a red gate
#     would read green — the single worst thing this artifact could do.
printf '#!/bin/sh\necho "FAIL: two gates failed"\nexit 4\n' > "$K865_ROOT/scripts/quality-gates.sh"
rm -f "$K865_SENTINEL"
k865_rc=0
bash -c "$K865_CMD" >/dev/null 2>&1 || k865_rc=$?
[ "$k865_rc" -eq 4 ] \
  || fail "#865: the handed command must exit with the gate's own status (wanted 4, got $k865_rc)"
grep -F '"rc":4' "$K865_SENTINEL" >/dev/null \
  || fail "#865: a RED gate was recorded as rc $(sed -n 's/.*\"rc\":\([0-9]*\).*/\1/p' "$K865_SENTINEL") — the piped status swallowed the failure: $(cat "$K865_SENTINEL")"

# (c) A WORKTREE THAT DOES NOT EXIST → the command must refuse outright: non-zero
#     exit, NO sentinel, and — the part that actually bites — the suite must not
#     run at all. The round-1 shape `cd X && … && set -o pipefail; ./gates.sh …`
#     is not a guard: `A && B; C` skips B on A's failure but still runs C, so a
#     failed `cd` skipped the `running` write AND `set -o pipefail` and then ran
#     `./scripts/quality-gates.sh` in whatever directory the worker's shell
#     started in. A RED suite in the WRONG repo was then recorded as
#     {"state":"finished","rc":0} — the exact silent green this whole item
#     exists to remove. The decoy below is that wrong repo: a red gate script
#     sitting in the cwd the command is launched from, printing a marker that
#     must never appear.
K865_DECOY="$(mktemp -d "$WF_TEST_TMPDIR/k865-decoy-XXXXXX")"
mkdir -p "$K865_DECOY/scripts"
K865_DECOY_MARK="K865-RAN-IN-THE-WRONG-REPO"
printf '#!/bin/sh\necho "%s"\nexit 4\n' "$K865_DECOY_MARK" > "$K865_DECOY/scripts/quality-gates.sh"
chmod +x "$K865_DECOY/scripts/quality-gates.sh"
K865_GONE="$WF_TEST_TMPDIR/k865-worktree-that-does-not-exist"
[ ! -e "$K865_GONE" ] || fail "#865: the failed-cd arm needs a path that does not exist"
K865_CMD_GONE="$(k865_emit_cmd "$K865_GONE")" || fail "#865: could not emit the handed command for a missing worktree"
rm -f "$K865_SENTINEL"
k865_rc=0
k865_out="$(cd "$K865_DECOY" && bash -c "$K865_CMD_GONE" 2>&1)" || k865_rc=$?
[ "$k865_rc" -ne 0 ] \
  || fail "#865: a worktree that does not exist must make the handed command exit non-zero, got 0: $k865_out"
case "$k865_out" in
  *"$K865_DECOY_MARK"*) fail "#865: the handed command ran the gate suite OUTSIDE the worktree after a failed cd — a red suite in the wrong repo: $k865_out" ;;
esac
[ ! -f "$K865_SENTINEL" ] \
  || fail "#865: a failed cd must leave NO sentinel — a refusal that writes one is indistinguishable from a run: $(cat "$K865_SENTINEL")"
case "$k865_out" in
  *'"state":"finished"'*) fail "#865: a failed cd printed a finished sentinel — workerGateState() would read 'finished' and the 3e.5 'WORKER GATE NEVER FINISHED' notice would never fire: $k865_out" ;;
esac

# (d) NO GATE SCRIPT → exit 127 and NO sentinel, so the handed prompt's "that is
#     not a gate failure" bullet is TRUE of the shell. Before the round-2 fix,
#     pipefail turned the missing script into rc 127 and the next statement wrote
#     {"state":"finished","rc":127} unconditionally — which the SAME prompt's
#     stronger rule ("finished + non-zero rc is a real FAIL you can report")
#     told the worker to report as a gate failure. Two rules in one prompt
#     disagreed and the shell backed the wrong one.
rm -f "$K865_ROOT/scripts/quality-gates.sh"
rm -f "$K865_SENTINEL"
k865_rc=0
k865_out="$(bash -c "$K865_CMD" 2>&1)" || k865_rc=$?
[ "$k865_rc" -eq 127 ] \
  || fail "#865: a repo with no scripts/quality-gates.sh must exit 127, got $k865_rc: $k865_out"
[ ! -f "$K865_SENTINEL" ] \
  || fail "#865: a repo with no gate script must leave NO sentinel — the prompt tells the worker a missing gate writes none: $(cat "$K865_SENTINEL")"
# The 127 and the message are a PAIR: the handed prompt tells the worker that
# exit 127 + this stderr line is "no gate", not a gate failure, so a refusal
# that exits 127 silently would leave the worker guessing which of the three
# refusals it hit.
case "$k865_out" in
  *'no executable ./scripts/quality-gates.sh'*) : ;;
  *) fail "#865: the 127 refusal must NAME itself on stderr — the prompt keys 'not a gate failure' on that line: $k865_out" ;;
esac
case "$k865_out" in
  *'"state":"finished"'*) fail "#865: a missing gate script produced a finished sentinel — the worker would report a repo with no gate as a gate FAILURE: $k865_out" ;;
esac

rm -f "$K865_SENTINEL" "$K865_GATELOG"
rm -rf "$K865_ROOT" "$K865_DECOY"
echo "PASS: #865 executed shell — the handed gate invocation records the gate's OWN exit status (green + red arms) and REFUSES without a sentinel when the worktree is gone or the repo has no gate script"

# --- K865 static lockstep guards -------------------------------------------
grep -q 'function workerGateCmd' "$MJS" \
  || fail "#865: workerGateCmd() missing — the worker must be handed an invocation, not asked to compose one"
grep -q '\.\.\.workerGateSection(item.slug, worktreePath)' "$MJS" \
  || fail "#865: workerPrompt()'s returned array must splice in workerGateSection() — a defined-but-unused section never reaches the worker"
grep -q 'WORKER GATE NEVER FINISHED' "$MJS" \
  || fail "#865: the residual failure must be LOUD — a stalled worker has to read differently from a slow one"
grep -q 'function gateSentinelCure' "$MJS" \
  || fail "#865: the null-verdict re-spawn must hand over the sentinel PATH, not repeat the instruction that failed 2/2"
echo "PASS: #865 static guard — handed invocation, spliced prompt section, loud residual, sentinel-aware re-spawn cure"

# ============================================================================
# DEBT ROW (K2145): the worker's scoped-gate BUDGET is a KNOWINGLY HALF-SHIPPED
#   invariant, and this is the CI-read row that stops it aging silently.
#
#   WHAT SHIPPED: build.md §3c now tells the worker to run its scoped gate as
#   `QUALITY_GATES_BUDGET_SECS=<budget> scripts/quality-gates.sh --scoped`.
#   That reaches the conversational (`--no-workflow`) path and hand-authored
#   first worker prompts ONLY. workerPrompt()'s embedded copy still instructs
#   an UNBUDGETED --scoped run, and the Workflow path is build.md's DEFAULT —
#   so the dominant path stays exposed. Closing it here would collide head-on
#   with the in-flight build-level.mjs rewrite (temperloop#2141), so it is
#   deliberately deferred to temperloop#2147.
#
#   WHY THIS SHAPE AND NOT A REGISTRY ROW. The obvious home looked like
#   mandatory-step-registry.tsv's shrink-only `pending` ledger, but it cannot
#   hold this, on two independent grounds:
#     (1) SCHEMA. That gate keys a row on a DECLARATION line carrying a
#         mandatory marker (`mandatory`|`non-negotiable`|`not optional`|
#         `never skip`) that makes the EXECUTION OF A STEP obligatory. This is
#         not that: §3c's worker-spawn step runs on every item either way. What
#         drifted is one of TWO COPIES of an instruction that step carries —
#         a constraint on how the step BEHAVES, which
#         validate-mandatory-step-signal.sh's own § THE SCOPE DECISION (a)
#         lists as `excluded` by construction. The bullet carries no marker
#         word either, so discovery never enumerates it.
#     (2) MECHANICS. Its `pending` set is a shrink-only ratchet against
#         origin/HEAD: a row present now and absent at the base ref is
#         PENDING-GREW and FAILS. A brand-new pending row cannot be parked
#         there by design — see mandatory-step-discovery.tsv's own header.
#   So this uses the nearest REAL mechanism instead: the static lockstep-guard
#   idiom every sibling §3c clause already uses (K1530 changelog fragment,
#   K1319 self-verification, K1934 activation proof, K1219 foreground-only),
#   in its SELF-DISCHARGING variant. Same suite, same `make test-build` gate.
#
#   IT DISCHARGES ITSELF, IN BOTH DIRECTIONS:
#     gap OPEN   -> build.md §3c MUST carry the disclosure, and that disclosure
#                   MUST name temperloop#2147. Delete either and this goes red.
#     gap CLOSED -> workerPrompt() carries the budget, so the disclosure is now
#                   FALSE and MUST be retired. Land the workerPrompt half
#                   without retiring it and this goes red.
#   Neither "forgot to fix it" nor "fixed it and left a lying disclosure
#   behind" can pass. ----------------------------------------------------------
K2145_BUILD_MD="$REPO_ROOT/claude/commands/build.md"
[ -f "$K2145_BUILD_MD" ] \
  || fail "#2145: claude/commands/build.md is missing — the prose half of the worker gate budget cannot be verified"

# The half that DID ship: the literal, executable budgeted invocation, and the
# belt-and-suspenders setting reference. The fallback form is load-bearing —
# quality-gates.sh normalises an EMPTY QUALITY_GATES_BUDGET_SECS to 0, and 0
# means NO BUDGET, so a bare $BUILD_GATE_SLICE_SECS on a checkout that does not
# vendor build.config.sh silently reinstates the unbounded run.
grep -qF 'QUALITY_GATES_BUDGET_SECS=<budget> scripts/quality-gates.sh --scoped' "$K2145_BUILD_MD" \
  || fail "#2145: build.md §3c must carry the literal budgeted gate invocation the worker is told to run"
grep -qF '${BUILD_GATE_SLICE_SECS:-300}' "$K2145_BUILD_MD" \
  || fail "#2145: build.md §3c must name the budget in the belt-and-suspenders \${BUILD_GATE_SLICE_SECS:-300} form — a BARE \$BUILD_GATE_SLICE_SECS expands EMPTY where build.config.sh is not vendored, and quality-gates.sh reads an empty QUALITY_GATES_BUDGET_SECS as 0 = NO BUDGET APPLIED"

# The discriminator. QUALITY_GATES_BUDGET_SECS appears in build-level.mjs
# exactly ONCE today, at the PARENT-side §3e.5 slice loop, which has always
# been budgeted. So "more than one occurrence" means the worker-facing half has
# landed — robust to however temperloop#2147 eventually writes it (one line, or
# several concatenated prompt fragments). The >=1 assertion keeps the
# discriminator from going stale unnoticed if that parent-side site is ever
# renamed or removed.
K2145_MJS_BUDGET_HITS="$(grep -c 'QUALITY_GATES_BUDGET_SECS' "$MJS" || true)"
[ "${K2145_MJS_BUDGET_HITS:-0}" -ge 1 ] \
  || fail "#2145: build-level.mjs no longer mentions QUALITY_GATES_BUDGET_SECS at all — the parent-side §3e.5 slice budget this debt row's discriminator is calibrated against is gone. Recalibrate this row rather than letting it read 'gap open' by accident"

K2145_DISCLOSURE='The BUDGET half of this bullet is not yet in lockstep'
if [ "$K2145_MJS_BUDGET_HITS" -gt 1 ]; then
  # NB: written as an `if`, never `grep ... && fail ...` — this file runs under
  # `set -e`, where an AND-list whose grep finds nothing returns non-zero and
  # would abort the suite on the SUCCESS path.
  if grep -qF "$K2145_DISCLOSURE" "$K2145_BUILD_MD"; then
    fail "#2145: build-level.mjs now carries a worker-facing QUALITY_GATES_BUDGET_SECS, so build.md §3c's 'not yet in lockstep' disclosure is FALSE. Retire the disclosure AND this debt row in the same change that closed the gap (temperloop#2147), and replace them with an ordinary static lockstep guard in the K1530/K1934 shape"
  fi
  echo "PASS: #2145 worker gate budget — workerPrompt() carries the budget and build.md §3c's known-gap disclosure has been retired; this debt row is discharged and should now be replaced by a plain lockstep guard"
else
  grep -qF "$K2145_DISCLOSURE" "$K2145_BUILD_MD" \
    || fail "#2145: build-level.mjs does NOT carry a worker-facing QUALITY_GATES_BUDGET_SECS, so the Workflow path — build.md's DEFAULT execution path — still spawns workers with an unbudgeted scoped gate. build.md §3c MUST keep the known-gap disclosure that says so; an undisclosed half-shipped invariant on the dominant path is exactly what this row exists to prevent"
  grep -qF 'temperloop#2147' "$K2145_BUILD_MD" \
    || fail "#2145: build.md §3c's known-gap disclosure must name temperloop#2147 as the discharging issue — a gap with no tracked owner is the debt that ages silently"
  echo "PASS: #2145 worker gate budget debt row — conversational-path budget shipped and pinned; Workflow-path gap is OPEN, disclosed in build.md §3c, and tracked to temperloop#2147 (this row flips red the moment workerPrompt() closes it without retiring the disclosure)"
fi

# temperloop#2083 — the LEVEL PICK and the two operator levers
#
# Phase 4 turns the barrier's comparison into a merge decision. Every case below
# is one acceptance bullet: the pre-registered tally, the winner's route to
# PR/CI, the calibration-gated confirm, the per-item override, the arms trailer
# (and the merge block when it is missing), the archive-then-delete ordering,
# the winning-arm-lost re-drive, and the post-pick CI record.
# ============================================================================

run_node_case "K2083 tally 2-1: the pre-registered tally makes the judge-preferred arm the level winner, and ONLY that arm's branches reach push/PR" "
$PREAMBLE
$DUAL_FIXTURE

calibrated();
// p1 and p2 go to arm A (baseline); p3 goes to arm B (candidate) → 2-1.
for (const [s, pref, pr] of [['p1','A',301],['p2','A',302],['p3','B',303]]) {
  winningArm(s, 'baseline', pr, 'abc' + pr);
  greenArm(s, 'candidate');
  itemBarrier(s, { outcome: 'JUDGED', judge: { preference: pref, margin: 20, order_agreement: true } });
  pickPhase(s);
}

globalThis.args = { ...dualArgs(['p1','p2','p3']), items: [
  { slug: 'p1', branch: 'build/p1', title: 'P1', kind: 'impl', acceptance: ['c'] },
  { slug: 'p2', branch: 'build/p2', title: 'P2', kind: 'impl', acceptance: ['c'] },
  { slug: 'p3', branch: 'build/p3', title: 'P3', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();

const pick = result.dualBuild.pick;
if (!pick)
  { console.log(JSON.stringify({ ok: false, reason: 'the level returned no pick: ' + JSON.stringify(result.dualBuild) })); process.exit(0); }
if (pick.tally.baseline !== 2 || pick.tally.candidate !== 1 || pick.tally.unresolved !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'tally wrong: ' + JSON.stringify(pick.tally) })); process.exit(0); }
if (pick.winner !== 'baseline' || pick.level !== 'baseline' || pick.reason !== 'tally')
  { console.log(JSON.stringify({ ok: false, reason: 'a 2-1 tally must elect the majority arm: ' + JSON.stringify(pick) })); process.exit(0); }

// ONLY the winning arm's branches are pushed / PR'd — including p3's, whose own
// judge preferred the other arm. The unit of CHOICE is the LEVEL (ADR 0038).
const prArms = callLog.filter(c => /^pr-batch:/.test(String(c.opts.label))).map(c => String(c.opts.label).split(':')[1]).sort();
if (prArms.join(',') !== 'p1@baseline,p2@baseline,p3@baseline')
  { console.log(JSON.stringify({ ok: false, reason: 'the wrong arms reached the PR phase: ' + JSON.stringify(prArms) })); process.exit(0); }
if ((result.parked ?? []).map(p => p.slug).sort().join(',') !== 'p1,p2,p3')
  { console.log(JSON.stringify({ ok: false, reason: 'routed items must park under the ITEM slug, never the arm slug: ' + JSON.stringify(result) })); process.exit(0); }
const p1 = (result.parked ?? []).find(p => p.slug === 'p1');
if (p1.pr !== 301 || p1.pushed_sha !== 'abc301')
  { console.log(JSON.stringify({ ok: false, reason: 'the winning arm did not go through the ordinary PR path: ' + JSON.stringify(p1) })); process.exit(0); }
if (p1.dual_build.barrier !== 'cleared' || p1.dual_build.awaiting !== null || p1.dual_build.pick.arm !== 'baseline')
  { console.log(JSON.stringify({ ok: false, reason: 'the routed record must record the cleared barrier and its pick: ' + JSON.stringify(p1.dual_build) })); process.exit(0); }
if (result.dualBuild.barrier !== 'cleared' || result.dualBuild.awaiting !== null)
  { console.log(JSON.stringify({ ok: false, reason: 'the level summary still reports a held barrier: ' + JSON.stringify(result.dualBuild) })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

run_node_case "K2083 tally tie: a 1-1-with-a-judged-tie level goes to the CHEAPER arm by whole-job cost, and a judged tie counts for neither arm" "
$PREAMBLE
$DUAL_FIXTURE

calibrated();
// q1 → baseline, q2 → candidate, q3 → a judged TIE (counts for neither).
// Tally is therefore 1-1 with one unresolved, and the tie-break is cost.
// The CANDIDATE arm is made cheaper on every item, so it must win.
for (const [s, pref, pr] of [['q1','A',401],['q2','B',402],['q3','tie',403]]) {
  winningArm(s, 'baseline', pr, 'abc' + pr);
  winningArm(s, 'candidate', pr, 'abc' + pr);
  itemBarrier(s, { outcome: 'JUDGED', judge: { preference: pref, margin: 5, order_agreement: pref !== 'tie' } });
  pickPhase(s);
  setWorkerUsage(s + '@baseline', { outcome: 'WORKER_USAGE', epoch_s: 1000, usage_source: 'envelope', input_tokens: 900, output_tokens: 900 });
  setWorkerUsage(s + '@candidate', { outcome: 'WORKER_USAGE', epoch_s: 1000, usage_source: 'envelope', input_tokens: 100, output_tokens: 100 });
}

globalThis.args = { ...dualArgs(['q1','q2','q3']), items: [
  { slug: 'q1', branch: 'build/q1', title: 'Q1', kind: 'impl', acceptance: ['c'] },
  { slug: 'q2', branch: 'build/q2', title: 'Q2', kind: 'impl', acceptance: ['c'] },
  { slug: 'q3', branch: 'build/q3', title: 'Q3', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();

const pick = result.dualBuild.pick;
if (pick.tally.baseline !== 1 || pick.tally.candidate !== 1 || pick.tally.unresolved !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'a judged tie must count for NEITHER arm: ' + JSON.stringify(pick.tally) })); process.exit(0); }
if ((pick.items.find(i => i.slug === 'q3') || {}).reason !== 'judged-tie')
  { console.log(JSON.stringify({ ok: false, reason: 'the tie item must be named as unresolved-by-tie: ' + JSON.stringify(pick.items) })); process.exit(0); }
if (pick.winner !== 'candidate' || pick.reason !== 'tally-tie-cheaper')
  { console.log(JSON.stringify({ ok: false, reason: 'a tally tie must go to the cheaper arm: ' + JSON.stringify(pick) })); process.exit(0); }
if (pick.cost.candidate.tokens !== 600 || pick.cost.baseline.tokens !== 5400)
  { console.log(JSON.stringify({ ok: false, reason: 'the tie-break must read WHOLE-JOB cost across the level: ' + JSON.stringify(pick.cost) })); process.exit(0); }
const prArms = callLog.filter(c => /^pr-batch:/.test(String(c.opts.label))).map(c => String(c.opts.label).split(':')[1]).sort();
if (prArms.join(',') !== 'q1@candidate,q2@candidate,q3@candidate')
  { console.log(JSON.stringify({ ok: false, reason: 'the cheaper arm was not the one routed: ' + JSON.stringify(prArms) })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

run_node_case "K2083 calibration gate: an UNCALIBRATED judge HOLDS the level — a level-pick escalation with NO default, and not one PR opens" "
$PREAMBLE
$DUAL_FIXTURE

uncalibrated();
winningArm('u1', 'baseline', 501, 'abc501');
greenArm('u1', 'candidate');
itemBarrier('u1');
pickPhase('u1');

globalThis.args = { ...dualArgs(['u1']), items: [
  { slug: 'u1', branch: 'build/u1', title: 'U1', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();

const esc = (result.escalations ?? []).find(e => e.slug === 'u1');
if (!esc || esc.kind !== 'level-pick')
  { console.log(JSON.stringify({ ok: false, reason: 'an uncalibrated level must raise a level-pick escalation: ' + JSON.stringify(result) })); process.exit(0); }
if (esc.payload.confirm_required !== true || esc.payload.default !== null)
  { console.log(JSON.stringify({ ok: false, reason: 'the confirm must be explicit, with NO default: ' + JSON.stringify(esc.payload) })); process.exit(0); }
if (!/confirm \\| override-level <arm> \\| override-item <slug> <arm>/.test(String(esc.payload.verdict_grammar)))
  { console.log(JSON.stringify({ ok: false, reason: 'the escalation must carry the verdict grammar: ' + JSON.stringify(esc.payload.verdict_grammar) })); process.exit(0); }
if (esc.payload.calibration.status !== 'uncalibrated')
  { console.log(JSON.stringify({ ok: false, reason: 'the escalation must name the calibration state it is gating on: ' + JSON.stringify(esc.payload.calibration) })); process.exit(0); }
// NOT ONE PR — asserted on the spawn, not just the steps.
if (callLog.some(c => /^(pr-batch|ci-batch|stamp-arms|archive-loser):/.test(String(c.opts.label))))
  { console.log(JSON.stringify({ ok: false, reason: 'the held level opened a PR anyway: ' + JSON.stringify(callLog.map(c => c.opts.label)) })); process.exit(0); }
if (result.dualBuild.pick.held !== true || result.dualBuild.barrier !== 'held')
  { console.log(JSON.stringify({ ok: false, reason: 'a held level must say so on its summary: ' + JSON.stringify(result.dualBuild) })); process.exit(0); }
// The worktrees are intact — that is what makes the confirm answerable.
if ((esc.payload.worktrees_intact ?? []).length !== 2)
  { console.log(JSON.stringify({ ok: false, reason: 'the escalation must name both arms\\' worktrees: ' + JSON.stringify(esc.payload.worktrees_intact) })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

run_node_case "K2083 confirm: the same UNCALIBRATED level routes once input.levelPick carries an explicit confirm — the gate discriminates on the answer, not on the calibration alone" "
$PREAMBLE
$DUAL_FIXTURE

uncalibrated();
winningArm('v1', 'baseline', 601, 'abc601');
greenArm('v1', 'candidate');
itemBarrier('v1');
pickPhase('v1');

globalThis.args = { ...dualArgs(['v1']), levelPick: { verdict: 'confirm' }, items: [
  { slug: 'v1', branch: 'build/v1', title: 'V1', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();

if ((result.escalations ?? []).some(e => e.kind === 'level-pick'))
  { console.log(JSON.stringify({ ok: false, reason: 'an answered level must not re-ask: ' + JSON.stringify(result.escalations) })); process.exit(0); }
const v1 = (result.parked ?? []).find(p => p.slug === 'v1');
if (!v1 || v1.pr !== 601)
  { console.log(JSON.stringify({ ok: false, reason: 'the confirmed pick did not route: ' + JSON.stringify(result) })); process.exit(0); }
if (result.dualBuild.pick.confirmed !== true || result.dualBuild.pick.confirm_required !== true)
  { console.log(JSON.stringify({ ok: false, reason: 'the summary must record BOTH that a confirm was required and that it was given: ' + JSON.stringify(result.dualBuild.pick) })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

run_node_case "K2083 per-item override: the level records mixed, the item's row records override scope item, a calibration pair is written from the override, and that item ships the OTHER arm" "
$PREAMBLE
$DUAL_FIXTURE

calibrated();
// Both items' judges prefer arm A; the operator overrides w2 to the candidate.
for (const [s, pr] of [['w1',701],['w2',702]]) {
  winningArm(s, 'baseline', pr, 'abc' + pr);
  winningArm(s, 'candidate', pr, 'abc' + pr);
  itemBarrier(s, { outcome: 'JUDGED', judge: { preference: 'A', margin: 30, order_agreement: true } });
}
pickPhase('w1');
pickPhase('w2', { pair: { outcome: 'CALIBRATION_PAIR_RECORDED' } });

globalThis.args = { ...dualArgs(['w1','w2']),
  levelPick: { verdict: 'override-item', items: [{ slug: 'w2', arm: 'candidate', reason: 'the candidate diff is the one I want' }] },
  items: [
    { slug: 'w1', branch: 'build/w1', title: 'W1', kind: 'impl', acceptance: ['c'] },
    { slug: 'w2', branch: 'build/w2', title: 'W2', kind: 'impl', acceptance: ['c'] },
  ]};

const mod = await loadLevel();
const result = await mod.default();

if (result.dualBuild.pick.level !== 'mixed')
  { console.log(JSON.stringify({ ok: false, reason: 'a per-item override must make the LEVEL pick mixed: ' + JSON.stringify(result.dualBuild.pick) })); process.exit(0); }
// w1 keeps the tally winner, w2 takes the override.
const prArms = callLog.filter(c => /^pr-batch:/.test(String(c.opts.label))).map(c => String(c.opts.label).split(':')[1]).sort();
if (prArms.join(',') !== 'w1@baseline,w2@candidate')
  { console.log(JSON.stringify({ ok: false, reason: 'the override did not move exactly the named item: ' + JSON.stringify(prArms) })); process.exit(0); }
// The ROW records it.
const row = pickRow('w2');
if (!row || !row.override || row.override.applied !== true || row.override.scope !== 'item')
  { console.log(JSON.stringify({ ok: false, reason: \"the overridden item's row must carry override scope item: \" + JSON.stringify(row) })); process.exit(0); }
if (!row.pick || row.pick.arm !== 'candidate' || row.pick.level !== 'mixed')
  { console.log(JSON.stringify({ ok: false, reason: 'the pick row must carry the arm AND the mixed level: ' + JSON.stringify(row) })); process.exit(0); }
const un = pickRow('w1');
if (!un || un.override.applied !== false || un.pick.arm !== 'baseline')
  { console.log(JSON.stringify({ ok: false, reason: 'an un-overridden item must record no override: ' + JSON.stringify(un) })); process.exit(0); }
// The CALIBRATION PAIR — written from the override, sourced as such.
const pair = callLog.find(c => String(c.opts.label) === 'level-pick-calibrate:w2');
if (!pair)
  { console.log(JSON.stringify({ ok: false, reason: 'a per-item override must write a calibration pair' })); process.exit(0); }
if (!/calibrate-record/.test(pair.promptFull) || !/--source override/.test(pair.promptFull) || !/--preference 'candidate'/.test(pair.promptFull))
  { console.log(JSON.stringify({ ok: false, reason: 'the pair must be recorded as an OVERRIDE-sourced human preference: ' + pair.promptFull.slice(0, 400) })); process.exit(0); }
if (callLog.some(c => String(c.opts.label) === 'level-pick-calibrate:w1'))
  { console.log(JSON.stringify({ ok: false, reason: 'an un-overridden item must not write a calibration pair' })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

run_node_case "K2083 arms trailer: the winning PR is stamped via stamp-arms, and a stamp that cannot be verified BLOCKS the merge rather than shipping an undisclosed comparison" "
$PREAMBLE
$DUAL_FIXTURE

calibrated();
winningArm('x1', 'baseline', 801, 'abc801');
greenArm('x1', 'candidate');
itemBarrier('x1');
pickPhase('x1');
winningArm('x2', 'baseline', 802, 'abc802');
greenArm('x2', 'candidate');
itemBarrier('x2');
pickPhase('x2', { stamp: { outcome: 'ARMS_STAMP_FAILED', reason: 'parse-arms could not verify the appended trailer' } });

globalThis.args = { ...dualArgs(['x1','x2']), items: [
  { slug: 'x1', branch: 'build/x1', title: 'X1', kind: 'impl', acceptance: ['c'] },
  { slug: 'x2', branch: 'build/x2', title: 'X2', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();

const stampCall = callLog.find(c => String(c.opts.label) === 'stamp-arms:x1');
if (!stampCall)
  { console.log(JSON.stringify({ ok: false, reason: 'the winning PR was never stamped' })); process.exit(0); }
if (!/tagging\\.sh/.test(stampCall.promptFull) || !/stamp-arms --baseline 'model-base' --candidate 'model-cand' --pick 'baseline'/.test(stampCall.promptFull))
  { console.log(JSON.stringify({ ok: false, reason: 'the stamp must go through tagging.sh stamp-arms with both arms and the pick: ' + stampCall.promptFull.slice(0, 500) })); process.exit(0); }
if (!/parse-arms/.test(stampCall.promptFull))
  { console.log(JSON.stringify({ ok: false, reason: \"the stamp must be VERIFIED with the emitter's own inverse: \" + stampCall.promptFull.slice(0, 500) })); process.exit(0); }

const x1 = (result.parked ?? []).find(p => p.slug === 'x1');
if ('merge_blocked' in x1 || x1.dual_build.pick.stamped !== true)
  { console.log(JSON.stringify({ ok: false, reason: 'a successfully stamped PR must NOT be merge-blocked: ' + JSON.stringify(x1) })); process.exit(0); }
const x2 = (result.parked ?? []).find(p => p.slug === 'x2');
if (x2.merge_blocked !== 'arms-trailer-unstamped' || x2.dual_build.pick.stamped !== false)
  { console.log(JSON.stringify({ ok: false, reason: 'an unstamped PR must block its own merge: ' + JSON.stringify(x2) })); process.exit(0); }
if ((result.dualBuild.pick.merge_blocked ?? []).join(',') !== 'x2')
  { console.log(JSON.stringify({ ok: false, reason: 'the level summary must name every merge-blocked item: ' + JSON.stringify(result.dualBuild.pick) })); process.exit(0); }
if (pickRow('x1').arms_trailer_stamped !== true || pickRow('x2').arms_trailer_stamped !== false)
  { console.log(JSON.stringify({ ok: false, reason: 'the pick row must record whether the trailer landed: ' + JSON.stringify([pickRow('x1'), pickRow('x2')]) })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

run_node_case "K2083 losing arm: the branch is deleted ONLY after archive-check succeeds — a failed check keeps the branch, and the emitted shell orders archive → archive-check → delete" "
$PREAMBLE
$DUAL_FIXTURE

calibrated();
winningArm('y1', 'baseline', 901, 'abc901');
greenArm('y1', 'candidate');
itemBarrier('y1');
pickPhase('y1');
winningArm('y2', 'baseline', 902, 'abc902');
greenArm('y2', 'candidate');
itemBarrier('y2');
pickPhase('y2', { loser: { outcome: 'LOSER_KEPT', reason: 'archive-check-failed' } });

globalThis.args = { ...dualArgs(['y1','y2']), items: [
  { slug: 'y1', branch: 'build/y1', title: 'Y1', kind: 'impl', acceptance: ['c'] },
  { slug: 'y2', branch: 'build/y2', title: 'Y2', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();

const cmd = (callLog.find(c => String(c.opts.label) === 'archive-loser:y1') || {}).promptFull ?? '';
if (!cmd)
  { console.log(JSON.stringify({ ok: false, reason: 'the losing arm was never archived' })); process.exit(0); }
const iArchive = cmd.indexOf(\"archive 'y1' 'candidate'\");
const iCheck = cmd.indexOf(\"archive-check 'y1' 'candidate'\");
const iDelete = cmd.indexOf('branch -D');
if (iArchive < 0 || iCheck < 0 || iDelete < 0)
  { console.log(JSON.stringify({ ok: false, reason: 'archive / archive-check / delete are not all present: ' + cmd.slice(0, 800) })); process.exit(0); }
if (!(iArchive < iCheck && iCheck < iDelete))
  { console.log(JSON.stringify({ ok: false, reason: 'the ordering is not archive → archive-check → delete: ' + JSON.stringify({ iArchive, iCheck, iDelete }) })); process.exit(0); }
if (!/--force|-f\\b/.test(cmd.slice(iDelete - 120, iDelete)) === false)
  { console.log(JSON.stringify({ ok: false, reason: 'the removal must not force past git\\'s own refusal' })); process.exit(0); }

const y1 = (result.parked ?? []).find(p => p.slug === 'y1');
if (y1.dual_build.pick.loser.archived !== true || y1.dual_build.pick.loser.deleted !== true)
  { console.log(JSON.stringify({ ok: false, reason: 'a verified archive must let the branch go: ' + JSON.stringify(y1.dual_build.pick.loser) })); process.exit(0); }
const y2 = (result.parked ?? []).find(p => p.slug === 'y2');
if (y2.dual_build.pick.loser.archived !== false || y2.dual_build.pick.loser.deleted !== false || y2.dual_build.pick.loser.reason !== 'archive-check-failed')
  { console.log(JSON.stringify({ ok: false, reason: 'a FAILED archive-check must KEEP the branch, named: ' + JSON.stringify(y2.dual_build.pick.loser) })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

run_node_case "K2083 winning-arm-lost: the item is re-driven ONCE on the winning arm's OWN model and parks incomplete when that still fails — the losing arm is never shipped in its place" "
$PREAMBLE
$DUAL_FIXTURE

calibrated();
// z1 elects the level winner (baseline) on its own judge verdict.
winningArm('z1', 'baseline', 1001, 'abc1001');
greenArm('z1', 'candidate');
itemBarrier('z1', { outcome: 'JUDGED', judge: { preference: 'A', margin: 50, order_agreement: true } });
pickPhase('z1');
// z2's BASELINE arm gate-failed, so the level's winning arm lost this item. Its
// candidate arm is green — and must NOT be what ships. The re-drive gets ONE
// more queued attempt, which fails too.
greenArm('z2', 'baseline', { gate: { outcome: 'GATE_FAIL', failed: 1 } });
greenArm('z2', 'candidate');
addMachinery('z2@baseline',
  { outcome: 'CREATED', path: '/tmp/repo.wt/z2@baseline', base: 'base-z2', guard: 'ARMED' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_FAIL', failed: 1 },
);
itemBarrier('z2', { outcome: 'JUDGE_UNAVAILABLE', reason: 'never-called' });

globalThis.args = { ...dualArgs(['z1','z2']), items: [
  { slug: 'z1', branch: 'build/z1', title: 'Z1', kind: 'impl', acceptance: ['c'] },
  { slug: 'z2', branch: 'build/z2', title: 'Z2', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();

if (result.dualBuild.pick.level !== 'baseline')
  { console.log(JSON.stringify({ ok: false, reason: 'the level winner is not what this fixture sets up: ' + JSON.stringify(result.dualBuild.pick) })); process.exit(0); }
// Re-driven ONCE: exactly two baseline-arm worker spawns for z2 across the run.
const z2Workers = callLog.filter(c => isWorkerCall(c.opts) && String(c.opts.label) === 'worker:z2@baseline');
if (z2Workers.length !== 2)
  { console.log(JSON.stringify({ ok: false, reason: 'the winning-arm-lost item must be re-driven exactly ONCE: ' + z2Workers.length + ' spawn(s)' })); process.exit(0); }
if (z2Workers.some(c => c.opts.model !== 'model-base'))
  { console.log(JSON.stringify({ ok: false, reason: \"the re-drive must stay on the WINNING arm's own model: \" + JSON.stringify(z2Workers.map(c => c.opts.model)) })); process.exit(0); }
// It parks INCOMPLETE, with no PR, and the losing arm is not shipped.
const z2 = (result.parked ?? []).find(p => p.slug === 'z2');
if (!z2 || z2.incomplete !== true || z2.pr !== null)
  { console.log(JSON.stringify({ ok: false, reason: 'a twice-failed winning arm must park incomplete with no PR: ' + JSON.stringify(z2) })); process.exit(0); }
if (z2.dual_build.pick.outcome !== 'incomplete' || z2.dual_build.pick.re_driven !== true)
  { console.log(JSON.stringify({ ok: false, reason: 'the incomplete park must name the re-drive it already spent: ' + JSON.stringify(z2.dual_build.pick) })); process.exit(0); }
if (callLog.some(c => String(c.opts.label) === 'pr-batch:z2@candidate'))
  { console.log(JSON.stringify({ ok: false, reason: \"the LOSING arm was shipped in the winner's place — that silently reverses the level's own pick\" })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

run_node_case "K2083 post-pick CI: a CI failure after the pick is recorded AGAINST THE ARM on the pick row, and the item escalates under the ITEM slug" "
$PREAMBLE
$DUAL_FIXTURE

calibrated();
// CI goes red, the one-shot CI-fix round runs, and CI is red again — the
// budget is spent, so the item escalates ci-failed AFTER the pick routed it.
winningArm('k1', 'baseline', 1101, 'abc1101', { ci: [
  { outcome: 'CI_FAILED', failed_run_ids: [9101] },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'PUSHED', sha: 'abc1102', branch: 'build/k1@baseline' },
  { outcome: 'CI_FAILED', failed_run_ids: [9102] },
] });
setWorker('k1@baseline',
  { status: 'done', summary: 'initial', acceptance_results: [{ criterion: 'c', passed: true, evidence: 'e' }], commits: [] },
  { status: 'done', summary: 'ci fix', acceptance_results: [], commits: [] });
greenArm('k1', 'candidate');
itemBarrier('k1');
pickPhase('k1');

globalThis.args = { ...dualArgs(['k1']), items: [
  { slug: 'k1', branch: 'build/k1', title: 'K1', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();

const esc = (result.escalations ?? []).find(e => e.slug === 'k1');
if (!esc || !/^ci-/.test(String(esc.kind)))
  { console.log(JSON.stringify({ ok: false, reason: 'a post-pick CI failure must escalate under the ITEM slug: ' + JSON.stringify(result.escalations) })); process.exit(0); }
const row = pickRow('k1');
if (!row || row.post_pick_ci !== 'failed')
  { console.log(JSON.stringify({ ok: false, reason: 'the pick row must record the post-pick CI outcome: ' + JSON.stringify(row) })); process.exit(0); }
if (row.arm !== 'baseline' || row.loss_reason !== 'gate')
  { console.log(JSON.stringify({ ok: false, reason: 'the failure must be recorded against the ARM that shipped: ' + JSON.stringify(row) })); process.exit(0); }
if (!esc.payload.dual_build || esc.payload.dual_build.pick.post_pick_ci !== 'failed')
  { console.log(JSON.stringify({ ok: false, reason: 'the escalation must carry the pick it came from: ' + JSON.stringify(esc.payload.dual_build) })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

run_node_case "K2083 levelPick input: an override naming a slug this level never built REFUSES — a mistyped slug is a typo, not a silent no-op" "
$PREAMBLE
$DUAL_FIXTURE

calibrated();
winningArm('bad3', 'baseline', 1301, 'abc1301');
greenArm('bad3', 'candidate');
itemBarrier('bad3');

globalThis.args = { ...dualArgs(['bad3']), levelPick: { verdict: 'override-item', items: [{ slug: 'bad3-typo', arm: 'candidate', reason: 'r' }] }, items: [
  { slug: 'bad3', branch: 'build/bad3', title: 'Bad3', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();

const esc = (result.escalations ?? []).find(e => e.slug === 'bad3');
if (!esc || esc.kind !== 'level-pick-input-invalid')
  { console.log(JSON.stringify({ ok: false, reason: 'an override naming an unknown slug must REFUSE, never silently fall back to the tally: ' + JSON.stringify(result) })); process.exit(0); }
if (!/bad3-typo/.test(String(esc.payload.reason)) || !/in scope/.test(String(esc.payload.reason)))
  { console.log(JSON.stringify({ ok: false, reason: 'the refusal must name the unknown slug AND what IS in scope: ' + JSON.stringify(esc.payload) })); process.exit(0); }
if (callLog.some(c => /^(pr-batch|stamp-arms):/.test(String(c.opts.label))))
  { console.log(JSON.stringify({ ok: false, reason: 'a refused pick must route nothing: ' + JSON.stringify(callLog.map(c => c.opts.label)) })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

run_node_case "K2083 levelPick input: a present-but-unusable levelPick REFUSES to route rather than silently discarding the operator's override" "
$PREAMBLE
$DUAL_FIXTURE

calibrated();
winningArm('bad2', 'baseline', 1201, 'abc1201');
greenArm('bad2', 'candidate');
itemBarrier('bad2');

globalThis.args = { ...dualArgs(['bad2']), levelPick: { verdict: 'override-level' }, items: [
  { slug: 'bad2', branch: 'build/bad2', title: 'Bad2', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();

const esc = (result.escalations ?? []).find(e => e.slug === 'bad2');
if (!esc || esc.kind !== 'level-pick-input-invalid')
  { console.log(JSON.stringify({ ok: false, reason: 'a malformed levelPick must REFUSE: ' + JSON.stringify(result) })); process.exit(0); }
if (!/arm/.test(String(esc.payload.reason)))
  { console.log(JSON.stringify({ ok: false, reason: 'the refusal must name what is missing: ' + JSON.stringify(esc.payload) })); process.exit(0); }
if (callLog.some(c => /^(pr-batch|stamp-arms):/.test(String(c.opts.label))))
  { console.log(JSON.stringify({ ok: false, reason: 'a refused pick must route nothing: ' + JSON.stringify(callLog.map(c => c.opts.label)) })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# --- temperloop#2083 static guards ------------------------------------------
# The cases above prove the behaviour. These pin the STRUCTURAL facts a future
# edit could undo while every case still passed.
grep -q 'function tallyLevelPick' "$MJS" \
  || fail "#2083: build-level.mjs has no tallyLevelPick — the level pick's rules must live in one named, pre-registered place, not inline at the routing site"
grep -q 'function driveLevelPick' "$MJS" \
  || fail "#2083: build-level.mjs has no driveLevelPick — phase 4 is not a callable boundary"
grep -q "'level-pick'" "$MJS" \
  || fail "#2083: build-level.mjs raises no level-pick escalation — the calibration-gated confirm has no surface"
grep -q 'calibrationBarMet' "$MJS" \
  || fail "#2083: build-level.mjs has no calibration bar read — the confirm gate would be unconditional"
# FAIL-CLOSED: an unreadable calibration seam must NOT read as calibrated.
K2083_CAL="$(awk '/^function calibrationBarMet/,/^\}$/' "$MJS")"
printf '%s' "$K2083_CAL" | grep -F "cal.available" >/dev/null \
  || fail "#2083: calibrationBarMet ignores whether the calibration read succeeded — an unreachable seam would auto-route a level's merges"
# The pick must route through the EXISTING PR boundary, never a second copy.
K2083_ROUTE="$(awk '/^async function routePickedItem/,/^\}$/' "$MJS")"
printf '%s' "$K2083_ROUTE" | grep -F 'driveItemPr(winner.ctx)' >/dev/null \
  || fail "#2083: routePickedItem does not hand the winning arm to driveItemPr — the winner must take the ordinary PR/CI/park path, not a parallel one"
printf '%s' "$K2083_ROUTE" | grep -F 'archiveLosingArm' >/dev/null \
  || fail "#2083: routePickedItem never archives the losing arm — a deleted branch with no verified patch is unrecoverable"
# build.md must carry the handler prose (the class-A activation predicate).
# SECTION-SCOPED, not a bare `level-pick` grep: that token also appears in the
# hand-off contract's conditional-key sentence, so a bare grep would sit green
# with the HANDLER itself deleted — the one thing an orchestrator actually
# reads to dispose of this kind.
K2083_BMD="$(grep -F -- '**`level-pick` — the LEVEL-scoped escalation' "$REPO_ROOT/claude/commands/build.md" || true)"
[ -n "$K2083_BMD" ] \
  || fail "#2083: claude/commands/build.md carries no level-pick HANDLER paragraph — the escalation would reach an orchestrator with no disposition for it"
printf '%s' "$K2083_BMD" | grep -F 'override-item <slug> <arm>' >/dev/null \
  || fail "#2083: build.md's level-pick handler does not state the verdict grammar the workflow parses — the operator would be asked in words levelPickInput() refuses"
printf '%s' "$K2083_BMD" | grep -F 'no PR opened for any in-scope item' >/dev/null \
  || fail "#2083: build.md's level-pick handler does not say the level holds with NO PR opened — the whole point of the calibration gate"
# Same section-scoping for the merge-block disposition: `merge_blocked` also
# appears inside the handler paragraph above, so a bare grep would sit green
# with the DISPOSITION deleted.
K2083_MB="$(grep -F -- 'is INELIGIBLE for Step 4' "$REPO_ROOT/claude/commands/build.md" || true)"
[ -n "$K2083_MB" ] \
  || fail "#2083: build.md gives no disposition for a merge_blocked item — an unstamped dual-built PR would reach Step 4's gate with nothing telling it to stop"
printf '%s' "$K2083_MB" | grep -F 'arms-trailer-unstamped' >/dev/null \
  || fail "#2083: build.md's merge-block disposition does not name the literal value build-level.mjs stamps, so the gate has nothing to match on"
# The presentation-plane row is pinned by its OWNER pointer, not by the kind
# name: `level-pick` also occurs inside the row as part of
# `level-pick-input-invalid`, so a bare grep survives the row being renamed.
grep -F 'driveLevelPick' "$REPO_ROOT/claude/presentation-plane.md" >/dev/null \
  || fail "#2083: claude/presentation-plane.md has no row pointing at the level-pick kind's owner — a style template could restyle the verdict grammar the workflow parses"
echo "PASS: #2083 static guards — the tally, the fail-closed calibration bar, the shared PR boundary, the loser archive, and both prose surfaces are wired"

echo ""
echo "All test_workflow.sh cases passed."
