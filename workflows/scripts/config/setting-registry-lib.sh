#!/usr/bin/env bash
#
# setting-registry-lib.sh — parse helper for the kernel setting registry
# (temperloop#164/#169, design decision D2: a kernel TSV registry + "keep the
# shell literals, lint them for equality" — the equality lint itself is a
# LATER item, registry-config-lints; this file only reads the registry).
#
# Reads workflows/scripts/config/setting-registry.tsv (the kernel table, ALWAYS
# present) and UNIONS in an optional overlay extension TSV when one is
# present — the same union shape as validate-capture-backstop.sh's kernel-table +
# overlay-extension-table pairing (see that script's header for the
# precedent this mirrors): a standalone kernel checkout reads the kernel
# table alone; a composed/overlay checkout (one that vendors this kernel via
# git subtree and adds its own org-specific settings) additionally unions in its
# overlay extension.
#
# ── Row shape (kernel table) ────────────────────────────────────────────────
#   name<TAB>default<TAB>type<TAB>layer<TAB>owning-script<TAB>doc   (6 fields)
# See setting-registry.tsv's own header for the full column contract (type/layer
# closed sets, inclusion rule).
#
# ── Overlay extension TSV ───────────────────────────────────────────────────
# Same 6 fields PLUS a 7th trailing `op` field, op in {add, redefault}:
#   name<TAB>default<TAB>type<TAB>layer<TAB>owning-script<TAB>doc<TAB>op
#   - op=add        a NEW setting, not present in the kernel table at all. It is
#                    an error (malformed) for an `add` row's name to already
#                    exist in the kernel table — that is a collision, almost
#                    certainly a copy-paste mistake, and should be `redefault`
#                    instead.
#   - op=redefault   OVERRIDES an existing kernel row's default/type/layer/
#                    owning-script/doc for the union view (e.g. an overlay
#                    that ships a different default for a setting the kernel
#                    also defines). It is an error for a `redefault` row's
#                    name to be absent from the kernel table — nothing to
#                    redefine.
# Discovery path: a sibling file next to the kernel TSV,
# workflows/scripts/config/setting-registry.overlay.tsv — present only in a
# composed/overlay checkout, mirroring claude/capture-backstop-registry.overlay.md.
# Overridable via SETTING_REGISTRY_OVERLAY_FILE (a test seam / explicit path
# override), per this repo's config-precedence discovery conventions
# (docs/config-precedence.md; see e.g. BOARDS_CONF_REPO_LOCAL). The kernel
# file path itself is overridable via SETTING_REGISTRY_FILE.
#
# Parsed with grep/cut only — NEVER sourced or eval'd, so a registry file
# (kernel or overlay) cannot execute code, same discipline as boards.conf.
#
# Kept bash-3.2-portable (no associative arrays, no mapfile) so it runs on
# the macOS dev shell as well as Linux CI, matching board.sh / cache.sh.
#
# This file is SOURCED, never executed directly — it has no CLI of its own.

_SETTING_REGISTRY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# (The v0.17.0 terminology-rename legacy window sourced an env shim here so a
# pre-rename KNOB_* env seam still drove the renamed SETTING_* name. The
# window CLOSED in v0.19.0, temperloop#767 — the shim and both of its
# `[ -f ]`-guarded source blocks are gone, and a pre-rename env name is
# simply unread.)

# The closed `type` vocabulary (setting-registry.tsv's own header is the
# canonical documentation of these; kept here too so validation doesn't need
# to re-parse the header comment).
SETTING_REGISTRY_TYPES="int seconds pct bool string enum path url label marker"

# The closed `layer` vocabulary — the six-layer ladder's own tokens
# (docs/config-precedence.md), naming WHERE a row's recorded default lives.
# Every row in THIS registry records a layer-5 or layer-6 default (a config
# ladder's layers 1-4 are call-site/environment, never a registry row); both
# tokens are kept in one vocabulary so a validator can still recognize e.g. a
# future layer-3/4 row without a schema change.
SETTING_REGISTRY_LAYERS="cli env machine-conf repo-local tracked-repo kernel"

# setting_registry_kernel_file -> the kernel TSV path (default: sibling
# setting-registry.tsv next to this lib; override via SETTING_REGISTRY_FILE).
setting_registry_kernel_file() {
  printf '%s' "${SETTING_REGISTRY_FILE:-$_SETTING_REGISTRY_LIB_DIR/setting-registry.tsv}"
}

# setting_registry_overlay_file -> the overlay extension TSV path (default: a
# sibling setting-registry.overlay.tsv; override via SETTING_REGISTRY_OVERLAY_FILE).
# Does NOT check existence — callers test `-f` themselves (mirrors
# validate-capture-backstop.sh's DRAIN_OVERLAY_EXT handling).
setting_registry_overlay_file() {
  printf '%s' "${SETTING_REGISTRY_OVERLAY_FILE:-$_SETTING_REGISTRY_LIB_DIR/setting-registry.overlay.tsv}"
}

# _setting_registry_data_rows <file> -> non-blank, non-comment lines of <file>,
# one per line. A comment is a line whose first non-space character is `#`.
_setting_registry_data_rows() {
  local file="$1"
  [ -f "$file" ] || return 0
  grep -vE '^[[:space:]]*(#|$)' "$file" || true
}

# _setting_registry_field_count <line> -> number of TAB-separated fields.
_setting_registry_field_count() {
  awk -F'\t' '{print NF}' <<<"$1"
}

# _setting_split_row <tab-row> -> sets globals KR_F1..KR_F7 to fields 1..7 (empty
# for any field the row lacks) and KR_NF to the field count. Parameter
# expansion ONLY — no `cut`/`awk` subshells. This is the hot path for
# setting_registry_validate / _rows / _get, each of which walks all ~430 registry
# rows; the previous per-row `$(_setting_registry_field_count …)` + four/one
# `$(cut …)` subshells were ~5 forks/row and dominated `config list`, the
# `configure` wizard, and the equality lint's runtime (K305). Deliberately NOT
# `IFS=$'\t' read`: tab is IFS-whitespace, so `read` collapses consecutive
# tabs and mis-aligns rows with an empty field (field 2 `default` is
# legitimately empty for many settings, e.g. EVAL_RUN). Parameter expansion
# preserves empty fields, matching `cut -f` exactly. Bash-3.2-portable.
#
# THE FIELD COUNT IS ACCUMULATED, NEVER DERIVED FROM `${r//[!$'\t']/}`
# (temperloop#2163). That global substitution walks the row CHARACTER BY
# CHARACTER inside bash, and it measured at ~2ms per row — 0.87s of the 1.03s
# `setting_registry_validate` spends, and the same again in `config list`'s own
# row walk, for a count this function's field-splitting loop already produces
# for free. Counting as we split is O(fields) instead of O(row length), keeps
# KR_NF exact for a row with MORE than 7 fields (the overlay-table `fc != 7`
# check depends on that), and preserves every empty field exactly as before.
_setting_split_row() {
  local rest="$1" n=0 f
  KR_F1=''; KR_F2=''; KR_F3=''; KR_F4=''; KR_F5=''; KR_F6=''; KR_F7=''
  while :; do
    n=$(( n + 1 ))
    f="${rest%%$'\t'*}"
    case "$n" in
      1) KR_F1="$f" ;;
      2) KR_F2="$f" ;;
      3) KR_F3="$f" ;;
      4) KR_F4="$f" ;;
      5) KR_F5="$f" ;;
      6) KR_F6="$f" ;;
      7) KR_F7="$f" ;;
    esac
    case "$rest" in
      *$'\t'*) rest="${rest#*$'\t'}" ;;
      *) break ;;
    esac
  done
  KR_NF="$n"
}

# _setting_registry_legal_name <name> -> rc 0 iff <name> is a legal shell
# identifier ([A-Za-z_][A-Za-z0-9_]*). The registry's consumers expand a row's
# name indirectly (`${!name}` in bin/subcommands/config.sh — the
# _config_list_bulk_source probe and the per-row env check); an illegal name
# aborts that expansion (bash "invalid variable name"), silently dropping
# rows — so validation rejects it here, upstream, instead. Pure `case`
# pattern-match (no regex), bash-3.2-portable.
_setting_registry_legal_name() {
  case "$1" in
    ''|[0-9]*|*[!A-Za-z0-9_]*) return 1 ;;
    *) return 0 ;;
  esac
}

# _setting_registry_in_list <needle> <space-separated list> -> rc 0 if present.
#
# ONE quoted-substring `case` match, NOT a `for item in $list` walk (K2163).
# setting_registry_validate calls this once per registry row against a list it
# grows by one entry per row, so the walk was quadratic in the registry size:
# at 434 rows that is ~94k loop iterations plus a re-word-split of an
# ever-longer string, and it measured as 1.25s of `config list`'s 3.0s — which
# `test_config.sh` pays ten times over and `test_score_gate_env.sh` then pays
# twice more on top of that. The substring search is the same membership test
# done in C.
#
# The needle is QUOTED INSIDE the pattern (`*" $needle "*`), so a `*` or `?` in
# a row's owning-script field is matched literally instead of globbing — the
# quoted portion of a `case` pattern is never a wildcard. An EMPTY needle
# returns 1 up front: `$list` carries a leading space, so an unquoted empty
# needle would match the resulting double space and silently turn a malformed
# row's empty `type`/`layer` into a legal one. Bash-3.2-portable.
_setting_registry_in_list() {
  local needle="$1" list="$2"
  [ -n "$needle" ] || return 1
  case " $list " in
    *" $needle "*) return 0 ;;
  esac
  return 1
}

# setting_registry_validate [--kernel-only] -> validates the kernel table (and,
# unless --kernel-only, the overlay extension when present). Prints one
# "MALFORMED: <reason>: <line>" line per bad row to stderr and returns
# non-zero if any row is malformed; otherwise prints nothing and returns 0.
# Malformed conditions:
#   - kernel row: field count != 6, OR `name` not a legal shell identifier
#     ([A-Za-z_][A-Za-z0-9_]*), OR `type` not in SETTING_REGISTRY_TYPES, OR
#     `layer` not in SETTING_REGISTRY_LAYERS, OR a duplicate (name,
#     owning-script) PAIR within the kernel table itself. A repeated `name`
#     alone is NOT an error — a setting whose default genuinely differs between
#     two owning scripts (a real layer-5-vs-layer-6 divergence, see
#     setting-registry.tsv's own header) legitimately gets two rows, one per
#     owning-script/layer; only an exact (name, owning-script) repeat is a
#     copy-paste mistake.
#   - overlay row: field count != 7, OR `name` not a legal shell identifier
#     (as above), OR `type`/`layer` invalid (as above), OR
#     `op` not in {add, redefault}, OR an `add` row whose name already
#     exists in the kernel table (collision), OR a `redefault` row whose name
#     does NOT exist in the kernel table (nothing to redefine).
setting_registry_validate() {
  local kernel_only="${1:-}"
  local kfile ofile rows row name type layer op fc bad=0
  kfile="$(setting_registry_kernel_file)"

  if [ ! -f "$kfile" ]; then
    echo "MALFORMED: kernel registry file not found: $kfile" >&2
    return 1
  fi

  local kernel_names="" kernel_name_script_pairs="" owning_script pair
  rows="$(_setting_registry_data_rows "$kfile")"
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    _setting_split_row "$row"
    fc="$KR_NF"
    if [ "$fc" != "6" ]; then
      echo "MALFORMED: kernel row has $fc fields (want 6): $row" >&2
      bad=1
      continue
    fi
    name="$KR_F1"
    type="$KR_F3"
    layer="$KR_F4"
    owning_script="$KR_F5"
    if ! _setting_registry_legal_name "$name"; then
      echo "MALFORMED: kernel row name '$name' is not a legal shell identifier ([A-Za-z_][A-Za-z0-9_]*) in $kfile: $row" >&2
      bad=1
    fi
    # Uniqueness key is (name, owning-script), not name alone — a setting
    # legitimately gets two rows when its default genuinely differs between
    # two owning scripts (see this function's header comment).
    pair="${name}|${owning_script}"
    if _setting_registry_in_list "$pair" "$kernel_name_script_pairs"; then
      echo "MALFORMED: duplicate kernel setting (name, owning-script): $pair" >&2
      bad=1
    fi
    kernel_name_script_pairs="$kernel_name_script_pairs $pair"
    kernel_names="$kernel_names $name"
    if ! _setting_registry_in_list "$type" "$SETTING_REGISTRY_TYPES"; then
      echo "MALFORMED: kernel row '$name' has unknown type '$type': $row" >&2
      bad=1
    fi
    if ! _setting_registry_in_list "$layer" "$SETTING_REGISTRY_LAYERS"; then
      echo "MALFORMED: kernel row '$name' has unknown layer '$layer': $row" >&2
      bad=1
    fi
  done <<EOF
$rows
EOF

  if [ "$kernel_only" != "--kernel-only" ]; then
    ofile="$(setting_registry_overlay_file)"
    if [ -f "$ofile" ]; then
      rows="$(_setting_registry_data_rows "$ofile")"
      while IFS= read -r row; do
        [ -n "$row" ] || continue
        _setting_split_row "$row"
        fc="$KR_NF"
        if [ "$fc" != "7" ]; then
          echo "MALFORMED: overlay row has $fc fields (want 7): $row" >&2
          bad=1
          continue
        fi
        name="$KR_F1"
        type="$KR_F3"
        layer="$KR_F4"
        op="$KR_F7"
        if ! _setting_registry_legal_name "$name"; then
          echo "MALFORMED: overlay row name '$name' is not a legal shell identifier ([A-Za-z_][A-Za-z0-9_]*) in $ofile: $row" >&2
          bad=1
        fi
        if ! _setting_registry_in_list "$type" "$SETTING_REGISTRY_TYPES"; then
          echo "MALFORMED: overlay row '$name' has unknown type '$type': $row" >&2
          bad=1
        fi
        if ! _setting_registry_in_list "$layer" "$SETTING_REGISTRY_LAYERS"; then
          echo "MALFORMED: overlay row '$name' has unknown layer '$layer': $row" >&2
          bad=1
        fi
        case "$op" in
          add)
            if _setting_registry_in_list "$name" "$kernel_names"; then
              echo "MALFORMED: overlay 'add' row '$name' collides with an existing kernel setting (use op=redefault): $row" >&2
              bad=1
            fi
            ;;
          redefault)
            if ! _setting_registry_in_list "$name" "$kernel_names"; then
              echo "MALFORMED: overlay 'redefault' row '$name' has no matching kernel setting to redefine: $row" >&2
              bad=1
            fi
            ;;
          *)
            echo "MALFORMED: overlay row '$name' has unknown op '$op' (want add|redefault): $row" >&2
            bad=1
            ;;
        esac
      done <<EOF
$rows
EOF
    fi
  fi

  [ "$bad" = "0" ]
}

# setting_registry_rows -> prints the UNIONED 6-field rows (kernel table with
# any overlay 'redefault' rows applied in place, plus overlay 'add' rows
# appended), one per line, name|default|type|layer|owning-script|doc
# (TAB-separated). Does NOT validate — call setting_registry_validate first if
# you want malformed rows rejected rather than silently best-effort unioned
# (an unrecognized op is treated as a no-op skip here, not an error).
setting_registry_rows() {
  local kfile ofile row name ofile_rows orow kernel_rows out=""
  kfile="$(setting_registry_kernel_file)"
  kernel_rows="$(_setting_registry_data_rows "$kfile")"

  ofile="$(setting_registry_overlay_file)"
  ofile_rows=""
  [ -f "$ofile" ] && ofile_rows="$(_setting_registry_data_rows "$ofile")"

  # Emit kernel rows, substituting a matching redefault row's 6 fields when
  # one exists.
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    name="${row%%$'\t'*}"          # field 1, no fork
    local replaced=""
    if [ -n "$ofile_rows" ]; then
      while IFS= read -r orow; do
        [ -n "$orow" ] || continue
        _setting_split_row "$orow"
        if [ "$KR_F1" = "$name" ] && [ "$KR_F7" = "redefault" ]; then
          replaced="$KR_F1"$'\t'"$KR_F2"$'\t'"$KR_F3"$'\t'"$KR_F4"$'\t'"$KR_F5"$'\t'"$KR_F6"
          break
        fi
      done <<EOF
$ofile_rows
EOF
    fi
    if [ -n "$replaced" ]; then
      out="$out$replaced"$'\n'
    else
      out="$out$row"$'\n'
    fi
  done <<EOF
$kernel_rows
EOF

  # Append overlay-only additions.
  if [ -n "$ofile_rows" ]; then
    while IFS= read -r orow; do
      [ -n "$orow" ] || continue
      _setting_split_row "$orow"
      [ "$KR_F7" = "add" ] || continue
      out="$out$KR_F1"$'\t'"$KR_F2"$'\t'"$KR_F3"$'\t'"$KR_F4"$'\t'"$KR_F5"$'\t'"$KR_F6"$'\n'
    done <<EOF
$ofile_rows
EOF
  fi

  printf '%s' "$out"
}

# setting_registry_get <name> -> prints the unioned row's `default` field for
# <name>, rc 1 on no match.
setting_registry_get() {
  local name="$1" row rest
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    if [ "${row%%$'\t'*}" = "$name" ]; then   # field 1, no fork
      rest="${row#*$'\t'}"
      printf '%s\n' "${rest%%$'\t'*}"          # field 2
      return 0
    fi
  done <<EOF
$(setting_registry_rows)
EOF
  return 1
}
