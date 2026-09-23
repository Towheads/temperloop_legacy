#!/usr/bin/env bash
#
# check-gate-paths.sh — completeness + reachability lint for the diff-scoped
# gate-selection map (temperloop#1024).
#
# This is the validation half of the path->gate map. Diff-scoped CI selection
# is only safe if the map cannot silently fall behind the gate list, so the map
# ships with its own gate — the same live-check-then-fixture-tests shape as
# check-setting-registry.sh and check-reviewer-routing.sh, and the same
# validate-capture-backstop.sh mold ("a registry that is not mechanically
# reconciled against the tree is a registry that drifts").
#
# FIVE CHECKS, all against the CURRENT tree (no baseline — the map was authored
# complete, so a red run is real drift, never debt to grandfather in):
#
#   1. WELL-FORMED   every non-comment row is TAB-separated with a non-empty
#      key and a non-empty glob list; no key appears twice.
#   2. COMPLETE      every gate scripts/quality-gates.sh reports on its
#      `[kernel]` layer has a row. A gate with no row still RUNS at selection
#      time (gate-selection.sh over-runs rather than under-runs), but leaving
#      it unmapped is drift, so it fails here rather than quietly widening
#      every PR's run forever. A row may be keyed EXACTLY or, since
#      temperloop#2162, by a PATTERN that globs a whole family of gates — see
#      the note at check 2 below.
#   3. NO STALE ROWS  every row key is either a reserved pseudo-key (`ALL`,
#      `none`) or a gate that currently exists — for a pattern key, at least
#      one current gate it globs. A row naming a deleted gate is dead weight
#      that hides a rename.
#   4. REACHABLE     every glob-bearing row has at least one glob that matches
#      at least one git-tracked path. THIS is the check the issue's second
#      constraint asks for: a gate whose globs can never match is a gate that
#      is silently skipped on every scoped run — exactly the silent-green class
#      the map must not reopen. `ALWAYS` rows are exempt by construction (they
#      carry no globs and run every scoped run). Additionally, any LITERAL
#      (wildcard-free) glob must exist in the tree — a literal that matches
#      nothing is a typo or a stale path, never a deliberate forward
#      reference. A WILDCARD that matches nothing is tolerated as long as its
#      row is otherwise reachable, because a wildcard may legitimately name an
#      optional surface (`scripts/quality-gates.d/**` exists only in a tree
#      that carries overlay drop-ins).
#   5. GATE COMMAND SHAPE  every declared gate command begins `make ` or
#      `bash `. build-level.mjs recovers a timed-out gate's NAME from its
#      ordinal by filtering `--list-selected` through `grep -E '^(make|bash) '`
#      (temperloop#1650); a gate spelled otherwise is silently dropped from that
#      filter and shifts every later ordinal, so the escalation names the wrong
#      gate. Asserted here so the coupling goes RED instead of drifting.
#
# Glob semantics are NOT reimplemented here: this script sources
# workflows/scripts/lib/gate-selection.sh and calls its `_gs_path_matches_glob`,
# so the matcher that validates the map is byte-for-byte the matcher that
# consumes it. A divergence between the two would be precisely the kind of
# false-green this gate exists to prevent.
#
# VENDORING CONSUMERS: in a composed tree (repo-root `.kernel-pin` present) the
# surface-conditional gates quality-gates.sh class-gates away are legitimately
# absent, so checks 2 and 3 report a legible SKIP line for the affected rows
# instead of failing — mirroring quality-gates.sh's own SKIPPED_KERNEL_GATES
# convention. In the kernel's own checkout (no `.kernel-pin`) both are hard.
# Check 4 honors the SAME exemption (temperloop#1144): a row check 3 just
# reported as `[skip]` is not this tree's row to hold reachable either, and
# failing it would tell the consumer to edit a gate-paths.tsv that is a symlink
# to the kernel's own. It is an exemption for ABSENT gates only — a row whose
# gate IS present in the composed tree keeps full literal-path and reachability
# checking, so the anti-silent-green property survives everywhere it applies.
#
# Usage:
#   check-gate-paths.sh
#
# Env overrides (the fixture seams, mirroring workflows/scripts/config/*'s
# SETTING_REGISTRY_* convention):
#   GATE_PATHS_FILE            map to validate (default: sibling gate-paths.tsv)
#   GATE_PATHS_ROOT            repo root (default: this script's repo)
#   GATE_PATHS_GATE_LIST_FILE  file of `[layer]  <gate>` lines to use instead of
#                              invoking scripts/quality-gates.sh --list
#   GATE_PATHS_TRACKED_FILE    file of tracked paths (one per line) to use
#                              instead of `git ls-files`
#   GATE_PATHS_ASSUME_CONSUMER 1 forces the vendoring-consumer arm (test seam)
#   GATE_PATHS_KERNEL_PREFIX   in a vendoring consumer, the path prefix the
#                              kernel subtree is vendored under, WITH its
#                              trailing slash (default: `kernel/`, the prefix
#                              `git subtree pull --prefix=kernel` establishes
#                              and `.kernel-pin` documents). Only consulted in
#                              consumer mode.
#
# Kept bash-3.2-portable (macOS default shell): no associative arrays, no
# mapfile.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT_DEFAULT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

ROOT="${GATE_PATHS_ROOT:-$REPO_ROOT_DEFAULT}"
MAP_FILE="${GATE_PATHS_FILE:-$SCRIPT_DIR/gate-paths.tsv}"

# The shared matcher — never a second copy (see the header).
# shellcheck source=../lib/gate-selection.sh
if ! source "$REPO_ROOT_DEFAULT/workflows/scripts/lib/gate-selection.sh"; then
  echo "check-gate-paths: cannot source gate-selection.sh" >&2
  exit 1
fi

fail=0
issues=0

_gp_issue() {
  printf '  [FAIL] %s\n' "$1" >&2
  issues=$((issues + 1))
  fail=1
}

# --- consumer detection ------------------------------------------------------
CONSUMER=0
if [[ "${GATE_PATHS_ASSUME_CONSUMER:-0}" == "1" ]] || [[ -f "$ROOT/.kernel-pin" ]]; then
  CONSUMER=1
fi
# Where a consumer vendors the kernel subtree. The map's rows are authored
# against the KERNEL's root layout (`scripts/tests/foo.sh`); in a composed tree
# that same file is tracked as `kernel/scripts/tests/foo.sh`, so check 4 has to
# try both spellings before calling a path missing.
KERNEL_PREFIX="${GATE_PATHS_KERNEL_PREFIX:-kernel/}"

# --- inputs ------------------------------------------------------------------
if [[ ! -f "$MAP_FILE" ]]; then
  echo "check-gate-paths: map file not found: $MAP_FILE" >&2
  exit 1
fi

GATE_LIST_RAW=""
if [[ -n "${GATE_PATHS_GATE_LIST_FILE:-}" ]]; then
  GATE_LIST_RAW="$(cat "$GATE_PATHS_GATE_LIST_FILE")"
elif [[ -x "$ROOT/scripts/quality-gates.sh" || -f "$ROOT/scripts/quality-gates.sh" ]]; then
  if ! GATE_LIST_RAW="$(bash "$ROOT/scripts/quality-gates.sh" --list 2>/dev/null)"; then
    echo "check-gate-paths: scripts/quality-gates.sh --list failed" >&2
    exit 1
  fi
else
  echo "check-gate-paths: no gate list available (no --list source)" >&2
  exit 1
fi

TRACKED=""
if [[ -n "${GATE_PATHS_TRACKED_FILE:-}" ]]; then
  TRACKED="$(cat "$GATE_PATHS_TRACKED_FILE")"
else
  TRACKED="$(git -C "$ROOT" ls-files 2>/dev/null)"
fi
if [[ -z "$TRACKED" ]]; then
  echo "check-gate-paths: no tracked paths resolved under $ROOT" >&2
  exit 1
fi

# Kernel-layer gates (completeness is enforced over these) and the union of all
# declared gates (staleness is judged against this).
KERNEL_GATE_LIST=""
ALL_GATE_LIST=""
while IFS= read -r line; do
  case "$line" in
    '[kernel]  '*)
      KERNEL_GATE_LIST="${KERNEL_GATE_LIST:+$KERNEL_GATE_LIST$'\n'}${line#'[kernel]  '}"
      ALL_GATE_LIST="${ALL_GATE_LIST:+$ALL_GATE_LIST$'\n'}${line#'[kernel]  '}"
      ;;
    '[overlay] '*)
      ALL_GATE_LIST="${ALL_GATE_LIST:+$ALL_GATE_LIST$'\n'}${line#'[overlay] '}"
      ;;
    *) : ;;  # `[skipped] …` lines carry a reason, not a gate command
  esac
done <<<"$GATE_LIST_RAW"

if [[ -z "$KERNEL_GATE_LIST" ]]; then
  echo "check-gate-paths: gate list contained no [kernel] entries" >&2
  exit 1
fi

echo "==> check-gate-paths: validating $(basename "$MAP_FILE")"

# --- 1. well-formed ----------------------------------------------------------
KEYS=""
GLOBS_BY_INDEX=()
KEY_BY_INDEX=()
lineno=0
while IFS= read -r line || [[ -n "$line" ]]; do
  lineno=$((lineno + 1))
  line="${line%$'\r'}"
  case "$line" in ''|'#'*) continue ;; esac
  case "$line" in
    *$'\t'*) : ;;
    *) _gp_issue "line $lineno: no TAB separator: $line"; continue ;;
  esac
  key="${line%%$'\t'*}"
  globs="${line#*$'\t'}"
  if [[ -z "$key" ]]; then _gp_issue "line $lineno: empty key"; continue; fi
  if [[ -z "$globs" ]]; then _gp_issue "line $lineno: empty glob list for key '$key'"; continue; fi
  case "$globs" in
    *$'\t'*) _gp_issue "line $lineno: more than two TAB-separated columns for key '$key'"; continue ;;
  esac
  if grep -Fxq -- "$key" <<<"$KEYS" 2>/dev/null; then
    _gp_issue "line $lineno: duplicate key '$key'"
    continue
  fi
  KEYS="${KEYS:+$KEYS$'\n'}$key"
  KEY_BY_INDEX+=("$key")
  GLOBS_BY_INDEX+=("$globs")
done <"$MAP_FILE"

if [[ ${#KEY_BY_INDEX[@]} -eq 0 ]]; then
  _gp_issue "map has no usable rows"
fi

# --- 2. completeness ---------------------------------------------------------
# A gate is mapped by an EXACT row, or (temperloop#2162) by a PATTERN row whose
# key globs it. Pattern rows exist because quality-gates.sh glob-expands two
# test directories into one gate per script: demanding a literal row per script
# would reinstate the hand-enumeration trap the expansion removes — adding a
# new test_*.sh would turn THIS check red until someone also edited the map.
# `_gs_key_is_pattern` / `_gs_key_matches_gate` are the SHARED predicates from
# gate-selection.sh (already sourced above), never a second copy — the same
# reason `_gs_path_matches_glob` is shared: a validator that judges the map by
# a different rule than the consumer applies is its own false-green.
_gp_gate_is_mapped() {
  local gate="$1" k
  grep -Fxq -- "$gate" <<<"$KEYS" && return 0
  for k in "${KEY_BY_INDEX[@]}"; do
    case "$k" in ALL|none) continue ;; esac
    _gs_key_is_pattern "$k" || continue
    _gs_key_matches_gate "$k" "$gate" && return 0
  done
  return 1
}

while IFS= read -r gate; do
  [[ -n "$gate" ]] || continue
  if ! _gp_gate_is_mapped "$gate"; then
    _gp_issue "gate has no row in the map (add one, or the gate widens every scoped run): $gate"
  fi
done <<<"$KERNEL_GATE_LIST"

# --- 3. no stale rows --------------------------------------------------------
# A PATTERN row is live when it globs at least one CURRENT gate, so a family row
# whose directory was deleted or renamed still fails here — which is exactly the
# staleness this check exists to catch, just one level up from a literal key.
_gp_key_names_a_gate() {
  local key="$1" g
  grep -Fxq -- "$key" <<<"$ALL_GATE_LIST" && return 0
  _gs_key_is_pattern "$key" || return 1
  while IFS= read -r g; do
    [[ -n "$g" ]] || continue
    _gs_key_matches_gate "$key" "$g" && return 0
  done <<<"$ALL_GATE_LIST"
  return 1
}

i=0
while [[ $i -lt ${#KEY_BY_INDEX[@]} ]]; do
  key="${KEY_BY_INDEX[$i]}"
  i=$((i + 1))
  case "$key" in ALL|none) continue ;; esac
  if ! _gp_key_names_a_gate "$key"; then
    if [[ $CONSUMER -eq 1 ]]; then
      printf '  [skip] row names a gate absent from this composed tree (vendoring consumer): %s\n' "$key"
    else
      _gp_issue "row names a gate that does not exist (stale row — was it renamed or deleted?): $key"
    fi
  fi
done

# --- 4. reachability ---------------------------------------------------------
# Every glob-bearing row must have at least one glob that matches at least one
# git-tracked path. An unmatched glob means the gate can never be selected.
i=0
while [[ $i -lt ${#KEY_BY_INDEX[@]} ]]; do
  key="${KEY_BY_INDEX[$i]}"
  globs="${GLOBS_BY_INDEX[$i]}"
  i=$((i + 1))
  [[ "$globs" == "ALWAYS" ]] && continue
  # VENDORING CONSUMERS — skip a row whose gate this composed tree does not
  # carry. quality-gates.sh class-gates those kernel-only gates away
  # (SELF_DISTRIBUTION_GATES and its peers, keyed on the SAME repo-root
  # `.kernel-pin` signal this script reads), and check 3 above has already
  # printed a `[skip]` line for this exact row — so failing it here would
  # contradict the skip we just reported, and would demand the consumer "fix" a
  # gate-paths.tsv that is a symlink to the kernel's own. The skip is therefore
  # already legible; a second line per row would be 100+ lines of noise.
  #
  # Deliberately NOT a blanket consumer bypass: a row whose gate IS present in
  # this tree stays hard, so the anti-silent-green check below still applies
  # everywhere it can apply.
  if [[ $CONSUMER -eq 1 ]]; then
    case "$key" in
      ALL|none) ;;
      *) if ! _gp_key_names_a_gate "$key"; then continue; fi ;;
    esac
  fi
  # `read -r -a`, never a bare `for glob in $globs` — the latter pathname-expands
  # the author's globs against the working directory before they are ever tested.
  read -r -a GLOB_LIST <<<"$globs"
  row_hit=0
  for glob in "${GLOB_LIST[@]}"; do
    hit=0
    # In a composed consumer tree, a row authored against the kernel's root
    # layout resolves under the vendored subtree — so try `<glob>` first and
    # `<kernel-prefix><glob>` second. In the kernel's own checkout the second
    # candidate is never added, so behaviour there is byte-for-byte unchanged.
    GLOB_CANDIDATES=("$glob")
    if [[ $CONSUMER -eq 1 ]]; then
      GLOB_CANDIDATES+=("$KERNEL_PREFIX$glob")
    fi
    for cand in "${GLOB_CANDIDATES[@]}"; do
      # Fast path: a glob with no wildcard is an exact path — a single grep beats
      # a bash loop over ~700 tracked paths, and most rows name exact files.
      case "$cand" in
        *'*'*|*'?'*|*'['*)
          while IFS= read -r p; do
            [[ -n "$p" ]] || continue
            if _gs_path_matches_glob "$p" "$cand"; then hit=1; break; fi
          done <<<"$TRACKED"
          ;;
        *)
          if grep -Fxq -- "$cand" <<<"$TRACKED"; then hit=1; fi
          ;;
      esac
      if [[ $hit -eq 1 ]]; then break; fi
    done
    # A LITERAL path (no wildcard) that matches nothing — under EITHER spelling
    # — is a typo or a stale reference, always a failure. A WILDCARD may
    # legitimately point at an optional/absent surface (scripts/quality-gates.d/**
    # in the kernel's own checkout, an overlay-only tree), so it is judged only
    # through the row-level check below.
    case "$glob" in
      *'*'*|*'?'*|*'['*) ;;
      *)
        if [[ $hit -eq 0 ]]; then
          _gp_issue "literal path '$glob' does not exist in the tree (typo or stale reference) on row: $key"
        fi
        ;;
    esac
    [[ $hit -eq 1 ]] && row_hit=1
  done
  # THE anti-silent-green check: a row whose globs can NEVER match is a gate
  # that is silently skipped on every scoped run, forever.
  if [[ $row_hit -eq 0 ]]; then
    _gp_issue "unreachable row — no glob matches any tracked path, so this gate can never be selected: $key"
  fi
done

# --- 5. gate command shape ---------------------------------------------------
# Every gate command must begin `make ` or `bash ` (temperloop#1650).
#
# This is NOT a style rule. build-level.mjs recovers the ORDINAL->name mapping
# for a timed-out gate by filtering `quality-gates.sh --list-selected` through
# `grep -E '^(make|bash) '` and taking line idx+1 — the selection banner, the
# pin notice and the trailing skipped-gate block are all dropped by that filter.
# A gate spelled any other way (`npm run …`, `node …`, `./scripts/x.sh`,
# `env FOO=1 bash …`) is dropped too, and then EVERY subsequent ordinal shifts
# by one, so the escalation names the wrong gate — confidently, in a message an
# operator acts on. The coupling is invisible from either side, so it is
# asserted here, against the live `--list` output, rather than left to whoever
# adds the next gate. Widening the vocabulary is fine; it just has to happen in
# both places, and this check is what makes that simultaneous.
while IFS= read -r _gp_gate; do
  [[ -n "$_gp_gate" ]] || continue
  case "$_gp_gate" in
    'make '*|'bash '*) : ;;
    *) _gp_issue "gate command does not begin \`make \` or \`bash \`, so build-level.mjs's ordinal->name filter drops it and shifts every later ordinal: $_gp_gate" ;;
  esac
done <<<"$ALL_GATE_LIST"
unset _gp_gate

# --- verdict -----------------------------------------------------------------
n_rows=${#KEY_BY_INDEX[@]}
n_gates="$(grep -c . <<<"$KERNEL_GATE_LIST" || true)"
if [[ $fail -ne 0 ]]; then
  printf '\ncheck-gate-paths: FAILED — %d issue(s) across %d row(s) / %d kernel gate(s).\n' \
    "$issues" "$n_rows" "$n_gates" >&2
  printf 'Fix by editing %s: every kernel gate needs exactly one row, every row a\n' "$MAP_FILE" >&2
  printf 'glob that matches at least one tracked path (or the literal ALWAYS).\n' >&2
  exit 1
fi
printf '  [ok] %d row(s) cover %d kernel gate(s); every glob reaches the tree\n' "$n_rows" "$n_gates"
exit 0
