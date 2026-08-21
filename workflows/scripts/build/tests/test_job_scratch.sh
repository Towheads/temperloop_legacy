#!/usr/bin/env bash
#
# Tests for the background-job scratch retention policy (temperloop#1111):
#   workflows/scripts/build/lib/job-scratch.sh      (sourced classifier)
#   workflows/scripts/build/job-scratch-reclaim.sh  (dry-run/--apply CLI)
#
# Fixture style matches the sibling build-toolkit suites: a throwaway jobs root
# in a tmpdir, fully hermetic (JOB_SCRATCH_ROOT is pinned at the fixture on
# every invocation, so the running host's real ~/.claude/jobs is never read and
# never touched), zero network.
#
# Covered — one case per state the classifier distinguishes:
#   classifier
#     - terminal + aged + oversize            -> JOB_SCRATCH_RECLAIMABLE
#     - terminal + aged + UNDER the floor     -> silent
#     - terminal + oversize but INSIDE grace  -> silent
#     - non-terminal (`blocked`) + aged       -> JOB_SCRATCH_ABANDONED
#     - state.json absent entirely            -> JOB_SCRATCH_ABANDONED:…:unknown
#     - no tmp/ at all                        -> silent
#     - symlinked tmp/                        -> silent (never followed)
#     - jq absent (PATH without it)           -> same verdicts via the fallback
#   reclaimer
#     - dry-run deletes NOTHING
#     - --apply deletes reclaimable tmp/ and KEEPS state.json + timeline.jsonl
#     - --apply never touches an ABANDONED job's tmp/
#     - refuses $HOME / `/` as a sweep root (exit 2, no deletion)
#     - absent root -> exit 0, "nothing to sweep"
set -euo pipefail

BUILD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$BUILD_DIR/job-scratch-reclaim.sh"
LIB="$BUILD_DIR/lib/job-scratch.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }
ok() { echo "PASS: $1"; }

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# ── Fixture builder ──────────────────────────────────────────────────────────
# mkjob <id> <state-or-NONE> <mb> <aged|fresh>
mkjob() {
  local id="$1" state="$2" mb="$3" age="$4"
  local d="$JOBS/$id"
  mkdir -p "$d/tmp"
  if [ "$state" != "NONE" ]; then
    printf '{\n  "state": "%s",\n  "children": [ { "state": "running" } ]\n}\n' "$state" > "$d/state.json"
  fi
  printf '{"t":"start"}\n' > "$d/timeline.jsonl"
  if [ "$mb" -gt 0 ]; then
    dd if=/dev/zero of="$d/tmp/blob" bs=1024 count=$((mb * 1024)) 2>/dev/null
  fi
  if [ "$age" = "aged" ]; then
    if [ -f "$d/state.json" ]; then
      touch -t 202001010000 "$d/state.json"
    fi
    # The directory mtime is the fallback last-activity signal when there is no
    # state.json at all, so age it last (writing inside it bumps it again).
    touch -t 202001010000 "$d" 2>/dev/null || true
  fi
  return 0
}

JOBS="$TMP/jobs"
mkdir -p "$JOBS"

mkjob reclaim-me    "done"    2 aged      # terminal, aged, oversize
mkjob too-small     "done"    0 aged      # terminal, aged, under the floor
mkjob still-fresh   "done"    2 fresh     # terminal, oversize, inside grace
mkjob blocked-job   blocked 2 aged      # NOT terminal — awaiting an operator
mkjob no-state      NONE    2 aged      # state unreadable
mkjob no-tmp        "done"    0 aged      # no scratch worth naming
rmdir "$JOBS/no-tmp/tmp"

# A symlinked tmp/ must never be followed: the reclaimer would otherwise be
# aimable at an arbitrary path by a planted link.
mkdir -p "$TMP/decoy"; printf 'precious\n' > "$TMP/decoy/keep.txt"
mkdir -p "$JOBS/symlinked"
printf '{\n  "state": "done"\n}\n' > "$JOBS/symlinked/state.json"
touch -t 202001010000 "$JOBS/symlinked/state.json"
ln -s "$TMP/decoy" "$JOBS/symlinked/tmp"

# Pinned for every invocation below (hermetic: the real ~/.claude/jobs is never
# consulted). MIN_MB=1 so the 2MB fixtures clear the floor.
ENVPIN=(JOB_SCRATCH_ROOT="$JOBS" JOB_SCRATCH_MIN_MB=1 JOB_SCRATCH_GRACE_DAYS=1 JOB_SCRATCH_ABANDONED_DAYS=14)

# ── Classifier ───────────────────────────────────────────────────────────────
classify() {
  # Single quotes are deliberate: $1/$2 are the inner shell's positional args
  # (passed after the `_`), not this shell's.
  # shellcheck disable=SC2016
  env "${ENVPIN[@]}" bash -c 'source "$1"; job_scratch_classify "$2"' _ "$LIB" "$JOBS/$1"
}

[ "$(classify reclaim-me)" = "JOB_SCRATCH_RECLAIMABLE:reclaim-me:2MB:done" ] \
  || fail "terminal+aged+oversize should be RECLAIMABLE, got: $(classify reclaim-me)"
ok "terminal + aged + oversize -> JOB_SCRATCH_RECLAIMABLE"

[ -z "$(classify too-small)" ] || fail "under the floor should be silent, got: $(classify too-small)"
ok "terminal + aged + under the size floor -> silent"

[ -z "$(classify still-fresh)" ] || fail "inside grace should be silent, got: $(classify still-fresh)"
ok "terminal + oversize but inside the grace window -> silent"

[ "$(classify blocked-job)" = "JOB_SCRATCH_ABANDONED:blocked-job:2MB:blocked" ] \
  || fail "a blocked job is NOT terminal and must be ABANDONED, got: $(classify blocked-job)"
ok "non-terminal (blocked) + aged -> JOB_SCRATCH_ABANDONED (never reclaimable)"

[ "$(classify no-state)" = "JOB_SCRATCH_ABANDONED:no-state:2MB:unknown" ] \
  || fail "an unreadable state must fail SAFE (ABANDONED, not RECLAIMABLE), got: $(classify no-state)"
ok "state.json absent -> JOB_SCRATCH_ABANDONED:…:unknown (fails safe)"

[ -z "$(classify no-tmp)" ] || fail "a job with no tmp/ should be silent, got: $(classify no-tmp)"
ok "no tmp/ at all -> silent"

[ -z "$(classify symlinked)" ] || fail "a symlinked tmp/ must be skipped, got: $(classify symlinked)"
ok "symlinked tmp/ -> silent (never followed)"

# The jq-less host must reach the SAME verdicts through the sed fallback — a
# missing dependency silently disabling the sweep is precisely the failure mode
# this whole item exists to close.
NOJQ="$TMP/nojq-bin"; mkdir -p "$NOJQ"
for c in bash sed awk du stat date basename find sort dd env printf; do
  p="$(command -v "$c" 2>/dev/null)" && ln -sf "$p" "$NOJQ/$c"
done
# Prove the sandbox really has no jq before trusting the verdict it produces —
# otherwise this case could pass while still going through jq.
if env -i "PATH=$NOJQ" bash -c 'command -v jq' >/dev/null 2>&1; then
  fail "no-jq fixture still resolves jq on PATH — the fallback was not exercised"
fi
# shellcheck disable=SC2016  # inner shell's positional args, as in classify()
nojq_verdict="$(env -i "HOME=$HOME" "PATH=$NOJQ" "${ENVPIN[@]}" \
  bash -c 'source "$1"; job_scratch_classify "$2"' _ "$LIB" "$JOBS/reclaim-me")"
[ "$nojq_verdict" = "JOB_SCRATCH_RECLAIMABLE:reclaim-me:2MB:done" ] \
  || fail "without jq the sed fallback must still read the state, got: $nojq_verdict"
ok "no jq on PATH -> same verdict via the sed fallback"

# ── Reclaimer: dry-run changes nothing ───────────────────────────────────────
dry="$(env "${ENVPIN[@]}" bash "$CLI")"
grep -q "WOULD-RECLAIM" <<<"$dry" || fail "dry-run should name what it would reclaim; got:
$dry"
grep -q "DRY-RUN: 1 job(s) reclaimable" <<<"$dry" || fail "dry-run summary wrong; got:
$dry"
[ -f "$JOBS/reclaim-me/tmp/blob" ] || fail "DRY-RUN DELETED SCRATCH — it must change nothing"
ok "dry-run reports but deletes nothing"

# ── Reclaimer: --apply ───────────────────────────────────────────────────────
applied="$(env "${ENVPIN[@]}" bash "$CLI" --apply)"
grep -q "RECLAIMED: 1 job(s)" <<<"$applied" || fail "--apply summary wrong; got:
$applied"

[ ! -e "$JOBS/reclaim-me/tmp" ] || fail "--apply did not remove the reclaimable tmp/"
ok "--apply removes a reclaimable job's tmp/"

[ -f "$JOBS/reclaim-me/state.json" ] && [ -f "$JOBS/reclaim-me/timeline.jsonl" ] \
  || fail "--apply destroyed the run RECORD; state.json/timeline.jsonl must survive"
ok "--apply keeps the run record (state.json + timeline.jsonl)"

[ -f "$JOBS/blocked-job/tmp/blob" ] || fail "--apply deleted a NON-TERMINAL job's scratch"
[ -f "$JOBS/no-state/tmp/blob" ]    || fail "--apply deleted an UNKNOWN-state job's scratch"
ok "--apply never touches an ABANDONED (non-terminal / unknown-state) job"

[ -f "$JOBS/still-fresh/tmp/blob" ] || fail "--apply deleted scratch still inside its grace window"
[ -f "$TMP/decoy/keep.txt" ]        || fail "--apply followed a symlinked tmp/ and deleted its target"
[ -L "$JOBS/symlinked/tmp" ]        || fail "--apply removed the tmp/ symlink itself"
ok "--apply respects the grace window and never follows a symlinked tmp/"

# Idempotent: a second --apply has nothing left to do and still exits 0.
again="$(env "${ENVPIN[@]}" bash "$CLI" --apply)"
grep -q "RECLAIMED: 0 job(s)" <<<"$again" || fail "second --apply should be a no-op; got:
$again"
ok "--apply is idempotent (second run reclaims 0)"

# ── Guards ───────────────────────────────────────────────────────────────────
rc=0
guard_out="$(JOB_SCRATCH_ROOT="$HOME" bash "$CLI" --apply 2>&1)" || rc=$?
[ "$rc" -eq 2 ] || fail "sweeping \$HOME must be refused with exit 2 (got $rc)"
grep -q "refusing to sweep root" <<<"$guard_out" || fail "refusal must say why; got: $guard_out"
ok "refuses to sweep \$HOME (exit 2, nothing deleted)"

rc=0
root_out="$(JOB_SCRATCH_ROOT="/" bash "$CLI" --apply 2>&1)" || rc=$?
[ "$rc" -eq 2 ] || fail "sweeping / must be refused with exit 2 (got $rc)"
grep -q "refusing to sweep root" <<<"$root_out" || fail "refusal must say why; got: $root_out"
ok "refuses to sweep / (exit 2, nothing deleted)"

rc=0
absent_out="$(JOB_SCRATCH_ROOT="$TMP/no-such-jobs-root" bash "$CLI" --apply)" || rc=$?
[ "$rc" -eq 0 ] || fail "an absent job root must exit 0, not fail the drain (got $rc)"
grep -q "nothing to sweep" <<<"$absent_out" || fail "absent root should say so; got: $absent_out"
ok "absent job root -> exit 0, nothing to sweep (fail-open)"

rc=0
env "${ENVPIN[@]}" bash "$CLI" --bogus-flag >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "an unknown flag must exit 2 (got $rc)"
ok "unknown flag -> exit 2"

echo "ALL PASS: test_job_scratch.sh"
