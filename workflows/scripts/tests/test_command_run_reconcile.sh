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
# Sections 11-13 cover the round-2 review findings, all of which are ways the
# machinery failed OPEN — it reported a clean property over an input it never
# evaluated, which is worse than no guard because it manufactures confidence:
#   11. a lake PATH CONTAINING A SPACE reduced to an empty report and passed
#       (`ok - 0 record(s)`), and an unreadable lake read identically to an
#       empty one.
#   12. the open-ledger marker key carried no TARGET, so two concurrent /fix
#       runs in one session shared one marker and one run id, and the second
#       `--open` destroyed the first run's held id.
#   13. a non-numeric *_SECS setting made the comparison it bounds return an
#       error that the surrounding `|| continue` read as an ordinary "no",
#       silently skipping the MISSING-RUN check while still exiting 0.
#
# Sections 14-17 cover the round-3 review findings. 14 and 15 are the same
# two classes as 11 and 13 — fail-open, and an alarm erased before it is read
# — surviving on surfaces the round-2 fix did not reach:
#   14. the lake DIRECTORY (not the stream FILE) could not be listed, and an
#       unreadable / absent / not-a-directory lake read identically to an
#       empty one — so a lake HOLDING A RECORD, merely chmod 000, asserted
#       that this host had emitted no telemetry at all.
#   15. the terminal emit's close path `rm`-ed whatever sat on the ledger key,
#       including a marker it never ADOPTED — deleting the aged emitted=0
#       MISSING-RUN alarm that emit-command-run.sh twice promises is never
#       removed at any age.
#   16. a record count that could not be read made `[ "$seen" -eq 0 ]` exit 2,
#       which `if` reads as FALSE — skipping the MISSING-RUN arm for that
#       marker while the guard still exited 0.
#   17. `\b` in the caller-doc presence lint let `--open --command
#       triage-feedback` satisfy the `triage` check by itself.
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

# 1c. The README's OWN documented reduction snippet is executed, not trusted.
#     A consumer copies that jq one-liner; if it does not reduce the way the
#     prose claims, the documentation is the defect. (The first cut of it used
#     `input_line_number` under `-s`, which is the LAST line read — every
#     legacy record would have shared one key and silently merged.)
snippet="$(awk '
  /^```sh$/ { inb = 1; buf = ""; next }
  inb && /^```$/ { if (buf ~ /canonical reduction/) { printf "%s", buf; exit } inb = 0; next }
  inb { buf = buf $0 "\n" }' "$README")"
if [ -z "$snippet" ]; then
  bad "the README's canonical reduction snippet is extractable" "no fenced sh block mentioning 'canonical reduction'"
else
  ok "the README's canonical reduction snippet is extractable"
  run_snippet() { # <lake-file> → the snippet's output
    printf '%s' "$snippet" \
      | sed "s#meta/data/raw/command-runs-\\*\\.jsonl#$1#" \
      | bash 2>&1
  }
  check_eq "the README snippet reduces the FIXED pair to one run (as the prose claims)" \
    "1" "$(run_snippet "$L2/command-runs-2026-09.jsonl" | jq -r 'length')"
  check_eq "the README snippet keeps each legacy record its OWN singleton run" \
    "2" "$(run_snippet "$L1/command-runs-2026-09.jsonl" | jq -r 'length')"
  check_eq "and agrees with the guard's own --reduce on the same lake" \
    "1" "$(run_snippet "$L2/command-runs-2026-09.jsonl" | jq -r '.[0].merged')"
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
# The ONE documented exit-0 exception belongs to DEFAULT mode ONLY, so it is
# exercised through a fake repo root — `--raw-dir`/$CMD_RUN_RAW_DIR are
# EXPLICIT targeting and now fail closed (section 14). repo_root is derived
# from the script's own location, so a copy under $FR/workflows/scripts sees
# $FR/meta/data/raw as its default lake.
FR="$TMP/fakerepo"; mkdir -p "$FR/workflows/scripts" "$FR/meta/data/raw"
cp "$RECON" "$FR/workflows/scripts/validate-command-run-reconcile.sh"
RECON_OUT="$(bash "$FR/workflows/scripts/validate-command-run-reconcile.sh" 2>&1)"; RECON_RC=$?
check_eq "the ONE documented exit-0 exception: a DEFAULT lake, present and readable, that has emitted nothing yet" "0" "$RECON_RC"
rm -rf "$FR/meta"
RECON_OUT="$(bash "$FR/workflows/scripts/validate-command-run-reconcile.sh" 2>&1)"; RECON_RC=$?
check_eq "…and a DEFAULT lake directory that does not exist at all is the same expected state" "0" "$RECON_RC"

echo "── 9. the wiring is mechanically enforced in the caller docs ──"
grep_ok "fix.md opens the run ledger" "--open --command fix" "$FIX_MD"
grep_ok "sweep.md opens the run ledger" "--open --command sweep" "$SWEEP_MD"
grep_ok "triage.md opens the run ledger" "--open --command triage" "$TRIAGE_MD"
grep_ok "fix.md keys the ledger on its target (two concurrent /fix runs)" "--target" "$FIX_MD"
grep_ok "sweep.md keys the ledger on its board" "--target" "$SWEEP_MD"
grep_ok "triage.md keys the ledger on its board" "--target" "$TRIAGE_MD"
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
grep_ok "emit-command-run.sh documents one marker per RUN, not per (session, command)" \
  "ONE MARKER PER RUN" "$EMIT"
grep_ok "README documents the ledger's key shape" \
  "<session>__<command>[__<target>].json" "$README"

echo "── 11. the guard must FAIL CLOSED on a lake it cannot read (round 2, HIGH 1) ──"
# The lake path is user-supplied from three surfaces (--stream, --raw-dir,
# $CMD_RUN_RAW_DIR). A space in it once split the file list into non-existent
# fragments; the read error was swallowed and `jq -s` over zero files produced
# a valid EMPTY report, so every check passed vacuously.
ONE_REC='{"ts":"2026-09-23T19:31:04Z","session_id":"sess-sp","run_id":"run-spaced","command":"fix","board":7,"items_processed":1,"merged":1,"resolved":0,"parked":0,"reported_no_op":0}'
SP="$TMP/lake with a space"; mkdir -p "$SP"
printf '%s\n' "$ONE_REC" > "$SP/command-runs-2026-09.jsonl"
PLAIN="$TMP/lake-plain"; mkdir -p "$PLAIN"
printf '%s\n' "$ONE_REC" > "$PLAIN/command-runs-2026-09.jsonl"

recon --raw-dir "$PLAIN"
plain_verdict="$RECON_OUT"
recon --raw-dir "$SP"
check_eq "a spaced lake path is READ, not silently reduced to nothing" \
  "0 1" "$RECON_RC $(printf '%s\n' "$RECON_OUT" | sed -n 's/.*ok — \([0-9]*\) record(s).*/\1/p')"
# The discriminating twin: byte-identical lakes, only the path differs.
if [ "$(printf '%s' "$plain_verdict" | sed 's/.*ok —/ok —/')" = "$(printf '%s' "$RECON_OUT" | sed 's/.*ok —/ok —/')" ]; then
  ok "and reads IDENTICALLY to the same bytes at a space-free path (the twin)"
else
  bad "and reads IDENTICALLY to the same bytes at a space-free path" \
    "spaced=[$RECON_OUT] plain=[$plain_verdict]"
fi
recon --raw-dir "$SP" --reduce
check_eq "the spaced lake's record actually reaches the reducer" \
  "run-spaced" "$(printf '%s\n' "$RECON_OUT" | jq -r '.run_id')"
recon --stream "$SP/command-runs-2026-09.jsonl"
check_eq "--stream with a spaced path reads it too (the explicit surface)" "0" "$RECON_RC"

# A read that FAILED must be distinguishable from a read that found nothing.
if [ "$(id -u)" -ne 0 ]; then
  UR="$TMP/lake-unreadable"; mkdir -p "$UR"
  printf '%s\n' "$ONE_REC" > "$UR/command-runs-2026-09.jsonl"
  chmod 000 "$UR/command-runs-2026-09.jsonl"
  recon --raw-dir "$UR"
  check_eq "an unreadable lake file: exit 1, never a clean 'ok — 0 record(s)'" "1" "$RECON_RC"
  case "$RECON_OUT" in *"could not be READ or parsed"*)
      ok "the failure says the input could not be READ (not that it was empty)" ;;
    *) bad "the failure says the input could not be READ" "got [$RECON_OUT]" ;; esac
  chmod 644 "$UR/command-runs-2026-09.jsonl"
  recon --raw-dir "$UR"
  check_eq "GREEN again once the same file is readable (the discriminating twin)" "0" "$RECON_RC"
else
  ok "the unreadable-lake case [skipped: running as root, where chmod 000 is not a read barrier]"
fi

echo "── 12. one marker per RUN, not per (session, command) (round 2, HIGH 2+3) ──"
# `/fix 2220 and 2224` runs two /fix runs CONCURRENTLY in one session. Keyed on
# (session, command) alone they collapsed onto one marker and one run id.
CC="$TMP/concurrent"; mkdir -p "$CC"
open_run() { # <target> → the run id
  CMD_RUN_RAW_DIR="$CC" CLAUDE_CODE_SESSION_ID=sess-cc bash "$EMIT" \
    --open --command fix --board 7 --target "$1" 2>/dev/null
}
emit_run() { # <target> <merged> <parked>
  CMD_RUN_RAW_DIR="$CC" CLAUDE_CODE_SESSION_ID=sess-cc bash "$EMIT" \
    --command fix --board 7 --target "$1" \
    --items-processed 1 --merged "$2" --resolved 0 --parked "$3" --reported-no-op 0 >/dev/null 2>&1
}
RID_A="$(open_run 2220)"
RID_B="$(open_run 2224)"
if [ -n "$RID_A" ] && [ "$RID_A" != "$RID_B" ]; then
  ok "two concurrent targets in ONE session get DISTINCT run ids"
else
  bad "two concurrent targets in ONE session get DISTINCT run ids" \
    "both runs got [$RID_A] — one run id for two runs is the double-count this field prevents"
fi
check_eq "and each holds its OWN open marker" "2" "$(marker_count "$CC/command-run-open")"
if [ -f "$CC/command-run-open/sess-cc__fix__2220.json" ] && [ -f "$CC/command-run-open/sess-cc__fix__2224.json" ]; then
  ok "the marker key carries the target, so neither run can overwrite the other"
else
  bad "the marker key carries the target" \
    "got: $(find "$CC/command-run-open" -type f -name '*.json' 2>/dev/null | tr '\n' ' ')"
fi

# Each run parks, then merges later in that SAME run — the real /fix shape.
emit_run 2220 0 1
emit_run 2224 0 1
emit_run 2220 1 0
emit_run 2224 1 0
recon --raw-dir "$CC" --reduce
check_eq "4 records from 2 concurrent runs reduce to exactly 2 runs" \
  "2" "$(printf '%s\n' "$RECON_OUT" | jq -s 'length')"
check_eq "each reduces to ONE merged item (neither double-counted)" \
  "2 2" "$(printf '%s\n' "$RECON_OUT" | jq -s -r '"\([.[].merged] | add) \([.[].items_processed] | add)"')"
recon --raw-dir "$CC"
check_eq "and the guard is GREEN over both" "0" "$RECON_RC"

# --open must never clobber a marker that is still LIVE on its key. This is
# the residual (session, command) key — a caller that passes no --target.
NC="$TMP/noclobber"; mkdir -p "$NC"
NC_A="$(CMD_RUN_RAW_DIR="$NC" CLAUDE_CODE_SESSION_ID=sess-nc bash "$EMIT" --open --command fix 2>/dev/null)"
NC_B="$(CMD_RUN_RAW_DIR="$NC" CLAUDE_CODE_SESSION_ID=sess-nc bash "$EMIT" --open --command fix 2>/dev/null)"
NC_HELD="$(jq -r '.run_id' "$NC/command-run-open/sess-nc__fix.json" 2>/dev/null)"
if [ -n "$NC_A" ] && [ "$NC_HELD" = "$NC_A" ] && [ "$NC_B" = "$NC_A" ]; then
  ok "a second --open on a LIVE key reuses the held run id, never overwrites it"
else
  bad "a second --open on a LIVE key reuses the held run id" \
    "first=[$NC_A] second=[$NC_B] marker now holds=[$NC_HELD] — the first run's id was lost"
fi

# A STALE un-emitted marker IS the missing-run alarm; --open must not erase it.
AL="$TMP/alarm"; mkdir -p "$AL/command-run-open"
cat > "$AL/command-run-open/sess-al__fix.json" <<'EOF'
{"run_id":"run-ALARM","command":"fix","session_id":"sess-al","board":7,"target":null,"opened_at":"1970-01-01T00:00:01Z","opened_epoch":1,"emitted":0}
EOF
CMD_RUN_RAW_DIR="$AL" CLAUDE_CODE_SESSION_ID=sess-al bash "$EMIT" --open --command fix >/dev/null 2>&1
if grep -lF 'run-ALARM' "$AL/command-run-open"/*.json >/dev/null 2>&1; then
  ok "a stale un-emitted marker survives a later --open on the same key (the alarm is not erased)"
else
  bad "a stale un-emitted marker survives a later --open on the same key" \
    "the MISSING-RUN alarm was deleted before any guard could read it"
fi
printf '%s\n' '{"ts":"2026-09-23T19:31:04Z","run_id":"run-other","command":"fix","items_processed":0,"merged":0,"resolved":0,"parked":0,"reported_no_op":0}' \
  > "$AL/command-runs-2026-09.jsonl"
recon --raw-dir "$AL"
check_eq "and the guard still goes RED on it" "1" "$RECON_RC"
case "$RECON_OUT" in *MISSING-RUN*run-ALARM*) ok "naming the preserved alarm's run id" ;;
  *) bad "naming the preserved alarm's run id" "got [$RECON_OUT]" ;; esac

# The marker write is ATOMIC: a temp sibling renamed into place, never a
# truncate-then-fill a concurrent reader can catch half-written.
if find "$CC/command-run-open" "$NC/command-run-open" -name '*.tmp.*' 2>/dev/null | grep . >/dev/null; then
  bad "the marker write leaves no temp file behind" "a .tmp.<pid> sibling survived"
else
  ok "the marker write leaves no temp file behind (write-temp-then-rename)"
fi

echo "── 13. a non-numeric *_SECS setting is rejected LOUDLY, never skipped (round 2) ──"
# `6h` / `12h` are plausible typos for something the registry calls `seconds`.
# Bare `[ … -ge "$VAR" ]` returns 2 on one, which `|| continue` reads as an
# ordinary "no" — disabling the MISSING-RUN check for every marker, silently.
recon --raw-dir "$M1"
check_eq "baseline: the missing-run lake is RED with a sane grace window" "1" "$RECON_RC"
RECON_OUT="$(CMD_RUN_OPEN_GRACE_SECS=6h bash "$RECON" --raw-dir "$M1" 2>&1)"; RECON_RC=$?
check_eq "a non-numeric CMD_RUN_OPEN_GRACE_SECS FAILS the guard (never a silent skip)" "1" "$RECON_RC"
case "$RECON_OUT" in *CMD_RUN_OPEN_GRACE_SECS*)
    ok "and the failure names the offending setting" ;;
  *) bad "and the failure names the offending setting" "got [$RECON_OUT]" ;; esac
case "$RECON_OUT" in *"ok — "*)
    bad "a non-numeric grace window never prints an ok verdict" "it printed one: [$RECON_OUT]" ;;
  *) ok "a non-numeric grace window never prints an ok verdict" ;; esac

# Same class on the emitter side. It never FAILS a caller, so the contract is
# warn-loudly-and-fall-back rather than exit non-zero.
TT="$TMP/ttl"; mkdir -p "$TT"
TTL_ERR="$(CMD_RUN_RUN_ID_TTL_SECS=12h CMD_RUN_RAW_DIR="$TT" CLAUDE_CODE_SESSION_ID=sess-ttl \
  bash "$EMIT" --open --command fix 2>&1 >/dev/null)"
TTL_RC=$?
check_eq "a non-numeric CMD_RUN_RUN_ID_TTL_SECS never fails the emit (warn-don't-drop)" "0" "$TTL_RC"
case "$TTL_ERR" in *CMD_RUN_RUN_ID_TTL_SECS*)
    ok "but it WARNS loudly, naming the setting (never a silent skip)" ;;
  *) bad "but it WARNS loudly, naming the setting" "stderr was [$TTL_ERR]" ;; esac
# …and the bound it guards still works: a marker past the default TTL is not adopted.
mkdir -p "$TT/command-run-open"
cat > "$TT/command-run-open/sess-ttl2__fix.json" <<'EOF'
{"run_id":"run-ancient","command":"fix","session_id":"sess-ttl2","board":7,"target":null,"opened_at":"1970-01-01T00:00:01Z","opened_epoch":1,"emitted":1}
EOF
TTL_REC="$(CMD_RUN_RUN_ID_TTL_SECS=12h CMD_RUN_RAW_DIR="$TT" CLAUDE_CODE_SESSION_ID=sess-ttl2 \
  bash "$EMIT" --command fix --board 7 \
  --items-processed 1 --merged 1 --resolved 0 --parked 0 --reported-no-op 0 2>/dev/null)"
if [ "$(printf '%s' "$TTL_REC" | jq -r '.run_id')" = "run-ancient" ]; then
  bad "the freshness bound still holds after the fallback" \
    "a marker far past the default TTL was adopted, so the bad value disabled the bound"
else
  ok "the freshness bound still holds after the fallback (a fresh id is minted)"
fi

echo "── 14. the guard must FAIL CLOSED on a lake DIRECTORY it cannot list (round 3, HIGH A) ──"
# Round 2 closed the fail-open on the FILE surface. The DIRECTORY surface kept
# the identical hole one level up: `for f in "$raw_dir"/command-runs-*.jsonl`
# with `[ -f "$f" ] || continue` cannot tell "readable, no files" from
# "unreadable / absent / not a directory" — all four landed in the empty-list
# arm and printed the sanctioned exit-0 sentence. A lake HOLDING A RECORD,
# merely chmod 000, therefore asserted this host had emitted no telemetry.
DIRL="$TMP/dir-lake"; mkdir -p "$DIRL"
printf '%s\n' "$ONE_REC" > "$DIRL/command-runs-2026-09.jsonl"
recon --raw-dir "$DIRL"
check_eq "control: the same lake, readable, reduces its one record" \
  "0 1" "$RECON_RC $(printf '%s\n' "$RECON_OUT" | sed -n 's/.*ok — \([0-9]*\) record(s).*/\1/p')"

if [ "$(id -u)" -ne 0 ]; then
  chmod 000 "$DIRL"
  recon --raw-dir "$DIRL"
  check_eq "an UNREADABLE lake DIRECTORY: exit 1, never 'this host has emitted no telemetry yet'" "1" "$RECON_RC"
  case "$RECON_OUT" in *"no command-run telemetry yet"*)
      bad "an unreadable lake directory never claims the host emitted nothing" "it claimed exactly that: [$RECON_OUT]" ;;
    *) ok "an unreadable lake directory never claims the host emitted nothing" ;; esac
  case "$RECON_OUT" in *"not a readable, searchable directory"*)
      ok "and the failure says the DIRECTORY could not be listed" ;;
    *) bad "and the failure says the DIRECTORY could not be listed" "got [$RECON_OUT]" ;; esac
  chmod 755 "$DIRL"
  recon --raw-dir "$DIRL"
  check_eq "GREEN again once the same directory is readable (the discriminating twin)" "0" "$RECON_RC"
else
  ok "the unreadable-lake-directory case [skipped: running as root, where chmod 000 is not a read barrier]"
fi

: > "$TMP/lake-is-a-file"
recon --raw-dir "$TMP/lake-is-a-file"
check_eq "a --raw-dir that is NOT A DIRECTORY: exit 1 (CANNOT EVALUATE), not 0" "1" "$RECON_RC"
recon --raw-dir "$TMP/no-such-lake-dir"
check_eq "an absent explicitly-named --raw-dir: exit 1 (CANNOT EVALUATE), not 0" "1" "$RECON_RC"
mkdir -p "$TMP/named-but-empty"
recon --raw-dir "$TMP/named-but-empty"
check_eq "an explicitly-named lake holding no command-runs-*.jsonl: exit 1 (CANNOT EVALUATE), not 0" "1" "$RECON_RC"
RECON_OUT="$(CMD_RUN_RAW_DIR="$TMP/no-such-lake-dir" bash "$RECON" 2>&1)"; RECON_RC=$?
check_eq "\$CMD_RUN_RAW_DIR is explicit targeting too: an absent one fails closed" "1" "$RECON_RC"

echo "── 15. the close path closes ONLY the marker this emit adopted (round 3, MEDIUM B) ──"
# `rm -f "$marker_path"` on every nothing-parked emit deleted whatever sat on
# the ledger key — including an aged, UNADOPTED emitted=0 marker, which IS the
# MISSING-RUN alarm this file twice promises is never erased at any age.
AD="$TMP/adopt"; mkdir -p "$AD/command-run-open"
AD_RID="$(CMD_RUN_RAW_DIR="$AD" CLAUDE_CODE_SESSION_ID=sess-ad bash "$EMIT" \
  --open --command fix --board 7 --target 2220 2>/dev/null)"
# Age the alarm past the adoption TTL, so the next emit MINTS rather than adopts.
AD_MK="$AD/command-run-open/sess-ad__fix__2220.json"
if [ -f "$AD_MK" ]; then
  jq -c '.opened_epoch = 1' "$AD_MK" > "$AD_MK.aged" && mv -f "$AD_MK.aged" "$AD_MK"
  AD_REC="$(CMD_RUN_RAW_DIR="$AD" CLAUDE_CODE_SESSION_ID=sess-ad bash "$EMIT" \
    --command fix --board 7 --target 2220 \
    --items-processed 1 --merged 1 --resolved 0 --parked 0 --reported-no-op 0 2>/dev/null)"
  if [ "$(printf '%s' "$AD_REC" | jq -r '.run_id')" = "$AD_RID" ]; then
    bad "the aged marker is NOT adopted (a fresh id is minted)" "the stale id was adopted"
  else
    ok "the aged marker is NOT adopted (a fresh id is minted)"
  fi
  if [ -f "$AD_MK" ]; then
    ok "an AGED, UNADOPTED emitted=0 marker SURVIVES a terminal emit on the same key"
  else
    bad "an AGED, UNADOPTED emitted=0 marker SURVIVES a terminal emit on the same key" \
      "the MISSING-RUN alarm was deleted by a run that never adopted it"
  fi
  recon --raw-dir "$AD"
  check_eq "so the guard still finds it (RED on the run that opened and never emitted)" "1" "$RECON_RC"
  case "$RECON_OUT" in *MISSING-RUN*"$AD_RID"*) ok "naming the surviving alarm's run id" ;;
    *) bad "naming the surviving alarm's run id" "got [$RECON_OUT]" ;; esac
else
  bad "the --open call wrote a marker to adopt" "no marker at $AD_MK"
fi

# A MALFORMED marker (no run_id) is a hard MARKER-MALFORMED failure for the
# guard; the close path must not silently delete that either.
MM="$TMP/malformed"; mkdir -p "$MM/command-run-open"
printf '%s\n' '{"command":"fix","session_id":"sess-mm","board":7,"target":"2220","opened_at":"1970-01-01T00:00:01Z","opened_epoch":1,"emitted":0}' \
  > "$MM/command-run-open/sess-mm__fix__2220.json"
CMD_RUN_RAW_DIR="$MM" CLAUDE_CODE_SESSION_ID=sess-mm bash "$EMIT" \
  --command fix --board 7 --target 2220 \
  --items-processed 1 --merged 1 --resolved 0 --parked 0 --reported-no-op 0 >/dev/null 2>&1
if [ -f "$MM/command-run-open/sess-mm__fix__2220.json" ]; then
  ok "a MALFORMED marker survives a terminal emit too (the guard's MARKER-MALFORMED fail is not erased)"
else
  bad "a MALFORMED marker survives a terminal emit too" "it was deleted before the guard could read it"
fi
recon --raw-dir "$MM"
check_eq "and the guard goes RED on it" "1" "$RECON_RC"
case "$RECON_OUT" in *MARKER-MALFORMED*) ok "naming MARKER-MALFORMED" ;;
  *) bad "naming MARKER-MALFORMED" "got [$RECON_OUT]" ;; esac

# The discriminating twin: the marker this emit DID adopt is still closed.
AD2="$TMP/adopt-twin"; mkdir -p "$AD2"
CMD_RUN_RAW_DIR="$AD2" CLAUDE_CODE_SESSION_ID=sess-ad2 bash "$EMIT" \
  --open --command fix --board 7 --target 2220 >/dev/null 2>&1
CMD_RUN_RAW_DIR="$AD2" CLAUDE_CODE_SESSION_ID=sess-ad2 bash "$EMIT" \
  --command fix --board 7 --target 2220 \
  --items-processed 1 --merged 1 --resolved 0 --parked 0 --reported-no-op 0 >/dev/null 2>&1
check_eq "an ADOPTED marker is still closed by its own terminal emit (the twin)" \
  "0" "$(marker_count "$AD2/command-run-open")"

echo "── 16. a record count that could not be read fails CLOSED (round 3, LOW C) ──"
# `[ "$seen" -eq 0 ]` on an empty/non-numeric $seen exits 2, which `if` reads
# as FALSE — skipping the MISSING-RUN arm for that marker while the guard
# still exits 0. The shim below makes exactly that one jq query return nothing,
# over a lake that is otherwise perfectly GREEN.
REAL_JQ="$(command -v jq)"
SHIM="$TMP/shim"; mkdir -p "$SHIM"
cat > "$SHIM/jq" <<SHIMEOF
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in *'select(.run_id == \$r)'*) exit 0 ;; esac
done
exec "$REAL_JQ" "\$@"
SHIMEOF
chmod +x "$SHIM/jq"
SC="$TMP/seen-count"; mkdir -p "$SC/command-run-open"
printf '%s\n' '{"ts":"2026-09-23T19:31:04Z","run_id":"run-counted","session_id":"sess-sc","command":"fix","board":7,"items_processed":1,"merged":1,"resolved":0,"parked":0,"reported_no_op":0}' \
  > "$SC/command-runs-2026-09.jsonl"
printf '%s\n' '{"run_id":"run-counted","command":"fix","session_id":"sess-sc","board":7,"opened_at":"1970-01-01T00:00:01Z","opened_epoch":1,"emitted":1}' \
  > "$SC/command-run-open/sess-sc__fix.json"
recon --raw-dir "$SC"
check_eq "control: the marker's run IS in the stream, so the guard is green" "0" "$RECON_RC"
RECON_OUT="$(PATH="$SHIM:$PATH" bash "$RECON" --raw-dir "$SC" 2>&1)"; RECON_RC=$?
check_eq "a record count that came back UNREADABLE fails CLOSED, never a silent skip" "1" "$RECON_RC"
case "$RECON_OUT" in *MISSING-RUN*) ok "and reports it as MISSING-RUN (records in stream=0), the safe direction" ;;
  *) bad "and reports it as MISSING-RUN" "got [$RECON_OUT]" ;; esac

echo "── 17. the --command presence check cannot be satisfied by a LONGER command (round 3, LOW D) ──"
if [ -f "$LINT" ]; then
  # `\b` matches between `e` and `-`, so triage.md's own legitimate
  # `--open --command triage-feedback` line satisfied the `triage` check all
  # by itself: drop the MAIN /triage open call and the lint stayed green.
  SUF="$TMP/lintsuffix"
  mkdir -p "$SUF/workflows/scripts" "$SUF/claude/commands"
  cp "$EMIT" "$SUF/workflows/scripts/emit-command-run.sh"
  cp "$LINT" "$SUF/workflows/scripts/validate-command-run-emit.sh"
  cp "$FIX_MD" "$SWEEP_MD" "$SUF/claude/commands/"
  sed 's/--open --command triage --board/--open --command triage-feedback --board/' \
    "$TRIAGE_MD" > "$SUF/claude/commands/triage.md"
  if bash "$SUF/workflows/scripts/validate-command-run-emit.sh" >/dev/null 2>&1; then
    bad "a --command <x>-suffix call cannot satisfy the <x> presence check" \
      "the lint stayed green with only an \`--open --command triage-feedback\` line"
  else
    ok "a --command <x>-suffix call cannot satisfy the <x> presence check"
  fi
  cp "$TRIAGE_MD" "$SUF/claude/commands/triage.md"
  if bash "$SUF/workflows/scripts/validate-command-run-emit.sh" >/dev/null 2>&1; then
    ok "and is green again on the real triage.md (the discriminating twin)"
  else
    bad "and is green again on the real triage.md" "still red"
  fi
fi

printf '\n'
if [ "$fail" -gt 0 ]; then
  printf 'test_command_run_reconcile: FAILED — %s passed, %s failed\n' "$pass" "$fail"
  exit 1
fi
printf 'test_command_run_reconcile: OK — all %s checks passed\n' "$pass"
