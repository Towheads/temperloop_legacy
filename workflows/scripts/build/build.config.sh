#!/usr/bin/env bash
#
# build.config.sh — central defaults for the build / sweep
# tunables (foundation #447). This is the ONE place a batch-pipeline setting's
# default lives; `source` it (the machinery scripts and the command Step 0 do) to
# pull every tunable into scope.
#
# Idiom: `: "${VAR:=default}"` assigns the default ONLY when VAR is unset, so a
# pre-existing environment value (a shell export, a `.env`, an inline
# `VAR=… cmd`) always WINS over the default here. To change a default globally,
# edit the line below.
#
# This file is sourced, never executed — it has no CLI and writes nothing.
#
# ── The six-layer config PRECEDENCE ladder (temperloop#164/#169) ────────────
# NOTE: "precedence layer" here is unrelated to the pipeline autonomy
# "level-5b" / "level-5c" driver-tier terminology used later in this file
# (§ Pipeline level-5b driver / § Pipeline level-5c merge tier below) — two
# different ladders; "layer" is always precedence, "level" always autonomy.
#
# Every setting this file governs resolves through the same precedence ladder,
# highest to lowest:
#
#   1. CLI flag           — a caller's explicit `--flag value` (handled by the
#                            consuming script before/after sourcing this file;
#                            out of scope here)
#   2. env var             — an exported shell value already in the process
#                            environment when this file is sourced
#   3. machine conf        — $XDG_CONFIG_HOME/temperloop/build.config.sh (this
#                            HOST's override, e.g. a mini's LaunchAgent env)
#   4. untracked repo-local conf — build.config.local.sh, this file's
#                            gitignored sibling (this CHECKOUT's override,
#                            e.g. secrets)
#   5. tracked repo conf   — this file's own `:=` defaults, AS COMMITTED in a
#                            consuming repo that vendors/edits its own copy
#   6. kernel built-in default — a matching `:=` fallback hardcoded directly
#                            into an individual consumer script, for a
#                            non-vendoring caller that never sources this file
#                            at all (see e.g. PIPELINE_OPERATOR /
#                            PIPELINE_MERGE_PENDING_LABEL below — several
#                            machinery scripts already keep one of these)
#
# Precedence layers 5 and 6 are BOTH implemented by `:=` assignments, just in
# two different places (this file vs. an individual script) — a consuming
# repo that vendors this file gets layer 5; a script invoked standalone
# without it falls through to layer 6. Layers 3 and 4 are sourced BELOW, before
# layer 5's defaults, so that (per the `:=` idiom) a value they set is already
# bound by the time layer 5 runs and its own `:=` becomes a no-op for that var
# — this is what makes source order double as precedence order. Full ladder
# writeup, and how `boards.conf`'s XDG-then-repo-local discovery is an
# INSTANCE of this same order: ../../../docs/config-precedence.md.
#
# ── v0.17.0 terminology-rename legacy window: CLOSED in v0.19.0 ─────────────
# The window's env shim (which forwarded the pre-rename FUNNEL_*/KNOB_* env
# prefixes onto the renamed PIPELINE_*/SETTING_* settings, NEW > OLD > default)
# was deleted with the rest of the window in v0.19.0 (temperloop#767, ADR
# 0017). A pre-rename env name is now simply UNREAD — it binds nothing and
# emits nothing. The v0.17.0 CHANGELOG BREAKING entry carries the full rename
# map; persisted external state (labels, issue markers, state paths, the lock
# dir) was deliberately never remapped and is unaffected.

# ── Precedence layer 3: machine conf ─────────────────────────────────────────
# Sourced FIRST (before repo-local and before this file's own defaults) so it
# outranks both, per the ladder above. Absent file is a silent no-op. The
# path is overridable via BUILD_CONFIG_MACHINE (a test seam / explicit
# host override). MUST itself use the `:=` idiom for every var it sets —
# a plain assignment here would beat an exported env var, the exact bug
# this ladder fixes for build.config.local.sh below. Template:
# build.config.machine.sh.example (copy to the path below on the host).
: "${BUILD_CONFIG_MACHINE:=${XDG_CONFIG_HOME:-$HOME/.config}/temperloop/build.config.sh}"
if [ -f "$BUILD_CONFIG_MACHINE" ]; then
  # shellcheck source=/dev/null
  . "$BUILD_CONFIG_MACHINE"
fi

# ── Precedence layer 4: untracked repo-local conf (secrets / per-checkout override; #709) ──
# Source an OPTIONAL, gitignored sibling `build.config.local.sh` for
# checkout-local secrets and overrides that must NOT be committed — e.g. the
# pipeline's Sentry poll credentials (SENTRY_AUTH_TOKEN / SENTRY_ORG /
# SENTRY_PROJECT) that /signal-intake reads via pipeline-tick.sh Phase 0.
# Sourced here, BEFORE this file's own `:=` defaults below, so it outranks
# them — but AFTER precedence layer 3 (machine conf) above, so machine conf
# still wins. An absent file is a silent no-op (never fatal), and being untracked it
# survives the pipeline cron's self-update `git reset --hard`. The path is
# overridable via BUILD_CONFIG_LOCAL (a test seam that also lets a host point
# elsewhere). MUST itself use the `:=` idiom for every var it sets — a plain
# assignment here would unconditionally win over an exported env var, which
# is precisely the ladder-order violation this file used to have (it sourced
# this file LAST, with plain assignments, so a local.sh value could beat an
# env export). Template + mini install: build.config.local.sh.example.
: "${BUILD_CONFIG_LOCAL:=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/build.config.local.sh}"
if [ -f "$BUILD_CONFIG_LOCAL" ]; then
  # shellcheck source=/dev/null
  . "$BUILD_CONFIG_LOCAL"
fi

# (The legacy window's SECOND shim pass stood here — it re-forwarded
# pre-rename names that a layer-3/4 conf had set ITSELF, after those confs
# were sourced. It closed with the window in v0.19.0, temperloop#767: a
# machine conf or repo-local conf written before the v0.17.0 rename must now
# set the renamed names directly, or its values are ignored.)

# ── Precedence layer 5 / 6: tracked repo conf / kernel built-in defaults ─────
# Everything below is this file's own `:=` default set. It runs LAST, after
# precedence layers 3 and 4 above, so any var they already bound is left
# untouched (its `:=` here is a no-op) — only a var still unset at this point
# takes the value below.

# ── 5-hour quota gate (#447) ────────────────────────────────────────────────
# After each level (build) / each fix (sweep), the run checks the
# remaining 5-hour usage quota and pauses-then-auto-resumes if it is too low.

# Pause when the REMAINING 5h quota is below this percent (i.e. used > 100-this).
: "${BUILD_QUOTA_PAUSE_PCT:=10}"

# Where status-line.sh persists the live rate-limit snapshot the gate reads.
: "${BUILD_QUOTA_CACHE:=$HOME/.claude/rate-limits.json}"

# Seconds to wait PAST the window's reset before resuming (lets the window roll).
: "${BUILD_QUOTA_WAIT_BUFFER:=60}"

# Ignore the cache (→ fail open, proceed) if its snapshot is older than this many
# seconds — never act on a stale low reading from a long-dead session.
: "${BUILD_QUOTA_MAX_AGE:=1800}"

# ── Existing build settings, centralized here (#447) ───────────────────────
# These predate this file; their defaults now live here. build.md prose
# keeps its inline `${VAR:-default}` as a belt-and-suspenders fallback for callers
# that did not source this file.
: "${BUILD_MERGE_GATE_WINDOW:=300}"   # timed merge-gate window (s); 0 = always modal
: "${BUILD_QUEUE_TIMEOUT:=1800}"      # per-PR native-merge-queue timeout (s)

# Queue-stall threshold (temperloop#1178): how long a PR may sit IN the native
# merge queue with ZERO merge_group runs ever dispatched for it before
# `gate.sh diagnose-queue` calls it QUEUE_STALLED rather than merely slow. A
# healthy entry gets its gh-readonly-queue/<base>/pr-<N>-<sha> run within about
# a minute, so this sits far above the ~2.5 min a queue's own checks
# legitimately take — and far below BUILD_QUEUE_TIMEOUT, so a genuine stall is
# NAMED well before the ceiling instead of guessed at after it. gate.sh keeps a
# byte-identical layer-6 fallback for a caller that did not source this file.
: "${BUILD_QUEUE_STALL_AFTER:=600}"   # queue-stall threshold (s), zero merge_group runs

# Step-4a.5 combined-tree pre-check (temperloop#865): before enqueuing a level
# that parked >1 PR, build the UNION of the parked branches in a throwaway
# worktree and run the full gate suite against it — catching a SEMANTIC
# collision (two PRs green alone, red combined) LOCALLY instead of paying the
# native queue's ~1h eject/diagnose/rebase/requeue cycle. "on" (default) runs
# it; "off" skips the check outright, leaning on the queue's own merge_group as
# the sole backstop. Single-PR levels skip it regardless (nothing to combine).
: "${BUILD_COMBINED_TREE_PRECHECK:=on}"   # on|off — run the Step-4a.5 union pre-check

# Step-3h.5 as-you-go merging (temperloop#1026): whether an item that the
# EXISTING Step-4a regime partition already puts in the clean-disjoint tier may
# merge the moment ITS OWN PR goes green, instead of parking `[m]` until the
# level-boundary batch gate. Scoped to that tier only — a risky /
# structurally-overlapping set is untouched and still takes the modal Step-4
# gate at the level boundary. Level boundaries remain a dependency barrier for
# STARTING the next level either way.
# PATH SCOPE (temperloop#1452): Step 3h.5 runs on /build's `--no-workflow`
# CONVERSATIONAL path only, so this setting is read there and is INERT on the
# default Workflow path — build-level.mjs neither merges nor writes the plan
# note, and returns only at the level boundary, so it cannot be 3h.5's actor.
# A default-path run batches every item to the Step-4 gate regardless of this
# value; that is a documented accepted trade-off, not a bug to work around by
# flipping this setting.
# Measured motivation (2026-08-02): three PRs opened together took 68/69/145
# min open-to-merge against 10-33 min for solo PRs — level batching converts
# within-level parallelism into a merge-queue pileup.
# Default ON, deliberately: the issue's acceptance criterion is only observable
# while the behavior is active, and a single value here reverts the whole
# change in one flip (0 restores pure level-boundary batching).
: "${BUILD_MERGE_AS_YOU_GO:=1}"           # 1|0 — merge each clean-disjoint PR as it greens

# Operator-phone reach on an ask-now halt (foundation#863). Every
# `ask-now` gate the /build orchestrator surfaces via `decision_sink_ask`
# calls decision-notify.sh, which relays a one-line summary to the operator's
# phone through the harness PushNotification tool. This setting is an OPTIONAL
# ADDITIONAL scriptable channel — an ntfy/pushover/terminal-notifier/webhook
# command an operator wires for phone reach independent of Remote Control. It
# receives the summary as a single argument (e.g. `ntfy pub my-topic`). Empty
# (default) = rely on PushNotification alone; a batch-severity (timed / non-
# blocking) gate never enters the seam, so it never notifies through either
# channel. Also the test-injection seam decision-notify.sh's own test drives.
: "${BUILD_DECISION_NOTIFY_CMD:=}"        # optional scriptable operator-notify channel

# ── Retry caps & transient-vs-deterministic classification (temperloop#976) ──
# The operator-facing home for every RETRY bound in /build's gate + CI-poll
# machinery. Repeating a DETERMINISTICALLY failing operation cannot change its
# outcome — it is pure burn (live evidence: the 3e.5 acceptance gate re-ran a
# deterministically-failing shellcheck three times in the epic #1443 run). Each
# loop below therefore carries three knobs: a hard attempt CAP, a graduated
# inter-attempt BACKOFF (so a legitimately transient failure gets real time to
# clear — Towheads/foundation#1297: retries fired back-to-back within a fraction
# of a second defeat a slow-clearing transient), and a DETERMINISTIC-signature
# pattern that fails fast with no retry at all.
#
# DUPLICATE LAYER-6 FALLBACKS — deliberate. `scripts/quality-gates.sh` and
# `workflows/scripts/build/ci-poll.sh` each keep a BYTE-IDENTICAL `:-` fallback
# for their own settings (the six-layer ladder's layer 6, § header above), because
# both must run standalone in a consuming repo that never sources this file — and
# because /build's 3e.5 acceptance gate deliberately SCRUBS this file's settings
# (build-config-settings.sh) so the suite runs hermetically at tracked defaults,
# exactly as CI's `checks` job does. Consequence to know: a value set HERE governs
# a hand-run or CI gate invocation, while the 3e.5 gate run always uses the
# script's own identical fallback. Keep the two literals in sync — the setting
# registry pins this file's copy.

# Per-gate retry cap in quality-gates.sh (temperloop#403): absorbs transient
# CI-runner flakiness. Set to 1 to disable retries entirely (e.g. when hunting a
# real intermittent bug).
: "${GATE_MAX_ATTEMPTS:=3}"

# Graduated per-attempt sleep (backoff*attempt seconds) between quality-gates.sh
# retry attempts (Towheads/foundation#1297). 0 = retry immediately (the pre-#1297
# behavior); the default gives a slow-clearing transient real time to clear.
: "${GATE_RETRY_BACKOFF:=5}"

# ERE matched against a FAILED gate attempt's captured output. A match classifies
# the failure DETERMINISTIC — the gate is NOT retried and fails straight to
# escalation. The default matches a shellcheck finding code (the #1443 case);
# widen it for other static-lint signatures, or set it EMPTY to disable
# signature-based classification (the byte-identical-output short-circuit still
# applies, so a deterministic failure is still capped at two attempts).
: "${GATE_DETERMINISTIC_PATTERN:=SC[0-9][0-9][0-9][0-9]}"

# How many quality gates scripts/quality-gates.sh runs CONCURRENTLY
# (temperloop#1025). `auto` resolves to the detected core count, clamped to a
# ceiling the scheduler owns; an explicit integer overrides it. Set to 1 to
# restore the exact pre-parallel serial loop — the right mode for bisecting a
# gate or hunting an order-dependent flake, since it removes concurrency as a
# variable. This is a WITHIN-JOB worker pool, so changing it never affects the
# required `checks (ubuntu-latest)` status-check context.
: "${QUALITY_GATES_JOBS:=auto}"

# Bounded retry count for ONE `gh api` call in ci-poll.sh — the head-SHA resolve
# or a check-runs query (temperloop#386). Absorbs a transient non-JSON/HTTP-5xx
# hiccup instead of false-escalating it as a CI failure. Set to 1 to disable.
: "${CI_POLL_API_MAX_ATTEMPTS:=5}"

# Graduated per-attempt sleep (backoff*attempt seconds) between ci-poll.sh
# gh_retry attempts (temperloop#386).
: "${CI_POLL_API_RETRY_BACKOFF:=2}"

# ERE matched against a failed `gh` invocation's combined output in ci-poll.sh.
# A match classifies the failure DETERMINISTIC — no retry, immediate legible
# ERROR carrying `deterministic_failure:true` (temperloop#976). The default names
# permanent HTTP 4xx / auth / argument errors and deliberately EXCLUDES HTTP 429
# (rate limiting), which IS transient and must keep its backed-off retries. Set
# EMPTY to retry every failure regardless of shape (the pre-#976 behavior).
: "${CI_POLL_API_DETERMINISTIC_PATTERN:=HTTP 40[0-9]|HTTP 41[0-9]|Not Found|Could not resolve to a|Bad credentials|Resource not accessible|unknown flag}"

# Autonomous pipeline drive-concurrency governor (temperloop#162, split out from the
# retired human "WIP cap" governance rule): at most this many concurrent drives the
# autonomous pipeline lane bounds per tick. SOURCE OF TRUTH for pipeline-tick.sh's
# autonomous-lane concurrency bound (which is explicitly INHERITED from this policy,
# not re-embedded — see that file's own comment). This is the mechanical governor
# ONLY — the former human "WIP cap = 3" cross-session governance rule it used to
# double as was retired in temperloop#162 (the In-Progress gate + claim-first lock
# in claude/CLAUDE.kernel.md's Task-workflow section stay; the numeric human cap is
# gone). Change the pipeline's concurrency bound here, once.
: "${PIPELINE_DRIVE_CONCURRENCY:=3}"

# Epic-decomposition sub-unit threshold (prose-tunables-migration follow-up to
# temperloop#183): a second "CLAUDE.md-resident setting" rendered at compose time
# into claude/CLAUDE.kernel.md's Task-workflow section — "epic-sized" is
# `{{EPIC_MIN_SUBUNITS}}`+ parallelizable sub-units (OR more than one
# dependency level, which stays a structural/contract fact, not a separate
# setting — see that section's own note). Rendered into the kernel doc at compose
# time by workflows/scripts/install-claude-md.sh.
: "${EPIC_MIN_SUBUNITS:=3}"

# HUMAN-FACING display timezone (temperloop — Pacific display convention). The
# IANA zone every human-facing date/time renders in: conversation reports and
# by-day breakdowns, telemetry-brief's "today" bucket, reconcile's status-line
# stamps. An IANA name (NOT a fixed "PST"/"PDT") so DST is handled automatically
# — reads PDT in summer, PST in winter, always matching the operator's wall clock.
# A third "CLAUDE.md-resident setting" rendered at compose time into
# claude/CLAUDE.kernel.md § Communication conventions as `{{DISPLAY_TZ}}` by
# workflows/scripts/install-claude-md.sh.
#
# NOT for STORED/PARSED records: the telemetry data lake (emit-*.sh), board
# claim/capture timestamps, and the plan-schema consent timestamp stay ISO-8601
# UTC (canonical, parseable, DST-free) — never localize those.
: "${DISPLAY_TZ:=America/Los_Angeles}"

# Merge-backend SELECTION (temperloop#13): a free personal repo can't always
# provision GitHub's native merge queue, so `gate.sh backend` chooses NATIVE
# vs MANAGED. "auto" probes the repo's branch ruleset for a `merge_queue` rule
# and fails safe to MANAGED on an unreadable probe (see gate.sh cmd_backend's
# header comment for the fail-safe-direction rationale); an explicit
# `native`/`managed` override here short-circuits the probe entirely. Pure
# string default — no network call happens at config-source time, only inside
# the `gate.sh backend` invocation itself.
: "${BUILD_MERGE_BACKEND:=auto}"       # auto|native|managed

# Per-Bash-call bound for the FOREGROUND CI / MERGED polls /build runs on a
# HEADLESS one-shot path (PIPELINE_OPERATOR_ABSENT=1 — the pipeline `claude -p` merge
# driver, which has no re-invoke-on-background-completion loop, so its waits must
# block the single session in the foreground rather than dispatch-and-yield, #626).
# Kept under the ~10-min Bash foreground cap; the session itself is un-timeout'd, so
# 3g/4b can chain several sequential foreground polls, and the #624 hand-off marker
# catches any tail that outlasts them. Operator-present runs ignore this (they keep
# the run_in_background + ScheduleWakeup path).
: "${BUILD_HEADLESS_POLL_TIMEOUT:=540}"  # foreground CI/MERGED poll bound (s), headless path

# ── Command-spec prose settings (prose-tunables-migration, temperloop#164/#169
#    D3 follow-up) ──────────────────────────────────────────────────────────
# These settings back a value that previously lived ONLY in a command spec's
# prose (no shell seam at all — the D3 "prose names a setting, never states its
# value" convention had nothing to point at). Each command spec now sources
# THIS file at its own Step 0 (the same worked shape as build.md Step 0 item
# 6) and references the symbolic name below instead of restating the
# literal. Centralized here rather than a per-command config file — one
# place, per § Named-setting convention (`claude/CLAUDE.kernel.md`).

# assess.md Step 6 — the approval-poll ScheduleWakeup cadence/budget.
: "${ASSESS_POLL_FIRST_WAKE:=270}"    # first wake (s) after arming the poll
: "${ASSESS_POLL_CADENCE:=1200}"      # every wake thereafter (s)
: "${ASSESS_POLL_BUDGET:=7200}"       # give up this long (s) after arming

# assess.md Step 3 — the REVIEW-SUBAGENT fanout's wall-clock LIVENESS ceiling
# (temperloop#866). Step 3 spawns `requirements-auditor` (always) and
# `architecture-reviewer` (conditionally) over the draft item list, and had no
# time or cost bound at all. Its existing graceful skip covers an UNAVAILABLE
# agent; it does NOT cover a NON-TERMINATING one, so a reviewer that was
# resolved, spawned, and is still actively working is invisible to that probe.
# THE INCIDENT (/assess --epic 856): architecture-reviewer returned in 336s over
# 20 tool uses; requirements-auditor ran more than THREE HOURS and 235KB of
# transcript on comparable scope before the operator killed it by hand — not
# hung, just working, at ~32x its sibling's cost for a bounded read-only review.
# On an attended run that costs an operator-noticed interrupt; on an unattended
# or cron run nobody is there to interrupt, the pass stalls forever, and /assess
# never reaches Step 4 to write the plan note at all — the worse case, and the
# reason this is a structural bound rather than a warning.
#
# WHAT IT BOUNDS: the whole Step-3 fanout's wall clock, measured from the moment
# the reviewers are spawned (they run CONCURRENTLY, so one runaway can no longer
# keep the other from launching). A reviewer still unreturned at the ceiling is
# ABANDONED — the bound is on the WAIT, not on the agent — and Step 3 continues
# to Step 3.5 with whatever DID return, emitting the
# `skipped — <agent> timed out after <actual>s` degradation notice
# (claude/message-schema.md § Degradation notice, the ceiling-timeout shape) so
# an incomplete review can never read as a clean one.
#
# WHY ITS OWN SETTING, not a reuse of BUILD_REVIEW_AGENT_CEILING_SECS: that pair
# is resolved by build.md/sweep.md/fix.md and handed to build-level.mjs's §3e
# fanout as input.reviewAgentCeilingSecs — a workflow-input seam /assess never
# touches — and its breach arm can escalate `review-agent-timeout` and refuse to
# push, a disposition Step 3 has no analogue for (every Step-3 reviewer is
# ADVISORY). The two also bound different workloads: §3e reviews one item's diff,
# Step 3 reviews a whole epic's draft decomposition, so tuning one to fit the
# other would loosen the pre-push gate — the safety-critical of the two — to suit
# a planning pass. Same per-command prefix convention as ASSESS_POLL_* above.
#
# CEILING, NOT A DEADLINE — it must never fire on healthy work. The observed
# healthy review finished in 336s; this sits well clear of that and far below the
# runaway it exists to cut off.
: "${ASSESS_REVIEW_AGENT_CEILING_SECS:=900}"

# assess.md Step 3 — the OBSERVABILITY half of the pair: a Step-3 review fanout
# still outstanding after this many seconds emits a one-line progress notice
# naming which reviewers are still running, so a long-but-alive review is VISIBLE
# well before ASSESS_REVIEW_AGENT_CEILING_SECS gives up on it, instead of the
# silence the incident above was. A slow reviewer is NOT abandoned and NOT
# dispositioned. It also sets the bounded wait's FIRST slice, so a review that
# finishes inside this threshold costs exactly one backgrounded `sleep`. Seeded
# above the observed healthy review (336s) so a healthy run stays quiet. Set to 0
# to disable the notice. Kept below the ceiling, where it could never fire.
: "${ASSESS_REVIEW_AGENT_SLOW_SECS:=420}"

# triage.md Step 1 Adapter A — the PROCESS-RECORD label exclusion: the third
# naturally-excluded intake bucket, alongside the inactive-milestone filter
# (foundation #208) and the open-`blocked_by` skip (foundation #137).
# Space-separated GitHub label names; a Backlog item carrying any of them is
# skipped from intake and reported on its own Step-5 summary line. Applied by
# workflows/scripts/build/triage-intake-exclusion.sh (which carries a
# byte-identical non-vendoring-checkout fallback of this same literal).
#
# WHY THESE TWO ARE THE DEFAULT — and why it is a setting, not a hardcode.
# Both labels are minted by the KERNEL: build.md 4d-retro files a process-retro
# tracker at epic close labelled `retro-pending` (an overlay /retro judge
# exists to consume it) or `retro-info` (terminal — no judge installed). A bare
# kernel checkout with no overlay mints `retro-info` trackers itself, so it
# needs this exclusion exactly as much as an overlay-carrying one — the default
# imports no overlay vocabulary and passes the stranger test on its own. The
# generic label predicate is what lets an operator whose checkout carries other
# non-work record labels extend the bucket without patching the spec.
#
# `retro-judged` is DELIBERATELY NOT in the default. The judge relabels
# `retro-pending`->`retro-judged` and closes the tracker in one motion, so a
# `retro-judged` tracker still OPEN in Backlog is a MISSED CLOSE that tidy.md's
# own drain sweep reports. Excluding it here would hide that tracker from
# /triage too, leaving nothing but the tidy line to notice it; letting it stay
# visible costs one re-consideration and keeps the signal.
: "${TRIAGE_INTAKE_EXCLUDE_LABELS:=retro-pending retro-info}"

# next.md Step 0.5 — orphan Sequencing/*.md record staleness prune.
: "${NEXT_SEQ_STALE_AFTER:=64800}"    # prune a record older than this (s)

# tidy.md Step 0 — cross-machine drain-lock election.
: "${TIDY_SYNC_WAIT:=90}"             # wait for Obsidian Sync to propagate locks (s)
: "${TIDY_LOCK_STALE_AFTER:=1800}"    # discard a `.drain.lock.*` older than this (s)

# check-in.md — resolved-entry prune window across its review sections.
: "${CHECKIN_PRUNE_DAYS:=30}"         # resolved entries older than this may be pruned

# sweep.md Phase 2 — clarification-free-issue fanout WIDTH per batch chunk:
# how many issues drive concurrently in a single Phase-2 chunk. 1 = full
# legacy sequential behavior (one issue at a time, the pre-fanout shape).
: "${SWEEP_FANOUT_WIDTH:=3}"

# sweep.md Phase 1 — model tier for the underspecification-detection subagent
# fanout. Sentinel: an EMPTY value means INHERIT THE SESSION'S OWN model (no
# override) — this is a deliberate, Contract-pinned default from a ratified
# design brief, not an oversight: detection is judgment work, and a missed
# ambiguity that silently reaches Phase 2 is the costly failure mode, so
# this setting does NOT default to a cheap tier the way PIPELINE_DRIVE_MODEL does
# for mechanical drives (§ Cost-tier routing, claude/CLAUDE.kernel.md).
: "${SWEEP_DETECT_MODEL:=}"

# sweep.md Step 3 — model tier for the Phase-2 fix-issue WORKER agent (the
# item.model field on each build-level.mjs items[] entry). Distinct from
# SWEEP_DETECT_MODEL above (Phase-1 detection): this is the implementation
# worker, not the ambiguity-detection fanout. Sentinel: an EMPTY value means
# INHERIT THE SESSION'S OWN model — today's hardcoded behavior, unchanged by
# this setting's addition (temperloop#982; the epic's own default-flip is
# tracked separately, temperloop#971 — this item ships NO default change).
# A /sweep singleton has no plan item to derive a tier from (unlike /build,
# which reads a plan-item `model:` field), which is why this lever didn't
# exist before.
: "${SWEEP_WORKER_MODEL:=}"

# fix.md Step 4 — model tier for the single-issue WORKER agent /fix spawns
# (the item.model field on its one-item build-level.mjs items[] entry). Same
# sentinel convention as SWEEP_WORKER_MODEL above and the same rationale: a
# /fix target has no plan item to derive a tier from either. Sentinel: empty
# = inherit the session's own model (today's hardcoded behavior, unchanged;
# temperloop#982).
: "${FIX_WORKER_MODEL:=}"

# claude/commands/interview.md Step 0 — model tier for the standalone
# interview's fact-probe subagent (a narrow, isolated read-only lookup a
# round's question may spawn before presenting options — never the
# interview's own facilitator turn, which always runs at the caller's
# session tier). Per the named-setting convention (claude/CLAUDE.kernel.md),
# that spec's Step 0 sources this file and names the setting symbolically
# thereafter, never a literal. Defaults to the SAME mechanical tier as
# PIPELINE_DRIVE_MODEL (a fact probe is mechanical lookup work, not the
# judgment-tier detection SWEEP_DETECT_MODEL deliberately stays inherit-
# session for) — the `: "${VAR:=}"` idiom is the personal-override path: a
# teammate exports a different tier without touching this tracked file.
: "${INTERVIEW_PROBE_MODEL:=claude-sonnet-5}"

# claude/workflows/build-level.mjs — model tier for the TWO machinery-executor
# agent spawns that bridge the deterministic bash machinery into the Workflow
# runtime: BUILD_MACHINERY_SOLO_MODEL for runMachinery (the SOLO executor —
# the 3e.5 quality gate, recover-probe, push-retry), BUILD_MACHINERY_BATCH_MODEL
# for runMachineryBatch (the BATCHED prelude/pr-batch/ci-batch executor — see
# that file's own DESIGN NOTE 1). Named as a pair, not a general-case-plus-
# carve-out — each covers exactly half of build-level.mjs's four machinery
# call sites, so neither name is the "default" the other overrides; setting
# only one leaves the other half of the machinery spawns untouched, by design.
# UNLIKE every setting above, build-level.mjs itself never sources this file —
# the Workflow runtime has no filesystem, no Node, and no shell (DESIGN NOTE 1
# again), so there is no Step-0-source shell seam available inside the .mjs.
# Instead, EVERY command that invokes build-level.mjs (`claude/commands/
# build.md`, `sweep.md`, `fix.md` — all three source this file at their own
# Step 0 already) resolves these two and passes them as orchestrator-supplied
# WORKFLOW INPUT — `input.machinerySoloModel` / `input.machineryBatchModel` —
# alongside the existing `input.machineryBinDir` / `input.claimCmd` hand-off
# precedent (build.md Step 3's args table is the worked example; sweep.md/
# fix.md mirror it). Never a config-file read from inside the .mjs. The
# EMPTY-STRING SAFETY is owned by the CONSUMER, not the producer: the .mjs
# reads `input.machinerySoloModel || 'haiku'` / `input.machineryBatchModel ||
# 'haiku'` (`||`, not `??` — `??` only falls through on null/undefined and
# would let an orchestrator that resolves this to `""` and forgets to omit
# the key pass a literal empty-string model through; `||` collapses BOTH
# absent-input AND empty-string-input to the same fallback). Sentinel:
# empty here means every consumer either omits the key or passes it through
# unfiltered — either way the .mjs's own hardcoded 'haiku' literal wins,
# the deliberate, UNCHANGED default (the byte-identical-when-unset contract
# this item ships under; temperloop#982).
: "${BUILD_MACHINERY_SOLO_MODEL:=}"
: "${BUILD_MACHINERY_BATCH_MODEL:=}"

# claude/workflows/build-level.mjs §3e.5 — the per-SLICE wall-clock budget, in
# seconds, for the parent-side acceptance gate's `scripts/quality-gates.sh` run.
#
# WHY A SLICE AND NOT A DEADLINE. The gate runs inside ONE executor-agent Bash
# invocation whose tool ceiling (~10 min) this repo cannot raise. Treating that
# ceiling as a deadline for the WHOLE suite decayed twice: temperloop#115 raised
# a flat timeout 2min -> 8min after a green suite was SIGTERM'd and reported as
# GATE_FAIL, and temperloop#1021 is the identical failure again once the gate
# list outgrew 8min. So this value bounds ONE slice, not the suite:
# quality-gates.sh (via QUALITY_GATES_BUDGET_SECS) runs gates until the budget is
# spent, stops CLEANLY BETWEEN GATES, and reports a resume index; build-level.mjs
# loops slices. Total suite runtime is therefore unbounded by the agent's cap, and
# gate-list growth can no longer manufacture a false failure — which is why this
# setting should almost never need raising. Raise it only to cut the NUMBER of
# slices (each costs one cheap executor spawn), never to "make the suite fit".
#
# Handed to build-level.mjs the same way the two model settings above are — as
# orchestrator-supplied WORKFLOW INPUT `input.gateSliceSecs`, resolved at
# build.md / sweep.md / fix.md Step 0 — because the Workflow runtime has no
# shell to source this file (DESIGN NOTE 1). The .mjs keeps its OWN in-file
# default and CLAMPS the value so the derived Bash-tool timeout can never exceed
# the agent's hard ~10-min cap; an un-updated caller that omits the key, or one
# that resolves it to an empty string, lands on that default unchanged.
: "${BUILD_GATE_SLICE_SECS:=300}"

# claude/workflows/build-level.mjs — whether the 3e.5 parent-side acceptance gate
# runs DIFF-SCOPED (1, the default) or as the full repo-wide suite (0).
#
# WHY IT EXISTS (temperloop#1663). The full per-item suite could not survive
# within-level parallelism. Measured on a 3-item level: 55 minutes, 21 agents,
# 1.24M subagent tokens, ZERO items landed — all three escalated
# `acceptance-gate-timeout` with every worker finished and committed and only the
# gate verdict missing. N concurrent items means N concurrent full suites, each
# with its own $QUALITY_GATES_JOBS workers; contention inflated the gate tail
# 200-300%. And the budget cannot absorb it: the .mjs's GATE_SLICE_SECS_MAX sits
# only ~20% above the budget that failed, because the derived Bash-tool timeout is
# clamped to the executor agent's own ~10-min hard cap. The suite had to get
# SHORTER, not the budget longer.
#
# WHEN SCOPED, the gate runs only the gates the item's changed paths can reach,
# resolved through workflows/scripts/config/gate-paths.tsv by
# workflows/scripts/lib/gate-selection.sh — the SAME map and selector that CI's
# `checks` job has used on the `pull_request` event since temperloop#1024. So
# scoping the acceptance gate carries no failure mode the PR check does not
# already carry, and what gates `main` is unchanged: the merge_group run of
# `checks` is unscoped and always runs everything.
#
# SET IT TO 0 to restore the pre-#1663 full-suite acceptance gate — the escape
# hatch if a scoped gate is ever found to have let something through that the
# full one would have caught. Doing so re-exposes the parallel-item timeout
# above, so prefer fixing the gate-paths.tsv row that was wrong.
#
# SET IT IN A CONFIG FILE, NOT THE ENVIRONMENT. This is the one setting whose
# env layer does NOT reach its consumer, and the reason is structural rather
# than an oversight: the gate command SCRUBS every build.config.sh value-setting
# from its own environment before running (foundation#1241, so the suite's
# config-precedence tests see tracked defaults exactly as CI does), and this
# name is in that scrub set. `export BUILD_GATE_SCOPED=0` is therefore erased
# before it is read and the gate stays scoped — verified, not assumed. The
# scrub deliberately leaves the config-FILE layers alone, so the working escape
# hatches are this file's own default, the repo-local
# workflows/scripts/build/build.config.local.sh ($BUILD_CONFIG_LOCAL), or the
# machine config ($BUILD_CONFIG_MACHINE).
#
# READ IN THE EMITTED SHELL, not plumbed as an orchestrator `input.*` key like
# BUILD_GATE_SLICE_SECS above. That is the narrower seam, not a shortcut: the
# slice budget must reach the .mjs's own control flow (it derives the Bash-tool
# timeout and bounds the slice loop) and the Workflow runtime has no shell to
# source this file with — DESIGN NOTE 1 — whereas this value is needed only
# inside the gate command string, which is bash. It is read from the WORKTREE'S
# copy of this file, i.e. the version the change under test ships.
: "${BUILD_GATE_SCOPED:=1}"

# claude/workflows/build-level.mjs — the §3e REVIEW-BLOCKING CONVERGENCE BOUND:
# how many review ROUNDS one item's worktree may spend before a HIGH-severity
# finding stops costing another escalation round-trip and is instead carried
# into the PR body's `## Review notes` for the human reviewer.
#
# WHY IT EXISTS (temperloop#1970). §3e is a cold, one-shot advisory pass: a HIGH
# finding escalates `review-blocking`, the orchestrator loops the item back to
# 3c, the worker fixes it, and a FRESH reviewer reads the (now larger) diff.
# Nothing bounded that loop. Measured on one live item (temperloop#1938 L1, item
# `interview-command-spec`/#1962): FIVE consecutive §3e passes, four DISTINCT
# HIGHs, zero repeats, ~2h45m and ~1.05M subagent tokens before it converged —
# and the spec grew 447 -> 635 lines across the fix passes, so each round
# enlarged the surface the next round reviewed. The orchestrator had to invent a
# stopping rule by hand at pass 5. This setting is that stopping rule as
# machinery. Its companion half is the reviewer seat itself
# (claude/agents/workflow-reviewer.md), now instructed to enumerate EVERY HIGH it
# can identify in ONE pass rather than surfacing them serially.
#
# ADVISORY, NEVER A SUPPRESSION. Past the bound the findings are not discarded:
# they ride the PR body (`## Review notes`, rendered by the same reviewBodySuffix
# every round uses) and the parked record's `review.residual_blocking` tally, so
# the human at the merge gate sees exactly what the reviewer said. What stops is
# only the automatic build-review-build loop.
#
# 3 = at most TWO review-blocking escalations for one item, then ship with notes.
# Any item that converges in fewer rounds behaves EXACTLY as it did before this
# setting existed. Raise it to give a noisy surface more automatic rounds; a
# non-positive value falls back to the .mjs's own in-file default rather than
# disabling the bound — an unbounded loop is not an option this setting offers.
#
# Handed to build-level.mjs exactly like BUILD_GATE_SLICE_SECS above — as the
# orchestrator-supplied WORKFLOW INPUT `input.reviewBlockingMaxRounds`, resolved
# at build.md / sweep.md / fix.md Step 0 — because the Workflow runtime has no
# shell to source this file (DESIGN NOTE 1). The .mjs keeps its own in-file
# default, so an un-updated caller that omits the key (or resolves it to an empty
# string) still runs bounded.
: "${BUILD_REVIEW_BLOCKING_MAX_ROUNDS:=3}"

# workflows/scripts/build/pr.sh — the PR-BODY CAP, in BYTES: the largest body
# `pr.sh open` will hand to `gh pr create` / `gh pr edit`.
#
# WHY IT EXISTS (temperloop#2009). GitHub rejects a PR body over 65536
# characters with `GraphQL: Body is too long`. That rejection lands on the very
# LAST step of the PR-open sequence — after the worker, every routed reviewer,
# the acceptance gate, the activation gate and the push have all already
# succeeded. The branch and its commits are safe; only publishing the result
# fails, and an unattended run then parks an item whose work is complete. Two
# live items failed exactly that way in one day (temperloop#1958, #1970), both
# recovered by hand. Past this bound pr.sh truncates the body LOCALLY — reviewer
# prose first, oldest review round first, with an inline marker naming what it
# cut and where the full text can be read — so an over-cap body is never sent
# and rejected.
#
# WHY IT COMPOSES WITH THE REVIEW BOUND ABOVE. BUILD_REVIEW_BLOCKING_MAX_ROUNDS
# carries residual findings INTO the PR body rather than looping another review
# round, so the fix that reduces review rounds is also what raises body
# pressure. The truncation order is what keeps the two agreeing: verbatim
# reviewer prose is what gets dropped, oldest round first, and the newest
# ROUND — where every residual HIGH from the final round lives — is trimmed only
# after every older round is gone. The unit is a round, not a reviewer block: a
# round that routed three reviewers renders three blocks, and dropping them one
# at a time would strip two of the final round's reviewers while still reporting
# the round as protected. The linkage lines, the acceptance recap, the
# `## Verification` surface and the attribution footer are never dropped.
#
# BYTES, not characters, and deliberately conservative: a UTF-8 byte count is
# always >= the character count GitHub meters, so a body inside this byte cap
# is inside the character limit too. 60000 leaves ~5.5KB of headroom below
# 65536 for the linkage + attribution tail the truncation ladder never touches.
# Raise it toward (never to) that limit to carry more reviewer prose; a
# non-numeric or zero value falls back to pr.sh's own in-file default rather
# than disabling the bound — an unbounded body is not an option this setting
# offers, since the API rejection it prevents is unconditional.
#
# Read by pr.sh directly (it sources this file), not plumbed as a workflow
# input: the bound must hold at the one place the body is handed to `gh`, and
# that place is bash — contrast BUILD_REVIEW_BLOCKING_MAX_ROUNDS above, which
# must reach build-level.mjs's own control flow (DESIGN NOTE 1).
: "${BUILD_PR_BODY_MAX_BYTES:=60000}"

# claude/workflows/build-level.mjs — the per-STEP WALL-CLOCK LIVENESS BOUND on a
# machinery-executor step (the `prelude` / `pr-batch` / `ci-batch` batches and the
# solo `gate` / `recover-probe` / `push-retry` calls), in seconds.
#
# WHY IT EXISTS (temperloop#1071). A `pr-batch` machinery agent ran 35,362,333ms
# — 9h49m — on TWO tool calls: one Bash invocation blocked, then completed
# successfully (all four steps green, the PR opened). Every bound that was
# supposed to make that unreachable failed to fire: the Bash tool's own `timeout`
# parameter is capped at 600,000ms and the emitted prompt asks for less than that,
# and NOTHING else bounded the call. The ROOT CAUSE of the stall is NOT
# established (candidate hypotheses — a network-bound `gh` call on a half-open
# socket, git lock contention across linked worktrees sharing one object store, a
# harness timeout not enforced across host suspend — are recorded as candidates,
# never acted on without a disconfirming probe). This setting is therefore the
# ROOT-CAUSE-AGNOSTIC defensive seam: a bound that holds no matter WHICH of those
# is true, because it lives INSIDE the invoked shell rather than in the harness
# layer that demonstrably did not fire.
#
# CEILING, NOT A DEADLINE — it must never fire on healthy work. Normal machinery
# steps in the observed sweep completed in seconds to a couple of minutes; the
# longest legitimate single step is a CI poll slice (CI_POLL_SLICE_SECS, 240s in
# the .mjs) or one 3e.5 gate slice ($BUILD_GATE_SLICE_SECS plus its overrun tail).
# The default sits comfortably above all of them AND above the Bash tool's own
# 600s hard cap, so this bound is a BACKSTOP behind the tool timeout, never a
# competitor to it. Raise it only if a legitimate step genuinely needs longer;
# lowering it below the gate slice budget would manufacture false timeouts.
#
# WHAT HAPPENS WHEN IT FIRES: the step is killed and reports its own
# `{"outcome":"STEP_TIMEOUT",...}` line, and build-level.mjs treats the step as
# LOST — it runs the EXISTING `pr.sh recover-probe <worktree> <branch>` side-effect
# probe (temperloop#939's ladder, the same disposal seam temperloop#1067 uses for
# the adjacent lost-return case) before deciding anything. A PR the timed-out step
# already opened is ADOPTED, never re-opened; nothing is ever blind-retried, so a
# bounded step cannot double-push or double-open a PR.
#
# Handed to build-level.mjs on the SAME orchestrator→workflow input seam as the
# two model settings and BUILD_GATE_SLICE_SECS above (`input.machineryStepCeilingSecs`,
# resolved at build.md / sweep.md / fix.md Step 0) — the Workflow runtime has no
# shell to source this file, and no `Date.now()` either, which is exactly why the
# bound is enforced in the emitted shell rather than in the .mjs's own control flow.
: "${BUILD_MACHINERY_STEP_CEILING_SECS:=900}"

# claude/workflows/build-level.mjs — the OBSERVABILITY half of the same seam: a
# batched machinery step that takes at least this many seconds emits its own
# `{"outcome":"STEP_SLOW",...}` notice line alongside its real result, which the
# driver turns into a `log()` line. A step that is merely slow is NOT lost and is
# NOT disposed — the notice exists so a long stall is VISIBLE well before it
# reaches BUILD_MACHINERY_STEP_CEILING_SECS, instead of being the silent 9.8h the
# #1071 incident was. Set to 0 to disable the notice entirely.
#
# The default sits just above the longest legitimate single batched step (the
# CI_POLL_SLICE_SECS poll slice) so a healthy ci-batch stays quiet. It is
# deliberately NOT applied to the SOLO executor calls: those return exactly ONE
# JSON object by contract, so a second notice line there would break the schema.
: "${BUILD_MACHINERY_STEP_SLOW_SECS:=300}"

# claude/workflows/build-level.mjs §3e — the REVIEW-AGENT liveness ceiling
# (temperloop#2003), the sibling of BUILD_MACHINERY_STEP_CEILING_SECS one layer
# up. That setting bounds a machinery STEP (a shell command, bounded by a
# watchdog compiled into the command text); a §3e reviewer is an
# `agent({agentType})` call with no shell to wrap, so it had no liveness bound at
# all. THE INCIDENT: run wf_f3b9c160-6ca routed four reviewers, two returned,
# `shell-reviewer` was spawned and never returned (its transcript ends
# mid-sentence), the workflow stopped writing its journal, and ~41 minutes of
# silence followed until a human ran TaskStop. The MANDATORY `workflow-reviewer`
# for that item's claude/commands/*.md diff never launched at all — and because
# the pass never resolved, the `review.mandatory_ok` tally that would have
# reported the gap was never evaluated either.
#
# WHAT IT BOUNDS: the whole §3e fanout's wall clock, measured from the moment the
# reviewers are spawned (they now run CONCURRENTLY, so one hang can no longer
# keep a later reviewer from launching). A reviewer still unreturned at the
# ceiling is ABANDONED — this runtime cannot cancel an agent — and dispositioned
# by kind: an ADVISORY one degrades to a legible `skipped — <agent> unavailable`
# notice and the item carries on, a MANDATORY one escalates
# `review-agent-timeout` so the gate can never read as if it had passed.
#
# CEILING, NOT A DEADLINE — it must never fire on healthy work. A real §3e review
# runs single-digit minutes; the default sits well clear of that, and
# build-level.mjs FLOORS it at one CI-poll/gate slice so no operator value can
# manufacture a false timeout. Handed to build-level.mjs on the SAME
# orchestrator->workflow input seam as the settings above
# (`input.reviewAgentCeilingSecs`, resolved at build.md / sweep.md / fix.md
# Step 0) — this runtime has no shell to source this file, and no `Date.now()`
# either, which is why the bound is a race against a `sleep` executor rather than
# a timer.
: "${BUILD_REVIEW_AGENT_CEILING_SECS:=1200}"

# claude/workflows/build-level.mjs §3e — the OBSERVABILITY half of the pair: a
# §3e fanout still running after this many seconds emits a `log()` progress
# notice naming which reviewers are still outstanding, so a long-but-alive review
# is VISIBLE well before BUILD_REVIEW_AGENT_CEILING_SECS gives up on it — instead
# of being the 41 minutes of silence the #2003 incident was. A slow review is NOT
# abandoned and NOT dispositioned. Set to 0 to disable the notice entirely.
#
# It also sets the timer's FIRST slice, so a review that finishes inside this
# threshold costs exactly one cheap `sleep` executor spawn — the micro-agent cost
# temperloop#942 exists to keep down. Handed in as `input.reviewAgentSlowSecs`.
: "${BUILD_REVIEW_AGENT_SLOW_SECS:=300}"

# ── Workflow-script size ceiling (temperloop#2126) ──────────────────────
# The harness Workflow tool refuses a `scriptPath` whose file exceeds a hard
# byte limit, and that limit is the harness's, not this repo's — no gate here
# measured against it, so claude/workflows/build-level.mjs grew to 98.4% of it
# in PR #2114 and over it in PR #2125, and every command that drives work
# through the engine (/fix, /sweep, /build) stopped loading. The pipeline could
# not repair itself, because the repair would have been driven by the engine
# that no longer loaded.
#
# WORKFLOW_SCRIPT_BYTE_CEILING is the harness's hard limit, restated here ONLY
# so the guard has something to measure against; raise it only if the harness
# raises it. WORKFLOW_SCRIPT_BUDGET_PCT is the fraction of that ceiling a
# workflow script may occupy before check-workflow-script-size.sh fails the
# build — deliberately well under 100 so the gate fires while there is still
# room to land the fix, rather than after the engine is already unloadable.
: "${WORKFLOW_SCRIPT_BYTE_CEILING:=524288}"   # harness Workflow-tool scriptPath limit (bytes)
: "${WORKFLOW_SCRIPT_BUDGET_PCT:=90}"         # % of the ceiling a workflow script may occupy
# claude/workflows/build-level.mjs §3c worker return contract — WORD BOUNDS on
# the two free-prose slots of the worker's structured verdict (temperloop#1080).
#
# WHY BOUNDS AT ALL. The verdict's SHAPE is already machine-enforced
# (WORKER_VERDICT_SCHEMA), but a JSON schema cannot bound a string's LENGTH, so
# the two prose slots were unbounded in practice: measured across 83 real
# /build worker verdicts, `summary` ran to a median 119 words (max 557) and
# per-criterion `evidence` to a median 33 words (max 244) against a spec that
# asked for "1-3 sentences" and "<file:line or test name>". Every one of those
# words is an OUTPUT token (weight 5, the most expensive class) that the
# orchestrator then ingests. The bound is not information loss: the detail
# belongs in `.build-verification.md`, which the worker already writes to a
# FILE and which pr.sh splices into the PR body's `## Verification` section
# WITHOUT it ever entering orchestrator context — so a bounded verdict moves
# prose off the expensive path rather than deleting it.
#
# Handed to build-level.mjs on the SAME seam as BUILD_GATE_SLICE_SECS above —
# orchestrator-supplied WORKFLOW INPUT `input.workerSummaryMaxWords` /
# `input.workerEvidenceMaxWords`, resolved at build.md Step 0 — because the
# Workflow runtime has no shell to source this file (DESIGN NOTE 1). The .mjs
# keeps its OWN in-file defaults, so a caller that omits the keys (sweep.md /
# fix.md today) still emits a BOUNDED worker prompt: the shape is inherited by
# every caller of the shared workerPrompt(), only the tuning is build.md's.
: "${BUILD_WORKER_SUMMARY_MAX_WORDS:=60}"
: "${BUILD_WORKER_EVIDENCE_MAX_WORDS:=30}"

# sweep.md Step 3 tier-2 composition — the BOUNDED wait on background chunk 1's
# completion notification. After the Phase-1 question batch resolves, if chunk 1's
# `<task-notification>` has not arrived, the driver polls the chunk's task state
# up to ATTEMPTS times, INTERVAL seconds apart (the same background-`sleep` wake
# pattern the per-chunk quota gate uses); on exhaustion chunk 1 is treated as a
# dropped-background escalation and the run proceeds to the Step-3.5 terminal-state
# assertion, which fails loudly on its unaccounted entries. The bound is what keeps
# a dropped notification from stalling the run indefinitely.
: "${SWEEP_BG_POLL_ATTEMPTS:=6}"      # bounded poll count before declaring the chunk dropped
: "${SWEEP_BG_POLL_INTERVAL:=120}"    # seconds between polls

# sweep.md Step 1 — Operational-epic member admission (epic #1847
# "epic-as-metadata for operational work", Produces #1). Default OFF: with
# this 0, sweep's fix-pool build is behavior-identical to legacy — a Ready
# item with a parent is skipped as an epic leg, full stop (rollback
# identity, acceptance-tested by test_sweep_epic_admission.sh's
# setting-off case). Set to 1 to additionally admit a Ready sub-issue whose
# parent epic is genuinely Operational (no Foundational label anywhere in
# the group — Foundational always wins, re-evaluated live at every pool
# build, never cached from triage time), carries no live (draft/approved,
# non-superseded) plan note (the /assess race guard), and whose parent
# carries triage's `<!-- triage:edges-considered -->` marker (the
# stale-writer guard — a marker-less Operational epic is refused with a
# legible notice rather than silently admitted on an unconsidered edge
# read). See workflows/scripts/build/sweep-epic-admission.sh for the
# combinator that evaluates this predicate, and docs/features/sweep.md for
# the operator-facing writeup.
#
# SCOPE: per-checkout, not per-board — build.config.sh has no board axis, so
# this setting governs every board a checkout's `/sweep` drains. What keeps
# a pipeline-enabled board (stageFind) on the ceremony path while this is
# off elsewhere is the un-rewired pipeline-drive router, not this setting.
#
# SYNC SURVIVAL (the #711 pattern): every reader of this setting MUST use
# the belt-and-suspenders `${SWEEP_ADMIT_OPERATIONAL_EPICS:-0}` form (never
# a bare `$SWEEP_ADMIT_OPERATIONAL_EPICS`), so a routine vendored sync that
# overwrites THIS file back to its tracked default can never silently flip
# an operator's opt-in back off mid-checkout — same failure class the local
# override hook (build.config.local.sh, layer 4 above) exists to prevent
# generally. The operator's actual flip belongs in the gitignored,
# sync-preserved `build.config.local.sh` sibling (`: "${SWEEP_ADMIT_OPERATIONAL_EPICS:=1}"`
# there), never edited directly on this tracked line — see
# test_sweep_admit_operational_epics_sync.sh for the acceptance proof
# (overwriting this file's own tracked default leaves an already-set local
# override's effective value unchanged).
: "${SWEEP_ADMIT_OPERATIONAL_EPICS:=0}"   # 0|1 — admit Ready Operational-epic members into sweep's fix pool

# ── Pipeline operator identity + required CI check (tracker seam v0, #772) ────
# The operator handle the async decision-issue backend, the merge-tier escalation
# path, and pipeline-tick's assignee baton all target. MUST be the operator's real
# GitHub collaborator LOGIN (verify with `gh api user -q .login` — a display
# name or email-derived handle can differ from the real login, and a re-assign
# to the wrong one targets nobody / fails, so the baton never reaches the
# operator; foundation #588). Consuming scripts (pipeline-tick.sh, pipeline-drive.sh)
# keep a matching `:=` fallback for a non-vendoring checkout, exactly as
# PIPELINE_MERGE_PENDING_LABEL does; this file is the SOURCE OF TRUTH. `gh` wants
# the bare login, so the leading @ is stripped at each use site. The placeholder
# below MUST be overridden — set the real value in the gitignored
# build.config.local.sh (§ Precedence layer 4 above), never here.
: "${PIPELINE_OPERATOR:=@REPLACE_WITH_YOUR_GH_LOGIN}"

# Required CI gate name a PR must clear to merge (foundation #665). Every build
# repo names its required ci.yml job `checks` (global CLAUDE.md § Branch & PR
# policy), so one default serves all boards.
: "${PIPELINE_REQUIRED_CHECK:=checks}"

# ── Pipeline-overlap predicate (#864) ─────────────────────────────────────────
# The pipeline's OPERATIONAL SURFACE — space-separated path prefixes that
# pipeline-overlap.sh intersects a plan's aggregate `files:` set against at
# /build run start (Step 1.7). A plan that rewrites this machinery while the
# pipeline is live is the Epic B interference cascade (retro #847): the default
# names the build machinery + board toolkit + pipeline commands/hooks + quality
# gates + Makefile, under both the kernel/ vendored prefix and the compat
# pre-split paths. Prefix match is textual, so both spellings must be listed.
: "${PIPELINE_DRIVEN_PATHS:=kernel/ workflows/scripts/ claude/commands/ claude/workflows/ claude/hooks/ scripts/quality-gates Makefile}"

# ── Pipeline level-5b driver (#604) ────────────────────────────────────────────
# The autonomous pipeline driver's supervised auto-drive. Default OFF: the cron
# stays pure 5a (emit + notify) until the operator opts in. Set PIPELINE_DRIVE=1
# (a deploy host's LaunchAgent/cron plist sets it when the 5b soak begins) to make
# pipeline-cron.sh execute the SAFE, no-merge tier of each tick plan via a headless
# pipeline-drive.sh / `claude -p "/pipeline-drive"` run. See pipeline-drive.sh.
: "${PIPELINE_DRIVE:=0}"                 # 1 = auto-execute the safe tier; 0 = emit-only (5a)
# Per-tick DRIVE CAP — the canonical "how many items the pipeline drives per tick"
# setting (#642). pipeline-tick.sh caps the number of Operational drive-ready actions it
# EMITs per tick on this (was a hardcoded one-per-tick); pipeline-cron.sh resolves the
# operator's vault `cap:` (the ```pipeline-schedule block) into it and ALSO maps it onto
# PIPELINE_DRIVE_MERGE_CAP below, so one vault field governs both the emit cap and the
# merge blast-radius. The `:=1` here is only the fallback when the vault omits `cap:`
# (and for a bare manual `pipeline-tick.sh` run); the vault is the live source of truth.
: "${PIPELINE_DRIVE_CAP:=1}"             # max Operational items driven per tick (vault `cap:` feeds this)
: "${PIPELINE_DRIVE_MODEL:=claude-sonnet-5}"  # model for the headless driver (mechanical actions)
: "${PIPELINE_DRIVE_SETTINGS:=}"         # --settings overlay for the headless driver (#606);
                                       # empty here → pipeline-drive.sh defaults it to its
                                       # repo-relative pipeline-drive.settings.json (deny gh pr/git
                                       # push + a broad allow for the full safe tier — #609)

# ── Pipeline level-5c merge tier (#615) ────────────────────────────────────────
# The merging tier of the autonomous driver: drive-ready WHERE kind=="code"
# (→ /build --unattended → PR → CI → merge). 5b (above) leaves this for the
# operator; 5c auto-executes it on /build's existing timed/modal merge gate.
# A SEPARATE gate from PIPELINE_DRIVE — flipping the safe tier on must NOT flip
# merging on. The merge tier RIDES ON TOP of the safe tier: it runs only when
# the cron already invokes pipeline-drive.sh (PIPELINE_DRIVE=1) AND this is 1.
# Default OFF ⇒ the merge tier is surfaced-but-not-driven, exactly as in 5b.
: "${PIPELINE_DRIVE_MERGE:=0}"           # 1 = also auto-execute the kind:code merge tier; 0 = leave for operator
# Merge blast-radius bound. Since #642 this is FED from the vault `cap:` by
# pipeline-cron.sh (it exports PIPELINE_DRIVE_MERGE_CAP=$cap alongside PIPELINE_DRIVE_CAP),
# so the operator sets it via the vault schedule, NOT the plist. The `:=1` here is
# only the fallback when the cron does not resolve a cap (e.g. a bare pipeline-drive.sh run).
: "${PIPELINE_DRIVE_MERGE_CAP:=1}"       # max kind:code items driven to merge per tick (vault `cap:` feeds this)
: "${PIPELINE_DRIVE_MERGE_MODEL:=claude-opus-4-8}"  # model for the merge driver (code drives are high-judgment)
: "${PIPELINE_DRIVE_MERGE_SETTINGS:=}"   # --settings overlay for the merge driver; empty here →
                                       # pipeline-drive.sh defaults it to pipeline-drive-merge.settings.json
                                       # (the inverse of the 5b overlay: ALLOWS the scoped gh pr/merge/push
                                       # surface /build needs, still never --dangerously-skip-permissions)

# Cross-tick merge hand-off (#624), now the bounded-timeout TAIL after #626. Since
# #626, a headless `claude -p` merge drive runs /build's CI-watch + merge gate in the
# FOREGROUND and the normal outcome is merged-in-session. This label covers the tail:
# when /build's foreground CI/MERGED poll hits its BUILD_HEADLESS_POLL_TIMEOUT bound
# before the merge lands (CI/queue slower than the session can foreground-wait), the
# drive splits across ticks. pipeline-drive.sh applies the label to an issue whose drive
# left an OPEN, unmerged PR (ground-truth probe, not a model self-report), and
# pipeline-tick.sh, on seeing it, emits a RESUME drive (re-attach to the open PR + run
# /build's merge gate) instead of a FRESH one — which would open a duplicate PR. The
# open PR remains the artifact work resumes on; the label is the cheap board pointer.
: "${PIPELINE_MERGE_PENDING_LABEL:=funnel-merge-pending}"

# Clarification-drain sentinel (foundation #657) — centralized here so the
# writer/reader pair share ONE source of truth (the drift the reviewer flagged):
#   PIPELINE_CLARIFIED_MARKER — the ack the 5b executor posts on a drained
#     `needs-clarification` item; pipeline-tick's clarification_already_applied reads
#     it for idempotency. (The prose writer /pipeline-drive.md cannot source config,
#     so that one literal stays hand-synced to this value.)
: "${PIPELINE_CLARIFIED_MARKER:=<!-- funnel:clarification-drained -->}"

# Level 5c code-escalation label (foundation #697, supersedes the #657 merge-escalation
# marker). A 5c CODE escalation (route-refused / terminally-red CI) carries THIS label
# + an assignee — NOT `needs-clarification` — so the #657 answer-drain's
# `label:needs-clarification … no:assignee` search can never match it (no marker, no
# per-item comment scan, no skip verb needed). pipeline-tick's park gate keeps such an
# item out of the drive pool (duplicate-PR guard). Consuming scripts keep a matching
# `:=` fallback for a non-vendoring checkout, exactly as PIPELINE_MERGE_PENDING_LABEL does.
: "${PIPELINE_ESCALATED_LABEL:=funnel-escalated}"

# ── Unified-retrospection RETRO_* settings (temperloop#532) ────────────────────
# These five settings are NAMED (in prose) by other items of the
# unified-retrospection epic and VALUED only here, per § Named-setting convention
# convention (`claude/CLAUDE.kernel.md`) — a command spec (`build.md`'s
# 4d-retro MINT step, the pipeline tick's retro-judge emit, `/retro` itself)
# references `$RETRO_*` symbolically and never restates the literal.

# Master on/off for the `/build` 4d-retro MINT (files a per-epic retro
# tracker at epic close). Default ON.
: "${RETRO_MINT_ENABLED:=1}"

# Debounce: minimum age (s) of the oldest `retro-pending` tracker before the
# pipeline tick emits a retro-judge action. Default a 3-day cadence.
: "${RETRO_MIN_INTERVAL:=259200}"

# CI-retry count at/above which a retro tracker is stamped `retro-urgent` at
# mint time (bypasses the debounce above).
: "${RETRO_URGENT_CI_RETRIES:=3}"

# Max number of retro trackers a single `/retro --pending` judge session
# processes (enforced judge-side).
: "${RETRO_BATCH_SESSION_CAP:=5}"

# Model the pipeline runs `claude -p "/retro --pending"` under — its own named
# model setting, distinct from PIPELINE_DRIVE_MODEL (same tier: the judge is a
# safe/standard drive, not a merge-tier high-judgment one).
: "${RETRO_JUDGE_MODEL:=claude-sonnet-5}"

# ── `temperloop configure` headless seat (temperloop#978) ─────────────────────
# A `claude -p` seat lives OUTSIDE the batch pipeline, under bin/subcommands/.
# The model-fan-out inventory (docs/model-fanout-inventory.md) found it as a
# SILENT INHERIT: it spawned a headless session with no --model flag at all,
# so it ran on whatever tier the invoking operator's CLI defaults to — the top
# tier, on a stranger's very first command. This setting is its lever.
#
# The inventory's other two seats were `try.sh`'s shadow-triage pass and
# `try.sh --demo`'s fix call, levered by TRY_TRIAGE_MODEL / TRY_DEMO_FIX_MODEL.
# Both settings were removed when `try` was retired — see the CHANGELOG's
# BREAKING entry for the migration.
#
# The seat runs `--tools ""` (structurally zero tool access), so it cannot
# write, and it is already dollar-capped. It is ALSO invisible to the
# `.temperloop/report.d/tokens` producer: it passes --no-session-persistence,
# so no transcript is written and no spend from this seat appears in the
# corpus that backs the pre-registered token-spend baseline note. See the
# inventory doc's § Measurement for why that gap forced a direct per-call
# measurement rather than a producer read.

# configure.sh — the AI-guided starting-value suggestion pass. Deliberately NOT
# re-tiered, and this one is a MEASURED refusal rather than a cautious one: the
# seat's whole job is to emit a single bare JSON object that the script parses
# with `jq`, and at the cheap tier the model wrapped that object in a fenced
# markdown code block on 4 of 4 runs, which makes `jq` exit 5 and drops EVERY
# setting through to the plain-prompt fallback. The cheap tier is ~2.4x cheaper
# per seat and delivers 0% of the job — the exact whole-job-accounting inversion
# the inventory doc's decision rule exists to catch. Sentinel: empty = inherit.
: "${CONFIGURE_AI_MODEL:=}"

# ── Language-reviewer catalog coverage scan (temperloop#538, ADR 0007/0008) ──
# The catalog's install-time coverage scan (and `make doctor`'s matching
# check) count each candidate language's files in the repo and offer
# activation only for a language that clears this floor — a repo with a
# single stray `.rb` file should not be offered a Ruby reviewer it doesn't
# need. This is INSTALL/DOCTOR-TIME machinery, not a batch-build-pipeline
# setting (contrast PIPELINE_DRIVE_CONCURRENCY above). Default 3: low enough that
# a small-but-real component (a handful of shell scripts, a slim Python
# helper) still gets offered its reviewer, high enough that a single
# generated/vendored/example file doesn't trigger a false-positive offer.
: "${REVIEWER_SCAN_MIN_FILES:=3}"

# ── Prose-plane budget gate (temperloop#719/#725, item prose-budget-gate;
#    ADR 0015) ──────────────────────────────────────────────────────────────
# Two-tier CI cap consumed by workflows/scripts/validate-prose-budget.sh,
# which measures both counts via workflows/scripts/count-prose.sh (never a
# second counting implementation — one compose seam). RATCHET: both caps are
# seeded at the FRESH baseline measured against the tree this item actually
# merges against — never a number recorded earlier and trusted stale. This
# item was seeded three times for exactly that reason: once at initial
# landing (338/1057, already past the epic's own earlier-recorded artifact
# by a few lines), again (340/1057) after a rebase onto a newer main picked
# up an unrelated ~2-line growth in claude/CLAUDE.kernel.md, and again
# (335/1057) by the epic's tighten-caps item (temperloop#730) after a
# subtraction pass (pointer-collapse + apply-approved-deletions) actually
# shrank the tier-1 render — re-measuring and re-seeding at merge-time
# state, rather than patching the gate to tolerate the old number, is the
# ratchet's own "green by construction" rule applied literally: whatever the
# tree looks like right before this PR merges IS the baseline, full stop.
# The tier-2 per-file figure held constant across all three seedings —
# claude/commands/build.md sits exactly at 1057 lines again at this
# tightening, so there is zero headroom to remove and the cap stays put
# rather than manufacturing a reduction. A cap is lowered again only by a
# later config PR, after a subtraction pass actually shrinks the prose
# (never raised/lowered by hand-editing prose to dodge the gate — see the
# setting-registry.tsv row for the same two settings, which must stay
# verbatim-equal to these two literals).
#
# TIER-1: caps the composed KERNEL-AUTHORED render only (claude/
# CLAUDE.kernel.md rendered via install-claude-md.sh's
# INSTALL_CLAUDE_MD_KERNEL_ONLY seam — never the kernel+overlay total).
#
# RAISED 2026-08-01 (item prose-budget-headroom, temperloop#925, epic #923
# "workshop collaborative decision walk") from 335 → 347. The prior seeding
# left ZERO headroom (335/335); this epic's `decision-presentation-template`
# item (#928) is the only item in the epic that touches CLAUDE.kernel.md —
# it qualifies the § Kernel vs overlay routing rule's "named message
# templates" carve-out (kernel.md:45–56) so it no longer reads as a blanket
# license once `### Decision presentation` is carved OUT of overlay-
# redeclaration by message-schema.md's own § Overrides. That qualifier was
# drafted against the live file to measure it, not estimated: 10 net-new
# lines. +20% estimation contingency (drafts precede the actual authored
# PR and typically grow under review) = 2 lines, ceiling. 335 + 10 + 2 =
# 347. See the sibling TIER-2 comment below for why this item bundles both
# caps in one config PR instead of four items each fighting their own gate.
#
# RAISED 2026-08-23 (item grounding-citation-pair, temperloop#1190) from
# 347 → 351. That item adds the kernel capture half of the response-level
# grounding-citation pair (§ Response-level grounding citations), whose
# backstop half already sat in claude/commands/tidy.md with no kernel rule
# to pair with — a half-present pair the capture/backstop gate would fail
# once registered. Measured against the live file, not estimated: 4 net-new
# lines (heading + blank + one paragraph + section separator), 345 → 349.
# +2 lines of review contingency = 351.
#
# NOT RAISED 2026-08-24 (item claude-p-explicit-model, temperloop#1829): that
# item's kernel prose is ONE new bullet under the existing § Subagent usage
# cost-tier routing list (350 → 351), which fits inside the contingency above
# rather than needing a ratchet. Recorded here so the next author knows the
# headroom is now SPENT — tier-1 sits exactly at its cap, so the next
# kernel-prose line does need a measured raise (or a subtraction pass).
: "${PROSE_BUDGET_TIER1_CAP:=351}"
# TIER-2: ONE uniform per-file cap over every tracked claude/**/*.md file
# (agent charters included) — deliberately a single setting, not a per-file
# table (a per-file value would just be a relocated exemption mechanism,
# which this item has none of). Seeded to clear the largest tracked file at
# landing time (claude/commands/build.md, 1057 lines, unchanged across all
# three seedings) — every other file already sits well under this cap, by
# construction of "uniform".
#
# RAISED 2026-08-01 (item prose-budget-headroom, temperloop#925, epic #923
# "workshop collaborative decision walk") from 1057 → 1128. `build.md`
# stays the largest file at 1057 and is untouched by this epic — the new
# binding file is `claude/commands/workshop.md` (938/1057 at measurement
# time, 119 lines of headroom), which FOUR items in this epic all grow:
# `premise-gate-presentation` (#931), `workshop-coverage-walk` (#930),
# `workshop-congruence-walkthrough` (#932), and `workshop-ratify-gate`
# (#934). Each region was drafted against the live file to get a real
# line count rather than an estimate pulled from the epic's own ~6–8-stop
# guess:
#   - Step 1.3b(iii) presentation re-point (premise-gate-presentation):  +7
#   - Step 2 full rewrite, old 93 lines → new 143 (workshop-coverage-walk): +50
#   - new Step 3.5 block (workshop-congruence-walkthrough):               +70
#   - Step 3.1.4 coverage-record tie-in (workshop-congruence-walkthrough): +4
#   - Step 4.1b finding-disposal tie-in (workshop-congruence-walkthrough): +4
#   - new Step 4.1c gate + migration carve-out (workshop-ratify-gate):    +23
#                                                                  subtotal: 158
# 938 + 158 = 1096. +20% estimation contingency on the 158 (drafts precede
# the actual authored PRs, which typically grow under review) = 32,
# ceiling. 1096 + 32 = 1128. This is a GLOBAL consequence, stated plainly
# per the operator's 2026-08-01 decision: TIER-2 is one uniform cap over
# every tracked claude/**/*.md file, so raising it to fund workshop.md
# relaxes the budget for every other kernel doc too — the alternative
# (a subtraction pass shrinking workshop.md first) was considered and not
# taken; see the epic's plan note § Re-triage signal 3 and this item's own
# Decisions-note record for the full rationale.
#
# SECOND RAISE, 1128 → 1154 (2026-08-01, temperloop#947, same epic). The
# first of the four items above has now landed and the estimate ran hot:
# `workshop-coverage-walk` (#930, PR #946) came in at +60 against its
# drafted +50 — 938 → 998, a 1.20 overrun factor. Re-projecting the three
# remaining items at that observed factor:
#   - premise-gate-presentation (#931):        +7  → 9
#   - workshop-congruence-walkthrough (#932): +78  → 94
#   - workshop-ratify-gate (#934):            +23  → 28
#                                        subtotal: 130
# 998 + 130 = 1128 — EXACTLY the cap set above, i.e. zero slack. That is
# the number worth acting on: three items grow this one file, so whichever
# merges last absorbs every earlier item's overrun and reds on someone
# else's estimate. +20% contingency on the 130 (same convention as the
# first raise) = 26, ceiling. 1128 + 26 = 1154.
# The global consequence stated above is UNCHANGED and applies again: this
# is one uniform cap, so a second relaxation loosens every tracked kernel
# doc a second time. That the cap needed raising twice inside one epic is
# itself signal that `workshop.md` carries real growth pressure a
# subtraction pass will eventually have to address; the operator decided
# 2026-08-01 to raise rather than run that pass on a file three in-flight
# items are concurrently editing.
#
# THIRD RAISE, 1154 → 1186 (2026-08-01, temperloop#954, same epic). The
# second raise undershot because it sized off a ONE-ITEM sample. With the
# whole L3 level landed, all four items are measured, and the drafted
# estimates ran hot by far more than the 1.20 the second raise assumed:
#   - workshop-coverage-walk (#930, PR #946):        +50 drafted →  +60  (1.20)
#   - premise-gate-presentation (#931, PR #950):      +7 drafted →   +9  (1.29)
#   - workshop-congruence-walkthrough (#932, PR #952):
#                                                    +78 drafted → +137  (1.76)
#                                        blended: 135 drafted → 206 (1.53)
# The congruence item is the outlier that broke the second estimate: its
# drafted +78 only ever priced the NEW Step 3.5, never the two other
# regions it also had to touch (Step 3.1.4, Step 4.1b) nor the
# docs/features/workshop.md update. Post-L3 merged `main` measures 1144 —
# ground truth read off the combined-tree pre-check worktree, not computed
# — leaving 10 lines under the 1154 cap. The one remaining item cannot fit:
#   - workshop-ratify-gate (#934): +23 drafted → +35 at the blended 1.53
# 1144 + 35 = 1179. +20% contingency on the 35 (same convention as both
# earlier raises) = 7, ceiling. 1144 + 42 = 1186.
# The global consequence stated above is UNCHANGED and applies a THIRD
# time. Two alternatives were considered and declined by the operator
# 2026-08-01: (a) a subtraction pass on workshop.md first — declined as an
# unplanned item on the critical path that would edit the very file
# workshop-ratify-gate then rewrites; (b) a per-file cap for workshop.md —
# declined because validate-prose-budget.sh's own header pins "ONE uniform
# per-file cap, never a per-file table (a per-file value would just be a
# relocated exemption mechanism; this gate has none)", so it is a contract
# change, not a tuning. workshop.md at 1144 became the LARGEST tracked
# kernel doc (past build.md at 1061), and this cap was raised three times
# in one day to fund it — the subtraction pass deferred above was filed as
# its own follow-up (temperloop#956).
#
# LOWERED, 1186 → 1100 (2026-08-02, temperloop#956, the deferred subtraction
# pass). Ran the subtraction on workshop.md itself: removals and
# consolidations only (never a behavior deletion — every step, gate, and
# named rule stayed specified, restated by reference instead of copied
# where it duplicated `claude/design-schema.md`/`claude/message-schema.md`
# content already covered elsewhere in the file) took it from 1181 lines to
# 1041. `claude/commands/build.md` is now the largest tracked file again, at
# 1100 lines — untouched by this item. Same "zero headroom, seeded to the
# largest tracked file" convention as the very first seeding of this cap:
# 1100. The ratchet moves both ways — a future raise still needs its own
# measured justification, never a restored high-water mark.
#
# RAISED, 1100 → 1111 (2026-08-13, temperloop#1432). build.md §3c required
# resolving the effective (kernel ∪ project) engineering principle set and
# embedding it in the worker prompt, but nothing implemented it — this item
# closes that gap: a new "## Step 1.8 — Resolve the effective engineering
# principle set" section (the once-per-run orchestrator resolution §3c/§3e
# both reuse) plus one new arg-description bullet for its `principlesSummaries`
# / `principlesDefaultRepo` hand-off. Trimmed once already (merged 7 numbered
# sub-steps to 5) before raising; `claude/commands/build.md` is again the
# largest tracked file, at 1111 — same zero-headroom convention as every
# prior seeding.
#
# RAISED, 1111 → 1130 (2026-08-13, temperloop#1319). Two concurrent items
# both add real §3c/§3f/Step-6 contract surface to build.md: #1319's
# discrimination-evidence degraded-case clause (the §3e spec review's [HIGH]
# finding — a named warning + Step-6 tally when a worker omits
# `discrimination_evidence`, plus the deferred-bare-gate reconciliation
# clause) and the sibling item #1430's §3e review-step prose, building
# concurrently in a separate worktree. #1319 folded bullets together once
# already (the prior 1100→1111 raise's PR) to stay under the then-cap;
# folding further here would damage readability rather than trim genuine
# redundancy, so the ratchet moves up instead — raised past #1319's own
# immediate need to leave #1430 headroom too, rather than raising twice in
# one day for two items landing the same week.
# Raised again 1130 -> 1140 (temperloop#1663). §3e.5 gained ONE bullet, and it
# is a contract bullet rather than commentary: §3e.5 stopped being the bare
# repo-wide run it had been since PR #309, so the section now has to state what
# scopes it, why that is safe, which seam carries it, and where the escape hatch
# actually lives (a config FILE — the env layer is scrubbed by #1241). Folding
# that into a neighbouring bullet would bury a safety property inside prose about
# pipefail. Same call, same reason, as the #1319/#1430 raise above: taken past the
# immediate need (+1) so the next build.md edit does not spend a PR on a ratchet.
# Raised again 1140 -> 1177 (2026-08-24, temperloop#1310). /build's own transcript
# became a reported surface: three level-composition rosters (§ 3-launch at level
# launch, § 4a at the merge gate, § 4d at the level close-out), because /workflows
# is opt-in and temperloop#1294's two remaining asks are harness-side and
# unfixable from this repo. The RENDERING moved into code (`plan.sh roster`), so
# the prose that landed here is only what a spec must carry: three invocation
# sites, why each one is where it is, and one worked example apiece — the examples
# are the bulk, and they are load-bearing (an operator report nobody has seen the
# shape of is not reviewable). A trim pass ran on the new prose first (1180 -> 1177
# measured, not drafted) before the ratchet moved. Reseeded to build.md's measured
# size under the zero-headroom convention this row has used since temperloop#956.
#
# RAISED 1177 -> 1178 (2026-08-24, temperloop#1688): `pr.sh push` grew a new
# value in its frozen outcome set, `PUSHED_UNWATCHED`, so build.md 3f step 1
# grew the one bullet that gives that outcome a disposition. Measured net +1
# (1177 -> 1178, post-rebase); the item's three other build.md edits are
# in-place rewrites of existing lines and cost nothing. No subtraction pass ran,
# deliberately: build.md's per-outcome disposition list is precisely what stops
# an undocumented payload shape from becoming a silent stall, so folding this
# bullet into the neighbouring PUSH_REJECTED one — or trimming an unrelated
# contract line to buy the line back — would delete more contract surface than
# the ratchet step costs. Reseeded to build.md's measured size, zero headroom.
#
# RAISED 1179 -> 1181 (2026-09-11, temperloop#1908): Step 0.5 item 5 (the
# reconciliation report) grew one new paragraph — the capture-at-source call
# to `emit-resume-recovery.sh`, the new resume-recovery raw-lake stream this
# item ships (a `/build` resume is not a drive and never writes a
# command-run, so it needed its own stream rather than a command-runs field).
# Measured net +2 (one prose line plus the markdown paragraph's blank-line
# separator); every other file this item touches is a new file or a
# registry/table row, not a build.md edit. No subtraction pass ran: the new
# paragraph is the one sentence + command line the item's own acceptance bar
# asked for, already the minimum this capture-at-source call can cost.
# Reseeded to build.md's measured size, zero headroom, same convention as
# every raise since temperloop#956.
#
# RAISED 1181 -> 1182 (2026-09-12, temperloop#1931): §3c grew one new bullet
# — a single sentence pointing the worker at build-level.mjs's new
# gateRegistrationChecklistSection() (the "register a new gate script before
# running --scoped" checklist) rather than restating its registry list here,
# per this gate's own pointer-not-restatement convention. Measured net +1
# (the item's own acceptance bar asks for exactly "one sentence"). No
# subtraction pass ran: a single bullet is already the minimum this pointer
# can cost. Reseeded to build.md's measured size, zero headroom, same
# convention as every raise since temperloop#956.
#
# RAISED 1182 -> 1183 (2026-09-12, temperloop#1934 round 2): a workflow-
# reviewer HIGH finding caught that the new activationProofSection() mirror
# sentence (the round-1 raise above never touched it) landed only in Step 3's
# Workflow-path items[] contract bullet — §3c, the path the conversational
# `--no-workflow` run actually reads before its first worker spawn, never
# gained it, so that path could still spawn a class-A worker that never sees
# its `proof:`. §3c grows one new bullet mirroring the existing pattern (the
# changelog-fragment and foreground-only clauses' own §3c mirrors). Measured
# net +1; no subtraction pass ran, one bullet already being the minimum this
# mirror can cost. Reseeded to build.md's measured size, zero headroom, same
# convention as every raise since temperloop#956.
#
# RAISED 1183 -> 1186 (2026-09-12, temperloop#1910 L6 "state-graph-queries"):
# Step 0.5 grew the state-graph cross-check call (one prose sentence + the
# build/query resume call line) and Step 6's summary grew the matching
# per-source tally bullet — the item's own acceptance bar asks for exactly
# this call line plus one sentence, nothing more. Measured net +3 (the new
# Step 0.5 paragraph's blank-line separator + sentence-and-call line, plus
# the one Step 6 bullet); no subtraction pass ran, three lines already being
# the minimum this wiring can cost. Reseeded to build.md's measured size,
# zero headroom, same convention as every raise since temperloop#956.
#
# RAISED 1201 -> 1261 (2026-09-17, temperloop#2071, AHEAD of temperloop#2081
# "--dual-build flag + orchestrator-side pre-flight" (size M) and
# temperloop#2083 "level-pick + the two operator levers" (size L), both in
# epic #2065 "new-work dual-build harness"): build.md sits at exactly the
# 1201-line cap with zero headroom (the standing convention since
# temperloop#956), so BOTH later items would immediately need their own
# mid-build ratchet step the moment either lands — the same
# "ships as its own PR ahead of the level, never a mid-build config change"
# contingency temperloop#1998 already used for the /workshop rewrite. #2081
# adds the `--dual-build <tier>=<candidate>` flag description plus a new
# Step 0/1 pre-flight-and-consent block (ceiling projection, epic-scoped
# grant honoring, the flag-less-resume refusal text) — projected ~35 lines.
# #2083 adds a level-pick escalation handler section (the pre-registered
# tally, the calibration-gated confirm-vs-optional-override split, the
# per-item-override disposition) — projected ~25 lines; its
# `claude/presentation-plane.md` row is a DIFFERENT tracked file, currently
# far under this same uniform cap, so it costs nothing against build.md's
# own headroom. Projected total 60 lines; NO subtraction pass ran ahead of
# it (nothing to subtract — build.md is already at zero headroom, per every
# raise since temperloop#956), so the raise is the projected total with no
# further contingency layered on top, matching this ratchet's zero-headroom
# convention rather than the mid-epic percentage-contingency framing
# temperloop#925/#947/#954 used before that convention was adopted. This
# item deliberately raises the cap WITHOUT itself adding any build.md prose
# (it is the epic's only L0 item touching this file, by design — see
# `[[Patterns/temperloop - a new setting defined on two parallel branches
# conflicts dangerously]]`), so build.md's own measured size is unchanged by
# this commit; the two cited later items reseed the cap to build.md's new
# measured size when they land, per the usual convention, and may raise or
# lower it again if their measured cost differs from this projection.
: "${PROSE_BUDGET_TIER2_FILE_CAP:=1261}"

# ── Pipeline spend profiler (temperloop#958) ───────────────────────────────
# Settings for `workflows/scripts/pipeline-spend-report.sh` and its
# `.temperloop/report.d/tokens` drop-in producer. That script resolves each
# of these with a `:?` (never a duplicated `:=` literal), so THIS FILE is the
# only place any of these values exists — which is what makes "no weight
# literal in the script" a structural fact rather than a review promise
# (kernel CLAUDE.md § Named-setting convention).
#
# COST WEIGHTS. A raw token count ranks spend WRONGLY, because the four token
# classes do not bill alike. These are relative multipliers normalized on
# ordinary input tokens (input = 1), not prices — no dollar constant lives
# anywhere in this loop (workflows/scripts/lib/report.contract.md § Non-goals,
# "no precise cost accounting"). The ratio that matters most is
# cache_create : cache_read, ~12.5:1 — during temperloop#953 ranking by RAW
# cache-read said the machinery agents were ~10% of spend; cost-weighted they
# are 31.8%. Re-derive these from the model's published per-class rates if
# they ever move; do not tune them to make a number look better.
: "${SPEND_WEIGHT_INPUT:=1}"
: "${SPEND_WEIGHT_CACHE_READ:=0.1}"
: "${SPEND_WEIGHT_CACHE_CREATE:=1.25}"
: "${SPEND_WEIGHT_OUTPUT:=5}"
#
# CLASSIFICATION THRESHOLDS, in deduped API calls per agent. Two of them, on
# purpose — see pipeline-spend-report.sh's header for why one cannot serve
# both jobs. SPEND_MACHINERY_MAX_CALLS is the spend-ATTRIBUTION split: at or
# below it an agent is /build machinery (a prelude / pr-batch / ci-batch
# executor that runs shell commands and reasons about nothing); above it, an
# item worker. SPEND_WORKER_PROFILE_MIN_CALLS is the floor for the "typical
# item worker" PROFILE, set higher so the long tail of short-lived helper
# agents on the item-worker side of the attribution split doesn't drag the
# median away from the thing an operator means by "an item worker".
# Both are seeded at the values that reproduce the temperloop#953 baselines
# over that investigation's 1,622-agent corpus (machinery 31.8% / item
# workers 68.2%; median profiled worker 61 calls, ~161K peak context).
: "${SPEND_MACHINERY_MAX_CALLS:=6}"
: "${SPEND_WORKER_PROFILE_MIN_CALLS:=40}"
#
# Transcript root. Claude Code's own per-project state dir; the profiler walks
# `$SPEND_TRANSCRIPT_ROOT/**/subagents/workflows/wf_*/agent-*.jsonl` under it
# and reads nothing else. Point it at a fixture tree to test, or at a synced
# copy of another host's transcripts to profile that host.
: "${SPEND_TRANSCRIPT_ROOT:=$HOME/.claude/projects}"

# ── knowledge_store root (foundation #777, Epic A #762 "kernel split";
#    kernel-literal-scrub, temperloop#189) ──────────────────────────────────
# `workflows/scripts/lib/knowledge_store.sh` (the document-I/O seam) owns
# `KNOWLEDGE_STORE_ROOT`'s KERNEL default (an XDG per-user data dir, correct
# for a stranger's fresh install with no vault). THIS file — the kernel's own
# tracked layer-5 default set — deliberately does NOT re-seed a different
# default here: a personal vault path is exactly the kind of operator-
# specific value the six-layer ladder's layers 3/4 (machine conf /
# build.config.local.sh, both sourced ABOVE this point) exist for, or —
# for a downstream repo that vendors this file — its own edited copy of
# this line (layer 5's own "consuming repo that vendors/edits its own copy"
# case, per the ladder writeup above). An operator whose structured notes
# live in a real vault sets `KNOWLEDGE_STORE_ROOT` at one of those layers;
# this kernel file simply leaves the var unset here and lets
# `knowledge_store.sh`'s own generic default apply when nothing upstream
# has claimed it. (Formerly this file hardcoded a personal vault path here
# as a layer-5 default — removed as scrub debt; see git history on this
# line for the prior literal.)

# ── Knowledge-store agent-plane render mode (temperloop#1599, kernel half of
#    foundation#956 "CLAUDE.md flip") ───────────────────────────────────────
# `workflows/scripts/install-claude-md.sh`'s "## Knowledge store routing"
# section renders an "Agent-plane access rule" one-liner by MECHANICALLY
# probing `[ -d "$root/.obsidian" ]` at compose time. That probe is correct
# pre-cutover (an Obsidian vault = route through its MCP tools) but wrong
# FOREVER post-cutover (foundation epic #951 Phase 3): Obsidian stays
# installed indefinitely as a plain *viewer* onto the now markdown-canonical
# store, so `.obsidian/` never goes away, and the probe would keep rendering
# the retired MCP-only rule on every re-install with no way to opt out.
#
# This setting is the explicit override the probe was missing. Values:
#   auto   (default) — today's unchanged behavior: probe `.obsidian` and
#          render the MCP rule when present, the direct-access rule when not.
#          A stranger's fresh kernel install renders byte-identical output to
#          before this setting existed.
#   direct — force the post-cutover rule (files canonical; agent-plane reads
#          via `Read`/`Glob`; concept/idea search via `ks_search`; Obsidian,
#          if present, is a viewer only) REGARDLESS of `.obsidian` presence.
#          An operator flips this once their own store has actually migrated
#          off the Obsidian MCP transport (knowledge_store.contract.md's own
#          "Obsidian-mode note" documents that transition).
: "${KNOWLEDGE_STORE_AGENT_PLANE:=auto}"   # auto|direct — see install-claude-md.sh render_knowledge_routing

# ── Pipeline label provisioning (temperloop#795) ───────────────────────────────
# BOTH pipeline labels above (`funnel-merge-pending`, `funnel-escalated`) must EXIST in
# every repo the pipeline drives, or a silent-thrash failure results (see
# pipeline-drive.sh's own "Pipeline label self-provisioning" comment for the failure
# mode). This used to be a manual, onboarding-time `gh label create` step documented
# here — now SELF-HEALING: pipeline-drive.sh ensures each label at its point of use
# via the board adapter's memoized `_board_issues_ensure_label` (lib/board.sh:1149),
# the same idiom capture.sh's self-healing `fnd:` labels use, so no third repo needs a
# manual onboarding step here at all.

# ── State graph (temperloop#1910, epic "graph of record", ADR 0033) ────────
# workflows/scripts/build/state-graph.sh derives one typed nodes+edges
# snapshot per repo from the board, open PRs, and worktrees (later: plan
# notes, the workflow journal, tmux markers), stored through the namespaced
# board cache library (lib/cache.sh, kind=state-graph). All three settings are
# named symbolically everywhere outside this file — never re-valued in prose
# (§ Named-setting convention) — including in state-graph.sh's own comments,
# the ontology registry, and ADR 0033.
#
# Age past which a `read` of the on-disk snapshot (a query, or state-graph.sh's
# own internal read helper) reports every source `stale` rather than the
# status recorded at build time, so a consumer never silently acts on data
# this run has already outgrown (ADR 0033). `build` itself always performs a
# fresh live fetch and is therefore never stale at the moment it writes.
: "${STATE_GRAPH_MAX_AGE_S:=300}"
# Wall-clock threshold, in milliseconds, past which `state-graph.sh query
# <name>` (a later item) or `bench` flags a run as slow — the measured
# trigger for the eventual JSON-snapshot-to-SQLite migration ADR 0033 names
# as a follow-on, never a design-time judgment call.
: "${STATE_GRAPH_QUERY_SLOW_MS:=500}"
# Number of distinct days `state-graph.sh soak --count` must have recorded
# before ADR 0033's independence cross-check is treated as trustworthy.
# Rationale for the default: chosen by judgment, not derived — the soak buys
# exposure to varied board states (parks, merges, claims going stale,
# worktrees appearing and vanishing), and a shorter window sees fewer
# situations and so catches fewer disagreements. No sample-size or coverage
# argument was ever made for this number; raising or lowering it is an
# operator call, which is why it is a setting rather than a literal.
: "${STATE_GRAPH_SOAK_DAYS:=14}"
# How many days may pass since the soak log's most recent qualifying record
# before `state-graph.sh soak --status` reports the soak clock `stale` rather
# than `current`. Compared with `<=`, so a record exactly this many days old
# is still current. Rationale for the default: the soak's intended cadence is
# daily, and a record from yesterday is the ordinary reading at any hour
# before today's run has happened — so 1 is the smallest window that does not
# report a healthy daily soak stale every morning. Raise it for a deliberately
# looser cadence; 0 demands a record dated today.
: "${STATE_GRAPH_SOAK_STALE_DAYS:=1}"

# ── Comparison-statistics library (temperloop#1249, epic #1225 "model
#    comparison harness") ───────────────────────────────────────────────────
# workflows/scripts/model-comparison/stats.sh: bootstrap confidence intervals,
# the minimum-detectable-effect disclosure, the inconclusive floor, and
# emit-coverage %. Every one of these five is a real operator-facing tunable
# (named symbolically in stats.sh's own header, never re-valued in prose —
# see § Named-setting convention).
#
# Sample-size floor: below this many outcomes, `verdict` is ALWAYS
# "inconclusive" and never returns a winner, whatever the bootstrap CI shows.
: "${MODEL_COMPARISON_MIN_SAMPLE_N:=20}"
# Percentile-bootstrap resample count.
: "${MODEL_COMPARISON_BOOTSTRAP_ITERATIONS:=2000}"
# Resampling RNG seed — fixed (not time-varying) so the SAME deltas always
# reproduce the SAME confidence interval; a real report needs a reproducible
# number, and the library's own known-answer fixture test depends on this.
: "${MODEL_COMPARISON_BOOTSTRAP_SEED:=1729}"
# Confidence-interval width (pct), e.g. 95 = a 95% CI. Also the width the
# minimum-detectable-effect figure is computed at, so the MDE and the CI it
# bounds are always stated at the same confidence.
: "${MODEL_COMPARISON_CI_WIDTH_PCT:=95}"
# The QUALITY axis's two bases can disagree, and this is how far apart they
# have to be before the report says so out loud (temperloop#1744, in
# percentage POINTS of relative delta).
#
# Two figures exist because the arms rarely judge the same set of records: an
# UNPAIRED figure over each arm's own judged rows, and a PAIRED figure over
# records judged in BOTH arms. On the temperloop#1656 A/A run — where the true
# arm effect is zero by construction — they came out at -2.89% (unpaired) and
# -6.31% (paired), 3.42 points apart, on opposite sides of the 5% A/A bar. One
# said "passes", the other said "breaches"; both were correct arithmetic.
#
# 2 points is set BELOW that observed 3.42 so the disagreement that motivated
# this disclosure would itself have been flagged, and above the sub-point
# wobble that a single differing record produces on a floor-sized corpus.
# Raise it to disclose less, lower it to disclose more; it changes only what
# is SAID, never which basis the statistics are computed on (always paired).
: "${MODEL_COMPARISON_QUALITY_BASIS_DISAGREEMENT_PCT:=2}"
# The quality effect size a comparison is SIZED for, as a percentage of the
# baseline paired mean (temperloop#1609). It sets no gate and withholds no
# verdict — its only job is the report line that says how many judged pairs
# would be needed to detect a difference this size, so a permanently
# unreachable comparison is visible up front rather than after the spend.
#
# 5% is the bar both A/A validation runs (#1262, #1656) were read against, so
# the projection answers the question those runs actually raised: #1262 came in
# at +2.02% and #1656 at -2.89% unpaired, both "under the 5% bar" — but neither
# run had the statistical power to ENFORCE that bar, which is the gap this
# figure makes visible instead of leaving to be worked out by hand.
: "${MODEL_COMPARISON_QUALITY_TARGET_EFFECT_PCT:=5}"
# `coverage`'s denominator: the emit-FEASIBLE seat subset — the three seats
# the L0 usage-capture-feasibility spike (temperloop#1246) measured ("only 3
# of the pipeline's 12 spawn seats can emit a TOKEN-BEARING attribution
# record today") PLUS "build-worker" (temperloop#2065 "worker-cost-capture"),
# the /build 3c per-item worker — emit-feasible (it DOES write a record) but
# never token-bearing (a Workflow agent() call has no envelope to read tokens
# from; its record is permanently attribution-only). "Feasible" here tracks
# WIRING — did the seat write a record for this outcome — never "carries real
# tokens"; see workflows/scripts/report-producers/model-comparison's own
# FEASIBLE_SEAT_ROSTER comment. Deliberately NOT the full 12-seat inventory.
# A coverage figure below 100% is expected and structural, not a defect to
# chase to zero.
: "${MODEL_COMPARISON_EMIT_FEASIBLE_SEATS:=4}"

# ── Replay corpus selection + isolation (temperloop#1254, epic #1225 "model
#    comparison harness") ───────────────────────────────────────────────────
# workflows/scripts/model-comparison/replay.sh: `corpus` (real `gh` reads,
# selects eligible closed-issue + merged-PR pairs from this repo's own
# history) and `worktree-prepare`/`worktree-teardown` (the isolated replay
# worktree, built on workflows/scripts/build/worktree.sh's existing lifecycle
# — see that file's header and Context/temperloop - replay ground-truth seam.md
# for why replay.sh adds no flag there and instead rewinds an unmodified
# `create`). Four operator-facing tunables, named symbolically in replay.sh's
# own header, never re-valued in prose (§ Named-setting convention).
#
# Default number of merged PRs `corpus` asks `gh pr list` for when no
# explicit `--limit`/`--target` is given. The ground-truth spike measured a
# ~52% survival rate applying the scope-closure rule to 46 single-issue
# merged PRs (temperloop#1247) — this default is sized to that same
# ballpark scan.
: "${REPLAY_CORPUS_LIMIT:=60}"
# Multiplier `corpus --target N` applies to compute its default `--limit`
# (limit = target * multiplier) when `--limit` is not given explicitly. 2x
# is the spike's own measured corpus-yield guidance: "budget ~2x its target
# size" (24/46 = 52% usable survival after scope closure).
: "${REPLAY_CORPUS_SAMPLE_MULTIPLIER:=2}"
# Space-separated file-extension list `diff-scope`'s N-bucket (solution-
# surface) path extraction matches against the pre-cut issue text — mirrors
# the spike's own demonstrated named-path regex
# (`[A-Za-z0-9_./-]+\.(py|sh|mjs|md|tsv|json)`).
: "${REPLAY_NAMED_PATH_EXTENSIONS:=py sh mjs md tsv json}"
# The sentinel `remote.origin.pushurl` value `worktree-prepare` writes,
# scoped ONLY to the replay worktree via git's per-worktree config extension
# (`extensions.worktreeConfig`), so a `git push` issued from inside an
# isolated replay worktree cannot resolve a real transport — structural,
# not a post-hoc probe. Deliberately not a real-looking URL, so a stray push
# attempt fails fast on an unresolvable scheme rather than hanging on DNS.
: "${REPLAY_PUSH_DISABLE_SENTINEL:=replay-worktree-push-disabled://no-remote}"

# ── Replay pre-flight estimate + per-comparison ceiling (temperloop#1256,
#    epic #1225 "model comparison harness") ─────────────────────────────────
# workflows/scripts/model-comparison/replay.sh's `preflight` subcommand: the
# spend gate that prints eligible-N, estimated cost, and significance
# reachability (via stats.sh's own `mde` primitive — never a second,
# hand-rolled computation of it) BEFORE a replay batch runs. Four
# operator-facing tunables, named symbolically in replay.sh's own header,
# never re-valued in prose (§ Named-setting convention).
#
# ── THE COST UNIT: COST-WEIGHTED TOKEN UNITS (temperloop#1380) ─────────────
# Every "TOKENS" setting in this block is denominated in COST-WEIGHTED token
# units — the SPEND_WEIGHT_* multiply-add over the raw input / cache_read /
# cache_creation / output classes — and NOT in raw token counts. That is the
# same unit workflows/scripts/report-producers/model-comparison reports in
# (`cost_basis.unit: "cost-weighted-token-units"`), which is the whole point:
# before #1380 pre-flight said `cost_basis: "token_count"` (a RAW sum) while
# the report said "cost-weighted token counts", two non-comparable units
# sharing the word "token", so an operator could not reconcile the figure
# they authorized against the figure the report handed back. One unit now,
# named identically on both sides.
#
# Two consequences worth stating out loud:
#   * These values are only meaningful WITHIN one SPEND_WEIGHT_* retune
#     epoch. Retune the weights and this per-replay figure needs re-deriving
#     from the raw measurement below, because the same tokens then price
#     differently. (Same caveat the report producer publishes as its
#     `weights_caveat`.)
#   * Cost-weighted is the unit that corresponds to SPEND, which is what a
#     spend gate is for. The dominant term in a real replay is cache_read
#     (2.38M of 2.51M raw on the measurement below), which the default
#     weights price at a tenth — so a RAW budget would be dominated by the
#     cheapest tokens in the batch.
#
# Max number of CORPUS RECORDS `preflight` will size a single invocation's
# cost estimate against, regardless of how large the corpus's eligible-N is —
# a larger corpus is spent across more than one invocation, never one
# unbounded batch.
: "${REPLAY_PREFLIGHT_BATCH_CAP:=40}"
# Estimated combined (candidate + judge) COST-WEIGHTED TOKEN UNITS that ONE
# EXECUTED replay (one corpus record in ONE arm) costs.
#
# PROVENANCE — READ THIS BEFORE TRUSTING IT. n = 1. This is an ESTIMATE
# grounded in a SINGLE observed live replay (the temperloop#1262 harness
# validation run, recorded in temperloop#1380), not a fitted average and not
# a distribution: one replay measured
#     input 49 · output 19,890 · cache_read 2,383,486 · cache_creation 102,946
#     -> raw total 2,506,371 · cost-weighted 466,530 (default SPEND_WEIGHT_*)
# rounded UP to the nearest 10,000 for the value below. It supersedes the
# original hand-set placeholder, which was 3.1x low in this unit (and 16.7x
# low against the same replay's raw total). ONE sample cannot express
# variance, so treat this as an order-of-magnitude figure that a real
# distribution should replace once more than one replay has been executed;
# `preflight` publishes the same provenance on every run in its
# `tokens_per_replay_basis` field rather than presenting the literal as
# though it were derived from the operator's own records.
#
# THE FALLBACK, NOT THE DEFAULT PATH (temperloop#1555). Since #1555 this
# literal is what `preflight` uses when the host carries FEWER than
# REPLAY_PREFLIGHT_DERIVE_MIN_N observed replay-candidate records — a host
# with enough of them derives the figure from those records instead and says
# so. It is deliberately NOT retuned to any measured mean, because a second
# hand-transcribed constant would rot exactly the way the n=1 one did. The
# derivation is the fix; this stays the honest unmeasured-host fallback.
#
# HOW LOW IS IT, REALLY (temperloop#1604)? Deliberately not answered with a
# number here — that is the rot this block already warns about, and a figure
# transcribed into config prose is stale the moment the next batch runs. The
# live answer is published on EVERY preflight, by the gate itself:
#
#     replay.sh preflight --corpus-file <corpus> | jq .observed_replay_cost
#
# …which reports this host's own records_n, mean, p50, p90 and spread, and
# `tokens_per_replay_basis` states which figure is in force and why. As a
# calibration datum rather than a value to copy: the #1656 run put it around
# 2.2x low on a 59-record basis, having read ~1.5x low at n=14 — the gap
# WIDENS as the corpus grows, which is the argument against chasing it with
# a constant.
#
# The drift is also caught automatically after the fact. batch.sh publishes a
# `spend_reconciliation` block comparing the projected figure the gate
# authorized against what the run actually cost, and raises `drift_alert` past
# MODEL_COMPARISON_SPEND_DRIFT_ALERT_PCT in either direction. So a stale
# estimate surfaces from the pipeline rather than from someone summing the
# lake by hand — the second of temperloop#1604's two fix directions, and the
# one compatible with not hand-transcribing a new constant.
: "${REPLAY_PREFLIGHT_TOKENS_PER_REPLAY:=470000}"
# The minimum number of OBSERVED replay-candidate model-usage records
# (workflows/scripts/emit-model-usage.sh's raw lake, seat "replay-candidate",
# usage_source "cli-envelope") `preflight` requires before it DERIVES the
# per-replay figure from them instead of using the literal above.
#
# Why 5: the estimate authorizes spend, so the derivation has to be worth
# more than the literal it replaces, and a mean over one or two records is
# not — the observed distribution has a 4.8x spread, so at n=2 the mean can
# sit anywhere in a factor-of-two band depending on which two records ran. By
# n=5 the mean is stable enough to beat a 1.49x-low constant, and preflight
# publishes the n, the spread and the p90 alongside it so an operator is
# never handed a bare point estimate to trust. Below the threshold the
# literal is used and the basis string says the figure is UNMEASURED on this
# host — never that it was derived. Set 0 to force the literal always (a host
# that deliberately wants the configured constant, e.g. a fresh SPEND_WEIGHT_*
# retune epoch whose historical records are no longer comparable).
: "${REPLAY_PREFLIGHT_DERIVE_MIN_N:=5}"
# Model-id patterns the pre-flight derive basis treats as NON-REAL and excludes
# (temperloop#1657). Space-separated shell glob patterns, matched against a
# model-usage record's `model` field.
#
# Why this exists: `replay.sh preflight` derives its per-replay cost basis from
# this host's own observed replay-candidate records, which is the whole point of
# temperloop#1555 — but a STUBBED replay emits a real attribution record too, so
# fixture output lands in the same lake as live spend. On the host that surfaced
# this, 18 of 32 basis records were `recorded-stub-model` carrying an identical
# hardcoded 4,487-unit token block, deflating the derived estimate 2.27x — to
# 308,757 against a real-record mean of 699,963. That is FURTHER from the truth
# than the 470,000 literal the derive path was built to replace, and unlike the
# literal it publishes a "DERIVED from this host's own observed records"
# provenance string that reads as a measurement.
#
# A DENYLIST rather than an allowlist, deliberately: an allowlist of known-real
# model ids would need updating for every new candidate model, and the
# cross-vendor comparison this harness exists to enable will name models no
# kernel list can anticipate — excluding a real one would silently skew the
# basis. Failing to exclude a NEW fixture sentinel is the cheaper error, and it
# is visible: the pre-flight publishes excluded_stub_records_n beside the
# estimate.
#
# The writer-side half — a stubbed run not reaching the production lake at all
# — is temperloop#1747, and is NOT fixed by this setting.
# To DISABLE the exclusion, set a pattern that matches nothing (e.g.
# `__none__`) — not the empty string. This file assigns with `:=`, which treats
# an empty value as unset and restores the default above.
# `*recorded-*` is here because a fixture stub is often named to look REAL:
# this repo's own suite emits `claude-recorded-candidate`, carrying the
# `claude-` prefix precisely so it passes the validator's family enum. A
# denylist keyed only on obvious sentinels would never see it. That is the
# standing weakness of a denylist, and it is why the WRITER guard in replay.sh
# — not this list — is the actual fix (temperloop#1747): with the guard in
# place no fixture record reaches the lake whatever it calls itself, and this
# list only has to cope with what is already on disk.
: "${REPLAY_PREFLIGHT_STUB_MODEL_PATTERNS:=recorded-* stub-* *-stub-model *-stub *recorded-*}"
# Per-comparison (i.e. per preflight invocation's planned batch) ceiling, in
# COST-WEIGHTED TOKEN UNITS. A projected batch whose estimated cost exceeds
# this STOPS at preflight — never partway through a later execution step.
#
# RE-DERIVED FOR THE NEW UNIT (temperloop#1380) — this value changed meaning,
# so do not read it as the old one. It is re-derived under the SAME design
# rule its predecessor was written to ("a default-cap batch sits comfortably
# under it; raising REPLAY_PREFLIGHT_BATCH_CAP well past default is what trips
# it"), now with the corrected two-arm arithmetic and the measured per-replay
# figure: REPLAY_PREFLIGHT_BATCH_CAP records x 2 arms x
# REPLAY_PREFLIGHT_TOKENS_PER_REPLAY = 37,600,000 weighted units at defaults,
# with the same ~1.33x headroom the predecessor carried.
#
# STATED PLAINLY: at the observed token mix this ceiling is a REAL-TERMS
# LOOSENING of roughly 34x versus the old literal 8,000,000 read as RAW tokens.
# The arithmetic, so it can be checked rather than trusted (temperloop#1710):
#
#   measured replay (below): raw 2,506,371 -> cost-weighted 466,530
#                            => weighted/raw ratio 0.1861
#   old ceiling in the NEW unit:  8,000,000 raw x 0.1861  = ~1,489,000 weighted
#   this ceiling:                                           50,000,000 weighted
#   loosening:                    50,000,000 / 1,489,000   = ~33.6x
#
# This block previously said "roughly 5.4x" here. That figure is 8,000,000 /
# 1,489,000 — the loosening of merely REINTERPRETING the old numeral in the new
# unit, NOT the loosening of the value actually set on the line below. It sat
# six lines above the 1.5M figure it contradicts, in the paragraph that exists
# precisely to state the loosening plainly, and at the exact moment the number
# is load-bearing for an operator's decision. Understating a spend-ceiling
# relaxation ~6x is the wrong direction to be wrong in.
#
# The loosening is deliberate and is not a quota being quietly widened — the old
# value was never an independent budget or an external quota; it was itself
# derived from batch cap x per-replay under a per-replay constant now known to
# be 3.1x low, so carrying its literal into the new unit would have been
# carrying an arithmetic accident. Holding the old real-terms strictness would
# put the ceiling near 1.5M weighted units, below even the cost of the SMALLEST
# statistically meaningful comparison (MODEL_COMPARISON_MIN_SAMPLE_N paired
# outcomes = 2x that many executed replays ~ 18,800,000 weighted units), i.e.
# a gate that stops every batch it could ever be asked about. An operator who
# wants a tighter budget should lower this deliberately, with those two
# numbers in view.
: "${REPLAY_PREFLIGHT_CEILING_TOKENS:=50000000}"
# Assumed per-replay cost-delta standard deviation, in COST-WEIGHTED TOKEN
# UNITS (same unit as REPLAY_PREFLIGHT_TOKENS_PER_REPLAY — a stddev in a
# different unit from the mean it varies around is the exact collision
# temperloop#1380 closed), fed to stats.sh's `mde` primitive for the
# pre-spend detectable-effect disclosure. A single observed replay cannot
# express variance at all, so this stays a rough same-order-of-magnitude
# placeholder — one third of REPLAY_PREFLIGHT_TOKENS_PER_REPLAY, the
# relationship its predecessor carried — that an operator should tighten
# once more than one replay has been executed.
: "${REPLAY_PREFLIGHT_ASSUMED_STDDEV_TOKENS:=155000}"

# ── Replay EXECUTION + SCORING (temperloop#1258) ──────────────────────────
# Wall-clock bound on ONE candidate run in replay.sh's `execute`. A run that
# exceeds it is killed and recorded as an `integration-error` (stage
# candidate-timeout) — a compatibility fact about the vendor integration,
# never a quality failure of the model. 1800s = 30 minutes: generous enough
# for a real /build-sized item, short enough that one hung vendor connection
# cannot stall a whole batch.
: "${REPLAY_CANDIDATE_TIMEOUT_SECS:=1800}"
# The gate entry point score.sh runs, resolved INSIDE the candidate's own
# base worktree (never today's tree) — the keystone spike's trap-C "never mix
# trees" disposition. Worktree-relative by contract; an adopter repo whose
# gate entry point is named differently repoints it here.
: "${REPLAY_SCORE_GATE_RELPATH:=scripts/quality-gates.sh}"
# Wall-clock bound on that gate run. A timeout is reported as
# `timed_out: true` alongside the normalized 137 exit code, never as a pass.
: "${REPLAY_SCORE_GATE_TIMEOUT_SECS:=1800}"
# Byte cap on the candidate diff text score.sh captures into
# `score.diff.text_excerpt` while the leg's worktree is still live
# (temperloop#1579 — batch.sh tears the worktree down right after replay, so
# this is the only point the real patch text can ever be read). An oversized
# diff is cut at this many bytes with an explicit truncation marker appended
# to the field itself, never silently grown without bound into the record.
: "${REPLAY_SCORE_DIFF_EXCERPT_MAX_BYTES:=200000}"

# ── Judge pass (temperloop#1259, epic #1225 "model comparison harness") ────
# workflows/scripts/model-comparison/judge.sh: the strong-tier JUDGE model
# that scores an already-executed replay record. Two operator-facing
# tunables, named symbolically in judge.sh's own header, never re-valued in
# prose (§ Named-setting convention) — following the same naming convention
# RETRO_JUDGE_MODEL established for the OTHER judge in this pipeline
# (unified-retrospection's epic-close judge; a different model, a different
# job).
#
# The judge model. Deliberately a STRONG tier (this item's own framing:
# "score every replay record with a strong-tier judge") — same default as
# PIPELINE_DRIVE_MERGE_MODEL's high-judgment tier, a different call site.
: "${MODEL_COMPARISON_JUDGE_MODEL:=claude-opus-4-8}"
# Wall-clock bound on ONE judge model call, mirroring REPLAY_CANDIDATE_TIMEOUT_SECS's
# per-candidate-run bound.
: "${MODEL_COMPARISON_JUDGE_TIMEOUT_SECS:=1800}"
# Optional cross-family judge rotation (temperloop#1260): judge.sh's
# `judge-rotate` subcommand scores one record with judges from more than one
# provider family and reports the variance of their quality_score across the
# panel. OFF by default — with it 0, judge-rotate refuses immediately and
# `judge`/`judge-batch`'s own behaviour is byte-identical to the
# pre-rotation module.
# How many times ONE record's judge call may be attempted before the row is
# recorded UNAVAILABLE (temperloop#1605). 1 disables retrying entirely.
#
# Scoped narrowly on purpose: a retry is only taken when the judge DID reply and
# the reply was unusable — truncated, unparseable, schema-invalid, or empty. A
# structural failure (no envelope, no usable modelUsage block) is not retried,
# because re-running cannot fix it and the attempt costs real spend.
#
# The motivating case (#1262, candidate arm, PR 1437): the judge returned a
# reply that BEGINS as the contracted JSON object and is cut mid-string. One
# lost judgment out of 56 flipped the whole batch to BATCH_DEGRADED. The judge
# pass is already resumable by arm-file sha, so a single-row retry was always
# the cheap recovery — there was simply no path to ask for it.
#
# 2 (one retry) rather than more: a truncation is usually transient, and a
# reply that fails twice is more likely a prompt/rubric problem that another
# attempt will not fix. Raise it if a run shows repeated single-attempt losses.
: "${MODEL_COMPARISON_JUDGE_MAX_ATTEMPTS:=2}"
: "${MODEL_COMPARISON_JUDGE_ROTATION_ENABLED:=0}"
# The minimum number of rotation members that must reach JUDGED before a
# per-judge variance figure is reported at all — passed to stats.sh as
# judge-rotate's OWN `--min-sample`, never the module-wide
# MODEL_COMPARISON_MIN_SAMPLE_N (sized for cost-delta outcome counts in the
# tens, not a judge panel).
: "${MODEL_COMPARISON_JUDGE_ROTATION_MIN_JUDGES:=2}"

# ── Comparison report producer (temperloop#1261, epic #1225) ───────────────
# workflows/scripts/report-producers/model-comparison reads a comparison's two
# arms — baseline.jsonl and candidate.jsonl — from this directory. Relative by
# default and resolved against the TARGET REPO (the cwd report.sh invokes a
# producer with), so the records sit beside the module's other repo-local
# runtime state, which .temperloop/.gitignore already excludes from the tree.
: "${MODEL_COMPARISON_REPORT_RECORDS_DIR:=.temperloop/model-comparison}"

# ── Batch driver circuit breaker (temperloop#1554, epic #1225) ─────────────
# workflows/scripts/model-comparison/batch.sh stops executing further legs
# once this many CONSECUTIVE integration errors carrying the SAME
# `integration_error.stage` land. The counter resets on any leg that scores
# and re-keys (back to 1) on a different stage, so a scatter of unrelated
# per-record incompatibilities never trips it while a systemically
# unavailable spawn path does.
#
# Why 5: the first live batch replayed 14 records successfully over ~3.1h and
# then fast-failed every remaining leg in ~4-5s — 28 consecutive
# `candidate-spawn` errors, almost certainly a rate/usage limit, hammered to
# the end of the corpus. With two arms per record, 5 legs is ~2.5 whole
# records' worth of the same failure back to back: comfortably above the 1-2
# legs a genuine single-record incompatibility produces, and far below the 28
# that run spent re-proving the endpoint was still unavailable. Set 0 to
# disable the breaker entirely (the pre-#1554 run-the-corpus-out behaviour).
: "${MODEL_COMPARISON_BATCH_MAX_CONSECUTIVE_STAGE_ERRORS:=5}"

# ── Batch driver concurrency (temperloop#1682, epic #1225) ────────────────
# How many corpus RECORDS workflows/scripts/model-comparison/batch.sh replays
# at a time. A record's own two legs always run sequentially in their
# counterbalanced order whatever this is set to — concurrency is across
# records only, because temperloop#1571's execution_order.position is
# meaningless if a record's two legs overlap, and losing it re-opens the
# arm-vs-position confound temperloop#1606 was filed against.
#
# Why 1: the measured cost of NOT having this is real — the temperloop#1656
# validation run took 29 min/leg, projecting ~27h for a 28-record batch, a
# third of it the in-worktree quality-gates.sh run rather than model time. But
# the default stays sequential so an existing invocation behaves exactly as it
# did, and widening is a deliberate act: `--concurrency N` on the command line,
# or this setting raised on a host that has earned it.
#
# WHAT RAISING THIS TRADES. Not CPU — the real ceiling is the PROVIDER'S RATE
# LIMIT. temperloop#1554's 28-leg outage happened on a strictly sequential run,
# and N concurrent records multiply request rate against one account's quota,
# so a higher N makes tripping the circuit breaker MORE likely, not less. There
# is a second, smaller cost in local CPU: each leg forks its own
# quality-gates.sh, which itself pools up to 4 wide, so N records is already
# roughly 4N concurrent processes. Raise it a rung at a time and watch the
# breaker.
: "${MODEL_COMPARISON_BATCH_CONCURRENCY:=1}"

# The hard ceiling MODEL_COMPARISON_BATCH_CONCURRENCY and `--concurrency N`
# are both clamped to, with a printed notice naming the clamp. It is a setting
# rather than a literal in batch-pool.sh because the right ceiling is a
# property of the host and the account — a shared laptop and a dedicated
# runner on a higher rate limit do not want the same number.
#
# Why 4: the same width scripts/quality-gates.sh's own auto-detect caps at,
# for a related reason — past that point oversubscription costs both wall
# clock and reliability. Here the binding constraint is the rate limit rather
# than cores, and 4 concurrent records is already ~8 concurrent replay legs'
# worth of request rate against one quota. An operator on a host that has
# demonstrably more headroom raises this deliberately; nothing auto-detects it,
# because nothing local can read a provider's quota.
: "${MODEL_COMPARISON_BATCH_MAX_CONCURRENCY:=4}"

# ── Post-run spend reconciliation (temperloop#1555, epic #1225) ────────────
# workflows/scripts/model-comparison/batch.sh compares the spend the operator
# AUTHORIZED at the gate against the spend the run actually INCURRED (summed
# over both arms' records from their own token blocks, in the same
# cost-weighted unit) and raises `spend_reconciliation.drift_alert` once the
# observed total deviates from the projected total by more than this
# PERCENTAGE in either direction.
#
# It is an ALERT FLAG, never a degradation: a projection being wrong is a fact
# about the ESTIMATE, not a defect in the batch that just completed, so it
# must not turn a BATCH_COMPLETE into a BATCH_DEGRADED. What it buys is that
# the drift is caught by the pipeline — on the summary and on stderr — instead
# of by someone summing the raw lake by hand, which is how the n=1 literal
# stayed 1.49x low across a whole live run.
#
# Why 25: the observed per-replay spread is 4.8x, so a batch-level total can
# legitimately land some way off a mean-based projection through record mix
# alone; 25% is wide enough that ordinary mix variance on a floor-sized batch
# does not cry wolf, and tight enough to catch the ~49% miss the n=1 literal
# actually produced. Set 0 to disable the alert.
: "${MODEL_COMPARISON_SPEND_DRIFT_ALERT_PCT:=25}"

# ── Dual-build harness (epic Towheads/temperloop#2065, item #2071) ─────────
# `/build --dual-build <tier>=<candidate>` builds every in-scope item under
# TWO models per level and judges/picks per item, per Design/2065 and
# `[[Decisions/temperloop - Declared tier settings over a shared tier
# resolver]]`: a plan-less/per-invocation seat gets a DECLARED config
# setting, never a new shared tier-resolution component. This is the ONLY
# item in the epic's L0 that touches this file, by design — see
# `[[Patterns/temperloop - a new setting defined on two parallel branches
# conflicts dangerously]]` — every later item stacks on this one's commit
# rather than adding its own competing definition of the same name.
#
# Baseline and candidate models. LITERAL defaults, never a `$HOME`-inherited
# / inherit-session sentinel — this is the one deliberate divergence from
# SWEEP_WORKER_MODEL / FIX_WORKER_MODEL's empty-default convention (D2 in
# `[[Decisions/temperloop - Declared tier settings over a shared tier
# resolver]]`), because ADR 0028's repo-scoped-bleed rule (docs/adr/0028)
# governs this differently: a dual-build run holds BOTH arms' models fixed
# and disclosed for the whole level (the `Model-comparison-arms:` PR
# trailer, dimension 4 #9), so "whatever this session happens to be running
# today" is exactly the operator-scoped bleed the ADR calls out — an
# inherited value could silently differ arm-to-arm across a resumed run, or
# across repos for a consultant's engagement (dimension 13). Baseline
# mirrors PIPELINE_DRIVE_MERGE_MODEL's existing high-judgment code/merge
# driving default — "what /build already ships today" is the correct
# baseline arm; candidate is the tier this harness exists to evaluate
# against it. Per-invocation `--dual-build <tier>=<candidate>` always wins
# over these (layer 1 beats layer 5); these are the un-overridden defaults
# only.
: "${DUAL_BUILD_BASELINE_MODEL:=claude-opus-4-8}"
: "${DUAL_BUILD_CANDIDATE_MODEL:=claude-sonnet-5}"

# Pre-flight (dimension 4 #6) declines to dual-build a level with fewer
# in-scope items than this floor — 2× worker spend + judge spend per item is
# a real cost that directly competes with shipping work (the design's own
# "break-even, not a quota-share aside" framing), and a level-scoped tally
# (D4: "the arm with more item wins") has no aggregation value at n=1 — a
# single-item level reduces to a bare per-item judge call the harness's own
# per-item machinery already provides, without earning the level barrier's
# extra worker/spend/attention cost. 2 is the smallest count at which "more
# item wins" is a meaningful tally rather than a single coin flip dressed up
# as one.
: "${DUAL_BUILD_MIN_INSCOPE_ITEMS:=2}"

# How many days a `dual-build` ledger row + its `git format-patch` archive
# may live under `.temperloop/model-comparison/dual-build/` before
# `dual-build purge` (dimension 4 #12) may reclaim it — mirrors
# CHECKIN_PRUNE_DAYS's existing 30-day convention for gitignored, local,
# prunable-by-age runtime state. The archive is what a future analysis or
# re-judge reads (D7), so this is a floor on how long that re-judge window
# stays open, never an automatic sweep — purge is operator-invoked.
: "${DUAL_BUILD_ARCHIVE_RETENTION_DAYS:=30}"

# Above this unresolved rate (tied/unjudged/infra rows ÷ total dual-built
# items, dimension 4 #8), the cumulative report withholds a verdict the same
# way an uncalibrated judge does — an unresolved rate this high means the
# win-rate numerator/denominator the report would otherwise print no longer
# honestly represents the tier's outcomes. 20%: tight enough that one
# genuine tie or infra blip in a small early sample does not itself trip the
# withhold (a 1-in-6 level stays under it), loose enough to catch a batch
# where the judge or infra is systemically failing to resolve picks,
# mirroring MODEL_COMPARISON_SPEND_DRIFT_ALERT_PCT's existing "wide enough
# not to cry wolf, tight enough to catch the real miss" sizing rationale.
: "${DUAL_BUILD_UNRESOLVED_THRESHOLD_PCT:=20}"

# How many archived ledger pairs the blind `calibrate` mode (dimension 4 #7)
# samples per level for a human preference. Deliberately light-touch — 1 per
# level keeps calibration a steady background accumulation toward the
# DUAL_BUILD_CALIBRATION_BAR_N floor below rather than a per-level chore that
# competes with the level-pick confirmation (dimension 4 #4) for operator
# attention; an operator who wants to calibrate faster reruns `calibrate`
# directly against more of the archive at any time.
: "${DUAL_BUILD_CALIBRATE_PAIRS_PER_LEVEL:=1}"

# The judge–human pairwise agreement bar (D13, dimension 4 #8): a winner is
# named only once agreement over blind `calibrate`-mode pairs (dimension 4
# #7 — override-derived pairs are excluded from this statistic by
# construction) reaches BOTH of these floors; below either, the report reads
# "judge uncalibrated — verdict withheld". Values are the design brief's own
# ratified numbers (D13), not invented here — 70% agreement over at least 20
# human-labelled pairs.
: "${DUAL_BUILD_CALIBRATION_BAR_PCT:=70}"
: "${DUAL_BUILD_CALIBRATION_BAR_N:=20}"

export BUILD_QUOTA_PAUSE_PCT BUILD_QUOTA_CACHE BUILD_QUOTA_WAIT_BUFFER \
       BUILD_QUOTA_MAX_AGE BUILD_MERGE_GATE_WINDOW BUILD_QUEUE_TIMEOUT BUILD_QUEUE_STALL_AFTER \
       BUILD_HEADLESS_POLL_TIMEOUT \
       BUILD_MERGE_BACKEND BUILD_COMBINED_TREE_PRECHECK BUILD_MERGE_AS_YOU_GO \
       PIPELINE_DRIVE_CONCURRENCY EPIC_MIN_SUBUNITS DISPLAY_TZ \
       STATE_GRAPH_MAX_AGE_S STATE_GRAPH_QUERY_SLOW_MS STATE_GRAPH_SOAK_DAYS STATE_GRAPH_SOAK_STALE_DAYS \
       ASSESS_POLL_FIRST_WAKE ASSESS_POLL_CADENCE ASSESS_POLL_BUDGET \
       ASSESS_REVIEW_AGENT_CEILING_SECS ASSESS_REVIEW_AGENT_SLOW_SECS \
       TRIAGE_INTAKE_EXCLUDE_LABELS \
       NEXT_SEQ_STALE_AFTER TIDY_SYNC_WAIT TIDY_LOCK_STALE_AFTER CHECKIN_PRUNE_DAYS \
       SWEEP_FANOUT_WIDTH SWEEP_DETECT_MODEL SWEEP_WORKER_MODEL SWEEP_BG_POLL_ATTEMPTS SWEEP_BG_POLL_INTERVAL \
       SWEEP_ADMIT_OPERATIONAL_EPICS \
       FIX_WORKER_MODEL INTERVIEW_PROBE_MODEL BUILD_MACHINERY_SOLO_MODEL BUILD_MACHINERY_BATCH_MODEL BUILD_GATE_SLICE_SECS \
       BUILD_REVIEW_BLOCKING_MAX_ROUNDS BUILD_PR_BODY_MAX_BYTES \
       BUILD_MACHINERY_STEP_CEILING_SECS BUILD_MACHINERY_STEP_SLOW_SECS \
       BUILD_REVIEW_AGENT_CEILING_SECS BUILD_REVIEW_AGENT_SLOW_SECS \
       WORKFLOW_SCRIPT_BYTE_CEILING WORKFLOW_SCRIPT_BUDGET_PCT \
       PIPELINE_OPERATOR PIPELINE_REQUIRED_CHECK \
       PIPELINE_DRIVE PIPELINE_DRIVE_CAP PIPELINE_DRIVE_MODEL PIPELINE_DRIVE_SETTINGS \
       PIPELINE_DRIVE_MERGE PIPELINE_DRIVE_MERGE_CAP PIPELINE_DRIVE_MERGE_MODEL PIPELINE_DRIVE_MERGE_SETTINGS \
       PIPELINE_MERGE_PENDING_LABEL PIPELINE_CLARIFIED_MARKER PIPELINE_ESCALATED_LABEL \
       RETRO_MINT_ENABLED RETRO_MIN_INTERVAL RETRO_URGENT_CI_RETRIES \
       RETRO_BATCH_SESSION_CAP RETRO_JUDGE_MODEL \
       CONFIGURE_AI_MODEL \
       REVIEWER_SCAN_MIN_FILES \
       PROSE_BUDGET_TIER1_CAP PROSE_BUDGET_TIER2_FILE_CAP \
       SPEND_WEIGHT_INPUT SPEND_WEIGHT_CACHE_READ SPEND_WEIGHT_CACHE_CREATE SPEND_WEIGHT_OUTPUT \
       SPEND_MACHINERY_MAX_CALLS SPEND_WORKER_PROFILE_MIN_CALLS SPEND_TRANSCRIPT_ROOT \
       KNOWLEDGE_STORE_ROOT KNOWLEDGE_STORE_AGENT_PLANE \
       MODEL_COMPARISON_MIN_SAMPLE_N MODEL_COMPARISON_BOOTSTRAP_ITERATIONS MODEL_COMPARISON_BOOTSTRAP_SEED \
       MODEL_COMPARISON_CI_WIDTH_PCT MODEL_COMPARISON_EMIT_FEASIBLE_SEATS \
       MODEL_COMPARISON_QUALITY_BASIS_DISAGREEMENT_PCT MODEL_COMPARISON_QUALITY_TARGET_EFFECT_PCT \
       REPLAY_CORPUS_LIMIT REPLAY_CORPUS_SAMPLE_MULTIPLIER REPLAY_NAMED_PATH_EXTENSIONS \
       REPLAY_PUSH_DISABLE_SENTINEL \
       REPLAY_PREFLIGHT_BATCH_CAP REPLAY_PREFLIGHT_TOKENS_PER_REPLAY \
       REPLAY_PREFLIGHT_DERIVE_MIN_N REPLAY_PREFLIGHT_STUB_MODEL_PATTERNS \
       REPLAY_PREFLIGHT_CEILING_TOKENS REPLAY_PREFLIGHT_ASSUMED_STDDEV_TOKENS \
       REPLAY_CANDIDATE_TIMEOUT_SECS REPLAY_SCORE_GATE_RELPATH REPLAY_SCORE_GATE_TIMEOUT_SECS \
       REPLAY_SCORE_DIFF_EXCERPT_MAX_BYTES \
       MODEL_COMPARISON_BATCH_CONCURRENCY MODEL_COMPARISON_BATCH_MAX_CONCURRENCY \
       MODEL_COMPARISON_JUDGE_MODEL MODEL_COMPARISON_JUDGE_TIMEOUT_SECS \
       MODEL_COMPARISON_JUDGE_MAX_ATTEMPTS MODEL_COMPARISON_JUDGE_ROTATION_ENABLED MODEL_COMPARISON_JUDGE_ROTATION_MIN_JUDGES \
       MODEL_COMPARISON_REPORT_RECORDS_DIR \
       MODEL_COMPARISON_BATCH_MAX_CONSECUTIVE_STAGE_ERRORS \
       MODEL_COMPARISON_SPEND_DRIFT_ALERT_PCT \
       DUAL_BUILD_BASELINE_MODEL DUAL_BUILD_CANDIDATE_MODEL DUAL_BUILD_MIN_INSCOPE_ITEMS \
       DUAL_BUILD_ARCHIVE_RETENTION_DAYS DUAL_BUILD_UNRESOLVED_THRESHOLD_PCT \
       DUAL_BUILD_CALIBRATE_PAIRS_PER_LEVEL \
       DUAL_BUILD_CALIBRATION_BAR_PCT DUAL_BUILD_CALIBRATION_BAR_N
