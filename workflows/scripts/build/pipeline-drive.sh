#!/usr/bin/env bash
#
# pipeline-drive.sh — the autonomous pipeline driver's LAYER-5b + 5c EXECUTOR
# (foundation #604, #615). Level 5a is EMIT-ONLY: pipeline-tick.sh decides a tick
# plan, pipeline-cron.sh logs + notifies, and the OPERATOR executes by hand. 5b
# auto-executes the emitted actions — but ONLY the SAFE tier that can never merge
# code — by handing them to a headless `claude -p "/pipeline-drive …"` driver
# (claude/commands/pipeline-drive.md). 5c (opt-in, a SEPARATE gate) additionally
# auto-executes the MERGING tier via `claude -p "/pipeline-drive-merge …"`, which
# drives each kind:code item through /build's own gated merge. See
# `Decisions/foundation - Pipeline level 5b: headless safe-actions-only auto-drive`
# and `Decisions/foundation - Pipeline level 5c supervised auto-merge tier`.
#
# THE SAFE/MERGING SPLIT:
#
#   SAFE — auto-executed headlessly (no PR, no merge), always when invoked:
#     route-foundational · drain-answer · drain-parse-miss · drain-clarification
#     · retro-judge · drive-ready WHERE kind == "spike"   (build.md kind:spike
#       path: writes a verdict note + routes a follow-up; opens no PR — #600)
#     (drain-clarification — #657 — clears `needs-clarification` on an item the
#      operator answered + unassigned: a label remove + ack comment, no PR/merge,
#      so it belongs in the safe tier alongside drain-answer.)
#     (route-needs-input retired in #684: `needs-clarification` producers now
#      assign the operator at source, so the pipeline only parks — see below.)
#     (retro-judge — epic #528, temperloop#535 — the KERNEL trigger half of the
#      mint-then-judge design: pipeline-tick.sh emits it when a `retro-pending`
#      tracker (build.md 4d-retro's mint, #533) is due. It spawns the OVERLAY
#      `/retro --pending` judge — a nested headless session, no PR/merge of its
#      own — so it belongs in the safe tier alongside the other no-merge drains.
#      temperloop#1148: the spawn is NOT typed by the driver as a bare
#      `claude -p` (that hop inherits no credential and dies on a headless host
#      with an expired interactive session). Each retro-judge action carries a
#      `spawn_cmd` naming pipeline-retro-judge-spawn.sh, which re-derives the
#      credential from the config ladder at the spawn site and reports an auth
#      failure loudly. See RETRO_JUDGE_SPAWN below.)
#
#   MERGING — drive-ready WHERE kind == "code" (→ /build --unattended → PR →
#     merge). Surfaced-but-not-driven by default; DRIVEN only when
#     PIPELINE_DRIVE_MERGE=1 (level 5c), capped at PIPELINE_DRIVE_MERGE_CAP per tick,
#     under the merge-ALLOWING containment overlay. The merge itself is /build's
#     timed/modal gate, never a raw `gh pr merge` here.
#
#   no-op-ish — nothing to execute, dropped silently:
#     route-already-assigned · drain-already-applied
#     · drain-clarification-already-applied
#     · skip-contention · skip-retro-judge · no-op · board-disabled
#     (route-already-assigned covers every parked `needs-clarification` item — #684 —
#      AND every parked `funnel-escalated` 5c code escalation — #697; the operator was
#      already assigned at source in both cases, so there is nothing for the pipeline to
#      do but drop it. #697 retired the skip-merge-escalation verb: a `funnel-escalated`
#      item no longer carries `needs-clarification`, so the drain never lists it.
#      skip-retro-judge — pipeline-tick.sh's own legible, REASON-BEARING record that
#      it declined to spawn the judge: reason "not-declared" (no overlay `/retro`
#      installed) or "headless-unsupported" (installed, but it never declared the
#      headless-unattended capability — temperloop#1150). The refusal IS the record;
#      there is nothing here to drive either.)
#
# 5b safety = STRUCTURALLY incapable of merging: with PIPELINE_DRIVE_MERGE off
# (default) the merging tier is filtered OUT before the headless Claude sees it,
# and pipeline-drive.md independently forbids merging. 5c safety = the merge runs
# ONLY through /build's gate: the cap bounds blast radius, /build's timed gate
# (and operator-absent decision queue) supervises each merge, and
# pipeline-drive-merge.md forbids merging outside /build. Two guards per tier.
#
# Like pipeline-tick.sh this is a THIN executor: it CALLS the existing pipeline
# commands via the prose driver and re-implements none of them. The deterministic
# half — flatten plans, classify each action into the SAFE/MERGING/no-op tier —
# lives HERE; the judgment half (running a prose command) is the Claude layer.
#
#   echo "$plans" | pipeline-drive.sh                 # live: filter → headless drive
#   echo "$plans" | pipeline-drive.sh --dry-run       # preview the tiering; NO claude spawn
#   pipeline-drive.sh --plans-file <f>                 # read the plan array from a file
#
# Input: the tick-plan ARRAY pipeline-cron.sh collects — a JSON array of per-board
# `{tick:"done", actions:[…]}` objects — on stdin or via --plans-file.
#
# Output (stdout, one JSON object): the drive outcome pipeline-cron.sh folds into
# the wake record —
#   {event:"drive", driven:<n>, safe_executed:<n|null>, safe_refused:<n|null>,
#    safe_failed:<n|null>, merge_driven:<n>, merged_pr:<n|null>, merge_status:<enum>,
#    parked:<n|null>, failed:<n|null>, refused:<n|null>, routed:<n>,
#    route_suppressed:<n>, handed_off:<n>,
#    reconciled_merged:<n>, merge_pending:<n>, reclaimed:<n>,
#    escalated:<n>, skipped_merge:<n>,
#    routed_issues:[…], handed_off_issues:[…], escalated_issues:[…],  (#640 audit)
#    reconciled_merged_issues:[…], merge_pending_issues:[…],  (#718 audit)
#    reclaimed_issues:[…],  (#1157 audit)
#    duration_ms:<n>,  (#640 timing; second-granularity — see pipeline-cron.sh _epoch_s)
#    gh_error_count:<n>, gh_errors:[…],  (#641)
#    safe:[…], merge:[…], result:<safe driver summary | null>,
#    merge_result:<merge driver summary | null>, status:"ran|empty|dry-run|error"}
# `routed_issues`/`handed_off_issues`/`escalated_issues` are the mutation AUDIT (#640):
# the issue numbers each side-effect acted on, so a soak reviewer can cross-check the
# pipeline's board mutations against the board's actual state (the counts alone cannot).
# `duration_ms` is this drive's wall time.
# The SAFE tier (5b) reports attempts-vs-outcomes exactly like the merge tier does,
# so a soak review never reads a refusal as a success (foundation #636):
#   `driven`       = safe actions HANDED to the safe driver this tick — i.e. attempts,
#                    NOT outcomes (the sibling of `merge_driven`).
#   `safe_executed`/`safe_refused`/`safe_failed` = the driver's OWN Step-3 summary
#                    counts ({executed,failed,refused}), parsed back from `result`. A
#                    refused spike drive counts in `driven` but in `safe_refused`, NOT
#                    `safe_executed`. null = the safe tier ran but its summary was
#                    unparseable (unknown — never a false 0); 0 = the tier did not run.
# The merge tier reports the SAME two distinct counts (foundation #620):
#   `merge_driven` = kind:code items HANDED to the merge driver this tick (5c, ≤cap)
#                    — i.e. attempts, NOT outcomes.
#   `merged_pr`    = PRs the driver actually MERGED **synchronously this tick**, parsed
#                    from its Step-3 summary ({merged,parked,failed,refused}). A
#                    parked/refused drive counts in `merge_driven` but NOT in `merged_pr`.
#                    null = the merge tier ran but its summary was unparseable (unknown —
#                    never a false 0). It CANNOT see an async/queue/`/build`-later merge of
#                    a PR the pipeline opened on a prior tick — that is `reconciled_merged`.
#   `merge_status` = enum disambiguating a `merged_pr` value for a soak reviewer (#718):
#                    "reported"    = merge tier ran, summary parsed → merged_pr is a real count.
#                    "unparseable" = merge tier ran but the one-shot session died / emitted no
#                                    parseable summary → merged_pr is null (unknown, in-flight/errored).
#                    "not-run"     = merge tier did not run this tick → merged_pr is a definitive 0.
#                    (This is the F#718 fix for a bare `merged_pr:null` that read as "field absent".)
# `parked`/`failed`/`refused` mirror the rest of that summary. `routed` = refused/
# failed code items this tick assigned to the operator + labeled `funnel-escalated`
# (its own gate since #697 — not `needs-clarification`) so they leave the auto-drive
# queue instead of re-refusing every tick (#622).
# `handed_off` = code drives THAT TICK that opened a PR but did NOT merge this tick (the
# one-shot `claude -p` session ended before CI greened + /build's merge gate fired);
# each is labeled PIPELINE_MERGE_PENDING_LABEL off a ground-truth open-PR probe so the
# NEXT tick RESUMES the merge rather than re-driving into a duplicate PR (#624). It is a
# same-tick counter — its ground-truth standing-set companion is `merge_pending`.
# `reconciled_merged` (+ `reconciled_merged_issues` audit) = PRs the pipeline OPENED on a
# prior tick (still carrying PIPELINE_MERGE_PENDING_LABEL) that have since merged ASYNC —
# via the merge queue / a later `/build` / an operator merge — detected by the item's
# issue now being CLOSED (its `Closes #N` fired). This is the F#718 fix for the blind
# spot `merged_pr` (same-tick only) could never see: it reconciles pipeline-opened throughput
# against ground truth, not the synchronous driver summary. The label is RETIRED on each
# reconciled issue so the standing set stays bounded and no merge is recounted next tick.
# `merge_pending` (+ `merge_pending_issues` audit) = the standing ground-truth set of
# PIPELINE_MERGE_PENDING_LABEL issues whose PR is STILL OPEN (opened-but-not-yet-merged) —
# the cross-check `handed_off` (same-tick) alone could not surface (#718). Both are
# computed by _reconcile_pending on every real tick, independent of whether a merge was
# driven this tick (an async merge lands on ticks with no new drives).
# `escalated` = merge-pending PRs whose required `checks` gate is TERMINALLY red,
# escalated to the operator (assign + `funnel-escalated`, drop the merge-pending
# label) instead of resume-looped forever — a red gate has no autonomous merge path,
# since the merge tier pushes no fixes (#665). Disjoint from `handed_off` (CI not yet
# terminal → still resumed) and `routed` (the driver itself refused, no PR opened).
# `reclaimed` (+ `reclaimed_issues` audit) = claims the merge session ABANDONED this
# tick — driven, but the one-shot session backgrounded a wait and died before opening
# a PR (the guardrail-disobedience #1157 backstops), leaving the item stranded In
# Progress. _reclaim_abandoned releases each back to Ready (via the unclaim.sh board
# CLI) so it re-enters the drive pool next tick instead of jamming the WIP cap.
# DISJOINT from `handed_off` (that owns items WITH an open PR; reclaim owns items with
# NONE) and from `routed`/`refused` (a reported terminal status is never reclaimed).
# `skipped_merge` = merges left for the operator (all of them in 5b, only those
# beyond the cap in 5c).
#
# --dry-run stops after tiering (status:"dry-run", results null) so the cron's own
# --dry-run stays side-effect-free (it never spawns a real claude).
#
# Config (env overrides win; defaults in build.config.sh):
#   PIPELINE_DRIVE_MODEL          safe-tier model (default claude-sonnet-5 —
#                               the safe actions are mechanical/low-judgment)
#   PIPELINE_DRIVE_MERGE          1 = also drive the kind:code merge tier (level 5c)
#   PIPELINE_DRIVE_MERGE_CAP      max code items driven to merge per tick (default 1)
#   PIPELINE_DRIVE_MERGE_MODEL    merge-tier model (default claude-opus-4-8)
#   PIPELINE_DRIVE_MERGE_SETTINGS merge-tier containment overlay (merge-allowing)
#   CLAUDE_BIN                  the claude binary (default `claude` from PATH); the
#                               test-double injection seam (mirrors workflow-eval.sh)
set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo '{"event":"drive","status":"error","reason":"jq not found"}' >&2; exit 1; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=workflows/scripts/build/build.config.sh
[ -f "$HERE/build.config.sh" ] && . "$HERE/build.config.sh"

# model-usage attribution emit (temperloop#1255, epic #1225): this driver is
# seat A7 (safe tier) + A8 (merge tier) of the L0 usage-capture-feasibility
# spike's emit-feasible set — both tiers spawn via _spawn_in_checkout's
# captured `claude -p --output-format json` envelope below, and
# model_usage_emit_from_envelope is the shared extraction the two call sites
# (safe/merge) and pipeline-retro-judge-spawn.sh's A9 all share.
# shellcheck source=workflows/scripts/lib/model-usage-envelope.sh
[ -f "$HERE/../lib/model-usage-envelope.sh" ] && . "$HERE/../lib/model-usage-envelope.sh"
MODEL_USAGE_EMIT="$HERE/../emit-model-usage.sh"

# ── model-usage lake SINK — THE CALLER PINS IT (temperloop#1565) ──────────────
# emit-model-usage.sh's OWN default is deliberately left alone: it climbs two
# levels from its own file location (workflows/scripts/../.. == the root of
# whatever checkout vendors it) and its comment block explicitly refuses to
# guess a foreign path, which is exactly right for a stranger's STANDALONE
# kernel checkout. It is wrong only for THIS caller, because the pipeline runs
# the kernel copy VENDORED under a consuming checkout (…/foundation.cron/
# kernel/) — a real directory, no symlink anywhere in the chain — so that climb
# lands on the VENDORED kernel's own root and every record this driver emitted
# went to <checkout>/kernel/meta/data/raw/, a stub dir holding nothing but a
# README. Both real lakes held zero model-usage records. The knowledge the
# emitter cannot have (which checkout is the canonical sink) is knowledge the
# CALLER has, so the caller supplies it.
#
# Pinned to the same canonical sink pipeline-cron.sh's own `RAW_DIR=` assignment
# pins its stream to, byte-for-byte in the default literal, for the reason
# stated there: the sink is fixed regardless of which checkout the cron runs
# from. (Cited by SYMBOL, never by line number — the number rots on every edit
# above it, and test 58 already pins the two literals equal by grep.)
# Byte-for-byte matters operationally, not just cosmetically — pipeline-cron.sh
# is this script's parent, so an identical literal guarantees the wrapper's own
# `$RAW_DIR` and this child's model-usage sink resolve to the same directory
# whether or not PIPELINE_RAW_DIR is set in the environment.
#
# NOT EXPORTED — this is `_MODEL_USAGE_SINK_DIR`, private state the shared lib
# applies as a PER-COMMAND prefix on the emitter alone
# (`_model_usage_run_emit` in workflows/scripts/lib/model-usage-envelope.sh,
# whose header carries the full rationale). An `export MODEL_USAGE_RAW_DIR`
# here would be inherited by the headless `claude -p` driver this script spawns
# below, and that session's own quality gates read the same variable — turning
# validate-model-usage-emit.sh and validate-provider-disclosure.sh into
# production-data gates inside an autonomous drive. Do not turn this back into
# an export.
#
# THE `${PIPELINE_RAW_DIR:-…}` CHAIN IS DELIBERATE AND PROTECTIVE (operator
# decision, reviewed). It could be dropped in favour of the bare literal, and
# that would be worse: a harness that isolates PIPELINE_RAW_DIR to a throwaway
# dir — which is exactly what the test suites and any fixture run do — would
# then fall THROUGH to `$HOME/dev/foundation/meta/data/raw` and write test
# records into the real production stream. Honouring PIPELINE_RAW_DIR keeps a
# caller that has already redirected the pipeline's lake from silently
# splattering this one stream somewhere else. Recorded as a trade-off, not an
# accident.
#
# DUPLICATE SEAM, documented here per setting-registry.tsv's own owning-script
# convention (the PIPELINE_OPERATOR precedent: a fallback duplicated in a
# non-owning consuming script is documented in each duplicate site's own
# comment and records NO second registry row). MODEL_USAGE_RAW_DIR's registry
# row keeps naming emit-model-usage.sh as its owning script and that script's
# own literal as the registered default; this site is a consuming caller's pin,
# never a second source of truth. The registry lint's unregistered sweep is
# name-only by design, so this seam is legal there; the equality check pins the
# literal in the OWNING script only, which is untouched.
#
# `${MODEL_USAGE_RAW_DIR:-…}` — an already-set value passes through UNTOUCHED
# and always wins; it is a live test seam (tests/test_pipeline_drive.sh points
# the whole suite at a throwaway dir this way). $HOME is guarded because this
# script runs under `set -u`: with MODEL_USAGE_RAW_DIR, PIPELINE_RAW_DIR and
# HOME ALL unset there is no sink to name, so we set nothing at all and leave
# the emitter on its own checkout-relative default. Telemetry never aborts a
# drive.
if [ -n "${MODEL_USAGE_RAW_DIR:-}" ] || [ -n "${PIPELINE_RAW_DIR:-}" ] || [ -n "${HOME:-}" ]; then
  _MODEL_USAGE_SINK_DIR="${MODEL_USAGE_RAW_DIR:-${PIPELINE_RAW_DIR:-$HOME/dev/foundation/meta/data/raw}}"
fi

# Attribution for the gh call-logger shim (F#988 / foundation#1265): tag every
# gh call this command makes with its outermost context. `:-` preserves an
# already-set (outer) value, so a nested command's context isn't clobbered.
# pipeline-tick.sh already does this; pipeline-drive.sh (the 5b/5c executor) never
# did, leaving its `pr list --json number,body` / `issue list --label
# funnel-merge-pending` polls in the shim's `unattributed` bucket. See
# workflows/scripts/gh-call-logger.sh.
export GH_CALL_CONTEXT="${GH_CALL_CONTEXT:-pipeline-drive}"

: "${PIPELINE_DRIVE_MODEL:=claude-sonnet-5}"
: "${CLAUDE_BIN:=claude}"
# Permission containment overlay handed to the headless `claude -p` (--settings):
# a deny-list (gh pr:*, git push:*) that the safe tier never needs — so the model
# itself can never type a merge/PR/push command — PLUS a broad allow-list (Bash,
# Read/Edit/Write, Task subagents, mcp__obsidian__*) that grants the full safe tier
# the tool use it needs. Without the allow block the headless driver (against an
# untrusted workspace) is denied Read/Bash wholesale and no-ops; with it the safe
# tier runs while deny still blocks the merge surface (deny > allow in Claude Code's
# permission evaluation, so this holds over the ambient config). The structural
# pre-filter below remains the PRIMARY merge-safety guarantee; the deny is the
# backstop. Repo-relative default → portable across checkouts (mini + macbook).
: "${PIPELINE_DRIVE_SETTINGS:=$HERE/pipeline-drive.settings.json}"

# Level 5c (merge tier) defaults. The merge driver gets a STRONGER model (code
# drives are high-judgment) and the INVERSE containment overlay — one that ALLOWS
# the scoped gh pr / merge / push surface /build needs (still no
# --dangerously-skip-permissions). Gate + cap default in build.config.sh.
: "${PIPELINE_DRIVE_MERGE_MODEL:=claude-opus-4-8}"
: "${PIPELINE_DRIVE_MERGE_SETTINGS:=$HERE/pipeline-drive-merge.settings.json}"

# ── The retro-judge spawn site (temperloop#1148) ──────────────────────────────
# A `retro-judge` action is executed by the headless SAFE driver, which used to
# type a bare `claude -p "/retro --pending …"` into its Bash tool — a SECOND hop
# that inherits no credential from the driver session, so on a headless host with
# an expired interactive OAuth session the judge died before turn 1 while the
# driver itself authenticated fine. Every retro-judge action handed to the driver
# therefore now carries a `spawn_cmd`: an absolute invocation of the wrapper
# below, which re-derives the credential from THIS checkout's config ladder
# (build.config.sh → the gitignored build.config.local.sh) at the spawn site
# instead of inheriting it, and classifies + announces an auth failure there.
# Resolved from $HERE — an absolute path, so it survives the driver's `cd` into
# a board checkout and always sources the CRON checkout's own local config.
# A plain assignment, not a `:=` seam: this is a structural path, not an
# operator tunable (the test-double seam for the spawn itself is CLAUDE_BIN,
# read by the wrapper).
RETRO_JUDGE_SPAWN="$HERE/pipeline-retro-judge-spawn.sh"

# Operator handle the merge tier routes un-driveable items to (foundation #622).
# Must match pipeline-tick.sh's PIPELINE_OPERATOR (the assignee baton) — a refused/failed
# code drive is assigned here and lands in the SAME assigned-to-me queue the
# `needs-clarification` producers (/triage, /sweep) assign into at source (#684).
# `gh` wants the bare login, so the leading @ is
# stripped at use. PIPELINE_GH_BIN is the test-double seam for the routing gh calls
# (mirrors CLAUDE_BIN for the driver spawn).
# SOURCE OF TRUTH is build.config.sh (sourced above); this `:=` is the
# non-vendoring-checkout fallback (tracker seam v0, #772) — build.config.sh's
# own placeholder wins here too since it's sourced first.
: "${PIPELINE_OPERATOR:=@REPLACE_WITH_YOUR_GH_LOGIN}"
: "${PIPELINE_GH_BIN:=gh}"

# Board CLI used by the #1157 abandonment reclaim to release a stranded claim back
# to Ready (In Progress → Ready). Shelling out to the CLI — rather than sourcing
# board.sh here — keeps this driver adapter-free (the adapter loads in unclaim.sh's
# own process, exactly as the CLAIM is made by a subprocess CLI via
# /build→build-level.mjs→claim.sh). PIPELINE_UNCLAIM_BIN is the test-double seam
# (mirrors PIPELINE_GH_BIN / CLAUDE_BIN).
: "${PIPELINE_UNCLAIM_BIN:=$HERE/../board/unclaim.sh}"

# Level 5c code-escalation label (foundation #697, supersedes the #657 merge-escalation
# marker). This script applies THIS label — not `needs-clarification` — to every CODE
# item it escalates to the operator (route-refused + terminally-red CI). Because those
# items never carry `needs-clarification`, pipeline-tick's Phase-A2 answer-drain
# (`label:needs-clarification … no:assignee`) can never match them: no hidden marker,
# no per-item comment scan, no skip verb. pipeline-tick's park gate keeps them out of the
# drive pool (duplicate-PR guard). SOURCE OF TRUTH is build.config.sh (sourced above);
# this `:=` is the non-vendoring-checkout fallback.
: "${PIPELINE_ESCALATED_LABEL:=funnel-escalated}"

# Cross-tick merge hand-off marker (foundation #624). A headless `claude -p` merge
# drive is ONE-SHOT — it opens a PR but the session ends before CI greens and the
# merge gate fires. So after the drive we GROUND-TRUTH probe each item for an open,
# unmerged PR and, when one exists (and the item did not park/refuse/fail/merge),
# label the issue with this so the NEXT tick RESUMES the merge instead of re-driving
# (a fresh drive would open a duplicate PR). pipeline-tick.sh reads the same label.
: "${PIPELINE_MERGE_PENDING_LABEL:=funnel-merge-pending}"

# ── Pipeline label self-provisioning (temperloop#795) ──────────────────────────
# Both funnel-* labels above (PIPELINE_ESCALATED_LABEL, PIPELINE_MERGE_PENDING_LABEL)
# must EXIST in the target repo before `_gh_sideeffect`'s `--add-label` calls run, or
# the fail-open wrapper SWALLOWS the "label does not exist" gh error — the item never
# parks, and pipeline-tick re-routes/re-refuses it every tick with no trace (the
# silent-thrash failure this repo's own build.config.sh used to document as a manual
# one-time `gh label create` onboarding step; deleted there in this same change now
# that it's enforced here instead). Rather than re-implement that create-if-missing
# dance a third time (build.config.sh's deleted prose was already a second copy of
# init.sh's — see temperloop#795/#796), source the board adapter for its EXISTING
# memoized `_board_issues_ensure_label` idiom (lib/board.sh:1149 — the same helper
# capture.sh's self-healing `fnd:` labels use) and call it at each label's point of
# use below, once per repo per tick (the memo is keyed `repo|label`, so a burst of
# adds against the same repo pays `gh label create` at most once).
#
# This is NOT the #1157 reclaim's "stay adapter-free" tradeoff above (PIPELINE_UNCLAIM_BIN)
# — that one avoids loading the adapter's board-STATE resolution (project/field/item
# lookups) for a single claim release. `_board_issues_ensure_label` resolves no board
# state at all; it is a standalone, side-effect-idempotent `gh label create || true`
# wrapper, so sourcing board.sh here costs no adapter surface the reclaim path was
# built to avoid.
#
# board.sh's own test-injection seam `_board_gh` (lib/board.sh:500) hard-codes bare
# `gh`; redefine it AFTER sourcing to route through PIPELINE_GH_BIN instead (default
# "gh", so production behavior is unchanged) so this script's existing fake-gh
# test-double harness (PIPELINE_GH_BIN) covers the ensure-label calls too, exactly
# like every other gh side-effect in this file.
#
# PIPELINE_BOARD_LIB is the test-double seam for the adapter PATH (mirrors
# PIPELINE_UNCLAIM_BIN / PIPELINE_GH_BIN) — a test points it at a nonexistent path
# to exercise the missing-adapter degrade path below without a real broken checkout.
: "${PIPELINE_BOARD_LIB:=$HERE/../board/lib/board.sh}"
# Shell review of temperloop#795: a bare, unguarded `_board_issues_ensure_label`
# call at each point-of-use site below would be exit 127 (command not found) under
# `set -euo pipefail` if board.sh failed to source — which ABORTS THE WHOLE TICK on a
# missing/partial vendor of workflows/scripts/board/, misattributed as a mystery 127
# deep in a callee. That inverts this item's own point: #795 exists to make a *soft*,
# per-item failure (missing label → swallowed add, tick keeps running) strictly
# better, never to make the missing-adapter case strictly WORSE (whole-tick abort).
# Fix, two parts: (1) attribute the true cause LOUDLY, here, at the source, instead of
# leaving it to surface as a 127 with no context; (2) each call site below is guarded
# with `command -v` (exactly PIPELINE_UNCLAIM_BIN's existing "if the optional binary
# resolved, use it" idiom, ~line 884) so a missing adapter degrades to the PRE-#795
# behavior (the label add may still swallow a "no such label" error, but the TICK
# ITSELF keeps running) rather than crashing every item in the tick.
if [ -f "$PIPELINE_BOARD_LIB" ]; then
  # shellcheck source=workflows/scripts/board/lib/board.sh
  source "$PIPELINE_BOARD_LIB"
  _board_gh() { GH_CALL_OP="${GH_CALL_OP:-board:${FUNCNAME[1]:-unknown}}" "$PIPELINE_GH_BIN" "$@"; }  # setting:exempt — call-attribution tag, computed per-call via FUNCNAME, not a static operator default (mirrors lib/board.sh:502)
else
  echo "WARNING: pipeline-drive.sh: board adapter not found at $PIPELINE_BOARD_LIB — funnel label self-provisioning (temperloop#795) is DISABLED this tick. A missing funnel-merge-pending/funnel-escalated label will silently swallow its --add-label, exactly as it did before #795. Check workflows/scripts/board/ vendored alongside workflows/scripts/build/." >&2
fi

# Required CI gate name a merge-pending PR must clear to merge (foundation #665).
# Every build repo names its required ci.yml job `checks` (global CLAUDE.md § Branch
# & PR policy), so one default serves all boards. When a resumed merge-pending PR's
# `checks` run is TERMINALLY red, no amount of re-resuming merges it — the merge tier
# does not push fixes — so it is escalated to the operator instead of looped forever.
# SOURCE OF TRUTH is build.config.sh (sourced above); this `:=` is the
# non-vendoring-checkout fallback (tracker seam v0, #772).
: "${PIPELINE_REQUIRED_CHECK:=checks}"

# ── Board → local checkout the headless driver MUST run IN (foundation #655) ──
# /build (and the kind:spike path) derive BOTH repoRoot and the board from the
# process cwd, with no cd-into-target. So the headless `claude -p` driver must be
# spawned INSIDE the target board's checkout, or it builds the wrong repo. With a
# single enabled board the cron cwd happened to match the only target; widening to
# boards `3 4 5` broke that — board-3 code items handed to a foundation-cwd merge
# agent were all refused (merges 5/day → 0). The map is env-overridable per board
# (PIPELINE_CHECKOUT_<n>); defaults track a deploy host's ~/dev sibling-checkout layout.
# Board 4 uses the plain foundation checkout (NOT the cron's self-updating
# foundation.cron, whose per-tick hard-reset would fight a live /build worktree).
# Because that plain checkout can be dirty / on a feature branch (an active session,
# which deploy-mini deliberately skips), the merge tier PRE-FLIGHTS it for
# clean-on-main and routes the board's drives to the operator when it isn't, rather
# than spawning a session that /build --unattended Step 0.1 would only hard-abort
# (F#687 — the counterpart to the no-checkout policy below).
: "${PIPELINE_CHECKOUT_3:=$HOME/dev/stageFind}"
: "${PIPELINE_CHECKOUT_4:=$HOME/dev/foundation}"
: "${PIPELINE_CHECKOUT_5:=$HOME/dev/ssmobile}"
: "${PIPELINE_CHECKOUT_6:=$HOME/dev/subsetwiki}"
# Default checkout for cwd-AGNOSTIC safe actions (route/drain shell out to gh with
# an explicit --repo, so any valid git checkout serves) whose board has no local
# checkout. Foundation is always present where the cron runs.
: "${PIPELINE_DEFAULT_CHECKOUT:=${FOUNDATION:-$(cd "$HERE/../../.." && pwd)}}"

# Echo the checkout dir for a board if it exists, else nothing — the caller owns
# the no-checkout policy (merge tier fails the item so it can't build the wrong
# repo; safe tier falls back to the default checkout).
_board_checkout() {  # $1 = board number
  local var="PIPELINE_CHECKOUT_$1" dir
  dir="${!var:-}"
  # Echo the dir on a hit, nothing on a miss — but ALWAYS return 0, so the caller's
  # `co="$(_board_checkout …)"` assignment never trips `set -e` on the miss path.
  if [ -n "$dir" ] && [ -d "$dir/.git" ]; then printf '%s' "$dir"; fi
  return 0
}

# repo slug (owner/name) for a board — inlined mirror of pipeline-tick.sh's
# tick_board_repo so the #718 reconciliation probe needs no adapter sourcing.
# Resolves the same boards.conf registry pipeline-tick.sh and board.sh's
# board_repo() do (machine-level conf, then the repo-local
# workflows/scripts/board/boards.conf override, then the built-in map below —
# foundation #770; byte-identical to the pre-#770 map) before falling back.
# Echoes the slug on a hit + rc 0; nothing + rc 1 on an unmapped board (caller
# skips it).
_drive_conf_repo() {  # $1 = board number; rc 1 on any miss (no conf, or no key)
  local f val
  f="${BOARDS_CONF_MACHINE:-}"
  if [ -z "$f" ]; then
    # Machine-level conf (mirrors board.sh's _board_machine_conf_default).
    # The temperloop#165 legacy fallback was removed in v0.19.0; board.sh is
    # the ONE site that still notices a stale legacy file and says so, so
    # this mirror stays silent rather than double-printing the same NOTE.
    f="${XDG_CONFIG_HOME:-$HOME/.config}/temperloop/boards.conf"
  fi
  [ -f "$f" ] || f="${BOARDS_CONF_REPO_LOCAL:-$HERE/../board/boards.conf}"
  [ -f "$f" ] || return 1
  val="$(grep -m1 "^board\.${1}\.repo=" "$f" 2>/dev/null | cut -d= -f2-)"
  [ -n "$val" ] || return 1
  printf '%s' "$val"
}

# denylist:allow — this built-in map is this repo's OWN real values,
# byte-identical to board.sh's board_repo() built-in map for the same
# boards.conf-less-consumer backward-compat reason (#770) — see that
# function's comment in workflows/scripts/board/lib/board.sh.
_board_repo() {  # $1 = board number
  local v
  v="$(_drive_conf_repo "$1")" && { printf '%s\n' "$v"; return 0; }
  case "$1" in
    3) echo "Towheads/stageFind" ;;    # denylist:allow — see comment above _board_repo()
    4) echo "Towheads/foundation" ;;   # denylist:allow — see comment above _board_repo()
    5) echo "Towheads/ssmobile" ;;     # denylist:allow — see comment above _board_repo()
    6) echo "Towheads/subsetwiki" ;;   # denylist:allow — see comment above _board_repo()
    *) return 1 ;;
  esac
}

# True (rc 0) iff $1 is a git checkout on `main` with a clean tree — the SAME
# clean-on-main predicate deploy-mini uses to decide it may safely fast-forward a
# checkout (board/deploy-mini.sh §1: on `main` AND empty `git status --porcelain`).
# On the unclean path it echoes a one-line reason and returns 1. The MERGE tier
# pre-flights each board's checkout with this (F#687): /build --unattended Step 0.1
# hard-aborts on a dirty-or-feature-branch tree, and the merge session may not
# mutate the operator's uncommitted work nor cd elsewhere — so a checkout that is
# not clean-on-main can ONLY fail. Routing its items to the operator beats spawning
# a doomed session. NOT applied to the safe tier (route/drain are cwd-agnostic).
_checkout_clean_on_main() {  # $1 = checkout dir; echoes reason + rc 1 if unclean, rc 0 if clean-on-main
  local co="$1" branch
  branch="$(git -C "$co" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  if [ "$branch" != "main" ]; then
    printf 'checkout not clean-on-main (on %s, not main)' "${branch:-a detached/unknown HEAD}"
    return 1
  fi
  if [ -n "$(git -C "$co" status --porcelain 2>/dev/null)" ]; then
    printf 'checkout not clean-on-main (dirty working tree)'
    return 1
  fi
  return 0
}

# Spawn ONE headless driver IN a given checkout (#655). The `cd` is in a subshell so
# the parent cwd is untouched; the scratch payload + settings overlay are absolute
# paths, so they survive the cd. Echoes the driver's raw stdout; sets _spawn_rc.
# $2=1 exports PIPELINE_OPERATOR_ABSENT=1 (the merge tier's operator-absent regime).
_spawn_rc=0
_spawn_in_checkout() {  # $1 checkout  $2 opabsent(0|1)  $3 prompt  $4 model  $5 settings
  local checkout="$1" opabsent="$2" prompt="$3" model="$4" settings="$5" out rc
  local args=(-p "$prompt" --model "$model" --output-format json)
  [ -n "$settings" ] && args+=(--settings "$settings")
  set +e
  if [ "$opabsent" = "1" ]; then
    out="$( cd "$checkout" && PIPELINE_OPERATOR_ABSENT=1 "$CLAUDE_BIN" "${args[@]}" 2>/dev/null )"
  else
    out="$( cd "$checkout" && "$CLAUDE_BIN" "${args[@]}" 2>/dev/null )"
  fi
  rc=$?
  set -e
  _spawn_rc=$rc
  printf '%s' "$out"
}

# model-usage attribution outcome_ref (temperloop#1255): a batch driver spawn
# (_spawn_in_checkout above) can cover several actions from DIFFERENT issues
# in one call — the ADR 0026 record carries exactly ONE outcome_ref, so this
# picks the precise "issue:<n>" ref when every action in the batch shares the
# SAME issue (the common case: PIPELINE_DRIVE_MERGE_CAP defaults to 1), and
# falls back to a board-scoped composite ref ("issue:board-<b>") when the
# batch spans zero or more than one distinct issue (retro-judge actions carry
# no `.issue` at all; a raised cap can legitimately batch several issues).
# $1 = the batch's actions array (JSON)  $2 = board number
_outcome_ref_for_batch() {
  local acts="$1" board="$2" uniq n
  uniq="$(jq -c '[.[] | .issue // empty | select(. != "")] | unique' <<<"$acts" 2>/dev/null || echo '[]')"
  n="$(jq 'length' <<<"$uniq" 2>/dev/null || echo 0)"
  if [ "${n:-0}" = "1" ]; then
    jq -r '"issue:" + (.[0] | tostring)' <<<"$uniq" 2>/dev/null || printf 'issue:board-%s' "$board"
  else
    printf 'issue:board-%s' "$board"
  fi
}

# Fold per-board summary $2 into accumulator $1 over the named count keys, and
# concatenate their `results[]`. Generic over the key set so it serves both the
# safe tier ({executed,failed,refused}) and the merge tier ({merged,parked,…}).
_combine_summary() {  # $1 acc  $2 add  $3 space-separated count keys
  jq -c --argjson add "$2" --arg keys "$3" '
    ($keys | split(" ")) as $k
    | reduce $k[] as $key (.; .[$key] = ((.[$key] // 0) + (($add[$key]) // 0)))
    | .results = ((.results // []) + (($add.results) // []))
  ' <<<"$1"
}

# ── Arg parse ─────────────────────────────────────────────────────────────────
DRY_RUN=0
PLANS_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --plans-file) PLANS_FILE="${2:?--plans-file needs a path}"; shift 2 ;;
    -h|--help) echo "usage: pipeline-drive.sh [--dry-run] [--plans-file <f>]  (else reads plans on stdin)" >&2; exit 2 ;;
    *) echo "pipeline-drive.sh: unknown arg '$1'" >&2; exit 2 ;;
  esac
done

# ── Read the tick-plan array ──────────────────────────────────────────────────
if [ -n "$PLANS_FILE" ]; then
  plans="$(cat "$PLANS_FILE")"
else
  plans="$(cat)"
fi
# Tolerate empty / malformed input — fail-open to an empty plan (never wedge cron).
jq -e . >/dev/null 2>&1 <<<"$plans" || plans='[]'

# Enabled-board set for the #718 reconciliation pass — every board that appears in this
# tick's plans. pipeline-cron ticks ALL enabled boards each wake and every plan carries at
# least one action stamped with its board (a no-op / board-disabled action still has one),
# so this is the full enabled set — the repos to probe for async-merged pipeline PRs.
reconcile_boards="$(jq -r '[.[]?.actions[]?.board // empty] | map(tostring) | unique | .[]' <<<"$plans" 2>/dev/null | tr '\n' ' ')"

# ── Tier each action: SAFE (auto-execute) vs MERGING (leave for the operator) ─
# The SAFE filter IS the structural merge-safety boundary — a drive-ready is safe
# ONLY when kind == "spike". Everything not SAFE and not a MERGING drive is
# no-op-ish and simply dropped.
safe="$(jq -c '[.[]?.actions[]? | select(
    (.action == "route-foundational")
    or (.action == "drain-answer")
    or (.action == "drain-parse-miss")
    or (.action == "drain-clarification")
    or (.action == "retro-judge")
    or (.action == "drive-ready" and .kind == "spike")
)]' <<<"$plans" 2>/dev/null || echo '[]')"

# MERGING drives we deliberately did NOT execute — surfaced so the wake record
# tells the operator what still needs a manual run. A drive-ready with a missing
# kind defaults to code (treated as merging — fail closed on the merge side).
merge="$(jq -c '[.[]?.actions[]? | select(
    .action == "drive-ready" and ((.kind // "code") == "code")
)]' <<<"$plans" 2>/dev/null || echo '[]')"

n_safe="$(jq 'length' <<<"$safe" 2>/dev/null || echo 0)"
n_merge="$(jq 'length' <<<"$merge" 2>/dev/null || echo 0)"

# ── Level 5c: decide whether to DRIVE the merge tier this tick ─────────────────
# Driven only when PIPELINE_DRIVE_MERGE=1 (a SEPARATE gate from the cron's
# PIPELINE_DRIVE), capped at PIPELINE_DRIVE_MERGE_CAP. Default OFF ⇒ capped_merge is
# empty, the merge tier is surfaced-but-not-driven, and every path below reduces
# to byte-identical 5b behavior.
do_merge=0
capped_merge='[]'
n_merge_driven=0
n_routed=0   # refused/failed code items routed to the operator this tick (#622)
n_route_suppressed=0   # refused items NOT re-routed because the operator already dispositioned them (#910)
n_handed_off=0   # code drives that opened a PR but did not merge this tick → resumed next tick (#624)
n_escalated=0   # merge-pending PRs with terminally-red CI escalated to the operator instead of looped (#665)
n_reconciled_merged=0   # pipeline-opened PRs that merged ASYNC (issue now closed) — reconciled + label retired (#718)
n_merge_pending=0   # standing set of merge-pending issues whose PR is still open this tick (#718)
n_reclaimed=0   # abandoned claims released back to Ready this tick (#1157 — driven, no PR, session died)
n_gh_errors=0   # routing/hand-off gh side-effect calls that FAILED this tick — recorded, not swallowed (#641)
gh_errors_json='[]'   # per-failure detail {phase,issue,repo,gh_op,exit} accumulated by _gh_sideeffect (#641)
# Mutation audit (#640): WHICH issues each side-effect acted on — the counters alone
# (n_routed/n_handed_off/n_escalated) cannot be cross-checked against the board's
# actual state, so a soak reviewer could not verify the pipeline's mutations. These
# arrays carry the issue numbers so the record is auditable, not just countable.
routed_issues_json='[]'
handed_off_issues_json='[]'
escalated_issues_json='[]'
reconciled_merged_issues_json='[]'   # #718 audit: pipeline-opened issues reconciled as async-merged
merge_pending_issues_json='[]'       # #718 audit: merge-pending issues still open this tick
reclaimed_issues_json='[]'           # #1157 audit: abandoned claims released back to Ready this tick
drive_start_s="${PIPELINE_NOW_EPOCH:-$(date +%s)}"   # tick wall-clock start (#640 timing)
if [ "${PIPELINE_DRIVE_MERGE:-0}" = "1" ] && [ "${n_merge:-0}" -gt 0 ]; then
  do_merge=1
  capped_merge="$(jq -c --argjson cap "${PIPELINE_DRIVE_MERGE_CAP:-1}" '.[0:$cap]' <<<"$merge" 2>/dev/null || echo '[]')"
  n_merge_driven="$(jq 'length' <<<"$capped_merge" 2>/dev/null || echo 0)"
fi
# Merges left for the operator: all of them in 5b, only those beyond the cap in 5c.
n_skipped_merge=$(( ${n_merge:-0} - ${n_merge_driven:-0} ))

# Pull the merge driver's Step-3 summary object ({merged,parked,failed,refused,…})
# out of whatever shape its result took, so emit_outcome can report TRUE outcome
# counts rather than the driven-attempt count (#620). Handles both:
#   (1) the summary object verbatim at top level — a driver that emits clean JSON
#       (and the test double);
#   (2) `claude -p --output-format json`'s envelope, where the model's final text
#       sits in `.result` (or we wrapped raw unparseable text under `.raw`) and the
#       summary is a ```json fenced block inside it.
# Echoes the summary JSON if found, nothing otherwise (caller maps empty→null).
_merge_summary_json() {  # stdin: the merge_result blob
  local blob text fenced cand
  blob="$(cat)"
  # (1) counts already at top level.
  if jq -e 'objects | has("merged")' >/dev/null 2>&1 <<<"$blob"; then
    jq -c . <<<"$blob"; return 0
  fi
  # (2) dig the model text out of the claude envelope, then the last ```json fence.
  text="$(jq -r '.result // .raw // empty' <<<"$blob" 2>/dev/null)"
  [ -z "$text" ] && return 0
  fenced="$(printf '%s\n' "$text" | awk '
    /^[[:space:]]*```json[[:space:]]*$/ { cap=1; buf=""; next }
    /^[[:space:]]*```[[:space:]]*$/     { if (cap) { last=buf; cap=0 } next }
    cap                                 { buf = buf $0 "\n" }
    END                                 { printf "%s", last }')"
  for cand in "$fenced" "$text"; do
    [ -z "$cand" ] && continue
    if jq -e 'objects | has("merged")' >/dev/null 2>&1 <<<"$cand"; then
      jq -c . <<<"$cand"; return 0
    fi
  done
  return 0
}

# Pull the SAFE driver's Step-3 summary object ({executed,failed,refused,…}) out of
# whatever shape its result took, so emit_outcome can report TRUE safe-tier outcomes
# rather than only the handed-in attempt count (foundation #636). The exact mirror of
# _merge_summary_json, keyed on the safe summary's signature field `executed` (vs the
# merge summary's `merged`): handles (1) the summary verbatim at top level (a clean
# driver / the test double) and (2) the `claude -p --output-format json` envelope,
# where the model's final text sits in `.result` (or wrapped raw text under `.raw`)
# and the summary is a ```json fenced block inside it — the production shape the
# 2026-06-29 #449 refusal took (a trailing summary fence after a per-action fence).
# Echoes the summary JSON if found, nothing otherwise (caller maps empty→null).
_safe_summary_json() {  # stdin: the safe_result blob
  local blob text fenced cand
  blob="$(cat)"
  if jq -e 'objects | has("executed")' >/dev/null 2>&1 <<<"$blob"; then
    jq -c . <<<"$blob"; return 0
  fi
  text="$(jq -r '.result // .raw // empty' <<<"$blob" 2>/dev/null)"
  [ -z "$text" ] && return 0
  fenced="$(printf '%s\n' "$text" | awk '
    /^[[:space:]]*```json[[:space:]]*$/ { cap=1; buf=""; next }
    /^[[:space:]]*```[[:space:]]*$/     { if (cap) { last=buf; cap=0 } next }
    cap                                 { buf = buf $0 "\n" }
    END                                 { printf "%s", last }')"
  for cand in "$fenced" "$text"; do
    [ -z "$cand" ] && continue
    if jq -e 'objects | has("executed")' >/dev/null 2>&1 <<<"$cand"; then
      jq -c . <<<"$cand"; return 0
    fi
  done
  return 0
}

# Ground truth (#910): has a HUMAN already dispositioned this issue by REMOVING
# `funnel-escalated`? Returns 0 (true) iff the issue timeline carries an `unlabeled`
# event for `funnel-escalated`. Since #697 the pipeline escalates CODE items under this
# OWN label — and the pipeline only ever ADDS it (never removes it: no drain touches
# `funnel-escalated`, unlike `needs-clarification` which #657's drain-clarification
# removes). So any `unlabeled` event for it is definitionally an operator action: the
# operator saw the escalated item and cleared the label. Without this guard, clearing
# the label re-admits a not-auto-driveable item to the drive pool (pipeline-tick.sh:
# label absent ⇒ drive-ready), it is re-refused, and _route_refused RE-APPLIES the
# label + re-comments every tick — the #712/#910 label-thrash loop. Because the pipeline
# never drains this label, no U>D accounting is needed (the #657 complication that
# forced it applied only to the shared `needs-clarification` label — retired here by
# #697's split): a single un-label IS the operator. Fail-open toward routing: any
# gh/jq error → 1 (not dispositioned), so a transient probe failure never suppresses a
# legitimate first-time route. Same fetch-then-jq shape as _open_pr_for_issue.
_operator_dispositioned() {  # $1=repo  $2=issue
  local repo="$1" issue="$2" json u
  json="$("$PIPELINE_GH_BIN" api "repos/$repo/issues/$issue/timeline" --paginate 2>/dev/null)" || return 1
  [ -z "$json" ] && return 1
  u="$(jq -r --arg l "$PIPELINE_ESCALATED_LABEL" '[.[]? | select(.event == "unlabeled" and (.label.name // "") == $l)] | length' <<<"$json" 2>/dev/null)" || return 1
  [ -n "$u" ] && [ "$u" -gt 0 ] 2>/dev/null
}

# Run a gh SIDE-EFFECT (issue edit / comment / label) that must FAIL-OPEN — a gh blip
# (auth, rate-limit, repo mismatch) must never abort the tick — but RECORD the failure
# into the drive telemetry record instead of swallowing it with a bare `|| true` (#641).
# A swallowed routing edit leaves the item Ready → re-refused every tick with no trace;
# a swallowed hand-off label leaves the next tick treating the item as fresh → duplicate
# PR. Both now surface as a {phase,issue,repo,gh_op,exit} row in the record's `gh_errors`
# and bump `gh_error_count`, so a soak reviewer sees the loss. Still returns 0 (fail-open).
#   $1 = phase (route|handoff|escalate)  $2 = issue  $3 = repo  $4.. = gh argv
_gh_sideeffect() {
  local phase="$1" issue="$2" repo="$3"; shift 3
  local op="${1:-} ${2:-}"   # e.g. "issue edit" / "issue comment" — the gh subcommand
  "$PIPELINE_GH_BIN" "$@" >/dev/null 2>&1 && return 0
  local rc=$?               # captured before any other command resets $?
  n_gh_errors=$((n_gh_errors + 1))
  gh_errors_json="$(jq -c --argjson arr "$gh_errors_json" \
    --arg ph "$phase" --arg i "$issue" --arg r "$repo" --arg op "$op" --argjson rc "$rc" \
    -n '$arr + [{phase:$ph, issue:$i, repo:$r, gh_op:$op, exit:$rc}]' 2>/dev/null \
    || printf '%s' "$gh_errors_json")"
  return 0
}

# Append an issue number to a mutation-audit array (#640). bash 3.2 has no namerefs,
# so pass the array's current VALUE and re-capture the result at the call site:
#   routed_issues_json="$(_audit_add "$routed_issues_json" "$issue")"
_audit_add() {  # $1 = current json array  $2 = issue number
  jq -c --argjson n "$2" '. + [$n]' <<<"$1" 2>/dev/null || printf '%s' "$1"
}

# Route every refused/failed merge-tier item to the operator (foundation #622).
# A `refused` result (the driver judged the item not autonomously driveable — e.g. a
# manual-ops task with no committable artifact) or `failed` leaves the item with NO
# /build side effects. Without this it would sit in Ready, unassigned, and be
# re-selected as a drive-ready candidate next tick → re-refused → re-commented: a
# dead-end loop, and the operator never receives it. So this escalation is itself a
# `funnel-escalated` PRODUCER and owns the full hand-off AT SOURCE (#684, relabeled by
# #697): assign the operator + add `funnel-escalated` (its OWN gate — not the shared
# `needs-clarification` — which pipeline-tick's park gate PARKS as route-already-assigned
# so the item leaves the auto-drive pool) + post the driver's one-line reason as a comment.
# Deterministic + shell-side (not model-driven) so it is reliable and unit-testable.
# Fail-open: a gh error on one item is swallowed and never aborts the tick.
# Sets the global n_routed. `parked` items are NOT routed here — /build's
# operator-absent path already assigns + queues them.
_route_refused() {  # $1 = merge_result blob
  local msum op rows issue note repo
  msum="$(printf '%s' "${1:-null}" | _merge_summary_json)"
  [ -z "$msum" ] && return 0
  op="${PIPELINE_OPERATOR#@}"
  rows="$(jq -r '.results[]? | select(.status=="refused" or .status=="failed")
                 | "\(.issue)\t\(.note // "")"' <<<"$msum" 2>/dev/null)" || return 0
  [ -z "$rows" ] && return 0
  while IFS=$'\t' read -r issue note; do
    [ -z "$issue" ] && continue
    # repo for this issue comes from the capped_merge actions we handed the driver
    # (the summary's results carry no repo); skip if we cannot resolve it.
    repo="$(jq -r --arg i "$issue" 'map(select((.issue|tostring)==$i)) | .[0].repo // empty' <<<"$capped_merge" 2>/dev/null)"
    [ -z "$repo" ] && continue
    # #910: if the operator already dispositioned this item (cleared the label once),
    # do NOT re-apply it or re-comment — that undoing-the-operator loop is the bug.
    # The item stays assigned + owned by the operator; skip the re-route silently.
    if _operator_dispositioned "$repo" "$issue"; then
      n_route_suppressed=$((n_route_suppressed + 1))
      continue
    fi
    # temperloop#795: ensure the label EXISTS before adding it — a missing label
    # makes the add below a swallowed no-op (see the point-of-use comment above
    # PIPELINE_MERGE_PENDING_LABEL's default). color/desc match the onboarding
    # prose this call replaces (formerly build.config.sh's manual `gh label create`).
    # `command -v` guard (#801): a missing board.sh (see the top-of-file WARNING)
    # leaves this function undefined — degrade to pre-#795 behavior, never a 127.
    command -v _board_issues_ensure_label >/dev/null 2>&1 && _board_issues_ensure_label \
      "$repo" "$PIPELINE_ESCALATED_LABEL" "fbca04" \
      "Pipeline 5c: stuck code item (route-refused / red CI) — needs your manual merge or close"
    _gh_sideeffect route "$issue" "$repo" issue edit "$issue" -R "$repo" \
      --add-assignee "$op" --add-label "$PIPELINE_ESCALATED_LABEL"
    _gh_sideeffect route "$issue" "$repo" issue comment "$issue" -R "$repo" \
      -b "_pipeline-drive-merge (level 5c)_: routed to @${op} — not autonomously driveable to a merged PR via /build, so assigned to you and labeled \`${PIPELINE_ESCALATED_LABEL}\` (it leaves the auto-drive queue until you act). Reason: ${note:-no reason recorded}"
    n_routed=$((n_routed + 1))
    routed_issues_json="$(_audit_add "$routed_issues_json" "$issue")"
  done <<<"$rows"
}

# Safe-tier analog of _route_refused (F#1053): route a REFUSED route-foundational to
# the operator's DECISION queue. The 5b driver refuses a route-foundational when the
# epic already has an approved/executing plan note (pipeline-drive.md) — re-running
# /assess would collide on the plan-schema filename ask (unresolvable headless) and
# mint a duplicate gate comment. A refused route-foundational has NO side effect, so it
# sits Ready and pipeline-tick re-emits route-foundational every tick → re-refused forever
# (the #951 hourly spin). Applying the `decision` label + an operator assignee lands it
# in pipeline-tick's EXISTING route-already-assigned guard (`decision` + assignees>0 ⇒
# parked), so it leaves the route-foundational path — reusing that guard, no new label
# or self-heal machinery (this is why F#1045, the "pipeline-tick shouldn't re-emit" half,
# needs no separate change: the marker + the existing guard together prevent re-emission).
# `decision` — NOT the merge tier's `funnel-escalated` — is the right queue: the epic is
# prepped and the operator owns the RESUME (run /build on the existing plan once its gate
# lifts), which is exactly what pipeline-tick's decision-guard detail already says. Any
# OTHER refusal reason routes the same way (parking beats re-firing); the driver's `note`
# is surfaced verbatim as the reason. Idempotency is STRUCTURAL: once parked, pipeline-tick
# stops emitting route-foundational for it, so it never re-enters the safe tier and this
# never re-comments — so no #910-style disposition guard is needed here. Deterministic +
# shell-side (not model-driven) so it is unit-testable. Fail-open per _gh_sideeffect.
# Sets the shared n_routed / routed_issues_json (both tiers "routed to the operator").
_route_safe_refused() {  # $1 = safe_result blob
  local ssum op rows issue note repo
  ssum="$(printf '%s' "${1:-null}" | _safe_summary_json)"
  [ -z "$ssum" ] && return 0
  op="${PIPELINE_OPERATOR#@}"
  # Only route-foundational refusals — a refused drain-*/spike action has its own
  # handling and must NOT be dragged into the decision queue.
  rows="$(jq -r '.results[]? | select((.action // "") == "route-foundational" and .status == "refused")
                 | "\(.issue)\t\(.note // "")"' <<<"$ssum" 2>/dev/null)" || return 0
  [ -z "$rows" ] && return 0
  while IFS=$'\t' read -r issue note; do
    [ -z "$issue" ] && continue
    # repo comes from the safe actions we handed the 5b driver (the summary results
    # carry no repo); skip if we cannot resolve it — mirrors _route_refused/$capped_merge.
    repo="$(jq -r --arg i "$issue" 'map(select((.issue|tostring)==$i)) | .[0].repo // empty' <<<"$safe" 2>/dev/null)"
    [ -z "$repo" ] && continue
    _gh_sideeffect route "$issue" "$repo" issue edit "$issue" -R "$repo" \
      --add-assignee "$op" --add-label decision
    _gh_sideeffect route "$issue" "$repo" issue comment "$issue" -R "$repo" \
      -b "_pipeline-drive (level 5b)_: route-foundational for #${issue} was refused (${note:-already prepped}). Parked to your decision queue — assigned to @${op} + labeled \`decision\` — so the pipeline stops re-emitting route-foundational for it every tick. You own the resume (e.g. run /build on the existing plan once its gate lifts); the pipeline will not re-route it while it stays assigned."
    n_routed=$((n_routed + 1))
    routed_issues_json="$(_audit_add "$routed_issues_json" "$issue")"
  done <<<"$rows"
}

# Ground truth (#624): is there an OPEN PR that CLOSES this issue? Echoes the PR
# number if so, nothing otherwise. The merge-tier drive's `Closes #<issue>` (build.md
# 3f) is the durable linkage; we read it back rather than trust the model's summary,
# so the hand-off is detected even when the one-shot session died without emitting a
# clean Step-3 summary (the F#624 case). Same-repo bare `Closes #N` form (the pipeline
# drives same-repo). Fail-open (a gh error → no PR found).
#
# We list the open-PR set DIRECTLY and body-match client-side — NOT via `--search`.
# `gh pr list --search` rides GitHub's eventually-consistent search index, which lags
# PR creation by seconds-to-minutes; the probe runs RIGHT AFTER a just-opened PR, the
# window where the index is most likely to miss it → a false "no PR" → a duplicate
# drive next tick. The direct listing is not search-indexed and sees a fresh PR at
# once; the exact `Closes #N` filter then runs on the body we already pull.
_open_pr_for_issue() {  # $1=repo  $2=issue
  local repo="$1" issue="$2" json
  json="$("$PIPELINE_GH_BIN" pr list -R "$repo" --state open \
            --json number,body --limit 100 2>/dev/null)" || return 0
  [ -z "$json" ] && return 0
  jq -r --arg n "$issue" '
    [ .[]? | select((.body // "")
        | test("(?i)(close[sd]?|fix(e[sd])?|resolve[sd]?)[[:space:]]+#" + $n + "\\b"))
      | .number ] | (.[0] // empty)' <<<"$json" 2>/dev/null || return 0
}

# Ground truth (#665): is the PR's required `checks` gate TERMINALLY red? Returns 0
# (true) iff its status-check rollup carries a `$PIPELINE_REQUIRED_CHECK` entry that has
# COMPLETED with conclusion FAILURE. A still-running / queued / pending check is NOT
# terminal → returns 1 (false), so a freshly-opened PR (CI not yet finished) and a PR
# whose CI is re-running after an operator fix are both left to resume, never escalated
# prematurely. A merge-queue/StatusContext entry (state, not conclusion) is matched too.
# Fail-open: any gh/jq error returns 1 (not terminal) so the tick never aborts and a
# transient probe failure can never wrongly escalate. The merge tier does not push
# fixes, so a terminal-red required check has no autonomous path to merge.
_required_check_failed() {  # $1=repo  $2=pr
  local repo="$1" pr="$2" json check="${PIPELINE_REQUIRED_CHECK:-checks}"
  json="$("$PIPELINE_GH_BIN" pr view "$pr" -R "$repo" --json statusCheckRollup 2>/dev/null)" || return 1
  [ -z "$json" ] && return 1
  jq -e --arg c "$check" '
    [ (.statusCheckRollup // [])[]
      | select((.name // .context // "") == $c)
      | select((.status // "COMPLETED") == "COMPLETED")
      | select((.conclusion // .state // "") == "FAILURE") ] | length > 0
  ' <<<"$json" >/dev/null 2>&1
}

# Escalate a merge-pending PR whose required CI is terminally red to the operator
# (#665) — the same exit _route_refused uses: drop PIPELINE_MERGE_PENDING_LABEL (so the
# next tick stops resuming it), assign the operator + add `funnel-escalated` (its own
# gate since #697, so pipeline-tick's park gate sees route-already-assigned and it leaves
# the auto-drive queue), and comment naming the failed check. Deterministic + shell-side;
# fail-open per gh call.
_escalate_stuck_pr() {  # $1=repo  $2=issue  $3=pr
  local repo="$1" issue="$2" pr="$3" op="${PIPELINE_OPERATOR#@}"
  # temperloop#795: ensure funnel-escalated exists before adding it (see the
  # point-of-use comment above PIPELINE_MERGE_PENDING_LABEL's default). No
  # matching ensure for the --remove-label below — removing an absent/missing
  # label is a harmless no-op, unlike a swallowed add.
  # `command -v` guard (#801): degrade to pre-#795 behavior if board.sh is missing,
  # never a 127 (see the top-of-file WARNING).
  command -v _board_issues_ensure_label >/dev/null 2>&1 && _board_issues_ensure_label \
    "$repo" "$PIPELINE_ESCALATED_LABEL" "fbca04" \
    "Pipeline 5c: stuck code item (route-refused / red CI) — needs your manual merge or close"
  _gh_sideeffect escalate "$issue" "$repo" issue edit "$issue" -R "$repo" \
    --remove-label "$PIPELINE_MERGE_PENDING_LABEL" \
    --add-assignee "$op" --add-label "$PIPELINE_ESCALATED_LABEL"
  _gh_sideeffect escalate "$issue" "$repo" issue comment "$issue" -R "$repo" \
    -b "_pipeline-drive-merge (level 5c)_: escalated to @${op} — PR #${pr}'s required \`${PIPELINE_REQUIRED_CHECK:-checks}\` check is terminally failing, so resuming the merge cannot land it (the merge tier does not push fixes). Removed \`${PIPELINE_MERGE_PENDING_LABEL}\` and assigned you; it leaves the auto-drive queue until the PR's CI is fixed (or the PR/issue is closed)."
  n_escalated=$((n_escalated + 1))
  escalated_issues_json="$(_audit_add "$escalated_issues_json" "$issue")"
}

# Mark the cross-tick hand-off (#624). After the merge session, each driven item that
# opened a PR but did NOT reach a terminal state this tick (CI still pending when the
# one-shot session ended) must be RESUMED next tick — not re-driven, which would open
# a duplicate PR. We decide per item from BOTH the driver summary and a ground-truth
# open-PR probe:
#   refused/failed → _route_refused owns it (no PR was opened); skip.
#   parked         → /build queued an operator decision; the operator owns it; skip.
#   everything else (merged / handed-off / absent / unparseable summary) → the
#                    ground-truth probe DECIDES: if an open PR still closes the issue,
#                    apply PIPELINE_MERGE_PENDING_LABEL so pipeline-tick.sh resumes it.
# `merged` is deliberately NOT skipped — #624's thesis is "trust the probe, not the
# model report", and a `merged` self-report can be wrong (a merge-queue rejection on
# the second `checks` run leaves the PR OPEN). A genuinely-merged PR is closed, so the
# probe returns nothing (harmless); a falsely-"merged" one is still open, so the probe
# catches it and labels it — closing the one duplicate-PR hole the model is trusted on.
# Deterministic + shell-side (the probe is the source of truth, not the model report),
# so it is reliable and unit-testable. Fail-open: a gh error never aborts the tick.
# Sets the global n_handed_off. Disjoint from _route_refused by status.
_record_handoff() {  # $1 = merge_result blob
  local msum issue repo status pr
  msum="$(printf '%s' "${1:-null}" | _merge_summary_json)"
  while IFS=$'\t' read -r issue repo; do
    [ -z "$issue" ] && continue
    status=""
    [ -n "$msum" ] && status="$(jq -r --arg i "$issue" \
      '(.results // []) | map(select((.issue|tostring)==$i)) | .[0].status // ""' <<<"$msum" 2>/dev/null)"
    case "$status" in
      refused|failed|parked) continue ;;  # routed (#622) / operator-owned
    esac
    pr="$(_open_pr_for_issue "$repo" "$issue")"
    [ -z "$pr" ] && continue
    # #665: a merge-pending PR whose required check is TERMINALLY red cannot be merged
    # by re-resuming (the merge tier pushes no fixes) — escalate to the operator and
    # drop it from the resume queue instead of re-labeling it for an infinite loop.
    if _required_check_failed "$repo" "$pr"; then
      _escalate_stuck_pr "$repo" "$issue" "$pr"
      continue
    fi
    # A FAILED hand-off label is the duplicate-PR hole (#641): without the marker the
    # next tick's pipeline-tick classifier sees no `pending_merge` → re-drives fresh →
    # opens a duplicate PR. Record it under the distinct `handoff` phase so a soak
    # reviewer can spot it; pipeline-tick's fresh-path ground-truth probe (#641) is the
    # belt-and-suspenders that prevents the duplicate even when this label is lost.
    # temperloop#795: ensure the label EXISTS first — a missing label is exactly the
    # "FAILED hand-off label" case the comment above just named, silently.
    # `command -v` guard (#801): degrade to pre-#795 behavior if board.sh is missing,
    # never a 127 (see the top-of-file WARNING).
    command -v _board_issues_ensure_label >/dev/null 2>&1 && _board_issues_ensure_label \
      "$repo" "$PIPELINE_MERGE_PENDING_LABEL" "fbca04" \
      "Pipeline 5c: PR open, session ended pre-merge — resume next tick"
    _gh_sideeffect handoff "$issue" "$repo" issue edit "$issue" -R "$repo" \
      --add-label "$PIPELINE_MERGE_PENDING_LABEL"
    n_handed_off=$((n_handed_off + 1))
    handed_off_issues_json="$(_audit_add "$handed_off_issues_json" "$issue")"
  done < <(jq -r '.[]? | "\(.issue)\t\(.repo)"' <<<"$capped_merge" 2>/dev/null)
}

# Reclaim an ABANDONED claim (#1157). The level-5c one-shot merge session claims each
# item In Progress (via /build → build-level.mjs 3a → claim.sh) as its FIRST action.
# When that session DISOBEYS the synchronous-block guardrail (pipeline-drive-merge.md
# :96-112) — backgrounds a wait and ends its turn — the headless process exits
# mid-drive, leaving the item stranded In Progress with NO branch and NO PR. Seven
# such strandings on 2026-07-12 exceeded the WIP cap and jammed the whole pipeline.
#
# The synchronous-block guardrail stays the PRIMARY fix; this is the mechanical
# BACKSTOP that makes its failure self-healing (release → re-drive next tick) instead
# of a jam — the same defense-in-depth philosophy as _record_handoff (trust the
# ground-truth probe, not the model report). It releases via the unclaim.sh board
# CLI — the CLAIM is made by a subprocess CLI, so the RELEASE is too, keeping this
# driver adapter-free (no board.sh sourcing here; see _board_repo's comment).
#
# DISJOINT BY CONSTRUCTION from _record_handoff: that pass acts on items WITH an open
# PR (a real hand-off to resume); this one acts ONLY on items with NO open PR
# (condition b). An item is in exactly one set, so ordering (reclaim AFTER handoff)
# is provably safe. Release predicate — ALL must hold, else the item is left
# untouched (a false release is worse than a missed one):
#   (a) the session reported NO terminal status for the issue (status ∉
#       {merged, handed-off, parked, refused, failed}) — the abandonment/unparseable
#       signature. A reported terminal is owned by _route_refused / _record_handoff /
#       the merge itself, never reclaimed here.
#   (b) NO open PR closes the issue (ground-truth _open_pr_for_issue probe) — an item
#       with a PR is a hand-off, handled above.
#   (d) the issue is still OPEN — protects a just-merged item whose PR is closed (so
#       (b) passes) but whose close→Done cascade has not fired yet; a closed issue is
#       never "stranded", the cascade takes it to Done.
#   (c) [enforced INSIDE unclaim.sh] the card is still In Progress — the idempotent
#       CLI guard flips only In Progress→Ready, no-op otherwise, so the authoritative
#       board-status check lives in the adapter-sourcing subprocess, not this driver.
# Fail-open like every reconciliation pass: an unclaim error just leaves the item
# stranded (the pre-fix status quo), never wedges the tick. Sets n_reclaimed +
# reclaimed_issues_json (folded into the wake record).
_reclaim_abandoned() {  # $1 = merge_result blob
  local msum issue repo board status pr state
  msum="$(printf '%s' "${1:-null}" | _merge_summary_json)"
  while IFS=$'\t' read -r issue repo board; do
    [ -z "$issue" ] && continue
    # (a) skip any issue the session reported a terminal status for.
    status=""
    [ -n "$msum" ] && status="$(jq -r --arg i "$issue" \
      '(.results // []) | map(select((.issue|tostring)==$i)) | .[0].status // ""' <<<"$msum" 2>/dev/null)"
    case "$status" in
      merged|handed-off|parked|refused|failed) continue ;;
    esac
    # (b) skip any issue with an OPEN PR — that is a hand-off, not an abandonment.
    pr="$(_open_pr_for_issue "$repo" "$issue")"
    [ -n "$pr" ] && continue
    # (d) skip a CLOSED issue — a merged item mid-cascade is not stranded.
    state="$("$PIPELINE_GH_BIN" issue view "$issue" -R "$repo" --json state --jq '.state' 2>/dev/null || echo "")"
    [ "$(printf '%s' "$state" | tr '[:lower:]' '[:upper:]')" = "OPEN" ] || continue
    # Release to Ready via the board CLI (its idempotent In-Progress-only guard is
    # condition (c)). Fail-open: an error never aborts the tick, just skips the item.
    if "$PIPELINE_UNCLAIM_BIN" "$issue" --board "$board" >/dev/null 2>&1; then
      n_reclaimed=$((n_reclaimed + 1))
      reclaimed_issues_json="$(_audit_add "$reclaimed_issues_json" "$issue")"
    fi
  done < <(jq -r '.[]? | "\(.issue)\t\(.repo)\t\(.board)"' <<<"$capped_merge" 2>/dev/null)
}

# Reconcile the pipeline's STANDING merge-pending set against ground truth (#718). The
# pipeline labels every hand-off issue PIPELINE_MERGE_PENDING_LABEL (#624), so that label
# set IS "PRs the pipeline opened that had not merged yet." We read it back each real tick
# and split it by the issue's live state — the `Closes #N` linkage the drive emits means
# a merged PR CLOSES its issue, so the issue's state is the merge ground truth:
#   CLOSED → the PR merged ASYNC (queue / a later /build / an operator merge) since we
#            labeled it → count `reconciled_merged` and RETIRE the label (bounded set,
#            never recounted next tick). This is the merge `merged_pr` (same-tick only)
#            could not see — the F#718 blind spot.
#   OPEN   → still genuinely pending this tick → count `merge_pending` (the standing-set
#            cross-check for the same-tick `handed_off`), keep the label for the next tick.
# Probes ONE `gh issue list --label` per enabled-board repo (boards derived from the
# plans' actions), then one label-remove per reconciled issue via the fail-open
# _gh_sideeffect path. Deterministic + shell-side (ground truth, not a model report),
# so it is unit-testable offline. Fail-open: a gh error on any repo/issue never aborts
# the tick. Sets n_reconciled_merged / n_merge_pending + their audit arrays.
_reconcile_pending() {  # $1 = space-separated board numbers
  local boards="$1" b repo listing issue state
  for b in $boards; do
    repo="$(_board_repo "$b")" || continue
    listing="$("$PIPELINE_GH_BIN" issue list -R "$repo" --label "$PIPELINE_MERGE_PENDING_LABEL" \
                 --state all --json number,state --limit 100 2>/dev/null)" || continue
    [ -z "$listing" ] && continue
    while IFS=$'\t' read -r issue state; do
      [ -z "$issue" ] && continue
      # gh reports issue state as CLOSED/OPEN (upper) — normalise defensively.
      case "$(printf '%s' "$state" | tr '[:lower:]' '[:upper:]')" in
        CLOSED)
          _gh_sideeffect reconcile "$issue" "$repo" issue edit "$issue" -R "$repo" \
            --remove-label "$PIPELINE_MERGE_PENDING_LABEL"
          n_reconciled_merged=$((n_reconciled_merged + 1))
          reconciled_merged_issues_json="$(_audit_add "$reconciled_merged_issues_json" "$issue")"
          ;;
        *)
          n_merge_pending=$((n_merge_pending + 1))
          merge_pending_issues_json="$(_audit_add "$merge_pending_issues_json" "$issue")"
          ;;
      esac
    done < <(jq -r '.[]? | "\(.number)\t\(.state)"' <<<"$listing" 2>/dev/null)
  done
}

emit_outcome() {  # $1=status  $2=safe_result(json|null)  $3=merge_result(json|null)
  local sr="${2:-null}" ssum s_executed s_refused s_failed
  ssum="$(printf '%s' "$sr" | _safe_summary_json)"
  if [ -n "$ssum" ]; then
    # The safe driver reported — take its TRUE outcome counts (#636). A refused
    # spike drive lands here as executed:0/refused:1, NOT the old driven=1/refused:0.
    s_executed="$(jq -r '.executed // 0' <<<"$ssum")"
    s_refused="$( jq -r '.refused  // 0' <<<"$ssum")"
    s_failed="$(  jq -r '.failed   // 0' <<<"$ssum")"
  elif [ "$sr" = "null" ]; then
    # Safe tier did not run this tick (dry-run / empty / no safe actions) → a
    # definitive zero on every outcome.
    s_executed=0; s_refused=0; s_failed=0
  else
    # Safe tier ran but emitted no parseable summary → outcome UNKNOWN. Report null
    # (not 0) so a soak rollup never reads a false "0 refusals" as fact (mirrors #620).
    s_executed=null; s_refused=null; s_failed=null
  fi

  local mr="${3:-null}" msum merged_pr parked failed refused merge_status
  msum="$(printf '%s' "$mr" | _merge_summary_json)"
  if [ -n "$msum" ]; then
    # The merge driver reported — take its TRUE counts.
    merged_pr="$(jq -r '.merged  // 0' <<<"$msum")"
    parked="$(  jq -r '.parked  // 0' <<<"$msum")"
    failed="$(  jq -r '.failed  // 0' <<<"$msum")"
    refused="$( jq -r '.refused // 0' <<<"$msum")"
    merge_status="reported"
  elif [ "$mr" = "null" ]; then
    # Merge tier did not run this tick (gate off / dry-run / empty) → a definitive
    # zero on every outcome — nothing was merged, parked, or refused.
    merged_pr=0; parked=0; failed=0; refused=0
    merge_status="not-run"
  else
    # Merge tier ran but emitted no parseable summary → outcome UNKNOWN. Report
    # null (not 0) so a soak rollup never reads a false "0 merges" as fact (#620).
    # merge_status labels this null so a soak reviewer reads it as in-flight/errored,
    # NOT "field absent / error" (the F#718 bare-null ambiguity).
    merged_pr=null; parked=null; failed=null; refused=null
    merge_status="unparseable"
  fi
  jq -cn --argjson driven "${n_safe:-0}" \
    --argjson safe_executed "$s_executed" --argjson safe_refused "$s_refused" \
    --argjson safe_failed "$s_failed" --argjson merge_driven "${n_merge_driven:-0}" \
    --argjson merged_pr "$merged_pr" --argjson parked "$parked" \
    --argjson failed "$failed" --argjson refused "$refused" \
    --argjson routed "${n_routed:-0}" --argjson handed_off "${n_handed_off:-0}" \
    --argjson route_suppressed "${n_route_suppressed:-0}" \
    --argjson escalated "${n_escalated:-0}" \
    --argjson reconciled_merged "${n_reconciled_merged:-0}" \
    --argjson merge_pending "${n_merge_pending:-0}" \
    --argjson reclaimed "${n_reclaimed:-0}" \
    --argjson skipped "${n_skipped_merge:-0}" \
    --arg merge_status "$merge_status" \
    --argjson gh_error_count "${n_gh_errors:-0}" \
    --argjson gh_errors "${gh_errors_json:-[]}" \
    --argjson routed_issues "${routed_issues_json:-[]}" \
    --argjson handed_off_issues "${handed_off_issues_json:-[]}" \
    --argjson escalated_issues "${escalated_issues_json:-[]}" \
    --argjson reconciled_merged_issues "${reconciled_merged_issues_json:-[]}" \
    --argjson merge_pending_issues "${merge_pending_issues_json:-[]}" \
    --argjson reclaimed_issues "${reclaimed_issues_json:-[]}" \
    --argjson duration_ms "$(( ( ${PIPELINE_NOW_EPOCH:-$(date +%s)} - drive_start_s ) * 1000 ))" \
    --argjson safe "$safe" --argjson merge "$merge" \
    --arg status "$1" --argjson result "${2:-null}" --argjson merge_result "$mr" \
    '{event:"drive", driven:$driven,
      safe_executed:$safe_executed, safe_refused:$safe_refused, safe_failed:$safe_failed,
      merge_driven:$merge_driven,
      merged_pr:$merged_pr, merge_status:$merge_status, parked:$parked, failed:$failed, refused:$refused,
      routed:$routed, route_suppressed:$route_suppressed, handed_off:$handed_off, escalated:$escalated,
      reconciled_merged:$reconciled_merged, merge_pending:$merge_pending, reclaimed:$reclaimed, skipped_merge:$skipped,
      routed_issues:$routed_issues, handed_off_issues:$handed_off_issues, escalated_issues:$escalated_issues,
      reconciled_merged_issues:$reconciled_merged_issues, merge_pending_issues:$merge_pending_issues,
      reclaimed_issues:$reclaimed_issues,
      duration_ms:$duration_ms,
      gh_error_count:$gh_error_count, gh_errors:$gh_errors,
      safe:$safe, merge:$merge,
      result:$result, merge_result:$merge_result, status:$status}'
}

# Nothing to drive on either tier → clean no-op (still report any skipped merges).
# Still reconcile the standing merge-pending set on a REAL empty tick (#718): a PR the
# pipeline opened earlier can merge async on a tick that drives nothing new. Dry-run stays
# side-effect-free (no gh calls).
if [ "${n_safe:-0}" -eq 0 ] && [ "$do_merge" -eq 0 ]; then
  [ "$DRY_RUN" -eq 0 ] && _reconcile_pending "$reconcile_boards"
  emit_outcome "empty" null null
  exit 0
fi

# --dry-run: report the tiering, spawn NO claude (keeps cron --dry-run pure).
if [ "$DRY_RUN" -eq 1 ]; then
  emit_outcome "dry-run" null null
  exit 0
fi

# One EXIT trap cleans the per-board payload dir (created lazily below). Each tier
# writes one scratch payload per distinct board under it (#655 grouping).
SCRATCH_DIR=""
trap '[ -n "$SCRATCH_DIR" ] && rm -rf "$SCRATCH_DIR"' EXIT

# ── SAFE tier (level 5b) — drive the no-merge actions via /pipeline-drive ────────
# The payload carries the SAFE actions AND the hard rules, written to a scratch
# file the headless Claude reads via /pipeline-drive's argument. The hard rules are
# the in-band, defense-in-depth restatement of pipeline-drive.md's HARD RULES — so
# even a payload inspected in isolation declares the merge prohibition.
#
# #655: actions are GROUPED BY BOARD and each group is driven in that board's
# checkout. route/drain are cwd-agnostic (gh --repo), but a kind:spike drive runs
# /build, which derives repoRoot+board from cwd — so a spike for board 3 must run
# in the stageFind checkout. A board with no local checkout falls back to the
# default checkout (route/drain still work there; spikes are rare on such boards).
safe_result=null
if [ "${n_safe:-0}" -gt 0 ]; then
  # Containment overlay must exist before we spawn — a configured-but-missing
  # settings file means we'd otherwise launch the driver UNCONTAINED, so fail
  # closed (report error, spawn nothing) rather than run without the deny-list.
  if [ -n "$PIPELINE_DRIVE_SETTINGS" ] && [ ! -f "$PIPELINE_DRIVE_SETTINGS" ]; then
    emit_outcome "error" "$(jq -cn --arg s "$PIPELINE_DRIVE_SETTINGS" '{reason:"settings overlay missing",settings:$s}')" null
    exit 0
  fi
  [ -z "$SCRATCH_DIR" ] && SCRATCH_DIR="$(mktemp -d -t pipeline-drive.XXXXXX)"
  safe_hard_rules='[
      "NEVER open a pull request.",
      "NEVER merge anything.",
      "NEVER drive a kind:code item (only kind:spike drives are permitted here).",
      "Spawn the retro judge ONLY by running the action'"'"'s spawn_cmd verbatim — NEVER a bare claude -p command, which loses the host credential at that hop (temperloop#1148).",
      "Execute each action independently; on a per-action failure, record it and continue."
    ]'
  safe_combined='{"executed":0,"failed":0,"refused":0,"results":[]}'
  safe_parsed_any=0
  safe_raws=""
  for b in $(jq -r '[.[].board // "?"] | unique[]' <<<"$safe"); do
    acts_b="$(jq -c --arg b "$b" --arg spawn "$RETRO_JUDGE_SPAWN" '[.[]
      | select((.board // "?") == $b)
      | if .action == "retro-judge"
        then . + {spawn_cmd: ($spawn + " --board " + ((.board // $b) | tostring))}
        else . end ]' <<<"$safe")"
    co="$(_board_checkout "$b")"; [ -z "$co" ] && co="$PIPELINE_DEFAULT_CHECKOUT"
    pf="$SCRATCH_DIR/safe-$b.json"
    jq -cn --argjson actions "$acts_b" --argjson hr "$safe_hard_rules" \
      '{layer:"5b", hard_rules:$hr, actions:$actions}' > "$pf"
    # CLAUDE_BIN is the test-double seam; the overlay (--settings, NEVER
    # --dangerously-skip-permissions) contains it. Fail-open: a per-board driver
    # error is reported as a tier error (the cron wraps the whole drive).
    # opabsent=1: the safe tier is a headless cron run with no live operator, so a
    # route-foundational action's inline /assess must take /assess's operator-absent
    # branches (async decision-issue for the approval gate; fail-open Abort/Proceed
    # for provenance/collision) instead of hitting an unanswerable modal
    # AskUserQuestion and recording status:failed (#329). The other safe actions
    # (drain-answer/parse-miss/clarification, spike) are deterministic gh mutations
    # or open no PR, so they are unaffected by the flag. Mirrors the merge tier below.
    driver_out="$(_spawn_in_checkout "$co" 1 "/pipeline-drive $pf" "$PIPELINE_DRIVE_MODEL" "$PIPELINE_DRIVE_SETTINGS")"
    if [ "$_spawn_rc" -ne 0 ]; then
      emit_outcome "error" "$(jq -cn --arg rc "$_spawn_rc" --arg b "$b" '{driver_exit:($rc|tonumber),board:$b}')" null
      exit 0
    fi
    # model-usage attribution (temperloop#1255, spike seat A7): the driver_out
    # captured above IS the `claude -p --output-format json` envelope — emit
    # one record for this board's safe-tier spawn regardless of _spawn_rc (a
    # non-zero rc already exited above; only the success path reaches here).
    model_usage_emit_from_envelope "pipeline-drive-safe" "$PIPELINE_DRIVE_MODEL" \
      "$(_outcome_ref_for_batch "$acts_b" "$b")" "$(_board_repo "$b" 2>/dev/null || true)" \
      "$MODEL_USAGE_EMIT" <<<"$driver_out"
    safe_raws="$safe_raws$driver_out"$'\n'
    bsum="$(printf '%s' "$driver_out" | _safe_summary_json)"
    if [ -n "$bsum" ]; then
      safe_parsed_any=1
      safe_combined="$(_combine_summary "$safe_combined" "$bsum" "executed failed refused")"
    fi
  done
  if [ "$safe_parsed_any" = "1" ]; then
    safe_result="$safe_combined"
  else
    # Ran but no board produced a parseable summary → hand the raw text under .raw
    # so emit_outcome's fence-extraction path still gets a shot; an unparseable
    # non-null result maps to null counts (unknown, never a false 0).
    safe_result="$(jq -cn --arg raw "$safe_raws" '{raw:$raw}')"
  fi
  # Route any REFUSED route-foundational to the operator's decision queue so it stops
  # re-firing every tick (F#1053 — the safe-tier analog of _route_refused/#622). Real-run
  # only: --dry-run exited above, so this never mutates GitHub during a preview.
  _route_safe_refused "$safe_result"
fi

# ── MERGING tier (level 5c) — drive the capped kind:code items via /pipeline-drive-merge ─
# The merge driver hands each code item to /build --unattended and lets /build's
# OWN timed/modal gate decide the merge; PIPELINE_OPERATOR_ABSENT=1 selects /build's
# operator-absent regime (timed gate + decision queue) so a blocking decision
# parks rather than hangs. It runs under the merge-ALLOWING containment overlay.
merge_result=null
if [ "$do_merge" -eq 1 ]; then
  # Merge-allowing overlay must exist before we spawn — fail closed (a missing
  # overlay would launch the merge driver UNCONTAINED over the merge surface).
  if [ -n "$PIPELINE_DRIVE_MERGE_SETTINGS" ] && [ ! -f "$PIPELINE_DRIVE_MERGE_SETTINGS" ]; then
    emit_outcome "error" "$safe_result" "$(jq -cn --arg s "$PIPELINE_DRIVE_MERGE_SETTINGS" '{reason:"merge settings overlay missing",settings:$s}')"
    exit 0
  fi
  [ -z "$SCRATCH_DIR" ] && SCRATCH_DIR="$(mktemp -d -t pipeline-drive.XXXXXX)"
  merge_hard_rules='[
      "Merge ONLY through /build --unattended — never run gh pr merge / gh pr create / git push yourself.",
      "Honor the /build timed and modal merge gate; never force-merge a structurally-risky set.",
      "Drive one code item at a time, within the cap.",
      "Execute each action independently; on a per-action failure, record it and continue.",
      "Stay on the board and repo named in each action; never touch another."
    ]'
  # #655: GROUP BY BOARD and drive each group IN that board's checkout — /build
  # derives repoRoot+board from cwd, so a board-3 code item must run in the
  # stageFind checkout (driving /build from foundation.cron refused all 3 today,
  # 5/day → 0). A board with NO local checkout cannot be built here, so its items
  # are synthesized as `failed` (→ _route_refused hands them to the operator)
  # rather than risk building the wrong repo. Per-board summaries are folded into
  # one synthesized Step-3 summary the downstream parsers consume unchanged.
  merge_combined='{"merged":0,"parked":0,"failed":0,"refused":0,"results":[]}'
  merge_parsed_any=0
  merge_raws=""
  for b in $(jq -r '[.[].board // "?"] | unique[]' <<<"$capped_merge"); do
    acts_b="$(jq -c --arg b "$b" '[.[] | select((.board // "?") == $b)]' <<<"$capped_merge")"
    co="$(_board_checkout "$b")"
    if [ -z "$co" ]; then
      # No local checkout for this board → cannot drive /build here. Synthesize a
      # failed result per item so _route_refused routes it to the operator.
      bsum="$(jq -cn --argjson acts "$acts_b" '{merged:0,parked:0,failed:($acts|length),refused:0,
        results:[$acts[] | {issue:.issue, status:"failed",
          note:("no local checkout configured for board " + (.board|tostring) + " — pipeline cannot drive /build here (F#655); set PIPELINE_CHECKOUT_" + (.board|tostring))}]}')"
      merge_parsed_any=1
      merge_combined="$(_combine_summary "$merge_combined" "$bsum" "merged parked failed refused")"
      continue
    fi
    if ! co_reason="$(_checkout_clean_on_main "$co")"; then
      # F#687: the board's checkout isn't clean-on-main (deploy-mini deliberately
      # SKIPS a dirty/feature-branch checkout, so a tick can find it that way). Every
      # code drive here would hard-abort at /build --unattended Step 0.1 before any
      # work. The merge session must not stash/commit/discard the operator's work nor
      # cd elsewhere — so synthesize a failed result per item (→ _route_refused hands
      # it to the operator) instead of spawning a session that can only fail.
      bsum="$(jq -cn --argjson acts "$acts_b" --arg reason "$co_reason" --arg co "$co" '{merged:0,parked:0,failed:($acts|length),refused:0,
        results:[$acts[] | {issue:.issue, status:"failed",
          note:($reason + " [" + $co + "] — pipeline skipped this board'"'"'s merge drives (F#687); resolve the checkout or let deploy-mini reset it to clean-on-main")}]}')"
      merge_parsed_any=1
      merge_combined="$(_combine_summary "$merge_combined" "$bsum" "merged parked failed refused")"
      continue
    fi
    pf="$SCRATCH_DIR/merge-$b.json"
    jq -cn --argjson actions "$acts_b" --argjson cap "${PIPELINE_DRIVE_MERGE_CAP:-1}" --argjson hr "$merge_hard_rules" \
      '{layer:"5c", cap:$cap, hard_rules:$hr, actions:$actions}' > "$pf"
    merge_out="$(_spawn_in_checkout "$co" 1 "/pipeline-drive-merge $pf" "$PIPELINE_DRIVE_MERGE_MODEL" "$PIPELINE_DRIVE_MERGE_SETTINGS")"
    # Fail-SOFT (unlike the safe tier): a merge-driver error on one board records a
    # driver_exit for that board and continues; the tick is never wedged.
    if [ "$_spawn_rc" -ne 0 ]; then
      merge_raws="$merge_raws$(jq -cn --arg rc "$_spawn_rc" --arg b "$b" '{driver_exit:($rc|tonumber),board:$b}')"$'\n'
      continue
    fi
    # model-usage attribution (temperloop#1255, spike seat A8): merge_out IS
    # the `claude -p --output-format json` envelope — emit one record for
    # this board's merge-tier spawn (only the success path reaches here).
    model_usage_emit_from_envelope "pipeline-drive-merge" "$PIPELINE_DRIVE_MERGE_MODEL" \
      "$(_outcome_ref_for_batch "$acts_b" "$b")" "$(_board_repo "$b" 2>/dev/null || true)" \
      "$MODEL_USAGE_EMIT" <<<"$merge_out"
    merge_raws="$merge_raws$merge_out"$'\n'
    bsum="$(printf '%s' "$merge_out" | _merge_summary_json)"
    if [ -n "$bsum" ]; then
      merge_parsed_any=1
      merge_combined="$(_combine_summary "$merge_combined" "$bsum" "merged parked failed refused")"
    fi
  done
  if [ "$merge_parsed_any" = "1" ]; then
    merge_result="$merge_combined"
  else
    # Ran but no board produced a parseable summary → hand raw text under .raw so
    # emit_outcome's fence path still gets a shot; unparseable → null counts.
    merge_result="$(jq -cn --arg raw "$merge_raws" '{raw:$raw}')"
  fi
  # Route any refused/failed code items to the operator so they leave the auto-drive
  # queue instead of re-refusing every tick (#622). Real-run only (dry-run exited
  # above), so this never mutates GitHub during a preview.
  _route_refused "$merge_result"
  # Mark any item that opened a PR but did not merge this tick for a cross-tick RESUME
  # (#624) — the one-shot session ended before /build's merge gate fired. Disjoint
  # from _route_refused by status; ground-truth open-PR probe, not a model report.
  _record_handoff "$merge_result"
  # Reclaim any claim the merge session ABANDONED (#1157): driven this tick, no open
  # PR, issue still open, and no terminal status reported → release the stranded
  # In-Progress claim back to Ready so it re-enters the drive pool instead of jamming
  # the WIP cap. Disjoint from _record_handoff (that one owns the has-a-PR items).
  _reclaim_abandoned "$merge_result"
fi

# Reconcile the standing merge-pending set against ground truth (#718): count PRs the
# pipeline opened on a prior tick that have since merged async (issue now closed → retire
# the label) vs those still open. Runs on every REAL tick (dry-run exited above),
# independent of whether a merge was driven this tick.
_reconcile_pending "$reconcile_boards"

emit_outcome "ran" "$safe_result" "$merge_result"
exit 0
