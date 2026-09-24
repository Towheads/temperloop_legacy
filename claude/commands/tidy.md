---
description: Nightly unattended tidy pass — drain the session-stub backlog in Sessions/_inbox/ (extract learnings to vault + auto-memory, generate tasks in Things inbox, archive processed stubs to foundation/meta/sessions/archive/), snapshot the vault, and park anything needing human judgment to the pipeline surfaces /check-in disposes.
---

You are running the **tidy** command. Goal: turn raw session transcripts in `Sessions/_inbox/` into durable artifacts (decisions, memories, patterns, tasks), archive the stub, and snapshot the vault.

**This command runs nightly, unattended** (a launchd/cron `claude -p "/tidy"` invocation, or on demand) — that headless one-shot has no re-invoke-on-background-completion loop, so it takes Step 0 item 4f's **headless lock arm** rather than the cross-host Sync-wait election. It has **no live operator**, so it **never** blocks on an `AskUserQuestion` and never asks a clarifying question: it extracts liberally and **parks anything needing human judgment on a durable surface** that `/check-in` disposes at the next daily review. Those are the pipeline surfaces under `Pipeline/` (falling back to the legacy `Context/pipeline - *` location — path fallback convention, `claude/commands/check-in.md`): pending-decisions, proposed-supersessions, candidate-tells, vault-hygiene — plus the **sensitivity flags** surface (Step 2). `/tidy` is the **drain-proposes** half; `/check-in` is the **operator-disposes** half — this command writes surfaces, never mutates their `Status`. <!-- cite: T.1 class:unattended-hang-silent-defaults -->

**Operating principles** (honor the knowledge store's `Projects/foundation/workflows/daily-planning/README.md` note — document paths throughout this file, e.g. `Sessions/_inbox/`, `Decisions/`, the pending-decisions surface (`Pipeline/pending decisions.md`, falling back to the legacy `Context/pipeline - pending decisions.md` — path fallback convention, `claude/commands/check-in.md`), are relative to **the knowledge store root**, resolved per `workflows/scripts/lib/knowledge_store.contract.md`):
- Write small, write in parallel — batch independent vault writes and Things writes.
- Reads use the `Read`/`Glob` file tools directly on the resolved knowledge-store path; concept search uses `ks_search` — per the contract's Obsidian-mode note. Writes stay on the Obsidian MCP; use the Things MCP for task creation.
- **Verify every capture append — read it back before reporting it captured (foundation#1091).** This run is unattended: its Step 6 summary lands in a log no operator watches live, so a silently-failed append (an MCP append can return OK on a write that never lands, or that the mcp-tools server misfiles a duplicate heading — see `claude/CLAUDE.md` § Obsidian vault) becomes a *lesson reported as captured but never written anywhere*. After every **agent-plane** capture append in Step 3 — whether via `mcp__obsidian-builtin__vault_append` **or** `mcp__obsidian__append_to_vault_file` — to a lesson/ledger/pipeline surface (the friction ledger, candidate-tells, proposed-supersessions, the pending-decisions / sensitivity-flags / vault-hygiene / environment-hygiene surfaces, the session-optimization toolkit, and any other capture append below), **read the target back** (`Read` on the resolved file path) and confirm the just-appended record is present. Each write and its **own** read-back are **sequential** — read only after that write returns; only a *target and its own read-back* must not be parallelized (a read racing its write false-negatives), while independent surfaces' write+read-back pairs may still be dispatched across the same turn per the write-small/parallel bullet above. On a confirmed mismatch, **re-issue the append once** — but first check the target's tail so an eventual-consistency false-negative (the write landed, the read was stale) doesn't append a duplicate row. If the record is *still* absent, record the miss in the Step 6 summary's `Capture read-back failures` line as `<surface> — <what>` rather than counting it captured. Fail-open on the read-back itself — a transient read *error* must never abort the drain — but a **confirmed-absent** record is a reported failure, never a silent success. (Scope: agent-plane appends only — the script-plane `ks_append` site in the label-reconcile sweep owns its own best-effort degrade and is not governed here.)
- Never duplicate work the live session already captured — check existence before writing.
- **Consolidate before writing — one batched write pass, never per-stub.** Scanning and adjudicating stubs produces *candidates* only; hold them in a single dedup ledger (across stubs, and against already-existing vault/memory artifacts) and execute one batched write pass after all stubs are scanned. Never write a Decision/Pattern/memory the moment an extraction is found mid-scan (that is the F#1012/#1013 duplicate pattern), and never let an analyst subagent write — the orchestrator owns the writes. <!-- cite: T.2 incident:F#1012 -->

## Capture/Backstop pairings

Every step in this command has a real-time counterpart that runs during the live session — the drain is the backstop, not the primary defense. **This table is the single source of truth for KERNEL capture/backstop pairings** — pairs generic enough that a stranger's kernel-only checkout needs them backstopped too. A composed (overlay) checkout carries a second table, the **overlay extension**, at `claude/capture-backstop-registry.overlay.md`, for pairs that reference Travis-personal (vault-backed) rules and have no meaning in a standalone kernel checkout; `workflows/scripts/validate-capture-backstop.sh` unions the two when the overlay file is present, and validates this kernel table alone otherwise. `[[Patterns/Capture-Backstop pairing]]` and `claude/CLAUDE.md` § Capture/Backstop pairing point here. The validator parses both tables in CI (the `checks` gate) — it fails the build if any pair, in either table, is **half-present** (a capture anchor present without its backstop anchor, or vice versa). When you add a pair: kernel machinery (board/build/pipeline/harness-generic) → a row here, in the same change as the rule; a personal/vault-backed rule → a row in the overlay extension table instead. <!-- cite: T.3 guard:workflows/scripts/validate-capture-backstop.sh -->

**Cell grammar** (so the validator can parse it): every checkable token is `backticked`. The **Capture location** cell is `` `<source>` § `<anchor>`… `` where `<source>` is a file (`claude/CLAUDE.md` = global config, `foundation/CLAUDE.md` = this repo's root CLAUDE.md, `stageFind/CLAUDE.md` = the consuming repo, or `claude/commands/<cmd>.md` = a kernel command spec — a tracked file the validator hard-checks like any other) or the literal `` `system-prompt` `` (unverifiable — the validator checks only the backstop half); each `` `<anchor>` `` is the exact heading or bold-label text to find in that source. The **Backstop** cell lists the exact `### <heading>` anchors in this file's Step 3. Same grammar in the overlay extension table.

| Capture rule | Capture location | Backstop |
|---|---|---|
| Feedback / project / user memory | `system-prompt` § auto memory | `Feedback memories`, `Project memories`, `User memories` |
| Defect capture-at-source | `claude/CLAUDE.md` § `Capture at source` | `Unfiled defects` |
| Stale board-claim sweep | `claude/CLAUDE.md` § `Board hygiene is part of the gate` | `Stale board claims` |
| Answered decision issues | `system-prompt` § `decision_sink_ask` | `Answered decisions` |
| Kernel-vs-overlay classification | `claude/CLAUDE.md` § `Kernel vs overlay routing rule` | `Kernel-candidate learnings` |
| Design-first default for invented work | `claude/CLAUDE.md` § `Design-first default for invented work` | `Provenance-less epics` |
| Per-epic retro mint | `claude/commands/build.md` § `Mint the per-epic retro tracker` | `Retro mint backstop` |
| Route a conversational fix request through /fix | `claude/CLAUDE.md` § `Route a conversational fix request through /fix` | `Unlinked fix PRs` |
| Disconfirm a root-cause diagnosis before institutionalizing it | `claude/CLAUDE.md` § `Disconfirm a root-cause diagnosis before institutionalizing it` | `Un-disconfirmed diagnoses` |
| Delta-approval collaborative engagement | `claude/commands/workshop.md` § `Step 3.7 — Delta report` | `All-accepted-untouched briefs` |
| Plan-critical artifact availability | `claude/commands/assess.md` § `Artifact-availability audit` | `Undurable plan artifacts` |
| Response-level grounding citations | `claude/CLAUDE.md` § `Response-level grounding citations` | `Missing grounding citations` |

## Step 0 — Verify environment and acquire the drain lock

1. Confirm the Obsidian MCP write tools (`mcp__obsidian-builtin__vault_append`, `vault_write`, `vault_patch`, `vault_delete`, `vault_move`) are loaded — they are **required** (the vault is the whole point); if missing, surface that and stop. Confirm `mcp__things__*` is loaded too, but treat it as **optional under unattended operation**: on a headless nightly host the Things app may not be running, and its absence must **not** abort the vault extraction + archive + snapshot. If Things is missing, **degrade** — skip Step 4 (task generation) and any Things dedup/search, note `Things unavailable — task generation skipped` in the Step 6 summary, and continue.
2. List `Sessions/_inbox/` via `Glob` on the resolved path. **Only `*.md` files are stubs** — ignore any `.drain.lock.*` entries here and everywhere below. If there are no `*.md` stubs, say so in one line and exit (don't acquire the lock — there's nothing to race over).

   **Early-exit on an open archive PR (delete-on-PR-record).** Before doing any drain work, check whether a prior run's archive PR is still open — `gh pr list --head chore/session-archive --state open` (in the archive repo, `~/dev/foundation`). **Best-effort / fail-open here:** if `gh` is absent, the branch doesn't exist, or this command errors, **proceed** with the drain — the archiver's fail-CLOSED guard is the real safety net, so this check never blocks on a `gh` hiccup.

   **If a PR IS open, classify it healthy vs. stalled before deciding how to exit** — stalled ⟺ the PR's checks rollup reads **FAILURE**, or its `mergeStateStatus` reads **BEHIND**; anything else (PASS, PENDING, NONE, CLEAN, UNKNOWN, …) is healthy/uncertain, and a probe error is treated the same as healthy (fail-open — never blocks). **Do not re-derive this predicate by hand** — it IS `archive-session.sh`'s own `heal_archive_pr()` predicate (`workflows/scripts/sessions/archive-session.sh`, foundation repo), reached through its standalone `heal-stalled-pr` entry point, so the two halves structurally cannot disagree:
   ```
   bash ~/dev/foundation/workflows/scripts/sessions/archive-session.sh heal-stalled-pr
   ```
   This repairs a stalled PR (rebase onto `origin/<default>` + force-with-lease push) **without running a drain** — no stub args, no retention sweep, no `INDEX.md` regen. It prints **one or more lines, always ending in exactly one terminal `archive-heal-*` line**: on the stalled path it first emits a progress line (`archive-heal-stalled: PR #<n> mergeStateStatus=… checks=… — rebasing …`) and only then its terminal line, so a single-line assumption is wrong for 2 of the 3 outcomes. **Branch on the LAST `archive-heal-*` line**, never on the first:
   - **`archive-heal-skipped: PR #<n> is healthy (…)`**, or any other `archive-heal-skipped: …` line (probe error, not a git repo, another run holds the land lock — all fail-open/no-op) → the PR is healthy or its state can't be determined right now. **Exit now** with today's unchanged one-liner — `archive PR #<n> still open; skipping this drain until it merges` — and do no extraction.
   - **`archive-pr-healed: …`** → the PR WAS stalled and this call just repaired it for the *next* run. **Still exit this run without extracting** — the repair unblocks the *next* drain, not this one (the rationale below still applies: a full extraction now would still just defer at archive). Emit today's exit line, **plus** the visible defect below, so the operator sees this run auto-healed a stall rather than reading a plain, indistinguishable skip.
   - **`archive-heal-failed: …`** → the PR was stalled and the heal itself failed (rebase conflict, rejected force-with-lease push, fetch failure). **Still exit this run without extracting.** Emit today's exit line, **plus** the visible defect below, carrying the failure reason verbatim — this must not be swallowed the way a bare skip line would swallow it.
   - **Anything else — the catch-all, and it is fail-open like the probe above.** If the command cannot be run at all (the script is missing, `~/dev/foundation` isn't there, `bash` fails before the script's own paths run), or its output matches **none** of the three prefixes, treat it exactly as `archive-heal-skipped`: **exit now** with today's unchanged one-liner and no extraction, and write no pending-decisions entry. This is a *second* external call added to this step, so it needs its own named failure path — the fail-open sentence above is scoped to the `gh pr list` probe and does not cover it. **Never fall through to extraction on an unrecognized outcome.**

   **Visible defect on the stalled path — not another silent skip line.** Append one `### open` entry to the pending-decisions surface (`Pipeline/pending decisions.md` vs the legacy `Context/pipeline - pending decisions.md` — target pinned by the append-target resolution rule of the path fallback convention, `claude/commands/check-in.md`; in the knowledge store) via `mcp__obsidian-builtin__vault_append`, in the same `### <ts> · tidy <sweep> · <key>` shape every other `ask-at-checkin` deferral in this file uses (§ Stale board claims, § Unlinked fix PRs):
   ```markdown
   ### <YYYY-MM-DD HH:MM> · tidy stalled-archive-PR · chore/session-archive#<n>
   - **Decision:** review the archive PR's heal outcome — <archive-pr-healed: …|archive-heal-failed: …, verbatim>
   - **Default taken:** heal attempted automatically via `archive-session.sh heal-stalled-pr`; this drain still exited without extracting
   - **Disposition:** auto-taken (unattended/--force-now; no live operator)
   - **Status:** open
   ```
   Without this entry, a healed or heal-failed PR would read identically to a healthy one — the plain exit line — and nothing would ever alarm on a run that couldn't self-heal; this is the deadlock the live incident (7 stubs stranded, 26 at the worst) traced to. <!-- cite: T.22 class:silent-drain-deadlock -->

   Rationale: under delete-on-PR-record the archiver (`archive-session.sh` § 4b) **refuses to land** a second batch while an archive PR is open (its force-push would overwrite the unmerged PR branch, whose stubs are already gone from `_inbox`), so a drain now would extract for 10+ minutes only to defer at archive — wasted work. This Step-0 check is the **efficiency early-exit**; the archiver's guard is the **enforcement backstop**; the heal call above keeps a stalled PR from wedging every *subsequent* drain indefinitely; and `/check-in` reviews the pending-decisions entry to confirm the repaired PR actually merges. <!-- cite: T.5 incident:F#487 -->
3. **Source the batch-pipeline config (best-effort).** `source workflows/scripts/build/build.config.sh` (bare repo-relative, the kernel's Step-0 config-sourcing convention — `~/.claude/CLAUDE.md` § Named-setting convention). This pulls the drain-lock timing settings (`TIDY_SYNC_WAIT`, `TIDY_LOCK_STALE_AFTER`) into scope, with any pre-set env value still overriding, before step 4 below uses them. If the file isn't found, proceed — 4c/4d keep their inline `${VAR:-default}` fallbacks.
4. **Acquire the cross-machine drain lock.** Multiple machines share `Sessions/_inbox/` via Obsidian Sync, so two `/tidy` runs (e.g. evening runs on two machines within a minute of each other) can process the same backlog at once and double-create Things tasks (the Step 4 dedup is search-then-add, not atomic across concurrent runs). Sync is eventually-consistent (~seconds to a minute), so a plain lockfile is racy — the protocol is **acquire → wait for Sync → elect**, earliest timestamp wins. It has **two arms, selected on exactly the predicate `claude/commands/build.md` § 3g keys its own headless branch on** — `PIPELINE_OPERATOR_ABSENT=1` ⇒ **headless one-shot**, anything else ⇒ **loop-capable**. A loop-capable run takes 4a–4e below; a headless run takes **4f instead** and never reaches 4c's wait: <!-- cite: T.4 incident:F#1201 -->
   a. Get identity (Bash): `EPOCH=$(date +%s)`, `HOST=$(hostname -s)`.
   b. Write `Sessions/_inbox/.drain.lock.<HOST>` containing one line `<EPOCH> <HOST> <this session-id>` (via `mcp__obsidian-builtin__vault_write`). **One file per host** — never a single shared lock file (concurrent writers would clobber it).
   c. Wait `TIDY_SYNC_WAIT` seconds to let Sync propagate every host's lock in both directions, then continue to 4d. **Use exactly one mechanism — a single backgrounded sleep — and nothing else:** make **one** Bash tool call, `sleep "$TIDY_SYNC_WAIT"`, with `run_in_background: true`, then **end your turn immediately with no further output** — the harness re-invokes you when the sleep exits, and you resume at 4d. Do **not** run a foreground `sleep` (the harness blocks it); do **not** use `Monitor`, an until-loop, or any poll (`Monitor` is a deferred tool whose schema must be fetched via `ToolSearch` first — calling it unfetched raises `InputValidationError`, and this poll arm is exactly what silently stalled an entire unattended run in F#1201); and do **not** spend turns narrating that you are waiting. **If the backgrounded sleep cannot be started at all, do not retry or spin — skip the wait and proceed directly to 4d.** A skipped wait risks at worst a rare cross-host double-drain (see 4f's residual-risk note for exactly what that does and does not duplicate); a *stalled* wait burns the whole unattended run to a zero-stub no-op, which is far worse. *(Override: if the user passed `--force-now`, skip the wait + election and proceed — a single-machine escape hatch for when you know no other host is draining. A `PIPELINE_OPERATOR_ABSENT=1` run never arrives here at all — it took 4f.)*
   d. Re-list `_inbox/` and read every `.drain.lock.*` file. **Discard and delete any lock whose `<EPOCH>` is older than `TIDY_LOCK_STALE_AFTER`** (a crashed prior run — never let it block forever). The delete is **best-effort**: if it fails (a Sync conflict, a permissions error), the lock is still discarded from *this* election — note it in one line and carry on, leaving the file for a later run's reap. Among the rest, the winner is the **lowest `<EPOCH>`**; tie-break on the lexicographically smallest `<HOST>`.
   e. If **my** lock is the winner → proceed to Step 1. Otherwise → delete my own `.drain.lock.<HOST>` and exit with one line: "another host (`<winner>`) is draining — yielding."
   f. **Headless arm (`PIPELINE_OPERATOR_ABSENT=1`) — `--force-now` semantics: no Sync wait, no election, never blocks.** A `claude -p` one-shot has **no re-invoke-on-background-completion loop** (the same fact `build.md` § 3g keys on), so 4c's backgrounded sleep ends the session *at* the wait and the nightly drain never resumes at 4d — the entire run lost to a zero-stub no-op. This arm keeps a lock anyway, in one non-blocking pass: <!-- cite: T.24 incident:K#1454 -->
      - **Cheap non-blocking peer check first.** Issue your own `Glob` call on the resolved `Sessions/_inbox/` path, filtered to `.drain.lock.*` entries, and read every file it returns — one pass, no wait. (This is a genuinely *first* list of the lock files, not a re-list: 4a is identity-only (`EPOCH`/`HOST`) and returns no listing, and Step 0 item 2's own listing explicitly says to ignore `.drain.lock.*` entries — so there is no prior lock-file listing here to reuse.) Reap any whose `<EPOCH>` is older than `TIDY_LOCK_STALE_AFTER`, same best-effort disposition as 4d. If a **live** (non-stale) peer lock remains → **yield**: write no lock, drain nothing, exit with one line — "another host (`<peer>`) holds a live drain lock — yielding (headless, no wait)". That is a legible no-op, not a failure.
      - **Otherwise write my own lock and go.** Write `Sessions/_inbox/.drain.lock.<HOST>` exactly as 4b does, then proceed **straight to Step 1** — no `TIDY_SYNC_WAIT`, no election, no re-read to confirm it propagated. Step 7 removes it like any other run's.
      - **Residual risk — stated narrowly, and accepted.** The check→write gap is a TOCTOU window: two hosts firing at the same wall-clock second can each see no peer lock and both drain. Step 4's search-then-add dedup absorbs **Things-task duplication only**; it says nothing about Step 3's vault writes, which are existence-check dedup'd against the same stale read — so a genuinely simultaneous double-drain **can** duplicate a Decision/Pattern/Mistake/auto-memory note. That is an **accepted residual risk** on this arm, not a covered one: the only stronger guarantee is the Sync-wait election, which a headless run structurally cannot complete, and the alternative to draining is losing the night's signal entirely. The normal single-host nightly has no peer to race.
      - **The kernel ships no nightly agent.** This repo carries no launchd plist and no nightly wrapper — the `claude -p "/tidy"` invocation and its `PIPELINE_OPERATOR_ABSENT=1` export are the **overlay's** (`tidy-nightly.sh`, `infra/launchd/`). A wrapper that does not export it selects 4a–4e and dies at the wait exactly as before; exporting it is this fix's install half.

## Step 1 — Scan each stub (consume the scan report)

**Do not load the full transcript.** The scanner pre-processes each stub into a compact JSON report (~2-3k tokens vs. ~18k for the raw transcript). Run it first; the report is your primary input. For each file in `_inbox/`: <!-- cite: T.6 guard:workflows/scripts/drain/scan_stub.py -->

1. Derive the stub's local filesystem path — a **raw on-disk path outside the knowledge_store seam**: `scan_stub.py` reads the file directly from disk rather than through `ks_read`/MCP, because the obsidian backend's REST API has no filesystem-root semantics to route a disk read through (per `workflows/scripts/lib/knowledge_store.contract.md` § the obsidian backend's root-mapping note). Resolves under the knowledge store root, e.g. `$KNOWLEDGE_STORE_ROOT/Sessions/_inbox/<filename>.md`.
2. Run the scanner, capturing its JSON output:
   ```
   python3 ~/dev/foundation/workflows/scripts/drain/scan_stub.py \
     $KNOWLEDGE_STORE_ROOT/Sessions/_inbox/<filename>.md
   ```
   The scanner emits a single JSON object to stdout (schema: `workflows/scripts/drain/scan-report-schema.md`). Parse it and hold it in memory — this is the **scan report** for this stub.
3. **Read the scan report, not the transcript.** Your extraction input is:
   - `report.stub` — session id, project, date for provenance attribution.
   - `report.lexicon_matches[]` — pre-matched extraction tells with category, matched line, and ±1 context. Step 3 adjudicates these — they are candidates, not confirmed extractions.
   - `report.user_turns[]` — digest of non-excluded user turns (truncated at 500 chars each). Skim for novel signal the lexicon can't catch (new phrasing, implicit commitments, preference shifts).
   - `report.tool_events` — structured AskUserQuestion Q/A pairs, tool errors, user interrupts, and `capture.sh` calls. Step 3 uses these as supporting evidence.
4. **Wider transcript access is the exception, not the rule.** Only fetch a wider window from the raw `.jsonl` (via `Read` on the path in the stub frontmatter's `transcript:` field) or from the stub itself (via `Read` on the stub's resolved file path) when a specific `lexicon_match` or `user_turns` entry is **genuinely ambiguous** — i.e., you can't tell from the match + ±1 context whether it's a real extraction candidate. When you do, read only the surrounding turns, not the full file.

## Step 2 — Sensitivity scan (mandatory)

Before extracting anything, scan each stub for: <!-- cite: T.7 class:credential-leak-propagation -->
- API keys, bearer tokens, OAuth secrets (e.g. long hex strings, `Bearer <hex>`, `sk-...`, `ghp_...`)
- Plaintext passwords
- Personal info that doesn't belong in a vault (SSN, full credit card numbers)

If found: **do not** copy the secret into any extracted artifact. Because this run is unattended, the Step 6 summary alone would never reach the operator — so **append one `### open` entry to the sensitivity-flags surface** (`Pipeline/sensitivity flags.md` vs the legacy `Context/pipeline - sensitivity flags.md` — target pinned by the append-target resolution rule of the path fallback convention, `claude/commands/check-in.md`; in the knowledge store) via `mcp__obsidian-builtin__vault_append`, recording the stub filename, the *kind* of secret (never the secret value itself), and its approximate location, with `Status: open`. Create the note with a one-line header if neither path exists (at the path the append-target resolution rule selects for creation). Also note the count in the Step 6 summary. `/check-in`'s `## Sensitivity flags review` section disposes it (redact the source stub, or dismiss as a false positive). Continue processing the rest.

## Step 3 — Extract learnings

**Input: the scan report from Step 1.** Adjudicate `report.lexicon_matches[]` (decide which flagged tells are real extractions vs. noise or already-captured live) and skim `report.user_turns[]` for novel signal the lexicon couldn't catch. Run the **Tool-event structural passes** below first — they reach the insight class no text phrase can surface — then run the tell-based extractors that follow.

**Spec-authoring damping (foundation#1137).** When `report.spec_authoring_context` is `true`, this session edited the drain's own tell-defining files (a command spec / CLAUDE.md / a lexicon TSV), so it quotes tell phrases verbatim and `report.lexicon_matches[]` is **deliberately empty** (`scan_stub` suppressed a false-positive storm; the count is in `report.lexicon_matches_suppressed`). Do **not** treat the empty match list as "no signal." Two fallbacks, both in force: <!-- cite: T.8 incident:F#1137 -->

- The phrase-independent **Tool-event structural passes** (errors, `capture_calls`, interrupts, AUQ answers) never used the lexicon, so they run unchanged.
- **Three extraction classes are lexicon-driven AND assistant-narrated, so a `report.user_turns[]` skim CANNOT recover them** (that digest is user turns only): § Self-correction moments (`category: "self-correction"`), § Unfiled defects' `worked-around-defect` category, and § Tooling friction's `state-collision` tells. On a damped stub these do **not** self-heal — do not treat the stub as "clean" for them. Instead **skim the ASSISTANT turns directly** (via the Step 1.4 wider-transcript access) for a genuine mid-session self-correction / worked-around-defect / stale-state realization, applying **heightened skepticism**: the very reason the lexicon was damped is that this session writes those tell phrases *into a spec as content*, so distinguish a real in-flight realization from a tell phrase merely being authored into a file.

Note the damping (`lexicon damped: N suppressed`) in the Step 6 summary so the suppression is visible, not silent.

**Adjudication rule for `lexicon_matches`.** Each match is a candidate. For each:
- Read the `match.line` and `match.context` (±1 lines). If clearly a real signal (an unfiled defect, a decision, friction, etc.) → extract. If clearly noise (incidental phrase, confirmed-already-live) → skip. If ambiguous → fetch the wider transcript window (Step 1.4) and then decide. Track your adjudication in the summary so the step count reflects actual extractions, not raw match count.

> **Canonical tell source.** The phrases and patterns used to identify insight-bearing moments in transcripts (friction slugs, defect language, deferral markers, self-critique, user pushback, etc.) are maintained as a structured data file: `workflows/scripts/drain/lexicon.tsv` in the foundation repo. That file is the **single source of truth** for extraction tells; `report.lexicon_matches[]` is its pre-applied output — the inline examples in the extractor steps below are illustrative, not exhaustive.

### Provenance tagging

**Every extraction produced in Step 3 is tagged with its provenance** — how it was found. This tag is carried on every findings record (see § Findings records below) and drives the candidate-tells accumulation.

Two provenance values:

- **`lexicon-hit`** — the extraction was triggered by a tell in `report.lexicon_matches[]`. Record the specific tell in `sub_method` (the `match.tell` field that fired).
- **`model-skim`** — the extraction was found by the model reading `report.user_turns[]` with no matching lexicon tell. `sub_method` is `null`.

**How to assign provenance.** For each extraction you decide to accept:
1. Check whether the extraction source appears in `report.lexicon_matches[]` — specifically, does any entry's `match.line` or `match.context` overlap with the user turn or phrase you are extracting from?
2. If yes → `lexicon-hit`; set `sub_method` to that entry's `tell` field.
3. If no → `model-skim`; the model caught it from `user_turns[]` alone.

Model-skim extractions ARE the lexicon's measured misses. Tag them carefully — they are what drives the lexicon's growth. <!-- cite: T.9 guard:workflows/scripts/drain/findings-schema.md -->

### Tool-event structural passes

`report.tool_events` carries the insight class no text phrase can reach — the densest signal the lexicon never sees. Walk each sub-array before the tell-based extractors below; each class routes into an existing extractor rather than a new one.

#### AskUserQuestion answers → Feedback memories / Decisions

Walk `report.tool_events.ask_user_questions[]`. For each entry:

- **Skip unanswered** (`answer: null`) — no signal to extract (though an unanswered question on an unattended run is a pending-decisions candidate; see § Pending decisions surface below).
- **Read the answer.** A Q/A pair captures the user's live judgment — the answer carries the strongest feedback and decision signal in the whole transcript, and it never appears in `user_turns[]` (tool results are outside the stub body).
- **Route by content:**
  - An answer that expresses a **preference, correction, or behavioral rule** (e.g. "file a bug to track it", "don't do that again", "yes that's the right approach") → **Feedback memories** extractor. Treat it exactly as a user correction or confirmation: save to auto-memory under `feedback_<topic>.md`.
  - An answer that makes a **project or architectural commitment** (e.g. "go with option B", "we'll use X for this") → **Decisions** extractor. Treat it as a decision datum with provenance from the Q/A pair.
  - An answer that reveals a **user preference or context** (role, workflow, tool habits) → **User memories** extractor.
  - Ambiguous — apply the same heuristic as `lexicon_matches` adjudication; fetch wider context from the stub if needed.
- Skip entries where the live session already captured the answer (check Decisions/memories for the same content before writing).

#### tool errors (hard + soft) → Tooling friction / Mistakes / Unfiled defects

Walk `report.tool_events.errors[]`. Each entry carries `kind`: **`hard`** (the tool result was flagged `is_error: true`) or **`soft`** (foundation #444 — `is_error` false/absent, but the content carried an error signature like `jq: error`, `Traceback`, `command not found`, `fatal:`; the class where a Bash command emits a downstream tool's error to stdout yet exits 0, so the harness never flagged it). For each entry:

- A **hard** error is a tool failure: MCP param misuse, a missing file path, an unexpected API response, a permission denial, or an auto-classifier rejection.
- A **soft** error is the higher-signal class for **undetected defects** — a tool that *silently* failed. Treat a recurring soft failure (the same signature firing more than once in the session) as an **Unfiled-defect candidate** (route to § Unfiled defects, cross-referencing `capture_calls[]` first): it is exactly the worked-around-but-never-filed pattern #444 exists to catch (the BOARD_ITEMS_JSON `jq` parse error of #443 was three soft failures). A one-off soft failure that the session clearly handled is friction, not a defect.
- **Route to § Tooling friction** when the error reflects an avoidable step — a wrong tool contract, a malformed input, a retry loop the session could have avoided. Category hint: `tool-misuse` or `probe-after-not-before`.
- **Route to § Mistakes** (vault `Mistakes/`) when the error reflects a real pitfall worth recording — a pattern that failed, an MCP tool that misfires on certain inputs, a harness behavior that is non-obvious. Applies the vault provenance schema.
- An error that is clearly environmental (network timeout, a transient file-not-found on a race) is not a pitfall or friction event — skip it.
- Default to silence: most errors are transient; only extract errors that are actionable or recurrence candidates.

#### `[Request interrupted by user for tool use]` → Feedback memories

Walk `report.tool_events.interrupts[]`. Each interrupt is the single most reliable user-rejection signal in the transcript — the user stopped Claude mid-tool, which is always an implicit "not that" feedback moment.

- Route every interrupt to the **Feedback memories** extractor as a user correction.
- To reconstruct what was being rejected, find the surrounding tool_use in the raw `.jsonl` near `location` (or skim `report.user_turns[]` and `report.lexicon_matches[]` for context from the same turn range).
- Save to auto-memory under `feedback_<topic>.md` (type: feedback). Body: what Claude was doing, what the interrupt says about the user's preference.
- If the surrounding context is genuinely ambiguous (no nearby tool call visible from the scan report), skip rather than guess.

#### `capture_calls` → Unfiled defects dedup

Walk `report.tool_events.capture_calls[]`. Each entry means `capture.sh` was invoked during the session — the defect WAS filed at source.

- **These are dedup signals for § Unfiled defects**, not new extractions. When the Unfiled defects pass below identifies a candidate defect, cross-reference `capture_calls[]` first: if the defect's keywords appear in any `capture_calls[].command`, the live "Capture at source" rule fired and the defect is already on the board — skip it, do not re-file.
- Do not route `capture_calls` to Decisions, Feedback, or Mistakes — they are evidence of completed live filing, not a new insight.
- Surface the count in the Step 6 summary (`capture_calls seen: N`) so the operator can confirm live capture is firing as expected.

For each stub, identify the following **only when present and not already captured live**:

> **Vault provenance schema (note-level).** All vault writes for `Decisions/`, `Patterns/`, `Mistakes/`, and `Context/` use this frontmatter + footer:
>
> ```yaml
> ---
> tags: [<kind>, project/<name>, ...]   # kind = decision | pattern | mistake | context
> date: <YYYY-MM-DD from stub frontmatter>
> source_kind: claude-stamped
> source_session: <stub filename without `.md`>
> source_model: <stub `model:` field — the analyzed session's model; omit if stub has none>
> extracted_by_model: <your current model ID — the model running this drain>
> last_verified: <same as date>
> ---
> ```
>
> ```markdown
> ## Source
> [[Sessions/<stub filename without `.md`>]] — <one-line context on which session moment produced this>.
> ```
>
> Reference: the knowledge store's `Decisions/foundation - Vault provenance schema (note-level).md` note. Apply on every newly-created note in this step. (Auto-memory under `~/.claude/projects/.../memory/` keeps its own format and is not affected.)
>
> **Model provenance — subject vs. analyst.** `source_model` is the **subject**: the model whose behavior/work the note is *about*. In a drain it is **not** you — it is the analyzed session's model, read from the stub's `model:` frontmatter field (written by the SessionEnd hook from the transcript's distinct `.message.model` set). `extracted_by_model` is the **analyst**: your own current model ID, the model running this drain. So a Mistake is attributed to the model that *made* it and a Pattern to the model that *did* it, while the extraction itself is credited to the drain runner. **If the stub carries no `model:` field** (older stub, pre-dating this hook change), **omit `source_model`** — never substitute your own drain model for it; absence reads as "subject model unknown," not "drained by X." <!-- cite: T.10 class:mis-attributed-model-evidence -->

### Decisions
Architectural, product, or process choices with rationale.
- Check `Decisions/` for an existing note covering the same decision (filename pattern: `<project> - <short title>.md`). If present, skip the *creation* path — live capture worked — but still run the **provenance audit** below.
- If missing, write `Decisions/<project> - <short title>.md` with the vault provenance schema frontmatter (`tags: [decision, project/<name>]`) and body covering: **what** was decided, **why**, **alternatives considered**, **trade-off accepted**. Cross-link to superseded decisions via `[[wikilinks]]`. End with the `## Source` footer.

#### Provenance audit (existing decisions)

For every `Decisions/<project> - *.md` mentioned by name in the stub, fetch its frontmatter via `Read` on the resolved file path. If any of `date`, `source_kind`, `source_session`, or `last_verified` is missing, OR the `## Source` footer is absent, the file was captured live without the provenance schema and needs backfilling.

`source_model` is **conditionally** part of this audit: only backfill it when the stub carries a `model:` field to source it from. A claude-stamped note missing `source_model` whose stub *also* has no `model:` is **not** a gap — treat it as "predates model provenance" (forward-only, exactly like notes that predate the whole schema). Never invent a `source_model`, and never substitute the drain runner's model for the missing subject.

Decide authorship from the stub:

- **Clear authorship** — the stub contains assistant-turn phrases like "wrote `Decisions/X.md`", "captured to vault", "writing the Decision now", "I'll create the decision file", or a tool-call result showing the file was created. Backfill in place via `mcp__obsidian__patch_vault_file`:
  - Frontmatter: set `date` and `last_verified` to the stub's date, `source_kind: claude-stamped`, `source_session: <stub filename without .md>`, and — only if the stub has a `model:` field — `source_model: <stub model>`. Preserve existing `tags` and any other fields.
  - Footer: append `## Source\n[[Sessions/<stub filename without .md>]] — <one-line context from the stub on which moment produced this decision>.`
- **Ambiguous authorship** — the decision is referenced but the stub doesn't claim it (e.g., it just links `[[stageFind - X]]` while discussing something else). Do **not** backfill. List the file in the summary block under `Provenance gaps` so the user can attribute it manually.

Track each backfilled file and each gap separately for the summary.

#### Contradiction detection (cross-session supersession proposer)

**A drain-internal detector**, not a capture/backstop pair. The capture rule in `claude/CLAUDE.md` § Decision capture asks an author to link a supersession *they already recognized* at bank time ("If a decision overturns or supersedes a prior one, link the prior note via `[[wikilink]]` and note the supersession"). This pass finds the *unrecognized* ones — a drain (or live `Decisions/` bank) lands a new/amended decision that contradicts an earlier note **without anyone noticing**, the "stale-assumption" error class no grep tell can surface, because the earlier claim only becomes wrong in light of the later one (governing spike: `Decisions/foundation - Cross-session contradiction detection (spike verdict)`). It is therefore **drain-internal** like the § Recurrence → promotion pass below — it has **no capture anchor it backstops, no Capture/Backstop registry row, and needs no `validate-capture-backstop.sh` change** (rationale + the superseded "registry row mandatory" cost line: the linked spike note). It **proposes** supersessions; it never edits a banked note. <!-- cite: T.11 class:auto-edited-banked-notes -->

**Run this for each `Decisions/<project> - *.md` note that this drain run banked new OR amended** (the creation path above, and any note the provenance audit touched). Skip notes only re-read but not changed.

For each such note `D_new` (project `P`):

1. **Retrieve the near-neighbours — do not scan the corpus.** Run `ks_search` on `D_new`'s claim text (its `what was decided` / `## Source` body, not the frontmatter), then keep only the `Decisions/` hits. **Invoke it literally as `ks_search "<claim text>" --limit 15`.** `--limit` and `--partition` are the **only** arguments `ks_search` accepts (`workflows/scripts/lib/knowledge_search.sh` § Public interface), and it rejects any other with **exit 2 before making a backend call** — so a guessed folder argument (`--folders Decisions`, `--scope Decisions`) is a hard usage error, never a scoped search. **Folder scoping is a post-filter, not an argument:** each result line is `{"doc_id","title","score","snippet"}` with `doc_id` a store-relative path, so drop every hit whose `doc_id` does not start with `Decisions/` and keep the top ~5 survivors — the wider `--limit` exists because that filter runs *after* the backend's cut. This returns the semantically-nearest prior decisions — the only set a contradiction could plausibly live in. (`Decisions/` is curated knowledge-store content, which the search index **does** cover — the "no semantic search" rule is scoped to raw transcripts in `meta/sessions/archive/`, so no new index is needed.)
2. **Constrain scope to the same project.** Drop any neighbour not tagged `project/<P>` — cross-project neighbours are noise. Also drop `D_new` itself and any note `D_new` already `[[wikilinks]]` as superseded (it was handled live).
3. **One bounded judgment per surviving neighbour `D_prior`** (≤5 total). Ask yourself a single yes/no: *does `D_new` assert something that **empirically contradicts or supersedes** `D_prior`?* Demand a genuine X-vs-not-X about the **same referent** (one note says a mechanism handles a case, the other empirically disproves that). **Reject mere refinement/elaboration** — most new decisions narrow or extend a prior one without contradicting it; those are not supersessions. Apply a similarity floor: if a neighbour is only loosely related (different referent), skip the judgment entirely.
4. **Surface a "yes" — never auto-edit.** For each judged contradiction, append one `### open` entry to the proposed-supersessions surface (`Pipeline/proposed supersessions.md` vs the legacy `Context/pipeline - proposed supersessions.md` — target pinned by the append-target resolution rule, `claude/commands/check-in.md`; in the knowledge store) via `mcp__obsidian-builtin__vault_append` (entry format defined in that note's header). Record: `D_new`, `D_prior`, the supersession **direction** (which note wins), and a one-line statement of the empirical contradiction. This is a **companion** to the unattended pending-decisions surface — a separate file so its append stream never interleaves with that file's seven `ask-at-checkin` EOF writers — read by the same `check-in` review (no new review step). `check-in` reads these and, on the operator's confirm, hand-adds the `[[wikilink]]` + supersession line to the notes — the convention stays human-owned.

**Default to silence + liberal judge.** Most drains bank no decision, and most banked decisions contradict nothing — surface nothing in that case. Because the output is **proposal-only** (a false positive costs the operator one glance at `check-in` and a dismiss; it never mutates a note), bias the judge toward flagging when genuinely uncertain — the asymmetry (cheap FP, expensive missed contradiction) is the same logic as the dropped-bug capture net. If `ks_search` is **unavailable — exit 3**, the backend's own legible-degradation code — skip this pass with a one-line note in the summary (do not fall back to a corpus scan). **Never read a usage error as unavailability:** **exit 2** means *your call was malformed* (an unrecognised argument, an empty query, a `--limit`/`--partition` with no value), so fix the invocation per step 1 and re-run — skipping on an exit 2 silently disables the whole supersession proposer on a fault that is one corrected argument away (temperloop#1170). Any other non-zero (e.g. exit 4, a backend error) is reported the same way as exit 3.

### Feedback memories
User corrections OR user confirmations of non-obvious approaches. (Both directions matter — see auto-memory rules.)

**Adjudicate `report.lexicon_matches[]` for `category: "trust-rupture"` matches** — this step's lexicon anchor, and the named consumer of that category (temperloop#1090), exactly as § Tooling friction anchors on `friction-slug`/`state-collision`, § Unfiled defects on `worked-around-defect`, and § Self-correction moments on `self-correction`. `trust-rupture` is the user-turn pushback category in `workflows/scripts/drain/lexicon.tsv` — explicit doubt, correction, or a re-stated instruction — and it is the operator saying directly that something went wrong, the verbal peer of the `interrupts[]` pass above. Read each match plus its ±1 context, apply the same liberal-but-not-noisy judgment as the `lexicon_matches` adjudication rule, then **route by failure mode** — the three the category spans are not interchangeable:

- **Correctness challenge** (*"are you sure"*, *"I think you're wrong"*, *"solving the wrong problem"*) — the assistant's *conclusion* was doubted → a **feedback memory** below (`feedback_<topic>.md`), stating the rule the pushback implies.
- **Communication failure** (*"I don't understand"*, *"is jargon"*, *"dense to parse"*) — the assistant's *explanation* failed to land, not its conclusion → **not a feedback memory; route to § Tooling friction (fewer-steps)**, which owns this subset as its `clarification-rework` ledger category (temperloop#1089). The split is made **here, at consumption time** — the lexicon deliberately keeps one `trust-rupture` category and the two steps discriminate the same matches by failure mode — so bank nothing here for a match you route there, and nothing there for the other two subsets.
- **Repeat-offence** (*"again,"*, *"I've told you before"*, *"this shouldn't keep happening"*) — a rule already stated is not being followed → bank the feedback memory **and** treat it as a **rule-promotion candidate**: its `feedback` findings record (§ Findings records) is what § Recurrence → promotion tallies into a "promote to a CLAUDE.md rule" task, and if the rule would belong upstream, apply § Kernel-candidate learnings' stranger test to the note it produces.

**Evidence is a verbatim quote, always.** Every artifact this step produces — memory or promotion candidate — carries the **exact pushback line from the transcript** (the `match.line`, unparaphrased) in its body, so the operator can see what was actually said rather than the drain's reading of it. No quote, no artifact.

**Default to silence.** Most stubs carry no genuine pushback: a stub with no `trust-rupture` match and no correction in `report.user_turns[]` produces **nothing here** — do not manufacture a feedback memory from ordinary clarifying questions or from the assistant's own hedging.

- Save to the project's auto-memory directory under `feedback_<topic>.md` with `type: feedback`. Body: rule, then `**Why:**` line, then `**How to apply:**` line, then the verbatim quote above.
- Add an index entry in `MEMORY.md`.
- Skip if a duplicate exists.

### Project memories
Who is doing what, why, by when. Convert relative dates to absolute.
- Save to auto-memory under `project_<topic>.md`, type `project`.

### User memories
Role, preferences, knowledge revealed. Save to auto-memory under `user_<topic>.md`, type `user`. Skip if redundant with existing.

### Patterns
Reusable approaches that worked. Save to vault `Patterns/<title>.md` with the vault provenance schema frontmatter (`tags: [pattern, project/<name>, ...]`) and the `## Source` footer. Skip if a pattern with the same title already exists.

### Mistakes
Pitfalls, failure modes, things that broke. Save to vault `Mistakes/<title>.md` with the vault provenance schema frontmatter (`tags: [mistake, project/<name>]`) and the `## Source` footer. Skip duplicates.

### Kernel-candidate learnings

**Backstop for `claude/CLAUDE.kernel.md` § Kernel vs overlay routing rule** (only when this checkout carries that file — skip this pass entirely otherwise, no note, no tag). The capture rule asks whoever routes a new rule/decision to apply the **stranger test** at capture time; this pass catches a `Decisions/` / `Patterns/` / `Mistakes/` note this run **banked or amended** (the creation and provenance-audit paths above) that the live session captured without running that test.

For each such note, apply the stranger test: would a stranger's kernel-only install need this for the kernel machinery (board adapter, build/sweep pipeline, install/doctor, branch/PR policy) to work correctly? If yes and the note isn't already tagged `kernel-candidate`, add that tag to its frontmatter `tags:` list via `mcp__obsidian__patch_vault_file` (a targeted `tags:` field patch, not a rewrite) — this flags it for eventual upstream contribution once the kernel repo exists as a live checkout. Never remove an existing `kernel-candidate` tag, and never tag a note the stranger test doesn't clearly pass — **default to `overlay`** (no tag), matching `/triage`'s Step 2.8 default (a missed kernel tag costs nothing; a wrongly-added one misroutes a personal/org-specific note).

**Default to silence.** Skip entirely on a checkout with no `claude/CLAUDE.kernel.md`. Most notes stay untagged.

### Provenance-less epics

Backstop for `claude/CLAUDE.kernel.md` § Design-first default for invented work (temperloop#218). The capture rule asks whoever materializes invented, epic-sized work to route it through `/workshop` first, and `/assess` Step 1 backstops it **in-band** (a legible, fail-open ask fires the moment such an epic reaches decomposition) — but an epic that is created and never assessed (sitting on the board, never run through `/assess --epic N`) slips past that in-band check entirely. This sweep is the periodic, out-of-band net: it catches a hand-authored epic before anyone gets around to assessing it.

**Run for each governed board** (via the board adapter — `board_item_list <board>`, or a raw `gh issue list -R "$repo" --search "## Contract in:body" --state open` if this checkout doesn't vendor the adapter): list **open** epics — issues carrying native sub-issues, or an `epic` label — whose body contains a `## Contract` heading but **no** `design-brief: [[Designs/` marker line (the same marker `/assess` Step 1 and `/workshop` Step 5a check). **Read-only** — this sweep never edits an epic body, never touches its `design-brief:` state, and never blocks anything; it only reports. **Scope — Contract-shaped epics only:** an invented epic hand-decomposed straight into sub-issues with *no* `## Contract` is invisible to this sweep (and to `/assess`'s in-band check, which gates on the same shape) — a **ratified accepted-gap decision**, deliberately not widened here: flagging every Contract-less epic would drown the legitimate discovered-work epics `/triage` births, which never carry a Contract by design. The temperloop#286 spike confirmed no reliable *retroactive* signal distinguishes the two — see `[[Decisions/temperloop - provenance net scope (invented-epic distinguishability spike)]]` (accepted-gap record: temperloop#349).

For each hit, append one `### open` entry to the pending-decisions surface (`Pipeline/pending decisions.md` vs the legacy `Context/pipeline - pending decisions.md` — target pinned by the append-target resolution rule of the path fallback convention, `claude/commands/check-in.md`; in the knowledge store) via `mcp__obsidian-builtin__vault_append`:

```markdown
### <YYYY-MM-DD HH:MM> · tidy provenance-less-epic sweep · <board>:#<n>
- **Decision:** epic #<n> ("<title>") carries a `## Contract` with no `design-brief:` marker — was it meant to go through `/workshop` first?
- **Default taken:** leave as-is (report-only; epic not edited, not parked, not blocked)
- **Disposition:** auto-taken (unattended; no live operator)
- **Status:** open
```

Skip an epic already recorded by a prior sweep (match on board + issue number under an existing `open` entry) — don't re-append the same finding every run.

**Default to silence.** If a board has no such epics, surface nothing. Same report-only stance as § Stale board claims above — this sweep proposes a review, it never edits an epic; `/check-in` disposes it (confirm the epic is fine as hand-authored, or run `/workshop` retroactively and materialize the marker onto it).

### All-accepted-untouched briefs

Backstop for the live `/workshop` delta-approval rule (`claude/commands/workshop.md` § Step 3.7 — Delta report): every dimension is rendered with its full current text and its before/after deltas, each cluster question carries that Δ inside its own block, and each dimension takes **one verdict of its own** — a contest is always available. Nothing live can force genuine engagement, though — an operator who accepts every dimension without ever contesting one is, in the moment, indistinguishable from one who engaged and simply found nothing to challenge. This sweep is the periodic, out-of-band tell: it reads each **ratified** brief's challenge record (the `### Challenge record` subheading, `claude/design-schema.md` § Challenge record) and flags the pattern that shape would leave — every single stop line's verdict reading bare `accepted`, with zero `challenged → revised` or `operator-edited` verdicts anywhere in the record. That pattern is not itself a defect (a genuinely sound design can legitimately draw no challenges), but it is worth a human glance.

**Scope — ratified briefs with a populated record only.** List `Designs/*.md` in the knowledge store (`Glob` on the resolved path) and read each brief's frontmatter. Skip any `status: draft` or `status: dropped` brief (the record isn't finished, or the case is closed). Skip a ratified brief with **no** `### Challenge record` subheading at all — the schema's own migration carve-out: either a pre-record brief, or one where every dimension's first look sailed through with nothing worth logging at all (a valid, non-defective state per that section) — either way there are no per-stop verdicts to inspect for the ALL-ACCEPTED pattern.

**Detect the pattern.** For a ratified brief that DOES carry a `### Challenge record` with at least one stop line, parse every stop line's `verdict` token (`claude/design-schema.md` § Challenge record's per-stop line shape). If **every** line's verdict is bare `accepted` — none reads `challenged → revised ×<N>` or `operator-edited` — the brief is **ALL-ACCEPTED-UNTOUCHED**.

For each newly-found hit, append one `### open` entry to the pending-decisions surface (`Pipeline/pending decisions.md` vs the legacy `Context/pipeline - pending decisions.md` — target pinned by the append-target resolution rule of the path fallback convention, `claude/commands/check-in.md`; in the knowledge store) via `mcp__obsidian-builtin__vault_append`:

```markdown
### <YYYY-MM-DD HH:MM> · tidy all-accepted-untouched sweep · Designs/<note>
- **Decision:** brief "<note>" ratified with every challenge-record stop `accepted` and zero challenges — genuinely engaged, or rubber-stamped?
- **Default taken:** leave as-is (report-only; brief not edited, not reopened, not blocked)
- **Disposition:** auto-taken (unattended; no live operator)
- **Status:** open
```

Skip a brief already recorded by a prior sweep (match on the `Designs/<note>` path under an existing `open` entry) — don't re-append the same finding every run.

**Default to silence.** If no ratified brief matches the pattern, surface nothing. Same report-only stance as § Provenance-less epics above — this sweep never edits a brief, reopens it, or blocks anything; `/check-in` disposes it (spot-check the reasoning, or take no action if the design genuinely warranted no pushback).

### Undurable plan artifacts

Backstop for the live `/assess` sequencing check (`claude/commands/assess.md` § Artifact-availability audit, temperloop#697). That audit runs at plan-authoring time and repairs in place, but it is deliberately **advisory** — an author can leave a hit unresolved, and a plan written before the audit existed never saw it at all. This sweep is the periodic, out-of-band net over **written** plan notes: a plan that sequences on an artifact only reachable from the authoring session's untracked working tree or its tmp scratchpad — or on one no item produces and nothing durable supplies — strands the `/build` worker, which runs in a fresh, isolated worktree that inherits neither. <!-- cite: T.25 incident:K#697 -->

**Scope — live plans only.** `Glob` `Plans/*.md` on the resolved knowledge-store path and read each note's frontmatter. Skip `status: abandoned` and `status: done` (settled) and anything under `Plans-archive/` (already built): only a `draft`, `approved`, or `executing` plan still has sequencing that can strand a worker.

**Detect the tells** — **all three** the live audit names, applied to each note's `## Sequencing notes` section and to every item's `scope:` / `notes:` / `acceptance:` / `files:` text. Tells 1 and 2 are textual and mechanical; tell 3 is the cross-item read, and it is re-derivable here rather than out of scope: Step 4 of `/assess` writes out the very draft items and `## Sequencing notes` the live audit ran against, so a written note persists the whole of the audit's raw material and nothing it needed is lost at write time. Equivalence has to be carried by this text, because `workflows/scripts/validate-capture-backstop.sh` can only confirm the pair's *row* exists in both tables — never that this sweep re-derives the same findings.

1. **Session-scratch locator** — a path token under `/tmp/`, `/private/tmp/`, `$TMPDIR`, or containing `/scratchpad/`. Purely mechanical, no judgment: such a path is never durable.
2. **Untracked-precondition assertion** — an artifact asserted to already exist with no durable locator ("already authored", "already in the tree", "uncommitted", "staged locally"). When the assertion names a repo-relative path, confirm mechanically with `git ls-files --error-unmatch <path>` in the plan's home repo — a path git tracks is **not** a hit.
3. **No durable locator at all** — the cross-item "consumed but produced by no item" read, mirroring the live audit's framing sentence. There is no phrase to grep for, so derive it from the note's own fields. Build the plan's **produces set**: the union of every item's `files:` entries plus any artifact an item's `scope:` / `acceptance:` names as its own deliverable (`files:` is the schema's nearest thing to a declared output — `claude/plan-schema.md` § Item fields at a glance). Then take each **concretely named** artifact an item consumes — named as an input by its `scope:` / `notes:` / `acceptance:`, or by `## Sequencing notes` — and flag it when it is in no item's produces set **and** has no durable locator: not tracked (`git ls-files --error-unmatch <path>` in the plan's home repo, or in the item's `repo:` when set) and not resolvable in the knowledge store (`Glob` the store for the named note). **Keep the bar high** so an unattended sweep stays quiet: "concretely named" means a file path, an ADR or note title, or a named fixture/corpus — never a generic capability, and never an ambient dependency that is not a plan artifact at all (a tool on `PATH`, an installed binary, a merged upstream PR, a board issue). Where the note's prose is too thin to tell consumption from mere mention, that is a **non-hit**: this tell reports the cases the note itself makes legible, and false silence is the cheaper error for a report-only sweep.

For each hit, append one `### open` entry to the pending-decisions surface (`Pipeline/pending decisions.md` vs the legacy `Context/pipeline - pending decisions.md` — target pinned by the append-target resolution rule of the path fallback convention, `claude/commands/check-in.md`; in the knowledge store) via `mcp__obsidian-builtin__vault_append`:

```markdown
### <YYYY-MM-DD HH:MM> · tidy undurable-plan-artifact sweep · Plans/<note>
- **Decision:** plan "<note>" sequences on `<artifact>` at `<asserted location — or "no locator given; produced by no item" for tell 3>`, which a clean checkout does not have — stage it durably, or make authoring it part of the consuming item?
- **Default taken:** leave as-is (report-only; plan not edited, not re-assessed, not blocked)
- **Disposition:** auto-taken (unattended; no live operator)
- **Status:** open
```

Skip a plan+artifact pair already recorded by a prior sweep (match on the `Plans/<note>` path **and** the artifact under an existing `open` entry) — don't re-append the same finding every run.

**Default to silence.** If no live plan carries any of the three tells, surface nothing. Same report-only stance as § Provenance-less epics and § All-accepted-untouched briefs above — this sweep never edits a plan note, never flips its `status:`, and never blocks a build; `/check-in` disposes it (stage the artifact, re-run `/assess`, or dismiss it as already handled).

### Retro mint backstop

Backstop for the live `/build` **4d-retro mint** rule (`claude/commands/build.md` § Mint the per-epic retro tracker) — the registered Capture/Backstop pair of that mint (§ Capture/Backstop pairings above). The live mint files exactly one `Retro-for-epic: #<epic>` tracker at each epic's build-close; this sweep is the periodic net for the three ways that mint-then-judge loop can silently break. **Report-only — it mutates nothing:** no tracker, epic, or label is ever created, closed, or relabelled. Each probe that fires appends one `### open` entry to the pending-decisions surface (`Pipeline/pending decisions.md` vs the legacy `Context/pipeline - pending decisions.md` — target pinned by the append-target resolution rule, `claude/commands/check-in.md`; in the knowledge store) via `mcp__obsidian-builtin__vault_append`, and folds a count into the Step 6 summary; `/check-in` disposes (re-mint by hand, nudge the judge, or close the tracker).

**Run for each governed board** (via the board adapter — `board_item_list <board>`, or a raw `gh issue list -R "$repo"` when this checkout doesn't vendor the adapter) — boards 3, 4, and 7 (the kernel tracker). Probes 1–3 are **per-board**; probe 4 is **once per run** (it reads a host-wide telemetry stream, not a board). Each detects its own fault and touches nothing:

1. **Missing mint** — a build-closed epic with **no** `Retro-for-epic:`-markered tracker. **Scope to epics with an archived plan note** (a `Plans-archive/<…>.md` snapshot exists — i.e. 4d-archive ran, so `/build` drove that epic to close): for each such epic #<n>, probe for its tracker (`gh issue list -R "$repo" --search "Retro-for-epic: #<n> in:body" --state all --json number`, or `issue_marker_probe` where the corpus lib is vendored — the same body-marker probe the mint's step 1 uses). A zero result means the mint never fired for a `/build`-closed epic (the mint was gated off at close, or the step errored) — report it. Scoping to archived-plan epics is what keeps this from flagging every hand-closed or triage-culled epic that was never a `/build`-driven close.
2. **Stale `retro-pending`** — a `retro-pending` tracker still **open** past a staleness bound (`gh issue list -R "$repo" --label retro-pending --state open --json number,createdAt`): flag any tracker older than `RETRO_MIN_INTERVAL` (`workflows/scripts/build/build.config.sh` — one judge cadence). A tracker still `retro-pending` and open well past one cadence means the overlay `/retro` judge isn't picking it up (its cron is down, or absent) — report it.
3. **Open `retro-judged`** — a `retro-judged` tracker still **open** (`gh issue list -R "$repo" --label retro-judged --state open --json number`). The judge relabels `retro-pending`→`retro-judged` and closes a tracker it has processed; a `retro-judged` tracker left open means that close step was missed — report it.
4. **Judge triggered but never ran** (temperloop#1150) — run `workflows/scripts/build/pipeline-retro-health.sh --format json` **once for the whole run** (read-only, no network, always exits 0; the verdict is its `status` field, never the exit code). It reads the pipeline wake stream's retro actions against the overlay `retro-runs` stream and returns one of five statuses. Dispose by status, and **do not re-derive its judgment** — this probe reports what the script found: <!-- cite: T.21 incident:K#1150 -->
   - `healthy` / `no-signal` / `no-lake` → **silence.** `no-signal` is the point of the probe: it is the load-bearing distinction between *"no retros were due"* (fine) and *"the stream has never had a row"* (not fine), which a zero-row rollup alone cannot tell apart — the ambiguity that hid a dead judge for months. `no-lake` means the trigger history is unreadable here (a checkout with no pipeline lake), which is unknown, not a fault to report.
   - `refused` → report **only** when `.skips["headless-unsupported"] > 0`: an installed `/retro` that does not declare the `headless-unattended` capability, so the tick is correctly refusing to spawn it. Append one `### open` entry naming the count and the script's own `detail` (which carries the remedy). A `refused` run whose skips are all `not-declared` is the expected kernel-only-checkout state — silence.
   - `defect` → **always report**, and this one is a **defect signal, not a pending decision**: the trigger fired and produced nothing. File it via the board adapter's `capture` (§ Capture at source in the kernel doc — this is exactly the "working around a broken thing" trigger), quoting `.judge_actions`, `.defect_kind` (`never-had-a-row` vs `stalled`), and `.detail`; then also append the `### open` entry so `/check-in` sees it. Skip if an open board item already names this fault — don't re-file it nightly.

**Default to silence.** A board with none of the four faults surfaces nothing (a kernel-only checkout with no `/retro` judge mints only terminal `retro-info` trackers, so probes 2 and 3 never match there). Skip an epic/tracker already recorded under an existing `open` entry (match on board + issue number) — don't re-append the same finding every run. This sweep never creates, closes, or relabels a tracker and never edits an epic — the same report-only stance as § Stale board claims and § Provenance-less epics above.

### Self-correction moments → Mistakes / Patterns + recurring-tell promotion

**A drain-internal detector** (like § Contradiction detection and § Recurrence → promotion below) — it surfaces a class the capture rules don't capture and has **no capture anchor it backstops, no Capture/Backstop registry row, and needs no `validate-capture-backstop.sh` change**. The signal is a **mid-session self-correction**: the assistant catching itself going the wrong way — a "that didn't go right" or "I'm thinking about this wrong" / "wrong approach" / "let me reconsider" / "I had this backwards" realization narrated mid-task. This is the moment *before* a Mistake fully crystallises — the model noticed its own error in flight — and it is almost always **assistant-narrated**, so the user-only lexicon never saw it. The `self-correction` tells in `workflows/scripts/drain/lexicon-assistant.tsv` (foundation #501) are scanned against **assistant** turns and pre-matched into `report.lexicon_matches[]` with `category: "self-correction"` and `role: "assistant"`.

**Adjudicate `report.lexicon_matches[]` for `category: "self-correction"` matches.** For each:

1. **Read the match + ±1 context.** A genuine self-correction is a real reasoning reversal — the model recognised a wrong assumption, layer, or approach and changed course. Skip an incidental phrase (quoting the rule, a hypothetical) — apply the same liberal-but-not-noisy judgment as the `lexicon_matches` adjudication rule. Also skim `report.user_turns[]` for self-correction language the lexicon missed (a user-flagged "you're thinking about this wrong" is a **Feedback memory**, not this pass — route it there).
2. **Route the accepted realization:**
   - If the self-correction names a **reusable recovery** (how the model got *unstuck* — "stepped back and re-read the contract first", "checked ground truth before re-deriving") → **Patterns** (vault `Patterns/`, provenance schema). This is the positive learning: the correction worked.
   - If it names a **pitfall worth recording** (the wrong assumption itself — "assumed closing the issue moves the board item; it does not, the Done write is explicit") → **Mistakes** (vault `Mistakes/`, provenance schema), deduping against existing notes exactly as the § Mistakes step does.
   - If the realization is too thin to warrant a note on its own (a one-off course-correction with no general lesson) → record it only as a findings record (below) so it still counts toward recurrence.
3. **Emit a findings record** (§ Findings records) for each adjudicated self-correction with `finding_type: mistake` (the routing target) or `finding_type: pattern` as routed above. If the match came from a `self-correction` tell, provenance is `lexicon-hit` with `sub_method` = the tell; if the model caught it from `user_turns[]` with no tell, it is `model-skim` → it also feeds **§ Candidate-tells accumulation**, the mechanism that grows the lexicon.

**Feeding recurring ones into the lexicon — the promotion path.** This pass deliberately reuses the existing growth machinery rather than adding a new one (subtraction over mechanism):

- **Model-skim self-corrections** (the lexicon missed them) append to the candidate-tells surface (`Pipeline/candidate tells.md` vs the legacy `Context/pipeline - candidate tells.md` — target pinned by the append-target resolution rule, `claude/commands/check-in.md`) via § Candidate-tells accumulation — each proposes a concrete new `self-correction` tell for `lexicon-assistant.tsv`, reviewed and promoted at `check-in`. This is how a **recurring** self-correction phrasing the lexicon doesn't yet catch becomes a permanent tell so future sessions detect it.
- **Recurring self-corrections as a class** are picked up by § Recurrence → promotion: because each accepted self-correction is a `mistake`/`pattern` findings record, the trailing-14-day tally already counts them, and crossing the ≥5 threshold raises a promotion task (tighten a guard rule or elevate a pattern). No new tally is needed.

**Default to silence.** Most stubs surface no genuine self-correction. Do not manufacture one from routine "let me check X" narration — only a real reasoning reversal qualifies.

### Un-disconfirmed diagnoses

Backstop for the live "Disconfirm a root-cause diagnosis before institutionalizing it" rule in `claude/CLAUDE.md` § Fix the real problem, not the symptom. The capture rule says: before propagating a root-cause diagnosis (filing an issue on it, baking a warning into a spec or worker prompts, fanning a fix across sites), run the cheapest direct disconfirming probe the diagnosis makes available. This step catches the ones that skipped it — a diagnosis institutionalized on confidence alone, then either later disproved or never cheap-checked at all (the #1090 incident: a false "SwiftLint autocorrect build phase rewrites files mid-build" root cause baked into an issue + ~15 worker prompts for ~9.5h until a one-line `pbxproj` grep, available at diagnosis time, disproved it).

**Adjudicate — anchor on the structural institutionalization signal first.** The highest-cost, structurally-visible institutionalization is a **filed issue**, so lead there: walk `report.tool_events.capture_calls[]` (the same structural pass § Unfiled defects dedups against) and, for each filing whose body asserts a **root cause**, check the transcript for a **cheap disconfirming probe run before the filing** — a grep of the file the theory names, an "is X installed / present" probe, a read of the config the mechanism assumes. A root-cause-derived filing with **no such probe on record** is the core signature. Then, **secondarily and lower-confidence** — the scan report exposes no `Edit`/`Write` events, so these channels are skim-only, not structurally anchored — skim `report.user_turns[]` and the assistant turns for the capture rule's other two institutionalization channels (a causal warning propagated into a spec / plan note / worker prompt; a fix fanned across multiple sites), applying the same before-it-shipped disconfirming-probe test. The tell throughout is the pairing: a confident causal claim propagated as fact with **no seconds-long falsification attempt on record**. **Skip a diagnosis that WAS disconfirmed** (the probe ran and the theory survived) — that is the rule working, not a miss.

**No lexicon tell — deliberate (guards against the #1137 false-positive class).** Unlike § Self-correction moments, this sweep is anchored on the structural institutionalization signal (`capture_calls[]`) plus judgment, **not** a phrase tell, and it does **not** propose new tells to § Candidate-tells accumulation. A bare causal-claim phrase ("the root cause is", "this is caused by") is low-precision — it fires on every *correct* diagnosis too — so promoting it into `lexicon-assistant.tsv` (a high-precision-only file) would manufacture exactly the false-positive storm foundation#1137 tracks. The signature is the *pairing* (claim + institutionalization + no disconfirmation), which no single phrase carries.

**Dedup against § Self-correction moments (runs earlier this pass).** A diagnosis that was institutionalized *and then reversed later in the same transcript* satisfies both this sweep and § Self-correction moments ("I had this backwards"). Before emitting, check whether § Self-correction moments already adjudicated this same incident this run: if so, emit **one** findings record only and **one** Mistakes note — keep this sweep's framing when the incident's cost was the *propagation* (an issue others acted on, a warning baked into many prompts), else defer to Self-correction's recovery framing — so the shared § Recurrence → promotion tally counts the incident once, not twice.

For each accepted case:

1. **Emit a findings record** (§ Findings records) with `finding_type: mistake`, so it feeds the trailing-14-day recurrence tally.
2. **Route a durable lesson to Mistakes** (vault `Mistakes/`, provenance schema) when the case names a recurring *class* of premature diagnosis (a build-phase theory, an env/tooling assumption, a "the framework does X" causal guess), deduping against existing notes exactly as the § Mistakes step does. A one-off with no general lesson stays a findings record only.
3. **Recurrence promotion is automatic** — because each accepted case is a `mistake` findings record, § Recurrence → promotion already counts it; crossing the threshold raises a promotion task to tighten the guard (e.g. a sharper live tell, or a required-probe checklist for a diagnosis class). No new tally.

**Default to silence.** Most sessions institutionalize nothing, or disconfirm before they do. Do **not** manufacture a finding from a diagnosis that was appropriately cheap-checked, from a hypothesis explored and dropped without being propagated, or from ordinary "I think X is the cause, let me verify" narration that then *did* verify.

### Unfiled defects

Backstop for the live "Capture at source / Capture, don't ask" rule in `stageFind/CLAUDE.md` § Task workflow. The capture rule says: when a defect is noticed mid-work and not fixed now, file it immediately via `scripts/capture.sh` rather than offering and waiting. This step catches the ones that slipped — typically an end-of-session "want me to file this?" that the user never answered, or a "side observation" that was only ever spoken.

Distinct from **Mistakes** (which captures the *lesson* in the vault): this captures the *unfixed defect itself* on the **worklist** (board / GitHub issue), because a vault note records rationale but is not a tracker — see the `stageFind/CLAUDE.md` "Defect vs enhancement routing" convention.

**Adjudicate `report.lexicon_matches[]` for defect-category tells** (categories: `defect-language`, `capture-miss`, or similar — check `report.lexicon_matches[].category`). **Include the `worked-around-defect` category** — these are the assistant-turn tells (`role: "assistant"`, from `lexicon-assistant.tsv`, foundation #444): a defect the *assistant itself* narrated routing around mid-task ("this is broken, let me work around it", "fall back to X because Y fails") and may never have filed. They are the highest-signal Unfiled-defect candidates precisely because the workaround makes the bug invisible — the #443 pattern (worked around twice, never filed). **Also fold in any recurring `soft` error from `report.tool_events.errors[]`** (per the tool-errors pass above) — a silently-failed tool is the same blind spot from the other direction. **Before filing, consult the `capture_calls` structural pass output above** — any defect whose keywords appear in a `capture_calls[].command` entry was already filed at source by the live "Capture at source" rule; cross-reference to avoid duplicates. Finally, skim `report.user_turns[]` for defect-shaped language the lexicon may have missed (novel phrasing, implicit observations). The canonical tell phrases are maintained in `workflows/scripts/drain/lexicon.tsv` (user turns) and `workflows/scripts/drain/lexicon-assistant.tsv` (assistant turns); the inline list below is illustrative only:

> "side observation", "out of scope (for my PR)", "worth flagging", "worth a follow-up", "candidate for a follow-up issue", "follow-up issue/item", "I'll just note it", "leave it (alone/here)", "not acted on", "gap in #N", "untracked", "not registered / not wired / not threaded / not consumed", "stale reference/comment", "doesn't fire / doesn't persist / never registered", "that's a bug", "want me to file …?" (especially if the *next* user turn changed topic or ended the session).

For each candidate:

1. **Classify by the routing predicate.** Apply the **defect-vs-enhancement routing predicate** — canonical statement: stageFind project `CLAUDE.md` § Task workflow → "Defect vs enhancement routing". Route per that predicate; do not restate it here. A **defect** → worklist (continue below); an **enhancement / deferred design seam** → not a defect, so capture it as a `Decisions/`/`Context/` note per the Decisions step instead, and move on.
2. **Dedup against the worklist, not Things.** Check for an existing GitHub issue (`gh issue list --state all --search "<keywords>"`) **and** a board item (project 3 stageFind, project 4 foundation). If either covers it, skip — live capture worked.
3. **Verify it's still live.** If the defect was since fixed (grep the repo / `git log`), do not file; note it as "self-resolved" in the summary.
4. **File it** via `scripts/capture.sh "<title>" --body "<one-line context + Sessions/<stub> provenance>" --label bug [--board 3|4]` (board 4 for foundation-tooling defects). Capture the issue number for the summary.
   - If the defect is **rework** — redoing or correcting prior work — add `--rework <regression|spec-miss|flake>` to the same `capture.sh` call so the cause is captured at filing time (F#730). This is a human-filing convention applied by whoever runs this step, not an automated real-time extraction rule, so it deliberately has no Capture/Backstop registry-table pair.

**Default to silence.** If a stub's defects were all filed live (the common case once "Capture, don't ask" is in force), surface nothing. Do **not** route a real defect to the Things inbox — Things is for personal/triage tasks, the board is the canonical worklist for defects.

### Stale board claims

Backstop for the live "Board hygiene is part of the gate" / "Park, don't abandon" rules in `claude/CLAUDE.md` § Task workflow, and for build's per-run Step 0.5 self-claim recovery. Those catch the *single-run* case; nothing periodically sweeps the board **across sessions** for claims a dead run stranded In Progress (bugs **and** epics — both carry a real `Host/Session` stamp; the epic stamp lands at `build.md` Step 3a). A 2026-06-04/05 session found two epics stranded In-Progress for days under dead sessions (GH #85). This sweep is the periodic net. <!-- cite: T.12 incident:F#85 -->

**Run the status reconcile for each governed board** (via the board adapter's `reconcile`, on PATH from `make install-board` in the foundation fleet; if `reconcile` isn't on PATH — as in a standalone kernel checkout, which ships no `install-board` target — fall back to `workflows/scripts/board/reconcile.sh`, else skip this step with a one-line note):

```
reconcile --status --board 3
reconcile --status --board 4
```

Each run is read-only (one cached-bypassed board resolve + two flat-cost REST list reads — no per-item read burst). Collect the lines under three sections of its output:

- **`stale claims`** — In Progress, stamped to a **dead same-host session** (its Claude transcript is absent or untouched beyond `reconcile.sh`'s own `RECONCILE_STALE_AFTER_SECS` cutoff). The drain machine *can* verify these — they are the release candidates. **They are also the `--claims` lens's strip candidates** (see the **Dead-session claim-stamp sweep** paragraph further down this same section): the *release* stays report-only, the *owner stamp* is auto-cleared unless an open PR holds it. Two different actions on the same population, with two different dispositions.
- **`orphaned In-Progress`** — In Progress with an **empty** owner stamp (a half-landed claim, GH #103). Also release candidates.
- **`foreign claims`** — In Progress on **another host**, whose liveness can't be checked from here. **Report-only, never released from this machine** — the owning host catches them on its own next drain.

**Report-only, never auto-release — and "release" is exactly what that covers.** This command is unattended — there is no operator to confirm a release — so it mirrors `reconcile`'s own report-only stance (surface stale/orphan/foreign claims; **move none**). The ratified default governs **moving an item back to Ready**, nothing narrower: it does *not* govern the owner stamp, which the `--claims` sweep below now clears on its own (temperloop#2069). **Report only** — list every candidate in the Step 6 summary and park nothing (default = **leave all**). A claim left In Progress is a harmless lock; a wrongly-released active claim is not. **This is an `ask-at-checkin` deferral** ([[Context/foundation - AskUserQuestion severity taxonomy]]) — no live operator, a safe default — so don't *silently* default: when any same-host stale/orphan candidate exists, record the auto-taken default to the **pending-decisions surface** (`claude/CLAUDE.md` § Unattended pending-decisions surface) so the next `check-in` reviews it. Append one `### open` entry to the pending-decisions surface (`Pipeline/pending decisions.md` vs the legacy `Context/pipeline - pending decisions.md` — target pinned by the append-target resolution rule of the path fallback convention, `claude/commands/check-in.md` — in the knowledge store) via `mcp__obsidian-builtin__vault_append`:
  ```markdown
  ### <YYYY-MM-DD HH:MM> · tidy stale-claim sweep · <host>:<sess8>
  - **Decision:** return same-host stale/orphan claims to Ready (board <N>: #<n>, …)
  - **Default taken:** leave all (report-only; parked nothing)
  - **Disposition:** auto-taken (unattended/--force-now; no live operator)
  - **Status:** open
  ```
- **Foreign claims** are *always* report-only — list them in the summary as "verify on `<host>`".

The current draining session's own claims self-exclude (their transcript mtime is current), so this never releases live work — including any item this very session is holding.

**Dead-session claim-stamp sweep — AUTO-APPLIED, and NOT an override of the report-only default above (temperloop#2069).** The same board set carries a *fourth* reconcile lens, and it is the one **board-side** repair this step applies rather than reports (the tmux-marker sweep below is local, the label-hygiene sweep after it is label-object cruft):

```
reconcile --claims --board 3 --unattended
reconcile --claims --board 4 --unattended
reconcile --claims --board 7 --unattended
```

For an item that is **In Progress** whose `fnd:host/session:*` stamp names a **same-host session proved dead** (transcript absent, or untouched beyond `RECONCILE_STALE_AFTER_SECS`), it strips **that one label and nothing else**. `fnd:status:in-progress` is left byte-identical, the issue is never closed, and the Status is **never moved to Ready**. A **foreign-host** stamp is never stripped (liveness is uncheckable from here) and stays in its own report-only bucket; a **live** same-host session's claim — including this very drain's own — self-excludes because its transcript mtime is current. Every candidate is reported **with its staleness age**, on the report path and the apply path alike, so a four-day-dead stamp reads differently from one that has only just crossed the cutoff.

**The open-PR carve-out — this NARROWS the auto-clear disposition, it does not reverse it.** A dead-session candidate that an **open PR** would close is **reported, never stripped**: its work is already delivered and parked `[m]` at the merge gate, so its claim is one `claude/CLAUDE.md` § Task workflow → **"Claim held until Done"** (K#275) declares *sanctioned*, not drift. Stripping it would also fail silently — `board_claim_contended()` opens `[ -n "$existing" ] || return 1`, so once the stamp is gone contention reports "not contended" and the next claim overwrites the owner with no warning at all. Candidates with **no** open PR still auto-clear exactly as above: that is the genuinely-dead-and-unfinished case the disposition was decided for, and it still covers both motivating epics (temperloop#1938 and temperloop#1910 are *parents* — the PRs belong to their members). The open-PR read is a **failure path, not a happy path**: if it errors, or its result cannot be established at all, **every** candidate is reported rather than stripped — an unknown PR state is never the permissive branch. The sweep prints three report-only buckets alongside the strip list (`held by an OPEN PR`, `open-PR state UNESTABLISHED`, `foreign claims`), so a candidate it deliberately left alone never reads as one it merely skipped.

**Why this is not a reversal of "report-only, never auto-release".** That default protects a cross-session lock whose wrongful *release* costs another session its work — it is about **moving an item to Ready**. Clearing only the owner stamp is a strictly smaller action the ratification never considered: it **asserts nothing about the work** (In Progress survives, which is correct for a genuinely unfinished epic whose driver simply died), it **restores claimability**, which is the actual harm (`claim.sh` refuses a foreign-owned claim, so a dead stamp makes a live epic unclaimable and makes its open sub-issues read as someone else's in-flight work), and it is **recoverable by one `claim.sh`** — the same bar the terminal-marker and label-hygiene sweeps around it already clear. The report-only loop also demonstrably does not converge: two kernel epics (temperloop#1938, temperloop#1910) were filed at 2 days stale and were still standing at **four days** when this disposition was decided. The full fork and its rejected alternatives are recorded in the knowledge store at `Decisions/temperloop - dead-session claim stamps are auto-cleared, status untouched`.

Each strip is preceded by an immediate fresh re-read of that one issue (never the scan's snapshot) requiring it to be still open, still carrying that exact stamp, and still In Progress — so a re-claim, a park, or a close landing between scan and apply is refused, not destroyed — and a second run reports zero candidates (idempotent). Like the label-hygiene sweep below, `--unattended` on this lens **records its own** `### open` pending-decision entry via `workflows/scripts/lib/knowledge_store.sh`'s `ks_append` — carrying the cleared count **and** the held and unestablished-PR-state counts as three separate numbers — and it records one when the unestablished count is non-zero even if it cleared nothing. Fold its `applied: cleared N dead-session claim stamp(s)…` / `In sync…` line into the Step 6 summary **and, when present, the `not stripped by design: H held by an open PR, U with an unestablished PR state.` line that follows it** (it follows the `Nothing to strip: …` verdict too, on the run where every candidate was held back); do **not** append a second entry yourself. **Never sum `H` and `U` in the summary** — `H` is a designed refusal that clears itself on the merge cascade, while `U` is a *read failure*: a `U` that stays non-zero night after night means the open-PR read is failing for this host, every candidate is landing in the unestablished bucket, and the sweep has degraded to inert behind a green exit code — surface that to the operator rather than letting it hide inside a combined total. **Capture/Backstop classification:** accumulated board *state*, not an author action a capture rule could capture at source — so, like the two sweeps around it, it reuses the existing "Stale board-claim sweep" registry row rather than registering a new pair.

**Stale tmux claim-marker sweep — the one AUTO-APPLIED repair here.** The same reconcile command carries a *third* drift class the status lens above does not reach: the local tmux `@claimed_issue` marker that paints the operator's `status-right` claim chip. Nothing clears a marker on session death, issue close, or merge — `release.sh` is a manual, same-window call that `claude/CLAUDE.md` § Task workflow explicitly makes *optional and best-effort*, and the close→Done cascade never reaches tmux — so a marker outlives its work indefinitely and the status bar asserts a claim that does not exist (temperloop#1037: one closed issue's marker branded all four windows of a session for over a month). A repair the operator must *notice* is no repair at all for drift that is by definition unnoticed, which is why it runs here, unattended:

```
reconcile --board 3 --fix
reconcile --board 4 --fix
```

**This one auto-applies rather than reporting** — the opposite disposition from the *release* half of the stale-board-claim sweep above (though it now shares its disposition with that sweep's stamp-clearing half), and for a reason worth being explicit about: the repair held back up there is releasing a board claim, a cross-session lock whose wrongful release costs another session its work. This one's is clearing a status-bar chip whose backing issue is **provably CLOSED or MERGED on GitHub** — no board state, no claim stamp, and no work is touched, and `claim.sh` restores the chip. `reconcile.sh` applies the proof itself and refuses anything short of it (an OPEN issue, an unreadable state, a live same-host claim on *any* registered board), so there is no judgment left here for an absent operator to make. It needs no pending-decision entry for the same reason.

Fold each run's `✓ cleared […]` / `NOT repaired` / `nothing to repair` lines into the Step 6 summary. The sweep works from **outside** tmux (it addresses the tmux server, not the caller's environment), so the nightly reaches the operator's windows; with no tmux server running it reports nothing and costs nothing. If `reconcile` isn't on PATH, use `workflows/scripts/board/reconcile.sh` exactly as the stale-claim sweep above does, else skip with a one-line note. **Capture/Backstop classification:** this is accumulated terminal *state*, not an author action a capture rule could capture at source, so — like the board LABEL hygiene sweep below — it reuses the existing "Stale board-claim sweep" registry row rather than registering a new pair.

**Board LABEL hygiene.** A DIFFERENT drift class on the same board set: every board rides item state on `fnd:`-namespaced repo labels (see `workflows/scripts/board/ISSUES-ONLY-BACKEND.md`), and several label classes accumulate cruft nothing else sweeps — an orphaned `fnd:host/session:*` repo label (a claim stamp left behind after its issue closed or was re-claimed), a stale `fnd:status:*` label left on an issue that later closed (a PR's `Closes #N` closes the issue without stripping its status label), and a **stranded `fnd:host/session:*` stamp still worn by a CLOSED issue** (temperloop#744 — that issue then reads as permanently claimed to `issue-state.sh resolve`; the orphaned-label class above structurally cannot reach it while any OPEN issue still wears the same stamp, so it needs its own per-issue strip). This is board LABEL drift, not the marker/claim drift the status reconcile above catches — it belongs here, not in the filesystem-scoped § Environment hygiene step below (that step's role/checkout model has no meaning for a repo's own tracker labels). **Capture/Backstop classification:** the stale `fnd:status:*` half backstops this SAME pair's capture rule (`claude/CLAUDE.md` § Board hygiene is part of the gate) — specifically its bare `Closes #N` path, which closes an issue without ever routing through `board_set_status`'s Done-path strip — while the orphaned `fnd:host/session:*` half is pure accumulated-state probing (the byproduct `lib/board.sh`'s own ~L1015 comment foresaw, with no live action to backstop); hence this reuses the existing "Stale board-claim sweep" registry row rather than registering a new Capture/Backstop pair. <!-- cite: T.13 guard:workflows/scripts/board/reconcile.sh -->

Run the SAME `reconcile` adapter with `--labels --unattended` for the same board set, plus board 7 (a board with no `fnd:` labels to sweep reports "nothing to sweep", harmlessly):

```
reconcile --labels --board 3 --unattended
reconcile --labels --board 4 --unattended
reconcile --labels --board 7 --unattended
```

Like the dead-session claim-stamp sweep above, and unlike the report-only *release* half of the stale-claim sweep, this sweep's **ratified unattended default is apply** (`--unattended` on this lens forces the delete/strip, it does not merely report) — a deleted `fnd:` label object is trivially recoverable with one `gh label create`, so auto-applying under no live operator is safe by design; see `reconcile.sh`'s own § Lens 3 header comment for the full rationale. Every delete/strip is preceded by an immediate re-check (a fresh read, not the initial scan's snapshot) so a claim or status write landing between scan and apply is never destroyed, and a second run against the post-apply state reports zero changes (idempotent).

**The pending-decision append is automatic — this step does NOT do it.** Unlike every other `ask-at-checkin` deferral in this file, `reconcile --labels --unattended` records its own auto-taken apply (the counts deleted/stripped/cleared) to the pending-decisions surface itself, via `workflows/scripts/lib/knowledge_store.sh`'s `ks_append` (script-plane, not the agent-plane `mcp__obsidian-builtin__vault_append` every other site here uses) — best-effort: a missing/unavailable knowledge store degrades to a stderr notice and never fails the sweep. Just fold each run's "applied: deleted N label(s), stripped M status label(s)[, cleared K claim stamp(s)]." line (or "nothing to sweep" / "In sync…") into the Step 6 summary; do not append a second pending-decision entry for this sweep yourself.

### Unlinked fix PRs

Backstop for the live "Route a conversational fix request through /fix" rule in `claude/CLAUDE.md` § Route a conversational fix request through /fix. A conversational fix driven ad hoc in a live session, bypassing `/fix`, leaves a recoverable trace: a merged or open PR with no issue-closing keyword behind it — `/fix` always emits a bare `Closes #<issue>` (from its `ghIssue:` item field, `claude/commands/fix.md` § 4a), so a PR with no such linkage is the tell that something bypassed the flow. (The bypass *also* skips claim-first board hygiene, but that half is **not recoverable at drain time** — a closed issue's claim marker, an `fnd:status:*` label on an issues-only board or the In-Progress Status on a Projects board, is cleared on close, leaving issue-linkage as the only durable post-hoc signal. This sweep detects that half; it does not attempt to reconstruct claim history.) **If a project's own reconcile/tidy tooling already owns this exact class** (a merged/open-PR-vs-issue-linkage sweep), delegate to it by name here instead of duplicating; as of this writing no such check exists in this kernel (`workflows/scripts/board/reconcile.sh` covers claim/label drift, not PR-issue linkage), so this sweep is the first owner of the class. <!-- cite: T.14 class:backticked-closes-no-linkage -->

**Run for each board-enabled repo this checkout governs** (the boards in `board_registered_boards` — matching the capture rule's board-enabled scope; a boardless checkout has no claim-first gate for `/fix` to bypass, so the sweep does not apply there):

```bash
gh pr list -R "$repo" --state merged --limit 50 --json number,title,url,body,mergedAt,headRefName
gh pr list -R "$repo" --state open   --json number,title,url,body,updatedAt,headRefName
```

For each PR, check linkage two ways, in order: (a) GitHub's own parsed linkage — `gh pr view <n> -R "$repo" --json closingIssuesReferences` — the authoritative signal, since it reflects a bare `Closes #N` GitHub actually recognized, not just body text; (b) a cross-repo `Closes owner/repo#N` line in the body (§ Cross-repo closes) when (a) is empty. A **backticked** or prose-embedded `Closes #N` that GitHub silently ignored (the known `/build` 3f failure mode, § Issue linkage) does **not** count as linkage — flag that PR the same as one with no mention at all.

- **Merged, no linkage** — a merged PR with empty `closingIssuesReferences` and no valid cross-repo `Closes` line. Exclude a PR whose title/body is self-evidently a refactor/chore/doc change with no pre-existing tracker (§ Issue linkage's own carve-out — the same judgment call `/build` 3f already makes); when genuinely unsure, include it rather than guess it away.
- **Open, no linkage, and idle** — an open PR with empty `closingIssuesReferences`/no valid cross-repo `Closes` line, and no recent activity (a judgment call, not a fixed setting — on the order of two weeks untouched by commit or comment, a PR that has sat long enough to read as abandoned rather than mid-review; report-only and inclusion-biased, so an exact cadence is deliberately unfixed).

**Report-only, never auto-file or auto-close.** Mirrors the § Stale board claims sweep's posture: list every candidate in the Step 6 summary and take no action — the change may have been an intentional, correctly-invoked trivial-change escape hatch (the capture rule's own carve-out), not a bypass. This is a **`ask-at-checkin` deferral** ([[Context/foundation - AskUserQuestion severity taxonomy]]) — append one `### open` entry to the pending-decisions surface (`Pipeline/pending decisions.md` vs the legacy `Context/pipeline - pending decisions.md` — target pinned by the append-target resolution rule of the path fallback convention, `claude/commands/check-in.md` — in the knowledge store) via `mcp__obsidian-builtin__vault_append`, only when at least one candidate surfaces:

```markdown
### <YYYY-MM-DD HH:MM> · tidy unlinked-fix-PR sweep · <repo>
- **Decision:** review candidate PR(s) for a conversational fix that bypassed /fix (merged-no-linkage: #A, #B; open-idle-no-linkage: #C)
- **Default taken:** leave all (report-only; no issue filed, no PR touched, no label changed)
- **Disposition:** auto-taken (unattended/--force-now; no live operator)
- **Status:** open
```

**Default to silence.** If no candidates surface for a repo, emit nothing for it — no pending-decision entry, no Step 6 line — the common case once `/fix` adoption is in force.

### Ready-but-unmerged PRs

The **readiness-keyed** backstop half of the orphaned-PR net (temperloop#721). A complete PR — checks green, mergeable, non-draft — can sit unmerged indefinitely and nothing else notices: `/fix` guards only the PRs its own flow produced, the § Unlinked fix PRs sweep above keys on issue-linkage + idleness (not readiness), and the merge queue makes enqueue ≠ merged — a PR enqueued and then dropped by the queue is exactly the orphan this sweep resurfaces (classified like any other open PR; no special casing). **A drain-internal probe, not a capture/backstop pair** — modeled on § Environment hygiene below: it probes accumulated *external* state (the open-PR set across the governed repos), not an author action a capture rule captures, so it has **no capture anchor it backstops, no Capture/Backstop registry row, and needs no `validate-capture-backstop.sh` change**.

**Run the probe**, both formats — `report` for the per-PR classification this step reasons over, `entry` for the ready-to-append block:

```
workflows/scripts/ready-pr-sweep.sh --format report
workflows/scripts/ready-pr-sweep.sh --format entry
```

The script (its usage header carries the full contract) enumerates every repo in `board_registered_boards`/`board_repo` — never a hardcoded repo list — and classifies each open PR from plain `gh pr list` + `statusCheckRollup` (PRs are not board items, so this never routes through the board adapter at all): **ready** (required checks green + `mergeStateStatus` CLEAN — an enqueue candidate), **needs-rebase** (BEHIND/DIRTY), **needs-attention** (failing or pending checks, or any other not-ready state — inclusion-biased), **not-yet-computed** (`mergeStateStatus` still read UNKNOWN after a bounded retry — GitHub computes it asynchronously, so UNKNOWN means "not computed yet", not a problem; temperloop#1504 — a single un-retried read is what made the SAME PR flip between `needs-attention` and `ready` on back-to-back sweeps, so this is its own class with no prescribed action, and it is **not** a `--format entry` candidate since it resolves on its own on a later sweep), **stale-draft** (a draft idle for `READY_PR_SWEEP_STALE_DRAFT_DAYS` or more — a draft can never enqueue, so one nobody flips ready is structurally unable to land; this is its own named class precisely because folding it into `skip` hid three such PRs for weeks, temperloop#1180), **skip** (a *recent* draft — an in-flight draft is a legitimate state — or a DO-NOT-MERGE marker in the title). Both formats are **read-only and fail-open**: the script never merges, enqueues, rebases, closes, or comments on a PR, and one repo erroring never aborts the sweep (a checkout without the script no-ops, so this is safe to run unconditionally).

**Report-only — auto-enqueue of the ready class is explicitly OUT of scope** (a later autonomy layer; per `claude/CLAUDE.md` § Merge autonomy & consent, a merge is never driven from an unattended drain). This is a **`ask-at-checkin` deferral** ([[Context/foundation - AskUserQuestion severity taxonomy]]): when the `entry` command printed a block (at least one ready/needs-rebase/needs-attention/stale-draft candidate — skip-class PRs never trigger it), append it verbatim as one `### open` entry to the pending-decisions surface (`Pipeline/pending decisions.md` vs the legacy `Context/pipeline - pending decisions.md` — target pinned by the append-target resolution rule of the path fallback convention, `claude/commands/check-in.md`; in the knowledge store) via `mcp__obsidian-builtin__vault_append` — `/check-in` disposes (enqueue the ready ones via `pr-enqueue`, flip a stale draft ready with `gh pr ready` or close it, rebase or investigate the rest, or dismiss). Note the per-class counts in the Step 6 summary.

**Default to silence.** Zero candidates → the `entry` command prints nothing; append no entry and emit just one Step 6 summary line (`ready-PR sweep: clean`).

### Vault hygiene

A periodic **detect-and-propose** probe for the knowledge-store vault. Nothing else alarms on hygiene drift — `/tidy` curates *on touch* (provenance audit, contradiction detection) but never *sweeps* the vault, so a silent pile-up (162 `Sessions/_inbox` stubs / 18 MB before anyone noticed — foundation #958/#959) goes unseen until it is large. This step runs a standalone probe each drain and records any drift to a review surface for `check-in` to dispose of. <!-- cite: T.15 incident:F#958 -->

**A drain-internal detector**, not a capture/backstop pair (like § Contradiction detection, § Self-correction detector, and § Recurrence → promotion): it backstops **no live extraction rule** — hygiene drift is a *state* the vault accumulates over time, not an author action a capture rule captures — so it has **no capture anchor it backstops, no Capture/Backstop registry row, and needs no `validate-capture-backstop.sh` change**. It **proposes**; `check-in`'s `## Vault hygiene review` section is the **sole mutator** that disposes (the same drain-proposes / check-in-disposes split as § Pending decisions surface). Drain **never** bulk-deletes vault content.

**Run the probe** (a kernel script that reads the store via the script-plane `plain-files` backend — `KNOWLEDGE_STORE_ROOT` (see `workflows/scripts/lib/knowledge_store.contract.md` for the default); a checkout with no vault prints one line and no-ops, so this is safe to run unconditionally):

```
workflows/scripts/drain/vault_hygiene_report.sh --format entry
```

It checks two families of drift. **Housekeeping**: `Sessions/_inbox` stub count + oldest age (alarm above `INBOX_MAX_STUBS` stubs or `INBOX_MAX_AGE_H` hours); closed plans (`status: done|complete|abandoned`) still resident in `Plans/` (should be archived + removed); named ledgers over their line cap; zero-byte / double-dot / stray-absolute-path garbage files; and a stale-`last_verified` tally (informational). **Structural** (temperloop#230, ADR §2.2): a top-level store folder outside the ADR §2.2 allowlist; a directory holding a single file outside the ADR schema's known nested substructure (one-file-directory); a note filename that doesn't match the `<project> - <title>` convention (naming drift); a `Plans/` note with status `draft`/`approved` untouched for an extended window (stale plan); and a dated or verdict-shaped title sitting in `Patterns/` (kind-misfile heuristic — usually really a Decision/Investigation). `Personal/` is exempt from every check above, structural or housekeeping. With `--format entry` it prints a ready-to-append `### <ts> · vault hygiene · <host>` block carrying **Status: open** **iff** something alarmed, and prints **nothing** when the vault is clean. **Class roll-up:** because that block lands in a note that accretes nightly, a class with more than `CLASS_ROLLUP_THRESHOLD` per-finding lines in one run collapses to a single `CLASS ROLL-UP` line carrying how many lines were rolled up plus one example, instead of inlining every hit. Two things the roll-up never does: it never deletes a **class-summary** line (a running total, a cap notice, the `duplicate-overlap` "N not shown" line below — each passes through verbatim and is never counted toward the roll-up), and it never presents its number as an alarm count — the number is a line count and is labelled as one. The default `report` format is an ad-hoc terminal read rather than an accreting note, and is never rolled up.

**Knowledge-store maintenance scans (foundation#1479).** Two further propose-only checks cover drift classes the "compiled wiki" layer accumulates silently. **`duplicate-overlap`** flags pairs of notes across `Decisions/`, `Patterns/`, `Mistakes/`, `Context/` whose *titles* share `DUP_OVERLAP_MIN` or more distinct terms — two pages on one concept that should merge or cross-link. It reuses the tokenizer and distinct-token counter `check_repeat_mistake` already ships (no new similarity engine), and builds an **inverted token→notes index** rather than comparing note pairs: a pairwise scan would be the same O(n²) whole-vault cost foundation#1202 removed, and worse here. Terms appearing in more than `DUP_TOKEN_MAX_NOTES` notes are skipped as non-discriminative. The listed pairs are capped, with an explicit "N not shown" line so a capped list never reads as the whole list. **`orphan-note`** reports notes with **no inbound wikilink anywhere in the store and no `Index.md` entry** — reachable only by search. It is **informational, never an ALARM** (the same posture as the stale-`last_verified` tally and the heat score), and that is a *measured* choice, not caution: on the vault it was built against, **560 of 744 notes (75%)** have no inbound link, so a per-note alarm would flag three quarters of the corpus nightly and bury the checks that do alarm. The **rate** is the signal — it says the wikilink graph is not this store's retrieval substrate — so the check emits one tally line plus a capped sample. It is distinct from `orphan-pattern` above, and neither subsumes the other: `orphan-pattern` asks whether a `Patterns/` note is reachable from the **composed CLAUDE.md's own T0 rules** (a routing question, answered against the T0 inventory); `orphan-note` asks whether **any** knowledge note is reachable by link-following at all (a graph question, answered against the backlink index).

**Both reuse one memoized backlink index** (`_hyg_all_files` / `_hyg_link_index`) rather than rebuilding per check — so the whole-vault walk and the wikilink tally happen **once** and serve the heat score, the orphan scan, and the duplicate scan together. This is why foundation#1202 (the one-pass index) was a prerequisite for these scans rather than an unrelated performance fix: adding them on the former per-note grep would have multiplied a probe that already blocked the nightly drain. Measured: the two checks added no material runtime (119s with them, 121s without).

**The third drift class — contradictory claims across notes — is already covered** and is deliberately *not* rebuilt here: § Contradiction detection (cross-session supersession proposer) in this same Step 3 is that pass, and it proposes supersessions to its own review surface.

**Read-log telemetry (temperloop#238).** The probe also tallies the knowledge-store read log (`KNOWLEDGE_READ_LOG`) — both the script-plane emitter (`ks__read_log_emit`) and the agent-plane PostToolUse hook (`claude/hooks/ks-agent-read-log.sh`) append the same normalized line, so this tally covers both planes with no special-casing — into four **informational** lines (never an ALARM, same posture as the stale-`last_verified` tally above): `reads/session`, the `most-read` note, `never-read` notes (store notes with no logged `op=read` line, same recursive-walk + `Personal/` exemption as every other check), and `search→read conversion` (the fraction of `op=search` lines followed, later in the same session, by an `op=read`). **Surface choice, documented per temperloop#238's own note:** this checkout carries no `claude/commands/telemetry.md`, and the rollup-backed rich renderer (`workflows/scripts/build_telemetry_brief.py`) is an **overlay**-only script — a kernel-only checkout has neither of those two specifically (a kernel-side brief renderer *does* now exist — `workflows/scripts/telemetry-brief.sh`, temperloop#431, rendered unconditionally by `check-in.md` Part 1 — but it reads the raw-lake streams and the read log's per-line data directly, not this tally; see `check-in.md` Part 1 and `docs/architecture.md`'s telemetry-lake read-side note). So the read-stats lines are wired into *this* report/review surface only — the same `Pipeline/vault hygiene report.md` surface every other finding in this step uses — rather than a kernel-side `/telemetry` file that doesn't exist here. A composed install's `/telemetry` renderer (or the `telemetry` skill) quotes these lines straight from that surface once it reads it; no second write path is needed.

**Heat score + review queue (temperloop#240, ADR §2.6-2.7).** The probe also computes a per-note **heat** score for every note in `Decisions/`, `Patterns/`, `Mistakes/`, `Context/`, and `Plans/` — a simple, documented weighted combination (default weights 3/2/1) of telemetry reads (from the same read log the paragraph above tallies), inbound wikilink count (a grep-based backlink count from every other store note), and a recency-of-verification score (linearly decayed over 180 days from `last_verified` frontmatter, or file mtime when absent). This is **informational only, never an ALARM**, and — like every other finding in this step — **nothing is ever auto-evicted on heat**; it is a discovery aid, not a deletion trigger. It appends a **top-5 review queue**, ranked by heat × staleness (days since `last_verified`/mtime) and capped at 5 by construction, folding in the orphan-pattern, stale-plan, and repeat-mistake flags already raised earlier in the same run as a `[tag]` annotation on any queue entry those checks also flagged. With no read-log data yet, it degrades to a links + recency ranking with no error; with no candidate notes at all (a bare kernel checkout) it reports "0 candidate notes" and emits no queue.

**Record the finding — replace, don't append.** Unlike the identity-keyed skip in § Provenance-less epics / § Retro mint backstop above (an epic or tracker either recurs or it doesn't, so a match is a pure duplicate to skip), this probe emits a **full-state snapshot** every run — every alarm, tally, and heat-ranked queue entry recomputed fresh, not a delta — so an identity-keyed skip would still append a "new" finding every night purely because the snapshot's content drifts run to run (observed: 207 lines on 2026-07-25, 209 on 2026-07-24 — 1101 lines total and climbing ~200/night). The fix has to be structural: **replace the drain's own prior `### … · vault hygiene · <host>` `open` block with this run's block instead of appending a new one.** Read the vault-hygiene review surface (`Pipeline/vault hygiene report.md` vs the legacy `Context/pipeline - vault hygiene report.md` — target pinned by the append-target resolution rule of the path fallback convention, `claude/commands/check-in.md`; in the knowledge store) via `Read` on the resolved file path. **A read error is not the same as a confirmed-absent note — never conflate them.** If the read fails (the tool errors — as opposed to succeeding with empty/no-such-note content), **abort the replace and report-only**: fall back to a plain `vault_append` of this run's block (or, if even that is unavailable, just note the failure in the Step 6 summary) rather than risking a `vault_write` that reconstructs the file from nothing and silently discards its real accumulated content (resolved history, or an actually-still-open entry this run's session simply failed to see). Only on a **successful** read do you branch on content: if it contains a `### … · vault hygiene · <host>` block whose `Status:` line still reads `open` (the drain's own most recent, still-undisposed proposal), drop that whole block and splice in this run's block in its place; if the read succeeded and no such `open` block is present (confirmed — first run, or the prior one was already disposed by `check-in`), just add this run's block to the note. **Perform the replace as a full-file `vault_write` rewrite of the entire note — never a `vault_patch` against the found block's heading.** A heading-targeted `vault_patch` is the documented mid-file silent-corruption failure mode (returns OK, corrupts the note — `claude/CLAUDE.md` § `vault_patch` safe-targeting contract), and unlike a stable named `::`-path heading, the block being replaced here is a dated, per-run heading with no fixed path to target safely. The replace touches **only the drain's own `open` block** — it never rewrites a `resolved` entry elsewhere in the note and never edits a `Status:` line itself, so `check-in` remains the sole mutator of `Status` and the drain-proposes / check-in-disposes split holds exactly as it does for every other finding in this note. **Confirm the write** with a follow-up `Read` before considering the step done — the same confirm-then-trust discipline `check-in.md` already applies to its own full-file rewrites — since a `vault_write` misfire here is a whole-note loss, not a single mid-file corruption. If the command printed nothing, the vault is clean: **surface nothing** and move on (default to silence) — leave any existing `open` block untouched (a clean run doesn't retract a still-undisposed prior finding). Note the one deliberate non-suppression: once `check-in` disposes an `open` block (e.g. marks it `dismissed: …`) while the underlying condition (an over-cap `_inbox`, say) is still true, the very next drain's probe re-alarms and this rule adds a **fresh** `open` block — replace only dedupes *consecutive undisposed* runs, it does not suppress a dismissed-but-still-real alarm from resurfacing; this is intentional, not a gap to "fix" later.

**This step does NOT** delete or move any vault file, does NOT mutate an entry's `Status` (check-in is the sole mutator, per its review section), and does NOT prune ledgers or archive plans. It only *reports* the drift; every disposal — deleting garbage, pruning a ledger, archiving a closed plan, moving a misfiled note — happens at `check-in` on operator confirmation.

**Auto-heal (`--heal`) is NOT passed by this step.** The probe supports one mechanically-safe auto-heal class — folder naming-case normalization (a top-level folder whose name is a case-only mismatch of an ADR §2.2 allowed name) plus the wikilink retarget that goes with it — but `/tidy` invokes it in its default report-only mode, matching the drain-proposes / check-in-disposes split every other finding in this step follows. An operator (or a future, explicitly-scoped step) may run the probe with `--heal` by hand; every other finding — including every structural lint above — stays propose-only regardless, since none of it is mechanically unambiguous the way a folder case fix is.

### Environment hygiene

A periodic **detect-and-propose** probe for the local filesystem environment — checkouts, worktrees, background-job scratch, and launchd agents — the sibling of § Vault hygiene above for the *host* rather than the *vault* (temperloop#168/#176/#177). Nothing else periodically sweeps this state across sessions: `build`'s own Step 0.5 recovers only the current run's stranded claims, and a leaked worktree or a cron checkout that silently drifted behind `main` otherwise goes unseen until someone trips over it. <!-- cite: T.16 guard:workflows/scripts/build/env-reconcile.sh -->

**This step is the home of the job-scratch retention backstop (temperloop#1111).** `/build` gives each worker its own worktree, and each Swift worker its own DerivedData path, so parallel `xcodebuild` runs don't collide — correct isolation, but nothing reclaimed the scratch when the job ended. Two finished job dirs accumulated 38.5GB of DerivedData trees and eval corpora and took the root volume to **0 bytes free**, hard enough that the harness's own Bash tool could not allocate a command's output file — which blocks *diagnosing* the problem, not merely doing work. Every retained byte was regenerable (DerivedData rebuilds; eval corpora reindex). The reclamation lives here rather than at `/build` level close because a level-close purge would need a worker→job-dir mapping the kernel does not own (the job directory is the harness's, created outside any kernel code path), so it would silently miss exactly the jobs it failed to map — the same invisible-leak shape this closes. A sweep keyed on the job's own terminal state needs no mapping and degrades to a no-op rather than to a silent miss.

**A drain-internal detector**, not a capture/backstop pair: like § Vault hygiene, it backstops no live extraction rule — environment drift is a *state* the host accumulates over time (a leaked worktree, a checkout that fell behind), not an author action a capture rule captures — so it has **no capture anchor it backstops, no Capture/Backstop registry row, and needs no `validate-capture-backstop.sh` change**.

**Policy: aggressive in-lane, report cross-lane.** This step may auto-fix drift only in checkouts that are structurally nobody's interactive home — a disposable worktree, or a **cron/kernel checkout** (role-defined as always clean-on-main; `foundation.cron`, the kernel checkout, `foundation-kernel`). It never mutates a **foreign** checkout's `HEAD` — an **operator/consumer checkout** (`foundation`, `stageFind`, `ssmobile`, `subsetwiki`) may legitimately be another session's active lane, and per `claude/CLAUDE.md` § Working-tree ownership only the session that owns a checkout may move its `HEAD`. This mirrors that rule exactly: report, never switch.

**Run the probe**, both formats — `report` to get the full per-checkout classification this step reasons over, `entry` for the ready-to-append block:

```
workflows/scripts/build/env-reconcile.sh --format report
workflows/scripts/env-hygiene-report.sh --format entry
```

(`env-hygiene-report.sh` is a thin passthrough wrapper over `env-reconcile.sh --format entry` — either invocation is equivalent for the `entry` form; a checkout with neither script present no-ops, so this is safe to run unconditionally.) Both are **read-only and fail-open**: they never `git fetch`, `launchctl load/unload`, or write a file themselves — this step's own subsequent auto-heal actions (below) are what mutate.

**Also sweep the command-run open ledger** — `bash workflows/scripts/validate-command-run-reconcile.sh` over this host's own lake (temperloop#2220 — stable command-run id). It reports a `/sweep`, `/triage` or `/fix` run that opened a ledger marker and then emitted **no record at all**, which is the only trace a silently-stopped run leaves. It lives here and **deliberately not in `scripts/quality-gates.sh`**: the lake is mutable per-host state no diff produces, so one abandoned `emitted=0` marker — a killed session, a crashed run, exactly what the ledger exists to record — would turn the merge gate red for every later PR and every `/build` item on that host, with an undocumented manual `rm` as the only remedy. A stale-marker report is environment hygiene, so this is its natural home; the hermetic fixture suite that proves the guard itself works stays gated. **Report-only, never auto-healed:** a marker is another run's trace, so append its `MISSING-RUN` / `UNREDUCIBLE` lines verbatim to the review surface below and let a human dispose them. A non-zero exit whose output is a `CANNOT EVALUATE` line is a broken probe, not drift — file it per § Unfiled defects. Absent script (a non-vendoring checkout) → skip silently.

For each drift class the `report` output surfaces, dispose as follows:

- **Auto-heal (safe, in-lane):**
  - **`LEAKED_WORKTREE`** (any of `ORPHANED`/`BRANCH_GONE`/`MERGED`/`CLOSED`) — **and ONLY this class; never `DIRTY_WORKTREE` or `UNCERTAIN_WORKTREE`, whose reason field looks identical** — under *either* a cron or an operator parent repo's `<repo>.wt/`: `git -C <parent-repo> worktree remove <wt-path>` then `git worktree prune`. **Run the removal WITHOUT `--force`, and never escalate to `--force`, `rm -rf`, or a retry when it refuses** — plain `git worktree remove` refuses a worktree with uncommitted changes, and that refusal is the last safety belt under the classifier: report the refusal to the review surface below and leave the directory alone. Removal is safe under any parent *only because the tree is confirmed clean*: `env-reconcile.sh` emits `LEAKED_WORKTREE` exclusively for a worktree whose `git status --porcelain` is empty, and a worktree is never a session's launch dir (`claude/CLAUDE.md` § Working-tree ownership), so removing it touches no peer session's `HEAD`. If the worktree's **actual** branch (`git -C <parent-repo> worktree list --porcelain`, never a `build/<slug>` guess — temperloop#658) still exists and is independently confirmed merged, delete it too (`git -C <parent-repo> branch -D <actual-branch>`) — mirrors `worktree.sh`'s own cleanup. <!-- cite: T.26 incident:K#658 -->
  - **`HARNESS_WORKTREE:STALE`** — and **ONLY** that reason; never `STALE_DIRTY`, `STALE_UNCERTAIN`, or `ACTIVE`, whose token prefix looks identical (temperloop#1405). A Claude Code agent worktree (`isolation: "worktree"`) under `<checkout>/.claude/worktrees/agent-<id>`, past the staleness horizon and confirmed clean. Nothing reaps these and their leftover `worktree-agent-<id>` branches accumulate invisibly behind them, so the finding line carries the exact removal command — directory **and**, when the branch is **confirmed merged**, the branch. **The branch half is gated, not assumed:** an unmerged or indeterminate branch is deliberately KEPT, the remedy says so inline, and the directory is still reclaimed — because `git branch -D` is a *force* delete that bypasses git's own not-fully-merged refusal, and this remedy is run **verbatim, unattended**. That is the same never-destroy-on-an-unestablished-verdict rule the `STALE_DIRTY` / `STALE_UNCERTAIN` bullet below applies to uncommitted work, extended to commits. Run *that* command, without `--force`, and treat a refusal exactly as above: report it, leave the directory alone. `ACTIVE` is not drift at all — a live agent may still be working in it — and is never counted or acted on.
  - **`BEHIND_MAIN`** on a cron/kernel checkout — fast-forward it: `git -C <repo> pull --ff-only`. Only when that same checkout classified *clean* (no `DIRTY`/`ON_BRANCH` alongside it) — `env-reconcile.sh` only ever emits `BEHIND_MAIN` for a checkout already confirmed on-default-branch, so this is the normal case. `--ff-only` refuses if the local ref isn't a strict ancestor, so this can never discard work.
  - **Merged local branches in a cron/kernel checkout** — run `scripts/prune-merged-branches.sh --apply` from that checkout. Safe: it only ever deletes a branch `git branch -d` itself confirms fully merged, and a cron/kernel checkout is never expected to carry extra local branches.
  - **`JOB_SCRATCH_RECLAIMABLE`** — run `workflows/scripts/build/job-scratch-reclaim.sh --apply`. In-lane by the same reasoning as a leaked worktree: a *terminal* job's `tmp/` is structurally nobody's live state, and its contents are 100% regenerable. The reclaimer re-derives the classification from the same `lib/job-scratch.sh` this probe used (so detector and reclaimer can never disagree), keeps the run **record** (`state.json`, `timeline.jsonl`), deletes only `<root>/<id>/tmp`, re-verifies that path against the resolved job root immediately before removing it, never follows a symlinked `tmp/`, and refuses `$HOME` or `/` as a sweep root. It is dry-run without `--apply`, and exits 0 on an absent job root.
- **Report-only (cross-lane / risky) — append to the review surface, touch nothing:**
  - **`DIRTY_WORKTREE:<reason>`** — a worktree that WOULD be leaked by its reason but carries uncommitted work (`git status --porcelain` non-empty in it). **Never remove it, forced or otherwise, and never `rm -rf` it**: the false-positive that destroyed a peer's uncommitted work (temperloop#658) was exactly a removal justified by a leak reason. Report it; a human decides whether the work is wanted.
  - **`HARNESS_WORKTREE:STALE_DIRTY`** / **`HARNESS_WORKTREE:STALE_UNCERTAIN`** — a stale harness agent worktree carrying uncommitted work, or one whose cleanliness could not be probed. Same rule as `DIRTY_WORKTREE`/`UNCERTAIN_WORKTREE` below: report it, never remove it. An agent worktree's unsaved bytes are worth no less than a session's.
  - **`UNCERTAIN_WORKTREE:<reason>`** — the classification could not be *established* (detached HEAD / unresolvable branch, or the cleanliness probe could not run). Report it. `git worktree prune` is still safe on the parent (it only drops admin records for directories that are already gone); removing a directory on an undetermined verdict is not.
  - **`PARKED_ON_MERGED`**, **`DIRTY`**, **`STALE_UNTRACKED`** on an **operator/consumer checkout** — this is exactly the working-tree-ownership foreign-lane case; never `git checkout`/`reset`/`clean` there.
  - **`DIRTY`** or **`ON_BRANCH`** on a cron/kernel checkout — surprising for a role defined as always clean-on-main (a live run may be mid-flight there); report, don't touch.
  - **`AGENT_UNLOADED`** / **`AGENT_STALE`** — never `launchctl load`/`unload` from this step; restarting or reloading an agent out from under a possibly-still-running process is exactly the kind of foreign mutation this policy exists to avoid.
  - **`JOB_SCRATCH_ABANDONED`** — big scratch under a job that is **not** terminal, or whose state cannot be read at all. Never auto-reclaimed: a non-terminal job can still resume (a `blocked` job is waiting on an operator answer and continues afterwards), and deleting a live run's scratch mid-flight is a strictly worse failure than leaving bytes on disk. Report it with its size so a human can dispose it; the same reasoning as never `launchctl`-reloading an agent out from under a running process.
  - **`ABSENT`** / **`NOT_A_REPO`** / **`MALFORMED_PLIST`** — configuration problems with nothing safe to mechanically fix; report.

**Record the finding.** If the `entry`-format command printed a block, append it verbatim to the environment-hygiene surface (`Pipeline/environment hygiene report.md` vs the legacy `Context/pipeline - environment hygiene report.md` — target pinned by the append-target resolution rule of the path fallback convention, `claude/commands/check-in.md`; in the knowledge store) via `mcp__obsidian-builtin__vault_append` — it creates the note if absent (at the path that rule selects for creation); this is a new pipeline surface parallel to the pending-decisions and sensitivity-flags surfaces, consumed by `/check-in`. Prepend one line per auto-heal action actually taken (`- auto-healed: <action> — <path>`) so the surface shows what was fixed alongside what's being reported. If the probe printed nothing (clean) and no auto-heal ran, **surface nothing** and move on (default to silence).

**File a board defect for a real misconfig** — a `BEHIND_MAIN` that `--ff-only` refused (true divergence, not a simple fast-forward), a `MALFORMED_PLIST`, an `AGENT_UNLOADED`/`AGENT_STALE` that recurs across drain runs, or an `ABSENT`/`NOT_A_REPO` checkout that should exist — via `workflows/scripts/board/capture.sh "<title>" --body "<one-line context>" --label bug [--board 3|4|--repo kernel]` (kernel-domain machinery routes `--repo kernel` per the kernel-vs-overlay routing rule; dedup against an existing issue first, same as § Unfiled defects). A drift class with a safe auto-heal (worktree prune, ff-pull, merged-branch delete, job-scratch reclaim) is not a "real misconfig" on its own — only file when the auto-heal itself failed or the drift is a class this step never auto-fixes. A `JOB_SCRATCH_ABANDONED` that recurs across drain runs *is* worth filing: it means a job is stuck non-terminal while holding real disk.

**This step never mutates a foreign checkout's `HEAD`** — verified against a fixture with a foreign parked-on-merged operator checkout: reported to the surface above, never `git checkout`ed or reset. It also never `launchctl load/unload`s an agent, and never deletes anything outside a confirmed-merged branch, a confirmed-leaked worktree, or a terminal job's regenerable `tmp/` scratch.

**Class-C activation soak-poll.** This step doubles as the drain-side poll for `/check-in`'s class-C **pending-activations** discharge (`claude/commands/check-in.md` § Pending-activations ledger, per the activation-completeness contract — `[[Decisions/temperloop - Activation-completeness contract]]`) — it lives here, not a new probe, because the launchd sub-case reuses this same section's `AGENT_STALE`/`AGENT_UNLOADED` classification. Read the ledger (`Pipeline/pending activations.md`, falling back to the legacy `Context/pipeline - pending activations.md` per the path fallback convention, `claude/commands/check-in.md`) via `Read` on the resolved file path. For each `### … - **Status:** open` entry with `class: C` whose `soak-until` has elapsed (a poll before `soak-until` is a no-op, not a check):

- **Launchd sub-case** (no `soak_check:` field): source `env-reconcile.sh` with no args (safe — populates `LAUNCHD_DIRS` and defines functions without running the reconciler, per its own doc header), then call the now-sourced `agent_status_by_label "<locus label>"`. Empty output → the agent fired within its declared cadence → discharge: patch the entry's `Status` line to `discharged — <timestamp observed>` via a direct `Edit` (this step is one of the two sanctioned `status:` mutators per `check-in.md`, alongside `/check-in` itself). `AGENT_STALE:<label>` or `AGENT_UNLOADED:<label>`, or exit 1 (no plist declares that label — unverifiable) → leave the record `open`; this is the same `AGENT_STALE`/`AGENT_UNLOADED` drift class already handled above, so a record still open across multiple drain runs gets the same recurrence-triggered board-defect filing, not a per-run one.
- **Data-accumulation sub-case** (`soak_check:` present): evaluate the command directly (`Bash`). Exit `0` → discharge with the same `Edit` pattern. Non-zero → leave `open`, no report needed unless it recurs.
- **No derivable predicate** (neither `soak_check:` nor a `locus` `agent_status_by_label` can resolve): never auto-discharge — leave `open`. `/check-in`'s own gate is where this gets surfaced to the operator; this drain poll's job is only to catch a discharge `/check-in` hasn't gotten to yet, never to substitute its judgment.

A ledger with no open class-C records past their window is a no-op — surface nothing. A discharge here is silent to the drain summary (the ledger itself is the durable record `/check-in` reviews); only a recurring `AGENT_STALE`/`AGENT_UNLOADED` or a record with no derivable predicate needs the operator's attention, and both already have their own surfacing path above.

### Toolkit provenance

A periodic **detect-and-propose** probe for one question the other hygiene steps never ask: is the toolkit code this host is *running* the release it claims to be? (temperloop#1047, ADR 0021/0022.) The two unprompted notices this feature ships — the session-start hook and the subtree-edit guard's re-probe — both fire only when somebody is *in a session*. A modified checkout on a host nobody has started a session on stays invisible indefinitely, and the design's own silent-fork metric (what fraction of modified checkouts end reconciled versus neither) has no collection point at all without a periodic reader. This step is that reader.

**A drain-internal detector**, not a capture/backstop pair — exactly like § Vault hygiene and § Environment hygiene above. A modified toolkit tree is accumulated *state*, not an author action a capture rule captures, so it backstops **no live extraction rule**, needs **no Capture/Backstop registry row**, and requires **no `validate-capture-backstop.sh` change**.

**Run the probe**, both formats — `report` for the verdict and attribution this step reasons over, `entry` for the ready-to-append block:

```
workflows/scripts/toolkit-provenance.sh --format report
workflows/scripts/toolkit-provenance.sh --format entry
```

Both are **read-only, network-free and fail-open**: the probe writes nothing anywhere (the whole mechanism persists no state by design), never fetches, and always exits 0. A checkout with no release baseline — the kernel's own development checkout, or any tree that is neither a vendoring consumer nor the managed clone — answers `UNKNOWN`, and `--format entry` prints nothing there, so this is safe to run unconditionally.

Dispose by verdict:

- **`RELEASED`** — surface nothing. The common case.
- **`UNKNOWN`** — surface nothing. A missing baseline is not a finding; the probe is telling you it cannot answer, which is its correct behaviour in a kernel checkout and is never an alarm.
- **`MODIFIED`** — an **`ask-at-checkin` deferral** ([[Context/foundation - AskUserQuestion severity taxonomy]]). Append the `entry`-format block verbatim as one `### open` entry to the pending-decisions surface (`Pipeline/pending decisions.md` vs the legacy `Context/pipeline - pending decisions.md` — target pinned by the append-target resolution rule of the path fallback convention, `claude/commands/check-in.md`; in the knowledge store) via `mcp__obsidian-builtin__vault_append`. `/check-in` disposes: upstream the change, restore the released content, or dismiss it as a deliberate in-flight fast-lane edit.

**Never auto-reconcile.** This step never restores a file, never reverts a commit, never opens a PR, and never sets `KERNEL_EDIT_ACK`. A modified toolkit tree is frequently a *deliberate* state (the sanctioned fast-lane path — `docs/features/toolkit-provenance.md`), and mechanically undoing an operator's live edit would destroy exactly the work the mechanism exists to make visible. Report; the operator decides. This is the same report-never-mutate posture § Environment hygiene applies to a foreign checkout's `HEAD`, for the same reason.

**Recurrence is the signal worth escalating, not a single run.** One `MODIFIED` run is ordinary. The *same* checkout reporting `MODIFIED` across many consecutive drains — with no `Upstream:` reference on its committed drift, so nothing suggests it is in flight — is a silent fork: file a board defect for it via `workflows/scripts/board/capture.sh "<title>" --body "<one-line context>" --label bug --repo kernel` (dedup against an existing issue first, same as § Unfiled defects), rather than letting it re-surface silently every night.

**Default to silence.** A `RELEASED` or `UNKNOWN` verdict emits no entry and no Step 6 line.

### Generated navigation (Index + Project Home MOCs)

A **detect-and-generate** step, the sibling of § Vault hygiene and § Environment hygiene above (temperloop#231, epic #226 "generated navigation"). Design intent (epic #226 ADR §2.1): project-first browsing of the vault is served **virtually**, by regeneration from signals already present in the store, never by hand-curating a nav page. `Index.md` (top-level) and `Projects/<name>/Home.md` (one per detected project) are the two generated MOCs; both are content **/tidy owns**, not the operator — a hand-edit to either is never reflected back and is never silently destroyed (see the refuse-and-propose behavior below). <!-- cite: T.17 guard:workflows/scripts/drain/generate_moc.sh -->

**Like § Vault hygiene and § Environment hygiene, this is a drain-internal step, not a capture/backstop pair** — no capture rule captures project navigation by hand (the whole point is that nothing should), so it has **no capture anchor it backstops, no Capture/Backstop registry row, and needs no `validate-capture-backstop.sh` change**.

**Run the generator** (a kernel script that resolves the store root via the script-plane `knowledge_store.sh` seam — never a hardcoded vault path; a checkout with no store, or a store with zero detected projects, prints one line and no-ops, so this is safe to run unconditionally):

```
workflows/scripts/drain/generate_moc.sh --format entry
```

**Detection** (both signals feed the same project namespace; a note counts if either matches): a **filename prefix** `<project> - <title>.md` (the vault's own `<project> - <short title>.md` naming convention, applied uniformly across `Decisions/`, `Patterns/`, `Mistakes/`, `Context/` — note this deliberately excludes the unrelated `<date> <project> - <title>.md` `Plans/` convention, whose leading token is a date+space, not a bare project slug), or a **`project/<name>` frontmatter tag** anywhere in the note's YAML block.

**What it writes, when projects are detected:**
- `Index.md` — links every detected project's `Projects/<name>/Home.md`, with a note count.
- `Projects/<name>/Home.md` — lists every note associated with that project (union of both signals).

Both carry a do-not-hand-edit banner as their first line, and both regenerate **idempotently** — an unchanged store produces byte-identical output run to run (no timestamp or run-specific data is embedded in the generated content itself).

**No hand-curated content lost (refuse-and-propose).** Before overwriting a target, the generator checks for its own banner as the target's first line. If the target already exists **without** it — hand-authored content, or content pre-dating this generator — the script **refuses to overwrite it** and reports a conflict instead; it never destroys hand-written content. This is the same propose/dispose idiom as § Vault hygiene and § Environment hygiene: `--format entry` prints a ready-to-append `### … Status: open` block **iff** a conflict was found (nothing when clean).

**Record the finding.** If the command printed a block (a conflict was found), append it verbatim to `Context/pipeline - moc generation conflicts.md` (in the knowledge store) via `mcp__obsidian-builtin__vault_append` — it creates the note if absent; a new pipeline surface parallel to the vault-hygiene and environment-hygiene ones, consumed by `/check-in`. Skip a conflict already recorded by a prior sweep (match on the conflicting target path — `Index.md` or `Projects/<name>/Home.md` — under an existing `open` entry) — don't re-append the same finding every run: unlike § Vault hygiene above, a refuse-and-propose conflict is identity-keyed on a fixed target path rather than a drifting full-state snapshot, so the same skip-on-match idiom § Provenance-less epics and § Retro mint backstop use applies here unchanged. If the command printed nothing (every target was either freshly written or already carried the generator's banner), **surface nothing** and move on (default to silence).

**This step does NOT** touch any note outside `Index.md` / `Projects/<name>/Home.md`, does NOT mutate an entry's `Status` (check-in is the sole mutator), and does NOT ever overwrite a hand-authored target — the operator resolves a reported conflict at `check-in` (typically by deleting or renaming the stray hand-written file so the next `/tidy` run can generate cleanly in its place).

### Pending decisions surface

Backstop for the capture rule in `claude/CLAUDE.md` § Unattended pending-decisions surface. The capture rule says: when an `ask-at-checkin` question (`build` Step 1.5, `build` Step 4b queue-stall, `assess` Step 6, this command's stale-claim sweep, `sweep` Step 2 leave-all-flagged, `sweep` Step 1 item 6 mixed-class-epic refusal, `sweep` Step 3.6A fully-drained-epic-left-open) is deferred on an **unattended / mini / cron** run, the run takes its safe default AND appends an `### open` entry to the pending-decisions surface (`Pipeline/pending decisions.md` vs the legacy `Context/pipeline - pending decisions.md` — target pinned by the append-target resolution rule, `claude/commands/check-in.md`; in the knowledge store) so the next `check-in` reviews it. This step catches the ones that slipped — an unattended run that defaulted a deferrable decision but never wrote the entry (so `check-in` would never surface it).

Check `report.lexicon_matches[]` for pending-decision tells (categories such as `ask-at-checkin`, `deferral`, or similar) and skim `report.user_turns[]` for an **unattended/`--force-now`/cron** batch-pipeline run that hit one of the seven `ask-at-checkin` sites and took its default. Also check `report.tool_events.ask_user_questions[]` — unanswered questions (`answer: null`) in a run that was unattended are the clearest signal. High-signal tells: an assistant turn running `build … --unattended` (skipped the Step 1.5 prompt, "work all"), a `build` native-merge-queue stall that dequeued-and-fell-back without surfacing (Step 4b, unattended), `assess` arming or declining the approval poll under `--unattended`, a `sweep` unattended run that left clarifying questions flagged-and-skipped (Step 2), a `sweep` unattended run that refused a mixed-class Operational/Foundational epic's members without surfacing it (Step 1 item 6), a `sweep` unattended run that left a fully-drained Operational epic's parent open without recording the pending-decision entry (Step 3.6A), or this command's own `--force-now` stale-claim sweep reporting candidates without parking.

For each such defaulted decision:

1. **Check the surface.** Read `Pipeline/pending decisions.md`; if that read fails (file absent), fall back to the legacy `Context/pipeline - pending decisions.md` (path fallback convention, `claude/commands/check-in.md`) — via `Read` on the resolved file path. If an entry already covers this run's decision, skip — live capture worked. **Match on site + run-id / date by default — except when the decision names an epic number** (currently only `sweep` Step 3.6A's fully-drained-epic-left-open site): that site's own capture dedups on "epic #E anywhere in this surface's WHOLE history, not just this run" (one entry per epic EVER — `sweep.md` § Step 3.6A item 4's `left-open-unattended` branch), so the backstop must match the SAME way — search the surface's whole history for `epic #E` in any existing entry's Decision line (`open` or already disposed), not just this run's site+date. A site+date-scoped backstop match would backfill a duplicate entry for an epic the live capture already correctly recorded on a prior run, violating the one-per-epic-ever invariant the capture guarantees.
2. **Backfill the missing entry.** If absent, append one `### open` entry in the note's format (Decision + Default taken + Disposition + Status: open) via `mcp__obsidian-builtin__vault_append` — targeting the path Step 1's read resolved, or, when neither file existed, the path the append-target resolution rule (`claude/commands/check-in.md`) selects for creation — with Disposition noting it was backfilled by `/tidy` from `Sessions/<stub>`. This re-arms the `check-in` review the live write would have triggered.
3. **Default to silence.** If every unattended run's deferrals were recorded live (the common case), surface nothing.

Distinct from **Stale board claims** above (which reconciles board *state*): this reconciles the *decision audit trail* — that a defaulted ask-at-checkin choice is visible to the operator at the next check-in rather than silently standing.

### Session optimization tools

Skim `report.user_turns[]` and `report.lexicon_matches[]` (categories: `optimization`, `session-tool`, or similar) for assistant or user turns where a new optimization tool, command, flag, or technique was introduced — slash commands the user hadn't used before, MCP tool patterns, hook tricks, telemetry queries, configuration moves that materially reduce friction. For each candidate:

- Fetch `Patterns/Session optimization toolkit.md` via `Read` on the resolved file path. If a section with the same name already exists, skip — live capture worked, or this drain run already covered it.
- If novel, append a new `## <name>` section via `mcp__obsidian__append_to_vault_file` with `**What:**`, `**When to use:**`, and `**Source:**` lines. Source: `[[Sessions/<stub filename without .md>]] — <one-line context>`.
- Default to silence — most stubs surface nothing new.

This is a backstop for the live `Session optimization tracking` rule in `claude/CLAUDE.md`. If the file doesn't exist yet (no live captures have happened), create it via `mcp__obsidian__create_vault_file` with the heading + first entry.

### Tooling friction (fewer-steps)

Backstop for the capture rule in `claude/CLAUDE.md` § Tooling friction capture. The signal is narrow on purpose: the session reached its outcome in **more steps than it needed**. **Adjudicate `report.lexicon_matches[]` for friction-category tells** — the relevant lexicon categories are **`friction-slug`** (the exact ledger-slug names, near-zero false-positive but they only fire when the friction was *already* named live) and **`state-collision`** (stale/dirty/conflicting state — `DIRTY`, `commits behind`, `stale local main`, `No commits between`, `now-stale`: the high-recall tells for unrecognized rework, fired on **user *and* assistant** turns), plus **`trust-rupture`** on **user turns only** — its *communication-failure* subset alone, adjudicated by the `clarification-rework` bullet below (§ Feedback memories owns that category's other two subsets; neither step banks what the other routes). Then skim `report.user_turns[]` for friction-shaped narration the lexicon may have missed. Append every genuine instance **not already in the ledger** to the friction ledger (`Context/Session friction ledger.md` in the knowledge store) via `mcp__obsidian-builtin__vault_append`, one row each: `- <YYYY-MM-DD> · <project> · <category> · <one-line evidence>`.

- **Re-checked confirmed state** — `redundant-status-check` / `reverification-backtrack`: `git pull`/`status` right after the session's own push/merge → "already up to date"; re-polling CI/mergeability after `gh pr checks --watch` already exited 0; re-querying state to "confirm" a bug it had already diagnosed; re-reading or re-deriving a file/note it just produced. Verbatim tells: *"already up to date"*, *"wait… contradicts my earlier read"*.
- **Acted before ground truth** — `probe-after-not-before` / `stale-context-rework`: created a PR/branch/file or filed a defect, then found it already existed / the remote had moved / a decision governed it. Tells: *"a PR already exists"*, divergence discovered at `git push`, *"auto-add didn't fire"* before its lag elapsed. **A `state-collision` match is the canonical route here** — most often **branched off a stale local main** (the live *Fetch ground truth before building* rule was skipped): the PR comes back `DIRTY`/conflicted or is **redundant** (`built on stale local main`), and recovery costs a `reset --hard origin/main` + re-branch. This realization is almost always **assistant-narrated** ("local main was 100 commits behind", "I branched stale and created conflicts"), so it lives in the assistant-turn `state-collision` matches, not `report.user_turns[]` — adjudicate those matches, don't wait for a user turn to name it. Log as `stale-context-rework` (or `probe-after-not-before` if the divergence was found *at push* after the branch was already built).
- **Wrong tool contract** — `tool-misuse` (secondary): a vault patch retried on a heading path; an MCP lister that skipped dotfiles; `Edit` on a symlinked file; `search_vault_simple` where `_smart` was meant.
- **Explanation had to be re-asked** — `clarification-rework` (temperloop#1089): the operator spent a turn asking what the assistant had just *said* — and the assistant spent another re-explaining it. That round-trip is an extra step by this section's own measure: the outcome was reachable without it, had the first explanation landed. **Adjudicate the `trust-rupture` matches on `report.user_turns[]`** — tells are *"I don't understand"*, *"what do you mean"*, *"I don't know what `<X>` means"*, *"still don't quite understand"*, *"is jargon"*, *"(dense|hard) to parse"*, *"that doesn't make sense"*. Every row carries the **verbatim** operator line (the `match.line`, unparaphrased) as its evidence — no quote, no row.
  - **Discriminate the three subsets of one lexicon category.** `trust-rupture` also spans a **correctness challenge** (*"are you sure"*, *"I think you're wrong"*, *"solving the wrong problem"*) and a **repeat-offence** (*"again,"*, *"I've told you before"*) — both belong to § Feedback memories, **not** here. Split on *what was doubted*: the **conclusion** → § Feedback memories; **what the assistant just said** → a `clarification-rework` row here. One turn can genuinely be both (*"I don't follow, and I don't think that's right"*) — route it once to each, never twice to one.
  - **False-positive floor — the confusion must be about the assistant's own last message.** A question about the **domain** ("what does this GitHub field mean?", "how does the merge queue work?") is ordinary curiosity, not a communication defect: it asks about the world, and the operator would have asked it however well the assistant wrote. Log a row **only** when the turn refers back into the assistant's preceding turn(s) — a term it introduced, a summary it gave, a recommendation it made — and asks for *that* to be restated or unpacked. If ±1 context leaves you unable to tell which it is, **do not log**: a tally of re-explanations is only worth acting on if every row is one.

A **needed** verification is not friction — a status check that found real changes, a first diagnosis, a required merge gate. A **needed** clarification is not friction either — a domain question, or the operator opening a topic the assistant never addressed. Append only genuinely avoidable steps; default to silence on a clean stub, and specifically: a stub with **no clarification tell** yields **no** `clarification-rework` row.

**Surface frequent stumbles.** After appending, tally the ledger over the trailing **14 days**. If any `category` has **≥5 rows**, surface it in the Step 6 summary as `Friction candidate: <category> (<count> in 14d)` and generate a Step 4 Things task — *Review friction ledger — <category> recurring; file a foundation issue*. `clarification-rework` is counted here exactly like the mechanical categories and is **never special-cased out** of the tally — five re-explanations in two weeks is the signal that a *habit* of the assistant's writing, not one bad message, is costing the operator turns. This is how the most-frequent stumbles become tracked work rather than repeating silently.

**Default to silence.** If a stub yielded no novel learnings (because they were captured live), that is the correct outcome — do not invent extractions to feel productive.

### Knowledge-search parity misses

Backstop for the live **Phase 1 parity comparison rule** in `claude/CLAUDE.overlay.md` —
temporary, removed at Phase 3 (F#956) alongside that rule (F#946/F#947, `Plans/2026-07-04
foundation - obsidian knowledge-store migration`). The capture rule says: while Phase 1 is in
force, every concept-level search (`mcp__obsidian__search_vault_smart`) should also run
`ks_search` (Bash) over the same query and get one comparison line appended to
`Context/foundation - knowledge-search parity ledger.md`. This step catches the ones that
slipped — a `search_vault_smart` call with no corresponding ledger line for that query and day.

**Skip entirely if this checkout has no `claude/CLAUDE.overlay.md`, or that file carries no
"Phase 1 parity comparison rule" section** — a standalone kernel checkout has no such rule to
backstop, and once Phase 3 deletes the rule this step should stop firing too (retire it in the
same change that removes the capture rule).

For each stub in this drain run:

1. **Find candidate concept searches.** Read the stub's raw `.jsonl` transcript (the path in the
   stub frontmatter's `transcript:` field — the same "wider transcript access" reach as Step
   1.4, justified here because no `report.tool_events` sub-array captures generic MCP tool
   invocations) and grep it for `search_vault_smart` tool_use invocations; extract each call's
   `query` argument.
2. **Check the ledger.** Read `Context/foundation - knowledge-search parity ledger.md` via
   `mcp__obsidian-builtin__vault_read`. For each candidate query, look under `## Entries` for a
   line dated the same day as the stub whose query matches (exact string or an obvious
   paraphrase). If found, the capture rule fired — skip this query.
3. **Backfill the miss.** For each query with no matching entry, append one line directly (a
   Bash `>>` append) in the ledger's `- <date> · <query> · smart|bm|tie · <gap note>` format:
   ```
   - <YYYY-MM-DD> · <query> · smart · backfilled by /tidy — ks_search comparison missing from live capture (Sessions/<stub filename without .md>)
   ```
   Default the verdict to `smart` (the only side known to have run) unless the same transcript
   window also shows a `ks_search` Bash invocation for the same query — in that case read both
   results from the transcript context and judge `smart`/`bm`/`tie` honestly instead of
   defaulting.
4. **Tally.** Surface `Knowledge-search parity misses backfilled: N (queries)` in the Step 6
   summary.

**Default to silence.** Most stubs show every concept search already ledgered live (the common
case once the capture rule is in force). Do not manufacture a miss from an ambiguous transcript
read — skip rather than guess.

### Missing grounding citations

Backstop half of the **kernel** pair registered in the table at the top of this file — its capture
half is `claude/CLAUDE.md` § Response-level grounding citations, and this heading is the backstop
anchor that row points at. Both halves are kernel-resident (a stranger's kernel-only checkout has a
knowledge store and therefore the same bypass to detect), so the row belongs in that kernel table
and **not** in `claude/capture-backstop-registry.overlay.md`;
`workflows/scripts/validate-capture-backstop.sh` fails the build if either half goes missing.
(Original motivating write-up: foundation#1478; routing settled kernel-side by temperloop#1190.)

**What the rule requires.** When knowledge-store content materially informed an answer, the
response cites it (`[source: <note path>]`); when a store query behind a context-dependent claim
found nothing, the response says so explicitly ("no relevant knowledge-store content found").
Without response-level citations, **memory bypass is undetectable per-response** — a
context-dependent answer with no citation is indistinguishable from one grounded in retrieved
content, which is the "placebo trap": the retrieval machinery can silently stop contributing and
every answer still *looks* informed. The capture-half section owns the full statement of the rule;
this step only detects breaches of it.

**No new capture surface — read only what the drain already reads.** This scan introduces no
instrumentation of live sessions, no new ledger, no new lexicon tell, and no additional file to
write: its only output is a row on the friction ledger § Tooling friction already maintains, and
its whole input is the **one `Sessions/_inbox/` stub the drain has already opened** — that stub's
Step 1 scan report, its `## Transcript` section (the same file `scan_stub.py` read in Step 1), and
where the turn-level detail is needed, that stub's own raw `.jsonl` at the frontmatter
`transcript:` path: the identical Step 1.4 reach § Knowledge-search parity misses above already
takes. The restriction is on the *source*, not on the depth of the read: never a second stub,
never the knowledge store, never the knowledge-store read log or any other out-of-band record,
never the session's repo — nothing outside that stub's own drained material. If the stub cannot
settle the question, skip (see § Default to silence, and never guess at the end of this section).

**Where the candidates come from — the stub body, not the scan report.** Unlike the tell-driven
extractors above, this check has **no scan-report candidate list to adjudicate**: per
`workflows/scripts/drain/scan-report-schema.md`, `report.user_turns[]` is user-turn-only,
`report.lexicon_matches[]` surfaces assistant turns only for the narrow `worked-around-defect`
category, and neither lexicon carries a citation/grounding tell — so a missing citation can never
appear there. Candidate discovery is therefore a **routine** assistant-turn skim of the stub's own
`## Transcript` section, not the ambiguity-only exception Step 1.4 states for lexicon candidates —
the same sanctioned shape § Spec-authoring damping above already uses when it directs a direct
assistant-turn skim for classes the scan report structurally cannot recover. The scan report is
still read — it supplies the stub's identity and provenance metadata — it simply cannot supply a
candidate, so never wait for a scan-report entry that will not come.

**The spot check.** Skimming those assistant turns, find responses that are plainly
**context-dependent** — they assert a project-specific decision, rationale, path, or convention
that could only have come from the knowledge store (not from the code in front of the session, and
not from general knowledge). For each, check whether the response carries a citation, or the
explicit negative form. Weigh the retrieval evidence **the stub itself carries** — a `ks_search`
call (via `vault-search.sh` or a direct `Bash` invocation) or a knowledge-store MCP read earlier
in the same transcript; a response that demonstrably *followed* an in-transcript retrieval and
cited nothing is the strongest signal, and is the case this step exists to flag. Do not go looking
in the knowledge-store read log for corroboration — that is an out-of-band source this step is
scoped out of, and its absence is never itself a finding.

**Sample, don't sweep.** Cap this at the **5** most clearly context-dependent responses per stub.
This is a judgment call with no mechanical oracle, and an exhaustive pass over every response
would cost more than the finding is worth — the point is a periodic read on whether the rule is
being followed, not a complete audit.

**Record.** If any sampled response lacks both a citation and the negative form, append one line
per stub to the friction ledger (`Context/Session friction ledger.md`, the same surface
§ Tooling friction uses) in that note's format, category `stale-context-rework`, evidence naming
the response and what it asserted uncited. Do **not** file a board defect — this is an authoring
habit that recurs, tallied like the other ledger classes, not a code bug.

**Default to silence, and never guess.** Most responses are not context-dependent, and a response
that plainly reasons from the code in front of it needs no citation. Absence of a citation is only
a finding when the assertion could not have come from anywhere but the store — if the transcript
is ambiguous about where a claim came from, skip it rather than manufacture a miss. Cite nothing
against a stub whose session did no knowledge-store work at all.

### Answered decisions

Delivery channel for the `decision_sink_ask` async backend — the read-back half of the decision queue sink. The async backend (in `/build`'s `decision_sink_ask` seam, operator-absent path) parks a plan item by posting a question comment, applying the `decision` label, and assigning the operator. When the operator replies and unassigns themselves, this step translates the parsed reply into **exactly one artifact** the existing 3d-esc / 4f resume machinery already reads — then stops. It does **not** transition sentinels (`[~]`/`[m]`/`[x]`), does **not** resume the item (no `build-level.mjs` invocation), and does **not** close the issue. The next `/build` tick's existing 3d-esc (`escalated: true` re-enter) or 4f (deferred `## Questions` drain) path performs resumption; this step only delivers the artifact. <!-- cite: T.18 incident:F#587 -->

**This step runs only during drain sessions that include a board-resident plan note in flight** — it is not a stub-based extraction. Run it as a standalone probe during any drain where a pipeline run may have been active, regardless of whether the stubs contain decision-queue signals. Skipping it silently on a session without stubs is correct (Step 0 exits early when there are no stubs, but this probe is independent — run it when the environment supports it).

**Scope: one REPO per call.** The drain operator may be on either the foundation or ssmobile board. Run this probe once per configured `PIPELINE_REPO` (default: the two governed boards, foundation = `<org>/foundation`, ssmobile = `<org>/ssmobile`). All gh commands below pass `-R "$REPO"`.

**Algorithm (per repo):**

1. **List candidate issues.** Query unassigned open decision issues. Use a
   **search qualifier** for the unassigned scope — `--assignee ""` is a no-op
   that does NOT restrict to unassigned (foundation #587), so it over-pulls
   operator-held issues; `no:assignee` actually filters:
   ```sh
   gh issue list -R "$REPO" \
     --search 'label:decision state:open no:assignee' \
     --json number,title,body,comments
   ```
   If the list is empty, skip this repo — nothing to drain.

2. **For each candidate issue `#N`:**

   a. **Contention pre-check.** Re-read the issue's current assignee count before acting:
      ```sh
      CURRENT=$(gh issue view "$N" -R "$REPO" --json assignees --jq '.assignees | length')
      ```
      If `CURRENT` > 0, the operator or another tick has re-assigned since the list was fetched — **skip this issue for this tick** (log: `issue #N assignee changed since list read — skipping`). Never act on an issue whose assignee changed under you.

   b. **Read the most recent comment.** Extract the last comment body from the `comments` array returned in step 1 (index `-1`). If there are no comments at all, treat as a parse-miss.

   c. **Parse the reply** per the typed reply grammar in `~/.claude/decision-queue-contract.md` § 3. Apply in order:
      - **Fenced `decision` block** — match a ` ```decision … ``` ` block anywhere in the comment; extract `chosen:` (required) and `reason:` (optional). Trim whitespace; match case-insensitively.
      - **`/choose <label>`** — a line starting `^/choose ` at the start of a line (no leading whitespace); extract the remainder as the label. Trim.
      - **`/approve`** — a line `^/approve` at the start of a line; treat as `chosen: approve` (valid only when `approve` / `accept` is an offered option — validate below).
      - **`/hold #N`** — not yet implemented; treat as a parse-miss with note `"/hold not yet supported"`.

   d. **Identify the item kind and slug.** Read the issue body for a `Tracked in plan:` back-link (format: `Tracked in plan: [[Plans/<date> <project> - <title>#<slug>]]`). The slug is the fragment after `#`. Also look for a `kind:` line (format: `kind: design-fork` or `kind: blocked`) that the `decision_sink_ask` async backend posts in the question comment. The question comment is the **first** comment (or the comment that contains the `kind:` line — search backwards from the most recent). If the kind cannot be determined from the comment, infer from context: a question listing design options with a `decision` fenced block structure → `design-fork`; a question listing clarifying questions → `blocked`.

   e. **Validate `chosen` against the offered option set.** The question comment (the one posted by the driver) lists the offered options. Extract the option labels from that comment (look for a block like `- \`<label>\` — ` lines, or an `Options:` / `**Options:**` section). Check that the parsed `chosen` value matches one of those labels (case-insensitive, whitespace-trimmed). If it does not match (or the option set cannot be parsed from the question comment), treat as a parse-miss.

   f. **On a successful parse and valid `chosen`:**
      - **Determine which artifact to write** based on `kind`:
        - **`design-fork`** → write a `## Design verdict — <slug>` block to the plan note:
          ```markdown
          ## Design verdict — <slug>
          Decision: <issue title or the design_fork.decision text from the question comment>
          Chosen: <the matched option label>
          Rationale: <the operator's `reason:` value, or "operator chose via decision queue" if absent>
          ```
          **Use `mcp__obsidian-builtin__vault_append`** on the plan note path (resolved from the `Tracked in plan:` wikilink). Do **not** use `mcp__obsidian__patch_vault_file` — the em-dash heading causes that tool to misfire. Then stamp `  - escalated: true` on the plan item via `mcp__obsidian-builtin__vault_patch`. This is the durable sentinel that the next `/build` tick's Step 1.4 resume path keys off to route the `[~]` item to 3d-esc continuation.
        - **`blocked`** → write a `## User answers — <slug>` block to the plan note:
          ```markdown
          ## User answers — <slug>
          <the operator's reply text (the chosen label plus reason if present), one line>
          ```
          **Use `mcp__obsidian-builtin__vault_append`** on the plan note. Then stamp `  - escalated: true` on the plan item via `mcp__obsidian-builtin__vault_patch`.
        - **Other kinds** (risky-set merge gate, `kind: merge-gate`) → write a `## Escalation resolution — <slug>` block via `mcp__obsidian-builtin__vault_append`:
          ```markdown
          ## Escalation resolution — <slug>
          Kind: <kind>
          Chosen: <the matched option label>
          Reason: <operator's reason if present>
          ```
          Then stamp `  - escalated: true` on the plan item (same as above).
      - **Drop the `decision` label** (baton handback):
        ```sh
        gh issue edit "$N" -R "$REPO" --remove-label decision
        ```
      - **Post a confirmation comment** (the delivery artifact). It MUST carry
        the machine sentinel `<!-- funnel:decision-applied -->` on its own line —
        `pipeline-tick.sh`'s idempotency guard (foundation #587) keys off it to
        recognise an already-drained issue that search-index lag re-lists, and
        skip it (`drain-already-applied`) instead of mis-firing a parse-miss +
        operator re-assign:
        ```sh
        gh issue comment "$N" -R "$REPO" --body \
          "Decision applied: $(chosen_value). Artifact written to plan note. Resuming on next tick.
        <!-- funnel:decision-applied -->"
        ```
      - **Stop.** Do NOT call `build-level.mjs`, do NOT flip `[~]`→`[m]`/`[x]`, do NOT merge. The existing 3d-esc / 4f path on the next tick performs resumption.

   g. **On a parse-miss** (unrecognizable comment, chosen not in offered set, `/hold`, or no comments):
      - **Re-assign to operator** with a "couldn't parse" comment per `~/.claude/decision-queue-contract.md` § 3 parse-miss rule:
        ```sh
        gh issue comment "$N" -R "$REPO" --body \
          "Couldn't parse your reply as a decision. Expected one of:
          - A \`\`\`decision\`\`\` block with \`chosen: <option>\` where <option> is one of: <offered-labels>
          - \`/choose <option>\` with one of the above labels
          - \`/approve\` (if \"approve\" is an offered option)
          Please re-reply and unassign yourself when done."
        # Strip a leading `@` from a real login (GitHub's replaceActorsForAssignable
        # rejects `@example-operator`; #977) but preserve the special `@me` token gh resolves.
        ASSIGNEE="$OPERATOR"; [ "$ASSIGNEE" = "@me" ] || ASSIGNEE="${ASSIGNEE#@}"
        gh issue edit "$N" -R "$REPO" --add-assignee "$ASSIGNEE"
        ```
        `OPERATOR` = `PIPELINE_OPERATOR` env var, default `@me` (operator's own handle — `gh`'s `@me` resolves to the authenticated user's real collaborator LOGIN, which can differ from the display/email-derived name shown elsewhere; verify with `gh api user -q .login` rather than assuming the two match; foundation #588). `--add-assignee` must receive a **bare** login (`example-operator`) or the literal `@me` — an `@`-prefixed real login (`@example-operator`) fails to resolve (foundation #977), hence the `ASSIGNEE` strip above.
      - **Leave** the `decision` label in place. The item remains in the queue for the next tick. Do NOT write any artifact block.

3. **Record in Step 6 summary:**
   - `Answered decisions drained: M (issue #s, repos, kinds, artifact types)`
   - `Parse-misses re-queued: M (issue #s, repos, reason)`
   - `Skipped (contention): M (issue #s)`

**What this step does NOT do (the delivery-channel invariant):**
- It does NOT make `[~]`→`[m]`/`[x]`/`[-]` sentinel transitions.
- It does NOT invoke `build-level.mjs` or any workflow continuation.
- It does NOT close the decision issue (the issue stays open; the `decision` label drop is the only label mutation on success).
- It does NOT open PRs, push branches, or interact with the merge gate.
- It does NOT re-derive or resume the plan independently — it writes one artifact block and stops.

The step is verified correct if, after it runs, the plan note contains the verdict block and `escalated: true`, the `decision` label is gone, and the next `/build` tick's 3d-esc / 4f path picks it up without any additional intervention from this step.

### Findings records

**After each extraction decision** (accept or skip), emit one findings record to `meta/data/raw/findings-<YYYY-MM>.jsonl` (one JSON object per line, newline-delimited). The schema is `workflows/scripts/drain/findings-schema.md` — that file is the SSOT; the required fields are summarised here for inline reference: <!-- cite: T.20 guard:workflows/scripts/drain/tally_recent_findings.py -->

| Field            | Value |
|------------------|-------|
| `schema_version` | `"2"` |
| `ts`             | ISO-8601 timestamp of this drain run. |
| `session_id`     | `report.stub.session_id` |
| `project`        | `report.stub.project` |
| `method`         | `"drain-lexicon"` or `"drain-model-skim"` (from provenance tag above) |
| `sub_method`     | The specific `match.tell` for `drain-lexicon`; `null` for `drain-model-skim`. |
| `finding_type`   | `decision` / `defect` / `pattern` / `mistake` / `feedback` / `friction` / `optimization` / `deferral` |
| `finding_ref`    | Durable artifact reference (vault note path, `#N`, `feedback_topic.md`, `things:<title>`). |
| `accepted`       | `true` if the extraction became a real artifact; `false` if skipped (noise, duplicate, already-captured-live). |
| `subject_model`  | The **analyzed-session** model — `report.stub.model` (the same value you stamp as a note's `source_model`); `null` if the stub had no `model:` line. |
| `analyst_model`  | The **drain-runner** model — your own current exact model ID (the note `extracted_by_model`); equals `subject_model` only when the drain runs under the same model as the analyzed session. |

Append the record via Bash: `printf '%s\n' '<json>' >> ~/dev/foundation/meta/data/raw/findings-$(date +%Y-%m).jsonl`. Batch all records for a stub in one append call when possible. The file is created on first write; no pre-creation needed.

Emit records for every adjudicated candidate — both accepted and rejected — so the false-positive rate is also measurable.

**Track a per-stub tally as you go** — for every stub processed this run, keep a running `{session_id: {"accepted": N, "rejected": M}}` count of the adjudications actually made for it (both `0`/`0` for a stub with genuinely nothing to extract). This tally is the input to the integrity check below and to the Step 6 summary's `Findings records:` line — do not reconstruct it after the fact from memory.

### Findings integrity check

A self-reported count is not evidence — corroborate it before quoting it. This is the mechanical check foundation#1576 added after a drain run's own Step 6 summary once asserted "Findings records: 16 emitted (8 accepted, 8 rejected)" while **zero** rows dated that day actually existed in the stream: an unverified positive-work claim. **The checker file is `workflows/scripts/drain/findings_integrity.py`** — it is the single findings-integrity checker (a later item extends this same file with additional checks rather than adding a sibling script). <!-- cite: T.23 guard:workflows/scripts/drain/findings_integrity.py -->

Before writing the Step 6 summary's `Findings records:` line, run:

```sh
python3 workflows/scripts/drain/findings_integrity.py \
  "$(git rev-parse --show-toplevel)" \
  --self-report '{"<session_id>": {"accepted": <n>, "rejected": <m>}, ...}'
```

using the per-stub tally above as the `--self-report` map (or `--self-report-file <path>` for a large batch). The script reads `meta/data/raw/findings-<YYYY-MM>.jsonl` directly — it needs no cooperation from the rest of this step to be correct, so a step that silently skipped its append cannot also talk its way past the corroboration:

- **Exit 0, `FINDINGS_INTEGRITY_OK`** — every self-reported session's accepted/rejected counts match the rows actually present in the stream (including a legitimate `0`/`0` self-report for a stub with nothing to extract, which the script does not flag). Use the script's own **corroborated** totals — not the pre-check self-reported figure — in the Step 6 summary's `Findings records:` line.
- **Exit 1, `FINDINGS_EMITTED_MISMATCH`** (one line per divergent session) — a self-report that cannot be corroborated. This includes the exact failure this check exists to catch: a stub self-reports ≥1 decision but zero rows actually landed for it (printed with an explicit `[processed transcript, zero rows landed]` tag). **This is a failure, not a log line:** report the script's corroborated (not self-reported) totals in the `Findings records:` line, and additionally add one line to the Step 6 summary's `Skipped/failed` bucket naming the diverging session(s) and the gap, so the failure is visible in the run log rather than absorbed into a cheerful-looking count.

The same file also carries an independent, whole-stream `--check-subject-model` mode (foundation#1584): it flags a findings record whose `subject_model` landed `null` even though the archived session stub it came from carried a `model:` line — the attribution-collapse defect that silently credits a defect to the model that *found* it (`analyst_model`) instead of the one that *produced* it (`subject_model`, findings-schema.md). It never flags a genuinely-modelless stub. This mode scans the whole `meta/data/raw/findings-*.jsonl` history rather than one run's self-report, so it is a periodic corroboration (e.g. a `check-in`/vault-hygiene pass), not a per-drain gate — invoke it ad hoc: `python3 workflows/scripts/drain/findings_integrity.py "$(git rev-parse --show-toplevel)" --check-subject-model`.

### Candidate-tells accumulation

**For every accepted extraction with `method: "drain-model-skim"`** (the model caught it, the lexicon didn't), append one entry to the candidate-tells file (`Pipeline/candidate tells.md` vs the legacy `Context/pipeline - candidate tells.md` — target pinned by the append-target resolution rule, `claude/commands/check-in.md`) in the vault via `mcp__obsidian-builtin__vault_append`.

Entry format (one line per extraction):

```
- <YYYY-MM-DD> · <project> · <finding_type> · `<missed phrase>` — <proposed tell>
```

- `<missed phrase>`: a short (≤10 words), greppable verbatim or near-verbatim phrase from the user turn the model used to identify the extraction.
- `<proposed tell>`: a one-line description — what it signals and how a lexicon pattern would match it (e.g. `literal: "going with option" → decision commit`).

Full format and review protocol: `workflows/scripts/drain/candidate-tells-format.md`.

If the vault file does not yet exist, create it first via `mcp__obsidian-builtin__vault_write` with this header:

```markdown
# Candidate Tells

Accumulated model-skim misses — phrases the model caught that the lexicon did not.
Review at check-in; promote promising ones into lexicon.tsv or discard.

```

Default to silence when no model-skim extractions were accepted — do not append placeholder entries.

### Recurrence → promotion

**Backstop that turns a repeating pattern of similar learnings into a proposal to amend the operating instructions.** The friction tally (`≥5/14d → Things task`) handles one category; this pass generalises the same shape to `feedback`, `pattern`, and `mistake` categories, where N similar extractions over a trailing window signal that a CLAUDE.md or skill *rule* should change — not merely that another note should be filed.

**How it works.** After all per-stub extractions above are complete (and findings records have been emitted), query the findings stream to count accepted extractions per `finding_type` over the trailing **14 days**:

```bash
# Tally accepted findings by type over the trailing 14 days (globs every
# findings-*.jsonl, so the window spans month boundaries). Prints `<type>\t<n>`.
python3 workflows/scripts/drain/tally_recent_findings.py "$(git rev-parse --show-toplevel)"
```

**Threshold rule.** For each of the following types, if the tally meets or exceeds the threshold, it is a **recurrence candidate**:

| `finding_type` | Threshold | Promotion signal |
|---|---|---|
| `feedback`  | ≥5 in 14d | Similar feedback keeps appearing → promote to a CLAUDE.md rule |
| `pattern`   | ≥5 in 14d | Pattern keeps being re-extracted → elevate to a canonical CLAUDE.md pattern anchor |
| `mistake`   | ≥5 in 14d | Same mistake recurs → tighten the guard rule in CLAUDE.md or a skill |
| `friction`  | ≥5 in 14d | (Handled by the Tooling friction section above — do not double-count here) |

**Default to silence.** Most runs surface nothing. Only proceed when at least one type crosses its threshold AND the type is in the covered set above (`feedback`, `pattern`, `mistake`). If the findings files are absent or unreadable, skip silently and note in the summary.

**For each recurrence candidate** (one type-category at a time):

1. **Check for an existing promotion task** — use `mcp__things__search_todos` with the title fragment `"Promote recurring <type>"` (Inbox + Anytime + Someday). If a task with that fragment already exists and is open, skip — a prior drain run already surfaced it.
2. **Generate a promotion task** via `mcp__things__add_todo`:
   - `title`: `"Promote recurring <type> extractions into a CLAUDE.md/skill rule"` — e.g. `"Promote recurring feedback extractions into a CLAUDE.md/skill rule"`
   - `notes`:
     ```
     <count> accepted <type> extractions in the last 14 days (threshold: 5).
     Recurring signal suggests a standing rule or guard should be added or tightened.
     Review the relevant notes/memories and draft a concrete amendment.

     ---
     Generated by /tidy recurrence→promotion pass on <YYYY-MM-DD>.
     Source: meta/data/raw/findings-<YYYY-MM>.jsonl
     ```
   - `tags`: `["drain", "Foundation", "est:30m"]`
   - `when`: omit (lands in Inbox)

**Surface in Step 6 summary** — see the `Recurrence candidates (≥5/14d)` line in the summary template below.

**Note on the capture/backstop split.** This pass is **drain-internal** — it tallies the findings stream that drain itself produces rather than backstopping a live extraction rule. No new capture anchor exists in CLAUDE.md and no new registry row is needed. The validate-capture-backstop script does not need updating.

## Step 4 — Generate tasks (liberal, deduped)

Identify candidate tasks from the **scan report** (`report.lexicon_matches[]` for deferral-category tells + `report.user_turns[]` for explicit or implicit commitments):
- Explicit deferrals — "queue this," "let's pick this up later," "table this," "next session," "tomorrow."
- Open questions left dangling that the user implicitly committed to resolving.
- Action items the user agreed to but did not complete in-session.
- Follow-ups Claude proposed that the user did not reject.

**Exclude defects already handled in Step 3 § Unfiled defects** — a defect routed to the board/GitHub there must **not** also become a Things task here. Things is for personal/triage follow-ups; the board is the worklist for defects.

For each candidate:

1. **Dedup pass.** Use `mcp__things__search_todos` (or `mcp__things__get_tagged_items` with tag `drain`) to find existing tasks with similar titles or tagged `drain` referencing the same source. Search Inbox + Anytime + Today + Someday. If a match exists, skip.

2. **Cross-stub dedup.** Within this drain run, track titles you've already added so two stubs about the same topic don't both create the task.

3. **Create task** via `mcp__things__add_todo` with:
   - `title`: short imperative ("Decide deployment target," "Review burrito-task triage")
   - `notes`: `<one-line context from the stub>\n\n---\nGenerated by /tidy from Sessions/<filename>.md on <YYYY-MM-DD>.\nSource: <project> session <date> <time>.`
   - `tags`: `["drain"]` plus the relevant theme tag (`Foundation` / `Community` / `Business`) when obvious from the stub, plus an `est:<duration>` tag using standard buckets (`est:5m`, `est:15m`, `est:30m`, `est:1h`, `est:2h`, `est:4h`, `est:8h`). Determine from stub context when scope is clear; if ambiguous, tag `est:?` and surface in Step 6 as `Tasks needing estimate refinement: M (titles)`.
   - `when`: omit (lands in Inbox by default)

4. Batch parallel `add_todo` calls when adding multiple tasks.

**Tag pre-existence note:** Things 3's URL scheme silently drops tags that don't already exist in the user's tag library. The theme tags (`Foundation`, `Community`, `Business`) exist; `drain` exists; `est:*` tags need to be created in the Things UI before they'll attach. If an `est:*` tag is missing, the task still creates but the estimate lives only in the notes line. Mention this in the summary if any drained task was missing its est-tag attachment.

## Step 5 — Archive the stub to the git store

The raw transcript's terminal home is the **git-tracked archive at `~/dev/foundation/meta/sessions/archive/`**, *not* the vault — moving it out of the embedded tree is what stops Smart Connections from re-embedding raw transcripts (epic #252; the 81%/258 MB cache bloat). The curated extractions from Steps 3–4 stay in the vault, where semantic search still finds them; only the raw transcript leaves the semantic layer. See `Decisions/foundation - Session-log long-term storage`.

Move the processed stubs from `Sessions/_inbox/<filename>.md` into the git store. **Archive the whole run's stubs in ONE batched archiver call** — `archive-session.sh` accepts multiple stub paths and lands them as a **single commit / single PR** (the retention sweep + `INDEX.md` regen + landing attempt run once for the batch). This is the #487 fix: a per-stub call would open one PR per stub, each re-regenerating `INDEX.md` on adjacent same-date lines and conflicting in the merge queue. **All vault access stays on MCP; the filesystem copy is done by the archiver script (no model Write-tool involvement):** <!-- cite: T.19 incident:F#487 -->

1. **Collect the cleanly-processed stubs.** For **each** stub that completed Steps 1–4 without unhandled errors, derive its local filesystem path — like Step 1's scanner call, a **raw on-disk path outside the knowledge_store seam**: the archiver reads vault files directly from disk (the MCP-only rule binds Claude, not shell scripts, and the obsidian backend's REST API has no filesystem-root semantics to route through). Resolves under the knowledge store root, e.g. `$KNOWLEDGE_STORE_ROOT/Sessions/_inbox/<filename>.md`. **Exclude** any stub that failed mid-process — leave it in `_inbox/` for the next run; it is not part of this batch.
2. Run the archiver **once, passing every collected stub path as a separate argument**. It copies each into `meta/sessions/archive/<basename>` via `cp` (printing `archived: <basename>` per stub), then runs the retention sweep (gzip cold logs), regenerates `INDEX.md` **once**, and makes a **single** landing attempt for the whole batch:
   ```
   bash ~/dev/foundation/workflows/scripts/sessions/archive-session.sh \
     $KNOWLEDGE_STORE_ROOT/Sessions/_inbox/<stub-1>.md \
     $KNOWLEDGE_STORE_ROOT/Sessions/_inbox/<stub-2>.md \
     …                                            # every cleanly-processed stub
   ```
   It is idempotent, touches **only the `meta/sessions/archive/` path, and only on the default branch (`main`)**. Because `main` is protected (the #330 merge-queue ruleset rejects a direct push — #404), on a protected `main` the archiver **lands the batch on a branch + PR + queue** rather than a bare local commit (which would be stranded local-only). It prints two kinds of verdict:

   **(a) One `archive-stub-durable:` / `archive-stub-pending:` line PER STUB** — whether *that* stub is captured **durably in git** and safe to delete. Under **delete-on-PR-record** (`[[Decisions/foundation - Delete-on-PR-record archive drain (supersedes 1161)]]`; supersedes the #1161 origin-proof rule) "durable" means the transcript is in git on `origin` — either committed on `origin/<default>` **OR** pushed to the enqueued archive PR branch (`chore/session-archive`). The PR branch **is** the durable record, so a stub need not wait for the PR to merge. These govern **deletion**:
   - `archive-stub-durable: <basename>` — captured durably in git (on `origin/<default>`, or on the enqueued archive PR branch); the `_inbox` stub is safe to delete.
   - `archive-stub-pending: <basename>` — nothing landed this run (the batch was `uncommitted`, or the archiver's pre-land guard deferred); keep it.

   **(b) The FINAL stdout line: one durability verdict for the whole BATCH.** This governs only what you **report**, never what you delete (the per-stub `archived:` lines above it are progress, not a verdict):
   - `archive-committed: <rev>` — the batch is **durable** (pushed to `origin/main`, already on `origin`, or committed locally where no remote exists).
   - `archive-pr-queued: <pr>` — the batch was landed on **one** PR that is **enqueued and auto-merges** (protected `main`; the queue merges it minutes later). The transcripts are already durable in git on that PR branch, so the batch's stubs are **safe to delete now** (delete-on-PR-record).
   - `archive-uncommitted: <reason>` — the stubs were placed on disk but **not** landed at all (a feature branch is checked out, `~/dev/foundation` isn't a git repo on this host, a direct push was rejected, etc.). They persist and a later default-branch run lands them.
3. **Delete per stub, report per batch.** Delete each stub the archiver marked `archive-stub-durable:` (via `mcp__obsidian__delete_vault_file`, one call per stub) — **whatever the batch verdict says**. Keep every `archive-stub-pending:` stub; deleting one the archiver did not land would lose it. If the archiver emitted no per-stub lines at all (an older build), fall back to the batch line: delete all on `archive-committed` **or** `archive-pr-queued` (both mean the batch is durable in git under delete-on-PR-record), else keep all.

   Then report the batch verdict in the summary:
   - `archive-pr-queued: <pr>` — list it as `N stub(s) archived on the auto-merging archive PR #<pr> (0 retained)`. The stubs are **already deleted** from `_inbox` this run (delete-on-PR-record); the PR merges async. **The next drain will not run until this PR merges** — the archiver's exit-guard refuses to stack a second archive PR, and Step 0 above early-exits on an open one — so if it lingers, `/check-in` surfaces it to merge.
   - `archive-uncommitted: <reason>` — list under *Skipped/failed* as `archive deferred — not landed: <reason>` (a feature branch, `~/dev/foundation` isn't a repo here, a rejected push, **or the pre-land guard declined because an archive PR is already open**) so a later run re-archives once it can land.

   **Why delete-on-PR-record** (supersedes the #372/#1161 origin-proof rule; temperloop#657): the archiver folds a whole run into ONE PR (#487). The old rule deleted a stub only once its bytes were proven on `origin/<default>`, keeping a `pr-queued` batch `pending` until merge — which both lagged the drain across runs *and* stranded stubs behind PRs that had already merged (F#1161: 109 of 123 stubs stranded 11 days). Since the PR branch already holds the transcripts in git, waiting for merge buys nothing: delete-on-PR-record deletes at PR-creation, so `_inbox` drains in one run. Safety rests on the archiver (foundation `archive-session.sh` § 4b): a stub is deleted only *after* its bytes are pushed to the PR branch (push-before-delete), and a pre-land exit-guard + `mkdir` lock + fail-CLOSED `gh` probe stop a later run's force-push from overwriting an unmerged PR branch. **Accepted residual:** a *deliberately closed-not-merged* archive PR loses its stubs (they rode only that branch); recover via `reconcile-inbox.sh`'s conservative on-origin sweep or `refs/pull/<pr>/head`. Operator rule: don't close an archive PR unmerged.

Archive only stubs whose Steps 1–4 completed without unhandled errors (step 1 above); a stub that failed mid-process stays in `_inbox/` and is noted in the summary so the next run picks it up. (Retrieval of archived transcripts is `git log -S` / `rg -z`, not semantic search — documented in `claude/CLAUDE.md` § Session logs for cold-session discoverability, #273.)

## Step 6 — Emit a summary

One-block summary:

```
/tidy — N stubs processed
- Decisions captured: M (titles)
- Provenance backfilled: M (titles)
- Provenance gaps (ambiguous authorship): M (titles)
- Proposed supersessions: M (D_new → D_prior; surfaced to proposed-supersessions surface for check-in)
- Memories saved: M (types)
- Patterns/Mistakes: M
- Optimization tools captured: M (titles)
- Tool-event structural passes: AskUserQuestion answered: M → feedback/decisions: K; errors: M → friction: J / mistakes: K; interrupts: M → feedback: K; capture_calls seen: M (dedup'd against Unfiled defects); spec-authoring damping: M stub(s), N lexicon match(es) suppressed (or "none")
- Unfiled defects filed: M (issue #s); self-resolved: M (titles)
- Stale/orphaned board claims: M (#s → board:host:sess; parked: K, report-only foreign: J)
- Board LABEL hygiene: board 3: deleted M / stripped N (or "in sync"); board 4: deleted M / stripped N (or "in sync"); board 7: deleted M / stripped N (or "in sync")
- Generated navigation: Index.md + N project Home.md(s) regenerated; conflicts (hand-authored, not overwritten): M (surfaced to moc-generation-conflicts surface for check-in)
- Answered decisions drained: M (issue #s, repos, kinds, artifact types); parse-misses re-queued: M; skipped (contention): M
- Tooling friction logged: M (categories); friction candidates (≥5/14d): M (categories)
- Findings records: M emitted (X accepted, Y rejected) — corroborated totals from `findings_integrity.py`; integrity: OK | FINDINGS_EMITTED_MISMATCH (N session(s), see Skipped/failed)
- Recurrence candidates (≥5/14d): M (types — feedback/pattern/mistake); promotion tasks added: M (titles)
- Tasks added to Things inbox: M (titles)
- Tasks needing estimate refinement: M (titles tagged `est:?`)
- Sensitivity flags: M (with file references, no secrets in output)
- Capture read-back failures: M (`<surface> — <what>` per record that did not land after a re-issue — foundation#1091; "none" when every append was confirmed)
- Skipped/failed: M (with reasons)
```

Always output only the summary block — this run is unattended (see the intro). The summary is written to the run log, not shown to a live operator; anything needing a human decision has already been parked to a `Pipeline/` surface (falling back to the legacy `Context/pipeline - *` location — path fallback convention, `claude/commands/check-in.md`) (or the sensitivity-flags surface) for `/check-in` to dispose. **Never** ask a clarifying question — extract liberally and let `/check-in` and morning planning triage.

## Step 7 — Release the drain lock

Delete your own `Sessions/_inbox/.drain.lock.<HOST>` via `mcp__obsidian__delete_vault_file`. Do this **unconditionally** at the end of the run — even if some stubs were left in `_inbox/` for the next run — so the lock never blocks a later drain. (A crash that skips this is backstopped by Step 0 item 4d's `TIDY_LOCK_STALE_AFTER` staleness cutoff.) Every path that reaches this step holds a lock and releases it here: item 4b writes the lock **unconditionally**, before item 4c's wait — so `--force-now` (which skips only 4c's wait and 4d/4e's election, never 4b's write) still holds a lock and must release it — and the **headless arm (Step 0 item 4f) writes one too** on its write-and-go branch. Skip this deletion only on a path that never wrote a lock in the first place — Step 0 item 2's early exits (no `*.md` stubs to drain, or an open/stalled archive PR): both exit the whole run before Step 0 item 4 ever runs, so they never reach this step at all.

## Step 8 — Snapshot the vault (silent)

Run `~/dev/foundation/workflows/scripts/mind_snapshot.sh` (no flags) to capture the vault's final state into the nested git history at `foundation/mind_snapshot/`. This runs **last** — after every extraction, surface append, archive, and lock release — so the whole run's writes land in one snapshot. The script is idempotent: if nothing changed since the last snapshot, no commit is created. Log any error in one line and continue — **never fail the run over the snapshot**. This absorbs what the retired evening routine's snapshot step used to do (`/tidy` is now the sole `mind_snapshot.sh` runner; K86). If `~/dev/foundation` is absent on this host, skip with a one-line note.
