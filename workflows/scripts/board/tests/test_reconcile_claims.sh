#!/usr/bin/env bash
#
# Fixture-replay tests for reconcile.sh's Lens 4 (dead-session claim stamps,
# --claims; temperloop#2069): an item that is In Progress whose
# `fnd:host/session:<host>:<sess8>` stamp names a session on THIS host that is
# provably dead gets that ONE label stripped — and nothing else. The
# `fnd:status:*` label stays byte-identical, the issue is never closed, and the
# Status is never moved to Ready.
#
# What each case pins (one per acceptance line of the item):
#   1  dry-run is the default: candidates + AGES reported, ZERO writes.
#   2  --apply strips the stamp ONLY; fnd:status:in-progress survives
#      byte-identical and no close / status write is ever issued.
#   3  a FOREIGN-host claim is never stripped — report-only, under any flag.
#   4  a LIVE same-host session's own held claim is never stripped.
#   5  the interleaved write: a claim/status change landing between scan and
#      apply is REFUSED by the immediate fresh re-read, not destroyed.
#   6  idempotence: a second run over the post-apply state reports zero
#      candidates and issues zero writes.
#   7  ages are rendered on the APPLY path too, and a 4-day-dead stamp reads
#      differently from one that has only just crossed the cutoff.
#   8  --unattended implies --apply and records the auto-take to the
#      pending-decisions surface.
#
# Zero network: reconcile.sh is SOURCED (its execute-guard suppresses the
# auto-run) and its `_board_gh` / `_reconcile_session_mtime` / `_reconcile_now`
# seams are overridden, exactly like test_reconcile.sh,
# test_reconcile_labels.sh and test_reconcile_status_issues_only.sh do.
#
# PROJECT_NUMBER / CLAIMS_APPLY / CLAIMS_UNATTENDED / the fixtures below are
# read by the sourced reconcile.sh, not in this file — ShellCheck can't see
# that cross-file use, so silence SC2034 file-wide (the directive must precede
# the first command). (Keep prose off any line starting `# shellcheck ` -- it
# is parsed as a directive.)
# shellcheck disable=SC2034

# Pin BOTH boards.conf discovery paths to nonexistent files (same convention as
# test_reconcile_labels.sh / test_boards_conf.sh) so board 7 resolves to the
# built-in issues-only backend regardless of what machine this runs on.
export BOARDS_CONF_MACHINE="/no-such-machine-conf-$$"
export BOARDS_CONF_REPO_LOCAL="/no-such-repo-local-conf-$$"

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$HERE/.." && pwd)"

# Deterministic host regardless of the runner's hostname — the same-host vs
# foreign-host split is the whole point of half these cases.
export SUBSET_HOST_LABEL="testhost"

# Isolated cache dir — never the real TMPDIR/BOARD_CACHE_DIR (mirrors
# test_reconcile.sh's isolation rationale).
BOARD_CACHE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/reconcile-claims-cache-test-XXXXXX")"
export BOARD_CACHE_DIR
TEST_TMP_DIRS=("$BOARD_CACHE_DIR")
cleanup() { rm -rf "${TEST_TMP_DIRS[@]}"; }
trap cleanup EXIT

# shellcheck source=scripts/reconcile.sh
# shellcheck disable=SC1091
source "$SCRIPTS_DIR/reconcile.sh"

fail() { printf 'FAIL: %b\n' "$1" >&2; exit 1; }

PROJECT_NUMBER=7

# --- fixtures ------------------------------------------------------------
# ALL_ISSUES_JSON is the SINGLE source of truth for repo state: board_resolve's
# whole-board `--state open` read AND the per-issue `api` re-check the strip
# path makes are both derived from it. API_OVERRIDE_<n>_JSON lets a case make
# the re-check disagree with the scan on purpose (the interleaved-write case).
ALL_ISSUES_JSON='[]'
# Session transcript mtimes, as "<sess8>=<epoch>" pairs; a session absent from
# this map has NO transcript at all (dead immediately).
SESSION_MTIMES=""
NOW_EPOCH=1789000000        # 2026-09-09T05:46:40Z — pinned so ages never vary
WRITES="/dev/null"          # every mutating gh call this run made

_board_gh() {
  case "$1 $2" in
    "issue list")
      local a want="" state="" jsonfields=""
      for a in "$@"; do
        case "$want" in
          state) state="$a"; want=""; continue ;;
          json)  jsonfields="$a"; want=""; continue ;;
        esac
        case "$a" in
          --state) want=state ;;
          --json)  want=json ;;
        esac
      done
      # board.sh's issues-only whole-board read asks for number,title,labels,
      # milestone; serve the open slice of the fixture with a null milestone.
      printf '%s' "$ALL_ISSUES_JSON" | jq -c --arg s "${state:-open}" '
        [ .[]
          | select(((.state // "open") | ascii_downcase) == $s)
          | { number, title: (.title // ""), milestone: null, labels: (.labels // []) } ]'
      ;;
    "issue edit")  printf '%s\n' "$*" >>"$WRITES"; return 0 ;;
    "issue close") printf '%s\n' "$*" >>"$WRITES"; return 0 ;;
    "label create") return 0 ;;
    "label delete") printf '%s\n' "$*" >>"$WRITES"; return 0 ;;
    *)
      case "$1" in
        api)
          local n="${2##*/}" var json
          var="API_OVERRIDE_${n}_JSON"
          json="${!var:-}"
          if [ -n "$json" ]; then printf '%s' "$json"; return 0; fi
          printf '%s' "$ALL_ISSUES_JSON" | jq -c --argjson n "$n" '
            (map(select(.number == $n))[0] // {"state":"open","labels":[]})
            | { state: ((.state // "open") | ascii_downcase), labels: (.labels // []) }' ;;
        *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
      esac
      ;;
  esac
}

# Deterministic liveness + clock seams. _reconcile_session_live is DERIVED from
# _reconcile_session_mtime in reconcile.sh, so overriding the mtime primitive
# alone drives both the report's age column and the apply path's re-check.
_reconcile_session_mtime() {
  local sess="$1" pair
  for pair in $SESSION_MTIMES; do
    case "$pair" in
      "$sess="*) printf '%s' "${pair#*=}"; return 0 ;;
    esac
  done
  printf '0'
}
_reconcile_now() { echo "$NOW_EPOCH"; }

run_claims() {
  WRITES="$(mktemp)"; TEST_TMP_DIRS+=("$WRITES")
  OUT="$(claims_reconcile_main)"
}

IP_LABEL="fnd:status:in-progress"
DEAD_SESS="deadbeef"
LIVE_SESS="a11ve000"
DEAD_STAMP="fnd:host/session:testhost:$DEAD_SESS"
LIVE_STAMP="fnd:host/session:testhost:$LIVE_SESS"
FOREIGN_STAMP="fnd:host/session:otherhost:f0re1gn0"

# A 4-day-dead transcript and a just-over-the-cutoff one, so the age column has
# two visibly different magnitudes to render (cutoff is 86400s / 1 day).
FOUR_DAYS_AGO=$(( NOW_EPOCH - 4 * 86400 - 2 * 3600 ))   # 4d 2h
JUST_STALE=$(( NOW_EPOCH - 86400 - 3600 ))              # 1d 1h

# =========================================================================
# Case 1: dry-run is the default — candidates reported WITH their ages, and
# ZERO writes. An absent transcript and a stale-but-present one both report.
# =========================================================================
ALL_ISSUES_JSON='[
  {"number":1938,"state":"OPEN","title":"Epic with 4 open members","labels":[{"name":"'"$IP_LABEL"'"},{"name":"'"$DEAD_STAMP"'"}]},
  {"number":1910,"state":"OPEN","title":"Epic with 6 open members","labels":[{"name":"'"$IP_LABEL"'"},{"name":"fnd:host/session:testhost:c0ffee00"}]},
  {"number":10,"state":"OPEN","title":"Ready singleton","labels":[{"name":"fnd:status:ready"}]}
]'
SESSION_MTIMES="$DEAD_SESS=$FOUR_DAYS_AGO"
CLAIMS_APPLY=0
CLAIMS_UNATTENDED=0
run_claims

grep -q "dead-session claim stamps (In Progress" <<<"$OUT" \
  || fail "case1: expected the dead-session-stamp section\n$OUT"
grep -qF "#1938 — stamped 'testhost:$DEAD_SESS' — stale for 4d 2h" <<<"$OUT" \
  || fail "case1: expected #1938 listed with its 4d 2h age\n$OUT"
grep -qF "#1910 — stamped 'testhost:c0ffee00' — no transcript for session 'c0ffee00' on this host (dead)" <<<"$OUT" \
  || fail "case1: expected #1910 listed as transcript-absent\n$OUT"
grep -q "#10" <<<"$OUT" \
  && fail "case1: a Ready item with no stamp must never be a candidate\n$OUT"
grep -q "(dry-run" <<<"$OUT" \
  || fail "case1: expected the dry-run notice\n$OUT"
grep -q "^applied:" <<<"$OUT" \
  && fail "case1: a dry run must never print an 'applied:' summary\n$OUT"
[ ! -s "$WRITES" ] || fail "case1: dry-run must issue ZERO writes\n$(cat "$WRITES")"
echo "PASS: case 1 dry-run reports every dead-session stamp WITH its age, zero writes"

# =========================================================================
# Case 2: --apply strips the STAMP label only. fnd:status:in-progress is left
# byte-identical, and no close / status write is ever issued.
# =========================================================================
CLAIMS_APPLY=1
CLAIMS_UNATTENDED=0
run_claims

grep -qF "stripped: #1938 $DEAD_STAMP" <<<"$OUT" \
  || fail "case2: expected #1938's stamp stripped\n$OUT"
grep -qF "stripped: #1910 fnd:host/session:testhost:c0ffee00" <<<"$OUT" \
  || fail "case2: expected #1910's stamp stripped\n$OUT"
grep -q "applied: cleared 2 dead-session claim stamp(s)" <<<"$OUT" \
  || fail "case2: expected the exact applied-count summary\n$OUT"
# Every write this run made must be a --remove-label of a host/session stamp.
while IFS= read -r w; do
  [ -n "$w" ] || continue
  case "$w" in
    "issue edit "*"--remove-label fnd:host/session:"*) ;;
    *) fail "case2: the ONLY write this lens may make is a host/session --remove-label; saw: $w" ;;
  esac
done <"$WRITES"
grep -q -- "--remove-label $IP_LABEL" "$WRITES" \
  && fail "case2: the fnd:status:* label must be left byte-identical\n$(cat "$WRITES")"
grep -q -- "--add-label" "$WRITES" \
  && fail "case2: this lens must never ADD a label\n$(cat "$WRITES")"
grep -q "issue close" "$WRITES" \
  && fail "case2: this lens must never close an issue\n$(cat "$WRITES")"
grep -q "0 status label(s) written, 0 item(s) closed or moved" <<<"$OUT" \
  || fail "case2: expected the stamp-only assertion in the applied summary\n$OUT"
echo "PASS: case 2 --apply strips the stamp ONLY — status label untouched, nothing closed or moved"

# =========================================================================
# Case 3: a FOREIGN-host claim is NEVER a strip candidate, even with --apply.
# Liveness is uncheckable from here, so it stays report-only.
# =========================================================================
ALL_ISSUES_JSON='[
  {"number":700,"state":"OPEN","title":"Claimed on another machine","labels":[{"name":"'"$IP_LABEL"'"},{"name":"'"$FOREIGN_STAMP"'"}]}
]'
SESSION_MTIMES=""
CLAIMS_APPLY=1
CLAIMS_UNATTENDED=0
run_claims

grep -q "foreign claims (another host" <<<"$OUT" \
  || fail "case3: expected the report-only foreign-claim bucket\n$OUT"
grep -qF "#700 — stamped 'otherhost:f0re1gn0'" <<<"$OUT" \
  || fail "case3: expected #700 listed as a foreign claim\n$OUT"
grep -q "stripped: #700" <<<"$OUT" \
  && fail "case3: a foreign-host claim must NEVER be stripped\n$OUT"
grep -q "nothing to strip" <<<"$OUT" \
  || fail "case3: a board with only foreign claims has nothing to strip\n$OUT"
[ ! -s "$WRITES" ] \
  || fail "case3: a foreign claim must produce ZERO writes even under --apply\n$(cat "$WRITES")"
echo "PASS: case 3 a foreign-host claim is refused (report-only), never stripped"

# =========================================================================
# Case 4: a LIVE same-host session's own held claim is never stripped — the
# running session's own claim self-excludes because its mtime is current.
# =========================================================================
ALL_ISSUES_JSON='[
  {"number":800,"state":"OPEN","title":"This very session is driving it","labels":[{"name":"'"$IP_LABEL"'"},{"name":"'"$LIVE_STAMP"'"}]},
  {"number":801,"state":"OPEN","title":"Dead run left this behind","labels":[{"name":"'"$IP_LABEL"'"},{"name":"'"$DEAD_STAMP"'"}]}
]'
SESSION_MTIMES="$LIVE_SESS=$NOW_EPOCH $DEAD_SESS=$FOUR_DAYS_AGO"
CLAIMS_APPLY=1
CLAIMS_UNATTENDED=0
run_claims

grep -q "#800" <<<"$OUT" \
  && fail "case4: a LIVE same-host claim must not even be reported as a candidate\n$OUT"
grep -q "stripped: #801" <<<"$OUT" \
  || fail "case4: the dead-session claim beside it should still be stripped\n$OUT"
grep -qF "$LIVE_STAMP" "$WRITES" \
  && fail "case4: a live session's own claim stamp must NEVER be written\n$(cat "$WRITES")"
grep -q "applied: cleared 1 dead-session claim stamp(s)" <<<"$OUT" \
  || fail "case4: expected exactly one strip\n$OUT"
echo "PASS: case 4 a live same-host session's own held claim is never stripped"

# =========================================================================
# Case 5: the INTERLEAVED WRITE. Three issues look identical in the scan; each
# changes underneath us before the apply, and the immediate FRESH re-read must
# refuse all three rather than destroying the new state:
#   #900 was re-claimed by a different (live) session -> stamp label gone
#   #901 was PARKED back to Ready                     -> In-Progress label gone
#   #902 was CLOSED                                   -> no longer open
# =========================================================================
ALL_ISSUES_JSON='[
  {"number":900,"state":"OPEN","title":"Re-claimed in the gap","labels":[{"name":"'"$IP_LABEL"'"},{"name":"'"$DEAD_STAMP"'"}]},
  {"number":901,"state":"OPEN","title":"Parked in the gap","labels":[{"name":"'"$IP_LABEL"'"},{"name":"'"$DEAD_STAMP"'"}]},
  {"number":902,"state":"OPEN","title":"Closed in the gap","labels":[{"name":"'"$IP_LABEL"'"},{"name":"'"$DEAD_STAMP"'"}]},
  {"number":903,"state":"OPEN","title":"Unchanged in the gap","labels":[{"name":"'"$IP_LABEL"'"},{"name":"'"$DEAD_STAMP"'"}]}
]'
# The fresh re-read disagrees with the scan snapshot for #900/#901/#902 only.
API_OVERRIDE_900_JSON='{"state":"open","labels":[{"name":"'"$IP_LABEL"'"},{"name":"fnd:host/session:testhost:99999999"}]}'
API_OVERRIDE_901_JSON='{"state":"open","labels":[{"name":"fnd:status:ready"},{"name":"'"$DEAD_STAMP"'"}]}'
API_OVERRIDE_902_JSON='{"state":"closed","labels":[{"name":"'"$IP_LABEL"'"},{"name":"'"$DEAD_STAMP"'"}]}'
SESSION_MTIMES="$DEAD_SESS=$FOUR_DAYS_AGO"
CLAIMS_APPLY=1
CLAIMS_UNATTENDED=0
run_claims

for n in 900 901 902; do
  grep -q "skip (no longer open+In-Progress+stamped): #$n" <<<"$OUT" \
    || fail "case5: expected the fresh re-read to refuse #$n\n$OUT"
  grep -q "stripped: #$n " <<<"$OUT" \
    && fail "case5: #$n changed between scan and apply and must NOT be stripped\n$OUT"
done
grep -q "stripped: #903 " <<<"$OUT" \
  || fail "case5: the unchanged issue must still be stripped\n$OUT"
grep -q "applied: cleared 1 dead-session claim stamp(s)" <<<"$OUT" \
  || fail "case5: exactly one of the four should survive the re-check\n$OUT"
grep -q "^issue edit 90[012] " "$WRITES" \
  && fail "case5: no write may reach an issue the re-read refused\n$(cat "$WRITES")"
unset API_OVERRIDE_900_JSON API_OVERRIDE_901_JSON API_OVERRIDE_902_JSON
echo "PASS: case 5 an interleaved re-claim / park / close is refused by the fresh re-read, never destroyed"

# =========================================================================
# Case 6: idempotence — a second run against the POST-APPLY state (the stamp
# is gone) reports zero candidates, issues zero writes, and exits 0.
# =========================================================================
ALL_ISSUES_JSON='[
  {"number":1938,"state":"OPEN","title":"Epic with 4 open members","labels":[{"name":"'"$IP_LABEL"'"}]},
  {"number":1910,"state":"OPEN","title":"Epic with 6 open members","labels":[{"name":"'"$IP_LABEL"'"}]}
]'
SESSION_MTIMES="$DEAD_SESS=$FOUR_DAYS_AGO"
CLAIMS_APPLY=1
CLAIMS_UNATTENDED=0
run_claims
rc=$?

[ "$rc" -eq 0 ] || fail "case6: the idempotent re-run must exit 0, got $rc"
grep -q "In sync" <<<"$OUT" \
  || fail "case6: expected an in-sync report on the post-apply state\n$OUT"
grep -q "^applied:" <<<"$OUT" \
  && fail "case6: nothing to apply means no applied summary\n$OUT"
[ ! -s "$WRITES" ] || fail "case6: the idempotent re-run must issue ZERO writes\n$(cat "$WRITES")"
echo "PASS: case 6 a second run against post-apply state reports zero changes, exit 0"

# =========================================================================
# Case 7: ages are rendered on the APPLY path too, and two different
# stalenesses render differently (a 4-day-dead stamp vs a just-over-cutoff one).
# =========================================================================
ALL_ISSUES_JSON='[
  {"number":1938,"state":"OPEN","title":"Four days dead","labels":[{"name":"'"$IP_LABEL"'"},{"name":"'"$DEAD_STAMP"'"}]},
  {"number":1910,"state":"OPEN","title":"Just over the cutoff","labels":[{"name":"'"$IP_LABEL"'"},{"name":"fnd:host/session:testhost:freshdea"}]}
]'
SESSION_MTIMES="$DEAD_SESS=$FOUR_DAYS_AGO freshdea=$JUST_STALE"
CLAIMS_APPLY=1
CLAIMS_UNATTENDED=0
run_claims

grep -qF "#1938 — stamped 'testhost:$DEAD_SESS' — stale for 4d 2h (cutoff 1d 0h)" <<<"$OUT" \
  || fail "case7: expected #1938's 4d 2h age on the apply path\n$OUT"
grep -qF "#1910 — stamped 'testhost:freshdea' — stale for 1d 1h (cutoff 1d 0h)" <<<"$OUT" \
  || fail "case7: expected #1910's 1d 1h age on the apply path\n$OUT"
echo "PASS: case 7 the apply path carries ages too, and a 4-day-dead stamp reads differently from a fresh one"

# =========================================================================
# Case 8: --unattended implies --apply AND records the auto-take to the
# pending-decisions surface (created at the legacy path when neither exists).
# =========================================================================
KS_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/reconcile-claims-ks-test-XXXXXX")"
TEST_TMP_DIRS+=("$KS_ROOT")
export KNOWLEDGE_STORE_ROOT="$KS_ROOT"
ALL_ISSUES_JSON='[
  {"number":1938,"state":"OPEN","title":"Four days dead","labels":[{"name":"'"$IP_LABEL"'"},{"name":"'"$DEAD_STAMP"'"}]}
]'
SESSION_MTIMES="$DEAD_SESS=$FOUR_DAYS_AGO"
CLAIMS_APPLY=0
CLAIMS_UNATTENDED=1
run_claims

grep -q "applied: cleared 1 dead-session claim stamp(s)" <<<"$OUT" \
  || fail "case8: --unattended alone must apply (CLAIMS_APPLY forced to 1)\n$OUT"
LEGACY_DOC="$KS_ROOT/Context/pipeline - pending decisions.md"
[ -f "$LEGACY_DOC" ] \
  || fail "case8: expected a pending-decisions entry at the legacy path\n$(find "$KS_ROOT" -type f)"
grep -q "dead-session claim-stamp sweep" "$LEGACY_DOC" \
  || fail "case8: entry missing the sweep name\n$(cat "$LEGACY_DOC")"
grep -q "board7" "$LEGACY_DOC" || fail "case8: entry missing the board tag\n$(cat "$LEGACY_DOC")"
grep -q "Default taken:\*\* applied — cleared 1 dead-session claim stamp(s)" "$LEGACY_DOC" \
  || fail "case8: entry missing the exact default-taken counts line\n$(cat "$LEGACY_DOC")"
grep -q "Status:\*\* open" "$LEGACY_DOC" || fail "case8: entry missing Status: open\n$(cat "$LEGACY_DOC")"
unset KNOWLEDGE_STORE_ROOT
echo "PASS: case 8 --unattended applies and records the auto-take to the pending-decisions surface"

echo
echo "ALL reconcile --claims (Lens 4) tests passed."
