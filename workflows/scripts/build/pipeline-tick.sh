#!/usr/bin/env bash
#
# pipeline-tick.sh — the autonomous pipeline driver's per-board tick (foundation
# #569). A THIN SCHEDULER: it CALLS the existing `/triage → /assess → /build`
# pipeline and inherits every hardened behavior (drive-concurrency governor, quota gate,
# claim-first, timed merge gate, epic lifecycle) — it NEVER re-embeds any of it.
# Re-implementing a pipeline step is a contract violation (see
# `Decisions/foundation - Autonomous pipeline driver + GitHub decision queue`
# § Scheduler-not-pipeline + the CORRECTION).
#
# Each tick, per ENABLED board, runs these phases:
#   0. intake          — invoke /signal-intake (crash-convergence, foundation
#                        #671/#637) BEFORE any spend decision below, so it runs
#                        on every tick, spend-open or spend-closed. Best-effort:
#                        a failure is caught, logged, and never blocks the tick.
#   A. drain-answered  — find decision issues the operator answered+unassigned,
#                        classify each typed reply, and EMIT the drain action
#                        (build.md Step 0a / tidy.md § Answered decisions
#                        own the apply; this script routes, it does not apply).
#   A2. drain-clarification — the clarification counterpart (foundation #657): find
#                        `needs-clarification` issues the operator answered+unassigned
#                        (same baton) and EMIT a drain that clears the label so the
#                        item becomes drivable again. No reply parse — the free-text
#                        answer already on the issue rides into the next drive.
#   B. drive-ready     — for one Operational Ready item, EMIT the
#                        `/assess`→`/build --unattended` invocation the Claude
#                        layer executes. The script never assesses/builds.
#   C. route-foundational — for one Foundational Ready item, EMIT the
#                        decision-queue routing (build.md's decision-issue
#                        backend posts the gate; this script names it).
#   R. retro-judge      — the KERNEL trigger half of the mint-then-judge design
#                        (epic #528, temperloop#535): build.md 4d-retro (#533,
#                        already merged) MINTS a `retro-pending`/`retro-info`
#                        tracker at epic close (applying `retro-urgent` when past
#                        the mint's own urgency bar). This phase hands DUE
#                        `retro-pending` trackers to the overlay `/retro --pending`
#                        judge. THIN: the only threshold applied here is the
#                        RETRO_MIN_INTERVAL debounce on the oldest tracker's age —
#                        bypassed unconditionally by a `retro-urgent` tracker
#                        (urgency was already decided at mint). The judge-side
#                        session cap (RETRO_BATCH_SESSION_CAP) is `/retro`'s own
#                        concern, never enforced here. TWO gates precede the
#                        emit, and either one failing EMITs a legible,
#                        reason-bearing skip instead — never a retro-judge
#                        action, and never silence: (1) PRESENCE —
#                        `command_declared retro` (the overlay command is
#                        installed at all); (2) HEADLESS CAPABILITY —
#                        `command_declared_capability retro headless-unattended`
#                        (the installed judge DECLARES it can complete an
#                        unattended `--pending` run). Gate 2 exists because
#                        presence alone spawned an unrunnable judge that exited
#                        `subtype: success` having judged nothing
#                        (temperloop#1150).
#
# WHY "EMIT", not "do": `/triage`, `/assess`, `/build` are prose specs executed
# by Claude, not callable binaries. The deterministic half — single-flight,
# board ON/OFF, the decision-drain query, the Operational/Foundational
# classification, the routing decision — is pure machine state and lives HERE.
# The judgment/agent half (actually running a prose command) is named in the
# emitted plan and run by the Claude driver layer. This split is what keeps the
# scheduler thin: this script decides WHAT to call; it never reimplements it.
#
#   pipeline-tick.sh                              # live tick over enabled boards
#   pipeline-tick.sh --board 3                    # live tick, one board
#   pipeline-tick.sh --dry-run --fixture <dir>    # offline tick against a stub
#   pipeline-tick.sh --list-enabled               # print the ON boards, exit
#
# --dry-run --fixture <dir> is the ACCEPTANCE path (off the live board): every
# `gh`/board read is served from files under <dir> instead of the network, and
# every mutation (label drop, assign, merge) is RECORDED to the emitted plan
# rather than executed. The fixture layout is documented in
# tests/test_pipeline_tick.sh (the test seeds it).
#
# A `needs-clarification` item is an OPERATOR-INPUT gate, and ASSIGNMENT is the
# baton (foundation#684/#657) — the two states are keyed on `no:assignee`:
#   • STILL ASSIGNED (awaiting the answer) → PARKED in the Ready loop as
#     `route-already-assigned`. The producer that raised the question (`/triage` or
#     `/sweep` park-on-question) already assigned the operator + posted the question
#     AT SOURCE (#684), so the item is already in the operator's assigned-to-me queue
#     and the pipeline has nothing to assign — the label alone means "not autonomously
#     actionable → park". (A level-5c CODE escalation is a SEPARATE gate since #697: it
#     carries its own `funnel-escalated` label, parked by the pipeline_escalated gate,
#     and is never drained. It is NOT a `needs-clarification` producer.) (This
#     supersedes #600's `route-needs-input`, which existed only to do the assign the
#     producers
#     now own.)
#   • UNASSIGNED (operator answered in a comment + unassigned = baton returned) →
#     DRAINED in Phase A2 as `drain-clarification`: the label is cleared so the item
#     becomes drivable again on the next tick (#657, the answer-consumption gap —
#     previously NOTHING autonomous cleared the label, so an answered item parked
#     forever). Phase A2 runs first and records drained numbers so the Ready-loop
#     park gate does not also park them. `spike` is NOT matched here. NOTE:
# foundation#594 originally also lumped `spike` into this
# skip-gate — that was wrong (#600). A `spike` is automatable read-only
# investigation whose verdict feeds a decision AFTER it runs (build.md's kind:spike
# path writes the note + routes a follow-up); it is a DRIVE target, not an
# operator-input gate, so it now falls through to `drive-ready` like any Operational
# item — and is in fact the SAFEST auto-drive (no PR, no merge).
#
# Output contract — a JSON "tick plan" (one object) on stdout: the ordered list
# of actions the tick decided, each a {phase, board, action, …} record. In a
# live run the Claude driver executes the EMITted command actions; in a
# --dry-run the plan IS the verifiable artifact (no side effects). The closed
# action set: drain-answer · drain-parse-miss · drain-already-applied
# · drain-clarification · drain-clarification-already-applied
# · drive-ready · route-foundational · route-already-assigned
# · skip-contention · retro-judge · skip-retro-judge · no-op.
#
# Single-flight: a flock lockfile (the contract's § 4 convention) so two
# overlapping ticks never double-act. The lock is released by fd-close on exit
# (clean or crash), never by rm — a crashed run's lock is reaped by the OS.
set -euo pipefail

# Attribution for the gh call-logger shim (F#988): tag every gh call this command
# makes with its outermost context. `:-` preserves an already-set (outer) value,
# so an autonomous driver's context wins over a nested command. See
# workflows/scripts/gh-call-logger.sh.
export GH_CALL_CONTEXT="${GH_CALL_CONTEXT:-pipeline-tick}"

command -v jq >/dev/null 2>&1 || { echo '{"error":"jq not found"}' >&2; exit 1; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Config (env overrides win; defaults centralized in build.config.sh) ──────
# Both optional sources below use `if …; then …; fi`, not `[ -f … ] && . …`,
# because this script is `set -euo pipefail` and these guards are meant to be
# FAIL-OPEN. The `&&` form leaves the whole statement at exit status 1 when the
# file is absent — harmless mid-file, but fatal the moment that status lands
# last in a function or at end of file, and it makes the guard's own value a
# lie to every reader. The `if` form is status-neutral in every position and is
# already the house idiom here: worklist.sh:50-53, gh-bench.sh:141, and
# read_ready_items() further down this file (temperloop#1132).
# shellcheck source=workflows/scripts/build/build.config.sh
if [ -f "$HERE/build.config.sh" ]; then . "$HERE/build.config.sh"; fi

# Shared "is slash command <name> available" probe (ADR 0008), resolve-once —
# the Phase R retro-judge trigger uses this to decide whether an overlay
# `/retro` judge is even installed before emitting a retro-judge action, and
# its companion `command_declared_capability` (temperloop#1150) to decide
# whether that judge DECLARES it can run unattended. If
# this checkout has no lib (a stray copy, or a source layout mismatch), the
# `command_declared` function is simply never defined; every call site below
# treats "function absent" the same as "declared=false" (fail toward the skip
# line, never toward assuming an uninstalled judge exists) — and the same
# fail-closed treatment applies to `command_declared_capability`.
# shellcheck source=workflows/scripts/lib/command_declared.sh
if [ -f "$HERE/../lib/command_declared.sh" ]; then . "$HERE/../lib/command_declared.sh"; fi

# Model the Phase R retro-judge trigger spawns `claude -p "/retro --pending"`
# under (temperloop#532/#535). SOURCE OF TRUTH is build.config.sh (sourced
# above); this `:=` is only the non-vendoring-checkout fallback, exactly as
# PIPELINE_OPERATOR's fallback line above it.
: "${RETRO_JUDGE_MODEL:=claude-sonnet-5}"
: "${RETRO_MIN_INTERVAL:=259200}"

# The set of boards the driver is ENABLED on. PILOT = stageFind (board 3) ONLY
# (the ON/OFF flip; foundation#569). To enable another board, add its logical
# number here (space-separated) — that is the entire "board ON/OFF" mechanism:
# enabled ⇒ the tick processes it, absent ⇒ the tick skips it. Operator-flippable
# via the env override without editing the file.
: "${PIPELINE_ENABLED_BOARDS:=3}"

# Cron cadence is a CONFIG variable, not hardcoded (open operator question —
# the operator finalizes it at the cron-install gate). This script does NOT
# schedule itself; it runs ONE tick and exits. The cadence is consumed by the
# (operator-installed) cron entry, surfaced here only so the default is visible.
: "${PIPELINE_TICK_CADENCE:=daily}"

# The operator handle the async decision-issue backend assigns to (the baton).
# This MUST be the operator's real GitHub collaborator LOGIN (verify with
# `gh api user -q .login` — a display/email-derived handle can differ from the
# real login, and a re-assign to the wrong one targets nobody / fails, so the
# baton never reaches the operator; foundation #588). Override per-host via the
# env var if the operator identity ever changes. SOURCE OF TRUTH is
# build.config.sh (sourced above); this `:=` is the non-vendoring-checkout
# fallback (tracker seam v0, #772) — build.config.sh's own placeholder wins
# here too since it's sourced first.
: "${PIPELINE_OPERATOR:=@REPLACE_WITH_YOUR_GH_LOGIN}"

# Drive-concurrency governor for the autonomous lane (temperloop#162): the bound
# on concurrent drives the pipeline lane keeps per tick. This is surfaced, not
# enforced here — real per-item concurrency is INHERITED from /build's claim-first
# gate, not re-embedded. SOURCE OF TRUTH is build.config.sh (sourced above); this
# `:=` is only the non-vendoring-checkout fallback. (Formerly PIPELINE_WIP_CAP, which
# also doubled as the now-retired human "WIP cap = 3" governance prose — that human
# cap was retired in temperloop#162; this setting is the mechanical governor only.)
: "${PIPELINE_DRIVE_CONCURRENCY:=3}"

# Per-tick DRIVE CAP (#642): how many Operational drive-ready items this tick may
# EMIT. Was a hardcoded one-per-tick; now the canonical operator setting, fed from the
# vault `cap:` (the ```pipeline-schedule block) by pipeline-cron.sh and defaulted in
# build.config.sh. A bare `pipeline-tick.sh` run uses the =1 fallback. This bounds the
# EMIT; real concurrency is still governed by the claim-first gate downstream.
: "${PIPELINE_DRIVE_CAP:=1}"

# Single-flight lockfile (contract § 4). One tick per host at a time.
: "${PIPELINE_LOCK_DIR:=/tmp/funnel-tick}"
: "${PIPELINE_LOCK_FILE:=$PIPELINE_LOCK_DIR/tick.lock}"

# The flock binary name (temperloop#492). Stock macOS ships no `flock`, so the
# single-flight lock degrades to the per-issue contention pre-check with a WARN.
# Script-local like PIPELINE_LOCK_DIR (a binary name, not an operator setting); the
# override exists so a test can force the degraded path deterministically on a
# host that DOES carry flock, and so a host with a differently-named binary can
# point at it.
: "${PIPELINE_FLOCK_CMD:=flock}"

# Run identity for the once-per-run flock-degradation notice (temperloop#492).
# pipeline-cron loops boards → many pipeline-tick PROCESSES per wake, each emitting
# the flock-missing WARN independently; on stock macOS that accumulates one line
# per board per tick, unattended, forever. The dedup keys off this shared run id
# (pipeline-cron.sh exports it for the whole wake), persisted in a marker so the
# notice fires AT MOST ONCE per run. A bare/standalone pipeline-tick.sh run has no
# exported id and falls back to its own PID — one process, one acquisition, one
# notice, exactly as before.

# Idempotency marker (foundation #587). The drain applier (tidy.md
# § Answered decisions step f) posts a confirmation comment when it applies an
# answered decision and drops the `decision` label. Search-index lag can re-list
# a just-drained issue on the NEXT tick (the label drop hasn't propagated); its
# latest comment is then this delivery artifact, NOT a decision reply. Keying off
# this sentinel lets the tick recognise an already-applied issue and skip it
# (drain-already-applied) instead of mis-parsing it as a parse-miss and spuriously
# re-assigning the operator. The `Decision applied:` prose prefix is the fallback
# for legacy confirmation comments posted before the sentinel existed.
: "${PIPELINE_DELIVERED_MARKER:=<!-- funnel:decision-applied -->}"

# Clarification-drain sentinel (foundation #657) — the SOURCE OF TRUTH is
# build.config.sh (sourced above), so the writer/reader pair never drift; this
# `:=` line is the non-vendoring-checkout fallback only, exactly as
# PIPELINE_MERGE_PENDING_LABEL does. PIPELINE_CLARIFIED_MARKER is the ack the executor
# posts on a drained item — the search index can re-list it before the label drop
# propagates, so clarification_already_applied keys off this to skip a re-drain.
: "${PIPELINE_CLARIFIED_MARKER:=<!-- funnel:clarification-drained -->}"

# Level 5c code-escalation label (foundation #697, supersedes the #657 merge-escalation
# marker). pipeline-drive.sh applies THIS label — not `needs-clarification` — to a CODE
# item it escalates to the operator (route-refused / terminally-red CI). Since those
# items no longer carry `needs-clarification`, Phase A2's answer-drain search can never
# list them (no marker scan / skip verb needed); the pipeline_escalated park gate keeps
# them out of the drive pool (duplicate-PR guard). SOURCE OF TRUTH is build.config.sh.
: "${PIPELINE_ESCALATED_LABEL:=funnel-escalated}"

# Cross-tick merge hand-off marker (foundation #624). pipeline-drive.sh applies this
# label to a Ready item whose headless merge drive left an OPEN, unmerged PR (the
# one-shot `claude -p` session ended before CI greened + the merge gate fired). On
# the next tick this script sees the label and emits a RESUME drive (re-attach to
# the open PR + run /build's merge gate) instead of a FRESH one — which would open a
# duplicate PR. Default centralized in build.config.sh; override via the env.
: "${PIPELINE_MERGE_PENDING_LABEL:=funnel-merge-pending}"

# Crash-signal intake orchestrator (foundation #671, epic #637). The L2
# `/signal-intake` script (crash-convergence/signal-intake.sh) — sourceable +
# execute-guarded, so invoking it here just RUNS it, mirroring how the tick
# calls the board adapter. Injectable so a test can point it at a stub instead
# of the real Sentry/board-hitting script. Default resolved once, below.
: "${PIPELINE_INTAKE_CMD:=$HERE/../crash-convergence/signal-intake.sh}"

# Intake config-absent WARN dedup dir (temperloop#330). The intake pre-gate used
# to invoke PIPELINE_INTAKE_CMD and swallow the outcome: on a host where the backend
# script is MISSING, or its Sentry credential is UNSET/placeholder, intake either
# can't run or cleanly no-ops (rc=0) — so the tick saw "success", printed NOTHING,
# and intake silently did nothing for ~19h unnoticed. run_intake_phase now surfaces
# ONE operator-visible WARN naming the reason, deduped ACROSS ticks (each tick is a
# fresh process) via a per-board marker file here — so it fires once per condition,
# not once per poll. Script-local like PIPELINE_LOCK_DIR (an internal marker path, not
# an operator setting); override only for a test seam. Defaults alongside the lockfile.
: "${PIPELINE_INTAKE_WARN_DIR:=$PIPELINE_LOCK_DIR}"

# ── Arg parse ────────────────────────────────────────────────────────────────
DRY_RUN=0
FIXTURE=""
ONE_BOARD=""
LIST_ENABLED=0

usage() {
  echo "usage: pipeline-tick.sh [--board N] [--dry-run --fixture <dir>] [--list-enabled]" >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)      DRY_RUN=1; shift ;;
    --fixture)      FIXTURE="${2:?--fixture needs a dir}"; shift 2 ;;
    --board)        ONE_BOARD="${2:?--board needs a value}"; shift 2 ;;
    --list-enabled) LIST_ENABLED=1; shift ;;
    -h|--help)      usage ;;
    *) echo "pipeline-tick.sh: unknown arg '$1'" >&2; usage ;;
  esac
done

if [ "$DRY_RUN" -eq 1 ] && [ -z "$FIXTURE" ]; then
  echo "pipeline-tick.sh: --dry-run requires --fixture <dir>" >&2
  exit 2
fi
if [ -n "$FIXTURE" ] && [ ! -d "$FIXTURE" ]; then
  echo "pipeline-tick.sh: fixture dir not found: $FIXTURE" >&2
  exit 2
fi

# ── Enabled-board set helpers (the ON/OFF flip) ──────────────────────────────
board_enabled() {
  local b="$1" e
  for e in $PIPELINE_ENABLED_BOARDS; do [ "$e" = "$b" ] && return 0; done
  return 1
}

if [ "$LIST_ENABLED" -eq 1 ]; then
  jq -cn \
    --argjson boards "$(printf '%s\n' "$PIPELINE_ENABLED_BOARDS" | jq -R 'split(" ")|map(select(length>0))')" \
    --arg cadence "$PIPELINE_TICK_CADENCE" \
    --argjson conc "$PIPELINE_DRIVE_CONCURRENCY" \
    --argjson cap "$PIPELINE_DRIVE_CAP" \
    '{enabled_boards:$boards, cadence:$cadence, drive_concurrency:$conc, drive_cap:$cap}'
  exit 0
fi

# Emit the flock-missing single-flight degradation notice AT MOST ONCE per
# pipeline run (temperloop#492). The condition (no `flock` on stock macOS) is
# stable and holds on EVERY tick, so the raw echo below used to accumulate one
# WARN line per board per tick on an unattended macOS host, drowning the log.
# pipeline-cron loops boards → a fresh pipeline-tick PROCESS per board, so the
# "already warned this run" state must persist on disk (mirrors _intake_warn_once,
# #330). The marker records the RUN ID that last warned; a differing (or absent)
# id re-warns — so each new run gets exactly one notice, never once-ever (a fresh
# cron log still shows it once). Marker writes are best-effort: a /tmp failure
# must never wedge the tick (the notice has already printed). NOTE: noise
# reduction only — the fallback per-issue contention pre-check is unchanged and
# remains the real double-act guard.
_flock_degraded_warn_once() {
  local run="${PIPELINE_RUN_ID:-$$}" marker prev=""
  marker="$PIPELINE_LOCK_DIR/flock-degraded-warned"
  [ -f "$marker" ] && prev="$(cat "$marker" 2>/dev/null || true)"
  [ "$prev" = "$run" ] && return 0
  echo '{"warning":"flock not found — single-flight lock skipped; relying on the per-issue contention pre-check"}' >&2
  mkdir -p "$PIPELINE_LOCK_DIR" 2>/dev/null || true
  printf '%s\n' "$run" > "$marker" 2>/dev/null || true
}

# ── Single-flight lock (contract § 4 — skip in dry-run; the fixture path has no
# shared mutable state to protect, and tests must run concurrently). The live
# path acquires it; a second overlapping tick gets flock -n failure and exits 0
# (a no-op tick, not an error). ────────────────────────────────────────────────
if [ "$DRY_RUN" -eq 0 ]; then
  if command -v "$PIPELINE_FLOCK_CMD" >/dev/null 2>&1; then
    mkdir -p "$PIPELINE_LOCK_DIR"
    exec 200>"$PIPELINE_LOCK_FILE"
    if ! "$PIPELINE_FLOCK_CMD" -n 200; then
      echo '{"tick":"skipped","reason":"pipeline-tick already running (single-flight lock held)"}'
      exit 0
    fi
  else
    # FAIL OPEN if flock is absent (e.g. a macOS dev box; a Linux deploy host has it).
    # The contention pre-check (§ 4, per-issue assignee re-read) is the real
    # double-act guard; the lockfile is the coarse host-level single-flight on
    # top of it. Without flock we proceed and rely on the pre-check — a tick
    # must never refuse to run merely because the coarse lock primitive is
    # missing. The cron host (the always-on Linux/mini) carries flock. The notice
    # is squelched to once per run (temperloop#492) — see _flock_degraded_warn_once.
    _flock_degraded_warn_once
  fi
fi

# ── Backend seam: live vs fixture reads ──────────────────────────────────────
# Every read the tick makes goes through one of these. In --dry-run they read
# fixture files; live they shell out to `gh`/the board adapter. Keeping the seam
# narrow is what makes the dry path a faithful stand-in for the live one.

# repo for a board (live: the adapter registry; here we resolve the same
# boards.conf registry directly — see workflows/scripts/board/lib/board.sh's
# board_repo() — so the dry path stays adapter-free (no gh, no board.sh
# sourcing) while still honoring an operator's boards.conf override. Discovery
# order + conf format are identical to board.sh's: machine-level conf, then
# the repo-local workflows/scripts/board/boards.conf override, then the
# built-in map below (foundation #770; byte-identical to the pre-#770 map).
_tick_conf_repo() {  # $1 = board number; rc 1 on any miss (no conf, or no key)
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
tick_board_repo() {
  local v
  v="$(_tick_conf_repo "$1")" && { printf '%s\n' "$v"; return 0; }
  case "$1" in
    3) echo "Towheads/stageFind" ;;    # denylist:allow — see comment above tick_board_repo()
    4) echo "Towheads/foundation" ;;   # denylist:allow — see comment above tick_board_repo()
    5) echo "Towheads/ssmobile" ;;     # denylist:allow — see comment above tick_board_repo()
    6) echo "Towheads/subsetwiki" ;;   # denylist:allow — see comment above tick_board_repo()
    *) return 1 ;;
  esac
}

# List answered decision issues (unassigned + label:decision + open).
# Live: `gh issue list`. Fixture: $FIXTURE/board-<N>/decisions.json (the same
# JSON shape `gh issue list --json number,title,body,comments,assignees` returns).
#
# Scoping is enforced via a SEARCH qualifier, not the `--assignee ""` flag
# (foundation #587): `--assignee ""` is a NO-OP — it does not restrict to
# unassigned, so the old query over-pulled every decision issue (incl. ones the
# operator still holds) and leaned entirely on the per-issue contention pre-check
# to skip them. `--search '… no:assignee'` actually filters to unassigned, so the
# list is genuinely "answered (operator unassigned)" — which is what also makes
# the contention pre-check's "assignee changed since list" reason accurate.
read_answered_decisions() {
  local board="$1" repo="$2"
  if [ "$DRY_RUN" -eq 1 ]; then
    local f="$FIXTURE/board-$board/decisions.json"
    [ -f "$f" ] && cat "$f" || echo '[]'
  else
    gh issue list -R "$repo" --search 'label:decision state:open no:assignee' \
      --json number,title,body,comments,assignees 2>/dev/null || echo '[]'
  fi
}

# Idempotency guard (foundation #587): is this decision issue ALREADY drained?
# True when its most-recent comment is the applier's delivery artifact — matched
# by the machine sentinel (preferred) or the legacy `Decision applied:` prose
# prefix (fallback). A just-drained issue can be re-listed once before the label
# drop propagates through the search index; recognising it here turns that into a
# clean drain-already-applied skip instead of a spurious parse-miss + re-assign.
decision_already_applied() {
  local body="$1"
  [ -z "$body" ] && return 1
  case "$body" in
    *"$PIPELINE_DELIVERED_MARKER"*) return 0 ;;
  esac
  printf '%s\n' "$body" | grep -iE '^[[:space:]]*Decision applied:' >/dev/null
}

# Phase-A2 reader (foundation #657): the ANSWERED `needs-clarification` items —
# the clarification counterpart to read_answered_decisions. Same baton as the
# decision queue: since #684 a `needs-clarification` item is ASSIGNED to the
# operator at source, so `no:assignee` means the operator has answered (in a
# comment) AND unassigned themselves to hand it back. Scoping the search to
# `no:assignee` is what makes "on this list ⇒ answered" true; a still-assigned
# item is awaiting the answer and is PARKED by the Ready-loop gate instead.
read_answered_clarifications() {
  local board="$1" repo="$2"
  if [ "$DRY_RUN" -eq 1 ]; then
    local f="$FIXTURE/board-$board/clarifications.json"
    [ -f "$f" ] && cat "$f" || echo '[]'
  else
    gh issue list -R "$repo" --search 'label:needs-clarification state:open no:assignee' \
      --json number,title,body,comments,assignees 2>/dev/null || echo '[]'
  fi
}

# Idempotency guard (foundation #657): is this clarification item ALREADY drained?
# True when its most-recent comment carries the executor's clarification sentinel.
# Same lag window as decision_already_applied: a just-drained item can be re-listed
# once before the `needs-clarification` label drop propagates through the search
# index; recognising it here turns that into a clean
# drain-clarification-already-applied skip instead of a redundant re-drain.
clarification_already_applied() {
  local body="$1"
  [ -z "$body" ] && return 1
  case "$body" in
    *"$PIPELINE_CLARIFIED_MARKER"*) return 0 ;;
  esac
  return 1
}

# Re-read one issue's current assignee COUNT (the contention pre-check, § 4).
# Fixture: $FIXTURE/board-<N>/assignees-<issue>.txt holds a single integer.
read_assignee_count() {
  local board="$1" repo="$2" issue="$3"
  if [ "$DRY_RUN" -eq 1 ]; then
    local f="$FIXTURE/board-$board/assignees-$issue.txt"
    [ -f "$f" ] && tr -dc '0-9' < "$f" || echo 0
  else
    gh issue view "$issue" -R "$repo" --json assignees --jq '.assignees | length' 2>/dev/null || echo 0
  fi
}

# Project the Ready items {number,title,labels} out of a board items-JSON blob.
# ROBUST to a malformed trailing token (#584): emits EXACTLY ONE JSON array.
# board_resolve's BOARD_ITEMS_JSON was observed on the LIVE board to carry a
# trailing token (jq: "Unmatched '}'") that makes jq exit non-zero AFTER it has
# already streamed the correct array. The previous `jq ... || echo '[]'` then
# APPENDED a stray '[]', so `$ready` held two JSON values, `jq length` returned
# the two-line string "1\n0", and the `[ $j -lt $n_ready ]` integer test in the
# drive/route loop aborted with "integer expression expected" — the tick
# silently no-op'd past ALL Ready work (drove/routed nothing on the live board).
# Fix: capture jq's stdout, IGNORE its exit (the emitted array is correct), then
# collapse to the first array value — never append a fallback after partial
# output. `.items[]?` also tolerates a missing / non-array `.items`.
#
# Resume inclusion (foundation #624): a handed-off merge drive is still CLAIMED —
# `claim.sh` flipped its card to **In Progress** before /build ran, and the card
# never left In Progress when the one-shot session died after opening the PR (board
# → Done fires only on merge). A Ready-only scan would therefore never see it, and
# the funnel-merge-pending marker would be written but never read. So this also
# enumerates **In-Progress items carrying PIPELINE_MERGE_PENDING_LABEL** — the only
# In-Progress cards the pipeline re-touches — so the resume gate downstream can fire.
# (A normal In-Progress card, unlabeled, is another session's active work and stays
# invisible here.) Resume items are sorted FIRST so an in-flight PR finishes before
# a fresh drive is started, within the one-drive-per-tick slot (finish-before-start).
ready_items_from_json() {
  local json="$1" out
  out="$(jq -c --arg lbl "$PIPELINE_MERGE_PENDING_LABEL" '[.items[]?
                 | select(.status == "Ready"
                          or (.status == "In Progress"
                              and ((.labels // []) | index($lbl)) != null))
                 | {number:(.content.number // .number), title:(.title // ""),
                    labels:[(.labels // [])[]]}]
                 | sort_by(if ((.labels // []) | index($lbl)) then 0 else 1 end)' <<<"$json" 2>/dev/null)" || true
  out="$(printf '%s' "$out" | jq -c -s '(map(select(type == "array")) | .[0]) // []' 2>/dev/null)" || out='[]'
  printf '%s\n' "$out"
}

# List Ready items with their work-class label.
# Live: the board adapter (board_resolve → BOARD_ITEMS_JSON → ready_items_from_json).
# Fixture (--dry-run): prefer a RAW board-items blob ($FIXTURE/board-<N>/items.json)
# so the dry path exercises the SAME normalizer as live (offline regression
# coverage for #584); else fall back to the pre-projected
# $FIXTURE/board-<N>/ready.json — array of {number,title,labels:[...]}.
read_ready_items() {
  local board="$1"
  if [ "$DRY_RUN" -eq 1 ]; then
    local raw="$FIXTURE/board-$board/items.json"
    if [ -f "$raw" ]; then
      ready_items_from_json "$(cat "$raw")"; return
    fi
    local f="$FIXTURE/board-$board/ready.json"
    [ -f "$f" ] && cat "$f" || echo '[]'
  else
    # Live path: resolve the board, then project via the shared normalizer.
    # Delegated to the adapter — NOT re-implemented here. The adapter call is
    # the live seam; tests exercise the same normalizer via the items.json fixture.
    local lib="$HERE/../board/lib/board.sh"
    if [ -f "$lib" ]; then
      # shellcheck source=/dev/null
      . "$lib"
      # Issue-plane read cache (F#988). board.sh's cached read arms gate on
      # `command -v cache_read` and board.sh never sources cache.sh itself (a
      # deliberate one-way layering, board.sh:521-526), so this caller must —
      # otherwise `board.<N>.cache=on` is inert here and board_resolve below
      # takes the live arm with a per-call stderr notice. Guarded on existence
      # (a consuming repo may vendor board.sh without cache.sh) and inert with
      # the axis off: sourcing only sets three `${VAR:-default}`s + functions.
      local cache_lib="$HERE/../board/lib/cache.sh"
      if [ -f "$cache_lib" ]; then
        # shellcheck source=/dev/null
        . "$cache_lib"
      fi
      board_resolve "$board" >/dev/null 2>&1 || { echo '[]'; return; }
      ready_items_from_json "${BOARD_ITEMS_JSON:-{\"items\":[]}}"  # setting:exempt — internal already-fetched board cache, not an operator default
    else
      echo '[]'
    fi
  fi
}

# ── Typed-reply parser (contract § 3) ────────────────────────────────────────
# Reads the MOST RECENT comment body and returns the chosen option, or "" on a
# parse miss. Accepts: a fenced ```decision``` block with `chosen: <x>`, or the
# `/choose <x>` / `/approve` shorthands (start-of-line). Closed-enum-or-escalate:
# a miss returns empty → the caller routes to drain-parse-miss (re-assign op),
# NEVER a silent default.
parse_reply() {
  local body="$1" chosen=""
  # /approve shorthand (start of a line)
  if printf '%s\n' "$body" | grep -iE '^/approve([[:space:]]|$)' >/dev/null; then
    echo "approve"; return 0
  fi
  # /choose <label> shorthand (start of a line) — take the rest of the line
  local choose_line
  choose_line="$(printf '%s\n' "$body" | grep -iE '^/choose[[:space:]]+' | head -1 || true)"
  if [ -n "$choose_line" ]; then
    chosen="$(printf '%s' "$choose_line" | sed -E 's@^/choose[[:space:]]+@@' | tr -d '\r' | awk '{$1=$1;print}')"
    [ -n "$chosen" ] && { echo "$chosen"; return 0; }
  fi
  # Fenced ```decision``` block with `chosen: <x>`
  chosen="$(printf '%s\n' "$body" \
    | awk '/^```decision/{f=1;next} /^```/{f=0} f' \
    | grep -iE '^[[:space:]]*chosen:' | head -1 \
    | sed -E 's@^[[:space:]]*chosen:[[:space:]]*@@' | tr -d '\r' | awk '{$1=$1;print}')"
  if [ -n "$chosen" ]; then echo "$chosen"; return 0; fi
  echo ""   # parse miss
  return 0
}

# Most-recent comment body from a decision-issue JSON object.
latest_comment_body() {
  jq -r '(.comments // []) | if length>0 then (sort_by(.createdAt)|last|.body) else "" end' 2>/dev/null
}

# ── Work-class classifier ────────────────────────────────────────────────────
# Reads an item's labels → "Operational" | "Foundational". One lookup, two rules
# from work-class-policy.md — the match ORDER below is what implements both:
#
#   • PRECEDENCE — Foundational wins (temperloop#1191; work-class-policy.md
#     § Precedence when both labels are present: Foundational wins). An item
#     carrying BOTH work-class labels resolves Foundational, so it GATES to the
#     operator's decision queue (Phase C, route-foundational) instead of routing
#     to autonomous drive (Phase B, drive-ready). Matching `Foundational` FIRST
#     IS that rule — an ambiguous work class gets human judgment, never an
#     autonomous merge. No writer creates the both-present state any more
#     (capture.sh and /triage both substitute rather than append), but
#     pre-existing dual-labeled issues that no stamp-time guard could reach
#     still arrive here, and this is the defined answer for them. Deliberately a
#     router rule only: no backfill, no mutual-exclusivity enforcement.
#   • DEFAULT-OPERATIONAL — an item with NEITHER label defaults to Operational.
classify_item() {
  local labels_json="$1"
  if jq -e 'any(.[]; . == "Foundational")' <<<"$labels_json" >/dev/null 2>&1; then
    echo "Foundational"  # precedence: wins even when Operational is present too
  else
    echo "Operational"   # default-Operational covers the explicit Operational label too
  fi
}

# ── Operator-clarification gate (foundation #594, corrected #600) ─────────────
# A Ready item carrying `needs-clarification` is blocked on an OPERATOR ANSWER
# (an open question parks it in Ready, #435 — answered downstream by `/sweep`
# Phase 1 / `/assess`, which clears the label). It is NOT auto-driven; the drive
# loop ROUTES it to the operator (assign + surface the question) instead. #594
# originally lumped `spike` into this gate too and skipped both — that was wrong
# (#600): a `spike` is automatable read-only investigation whose verdict feeds a
# decision AFTER it runs, so it is a DRIVE target, not an operator-input gate, and
# is no longer matched here (it falls through to classify_item → Operational →
# drive-ready). classify_item alone can't catch needs-clarification — it checks
# only `Foundational`, so the label would otherwise default to Operational and be
# driven. Returns rc 0 (prints the label) on a hit, rc 1 on a miss; rc is the gate.
needs_clarification() {
  local labels_json="$1"
  jq -e 'any(.[]; . == "needs-clarification")' <<<"$labels_json" >/dev/null 2>&1 || return 1
  printf 'needs-clarification\n'
}

# ── Level 5c code-escalation gate (foundation #697) ────────────────────────────
# A Ready item carrying `funnel-escalated` is a CODE item the merge tier could not
# land (route-refused / terminally-red CI); pipeline-drive.sh assigned the operator +
# applied this OWN label (not `needs-clarification` — #697's split). It has an open or
# failed PR and awaits a MANUAL merge/close, so it must NEVER be auto-driven: a fresh
# drive would open a DUPLICATE PR. This gate is the duplicate-PR guard the shared
# `needs-clarification` label was silently providing before the split — it keeps the
# item OUT of the drive pool (the Ready loop PARKS it as route-already-assigned). Same
# rc contract as needs_clarification: rc 0 (prints the label) on a hit, rc 1 on a miss.
pipeline_escalated() {
  local labels_json="$1"
  jq -e --arg l "$PIPELINE_ESCALATED_LABEL" 'any(.[]; . == $l)' <<<"$labels_json" >/dev/null 2>&1 || return 1
  printf '%s\n' "$PIPELINE_ESCALATED_LABEL"
}

# ── Cross-tick merge hand-off gate (foundation #624) ──────────────────────────
# True when a Ready item carries PIPELINE_MERGE_PENDING_LABEL — its prior headless
# merge drive opened a PR but the one-shot session ended before the merge gate
# fired (pipeline-drive.sh applied the marker off a ground-truth open-PR probe). Such
# an item must be RESUMED (re-attach to the open PR + run /build's merge gate), not
# re-driven from scratch (a fresh drive opens a duplicate PR). Returns rc 0 on a hit,
# rc 1 on a miss; rc is the gate. Checked AFTER needs_clarification (an open operator
# question outranks a resume) and only matters for an Operational drive-ready item.
pending_merge() {
  local labels_json="$1"
  jq -e --arg l "$PIPELINE_MERGE_PENDING_LABEL" 'any(.[]; . == $l)' <<<"$labels_json" >/dev/null 2>&1
}

# Ground-truth open-PR probe (foundation #641) — the belt-and-suspenders behind
# pending_merge. The hand-off MARKER is trustworthy ONLY when pipeline-drive.sh's
# `gh issue edit --add-label` actually succeeded; if that gh call FAILED (auth /
# rate-limit / repo mismatch) the label is silently absent, pending_merge returns
# false, and a kind:code item would be re-driven FRESH → a DUPLICATE PR. So before
# emitting a fresh code drive we ask GitHub directly: is there an OPEN PR whose body
# closes this issue? Echoes the PR number if so (→ recover to resume), nothing
# otherwise (→ genuinely fresh). Mirrors pipeline-drive.sh's `_open_pr_for_issue`
# (canonical there) but adapted to pipeline-tick's DRY_RUN/fixture harness. Same-repo
# bare `Closes #N` form (the pipeline drives same-repo). Fail-open: any gh/jq error →
# nothing → fresh drive (never wedges the tick; the marker path already handled the
# common resume, this only covers the lost-label edge).
open_pr_for_issue() {  # $1=board  $2=repo  $3=issue
  local board="$1" repo="$2" issue="$3" json
  if [ "$DRY_RUN" -eq 1 ]; then
    local f="$FIXTURE/board-$board/open-pr-$issue.txt"
    if [ -f "$f" ]; then tr -dc '0-9' < "$f"; fi
    return 0
  fi
  json="$(gh pr list -R "$repo" --state open --json number,body --limit 100 2>/dev/null)" || return 0
  [ -z "$json" ] && return 0
  jq -r --arg n "$issue" '
    [ .[]? | select((.body // "")
        | test("(?i)(close[sd]?|fix(e[sd])?|resolve[sd]?)[[:space:]]+#" + $n + "\\b"))
      | .number ] | (.[0] // empty)' <<<"$json" 2>/dev/null || return 0
}

# ── Bare-singleton gate for a fresh kind:code drive (foundation #717) ──────────
# #635 split the fresh emit by kind: a kind:spike drive-ready routes to the singleton
# verdict path, a kind:code keeps the epic /triage→/assess --epic→/build sequence. But
# a kind:code Ready item can ALSO be a bare singleton (0 sub-issues AND no `## Contract`
# body) — and /assess --epic REFUSES it ("no sub-issues and no Contract → run /triage"),
# so /build gets no plan note and the scarce 5c merge cap burns on a guaranteed no-op
# every tick (the 2026-07-01 F499/F533/F534/F538/F659 dead-end). This is the kind:code
# sibling of #635. Detect the bare singleton so the emit can route it through /sweep's
# per-issue build path (scoped to the one issue) instead of /assess --epic.
#
# Signal — one REST read (mirrors board_parent_issue's `repos/…/issues/N` endpoint,
# which reads `.parent_issue_url` off the same object): a bare singleton iff
# `.sub_issues_summary.total == 0` (no children → not an epic parent) AND the body
# carries no `## Contract` heading (no pre-designed undecomposed Contract for /assess
# to decompose — the #526 seam). Cap-bounded: fires only for a fresh kind:code
# candidate, so at most PIPELINE_DRIVE_CAP times per tick (like open_pr_for_issue).
#
# FAIL-OPEN to the EPIC route (rc 1) on ANY gh/jq error, empty data, or missing
# fixture — a genuine epic mis-routed to the singleton path would be silently skipped
# by /sweep (worse than the status quo), so ambiguity KEEPS the current epic behavior.
# Dry-run purity: reads a `board-$board/singleton-$issue.json` fixture (the raw issue
# object); no fixture → rc 1 (epic route), so every pre-#717 test that omits the
# fixture keeps its epic-path expectation unchanged.
#
# Returns rc 0 (IS a bare singleton → /sweep per-issue route) / rc 1 (epic or unknown).
bare_ready_singleton() {  # $1=board  $2=repo  $3=issue
  local board="$1" repo="$2" issue="$3" json total body
  if [ "$DRY_RUN" -eq 1 ]; then
    local f="$FIXTURE/board-$board/singleton-$issue.json"
    [ -f "$f" ] || return 1
    json="$(cat "$f")"
  else
    json="$(gh api "repos/$repo/issues/$issue" 2>/dev/null)" || return 1
  fi
  [ -n "$json" ] || return 1
  total="$(jq -r '.sub_issues_summary.total // 0' <<<"$json" 2>/dev/null)" || return 1
  # Any sub-issue → a genuine epic parent → keep the epic route.
  case "$total" in ''|*[!0-9]*) return 1 ;; esac
  [ "$total" -eq 0 ] || return 1
  # A `## Contract` body → a pre-designed undecomposed epic /assess decomposes → epic route.
  body="$(jq -r '.body // ""' <<<"$json" 2>/dev/null)" || return 1
  printf '%s\n' "$body" | grep -iE '^[[:space:]]*##[[:space:]]+Contract\b' >/dev/null && return 1
  return 0
}

# ── Phase R helpers — retro-judge trigger (epic #528, temperloop#535) ────────
# The KERNEL trigger half of the mint-then-judge design: build.md 4d-retro
# (#533, already merged) files a `retro-pending`/`retro-info` tracker at epic
# close, applying `retro-urgent` when past the mint's own urgency bar. This
# phase reads back the `retro-pending` set and decides whether it's due — it
# holds NO judgment beyond the RETRO_MIN_INTERVAL debounce (urgency was
# already decided at mint, and RETRO_BATCH_SESSION_CAP is the judge's own
# concern, never enforced here).

# List OPEN `retro-pending` trackers for a board/repo.
# Live: `gh issue list --search 'label:retro-pending state:open'`. Fixture:
# $FIXTURE/board-<N>/retro-trackers.json — the SAME raw shape (an array of
# {number,title,createdAt,labels,state?}), filtered here by the identical
# state:open + label:retro-pending predicate the live search applies — so a
# fixture tracker pre-set to `retro-judged`/closed (e.g. left in the fixture
# file for test convenience, already processed by a prior judge run) is
# filtered out exactly as it would be live, and is NEVER re-emitted.
read_retro_trackers() {
  local board="$1" repo="$2"
  if [ "$DRY_RUN" -eq 1 ]; then
    local f="$FIXTURE/board-$board/retro-trackers.json"
    [ -f "$f" ] || { echo '[]'; return; }
    jq -c '[.[] | select(((.state // "open") | ascii_downcase) == "open")
                 | select((.labels // []) | index("retro-pending"))]' "$f" 2>/dev/null || echo '[]'
  else
    local raw
    raw="$(gh issue list -R "$repo" --search 'label:retro-pending state:open' \
      --json number,title,createdAt,labels 2>/dev/null)"
    [ -n "$raw" ] || { echo '[]'; return; }
    # `gh issue list --json …labels` hands back `labels` as OBJECTS
    # ({id,name,description,color}), never bare strings — normalize to a bare
    # name array here so this LIVE arm agrees with the shape the DRY_RUN
    # fixture arm already speaks (an array of strings). Without this,
    # retro_judge_due_reason's `index("retro-urgent")` is always false against
    # the raw object shape, so the urgency bypass never fires live
    # (temperloop#1184). Do NOT normalize the fixture arm instead — its
    # fixtures already use the string shape gh's search-index encodes on disk.
    jq -c '[.[] | .labels = ((.labels // []) | map(.name // empty) | map(select(. != "")))]' \
      <<<"$raw" 2>/dev/null || echo '[]'
  fi
}

# ISO8601 UTC (`YYYY-MM-DDTHH:MM:SSZ`, gh's `createdAt` shape) → epoch seconds.
# Platform-dialect guard (kernel CLAUDE.md § Tool invocation discipline: macOS
# ships BSD date, no `-d`): try GNU `date -d` first (the Linux cron host), fall
# back to BSD/macOS `date -j -f` (a dev laptop). Echoes nothing + rc 1 on a
# parse failure — the caller skips an unparseable createdAt rather than
# mis-computing an age off it.
_retro_iso_to_epoch() {
  local iso="$1"
  date -u -d "$iso" +%s 2>/dev/null && return 0
  date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$iso" +%s 2>/dev/null && return 0
  return 1
}

# Epoch seconds -> ISO8601 UTC. Platform-dialect twin of _retro_iso_to_epoch
# above (same GNU-then-BSD fallback) — used to render the not-due skip's
# due-at in the same createdAt shape gh already speaks. Echoes nothing + rc 1
# on a conversion failure (neither date dialect available).
_retro_epoch_to_iso() {
  local epoch="$1"
  date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null && return 0
  date -u -r "$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null && return 0
  return 1
}

# Oldest createdAt (epoch seconds) across $1 (a retro-trackers JSON array), or
# nothing (rc 1) when none parse. Shared by retro_judge_due_reason's debounce
# check and the not-due skip's due-at computation below, so both read the same
# "oldest" fact off one loop.
_retro_oldest_epoch() {
  local trackers="$1" ts epoch oldest=""
  while IFS= read -r ts; do
    [ -z "$ts" ] && continue
    epoch="$(_retro_iso_to_epoch "$ts")" || continue
    if [ -z "$oldest" ] || [ "$epoch" -lt "$oldest" ]; then oldest="$epoch"; fi
  done < <(jq -r '.[].createdAt // empty' <<<"$trackers" 2>/dev/null)
  [ -n "$oldest" ] || return 1
  printf '%s\n' "$oldest"
}

# Is $1 (a retro-trackers JSON array, already filtered to open+retro-pending)
# DUE for the judge? Echoes the reason ("urgent" or "debounce") + rc 0 when
# due; rc 1 (nothing echoed) when not due (empty set, or the oldest tracker
# hasn't crossed RETRO_MIN_INTERVAL and none is urgent).
#   urgent   — ANY tracker carries `retro-urgent` (decided at mint, #533) —
#              bypasses the age gate unconditionally, checked FIRST.
#   debounce — no urgent tracker, but the OLDEST tracker's age (now - its
#              createdAt) is >= RETRO_MIN_INTERVAL.
# This is the ONLY threshold Phase R applies — the tick holds no policy beyond
# it (RETRO_BATCH_SESSION_CAP is the judge's own concern downstream).
retro_judge_due_reason() {
  local trackers="$1" now oldest
  jq -e 'any(.[]; (.labels // []) | index("retro-urgent"))' <<<"$trackers" >/dev/null 2>&1 \
    && { echo "urgent"; return 0; }
  now="${PIPELINE_NOW_EPOCH:-$(date -u +%s)}"
  oldest="$(_retro_oldest_epoch "$trackers")" || return 1
  [ $(( now - oldest )) -ge "${RETRO_MIN_INTERVAL:-259200}" ] && { echo "debounce"; return 0; }
  return 1
}

# The capability an overlay `/retro` must DECLARE before this phase will spawn
# it unattended (temperloop#1150). The declaration grammar is one marker line,
# alone on its line, in the resolved `retro.md`:
#     <!-- capability: headless-unattended -->
# See workflows/scripts/lib/command_declared.sh's header. This is a CONTRACT
# TOKEN (a name in a grammar shared with the overlay), not a tunable — it is
# deliberately NOT a build.config.sh setting: making it configurable would only
# let a host rename the handshake, and a knob to switch the gate OFF is exactly
# the silence this item exists to remove.
RETRO_HEADLESS_CAPABILITY='headless-unattended'

# Phase R — EMIT the retro-judge trigger (or a legible skip) for one board.
# bash 3.2 has no namerefs, so this function returns nothing to the caller
# directly — its only contract is ACTIONS growth: append exactly one action
# when it has anything to say (a skip-retro-judge, or a due retro-judge),
# append nothing when there is genuinely nothing to report (a judge is
# declared+capable but there are no trackers, or trackers exist but none is
# due). The caller (tick_board) detects whether it emitted anything by diffing
# ACTIONS before/after, mirroring how did_op/did_found/did_route are tracked
# inline.
#
# EVERY skip carries a machine-readable `reason` (temperloop#1150) so a reader —
# pipeline-retro-health.sh, /tidy's Retro mint backstop, an operator — can tell
# the two structurally different skips apart without parsing prose:
#   not-declared        no `/retro` command file on any surface (a kernel-only
#                       checkout / CI) — expected, steady state.
#   headless-unsupported a `/retro` IS installed but does not declare
#                       `headless-unattended` — a real, actionable gap: the
#                       judge exists and cannot be driven unattended.
run_retro_phase() {
  local board="$1" repo="$2"
  # Read the parked retro-pending set FIRST: a skip (or a trigger) is only
  # meaningful when retro work is actually parked. An empty set emits nothing —
  # which is what keeps the probe-false path from adding a spurious
  # skip-retro-judge to EVERY tick on a checkout with no /retro judge (a
  # kernel-only checkout / CI), where it would otherwise inflate every unrelated
  # tick's action list (the fixture action-count regression, temperloop#535).
  local trackers n
  trackers="$(read_retro_trackers "$board" "$repo")"
  n="$(jq 'length' <<<"$trackers" 2>/dev/null || echo 0)"
  [ "${n:-0}" -gt 0 ] || return 0
  if ! { command -v command_declared >/dev/null 2>&1 && command_declared retro; }; then
    # Parked trackers exist but no overlay `/retro` judge is installed — emit
    # exactly one legible skip naming the parked count; no retro-judge action.
    add_action "$(jq -cn --arg b "$board" --arg r "$repo" --argjson n "$n" \
      '{phase:"retro",board:$b,repo:$r,action:"skip-retro-judge",count:$n,reason:"not-declared",
        detail:("\($n) retro-pending tracker(s) parked, but no /retro judge is declared (command_declared retro = false, or the shared lib was unsourceable) — they stay parked; no retro-judge action emitted this tick")}')"
    return 0
  fi
  # GATE 2 — HEADLESS CAPABILITY (temperloop#1150). A judge that is INSTALLED
  # but cannot complete an unattended `--pending` run is worse than an absent
  # one: spawning it burns a nested headless session that ends its turn and
  # exits `subtype: success` having judged nothing, so the tick, the wake
  # record, and the operator all read "healthy" while the retro loop is dead.
  # Refuse legibly instead. The capability is DECLARED by the overlay judge
  # (the marker grammar above), never inferred — an undeclared capability is a
  # refusal, and the fix is one marker line in the judge, named right here in
  # the skip so the remedy is on the live line rather than in a doc.
  if ! { command -v command_declared_capability >/dev/null 2>&1 \
         && command_declared_capability retro "$RETRO_HEADLESS_CAPABILITY"; }; then
    add_action "$(jq -cn --arg b "$board" --arg r "$repo" --argjson n "$n" --arg cap "$RETRO_HEADLESS_CAPABILITY" \
      '{phase:"retro",board:$b,repo:$r,action:"skip-retro-judge",count:$n,reason:"headless-unsupported",
        detail:("\($n) retro-pending tracker(s) parked and a /retro judge IS installed, but it does not declare the \($cap) capability (command_declared_capability retro \($cap) = false, or the shared lib was unsourceable) — the kernel refuses to spawn a judge that has not asserted it can complete an unattended --pending run, because such a run exits success having judged nothing (temperloop#1150). Trackers stay parked. Remedy: add the marker line <!-- capability: \($cap) --> to the /retro command file once its headless --pending mode genuinely completes unattended")}')"
    return 0
  fi
  local reason
  if reason="$(retro_judge_due_reason "$trackers")"; then
    add_action "$(jq -cn --arg b "$board" --arg r "$repo" --argjson n "$n" --arg reason "$reason" \
      --arg model "$RETRO_JUDGE_MODEL" \
      '{phase:"retro",board:$b,repo:$r,action:"retro-judge",count:$n,reason:$reason,
        emit:("claude -p \"/retro --pending --board "+$b+"\" --model "+$model+" — hand "+($n|tostring)+" due retro-pending tracker(s) to the overlay judge ("+
              (if $reason=="urgent" then "urgency bypass: at least one tracker carries retro-urgent, decided at mint (#533)"
               else "oldest tracker'"'"'s age has crossed RETRO_MIN_INTERVAL" end)+")"),
        detail:"THIN trigger only: urgency was decided at mint, not here; the only threshold this phase applies is the RETRO_MIN_INTERVAL debounce (bypassed by urgency); RETRO_BATCH_SESSION_CAP is the judge'"'"'s own concern, never enforced here (epic #528, temperloop#535)"}')"
    return 0
  fi
  # Not due (temperloop#1184): trackers ARE parked, none is urgent, and the
  # oldest hasn't crossed RETRO_MIN_INTERVAL yet — the STEADY-STATE debounce
  # wait, distinct from the two broken-judge skips above. Emit it too (never
  # silence — temperloop#1150's "every skip is legible" rule applies here as
  # much as to not-declared/headless-unsupported) so a parked-but-not-due set
  # reads as "waiting on schedule" rather than "the phase went quiet".
  local oldest due_at due_at_iso
  if oldest="$(_retro_oldest_epoch "$trackers")"; then
    due_at=$(( oldest + ${RETRO_MIN_INTERVAL:-259200} ))
    due_at_iso="$(_retro_epoch_to_iso "$due_at")" || due_at_iso="$due_at"
  else
    due_at_iso="unknown"
  fi
  add_action "$(jq -cn --arg b "$board" --arg r "$repo" --argjson n "$n" --arg due "$due_at_iso" \
    '{phase:"retro",board:$b,repo:$r,action:"skip-retro-judge",count:$n,reason:"not-due",due_at:$due,
      detail:("\($n) retro-pending tracker(s) parked, none urgent, oldest has not yet crossed RETRO_MIN_INTERVAL — due at \($due) UTC (steady-state debounce wait, not a broken judge)")}')"
}

# ── Phase 0 — crash-signal intake (foundation #671, epic #637) ───────────────
# Runs /signal-intake (the L2 crash-convergence orchestrator) ONCE per board,
# BEFORE any of the tick's spend decisions — Phase A's drain loop and Phase
# B/C's PIPELINE_DRIVE_CAP-gated drive/route loop below (the closest thing this
# scheduler has to a "spend gate": the counter that decides how much of this
# tick's Ready work gets driven). Placing intake ahead of that gate is what
# makes intake run on EVERY tick, including a tick that ends up driving/
# routing nothing (a "spend-closed" tick) — not just ticks with drivable work.
#
# BEST-EFFORT AND NON-BLOCKING (the hard requirement): the pipeline's core job
# is driving the board, and that must never fail because crash intake had a
# problem — a missing SENTRY_AUTH_TOKEN, a Sentry API error, a board-adapter
# hiccup. A non-zero exit from the orchestrator is caught, logged to stderr,
# and swallowed; `set -e` never sees it (the `||` below absorbs the exit code
# before it can propagate), so the tick always continues to Phase A.
#
# Dry-run purity (mirrors pipeline-drive.sh's --dry-run guarantee, foundation
# #604/#615): a --dry-run tick must stay side-effect-free — no network, no
# `gh`. So when DRY_RUN=1 AND PIPELINE_INTAKE_CMD is still its default (the real
# script), skip the call outright rather than actually invoking Sentry/board
# calls. A test that wants to exercise the failure-handling path sets
# PIPELINE_INTAKE_CMD to a stub — an explicit override runs even under --dry-run,
# since a stub has no side effects of its own.
# Emit the config-absent WARN for $board with $reason AT MOST ONCE per condition
# (temperloop#330): only when the reason differs from the one already recorded in
# the per-board marker (or no marker yet). This is the "once per condition, not per
# poll" dedup — each tick is a fresh process, so the "already warned" state must
# persist on disk. Marker write is best-effort: a /tmp write failure must never
# wedge the tick (the WARN already printed), so every fs op is `|| true`-guarded.
_intake_warn_once() {
  local board="$1" reason="$2" marker prev=""
  marker="$PIPELINE_INTAKE_WARN_DIR/intake-warned-$board"
  [ -f "$marker" ] && prev="$(cat "$marker" 2>/dev/null || true)"
  if [ "$prev" != "$reason" ]; then
    printf 'pipeline-tick: WARN — signal-intake config absent for board %s: %s (emitted once per condition, not per tick)\n' \
      "$board" "$reason" >&2
    mkdir -p "$PIPELINE_INTAKE_WARN_DIR" 2>/dev/null || true
    printf '%s\n' "$reason" > "$marker" 2>/dev/null || true
  fi
}

# Clear a board's config-absent marker once config is PRESENT again, so the next
# time it goes absent the WARN fires afresh (once-per-condition, never once-ever).
_intake_warn_clear() {
  rm -f "$PIPELINE_INTAKE_WARN_DIR/intake-warned-$1" 2>/dev/null || true
}

run_intake_phase() {
  local board="$1"
  if [ "$DRY_RUN" -eq 1 ] && [ "$PIPELINE_INTAKE_CMD" = "$HERE/../crash-convergence/signal-intake.sh" ]; then
    return 0
  fi

  # Config-absent surfacing (temperloop#330) — two conditions, two dispositions:
  #
  #  1. backend MISSING / not executable — invoking it would just make the rc!=0
  #     failure path below spam EVERY tick (rc=127), so WARN once and SKIP the
  #     invocation entirely.
  #  2. backend present but the Sentry credential is UNSET/placeholder — intake
  #     runs but cleanly no-ops (nothing to poll), the exact silent case #330
  #     observed no-op'ing ~19h unnoticed. WARN once, then STILL invoke best-effort
  #     (the backend is a black box that may do token-free work, and a stubbed
  #     backend must still run — warn-not-skip keeps the #671 intake tests intact).
  #
  # A recovered tick (backend present AND credential set) clears the marker so a
  # future re-absence warns again. The two reasons are distinct conditions, so a
  # transition between them (e.g. backend appears but token still absent) re-warns.
  if [ ! -x "$PIPELINE_INTAKE_CMD" ]; then
    _intake_warn_once "$board" "backend script not found or not executable: $PIPELINE_INTAKE_CMD"
    return 0
  fi
  case "${SENTRY_AUTH_TOKEN:-}" in # setting:exempt — credential presence-probe (unset/placeholder?), not a kernel default; the token is operator config in build.config.local.sh(.example)
    ''|REPLACE_WITH_READ_SCOPED_TOKEN)
      _intake_warn_once "$board" "SENTRY_AUTH_TOKEN unset or still the example placeholder — set it in build.config.local.sh (see build.config.local.sh.example); intake has nothing to poll" ;;
    *)
      _intake_warn_clear "$board" ;;
  esac

  local err rc=0
  err="$("$PIPELINE_INTAKE_CMD" run --board "$board" 2>&1 >/dev/null)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'pipeline-tick: signal-intake failed for board %s (non-blocking, rc=%s): %s\n' \
      "$board" "$rc" "$err" >&2
  fi
  return 0
}

# ── The tick ─────────────────────────────────────────────────────────────────
ACTIONS='[]'   # accumulated tick-plan action records
add_action() { ACTIONS="$(jq -c --argjson a "$1" '. + [$a]' <<<"$ACTIONS")"; }

tick_board() {
  local board="$1" repo
  repo="$(tick_board_repo "$board")" || { echo "pipeline-tick.sh: unknown board $board" >&2; return 1; }

  # Phase 0 — crash-signal intake, BEFORE Phase A/B/C's spend decisions (see
  # run_intake_phase's header comment). Runs every tick regardless of what (if
  # anything) this tick ends up draining/driving/routing.
  run_intake_phase "$board"

  # Phase R — retro-judge trigger (epic #528, temperloop#535), likewise BEFORE
  # Phase A/B/C: it is independent of decision/Ready state, so it is evaluated
  # every tick regardless of what else this tick drains/drives/routes. Detect
  # whether it emitted anything (bash 3.2 has no namerefs, so compare ACTIONS
  # before/after rather than have the function return a value) so the
  # tick-is-a-no-op check below does not contradict a retro-judge/skip record.
  local actions_before_retro="$ACTIONS"
  run_retro_phase "$board" "$repo"
  local did_retro=0
  [ "$ACTIONS" != "$actions_before_retro" ] && did_retro=1

  # ── Phase A — drain answered decisions FIRST (contract + build.md 0a) ──────
  local decisions reply chosen issue
  decisions="$(read_answered_decisions "$board" "$repo")"
  local n_dec; n_dec="$(jq 'length' <<<"$decisions")"
  local i=0
  while [ "$i" -lt "$n_dec" ]; do
    local d; d="$(jq -c ".[$i]" <<<"$decisions")"
    issue="$(jq -r '.number' <<<"$d")"
    reply="$(latest_comment_body <<<"$d")"

    # Idempotency guard (§ #587): a just-drained issue can be re-listed once
    # before the label drop propagates through the search index. If its latest
    # comment is the applier's delivery artifact, it is already applied — skip it
    # cleanly (NOT a parse-miss; do not re-assign the operator). Cheap (no API
    # call), so it runs before the contention pre-check's fresh assignee read.
    if decision_already_applied "$reply"; then
      add_action "$(jq -cn --arg b "$board" --arg r "$repo" --argjson n "$issue" \
        '{phase:"drain",board:$b,repo:$r,issue:$n,action:"drain-already-applied",
          detail:"latest comment is the delivery artifact (decision already applied; label drop not yet propagated) — idempotent skip"}')"
      i=$((i+1)); continue
    fi

    # Contention pre-check (§ 4): re-read current assignees; non-zero = raced.
    # With the unassigned-scoped drain list (#587), a non-zero count here is a
    # GENUINE mid-tick re-assign (the operator or another tick grabbed the baton
    # after the list read) — not an always-assigned issue the old over-pull mixed
    # in — so the "assignee changed since drain-list" reason is now accurate.
    local cur; cur="$(read_assignee_count "$board" "$repo" "$issue")"
    if [ "${cur:-0}" -gt 0 ]; then
      add_action "$(jq -cn --arg b "$board" --arg r "$repo" --argjson n "$issue" \
        '{phase:"drain",board:$b,repo:$r,issue:$n,action:"skip-contention",
          detail:"assignee changed since drain-list — skip this tick"}')"
      i=$((i+1)); continue
    fi

    chosen="$(parse_reply "$reply")"
    if [ -z "$chosen" ]; then
      # Parse miss → re-assign operator with a couldn't-parse note (no guess).
      # reassign_to is emitted as a BARE login (strip the leading `@`) — it feeds an
      # `--add-assignee` call (pipeline-drive.md) and GitHub's replaceActorsForAssignable
      # cannot resolve an `@`-prefixed login (foundation #977; mirrors pipeline-drive.sh's
      # `${PIPELINE_OPERATOR#@}` strip at 555/633). The `@` stays in PIPELINE_OPERATOR for
      # mention text; only the assignee target is bared. The literal `@me` token is
      # PRESERVED — gh special-cases it to the authenticated user, so stripping it to
      # `me` (a non-user) would re-break the very assign this fixes.
      add_action "$(jq -cn --arg b "$board" --arg r "$repo" --argjson n "$issue" --arg op "$PIPELINE_OPERATOR" \
        '{phase:"drain",board:$b,repo:$r,issue:$n,action:"drain-parse-miss",
          reassign_to:(if $op == "@me" then $op else ($op | ltrimstr("@")) end),
          detail:"could not parse reply as a decision block or /command — re-assigned operator (closed-enum-or-escalate)"}')"
    else
      # Parsed → EMIT the drain-apply (build.md 0a / tidy owns the apply:
      # translate reply → artifact, drop the decision label, hand baton back).
      # The scheduler ROUTES; it does not perform the sentinel/worktree work.
      add_action "$(jq -cn --arg b "$board" --arg r "$repo" --argjson n "$issue" --arg c "$chosen" \
        '{phase:"drain",board:$b,repo:$r,issue:$n,action:"drain-answer",chosen:$c,
          emit:("apply answered decision #"+($n|tostring)+" (chosen="+$c+") → drop `decision` label, hand baton back; resume via build.md Step 0a / tidy § Answered decisions"),
          detail:"parsed typed reply; routed to the existing drain (no re-implementation)"}')"
    fi
    i=$((i+1))
  done

  # ── Phase A2 — drain ANSWERED needs-clarification items (foundation #657) ───
  # The clarification counterpart to the decision drain above, on the SAME baton:
  # since #684 a `needs-clarification` item is assigned to the operator at source,
  # so an UNASSIGNED one (this list) is answered + handed back. Clearing the label
  # is all that is needed to make it drivable again — the free-text answer already
  # lives on the issue, read downstream by /assess//build (no reply to parse). The
  # apply (remove label + post the sentinel ack) is a no-PR/no-merge safe mutation
  # the 5b executor performs; this script only ROUTES. Numbers drained here are
  # recorded in `drained_clar` so the Ready-loop park gate below does not ALSO park
  # the same item (it is unassigned, so it appears in both this list and Ready).
  local drained_clar=" "
  local clarifs; clarifs="$(read_answered_clarifications "$board" "$repo")"
  local n_clar; n_clar="$(jq 'length' <<<"$clarifs")"
  local k=0
  while [ "$k" -lt "$n_clar" ]; do
    local c cnum creply
    c="$(jq -c ".[$k]" <<<"$clarifs")"
    cnum="$(jq -r '.number' <<<"$c")"
    creply="$(latest_comment_body <<<"$c")"

    # (#697 retired the merge-escalation guard that lived here: level-5c CODE
    # escalations now carry their OWN `funnel-escalated` label — never
    # `needs-clarification` — so read_answered_clarifications' search can no longer
    # list one. The exclusion is now the absence of the label at SEARCH time, not a
    # per-item comment-history scan. The pipeline_escalated park gate in the Ready loop
    # keeps such an item out of the drive pool.)

    # Idempotency: latest comment is the executor's clarified-marker ack → the
    # label drop just hasn't propagated. Skip (do NOT re-drain).
    if clarification_already_applied "$creply"; then
      add_action "$(jq -cn --arg b "$board" --arg r "$repo" --argjson n "$cnum" \
        '{phase:"drain",board:$b,repo:$r,issue:$n,action:"drain-clarification-already-applied",
          detail:"latest comment is the clarified-marker ack (label drop not yet propagated) — idempotent skip"}')"
      drained_clar="$drained_clar$cnum "
      k=$((k+1)); continue
    fi

    # Contention pre-check: a fresh re-assign since the drain-list read means the
    # operator (or another tick) re-grabbed the baton — skip this tick.
    local ccur; ccur="$(read_assignee_count "$board" "$repo" "$cnum")"
    if [ "${ccur:-0}" -gt 0 ]; then
      add_action "$(jq -cn --arg b "$board" --arg r "$repo" --argjson n "$cnum" \
        '{phase:"drain",board:$b,repo:$r,issue:$n,action:"skip-contention",
          detail:"assignee changed since clarification drain-list — skip this tick"}')"
      # Now re-assigned, so it is in the Ready pool AND awaiting — record it so the
      # park gate does not ALSO emit route-already-assigned this tick (it parks next
      # tick once stable). skip-contention is this tick's single visible record.
      drained_clar="$drained_clar$cnum "
      k=$((k+1)); continue
    fi

    # EMIT the clarification drain: clear the label + post the sentinel ack. No
    # parse — the answer is free-text context read downstream when the item drives.
    add_action "$(jq -cn --arg b "$board" --arg r "$repo" --argjson n "$cnum" --arg t "$(jq -r '.title // ""' <<<"$c")" \
      '{phase:"drain",board:$b,repo:$r,issue:$n,title:$t,action:"drain-clarification",
        emit:("clear `needs-clarification` on #"+($n|tostring)+" + post the clarified-marker ack; the answer already on the issue rides into the next drive"),
        detail:"operator answered + unassigned (baton returned) — clearing the open-question gate (foundation #657)"}')"
    drained_clar="$drained_clar$cnum "
    k=$((k+1))
  done

  # ── Phases B & C — drive Ready work by work-class ─────────────────────────
  local ready; ready="$(read_ready_items "$board")"
  local n_ready; n_ready="$(jq 'length' <<<"$ready")"

  # Up to PIPELINE_DRIVE_CAP Operational drives + one Foundational route per tick
  # (#642). did_op is now a COUNTER, not a boolean: it gates how many Operational
  # drive-ready items this tick emits (vault `cap:` feeds the cap). The claim-first
  # lock still governs real per-item concurrency once items are claimed (INHERITED
  # from /build, not enforced here). Foundational items are ROUTED, not driven, so did_found
  # stays one-per-tick — the drive cap does not apply to routing.
  local did_op=0 did_found=0 did_route=0 j=0
  while [ "$j" -lt "$n_ready" ]; do
    local it num title labels cls
    it="$(jq -c ".[$j]" <<<"$ready")"
    num="$(jq -r '.number' <<<"$it")"
    title="$(jq -r '.title // ""' <<<"$it")"
    labels="$(jq -c '.labels // []' <<<"$it")"

    # Operator-clarification gate (#594, corrected #600, simplified #684): a Ready
    # item carrying `needs-clarification` is blocked on the operator's answer —
    # never auto-drive it. PARK it (`route-already-assigned`) unconditionally, gated
    # BEFORE classifying (classify_item would default it Operational and drive it).
    # The producer that raised the question (`/triage`, `/sweep` park-on-question)
    # already assigned the operator AT SOURCE, so the item is already in the
    # operator's assigned-to-me queue and the pipeline has nothing to assign — no
    # assignee re-read, no `route-needs-input` (that step existed only to do the
    # assign the producers now own — #684). `spike` is NOT matched here (it drives —
    # #600). The loop continues, so a clean Operational item after a parked one is
    # still driven this tick.
    #
    # EXCEPTION (#657): if Phase A2 already drained this item this tick (operator
    # answered + unassigned), it is in `drained_clar`. Such an item is unassigned,
    # so it appears in BOTH the drain-list and the Ready pool — parking it here too
    # would emit a contradictory route-already-assigned alongside the drain. Skip
    # it: the drain is authoritative (the label is being cleared, not parked).
    if needs_clarification "$labels" >/dev/null; then
      case "$drained_clar" in
        *" $num "*) j=$((j+1)); continue ;;
      esac
      add_action "$(jq -cn --arg b "$board" --arg r "$repo" --argjson n "$num" --arg t "$title" \
        '{phase:"route",board:$b,repo:$r,issue:$n,title:$t,action:"route-already-assigned",label:"needs-clarification",
          detail:"Ready item carries `needs-clarification` — parked awaiting the operator answer; assignment + question owned at source by /triage//sweep, so the pipeline does not re-assign (re-enters drive once /sweep Phase 1 / /assess clears the label) (foundation #684)"}')"
      did_route=1
      j=$((j+1)); continue
    fi

    # Level 5c code-escalation gate (#697): a Ready item carrying `funnel-escalated`
    # is a code item the merge tier could not land (route-refused / terminally-red
    # CI) — pipeline-drive.sh assigned the operator + applied this OWN label. It has an
    # open/failed PR and awaits a MANUAL merge/close; auto-driving it fresh would open
    # a DUPLICATE PR. PARK it (`route-already-assigned`), gated BEFORE classify_item
    # exactly like needs_clarification — this is the duplicate-PR guard the shared
    # label used to provide before #697's split. The operator resolves it by merging/
    # closing the PR (which clears the label), not by answering a question — so unlike
    # needs-clarification it is NOT drained by Phase A2 (nothing lists it there).
    if pipeline_escalated "$labels" >/dev/null; then
      add_action "$(jq -cn --arg b "$board" --arg r "$repo" --argjson n "$num" --arg t "$title" --arg l "$PIPELINE_ESCALATED_LABEL" \
        '{phase:"route",board:$b,repo:$r,issue:$n,title:$t,action:"route-already-assigned",label:$l,
          detail:"Ready item carries `funnel-escalated` — a level-5c code item the merge tier could not land (has an open/failed PR); parked awaiting the operator manual merge/close, assigned at source by the 5c escalation, so the pipeline does not re-drive (would duplicate the PR) (foundation #697)"}')"
      did_route=1
      j=$((j+1)); continue
    fi

    # Decision-queue re-route guard (foundation #834/#1002/#1009, epic #970): a Ready
    # item already routed to the async decision queue carries the `decision` label AND
    # an operator assignee (the baton a prior route-foundational set). Re-emitting
    # route-foundational re-runs /assess and mints a DUPLICATE plan note + gate comment
    # every tick (8+ near-duplicates on stageFind#770 across 2026-07-01/02). PARK it
    # (`route-already-assigned`), gated BEFORE classify_item exactly like the
    # needs-clarification / funnel-escalated gates above. The `decision` label ALONE is
    # not enough: an UNASSIGNED `decision` item is an ANSWERED one Phase A drains
    # (read_answered_decisions is `no:assignee`), so require assignees>0 — an assigned
    # `decision` item is still parked awaiting the operator's reply and must not re-route.
    # The assignee read is cap-bounded (only `decision`-labeled Ready items reach it) and
    # dry-run-safe (read_assignee_count reads the `assignees-<n>.txt` fixture). Mirrors
    # drain-clarification's idempotency sentinel (#657) for the route-foundational path.
    if jq -e 'any(.[]; . == "decision")' <<<"$labels" >/dev/null 2>&1; then
      local dcur; dcur="$(read_assignee_count "$board" "$repo" "$num")"
      if [ "${dcur:-0}" -gt 0 ]; then
        add_action "$(jq -cn --arg b "$board" --arg r "$repo" --argjson n "$num" --arg t "$title" \
          '{phase:"route",board:$b,repo:$r,issue:$n,title:$t,action:"route-already-assigned",label:"decision",
            detail:"Ready item carries `decision` + an operator assignee — already routed to the async decision queue by a prior route-foundational; parked awaiting the operator reply. Re-routing would re-run /assess and mint a duplicate plan note + gate comment (foundation #834/#1002/#1009, epic #970). Phase A drains it once the operator answers + unassigns (which drops the label)."}')"
        did_route=1
        j=$((j+1)); continue
      fi
    fi

    cls="$(classify_item "$labels")"

    if [ "$cls" = "Operational" ] && [ "$did_op" -lt "$PIPELINE_DRIVE_CAP" ]; then
      # Phase B — EMIT the pipeline invocation. The driver CALLS /assess→/build;
      # it never assesses or builds. --unattended selects the async backend +
      # auto-merge-on-green (Operational does NOT ride the timed objection gate).
      #
      # Stamp the work `kind` (foundation #604): a `spike`-labeled item is
      # automatable read-only investigation whose drive opens NO PR (build.md's
      # kind:spike path writes a verdict note + routes a follow-up — #600); a
      # plain Operational item is `code` (its drive ends in a PR + merge). The
      # 5b headless driver (pipeline-drive.sh) filters on this: it auto-executes
      # only `kind:spike` drives (no-merge), leaving `kind:code` drives emit-only
      # for the operator to run manually (the merging tier waits for level 5c). The
      # scheduler classifies; the driver stays dumb.
      local kind="code"
      if jq -e 'any(.[]; . == "spike")' <<<"$labels" >/dev/null 2>&1; then kind="spike"; fi
      # Resume vs fresh (foundation #624): a kind:code item carrying the merge
      # hand-off marker already has an OPEN PR from a prior tick's drive — RESUME
      # the merge (re-attach + run /build's gate) rather than re-drive (a fresh
      # drive opens a duplicate PR). The marker is set only by pipeline-drive.sh off a
      # ground-truth open-PR probe, so it is trustworthy. A spike never opens a PR,
      # so it is never pending; resume applies to the merge tier only.
      # Recover a LOST hand-off marker from ground truth (#641): a kind:code item
      # WITHOUT the pending-merge label but WITH an open PR that closes it means the
      # prior tick's `--add-label` gh call failed — the item is really mid-merge, not
      # fresh. Probe only when the label is absent (the marker path already caught the
      # common resume) and only for kind:code (a spike never opens a PR), so the extra
      # `gh pr list` fires at most once per fresh-code candidate (cap-bounded).
      local recovered_pr=""
      if [ "$kind" = "code" ] && ! pending_merge "$labels"; then
        recovered_pr="$(open_pr_for_issue "$board" "$repo" "$num")"
      fi
      if [ "$kind" = "code" ] && pending_merge "$labels"; then
        add_action "$(jq -cn --arg b "$board" --arg r "$repo" --argjson n "$num" --arg t "$title" --arg k "$kind" --arg l "$PIPELINE_MERGE_PENDING_LABEL" \
          '{phase:"drive",board:$b,repo:$r,issue:$n,title:$t,action:"drive-ready",class:"Operational",kind:$k,mode:"resume",label:$l,
            emit:("RESUME the in-flight merge for #"+($n|tostring)+": re-attach to its OPEN PR and run /build --unattended on the existing plan note (re-check the now-green CI + run /build'"'"'s merge gate). Do NOT re-assess or open a new PR. If no open PR is found, fall back to a fresh drive."),
            detail:"carries the merge hand-off marker — a prior tick opened a PR but the one-shot session ended before the merge gate; resume it via /build (foundation #624)"}')"
      elif [ -n "$recovered_pr" ]; then
        add_action "$(jq -cn --arg b "$board" --arg r "$repo" --argjson n "$num" --arg t "$title" --arg k "$kind" --argjson pr "$recovered_pr" \
          '{phase:"drive",board:$b,repo:$r,issue:$n,title:$t,action:"drive-ready",class:"Operational",kind:$k,mode:"resume",recovered_pr:$pr,
            emit:("RESUME the in-flight merge for #"+($n|tostring)+": an OPEN PR (#"+($pr|tostring)+") already closes it. Re-attach to that PR and run /build --unattended on the existing plan note (re-check CI + run /build'"'"'s merge gate). Do NOT re-assess or open a new PR."),
            detail:("NO hand-off marker but a ground-truth open-PR probe found #"+($pr|tostring)+" closing this issue — the prior tick'"'"'s hand-off label add failed (pipeline-drive.sh #641); resuming (not re-driving) prevents a duplicate PR")}')"
      else
        # Split the fresh emit by ROUTE (#635 + #717). Three shapes:
        #  - spike          → singleton verdict path (opens NO PR); the 5b safe tier
        #                     drives it. A standalone spike is a Ready SINGLETON, not an
        #                     epic, so /assess --epic refuses it. [#635]
        #  - singleton-code → a bare Ready singleton (0 sub-issues AND no `## Contract`):
        #                     /assess --epic ALSO refuses it ("no sub-issues and no
        #                     Contract → run /triage"), so drive it via /sweep's per-issue
        #                     build path SCOPED to this one issue (worktree → worker → PR →
        #                     CI → /build's merge gate — the same per-issue mechanics /sweep
        #                     Phase 2 runs). NEVER /assess --epic; NEVER whole-pool /sweep.
        #                     [#717 — the kind:code sibling of #635]
        #  - epic           → a genuine epic (has sub-issues, or a `## Contract` body for
        #                     /assess to decompose): the /triage→/assess --epic→/build
        #                     sequence. [unchanged]
        # bare_ready_singleton fails OPEN to the epic route on any probe error, so an
        # ambiguous item keeps the current behavior (never mis-routes an epic to /sweep).
        local route="epic"
        if [ "$kind" = "spike" ]; then
          route="spike"
        elif bare_ready_singleton "$board" "$repo" "$num"; then
          route="singleton-code"
        fi
        add_action "$(jq -cn --arg b "$board" --arg r "$repo" --argjson n "$num" --arg t "$title" --arg k "$kind" --arg route "$route" \
          '{phase:"drive",board:$b,repo:$r,issue:$n,title:$t,action:"drive-ready",class:"Operational",kind:$k,mode:"fresh",route:$route,
            emit:(if $route=="spike"
                  then "claim #"+($n|tostring)+" then drive this standalone spike to its verdict directly (build.md kind:spike path for a Ready singleton — the same path /sweep uses): investigate, write the verdict note to the vault, route any follow-up issue, then close #"+($n|tostring)+" with the note linked. Do NOT run /assess --epic — a standalone spike is a singleton, not an epic, so /assess refuses it."
                  elif $route=="singleton-code"
                  then "claim #"+($n|tostring)+" then drive this bare code singleton via the /sweep per-issue build path SCOPED to #"+($n|tostring)+" ALONE (build-level.mjs: worktree → isolated worker → PR → CI → the /build merge gate — the same per-issue mechanics /sweep Phase 2 runs). It is a Ready singleton (0 sub-issues, no ## Contract), NOT an epic, so /assess --epic would refuse it. Do NOT run /assess --epic; do NOT /sweep the whole Ready pool — drive only #"+($n|tostring)+"."
                  else "claim #"+($n|tostring)+" then run: /triage --board "+$b+" → /assess --epic "+($n|tostring)+" → /build <plan> --unattended (auto-merge on green)"
                  end),
            detail:(if $route=="spike"
                    then "standalone spike = Ready singleton, not an epic; drive to a verdict note + routed follow-up via the kind:spike singleton path, never /assess --epic (#635)"
                    elif $route=="singleton-code"
                    then "bare Ready singleton (0 sub-issues, no ## Contract) — driven via the /sweep per-issue build path scoped to this issue, never /assess --epic (which refuses it) nor the whole-pool /sweep (#717, the kind:code sibling of #635)"
                    else "inherits drive-concurrency governor + quota + claim-first + epic lifecycle from the called commands (re-embeds none)"
                    end)}')"
      fi
      did_op=$((did_op+1))
    elif [ "$cls" = "Foundational" ] && [ "$did_found" -eq 0 ]; then
      # Phase C — route the Foundational design/approval gate to the queue.
      # build.md's decision-issue backend posts the gate; the scheduler names it.
      #
      # #720: a bare Foundational item (0 sub-issues AND no `## Contract`) has nothing
      # for /assess to decompose — the prep step ("epic has no sub-issues and no
      # ## Contract → run /triage") FAILS every tick and the item never reaches the
      # decision queue. Reuse the #717 bare_ready_singleton probe: a bare decision
      # routes STRAIGHT to the queue (mode:direct, skip the /assess prep); a genuine epic
      # (sub-issues or a `## Contract` body) keeps the prep-then-gate path. The probe
      # fails OPEN to the epic route on any error, so an ambiguous item keeps today's
      # prep behavior (never mis-routes an epic to the direct path).
      #
      # #977: emit `reassign_to` as a BARE login (strip the leading `@`) — it feeds an
      # `--add-assignee` call (pipeline-drive.md) and GitHub's replaceActorsForAssignable
      # cannot resolve an `@`-prefixed login (`@example-operator`). Mirrors pipeline-drive.sh's
      # `${PIPELINE_OPERATOR#@}` strip (555/633); the `@` stays in PIPELINE_OPERATOR for
      # mention text, only the assignee target is bared. The literal `@me` token is
      # PRESERVED (gh resolves it to the authenticated user; `me` alone is a non-user).
      local froute="prep"
      if bare_ready_singleton "$board" "$repo" "$num"; then froute="direct"; fi
      add_action "$(jq -cn --arg b "$board" --arg r "$repo" --argjson n "$num" --arg t "$title" --arg op "$PIPELINE_OPERATOR" --arg mode "$froute" \
        '{phase:"route",board:$b,repo:$r,issue:$n,title:$t,action:"route-foundational",class:"Foundational",mode:$mode,
          reassign_to:(if $op == "@me" then $op else ($op | ltrimstr("@")) end),
          emit:(if $mode=="direct"
                then "route #"+($n|tostring)+" STRAIGHT to the decision queue (NO /assess prep — 0 sub-issues, no ## Contract, nothing to decompose): post the design + plan-approval gate comment, apply `decision` label, assign operator, park — via build.md decision-issue backend"
                else "prep #"+($n|tostring)+" (decompose/draft via /assess) then route design + plan-approval to the decision queue: post gate comment, apply `decision` label, assign operator, park — via build.md decision-issue backend"
                end),
          detail:(if $mode=="direct"
                  then "bare Foundational decision (0 sub-issues, no ## Contract) — nothing for /assess to decompose (the prep step would fail every tick, #720); routed straight to the async decision backend"
                  else "prep-then-gate: operator-led, routed to the async decision backend (re-embeds no gate logic)"
                  end)}')"
      did_found=1
    fi
    j=$((j+1))
  done

  # A tick is a no-op only when NO phase produced an action — Phase A2 (n_clar>0
  # ⇒ a drain / already-applied / contention was emitted) counts too, mirroring how
  # n_dec gates the decision drain. Without the n_clar term, a drain-only tick would
  # append a contradicting "no drivable work" record. Phase R (did_retro) joins the
  # same guard: a retro-judge/skip-retro-judge-only tick must not ALSO claim no-op.
  if [ "$did_op" -eq 0 ] && [ "$did_found" -eq 0 ] && [ "$did_route" -eq 0 ] && [ "$n_dec" -eq 0 ] && [ "$n_clar" -eq 0 ] && [ "$did_retro" -eq 0 ]; then
    add_action "$(jq -cn --arg b "$board" --arg r "$repo" \
      '{phase:"tick",board:$b,repo:$r,action:"no-op",detail:"no answered decisions/clarifications and no drivable Ready work this tick"}')"
  fi
}

# ── Main loop: enabled boards (or the one --board, if it is enabled) ─────────
BOARDS_TO_RUN=""
if [ -n "$ONE_BOARD" ]; then
  if board_enabled "$ONE_BOARD"; then
    BOARDS_TO_RUN="$ONE_BOARD"
  else
    # An explicit --board that is OFF: emit a disabled record, do nothing.
    jq -cn --arg b "$ONE_BOARD" \
      '{tick:"done",actions:[{phase:"tick",board:$b,action:"board-disabled",
        detail:"board not in PIPELINE_ENABLED_BOARDS — driver OFF for it (pilot = stageFind only)"}]}'
    exit 0
  fi
else
  BOARDS_TO_RUN="$PIPELINE_ENABLED_BOARDS"
fi

for b in $BOARDS_TO_RUN; do
  tick_board "$b"
done

jq -cn --argjson actions "$ACTIONS" --argjson dry "$DRY_RUN" \
  '{tick:"done", dry_run:($dry==1), actions:$actions}'
