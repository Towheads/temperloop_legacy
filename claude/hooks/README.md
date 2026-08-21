# claude/hooks — hook inventory and eval profile contract

## Hook inventory

| File | Event | Matcher | Side-channel owned | EVAL_RUN suppressed? |
|---|---|---|---|---|
| `session-start-drain.sh` | SessionStart | — | Vault drain (`Sessions/_inbox/`), vault snapshot | Yes (drain/snapshot skipped; session-id still emitted) |
| `mcp-health-preflight.sh` | SessionStart | — | Injects banner into model context | Yes (no banner injected under eval) |
| `session-start-provenance.sh` | SessionStart | — | Injects an unprompted toolkit-provenance notice into model context, **only** when the verdict is `MODIFIED` | Yes (exits 0 silently under EVAL_RUN) |
| `session-start-deploy-mini.sh` | SessionStart | — | Board toolkit deploy (mini-only) | No (mini-gate handles it; eval runs are not mini) |
| `git-stale-branch-guard.sh` | PreToolUse | Bash | None (prod: *ask* decision) | Yes (exits 0 silently under EVAL_RUN) |
| `claude-p-spawn-guard.sh` | PreToolUse | Bash | None (prod: *ask* decision) | Yes (exits 0 silently under EVAL_RUN) |
| `build-worktree-guard.sh` | PreToolUse | Bash\|Edit\|Write\|MultiEdit | Worktree-ownership records under `<XDG state>/build-worktree-guard.owners/` (deny decision) | No (write jail is always active) |
| `subtree-edit-guard.sh` | PreToolUse | Edit\|Write\|MultiEdit | None (prod: *ask* decision) | Yes (exits 0 silently under EVAL_RUN) |
| `write-lane-guard.sh` | PreToolUse | Bash\|Edit\|Write\|MultiEdit\|NotebookEdit | None (prod: *ask* decision) | Yes (exits 0 silently under EVAL_RUN) |
| `mcp-failure-tripwire.sh` | PostToolUse | mcp__obsidian.* | None (block decision) | No (eval sessions don't use vault; hook is a no-op if MCP not called) |
| `ks-agent-read-log.sh` | PostToolUse | `mcp__.*` recommended (the hook re-checks every event against the `KNOWLEDGE_READ_LOG_AGENT_MATCHERS` config seam in `workflows/scripts/lib/knowledge_store.sh`, so a broader harness-level matcher is safe) | Agent-plane read-log line, same file/format as the script-plane emitter (`KNOWLEDGE_READ_LOG`, default `~/.local/state/foundation/knowledge-reads.log`) | Yes (exits 0 silently under EVAL_RUN) |
| `log-askuserquestion.sh` | PostToolUse | AskUserQuestion | `meta/data/raw/askuserquestion-events.jsonl` | Yes |
| `session-end-log.sh` | SessionEnd | — | `<cwd>/.mind/<stub>.md` | Yes |
| `session-end-read-summary.sh` | SessionEnd | — | stdout one-liner (`knowledge store: N reads, M searches`), tallied from the read log (`KNOWLEDGE_READ_LOG`) | Yes |
| `session-end-seq-cleanup.sh` | SessionEnd | — | Vault `Sequencing/<id8>.md` | Yes |

### `claude-p-spawn-guard.sh` — what it covers, and what it does not

A headless `claude -p` / `--print` spawn does **not** inherit the launching
session's model — it resolves the *machine's* saved default (whatever `/model`
last wrote to `~/.claude/settings.json`, possibly days earlier from unrelated
work). This guard scans the **entire** Bash command text — **heredoc bodies
included, not just the argv head** — and returns `ask` when a `claude`
invocation carries `-p`/`--print` with neither `--model` nor a `--settings`
source that pins `.model`. Scanning the whole string is the load-bearing part:
the 2026-08-24 incident dispatched its 57 spawns as `bash review-one.sh … &`,
so the *only* Bash calls carrying the literal `claude -p` were the inline smoke
test and the **heredoc that authored the script** (temperloop#1836 probed and
disconfirmed the argv-head design).

**Residual blind spot — stated deliberately, because an overclaimed guard is
worse than none: it stops people looking.** This hook sees only spawn text that
passes through a Bash **tool call**. It does **not** catch:

- a bare `claude -p` inside an **already-committed script invoked by path**
  (`bash tools/fanout.sh`) — that file's text never reaches the hook. Committed
  `*.sh` are the job of `workflows/scripts/validate-model-usage-emit.sh` §6e;
  a committed script outside that validator's scan dir is covered by neither.
- a spawn launched **outside the harness** (a hand-driven shell, cron, launchd).
- a spawn behind an **unlisted launcher prefix**. `claude` is recognised in
  command position after a separator, a `VAR=val` assignment, a bare modifier
  (`time`, `env`, `nohup`, `sudo`, …), `sh -c`, or one of a short, **named** set
  of argument-taking launchers — `timeout`, `gtimeout`, `xargs`, `parallel`
  (the `LAUNCH` list in the hook's awk block). Any other wrapper that puts its
  own arguments before `claude` (`nice -n 10 claude -p …`, `flock`, a container
  `run`, a bespoke wrapper) is **not** recognised and stays silent. The list is
  bounded on purpose: enumerating every possible launcher is not attempted, and
  widening it trades false negatives for false positives.
- a spawn whose `claude` token is hidden from a text scan — assembled by string
  concatenation, held in a variable, or decoded at run time.

The incident class is **narrowed** by this guard, not closed.

Both blind spots that can be pinned mechanically **are** pinned, as
asserted-silence tests in `tests/test_claude_p_spawn_guard.sh` (the
`bash <already-written-script>` dispatch form, and `nice -n` as the unlisted
launcher) — so the claims above stay honest rather than aspirational, and a
change that widens coverage has to update the claim alongside it.

**A false ask is the failure mode this guard most has to avoid in itself.** It
is advisory, and an ask on *correct* usage trains reflexive approval and erodes
the real one. So quoting is tracked as one shell-accurate state (none / double /
single), not as two independent parities: a `;`, `&` or `&&` inside a
**single-quoted prompt** is prompt text, not a command break, and
`claude -p 'Review this; be brief' --model sonnet` is silent.

That quote state gates **flag recognition** as well as the command break — a
flag-shaped word inside an open quote region is prompt text, not a flag. This
cuts both ways, and both directions are pinned by tests:

- `claude -p "explain the --model flag"` still **asks**. The prompt only
  *mentions* `--model`; the invocation passes none, so it is a genuinely bare
  spawn. (Reading it as a real flag was a silent false *negative* — the guard
  going quiet on exactly the spawn it exists to catch.)
- `claude --append-system-prompt "always use -p mode" --output-format json`
  stays **silent** — there is no print flag anywhere in it, only the word `-p`
  inside a quoted system prompt.

The **attached** spellings `-p"hi"` and `--print'hi'` (a value joined to the
flag with no space) are recognised too, so they are *not* a blind spot.

## Shared helper

**`eval-guard.sh`** — sourced by every hook that owns a production write channel.  Provides a single function: <!-- cite: HK.1 guard:claude/hooks/eval-guard.sh -->

```bash
# shellcheck source=eval-guard.sh
. "$(dirname "${BASH_SOURCE[0]}")/eval-guard.sh"
eval_guard_exit_if_eval   # exits 0 immediately when EVAL_RUN is non-empty
```

The check is a `[ -n "${EVAL_RUN:-}" ]` test — cheap, uniform, zero-overhead on production runs.

---

## Eval profile contract

The eval runner must set the following to launch a headless `claude -p` session in eval mode such that all side-channel hooks self-suppress.

### Required environment

| Variable | Value | Purpose |
|---|---|---|
| `EVAL_RUN` | `1` (any non-empty string) | Activates all hook suppressions |
| `CLAUDE_CONFIG_DIR` | Path to an isolated config directory (see below) | Prevents reading/writing the production `~/.claude/` profile |

### Isolated config directory

Create a minimal config dir that omits or stubs production hooks as needed.  A typical setup copies or links the hook scripts (which self-suppress via `EVAL_RUN`) but points to a scratch working directory:

```sh
EVAL_CONFIG="$HOME/.claude-eval"
mkdir -p "$EVAL_CONFIG/hooks"
# REPO_ROOT is your installed kernel checkout (e.g. $HOME/.local/share/temperloop
# for a bootstrap install) — never a hardcoded personal dev path.
REPO_ROOT="${REPO_ROOT:?set to your kernel checkout root}"
# Link (not copy) hooks — they self-suppress via EVAL_RUN
for h in session-end-log session-start-drain log-askuserquestion \
          session-end-seq-cleanup mcp-health-preflight eval-guard; do
  ln -sf "$REPO_ROOT/claude/hooks/${h}.sh" "$EVAL_CONFIG/hooks/"
done
# Provide a minimal settings.json referencing the eval hook paths
```

### What is suppressed vs what still fires

| Hook behaviour | Production (EVAL_RUN unset) | Eval (EVAL_RUN=1) |
|---|---|---|
| SessionEnd transcript stub in `.mind/` | Written | **Suppressed** |
| Vault drain (`Sessions/_inbox/`) | Runs | **Suppressed** |
| Vault snapshot | Runs | **Suppressed** |
| MCP health preflight banner | Injected if degraded | **Suppressed** |
| AskUserQuestion telemetry to JSONL | Appended | **Suppressed** |
| Sequencing record cleanup | Runs | **Suppressed** |
| Git stale-branch guard on `checkout -b`/`switch -c` off stale main | `ask` decision | **Suppressed** (exit 0) |
| Session-id `additionalContext` | Emitted | **Emitted** (eval traceability) |
| Toolkit-provenance `additionalContext` on a `MODIFIED` checkout | Injected | **Suppressed** (exit 0) |
| Write-jail guard (build-worktree-guard), incl. its writer-identity arm | Active when armed | Active when armed |
| Subtree-edit guard on Edit/Write/MultiEdit into `kernel/` (direct or via a compat symlink) | `ask` decision (or silent bypass under `.build-guard`/`KERNEL_EDIT_ACK=1`) | **Suppressed** (exit 0) |
| Write-lane guard on a mutation targeting a foreign repo's canonical checkout | `ask` decision | **Suppressed** (exit 0) |
| Bare-`claude -p` spawn guard on a Bash command containing a `claude -p`/`--print` with no `--model` (and no model-pinning `--settings`) | `ask` decision | **Suppressed** (exit 0) |

### Launching a headless eval session

```sh
EVAL_RUN=1 CLAUDE_CONFIG_DIR=/path/to/eval-config \
  claude -p "$(cat prompt.txt)" --model "$EVAL_MODEL" --output-format json > result.json
```

The explicit `--model` is not optional boilerplate: a bare `claude -p` resolves
the *machine's* saved default model, so an eval run without it silently scores
whatever tier that host was last configured for (see
`claude-p-spawn-guard.sh` above).
