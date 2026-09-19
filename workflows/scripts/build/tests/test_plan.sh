#!/usr/bin/env bash
#
# Tests for workflows/scripts/build/plan.sh — the build Step-1 plan
# parse/validate + dependency-level toposort and the in-band sentinel writeback
# CLI (epic #253, spike #245). Board-toolkit fixture style: throwaway plan-note
# files in a tmpdir, the _plan_vault_write REST seam OVERRIDDEN so ZERO live
# REST calls happen, structured-output assertions via jq.
#
# Covers:
#   - validate: a valid approved plan → VALID; malformed plans → INVALID +
#     non-zero exit (draft status, duplicate slug, missing acceptance, bad
#     branch, dangling depends-on/after ref, leftover acceptance placeholder,
#     non-int gh_issue, gh_issue+split_from together, prose external gate with
#     no gate_check); a depends-on ∪ after cycle → INVALID (rule 8)
#   - validate rule 14: a product-source item (kind: code, files: under
#     scripts/|workflows/|claude/) with no activation: block → INVALID; a
#     kind: spike or docs-only item with no block → VALID (exempt); a
#     product-source item WITH a block → VALID; a pre-RULE_14_CUTOVER_DATE
#     plan's product-source item with no block → VALID (grandfathered)
#   - validate rule 15 (temperloop#526): keystone: true on a kind: spike → VALID;
#     keystone: on a kind: code item → INVALID; keystone: <non-true> → INVALID;
#     a routine spike with no keystone: → VALID (absent field is the common case)
#   - toposort: a 2-level DAG over the union of depends-on + after → the right
#     level partition; a cycle → CYCLE outcome + non-zero exit
#   - writeback routes EVERY vault write through _plan_vault_write (grep: no
#     direct curl outside that function); the seam is overridden, sentinel is
#     flipped, stamp sub-lines are written, WRITTEN is emitted
#   - an unreachable REST API (seam returns non-zero) → WRITE_FAILED + non-zero
#     exit + stderr; NEVER silent success
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/plan.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# --- fixtures ----------------------------------------------------------------
# A valid, approved 2-level plan. Edges:
#   base       : (none)            → L0
#   builds-on  : depends-on base   → L1
#   follows    : after base        → L1
# So levels = [[base], [builds-on, follows]].
cat > "$TMP/valid.md" <<'EOF'
---
tags: [plan, project/foundation]
date: 2026-06-09
status: approved
---

# foundation - valid plan

## Items

- [ ] **Base change** `slug: base` — the foundation item
  - branch: `feat/base`
  - size: S
  - acceptance:
    - base works
    - tests pass

- [ ] **Builds on base** `slug: builds-on` — extends base
  - branch: `feat/builds-on`
  - size: M
  - depends-on: base
  - gh_issue: 4567
  - acceptance:
    - extension works

- [ ] **Follows base logically** `slug: follows` — sequenced after base
  - branch: `fix/follows`
  - size: S
  - after: base
  - acceptance:
    - follows correctly
EOF

# --- validate: the valid plan passes -----------------------------------------
out="$(bash "$SCRIPT" validate "$TMP/valid.md")"
[ "$(jq -r .outcome <<<"$out")" = "VALID" ] || fail "valid plan not VALID (got: $out)"
echo "PASS: validate → VALID on a well-formed approved plan"

# --- validate: draft status is rejected (rule 1) -----------------------------
sed 's/^status: approved/status: draft/' "$TMP/valid.md" > "$TMP/draft.md"
rc=0; out="$(bash "$SCRIPT" validate "$TMP/draft.md")" || rc=$?
[ "$rc" -ne 0 ] || fail "draft plan did not exit non-zero"
[ "$(jq -r .outcome <<<"$out")" = "INVALID" ] || fail "draft not INVALID (got: $out)"
jq -e '.errors | map(test("rule 1")) | any' <<<"$out" >/dev/null \
  || fail "draft INVALID but rule 1 not in errors (got: $out)"
echo "PASS: validate → INVALID + non-zero on a draft (non-approved) plan (rule 1)"

# --- validate: duplicate slug is rejected (rule 3) ---------------------------
cat > "$TMP/dupe.md" <<'EOF'
---
status: approved
---
## Items

- [ ] **First** `slug: same` — one
  - branch: `feat/same`
  - acceptance:
    - x

- [ ] **Second** `slug: same` — two
  - branch: `feat/same`
  - acceptance:
    - y
EOF
rc=0; out="$(bash "$SCRIPT" validate "$TMP/dupe.md")" || rc=$?
[ "$rc" -ne 0 ] || fail "duplicate-slug plan did not exit non-zero"
jq -e '.errors | map(test("duplicate slug")) | any' <<<"$out" >/dev/null \
  || fail "duplicate slug not flagged (got: $out)"
echo "PASS: validate → INVALID + non-zero on a duplicate slug (rule 3)"

# --- validate: missing acceptance / bad branch / dangling refs ---------------
cat > "$TMP/multi.md" <<'EOF'
---
status: approved
---
## Items

- [ ] **No acceptance** `slug: no-acc` — missing block
  - branch: `feat/no-acc`

- [ ] **Bad branch** `slug: bad-branch` — wrong prefix
  - branch: `feature/bad-branch`
  - acceptance:
    - x

- [ ] **Dangling depends** `slug: dangling` — points nowhere
  - branch: `feat/dangling`
  - depends-on: ghost
  - after: phantom
  - acceptance:
    - x
EOF
rc=0; out="$(bash "$SCRIPT" validate "$TMP/multi.md")" || rc=$?
[ "$rc" -ne 0 ] || fail "multi-error plan did not exit non-zero"
jq -e '.errors | map(test("rule 2")) | any' <<<"$out" >/dev/null || fail "missing acceptance (rule 2) not flagged (got: $out)"
jq -e '.errors | map(test("rule 4")) | any' <<<"$out" >/dev/null || fail "bad branch (rule 4) not flagged (got: $out)"
jq -e '.errors | map(test("rule 5")) | any' <<<"$out" >/dev/null || fail "dangling depends-on (rule 5) not flagged (got: $out)"
jq -e '.errors | map(test("rule 8.*phantom|after .phantom")) | any' <<<"$out" >/dev/null || fail "dangling after (rule 8) not flagged (got: $out)"
echo "PASS: validate flags missing acceptance, bad branch, dangling depends-on/after (rules 2/4/5/8)"

# --- validate: acceptance placeholder is fatal (rule 9) ----------------------
cat > "$TMP/placeholder.md" <<'EOF'
---
status: approved
---
## Items

- [ ] **Placeholder** `slug: ph` — unfinished acceptance
  - branch: `feat/ph`
  - acceptance:
    - (no acceptance criteria derivable from source — fill in during review)
EOF
rc=0; out="$(bash "$SCRIPT" validate "$TMP/placeholder.md")" || rc=$?
[ "$rc" -ne 0 ] && jq -e '.errors | map(test("rule 9")) | any' <<<"$out" >/dev/null \
  || fail "leftover acceptance placeholder not flagged (rule 9) (got: $out)"
echo "PASS: validate → INVALID on a leftover acceptance placeholder (rule 9)"

# --- validate: gh_issue must be a positive int (rule 7) ----------------------
cat > "$TMP/badissue.md" <<'EOF'
---
status: approved
---
## Items

- [ ] **Bad issue** `slug: bad-issue` — non-int gh_issue
  - branch: `feat/bad-issue`
  - gh_issue: abc
  - acceptance:
    - x
EOF
rc=0; out="$(bash "$SCRIPT" validate "$TMP/badissue.md")" || rc=$?
[ "$rc" -ne 0 ] && jq -e '.errors | map(test("rule 7")) | any' <<<"$out" >/dev/null \
  || fail "non-int gh_issue not flagged (rule 7) (got: $out)"
echo "PASS: validate → INVALID on a non-integer gh_issue (rule 7)"

# --- validate: gh_issue + split_from mutual exclusion (rule 10) --------------
cat > "$TMP/bothrefs.md" <<'EOF'
---
status: approved
---
## Items

- [ ] **Both refs** `slug: both` — gh_issue and split_from together
  - branch: `feat/both`
  - gh_issue: 100
  - split_from: #40
  - acceptance:
    - x
EOF
rc=0; out="$(bash "$SCRIPT" validate "$TMP/bothrefs.md")" || rc=$?
[ "$rc" -ne 0 ] && jq -e '.errors | map(test("rule 10")) | any' <<<"$out" >/dev/null \
  || fail "gh_issue+split_from not flagged (rule 10) (got: $out)"
echo "PASS: validate → INVALID when gh_issue and split_from coexist (rule 10)"

# --- validate: prose external gate without gate_check (rule 11) --------------
cat > "$TMP/gate.md" <<'EOF'
---
status: approved
---
## Items

- [ ] **Gated** `slug: gated` — waits on external work
  - branch: `feat/gated`
  - notes: External gate — do not start until #380 lands.
  - acceptance:
    - x
EOF
rc=0; out="$(bash "$SCRIPT" validate "$TMP/gate.md")" || rc=$?
[ "$rc" -ne 0 ] && jq -e '.errors | map(test("rule 11")) | any' <<<"$out" >/dev/null \
  || fail "prose external gate without gate_check not flagged (rule 11) (got: $out)"
# adding a gate_check clears it
cat > "$TMP/gate-ok.md" <<'EOF'
---
status: approved
---
## Items

- [ ] **Gated** `slug: gated` — waits on external work
  - branch: `feat/gated`
  - notes: External gate — do not start until #380 lands.
  - gate_check: "configs/artists.toml lists >=40 artists"
  - acceptance:
    - x
EOF
out="$(bash "$SCRIPT" validate "$TMP/gate-ok.md")"
[ "$(jq -r .outcome <<<"$out")" = "VALID" ] || fail "external gate WITH gate_check should be VALID (got: $out)"
echo "PASS: validate flags a prose external gate missing gate_check, clears it once gate_check present (rule 11)"

# --- validate: activation block internal consistency (rule 13) ----------------
# class A without a proof: predicate → INVALID
cat > "$TMP/act-noproof.md" <<'EOF'
---
status: approved
---
## Items

- [ ] **Class A no proof** `slug: act-a-noproof` — synchronous activation, missing predicate
  - branch: `feat/act-a-noproof`
  - activation:
    - class: A
  - acceptance:
    - x
EOF
rc=0; out="$(bash "$SCRIPT" validate "$TMP/act-noproof.md")" || rc=$?
[ "$rc" -ne 0 ] && jq -e '.errors | map(test("rule 13")) | any' <<<"$out" >/dev/null \
  || fail "class-A activation without proof: not flagged (rule 13) (got: $out)"
echo "PASS: validate → INVALID on a class-A activation block missing proof: (rule 13)"

# an unknown class → INVALID
cat > "$TMP/act-badclass.md" <<'EOF'
---
status: approved
---
## Items

- [ ] **Bad class** `slug: act-badclass` — class must be A|B|C
  - branch: `feat/act-badclass`
  - activation:
    - class: X
    - proof: "true"
  - acceptance:
    - x
EOF
rc=0; out="$(bash "$SCRIPT" validate "$TMP/act-badclass.md")" || rc=$?
[ "$rc" -ne 0 ] && jq -e '.errors | map(test("rule 13")) | any' <<<"$out" >/dev/null \
  || fail "activation with an invalid class not flagged (rule 13) (got: $out)"
echo "PASS: validate → INVALID on an activation class outside A|B|C (rule 13)"

# class A WITH proof: → VALID (and coexists with acceptance parsing)
cat > "$TMP/act-ok.md" <<'EOF'
---
status: approved
---
## Items

- [ ] **Class A with proof** `slug: act-a-ok` — synchronous activation, wired-in predicate
  - branch: `feat/act-a-ok`
  - activation:
    - class: A
    - proof: "grep -q GeminiRunner evals/runners/__init__.py"
  - acceptance:
    - runner registered and dispatched
    - tests pass
EOF
out="$(bash "$SCRIPT" validate "$TMP/act-ok.md")"
[ "$(jq -r .outcome <<<"$out")" = "VALID" ] || fail "class-A activation WITH proof should be VALID (got: $out)"
echo "PASS: validate → VALID on a class-A activation block carrying proof: (rule 13)"

# class B needs no proof: (ledger-discharged) → VALID
cat > "$TMP/act-b.md" <<'EOF'
---
status: approved
---
## Items

- [ ] **Class B** `slug: act-b` — propagation-gated, no proof required
  - branch: `feat/act-b`
  - activation:
    - class: B
  - acceptance:
    - x
EOF
out="$(bash "$SCRIPT" validate "$TMP/act-b.md")"
[ "$(jq -r .outcome <<<"$out")" = "VALID" ] || fail "class-B activation without proof should be VALID (ledger-discharged) (got: $out)"
echo "PASS: validate → VALID on a class-B activation block with no proof: (ledger-discharged) (rule 13)"

# --- K1451 static lockstep guards: rule 13 is what makes 3e.6's no-predicate --
# arm UNREACHABLE, so the prose that depends on it must stay in lockstep with
# the behavior cases above.
#
# The defect (temperloop#1451, the temperloop#1387 shape): build.md §3e.6
# routed a class-A block with no `proof:` to a `/verify` skill that has never
# existed in this repo, under a pre-authorized legible-degradation clause — so
# that arm of a MANDATORY gate could only ever resolve to its own skip notice.
# The fix keeps `proof:` mandatory (rule 13, asserted behaviorally above) and
# deletes the dead route + its degradation arm. These greps are the mechanical
# half: they go RED if either surface is reverted independently of the other.
K1451_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
K1451_BUILD_MD="$K1451_REPO/claude/commands/build.md"
K1451_PLAN_SCHEMA="$K1451_REPO/claude/plan-schema.md"
# An absent prose half is a HARD FAIL, never a skip — a check that cannot run
# must not report PASS (temperloop#1409's own failure class).
[ -f "$K1451_BUILD_MD" ] \
  || fail "#1451: claude/commands/build.md is missing — the prose half of this contract pair cannot be verified"
[ -f "$K1451_PLAN_SCHEMA" ] \
  || fail "#1451: claude/plan-schema.md is missing — the prose half of this contract pair cannot be verified"

# (a) 3e.6 must carry a HARD-FAIL arm for the no-predicate case, not a skip.
grep -qF 'activation-proof-missing' "$K1451_BUILD_MD" \
  || fail "#1451: build.md §3e.6 must escalate 'activation-proof-missing' for a class-A block with no proof: (no silent pass, no skip arm)"
# (b) The dead degradation arm must stay gone: no /verify skip notice anywhere
#     in build.md. (The historical note in §3e.6 deliberately does not quote it.)
! grep -qF 'skipped — /verify' "$K1451_BUILD_MD" \
  || fail "#1451: build.md still carries a 'skipped — /verify ...' degradation line — a pre-authorized skip for a capability that does not exist"
# (c) No live route to /verify while no /verify command ships. Conditional on
#     the command's actual presence, so this guard stops objecting the day a
#     real /verify lands rather than blocking it.
if [ ! -f "$K1451_REPO/claude/commands/verify.md" ]; then
  ! grep -qiE 'invoke[^.]*/verify|driving `?/verify|drive `?/verify' "$K1451_BUILD_MD" \
    || fail "#1451: build.md routes to /verify, but claude/commands/verify.md does not exist (dead route)"
  ! grep -qF '/verify' "$K1451_PLAN_SCHEMA" \
    || fail "#1451: plan-schema.md names /verify as a class-A fallback, but claude/commands/verify.md does not exist (dead route)"
fi
# (d) /build's Step 1 must name rule 13 — the front-door check that makes the
#     3e.6 arm unreachable in the first place. Without it the orchestrator's
#     own checklist never enforces the invariant 3e.6 now relies on.
grep -qF 'rule 13' "$K1451_BUILD_MD" \
  || fail "#1451: build.md Step 1 must name rule 13 (class-A activation requires proof:) — the validation that makes 3e.6's no-predicate arm unreachable"
echo "PASS: #1451 dead-/verify-arm guard — rule 13 mandatory-proof enforced in plan.sh; build.md/plan-schema.md carry no route or skip arm to a non-existent /verify"

# --- validate: rule 14 — activation required for product-source items --------
# A plan dated ON-OR-AFTER the RULE_14_CUTOVER_DATE (2026-07-17) so the
# grandfather gate does NOT apply — rule 14 is live for all cases below unless
# a per-file date says otherwise.

# product-source (kind: code, files: touches claude/) WITHOUT activation: → INVALID
cat > "$TMP/r14-product-noact.md" <<'EOF'
---
status: approved
date: 2026-07-20
---
## Items

- [ ] **Product source, no activation** `slug: r14-product-noact` — touches shipped claude/ machinery
  - branch: `feat/r14-product-noact`
  - kind: code
  - files: `claude/plan-schema.md`
  - acceptance:
    - x
EOF
rc=0; out="$(bash "$SCRIPT" validate "$TMP/r14-product-noact.md")" || rc=$?
[ "$rc" -ne 0 ] && jq -e '.errors | map(test("rule 14")) | any' <<<"$out" >/dev/null \
  || fail "product-source item with no activation: block not flagged (rule 14) (got: $out)"
echo "PASS: validate → INVALID on a product-source item (kind: code, files: under claude/) with no activation: block (rule 14)"

# kind: spike WITHOUT activation: → VALID (exempt)
cat > "$TMP/r14-spike-noact.md" <<'EOF'
---
status: approved
date: 2026-07-20
---
## Items

- [ ] **Spike, no activation** `slug: r14-spike-noact` — verdict-only, exempt from rule 14
  - branch: `feat/r14-spike-noact`
  - kind: spike
  - files: `claude/plan-schema.md`
  - acceptance:
    - x
EOF
out="$(bash "$SCRIPT" validate "$TMP/r14-spike-noact.md")"
[ "$(jq -r .outcome <<<"$out")" = "VALID" ] || fail "kind: spike item with no activation: block should be VALID (rule 14 exempt) (got: $out)"
echo "PASS: validate → VALID on a kind: spike item with no activation: block (rule 14 exemption)"

# docs-only (files: only under docs/) WITHOUT activation: → VALID (exempt)
cat > "$TMP/r14-docsonly-noact.md" <<'EOF'
---
status: approved
date: 2026-07-20
---
## Items

- [ ] **Docs only, no activation** `slug: r14-docsonly-noact` — docs-only, exempt from rule 14
  - branch: `docs/r14-docsonly-noact`
  - kind: code
  - files: `docs/usage.md`
  - acceptance:
    - x
EOF
out="$(bash "$SCRIPT" validate "$TMP/r14-docsonly-noact.md")"
[ "$(jq -r .outcome <<<"$out")" = "VALID" ] || fail "docs-only item with no activation: block should be VALID (rule 14 exempt) (got: $out)"
echo "PASS: validate → VALID on a docs-only item (files: under docs/) with no activation: block (rule 14 exemption)"

# product-source WITH activation: → VALID
cat > "$TMP/r14-product-withact.md" <<'EOF'
---
status: approved
date: 2026-07-20
---
## Items

- [ ] **Product source, with activation** `slug: r14-product-withact` — touches shipped workflows/ machinery, has activation:
  - branch: `feat/r14-product-withact`
  - kind: code
  - files: `workflows/scripts/build/plan.sh`
  - activation:
    - class: A
    - proof: "true"
  - acceptance:
    - x
EOF
out="$(bash "$SCRIPT" validate "$TMP/r14-product-withact.md")"
[ "$(jq -r .outcome <<<"$out")" = "VALID" ] || fail "product-source item WITH activation: block should be VALID (got: $out)"
echo "PASS: validate → VALID on a product-source item (kind: code, files: under workflows/) carrying an activation: block (rule 14)"

# product-source WITH activation: placed AFTER acceptance: (the canonical field
# order) → VALID. Regression guard for the parser bug where the in_acc branch
# tested the deeper-bullet acceptance-entry regex before the same-level field-key
# regex, so a `- activation:` bullet following acceptance: was miscounted as an
# acceptance entry and never opened the activation block — rule 14 then wrongly
# reported 'carries no activation: block' for a well-formed item.
cat > "$TMP/r14-act-after-acc.md" <<'EOF'
---
status: approved
date: 2026-07-20
---
## Items

- [ ] **Activation after acceptance** `slug: r14-act-after-acc` — canonical field order, activation: after acceptance:
  - branch: `feat/r14-act-after-acc`
  - kind: code
  - files: `workflows/scripts/build/plan.sh`
  - acceptance:
    - runner registered and dispatched
    - tests pass
  - activation:
    - class: A
    - proof: "true"
EOF
out="$(bash "$SCRIPT" validate "$TMP/r14-act-after-acc.md")"
[ "$(jq -r .outcome <<<"$out")" = "VALID" ] || fail "product-source item with activation: placed AFTER acceptance: should be VALID — rule 14 false positive on canonical field order (got: $out)"
echo "PASS: validate → VALID on a product-source item whose activation: block follows acceptance: (rule 14 field-order regression)"

# grandfathered: pre-cutover date: + product-source + no activation: → VALID
cat > "$TMP/r14-grandfathered.md" <<'EOF'
---
status: approved
date: 2026-07-16
---
## Items

- [ ] **Pre-cutover product source, no activation** `slug: r14-grandfathered` — predates rule 14's cutover, exempt
  - branch: `feat/r14-grandfathered`
  - kind: code
  - files: `claude/commands/build.md`
  - acceptance:
    - x
EOF
out="$(bash "$SCRIPT" validate "$TMP/r14-grandfathered.md")"
[ "$(jq -r .outcome <<<"$out")" = "VALID" ] || fail "grandfathered (pre-cutover date:) product-source item with no activation: should be VALID (got: $out)"
echo "PASS: validate → VALID on a product-source item with no activation: block when the plan's date: predates RULE_14_CUTOVER_DATE (rule 14 grandfather clause)"

# --- validate: rule 15 — keystone: spike-only, value 'true' (temperloop#526) --
# A keystone: true spike halts /build for operator verdict-review before
# dependents build. It is spike-only and its only meaningful value is 'true'.

# keystone: true on a kind: spike → VALID
cat > "$TMP/r15-keystone-spike.md" <<'EOF'
---
status: approved
date: 2026-07-23
---
## Items

- [ ] **Reshaping spike** `slug: r15-ks-spike` — verdict reshapes downstream contracts
  - branch: `chore/r15-ks-spike`
  - kind: spike
  - keystone: true
  - acceptance:
    - verdict note written
EOF
out="$(bash "$SCRIPT" validate "$TMP/r15-keystone-spike.md")"
[ "$(jq -r .outcome <<<"$out")" = "VALID" ] || fail "keystone: true on a kind: spike item should be VALID (rule 15) (got: $out)"
echo "PASS: validate → VALID on a keystone: true marker on a kind: spike item (rule 15)"

# keystone: true on a kind: code item → INVALID (rule 15)
cat > "$TMP/r15-keystone-code.md" <<'EOF'
---
status: approved
date: 2026-07-23
---
## Items

- [ ] **Not a spike** `slug: r15-ks-code` — keystone marker on a code item is a defect
  - branch: `feat/r15-ks-code`
  - kind: code
  - keystone: true
  - files: `docs/x.md`
  - acceptance:
    - x
EOF
rc=0; out="$(bash "$SCRIPT" validate "$TMP/r15-keystone-code.md")" || rc=$?
[ "$rc" -ne 0 ] && jq -e '.errors | map(test("rule 15")) | any' <<<"$out" >/dev/null \
  || fail "keystone: true on a kind: code item not flagged (rule 15) (got: $out)"
echo "PASS: validate → INVALID on a keystone: true marker on a non-spike (kind: code) item (rule 15)"

# keystone: <not true> on a spike → INVALID (rule 15)
cat > "$TMP/r15-keystone-badval.md" <<'EOF'
---
status: approved
date: 2026-07-23
---
## Items

- [ ] **Bad keystone value** `slug: r15-ks-badval` — only 'true' is meaningful
  - branch: `chore/r15-ks-badval`
  - kind: spike
  - keystone: yes
  - acceptance:
    - verdict note written
EOF
rc=0; out="$(bash "$SCRIPT" validate "$TMP/r15-keystone-badval.md")" || rc=$?
[ "$rc" -ne 0 ] && jq -e '.errors | map(test("rule 15")) | any' <<<"$out" >/dev/null \
  || fail "keystone: <non-true> value not flagged (rule 15) (got: $out)"
echo "PASS: validate → INVALID on a keystone: value other than 'true' (rule 15)"

# a routine spike (no keystone:) → VALID (unchanged autonomous path)
cat > "$TMP/r15-routine-spike.md" <<'EOF'
---
status: approved
date: 2026-07-23
---
## Items

- [ ] **Routine spike** `slug: r15-routine-spike` — no keystone marker, autonomous
  - branch: `chore/r15-routine-spike`
  - kind: spike
  - acceptance:
    - verdict note written
EOF
out="$(bash "$SCRIPT" validate "$TMP/r15-routine-spike.md")"
[ "$(jq -r .outcome <<<"$out")" = "VALID" ] || fail "routine spike (no keystone:) should be VALID (rule 15) (got: $out)"
echo "PASS: validate → VALID on a routine spike with no keystone: marker (rule 15 — absent field is the common case)"

# --- validate rule 16 (foundation#1059): cost: block requires because: --------
# A cost: block WITH because: (and optional budget:) → VALID.
cat > "$TMP/r16-ok.md" <<'EOF'
---
tags: [plan]
date: 2026-07-24
status: approved
---
## Items

- [ ] **Deep research run** `slug: r16-deep` — run the research harness
  - branch: `feat/r16-deep`
  - size: M
  - cost:
      - because: deep-research
      - budget: 500000
  - acceptance:
    - it runs
EOF
out="$(bash "$SCRIPT" validate "$TMP/r16-ok.md")"
[ "$(jq -r .outcome <<<"$out")" = "VALID" ] || fail "cost: block with because: should be VALID (rule 16) (got: $out)"
grep -q "rule 16" <<<"$out" && fail "rule 16 should NOT fire on a valid cost: block (got: $out)"
echo "PASS: validate → VALID on a cost: block carrying because: (+optional budget:) (rule 16)"

# A cost: block with NO because: → INVALID (rule 16).
sed '/because: deep-research/d' "$TMP/r16-ok.md" > "$TMP/r16-nobecause.md"
rc=0; out="$(bash "$SCRIPT" validate "$TMP/r16-nobecause.md")" || rc=$?
[ "$rc" -ne 0 ] || fail "cost: with no because: should exit non-zero (rule 16) (got rc=$rc)"
[ "$(jq -r .outcome <<<"$out")" = "INVALID" ] || fail "cost: with no because: should be INVALID (rule 16) (got: $out)"
jq -e '.errors[] | select(test("rule 16"))' <<<"$out" >/dev/null \
  || fail "cost: with no because: INVALID but rule 16 not in errors (got: $out)"
echo "PASS: validate → INVALID + rule 16 on a cost: block missing because:"

# An item with NO cost: block → VALID, rule 16 never fires (the common case).
grep -q "rule 16" <<<"$(bash "$SCRIPT" validate "$TMP/valid.md")" \
  && fail "rule 16 must not fire on a plan with no cost: blocks"
echo "PASS: validate → rule 16 dormant on plans with no cost: block (absent = standard cost)"

# Inline shorthand `- cost: <driver>` (a hand-authored one-liner) is FLAGGED, not
# silently dropped: the inline value is captured as because: → VALID, no rule 16.
cat > "$TMP/r16-inline.md" <<'EOF'
---
tags: [plan]
date: 2026-07-24
status: approved
---
## Items

- [ ] **Inline cost flag** `slug: r16-inline` — one-liner cost, cost BEFORE acceptance
  - branch: `feat/r16-inline`
  - size: M
  - cost: agent-fanout
  - acceptance:
    - it runs
EOF
out="$(bash "$SCRIPT" validate "$TMP/r16-inline.md")"
[ "$(jq -r .outcome <<<"$out")" = "VALID" ] || fail "inline '- cost: <driver>' should be VALID (because captured inline) (got: $out)"
grep -q "rule 16" <<<"$out" && fail "inline cost value must count as because: (rule 16 must NOT fire) (got: $out)"
echo "PASS: validate → inline '- cost: <driver>' captures the driver as because: (not silently dropped) + a cost block before acceptance still parses"

# --- toposort: 2-level DAG over depends-on ∪ after ----------------------------
out="$(bash "$SCRIPT" toposort "$TMP/valid.md")"
jq -e '.levels | length == 2' <<<"$out" >/dev/null || fail "expected 2 levels (got: $out)"
jq -e '.levels[0] == ["base"]' <<<"$out" >/dev/null || fail "L0 should be [base] (got: $out)"
jq -e '.levels[1] | sort == ["builds-on","follows"]' <<<"$out" >/dev/null \
  || fail "L1 should be {builds-on, follows} (got: $out)"
echo "PASS: toposort partitions a 2-level DAG over the depends-on ∪ after union"

# --- toposort: a cycle fails loud (rule 8 / CYCLE outcome) -------------------
cat > "$TMP/cycle.md" <<'EOF'
---
status: approved
---
## Items

- [ ] **A** `slug: a` — cycles to b
  - branch: `feat/a`
  - depends-on: b
  - acceptance:
    - x

- [ ] **B** `slug: b` — cycles to a
  - branch: `feat/b`
  - after: a
  - acceptance:
    - x
EOF
rc=0; out="$(bash "$SCRIPT" toposort "$TMP/cycle.md")" || rc=$?
[ "$rc" -ne 0 ] || fail "cyclic toposort did not exit non-zero"
[ "$(jq -r .outcome <<<"$out")" = "CYCLE" ] || fail "cycle not reported as CYCLE (got: $out)"
echo "PASS: toposort → CYCLE + non-zero exit on a depends-on ∪ after cycle"
# validate catches the same cycle as rule 8
rc=0; out="$(bash "$SCRIPT" validate "$TMP/cycle.md")" || rc=$?
[ "$rc" -ne 0 ] && jq -e '.errors | map(test("rule 8")) | any' <<<"$out" >/dev/null \
  || fail "validate did not flag the cycle as rule 8 (got: $out)"
echo "PASS: validate → INVALID (rule 8) on the same cycle"

# --- writeback: ALL writes route through _plan_vault_write (source grep) ------
# The only curl in the script must live inside the _plan_vault_write function.
curl_lines="$(grep -nE '\bcurl\b' "$SCRIPT" || true)"
[ -n "$curl_lines" ] || fail "expected a curl call inside _plan_vault_write"
# Extract the body of _plan_vault_write and assert the curl line(s) fall inside it.
awk '/^_plan_vault_write\(\)/{f=1} f{print NR": "$0} f&&/^}/{f=0}' "$SCRIPT" > "$TMP/seam.txt"
while IFS= read -r cl; do
  ln="${cl%%:*}"
  grep -q "^${ln}: " "$TMP/seam.txt" || fail "a curl call (line $ln) lives OUTSIDE _plan_vault_write — not the sole write path"
done <<<"$curl_lines"
echo "PASS: every curl in plan.sh lives inside _plan_vault_write (sole sentinel-write path)"

# --- writeback: seam overridden → no live REST; sentinel flipped + stamped ----
# Source the script's functions, override the seam to capture instead of PUT.
# shellcheck disable=SC1090
( set +e
  # Run plan.sh with the seam stubbed via an injected wrapper. We can't source
  # the dispatch tail, so we exercise writeback as a subprocess with a stub
  # _plan_vault_write installed by pointing the REST helper at a fake: override
  # by exporting a function is not inherited by a bash subprocess, so instead we
  # drive the seam through a writable fake key-file + a curl shim on PATH.
  true
)
# Stub strategy mirroring pr.sh's gh-shim: put a fake `curl` on PATH that
# records the PUT target + body and returns HTTP 200, and a fake key-file so the
# seam's preconditions pass. This proves the write goes THROUGH _plan_vault_write
# (it is the only curl) and that a 200 → WRITTEN.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/curl" <<EOF
#!/usr/bin/env bash
# record args + body, emit 200 as the -w '%{http_code}' value
printf '%s\n' "\$@" > "$TMP/curl-args"
for a in "\$@"; do case "\$a" in @*) cp "\${a#@}" "$TMP/put-body" ;; esac; done
printf '200'
EOF
chmod +x "$TMP/bin/curl"
mkdir -p "$TMP/keydir"
echo '{"apiKey":"test-key"}' > "$TMP/keydir/data.json"

cp "$TMP/valid.md" "$TMP/wb.md"
out="$(PATH="$TMP/bin:$PATH" PLAN_API_KEY_FILE="$TMP/keydir/data.json" \
  bash "$SCRIPT" writeback "$TMP/wb.md" --slug builds-on --sentinel '[~]' \
  --pr 142 --pushed-sha abc123 --run-status "worker active")"
[ "$(jq -r .outcome <<<"$out")" = "WRITTEN" ] || fail "writeback not WRITTEN (got: $out)"
[ "$(jq -r .sentinel <<<"$out")" = "[~]" ] || fail "writeback sentinel not echoed (got: $out)"
# the PUT body must carry the flipped sentinel on the builds-on item + the stamps
grep -q '^- \[~\] \*\*Builds on base\*\* `slug: builds-on`' "$TMP/put-body" \
  || fail "PUT body did not flip the builds-on sentinel to [~]"
grep -q '^  - pr: 142' "$TMP/put-body" || fail "PUT body missing stamped pr: 142"
grep -q '^  - pushed_sha: abc123' "$TMP/put-body" || fail "PUT body missing stamped pushed_sha"
grep -q '^  - Run-status: worker active' "$TMP/put-body" || fail "PUT body missing Run-status stamp"
# the OTHER items must be untouched (base still [ ])
grep -q '^- \[ \] \*\*Base change\*\* `slug: base`' "$TMP/put-body" \
  || fail "writeback disturbed an unrelated item's sentinel"
echo "PASS: writeback flips the target sentinel, stamps pr/pushed_sha/Run-status, leaves others untouched (→ WRITTEN)"

# --- writeback: the as-you-go merging sentinel [>] (temperloop#1026) -----------
# `[>]` is a DISTINCT state from `[m]` — consent recorded and the merge issued at
# Step 3h.5, awaiting confirmed MERGED — so writeback must accept it in BOTH the
# bracketed and the bare-char form and land it on the item header line. A silent
# rejection here would force /build to repurpose `[m]` for merge-in-flight, the
# exact conflation this sentinel exists to prevent.
cp "$TMP/valid.md" "$TMP/wb-ayg.md"
out="$(PATH="$TMP/bin:$PATH" PLAN_API_KEY_FILE="$TMP/keydir/data.json" \
  bash "$SCRIPT" writeback "$TMP/wb-ayg.md" --slug builds-on --sentinel '[>]' --pr 1026)"
[ "$(jq -r .outcome <<<"$out")" = "WRITTEN" ] || fail "writeback [>] not WRITTEN (got: $out)"
[ "$(jq -r .sentinel <<<"$out")" = "[>]" ] || fail "writeback [>] sentinel not echoed (got: $out)"
grep -q '^- \[>\] \*\*Builds on base\*\* `slug: builds-on`' "$TMP/put-body" \
  || fail "PUT body did not flip the builds-on sentinel to [>]"
cp "$TMP/valid.md" "$TMP/wb-ayg2.md"
out="$(PATH="$TMP/bin:$PATH" PLAN_API_KEY_FILE="$TMP/keydir/data.json" \
  bash "$SCRIPT" writeback "$TMP/wb-ayg2.md" --slug base --sentinel '>')"
[ "$(jq -r .sentinel <<<"$out")" = "[>]" ] || fail "bare-char '>' not normalized to [>] (got: $out)"
echo "PASS: writeback accepts the as-you-go merging sentinel [>], bracketed and bare (#1026)"

# --- writeback: plan filename with spaces → URL-encoded PUT path (#364) --------
# Every real plan filename has spaces ('Plans/<date> <project> - <title>.md'), so
# the PUT URL MUST percent-encode the path segments — a raw space makes curl
# reject the URL (exit 3, http_code 000) and writeback breaks for all plans.
# Re-install the recording curl shim (the 000 shim above replaced it).
cat > "$TMP/bin/curl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$TMP/curl-args"
for a in "\$@"; do case "\$a" in @*) cp "\${a#@}" "$TMP/put-body" ;; esac; done
printf '200'
EOF
chmod +x "$TMP/bin/curl"
mkdir -p "$TMP/Plans"
cp "$TMP/valid.md" "$TMP/Plans/2026-06-11 stagefind - spaces in name.md"
out="$(PATH="$TMP/bin:$PATH" PLAN_API_KEY_FILE="$TMP/keydir/data.json" \
  bash "$SCRIPT" writeback "$TMP/Plans/2026-06-11 stagefind - spaces in name.md" \
  --slug base --sentinel '[x]')"
[ "$(jq -r .outcome <<<"$out")" = "WRITTEN" ] || fail "spaced-filename writeback not WRITTEN (got: $out)"
# The PUT-target URL line in curl-args must carry the percent-encoded path …
grep -q 'vault/Plans/2026-06-11%20stagefind%20-%20spaces%20in%20name\.md' "$TMP/curl-args" \
  || fail "PUT URL not percent-encoded (got: $(grep vault/ "$TMP/curl-args"))"
# … and must NOT contain a raw space in the vault path (the exit-3 trigger).
grep -E '^https?://[^ ]*/vault/.* ' "$TMP/curl-args" \
  && fail "PUT URL still contains a raw space in the path (curl would reject it)"
echo "PASS: writeback URL-encodes a spaced plan filename before the PUT (→ no curl exit-3) (#364)"

# --- writeback: unreachable REST → WRITE_FAILED + non-zero + stderr -----------
# A curl shim that emits HTTP 000 (no response) must make the seam fail loud.
cat > "$TMP/bin/curl" <<EOF
#!/usr/bin/env bash
printf '000'
EOF
chmod +x "$TMP/bin/curl"
rc=0
out="$(PATH="$TMP/bin:$PATH" PLAN_API_KEY_FILE="$TMP/keydir/data.json" \
  bash "$SCRIPT" writeback "$TMP/wb.md" --slug builds-on --sentinel '[m]' 2>"$TMP/err")" || rc=$?
[ "$rc" -ne 0 ] || fail "unreachable REST writeback did NOT exit non-zero (silent success — the forbidden failure)"
[ "$(jq -r .outcome <<<"$out")" = "WRITE_FAILED" ] || fail "unreachable REST not WRITE_FAILED (got: $out)"
grep -qi 'unreachable' "$TMP/err" || fail "no fail-loud stderr message on unreachable REST (got: $(cat "$TMP/err"))"
echo "PASS: unreachable REST → WRITE_FAILED + non-zero exit + stderr (never silent success)"

# --- writeback: no REST config → fail SOFT to a direct filesystem write (#342) -
# When no Obsidian REST config is resolvable (nonexistent key file, and the plan
# path is not under a vault that carries the plugin), the seam must NOT fail loud
# — it persists the sentinel directly to the plan note's on-disk path (resume-
# safety intact) and returns WRITTEN. This is the temperloop-kernel-checkout case
# the old "fail loud on missing key file" behavior broke (WRITE_FAILED with a
# hardcoded ~/.local/share/foundation/knowledge path). No curl shim on PATH here,
# so a stray REST attempt would error visibly rather than silently succeed.
cp "$TMP/valid.md" "$TMP/wb.md"
rc=0
out="$(PLAN_API_KEY_FILE="$TMP/nonexistent.json" \
  bash "$SCRIPT" writeback "$TMP/wb.md" --slug base --sentinel '[x]' 2>"$TMP/err2")" || rc=$?
[ "$rc" -eq 0 ] || fail "no-REST-config writeback did not fail soft (exit $rc, out: $out)"
[ "$(jq -r .outcome <<<"$out")" = "WRITTEN" ] || fail "no-REST-config writeback not WRITTEN via FS fallback (got: $out)"
grep -qi 'filesystem fallback' "$TMP/err2" || fail "no filesystem-fallback notice on stderr (got: $(cat "$TMP/err2"))"
# the sentinel flip must be persisted to the on-disk plan file itself
grep -q '^- \[x\] \*\*Base change\*\* `slug: base`' "$TMP/wb.md" \
  || fail "FS fallback did not flip the base sentinel to [x] on disk (got: $(grep 'slug: base' "$TMP/wb.md"))"
echo "PASS: no REST config → filesystem-write fallback persists the sentinel (→ WRITTEN, never WRITE_FAILED) (#342)"

# --- writeback: no REST config AND no writable on-disk path → WRITE_SKIPPED ----
# The soft outcome the orchestrator can handle: nothing persisted, but zero exit
# (not the hard WRITE_FAILED of a broken-but-configured endpoint). We force the
# FS fallback itself to fail by making the plan file read-only. Skipped when the
# suite runs as root (a 0444 file is still writable to root, so the fallback
# would succeed and the branch is unreachable).
if [ "$(id -u)" -ne 0 ]; then
  cp "$TMP/valid.md" "$TMP/ro.md"
  chmod 0444 "$TMP/ro.md"
  rc=0
  out="$(PLAN_API_KEY_FILE="$TMP/nonexistent.json" \
    bash "$SCRIPT" writeback "$TMP/ro.md" --slug base --sentinel '[x]' 2>"$TMP/err3")" || rc=$?
  chmod 0644 "$TMP/ro.md"
  [ "$rc" -eq 0 ] || fail "WRITE_SKIPPED case exited non-zero (should be a soft, zero-exit skip; got rc=$rc)"
  [ "$(jq -r .outcome <<<"$out")" = "WRITE_SKIPPED" ] || fail "read-only fallback not WRITE_SKIPPED (got: $out)"
  echo "PASS: no REST config + unwritable plan path → WRITE_SKIPPED (soft, zero exit) (#342)"
else
  echo "SKIP: WRITE_SKIPPED read-only test (running as root)"
fi

# --- error: bad args → structured ERROR + non-zero ----------------------------
rc=0; out="$(bash "$SCRIPT" validate "$TMP/nonexistent.md" 2>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] && [ "$(jq -r .outcome <<<"$out")" = "ERROR" ] \
  || fail "validate on missing file not structured ERROR (got: $out)"
rc=0; out="$(bash "$SCRIPT" writeback "$TMP/wb.md" --slug base 2>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] && [ "$(jq -r .outcome <<<"$out")" = "ERROR" ] \
  || fail "writeback without --sentinel not structured ERROR (got: $out)"
rc=0; out="$(bash "$SCRIPT" writeback "$TMP/wb.md" --slug ghost --sentinel '[x]' 2>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] && [ "$(jq -r .outcome <<<"$out")" = "ERROR" ] \
  || fail "writeback on unknown slug not structured ERROR (got: $out)"
echo "PASS: bad args (missing file, no --sentinel, unknown slug) → structured ERROR + non-zero"

# =============================================================================
# roster — the /build level-composition report (temperloop#1310)
#
# THIS BLOCK IS THE EXECUTION SIGNAL for build.md's mandatory roster print
# (claude/CLAUDE.kernel.md § Mandatory-step birth rule; registered in
# workflows/scripts/config/mandatory-step-registry.tsv, run by `make test-build`).
# It closes BOTH halves of the "declared mandatory, silently never runs" shape:
#   (a) INVOCATION — the spec must still invoke `plan.sh roster` at all three
#       sites; delete one and this file goes RED. Prose alone can be dropped by
#       the executing model with nothing to notice, so the roster is rendered by
#       code and the spec's call to it is what is asserted.
#   (b) TOTALITY — the renderer must emit one row per level member and header
#       counts that EQUAL the rows shown. A change that drops terminal rows, or
#       restates a count beside the rows instead of deriving it, goes RED here.
# =============================================================================

cat > "$TMP/roster.md" <<'EOF'
---
tags: [plan, project/temperloop]
date: 2026-08-24
status: approved
---

# temperloop - roster fixture

## Items

- [ ] **Fresh item** `slug: alpha` — a fresh one
  - branch: `feat/alpha`
  - gh_issue: 1310
  - acceptance:
    - it works
- [~] **Resuming item** `slug: bravo` — carries a PR
  - branch: `feat/bravo`
  - gh_issue: 1267
  - pr: 1798
  - acceptance:
    - it works
- [v] **Spike** `slug: charlie` — verdict captured
  - branch: `feat/charlie`
  - kind: spike
  - gh_issue: 1311
  - Run-status: routed #1330
  - acceptance:
    - it works
- [-] **Cross-repo** `slug: delta` — skipped
  - branch: `feat/delta`
  - repo: Towheads/ssmobile
  - gh_issue: 77
  - acceptance:
    - it works
- [m] **Merge set** `slug: echo` — parked for the gate
  - branch: `feat/echo`
  - pr: 205
  - acceptance:
    - it works
- [?] **Unreadable sentinel** `slug: foxtrot` — outside the seven
  - branch: `feat/foxtrot`
  - acceptance:
    - it works
EOF

# --- roster totality: one row per level member, on every stage ----------------
for st in launch gate close; do
  out="$(bash "$SCRIPT" roster "$TMP/roster.md" --level 0 --stage "$st" \
      --owner-repo Towheads/temperloop)" \
    || fail "roster --stage $st exited non-zero (got: $out)"
  n_rows="$(printf '%s\n' "$out" | grep -c '^\[')"
  [ "$n_rows" -eq 6 ] || fail "roster --stage $st rendered $n_rows rows for a 6-item level"
  for sl in alpha bravo charlie delta echo foxtrot; do
    grep -q " $sl " <<<"$out" || fail "roster --stage $st dropped the '$sl' row (totality)"
  done
done
echo "PASS: roster renders one row per level member on every stage (totality over the level)"

# --- roster arithmetic: the header counts EQUAL the rows shown ----------------
# The failure this pins is the one a hand-written worked example made in review:
# a header stating a partition that does not sum to the rows beneath it.
out="$(bash "$SCRIPT" roster "$TMP/roster.md" --level 0 --stage launch --owner-repo Towheads/temperloop)"
hdr="$(printf '%s\n' "$out" | head -1)"
[ "$(sed -E 's/.*launch: ([0-9]+) items.*/\1/' <<<"$hdr")" -eq 6 ] \
  || fail "launch header item count != 6 rows (got: $hdr)"
[ "$(sed -E 's/.*\(([0-9]+) active\).*/\1/' <<<"$hdr")" -eq 2 ] \
  || fail "launch header active count wrong — alpha+bravo are the only drivable rows (got: $hdr)"
out="$(bash "$SCRIPT" roster "$TMP/roster.md" --level 0 --stage gate --owner-repo Towheads/temperloop)"
hdr="$(printf '%s\n' "$out" | head -1)"
tot="$(sed -E 's/.*disposition: ([0-9]+) items.*/\1/' <<<"$hdr")"
inm="$(sed -E 's/.*· ([0-9]+) in the merge set.*/\1/' <<<"$hdr")"
outm="$(sed -E 's/.*· ([0-9]+) outside it.*/\1/' <<<"$hdr")"
[ "$((inm + outm))" -eq "$tot" ] || fail "gate header partition does not sum to the total (got: $hdr)"
[ "$tot" -eq "$(printf '%s\n' "$out" | grep -c '^\[')" ] \
  || fail "gate header total != rows shown (got: $hdr)"
out="$(bash "$SCRIPT" roster "$TMP/roster.md" --level 0 --stage close --owner-repo Towheads/temperloop)"
hdr="$(printf '%s\n' "$out" | head -1)"
tot="$(sed -E 's/.*closed: ([0-9]+) items.*/\1/' <<<"$hdr")"
sum=0
for f in 'merged' 'left open' 'skipped' 'unchanged'; do
  sum=$((sum + $(sed -E "s/.*· ([0-9]+) $f.*/\1/" <<<"$hdr")))
done
[ "$sum" -eq "$tot" ] || fail "close header partition does not sum to the total (got: $hdr)"
echo "PASS: roster header counts are DERIVED from the rows and sum to the level total (arithmetic self-consistency)"

# --- roster never infers an unresolvable value -------------------------------
out="$(bash "$SCRIPT" roster "$TMP/roster.md" --level 0 --stage launch --owner-repo Towheads/temperloop)"
grep -q '^\[?\] foxtrot .*sentinel is not one of' <<<"$out" \
  || fail "an out-of-schema sentinel did not render the report-only [?] marker + reason (got: $out)"
grep -q '^\[m\] echo  *no issue' <<<"$out" \
  || fail "an item with no gh_issue: did not render the literal 'no issue' (got: $out)"
grep -q '^\[-\] delta  *Towheads/ssmobile#77' <<<"$out" \
  || fail "a cross-repo item did not render a fully-qualified issue ref (got: $out)"
grep -q '^\[~\] bravo .*resume → 3g re-attach PR #1798' <<<"$out" \
  || fail "a [~] item carrying pr: did not render the resume stage (got: $out)"
out="$(bash "$SCRIPT" roster "$TMP/roster.md" --level 0 --stage launch --only-slugs bravo)"
grep -q '^\[~\] bravo .*continuation' <<<"$out" \
  || fail "--only-slugs did not render its member at the continuation stage (got: $out)"
grep -q '^\[ \] alpha .*parked' <<<"$out" \
  || fail "a still-open sibling outside --only-slugs was not reported as parked (got: $out)"
echo "PASS: roster names every unestablishable value ([?], 'no issue') and never infers one"

# --- roster bad args → structured ERROR + non-zero ----------------------------
for badargs in "--level 0 --stage bogus" "--level nine --stage launch" "--level 9 --stage launch"; do
  rc=0
  # shellcheck disable=SC2086
  out="$(bash "$SCRIPT" roster "$TMP/roster.md" $badargs 2>/dev/null)" || rc=$?
  [ "$rc" -ne 0 ] && [ "$(jq -r .outcome <<<"$out")" = "ERROR" ] \
    || fail "roster $badargs not structured ERROR + non-zero (got: $out)"
done
echo "PASS: roster bad args (unknown stage, non-numeric level, empty level) → structured ERROR + non-zero"

# --- THE INVOCATION GUARD: build.md must still CALL the renderer -------------
# claude/commands/build.md § 3-launch / § 4a / § 4d each invoke plan.sh roster.
# Deleting an invocation from the spec turns this red — that is the whole point:
# an AI-executed spec has no runtime tally, so the invocation's PRESENCE is what
# an execution signal can hold onto.
BUILD_MD="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)/claude/commands/build.md"
if [ -f "$BUILD_MD" ]; then
  for st in launch gate close; do
    grep -qE "plan\\.sh[\"\`']? roster .*--stage $st" "$BUILD_MD" \
      || fail "claude/commands/build.md no longer invokes plan.sh roster --stage $st"
  done
  echo "PASS: claude/commands/build.md invokes plan.sh roster at all three sites (launch/gate/close)"
else
  echo "SKIP: build.md invocation guard (spec not present in this checkout)"
fi

# --- temperloop#2083 round 3: `merge_blocked` is DURABLE and survives a resume -
# The pre-push review's HIGH 2: the dual-build merge hold lived only in the
# current invocation's in-memory level summary. A crash or a `/build <plan>`
# resume between Step 3 (which computes it) and Step 4 (which consumes it) left
# an ordinary-looking `[m]` item with an ordinary `pr:` line and merged it
# UNSTAMPED — the exact ADR 0040 disclosure violation the hold exists to
# prevent, reached by silent loss rather than by logic. The fix makes the note
# itself the carrier. This block is the RESUME test: persist → re-read from the
# note alone → assert the gate surface still excludes it.
# Re-install the 200-returning curl shim: a later block above swapped it for an
# unreachable one, and this block needs the WRITTEN path.
cat > "$TMP/bin/curl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$TMP/curl-args"
for a in "\$@"; do case "\$a" in @*) cp "\${a#@}" "$TMP/put-body" ;; esac; done
printf '200'
EOF
chmod +x "$TMP/bin/curl"

cat > "$TMP/mb.md" <<'EOF'
---
tags: [plan, project/temperloop]
date: 2026-09-19
status: approved
---

# temperloop - merge_blocked fixture

## Items

- [~] **Dual built** `slug: dual` — winner routed to PR
  - branch: `feat/dual`
  - size: M
  - gh_issue: 2083
  - acceptance:
    - it works

- [~] **Ordinary** `slug: plain` — single-arm item
  - branch: `feat/plain`
  - size: S
  - acceptance:
    - it works
EOF

# 1. PERSIST — park `[m]` and stamp the hold in the same writeback.
out="$(PATH="$TMP/bin:$PATH" PLAN_API_KEY_FILE="$TMP/keydir/data.json" \
  bash "$SCRIPT" writeback "$TMP/mb.md" --slug dual --sentinel '[m]' \
  --pr 2083 --pushed-sha deadbee --merge-blocked arms-trailer-unstamped)"
[ "$(jq -r .outcome <<<"$out")" = "WRITTEN" ] || fail "#2083 r3: writeback --merge-blocked not WRITTEN (got: $out)"
grep -q '^  - merge_blocked: arms-trailer-unstamped' "$TMP/put-body" \
  || fail "#2083 r3: writeback did not stamp the merge_blocked sub-line — the hold has no durable carrier and a resumed gate would merge an unstamped dual-build PR"

# 2. RE-READ — the persisted note is the ONLY input from here on. This is the
#    resumed run: nothing in memory survived.
cp "$TMP/put-body" "$TMP/mb-resumed.md"

# 3. STICKINESS — a later writeback that names neither flag must NOT drop the
#    hold. Every sentinel flip after park would otherwise silently un-block it.
out="$(PATH="$TMP/bin:$PATH" PLAN_API_KEY_FILE="$TMP/keydir/data.json" \
  bash "$SCRIPT" writeback "$TMP/mb-resumed.md" --slug dual --sentinel '[m]' --pr 2083)"
grep -q '^  - merge_blocked: arms-trailer-unstamped' "$TMP/put-body" \
  || fail "#2083 r3: a writeback that did not name the flag DROPPED the merge_blocked sub-line — a hold that any later sentinel flip erases is no hold at all"
cp "$TMP/put-body" "$TMP/mb-resumed.md"

# 4. THE GATE SURFACE — roster --stage gate is what Step 4 renders and counts.
#    A held item must be reported, named, and OUT of the merge set.
out="$(bash "$SCRIPT" roster "$TMP/mb-resumed.md" --level 0 --stage gate --owner-repo Towheads/temperloop)"
grep -q 'MERGE BLOCKED (arms-trailer-unstamped)' <<<"$out" \
  || fail "#2083 r3: the resumed gate roster does not name the hold — a blocked item with a green, OPEN PR reads identically to a merge-eligible one (got: $out)"
grep -q 'held out of the merge set' <<<"$out" \
  || fail "#2083 r3: the resumed gate roster does not say the item is held OUT of the merge set (got: $out)"
# Capture the held row FIRST. Asserting "no [m] row says 'in the merge set'"
# straight off the pipeline would pass just as happily when there is NO [m] row
# at all — a roster that dropped the item entirely would read as success.
mb_row="$(grep -E '^\[m\][[:space:]]+dual' <<<"$out" || true)"
[ -n "$mb_row" ] \
  || fail "#2083 r3: the resumed gate roster has no [m] row for the held item — it was dropped from the roster rather than held out of the merge set (got: $out)"
case "$mb_row" in
  *'in the merge set'*)
    fail "#2083 r3: the resumed gate roster still reports the held item IN the merge set (got: $mb_row)" ;;
esac
# The merge COUNT is what a consenting operator actually reads at the gate.
# `plain` is [~] and `dual` is held, so BOTH sit outside and the count is ZERO.
# Asserted on the rendered header ALONE, and on the exact rendered field: an
# `|| grep 'MERGE BLOCKED'` fallback would make this vacuous, since assertion 4a
# above has already proved that string present — the check could never go red.
grep -F '2 items · 0 in the merge set · 2 outside it' <<<"$out" >/dev/null \
  || fail "#2083 r3: the held item did not leave the merge COUNT — the gate header still offers it for merge (got: $out)"

# 5. CLEARING is EXPLICIT — the one way out is landing the trailer.
out="$(PATH="$TMP/bin:$PATH" PLAN_API_KEY_FILE="$TMP/keydir/data.json" \
  bash "$SCRIPT" writeback "$TMP/mb-resumed.md" --slug dual --sentinel '[m]' --pr 2083 --clear-merge-blocked)"
grep -q '^  - merge_blocked:' "$TMP/put-body" \
  && fail "#2083 r3: --clear-merge-blocked left the sub-line in place"
out="$(bash "$SCRIPT" roster "$TMP/put-body" --level 0 --stage gate --owner-repo Towheads/temperloop)"
grep -q 'in the merge set' <<<"$out" \
  || fail "#2083 r3: a CLEARED item never rejoins the merge set — the exclusion would be permanent (got: $out)"

# 6. The two flags are mutually exclusive — a writeback that both sets and
#    clears has no defensible outcome, so it must refuse rather than pick one.
set +e
out="$(PATH="$TMP/bin:$PATH" PLAN_API_KEY_FILE="$TMP/keydir/data.json" \
  bash "$SCRIPT" writeback "$TMP/mb-resumed.md" --slug dual --sentinel '[m]' \
  --merge-blocked x --clear-merge-blocked 2>&1)"
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "#2083 r3: --merge-blocked together with --clear-merge-blocked was accepted (got: $out)"
echo "PASS: #2083 r3 — merge_blocked persists to the plan note, is sticky across writebacks, keeps a resumed gate roster from counting the item in the merge set, and clears only explicitly"
