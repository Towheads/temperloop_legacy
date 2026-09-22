---
title: TemperLoop CLI install ladder
slug: install-cli
---

## Problem

Without a CLI entrypoint, a stranger evaluating this kernel would have to
hand-clone the repo, wire up symlinks, and run raw scripts before seeing any
real behavior — with no natural on-ramp from "look, read-only" to "opt my own
repo in." That is a large trust ask to make of someone still deciding
whether the tool is worth adopting, and a partial or wrong-flag install can
leave a repo half-configured with no easy way to check what actually landed.

## How it works

**Install.** A short bootstrap script (`bin/bootstrap.sh`, fetched over
`curl` or inspected first) shallow-clones this repo into
`~/.local/share/temperloop` (fast-forwarding it in place on re-run) and
symlinks `~/.local/bin/temperloop` to the entrypoint inside that checkout.
No shell-rc edits, no `sudo`. Uninstalling means removing those two paths;
that is the installer's entire footprint. (Through the v0.15.0 → v0.19.0
rename window it also symlinked a `foundation` compat shim, since the CLI was
named `foundation` before its rename. That symlink is no longer created; an
install that predates v0.19.0 may still carry one, and `temperloop uninstall`
removes it.)

**Update.** `temperloop update` (ADR 0002 "Managed-clone state ownership") is
the sole sanctioned way to move that managed clone's `HEAD` forward once it
exists. It fetches release tags (auto-converting a tagless `--depth 1` clone
via `git fetch --unshallow` on first run), prints the full CHANGELOG delta
for the jump — any `BREAKING`-marked section called out — BEFORE asking for
consent (an explicit `--yes`, an interactive `y/N`, or a legible refusal on a
non-interactive run; there is no timeout-as-consent), checks the on-disk
install manifest's schema against the target tag's own `manifest.sh` before
touching `HEAD` at all, then checks out the tag and re-runs `install` +
`doctor`. It takes no `--dir`/`--repo` argument — its entire write surface is
the managed clone's own git state plus the machine surface `install.sh`
already owns, never a repo-tracked path in any other repo.

**The adoption path: testbed -> first epic -> promote -> adopt.** The reader
runs `temperloop testbed`, which builds a private *duplicate* of a real repo
of their own (not a fork — a fork of a public repo is forcibly public, and
carries an upstream that PR tooling offers as a base) and carries their open
issues across, since GitHub never copies issues to a fork; they run
`temperloop init` there and take the resulting first epic through `/assess`
-> `/build`. The evaluation is therefore the real pipeline doing real work on
the reader's own code, in a repo that is disposable — and `/promote` carries
the work worth keeping back into the original before `temperloop testbed
--teardown` reclaims the duplicate. `README.md` § 3 is the canonical command
sequence.

**`temperloop init` — the adopt step.** Run it in the
testbed to evaluate, and again in the real repo to adopt; it behaves
identically in both. It opts a repo in, then **hands off**. `init --dry-run`
previews the tree-only proposal PR with zero API writes of any kind. `init`
for real does exactly four things and stops: bootstraps `.temperloop/config`,
proposes any tree changes (e.g. a `boards.conf` entry) via a reviewable PR —
nothing ever lands without review — offers the kernel-shipped **first epic**
("Set up `<project>` with temperloop",
[ADR 0010](../adr/0010-onboarding-as-first-executed-epic.md)), and prints a
`next step:` handoff line. It applies **no API state of its own**.

**This step's handoff is the one part that needs `temperloop install`**:
`/assess` and `/build` are Claude Code slash commands, deployed into
`~/.claude/` by the install below, so unlike the legacy rungs above this one
does not end self-contained. `init` probes for the installed command and
prints an extra `prerequisite:` line when it is missing, rather than handing
the reader a pointer to something that isn't on their machine.

**Where the setup writes went.** Branch protection, head-branch auto-delete,
the merge-queue disposition, the required `checks` status context, the CI
workflow, and the adopter's review principles are all applied by that first
epic, driven through the real pipeline (`/assess --epic N` → `/build`) with
per-write consent and consequences disclosed at the moment of asking. `init`
used to apply a required check and a label set itself, under its own consent
prompt; that was retired (temperloop#796) for two reasons worth naming:
`init`'s required-check apply armed a `checks` context with no regard for
whether anything would ever post it (the self-brick the epic's structural
congruence rule makes unreachable), and the `fnd:`/pipeline labels are
already created lazily at point of use by the issues-only tracker backend,
so pre-creating them bought nothing. The flags that gated those applies
(`--yes/--no-required-check`, `--yes/--no-labels`, `--yes/--no-board`) are
**retained as deprecated no-ops**: each still parses, prints one line naming
where its step went, and is ignored. Nothing that passes them breaks.
`--tracker-mode` and the `--provision-*` family went further — they no
longer parse at all, and each exits 2 naming the removal release.

**Tracker mode: there is only one, and there is no way back.** Issues-only
(`board.<N>.backend=issues`) is the sole tracker backend — not merely the
sole *init-time* default. The Projects-v2 arm was deprecated by ADR 0004
and **removed outright** in the Projects-v2 removal release (epic
temperloop#524), so after this release there is **no configuration path
back to Projects-v2**: no flag, no `boards.conf` axis, and no environment
variable restores it. `init` cannot provision a Projects board, and neither
can anything else in this repo.

Provisioning one by hand no longer helps either, and it is worth being
precise about why: the adapter has no Projects code path left to reach. A
stale `board.<N>.backend=projects` line in an operator's `boards.conf` is
**refused** rather than silently downgraded — `board_backend` exits
non-zero and names the migration path, so a conf line asking for a backend
that no longer exists fails loudly instead of quietly doing something else.
An adopter who genuinely wants Projects-v2 forks `board.sh` and maintains
that arm themselves.

If you are crossing over from a Projects board that still holds live state,
the migration is ordered and time-boxed: check out **v0.25.0** — the last
release carrying `workflows/scripts/board/migrate-board-to-issues.sh`,
which was deleted in v0.26.0 per ADR 0004's ordering pin — run that script
against the board, then delete the `backend=projects` line and pull
forward.

**Board number: a fresh install mints board 1, on purpose.** A repo with no
prior `.temperloop/config` and no `--board` flag gets `board.1.*` in the
proposed `boards.conf` entry. That default is deliberately standalone-kernel
numbering — a stranger cloning this kernel has no other boards to collide
with, so `1` is simply the first free id. It is **not** a recommendation for
every adopter: a fleet operator who already runs several repos under their
own board-numbering convention (their own boards 3/4/5/6/7, say) is expected
to override it, not collide with it. Teaching `init` to detect and match an
operator's fleet-specific numbering was considered and rejected — that
convention names one operator's own repos, which is overlay knowledge, and
baking it into the kernel installer would put overlay-specific state inside
code a stranger with no fleet is expected to run. Two escapes already cover
the fleet case instead: pass `--board <n>` explicitly on the `init` command
line, or run `init` again inside a repo that already has a
`.temperloop/config` — its prior `tracker.board` is carried forward
unless overridden.

**The safety contract.** `init` writes no API state at all, so its only mutating calls
are the tree-only proposal PR and the first-epic issue it offers to file
(plus, if you decline, the one Backlog pointer that keeps the gap tracked);
`--dry-run` skips even those.

**`doctor.sh` link states.** Every managed install path
(symlinks under `~/.claude/`, the composed `CLAUDE.md`, the `gh` logger
shim) is classified into one of five states: `OK` (symlink present and
correct, or the managed real file/shim is present), `MISSING` (target does
not exist), `DRIFT` (symlink present but points somewhere else, or a real
file exists where the wrong kind of thing is expected), `SHADOWED` (a real
file/directory sits where a symlink should be), or `DANGLING` (symlink
present but its target does not exist on disk). `bash
workflows/scripts/install/doctor.sh` exits 0 only
when every entry is `OK`, 1 otherwise (`temperloop install` also prints this
exact command at the end of its own run — see § Verify in `bin/README.md`).
**`temperloop doctor` is the first-class way in**: the subcommand `exec`s that
same script, so its output and exit code are identical by construction and it
takes the same optional `<toolkit-root>` argument. (Earlier releases had no
such subcommand and both this page and `bin/README.md` said so; that statement
is superseded.) It separately reports a
knowledge-store root check (does the agent-plane Obsidian MCP vault agree
with the script-plane `KNOWLEDGE_STORE_ROOT`?), a cross-checkout
install-source check (does the real, symlink-resolved location of a
representative installed surface —
`~/.claude/hooks/session-start-drain.sh` — belong to the SAME checkout
doctor is running from, or has `~/.claude` silently been bound to a
different clone entirely? A mismatch names both real paths and both
`.kernel-pin` tags), and, when a `boards.conf` is present, the per-board
issue-cache store state — all read-only, all `SKIPPED`-not-`FAIL` when the
underlying pieces simply aren't configured yet (the knowledge-store and
cross-checkout checks additionally FAIL — not just report — on a genuine
mismatch, contributing to doctor's exit code). It also reports **toolkit
provenance** — whether the toolkit code in this checkout is byte-identical to
the release it claims to be — as a `WARN`-level, strictly non-fatal check that
never touches the exit code; see
[toolkit provenance](toolkit-provenance.md).

**Installed build-workflow content check.** The five link states above
compare a symlink's *target string*, and the cross-checkout check compares
*path identity* — neither can see a correctly-targeted
`~/.claude/workflows/build-level.mjs` whose *content* is weeks stale, which
is exactly what `/build`, `/sweep` and `/fix` execute when they invoke the
orchestrator by `scriptPath`. So `doctor.sh` separately compares every
installed `~/.claude/workflows/*.mjs` against this checkout's own
`claude/workflows/*.mjs` by sha256 (byte compare when no hasher is on
`PATH`) and reports one of five outcomes per file: `OK` (byte-identical),
`DRIFT` (they differ — printing both sizes, both mtimes and both digests,
naming which side is newer and by how much, and naming the physical
directory the installed copy really lives in), `ABSENT` (nothing installed
there at all — its own outcome, explicitly *neither* drift *nor* in-sync),
`UNKNOWN` (something is there but could not be compared — a dangling
symlink, a directory, an unreadable file — indeterminate, never a silent
pass), or `SKIPPED` (this checkout ships no workflows to compare against).
`DRIFT` and `UNKNOWN` contribute to doctor's exit code. It **detects and
reports only** — it never writes to `~/.claude`, because installing is
global shared state and a deliberately operator-run action; it names the
remedy and leaves the decision to a human.

**Kernel/overlay compose.** `workflows/scripts/install-claude-md.sh`
composes the installed `~/.claude/CLAUDE.md` from three pieces, in order: a
generated-file banner, the kernel doc (`claude/CLAUDE.kernel.md`, with any
`{{SETTING_NAME}}` placeholder tokens substituted from config), a rendered
"Knowledge store routing" section, and the personal overlay doc
(`claude/CLAUDE.overlay.md`) verbatim. It is idempotent — composing the same
sources twice on the same machine reproduces the target byte-for-byte — and
alongside the composed file it writes a T0 inventory of every
knowledge-store note the composed rules actually reference.
An opt-in `INSTALL_CLAUDE_MD_KERNEL_ONLY=1` render-only mode emits the
rendered kernel doc alone — no banner, no knowledge-store-routing section,
no overlay, no T0-inventory write — for
`workflows/scripts/count-prose.sh`'s tier-1 prose-plane count (tier-1 = the
kernel-authored line count alone, as opposed to the full kernel+overlay
total a real install renders). `temperloop install` (this repo's own CLI;
a downstream fleet's `make install-claude` wrapper is the same story) never
sets it, so a normal compose is unaffected.

## Integration

Consumes: `gh` (authenticated) and `claude` on `PATH` — both are checked
before any subcommand does anything, and a missing tool prints exactly
what's missing and how to fix it rather than a stack trace. `doctor.sh`
consumes `workflows/scripts/install/links.sh`'s managed-path enumeration and
`workflows/scripts/build/build.config.sh` / `workflows/scripts/lib/
knowledge_store.sh` / `knowledge_store_obsidian.sh` for the vault-agreement
check. `install-claude-md.sh` is invoked by
`temperloop install` (its `claude-md`-kind managed path) and is itself
verified by `doctor.sh`'s `claude-md` classification.

## Resource impact

Storage: a shallow clone into `~/.local/share/temperloop` (typically tens of
MB) plus a handful of negligible symlinks in `~/.local/bin`. API budget:
`doctor.sh` and `install`/`uninstall` issue no `gh` mutations and make no
model calls at all; `init`'s only mutating calls are the tree-only proposal
PR and the first-epic issue it offers to file.
Runtime: `doctor.sh` is pure shell and sub-second.

## Telemetry

None dedicated. Each subcommand's own printed output is the observable
surface: `doctor`'s per-entry
`OK`/`MISSING`/`DRIFT`/`SHADOWED`/`DANGLING` table and its exit code,
`init --dry-run`'s preview diff, and `init`'s closing `next step:` handoff
line (the marker the tier-2 round-trip workflow greps to prove the live path
reached the handoff rather than degrading earlier). A failure surfaces as a
non-zero exit code plus an explicit `skipped — <reason>` or `FAIL —` line,
never a silent no-op.
