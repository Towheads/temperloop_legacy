#!/usr/bin/env bash
#
# test_reviewer_seat_tiers.sh — the model-tier invariant for the review seats
# /build §3e spawns (temperloop#1456, epic #1616).
#
# WHY THIS EXISTS. `runReviewers()` in claude/workflows/build-level.mjs spawns
# each routed reviewer with NO `model` override, on the stated reasoning that
# "the reviewer's OWN agent definition sets its tier". That reasoning is only
# sound while every one of those definitions actually DECLARES a tier: a
# charter declaring `model: inherit` takes whichever model the CALLING context
# runs under, and an autonomous drive runs cheap by design
# ($PIPELINE_DRIVE_MODEL). `architecture-reviewer` declared exactly that while
# its own prose promised the seat is "never down-tiered" — two statements
# standing in disagreement, with nothing mechanical between them. Nothing
# errored; the review would simply have run weaker than designed, invisibly, on
# precisely the `kind: architectural` items the seat exists to protect.
#
# The gap this closes is a MEASUREMENT gap, which is epic #1616's whole theme:
# the tier a seat resolves to is not observable from any artifact the pipeline
# produces, so a silent down-tier leaves no trace to notice later. The
# declaration is the only place it can be checked, so it is checked here.
#
# WHAT IT ASSERTS (each case is one property, not one file):
#   1. architecture-reviewer declares an explicit tier — never `inherit` — and
#      specifically `opus`, the pinned strong tier its own prose promises.
#   2. Its charter prose names the tier its frontmatter actually declares, and
#      no longer claims the session model (the doc-vs-mechanism disagreement,
#      restated as the property rather than as a banned string).
#   3. The §3e reviewers that remain cheap still declare `sonnet` — the no-op
#      assertion: whatever fixes case 1 must not move them.
#   4. runReviewers() passes no `model` override anywhere in its body, so
#      frontmatter remains the single tier authority for every routed seat.
#   5. The two GATE-BEARING seats temperloop#2132 moved — `workflow-reviewer`
#      and `typescript-reviewer` — declare `model: inherit`, AND each charter's
#      prose states that tier rather than still claiming the `sonnet` it used
#      to declare. That is case 2's doc-vs-mechanism property applied to the
#      seats this item moved: the same disagreement, in mirror image, is
#      exactly what an edit to one half and not the other would recreate.
#
# WHY CASE 4 ANCHORS ON THE FUNCTION, NOT ON ONE SPAWN SITE INSIDE IT. It
# originally located the spawn by its `for (const route of routes)` loop header.
# That spawn shape has now moved TWICE — most recently the loop became
# `routes.map(...)` feeding a bounded fanout wait (temperloop#2003) — and the
# move silently disarmed the locator: the invariant still held, but the guard
# could no longer find the thing it guards. The property was never about one
# loop. It is about the WHOLE of runReviewers(): no `model` override may be
# passed from anywhere in it, however the spawn is arranged internally. So the
# locator is the function's own declaration line and its closing brace, which no
# internal restructure changes.
#
# Scope: the seats /build §3e routes, PLUS `claude/agents/reviewers/
# typescript-reviewer.md` (temperloop#2132). The rest of the
# `claude/agents/reviewers/**` language catalog stays deliberately NOT covered
# — those seats are inert, opted-in per adopter repo, and their tiers were
# dispositioned separately (docs/model-fanout-inventory.md § B3).
# `typescript-reviewer` is the exception because it is NOT inert here:
# `workflows/scripts/config/reviewer-routing.tsv` routes `.ts`/`.js`/`.mjs`
# straight to it, so every diff touching the build engine itself is gated on
# that seat in THIS repo, not only in an adopter's.
#
# No network, no HOME mutation, no tmpdir: every assertion reads a tracked file.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
AGENTS_DIR="${REPO_ROOT}/claude/agents"
BUILD_LEVEL="${REPO_ROOT}/claude/workflows/build-level.mjs"

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "PASS: $1"; }

# Read the `model:` value out of a charter's YAML frontmatter — the FIRST
# `---`-delimited block only, so a `model:` mentioned in the body prose can
# never be mistaken for the declaration.
frontmatter_model() {
  awk '
    /^---[[:space:]]*$/ { n++; if (n >= 2) exit; next }
    n == 1 && /^model:[[:space:]]/ { sub(/^model:[[:space:]]*/, ""); sub(/[[:space:]]+$/, ""); print; exit }
  ' "$1"
}

# ---------------------------------------------------------------------------
# Test 1: architecture-reviewer declares an explicit tier, never `inherit`,
# and specifically `opus`.
#
# The seat's output IS the gate (nothing downstream mechanically checks a
# boundary call), so under `/build` 3c § Model tiering — *tier by measured
# rounds, not by an assumed gate* — no cheaper tier is admissible without a
# paired measurement, and `inherit` is not a tier at all, it is a deferral to
# whoever spawned the seat.
#
# The `opus` half is asserted on top of the generic not-inherit property rather
# than in place of it, because the two guard different things: not-inherit
# guards the temperloop#1456 deferral defect, while naming `opus` guards the
# PIN itself — the seat's charter promises a FLOOR ("never down-tiered"), and
# only a specific strong tier delivers one. temperloop#2132 moved two sibling
# seats to `inherit`, so the difference between the two mechanisms is now load-
# bearing here and is checked, not assumed.
# ---------------------------------------------------------------------------
ARCH="${AGENTS_DIR}/architecture-reviewer.md"
[ -f "$ARCH" ] || fail "1: charter not found at $ARCH"

arch_model="$(frontmatter_model "$ARCH")"
[ -n "$arch_model" ] || fail "1: architecture-reviewer.md declares no frontmatter 'model:' at all"
if [ "$arch_model" = "inherit" ]; then
  fail "1: architecture-reviewer declares 'model: inherit' — the seat its own charter calls 'never down-tiered' would take the CALLING context's tier, so an autonomous drive on \$PIPELINE_DRIVE_MODEL silently down-tiers it (temperloop#1456). Declare an explicit tier."
fi
if [ "$arch_model" != "opus" ]; then
  fail "1: architecture-reviewer declares 'model: ${arch_model}', expected 'opus' — this seat PINS the strong tier so its 'never down-tiered' promise is a floor rather than a deferral to the caller (temperloop#1456). temperloop#2132 moved workflow-reviewer/typescript-reviewer to 'inherit' deliberately; this seat is the one that must not follow."
fi
pass "1: architecture-reviewer pins the strong tier (model: ${arch_model}), not inherit"

# ---------------------------------------------------------------------------
# Test 2: the charter prose agrees with the frontmatter.
#
# The original defect was not the value alone — it was the DISAGREEMENT
# between a charter promising "never down-tiered" and a frontmatter deferring
# the tier to the caller. Fixing one and leaving the other standing would
# re-create it in mirror image.
# ---------------------------------------------------------------------------
#
# Stated as two positive properties rather than "the string `model: inherit`
# never appears": the charter SHOULD be free to record what it used to declare
# and why that was wrong — that history is the reason the next reader does not
# re-derive it. What it must not do is describe its CURRENT tier as anything
# other than what the frontmatter says.
if ! grep -qF "\`model: ${arch_model}\`" "$ARCH"; then
  fail "2: architecture-reviewer.md's frontmatter declares '${arch_model}' but its prose never states that tier — the charter must name the tier it actually runs on (temperloop#1456)"
fi
if grep -q 'runs on the \*\*session model\*\*' "$ARCH"; then
  fail "2: architecture-reviewer.md's prose still claims the seat runs on the session model while its frontmatter declares '${arch_model}' — the doc and the mechanism disagree (temperloop#1456)"
fi
pass "2: architecture-reviewer's prose states its declared tier and no longer claims the session model"

# ---------------------------------------------------------------------------
# Test 3: the §3e reviewers that stay cheap are untouched — still `sonnet`.
#
# This is the no-op assertion: it fails if a tier change elsewhere in this file
# moved a seat it had no business moving. `workflow-reviewer` LEFT this roster
# at temperloop#2132 and is asserted in case 5 instead; `docs-reviewer` and
# `requirements-auditor` stay, and `docs-reviewer` stays deliberately — its
# known gap is severity CALIBRATION, owned by temperloop#2128, not recall, so
# a stronger model is not the instrument for it.
# ---------------------------------------------------------------------------
for seat in docs-reviewer requirements-auditor; do
  charter="${AGENTS_DIR}/${seat}.md"
  [ -f "$charter" ] || fail "3: charter not found at $charter"
  got="$(frontmatter_model "$charter")"
  [ "$got" = "sonnet" ] || fail "3: ${seat} declares 'model: ${got:-<none>}', expected 'sonnet' — the temperloop#1456 tier fix, and the temperloop#2132 move of its two gate-bearing siblings, must both be a no-op for this seat"
done
pass "3: docs-reviewer and requirements-auditor still declare model: sonnet"

# ---------------------------------------------------------------------------
# Test 4: runReviewers() passes no `model` override.
#
# Cases 1 and 3 only mean anything while the frontmatter is what the spawn
# actually honours. A caller-side override would quietly become a second,
# competing tier authority — and would have to be re-applied at every one of
# this seat's call sites (/build §3e, /assess Step 3, /workshop Step 3.3/3.5),
# which is the reason the fix went into the frontmatter instead.
#
# The extraction is anchored on the FUNCTION (declaration line -> first
# column-0 `}`), never on the spawn's current internal arrangement — see the
# header's "WHY CASE 4 ANCHORS ON THE FUNCTION". Every nested construct in this
# function (the arrow helpers, the `.then` recorder, the `routes.map`) closes at
# an indented brace, so the first column-0 `}` is the function's own end.
# ---------------------------------------------------------------------------
[ -f "$BUILD_LEVEL" ] || fail "4: build-level.mjs not found at $BUILD_LEVEL"

spawn_block="$(awk '
  /^async function runReviewers/ { inblock = 1 }
  inblock { print }
  inblock && /^}/ { exit }
' "$BUILD_LEVEL")"
[ -n "$spawn_block" ] || fail "4: could not locate the runReviewers() function in build-level.mjs (expected a line starting \`async function runReviewers\`) — the locator, not the invariant, is what broke; re-anchor it rather than relaxing the assertion"

if printf '%s\n' "$spawn_block" | grep -vE '^[[:space:]]*(//|\*|/\*)' | grep -E '\bmodel[[:space:]]*:' >/dev/null; then
  fail "4: runReviewers() passes a 'model' override — the reviewer frontmatter is no longer the single tier authority (temperloop#1456)"
fi
pass "4: runReviewers() passes no model override; frontmatter remains the single tier authority"

# ---------------------------------------------------------------------------
# Test 5: the two gate-bearing seats declare `inherit`, and say so.
#
# temperloop#2132 moved `workflow-reviewer` and `typescript-reviewer` off
# `sonnet` onto `model: inherit` — the session model — under the CURRENT rule
# in `/build` 3c § Model tiering as rewritten by temperloop#2140: *tier by
# measured rounds, not by an assumed gate*. A seat moves to a cheaper model
# only on a paired measurement showing it costs less PER MERGED ITEM, and a
# seat whose output IS the gate stays on the session model without needing
# one. Both of these are gates: a HIGH from either at §3e loops the item back
# to 3c for another build round (build.md, "Blocking — HIGH severity only")
# rather than being filtered by a human, and no paired measurement was run
# (it is parked to temperloop#2134).
#
# The prose half is asserted for the same reason case 2 asserts it on
# `architecture-reviewer`: the original defect was the DISAGREEMENT between a
# charter and its frontmatter, not either value alone. These two charters each
# carried a paragraph justifying `sonnet`; moving the frontmatter and leaving
# that paragraph would recreate temperloop#1456 in mirror image.
#
# `inherit` is NOT the same guarantee as `architecture-reviewer`'s pin, and
# this file asserts both precisely so the difference stays visible: `inherit`
# buys parity with the calling context, a pin buys a floor. A cheap autonomous
# drive that reached §3e would run these two seats cheap. That residual is
# accepted for them and NOT accepted for `architecture-reviewer` (case 1).
# ---------------------------------------------------------------------------
INHERIT_SEATS="${AGENTS_DIR}/workflow-reviewer.md ${AGENTS_DIR}/reviewers/typescript-reviewer.md"
for charter in $INHERIT_SEATS; do
  seat="$(basename "$charter" .md)"
  [ -f "$charter" ] || fail "5: charter not found at $charter"
  got="$(frontmatter_model "$charter")"
  [ "$got" = "inherit" ] || fail "5: ${seat} declares 'model: ${got:-<none>}', expected 'inherit' — a §3e HIGH from this seat loops the item back to 3c, so its output IS the gate and § Model tiering keeps it on the session model absent a paired measurement (temperloop#2132)"
  grep -qF '`model: inherit`' "$charter" || fail "5: ${seat}.md declares 'model: inherit' in frontmatter but its prose never states that tier — the charter must name the tier it actually runs on (temperloop#2132, the temperloop#1456 property in mirror image)"
  if grep -q 'seat runs on \*\*`sonnet`\*\*' "$charter"; then
    fail "5: ${seat}.md's prose still claims the seat runs on \`sonnet\` while its frontmatter declares 'inherit' — the doc and the mechanism disagree (temperloop#2132)"
  fi
done
pass "5: workflow-reviewer and typescript-reviewer declare model: inherit, and their prose states that tier"

echo "All reviewer seat-tier tests passed."
