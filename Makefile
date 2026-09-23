# temperloop Makefile — standalone subset of foundation's Makefile (F#803).
# Every recipe body here is copied verbatim from foundation's own Makefile for
# the kernel-classified targets scripts/quality-gates.sh's KERNEL_GATES invoke,
# plus the docs generator. Kernel content is now authored directly in this repo
# and vendored downstream via update-kernel.sh's git-subtree pull — hand edits
# inside a vendored kernel/ copy are forbidden; change kernel content here.
SHELL := /bin/bash
FOUNDATION := $(shell pwd)
BOARD_SRC := $(FOUNDATION)/workflows/scripts/board
BUILD_SRC := $(FOUNDATION)/workflows/scripts/build
PROBE_SRC := $(FOUNDATION)/workflows/scripts/probe
DEMO_SRC := $(FOUNDATION)/workflows/scripts/demo
PROPOSAL_SRC := $(FOUNDATION)/workflows/scripts/proposal
PROMOTE_SRC := $(FOUNDATION)/workflows/scripts/promote
BIN_SRC := $(FOUNDATION)/bin
HOOKS_SRC := $(FOUNDATION)/claude/hooks
TESTBED_SRC := $(FOUNDATION)/workflows/scripts/testbed

.PHONY: help shellcheck quality-gates test-board test-build test-build-workflow \
	test-hooks test-install test-install-links test-install-worktree-guard test-testbed-record \
	test-prune-branches validate-capture-backstop validate-activation-registry validate-mandatory-step-signal validate-onramp-anchors validate-command-run-emit validate-issue-touch-emit \
	validate-resume-recovery-emit \
	validate-knowledge-search-emit validate-diagnose-queue-emit \
	validate-lexicon validate-template-refs test-scan-stub test-vault-hygiene test-tally-findings test-findings-integrity test-model-comparison-stats test-env-hygiene-report lint-pr-body-test test-stranger-config \
	test-kernel-manifest test-kernel-denylist test-kernel-gitleaks test-kernel-prerename test-kernel-terminology test-pr-leak-guard test-producer-egress docs \
	test-docs-generator test-conventions-probe test-demo test-proposal-pr guard-install-worktree test-cli-subcommands test-testbed-source \
	test-testbed-command test-promote-push test-testbed-equivalence test-candidate-session \
	validate-clean-host-ks-search macos-gate-timing-report

help:
	@echo "Targets:"
	@echo "  quality-gates          Run the full static gate set (= CI's checks job)"
	@echo "  shellcheck              Whole-tree shellcheck (production + hook scripts)"
	@echo "  test-board              Board toolkit tests"
	@echo "  test-build              Build deterministic-machinery toolkit tests"
	@echo "  test-build-workflow     build-level.mjs offline harness"
	@echo "  test-hooks              Claude Code hook tests"
	@echo "  test-install            install-settings reconcile test"
	@echo "  test-install-links      install-links helper tests"
	@echo "  test-install-worktree-guard  Canonical-checkout guard tests"
	@echo "  test-testbed-record     Machine-scoped testbed artifact record tests"
	@echo "  test-prune-branches     prune-merged-branches.sh tests"
	@echo "  validate-capture-backstop     Capture/Backstop pairing registry lint"
	@echo "  validate-activation-registry  Class-A static-second-surface activation registry lint"
	@echo "  validate-mandatory-step-signal  Mandatory-step birth rule: declaration <-> execution-signal registry lint"
	@echo "  validate-onramp-anchors  On-ramp anchor-registry lint (ADR 0024)"
	@echo "  validate-command-run-emit  emit-command-run.sh presence/wiring lint"
	@echo "  validate-issue-touch-emit  emit-issue-touch.sh presence/wiring lint"
	@echo "  validate-resume-recovery-emit  emit-resume-recovery.sh presence/wiring lint"
	@echo "  validate-knowledge-search-emit  ks_search read-log outcome-field presence/wiring lint"
	@echo "  validate-lexicon        drain-mind tell-lexicon lint"
	@echo "  validate-template-refs  Message-template reference-integrity + registry-completeness lint"
	@echo "  test-scan-stub          Session-stub scanner tests"
	@echo "  test-model-comparison-stats  Comparison-statistics library tests"
	@echo "  lint-pr-body-test       PR-body issue-linkage lint tests"
	@echo "  test-stranger-config    Kernel-portability seam integration test"
	@echo "  test-kernel-manifest    kernel-manifest.txt coverage check"
	@echo "  test-kernel-denylist    Personal-token denylist check"
	@echo "  test-kernel-gitleaks    gitleaks secret scan over the kernel set"
	@echo "  test-kernel-prerename   Pre-rename (foundation->temperloop) identifier leak-gate sweep"
	@echo "  test-kernel-terminology v0.17.0 terminology-rename identifier leak-gate sweep"
	@echo "  test-pr-leak-guard      Diff-scoped public-repo leak guard (PR added lines)"
	@echo "  test-producer-egress    Egress lint over the Epic E value-loop producers"
	@echo "  docs                    Render the generated docs site"
	@echo "  test-docs-generator     Docs generator unit tests"
	@echo "  test-conventions-probe  Conventions-probe (read-only repo-convention detector) tests"
	@echo "  test-demo               Demo-repo seed script tests"
	@echo "  test-proposal-pr        Proposal-PR generator (tree-diff -> reviewable PR) tests"
	@echo "  test-cli-subcommands    bin/subcommands/ CLI subcommand tests"
	@echo "  test-testbed-source     Testbed source-provider seam + mirror-from-repo tests"
	@echo "  test-testbed-command    'temperloop testbed' one-command evaluation-build tests"
	@echo "  test-promote-push       /promote's commit-carrying branch-push tests"
	@echo "  test-testbed-equivalence  Provider-equivalence guard: identical driver call sequence, both providers"
	@echo ""
	@echo "Opt-in, NEVER run by a gate or by CI (needs Docker + network):"
	@echo "  validate-clean-host-ks-search  Stranger first-run ks_search validation in a clean Linux container"
	@echo ""
	@echo "Opt-in reports, NEVER run by a gate or by CI (read committed data only):"
	@echo "  macos-gate-timing-report  Recompute docs/validation/macos-ci-gate-timing.md's tables"

# Canonical-checkout guard (foundation #509): refuses to run from a linked git
# worktree unless FORCE_REHOME=1. Not wired into any target below today (no
# install-* target ships in this standalone Makefile yet) — kept for parity
# with foundation's own Makefile and for a future install-* target to depend
# on without reintroducing the guard logic.
guard-install-worktree:
	@bash -c ' \
		if [ -n "$${FORCE_REHOME:-}" ]; then exit 0; fi; \
		_common="$$(git rev-parse --git-common-dir 2>/dev/null)" || exit 0; \
		_gitdir="$$(git rev-parse --absolute-git-dir 2>/dev/null)" || exit 0; \
		_common_abs="$$(cd "$$_common" && pwd)"; \
		_gitdir_abs="$$(cd "$$_gitdir" && pwd)"; \
		if [ "$$_common_abs" != "$$_gitdir_abs" ]; then \
			_canonical="$$(dirname "$$_common_abs")"; \
			echo "make: refusing to install from a git worktree ($$PWD)." >&2; \
			echo "  Run from the canonical checkout: $$_canonical" >&2; \
			echo "  Set FORCE_REHOME=1 to override." >&2; \
			exit 1; \
		fi \
	'

# test-board runs every tests/test_*.sh via a glob rather than mirroring
# foundation's explicit list — a static copy of that list goes stale the
# moment foundation registers a new board test (F#836: the pre-glob heredoc
# silently skipped test_issues_backend.sh in kernel CI). The glob matches
# whatever tests are actually vendored, so kernel coverage can never trail
# the tree it ships.
# `env -u TMUX -u TMUX_PANE -u CMUX_WORKSPACE_ID` is a CONTAINMENT rail, not a
# convenience (temperloop#1037): several of these tests drive the real
# claim-marker helpers, and those helpers are no-ops outside a multiplexer. Run
# from inside the operator's own tmux session — which is how a kernel dev runs
# them — a test that misses an isolation seam brands or clears a REAL window on
# the shared server. That is not hypothetical: a board test's `#502 Claim target`
# fixture leaked into the live tmux server and sat in the operator's status bar
# for over a month. Stripping the multiplexer environment at the runner makes the
# whole suite structurally unable to reach it, whatever an individual test forgot.
test-board:
	@echo "==> Running board toolkit tests..."
	@for t in $(BOARD_SRC)/tests/test_*.sh; do \
		if out="$$(env -u TMUX -u TMUX_PANE -u CMUX_WORKSPACE_ID bash "$$t" 2>&1)"; then echo "  [ok] $$(basename $$t)"; else echo "  [FAIL] $$(basename $$t)"; printf '%s\n' "$$out" | sed 's/^/      /'; exit 1; fi; \
	done

# WALL-CLOCK BOUND (temperloop#2184). This target and test-build-workflow
# below both run through workflows/scripts/build/bounded-suite.sh: neither had
# any bound, so a hang inside a test ran forever with nothing going red (the
# observed incident: ~50h and two orphaned process trees). The bound itself is
# the NAMED SETTING $$BUILD_SUITE_TIMEOUT_SECS (build.config.sh), never a
# literal in this recipe — see CLAUDE.kernel.md § Named-setting convention.
# The loop writes the test script it is about to run to $$SUITE_PROGRESS_FILE
# so a timeout report names the case that was RUNNING, not the last one that
# passed.
#
# NOT THE QUALITY GATE ANY MORE (temperloop#2162) — still a first-class local
# target, and still the execution signal four mandatory-step-registry.tsv rows
# name. `scripts/quality-gates.sh` used to carry `make test-build` as ONE gate,
# which meant 58 scripts running SERIALLY inside a single gate-pool slot the
# pool could never spread. It now glob-expands this same directory into one
# BOUNDED gate per script (`_qg_expand_case_gates`), so the split is in the
# gate list rather than here. Keep this recipe globbing the directory: the
# expansion reads the same glob, and the two must agree about what the suite
# IS. See docs/features/quality-gates.md § Parallel execution.
test-build:
	@echo "==> Running build toolkit tests..."
	@bash "$(BUILD_SRC)/bounded-suite.sh" --label test-build -- \
		bash -c 'for t in "$$1"/tests/test_*.sh; do \
			printf "%s\n" "$$(basename "$$t")" > "$${SUITE_PROGRESS_FILE:-/dev/null}"; \
			if out="$$(bash "$$t" 2>&1)"; then echo "  [ok] $$(basename "$$t")"; else echo "  [FAIL] $$(basename "$$t")"; printf "%s\n" "$$out" | sed "s/^/      /"; exit 1; fi; \
		done' _ "$(BUILD_SRC)"

# Bounded exactly like test-build above (temperloop#2184). --case-source lets
# the guard name the running case even for the suite's inline sections, which
# announce nothing until they pass.
test-build-workflow:
	@echo "==> Running build-level.mjs offline harness..."
	@bash "$(BUILD_SRC)/bounded-suite.sh" --label test-build-workflow \
		--case-source "$(BUILD_SRC)/tests/test_workflow.sh" \
		-- bash "$(BUILD_SRC)/tests/test_workflow.sh"

# Glob-based, same rationale as test-board above (F#836): kernel coverage
# can never trail whichever tests/test_*.sh files are actually vendored.
test-conventions-probe:
	@echo "==> Running conventions-probe tests..."
	@for t in $(PROBE_SRC)/tests/test_*.sh; do \
		if out="$$(bash "$$t" 2>&1)"; then echo "  [ok] $$(basename $$t)"; else echo "  [FAIL] $$(basename $$t)"; printf '%s\n' "$$out" | sed 's/^/      /'; exit 1; fi; \
	done

# Glob-based, mirroring test-board (F#836) — kernel coverage tracks
# whatever seed-content tests are actually vendored.
test-demo:
	@echo "==> Running testbed seed-content tests..."
	@for t in $(DEMO_SRC)/tests/test_*.sh; do \
		if out="$$(bash "$$t" 2>&1)"; then echo "  [ok] $$(basename $$t)"; else echo "  [FAIL] $$(basename $$t)"; printf '%s\n' "$$out" | sed 's/^/      /'; exit 1; fi; \
	done

# Glob-based, mirroring test-board (F#836) — kernel coverage tracks whatever
# proposal-pr tests are actually vendored.
test-proposal-pr:
	@echo "==> Running proposal-PR generator tests..."
	@for t in $(PROPOSAL_SRC)/tests/test_*.sh; do \
		if out="$$(bash "$$t" 2>&1)"; then echo "  [ok] $$(basename $$t)"; else echo "  [FAIL] $$(basename $$t)"; printf '%s\n' "$$out" | sed 's/^/      /'; exit 1; fi; \
	done

# Glob-based, same rationale as test-board/test-conventions-probe above
# (F#836): kernel coverage can never trail whichever tests/test_*.sh files
# are actually vendored.
#
# NAMED `test-cli-subcommands`, not `test-try` (temperloop#1117): this target
# has always globbed the WHOLE bin/subcommands/tests/ directory — init, eject,
# config, configure, report, feedback, uninstall, update, baseline-snapshot,
# dispatch-rename, prereq-scoping, report-offer, tokens-producer — and only
# incidentally carried try's name. Retiring `try` therefore RENAMES this gate
# rather than deleting it; deleting it would have silently dropped the sole
# runner for 13 unrelated suites.
#
# NOT THE QUALITY GATE ANY MORE (temperloop#2162), same as test-build above and
# for the same reason: as one gate it ran its whole glob serially inside a
# single gate-pool slot. scripts/quality-gates.sh now glob-expands this same
# directory into one BOUNDED gate per script. This recipe stays as the local
# runner, and stays glob-based — the expansion reads the same glob, and the two
# must agree about what the suite IS.
test-cli-subcommands:
	@echo "==> Running CLI subcommand tests..."
	@for t in $(BIN_SRC)/subcommands/tests/test_*.sh; do \
		if out="$$(bash "$$t" 2>&1)"; then echo "  [ok] $$(basename $$t)"; else echo "  [FAIL] $$(basename $$t)"; printf '%s\n' "$$out" | sed 's/^/      /'; exit 1; fi; \
	done

# Glob-based, mirroring test-board/test-demo (F#836): kernel coverage tracks
# whatever testbed tests are actually vendored.
test-testbed-source:
	@echo "==> Running testbed source-provider tests..."
	@for t in $(TESTBED_SRC)/tests/test_*.sh; do \
		if out="$$(bash "$$t" 2>&1)"; then echo "  [ok] $$(basename $$t)"; else echo "  [FAIL] $$(basename $$t)"; printf '%s\n' "$$out" | sed 's/^/      /'; exit 1; fi; \
	done

# Glob-based, mirroring test-board/test-testbed-source (F#836): kernel
# coverage tracks whatever /promote tests are actually vendored.
test-promote-push:
	@echo "==> Running /promote branch-push tests..."
	@for t in $(PROMOTE_SRC)/tests/test_*.sh; do \
		if out="$$(bash "$$t" 2>&1)"; then echo "  [ok] $$(basename $$t)"; else echo "  [FAIL] $$(basename $$t)"; printf '%s\n' "$$out" | sed 's/^/      /'; exit 1; fi; \
	done

test-hooks:
	@echo "==> Running hook tests..."
	@for t in $(HOOKS_SRC)/tests/test_*.sh; do \
		if out="$$(bash "$$t" 2>&1)"; then echo "  [ok] $$(basename $$t)"; else echo "  [FAIL] $$(basename $$t)"; printf '%s\n' "$$out" | sed 's/^/      /'; exit 1; fi; \
	done

shellcheck:
	@echo "==> shellcheck (production + hook scripts)..."
	@bash scripts/shellcheck-tree.sh

quality-gates:
	@bash $(FOUNDATION)/scripts/quality-gates.sh

validate-capture-backstop:
	@bash $(FOUNDATION)/workflows/scripts/validate-capture-backstop.sh

validate-activation-registry:
	@bash $(FOUNDATION)/workflows/scripts/validate-activation-registry.sh

validate-mandatory-step-signal:
	@bash $(FOUNDATION)/workflows/scripts/validate-mandatory-step-signal.sh

validate-onramp-anchors:
	@bash $(FOUNDATION)/workflows/scripts/validate-onramp-anchors.sh

validate-command-run-emit:
	@bash $(FOUNDATION)/workflows/scripts/validate-command-run-emit.sh

validate-issue-touch-emit:
	@bash $(FOUNDATION)/workflows/scripts/validate-issue-touch-emit.sh

validate-resume-recovery-emit:
	@bash $(FOUNDATION)/workflows/scripts/validate-resume-recovery-emit.sh

validate-diagnose-queue-emit:
	@bash $(FOUNDATION)/workflows/scripts/validate-diagnose-queue-emit.sh

validate-knowledge-search-emit:
	@bash $(FOUNDATION)/workflows/scripts/validate-knowledge-search-emit.sh

validate-lexicon:
	@bash $(FOUNDATION)/workflows/scripts/drain/validate-lexicon.sh

validate-template-refs:
	@bash $(FOUNDATION)/workflows/scripts/validate-template-refs.sh

test-kernel-manifest:
	@echo "==> Running kernel-manifest coverage check..."
	@bash $(FOUNDATION)/workflows/scripts/kernel/check-kernel-manifest.sh

docs:
	@python3 $(FOUNDATION)/workflows/scripts/docs/generate.py

test-docs-generator:
	@echo "==> Running docs generator tests..."
	@python3 -m unittest discover -s $(FOUNDATION)/workflows/scripts/docs/tests -t $(FOUNDATION)/workflows/scripts/docs -v

test-kernel-denylist:
	@echo "==> Running kernel personal-token denylist check..."
	@bash $(FOUNDATION)/workflows/scripts/kernel/check-personal-token-denylist.sh
	@echo "==> Running check-personal-token-denylist.sh fixture tests..."
	@bash $(FOUNDATION)/workflows/scripts/kernel/tests/test_check_personal_token_denylist.sh

test-kernel-gitleaks:
	@echo "==> Running kernel gitleaks scan..."
	@bash $(FOUNDATION)/workflows/scripts/kernel/check-gitleaks-kernel.sh

# Pre-rename identifier leak-gate sweep (temperloop#433): keeps a pre-rename
# foundation->temperloop identifier (temperloop#165 / PR #487) from silently
# re-entering a stranger surface — a closed, reviewed set of tokens/leaves
# (prerename-leak-verdicts.tsv) is all that's allowed; anything else fails.
test-kernel-prerename:
	@echo "==> Running pre-rename identifier leak-gate sweep..."
	@bash $(FOUNDATION)/workflows/scripts/kernel/check-prerename-leak-guard.sh
	@echo "==> Running check-prerename-leak-guard.sh fixture tests..."
	@bash $(FOUNDATION)/workflows/scripts/kernel/tests/test_check_prerename_leak_guard.sh

# v0.17.0 terminology-rename identifier leak gate (temperloop#729): keeps the
# renamed coined identifiers (the legacy env prefixes, the old script-file
# names, and the coined severity/pairing tokens) from silently re-entering a
# stranger surface — only the reviewed exempt set (compat window + records)
# may carry them; anything else fails.
test-kernel-terminology:
	@echo "==> Running terminology-rename identifier leak-gate sweep..."
	@bash $(FOUNDATION)/workflows/scripts/kernel/check-terminology-leak-guard.sh
	@echo "==> Running check-terminology-leak-guard.sh fixture tests..."
	@bash $(FOUNDATION)/workflows/scripts/kernel/tests/test_check_terminology_leak_guard.sh

# Diff-scoped public-repo leak guard (temperloop #74): scans the ADDED lines of
# a PR's diff (all tracked files) for personal/private tokens + secrets and
# fails the merge — the diff-scoped complement to the whole-tree
# denylist/gitleaks checks above. The live scan (against the current checkout's
# diff-vs-base) runs first and must be green; on push:main / no-base it skips
# cleanly. The fixture regression test then proves detection deterministically.
test-pr-leak-guard:
	@echo "==> Running diff-scoped PR leak guard against the current checkout..."
	@bash $(FOUNDATION)/workflows/scripts/kernel/check-pr-leak-guard.sh
	@echo "==> Running check-pr-leak-guard.sh fixture tests..."
	@bash $(FOUNDATION)/workflows/scripts/kernel/tests/test_check_pr_leak_guard.sh

# Mechanical egress lint over Epic E's before/after value-loop producers
# (foundation #766, privacy/egress audit item): greps the named producer
# scripts for network-call patterns beyond the one sanctioned `gh` channel.
# --overlay-report-d is passed (temperloop#958): this repo DOES now carry its
# own .temperloop/report.d/, holding the kernel's `tokens` spend producer, so
# that drop-in is scanned by the same lint as the named producers rather than
# being the one file in the loop nothing checks. The flag is a glob over
# whatever the dir holds, so a future drop-in is covered with zero
# maintenance here, and an absent dir is a silent, legible skip — the arg
# stays correct in a checkout that has none. See check-producer-egress.sh's
# header for the documented (today: empty) opt-in egress surface.
test-producer-egress:
	@echo "==> Running producer egress check..."
	@bash $(FOUNDATION)/workflows/scripts/kernel/check-producer-egress.sh --kernel-root $(FOUNDATION) --overlay-report-d $(FOUNDATION)/.temperloop/report.d
	@echo "==> Running check-producer-egress.sh fixture tests..."
	@bash $(FOUNDATION)/workflows/scripts/kernel/tests/test_check_producer_egress.sh

test-scan-stub:
	@echo "==> Running stub scanner tests..."
	@bash $(FOUNDATION)/workflows/scripts/drain/tests/test_scan_stub.sh

test-vault-hygiene:
	@echo "==> Running vault-hygiene probe tests..."
	@bash $(FOUNDATION)/workflows/scripts/drain/tests/test_vault_hygiene_report.sh

test-tally-findings:
	@echo "==> Running recent-findings tally tests..."
	@bash $(FOUNDATION)/workflows/scripts/drain/tests/test_tally_recent_findings.sh

test-findings-integrity:
	@echo "==> Running findings-integrity checker tests..."
	@bash $(FOUNDATION)/workflows/scripts/drain/tests/test_findings_integrity.sh

test-model-comparison-stats:
	@echo "==> Running comparison-statistics library tests..."
	@bash $(FOUNDATION)/workflows/scripts/model-comparison/tests/test_stats.sh

test-env-hygiene-report:
	@echo "==> Running env-hygiene-report wrapper tests..."
	@bash $(FOUNDATION)/workflows/scripts/tests/test_env_hygiene_report.sh

lint-pr-body-test:
	@echo "==> Running PR-body issue-linkage lint tests..."
	@bash $(FOUNDATION)/workflows/scripts/tests/test_lint_pr_body.sh

test-install:
	@echo "==> Running install-settings reconcile test..."
	@bash workflows/scripts/tests/test_install_settings.sh

test-install-links:
	@echo "==> Running install-links tests..."
	@bash workflows/scripts/tests/test_install_links.sh

test-install-worktree-guard:
	@echo "==> Running install-worktree-guard tests..."
	@bash workflows/scripts/tests/test_install_worktree_guard.sh

test-testbed-record:
	@echo "==> Running testbed-record tests..."
	@bash workflows/scripts/testbed/tests/test_testbed_record.sh

# `temperloop testbed` — the one-command evaluation build (temperloop#1229).
# Named explicitly rather than left to test-cli-subcommands'
# bin/subcommands/tests/*.sh glob: this suite is the FIRST consumer of BOTH
# Level 0 testbed seams, so it must also be selected when
# workflows/scripts/testbed/** changes — which test-cli-subcommands'
# `bin/**`-scoped gate-paths row cannot express. Same
# named-target/globbed-target overlap test-testbed-record already carries with
# test-testbed-source, and for the same reason.
test-testbed-command:
	@echo "==> Running temperloop testbed subcommand tests..."
	@bash bin/subcommands/tests/test_testbed.sh

# Provider-equivalence guard (temperloop#1232, epic #1117): both source
# providers, driven through bin/subcommands/testbed.sh's own driver via test
# doubles, must produce ONE identical seam-call and driver-step sequence,
# modulo source identity. Named target (not riding test-testbed-source's
# glob, even though the test file lives under workflows/scripts/testbed/
# tests/ and IS also picked up there) because, like test-testbed-command, it
# is a consumer of BOTH the seam AND the driver script — its own
# gate-paths.tsv row is scoped to both, so a change to either re-runs it.
test-testbed-equivalence:
	@echo "==> Running testbed provider-equivalence tests..."
	@bash workflows/scripts/testbed/tests/test_provider_equivalence.sh

test-prune-branches:
	@echo "==> Running prune-merged-branches tests..."
	@bash scripts/tests/test_prune_merged_branches.sh

test-candidate-session:
	@echo "==> Running candidate-session (restricted candidate-model overlay + provider-key health check) tests..."
	@bash workflows/scripts/model-comparison/tests/test_candidate_session.sh

test-stranger-config:
	@echo "==> Running stranger-config test..."
	@bash scripts/tests/test_stranger_config.sh

# OPT-IN, MANUALLY INVOKED — deliberately NOT in scripts/quality-gates.sh's
# KERNEL_GATES and NOT in any .github/workflows/ job (temperloop#1635). It
# performs a REAL uv-tool install over the network inside a Docker container,
# which kernel principle 3 forbids in the gated suite. Run it by hand when the
# install path or its pins change; see the script's own usage header.
validate-clean-host-ks-search:
	@echo "==> Running the clean-host ks_search validation (Docker + network required)..."
	@bash workflows/scripts/dev/validate-clean-host-ks-search.sh

# OPT-IN REPORT, deliberately NOT a gate (temperloop#968). It recomputes every
# table in docs/validation/macos-ci-gate-timing.md from the per-gate datasets
# committed beside it, so that document's numbers are reproducible rather than
# taken on trust. Zero network, zero `gh`, deterministic — it is not in
# KERNEL_GATES because it re-derives a POINT-IN-TIME measurement, and a frozen
# measurement re-checked on every PR is gate cost with no signal.
macos-gate-timing-report:
	@bash workflows/scripts/dev/macos-gate-timing-report.sh
