# AGENTS.md

Instructions for any AI coding agent (Claude Code, or another agent that
reads this file per the [AGENTS.md](https://agents.md) convention) working
in this repository. If you are a Claude Code session specifically, also read
`CLAUDE.md` (repo root) and `claude/CLAUDE.kernel.md`, which this file
defers to for the full process contracts — this file is the cross-agent
orientation layer, not a replacement for either.

## What this repo is

TemperLoop is a dev-process kernel for Claude Code–driven development: a
board adapter that turns a GitHub Projects board (or a plain issues-only
tracker) into a cross-session work queue, a build/sweep pipeline of Claude
Code slash commands that drive an issue from triage to a reviewed PR, and
the install/quality-gate tooling that gets both running in a repo you
already have. It is a toolkit — scripts, slash commands, and contract files
you read — not a service you depend on. Full description: [`README.md`](README.md).

This repo builds and ships that kernel; it also *uses* its own pipeline on
itself (an agent working here is both developing and dogfooding the tools
described below).

## How an agent administers this repo

### The CLI vs. `make` — two different surfaces, don't confuse them

`bin/temperloop` (subcommands in `bin/subcommands/`) is the **pre-checkout
newcomer surface** — `init` (propose adopting this repo's conventions in
another repo via a reviewable PR, then offer the pre-designed first epic),
`baseline-snapshot` / `report` (before/after value tracking), `eject`
(manifest-driven clean removal). It is not a second front door onto *this*
checkout's day-to-day work — don't add a Makefile-target wrapper here.

**In-checkout operations stay on `make`.** Run `make help` for the full
target list with descriptions. The ones an agent needs most:

- `make quality-gates` — the full static gate set, identical to what CI's
  `checks` job runs (`scripts/quality-gates.sh`). Run this before opening a
  PR.
- `make test-board` / `make test-build` — the board adapter / build-machinery
  toolkit test suites (zero network).
- `make docs` — renders the generated docs site to
  `workflows/scripts/docs/_site/` (gitignored; a build artifact).
- `bash scripts/prune-merged-branches.sh` — sweep merged local branches
  (dry-run by default; `--apply` to delete).

### Board-adapter rules

Every board read or write goes through the adapter — never a hand-rolled
issue read or label write at the call site. Source
`workflows/scripts/board/lib/board.sh`, or use the bare commands:
`worklist` / `claim` / `release` / `reconcile` / `capture` / `milestone`
(all in `workflows/scripts/board/`), each taking `--board N`.

There is **one backend: issues-only** — plain GitHub Issues over REST, with
item state on `fnd:`-namespaced labels and Done meaning the issue is closed
with no residual `fnd:status:*` label. No Projects board is ever
provisioned, and none can be: the Projects-v2/GraphQL arm was deprecated by
ADR 0004 and removed outright in the Projects-v2 removal release (epic
#524). There is no configuration path back — a stale
`board.<N>.backend=projects` line in `boards.conf` is refused with a
non-zero exit naming the migration path, not silently downgraded. See
`workflows/scripts/board/ISSUES-ONLY-BACKEND.md` for the
label/status/claim-lock contract, and `board.sh`'s own header for the
function-level detail.

This matters mechanically, not just stylistically. Board reads are **live**
— every one is a real REST call, with no cross-process cache in front of it
— and they share REST's **5,000 requests/hour** bucket with CI-check
polling and ordinary issue/PR porcelain. So resolve a board **once** and
reuse the result rather than re-resolving per item, and prefer
`board_resolve_item` over the whole-board `board_resolve` for a single-item
operation. Because the Projects arm's removal collapsed two
independently-metered surfaces into one, there is no longer a second budget
to move a noisy caller onto: a drain has to be fixed at its source. See
`docs/failure-modes/02-rest-budget-exhaustion.md` for the worked example of
exactly that trap.

### Shell-dialect rules

These libs are **sourced into the agent's shell**, not just executed, and on
macOS that shell is **zsh** — a `#!/usr/bin/env bash` shebang does not protect
a sourced file. So a capability probe must be POSIX:

```sh
command -v some_fn >/dev/null 2>&1     # correct in bash AND zsh
declare -F some_fn >/dev/null 2>&1     # WRONG — always true under zsh
```

zsh implements `declare` as `typeset`, whose `-F` means "float with N digits",
so `declare -F <absent-name>` **exits 0** and the fallback written beneath the
guard becomes unreachable. `type -t` is bash-only in the same way. That defect
killed the first board call of a `/triage` run twice (#1776). Need strictly
"is a function"? `typeset -f <name>` is portable. `scripts/lint-shell-dialect-probe.sh`
(a `checks` gate) fails on a re-introduction; a line that must carry the shape
as data opts out with a `shell-dialect-probe:exempt — <why>` pragma.

### Quality gates

`scripts/quality-gates.sh` is the single source of truth for this repo's
static gate set — the board / build / install / hooks test suites, the
Capture/Backstop and PR-body-lint registries, the kernel-manifest / personal-token
/ gitleaks scrub checks, and a whole-tree shellcheck. CI's one required job
(`checks`, `.github/workflows/ci.yml`) runs exactly this script, so "green
locally" and "green in CI" mean the same thing. Run `scripts/quality-gates.sh
--list` to see every gate as a `[kernel] <command>` line, or `make
quality-gates` to run them all.

### Where the contract docs live

- `claude/CLAUDE.kernel.md` — the full process-contract doc: branch/PR
  policy, working-tree ownership, board-adapter usage, task workflow, plan-
  first default, PR verification surface, and more. The canonical reference
  for *how* work happens in this repo and its sibling build repos.
- `claude/plan-schema.md` — the plan-note contract `/assess` writes and
  `/build` consumes.
- `workflows/scripts/lib/knowledge_store.contract.md` — the knowledge
  (document-I/O) adapter interface, for anyone wiring in a new notes
  backend.
- `workflows/scripts/lib/tracker.contract.md` — the tracker (work-tracking)
  adapter interface contract, symmetric with `knowledge_store.contract.md`,
  for anyone wiring in a new tracker backend. Its companion
  `workflows/scripts/board/ISSUES-ONLY-BACKEND.md` is the `issues-only`
  backend's operational deep-dive.
- `docs/managed-merge-queue.md` — the merge-backend seam (native vs.
  managed queue) that lets the build/sweep ladder run end-to-end even on a
  repo with no native merge queue available.
- `docs/config-precedence.md` — the six-layer config precedence ladder
  (CLI flag > env var > machine conf > untracked repo-local conf > tracked
  repo conf > kernel built-in default) every tunable in this repo resolves
  through.
- `docs/CONTRIBUTING.md` — how to contribute a failure-mode chapter or a new
  knowledge/tracker adapter.
- `bin/README.md` — the CLI's own front page: install, prerequisites, and
  the per-subcommand reference (flags, exit codes, safety contract). The
  testbed → first epic → promote → adopt quickstart itself is canonical in
  `README.md` § 3; `bin/README.md` points at it rather than restating it.

Once `make docs` has been run, all of the above (plus the command reference
and quality-gate list) are also browsable as a generated static site at
`workflows/scripts/docs/_site/`.

## Safety rails

- **Adapter-only board access.** See § Board-adapter rules above — never a
  hand-rolled issue read or label write for anything the adapter already
  covers.
- **`main` is protected.** Never push to it directly. Branch
  `<type>/<slug>` (`type` ∈ `feat|fix|chore|refactor|docs|test`), commit,
  push, open a PR. Wait for the required `checks` status to go green before
  merging.
- **Merge-queue flow, not a direct merge.** `gh pr merge --merge` enqueues
  the PR in the repo's merge queue rather than merging immediately — it
  lands only after a second `checks` run against the queue's rebased head.
  Never pass `--delete-branch` (the queue rejects it; head branches
  auto-delete via the repo's own setting instead). On a repo with no native
  merge queue provisioned (a free personal/non-org repo), `gate.sh
  managed-merge` replicates the same re-validate-then-merge sequencing by
  hand — see `docs/managed-merge-queue.md`. Either path only closes tracking
  state once the merge is *confirmed landed* (`state=="MERGED"`), never at
  the moment the merge call returns.
- **Worktree lanes.** A session mutates only the working tree it was
  launched in, plus any linked git worktree it created — never another
  checkout's `HEAD` directly. Cross-repo or isolated work happens in its own
  `git worktree add <path> -b <branch>`, worked under `<path>`, never in a
  foreign repo's canonical checkout. This is mechanically backstopped for
  Claude Code sessions by the `write-lane-guard.sh` PreToolUse hook
  (`claude/hooks/`), which intercepts a state-mutating call into a foreign
  checkout and asks before proceeding.
- **Every headless `claude -p` spawn passes an explicit `--model`.** A bare
  `claude -p` (or `--print`) does *not* inherit the launching session's
  model — it resolves whatever default model that machine has saved, so a
  fan-out script silently routes its workers to an unintended tier. Always
  pass `--model`, and take its value from a named setting in
  `workflows/scripts/build/build.config.sh` (e.g. `PIPELINE_DRIVE_MODEL`)
  rather than hard-coding a model id.
  `workflows/scripts/validate-model-usage-emit.sh` fails the `checks` gate on
  a spawn site under `workflows/scripts/build/` that omits the flag — but it
  can only see files that live in this repo. The run-time-composed case is
  backstopped for Claude Code sessions by the `claude-p-spawn-guard.sh`
  PreToolUse hook (`claude/hooks/`), which scans a Bash command's whole text —
  heredoc bodies included, so it fires on the heredoc that *authors* a
  `/tmp` fan-out script — and asks before a bare spawn. It sees only text
  passing through a Bash tool call, so a bare spawn inside an already-committed
  script invoked by path, one behind a launcher prefix the hook does not list,
  or one launched outside the harness, is still covered by this rule alone.
- **Portable shell only (macOS/BSD + zsh).** Scripts here run on
  contributors' macOS (BSD userland) and get sourced under both bash and
  zsh, where several silent-failure footguns slip past the whole-tree
  shellcheck gate. Three recurring ones to avoid: (1) `grep -P` (PCRE) — BSD
  grep does not support it; use `grep -E` or `rg` instead. (2) Relying on an
  unquoted `$VAR` to word-split inside a `for` loop — zsh does **not** split
  unquoted parameters, so `for x in $LIST` iterates once over the whole
  concatenated string (a cull loop silently no-op'd on its list this way);
  use an array, `${(z)VAR}`, or awk-internal splitting. (3) GNU-only `mktemp`
  invocations — write portable `mktemp "${TMPDIR:-/tmp}/name.XXXXXX"`. The
  zsh-tied special-parameter slice of this class (`local path=…` rebinding
  `PATH` under zsh) is already caught mechanically by
  `scripts/lint-zsh-param-tie.sh`; the rest is author discipline shellcheck
  cannot see.
