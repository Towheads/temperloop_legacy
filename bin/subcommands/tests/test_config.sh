#!/usr/bin/env bash
#
# Tests for config.sh — `temperloop config list` (temperloop#262, item
# configure-config-cli — ADR K164 D7). Exercises the PINNED clean-subshell
# layer-probe mechanism (config.sh's own header comment) against the REAL
# kernel registry (workflows/scripts/config/setting-registry.tsv) and the
# REAL build.config.sh — deliberately, not a synthetic fixture registry:
# the point of `config list` is to reflect THIS repo's actual precedence
# resolution, so testing against real rows also catches real drift.
#
# Covers:
#   - an exported env var wins (layer "env"), value reflects the export
#   - a machine-conf file (XDG_CONFIG_HOME fixture) setting a var wins
#     over its tracked-repo default (layer "machine-conf")
#   - a repo-local file (BUILD_CONFIG_LOCAL fixture) setting a var wins
#     over its tracked-repo default (layer "repo-local")
#   - an untouched tracked-repo-layer setting resolves to build.config.sh's
#     own default, layer "tracked-repo"
#   - an untouched kernel-layer setting (owned by a script OTHER than
#     build.config.sh) resolves to the registry default, layer "kernel"
#   - --format text prints the layer-1 "n/a at list-time" note once
#   - --format tsv header row is exact
#   - unknown subcommand / no args -> exit 2; -h/--help -> exit 0
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$HERE/../config.sh"

fail() { printf 'FAIL: %b\n' "$1" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/config-test-XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# tsv_field <tsv-output> <name> <field#> (1=name 2=layer 3=value 4=owning 5=doc)
#
# Herestring input, NOT `printf | awk`: awk's early `exit` closes the pipe
# while the writer may still be flushing, so under this suite's
# `set -o pipefail` a pipeline here can report SIGPIPE (rc 141) on a
# perfectly good match — a scheduling race that fires readily on Linux CI
# runners and almost never on macOS (the temperloop#262 CI-only failure).
# A herestring has no writer process to kill, so it is race-free.
tsv_field() {
  awk -F'\t' -v n="$2" -v f="$3" '$1==n{print $f; exit}' <<<"$1"
}

# =============================================================================
# 1. env layer: an exported var wins, value reflects the export.
# =============================================================================
out="$(env -u XDG_CONFIG_HOME -u BUILD_CONFIG_MACHINE -u BUILD_CONFIG_LOCAL \
  BUILD_QUOTA_PAUSE_PCT=77 bash "$CONFIG" list --format tsv)"
[ "$(tsv_field "$out" BUILD_QUOTA_PAUSE_PCT 2)" = "env" ] \
  || fail "env-set BUILD_QUOTA_PAUSE_PCT did not report layer=env (got: $(tsv_field "$out" BUILD_QUOTA_PAUSE_PCT 2))"
[ "$(tsv_field "$out" BUILD_QUOTA_PAUSE_PCT 3)" = "77" ] \
  || fail "env-set BUILD_QUOTA_PAUSE_PCT did not report the exported value (got: $(tsv_field "$out" BUILD_QUOTA_PAUSE_PCT 3))"
echo "PASS: an exported env var wins (layer=env, correct value)"

# =============================================================================
# 2. machine-conf layer: a machine-conf file setting a var wins over its
#    tracked-repo default.
# =============================================================================
XDG="$WORK/xdg"
mkdir -p "$XDG/temperloop"
cat > "$XDG/temperloop/build.config.sh" <<'EOF'
: "${BUILD_MERGE_GATE_WINDOW:=999}"
export BUILD_MERGE_GATE_WINDOW
EOF
out="$(env -u BUILD_CONFIG_MACHINE -u BUILD_CONFIG_LOCAL XDG_CONFIG_HOME="$XDG" bash "$CONFIG" list --format tsv)"
[ "$(tsv_field "$out" BUILD_MERGE_GATE_WINDOW 2)" = "machine-conf" ] \
  || fail "machine-conf-set BUILD_MERGE_GATE_WINDOW did not report layer=machine-conf (got: $(tsv_field "$out" BUILD_MERGE_GATE_WINDOW 2))"
[ "$(tsv_field "$out" BUILD_MERGE_GATE_WINDOW 3)" = "999" ] \
  || fail "machine-conf-set BUILD_MERGE_GATE_WINDOW did not report the machine-conf value (got: $(tsv_field "$out" BUILD_MERGE_GATE_WINDOW 3))"
echo "PASS: a machine-conf file setting a var wins over its tracked-repo default (layer=machine-conf)"

# =============================================================================
# 3. repo-local layer: a BUILD_CONFIG_LOCAL fixture setting a var wins over
#    its tracked-repo default (and is itself outranked by machine-conf,
#    tested implicitly by using a DIFFERENT setting than test 2 above).
# =============================================================================
LOCAL_CONF="$WORK/build.config.local.sh"
cat > "$LOCAL_CONF" <<'EOF'
: "${TIDY_SYNC_WAIT:=555}"
export TIDY_SYNC_WAIT
EOF
out="$(env -u XDG_CONFIG_HOME -u BUILD_CONFIG_MACHINE BUILD_CONFIG_LOCAL="$LOCAL_CONF" bash "$CONFIG" list --format tsv)"
[ "$(tsv_field "$out" TIDY_SYNC_WAIT 2)" = "repo-local" ] \
  || fail "repo-local-set TIDY_SYNC_WAIT did not report layer=repo-local (got: $(tsv_field "$out" TIDY_SYNC_WAIT 2))"
[ "$(tsv_field "$out" TIDY_SYNC_WAIT 3)" = "555" ] \
  || fail "repo-local-set TIDY_SYNC_WAIT did not report the repo-local value (got: $(tsv_field "$out" TIDY_SYNC_WAIT 3))"
echo "PASS: a repo-local (BUILD_CONFIG_LOCAL) file setting a var wins over its tracked-repo default (layer=repo-local)"

# =============================================================================
# 4. untouched tracked-repo-layer setting -> build.config.sh's own default,
#    layer=tracked-repo.
# =============================================================================
out="$(env -u XDG_CONFIG_HOME -u BUILD_CONFIG_MACHINE -u BUILD_CONFIG_LOCAL bash "$CONFIG" list --format tsv)"
[ "$(tsv_field "$out" PIPELINE_DRIVE_CONCURRENCY 2)" = "tracked-repo" ] \
  || fail "untouched PIPELINE_DRIVE_CONCURRENCY did not report layer=tracked-repo (got: $(tsv_field "$out" PIPELINE_DRIVE_CONCURRENCY 2))"
[ "$(tsv_field "$out" PIPELINE_DRIVE_CONCURRENCY 3)" = "3" ] \
  || fail "untouched PIPELINE_DRIVE_CONCURRENCY did not report build.config.sh's default of 3 (got: $(tsv_field "$out" PIPELINE_DRIVE_CONCURRENCY 3))"
echo "PASS: an untouched tracked-repo-layer setting resolves to build.config.sh's own default (layer=tracked-repo)"

# =============================================================================
# 5. untouched kernel-layer setting (owned by a script other than
#    build.config.sh) -> registry default, layer=kernel.
# =============================================================================
[ "$(tsv_field "$out" BASELINE_SNAPSHOT_TIMEOUT 2)" = "kernel" ] \
  || fail "untouched BASELINE_SNAPSHOT_TIMEOUT did not report layer=kernel (got: $(tsv_field "$out" BASELINE_SNAPSHOT_TIMEOUT 2))"
[ "$(tsv_field "$out" BASELINE_SNAPSHOT_TIMEOUT 3)" = "20" ] \
  || fail "untouched BASELINE_SNAPSHOT_TIMEOUT did not report its registry default of 20 (got: $(tsv_field "$out" BASELINE_SNAPSHOT_TIMEOUT 3))"
echo "PASS: an untouched kernel-layer setting resolves to the registry default (layer=kernel)"

# =============================================================================
# 6. --format text prints the layer-1 n/a note + header once; --format tsv
#    header row is exact.
# =============================================================================
text_out="$(env -u XDG_CONFIG_HOME -u BUILD_CONFIG_MACHINE -u BUILD_CONFIG_LOCAL bash "$CONFIG" list)"
# Herestrings, not `echo "$text_out" | grep -q` / `printf | head -1`: -q and
# -1 stop reading at the first match/line, and under `set -euo pipefail` the
# still-writing left side then dies of SIGPIPE (rc 141), failing the pipeline
# — and, for the head-1 assignment, killing the whole suite — on a run whose
# output was CORRECT. This is the Linux-CI-only failure this suite shipped
# with (temperloop#262): the race all but never fires on macOS, so it looked
# platform-dependent. See tsv_field's comment above.
grep -q 'layer 1 .cli. is never resolved at list-time' <<<"$text_out" \
  || fail "text format did not print the layer-1 n/a note"
grep -q '^NAME' <<<"$text_out" || fail "text format did not print a NAME header"

tsv_header="$(head -1 <<<"$out")"
[ "$tsv_header" = "$(printf 'name\tlayer\tvalue\towning-script\tdoc')" ] \
  || fail "tsv header row is not exact (got: $tsv_header)"
echo "PASS: --format text prints the layer-1 n/a note; --format tsv header row is exact"

# =============================================================================
# 7. CLI usage errors.
# =============================================================================
set +e
bash "$CONFIG" >/dev/null 2>&1; rc=$?
set -e
[ "$rc" -eq 2 ] || fail "no args did not exit 2 (got: $rc)"

set +e
bash "$CONFIG" bogus >/dev/null 2>&1; rc=$?
set -e
[ "$rc" -eq 2 ] || fail "unknown subcommand did not exit 2 (got: $rc)"

set +e
bash "$CONFIG" -h >/dev/null 2>&1; rc=$?
set -e
[ "$rc" -eq 0 ] || fail "-h did not exit 0 (got: $rc)"

set +e
bash "$CONFIG" list --format bogus >/dev/null 2>&1; rc=$?
set -e
[ "$rc" -eq 2 ] || fail "invalid --format did not exit 2 (got: $rc)"
echo "PASS: CLI usage errors (no args / unknown subcommand / invalid --format exit 2; -h exits 0)"

# =============================================================================
# 8. an overlay row whose NAME is not a legal shell identifier is rejected
#    upstream by registry validation: `config list` refuses loudly (exit 1,
#    diagnostics naming the row and its source file) instead of silently
#    dropping the row and exiting 0 (temperloop#1825). Fixture uses the real
#    overlay basename an operator would author.
# =============================================================================
BADOV_DIR="$WORK/badname-overlay"
mkdir -p "$BADOV_DIR"
printf 'SWEEP-FANOUT-WIDTH\t3\tint\tkernel\tscripts/a.sh\thyphenated name, illegal\tadd\n' \
  > "$BADOV_DIR/setting-registry.overlay.tsv"
set +e
badname_err="$(env -u XDG_CONFIG_HOME -u BUILD_CONFIG_MACHINE -u BUILD_CONFIG_LOCAL \
  SETTING_REGISTRY_OVERLAY_FILE="$BADOV_DIR/setting-registry.overlay.tsv" \
  bash "$CONFIG" list --format tsv 2>&1 >/dev/null)"; rc=$?
set -e
[ "$rc" -ne 0 ] || fail "an illegal-name overlay row did not make config list exit non-zero"
grep -q "not a legal shell identifier" <<<"$badname_err" \
  || fail "config list stderr did not carry the illegal-name diagnostic (got: $badname_err)"
grep -q "SWEEP-FANOUT-WIDTH" <<<"$badname_err" \
  || fail "config list stderr did not name the offending row (got: $badname_err)"
grep -q "setting-registry.overlay.tsv" <<<"$badname_err" \
  || fail "config list stderr did not name the offending source file (got: $badname_err)"
echo "PASS: an illegal-name overlay row is rejected upstream — config list exits non-zero and names the row + file"

# =============================================================================
# 9. A setting whose VALUE is arbitrary multi-line text (temperloop#2218).
#
#    CHANGELOG_GATE_PR_BODY is a real registry row that CI sets from the
#    pull_request payload's body, so this is not a synthetic input class: it
#    is untrusted, attacker-influenceable, multi-line, TAB-bearing text that
#    reaches `config list` on every PR run. `config list` used to feed it
#    into a TAB-delimited, one-record-per-line layer map unescaped, so its
#    own newlines opened fresh records and its own text supplied variable
#    NAMES. Every assertion below FAILS against the pre-fix script — that is
#    the point of them; see the PR's verification surface for the recorded
#    red-then-green run.
#
#    Note what is NOT asserted: that the output "looks right". The dropped
#    fix on PR #2217 passed a test that matched only the FIRST physical line
#    of a corrupt row. The assertions here pin (a) exact values of OTHER
#    settings, (b) a physical LINE COUNT, and (c) the absence of a side
#    effect — none of which a corrupt-but-plausible output can satisfy.
# =============================================================================
CLEAN_ENV=(env -u XDG_CONFIG_HOME -u BUILD_CONFIG_MACHINE -u BUILD_CONFIG_LOCAL -u CHANGELOG_GATE_PR_BODY)

# The honest row count: one physical line per registry row, plus the header.
baseline_out="$("${CLEAN_ENV[@]}" bash "$CONFIG" list --format tsv)"
baseline_lines="$(wc -l <<<"$baseline_out" | tr -d ' ')"

# --- 9a. A multi-line value must not fabricate a row for a REAL setting. ----
# The body embeds a line that is literally `IDENT<TAB>value` — the shape
# `config list --format tsv` output and setting-registry.tsv rows both have,
# which is exactly why temperloop PR bodies quoting either one trigger this.
ml_body=$'line one\nBUILD_QUOTA_PAUSE_PCT\t99\ntail'
set +e
ml_err="$("${CLEAN_ENV[@]}" CHANGELOG_GATE_PR_BODY="$ml_body" \
  bash "$CONFIG" list --format tsv 2>&1 >"$WORK/ml.tsv")"; rc=$?
set -e
ml_out="$(cat "$WORK/ml.tsv")"
[ "$rc" -eq 0 ] || fail "a multi-line env value made config list exit $rc (stderr: $ml_err)"
[ -z "$ml_err" ] || fail "a multi-line env value produced stderr: $ml_err"
[ "$(tsv_field "$ml_out" BUILD_QUOTA_PAUSE_PCT 2)" = "tracked-repo" ] \
  || fail "a multi-line env value fabricated BUILD_QUOTA_PAUSE_PCT's LAYER out of prose (got: $(tsv_field "$ml_out" BUILD_QUOTA_PAUSE_PCT 2), want tracked-repo)"
[ "$(tsv_field "$ml_out" BUILD_QUOTA_PAUSE_PCT 3)" = "10" ] \
  || fail "a multi-line env value fabricated BUILD_QUOTA_PAUSE_PCT's VALUE out of prose (got: $(tsv_field "$ml_out" BUILD_QUOTA_PAUSE_PCT 3), want 10)"
echo "PASS: a multi-line setting value produces no stderr and fabricates no row for a real setting"

# --- 9b. --format tsv: exactly one PHYSICAL line per row, multi-line or not.
ml_lines="$(wc -l <<<"$ml_out" | tr -d ' ')"
[ "$ml_lines" = "$baseline_lines" ] \
  || fail "--format tsv emitted $ml_lines physical lines with a multi-line env value, $baseline_lines without — the one-row-per-line contract is broken"
# And the row itself must be present, on ONE line, carrying the escaped text.
[ "$(tsv_field "$ml_out" CHANGELOG_GATE_PR_BODY 3)" = 'line one\nBUILD_QUOTA_PAUSE_PCT\t99\ntail' ] \
  || fail "the multi-line value was not emitted as one escaped field (got: $(tsv_field "$ml_out" CHANGELOG_GATE_PR_BODY 3))"
# A lone TAB in a value corrupts the name/value split on its own line, so it
# needs the same treatment as a newline and gets its own assertion.
tab_out="$("${CLEAN_ENV[@]}" CHANGELOG_GATE_PR_BODY=$'has\ta\ttab' bash "$CONFIG" list --format tsv 2>/dev/null)"
[ "$(wc -l <<<"$tab_out" | tr -d ' ')" = "$baseline_lines" ] \
  || fail "a TAB-bearing env value changed the physical line count"
[ "$(tsv_field "$tab_out" CHANGELOG_GATE_PR_BODY 3)" = 'has\ta\ttab' ] \
  || fail "a TAB-bearing env value was not escaped into one field (got: $(tsv_field "$tab_out" CHANGELOG_GATE_PR_BODY 3))"
echo "PASS: --format tsv emits exactly one physical line per registry row, including for multi-line and TAB-bearing values"

# --- 9c. Value text must never reach the NAME argument of `printf -v`. -----
# THIS IS A COMMAND-EXECUTION HAZARD, NOT A DIAGNOSTIC. Bash parses that name
# argument: a name of the form IDENT[...] makes the brackets an ARRAY
# SUBSCRIPT evaluated in ARITHMETIC context, which is an evaluating context
# that performs command substitution. Two separate assertions, because they
# fail differently against the unfixed script.
#
#   (i) the arithmetic-eval case aborts the run under `set -u`
#       (`checks: unbound variable`) — this is what turned CI red;
#  (ii) the command-substitution case exits 0 and runs the command, leaving
#       nothing in the output to notice. Only a SIDE EFFECT can catch it, so
#       this asserts on a marker file rather than on stdout.
subscript_body=$'body line\ncontexts["checks (ubuntu-latest)"]\tvalue'
set +e
sub_err="$("${CLEAN_ENV[@]}" CHANGELOG_GATE_PR_BODY="$subscript_body" \
  bash "$CONFIG" list --format tsv 2>&1 >"$WORK/sub.tsv")"; rc=$?
set -e
[ "$rc" -eq 0 ] \
  || fail "a value yielding a bracketed name aborted config list (rc=$rc, stderr: $sub_err) — value text reached printf -v's name argument"
[ -z "$sub_err" ] || fail "a value yielding a bracketed name produced stderr: $sub_err"
[ "$(wc -l <"$WORK/sub.tsv" | tr -d ' ')" = "$baseline_lines" ] \
  || fail "a value yielding a bracketed name truncated the listing"

MARKER="$WORK/cmdsub-marker"
rm -f "$MARKER"
# The \$( ) is escaped so THIS shell does not expand it; the whole question
# is whether config.sh does.
cmdsub_body="body line
evil[\$(touch '$MARKER')]	value"
set +e
"${CLEAN_ENV[@]}" CHANGELOG_GATE_PR_BODY="$cmdsub_body" \
  bash "$CONFIG" list --format tsv >/dev/null 2>&1; rc=$?
set -e
[ ! -e "$MARKER" ] \
  || fail "COMMAND EXECUTION: a command substitution embedded in a setting VALUE was evaluated by config list (marker file created)"
[ "$rc" -eq 0 ] || fail "the command-substitution probe made config list exit $rc"
echo "PASS: value text never reaches printf -v's name argument (no arithmetic eval, no command substitution)"

# --- 9d. The escaping is unambiguous, and lossless including trailing NLs. --
# A value holding the two literal characters backslash+n must NOT round-trip
# as a newline: it emits `\\n`. This is what distinguishes a real encoding
# from a one-way `${v//$'\n'/\\n}`.
amb_out="$("${CLEAN_ENV[@]}" CHANGELOG_GATE_PR_BODY='literal\nbackslash-n' bash "$CONFIG" list --format tsv 2>/dev/null)"
[ "$(tsv_field "$amb_out" CHANGELOG_GATE_PR_BODY 3)" = 'literal\\nbackslash-n' ] \
  || fail "a literal backslash-n in a value was not escaped unambiguously (got: $(tsv_field "$amb_out" CHANGELOG_GATE_PR_BODY 3))"

# Trailing newlines survive the `$( )` capture of a FILE layer's map — the
# acceptance-4 caveat, closed rather than documented. The value below is
# `a` followed by two newlines.
TRAIL_LOCAL="$WORK/trailing.local.sh"
printf '%s\n' 'BUILD_QUOTA_PAUSE_PCT=$'"'"'a\n\n'"'"'' > "$TRAIL_LOCAL"
trail_out="$(env -u XDG_CONFIG_HOME -u BUILD_CONFIG_MACHINE -u CHANGELOG_GATE_PR_BODY \
  BUILD_CONFIG_LOCAL="$TRAIL_LOCAL" bash "$CONFIG" list --format tsv 2>/dev/null)"
[ "$(tsv_field "$trail_out" BUILD_QUOTA_PAUSE_PCT 2)" = "repo-local" ] \
  || fail "the trailing-newline fixture did not win at layer repo-local (got: $(tsv_field "$trail_out" BUILD_QUOTA_PAUSE_PCT 2))"
[ "$(tsv_field "$trail_out" BUILD_QUOTA_PAUSE_PCT 3)" = 'a\n\n' ] \
  || fail "a file-layer value's TRAILING newlines were lost to the \$( ) capture (got: $(tsv_field "$trail_out" BUILD_QUOTA_PAUSE_PCT 3), want 'a\\n\\n')"
echo "PASS: the value encoding is unambiguous (a literal backslash-n is not decoded as a newline) and preserves trailing newlines"

# --- 9e. No collateral damage: an ordinary value is untouched by the escape.
[ "$(tsv_field "$baseline_out" PIPELINE_DRIVE_CONCURRENCY 3)" = "3" ] \
  || fail "the escaping changed an ordinary value"
echo "PASS: values with nothing to escape are unchanged"

echo
echo "ALL PASS: test_config.sh"
