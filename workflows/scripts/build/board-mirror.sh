#!/usr/bin/env bash
#
# build board-mirror entrypoints — the thin shell compositions for the
# steps /build mirrors onto the GitHub Projects board (epic #253, spike
# #245). build.md stays the prose orchestrator; it CALLS these. Each
# subcommand is a pure function of observable board state with a closed
# outcome set, so it moves from prose in build.md to code here — while every
# board read/write stays in the adapter (`board/lib/board.sh`).
#
# Single file, six subcommands (mirroring pr.sh's multi-verb shape): the six
# steps share the symlink-resolve preamble, the board.sh sourcing, and the
# `_board_gh` test seam, so one file keeps that in one place.
#
#   board-mirror.sh ensure-issue --board N --title T [--body B] [--backlink S] \
#                                [--issue N] [--label L]            # 2.5
#   board-mirror.sh ensure-epic  --board N --epic N [--child N[,N...]] # 2.6
#   board-mirror.sh claim-item   --board N --issue N [--epic N]       # 3a
#   board-mirror.sh close-epic   --board N --epic N \
#                                [--allow-open-acceptance]            # 4d-epic
#   board-mirror.sh file-retro   --board N --epic N [--just-closed]   # 4d-retro
#   board-mirror.sh park-epic    --board N --epic N                   # Step-5
#
# CRITICAL: thin composition only. All board STATE read/write goes through the
# adapter — board_resolve_item / board_item_id / board_set_status / board_stamp /
# board_capture_item / board_set_milestone. The only direct `gh` calls are the
# REST sub-issues / issue-create / issue-close / issue-search ops, and they route
# through the adapter's `_board_gh` seam (the SAME seam board_blocked_by_open /
# board_parent_issue / board_active_milestones use). That is GitHub REST, NOT
# Projects-v2 GraphQL, so it never touches the scarce 5,000-pt/hr GraphQL budget,
# and it stays replay-testable through the one seam. There is NO raw `gh project`
# / `updateProjectV2Field` / Projects-v2 GraphQL anywhere in this file.
#
# `board_capture_item` truthfully returns non-zero when an item never lands on
# the board (foundation #1226 — see its and board_create_many's header
# comments in lib/board.sh for the full return contract). Every call site
# below already wraps it in `|| die` or a deliberate `|| true`; that wrapping
# is now load-bearing rather than dead code — `die` genuinely fires on a real
# landing failure instead of being unreachable behind an always-0 return.
#
# Output contract — one structured JSON line per outcome (the orchestrator
# branches on `.outcome`, never parses prose). ERROR + non-zero on bad input /
# adapter failure; a contention HALT (3a) is also non-zero.
set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo '{"outcome":"ERROR","error":"jq not found"}'; exit 1; }

# Resolve symlinks so the script finds its real board/lib/board.sh even when
# invoked through a symlink on PATH (portable — no GNU readlink -f). Mirrors
# claim.sh / capture.sh.
src="${BASH_SOURCE[0]}"
while [ -L "$src" ]; do
  dir="$(cd -P "$(dirname "$src")" && pwd)"; src="$(readlink "$src")"
  case "$src" in /*) ;; *) src="$dir/$src" ;; esac
done
SCRIPT_DIR="$(cd -P "$(dirname "$src")" && pwd)"
# The board toolkit lives a sibling dir over: build/ -> board/lib/board.sh.
# shellcheck source=../board/lib/board.sh
source "$SCRIPT_DIR/../board/lib/board.sh"

# Issue-plane read cache (F#988 / temperloop#1118). #1118 deliberately did NOT
# wire this script, on the reasoning that it called only board_resolve_item —
# the always-live single-item arm — so sourcing cache.sh here would be inert.
# That reasoning is invalidated by temperloop#1119 (this change): the sub-issue
# read helpers below now call board_sub_issues, which DOES have a cached arm and
# gates it on `command -v cache_read` in the calling process. Without this line
# the routing above would buy nothing and would emit one fallback notice per
# read. Guarded on existence and `if`-form (this script is set -e) for the same
# reasons as #1118's two sites.
if [ -f "$SCRIPT_DIR/../board/lib/cache.sh" ]; then
  # shellcheck source=../board/lib/cache.sh
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/../board/lib/cache.sh"
fi

# fd 3 = the script's real stdout, so a die() inside a command substitution
# still reaches the orchestrator (same seam as ci-poll.sh / pr.sh).
exec 3>&1
die() {
  jq -cn --arg error "$1" '{outcome:"ERROR", error:$error}' >&3
  exit 1
}

usage() {
  die "usage: board-mirror.sh {ensure-issue|ensure-epic|claim-item|close-epic|file-retro|park-epic} --board N ... (see header)"
}

# Closed-set validators (these feed gh paths / jq --argjson).
validate_board() {
  board_repo "$1" >/dev/null 2>&1 || die "board '$1' unknown — must be a known board number"
}
validate_num() {
  case "$2" in
    ""|*[!0-9]*) die "$1 '$2' invalid — must be a positive integer" ;;
  esac
}

# --- sub-issue READ helpers (routed through the board adapter) ----------------
# These now delegate to board_sub_issues rather than calling the REST endpoint
# directly (temperloop#1119). The prior comment justified keeping them local as
# "build-mirror-specific composition, not general board adapter surface" — true
# of their SHAPE, but the effect was that every relationship read in production
# bypassed board.sh's cached arm (#1030), leaving the F#988 epic's heaviest
# measured class (rel_loop, 4.1s p50 / 12.6s total) uncached in the one place it
# actually ran. The composition stays local; only the read is delegated.
#
# They take a BOARD id now, not a repo — board_sub_issues resolves the repo
# itself via board_repo. Both call sites already have $board in scope.
#
# The WRITE path below (_subissue_link) now routes through the adapter too
# (temperloop#1188, re-cut from foundation#1287): board_add_sub_issue /
# board_remove_sub_issue closed the last raw-gh-api sub-issue mutation hole,
# so this composition delegates rather than building its own POST.

# List a parent issue's child sub-issue NUMBERS, one per line (empty = none).
_subissue_children() {
  local board="$1" epic="$2"
  board_sub_issues "$board" "$epic"
}

# Count a parent issue's still-OPEN children (data-driven, NOT "plan finished").
# `wc -l` rather than `grep -c .`: grep exits 1 on zero matches, which would
# trip this script's errexit on the legitimate "epic fully drained" case.
_subissue_open_children() {
  local board="$1" epic="$2"
  board_sub_issues "$board" "$epic" open | wc -l | tr -d '[:space:]'
}

# temperloop#458: count UNCHECKED acceptance/verification checkboxes in an epic's
# BODY — work-bearing acceptance written as prose (never split into its own
# sub-issue) that the open-children count alone cannot see, and which would
# otherwise vanish silently when the last child closes. Scans only sections whose
# heading matches /accept|verif/i, and IGNORES bare `#N` / `owner/repo#N`
# child-reference checkboxes (those are tracked by the sub-issue state count, not
# by body prose). Prints an integer count (0 = none / no acceptance section).
_epic_body_open_acceptance() {
  local repo="$1" epic="$2"
  _board_gh api "repos/$repo/issues/$epic" --jq '.body // ""' 2>/dev/null |
    tr -d '\r' |
    awk '
      /^[[:space:]]*#+[[:space:]]+/ {
        h = tolower($0)
        in_acc = (h ~ /accept|verif/) ? 1 : 0
        next
      }
      in_acc && /^[[:space:]]*[-*+][[:space:]]+\[ \]/ {
        line = $0
        sub(/^[[:space:]]*[-*+][[:space:]]+\[ \][[:space:]]*/, "", line)
        gsub(/[[:space:]]+$/, "", line)
        if (line ~ /^#?[0-9]+$/) next                        # bare "123" / "#123"
        if (line ~ /^[A-Za-z0-9._\/-]+#[0-9]+$/) next        # "owner/repo#123"
        n++
      }
      END { print n + 0 }
    '
}

# Link a child issue under a parent as a native sub-issue. Delegates to the
# adapter's board_add_sub_issue (temperloop#1188), which resolves the child's
# database id and busts the issue-cache entry on success. Idempotent at the
# caller (we skip already-linked children before calling this).
_subissue_link() {
  local board="$1" epic="$2" child_num="$3"
  board_add_sub_issue "$board" "$epic" "$child_num" >/dev/null 2>&1
}

# --- 2.5: ensure a worked item has a tracking issue ON the board ---------------
# Idempotent via a unique back-link string probed in issue BODIES (in:body, NOT
# in:title). If an issue already carries the back-link, reuse it; else create it
# (repo-level gh issue create) and land it on the board via board_capture_item
# (auto-add-aware, single-item — never the whole-board resolve). --issue pins an
# already-known tracking issue (skip the search), --label tags it on create.
#   ISSUE_EXISTS  — back-link found / --issue given; reused, already on board
#   ISSUE_CREATED — created + landed in Backlog
cmd_ensure_issue() {
  local board="" title="" body="" backlink="" issue="" label="" repo url num
  while [ $# -gt 0 ]; do
    case "$1" in
      --board)    [ $# -ge 2 ] || usage; board="$2"; shift ;;
      --title)    [ $# -ge 2 ] || usage; title="$2"; shift ;;
      --body)     [ $# -ge 2 ] || usage; body="$2"; shift ;;
      --backlink) [ $# -ge 2 ] || usage; backlink="$2"; shift ;;
      --issue)    [ $# -ge 2 ] || usage; issue="$2"; shift ;;
      --label)    [ $# -ge 2 ] || usage; label="$2"; shift ;;
      *) usage ;;
    esac
    shift
  done
  validate_board "$board"
  repo="$(board_repo "$board")"

  # Already-known tracking issue: ensure it's on the board, no create.
  if [ -n "$issue" ]; then
    validate_num "--issue" "$issue"
    board_resolve_item "$board" "$issue" || die "could not resolve issue #$issue on board $board"
    if [ -z "$(board_item_id "$issue")" ]; then
      url="$(_board_gh api "repos/$repo/issues/$issue" --jq '.html_url' 2>/dev/null)" \
        || die "could not resolve URL for #$issue"
      board_capture_item "$board" "$url" "$issue" || die "could not land #$issue on board $board"
    fi
    jq -cn --argjson n "$issue" '{outcome:"ISSUE_EXISTS", issue:$n}'
    return 0
  fi

  [ -n "$title" ]    || die "ensure-issue requires --title (or --issue)"
  [ -n "$backlink" ] || die "ensure-issue requires --backlink (the unique idempotency probe string)"

  # Probe-before-create: search issue BODIES for the unique back-link (in:body,
  # never in:title — the back-link lives in the body). A hit means a prior run
  # already filed this item; reuse it.
  num="$(
    _board_gh api -X GET search/issues \
      -f q="repo:$repo in:body \"$backlink\"" --jq '.items[0].number // empty' 2>/dev/null
  )" || num=""
  if [ -n "$num" ]; then
    board_resolve_item "$board" "$num" >/dev/null 2>&1 || true
    if [ -z "$(board_item_id "$num")" ]; then
      url="$(_board_gh api "repos/$repo/issues/$num" --jq '.html_url' 2>/dev/null)" || url=""
      # Deliberate `|| true`, not an oversight: the issue was already found via
      # the back-link probe (ISSUE_EXISTS below is correct regardless), so a
      # board-landing failure here is best-effort placement, not a creation
      # failure worth dying over — the outcome this branch reports doesn't
      # change either way.
      if [ -n "$url" ]; then board_capture_item "$board" "$url" "$num" || true; fi
    fi
    jq -cn --argjson n "$num" '{outcome:"ISSUE_EXISTS", issue:$n}'
    return 0
  fi

  # Create — embed the back-link in the body so the next run's probe finds it.
  [ -n "$body" ] || body="Tracking issue filed by /build board-mirror."
  body="$body"$'\n\n'"$backlink"
  local create_args
  create_args=(issue create -R "$repo" --title "$title" --body "$body")
  [ -n "$label" ] && create_args+=(--label "$label")
  url="$(_board_gh "${create_args[@]}")" || die "gh issue create failed"
  num="$(basename "$url")"
  validate_num "created-issue" "$num"
  board_capture_item "$board" "$url" "$num" || die "created #$num but could not land it on board $board"
  jq -cn --argjson n "$num" --arg url "$url" '{outcome:"ISSUE_CREATED", issue:$n, url:$url}'
}

# --- 2.6: ensure the parent epic exists + link each per-item issue as a child --
# Idempotent on the plan's epic: the epic must already exist (we do NOT create
# it here — the plan carries its number); we link each --child that is not
# ALREADY a sub-issue, and warn-and-continue on any single linkage failure (one
# bad child never aborts the rest). A re-run links nothing (all already children).
#   EPIC_LINKED — {linked:[…newly linked…], skipped:[…already children…], failed:[…]}
cmd_ensure_epic() {
  local board="" epic="" children_csv="" repo
  while [ $# -gt 0 ]; do
    case "$1" in
      --board) [ $# -ge 2 ] || usage; board="$2"; shift ;;
      --epic)  [ $# -ge 2 ] || usage; epic="$2"; shift ;;
      --child) [ $# -ge 2 ] || usage; children_csv="$2"; shift ;;
      *) usage ;;
    esac
    shift
  done
  validate_board "$board"
  validate_num "--epic" "$epic"
  repo="$(board_repo "$board")"
  # Epic must exist (the plan's epic:). Probe it; a missing epic is a hard error
  # (the orchestrator created it at decomposition time — its absence is a bug).
  _board_gh api "repos/$repo/issues/$epic" --jq '.number' >/dev/null 2>&1 \
    || die "epic #$epic not found in $repo — ensure-epic does not create it"

  # Existing children: skip these (idempotency for already-linked).
  local existing
  existing="$(_subissue_children "$board" "$epic" | tr '\n' ' ')"

  local children linked=() skipped=() failed=() c
  children="$(printf '%s' "$children_csv" | tr ',' ' ')"
  for c in $children; do
    validate_num "--child" "$c"
    if [[ " $existing " == *" $c "* ]]; then
      skipped+=("$c")
      continue
    fi
    if _subissue_link "$board" "$epic" "$c"; then
      linked+=("$c")
      existing="$existing $c"   # so a duplicate in the same --child list is skipped
    else
      # warn-and-continue: a single linkage failure never aborts the batch.
      echo "warning: could not link #$c under epic #$epic (continuing)" >&2
      failed+=("$c")
    fi
  done

  jq -cn --argjson epic "$epic" \
    --argjson linked  "$(printf '%s\n' "${linked[@]:-}"  | jq -R 'select(.!="")|tonumber' | jq -cs .)" \
    --argjson skipped "$(printf '%s\n' "${skipped[@]:-}" | jq -R 'select(.!="")|tonumber' | jq -cs .)" \
    --argjson failed  "$(printf '%s\n' "${failed[@]:-}"  | jq -R 'select(.!="")|tonumber' | jq -cs .)" \
    '{outcome:"EPIC_LINKED", epic:$epic, linked:$linked, skipped:$skipped, failed:$failed}'
}

# --- 3a: claim an item In Progress (claim-first) + epic In Progress on first claim
# Contention pre-check: resolve the item LIVE; if it is ALREADY In Progress under
# a DIFFERENT Host/Session stamp, HALT (non-zero) — a second session owns it. If
# it is In Progress under OUR stamp, or unclaimed, proceed: delegate the actual
# claim (stamp-then-flip ordering) to claim.sh, then move the epic -> In Progress
# and stamp it on this first claim (idempotent: a no-op if the epic is already In
# Progress). Our stamp = "<host>:<sess8>" (same shape claim.sh writes).
#   CLAIMED   — {issue, epic_moved:bool}
#   CONTENDED — {issue, owner} + non-zero exit (a different live session owns it)
cmd_claim_item() {
  local board="" issue="" epic="" repo our_host our_sess our_stamp
  while [ $# -gt 0 ]; do
    case "$1" in
      --board) [ $# -ge 2 ] || usage; board="$2"; shift ;;
      --issue) [ $# -ge 2 ] || usage; issue="$2"; shift ;;
      --epic)  [ $# -ge 2 ] || usage; epic="$2"; shift ;;
      *) usage ;;
    esac
    shift
  done
  validate_board "$board"
  validate_num "--issue" "$issue"
  [ -z "$epic" ] || validate_num "--epic" "$epic"
  repo="$(board_repo "$board")"

  # our_host/our_sess feed claim.sh's environment below; the stamp itself comes
  # from the board.sh owner (board_own_stamp, temperloop#1220/#1823) — never
  # re-derived here — so the pre-check compares the exact string claim.sh writes.
  our_host="$(board_host_label)"
  our_sess="${CLAUDE_CODE_SESSION_ID:-}"
  our_stamp="$(board_own_stamp)"

  # Contention pre-check — resolve the ONE item live (single-item, never the
  # whole board), read its Status + Host/Session stamp.
  board_resolve_item "$board" "$issue" || die "could not resolve #$issue on board $board"
  [ -n "$(board_item_id "$issue")" ] || die "#$issue is not on board $board"
  local cur_status cur_stamp
  cur_status="$(printf '%s' "$BOARD_ITEMS_JSON" |
    jq -r --argjson n "$issue" '.items[] | select(.content.number==$n) | .status // ""')"
  cur_stamp="$(printf '%s' "$BOARD_ITEMS_JSON" |
    jq -r --argjson n "$issue" '.items[] | select(.content.number==$n) | .["host/Session"] // ""')"
  if [ "$cur_status" = "$BOARD_OPT_INPROGRESS" ] && [ -n "$cur_stamp" ] && [ "$cur_stamp" != "$our_stamp" ]; then
    jq -cn --argjson n "$issue" --arg owner "$cur_stamp" \
      '{outcome:"CONTENDED", issue:$n, owner:$owner}'
    exit 1
  fi

  # Delegate the actual claim to the claim.sh entrypoint (stamp-first, flip-last
  # ordering — the #135 lock-safety property lives there; we don't re-implement
  # it). Run it through this script's own dir resolution.
  CLAUDE_CODE_SESSION_ID="${our_sess}" SUBSET_HOST_LABEL="${our_host}" \
    bash "$SCRIPT_DIR/../board/claim.sh" "$issue" --board "$board" >/dev/null \
    || die "claim.sh failed for #$issue on board $board"

  # Move the epic -> In Progress + stamp it on first claim. Idempotent: skip the
  # whole block when the epic is already In Progress under any owner.
  local epic_moved=false
  if [ -n "$epic" ]; then
    board_resolve_item "$board" "$epic" || die "could not resolve epic #$epic"
    local epic_item epic_status
    epic_item="$(board_item_id "$epic")"
    [ -n "$epic_item" ] || die "epic #$epic is not on board $board"
    epic_status="$(printf '%s' "$BOARD_ITEMS_JSON" |
      jq -r --argjson n "$epic" '.items[] | select(.content.number==$n) | .status // ""')"
    if [ "$epic_status" != "$BOARD_OPT_INPROGRESS" ]; then
      board_stamp "$epic_item" "$BOARD_FIELD_HOSTSESSION" "$our_stamp" \
        || die "could not stamp epic #$epic"
      board_set_status "$epic_item" "$BOARD_OPT_INPROGRESS" \
        || die "could not move epic #$epic to In Progress"
      epic_moved=true
    fi
  fi
  jq -cn --argjson n "$issue" --argjson moved "$epic_moved" \
    '{outcome:"CLAIMED", issue:$n, epic_moved:$moved}'
}

# --- 4d-epic: close the epic when its open-children count hits 0 ----------------
# DATA-DRIVEN: closes iff the sub-issues API reports zero OPEN children — NOT
# "the plan finished". Idempotent: a no-op (EPIC_ALREADY_CLOSED) if the epic is
# already closed; EPIC_OPEN_CHILDREN (no close) while any child is still open.
# temperloop#458: even with zero open children, REFUSE to close while the epic
# BODY still carries unchecked acceptance/verification checkboxes — work-bearing
# acceptance left as prose (never materialized as a sub-issue) would otherwise
# vanish silently on the last child's close. --allow-open-acceptance is the
# explicit operator override that closes anyway.
#   EPIC_CLOSED           — closed now (open children == 0, acceptance clear or
#                           overridden; {acceptance_override:true} when the
#                           override forced past open acceptance boxes)
#   EPIC_ALREADY_CLOSED   — already closed, no-op
#   EPIC_OPEN_CHILDREN    — {open:N} still-open children, not closed
#   EPIC_ACCEPTANCE_OPEN  — {acceptance_open:N} children drained but N unchecked
#                           body acceptance/verification boxes remain, not closed
cmd_close_epic() {
  local board="" epic="" allow_open_acceptance="" repo state open acc_open acc_override
  while [ $# -gt 0 ]; do
    case "$1" in
      --board) [ $# -ge 2 ] || usage; board="$2"; shift ;;
      --epic)  [ $# -ge 2 ] || usage; epic="$2"; shift ;;
      --allow-open-acceptance) allow_open_acceptance=1 ;;
      *) usage ;;
    esac
    shift
  done
  validate_board "$board"
  validate_num "--epic" "$epic"
  repo="$(board_repo "$board")"

  state="$(_board_gh api "repos/$repo/issues/$epic" --jq '.state' 2>/dev/null)" \
    || die "could not read epic #$epic state in $repo"
  if [ "$state" = "closed" ]; then
    jq -cn --argjson n "$epic" '{outcome:"EPIC_ALREADY_CLOSED", epic:$n}'
    return 0
  fi
  open="$(_subissue_open_children "$board" "$epic")"
  case "$open" in ""|*[!0-9]*) die "could not count open children of epic #$epic" ;; esac
  if [ "$open" -gt 0 ]; then
    jq -cn --argjson n "$epic" --argjson open "$open" \
      '{outcome:"EPIC_OPEN_CHILDREN", epic:$n, open:$open}'
    return 0
  fi
  # temperloop#458: body-acceptance guard (skipped by the explicit override).
  if [ -n "$allow_open_acceptance" ]; then
    acc_override=true
  else
    acc_open="$(_epic_body_open_acceptance "$repo" "$epic")"
    case "$acc_open" in ""|*[!0-9]*) acc_open=0 ;; esac
    if [ "$acc_open" -gt 0 ]; then
      jq -cn --argjson n "$epic" --argjson a "$acc_open" \
        '{outcome:"EPIC_ACCEPTANCE_OPEN", epic:$n, acceptance_open:$a}'
      return 0
    fi
    acc_override=false
  fi
  _board_gh issue close "$epic" -R "$repo" >/dev/null 2>&1 \
    || die "gh issue close failed for epic #$epic"
  # The board's close->Done cascade moves the card; we do not set Done by hand.
  jq -cn --argjson n "$epic" --argjson ov "$acc_override" \
    '{outcome:"EPIC_CLOSED", epic:$n} + (if $ov then {acceptance_override:true} else {} end)'
}

# --- 4d-retro: file exactly ONE spike-labelled process-retro issue -------------
# Fires only when 4d-epic JUST closed the epic (--just-closed). Idempotent via a
# body-marker probe `Retro-for-epic: #<epic>` searched in:body (NOT in:title): if
# a retro already carries the marker, no second one is filed. Files into Backlog
# via capture.sh with --label spike. Without --just-closed it is an explicit
# no-op (RETRO_SKIPPED) — the orchestrator only passes it on a fresh close.
#   RETRO_FILED   — filed a new retro issue {retro:N}
#   RETRO_EXISTS  — a retro for this epic already exists, no-op
#   RETRO_SKIPPED — --just-closed not set (epic was not just closed)
cmd_file_retro() {
  local board="" epic="" just_closed="" repo marker existing
  while [ $# -gt 0 ]; do
    case "$1" in
      --board)       [ $# -ge 2 ] || usage; board="$2"; shift ;;
      --epic)        [ $# -ge 2 ] || usage; epic="$2"; shift ;;
      --just-closed) just_closed=1 ;;
      *) usage ;;
    esac
    shift
  done
  validate_board "$board"
  validate_num "--epic" "$epic"
  repo="$(board_repo "$board")"
  marker="Retro-for-epic: #${epic}"

  if [ -z "$just_closed" ]; then
    jq -cn --argjson n "$epic" '{outcome:"RETRO_SKIPPED", epic:$n}'
    return 0
  fi

  # Idempotency probe: a retro carrying the marker in its BODY already exists.
  existing="$(
    _board_gh api -X GET search/issues \
      -f q="repo:$repo in:body \"$marker\"" --jq '.items[0].number // empty' 2>/dev/null
  )" || existing=""
  if [ -n "$existing" ]; then
    jq -cn --argjson n "$epic" --argjson retro "$existing" \
      '{outcome:"RETRO_EXISTS", epic:$n, retro:$retro}'
    return 0
  fi

  # File via capture.sh (Backlog, spike label). The marker rides the body so the
  # next run's probe finds it. capture.sh prints "Captured <url> ... (#<num>)".
  local title body out num
  title="Process retro: epic #${epic}"
  body="Process-retrospective spike for epic #${epic}, filed by /build on epic close."$'\n\n'"${marker}"
  out="$(bash "$SCRIPT_DIR/../board/capture.sh" "$title" \
    --body "$body" --label spike --board "$board")" \
    || die "capture.sh failed to file the retro for epic #$epic"
  num="$(grep -oE '#[0-9]+' <<<"$out" | tail -1 | tr -d '#')"
  validate_num "retro-issue" "$num"
  jq -cn --argjson n "$epic" --argjson retro "$num" \
    '{outcome:"RETRO_FILED", epic:$n, retro:$retro}'
}

# --- Step-5 park-back: move a still-open epic THIS run owns -> Ready ------------
# Park-don't-abandon: at end-of-run, an epic that is still OPEN and whose
# Host/Session stamp matches THIS run's stamp is moved Ready and its stamp
# cleared (un-owned). Only un-owns what THIS run stamped: a DIFFERENT live
# session's stamp is left untouched (PARK_FOREIGN, no-op). A closed epic, or one
# already not In Progress, is skipped (PARK_SKIPPED — nothing to park).
#   EPIC_PARKED   — moved to Ready + stamp cleared
#   PARK_FOREIGN  — In Progress under a DIFFERENT session's stamp, untouched
#   PARK_SKIPPED  — closed, or not In Progress (nothing to park)
cmd_park_epic() {
  local board="" epic="" repo our_stamp
  while [ $# -gt 0 ]; do
    case "$1" in
      --board) [ $# -ge 2 ] || usage; board="$2"; shift ;;
      --epic)  [ $# -ge 2 ] || usage; epic="$2"; shift ;;
      *) usage ;;
    esac
    shift
  done
  validate_board "$board"
  validate_num "--epic" "$epic"
  repo="$(board_repo "$board")"

  # Own stamp via the board.sh owner (temperloop#1220/#1823) — never re-derived.
  our_stamp="$(board_own_stamp)"

  local state
  state="$(_board_gh api "repos/$repo/issues/$epic" --jq '.state' 2>/dev/null)" \
    || die "could not read epic #$epic state in $repo"
  if [ "$state" = "closed" ]; then
    jq -cn --argjson n "$epic" '{outcome:"PARK_SKIPPED", epic:$n, reason:"closed"}'
    return 0
  fi

  board_resolve_item "$board" "$epic" || die "could not resolve epic #$epic"
  local epic_item epic_status epic_stamp
  epic_item="$(board_item_id "$epic")"
  [ -n "$epic_item" ] || die "epic #$epic is not on board $board"
  epic_status="$(printf '%s' "$BOARD_ITEMS_JSON" |
    jq -r --argjson n "$epic" '.items[] | select(.content.number==$n) | .status // ""')"
  epic_stamp="$(printf '%s' "$BOARD_ITEMS_JSON" |
    jq -r --argjson n "$epic" '.items[] | select(.content.number==$n) | .["host/Session"] // ""')"

  if [ "$epic_status" != "$BOARD_OPT_INPROGRESS" ]; then
    jq -cn --argjson n "$epic" '{outcome:"PARK_SKIPPED", epic:$n, reason:"not-in-progress"}'
    return 0
  fi
  # Only un-own what THIS run stamped — never clear a different live session.
  if [ -n "$epic_stamp" ] && [ "$epic_stamp" != "$our_stamp" ]; then
    jq -cn --argjson n "$epic" --arg owner "$epic_stamp" \
      '{outcome:"PARK_FOREIGN", epic:$n, owner:$owner}'
    return 0
  fi

  board_set_status "$epic_item" "$BOARD_OPT_READY" || die "could not move epic #$epic to Ready"
  # Clear the stamp (board_stamp with empty text routes through --clear).
  board_stamp "$epic_item" "$BOARD_FIELD_HOSTSESSION" "" || die "could not clear epic #$epic stamp"
  jq -cn --argjson n "$epic" '{outcome:"EPIC_PARKED", epic:$n}'
}

[ $# -ge 1 ] || usage
cmd="$1"; shift
case "$cmd" in
  ensure-issue) cmd_ensure_issue "$@" ;;
  ensure-epic)  cmd_ensure_epic  "$@" ;;
  claim-item)   cmd_claim_item   "$@" ;;
  close-epic)   cmd_close_epic   "$@" ;;
  file-retro)   cmd_file_retro   "$@" ;;
  park-epic)    cmd_park_epic    "$@" ;;
  *) usage ;;
esac
