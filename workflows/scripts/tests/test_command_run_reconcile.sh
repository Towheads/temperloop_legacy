#!/usr/bin/env bash
#
# test_command_run_reconcile.sh — tests for the command-run stream's
# RUN-ID + RECONCILIATION property (temperloop#2220): "the stream reduces to
# exactly one record per run."
#
# Covers workflows/scripts/emit-command-run.sh's `run_id` field and open
# ledger, and workflows/scripts/validate-command-run-reconcile.sh, the guard
# that asserts the property.
#
# THE TWO HALVES, because the property breaks in BOTH directions and a
# half-guard is worth nothing:
#
#   A. DUPLICATE — one run, several records. Section 1 replays the REAL
#      two-record shape quoted in temperloop#2220's body: it reduces to TWO
#      items without a run id (the defect, reproduced) and to exactly ONE
#      merged item with one (the fix), with no already-written line rewritten
#      or backfilled in either case.
#   B. MISSING — one run, no record. Section 3 replays the inverse failure the
#      same session produced: a run that started and never emitted. A guard
#      written for the duplicate half alone passes straight through it, so it
#      is asserted red here explicitly.
#
# Every assertion is shown DISCRIMINATING: each red case has a green twin
# differing only in the thing the fix changes.
#
# Synthetic lake under a throwaway tmpdir (CMD_RUN_RAW_DIR / --raw-dir).
# Zero network; never writes outside the tmpdir.

set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -P "$HERE/../../.." && pwd)"
EMIT="$REPO/workflows/scripts/emit-command-run.sh"
RECON="$REPO/workflows/scripts/validate-command-run-reconcile.sh"
LINT="$REPO/workflows/scripts/validate-command-run-emit.sh"
README="$REPO/meta/data/raw/README.md"
FIX_MD="$REPO/claude/commands/fix.md"
SWEEP_MD="$REPO/claude/commands/sweep.md"
TRIAGE_MD="$REPO/claude/commands/triage.md"

[ -f "$EMIT" ]  || { echo "FATAL: emit-command-run.sh not found at $EMIT" >&2; exit 1; }
[ -f "$RECON" ] || { echo "FATAL: validate-command-run-reconcile.sh not found at $RECON" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required for this test" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/command-run-reconcile-test.XXXXXX")"
trap 'chmod -R u+rwX "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s: %s\n' "$1" "$2"; }
check_eq() { # <desc> <want> <got>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want [$2], got [$3]"; fi
}
grep_ok() { # <desc> <needle> <file>
  if grep -Fq -- "$2" "$3"; then ok "$1"; else bad "$1" "missing [$2] in $3"; fi
}

# recon <args…> → sets RECON_OUT / RECON_RC
recon() {
  RECON_OUT="$(bash "$RECON" "$@" 2>&1)"
  RECON_RC=$?
}

# THE REAL TWO-RECORD SHAPE, verbatim from temperloop#2220's body: one /fix
# run driving K#2208, parked at the merge gate at 18:35 and merged at 19:31.
LEGACY_PARK='{"ts":"2026-09-23T18:35:36Z","session_id":"2c46ec51-0000-0000-0000-000000000000","command":"fix","board":7,"items_processed":1,"merged":0,"resolved":0,"parked":1,"reported_no_op":0}'
LEGACY_MERGE='{"ts":"2026-09-23T19:31:04Z","session_id":"2c46ec51-0000-0000-0000-000000000000","command":"fix","board":7,"items_processed":1,"merged":1,"resolved":0,"parked":0,"reported_no_op":0}'

echo "── 1. criterion 1: the real two-record shape reduces to exactly one merged item ──"

# 1a. UNFIXED: the two lines exactly as they were written, with no run id.
L1="$TMP/legacy"; mkdir -p "$L1"
printf '%s\n%s\n' "$LEGACY_PARK" "$LEGACY_MERGE" > "$L1/command-runs-2026-09.jsonl"
recon --raw-dir "$L1" --reduce
check_eq "UNFIXED: the issue's two lines reduce to TWO runs (the double count)" \
  "2" "$(printf '%s\n' "$RECON_OUT" | jq -s 'length')"
check_eq "UNFIXED: those two runs sum to items_processed=2 for one real item" \
  "2" "$(printf '%s\n' "$RECON_OUT" | jq -s '[.[].items_processed] | add')"

# 1b. FIXED: the SAME two records as the emitter now writes them — same ts,
#     same counts, same order; the ONLY difference is the shared run_id.
L2="$TMP/fixed"; mkdir -p "$L2"
printf '%s\n%s\n' \
  "$(printf '%s' "$LEGACY_PARK"  | jq -c '. + {run_id:"run-20260923T183536Z-aaaabbbb"}')" \
  "$(printf '%s' "$LEGACY_MERGE" | jq -c '. + {run_id:"run-20260923T183536Z-aaaabbbb"}')" \
  > "$L2/command-runs-2026-09.jsonl"
recon --raw-dir "$L2" --reduce
check_eq "FIXED: the same two lines reduce to exactly ONE run" \
  "1" "$(printf '%s\n' "$RECON_OUT" | jq -s 'length')"
check_eq "FIXED: that one run reports items_processed=1" \
  "1" "$(printf '%s\n' "$RECON_OUT" | jq -r '.items_processed')"
check_eq "FIXED: its disposition is merged, not parked" \
  "1 0" "$(printf '%s\n' "$RECON_OUT" | jq -r '"\(.merged) \(.parked)"')"
check_eq "FIXED: the reduction reports it collapsed 2 records" \
  "2" "$(printf '%s\n' "$RECON_OUT" | jq -r '.records')"
check_eq "FIXED: nothing was backfilled — both original lines are still on disk, unchanged" \
  "2" "$(wc -l < "$L2/command-runs-2026-09.jsonl" | tr -d ' ')"
if grep -Fq '"parked":1' "$L2/command-runs-2026-09.jsonl"; then
  ok "FIXED: the superseded park line is preserved verbatim (append-only, never retracted)"
else
  bad "FIXED: the superseded park line is preserved verbatim" "the park record was rewritten"
fi

echo "── 2. end-to-end: --open → park emit → merge emit, through the real script ──"
E2E="$TMP/e2e"; mkdir -p "$E2E"
RID="$(CMD_RUN_RAW_DIR="$E2E" CLAUDE_CODE_SESSION_ID=sess-e2e bash "$EMIT" --open --command fix --board 7 2>/dev/null)"
case "$RID" in run-*) ok "--open prints a run id" ;; *) bad "--open prints a run id" "got [$RID]" ;; esac
CMD_RUN_RAW_DIR="$E2E" CLAUDE_CODE_SESSION_ID=sess-e2e bash "$EMIT" --command fix --board 7 \
  --items-processed 1 --merged 0 --resolved 0 --parked 1 --reported-no-op 0 >/dev/null 2>&1
marker_count() { find "$1" -type f -name '*.json' 2>/dev/null | wc -l | tr -d ' '; }
check_eq "a parked record HOLDS the open marker (the run may still converge)" \
  "1" "$(marker_count "$E2E/command-run-open")"
check_eq "and bumps its emitted count, so the run is not read as missing" \
  "1" "$(jq -r '.emitted' "$E2E/command-run-open/"*.json 2>/dev/null)"
CMD_RUN_RAW_DIR="$E2E" CLAUDE_CODE_SESSION_ID=sess-e2e bash "$EMIT" --command fix --board 7 \
  --items-processed 1 --merged 1 --resolved 0 --parked 0 --reported-no-op 0 >/dev/null 2>&1
check_eq "the later merge emit ADOPTS the same run id without the caller carrying it" \
  "1" "$(jq -s '[.[].run_id] | unique | length' "$E2E"/command-runs-*.jsonl)"
check_eq "a terminal (nothing-parked) record CLOSES the marker" \
  "0" "$(marker_count "$E2E/command-run-open")"
recon --raw-dir "$E2E" --reduce
check_eq "the live park→merge run reduces to one merged item" \
  "1 1 1" "$(printf '%s\n' "$RECON_OUT" | jq -s -r '"\(length) \(.[0].items_processed) \(.[0].merged)"')"
recon --raw-dir "$E2E"
check_eq "and the guard is GREEN on it" "0" "$RECON_RC"

echo "── 3. criterion 2, MISSING half: a run that started and never emitted ──"
M1="$TMP/missing"; mkdir -p "$M1/command-run-open"
printf '%s\n' "$(printf '%s' "$LEGACY_MERGE" | jq -c '. + {run_id:"run-other", session_id:"sess-other"}')" \
  > "$M1/command-runs-2026-09.jsonl"
cat > "$M1/command-run-open/sess-missing__fix.json" <<'EOF'
{"run_id":"run-never-emitted","command":"fix","session_id":"sess-missing","board":7,"opened_at":"2026-09-23T06:16:52Z","opened_epoch":1,"emitted":0}
EOF
recon --raw-dir "$M1"
check_eq "RED on a run that opened and never emitted" "1" "$RECON_RC"
case "$RECON_OUT" in *MISSING-RUN*run-never-emitted*) ok "the failure names MISSING-RUN and the run id" ;;
  *) bad "the failure names MISSING-RUN and the run id" "got [$RECON_OUT]" ;; esac

# discrimination twin: the SAME marker, once the run does emit → green.
M2="$TMP/missing-fixed"; mkdir -p "$M2/command-run-open"
{ printf '%s\n' "$(printf '%s' "$LEGACY_MERGE" | jq -c '. + {run_id:"run-other", session_id:"sess-other"}')"
  printf '%s\n' "$(printf '%s' "$LEGACY_MERGE" | jq -c '. + {run_id:"run-never-emitted", session_id:"sess-missing"}')"; } \
  > "$M2/command-runs-2026-09.jsonl"
sed 's/"emitted":0/"emitted":1/' "$M1/command-run-open/sess-missing__fix.json" \
  > "$M2/command-run-open/sess-missing__fix.json"
recon --raw-dir "$M2"
check_eq "GREEN once that same run's record exists (the discriminating twin)" "0" "$RECON_RC"

# a marker claiming it emitted, whose record is nowhere in the stream, is
# still a missing run — `emitted` alone is not taken as proof.
M3="$TMP/missing-lost"; mkdir -p "$M3/command-run-open"
printf '%s\n' "$(printf '%s' "$LEGACY_MERGE" | jq -c '. + {run_id:"run-other", session_id:"sess-other"}')" \
  > "$M3/command-runs-2026-09.jsonl"
cp "$M2/command-run-open/sess-missing__fix.json" "$M3/command-run-open/sess-missing__fix.json"
recon --raw-dir "$M3"
check_eq "RED when a marker claims emitted=1 but no record carries its run id" "1" "$RECON_RC"

# an in-flight run (opened just now) is NOT a missing run.
M4="$TMP/inflight"; mkdir -p "$M4/command-run-open"
printf '%s\n' "$(printf '%s' "$LEGACY_MERGE" | jq -c '. + {run_id:"run-other", session_id:"sess-other"}')" \
  > "$M4/command-runs-2026-09.jsonl"
jq -nc --argjson now "$(date -u +%s)" \
  '{run_id:"run-in-flight",command:"fix",session_id:"sess-now",board:7,opened_at:"now",opened_epoch:$now,emitted:0}' \
  > "$M4/command-run-open/sess-now__fix.json"
recon --raw-dir "$M4"
check_eq "a run still inside the grace window is not flagged (no false red)" "0" "$RECON_RC"

echo "── 4. criterion 2, DUPLICATE half: an unreducible post-cutover record ──"
D1="$TMP/dup"; mkdir -p "$D1"
{ printf '%s\n' "$(printf '%s' "$LEGACY_MERGE" | jq -c '. + {ts:"2026-09-23T05:00:00Z", run_id:"run-cutover", session_id:"sess-cut"}')"
  printf '%s\n' "$LEGACY_PARK"
  printf '%s\n' "$LEGACY_MERGE"; } > "$D1/command-runs-2026-09.jsonl"
recon --raw-dir "$D1"
check_eq "RED on run-id-less records written after the host's cutover" "1" "$RECON_RC"
case "$RECON_OUT" in *UNREDUCIBLE*) ok "the failure names UNREDUCIBLE" ;;
  *) bad "the failure names UNREDUCIBLE" "got [$RECON_OUT]" ;; esac

# discrimination twin: the same three lines, all carrying run ids → green.
D2="$TMP/dup-fixed"; mkdir -p "$D2"
{ printf '%s\n' "$(printf '%s' "$LEGACY_MERGE" | jq -c '. + {ts:"2026-09-23T05:00:00Z", run_id:"run-cutover", session_id:"sess-cut"}')"
  printf '%s\n' "$(printf '%s' "$LEGACY_PARK"  | jq -c '. + {run_id:"run-2208"}')"
  printf '%s\n' "$(printf '%s' "$LEGACY_MERGE" | jq -c '. + {run_id:"run-2208"}')"; } > "$D2/command-runs-2026-09.jsonl"
recon --raw-dir "$D2"
check_eq "GREEN on the same three lines once they carry run ids" "0" "$RECON_RC"

echo "── 5. the pre-#2220 backlog is tolerated, never backfilled ──"
recon --raw-dir "$L1"
check_eq "a legacy-only stream is GREEN (reported as legacy, not failed)" "0" "$RECON_RC"
case "$RECON_OUT" in *"2 legacy run(s)"*) ok "the verdict names how many runs read as legacy singletons" ;;
  *) bad "the verdict names how many runs read as legacy singletons" "got [$RECON_OUT]" ;; esac
recon --raw-dir "$L1" --reduce
check_eq "a legacy record still parses and reduces (as its own singleton run)" \
  "true true" "$(printf '%s\n' "$RECON_OUT" | jq -s -r '"\(.[0].legacy) \(.[1].legacy)"')"

echo "── 6. the run id is purely additive ──"
ADD="$TMP/additive"; mkdir -p "$ADD"
REC="$(CMD_RUN_RAW_DIR="$ADD" CLAUDE_CODE_SESSION_ID=sess-add bash "$EMIT" --command sweep --board 3 \
  --items-processed 2 --merged 1 --resolved 0 --parked 1 --reported-no-op 0 2>/dev/null)"
check_eq "every record now carries run_id" "true" "$(printf '%s' "$REC" | jq -r 'has("run_id")')"
check_eq "and no schema_version was bumped in (the additive-change convention)" \
  "false" "$(printf '%s' "$REC" | jq -r 'has("schema_version")')"
check_eq "the pre-existing fields are untouched" \
  "2 1 0 1 0" "$(printf '%s' "$REC" | jq -r '"\(.items_processed) \(.merged) \(.resolved) \(.parked) \(.reported_no_op)"')"

echo "── 7. ledger edge cases ──"
X1="$TMP/explicit"; mkdir -p "$X1"
REC="$(CMD_RUN_RAW_DIR="$X1" CLAUDE_CODE_SESSION_ID=sess-x bash "$EMIT" --command fix --board 7 \
  --run-id run-explicit --items-processed 1 --merged 1 --resolved 0 --parked 0 --reported-no-op 0 2>/dev/null)"
check_eq "an explicit --run-id wins over the ledger" "run-explicit" "$(printf '%s' "$REC" | jq -r '.run_id')"

X2="$TMP/stale"; mkdir -p "$X2/command-run-open"
cat > "$X2/command-run-open/sess-stale__fix.json" <<'EOF'
{"run_id":"run-stale","command":"fix","session_id":"sess-stale","board":7,"opened_at":"1970-01-01T00:00:01Z","opened_epoch":1,"emitted":1}
EOF
REC="$(CMD_RUN_RAW_DIR="$X2" CLAUDE_CODE_SESSION_ID=sess-stale bash "$EMIT" --command fix --board 7 \
  --items-processed 1 --merged 1 --resolved 0 --parked 0 --reported-no-op 0 2>/dev/null)"
if [ "$(printf '%s' "$REC" | jq -r '.run_id')" = "run-stale" ]; then
  bad "a marker past CMD_RUN_RUN_ID_TTL_SECS is not adopted" "the stale run id was adopted, silently merging two runs"
else
  ok "a marker past CMD_RUN_RUN_ID_TTL_SECS is not adopted (a fresh id is minted)"
fi

X4="$TMP/prune"; mkdir -p "$X4/command-run-open"
cat > "$X4/command-run-open/sess-spent__fix.json" <<'EOF'
{"run_id":"run-spent","command":"fix","session_id":"sess-spent","board":7,"opened_at":"1970-01-01T00:00:01Z","opened_epoch":1,"emitted":2}
EOF
cat > "$X4/command-run-open/sess-silent__sweep.json" <<'EOF'
{"run_id":"run-silent","command":"sweep","session_id":"sess-silent","board":3,"opened_at":"1970-01-01T00:00:01Z","opened_epoch":1,"emitted":0}
EOF
CMD_RUN_RAW_DIR="$X4" CLAUDE_CODE_SESSION_ID=sess-new bash "$EMIT" --open --command fix --board 7 >/dev/null 2>&1
if [ -f "$X4/command-run-open/sess-spent__fix.json" ]; then
  bad "--open prunes a SPENT marker (past the TTL, record already emitted)" "it survived, so the ledger grows unboundedly"
else
  ok "--open prunes a SPENT marker (past the TTL, record already emitted)"
fi
if [ -f "$X4/command-run-open/sess-silent__sweep.json" ]; then
  ok "--open never prunes an un-emitted marker at any age — that one IS the missing-run alarm"
else
  bad "--open never prunes an un-emitted marker at any age" "the alarm was deleted before any guard could read it"
fi

X3="$TMP/degraded"; mkdir -p "$X3"
: > "$X3/command-run-open"   # a FILE where the ledger dir belongs: unwritable
REC="$(CMD_RUN_RAW_DIR="$X3" CLAUDE_CODE_SESSION_ID=sess-deg bash "$EMIT" --command fix --board 7 \
  --items-processed 1 --merged 0 --resolved 0 --parked 1 --reported-no-op 0 2>/dev/null)"
EMIT_RC=$?
check_eq "an unwritable ledger never fails the emit (warn-don't-drop)" "0" "$EMIT_RC"
check_eq "and the record still carries a run id, so the run stays reducible" \
  "true" "$(printf '%s' "$REC" | jq -r '(.run_id // "") | startswith("run-")')"

echo "── 8. fail-closed on a degenerate input (temperloop#1409 class) ──"
recon --stream "$TMP/does-not-exist.jsonl"
check_eq "an absent explicitly-named stream: exit 1 (CANNOT EVALUATE), not 0" "1" "$RECON_RC"
: > "$TMP/empty.jsonl"
recon --stream "$TMP/empty.jsonl"
check_eq "an empty explicitly-named stream: exit 1 (CANNOT EVALUATE), not 0" "1" "$RECON_RC"
if [ "$(id -u)" -ne 0 ]; then
  printf 'x\n' > "$TMP/unreadable.jsonl"; chmod 000 "$TMP/unreadable.jsonl"
  recon --stream "$TMP/unreadable.jsonl"
  check_eq "an unreadable explicitly-named stream: exit 1 (CANNOT EVALUATE), not 0" "1" "$RECON_RC"
  chmod 644 "$TMP/unreadable.jsonl"
else
  ok "the unreadable-stream case [skipped: running as root, where chmod 000 is not a read barrier]"
fi
printf 'not json at all\n' > "$TMP/garbage.jsonl"
recon --stream "$TMP/garbage.jsonl"
check_eq "an unparseable stream: exit 1 (CANNOT EVALUATE), not 0" "1" "$RECON_RC"
recon --open-dir "$TMP/no-such-dir" --stream "$L1/command-runs-2026-09.jsonl"
check_eq "an absent explicitly-named open-dir: exit 1 (CANNOT EVALUATE), not 0" "1" "$RECON_RC"
recon --raw-dir "$TMP/empty-lake"
check_eq "the ONE documented exit-0 exception: a default lake that has emitted nothing yet" "0" "$RECON_RC"

echo "── 9. the wiring is mechanically enforced in the caller docs ──"
grep_ok "fix.md opens the run ledger" "--open --command fix" "$FIX_MD"
grep_ok "sweep.md opens the run ledger" "--open --command sweep" "$SWEEP_MD"
grep_ok "triage.md opens the run ledger" "--open --command triage" "$TRIAGE_MD"
if [ -f "$LINT" ]; then
  if bash "$LINT" >/dev/null 2>&1; then
    ok "validate-command-run-emit.sh is green on the real tree"
  else
    bad "validate-command-run-emit.sh is green on the real tree" "$(bash "$LINT" 2>&1 | tail -3)"
  fi
  # Discrimination: a caller doc that loses its --open call must go red.
  FIXR="$TMP/lintfix"
  mkdir -p "$FIXR/workflows/scripts" "$FIXR/claude/commands"
  cp "$EMIT" "$FIXR/workflows/scripts/emit-command-run.sh"
  chmod +x "$FIXR/workflows/scripts/emit-command-run.sh"
  cp "$LINT" "$FIXR/workflows/scripts/validate-command-run-emit.sh"
  cp "$SWEEP_MD" "$TRIAGE_MD" "$FIXR/claude/commands/"
  sed 's/--open --command fix/--command fix/' "$FIX_MD" > "$FIXR/claude/commands/fix.md"
  if bash "$FIXR/workflows/scripts/validate-command-run-emit.sh" >/dev/null 2>&1; then
    bad "the lint catches a caller doc that dropped its --open call" "it stayed green"
  else
    ok "the lint catches a caller doc that dropped its --open call"
  fi
  # …and is green again once restored (the discriminating twin).
  cp "$FIX_MD" "$FIXR/claude/commands/fix.md"
  if bash "$FIXR/workflows/scripts/validate-command-run-emit.sh" >/dev/null 2>&1; then
    ok "and is green again once the --open call is restored"
  else
    bad "and is green again once the --open call is restored" "still red"
  fi
fi

echo "── 10. the canonical sink spec documents the field and the reduction rule ──"
grep_ok "README documents the run_id field" "run_id" "$README"
grep_ok "README states the reduce-by-run_id-take-the-last rule" "take the LAST record" "$README"
grep_ok "README dispositions the pre-#2220 backlog (no run_id ⇒ its own singleton run)" \
  "its own singleton run" "$README"
grep_ok "README's record-shape line lists run_id" \
  '{ts, session_id, run_id, command' "$README"
grep_ok "emit-command-run.sh documents the open ledger" "THE RUN LEDGER" "$EMIT"

printf '\n'
if [ "$fail" -gt 0 ]; then
  printf 'test_command_run_reconcile: FAILED — %s passed, %s failed\n' "$pass" "$fail"
  exit 1
fi
printf 'test_command_run_reconcile: OK — all %s checks passed\n' "$pass"
