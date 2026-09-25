#!/usr/bin/env bash
#
# Tests for workflows/scripts/build/gate.sh — the build 4a/4b/4c
# merge-gate mechanics (epic #253, spike #245). ONE fixture system: this test
# `source`s gate.sh (whose source guard skips the dispatch), which in turn
# sources board.sh — and overrides the `_gate_gh` seam exactly the way the
# board replay tests override `_board_gh` (no second mock layer, no PATH shim,
# zero network; gate.sh has no local-git dependency at all — temperloop#242).
# Each case redefines the seam, then calls the cmd_* function directly and
# asserts on the structured JSON it prints.
#
# Covers:
#   - read: stable MERGEABLE/CLEAN read; UNKNOWN/BEHIND triggers exactly one
#     re-poll, then classifies on the second (settled) value
#   - strict: required_status_checks.strict==true → STRICT; gh 404 → NON_STRICT
#   - risk: RISKY on overlapping files (via the GitHub API's own `files` field,
#     never a local git diff, so a push-by-SHA head ref with no reachable
#     local/origin branch is never a problem — temperloop#242); RISKY on a
#     hold/risky label; RISKY on a not-CLEAN mergeStateStatus; a clean,
#     pairwise-disjoint, unflagged set → CLEAN_DISJOINT_INDEPENDENT; a failed
#     files lookup emits a closed {"outcome":"ERROR"} line rather than dying
#     with empty stdout under `set -e` (the dead-ERR-path regression)
#   - queue: canonical --auto incantation → QUEUED (a real merge is never run)
#   - nudge: BEHIND → NUDGED (update-branch called); not-BEHIND → NUDGE_NOOP
#   - poll: ONE fixture per terminal outcome — MERGED (exit 0, the SOLE success
#     check), CONFLICTING/DIRTY (exit 3), TIMEOUT (exit 4); a CLOSED-not-merged
#     PR never reads MERGED (the #130 premature-close guard)
#   - backend: auto probe → NATIVE (merge_queue rule present) / MANAGED (rule
#     absent) / MANAGED+probe_failed:true (gh error, the fail-safe direction);
#     an explicit BUILD_MERGE_BACKEND=native|managed override short-circuits
#     WITHOUT calling the probe at all
#   - managed-merge: strict (default) → update-branch called, SHA-pinned CI
#     re-poll green, merge, confirmed MERGED; --non-strict → update-branch
#     NEVER called, merges directly; CI red after update-branch → EJECTED, no
#     merge attempted; `gh pr merge` itself rejected (e.g. queue-armed repo) →
#     MERGE_REJECTED, distinct non-silent outcome; an existing subcommand's
#     JSON is asserted BYTE-IDENTICAL (no-behavior-change-on-native guarantee)
#   - diagnose-queue (temperloop#1150): a live mergeQueueEntry → QUEUED (exit 0,
#     the merge_group probe is NOT even queried); a failed merge_group run for
#     the PR → split by per-job step data (temperloop#1175): a workflow-defined
#     step (any step after "Set up job") itself failing → MERGE_GROUP_FAILED
#     (exit 7) + the run id; the run failing before any workflow-defined step
#     ran → MERGE_GROUP_INFRA (exit 11) + the run id; the jobs lookup itself
#     erroring → the conservative MERGE_GROUP_FAILED fallback (never widens
#     what gets retried); not-in-queue with no
#     referencing run → DEQUEUED (exit 8); the `/pr-<N>-` branch anchor does not
#     let #4 match a #42 run; an in-progress referencing run → QUEUED (not a
#     dequeue); an already-merged PR → MERGED (exit 0), short-circuiting the probe
#   - QUEUE_STALLED (temperloop#1178): a live entry older than
#     BUILD_QUEUE_STALL_AFTER with ZERO dispatched merge_group runs →
#     QUEUE_STALLED (exit 10) + enqueued_secs/merge_group_runs; a HEALTHY entry is
#     unaffected (under the threshold, or with ≥1 referencing run, stays QUEUED);
#     raising the setting turns the same stalled fixture back into QUEUED; poll's
#     TIMEOUT carries the probe's verdict as `reason`/`diagnosis`, and falls back
#     to the bare TIMEOUT shape when the probe itself errors. The clock is pinned
#     through the `_gate_now` seam, so these are deterministic and network-free.
#   - the TIMEOUT stamp (temperloop#2055, the sufficiency the raised
#     BUILD_QUEUE_TIMEOUT ceiling leans on): a zero-progress stall stamps
#     `reason:"QUEUE_STALLED"`, a live-entry healthy-but-slow PR stamps
#     `reason:"QUEUED"` + the incident's `queueState`, and in BOTH cases
#     `.diagnosis` is byte-equal to running diagnose-queue directly on the same
#     fixture — so the stamp can never silently degrade to a bare waited count
#
# The seams are redefined mid-file per case (the library calls them
# indirectly), so shellcheck's "never invoked"/"unreachable" checks are false
# positives — disabled file-wide like the sibling board replay tests.
# shellcheck disable=SC2317,SC2329
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the script under test. Its source-guard ([ BASH_SOURCE = $0 ]) skips
# the CLI dispatch, exposing cmd_* and the _gate_* seams; it also sources
# board.sh, so the shared fixture system is in scope. No re-poll wait in tests.
export GATE_REPOLL_DELAY=0
# shellcheck source=workflows/scripts/build/gate.sh
source "$HERE/../gate.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# cmd_diagnose_queue now fires a lake-stream emit (workflows/scripts/
# emit-diagnose-queue.sh, temperloop#1192) on every exit path. Pin its sink to
# a throwaway tmpdir so this test never writes into the real repo's
# meta/data/raw/ — the emit's own behavior (record shape, per-outcome
# coverage) is covered by workflows/scripts/tests/test_diagnose_queue_emit.sh;
# here we only need the emit to be a no-op on this file's own assertions.
export DIAGNOSE_QUEUE_RAW_DIR="$TMP/diagnose-queue-raw"

# Confirm the shared fixture system is live: board.sh's _board_gh seam is in
# scope (same harness gate.sh + the board tests share).
command -v _board_gh >/dev/null || fail "board.sh not sourced — shared fixture system missing"
echo "PASS: gate.sh sources board.sh — one shared fixture system (_board_gh in scope)"

# --- read: stable MERGEABLE/CLEAN -------------------------------------------
_gate_gh() {
  # $1=pr $2=view ... emit the --json payload as gh would (raw via --jq).
  cat <<'JSON'
{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","state":"OPEN",
 "statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"}]}
JSON
}
out="$(cmd_read Towheads/foundation 42)"
[ "$(jq -r .outcome <<<"$out")" = "READ" ] || fail "read outcome (got: $out)"
[ "$(jq -r .mergeable <<<"$out")" = "MERGEABLE" ] || fail "read mergeable (got: $out)"
[ "$(jq -r .mergeStateStatus <<<"$out")" = "CLEAN" ] || fail "read mss (got: $out)"
[ "$(jq -r .checks <<<"$out")" = "PASS" ] || fail "read checks digest (got: $out)"
echo "PASS: read → mergeable/mergeStateStatus/state/checks digest on a CLEAN PR"

# --- read: UNKNOWN then settled → exactly one re-poll -----------------------
# A file-backed counter, because _gate_view runs inside a process-substitution
# subshell — an in-memory counter would reset each call.
echo 0 > "$TMP/reads"
_gate_gh() {
  local n; n=$(<"$TMP/reads"); n=$((n + 1)); echo "$n" > "$TMP/reads"
  if [ "$n" -eq 1 ]; then
    echo '{"mergeable":"UNKNOWN","mergeStateStatus":"UNKNOWN","state":"OPEN","statusCheckRollup":[]}'
  else
    echo '{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","state":"OPEN","statusCheckRollup":[]}'
  fi
}
out="$(cmd_read Towheads/foundation 42)"
[ "$(jq -r .mergeable <<<"$out")" = "MERGEABLE" ] || fail "re-poll did not settle (got: $out)"
[ "$(<"$TMP/reads")" -eq 2 ] || fail "expected exactly one re-poll (2 reads), got $(<"$TMP/reads")"
echo "PASS: read re-polls ONCE on UNKNOWN and classifies on the settled value"

# --- strict: protection strict==true → STRICT -------------------------------
_gate_gh() { echo "true"; }
out="$(cmd_strict Towheads/foundation)"
[ "$(jq -r .outcome <<<"$out")" = "STRICT" ] || fail "strict-true not STRICT (got: $out)"
echo "PASS: strict → STRICT when required_status_checks.strict == true"

# --- strict: gh 404 (not protected) → NON_STRICT ----------------------------
_gate_gh() { return 1; }   # gh non-zero == 404 / not protected
out="$(cmd_strict Towheads/foundation)"
[ "$(jq -r .outcome <<<"$out")" = "NON_STRICT" ] || fail "404 not NON_STRICT (got: $out)"
echo "PASS: strict → NON_STRICT on a 404 (branch not protected)"

# --- risk: CLEAN, pairwise-disjoint, unflagged set → passes -----------------
# _gate_gh dispatches on the requested --json field; the "files" field (the
# GitHub API's own PR-files list, NEVER local git — temperloop#242) returns
# each PR's disjoint file set. This is also the push-by-SHA regression case:
# a real push-by-SHA branch has no local/origin ref of that name at all, so a
# fixture that answered via `headRefName` + a git diff could never model it
# faithfully — routing entirely through the `files` field is what makes this
# test exercise the actual push-by-SHA-safe code path, not just a mock of it.
_gate_gh() {
  local pr field=""; local -a a=("$@")
  pr="${a[2]}"
  for ((k=0; k<${#a[@]}; k++)); do [ "${a[$k]}" = "--json" ] && field="${a[$((k+1))]}"; done
  case "$field" in
    mergeable,mergeStateStatus,state,statusCheckRollup)
      echo '{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","state":"OPEN","statusCheckRollup":[]}' ;;
    files)  echo "src/file_$pr.sh" ;;   # one unique file per PR → disjoint
    labels) echo "" ;;                  # no labels
    *) echo "{}" ;;
  esac
}
out="$(cmd_risk Towheads/foundation 10 11 12)"
[ "$(jq -r .outcome <<<"$out")" = "CLEAN_DISJOINT_INDEPENDENT" ] \
  || fail "clean disjoint set not CLEAN_DISJOINT_INDEPENDENT (got: $out)"
echo "PASS: risk → CLEAN_DISJOINT_INDEPENDENT on a CLEAN, disjoint, unflagged set (files via API, not local git)"

# --- risk: overlapping changed files → RISKY --------------------------------
_gate_gh() {
  local pr field=""; local -a a=("$@"); pr="${a[2]}"
  for ((k=0; k<${#a[@]}; k++)); do [ "${a[$k]}" = "--json" ] && field="${a[$((k+1))]}"; done
  case "$field" in
    mergeable,mergeStateStatus,state,statusCheckRollup)
      echo '{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","state":"OPEN","statusCheckRollup":[]}' ;;
    files)  echo "src/shared.sh" ;;   # every PR touches the SAME file → overlap
    labels) echo "" ;;
    *) echo "{}" ;;
  esac
}
out="$(cmd_risk Towheads/foundation 10 11)"
[ "$(jq -r .outcome <<<"$out")" = "RISKY" ] || fail "overlap not RISKY (got: $out)"
jq -e '.reasons[] | select(test("overlapping files"))' <<<"$out" >/dev/null \
  || fail "overlap reason not surfaced (got: $out)"
echo "PASS: risk → RISKY when changed-file sets are not pairwise disjoint"

# --- risk: a hold/risky label → RISKY ---------------------------------------
_gate_gh() {
  local pr field=""; local -a a=("$@"); pr="${a[2]}"
  for ((k=0; k<${#a[@]}; k++)); do [ "${a[$k]}" = "--json" ] && field="${a[$((k+1))]}"; done
  case "$field" in
    mergeable,mergeStateStatus,state,statusCheckRollup)
      echo '{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","state":"OPEN","statusCheckRollup":[]}' ;;
    files)  echo "src/file_$pr.sh" ;;   # disjoint again
    labels) [ "$pr" = "11" ] && echo "hold" || echo "" ;;
    *) echo "{}" ;;
  esac
}
out="$(cmd_risk Towheads/foundation 10 11)"
[ "$(jq -r .outcome <<<"$out")" = "RISKY" ] || fail "label not RISKY (got: $out)"
jq -e '.reasons[] | select(test("hold/risky label"))' <<<"$out" >/dev/null \
  || fail "label reason not surfaced (got: $out)"
echo "PASS: risk → RISKY when any PR carries a hold/risky label"

# --- risk: a not-CLEAN mergeStateStatus → RISKY -----------------------------
_gate_gh() {
  local pr field=""; local -a a=("$@"); pr="${a[2]}"
  for ((k=0; k<${#a[@]}; k++)); do [ "${a[$k]}" = "--json" ] && field="${a[$((k+1))]}"; done
  case "$field" in
    mergeable,mergeStateStatus,state,statusCheckRollup)
      if [ "$pr" = "11" ]; then
        echo '{"mergeable":"MERGEABLE","mergeStateStatus":"BLOCKED","state":"OPEN","statusCheckRollup":[]}'
      else
        echo '{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","state":"OPEN","statusCheckRollup":[]}'
      fi ;;
    files)  echo "src/file_$pr.sh" ;;
    labels) echo "" ;;
    *) echo "{}" ;;
  esac
}
out="$(cmd_risk Towheads/foundation 10 11)"
[ "$(jq -r .outcome <<<"$out")" = "RISKY" ] || fail "not-CLEAN mss not RISKY (got: $out)"
jq -e '.reasons[] | select(test("not CLEAN"))' <<<"$out" >/dev/null \
  || fail "not-CLEAN reason not surfaced (got: $out)"
echo "PASS: risk → RISKY when any PR's mergeStateStatus is not CLEAN"

# --- risk: a failed files lookup emits a closed ERROR outcome, never dies
# empty ------------------------------------------------------------------
# Regression for the dead-ERR-path defect (temperloop#242): a bare
# `local f; f="$(_gate_pr_files ...)"` split across two statements let a
# failing command substitution kill the whole script under `set -euo
# pipefail` BEFORE the `case "$f" in ERR*)` handler ever ran — rc=1 with
# EMPTY stdout, no JSON for the orchestrator to branch on. This asserts the
# fixed call site always produces a closed-JSON {"outcome":"ERROR",...} line
# on stdout (via the fd-3 `die` seam) rather than dying silent.
_gate_gh() {
  local pr field=""; local -a a=("$@"); pr="${a[2]}"
  for ((k=0; k<${#a[@]}; k++)); do [ "${a[$k]}" = "--json" ] && field="${a[$((k+1))]}"; done
  case "$field" in
    mergeable,mergeStateStatus,state,statusCheckRollup)
      echo '{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","state":"OPEN","statusCheckRollup":[]}' ;;
    files)  echo "gh: pull request files lookup failed (rate limited)" >&2; return 1 ;;
    labels) echo "" ;;
    *) echo "{}" ;;
  esac
}
# die() emits on fd 3 (the script's real-stdout seam — see the "error: bad
# inputs" case below); capture it back into the command substitution with
# `3>&1` and silence the plain-stdout side (2/1) so a genuine empty-stdout
# regression can't hide behind fd 3's output.
rc=0; out="$( (cmd_risk Towheads/foundation 10) 3>&1 2>/dev/null)" || rc=$?
[ "$rc" -eq 1 ] || fail "expected cmd_risk to exit 1 on a files-lookup failure (got rc=$rc, out: $out)"
[ -n "$out" ] || fail "cmd_risk died with EMPTY stdout on a files-lookup failure (the dead-ERR-path regression)"
[ "$(jq -r .outcome <<<"$out")" = "ERROR" ] \
  || fail "expected a closed {\"outcome\":\"ERROR\"} line, got: $out"
echo "PASS: risk → closed ERROR-outcome JSON (never empty-stdout death) when the files lookup fails"

# --- queue: canonical --auto incantation → QUEUED ---------------------------
# Assert gate.sh queues via --auto --merge (never a bare merge-now), and records
# the strict flag. The merge queue rejects --delete-branch and deletes the head
# branch itself, so the incantation must NOT carry it (Branch & PR policy). The
# seam logs the argv so we can prove the incantation; it never performs a real
# merge.
_gate_gh() { echo "$*" > "$TMP/merge_argv"; return 0; }
out="$(cmd_queue Towheads/foundation 42 --strict)"
[ "$(jq -r .outcome <<<"$out")" = "QUEUED" ] || fail "queue outcome (got: $out)"
[ "$(jq -r .strict <<<"$out")" = "true" ] || fail "queue strict flag (got: $out)"
argv="$(<"$TMP/merge_argv")"
grep -q -- '--auto' <<<"$argv" || fail "queue did not use --auto (argv: $argv)"
grep -q -- '--merge' <<<"$argv" || fail "queue did not use --merge (argv: $argv)"
grep -q -- '--delete-branch' <<<"$argv" && fail "queue must NOT pass --delete-branch (the merge queue rejects it; argv: $argv)"
echo "PASS: queue → QUEUED via the canonical --auto --merge (no --delete-branch, no bare merge)"

# --- queue: a DRAFT PR is NAMED before the enqueue (temperloop#1180) ---------
# Disposition is FAIL LOUDLY, not an auto `gh pr ready` flip: nothing in this
# repo opens a draft (pr.sh open passes no --draft on any path) and nothing runs
# `gh pr ready`, so a draft at the merge gate is always a human decision. Assert
# the named DRAFT outcome + exit 9, the actionable remedy in the message, and —
# the load-bearing half — that `gh pr merge` is NEVER reached, so GitHub's raw
# `Pull request is a draft (enablePullRequestAutoMerge)` string can't be the
# operator-facing signal.
rm -f "$TMP/queue_merge_called"
_gate_gh() {
  local -a a=("$@")
  if [ "${a[0]}" = "pr" ] && [ "${a[1]}" = "merge" ]; then
    touch "$TMP/queue_merge_called"; return 0
  fi
  echo "true"   # gh pr view --json isDraft --jq .isDraft
}
rc=0; out="$(cmd_queue Towheads/foundation 440 --strict)" || rc=$?
[ "$rc" -eq 9 ] || fail "draft PR did not exit 9 (rc=$rc, out: $out)"
[ "$(jq -r .outcome <<<"$out")" = "DRAFT" ] || fail "queue draft outcome (got: $out)"
[ "$(jq -r .pr <<<"$out")" = "440" ] || fail "queue draft pr number (got: $out)"
[ -f "$TMP/queue_merge_called" ] && fail "gh pr merge was attempted on a draft PR (detection must precede the enqueue)"
err="$(jq -r .error <<<"$out")"
grep -q 'DRAFT' <<<"$err" || fail "draft message does not name the draft state (got: $err)"
grep -q 'gh pr ready 440 -R Towheads/foundation' <<<"$err" || fail "draft message lacks the actionable remedy (got: $err)"
grep -qi 'GraphQL' <<<"$err" && fail "draft message leaks GitHub's raw GraphQL error text (got: $err)"
echo "PASS: queue → DRAFT (exit 9) detected BEFORE the enqueue, with a named state + a gh pr ready remedy"

# --- queue: a draft that slips past the fail-open probe is still NAMED -------
# The pre-flight probe is fail-open (an unreadable isDraft proceeds rather than
# blocking), so the post-hoc classifier is what closes the hole: `gh pr merge`
# rejecting with GitHub's raw draft string must still surface as DRAFT, never as
# a raw-text ERROR.
_gate_gh() {
  local -a a=("$@")
  if [ "${a[0]}" = "pr" ] && [ "${a[1]}" = "merge" ]; then
    echo "GraphQL: Pull request is a draft (enablePullRequestAutoMerge)"; return 1
  fi
  return 1   # the isDraft probe itself fails — the fail-open path
}
rc=0; out="$(cmd_queue Towheads/foundation 440)" || rc=$?
[ "$rc" -eq 9 ] || fail "post-hoc draft rejection did not exit 9 (rc=$rc, out: $out)"
[ "$(jq -r .outcome <<<"$out")" = "DRAFT" ] || fail "post-hoc draft outcome (got: $out)"
grep -qi 'GraphQL' <<<"$(jq -r .error <<<"$out")" && fail "post-hoc DRAFT still echoes the raw GraphQL string"
echo "PASS: queue → DRAFT (exit 9) also when the probe fails open and gh itself rejects the draft"

# --- queue: a NON-draft enqueue failure stays a plain ERROR ------------------
# The post-hoc classifier is anchored on the draft phrase alone; an unrelated
# rejection that merely mentions enablePullRequestAutoMerge must NOT be
# mis-named DRAFT (one wrong message traded for another).
_gate_gh() {
  local -a a=("$@")
  if [ "${a[0]}" = "pr" ] && [ "${a[1]}" = "merge" ]; then
    echo "GraphQL: Auto merge is not allowed for this repository (enablePullRequestAutoMerge)"; return 1
  fi
  echo "false"
}
rc=0; out="$( (cmd_queue Towheads/foundation 42) 3>&1 2>/dev/null)" || rc=$?
[ "$rc" -eq 1 ] || fail "non-draft enqueue failure did not exit 1 (rc=$rc, out: $out)"
[ "$(jq -r .outcome <<<"$out")" = "ERROR" ] || fail "non-draft enqueue failure not ERROR (got: $out)"
echo "PASS: queue → a non-draft enqueue rejection stays a plain ERROR (no DRAFT false positive)"

# --- nudge: BEHIND → NUDGED (update-branch invoked) -------------------------
rm -f "$TMP/nudge_called"
_gate_gh() {
  local -a a=("$@")
  if [ "${a[0]}" = "pr" ] && [ "${a[1]}" = "update-branch" ]; then
    touch "$TMP/nudge_called"; return 0
  fi
  echo '{"mergeable":"UNKNOWN","mergeStateStatus":"BEHIND","state":"OPEN","statusCheckRollup":[]}'
}
out="$(cmd_nudge Towheads/foundation 42)"
[ "$(jq -r .outcome <<<"$out")" = "NUDGED" ] || fail "BEHIND not NUDGED (got: $out)"
[ -f "$TMP/nudge_called" ] || fail "update-branch not invoked for a BEHIND PR"
echo "PASS: nudge → NUDGED (gh pr update-branch) for a still-BEHIND PR (#83 nudge)"

# --- nudge: not-BEHIND → NUDGE_NOOP -----------------------------------------
_gate_gh() {
  local -a a=("$@")
  [ "${a[1]}" = "update-branch" ] && fail "update-branch called on a CLEAN PR (should NOOP)"
  echo '{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","state":"OPEN","statusCheckRollup":[]}'
}
out="$(cmd_nudge Towheads/foundation 42)"
[ "$(jq -r .outcome <<<"$out")" = "NUDGE_NOOP" ] || fail "CLEAN not NUDGE_NOOP (got: $out)"
echo "PASS: nudge → NUDGE_NOOP (no update-branch) when the PR is not BEHIND"

# --- poll: MERGED is the SOLE success check (exit 0) ------------------------
_gate_gh() { echo '{"state":"MERGED","mergedAt":"2026-06-10T12:00:00Z","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}'; }
rc=0; out="$(cmd_poll Towheads/foundation 42 --interval 0.1 --timeout 5)" || rc=$?
[ "$rc" -eq 0 ] || fail "MERGED did not exit 0 (rc=$rc)"
[ "$(jq -r .outcome <<<"$out")" = "MERGED" ] || fail "poll MERGED outcome (got: $out)"
[ "$(jq -r .mergedAt <<<"$out")" = "2026-06-10T12:00:00Z" ] || fail "poll mergedAt (got: $out)"
echo "PASS: poll → MERGED + exit 0 ONLY on state==MERGED with a confirmed mergedAt"

# --- poll: CLOSED-without-merge NEVER reads MERGED (the #130 guard) ----------
# A PR closed but never merged: state=CLOSED, mergedAt=null. It must NOT exit 0
# as MERGED; here it has no conflict, so it runs to TIMEOUT (exit 4) — the point
# is that MERGED (exit 0) is unreachable for a closed-not-merged PR.
_gate_gh() { echo '{"state":"CLOSED","mergedAt":null,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}'; }
rc=0; out="$(cmd_poll Towheads/foundation 42 --interval 0.1 --timeout 0)" || rc=$?
[ "$rc" -ne 0 ] || fail "CLOSED-not-merged exited 0 (premature-close #130 regression!)"
[ "$(jq -r .outcome <<<"$out")" != "MERGED" ] || fail "CLOSED-not-merged read as MERGED (#130!)"
echo "PASS: poll → a CLOSED-but-unmerged PR never reads MERGED (the #130 premature-close guard)"

# --- poll: CONFLICTING/DIRTY → distinct exit 3 ------------------------------
_gate_gh() { echo '{"state":"OPEN","mergedAt":null,"mergeable":"CONFLICTING","mergeStateStatus":"DIRTY"}'; }
rc=0; out="$(cmd_poll Towheads/foundation 42 --interval 0.1 --timeout 5)" || rc=$?
[ "$rc" -eq 3 ] || fail "CONFLICTING/DIRTY did not exit 3 (rc=$rc)"
[ "$(jq -r .outcome <<<"$out")" = "CONFLICTING" ] || fail "poll CONFLICTING outcome (got: $out)"
echo "PASS: poll → CONFLICTING + distinct exit 3 on a conflicting/dirty PR"

# --- poll: timeout/stall → distinct exit 4 ----------------------------------
_gate_gh() { echo '{"state":"OPEN","mergedAt":null,"mergeable":"MERGEABLE","mergeStateStatus":"BLOCKED"}'; }
rc=0; out="$(cmd_poll Towheads/foundation 42 --interval 0.1 --timeout 0)" || rc=$?
[ "$rc" -eq 4 ] || fail "stall did not exit 4 (rc=$rc)"
[ "$(jq -r .outcome <<<"$out")" = "TIMEOUT" ] || fail "poll TIMEOUT outcome (got: $out)"
echo "PASS: poll → TIMEOUT + distinct exit 4 on a stalled (never-terminal) PR"

# --- diagnose-queue: still enqueued (mergeQueueEntry present) → QUEUED --------
# The membership signal short-circuits: a live mergeQueueEntry means "still in
# the queue", so the merge_group probe is not even reached. The runs fixture is
# a FAILING run on purpose — if the code wrongly queried channel 2 it would
# emit MERGE_GROUP_FAILED, and the QUEUED assertion would catch the regression.
_gate_gh() {
  case "$*" in
    *graphql*) echo '{"data":{"repository":{"pullRequest":{"state":"OPEN","merged":false,"mergedAt":null,"mergeQueueEntry":{"state":"QUEUED","position":1}}}}}' ;;
    *actions/runs*) echo '{"workflow_runs":[{"head_branch":"gh-readonly-queue/main/pr-42-abc","conclusion":"failure","status":"completed","id":1,"created_at":"2026-07-01T10:00:00Z"}]}' ;;
    *) echo '{}' ;;
  esac
}
rc=0; out="$(cmd_diagnose_queue Towheads/foundation 42)" || rc=$?
[ "$rc" -eq 0 ] || fail "QUEUED did not exit 0 (rc=$rc)"
[ "$(jq -r .outcome <<<"$out")" = "QUEUED" ] || fail "diagnose QUEUED outcome (got: $out)"
echo "PASS: diagnose-queue → QUEUED (still enqueued via mergeQueueEntry; merge_group NOT consulted)"

# --- diagnose-queue: not in queue + failed merge_group run → MERGE_GROUP_FAILED
_gate_gh() {
  case "$*" in
    *graphql*) echo '{"data":{"repository":{"pullRequest":{"state":"OPEN","merged":false,"mergedAt":null,"mergeQueueEntry":null}}}}' ;;
    *actions/runs*) echo '{"workflow_runs":[{"head_branch":"gh-readonly-queue/main/pr-42-abc123","conclusion":"failure","status":"completed","id":9001,"created_at":"2026-07-01T10:00:00Z"}]}' ;;
    *) echo '{}' ;;
  esac
}
rc=0; out="$(cmd_diagnose_queue Towheads/foundation 42)" || rc=$?
[ "$rc" -eq 7 ] || fail "MERGE_GROUP_FAILED did not exit 7 (rc=$rc)"
[ "$(jq -r .outcome <<<"$out")" = "MERGE_GROUP_FAILED" ] || fail "diagnose MERGE_GROUP_FAILED outcome (got: $out)"
[ "$(jq -r .run_id <<<"$out")" = "9001" ] || fail "diagnose failed run_id (got: $out)"
echo "PASS: diagnose-queue → MERGE_GROUP_FAILED (exit 7) + failed run id when the group CI failed"

# --- diagnose-queue: MERGE_GROUP_FAILED split via per-job step data (temperloop#1175) ---
# A workflow-defined step (any step AFTER the runner-provided "Set up job"
# step, keyed on the step's `number`, never its name) itself concluded
# "failure" → still MERGE_GROUP_FAILED (exit 7), the real-gate-failure case.
_gate_gh() {
  case "$*" in
    *graphql*) echo '{"data":{"repository":{"pullRequest":{"state":"OPEN","merged":false,"mergedAt":null,"mergeQueueEntry":null}}}}' ;;
    *actions/runs/9001/jobs*) echo '{"jobs":[{"id":1,"steps":[
        {"number":1,"name":"Set up job","conclusion":"success"},
        {"number":2,"name":"Run bash scripts/quality-gates.sh","conclusion":"failure"},
        {"number":3,"name":"Complete job","conclusion":"skipped"}]}]}' ;;
    *actions/runs*) echo '{"workflow_runs":[{"head_branch":"gh-readonly-queue/main/pr-42-abc123","conclusion":"failure","status":"completed","id":9001,"created_at":"2026-07-01T10:00:00Z"}]}' ;;
    *) echo '{}' ;;
  esac
}
rc=0; out="$(cmd_diagnose_queue Towheads/foundation 42)" || rc=$?
[ "$rc" -eq 7 ] || fail "real gate failure did not exit 7 (rc=$rc, out=$out)"
[ "$(jq -r .outcome <<<"$out")" = "MERGE_GROUP_FAILED" ] || fail "real gate failure outcome (got: $out)"
[ "$(jq -r .run_id <<<"$out")" = "9001" ] || fail "real gate failure run_id (got: $out)"
echo "PASS: diagnose-queue → MERGE_GROUP_FAILED (exit 7) when a workflow-defined step itself concluded failure"

# --- diagnose-queue: MERGE_GROUP_INFRA when the run never reached a workflow-
# defined step (temperloop#1175, foundation PR #1563) — a GitHub Actions infra
# hiccup during runner setup (e.g. "Set up job -> Failed to resolve action
# download info -> Service Unavailable"), never a log-text match: only the
# STRUCTURE (the sole recorded step is the runner-provided "Set up job" step,
# number 1) drives this.
_gate_gh() {
  case "$*" in
    *graphql*) echo '{"data":{"repository":{"pullRequest":{"state":"OPEN","merged":false,"mergedAt":null,"mergeQueueEntry":null}}}}' ;;
    *actions/runs/9002/jobs*) echo '{"jobs":[{"id":1,"steps":[
        {"number":1,"name":"Set up job","conclusion":"failure"}]}]}' ;;
    *actions/runs*) echo '{"workflow_runs":[{"head_branch":"gh-readonly-queue/main/pr-42-def456","conclusion":"failure","status":"completed","id":9002,"created_at":"2026-07-01T10:00:00Z"}]}' ;;
    *) echo '{}' ;;
  esac
}
rc=0; out="$(cmd_diagnose_queue Towheads/foundation 42)" || rc=$?
[ "$rc" -eq 11 ] || fail "MERGE_GROUP_INFRA did not exit 11 (rc=$rc, out=$out)"
[ "$(jq -r .outcome <<<"$out")" = "MERGE_GROUP_INFRA" ] || fail "diagnose MERGE_GROUP_INFRA outcome (got: $out)"
[ "$(jq -r .run_id <<<"$out")" = "9002" ] || fail "diagnose MERGE_GROUP_INFRA run_id (got: $out)"
echo "PASS: diagnose-queue → MERGE_GROUP_INFRA (exit 11) when the failing run never reached a workflow-defined step"

# --- diagnose-queue: unclassifiable per-job data stays the conservative
# MERGE_GROUP_FAILED default (never widens what gets retried) — the jobs
# lookup itself erroring is the representative unclassifiable case.
_gate_gh() {
  case "$*" in
    *graphql*) echo '{"data":{"repository":{"pullRequest":{"state":"OPEN","merged":false,"mergedAt":null,"mergeQueueEntry":null}}}}' ;;
    *actions/runs/9003/jobs*) return 1 ;;
    *actions/runs*) echo '{"workflow_runs":[{"head_branch":"gh-readonly-queue/main/pr-42-ghi789","conclusion":"failure","status":"completed","id":9003,"created_at":"2026-07-01T10:00:00Z"}]}' ;;
    *) echo '{}' ;;
  esac
}
rc=0; out="$(cmd_diagnose_queue Towheads/foundation 42)" || rc=$?
[ "$rc" -eq 7 ] || fail "unclassifiable jobs lookup did not fall back to exit 7 (rc=$rc, out=$out)"
[ "$(jq -r .outcome <<<"$out")" = "MERGE_GROUP_FAILED" ] || fail "unclassifiable jobs lookup fallback outcome (got: $out)"
[ "$(jq -r .run_id <<<"$out")" = "9003" ] || fail "unclassifiable jobs lookup fallback run_id (got: $out)"
echo "PASS: diagnose-queue → an erroring jobs lookup stays the conservative MERGE_GROUP_FAILED default"

# --- diagnose-queue: not in queue + no referencing run → DEQUEUED ------------
_gate_gh() {
  case "$*" in
    *graphql*) echo '{"data":{"repository":{"pullRequest":{"state":"OPEN","merged":false,"mergedAt":null,"mergeQueueEntry":null}}}}' ;;
    *actions/runs*) echo '{"workflow_runs":[]}' ;;
    *) echo '{}' ;;
  esac
}
rc=0; out="$(cmd_diagnose_queue Towheads/foundation 42)" || rc=$?
[ "$rc" -eq 8 ] || fail "DEQUEUED did not exit 8 (rc=$rc)"
[ "$(jq -r .outcome <<<"$out")" = "DEQUEUED" ] || fail "diagnose DEQUEUED outcome (got: $out)"
echo "PASS: diagnose-queue → DEQUEUED (exit 8) when the PR left the queue with no failing merge_group run"

# --- diagnose-queue: the /pr-<N>- anchor — #4 must NOT match a #42 run -------
# Same failing-#42 runs fixture, but we diagnose #4: the anchored substring
# `/pr-4-` must not match `.../pr-42-...`, so #4 reads DEQUEUED, not the #42
# failure (guards a pr-4 / pr-42 / pr-420 collision).
_gate_gh() {
  case "$*" in
    *graphql*) echo '{"data":{"repository":{"pullRequest":{"state":"OPEN","merged":false,"mergedAt":null,"mergeQueueEntry":null}}}}' ;;
    *actions/runs*) echo '{"workflow_runs":[{"head_branch":"gh-readonly-queue/main/pr-42-abc123","conclusion":"failure","status":"completed","id":9001,"created_at":"2026-07-01T10:00:00Z"}]}' ;;
    *) echo '{}' ;;
  esac
}
rc=0; out="$(cmd_diagnose_queue Towheads/foundation 4)" || rc=$?
[ "$rc" -eq 8 ] || fail "pr-4 matched a pr-42 run (anchoring bug!) rc=$rc"
[ "$(jq -r .outcome <<<"$out")" = "DEQUEUED" ] || fail "diagnose anchoring outcome (got: $out)"
echo "PASS: diagnose-queue → the /pr-<N>- anchor does not let #4 match a #42 merge_group run"

# --- diagnose-queue: in-progress referencing run → QUEUED (not a dequeue) ----
_gate_gh() {
  case "$*" in
    *graphql*) echo '{"data":{"repository":{"pullRequest":{"state":"OPEN","merged":false,"mergedAt":null,"mergeQueueEntry":null}}}}' ;;
    *actions/runs*) echo '{"workflow_runs":[{"head_branch":"gh-readonly-queue/main/pr-42-abc","conclusion":null,"status":"in_progress","id":9002,"created_at":"2026-07-01T10:00:00Z"}]}' ;;
    *) echo '{}' ;;
  esac
}
rc=0; out="$(cmd_diagnose_queue Towheads/foundation 42)" || rc=$?
[ "$rc" -eq 0 ] || fail "in-progress group did not exit 0 (rc=$rc)"
[ "$(jq -r .outcome <<<"$out")" = "QUEUED" ] || fail "diagnose in-progress QUEUED (got: $out)"
echo "PASS: diagnose-queue → QUEUED when a referencing merge_group run is still building (not a dequeue)"

# --- diagnose-queue: already merged (a race) → MERGED, probe short-circuited --
_gate_gh() {
  case "$*" in
    *graphql*) echo '{"data":{"repository":{"pullRequest":{"state":"MERGED","merged":true,"mergedAt":"2026-07-02T08:00:00Z","mergeQueueEntry":null}}}}' ;;
    *actions/runs*) echo '{"workflow_runs":[{"head_branch":"gh-readonly-queue/main/pr-42-x","conclusion":"failure","status":"completed","id":1,"created_at":"2026-07-01T10:00:00Z"}]}' ;;
    *) echo '{}' ;;
  esac
}
rc=0; out="$(cmd_diagnose_queue Towheads/foundation 42)" || rc=$?
[ "$rc" -eq 0 ] || fail "MERGED-race did not exit 0 (rc=$rc)"
[ "$(jq -r .outcome <<<"$out")" = "MERGED" ] || fail "diagnose MERGED-race outcome (got: $out)"
[ "$(jq -r .mergedAt <<<"$out")" = "2026-07-02T08:00:00Z" ] || fail "diagnose MERGED-race mergedAt (got: $out)"
echo "PASS: diagnose-queue → MERGED (exit 0) short-circuits the merge_group probe when the PR already landed"

# --- QUEUE_STALLED (temperloop#1178) ----------------------------------------
# The stall verdict ages the live queue entry against BUILD_QUEUE_STALL_AFTER and
# counts merge_group runs dispatched for it. Both inputs are pinned here — the
# clock via the `_gate_now` seam (expressed through `_gate_epoch_of` so the test
# never hardcodes an epoch integer), the run history via the `_gate_gh` fixture —
# so every case below is deterministic with ZERO network.
_gate_now() { _gate_epoch_of "2026-01-01T00:00:00Z"; }

# STALLED: enqueued an hour ago (past the threshold) and NO merge_group run has
# ever been dispatched for it — the exact shape the incident hand-probed.
_gate_gh() {
  case "$*" in
    *graphql*) echo '{"data":{"repository":{"pullRequest":{"state":"OPEN","merged":false,"mergedAt":null,"mergeQueueEntry":{"state":"QUEUED","position":1,"enqueuedAt":"2025-12-31T23:00:00Z"}}}}}' ;;
    *actions/runs*) echo '{"workflow_runs":[]}' ;;
    *) echo '{}' ;;
  esac
}
rc=0; out="$(cmd_diagnose_queue Towheads/foundation 42)" || rc=$?
[ "$rc" -eq 10 ] || fail "QUEUE_STALLED did not exit 10 (rc=$rc, out=$out)"
[ "$(jq -r .outcome <<<"$out")" = "QUEUE_STALLED" ] || fail "diagnose QUEUE_STALLED outcome (got: $out)"
[ "$(jq -r .enqueued_secs <<<"$out")" = "3600" ] || fail "QUEUE_STALLED enqueued_secs (got: $out)"
[ "$(jq -r .merge_group_runs <<<"$out")" = "0" ] || fail "QUEUE_STALLED merge_group_runs (got: $out)"
echo "PASS: diagnose-queue → QUEUE_STALLED (exit 10) + enqueued_secs/merge_group_runs when a long-enqueued PR has no merge_group run"

# HEALTHY (a): enqueued 2 minutes ago — inside the ~2.5 min a queue's own checks
# legitimately take. The runs fixture is EMPTY, i.e. the very state that reads
# STALLED once aged: only the threshold keeps this QUEUED, which is the point.
_gate_gh() {
  case "$*" in
    *graphql*) echo '{"data":{"repository":{"pullRequest":{"state":"OPEN","merged":false,"mergedAt":null,"mergeQueueEntry":{"state":"QUEUED","position":1,"enqueuedAt":"2025-12-31T23:58:00Z"}}}}}' ;;
    *actions/runs*) echo '{"workflow_runs":[]}' ;;
    *) echo '{}' ;;
  esac
}
rc=0; out="$(cmd_diagnose_queue Towheads/foundation 42)" || rc=$?
[ "$rc" -eq 0 ] || fail "under-threshold entry did not exit 0 (rc=$rc, out=$out)"
[ "$(jq -r .outcome <<<"$out")" = "QUEUED" ] || fail "under-threshold outcome (got: $out)"
echo "PASS: diagnose-queue → QUEUED under BUILD_QUEUE_STALL_AFTER (the legitimate ~2.5 min check window never trips the stall verdict)"

# HEALTHY (b): long-enqueued but the queue HAS dispatched a merge_group run for
# it (still building) — a slow queue, not a stalled one.
_gate_gh() {
  case "$*" in
    *graphql*) echo '{"data":{"repository":{"pullRequest":{"state":"OPEN","merged":false,"mergedAt":null,"mergeQueueEntry":{"state":"QUEUED","position":1,"enqueuedAt":"2025-12-31T23:00:00Z"}}}}}' ;;
    *actions/runs*) echo '{"workflow_runs":[{"head_branch":"gh-readonly-queue/main/pr-42-abc","conclusion":null,"status":"in_progress","id":9100,"created_at":"2025-12-31T23:01:00Z"}]}' ;;
    *) echo '{}' ;;
  esac
}
rc=0; out="$(cmd_diagnose_queue Towheads/foundation 42)" || rc=$?
[ "$rc" -eq 0 ] || fail "long-enqueued PR with a merge_group run did not exit 0 (rc=$rc, out=$out)"
[ "$(jq -r .outcome <<<"$out")" = "QUEUED" ] || fail "run-present outcome (got: $out)"
echo "PASS: diagnose-queue → QUEUED when a long-enqueued PR HAS a dispatched merge_group run (slow, not stalled)"

# The threshold is the NAMED SETTING, not a literal: the SAME stalled fixture
# reads QUEUED when BUILD_QUEUE_STALL_AFTER is raised past the entry's age.
_gate_gh() {
  case "$*" in
    *graphql*) echo '{"data":{"repository":{"pullRequest":{"state":"OPEN","merged":false,"mergedAt":null,"mergeQueueEntry":{"state":"QUEUED","position":1,"enqueuedAt":"2025-12-31T23:00:00Z"}}}}}' ;;
    *actions/runs*) echo '{"workflow_runs":[]}' ;;
    *) echo '{}' ;;
  esac
}
rc=0; out="$(BUILD_QUEUE_STALL_AFTER=7200 cmd_diagnose_queue Towheads/foundation 42)" || rc=$?
[ "$rc" -eq 0 ] || fail "raised BUILD_QUEUE_STALL_AFTER did not suppress the stall (rc=$rc, out=$out)"
[ "$(jq -r .outcome <<<"$out")" = "QUEUED" ] || fail "raised-threshold outcome (got: $out)"
echo "PASS: diagnose-queue → the stall threshold is read from BUILD_QUEUE_STALL_AFTER (raising it turns the same fixture back into QUEUED)"

# --- poll: a TIMEOUT carries its REASON, not a bare `waited` count -----------
# Same never-terminal PR as the TIMEOUT case above, but the queue channels now
# describe a stalled entry: the deadline runs the same probe and the TIMEOUT
# payload names QUEUE_STALLED — "stop waiting" rather than "try again later".
_gate_gh() {
  case "$*" in
    *"pr view"*) echo '{"state":"OPEN","mergedAt":null,"mergeable":"MERGEABLE","mergeStateStatus":"BLOCKED"}' ;;
    *graphql*) echo '{"data":{"repository":{"pullRequest":{"state":"OPEN","merged":false,"mergedAt":null,"mergeQueueEntry":{"state":"QUEUED","position":1,"enqueuedAt":"2025-12-31T23:00:00Z"}}}}}' ;;
    *actions/runs*) echo '{"workflow_runs":[]}' ;;
    *) echo '{}' ;;
  esac
}
rc=0; out="$(cmd_poll Towheads/foundation 42 --interval 0.1 --timeout 0)" || rc=$?
[ "$rc" -eq 4 ] || fail "diagnosed TIMEOUT did not exit 4 (rc=$rc, out=$out)"
[ "$(jq -r .outcome <<<"$out")" = "TIMEOUT" ] || fail "poll TIMEOUT outcome (got: $out)"
[ "$(jq -r .reason <<<"$out")" = "QUEUE_STALLED" ] || fail "poll TIMEOUT reason (got: $out)"
[ "$(jq -r .diagnosis.enqueued_secs <<<"$out")" = "3600" ] || fail "poll TIMEOUT diagnosis payload (got: $out)"
# The stamp is the probe's WHOLE verdict, not just its outcome word: run the
# same probe directly under the same fixture and require byte-equal JSON.
probe=0; dq="$(cmd_diagnose_queue Towheads/foundation 42)" || probe=$?
[ "$probe" -eq 10 ] || fail "stalled probe did not exit 10 (rc=$probe, out=$dq)"
[ "$(jq -cS . <<<"$dq")" = "$(jq -cS .diagnosis <<<"$out")" ] \
  || fail "poll TIMEOUT.diagnosis is not the full diagnose-queue verdict (probe: $dq, got: $out)"
echo "PASS: poll → TIMEOUT carries the diagnose-queue reason (QUEUE_STALLED) and its whole verdict, not a bare waited count"

# --- poll: a HEALTHY-but-SLOW PR's TIMEOUT names QUEUED (temperloop#2055) ----
# The reproduction behind the raised BUILD_QUEUE_TIMEOUT ceiling
# (foundation#1908, 2026-09-15): a CLEAN PR whose queue entry is live and whose
# merge_group run IS building simply outran the clock, and merged moments
# later. The deadline still fires — but the stamp says which case it is:
# `reason: "QUEUED"` plus the FULL diagnosis object, including the
# `queueState` the incident hand-probed. That stamp is what makes an hour-wide
# ceiling safe to sit behind, so it is pinned here: a future change that
# dropped it back to a bare `waited` count would turn every TIMEOUT back into
# an unreadable verdict.
_gate_gh() {
  case "$*" in
    *"pr view"*) echo '{"state":"OPEN","mergedAt":null,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}' ;;
    *graphql*) echo '{"data":{"repository":{"pullRequest":{"state":"OPEN","merged":false,"mergedAt":null,"mergeQueueEntry":{"state":"AWAITING_CHECKS","position":1,"enqueuedAt":"2025-12-31T23:00:00Z"}}}}}' ;;
    *actions/runs*) echo '{"workflow_runs":[{"head_branch":"gh-readonly-queue/main/pr-42-abc","conclusion":null,"status":"in_progress","id":9100,"created_at":"2025-12-31T23:01:00Z"}]}' ;;
    *) echo '{}' ;;
  esac
}
rc=0; out="$(cmd_poll Towheads/foundation 42 --interval 0.1 --timeout 0)" || rc=$?
[ "$rc" -eq 4 ] || fail "QUEUED-reason TIMEOUT did not exit 4 (rc=$rc, out=$out)"
[ "$(jq -r .outcome <<<"$out")" = "TIMEOUT" ] || fail "poll TIMEOUT outcome (got: $out)"
[ "$(jq -r .reason <<<"$out")" = "QUEUED" ] || fail "poll TIMEOUT reason should name QUEUED (got: $out)"
[ "$(jq -r .diagnosis.queueState <<<"$out")" = "AWAITING_CHECKS" ] \
  || fail "poll TIMEOUT diagnosis lost the queueState the incident read (got: $out)"
probe=0; dq="$(cmd_diagnose_queue Towheads/foundation 42)" || probe=$?
[ "$probe" -eq 0 ] || fail "healthy-slow probe did not exit 0 (rc=$probe, out=$dq)"
[ "$(jq -cS . <<<"$dq")" = "$(jq -cS .diagnosis <<<"$out")" ] \
  || fail "poll TIMEOUT.diagnosis is not the full diagnose-queue verdict (probe: $dq, got: $out)"
echo "PASS: poll → TIMEOUT on a healthy-but-slow PR names QUEUED and carries the whole diagnose-queue verdict"

# Fail-open: when the diagnose probe itself errors, the TIMEOUT keeps its
# pre-existing bare shape (outcome + waited, exit 4) and never leaks an ERROR.
_gate_gh() {
  case "$*" in
    *"pr view"*) echo '{"state":"OPEN","mergedAt":null,"mergeable":"MERGEABLE","mergeStateStatus":"BLOCKED"}' ;;
    *) return 1 ;;
  esac
}
rc=0; out="$(cmd_poll Towheads/foundation 42 --interval 0.1 --timeout 0)" || rc=$?
[ "$rc" -eq 4 ] || fail "fail-open TIMEOUT did not exit 4 (rc=$rc, out=$out)"
[ "$(jq -r .outcome <<<"$out")" = "TIMEOUT" ] || fail "fail-open TIMEOUT outcome (got: $out)"
[ "$(jq -r '.reason // "none"' <<<"$out")" = "none" ] || fail "fail-open TIMEOUT should carry no reason (got: $out)"
echo "PASS: poll → a failing diagnose probe leaves the bare TIMEOUT shape untouched (fail-open, still exit 4)"

_gate_now() { date +%s; }

# --- error: bad inputs → structured ERROR + non-zero exit -------------------
# die() emits on fd 3 (the script's real-stdout seam); when sourced, fd 3 is the
# test's stdout, so capture it back into the command substitution with 3>&1.
rc=0; out="$( (cmd_read not-a-repo 42) 3>&1 2>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] && [ "$(jq -r .outcome <<<"$out")" = "ERROR" ] \
  || fail "bad owner/repo not structured ERROR (got: $out)"
rc=0; out="$( (cmd_read Towheads/foundation abc) 3>&1 2>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] && [ "$(jq -r .outcome <<<"$out")" = "ERROR" ] \
  || fail "bad pr not structured ERROR (got: $out)"
echo "PASS: bad owner/repo or pr → structured ERROR + non-zero exit"

# --- backend: auto probe, merge_queue rule present → NATIVE -----------------
# _gate_gh here stands in for `gh api ... --jq '...'`, so the fixture emits the
# ALREADY-PROJECTED boolean the real --jq would produce (same style as the
# cmd_strict fixtures above), not the raw rules array.
unset BUILD_MERGE_BACKEND
_gate_gh() { echo "true"; }
out="$(cmd_backend Towheads/foundation)"
[ "$(jq -r .outcome <<<"$out")" = "NATIVE" ] || fail "merge_queue rule present not NATIVE (got: $out)"
echo "PASS: backend → NATIVE when the branch ruleset carries a merge_queue rule"

# --- backend: auto probe, merge_queue rule absent → MANAGED ------------------
_gate_gh() { echo "false"; }
out="$(cmd_backend Towheads/foundation)"
[ "$(jq -r .outcome <<<"$out")" = "MANAGED" ] || fail "no merge_queue rule not MANAGED (got: $out)"
[ "$(jq -r 'has("probe_failed")' <<<"$out")" = "false" ] || fail "clean MANAGED should not carry probe_failed (got: $out)"
echo "PASS: backend → MANAGED when the branch ruleset has no merge_queue rule"

# --- backend: probe error (gh non-zero / empty) → MANAGED + probe_failed:true
_gate_gh() { return 1; }
out="$(cmd_backend Towheads/foundation)"
[ "$(jq -r .outcome <<<"$out")" = "MANAGED" ] || fail "probe error not MANAGED (got: $out)"
[ "$(jq -r .probe_failed <<<"$out")" = "true" ] || fail "probe error missing probe_failed:true (got: $out)"
echo "PASS: backend → MANAGED + probe_failed:true on a probe error (fail-safe direction)"

# --- backend: explicit override wins WITHOUT probing -------------------------
_gate_gh() { fail "gh called under an explicit BUILD_MERGE_BACKEND override (should short-circuit)"; }
BUILD_MERGE_BACKEND=native out="$(BUILD_MERGE_BACKEND=native cmd_backend Towheads/foundation)"
[ "$(jq -r .outcome <<<"$out")" = "NATIVE" ] || fail "override=native not NATIVE (got: $out)"
echo "PASS: backend → NATIVE on BUILD_MERGE_BACKEND=native, no probe call"

out="$(BUILD_MERGE_BACKEND=managed cmd_backend Towheads/foundation)"
[ "$(jq -r .outcome <<<"$out")" = "MANAGED" ] || fail "override=managed not MANAGED (got: $out)"
[ "$(jq -r 'has("probe_failed")' <<<"$out")" = "false" ] || fail "override MANAGED should not carry probe_failed (got: $out)"
echo "PASS: backend → MANAGED on BUILD_MERGE_BACKEND=managed, no probe call"
unset BUILD_MERGE_BACKEND

# --- managed-merge: green STRICT path ----------------------------------------
# update-branch called → new head sha resolved → SHA-pinned CI re-poll GREEN →
# merge → confirmed MERGED. Zero-delay poll settings (mirrors GATE_REPOLL_DELAY).
export GATE_CI_POLL_INTERVAL=0 GATE_CI_POLL_TIMEOUT=5
export GATE_MERGE_POLL_INTERVAL=0 GATE_MERGE_POLL_TIMEOUT=5
rm -f "$TMP/mm_calls"
_gate_gh() {
  local -a a=("$@")
  echo "$*" >> "$TMP/mm_calls"
  case "${a[0]:-} ${a[1]:-}" in
    "pr update-branch") return 0 ;;
    "pr view")
      local field="" k
      for ((k=0; k<${#a[@]}; k++)); do [ "${a[$k]}" = "--json" ] && field="${a[$((k+1))]}"; done
      case "$field" in
        headRefOid) echo "deadbeef1" ;;
        state,mergedAt,mergeable,mergeStateStatus)
          echo '{"state":"MERGED","mergedAt":"2026-07-04T00:00:00Z","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}' ;;
        *) echo "{}" ;;
      esac
      return 0 ;;
    "pr merge") return 0 ;;
    "run list") echo "[]"; return 0 ;;
    *)
      if [ "${a[0]:-}" = "api" ]; then
        echo '[{"status":"completed","conclusion":"success"}]'
      fi ;;
  esac
}
out="$(cmd_managed_merge Towheads/foundation 42)"
[ "$(jq -r .outcome <<<"$out")" = "MERGED" ] || fail "managed-merge green-strict outcome (got: $out)"
[ "$(jq -r .mergedAt <<<"$out")" = "2026-07-04T00:00:00Z" ] || fail "managed-merge green-strict mergedAt (got: $out)"
grep -q "^pr update-branch " "$TMP/mm_calls" || fail "managed-merge strict did not call update-branch"
echo "PASS: managed-merge (strict, default) → update-branch + SHA-pinned CI re-poll + merge + confirmed MERGED"

# --- managed-merge: green NON-STRICT path ------------------------------------
# --non-strict must NEVER call update-branch (or the CI re-poll) — straight to
# merge → confirmed MERGED, preserving a non-strict repo's immediate-merge
# cost profile.
rm -f "$TMP/mm_calls"
_gate_gh() {
  local -a a=("$@")
  echo "$*" >> "$TMP/mm_calls"
  case "${a[0]:-} ${a[1]:-}" in
    "pr update-branch") fail "update-branch called under --non-strict (must be skipped entirely)" ;;
    "pr view")
      echo '{"state":"MERGED","mergedAt":"2026-07-04T01:00:00Z","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}'
      return 0 ;;
    "pr merge") return 0 ;;
  esac
  case "${a[0]:-}" in
    api) fail "CI re-poll (gh api) called under --non-strict (must be skipped entirely)" ;;
  esac
}
out="$(cmd_managed_merge Towheads/foundation 42 --non-strict)"
[ "$(jq -r .outcome <<<"$out")" = "MERGED" ] || fail "managed-merge green-non-strict outcome (got: $out)"
! grep -q "update-branch" "$TMP/mm_calls" || fail "managed-merge non-strict seam saw update-branch"
! grep -q "^api" "$TMP/mm_calls" || fail "managed-merge non-strict seam saw a CI re-poll call"
echo "PASS: managed-merge --non-strict → NO update-branch, NO CI re-poll, straight to merge + confirmed MERGED"

# --- managed-merge: CI red after update-branch → EJECTED, no merge attempted
rm -f "$TMP/mm_calls"
_gate_gh() {
  local -a a=("$@")
  echo "$*" >> "$TMP/mm_calls"
  case "${a[0]:-} ${a[1]:-}" in
    "pr update-branch") return 0 ;;
    "pr view")
      local field="" k
      for ((k=0; k<${#a[@]}; k++)); do [ "${a[$k]}" = "--json" ] && field="${a[$((k+1))]}"; done
      case "$field" in
        headRefOid) echo "deadbeef2" ;;
        *) echo "{}" ;;
      esac
      return 0 ;;
    "pr merge") fail "merge attempted after CI red on the updated head (eject must not merge)" ;;
    "run list") echo "[987]"; return 0 ;;
  esac
  case "${a[0]:-}" in
    api) echo '[{"status":"completed","conclusion":"failure"}]' ;;
  esac
}
rc=0; out="$(cmd_managed_merge Towheads/foundation 42)" || rc=$?
[ "$rc" -eq 5 ] || fail "managed-merge eject did not exit 5 (rc=$rc)"
[ "$(jq -r .outcome <<<"$out")" = "EJECTED" ] || fail "managed-merge eject outcome (got: $out)"
[ "$(jq -c .failed_run_ids <<<"$out")" = "[987]" ] || fail "managed-merge eject failed_run_ids (got: $out)"
! grep -q "^pr merge " "$TMP/mm_calls" || fail "managed-merge eject seam saw a merge call"
echo "PASS: managed-merge → CI red after update-branch → EJECTED (exit 5), failed_run_ids surfaced, no merge attempted"

# --- managed-merge: CI re-poll times out → TIMEOUT (exit 4), not die() -------
# The SHA-pinned CI re-poll runs out its deadline with checks still pending
# (never completing). Per gate.sh's header exit-code contract this is the
# TIMEOUT/exit-4 outcome — NOT the ERROR/exit-1 a die() would emit — and no
# merge is attempted (temperloop#23). GATE_CI_POLL_TIMEOUT=0 makes the deadline
# fire on the first (still-pending) poll so the test needs no real wait.
rm -f "$TMP/mm_calls"
export GATE_CI_POLL_TIMEOUT=0
_gate_gh() {
  local -a a=("$@")
  echo "$*" >> "$TMP/mm_calls"
  case "${a[0]:-} ${a[1]:-}" in
    "pr update-branch") return 0 ;;
    "pr view")
      local field="" k
      for ((k=0; k<${#a[@]}; k++)); do [ "${a[$k]}" = "--json" ] && field="${a[$((k+1))]}"; done
      case "$field" in
        headRefOid) echo "deadbeef3" ;;
        *) echo "{}" ;;
      esac
      return 0 ;;
    "pr merge") fail "merge attempted after CI re-poll TIMEOUT (timeout must not merge)" ;;
  esac
  case "${a[0]:-}" in
    # check-runs still pending → _gate_ci_poll never sees all-completed → TIMEOUT
    api) echo '[{"status":"in_progress","conclusion":null}]' ;;
  esac
}
rc=0; out="$(cmd_managed_merge Towheads/foundation 42)" || rc=$?
[ "$rc" -eq 4 ] || fail "managed-merge CI re-poll timeout did not exit 4 (rc=$rc, out=$out)"
[ "$(jq -r .outcome <<<"$out")" = "TIMEOUT" ] || fail "managed-merge CI-timeout outcome (got: $out)"
[ "$(jq -r .pr <<<"$out")" = "42" ] || fail "managed-merge CI-timeout pr field (got: $out)"
jq -e 'has("waited")' <<<"$out" >/dev/null || fail "managed-merge CI-timeout missing waited (got: $out)"
! grep -q "^pr merge " "$TMP/mm_calls" || fail "managed-merge CI-timeout seam saw a merge call"
export GATE_CI_POLL_TIMEOUT=5
echo "PASS: managed-merge → CI re-poll timeout → TIMEOUT (exit 4, not die/ERROR), no merge attempted"

# --- managed-merge: gh pr merge itself rejected (e.g. queue-armed repo) ------
# --non-strict path (fewer preconditions) with the merge call itself failing —
# a distinct, non-silent MERGE_REJECTED outcome rather than a bare ERROR.
_gate_gh() {
  local -a a=("$@")
  case "${a[0]:-} ${a[1]:-}" in
    "pr merge") echo "GraphQL: Pull request is not mergeable via the UI or API (mergePullRequest)"; return 1 ;;
  esac
  echo "{}"
}
rc=0; out="$(cmd_managed_merge Towheads/foundation 42 --non-strict)" || rc=$?
[ "$rc" -eq 6 ] || fail "managed-merge merge-rejected did not exit 6 (rc=$rc)"
[ "$(jq -r .outcome <<<"$out")" = "MERGE_REJECTED" ] || fail "managed-merge merge-rejected outcome (got: $out)"
jq -e '.error | test("not mergeable")' <<<"$out" >/dev/null \
  || fail "managed-merge merge-rejected error message not surfaced (got: $out)"
echo "PASS: managed-merge → a merge the platform itself rejects surfaces as MERGE_REJECTED (exit 6), not silently"
unset GATE_CI_POLL_INTERVAL GATE_CI_POLL_TIMEOUT GATE_MERGE_POLL_INTERVAL GATE_MERGE_POLL_TIMEOUT

# --- no-behavior-change-on-native guarantee: an existing subcommand's JSON is
# BYTE-IDENTICAL after adding managed-merge (acceptance criterion 3) ---------
_gate_gh() { echo "true"; }
out="$(cmd_strict Towheads/foundation)"
[ "$out" = '{"outcome":"STRICT"}' ] \
  || fail "cmd_strict output changed byte-for-byte after adding managed-merge (got: $out)"
echo "PASS: cmd_strict output is byte-identical after adding managed-merge (no behavior change on existing subcommands)"

echo "ALL GATE TESTS PASSED"
