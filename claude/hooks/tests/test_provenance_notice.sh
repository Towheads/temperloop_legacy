#!/usr/bin/env bash
# Tests for the two halves of the unprompted toolkit-provenance notice
# (temperloop#1047): claude/hooks/session-start-provenance.sh (session start)
# and claude/hooks/subtree-edit-guard.sh's re-probe (the moment drift begins).
#
# Both halves ship together because neither covers the other's case: a
# session-start check is structurally blind to a mid-session edit, and the edit
# guard never fires on a session that merely INHERITED a modified tree.
#
# Fixture: a real, synthetic vendoring consumer built with an actual squashing
# `git subtree add`, whose vendored kernel/ dir carries copies of the hooks and
# the probe at their real relative positions — so the script-relative
# resolution the production symlink install depends on is exercised, not
# stubbed. Zero network.
#
# Covers:
#   A1 session start, MODIFIED tree  -> additionalContext naming the drift
#   A2 session start, RELEASED tree  -> silent (no nagging a clean checkout)
#   A3 session start, UNKNOWN        -> silent
#   A4 EVAL_RUN                      -> silent
#   A5 no probe on disk              -> silent, exit 0 (fail-open)
#   A6 CROSS-ENGAGEMENT: run with cwd inside a SECOND, unrelated project tree,
#      the notice still fires — with a control proving a $PWD-scoped probe
#      would have said nothing there
#   B1 edit guard on a clean tree    -> ask reason carries the "currently
#      RELEASED, this edit is the moment it stops" line (the mid-session notice)
#   B2 edit guard on a modified tree -> ask reason carries the "ALREADY
#      MODIFIED" line
#   B3 build-worker bypass path      -> the same notice reaches stderr
#   B4 probe absent                  -> guard still asks, with no notice
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOKS_DIR=$(cd "$HERE/.." && pwd)
REPO_ROOT=$(cd "$HOOKS_DIR/../.." && pwd)
START_HOOK="$HOOKS_DIR/session-start-provenance.sh"
GUARD="$HOOKS_DIR/subtree-edit-guard.sh"
PROBE="$REPO_ROOT/workflows/scripts/toolkit-provenance.sh"

[ -f "$START_HOOK" ] || { echo "FATAL: hook not found at $START_HOOK" >&2; exit 1; }
[ -f "$GUARD" ] || { echo "FATAL: guard not found at $GUARD" >&2; exit 1; }
[ -f "$PROBE" ] || { echo "FATAL: probe not found at $PROBE" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required for this test" >&2; exit 1; }

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

TMP=$(mktemp -d "${TMPDIR:-/tmp}/test-provenance-notice-XXXXXX")
trap 'rm -rf "$TMP"' EXIT

# Never let a fixture resolve as the managed clone.
export TEMPERLOOP_HOME="$TMP/no-such-managed-home"

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "PASS: $1"; }

# --- Fixture: a real vendoring consumer -----------------------------------
UP="$TMP/up"
mkdir -p "$UP/workflows/scripts" "$UP/claude/hooks"
git init -q --initial-branch=main "$UP"
# Fixture identity, set LOCALLY per repo (temperloop#1047 CI): `git subtree`
# runs its own internal `git commit`, which uses AMBIENT config -- not the
# `-c user.*` this suite passes to its own explicit commits. A CI runner has
# no global identity and its `runner` account has no GECOS name, so that
# internal commit died with "empty ident name" and the fixture silently lost
# its subtree-split marker. A dev machine hid this by deriving a fallback
# name from the user record.
git -C "$UP" config user.name "Fixture"
git -C "$UP" config user.email "fixture@example.invalid"
git -C "$UP" config commit.gpgsign false
printf 'alpha\n' >"$UP/a.txt"
cp "$PROBE" "$UP/workflows/scripts/toolkit-provenance.sh"
cp "$START_HOOK" "$UP/claude/hooks/session-start-provenance.sh"
cp "$HOOKS_DIR/eval-guard.sh" "$UP/claude/hooks/eval-guard.sh"
cp "$GUARD" "$UP/claude/hooks/subtree-edit-guard.sh"
git -C "$UP" add -A
git -C "$UP" commit -qm "kernel v0.1.0"
git -C "$UP" tag v0.1.0

CON="$TMP/con"
mkdir -p "$CON"
git init -q --initial-branch=main "$CON"
# Fixture identity, set LOCALLY per repo (temperloop#1047 CI): `git subtree`
# runs its own internal `git commit`, which uses AMBIENT config -- not the
# `-c user.*` this suite passes to its own explicit commits. A CI runner has
# no global identity and its `runner` account has no GECOS name, so that
# internal commit died with "empty ident name" and the fixture silently lost
# its subtree-split marker. A dev machine hid this by deriving a fallback
# name from the user record.
git -C "$CON" config user.name "Fixture"
git -C "$CON" config user.email "fixture@example.invalid"
git -C "$CON" config commit.gpgsign false
printf '# consumer\n' >"$CON/README.md"
git -C "$CON" add -A
git -C "$CON" commit -qm init
# `-c protocol.file.allow=always`: git 2.38.1 (CVE-2022-39253) hardened the
# `file` transport, and CI runner images set `protocol.file.allow=never` in the
# SYSTEM gitconfig — so `git subtree add|pull` from a local fixture path dies
# with "transport 'file' not allowed". The fixture is entirely local and
# self-built, so re-allowing it here is scoped to the fixture, never production.
# The failure is also made LOUD: a silently-broken fixture used to surface as a
# wrong PROBE verdict (UNKNOWN instead of RELEASED), blaming the code under test
# for a setup failure (temperloop#1047 CI).
git -C "$CON" -c protocol.file.allow=always subtree add --prefix=kernel "$UP" v0.1.0 --squash \
  -m "chore(kernel): subtree pull v0.1.0" >"$TMP/subtree-add.log" 2>&1 \
  || fail "fixture: 'git subtree add' failed, so no subtree-split marker exists — $(tr '\n' ' ' <"$TMP/subtree-add.log")"
printf 'tag v0.1.0\nsha %s\n' "$(git -C "$UP" rev-parse 'v0.1.0^{commit}')" >"$CON/.kernel-pin"
git -C "$CON" add .kernel-pin
git -C "$CON" commit -qm "chore(kernel): pin v0.1.0"

FIX_START="$CON/kernel/claude/hooks/session-start-provenance.sh"
FIX_GUARD="$CON/kernel/claude/hooks/subtree-edit-guard.sh"

OTHER="$TMP/other-project"
mkdir -p "$OTHER"
git init -q --initial-branch=main "$OTHER"
# Fixture identity, set LOCALLY per repo (temperloop#1047 CI): `git subtree`
# runs its own internal `git commit`, which uses AMBIENT config -- not the
# `-c user.*` this suite passes to its own explicit commits. A CI runner has
# no global identity and its `runner` account has no GECOS name, so that
# internal commit died with "empty ident name" and the fixture silently lost
# its subtree-split marker. A dev machine hid this by deriving a fallback
# name from the user record.
git -C "$OTHER" config user.name "Fixture"
git -C "$OTHER" config user.email "fixture@example.invalid"
git -C "$OTHER" config commit.gpgsign false
printf 'unrelated\n' >"$OTHER/x.txt"
git -C "$OTHER" add -A
git -C "$OTHER" commit -qm "unrelated project"

run_start() { # run_start <cwd> [env NAME=VALUE ...]
  local cwd="$1"; shift
  ( cd "$cwd" && env "$@" bash "$FIX_START" </dev/null 2>/dev/null )
}

run_guard() { # run_guard <cwd> <file_path> [env NAME=VALUE ...] ; stdout+stderr merged
  local cwd="$1" fp="$2"; shift 2
  local json
  json=$(jq -cn --arg fp "$fp" --arg cwd "$cwd" \
    '{tool_name:"Edit", tool_input:{file_path:$fp}, cwd:$cwd}')
  ( cd "$cwd" && env "$@" bash "$FIX_GUARD" <<<"$json" 2>&1 )
}

# ===========================================================================
# A2 — clean tree, session start: silent
# ===========================================================================
out="$(run_start "$CON")"
[ -z "$out" ] || fail "A2: a RELEASED checkout must produce no session-start notice — got: $out"
pass "A2: session start on a released checkout says nothing"

# ===========================================================================
# B1 — the mid-session notice, delivered by the edit guard on a clean tree
# ===========================================================================
out="$(run_guard "$CON" "$CON/kernel/a.txt")"
grep -q '"permissionDecision":"ask"' <<<"$out" || fail "B1: the guard did not ask — got: $out"
grep -q 'TOOLKIT PROVENANCE' <<<"$out" || fail "B1: no provenance notice in the ask reason — got: $out"
grep -q 'currently reports RELEASED' <<<"$out" \
  || fail "B1: expected the honest 'currently RELEASED, this edit starts the drift' wording — got: $out"
grep -q 'temperloop doctor' <<<"$out" || fail "B1: expected the on-ramp command named — got: $out"
pass "B1: editing the vendored tree mid-session produces a provenance notice in that same session"

# ===========================================================================
# A1 — session start, MODIFIED tree
# ===========================================================================
printf 'alpha-EDITED\n' >"$CON/kernel/a.txt"
out="$(run_start "$CON")"
[ -n "$out" ] || fail "A1: a MODIFIED checkout must produce a session-start notice"
ctx="$(jq -r '.hookSpecificOutput.additionalContext // empty' <<<"$out" 2>/dev/null)"
[ -n "$ctx" ] || fail "A1: output is not a SessionStart additionalContext block — got: $out"
grep -q 'NOT the release it claims' <<<"$ctx" || fail "A1: notice does not state the verdict — got: $ctx"
grep -q 'kernel/a.txt' <<<"$ctx" || fail "A1: notice does not name the drifted path — got: $ctx"
grep -q 'v0.1.0' <<<"$ctx" || fail "A1: notice does not name the claimed release — got: $ctx"
pass "A1: session start on a modified checkout injects an unprompted notice naming the release and the drift"

# ===========================================================================
# A6 — cross-engagement
# ===========================================================================
out="$(run_start "$OTHER")"
ctx="$(jq -r '.hookSpecificOutput.additionalContext // empty' <<<"$out" 2>/dev/null)"
[ -n "$ctx" ] \
  || fail "A6: a session in a second, unrelated project must still surface the shared toolkit's notice — got: $out"
grep -q 'kernel/a.txt' <<<"$ctx" || fail "A6: notice lost the drifted path when run from elsewhere — got: $ctx"
# Control: a $PWD-scoped probe would have found nothing to report there.
v_other="$(bash "$PROBE" --root "$OTHER" --format verdict)"
[ "$v_other" = "UNKNOWN" ] \
  || fail "A6: control failed — the unrelated project tree itself should be UNKNOWN, got '$v_other'"
pass "A6: the notice follows the toolkit, not \$PWD — a second, unrelated project tree still gets it"

# ===========================================================================
# B2 — edit guard on an already-modified tree
# ===========================================================================
out="$(run_guard "$CON" "$CON/kernel/a.txt")"
grep -q 'ALREADY reports MODIFIED' <<<"$out" \
  || fail "B2: expected the already-modified wording — got: $out"
pass "B2: the edit guard reports an already-modified tree as such, not as newly-drifting"

# ===========================================================================
# B3 — build-worker bypass still carries the notice (on stderr)
# ===========================================================================
out="$(run_guard "$CON" "$CON/kernel/a.txt" KERNEL_EDIT_ACK=1)"
grep -q '"permissionDecision":"ask"' <<<"$out" && fail "B3: the bypass should not ask — got: $out"
grep -q 'TOOLKIT PROVENANCE' <<<"$out" \
  || fail "B3: the bypass note lost the provenance notice — got: $out"
pass "B3: the acknowledged/bypassed path still surfaces the provenance notice"

# ===========================================================================
# B4 — probe absent: the guard still asks, with no notice (fail-open)
# ===========================================================================
out="$(run_guard "$CON" "$CON/kernel/a.txt" TOOLKIT_PROVENANCE_SH="$TMP/absent-probe.sh")"
grep -q '"permissionDecision":"ask"' <<<"$out" \
  || fail "B4: an absent probe must not stop the guard from asking — got: $out"
grep -q 'TOOLKIT PROVENANCE' <<<"$out" && fail "B4: a notice was fabricated with no probe — got: $out"
pass "B4: an absent probe degrades to the guard's pre-existing behaviour (fail-open)"

# ===========================================================================
# A3 — UNKNOWN verdict: silent
# ===========================================================================
out="$(run_start "$OTHER" TOOLKIT_PROVENANCE_SH="$PROBE" TOOLKIT_PROVENANCE_ROOT="$OTHER")"
[ -z "$out" ] || fail "A3: an UNKNOWN verdict must produce no notice — got: $out"
pass "A3: an UNKNOWN verdict says nothing (no baseline is not a finding)"

# ===========================================================================
# A4 / A5 — EVAL_RUN, and no probe on disk
# ===========================================================================
out="$(run_start "$CON" EVAL_RUN=1)"
[ -z "$out" ] || fail "A4: EVAL_RUN must suppress the notice — got: $out"
pass "A4: EVAL_RUN suppresses the notice"

out="$(run_start "$CON" TOOLKIT_PROVENANCE_SH="$TMP/absent-probe.sh")"
rc=$?
[ -z "$out" ] || fail "A5: an absent probe must produce no output — got: $out"
[ "$rc" = "0" ] || fail "A5: an absent probe must exit 0 (fail-open), got rc=$rc"
pass "A5: an absent probe fails open — no output, exit 0"

# ===========================================================================
# Read-only contract
# ===========================================================================
before="$(git -C "$CON" status --porcelain)"
run_start "$CON" >/dev/null
run_guard "$CON" "$CON/kernel/a.txt" >/dev/null
after="$(git -C "$CON" status --porcelain)"
[ "$before" = "$after" ] || fail "R: a notice hook mutated the tree (before='$before' after='$after')"
pass "R: neither notice half writes anything to the tree it reports on"

echo
echo "All provenance-notice hook tests passed."
