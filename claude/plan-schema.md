# Plan-note schema

Canonical schema for plan notes consumed by `/build` and produced by `/assess`. <!-- cite: PS.1 guard:workflows/scripts/build/plan.sh -->

> **Source of truth: foundation `claude/plan-schema.md`**, deployed to `~/.claude/plan-schema.md` by `make install-claude` (same symlink as the rest of `claude/`). It is **not** kept in the Obsidian vault — it ships with the commands that cite it, so it resolves on every machine they run on (incl. stageFind / a headless cron/deploy host). The *plan notes* it describes still live in the vault at `Plans/<date> <project> - <title>.md`; only this contract lives with the code. Rationale: `Decisions/foundation - Plan schema in claude config (out of the vault)`. Branch field formatting: `Decisions/foundation - Branch naming convention`.

## Contents

1. **File location** · **Frontmatter** — where a plan note lives and its required YAML (`status:` gates planning → execution).
2. **Body structure** — the note template (`## Problem` / `## Summary` / `## Items`), then each item field in detail:
   - Problem & Summary · Item fields at a glance (the scannable field index) · Item identifier · Branch field · `repo:` (optional) · Acceptance
   - Optional item fields: `gh_issue:` · `also_closes:` · `kind:` · `keystone:` · `model:` · Edges (`depends-on:` / `after:`) · `epic:` · `split_from:` · `gate_check:` · `activation:` · `cost:` · orchestrator-written `pr:` / `pushed_sha:` / `merge_blocked:`
3. **Orchestrator-written sections** — `## Questions` (ask-at-gate deferrals) · `## Merge gate log` (merge consent) · `## Run scope` (keystone-spike halt)
4. **Status sentinels** — the seven in-band `[ ]` / `[~]` / `[m]` / `[>]` / `[x]` / `[v]` / `[-]` states (alphabet: `workflows/scripts/config/ontology-registry.tsv`)
5. **Validation rules** — the 16 checks `/build` enforces before execution
6. **Worked example** · **Cross-references**

Most field subsections below open with a bold **Rule:** line — the operative
contract in one sentence — followed by its rationale. Skim the rules; read the
rationale only when you need the *why*.

## File location

Plan notes live at `Plans/<YYYY-MM-DD> <project> - <short title>.md` in the Obsidian vault, where `<YYYY-MM-DD>` is the plan's creation date (the same value as frontmatter `date:`). The **date-first prefix is required on every plan** — it matches the vault's `Sweeps/` / `Issues/` / `Sessions/` naming and keeps the `Plans/` folder chronologically sortable. The short title is the theme (3-7 words) and must **not** also lead with a date, since the prefix already carries it. The `Plans/` folder is a sibling of `Decisions/` and holds work breakdowns derived from analysis docs.

## Frontmatter

```yaml
---
tags: [plan, project/<name>]
date: <YYYY-MM-DD created>
source_kind: claude-stamped
source_session: <session-id>
last_verified: <YYYY-MM-DD>
sources:                              # one or more analysis docs that produced this plan
  - "Sweeps/2026-05-15 tier-2 sweep results.md"
  - "Context/stagefind - eval taxonomy.md"
epic: 4567                            # optional; parent epic issue # (board-enabled projects); /build Step 2.6 backfills
status: draft                         # draft | approved | executing | done | abandoned
---
```

`status: draft` is the gate between planning and execution. `/build` refuses to start on a `draft` plan; the user must promote it to `approved` first. <!-- cite: PS.2 guard:workflows/scripts/build/plan.sh -->

A session can also *poll* on this field: `/assess` optionally arms an approval poll (`Decisions/foundation - Approval-poll handoff for batch workflow`) that watches `status` for up to 2h and auto-launches `/build <plan> --unattended` the moment the user flips it to `approved` — letting the user review, edit, and approve on their own time. The poll auto-starts *execution* only; `/build`'s per-level merge gates stay human-gated.

## Body structure

```markdown
# <Plan title>

## Problem
<2-4 sentences: the problem this plan solves and why it's happening now — the pain
or risk in user-facing terms, NOT the solution. This is the first thing the reviewer
reads at the approval gate.>

## Summary
<The work as grouped bullets (not a paragraph). Each PARENT bullet names one part of
the problem; each SUB-bullet is one item's change, prefixed with its build level
(**L0** first → **Ln** last; items in the same level ship together). Group parents by
theme — which part of the problem — not by level. Light `(#N)` refs, no slugs.>

- **<part of the problem>**
  - **L0** — <change> (#<issue>)
  - **L1** — <change> (#<issue>)
- **<another part of the problem>**
  - **L2** — <change> (#<issue>)

Build order: L0 first → Ln last; items in the same level ship together.

## Sequencing notes
<Free-form: known dependencies, recommended order, items that can run in parallel, items that block the rest. Merge edges go in per-item `depends-on`, logical-order edges in `after:`; this section is for genuinely soft guidance only.>

## Items

- [ ] **<title>** `slug: short-stable-slug` — <one-line scope; becomes PR title body>
  - branch: `<type>/<slug>`           # type ∈ {feat, fix, chore, refactor, docs, test}
  - repo: owner/repo                   # optional; target repo for this item's work, when different from the plan's home repo (the kernel-repo case). Default: the plan's home repo
  - size: S | M | L                    # L means "should probably be split"
  - kind: code | spike                 # default code; spike = verdict-only (note + routed issue, no PR)
  - keystone: true                     # optional; kind: spike ONLY — halt /build after this spike's verdict for operator review before dependents build (temperloop#526)
  - model: opus                        # optional; advisory worker-model tier for /build 3c (opus | sonnet | haiku); absent = inherit the session model (top tier)
  - depends-on: other-slug, another-slug   # MERGE-safety edge: dep must be [x] merged before this starts
  - after: predecessor-slug            # LOGICAL-order edge: satisfied by any terminal state ([x]/[-]/[v])
  - source: [[Sweeps/2026-05-15 tier-2 sweep results#Finding 4: provider timeout fallback]]
  - gh_issue: 4567                     # optional; GitHub issue resolved on merge (PR body gets `Closes #N`)
  - also_closes: 4570, 4571            # optional; ADDITIONAL issues this PR resolves — one bare `Closes #M` line each
  - files: `evals/runners/gemini.py`, `evals/runners/__init__.py`
  - acceptance:
    - Gemini runner retries on 504 with exponential backoff (3 attempts, 1s/2s/4s)
    - Existing tests pass; new test covers 504 retry path
    - No change to runner public API
  - gate_check: "configs/artists.toml lists >=40 artists"   # optional; REQUIRED when an external/cross-plan gate rides notes: — a machine-checkable predicate on the CONSUMABLE (command / file-check), not the tracker's closed-state
  - notes: <nuance the worker needs — known gotchas, prior failed approaches, links to related Decisions/Mistakes; an external gate ("Do not start until #N lands") lives here AND must carry a matching gate_check:>
  - review: python-reviewer            # optional override; otherwise inferred from changed files
```

### Problem & Summary — problem-first, grouped by level

The first two sections are the human-readable face of the plan; they are what the reviewer reads at the approval gate (and what `/assess` Step 5 reproduces), so they are optimized for *reading*, not for the machine.

- **`## Problem`** states **why the plan exists** — the pain or risk in user-facing terms, not the fix. 2-4 sentences. (Authoring standard; it is **not** a `/build` validation rule, so older plans without it still execute.)
- **`## Summary`** is **grouped bullets, not a paragraph.** Each **parent bullet = one part of the problem** being addressed; each **sub-bullet = one item's change**, prefixed with its **build level** (`**L0**` first → `**Ln**` last; items in the same level ship together). Group parents by theme, not by level — the level tag carries sequencing, the grouping carries meaning. Use light `(#N)` refs; **no slugs** in this section (slugs live on the `## Items` entries). Don't invent per-item "Leg N" labels — the **level is the sequence**.

The level on each sub-bullet is the item's dependency level (the same level `/build` computes from `depends-on` + `after`), so the summary's sequencing and the execution DAG never disagree.

### Item fields at a glance

Every `## Items` entry is one checkbox line — `- [ ] **<title>** \`slug: <kebab>\` — <scope>` — followed by an indented field block. The table below is a scannable index; the subsections after it give each field's full rules. In the **Required?** column, *required* means every item carries it per the template; *optional* fields sit under an `Optional …` subsection below; validator-enforced fields cite their rule number (see `## Validation rules`).

| Field | Required? | Purpose |
|---|---|---|
| `**<title>**` | required | Human-readable item title. |
| *scope* (text after the slug) | required | One-line scope; becomes the PR title body. |
| `slug:` | required (rule 3) | Stable kebab-case id; the handle `depends-on:` / `after:` reference. |
| `branch:` | required (rule 4) | `<type>/<slug>`, type ∈ {feat, fix, chore, refactor, docs, test}. |
| `repo:` | optional (rule 12) | Target `owner/repo` when the item lands in a repo other than the plan's home (the kernel-vs-overlay split); absent = the plan's home repo. |
| `size:` | required | `S` \| `M` \| `L` (`L` means "should probably be split"). |
| `kind:` | optional (default `code`) | `code` → PR; `spike` → verdict note + routed issue, no PR. |
| `keystone:` | optional (rule 15) | `kind: spike` **only**; value `true`. Marks a *keystone* spike — one whose verdict reshapes downstream contracts — so `/build` halts for operator verdict-review before dependents build (temperloop#526). Absent = routine spike (today's autonomous path). |
| `model:` | optional | Advisory worker-model tier `opus` \| `sonnet` \| `haiku`; absent = inherit the session model. |
| `cost:` | optional (rule 16) | Block marking an item with **outsized execution spend** (deep-research run, large agent fan-out, big eval) — its **presence** is the binary "expensive" flag. Carries a required `because:` (the cost driver) and an optional `budget:` (intended token ceiling). Advisory/display: `/build` surfaces it at the approval preview so a large spend isn't buried in a plain-looking item. |
| `depends-on:` | optional | MERGE-safety edge — each dep must be `[x]` merged before this item starts. |
| `after:` | optional | LOGICAL-order edge — satisfied by any terminal state (`[x]` / `[-]` / `[v]`). |
| `source:` | recommended (rule 6) | Wikilink to the analysis doc/finding; must resolve when present. |
| `gh_issue:` | optional (rule 7) | GitHub issue closed on merge — emits `Closes #N` in the PR body. |
| `also_closes:` | optional | Additional issues this PR resolves — one bare `Closes #M` line each. |
| `files:` | optional | Files the item is expected to touch. |
| `acceptance:` | required (rule 2) | Bullet list of independently checkable conditions. |
| `gate_check:` | conditional (rule 11) | Machine-checkable external-gate predicate; required whenever a prose external gate rides `notes:`. |
| `activation:` | conditional (rules 13 & 14) | Inward activation predicate — how `/build` confirms *this item's own* output is live. A `class: A` block carries a `proof:` command run at Step 3e.6; `class: B`/`C` are ledger-discharged (temperloop#317). **Required** (rule 14) on a *product-source* item — `kind: code` whose `files:` touch `scripts/`, `workflows/`, or `claude/` — unless the plan is grandfathered (§ Optional `activation:` block). |
| `notes:` | optional | Nuance for the worker — gotchas, prior failed approaches, external-gate prose. |
| `review:` | optional | Reviewer override; otherwise inferred from changed files. |
| `split_from:` | optional (rule 10) | `#N` this item was split from; mutually exclusive with `gh_issue:`. |
| `epic:` (frontmatter) | optional | Parent epic issue # on board-enabled projects. |
| `pr:`, `pushed_sha:` | orchestrator-written | Set by `/build` at PR-create time; authors don't set them. |
| `merge_blocked:` | orchestrator-written | Set by `/build` at park time (3h step 1) for a dual-built item whose winning PR is unstamped; excludes it from Step 4's merge gate across a resume. |

### Item identifier — slug, not position

**Rule:** every item carries a stable `slug: <kebab>` (lowercase `[a-z0-9-]+`, ≤40 chars, unique in the plan, descriptive); `depends-on:` / `after:` reference items **by slug, never by position** — reorderings break positional refs silently. <!-- cite: PS.3 guard:workflows/scripts/build/plan.sh -->

Each item has a stable slug (`slug: <kebab>`) used by `depends-on`. **Do not** reference items by position number — reorderings break positional references silently. Slugs survive edits.

Slug rules:
- Lowercase, kebab-case, `[a-z0-9-]+`, max 40 chars.
- Unique within the plan note.
- Should be descriptive enough to read in prose: `gemini-retry-504`, not `item-3`.

### Branch field

**Rule:** `branch:` must be `<type>/<slug>` with type ∈ {feat, fix, chore, refactor, docs, test}, and its slug half should equal the item's `slug:` (keeping the plan → branch → PR chain traceable).

`branch:` must follow `<type>/<slug>` per `Decisions/foundation - Branch naming convention`. The slug part should equal the item's `slug:` field — keeping them in lockstep makes the plan→branch→PR chain easy to trace.

Type derivation table:

| Finding nature | Type |
|---|---|
| Behavior wrong; fix restores intended behavior | `fix` |
| New capability requested | `feat` |
| Correct but messy / duplicated | `refactor` |
| Build / deps / config / tooling | `chore` |
| Docs only | `docs` |
| Test gap | `test` |

### Optional `repo:` field

**Rule:** set `repo: owner/repo` only when this item's work lands in a *different* repo than the plan's home (the kernel-vs-overlay split); absent = the plan's home repo. `/build` uses it to pick the item's checkout/worktree and to qualify the `Closes` line.

`repo:` names the `owner/repo` this item's work actually lands in, when that differs from the plan's home repo. Default (absent) is the plan's home repo — the common case. The motivating case is the **kernel-vs-overlay split** (`claude/CLAUDE.kernel.md` § Kernel vs overlay routing rule, the "stranger test"): a plan authored in an overlay/consumer repo can carry an item whose fix is actually kernel-classified and belongs **upstream**, in the kernel repo, not the plan's own checkout. `/triage` flags such candidates (its kernel-vs-overlay routing step) and `/assess` carries the classification into the item's `repo:` field.

`/build` consumes `repo:` at two honor points:
- **Checkout/worktree selection (Step 3b).** When `repo:` is set and differs from the plan's home repo, the orchestrator resolves a local checkout of `repo:` (rather than the plan's own checkout) and passes *that* root to `worktree.sh create` — the item's worktree, branch, and commits all land against the target repo, never the plan's. If no local checkout of `repo:` exists, this is a hard block (surface it — do not silently fall back to the plan's own repo).
- **PR-body close line (Step 3f).** A cross-repo item's `Closes` line must use the fully-qualified `owner/repo#N` form — `Closes owner/repo#<gh_issue>` — never bare `Closes #N`, which is same-repo only and would not reach the target repo's tracker (per the global `CLAUDE.md` § Issue linkage cross-repo-closes caveat). `also_closes:` entries on a cross-repo item are qualified the same way.

Format: bare `owner/repo` (no `#`, no issue number — that's what `gh_issue:` carries). Slug/kebab org and repo names only.

### Acceptance — bullet list, not prose

**Rule:** `acceptance:` is a **list** of independently checkable conditions (the worker's self-check before `status: done`), never a paragraph. When sequential legs share one gate/corpus, each leg's block MUST state its **gate scope** — the fixtures it owns, plus the exclusions owned by a **named** later item.

Each `acceptance:` block is a list of independently checkable conditions. The worker uses these for self-verification before returning `status: done`; a paragraph form is harder to tick off mentally.

**Gate scope, when sequential legs share one gate/corpus.** When a plan's items are **sequential legs measured by one shared acceptance gate** (a full-corpus eval sweep, a CI smoke gate, any check whose denominator spans multiple legs), each leg's `acceptance:` MUST state its **gate scope** — the fixtures/cases that leg is accountable for, *and* the exclusions whose failure is owned by a **later leg, naming the owning item** (e.g. `excludes Y — owned by #Z`). This is the **gate-side analog** of the falsifiable-acceptance / assume-unverified-mechanism rule (#108): where #108 pins what a leg *produces* (no acceptance criterion may rest on an unbuilt mechanism), gate scope pins what a leg is *measured against* (no acceptance criterion may rest on a shared gate whose denominator a later leg can fail). Without it, a shared-gate failure is **ambiguous between "this leg regressed" and "a later leg's known failure is in my denominator"** — the #491/#512 trap, where leg #491 met its own contract yet could not pass the shared eval-smoke gate because a later leg (#492) owned the fixtures that collapsed, forcing a park, a follow-up issue (#512), and a mid-run gate rescope. Pinning each leg's scope at assess time makes the failure attributable and avoids that churn. Example acceptance bullet: <!-- cite: PS.4 incident:F#491 -->

```markdown
  - acceptance:
    - Gate scope: this leg owns fixtures `ibiza-hi.es`, `barcelona.es` (deterministic year inference); it EXCLUDES the bare-artist fixtures `sf-audio`/`sf-1015`, owned by #492 — their failure does not count against this leg's gate.
    - ibiza-hi.es year-inference accuracy ≥ 99% on the locale corpus
```

### Optional `gh_issue:` field

**Rule:** set `gh_issue: <n>` when the item closes an existing tracked issue — `/build` emits `Closes #N` in the PR body. Leave it unset for untracked work, a `split_from:` item, or a Contract-derived item; `/build` mints a fresh issue for those.

When an item resolves a GitHub issue tracked in the project's repo, set `gh_issue: <number>`. `/build` consumes this field to inject `Closes #N` into the PR body, which auto-closes the issue on merge per GitHub's keyword linkage. Items without `gh_issue:` don't emit a `Closes` section — refactors, chores, features without a pre-existing tracker.

Three flavours of item leave `gh_issue:` unset, and `/build` Step 2.5 mints a fresh tracking issue for each: (a) untracked work with no pre-existing issue; (b) a **split item** (carries `split_from: #N`; Step 2.6 then *closes* the coarse #N); and (c) a **Contract-derived item** from `/assess` **epic-decomposition mode** — a pre-designed epic decomposed from its `## Contract` body when it had no sub-issues (foundation #526). A Contract-derived item leaves **both** `gh_issue:` and `split_from:` unset and relies on `epic:` frontmatter: `/build` mints its sub-issue and Step 2.6 links it under the **existing** epic, closing nothing (unlike the split case, there is no coarse issue to retire — the parent is the epic, which stays open until its last child closes).

When a plan item is decomposed from an `Issues/` vault note that wraps the GH issue (as `/assess` does for bug batches), populate `gh_issue:` from the issue number in the source heading. The vault Issues note remains the source-of-record for the discussion; the GH issue is the operational tracker.

Project-level rule on PR-body issue references lives in the project `CLAUDE.md` under "Issue linkage" (when the project has one).

### Optional `also_closes:` field

**Rule:** list *additional* issues this one PR closes beyond `gh_issue:` — `/build` emits one bare `Closes #M` line per entry (never `Closes #1 and #2`). Absent is the common case.

`also_closes:` is a list of **additional** issue numbers this PR resolves, beyond the primary `gh_issue:`. `/build` emits **one bare `Closes #M` line per entry** (each on its own line, never combined) in the PR body, alongside the primary `Closes #<gh_issue>`. GitHub closes an issue only when it carries its **own** keyword — `Closes #1` then `Closes #2` on separate lines — **never** `Closes #1 and #2`; so each entry must become its own line.

Two patterns motivate it:

- **Opportunistic same-PR fix** — a `capture.sh`'d defect fixed alongside the planned work in the same PR; list it in `also_closes:` so it closes atomically with the primary issue.
- **Root-cause-collapse atomic close** — instead of `/triage` closing absorbed symptoms early, the symptoms stay open and the survivor's fix PR carries `Closes #<survivor>` (the primary `gh_issue:`) plus `Closes #<symptomN>` (each `also_closes:` entry), so the whole cluster closes atomically on merge.

`also_closes:` absent is the common case. The list accepts plain integers or `#N` refs; each must be a positive integer.

**On board-enabled projects, `/build` backfills this field.** When the project root provides `scripts/claim.sh` (stageFind's GitHub Projects board), `/build` creates a tracking issue at run start for every worked item that lacks `gh_issue:` and writes the number back here — so on those projects the field ends up populated for all executed items, and each item is claimed In Progress while worked and moved to Done on merge. Authoring `gh_issue:` ahead of time still works when the issue already exists. See `Decisions/foundation - build board integration`.

### Item `kind:` — code vs spike

**Rule:** `code` (default) produces a PR (worker → commit → push → PR → CI → merge); `spike` is verdict-only — a note + routed issue, no PR — and lands in terminal state `[v]`.

`kind:` is `code` (default) or `spike`. A **code** item produces a PR (worker → commit → push → PR → CI → merge). A **spike** item is verdict-only — its deliverable is a Context/Decision note + a routed follow-up issue, not a PR. `/build` runs a `spike` read-only, skips push/PR/CI, verifies the note exists and the issue is routed, and marks it `[v]` (verdict-captured); on board-enabled projects the spike's issue closes on verdict-capture, not via a PR `Closes`. In the `## Summary`, a spike gets its level tag like any other item — isolate it into its own earlier level (via `after:` edges) so no level mixes a spike and a build item.

### Optional `keystone:` field — the keystone-spike review gate

**Rule:** `keystone: true` is **spike-only** — it makes `/build` halt after the spike captures its verdict so the operator reviews it before any dependent level builds. Use it when the verdict reshapes downstream contracts/scope; omit for a routine spike (today's autonomous path). <!-- cite: PS.8 incident:K#526 -->

`keystone: true` is a **spike-only** marker (validated by rule 15) for a *keystone* spike: one whose verdict **reshapes downstream contracts or scope**, as opposed to a routine investigation spike whose verdict merely informs a single dependent. By default every `kind: spike` runs **fully autonomously** (`/build` Step 3 spike kind-fork → `[v]`, no operator gate — a spike-only level needs no merge gate), so a keystone spike's contract-reshaping verdict would otherwise flow **straight into dependent builds with no operator review**. `keystone: true` closes that gap: `/build` **halts after the keystone spike captures its verdict**, so the operator reviews the Decisions/Context verdict note before any dependent level builds.

Mechanics (`/build` spike kind-fork, `claude/commands/build.md`): the run splits into **two runs against the same plan note**, recorded in an orchestrator-written `## Run scope` section (below):

- **RUN 1 (spike):** process levels up to and including the keystone spike's level; the spike captures its `[v]` verdict as normal, then — because it is `keystone: true` **and** non-terminal items remain — `/build` records the halt in `## Run scope` and **stops without advancing** to dependent levels. The plan stays `status: executing` so a later run resumes.
- **RUN 2 (build):** the operator reviews the verdict note and **re-runs `/build`**. On resume the keystone spike is already `[v]` at start (it did not transition *this* run), so no halt fires — RUN 2 builds the dependent levels normally. Re-running `/build` **is** the operator's approval to proceed; if the verdict says the plan should change, the operator edits the plan (or abandons it) instead of re-running.

This gate is **`ask-now`** (no safe default — a contract-reshaping verdict is exactly what a human must see) and is therefore **NOT skippable by an `--unattended` approval poll.** `--unattended` controls the *start*, never a mid-run gate: an operator-absent run that hits the keystone halt parks the plan (`status: executing`), posts a verdict-review decision issue on the epic (operator-absent backend), and stops the tick — it never auto-proceeds into dependent builds on silence. Routine spikes (`keystone:` absent) keep today's autonomous path unchanged.

Author a keystone spike exactly like any other spike — its own isolated level via `after:` edges — and add the one `keystone: true` line. See `Decisions/temperloop - Keystone-spike review gate`.

### Optional `model:` field — tier by measured rounds-to-merge

**Rule:** `model:` is an optional worker-tier hint (`opus` | `sonnet` | `haiku`); **absent = inherit the session model (top tier)**, the safe default. It is advisory for `/build` 3c only, never a validation rule. `/assess` stamps `opus` on `size: S`/`M` **code** items and leaves spikes / `size: L` absent — except two named carve-outs that also inherit: an S/M item whose files are exclusively advisory-only-verified spec-prose (Carve-out (a) below), and an S/M item whose failure mode is invisible to CI and to its own acceptance gates (Carve-out (b) below). *The tier is set by measured rounds-to-merge, never by which gate is assumed to catch a mistake.* <!-- cite: PS.9 incident:K#671 -->

`model:` is an optional per-item worker-model tier: `opus` | `sonnet` | `haiku`, or absent. **Absent = inherit the session model (the top tier)** — the safe default. The field is **advisory routing for `/build` 3c only** (it is passed through to the worker `Agent` spawn when present); it is never a validation rule, and an item without it executes normally on the session model.

**Stamping rule** (applied by `/assess` Step 2 when drafting items):

- `size: S` or `M` **and** `kind: code` → stamp `model: opus`.
- `kind: spike` or `size: L` → leave `model:` absent (inherit the session model).
- **Carve-out (a) — advisory-only-verified spec-prose:** an `S`/`M` `kind: code` item whose files are **exclusively** advisory-only-verified spec-prose (`claude/commands/*.md` and similar prose whose *semantics* are verified only by advisory review — e.g. workflow-reviewer — not by mechanical CI/`quality-gates.sh`/acceptance gates) → leave `model:` absent (inherit the session model), **overriding** the first bullet. Such an item's output *is* the gate, so it belongs with the spikes, not the gated code items.
- **Carve-out (b) — silent failure mode:** an `S`/`M` `kind: code` item **whose own failure mode is invisible to CI and to its own acceptance gates** — a guard that can fail *open*, a detector that can fail to detect, a validator wired to a field that is absent in the common case — → leave `model:` absent (inherit the session model), **overriding** the first bullet. **Trigger condition** (either limb is sufficient, and `/assess` decides it from the item's `Produces`/acceptance without re-deriving the reasoning): **(i)** the item's deliverable is a **negative-space check** whose correct behaviour is *silence* — a guard, gate, hook, detector, validator, refusal, or precondition — so a broken one and a correct-but-never-exercised one both emit the same green run; or **(ii)** the item's acceptance bullets are satisfiable by tests built **only** from payloads the implementer chose, with no fixture or adversarial case that would go red if the check stopped firing. Motivating case: temperloop#1187 (worktree-guard writer identity) — a guard wired to a field absent in the common case passes CI, `quality-gates.sh`, and its own tests. **Not** triggered by an item that merely *touches* a guard: the test is whether *this item's* deliverable can be wrong while everything downstream stays green.

The tier is set by **measured rounds-to-merge, not by an assumed gate**. The stamp was originally `sonnet` on the premise that a mechanical gate downstream — CI, `quality-gates.sh` (3e.5), the acceptance bullets — catches a cheaper worker's mistakes. A retrospective over every workflow-driven item from 2026-08-14 to 2026-09-16 (284 items in the foundation session archive; temperloop#2127–#2132 carry the review-loop half) measured the opposite: `sonnet`-stamped S/M code items took **2.7** review-and-fix rounds and **1.38M** pooled subagent tokens per item against **1.2** rounds / **0.71M** on `opus` and **1.4** / **0.54M** on the top tier, and **48%** of them hit a `review-blocking` round against 24% / 14%. The extra rounds were caught by the *advisory* §3e reviewers, never by CI or the acceptance gate, so the cheaper worker was not cheaper per merged item — it moved the spend into re-review and re-gating. `opus` is the default because it had the lowest cost per merged item in that window; `sonnet`/`haiku` remain legal values for an operator running a deliberate comparison (the `--dual-build` harness), never a stamp. Carve-out (a) keeps a spec-prose rewrite on the session model because `claude/commands/*.md` semantics are advisory-review-only, so no mechanical gate catches a weaker model's mistake. Carve-out (b) keeps a *silent-failure* deliverable there for a second reason: the gates all run, and all pass, but none of them can *observe* the defect — a guard that never fires is indistinguishable from a guard with nothing to catch, so CI green is evidence about the harness, not about the guard. Where (a) asks "is there a mechanical gate over these files?", (b) asks "would the gates that *do* run go red if this were wrong?" — both leave a seat whose output *is* the gate on the top tier. **This ruling is explicit so it cannot recur as an invisible ad-hoc per-plan deviation** (the epic-#671 pattern, where `/assess` left `model:` absent on two size-M spec-rewrite items with the rationale inline in the plan rather than in the schema — unrepeatable by the next `/assess` run and invisible to the schema's readers): the carve-outs live in the stamping rule, so every `/assess` run applies them uniformly. **The sanctioned route for any deviation from the S/M→`opus` stamp is a named carve-out in this section — (a) or (b), applied by its own trigger condition — never a per-item rationale written inline in a plan note.** An item that warrants the top tier but fits neither trigger is a signal to add a *third* named carve-out here (as temperloop#1286 added (b) rather than let temperloop#1203's item 1 stand as an inline exception); an inline deviation stays the discouraged thing. **Escalate-on-retry:** `/build` re-runs any failed lower-tier attempt (a `failed` return or a CI failure) on the session model regardless of the stamp — a retry never stays on the stamped model (see `/build` 3c).

### Edges — `depends-on:` (merge-safety) vs `after:` (logical order)

**Rule:** `depends-on:` = a **merge-safety** edge (the dep must be `[x]` **merged** before this item's worker starts); `after:` = a **logical-order** edge (satisfied by *any* terminal state `[x]`/`[-]`/`[v]`). Reach for `after:` whenever the edge is only about order, not merge conflict. <!-- cite: PS.11 guard:claude/commands/build.md -->

Two distinct ordering fields, both comma-separated slug lists:

- **`depends-on:`** is a **merge-safety** edge — use it only when out-of-order merging would break (items share schema or identical lines). The dependent's worker starts only after the dep is `[x]` **merged** (it builds on the dep's merged code). Neither `[m]` nor `[>]` satisfies a `depends-on` — `[>]` is a merge in flight, not a landed one.
- **`after:`** is a **logical-order** edge — the dependent shares no code with its antecedent but must follow it (e.g. a fix that must follow a spike's verdict). It only sequences the item into a later level, and is satisfied once the antecedent reaches **any** terminal state (`[x]`, `[-]`, or `[v]`) — so a spike satisfies an `after:` edge with no merge.

`/build` builds dependency levels from the **union** of both fields, but applies the "must be merged first" precondition only to `depends-on`. Reach for `after:` whenever the edge is purely about order, not merge conflict — keeping `depends-on` honest is what lets a level fan out safely.

### Optional `epic:` frontmatter field

**Rule:** `epic: <n>` records the parent epic tracking this plan as one unit; on board-enabled projects, if it is absent `/build` mints an epic from the `## Summary` and backfills the field. Optional.

`epic: <issue-number>` records the parent epic that tracks this plan as one unit. On board-enabled projects, `/build` (Step 2.6) creates the epic from the plan `## Summary` if `epic:` is absent, links each per-item issue as a child, and writes the number back here — idempotent on re-run, exactly like `gh_issue:`. `epic:` absent is valid.

### Optional `split_from:` item field

**Rule:** `split_from: #N` marks an item `/assess` split out of coarse issue #N — set it **only** with `gh_issue:` left unset (the two are mutually exclusive, rule 10). `/build` mints a fresh per-item issue and swaps `split_from:`→`gh_issue:` atomically, then closes the coarse #N. <!-- cite: PS.5 incident:F#73 -->

`split_from: #N` marks an item that `/assess` split out of one coarse sub-issue #N. It is set **only** on split-derived items, and **only with `gh_issue:` left unset** — the two are mutually exclusive. It exists to preserve `/build`'s one-item↔one-issue invariant when one sub-issue decomposes into several items: copying `gh_issue: #N` onto all of them is the #73 bug (the first PR's `Closes #N` closes the shared issue while the rest of the chain is unmerged, and the board moves #N to Done prematurely).

Mechanism: `/build` Step 2.5 sees no `gh_issue:` and **mints a fresh per-item issue** for each split item, writing the minted `gh_issue:` while **removing `split_from:` in the same patch** (the atomic swap that makes "1:1 restored" literal and keeps rule 10 always true — see rule 10), and adding a `Split from #N` lineage line to each minted body; Step 2.6 links the minted leaves as **direct epic children** and then **closes the coarse #N** (once all its leaves are minted) so the data-driven 4d epic-close doesn't hang on a bucket issue. Most items are 1:1 and carry `gh_issue:` instead — `split_from:` absent is the common case. See `Decisions/foundation - Split member 1-to-1 issue minting`.

### Optional `gate_check:` field — the external-gate predicate

**Rule:** any external/cross-plan gate riding `notes:` ("don't start until #N lands") MUST carry a `gate_check:` — a machine-checkable predicate on the **consumable** (the file/artifact/count the gated item needs), never on the upstream tracker's closed-state. *"Issue closed" ≠ "dependency consumable exists."* <!-- cite: PS.6 incident:F#492 -->

The schema forbids cross-plan `after:` refs, so an item that must wait on work **outside this plan** (another plan's leg, an unplanned upstream issue) records that gate as **prose in `notes:`** — `"Do not start until #380 lands"`. Prose is unverifiable: a reader (or `/build`) can only *infer* whether the gate lifted, and the cheapest inference — "the issue is closed" — is **wrong**, because **"issue closed" ≠ "dependency consumable exists."** An issue can close the *data-capture* half of its work while explicitly deferring the *product-wiring* half, so the consumable the gated item actually needs still doesn't exist.

`gate_check:` makes the gate **machine-checkable**: a command or file-check on the **consumable, not the tracker** — the artifact / file / schema / count the gated item actually depends on, evaluated directly. Examples:

```markdown
  - notes: External gate — do not start until the roster lands (#380).
  - gate_check: "configs/artists.toml lists >=40 artists"
```
```markdown
  - gate_check: "test -f build/schema.json && jq -e '.version==2' build/schema.json"
```

Write the predicate against what makes the gated work *possible*, never against the upstream tracker's state. A `gate_check:` that just re-states "#380 is closed" defeats the purpose — pin the **consumable** (`configs/artists.toml lists >=40 artists`), which is true only when the dependency is genuinely *consumable*, not merely when its issue flipped closed.

**This prevents the ELT #492 false gate-lift.** During the ELT run, item #492's gate rode `notes:` as prose ("don't start until #380 lands"); the orchestrator declared it lifted from issue state alone — *"#380 CLOSED → roster gate lifted"* — but #380 had closed the data capture while deferring product wiring (`configs/artists.toml` still listed 3 of 40 artists). #492 was re-opened on that false premise, re-parked, two missing prereqs filed (#519/#520), and the leg re-decomposed — the costliest replan of the run. A `gate_check: "configs/artists.toml lists >=40 artists"` would have read **false** at the gate-lift decision and stopped it. `/assess` emits the predicate alongside the prose gate; `/build` Step 3a runs it instead of inferring lift from issue-closed-state.

### Optional `activation:` block — the inward activation predicate

**Rule:** `activation:` declares how `/build` confirms *this item's own* output is wired into the running path (not merely built). `class: A` (in-repo) carries a `proof:` command run at Step 3e.6 — the only class enforced today; `class: B`/`C` are ledger-recorded (auto-discharge machinery pending, temperloop#317). **Required on a product-source item** — `kind: code` whose `files:` touch `scripts/`/`workflows/`/`claude/` (rule 14). <!-- cite: PS.7 incident:K#317 -->

`gate_check:` points **outward** — "has a *dependency's* consumable materialized." `activation:` is its **inward twin**: "is *this item's own* output now wired into the running path?" It exists because the pipeline's definition of done — worker self-checks `acceptance:` → static gate → CI green → PR merged — measures the *artifact*, never the artifact's *integration*. A runner that is correct but never registered, a flag built but never flipped, a rollup computed but never rendered all satisfy "done" while staying dormant. See `Decisions/temperloop - Activation-completeness contract`.

Activation is a taxonomy of three classes, keyed by **where** the proof lives and **when** it is observable:

```markdown
  - activation:
    - class: A
    - proof: "grep -q GeminiRunner evals/runners/__init__.py"
```

- **`class: A` — synchronous / in-repo.** Flag flip, dispatch-table registration, call-site wiring, render-a-rollup. Proof lives in the same repo and is observable at merge. Carries a **`proof:`** predicate — a shell command that reads **false until the built code is genuinely reachable**, pinned on the *reachability surface* (the `__init__.py` entry, the config value, the rendered panel), never on "the code exists." `/build` runs it at Step 3e.6. The `proof:` predicate is **mandatory** on a class-A block, not a preferred-but-optional field: **rule 13** fails validation when it is missing, and 3e.6 has **no fallback actor** to drive in its place — an omitted `proof:` stops the plan at Step 1 rather than degrading the gate to a no-op (temperloop#1451, which deleted 3e.6's route to a fallback capability that never shipped). **This is the only class enforced today** (temperloop#317 Level 1).

  **Absence-asserting `proof:` predicates — the multiline-safe idiom (temperloop#944).** A `class: A` proof that asserts a phrase is *gone* (the negated form, `! grep -q '<phrase>' <file>`) is silently vacuous the moment the target phrase line-wraps: `grep` matches only within a single physical line, so a wrapped phrase can never match, and `! grep -q` reads **Pass** whether or not the removal happened — green even on an untouched tree, the worst direction for a gate to fail in (silently and positively). The wrap point moves whenever an unrelated edit re-flows the surrounding paragraph, so a proof sound when authored can go vacuous later with nothing signalling the transition. Live instance: `! grep -q 'batched draft is still fine' claude/commands/workshop.md` (temperloop#930) passed on `main@f41a93a` *before any work happened*, because the target phrase was wrapped across lines 386/387 at that commit. Author an absence proof against the **portable, wrap-immune** form instead — fold the file to one line and collapse whitespace before matching, so no phrase can straddle a boundary `grep` can't see across, and a phrase reflowed to a *different* wrap point still matches:

  ```markdown
    - proof: "! tr '\n' ' ' < claude/commands/workshop.md | tr -s ' ' | grep -q 'batched draft is still fine'"
  ```

  Verified portable across BSD (macOS) and GNU `tr`/`grep` — no `pcregrep`/`perl -0777` dependency. A **presence** proof (the `GeminiRunner` example above) needs no such treatment: `grep -q` already reads Pass the instant *any* line contains the target, so wrapping can only produce a false **negative** there (a proof that wrongly reads Fail on genuinely-present code), never grep's false-**positive** direction — the wrap hazard is asymmetric to absence proofs specifically, which is why only they require this form. `/assess` authors every absence-asserting `proof:` field in this form. `/build` 3e.6 additionally runs a merge-base control pass on any absence-asserting predicate — a proof that already passes before the work happened proves nothing — see `claude/commands/build.md` § 3e.6.

- **`class: B` — propagation-gated / cross-repo.** A kernel feature is live only after a release + each consumer's `make update-kernel` + `make install`. Discharged **per-consumer** against an installed-kernel-version watermark, on the `Context/pipeline - pending activations.md` ledger — not at merge. *(Machinery lands with temperloop#317; a `class: B` block records intent today but is not yet auto-discharged.)*
- **`class: C` — time-deferred / soak.** A LaunchAgent firing on cadence, a rollup accumulating data, cross-host reconciliation. Discharged by a periodic liveness poll after a soak window (`env-reconcile.sh`'s `AGENT_STALE` is the launchd sensor), also via the ledger. *(Same status as class B — intent recorded, auto-discharge is temperloop#317.)*

The block stays **optional** on any item that isn't product-source (below), and B/C discharge machinery is still landing (temperloop#317), so authoring a B/C block is never forced ahead of the machinery that honors it. When the block **is** present, rule 13 enforces its internal consistency (class ∈ {A,B,C}; a class-A block must carry `proof:`).

**Rule 14 — required on product-source items.** A **product-source** item is `kind: code` (not `kind: spike`) whose `files:` list includes at least one path under a shipped kernel/product-machinery root — `scripts/`, `workflows/`, or `claude/`. Such an item MUST carry an `activation:` block; omitting it fails validation (rule 14, below). This is the inward-enforcement counterpart to rule 11's outward `gate_check:` requirement: rule 11 forces a *dependency's* gate to be machine-checkable, rule 14 forces *this item's own* activation to be declared at all. An item is exempt from rule 14 when:

- it is `kind: spike` (verdict-only, no PR, no running-path integration to activate);
- it is **docs-only** — every `files:` entry lives under `docs/`, or is a `*.md` path outside `claude/` (a doc change under `claude/` — e.g. `claude/plan-schema.md` itself — still counts as product-source, since `claude/` is shipped command/schema machinery, not prose-only docs); or
- the item has **no `files:` entries at all**, or none of them fall under `scripts/`, `workflows/`, or `claude/` (a decision-only or non-product-source `kind: code` item).

**Grandfather cutover (non-BREAKING release discipline).** Rule 14 is a new hard-fail on an existing optional field, which would otherwise break an already-`approved` in-flight plan on its next `/build` resume — exactly what the kernel's non-BREAKING release principle forbids. The gate: a plan whose frontmatter `date:` (§ Frontmatter) is present and **strictly before** the cutover constant `RULE_14_CUTOVER_DATE` (defined once, in `workflows/scripts/build/plan.sh`, currently `2026-07-17`) is **exempt from rule 14 entirely**, regardless of its items' product-source status — so a plan authored before rule 14 shipped keeps validating unchanged across the rollout. A plan with **no** `date:` frontmatter is never grandfathered (treated as on-or-after the cutover). Bump the constant only when deliberately re-cutting the boundary, never to silence one plan's failure.

### Optional `cost:` block — the expensive-work flag (foundation#1059)

**Rule:** add a `cost:` block to flag an item with outsized *execution* spend (deep-research, large agent fan-out, big eval), so it's visible at the approval surface instead of hiding in a plain-looking item. **Presence is the binary "expensive" flag**; `because:` (the driver) is required (rule 16), `budget:` optional. Advisory/display-only — drives no control flow. <!-- cite: PS.10 incident:F#1059 -->

Most plan items are cheap and uniform to execute. A few are **not** — a run of the deep-research harness, a `Workflow` that fans out large numbers of parallel subagents, a big eval/benchmark sweep — and on the approval surface such an item looks identical to a one-line typo fix, so a large token/time spend can hide inside an innocuous-looking plan item. The `cost:` block makes that visible **before** approval.

```markdown
  - cost:
    - because: agent-fanout          # REQUIRED — the cost driver
    - budget: 500000                 # optional — intended token ceiling
```

An **inline shorthand** is accepted for a hand-authored one-liner: `- cost: agent-fanout` opens the block and takes the inline value as the `because:` (so a mis-remembered form is *flagged*, not silently dropped). A nested `- because:` overrides an inline value; a bare `- cost:` with no `because:` anywhere fails rule 16.

- **Presence is the binary flag.** A `cost:` block on an item means "this item's *execution* carries outsized spend"; its absence means standard. There is deliberately **no graded tier or token estimate** — magnitude at plan time is unknowable (a fan-out's real cost is decided at runtime), so a scale or a number would be fabricated precision that erodes trust in the flag. The honest signal is a **tripwire**: *look at this one before you approve it.*
- **`because:` is required (rule 16)** — the cost driver, so the display says *why*: `deep-research` \| `agent-fanout` \| `large-eval` \| a short freeform phrase. "Expensive" with no reason is uninformative.
- **`budget:` is optional** — an intended token ceiling. Magnitude lives here and is honest because it is a target you *set*, not an estimate you *guess*; it composes with the `Workflow` `budget` mechanism (a per-turn token target), so an expensive-flagged item is the natural place to attach one.
- **Advisory / display-only.** Unlike the frozen orchestrator fields, `cost:` drives no `/build` control flow — `/build` surfaces it at the per-item approval preview (`💰 expensive: <because>[ · budget: N]`) and otherwise ignores it. `/assess` populates it (an explicit author flag carried forward, plus light detection of a deep-research / fan-out / large-eval item; see `claude/commands/assess.md`).

### Orchestrator-written fields (`pr:`, `pushed_sha:`)

`/build` writes these onto an item as it works — authors don't set them. `pr:` (the open PR number) and `pushed_sha:` (the worker commit pushed to the branch) are recorded at PR-create time (3f), *before* the CI watch, so a crash leaves a recoverable pointer: Step 1 resume re-attaches to `pr:` instead of re-spawning a worker, and Step 0.5 reconciles open PRs against it.

**`merge_blocked:` — the same shape, for a hold rather than a pointer** (temperloop#2083). `/build` stamps `  - merge_blocked: <value>` on a parked `[m]` item at 3h step 1 when that item's winning dual-build PR carries no *verified* `Model-comparison-arms:` trailer (today the single literal `arms-trailer-unstamped`). Step 4 subtracts every item carrying it from the merge gate's selected set, reading **this sub-line** rather than the run's in-memory level summary — that is the whole point of persisting it: a crash or a `/build <plan>` resume between Step 3 and Step 4 would otherwise see an ordinary `[m]` item with an ordinary `pr:` line and merge it unstamped (ADR 0040). A green, `OPEN` PR is exactly what a blocked item looks like, so Step 1.4's resume revalidation carries the flag forward unchanged; only landing and confirming the trailer clears it.

## Orchestrator-written `## Questions` section (ask-at-gate deferred decisions)

**Rule:** `/build` writes this section (authors don't) — the **in-run, ephemeral** queue for `ask-at-gate` decisions (non-blocking mid-run choices that carry an obvious default). The orchestrator appends an entry and proceeds on its default, then surfaces the whole batch as ONE question at the next level merge gate. <!-- cite: PS.12 guard:claude/commands/build.md -->

`/build` writes this section onto the plan note as it runs — authors don't author it; it is created on demand the first time a deferrable in-run decision arises. It is the **in-run, ephemeral queue** for **`ask-at-gate`** decisions: non-blocking choices that arise *during an active run* (e.g. "create N tracking issues?", "auto-fix the safe reconcile divergences?", a per-PR conflict disposition) which carry an **obvious default** and so need not interrupt the level. Instead of issuing an interrupting `AskUserQuestion` mid-level, the orchestrator **appends one entry here** and proceeds on the default; the whole batch is then surfaced as ONE question at the next **level merge gate** (Step 4), before merge consent is recorded. See the severity taxonomy `[[Context/foundation - AskUserQuestion severity taxonomy]]` for which sites defer here vs. stay blocking.

This section is **distinct** from the unattended/check-in pending-decisions surface (#236): that one is cross-run, durable, and read at the daily check-in; this one is per-run, drained at *this* run's next gate. The only thing the two share is the convention below (default-if-unanswered) — a contract, not a schema.

### Shape

```markdown
## Questions

- [ ] `step: 2.5` `item: gemini-retry-504` — Create a tracking issue for this item? **default: create**
  - auto-proceed: if unanswered at the level merge gate, the default (create) is taken — no stall.
- [ ] `step: 0.5` — Auto-fix the safe reconcile divergences (adopt orphan PR #210, prune dead worktree `…/foo`)? **default: don't auto-fix (report only)**
  - auto-proceed: unanswered → default (leave as-is) at gate.
- [x] `step: 4c` `pr: 205` — Conflicting PR #205 disposition? **default: leave open for manual rebase** → answered: re-spawn worker to rebase
```

Each entry is **one line** with a checkbox sentinel plus a `## Questions`-local one-line `auto-proceed:` sub-line stating what the default does:

- **Checkbox** — `[ ]` unanswered (default still pending), `[x]` answered/resolved (default overridden or confirmed at the gate).
- **`step:`** (required) — the originating build step that deferred the question (e.g. `2.5`, `2.6`, `0.5`, `4c`), so the gate can route the answer back to the right action.
- **`item:`** / `pr:` (optional) — the plan-item slug or PR number the question is scoped to, when per-item; omitted for run-wide questions.
- **The question text**, then **`default: <value>`** in bold — the value taken if the entry is unanswered when the gate resolves. **Every entry MUST state its default** — an `ask-at-gate` entry with no default is a defect (it cannot be deferred, because deferral needs a value to proceed with meanwhile). This is the pinned convention from the severity taxonomy.
- **`auto-proceed:` sub-line** (required) — one line spelling out what taking the default does, so an unanswered entry resolving at the gate is legible after the fact.

### Lifecycle

- **Append** (any time during a level): the originating step appends an `[ ]` entry instead of interrupting, then proceeds on the entry's `default`.
- **Drain at gate** (Step 4): the orchestrator reads every `[ ]` entry and surfaces the batch as ONE question before merge consent is recorded — in the **timed** gate regime, an entry still `[ ]` when the window elapses takes its `default` (consistent with the timed-gate "absence of objection = consent" auto-proceed); in the **modal** regime, the entries are presented alongside the merge `AskUserQuestion`. Either way, **an unanswered entry at gate resolution takes its default — never a silent stall.**
- **Resolve**: tick `[ ]` → `[x]` and append `→ answered: <choice>` (or `→ default taken: <value>`) when the gate resolves it, so a resumed run never re-asks a settled question.

## Orchestrator-written `## Merge gate log` section (merge-consent lines)

**Rule:** `/build` writes this (authors don't) — one **append-only** line per level merge-consent event, recorded at consent time. It is the durable pointer that makes **resume-without-re-consent** mechanical on the MANAGED merge backend. <!-- cite: PS.13 guard:claude/commands/build.md -->

`/build` appends this section onto the plan note as it runs — authors don't author it. It is the **durable record of merge consent**, one line per level-consent event, written **at consent time** (modal approval given, timed window elapsed with no objection, or the headless immediate-merge re-poll passed) and **before the first merge call of that level**, via `vault_append` (a reliable EOF op). Like `pr:`/`pushed_sha:`, it exists so a crash leaves a recoverable pointer — here, the pointer that makes **resume-without-re-consent** mechanical on the MANAGED merge backend (`/build` 4b "Merge — MANAGED backend" resume state table): a resumed run that finds a consent line covering a still-`[m]` item's PR re-enters the managed loop without re-asking the operator; absent a covering line, the level takes a fresh gate. No PR/issue label carries this state — consent and resume ride the plan note alone, cross-checked against a live PR probe.

### Shape

```markdown
## Merge gate log

- consent: level 0 · 2026-07-04T18:22:05Z · mode: modal-approved · PRs: #17 #18 #19
- consent: level 1 · 2026-07-05T02:10:44Z · mode: timed-elapsed · PRs: #21
```

One line per consent event, four fields:

- **`level <k>`** — the dependency level the consent covers.
- **Timestamp** — ISO-8601 UTC, the moment consent was recorded.
- **`mode:`** — how consent arose: `modal-approved` (explicit operator approval at the modal gate) | `timed-elapsed` (timed window elapsed with no objection) | `headless-immediate` (`PIPELINE_OPERATOR_ABSENT=1` immediate-merge branch, re-poll passed).
- **`PRs:`** — the **exact** consented PR list. Consent pins this list: a PR not in it (or work re-pushed under a new PR number) is **not** covered and must earn consent at a fresh gate. A level gated more than once (e.g. an EJECTED item re-parked and re-gated) appends a **new** line — lines are append-only, never edited.

**As-you-go consent uses this same line, not a second grammar** (`/build` Step 3h.5, temperloop#1026 — a step scoped to `/build`'s `--no-workflow` **conversational path only**, temperloop#1452, so a default Workflow-path run simply never writes one of these; the grammar below is unchanged either way). An item that merges at its own green rather than at the level boundary records a consent line with the *same* four fields and the *same* `mode:` vocabulary — its `level <k>` is the level the item belongs to and its `PRs:` list is the single PR consented. Because a level can then carry several consent lines (one per as-you-go merge, plus one for whatever the boundary gate consents), the append-only rule is what keeps them all readable, and the resume routing is unchanged: an item is covered iff *some* line for its level names its PR. A `[>]` item with no covering line is a corrupted state and takes a fresh gate.

## Orchestrator-written `## Run scope` section (keystone-spike halt boundary)

**Rule:** `/build` writes this (authors don't), only for a plan carrying a `keystone: true` spike — it records the RUN 1 (spike) halt / RUN 2 (build) resume boundary. Its job is **audit legibility, not resume control** (resume rides the spike's own `[v]` sentinel). <!-- cite: PS.14 incident:K#526 -->

`/build` appends this section onto the plan note **only when a plan carries a `keystone: true` spike** (§ Optional `keystone:` field; temperloop#526) — authors don't author it. It is the **durable record of the keystone-spike review halt**: the boundary at which a RUN 1 (spike) stopped so the operator could review a contract-reshaping verdict before the RUN 2 (build) of dependent levels. Like `## Merge gate log`, it exists so the halt survives a crash and a resumed run can tell which side of the boundary it is on. Written via `vault_append` (a reliable EOF op) at the moment the halt fires (RUN 1) and again when the run resumes past it (RUN 2).

Its load-bearing job is **audit legibility, not resume control** — resume correctness rides the spike's own `[v]` sentinel (a keystone spike already `[v]` at run start did not transition *this* run, so no halt re-fires; the re-run itself is the operator's approval to proceed). The `## Run scope` lines make the two-run split and the operator's review point legible after the fact, especially on an `--unattended` run where the halt parked the plan and posted a decision issue rather than blocking a live operator.

### Shape

```markdown
## Run scope

- RUN 1 (spike) · 2026-07-23T14:02:11Z · keystone spike `provider-contract-spike` (level 0) `[v]` — HALTED before levels 1–3; verdict: [[Decisions/temperloop - provider contract reshape]] · review then re-run /build to proceed
- RUN 2 (build) · 2026-07-24T09:15:40Z · resumed after operator review — building levels 1–3
```

One line per run boundary:

- **`RUN <n> (<phase>)`** — `RUN 1 (spike)` for the halt, `RUN 2 (build)` for the resume. A plan with several keystone spikes appends a new `RUN k (spike)` / `RUN k+1 (build)` pair per halt — lines are append-only, never edited.
- **Timestamp** — ISO-8601 UTC, the moment the halt fired or the resume began.
- **The halt line** names the keystone spike slug + level, its `[v]` capture, the levels held, and the `verdict:` wikilink the operator reviews. On `--unattended` it also names the posted decision issue (`decision issue: #N`).

## Status sentinels (in-band tracking)

`/build` mutates the plan note as it goes. The seven sentinel tokens and their meanings are tabled ONCE, in `workflows/scripts/config/ontology-registry.tsv` (`state:plan-sentinel` rows; ADR 0032 (ontology registry is source of truth)) and enforced by `check-ontology-registry.sh` — never restated here. Compact gloss (the registry row is the definition): `[ ]` untouched · `[~]` in-progress · `[m]` merge-pending · `[>]` merging · `[x]` merged · `[v]` verdict-captured · `[-]` skipped. A terminal sentinel carries a trailing record after the title: `— merged in #<pr> (<date>)`, `— verdict-captured <date> (kind: spike — note written + issue routed; no PR)`, or `— skipped <date>: <reason>, see [[Sessions/...]]`.

`[m]` is set by `/build` when an item reaches CI-green inside a dependency-level batch; it transitions to `[x]` (merged) or stays `[m]` (left open at the gate) when the level's batch merge gate fires. `[>]` is the **as-you-go merging** state (`/build` Step 3h.5, temperloop#1026) — set when an item the level gate's *own* regime partition already classes clean-disjoint records its consent and issues its merge without waiting for the level boundary; it transitions to `[x]` on confirmed `MERGED`, or is demoted back to `[m]` if the merge times out, ejects, or conflicts. **Only `/build`'s `--no-workflow` conversational path ever produces it** (temperloop#1452: Step 3h.5 is scoped to that path, because the Workflow neither merges nor writes the plan note) — a default Workflow-path run parks every item `[m]` instead. It stays a first-class part of this schema regardless: `plan.sh writeback` accepts it, resume routing reads it, and a note written by a conversational run must remain readable by any later run. It is a **distinct** state, never a re-used `[m]`: `[m]` means *parked, awaiting consent*, `[>]` means *consented, in flight*, and the level gate re-consents the former but only confirms the latter. `[v]` is the terminal state for `kind: spike` items — set on verdict-capture (note written + issue routed), it never enters the merge gate. Grep `\- \[~\]\|\- \[m\]\|\- \[>\]` across the vault to find anything in flight.

## Validation rules (enforced by `/build` before execution)

Fail fast if any of:

1. Frontmatter `status` is `draft` — force the user to mark `approved`.
2. Any item has no `acceptance:` block — workers need a self-check signal.
3. Any item has no `slug:` — required for stable `depends-on` references.
4. Any item's `branch:` doesn't match `<type>/<slug>` where type ∈ {feat, fix, chore, refactor, docs, test}.
5. `depends-on` references a slug that doesn't exist in this plan, or one that is not yet in `[x]` state when the dependent item is about to start. (neither `[m]` nor `[>]` satisfies a `depends-on` — the dep must be merged into main, not merely consented and in flight, before the dependent's worker can build on top of it.)
6. A `source:` wikilink target doesn't resolve (analysis doc was moved/renamed since planning).
7. `gh_issue:` (when present) must be a positive integer — fail otherwise; do not silently coerce.
8. `after:` references a slug that doesn't exist in this plan, OR the union of `depends-on` + `after` edges contains a cycle. (Unlike `depends-on`, an `after:` edge is satisfied by *any* terminal state — `[x]`, `[-]`, or `[v]` — not only `[x]` merged.)
9. An item's `acceptance:` block still contains the placeholder `- (no acceptance criteria derivable from source — fill in during review)`. The placeholder is a valid *authoring* signal but a *fatal* execution signal — fill it in before approving. (`epic:` absent is never a failure — it is optional and only meaningful on board-enabled projects.)
10. An item carries **both** `gh_issue:` and `split_from:` (mutually exclusive), or a non-empty `split_from:` whose value isn't a `#<positive-integer>` issue ref. A split item must leave `gh_issue:` unset so Step 2.5 mints it a fresh per-item issue (#73). This mutual exclusion is an **always-true invariant**, including across a resume: `build` Step 2.5 **swaps `split_from:`→`gh_issue:` atomically** — the same patch that writes the minted `gh_issue:` also *removes* `split_from:`, restoring the 1:1 item↔issue end-state — so an item is never left carrying both, and a resumed run's re-validation of this rule always passes. Worked before/after of one split item across Step 2.5: `split_from: #40` / no `gh_issue:`  →  `gh_issue: #57` / no `split_from:`.
11. An item declares an **external / cross-plan gate in `notes:`** (a prose gate of the "don't start until #N lands" form — the schema forbids a cross-plan `after:` ref, so such a gate can only ride `notes:`) but carries **no `gate_check:` predicate**. A prose-only external gate is a **validation smell**: it is unverifiable, so a gate-lift can only be *inferred* from issue-closed-state — the ELT #492 trap, where "#380 CLOSED → roster gate lifted" was wrong because #380 deferred product wiring ("issue closed" ≠ "dependency consumable exists"). Every external/cross-plan gate MUST carry a machine-checkable `gate_check:` on the **consumable** (e.g. `gate_check: "configs/artists.toml lists >=40 artists"`) that `/build` Step 3a evaluates directly instead of inferring lift from the tracker. (A `gate_check:` is **optional** on an item with no external gate — the requirement is conditional on the prose gate being present.)
12. `repo:` (when present) must match `owner/repo` shape — a single `/` separating two non-empty segments of `[A-Za-z0-9_.-]+`, no leading `#`, no issue number. Fail otherwise; do not silently coerce or strip. (`repo:` absent is never a failure — it is optional and defaults to the plan's home repo.)
13. An item declares an `activation:` block whose `class:` is not one of `A` \| `B` \| `C`, **or** a `class: A` block that carries no `proof:` predicate. Class A is the synchronous in-repo activation check `/build` runs at Step 3e.6, so it must be machine-checkable — like `gate_check:`, but pinned on *this item's own* reachability surface (the `__init__.py` entry, the flipped flag, the rendered panel) rather than a dependency's. Class B/C are ledger-discharged (temperloop#317) and need no `proof:`. (An `activation:` block is **optional** — the requirement is conditional on the block being present; a `class: A` block specifically must carry `proof:`.)
14. A **product-source** item — `kind: code` (not `kind: spike`) whose `files:` list includes at least one path under `scripts/`, `workflows/`, or `claude/` — carries **no `activation:` block**. Fail unless the item is exempt (`kind: spike`; docs-only — every `files:` entry under `docs/` or a `*.md` outside `claude/`; or no `files:` entry touches `scripts/`/`workflows/`/`claude/`) **or** the plan is **grandfathered** — its frontmatter `date:` is present and strictly before the cutover constant `RULE_14_CUTOVER_DATE` in `workflows/scripts/build/plan.sh` (currently `2026-07-17`); a plan with no `date:` frontmatter is never grandfathered. See § Optional `activation:` block for the full predicate and grandfather rationale. This is the inward-enforcement counterpart to rule 11 (which forces a *dependency's* gate to be machine-checkable) — rule 14 forces *this item's own* activation to be declared at all, closing the "correct but never wired in" gap the activation-completeness contract (`Decisions/temperloop - Activation-completeness contract`) exists to catch.
15. An item carries a `keystone:` field whose value is **not `true`**, OR a `keystone: true` marker on an item that is **not `kind: spike`** (default `kind` is `code`). `keystone: true` is the spike-only marker for the keystone-spike review gate (temperloop#526) — `/build` halts after a keystone spike's verdict for operator review before dependents build. It is meaningless on a `code` item (which merges through the normal gate), so a `keystone:` on a non-spike item is a plan defect; an absent/empty `keystone:` is the common case (a routine spike on today's autonomous path). See § Optional `keystone:` field.
16. An item carries a `cost:` block but **no `because:`** entry naming the cost driver. The `cost:` block flags outsized execution spend (foundation#1059) and its presence is the binary "expensive" flag; a bare flag with no reason is uninformative at the approval surface, so `because:` (`deep-research` \| `agent-fanout` \| `large-eval` \| a short freeform phrase) is required. `budget:` stays optional. See § Optional `cost:` block.

> `## Problem` and the grouped `## Summary` are an **authoring standard, not a validation rule** — `/build` does not fail a plan that lacks them, so plans authored before this convention still execute on resume.

## Worked example

```markdown
---
tags: [plan, project/stagefind]
date: 2026-05-16
source_kind: claude-stamped
source_session: 784be64a
last_verified: 2026-05-16
sources:
  - "Sweeps/2026-05-15 tier-2 sweep results.md"
status: approved
---

# stagefind - 2026-05-15 sweep follow-up

## Problem
The tier-2 sweep surfaced three independent reliability gaps in the eval runners: upstream 504s aren't retried, the cache key changes every run so nothing is reused, and one runner silently ignores `--max-items`. Together they make sweeps flaky and slow and undermine trust in the numbers.

## Summary
- **Make the runners resilient and reproducible.**
  - **L0** — Add exponential-backoff retry for Gemini 504s. (#4567)
  - **L1** — Derive the cache key only from (prompt, model, params) so reruns hit cache.
- **Make the CLI honor its flags.**
  - **L1** — Respect `--max-items` in the batch runner (currently parsed but ignored).

Build order: L0 first → L1 last; items in the same level ship together.

## Sequencing notes
The cache-miss fix touches the same runner registration code as the max-items fix — do `gemini-retry-504` first, then `cache-key-stability` and `respect-max-items` can go in parallel.

## Items

- [ ] **Gemini runner: retry on 504** `slug: gemini-retry-504` — add exponential-backoff retry for upstream 504s
  - branch: `fix/gemini-retry-504`
  - size: S
  - model: opus                       # stamped: size S + kind code → opus (absent = inherit session model)
  - source: [[Sweeps/2026-05-15 tier-2 sweep results#Finding 4: provider timeout fallback]]
  - gh_issue: 4567                    # tracked in the repo; PR body emits `Closes #4567`
  - files: `evals/runners/gemini.py`
  - acceptance:
    - Retries on 504 with 1s/2s/4s backoff (3 attempts total)
    - Existing tests pass; new test covers the 504 retry path
    - No change to runner public API
  - notes: see [[Mistakes/stagefind - silent provider timeouts]] for prior approach that masked errors

- [ ] **Stabilize cache key across runs** `slug: cache-key-stability` — cache key currently includes a timestamp, defeating reuse
  - branch: `fix/cache-key-stability`
  - size: M
  - depends-on: gemini-retry-504
  - source: [[Sweeps/2026-05-15 tier-2 sweep results#Finding 7: 0% cache hits in tier-2]]
  - files: `evals/cache.py`, `evals/runners/__init__.py`
  - acceptance:
    - Cache key derived only from (prompt, model, params) — no clock-dependent inputs
    - Tier-2 sweep shows >80% cache hits on second consecutive run
    - Existing cache tests pass; new test asserts key stability across two builds 1s apart

- [ ] **CLI: honor `--max-items` in batch runner** `slug: respect-max-items` — flag is parsed but ignored
  - branch: `fix/respect-max-items`
  - size: S
  - depends-on: gemini-retry-504
  - source: [[Sweeps/2026-05-15 tier-2 sweep results#Finding 9: --max-items ignored by batch runner]]
  - files: `evals/cli.py`, `evals/runners/batch.py`
  - acceptance:
    - `--max-items N` truncates the input set to N before dispatch
    - New CLI test asserts truncation; existing tests unaffected
```

## Cross-references

- Decision: `Decisions/foundation - Plan-note schema`
- Decision: `Decisions/foundation - Plan schema in claude config (out of the vault)`
- Decision: `Decisions/foundation - Approval-poll handoff for batch workflow`
- Kernel-vs-overlay routing (the `repo:` field's motivating case): `claude/CLAUDE.kernel.md` § Kernel vs overlay routing rule
- Convention: `Decisions/foundation - Branch naming convention`
- Consumer command: `claude/commands/build.md` (deployed `~/.claude/commands/build.md`)
- Producer command: `claude/commands/assess.md` (deployed `~/.claude/commands/assess.md`)
