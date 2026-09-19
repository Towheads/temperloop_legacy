#!/usr/bin/env bash
# description: bootstrap .temperloop/config; propose tree changes via PR; offer the pre-designed first epic; print the handoff
#
# init.sh — `temperloop init`: opt-in, reviewable adoption (foundation #765
# Epic D "newcomer experience", item foundation-init / #854).
#
# SCOPE (temperloop#796 — the init scope-down): bootstrap
# `.temperloop/config` (and its proposal PR) -> offer/file the first epic ->
# print the handoff -> STOP. Every *apply* of API STATE this script used to
# perform under its own consent prompt — a required `checks` status check,
# the `fnd:`/pipeline label set, a Projects-v2 board — now belongs to the
# FIRST EPIC's own `## Contract`
# (claude/templates/first-epic-setup.md, ADR 0010), applied later by
# `/assess --epic N` -> `/build`. See "DEPRECATED FLAGS" below: the flags
# that used to gate those applies still parse, and now emit a deprecation
# notice naming where the step went instead of doing anything.
#
# Thin wiring over three landed seams — this script is their ONLY call
# site, it adds no parallel logic of its own:
#   1. the conventions probe (workflows/scripts/probe/conventions-probe.sh,
#      contract: workflows/scripts/lib/conventions_probe.contract.md,
#      schema 1) — read-only detection of the target repo's conventions.
#   2. the proposal-PR generator (workflows/scripts/proposal/proposal-pr.sh)
#      — the ONLY path by which this script ever writes to the target
#      repo's TREE. Every tree change (`.temperloop/config`, an optional
#      `workflows/scripts/board/boards.conf` entry) rides a reviewable PR;
#      nothing is ever committed straight to the default branch.
#   3. the FIRST-EPIC OFFER, owned by this script — the ONE consented
#      action that remains, and the handoff into the real pipeline. It
#      files an issue (never API state); --dry-run, --no-network, an absent
#      `gh`, or a decline performs zero mutating `gh` calls beyond the
#      decline path's own tracked re-offer pointer.
#
# WHY THE APPLIES MOVED (temperloop#793/#796, ADR 0010 amendment). Two
# reasons, both structural rather than stylistic:
#   - CONGRUENCE. This script's required-check apply was an unconditional
#     `PATCH .../protection/required_status_checks` — it armed a required
#     `checks` context with no regard for whether anything would ever POST
#     that context. The first epic refuses exactly that (ADR 0010
#     § "Structural congruence, not a naming convention"): the required
#     status enters the composed change-set only when its producer was
#     actually configured, so the self-brick failure mode is unreachable
#     rather than merely untested.
#   - REDUNDANCY. The `fnd:`/pipeline label set is created lazily at point
#     of use by the issues-only tracker backend itself
#     (`_board_issues_ensure_label`, workflows/scripts/board/lib/board.sh),
#     memoized per process — pre-creating it here bought nothing and cost
#     six API writes on a first run.
#   - A DANGLING CONTRACT. The board arm rendered
#     `# board.<N>.project=<FILL IN ...>` into boards.conf BEFORE the apply
#     step and never reassigned it, so even a fully-consented, successful
#     provisioning run emitted a placeholder the adapter cannot read.
#     Issues-only is now the SOLE tracker backend, not merely the sole
#     init-time default: the Projects-v2 arm was removed outright (ADR
#     0004, epic #524). There is NO configuration path back to Projects-v2
#     — an adopter who wants it forks board.sh (docs/features/
#     install-cli.md § Tracker mode).
#
# DEPRECATED FLAGS (retained, each with a NAMED removal window).
# `--yes/--no-required-check`, `--yes/--no-labels`, and `--yes/--no-board`
# still PARSE and still exit 0 — they emit a one-line deprecation notice
# naming where the step went, then are ignored.
#
# WHY THEY ARE RETAINED. NOT because of the in-repo call sites: those are
# all greppable, and the very change that deprecated these flags rewrote
# .github/workflows/install-tier2.yml to stop passing them — a site this
# repo can edit is not a breakage argument. The real reason is
# VERSIONING.md's **CLI surface** contract row, which names
# `bin/subcommands/*` and "callers of `bin/temperloop` and its
# subcommands": an ADOPTER's own wrapper script, Makefile, or CI job may
# pass any of these, and this script exits 2 on an unknown arg, so a
# removal would hard-fail callers that cannot be enumerated from inside
# this repo. Deprecate-then-remove-on-a-named-release is the contract that
# row implies.
#
# ONE WINDOW REMAINS OPEN — THE PRE-SCOPE-DOWN COMPAT WINDOW (v0.20.0) —
# the three CONSENT pairs `--yes/--no-required-check`, `--yes/--no-labels`,
# and `--yes/--no-board`. These gated a branch-protection PATCH and a label
# loop that existed on the ISSUES-ONLY path too, so they were never in
# scope for the ADR-0004 Projects-arm removal below. They are removed
# instead at **v0.20.0**, together with `eject.sh`'s pre-scope-down
# `required_check`/`label`/`board` read-compat handlers — ONE window,
# because both halves serve the same cohort: a repo initialised BEFORE
# the temperloop#796 scope-down, whose `.temperloop/config` may still
# record that API state and whose wrapper scripts may still pass these
# flags. Neither half can go while that cohort is still supported, and
# neither has a reason to outlive it.
#
# REMOVED FLAGS — the `--provision-*` board-provisioning flag and
# `--tracker-mode` (temperloop#524, epic "retire the Projects-v2/GraphQL
# arm"). THE ADR-0004 PROJECTS-ARM REMOVAL these two were always scoped to
# (docs/adr/0004-issues-only-default-backend.md) has now arrived: ten
# releases have passed since issues-only became the default, and every
# registered board has run issues-only since 2026-07-18. Both flags are
# GONE outright — they no longer parse. Each now hits a dedicated case arm
# below that exits 2 with a message naming the removal (never the generic
# "unknown arg" text), so an adopter whose script still passes one learns
# *why*, not just that it broke. `--tracker-mode` is removed in full, not
# reduced to a single accepted value: with the Projects-v2 value gone, an
# `issues`-only accepted value would be dead surface wearing a flag's
# clothing. (The board-provisioning flag is matched by its `--provision-*`
# PREFIX rather than a single exact spelling, so the whole retired family
# — not just its one historic name, still spelled out in bin/README.md's
# compat table — is caught the same way.)
#
# The affirmative forms (`--yes-*`, which REQUEST an action that no longer
# happens) still warn-and-continue rather than exiting non-zero. That is a
# deliberate, reversible call, consistent with this script's fail-open
# posture everywhere else: an adopter's unattended job should not start
# failing because of a flag whose action was retired as redundant. Revisit
# it at the v0.20.0 removal, not before.
#
# `temperloop init` is the SOLE WRITER of `.temperloop/config` — no other
# subcommand (this repo's `eject`, once it lands, only READS it) ever
# creates or edits that file. Every API-STATE side effect this script
# produces (a label, a required-check setting, a proposal branch/PR, a
# board) is recorded in `.temperloop/config`'s `installs` array — the exact
# set `temperloop eject` reverts via `gh`. Re-running this script MERGES
# into that array rather than clobbering it (see "round-trip" below), and an
# install already recorded from a prior run (or already present on the
# remote, e.g. a label that already existed) is never re-recorded or
# re-applied. TREE artifacts are the other half of that split and do NOT
# enter `installs[]`: a file this script proposes rides the FILES MANIFEST
# and is reverted by the tree, not by an API call — the split `eject.sh`'s
# own header defends. `.temperloop/config` itself and the `tokens` producer
# shim below are both tree artifacts in exactly that sense.
#
# TRACKER MODE is a THIN RENDER, not a second config store: the functional
# artifact the board adapter (workflows/scripts/board/lib/board.sh) reads
# is `boards.conf`, in its own documented format and discovery path — see
# `workflows/scripts/board/boards.conf.example`. This script only RENDERS
# the `board.<N>.*` lines and, when the target repo has already adopted the
# board toolkit (a `workflows/scripts/board/` dir exists), proposes
# appending them to that repo's `boards.conf` via the SAME proposal-PR
# generator (still tree-only, still reviewable). When the toolkit isn't
# present yet, the rendered entry is only recorded in `.temperloop/config`
# (`tracker.boards_conf_entry`) for the operator to apply by hand later —
# `.temperloop/config` itself is NEVER read by the adapter, so there is no
# risk of two config stores disagreeing. Issues-only
# (`board.<N>.backend=issues`) is now the SOLE init-time tracker mode
# (temperloop#793), and the rendered entry is always COMPLETE — every line
# is a real, adapter-readable assignment, never a commented placeholder the
# adapter's `^board\.N\.axis=` grep would silently fall through.
#
# BOOTSTRAP ORDERING NOTE (a known, accepted limitation): the proposal PR
# this script opens carries `.temperloop/config`'s content as committed
# BEFORE that PR's own outcome (its branch/PR number) is known — a
# PR can't describe itself before it exists. This script resolves it with
# a second pass: once the first `proposal-pr.sh open` call returns
# PR_OPENED/EXISTS, it folds a `{"type":"proposal_pr",...}` install entry
# for THIS run into `.temperloop/config` and calls the SAME generator a
# second time (same branch, --force) so the version that actually lands
# is self-describing. A --dry-run or NO_CHANGES first pass skips this
# second pass — there is no PR yet to describe.
#
# Epic E soft seam (baseline-snapshot): 'present' is decided purely by
# kernel/bin/subcommands/baseline-snapshot.sh existing next to this file —
# the dispatcher's own file-discovery mechanism IS the capability probe,
# so this script never hand-maintains a second "is it there" check. The
# invocation contract is one line: no args, exit 0 = snapshot written.
# Absent -> "skipped — baseline-snapshot unavailable", and init continues
# either way; this is a soft seam that never blocks init.
#
# FIRST-EPIC OFFER (temperloop#610, ADR 0010, item first-epic-offer): since
# the scope-down (temperloop#796) this is the WHOLE of Step 2 — the one
# consented action this script performs, gated behind the same
# gh_repo/gh-binary/dry-run/no-network preconditions the retired
# required-check/labels/board applies used. Consumes the kernel-shipped
# template (claude/templates/first-epic-setup.md) as pure data — this
# script never restates its content, only extracts and substitutes
# <project>.
#   - IDEMPOTENT: probes issue BODIES (never titles) in the adopter's repo
#     for a design-brief marker (accept already happened) or a decline
#     marker (decline already happened + its re-offer pointer was filed)
#     before ever offering — a re-run of this script neither re-files the
#     epic nor re-nags after a decline. The probe is THREE-VALUED
#     (temperloop#1444): already-filed / not-filed / UNKNOWN. Its queries
#     carry the now-mandatory `is:issue` qualifier, and its result is
#     validated digits-only before it is ever treated as an issue number —
#     `gh` prints its error body to STDOUT, so an unvalidated fail-open let
#     a 422 blob read as "already filed as #<blob>". A probe that cannot
#     answer degrades to UNKNOWN, which WITHHOLDS the offer with a legible
#     notice; it never claims the epic is already filed.
#   - Skip vs. decline are DELIBERATELY DISTINCT outcomes. A non-interactive
#     run (no TTY, or a CI/GITHUB_ACTIONS ambient signal, and no
#     --yes-first-epic/--no-first-epic preset) SKIPS with a plain notice —
#     nobody actually answered, so nothing beyond the notice happens. Only
#     an ACTUAL "no" (typed at a real prompt, or an explicit
#     --no-first-epic) triggers the decline floor below. A decline should
#     leave a durable, tracked trace, which a merely-unattended run has no
#     standing to create on the adopter's behalf.
#   - DECLINE FLOOR (never a vanished gap) — ONE floor, not two, since the
#     scope-down (temperloop#796; ADR 0010's "Decline floors are durable"
#     clause as amended): declining the epic files a durable re-offer
#     pointer (a plain GitHub issue, `fnd:status:backlog` labelled) in the
#     ADOPTER's OWN repo naming exactly what remains unconfigured (branch
#     protection, auto-delete, merge-queue disposition, CI disposition), so
#     the gap stays tracked rather than vanishing. That pointer IS the whole
#     floor. The principles interview no longer runs INLINE here: it is the
#     first epic's own L0 item (`record-principles`, template § Contract),
#     so declining the epic DEFERS the interview rather than running a
#     second, parallel copy of it from this script — and the kernel default
#     (claude/engineering-principles.md) still applies at every review call
#     site's point of use regardless, so declining costs the adopter only
#     the *recorded* choice, never the criteria themselves. The GitHub/CI
#     Phase A/B/C interview likewise only makes sense once the epic exists,
#     and is driven later by /assess --epic N -> /build; this script's job
#     ends at the offer + (on decline) the pointer + the handoff line.
#
# PARTIAL-RUN RECOVERY (temperloop#414): a run that dies anywhere from Step
# 3's proposal-pr.sh call onward (killed process, failed push, failed `gh pr
# create`) leaves the checkout on the proposal branch with no memory of what
# branch it came from. This script writes an untracked `.temperloop/.recovery.json`
# ({"original_branch":...,"proposal_branch":...}) immediately before that
# call and deletes it immediately after the call succeeds (whatever the
# outcome) — so the marker survives on disk exactly when, and only when, a
# run was interrupted mid-switch. `temperloop eject` (kernel/bin/subcommands/
# eject.sh) is the reader: it restores `original_branch` and deletes the
# stray `proposal_branch` when it finds the marker and the checkout is still
# sitting on that branch. A run whose HEAD is detached, or that never
# switches branch (already on it), writes no marker — nothing to restore.
#
# TOKENS PRODUCER SHIM (temperloop#984). `temperloop report`'s headline
# metric — tokens spent vs items merged — comes from a DROP-IN PRODUCER the
# target repo carries at `.temperloop/report.d/tokens`
# (workflows/scripts/lib/report.contract.md § "Overlay drop-in contract").
# Nothing placed that file before this item, so the headline was silently
# unavailable in every repo except this kernel checkout itself; Step 4 now
# adds it to the SAME files manifest `.temperloop/config` already rides.
# Four properties, each load-bearing:
#   - MANIFEST, NOT `installs[]`. A tree artifact is reverted by the tree;
#     `installs[]` is the API-state set `eject` reverts via `gh`. See the
#     sole-writer note above and eject.sh's own header for that split.
#   - MODE 755, because the contract EXECs producers rather than sourcing
#     them; a 644 producer renders as "skipped -- tokens: producer
#     unavailable" and the headline silently degrades. proposal-pr.sh
#     validates the per-entry mode (644|755) itself, so nothing here has to.
#   - NEVER OVERWRITTEN AND NEVER DROPPED, and never prompted about. `init`
#     stays entirely non-interactive on this path: a producer already at
#     that path belongs to the adopter (hand-written, or edited after an
#     earlier `init`), and silently clobbering it would destroy work with no
#     undo — while silently OMITTING it deletes that same work just as
#     surely, because the proposal branch is re-cut off base every run. Both
#     directions are governed by the three-rule base-tip decision documented
#     at "THE BASE TIP" below, which the boards.conf step shares.
#   - COPIED VERBATIM from this kernel checkout's own shim, pure data
#     extraction exactly like the first-epic template — this script never
#     restates the shim's resolver logic, so there is no second copy to
#     drift. The shim is a thin locator that finds an installed kernel and
#     `exec`s the real implementation at
#     workflows/scripts/report-producers/tokens, which is why copying it
#     into an adopter's tree does NOT freeze the implementation the way
#     copying the producer itself once did (temperloop#980).
# A missing shim is a SOFT SEAM, same posture as the baseline-snapshot step:
# it reports a legible skip and `init` continues. An unplaceable report
# headline is never worth failing an adopter's bootstrap over.
#
# DUAL-BUILD PRODUCER SHIM (temperloop#2084, epic #2065). Same placement
# rules, same manifest treatment, same soft-seam skip as the TOKENS shim
# just above — this note only says what's DIFFERENT. Unlike model-
# comparison (ADR 0027, no shim shipped at all — deliberately inert), the
# dual-build report producer IS wired here, unconditionally, exactly like
# `tokens`: a repo that never runs `/build --dual-build` carries an empty
# ledger, and workflows/scripts/report-producers/dual-build degrades to one
# `skipped -- ` line for that repo — the same "no standing cost when
# unused" property that lets `tokens` be wired unconditionally too. The
# shim finds an installed kernel and `exec`s
# workflows/scripts/report-producers/dual-build, which reads the
# `.temperloop/model-comparison/dual-build/` ledger (gitignored, per-repo,
# already outside this manifest's own tree).
#
# Usage:
#   init.sh [--dir DIR] [--gh-repo OWNER/REPO] [--no-network] [--timeout SECS]
#           [--branch NAME] [--base BRANCH] [--remote NAME]
#           [--board N]
#           [--yes-first-epic | --no-first-epic]
#           [--dry-run]
#
#   Deprecated, still accepted, ignored (see "DEPRECATED FLAGS" above):
#           [--yes-required-check | --no-required-check]
#           [--yes-labels | --no-labels]
#           [--yes-board | --no-board]
#
#   Removed — no longer parse; each exits 2 naming the removal release
#   (see "REMOVED FLAGS" above): --tracker-mode, --provision-*
#
#   --dir DIR             Git checkout to initialize. Default: current dir.
#   --gh-repo OWNER/REPO  Forwarded to the probe; also the repo this
#                          script's own `gh` calls target. Default:
#                          inferred by the probe from the origin remote.
#   --no-network           Forwarded to the probe; ALSO forces every
#                          consented-apply action to skip (no gh_repo
#                          resolution is trustworthy offline) AND skips
#                          every step of this script that itself reaches
#                          the network — the base-tip fetch and the Step 3
#                          proposal PR (no branch, no commit, no push, no
#                          PR), each with a `skipped — network disabled`
#                          notice. The run still completes and still prints
#                          the Step 4/5 summary + handoff (temperloop#969).
#   --timeout SECS         Forwarded to the probe. Default: 10.
#   --branch NAME           Proposal branch name. Default:
#                          "foundation-init/config" — a single stable,
#                          re-usable branch: re-running this script force-
#                          updates the same open PR rather than opening a
#                          new one each time.
#   --base BRANCH          Forwarded to the proposal generator. Default:
#                          the target repo's own default branch.
#   --remote NAME           Forwarded to the proposal generator. Default: origin.
#   --board N               Board id the rendered boards.conf
#                          entry uses. Default: carried forward from an
#                          existing .temperloop/config, else 1.
#   --yes-first-epic / --no-first-epic
#                          Pre-answer the first-epic offer instead of an
#                          interactive prompt. A non-interactive run with
#                          NEITHER flag SKIPS the offer entirely (never
#                          asks, never silently declines) — see "FIRST-EPIC
#                          OFFER" above for why a silent skip and an
#                          explicit decline are kept distinct.
#   --dry-run               Forwarded to the proposal generator (local
#                          commit only, nothing pushed, no PR opened) AND
#                          skips the first-epic offer entirely (zero gh
#                          mutation calls of any kind).
#
#   Removed (no longer parse — each exits 2 naming the removal release,
#   rather than the generic "unknown arg" error; see "REMOVED FLAGS" above):
#   --tracker-mode MODE     Used to be "issues" (the only mode this script
#                          ever wrote) or "projects". With the Projects-v2
#                          arm gone there is nothing left to select, and no
#                          configuration path back — see
#                          docs/features/install-cli.md § Tracker mode.
#                          [removed: the Projects-v2 removal release
#                          (ADR 0004, epic #524)]
#   --provision-*            Formerly a legible no-op (its one historic
#                          spelling is still on record in bin/README.md's
#                          compat table). A Projects-v2 board is never
#                          provisioned by `init`, and cannot be provisioned
#                          by hand either — the adapter has no Projects
#                          code path left to reach. See
#                          docs/features/install-cli.md § Tracker mode.
#                          [removed: the Projects-v2 removal release
#                          (ADR 0004, epic #524)]
#
#   Deprecated (parsed, reported, then ignored — each with a named removal
#   window; see "DEPRECATED FLAGS" above for the windows and why removing
#   one early would break un-greppable adopter callers):
#   --yes-required-check / --no-required-check
#   --yes-labels / --no-labels
#   --yes-board / --no-board
#                          Legible no-ops. The required `checks` status
#                          check moved to the first epic; the `fnd:`/
#                          pipeline labels are created lazily at point of
#                          use by the issues-only tracker backend; board
#                          provisioning was dropped outright.
#                          [removed: v0.20.0, the pre-scope-down compat
#                          window — see "DEPRECATED FLAGS" above]
#
# Exit codes: 0 = ran to completion (even if every apply action was
# declined — that is a legible, successful run, not a failure). 1 = fatal
# usage/environment error (bad --dir, probe/generator missing or failing).
# 2 = invalid CLI usage.
#
# Dependencies: bash (3.2+), git, jq (hard requirements, mirroring the
# probe and generator this script wraps). `gh` is optional — its absence
# degrades only the consented-apply step (every action reports "skipped").
#
# shellcheck shell=bash

set -uo pipefail

# ---------------------------------------------------------------------------
# Locate sibling kernel content — same pinned-physical-path idiom as
# eject.sh / testbed.sh (see those scripts' own header comments).
# ---------------------------------------------------------------------------
SUBCOMMAND_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$(cd "$SUBCOMMAND_DIR/.." && pwd)"
KERNEL_ROOT="$(cd "$BIN_DIR/.." && pwd)"
PROBE="$KERNEL_ROOT/workflows/scripts/probe/conventions-probe.sh"
PROPOSAL="$KERNEL_ROOT/workflows/scripts/proposal/proposal-pr.sh"
BASELINE_SNAPSHOT="$SUBCOMMAND_DIR/baseline-snapshot.sh"
# The `tokens` drop-in producer's LOCATOR SHIM, copied verbatim into an
# adopter's tree by Step 4's files manifest (see the "TOKENS PRODUCER SHIM"
# header note). This kernel checkout's own copy is the canonical one —
# claimed by workflows/scripts/kernel/kernel-manifest.txt and
# docs/features/feature-manifest.txt — so there is no second copy to drift.
PRODUCER_SHIM="$KERNEL_ROOT/.temperloop/report.d/tokens"
# The `dual-build` drop-in producer's LOCATOR SHIM (temperloop#2084, epic
# #2065), wired the same way as PRODUCER_SHIM above — see the "DUAL-BUILD
# PRODUCER SHIM" note below for why this one is unconditionally wired too
# rather than shipped inert (ADR 0027's model-comparison treatment).
DUAL_BUILD_PRODUCER_SHIM="$KERNEL_ROOT/.temperloop/report.d/dual-build"

if [ ! -f "$PROBE" ]; then
  echo "init.sh: conventions-probe.sh not found at $PROBE (broken kernel checkout)" >&2
  exit 1
fi
if [ ! -f "$PROPOSAL" ]; then
  echo "init.sh: proposal-pr.sh not found at $PROPOSAL (broken kernel checkout)" >&2
  exit 1
fi

command -v jq >/dev/null 2>&1 || { echo "init.sh: jq not found on PATH" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "init.sh: git not found on PATH" >&2; exit 1; }

# Test-double seam (mirrors eject.sh's EJECT_GH_BIN / pipeline-drive.sh's
# PIPELINE_GH_BIN convention) — never overridden in production use.
: "${INIT_GH_BIN:=gh}"

usage() {
  cat <<'EOF'
usage: init.sh [--dir DIR] [--gh-repo OWNER/REPO] [--no-network] [--timeout SECS]
               [--branch NAME] [--base BRANCH] [--remote NAME]
               [--board N]
               [--yes-first-epic | --no-first-epic]
               [--dry-run]

deprecated (still accepted, reported, then ignored):
               [--yes-required-check | --no-required-check]
               [--yes-labels | --no-labels]
               [--yes-board | --no-board]

removed (no longer parse; each exits 2 naming the removal release):
               --tracker-mode, --provision-*
EOF
}

# ---------------------------------------------------------------------------
# CLI parsing
# ---------------------------------------------------------------------------
init_dir="."
gh_repo_flag=""
no_network=0
init_timeout=10
branch="foundation-init/config"
base=""
remote="origin"
# Fixed, no longer CLI-settable — issues-only is the sole tracker mode
# `init` has ever written (temperloop#793), and the Projects-v2 arm that
# made this a real choice is gone (temperloop#524, ADR 0004). Kept as an
# internal value because build_config_json()/the Summary still render it.
tracker_mode="issues"
board_num=""
consent_required_check=""
consent_labels=""
consent_board=""
consent_first_epic=""
dry_run=0

# Named removal release for the two flags below — no version number is cut
# yet (CHANGELOG.md's `## [Unreleased]` section), so this names the epic +
# ADR per this item's own acceptance criteria, same wording as the
# "REMOVED FLAGS" header note above and bin/README.md's compat table.
removed_window_projects="the Projects-v2 removal release (ADR 0004, epic #524)"

while [ $# -gt 0 ]; do
  case "$1" in
    --dir) init_dir="${2:?--dir needs a value}"; shift 2 ;;
    --gh-repo) gh_repo_flag="${2:?--gh-repo needs a value}"; shift 2 ;;
    --no-network) no_network=1; shift ;;
    --timeout) init_timeout="${2:?--timeout needs a value}"; shift 2 ;;
    --branch) branch="${2:?--branch needs a value}"; shift 2 ;;
    --base) base="${2:?--base needs a value}"; shift 2 ;;
    --remote) remote="${2:?--remote needs a value}"; shift 2 ;;
    --tracker-mode)
      echo "init.sh: --tracker-mode was removed in $removed_window_projects — issues-only is now the only tracker backend \`init\` has ever written, so there is nothing left to select. There is NO configuration path back to Projects-v2; an adopter who wants it forks board.sh. See docs/features/install-cli.md § Tracker mode." >&2
      usage >&2
      exit 2
      ;;
    --board) board_num="${2:?--board needs a value}"; shift 2 ;;
    --provision-*)
      # Matched by PREFIX, not one exact spelling (its historic name is on
      # record in bin/README.md's compat table) — the whole retired
      # board-provisioning flag family hits this arm, and `$1` echoes back
      # exactly what the caller typed.
      echo "init.sh: '$1' was removed in $removed_window_projects — a Projects-v2 board is never provisioned by \`init\`, and cannot be provisioned by hand either: the adapter has no Projects code path left to reach. See docs/features/install-cli.md § Tracker mode." >&2
      usage >&2
      exit 2
      ;;
    --yes-required-check) consent_required_check=yes; shift ;;
    --no-required-check) consent_required_check=no; shift ;;
    --yes-labels) consent_labels=yes; shift ;;
    --no-labels) consent_labels=no; shift ;;
    --yes-board) consent_board=yes; shift ;;
    --no-board) consent_board=no; shift ;;
    --yes-first-epic) consent_first_epic=yes; shift ;;
    --no-first-epic) consent_first_epic=no; shift ;;
    --dry-run) dry_run=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "init.sh: unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# ---------------------------------------------------------------------------
# VALIDATE BEFORE ACTING — `--remote`, the sibling of the `--base` guard
# further down (see "VALIDATE BEFORE ACTING" near init_default_branch).
#
# `--remote` parses as a bare `remote="${2:?…}"` and is then spliced straight
# into `git fetch "$remote" "$base"` as that command's FIRST POSITIONAL — the
# position git parses as an option whenever the word begins with `-`. So a
# value like `--upload-pack=touch /tmp/PWNED; git-upload-pack` EXECUTES at the
# fetch, exactly the injection the `--base` guard closed on the other argument
# of the same call. Downstream refusal is not a guard: proposal-pr.sh
# validates the remote it is handed, but only AFTER this script's own fetch
# has already run it.
#
# This is documented CLI surface (VERSIONING.md's CLI-surface row) that
# adopter wrapper scripts and CI jobs pass, so the value is not always a
# human's own keystroke. Unlike `--base` — which may be empty here and is only
# resolved once init_default_branch has run — `--remote` always holds its
# final value the instant parsing ends, so it is validated HERE, at parse
# time, strictly before the first git invocation that consumes it. One guard
# then covers init_default_branch's symbolic-ref/show-ref probes, the fetch,
# the base-ref show-refs, and the value forwarded to proposal-pr.sh.
case "$remote" in
  -*)
    echo "init.sh: --remote '$remote' must not begin with '-' (git would read it as an option, not a remote)" >&2
    exit 2
    ;;
esac
if ! git check-ref-format "refs/remotes/$remote/HEAD" 2>/dev/null; then
  echo "init.sh: --remote '$remote' is not a valid git remote name" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# DEPRECATED-FLAG NOTICES (temperloop#796 — the init scope-down).
#
# Every flag below still PARSES (removing one would hard-fail the six
# consumer sites the instant it landed — this script exits 2 on an unknown
# arg — and would make an otherwise-safe release BREAKING). What each one
# now does is: print ONE line naming where the step actually went, then get
# ignored. The notices go to stderr so they can't be mistaken for the
# step's own structured stdout, and they deliberately avoid the
# "skipped — " / "FAILED" wording that .github/workflows/install-tier2.yml
# content-scans for: a deprecated flag is neither a degraded step nor a
# failure, and must not turn the tier-2 round trip red.
# ---------------------------------------------------------------------------
_init_deprecated() {
  # _init_deprecated <flag> <removal-window> <where-it-went>
  #
  # The removal window is named on the line an adopter actually sees, not
  # only in this file's header — a deprecation notice with no stated exit
  # condition is indistinguishable from a permanent no-op.
  echo "init.sh: DEPRECATED — $1 is accepted but ignored (removed in $2): $3" >&2
}

# The one remaining named removal window — see "DEPRECATED FLAGS" in the
# header. (The ADR-0004 Projects-arm removal window this used to share with
# the board-provisioning flag family and --tracker-mode is gone: those two
# no longer parse at all — see "REMOVED FLAGS" — so there is nothing left
# to defer to it.)
deprecated_window_consent="v0.20.0, the pre-scope-down compat window"

deprecated_moved_required_check="the required \`checks\` status check is now applied by the first epic (claude/templates/first-epic-setup.md § Contract, item \`github-substrate\`; ADR 0010 § \"Structural congruence\"), which — unlike this step — refuses to arm a required status no producer will ever post. Run it via /assess --epic N -> /build."
deprecated_moved_labels="the \`fnd:\`/pipeline label set is created lazily at point of use by the issues-only tracker backend itself (\`_board_issues_ensure_label\`, workflows/scripts/board/lib/board.sh) — there is nothing left to pre-create."
deprecated_moved_board="board provisioning was dropped from \`init\` outright (temperloop#793); issues-only is the sole tracker backend, and the Projects-v2 arm was removed outright (ADR 0004, epic #524). There is no configuration path back — see docs/features/install-cli.md § Tracker mode."

[ -n "$consent_required_check" ] \
  && _init_deprecated "--${consent_required_check}-required-check" \
       "$deprecated_window_consent" "$deprecated_moved_required_check"
[ -n "$consent_labels" ] \
  && _init_deprecated "--${consent_labels}-labels" \
       "$deprecated_window_consent" "$deprecated_moved_labels"
[ -n "$consent_board" ] \
  && _init_deprecated "--${consent_board}-board" \
       "$deprecated_window_consent" "$deprecated_moved_board"

# --- resolve --dir to a git toplevel (mirrors proposal-pr.sh's own
# resolve_repo_dir, so both scripts agree on what "the repo" means) -------
abs_dir() { (cd "$1" 2>/dev/null && pwd -P); }
repo_dir="$(abs_dir "$init_dir")" || { echo "init.sh: --dir '$init_dir' does not exist" >&2; exit 1; }
repo_top="$(git -C "$repo_dir" rev-parse --show-toplevel 2>/dev/null)" \
  || { echo "init.sh: --dir '$init_dir' is not a git working tree" >&2; exit 1; }
repo_dir="$(abs_dir "$repo_top")"

# Capture the caller's branch BEFORE anything below ever switches it (only
# Step 3's proposal-pr.sh call does that, via `git checkout -B`) — this is
# the "original branch" a partial/failed run needs to restore later (see
# the recovery-marker note ahead of that call, and temperloop#414).  Empty
# when HEAD is detached; the marker is then never written (nothing named
# to restore to).
orig_branch="$(git -C "$repo_dir" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"

echo "== temperloop init =="
echo

# ---------------------------------------------------------------------------
# Step 0 — Epic E soft seam: baseline snapshot, iff the sibling subcommand
# file exists. Never blocks init either way.
#
# --dry-run GATE (temperloop#413): baseline-snapshot.sh is a real writer —
# it appends to .temperloop/baseline.jsonl and self-manages
# .temperloop/.gitignore, both straight to disk, with no proposal-PR/commit
# indirection of its own. A dry run must be genuinely zero-write (bin/
# README.md bills it as "preview first: tree-only, zero API writes"), so
# this step is skipped outright on --dry-run — never invoked, not even in
# some "preview" mode of its own (it has none).
# ---------------------------------------------------------------------------
echo "-- 0. Baseline snapshot (Epic E soft seam) --"
if [ "$dry_run" -eq 1 ]; then
  echo "skipped (--dry-run — tree-only preview, no baseline write)"
elif [ -f "$BASELINE_SNAPSHOT" ]; then
  if (cd "$repo_dir" && bash "$BASELINE_SNAPSHOT"); then
    echo "baseline snapshot written"
  else
    echo "baseline-snapshot.sh exited non-zero — continuing (soft seam, never blocks init)"
  fi
else
  echo "skipped — baseline-snapshot unavailable"
fi
echo

# ---------------------------------------------------------------------------
# Step 1 — the conventions probe (read-only). Forward every flag it
# understands; this script adds no probe behavior of its own.
# ---------------------------------------------------------------------------
echo "-- 1. Conventions probe (read-only) --"
probe_args=(--dir "$repo_dir" --timeout "$init_timeout")
[ -n "$gh_repo_flag" ] && probe_args+=(--gh-repo "$gh_repo_flag")
[ "$no_network" -eq 1 ] && probe_args+=(--no-network)

probe_json="$(bash "$PROBE" "${probe_args[@]}")"
probe_rc=$?
if [ "$probe_rc" -ne 0 ]; then
  echo "init.sh: conventions-probe failed (exit $probe_rc)" >&2
  exit "$probe_rc"
fi
echo "$probe_json" | jq -c '{schema, repo, ci: .ci.providers}'

probe_schema="$(jq -r '.schema' <<<"$probe_json")"
if [ "$probe_schema" != "1" ]; then
  echo "init.sh: warning — probe schema is $probe_schema; this script understands schema 1 — proceeding best-effort" >&2
fi

gh_repo="$(jq -r '.repo.gh_repo // empty' <<<"$probe_json")"
if [ -z "$gh_repo" ]; then
  echo "init.sh: could not determine a GitHub owner/repo (no --gh-repo, no github.com origin remote) — the first-epic offer will skip" >&2
fi
echo

# ---------------------------------------------------------------------------
# Step 2 — read any existing .temperloop/config: the round-trip half of
# the persisted contract (probe -> config -> init re-reads it). A prior
# run's install manifest is carried forward (merged, never clobbered); an
# unreadable/wrong-schema file is treated as absent, with a warning, so a
# corrupt config can't wedge every future run.
# ---------------------------------------------------------------------------
config_rel=".temperloop/config"
config_path="$repo_dir/$config_rel"
# temperloop#165: a pre-v0.15.0 init wrote .foundation/config. That legacy
# READ was supported through the v0.15.0 -> v0.19.0 window and is now GONE
# — but the legacy file is still DETECTED, and the detection is the
# load-bearing half: silently ignoring it would restart from a fresh install
# manifest on top of forgotten legacy state, re-applying steps the target
# repo already carries. Refuse legibly instead, naming the migration.
# `temperloop eject` still cleans either dir.
legacy_config_rel=".foundation/config"
read_config_rel="$config_rel"
read_config_path="$config_path"
if [ ! -f "$config_path" ] && [ -f "$repo_dir/$legacy_config_rel" ]; then
  echo "init.sh: ERROR — found legacy $legacy_config_rel, whose read support was removed in v0.19.0 (the config renamed to .temperloop/config in v0.15.0). Rename the directory (git mv .foundation .temperloop) or run 'temperloop eject' with a pre-v0.19.0 release, then re-run init." >&2
  exit 1
fi
existing_config=""
existing_installs="[]"
if [ -f "$read_config_path" ]; then
  if existing_config="$(jq -e '.' "$read_config_path" 2>/dev/null)" \
      && [ "$(jq -r '.schema // empty' <<<"$existing_config")" = "1" ]; then
    existing_installs="$(jq -c '.installs // []' <<<"$existing_config")"
    echo "-- Found existing $read_config_rel (schema 1) — merging its install manifest ($(jq 'length' <<<"$existing_installs") entries) --"
  else
    echo "init.sh: warning — existing $read_config_rel is not valid schema-1 JSON; starting a fresh install manifest" >&2
    existing_config=""
  fi
  echo
fi

# --- tracker mode + board number (carried forward unless overridden) -----
if [ -z "$board_num" ] && [ -n "$existing_config" ]; then
  prior_board="$(jq -r '.tracker.board // empty' <<<"$existing_config")"
  [ -n "$prior_board" ] && board_num="$prior_board"
fi
[ -n "$board_num" ] || board_num=1
# Board 1 above is intended standalone-kernel numbering, not a fleet-collision
# bug — see docs/features/install-cli.md § "Board number: a fresh install
# mints board 1, on purpose" for why detection of a fleet's own numbering is
# deliberately not done here.

# render_boards_conf_entry <board-id> [owner/repo]
#
# Issues-only is the SOLE init-time tracker mode (temperloop#793), so this
# renders exactly one shape and every line it emits is a REAL, adapter-
# readable assignment. The retired `projects` arm rendered a commented
# `# board.<N>.project=<FILL IN ...>` line here, BEFORE the apply step that
# would have learned the project number, and never reassigned it — so even
# a fully-consented, successful provisioning run shipped a placeholder. And
# because it was a COMMENT, the adapter's `^board\.N\.axis=` grep missed it
# and fell through to its built-in maps rather than failing loudly. There is
# no arm that can emit an incomplete entry any more; test_init.sh pins that
# ("FILL IN" absent from both the config's `tracker.boards_conf_entry` and
# the proposed boards.conf).
render_boards_conf_entry() {
  local board="$1" repo="${2:-<owner>/<repo>}"
  printf 'board.%s.repo=%s\nboard.%s.backend=issues\n' "$board" "$repo" "$board"
}
boards_conf_entry="$(render_boards_conf_entry "$board_num" "$gh_repo")"

# ---------------------------------------------------------------------------
# Step 2 — the FIRST-EPIC OFFER: the ONE consented action `init` still
# performs, and the handoff into the real pipeline (temperloop#796 — the
# init scope-down). It files an ISSUE; it never writes API state. Every
# API-state apply that used to live here (required check, `fnd:` labels,
# Projects-v2 board) is now the first epic's own work — see the "SCOPE" and
# "WHY THE APPLIES MOVED" header notes.
#
# $handoff_next is the single line every arm below sets, printed as the
# closing handoff in the Summary. It is the marker
# .github/workflows/install-tier2.yml greps to prove the live round trip
# reached the handoff rather than degrading somewhere earlier.
# ---------------------------------------------------------------------------
echo "-- 2. First-epic offer (the one consented action; explicit confirmation, default no) --"

handoff_next=""
handoff_prereq=""
# handoff_epic_num/handoff_epic_url are set ONLY when an epic actually
# exists to hand off to (freshly filed, or already filed on an idempotent
# re-run) — temperloop#781. They gate the epic-specific launch/URL lines
# in the closing handoff box (Section 5): every other arm (unoffered,
# declined, failed-to-file) leaves them empty and the box falls back to
# framing whatever $handoff_next says instead.
handoff_epic_num=""
handoff_epic_url=""
handoff_unoffered="run \`temperloop init\` interactively (or pass --yes-first-epic) to file the pre-designed first epic — it is what configures branch protection, head-branch auto-delete, the merge-queue disposition, CI, and your review principles."

if [ "$dry_run" -eq 1 ]; then
  echo "first-epic: skipped (--dry-run — tree-only preview, no API writes)"
  handoff_next="$handoff_unoffered"
elif [ "$no_network" -eq 1 ]; then
  echo "first-epic: skipped (--no-network)"
  handoff_next="$handoff_unoffered"
elif [ -z "$gh_repo" ]; then
  echo "first-epic: skipped (no resolved gh_repo)"
  handoff_next="$handoff_unoffered"
elif ! command -v "$INIT_GH_BIN" >/dev/null 2>&1; then
  echo "first-epic: skipped (gh CLI not found on PATH)"
  handoff_next="$handoff_unoffered"
else
  # --- first epic offer (temperloop#610, ADR 0010) ---------------------
  # See the "FIRST-EPIC OFFER" header comment (top of file) for the full
  # design rationale — skip vs. decline, idempotency probes, the decline
  # floor. This block only ever runs once the surrounding gates above
  # (dry-run/no-network/gh_repo/gh-binary) already passed.
  first_epic_project="$(basename "$gh_repo")"
  first_epic_marker='design-brief: docs/adr/0010-onboarding-as-first-executed-epic.md'
  first_epic_decline_marker="First-epic-decline: $gh_repo"
  first_epic_template="$KERNEL_ROOT/claude/templates/first-epic-setup.md"

  # Mirrors feedback.sh's _feedback_attended: a CI/GITHUB_ACTIONS ambient
  # signal or closed stdin both mean "no live operator to ask" — degrade to
  # a legible skip, never a hang and never a silent "decline".
  _init_first_epic_attended() {
    case "${CI:-}" in [Tt]rue|1|[Yy]es) return 1 ;; esac  # setting:exempt — standard CI-ecosystem ambient signal, not an operator default this repo defines
    case "${GITHUB_ACTIONS:-}" in [Tt]rue|1|[Yy]es) return 1 ;; esac  # setting:exempt — GitHub Actions' own ambient signal, not an operator default this repo defines
    [ -t 0 ] && return 0
    return 1
  }

  # The one line the whole first-epic step exists to produce, once an epic
  # is on the board: the pipeline handoff. Shared by the just-filed and the
  # already-filed arms so a re-run hands off identically to a first run.
  #
  # NAMES ITS PREREQUISITE. `/assess` and `/build` are Claude Code slash
  # commands, and they only reach a machine via `temperloop install`, which
  # symlinks `claude/*` into `~/.claude/`
  # (workflows/scripts/install/links.sh). The adoption ladder
  # (try -> try --demo -> init) otherwise needs no machine-wide setup, so a
  # stranger can very reasonably arrive here with no `~/.claude/commands/`
  # at all — and a handoff naming a command they do not have would defer
  # ALL of this epic's value to a dead pointer, inverting the very
  # first-run experience it exists to fix.
  #
  # The probe is a plain file test against the path links.sh deploys
  # (`~/.claude/commands/assess.md`, resolving through the directory
  # symlink install creates). It only chooses WORDING — both branches name
  # the same next command, and the un-installed branch is phrased so it
  # stays correct even if the probe is wrong (a false negative reads as a
  # redundant "if you haven't", never as a false instruction).
  # The probe only ever ADDS a `prerequisite:` line; it never rewrites the
  # `next step:` line itself. That split is deliberate: `next step: /assess
  # --epic <N>` is a stable marker
  # (.github/workflows/install-tier2.yml greps it, and so does this
  # script's own test suite), so making its wording conditional on a
  # machine-state probe would make the marker conditional too — a probe
  # that silently moved the goalposts for every consumer of that line.
  _init_assess_available() {
    [ -f "${HOME:-}/.claude/commands/assess.md" ]
  }
  # Sets handoff globals directly rather than echoing for a `$(...)`
  # capture — command substitution runs in a subshell, so a $handoff_prereq
  # (or $handoff_epic_num/$handoff_epic_url) assigned in there would be
  # silently discarded.
  #
  # $2 (url) is optional: the fresh-filed call site already has the full
  # URL `gh issue create` printed, and passes it straight through. The
  # idempotent already-filed call site only ever recovers an issue NUMBER
  # from its search/issues probe, so it omits $2 and this function
  # constructs the URL itself from $gh_repo — same shape gh's own output
  # uses, and always a full, never-truncated URL either way (temperloop#781
  # acceptance: the epic URL must print in full on both paths).
  _init_set_handoff() {
    handoff_epic_num="$1"
    handoff_epic_url="${2:-https://github.com/$gh_repo/issues/$1}"
    handoff_next="$(printf '/assess --epic %s — then /build. That epic is what applies the substrate (branch protection, head-branch auto-delete, merge-queue disposition, CI disposition) and records your review principles.' "$1")"
    if ! _init_assess_available; then
      handoff_prereq="\`/assess\` and \`/build\` are Claude Code slash commands, installed into ~/.claude/ by \`temperloop install\` — run that first. (Nothing else in the try -> try --demo -> init ladder needs it; this step does.)"
    fi
  }

  if [ ! -f "$first_epic_template" ]; then
    echo "first-epic: skipped (template not found at $first_epic_template — broken kernel checkout)"
    handoff_next="$handoff_unoffered"
  else
    # Idempotency probes — search issue BODIES (in:body, never in:title):
    # a prior accept already filed the epic (design-brief marker), or a
    # prior decline already filed the durable re-offer pointer (decline
    # marker). Either hit means: never re-offer.
    #
    # THREE-VALUED, deliberately (temperloop#1444): "already filed",
    # "not filed", and UNKNOWN. The probe used to be two-valued and got
    # both halves wrong at once:
    #
    #   1. `is:issue` is now REQUIRED. GitHub's search/issues endpoint
    #      422s on a query carrying neither `is:issue` nor
    #      `is:pull-request`. That is external API drift — no commit in
    #      this repo caused it — which is exactly why the fix cannot stop
    #      at the qualifier.
    #   2. `gh` writes its ERROR BODY to STDOUT. So the old fail-open
    #      (`2>/dev/null || true`) handed the raw 422 JSON blob back as
    #      the "issue number": non-empty, therefore reported as
    #      `already filed as #{"message":…}` and passed straight into
    #      _init_set_handoff, corrupting the handoff too. ANY probe error
    #      — rate limit, network blip, auth scope, outage — silently read
    #      as "already filed, skip".
    #
    # So the captured value is VALIDATED as digits-only before it is ever
    # treated as an issue number, and a probe that errors (or returns
    # anything non-numeric) is recorded as UNKNOWN rather than folded into
    # "no". The validation is the durable half: it makes the probe robust
    # to the NEXT external change, not just this one.
    #
    # Sets $first_epic_probe_num (digits, or empty) and
    # $first_epic_probe_failed (non-empty = UNKNOWN).
    _init_first_epic_probe() {
      first_epic_probe_num=""
      first_epic_probe_failed=""
      first_epic_probe_num="$("$INIT_GH_BIN" api -X GET search/issues \
        -f q="repo:$gh_repo is:issue in:body \"$1\"" \
        --jq '.items[0].number // empty' 2>/dev/null)" \
        || first_epic_probe_failed=1
      case "$first_epic_probe_num" in
        '') ;;
        *[!0-9]*)
          first_epic_probe_num=""
          first_epic_probe_failed=1
          ;;
      esac
      if [ -n "$first_epic_probe_failed" ]; then
        first_epic_probe_num=""
      fi
    }

    _init_first_epic_probe "$first_epic_marker"
    first_epic_existing_num="$first_epic_probe_num"
    first_epic_probe_unknown="$first_epic_probe_failed"
    first_epic_existing_pointer=""
    if [ -z "$first_epic_existing_num" ] && [ -z "$first_epic_probe_unknown" ]; then
      _init_first_epic_probe "$first_epic_decline_marker"
      first_epic_existing_pointer="$first_epic_probe_num"
      first_epic_probe_unknown="$first_epic_probe_failed"
    fi

    # NEVER a silent skip (kernel § Subagent usage / legible degradation).
    # This notice states the FACT — the probe could not answer — and the
    # arm below states the DISPOSITION, so neither line has to guess at
    # the other's job. Deliberately worded without the token `FAILED`:
    # .github/workflows/install-tier2.yml treats that marker as fatal, and
    # an unanswerable probe is a degrade, not a failed action.
    if [ -n "$first_epic_probe_unknown" ]; then
      echo "first-epic: idempotency probe unavailable — the search/issues probe errored or returned a non-numeric result, so whether the epic is already filed is UNKNOWN (never assumed 'already filed')"
    fi

    if [ -n "$first_epic_existing_num" ]; then
      echo "first-epic: already filed as #$first_epic_existing_num — skipping offer (idempotent)"
      _init_set_handoff "$first_epic_existing_num"
    elif [ -n "$first_epic_existing_pointer" ]; then
      echo "first-epic: previously declined — re-offer pointer #$first_epic_existing_pointer already tracks the gap — skipping re-offer"
      handoff_next="the substrate is still unconfigured and tracked by #$first_epic_existing_pointer. Re-run \`temperloop init\` with --yes-first-epic (or open the epic by hand from claude/templates/first-epic-setup.md) when you want it."
    elif [ -z "$consent_first_epic" ] && ! _init_first_epic_attended; then
      echo "first-epic: skipped — no interactive operator detected (no TTY, or an unattended/CI signal is set); point-of-use principle defaults and the managed-merge floor still apply with zero configuration — pass --yes-first-epic/--no-first-epic to decide non-interactively"
      handoff_next="$handoff_unoffered"
    elif [ -n "$first_epic_probe_unknown" ]; then
      # UNKNOWN state, ranked AFTER the ambient-CI arm on purpose: an
      # unattended run has a truer, more specific reason to skip (there is
      # nobody to ask), so it should not be reported as a probe outage.
      # Reached only when an operator IS present (or consented) and we
      # still cannot tell whether the epic exists: withhold, because
      # filing a duplicate epic is the one outcome the probe exists to
      # prevent.
      #
      # This arm prints a SECOND '^first-epic: ' line (the notice above
      # states the fact, this one the disposition).
      # .github/workflows/install-tier2.yml's init leg accounts for that:
      # it reads the LAST such line as the disposition rather than
      # requiring exactly one, so a transient search outage degrades
      # legibly instead of failing a release gate.
      echo "first-epic: skipped — idempotency state unknown (see the probe notice above), so the offer is withheld rather than risk filing a duplicate epic; re-run \`temperloop init\` once \`gh\` is healthy, or open the epic by hand from claude/templates/first-epic-setup.md"
      handoff_next="$handoff_unoffered"
    else
      first_epic_decision="$consent_first_epic"
      if [ -z "$first_epic_decision" ]; then
        echo
        echo "temperloop ships a pre-designed first epic: \"Set up $first_epic_project with temperloop\" —"
        echo "it configures engineering-review principles, a GitHub branch/PR/merge substrate, and CI"
        echo "by driving REAL work through this repo's own pipeline (/assess --epic N -> /build), so every"
        echo "future change — yours or an agent's — arrives as a reviewed, gated pull request you can audit."
        echo "See claude/templates/first-epic-setup.md and docs/adr/0010-onboarding-as-first-executed-epic.md."
        echo "Decline, and nothing changes: $first_epic_project is untouched — its branch protection, CI, and"
        echo "merge queue stay unconfigured, though the kernel's review-principle defaults still apply"
        echo "automatically at point of use. We'll file a Backlog item tracking the gap so it's easy to pick"
        echo "up later — or open the epic by hand any time from claude/templates/first-epic-setup.md."
        printf 'Set up %s with temperloop as your first epic? [y/N] ' "$first_epic_project"
        first_epic_ans=""
        read -r first_epic_ans || first_epic_ans=""
        case "$first_epic_ans" in
          y|Y|yes|YES) first_epic_decision=yes ;;
          *)           first_epic_decision=no ;;
        esac
      fi

      if [ "$first_epic_decision" = yes ]; then
        # The epic body is EVERYTHING from the template's own
        # "# Set up <project> with temperloop" heading down — copied
        # verbatim (never restated) after substituting <project>. This is
        # data extraction, not a second copy of the epic's content.
        first_epic_body="$(awk '/^# Set up /{p=1} p' "$first_epic_template" | sed "s/<project>/$first_epic_project/g")"
        if first_epic_url="$("$INIT_GH_BIN" issue create -R "$gh_repo" \
            --title "Set up $first_epic_project with temperloop" \
            --body "$first_epic_body" 2>&1)"; then
          first_epic_num="$(basename "$first_epic_url")"
          echo "first-epic: filed $first_epic_url (#$first_epic_num) — next: /assess --epic $first_epic_num"
          _init_set_handoff "$first_epic_num" "$first_epic_url"
          # NOT recorded into installs[] (temperloop#794): filing this issue
          # is not a revertible API-state side effect the way a label/
          # required-check/board/proposal-branch is — `temperloop eject`
          # must never close or otherwise touch an epic issue an adopter may
          # already be working, so there is no revert action to record. The
          # idempotency probe above (search/issues on $first_epic_marker) is
          # what keeps a re-run from re-offering; installs[] isn't needed for
          # that. (eject.sh's dispatch keeps a read-compat no-op handler for
          # this type in case an older init already wrote one.)
        else
          echo "first-epic: FAILED to file — $first_epic_url"
          handoff_next="$handoff_unoffered"
        fi
      else
        # DECLINE FLOOR — ONE floor, not two (temperloop#796; ADR 0010's
        # "Decline floors are durable" clause as amended). The durable
        # re-offer pointer below IS the whole floor.
        #
        # What used to run here, and why it doesn't any more: an INLINE
        # principles interview, extracted from the template's own "### A1."
        # section and recorded into the knowledge-store priorities note.
        # That was a SECOND, parallel copy of an interview the epic already
        # owns as its L0 item (`record-principles`) — asked by a different
        # actor (this bootstrap script rather than /assess -> /build),
        # writing through a different seam, on the path where the adopter
        # had just said "no". Declining the epic now DEFERS the interview
        # instead of running a shadow of it, and the kernel default
        # (claude/engineering-principles.md) still applies at every review
        # call site's point of use regardless — so declining costs the
        # adopter only the *recorded* choice, never the criteria
        # themselves.
        echo "first-epic: declined — filing a durable re-offer pointer (the whole decline floor; the principles interview is the epic's own L0, deferred rather than run inline)"

        # Durable re-offer pointer — a Backlog item in the ADOPTER's own
        # repo naming exactly what remains unconfigured, so the gap stays
        # tracked rather than vanishing (ADR 0010 § Decline floors).
        "$INIT_GH_BIN" label create "fnd:status:backlog" -R "$gh_repo" \
          --color "ededed" --description "Tracker status (issues-only backend)" >/dev/null 2>&1 || true
        first_epic_pointer_body="temperloop's pre-designed first epic (\"Set up $first_epic_project with temperloop\") was offered by \`temperloop init\` and declined.

Unconfigured substrate this leaves behind:
- Default-branch protection (require-PR, no direct pushes)
- Head-branch auto-delete on merge
- A merge-queue disposition (native queue, or the managed-merge fallback)
- A CI disposition (a scaffolded \`checks\` workflow, or an explicit no-Actions posture)

None of this leaves the repo broken — the kernel's point-of-use principle
defaults and the managed-merge fallback both still work with zero
configuration. Re-run \`temperloop init\` (or open the epic by hand from
claude/templates/first-epic-setup.md) to configure it later.

$first_epic_decline_marker"
        if first_epic_pointer_url="$("$INIT_GH_BIN" issue create -R "$gh_repo" \
            --title "temperloop first-epic setup: still unconfigured" \
            --body "$first_epic_pointer_body" --label "fnd:status:backlog" 2>&1)"; then
          first_epic_pointer_num="$(basename "$first_epic_pointer_url")"
          echo "first-epic: filed durable re-offer pointer $first_epic_pointer_url (#$first_epic_pointer_num)"
          handoff_next="the substrate is still unconfigured and tracked by #$first_epic_pointer_num. Re-run \`temperloop init\` with --yes-first-epic (or open the epic by hand from claude/templates/first-epic-setup.md) when you want it."
          # NOT recorded into installs[] (temperloop#794) — same reasoning
          # as the accept-path issue above: this pointer issue is a durable
          # tracked gap, not a revertible API-state side effect, and eject
          # must never touch it. The idempotency probe above
          # ($first_epic_decline_marker) is what prevents re-offering.
        else
          echo "first-epic: FAILED to file the re-offer pointer — $first_epic_pointer_url"
          handoff_next="$handoff_unoffered"
        fi
      fi
    fi
  fi
fi
echo

# Carry the prior run's install manifest forward, deduped on the fields
# that identify an install uniquely.
#
# Since the scope-down (temperloop#796) this step contributes NOTHING of its
# own: the only entry `init` still mints is the `proposal_pr` one, folded in
# by the self-record second pass below. The carry-forward is deliberately
# kept, and `.temperloop/config`'s schema stays **1**, precisely so an
# EXISTING adopter's recorded `label` / `required_check` / `board` entries
# survive a re-run and stay revertible — `temperloop eject` keeps all four
# handlers, and dropping them from the manifest here would silently strand
# API state it can no longer see.
all_installs="$(jq -c 'unique_by([.type, (.name // ""), (.branch // ""), (.repo // ""), (.url // "")])' \
  <<<"$existing_installs")"

# ---------------------------------------------------------------------------
# THE BASE TIP — the only tree a manifest decision may be made against.
#
# WHY THIS EXISTS (a HIGH defect this replaced, reproduced in both
# directions). proposal-pr.sh always re-creates the proposal branch FRESH off
# the base tip (`git checkout -q -B "$branch" "$base_ref"`), so the manifest
# is a diff against the BASE, never against whatever the caller happens to
# have checked out. Every optional-entry decision below used to read the
# WORKING TREE instead, which is wrong in both directions:
#   - AN IDEMPOTENT RE-RUN DELETED THE FILE IT CLAIMED TO PRESERVE. After run
#     1 the checkout sits on the proposal branch, which carries the file. Run
#     2's working-tree probe saw it, "skipped", and omitted the manifest
#     entry — then the branch was re-cut off base, which does NOT carry it,
#     so git removed it and the force-push regressed an already-open PR. The
#     operator was told "leaving it untouched" at the exact moment the file
#     was deleted under them.
#   - AN ADOPTER'S OWN FILE WAS OVERWRITTEN. When the file exists on the base
#     branch but not in the local checkout (a stale clone, a checkout on an
#     older commit, or --base naming a branch other than the one checked
#     out), the working-tree probe found nothing, proposed ours, and the
#     generator's `printf > "$abs"` replaced theirs.
# Both are ONE root cause: probing a tree that is not the one being diffed.
#
# THE RULE every optional entry below now follows — decide against the base
# tip, and never drop content you can see:
#   1. on the base tip already -> propose nothing (the fresh branch inherits
#      it verbatim, so there is nothing to add and nothing to overwrite);
#   2. in the working tree but NOT on the base tip -> carry THAT FILE'S OWN
#      BYTES into the manifest (never ours), so a re-run neither clobbers nor
#      drops it;
#   3. in neither -> propose ours.
#
# NO SECOND RESOLVER. `$base` is resolved HERE and then passed to
# proposal-pr.sh explicitly, rather than each side working it out
# independently — two copies of a default-branch resolver drifting apart
# would reintroduce exactly the bug above, one layer deeper and harder to
# see. init decides; the generator is told.
#
# WHAT THAT DOES AND DOES NOT GUARANTEE. It pins the ref NAME both scripts
# mean — that much is by construction. It does NOT pin the ref TIP: this
# script fetches and probes, then proposal-pr.sh fetches again before cutting
# the branch, so a push landing between the two moves the tip out from under
# the decisions made above. The residual race is a stale-by-seconds manifest
# (an entry proposed against a base that just gained the file), not a wrong
# TREE — the failure this section exists to prevent — and the generator's own
# diff-against-base is what settles it: a redundant entry becomes NO_CHANGES.
# Narrowing it further would mean passing a resolved SHA rather than a branch
# name, which the generator's interface does not take today.
# ---------------------------------------------------------------------------

# Mirrors proposal-pr.sh's own default_branch(). What passing the RESULT to
# that script guarantees is agreement on the resolved NAME — not that the two
# scripts do the same things in the same order with it. proposal-pr.sh
# validates the name BEFORE it invokes git; this script must do the same, and
# for a while did not (see "VALIDATE BEFORE ACTING" below).
init_default_branch() {
  local ref b
  if ref="$(git -C "$repo_dir" symbolic-ref --quiet --short "refs/remotes/$remote/HEAD" 2>/dev/null)"; then
    printf '%s\n' "${ref#"$remote"/}"
    return 0
  fi
  for b in main master; do
    if git -C "$repo_dir" show-ref --verify --quiet "refs/remotes/$remote/$b"; then
      printf '%s\n' "$b"
      return 0
    fi
  done
  return 1
}

[ -n "$base" ] || base="$(init_default_branch || true)"

# ---------------------------------------------------------------------------
# VALIDATE BEFORE ACTING — `--base` is an UNVALIDATED CLI string, and the
# fetch below is its first consumer.
#
# `--base` parses as a bare `base="${2:?…}"` with no checking, and `git fetch`
# honors option-shaped arguments: a value like
# `--upload-pack=touch /tmp/PWNED; git-upload-pack` EXECUTES at the fetch.
# Before the base-tip probe existed this script never invoked git with `$base`
# at all — it only forwarded the string, and proposal-pr.sh's own
# validate_branch() rejected it before that script's fetch. Introducing a
# fetch here inverted that ordering: the generator still refuses, but only
# AFTER the command has already run. Downstream refusal is not a guard.
#
# This is documented CLI surface (VERSIONING.md's CLI-surface row) that
# adopter wrapper scripts and CI jobs pass, so the value is not always a
# human's own keystroke. Validate once, HERE, before the first git invocation
# — one guard then covers the fetch, both show-refs, every cat-file/show in
# base_has/base_show, and the message interpolations.
# ---------------------------------------------------------------------------
if [ -n "$base" ] && ! git check-ref-format "refs/heads/$base" 2>/dev/null; then
  echo "init.sh: --base '$base' is not a valid git branch name" >&2
  exit 2
fi

# Same best-effort fetch + same ref preference order proposal-pr.sh uses, so
# the tip this script INSPECTS is the tip that script BRANCHES FROM. Skipped
# on --dry-run, which is contractually zero-write to $repo_dir (temperloop
# #413) — a fetch writes refs under .git/. A dry run's preview is therefore
# computed against whatever base ref is already local; Step 4's preview says
# so out loud rather than leaving the operator to infer it.
#
# ...and skipped on --no-network for the same reason the Step 3 proposal is
# (temperloop#969): this fetch is the run's OTHER network reach, and a flag
# named --no-network that still dials out is the very defect that issue
# reports. Purely a suppression of the call — under --no-network the Step 3
# arm never consumes $base_ref (only the --dry-run preview does, and that
# arm already skips the fetch), so the resolution below simply reads
# whatever refs are already local.
base_ref=""
if [ -n "$base" ]; then
  [ "$dry_run" -eq 1 ] || [ "$no_network" -eq 1 ] || git -C "$repo_dir" fetch "$remote" "$base" >/dev/null 2>&1 || true
  if git -C "$repo_dir" show-ref --verify --quiet "refs/remotes/$remote/$base"; then
    base_ref="refs/remotes/$remote/$base"
  elif git -C "$repo_dir" show-ref --verify --quiet "refs/heads/$base"; then
    base_ref="refs/heads/$base"
  fi
fi

# base_has <repo-relative-path> — does the base tip carry this path? False
# whenever the base could not be resolved at all, which degrades SAFELY: rule
# 2 then governs anything already in the working tree (carry its own bytes),
# and proposal-pr.sh refuses the run on its own for the same reason.
base_has() {
  [ -n "$base_ref" ] && git -C "$repo_dir" cat-file -e "$base_ref:$1" 2>/dev/null
}
# base_show <repo-relative-path> — that path's bytes at the base tip.
base_show() {
  git -C "$repo_dir" show "$base_ref:$1" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Step 4 — build .temperloop/config content and the tree-only proposal.
# ---------------------------------------------------------------------------
now_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
build_config_json() {
  local installs="$1"
  jq -n \
    --argjson schema 1 \
    --arg generated_at "$now_ts" \
    --argjson probe "$probe_json" \
    --arg mode "$tracker_mode" \
    --arg board "$board_num" \
    --arg conf_path "workflows/scripts/board/boards.conf" \
    --arg entry "$boards_conf_entry" \
    --argjson installs "$installs" \
    '{
      schema: $schema,
      generated_at: $generated_at,
      probe: $probe,
      tracker: {
        mode: $mode,
        board: ($board | tonumber? // $board),
        boards_conf_path: $conf_path,
        boards_conf_entry: $entry
      },
      installs: $installs
    }'
}
config_json="$(build_config_json "$all_installs")"

manifest_entries=()
manifest_entries+=("$(jq -cn --arg p "$config_rel" --arg c "$config_json" '{path:$p, content:$c}')")
# The PR title names what this manifest actually carries. Built up alongside
# the entries rather than inferred from `${#manifest_entries[@]}`: with more
# than one optional entry, a count no longer identifies WHICH ones are
# present, and the old two-branch form would have titled a config-plus-
# producer proposal "+ boards.conf".
title_parts="$config_rel"

board_toolkit_dir="$repo_dir/workflows/scripts/board"
boards_conf_target="workflows/scripts/board/boards.conf"
# The toolkit-presence probe reads base ∪ tree for the same reason every
# decision below does: on a re-run the checkout sits on the proposal branch,
# cut off a base that may not carry the toolkit dir, and a tree-only probe
# would then answer "no toolkit here" and silently drop boards.conf from the
# manifest — the same deletion bug, one question earlier.
if [ -d "$board_toolkit_dir" ] || base_has "workflows/scripts/board"; then
  boards_conf_abs="$repo_dir/$boards_conf_target"

  # --- A REAL UNION, not a preference -------------------------------------
  # An earlier cut of this arm let the working tree's whole-file bytes
  # REPLACE the base tip's, and called that a union. It is not: a stale clone
  # carrying a stale boards.conf then won outright and DELETED every
  # board.<N>.* the base had and the tree didn't — force-pushed over the open
  # PR, silently. Fixing "the tree lacks the file entirely" closed only half
  # the hole; this closes the other half.
  #
  # THE RULE: the base tip is authoritative and is preserved BYTE-FOR-BYTE as
  # the foundation. The working tree may only ADD board sections base does
  # not already define. So the proposal is always a superset of base — never
  # a rewrite of it — and the invariant is asserted below rather than merely
  # intended, because "I meant a union" is exactly the claim that was wrong.
  #
  # When base has no boards.conf at all there is nothing of base's to
  # preserve, so the tree's bytes are kept VERBATIM instead of being
  # reconstructed from sections — that keeps an adopter's comments and
  # layout, which section extraction would quietly discard.

  # boards_conf_ids <content> — the distinct board ids a body assigns.
  boards_conf_ids() {
    printf '%s\n' "$1" | awk -F. '/^board\./ { if (NF >= 3) print $2 }' | sort -u
  }
  # boards_conf_section <content> <id> — one board id's assignment lines.
  # Exact prefix compare via awk `index`, never a regex: a board id is
  # caller data and must not be interpolated into a pattern.
  boards_conf_section() {
    printf '%s\n' "$1" | awk -v p="board.$2." 'index($0, p) == 1'
  }
  boards_conf_has_id() {
    printf '%s\n' "$1" | grep -Fx "$2" >/dev/null
  }

  boards_conf_unsafe=0
  base_conf=""
  base_conf_present=0
  if base_has "$boards_conf_target"; then
    # CHECK the capture (this script has no `set -e`): an unchecked read that
    # came back empty would make base look like it holds nothing, and the
    # "union" would then propose a file that erases it.
    if base_conf="$(base_show "$boards_conf_target")"; then
      base_conf_present=1
    else
      boards_conf_unsafe=1
      echo "init.sh: WARNING — $boards_conf_target exists at ${base:-the base branch} but could not be read; not proposing boards.conf (refusing to risk overwriting entries this run cannot see)" >&2
    fi
  fi
  tree_conf=""
  if [ -f "$boards_conf_abs" ] && [ -r "$boards_conf_abs" ]; then
    if ! tree_conf="$(cat "$boards_conf_abs")"; then
      boards_conf_unsafe=1
      echo "init.sh: WARNING — could not read $boards_conf_target from the working tree; not proposing boards.conf (its board entries cannot be preserved unread)" >&2
    fi
  fi

  if [ "$boards_conf_unsafe" -eq 0 ]; then
    if [ "$base_conf_present" -eq 1 ]; then
      # Base is the foundation, kept verbatim; the tree may only add ids it
      # does not already define.
      base_ids="$(boards_conf_ids "$base_conf")"
      desired_conf="$base_conf"
      for tree_id in $(boards_conf_ids "$tree_conf"); do
        boards_conf_has_id "$base_ids" "$tree_id" && continue
        tree_section="$(boards_conf_section "$tree_conf" "$tree_id")"
        [ -n "$tree_section" ] || continue
        desired_conf="$desired_conf"$'\n\n'"$tree_section"
      done
    else
      # Nothing on base to preserve — keep the tree's own bytes verbatim.
      desired_conf="$tree_conf"
    fi

    # Our own entry, only if no one has already defined this board id.
    if ! boards_conf_has_id "$(boards_conf_ids "$desired_conf")" "$board_num"; then
      if [ -n "$desired_conf" ]; then
        desired_conf="$desired_conf"$'\n\n'"$boards_conf_entry"
      else
        desired_conf="$boards_conf_entry"
      fi
    fi

    # ASSERT the superset invariant before proposing anything. This is the
    # backstop for the claim above: every board id the base tip defines must
    # still be defined by what we are about to propose. A violation means the
    # union logic is wrong, so refuse and say so rather than force-push a
    # deletion over the adopter's open PR.
    boards_conf_lost=""
    desired_ids="$(boards_conf_ids "$desired_conf")"
    for base_id in $(boards_conf_ids "$base_conf"); do
      boards_conf_has_id "$desired_ids" "$base_id" \
        || boards_conf_lost="$boards_conf_lost board.$base_id.*"
    done
    if [ -n "$boards_conf_lost" ]; then
      echo "init.sh: WARNING — not proposing $boards_conf_target: it would drop$boards_conf_lost, which ${base:-the base branch} defines. This is a bug in init's boards.conf merge; the rendered entry is still recorded in $config_rel for you to apply by hand." >&2
    elif [ -z "$desired_conf" ]; then
      # Same no-`set -e` hazard the producer arm guards twice: never propose
      # an empty file over a path that is supposed to carry configuration.
      echo "init.sh: WARNING — computed an empty $boards_conf_target; not proposing it" >&2
    elif [ "$base_conf_present" -eq 1 ] && [ "$desired_conf" = "$base_conf" ]; then
      echo "boards.conf: board.$board_num.* already on ${base:-the base branch} — leaving $boards_conf_target untouched"
    else
      manifest_entries+=("$(jq -cn --arg p "$boards_conf_target" --arg c "$desired_conf" '{path:$p, content:$c}')")
      title_parts="$title_parts + boards.conf"
      # Narrate the propose branch too. It used to be the ONLY silent
      # decision in this script — the operator saw nothing at all while
      # their board entries were being rewritten.
      if [ "$base_conf_present" -eq 1 ]; then
        echo "boards.conf: proposing $boards_conf_target — keeping every board ${base:-the base branch} already defines and adding board.$board_num.*"
      else
        echo "boards.conf: proposing $boards_conf_target — adding board.$board_num.* (not yet on ${base:-the base branch})"
      fi
    fi
  fi
else
  echo "boards.conf: workflows/scripts/board/ not present in this repo — rendered entry recorded in $config_rel only:"
  printf '%s\n' "$boards_conf_entry" | sed 's/^/  /'
fi

# --- the `tokens` report.d producer shim (temperloop#984) ------------------
# See "TOKENS PRODUCER SHIM" in the header for the full rationale, and "THE
# BASE TIP" above for the three-rule decision the arms below implement (the
# same one the boards.conf step just used). This is the whole placement
# path: no prompt (no arm reads stdin), no overwrite and no drop, no
# `installs[]` entry (a tree artifact rides the manifest), and a legible
# skip when the shim itself is unusable.
producer_target=".temperloop/report.d/tokens"
producer_abs="$repo_dir/$producer_target"
# Set only on the arm that actually proposes the file — a reviewer seeing a
# new EXECUTABLE in the diff deserves a sentence on what it is and what it
# may do, and a body that claimed one on a run that placed nothing would be
# worse than saying nothing at all.
producer_body_note=""
producer_source=""
producer_mode=""
if base_has "$producer_target"; then
  # RULE 1 — already on the base tip. The proposal branch is cut FROM base,
  # so it inherits the adopter's file verbatim: there is nothing to add and,
  # crucially, nothing of theirs for us to overwrite. This is the arm that
  # fixes the stale-clone direction, where a working-tree probe saw nothing
  # and proposed ours straight over theirs.
  echo "report.d producer: $producer_target already on ${base:-the base branch} — leaving it untouched (never overwritten)"
elif [ -e "$producer_abs" ] || [ -L "$producer_abs" ]; then
  # RULE 2 — in the working tree but NOT on base. This is the idempotent
  # re-run (the checkout is sitting on the proposal branch that carries it),
  # and also an adopter who wrote their own but has not merged it to the
  # default branch yet. Carry THAT FILE'S OWN BYTES, never the shim's:
  # omitting the entry here is what used to DELETE the file on re-run, and
  # substituting the shim's bytes is what would overwrite a hand-written one.
  #
  # `-e`, not `-f`, because a directory or a symlink sitting there is equally
  # not ours to replace; `|| -L` because `-e` FOLLOWS symlinks and so misses
  # a DANGLING one — which is the case that would actually have been
  # clobbered, since the generator's own `printf > "$abs"` follows the link
  # too and would silently write through to its missing target.
  if [ -f "$producer_abs" ] && [ -r "$producer_abs" ]; then
    producer_source="$producer_abs"
    # PRESERVE THEIR MODE, don't re-arm it. Hardcoding 755 on this arm was
    # wrong: the file is the ADOPTER's, and 644 is a MEANINGFUL state here —
    # report.sh only runs executables, so a non-executable producer renders
    # as "skipped -- tokens: producer unavailable". That makes chmod 644 a
    # plausible deliberate DISABLE, and forcing 755 silently re-armed it
    # while the line below said "unchanged". 755 belongs to rule 3, where
    # the bytes really are ours.
    if [ -x "$producer_abs" ]; then producer_mode="755"; else producer_mode="644"; fi
    # Say what is and is not preserved. `-f` above follows symlinks, so a
    # symlinked producer is carried as a regular file holding its target's
    # bytes — the link itself does not survive the manifest, and an operator
    # who deliberately symlinked it should know that.
    #
    # Byte-exact for any normal file, but the message still says "content
    # and mode" rather than "bytes": since temperloop#992 proposal-pr.sh
    # normalizes every manifest entry to EXACTLY ONE final newline (see the
    # capture note below), so a source ending in two or more blank lines is
    # carried with those collapsed to one. "Content and mode" stays the
    # honest claim across every input.
    producer_carry_note=""
    [ -L "$producer_abs" ] && producer_carry_note=", flattened from a symlink to a regular file"
    echo "report.d producer: carrying the existing $producer_target forward — content and mode ($producer_mode) preserved$producer_carry_note (present here, not yet on ${base:-the base branch})"
  else
    # Unreadable, or not a regular file. We cannot copy bytes we cannot
    # read, so this one case genuinely cannot be carried — say so LOUDLY on
    # stderr rather than printing a soothing "leaving it untouched" line
    # while the branch re-cut drops it.
    echo "init.sh: WARNING — $producer_target exists but is not a readable regular file; it cannot be carried into the proposal, and re-creating the proposal branch off ${base:-the base branch} may remove it. Commit it to ${base:-the base branch}, or make it readable, then re-run." >&2
  fi
elif [ ! -f "$PRODUCER_SHIM" ] || [ ! -r "$PRODUCER_SHIM" ] || [ ! -s "$PRODUCER_SHIM" ]; then
  # Soft seam (see the header): a broken/partial kernel checkout costs the
  # adopter one `temperloop report` headline, never their whole bootstrap.
  # `-r` and `-s`, not just `-f`: this script runs WITHOUT `set -e`, so an
  # unreadable or empty shim would otherwise sail past a bare `-f`, leave
  # `$(cat …)` empty, and commit a ZERO-BYTE mode-755 file into the
  # adopter's PR — which `report.sh` then execs to exit 0 with no output and
  # no `skipped` line anywhere. That is precisely the failure this arm
  # exists to make legible, arriving illegibly.
  echo "report.d producer: skipped — shim unavailable at $PRODUCER_SHIM"
else
  # RULE 3 — on neither side. Propose ours, and only here is a hardcoded 755
  # ours to choose: these are the kernel's bytes, and the shim is exec'd.
  producer_source="$PRODUCER_SHIM"
  producer_mode="755"
fi

if [ -n "$producer_source" ]; then
  # `$(…)` strips every trailing newline, so `$producer_content` carries
  # none — and that is fine, because since temperloop#992 proposal-pr.sh
  # NORMALIZES each manifest entry on write to exactly one final newline.
  # The landed copy is therefore the source's bytes for any normally-
  # terminated file (a source ending in several blank lines has them
  # collapsed to one). Do NOT re-append a newline at THIS call site: the
  # generator owns the invariant for `.temperloop/config`, `boards.conf`,
  # and this file alike, and a second newline here would only add a blank
  # line the generator cannot tell from intent.
  producer_content="$(cat "$producer_source")"
  if [ -z "$producer_content" ]; then
    # Belt-and-braces for the same no-`set -e` hazard as the soft-seam arm
    # above: a read that succeeded the file tests and STILL came back empty
    # (a race, a vanished file) must not become a zero-byte executable in
    # someone's PR. Guarding the append is what makes that structural.
    echo "init.sh: WARNING — read $producer_source but got no content; not proposing $producer_target (refusing to commit a zero-byte executable)" >&2
  else
    manifest_entries+=("$(jq -cn --arg p "$producer_target" --arg c "$producer_content" \
      --arg m "${producer_mode:-755}" '{path:$p, content:$c, mode:$m}')")
    title_parts="$title_parts + report.d/tokens"
    # The body note describes OUR shim, so it is set only when that is what
    # we are actually proposing. On the carry-forward arm the file is the
    # adopter's own and we have no standing to describe its behavior.
    if [ "$producer_source" = "$PRODUCER_SHIM" ]; then
      producer_body_note="

\`$producer_target\` is a **drop-in report producer** (mode 755, executable —
\`temperloop report\` runs every executable in \`.temperloop/report.d/\`). It is
a thin LOCATOR: it finds an installed temperloop kernel and \`exec\`s that
kernel's own implementation, which reads local Claude Code transcripts to
report token spend. It makes no network calls of its own, and it exits 0 with
a one-line \`skipped\` notice on any host with no kernel installed. Deleting
it costs you only \`temperloop report\`'s tokens-spent headline."
      echo "report.d producer: proposing $producer_target (mode 755) — the drop-in that gives \`temperloop report\` its tokens-spent headline"
    fi
  fi
fi
echo

# --- the `dual-build` report.d producer shim (temperloop#2084) ------------
# Identical three-rule placement to the tokens block just above — see
# "DUAL-BUILD PRODUCER SHIM" in the header for what's different (nothing in
# the mechanics, only in why it's wired unconditionally). Deliberately its
# own block rather than a shared loop: the two shims' human-facing body
# notes differ, and this codebase's existing convention (this file has
# exactly one other such block, tokens') has no generic n-producer loop yet
# to extend — see the verification-surface note on why duplicating the
# well-tested three-rule shape here is the lower-risk choice over a first
# generalization attempt on this file.
db_producer_target=".temperloop/report.d/dual-build"
db_producer_abs="$repo_dir/$db_producer_target"
db_producer_body_note=""
db_producer_source=""
db_producer_mode=""
if base_has "$db_producer_target"; then
  echo "report.d producer: $db_producer_target already on ${base:-the base branch} — leaving it untouched (never overwritten)"
elif [ -e "$db_producer_abs" ] || [ -L "$db_producer_abs" ]; then
  if [ -f "$db_producer_abs" ] && [ -r "$db_producer_abs" ]; then
    db_producer_source="$db_producer_abs"
    if [ -x "$db_producer_abs" ]; then db_producer_mode="755"; else db_producer_mode="644"; fi
    db_producer_carry_note=""
    [ -L "$db_producer_abs" ] && db_producer_carry_note=", flattened from a symlink to a regular file"
    echo "report.d producer: carrying the existing $db_producer_target forward — content and mode ($db_producer_mode) preserved$db_producer_carry_note (present here, not yet on ${base:-the base branch})"
  else
    echo "init.sh: WARNING — $db_producer_target exists but is not a readable regular file; it cannot be carried into the proposal, and re-creating the proposal branch off ${base:-the base branch} may remove it. Commit it to ${base:-the base branch}, or make it readable, then re-run." >&2
  fi
elif [ ! -f "$DUAL_BUILD_PRODUCER_SHIM" ] || [ ! -r "$DUAL_BUILD_PRODUCER_SHIM" ] || [ ! -s "$DUAL_BUILD_PRODUCER_SHIM" ]; then
  echo "report.d producer: skipped — shim unavailable at $DUAL_BUILD_PRODUCER_SHIM"
else
  db_producer_source="$DUAL_BUILD_PRODUCER_SHIM"
  db_producer_mode="755"
fi

if [ -n "$db_producer_source" ]; then
  db_producer_content="$(cat "$db_producer_source")"
  if [ -z "$db_producer_content" ]; then
    echo "init.sh: WARNING — read $db_producer_source but got no content; not proposing $db_producer_target (refusing to commit a zero-byte executable)" >&2
  else
    manifest_entries+=("$(jq -cn --arg p "$db_producer_target" --arg c "$db_producer_content" \
      --arg m "${db_producer_mode:-755}" '{path:$p, content:$c, mode:$m}')")
    title_parts="$title_parts + report.d/dual-build"
    if [ "$db_producer_source" = "$DUAL_BUILD_PRODUCER_SHIM" ]; then
      db_producer_body_note="

\`$db_producer_target\` is a **drop-in report producer** (mode 755, executable —
\`temperloop report\` runs every executable in \`.temperloop/report.d/\`). It is
a thin LOCATOR: it finds an installed temperloop kernel and \`exec\`s that
kernel's own implementation, which reads this repo's dual-build ledger
(\`.temperloop/model-comparison/dual-build/\`, gitignored) to report the
new-work dual-build harness's cumulative win-rate/cost/calibration figures.
It makes no network calls of its own, and it exits 0 with a one-line
\`skipped\` notice on any host with no kernel installed, or in any repo that
has never run \`/build --dual-build\`. Deleting it costs you only
\`temperloop report\`'s dual-build block."
      echo "report.d producer: proposing $db_producer_target (mode 755) — the drop-in that gives \`temperloop report\` its dual-build cumulative block"
    fi
  fi
fi
echo

echo "-- 3. Proposal PR (tree-only; nothing lands without review) --"
title="chore: temperloop init — $title_parts"
body="Proposed by \`temperloop init\` (opt-in, reviewable — foundation #765 Epic D).

This PR is TREE-ONLY: it never touches labels, branch protection, or
Projects-v2 board state. \`temperloop init\` does not apply API state at all
any more (temperloop#796) — branch protection, head-branch auto-delete, the
merge-queue disposition, the required \`checks\` status, and CI are the
first epic's work, applied later with per-write consent via
\`/assess --epic N\` -> \`/build\`.

Tracker mode: **issues-only** (\`board.$board_num.backend=issues\`), the sole
tracker backend. The Projects-v2 arm was removed outright (ADR 0004, epic
#524) and there is no configuration path back — see
\`docs/features/install-cli.md\` § Tracker mode.$producer_body_note$db_producer_body_note"

if [ "$dry_run" -eq 1 ]; then
  # --dry-run GATE (temperloop#413): genuinely zero-write — compute and
  # print what WOULD be proposed, without ever invoking proposal-pr.sh.
  # proposal-pr.sh's OWN --dry-run mode still performs a REAL local
  # `git checkout -B <branch>` + `git commit` in $repo_dir (its header
  # says so explicitly: "Still a real local git checkout + commit in
  # --repo-dir — nothing remote, nothing on GitHub") — that is exactly
  # the second half of #413's bug report (a dry run left the checkout on
  # foundation-init/config instead of the caller's original branch). So a
  # dry run never calls it at all; this preview is computed locally and
  # read-only — nothing is switched and nothing is written to disk.
  #
  # COMPARED AGAINST THE BASE TIP, not the working tree. A real run commits
  # onto a branch cut fresh off base, so base is what "would create / would
  # update / unchanged" is actually relative to. Comparing against the
  # working tree made the preview LIE routinely once rule 2's carry-forward
  # existed: after one real run it printed `unchanged: .temperloop/report.d/
  # tokens` while base did not carry that path at all — the run would in fact
  # CREATE it. Fall back to the tree only when no base ref resolved, and
  # label that explicitly rather than presenting it as the same answer.
  echo "dry-run — tree-only preview; zero writes to $repo_dir (no branch switch, no commit, no push, no PR)"
  if [ -n "$base_ref" ]; then
    # Name the ref AND the staleness: --dry-run deliberately skips the fetch
    # (a fetch writes refs under .git/, and this mode promises zero writes),
    # so every assertive line above and below is relative to whatever this
    # checkout last saw — not to what is on the remote right now.
    echo "  comparing against $base_ref — NOT refreshed (--dry-run performs no fetch, so this may be behind the remote)"
  else
    # With no base ref there is nothing to diff against, and proposal-pr.sh —
    # the thing that would REFUSE the run for this very reason — is never
    # invoked on this path. Without this line a dry run prints a confident
    # first-time-proposal preview and no refusal at all.
    echo "  base unresolved — preview assumes an EMPTY base; a real run would be refused until --base resolves"
  fi
  for entry in "${manifest_entries[@]}"; do
    entry_path="$(jq -r '.path' <<<"$entry")"
    entry_content="$(jq -r '.content' <<<"$entry")"
    if [ -n "$base_ref" ]; then
      if ! base_has "$entry_path"; then
        echo "  would create: $entry_path"
      elif [ "$(base_show "$entry_path")" = "$entry_content" ]; then
        echo "  unchanged:    $entry_path"
      else
        echo "  would update: $entry_path"
      fi
    else
      entry_abs="$repo_dir/$entry_path"
      if [ ! -e "$entry_abs" ]; then
        echo "  would create: $entry_path (vs. local tree — base unresolved)"
      elif [ "$(cat "$entry_abs" 2>/dev/null)" = "$entry_content" ]; then
        echo "  unchanged:    $entry_path (vs. local tree — base unresolved)"
      else
        echo "  would update: $entry_path (vs. local tree — base unresolved)"
      fi
    fi
  done
  outcome="DRY_RUN"
  echo
elif [ "$no_network" -eq 1 ]; then
  # --no-network GATE (temperloop#969): the SAME gate Step 2's first-epic
  # offer already applies (`elif [ "$no_network" -eq 1 ]` -> one skip line,
  # then carry on), applied to the one remaining step that reaches the
  # network. Before this arm existed the flag suppressed Step 2 and NOT
  # this one, so `temperloop init --no-network` in a remote-less repo ran
  # proposal-pr.sh anyway, which force-created and switched to $branch,
  # committed onto it, and only THEN died on `git push` — surfacing a raw
  # `fatal: 'origin' does not appear to be a git repository`, exiting
  # non-zero through the `proposal_rc` check below, and never reaching the
  # Step 4/5 summary + handoff. A stranger was left on an unfamiliar
  # branch with a git error and no recovery guidance, from a flag whose
  # name promises the opposite.
  #
  # WHOLE-STEP SKIP, not a push-only suppression. proposal-pr.sh has no
  # "commit locally but do not push" mode other than its own --dry-run,
  # and taking that route would still leave the checkout parked on
  # $branch — i.e. it would fix the error message and keep the branch half
  # of the reported harm. Skipping the invocation outright is both the
  # shape Step 2 already uses and the only shape that leaves the operator
  # where they started.
  #
  # DEGRADATION-NOTICE SHAPE: the kernel's `skipped — <what>` form, worded
  # to match conventions-probe.sh's own network-gated skips ("skipped —
  # network disabled (--no-network)") so one vocabulary covers every
  # network-gated step of a run. It deliberately keeps the `skipped — `
  # prefix .github/workflows/install-tier2.yml content-scans for: this IS
  # a degraded step, unlike the deprecated-flag notices above.
  echo "skipped — network disabled (--no-network): no proposal branch, no commit, no push, no PR — re-run without --no-network to open the tree-only proposal PR for $config_rel"
  outcome="NO_NETWORK"
  echo
else
  proposal_args=(open --repo-dir "$repo_dir" --branch "$branch" --title "$title" \
    --body "$body" --files-manifest - --remote "$remote" --force)
  # ALWAYS pass the base we resolved (never leave the generator to work it
  # out again): $base is filled in above from init_default_branch() when the
  # caller gave no --base, so this now pins the generator to the SAME ref the
  # manifest decisions above were made against. Two independent resolvers
  # drifting apart is exactly how a manifest gets diffed against a different
  # tree than the one it was decided from. Still conditional only for the
  # unresolvable-base case, which proposal-pr.sh refuses on its own terms.
  [ -n "$base" ] && proposal_args+=(--base "$base")

  # --- recovery marker (temperloop#414) ------------------------------------
  # proposal-pr.sh's own `git checkout -B "$branch" ...` (inside the call
  # below) is the ONLY branch switch in this whole script — a run that dies
  # anywhere from here on (a killed process, a failed push, a failed `gh pr
  # create`) leaves the checkout sitting on $branch with no further trace of
  # what branch to return to once the process is gone. Record it BEFORE the
  # switch, as untracked (gitignored) recovery state under .temperloop/ — the
  # exact same directory `temperloop eject` already owns cleaning up. Cleared
  # right below the instant the switch is known to have succeeded (whatever
  # its outcome — NO_CHANGES/PR_OPENED/EXISTS all mean "this branch is now
  # intentional", not a stray leftover); a run that never reaches that point
  # leaves the marker in place for `temperloop eject` (or a later `init` run
  # from the very same branch) to act on. Skipped when already on $branch
  # (nothing to protect against) or HEAD is detached (nothing named to
  # restore to).
  if [ -n "$orig_branch" ] && [ "$orig_branch" != "$branch" ]; then
    mkdir -p "$repo_dir/.temperloop" 2>/dev/null
    jq -cn --arg orig "$orig_branch" --arg prop "$branch" \
      '{original_branch:$orig, proposal_branch:$prop}' \
      > "$repo_dir/.temperloop/.recovery.json" 2>/dev/null || true
    gi_path="$repo_dir/.temperloop/.gitignore"
    if [ -f "$gi_path" ]; then
      grep -Fxq ".recovery.json" "$gi_path" 2>/dev/null || printf '%s\n' ".recovery.json" >> "$gi_path"
    else
      printf '%s\n' ".recovery.json" > "$gi_path"
    fi
  fi

  manifest_json="$(printf '%s\n' "${manifest_entries[@]}" | jq -sc '.')"
  proposal_out="$(printf '%s' "$manifest_json" | bash "$PROPOSAL" "${proposal_args[@]}")"
  proposal_rc=$?
  echo "$proposal_out" | jq '.' 2>/dev/null || echo "$proposal_out"
  if [ "$proposal_rc" -ne 0 ]; then
    echo "init.sh: proposal-pr.sh failed (exit $proposal_rc)" >&2
    exit "$proposal_rc"
  fi
  rm -f "$repo_dir/.temperloop/.recovery.json" 2>/dev/null || true
  outcome="$(jq -r '.outcome // "ERROR"' <<<"$proposal_out" 2>/dev/null || echo ERROR)"
  echo

  # --- bootstrap-ordering second pass: fold THIS run's own PR record into
  # the config that actually lands, once the PR outcome is known (see the
  # header note "BOOTSTRAP ORDERING NOTE"). Skipped for NO_CHANGES — there
  # is no PR to describe. (DRY_RUN can no longer reach this branch at all
  # — see the --dry-run arm above, which returns its own synthetic
  # "DRY_RUN" outcome without ever calling proposal-pr.sh.) --------------
  if [ "$outcome" = "PR_OPENED" ] || [ "$outcome" = "EXISTS" ]; then
    pr_url="$(jq -r '.url // empty' <<<"$proposal_out")"
    pr_number="$(jq -r '.pr_number // empty' <<<"$proposal_out")"
    pr_entry="$(jq -cn --arg branch "$branch" --arg url "$pr_url" --arg n "${pr_number:-}" \
      '{type:"proposal_pr", branch:$branch, pr_number:(if $n == "" then null else ($n|tonumber) end), url:$url}')"
    all_installs2="$(jq -c -n --argjson a "$all_installs" --argjson b "[$pr_entry]" \
      '($a + $b) | unique_by([.type, (.name // ""), (.branch // ""), (.repo // ""), (.url // "")])')"
    config_json2="$(build_config_json "$all_installs2")"
    manifest_entries[0]="$(jq -cn --arg p "$config_rel" --arg c "$config_json2" '{path:$p, content:$c}')"
    manifest_json2="$(printf '%s\n' "${manifest_entries[@]}" | jq -sc '.')"

    echo "-- config self-record pass (folds this run's own PR into $config_rel) --"
    proposal_out2="$(printf '%s' "$manifest_json2" | bash "$PROPOSAL" "${proposal_args[@]}")"
    echo "$proposal_out2" | jq '.' 2>/dev/null || echo "$proposal_out2"
    echo
  fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo "-- 4. Summary --"
echo "tracker mode: $tracker_mode (board $board_num)"
echo "boards.conf entry:"
printf '%s\n' "$boards_conf_entry" | sed 's/^/  /'
echo "config: $config_rel"
echo

# --- the handoff (temperloop#796; box framing + lastness temperloop#781) --
# `init`'s job ends HERE: bootstrap + propose + offer the first epic + hand
# off. It applies no API state of its own — the epic does, under its own
# per-write consent.
#
# `next step:` is the stable marker .github/workflows/install-tier2.yml
# greps to prove the live round trip actually reached the handoff, and
# test_init.sh pins its exact prefix — it stays a single, unindented,
# never-wrapped line with that literal prefix. Everything else below is
# framing AROUND it (never folded into a box border): a banner making the
# "not finished" framing visually distinct, an epic-specific launch block
# printed only when $handoff_epic_num is set (both the fresh-filed and the
# idempotent already-filed call sites route through _init_set_handoff, so
# an operator who lost the first run's scrollback gets the same recovery
# instruction on a re-run), and a trailing "what happens next" line.
#
# `temperloop init: done` prints BEFORE this block, not after — the
# handoff, not that marker, must be the true last thing this script prints
# (temperloop#781 acceptance: nothing printed after the handoff).
echo "temperloop init: done"
echo
echo "-- 5. Handoff --"
echo "================================================================"
echo "  CONFIGURATION IS NOT FINISHED — one step remains"
echo "================================================================"
echo
echo "\`temperloop init\` created the plan of work; it did not apply it."
echo
# Cost disclosure, named BEFORE the /assess handoff below (temperloop#1130,
# spike temperloop#1348) — a separate line, never folded into `next step:`,
# which .github/workflows/install-tier2.yml greps verbatim and which this
# script's own tests pin the exact prefix of (see the comment above this
# block). `temperloop testbed`/`temperloop init` are verified $0 (no
# `claude` invocation in either path); `/assess`/`/build` run in your own
# interactive `claude` session, not a capped headless call, so
# `--max-budget-usd` has nothing to attach to and there is no tool-enforced
# dollar ceiling from here on.
echo "cost: \`temperloop testbed\` and \`temperloop init\` spent \$0 (no"
echo "  Claude invocation runs in either path). From here on — \`/assess\`,"
echo "  \`/build\` — there is no tool-enforced dollar ceiling: those run in"
echo "  your own interactive Claude Code session, not a capped headless"
echo "  call. See docs/cost-and-autonomy.md for the full breakdown before"
echo "  you proceed."
if [ -n "$handoff_epic_num" ]; then
  echo
  echo "Launch Claude Code in this repo:"
  echo
  echo "    claude"
  echo
  echo "Then run the exact invocation below:"
  echo
  echo "    /assess --epic $handoff_epic_num"
  echo
  echo "Epic: $handoff_epic_url"
fi
echo
echo "next step: ${handoff_next:-$handoff_unoffered}"
[ -n "$handoff_prereq" ] && echo "prerequisite: $handoff_prereq"
if [ -n "$handoff_epic_num" ]; then
  echo
  echo "What happens next: /assess decomposes the epic into a reviewable plan;"
  echo "/build then applies that plan, with your review at each step."
fi
echo "================================================================"
exit 0
