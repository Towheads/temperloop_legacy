# Versioning

Canonical versioning policy for temperloop (the kernel). This is the single
source of truth for **when** a release bumps major/minor/patch and **what**
each bump signals — to a stranger vendoring the kernel, and to the machinery
that consumes it (`update-kernel`, `kernel-drift-check`, the Pages
version-switcher). The `CHANGELOG.md` preamble and
`workflows/scripts/kernel/kernel-repo-layout.md` § Release-tag convention
defer here rather than restate the rule.

## The core idea: version by contract surface, not by code

The kernel is **vendored, not installed** — an adopter pulls it as a `git
subtree` at a tag (`make update-kernel KERNEL_TAG=vX.Y.Z`), not as a package
dependency. So the thing a version has to describe is not a function
signature; it is the **contract surface an overlay couples to**. A change is
"breaking" exactly when a downstream overlay or a stranger's config must
change to keep working — nothing else.

### The contract surface

These are the seams an adopter depends on. A change to any of them is a
contract-surface change (minor-or-breaking, never a patch):

| Surface | What couples to it | Where it lives |
|---|---|---|
| **Board adapter interface** | overlay scripts calling `board_resolve_item` / `board_resolve` / `board_item_list` / `board_set_*`, the `--board N` axis, board commands (`claim`/`release`/`worklist`/`reconcile`/`capture`/`milestone`) | `workflows/scripts/board/lib/board.sh`, `boards.conf` |
| **Pipeline command contracts** | operators running the slash commands; their documented steps + `plan-schema.md` shape | `claude/commands/*.md`, `claude/plan-schema.md` |
| **Hook names + signatures** | a machine's installed hooks; anything keying off their I/O contract | `claude/hooks/*.sh` |
| **Quality-gate contract** | CI + local gate parity: the required job name `checks`, the `KERNEL_GATES` set, the Capture/Backstop + PR-body-lint registry formats | `scripts/quality-gates.sh`, `.github/workflows/ci.yml` |
| **CLI surface** | callers of `bin/temperloop` and its subcommands (`init`, `eject`, `testbed`, `report`, `feedback`, `baseline-snapshot`, `configure`, `config`, `install`, `uninstall`, `update`) (the `bin/foundation` compat shim rode this row through the temperloop#165 rename window; at v0.19.0 its **forwarding removed; file retained as a refusing tombstone** — never say "removed": a pre-v0.19.0 install left a `~/.local/bin/foundation` symlink pointing at that file, and `temperloop update` moves the checkout underneath the symlink, so deleting the file would yield a dangling ENOENT exactly where the operator needs to be told the name changed. Retiring the stale symlink is MANUAL — `temperloop uninstall` *prints* the `rm -f` but cannot remove it, since the symlink is bootstrap footprint predating the install manifest) | `bin/temperloop`, `bin/foundation` (the refusing tombstone — retained, not deleted), `bin/subcommands/*` |
| **Shipped version stamp** | the release artifact's own version — the repo-root `VERSION` file (bare `x.y.z`) that `temperloop version` reports. **Bumped in the tagged commit** as part of the cut (kernel-repo-layout.md § Release-tag convention); `test_version_embedding.sh` fails the build if it drifts from the tag | `VERSION`, `bin/lib/common.sh` (`temperloop_resolve_version`) |
| **Compose / pin seam** | the overlay's `install-claude` compose (`CLAUDE.kernel.md` + overlay), `.kernel-pin` format, the kernel-manifest classification | `workflows/scripts/install-claude-md.sh`, `.kernel-pin`, `kernel-manifest.txt` |
| **Published schemas/contracts** | anything a stranger reads to conform: `plan-schema.md`, `report.contract.md`, `knowledge_store.contract.md`, `tracker.contract.md`, `lexicon.tsv` columns | various `*.contract.md`, `*-schema.md` |
| **Setting registry** | callers reading `workflows/scripts/config/setting-registry.tsv`'s row shape (`name\|default\|type\|layer\|owning-script\|doc`) or the union-aware parse helper's function signatures/output shape — `temperloop config list`, the registry↔shell equality lint, and any overlay extension TSV | `workflows/scripts/config/setting-registry.tsv`, `workflows/scripts/config/setting-registry-lib.sh` |
| **Machine-surface install manifest** | callers reading/writing `${XDG_STATE_HOME:-$HOME/.local/state}/temperloop/install-manifest.json`'s `schema_version` / `paths[path].{state,backup_path}` shape, or the lib helper function signatures/output shapes — the not-yet-built `temperloop install`/`uninstall` subcommands, and any future doctor-style reader | `workflows/scripts/install/manifest.sh` |
| **Kernel engineering-principles criteria** | review agents and `/build` workers judging a diff against the declared cross-language criteria; a project's `§ Principles` section merging with (extending, replacing, or excluding from) the kernel set per the merge semantics stated in the file's own header | `claude/engineering-principles.md` |
| **Dual-build ledger row schema** | anything reading `.temperloop/model-comparison/dual-build/rows.jsonl`'s per-item, per-arm row shape (`schema_version`, `seq`, `tier`/`model`/`arm`, `base_sha`/`head_sha`, `gate`, `cost`, `judge`, `pick`, `override`, `loss_reason`, `cross_read_attempted`, `guard_armed`, the optional `repo`) or its sibling `calibration-pairs.jsonl`/`calibration.json`/`null-floor.json` shape — the report producer, a future cross-repo rollup, or a manual analysis; a field addition is additive, a field removal or type change is breaking | `workflows/scripts/model-comparison/dual-build-ledger.sh` (the schema's own documented header), `workflows/scripts/report-producers/dual-build` |
| **The changelog gate itself** | every other row in this table — the completeness/section-scope enforcement PR authors rely on, `update-kernel`'s BREAKING-marker scan of the CHANGELOG range, and the fragment-collision guarantee `changelog.d/` exists to provide; a change to any of these paths can silently narrow or break what every other contract-surface PR is required to do | `workflows/scripts/check-changelog-entry.sh`, `workflows/scripts/lib/changelog.sh`, `scripts/assemble-changelog.sh`, `VERSIONING.md` |

**This table is machine-read.** `workflows/scripts/check-changelog-entry.sh`
(the `## [Unreleased]` completeness gate in `scripts/quality-gates.sh`'s
`KERNEL_GATES`, temperloop#960) parses the backticked paths out of the **"Where
it lives"** column at run time and uses exactly that set to decide whether a
change touches contract surface and therefore owes a CHANGELOG entry. It reads
this table rather than keeping a second copy of the definition, so **adding a
row here extends the gate for free** — and restructuring the table, renaming the
`### The contract surface` heading, or moving the paths out of the last column
will make the gate fail loudly (it refuses to run against a table it cannot
parse rather than silently enforce nothing). Keep the shape: one row per
surface, path patterns backticked in the final column.

### "Vendored" vs. "installed" — two different senses (ADR K164 D7)

This document's own "the kernel is **vendored, not installed**" framing
(above) is about **repo integration**: how the kernel's *code* reaches a
downstream tree — a `git subtree` pull at a tag, never an npm/pip-style
package dependency. That sense is unchanged by `temperloop install`
(temperloop#264, the CLI half of the machine-surface install manifest row
in the contract-surface table above): running that subcommand never
touches how the kernel repo itself is consumed, pulled, or pinned.

`temperloop install` is a **separate, machine-scoped** sense of "install"
— it materializes the **machine surface** (`~/.claude/*`, `~/.local/bin/*`,
the composed `CLAUDE.md`, the `gh` call-logger shim) that lets an operator
actually *use* a vendored-or-cloned checkout day to day, per
`links_enumerate()`'s desired state (`workflows/scripts/install/links.sh`).
Every touched path is recorded in the install manifest so a later
`temperloop uninstall` (not yet built) can cleanly reverse exactly what
this run did. Two axes, never conflated:

| Axis | "Vendored" | "Installed" |
|---|---|---|
| What moves | the kernel's **code** (a git subtree pull) | the kernel's **machine footprint** (symlinks/real files under `$HOME`) |
| Direction | into a downstream **repo tree** | onto an operator's **machine** |
| Mechanism | `make update-kernel` / `git subtree` | `temperloop install` (this item) / `temperloop uninstall` (future) |
| Reversible via | `.kernel-pin` + a subtree re-pull | the install manifest (`manifest_restore_from_record`) |

So "the kernel is vendored, not installed" continues to describe the
repo-integration axis exactly as it always has; it says nothing about, and
is not contradicted by, the machine-surface axis `temperloop install` now
covers. The Makefile ships no `install`/`install-env`/`install-claude`
target for the same reason — those depend on `env/*` dotfiles absent from a
kernel-only checkout — so the vendored-vs-installed table above is the
authoritative disambiguation.

Renaming/removing a board function, changing a hook's I/O, renaming the
`checks` job, changing `.kernel-pin`'s format, or dropping a documented
command step are **breaking**. Adding a new board command, a new hook, a new
optional `plan-schema` field, or a new gate that no existing overlay is
required to satisfy is **additive**. Fixing a bug with none of the above is a
**patch**.

**Setting registry, specifically** (finer-grained than the generic rule above,
since a TSV row is itself structured data a caller can depend on at four
different granularities): a **column change** (renaming/removing/reordering
one of the six `name|default|type|layer|owning-script|doc` fields, or a
parse-helper function signature/output-shape change) is **breaking** — every
reader of the row shape must adapt. A **new setting row** (a name no reader
already depended on) is **additive**. A **default-value change on an
existing row** is **minor** — a stranger who dot-sources the previous
default should re-check it, so it is never a bare **patch**, but it doesn't
change the row shape so it isn't breaking either. **Removing an existing
row** — retiring a setting *name* — is **breaking**, and is the case the
other three do not cover: unlike a column change it leaves the row *shape*
completely intact, so nothing a shape-reader parses fails, yet every caller
that sets or reads that name silently gets nothing back. It therefore must
mark its CHANGELOG section `BREAKING` and carry a migration line naming the
replacement name (or stating plainly that there is none). v0.19.0 is the
worked example: closing the two compatibility windows removed **four** rows
— the four DEPRECATED legacy-prefixed env rows superseded by their
`TEMPERLOOP_*` twins in v0.15.0 — with no column change at all.
(`setting-registry.tsv`'s own header already classified its removal this
way, deferring to "the rule above"; this is that rule, now stated.)

**Machine-surface install manifest, specifically** (same three-way split as
the setting registry, applied to the manifest's own JSON shape): a **field/
column change** (renaming, removing, or reshaping `schema_version`,
`state`, or `backup_path` on a path entry, or a `manifest.sh` helper
function's signature/output-shape change) is **breaking** — every reader
must adapt, and per the library's own read-compat stance a reader unable to
parse an older manifest must refuse legibly, naming the schema version it
found, never guess. A **new field** added to a path entry (a name no
existing reader already depends on) is **additive**. A **semantics-only
change** with no shape change (e.g. changing what circumstance sets
`state=preexisting` vs. `created`) is **minor** — the JSON shape is
unchanged, but a reader's assumptions about the field's meaning may need
re-checking, so it is never a bare patch.

## Bump rules

### Pre-1.0 (where we are today)

Strict SemVer reserves the breaking signal for a major bump — unavailable at
`0.x`, where the standard reading is "anything may break, always." That reading
gives a stranger **no** signal, which defeats the point of a version. So
pre-1.0 the kernel keeps `v0.MINOR.PATCH` **but carries the breaking signal in
the CHANGELOG entry**, not in the version number:

| Bump | Trigger | Stranger signal | CHANGELOG marking |
|---|---|---|---|
| **patch** `0.x.Y+1` | fix only; contract surface untouched | safe pull, no action | plain `### Fixed` |
| **minor, additive** `0.X+1.0` | contract surface **grows**; nothing existing changes | safe pull, new capability available | plain `### Added` / `### Changed` |
| **minor, breaking** `0.X+1.0` | contract surface **changes/shrinks**; an overlay must adapt | **touch your overlay/config before pulling** | section header tagged **`BREAKING`** + a `### Changed`/`### Removed` entry that names the migration |

The one rule that makes this work: **a breaking release MUST mark its
CHANGELOG section `BREAKING` and MUST include a migration note.** That marker
is the machine-readable breaking signal for the pre-1.0 world — it is what
`update-kernel` reads (below), and what a stranger greps for before pulling.
The version number alone stays ambiguous at `0.x`; the CHANGELOG resolves it.

### Post-1.0

Standard SemVer, no house rule: **major** = breaking (overlay must adapt),
**minor** = additive, **patch** = fix. The `BREAKING` CHANGELOG marker stays as
a courtesy but the major bump becomes the primary signal.

## Signal to the machinery

The version/CHANGELOG delta is an **actionable** signal, not a bare label:

- **`update-kernel`** — after fetching the target tag, it scans the CHANGELOG
  range `current-pin-tag..target-tag` for a `BREAKING` marker (pre-1.0) or a
  major-version increment (post-1.0). On a breaking delta it **refuses the
  unattended path** and requires an explicit acknowledgment
  (`KERNEL_ALLOW_BREAKING=1` or an interactive confirm), printing the
  migration notes from the marked sections. An additive/patch delta pulls
  without prompting. *(Implemented in `scripts/update-kernel.sh`'s
  breaking-delta gate — temperloop#89, the routed follow-up to the versioning
  spike #79 / PR #88.)*
- **`kernel-drift-check`** — unchanged. It is a byte-identity check (subtree
  tree-hash vs `.kernel-pin`), orthogonal to semver; it answers "is `kernel/`
  the pinned tag?", not "how big is the jump?"
- **Pages version-switcher** (Epic C) — keys off the tag list; no change
  needed, but benefits from the tags now carrying a defined meaning.

## The 1.0 criterion

We **adopt the semantics now** (bump rules + the `BREAKING` marker + the
`update-kernel` gate) but **defer the literal `1.0.0` tag** — the contract
surface is still moving (v0.4→v0.6 in days). The trigger to cut `1.0.0`:

> **three consecutive minor releases with zero `BREAKING` markers**, or an
> explicit operator decision that the contract surface is stable enough to
> promise compatibility.

Until then, a stranger reads `0.x` as "stable semantics, surface still
settling — read the CHANGELOG `BREAKING` markers before you pull," which is a
real, usable signal rather than SemVer's blanket pre-1.0 disclaimer.

## Cutting a release

The ordered procedure. The *conventions* it applies — annotated tag, `VERSION`
bumped in the tagged commit, Keep-a-Changelog section shape — belong to
`workflows/scripts/kernel/kernel-repo-layout.md` § Release-tag convention and
are referenced here, not restated. This section owns the **steps and their
order**, so a cut is followed rather than reconstructed from memory.

**The cut is ONE pull request.** Not one per concern. `main` is protected, so
every cut costs a merge-queue round-trip (~11 min: the `checks` run, then the
queue's second run); splitting the cut across two PRs doubles that for no
structural reason. The v0.23.0 cut split a CHANGELOG backfill from the version
bump and spent an extra cycle on it.

### 1. Assemble the `changelog.d/` fragments into `[Unreleased]`

Every contract-surface PR since the last tag wrote its entry as a
**`changelog.d/` fragment** rather than a line under `## [Unreleased]` — that
is what stops two concurrent PRs colliding on one anchor, and
`workflows/scripts/check-changelog-entry.sh` enforces it at PR time. The cut is
where they are folded back into the one section every downstream reader still
expects:

```sh
scripts/assemble-changelog.sh --check     # validate every fragment; writes nothing
scripts/assemble-changelog.sh --dry-run   # print the resulting CHANGELOG.md
scripts/assemble-changelog.sh             # rewrite [Unreleased], delete the consumed fragments
```

The assembler is **additive, never replacing**: it merges into whatever
`## [Unreleased]` already holds, so an in-flight PR that still wrote a direct
line is folded in beside the fragments rather than dropped. When any fragment
carries `.breaking` it adds the ` — BREAKING` suffix to the `## [Unreleased]`
heading *and* to that category's sub-heading. Fragments are deleted only after
the rewrite has actually landed, so an entry is never lost from both places at
once. Format and rules: [`changelog.d/README.md`](changelog.d/README.md).

**What replaced the old completeness walk.** This step used to grep every merge
commit since the last tag for `^CHANGELOG.md$` and backfill whatever it named.
That loop is gone. Completeness is enforced at PR time by the gate, and the
cut-time backstop is now the deterministic `--assert-empty` assertion in step 3
— one `git ls-tree` against the commit being tagged, which is both cheaper than
the loop and catches a failure the loop never could.

### 2. Rewrite the heading and bump `VERSION` — in one commit

Turn `## [Unreleased]` into `## [x.y.z] - YYYY-MM-DD`, open a fresh empty
`## [Unreleased]` above it, and set `VERSION` to bare `x.y.z`. The
`test_version_embedding.sh` gate fails the build if `VERSION` disagrees with
the tag, so these must move together.

> **⚠ Carry the `BREAKING` marker across the rewrite.**
> `changelog_breaking_sections()` (`workflows/scripts/lib/changelog.sh`) sets
> its breaking flag **only from a heading line** — `BREAKING` on the
> `## [x.y.z]` line, or `/^#+ .*BREAKING/` on a sub-heading. **Body prose never
> sets it.** So rewriting `## [Unreleased] — BREAKING` into a bare
> `## [0.23.0] - 2026-08-02` silently drops the release's breaking signal, and
> both `update-kernel`'s acknowledgment gate and `temperloop update`'s BREAKING
> warning no-op without telling anyone. Keep the suffix on the version heading,
> and keep the ` — BREAKING` sub-heading (e.g. `### Changed — BREAKING`) as the
> belt-and-suspenders half that survives a botched rewrite.
>
> Step 1's assembler applies both markers for you when a `.breaking` fragment
> was pending — which makes this rewrite the **only** place they can now be
> lost. A `.breaking` fragment reaches `changelog_breaking_sections()` solely
> through the heading it produces here.

> **⚠ `## [Unreleased] — BREAKING` occurs more than once in the file.** The live
> heading is near the top; historical entries quote the same string in their
> body prose. A `replace_all` edit rewrites history. Anchor on a unique
> neighbouring line instead.

Verify before pushing — a non-empty result means the gate will fire rather than
silently pass:

```sh
source workflows/scripts/lib/changelog.sh
changelog_breaking_sections v<last> v<new> CHANGELOG.md | wc -c   # args: cur, tgt, FILE
```

### 3. Merge, then tag the merge commit

Enqueue via `pr-enqueue` (or a bare `gh pr merge` — the queue owns the
strategy; passing `--merge` is rejected). Wait for confirmed `MERGED`, pull, and
tag **that** commit — not the branch tip:

```sh
git checkout main && git pull --ff-only

# The cut-time assertion. Run it on the commit you are about to tag, BEFORE
# tagging — a tag is local until pushed, but re-tagging is still churn.
scripts/assemble-changelog.sh --assert-empty HEAD

git tag -a v<new> -m "<subject>"   # subject: 'v<new>' or 'v<new> — BREAKING'
git push origin v<new>
```

> **⚠ Why the assertion is not optional: the cut-vs-sibling omission race.**
> Your cut PR rewrote `CHANGELOG.md` and deleted fragments A and B. While it
> sat in the queue, a sibling PR added fragment C. Those touch **disjoint
> files**, so git merged them **clean** — no conflict, no queue ejection, no
> gate failure — and C is now on `main` with its entry **absent** from the
> section you are about to ship. Nothing else in the pipeline sees this: it is
> a missing entry, not a wrong one, and the mirror image of the merge conflict
> fragments were adopted to eliminate. The only durable evidence is C's file
> still sitting in `changelog.d/` at the commit being tagged, which is exactly
> what `--assert-empty` checks.
>
> If it fires, **re-run step 1 on this commit** and fold the leftovers into the
> release section. Never delete a leftover fragment to silence it — the file
> *is* somebody's entry.

The tag body follows the shape of the previous tags: subject line, one line on
how many PRs/commits it covers, the BREAKING pointer if applicable, then a short
`Highlights:` list drawn from the CHANGELOG section. `git tag -l --format=
'%(contents)' v<last>` shows the house style.

**The tag push fires the live install gate.** `v<new>` matches
`.github/workflows/install-tier2.yml`'s `v*.*.0` trigger, so pushing it starts
the tier-2 round trip — a real `bin/bootstrap.sh` install of this tag, then
`temperloop init` → `temperloop eject` against the live demo repo. That run is
step 4's precondition, so note its URL now rather than hunting for it later:

```sh
gh run list --workflow=install-tier2.yml --limit 1
```

### 4. Propagate to consuming repos

**Do not propagate until the tier-2 run on `v<new>` is green.** It is the only
proof a stranger's actual install of this tag works against a real GitHub API —
tier-1's hermetic suite structurally cannot give it, and `checks` never ran it.
Because the tag is pushed by hand in step 3, this gate necessarily lands *after*
the tag exists: it gates **propagation, not tagging**. That is the real gate,
not a consolation — nothing downstream has moved yet, and pre-1.0 an
unpropagated tag is cheap to fix.

```sh
gh run watch "$(gh run list --workflow=install-tier2.yml --limit 1 --json databaseId --jq '.[0].databaseId')"
```

If it fails, read the run's **Round-trip verdict** step first — it names the
failing leg (`version`/`init`/`eject`) instead of making you dig through logs.
Fix forward and cut the next tag; do not propagate a tag whose live install
path is known broken. If the failure is in the demo repo or the environment
rather than in the release (a `gh` API hiccup, an orphaned proposal branch left
by a previous run's `eject`), re-run the workflow once that is cleared — a
`workflow_dispatch` run tests `main` rather than the tag, so prefer re-running
the tag-triggered run itself.

A tag alone changes nothing downstream — each overlay vendors on its own:

```sh
cd <consuming-repo> && make update-kernel KERNEL_TAG=v<new>
```

This is worktree-isolated: it pushes a `chore/kernel-v<new>` branch and opens a
PR, leaving the caller clean-on-main. **Read its output** — it runs the gate
wiring check and will name any gate the new kernel adds that the overlay does
not satisfy yet, then open the PR anyway. Wire those before merging or CI blocks
(foundation#1508 tracks automating this). Merge the vendor PR, then
`git pull && make install` in that repo to make the release live.

## Summary for a stranger

- Tags are `vX.Y.Z`, annotated, on the commit that produced them.
- Pre-1.0: **read the CHANGELOG.** A `BREAKING`-marked section means touch your
  overlay first. No marker means safe to pull.
- `update-kernel` will stop you before an unacknowledged breaking pull.
- 1.0 arrives when the surface has held still for three minor releases.
