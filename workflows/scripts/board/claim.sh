#!/usr/bin/env bash
#
# Claim a board item as the FIRST action when starting work on it: mark it
# In Progress and stamp the Host/Session field so other machines can see which
# session owns it.
#
# Why first: the board (GitHub Issues, issues-only backend) acts as a distributed
# lock across concurrent Claude Code sessions. A slow claim opens a race window
# where a second session reads the item as still-Ready and double-pulls it.
# Claiming as the first action shrinks that window to zero. `worklist.sh` reads
# the board back for the unified cross-machine view. Needs only the DEFAULT `repo`
# gh scope — status and the claim stamp are `fnd:`-namespaced labels written over
# plain REST (see ISSUES-ONLY-BACKEND.md); no `project` scope is required.
#
# --board selects the board (default 3 = stageFind; 4 = foundation).
#
#   claim.sh 227               # claim issue #227 on the default board (3)
#   claim.sh '#227'            # leading # is fine
#   claim.sh 12 --board 4      # claim issue #12 on the foundation board
#
set -euo pipefail

# Attribution for the gh call-logger shim (F#988): tag every gh call this command
# makes with its outermost context. `:-` preserves an already-set (outer) value,
# so an autonomous driver's context wins over a nested command. See
# workflows/scripts/gh-call-logger.sh.
export GH_CALL_CONTEXT="${GH_CALL_CONTEXT:-claim}"

# Resolve symlinks so the script finds its real lib/ even when invoked through a
# symlink (on PATH or from a consuming repo's scripts/ dir) — BASH_SOURCE points
# at the symlink, not the real file. Portable (no GNU readlink -f).
src="${BASH_SOURCE[0]}"
while [ -L "$src" ]; do
  dir="$(cd -P "$(dirname "$src")" && pwd)"; src="$(readlink "$src")"
  case "$src" in /*) ;; *) src="$dir/$src" ;; esac
done
SCRIPT_DIR="$(cd -P "$(dirname "$src")" && pwd)"
# shellcheck source=scripts/lib/claim_marker.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/claim_marker.sh"
# shellcheck source=scripts/lib/board.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/board.sh"
# shellcheck source=scripts/lib/raw_lake.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/raw_lake.sh"

# Module-level state, set by the execute-guard (direct run) or by a sourcing test
# before it calls claim_main. Defaults match the historical CLI (board 3).
PROJECT_NUMBER=3
issue=""

# Canonical default sink for the append-only claims log (F#728) — computed ONCE as
# a module constant, never re-literal'd at the call site. CHECKOUT-RELATIVE
# (temperloop#1822): the lake of the checkout THIS script file lives in, so the
# writer and that same checkout's own readers (telemetry-brief.sh's
# `$raw_root/meta/data/raw`) resolve the SAME directory with no env set. The
# old `$HOME/dev/foundation` absolute pin made every non-foundation checkout's
# reader see zero claims — and grew a phantom `~/dev/foundation/` tree on
# hosts that never cloned foundation (the stranger-test tail of #1822).
# Resolution is DELEGATED to lib/raw_lake.sh's raw_lake_dir() — the single
# owner of this path (temperloop#1902), sourced above. It resolves the git
# toplevel of the library's own resolved dir rather than a fixed `../..` hop,
# because the board scripts are vendored at DIFFERENT depths in consuming
# checkouts (workflows/scripts/board/ in the kernel/foundation layout,
# scripts/ in stageFind's synced copy) and the symlink resolution above
# already pinned SCRIPT_DIR — and hence the sourced library — to the real
# file, so an installed-on-PATH symlink still resolves its SOURCE checkout's
# lake. The old absolute literal survives only inside raw_lake_dir(), as the
# last-resort fallback for a copy living outside any git checkout — the same
# fallback literal telemetry-brief.sh's own raw_root uses. CLAIMS_RAW_DIR
# overrides it (tests only). Which checkout's lake a claim lands in therefore follows which
# checkout's claim.sh ran — cross-checkout aggregation, where wanted, is a
# reader-side union (meta/data/raw/README.md), no longer a writer-side pin.
# canonical sink spec: meta/data/raw/README.md (lake path + schema-version
# convention; this stream's record shape is documented at claim_log_emit below).
CLAIMS_RAW_DIR_DEFAULT="$(raw_lake_dir)"

# Append one JSONL record of this claim to the durable session↔issue join key the
# cost model needs (F#728). The board's Host/Session field is OVERWRITTEN by every
# subsequent claim (transient — no history), so it can't answer "which session
# claimed issue N, and when" after the fact; this log can. Sink: the
# checkout-relative CLAIMS_RAW_DIR_DEFAULT above (override via CLAIMS_RAW_DIR, tests
# only), file `claims-YYYY-MM.jsonl` (monthly rotation, matching the other raw-lake
# streams). PER-CHECKOUT since temperloop#1822 (which superseded the earlier
# all-boards-in-foundation's-lake pin): a claim lands in the lake of the
# checkout whose claim.sh ran, and cross-board/cross-checkout cost attribution
# is a reader-side union of lakes, not a writer-side pin.
# COVERAGE CAVEAT: meta/data/raw/ is gitignored and per-host/per-checkout, so this
# captures only work claimed through THIS checkout's script; claims made on another
# machine or checkout never reach this file until an ingest unions the raw lakes.
#
# session_id is the RAW, FULL `$CLAUDE_CODE_SESSION_ID` UUID — NOT the truncated
# `host:sess8` board stamp computed above for `stamp`. The cost rollup joins on
# session_id[:8] against the run-status footer's 8-char id; emitting the
# host-prefixed stamp here would join as `mini:c33` garbage and silently break
# attribution. `$sess` (set above, before the stamp is derived from it) already IS
# that raw id — reuse it verbatim, do not re-derive from `$stamp`.
#
# `|| true`-isolated at the call site from claim.sh's `set -e`: this is telemetry,
# never allowed to affect the lock's stamp-then-flip safety ordering (#103/#135).
# A missing/uncreatable sink dir WARNS to stderr and returns — the claim itself
# (already committed via the two board writes above) is never dropped or aborted.
claim_log_emit() {  # $1=item_id
  local dir file ts rec
  dir="${CLAIMS_RAW_DIR:-$CLAIMS_RAW_DIR_DEFAULT}"
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  file="$dir/claims-${ts%-*}.jsonl"   # ts%-* strips DDThh:mm:ssZ, leaving YYYY-MM
  if ! mkdir -p "$dir" 2>/dev/null; then
    echo "claim.sh: WARN claims log dir unavailable: $dir (claim recorded on the board; NOT logged to the raw lake)" >&2
    return 0
  fi
  rec=$(printf '{"ts":"%s","host":"%s","session_id":"%s","board":%s,"issue":%s,"item_id":"%s"}' \
    "$ts" "$host" "$sess" "$PROJECT_NUMBER" "$issue" "$1")
  printf '%s\n' "$rec" >>"$file" 2>/dev/null \
    || echo "claim.sh: WARN failed to append claims log record to $file (claim itself still succeeded)" >&2
}

# The whole claim, wrapped so a test can source this file (the execute-guard at
# the bottom suppresses the auto-run when sourced), set $issue / $PROJECT_NUMBER,
# override the board.sh `_board_gh` seam (or board_resolve_item) with canned data,
# and drive claim_main with zero network. Reads the two module vars above.
claim_main() {
  # Resolve project + fields + THIS issue's item by name (robust to field
  # re-creation). board_resolve_item issues a single project view + field-list +
  # one targeted GraphQL lookup for this issue's project item — skipping the
  # whole-board `item-list --limit 200` page that drained the Projects-v2 budget
  # when claim ran in a burst (GH #53). Same globals/accessors as board_resolve.
  board_resolve_item "$PROJECT_NUMBER" "$issue"

  local item_id issue_title host sess stamp
  # Every registered board runs the issues-only backend (temperloop#524's
  # 2026-08-04 addendum — 10 releases of soak past ADR 0004): status/stamp
  # writes drive entirely through fnd: labels inside board_set_status/
  # board_stamp themselves, so there is no Projects-v2 field/option schema to
  # pre-resolve or gate on here (a caller-side removal — lib/board.sh's
  # board_field_id/board_option_id accessors are untouched, just unused by
  # this script now).

  # Resolve the project item id (and title, for the tmux window name) for this issue.
  item_id=$(board_item_id "$issue")
  issue_title=$(board_item_title "$issue")
  [ -n "$item_id" ] || { echo "issue #$issue is not on project $PROJECT_NUMBER" >&2; return 1; }

  # `host` / `sess` stay set for claim_log_emit below, which reads them from this
  # frame (the raw full session UUID, NOT the truncated stamp — see its header).
  host="$(board_host_label)"
  sess="${CLAUDE_CODE_SESSION_ID:-}"
  # The `<host>:<sess8>` STAMP format is owned by board_own_stamp (lib/board.sh),
  # the single derivation site — claim-guard.sh reads the stamp back to decide
  # "is this claim mine?", and a second inline copy here is exactly how the
  # writer and the reader come to disagree (temperloop#1220).
  stamp="$(board_own_stamp)"

  # Cross-session lock contention pre-check (foundation #800, extended to the
  # Projects-v2 arm): refuses a claim already held by a DIFFERENT host:session
  # stamp, on EITHER backend — the item is already resolved above (via
  # board_resolve_item), so this is one more jq read against the warm
  # BOARD_ITEMS_JSON, no extra `gh`/GraphQL call. See board_claim_contended's
  # own header comment for exactly what does/does not count as contended
  # (self-reclaim and half-claim adoption are both safe).
  local foreign_stamp
  if foreign_stamp="$(board_claim_contended "$PROJECT_NUMBER" "$issue" "$stamp")"; then
    echo "claim refused: #$issue is already In Progress, claimed by [$foreign_stamp] — verify there (or via reconcile.sh) before taking it." >&2
    return 1
  fi

  # The claim is two board writes, and their ORDER is the lock's safety property:
  # stamp the owner FIRST, flip the In-Progress status LAST. The status flip is
  # the lock — the one observable, contended commit; everything else is metadata.
  # Under `set -e` a failed write aborts, so by committing the lock last, any
  # failure (rate-limit, GraphQL blip) leaves the item in a SAFE state:
  #   - stamp fails  → status never flipped → item stays Ready / un-claimed (no
  #                    phantom lock; the exact #103 failure this ordering fixes).
  #   - status fails → item still Ready, merely carrying an owner stamp — harmless
  #                    (worklist.sh shows In-Progress only) and overwritten by the
  #                    next claim.
  # Do NOT reorder these: flipping status before the stamp re-introduces the
  # ownerless In-Progress lock (GH #135). Stamping while still Ready is safe — the
  # Host/Session field is pure metadata until the status flip makes it a claim.

  # 1) Stamp Host/Session (owner metadata) — safe to write while still Ready.
  board_stamp "$item_id" "$BOARD_FIELD_HOSTSESSION" "$stamp"

  # 2) Flip In Progress — the claim-first lock; the atomic commit, done LAST.
  board_set_status "$item_id" "$BOARD_OPT_INPROGRESS"

  # STDERR, never stdout (temperloop#2232). This is a human progress line, and
  # claim.sh is invoked INSIDE build-level.mjs's prelude batch, whose stdout is
  # parsed as a stream of JSON result lines by the machinery-executor relay.
  # Printed on stdout, this prose sat adjacent to the wrapper's
  # {"outcome":"CLAIMED"} line and the relay parsed it INTO that object,
  # inventing item/board/status/session_id fields and tripping the #2193
  # relay-integrity refusal on a perfectly healthy claim. Every other batch-step
  # emitter (worktree.sh / pr.sh / ci-poll.sh) already keeps stdout JSON-pure and
  # sends advisories to stderr; this restores that convention here. A terminal
  # still shows the line, so direct human use is unchanged.
  echo "Claimed #$issue → In Progress  [$stamp]" >&2

  # 3) Append to the durable claims log (F#728) — AFTER the lock is committed, so
  #    a telemetry failure can never affect the stamp-then-flip ordering above.
  #    See claim_log_emit's header comment for the sink, all-boards intent, and
  #    the single-host coverage caveat.
  claim_log_emit "$item_id" || true

  # 4) Surface the claim in whatever terminal multiplexer is present. The marker
  #    helper is multiplexer-aware and SELF-GUARDS per surface, so we compute the
  #    display string unconditionally and always call it — it is a no-op outside
  #    every multiplexer. The surfaces it drives:
  #    - tmux rename-window: sets the window *name* (#W) — the tmux window-status
  #      list and the tab title under plain tmux. A manual rename also disables
  #      automatic-rename for the window, so the name sticks.
  #    - tmux @claimed_issue: a per-window option read by the status bar
  #      (`status-right`) — the lever for iTerm2 control mode (`tmux -CC`), where
  #      the native tab follows the *pane* title (owned by Claude Code's live
  #      summary), so the window name never reaches the tab. status-right falls
  #      back to "No Issue Claimed" when empty. See GH #251.
  #    - cmux set-status: a per-workspace status chip (GH #348), for sessions
  #      running under cmux instead of tmux.
  #    The tmux surfaces apply to THIS session's own window (the pane Claude runs
  #    in), not the server's "current" window — else a claim from one session
  #    brands a concurrent session's window (GH #297). `scripts/release.sh` clears
  #    the marker when work on the item stops.
  local wname title_max short
  wname="#$issue"
  if [ -n "$issue_title" ]; then
    title_max=22                       # tune: chars of title shown after the number
    short="$issue_title"
    if [ "${#short}" -gt "$title_max" ]; then short="${short:0:$title_max}…"; fi
    wname="#$issue $short"
  fi
  claim_marker_set "$wname"
}

# Execute-guard: run the claim only when this file is RUN, not when SOURCED. When
# sourced (BASH_SOURCE[0] != $0), a test sets $issue / $PROJECT_NUMBER, defines
# its seam overrides, and calls claim_main itself — keeping the CLI parsing and
# the module-var defaults untouched.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  while [ $# -gt 0 ]; do
    case "$1" in
      --board) PROJECT_NUMBER="$(board_resolve_name "${2:?--board needs a value}")" || exit 2; shift 2 ;;
      --) shift; break ;;
      -*) echo "unknown arg: $1" >&2; exit 2 ;;
      *) if [ -z "$issue" ]; then issue="$1"; shift; else echo "unexpected arg: $1" >&2; exit 2; fi ;;
    esac
  done
  [ -n "$issue" ] || { echo "usage: claim.sh <issue-number> [--board 3|4]" >&2; exit 2; }
  issue="${issue#\#}"
  [[ "$issue" =~ ^[0-9]+$ ]] || { echo "issue must be a number, got: $issue" >&2; exit 2; }
  claim_main
fi
