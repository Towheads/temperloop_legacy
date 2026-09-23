#!/usr/bin/env bash
# description: config subcommands — `config list` prints resolved value + winning precedence layer per registry setting
#
# config.sh — `temperloop config <subcommand>` (temperloop#262, item
# configure-config-cli — ADR K164 D7). One subcommand today: `list`.
#
# WHY THIS EXISTS: the six-layer config precedence ladder
# (docs/config-precedence.md) means a setting's EFFECTIVE value is never just
# "the registry default" — it's whichever layer's file/env sets it first,
# highest layer wins. An operator staring at setting-registry.tsv has no way to
# see what actually WINS on their own machine/checkout without this.
#
# PINNED MECHANISM (design decision, temperloop#262 — do not redesign): the
# ladder itself deliberately tracks no winner (docs/config-precedence.md is
# a pure "highest-layer-wins by source order + `:=`" design with no runtime
# bookkeeping), and setting_registry_get returns only the static registry
# default. So `config list` RE-DERIVES value + winning layer per setting via
# CLEAN-SUBSHELL LAYER PROBES, cheapest layer first:
#   1. env    — is the setting's var already set in THIS process's real
#               environment (layer 2)? No subshell needed — that's just
#               "was it exported before this script ran".
#   2. machine-conf   — does SOURCING the machine-conf file
#               ($BUILD_CONFIG_MACHINE, i.e. the same
#               $XDG_CONFIG_HOME/temperloop/build.config.sh path
#               build.config.sh itself resolves at layer 3) set the var, in
#               a subshell that never touches this process's real state?
#   3. repo-local     — same probe against $BUILD_CONFIG_LOCAL (layer 4,
#               build.config.sh's untracked sibling).
#   4. tracked-repo   — same probe against build.config.sh itself (layer
#               5/6's one physical file in this repo). Reached only once
#               layers 1-3 have already been ruled out for this var, so
#               whatever build.config.sh's OWN sourcing pass resolves the
#               var to at this point is unambiguously ITS layer — even
#               though build.config.sh transparently re-sources the same
#               layer-3/4 files internally (see its own header), those
#               inner sources are provably no-ops here (layers 1-3 already
#               said "unset"), so nothing is double-counted.
#   5. else    — no file set it: use the registry row's own recorded
#               `default` field verbatim, and report ITS `layer` column as
#               the winning layer. The D2 registry↔shell equality lint
#               (registry-config-lints, a later item) is what makes this
#               trustworthy without sourcing every individual OWNING
#               SCRIPT (baseline-snapshot.sh, init.sh, ...) — the registry
#               default is guaranteed to equal that script's real literal.
#
# Layer 1 (CLI flag) is NEVER a candidate winner here — there is no live
# invocation context to inspect at list-time (a flag only exists inside
# some OTHER script's own arg parsing). This is reported once, in the
# output header, rather than per-row.
#
# PERFORMANCE NOTE: probes 2-4 each source ONE file (machine-conf,
# repo-local, tracked-repo) exactly ONCE TOTAL for the whole run — not once
# per setting — capturing every registry-known var's resulting value from
# that single source pass, then looking values up per-row out of that
# captured snapshot. Sourcing build.config.sh (a few hundred lines, pure
# `:=` assignments, no external commands beyond `dirname`/`pwd`/`hostname
# -s`) once is cheap; doing it ~150 times (once per registry row) would not
# be.
#
# Usage:
#   config.sh list [--format text|tsv]
#
#   list             Print every unioned registry row (kernel table +
#                    overlay extension when present — setting-registry-lib.sh)
#                    with its resolved value and winning layer.
#   --format text    Human-readable aligned columns (default).
#   --format tsv     Machine-parseable: name<TAB>layer<TAB>value<TAB>
#                    owning-script<TAB>doc, one row per line — same field
#                    order as the registry's own row shape, with `default`
#                    swapped for the resolved `value` and `layer` swapped
#                    for the resolved `layer`.
#
# Exit codes: 0 = printed successfully. 1 = broken kernel checkout (the
# registry lib or build.config.sh is missing). 2 = invalid CLI usage.
#
# Dependencies: bash (3.2+), awk, grep. No `jq`, no `gh`, no `claude` — this
# subcommand is pure local shell-state introspection, never a network call.
#
# NOTE on the CLI dispatcher's prereq gate: per-subcommand prereq scoping
# (temperloop#412) means `bin/temperloop`'s dispatcher checks a subcommand
# only against what its own `# prereqs: ...` header declares (see that
# script's own header) — this file declares none, so `temperloop config
# list` reaches this script with zero dispatcher-level claude/gh checks,
# matching what it actually needs (nothing). Testing still invokes this
# script directly, exactly like the existing eject.sh/init.sh/testbed.sh test
# suites already do — that stays the simplest path for a fixture that
# wants no CLI-dispatch machinery involved at all.
#
# shellcheck shell=bash

set -uo pipefail

SUBCOMMAND_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$(cd "$SUBCOMMAND_DIR/.." && pwd)"
KERNEL_ROOT="$(cd "$BIN_DIR/.." && pwd)"
REGISTRY_LIB="$KERNEL_ROOT/workflows/scripts/config/setting-registry-lib.sh"
TRACKED_REPO_FILE="$KERNEL_ROOT/workflows/scripts/build/build.config.sh"

if [ ! -f "$REGISTRY_LIB" ]; then
  echo "config.sh: setting-registry-lib.sh not found at $REGISTRY_LIB (broken kernel checkout)" >&2
  exit 1
fi
if [ ! -f "$TRACKED_REPO_FILE" ]; then
  echo "config.sh: build.config.sh not found at $TRACKED_REPO_FILE (broken kernel checkout)" >&2
  exit 1
fi
# shellcheck source=../../workflows/scripts/config/setting-registry-lib.sh
source "$REGISTRY_LIB"

usage() {
  cat <<'EOF'
usage: config.sh list [--format text|tsv]
EOF
}

if [ $# -eq 0 ]; then
  usage >&2
  exit 2
fi

sub="$1"
shift

case "$sub" in
  -h|--help)
    usage
    exit 0
    ;;
  list)
    ;;
  *)
    echo "config.sh: unknown subcommand '$sub'" >&2
    usage >&2
    exit 2
    ;;
esac

format="text"
while [ $# -gt 0 ]; do
  case "$1" in
    --format) format="${2:?--format needs a value}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "config.sh: unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done
case "$format" in
  text|tsv) ;;
  *)
    echo "config.sh: --format must be 'text' or 'tsv' (got: $format)" >&2
    exit 2
    ;;
esac

# ---------------------------------------------------------------------------
# Resolve the three FILE layers. Reuses the SAME override settings
# build.config.sh itself already honors (BUILD_CONFIG_MACHINE /
# BUILD_CONFIG_LOCAL, both already setting-registry.tsv rows) rather than
# inventing a new registry setting just for this subcommand's own path
# resolution — so a host/checkout override that already works for
# build.config.sh transparently works for `config list` too.
# ---------------------------------------------------------------------------
machine_conf_file="${BUILD_CONFIG_MACHINE:-${XDG_CONFIG_HOME:-$HOME/.config}/temperloop/build.config.sh}"
repo_local_file="${BUILD_CONFIG_LOCAL:-$(dirname "$TRACKED_REPO_FILE")/build.config.local.sh}"

# _config_list_bulk_source <file> <name...> -> ONE subshell source of
# <file> (silent no-op if absent/unreadable), then name<TAB>value for every
# given <name> that ended up SET after sourcing. One source call per
# candidate file for the WHOLE run (see header perf note), not one per
# setting.
_config_list_bulk_source() {
  local file="$1"
  shift
  [ -f "$file" ] || return 0
  (
    # shellcheck disable=SC1090
    source "$file" >/dev/null 2>&1 || true
    local n
    for n in "$@"; do
      if [ -n "${!n+x}" ]; then
        printf '%s\t%s\n' "$n" "${!n}"
      fi
    done
  )
}

# _config_list_index <prefix> <map> -> turn a name<TAB>value map into one
# `<prefix><name>` shell variable per entry, so the per-row probes below are
# O(1) hash lookups instead of a scan of the whole map.
#
# WHY AN INDEX AT ALL (temperloop#2163). The three maps are probed up to three
# times per registry row, and at 434 rows every probe that MISSES used to walk
# the entire map — first as a `read` line-loop, and no better as a `case`
# substring match, which bash evaluates character-by-character against a
# leading-`*` pattern. Either way it is O(rows x map-size) and measured at ~1s
# of `config list`'s runtime, a cost `test_config.sh` pays ten times over and
# `test_score_gate_env.sh` then pays twice more on top of that. Indexing once
# turns the whole walk into ~434 assignments.
#
# A registry name is a legal shell identifier by construction — the validation
# below is FATAL on a row whose name is not, precisely because the name-built
# assignment here, the `${!key}` read in _config_list_lookup and the
# bulk-source probe above all reject one. `printf -v` rather than `eval`: the
# value is passed as an argument instead of re-parsed as shell. Same
# `IFS=$'\t' read` split the map is written with. Bash-3.2-portable (printf -v
# is bash 3.1+): an index of plain variables, never an associative array.
_config_list_index() {
  local prefix="$1" map="$2" lname lval
  [ -n "$map" ] || return 0
  while IFS=$'\t' read -r lname lval; do
    [ -n "$lname" ] || continue
    printf -v "${prefix}${lname}" '%s' "$lval"
  done <<EOF
$map
EOF
}

# _config_list_lookup <prefix> <name> -> rc 0 if the <prefix>-indexed map holds
# <name>, setting global CFG_LOOKUP_VAL to its value; rc 1 if absent. Sets a
# global rather than printing so the per-row call sites below can invoke it
# directly instead of via a `$(…)` command substitution — that subshell fork,
# paid up to 3x per registry row, was part of what made `config list` slow
# (K305).
_config_list_lookup() {
  local key="$1$2"
  CFG_LOOKUP_VAL=""
  [ -n "${!key+x}" ] || return 1
  CFG_LOOKUP_VAL="${!key}"
  return 0
}

# Validate the registry BEFORE the union walk, and print the validator's
# diagnostics (they name each bad row and its source file) instead of
# swallowing them. Most malformations stay a best-effort warning — a row with
# e.g. an unknown type still lists fine — but a row whose NAME is not a legal
# shell identifier is FATAL: the `${!name}` indirect-expansion sites below
# (the bulk-source probe and the per-row env check) abort on such a name
# (bash "invalid variable name"), which is exactly how an illegal row used to
# be silently dropped while still exiting 0 (temperloop#1825). Reject it
# upstream, loudly, so those sites never see one. The diagnostic text matched
# here is the lib's own "not a legal shell identifier" message
# (setting-registry-lib.sh, _setting_registry_legal_name's callers).
val_out=""
if ! val_out="$(setting_registry_validate 2>&1)"; then
  printf '%s\n' "$val_out" >&2
  if grep -q 'is not a legal shell identifier' <<<"$val_out"; then
    echo "config.sh: the setting registry has row(s) whose name is not a legal shell identifier — refusing to list (fix the row(s) named above)" >&2
    exit 1
  fi
  echo "config.sh: warning — the setting registry reported malformed rows (details above) — continuing with a best-effort union" >&2
fi

rows="$(setting_registry_rows)"
all_names="$(printf '%s\n' "$rows" | awk -F'\t' 'NF>0{print $1}' | sort -u)"

# shellcheck disable=SC2086  # intentional word-split: a space-separated name list
machine_conf_map="$(_config_list_bulk_source "$machine_conf_file" $all_names)"
_config_list_index CFG_MC_ "$machine_conf_map"
# shellcheck disable=SC2086
repo_local_map="$(_config_list_bulk_source "$repo_local_file" $all_names)"
_config_list_index CFG_RL_ "$repo_local_map"
# shellcheck disable=SC2086
tracked_repo_map="$(_config_list_bulk_source "$TRACKED_REPO_FILE" $all_names)"
_config_list_index CFG_TR_ "$tracked_repo_map"

if [ "$format" = "tsv" ]; then
  printf 'name\tlayer\tvalue\towning-script\tdoc\n'
else
  echo "temperloop config list — resolved value + winning precedence layer per setting"
  echo "(layer 1 \"cli\" is never resolved at list-time — always reported n/a here;"
  echo " see docs/config-precedence.md for the full six-layer ladder)"
  echo
  printf '%-42s %-13s %-30s %s\n' "NAME" "LAYER" "VALUE" "OWNING-SCRIPT"
fi

while IFS= read -r row; do
  [ -n "$row" ] || continue
  _setting_split_row "$row"   # fork-free field split (lib helper); K305
  name="$KR_F1"
  default="$KR_F2"
  reg_layer="$KR_F4"
  owning="$KR_F5"
  doc="$KR_F6"

  value="" layer=""
  if [ -n "${!name+x}" ]; then
    value="${!name}"
    layer="env"
  elif _config_list_lookup CFG_MC_ "$name"; then
    value="$CFG_LOOKUP_VAL"
    layer="machine-conf"
  elif _config_list_lookup CFG_RL_ "$name"; then
    value="$CFG_LOOKUP_VAL"
    layer="repo-local"
  elif _config_list_lookup CFG_TR_ "$name"; then
    value="$CFG_LOOKUP_VAL"
    layer="tracked-repo"
  else
    value="$default"
    # untouched -> the registry row's own recorded layer (layer 5/6) wins
    layer="$reg_layer"
  fi

  if [ "$format" = "tsv" ]; then
    printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$layer" "$value" "$owning" "$doc"
  else
    printf '%-42s %-13s %-30s %s\n' "$name" "$layer" "$value" "$owning"
  fi
done <<EOF
$rows
EOF

exit 0
