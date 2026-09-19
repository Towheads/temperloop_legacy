# Presentation-plane index

> **Source of truth: `claude/presentation-plane.md`**, deployed to
> `~/.claude/presentation-plane.md` by `make install-claude` (same symlink
> convention as the rest of `claude/`). Epic #94 (communication-style model),
> plan item `plane-enumeration`.

The kernel ships (or will ship) style templates that restyle how commands talk
to the operator — tone, verbosity, formatting of human-facing prose. Some of
the kernel's output surfaces are not prose at all: they are grammars a parser
(GitHub's closing-keyword scanner, `/build`'s orchestrator, a shell script's
`jq` caller, a CI validator) reads back mechanically. A style template that
"helpfully" reformats one of those breaks the parser silently — the #164
failure shape (looks like it worked; nothing downstream notices until the
mechanism that depended on the exact bytes fails).

This file is the **index of which surfaces are which**. It is deliberately <!-- cite: PP.1 incident:F#164 -->
**not** a second copy of any contract: each row below names a surface,
classifies it, and points at the ONE place that surface's real shape is owned
(spec-centralization — the same discipline foundation's F#741 telemetry-sink
README uses so emit sites point at one canonical spec instead of restating
it). If a contract's shape ever changes, this index does not need editing —
only the pointer needs to keep resolving. **Never paste or paraphrase an
owning contract's content into a row here** — a stale enumeration that
mislabels a parsed surface as style-free would license the very breakage this
index exists to prevent.

## How to use this index

For any concrete output you're about to restyle:

1. Find the surface (or the smallest surface it contains — see "Mixed
   surfaces" below) in the **kernel table**, then the **overlay-extension
   table** if the project has one installed.
2. **Frozen** → do not change its literal bytes: keyword, casing, delimiter,
   field name, heading path, label string, JSON key/value, whatever the
   owning contract specifies. Follow the pointer and read the real contract
   before touching anything nearby.
3. **Not listed** → treat as **style-free**: human-facing prose (PR
   descriptions, plan-item titles and notes prose, commit-message bodies
   minus any closing-keyword line, decision-issue question prose, session
   summaries) that a style template may restyle freely.
4. Found a machine-parsed surface that isn't listed? That's a gap in this <!-- cite: PP.3 class:stale-index-licensed-breakage -->
   index, not license to guess — file it (kernel: an issue against this repo;
   overlay: per that project's capture-at-source rule) and add a row once the
   real owner is confirmed.

### Mixed surfaces (the common trap)

Most frozen surfaces are not whole documents — they are **exact lines or <!-- cite: PP.2 incident:F#265 -->
fields embedded inside an otherwise free-form document**. A PR body is mostly
style-free prose, EXCEPT a bare `Closes #N` line and the `## Verification`
section's resolved content. A plan-note item is mostly free-form prose,
EXCEPT its checkbox sentinel and its indented sub-line fields. A decision
issue comment is mostly free-form question prose, EXCEPT the fenced
` ```decision ` block / `/choose` / `/approve` grammar and (for a plan-approval
poll specifically) the `plan-approval-poll:` marker line. Restyle the
document; leave the embedded frozen line(s) byte-for-byte alone.

---

## Kernel table

Surfaces generic enough that a stranger's kernel-only checkout (no overlay,
no board, no vault) needs them frozen too.

| Surface | Class | Owning contract / parser | Why |
|---|---|---|---|
| Bare `Closes #N` / `Fixes #N` issue-closing line in a PR body or commit message | **Frozen** | `claude/CLAUDE.kernel.md` § Issue linkage (grammar) + `workflows/scripts/build/pr.sh` `open` (mechanical emitter) | GitHub's own closing-keyword scanner reads this exact bare-line, non-backticked form; a reformatted or combined (`Closes #1 and #2`) line silently fails to close. |
| Plan-note status sentinels `[ ]`/`[~]`/`[m]`/`[>]`/`[x]`/`[v]`/`[-]` | **Frozen** | `claude/plan-schema.md` § Status sentinels (meaning) + `workflows/scripts/build/plan.sh` `writeback`/`toposort` (mechanical parser/writer) | `/build`'s crash-resume, dependency-level toposort, and merge-gate logic branch on these exact tokens — see `plan.sh`'s closed `{"outcome":…}` contract. |
| Orchestrator/author sub-line fields on a plan item: `pr:`, `pushed_sha:`, `gh_issue:`, `also_closes:`, `epic:`, `split_from:`, `gate_check:`, `slug:`, `branch:`, `depends-on:`, `after:` | **Frozen** | `claude/plan-schema.md` (field definitions) + `workflows/scripts/build/plan.sh` `validate`/`writeback` | `/build` resume, `worktree.sh`'s deterministic `<slug>` path, `pr.sh`'s `Closes` emission, and `gate.sh`'s risk read all key off these exact field names. |
| `speculative: true` / `escalated: true` sentinel sub-lines | **Frozen** | `claude/commands/build.md` §§ "Crash-safe sentinel" / "Stamp `escalated: true`" (not in `plan-schema.md`) | Step 0.5 reconcile and Step 1.4 resume use presence/absence of these exact tokens to discriminate a held speculative worker / an escalated-awaiting-continuation item from a plain stuck worker — a renamed or reworded sentinel collapses the discrimination. |
| Decision-issue reply grammar: fenced ` ```decision ` block, `chosen:` key, `/choose <label>`, `/approve` shorthand, the `decision` label | **Frozen** | `claude/decision-queue-contract.md` §§ 2–3 | The driver's typed-reply parser and closed-enum-or-escalate rule read this exact grammar; the `decision` label is also the queue's drain filter (`--label decision --assignee ""`). |
| `plan-approval-poll: [[Plans/<vault-path>]]` marker line | **Frozen** | `claude/commands/assess.md` Step 6 (minted; "load-bearing... must not change") / `claude/commands/build.md` Step 0a (consumed as filter) | Literal-string filter `/build` Step 0a uses to distinguish a plan-approval decision issue from any other decision issue in the same queue. |
| `gate.sh` structured `.outcome` JSON (`READ`/`STRICT`/`NON_STRICT`/`RISKY`/`CLEAN_DISJOINT_INDEPENDENT`/`QUEUED`/`NUDGED`/`NUDGE_NOOP`/`MERGED`/`CONFLICTING`/`TIMEOUT`/`NATIVE`/`MANAGED`/`EJECTED`/`MERGE_REJECTED`/`ERROR`) | **Frozen** | `workflows/scripts/build/gate.sh` header (closed outcome-set contract) | The orchestrator branches on `.outcome` and associated keys only — never parses prose; a reworded outcome value is a silent no-match. |
| `pr.sh` structured outcomes (`SCAN_CLEAN`/`SCAN_BLOCKED`/`BASE_CURRENT`/`BASE_STALE`/`REBASED`/`REBASE_CONFLICT`/`DIRTY_WORKTREE`/`PUSHED`/`PUSHED_UNWATCHED`/`PUSH_REJECTED`/`PR_OPENED`/`EXISTS`/`ERROR`) | **Frozen** | `workflows/scripts/build/pr.sh` header | Same closed-outcome-set contract as `gate.sh`, with two exceptions that print a payload rather than an outcome wrapper: `open --body-only` (raw prose body — see that surface separately, style-free) and `acceptance-extract` (a JSON array of the recovered `acceptance_results` entries; temperloop#1267 made the `## Acceptance` recap round-trippable by moving each entry's evidence onto its own nested line, and this subcommand is that format's owned inverse — a reader parsing the recap by eye instead re-introduces the ambiguity the move removed). |
| `worktree.sh` structured outcomes (`CREATED`/`REMOVED`/`REMOVE_REFUSED`/`NOT_FOUND`/`PRUNED`/`SKIPPED_FRESH`/`SKIPPED_DIRTY`/`SKIPPED_UNMERGED`/`SIDELINED_WT`/`SIDELINED_WT_REAPED`/`PARKED_REF`/`PARKED_REF_REAPED`/`ERROR`) | **Frozen** | `workflows/scripts/build/worktree.sh` header | Same closed-outcome-set contract; the deterministic `<repo-root>.wt/<slug>` path it derives is also frozen (a pure function of `slug:`, never restated by a worker), as is the `<path>.unpreserved-<sha8>` sideline path `prune`'s own disposal owner keys off (temperloop#1730). `REMOVE_REFUSED` additionally carries a non-zero exit: `remove` refuses rather than destroy work no preservation captured. |
| `ci-poll.sh` structured outcomes (`CI_GREEN`/`CI_FAILED`/`TIMEOUT`/`ERROR`) | **Frozen** | `workflows/scripts/build/ci-poll.sh` header | Same closed-outcome-set contract; `failed_run_ids` shape is part of it. |
| `.build-guard` worktree marker file (JSON: `slug`/`branch`/`created`) | **Frozen** | `workflows/scripts/build/worktree.sh` (`create`, writer) + `claude/hooks/build-worktree-guard.sh` (reader) | The PreToolUse write-jail hook arms itself by checking for this exact filename's presence — a renamed marker file silently disarms the guard. |
| `.dual-build-arm` worktree marker file (JSON: `arm`/`sibling_worktree`/`sibling_branch`) | **Frozen** | `workflows/scripts/build/worktree.sh` (`create --arm`, writer) | temperloop#2076 (epic #2065): written ONLY when `--arm` is given, one per arm-disambiguated worktree; a future dual-build read-side sibling guard (epic #2065 item #13) resolves the sibling's worktree/branch off these exact field names rather than re-deriving `@<arm>` string surgery. |
| Telemetry / raw-lake record shapes (`command-run`, `issue-touches`, `claims`, `pipeline`, `knowledge-search-fallback`, `item-efficiency` streams; the `schema_version` convention) | **Frozen** | `meta/data/raw/README.md` (canonical sink spec) | Every emit site (`emit-command-run.sh`, `emit-issue-touch.sh`, `emit-gh-perf.sh`, `emit-item-efficiency.sh`, …) and every reader points here rather than restating the shape; a stream's readers key off exact field names, and a breaking change requires the documented `schema_version` bump. |
| Board adapter field names/values: `Status` single-select option strings, the `Host/Session` claim-stamp format, `Seq`, `Component` | **Frozen** | `workflows/scripts/board/lib/board.sh` (field-name constants) + `claim.sh`/`worklist.sh`/`reconcile.sh` (consumers) | The distributed-lock read (claim/release/reconcile) and the board's Ready/In-Progress/Done routing key off these exact option strings and the stamp format; a restyled option string desyncs the board from every reader. |
| Dual-build ledger row shape (`schema_version, seq, created_at, tier, model, slug, arm, base_sha, head_sha, start_order, gate, cost{…}, judge{…}, pick, override, loss_reason, cross_read_attempted, guard_armed, machinery_version, operator, host`) in `.temperloop/model-comparison/dual-build/rows.jsonl`, plus the `archives/<slug>@<arm>.patch` filename convention | **Frozen** | `workflows/scripts/model-comparison/dual-build-ledger.sh` header comment (the one place the shape is authored) | temperloop#2072, epic #2065 "new-work dual-build harness". `read`'s own consistency check keys on the exact `seq`/`slug`/`arm` field names to detect a truncated ledger, and `archive-check` derives a missing `--base` from the same-named `slug`/`arm`/`base_sha` fields; `append` assigns `schema_version`/`seq` itself and ignores any caller-supplied value for either, so a restyled field name would desync the reader from data the writer already committed to disk (a single-host, append-only, git-ignored stream — never git-tracked, so there is no diff to catch a silent rename after the fact). |
| Work-class labels `Operational` / `Foundational` | **Frozen** | `claude/work-class-policy.md` | The autonomous pipeline driver's autonomy-policy branch (fully-autonomous vs prep-then-gate) matches on these exact label strings. |
| Capture/Backstop pairing registry table (`claude/commands/tidy.md` § "Capture/Backstop pairings" table) | **Frozen** | `workflows/scripts/validate-capture-backstop.sh` (mechanical table parser) | The validator parses this table's literal row/column structure to assert every capture rule has a paired backstop; reflowing the table (not just its prose) breaks the CI gate silently. |
| Citation markers (`<!-- cite: <row-id> <class>:<ref> -->`) + `workflows/scripts/config/citation-registry.tsv` rows | **Frozen** | `claude/citation-schema.md` (grammar/placement) + `workflows/scripts/validate-prose-budget.sh` (mechanical 1:1 reconciler) | The budget gate greps the exact marker token grammar across `claude/**/*.md` and reconciles it against the registry's `row-id<TAB>file` rows; a restyled marker, a reflowed registry row, or a marker moved into code font goes red (or silently unscanned). |
| `/build` worker verdict JSON (`status`, `summary`, `acceptance_results[].{criterion,passed,evidence,discrimination_evidence,deferred_host_config}`, `commits[]`, `verification_surface_path`, `questions[]`, `design_fork{}`, `failure_reason`) | **Frozen** | `claude/workflows/build-level.mjs` `WORKER_VERDICT_SCHEMA` (machine-validated schema) + `claude/commands/build.md` §3c/§3d (prose contract, kept in lockstep with the schema) | `driveItem`/§3d branch **solely** on `.status` plus its per-status required fields, never on prose; `workflows/scripts/build/pr.sh`'s `assemble_body` recap reads `.criterion`/`.passed`/`.evidence`/`.discrimination_evidence`/`.deferred_host_config` off `.acceptance_results[]` by exact key — a renamed or reworded key either desyncs 3d's branching or silently drops that entry from the PR body a human reviews (temperloop#1319 was exactly this: `.discrimination_evidence` reaching the schema but not this jq). `.deferred_host_config` (temperloop#1182) is load-bearing in BOTH consumers: paired with `passed: false` it is the host-config **deferral** marker, which `isHostConfigDeferral()` excludes from §3d's `anyFailed` (so it does not stall the level) and which `pr.sh` renders as a `DEFERRED — host-config …` line (so an unchecked box is not misread as a worker failure). Drop the key in either place and a deferral silently reverts to reading as a plain failure. |
| The "cannot evaluate" idiom: `{outcome:"CANNOT_EVALUATE",error:<msg>}` JSON on stdout, `<prefix>: CANNOT EVALUATE — <msg>` on stderr, and the reserved non-zero exit status `RC_CANNOT_EVALUATE` (2) | **Frozen** | `workflows/scripts/lib/cannot-evaluate.sh` `cannot_evaluate_emit`/`RC_CANNOT_EVALUATE` (the ONE emission path, with exactly ONE registered exception named in the notes) | `workflows/scripts/model-comparison/{batch,judge,score,replay}.sh` each delegate their local `*_cannot_evaluate()` wrapper to this one function, and every model-comparison test fixture's `expect_cannot_evaluate` helper asserts both shapes verbatim; a caller that forgets to branch on the return now fails CLOSED on the reserved code instead of silently falling through to 0 (temperloop#1475). The code converges on 2, the same value three sibling standalone conventions already use (`KERNEL_LIB_RC_CANNOT_EVALUATE`, `PA_RC_CANNOT_EVALUATE`, `FD_RC_CANNOT_EVALUATE`) — those three keep their own local constant names for the identical value; this row does not rename or absorb them. **Coverage of "ONE emission path", stated exactly (temperloop#1487).** It covers (a) those four scripts' runtime `*_cannot_evaluate()` wrappers and (b) their `command -v jq` BOOTSTRAP guards, which now ride the same helper: `cannot_evaluate_emit` encodes with `jq` when present and with a pure-shell escaper when not, so the guard that fires *because jq is missing* no longer needs a hand-rolled shape. Before #1487 those four guards had drifted apart — `batch.sh` put the machine JSON on **stderr** with no human line and `replay.sh` emitted `outcome:"ERROR"` on stderr, so a consumer parsing stdout for the verdict saw nothing from either; both now emit both frozen shapes on the correct streams. Each script keeps its OWN documented process exit code at that guard (1, its CANNOT_EVALUATE code) — this row freezes the two output shapes plus the library function's return value, not a top-level CLI's exit table. **The one accepted exception**, deliberately named rather than left implicit: `workflows/scripts/model-comparison/tagging.sh`'s `crosscheck` subcommand (`_cc_eval`). Its **stdout is its own human verdict stream** (`OK —`/`FAIL —`/`CANNOT EVALUATE —`, one line, captured as the verdict by `test_live_tagging.sh`'s `run_crosscheck`), so emitting this helper's JSON there would corrupt the channel the verdict rides; it has no `{outcome:…}` consumer anywhere. It therefore emits the frozen HUMAN line verbatim on stderr, emits **no** machine JSON on either stream (no half-shape, no wrong-stream copy), and returns its own documented `1` rather than `RC_CANNOT_EVALUATE` — still fail-CLOSED, which is the #1409 property. `test_cannot_evaluate.sh` asserts this carve-out's exact shape, so a future silent drift into a partial JSON emitter goes red. |
| `/interview` parameter names `--into <note>`, `--first-question <block>`, `--check-questions <block>` | **Frozen** | `claude/commands/interview.md` § Parameters | A caller executes the interview spec inline in the same session with exactly this parameter block — the caller is `/workshop` Phase 1 (`claude/commands/workshop.md` Step 1.5), which passes all three; the "call" is a spec read, not a CLI parse, so a renamed or reworded flag desyncs caller prose from callee prose with no runtime error to catch it — the caller passes a parameter the interview never reads, or omits one it requires. |
| `Model-comparison-arms: baseline=<model> candidate=<model> pick=<baseline\|candidate> reason="<one line>"` PR trailer line | **Frozen** | `workflows/scripts/model-comparison/tagging.sh` `stamp-arms` (emitter) / `parse-arms` (its owned inverse) — ADR 0040 | The dual-build harness's (epic #2065) second, additive disclosure trailer — written ALONGSIDE, never in place of, the existing `Model-provenance:` line above, so every existing single-model consumer (including this file's own `crosscheck`) keeps parsing exactly what it always has. `pick` is one of the two literal arm names `batch.sh`'s `BATCH_ARM_BASELINE`/`BATCH_ARM_CANDIDATE` use; `reason` may not contain a double-quote or a newline, since the grammar's own trailing `"$` anchor depends on exactly one quote pair per line. A restyled key, delimiter, or the quoting rule breaks `parse-arms`'s round-trip silently. |
| `level-pick` escalation kind and its verdict grammar (`confirm` \| `override-level <arm>` \| `override-item <slug> <arm> "<reason>"`), plus the `levelPick` continuation object `{verdict, arm?, items?:[{slug,arm,reason}]}` and the `merge_blocked: "arms-trailer-unstamped"` parked-record field | **Frozen** | `claude/workflows/build-level.mjs` (`levelPickInput`/`driveLevelPick`, the emitter and the parser of the answer) + `claude/commands/build.md` 3d-esc's level-pick handler (the operator-facing dispositions) | temperloop#2083, epic #2065's dual-build harness. The orchestrator asks the operator in these exact option words and hands the answer straight back as `levelPick`, where `levelPickInput()` matches the verdict against a closed set and REFUSES anything else (`level-pick-input-invalid`) rather than discarding an override — so a restyled option label ("pick the candidate" for `override-level candidate`) does not read as a friendlier prompt, it reads as a malformed answer and stalls the level. `merge_blocked` is likewise read as a literal by Step 4's gate. |

## Overlay-extension table

Surfaces owned by a downstream overlay (an org/personal composition on top of
this kernel checkout) that a bare kernel checkout has no knowledge of and
cannot verify. **This table is scaffold-only here** — the kernel repo does
not know the real shape of an overlay's frozen surfaces; the consuming
overlay populates its own rows once its style templates are wired up (plan
item `overlay-adoption`). The rows below are illustrative of the *pattern*,
not an exhaustive or verified enumeration.

| Surface | Class | Owning contract / parser | Why |
|---|---|---|---|
| *(example, foundation)* Overlay-only telemetry streams layered onto `meta/data/raw/` (rework-tracking, richer issue-metadata snapshots, retrospective-verdict snapshots) | **Frozen** | *(overlay's own `meta/data/raw/README.md` extension — not this kernel's)* | Same reasoning as the kernel `command-run`/`issue-touches` row, scoped to overlay-only emit sites; the overlay's README extends this kernel's stub additively rather than replacing it (per `meta/data/raw/README.md` § Scope). |
| *(example, foundation)* `claude/capture-backstop-registry.overlay.md` § "Capture/Backstop pairings — overlay extension" table | **Frozen** | `workflows/scripts/validate-capture-backstop.sh` (unions this table in when present) | Same mechanical-parse reasoning as the kernel Capture/Backstop row, for pairs whose capture half is a personal/vault-backed rule with no meaning in a standalone kernel checkout. |
| *(placeholder — add real overlay-specific frozen surfaces here as they're identified)* | — | — | — |

---

## Maintenance

Add a row here whenever a new machine-parsed output surface is introduced
(a new `.outcome` value on an existing script is not a new row — it's covered
by the existing row's pointer to that script's header; a genuinely new
script or grammar is). Do not let this index drift ahead of or behind the
contracts it points at — if a pointer stops resolving (file moved, section
renamed), fix the pointer in the same change that moves the target.
