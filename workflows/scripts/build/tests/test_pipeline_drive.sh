#!/usr/bin/env bash
#
# Tests for workflows/scripts/build/pipeline-drive.sh — the autonomous pipeline
# driver's LAYER-5b safe-actions-only EXECUTOR (foundation #604).
#
# pipeline-drive.sh is a THIN executor: it tiers a tick plan into SAFE (auto-execute,
# no-merge) vs MERGING (leave for the operator) vs no-op-ish, then hands ONLY the
# safe tier to a headless `claude -p "/pipeline-drive"`. These tests run entirely
# OFFLINE: the deterministic tiering is asserted via --dry-run (no claude spawn),
# and the headless invocation is exercised against a CAPTURE DOUBLE that records
# the payload instead of calling the real CLI. Zero network, zero real claude.
#
# Covers:
#   1. tiering — route-*/drain-*/spike-drive land in SAFE; code-drive lands in
#      MERGING; the no-op-ish records (route-already-assigned, …) are dropped.
#   2. the SAFE filter is the structural merge boundary: a kind:code drive is
#      NEVER in the safe set, and a kind-less drive defaults to merging (fail-closed).
#   3. empty safe set → status "empty", no claude spawn (even live).
#   4. live drive → the headless payload carries the safe actions AND the
#      merge-forbidding HARD RULES; the driver's JSON summary is passed through.
#   5. a code-only plan in LIVE mode spawns NO claude (the merging tier never
#      reaches the headless layer) WHEN PIPELINE_DRIVE_MERGE is off (the default).
#   6–12. level 5c (#615) — with PIPELINE_DRIVE_MERGE=1 the kind:code merge tier IS
#      driven via a headless `claude -p "/pipeline-drive-merge"` under the
#      merge-ALLOWING overlay and PIPELINE_OPERATOR_ABSENT=1: the cap is enforced,
#      the gate defaults OFF (no merge drive), a missing merge overlay fails
#      closed, the overlay grants the gh pr/merge/push surface, and both tiers
#      can run in one tick.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRIVE="$HERE/../pipeline-drive.sh"

pass=0
fail=0
ok()  { echo "  ok    $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1: $2"; fail=$((fail + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Make $1 a real git repo on branch $2 (default main) with ONE commit → clean tree.
# The commit matters: an UNBORN branch makes `git rev-parse --abbrev-ref HEAD`
# return "HEAD", which the F#687 clean-on-main check would read as not-main. git
# needs an identity to commit; pass it inline so the suite never depends on the
# machine's git config.
mk_repo() {  # $1 = dir  $2 = branch (default main)
  local d="$1" br="${2:-main}"
  mkdir -p "$d"; git init -q "$d"; git -C "$d" symbolic-ref HEAD "refs/heads/$br"
  git -C "$d" -c user.email=test@test -c user.name=test -c commit.gpgsign=false \
    commit -q --allow-empty -m init
}

# #655: the driver now spawns the headless `claude -p` INSIDE the target board's
# checkout (PIPELINE_CHECKOUT_<n>) so /build's cwd-derived repoRoot+board match the
# action's board/repo. Point every board at a hermetic fake checkout (a dir with a
# .git child — the test double ignores cwd, it only needs `cd` to succeed) so the
# suite never depends on the machine's ~/dev layout, and distinct dirs per board so
# a test can assert which checkout each board's driver ran in. Board 9 is left
# UNMAPPED on purpose (the no-checkout case). Exported → inherited by every child.
# F#687: the merge tier now PRE-FLIGHTS each board's checkout for clean-on-main
# (on `main` + empty `git status --porcelain`) before spawning, so a bare `.git`
# dir no longer passes. Make each fixture a REAL clean-on-main repo so the merge-tier
# tests below spawn as before; dedicated dirty/feature-branch fixtures drive the new
# pre-flight tests (t37/t38).
CO3="$TMP/co3"; CO4="$TMP/co4"
mk_repo "$CO3"; mk_repo "$CO4"
export PIPELINE_CHECKOUT_3="$CO3" PIPELINE_CHECKOUT_4="$CO4"
export PIPELINE_CHECKOUT_5="$CO3" PIPELINE_CHECKOUT_6="$CO3"
export PIPELINE_CHECKOUT_9=""           # explicitly unmapped → no-checkout policy
export PIPELINE_DEFAULT_CHECKOUT="$CO4"  # safe-tier fallback for an unmapped board

# #1157: the #1157 abandonment reclaim (_reclaim_abandoned) shells out to unclaim.sh
# to release a stranded claim. A clean-merge summary ({merged:N,results:[]}) has the
# SAME empty per-issue status as an abandonment, so the reclaim pass RUNS in every
# merge test — point PIPELINE_UNCLAIM_BIN at a global NO-OP double for the WHOLE suite
# so no test can ever invoke the REAL unclaim.sh → real board write. The reclaim
# tests below override PIPELINE_UNCLAIM_BIN with their own per-case recording double.
GLOBAL_UNCLAIM="$TMP/unclaim-noop.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$GLOBAL_UNCLAIM"; chmod +x "$GLOBAL_UNCLAIM"
export PIPELINE_UNCLAIM_BIN="$GLOBAL_UNCLAIM"

# temperloop#1255: every live drive below now calls emit-model-usage.sh (via
# model-usage-envelope.sh) after each spawn — a REAL side effect (an append
# to the model-usage raw lake) that, left unpointed, lands in THIS
# checkout's actual (gitignored but real) meta/data/raw/, exactly the kind
# of test-run pollution the rest of this fixture goes out of its way to
# avoid (GLOBAL_UNCLAIM above is the same isolation move for a different
# side effect). Point it at a throwaway dir under $TMP for the WHOLE suite.
export MODEL_USAGE_RAW_DIR="$TMP/model-usage-raw"

# A synthetic tick-plan ARRAY — the shape pipeline-cron.sh collects (per-board
# {tick,actions[]} objects). One of every action class, so the tiering is exercised
# in full. (A real single tick emits at most one drive-ready — the drive cap — so the
# two drives here are synthetic, to assert spike-vs-code routing in one pass.)
PLANS='[{"tick":"done","actions":[
  {"phase":"route","action":"route-already-assigned","board":"3","repo":"Towheads/stageFind","issue":733},
  {"phase":"drain","action":"drain-answer","board":"3","repo":"Towheads/stageFind","issue":42,"chosen":"timed"},
  {"phase":"drain","action":"drain-parse-miss","board":"3","repo":"Towheads/stageFind","issue":43,"reassign_to":"@towhead"},
  {"phase":"drain","action":"drain-already-applied","board":"3","repo":"Towheads/stageFind","issue":44},
  {"phase":"drain","action":"skip-contention","board":"3","repo":"Towheads/stageFind","issue":45},
  {"phase":"drain","action":"drain-clarification","board":"3","repo":"Towheads/stageFind","issue":46},
  {"phase":"drain","action":"drain-clarification-already-applied","board":"3","repo":"Towheads/stageFind","issue":48},
  {"phase":"drive","action":"drive-ready","board":"3","repo":"Towheads/stageFind","issue":101,"kind":"code"},
  {"phase":"drive","action":"drive-ready","board":"3","repo":"Towheads/stageFind","issue":102,"kind":"spike"},
  {"phase":"tick","action":"no-op","board":"3"}
]}]'

# ── 1: tiering — SAFE vs MERGING vs dropped (the headline) ────────────────────
echo "--- test 1: --dry-run tiers actions into safe / merge / dropped ---"
OUT="$(printf '%s' "$PLANS" | bash "$DRIVE" --dry-run)"

[ "$(jq -r '.status' <<<"$OUT")" = "dry-run" ] && ok "status=dry-run (no spawn)" || bad "t1.status" "got $(jq -r '.status' <<<"$OUT")"
[ "$(jq -r '.driven' <<<"$OUT")" = "4" ] && ok "driven=4 (drain-answer, drain-parse-miss, drain-clarification, spike-drive; #657)" || bad "t1.driven" "got $(jq -r '.driven' <<<"$OUT")"
[ "$(jq -r '.skipped_merge' <<<"$OUT")" = "1" ] && ok "skipped_merge=1 (the code drive)" || bad "t1.skipped" "got $(jq -r '.skipped_merge' <<<"$OUT")"

# SAFE membership — exactly the four safe issues, sorted (drain-clarification joins #657).
[ "$(jq -c '[.safe[].issue]|sort' <<<"$OUT")" = "[42,43,46,102]" ] \
  && ok "safe set = {drain-answer 42, drain-parse-miss 43, drain-clarification 46, spike 102}" \
  || bad "t1.safe-set" "got $(jq -c '[.safe[].issue]|sort' <<<"$OUT")"

# The spike drive IS safe; the code drive is NOT.
jq -e '.safe | any(.action=="drive-ready" and .issue==102 and .kind=="spike")' <<<"$OUT" >/dev/null \
  && ok "spike drive (102) is in the safe tier" || bad "t1.spike" "spike drive missing from safe"
jq -e '.safe | any(.action=="drive-ready" and .issue==101) | not' <<<"$OUT" >/dev/null \
  && ok "code drive (101) is NOT in the safe tier (structural merge boundary)" || bad "t1.code-safe" "code drive leaked into safe"

# The no-op-ish records are dropped from BOTH tiers (incl. the #657 skips).
jq -e '.safe + .merge | any(.action=="route-already-assigned" or .action=="drain-already-applied" or .action=="skip-contention" or .action=="no-op" or .action=="drain-clarification-already-applied") | not' <<<"$OUT" >/dev/null \
  && ok "no-op-ish records (already-assigned/applied/contention/no-op/clarif-applied) are dropped" || bad "t1.dropped" "a no-op-ish record survived"

# MERGING tier = exactly the code drive.
[ "$(jq -c '[.merge[].issue]' <<<"$OUT")" = "[101]" ] \
  && ok "merge tier = {code drive 101} (left for the operator)" || bad "t1.merge" "got $(jq -c '[.merge[].issue]' <<<"$OUT")"

# ── 1b: retro-judge classifies SAFE, no-merge (epic #528, temperloop#535) ─────
# The KERNEL trigger half of the mint-then-judge design: pipeline-tick.sh emits
# `retro-judge` when a due `retro-pending` tracker (build.md 4d-retro's mint,
# #533) is found. It spawns the overlay `/retro --pending` judge — no PR, no
# merge of its own — so it belongs in the SAFE tier alongside the other
# no-merge drains, and `skip-retro-judge` (emitted when no judge is declared)
# is a no-op-ish record dropped from both tiers, same as skip-contention.
echo "--- test 1b: retro-judge classifies SAFE; skip-retro-judge is dropped (no-op-ish) ---"
RETRO_PLANS='[{"tick":"done","actions":[
  {"phase":"retro","action":"retro-judge","board":"3","repo":"Towheads/stageFind","count":2,"reason":"debounce"},
  {"phase":"retro","action":"skip-retro-judge","board":"3","repo":"Towheads/stageFind"}
]}]'
OUT1B="$(printf '%s' "$RETRO_PLANS" | bash "$DRIVE" --dry-run)"
[ "$(jq -r '.status' <<<"$OUT1B")" = "dry-run" ] && ok "t1b status=dry-run" || bad "t1b.status" "got $(jq -r '.status' <<<"$OUT1B")"
jq -e '.safe | any(.action=="retro-judge")' <<<"$OUT1B" >/dev/null \
  && ok "retro-judge lands in the SAFE tier" || bad "t1b.safe" "retro-judge missing from safe: $(jq -c '.safe' <<<"$OUT1B")"
jq -e '.merge | any(.action=="retro-judge") | not' <<<"$OUT1B" >/dev/null \
  && ok "retro-judge never lands in the MERGING tier" || bad "t1b.merge" "retro-judge leaked into merge"
jq -e '.safe + .merge | any(.action=="skip-retro-judge") | not' <<<"$OUT1B" >/dev/null \
  && ok "skip-retro-judge is dropped from both tiers (no-op-ish)" || bad "t1b.skip" "skip-retro-judge survived tiering"
[ "$(jq -r '.driven' <<<"$OUT1B")" = "1" ] && ok "driven=1 (only retro-judge; the skip is not an attempt)" || bad "t1b.driven" "got $(jq -r '.driven' <<<"$OUT1B")"

# ── 2: a kind-less drive defaults to MERGING (fail closed on the merge side) ──
echo "--- test 2: a drive-ready with no kind defaults to merging, never safe ---"
NOKIND='[{"tick":"done","actions":[{"action":"drive-ready","board":"3","repo":"r","issue":201}]}]'
OUT2="$(printf '%s' "$NOKIND" | bash "$DRIVE" --dry-run)"
[ "$(jq -r '.status' <<<"$OUT2")" = "empty" ] && ok "kind-less drive → safe empty → status=empty" || bad "t2.status" "got $(jq -r '.status' <<<"$OUT2")"
[ "$(jq -c '[.merge[].issue]' <<<"$OUT2")" = "[201]" ] && ok "kind-less drive routed to merge (fail-closed)" || bad "t2.merge" "got $(jq -c '[.merge[].issue]' <<<"$OUT2")"

# ── 3: empty safe set → status empty, NO spawn (even live) ────────────────────
echo "--- test 3: code-only + no-op plan → empty, no claude spawn (live) ---"
RAN_MARK="$TMP/should-not-run"
NOSPAWN_DOUBLE="$TMP/double-mark.sh"
printf '%s\n' '#!/usr/bin/env bash' 'touch "$DOUBLE_MARK"' 'echo "{}"' > "$NOSPAWN_DOUBLE"
chmod +x "$NOSPAWN_DOUBLE"
CODE_ONLY='[{"tick":"done","actions":[
  {"action":"drive-ready","board":"3","repo":"r","issue":301,"kind":"code"},
  {"action":"route-already-assigned","board":"3","repo":"r","issue":302}]}]'
OUT3="$(printf '%s' "$CODE_ONLY" | env CLAUDE_BIN="$NOSPAWN_DOUBLE" DOUBLE_MARK="$RAN_MARK" bash "$DRIVE")"
[ "$(jq -r '.status' <<<"$OUT3")" = "empty" ] && ok "code-only live run → status=empty" || bad "t3.status" "got $(jq -r '.status' <<<"$OUT3")"
[ ! -f "$RAN_MARK" ] && ok "no claude spawned — the merging tier never reaches the headless layer" || bad "t3.spawn" "claude was spawned for a code-only plan"
[ "$(jq -c '[.merge[].issue]' <<<"$OUT3")" = "[301]" ] && ok "the code drive is still reported in merge[]" || bad "t3.merge" "got $(jq -c '[.merge[].issue]' <<<"$OUT3")"

# ── 4: live drive → payload carries the safe actions + HARD RULES; summary passthrough ─
echo "--- test 4: live drive hands the safe payload (with hard rules) to claude -p ---"
CAP="$TMP/cap"; mkdir -p "$CAP"
# Capture double: records argv + the /pipeline-drive payload file, returns a canned summary.
CAP_DOUBLE="$TMP/claude-capture.sh"
cat > "$CAP_DOUBLE" <<'DOUBLE'
#!/usr/bin/env bash
set -euo pipefail
prompt=""; prev=""
for a in "$@"; do
  printf '%s\n' "$a" >> "$CAP_DIR/argv.txt"
  [ "$prev" = "-p" ] && prompt="$a"
  prev="$a"
done
# prompt looks like: /pipeline-drive /tmp/pipeline-drive.XXXX
payload="${prompt#/pipeline-drive }"
[ -f "$payload" ] && cp "$payload" "$CAP_DIR/payload.json"
echo '{"driver":"pipeline-drive","layer":"5b","executed":3,"failed":0,"refused":0,"results":[]}'
DOUBLE
chmod +x "$CAP_DOUBLE"

OUT4="$(printf '%s' "$PLANS" | env CLAUDE_BIN="$CAP_DOUBLE" CAP_DIR="$CAP" PIPELINE_DRIVE_MODEL="claude-test" bash "$DRIVE")"
[ "$(jq -r '.status' <<<"$OUT4")" = "ran" ] && ok "live drive → status=ran" || bad "t4.status" "got $(jq -r '.status' <<<"$OUT4")"
# The driver's JSON summary is passed through verbatim under .result.
[ "$(jq -r '.result.executed' <<<"$OUT4")" = "3" ] && ok "driver summary passed through (.result.executed=3)" || bad "t4.result" "got $(jq -r '.result.executed // "none"' <<<"$OUT4")"
# …and its outcome counts are parsed back into the wake record (#636).
[ "$(jq -r '.driven' <<<"$OUT4")" = "4" ] && ok "driven=4 (4 safe actions handed to the driver; drain-clarification joins #657)" || bad "t4.driven" "got $(jq -r '.driven' <<<"$OUT4")"
[ "$(jq -r '.safe_executed' <<<"$OUT4")" = "3" ] && ok "safe_executed=3 (driver reported 3 executed)" || bad "t4.safe_executed" "got $(jq -r '.safe_executed' <<<"$OUT4")"
[ "$(jq -r '.safe_refused' <<<"$OUT4")" = "0" ] && ok "safe_refused=0 (clean run)" || bad "t4.safe_refused" "got $(jq -r '.safe_refused' <<<"$OUT4")"
# The headless invocation used -p and the configured model.
grep -qx -- "-p" "$CAP/argv.txt" && ok "claude invoked with -p (headless)" || bad "t4.flag" "no -p in argv"
grep -qx "claude-test" "$CAP/argv.txt" && ok "claude invoked with the configured model" || bad "t4.model" "model not passed"
# The payload file carried the SAFE actions only…
[ -f "$CAP/payload.json" ] && ok "a payload file was handed to the driver" || bad "t4.payload" "no payload captured"
[ "$(jq -c '[.actions[].issue]|sort' "$CAP/payload.json")" = "[42,43,46,102]" ] \
  && ok "payload.actions = the safe set only (no code drive, no no-ops)" || bad "t4.payload-actions" "got $(jq -c '[.actions[].issue]|sort' "$CAP/payload.json")"
# …and the merge-forbidding HARD RULES (defense-in-depth restatement).
jq -e '[.hard_rules[]] | any(test("NEVER merge"))' "$CAP/payload.json" >/dev/null \
  && ok "payload carries the 'NEVER merge' hard rule" || bad "t4.rule-merge" "no merge prohibition in payload"
jq -e '[.hard_rules[]] | any(test("kind:code"))' "$CAP/payload.json" >/dev/null \
  && ok "payload carries the 'never drive a kind:code item' hard rule" || bad "t4.rule-code" "no code-drive prohibition in payload"
# Containment (#606): the headless invocation is launched UNDER the --settings deny
# overlay and NEVER with --dangerously-skip-permissions.
OVERLAY="$(cd "$HERE/.." && pwd)/pipeline-drive.settings.json"
grep -qx -- "--settings" "$CAP/argv.txt" \
  && ok "claude invoked with --settings (containment overlay)" || bad "t4.settings-flag" "no --settings in argv"
grep -qxF "$OVERLAY" "$CAP/argv.txt" \
  && ok "claude invoked with the repo-relative overlay path" || bad "t4.settings-path" "overlay path not in argv"
grep -q "dangerously-skip-permissions" "$CAP/argv.txt" \
  && bad "t4.no-bypass" "--dangerously-skip-permissions was passed" || ok "claude NOT invoked with --dangerously-skip-permissions"

# ── 4b: the retro-judge action carries a credential-bearing spawn_cmd (#1148) ─
# The 2026-08-05 failure was a SECOND hop: the driver typed a bare `claude -p
# "/retro --pending"` into its Bash tool, and that child inherited none of the
# driver's credentials, so on a headless host with an expired interactive OAuth
# session it died before turn 1. The structural fix asserted here is that the
# driver is never asked to type that command at all — the payload hands it an
# absolute `spawn_cmd` pointing at the wrapper that re-derives the credential at
# the spawn site. This asserts the SEAM, not a real retro run (there is no
# `/retro` in a kernel checkout, and #1150's capability gate would refuse it).
echo "--- test 4b: a retro-judge action carries an absolute, credential-bearing spawn_cmd ---"
CAP4B="$TMP/cap4b"; mkdir -p "$CAP4B"
RJ_PLANS='[{"tick":"done","actions":[
  {"phase":"retro","action":"retro-judge","board":"3","repo":"Towheads/stageFind","count":2,"reason":"debounce"}
]}]'
OUT4B="$(printf '%s' "$RJ_PLANS" | env CLAUDE_BIN="$CAP_DOUBLE" CAP_DIR="$CAP4B" \
  PIPELINE_DRIVE_MODEL="claude-test" bash "$DRIVE")"
[ "$(jq -r '.status' <<<"$OUT4B")" = "ran" ] && ok "retro-judge drives live" || bad "t4b.status" "$OUT4B"
SPAWN="$(jq -r '.actions[] | select(.action=="retro-judge") | .spawn_cmd // ""' "$CAP4B/payload.json" 2>/dev/null)"
[ -n "$SPAWN" ] && ok "the retro-judge action carries a spawn_cmd" || bad "t4b.present" "payload: $(cat "$CAP4B/payload.json" 2>/dev/null)"
case "$SPAWN" in
  /*pipeline-retro-judge-spawn.sh*) ok "spawn_cmd is an ABSOLUTE path to the credential-bearing wrapper (survives the driver's cd into a board checkout)" ;;
  *) bad "t4b.abs" "got '$SPAWN'" ;;
esac
case "$SPAWN" in
  *"--board 3"*) ok "spawn_cmd carries the action's own board" ;;
  *) bad "t4b.board" "got '$SPAWN'" ;;
esac
[ -x "${SPAWN%% *}" ] && ok "and that wrapper exists and is executable in this checkout" || bad "t4b.exec" "not executable: ${SPAWN%% *}"
jq -e '[.hard_rules[]] | any(test("spawn_cmd"))' "$CAP4B/payload.json" >/dev/null \
  && ok "a HARD RULE forbids the driver typing a bare claude -p for the judge" || bad "t4b.rule" "$(jq -c '.hard_rules' "$CAP4B/payload.json")"
jq -e '.actions[] | select(.action=="retro-judge") | .spawn_cmd | test("OAUTH|ANTHROPIC_API_KEY|sk-")|not' "$CAP4B/payload.json" >/dev/null \
  && ok "no credential (or credential-shaped value) is ever written into the payload" || bad "t4b.secret" "$SPAWN"

# ── 5a: a configured-but-missing overlay fails CLOSED (no spawn) ──────────────
echo "--- test 5a: a missing settings overlay fails closed (no claude spawn) ---"
MISS_MARK="$TMP/should-not-spawn-missing"
OUT5A="$(printf '%s' "$PLANS" | env CLAUDE_BIN="$NOSPAWN_DOUBLE" DOUBLE_MARK="$MISS_MARK" \
          PIPELINE_DRIVE_SETTINGS="$TMP/nope-not-here.json" bash "$DRIVE")"
[ "$(jq -r '.status' <<<"$OUT5A")" = "error" ] && ok "missing overlay → status=error (fail-closed)" || bad "t5a.status" "got $(jq -r '.status' <<<"$OUT5A")"
[ ! -f "$MISS_MARK" ] && ok "no claude spawned with a missing overlay (never runs uncontained)" || bad "t5a.spawn" "claude spawned despite missing overlay"

# ── 5b: the policy file itself denies the merge/PR/push surface ───────────────
echo "--- test 5b: pipeline-drive.settings.json denies gh pr + git push ---"
POLICY="$(cd "$HERE/.." && pwd)/pipeline-drive.settings.json"
[ -f "$POLICY" ] && ok "overlay policy file exists" || bad "t5b.exists" "policy file missing at $POLICY"
jq -e '.permissions.deny | index("Bash(gh pr:*)")' "$POLICY" >/dev/null \
  && ok "policy denies Bash(gh pr:*)" || bad "t5b.deny-pr" "gh pr not denied"
jq -e '.permissions.deny | index("Bash(git push:*)")' "$POLICY" >/dev/null \
  && ok "policy denies Bash(git push:*)" || bad "t5b.deny-push" "git push not denied"

# ── 5c: the policy file grants the broad allow the full safe tier needs (#609) ─
# Without an allow block the headless driver (untrusted workspace) is denied
# Read/Bash wholesale and no-ops; these entries let route/drain/assess/spike act
# while deny (above) still blocks the merge surface (deny > allow).
echo "--- test 5c: pipeline-drive.settings.json allows the safe-tier surface ---"
for entry in "Bash" "Read" "Edit" "Write" "Task" "mcp__obsidian__*"; do
  jq -e --arg e "$entry" '.permissions.allow | index($e)' "$POLICY" >/dev/null \
    && ok "policy allows $entry" || bad "t5c.allow" "allow missing $entry"
done

# ── 5: malformed / empty input is fail-open (never wedges the cron) ──────────
echo "--- test 5: malformed input fails open to an empty drive ---"
OUT5="$(printf 'not json at all' | bash "$DRIVE" --dry-run)"
[ "$(jq -r '.status' <<<"$OUT5")" = "empty" ] && ok "garbage input → status=empty (fail-open)" || bad "t5.status" "got $(jq -r '.status' <<<"$OUT5")"

# ╭──────────────────────────────────────────────────────────────────────────╮
# │ LAYER 5c — the merge tier (#615). PIPELINE_DRIVE_MERGE=1 drives kind:code.    │
# ╰──────────────────────────────────────────────────────────────────────────╯

# A dual capture double: records argv + which prose command + the PIPELINE_OPERATOR_ABSENT
# env, copies each tier's payload, and returns the matching canned summary. Distinguishes
# /pipeline-drive (safe) from /pipeline-drive-merge (5c merge).
make_merge_double() {  # $1 = capture dir
  local d="$1" f="$1/double.sh"
  cat > "$f" <<'DOUBLE'
#!/usr/bin/env bash
set -euo pipefail
prompt=""; prev=""
for a in "$@"; do
  printf '%s\n' "$a" >> "$CAP_DIR/argv.txt"
  [ "$prev" = "-p" ] && prompt="$a"
  prev="$a"
done
printf 'opabsent=%s prompt=%s\n' "${PIPELINE_OPERATOR_ABSENT:-unset}" "$prompt" >> "$CAP_DIR/calls.txt"
printf '%s\t%s\n' "$PWD" "$prompt" >> "$CAP_DIR/pwd.txt"
case "$prompt" in
  "/pipeline-drive-merge "*)
    payload="${prompt#/pipeline-drive-merge }"
    [ -f "$payload" ] && cp "$payload" "$CAP_DIR/merge-payload.json"
    # The canned Step-3 summary. Tests override MERGE_SUMMARY to exercise the
    # park/refuse outcomes (#620); default = one clean merge.
    summary="${MERGE_SUMMARY:-}"
    [ -z "$summary" ] && summary='{"driver":"pipeline-drive-merge","layer":"5c","merged":1,"parked":0,"failed":0,"refused":0,"results":[]}'
    if [ "${MERGE_WRAP:-0}" = "1" ]; then
      # Emit the PRODUCTION shape: a `claude -p --output-format json` envelope
      # carrying the summary as a ```json fenced block inside .result, so the
      # extractor's fence-parsing path (not just top-level) is under test.
      text="Parked the item. Emitting the Step 3 summary:"$'\n\n'"\`\`\`json"$'\n'"$summary"$'\n'"\`\`\`"
      jq -cn --arg t "$text" '{type:"result",subtype:"success",is_error:false,result:$t}'
    else
      printf '%s\n' "$summary"
    fi
    ;;
  "/pipeline-drive "*)
    payload="${prompt#/pipeline-drive }"
    [ -f "$payload" ] && cp "$payload" "$CAP_DIR/safe-payload.json"
    # The canned Step-3 summary. Tests override SAFE_SUMMARY to exercise the safe-tier
    # refuse outcome (F#1053 route-foundational park); default = one clean execution.
    ssummary="${SAFE_SUMMARY:-}"
    [ -z "$ssummary" ] && ssummary='{"driver":"pipeline-drive","layer":"5b","executed":1,"failed":0,"refused":0,"results":[]}'
    printf '%s\n' "$ssummary"
    ;;
  *) echo '{}' ;;
esac
DOUBLE
  chmod +x "$f"
  printf '%s' "$f"
}

MERGE_OVERLAY="$(cd "$HERE/.." && pwd)/pipeline-drive-merge.settings.json"
# A realistic single code drive (a tick is drive-capped to ~one drive).
CODE1='[{"tick":"done","actions":[
  {"phase":"drive","action":"drive-ready","board":"3","repo":"Towheads/stageFind","issue":101,"kind":"code","emit":"/build"}]}]'

# ── 6: PIPELINE_DRIVE_MERGE=1 drives the code tier via /pipeline-drive-merge ───────
echo "--- test 6: gate ON → the code drive is executed via /pipeline-drive-merge ---"
C6="$TMP/c6"; mkdir -p "$C6"; D6="$(make_merge_double "$C6")"
OUT6="$(printf '%s' "$CODE1" | env CLAUDE_BIN="$D6" CAP_DIR="$C6" \
        PIPELINE_DRIVE_MERGE=1 PIPELINE_DRIVE_MERGE_MODEL="merge-model-test" bash "$DRIVE")"
[ "$(jq -r '.status' <<<"$OUT6")" = "ran" ] && ok "gate on + code drive → status=ran" || bad "t6.status" "got $(jq -r '.status' <<<"$OUT6")"
[ "$(jq -r '.merge_driven' <<<"$OUT6")" = "1" ] && ok "merge_driven=1 (code item handed to the merge driver)" || bad "t6.merge_driven" "got $(jq -r '.merge_driven' <<<"$OUT6")"
[ "$(jq -r '.merged_pr' <<<"$OUT6")" = "1" ] && ok "merged_pr=1 (driver reported one real merge)" || bad "t6.merged_pr" "got $(jq -r '.merged_pr' <<<"$OUT6")"
[ "$(jq -r '.skipped_merge' <<<"$OUT6")" = "0" ] && ok "skipped_merge=0 (nothing left for operator)" || bad "t6.skipped" "got $(jq -r '.skipped_merge' <<<"$OUT6")"
[ "$(jq -r '.merge_result.merged' <<<"$OUT6")" = "1" ] && ok "merge driver summary passed through (.merge_result.merged=1)" || bad "t6.mresult" "got $(jq -r '.merge_result.merged // "none"' <<<"$OUT6")"
grep -q '^/pipeline-drive-merge ' "$C6/argv.txt" && ok "claude invoked with the /pipeline-drive-merge command" || bad "t6.cmd" "no /pipeline-drive-merge in argv"
grep -qx "merge-model-test" "$C6/argv.txt" && ok "merge driver used the configured merge model" || bad "t6.model" "merge model not passed"
grep -qxF "$MERGE_OVERLAY" "$C6/argv.txt" && ok "merge driver launched under the merge-allowing overlay" || bad "t6.overlay" "merge overlay path not in argv"
grep -q '^opabsent=1 ' "$C6/calls.txt" && ok "merge driver ran with PIPELINE_OPERATOR_ABSENT=1 (build's operator-absent regime)" || bad "t6.opabsent" "PIPELINE_OPERATOR_ABSENT not set for the merge call"
grep -q "dangerously-skip-permissions" "$C6/argv.txt" && bad "t6.no-bypass" "--dangerously-skip-permissions was passed" || ok "merge driver NOT invoked with --dangerously-skip-permissions"
# Merge payload shape: level 5c, the cap, the code action, and the scoped hard rules.
[ "$(jq -r '.layer' "$C6/merge-payload.json")" = "5c" ] && ok "merge payload layer=5c" || bad "t6.payload-layer" "got $(jq -r '.layer' "$C6/merge-payload.json")"
[ "$(jq -c '[.actions[].issue]' "$C6/merge-payload.json")" = "[101]" ] && ok "merge payload carries the code drive (101)" || bad "t6.payload-actions" "got $(jq -c '[.actions[].issue]' "$C6/merge-payload.json")"
jq -e '[.hard_rules[]] | any(test("Merge ONLY through /build"))' "$C6/merge-payload.json" >/dev/null \
  && ok "merge payload carries the 'merge only through /build' hard rule" || bad "t6.rule" "no /build-only rule in merge payload"
jq -e '[.hard_rules[]] | any(test("never force-merge"))' "$C6/merge-payload.json" >/dev/null \
  && ok "merge payload carries the 'never force-merge a risky set' hard rule" || bad "t6.rule2" "no force-merge prohibition in merge payload"

# ── 7: the per-tick cap bounds how many code items are driven ─────────────────
echo "--- test 7: PIPELINE_DRIVE_MERGE_CAP caps the merge tier ---"
CODE2='[{"tick":"done","actions":[
  {"action":"drive-ready","board":"3","repo":"r","issue":101,"kind":"code","emit":"/build"},
  {"action":"drive-ready","board":"3","repo":"r","issue":102,"kind":"code","emit":"/build"}]}]'
C7="$TMP/c7"; mkdir -p "$C7"; D7="$(make_merge_double "$C7")"
OUT7="$(printf '%s' "$CODE2" | env CLAUDE_BIN="$D7" CAP_DIR="$C7" \
        PIPELINE_DRIVE_MERGE=1 PIPELINE_DRIVE_MERGE_CAP=1 bash "$DRIVE")"
[ "$(jq -r '.merge_driven' <<<"$OUT7")" = "1" ] && ok "cap=1 → merge_driven=1 (only one handed to the driver)" || bad "t7.merge_driven" "got $(jq -r '.merge_driven' <<<"$OUT7")"
[ "$(jq -r '.skipped_merge' <<<"$OUT7")" = "1" ] && ok "the over-cap code item is reported skipped_merge=1" || bad "t7.skipped" "got $(jq -r '.skipped_merge' <<<"$OUT7")"
[ "$(jq -c '[.actions[].issue]' "$C7/merge-payload.json")" = "[101]" ] && ok "merge payload sliced to the cap (only 101)" || bad "t7.payload" "got $(jq -c '[.actions[].issue]' "$C7/merge-payload.json")"
# The full merge tier (both) is still surfaced for visibility.
[ "$(jq -c '[.merge[].issue]|sort' <<<"$OUT7")" = "[101,102]" ] && ok "both code items still surfaced in merge[]" || bad "t7.merge-surface" "got $(jq -c '[.merge[].issue]|sort' <<<"$OUT7")"

# ── 8: gate OFF (default) → the merge tier is NOT driven ──────────────────────
echo "--- test 8: with PIPELINE_DRIVE_MERGE unset, a code drive is surfaced, not driven ---"
C8="$TMP/c8"; mkdir -p "$C8"; D8="$(make_merge_double "$C8")"
# The full mixed fixture (safe + code). Default gate ⇒ safe driven, merge untouched.
OUT8="$(printf '%s' "$PLANS" | env CLAUDE_BIN="$D8" CAP_DIR="$C8" bash "$DRIVE")"
[ "$(jq -r '.merge_driven' <<<"$OUT8")" = "0" ] && ok "gate off → merge_driven=0" || bad "t8.merge_driven" "got $(jq -r '.merge_driven' <<<"$OUT8")"
[ "$(jq -r '.merged_pr' <<<"$OUT8")" = "0" ] && ok "gate off → merged_pr=0 (definitive, merge tier never ran)" || bad "t8.merged_pr" "got $(jq -r '.merged_pr' <<<"$OUT8")"
[ "$(jq -r '.merge_result' <<<"$OUT8")" = "null" ] && ok "gate off → merge_result is null (no merge driver)" || bad "t8.mresult" "got $(jq -r '.merge_result' <<<"$OUT8")"
grep -q '^/pipeline-drive-merge ' "$C8/argv.txt" && bad "t8.spawn" "/pipeline-drive-merge spawned with the gate off" || ok "no /pipeline-drive-merge spawned with the gate off"
[ "$(jq -r '.skipped_merge' <<<"$OUT8")" = "1" ] && ok "the code drive is left for the operator (skipped_merge=1)" || bad "t8.skipped" "got $(jq -r '.skipped_merge' <<<"$OUT8")"

# ── 9: a missing merge overlay fails CLOSED (no spawn) ────────────────────────
echo "--- test 9: gate on + missing merge overlay → status=error, no merge spawn ---"
C9="$TMP/c9"; mkdir -p "$C9"; D9="$(make_merge_double "$C9")"
OUT9="$(printf '%s' "$CODE1" | env CLAUDE_BIN="$D9" CAP_DIR="$C9" \
        PIPELINE_DRIVE_MERGE=1 PIPELINE_DRIVE_MERGE_SETTINGS="$TMP/no-merge-overlay.json" bash "$DRIVE")"
[ "$(jq -r '.status' <<<"$OUT9")" = "error" ] && ok "missing merge overlay → status=error (fail-closed)" || bad "t9.status" "got $(jq -r '.status' <<<"$OUT9")"
jq -e '.merge_result.reason | test("merge settings overlay missing")' <<<"$OUT9" >/dev/null \
  && ok "the error names the missing merge overlay" || bad "t9.reason" "got $(jq -c '.merge_result' <<<"$OUT9")"
[ ! -f "$C9/calls.txt" ] && ok "no claude spawned with a missing merge overlay (never runs uncontained)" || bad "t9.spawn" "merge driver spawned despite missing overlay"

# ── 10: the merge overlay grants the gh pr/merge/push surface (and denies none) ─
echo "--- test 10: pipeline-drive-merge.settings.json ALLOWS the merge surface ---"
[ -f "$MERGE_OVERLAY" ] && ok "merge overlay policy file exists" || bad "t10.exists" "missing at $MERGE_OVERLAY"
for entry in "Bash(gh pr:*)" "Bash(gh pr merge:*)" "Bash(git push:*)"; do
  jq -e --arg e "$entry" '.permissions.allow | index($e)' "$MERGE_OVERLAY" >/dev/null \
    && ok "merge overlay allows $entry" || bad "t10.allow" "allow missing $entry"
done
jq -e '.permissions | has("deny") | not' "$MERGE_OVERLAY" >/dev/null \
  && ok "merge overlay has NO deny block (the inverse of the 5b overlay)" || bad "t10.no-deny" "merge overlay unexpectedly denies something"

# ── 11: --dry-run with the gate on previews the merge drive WITHOUT spawning ──
echo "--- test 11: gate on + --dry-run previews the merge tiering, no spawn ---"
C11="$TMP/c11"; mkdir -p "$C11"; D11="$(make_merge_double "$C11")"
OUT11="$(printf '%s' "$CODE1" | env CLAUDE_BIN="$D11" CAP_DIR="$C11" PIPELINE_DRIVE_MERGE=1 bash "$DRIVE" --dry-run)"
[ "$(jq -r '.status' <<<"$OUT11")" = "dry-run" ] && ok "gate on + --dry-run → status=dry-run" || bad "t11.status" "got $(jq -r '.status' <<<"$OUT11")"
[ "$(jq -r '.merge_driven' <<<"$OUT11")" = "1" ] && ok "dry-run reports merge_driven=1 (what WOULD be handed to the driver)" || bad "t11.merge_driven" "got $(jq -r '.merge_driven' <<<"$OUT11")"
[ "$(jq -r '.merged_pr' <<<"$OUT11")" = "0" ] && ok "dry-run merged_pr=0 (a preview merges nothing)" || bad "t11.merged_pr" "got $(jq -r '.merged_pr' <<<"$OUT11")"
[ ! -f "$C11/calls.txt" ] && ok "no claude spawned on --dry-run (cron --dry-run stays pure)" || bad "t11.spawn" "claude spawned on --dry-run"

# ── 12: both tiers in one tick — safe AND merge drivers run ───────────────────
echo "--- test 12: a mixed plan + gate on drives BOTH the safe and merge tiers ---"
C12="$TMP/c12"; mkdir -p "$C12"; D12="$(make_merge_double "$C12")"
OUT12="$(printf '%s' "$PLANS" | env CLAUDE_BIN="$D12" CAP_DIR="$C12" PIPELINE_DRIVE_MERGE=1 bash "$DRIVE")"
[ "$(jq -r '.status' <<<"$OUT12")" = "ran" ] && ok "mixed plan + gate on → status=ran" || bad "t12.status" "got $(jq -r '.status' <<<"$OUT12")"
[ "$(jq -r '.driven' <<<"$OUT12")" = "4" ] && ok "safe tier still driven (driven=4; drain-clarification joins #657)" || bad "t12.driven" "got $(jq -r '.driven' <<<"$OUT12")"
[ "$(jq -r '.merge_driven' <<<"$OUT12")" = "1" ] && ok "merge tier also driven (merge_driven=1)" || bad "t12.merge_driven" "got $(jq -r '.merge_driven' <<<"$OUT12")"
grep -q '^/pipeline-drive ' "$C12/argv.txt" && ok "the safe /pipeline-drive command ran" || bad "t12.safe-cmd" "no /pipeline-drive in argv"
grep -q '^/pipeline-drive-merge ' "$C12/argv.txt" && ok "the merge /pipeline-drive-merge command ran" || bad "t12.merge-cmd" "no /pipeline-drive-merge in argv"
[ -f "$C12/safe-payload.json" ] && [ "$(jq -c '[.actions[].issue]|sort' "$C12/safe-payload.json")" = "[42,43,46,102]" ] \
  && ok "safe payload = the safe set (code drive excluded)" || bad "t12.safe-payload" "got $(jq -c '[.actions[].issue]|sort' "$C12/safe-payload.json" 2>/dev/null)"
[ -f "$C12/merge-payload.json" ] && [ "$(jq -c '[.actions[].issue]' "$C12/merge-payload.json")" = "[101]" ] \
  && ok "merge payload = the code drive only (101)" || bad "t12.merge-payload" "got $(jq -c '[.actions[].issue]' "$C12/merge-payload.json" 2>/dev/null)"

# ── 13: a PARKED drive is driven-but-not-merged (the #620 regression) ─────────
# The merge driver correctly parks a decision-gated item: it WAS handed to the
# driver (merge_driven=1) but NOTHING merged (merged_pr=0). The bug was conflating
# the two — reporting the old `merged` field from the driven-attempt count, so a
# park looked like a merge in the soak telemetry.
echo "--- test 13: a parked drive → merge_driven=1 but merged_pr=0 (#620) ---"
C13="$TMP/c13"; mkdir -p "$C13"; D13="$(make_merge_double "$C13")"
PARK_SUMMARY='{"driver":"pipeline-drive-merge","layer":"5c","merged":0,"parked":1,"failed":0,"refused":0,"results":[{"action":"drive-ready","issue":101,"status":"parked","pr":null}]}'
OUT13="$(printf '%s' "$CODE1" | env CLAUDE_BIN="$D13" CAP_DIR="$C13" \
        PIPELINE_DRIVE_MERGE=1 MERGE_SUMMARY="$PARK_SUMMARY" bash "$DRIVE")"
[ "$(jq -r '.merge_driven' <<<"$OUT13")" = "1" ] && ok "parked item still counts as driven (merge_driven=1)" || bad "t13.merge_driven" "got $(jq -r '.merge_driven' <<<"$OUT13")"
[ "$(jq -r '.merged_pr' <<<"$OUT13")" = "0" ] && ok "parked item did NOT merge (merged_pr=0) — the #620 fix" || bad "t13.merged_pr" "got $(jq -r '.merged_pr' <<<"$OUT13")"
[ "$(jq -r '.parked' <<<"$OUT13")" = "1" ] && ok "the park is surfaced (parked=1)" || bad "t13.parked" "got $(jq -r '.parked' <<<"$OUT13")"
[ "$(jq -r '.failed' <<<"$OUT13")" = "0" ] && ok "failed=0" || bad "t13.failed" "got $(jq -r '.failed' <<<"$OUT13")"

# ── 14: counts are parsed from the PRODUCTION claude envelope (fenced summary) ─
# In production the summary arrives inside `claude -p --output-format json`'s
# .result as a ```json fenced block, not bare. Prove the extractor digs it out —
# otherwise every real tick would fall through to the "unknown" (null) branch.
echo "--- test 14: merged_pr parsed from a fenced summary in the claude envelope ---"
C14="$TMP/c14"; mkdir -p "$C14"; D14="$(make_merge_double "$C14")"
OUT14="$(printf '%s' "$CODE1" | env CLAUDE_BIN="$D14" CAP_DIR="$C14" \
        PIPELINE_DRIVE_MERGE=1 MERGE_WRAP=1 MERGE_SUMMARY="$PARK_SUMMARY" bash "$DRIVE")"
[ "$(jq -r '.merged_pr' <<<"$OUT14")" = "0" ] && ok "merged_pr=0 extracted from the fenced envelope" || bad "t14.merged_pr" "got $(jq -r '.merged_pr' <<<"$OUT14")"
[ "$(jq -r '.parked' <<<"$OUT14")" = "1" ] && ok "parked=1 extracted from the fenced envelope" || bad "t14.parked" "got $(jq -r '.parked' <<<"$OUT14")"
[ "$(jq -r '.merge_driven' <<<"$OUT14")" = "1" ] && ok "merge_driven=1 (production-shape result)" || bad "t14.merge_driven" "got $(jq -r '.merge_driven' <<<"$OUT14")"

# ── 15: a merge tier that ran but emitted GARBAGE → merged_pr=null (never 0) ───
# Unparseable driver output must read as UNKNOWN, not a false "0 merges" — a soak
# rollup distinguishes null (couldn't tell) from a real 0 (#620).
echo "--- test 15: unparseable merge output → merged_pr=null (unknown, not a false 0) ---"
C15="$TMP/c15"; mkdir -p "$C15"; D15="$(make_merge_double "$C15")"
OUT15="$(printf '%s' "$CODE1" | env CLAUDE_BIN="$D15" CAP_DIR="$C15" \
        PIPELINE_DRIVE_MERGE=1 MERGE_SUMMARY="not json at all" bash "$DRIVE")"
[ "$(jq -r '.merged_pr' <<<"$OUT15")" = "null" ] && ok "garbage merge output → merged_pr=null (unknown)" || bad "t15.merged_pr" "got $(jq -r '.merged_pr' <<<"$OUT15")"
[ "$(jq -r '.merge_driven' <<<"$OUT15")" = "1" ] && ok "the attempt is still recorded (merge_driven=1)" || bad "t15.merge_driven" "got $(jq -r '.merge_driven' <<<"$OUT15")"

# ╭──────────────────────────────────────────────────────────────────────────╮
# │ foundation #622 — refused/failed items are ROUTED to the operator, not    │
# │ left as a dead-end. The merge driver only reports; pipeline-drive.sh assigns │
# │ + labels `funnel-escalated` (its OWN gate since #697 — not the shared     │
# │ `needs-clarification`) + comments (deterministic, shell-side).            │
# ╰──────────────────────────────────────────────────────────────────────────╯

# A gh double: records every invocation so a routing edit/comment can be asserted.
# `pr list` is served from GH_PR_LIST_JSON (default empty) so the #624 hand-off probe
# (_open_pr_for_issue) can be driven offline; it is NOT recorded as a mutation (it is a
# read), keeping the routing-edit/comment assertions clean.
make_gh_double() {  # $1 = capture dir
  local d="$1" f="$1/gh.sh"
  cat > "$f" <<'GHDOUBLE'
#!/usr/bin/env bash
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "list" ]; then
  printf '%s' "${GH_PR_LIST_JSON:-[]}"
  exit 0
fi
# `issue list --label funnel-merge-pending --json number,state` — the #718 reconciliation
# probe (_reconcile_pending). Served from GH_PENDING_JSON (default [] → no standing
# merge-pending set), and NOT recorded (it is a read, keeping the routing/reconcile-EDIT
# assertions clean). The label-remove write it may trigger IS recorded (an `issue edit`).
if [ "${1:-}" = "issue" ] && [ "${2:-}" = "list" ]; then
  printf '%s' "${GH_PENDING_JSON:-[]}"
  exit 0
fi
# `pr view ... --json statusCheckRollup` — the #665 terminal-red probe. Served from
# GH_PR_VIEW_JSON (default empty → probe reads it as "not terminal", i.e. resume),
# and NOT recorded (it is a read, keeping the routing-edit assertions clean).
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ]; then
  printf '%s' "${GH_PR_VIEW_JSON:-}"
  exit 0
fi
# `issue view N --json state --jq .state` — the #1157 reclaim's condition-(d) probe
# (_reclaim_abandoned). Served from GH_ISSUE_STATE (default OPEN → the issue is live,
# so a no-PR/no-terminal item is genuinely stranded and eligible for reclaim), and
# NOT recorded (it is a read, keeping the routing-edit assertions clean).
if [ "${1:-}" = "issue" ] && [ "${2:-}" = "view" ]; then
  printf '%s' "${GH_ISSUE_STATE:-OPEN}"
  exit 0
fi
# `api repos/.../issues/N/timeline` — the #910 operator-disposition probe
# (_operator_dispositioned). Served from GH_TIMELINE_JSON (default empty → the probe
# reads it as "no unlabeled event", i.e. NOT dispositioned → route as before), and
# NOT recorded (it is a read, keeping the routing-edit/comment assertions clean).
if [ "${1:-}" = "api" ]; then
  printf '%s' "${GH_TIMELINE_JSON:-}"
  exit 0
fi
printf '%s\n' "$*" >> "$CAP_DIR/gh-calls.txt"
for a in "$@"; do printf '%s\n' "$a" >> "$CAP_DIR/gh-argv.txt"; done
# Forced-failure mode (#641): if the joined argv matches GH_FAIL_MATCH, the call is
# still LOGGED (the attempt was made) but returns non-zero — simulating an auth /
# rate-limit / repo-mismatch gh side-effect failure so we can assert it is RECORDED,
# not swallowed.
if [ -n "${GH_FAIL_MATCH:-}" ] && grep -qF -- "$GH_FAIL_MATCH" <<<"$*"; then
  exit "${GH_FAIL_RC:-1}"
fi
exit 0
GHDOUBLE
  chmod +x "$f"
  printf '%s' "$f"
}

# An unclaim.sh double for the #1157 reclaim tests: records each release call's argv
# ("<issue> --board <n>", one per line) to $CAP_DIR/unclaim-calls.txt and exits 0
# (simulating a successful In Progress → Ready release). Lets the reclaim's board
# write be asserted offline, with zero real board mutation.
make_unclaim_double() {  # $1 = capture dir
  local d="$1" f="$1/unclaim.sh"
  cat > "$f" <<'UNCLAIMDOUBLE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CAP_DIR/unclaim-calls.txt"
exit 0
UNCLAIMDOUBLE
  chmod +x "$f"
  printf '%s' "$f"
}

REFUSE_SUMMARY='{"driver":"pipeline-drive-merge","layer":"5c","merged":0,"parked":0,"failed":0,"refused":1,"results":[{"action":"drive-ready","issue":101,"board":"3","status":"refused","pr":null,"note":"manual ops secret rotation"}]}'

# ── 16: a refused drive is routed to the operator (assign + label + comment) ───
echo "--- test 16: refused → assigned + funnel-escalated + comment (#622/#697) ---"
C16="$TMP/c16"; mkdir -p "$C16"; D16="$(make_merge_double "$C16")"; G16="$(make_gh_double "$C16")"
OUT16="$(printf '%s' "$CODE1" | env CLAUDE_BIN="$D16" PIPELINE_GH_BIN="$G16" CAP_DIR="$C16" \
        PIPELINE_OPERATOR=@towhead \
        PIPELINE_DRIVE_MERGE=1 MERGE_SUMMARY="$REFUSE_SUMMARY" bash "$DRIVE")"
[ "$(jq -r '.refused' <<<"$OUT16")" = "1" ] && ok "refused=1 surfaced" || bad "t16.refused" "got $(jq -r '.refused' <<<"$OUT16")"
[ "$(jq -r '.merged_pr' <<<"$OUT16")" = "0" ] && ok "merged_pr=0 (nothing merged)" || bad "t16.merged_pr" "got $(jq -r '.merged_pr' <<<"$OUT16")"
[ "$(jq -r '.routed' <<<"$OUT16")" = "1" ] && ok "routed=1 (item handed to the operator)" || bad "t16.routed" "got $(jq -r '.routed' <<<"$OUT16")"
grep -qx "issue edit 101 -R Towheads/stageFind --add-assignee towhead --add-label funnel-escalated" "$C16/gh-calls.txt" \
  && ok "gh assigned the operator + added funnel-escalated on the refused issue (#697)" || bad "t16.edit" "got $(cat "$C16/gh-calls.txt" 2>/dev/null || echo none)"
# The refused-route comment must NOT carry the retired merge-escalation marker (#697).
grep -q '^issue comment 101 ' "$C16/gh-calls.txt" \
  && ok "gh posted a routing comment on the refused issue" || bad "t16.comment" "no issue comment in $(cat "$C16/gh-calls.txt" 2>/dev/null || echo none)"
grep -qF 'pipeline:merge-escalation' "$C16/gh-argv.txt" 2>/dev/null \
  && bad "t16.marker" "escalation comment still carries the retired merge-escalation marker" \
  || ok "escalation comment carries NO merge-escalation marker (retired by #697)"

# ── 16b: #910 — a refused item the operator ALREADY dispositioned is NOT re-routed ─
# The label-thrash loop: the operator clears `funnel-escalated` (an `unlabeled`
# timeline event), the item re-enters the drive pool, is re-refused, and the driver
# used to RE-APPLY the label + re-comment every tick. With the guard it is suppressed.
# (#697: the disposition now keys on the OWN `funnel-escalated` label, not the shared
# `needs-clarification` — and since the pipeline never drains this label, a single
# un-label IS the operator, no U>D accounting needed.)
echo "--- test 16b: refused + prior operator un-label of funnel-escalated → suppressed (#910/#697) ---"
C16B="$TMP/c16b"; mkdir -p "$C16B"; D16B="$(make_merge_double "$C16B")"; G16B="$(make_gh_double "$C16B")"
OUT16B="$(printf '%s' "$CODE1" | env CLAUDE_BIN="$D16B" PIPELINE_GH_BIN="$G16B" CAP_DIR="$C16B" \
        PIPELINE_DRIVE_MERGE=1 MERGE_SUMMARY="$REFUSE_SUMMARY" \
        GH_TIMELINE_JSON='[{"event":"unlabeled","label":{"name":"funnel-escalated"}}]' bash "$DRIVE")"
[ "$(jq -r '.route_suppressed' <<<"$OUT16B")" = "1" ] && ok "route_suppressed=1 (operator disposition detected)" || bad "t16b.suppressed" "got $(jq -r '.route_suppressed' <<<"$OUT16B")"
[ "$(jq -r '.routed' <<<"$OUT16B")" = "0" ] && ok "routed=0 (not re-handed to the operator)" || bad "t16b.routed" "got $(jq -r '.routed' <<<"$OUT16B")"
[ ! -f "$C16B/gh-calls.txt" ] && ok "no gh edit/comment — the operator's clear is respected (#910 fix)" || bad "t16b.gh" "gh was called: $(cat "$C16B/gh-calls.txt")"

# ── 16c: #910 guard is SPECIFIC — a refused item whose timeline has other events but
# NO `funnel-escalated` un-label still routes first-time (regression guard). ──────
echo "--- test 16c: refused + timeline without an un-label event → routes as before (#910) ---"
C16C="$TMP/c16c"; mkdir -p "$C16C"; D16C="$(make_merge_double "$C16C")"; G16C="$(make_gh_double "$C16C")"
OUT16C="$(printf '%s' "$CODE1" | env CLAUDE_BIN="$D16C" PIPELINE_GH_BIN="$G16C" CAP_DIR="$C16C" \
        PIPELINE_DRIVE_MERGE=1 MERGE_SUMMARY="$REFUSE_SUMMARY" \
        GH_TIMELINE_JSON='[{"event":"labeled","label":{"name":"funnel-escalated"}},{"event":"commented"}]' bash "$DRIVE")"
[ "$(jq -r '.routed' <<<"$OUT16C")" = "1" ] && ok "routed=1 (first-time route still fires)" || bad "t16c.routed" "got $(jq -r '.routed' <<<"$OUT16C")"
[ "$(jq -r '.route_suppressed' <<<"$OUT16C")" = "0" ] && ok "route_suppressed=0 (no prior disposition)" || bad "t16c.suppressed" "got $(jq -r '.route_suppressed' <<<"$OUT16C")"
grep -q '^issue edit 101 ' "$C16C/gh-calls.txt" && ok "gh re-applied the label (no prior operator disposition)" || bad "t16c.edit" "no issue edit in $(cat "$C16C/gh-calls.txt" 2>/dev/null || echo none)"

# ── 16d: #697 — the disposition gate is DECOUPLED from `needs-clarification`. ─────
# A `needs-clarification` un-label (a pipeline clarification drain on the OTHER label,
# #657) is NOT a `funnel-escalated` disposition: the two labels are independent since
# the #697 split, so a refused code item still routes even when the timeline carries a
# needs-clarification drain + its clarified-marker ack. (This replaces the retired
# #657×#910 U>D accounting — that complexity existed only while both intents shared the
# one label; the split removed it.)
echo "--- test 16d: refused + a needs-clarification drain un-label → still routes (decoupled, #697) ---"
C16D="$TMP/c16d"; mkdir -p "$C16D"; D16D="$(make_merge_double "$C16D")"; G16D="$(make_gh_double "$C16D")"
OUT16D="$(printf '%s' "$CODE1" | env CLAUDE_BIN="$D16D" PIPELINE_GH_BIN="$G16D" CAP_DIR="$C16D" \
        PIPELINE_DRIVE_MERGE=1 MERGE_SUMMARY="$REFUSE_SUMMARY" \
        GH_TIMELINE_JSON='[{"event":"unlabeled","label":{"name":"needs-clarification"}},{"event":"commented","body":"<!-- funnel:clarification-drained --> Clarified (pipeline): operator answer consumed — released to drive."}]' bash "$DRIVE")"
[ "$(jq -r '.routed' <<<"$OUT16D")" = "1" ] && ok "routed=1 (a needs-clarification drain is not a funnel-escalated disposition)" || bad "t16d.routed" "got $(jq -r '.routed' <<<"$OUT16D")"
[ "$(jq -r '.route_suppressed' <<<"$OUT16D")" = "0" ] && ok "route_suppressed=0 (the two labels are decoupled since #697)" || bad "t16d.suppressed" "got $(jq -r '.route_suppressed' <<<"$OUT16D")"

# ╭──────────────────────────────────────────────────────────────────────────╮
# │ foundation #1053 — a REFUSED route-foundational (the 5b driver refused an  │
# │ epic that already has an approved/executing plan) is routed to the         │
# │ operator's DECISION queue (assign + `decision` + comment), so pipeline-tick's│
# │ existing route-already-assigned guard parks it instead of re-emitting      │
# │ route-foundational every tick (the #951 spin). #1045 needs no separate fix.│
# ╰──────────────────────────────────────────────────────────────────────────╯
ROUTE_FND='[{"tick":"done","actions":[{"phase":"route","action":"route-foundational","board":"4","repo":"Towheads/foundation","issue":951,"title":"Epic: knowledge-store migration","mode":"prep"}]}]'
SAFE_REFUSE_RF='{"driver":"pipeline-drive","layer":"5b","executed":0,"failed":0,"refused":1,"results":[{"action":"route-foundational","issue":951,"board":"4","status":"refused","note":"already-prepped: Plans/2026-07-04 obsidian knowledge-store migration is executing"}]}'

# ── 16e: a refused route-foundational → assigned + `decision` + comment (#1053) ──
echo "--- test 16e: refused route-foundational → decision-queue park (#1053, subsumes #1045) ---"
C16E="$TMP/c16e"; mkdir -p "$C16E"; D16E="$(make_merge_double "$C16E")"; G16E="$(make_gh_double "$C16E")"
OUT16E="$(printf '%s' "$ROUTE_FND" | env CLAUDE_BIN="$D16E" PIPELINE_GH_BIN="$G16E" CAP_DIR="$C16E" \
        PIPELINE_OPERATOR=@towhead SAFE_SUMMARY="$SAFE_REFUSE_RF" bash "$DRIVE")"
[ "$(jq -r '.safe_refused' <<<"$OUT16E")" = "1" ] && ok "safe_refused=1 surfaced" || bad "t16e.refused" "got $(jq -r '.safe_refused' <<<"$OUT16E")"
[ "$(jq -r '.routed' <<<"$OUT16E")" = "1" ] && ok "routed=1 (parked to the operator)" || bad "t16e.routed" "got $(jq -r '.routed' <<<"$OUT16E")"
grep -qx "issue edit 951 -R Towheads/foundation --add-assignee towhead --add-label decision" "$C16E/gh-calls.txt" \
  && ok "gh assigned the operator + added the \`decision\` label (pipeline-tick's park guard)" || bad "t16e.edit" "got $(cat "$C16E/gh-calls.txt" 2>/dev/null || echo none)"
grep -q '^issue comment 951 ' "$C16E/gh-calls.txt" \
  && ok "gh posted a decision-queue park comment on the refused epic" || bad "t16e.comment" "no issue comment in $(cat "$C16E/gh-calls.txt" 2>/dev/null || echo none)"
# The park MUST use `decision` (pipeline-tick's route-already-assigned guard), NOT the
# merge tier's `funnel-escalated` (which the guard treats as an open/failed-PR code item).
if grep -qF 'funnel-escalated' "$C16E/gh-argv.txt" 2>/dev/null; then
  bad "t16e.label" "route-foundational park wrongly used funnel-escalated, not decision"
else
  ok "park used decision, not funnel-escalated (right queue for a prepped epic)"
fi

# ── 16f: filter is route-foundational-SPECIFIC — a refused drain-* is NOT decision-parked ─
echo "--- test 16f: a refused drain action is NOT routed to the decision queue (#1053 filter) ---"
SAFE_REFUSE_DRAIN='{"driver":"pipeline-drive","layer":"5b","executed":0,"failed":0,"refused":1,"results":[{"action":"drain-parse-miss","issue":951,"board":"4","status":"refused","note":"unparseable reply"}]}'
C16F="$TMP/c16f"; mkdir -p "$C16F"; D16F="$(make_merge_double "$C16F")"; G16F="$(make_gh_double "$C16F")"
OUT16F="$(printf '%s' "$ROUTE_FND" | env CLAUDE_BIN="$D16F" PIPELINE_GH_BIN="$G16F" CAP_DIR="$C16F" \
        PIPELINE_OPERATOR=@towhead SAFE_SUMMARY="$SAFE_REFUSE_DRAIN" bash "$DRIVE")"
[ "$(jq -r '.routed' <<<"$OUT16F")" = "0" ] && ok "routed=0 (a refused drain-* is not a route-foundational park)" || bad "t16f.routed" "got $(jq -r '.routed' <<<"$OUT16F")"
[ ! -f "$C16F/gh-calls.txt" ] && ok "no gh edit/comment — the drain refusal keeps its own handling" || bad "t16f.gh" "gh was called: $(cat "$C16F/gh-calls.txt")"

# ── 16g: an EXECUTED route-foundational runs operator-ABSENT to a non-failed ──
# terminal state (#329). Root cause: the safe tier spawned /pipeline-drive with
# opabsent=0, so the inline /assess hit an unanswerable modal AskUserQuestion and
# recorded status:failed. With the fix the safe tier spawns opabsent=1, so /assess
# takes its operator-absent branches and route-foundational reaches `executed`.
echo "--- test 16g: executed route-foundational spawns opabsent=1, terminal=ran (#329) ---"
SAFE_EXEC_RF='{"driver":"pipeline-drive","layer":"5b","executed":1,"failed":0,"refused":0,"results":[{"action":"route-foundational","issue":951,"board":"4","status":"executed","note":"prepped draft plan + routed to decision queue"}]}'
C16G="$TMP/c16g"; mkdir -p "$C16G"; D16G="$(make_merge_double "$C16G")"; G16G="$(make_gh_double "$C16G")"
OUT16G="$(printf '%s' "$ROUTE_FND" | env CLAUDE_BIN="$D16G" PIPELINE_GH_BIN="$G16G" CAP_DIR="$C16G" \
        PIPELINE_OPERATOR=@towhead SAFE_SUMMARY="$SAFE_EXEC_RF" bash "$DRIVE")"
# The #329 root-cause proof: the safe tier spawned the /pipeline-drive driver operator-ABSENT.
grep -q '^opabsent=1 prompt=/pipeline-drive ' "$C16G/calls.txt" \
  && ok "safe tier ran /pipeline-drive with PIPELINE_OPERATOR_ABSENT=1 (#329 — inline /assess takes its operator-absent branches)" \
  || bad "t16g.opabsent" "safe tier not operator-absent: $(cat "$C16G/calls.txt" 2>/dev/null || echo none)"
[ "$(jq -r '.safe_executed' <<<"$OUT16G")" = "1" ] && ok "safe_executed=1 (route-foundational reached a non-failed terminal state)" || bad "t16g.exec" "got $(jq -r '.safe_executed' <<<"$OUT16G")"
[ "$(jq -r '.safe_failed' <<<"$OUT16G")" = "0" ] && ok "safe_failed=0 (no status:failed wall)" || bad "t16g.failed" "got $(jq -r '.safe_failed' <<<"$OUT16G")"
[ "$(jq -r '.status' <<<"$OUT16G")" = "ran" ] && ok "status=ran (tier terminal, not failed)" || bad "t16g.status" "got $(jq -r '.status' <<<"$OUT16G")"

# ── 17: a clean merge is NOT routed (no operator hand-off, no stray gh edits) ──
echo "--- test 17: a merged drive is not routed (#622) ---"
C17="$TMP/c17"; mkdir -p "$C17"; D17="$(make_merge_double "$C17")"; G17="$(make_gh_double "$C17")"
OUT17="$(printf '%s' "$CODE1" | env CLAUDE_BIN="$D17" PIPELINE_GH_BIN="$G17" CAP_DIR="$C17" \
        PIPELINE_DRIVE_MERGE=1 bash "$DRIVE")"   # default summary = one clean merge
[ "$(jq -r '.merged_pr' <<<"$OUT17")" = "1" ] && ok "merged_pr=1 (clean merge)" || bad "t17.merged_pr" "got $(jq -r '.merged_pr' <<<"$OUT17")"
[ "$(jq -r '.routed' <<<"$OUT17")" = "0" ] && ok "routed=0 (a merge needs no operator hand-off)" || bad "t17.routed" "got $(jq -r '.routed' <<<"$OUT17")"
[ ! -f "$C17/gh-calls.txt" ] && ok "no gh issue edit/comment on a clean merge" || bad "t17.gh" "gh was called: $(cat "$C17/gh-calls.txt")"

# ── 18: routing fires off the PRODUCTION fenced-envelope shape too ────────────
echo "--- test 18: refused routing works from the fenced claude envelope (#622) ---"
C18="$TMP/c18"; mkdir -p "$C18"; D18="$(make_merge_double "$C18")"; G18="$(make_gh_double "$C18")"
OUT18="$(printf '%s' "$CODE1" | env CLAUDE_BIN="$D18" PIPELINE_GH_BIN="$G18" CAP_DIR="$C18" \
        PIPELINE_DRIVE_MERGE=1 MERGE_WRAP=1 MERGE_SUMMARY="$REFUSE_SUMMARY" bash "$DRIVE")"
[ "$(jq -r '.routed' <<<"$OUT18")" = "1" ] && ok "routed=1 extracted from the fenced envelope" || bad "t18.routed" "got $(jq -r '.routed' <<<"$OUT18")"
grep -q '^issue edit 101 ' "$C18/gh-calls.txt" && ok "gh routing fired from the production-shape result" || bad "t18.edit" "no issue edit in $(cat "$C18/gh-calls.txt" 2>/dev/null || echo none)"

# ── 19: a failed drive is routed to the operator too (same dead-end risk) ─────
echo "--- test 19: a failed drive is also routed (#622) ---"
C19="$TMP/c19"; mkdir -p "$C19"; D19="$(make_merge_double "$C19")"; G19="$(make_gh_double "$C19")"
FAIL_SUMMARY='{"driver":"pipeline-drive-merge","layer":"5c","merged":0,"parked":0,"failed":1,"refused":0,"results":[{"action":"drive-ready","issue":101,"board":"3","status":"failed","pr":null,"note":"build error"}]}'
OUT19="$(printf '%s' "$CODE1" | env CLAUDE_BIN="$D19" PIPELINE_GH_BIN="$G19" CAP_DIR="$C19" \
        PIPELINE_DRIVE_MERGE=1 MERGE_SUMMARY="$FAIL_SUMMARY" bash "$DRIVE")"
[ "$(jq -r '.failed' <<<"$OUT19")" = "1" ] && ok "failed=1 surfaced" || bad "t19.failed" "got $(jq -r '.failed' <<<"$OUT19")"
[ "$(jq -r '.routed' <<<"$OUT19")" = "1" ] && ok "routed=1 (a failed drive is handed to the operator)" || bad "t19.routed" "got $(jq -r '.routed' <<<"$OUT19")"

# ╭──────────────────────────────────────────────────────────────────────────╮
# │ foundation #624 — cross-tick merge hand-off. A one-shot `claude -p` merge  │
# │ drive opens a PR but the session ends before CI greens + the merge gate    │
# │ fires. pipeline-drive.sh GROUND-TRUTH probes for an open unmerged PR and      │
# │ labels the issue funnel-merge-pending so the NEXT tick RESUMES, not         │
# │ re-drives (a fresh drive would open a duplicate PR).                        │
# ╰──────────────────────────────────────────────────────────────────────────╯

# A summary with NO terminal outcome for the item (it opened a PR but the session
# ended) — the realistic hand-off shape the driver emits when CI outlasts the run.
HANDOFF_SUMMARY='{"driver":"pipeline-drive-merge","layer":"5c","merged":0,"handed_off":1,"parked":0,"failed":0,"refused":0,"results":[{"action":"drive-ready","issue":101,"board":"3","status":"handed-off","pr":857,"note":"PR #857 opened, CI pending"}]}'
# An open PR (#857) whose body closes #101 — what the ground-truth probe sees.
OPEN_PR_101='[{"number":857,"body":"Adds the thing.\n\nCloses #101\n"}]'

# ── 20: a hand-off (open PR, not merged) is labeled for resume next tick ───────
echo "--- test 20: handed-off drive → funnel-merge-pending label + handed_off=1 (#624) ---"
C20="$TMP/c20"; mkdir -p "$C20"; D20="$(make_merge_double "$C20")"; G20="$(make_gh_double "$C20")"
OUT20="$(printf '%s' "$CODE1" | env CLAUDE_BIN="$D20" PIPELINE_GH_BIN="$G20" CAP_DIR="$C20" \
        GH_PR_LIST_JSON="$OPEN_PR_101" PIPELINE_DRIVE_MERGE=1 MERGE_SUMMARY="$HANDOFF_SUMMARY" bash "$DRIVE")"
[ "$(jq -r '.merged_pr' <<<"$OUT20")" = "0" ] && ok "merged_pr=0 (nothing merged this tick)" || bad "t20.merged_pr" "got $(jq -r '.merged_pr' <<<"$OUT20")"
[ "$(jq -r '.handed_off' <<<"$OUT20")" = "1" ] && ok "handed_off=1 (PR opened, not merged)" || bad "t20.handed_off" "got $(jq -r '.handed_off' <<<"$OUT20")"
[ "$(jq -r '.routed' <<<"$OUT20")" = "0" ] && ok "routed=0 (a hand-off is not an operator route)" || bad "t20.routed" "got $(jq -r '.routed' <<<"$OUT20")"
grep -qx "issue edit 101 -R Towheads/stageFind --add-label funnel-merge-pending" "$C20/gh-calls.txt" \
  && ok "gh labeled the issue funnel-merge-pending (resume marker)" || bad "t20.label" "got $(cat "$C20/gh-calls.txt" 2>/dev/null || echo none)"

# ── 21: a clean merge is NOT handed off (probe finds no open PR → no marker) ───
echo "--- test 21: a merged drive leaves no hand-off marker (#624) ---"
C21="$TMP/c21"; mkdir -p "$C21"; D21="$(make_merge_double "$C21")"; G21="$(make_gh_double "$C21")"
# Default summary = one clean merge; the merged PR is CLOSED, so the ground-truth
# probe returns no open PR → no label. (merged is NOT skipped before the probe — the
# probe is the source of truth — but for a real merge it correctly finds nothing.)
OUT21="$(printf '%s' "$CODE1" | env CLAUDE_BIN="$D21" PIPELINE_GH_BIN="$G21" CAP_DIR="$C21" \
        GH_PR_LIST_JSON='[]' PIPELINE_DRIVE_MERGE=1 bash "$DRIVE")"
[ "$(jq -r '.merged_pr' <<<"$OUT21")" = "1" ] && ok "merged_pr=1 (clean merge)" || bad "t21.merged_pr" "got $(jq -r '.merged_pr' <<<"$OUT21")"
[ "$(jq -r '.handed_off' <<<"$OUT21")" = "0" ] && ok "handed_off=0 (merged → probe finds no open PR → nothing to resume)" || bad "t21.handed_off" "got $(jq -r '.handed_off' <<<"$OUT21")"
[ ! -f "$C21/gh-calls.txt" ] && ok "no gh issue edit on a clean merge (probe found no open PR)" || bad "t21.gh" "gh called: $(cat "$C21/gh-calls.txt")"

# ── 21b: a FALSELY-'merged' self-report whose PR is still open IS handed off ───
# The #624 trust-the-probe guard: a merge-queue rejection on the second checks run
# (or any mis-reported merge) leaves the PR OPEN. The probe sees it and labels for
# resume — so `merged` must NOT short-circuit the probe (the MAJOR the reviewer found).
echo "--- test 21b: merged self-report + still-open PR → handed_off=1 (trust the probe) ---"
C21B="$TMP/c21b"; mkdir -p "$C21B"; D21B="$(make_merge_double "$C21B")"; G21B="$(make_gh_double "$C21B")"
OUT21B="$(printf '%s' "$CODE1" | env CLAUDE_BIN="$D21B" PIPELINE_GH_BIN="$G21B" CAP_DIR="$C21B" \
        GH_PR_LIST_JSON="$OPEN_PR_101" PIPELINE_DRIVE_MERGE=1 bash "$DRIVE")"   # default summary = merged:1
[ "$(jq -r '.merged_pr' <<<"$OUT21B")" = "1" ] && ok "the self-report still says merged_pr=1" || bad "t21b.merged_pr" "got $(jq -r '.merged_pr' <<<"$OUT21B")"
[ "$(jq -r '.handed_off' <<<"$OUT21B")" = "1" ] && ok "handed_off=1 (probe overrides the false merge claim)" || bad "t21b.handed_off" "got $(jq -r '.handed_off' <<<"$OUT21B")"
grep -qx "issue edit 101 -R Towheads/stageFind --add-label funnel-merge-pending" "$C21B/gh-calls.txt" \
  && ok "the still-open PR is labeled for resume despite the 'merged' report" || bad "t21b.label" "got $(cat "$C21B/gh-calls.txt" 2>/dev/null || echo none)"

# ── 22: the DEATH path — unparseable summary + open PR → still handed off ──────
# The core #624 case: the session died WITHOUT emitting a clean summary, so the
# per-item status is unknown. The ground-truth open-PR probe (not the model report)
# is what detects the hand-off — otherwise the next tick re-drives into a dup PR.
echo "--- test 22: garbage summary + open PR → handed_off=1 off the ground-truth probe (#624) ---"
C22="$TMP/c22"; mkdir -p "$C22"; D22="$(make_merge_double "$C22")"; G22="$(make_gh_double "$C22")"
OUT22="$(printf '%s' "$CODE1" | env CLAUDE_BIN="$D22" PIPELINE_GH_BIN="$G22" CAP_DIR="$C22" \
        GH_PR_LIST_JSON="$OPEN_PR_101" PIPELINE_DRIVE_MERGE=1 MERGE_SUMMARY="not json at all" bash "$DRIVE")"
[ "$(jq -r '.merged_pr' <<<"$OUT22")" = "null" ] && ok "merged_pr=null (summary unparseable — unknown)" || bad "t22.merged_pr" "got $(jq -r '.merged_pr' <<<"$OUT22")"
[ "$(jq -r '.handed_off' <<<"$OUT22")" = "1" ] && ok "handed_off=1 (probe found the open PR despite no summary)" || bad "t22.handed_off" "got $(jq -r '.handed_off' <<<"$OUT22")"
grep -qx "issue edit 101 -R Towheads/stageFind --add-label funnel-merge-pending" "$C22/gh-calls.txt" \
  && ok "the death-path drive is still labeled for resume" || bad "t22.label" "got $(cat "$C22/gh-calls.txt" 2>/dev/null || echo none)"

# ── 23: a PARKED drive with an open PR is NOT handed off (operator owns it) ────
# /build parked it for an ask-now decision (it queued the operator). Even with an
# open PR, it must NOT be auto-resumed — the operator decision gates it. status=parked
# beats the probe.
echo "--- test 23: parked + open PR → handed_off=0 (operator decision owns it) (#624) ---"
C23="$TMP/c23"; mkdir -p "$C23"; D23="$(make_merge_double "$C23")"; G23="$(make_gh_double "$C23")"
OUT23="$(printf '%s' "$CODE1" | env CLAUDE_BIN="$D23" PIPELINE_GH_BIN="$G23" CAP_DIR="$C23" \
        GH_PR_LIST_JSON="$OPEN_PR_101" PIPELINE_DRIVE_MERGE=1 MERGE_SUMMARY="$PARK_SUMMARY" bash "$DRIVE")"
[ "$(jq -r '.parked' <<<"$OUT23")" = "1" ] && ok "parked=1 surfaced" || bad "t23.parked" "got $(jq -r '.parked' <<<"$OUT23")"
[ "$(jq -r '.handed_off' <<<"$OUT23")" = "0" ] && ok "handed_off=0 (parked is operator-owned, not resumed)" || bad "t23.handed_off" "got $(jq -r '.handed_off' <<<"$OUT23")"
[ ! -f "$C23/gh-calls.txt" ] && ok "no funnel-merge-pending label on a parked item" || bad "t23.gh" "gh called: $(cat "$C23/gh-calls.txt")"

# ── 24: a resume action carries mode:"resume" into the merge payload ──────────
# pipeline-tick.sh sets mode:resume on a hand-off-labeled item; pipeline-drive.sh must
# pass it through to the merge driver so it re-attaches instead of re-driving.
echo "--- test 24: a mode:resume drive-ready flows mode into the merge payload (#624) ---"
RESUME1='[{"tick":"done","actions":[
  {"phase":"drive","action":"drive-ready","board":"3","repo":"Towheads/stageFind","issue":101,"kind":"code","mode":"resume","emit":"/build"}]}]'
C24="$TMP/c24"; mkdir -p "$C24"; D24="$(make_merge_double "$C24")"
OUT24="$(printf '%s' "$RESUME1" | env CLAUDE_BIN="$D24" CAP_DIR="$C24" PIPELINE_DRIVE_MERGE=1 bash "$DRIVE")"
[ "$(jq -r '.merge_driven' <<<"$OUT24")" = "1" ] && ok "the resume item is handed to the merge driver" || bad "t24.merge_driven" "got $(jq -r '.merge_driven' <<<"$OUT24")"
[ "$(jq -r '.actions[0].mode' "$C24/merge-payload.json")" = "resume" ] \
  && ok "merge payload carries mode:resume" || bad "t24.mode" "got $(jq -r '.actions[0].mode // "none"' "$C24/merge-payload.json" 2>/dev/null)"

# ── 25: build.config.sh ships the headless foreground-poll bound (#626) ───────
# The headless one-shot merge path (build.md 3g/4b) bounds each FOREGROUND CI/MERGED
# poll by BUILD_HEADLESS_POLL_TIMEOUT so it stays under the ~10-min Bash cap. Assert
# the default exists and is exported, and that a pre-set env value wins (the `:=` idiom).
echo "--- test 25: BUILD_HEADLESS_POLL_TIMEOUT default + export + env-override (#626) ---"
CONFIG="$HERE/../build.config.sh"
VAL_DEFAULT="$(bash -c 'source "$1" >/dev/null 2>&1; echo "$BUILD_HEADLESS_POLL_TIMEOUT"' _ "$CONFIG")"
[ "$VAL_DEFAULT" = "540" ] && ok "BUILD_HEADLESS_POLL_TIMEOUT defaults to 540" || bad "t25.default" "got '$VAL_DEFAULT'"
EXPORTED="$(bash -c 'source "$1" >/dev/null 2>&1; export -p | grep -c "BUILD_HEADLESS_POLL_TIMEOUT"' _ "$CONFIG")"
[ "$EXPORTED" = "1" ] && ok "BUILD_HEADLESS_POLL_TIMEOUT is exported" || bad "t25.export" "export count $EXPORTED"
VAL_OVERRIDE="$(BUILD_HEADLESS_POLL_TIMEOUT=120 bash -c 'source "$1" >/dev/null 2>&1; echo "$BUILD_HEADLESS_POLL_TIMEOUT"' _ "$CONFIG")"
[ "$VAL_OVERRIDE" = "120" ] && ok "a pre-set env value wins over the default" || bad "t25.override" "got '$VAL_OVERRIDE'"

# ╭──────────────────────────────────────────────────────────────────────────╮
# │ foundation #636 — the SAFE tier reports attempts-vs-outcomes, so a 5b      │
# │ refusal is never counted as a successful drive. `driven` = handed-in       │
# │ attempts (sibling of merge_driven); safe_executed/safe_refused/safe_failed │
# │ = the driver's OWN Step-3 summary, parsed back from `result`.              │
# ╰──────────────────────────────────────────────────────────────────────────╯

# A configurable safe-tier double: returns SAFE_SUMMARY (default one clean execute);
# SAFE_WRAP=1 emits it inside a `claude -p --output-format json` envelope with the
# summary as a TRAILING ```json fence — the exact 2026-06-29 #449 shape.
make_safe_double() {  # $1 = capture dir
  local d="$1" f="$1/safe.sh"
  cat > "$f" <<'SAFEDOUBLE'
#!/usr/bin/env bash
set -euo pipefail
summary="${SAFE_SUMMARY:-}"
[ -z "$summary" ] && summary='{"driver":"pipeline-drive","layer":"5b","executed":1,"failed":0,"refused":0,"results":[]}'
if [ "${SAFE_WRAP:-0}" = "1" ]; then
  # Production envelope: a per-action fence FIRST, then the summary fence LAST —
  # the precise shape the #449 refusal took (summary is the trailing fence).
  text="This is a single spike, not an epic — recording it as refused:"$'\n\n'"\`\`\`json"$'\n'"{\"action\":\"drive-ready\",\"issue\":449,\"status\":\"refused\"}"$'\n'"\`\`\`"$'\n\n'"Step 3 summary:"$'\n\n'"\`\`\`json"$'\n'"$summary"$'\n'"\`\`\`"
  jq -cn --arg t "$text" '{type:"result",subtype:"success",is_error:false,result:$t}'
else
  printf '%s\n' "$summary"
fi
SAFEDOUBLE
  chmod +x "$f"
  printf '%s' "$f"
}

# A single spike drive (a real tick is drive-capped to ~one drive) → n_safe=1.
SPIKE1='[{"tick":"done","actions":[
  {"phase":"drive","action":"drive-ready","board":"3","repo":"Towheads/stageFind","issue":449,"kind":"spike","emit":"drive the spike to its verdict"}]}]'
REFUSE_SAFE='{"driver":"pipeline-drive","layer":"5b","executed":0,"failed":0,"refused":1,"results":[{"action":"drive-ready","issue":449,"status":"refused","note":"single spike, not an epic"}]}'

# ── 26: a SAFE refusal is counted as refused, NOT as a successful drive (#636) ─
# The 2026-06-29 #449 regression: latest.json showed driven=1/refused:0 while the
# driver self-reported executed:0/refused:1. driven stays the attempt count; the
# refusal now lands in safe_refused.
echo "--- test 26: a safe-tier refusal → driven=1 but safe_executed=0, safe_refused=1 (#636) ---"
C26="$TMP/c26"; mkdir -p "$C26"; S26="$(make_safe_double "$C26")"
OUT26="$(printf '%s' "$SPIKE1" | env CLAUDE_BIN="$S26" SAFE_SUMMARY="$REFUSE_SAFE" bash "$DRIVE")"
[ "$(jq -r '.status' <<<"$OUT26")" = "ran" ] && ok "status=ran" || bad "t26.status" "got $(jq -r '.status' <<<"$OUT26")"
[ "$(jq -r '.driven' <<<"$OUT26")" = "1" ] && ok "driven=1 (one safe action was attempted)" || bad "t26.driven" "got $(jq -r '.driven' <<<"$OUT26")"
[ "$(jq -r '.safe_executed' <<<"$OUT26")" = "0" ] && ok "safe_executed=0 (nothing actually executed)" || bad "t26.safe_executed" "got $(jq -r '.safe_executed' <<<"$OUT26")"
[ "$(jq -r '.safe_refused' <<<"$OUT26")" = "1" ] && ok "safe_refused=1 (the refusal is counted — the #636 fix)" || bad "t26.safe_refused" "got $(jq -r '.safe_refused' <<<"$OUT26")"
[ "$(jq -r '.safe_failed' <<<"$OUT26")" = "0" ] && ok "safe_failed=0" || bad "t26.safe_failed" "got $(jq -r '.safe_failed' <<<"$OUT26")"

# ── 27: the same refusal parsed from the PRODUCTION fenced envelope (#636) ─────
echo "--- test 27: safe_refused parsed from the #449-shape claude envelope (#636) ---"
C27="$TMP/c27"; mkdir -p "$C27"; S27="$(make_safe_double "$C27")"
OUT27="$(printf '%s' "$SPIKE1" | env CLAUDE_BIN="$S27" SAFE_WRAP=1 SAFE_SUMMARY="$REFUSE_SAFE" bash "$DRIVE")"
[ "$(jq -r '.safe_refused' <<<"$OUT27")" = "1" ] && ok "safe_refused=1 dug out of the trailing summary fence" || bad "t27.safe_refused" "got $(jq -r '.safe_refused' <<<"$OUT27")"
[ "$(jq -r '.safe_executed' <<<"$OUT27")" = "0" ] && ok "safe_executed=0 from the fenced envelope" || bad "t27.safe_executed" "got $(jq -r '.safe_executed' <<<"$OUT27")"

# ── 28: a clean safe execution reports the right outcome counts (#636) ─────────
echo "--- test 28: a clean safe drive → safe_executed matches, safe_refused=0 (#636) ---"
C28="$TMP/c28"; mkdir -p "$C28"; S28="$(make_safe_double "$C28")"
OUT28="$(printf '%s' "$SPIKE1" | env CLAUDE_BIN="$S28" \
        SAFE_SUMMARY='{"driver":"pipeline-drive","layer":"5b","executed":1,"failed":0,"refused":0,"results":[]}' bash "$DRIVE")"
[ "$(jq -r '.safe_executed' <<<"$OUT28")" = "1" ] && ok "safe_executed=1 (the spike drove to a verdict)" || bad "t28.safe_executed" "got $(jq -r '.safe_executed' <<<"$OUT28")"
[ "$(jq -r '.safe_refused' <<<"$OUT28")" = "0" ] && ok "safe_refused=0 (clean)" || bad "t28.safe_refused" "got $(jq -r '.safe_refused' <<<"$OUT28")"

# ── 29: unparseable safe output → safe_* = null (unknown, never a false 0) (#636) ─
echo "--- test 29: garbage safe output → safe_executed/refused/failed = null ---"
C29="$TMP/c29"; mkdir -p "$C29"; S29="$(make_safe_double "$C29")"
OUT29="$(printf '%s' "$SPIKE1" | env CLAUDE_BIN="$S29" SAFE_SUMMARY="not json at all" bash "$DRIVE")"
[ "$(jq -r '.safe_executed' <<<"$OUT29")" = "null" ] && ok "safe_executed=null (unknown)" || bad "t29.safe_executed" "got $(jq -r '.safe_executed' <<<"$OUT29")"
[ "$(jq -r '.safe_refused' <<<"$OUT29")" = "null" ] && ok "safe_refused=null (unknown, not a false 0)" || bad "t29.safe_refused" "got $(jq -r '.safe_refused' <<<"$OUT29")"
[ "$(jq -r '.driven' <<<"$OUT29")" = "1" ] && ok "driven=1 (the attempt is still recorded)" || bad "t29.driven" "got $(jq -r '.driven' <<<"$OUT29")"

# ── 30: dry-run / no spawn → safe_* = 0 (the tier did not run) (#636) ──────────
echo "--- test 30: --dry-run → safe outcomes are a definitive 0 (no spawn) ---"
OUT30="$(printf '%s' "$PLANS" | bash "$DRIVE" --dry-run)"
[ "$(jq -r '.driven' <<<"$OUT30")" = "4" ] && ok "driven=4 (what WOULD be driven; drain-clarification joins #657)" || bad "t30.driven" "got $(jq -r '.driven' <<<"$OUT30")"
[ "$(jq -r '.safe_executed' <<<"$OUT30")" = "0" ] && ok "safe_executed=0 (a preview executes nothing)" || bad "t30.safe_executed" "got $(jq -r '.safe_executed' <<<"$OUT30")"
[ "$(jq -r '.safe_refused' <<<"$OUT30")" = "0" ] && ok "safe_refused=0 (a preview refuses nothing)" || bad "t30.safe_refused" "got $(jq -r '.safe_refused' <<<"$OUT30")"

# ╭──────────────────────────────────────────────────────────────────────────╮
# │ F#655 — the merge tier drives each board IN that board's checkout.         │
# │ Regression: with boards `3 4 5` the merge agent ran from the foundation    │
# │ cwd and refused every board-3 item (merges 5/day → 0). The driver now      │
# │ groups by board and cd's into PIPELINE_CHECKOUT_<n> before spawning.         │
# ╰──────────────────────────────────────────────────────────────────────────╯

# ── 31: a board-3 merge drive runs IN the board-3 checkout (the cd fix) ───────
echo "--- test 31: merge driver spawns cd'd into the target board's checkout (#655) ---"
C31="$TMP/c31"; mkdir -p "$C31"; D31="$(make_merge_double "$C31")"
B3CODE='[{"tick":"done","actions":[
  {"phase":"drive","action":"drive-ready","board":"3","repo":"Towheads/stageFind","issue":101,"kind":"code","emit":"/build"}]}]'
OUT31="$(printf '%s' "$B3CODE" | env CLAUDE_BIN="$D31" CAP_DIR="$C31" PIPELINE_DRIVE_MERGE=1 bash "$DRIVE")"
[ "$(jq -r '.merge_driven' <<<"$OUT31")" = "1" ] && ok "merge_driven=1" || bad "t31.driven" "got $(jq -r '.merge_driven' <<<"$OUT31")"
[ "$(jq -r '.merged_pr' <<<"$OUT31")" = "1" ] && ok "merged_pr=1 (built in the right checkout → merged)" || bad "t31.merged" "got $(jq -r '.merged_pr' <<<"$OUT31")"
# The headless driver's cwd was the board-3 checkout, NOT the launching cwd.
grep -q "^$CO3"$'\t'"/pipeline-drive-merge" "$C31/pwd.txt" \
  && ok "driver ran with cwd = PIPELINE_CHECKOUT_3 ($CO3)" || bad "t31.cwd" "pwd log: $(cat "$C31/pwd.txt" 2>/dev/null)"

# ── 32: a mixed board-3 + board-4 cap drives each in its OWN checkout ─────────
echo "--- test 32: mixed-board cap → one driver per board, each cd'd in, counts combined (#655) ---"
C32="$TMP/c32"; mkdir -p "$C32"; D32="$(make_merge_double "$C32")"
MIXED='[{"tick":"done","actions":[
  {"phase":"drive","action":"drive-ready","board":"3","repo":"Towheads/stageFind","issue":201,"kind":"code","emit":"/build"},
  {"phase":"drive","action":"drive-ready","board":"4","repo":"Towheads/foundation","issue":202,"kind":"code","emit":"/build"}]}]'
OUT32="$(printf '%s' "$MIXED" | env CLAUDE_BIN="$D32" CAP_DIR="$C32" \
        PIPELINE_DRIVE_MERGE=1 PIPELINE_DRIVE_MERGE_CAP=2 bash "$DRIVE")"
[ "$(jq -r '.merge_driven' <<<"$OUT32")" = "2" ] && ok "merge_driven=2 (both boards handed to a driver)" || bad "t32.driven" "got $(jq -r '.merge_driven' <<<"$OUT32")"
[ "$(jq -r '.merged_pr' <<<"$OUT32")" = "2" ] && ok "merged_pr=2 (per-board summaries combined)" || bad "t32.merged" "got $(jq -r '.merged_pr' <<<"$OUT32")"
# Two distinct spawns, one per checkout.
grep -q "^$CO3"$'\t' "$C32/pwd.txt" && ok "a driver ran in the board-3 checkout" || bad "t32.cwd3" "no board-3 cwd: $(cat "$C32/pwd.txt")"
grep -q "^$CO4"$'\t' "$C32/pwd.txt" && ok "a driver ran in the board-4 checkout" || bad "t32.cwd4" "no board-4 cwd: $(cat "$C32/pwd.txt")"
[ "$(grep -c '/pipeline-drive-merge' "$C32/pwd.txt")" = "2" ] && ok "exactly two merge spawns (one per board)" || bad "t32.spawns" "got $(grep -c '/pipeline-drive-merge' "$C32/pwd.txt")"
# Each per-board payload carries only that board's action.
[ "$(jq -r '[.actions[].board]|unique|join(",")' "$C32/merge-payload.json" 2>/dev/null)" != "" ] && ok "a per-board merge payload was written" || bad "t32.payload" "no merge payload captured"

# ── 33: a board with NO local checkout fails the item (never builds wrong repo) ─
echo "--- test 33: an unmapped board → item failed + routed, no spawn (#655) ---"
C33="$TMP/c33"; mkdir -p "$C33"; D33="$(make_merge_double "$C33")"
# A capture gh double so the route (issue edit/comment) doesn't hit the network.
GH33="$TMP/gh33.sh"; cat > "$GH33" <<'GHX'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_CAP/gh.txt"
GHX
chmod +x "$GH33"; GHCAP33="$TMP/ghcap33"; mkdir -p "$GHCAP33"
NOCO='[{"tick":"done","actions":[
  {"phase":"drive","action":"drive-ready","board":"9","repo":"Towheads/nowhere","issue":301,"kind":"code","emit":"/build"}]}]'
OUT33="$(printf '%s' "$NOCO" | env CLAUDE_BIN="$D33" CAP_DIR="$C33" GH_CAP="$GHCAP33" PIPELINE_GH_BIN="$GH33" \
        PIPELINE_DRIVE_MERGE=1 bash "$DRIVE")"
[ "$(jq -r '.merge_driven' <<<"$OUT33")" = "1" ] && ok "merge_driven=1 (item was in the cap)" || bad "t33.driven" "got $(jq -r '.merge_driven' <<<"$OUT33")"
[ "$(jq -r '.failed' <<<"$OUT33")" = "1" ] && ok "failed=1 (no checkout → synthesized failed, not built)" || bad "t33.failed" "got $(jq -r '.failed' <<<"$OUT33")"
[ "$(jq -r '.merged_pr' <<<"$OUT33")" = "0" ] && ok "merged_pr=0 (the wrong repo was never built)" || bad "t33.merged" "got $(jq -r '.merged_pr' <<<"$OUT33")"
[ ! -f "$C33/pwd.txt" ] && ok "no driver was spawned for the unmapped board" || bad "t33.spawn" "a driver ran: $(cat "$C33/pwd.txt")"
[ "$(jq -r '.routed' <<<"$OUT33")" = "1" ] && ok "routed=1 (the un-driveable item handed to the operator)" || bad "t33.routed" "got $(jq -r '.routed' <<<"$OUT33")"
grep -q 'funnel-escalated' "$GHCAP33/gh.txt" 2>/dev/null && ok "the item was labeled funnel-escalated (left the auto-drive pool, #697)" || bad "t33.label" "no route label: $(cat "$GHCAP33/gh.txt" 2>/dev/null)"

# ── 34: the safe tier also drives each board in its checkout (cwd-sensitive spike) ─
echo "--- test 34: safe tier groups by board and cd's into each checkout (#655) ---"
C34="$TMP/c34"; mkdir -p "$C34"; D34="$(make_merge_double "$C34")"
# board-3 spike + board-4 spike → two safe spawns, one per checkout.
SAFE2='[{"tick":"done","actions":[
  {"phase":"drive","action":"drive-ready","board":"3","repo":"Towheads/stageFind","issue":401,"kind":"spike"},
  {"phase":"drive","action":"drive-ready","board":"4","repo":"Towheads/foundation","issue":402,"kind":"spike"}]}]'
OUT34="$(printf '%s' "$SAFE2" | env CLAUDE_BIN="$D34" CAP_DIR="$C34" bash "$DRIVE")"
[ "$(jq -r '.status' <<<"$OUT34")" = "ran" ] && ok "status=ran" || bad "t34.status" "got $(jq -r '.status' <<<"$OUT34")"
[ "$(jq -r '.safe_executed' <<<"$OUT34")" = "2" ] && ok "safe_executed=2 (both spike drives combined)" || bad "t34.executed" "got $(jq -r '.safe_executed' <<<"$OUT34")"
grep -q "^$CO3"$'\t'"/pipeline-drive " "$C34/pwd.txt" && ok "board-3 spike ran in the board-3 checkout" || bad "t34.cwd3" "$(cat "$C34/pwd.txt")"
grep -q "^$CO4"$'\t'"/pipeline-drive " "$C34/pwd.txt" && ok "board-4 spike ran in the board-4 checkout" || bad "t34.cwd4" "$(cat "$C34/pwd.txt")"

# ╭──────────────────────────────────────────────────────────────────────────╮
# │ foundation #665 — a merge-pending PR whose required `checks` gate is        │
# │ TERMINALLY red cannot be merged by re-resuming (the merge tier pushes no    │
# │ fixes). pipeline-drive.sh probes the required check on the resume path and,   │
# │ when it has COMPLETED with FAILURE, ESCALATES to the operator (drop the     │
# │ merge-pending label, assign + funnel-escalated — #697) instead of looping   │
# │ it forever — while a still-running check is left to resume, never escalated. │
# ╰──────────────────────────────────────────────────────────────────────────╯

# A required `checks` run that has finished red — the terminal-failure shape the
# #665 probe escalates on (sibling green checks present, to prove it matches by name).
ROLLUP_RED='{"statusCheckRollup":[{"name":"checks","status":"COMPLETED","conclusion":"FAILURE"},{"name":"eval-smoke","status":"COMPLETED","conclusion":"SUCCESS"}]}'
# The same gate still RUNNING — not terminal, so it must NOT escalate (resume instead).
ROLLUP_PENDING='{"statusCheckRollup":[{"name":"checks","status":"IN_PROGRESS","conclusion":null}]}'

# ── 35: merge-pending PR with a TERMINALLY-red required check → escalated ──────
echo "--- test 35: open PR + terminal-red checks → escalated to operator, not resumed (#665) ---"
C35="$TMP/c35"; mkdir -p "$C35"; D35="$(make_merge_double "$C35")"; G35="$(make_gh_double "$C35")"
OUT35="$(printf '%s' "$CODE1" | env CLAUDE_BIN="$D35" PIPELINE_GH_BIN="$G35" CAP_DIR="$C35" \
        PIPELINE_OPERATOR=@towhead \
        GH_PR_LIST_JSON="$OPEN_PR_101" GH_PR_VIEW_JSON="$ROLLUP_RED" \
        PIPELINE_DRIVE_MERGE=1 MERGE_SUMMARY="$HANDOFF_SUMMARY" bash "$DRIVE")"
[ "$(jq -r '.escalated' <<<"$OUT35")" = "1" ] && ok "escalated=1 (terminal-red PR handed to the operator)" || bad "t35.escalated" "got $(jq -r '.escalated' <<<"$OUT35")"
[ "$(jq -r '.handed_off' <<<"$OUT35")" = "0" ] && ok "handed_off=0 (NOT re-queued for resume)" || bad "t35.handed_off" "got $(jq -r '.handed_off' <<<"$OUT35")"
grep -qx "issue edit 101 -R Towheads/stageFind --remove-label funnel-merge-pending --add-assignee towhead --add-label funnel-escalated" "$C35/gh-calls.txt" \
  && ok "gh dropped the merge-pending label + assigned operator + funnel-escalated (#697)" || bad "t35.edit" "got $(cat "$C35/gh-calls.txt" 2>/dev/null || echo none)"
grep -q '^issue comment 101 ' "$C35/gh-calls.txt" \
  && ok "gh posted an escalation comment naming the failed check" || bad "t35.comment" "no issue comment in $(cat "$C35/gh-calls.txt" 2>/dev/null || echo none)"
grep -qx "issue edit 101 -R Towheads/stageFind --add-label funnel-merge-pending" "$C35/gh-calls.txt" \
  && bad "t35.no-resume" "the PR was ALSO re-labeled for resume (loop not broken)" || ok "the PR was NOT re-labeled funnel-merge-pending (loop broken)"

# ── 36: merge-pending PR whose required check is still RUNNING → resumed, not escalated ─
echo "--- test 36: open PR + pending checks → handed_off (resume), escalated=0 (#665) ---"
C36="$TMP/c36"; mkdir -p "$C36"; D36="$(make_merge_double "$C36")"; G36="$(make_gh_double "$C36")"
OUT36="$(printf '%s' "$CODE1" | env CLAUDE_BIN="$D36" PIPELINE_GH_BIN="$G36" CAP_DIR="$C36" \
        GH_PR_LIST_JSON="$OPEN_PR_101" GH_PR_VIEW_JSON="$ROLLUP_PENDING" \
        PIPELINE_DRIVE_MERGE=1 MERGE_SUMMARY="$HANDOFF_SUMMARY" bash "$DRIVE")"
[ "$(jq -r '.escalated' <<<"$OUT36")" = "0" ] && ok "escalated=0 (a running check is not terminal — give CI time)" || bad "t36.escalated" "got $(jq -r '.escalated' <<<"$OUT36")"
[ "$(jq -r '.handed_off' <<<"$OUT36")" = "1" ] && ok "handed_off=1 (still resumed next tick)" || bad "t36.handed_off" "got $(jq -r '.handed_off' <<<"$OUT36")"
grep -qx "issue edit 101 -R Towheads/stageFind --add-label funnel-merge-pending" "$C36/gh-calls.txt" \
  && ok "gh kept the funnel-merge-pending resume marker" || bad "t36.label" "got $(cat "$C36/gh-calls.txt" 2>/dev/null || echo none)"

# ╭──────────────────────────────────────────────────────────────────────────╮
# │ F#687 — the merge tier PRE-FLIGHTS each board's checkout for clean-on-main  │
# │ before spawning. deploy-mini SKIPS a dirty/feature-branch checkout, so a    │
# │ tick can find board 4's plain checkout dirty or on a feature branch; every  │
# │ code drive there would hard-abort at /build --unattended Step 0.1. The      │
# │ driver routes those items to the operator instead of spawning a doomed      │
# │ session — the clean-on-main sibling of the no-checkout policy (t33).         │
# ╰──────────────────────────────────────────────────────────────────────────╯

# ── 37: a DIRTY board checkout → items failed + routed, NO spawn (F#687) ───────
echo "--- test 37: dirty checkout → merge items routed to operator, no spawn (F#687) ---"
C37="$TMP/c37"; mkdir -p "$C37"; D37="$(make_merge_double "$C37")"; G37="$(make_gh_double "$C37")"
CODIRTY="$TMP/co-dirty"; mk_repo "$CODIRTY"
: > "$CODIRTY/uncommitted.txt"   # untracked file → `git status --porcelain` non-empty → dirty
OUT37="$(printf '%s' "$CODE1" | env CLAUDE_BIN="$D37" PIPELINE_GH_BIN="$G37" CAP_DIR="$C37" \
        PIPELINE_CHECKOUT_3="$CODIRTY" PIPELINE_DRIVE_MERGE=1 bash "$DRIVE")"
[ "$(jq -r '.failed' <<<"$OUT37")" = "1" ] && ok "failed=1 (dirty checkout → synthesized failed, not built)" || bad "t37.failed" "got $(jq -r '.failed' <<<"$OUT37")"
[ "$(jq -r '.merged_pr' <<<"$OUT37")" = "0" ] && ok "merged_pr=0 (nothing merged from a doomed checkout)" || bad "t37.merged" "got $(jq -r '.merged_pr' <<<"$OUT37")"
[ ! -f "$C37/pwd.txt" ] && ok "no merge driver spawned into the dirty checkout" || bad "t37.spawn" "a driver ran: $(cat "$C37/pwd.txt")"
[ "$(jq -r '.routed' <<<"$OUT37")" = "1" ] && ok "routed=1 (the un-driveable item handed to the operator)" || bad "t37.routed" "got $(jq -r '.routed' <<<"$OUT37")"
jq -e '.merge_result.results[0].note | test("clean-on-main.*dirty")' <<<"$OUT37" >/dev/null \
  && ok "the failed note names the dirty clean-on-main reason (F#687)" || bad "t37.note" "got $(jq -r '.merge_result.results[0].note // "none"' <<<"$OUT37")"

# ── 38: a FEATURE-BRANCH board checkout → same routing (the other predicate arm) ─
echo "--- test 38: feature-branch checkout → merge items routed, no spawn (F#687) ---"
C38="$TMP/c38"; mkdir -p "$C38"; D38="$(make_merge_double "$C38")"; G38="$(make_gh_double "$C38")"
COFEAT="$TMP/co-feat"; mk_repo "$COFEAT" "fix/some-branch"
OUT38="$(printf '%s' "$CODE1" | env CLAUDE_BIN="$D38" PIPELINE_GH_BIN="$G38" CAP_DIR="$C38" \
        PIPELINE_CHECKOUT_3="$COFEAT" PIPELINE_DRIVE_MERGE=1 bash "$DRIVE")"
[ "$(jq -r '.failed' <<<"$OUT38")" = "1" ] && ok "failed=1 (feature branch → not built)" || bad "t38.failed" "got $(jq -r '.failed' <<<"$OUT38")"
[ ! -f "$C38/pwd.txt" ] && ok "no merge driver spawned into the feature-branch checkout" || bad "t38.spawn" "a driver ran: $(cat "$C38/pwd.txt")"
jq -e '.merge_result.results[0].note | test("clean-on-main.*not main")' <<<"$OUT38" >/dev/null \
  && ok "the failed note names the not-on-main clean-on-main reason (F#687)" || bad "t38.note" "got $(jq -r '.merge_result.results[0].note // "none"' <<<"$OUT38")"

# ── 39: a CLEAN-on-main board checkout still spawns + merges (no regression) ───
echo "--- test 39: clean-on-main checkout is unaffected — merge still spawns (F#687) ---"
C39="$TMP/c39"; mkdir -p "$C39"; D39="$(make_merge_double "$C39")"
OUT39="$(printf '%s' "$CODE1" | env CLAUDE_BIN="$D39" CAP_DIR="$C39" PIPELINE_DRIVE_MERGE=1 bash "$DRIVE")"
[ "$(jq -r '.merged_pr' <<<"$OUT39")" = "1" ] && ok "merged_pr=1 (clean-on-main CO3 still spawns + merges)" || bad "t39.merged" "got $(jq -r '.merged_pr' <<<"$OUT39")"
grep -q '/pipeline-drive-merge' "$C39/pwd.txt" 2>/dev/null && ok "a merge driver DID spawn for the clean checkout" || bad "t39.spawn" "no spawn: $(cat "$C39/pwd.txt" 2>/dev/null || echo none)"

# ╭──────────────────────────────────────────────────────────────────────────╮
# │ F#641 — routing / hand-off gh SIDE-EFFECTS used to swallow failures with a  │
# │ bare `|| true`: a failed routing edit left the item re-refused every tick   │
# │ with no trace; a failed hand-off label let the next tick re-drive fresh →    │
# │ a DUPLICATE PR. Failures are now RECORDED into the drive record (gh_errors   │
# │ + gh_error_count), fail-open preserved (the tick still completes).           │
# ╰──────────────────────────────────────────────────────────────────────────╯

# ── 40: a failed ROUTING edit is recorded, not swallowed (#641) ────────────────
echo "--- test 40: refused-route gh edit fails → recorded in gh_errors, fail-open (#641) ---"
C40="$TMP/c40"; mkdir -p "$C40"; D40="$(make_merge_double "$C40")"; G40="$(make_gh_double "$C40")"
OUT40="$(printf '%s' "$CODE1" | env CLAUDE_BIN="$D40" PIPELINE_GH_BIN="$G40" CAP_DIR="$C40" \
        GH_FAIL_MATCH="issue edit 101" GH_FAIL_RC=7 \
        PIPELINE_DRIVE_MERGE=1 MERGE_SUMMARY="$REFUSE_SUMMARY" bash "$DRIVE")"
[ "$(jq -r '.status' <<<"$OUT40")" = "ran" ] && ok "tick still completed (fail-open — a gh blip did not abort)" || bad "t40.status" "got $(jq -r '.status' <<<"$OUT40")"
[ "$(jq -r '.routed' <<<"$OUT40")" = "1" ] && ok "routed=1 (routing counter still advances)" || bad "t40.routed" "got $(jq -r '.routed' <<<"$OUT40")"
[ "$(jq -r '.gh_error_count >= 1' <<<"$OUT40")" = "true" ] && ok "gh_error_count>=1 (the failed edit was recorded)" || bad "t40.count" "got $(jq -r '.gh_error_count' <<<"$OUT40")"
[ "$(jq -r 'any(.gh_errors[]?; .phase=="route" and (.issue|tostring)=="101" and .exit==7)' <<<"$OUT40")" = "true" ] \
  && ok "gh_errors carries {phase:route, issue:101, exit:7}" || bad "t40.detail" "got $(jq -c '.gh_errors' <<<"$OUT40")"

# ── 41: a failed HAND-OFF label is recorded under the distinct `handoff` phase ─
# This is the duplicate-PR hole: without the marker the next tick re-drives fresh.
echo "--- test 41: hand-off label add fails → recorded as phase=handoff (#641) ---"
C41="$TMP/c41"; mkdir -p "$C41"; D41="$(make_merge_double "$C41")"; G41="$(make_gh_double "$C41")"
OUT41="$(printf '%s' "$CODE1" | env CLAUDE_BIN="$D41" PIPELINE_GH_BIN="$G41" CAP_DIR="$C41" \
        GH_FAIL_MATCH="--add-label funnel-merge-pending" \
        GH_PR_LIST_JSON="$OPEN_PR_101" PIPELINE_DRIVE_MERGE=1 MERGE_SUMMARY="$HANDOFF_SUMMARY" bash "$DRIVE")"
[ "$(jq -r '.handed_off' <<<"$OUT41")" = "1" ] && ok "handed_off=1 (counter still advances on fail-open)" || bad "t41.handed_off" "got $(jq -r '.handed_off' <<<"$OUT41")"
[ "$(jq -r 'any(.gh_errors[]?; .phase=="handoff" and (.issue|tostring)=="101")' <<<"$OUT41")" = "true" ] \
  && ok "gh_errors carries the failed hand-off label under phase=handoff" || bad "t41.detail" "got $(jq -c '.gh_errors' <<<"$OUT41")"

# ── 42: NO gh failure → gh_errors stays empty, gh_error_count=0 (no false noise) ─
echo "--- test 42: clean tick → gh_error_count=0, gh_errors=[] (#641) ---"
C42="$TMP/c42"; mkdir -p "$C42"; D42="$(make_merge_double "$C42")"; G42="$(make_gh_double "$C42")"
OUT42="$(printf '%s' "$CODE1" | env CLAUDE_BIN="$D42" PIPELINE_GH_BIN="$G42" CAP_DIR="$C42" \
        PIPELINE_DRIVE_MERGE=1 MERGE_SUMMARY="$REFUSE_SUMMARY" bash "$DRIVE")"
[ "$(jq -r '.gh_error_count' <<<"$OUT42")" = "0" ] && ok "gh_error_count=0 (no failures on a clean tick)" || bad "t42.count" "got $(jq -r '.gh_error_count' <<<"$OUT42")"
[ "$(jq -c '.gh_errors' <<<"$OUT42")" = "[]" ] && ok "gh_errors=[] (empty, no false noise)" || bad "t42.empty" "got $(jq -c '.gh_errors' <<<"$OUT42")"

# ╭──────────────────────────────────────────────────────────────────────────╮
# │ temperloop#795 — pipeline label SELF-PROVISIONING at point of use. Before   │
# │ this fix, init.sh created `fnd:status:*` but NEVER `funnel-merge-pending`/  │
# │ `funnel-escalated` (build.config.sh only documented a MANUAL one-time `gh   │
# │ label create` onboarding step) — so on a repo missing either label, the     │
# │ `--add-label` calls below are silently swallowed by `_gh_sideeffect`'s      │
# │ fail-open wrapper: the item never parks and re-routes/re-refuses every      │
# │ tick with no trace (the documented silent thrash). Fixed by ensuring each   │
# │ label via the board adapter's memoized `_board_issues_ensure_label` (the    │
# │ same idiom capture.sh's self-healing `fnd:` labels use) immediately before  │
# │ each add-label call. These tests assert the `gh label create` call is       │
# │ actually MADE at each of the three point-of-use call sites — i.e. a repo   │
# │ with NEITHER label pre-existing gets both created on demand, so the add     │
# │ below can never hit a missing-label silent swallow.                        │
# ╰──────────────────────────────────────────────────────────────────────────╯

# ── 42b: hand-off (_record_handoff) ensures funnel-merge-pending before adding ──
echo "--- test 42b: hand-off ensures funnel-merge-pending exists before labeling (#795) ---"
C42B="$TMP/c42b"; mkdir -p "$C42B"; D42B="$(make_merge_double "$C42B")"; G42B="$(make_gh_double "$C42B")"
OUT42B="$(printf '%s' "$CODE1" | env CLAUDE_BIN="$D42B" PIPELINE_GH_BIN="$G42B" CAP_DIR="$C42B" \
        GH_PR_LIST_JSON="$OPEN_PR_101" PIPELINE_DRIVE_MERGE=1 MERGE_SUMMARY="$HANDOFF_SUMMARY" bash "$DRIVE")"
[ "$(jq -r '.handed_off' <<<"$OUT42B")" = "1" ] && ok "sanity: handed_off=1" || bad "t42b.handed_off" "got $(jq -r '.handed_off' <<<"$OUT42B")"
grep -qx 'label create funnel-merge-pending -R Towheads/stageFind --color fbca04 --description Pipeline 5c: PR open, session ended pre-merge — resume next tick' "$C42B/gh-calls.txt" \
  && ok "gh label create funnel-merge-pending ran BEFORE the add-label (self-provisioned, no manual onboarding needed)" \
  || bad "t42b.ensure" "got $(cat "$C42B/gh-calls.txt" 2>/dev/null || echo none)"
# The ensure-create precedes the add-label edit for the SAME issue (ordering matters:
# a create AFTER the add would not have prevented the swallow it exists to prevent).
CREATE_LINE="$(grep -nx 'label create funnel-merge-pending -R Towheads/stageFind --color fbca04 --description Pipeline 5c: PR open, session ended pre-merge — resume next tick' "$C42B/gh-calls.txt" | cut -d: -f1)"
ADD_LINE="$(grep -nx 'issue edit 101 -R Towheads/stageFind --add-label funnel-merge-pending' "$C42B/gh-calls.txt" | cut -d: -f1)"
[ -n "$CREATE_LINE" ] && [ -n "$ADD_LINE" ] && [ "$CREATE_LINE" -lt "$ADD_LINE" ] \
  && ok "ensure-create precedes the add-label edit (ordering: create-then-add, #795)" \
  || bad "t42b.order" "create@$CREATE_LINE add@$ADD_LINE in $(cat "$C42B/gh-calls.txt")"

# ── 42c: refused routing (_route_refused) ensures funnel-escalated before adding ─
echo "--- test 42c: refused routing ensures funnel-escalated exists before labeling (#795) ---"
C42C="$TMP/c42c"; mkdir -p "$C42C"; D42C="$(make_merge_double "$C42C")"; G42C="$(make_gh_double "$C42C")"
OUT42C="$(printf '%s' "$CODE1" | env CLAUDE_BIN="$D42C" PIPELINE_GH_BIN="$G42C" CAP_DIR="$C42C" \
        PIPELINE_OPERATOR=@towhead PIPELINE_DRIVE_MERGE=1 MERGE_SUMMARY="$REFUSE_SUMMARY" bash "$DRIVE")"
[ "$(jq -r '.routed' <<<"$OUT42C")" = "1" ] && ok "sanity: routed=1" || bad "t42c.routed" "got $(jq -r '.routed' <<<"$OUT42C")"
grep -qx 'label create funnel-escalated -R Towheads/stageFind --color fbca04 --description Pipeline 5c: stuck code item (route-refused / red CI) — needs your manual merge or close' "$C42C/gh-calls.txt" \
  && ok "gh label create funnel-escalated ran BEFORE the add-label (self-provisioned)" \
  || bad "t42c.ensure" "got $(cat "$C42C/gh-calls.txt" 2>/dev/null || echo none)"

# ── 42d: stuck-PR escalation (_escalate_stuck_pr) ensures funnel-escalated too ──
echo "--- test 42d: terminal-red-CI escalation ensures funnel-escalated exists (#795) ---"
C42D="$TMP/c42d"; mkdir -p "$C42D"; D42D="$(make_merge_double "$C42D")"; G42D="$(make_gh_double "$C42D")"
OUT42D="$(printf '%s' "$CODE1" | env CLAUDE_BIN="$D42D" PIPELINE_GH_BIN="$G42D" CAP_DIR="$C42D" \
        PIPELINE_OPERATOR=@towhead GH_PR_LIST_JSON="$OPEN_PR_101" GH_PR_VIEW_JSON='{"statusCheckRollup":[{"name":"checks","status":"COMPLETED","conclusion":"FAILURE"}]}' \
        PIPELINE_DRIVE_MERGE=1 MERGE_SUMMARY="$HANDOFF_SUMMARY" bash "$DRIVE")"
[ "$(jq -r '.escalated' <<<"$OUT42D")" = "1" ] && ok "sanity: escalated=1" || bad "t42d.escalated" "got $(jq -r '.escalated' <<<"$OUT42D")"
grep -qx 'label create funnel-escalated -R Towheads/stageFind --color fbca04 --description Pipeline 5c: stuck code item (route-refused / red CI) — needs your manual merge or close' "$C42D/gh-calls.txt" \
  && ok "gh label create funnel-escalated ran BEFORE the terminal-red escalation edit (self-provisioned)" \
  || bad "t42d.ensure" "got $(cat "$C42D/gh-calls.txt" 2>/dev/null || echo none)"

# ── 42e: the ensure-create is MEMOIZED per repo|label — a burst of adds against the
# same repo pays `gh label create` at most once (board.sh's own _board_issues_ensure_label
# memo, reused as-is — #795 does not re-implement it).
echo "--- test 42e: ensure-label is memoized — at most one create per repo|label per tick (#795) ---"
REFUSE_SUMMARY_2='{"driver":"pipeline-drive-merge","layer":"5c","merged":0,"parked":0,"failed":0,"refused":2,"results":[{"action":"drive-ready","issue":101,"board":"3","status":"refused","note":"one"},{"action":"drive-ready","issue":102,"board":"3","status":"refused","note":"two"}]}'
CODE2='[{"tick":"done","actions":[{"phase":"safe","action":"drive-ready","board":"3","repo":"Towheads/stageFind","issue":101,"kind":"code"},{"phase":"safe","action":"drive-ready","board":"3","repo":"Towheads/stageFind","issue":102,"kind":"code"}]}]'
C42E="$TMP/c42e"; mkdir -p "$C42E"; D42E="$(make_merge_double "$C42E")"; G42E="$(make_gh_double "$C42E")"
OUT42E="$(printf '%s' "$CODE2" | env CLAUDE_BIN="$D42E" PIPELINE_GH_BIN="$G42E" CAP_DIR="$C42E" \
        PIPELINE_OPERATOR=@towhead PIPELINE_DRIVE_MERGE=1 PIPELINE_DRIVE_MERGE_CAP=2 \
        MERGE_SUMMARY="$REFUSE_SUMMARY_2" bash "$DRIVE")"
[ "$(jq -r '.routed' <<<"$OUT42E")" = "2" ] && ok "sanity: both refused items routed" || bad "t42e.routed" "got $(jq -r '.routed' <<<"$OUT42E")"
N_CREATES="$(grep -cx 'label create funnel-escalated -R Towheads/stageFind --color fbca04 --description Pipeline 5c: stuck code item (route-refused / red CI) — needs your manual merge or close' "$C42E/gh-calls.txt")"
[ "$N_CREATES" = "1" ] && ok "exactly ONE label-create call for two refused issues in the same repo (memoized)" || bad "t42e.memo" "got $N_CREATES creates in $(cat "$C42E/gh-calls.txt")"

# ╭──────────────────────────────────────────────────────────────────────────╮
# │ temperloop#801 (shell review of #795) — a missing board adapter must         │
# │ DEGRADE, not ABORT the tick. A bare, unguarded `_board_issues_ensure_label`   │
# │ call would be exit 127 (command not found) under `set -euo pipefail` if      │
# │ board.sh failed to source — aborting the WHOLE TICK, misattributed as a       │
# │ mystery 127 deep in a callee. That inverts #795's own point: a soft,         │
# │ per-item failure (missing label → swallowed add, tick keeps running) must     │
# │ never become STRICTLY WORSE (whole-tick abort) just because the adapter       │
# │ itself is unavailable. Fixed: (1) PIPELINE_BOARD_LIB (the test-double seam,   │
# │ mirrors PIPELINE_UNCLAIM_BIN) WARNS loudly and attributes the true cause      │
# │ when board.sh is missing; (2) each of the three call sites is `command -v`-   │
# │ guarded (PIPELINE_UNCLAIM_BIN's own "if the optional dependency resolved"     │
# │ idiom) to degrade to the pre-#795 behavior instead of crashing.               │
# ╰──────────────────────────────────────────────────────────────────────────╯

# ── 42f: a missing board adapter degrades — tick completes, WARNING attributes the
# true cause, no 127 leaks, and the item is still processed (pre-#795 behavior) ────
echo "--- test 42f: missing board.sh degrades (WARNING + tick completes, no 127) (#801) ---"
C42F="$TMP/c42f"; mkdir -p "$C42F"; D42F="$(make_merge_double "$C42F")"; G42F="$(make_gh_double "$C42F")"
set +e
OUT42F="$(printf '%s' "$CODE1" | env CLAUDE_BIN="$D42F" PIPELINE_GH_BIN="$G42F" CAP_DIR="$C42F" \
        PIPELINE_BOARD_LIB="$TMP/no-such-board-lib-$$.sh" \
        GH_PR_LIST_JSON="$OPEN_PR_101" PIPELINE_DRIVE_MERGE=1 MERGE_SUMMARY="$HANDOFF_SUMMARY" \
        bash "$DRIVE" 2>"$C42F/stderr.txt")"
RC42F=$?
set -e
[ "$RC42F" -eq 0 ] && ok "exit 0 (no 127 — the tick does not abort on a missing adapter)" || bad "t42f.exit" "got exit $RC42F, stderr: $(cat "$C42F/stderr.txt" 2>/dev/null || echo none)"
[ "$(jq -r '.handed_off' <<<"$OUT42F" 2>/dev/null)" = "1" ] && ok "handed_off=1 (the tick still completes and processes the item)" || bad "t42f.handed_off" "got: $OUT42F"
grep -qF 'WARNING: pipeline-drive.sh: board adapter not found' "$C42F/stderr.txt" \
  && ok "WARNING attributes the TRUE cause (missing board adapter), not a bare 127" \
  || bad "t42f.warning" "got $(cat "$C42F/stderr.txt" 2>/dev/null || echo none)"
grep -qiF 'command not found' "$C42F/stderr.txt" \
  && bad "t42f.no127" "a 'command not found' 127 leaked to stderr — the guard did not hold" \
  || ok "no 'command not found' 127 on stderr (the command -v guard held)"
# Pre-#795 behavior restored: NO label-create call was made (adapter unavailable),
# but the add-label edit still fires exactly as it did before #795 existed.
grep -qx 'label create funnel-merge-pending -R Towheads/stageFind --color fbca04 --description Pipeline 5c: PR open, session ended pre-merge — resume next tick' "$C42F/gh-calls.txt" 2>/dev/null \
  && bad "t42f.noensure" "a label-create call happened despite the missing adapter" \
  || ok "no label-create call (adapter unavailable — self-provisioning correctly skipped)"
grep -qx "issue edit 101 -R Towheads/stageFind --add-label funnel-merge-pending" "$C42F/gh-calls.txt" \
  && ok "the add-label edit still fires (degraded to pre-#795 behavior, not crashed)" \
  || bad "t42f.add" "got $(cat "$C42F/gh-calls.txt" 2>/dev/null || echo none)"

# ╭──────────────────────────────────────────────────────────────────────────╮
# │ F#640 — record ENRICHMENT: the drive record logged COUNTS (routed,          │
# │ handed_off) but not WHICH issues, so a soak reviewer could not cross-check   │
# │ the pipeline's board mutations. Now it carries per-side-effect issue arrays    │
# │ (routed_issues / handed_off_issues / escalated_issues) + a drive duration.   │
# ╰──────────────────────────────────────────────────────────────────────────╯

# ── 43: a routed item's issue number is in routed_issues (mutation audit) ─────
echo "--- test 43: routed_issues carries the acted-on issue number (#640) ---"
C43="$TMP/c43"; mkdir -p "$C43"; D43="$(make_merge_double "$C43")"; G43="$(make_gh_double "$C43")"
OUT43="$(printf '%s' "$CODE1" | env CLAUDE_BIN="$D43" PIPELINE_GH_BIN="$G43" CAP_DIR="$C43" \
        PIPELINE_NOW_EPOCH=1000 PIPELINE_DRIVE_MERGE=1 MERGE_SUMMARY="$REFUSE_SUMMARY" bash "$DRIVE")"
[ "$(jq -c '.routed_issues' <<<"$OUT43")" = "[101]" ] && ok "routed_issues=[101] (the routed issue is auditable)" || bad "t43.routed_issues" "got $(jq -c '.routed_issues' <<<"$OUT43")"
[ "$(jq -c '.handed_off_issues' <<<"$OUT43")" = "[]" ] && ok "handed_off_issues=[] (nothing handed off on a refuse)" || bad "t43.handoff_issues" "got $(jq -c '.handed_off_issues' <<<"$OUT43")"
[ "$(jq -r '.routed' <<<"$OUT43")" = "1" ] && ok "routed count still agrees with the array length" || bad "t43.count" "got $(jq -r '.routed' <<<"$OUT43")"

# ── 44: a handed-off item's issue number is in handed_off_issues ──────────────
echo "--- test 44: handed_off_issues carries the resumed issue number (#640) ---"
C44="$TMP/c44"; mkdir -p "$C44"; D44="$(make_merge_double "$C44")"; G44="$(make_gh_double "$C44")"
OUT44="$(printf '%s' "$CODE1" | env CLAUDE_BIN="$D44" PIPELINE_GH_BIN="$G44" CAP_DIR="$C44" \
        GH_PR_LIST_JSON="$OPEN_PR_101" PIPELINE_DRIVE_MERGE=1 MERGE_SUMMARY="$HANDOFF_SUMMARY" bash "$DRIVE")"
[ "$(jq -c '.handed_off_issues' <<<"$OUT44")" = "[101]" ] && ok "handed_off_issues=[101]" || bad "t44.handoff_issues" "got $(jq -c '.handed_off_issues' <<<"$OUT44")"

# ── 45: the drive record carries a duration_ms timing field ───────────────────
echo "--- test 45: drive record carries duration_ms (#640 timing) ---"
C45="$TMP/c45"; mkdir -p "$C45"; D45="$(make_merge_double "$C45")"; G45="$(make_gh_double "$C45")"
OUT45="$(printf '%s' "$CODE1" | env CLAUDE_BIN="$D45" PIPELINE_GH_BIN="$G45" CAP_DIR="$C45" \
        PIPELINE_DRIVE_MERGE=1 MERGE_SUMMARY="$REFUSE_SUMMARY" bash "$DRIVE")"
[ "$(jq -r 'has("duration_ms")' <<<"$OUT45")" = "true" ] && ok "record has duration_ms" || bad "t45.has" "got $(jq -c '.' <<<"$OUT45")"
[ "$(jq -r '.duration_ms >= 0 and (.duration_ms|type)=="number"' <<<"$OUT45")" = "true" ] && ok "duration_ms is a non-negative number" || bad "t45.num" "got $(jq -r '.duration_ms' <<<"$OUT45")"

# ╭──────────────────────────────────────────────────────────────────────────╮
# │ F#718 — the wake record under-reported merges. Three fixes:                 │
# │  (1) merge_status enum disambiguates a `merged_pr` value (reported /        │
# │      unparseable / not-run) so a bare null no longer reads as "field        │
# │      absent" to a soak reviewer.                                            │
# │  (2) reconciled_merged (+ audit) counts pipeline-opened PRs that merged       │
# │      ASYNC — the merge-pending issue is now CLOSED — and RETIRES the label. │
# │  (3) merge_pending (+ audit) is the standing ground-truth open set, the     │
# │      cross-check for the same-tick handed_off.                              │
# ╰──────────────────────────────────────────────────────────────────────────╯

# ── 46: merge_status="reported" on a clean parsed merge (merged_pr is a real count) ─
echo "--- test 46: merge_status=reported when the driver summary parses (#718) ---"
C46="$TMP/c46"; mkdir -p "$C46"; D46="$(make_merge_double "$C46")"; G46="$(make_gh_double "$C46")"
OUT46="$(printf '%s' "$CODE1" | env CLAUDE_BIN="$D46" PIPELINE_GH_BIN="$G46" CAP_DIR="$C46" \
        PIPELINE_DRIVE_MERGE=1 bash "$DRIVE")"   # default summary = one clean merge
[ "$(jq -r '.merge_status' <<<"$OUT46")" = "reported" ] && ok "merge_status=reported (summary parsed)" || bad "t46.status" "got $(jq -r '.merge_status' <<<"$OUT46")"
[ "$(jq -r '.merged_pr' <<<"$OUT46")" = "1" ] && ok "merged_pr=1 is a real count under merge_status=reported" || bad "t46.merged_pr" "got $(jq -r '.merged_pr' <<<"$OUT46")"

# ── 47: in-flight/errored driver → merge_status="unparseable", merged_pr stays null ─
# The F#718 symptom-2 case: the one-shot session died before a parseable Step-3 summary.
# merged_pr:null is now SELF-DESCRIBING (unparseable), not indistinguishable from absent.
echo "--- test 47: unparseable merge summary → merge_status=unparseable, merged_pr=null (#718) ---"
C47="$TMP/c47"; mkdir -p "$C47"; D47="$(make_merge_double "$C47")"; G47="$(make_gh_double "$C47")"
OUT47="$(printf '%s' "$CODE1" | env CLAUDE_BIN="$D47" PIPELINE_GH_BIN="$G47" CAP_DIR="$C47" \
        PIPELINE_DRIVE_MERGE=1 MERGE_SUMMARY="not json at all" bash "$DRIVE")"
[ "$(jq -r '.merge_status' <<<"$OUT47")" = "unparseable" ] && ok "merge_status=unparseable (ran but no parseable summary)" || bad "t47.status" "got $(jq -r '.merge_status' <<<"$OUT47")"
[ "$(jq -r '.merged_pr' <<<"$OUT47")" = "null" ] && ok "merged_pr=null (unknown, NOT a false 0) — now labeled by merge_status" || bad "t47.merged_pr" "got $(jq -r '.merged_pr' <<<"$OUT47")"

# ── 48: merge tier not driven → merge_status="not-run", merged_pr=0 (a definitive 0) ─
# CODE1 is a kind:code item; with PIPELINE_DRIVE_MERGE off it is surfaced-not-driven, so the
# merge tier never runs and merged_pr=0 is a TRUE zero — distinct from the null above.
echo "--- test 48: merge tier off → merge_status=not-run, merged_pr=0 (#718) ---"
C48="$TMP/c48"; mkdir -p "$C48"; D48="$(make_merge_double "$C48")"; G48="$(make_gh_double "$C48")"
OUT48="$(printf '%s' "$CODE1" | env CLAUDE_BIN="$D48" PIPELINE_GH_BIN="$G48" CAP_DIR="$C48" bash "$DRIVE")"
[ "$(jq -r '.merge_status' <<<"$OUT48")" = "not-run" ] && ok "merge_status=not-run (merge tier did not run)" || bad "t48.status" "got $(jq -r '.merge_status' <<<"$OUT48")"
[ "$(jq -r '.merged_pr' <<<"$OUT48")" = "0" ] && ok "merged_pr=0 is a definitive zero under merge_status=not-run" || bad "t48.merged_pr" "got $(jq -r '.merged_pr' <<<"$OUT48")"

# ── 49: an async-merged pipeline PR is RECONCILED — pending issue now CLOSED (#718) ──
# The core F#718 fix: the pipeline opened a PR on a prior tick (issue 701 labeled
# funnel-merge-pending); it merged via the queue/async since. Its `Closes #701` closed the
# issue, so the reconciliation probe sees state=CLOSED → counts reconciled_merged and
# RETIRES the label so it is never recounted. Reconcilable from the telemetry ALONE.
echo "--- test 49: async-merged pipeline PR (pending issue closed) → reconciled_merged + label retired (#718) ---"
C49="$TMP/c49"; mkdir -p "$C49"; D49="$(make_merge_double "$C49")"; G49="$(make_gh_double "$C49")"
OUT49="$(printf '%s' "$CODE1" | env CLAUDE_BIN="$D49" PIPELINE_GH_BIN="$G49" CAP_DIR="$C49" \
        GH_PENDING_JSON='[{"number":701,"state":"CLOSED"}]' bash "$DRIVE")"
[ "$(jq -r '.reconciled_merged' <<<"$OUT49")" = "1" ] && ok "reconciled_merged=1 (async merge of a pipeline-opened PR seen)" || bad "t49.count" "got $(jq -r '.reconciled_merged' <<<"$OUT49")"
[ "$(jq -c '.reconciled_merged_issues' <<<"$OUT49")" = "[701]" ] && ok "reconciled_merged_issues=[701] (reconcilable from telemetry alone)" || bad "t49.audit" "got $(jq -c '.reconciled_merged_issues' <<<"$OUT49")"
[ "$(jq -r '.merge_pending' <<<"$OUT49")" = "0" ] && ok "merge_pending=0 (the closed one left the standing set)" || bad "t49.pending" "got $(jq -r '.merge_pending' <<<"$OUT49")"
grep -qx "issue edit 701 -R Towheads/stageFind --remove-label funnel-merge-pending" "$C49/gh-calls.txt" \
  && ok "label retired on the reconciled issue (bounded set, no recount next tick)" || bad "t49.retire" "got $(cat "$C49/gh-calls.txt" 2>/dev/null || echo none)"

# ── 50: a still-open pipeline PR is counted in the standing merge_pending set (#718) ─
# The symptom-3 cross-check: issue 702 is labeled funnel-merge-pending and STILL OPEN, so
# the "opened-but-not-yet-merged" set is visible in telemetry — the label is KEPT (no write).
echo "--- test 50: still-open pending pipeline PR → merge_pending, label kept (#718) ---"
C50="$TMP/c50"; mkdir -p "$C50"; D50="$(make_merge_double "$C50")"; G50="$(make_gh_double "$C50")"
OUT50="$(printf '%s' "$CODE1" | env CLAUDE_BIN="$D50" PIPELINE_GH_BIN="$G50" CAP_DIR="$C50" \
        GH_PENDING_JSON='[{"number":702,"state":"OPEN"}]' bash "$DRIVE")"
[ "$(jq -r '.merge_pending' <<<"$OUT50")" = "1" ] && ok "merge_pending=1 (standing open set surfaced)" || bad "t50.count" "got $(jq -r '.merge_pending' <<<"$OUT50")"
[ "$(jq -c '.merge_pending_issues' <<<"$OUT50")" = "[702]" ] && ok "merge_pending_issues=[702] (auditable)" || bad "t50.audit" "got $(jq -c '.merge_pending_issues' <<<"$OUT50")"
[ "$(jq -r '.reconciled_merged' <<<"$OUT50")" = "0" ] && ok "reconciled_merged=0 (still open, not merged)" || bad "t50.reconciled" "got $(jq -r '.reconciled_merged' <<<"$OUT50")"
[ ! -f "$C50/gh-calls.txt" ] && ok "no gh write — an open pending issue keeps its label for the next tick" || bad "t50.nowrite" "gh was called: $(cat "$C50/gh-calls.txt")"

# ── 51: reconciliation splits a MIXED pending set correctly (closed vs open) ──────
echo "--- test 51: mixed pending set → reconciled the closed one, kept the open one (#718) ---"
C51="$TMP/c51"; mkdir -p "$C51"; D51="$(make_merge_double "$C51")"; G51="$(make_gh_double "$C51")"
OUT51="$(printf '%s' "$CODE1" | env CLAUDE_BIN="$D51" PIPELINE_GH_BIN="$G51" CAP_DIR="$C51" \
        GH_PENDING_JSON='[{"number":701,"state":"CLOSED"},{"number":702,"state":"OPEN"}]' bash "$DRIVE")"
[ "$(jq -r '.reconciled_merged' <<<"$OUT51")" = "1" ] && ok "reconciled_merged=1 (only the closed one)" || bad "t51.reconciled" "got $(jq -r '.reconciled_merged' <<<"$OUT51")"
[ "$(jq -r '.merge_pending' <<<"$OUT51")" = "1" ] && ok "merge_pending=1 (only the open one)" || bad "t51.pending" "got $(jq -r '.merge_pending' <<<"$OUT51")"
[ "$(jq -c '.reconciled_merged_issues' <<<"$OUT51")" = "[701]" ] && ok "audit: reconciled=[701]" || bad "t51.a1" "got $(jq -c '.reconciled_merged_issues' <<<"$OUT51")"
[ "$(jq -c '.merge_pending_issues' <<<"$OUT51")" = "[702]" ] && ok "audit: pending=[702]" || bad "t51.a2" "got $(jq -c '.merge_pending_issues' <<<"$OUT51")"

# ── 52: reconciliation is SIDE-EFFECT-FREE under --dry-run (no gh probe/write) ────
echo "--- test 52: --dry-run makes no reconciliation gh calls (#718 dry-run purity) ---"
C52="$TMP/c52"; mkdir -p "$C52"; D52="$(make_merge_double "$C52")"; G52="$(make_gh_double "$C52")"
OUT52="$(printf '%s' "$CODE1" | env CLAUDE_BIN="$D52" PIPELINE_GH_BIN="$G52" CAP_DIR="$C52" \
        PIPELINE_DRIVE_MERGE=1 GH_PENDING_JSON='[{"number":701,"state":"CLOSED"}]' bash "$DRIVE" --dry-run)"
[ "$(jq -r '.status' <<<"$OUT52")" = "dry-run" ] && ok "status=dry-run" || bad "t52.status" "got $(jq -r '.status' <<<"$OUT52")"
[ "$(jq -r '.reconciled_merged' <<<"$OUT52")" = "0" ] && ok "reconciled_merged=0 (no probe on dry-run)" || bad "t52.reconciled" "got $(jq -r '.reconciled_merged' <<<"$OUT52")"
[ ! -f "$C52/gh-calls.txt" ] && ok "no gh side-effects on dry-run (label not retired)" || bad "t52.nowrite" "gh was called: $(cat "$C52/gh-calls.txt")"

# ── 53: boards.conf registry seam (foundation #770) — _board_repo honors an override ─
# _board_repo is the pipeline mirror of board.sh's board_repo() (#718's inlined-map
# comment). #770 taught both to resolve an optional boards.conf FIRST, falling back
# to the byte-identical built-in map when no conf exists. _reconcile_pending's
# `-R "$repo"` label-remove write is the one observable side-effect that carries
# _board_repo's resolved value, so it doubles as this seam's integration test.
echo "--- test 53: _board_repo resolves board 3's repo from a repo-local boards.conf override ---"
C53="$TMP/c53"; mkdir -p "$C53"; D53="$(make_merge_double "$C53")"; G53="$(make_gh_double "$C53")"
CONF53="$TMP/c53-boards.conf"
cat > "$CONF53" <<'EOF'
board.3.repo=Conf/board3-override
EOF
OUT53="$(printf '%s' "$CODE1" | env CLAUDE_BIN="$D53" PIPELINE_GH_BIN="$G53" CAP_DIR="$C53" \
        BOARDS_CONF_REPO_LOCAL="$CONF53" BOARDS_CONF_MACHINE="$TMP/no-such-machine.conf" \
        GH_PENDING_JSON='[{"number":701,"state":"CLOSED"}]' bash "$DRIVE")"
[ "$(jq -r '.reconciled_merged' <<<"$OUT53")" = "1" ] && ok "reconciled_merged=1 (conf-resolved repo still drives the probe)" || bad "t53.reconciled" "got $(jq -r '.reconciled_merged' <<<"$OUT53")"
grep -qx "issue edit 701 -R Conf/board3-override --remove-label funnel-merge-pending" "$C53/gh-calls.txt" \
  && ok "label retired against the boards.conf-resolved repo, not the built-in Towheads/stageFind" \
  || bad "t53.repo" "got $(cat "$C53/gh-calls.txt" 2>/dev/null || echo none)"

echo "--- test 53b: with NO boards.conf, _board_repo falls back to the byte-identical built-in map ---"
C53B="$TMP/c53b"; mkdir -p "$C53B"; D53B="$(make_merge_double "$C53B")"; G53B="$(make_gh_double "$C53B")"
printf '%s' "$CODE1" | env CLAUDE_BIN="$D53B" PIPELINE_GH_BIN="$G53B" CAP_DIR="$C53B" \
        BOARDS_CONF_REPO_LOCAL="$TMP/no-such-boards.conf" BOARDS_CONF_MACHINE="$TMP/no-such-machine.conf" \
        GH_PENDING_JSON='[{"number":701,"state":"CLOSED"}]' bash "$DRIVE" >/dev/null
grep -qx "issue edit 701 -R Towheads/stageFind --remove-label funnel-merge-pending" "$C53B/gh-calls.txt" \
  && ok "no conf → built-in Towheads/stageFind fallback (byte-identical to pre-#770)" \
  || bad "t53b.repo" "got $(cat "$C53B/gh-calls.txt" 2>/dev/null || echo none)"

# ╭──────────────────────────────────────────────────────────────────────────╮
# │ foundation #1157 — _reclaim_abandoned releases a claim the one-shot merge  │
# │ session ABANDONED (backgrounded a wait and died before opening a PR),      │
# │ leaving the item stranded In Progress. Release predicate: (a) no terminal  │
# │ status reported, (b) no open PR, (d) issue still open; the board-status    │
# │ (c) guard lives inside unclaim.sh. Disjoint from _record_handoff (has-PR). │
# ╰──────────────────────────────────────────────────────────────────────────╯

# ── 54a: abandonment (unparseable, no PR, issue open) → released to Ready ──────
echo "--- test 54a: abandoned claim (no PR, no terminal status, issue open) → reclaimed (#1157) ---"
C54A="$TMP/c54a"; mkdir -p "$C54A"; D54A="$(make_merge_double "$C54A")"; G54A="$(make_gh_double "$C54A")"; U54A="$(make_unclaim_double "$C54A")"
OUT54A="$(printf '%s' "$CODE1" | env CLAUDE_BIN="$D54A" PIPELINE_GH_BIN="$G54A" PIPELINE_UNCLAIM_BIN="$U54A" CAP_DIR="$C54A" \
        PIPELINE_DRIVE_MERGE=1 MERGE_SUMMARY="not json at all" bash "$DRIVE")"
[ "$(jq -r '.merge_status' <<<"$OUT54A")" = "unparseable" ] && ok "sanity: the abandoned session's summary is unparseable" || bad "t54a.status" "got $(jq -r '.merge_status' <<<"$OUT54A")"
[ "$(jq -r '.reclaimed' <<<"$OUT54A")" = "1" ] && ok "reclaimed=1 (the stranded claim was released)" || bad "t54a.reclaimed" "got $(jq -r '.reclaimed' <<<"$OUT54A")"
[ "$(jq -c '.reclaimed_issues' <<<"$OUT54A")" = "[101]" ] && ok "reclaimed_issues=[101] (audit)" || bad "t54a.audit" "got $(jq -c '.reclaimed_issues' <<<"$OUT54A")"
[ "$(jq -r '.handed_off' <<<"$OUT54A")" = "0" ] && ok "handed_off=0 (no PR → not a hand-off; disjoint from reclaim)" || bad "t54a.handoff" "got $(jq -r '.handed_off' <<<"$OUT54A")"
grep -qx "101 --board 3" "$C54A/unclaim-calls.txt" && ok "unclaim.sh released #101 on board 3" || bad "t54a.unclaim" "got $(cat "$C54A/unclaim-calls.txt" 2>/dev/null || echo none)"

# ── 54b: an open PR exists → hand-off, NOT reclaimed (disjointness) ────────────
echo "--- test 54b: unparseable BUT an open PR closes the issue → hand-off, not reclaimed (#1157) ---"
C54B="$TMP/c54b"; mkdir -p "$C54B"; D54B="$(make_merge_double "$C54B")"; G54B="$(make_gh_double "$C54B")"; U54B="$(make_unclaim_double "$C54B")"
OUT54B="$(printf '%s' "$CODE1" | env CLAUDE_BIN="$D54B" PIPELINE_GH_BIN="$G54B" PIPELINE_UNCLAIM_BIN="$U54B" CAP_DIR="$C54B" \
        PIPELINE_DRIVE_MERGE=1 MERGE_SUMMARY="not json at all" \
        GH_PR_LIST_JSON='[{"number":555,"body":"Closes #101"}]' bash "$DRIVE")"
[ "$(jq -r '.reclaimed' <<<"$OUT54B")" = "0" ] && ok "reclaimed=0 (an item with an open PR is never reclaimed)" || bad "t54b.reclaimed" "got $(jq -r '.reclaimed' <<<"$OUT54B")"
[ "$(jq -r '.handed_off' <<<"$OUT54B")" = "1" ] && ok "handed_off=1 (the open PR routes it to the resume path instead)" || bad "t54b.handoff" "got $(jq -r '.handed_off' <<<"$OUT54B")"
[ ! -f "$C54B/unclaim-calls.txt" ] && ok "unclaim.sh NOT called for a has-PR item" || bad "t54b.unclaim" "unclaim was called: $(cat "$C54B/unclaim-calls.txt")"

# ── 54c: a reported terminal status (refused) → NOT reclaimed (condition a) ────
echo "--- test 54c: a refused item (reported terminal status) → routed, not reclaimed (#1157 cond a) ---"
C54C="$TMP/c54c"; mkdir -p "$C54C"; D54C="$(make_merge_double "$C54C")"; G54C="$(make_gh_double "$C54C")"; U54C="$(make_unclaim_double "$C54C")"
OUT54C="$(printf '%s' "$CODE1" | env CLAUDE_BIN="$D54C" PIPELINE_GH_BIN="$G54C" PIPELINE_UNCLAIM_BIN="$U54C" CAP_DIR="$C54C" \
        PIPELINE_OPERATOR=@towhead PIPELINE_DRIVE_MERGE=1 MERGE_SUMMARY="$REFUSE_SUMMARY" bash "$DRIVE")"
[ "$(jq -r '.reclaimed' <<<"$OUT54C")" = "0" ] && ok "reclaimed=0 (a reported terminal is owned by _route_refused, not reclaimed)" || bad "t54c.reclaimed" "got $(jq -r '.reclaimed' <<<"$OUT54C")"
[ "$(jq -r '.routed' <<<"$OUT54C")" = "1" ] && ok "routed=1 (the refused item still goes to the operator)" || bad "t54c.routed" "got $(jq -r '.routed' <<<"$OUT54C")"
[ ! -f "$C54C/unclaim-calls.txt" ] && ok "unclaim.sh NOT called for a refused item" || bad "t54c.unclaim" "unclaim was called: $(cat "$C54C/unclaim-calls.txt")"

# ── 54d: a CLOSED issue (merged mid-cascade) → NOT reclaimed (condition d) ─────
echo "--- test 54d: unparseable + no PR but the issue is CLOSED → not reclaimed (#1157 cond d) ---"
C54D="$TMP/c54d"; mkdir -p "$C54D"; D54D="$(make_merge_double "$C54D")"; G54D="$(make_gh_double "$C54D")"; U54D="$(make_unclaim_double "$C54D")"
OUT54D="$(printf '%s' "$CODE1" | env CLAUDE_BIN="$D54D" PIPELINE_GH_BIN="$G54D" PIPELINE_UNCLAIM_BIN="$U54D" CAP_DIR="$C54D" \
        PIPELINE_DRIVE_MERGE=1 MERGE_SUMMARY="not json at all" \
        GH_ISSUE_STATE="CLOSED" bash "$DRIVE")"
[ "$(jq -r '.reclaimed' <<<"$OUT54D")" = "0" ] && ok "reclaimed=0 (a closed issue is not stranded — the cascade takes it to Done)" || bad "t54d.reclaimed" "got $(jq -r '.reclaimed' <<<"$OUT54D")"
[ ! -f "$C54D/unclaim-calls.txt" ] && ok "unclaim.sh NOT called for a closed issue" || bad "t54d.unclaim" "unclaim was called: $(cat "$C54D/unclaim-calls.txt")"

# ── 55: the model-usage lake sink is CALLER-PINNED (temperloop#1565) ──────────
# THE BUG. emit-model-usage.sh derives its lake root by climbing two levels
# from its OWN file location. The pipeline runs the kernel copy VENDORED under
# a consuming checkout, so that climb landed on the vendored kernel's own root
# and every record this driver emitted went to <checkout>/kernel/meta/data/raw/
# — a stub dir holding nothing but a README. Both real lakes held zero
# model-usage records while the driver reported clean runs.
#
# THE FIX under test: this driver (the caller, which knows the canonical sink
# the emitter cannot) exports MODEL_USAGE_RAW_DIR before invoking the emitter,
# pinned to the same ${PIPELINE_RAW_DIR:-…} literal pipeline-cron.sh pins its
# own stream to. These cases are DISCRIMINATING — before the fix the record
# landed in this checkout's own meta/data/raw/ and $PIPELINE_RAW_DIR stayed
# empty, so t55 fails against the unfixed script.
#
# NOTE the `env -u MODEL_USAGE_RAW_DIR`: the suite exports that variable
# globally at the top (test-run isolation), which is exactly the override this
# fix must keep honoring — so the default path can only be exercised by
# unsetting it for these cases.
echo "--- test 55: with MODEL_USAGE_RAW_DIR unset, the record lands in PIPELINE_RAW_DIR, not the checkout (temperloop#1565) ---"
MU_MONTH="$(date -u +%Y-%m)"
# The checkout-relative dir the UNFIXED code wrote to: emit-model-usage.sh
# lives at workflows/scripts/, and climbs two levels to the repo root.
MU_CHECKOUT_LAKE="$(cd "$HERE/../../../.." && pwd)/meta/data/raw"
mu_checkout_lines() {  # total lines across the checkout lake's model-usage files
  local t=0 f n
  for f in "$MU_CHECKOUT_LAKE"/model-usage-*.jsonl; do
    [ -e "$f" ] || continue
    n="$(wc -l < "$f" 2>/dev/null | tr -d ' ')" || n=0
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    t=$((t + n))
  done
  printf '%s' "$t"
}
MU_BEFORE="$(mu_checkout_lines)"
MU_LAKE="$TMP/canonical-lake"
MU_PLAN='[{"tick":"done","actions":[
  {"phase":"drain","action":"drain-answer","board":"3","repo":"Towheads/stageFind","issue":42,"chosen":"timed"}
]}]'
OUT55="$(printf '%s' "$MU_PLAN" | env -u MODEL_USAGE_RAW_DIR PIPELINE_RAW_DIR="$MU_LAKE" \
          CLAUDE_BIN="$CAP_DOUBLE" CAP_DIR="$TMP/cap55" PIPELINE_DRIVE_MODEL="claude-test" bash "$DRIVE")"
[ "$(jq -r '.status' <<<"$OUT55")" = "ran" ] && ok "the drive still ran" || bad "t55.status" "$OUT55"
[ -s "$MU_LAKE/model-usage-$MU_MONTH.jsonl" ] \
  && ok "the model-usage record landed in the CANONICAL lake (\$PIPELINE_RAW_DIR), not a vendored-checkout stub" \
  || bad "t55.sink" "no record at $MU_LAKE/model-usage-$MU_MONTH.jsonl (dir: $(ls -A "$MU_LAKE" 2>/dev/null || echo MISSING))"
jq -e -r 'select(.seat=="pipeline-drive-safe") | .outcome_ref' < "$MU_LAKE/model-usage-$MU_MONTH.jsonl" >/dev/null 2>&1 \
  && ok "…and it is this driver's own safe-tier record" \
  || bad "t55.seat" "$(cat "$MU_LAKE/model-usage-$MU_MONTH.jsonl" 2>/dev/null)"
[ "$(mu_checkout_lines)" = "$MU_BEFORE" ] \
  && ok "and NOTHING was appended to this checkout's own meta/data/raw (the pre-fix destination)" \
  || bad "t55.leak" "the checkout lake grew from $MU_BEFORE to $(mu_checkout_lines)"

echo "--- test 56: an explicitly-set MODEL_USAGE_RAW_DIR still wins (the pin is a default, not a clobber) ---"
MU_OVERRIDE="$TMP/explicit-override-lake"
OUT56="$(printf '%s' "$MU_PLAN" | env MODEL_USAGE_RAW_DIR="$MU_OVERRIDE" PIPELINE_RAW_DIR="$TMP/decoy-lake" \
          CLAUDE_BIN="$CAP_DOUBLE" CAP_DIR="$TMP/cap56" PIPELINE_DRIVE_MODEL="claude-test" bash "$DRIVE")"
[ "$(jq -r '.status' <<<"$OUT56")" = "ran" ] && ok "the drive still ran" || bad "t56.status" "$OUT56"
[ -s "$MU_OVERRIDE/model-usage-$MU_MONTH.jsonl" ] \
  && ok "an already-set MODEL_USAGE_RAW_DIR passes through untouched (the live test seam this suite itself relies on)" \
  || bad "t56.override" "no record at $MU_OVERRIDE"
[ ! -e "$TMP/decoy-lake/model-usage-$MU_MONTH.jsonl" ] \
  && ok "…and PIPELINE_RAW_DIR does NOT override it" || bad "t56.precedence" "the decoy lake was written"

echo "--- test 57: the \$HOME expansion is guarded — an unset HOME never aborts the seam (temperloop#1565) ---"
# pipeline-drive.sh runs under `set -u`, where a bare $HOME in the pinned
# default is an immediate abort. Assert on the SHIPPED bytes of the guard
# itself rather than the whole script: with HOME unset the script already dies
# earlier, inside build.config.sh (a pre-existing, unrelated condition), so a
# whole-script run cannot tell a guarded seam from an unguarded one. Extracting
# and evaluating the exact three-line block does.
MU_GUARD_START="$(grep -n -F 'if [ -n "${MODEL_USAGE_RAW_DIR:-}" ]' "$DRIVE" | head -n1 | cut -d: -f1)"
MU_GUARD_END="$((MU_GUARD_START + 2))"
MU_GUARD="$(sed -n "${MU_GUARD_START},${MU_GUARD_END}p" "$DRIVE")"
[ -n "$MU_GUARD_START" ] && [ "$(sed -n "${MU_GUARD_END}p" "$DRIVE")" = "fi" ] \
  && ok "located the guarded pin block in the shipped script" || bad "t57.locate" "block not found at $MU_GUARD_START"
MU_G1="$(env -u HOME -u PIPELINE_RAW_DIR -u MODEL_USAGE_RAW_DIR bash -c \
  'set -uo pipefail; '"$MU_GUARD"'; printf "SURVIVED:%s" "${_MODEL_USAGE_SINK_DIR:-<unset>}"' 2>&1)" || MU_G1="ABORTED:$MU_G1"
[ "$MU_G1" = "SURVIVED:<unset>" ] \
  && ok "HOME/PIPELINE_RAW_DIR/MODEL_USAGE_RAW_DIR all unset → the seam sets nothing and does not abort (the emitter keeps its own default)" \
  || bad "t57.unset-home" "got '$MU_G1'"
# BSD env(1): every -u must precede the NAME=VALUE assignments (a trailing
# -u is parsed as a command name and fails "No such file or directory").
MU_G2="$(env -u PIPELINE_RAW_DIR -u MODEL_USAGE_RAW_DIR HOME="$TMP/fakehome" bash -c \
  'set -uo pipefail; '"$MU_GUARD"'; printf "%s" "$_MODEL_USAGE_SINK_DIR"' 2>&1)" || MU_G2="ABORTED:$MU_G2"
[ "$MU_G2" = "$TMP/fakehome/dev/foundation/meta/data/raw" ] \
  && ok "with HOME set and no overrides, the pin resolves to the canonical absolute sink" || bad "t57.home-set" "got '$MU_G2'"
MU_G3="$(env -u HOME -u MODEL_USAGE_RAW_DIR PIPELINE_RAW_DIR="$TMP/pin-lake" bash -c \
  'set -uo pipefail; '"$MU_GUARD"'; printf "%s" "$_MODEL_USAGE_SINK_DIR"' 2>&1)" || MU_G3="ABORTED:$MU_G3"
[ "$MU_G3" = "$TMP/pin-lake" ] \
  && ok "PIPELINE_RAW_DIR alone is enough — HOME is never expanded when it is not needed" || bad "t57.pipeline-only" "got '$MU_G3'"

echo "--- test 58: the pinned literal matches pipeline-cron.sh's own RAW_DIR literal, byte-for-byte ---"
# The wrapper is this script's PARENT. If the two literals ever drift, the
# cron's own stream and this driver's model-usage stream resolve to different
# directories whenever PIPELINE_RAW_DIR is unset — reintroducing #1565 by a
# different route. Compare the shipped text, not a resolved path.
MU_CRON_LIT="$(grep -F 'RAW_DIR="${PIPELINE_RAW_DIR:-' "$(cd "$HERE/.." && pwd)/pipeline-cron.sh" | head -n1 | sed -E 's/.*\$\{PIPELINE_RAW_DIR:-(.*)\}".*/\1/')"
MU_DRIVE_LIT="$(grep -F 'MODEL_USAGE_RAW_DIR:-${PIPELINE_RAW_DIR:-' "$DRIVE" | grep -v '^[[:space:]]*#' | head -n1 | sed -E 's/.*\$\{PIPELINE_RAW_DIR:-(.*)\}\}".*/\1/')"
[ -n "$MU_CRON_LIT" ] && [ "$MU_CRON_LIT" = "$MU_DRIVE_LIT" ] \
  && ok "pipeline-drive.sh's pinned default ($MU_DRIVE_LIT) equals pipeline-cron.sh's RAW_DIR literal verbatim" \
  || bad "t58.equal" "cron='$MU_CRON_LIT' drive='$MU_DRIVE_LIT'"

# ── 59: the spawned driver must not inherit the sink pin (temperloop#1565) ────
# THE REGRESSION THIS GUARDS, and why it is not cosmetic. Handing the emitter
# its sink via `export MODEL_USAGE_RAW_DIR` at the top of this script works for
# the emitter and breaks everything downstream: an export is process-wide and
# INHERITED, and _spawn_in_checkout launches a headless `claude -p` with the
# full inherited environment. That session runs /pipeline-drive → /build →
# scripts/quality-gates.sh, and MODEL_USAGE_RAW_DIR is read by more than the
# emitter — validate-model-usage-emit.sh and validate-provider-disclosure.sh
# both consult it. An exported pin therefore silently converts two REPO-SCOPED
# gates into PRODUCTION-DATA gates inside an autonomous drive: the emit
# validator strict-parses a long-lived append-only stream written by several
# emitter versions, and the disclosure gate joins production sends against the
# WORKTREE's disclosure log. That is #1565's own defect class inverted.
#
# So the pin is applied as a per-command prefix on the emitter alone, and the
# spawned child must see NOTHING. This case fails against the exported version.
echo "--- test 59: the spawned driver's environment carries NO sink pin (temperloop#1565 review) ---"
ENV_DOUBLE="$TMP/claude-env-probe.sh"
cat > "$ENV_DOUBLE" <<'ENVDOUBLE'
#!/usr/bin/env bash
# Record what THIS CHILD sees, then behave like the ordinary capture double.
printf '%s\n' "${MODEL_USAGE_RAW_DIR:-<unset>}" >> "$ENV_REC"
echo '{"driver":"pipeline-drive","layer":"5b","executed":1,"failed":0,"refused":0,"results":[]}'
ENVDOUBLE
chmod +x "$ENV_DOUBLE"
ENV_REC59="$TMP/env59.txt"
MU_LAKE59="$TMP/lake59"
OUT59="$(printf '%s' "$MU_PLAN" | env -u MODEL_USAGE_RAW_DIR PIPELINE_RAW_DIR="$MU_LAKE59" \
          CLAUDE_BIN="$ENV_DOUBLE" ENV_REC="$ENV_REC59" PIPELINE_DRIVE_MODEL="claude-test" bash "$DRIVE")"
[ "$(jq -r '.status' <<<"$OUT59")" = "ran" ] && ok "the drive ran" || bad "t59.status" "$OUT59"
[ -s "$ENV_REC59" ] && ok "the headless driver double was spawned" || bad "t59.spawned" "no spawn recorded"
[ "$(head -n1 "$ENV_REC59")" = "<unset>" ] \
  && ok "the spawned driver inherits NO MODEL_USAGE_RAW_DIR — its quality gates keep reading their own checkout" \
  || bad "t59.inherited" "the child inherited MODEL_USAGE_RAW_DIR=$(head -n1 "$ENV_REC59")"
[ -s "$MU_LAKE59/model-usage-$MU_MONTH.jsonl" ] \
  && ok "…while the emitter still wrote to the pinned canonical lake (the pin works, it just does not leak)" \
  || bad "t59.emit" "no record at $MU_LAKE59"

echo "--- test 60: an operator-exported MODEL_USAGE_RAW_DIR still reaches the child unchanged ---"
# The complement, so t59 cannot be satisfied by scrubbing the variable on the
# way out: if the OPERATOR's environment exports it, that is their call and this
# script neither injects nor strips. t59 proves we add no leak; this proves we
# do not silently remove an inherited one.
ENV_REC60="$TMP/env60.txt"
OUT60="$(printf '%s' "$MU_PLAN" | env MODEL_USAGE_RAW_DIR="$TMP/lake60" \
          CLAUDE_BIN="$ENV_DOUBLE" ENV_REC="$ENV_REC60" PIPELINE_DRIVE_MODEL="claude-test" bash "$DRIVE")"
[ "$(jq -r '.status' <<<"$OUT60")" = "ran" ] && ok "the drive ran" || bad "t60.status" "$OUT60"
[ "$(head -n1 "$ENV_REC60")" = "$TMP/lake60" ] \
  && ok "an operator-exported value reaches the child untouched" || bad "t60.passthrough" "got $(head -n1 "$ENV_REC60")"

# ── 61: the pin is applied at the EMIT call, not the process (structural) ─────
echo "--- test 61: neither caller exports MODEL_USAGE_RAW_DIR (structural anti-regression) ---"
# A behavioural test can only catch the leak on the paths it exercises; this
# catches it wherever it is reintroduced, and names the correct mechanism.
for f in "$DRIVE" "$(cd "$HERE/.." && pwd)/pipeline-retro-judge-spawn.sh"; do
  if grep -v '^[[:space:]]*#' "$f" | grep -E 'export[[:space:]]+MODEL_USAGE_RAW_DIR' >/dev/null; then
    bad "t61.export" "$(basename "$f") exports MODEL_USAGE_RAW_DIR — use the scoped _MODEL_USAGE_SINK_DIR pin instead"
  else
    ok "$(basename "$f") does not export MODEL_USAGE_RAW_DIR"
  fi
  if grep -v '^[[:space:]]*#' "$f" | grep -F '_MODEL_USAGE_SINK_DIR=' >/dev/null; then
    ok "$(basename "$f") sets the scoped, non-exported _MODEL_USAGE_SINK_DIR pin"
  else
    bad "t61.pin" "$(basename "$f") no longer sets _MODEL_USAGE_SINK_DIR"
  fi
done
MU_LIB="$(cd "$HERE/../.." && pwd)/lib/model-usage-envelope.sh"
grep -F 'MODEL_USAGE_RAW_DIR="$_MODEL_USAGE_SINK_DIR" "$emit_script"' "$MU_LIB" >/dev/null \
  && ok "the shared lib applies the sink as a PER-COMMAND prefix on the emitter alone" \
  || bad "t61.lib" "model-usage-envelope.sh no longer applies the sink as a per-command prefix"

# ── summary ──────────────────────────────────────────────────────────────────
echo
echo "pipeline-drive tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
