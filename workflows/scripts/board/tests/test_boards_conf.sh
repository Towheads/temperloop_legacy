#!/usr/bin/env bash
#
# Tests for board.sh's boards.conf registry seam (foundation #770). board_repo /
# board_repo / board_owner are deliberately SEPARATE per-axis
# registries (repo-owner vs project-owner vs project-number — #330 paid for
# this distinction); each now resolves through an optional external
# `boards.conf` file BEFORE falling back to the built-in case map. Discovery
# order (first hit wins): machine-level ($BOARDS_CONF_MACHINE, defaulting to
# $XDG_CONFIG_HOME/temperloop/boards.conf) -> repo-local override
# ($BOARDS_CONF_REPO_LOCAL, defaulting to workflows/scripts/board/boards.conf)
# -> the built-in map.
#
# This suite exercises BOTH conf-present and conf-absent (fallback) paths:
#   1. conf-absent: every accessor returns exactly the pre-#770 built-in
#      values (byte-identical fallback — the guarantee a consuming repo with
#      no conf, e.g. stageFind's synced board.sh, relies on).
#   2. repo-local conf present: a value present in the conf overrides the
#      built-in map; a board NOT mentioned in the conf still falls through to
#      the built-in map (partial-conf coexists with fallback).
#   3. machine-level conf takes precedence over a repo-local conf when both
#      exist (discovery-order precedence).
#   4. all three axes (repo/owner/project) are independently overridable.
#
# No network, no gh call — board_repo/board_owner never
# call `_board_gh`.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$HERE/../lib" && pwd)"

fail() { echo "FAIL: $1" >&2; exit 1; }

# shellcheck source=scripts/lib/board.sh
# shellcheck disable=SC1091
source "$LIB_DIR/board.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/board-conf-test-XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# --- 1: conf-absent -> byte-identical fallback -----------------------------
export BOARDS_CONF_MACHINE="$WORK/no-such-machine-conf"
export BOARDS_CONF_REPO_LOCAL="$WORK/no-such-repo-local-conf"

[ "$(board_repo 3)" = "Towheads/stageFind" ]  || fail "board_repo 3 fallback wrong"
[ "$(board_repo 4)" = "Towheads/foundation" ] || fail "board_repo 4 fallback wrong"
[ "$(board_repo 5)" = "Towheads/ssmobile" ]   || fail "board_repo 5 fallback wrong"
[ "$(board_repo 6)" = "Towheads/subsetwiki" ] || fail "board_repo 6 fallback wrong"
if board_repo 9 >/dev/null 2>&1; then fail "board_repo 9 should fail (unmapped, no conf)"; fi

[ "$(board_owner 3)" = "Towheads" ] || fail "board_owner 3 fallback wrong"
[ "$(board_owner 4)" = "Towheads" ] || fail "board_owner 4 fallback wrong"
[ "$(board_owner 9)" = "Towheads" ] || fail "board_owner 9 fallback (BOARD_OWNER default) wrong"

# board_project_number was REMOVED with the Projects-v2 arm (ADR 0004). Assert
# it is genuinely gone rather than merely unused, so it cannot silently
# reappear as a vestigial resolver nothing calls.
if command -v board_project_number >/dev/null 2>&1; then
  fail "board_project_number must NOT exist — it was removed with the Projects-v2 arm (ADR 0004)"
fi

echo "PASS: conf-absent fallback is byte-identical to the pre-#770 built-in map (project axis retired, ADR 0004)"

# --- 2: repo-local conf present, partial coverage --------------------------
cat > "$WORK/repo-local.conf" <<'EOF'
# comment lines and blanks are ignored

board.4.repo=Acme/foundation-fork
board.4.owner=Acme
board.4.project=42
EOF
export BOARDS_CONF_REPO_LOCAL="$WORK/repo-local.conf"
export BOARDS_CONF_MACHINE="$WORK/no-such-machine-conf"   # still absent

[ "$(board_repo 4)" = "Acme/foundation-fork" ] || fail "board_repo 4 should resolve from repo-local conf"
[ "$(board_owner 4)" = "Acme" ]                || fail "board_owner 4 should resolve from repo-local conf"
# The conf above still carries a legacy `board.4.project=42` line (the retired
# Projects-v2 axis, ADR 0004). An operator's old conf must keep working: an
# unknown/retired axis is simply not read, never a parse error, and the live
# repo/owner axes beside it resolve normally. This is the migration case — a
# stale `project=` line is inert, unlike a stale `backend=projects` line, which
# hard-fails on purpose (section 9 below).
[ "$(board_backend 4)" = "issues" ] \
  || fail "a legacy project= line must not disturb backend resolution, got: $(board_backend 4)"

# board 3 is NOT in the conf -> falls through to the built-in map unaffected.
[ "$(board_repo 3)" = "Towheads/stageFind" ] || fail "board_repo 3 should still fall back (not in conf)"
[ "$(board_owner 3)" = "Towheads" ]          || fail "board_owner 3 should still fall back (not in conf)"

echo "PASS: repo-local conf overrides its listed board; unlisted boards still fall back"

# --- 3: machine-level conf takes precedence over repo-local -----------------
cat > "$WORK/machine.conf" <<'EOF'
board.4.repo=Machine/foundation
EOF
export BOARDS_CONF_MACHINE="$WORK/machine.conf"
# BOARDS_CONF_REPO_LOCAL still points at repo-local.conf (board.4.repo=Acme/foundation-fork)

[ "$(board_repo 4)" = "Machine/foundation" ] || fail "machine-level conf should win over repo-local"
# An axis the machine conf does NOT set for board 4 (owner) is looked up in the
# SAME file that won discovery (machine.conf), which has no owner key -> falls
# back to the built-in map, NOT to repo-local.conf's owner=Acme. This pins the
# "one file wins, not a per-key merge across files" discovery contract.
[ "$(board_owner 4)" = "Towheads" ] || fail "board_owner 4 should fall back to built-in (machine.conf has no owner key, no cross-file merge)"

echo "PASS: machine-level conf takes precedence over repo-local (whole-file discovery, not per-key merge)"

# --- 4b: backend axis — vestigial since ADR 0004 removed the Projects-v2 arm.
# An explicit `backend=issues` line is accepted (a no-op that resolves what it
# always did), and a board with NO backend line resolves "issues" too, because
# that is the only backend. The axis's one live job — hard-failing a stale
# `backend=projects` line — is proven in section 9 below and behaviorally in
# test_issues_backend.sh.
cat > "$WORK/backend.conf" <<'EOF'
board.7.repo=Acme/issues-only-repo
board.7.backend=issues
EOF
export BOARDS_CONF_REPO_LOCAL="$WORK/backend.conf"
export BOARDS_CONF_MACHINE="$WORK/no-such-machine-conf"

[ "$(board_backend 7)" = "issues" ] || fail "board_backend 7 should resolve 'issues' from conf"
[ "$(board_backend 4)" = "issues" ] || fail "board_backend 4 (not in conf) should resolve 'issues' — the only backend (ADR 0004)"
[ "$(board_backend 3)" = "issues" ] || fail "board_backend 3 (no conf at all) should resolve 'issues' — the only backend (ADR 0004)"
echo "PASS: an explicit backend=issues line and an absent backend key both resolve 'issues' (ADR 0004)"

# --- 5: unset BOARDS_CONF_* env vars resolve the real default paths --------
# (Just confirm the default-path expressions don't error under `set -u` — we
# don't touch the real $HOME/.config or the real repo-local boards.conf here.)
unset BOARDS_CONF_MACHINE BOARDS_CONF_REPO_LOCAL
_board_conf_file >/dev/null 2>&1 || true   # rc 1 is fine (no real conf in this test env); must not error out
echo "PASS: default discovery paths (unset overrides) evaluate without error"

# --- 6: board 7 = the temperloop tracker (F#808), conf-absent -------------
# Board 7 is registered directly in board_repo()'s BUILT-IN map (not a
# committed boards.conf — see ISSUES-ONLY-BACKEND.md § "The
# temperloop tracker" for why: a real org-qualified repo value is
# exactly the class of literal this checkout's personal-token-denylist
# forbids inside the kernel-vendored tree outside board_repo()'s own
# sanctioned case map). So this mirrors § 1's conf-absent fallback proof,
# just for board 7 specifically — the "boards.conf kernel entry present and
# adapter-resolvable" acceptance proof (F#808).
export BOARDS_CONF_MACHINE="$WORK/no-such-machine-conf-3"
export BOARDS_CONF_REPO_LOCAL="$WORK/no-such-repo-local-conf-3"

[ "$(board_repo 7)" = "Towheads/temperloop" ] \
  || fail "board_repo 7 should resolve the built-in kernel-tracker default, got: $(board_repo 7)"
[ "$(board_backend 7)" = "issues" ] \
  || fail "board_backend 7 should resolve 'issues', got: $(board_backend 7)"
_board_is_issues_only 7 || fail "_board_is_issues_only 7 should be true"

# Boards 3-6 resolve their own built-in repo defaults, and are issues-only too —
# board 7 is no longer an EXCEPTION to a Projects default, since there is no
# Projects default left for it to be an exception to (ADR 0004/0005 supersession).
[ "$(board_repo 3)" = "Towheads/stageFind" ] || fail "board_repo 3 should still resolve its own built-in default"
[ "$(board_backend 4)" = "issues" ]          || fail "board_backend 4 should resolve 'issues' like every other board"
echo "PASS: board 7 (kernel tracker) resolves its built-in repo default conf-absent (F#808); it is no longer a backend exception (ADR 0004)"

# --- 7: a boards.conf CAN still override board 7, exactly like any board ---
cat > "$WORK/board7-override.conf" <<'EOF'
board.7.repo=Acme/kernel-fork
EOF
export BOARDS_CONF_REPO_LOCAL="$WORK/board7-override.conf"
export BOARDS_CONF_MACHINE="$WORK/no-such-machine-conf-4"

[ "$(board_repo 7)" = "Acme/kernel-fork" ] \
  || fail "board_repo 7 should be overridable via boards.conf like any other board, got: $(board_repo 7)"
# backend isn't in this override conf -> still falls through to the built-in
# map's board-7 case (issues), NOT the general "projects" default.
[ "$(board_backend 7)" = "issues" ] \
  || fail "board_backend 7 (repo overridden, backend not) should still resolve 'issues' from the built-in map, got: $(board_backend 7)"
echo "PASS: a boards.conf entry overrides board 7's repo exactly like any other board; backend still falls back to the built-in kernel default"

# --- 8: board_registered_boards() — single source of truth for probes ------
# The accessor every command-spec repo->board reverse-lookup probe iterates
# (temperloop#352), replacing the hardcoded `3 4 5 6` literal. Conf-absent it is
# exactly the built-in set INCLUDING board 7 (the exact #352 gap); a boards.conf
# that registers a NEW board number unions it in, so a probe picks up an
# onboarded board with no command-spec edit (drift-proof).
export BOARDS_CONF_MACHINE="$WORK/no-such-machine-conf-8"
export BOARDS_CONF_REPO_LOCAL="$WORK/no-such-repo-local-conf-8"
[ "$(board_registered_boards | tr '\n' ' ')" = "3 4 5 6 7 " ] \
  || fail "board_registered_boards (conf-absent) should be the built-in set '3 4 5 6 7', got: $(board_registered_boards | tr '\n' ' ')"
board_registered_boards | grep -x 7 >/dev/null \
  || fail "board_registered_boards must include board 7 (temperloop#352: probes dropped it)"

cat > "$WORK/board8.conf" <<'EOF'
board.8.repo=Acme/eighth
EOF
export BOARDS_CONF_REPO_LOCAL="$WORK/board8.conf"
export BOARDS_CONF_MACHINE="$WORK/no-such-machine-conf-8b"
[ "$(board_registered_boards | tr '\n' ' ')" = "3 4 5 6 7 8 " ] \
  || fail "board_registered_boards should union a conf-registered board 8, got: $(board_registered_boards | tr '\n' ' ')"
echo "PASS: board_registered_boards is the built-in set (incl. board 7) unioned with conf-registered boards (temperloop#352)"

# --- 10: composed-tree consumer-root conf (temperloop#494) ------------------
# A self-hosting composed checkout (foundation) vendors the kernel as a
# `kernel/` subtree and exposes workflows/scripts/board as a DIRECTORY SYMLINK
# into it, so the symlink-resolved repo-local path ($_BOARD_LIB_DIR/../
# boards.conf) physically lands INSIDE kernel/ — un-committable (kernel-drift).
# board.sh must instead probe the CONSUMER ROOT (the directory containing
# kernel/) for a real workflows/scripts/board/boards.conf OUTSIDE kernel/,
# BEFORE that symlink-resolved location. This builds a fixture composed tree and
# asserts the probe precedence from a SUBSHELL that re-sources board.sh so its
# $_BOARD_LIB_DIR resolves through the fixture's board symlink (the real
# in-process $_BOARD_LIB_DIR points at this repo's own lib, which is not inside
# a kernel/ subtree). Neither BOARDS_CONF_MACHINE nor BOARDS_CONF_REPO_LOCAL is
# set — the consumer-root layer must fire on its own.
CT="$WORK/composed"
# kernel subtree: the real board.sh + a kernel-internal boards.conf (the path
# the board symlink resolves to — must LOSE to the consumer-root file).
mkdir -p "$CT/kernel/workflows/scripts/board/lib"
cp "$LIB_DIR/board.sh" "$CT/kernel/workflows/scripts/board/lib/board.sh"
cat > "$CT/kernel/workflows/scripts/board/boards.conf" <<'EOF'
board.4.repo=Kernel/should-not-win
EOF
# consumer root: a REAL board dir (its lib is a symlink into the kernel subtree,
# exactly like foundation composes it) holding the committed consumer-owned conf.
mkdir -p "$CT/workflows/scripts/board"
ln -s "../../../kernel/workflows/scripts/board/lib" "$CT/workflows/scripts/board/lib"
cat > "$CT/workflows/scripts/board/boards.conf" <<'EOF'
board.4.repo=Consumer/root-wins
EOF

# Sanity: the fixture reproduces the failing geometry — board.sh's physical lib
# is inside kernel/, and the symlink-resolved repo-local conf is the kernel one.
ct_phys="$(cd "$CT/workflows/scripts/board/lib" && pwd -P)"
case "$ct_phys" in
  */kernel/workflows/scripts/board/lib) : ;;
  *) fail "fixture geometry wrong: board lib did not resolve into kernel/, got: $ct_phys" ;;
esac

ct_repo="$(
  set -euo pipefail
  unset BOARDS_CONF_MACHINE BOARDS_CONF_REPO_LOCAL
  # A machine conf default that certainly does not exist, so layer 1 is inert
  # without depending on the real ~/.config of the host.
  # Deliberately scoped to this subshell only -- never meant to
  # leak into the environment of the parent script.
  # shellcheck disable=SC2030,SC2031
  export XDG_CONFIG_HOME="$WORK/no-such-xdg"
  # shellcheck source=/dev/null
  source "$CT/workflows/scripts/board/lib/board.sh"
  board_repo 4
)"
[ "$ct_repo" = "Consumer/root-wins" ] \
  || fail "composed tree: board_repo 4 should resolve the CONSUMER-ROOT conf before the symlink-resolved kernel one, got: $ct_repo"

# _board_consumer_root_conf points at the consumer-root file, not the kernel one.
ct_conf="$(
  set -euo pipefail
  unset BOARDS_CONF_MACHINE BOARDS_CONF_REPO_LOCAL
  # Deliberately scoped to this subshell only -- never meant to
  # leak into the environment of the parent script.
  # shellcheck disable=SC2030,SC2031
  export XDG_CONFIG_HOME="$WORK/no-such-xdg"
  # shellcheck source=/dev/null
  source "$CT/workflows/scripts/board/lib/board.sh"
  _board_consumer_root_conf
)"
# pwd -P canonicalizes /var -> /private/var on macOS, so compare against the
# physically-resolved expected path rather than the raw mktemp path.
ct_expect="$(cd "$CT/workflows/scripts/board" && pwd -P)/boards.conf"
[ "$ct_conf" = "$ct_expect" ] \
  || fail "_board_consumer_root_conf should return the consumer-root path ($ct_expect), got: $ct_conf"
case "$ct_conf" in
  */kernel/*) fail "consumer-root conf must be OUTSIDE kernel/, got: $ct_conf" ;;
esac

echo "PASS: composed tree resolves the consumer-root boards.conf before the symlink-resolved kernel path (temperloop#494)"

# --- 10b: whole-board-symlink layout has NO consumer-root seam yet ----------
# When workflows/scripts/board is itself a whole-directory symlink into kernel/
# (foundation's CURRENT layout, before it materialises a real board dir), the
# consumer-root candidate resolves BACK inside kernel/ — it is not a committable
# seam, so the probe must decline and fall through to layer 2 unchanged.
CT2="$WORK/composed-symlink"
mkdir -p "$CT2/kernel/workflows/scripts/board/lib"
cp "$LIB_DIR/board.sh" "$CT2/kernel/workflows/scripts/board/lib/board.sh"
cat > "$CT2/kernel/workflows/scripts/board/boards.conf" <<'EOF'
board.4.repo=Kernel/only
EOF
mkdir -p "$CT2/workflows/scripts"
ln -s "../../kernel/workflows/scripts/board" "$CT2/workflows/scripts/board"

ct2_conf="$(
  set -euo pipefail
  unset BOARDS_CONF_MACHINE BOARDS_CONF_REPO_LOCAL
  # Deliberately scoped to this subshell only -- never meant to
  # leak into the environment of the parent script.
  # shellcheck disable=SC2030,SC2031
  export XDG_CONFIG_HOME="$WORK/no-such-xdg"
  # shellcheck source=/dev/null
  source "$CT2/workflows/scripts/board/lib/board.sh"
  if _board_consumer_root_conf; then echo HIT; else echo MISS; fi
)"
[ "$ct2_conf" = "MISS" ] \
  || fail "whole-board-symlink layout should NOT yield a consumer-root seam (candidate resolves back into kernel/), got: $ct2_conf"

# ...and _board_conf_file then falls through to the (kernel-internal) layer-2
# path unchanged — the pre-#494 behavior, so nothing regresses for a tree that
# has not yet materialised a real consumer-owned board dir.
ct2_repo="$(
  set -euo pipefail
  unset BOARDS_CONF_MACHINE BOARDS_CONF_REPO_LOCAL
  # Deliberately scoped to this subshell only -- never meant to
  # leak into the environment of the parent script.
  # shellcheck disable=SC2030,SC2031
  export XDG_CONFIG_HOME="$WORK/no-such-xdg"
  # shellcheck source=/dev/null
  source "$CT2/workflows/scripts/board/lib/board.sh"
  board_repo 4
)"
[ "$ct2_repo" = "Kernel/only" ] \
  || fail "whole-board-symlink layout should fall through to the layer-2 symlink-resolved conf, got: $ct2_repo"

echo "PASS: a whole-board-symlink layout declines the consumer-root seam and falls through to layer 2 unchanged (temperloop#494)"

# --- 10c: a synced-directory consumer is NOT a composed tree ---------------
# stageFind/ssmobile/subsetwiki get a real (banner-stamped copy) board dir with
# no kernel/ subtree above it. board.sh's physical path has no /kernel/
# component, so the consumer-root probe is inert and the existing repo-local
# path resolves their real committed conf unchanged.
CT3="$WORK/synced"
mkdir -p "$CT3/workflows/scripts/board/lib"
cp "$LIB_DIR/board.sh" "$CT3/workflows/scripts/board/lib/board.sh"
cat > "$CT3/workflows/scripts/board/boards.conf" <<'EOF'
board.4.repo=Synced/repo-local
EOF
ct3_repo="$(
  set -euo pipefail
  unset BOARDS_CONF_MACHINE BOARDS_CONF_REPO_LOCAL
  # Deliberately scoped to this subshell only -- never meant to
  # leak into the environment of the parent script.
  # shellcheck disable=SC2030,SC2031
  export XDG_CONFIG_HOME="$WORK/no-such-xdg"
  # shellcheck source=/dev/null
  source "$CT3/workflows/scripts/board/lib/board.sh"
  if _board_consumer_root_conf; then echo "CONSUMER-ROOT-FIRED"; fi
  board_repo 4
)"
[ "$ct3_repo" = "Synced/repo-local" ] \
  || fail "synced-directory consumer should resolve its own repo-local conf (consumer-root probe inert), got: $ct3_repo"

echo "PASS: a synced-directory consumer resolves its committed repo-local conf, consumer-root probe inert (temperloop#494)"

# --- 9: backend axis per-key fallthrough (boards.conf per-axis backend
# fallthrough) — a machine-level conf that EXISTS but is silent on this
# board's backend key must fall through to a repo-local `backend=` entry,
# NOT shadow it whole-file and jump straight to the built-in default. This is
# the fleet-cutover case: a committed repo-local backend flip (e.g.
# board.9.backend=issues) must survive an unrelated machine-level conf
# present on the host for OTHER boards. Deliberately does NOT change the
# repo/owner axes' whole-file contract pinned in section 3 above.
cat > "$WORK/repo-local-9.conf" <<'EOF'
board.9.repo=Acme/ninth
board.9.backend=issues
EOF
cat > "$WORK/machine-9-silent.conf" <<'EOF'
# a machine-level conf that exists, but says nothing about board 9's backend
# (e.g. it only configures unrelated boards)
board.42.repo=Acme/unrelated
EOF
export BOARDS_CONF_MACHINE="$WORK/machine-9-silent.conf"
export BOARDS_CONF_REPO_LOCAL="$WORK/repo-local-9.conf"

[ "$(board_backend 9)" = "issues" ] \
  || fail "board_backend 9 should fall through the silent machine-level conf to the repo-local backend=issues entry, got: $(board_backend 9)"

# ...but an EXPLICIT machine-level backend= line still wins outright over the
# repo-local one (discovery order preserved; only the absent-key case falls
# through).
cat > "$WORK/machine-9-explicit.conf" <<'EOF'
board.9.backend=projects
EOF
export BOARDS_CONF_MACHINE="$WORK/machine-9-explicit.conf"
# BOARDS_CONF_REPO_LOCAL still points at repo-local-9.conf (backend=issues)

# ...and an EXPLICIT machine-level `backend=projects` line is still found FIRST
# (discovery order preserved) — but since ADR 0004 removed the Projects-v2 arm,
# being found first now means it HARD-FAILS rather than selecting an arm.
#
# This is the strongest form of the temperloop#908 property: the machine-level
# stale line must NOT be quietly rescued by the repo-local `backend=issues`
# entry sitting underneath it. If discovery order were broken, or if the stale
# line resolved silently, this board would come back "issues" with rc 0 and the
# operator would never learn their conf is dead.
if out="$(board_backend 9 2>"$WORK/be9-stderr.txt")"; then
  fail "board_backend 9 (explicit machine-level backend=projects) must FAIL, got: '$out'"
fi
grep -q 'ADR 0004' "$WORK/be9-stderr.txt" \
  || fail "the backend=projects refusal should cite ADR 0004, got: $(cat "$WORK/be9-stderr.txt")"
grep -q 'board 9' "$WORK/be9-stderr.txt" \
  || fail "the backend=projects refusal should name the board, got: $(cat "$WORK/be9-stderr.txt")"
grep -qi 'migrat' "$WORK/be9-stderr.txt" \
  || fail "the backend=projects refusal should point at the migration path, got: $(cat "$WORK/be9-stderr.txt")"

# A board mentioned in NEITHER file for the backend key resolves "issues" — the
# only backend there is (ADR 0004); formerly this defaulted to "projects".
[ "$(board_backend 4)" = "issues" ] \
  || fail "board_backend 4 (backend key absent from both conf files) should resolve 'issues'"

echo "PASS: the backend axis falls through a silent machine-level conf to repo-local; an explicit machine-level backend=projects is found first and HARD-FAILS citing ADR 0004 (temperloop#908)"

# --- 11: board_owner FAILS LEGIBLY for a boards.conf board that declares
# repo= but no resolvable owner= (temperloop#798). Before this item,
# an adopter's own board id (not one of this repo's own 3-6) silently
# borrowed $BOARD_OWNER ("Towheads", THIS kernel checkout's own org) whenever
# they forgot an owner= line — a CROSS-TENANT MISDIRECTION: `gh project …
# --owner Towheads` would resolve to a foreign org's project instead of
# erroring. board_owner() now refuses instead of guessing.
cat > "$WORK/board11-no-owner.conf" <<'EOF'
board.11.repo=Acme/eleventh
board.11.project=11
EOF
export BOARDS_CONF_REPO_LOCAL="$WORK/board11-no-owner.conf"
export BOARDS_CONF_MACHINE="$WORK/no-such-machine-conf-11"

if owner_out="$(board_owner 11 2>"$WORK/board11-stderr.txt")"; then
  fail "board_owner 11 (repo=/project= set, no owner=) should FAIL, got: $owner_out"
fi
grep -q "board 11" "$WORK/board11-stderr.txt" \
  || fail "board_owner 11 failure message should name the board, got: $(cat "$WORK/board11-stderr.txt")"
grep -q "owner=" "$WORK/board11-stderr.txt" \
  || fail "board_owner 11 failure message should point at the missing owner= line, got: $(cat "$WORK/board11-stderr.txt")"

# The gate keys on the `repo=` line (the retired `project=` axis beside it is
# no longer read at all) — board_repo 11 still resolves fine, proving the
# owner= gate is independent and does not disturb the other live axes.
[ "$(board_repo 11)" = "Acme/eleventh" ] \
  || fail "board_repo 11 should still resolve from conf despite board_owner's gate"

echo "PASS: board_owner fails legibly for a boards.conf board that sets repo= but no owner= (temperloop#798)"

# --- 11b: the gate only fires when repo= IS declared without a matching
# owner= — a board with NO boards.conf entry at all (repo AND owner both
# absent) is unaffected and still falls back to $BOARD_OWNER.
export BOARDS_CONF_REPO_LOCAL="$WORK/no-such-repo-local-conf-11b"
export BOARDS_CONF_MACHINE="$WORK/no-such-machine-conf-11b"
[ "$(board_owner 12)" = "Towheads" ] \
  || fail "board_owner 12 (no boards.conf entry at all) should still fall back to \$BOARD_OWNER, got: $(board_owner 12)"

# ...and board 7 (the temperloop tracker, F#808) specifically still resolves
# unaffected: it has no boards.conf entry in this scenario, so the new gate
# never fires for it (see board_owner's own comment on why board 7 never
# actually reaches this lookup in practice — issues-only backend).
[ "$(board_owner 7)" = "Towheads" ] \
  || fail "board_owner 7 (kernel tracker, no boards.conf entry) should still resolve \$BOARD_OWNER unchanged, got: $(board_owner 7)"

echo "PASS: the owner= gate only fires for a boards.conf board that declares repo=; an unconfigured board (incl. board 7) is unaffected"

echo "ALL PASS: test_boards_conf.sh"
