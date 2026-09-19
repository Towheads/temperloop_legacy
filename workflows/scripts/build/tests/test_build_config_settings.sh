#!/usr/bin/env bash
#
# Tests for workflows/scripts/build/build-config-settings.sh — the SSOT-derived
# setting-name list build-level.mjs's 3e.5 gate `unset`s to run hermetically
# (temperloop#1241, export arm temperloop#1709).
#
# Covers: helper prints names · includes known VALUE settings · EXCLUDES the two
# config-file resolvers (BUILD_CONFIG_MACHINE/LOCAL, #1055's domain) · list ==
# the UNION of build.config.sh's own decls and its top-level exports, minus those
# two (SSOT coverage) · the union is a SUPERSET of the decl-only set it replaced
# (no name regressed) · the CLASS property that an export-only name is covered ·
# a FIXTURE proving the export parser follows multi-line `\` continuations (the
# exact shape that hid #1709 — a bare name alone on a continuation line) · the
# load-bearing behavior: after `unset $(helper)` a tracked default wins over an
# exported setting — WITH a negative control proving the assertion is real (env
# wins without the scrub). Zero network.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$HERE/../build-config-settings.sh"
CONFIG="$HERE/../build.config.sh"

pass=0
fail=0
ok()  { echo "  ok    $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1: $2"; fail=$((fail + 1)); }

names="$(bash "$HELPER")"

# Reference parses of build.config.sh, used by several assertions below.
# decls: the `: "${NAME:=...}"` shape (what the helper emitted before #1709).
decls="$(sed -nE 's/^: "\$\{([A-Z_][A-Z0-9_]*):=.*/\1/p' "$CONFIG" \
           | grep -vxE 'BUILD_CONFIG_MACHINE|BUILD_CONFIG_LOCAL' | sort -u)"
# exports: names in top-level `export` statements, continuations followed.
# Deliberately a DIFFERENT implementation from the helper's awk parser (a pure
# bash reader) so the two can disagree — an oracle, not a copy of the code under
# test.
exports="$(
  in_export=0
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$in_export" -eq 0 ]; then
      case "$line" in
        "export "*|"export	"*) in_export=1; line="${line#export}" ;;
        *) continue ;;
      esac
    fi
    case "$line" in
      *\\) cont=1; line="${line%\\}" ;;
      *) cont=0 ;;
    esac
    for tok in $line; do
      tok="${tok%%=*}"
      printf '%s\n' "$tok"
    done
    in_export=$cont
  done < "$CONFIG" \
    | grep -xE '[A-Z_][A-Z0-9_]*' \
    | grep -vxE 'BUILD_CONFIG_MACHINE|BUILD_CONFIG_LOCAL' | sort -u
)"
union="$(printf '%s\n%s\n' "$decls" "$exports" | sort -u)"
got="$(printf '%s\n' "$names" | sort -u)"

# 1. Prints a non-empty list.
if [ -n "$names" ]; then ok "helper prints setting names"; else bad "helper prints setting names" "empty output"; fi

# 2. Includes representative VALUE settings from each family the pipeline exports.
for k in BUILD_MERGE_GATE_WINDOW TIDY_SYNC_WAIT ASSESS_POLL_CADENCE PIPELINE_OPERATOR EPIC_MIN_SUBUNITS; do
  if grep -qxF "$k" <<<"$names"; then ok "includes $k"; else bad "includes $k" "absent from list"; fi
done

# 3. EXCLUDES the two config-file resolvers (structurally distinct; #1055).
for k in BUILD_CONFIG_MACHINE BUILD_CONFIG_LOCAL; do
  if grep -qxF "$k" <<<"$names"; then bad "excludes $k" "leaked into scrub list"; else ok "excludes $k"; fi
done

# 4. SSOT coverage: helper list == decls UNION top-level exports, minus the two
#    exclusions. Guards against either parser arm drifting from the file.
if [ "$union" = "$got" ]; then ok "list matches decls + exports union (SSOT)"; else
  bad "list matches decls + exports union (SSOT)" "diff: $(diff <(echo "$union") <(echo "$got") | tr '\n' ' ')"; fi

# 5. NO REGRESSION: the union is a superset of the decl-only set the helper
#    emitted before #1709, and at least as large. Every name previously scrubbed
#    is still scrubbed.
dropped="$(comm -23 <(echo "$decls") <(echo "$got") | tr '\n' ' ')"
if [ -z "${dropped// /}" ]; then ok "every previously-emitted (decl) name is still emitted"; else
  bad "every previously-emitted (decl) name is still emitted" "dropped: $dropped"; fi
n_decls="$(printf '%s\n' "$decls" | grep -c . || true)"
n_got="$(printf '%s\n' "$got" | grep -c . || true)"
if [ "$n_got" -ge "$n_decls" ]; then ok "emitted count $n_got >= decl-only count $n_decls"; else
  bad "emitted count >= decl-only count" "got $n_got < $n_decls"; fi

# 6. THE CLASS PROPERTY (#1709), asserted against the REAL build.config.sh, not a
#    fixture: every name build.config.sh EXPORTS but does not DECLARE appears in
#    the helper's output. Stated generically — no setting name is hardcoded, so a
#    future export-only setting is covered by this same assertion.
export_only="$(comm -23 <(echo "$exports") <(echo "$decls"))"
if [ -z "$export_only" ]; then
  ok "class: export-only names covered (build.config.sh currently has none)"
else
  missing="$(comm -23 <(echo "$export_only") <(echo "$got") | tr '\n' ' ')"
  if [ -z "${missing// /}" ]; then
    ok "class: all $(printf '%s\n' "$export_only" | grep -c . || true) export-only name(s) are covered"
  else
    bad "class: all export-only names are covered" "escaped the scrub list: $missing"
  fi
fi

# 7. FIXTURE — the multi-line continuation shape. A single-line-only parser would
#    pass a naive test on a one-line export list while still missing the live bug
#    (#1709's name sits ALONE on a `\`-continued line). The helper resolves its
#    config as the SIBLING of its own path, so a copy of the script beside a
#    fixture config reads the fixture.
fixture_dir="$(mktemp -d)"
empty="$(mktemp)"
trap 'rm -rf "$fixture_dir"; rm -f "$empty"' EXIT
cp "$HELPER" "$fixture_dir/build-config-settings.sh"
cat > "$fixture_dir/build.config.sh" <<'FIXTURE'
#!/usr/bin/env bash
# Fixture config — exercises every shape the parser must handle.
: "${FIX_DECLARED_AND_EXPORTED:=1}"
: "${FIX_DECLARED_ONLY:=2}"

not_top_level() {
  export FIX_NESTED_EXPORT=3
}

export FIX_DECLARED_AND_EXPORTED FIX_EXPORT_ONLY_SAME_LINE \
       FIX_EXPORT_ONLY_CONTINUED_ALONE \
       FIX_EXPORT_ONLY_A FIX_EXPORT_ONLY_B
export FIX_EXPORT_WITH_VALUE=4
FIXTURE
fixture_names="$(bash "$fixture_dir/build-config-settings.sh" | sort -u)"

for k in FIX_DECLARED_AND_EXPORTED FIX_DECLARED_ONLY FIX_EXPORT_ONLY_SAME_LINE \
         FIX_EXPORT_ONLY_CONTINUED_ALONE FIX_EXPORT_ONLY_A FIX_EXPORT_ONLY_B \
         FIX_EXPORT_WITH_VALUE; do
  if grep -qxF "$k" <<<"$fixture_names"; then ok "fixture: covers $k"; else
    bad "fixture: covers $k" "absent — parser missed this shape"; fi
done
# The continuation arm must not swallow a nested (indented) export: those are
# function-local, not settings, and the decl parser is anchored at column 0 too.
if grep -qxF FIX_NESTED_EXPORT <<<"$fixture_names"; then
  bad "fixture: ignores a nested (indented) export" "FIX_NESTED_EXPORT leaked in"
else ok "fixture: ignores a nested (indented) export"; fi
# Output contract: deduplicated and sorted.
if [ "$fixture_names" = "$(bash "$fixture_dir/build-config-settings.sh")" ]; then
  ok "fixture: output is sorted and deduplicated"; else
  bad "fixture: output is sorted and deduplicated" "raw output differs from sort -u"; fi

# 8. Behavior — hermeticity. Isolate from any host machine/local config file so
#    the ONLY variable under test is the env-setting scrub.

# 8a. Negative control: WITHOUT the scrub, an exported setting wins the env layer.
ctrl="$(
  export BUILD_CONFIG_MACHINE="$empty" BUILD_CONFIG_LOCAL="$empty"
  export BUILD_MERGE_GATE_WINDOW=99999
  # shellcheck disable=SC1090
  source "$CONFIG"
  echo "$BUILD_MERGE_GATE_WINDOW"
)"
if [ "$ctrl" = "99999" ]; then ok "negative control: exported setting wins without scrub"; else
  bad "negative control: exported setting wins without scrub" "got '$ctrl' (expected 99999 — test would be vacuous)"; fi

# 8b. WITH the scrub, the tracked default (300) wins — the gate is hermetic.
scrubbed="$(
  export BUILD_CONFIG_MACHINE="$empty" BUILD_CONFIG_LOCAL="$empty"
  export BUILD_MERGE_GATE_WINDOW=99999
  # temperloop#2142: non-empty arg list (`-v __tbcs_noop`) + decoupled status
  # (`|| :`). A zero-argument `unset` errors in zsh, and ANY non-zero `unset`
  # trips this file's `set -e`; the scrub is best-effort hygiene either way.
  # shellcheck disable=SC2046  # intentional word-split: unset the whole setting set
  unset -v __tbcs_noop $(bash "$HELPER") || :
  # shellcheck disable=SC1090
  source "$CONFIG"
  echo "$BUILD_MERGE_GATE_WINDOW"
)"
if [ "$scrubbed" = "300" ]; then ok "scrub yields tracked default (hermetic gate)"; else
  bad "scrub yields tracked default (hermetic gate)" "got '$scrubbed' (expected 300)"; fi

# 8c. THE #1709 BEHAVIOR, generically: after the scrub, NO name build.config.sh
#     exports survives into the environment the gate's child process inherits —
#     including the export-only ones. Every exported name is pre-set to a
#     sentinel, so a survivor is reported by name rather than inferred.
survivors="$(
  export BUILD_CONFIG_MACHINE="$empty" BUILD_CONFIG_LOCAL="$empty"
  while IFS= read -r n; do [ -n "$n" ] && export "$n=SENTINEL_1709"; done <<<"$exports"
  # shellcheck disable=SC1090
  source "$CONFIG"
  # shellcheck disable=SC2046  # intentional word-split: unset the whole setting set (temperloop#2142 form)
  unset -v __tbcs_noop $(bash "$HELPER") || :
  env | grep -F '=SENTINEL_1709' | cut -d= -f1 | sort || true
)"
if [ -z "$survivors" ]; then ok "no exported setting survives the scrub"; else
  bad "no exported setting survives the scrub" "survived: $(echo "$survivors" | tr '\n' ' ')"; fi

echo ""
echo "build-config-settings: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
