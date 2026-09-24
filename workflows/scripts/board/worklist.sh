#!/usr/bin/env bash
#
# Unified, cross-machine worklist: which board item each Claude Code session is
# working, on any machine. Reads the board (GitHub Issues, issues-only backend)
# and prints the In-Progress set with its Host/Session stamp.
#
# The board is the cross-machine source of truth for "what's being worked,
# where" — it's reachable from every machine, so this command answers the
# question identically anywhere (no local state, no tmux dependency). Needs only
# the DEFAULT `repo` gh scope — the read is a plain-REST issue/label list (see
# ISSUES-ONLY-BACKEND.md); no `project` scope is required.
#
# --board selects the board (default 3 = stageFind; 4 = foundation).
#
#   worklist.sh                   # In-Progress items + host/session
#   worklist.sh --all             # every item, grouped by Status
#   worklist.sh --board 4         # the foundation board
#
set -euo pipefail

# Attribution for the gh call-logger shim (F#988): tag every gh call this command
# makes with its outermost context. `:-` preserves an already-set (outer) value,
# so an autonomous driver's context wins over a nested command. See
# workflows/scripts/gh-call-logger.sh.
export GH_CALL_CONTEXT="${GH_CALL_CONTEXT:-worklist}"

# Resolve symlinks so the script finds its real lib/ even when invoked through a
# symlink (on PATH or from a consuming repo's scripts/ dir) — BASH_SOURCE points
# at the symlink, not the real file. Portable (no GNU readlink -f).
src="${BASH_SOURCE[0]}"
while [ -L "$src" ]; do
  dir="$(cd -P "$(dirname "$src")" && pwd)"; src="$(readlink "$src")"
  case "$src" in /*) ;; *) src="$dir/$src" ;; esac
done
SCRIPT_DIR="$(cd -P "$(dirname "$src")" && pwd)"
# shellcheck source=scripts/lib/board.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/board.sh"

# Issue-plane read cache (F#988). board.sh's cached read arms gate on
# `command -v cache_read` and board.sh NEVER sources cache.sh itself — a
# deliberate one-way layering (board.sh:521-526) that keeps reconcile.sh
# permanently on the live arm. So the CALLER must source it, or the axis
# `board.<N>.cache=on` is inert here and every read takes the live path with a
# per-call stderr notice. Guarded on existence: a consuming repo that vendors a
# subset without cache.sh still runs unchanged. Sourcing is side-effect-free
# (three `${VAR:-default}` assignments + function defs), so with the axis off
# this changes nothing. `if` rather than `[ -f … ] && source …` because this
# script is `set -e`: the && form would abort the run when cache.sh is absent.
if [ -f "$SCRIPT_DIR/lib/cache.sh" ]; then
  # shellcheck source=scripts/lib/cache.sh
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/lib/cache.sh"
fi

PROJECT_NUMBER=3
show_all=0
while [ $# -gt 0 ]; do
  case "$1" in
    --all) show_all=1; shift ;;
    --board) PROJECT_NUMBER="$(board_resolve_name "${2:?--board needs a value}")" || exit 2; shift 2 ;;
    *) echo "usage: worklist.sh [--all] [--board 3|4]" >&2; exit 2 ;;
  esac
done

# Single item-list --limit 200 fetch via the board adapter (read-only; no need
# for the field-list/project-view that board_resolve also does).
json=$(board_item_list "$PROJECT_NUMBER")

if [ "$show_all" -eq 1 ]; then
  echo "$json" | jq -r '
    .items
    | group_by(.status // "(no status)")[]
    | "── \(.[0].status // "(no status)") ──",
      ( sort_by(.content.number)[]
        | "  #\(.content.number)  \(.content.title)"
          + ( if (.["host/Session"] // "") != "" then "  [\(.["host/Session"])]" else "" end ) )
  '
else
  # The In-Progress status NAME comes from the board adapter's one constant.
  echo "$json" | jq -r --arg ip_name "$BOARD_OPT_INPROGRESS" '
    [ .items[] | select(.status == $ip_name) ] as $ip
    | if ($ip | length) == 0 then "No items In Progress."
      else ( $ip | sort_by(.content.number)[]
             | "#\(.content.number)  \(.content.title)\n        owner: \(.["host/Session"] // "(unstamped)")" )
      end
  '
fi
