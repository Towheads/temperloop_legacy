# TemperLoop CLI

`temperloop` is the **newcomer/adoption surface** for this kernel — a single
POSIX entrypoint for someone who has never touched this project's Makefile,
board, or build pipeline. If you already have a checkout, in-checkout
operations (the board toolkit, the build/sweep pipeline, the quality gates)
stay on `make` — this CLI does not duplicate a Makefile target.

(The CLI was named `foundation` before foundation #893's rename to the
project's ratified public name, TemperLoop. `foundation <sub>` worked through
a compat window that **closed in v0.19.0**: `kernel/bin/foundation` no longer
execs `temperloop`, it refuses and names the replacement — see the v0.15.0
CHANGELOG `BREAKING` entry for the migration note and the v0.19.0 entry for
what each legacy name now does.)

## Prerequisites

`temperloop` shells out to two tools it doesn't vendor, and checks both
before doing anything:

- [Claude Code](https://docs.claude.com/en/docs/claude-code/quickstart) (`claude` on `PATH`) — drives the actual work.
- [GitHub CLI](https://cli.github.com) (`gh`), authenticated (`gh auth login`) — every subcommand that talks to GitHub needs it.

If either is missing, `temperloop` prints exactly what's missing and how to
fix it — never a bare stack trace.

## Install

**Inspect first (recommended)** — read the installer before you run it:

```sh
curl -fsSL https://raw.githubusercontent.com/Towheads/temperloop/main/bin/bootstrap.sh -o temperloop-bootstrap.sh
less temperloop-bootstrap.sh          # read it — see exactly what it does
sh temperloop-bootstrap.sh
```

**One-line**, once you trust the source:

```sh
curl -fsSL https://raw.githubusercontent.com/Towheads/temperloop/main/bin/bootstrap.sh | sh
```

The installer does exactly three things, nothing else, and the details
differ between a fresh install and a re-run (ADR 0002, "Managed-clone state
ownership"):

- **Fresh install**: clones `temperloop` into `~/.local/share/temperloop`
  with enough history for tags to resolve, then **lands the clone on the
  latest release tag** (highest `vX.Y.Z` by version sort) — you get a
  released version, never `main`'s unreleased tip. If the remote genuinely
  has no release tags yet, it stays on the default branch with an explicit
  warning printed to stderr.
- **Re-run** (an install already exists): the bootstrap script never pulls
  or fast-forwards the existing clone in place — it **delegates to
  `temperloop update`**, which surfaces the CHANGELOG delta (including any
  `BREAKING` sections) and asks for consent before moving anything. An
  install that predates the `update` subcommand fails with a stated
  recovery (reinstall fresh, or move the clone to a tag by hand) rather than
  a silent pull or a dead end.

Either way it also symlinks `~/.local/bin/temperloop` to the entrypoint
inside that checkout, and prints a `PATH` reminder if `~/.local/bin` isn't on
it already. (A pre-v0.19.0 install also symlinked a `foundation` compat
shim; that is no longer created.) No shell-rc
edits, no `sudo`.

Uninstalling is layered across **seven separate scopes** — most people only
ever need `temperloop uninstall` (the machine-surface install) or
`temperloop eject` (undoing `init` in a target repo); see § Uninstall below
for the full breakdown and the other five.

## Quickstart: testbed → first epic → promote → adopt

Evaluate temperloop on **your own code, in a repo you can throw away — then
keep what it built**: `temperloop testbed` makes a private duplicate of a real
repo of yours and carries its open issues across, you run `temperloop init`
there and take the first epic it offers you through `/assess` → `/build`, then
`/promote` lands the work worth keeping back in the real repo before
`temperloop testbed --teardown` reclaims the duplicate. The exact commands live
in [the README's § 3](../README.md), which is the canonical copy; this page is
the CLI reference behind it.

A duplicate, not a fork: a fork of a public repo is forcibly public, and it
carries an upstream that PR tooling will offer as a base. GitHub also never
copies issues to a fork, which is why `testbed` copies them for you.

**Before you run anything: what this costs, and what it will do on its own.**
[`../docs/cost-and-autonomy.md`](../docs/cost-and-autonomy.md) covers real
spend figures per tier (including whether a budget cap is on by default),
and exactly what an unattended run may do without asking versus what always
blocks for you — worth two minutes first. Note in particular that the
evaluation path runs the real pipeline in an **interactive** `claude`
session, not a capped headless call, and so carries **no tool-enforced
dollar ceiling**; `temperloop testbed` and `temperloop init` themselves
spend $0 (see `docs/cost-and-autonomy.md` § Cost at a glance).

### `temperloop init` — adopt, in the testbed or for real

```sh
temperloop init --dry-run   # preview first: tree-only, zero API writes
temperloop init              # for real, once you like the preview
```

Bootstraps `.temperloop/config` in your repo and proposes any tree changes
(e.g. a `boards.conf` entry) via a reviewable PR — nothing ever lands
without review. Then it offers you the kernel-shipped **first epic** ("Set
up `<project>` with temperloop"), prints a `next step:` handoff line, and
stops. `--dry-run` previews the tree-only PR with zero API calls of any
kind.

**The handoff needs `temperloop install`.** `/assess` and `/build` are
Claude Code slash commands, and they reach your machine only through
`temperloop install`, which symlinks them into `~/.claude/`. `init` itself
needs no machine-wide setup; **its handoff does** — so if you have not
run `temperloop install` yet, run it before acting on the `next step:` line.
`init` itself detects this and prints a `prerequisite:` line when the
command isn't installed, so you won't be left pointing at something that
doesn't exist.

`init` applies **no API state itself**. Branch protection, head-branch
auto-delete, the merge-queue disposition, the required `checks` status
check, CI, and your review principles are that first epic's work, applied
later with per-write consent by driving it through the real pipeline
(`/assess --epic N` → `/build`) — and note that what the epic applies is
**not** undone by `temperloop eject` (§ Uninstall scope (e), below).

Three flags that used to gate `init`'s own applies still parse and still
exit 0; each now prints one line naming where its step went, plus the
release it is removed in, and is then ignored. Nothing that passes them
breaks. Where each one went:

| Flag | Where its step went | Removed in |
|---|---|---|
| `--yes/--no-required-check` | the first epic — which, unlike `init`, refuses to require a `checks` status no workflow will post | v0.20.0 (the pre-scope-down compat window) |
| `--yes/--no-labels` | nowhere — **retired as redundant**. The `fnd:`/pipeline labels are created lazily at point of use by the issues-only tracker backend, so there was never anything to pre-create | v0.20.0 (same) |
| `--yes/--no-board` | nowhere — board provisioning was dropped outright | v0.20.0 (same) |

**Two more are gone outright: `--provision-board` and `--tracker-mode`.**
Ten releases have passed since issues-only became the default backend
(ADR 0004), and every registered board has run issues-only since
2026-07-18 — the removal window both flags were always scoped to has now
arrived (epic #524). Neither one parses any more; each exits non-zero with
a message naming the removal, not a bare "unknown flag" error (`init.sh`
catches `--provision-board` via a `--provision-*` prefix match, so the
whole retired board-provisioning flag family is refused, not just this one
historic spelling). There is no replacement and no way back: the adapter
has no Projects code path left to reach, so a Projects-v2 board cannot be
provisioned by hand either — see § Tracker mode in
[the install-cli feature doc](../docs/features/install-cli.md).

`foundation <subcommand>` does **not** run any of this ladder — the compat
shim was removed in v0.19.0 (see above) and now only refuses, naming
`temperloop`.

### Verify: `temperloop install` + `temperloop doctor`

`init` above works against a target repo and needs no machine-wide setup
of its own. Its **handoff** is the exception worth calling out: `init`
itself needs none, but the `/assess --epic N` → `/build` handoff it ends on is Claude
Code slash commands that only exist once you have run the install below —
so treat this step as part of the adoption path, not an optional extra.
`temperloop install` wires up the **machine surface** —
the machine-wide `~/.claude/CLAUDE.md` / `settings.json`, the `gh`
call-logger shim (§ Details below), and the other managed paths — and every
run ends by printing the exact command to check what actually landed:

```sh
temperloop install            # --dry-run to preview, --yes to skip the prompt
# ⇒ ends with: Verify with: bash <clone>/workflows/scripts/install/doctor.sh
```

Run that printed command any time to re-check link state on its own — `OK`
per managed path, or `MISSING` / `DRIFT` / `SHADOWED` / `DANGLING` when
something's drifted.

```sh
temperloop doctor             # same health check, same output, no path to copy
```

`temperloop doctor` is the first-class way in: it `exec`s that same script, so
its output and exit code are identical by construction, and it takes the same
optional `<toolkit-root>` argument. (Earlier releases had no such subcommand
and this page said so; that is no longer true — see the CHANGELOG entry for the
release that added it.) Beyond link state the health check also reports
**toolkit provenance** — whether the toolkit code you are running is
byte-identical to the release it claims to be; see
[`../docs/features/toolkit-provenance.md`](../docs/features/toolkit-provenance.md).
See `docs/features/install-cli.md` for exactly what it checks.

### `temperloop feedback` vs. `temperloop report` — sending vs. rendering

These two subcommands are easy to conflate by name association, so the
split is stated explicitly here: `temperloop report` never leaves your
machine — it only renders your own local `.temperloop/baseline.jsonl`
before/after metrics to your terminal. `temperloop feedback` is the
opposite: it **sends** a message to the kernel maintainers, as a GitHub
issue on `Towheads/temperloop`. Nothing is ever sent without you seeing the
exact composed payload first, it always gets scanned for personal/org
tokens before you see it, and it refuses outright in any non-interactive or
CI context — a timeout or a flag is never consent for an external write.
See `bin/subcommands/feedback.sh`'s own header comment for the full
compose → leak-scan → preview → consent → transmit contract.

## Usage

```
temperloop help              list installed subcommands
temperloop <subcommand> ...  run one
temperloop --version         print the CLI version
```

## Subcommand reference

Subcommands are **discovered files** — anything dropped at
`bin/subcommands/<name>.sh` becomes `temperloop <name>` automatically, with
no dispatcher edit required. Run `temperloop help` (or, if you're reading
this on the generated docs site, see the live table right below this
paragraph) for the current list — both are built by scanning
`bin/subcommands/*.sh` for each file's `# description: ...` header, so
neither can drift from what's actually installed.

## Details

Background you don't need for the quickstart above, but will if you're
uninstalling, auditing what `gh` calls get logged, or running this CLI
across more than one client/engagement.

### Uninstall — seven separate scopes, don't conflate them

| Scope | What it undoes | How |
|---|---|---|
| (a) **Bootstrap footprint** | `~/.local/bin/temperloop`, `~/.local/share/temperloop` — the bootstrap's entire footprint, written *before* any manifest existed — plus `~/.local/bin/foundation` if a **pre-v0.19.0** install left the compat-shim symlink behind (no new install creates one) | manual: `rm -f ~/.local/bin/temperloop ~/.local/bin/foundation && rm -rf ~/.local/share/temperloop` |
| (b) **Machine-surface install manifest** | settings/config/symlinks a `temperloop install` wrote under `$HOME`, recorded in `${XDG_STATE_HOME:-$HOME/.local/state}/temperloop/install-manifest.json` | `temperloop uninstall` |
| (c) **Target-repo side effects** | the proposal PR `temperloop init` produced in a repo you pointed it at — including the local **and remote** `foundation-init/*` branch it opened, even when the run died before ever reaching a PR (a killed process, a failed push, a failed `gh pr create`), via the `.temperloop/.recovery.json` marker — plus the label, required check, and board a **pre-scope-down** `init` recorded before it stopped applying API state — as recorded in that repo's `.temperloop/config` (pre-v0.15.0 inits wrote `.foundation/config`; that read was removed in v0.19.0 and `init` now refuses on one, but `eject` still cleans it) | `temperloop eject` (run inside the target repo; cleans either dir) |
| (d) **Issue-cache store root** | `${CACHE_STORE_ROOT:-${XDG_CACHE_HOME:-$HOME/.cache}/temperloop}` — created by `temperloop install`, grown by ongoing board cache reads/refreshes; deliberately **not** tracked by the manifest (it's regenerable cache, not install state, so "restore its original content" is the wrong verb for it) | manual, optional: `rm -rf "${CACHE_STORE_ROOT:-${XDG_CACHE_HOME:-$HOME/.cache}/temperloop}"` |
| (e) **First-epic substrate** | default-branch protection, head-branch auto-delete, the merge-queue disposition, any scaffolded CI workflow, and the recorded `§ Principles` disposition — applied by the **first epic** via `/assess --epic N` → `/build`, never by `init`, so none of it is in scope (c)'s manifest and **`temperloop eject` does not revert it** | manual: repo **Settings → Branches** (and delete the generated workflow file); step-by-step in [`docs/features/engineering-principles.md` § Uninstall / removal](../docs/features/engineering-principles.md) |
| (f) **Machine-scoped testbed record** | pointers to testbed repositories `temperloop testbed` created in **your own GitHub account**, recorded in `${XDG_STATE_HOME:-$HOME/.local/state}/temperloop/testbed-record.json` (`workflows/scripts/testbed/record.sh`) — a live remote repository, not a local file/symlink, so it's deliberately **not** folded into scope (b)'s manifest | `temperloop uninstall` **names** any repo the record still shows and prints the exact `temperloop testbed --teardown` command for each — print-only, it never deletes the repo or the record entry itself: `temperloop testbed --teardown --repo OWNER/NAME` |
| (g) **Knowledge-search backend home** | `${KNOWLEDGE_SEARCH_BM_HOME:-${XDG_STATE_HOME:-$HOME/.local/state}/foundation/basic-memory-home}` (`workflows/scripts/lib/knowledge_search.sh`'s `_ks_bm_home`) — the pinned `basic-memory` uv tool, uv's own cache and any managed CPython it downloaded, and the derived search index, all pinned inside that one directory. `temperloop install` never writes it: it appears lazily, on a host that has `uv`, the first time `make doctor` or an `ks_search` needs it. Deliberately **not** tracked by the manifest for scope (d)'s reason — it's regenerable tool state, not install state, and not your notes either (the knowledge **store** is a separate directory under `$XDG_DATA_HOME` that `temperloop uninstall` also never touches) | manual, optional: `rm -rf "${KNOWLEDGE_SEARCH_BM_HOME:-${XDG_STATE_HOME:-$HOME/.local/state}/foundation/basic-memory-home}"` — safe, but the next search re-downloads an interpreter and rebuilds a ~380 MB virtualenv. `temperloop uninstall` **names** the tree and prints this command whenever it is actually on disk, and says nothing about it when it is not |

Scope (e) is the one to read twice, because it is the only scope with no
command behind it. Since the `init` scope-down, `init` itself writes no API
state — everything that actually configures your repo is applied later, by
the first epic, through ordinary consented PRs. That state is **your repo's
own settings and content** from the moment it lands, exactly like any other
change your PRs make, which is why no kernel manifest tracks it and why
reverting those PRs does not undo it either: a protected branch stays
protected and an armed queue stays armed until you turn them off. Each write
is disclosed with its undo path at the moment you consent to it (see
`claude/templates/first-epic-setup.md` § A2/A3), so this is a documented
trade rather than a surprise — but a clean `temperloop eject` genuinely does
not mean "back to how you found it."

One first-epic answer is deliberately **not** in scope (e): the § A4
token-metering opt-in places a **tracked file**,
`.temperloop/report.d/tokens`, not API state. Reverting the PR that placed
it removes it, and `temperloop eject` removes it too — as scope (c), with
the rest of `.temperloop/`. The "eject does not revert it" warning above is
about repository *settings*; it does not extend to that file.

Scope (a) predates any manifest, so `temperloop uninstall` cannot know about
it or remove it — this is a deliberate stance, not a gap: inferring "this
looks like a temperloop path, remove it too" would be exactly the
namespace-grep behavior the manifest's own read discipline forbids (see
`workflows/scripts/install/manifest.sh`'s header). `temperloop uninstall`
prints the scope-(a) manual-removal bullet as guidance every time it runs,
so it's never a dead end — just never automatic. It prints the same kind of
guidance for scope (d) (the cache store root) and a reminder to run
`temperloop eject` for scope (c) in any target repo you ran `init` against —
plus, when the testbed record (scope (f)) still shows a live testbed repo,
its `owner/name` and the exact `temperloop testbed --teardown` command to
remove it; it says nothing about scope (f) at all when the record is empty
or absent. Scope (g) (the knowledge-search backend home) prints on that same
present-or-silent rule: named, with its `rm -rf`, whenever the tree exists —
nothing at all on a host that never grew one.

`temperloop uninstall` reads **only** its manifest: it removes every path it
created and restores every preexisting path it backed up from that exact
backup, and never touches a path absent from the manifest — a hand-edited
machine conf under `$XDG_CONFIG_HOME/temperloop/`, for instance, always
survives. `--dry-run` previews with zero writes; `--yes` pre-confirms
(otherwise an interactive `y/N` prompt, or a non-interactive default-deny
that touches nothing).

### The `gh` call-logger shim (disclosure)

`temperloop install` (scope (b) above) unconditionally installs
`workflows/scripts/gh-call-logger.sh` as `~/.local/bin/gh` — a transparent
wrapper around **every** `gh` invocation on the machine (and, installed
under the same mechanism as `git-bug`, every `git-bug` call too). This is
part of the machine-surface install manifest, so it shows up in
`temperloop uninstall`'s removal list like any other managed path; it is not
a hidden side effect.

**What it does.** It runs the real `gh`/`git-bug` binary as a child process,
times the call, and appends one record of the call (start time, duration,
exit code, the outermost command/op that made it if set, cwd, and the
arguments) to two local, append-only sinks — never sending anything over the
network itself. It never blocks, alters, or fails a call: logging is
best-effort, and a logging failure can never change the wrapped tool's exit
code.

**Where it logs.**

- A self-truncating TSV at `${GH_CALL_LOG_FILE:-$HOME/.cache/gh-calls-v2.tsv}`
  (rotates to `<file>.1` past a 16&nbsp;MiB cap).
- A monthly JSONL lake file at
  `${GH_CALLS_RAW_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/temperloop/gh-calls}/gh-calls-<YYYY-MM>.jsonl`.
  The default is XDG-scoped and never assumes a particular downstream repo
  checkout exists on disk; a real `foundation` checkout that wants this
  stream unioned into its own `meta/data/raw/` sets `GH_CALLS_RAW_DIR`
  explicitly (see `meta/data/raw/README.md` for the record shape).

**How to opt out.** Set `GH_CALL_LOG=0` (per-call or exported machine-wide)
for a zero-overhead passthrough — the real tool still runs, but no timing,
no log row, no lake record. To remove the shim entirely, run `temperloop
uninstall` (or `rm -f ~/.local/bin/gh`, restoring your shell's own `gh`
resolution from `PATH`).

### Running across multiple repos or clients

Working across more than one GitHub identity (e.g. a personal account plus a
client's org)? `gh` resolves whichever identity is currently active —
`gh auth switch` swaps it before you run a `temperloop` subcommand against a
different repo/org, same as it would for a bare `gh` call.

`temperloop install` (scope (b) of the Uninstall table above) is a **single
global, per-machine** install — the machine-wide `~/.claude/CLAUDE.md`,
`settings.json`, and the rest are shared by every repo you point this CLI
at, not duplicated per repo. What *is* per-repo is `.temperloop/config`
(pre-v0.15.0: `.foundation/config`; that read was removed in v0.19.0 —
`init` refuses on one, `eject` still cleans it),
written inside the target repo's own working tree by `temperloop init` (and
reverted by `temperloop eject`, scope (c)) — board wiring and proposal PRs
live there, scoped to that one repo, never in the global install. A repo
initialised before the `init` scope-down may also carry recorded labels and
required checks in that manifest; those entries are carried forward
untouched on every re-run and `eject` still reverts them, even though `init`
no longer creates any.

If you want an isolated instance per engagement instead of the one shared
global install — the case for, say, a consultant running this across
several unrelated client codebases — `bin/bootstrap.sh` honors two
environment-variable overrides read *before* it clones anything:
`TEMPERLOOP_HOME` (default `~/.local/share/temperloop`, where the checkout
lives) and `TEMPERLOOP_BIN_DIR` (default `~/.local/bin`, where the
`temperloop` entrypoint gets symlinked). Set both to a client-specific path
before running the bootstrap script to keep each engagement's install fully
separate. (The pre-rename `FOUNDATION_HOME` / `FOUNDATION_BIN_DIR` /
`FOUNDATION_KERNEL_REPO` names were read as fallbacks through the rename
window and are **no longer read** as of v0.19.0: setting one without its
`TEMPERLOOP_*` twin now fails with a message naming the replacement, rather
than installing somewhere you did not ask for.)
