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
# VALUE ESCAPING — the `one row per line` contract is STRUCTURAL, not a
# hope (temperloop#2218). A setting's value is arbitrary text: an env-layer
# value in particular is whatever the environment holds, and in CI at least
# one registry setting (CHANGELOG_GATE_PR_BODY) is a whole pull-request body
# — untrusted, multi-line, TAB-bearing. So EVERY value this script prints,
# in BOTH formats and from ALL five layers, is emitted C-escaped:
#
#     backslash -> \\        TAB -> \t        newline -> \n
#
# and nothing else is transformed. The escape is applied exactly once, at
# the single print site at the bottom of this file, so a value can never
# reach the output carrying a field or record separator of the format it is
# being printed in. `\\` is escaped FIRST, so the encoding is unambiguous in
# both directions: a value holding the two literal characters `\` + `n`
# emits `\\n` and never round-trips back into a newline. A consumer that
# wants the raw bytes reverses the three substitutions, innermost last.
#
# The same encoding is used INTERNALLY on the layer maps (see
# _config_list_escape / _config_list_bulk_source / _config_list_index below),
# where it is load-bearing for correctness rather than presentation.
#
# TRAILING NEWLINES ARE PRESERVED (the temperloop#2218 acceptance-4 caveat,
# now resolved rather than merely documented). The three file-layer maps are
# captured through `$( )`, which strips trailing newlines — but only from
# the map as a whole, i.e. from the record TERMINATOR, because a value's own
# newlines are already `\n` by the time the map is assembled. A value of
# `a` + two newlines is carried as the six characters `a\n\n` and comes back
# out of the index byte-identical. The parse is lossless for every byte a
# shell variable can hold except NUL, which no shell variable can hold.
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

# _config_list_escape <value> -> sets CFG_ESCAPED to <value> with backslash,
# TAB and newline replaced by `\\`, `\t` and `\n` (see the header's VALUE
# ESCAPING note for the contract and why the order is load-bearing).
# Bash-3.2-safe: plain `${v//pat/rep}` pattern substitution, no `${v@Q}`, no
# printf %q, no external process.
_config_list_escape() {
  local v="$1"
  v="${v//\\/\\\\}"
  v="${v//$'\t'/\\t}"
  v="${v//$'\n'/\\n}"
  CFG_ESCAPED="$v"
}

# _config_list_unescape <escaped> -> sets CFG_UNESCAPED to the exact inverse
# of _config_list_escape. Single left-to-right scan, so `\\n` decodes to the
# two characters `\`+`n` and NOT to a newline — the ambiguity a naive
# sequence of three `${v//…}` calls would introduce. An unrecognised escape
# (`\x`) and a trailing lone backslash are both preserved verbatim rather
# than silently eaten; neither is producible by _config_list_escape, so that
# arm exists only to keep the function total.
_config_list_unescape() {
  local s="$1" out="" head ch
  # Fast path: the overwhelming majority of values hold no backslash at all,
  # and this runs once per map entry per layer (~3x the registry's row count).
  case "$s" in
    *\\*) ;;
    *) CFG_UNESCAPED="$s"; return 0 ;;
  esac
  while :; do
    case "$s" in
      *\\*) ;;
      *) out="$out$s"; break ;;
    esac
    head="${s%%\\*}"
    out="$out$head"
    s="${s:$(( ${#head} + 1 ))}"
    ch="${s:0:1}"
    case "$ch" in
      n)  out="$out"$'\n'; s="${s:1}" ;;
      t)  out="$out"$'\t'; s="${s:1}" ;;
      \\) out="$out\\";    s="${s:1}" ;;
      *)  out="$out\\" ;;   # lone/unknown backslash: keep it, re-scan from ch
    esac
  done
  CFG_UNESCAPED="$out"
}

# _config_list_bulk_source <file> <name...> -> ONE subshell source of
# <file> (silent no-op if absent/unreadable), then name<TAB>value for every
# given <name> that ended up SET after sourcing, with the VALUE C-ESCAPED
# (_config_list_escape above). One source call per candidate file for the
# WHOLE run (see header perf note), not one per setting.
#
# THE ESCAPE IS THE WHOLE POINT, not tidiness (temperloop#2218). This map is
# a one-record-per-LINE, TAB-delimited format consumed by an `IFS=$'\t' read`
# loop, and a value here is arbitrary text — every registry name that is
# merely SET in the environment is emitted, so an exported
# CHANGELOG_GATE_PR_BODY (a whole untrusted PR body in CI) lands in the value
# field. Unescaped, its own newlines opened FRESH RECORDS and its own TABs
# split them, so _config_list_index then read a variable NAME out of value
# text: it fabricated rows for real settings (`BUILD_QUOTA_PAUSE_PCT
# machine-conf 99` out of prose) and, worse, fed attacker-influenced text to
# `printf -v`, whose name argument bash parses — a name shaped `IDENT[...]`
# makes the brackets an ARRAY SUBSCRIPT evaluated in ARITHMETIC context,
# which performs command substitution. Escaping here makes the name field
# structurally incapable of coming from a value.
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
        _config_list_escape "${!n}"
        printf '%s\t%s\n' "$n" "$CFG_ESCAPED"
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
#
# TWO INDEPENDENT DEFENCES ON THE NAME ARGUMENT (temperloop#2218; kernel
# principle 5 — counter the failure mode structurally, do not ask the next
# editor to be careful):
#
#   1. The producer escapes (_config_list_bulk_source above), so value text
#      can no longer start a record and `lname` can only ever be a name the
#      producer was handed.
#   2. This loop REFUSES any `lname` that is not `[A-Za-z_][A-Za-z0-9_]*`,
#      loudly, BEFORE `printf -v` sees it. That is redundant today and
#      deliberately so: `printf -v` is not a literal context — bash parses
#      its name argument, and `IDENT[...]` makes the brackets an array
#      subscript evaluated in ARITHMETIC context, which performs command
#      substitution. Defence 1 is one `printf` edit away from being undone;
#      defence 2 fails closed no matter what reaches it, and says so on
#      stderr instead of skipping silently.
#
# The legality test is the registry lib's OWN `_setting_registry_legal_name`
# (pure `case`, bash-3.2-portable), not a second copy of the pattern here —
# same lib this file already borrows `_setting_split_row` from. One
# definition of "legal shell identifier" for the registry and its consumers
# means the two can never drift apart into a gap.
_config_list_index() {
  local prefix="$1" map="$2" lname lval
  [ -n "$map" ] || return 0
  while IFS=$'\t' read -r lname lval; do
    [ -n "$lname" ] || continue
    if ! _setting_registry_legal_name "$lname"; then
      echo "config.sh: internal error — refusing to index layer entry '$lname': not a legal shell identifier (unreachable via _config_list_bulk_source; see _config_list_index)" >&2
      continue
    fi
    _config_list_unescape "$lval"
    printf -v "${prefix}${lname}" '%s' "$CFG_UNESCAPED"
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

  # THE SINGLE PRINT SITE — escape here, once, for every layer and both
  # formats (temperloop#2218). The env layer is why this cannot live in the
  # index: it reads `${!name}` directly at the top of this loop and never
  # passes through a layer map at all, so a multi-line env value would reach
  # `printf` raw and break the documented one-row-per-line contract no matter
  # what the index does. Escaping the printed `value` rather than each
  # producer covers env, all three file layers and the registry default in one
  # place, and makes the contract un-bypassable by a future fifth source.
  _config_list_escape "$value"
  if [ "$format" = "tsv" ]; then
    printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$layer" "$CFG_ESCAPED" "$owning" "$doc"
  else
    printf '%-42s %-13s %-30s %s\n' "$name" "$layer" "$CFG_ESCAPED" "$owning"
  fi
done <<EOF
$rows
EOF

exit 0
