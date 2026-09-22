#!/usr/bin/env bash
#
# env-reconcile.sh — READ-ONLY, FAIL-OPEN environment reconciler (#172).
#
# Enumerates every local checkout / worktree / launchd agent BY ROLE and
# classifies drift against that role's own definition of "clean". This is
# the shared detection substrate for the /tidy environment audit and (agent
# classes) foundation#1089 — it only REPORTS; it never mutates git, launchd,
# or any file outside its own stdout.
#
# ROLES + drift classes:
#
#   cron/kernel checkout   — must be clean-on-main. Drift:
#                              DIRTY        uncommitted changes present
#                              ON_BRANCH    HEAD is not the default branch
#                              BEHIND_MAIN  HEAD is behind the last-fetched
#                                           origin/<default> (checked against
#                                           whatever remote-tracking ref is
#                                           already on disk — this script
#                                           never fetches)
#                            Default checkouts: foundation.cron, the kernel
#                            checkout (temperloop), foundation-kernel (the
#                            pre-rename kernel checkout name some hosts still
#                            carry). Override: ENV_RECONCILE_CRON_CHECKOUTS
#                            (space-separated absolute paths).
#
#   operator/consumer      — may legitimately sit on a feature branch. Drift:
#   checkout                  PARKED_ON_MERGED  on a branch whose PR merged
#                              STALE_UNTRACKED   an untracked file older than
#                                                the staleness horizon
#                              STALE_VENDORED_HOOK:<hook>
#                                                the checkout's VENDORED copy of
#                                                a guard hook
#                                                (.claude/hooks/<hook>) differs
#                                                from this kernel's canonical
#                                                claude/hooks/<hook> — i.e. the
#                                                consumer is running an
#                                                out-of-date guard. See the
#                                                "Vendored-hook drift" block
#                                                below for the comparison
#                                                contract and the remedy.
#                              COMPOSED_STALE:<input>
#                                                the composed ~/.claude/CLAUDE.md
#                                                (a real generated FILE, never a
#                                                symlink — `make doctor` cannot
#                                                see it) is OLDER, by mtime, than
#                                                one of its named inputs
#                                                (claude/CLAUDE.kernel.md,
#                                                claude/CLAUDE.overlay.md,
#                                                workflows/scripts/build/build.config.sh)
#                                                under the checkout named by
#                                                ENV_RECONCILE_CLAUDE_MD_SOURCE_CHECKOUT
#                                                — i.e. the host is serving a
#                                                stale, silently-superseded set
#                                                of rules to every session. NOT
#                                                per-checkout like the classes
#                                                above: the composed file is a
#                                                single machine-wide artifact,
#                                                so this is checked once. See
#                                                the "Composed CLAUDE.md
#                                                staleness" block below for the
#                                                mtime-vs-cmp rationale and the
#                                                fail-open contract.
#                            Non-drift (informational):
#                              DORMANT:<days>d-idle:<n>-behind
#                                                the checkout is behind the
#                                                already-fetched origin/<default>
#                                                AND has had no local activity
#                                                (commit / pull / branch switch)
#                                                for more than
#                                                $DORMANT_CHECKOUT_DAYS days —
#                                                i.e. behind because ABANDONED,
#                                                not because it is busy on other
#                                                work. Printed on its own
#                                                `DORMANT` line, NEVER counted as
#                                                drift and never given a remedy:
#                                                disposing of an abandoned
#                                                checkout is the operator's call.
#                                                Being behind alone stays
#                                                deliberately un-flagged for this
#                                                role (that is the whole point of
#                                                the operator baseline); last
#                                                activity is what separates the
#                                                two. See
#                                                classify_operator_dormancy
#                                                (temperloop#2041).
#                            Default checkouts: foundation, stageFind,
#                            ssmobile, subsetwiki, temperloop (the interactive
#                            operator checkout of the kernel repo — a DIFFERENT
#                            ROLE of the same repo as the cron checkout above at
#                            $HOME/dev/batch/temperloop). Override:
#                            ENV_RECONCILE_OPERATOR_CHECKOUTS.
#
#   worktree <repo>.wt/<slug> — disposable. Drift (THREE classes, and only the
#                            first is safe for a consumer to auto-remove —
#                            temperloop#658):
#                            LEAKED_WORKTREE:<reason>
#                                              its ACTUAL branch (read from
#                                              git's own worktree record, never
#                                              guessed from the directory name)
#                                              is gone / merged / on a closed
#                                              PR, or the directory is ORPHANED
#                                              (not a worktree the parent repo
#                                              has registered) — AND the
#                                              worktree is CLEAN, so removing it
#                                              destroys nothing.
#                            DIRTY_WORKTREE:<reason>
#                                              the same leak reason held, but
#                                              `git status --porcelain` in the
#                                              worktree is non-empty: it carries
#                                              uncommitted work. REPORT ONLY —
#                                              never auto-removed, whatever the
#                                              reason says.
#                            UNCERTAIN_WORKTREE:<reason>
#                                              the classification could not be
#                                              ESTABLISHED — the worktree is
#                                              detached / its branch is
#                                              unresolvable (BRANCH_UNRESOLVED),
#                                              or its cleanliness could not be
#                                              probed (an unregistered ORPHANED
#                                              directory, or a BRANCH_GONE
#                                              worktree whose deleted ref leaves
#                                              `git status` no base to diff
#                                              against — see
#                                              _worktree_dirt_state). REPORT
#                                              ONLY. An undetermined verdict is
#                                              never a licence to remove.
#                            Scanned beside every cron+operator checkout
#                            above (the deterministic `<repo>.wt/` layout
#                            worktree.sh itself uses).
#
#                            Why the split (temperloop#658): this classifier
#                            used to assume every `<repo>.wt/<slug>` worktree
#                            sat on `build/<slug>`, the naming convention
#                            worktree.sh happens to use. A worktree created by
#                            hand on any other prefix — the `fix/…` isolated
#                            worktree the kernel's own § Working-tree ownership
#                            rule PRESCRIBES for cross-repo work — resolved to a
#                            branch name that had never existed, so `show-ref`
#                            missed and a live worktree reported
#                            LEAKED_WORKTREE:BRANCH_GONE. /tidy's env-hygiene
#                            auto-heal then force-removed it, destroying
#                            uncommitted work with no recovery (observed
#                            2026-07-21). Classify from the real signal — git's
#                            own branch record — and downgrade to a report-only
#                            class whenever the tree is dirty or the verdict is
#                            unestablished.
#
#   harness agent worktree   <checkout>/.claude/worktrees/agent-<id> — the
#   (temperloop#1405)        SECOND worktree layout, created by Claude Code's
#                            own agent isolation (`isolation: "worktree"`)
#                            INSIDE the checkout, untracked, on a machine-made
#                            `worktree-agent-<id>` branch with no PR behind it.
#                            Its own named class, ONE token, four reasons:
#                            HARNESS_WORKTREE:ACTIVE
#                                              younger than
#                                              $STALE_UNTRACKED_DAYS — an agent
#                                              may still be working in it.
#                                              Reported on its own `HARNESS`
#                                              line, NEVER counted as drift.
#                            HARNESS_WORKTREE:STALE
#                                              past the horizon and CLEAN — the
#                                              only removable one. Its finding
#                                              carries the exact removal command
#                                              (directory AND the leftover
#                                              branch).
#                            HARNESS_WORKTREE:STALE_DIRTY
#                            HARNESS_WORKTREE:STALE_UNCERTAIN
#                                              past the horizon but carrying
#                                              uncommitted work / unprobeable.
#                                              REPORT ONLY, same rule as
#                                              DIRTY_WORKTREE above.
#                            Scanned under every cron+operator checkout that
#                            HAS a $HARNESS_WT_SUBDIR directory (a checkout can
#                            host these without ever having had a <repo>.wt/).
#
#                            Why a class of its own, not a reason folded into
#                            the three above: nothing reaps these, their branch
#                            never had a PR, and the remedy differs — so the
#                            operator needs to know WHICH kind of worktree they
#                            are looking at. Before this, they were not scanned
#                            at all and instead surfaced as the parent
#                            checkout's opaque `DIRTY` / `STALE_UNTRACKED:
#                            .claude/worktrees/` — a remedy-less class that told
#                            a reader something was there but not what to do,
#                            and MASKED any real drift beside it (both observed
#                            live 2026-08-13). Those parent-level classes now
#                            exclude this path (_status_porcelain_sans_harness)
#                            precisely BECAUSE it is classified here; every
#                            other dirty path still reports DIRTY.
#   job scratch <root>/<id>/tmp — regenerable background-job scratch
#                            (temperloop#1111). The same "disposable by
#                            definition" role as a worktree, one layer down:
#                            the harness's job dir holds a run RECORD
#                            (state.json, timeline.jsonl, ~140KB) beside a
#                            tmp/ tree workers fill with DerivedData and eval
#                            corpora — 100% regenerable, and reclaimed by
#                            nothing until this class existed (two job dirs
#                            held 38.5GB and took the root volume to 0 bytes
#                            free). Drift:
#                              JOB_SCRATCH_RECLAIMABLE:<id>:<MB>MB:<state>
#                                              terminal job, past its grace
#                                              window, scratch over the size
#                                              floor — safe to delete
#                              JOB_SCRATCH_ABANDONED:<id>:<MB>MB:<state>
#                                              big scratch under a job that is
#                                              NOT terminal (or whose state is
#                                              unreadable) and has been idle
#                                              past the abandoned horizon —
#                                              REPORT-ONLY, never auto-deleted
#                            Classification is delegated verbatim to
#                            lib/job-scratch.sh, so this reconciler and the
#                            mutating job-scratch-reclaim.sh can never disagree
#                            about what is safe to delete — and this file stays
#                            READ-ONLY as promised above. Override:
#                            JOB_SCRATCH_ROOT (plus the floor/window settings
#                            in that lib's own header).
#
#   launchd agent            each infra/launchd/*.plist declared beside a
#                            checkout above. Drift:
#                              AGENT_UNLOADED  declared AND installed on THIS
#                                              host, but not in `launchctl list`
#                              AGENT_STALE     loaded, but its heartbeat marker
#                                              is older than its cadence (no
#                                              successful run within cadence)
#                              AGENT_CHECKOUT_BEHIND:<dir>
#                                              the plist's declared
#                                              WorkingDirectory resolves to a
#                                              git checkout whose HEAD is
#                                              behind the already-fetched
#                                              origin/<default> (#1624: a
#                                              merged fix can close its issue,
#                                              move its board item to Done,
#                                              and still never reach the
#                                              nightly that actually runs
#                                              from a stale checkout). Reuses
#                                              _behind_origin_default — the
#                                              same default_branch_of ->
#                                              merge-base --is-ancestor
#                                              mechanism BEHIND_MAIN uses
#                                              below, never a fetch. FAIL-OPEN:
#                                              an absent WorkingDirectory key,
#                                              a non-existent path, or a path
#                                              that isn't a git checkout prints
#                                              nothing ("can't verify") rather
#                                              than a crash or a false BEHIND
#                                              claim — see classify_agent_checkout.
#                            Non-drift (informational):
#                              EXPECTED_ELSEWHERE  declared, but this host does
#                                              not own the agent (not installed
#                                              here / not in ENV_RECONCILE_AGENT_HOSTS)
#                                              — the agent host owns it, so its
#                                              not-loaded state is NOT this
#                                              host's drift (#531).
#                            Override: ENV_RECONCILE_LAUNCHD_DIRS
#                            (space-separated dirs to glob *.plist in).
#                            Heartbeat convention (#1173): freshness is judged
#                            from a marker the job writes on SUCCESS, at
#                            $AGENT_HEARTBEAT_DIR/<label>.ran — NEVER from
#                            StandardOutPath's mtime, which launchd touches on
#                            every wake (incl. a wake that aborts having done
#                            nothing). A marker-less agent is reported as
#                            freshness-unknown (nothing emitted), not STALE.
#
# Usage:
#   env-reconcile.sh [--format report|entry]
#
#   --format report   human-readable table + summary (default)
#   --format entry    a `### … Status: open` vault block (modeled on
#                      drain/vault_hygiene_report.sh --format entry) —
#                      emits NOTHING and exits 0 when no drift is found
#
# Library surface (also SOURCEABLE — `source env-reconcile.sh` with no args
# defines the functions below and populates OPERATOR_CHECKOUTS without running
# the reconciler; see the direct-invocation guard ahead of "Main enumeration"):
#   OPERATOR_CHECKOUTS      array — the resolved consumer-checkout registry
#                            (DEFAULT_OPERATOR_CHECKOUTS, or the
#                            ENV_RECONCILE_OPERATOR_CHECKOUTS override) — the
#                            single source of truth for "which checkouts are
#                            kernel consumers", reused (not re-listed) by
#                            /check-in's class-B cross-repo-propagation
#                            discharge (claude/commands/check-in.md).
#   is_kernel_checkout <c>   true iff <c> IS the kernel repo itself (ships
#                            claude/CLAUDE.kernel.md, not claude/CLAUDE.overlay.md
#                            — see the function's own header for the matched site).
#   kernel_pin_tag_of <c>    prints checkout <c>'s installed kernel tag, read
#                            from its own `.kernel-pin` `tag` line; exits 1
#                            (prints nothing) if absent — "not yet reached".
#                            EXCEPTION: when <c> is the kernel repo itself
#                            (is_kernel_checkout), which has no `.kernel-pin`
#                            by construction, the tag is instead the nearest
#                            release tag reachable from <c>'s own HEAD (see
#                            the function's own header, #1333).
#   semver_ge <a> <b>        prints `true`/`false` for a numeric (not
#                            lexical) `vMAJOR.MINOR.PATCH` compare.
#   agent_status_by_label <l> looks up the launchd agent declaring Label <l>
#                            across the resolved LAUNCHD_DIRS registry and
#                            prints classify_agent's verdict for it —
#                            `AGENT_STALE:<l>` / `AGENT_UNLOADED:<l>` / empty
#                            (fresh) — reused (not reinvented) by /check-in's
#                            class-C launchd-sub-case discharge
#                            (claude/commands/check-in.md). Exits 1 (prints
#                            nothing) if no plist declaring <l> is found —
#                            "can't verify", never a crash.
#
# Env overrides (all optional; space-separated path lists unless noted):
#   ENV_RECONCILE_CRON_CHECKOUTS
#   ENV_RECONCILE_OPERATOR_CHECKOUTS
#   ENV_RECONCILE_LAUNCHD_DIRS
#   ENV_RECONCILE_STALE_UNTRACKED_DAYS      (default 7 — also the staleness
#                                            horizon for a harness agent
#                                            worktree, ACTIVE vs STALE)
#   ENV_RECONCILE_DORMANT_DAYS              (default 14 — days with no local
#                                            activity before a BEHIND operator
#                                            checkout is called DORMANT;
#                                            informational, never drift)
#   ENV_RECONCILE_HARNESS_WT_SUBDIR         (default .claude/worktrees — the
#                                            checkout-relative directory the
#                                            harness creates its agent
#                                            worktrees under, #1405. No
#                                            trailing slash.)
#   ENV_RECONCILE_AGENT_HEARTBEAT_DIR       (default $XDG_STATE_HOME/foundation/
#                                            agent-heartbeat — dir of <label>.ran
#                                            markers the jobs write on success)
#   ENV_RECONCILE_AGENT_DEFAULT_CADENCE_S   (default 86400 — used when a
#                                            plist declares no StartInterval)
#   ENV_RECONCILE_AGENT_HOSTS               (host-role override, #531 — space-
#                                            separated host labels that OWN the
#                                            launchd/cron role; compared against
#                                            ${SUBSET_HOST_LABEL:-hostname -s}.
#                                            When set, a host NOT in the list
#                                            reports its agents/cron checkouts as
#                                            EXPECTED_ELSEWHERE. When UNSET, the
#                                            install-marker auto-detect below is
#                                            used instead — no config needed.)
#   ENV_RECONCILE_AGENT_INSTALL_DIR         (default ~/Library/LaunchAgents — the
#                                            launchd user-agent install dir whose
#                                            plists mark which agents THIS host
#                                            actually runs, #531)
#   ENV_RECONCILE_CANONICAL_HOOK_DIR        (default <this repo>/claude/hooks —
#                                            the canonical hook source the
#                                            vendored copies are compared against)
#   ENV_RECONCILE_VENDORED_HOOKS            (default build-worktree-guard.sh —
#                                            space-separated hook basenames to
#                                            compare)
#   ENV_RECONCILE_CLAUDE_MD_SOURCE_CHECKOUT (unset by default — a SINGLE
#                                            checkout path naming which
#                                            checkout's claude/CLAUDE.*.md +
#                                            build.config.sh are the composed
#                                            ~/.claude/CLAUDE.md's "inputs".
#                                            UNSET means the check reports
#                                            UNVERIFIABLE rather than guessing
#                                            — see "Composed CLAUDE.md
#                                            staleness" below for why a guess
#                                            is unsafe here.)
#   ENV_RECONCILE_CLAUDE_MD_TARGET          (default $HOME/.claude/CLAUDE.md —
#                                            the composed file's own path;
#                                            overridable so tests never touch
#                                            a real ~/.claude)
#
# ── Vendored-hook drift (STALE_VENDORED_HOOK, foundation#1353 / F#932) ────────
# A guard hook is the source of truth HERE (claude/hooks/) and is push-synced
# into each consumer repo at .claude/hooks/<hook>, where it is registered in
# that repo's project-level .claude/settings.json. Nothing reported when a
# consumer's copy fell behind — so a consumer could keep running a guard whose
# protections the kernel has since widened, silently. That is exactly the F#932
# shape: the write-jail's matcher was `Edit|Write|MultiEdit` only, worker Bash
# was un-jailed, and a worker's `rm -rf "$(dirname "$(pwd)")"` deleted every
# checkout and the local knowledge store. The kernel grew a Bash arm; the
# consumers kept the pre-Bash-arm copy and nothing said so.
#
# Comparison contract:
#   - CONTENT comparison, never a version stamp. A stamp needs kernel-side
#     coordination to bump and can itself go stale (it says what the syncer
#     BELIEVED, not what the file IS); the bytes cannot lie. This is
#     deliberately a different mechanism from board-sync-drift-check.sh's
#     single-manifest SHA — that check runs inside a consumer's own CI against
#     an explicit expected SHA; this one runs on the operator's host with no
#     agreed reference but the canonical file itself.
#   - The sync stamps a provenance PREAMBLE onto its output: after the shebang
#     it injects THREE lines — the "# GENERATED by foundation '<cmd>' …" banner,
#     the "# Source of truth: …" note, and a bare "#" separator. All three are
#     EXCLUDED from the comparison (_hook_body is the injector's exact inverse)
#     — they are present by construction in every synced copy and absent from
#     the canonical file, so counting even ONE of them would make every
#     correctly-synced consumer permanently and unclearably "drifted".
#     ⚠️ The injector lives in the consumer-side fleet Makefile (foundation
#     Makefile:458) and this strip lives here in the kernel, with NOTHING
#     mechanically linking them — see _hook_body's own note; the in-sync test
#     fixture is deliberately built with the real injector so a shape change
#     fails the suite rather than silently false-alarming production.
#   - The remedy is read from the copy's OWN banner (which names the exact sync
#     command that produced it), VALIDATED to a bare `make <target>` shape, and
#     falls back to the generic engine invocation otherwise. No mapping table to
#     keep in sync with the fleet Makefile's wrappers. The named target lives in
#     that fleet repo, NOT in this kernel repo, so the remedy is rendered with
#     its run location.
#   - Which hooks are compared is ENV_RECONCILE_VENDORED_HOOKS. Renaming the
#     canonical hook without updating that list turns this check into a silent
#     no-op. That is the fail-open invariant working as specified (an
#     unresolvable reference must never manufacture drift), noted here so the
#     trade-off is visible rather than surprising.
#
# DETECTION ONLY. This class makes the staleness visible; auto-syncing a
# consumer on kernel merge (foundation#694) is the durable fix and is NOT
# duplicated here. Reporting — never healing — is also what the "aggressive
# in-lane, report cross-lane" environment-hygiene policy requires: a consumer
# checkout is a foreign lane, so its drift is surfaced for /check-in to dispose,
# never silently rewritten from under whichever session owns it.
#
# Deliberately NOT a `make doctor` check: doctor runs at every session start and
# its pinned contract is "doctor non-zero → run `make install` to heal". A stale
# hook in a FOREIGN checkout is not healable by `make install` (that would be a
# foreign-tree write), so a doctor class here would pin doctor non-zero forever,
# fire a futile `make install` every session, and bury doctor's real
# MISSING/DANGLING signal.
#
# ── Composed CLAUDE.md staleness (COMPOSED_STALE, temperloop#1618) ──────────
# The installed ~/.claude/CLAUDE.md is a COMPOSED real file (kernel doc +
# overlay + a rendered "## Knowledge store routing" section, per
# install-claude-md.sh) — deliberately not a symlink, which is exactly why
# `make doctor` (a symlink classifier) structurally cannot see it go stale. A
# stale composed file is not inert: it actively feeds superseded rules to
# every session on the host while looking identical to a current one.
#
# MECHANISM IS MTIME, DELIBERATELY — NOT the vendored-hook block's `cmp`
# comparator above (_hook_body / _stale_vendored_hooks). That comparator
# diffs a copy against an EXPECTED-CONTENT baseline: the canonical hook file
# IS byte-identical to a correctly-synced copy (once the sync preamble is
# stripped), so a mismatch is unambiguous drift. The composed CLAUDE.md has
# no such baseline to diff against without re-running install-claude-md.sh
# itself — which this READ-ONLY reconciler must never do (see the file's own
# READ-ONLY / FAIL-OPEN contract below). Concretely: compose injects a
# generated "## Knowledge store routing" section present in NEITHER
# claude/CLAUDE.kernel.md nor claude/CLAUDE.overlay.md, and substitutes
# `{{SETTING_NAME}}` placeholder tokens the kernel doc's raw text still
# carries — so a `cmp` of the composed file against either source ALONE
# would differ every time, drift or not, and there is no third
# "expected-composed-output" file to diff against short of composing one.
# mtime sidesteps needing a content baseline entirely: is the artifact
# older than the things that feed it, yes or no. Do NOT "fix" this to `cmp`
# — see classify_composed_claude_md's own header for the same point in code.
#
# SOURCE CHECKOUT IS NAMED EXPLICITLY, NEVER ASSUMED. `make install-claude`
# composes from WHICHEVER checkout ran it; the generated-file banner records
# only the source basenames, never the producing checkout's path; and this
# script's own OPERATOR_CHECKOUTS registry cannot be trusted to guess it
# either — the host that motivated this check has ~/.claude/* resolving into
# a checkout not even in DEFAULT_OPERATOR_CHECKOUTS. So
# ENV_RECONCILE_CLAUDE_MD_SOURCE_CHECKOUT must be set explicitly; unset means
# "can't verify" (UNVERIFIABLE), never a guessed comparison.
#
# NOT PER-CHECKOUT. Every other operator-checkout class above is evaluated
# once per entry in OPERATOR_CHECKOUTS. This one is a single machine-wide
# check (there is exactly one ~/.claude/CLAUDE.md), evaluated once, and
# reported in its own report section / a single FINDINGS entry — see the
# "Composed CLAUDE.md" emit block near the end of the main-enumeration guard.
#
# REPORT-ONLY: never re-runs install-claude-md.sh / `make install-claude`,
# never rewrites the composed file, never touches ~/.claude/ at all — reading
# two mtimes is its entire footprint.
#
# READ-ONLY / FAIL-OPEN contract: this script never runs `git fetch`, never
# writes a file, never calls `launchctl load/unload`, never invokes `gh` in
# any but a read (`pr view`) mode. A missing tool (gh, launchctl), a
# non-existent checkout, or a malformed plist is skipped/degraded rather than
# aborting — the script always exits 0 except on a genuine usage error (2).
#
# Kept POSIX-bash-3.2 compatible (no mapfile/associative arrays) with BSD-vs-
# GNU stat fallbacks, so it runs on the macOS dev shell as well as Linux CI.
# It is primarily a DIRECTLY-INVOKED script (env-hygiene-report.sh + /tidy
# call it by bare path) — tracked 100755, like its sourced-only sibling
# lib/merged-detect.sh is NOT — but it is also safely sourceable for its
# library surface above (a `source`'d run's arg-parse loop simply sees an
# empty "$@" and its main-enumeration body is skipped by the direct-invocation
# guard, so sourcing never runs the reconciler or trips one of its `exit`s).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Override seams (tests redefine these — same convention as
#    merged-detect.sh's _merged_detect_gh / gate.sh's _gate_gh) ──────────────
_env_reconcile_launchctl() { launchctl "$@"; }

# ── Source the shared merged-detection helper ────────────────────────────────
# shellcheck source=lib/merged-detect.sh
source "$SCRIPT_DIR/lib/merged-detect.sh" 2>/dev/null || true
if ! command -v merged_detect_is_merged >/dev/null 2>&1; then
  # Fail-open stand-in if the sibling lib is somehow missing — never treat
  # anything as "merged" on uncertain grounds (mirrors the lib's own default).
  merged_detect_is_merged() { printf 'false\n'; return 0; }
fi
# _merged_detect_gh is defined by the sourced lib above (or, if the source
# failed, is simply undefined — _pr_state_of below tolerates that via `|| true`).

# ── Source the shared job-scratch classifier (temperloop#1111) ───────────────
# READ-ONLY by construction — the lib defines classification only; deletion
# lives in the sibling job-scratch-reclaim.sh, which this file never calls.
# shellcheck source=lib/job-scratch.sh
source "$SCRIPT_DIR/lib/job-scratch.sh" 2>/dev/null || true
if ! command -v job_scratch_list >/dev/null 2>&1; then
  # Fail-open stand-in if the sibling lib is somehow missing: report no job
  # scratch at all rather than abort the whole reconcile.
  job_scratch_list() { :; }
fi

# ── Arg parse ─────────────────────────────────────────────────────────────────
FORMAT="report"
while [ $# -gt 0 ]; do
  case "$1" in
    --format) FORMAT="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
    --format=*) FORMAT="${1#--format=}"; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
case "$FORMAT" in report|entry) ;; *) echo "unknown --format: $FORMAT (report|entry)" >&2; exit 2 ;; esac

# ── Tunables (env-overridable) ────────────────────────────────────────────────
STALE_UNTRACKED_DAYS="${ENV_RECONCILE_STALE_UNTRACKED_DAYS:-7}"
# Dormancy horizon (DORMANT, temperloop#2041) — days of NO local activity after
# which an operator checkout that is ALSO behind its already-fetched
# origin/<default> is NAMED dormant instead of reading as a bare OK.
# Deliberately longer than the untracked-file horizon above: a week of quiet is
# an ordinary gap between sessions, while a fortnight of quiet on a checkout the
# rest of the world has moved past is the thing an operator wants told. Never a
# drift class either way — see classify_operator_dormancy.
DORMANT_CHECKOUT_DAYS="${ENV_RECONCILE_DORMANT_DAYS:-14}"
# Harness agent worktrees (temperloop#1405). Claude Code's own agent isolation
# (`isolation: "worktree"`) creates worktrees under
# <checkout>/.claude/worktrees/agent-<id>/ — INSIDE the checkout and untracked,
# a different layout from the <repo>.wt/<slug> one worktree.sh uses. Relative to
# a checkout root, and carries NO trailing slash (each consumer appends its
# own). Overridable so a host whose harness writes elsewhere is still scanned
# rather than silently unclassified.
HARNESS_WT_SUBDIR="${ENV_RECONCILE_HARNESS_WT_SUBDIR:-.claude/worktrees}"
AGENT_DEFAULT_CADENCE_S="${ENV_RECONCILE_AGENT_DEFAULT_CADENCE_S:-86400}"
# Heartbeat markers: the reliable freshness signal (#1173). A launchd job touches
# $AGENT_HEARTBEAT_DIR/<label>.ran on SUCCESSFUL completion; env-reconcile reads
# the marker's mtime, never StandardOutPath (which launchd touches on every wake).
AGENT_HEARTBEAT_DIR="${ENV_RECONCILE_AGENT_HEARTBEAT_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/foundation/agent-heartbeat}"

# Vendored-hook drift (STALE_VENDORED_HOOK). The canonical source is THIS repo's
# own claude/hooks/ — resolved from SCRIPT_DIR (workflows/scripts/build) up three
# levels. That holds both in a bare kernel checkout and inside a consumer's
# vendored `kernel/` subtree, since either way the canonical hook sits beside the
# reconciler running the comparison. Empty (unresolvable) = the comparison is
# skipped entirely: fail-open, never a false alarm from a missing reference.
_REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." 2>/dev/null && pwd -P)" || _REPO_ROOT=""
DEFAULT_CANONICAL_HOOK_DIR=""
[ -n "$_REPO_ROOT" ] && DEFAULT_CANONICAL_HOOK_DIR="$_REPO_ROOT/claude/hooks"
CANONICAL_HOOK_DIR="${ENV_RECONCILE_CANONICAL_HOOK_DIR:-$DEFAULT_CANONICAL_HOOK_DIR}"

# Composed ~/.claude/CLAUDE.md staleness (COMPOSED_STALE). See the "Composed
# CLAUDE.md staleness" header block above for the mtime-not-cmp rationale and
# the fail-open contract. CLAUDE_MD_SOURCE_CHECKOUT is UNSET by default —
# deliberately no guessed default (see that block); classify_composed_claude_md
# reports UNVERIFIABLE when it is empty.
CLAUDE_MD_TARGET="${ENV_RECONCILE_CLAUDE_MD_TARGET:-$HOME/.claude/CLAUDE.md}"
CLAUDE_MD_SOURCE_CHECKOUT="${ENV_RECONCILE_CLAUDE_MD_SOURCE_CHECKOUT:-}"
read -r -a VENDORED_HOOKS <<<"${ENV_RECONCILE_VENDORED_HOOKS:-build-worktree-guard.sh}"

# ── Host-role ownership (#531) ────────────────────────────────────────────────
# The launchd-agent and cron-checkout roles are owned by ONE host (the agent host),
# not every machine that carries this checkout. A laptop that never installed
# the plists and never held the cron checkouts must NOT report the agent host's agents
# as AGENT_UNLOADED nor the agent host's cron checkouts as ABSENT — that drift belongs
# to the owning host, and flagging it everywhere is the #531 false-positive.
#
# Ownership resolves through two seams, cheapest-first, both READ-ONLY:
#   1. Explicit host list — ENV_RECONCILE_AGENT_HOSTS (space-separated host
#      labels, matched against this host's ${SUBSET_HOST_LABEL:-hostname -s}).
#      When set, THIS host owns the role iff it is in the list; every other host
#      classifies the agents/cron checkouts as EXPECTED_ELSEWHERE (not drift).
#   2. Install-marker auto-detect (default, zero-config) — a launchd USER agent
#      is "installed" on a host only when its plist lives in the launchd agents
#      directory ($AGENT_INSTALL_DIR, default ~/Library/LaunchAgents). If a
#      declared plist is NOT installed here, this host does not run that agent →
#      EXPECTED_ELSEWHERE; if it IS installed but not loaded → genuine
#      AGENT_UNLOADED. The install directory being empty of the declared agents
#      is exactly the laptop's self-describing "not my role" signal.
RECONCILE_HOST="${SUBSET_HOST_LABEL:-$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo host)}"
AGENT_INSTALL_DIR="${ENV_RECONCILE_AGENT_INSTALL_DIR:-$HOME/Library/LaunchAgents}"
read -r -a AGENT_HOSTS <<<"${ENV_RECONCILE_AGENT_HOSTS:-}"

DEFAULT_CRON_CHECKOUTS="$HOME/dev/foundation.cron $HOME/dev/batch/temperloop $HOME/dev/foundation-kernel"
# Note: the kernel repo is registered TWICE — once above ($HOME/dev/batch/
# temperloop, cron) and once here ($HOME/dev/temperloop, operator) — because
# what these lists name is a ROLE, not a repo. Two clones of one repo, each
# classified against its OWN baseline: the cron/kernel clone is the one
# automation drives, so it must be clean-on-main; the operator clone is the one
# a human or session drives, so sitting on a feature branch there is ordinary
# work rather than drift.
#
# This comment deliberately says NOTHING about which clone currently holds the
# `<repo>.wt/*` worktrees, gets pulled more often, or is "the live one". That is
# a fact about one host's habits at one moment — it already inverted once, when
# the `batch/` layout arrived and the claim recorded here went silently stale
# (temperloop#2041) — and the classifier never reads it: worktrees are
# discovered by scanning `<checkout>.wt/` beside EVERY entry in BOTH lists, so
# either role may own any number of them, including none.
DEFAULT_OPERATOR_CHECKOUTS="$HOME/dev/foundation $HOME/dev/stageFind $HOME/dev/ssmobile $HOME/dev/subsetwiki $HOME/dev/temperloop"

read -r -a CRON_CHECKOUTS <<<"${ENV_RECONCILE_CRON_CHECKOUTS:-$DEFAULT_CRON_CHECKOUTS}"
read -r -a OPERATOR_CHECKOUTS <<<"${ENV_RECONCILE_OPERATOR_CHECKOUTS:-$DEFAULT_OPERATOR_CHECKOUTS}"

# bash-3.2 note: `"${arr[@]}"` on a DECLARED-BUT-EMPTY array is an "unbound
# variable" error under `set -u` on bash < 4.4 (macOS ships 3.2) — every array
# expansion below is guarded by an index-based loop over `${#arr[@]}` (safe
# even when 0) rather than a bare `for x in "${arr[@]}"`.
LAUNCHD_DIRS=()
if [ -n "${ENV_RECONCILE_LAUNCHD_DIRS:-}" ]; then
  read -r -a LAUNCHD_DIRS <<<"$ENV_RECONCILE_LAUNCHD_DIRS"
else
  _i=0
  while [ "$_i" -lt "${#CRON_CHECKOUTS[@]}" ]; do
    _c="${CRON_CHECKOUTS[$_i]}"; _i=$((_i + 1))
    [ -d "$_c/infra/launchd" ] && LAUNCHD_DIRS+=("$_c/infra/launchd")
  done
  _i=0
  while [ "$_i" -lt "${#OPERATOR_CHECKOUTS[@]}" ]; do
    _c="${OPERATOR_CHECKOUTS[$_i]}"; _i=$((_i + 1))
    [ -d "$_c/infra/launchd" ] && LAUNCHD_DIRS+=("$_c/infra/launchd")
  done
fi

# ── Portable stat/date helpers (mirrors vault_hygiene_report.sh) ─────────────
# Portable mtime-as-epoch. GNU-first, then BSD — each branch emits ONLY on
# success (guarded by capture + non-empty check), because GNU `stat -f %m`
# mis-parses as filesystem mode and leaks a multi-line "File: …" blob to stdout
# while exiting non-zero, which a bare `A || B` would concatenate into the result
# (breaking the arithmetic that consumes it under `set -u`).
file_mtime() {
  local m
  if m="$(stat -c %Y "$1" 2>/dev/null)" && [ -n "$m" ]; then printf '%s\n' "$m"; return 0; fi
  if m="$(stat -f %m "$1" 2>/dev/null)" && [ -n "$m" ]; then printf '%s\n' "$m"; return 0; fi
  echo 0
}
now_epoch() { date +%s; }

# ── is_kernel_checkout <checkout> ─────────────────────────────────────────────
# True iff <checkout> IS the kernel repo itself, rather than a checkout that
# merely vendors the kernel in as a consumer. Same detection convention
# validate-capture-backstop.sh already uses for its own KERNEL_ONLY_MD case
# (workflows/scripts/validate-capture-backstop.sh:68-70): a bare kernel
# checkout ships `claude/CLAUDE.kernel.md` but never `claude/CLAUDE.overlay.md`
# (a composed/overlay consumer checkout carries both — the overlay half is
# personal/org content the kernel repo itself never ships). Matched here
# rather than reinvented so the two checks agree on what "is the kernel repo"
# means.
is_kernel_checkout() {
  local checkout="$1"
  [ -f "$checkout/claude/CLAUDE.kernel.md" ] && [ ! -f "$checkout/claude/CLAUDE.overlay.md" ]
}

# ── kernel_pin_tag_of <checkout> ──────────────────────────────────────────────
# Reads the installed kernel tag straight from a consumer checkout's own
# `.kernel-pin` file (atomically written by `scripts/update-kernel.sh`; NOT a
# new stamp — this is the /check-in class-B discharge's only source of truth
# for "what kernel tag is this consumer running"). Prints the tag (e.g.
# `v0.12.1`) and exits 0 on success; prints nothing and exits 1 when the
# checkout or its `.kernel-pin` is absent or has no `tag` line — the caller
# treats that as "not yet reached", never a crash (a straggler/never-updated
# consumer keeps a class-B record open, it doesn't abort the discharge pass).
#
# EXCEPTION — the checkout IS the kernel repo (is_kernel_checkout above).
# `.kernel-pin` is the vendored-subtree identity carrier a CONSUMER writes;
# the kernel repo is never its own consumer, so it can never have one BY
# CONSTRUCTION — treating that absence as "not yet reached" would make any
# `all-consumers` class-B record permanently undischargeable the moment the
# kernel checkout is in scope (temperloop#1333: exactly the failure
# `719-pointer-collapse` / `719-apply-approved-deletions` /
# `719-terminology-consolidation` hit). Instead resolve "reached" from the
# checkout's OWN history: the nearest release tag that is an ancestor of its
# HEAD is the version this checkout has itself reached — the same tag a
# consumer would record in `.kernel-pin` if it updated right now. A checkout
# that hasn't fetched/merged far enough correctly resolves to an OLDER tag (or
# none), so a stale kernel checkout still reads "not yet reached" — this stays
# fail-open, never a blanket "always discharged".
kernel_pin_tag_of() {
  local checkout="$1" pin tag
  if is_kernel_checkout "$checkout"; then
    tag="$(git -C "$checkout" describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null)" || return 1
    [ -n "$tag" ] || return 1
    printf '%s\n' "$tag"
    return 0
  fi
  pin="$checkout/.kernel-pin"
  [ -f "$pin" ] || return 1
  tag="$(awk '$1=="tag"{print $2; exit}' "$pin" 2>/dev/null)"
  [ -n "$tag" ] || return 1
  printf '%s\n' "$tag"
  return 0
}

# ── semver_ge <a> <b> ──────────────────────────────────────────────────────────
# bash-3.2-safe semver `a >= b` compare for the `vMAJOR.MINOR.PATCH` tag shape
# (a leading `v` is optional on either side; a missing component defaults to
# 0). Prints `true` or `false` on stdout and always exits 0 — this is a pure
# string-in/string-out helper, never a pass/fail exit code, so callers test
# its printed value rather than `$?`. NUMERIC comparison, not lexical: lexical
# order would wrongly rank "0.9.0" above "0.12.1" (`9` > `1` as the first
# differing character); semver_ge compares each dotted component as an
# integer instead. (BSD `sort -V` on macOS also orders these correctly and is
# a fine ad-hoc sanity check — `printf 'v0.9.0\nv0.12.1\n' | sort -V` — but
# this function is used directly rather than shelling out to `sort` so the
# compare stays a single in-process call.)
semver_ge() {
  local a="${1#v}" b="${2#v}" a_maj a_min a_pat b_maj b_min b_pat
  IFS='.' read -r a_maj a_min a_pat <<<"$a"
  IFS='.' read -r b_maj b_min b_pat <<<"$b"
  a_maj="${a_maj%%[^0-9]*}"; a_min="${a_min%%[^0-9]*}"; a_pat="${a_pat%%[^0-9]*}"
  b_maj="${b_maj%%[^0-9]*}"; b_min="${b_min%%[^0-9]*}"; b_pat="${b_pat%%[^0-9]*}"
  a_maj="${a_maj:-0}"; a_min="${a_min:-0}"; a_pat="${a_pat:-0}"
  b_maj="${b_maj:-0}"; b_min="${b_min:-0}"; b_pat="${b_pat:-0}"
  if [ "$a_maj" -gt "$b_maj" ]; then printf 'true\n'; return 0; fi
  if [ "$a_maj" -lt "$b_maj" ]; then printf 'false\n'; return 0; fi
  if [ "$a_min" -gt "$b_min" ]; then printf 'true\n'; return 0; fi
  if [ "$a_min" -lt "$b_min" ]; then printf 'false\n'; return 0; fi
  if [ "$a_pat" -ge "$b_pat" ]; then printf 'true\n'; return 0; fi
  printf 'false\n'
  return 0
}

# ── Findings accumulator ──────────────────────────────────────────────────────
alarms=0
FINDINGS=""
add() { FINDINGS="${FINDINGS}$1"$'\n'; [ "${2:-}" = "drift" ] && alarms=$((alarms + 1)); }

is_git_repo() { git -C "$1" rev-parse --show-toplevel >/dev/null 2>&1; }
current_branch_of() { git -C "$1" symbolic-ref --quiet --short HEAD 2>/dev/null; }

# Mirrors worktree.sh's default_branch() — READ-ONLY, no fetch: resolves from
# whatever origin/HEAD or main/master ref is already on disk.
default_branch_of() {
  local repo="$1" ref b
  if ref="$(git -C "$repo" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)"; then
    printf '%s\n' "${ref#origin/}"
    return 0
  fi
  for b in main master; do
    if git -C "$repo" show-ref --verify --quiet "refs/remotes/origin/$b"; then
      printf '%s\n' "$b"
      return 0
    fi
  done
  return 1
}

# PR state via the same gh override seam merged-detect.sh sources in
# (_merged_detect_gh) — read-only (`pr view`), fail-open to UNKNOWN on any
# gh error (not installed / offline / rate-limited).
_pr_state_of() {
  local repo="$1" branch="$2" state
  if ! command -v _merged_detect_gh >/dev/null 2>&1; then
    printf 'UNKNOWN\n'
    return 0
  fi
  state="$(cd "$repo" && _merged_detect_gh pr view "$branch" --json state --jq .state 2>/dev/null)" || {
    printf 'UNKNOWN\n'
    return 0
  }
  case "$state" in
    MERGED | OPEN | CLOSED) printf '%s\n' "$state" ;;
    *) printf 'UNKNOWN\n' ;;
  esac
}

# ── _behind_origin_default <repo> ─────────────────────────────────────────────
# Prints 'true' when <repo>'s current HEAD is checked out on its default
# branch AND is a strict ancestor of the already-fetched origin/<default> —
# i.e. genuinely behind. Prints 'false' for every other case, INCLUDING every
# can't-tell case (not a git repo, no default branch resolvable, no
# origin/<default> ref on disk yet, detached HEAD, HEAD on a non-default
# branch): the caller treats 'false' as "no evidence of drift", exactly the
# fail-open posture this block had inline (in classify_cron_checkout) before
# it was extracted here so classify_agent_checkout could reuse the identical
# mechanism rather than reimplementing it (#1624). NEVER fetches — compares
# only against whatever remote-tracking ref is already on disk. Always exits
# 0 — a print-only helper like semver_ge above; callers test the printed
# value, never $?.
_behind_origin_default() {
  local repo="$1" branch default head origin_head
  branch="$(current_branch_of "$repo")" || branch=""
  default="$(default_branch_of "$repo")" || { printf 'false\n'; return 0; }
  if [ -z "$branch" ] || [ "$branch" != "$default" ]; then
    printf 'false\n'
    return 0
  fi
  head="$(git -C "$repo" rev-parse HEAD 2>/dev/null)" || { printf 'false\n'; return 0; }
  git -C "$repo" show-ref --verify --quiet "refs/remotes/origin/$default" || { printf 'false\n'; return 0; }
  origin_head="$(git -C "$repo" rev-parse "origin/$default" 2>/dev/null)" || origin_head=""
  if [ -n "$origin_head" ] && [ "$head" != "$origin_head" ] \
    && git -C "$repo" merge-base --is-ancestor "$head" "origin/$default" 2>/dev/null; then
    printf 'true\n'
  else
    printf 'false\n'
  fi
}

# ── _status_porcelain_sans_harness <repo> ─────────────────────────────────────
# The checkout's `git status --porcelain` with every entry under
# $HARNESS_WT_SUBDIR/ dropped (temperloop#1405).
#
# WHY. Harness agent worktrees live INSIDE the checkout and are untracked, so
# any checkout that had ever run an `isolation: "worktree"` agent reported a
# bare DIRTY (cron role) or STALE_UNTRACKED:.claude/worktrees/ (operator role) —
# an opaque class with no remedy pointer that MASKED whatever real drift sat
# beside it (both observed live 2026-08-13). Those worktrees are classified in
# their own right by classify_worktree's harness arm now, so counting them again
# here is double-reporting, not detection.
#
# ONLY that one path prefix is dropped, and only when it is the ENTRY's own
# path: every other dirty or untracked path still reaches the caller, so a
# genuinely dirty checkout still reports DIRTY. A coarser collapse (git
# reporting `?? .claude/` because nothing under it is tracked) deliberately does
# NOT match — swallowing that would hide real untracked files like
# .claude/settings.local.json.
_status_porcelain_sans_harness() {
  local repo="$1"
  git -C "$repo" status --porcelain 2>/dev/null | awk -v p="${HARNESS_WT_SUBDIR}/" '
    {
      path = substr($0, 4)          # porcelain v1: two status chars + one space
      sub(/^"/, "", path)           # unquote a path git had to escape
      if (substr(path, 1, length(p)) == p) next
      print
    }
  '
}

# ── classify_cron_checkout <repo> ─────────────────────────────────────────────
# Prints zero or more space-separated class tokens (empty = OK).
classify_cron_checkout() {
  local repo="$1" classes="" branch default
  [ -d "$repo" ] || { printf 'ABSENT'; return 0; }
  is_git_repo "$repo" || { printf 'NOT_A_REPO'; return 0; }

  branch="$(current_branch_of "$repo")" || branch=""
  default="$(default_branch_of "$repo")" || default="main"

  # Harness agent worktrees are excluded here — they carry their own named class
  # (temperloop#1405); see _status_porcelain_sans_harness.
  if [ -n "$(_status_porcelain_sans_harness "$repo")" ]; then
    classes="${classes}DIRTY "
  fi

  if [ -z "$branch" ]; then
    classes="${classes}ON_BRANCH:(detached) "
  elif [ "$branch" != "$default" ]; then
    classes="${classes}ON_BRANCH:${branch} "
  elif [ "$(_behind_origin_default "$repo")" = "true" ]; then
    classes="${classes}BEHIND_MAIN "
  fi

  printf '%s' "$classes"
}

# ── Vendored-hook drift helpers (STALE_VENDORED_HOOK) ─────────────────────────
# _hook_body <file> — the file's content with the sync's provenance BANNER
# removed, so a synced copy and its canonical source compare equal when only the
# banner differs.
#
# EXACT INVERSE OF THE INJECTOR. The hook-sync's recipe is
#   awk 'NR==1{print; print b; print s; print "#"; next} {print}'
# i.e. after the shebang it inserts exactly THREE lines: the "GENERATED by …
# DO NOT EDIT HERE" banner, the "Source of truth: …" note, and a bare `#`
# separator. So this strips exactly lines 2-4, and ONLY when line 2 is the
# banner — which makes it a no-op on the canonical file (no banner at line 2),
# keeping the two streams symmetric.
#
# The bare `#` is the load-bearing third line: dropping only the two commented
# lines leaves it behind in every synced copy and absent from canonical, so the
# streams could never compare equal and EVERY correctly-synced consumer would
# report permanent, unclearable drift (following the remedy re-runs the injector
# and reproduces the identical file). That self-perpetuating alarm is exactly the
# fatigue shape that buries the real signal this class exists to raise.
#
# ⚠️ CROSS-REPO COUPLING, NOT MECHANICALLY LINKED: this strip lives in the kernel
# while the injector lives in the CONSUMER-side fleet Makefile's `sync-hooks`
# recipe (foundation Makefile:458, the `inject()` awk one-liner above). Nothing
# checks the two stay inverses — if the injected preamble's shape ever changes,
# this function must change with it, and the in-sync fixture in
# tests/test_env_reconcile.sh (built with the REAL injector, deliberately) is
# what catches the mismatch.
#
# Positional, not pattern-global: a body line deeper in the file that happens to
# read "Source of truth:" is content, not banner, and is never silently dropped.
# Nothing else is normalised — any other byte difference IS drift.
_hook_body() {
  awk '
    NR==1 { print; next }
    NR==2 && /^# *GENERATED by / { stripped=1; next }
    stripped && (NR==3 || NR==4) { next }
    { print }
  ' "$1" 2>/dev/null
}

# _vendored_hook_sync_cmd <repo> <hook> — the exact command that re-syncs <hook>
# into <repo>. Read from the vendored copy's OWN banner, which names the make
# target that produced it (`# GENERATED by foundation 'make sync-<x>-hooks' …`);
# falls back to the generic sync engine with an explicit TARGET_REPO when the
# copy carries no banner. Self-describing — no repo→target mapping table here
# that could itself drift from the fleet Makefile's wrappers.
#
# THE CAPTURE IS UNTRUSTED INPUT AND IS VALIDATED BEFORE USE. Its source is the
# very file this check exists because it cannot be assumed to match canonical —
# a garbled, truncated, or hand-edited banner is the realistic case. This script
# never executes the string, but `--format entry` is appended to the hygiene
# report that /check-in READS AND DISPOSES, so an unvalidated capture hands an
# agent an authoritative-looking command line sourced from a suspect file (a
# planted banner reading `make sync-x-hooks; curl … | sh; rm -rf …` otherwise
# renders verbatim). So the capture is accepted ONLY in the narrow shape a
# legitimate SYNC_LABEL produces — `make <target>`, a single bare target of
# word/dot/dash characters — and anything else falls back to the generic engine
# invocation. That keeps the self-describing property for real banners while
# making the surface un-injectable.
#
# The emitted command is a FLEET-Makefile target (`sync-<x>-hooks` lives in the
# consumer-side fleet repo, not in this kernel repo, which has no such target),
# so callers render it with its run location — see the emit site.
_vendored_hook_sync_cmd() {
  local repo="$1" hook="$2" cmd
  cmd="$(sed -n "s/^#[[:space:]]*GENERATED by [A-Za-z0-9_-]* '\([^']*\)'.*/\1/p" \
    "$repo/.claude/hooks/$hook" 2>/dev/null | head -1)"
  case "$cmd" in
    "make "[A-Za-z0-9_]*)
      # Re-check the tail against the allowed charset: no whitespace, no shell
      # metacharacters, no second word — a bare `make <target>` and nothing else.
      case "${cmd#make }" in
        *[!A-Za-z0-9_.-]*) cmd="" ;;
      esac
      ;;
    *) cmd="" ;;
  esac
  if [ -n "$cmd" ]; then
    printf '%s\n' "$cmd"
  else
    printf 'make sync-hooks TARGET_REPO=%s\n' "$repo"
  fi
}

# _stale_vendored_hooks <repo> — prints a space-terminated
# `STALE_VENDORED_HOOK:<hook>` token per vendored hook whose banner-stripped body
# differs from canonical. FAIL-OPEN and SILENT on every uncertain case: no
# resolvable canonical dir, no `cmp`, a canonical file that is missing/unreadable,
# or a consumer that simply vendors no copy of the hook — each is skipped without
# a token and without a message. Only a readable-copy-vs-readable-canonical
# mismatch raises the class.
_stale_vendored_hooks() {
  local repo="$1" out="" h canon vend _i=0
  [ -n "$CANONICAL_HOOK_DIR" ] || { printf ''; return 0; }
  command -v cmp >/dev/null 2>&1 || { printf ''; return 0; }
  while [ "$_i" -lt "${#VENDORED_HOOKS[@]}" ]; do
    h="${VENDORED_HOOKS[$_i]}"; _i=$((_i + 1))
    [ -n "$h" ] || continue
    canon="$CANONICAL_HOOK_DIR/$h"
    vend="$repo/.claude/hooks/$h"
    [ -r "$canon" ] || continue   # no reference to compare against — skip
    [ -r "$vend" ] || continue    # consumer vendors no copy — not this class
    if ! cmp -s <(_hook_body "$canon") <(_hook_body "$vend"); then
      out="${out}STALE_VENDORED_HOOK:${h} "
    fi
  done
  printf '%s' "$out"
}

# ── classify_operator_checkout <repo> ─────────────────────────────────────────
classify_operator_checkout() {
  local repo="$1" classes="" branch default merged now f m age_days
  [ -d "$repo" ] || { printf 'ABSENT'; return 0; }
  is_git_repo "$repo" || { printf 'NOT_A_REPO'; return 0; }

  branch="$(current_branch_of "$repo")" || branch=""
  default="$(default_branch_of "$repo")" || default="main"

  if [ -n "$branch" ] && [ "$branch" != "$default" ]; then
    merged="$(merged_detect_is_merged "$repo" "$branch" "$default" 2>/dev/null)" || merged="false"
    [ "$merged" = "true" ] && classes="${classes}PARKED_ON_MERGED:${branch} "
  fi

  now="$(now_epoch)"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    m="$(file_mtime "$repo/$f")"
    age_days=$(( (now - m) / 86400 ))
    if [ "$age_days" -gt "$STALE_UNTRACKED_DAYS" ]; then
      classes="${classes}STALE_UNTRACKED:${f} "
    fi
    # Same harness-worktree exclusion as the cron role's DIRTY test above
    # (temperloop#1405) — .claude/worktrees/ is classified in its own right.
  done < <(_status_porcelain_sans_harness "$repo" | awk '/^\?\?/{ sub(/^\?\? /,""); print }')

  # An out-of-date VENDORED guard hook — the consumer is running protections the
  # kernel has since widened (see the "Vendored-hook drift" block in the header).
  classes="${classes}$(_stale_vendored_hooks "$repo")"

  printf '%s' "$classes"
}

# ── _checkout_last_activity_days <repo> ───────────────────────────────────────
# Prints the whole-day age of the most recent LOCAL activity in <repo>. Exits 1
# printing NOTHING when no activity signal can be read (fail-open — the caller
# then says nothing rather than guessing "abandoned" from an absent reading).
#
# TWO signals, NEWEST wins, because either alone mis-dates a live checkout:
#   * HEAD's committer date — when the commit this checkout sits on was made.
#   * the newest HEAD REFLOG ENTRY's own recorded timestamp — every pull, merge,
#     commit or branch switch IN THIS CHECKOUT moves HEAD and appends a
#     timestamped line to the reflog, so it dates the last time a human or
#     session actually drove this clone. It is what keeps a freshly-pulled clone
#     of a quiet repo (old HEAD commit, recent pull) from reading as dormant.
#
# THE ENTRY'S RECORDED TIMESTAMP, NEVER THE REFLOG FILE'S MTIME. The file's
# mtime looks like the same signal and is not: `git gc --auto` (which a routine
# fetch triggers) expires old entries and REWRITES the file, so an abandoned
# checkout's <git-dir>/logs/HEAD can be zero bytes and dated TODAY. That is not
# hypothetical — it is exactly the state $HOME/dev/temperloop was in when this
# class was written (temperloop#2041: empty reflog, mtime today, last real
# activity a month earlier), so an mtime reading would have reported the very
# checkout that motivated this class as active. An expired-away reflog instead
# leaves the committer date as the only signal, which is the correct reading for
# a checkout nothing has touched in months.
#
# DELIBERATELY NOT the index mtime either, the obvious third candidate: `git
# status` refreshes it, and this very reconciler runs `git status --porcelain`
# over every checkout it classifies — a probe that made its own subject look
# active could never report anything, and would look correct while doing so.
#
# READ-ONLY, like everything else here: `log` / `rev-parse` / a file test, never
# a fetch.
_checkout_last_activity_days() {
  local repo="$1" committed reflog gitdir newest now days
  committed="$(git -C "$repo" log -1 --format=%ct 2>/dev/null)" || committed=""
  case "$committed" in
    '' | *[!0-9]*) committed=0 ;;
  esac
  # The reflog FILE is checked for existence-and-non-emptiness FIRST: asked for
  # a reflog entry it does not have, `git log -g` helpfully SYNTHESISES one for
  # the current HEAD stamped NOW — so on exactly the expired-reflog checkout
  # this class is for, reading it unguarded reports today. `%gd` under
  # --date=unix prints `HEAD@{<epoch>}`.
  reflog=0
  gitdir="$(git -C "$repo" rev-parse --absolute-git-dir 2>/dev/null)" || gitdir=""
  if [ -n "$gitdir" ] && [ -s "$gitdir/logs/HEAD" ]; then
    reflog="$(git -C "$repo" log -g -1 --date=unix --format='%gd' HEAD 2>/dev/null)" || reflog=""
    reflog="${reflog##*@\{}"
    reflog="${reflog%%\}*}"
    case "$reflog" in
      '' | *[!0-9]*) reflog=0 ;;
    esac
  fi
  newest="$committed"
  [ "$reflog" -gt "$newest" ] && newest="$reflog"
  [ "$newest" -gt 0 ] || return 1
  now="$(now_epoch)"
  days=$(( (now - newest) / 86400 ))
  [ "$days" -lt 0 ] && days=0
  printf '%s\n' "$days"
}

# ── classify_operator_dormancy <repo> ─────────────────────────────────────────
# Prints a single `DORMANT:<days>d-idle:<n>-behind` token when an operator
# checkout looks ABANDONED rather than merely between sessions; prints nothing
# otherwise. Always exits 0 — a print-only helper, like semver_ge.
#
# WHY A SEPARATE, NON-DRIFT CLASS (temperloop#2041). Being behind origin/<default>
# is legitimately NOT drift for this role — an operator checkout may sit on
# other work for as long as the operator likes, which is exactly why the
# cron-role BEHIND_MAIN class has no counterpart in classify_operator_checkout.
# The hole that leaves is silence: a checkout 544 commits behind, with zero
# worktrees and no activity in a month, printed a bare `OK` — indistinguishable
# from one pulled an hour ago (observed 2026-09-15 on $HOME/dev/temperloop).
# Promoting BEHIND_MAIN to drift for this role would flag every legitimately-
# working checkout; the discriminator between "behind because busy elsewhere"
# and "behind because abandoned" is LAST ACTIVITY, so that is what is added.
#
# CONJUNCTION, deliberately: behind AND idle. Idle alone is an ordinary quiet
# repo nobody has needed; behind alone is the ordinary working state above.
# Together they say the world moved on and this clone did not follow.
#
# NEVER counted as drift and never carrying a remedy: the disposition of an
# abandoned checkout (pull it, retire it, leave it) is an operator decision this
# READ-ONLY reconciler exists to inform, not to make — it renders as its own
# `DORMANT` line in the report, and adds no alarm to `--format entry`.
classify_operator_dormancy() {
  local repo="$1" days behind
  [ -d "$repo" ] || return 0
  is_git_repo "$repo" || return 0
  # Reuses the cron role's own behind-ness mechanism (never a fetch); it prints
  # 'false' for a detached HEAD or a non-default branch, so a checkout parked on
  # a feature branch can never reach the dormancy test at all.
  [ "$(_behind_origin_default "$repo")" = "true" ] || return 0
  days="$(_checkout_last_activity_days "$repo")" || return 0
  [ "$days" -gt "$DORMANT_CHECKOUT_DAYS" ] || return 0
  # How far behind, for legibility only — the classification above does not
  # depend on it, so an unreadable count degrades to `?` rather than suppressing
  # the signal.
  behind="$(git -C "$repo" rev-list --count HEAD..origin/"$(default_branch_of "$repo")" 2>/dev/null)" || behind=""
  case "$behind" in
    '' | *[!0-9]*) behind="?" ;;
  esac
  printf 'DORMANT:%sd-idle:%s-behind' "$days" "$behind"
}

# ── classify_composed_claude_md <target> <source_checkout> ───────────────────
# Prints zero or more space-separated `COMPOSED_STALE:<input-basename>` tokens
# (empty = fresh/OK), or a single `UNVERIFIABLE:<reason>` token when freshness
# cannot be established. NOT per-checkout like every classify_* above — the
# composed ~/.claude/CLAUDE.md is one machine-wide artifact, so the caller
# invokes this exactly once (see the main-enumeration "Composed CLAUDE.md"
# section), not per OPERATOR_CHECKOUTS entry.
#
# MTIME, DELIBERATELY — NOT the vendored-hook block's `cmp` comparator
# (_hook_body / _stale_vendored_hooks above). That comparator has a
# byte-identical expected-content baseline (the canonical hook file) to diff
# a copy against. The composed CLAUDE.md has none: install-claude-md.sh
# injects a generated "## Knowledge store routing" section present in
# NEITHER claude/CLAUDE.kernel.md nor claude/CLAUDE.overlay.md, and
# substitutes `{{SETTING_NAME}}` placeholders — so a `cmp` against either
# source alone would differ every time, drift or not, and producing a real
# "expected composed output" to diff against means re-running compose, which
# this READ-ONLY reconciler must never do. mtime needs no content baseline:
# is the artifact older than what feeds it, yes or no. See the "Composed
# CLAUDE.md staleness" block in this file's own header for the full
# rationale — do NOT "fix" this to `cmp`.
#
# FAIL-OPEN: <source_checkout> empty/absent, <target> missing, or ANY ONE of
# the three named inputs missing under <source_checkout> all print
# UNVERIFIABLE (never COMPOSED_STALE, never silent OK) — a partial input set
# cannot establish "composed is current", so this refuses to guess.
classify_composed_claude_md() {
  local target="$1" checkout="$2"
  local -a inputs=(
    "claude/CLAUDE.kernel.md"
    "claude/CLAUDE.overlay.md"
    "workflows/scripts/build/build.config.sh"
  )
  local rel abspath tmtime imtime classes="" _i=0

  [ -n "$checkout" ] || { printf 'UNVERIFIABLE:no-source-checkout-configured'; return 0; }
  [ -d "$checkout" ] || { printf 'UNVERIFIABLE:source-checkout-not-found:%s' "$checkout"; return 0; }
  [ -f "$target" ] || { printf 'UNVERIFIABLE:composed-missing:%s' "$target"; return 0; }

  # Every named input must be present to establish freshness AT ALL — a
  # partial input set is "can't verify", never a partial comparison (that
  # would silently under-report drift the missing input might itself show).
  _i=0
  while [ "$_i" -lt "${#inputs[@]}" ]; do
    rel="${inputs[$_i]}"; _i=$((_i + 1))
    [ -f "$checkout/$rel" ] || { printf 'UNVERIFIABLE:input-missing:%s' "$rel"; return 0; }
  done

  tmtime="$(file_mtime "$target")"
  _i=0
  while [ "$_i" -lt "${#inputs[@]}" ]; do
    rel="${inputs[$_i]}"; _i=$((_i + 1))
    abspath="$checkout/$rel"
    imtime="$(file_mtime "$abspath")"
    if [ "$imtime" -gt "$tmtime" ]; then
      classes="${classes}COMPOSED_STALE:$(basename "$rel") "
    fi
  done

  printf '%s' "$classes"
}

# ── _worktree_branch_of <repo> <wt_abs> ───────────────────────────────────────
# Prints the SHORT name of the branch a registered worktree is ACTUALLY on
# (`fix/foo`, `build/foo`, `worktree-agent-7`, …), read from git's own
# `worktree list --porcelain` record for that exact path. Exits 1, printing
# nothing, when the worktree is detached or its branch cannot be established —
# the caller must treat that as UNCERTAIN, never as evidence of a leak.
#
# The porcelain record is the right signal precisely because it still names the
# branch when the REF has been deleted out from under the worktree: git prints
# `branch refs/heads/<name>` alongside `HEAD 0000000…`. That is what keeps the
# genuine branch-gone case detectable — reading the branch from the worktree's
# own `HEAD` symref (the fallback below, for a path spelling the parent records
# differently) agrees with it. Neither is derived from the DIRECTORY NAME, which
# is the guess temperloop#658 removed.
_worktree_branch_of() {
  local repo="$1" wt_abs="$2" branch
  branch="$(git -C "$repo" worktree list --porcelain 2>/dev/null | awk -v target="worktree $wt_abs" '
    $0 == target { found = 1; next }
    found && substr($0, 1, 18) == "branch refs/heads/" { print substr($0, 19); exit }
    found && ($0 == "detached" || $0 == "") { exit }
  ')" || branch=""
  if [ -z "$branch" ]; then
    branch="$(git -C "$wt_abs" symbolic-ref --quiet --short HEAD 2>/dev/null)" || branch=""
  fi
  [ -n "$branch" ] || return 1
  printf '%s\n' "$branch"
}

# ── _worktree_dirt_state <wt> ─────────────────────────────────────────────────
# Prints `dirty` (uncommitted changes OR untracked files present — an untracked
# new file is unsaved work exactly like a modified tracked one), `clean`, or
# `unknown` when cleanliness could not be ESTABLISHED. Always exits 0; callers
# read the printed value. Gitignored paths do not count (`status --porcelain`
# already honours .gitignore, so the build machinery's own `.build-guard` /
# `.build-verification.md` markers never make a finished worktree look dirty).
#
# UNRESOLVABLE HEAD ⇒ `unknown`, deliberately. When a worktree's branch ref has
# been deleted out from under it, its HEAD names a ref that resolves to nothing
# and `git status` has no base to diff against — it reports every tracked file
# as a new addition, which reads as "dirty" but is an artefact of the missing
# ref, not evidence about unsaved work. Neither `dirty` nor `clean` is
# defensible there, so this says so: the caller emits UNCERTAIN_WORKTREE and the
# consumer reports instead of removing. The cost is that a BRANCH_GONE worktree
# is never auto-removed, and that is the right trade — the vanished ref may have
# been the only pointer to that worktree's commits, so nothing about it can be
# shown to be expendable.
_worktree_dirt_state() {
  local wt="$1" st
  git -C "$wt" rev-parse --verify --quiet HEAD >/dev/null 2>&1 || { printf 'unknown\n'; return 0; }
  st="$(git -C "$wt" status --porcelain 2>/dev/null)" || { printf 'unknown\n'; return 0; }
  if [ -n "$st" ]; then printf 'dirty\n'; else printf 'clean\n'; fi
}

# ── _worktree_verdict <reason> <slug> <dirt> ──────────────────────────────────
# The one place a leak REASON is turned into an emitted CLASS. A leak reason is
# only ever emitted as the auto-removable LEAKED_WORKTREE when the worktree is
# confirmed clean; a dirty tree downgrades to DIRTY_WORKTREE and an unprobeable
# one to UNCERTAIN_WORKTREE, both report-only (see the header block). Routing
# every reason through here is what makes "never force-remove on an uncertain
# classification" structural rather than a rule each call site must remember.
_worktree_verdict() {
  local reason="$1" slug="$2" dirt="$3"
  case "$dirt" in
    dirty) printf 'DIRTY_WORKTREE:%s:%s' "$reason" "$slug" ;;
    clean) printf 'LEAKED_WORKTREE:%s:%s' "$reason" "$slug" ;;
    *) printf 'UNCERTAIN_WORKTREE:%s:%s' "$reason" "$slug" ;;
  esac
}

# ── _branch_landed_in_default <repo> <branch> ─────────────────────────────────
# Prints 'true' when <branch>'s tip is a STRICT ancestor of the already-fetched
# origin/<default> — every commit the branch carries is already contained in the
# default branch, so the worktree holds nothing origin/<default> does not.
# Prints 'false' for every other case, INCLUDING every can't-tell one: 'false'
# means "no evidence the work landed", the same fail-open posture
# _behind_origin_default and merged_detect_is_merged already take. NEVER fetches
# — compares only against the remote-tracking ref already on disk, and a stale
# origin/<default> can only make containment LESS likely, never falsely true.
#
# WHY THIS ARM EXISTS (temperloop#1404). merged_detect_is_merged is built for
# the merge-queue/squash topology where a merged branch's tip is NOT an ancestor
# of origin/<default>, and has no arm for the opposite, ordinary case: its
# Method 1 (`gh pr view <branch>`) returns nothing when no PR was ever opened
# under that head-branch name, and its Method 2 patch-equivalence heuristic is
# inconclusive precisely when the branch's cumulative diff since its merge-base
# is EMPTY — which is exactly what "already contained in origin/<default>"
# means. Both fail open to false, so such a worktree reported OK forever
# (observed 2026-08-13: `<repo>.wt/land-probe-cwd-873`, clean tree, no PR, tip
# an ancestor of origin/main — a leak env-reconcile never surfaced, removed by
# hand). scripts/prune-merged-branches.sh has carried the EITHER/OR — plain
# ancestor OR merged-detect — since #173; this is the same cheap, network-free
# arm, which classify_worktree was missing.
#
# STRICT ancestry, on purpose. A branch whose tip EQUALS origin/<default> has no
# commits of its own — the shape of a worktree JUST created whose worker has not
# committed yet, i.e. live work. Non-strict containment would call that landed
# and hand /tidy's auto-heal a live worktree to remove, the expensive direction
# this classifier learned about in temperloop#658.
_branch_landed_in_default() {
  local repo="$1" branch="$2" default tip origin_tip
  default="$(default_branch_of "$repo")" || { printf 'false\n'; return 0; }
  tip="$(git -C "$repo" rev-parse --verify --quiet "refs/heads/$branch" 2>/dev/null)" || tip=""
  origin_tip="$(git -C "$repo" rev-parse --verify --quiet "refs/remotes/origin/$default" 2>/dev/null)" || origin_tip=""
  if [ -z "$tip" ] || [ -z "$origin_tip" ] || [ "$tip" = "$origin_tip" ]; then
    printf 'false\n'
    return 0
  fi
  if git -C "$repo" merge-base --is-ancestor "$tip" "$origin_tip" 2>/dev/null; then
    printf 'true\n'
  else
    printf 'false\n'
  fi
}

# ── Harness agent worktrees (temperloop#1405) ─────────────────────────────────
# _is_harness_worktree <wt_abs> — true iff the path sits under some checkout's
# $HARNESS_WT_SUBDIR. Keyed on the PATH LAYOUT, deliberately never on the branch
# name: `worktree-agent-<id>` is only the harness's current convention, and
# classifying a worktree from a naming convention is precisely the mistake
# temperloop#658 removed from this same function.
_is_harness_worktree() {
  case "$1" in
    */"$HARNESS_WT_SUBDIR"/*) return 0 ;;
    *) return 1 ;;
  esac
}

# _harness_worktree_age_days <wt_abs> — whole days since the worktree directory
# was last touched. FAIL-OPEN: an un-stat-able path reads as age 0, which routes
# to ACTIVE below — i.e. informational, never drift and never a removal
# suggestion. Guessing "old" from a failed stat is the one error that could cost
# someone their work.
_harness_worktree_age_days() {
  local m now
  m="$(file_mtime "$1")"
  case "$m" in ''|*[!0-9]*) printf '0'; return 0 ;; esac
  [ "$m" -gt 0 ] || { printf '0'; return 0; }
  now="$(now_epoch)"
  printf '%s' "$(( (now - m) / 86400 ))"
}

# _harness_worktree_verdict <slug> <dirt> <age_days> — the ONE place a harness
# worktree becomes an emitted CLASS. It is its OWN named class rather than a
# reason folded into LEAKED_WORKTREE/DIRTY_WORKTREE, because its remedy is
# different: nothing reaps these, the branch is `worktree-agent-<id>` with no PR
# behind it, and an operator reading the report needs to know that before acting.
# Two axes:
#   AGE   younger than $STALE_UNTRACKED_DAYS ⇒ ACTIVE. A live agent may still be
#         working in there, so this is informational, never counted as drift —
#         flagging every running agent would just re-create, one layer down, the
#         same noise this class exists to remove.
#   DIRT  past the horizon, only a CONFIRMED-CLEAN tree is ever handed to a
#         consumer as removable (STALE); uncommitted work downgrades to
#         STALE_DIRTY and an unprobeable tree to STALE_UNCERTAIN, both
#         report-only. Same never-remove-on-an-unestablished-verdict rule
#         _worktree_verdict enforces for the <repo>.wt layout.
_harness_worktree_verdict() {
  local slug="$1" dirt="$2" age_days="$3"
  if [ "$age_days" -le "$STALE_UNTRACKED_DAYS" ]; then
    printf 'HARNESS_WORKTREE:ACTIVE:%s' "$slug"
    return 0
  fi
  case "$dirt" in
    clean) printf 'HARNESS_WORKTREE:STALE:%s' "$slug" ;;
    dirty) printf 'HARNESS_WORKTREE:STALE_DIRTY:%s' "$slug" ;;
    *) printf 'HARNESS_WORKTREE:STALE_UNCERTAIN:%s' "$slug" ;;
  esac
}

# _harness_worktree_remedy <repo> <wt_abs> — the copy-pasteable removal command
# a STALE finding line carries. It names the leftover `worktree-agent-<id>`
# branch when git still records one: those branches are the second, invisible
# half of the leak (they survive the directory), so a remedy that removed only
# the directory would leave the report clean and the repo still accumulating.
_harness_worktree_remedy() {
  local repo="$1" wt="$2" branch merged
  if branch="$(_worktree_branch_of "$repo" "$wt")" && [ -n "$branch" ]; then
    # NEVER hand a consumer a FORCE delete for a branch whose merged-ness is
    # not established. `/tidy` runs this remedy VERBATIM and UNATTENDED as
    # auto-heal, and `git branch -D` deliberately bypasses the "not fully
    # merged" refusal — the only thing standing between an automated sweep and
    # somebody's unmerged commits.
    #
    # This is the same never-destroy-on-an-unestablished-verdict rule
    # _harness_worktree_verdict already applies to DIRT (an unprobeable tree
    # downgrades to report-only rather than removable), and the same one the
    # sibling <repo>.wt ladder applies through merged_detect_is_merged below.
    # The harness arm was the one place that skipped it. Caught by §3e —
    # independently, by both the shell and workflow reviewers.
    merged="$(merged_detect_is_merged "$repo" "$branch" 2>/dev/null)" || merged="false"
    if [ "$merged" = "true" ]; then
      # Confirmed merged. Still `-d`, not `-D`: if merged-detection is ever
      # wrong, git's own refusal is the backstop rather than nothing at all.
      printf 'git -C %s worktree remove %s && git -C %s branch -d %s' \
        "$repo" "$wt" "$repo" "$branch"
      return 0
    fi
    # Unmerged, or merged-ness indeterminate. Reclaim the directory — always
    # safe — but KEEP the branch and SAY so. A remedy that silently drops half
    # its job reads as complete; one that names what it left behind lets the
    # operator finish it deliberately.
    printf 'git -C %s worktree remove %s && git -C %s worktree prune  # branch %s KEPT: not confirmed merged — inspect, then delete by hand' \
      "$repo" "$wt" "$repo" "$branch"
    return 0
  fi
  printf 'git -C %s worktree remove %s && git -C %s worktree prune' \
    "$repo" "$wt" "$repo"
}

# ── classify_worktree <repo> <wt_dir> ─────────────────────────────────────────
# <repo> is the PARENT checkout root (without .wt); <wt_dir> is the
# <repo>.wt/<slug> — or <repo>/$HARNESS_WT_SUBDIR/agent-<id> — directory being
# examined.
classify_worktree() {
  local repo="$1" wt="$2" slug branch wt_abs merged state dirt
  slug="$(basename "$wt")"

  wt_abs="$(cd "$wt" 2>/dev/null && pwd -P)" || wt_abs="$wt"
  dirt="$(_worktree_dirt_state "$wt_abs")"

  # HARNESS-LAYOUT ARM (temperloop#1405) — ahead of the <repo>.wt tests below,
  # and additive to them. A harness agent worktree sits on a machine-made
  # `worktree-agent-<id>` branch that never had a PR, so the registered /
  # branch-gone / merged / PR-state ladder underneath says nothing useful about
  # it; run through that ladder it fell out the bottom as OK while the parent
  # checkout reported an opaque, remedy-less DIRTY on its behalf. It gets its
  # own named class instead, so real drift stops hiding among these.
  if _is_harness_worktree "$wt_abs"; then
    _harness_worktree_verdict "$slug" "$dirt" "$(_harness_worktree_age_days "$wt_abs")"
    return 0
  fi

  if ! git -C "$repo" worktree list --porcelain 2>/dev/null | grep -xF "worktree $wt_abs" >/dev/null; then
    _worktree_verdict ORPHANED "$slug" "$dirt"
    return 0
  fi

  # The worktree's REAL branch — never `build/$slug` (temperloop#658).
  if ! branch="$(_worktree_branch_of "$repo" "$wt_abs")"; then
    printf 'UNCERTAIN_WORKTREE:BRANCH_UNRESOLVED:%s' "$slug"
    return 0
  fi

  if ! git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
    _worktree_verdict BRANCH_GONE "$slug" "$dirt"
    return 0
  fi

  merged="$(merged_detect_is_merged "$repo" "$branch" 2>/dev/null)" || merged="false"
  if [ "$merged" = "true" ]; then
    _worktree_verdict MERGED "$slug" "$dirt"
    return 0
  fi

  state="$(_pr_state_of "$repo" "$branch")"
  if [ "$state" = "CLOSED" ]; then
    _worktree_verdict CLOSED "$slug" "$dirt"
    return 0
  fi

  # The plain-ancestor arm merged-detect structurally cannot cover
  # (temperloop#1404) — see _branch_landed_in_default. Runs LAST, so every
  # conclusive PR signal still wins: a branch whose commits are already
  # contained in origin/<default> has landed, whatever gh could or could not
  # tell us, and the verdict routes through _worktree_verdict exactly like the
  # others (dirty => report-only, unprobeable => UNCERTAIN).
  #
  # GATED ON THE PR NOT BEING OPEN. An OPEN PR is GitHub saying that branch is
  # still in flight — its commits can be contained in origin/<default> while the
  # worktree is alive (they landed by another route, the PR was retargeted) —
  # and temperloop#658's lesson is that calling live work a leak is this
  # classifier's expensive direction. UNKNOWN does NOT block the arm: UNKNOWN is
  # the no-PR-was-ever-opened case this arm exists for, and it is also what gh
  # being absent/offline prints, which this local, network-free test must keep
  # working under.
  if [ "$state" != "OPEN" ] && [ "$(_branch_landed_in_default "$repo" "$branch")" = "true" ]; then
    _worktree_verdict MERGED "$slug" "$dirt"
    return 0
  fi

  printf ''
}

# ── naive dependency-free plist XML key extractor ────────────────────────────
# _plist_extract_key <plist> <KeyName> — prints the <string> or <integer>
# value immediately following <key>KeyName</key>; empty if not found or the
# file is malformed (fail-open: caller treats empty as "unknown").
_plist_extract_key() {
  local plist="$1" key="$2"
  awk -v k="<key>${key}</key>" '
    index($0, k) { found=1; next }
    found {
      if (match($0, /<string>.*<\/string>/)) {
        line=$0; sub(/.*<string>/,"",line); sub(/<\/string>.*/,"",line); print line; exit
      }
      if (match($0, /<integer>.*<\/integer>/)) {
        line=$0; sub(/.*<integer>/,"",line); sub(/<\/integer>.*/,"",line); print line; exit
      }
      if (/<\/dict>/ || /<key>/) exit   # next key/end-of-dict with no value seen — give up
    }
  ' "$plist" 2>/dev/null || true
}

# ── classify_agent_checkout <plist> ───────────────────────────────────────────
# Prints AGENT_CHECKOUT_BEHIND:<dir> when <plist>'s declared WorkingDirectory
# resolves to a git checkout that is behind the already-fetched
# origin/<default> (#1624). Reuses _behind_origin_default — the exact
# default_branch_of -> merge-base --is-ancestor mechanism classify_cron_checkout
# uses for BEHIND_MAIN — rather than reimplementing the comparison.
#
# FAIL-OPEN, silently, on every uncertain case: an absent WorkingDirectory key,
# a path that doesn't exist, or a path that isn't a git checkout each print
# nothing ("can't verify") — never a crash, never a false BEHIND claim. This
# mirrors classify_agent's own freshness-unknown convention for a marker-less
# agent: silence folds into the report's OK row rather than asserting a verdict
# on evidence we don't have.
classify_agent_checkout() {
  local plist="$1" wd
  wd="$(_plist_extract_key "$plist" WorkingDirectory)"
  [ -n "$wd" ] || { printf ''; return 0; }
  [ -d "$wd" ] || { printf ''; return 0; }
  is_git_repo "$wd" || { printf ''; return 0; }
  if [ "$(_behind_origin_default "$wd")" = "true" ]; then
    printf 'AGENT_CHECKOUT_BEHIND:%s' "$wd"
  else
    printf ''
  fi
  return 0
}

# ── Host-role ownership helpers (#531) ────────────────────────────────────────
# _host_in_agent_hosts — true iff this host is in the explicit AGENT_HOSTS list.
_host_in_agent_hosts() {
  local h _i=0
  while [ "$_i" -lt "${#AGENT_HOSTS[@]}" ]; do
    h="${AGENT_HOSTS[$_i]}"; _i=$((_i + 1))
    [ "$h" = "$RECONCILE_HOST" ] && return 0
  done
  return 1
}

# _agent_installed_here <plist> — is the agent declared by <plist> installed on
# THIS host? An installed launchd user agent lives in $AGENT_INSTALL_DIR (default
# ~/Library/LaunchAgents), matched by plist basename first (the shape
# `make install-launchd-all` produces) then, as a fallback, by declared Label.
# READ-ONLY — a stat/glob only, never a launchctl call.
_agent_installed_here() {
  local plist="$1" base label f flabel
  [ -d "$AGENT_INSTALL_DIR" ] || return 1
  base="$(basename "$plist")"
  [ -e "$AGENT_INSTALL_DIR/$base" ] && return 0
  label="$(_plist_extract_key "$plist" Label)"
  [ -n "$label" ] || return 1
  for f in "$AGENT_INSTALL_DIR"/*.plist; do
    [ -e "$f" ] || continue
    flabel="$(_plist_extract_key "$f" Label)"
    [ "$flabel" = "$label" ] && return 0
  done
  return 1
}

# _agent_owned_here <plist> — does THIS host own (and therefore run) the agent
# declared by <plist>? Explicit AGENT_HOSTS list wins when set; otherwise the
# install-marker auto-detect above. When false, the agent is another host's
# responsibility and classify_agent reports EXPECTED_ELSEWHERE, not drift.
_agent_owned_here() {
  local plist="$1"
  if [ "${#AGENT_HOSTS[@]}" -gt 0 ]; then
    _host_in_agent_hosts
    return $?
  fi
  _agent_installed_here "$plist"
}

# _this_host_owns_cron — does THIS host own the cron-checkout role? Explicit
# AGENT_HOSTS list wins when set; otherwise auto-detect: a host owns the cron
# role iff it has at least one of the declared launchd agents installed (the same
# automation-host signal). A host with none installed (a laptop) does not own the
# cron checkouts, so their absence is EXPECTED_ELSEWHERE rather than ABSENT.
_this_host_owns_cron() {
  if [ "${#AGENT_HOSTS[@]}" -gt 0 ]; then
    _host_in_agent_hosts
    return $?
  fi
  local d p _i=0
  while [ "$_i" -lt "${#LAUNCHD_DIRS[@]}" ]; do
    d="${LAUNCHD_DIRS[$_i]}"; _i=$((_i + 1))
    [ -d "$d" ] || continue
    for p in "$d"/*.plist; do
      [ -e "$p" ] || continue
      _agent_installed_here "$p" && return 0
    done
  done
  return 1
}

# ── classify_agent <plist> ────────────────────────────────────────────────────
classify_agent() {
  local plist="$1" label interval last_run age_s marker classes=""

  label="$(_plist_extract_key "$plist" Label)"
  if [ -z "$label" ]; then
    printf 'MALFORMED_PLIST:%s' "$(basename "$plist")"
    return 0
  fi

  # Host-role gate (#531): an agent this host does not own belongs to the agent host,
  # not here — report EXPECTED_ELSEWHERE (a non-drift class) rather than probing
  # launchctl and false-flagging it AGENT_UNLOADED on a non-owning laptop. It also
  # gates the checkout-currency check below: WorkingDirectory is a path on THIS
  # host's filesystem, meaningful only when this host is the one actually running
  # the agent from it.
  if ! _agent_owned_here "$plist"; then
    printf 'EXPECTED_ELSEWHERE:%s' "$label"
    return 0
  fi

  # WorkingDirectory currency (#1624) — an axis independent of load/freshness
  # state: a checkout can be behind whether the agent is loaded, unloaded, or
  # stale, so this is computed unconditionally rather than nested under one of
  # the exclusive early-returns below.
  classes="$(classify_agent_checkout "$plist")"
  [ -n "$classes" ] && classes="${classes} "

  if ! command -v launchctl >/dev/null 2>&1; then
    printf '%s' "$classes"   # fail-open: tool absent, no loaded-state verdict possible
    return 0
  fi

  if ! _env_reconcile_launchctl list 2>/dev/null | awk '{print $3}' | grep -xF "$label" >/dev/null; then
    printf '%sAGENT_UNLOADED:%s' "$classes" "$label"
    return 0
  fi

  interval="$(_plist_extract_key "$plist" StartInterval)"
  case "$interval" in '' | *[!0-9]*) interval="$AGENT_DEFAULT_CADENCE_S" ;; esac

  # ── Freshness oracle (#1173 / #904) ─────────────────────────────────────────
  # launchd touches StandardOutPath's mtime on EVERY wake — including a wake that
  # aborts in seconds having done nothing — so that mtime cannot distinguish "the
  # job ran" from "launchd opened the file" (a 0-byte log can carry a current
  # mtime; this is how the F#1170 silent-abort nights stayed invisible to the very
  # probe meant to catch them). The reliable signal is a heartbeat MARKER the job
  # itself writes on SUCCESSFUL completion; env-reconcile reads the marker, never
  # StandardOutPath. Agents opt in by `touch`-ing $AGENT_HEARTBEAT_DIR/<label>.ran
  # at the end of a successful run.
  marker="$AGENT_HEARTBEAT_DIR/${label}.ran"
  if [ -f "$marker" ]; then
    last_run="$(file_mtime "$marker")"
    age_s=$(( $(now_epoch) - last_run ))
    # Stale once the last SUCCESSFUL run is older than one full cadence: a single
    # missed or silently-aborted cycle leaves the marker untouched and trips this.
    if [ "$age_s" -gt "$interval" ]; then
      printf '%sAGENT_STALE:%s' "$classes" "$label"
      return 0
    fi
    printf '%s' "$classes"
    return 0
  fi

  # No heartbeat marker: the agent has not adopted the reliable signal, and
  # StandardOutPath mtime is untrustworthy (#1173), so we do NOT assert freshness
  # from it — a false-STALE every run is noise, and the false-FRESH it used to
  # emit was the F#1170 blind spot. The loaded-state check above still catches an
  # UNLOADED agent; freshness for a marker-less agent is reported as unknown
  # (nothing emitted) until it adopts the heartbeat. Fail-open. $classes (e.g. an
  # AGENT_CHECKOUT_BEHIND finding) still surfaces on its own independent axis.
  printf '%s' "$classes"
}

# ── agent_status_by_label <label> ─────────────────────────────────────────────
# Finds the launchd agent declaring Label <label> among the resolved
# LAUNCHD_DIRS registry and returns classify_agent's verdict for its plist —
# the same AGENT_STALE:<label> / AGENT_UNLOADED:<label> signal the
# direct-invocation report already emits (classify_agent above), reused
# (never reinvented) by /check-in's class-C activation discharge
# (claude/commands/check-in.md § Pending-activations ledger) for the
# launchd sub-case: a record's `locus` names an agent's declared Label, and
# discharge polls this instead of standing up a new "is the agent alive"
# sensor. Prints one of:
#   AGENT_STALE:<label>     loaded, but no evidence of a run within cadence
#   AGENT_UNLOADED:<label>  declared but not currently loaded
#   (empty)                 fresh — fired within its own declared cadence
# and exits 0 in all three cases. If no plist among LAUNCHD_DIRS declares
# <label>, prints nothing and exits 1 — "can't verify", the same fail-open
# shape as kernel_pin_tag_of's "not yet reached": the caller keeps the
# record open and reports it as unverifiable rather than guessing.
agent_status_by_label() {
  local label="$1" dir plist found_label
  local _i=0
  while [ "$_i" -lt "${#LAUNCHD_DIRS[@]}" ]; do
    dir="${LAUNCHD_DIRS[$_i]}"; _i=$((_i + 1))
    [ -d "$dir" ] || continue
    for plist in "$dir"/*.plist; do
      [ -e "$plist" ] || continue
      found_label="$(_plist_extract_key "$plist" Label)"
      if [ "$found_label" = "$label" ]; then
        classify_agent "$plist"
        return 0
      fi
    done
  done
  return 1
}

# ── Main enumeration + Emit — DIRECT-INVOCATION ONLY ─────────────────────────
# Guarded so this script is also safely SOURCEABLE as a library: a caller
# (e.g. /check-in's class-B and class-C activation discharge —
# claude/commands/check-in.md § Pending-activations ledger) can `source` this
# file with no args to pull in OPERATOR_CHECKOUTS (the consumer registry),
# LAUNCHD_DIRS, and the kernel_pin_tag_of / semver_ge / agent_status_by_label
# helpers above WITHOUT running the reconciler or hitting one of its
# `exit` calls (which, under `source`, would exit the *caller's* shell, not
# just return). Direct execution (`env-reconcile.sh [--format ...]`) is
# unaffected — this guard is true exactly when the script is its own $0.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then

declare -a WT_ROOTS=()
_i=0
while [ "$_i" -lt "${#CRON_CHECKOUTS[@]}" ]; do
  _c="${CRON_CHECKOUTS[$_i]}"; _i=$((_i + 1))
  [ -d "${_c}.wt" ] && WT_ROOTS+=("$_c")
done
_i=0
while [ "$_i" -lt "${#OPERATOR_CHECKOUTS[@]}" ]; do
  _c="${OPERATOR_CHECKOUTS[$_i]}"; _i=$((_i + 1))
  [ -d "${_c}.wt" ] && WT_ROOTS+=("$_c")
done

# The SECOND worktree layout (temperloop#1405): checkouts that host harness
# agent worktrees under $HARNESS_WT_SUBDIR. A separate root list, not a filter
# on WT_ROOTS — a checkout can host harness worktrees without ever having had a
# <repo>.wt/ directory, and both of the live instances in #1405 were exactly
# that shape.
declare -a HARNESS_WT_ROOTS=()
_i=0
while [ "$_i" -lt "${#CRON_CHECKOUTS[@]}" ]; do
  _c="${CRON_CHECKOUTS[$_i]}"; _i=$((_i + 1))
  [ -d "${_c}/${HARNESS_WT_SUBDIR}" ] && HARNESS_WT_ROOTS+=("$_c")
done
_i=0
while [ "$_i" -lt "${#OPERATOR_CHECKOUTS[@]}" ]; do
  _c="${OPERATOR_CHECKOUTS[$_i]}"; _i=$((_i + 1))
  [ -d "${_c}/${HARNESS_WT_SUBDIR}" ] && HARNESS_WT_ROOTS+=("$_c")
done

# Resolve once (#531): does THIS host own the cron-checkout role? On a
# non-owning host a cron checkout that is simply not present here is
# EXPECTED_ELSEWHERE, not ABSENT — the absence is the owning host's concern.
if _this_host_owns_cron; then HOST_OWNS_CRON=1; else HOST_OWNS_CRON=0; fi

CRON_LINES=""
_i=0
while [ "$_i" -lt "${#CRON_CHECKOUTS[@]}" ]; do
  c="${CRON_CHECKOUTS[$_i]}"; _i=$((_i + 1))
  [ -n "$c" ] || continue
  cls="$(classify_cron_checkout "$c")"
  # A missing cron checkout on a host that does not own the cron role isn't
  # drift — reclassify ABSENT → EXPECTED_ELSEWHERE so a laptop stops reporting
  # the agent host's cron checkouts as ABSENT (#531).
  if [ "$cls" = "ABSENT" ] && [ "$HOST_OWNS_CRON" -eq 0 ]; then
    cls="EXPECTED_ELSEWHERE"
  fi
  if [ -z "$cls" ]; then
    CRON_LINES="${CRON_LINES}  OK           $c"$'\n'
  else
    case "$cls" in
      EXPECTED_ELSEWHERE)
        # Not this host's role (#531) — informational, never drift.
        CRON_LINES="${CRON_LINES}  EXPECTED     $c  [${cls}]"$'\n'
        ;;
      ABSENT | NOT_A_REPO)
        CRON_LINES="${CRON_LINES}  ${cls}$(printf '%*s' $((13 - ${#cls})) '')$c"$'\n'
        ;;
      *)
        CRON_LINES="${CRON_LINES}  DRIFT        $c  [${cls% }]"$'\n'
        add "- ⚠️ cron/kernel checkout drift: $c — ${cls% }" drift
        ;;
    esac
  fi
done

OPERATOR_LINES=""
_i=0
while [ "$_i" -lt "${#OPERATOR_CHECKOUTS[@]}" ]; do
  c="${OPERATOR_CHECKOUTS[$_i]}"; _i=$((_i + 1))
  [ -n "$c" ] || continue
  cls="$(classify_operator_checkout "$c")"
  # Dormancy is classified beside the drift classes, never folded into them
  # (temperloop#2041): it is informational, so it must neither raise an alarm on
  # its own nor be MASKED by a drift class that happens to sit on the same
  # checkout — hence it is appended to whichever line that checkout prints.
  dorm="$(classify_operator_dormancy "$c")"
  if [ -z "$cls" ]; then
    if [ -n "$dorm" ]; then
      OPERATOR_LINES="${OPERATOR_LINES}  DORMANT      $c  [${dorm}]"$'\n'
    else
      OPERATOR_LINES="${OPERATOR_LINES}  OK           $c"$'\n'
    fi
  else
    case "$cls" in
      ABSENT | NOT_A_REPO)
        OPERATOR_LINES="${OPERATOR_LINES}  ${cls}$(printf '%*s' $((13 - ${#cls})) '')$c"$'\n'
        ;;
      *)
        OPERATOR_LINES="${OPERATOR_LINES}  DRIFT        $c  [${cls% }${dorm:+ $dorm}]"$'\n'
        add "- ⚠️ operator checkout drift: $c — ${cls% }${dorm:+ $dorm}" drift
        # A stale vendored hook is only actionable with the command that re-syncs
        # it, so emit the remedy alongside the class in BOTH formats (the report
        # table below, and the FINDINGS block --format entry renders). Appended
        # via `add` WITHOUT the drift flag: it annotates the alarm already
        # counted above rather than counting as a second one.
        _j=0
        while [ "$_j" -lt "${#VENDORED_HOOKS[@]}" ]; do
          h="${VENDORED_HOOKS[$_j]}"; _j=$((_j + 1))
          # Match the token's TRAILING SPACE (_stale_vendored_hooks emits
          # `STALE_VENDORED_HOOK:<hook> `). Without it a hook basename that is a
          # prefix of another cross-matches, emitting a spurious re-sync line for
          # an in-sync hook the moment ENV_RECONCILE_VENDORED_HOOKS lists two
          # with a shared prefix.
          case "$cls" in
            *"STALE_VENDORED_HOOK:$h "*)
              remedy="$(_vendored_hook_sync_cmd "$c" "$h")"
              # The target lives in the consumer-side FLEET Makefile, not in this
              # kernel repo — so name the run location, or an operator acting on
              # this line from a kernel checkout just gets "No rule to make target".
              OPERATOR_LINES="${OPERATOR_LINES}               ↳ re-sync $h: $remedy  (run from the foundation checkout)"$'\n'
              add "  - remedy — re-sync $h into $c: \`$remedy\` (run from the foundation checkout)"
              ;;
          esac
        done
        ;;
    esac
  fi
done

# Composed ~/.claude/CLAUDE.md staleness (COMPOSED_STALE) — a single
# machine-wide check, not per-checkout (see classify_composed_claude_md's own
# header and the "Composed CLAUDE.md staleness" block in this file's header).
COMPOSED_LINES=""
cls="$(classify_composed_claude_md "$CLAUDE_MD_TARGET" "$CLAUDE_MD_SOURCE_CHECKOUT")"
if [ -z "$cls" ]; then
  COMPOSED_LINES="  OK           $CLAUDE_MD_TARGET"$'\n'
else
  case "$cls" in
    UNVERIFIABLE:*)
      # Fail-open, informational — never counted as drift (add's default).
      COMPOSED_LINES="  UNVERIFIABLE $CLAUDE_MD_TARGET  [${cls}]"$'\n'
      ;;
    *)
      COMPOSED_LINES="  DRIFT        $CLAUDE_MD_TARGET  [${cls% }]"$'\n'
      add "- ⚠️ composed CLAUDE.md drift: $CLAUDE_MD_TARGET — ${cls% } (source: $CLAUDE_MD_SOURCE_CHECKOUT)" drift
      ;;
  esac
fi

WT_LINES=""
wt_checked=0
_i=0
while [ "$_i" -lt "${#WT_ROOTS[@]}" ]; do
  c="${WT_ROOTS[$_i]}"; _i=$((_i + 1))
  while IFS= read -r wt; do
    [ -n "$wt" ] || continue
    wt_checked=$((wt_checked + 1))
    cls="$(classify_worktree "$c" "$wt")"
    if [ -z "$cls" ]; then
      WT_LINES="${WT_LINES}  OK           $wt"$'\n'
    else
      WT_LINES="${WT_LINES}  DRIFT        $wt  [${cls}]"$'\n'
      # The finding line carries the DISPOSITION, not just the class, so a
      # consumer acting on this surface (/tidy's env-hygiene auto-heal,
      # /check-in) cannot read a report-only verdict as a removal instruction
      # (temperloop#658).
      case "$cls" in
        DIRTY_WORKTREE:*)
          add "- ⚠️ worktree with UNCOMMITTED work — REPORT ONLY, never remove: $wt — ${cls}" drift
          ;;
        UNCERTAIN_WORKTREE:*)
          add "- ⚠️ worktree classification UNDETERMINED — REPORT ONLY, never remove: $wt — ${cls}" drift
          ;;
        *)
          add "- ⚠️ leaked worktree (clean tree, safe to remove): $wt — ${cls}" drift
          ;;
      esac
    fi
  done < <(find "${c}.wt" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
done

# ── Harness agent worktrees (temperloop#1405) ────────────────────────────────
# The second layout, scanned into the same WT_LINES section so an operator reads
# every worktree in one place. Each finding carries a REMEDY POINTER, because
# the whole defect being fixed here is that these surfaced as an opaque parent
# DIRTY telling the reader something was there but never what to do about it.
_i=0
while [ "$_i" -lt "${#HARNESS_WT_ROOTS[@]}" ]; do
  c="${HARNESS_WT_ROOTS[$_i]}"; _i=$((_i + 1))
  while IFS= read -r wt; do
    [ -n "$wt" ] || continue
    wt_checked=$((wt_checked + 1))
    cls="$(classify_worktree "$c" "$wt")"
    case "$cls" in
      HARNESS_WORKTREE:ACTIVE:*)
        # Named, but NOT drift: a live agent may still be working in there.
        WT_LINES="${WT_LINES}  HARNESS      $wt  [${cls}]"$'\n'
        ;;
      HARNESS_WORKTREE:STALE:*)
        WT_LINES="${WT_LINES}  DRIFT        $wt  [${cls}]"$'\n'
        add "- ⚠️ stale harness agent worktree (clean tree, safe to remove): $wt — ${cls}" drift
        add "  - remedy — remove it and its leftover branch: \`$(_harness_worktree_remedy "$c" "$wt")\`"
        ;;
      HARNESS_WORKTREE:*)
        WT_LINES="${WT_LINES}  DRIFT        $wt  [${cls}]"$'\n'
        add "- ⚠️ stale harness agent worktree with unsaved or unprobeable work — REPORT ONLY, never remove: $wt — ${cls}" drift
        add "  - remedy — inspect before disposing: \`git -C $wt status\`"
        ;;
      *)
        # Unreachable while the harness arm owns this layout; kept so a future
        # classifier change degrades to a visible line, never a silent drop.
        WT_LINES="${WT_LINES}  OK           $wt"$'\n'
        ;;
    esac
  done < <(find "${c}/${HARNESS_WT_SUBDIR}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
done

# Regenerable background-job scratch (temperloop#1111). Machine-wide like the
# composed-CLAUDE.md check, not per-checkout: the harness owns ONE job root.
# The two verdicts are BOTH drift, but they are disposed differently by /tidy —
# RECLAIMABLE is auto-healed in-lane (job-scratch-reclaim.sh --apply), while
# ABANDONED is report-only, because a non-terminal job can still resume and
# deleting a live run's scratch mid-flight is worse than leaving the bytes.
JOB_SCRATCH_LINES=""
job_scratch_checked=0
while IFS= read -r _js_line; do
  [ -n "$_js_line" ] || continue
  job_scratch_checked=$((job_scratch_checked + 1))
  cls="${_js_line%% *}"
  _js_dir="${_js_line#* }"
  JOB_SCRATCH_LINES="${JOB_SCRATCH_LINES}  DRIFT        ${_js_dir}/tmp  [${cls}]"$'\n'
  case "$cls" in
    JOB_SCRATCH_RECLAIMABLE:*)
      add "- ⚠️ reclaimable job scratch: ${_js_dir}/tmp — ${cls}" drift
      # Emit the remedy in BOTH formats (same convention as the vendored-hook
      # re-sync line above): the report table an operator reads by eye, and the
      # FINDINGS block --format entry renders into the review surface. Appended
      # via `add` WITHOUT the drift flag — it annotates the alarm already
      # counted above rather than counting as a second one.
      JOB_SCRATCH_LINES="${JOB_SCRATCH_LINES}               ↳ reclaim: workflows/scripts/build/job-scratch-reclaim.sh --apply"$'\n'
      add "  - remedy — reclaim it: \`workflows/scripts/build/job-scratch-reclaim.sh --apply\`"
      ;;
    *)
      add "- ⚠️ abandoned job scratch: ${_js_dir}/tmp — ${cls} (report-only: a non-terminal job may still resume)" drift
      ;;
  esac
done < <(job_scratch_list)

AGENT_LINES=""
agent_checked=0
_i=0
while [ "$_i" -lt "${#LAUNCHD_DIRS[@]}" ]; do
  d="${LAUNCHD_DIRS[$_i]}"; _i=$((_i + 1))
  if [ -z "$d" ] || [ ! -d "$d" ]; then continue; fi
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    agent_checked=$((agent_checked + 1))
    cls="$(classify_agent "$p")"
    if [ -z "$cls" ]; then
      AGENT_LINES="${AGENT_LINES}  OK           $p"$'\n'
    else
      case "$cls" in
        EXPECTED_ELSEWHERE:*)
          # Not this host's role (#531) — informational, never drift.
          AGENT_LINES="${AGENT_LINES}  EXPECTED     $p  [${cls}]"$'\n'
          ;;
        *)
          # cls may carry a trailing space when classify_agent combined an
          # AGENT_CHECKOUT_BEHIND token (its own field, always space-appended)
          # with nothing after it — strip it (same convention as the operator-
          # checkout emit site above) rather than print an empty trailing token.
          AGENT_LINES="${AGENT_LINES}  DRIFT        $p  [${cls% }]"$'\n'
          add "- ⚠️ launchd agent drift: $p — ${cls% }" drift
          ;;
      esac
    fi
  done < <(find "$d" -mindepth 1 -maxdepth 1 -type f -name '*.plist' 2>/dev/null)
done

# ── Emit ───────────────────────────────────────────────────────────────────
if [ "$FORMAT" = "entry" ]; then
  [ "$alarms" -eq 0 ] && exit 0   # clean → append nothing
  ts="$(date '+%Y-%m-%d %H:%M')"
  host="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo host)"
  printf '### %s · env reconcile · %s\n' "$ts" "$host"
  printf -- '- **Decision:** dispose of %d environment-drift alarm(s) below.\n' "$alarms"
  printf -- '- **Findings:**\n'
  printf '%s' "$FINDINGS" | sed 's/^/  /'
  printf -- '- **Status:** open\n'
  exit 0
fi

echo "=== env reconcile ==="
echo "-- cron/kernel checkouts --"
printf '%s' "$CRON_LINES"
echo "-- operator/consumer checkouts --"
printf '%s' "$OPERATOR_LINES"
echo "-- composed CLAUDE.md --"
printf '%s' "$COMPOSED_LINES"
echo "-- worktrees ($wt_checked checked) --"
printf '%s' "$WT_LINES"
echo "-- job scratch ($job_scratch_checked flagged) --"
printf '%s' "$JOB_SCRATCH_LINES"
echo "-- launchd agents ($agent_checked checked) --"
printf '%s' "$AGENT_LINES"
echo "---"
if [ "$alarms" -gt 0 ]; then
  echo "DRIFT: $alarms"
else
  echo "OK"
fi
exit 0

fi # end direct-invocation guard
