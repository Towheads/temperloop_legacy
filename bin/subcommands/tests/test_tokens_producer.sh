#!/usr/bin/env bash
#
# Tests for the `.temperloop/report.d/tokens` LOCATOR SHIM (temperloop#980
# "producer-kernel-side-relocation") — the shim's own reachability, not the
# corpus/render concerns owned by sibling items #983/#981/#984 (see this
# item's own "Gate scope" acceptance bullet).
#
# RESOLUTION ORDER under test (see the shim's own header for the full
# rationale): 1. $TEMPERLOOP_HOME  2. self-checkout ($(dirname "$0")/../..)
# 3. `command -v temperloop`  4. skip.
#
# Covers:
#   1. SELF-CHECKOUT (resolver 2) — THE REGRESSION TEST. The shim, run from
#      its REAL in-place location inside this checkout, with $TEMPERLOOP_HOME
#      unset and no `temperloop` on PATH, still resolves and matches the
#      kernel checkout's own control output. An earlier cut of this shim
#      dropped this resolver entirely, silently degrading `temperloop
#      report` in this repo (and any other checkout carrying its own
#      producer) on any host with no installed CLI — this is the exact case
#      the prior orphan-fixture-only suite could never reach.
#   2. resolution ORDER 2>3: self-checkout wins over a DIFFERENT
#      PATH-discoverable `temperloop` when $TEMPERLOOP_HOME is unset.
#   3. a copy of the shim placed at <tmp-repo>/.temperloop/report.d/tokens,
#      in a repo with NO workflows/ directory (so self-checkout fails
#      closed), resolves the kernel via $TEMPERLOOP_HOME and emits the SAME
#      JSON object the kernel checkout's own
#      workflows/scripts/report-producers/tokens emits directly.
#   4. the same, resolved instead via `command -v temperloop`
#      (symlink-resolved to its checkout root) when $TEMPERLOOP_HOME is
#      unset — the documented resolver-3 fallback path.
#   5. resolution ORDER 1>3: $TEMPERLOOP_HOME wins over a DIFFERENT
#      PATH-discoverable `temperloop` (orphan copy, self-checkout n/a).
#   6. resolution ORDER 1>2: $TEMPERLOOP_HOME (pointed at a distinct fake
#      kernel) wins over self-checkout, even when the shim runs from its
#      REAL in-place location (where self-checkout would otherwise resolve
#      to this checkout's own real producer).
#   7. a stale/invalid $TEMPERLOOP_HOME (missing the producer, orphan copy
#      so self-checkout is n/a) falls through to the `command -v temperloop`
#      fallback rather than failing.
#   8. no kernel resolvable at all (orphan copy, unset $TEMPERLOOP_HOME, no
#      `temperloop` on PATH) -> the contract's skip line, exit 0.
#   9. STATIC: the shim itself contains no transcript-parsing / jq-shaping
#      code (comments mentioning the words are fine; only non-comment lines
#      are checked) — the implementation lives kernel-side, this file is
#      locator + exec only.
#  10. STATIC: the shim does not hardcode a fourth copy of the
#      TEMPERLOOP_HOME default install-path literal (bin/bootstrap.sh's
#      header names the three existing hand-synced copies).
#  11. ARGS PASSTHROUGH: the shim execs with "$@" (static grep on the exec
#      line) and an extra CLI arg does not break resolution (dynamic).
#
# Tests 12+ (temperloop#986 "producer-first-run-notice") cover the kernel-
# side implementation's first-run disclosure + per-person local disable,
# each against the IMPL directly with its own freshly isolated
# $XDG_STATE_HOME (never the pre-seeded one tests 1-11 share, and never the
# real machine's own state dir):
#  12. FIRST RUN: a fresh $XDG_STATE_HOME produces a `notice` naming what is
#      read, that there is no network call, and how to disable -- and the
#      tokens headline (`tokens_spent`) still renders on that same run.
#  13. SECOND RUN: the same $XDG_STATE_HOME, invoked again, renders no
#      first-run disclosure text (the marker written by test 12 suppresses
#      it) while the tokens headline still renders.
#  14. DISABLED: writing the disable marker suppresses the producer
#      entirely -- exactly the contract's skip line, exit 0 -- with no
#      commit and no working-tree change (state lives only under the
#      isolated $XDG_STATE_HOME).
#  15. STATE PATH: both markers land under
#      $XDG_STATE_HOME/temperloop/tokens-producer/, never inside the repo
#      tree (a whole-repo `git status --porcelain` delta stays unchanged
#      across tests 12-14 -- not scoped to any one subdirectory, so a stray
#      write ANYWHERE in the tree is caught, review round 2 item 7).
#  16. STATIC (comment-filtered, review round 2 item 6): the notice text
#      names $SPEND_TRANSCRIPT_ROOT (what is read) and states no network
#      call, sourced from the producer file's own NON-COMMENT lines.
#  17. BLOCKING 1 REGRESSION (review round 2): a RELATIVE $XDG_STATE_HOME,
#      run from inside $REPO_ROOT itself (report.sh's real cwd), must NOT
#      write producer state inside the repo working tree -- the XDG Base
#      Directory spec requires a relative value be ignored; it must fall
#      back to $HOME/.local/state instead.
#  18. BLOCKING 2 REGRESSION (review round 2): the disable command this
#      producer prints for a human to paste must survive an apostrophe AND
#      a space in the resolved path, and must genuinely disable the
#      producer end to end when the exact printed text is evaluated.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
SHIM="$REPO_ROOT/.temperloop/report.d/tokens"
IMPL="$REPO_ROOT/workflows/scripts/report-producers/tokens"
REAL_TEMPERLOOP_BIN="$REPO_ROOT/bin/temperloop"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

[ -f "$SHIM" ] || fail "shim not found at $SHIM"
[ -x "$SHIM" ] || fail "shim not executable at $SHIM"
[ -f "$IMPL" ] || fail "kernel-side implementation not found at $IMPL"
[ -x "$IMPL" ] || fail "kernel-side implementation not executable at $IMPL"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/tokens-producer-test-XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# Pinned, non-existent transcript root (temperloop#983): this suite tests
# the SHIM's RESOLUTION mechanics, not corpus scoping (that's
# workflows/scripts/tests/test_pipeline_spend_report.sh's job, see this
# file's own header). Since #983 the kernel-side implementation scopes its
# transcript --root to the invoking cwd's own git checkout whenever
# $SPEND_TRANSCRIPT_ROOT is NOT already set -- and several fixtures below
# deliberately vary cwd (a git checkout here, a plain non-git $ORPHAN dir
# there) purely to exercise shim resolution, which would otherwise make
# control vs. shim output diverge on corpus scope alone, unrelated to what
# this suite checks. Pinning $SPEND_TRANSCRIPT_ROOT on every invocation
# below holds corpus scope constant (and empty) so this suite's only
# variable is shim resolution, exactly as documented.
SPEND_TRANSCRIPT_ROOT="$WORK/no-transcripts-983"

# Isolated, PRE-SEEDED $XDG_STATE_HOME (temperloop#986): the kernel-side
# implementation now folds a one-time first-run disclosure into its `notice`
# field (see that file's own header) and reads a per-person disable marker,
# both under $XDG_STATE_HOME/temperloop/tokens-producer/. This suite tests
# SHIM RESOLUTION first (tests 1-11 below); tests 12+ further down in this
# same file own the notice/disable behavior itself, each with their OWN
# freshly isolated $XDG_STATE_HOME so they don't inherit this pre-seeded
# "already shown" marker. Until then, every invocation below is pointed at
# the SAME isolated, pre-seeded state dir with the "already shown" marker
# already in place, holding notice text constant (and never touching the
# real machine's own $XDG_STATE_HOME) so control_out and every shim
# invocation stay byte-comparable exactly as before this item.
XDG_STATE_HOME="$WORK/xdg-state-983"
mkdir -p "$XDG_STATE_HOME/temperloop/tokens-producer"
: > "$XDG_STATE_HOME/temperloop/tokens-producer/first-run-notice-shown"

control_out="$(SPEND_TRANSCRIPT_ROOT="$SPEND_TRANSCRIPT_ROOT" XDG_STATE_HOME="$XDG_STATE_HOME" "$IMPL")" || fail "control run of the kernel-side implementation failed"
echo "$control_out" | jq -e 'type == "object" and (.tokens_spent | type) == "number"' >/dev/null \
  || fail "control run's stdout did not parse as {tokens_spent: <number>}"

# --- fixture: a second, DISTINCT fake kernel checkout, so the ORDER tests
# can prove which resolver won by checking whose marker output appears. -----
FAKEKERNEL2="$WORK/fake-kernel-2"
mkdir -p "$FAKEKERNEL2/bin" "$FAKEKERNEL2/workflows/scripts/report-producers"
cat > "$FAKEKERNEL2/bin/temperloop" <<'EOF'
#!/usr/bin/env bash
echo "fake-kernel-2 dispatcher -- not exercised by this test"
EOF
chmod +x "$FAKEKERNEL2/bin/temperloop"
cat > "$FAKEKERNEL2/workflows/scripts/report-producers/tokens" <<'EOF'
#!/usr/bin/env bash
echo '{"tokens_spent":424242}'
EOF
chmod +x "$FAKEKERNEL2/workflows/scripts/report-producers/tokens"
FAKEBIN2="$WORK/fakebin2"
mkdir -p "$FAKEBIN2"
ln -s "$FAKEKERNEL2/bin/temperloop" "$FAKEBIN2/temperloop"

# --- 1: SELF-CHECKOUT (resolver 2) — THE REGRESSION TEST --------------------
# The shim at its REAL in-place location, $TEMPERLOOP_HOME unset, no
# `temperloop` anywhere on PATH. This is the exact scenario an earlier cut
# of this shim regressed on (no self-checkout resolver at all -> permanent
# skip in this repo on any host with no installed CLI).
out1="$(env -i HOME="$HOME" SPEND_TRANSCRIPT_ROOT="$SPEND_TRANSCRIPT_ROOT" XDG_STATE_HOME="$XDG_STATE_HOME" PATH="/usr/bin:/bin" "$SHIM")" \
  || fail "1: shim invocation (self-checkout) failed"
[ "$out1" = "$control_out" ] || fail "1: shim in place (self-checkout, no \$TEMPERLOOP_HOME, no PATH temperloop) did not match the control output.
  control: $control_out
  shim:    $out1"
echo "PASS: 1 SELF-CHECKOUT — shim in place resolves with no \$TEMPERLOOP_HOME and no PATH temperloop, matches the kernel checkout's own output"

# --- 2: resolution ORDER 2>3 — self-checkout wins over a different
# PATH-discoverable temperloop. ----------------------------------------------
out2="$(env -i HOME="$HOME" SPEND_TRANSCRIPT_ROOT="$SPEND_TRANSCRIPT_ROOT" XDG_STATE_HOME="$XDG_STATE_HOME" PATH="$FAKEBIN2:/usr/bin:/bin" "$SHIM")" \
  || fail "2: shim invocation failed"
[ "$out2" = "$control_out" ] || fail "2: self-checkout should win over a different PATH-found kernel, but output was: $out2"
echo "$out2" | grep 424242 >/dev/null && fail "2: self-checkout should have won over the PATH-found fake-kernel-2, but fake-kernel-2's output leaked through"
echo "PASS: 2 resolution order 2>3 — self-checkout wins over a different PATH-found kernel"

# --- fixture: an orphan repo (NO workflows/ dir) so self-checkout fails
# closed and the remaining tests can isolate resolvers 1/3/4 cleanly. -------
ORPHAN="$WORK/orphan-repo"
mkdir -p "$ORPHAN/.temperloop/report.d"
cp "$SHIM" "$ORPHAN/.temperloop/report.d/tokens"
chmod +x "$ORPHAN/.temperloop/report.d/tokens"
[ -d "$ORPHAN/workflows" ] && fail "test setup bug: orphan repo must have no workflows/ dir"

# --- 3: copy in a workflows/-less repo, resolved via $TEMPERLOOP_HOME ------
out3="$(cd "$ORPHAN" && env -u TEMPERLOOP_BIN_DIR TEMPERLOOP_HOME="$REPO_ROOT" SPEND_TRANSCRIPT_ROOT="$SPEND_TRANSCRIPT_ROOT" XDG_STATE_HOME="$XDG_STATE_HOME" PATH="/usr/bin:/bin" "$ORPHAN/.temperloop/report.d/tokens")" \
  || fail "3: shim invocation failed"
[ "$out3" = "$control_out" ] || fail "3: shim (via \$TEMPERLOOP_HOME) output did not match the kernel checkout's own control output.
  control: $control_out
  shim:    $out3"
echo "PASS: 3 shim in a workflows/-less repo resolves via \$TEMPERLOOP_HOME and matches the kernel checkout's own output"

# --- 4: resolved via \`command -v temperloop\` when \$TEMPERLOOP_HOME unset --
FAKEBIN="$WORK/fakebin"
mkdir -p "$FAKEBIN"
ln -s "$REAL_TEMPERLOOP_BIN" "$FAKEBIN/temperloop"

out4="$(cd "$ORPHAN" && env -i HOME="$HOME" SPEND_TRANSCRIPT_ROOT="$SPEND_TRANSCRIPT_ROOT" XDG_STATE_HOME="$XDG_STATE_HOME" PATH="$FAKEBIN:/usr/bin:/bin" "$ORPHAN/.temperloop/report.d/tokens")" \
  || fail "4: shim invocation (PATH fallback) failed"
[ "$out4" = "$control_out" ] || fail "4: shim (via 'command -v temperloop' PATH fallback) output did not match the control output.
  control: $control_out
  shim:    $out4"
echo "PASS: 4 shim with no \$TEMPERLOOP_HOME resolves via 'command -v temperloop', symlink-resolved to its checkout root"

# --- 5: resolution ORDER 1>3 — $TEMPERLOOP_HOME (real checkout) wins over a
# DIFFERENT PATH-found kernel. ------------------------------------------------
out5="$(cd "$ORPHAN" && env -i HOME="$HOME" TEMPERLOOP_HOME="$REPO_ROOT" SPEND_TRANSCRIPT_ROOT="$SPEND_TRANSCRIPT_ROOT" XDG_STATE_HOME="$XDG_STATE_HOME" PATH="$FAKEBIN2:/usr/bin:/bin" "$ORPHAN/.temperloop/report.d/tokens")" \
  || fail "5: shim invocation failed"
[ "$out5" = "$control_out" ] || fail "5: with BOTH \$TEMPERLOOP_HOME (real) and a different PATH-found kernel set, \$TEMPERLOOP_HOME should win, but output was: $out5"
echo "$out5" | grep 424242 >/dev/null && fail "5: \$TEMPERLOOP_HOME should have won over the PATH-found fake-kernel-2, but fake-kernel-2's output leaked through"
echo "PASS: 5 resolution order 1>3 — \$TEMPERLOOP_HOME wins over a different PATH-found kernel"

# --- 6: resolution ORDER 1>2 — $TEMPERLOOP_HOME (a DIFFERENT fake kernel)
# wins over self-checkout, even with the shim run from its REAL in-place
# location (where self-checkout alone would resolve to THIS checkout). ------
out6="$(env -i HOME="$HOME" TEMPERLOOP_HOME="$FAKEKERNEL2" XDG_STATE_HOME="$XDG_STATE_HOME" PATH="/usr/bin:/bin" "$SHIM")" \
  || fail "6: shim invocation failed"
echo "$out6" | jq -e '.tokens_spent == 424242' >/dev/null \
  || fail "6: \$TEMPERLOOP_HOME (fake-kernel-2) should win over self-checkout even when the shim runs in place; got: $out6"
echo "PASS: 6 resolution order 1>2 — \$TEMPERLOOP_HOME wins over self-checkout, even when the shim runs from its real in-place location"

# --- 7: a stale/invalid $TEMPERLOOP_HOME (no producer there, orphan copy so
# self-checkout is n/a) falls through to the PATH fallback. ------------------
STALE="$WORK/stale-home"
mkdir -p "$STALE"
out7="$(cd "$ORPHAN" && env -i HOME="$HOME" TEMPERLOOP_HOME="$STALE" XDG_STATE_HOME="$XDG_STATE_HOME" PATH="$FAKEBIN2:/usr/bin:/bin" "$ORPHAN/.temperloop/report.d/tokens")" \
  || fail "7: shim invocation failed"
echo "$out7" | jq -e '.tokens_spent == 424242' >/dev/null \
  || fail "7: a stale \$TEMPERLOOP_HOME (missing the producer) should fall through to the PATH fallback (fake-kernel-2, tokens_spent=424242); got: $out7"
echo "PASS: 7 a stale/invalid \$TEMPERLOOP_HOME falls through to the 'command -v temperloop' fallback"

# --- 8: no kernel resolvable at all (orphan copy: no self-checkout, no
# $TEMPERLOOP_HOME, no PATH temperloop). --------------------------------------
out8rc=0
out8="$(cd "$ORPHAN" && env -i HOME="$HOME" XDG_STATE_HOME="$XDG_STATE_HOME" PATH="/usr/bin:/bin" "$ORPHAN/.temperloop/report.d/tokens")" || out8rc=$?
[ "$out8rc" -eq 0 ] || fail "8: shim with no kernel resolvable must still exit 0; got rc=$out8rc"
[ "$out8" = "skipped -- tokens: producer unavailable" ] || fail "8: shim with no kernel resolvable should print exactly the contract's skip line; got: $out8"
echo "PASS: 8 no kernel resolvable -> exactly the contract's skip line, exit 0"

# --- 9: STATIC — no transcript-parsing / jq-shaping code in the shim -------
# (comments mentioning "jq" or "tokens_spent" are fine and expected — this
# checks CODE lines only, same convention as
# workflows/scripts/tests/test_pipeline_spend_report.sh's egress checks.)
if grep -nE '\bjq\b' "$SHIM" | grep -vE '^[0-9]+:[[:space:]]*#' | grep . >/dev/null; then
  fail "9: the shim contains a non-comment 'jq' reference -- transcript/JSON shaping belongs kernel-side only"
fi
echo "PASS: 9a shim has no non-comment jq reference"

if grep -nE 'select\(|with_entries|by_model' "$SHIM" | grep -vE '^[0-9]+:[[:space:]]*#' | grep . >/dev/null; then
  fail "9: the shim contains jq-shaping-looking code (select/with_entries/by_model) outside comments"
fi
echo "PASS: 9b shim has no jq-shaping code outside comments"

# --- 10: STATIC — no fourth hardcoded install-path literal ------------------
if grep -qF '.local/share/temperloop' "$SHIM"; then
  fail "10: the shim hardcodes the TEMPERLOOP_HOME default install-path literal -- bin/bootstrap.sh's header names the three existing hand-synced copies; this shim must not add a fourth (rely on 'command -v temperloop' instead)"
fi
echo "PASS: 10 shim does not hardcode a fourth copy of the install-path literal"

# --- 11: ARGS PASSTHROUGH ----------------------------------------------------
# Static: the exec line forwards "$@" (a non-comment occurrence).
if ! grep -nE '^[^#]*exec .*"\$@"' "$SHIM" | grep . >/dev/null; then
  fail "11: the shim's exec line does not forward \"\$@\" -- args passthrough regressed"
fi
echo "PASS: 11a shim's exec line forwards \"\$@\""

# Dynamic: an extra CLI arg (the contract is "invoked with no arguments"
# today, so this just proves passthrough doesn't break resolution -- the
# kernel-side implementation takes no flags and silently ignores it).
out11="$(env -i HOME="$HOME" SPEND_TRANSCRIPT_ROOT="$SPEND_TRANSCRIPT_ROOT" XDG_STATE_HOME="$XDG_STATE_HOME" PATH="/usr/bin:/bin" "$SHIM" --an-arg-nobody-asked-for)" \
  || fail "11: shim invocation with an extra arg failed"
[ "$out11" = "$control_out" ] || fail "11: shim invoked with an extra arg should still match the control output; got: $out11"
echo "PASS: 11b shim invoked with an extra arg still resolves and matches the control output"

# --- 12-18: first-run disclosure notice + per-person local disable
# (temperloop#986) ------------------------------------------------------------
# Each test below runs the kernel-side IMPL directly (not the shim -- the
# notice/disable logic lives entirely kernel-side) under its OWN freshly
# isolated $XDG_STATE_HOME and/or $HOME, so tests never see each other's
# markers and never touch the real machine's own state dir.

NOTICE_WORK="$(mktemp -d "${TMPDIR:-/tmp}/tokens-producer-notice-test-XXXXXX")"
# Defensive pre-clean (test 17 below writes, however briefly, inside
# $REPO_ROOT itself to prove it does NOT stay there -- a prior interrupted
# run of this suite could in principle have left residue; never trust prior
# state on disk before asserting about it).
rm -rf "$REPO_ROOT/.local" 2>/dev/null
notice_cleanup() { rm -rf "$NOTICE_WORK"; rm -rf "$REPO_ROOT/.local" 2>/dev/null; }
trap 'cleanup; notice_cleanup' EXIT

# Whole-repo BEFORE snapshot (widens test 15 below past a narrower prior cut
# scoped only to .temperloop/ -- see that test for why the narrower scope
# was a real gap). Taken now, before tests 12-14 run, so the AFTER snapshot
# at test 15 isolates exactly what THOSE THREE runs did to the tree, not
# this worker's own in-progress source edits (which are already reflected
# on both sides of the diff either way, since neither snapshot happens
# to straddle an edit to this file).
pre_repo_status="$(cd "$REPO_ROOT" && git status --porcelain 2>/dev/null)" || pre_repo_status=""

# --- 12: FIRST RUN ------------------------------------------------------------
XDG12="$NOTICE_WORK/xdg-12"
first_out="$(env -i HOME="$HOME" SPEND_TRANSCRIPT_ROOT="$SPEND_TRANSCRIPT_ROOT" XDG_STATE_HOME="$XDG12" PATH="/usr/bin:/bin" "$IMPL")" \
  || fail "12: first run of the kernel-side implementation failed"
echo "$first_out" | jq -e 'type == "object" and (.tokens_spent | type) == "number"' >/dev/null \
  || fail "12: first run's stdout did not still parse as {tokens_spent: <number>} -- notice: $(echo "$first_out" | jq -r '.notice // empty')"
first_notice="$(echo "$first_out" | jq -r '.notice // empty')"
[ -n "$first_notice" ] || fail "12: first run produced no notice field at all"
case "$first_notice" in
  *'SPEND_TRANSCRIPT_ROOT'*) : ;;
  *) fail "12: first-run notice does not name what is read (\$SPEND_TRANSCRIPT_ROOT); got: $first_notice" ;;
esac
case "$first_notice" in
  *'no network call'*|*'NO network call'*) : ;;
  *) fail "12: first-run notice does not state there is no network call; got: $first_notice" ;;
esac
case "$first_notice" in
  *'disable'*) : ;;
  *) fail "12: first-run notice does not name how to disable locally; got: $first_notice" ;;
esac
echo "PASS: 12 first run emits a notice naming what is read, no network call, and how to disable -- and the tokens headline still renders"

# --- 13: SECOND RUN (same $XDG_STATE_HOME) ------------------------------------
second_out="$(env -i HOME="$HOME" SPEND_TRANSCRIPT_ROOT="$SPEND_TRANSCRIPT_ROOT" XDG_STATE_HOME="$XDG12" PATH="/usr/bin:/bin" "$IMPL")" \
  || fail "13: second run of the kernel-side implementation failed"
echo "$second_out" | jq -e 'type == "object" and (.tokens_spent | type) == "number"' >/dev/null \
  || fail "13: second run's stdout did not parse as {tokens_spent: <number>}"
second_notice="$(echo "$second_out" | jq -r '.notice // empty')"
case "$second_notice" in
  *'disable'*) fail "13: second run still emitted the first-run disclosure (mentions 'disable'); got: $second_notice" ;;
esac
[ "$second_notice" != "$first_notice" ] || fail "13: second run's notice should differ from the first run's (disclosure prefix should be gone); got identical: $second_notice"
echo "PASS: 13 second run prints no first-run disclosure, tokens headline still renders"

# --- 14: DISABLED --------------------------------------------------------------
XDG14="$NOTICE_WORK/xdg-14"
mkdir -p "$XDG14/temperloop/tokens-producer"
: > "$XDG14/temperloop/tokens-producer/disabled"
disabled_rc=0
disabled_out="$(env -i HOME="$HOME" SPEND_TRANSCRIPT_ROOT="$SPEND_TRANSCRIPT_ROOT" XDG_STATE_HOME="$XDG14" PATH="/usr/bin:/bin" "$IMPL")" || disabled_rc=$?
[ "$disabled_rc" -eq 0 ] || fail "14: a disabled producer must still exit 0; got rc=$disabled_rc"
[ "$disabled_out" = "skipped -- tokens: producer unavailable" ] || fail "14: a disabled producer should print exactly the contract's skip line; got: $disabled_out"
echo "PASS: 14 the disable marker suppresses the producer entirely (contract skip line, exit 0)"

# --- 15: STATE PATH + no repo-tracked residue ---------------------------------
[ -f "$XDG12/temperloop/tokens-producer/first-run-notice-shown" ] \
  || fail "15: the 'already shown' marker did not land at \$XDG_STATE_HOME/temperloop/tokens-producer/first-run-notice-shown"
[ -f "$XDG14/temperloop/tokens-producer/disabled" ] \
  || fail "15: the disable marker was not found where test 14 wrote it (sanity check on the fixture itself)"
# WHOLE-REPO delta, not scoped to .temperloop/ (review round 2, item 7): a
# prior cut of this test scoped its check to `git status --porcelain --
# .temperloop`, which is exactly narrow enough to have MISSED BLOCKING 1 (a
# relative $XDG_STATE_HOME writing a stray `.local/` dir at the repo root --
# outside .temperloop/, so invisible to that pathspec). Comparing the WHOLE
# repo's status before (captured above, before test 12 ran anything) against
# after (here) catches ANY new path the producer created ANYWHERE in the
# tree, while still not false-positiving on this worker's own in-progress
# source edits -- those are present on BOTH sides of the diff (before tests
# 12-14 ran and after), so they cancel out; only a delta introduced BY tests
# 12-14 themselves fails this check.
#
# IT READS GLOBAL STATE, AND SINCE temperloop#2162 IT HAS CONCURRENT NEIGHBOURS.
# The whole-repo delta is the only probe wide enough to catch BLOCKING 1 (see
# above), but the working tree is SHARED: #2162 split `make test-build` and
# `make test-cli-subcommands` into ~73 per-script gates the pool now runs
# CONCURRENTLY, so a SIBLING gate writing a transient file anywhere in the
# checkout lands in this delta too. Not hypothetical — it fired at 32-way
# concurrency on `workflows/scripts/build/tests/.review-wait-early.<pid>`, and
# the fix was to move THAT test's scratch out of the tree, because a test
# writing into a git-tracked directory is the real defect. Keeping this probe
# wide is right; what it owes the reader is honest ATTRIBUTION, so the message
# below points at the other suspect instead of asserting the producer did it.
post_repo_status="$(cd "$REPO_ROOT" && git status --porcelain 2>/dev/null)" || post_repo_status=""
[ "$pre_repo_status" = "$post_repo_status" ] || fail "15: the repo tree changed after tests 12-14 (whole-repo status delta, not just .temperloop/) -- state must never leak into a repo-tracked path.
  If the added entry is NOT one this producer could have written, check whether a
  CONCURRENTLY-RUNNING gate wrote it: since temperloop#2162 the former test-build /
  test-cli-subcommands umbrellas are ~73 pooled per-script gates sharing this one
  working tree, and a sibling's scratch file belongs in a mktemp dir, not here.
  before:
$pre_repo_status
  after:
$post_repo_status"
echo "PASS: 15 both markers live only under the isolated \$XDG_STATE_HOME, never in the repo tree (whole-repo status delta, not just .temperloop/)"

# --- 16: STATIC — notice text sources ------------------------------------------
# Comment-filtered (the convention tests 9a/9b already use): a bare `grep`
# here would pass even with the disclosure feature entirely deleted, since
# this file's OWN header/inline comments already discuss "no network call"
# and "$SPEND_TRANSCRIPT_ROOT" at length for unrelated reasons (review round
# 2, item 6 -- confirmed tautological: deleting the whole first_run_notice=
# line left 2 and 12 matches respectively). Filtering comment-only lines
# makes this an actual check on the disclosure CODE, covering what test 12's
# dynamic check does not: that the wording lives in the shipped source, not
# just in whatever this one test run happened to produce.
#
# The comment-filtered source is captured ONCE into a variable and matched
# with `case`, NOT re-derived per check as `grep -vE ... | grep -q ...`
# (temperloop#1168). Under this file's `set -uo pipefail`, that pipeline is a
# SIGPIPE race: `grep -q` exits the instant it matches -- for the
# SPEND_TRANSCRIPT_ROOT pattern that is within the first few hundred bytes of
# a ~37KB producer -- which closes the pipe while the upstream `grep -vE` is
# still writing. GNU grep (every Linux CI runner) then reports `grep: write
# error: Broken pipe` and exits 2; `pipefail` promotes that to the pipeline's
# status, `!` inverts it, and the check fails a green tree. BSD grep on macOS
# usually wins the race, which is why this reproduced only in consumer CI.
# `case` on a captured string has no pipe and no race, and matches the
# in-file convention test 12 already uses.
impl_noncomment="$(grep -vE '^[[:space:]]*#' "$IMPL")"
case "$impl_noncomment" in
  *'no network call'*|*'NO network call'*) : ;;
  *) fail "16: the kernel-side implementation's non-comment source has no 'no network call' disclosure text" ;;
esac
case "$impl_noncomment" in
  *SPEND_TRANSCRIPT_ROOT*) : ;;
  *) fail "16: the kernel-side implementation's non-comment source does not reference \$SPEND_TRANSCRIPT_ROOT in its disclosure text" ;;
esac
echo "PASS: 16 kernel-side implementation's non-comment source carries the disclosure wording"

# --- 17: BLOCKING 1 REGRESSION — a RELATIVE $XDG_STATE_HOME must not write
# producer state inside the repo working tree --------------------------------
# report.sh runs every report.d producer with cwd = the TARGET repo's own
# root (report.contract.md's Overlay drop-in contract), so this test
# reproduces that exactly: cwd = $REPO_ROOT, $XDG_STATE_HOME set to a
# RELATIVE value -- the precise repro from review round 2 (`XDG_STATE_HOME=
# ".local/state"`). Per the XDG Base Directory spec a relative value is
# invalid and MUST be ignored; the pre-fix code only guarded unset/empty,
# so this would previously create `.local/state/...` inside $REPO_ROOT
# itself the instant `report` ran there with such a value set. $HOME here is
# its OWN isolated dir (never the real machine's $HOME) so the correct
# fallback path is also verifiable without touching real machine state.
HOME17="$NOTICE_WORK/home-17"
mkdir -p "$HOME17"
REL_XDG_17=".local/state"
out17rc=0
out17="$(cd "$REPO_ROOT" && env -i HOME="$HOME17" SPEND_TRANSCRIPT_ROOT="$SPEND_TRANSCRIPT_ROOT" XDG_STATE_HOME="$REL_XDG_17" PATH="/usr/bin:/bin" "$IMPL")" || out17rc=$?
if [ "$out17rc" -ne 0 ]; then
  rm -rf "$REPO_ROOT/.local" 2>/dev/null
  fail "17: a relative \$XDG_STATE_HOME run (cwd=\$REPO_ROOT) exited non-zero (rc=$out17rc)"
fi
echo "$out17" | jq -e 'type == "object" and (.tokens_spent | type) == "number"' >/dev/null || {
  rm -rf "$REPO_ROOT/.local" 2>/dev/null
  fail "17: a relative \$XDG_STATE_HOME run's stdout did not parse as {tokens_spent: <number>}; got: $out17"
}
if [ -e "$REPO_ROOT/.local" ]; then
  rm -rf "$REPO_ROOT/.local" 2>/dev/null
  fail "17: a RELATIVE \$XDG_STATE_HOME (\"$REL_XDG_17\") wrote producer state INSIDE the repo working tree at $REPO_ROOT/.local -- the XDG Base Directory spec requires a relative value be ignored (BLOCKING 1 regression)"
fi
[ -e "$HOME17/.local/state/temperloop/tokens-producer" ] \
  || fail "17: with a relative \$XDG_STATE_HOME ignored, this run should have fallen back to \$HOME/.local/state and created state there -- found nothing at $HOME17/.local/state/temperloop/tokens-producer, so the fallback itself may be broken (not just under-tested)"
echo "PASS: 17 a relative \$XDG_STATE_HOME does not write producer state inside the repo working tree; it falls back to \$HOME/.local/state per the XDG spec"

# --- 18: BLOCKING 2 REGRESSION — the printed disable command must survive an
# apostrophe AND a space in the resolved path, and must genuinely disable the
# producer when pasted -------------------------------------------------------
# A real, observed path shape (an apostrophe in a surname, a space in "o'brien
# dev") is exactly what broke the pre-fix version: interpolating the
# RESOLVED path into single quotes let the apostrophe close the quote early,
# so the pasted command exited 0 while doing something other than what it
# claimed -- the producer stayed enabled with no error the operator could
# see. This test extracts the EXACT command this producer prints, evaluates
# it verbatim (as a human copy-pasting the notice text would), and confirms
# the round trip: the marker lands where the producer actually checks, and
# the NEXT run is genuinely suppressed.
APOS_HOME="$NOTICE_WORK/o'brien dev"
mkdir -p "$APOS_HOME"
out18="$(env -i HOME="$APOS_HOME" SPEND_TRANSCRIPT_ROOT="$SPEND_TRANSCRIPT_ROOT" PATH="/usr/bin:/bin" "$IMPL")" \
  || fail "18: first run under an apostrophe+space \$HOME failed"
notice18="$(echo "$out18" | jq -r '.notice // empty')"
case "$notice18" in
  *'disable'*) : ;;
  *) fail "18: first-run notice under an apostrophe+space \$HOME carries no disable instructions; got: $notice18" ;;
esac
# Extract the literal command between "run: " and " (a per-machine" -- the
# exact substring a human would select and paste.
disable_cmd="$(printf '%s' "$notice18" | sed -n 's/.*run: \(.*\) (a per-machine marker file.*/\1/p')"
[ -n "$disable_cmd" ] || fail "18: could not extract the disable command from the notice text: $notice18"
# The extracted command must be the UNEXPANDED literal form -- $APOS_HOME's
# own text must NOT appear inside it. If it does, something was
# interpolated again and this regression test would itself be pointless
# (an interpolated apostrophe+space path pasted below would just fail
# differently, not prove the fix).
case "$disable_cmd" in
  *"$APOS_HOME"*) fail "18: the disable command has \$HOME interpolated into it (expected the literal, unexpanded \${XDG_STATE_HOME:-\$HOME/.local/state} form); got: $disable_cmd" ;;
esac
# Paste it: eval, verbatim, under the SAME apostrophe+space $HOME.
eval_rc=0
env -i HOME="$APOS_HOME" PATH="/usr/bin:/bin" bash -c "$disable_cmd" || eval_rc=$?
[ "$eval_rc" -eq 0 ] || fail "18: evaluating the printed disable command under an apostrophe+space \$HOME exited non-zero (rc=$eval_rc); command was: $disable_cmd"
[ -f "$APOS_HOME/.local/state/temperloop/tokens-producer/disabled" ] \
  || fail "18: evaluating the printed disable command did not create the marker at the path this producer actually checks (\$HOME/.local/state/temperloop/tokens-producer/disabled) -- it exited 0 but the disable silently did not take"
# ...and the very next run under that same $HOME must now be suppressed.
out18b="$(env -i HOME="$APOS_HOME" SPEND_TRANSCRIPT_ROOT="$SPEND_TRANSCRIPT_ROOT" PATH="/usr/bin:/bin" "$IMPL")" \
  || fail "18: the run after pasting the disable command failed outright"
[ "$out18b" = "skipped -- tokens: producer unavailable" ] \
  || fail "18: the producer should be disabled after pasting its own printed command, but ran anyway; got: $out18b"
echo "PASS: 18 the printed disable command survives an apostrophe+space path and genuinely disables the producer end to end when pasted"

echo "ALL PASS: test_tokens_producer.sh"
