#!/usr/bin/env bash
#
# gate-selection.sh — DIFF-SCOPED gate selection for scripts/quality-gates.sh
# (temperloop#1024).
#
# Sourced, never executed — the same seam as its siblings gate-retry.sh and
# checkout-freshness.sh, and for the same reason: quality-gates.sh's gate LIST
# is ~110 hardcoded `make`/`bash` targets, so a selection policy embedded in
# that file could not be exercised by a test without running the whole suite.
# Here it takes a synthetic map + a synthetic changed-path list and is testable
# in milliseconds (workflows/scripts/lib/tests/test_gate_selection.sh).
#
# ── The problem ──────────────────────────────────────────────────────────
# The `checks` job runs the whole gate set sequentially (~5.5 min measured
# 2026-08-02, flat across the last 20 runs) on EVERY pull_request, and again on
# merge_group — so every merged PR pays ≥11 min of CI even when the diff is a
# single docs file. Almost none of those suites can be affected by a docs edit.
#
# ── The shape of the fix ─────────────────────────────────────────────────
# A registry (workflows/scripts/config/gate-paths.tsv) maps each gate to the
# path globs that can affect it. On a `pull_request` event with a resolvable
# base SHA, only the gates reachable from the changed paths run. Everywhere
# else — merge_group, push:main, nightly, a local or worker run, an
# unresolvable base, a missing/unparseable map — the FULL set runs exactly as
# before. Full-set coverage of `main` is therefore never weakened: the merge
# queue's own `checks` run is unscoped.
#
# ── The failure class this must not reintroduce ──────────────────────────
# A path→gate map that misses a dependency silently runs a NARROWER set and
# reports green — the silent-green class. Five structural defenses:
#
#   1. DEFAULT TO FULL on an unrecognised path. A changed path that matches no
#      glob in ANY row escalates the whole run to the full set. Narrowing is
#      opt-in per path, never the fallback.
#   2. DEFAULT TO FULL on any resolution failure — no base, a base git cannot
#      resolve, an empty/failed diff, a missing or malformed map file. Every
#      degradation is announced on stderr, never silent.
#   3. AN EXPLICIT ESCALATION ROW (`ALL`). Paths whose blast radius is the gate
#      machinery itself (quality-gates.sh, this lib, the map, the Makefile, the
#      CI workflows, the kernel manifest) force the full set outright.
#      ONE NARROW, CONTENT-CHECKED EXCEPTION (temperloop#1933): a diff to
#      `scripts/quality-gates.sh` that REMOVES nothing and ADDS only
#      gate-REGISTRATION lines, with comments and blank lines allowed to ride
#      along. TWO line shapes count as a registration, and BOTH additionally
#      require the literal to name a gate the caller's own list already carries:
#        `<NAME>_GATES+=("<literal command>")`   the append form (l.1917+),
#          self-describing — the array it appends to is ON the line; and
#        `  "<literal command>"`                 a bare element of a
#          `<NAME>_GATES=( … )` array literal; quality-gates.sh calls
#          `KERNEL_GATES=(` "the ONE place this list is typed", the most
#          idiomatic site of all. This shape names no array of its own, so it
#          is additionally required to sit POSITIONALLY inside such a literal:
#          the enclosing `-U0` hunk header's funcname context must itself read
#          `<NAME>_GATES=(` / `<NAME>_GATES+=(`. Shape + membership is NOT
#          enough for it — `SERIAL_LANE_PINS=( … )` and
#          `SLOW_DISPATCH_HINTS=( … )` also hold bare quoted literals that ARE
#          members of the run set, so without the positional test an addition
#          to the serial-lane pin list (a correctness-bearing concurrency
#          decision, not a registration) bought the narrow run and skipped
#          `test_quality_gates_parallel.sh` — the one gate that would prove it.
#      The membership requirement keeps the append form from reading a
#      SKIPPED_KERNEL_GATES disclosure string (whose array name also ends
#      `_GATES`) as a registration, and backs the bare-element form up behind
#      the positional test.
#      Such a diff ADDS a gate;
#      it cannot change what any EXISTING gate runs, nor how the tree is
#      classified — which is the whole reason quality-gates.sh sits on the ALL
#      row. So the ALL row alone is skipped FOR THAT ONE PATH, the map's own
#      non-ALL rows select the registry validators that a registration has to
#      satisfy (check-gate-paths + its test, the check-surface degenerate-
#      coverage pair, the exec-bit pair, and the ALWAYS floor that already
#      carries check-setting-registry / validate-feature-docs / the kernel
#      manifest), and the NEWLY REGISTERED gate commands are unioned in by name.
#      Every other quality-gates.sh edit — any removed line, any added line that
#      is not a registration, an added literal that is not a gate in the caller's
#      list, a comment-only diff, a diff the probe cannot read at all — keeps the
#      full escalation. The exception fails CLOSED.
#   4. AN UNMAPPED GATE ALWAYS RUNS. A gate with no row in the map is selected
#      unconditionally rather than skipped, so a map that has fallen behind the
#      gate list over-runs instead of under-running. The companion validator
#      (workflows/scripts/config/check-gate-paths.sh, itself a gate) turns that
#      soft over-run into a hard build failure in the kernel's own checkout,
#      and additionally proves every row's globs match at least one tracked
#      path — a gate orphaned behind a glob that can never match fails the
#      build rather than being silently skipped forever.
#   5. A RENAME LISTS BOTH PATHS (temperloop#1695). Every changed-set diff runs
#      with `--no-renames`. git's rename detection is ON by default and reports
#      a rename as a SINGLE entry carrying the DESTINATION path only, so moving
#      a file OUT of a gated tree put only the destination in the changed set:
#      the source tree lost a file and nothing re-ran its gates. `--no-renames`
#      renders the same change as a delete PLUS an add, so BOTH paths enter the
#      changed set and BOTH trees' gates are pulled in.
#      WHY WIDENING IS THE SAFE DIRECTION: it is the same bet defenses 1, 2 and
#      4 already make — every unknown resolves toward MORE coverage, because
#      an over-run costs gate minutes while an under-run reports green on a
#      suite that never ran. Reconstructing the source path from a `R100 old
#      new` status line instead would narrow on a second parse of the same
#      diff and buy nothing the wider set does not already cover; the cost here
#      is one extra changed path per renamed file. Before this, the miss was a
#      LATENCY gap rather than a hole in what gates `main` — the unscoped
#      merge_group run still caught it before the default branch — but it made
#      a scoped `pull_request` run narrower than its own diff.
#
# ── Map format (workflows/scripts/config/gate-paths.tsv) ─────────────────
#   <key><TAB><glob>[ <glob> ...]
#   * `#` comments and blank lines ignored.
#   * <key> is a gate command EXACTLY as it appears in quality-gates.sh's
#     GATES array, or one of two reserved pseudo-keys:
#       ALL   — the globs listed escalate the run to the FULL set.
#       none  — the globs listed are RECOGNISED but affect no gate.
#   * <key> MAY ALSO BE A PATTERN (temperloop#2162) — a key carrying `*`, `?`
#     or `[` is matched against each gate command line as a shell glob, so ONE
#     row can map a whole FAMILY of gates. This exists because quality-gates.sh
#     now GLOB-EXPANDS two test directories into one gate per script: the whole
#     point of expanding at list time is that a newly added test_*.sh needs no
#     registry edit, and a map that demanded a hand-typed row per script would
#     have put that maintenance trap straight back (check-gate-paths.sh's
#     completeness check fails an unmapped gate). MATCHING ROWS ARE UNIONED,
#     never ranked: a gate is selected when ANY row that names it — its own
#     literal row, a pattern row that globs it, or both — was selected. A
#     single script inside an expanded family can therefore carry its own
#     pinpoint row for EXTRA triggers (which is exactly what the four
#     state-graph suites and test_dual_build_preflight.sh do) without that row
#     ever REMOVING the family row's triggers. A precedence here would narrow
#     — see the union rationale at the resolver's emit loop.
#   * The single token `ALWAYS` in place of a glob list marks a gate that runs
#     on every scoped run (a whole-tree scanner). An `ALWAYS` row contributes
#     NOTHING to path recognition — otherwise a whole-tree gate's `**` would
#     match every path and defense (1) above could never fire.
#   * `**` inside a glob means "any characters, including `/`"; so does `*`
#     (bash `[[ ]]` pattern matching is not path-component aware). Both forms
#     are accepted so a glob reads the way an author expects.
#
# Public entry point:
#   gate_selection_resolve   — reads the GATE_SELECTION_* inputs below and sets
#                              the GATE_SELECTION_MODE / _SELECTED / _REASON
#                              outputs. Never fails the caller: on any problem
#                              it degrades to mode=full with a stated reason.
#
# Inputs (globals, set by the caller before the call):
#   GATE_SELECTION_ROOT        repo root (git operations run with -C here)
#   GATE_SELECTION_MAP_FILE    path to gate-paths.tsv
#   GATE_SELECTION_ALL_GATES   newline-delimited full gate list, in run order
#   GATE_SELECTION_BASE        base ref/sha to diff against (caller passes
#                              $LEAK_GUARD_BASE — ci.yml already supplies it,
#                              so no second base-derivation path exists)
#   GATE_SELECTION_CHANGED     OPTIONAL caller-supplied changed-path set:
#                              newline-delimited paths used verbatim instead of
#                              running git. Two real callers: this suite's own
#                              fixture tests, and quality-gates.sh's `--scoped`
#                              mode, which hands in the LOCAL working-tree set
#                              gate_selection_local_changed() computes below.
#   GATE_SELECTION_DIFF_TEXT   OPTIONAL caller-supplied unified diff of
#                              scripts/quality-gates.sh, used VERBATIM by the
#                              registration-only probe (defense 3's exception)
#                              instead of running git. The fixture seam for
#                              this suite; no production caller sets it.
#
# Outputs (globals):
#   GATE_SELECTION_MODE        full | diff
#   GATE_SELECTION_REASON      one human-readable line explaining the mode
#   GATE_SELECTION_SELECTED    newline-delimited selected gates, in the input
#                              order (mode=diff only; empty when mode=full)
#   GATE_SELECTION_SKIPPED     newline-delimited gates the selection LEFT OUT,
#                              in the input order (mode=diff only). The
#                              complement of _SELECTED, computed here rather
#                              than re-derived by each caller, so a scoped run
#                              can NAME what it did not run — a green scoped
#                              run that cannot say what it skipped is
#                              indistinguishable from a green full one
#                              (temperloop#957).
#   GATE_SELECTION_MATCHED     newline-delimited changed paths that were
#                              recognised (diagnostics)
#   GATE_SELECTION_LOCAL_BASE  set by gate_selection_local_changed(): the base
#                              commit that resolution settled on (diagnostics)
#
# Second entry point:
#   gate_selection_local_changed <root>
#                              print the LOCAL working-tree changed set (see
#                              its own comment block). Non-zero, with a stderr
#                              line, when no base resolves — the caller must
#                              then degrade to the full set.
#   gate_selection_local_changed_to_file <root> <outfile>
#                              the same resolution, paths written to <outfile>,
#                              run in the CALLER'S shell so the
#                              GATE_SELECTION_LOCAL_BASE out-param survives
#                              (temperloop#1663 — a command substitution is a
#                              subshell and silently swallowed it).
#
# Settings:
#   QUALITY_GATES_SCOPE  auto (default) | full | diff.  `auto` scopes only on a
#     GitHub `pull_request` event; `full` disables scoping outright; `diff`
#     forces an attempt regardless of event (the local/CI test seam, and what
#     quality-gates.sh's `--scoped` flag sets).
#
# Kept bash-3.2-portable (macOS default shell): no associative arrays, no
# mapfile, no `${v,,}`.

# --- glob matching -----------------------------------------------------------
# `**` and `*` both mean "any characters including /": bash's `[[ str == pat ]]`
# is not path-component aware, so `docs/*` already matches `docs/a/b.md`. `**`
# is normalised to `*` purely so an author can write the intuitive form.
_gs_path_matches_glob() {
  # `cand_path`, not `path`: under zsh a `local path=` rebinds $PATH for the
  # scope (temperloop#40, enforced by scripts/lint-zsh-param-tie.sh).
  local cand_path="$1" glob="$2" star='*' pat
  pat="${glob//\*\*/$star}"
  # shellcheck disable=SC2053  # RHS is a glob on purpose
  [[ "$cand_path" == $pat ]]
}

# --- map loading -------------------------------------------------------------
# Fills the parallel arrays _GS_KEYS / _GS_GLOBS. Returns non-zero (with a
# stderr line) on a malformed row so the caller can degrade to the full set.
_gs_load_map() {
  local file="$1" line key globs
  _GS_KEYS=()
  _GS_GLOBS=()
  if [[ ! -f "$file" ]]; then
    printf 'gate-selection: map file not found: %s\n' "$file" >&2
    return 1
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    # Strip a trailing CR so a CRLF-checked-out map still parses.
    line="${line%$'\r'}"
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in
      *$'\t'*) : ;;
      *)
        printf 'gate-selection: malformed row (no TAB): %s\n' "$line" >&2
        return 1
        ;;
    esac
    key="${line%%$'\t'*}"
    globs="${line#*$'\t'}"
    if [[ -z "$key" || -z "$globs" ]]; then
      printf 'gate-selection: malformed row (empty key or glob list): %s\n' "$line" >&2
      return 1
    fi
    _GS_KEYS+=("$key")
    _GS_GLOBS+=("$globs")
  done <"$file"
  if [[ ${#_GS_KEYS[@]} -eq 0 ]]; then
    printf 'gate-selection: map file has no rows: %s\n' "$file" >&2
    return 1
  fi
  return 0
}

# --- changed-path resolution -------------------------------------------------
# `git diff --name-only <base>...HEAD` — the same three-dot form the PR leak
# guard uses, so both diff-scoped consumers see the same file set.
# `--no-renames` is defense 5 in the header: without it a rename lists only the
# DESTINATION path and the source tree's gates go unselected.
_gs_changed_paths() {
  local root="$1" base="$2"
  [[ -n "$base" ]] || return 1
  git -C "$root" rev-parse --verify --quiet "${base}^{commit}" >/dev/null 2>&1 || return 1
  git -C "$root" diff --no-renames --name-only "${base}...HEAD" 2>/dev/null || return 1
}

# --- LOCAL working-tree changed set (temperloop#957) --------------------------
# The CI path above diffs a PUSHED head against a supplied base. A /build item
# worker asking for a mid-work gate run has neither: its work is a mix of
# committed, staged, unstaged and brand-new files in a throwaway worktree, and
# nothing exports a base for it. So this helper resolves the base itself and
# unions the four sources — anything less would UNDER-run:
#
#   1. <merge-base(origin/<default>, HEAD)>...HEAD   the worker's commits
#   2. `git diff --name-only HEAD`                   staged + unstaged edits
#   3. `git ls-files --others --exclude-standard`    new, not-yet-added files
#
# (1) and (2) both carry `--no-renames` (defense 5): a worker who `git mv`s a
# file out of a gated tree — committed OR merely staged — must still select the
# SOURCE tree's gates, and rename detection would hide that path from both.
#
# (2) and (3) are what make this usable MID-work rather than only after a
# commit, and (3) is why a brand-new source file cannot hide from the selector.
# Ignored files are deliberately excluded via --exclude-standard: the build
# harness drops its own scratch (`.build-guard`, `.build-verification.md`) into
# the worktree root, and those are not changes to the tree under test.
#
# BASE RESOLUTION IS MANDATORY. If no base resolves, this returns non-zero and
# the caller degrades to the full set — it does NOT fall back to "the
# working-tree changes alone", which would silently hide every committed change
# and is exactly the silent-green class defense (2) in the header exists for.
# GATE_SELECTION_LOCAL_BASE is an OUT-PARAM read by the sourcing caller (the
# base this resolution settled on, reported in the run's own scope line), so
# the static linter's "appears unused" is a false positive — same blanket
# disable as gate_selection_resolve below.
# shellcheck disable=SC2034
# _gs_local_merge_base <root> — print the default-branch merge-base, or fail.
# THE one candidate walk: origin/HEAD when the remote advertises one, else the
# conventional names. Three callers share it (the two local-changed entry points
# and the registration probe's base fallback), and they MUST agree — a probe that
# resolved a different base than the changed set was computed against would
# classify a diff the selection never saw.
_gs_local_merge_base() {
  local root="${1:-.}" default_ref="" base="" cand
  git -C "$root" rev-parse --git-dir >/dev/null 2>&1 || return 1
  default_ref="$(git -C "$root" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  for cand in "$default_ref" origin/main origin/master main master; do
    [[ -n "$cand" ]] || continue
    if base="$(git -C "$root" merge-base "$cand" HEAD 2>/dev/null)" && [[ -n "$base" ]]; then
      printf '%s\n' "$base"
      return 0
    fi
  done
  return 1
}

gate_selection_local_changed() {
  local root="${1:-.}" base=""
  git -C "$root" rev-parse --git-dir >/dev/null 2>&1 || {
    printf 'gate-selection: %s is not a git checkout — cannot resolve a local changed set\n' "$root" >&2
    return 1
  }
  base="$(_gs_local_merge_base "$root" || true)"
  if [[ -z "$base" ]]; then
    printf 'gate-selection: no default-branch merge-base resolvable in %s\n' "$root" >&2
    return 1
  fi
  GATE_SELECTION_LOCAL_BASE="$base"
  {
    git -C "$root" diff --no-renames --name-only "${base}...HEAD" 2>/dev/null
    git -C "$root" diff --no-renames --name-only HEAD 2>/dev/null
    git -C "$root" ls-files --others --exclude-standard 2>/dev/null
  } | sort -u | grep -v '^$'
  return 0
}

# --- gate_selection_local_changed_to_file <root> <outfile> --------------------
# The same resolution as above, but the PATHS go to <outfile> and the function
# runs in the CALLER'S shell, so GATE_SELECTION_LOCAL_BASE actually survives.
#
# WHY THIS EXISTS (temperloop#1663). The out-param above is real but was
# unreachable: quality-gates.sh's only caller invoked it as
# `x="$(gate_selection_local_changed …)"`, and a command substitution is a
# SUBSHELL — the assignment died with it, so the base-disclosure line guarded by
# `[[ -n "$GATE_SELECTION_LOCAL_BASE" ]]` could never print. That line is the
# only place a scoped run names the tree state it scoped against, which is
# exactly what an operator needs when a run narrows more than they expected.
# Latent since #957; it became load-bearing when #1663 put scoping on the
# acceptance path.
#
# Returns non-zero (leaving <outfile> untouched) on the same no-base condition
# the sibling reports, so the caller degrades to the full set identically.
# GATE_SELECTION_LOCAL_BASE is an OUT-PARAM read by the sourcing caller — the
# same false positive the sibling above carries, and the same blanket disable.
# shellcheck disable=SC2034
gate_selection_local_changed_to_file() {
  local root="${1:-.}" out="$2" paths
  # The inner call still runs in a substitution, so re-do the base resolution
  # here rather than reading the sibling's out-param through the same trap this
  # function exists to avoid.
  paths="$(gate_selection_local_changed "$root")" || return 1
  # ...and recompute the base in THIS shell so the global lands where the caller
  # can see it. Cheap (one merge-base), and it cannot disagree with the sibling:
  # both call _gs_local_merge_base against the identical HEAD.
  local base=""
  base="$(_gs_local_merge_base "$root" || true)"
  GATE_SELECTION_LOCAL_BASE="$base"
  printf '%s\n' "$paths" >"$out" || return 1
  return 0
}

# --- the gate-REGISTRATION-only exception (temperloop#1933) ------------------
# scripts/quality-gates.sh sits on the ALL row, so registering ONE new gate line
# escalated the whole run to the ~110-gate set. A registration adds a gate; it
# does not change what an existing gate runs. The two helpers below are what let
# the selector tell those two diffs apart, and both fail CLOSED: anything they
# cannot read, or cannot prove is registration-only, keeps the ALL escalation.
_GS_QG_PATH="scripts/quality-gates.sh"
# `<NAME>_GATES+=("<literal command>")`, optionally indented. The literal is
# deliberately `$`- and backtick-free: a splat such as
# `KERNEL_GATES+=("${SELF_DISTRIBUTION_GATES[@]}")` registers gates whose names
# this probe cannot know, so it does NOT match and the diff escalates.
_GS_REG_LINE_RE='^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*_GATES\+=\("([^"$`]+)"\)[[:space:]]*$'
# ...and the OTHER registration site: a bare element of a `<NAME>_GATES=( … )`
# array literal (quality-gates.sh's own comment calls `KERNEL_GATES=(` "the ONE
# place this list is typed"), which diffs as `+  "make test-foo"` and would
# otherwise be the most idiomatic way to register a gate and the one shape the
# exception missed.
#
# Shape + membership is NOT sufficient for this form, because it carries no array
# name of its own. `SERIAL_LANE_PINS=( … )` and `SLOW_DISPATCH_HINTS=( … )` are
# two OTHER arrays in quality-gates.sh whose elements are bare quoted gate command
# lines that ARE in the run set, so a pure addition to either passed both tests.
# Neither is a registration: a serial-lane pin is a correctness-bearing
# concurrency decision (its own comment records temperloop#1379's MEASURED data
# race — six concurrent runs, four failures), and the narrow run it bought skipped
# `bash scripts/tests/test_quality_gates_parallel.sh`, precisely the gate that
# would prove a lane change safe. So a bare element must ALSO be positionally
# inside a gate array: the enclosing hunk header's funcname context must match
# _GS_REG_ARRAY_CTX_RE below. An unrecognised context fails CLOSED.
_GS_REG_ELEM_RE='^[[:space:]]*"([^"$`]+)"[[:space:]]*$'
# The hunk-header funcname that puts a bare element inside a gate array. git's
# default funcname heuristic reports the nearest preceding line beginning at
# column 0 with an alphabetic/`_`/`$` character — which for an addition ANYWHERE
# in `KERNEL_GATES=( … )` (all ~1740 lines of it) is that opening line itself;
# verified against the real file at both ends of the literal. The `--no-ext-diff`
# / `--no-textconv` pins at the call site keep that context git's own.
_GS_REG_ARRAY_CTX_RE='^[A-Za-z_][A-Za-z0-9_]*_GATES(\+)?=\([[:space:]]*$'

# _gs_qg_diff <root> <base> — print a unified diff of $_GS_QG_PATH, or fail.
# Unions the committed half (`<base>...HEAD`) with the working-tree half
# (`HEAD`), because a /build worker running `--scoped` mid-work may have the
# registration staged or merely saved rather than committed. A base that does
# not resolve is a FAILURE, not an empty diff: an empty diff would read as
# "nothing was removed" and narrow on no evidence at all.
#
# THE DIFF FORMAT IS PINNED AT THE CALL SITE, not inherited from the invoking
# developer's git config. FOUR knobs on this seam, all pinned:
#   * `diff.mnemonicPrefix=true` renders `--- c/… +++ w/…`, and
#   * `diff.noprefix=true` renders `--- path +++ path` — both overridden by
#     `--src-prefix`/`--dst-prefix`, which are portable further back than the
#     newer `--default-prefix`;
#   * a configured `diff.external` replaces the rendering wholesale —
#     `--no-ext-diff` neutralises it;
#   * a `.gitattributes` `diff=<driver>` whose driver sets `textconv` rewrites
#     the CONTENT of every line before git diffs it, which `--no-ext-diff` does
#     NOT disable — `--no-textconv` does.
# Under any of the four the classifier reads a header or a mangled literal as an
# added non-registration line and the exception silently never fires (it fails
# CLOSED, so no correctness hole, but a capability that never fires is
# indistinguishable from one that found nothing).
#
# `--no-renames` rides along for the SAME reason the changed-set diffs carry it
# (defense 5), one step further down: once the changed set lists a renamed-away
# source path, this probe can be handed a $_GS_QG_PATH that was renamed, and a
# rename-detected diff would show it as a small same-file delta. Without the
# flag, a rename INTO scripts/quality-gates.sh could therefore read as
# registration-only and decline the ALL escalation. Pinned, it renders as a
# whole-file add (or a delete), whose lines veto — it fails CLOSED like the rest.
_gs_qg_diff() {
  local root="$1" base="$2" committed="" worktree=""
  if [[ -n "${GATE_SELECTION_DIFF_TEXT+x}" ]]; then
    printf '%s\n' "$GATE_SELECTION_DIFF_TEXT"
    return 0
  fi
  [[ -n "$base" ]] || return 1
  git -C "$root" rev-parse --git-dir >/dev/null 2>&1 || return 1
  git -C "$root" rev-parse --verify --quiet "${base}^{commit}" >/dev/null 2>&1 || return 1
  committed="$(git -C "$root" diff --no-color --no-ext-diff --no-textconv --no-renames --src-prefix=a/ --dst-prefix=b/ -U0 "${base}...HEAD" -- "$_GS_QG_PATH" 2>/dev/null)" || return 1
  worktree="$(git -C "$root" diff --no-color --no-ext-diff --no-textconv --no-renames --src-prefix=a/ --dst-prefix=b/ -U0 HEAD -- "$_GS_QG_PATH" 2>/dev/null)" || return 1
  printf '%s\n%s\n' "$committed" "$worktree"
  return 0
}

# _gs_registration_only <diff-text> — classify the diff.
# On success prints the newly registered gate commands, one per line. Fails
# (leaving the ALL escalation in place) when the diff removes ANY line, adds any
# line that is not a registration / comment / blank, or contains no registration
# at all. That last clause is why a comment-only or whitespace-only diff still
# escalates: the exception is for REGISTERING a gate, not for editing the file.
_gs_registration_only() {
  local diff_text="$1" line body lead stripped hunk_ctx found=0 gates=""
  local in_hunk=0 elem_ok=0
  while IFS= read -r line; do
    # `diff --git …` and `@@…` are the two lines that can be recognised ANYWHERE,
    # including mid-hunk: a REMOVED line always carries a leading `-`, so neither
    # shape can be one. That is what lets the two halves of the unioned diff be
    # read in a single pass, and it is why the hunk state below can be trusted.
    case "$line" in
      'diff --git '*) in_hunk=0; elem_ok=0; continue ;;
      '@@'*)
        in_hunk=1
        # `@@ -a,b +c,d @@ <funcname context>` — strip through the second `@@ `.
        # A hunk header with NO context leaves $hunk_ctx as the whole line, which
        # matches no array and correctly denies the bare-element shape.
        hunk_ctx="${line#@@ *@@ }"
        if [[ $hunk_ctx =~ $_GS_REG_ARRAY_CTX_RE ]]; then elem_ok=1; else elem_ok=0; fi
        continue
        ;;
    esac
    # Every OTHER header shape is recognised only BEFORE the first `@@` of a file.
    # Matching them on prefix alone at any position swallowed a real removal: with
    # `-U0` a removed line whose content begins `-- a/` renders as `--- a/…` and a
    # removed `++ b/…` as `+++ b/…`, so the header skip ran first and the removal
    # never got to veto. Gating on "not yet inside a hunk" makes that structural
    # rather than a bet on what content quality-gates.sh happens to hold.
    if [[ $in_hunk -eq 0 ]]; then
      case "$line" in
        'index '*|'--- a/'*|'--- /dev/null'|'+++ b/'*|'+++ /dev/null') continue ;;
        'old mode '*|'new mode '*|'new file mode '*|'deleted file mode '*) continue ;;
        'similarity index '*|'rename from '*|'rename to '*) continue ;;
      esac
    fi
    case "$line" in
      -*) return 1 ;;   # a REMOVED line — never registration-only
      +*) : ;;
      *)  continue ;;   # context, `\ No newline...`, or padding between halves
    esac
    body="${line#+}"
    if [[ $body =~ $_GS_REG_LINE_RE ]]; then
      found=1
      gates="${gates:+$gates$'\n'}${BASH_REMATCH[1]}"
      continue
    fi
    # The bare-element form ONLY inside a `<NAME>_GATES=( … )` literal — see
    # _GS_REG_ELEM_RE's comment: SERIAL_LANE_PINS / SLOW_DISPATCH_HINTS elements
    # are gate-shaped AND members of the run set, and are not registrations.
    if [[ $elem_ok -eq 1 ]] && [[ $body =~ $_GS_REG_ELEM_RE ]]; then
      found=1
      gates="${gates:+$gates$'\n'}${BASH_REMATCH[1]}"
      continue
    fi
    lead="${body%%[![:space:]]*}"
    stripped="${body#"$lead"}"
    case "$stripped" in
      ''|'#'*) continue ;;   # a blank or comment line rides along
    esac
    return 1
  done <<<"$diff_text"
  [[ $found -eq 1 ]] || return 1
  printf '%s\n' "$gates"
  return 0
}

# --- membership over a newline-delimited set ---------------------------------
_gs_in_list() {
  local needle="$1" list="$2" item
  while IFS= read -r item; do
    [[ "$item" == "$needle" ]] && return 0
  done <<<"$list"
  return 1
}

# --- key/gate matching (exact, or a PATTERN key — temperloop#2162) -----------
# `_gs_key_is_pattern <key>` is the single place that decides what makes a key
# a pattern, so the map loader, the resolver and check-gate-paths.sh cannot
# drift on that question.
_gs_key_is_pattern() {
  case "$1" in
    *'*'*|*'?'*|*'['*) return 0 ;;
    *) return 1 ;;
  esac
}

# `_gs_key_matches_gate <key> <gate>` — true when the row keyed <key> governs
# the gate command <gate>. A literal key matches only itself; a pattern key
# matches as a shell glob. It is deliberately a MEMBERSHIP predicate with no
# ranking: the resolver unions every row that answers true here, because a
# precedence between a pinpoint row and the family row that globs it can only
# resolve toward LESS coverage (see the emit loop's union rationale).
_gs_key_matches_gate() {
  local key="$1" gate="$2"
  [[ "$key" == "$gate" ]] && return 0
  if _gs_key_is_pattern "$key"; then
    # shellcheck disable=SC2053  # RHS is a glob on purpose
    [[ "$gate" == $key ]] && return 0
  fi
  return 1
}

# --- the selection itself ----------------------------------------------------
# GATE_SELECTION_MODE / _REASON / _SELECTED / _MATCHED are OUT-PARAMS: written
# here, read by the sourcing caller (this is a sourced lib, not a program), so
# the static linter's "appears unused" is a false positive for the whole
# function — same blanket disable as gate-retry.sh's gate_run_with_retry.
# shellcheck disable=SC2034
gate_selection_resolve() {
  GATE_SELECTION_MODE="full"
  GATE_SELECTION_REASON=""
  GATE_SELECTION_SELECTED=""
  GATE_SELECTION_SKIPPED=""
  GATE_SELECTION_MATCHED=""

  local scope="${QUALITY_GATES_SCOPE:-auto}"
  local event="${GITHUB_EVENT_NAME:-}"  # setting:exempt — GitHub Actions' own ambient event name, not an operator default this repo defines
  case "$scope" in
    full)
      GATE_SELECTION_REASON="full set — QUALITY_GATES_SCOPE=full"
      return 0
      ;;
    diff) : ;;
    auto)
      if [[ "$event" != "pull_request" ]]; then
        GATE_SELECTION_REASON="full set — event '${event:-<none>}' is not pull_request (scoping applies to pull_request only)"
        return 0
      fi
      ;;
    *)
      GATE_SELECTION_REASON="full set — unrecognised QUALITY_GATES_SCOPE='$scope' (expected auto|full|diff)"
      return 0
      ;;
  esac

  # The GATE_SELECTION_* globals below are this lib's CALL INTERFACE — set by
  # the caller immediately before the call, never operator-tunable settings —
  # so they are read once into locals here and marked exempt from the
  # setting-registry sweep (check-setting-registry.sh's own
  # "internal/derived/computed values" category).
  local root="${GATE_SELECTION_ROOT:-.}"     # setting:exempt — internal call-interface global, set by the caller
  local map="${GATE_SELECTION_MAP_FILE:-}"   # setting:exempt — internal call-interface global, set by the caller
  local all="${GATE_SELECTION_ALL_GATES:-}"  # setting:exempt — internal call-interface global, set by the caller
  local base="${GATE_SELECTION_BASE:-}"      # setting:exempt — internal call-interface global, set by the caller
  if [[ -z "$all" ]]; then
    GATE_SELECTION_REASON="full set — no gate list supplied to the selector"
    return 0
  fi

  local changed
  if [[ -n "${GATE_SELECTION_CHANGED+x}" ]]; then
    changed="$GATE_SELECTION_CHANGED"
  else
    if ! changed="$(_gs_changed_paths "$root" "$base")"; then
      GATE_SELECTION_REASON="full set — no resolvable diff base (base='$base')"
      return 0
    fi
  fi
  if [[ -z "$changed" ]]; then
    GATE_SELECTION_REASON="full set — the diff against '$base' resolved zero changed paths"
    return 0
  fi

  if ! _gs_load_map "$map"; then
    GATE_SELECTION_REASON="full set — gate-path map unusable (see the line above)"
    return 0
  fi

  # The registration-only probe (temperloop#1933), run ONCE before the path
  # loop.
  #
  # RESOLVING THE PROBE'S BASE IS THREE-STEP, and every step is load-bearing:
  #   1. $base — the CI path's $LEAK_GUARD_BASE, and the fixture suite's.
  #   2. $GATE_SELECTION_LOCAL_BASE — set by gate_selection_local_changed_to_file
  #      on a local `--scoped` FIRST slice, whose $base is empty.
  #   3. a merge-base resolved right here, the same walk (1)/(2) use.
  # (3) is not belt-and-braces: it is what makes the exception reachable on the
  # DEFAULT /build path at all. scripts/quality-gates.sh re-initialises
  # GATE_SELECTION_LOCAL_BASE="" per process and only its first-slice branch
  # fills it; slice 2..N reuses the PINNED changed set (temperloop#1663) and never
  # calls that function, so steps (1) and (2) are BOTH empty there. Without (3)
  # slice 1 would narrow, slice 2 would escalate, and the #1663 drift guard would
  # see the fingerprint move and RESTART FROM GATE 0 ON THE FULL SET — costing
  # more gate time than never having narrowed, under a note that misattributes
  # the cause to a moved working tree. (3) is cheap (one merge-base) and cannot
  # disagree with (2): the identical candidate walk against the identical HEAD.
  local _gs_reg_only=0 _gs_reg_gates="" _gs_qg_diff_text=""
  local _gs_qg_base="${base:-${GATE_SELECTION_LOCAL_BASE:-}}"  # setting:exempt — internal call-interface global set by gate_selection_local_changed(), not an operator default
  if _gs_in_list "$_GS_QG_PATH" "$changed"; then
    [[ -n "$_gs_qg_base" ]] || _gs_qg_base="$(_gs_local_merge_base "$root" || true)"
    if _gs_qg_diff_text="$(_gs_qg_diff "$root" "$_gs_qg_base")" &&
       _gs_reg_gates="$(_gs_registration_only "$_gs_qg_diff_text")"; then
      _gs_reg_only=1
    else
      _gs_reg_gates=""
    fi
  fi
  # EVERY captured literal must be a gate the caller's own list already carries.
  # Two holes close together here, and this is the load-bearing half of the
  # classifier rather than a tidy-up:
  #   * FAIL-OPEN. `<NAME>_GATES` also matches SKIPPED_KERNEL_GATES, a
  #     skip-DISCLOSURE array whose elements are human sentences, not commands
  #     (`SKIPPED_KERNEL_GATES+=("test_update_kernel.sh — …")`). A diff adding one
  #     is not a registration at all, yet it read as one and declined the ALL row
  #     — the one direction this exception must never fail in.
  #   * PHANTOM GATES. A captured literal that is not a real gate was unioned into
  #     $selected, dropped later for not being in $all, but still counted in the
  #     "+N gate(s)" the reason line shows an operator.
  # Membership is preferred over anchoring the accepted array names because it is
  # SELF-MAINTAINING: a new run-set array needs no edit here, and a new
  # disclosure-shaped array cannot sneak in.
  if [[ $_gs_reg_only -eq 1 ]]; then
    local _gs_cap
    while IFS= read -r _gs_cap; do
      [[ -n "$_gs_cap" ]] || continue
      _gs_in_list "$_gs_cap" "$all" && continue
      _gs_reg_only=0
      _gs_reg_gates=""
      break
    done <<<"$_gs_reg_gates"
  fi

  local selected="" matched="" chg_path i key globs glob hit any_recognised
  local _gs_glob_list=()
  while IFS= read -r chg_path; do
    [[ -n "$chg_path" ]] || continue
    any_recognised=0
    i=0
    while [[ $i -lt ${#_GS_KEYS[@]} ]]; do
      key="${_GS_KEYS[$i]}"
      globs="${_GS_GLOBS[$i]}"
      i=$((i + 1))
      # An ALWAYS row is not a recogniser — see the header. Its gate is added
      # unconditionally further down.
      [[ "$globs" == "ALWAYS" ]] && continue
      # temperloop#1933: skip the ALL row for a registration-only
      # quality-gates.sh diff, and ONLY for that path. Every other ALL glob on
      # the row — the Makefile, this lib, the map itself — still escalates, and
      # quality-gates.sh still has to be recognised by a real (non-ALWAYS) row
      # below or the unmapped-path default fires as usual.
      if [[ $_gs_reg_only -eq 1 && "$key" == "ALL" && "$chg_path" == "$_GS_QG_PATH" ]]; then
        continue
      fi
      hit=0
      # `read -r -a` splits on IFS WITHOUT pathname expansion. A bare
      # `for glob in $globs` would let the shell expand `docs/**` against the
      # working directory before the matcher ever saw it — silently replacing
      # the author's glob with whatever happens to exist on disk.
      read -r -a _gs_glob_list <<<"$globs"
      for glob in "${_gs_glob_list[@]}"; do
        if _gs_path_matches_glob "$chg_path" "$glob"; then hit=1; break; fi
      done
      [[ $hit -eq 1 ]] || continue
      any_recognised=1
      case "$key" in
        ALL)
          GATE_SELECTION_REASON="full set — changed path '$chg_path' matches an ALL escalation glob ('$glob')"
          return 0
          ;;
        none) : ;;  # recognised, affects no gate
        *)
          _gs_in_list "$key" "$selected" || selected="${selected:+$selected$'\n'}$key"
          ;;
      esac
    done
    if [[ $any_recognised -eq 0 ]]; then
      GATE_SELECTION_REASON="full set — changed path '$chg_path' matches no glob in the gate-path map (default-to-full on an unmapped path)"
      return 0
    fi
    matched="${matched:+$matched$'\n'}$chg_path"
  done <<<"$changed"

  # Union in the gates the registration-only diff just REGISTERED. They are in
  # $all already — the caller built that list from the same edited file — so
  # naming them here is what makes a new gate RUN on the very PR that adds it,
  # rather than first running on the next unrelated full set.
  if [[ $_gs_reg_only -eq 1 && -n "$_gs_reg_gates" ]]; then
    local _gs_new_gate
    while IFS= read -r _gs_new_gate; do
      [[ -n "$_gs_new_gate" ]] || continue
      _gs_in_list "$_gs_new_gate" "$selected" || selected="${selected:+$selected$'\n'}$_gs_new_gate"
    done <<<"$_gs_reg_gates"
  fi

  # Emit in the caller's run order, and keep any gate the map does not mention
  # (defense 4 in the header: an unmapped gate over-runs, never under-runs).
  local gate ordered="" left_out="" mapped always keep mapped_keys _gs_mkey
  while IFS= read -r gate; do
    [[ -n "$gate" ]] || continue
    mapped=0
    always=0
    mapped_keys=""
    # EVERY row that names this gate, UNIONED — never a precedence
    # (temperloop#2162; the exact-wins precedence this replaces shipped in the
    # first cut of that item and is the bug it fixes).
    #
    # A gate inside a glob-expanded family may ALSO carry its own pinpoint row,
    # and the two rows carry DIFFERENT trigger sets: the pinpoint row names
    # paths the family row does not glob (test_state_graph_soak.sh's row names
    # workflows/scripts/config/ontology-registry.tsv), and the family row globs
    # paths the pinpoint row does not name (all of workflows/scripts/build/**).
    # Letting the exact row WIN — on the reasoning that the family row would
    # otherwise "silently widen" a pinpoint gate — inverts the one invariant
    # this selector states about itself: every unresolved case resolves TOWARD
    # MORE coverage, never less (the header's five silent-green defenses, and
    # quality-gates.sh's own "resolves TOWARD MORE coverage, never less").
    # WIDENING is the safe direction here; NARROWING is the silent-green one,
    # and exact-wins narrowed for real — a one-file
    # `workflows/scripts/build/pr.sh` diff stopped selecting the four
    # state-graph suites and test_dual_build_preflight.sh, which the umbrella
    # row had always run, on CI too (`checks` is itself diff-scoped).
    #
    # So: collect EVERY matching key and keep the gate if ANY of them was
    # selected. The union is a strict superset of either row alone, so the
    # pinpoint row keeps its extra triggers and the family row keeps its reach.
    i=0
    while [[ $i -lt ${#_GS_KEYS[@]} ]]; do
      if _gs_key_matches_gate "${_GS_KEYS[$i]}" "$gate"; then
        mapped=1
        mapped_keys="${mapped_keys:+$mapped_keys$'\n'}${_GS_KEYS[$i]}"
        [[ "${_GS_GLOBS[$i]}" == "ALWAYS" ]] && always=1
      fi
      i=$((i + 1))
    done
    keep=0
    if [[ $mapped -eq 0 ]]; then
      keep=1                       # unmapped gate — over-run, never under-run
    elif [[ $always -eq 1 ]]; then
      keep=1                       # whole-tree scanner — runs every scoped run
    elif _gs_in_list "$gate" "$selected"; then
      # The gate's own command line is in $selected. That happens on a
      # registration-only diff, whose union names REAL gate command lines
      # rather than row keys.
      keep=1
    else
      # Selected through ANY row that names this gate — its own pinpoint row,
      # the family pattern row that globs it, or both.
      while IFS= read -r _gs_mkey; do
        [[ -n "$_gs_mkey" ]] || continue
        if _gs_in_list "$_gs_mkey" "$selected"; then keep=1; break; fi
      done <<<"$mapped_keys"
    fi
    if [[ $keep -eq 1 ]]; then
      ordered="${ordered:+$ordered$'\n'}$gate"
    else
      left_out="${left_out:+$left_out$'\n'}$gate"
    fi
  done <<<"$all"

  GATE_SELECTION_MODE="diff"
  GATE_SELECTION_SELECTED="$ordered"
  GATE_SELECTION_SKIPPED="$left_out"
  GATE_SELECTION_MATCHED="$matched"
  local n_changed n_sel n_all
  n_changed="$(printf '%s\n' "$changed" | grep -c . || true)"
  n_sel="$(printf '%s\n' "$ordered" | grep -c . || true)"
  n_all="$(printf '%s\n' "$all" | grep -c . || true)"
  GATE_SELECTION_REASON="diff-scoped — ${n_changed} changed path(s) vs '${base:-<seeded>}' select ${n_sel}/${n_all} gate(s)"
  # A run that declined an ALL escalation must SAY so — a scoped run that
  # silently skipped the escalation is indistinguishable from one whose diff
  # never touched the gate machinery at all (the legible-degradation rule).
  if [[ $_gs_reg_only -eq 1 ]]; then
    local n_reg
    n_reg="$(printf '%s\n' "$_gs_reg_gates" | grep -c . || true)"
    GATE_SELECTION_REASON="${GATE_SELECTION_REASON}; ${_GS_QG_PATH} is a REGISTRATION-ONLY diff (+${n_reg} gate(s), nothing removed) so its ALL escalation was declined in favour of the registry validators (temperloop#1933)"
  fi
  return 0
}
