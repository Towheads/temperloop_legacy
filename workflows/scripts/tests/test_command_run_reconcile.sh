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
# Sections 18-19 cover the round-4 review finding — the SAME fail-open class as
# 11 and 14, on its THIRD surface, pre-existing since the guard's first commit
# and missed by all three earlier rounds:
#   18. the OPEN LEDGER directory could not be LISTED, and the guard printed
#       its clean reduction verdict straight over an aged emitted=0
#       MISSING-RUN alarm sitting in it — on the surface that EXPLICIT
#       targeting should make the strictest, and on the MISSING half of the
#       property. Both directory surfaces now share ONE classifier, asserted
#       here mechanically so a fourth surface inherits the guard.
#   19. the header's own completeness claim ("N ways this guard once failed
#       open") had contradicted the code four rounds running, so it is
#       asserted from the file rather than maintained by hand.
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

echo "── 18. the OPEN LEDGER directory is classified too (round 4, HIGH) ──"
# THE SAME fail-open class as sections 11 and 14, on its THIRD surface —
# pre-existing since the guard's first commit and a miss of rounds 1, 2 AND 3.
# The `--open-dir` validation tested directory-ness ONLY (`[ ! -d ]`) while its
# own message said "is not a readable directory", and Check 1's loop gate was a
# bare `[ -d ]`. A ledger that IS a directory but cannot be LISTED made
# `for m in "$open_dir"/*.json` fail to expand, `[ -f "$m" ] || continue`
# swallowed the literal pattern, the loop body never ran, and the guard printed
# its clean verdict over an aged emitted=0 MISSING-RUN alarm sitting right
# there. `--open-dir` is EXPLICIT targeting, so by this guard's own stated
# asymmetry it should be the STRICTEST surface; it was the laxest.
#
# The fix is NOT a third bespoke patch: one shared `classify_dir` helper now
# classifies EVERY directory surface, so a fourth surface inherits the guard.
OL="$TMP/open-ledger"; mkdir -p "$OL/command-run-open"
printf '%s\n' '{"ts":"2026-09-23T19:31:04Z","run_id":"run-present","session_id":"sess-ol","command":"fix","board":7,"items_processed":1,"merged":1,"resolved":0,"parked":0,"reported_no_op":0}' \
  > "$OL/command-runs-2026-09.jsonl"
printf '%s\n' '{"run_id":"run-ALARM","command":"fix","session_id":"sess-ol","board":7,"opened_at":"1970-01-01T00:00:01Z","opened_epoch":1,"emitted":0}' \
  > "$OL/command-run-open/sess-ol__fix.json"

recon --raw-dir "$OL"
check_eq "control: a LISTABLE ledger's aged emitted=0 alarm is read and goes red" "1" "$RECON_RC"
case "$RECON_OUT" in *"MISSING-RUN  run_id=run-ALARM"*) ok "control: and the alarm is named" ;;
  *) bad "control: and the alarm is named" "got [$RECON_OUT]" ;; esac

if [ "$(id -u)" -ne 0 ]; then
  chmod 000 "$OL/command-run-open"

  recon --stream "$OL/command-runs-2026-09.jsonl" --open-dir "$OL/command-run-open"
  check_eq "an UNREADABLE explicitly-named --open-dir: exit 1 (CANNOT EVALUATE), not 0" "1" "$RECON_RC"
  case "$RECON_OUT" in *"record(s) reduce to"*)
      bad "an unlistable open ledger never prints the clean reduction verdict" \
        "it printed exactly that over a hidden alarm: [$RECON_OUT]" ;;
    *) ok "an unlistable open ledger never prints the clean reduction verdict" ;; esac
  case "$RECON_OUT" in *"not a readable, searchable directory"*)
      ok "and the failure says the LEDGER could not be LISTED, not merely that it is absent" ;;
    *) bad "and the failure says the LEDGER could not be LISTED" "got [$RECON_OUT]" ;; esac

  # The DEFAULT twin: the same ledger reached as <lake>/command-run-open. An
  # unlistable directory is an unread input on EVERY surface in EITHER mode,
  # so the shared classifier fails it closed here too.
  recon --raw-dir "$OL"
  check_eq "…and the DEFAULT <lake>/command-run-open twin fails closed identically" "1" "$RECON_RC"
  case "$RECON_OUT" in *"record(s) reduce to"*)
      bad "the default-mode unlistable ledger never prints the clean verdict either" "got [$RECON_OUT]" ;;
    *) ok "the default-mode unlistable ledger never prints the clean verdict either" ;; esac

  chmod 755 "$OL/command-run-open"
  recon --raw-dir "$OL"
  case "$RECON_OUT" in *"MISSING-RUN  run_id=run-ALARM"*)
      ok "GREEN twin: readable again, the SAME ledger's SAME alarm is read once more" ;;
    *) bad "GREEN twin: readable again, the SAME ledger's SAME alarm is read once more" "got [$RECON_OUT]" ;; esac
else
  ok "the unlistable-open-ledger cases [skipped: running as root, where chmod 000 is not a read barrier]"
fi

: > "$TMP/ledger-is-a-file"
recon --stream "$OL/command-runs-2026-09.jsonl" --open-dir "$TMP/ledger-is-a-file"
check_eq "an --open-dir that is NOT A DIRECTORY: exit 1 (CANNOT EVALUATE), not 0" "1" "$RECON_RC"

# The one state that is NOT a failure on this surface: a present, readable
# ledger holding no markers. Every run that opened has closed, which is the
# healthy steady state — failing it would make the guard red on every host.
mkdir -p "$TMP/empty-ledger"
recon --stream "$OL/command-runs-2026-09.jsonl" --open-dir "$TMP/empty-ledger"
check_eq "an EMPTY but readable --open-dir stays GREEN: no open marker is a real, expected state" "0" "$RECON_RC"

# ONE classifier, not three — asserted BEHAVIOURALLY, from the OUTPUT.
#
# The round-4 form of this assertion counted `classify_dir "` call sites and
# passed at >= 2. That assertion could not fail through the drift it names: it
# reads SOURCE TEXT, so a call site that is present but never REACHED still
# satisfies it — which is exactly what round 5 then found (`--open-dir ""`
# skipped the ledger call site entirely and this check stayed green). A test
# that survives its own regression is the silent-green class, so it is
# replaced rather than kept beside the new one.
#
# What actually pins "one shared classifier" is that BOTH surfaces produce the
# SAME sentence for the SAME pathological input, and that the sentence has
# exactly ONE site in the source. A surface re-bespoked with a copy of the
# message makes the source count 2; one re-bespoked with different wording
# fails the output match; one that stops classifying at all prints neither.
SHARED_MSG='is not a directory, so the'
NOTDIR="$TMP/classifier-not-a-dir"; : > "$NOTDIR"
recon --raw-dir "$NOTDIR"
LAKE_RC="$RECON_RC"; LAKE_OUT="$RECON_OUT"
recon --stream "$OL/command-runs-2026-09.jsonl" --open-dir "$NOTDIR"
check_eq "both directory surfaces refuse the SAME not-a-directory target, both exit 1" \
  "1 1" "$LAKE_RC $RECON_RC"
case "$LAKE_OUT" in *"$SHARED_MSG"*)
  case "$RECON_OUT" in *"$SHARED_MSG"*)
      ok "…and both print the SAME shared-classifier sentence, so neither surface is bespoke" ;;
    *) bad "both print the SAME shared-classifier sentence" "the LEDGER surface printed something else: [$RECON_OUT]" ;;
  esac ;;
  *) bad "both print the SAME shared-classifier sentence" "the LAKE surface printed something else: [$LAKE_OUT]" ;;
esac
# `grep -c` exits 1 on zero matches, so the count is taken from the STATUS,
# never from an `|| echo 0` that would concatenate two lines into "0\n0".
MSG_SITES="$(grep -c "$SHARED_MSG" "$RECON" 2>/dev/null)" || MSG_SITES=0
case "$MSG_SITES" in ''|*[!0-9]*) MSG_SITES=0 ;; esac
check_eq "and that sentence has exactly ONE site in the guard (a copy would mean a second classifier)" \
  "1" "$MSG_SITES"

echo "── 19. the header's completeness claims are TRUE at this HEAD (round 5) ──"
# In a guard whose entire job is honest reporting, a completeness claim the
# code contradicts IS a defect. Round 4 was the fourth time this item shipped
# one, so it is asserted mechanically from here on — and round 5 shipped a
# fifth way, so the count moves with the code or this goes red.
grep_ok "the header counts FIVE ways it once failed open" "FIVE WAYS" "$RECON"
for superseded in 'THREE WAYS THIS GUARD ONCE FAILED' 'FOUR WAYS THIS GUARD ONCE FAILED'; do
  if grep -Fq "$superseded" "$RECON"; then
    bad "the superseded claim '$superseded' is gone" "the header still carries it"
  else
    ok "the superseded claim '$superseded' is gone"
  fi
done
grep_ok "the header names the shared classifier by name" "classify_dir" "$RECON"
# Lines 53-55 and 57 of the header (the FAIL CLOSED paragraph and the shared-
# classifier claim) must both be true for an EMPTY operand too — section 20
# is the behavioural half; these are the claims themselves.
grep_ok "the FAIL CLOSED paragraph covers an empty flag operand" \
  "includes a flag whose operand is EMPTY" "$RECON"
grep_ok "the header states the parse-time operand rule" \
  "EVERY FLAG'S OPERAND IS VALIDATED AT PARSE TIME" "$RECON"

echo "── 20. an EMPTY or MISSING flag operand is a USAGE error (round 5, HIGH) ──"
# THE SAME fail-open class as sections 11, 14 and 18 — one level ABOVE every
# surface, in the argument parser, and pre-existing since this guard's first
# commit. `--open-dir ""` recorded the ledger as EXPLICITLY named while
# storing an empty path, and the gate that decided whether to classify it
# asked `[ -n "$open_dir" ]` — NON-EMPTINESS, not explicitness. So the
# classifier never ran, Check 1 never ran, and the clean reduction verdict
# printed straight over the aged emitted=0 alarm section 18 uses. `--raw-dir
# ""` was the mirror image: an emptied operand silently re-targeted this
# host's DEFAULT lake instead of failing closed. The trigger is not a typo
# but a composed invocation — `--open-dir "$LEDGER"` with $LEDGER unset.
#
# $OL (section 18) is the discriminating fixture: a lake holding one record
# plus an aged emitted=0 MISSING-RUN alarm. The GREEN control is right here.
recon --raw-dir "$OL"
check_eq "control: with the ledger reached normally, the aged alarm is READ (exit 1)" "1" "$RECON_RC"
case "$RECON_OUT" in *"MISSING-RUN  run_id=run-ALARM"*) ok "control: and the alarm is named" ;;
  *) bad "control: and the alarm is named" "got [$RECON_OUT]" ;; esac

recon --raw-dir "$OL" --open-dir ""
check_eq "an EMPTY --open-dir operand is a USAGE error (exit 2), never a silent skip" "2" "$RECON_RC"
case "$RECON_OUT" in *"record(s) reduce to"*)
    bad "an empty --open-dir never prints the clean reduction verdict" \
      "it printed exactly that over the hidden alarm: [$RECON_OUT]" ;;
  *) ok "an empty --open-dir never prints the clean reduction verdict" ;; esac
case "$RECON_OUT" in *"FAIL USAGE"*"--open-dir"*) ok "and it says which flag was given no operand" ;;
  *) bad "and it says which flag was given no operand" "got [$RECON_OUT]" ;; esac

# The MISSING-operand twin: the flag as the LAST argument, no operand at all.
recon --raw-dir "$OL" --open-dir
check_eq "a MISSING --open-dir operand fails identically (exit 2)" "2" "$RECON_RC"

# The --raw-dir half of the same bug: an empty operand must NOT fall back to
# this host's default lake, which would report a clean verdict over a lake the
# caller never named.
recon --raw-dir ""
check_eq "an EMPTY --raw-dir operand is a USAGE error, not a silent re-target of the default lake" "2" "$RECON_RC"
case "$RECON_OUT" in *"ok —"*) bad "an empty --raw-dir never reports on the default lake" "got [$RECON_OUT]" ;;
  *) ok "an empty --raw-dir never reports on the default lake" ;; esac

recon --stream "" --open-dir "$OL/command-run-open"
check_eq "an EMPTY --stream operand is a USAGE error too — every flag, one rule" "2" "$RECON_RC"

# The SETTING twin of an empty operand: CMD_RUN_RAW_DIR set but blank — the
# shape `CMD_RUN_RAW_DIR="$LAKE"` produces when $LAKE is unset. It is a
# setting, not a flag, so it fails as CANNOT EVALUATE (1), not USAGE (2).
RECON_OUT="$(CMD_RUN_RAW_DIR="" bash "$RECON" 2>&1)"; RECON_RC=$?
check_eq "a set-but-EMPTY \$CMD_RUN_RAW_DIR fails closed (exit 1), never falls back to the default lake" "1" "$RECON_RC"
case "$RECON_OUT" in *"set but EMPTY"*) ok "and it names the setting as the cause" ;;
  *) bad "and it names the setting as the cause" "got [$RECON_OUT]" ;; esac

# A VALID operand still works — the green twin that proves the parser refuses
# emptiness, not the flag.
recon --raw-dir "$OL" --open-dir "$OL/command-run-open"
check_eq "GREEN twin: the SAME flags with REAL operands still read the alarm (exit 1)" "1" "$RECON_RC"
case "$RECON_OUT" in *"MISSING-RUN  run_id=run-ALARM"*) ok "GREEN twin: and the alarm is named" ;;
  *) bad "GREEN twin: and the alarm is named" "got [$RECON_OUT]" ;; esac

# And the STATIC half: no gate may re-derive explicitness from a path being
# non-empty. This is what stops the class returning on a flag added later.
# shellcheck disable=SC2016  # the single quotes are deliberate: this is the
# literal SOURCE TEXT being searched for, not an expansion.
if grep -Eq 'if \[ -n "\$(open_dir|raw_dir)" \]' "$RECON"; then
  bad "no gate keys on a path being non-empty" \
    "a \`[ -n \"\$open_dir\" ]\`/\`[ -n \"\$raw_dir\" ]\` gate is back — explicitness is a parse-time fact"
else
  ok "no gate keys on a path being non-empty (every gate reads a parse-time *_explicit/*_set flag)"
fi
grep_ok "every value-taking flag routes through one operand validator" "need_operand \"\$1\"" "$RECON"

echo "── 21. the SPEC side of the same class: the --open call's ordering (round 5, HIGH) ──"
# The script half above stops a check being SKIPPED. The spec half stops a
# FALSE alarm being manufactured, which is worse: sweep.md item 8 / triage.md
# item 7 / fix.md item 7 sit in the same "Run in parallel:" list as the item
# that computes $BOARD, and each numbered item is typically its own Bash call
# with no persisted shell state. An open call that runs with $BOARD empty
# writes the marker under the target-LESS key; the terminal emit, by then
# holding a resolved board, computes the target-BEARING key, adopts nothing,
# and mints a second id — leaving an orphan at emitted=0 that prune never
# removes and that ages into a MISSING-RUN alarm that is FALSE.
#
# validate-command-run-emit.sh owns the mechanical check; this asserts it is
# armed AND that it discriminates, by running it over the PRE-fix doc shape.
if [ ! -f "$LINT" ]; then
  bad "the emit lint is present" "missing at $LINT"
else
  LINT_OUT="$(bash "$LINT" 2>&1)"; LINT_RC=$?
  check_eq "the emit lint is GREEN on the real specs" "0" "$LINT_RC"
  case "$LINT_OUT" in *"declares the open call's ordering dependency"*)
      ok "and it reports the ordering check ran on all three caller docs" ;;
    *) bad "and it reports the ordering check ran" "got [$LINT_OUT]" ;; esac

  # RED twin: the same lint over a doc whose open call carries no ordering
  # call-out — a hermetic copy, so nothing outside $TMP is touched.
  ORD="$TMP/ordering-red"; mkdir -p "$ORD/workflows/scripts" "$ORD/claude/commands"
  cp "$LINT" "$ORD/workflows/scripts/" && cp "$EMIT" "$ORD/workflows/scripts/"
  chmod +x "$ORD/workflows/scripts/emit-command-run.sh"
  for d in sweep triage fix; do cp "$REPO/claude/commands/$d.md" "$ORD/claude/commands/$d.md"; done
  # Strip ONLY the ordering call-out from sweep.md — every other line stands,
  # so a red here can be nothing else.
  sed 's/\*\*Runs after item [0-9]\*\*//' \
    "$REPO/claude/commands/sweep.md" > "$ORD/claude/commands/sweep.md"
  ORD_OUT="$(bash "$ORD/workflows/scripts/validate-command-run-emit.sh" 2>&1)"; ORD_RC=$?
  check_eq "RED twin: the lint FAILS a doc whose open call lost its ordering call-out" "1" "$ORD_RC"
  case "$ORD_OUT" in *"no ordering call-out"*) ok "RED twin: and it names the missing call-out" ;;
    *) bad "RED twin: and it names the missing call-out" "got [$ORD_OUT]" ;; esac
fi

# The carve-out sentence must read the SAME in all three specs — a
# best-effort step stated three ways invites an executor to treat one as
# blocking. (The lint asserts it too; this pins the exact shared wording.)
for d in "$SWEEP_MD" "$TRIAGE_MD" "$FIX_MD"; do
  grep_ok "$(basename "$d") carries the shared never-stops-a-run carve-out" \
    "(the telemetry ledger open) never stops a run" "$d"
done

# And the docs MEDIUM: the first mention of #2220 in each caller spec carries
# a title hook, per claude/message-schema.md's reference-token rule.
for d in "$SWEEP_MD" "$TRIAGE_MD" "$FIX_MD"; do
  first="$(grep -n 'temperloop#2220' "$d" | head -1)"
  case "$first" in *"temperloop#2220 — stable command-run id"*)
      ok "$(basename "$d") gives #2220 a first-mention title hook" ;;
    *) bad "$(basename "$d") gives #2220 a first-mention title hook" "first mention was: [$first]" ;;
  esac
done

printf '\n'
if [ "$fail" -gt 0 ]; then
  printf 'test_command_run_reconcile: FAILED — %s passed, %s failed\n' "$pass" "$fail"
  exit 1
fi
printf 'test_command_run_reconcile: OK — all %s checks passed\n' "$pass"
