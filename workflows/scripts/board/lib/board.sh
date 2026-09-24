#!/usr/bin/env bash
#
# Board adapter — the ONE sourced library that owns every tracker interaction
# for the dev-process scripts (claim.sh / capture.sh / worklist.sh, and /build
# board-mirroring).
#
# SINGLE BACKEND (ADR 0004, epic temperloop#524). This adapter speaks exactly
# one tracking backend: ISSUES-ONLY — plain GitHub Issues, `fnd:`-namespaced
# labels for state, native milestones, sub-issues, and issue dependencies, over
# REST alone. The former Projects-v2/GraphQL arm — its `gh project` argv, the
# 5,000-pt/hr GraphQL budget guard, and the structure/state cross-process cache
# split — was deprecated in v0.15.0 and REMOVED here. The tracking flow now
# issues no GraphQL call and depends on no paid or org-level GitHub feature: a
# free account and a repo are sufficient. See ADR 0004 for the decision and
# ISSUES-ONLY-BACKEND.md for the label/status contract this file implements.
#
# Why this exists: four call sites used to re-implement the same item
# resolution dance, copy-pasting the field-name strings ("Status",
# "Host/Session"), the option names ("In Progress", "Backlog"), and the owner.
# A board rename broke all four, some silently. This library makes those a
# single edit point and — crucially — adds a test seam (`_board_gh`) so the
# claim/capture logic can finally be covered by fixture-replay tests.
#
# Two design rules carried over from lib/claim_marker.sh:
#   - resolve-by-NAME (robust to a board field being deleted + re-created with a
#     new id), never hard-code field/option ids;
#   - a SINGLE indirection seam (`_board_gh`) every board call routes through,
#     so tests override it to replay canned fixtures with zero network.
#
# Sourced, not executed:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/lib/board.sh"

# --- identity + name constants (ONE place) --------------------------------
# A board rename is a one-line edit here; nothing downstream hard-codes these.
# These constants are a PUBLIC surface consumed by the sourcing scripts
# (claim.sh / capture.sh / worklist.sh) and future /build mirroring; some
# are read only across the `source` boundary, which shellcheck cannot see when
# linting this file in isolation. Hence the file-scoped SC2034 suppression.
# shellcheck disable=SC2034
BOARD_OWNER="Towheads"   # org owner; the board_owner() `*)` fallback for an unknown board (#330)  # denylist:allow — this repo's own real value, see board_repo() comment above
# Every governed board keys its worklist single-select on GitHub's built-in
# Status field (options: Backlog / Ready / In Progress / Done), so the
# built-in close->Done / reopen->In Progress automations — which can only target
# Status — drive the board. stageFind (3) consolidated onto Status in GH #340;
# foundation (4) was migrated to match in epic #24 (2026-06-02), at which point
# the former per-board board_status_field() shim collapsed to this one constant.
# ALL callers (claim.sh / worklist.sh / reconcile.sh / capture.sh) use it.
BOARD_FIELD_STATUS="Status"
BOARD_FIELD_HOSTSESSION="Host/Session"
BOARD_OPT_INPROGRESS="In Progress"
BOARD_OPT_BACKLOG="Backlog"
BOARD_OPT_READY="Ready"
BOARD_OPT_DONE="Done"
# Subsystem axis (foundation #97). A board-native single-select, orthogonal to the
# release-phase axis (which rides GitHub's built-in, read-only Milestone field —
# see board_item_milestone). stageFind seeded it from the milestones it had been
# mis-using as components (Datastore / Ingest / Extractor / …). Not every board
# defines it; board_set_component fails loudly (non-zero, no edit) where absent.
BOARD_FIELD_COMPONENT="Component"

# --- boards.conf registry seam (foundation #770) --------------------------
# The two registries below (board_repo/board_owner) are deliberately SEPARATE
# axes (repo-owner vs board-owner — #330 paid for this distinction; never
# collapse them back to one). The third, board_project_number, was retired with
# the Projects-v2 arm (ADR 0004) — a project number has no meaning on the
# issues-only backend. Each resolves its value through an optional external
# `boards.conf` FIRST, falling
# back to the built-in case map below when no conf entry exists. Discovery
# order (first hit wins):
#   1. machine-level: $XDG_CONFIG_HOME/temperloop/boards.conf
#      (default ~/.config/temperloop/boards.conf) — override BOARDS_CONF_MACHINE.
#      The subdir renamed foundation/ -> temperloop/ in v0.15.0
#      (temperloop#165). The legacy ~/.config/foundation/boards.conf
#      fallback was removed in v0.19.0 and is NO LONGER READ — an existing
#      legacy file is named once on stderr instead of being used silently
#      (see _board_machine_conf_default). Move it (mkdir -p
#      ~/.config/temperloop && mv ~/.config/foundation/boards.conf
#      ~/.config/temperloop/) or set BOARDS_CONF_MACHINE.
#   1b. composed-tree consumer-root conf (temperloop#494): in a self-hosting
#      checkout that vendors this kernel as a `kernel/` subtree and symlinks
#      workflows/scripts/board into it (foundation), the layer-2 repo-local path
#      below physically lands inside kernel/. This layer — between machine-level
#      and repo-local — probes the CONSUMER ROOT (the directory containing
#      kernel/, located from board.sh's own physical path) for a real
#      workflows/scripts/board/boards.conf OUTSIDE kernel/, giving that tree a
#      committable driver-side seam. Inert for synced-directory consumers and
#      the kernel repo itself (not inside a kernel/ subtree). See
#      _board_consumer_root_conf below.
#   2. repo-local override: workflows/scripts/board/boards.conf, next to this
#      lib — override BOARDS_CONF_REPO_LOCAL
#   3. the built-in case map (below) — the fallback every caller sees when
#      NEITHER conf file exists, byte-for-byte the same values as before this
#      seam existed. This matters because board.sh is synced (banner-stamped,
#      real-file copies — see `make sync-stagefind-board`) into stageFind and
#      the sync never carries a conf file: a consuming repo with no conf must
#      behave EXACTLY as it did pre-#770.
#
# The repo/owner axes above resolve "whole-file first-hit-wins": once
# a conf file exists at a higher-precedence location, THAT file alone is
# consulted for the axis (a miss there falls straight to the built-in map,
# never checking a lower-precedence file — see _board_conf_get's comment and
# test_boards_conf.sh section 3, which pins this). The `backend` axis
# (board_backend below) is the one exception: it resolves per-key across
# BOTH files via _board_conf_get_layered, so a machine-level conf that is
# merely silent on a board's backend key falls through to a repo-local entry
# instead of shadowing it outright — see board_backend's own comment for why.
#
# Conf format: `board.<N>.<axis>=<value>` lines, axis in {repo,owner,backend,
# name,cache}.
# Blank lines and `#`-prefixed lines are ignored. Parsed with grep/cut only —
# NEVER sourced or eval'd, so a conf file cannot execute code. See
# workflows/scripts/board/boards.conf.example for the documented format.
_BOARD_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default machine-level conf path (layer 3): $XDG_CONFIG_HOME/temperloop/
# boards.conf. The temperloop#165 read-old fallback to a legacy
# $XDG_CONFIG_HOME/foundation/boards.conf was removed in v0.19.0 — the
# legacy file is no longer used, but its mere PRESENCE is still reported
# once on stderr rather than ignored silently: a stranger whose only conf
# sits at the legacy path would otherwise see every board op fall through to
# the built-in maps with no explanation at all. This NOTE is the whole
# diagnostic (docs/config-precedence.md and the CHANGELOG carry the
# migration instruction).
_board_machine_conf_default() {
  local new_f old_f
  new_f="${XDG_CONFIG_HOME:-$HOME/.config}/temperloop/boards.conf"
  old_f="${XDG_CONFIG_HOME:-$HOME/.config}/foundation/boards.conf"
  if [ ! -f "$new_f" ] && [ -f "$old_f" ]; then
    echo "board.sh: NOTE — legacy machine conf $old_f is no longer read (legacy fallback removed in v0.19.0); move it to $new_f or set BOARDS_CONF_MACHINE." >&2
  fi
  printf '%s' "$new_f"
}

# Composed-tree consumer-root conf (temperloop#494). A self-hosting composed
# checkout (foundation, the pipeline driver) vendors this kernel as a `kernel/`
# subtree and exposes `workflows/scripts/board` as a DIRECTORY SYMLINK into it —
# so the symlink-resolved repo-local location ($_BOARD_LIB_DIR/../boards.conf,
# the layer-2 path in _board_conf_file/_board_conf_files below) physically lands
# INSIDE kernel/, where a committed consumer-owned conf trips kernel-drift-check
# and conflicts with every subtree pull. That is exactly why foundation — alone
# among the consumers — could not commit its driver-side backend-flip entries
# (temperloop#460 L3 canary, temperloop#470) and fell back to a machine-level
# ~/.config conf.
#
# This probe gives such a tree a committable, reviewable seam OUTSIDE kernel/:
# board.sh's OWN physical path (symlinks resolved, `pwd -P`) is inspected for a
# `/kernel/` component; if present, the consumer root is the directory that
# CONTAINS kernel/, and its `workflows/scripts/board/boards.conf` is used —
# but ONLY when it is a real file whose directory does NOT itself resolve back
# inside kernel/ (i.e. the consumer really does own a physical board dir there,
# not merely a whole-directory symlink into the subtree). That guard is what
# keeps the current whole-`board`-symlink layout falling straight through to
# layer 2 unchanged, and lights up only once the consumer materialises a real
# consumer-owned boards.conf at that path.
#
# ADR 0005's "boards.conf is never vendored" rule is preserved: this file lives
# at the CONSUMER root, above kernel/ — it is consumer-owned, never carried into
# the vendored subtree. A synced-directory consumer (stageFind/ssmobile/
# subsetwiki, whose `workflows/scripts/board` is a real banner-stamped copy, not
# a subtree symlink) and the kernel repo itself are NOT inside a `/kernel/`
# subtree, so this returns rc 1 and their existing layer-2 path is used verbatim.
# rc 0 + the path on a hit; rc 1 on any miss (not a composed tree, no file, or
# a file that resolves back inside kernel/).
_board_consumer_root_conf() {
  local phys root cand cand_dir
  # board.sh's own PHYSICAL directory (pwd -P resolves the board symlink into
  # kernel/ for a composed tree; leaves a real synced/kernel checkout as-is).
  phys="$(cd "$_BOARD_LIB_DIR" 2>/dev/null && pwd -P)" || return 1
  case "$phys" in
    */kernel/*) root="${phys%%/kernel/*}" ;;   # dir that contains kernel/
    *) return 1 ;;                              # not a vendored composed tree
  esac
  cand="$root/workflows/scripts/board/boards.conf"
  [ -f "$cand" ] || return 1
  # Reject a candidate whose directory resolves back INSIDE kernel/ — that is
  # the whole-`board`-symlink case, which is NOT a committable seam. Only a real
  # consumer-owned board dir at the root passes.
  cand_dir="$(cd "$(dirname "$cand")" 2>/dev/null && pwd -P)" || return 1
  case "$cand_dir/" in
    "$root/kernel/"*) return 1 ;;
  esac
  printf '%s' "$cand"
  return 0
}

# Echo the first EXISTING conf file in discovery order; rc 1 if none exists
# (callers then fall through to their built-in case map).
_board_conf_file() {
  local f
  f="${BOARDS_CONF_MACHINE:-$(_board_machine_conf_default)}"
  [ -f "$f" ] && { printf '%s' "$f"; return 0; }
  # composed-tree consumer-root conf — BEFORE the symlink-resolved repo-local
  # one, so a self-hosting tree's committed driver-side conf wins over the
  # kernel-internal path its board symlink would otherwise resolve to (#494).
  f="$(_board_consumer_root_conf)" && { printf '%s' "$f"; return 0; }
  f="${BOARDS_CONF_REPO_LOCAL:-$_BOARD_LIB_DIR/../boards.conf}"
  [ -f "$f" ] && { printf '%s' "$f"; return 0; }
  return 1
}

# Echo EVERY existing conf file, one per line, in discovery order (machine
# then repo-local). Unlike _board_conf_file() (which stops at the first
# existing file, for the "one file wins" axes), this is the enumeration seam
# _board_conf_get_layered() below walks for a per-key fallthrough. Emits
# nothing (rc 0, empty output) when neither file exists.
_board_conf_files() {
  local f
  f="${BOARDS_CONF_MACHINE:-$(_board_machine_conf_default)}"
  [ -f "$f" ] && printf '%s\n' "$f"
  # composed-tree consumer-root conf, same layer/precedence as in
  # _board_conf_file (between machine-level and symlink-resolved repo-local) so
  # the per-key backend fallthrough walked by _board_conf_get_layered() sees it
  # too (#494).
  f="$(_board_consumer_root_conf)" && printf '%s\n' "$f"
  f="${BOARDS_CONF_REPO_LOCAL:-$_BOARD_LIB_DIR/../boards.conf}"
  [ -f "$f" ] && printf '%s\n' "$f"
  return 0
}

# _board_conf_get <board> <axis> — echo the conf value + rc 0 on a hit; rc 1 on
# any miss (no conf file, or no matching key) so the caller falls back cleanly.
# Whole-file "one file wins" discovery: only the FIRST existing conf file is
# ever consulted for this axis, even if a lower-precedence file would have
# matched — see test_boards_conf.sh section 3, which pins this contract
# deliberately (no cross-file per-key merge) for the repo/owner axes.
_board_conf_get() {
  local board="$1" axis="$2" file val
  file="$(_board_conf_file)" || return 1
  val="$(grep -m1 "^board\.${board}\.${axis}=" "$file" 2>/dev/null | cut -d= -f2-)"
  [ -n "$val" ] || return 1
  printf '%s' "$val"
}

# _board_conf_get_layered <board> <axis> — like _board_conf_get, but walks
# EVERY existing conf file in discovery order (machine, then repo-local) and
# returns the first line match ACROSS files, instead of stopping at the first
# existing file. This is per-key fallthrough: a machine-level conf that omits
# this axis for this board no longer shadows a repo-local entry that sets it —
# an explicit machine-level value for the axis still wins outright, since it's
# found first. Used ONLY by board_backend() below (which since ADR 0004 reads
# the axis solely to REJECT a stale `backend=projects` line, not to select an
# arm); every other axis keeps _board_conf_get's whole-file "one file wins"
# contract (see its comment).
# rc 1 if no existing conf file carries the key.
_board_conf_get_layered() {
  local board="$1" axis="$2" file val
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    val="$(grep -m1 "^board\.${board}\.${axis}=" "$file" 2>/dev/null | cut -d= -f2-)"
    if [ -n "$val" ]; then
      printf '%s' "$val"
      return 0
    fi
  done < <(_board_conf_files)
  return 1
}

# board number -> "owner/repo" for `gh issue create -R`. This is the ONE
# per-board "what" registry: onboarding a new board is a single line here (or
# in boards.conf), and every caller's --board switch resolves through it.
# Keeping the mapping here means capture.sh's --board switch and any future
# caller agree on it.
# denylist:allow — this built-in map is this repo's OWN real values, kept
# byte-identical for the boards.conf-less-consumer backward-compat guarantee
# documented above (#770); NOT an oversight. A stranger's fork replaces this
# whole case map (or ships a boards.conf) with their own org/repo values.
board_repo() {
  local v
  v="$(_board_conf_get "$1" repo)" && { printf '%s\n' "$v"; return 0; }
  case "$1" in
    3) echo "Towheads/stageFind" ;;   # migrated into the org (#330)  # denylist:allow — see comment above board_repo()
    4) echo "Towheads/foundation" ;;  # migrated into the org (#330)  # denylist:allow — see comment above board_repo()
    5) echo "Towheads/ssmobile" ;;    # migrated into the org (#330)  # denylist:allow — see comment above board_repo()
    6) echo "Towheads/subsetwiki" ;;  # onboarded in the org  # denylist:allow — see comment above board_repo()
    7) echo "Towheads/temperloop" ;;  # the kernel tracker itself (F#808, issues-only — see board_backend below); formerly Towheads/foundation-kernel  # denylist:allow — see comment above board_repo()
    *) return 1 ;;
  esac
}

# The registered board ids — the SINGLE SOURCE OF TRUTH every
# caller's repo->board reverse-lookup probe iterates, instead of a hardcoded
# `3 4 5 6` literal duplicated across command specs that silently drifts each
# time a board is onboarded. That drift was temperloop#352: board 7 was added to
# board_repo()'s case map above but /build, /assess, /sweep still looped
# `3 4 5 6`, so the probe never matched the temperloop repo and board integration
# resolved OFF on the kernel's own tracker. Emits the built-in set (the twin of
# board_repo()'s case map — onboarding a board is one line there plus one number
# here) UNION any board numbers a discovered boards.conf defines, one per line,
# ascending. Iterate it as `for b in $(board_registered_boards)`.
board_registered_boards() {
  local file
  {
    printf '%s\n' 3 4 5 6 7
    if file="$(_board_conf_file)"; then
      grep -oE '^board\.[0-9]+\.' "$file" 2>/dev/null | grep -oE '[0-9]+' || true
    fi
  } | sort -nu
}

# board number -> the GitHub login that owns the board. This is the seam where a
# board migrated to a different owner expresses it: boards 3/4/5 were all
# migrated into this repo's own org (#330) and carry it here. $BOARD_OWNER
# remains only the `*)` fallback for an unknown board. Kept SEPARATE from
# board_repo()'s repo-owner: for a co-located board they're equal (all are now),
# but the two are distinct axes and #330 paid for the distinction.
board_owner() {
  local v
  v="$(_board_conf_get "$1" owner)" && { printf '%s\n' "$v"; return 0; }
  case "$1" in
    3 | 4 | 5 | 6) echo "Towheads" ;; # all boards live in the org (#330; 6 onboarded)  # denylist:allow — this repo's own real value, see board_repo() comment above
    *)
      # No owner= for this board, and it isn't one of the built-in boards
      # above. If boards.conf declares repo= for this board (an ADOPTER's own
      # custom board id, not one of this repo's own 3-6), silently returning
      # $BOARD_OWNER here would be a CROSS-TENANT MISDIRECTION
      # (temperloop#798): $BOARD_OWNER is THIS kernel checkout's own org
      # ("Towheads"), so a read against an adopter's board would silently
      # resolve to a FOREIGN org instead of erroring. Fail loudly instead — the
      # adopter is missing a `board.<N>.owner=` line and needs to add one, not
      # have the request silently misrouted to this repo's own org.
      if _board_conf_get "$1" repo >/dev/null 2>&1; then
        echo "board.sh: board $1 sets repo= in boards.conf but no resolvable owner= — add 'board.$1.owner=<login-or-org>' to boards.conf (refusing to silently fall back to this kernel checkout's own org)" >&2
        return 1
      fi
      # No boards.conf entry AT ALL for this board (repo AND owner both
      # absent) — e.g. board 7, the temperloop tracker itself, whose repo
      # resolves from board_repo()'s own built-in map rather than boards.conf
      # (#808). The pre-#798 fallback stays unchanged for this
      # genuinely-unconfigured case.
      echo "$BOARD_OWNER" ;;
  esac
}

# --- tracker backend selector (ADR 0004) ----------------------------------
# There is exactly ONE tracking backend: ISSUES-ONLY. No Projects board is ever
# provisioned or queried; item CRUD + Status ride plain `fnd:`-namespaced
# GitHub labels on the repo's Issues. This function is retained (rather than
# deleted outright) for two reasons: callers and the boards.conf `backend` axis
# both predate the removal, and — the load-bearing one — a stale
# `board.<N>.backend=projects` line left in an operator's conf MUST NOT be
# silently ignored.
#
# WHY THE HARD FAIL. temperloop#908 recorded the failure this guards: a backend
# that changes under you with nothing telling you. A conf line reading
# `backend=projects` expresses a real operator intent that this build can no
# longer honour; quietly resolving it to "issues" would move that board's state
# onto a different substrate with no signal at all — exactly the silently
# reverted cutover that put four boards on the wrong path and was found by
# hand. So an explicit `backend=projects` is a LOUD, non-zero refusal naming
# ADR 0004 and the migration path, and every other input (absent axis,
# `backend=issues`, or any conf file at all) resolves "issues".
#
# The axis still resolves through _board_conf_get_layered (per-key fallthrough
# across BOTH conf files) so a stale line is caught wherever it sits — a
# machine-level conf and a committed repo-local one are equally able to strand
# an operator on a dead arm.
#   board_backend <board#>  ->  "issues"  (rc 0)
#                            ->  rc 1 + stderr on an explicit backend=projects
board_backend() {
  local v
  if v="$(_board_conf_get_layered "$1" backend)" && [ "$v" = "projects" ]; then
    echo "board.sh: board $1 sets backend=projects in boards.conf, but the Projects-v2 arm was REMOVED (ADR 0004; deprecated v0.15.0). Migration path: check out v0.25.0 — the last release carrying workflows/scripts/board/migrate-board-to-issues.sh, which was deleted in v0.26.0 per ADR 0004's ordering pin — run that script against this board, then delete the board.$1.backend=projects line and pull again. There is NO configuration path back to Projects-v2 — an adopter who wants it forks board.sh." >&2
    return 1
  fi
  printf '%s\n' "issues"
}

# True iff <board#> is configured for the issues-only backend — which, since
# ADR 0004, is every board. Retained as the single predicate the public
# functions read so a stale `backend=projects` conf line propagates its
# non-zero refusal (see board_backend above) instead of being ignored.
_board_is_issues_only() {
  [ "$(board_backend "$1")" = "issues" ]
}

# --- board NAME aliases for --board (temperloop #95) ----------------------
# Every --board switch accepts a board NAME as well as its board id, so a
# human never has to touch the private number space (the number stays the SOLE
# internal key; names resolve to a number at the CLI/entrypoint boundary and
# nothing downstream is name-aware). Two name sources, checked in this order —
# same first-hit-wins discovery as every other axis:
#   1. a `board.<N>.name=<slug>` line in boards.conf (an axis peer to
#      repo/owner/backend/cache — same grep-only, never-sourced parsing;
#      see boards.conf.example). This is how a stranger's fork names its own
#      boards without editing this lib.
#   2. the built-in name map below — this repo's OWN board names, kept here for
#      the boards.conf-less consumer (a synced board.sh with no conf must accept
#      `--board foundation` exactly as it accepts `--board 4`). These are app
#      names, NOT identity/credential tokens, so they are deliberately NOT on
#      the personal-token denylist (see personal-token-denylist.tsv's header).
# Matching is case-insensitive on the name; a bare integer is a NUMBER and
# passes straight through untouched (the cheap, dominant internal path — no conf
# read). An unknown name errors to stderr WITH the known-names list, rc 2.

# Built-in name -> board id. Lowercased input; rc 1 on miss.
# A stranger's fork edits this map (or ships boards.conf board.<N>.name= lines).
_board_builtin_name_to_number() {
  case "$1" in
    stagefind)         echo 3 ;;
    foundation)        echo 4 ;;
    ssmobile)          echo 5 ;;
    subsetwiki)        echo 6 ;;
    kernel|temperloop) echo 7 ;;
    *) return 1 ;;
  esac
}

# The names the built-in map answers to (for the unknown-name error list).
_BOARD_BUILTIN_NAMES="stagefind foundation ssmobile subsetwiki kernel temperloop"

# boards.conf name -> number lookup (case-insensitive on the value). Parsed with
# a pure shell split, never eval/grep-with-user-regex, so a name with regex
# metacharacters can't misfire. rc 1 on no-conf / no-match.
_board_conf_name_to_number() {
  local want line n nm file
  want="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  file="$(_board_conf_file)" || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      board.*.name=*)
        n="${line#board.}"; n="${n%%.name=*}"
        nm="${line#*.name=}"
        nm="$(printf '%s' "$nm" | tr '[:upper:]' '[:lower:]')"
        [ "$nm" = "$want" ] && { printf '%s' "$n"; return 0; }
        ;;
    esac
  done < "$file"
  return 1
}

# The full known-names list (built-in + every boards.conf board.<N>.name=),
# space-separated, for the unknown-name error message.
_board_known_names() {
  local names="$_BOARD_BUILTIN_NAMES" file line
  if file="$(_board_conf_file)"; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        board.*.name=*) names="$names ${line#*.name=}" ;;
      esac
    done < "$file"
  fi
  printf '%s' "$names"
}

# board_resolve_name <name-or-number> -> canonical board id on stdout.
# The ONE shared resolver every --board switch and every lib entrypoint routes a
# board argument through. A bare integer passes through unchanged (backward
# compatible — the sole internal key is still the number). A name resolves via
# boards.conf then the built-in map. An unknown name prints an error + the known
# names to stderr and returns 2; an empty argument returns 2.
board_resolve_name() {
  local arg="$1" n
  case "$arg" in
    '')       printf 'board name or number required\n' >&2; return 2 ;;
    *[!0-9]*) : ;;                         # contains a non-digit -> treat as a name
    *)        printf '%s' "$arg"; return 0 ;;   # pure integer -> passthrough
  esac
  if n="$(_board_conf_name_to_number "$arg")"; then printf '%s' "$n"; return 0; fi
  if n="$(_board_builtin_name_to_number "$(printf '%s' "$arg" | tr '[:upper:]' '[:lower:]')")"; then
    printf '%s' "$n"; return 0
  fi
  printf 'unknown board name: %s\nknown board names: %s\n' "$arg" "$(_board_known_names)" >&2
  return 2
}

# --- issue-plane read-cache enable axis (F#988 Contract, cache-read-dispatch
# item) ----------------------------------------------------------------------
# A boards.conf axis, a peer to repo/owner/backend (milestone is
# read-side, not conf): `board.<N>.cache=on`. Default (omitted, or any value
# other than "on") is OFF — the whole-board issues-only read stays exactly the
# live `gh issue list` call it always was (see _board_issues_item_list below).
# This is deliberately an ENABLE/DISABLE switch only — every TUNING setting for
# the store itself (root dir, TTL) stays an env var on lib/cache.sh
# (CACHE_STORE_ROOT / CACHE_STORE_TTL), never a second boards.conf axis (see
# cache.sh's own "Tuning settings" comment). Turning this on has NO effect unless
# the caller has ALSO sourced lib/cache.sh in the same process — board.sh
# itself never sources cache.sh (kept a one-way, additive-only layering; see
# cache.sh's own header) — _board_issues_item_list checks `command -v
# cache_read` and falls back to the live read (with one stderr notice) when
# the axis is on but cache.sh isn't in scope. This is what keeps reconcile.sh
# (which never sources cache.sh) permanently on the live-read arm regardless
# of what a boards.conf sets this axis to — see test_reconcile.sh's Lens 3.
_board_cache_store_enabled() {
  [ "$(_board_conf_get "$1" cache 2>/dev/null)" = "on" ]
}

# --- the ONE test-injection seam ------------------------------------------
# Every board `gh` call goes through here. Production runs real gh; tests
# override this after sourcing (e.g. `_board_gh() { fake_gh "$@"; }`) to replay
# fixtures. Mirrors lib/claim_marker.sh's `_claim_marker_tmux`.
_board_gh() { GH_CALL_OP="${GH_CALL_OP:-board:${FUNCNAME[1]:-unknown}}" gh "$@"; }  # setting:exempt — call-attribution tag, computed per-call via FUNCNAME, not a static operator default

# In-memory resolve results, populated by board_resolve / board_resolve_item. Default
# them to empty AT LOAD so a read-position accessor (board_item_id,
# board_item_title, board_item_milestone, …) invoked BEFORE any resolve
# returns its documented empty-string "not on the board" result instead of aborting with
# an 'unbound variable' error under set -u — the capture.sh --repo kernel path runs set -u
# and was stranding freshly-captured issues off-board (temperloop#602). The `+x` guard
# assigns only when unset, so a resolve already run in this process is never clobbered by a
# defensive re-source; the plain-assignment form (not the ${VAR:-} setting idiom) keeps these
# internal cache globals out of the setting-registry ${VAR:-} seam sweep.
[ -n "${BOARD_ITEMS_JSON+x}" ]  || BOARD_ITEMS_JSON=""
[ -n "${BOARD_FIELDS_JSON+x}" ] || BOARD_FIELDS_JSON=""

# The board whose state the in-shell globals currently describe — set by
# board_resolve / board_resolve_item so the item-id-only mutators (board_set_*,
# board_stamp) know which board's on-disk cache to invalidate after a write.
BOARD_CURRENT=""

# Machine-readable un-landed-issue list, set by board_create_many /
# _board_issues_create_many / board_capture_item on every return: a
# space-separated list of the issue numbers that did NOT resolve/status in the
# call that just returned (empty string on a fully-successful call). A caller
# that wants the specifics — not just the pass/fail return code — reads this
# global immediately after the call. See board_create_many's own header
# comment for the full return-code contract (foundation #1226).
BOARD_UNLANDED_ISSUES=""

# Strip ASCII control characters 0x00–0x1f from a whole-board read's raw TEXT
# (foundation #224). A raw control char inside an item title/body is invalid in a
# JSON string value, so it breaks jq's parse with a hard error — and because the
# whole-board read is bulk, ONE poisoned item takes down the entire list. This has
# RECURRED because earlier fixes patched it per-call-site (ccbc6868 added an inline
# `tr -d '\000-\037'` at ONE site; 92feec12 hit it again). The durable fix mirrors
# the #223 fix: ONE shared pipe-stage helper applied at the raw whole-board exit
# (_board_issues_item_list) AND at every per-issue / per-milestone REST→jq seam
# that reads a user-controlled
# body/description: board_blocked_by_open, board_parent_issue, _board_issue_db_id,
# board_active_milestones,
# board_set_milestone_description, and milestone.sh's _milestone_description /
# milestone_list (#614). Those single-item REST reads were the uncovered class: a
# gh-leaked literal control byte made their `… 2>/dev/null | jq` fail, the 2>/dev/null
# swallowed the error, and the function returned a SILENT wrong-empty answer
# ("not blocked" / "no parent" / "no active milestones") — which halted /triage.
# Crucially the helper runs on the raw TEXT *before* any jq sees it (control chars
# break jq, so a jq-based sanitizer can't fix its own input). tr never fails on this
# class of input, so it adds no new error path. INVARIANT: any new `_board_gh api …
# | jq` that reads issue/milestone content must route through this stage first.
_board_sanitize_control_chars() {
  LC_ALL=C tr -d '\000-\037'
}

# --- issues-only backend: fnd: label vocabulary + item CRUD/status --------
# See ISSUES-ONLY-BACKEND.md (sibling file) for the full contract. Summary:
# item state rides `fnd:<field-slug>:<value-slug>` labels on the plain GitHub
# issue (`fnd:status:ready`, `fnd:status:in-progress`, `fnd:component:ingest`,
# …); "Done" is the ONE exception — it carries NO label, it is simply the
# issue being CLOSED (closing strips any residual fnd:status:* label; a
# read of a closed issue always reports status "Done" regardless of labels).
# No Projects-v2 call is ever made on this path — the arm that made them was
# removed (ADR 0004); this is the only path there is.

# "In Progress" -> "in-progress" (lowercase, spaces collapsed to hyphens).
_board_issues_slug() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -s ' ' '-'
}

# "fnd:status:" for field-name "Status", "fnd:component:" for "Component" —
# generic over ANY single-select-shaped field name via the same slugger, so a
# future field axis (beyond Status/Component) needs no new plumbing here.
_board_issues_label_prefix() {
  printf 'fnd:%s:' "$(_board_issues_slug "$1")"
}

# Shared jq `def`s for reshaping a raw `gh issue list`/`gh api issues/<n>`
# response into the SAME item shape board_resolve_item / board_item_list
# produce for the Projects-v2 path — {id, content:{number,title,type}, status,
# component, "host/Session"} — so every downstream accessor (board_item_id /
# board_item_title / a caller's own `.status`/`.component`/`.["host/Session"]`
# read — e.g. reconcile.sh's foreign-claim detector, worklist.sh's owner
# column) works UNCHANGED regardless of backend. `issue_item($n)` expects `.`
# to be the raw issue object (labels + state + title) and $n to be its issue
# number.
#   unslug: "in-progress" -> "In Progress" (inverse of _board_issues_slug,
#     good enough for the closed status vocabulary + any Component slug — see
#     ISSUES-ONLY-BACKEND.md's round-trip note). NOT applied to the
#     Host/Session claim stamp below — that is a free-text field (like its
#     Projects-v2 counterpart, a --text field rather than a single-select), so
#     unslugging (which lowercases) would corrupt a mixed-case hostname and
#     silently break the foreign-host comparison board_claim_contended /
#     reconcile.sh rely on. The stamp is stored and read back VERBATIM.
#   labels: the RAW label-name array (foundation #801, split 3/3 — the pipeline-
#     integration "D3 seam" fix). A caller like pipeline-tick.sh reads a Ready
#     item's ordinary GitHub labels directly (`spike`, `Foundational`,
#     `needs-clarification`, `funnel-escalated`, `funnel-merge-pending` — none
#     of them `fnd:`-namespaced) to classify/gate it; the Projects-v2 path
#     exposed this for free (its raw item-list JSON carried a top-level `labels`
#     array for Issue content, which board.sh reshaped none of).
#     Before this fix the issues-only reshape below extracted only the
#     `fnd:`-prefixed labels into status/component/host-session and DROPPED
#     every other label — so a live pipeline-tick against an issues-only board
#     could never see `spike`/`Foundational`/etc. and every Ready item
#     silently misclassified as a fresh Operational kind:code drive. Emitting
#     the full, unfiltered label-name list here (fnd: ones included — harmless,
#     since a `. == "spike"` equality check never matches `"fnd:status:ready"`)
#     makes the issues-only item shape a byte-for-byte structural match for the
#     Projects-v2 one on this key too. See ISSUES-ONLY-BACKEND.md § Pipeline
#     integration and tests/test_board_dual_adapter.sh (the parity proof).
#   milestone: the item's release-phase milestone as { title } (temperloop#154 —
#     the same class of dropped-field bug the #801 labels passthrough fixed).
#     board_item_milestone reads `.milestone.title`; the Projects-v2 path got it
#     for free, but the issues-only reshape used to drop it entirely, so
#     board_item_milestone always returned empty on this backend — which silently
#     defeated /triage's active-milestone intake filter (every item read as
#     unmilestoned, so a Backlog item on an INACTIVE milestone was wrongly intook
#     instead of deferred). Emitting `{ title }` here (omitted when the issue has
#     no milestone, matching the component/host optional-field style) makes
#     board_item_milestone work unchanged on both backends. The whole-board live
#     read (_board_issues_item_list) must request `milestone` in its `gh issue
#     list --json` field list for this to be populated; the single-issue read
#     (_board_issues_resolve_item via `gh api …/issues/<n>`) carries it already.
read -r -d '' _BOARD_ISSUES_JQ_DEFS <<'JQ_DEFS' || true
def unslug: split("-") | map((.[0:1] | ascii_upcase) + .[1:]) | join(" ");
def issue_item($n):
  (.labels // [] | map(.name)) as $labels
  | (.state // "open") as $state
  | ( ($labels | map(select(test("^fnd:status:")))) as $sl
      | if ($sl | length) > 0 then ($sl[0] | sub("^fnd:status:"; "")) else "" end ) as $status_slug
  | ( ($labels | map(select(test("^fnd:component:")))) as $cl
      | if ($cl | length) > 0 then ($cl[0] | sub("^fnd:component:"; "")) else "" end ) as $comp_slug
  | ( ($labels | map(select(test("^fnd:host/session:")))) as $hl
      | if ($hl | length) > 0 then ($hl[0] | sub("^fnd:host/session:"; "")) else "" end ) as $host_session
  | { id: ("ISSUE_" + ($n | tostring)),
      content: { number: $n, title: (.title // ""), type: "Issue" },
      labels: $labels }
    + ( if $state == "closed" then { status: "Done" }
        elif $status_slug != "" then { status: ($status_slug | unslug) }
        else {} end )
    + ( if $comp_slug != "" then { component: ($comp_slug | unslug) } else {} end )
    + ( if $host_session != "" then { "host/Session": $host_session } else {} end )
    + ( if (.milestone.title // "") != "" then { milestone: { title: .milestone.title } } else {} end );
JQ_DEFS

# Whole-board (active-set) read for an issues-only board: every OPEN issue,
# reshaped to the shared item form. Mirrors the Projects path's `-status:Done`
# active-set convention for free — `--state open` already excludes the Done
# (closed) tail, no separate filter needed.
#
# --- PLANE MAP (F#988 Contract, cache-read-dispatch item) -------------------
# This function serves the ISSUE PLANE: the whole corpus of a repo's GitHub
# Issues (title/labels/state — everything this backend's item IS, since an
# issues-only board has no item distinct from its issue). It is served either
# LIVE (a `gh issue list` REST call, always was) or, when `board.<N>.cache=on`
# AND lib/cache.sh has been sourced by the caller, from cache.sh's on-disk
# issue-cache STORE (see cache.sh's header + CACHE-STORE.md). Either way this
# draws on REST's own 5,000/hr bucket. Since ADR 0004 removed the Projects-v2
# arm, cache.sh's store is the ONLY cache in front of any board read —
# board.sh's former item-plane cache (`_board_cached_read` / BOARD_CACHE_TTL,
# GraphQL-budget relief for Projects-v2 board-item field values) went with the
# arm it existed to protect. See cache.sh's own header for the store-side half
# of this map.
#   _board_issues_item_list <board#>  ->  {"items":[...]} JSON on stdout
_board_issues_item_list() {
  local board="$1" repo lim raw

  repo="$(board_repo "$board")" || return 1
  lim="${BOARD_ITEM_LIMIT:-500}"

  if _board_cache_store_enabled "$board"; then
    # `command -v`, NOT `declare -F` (temperloop#1776): this lib is SOURCED into
    # the agent's shell by every command spec, and on macOS that shell is zsh,
    # where `declare` is `typeset` and `-F` means "float with N digits" — so
    # `declare -F cache_read` SUCCEEDS for an undefined name and the fallback
    # below is unreachable. `command -v` is POSIX and false-for-absent in both
    # shells. There is no `cache_read` binary, so the wider "function, builtin
    # or binary" sense of `command -v` cannot make this probe true by accident.
    if command -v cache_read >/dev/null 2>&1; then
      # cache_read serves warm-and-fresh with ZERO gh calls; on a miss/stale
      # store it pays exactly one live refresh itself (cache.sh's own
      # degradation contract — one stderr notice, never fabricated data) and
      # this function does not layer a second live fallback on top of that.
      # Snapshot rows are ALL states; filter to open here (mirrors the live
      # arm's `--state open`) — note BOARD_ITEM_LIMIT is a live-arm-only setting:
      # the store is not paginated/truncated (a later perf pass can add a cap
      # if an issues-only repo's corpus ever makes this the bottleneck).
      raw="$(cache_read "$repo")" || return 1
      printf '%s' "$raw" | _board_sanitize_control_chars | jq -s -c "
        $_BOARD_ISSUES_JQ_DEFS
        { items: [ .[] | select((.state // \"open\") == \"open\") | issue_item(.number) ] }
      "
      return $?
    fi
    echo "board: cache enabled for board $board (board.$board.cache=on) but lib/cache.sh is not sourced in this process — falling back to a live (uncached) read" >&2
  fi

  raw="$(_board_gh issue list -R "$repo" --state open --limit "$lim" \
        --json number,title,labels,milestone 2>/dev/null)" || {
    echo "board: live read failed (issues, board $board) — rate limit or auth?" >&2
    return 1
  }
  [ -n "$raw" ] || raw="[]"
  printf '%s' "$raw" | _board_sanitize_control_chars | jq -c "
    $_BOARD_ISSUES_JQ_DEFS
    { items: [ .[] | issue_item(.number) ] }
  "
}

# Single-issue, always-live read (the issues-only counterpart to
# board_resolve_item's targeted GraphQL query) — used by the mutating callers
# (claim/status-move) that must see fresh state. Unlike the whole-board read
# this DOES observe a just-closed issue (Done), since `gh api issues/<n>`
# doesn't filter by state.
#   _board_issues_resolve_item <board#> <issue#>  -> sets BOARD_ITEMS_JSON
_board_issues_resolve_item() {
  local board="$1" issue="$2" repo raw
  repo="$(board_repo "$board")" || return 1
  raw="$(_board_gh api "repos/$repo/issues/$issue" 2>/dev/null)" || return 1
  [ -n "$raw" ] || return 1
  BOARD_PROJECT_ID=""
  BOARD_FIELDS_JSON='{"fields":[]}'
  BOARD_ITEMS_JSON="$(
    printf '%s' "$raw" | _board_sanitize_control_chars | jq -c --argjson n "$issue" "
      $_BOARD_ISSUES_JQ_DEFS
      { items: [ issue_item(\$n) ] }
    "
  )"
  BOARD_CURRENT="$board"
}

# Memoize `fnd:` label creation within this process (repo|label key) so a
# burst of status writes against the same repo pays `gh label create` at most
# once per label, not once per call. Plain string, not an associative array —
# board.sh must stay portable to macOS's stock bash 3.2 (no assoc arrays).
#
# $3 (color) and $4 (description) are optional overrides for callers that
# aren't creating an `fnd:` tracker label (e.g. capture.sh's work-class
# labels, Operational/Foundational) — default to the original fnd: tracker
# color/description so every existing call site (which passes only repo+label)
# is unaffected.
_BOARD_ISSUES_LABELS_ENSURED=""
_board_issues_ensure_label() {
  local repo="$1" label="$2" color="${3:-fbca04}" desc="${4:-fnd: tracker label (issues-only backend)}" key
  key="$repo|$label"
  case " $_BOARD_ISSUES_LABELS_ENSURED " in
    *" $key "*) return 0 ;;
  esac
  _board_gh label create "$label" -R "$repo" --color "$color" \
    --description "$desc" >/dev/null 2>&1 || true
  _BOARD_ISSUES_LABELS_ENSURED="$_BOARD_ISSUES_LABELS_ENSURED $key"
  return 0
}

# The issues-only write path board_set_status (and, via it, board_set_component)
# delegate to for an ISSUE_* item id. Emulates a single-select: at most one
# `fnd:<field>:*` label at a time. Status additionally drives open/closed:
# target "Done" -> strip any fnd:status:* label + CLOSE; any other target ->
# ensure the label + REOPEN if the issue was closed. Both the close/reopen and
# the label add/remove are read-before-write (one `gh api issues/<n>` fetch)
# so an already-correct state is a no-op, not a redundant/erroring gh call.
#
# Done ALSO clears the claim stamp (temperloop#744). The `fnd:host/session:*`
# label is the cross-session claim LOCK (see _board_issues_stamp_field below and
# ISSUES-ONLY-BACKEND.md § Claim lock) — reaching Done is the end of the claim
# by construction, so leaving the stamp on a closed issue publishes a lock that
# can never be released, and a reader (issue-state.sh's `claimed-elsewhere`
# derivation, reconcile.sh's foreign-claim bucket, board_claim_contended) cannot
# tell it apart from a live claim. So the Done arm strips every
# `fnd:host/session:*` label alongside the status label, under the same
# retry-once/never-swallow contract as the status strip. Non-Done targets do NOT
# touch the stamp — a Ready/Backlog park is exactly the case where the claim may
# legitimately still be held (kernel doc § Claim held until Done), and claim.sh
# re-stamps on its own. This closes only the ADAPTER-driven close path; a close
# that bypasses the adapter entirely (a merged PR's native `Closes #N`, a hand
# `gh issue close`, the web UI) never runs this code and is swept by
# reconcile.sh's Lens 3 --labels backstop instead — see that file's class (j).
# Best-effort write-through invalidation (F#988 Contract, cache-read-dispatch
# item): dirty the canonical issue-cache store's entry for <repo> after a
# SUCCESSFUL issues-only mutation, so a following whole-board read (when
# board.<N>.cache=on) doesn't keep serving a pre-write snapshot for the rest
# of the store's TTL window. A pure no-op — never fails the caller — when
# lib/cache.sh has not been sourced in this process (board.sh has no hard
# dependency on it, see cache.sh's own header) or when no store yet exists
# for this repo (cache_dirty itself no-ops then; see cache.sh's cache_dirty).
#   _board_cache_dirty_after_write <owner/repo>
_board_cache_dirty_after_write() {
  command -v cache_dirty >/dev/null 2>&1 && cache_dirty "$1" >/dev/null 2>&1
  return 0
}

#   _board_issues_set_field <ISSUE_n> <field-name> <option-name>
_board_issues_set_field() {
  local item_id="$1" field_name="$2" opt_name="$3"
  local issue repo prefix target_label issue_json state cur l is_done=0 already_present=0 removal_failed=0
  local hs_prefix hs_cur

  issue="${item_id#ISSUE_}"
  repo="$(board_repo "${BOARD_CURRENT:-}")" || {  # setting:exempt — internal already-resolved board state, not an operator default
    echo "board: _board_issues_set_field — no current board (call board_resolve_item first)" >&2
    return 1
  }
  prefix="$(_board_issues_label_prefix "$field_name")"

  if [ "$field_name" = "$BOARD_FIELD_STATUS" ] && [ "$opt_name" = "$BOARD_OPT_DONE" ]; then
    is_done=1
  else
    target_label="${prefix}$(_board_issues_slug "$opt_name")"
    _board_issues_ensure_label "$repo" "$target_label" || return 1
  fi

  issue_json="$(_board_gh api "repos/$repo/issues/$issue" 2>/dev/null | _board_sanitize_control_chars)" || return 1
  [ -n "$issue_json" ] || return 1
  state="$(printf '%s' "$issue_json" | jq -r '.state // "open"')"
  cur="$(printf '%s' "$issue_json" | jq -r --arg p "$prefix" '.labels[]?.name | select(startswith($p))')"

  while IFS= read -r l; do
    [ -n "$l" ] || continue
    if [ "$is_done" -eq 0 ] && [ "$l" = "$target_label" ]; then
      already_present=1
      continue
    fi
    # Retry once, then surface the failure — do NOT swallow it. A silently
    # dropped removal leaves DUAL fnd:<field>:* labels (e.g. status:backlog +
    # status:ready) on the issue while the write still reports success, so the
    # caller cannot tell the flip half-failed (temperloop#601). The removal is
    # not inherently broken (running it by hand succeeds); the hazard is a
    # transient/throttled failure being hidden, so a single retry absorbs the
    # transient case and a persistent failure is reported via a non-zero return.
    if ! _board_gh issue edit "$issue" -R "$repo" --remove-label "$l" >/dev/null 2>&1 \
       && ! _board_gh issue edit "$issue" -R "$repo" --remove-label "$l" >/dev/null 2>&1; then
      echo "board: _board_issues_set_field — failed to remove stale '$prefix' label '$l' on $repo#$issue" >&2
      removal_failed=1
    fi
  done <<<"$cur"

  # Skip a redundant add when the target label is already the issue's only
  # fnd:<field>:* label (re-setting the same status/component is then a pure
  # no-op at the gh-call level, not just idempotent at the label-set level).
  if [ "$is_done" -eq 0 ] && [ "$already_present" -eq 0 ]; then
    _board_gh issue edit "$issue" -R "$repo" --add-label "$target_label" >/dev/null || return 1
  fi

  # Done clears the claim stamp too (temperloop#744) — see this function's
  # header. Reads the ALREADY-FETCHED issue_json (no extra gh call) and reuses
  # the same retry-once/never-swallow removal contract as the status strip.
  if [ "$is_done" -eq 1 ]; then
    hs_prefix="$(_board_issues_label_prefix "$BOARD_FIELD_HOSTSESSION")"
    hs_cur="$(printf '%s' "$issue_json" | jq -r --arg p "$hs_prefix" '.labels[]?.name | select(startswith($p))')"
    while IFS= read -r l; do
      [ -n "$l" ] || continue
      if ! _board_gh issue edit "$issue" -R "$repo" --remove-label "$l" >/dev/null 2>&1 \
         && ! _board_gh issue edit "$issue" -R "$repo" --remove-label "$l" >/dev/null 2>&1; then
        echo "board: _board_issues_set_field — failed to clear claim stamp '$l' on $repo#$issue" >&2
        removal_failed=1
      fi
    done <<<"$hs_cur"
  fi

  if [ "$field_name" = "$BOARD_FIELD_STATUS" ]; then
    if [ "$is_done" -eq 1 ]; then
      [ "$state" = "closed" ] || { _board_gh issue close "$issue" -R "$repo" >/dev/null || return 1; }
    else
      [ "$state" = "open" ] || { _board_gh issue reopen "$issue" -R "$repo" >/dev/null || return 1; }
    fi
  fi
  _board_cache_dirty_after_write "$repo"
  # A stale-label removal that persistently failed above means the issue may
  # still carry a second fnd:<field>:* label — report that to the caller rather
  # than claiming a clean single-label flip (temperloop#601).
  [ "$removal_failed" -eq 0 ] || return 1
  return 0
}

# Free-text label stamp for the issues-only backend — board_stamp's ISSUE_*
# counterpart to _board_issues_set_field's single-select emulation (foundation
# #800, claim/edges split; board_stamp/board_set_number were explicitly left
# "out of scope, fail loud" by the #799 split this one builds on). UNLIKE
# status/component, a free-text value (e.g. a Host/Session claim stamp
# "host:sess8") is stored VERBATIM as the label suffix — no slugging — because
# slugging lowercases, which would corrupt a mixed-case hostname and silently
# break the foreign-host comparison board_claim_contended / reconcile.sh rely
# on. At most one `fnd:<field-slug>:*` label of this prefix is kept at a time
# (same single-value-per-field convention as status/component, read-before-
# write so an already-correct stamp is a no-op). An empty <text> CLEARS the
# field (strips the label, adds nothing) mirroring board_stamp's Projects-v2
# `--clear` semantics (foundation #259) — this is what makes build's epic
# park-back stamp-clear actually clear on an issues-only board too.
#
# Label-count note: distinct stamp VALUES accumulate as distinct repo-level
# label objects over the tracker's lifetime (there is no cheap "is this label
# still referenced anywhere" check to safely `gh label delete` on removal —
# doing so could yank a label still worn by a DIFFERENT issue the same
# host/session claimed concurrently). Growth is bounded by the number of
# distinct host:session8 stamps that have ever claimed something on this repo
# (`_board_issues_ensure_label` already memoizes/no-ops a re-create), not by
# the number of claims — acceptable for a tracker's realistic session volume;
# a future cleanup pass could sweep orphaned `fnd:host/session:*` labels if it
# ever becomes a real problem.
#   _board_issues_stamp_field <ISSUE_n> <field-name> <text>
_board_issues_stamp_field() {
  local item_id="$1" field_name="$2" text="$3"
  local issue repo prefix target_label issue_json cur l already_present=0 removal_failed=0

  issue="${item_id#ISSUE_}"
  repo="$(board_repo "${BOARD_CURRENT:-}")" || {  # setting:exempt — internal already-resolved board state, not an operator default
    echo "board: _board_issues_stamp_field — no current board (call board_resolve_item first)" >&2
    return 1
  }
  prefix="$(_board_issues_label_prefix "$field_name")"

  if [ -n "$text" ]; then
    target_label="${prefix}${text}"
    _board_issues_ensure_label "$repo" "$target_label" || return 1
  fi

  issue_json="$(_board_gh api "repos/$repo/issues/$issue" 2>/dev/null | _board_sanitize_control_chars)" || return 1
  [ -n "$issue_json" ] || return 1
  cur="$(printf '%s' "$issue_json" | jq -r --arg p "$prefix" '.labels[]?.name | select(startswith($p))')"

  while IFS= read -r l; do
    [ -n "$l" ] || continue
    if [ -n "$text" ] && [ "$l" = "$target_label" ]; then
      already_present=1
      continue
    fi
    # Same non-swallowing contract as _board_issues_set_field: retry once, then
    # surface a persistent removal failure via a non-zero return rather than
    # leaving a stale second fnd:<field>:* stamp label behind silently
    # (temperloop#601).
    if ! _board_gh issue edit "$issue" -R "$repo" --remove-label "$l" >/dev/null 2>&1 \
       && ! _board_gh issue edit "$issue" -R "$repo" --remove-label "$l" >/dev/null 2>&1; then
      echo "board: _board_issues_stamp_field — failed to remove stale '$prefix' label '$l' on $repo#$issue" >&2
      removal_failed=1
    fi
  done <<<"$cur"

  if [ -n "$text" ] && [ "$already_present" -eq 0 ]; then
    _board_gh issue edit "$issue" -R "$repo" --add-label "$target_label" >/dev/null || return 1
  fi
  _board_cache_dirty_after_write "$repo"
  [ "$removal_failed" -eq 0 ] || return 1
  return 0
}

# Detect whether <issue#> is already claimed by ANOTHER session BEFORE writing
# a new claim over it (foundation #800, extended to the Projects-v2 arm by a
# later fix — see below). Originally an issues-only-only pre-check; the
# Projects-v2 path used to have no such check and silently overwrote a foreign
# claim (relying entirely on reconcile.sh's separate, report-only pass to
# surface it after the fact — see reconcile.sh's "foreign claim" bucket). It is
# cheap on BOTH backends: the caller (claim.sh) has already resolved the item
# via board_resolve_item before calling this, so this is a pure jq read of the
# already-fetched BOARD_ITEMS_JSON, no extra `gh`/GraphQL call — board_resolve_item
# reshapes a Projects-v2 single-item resolve into the SAME {status, "host/Session"}
# item shape the issues-only backend produces (see board_resolve_item's field-
# flattening jq and _board_issues_resolve_item's issue_item def), so the check
# below is backend-agnostic and needs no `_board_is_issues_only` branch.
#
# CONTENDED means: the issue is currently In Progress AND carries an existing
# Host/Session stamp that is PRESENT and DIFFERENT from the stamp about to be
# written. Two cases are deliberately NOT contended (mirroring the Projects-v2
# adoption behavior test_claim.sh case 3 pins):
#   - re-claiming with the SAME stamp (idempotent self-reclaim), and
#   - an In-Progress item with NO existing stamp (adopting/repairing a
#     half-claim, the #103 failure mode — claim writes unconditionally there).
#   board_claim_contended <board#> <issue#> <new-stamp>
#     -> prints the FOREIGN existing stamp + rc 0 if contended
#        rc 1 (nothing printed) if safe to claim
board_claim_contended() {
  local issue="$2" new_stamp="$3" status existing
  status="$(printf '%s' "$BOARD_ITEMS_JSON" |
    jq -r --argjson n "$issue" '.items[] | select(.content.number==$n) | .status // ""')"
  [ "$status" = "$BOARD_OPT_INPROGRESS" ] || return 1
  existing="$(printf '%s' "$BOARD_ITEMS_JSON" |
    jq -r --argjson n "$issue" '.items[] | select(.content.number==$n) | .["host/Session"] // ""')"
  [ -n "$existing" ] || return 1
  [ "$existing" = "$new_stamp" ] && return 1
  printf '%s\n' "$existing"
  return 0
}

# Issues-only counterpart to board_create_many: there is no Projects board to
# item-add to (and so no index-lag retry to absorb — a label write is
# synchronous REST, not an async Projects-v2 mutation), so "landing an item"
# collapses to just labeling it Backlog. The issues already exist repo-side
# (gh issue create is the caller's job, same as the Projects path).
#
# RETURN CONTRACT: identical to board_create_many (foundation #1226) so the
# contract does not diverge by backend (see ISSUES-ONLY-BACKEND.md's
# function-level interface parity table) — 0/full, 1/partial, 2/total, with
# BOARD_UNLANDED_ISSUES carrying the space-separated failures on any non-zero.
#   _board_issues_create_many <board#> <url1> <num1> [<url2> <num2> ...]
_board_issues_create_many() {
  local board="$1"; shift
  local url num item_id
  local nums=() failed=()
  BOARD_CURRENT="$board"
  while [ "$#" -ge 2 ]; do
    url="$1"; num="$2"; shift 2
    nums+=("$num")
    item_id="ISSUE_$num"
    if board_set_status "$item_id" "$BOARD_OPT_BACKLOG"; then
      continue
    fi
    failed+=("$num")
    echo "warning: #$num (issues-only board $board) could not be labeled Backlog" >&2
  done
  if [ "${#failed[@]}" -eq 0 ]; then
    BOARD_UNLANDED_ISSUES=""
    return 0
  fi
  BOARD_UNLANDED_ISSUES="${failed[*]}"
  if [ "${#failed[@]}" -eq "${#nums[@]}" ]; then
    return 2
  fi
  return 1
}

# --- resolve a whole board ------------------------------------------------
# ONE live `gh issue list` read of the board's active (open) set, reshaped into
# the shared item form. Populates module globals reused by every accessor below.
#
#   board_resolve <board#>
#
# Sets: BOARD_PROJECT_ID, BOARD_FIELDS_JSON, BOARD_ITEMS_JSON, BOARD_CURRENT.
# BOARD_PROJECT_ID and BOARD_FIELDS_JSON are VESTIGIAL on the issues-only
# backend — there is no project node and no field schema — and are set to their
# documented empty values ("" and `{"fields":[]}`) so a caller reading them
# under `set -u` behaves exactly as it did before the Projects arm was removed.
# Returns non-zero (without completing) if the read fails, so a rate-limited run
# fails loudly instead of leaving the accessors on null. For a caller that
# touches exactly ONE issue, prefer board_resolve_item (below): it reads that one
# issue rather than the whole board.
board_resolve() {
  local board
  board="$(board_resolve_name "$1")" || return 1
  # Propagates board_backend's non-zero refusal for a stale `backend=projects`
  # conf line (ADR 0004) rather than resolving it silently.
  _board_is_issues_only "$board" || return 1
  BOARD_PROJECT_ID=""
  BOARD_FIELDS_JSON='{"fields":[]}'
  BOARD_ITEMS_JSON="$(board_item_list "$board")" || return 1
  BOARD_CURRENT="$board"
  return 0
}

# --- resolve ONE item -----------------------------------------------------
# Single-item callers don't need the whole board: this reads the ONE issue live
# (`gh api repos/<r>/issues/<n>`) instead of listing every item.
#
# It sets the SAME globals as board_resolve (BOARD_PROJECT_ID, BOARD_FIELDS_JSON,
# BOARD_ITEMS_JSON) in the identical item form — `{id, content:{number,title,
# type}, status, component, "host/Session", labels, milestone}` — so every
# accessor (board_item_id / board_item_title / board_item_milestone) and every
# mutator works against it unchanged; BOARD_ITEMS_JSON simply carries the one
# resolved item. The read is ALWAYS LIVE and never cached: the single-item
# callers are the mutating ones (the cross-session claim lock, a Done /
# In-Progress move) and must see fresh status.
#
# Drop-in for board_resolve at any caller that touches exactly ONE issue
# (claim.sh; a single Done / In-Progress move; a one-item contention read). The
# full board_resolve stays for callers that scan the whole board — worklist.sh,
# reconcile.sh, and the /triage + board_create_many burst paths.
#   board_resolve_item <board#> <issue#>
# Returns non-zero (without setting state) if <board#> is not a known board.
board_resolve_item() {
  local board issue="$2"
  board="$(board_resolve_name "$1")" || return 1
  # Propagates board_backend's non-zero refusal for a stale `backend=projects`
  # conf line (ADR 0004) rather than resolving it silently.
  _board_is_issues_only "$board" || return 1
  _board_issues_resolve_item "$board" "$issue"
  return $?
}
# Fetch just the item-list for a board — the board's ACTIVE (open) slice, which
# is exactly what every whole-board consumer wants. For read-only callers like
# worklist.sh that only need the items.
#
# ALWAYS LIVE: one `gh issue list` REST call per invocation, on REST's own
# 5,000/hr bucket. The optional per-board issue-corpus store
# (`board.<N>.cache=on` + a caller that sourced lib/cache.sh) is the ONE cache in
# front of this read — see _board_issues_item_list's PLANE MAP comment.
#   board_item_list <board#>  ->  item-list JSON on stdout
board_item_list() {
  local _b; _b="$(board_resolve_name "$1")" || return 1; set -- "$_b" "${@:2}"
  # Propagates board_backend's non-zero refusal for a stale `backend=projects`
  # conf line (ADR 0004) rather than resolving it silently.
  _board_is_issues_only "$1" || return 1
  _board_issues_item_list "$1"
  return $?
}
# Resolve the board item id for an issue number from the cached item-list.
#   board_item_id <issue#>  ->  item id (empty if the issue is not on the board)
board_item_id() {
  printf '%s' "$BOARD_ITEMS_JSON" |
    jq -r --argjson n "$1" '.items[] | select(.content.number == $n) | .id'
}

# Resolve the issue title for an issue number from the cached item-list.
#   board_item_title <issue#>  ->  title (empty if absent)
board_item_title() {
  printf '%s' "$BOARD_ITEMS_JSON" |
    jq -r --argjson n "$1" '.items[] | select(.content.number == $n) | .content.title // ""'
}

# Resolve an item's release-phase milestone TITLE from the resolved item-list.
# The release-phase axis rides GitHub's built-in, read-only `Milestone` field
# (foundation #97): a system field that can't be renamed/deleted, carried as
# `.milestone = {title}` by the issues-only reshape (issue_item) since
# temperloop#154. WRITES go through
# board_set_milestone (repo-level `gh issue edit`, since the board mirror is
# read-only).
#   board_item_milestone <issue#>  ->  milestone title (empty if none)
#
# Arg guard (temperloop#594): this accessor takes a SINGLE issue-number arg — no
# leading board arg, unlike the accessor-family siblings board_blocked_by_open /
# board_set_status that take/guard one. Called with the guessable leading-board-arg
# shape `board_item_milestone 7 592`, jq would select issue #7 (the board number)
# and silently return empty — reading as "unmilestoned" and masking real milestones
# (in a live /triage run this hid 8 milestoned Backlog items). So reject any call
# that isn't exactly one all-digits issue number, LOUD on stderr + non-zero, like
# board_set_status's item-id guard — the misuse surfaces even when a caller swallows
# the exit code.
board_item_milestone() {
  if [ "$#" -ne 1 ]; then
    echo "board: board_item_milestone takes exactly ONE issue# arg — no leading board arg (got $# arg(s): '$*'); it reads .milestone.title for a single issue" >&2
    return 1
  fi
  case "$1" in
    '' | *[!0-9]*)
      echo "board: board_item_milestone needs a numeric issue# (got '$1')" >&2
      return 1 ;;
  esac
  printf '%s' "$BOARD_ITEMS_JSON" |
    jq -r --argjson n "$1" '.items[] | select(.content.number == $n) | .milestone.title // ""'
}

# Print the OPEN issues that block <issue#>, one number per line (empty output =
# not blocked). GitHub native issue *dependencies* (blocked_by) — a first-class
# relationship, separate from Status / labels / sub-issues. Reads the per-issue
# REST endpoint (NOT the Projects board / cache), so it is ALWAYS LIVE and costs
# one REST call per issue — REST's 5,000/hr bucket, separate from the Projects-v2
# GraphQL budget the board-page reads draw on. Callers MUST gate on candidate
# items only (a triage Backlog slice / a /next in-scope set), never the whole
# board. Emptiness is the gate; the numbers are returned so a caller can surface
# `blocked_by #M`. Pipes to an external `jq` (like board_resolve_item) so the
# `_board_gh` seam stays replay-testable.
#   board_blocked_by_open <board> <issue#>  ->  open-blocker numbers, one per line
board_blocked_by_open() {
  local board="$1" issue="$2" repo
  repo="$(board_repo "$board")" || return 1
  _board_gh api "repos/$repo/issues/$issue/dependencies/blocked_by" 2>/dev/null |
    _board_sanitize_control_chars |
    jq -r '.[] | select(.state=="open") | .number'
}

# Resolve an issue NUMBER to its REST **database id** (`.id`) — the integer the
# dependencies WRITE API keys blockers by (distinct from `.number` and the
# GraphQL `.node_id`). Internal helper for the blocked_by writers below; goes
# through the `_board_gh` seam so those writers stay replay-testable. Empty
# output + non-zero when the issue can't be resolved.
#   _board_issue_db_id <repo> <issue#>  ->  numeric database id, or empty
_board_issue_db_id() {
  local repo="${1:-}" issue="${2:-}" id
  id="$(_board_gh api "repos/$repo/issues/$issue" 2>/dev/null |
    _board_sanitize_control_chars |
    jq -r '.id // empty')"
  [ -n "$id" ] || return 1
  printf '%s' "$id"
}

# Add a native GitHub `blocked_by` dependency edge — make <issue#> blocked by
# <blocker#>. The WRITE counterpart to board_blocked_by_open (foundation#1221):
# the adapter had the reader but no writer, so a dependency-edge write had to
# bypass the adapter via raw REST, against the "all board reads/writes go through
# the adapter" rule. Like the reader this is per-issue REST, ALWAYS LIVE (REST's
# 5,000/hr bucket, not the GraphQL board budget) — and there is NO board cache to
# bust, since board_blocked_by_open reads the same live endpoint, so a written
# edge is visible on the very next read. The dependencies WRITE API keys the
# blocker by its **database id**, not its number (foundation#1221 verified: the
# issue object exposes `.id` ≠ `.number`), so we resolve <blocker#> → its id
# first, then POST. Both calls go through `_board_gh` so the writer is
# replay-testable like its reader sibling. Adding an edge that ALREADY exists is
# the API's 422 (surfaced as a non-zero return), NOT a silent success — a caller
# wanting idempotency gates on board_blocked_by_open first.
#   board_blocked_by_add <board> <issue#> <blocker#>  ->  exit 0 on success
board_blocked_by_add() {
  local board="${1:-}" issue="${2:-}" blocker="${3:-}" repo blocker_id
  if [ "$#" -ne 3 ]; then
    echo "board: board_blocked_by_add takes <board> <issue#> <blocker#> (got $#: '$*')" >&2
    return 1
  fi
  case "$issue" in '' | *[!0-9]*) echo "board: board_blocked_by_add needs a numeric <issue#> (got '$issue')" >&2; return 1 ;; esac
  case "$blocker" in '' | *[!0-9]*) echo "board: board_blocked_by_add needs a numeric <blocker#> (got '$blocker')" >&2; return 1 ;; esac
  repo="$(board_repo "$board")" || return 1
  if ! blocker_id="$(_board_issue_db_id "$repo" "$blocker")"; then
    echo "board: board_blocked_by_add could not resolve the database id of blocker #$blocker in $repo" >&2
    return 1
  fi
  _board_gh api --method POST "repos/$repo/issues/$issue/dependencies/blocked_by" \
    -F "issue_id=$blocker_id" >/dev/null
}

# Remove a native `blocked_by` dependency edge — the DELETE counterpart to
# board_blocked_by_add (foundation#1221), so the writer contract is whole. Same
# database-id keying (the DELETE path ends in the blocker's `.id`, not its
# number). Removing an edge that ISN'T present is the API's 404 (non-zero), not a
# silent success. Same always-live REST / no-cache posture as _add.
#   board_blocked_by_remove <board> <issue#> <blocker#>  ->  exit 0 on success
board_blocked_by_remove() {
  local board="${1:-}" issue="${2:-}" blocker="${3:-}" repo blocker_id
  if [ "$#" -ne 3 ]; then
    echo "board: board_blocked_by_remove takes <board> <issue#> <blocker#> (got $#: '$*')" >&2
    return 1
  fi
  case "$issue" in '' | *[!0-9]*) echo "board: board_blocked_by_remove needs a numeric <issue#> (got '$issue')" >&2; return 1 ;; esac
  case "$blocker" in '' | *[!0-9]*) echo "board: board_blocked_by_remove needs a numeric <blocker#> (got '$blocker')" >&2; return 1 ;; esac
  repo="$(board_repo "$board")" || return 1
  if ! blocker_id="$(_board_issue_db_id "$repo" "$blocker")"; then
    echo "board: board_blocked_by_remove could not resolve the database id of blocker #$blocker in $repo" >&2
    return 1
  fi
  _board_gh api --method DELETE "repos/$repo/issues/$issue/dependencies/blocked_by/$blocker_id" >/dev/null
}

# Print the parent EPIC's issue number for a sub-issue, or empty for a singleton
# (foundation #159). The REST issue object has NO `.parent` key — the parent link
# is `.parent_issue_url` (e.g. ".../issues/145") and `.sub_issues_summary` is the
# issue's *own* children. Reading `.parent` therefore resolves empty for EVERY
# issue, silently mis-classifying every epic child as a parentless singleton — the
# exact bug this accessor exists to prevent. We parse the trailing number out of
# `.parent_issue_url` so the field name lives in ONE place (this adapter), mirroring
# board_blocked_by_open: per-issue REST endpoint (NOT the Projects board / cache),
# ALWAYS LIVE, one REST call (REST's 5,000/hr bucket, separate from the GraphQL
# board budget). Callers MUST gate on candidate items only, never the whole board.
# Empty output = no parent (a directly-workable singleton). Pipes to an external
# `jq` (like its siblings) so the `_board_gh` seam stays replay-testable.
#
# --- relationship reads are LIVE-ONLY (temperloop#1163) ----------------------
# The cache-relationships arm temperloop#1030 added here was REMOVED. It rested
# on a premise this comment previously asserted as fact — that the bulk
# issues-list row "carries the parent link as a nested `.parent.number`" — which
# is false, and was false when it was written. The bulk list carries
# `sub_issues_summary` (counts only); `parent_issue_url` comes from the
# single-issue endpoint. So the cached arm read a key that was never present and
# returned empty for every issue, silently. See the block comment above
# board_sub_issues for the measurement, the blast radius (board-mirror.sh's
# epic-close cascade reading a 0 open-child count as "fully drained"), and the
# zero-API-cost path back to caching these reads (temperloop#1165).
#
# board_blocked_by_open (above) is likewise live-only — native issue
# *dependencies* are a different relationship, deliberately never cached.
#   board_parent_issue <board> <issue#>  ->  parent epic number, or empty
board_parent_issue() {
  local board="$1" issue="$2" repo url
  repo="$(board_repo "$board")" || return 1
  # NO CACHED ARM — removed in temperloop#1163. See the block comment above
  # board_sub_issues for the full finding; in short, the snapshot has no
  # `.parent` field to read, so the cached arm returned empty for every issue.
  url="$(_board_gh api "repos/$repo/issues/$issue" 2>/dev/null |
    _board_sanitize_control_chars |
    jq -r '.parent_issue_url // empty')"
  [ -n "$url" ] && basename "$url"
  return 0
}

# Print the CHILD (sub-issue) numbers of <issue#>, one per line (empty output
# = no children — a singleton, or an epic with none yet). The read-side
# counterpart to board_parent_issue, using GitHub's native sub-issues REST
# endpoint (foundation #800, claim/edges split). Works on a PLAIN issue with
# no Projects board provisioned — same per-issue REST shape as
# board_parent_issue / board_blocked_by_open (ALWAYS LIVE, REST's own
# 5,000/hr bucket). Callers MUST gate on candidate items
# only, never the whole board (same caveat as its siblings). Pipes to an
# external `jq` so the `_board_gh` seam stays replay-testable.
#
# --- cache-relationships item (F#988 Contract) -------------------------------
# Same cache-enabled check, same cache.sh delegation, and same fall-through-live
# degradation (one stderr notice) as board_parent_issue above — see its comment
# for the full contract. Inversion here selects every snapshot row whose
# `.parent.number` equals <issue#> and prints that row's OWN `.number`; the
# snapshot's ALL-states corpus (open AND closed — cache.sh never filters state,
# see CACHE-STORE.md) means a closed child is preserved here exactly as the live
# `/sub_issues` endpoint already includes closed children — no behavior change,
# just a cheaper read when warm.
# OPTIONAL STATE FILTER (temperloop#1119). The third arg narrows the result to
# children in one state; it DEFAULTS to `all`, so every pre-existing two-arg
# call is byte-identical to before. It exists because the epic-close count
# ("how many children are still open?") is a relationship read like any other,
# and without a state filter its only options were the raw REST endpoint —
# which bypasses this cached arm entirely — or a per-child state lookup, which
# is N extra calls to answer what one snapshot pass already knows. Both arms
# filter, so cached and live stay byte-parity under every state value.
#   board_sub_issues <board> <issue#> [all|open|closed]  ->  numbers, one per line
board_sub_issues() {
  local board="$1" issue="$2" state="${3:-all}" repo raw
  case "$state" in
    all | open | closed) ;;
    *) echo "board_sub_issues: state must be all|open|closed (got '$state')" >&2; return 2 ;;
  esac
  repo="$(board_repo "$board")" || return 1
  # NO CACHED ARM — removed in temperloop#1163, because it was answering from a
  # field the store does not contain and so returned EMPTY for every issue.
  #
  # THE DEFECT. temperloop#1030 added a cached arm here on the premise (stated
  # in this file's own prior comment, and in temperloop#1023's acceptance as
  # "verified live 2026-07-05") that the bulk issues-list payload carries the
  # parent link as a nested `.parent.number`. It does not, and measurement says
  # it did not: 0 of 911 rows in foundation's snapshot and 0 of 611 in
  # temperloop's carry any `.parent` key. The bulk list carries
  # `sub_issues_summary` (counts) — the *single-issue* endpoint is what carries
  # the linkage, as `parent_issue_url`.
  #
  # WHY IT MATTERED. The failure was silent and directional: `board_sub_issues
  # <b> <epic> open | wc -l` returned 0 for every epic, and
  # build/board-mirror.sh treats a 0 open-child count as "epic fully drained"
  # and CLOSES the epic. Verified on a real open epic: temperloop#524 live=1
  # open child, cached=0. Once board-mirror.sh began sourcing cache.sh
  # (temperloop#1118) and the enable axis was switched on, that path was armed
  # to close epics with open children.
  #
  # WHY LIVE-ONLY RATHER THAN A FIXED CACHED ARM. The linkage is genuinely
  # absent from the snapshot, so there is nothing here to read correctly — and a
  # relationship read backs an irreversible action (closing an epic), which is
  # the wrong place to trade correctness for latency. `board_blocked_by_open`
  # is already live-only for the same reason.
  #
  # THIS IS RECOVERABLE, AND CHEAPLY (temperloop#1165). cache_refresh_details
  # ALREADY issues one single-issue API call per issue — the exact call whose
  # response carries `parent_issue_url` — and discards the field when it
  # projects to {body, comments, number, schema_version, updatedAt}. Persisting
  # it there costs ZERO additional API calls and makes the parent graph fully
  # derivable on disk, at which point these reads can be served locally and
  # indexed. Until that lands, live is the only correct answer.
  _board_gh api "repos/$repo/issues/$issue/sub_issues" 2>/dev/null |
    _board_sanitize_control_chars |
    jq -r --arg st "$state" '.[] | select($st == "all" or (.state // "open") == $st) | .number'
  return 0
}

# Add a native GitHub sub-issue link — make <child#> a child of <parent#>. The
# WRITE counterpart to board_sub_issues (temperloop#1188, re-cut from
# foundation#1287): the adapter had the reader but no writer, so a sub-issue
# link had to bypass the adapter via raw REST — the linkage axis's last
# sanctioned raw-gh-api hole, alongside blocked_by (temperloop#1221,
# board_blocked_by_add above) which this mirrors shape-for-shape. That axis
# already failed silently once on the READ side (temperloop#1030's cached arm
# returned 0 children for every epic and armed board-mirror.sh to close epics
# with live children — ripped out in #1163), which is why this write path gets
# the adapter's same guards rather than staying a bespoke inline POST.
#
# Per-issue REST, ALWAYS LIVE (REST's own 5,000/hr bucket, not the GraphQL
# board budget). The sub-issues WRITE API keys the CHILD by its database id
# (not its number, same as blocked_by's blocker) — resolve <child#> -> id
# first, then POST. Both calls go through `_board_gh` so the writer is
# replay-testable like its blocked_by sibling. Adding a link that ALREADY
# exists is the API's 4xx (surfaced as a non-zero return), NOT a silent
# success — a caller wanting idempotency gates on board_sub_issues first
# (board-mirror.sh's cmd_ensure_epic already does this).
#
# Busts the issue-cache store entry for <parent#>'s repo on a successful write
# — same `_board_cache_dirty_after_write` shape as board_set_status /
# _board_issues_set_field — so a following board_sub_issues read for this repo
# doesn't keep serving a pre-write snapshot for the rest of the store's TTL
# window.
#   board_add_sub_issue <board> <parent#> <child#>  ->  exit 0 on success
board_add_sub_issue() {
  local board="${1:-}" parent="${2:-}" child="${3:-}" repo child_id
  if [ "$#" -ne 3 ]; then
    echo "board: board_add_sub_issue takes <board> <parent#> <child#> (got $#: '$*')" >&2
    return 1
  fi
  case "$parent" in '' | *[!0-9]*) echo "board: board_add_sub_issue needs a numeric <parent#> (got '$parent')" >&2; return 1 ;; esac
  case "$child" in '' | *[!0-9]*) echo "board: board_add_sub_issue needs a numeric <child#> (got '$child')" >&2; return 1 ;; esac
  repo="$(board_repo "$board")" || return 1
  if ! child_id="$(_board_issue_db_id "$repo" "$child")"; then
    echo "board: board_add_sub_issue could not resolve the database id of child #$child in $repo" >&2
    return 1
  fi
  _board_gh api --method POST "repos/$repo/issues/$parent/sub_issues" \
    -F sub_issue_id="$child_id" >/dev/null || return 1
  _board_cache_dirty_after_write "$repo"
  return 0
}

# Remove a native GitHub sub-issue link — the DELETE counterpart to
# board_add_sub_issue, so the writer contract is whole (operator-decided
# 2026-08-07: an add-only surface would leave remove as a sanctioned raw-gh-api
# bypass, merely narrowing the exact hole this pair closes). GitHub's remove
# endpoint is deliberately SINGULAR (`.../sub_issue`, not `.../sub_issues`) and
# — UNLIKE blocked_by_remove, whose DELETE keys the blocker off the URL path —
# takes the child's database id in the request BODY, not the path (verified
# against the GitHub Sub-issues REST API reference). Same database-id
# resolution as _add. Removing a link that ISN'T present is the API's 4xx
# (non-zero), not a silent success. Same always-live REST / write-through
# cache-bust posture as _add.
#   board_remove_sub_issue <board> <parent#> <child#>  ->  exit 0 on success
board_remove_sub_issue() {
  local board="${1:-}" parent="${2:-}" child="${3:-}" repo child_id
  if [ "$#" -ne 3 ]; then
    echo "board: board_remove_sub_issue takes <board> <parent#> <child#> (got $#: '$*')" >&2
    return 1
  fi
  case "$parent" in '' | *[!0-9]*) echo "board: board_remove_sub_issue needs a numeric <parent#> (got '$parent')" >&2; return 1 ;; esac
  case "$child" in '' | *[!0-9]*) echo "board: board_remove_sub_issue needs a numeric <child#> (got '$child')" >&2; return 1 ;; esac
  repo="$(board_repo "$board")" || return 1
  if ! child_id="$(_board_issue_db_id "$repo" "$child")"; then
    echo "board: board_remove_sub_issue could not resolve the database id of child #$child in $repo" >&2
    return 1
  fi
  _board_gh api --method DELETE "repos/$repo/issues/$parent/sub_issue" \
    -F sub_issue_id="$child_id" >/dev/null || return 1
  _board_cache_dirty_after_write "$repo"
  return 0
}

# Guard: the project item-edit writers below are keyed by a PVTI_* item-id, NOT a
# board number or issue#. Called with the wrong arg shape (e.g. `board_set_status
# 489 "Done"`), the underlying gh item-edit fails opaquely — and because callers
# commonly swallow the exit code (`|| true` in best-effort bulk paths), a reported
# claim/status-flip silently no-ops (foundation #128: F103 "claimed In Progress"
# never took; #489 "Done" failed twice). Validate the arg shape up front and fail
# LOUD with a clear message, so the misuse surfaces even when the return code is
# swallowed. Resolve an item-id first with board_resolve_item / board_item_id.
_board_assert_item_id() {
  case "$1" in
    ISSUE_*) return 0 ;;
    PVTI_*)
      echo "board: ${2:-this op} was given a PVTI_* Projects-v2 item-id ('$1'), but the Projects-v2 arm was REMOVED (ADR 0004) — item ids are ISSUE_<issue#> now; re-resolve with board_resolve_item/board_item_id" >&2
      return 1 ;;
    *)
      echo "board: ${2:-this op} needs an ISSUE_* item-id as arg1 (got '$1') — resolve it first with board_resolve_item/board_item_id; a board number or issue# silently no-ops" >&2
      return 1 ;;
  esac
}

# Set the worklist single-select on an item to a named option.
#   board_set_status <item-id> <option-name> [field-name]
#     e.g. board_set_status ISSUE_42 "In Progress"            # default Status field
#          board_set_status ISSUE_42 "Backlog" "Some Field"   # explicit field override
# field-name defaults to BOARD_FIELD_STATUS (the built-in Status field every board
# governs on). The override arg remains for callers that target another
# single-select-shaped field (Component). Delegates to the `fnd:` label writer,
# which emulates a single-select: at most one `fnd:<field>:*` label at a time.
# Returns non-zero without editing if arg1 is not an ISSUE_* item-id
# (foundation #128).
board_set_status() {
  local item_id="$1" opt_name="$2" field_name="${3:-$BOARD_FIELD_STATUS}"
  _board_assert_item_id "$item_id" board_set_status || return 1
  _board_issues_set_field "$item_id" "$field_name" "$opt_name"
  return $?
}

# One-call Done write that survives an issue already being CLOSED
# (temperloop#1217) and needs NO prior cross-Bash-call shell state — a caller
# in a fresh Bash tool invocation can call this directly with nothing
# resolved first.
#
# DELIBERATE DEPARTURE from the usual "resolve first with board_item_id /
# board_resolve_item, then act" model this kernel doc's own board-adapter
# rule documents: that model is actively WRONG for a Done write specifically,
# for two reasons. (1) `board_item_id` reads the whole-board `BOARD_ITEMS_JSON`
# (board_resolve/board_item_list), and that list is `--state open` only (mirrors
# the Projects-v2 active-set convention) — so on an issue that is ALREADY
# closed (the #1217 case: a merged PR's own `Closes #N` beat the adapter's Done
# write to the punch), `board_item_id` returns EMPTY and a caller's
# `board_set_status "" Done` silently no-ops, leaving the stale
# `fnd:status:*`/`fnd:host/session:*` labels standing on a closed issue. (2)
# even `board_resolve_item` (which DOES read live and sees a closed issue) sets
# `BOARD_ITEMS_JSON`/`BOARD_CURRENT` as process globals — no help across a
# resolve-then-act split, since shell state does not persist between separate
# Bash tool calls in an agent session. So this helper skips resolution
# entirely: the `ISSUE_<n>` item id is fully deterministic (see `issue_item`'s
# `id: "ISSUE_" + ($n|tostring)` def above — it needs no lookup, just the
# issue number), and `_board_issues_set_field`'s Done arm already does its own
# live single-issue `gh api issues/<n>` read to decide what to strip/close —
# so one call is correct whether the issue starts open, already closed, or
# already fully Done (re-run is a no-op, exit 0).
#
# Saves and restores BOARD_CURRENT, so a caller mid-way through its own
# multi-op board sequence is not left with this helper's board silently
# substituted for whatever it had resolved before — the adapter is left with
# no global modified, which is the property this helper exists to guarantee
# alongside the state-independence above.
#
# Takes NO --comment param by design: a reason comment is repo-level content,
# not board state, and bundling a non-idempotent `gh issue comment` into this
# otherwise read-before-write-idempotent mutator would repost it on retry.
# Callers post their own comment (`gh issue comment`) immediately BEFORE
# calling this.
#
# MISUSE WARNING: never call this for an issue whose close is properly owed to
# a merged PR's own `Closes #N` (kernel doc § Issue linkage) — that PR's merge
# is what should close it. Calling this first closes the issue EARLY, which
# breaks both the auto-close linkage (GitHub's closing-keyword match no longer
# has an open issue to act on) and the merge-queue accounting that a
# still-open issue number represents. This helper is for a Done write the
# adapter itself owns outright: closing with no linked PR, or repairing a Done
# write a #1217-style race already lost.
#   board_close_done <board#> <issue#>  -> exit 0 on success (idempotent)
board_close_done() {
  if [ "$#" -ne 2 ]; then
    echo "board: board_close_done takes <board#> <issue#> (got $#: '$*')" >&2
    return 1
  fi
  local board="$1" issue="$2" rc saved_board
  case "$issue" in '' | *[!0-9]*) echo "board: board_close_done needs a numeric <issue#> (got '$issue')" >&2; return 1 ;; esac
  board="$(board_resolve_name "$board")" || return 1
  # Propagates board_backend's non-zero refusal for a stale `backend=projects`
  # conf line (ADR 0004) rather than resolving it silently.
  _board_is_issues_only "$board" || return 1
  # Save/restore BOARD_CURRENT around the write below. `${BOARD_CURRENT:-}` is
  # `set -u`-safe whether or not the caller had it set, and always restores it
  # to a defined (possibly empty) string — this function is defined IN
  # board.sh, so no caller can reach it without having sourced the file, and
  # every neighboring script-level BOARD_CURRENT init in this file already
  # runs unconditionally too. There is no unset-vs-empty case to preserve.
  saved_board="${BOARD_CURRENT:-}"  # setting:exempt — internal already-resolved board state, not an operator default
  BOARD_CURRENT="$board"
  # `|| rc=$?` (not a bare trailing status check) so the restore below still
  # runs under a caller's `set -e` even when this call's exit status goes
  # untested.
  rc=0
  board_set_status "ISSUE_$issue" "$BOARD_OPT_DONE" || rc=$?
  BOARD_CURRENT="$saved_board"
  return $rc
}

# Set the board-native Component single-select on an item to a named option.
# Thin, intention-revealing wrapper over board_set_status's field-override arm
# (the Component axis is just another single-select). Returns non-zero without
# editing if the board has no Component field or no such option (the field is
# stageFind-seeded; not every board defines it).
#   board_set_component <item-id> <component-name>
board_set_component() {
  board_set_status "$1" "$2" "$BOARD_FIELD_COMPONENT"
}

# Resolve THIS machine's claim-stamp host label — the value written into every
# `Host/Session` board stamp (`<host>:<sess8>`) and read back by every script
# that needs to know whether a claim is "ours" (claim.sh / release.sh /
# capture.sh / reconcile.sh / board-mirror.sh). ONE helper, ONE resolution
# order, so a single machine can never resolve to two different labels
# depending on which script asked (temperloop#1455 — session 15297bb9 stamped
# some issues `mini` and others `Mac-mini` on the SAME machine because five
# call sites each inlined their own copy of this fallback — three different
# variants — and a sixth site, this repo's own prose spec for the value
# (`claude/commands/build.md`), documented a variant none of the shell code
# actually implemented).
#
# Resolution order, highest wins:
#   1. $SUBSET_HOST_LABEL    — the current override name. An operator sets
#      this once per machine (durable per-machine config: a shell-profile
#      export, or a launchd agent's own `EnvironmentVariables` dict — whichever
#      contexts that machine actually runs this tooling from) to a SHORT,
#      STABLE label that won't drift if the box is renamed. This is
#      deliberately NOT `hostname -s`: macOS's Bonjour/System-Settings hostname
#      can differ from a human's preferred short label (observed on the
#      machine that motivated this fix: `hostname -s` = "Mac-mini", the
#      desired/established label = "mini") and can itself change on a rename,
#      whereas an operator-set override stays put until they change it again.
#      THIS is why the override wins over `hostname -s` rather than the other
#      way around — the override is the more durable, more intentional value.
#   2. $STAGEFIND_HOST_LABEL — legacy/back-compat name for the same override
#      (predates the `SUBSET_` rename), kept as a nested fallback so a machine
#      that only ever set the old name still resolves consistently instead of
#      silently falling through past it to `hostname -s`.
#   3. `hostname -s`          — the built-in, zero-config fallback every
#      machine has even with no override set anywhere.
#   4. A literal "unknown"    — only if even `hostname -s` (and the bare
#      `hostname` retry below it) comes back empty, e.g. a broken/missing
#      `hostname` binary in a stripped-down launchd environment. This function
#      MUST NEVER return an empty string: an empty host half would corrupt the
#      `<host>:<sess8>` claim-stamp format downstream.
#
# WHY THE OVERRIDE ALONE ISN'T ENOUGH, AND WHAT THIS FUNCTION DOES AND DOES NOT
# FIX: an exported env var is only visible to a process that had it exported
# INTO its environment — an interactive shell with a profile loaded sees it,
# but a bare launchd/cron invocation (no profile sourced) does NOT unless the
# operator ALSO exported it into that context (e.g. a launchd plist's own
# `EnvironmentVariables`). Populating the override consistently across every
# context on a given machine is per-machine operator data — out of scope for
# this function (and for kernel code generally; see the issue's own scope
# note). What this function guarantees is narrower but was the actual bug:
# EVERY call site in this tree resolves the override (when present) and the
# built-in fallback (when it isn't) through the exact same ordered chain, so
# two scripts invoked in the SAME environment can never disagree — the
# session-15297bb9 regression was two call sites disagreeing given identical
# inputs, not the override being unset somewhere.
#
#   board_host_label   ->  a non-empty host label, always
board_host_label() {
  local label
  label="${SUBSET_HOST_LABEL:-${STAGEFIND_HOST_LABEL:-$(hostname -s)}}"
  if [ -z "$label" ]; then
    label="$(hostname -s 2>/dev/null)"
    [ -n "$label" ] || label="$(hostname 2>/dev/null)"
    [ -n "$label" ] || label="unknown"
  fi
  printf '%s' "$label"
}

# This session's OWN claim stamp — the `<host>:<sess8>` string claim.sh writes
# into `fnd:host/session:*`, and the one any reader must compare against to
# answer "is this claim MINE?".
#
# Same reasoning as board_host_label above, one level up: the format itself had
# two would-be call sites (claim.sh writing it, claim-guard.sh reading it back),
# and two sites deriving it independently can disagree — which for a claim stamp
# means either culling a peer's actively-claimed issue or refusing to cull our
# own (temperloop#1220). This is the single owner of the format; never re-derive
# `${host}:${sess:0:8}` at a call site.
#
# `$CLAUDE_CODE_SESSION_ID` is truncated to 8 chars to match the board stamp's
# historical shape; with no session id in the environment (a hand-run shell, cron
# without the harness) the session half is the literal `manual` — so a manual
# run's stamp is still non-empty and still comparable.
#
#   board_own_stamp   ->  "<host>:<sess8>" or "<host>:manual", always non-empty
board_own_stamp() {
  local host sess
  host="$(board_host_label)"
  sess="${CLAUDE_CODE_SESSION_ID:-}"
  if [ -n "$sess" ]; then printf '%s:%s' "$host" "${sess:0:8}"; else printf '%s:manual' "$host"; fi
}

# Stamp a free-text field on an item.
#   board_stamp <item-id> <field-name> <text>   (e.g. "Host/Session" "host:abc")
# Delegates to _board_issues_stamp_field — a `fnd:<field-slug>:<verbatim-text>`
# label, single-value-per-prefix. UNLIKE status/component the value is stored
# VERBATIM (no slugging), because slugging lowercases and would corrupt a
# mixed-case hostname. An EMPTY <text> CLEARS the field (strips the label, adds
# nothing) — this is what makes build Step 5's epic park-back stamp-clear
# actually clear. Returns non-zero without editing if arg1 is not an ISSUE_*
# item-id.
board_stamp() {
  local item_id="$1" field_name="$2" text="$3"
  _board_assert_item_id "$item_id" board_stamp || return 1
  _board_issues_stamp_field "$item_id" "$field_name" "$text"
  return $?
}

# Assign an issue's release-phase milestone (foundation #97). The board's
# `Milestone` column is GitHub's read-only mirror of the issue's native milestone,
# so this writes at the REPO level (`gh issue edit … --milestone`) rather than via
# a board item-edit — keyed by issue NUMBER, not item id. Routes through the
# `_board_gh` seam (testable). The milestone must already exist in the repo (create it
# once with `gh api repos/<owner>/<repo>/milestones`). Returns non-zero (no edit)
# if the board number is unknown.
#   board_set_milestone <board#> <issue#> <milestone-title>
board_set_milestone() {
  local board="$1" issue="$2" title="$3" repo
  repo="$(board_repo "$board")" || return 1
  _board_gh issue edit "$issue" -R "$repo" --milestone "$title" >/dev/null || return 1
}

# Print the titles of the OPEN milestones marked "triage:active", one per line
# (foundation #210). A milestone is "active" iff its GitHub DESCRIPTION contains
# the literal HTML-comment marker `<!-- triage:active -->`; the default is
# inactive (no marker). The marker is MACHINE-OWNED — never hand-edited; written
# only via board_set_milestone_description (which the milestone.sh CLI verbs call
# in a later item). Milestones are read over REST (repos/<owner>/<repo>/milestones)
# over REST (REST's own 5,000/hr bucket). Routed through the `_board_gh` seam
# so the fixture-replay harness can stub it; pipes to an external `jq` like
# board_blocked_by_open / board_parent_issue so the seam stays replay-testable.
# Returns non-zero (no output) on an unknown board OR on an actual milestone-fetch
# failure — the API output is captured first (`|| return 1`) so a genuine REST
# error propagates instead of being masked by jq's exit code. A SUCCESSFUL fetch
# that finds zero active markers stays exit 0 with empty output: "none active" is
# the normal default state (milestones default inactive), NOT a failure. This lets
# a caller distinguish "fetch failed" (non-zero) from "genuinely none active"
# (exit 0, empty) — the disambiguation /triage's active-milestone guard needs
# (temperloop#152). Callers that only capture output (e.g. milestone.sh) are
# unaffected: an empty result reads the same either way.
#   board_active_milestones <board#>  ->  active milestone titles, one per line
board_active_milestones() {
  local board="$1" repo raw
  repo="$(board_repo "$board")" || return 1
  raw="$(_board_gh api "repos/$repo/milestones?state=open" 2>/dev/null)" || return 1
  printf '%s' "$raw" |
    _board_sanitize_control_chars |
    jq -r '.[] | select((.description // "") | contains("<!-- triage:active -->")) | .title'
}

# Set (overwrite) an OPEN milestone's GitHub description, resolving the milestone
# by TITLE (foundation #210). This is the WRITE half of the triage:active marker
# pair (board_active_milestones reads it): the milestone.sh CLI verbs call this to
# stamp/clear the machine-owned `<!-- triage:active -->` marker. Like its read
# sibling it goes over REST — a GET to resolve the title->number (and read the
# current description), then a PATCH of repos/<owner>/<repo>/milestones/<number>.
# Both calls route
# through the `_board_gh` seam (stubbable). IDEMPOTENT: if the milestone's current
# description already equals the target, it skips the PATCH (no-op, returns 0 — do
# not double-write). Fails loudly (non-zero, clear stderr) on an unknown board or
# an unknown milestone title.
#   board_set_milestone_description <board#> <title> <description>
board_set_milestone_description() {
  local board="$1" title="$2" desc="$3" repo number current
  repo="$(board_repo "$board")" || {
    echo "board: board_set_milestone_description — unknown board '$board'" >&2
    return 1
  }
  # Resolve the milestone by title over REST, capturing its number + current
  # description in one read (state=all so a closed milestone still resolves).
  local milestone_json
  milestone_json="$(
    _board_gh api "repos/$repo/milestones?state=all" 2>/dev/null |
      _board_sanitize_control_chars |
      jq -c --arg t "$title" 'map(select(.title == $t)) | .[0] // empty'
  )"
  if [ -z "$milestone_json" ]; then
    echo "board: board_set_milestone_description — no milestone titled '$title' in $repo" >&2
    return 1
  fi
  number="$(printf '%s' "$milestone_json" | jq -r '.number')"
  current="$(printf '%s' "$milestone_json" | jq -r '.description // ""')"
  # Idempotent: identical description -> skip the PATCH (no double-write).
  if [ "$current" = "$desc" ]; then
    return 0
  fi
  _board_gh api --method PATCH "repos/$repo/milestones/$number" \
    -f description="$desc" >/dev/null || return 1
}

# Set a number field on an item (e.g. the worklist `Seq` order).
#   board_set_number <item-id> <field-name> <value>   (e.g. "Seq" 3)
# Resolves the field id by name from cache, then issues the --number item-edit.
# Returns non-zero without editing if the field name does not resolve.
#
# Seq is RETIRED BY DESIGN on the issues-only backend (ADR 0006), not emulated —
# an ISSUE_* item-id has no Projects-v2 field schema to resolve a number field
# against, and no `fnd:seq:<n>` label encoding was introduced to fake one (that
# would mint an unbounded numeric label namespace, recreating the label sprawl
# the issues-only migration removes). Work ordering on this backend lives where
# it already effectively lived: epic dependency levels (computed from plan
# notes) and milestones. So an ISSUE_* item-id fails LOUD here with a message
# naming the retirement and its replacement signal, instead of falling through
# to the generic "field id doesn't resolve" silent return 1 below.
board_set_number() {
  local item_id="$1"
  _board_assert_item_id "$item_id" board_set_number || return 1
  echo "board: board_set_number — Seq is retired by design on the issues-only backend — ordering lives in epic dependency levels and milestones (ADR 0006)" >&2
  return 1
}
# Land many already-created issues in Backlog.
#
# This is the BURST path for /triage and /build, which create N issues/epics at
# once. On the issues-only backend "landing an item" is just labeling it Backlog
# — a synchronous REST write per issue, with no board to item-add to and so no
# index-lag retry to absorb (the Projects-v2 async-indexing retry loop, and its
# GraphQL budget guard, died with that arm — ADR 0004). The issues themselves
# already exist (`gh issue create` is the caller's job, repo-level, not board
# state).
#
# RETURN CONTRACT (foundation #1226 — supersedes the old "always returns 0"
# behavior, which let a genuinely-dropped item print as a success one line
# later in every caller). An item that fails to label WARNs on stderr AND is
# counted as a failure — a single exit code can't distinguish "everything
# failed" from "one straggler in a big batch failed", so:
#   - every item landed  -> return 0, BOARD_UNLANDED_ISSUES=""
#   - SOME items failed  -> return 1 (partial), BOARD_UNLANDED_ISSUES=
#                           "<space-separated un-landed issue numbers>"
#   - ALL items failed   -> return 2 (total),   BOARD_UNLANDED_ISSUES=
#                           "<space-separated un-landed issue numbers>"
# A caller that only checks `|| die`/`|| true` still gets truthful pass/fail;
# a caller that wants the specifics reads BOARD_UNLANDED_ISSUES right after
# the call (before any other board.sh call touches it).
#   board_create_many <board#> <url1> <num1> [<url2> <num2> ...]
board_create_many() {
  local board="$1"; shift
  # Propagates board_backend's non-zero refusal for a stale `backend=projects`
  # conf line (ADR 0004) rather than resolving it silently.
  _board_is_issues_only "$board" || return 2
  _board_issues_create_many "$board" "$@"
  return $?
}

# Single-item convenience wrapper over board_create_many (the capture.sh flow:
# one issue already created repo-side; label it Backlog). Return code and
# BOARD_UNLANDED_ISSUES pass straight through from board_create_many — with a
# single item, "partial" (1) never happens, only 0 (landed) or 2 (didn't).
#   board_create_on_board <board#> <issue-url> <issue#>
board_create_on_board() {
  board_create_many "$1" "$2" "$3"
}

# --- single-item placement -------------------------------------------------
# Place a just-created issue: resolve the ONE issue, then ensure it is in Backlog
# if it isn't already statused. On the issues-only backend the issue always
# resolves on the first attempt (there is no asynchronous board indexing to wait
# on), so the retry loop below is vestigial belt-and-braces rather than the
# Projects-v2 auto-add poll it originally was; it is kept because its fallback to
# board_create_on_board is what guarantees a Backlog label even if the resolve
# itself transiently fails.
#
# RETURN CONTRACT (foundation #1226): same shape as board_create_many, since
# this is itself single-item — return 0 on a landed item, non-zero (2, by
# board_create_many's total-failure convention — see its header comment) on
# one that never landed, and BOARD_UNLANDED_ISSUES carries "<num>" on failure.
# A caller MUST check this return, not assume the old always-0 behavior.
#   board_capture_item <board#> <issue-url> <issue#>
board_capture_item() {
  # NB: 'item_status', not 'status' — 'status' is zsh's read-only alias for $?,
  # and the Claude Code Bash tool sources this adapter under zsh; a 'local status'
  # there dies with "read-only variable: status" (foundation #82).
  local board="$1" url="$2" num="$3" attempt item_id item_status
  for attempt in 1 2 3; do
    board_resolve_item "$board" "$num"
    item_id="$(board_item_id "$num")"
    if [ -n "$item_id" ]; then
      item_status="$(
        printf '%s' "$BOARD_ITEMS_JSON" |
          jq -r --argjson n "$num" '.items[] | select(.content.number==$n) | .status // ""'
      )"
      # Auto-add placed it; land it in Backlog only if it isn't already statused.
      if [ -n "$item_status" ] || board_set_status "$item_id" "$BOARD_OPT_BACKLOG"; then
        BOARD_UNLANDED_ISSUES=""
        return 0
      fi
      BOARD_UNLANDED_ISSUES="$num"
      echo "warning: #$num found on board $board but setting Backlog failed" >&2
      return 2
    fi
    sleep 2
  done
  # Auto-add never indexed the issue — fall back to the explicit add.
  board_create_on_board "$board" "$url" "$num"
}
