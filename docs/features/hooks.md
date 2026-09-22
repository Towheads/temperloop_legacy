---
title: Guard and lifecycle hooks
slug: hooks
---

## Problem

An AI coding agent has broad, fast write access to a working tree and to the
shell — broader and faster than a human operator exercising the same
permissions by hand. Left unchecked, a single session can silently step on a
concurrent session's checkout, branch off a stale base that only reveals the
divergence at push time, bypass a rate-limited API adapter with a raw query
that drains a shared budget, or leak an edit meant for a sandboxed worktree
into the real repository. None of these are hypothetical: each guard in this
repo exists because a real session hit the failure it now prevents. Without a
mechanical layer sitting between the agent's tool calls and their effects,
every one of those mistakes depends on the agent noticing its own mistake in
time — which is exactly the class of error an agent is worst at catching.

Session lifecycle also needs a durable record. A session that ends leaves
behind context (what happened, what was decided, what was read) that is
useful later but only if something captures it before the process exits —
otherwise it is lost the moment the terminal closes.

## How it works

Hooks are shell scripts registered against Claude Code tool-use events
(`PreToolUse`, `PostToolUse`, `SessionStart`, `SessionEnd`) and matched to a
tool pattern (e.g. `Bash`, or `Edit|Write|MultiEdit`). A `PreToolUse` hook
receives the proposed tool call on stdin and returns a permission decision
before the call executes; a `PostToolUse` or lifecycle hook runs after the
fact and can only observe and record, never block.

**The guard inventory** (all `PreToolUse`, all shell scripts under
`claude/hooks/`):

- **write-lane-guard.sh** — matches `Bash|Edit|Write|MultiEdit|NotebookEdit`.
  A session's "lane" is its own launch directory plus any git worktree linked
  to it. A state-mutating call whose target resolves to the *main* working
  tree of a different repository (not the session's own lane) returns an
  `ask` — the sanctioned way to touch another repository is a dedicated,
  isolated worktree, which this guard leaves silent. It exists because two
  concurrent sessions sharing one filesystem can otherwise move each other's
  branch pointer out from under one another.
- **git-stale-branch-guard.sh** — matches `Bash`. On a branch-creation command
  (`git checkout -b`/`-B`, `git switch -c`/`-C`/`--create`) whose base is the
  *local* default branch, fetches the default branch from origin and, if the
  local copy is behind, returns an `ask` naming how many commits behind and
  the fix. Branching off `origin/<default>`, a SHA, or a non-default ref is
  left silent — those bases are already correct. It exists because branching
  from a stale local base and discovering the divergence only at push time
  was the single most common and most expensive friction pattern observed.
- **build-worktree-guard.sh** — matches `Bash|Edit|Write|MultiEdit`. Enforces
  that an automated build worker only ever writes inside its own pre-created
  worktree. It is inert by default and arms only when a per-worktree marker
  file is present *and* the worktree sits under the expected
  `<repo>.wt/<name>/` convention — so an ordinary interactive session, which
  has neither, is never affected. It exists because a bare absolute path can
  resolve against the parent checkout even when the worker's shell is `cd`'d
  into its worktree, silently leaking an uncommitted write into the
  orchestrator's own tree. Beyond the file-write tools, it also inspects
  **Bash** commands and denies a destructive filesystem verb
  (`rm`/`rmdir`/`mv`/`shred`/`truncate`/`dd of=`) whose target it cannot prove
  stays inside the worktree — including any non-literal target (a `$`
  expansion, a `$(…)` substitution, or a glob), the exact shape that once
  resolved to `~/dev` and wiped every checkout.
- **subtree-edit-guard.sh** — matches `Edit|Write|MultiEdit`. In a repository
  that vendors this kernel via a pinned subtree, an edit through the vendored
  path (or a compatibility symlink into it) returns an `ask` — the only
  sanctioned way to change vendored content is to land the change upstream in
  the kernel repository first, then pull it down. A build worker operating
  inside an already-supervised, marker-armed worktree is exempted from the
  interactive prompt (nothing to ask — no live operator is present, and a
  downstream mechanical check still catches an unwaived change). Whichever way
  it resolves, it first re-runs the toolkit-provenance probe and folds the
  current verdict into its message: this guard firing *is* the moment the
  vendored tree stops being the release it claims, so it is the only place a
  mid-session provenance notice can be delivered at all (see
  [toolkit provenance](toolkit-provenance.md)).
- **claude-p-spawn-guard.sh** — matches `Bash`. A headless `claude -p` /
  `--print` spawn does not inherit the launching session's model; it resolves
  the *machine's* saved default, so a fan-out composed mid-run silently routes
  every worker to whatever tier that host was last set to. This guard scans the
  whole command text — heredoc bodies included, not just the leading command
  word — and returns an `ask` when a `claude` invocation carries `-p`/`--print`
  with neither `--model` nor a `--settings` source pinning one. Scanning the
  whole string is the point rather than a detail: the incident that prompted it
  dispatched its spawns through an already-written script, so the earliest
  command carrying the literal was the *heredoc that authored that script*, and
  a guard reading only the leading command word would have stayed silent
  through all of it. Command position is also recognised through a short,
  *named* set of argument-taking launchers — `timeout`, `gtimeout`, `xargs`,
  `parallel` — since those are the shapes a hand-rolled fan-out and this
  repository's own build machinery actually reach for. It sees only spawn text
  passing through a Bash tool call — a bare spawn inside an already-committed
  script invoked by path (the job of `validate-model-usage-emit.sh`), one behind
  an *unlisted* launcher prefix, or anything launched outside the harness, is
  not covered. Those gaps are stated in the hook's own header and in
  `claude/hooks/README.md`, and the two that can be pinned mechanically are
  asserted as silence tests rather than left implied.
- **arm-read-guard.sh** — matches `Read|Glob|Grep|Bash`. A dual-build level
  builds one plan item twice, under two models, in two isolated worktrees off
  one base SHA; the comparison is only evidence while the two arms stay
  independent. This guard denies a read that reaches the *sibling* arm — a path
  under its worktree (every path-shaped field of a Read/Glob/Grep input, and
  the whole command text of a Bash call, so a relative `../<slug>@baseline`
  reach or a `git log`/`git show` of the sibling branch is caught without
  enumerating git subcommands). It arms only when the worktree carries a
  `.dual-build-arm` marker naming the sibling, so a session that is not an arm
  of a dual build never sees it. A denial also appends one JSON line to
  `.dual-build-cross-read-attempts.jsonl` beside that marker, because a blocked
  attempt that left no trace would be indistinguishable from a clean run. That
  file's existence is the signal the per-level `/build` driver
  (`claude/workflows/build-level.mjs`) folds into the arm's **ledger row** — the
  per-arm result record a dual-build level writes for each of its two arms — as
  `cross_read_attempted`. Both the marker and that record are written by the
  dual-build harness landing with epic #2065; see the amendment in [ADR
  0027](../adr/0027-model-comparison-ships-as-an-inert-opt-in-module.md) for why
  this module ships a hook at all. Its gap is the same shape as the spawn
  guard's — a sibling path assembled at run time out of shell variables, or a
  read performed inside an already-committed script invoked by path, is not
  visible in the command text.

**The fail-open philosophy.** Every guard above fails open: any internal error
— missing `jq`, unparseable input, not a git repository, a network failure —
exits `0` immediately and lets the command through unmodified. A guard bug must
never be able to wedge a session that is doing something correct. This is a
deliberate trade-off: a guard can be bypassed by a determined or confused
caller, but it can never be the reason a legitimate write fails.

The *verdict* is `ask` by default, so a risky action becomes a **conscious
choice** rather than a hard block — and two guards deny instead, for the same
pair of reasons. `build-worktree-guard.sh`'s Bash arm and `arm-read-guard.sh`
both fire only inside a marker-armed, headless build worktree, where (a) no
operator is present to answer an `ask`, so a prompt would hang the run or be
auto-approved unread, and (b) the action they intercept has no legitimate form
in that context — a destructive verb on a target that cannot be proven to stay
inside the worktree, and an arm reading the sibling it is being compared
against. Marker-scoped inertness is what keeps the stricter verdict confined to
the situation that earns it; an ordinary session reaches neither.

**`EVAL_RUN` self-suppression.** An unattended, headless evaluation run has
no live operator to answer an interactive `ask` prompt — an unanswered
`ask` would simply hang the run forever. Every hook that owns a
production side effect sources a shared helper, `eval-guard.sh`, which
exposes one function:

```bash
. "$(dirname "${BASH_SOURCE[0]}")/eval-guard.sh"
eval_guard_exit_if_eval   # exits 0 immediately when EVAL_RUN is non-empty
```

The check is a single `[ -n "${EVAL_RUN:-}" ]` test. Setting `EVAL_RUN` to
any non-empty value during a headless evaluation session suppresses every
side-channel write (vault drain, session-stub logging, telemetry appends)
and downgrades the interactive guards from `ask` to a silent pass-through. The
two deny-verdict guards are deliberately *not* suppressed: neither prompts, so
neither can hang a headless run, and suppressing them would silently void the
containment an evaluation run is least able to notice the loss of.

**Session lifecycle hooks.** Beyond the six guards, a set of `SessionStart`
and `SessionEnd` hooks handle non-blocking bookkeeping: writing a transcript
stub when a session ends, draining accumulated stubs into durable storage
when a new session starts, a health-preflight check that injects a banner into
the model's context if a dependency looks degraded, and a toolkit-provenance
notice that injects a banner when the toolkit code about to run is not the
release it claims to be (silent otherwise — see
[toolkit provenance](toolkit-provenance.md)). These never
return a permission decision — they observe and record, and every one of
them is itself `EVAL_RUN`-suppressed so an evaluation run's transcripts and
telemetry never mix with production data.

## Integration

Hooks are declared in the Claude Code settings file (matcher + event +
script path) and installed alongside the rest of the CLI configuration. They
run as ordinary subprocesses invoked by the harness around each tool call —
no separate service, daemon, or long-running process. A repository that
vendors this kernel gets the guard inventory for free once the hooks are
installed; a hook's behavior is entirely local to the checkout(s) it can see
on disk plus whatever it reads from environment variables (`EVAL_RUN`,
`XDG_STATE_HOME`, and a small number of per-hook overrides for pointing a
test harness at a scratch location instead of the real one).

## Resource impact

Each guard is a short shell script invoked synchronously before or after a
single tool call; the added latency is dominated by process-spawn overhead
(a `jq` parse of a small JSON payload, an occasional `git` or `gh` call) —
low milliseconds per invocation, not a measurable drag on a session. The
stale-branch guard is the one guard that does network I/O (a `git fetch`
against origin) when it fires, which is also a deliberate side benefit: the
fetch cures the stale remote-tracking ref the warning is about. Lifecycle
hooks write small text files (a transcript stub, a denial-log line) to local
disk; none of them hold a lock or block the session on I/O beyond a normal
file write.

## Telemetry

The guards do not emit their own metrics — a fired `ask` is visible
in-session as the prompt itself, and a silent pass-through leaves no trace by
design (this is the fail-open contract, not a gap). Absence of a fired guard
is not itself observable; if a guard needs to be proven inert or active in a
given run, add a scoped assertion around that scenario rather than relying
on an existing stream.
