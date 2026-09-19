#!/usr/bin/env bash
#
# count-prose.sh — kernel prose-plane baseline counter (temperloop#719, item
# prose-baseline-measurement / #722).
#
# Reports the two numbers the two-tier CI budget gate (docs/adr/
# 0015-prose-plane-budget-gate.md, item prose-budget-gate / #725) seeds its
# caps from:
#
#   TIER-1 — line count of the composed KERNEL-AUTHORED render only:
#            claude/CLAUDE.kernel.md rendered through the existing compose
#            seam (workflows/scripts/install-claude-md.sh's own
#            render_kernel_doc, invoked via its INSTALL_CLAUDE_MD_KERNEL_ONLY
#            render-only mode) — never a second, duplicated compose
#            implementation living in this script (ADR 0015). The
#            host-rendered "## Knowledge store routing" section and the
#            personal `claude/CLAUDE.overlay.md` are excluded — this is the
#            kernel-authored surface alone, never the kernel+overlay total.
#   TIER-2 — a line count for every tracked file matching `claude/**/*.md`
#            (agent charters under claude/agents/ included), plus the sum
#            across all of them.
#
# Usage:
#   workflows/scripts/count-prose.sh
#
# Stranger-clean: no vault/overlay/org dependency. This script and the seam
# it calls read only tracked repo files (claude/CLAUDE.kernel.md,
# workflows/scripts/install-claude-md.sh, workflows/scripts/build/
# build.config.sh) — it never reads claude/CLAUDE.overlay.md, the knowledge
# store, or the operator's friction ledger.
#
# Host determinism (verified in CI by workflows/scripts/tests/
# test_count_prose.sh, which runs on both the ubuntu-latest and
# macos-latest CI legs, matching whatever host authored the numbers):
#   - BUILD_CONFIG_MACHINE and BUILD_CONFIG_LOCAL are pinned to /dev/null
#     before invoking the compose seam. build.config.sh sources both paths
#     (precedence layers 3/4) only `if [ -f "$path" ]`; /dev/null is never a
#     regular file, so both sourcing blocks silently no-op regardless of
#     what a real host's XDG machine conf or a checkout's untracked
#     build.config.local.sh contain. This neutralizes the two config-FILE
#     layers (3/4) to the TRACKED repo defaults (layer 5) only.
#   - THIS PROCESS'S OWN ENVIRONMENT is also scrubbed of every
#     build.config.sh setting name before invoking the seam — layer 2 (an
#     exported env var) OUTRANKS layer 5's tracked `:=` default, so an
#     inherited `EPIC_MIN_SUBUNITS`/`DISPLAY_TZ` (e.g. from a pipeline-drive
#     session, or a caller's own shell) would otherwise flow straight
#     through the `:=` idiom and perturb the render even with layers 3/4
#     neutralized above. `build-config-settings.sh` is the SSOT-derived name
#     list (temperloop#1241 — the same mechanism build-level.mjs's 3e.5 gate
#     already uses to make `quality-gates.sh` hermetic under pipeline-drive);
#     unsetting every name it prints, rather than hand-listing
#     EPIC_MIN_SUBUNITS/DISPLAY_TZ ourselves, means a future setting addition
#     to build.config.sh is covered here with no edit to this script.
#   - Combined, the {{EPIC_MIN_SUBUNITS}} / {{DISPLAY_TZ}} setting substitution
#     baked into the kernel doc's rendered text is identical on every host
#     and every CI runner — no machine-specific override, checkout-local
#     override, OR inherited-env override can perturb the tier-1 number.
#   - Tracked-file enumeration goes through `git ls-files` (never a
#     filesystem glob), so an untracked scratch file dropped under claude/
#     on the authoring host can never inflate tier-2 relative to a clean CI
#     checkout.
#   - Line counts use `wc -l`, trimmed of the leading-whitespace padding
#     BSD `wc` prints (macOS) that GNU `wc` (Linux CI) does not, so the
#     printed number is identical text on both OS families, not just
#     numerically equal.
#
# SESSION-START CONTRIBUTORS (temperloop#827, epic #810's sub-item "P1" —
# epic #810's OWN Produces-list numbering, "P1"/"P7"/etc., a DIFFERENT axis
# from docs/adr/0018-measure-session-cost-before-gating.md's Phase A/Phase B
# split of the same epic; everything P-numbered belongs to Phase A — the
# "session-start context budget" design brief): a THIRD report section, driven
# entirely by the tracked manifest workflows/scripts/config/
# contributor-manifest.tsv rather than by code — a new session-start
# contributor is a manifest ROW, never a script change (unless it needs a
# `unit` this script does not implement yet; see the tsv's own header for
# the closed set). Reports each contributor in BYTES (not lines — the unit
# temperloop#719/#722's own postmortem showed can move 0 lines on a
# +2,260 B commit) plus a re-derived byte->token proxy ratio. This section
# extends the determinism contract above to the new unit: `wc -c` (byte
# counts) is trimmed of the same BSD-vs-GNU padding as `wc -l`, and `LC_ALL=C`
# (set globally, below) pins `wc -w`'s locale-sensitive whitespace
# classification the same way. THIS SCRIPT's own contributor loop reads each
# manifest path straight off the working tree (`[ -f "$c_path" ]`, `wc -c`) —
# it does NOT itself re-verify trackedness via `git ls-files`. The guarantee
# that a HOST-STATE contributor (e.g. the machine-global ~/.claude/agents
# install surface) can never enter this report belongs entirely to
# check-contributor-manifest.sh's tracked-path invariant (wired into
# scripts/quality-gates.sh) — a manifest row is only as trustworthy as that
# lint having run and passed; this script takes the tsv's path list on
# faith and re-derives only the BYTE COUNT at each of those paths, never the
# path list itself.
#
# LOAD-CLASS BUCKETING (temperloop#826 coverage spike): "session-start" is
# not one load class. The spike verified empirically (Claude Code 2.1.220)
# that AGENTS.md is NOT harness-auto-loaded — it arrives only on turn 1,
# because the auto-loaded root CLAUDE.md's own prose instructs the agent to
# read it. Summing a future `pointer-turn1` row into the same total as a
# `harness-auto` row would move the number without moving the underlying
# cost — the exact metric error ADR 0018 was written against. So this
# report BUCKETS by the manifest's `load` column and only folds the
# `harness-auto` bucket into "SESSION-START CONTRIBUTOR TOTAL" / the
# byte->token ratio; every row shipped by this item is `harness-auto`, and
# any other bucket that appears later (temperloop#836, turn-1 contributor
# rows, e.g. AGENTS.md) gets its own labeled subtotal, never silently
# merged in.
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

: "${COUNT_PROSE_ROOT:=$REPO_ROOT}"  # setting:exempt — test/fixture root override (mirrors FEATURE_DOCS_ROOT/KERNEL_MANIFEST_ROOT), not an operator-facing config-precedence default
kernel_doc="$COUNT_PROSE_ROOT/claude/CLAUDE.kernel.md"
install_script="$COUNT_PROSE_ROOT/workflows/scripts/install-claude-md.sh"
: "${CONTRIBUTOR_MANIFEST_TSV:=$COUNT_PROSE_ROOT/workflows/scripts/config/contributor-manifest.tsv}"  # setting:exempt — same fixture-root class as COUNT_PROSE_ROOT itself, not an operator-facing config-precedence default

[ -f "$kernel_doc" ] || { echo "count-prose: kernel doc not found: $kernel_doc" >&2; exit 1; }
[ -f "$install_script" ] || { echo "count-prose: compose seam not found: $install_script" >&2; exit 1; }
if [ ! -d "$COUNT_PROSE_ROOT/.git" ] && [ ! -f "$COUNT_PROSE_ROOT/.git" ]; then
  echo "count-prose: $COUNT_PROSE_ROOT is not a git checkout" >&2
  exit 1
fi
# The contributor manifest is a SOFT dependency, unlike kernel_doc/
# install_script/COUNT_PROSE_ROOT above: this script is also invoked by
# validate-prose-budget.sh (directly, and via that script's own fixture
# suite) against MINIMAL scratch COUNT_PROSE_ROOT trees that exercise only
# TIER-1/TIER-2 and were never given a contributor-manifest.tsv or a
# claude/commands+agents tree of their own — those callers care about
# tier-1/tier-2 alone and must keep working unmodified. So a missing
# manifest degrades the SESSION-START CONTRIBUTORS section to a skipped,
# clearly-labeled no-op (never a script-wide exit 1) — contrast the three
# checks above, which this script cannot run AT ALL without.
contributor_manifest_available=1
[ -f "$CONTRIBUTOR_MANIFEST_TSV" ] || contributor_manifest_available=0

# lines_in <file> — echo a file's line count, trimmed. BSD `wc -l` (macOS)
# right-pads its count with leading spaces; GNU `wc -l` (Linux) does not —
# strip whitespace so the two OS families print byte-identical text, not
# just numerically equal counts.
lines_in() {
  wc -l <"$1" | tr -d '[:space:]'
}

# bytes_in <file> — echo a file's byte count, trimmed. BSD `wc -c` (macOS)
# right-pads its count exactly like BSD `wc -l` does — same trim, new unit.
bytes_in() {
  wc -c <"$1" | tr -d '[:space:]'
}

# words_in <file> — echo a file's whitespace-delimited word count, trimmed.
# Same BSD/GNU padding-trim contract as lines_in/bytes_in above, stated once
# here rather than duplicated inline at each `wc -w` call site.
words_in() {
  wc -w <"$1" | tr -d '[:space:]'
}

# bytes_of <string> — echo the byte length of a STRING (not a file), for a
# value already extracted from a file (e.g. a frontmatter scalar) rather
# than measured as a whole file. `printf '%s'` (never `echo`) so the value
# is passed through with no added trailing newline of its own to count.
bytes_of() {
  printf '%s' "$1" | wc -c | tr -d '[:space:]'
}

# words_of <string> — echo the whitespace-delimited word count of a STRING.
# The session-start byte->token proxy ratio (below) uses word count as its
# token-count side: Phase A adds no tokenizer dependency (design brief
# dimension 6 — "no network, no tokenizer"), and word count is a live,
# content-dependent measure recomputed from the same text the byte count
# comes from, never a fixed conversion constant.
words_of() {
  printf '%s' "$1" | wc -w | tr -d '[:space:]'
}

# frontmatter_description <file> — echo the single-line YAML scalar value
# of a file's `description:` frontmatter field (between the leading `---`
# fences), trailing whitespace trimmed. Every claude/commands/*.md and
# claude/agents/**/*.md file in this repo keeps `description:` as an
# unfolded, unquoted, single-line scalar — a YAML block (`|`) or folded
# (`>`) style indicator on that line is REJECTED, not silently accepted: an
# earlier version of this comment claimed check-contributor-manifest.sh's
# field-presence check alone would catch that case, which was FALSE — a
# presence-only check is satisfied by `description: >` just as much as by a
# real one-line value, and only its FIRST continuation line would then be
# read as the entire (usually ~1-byte) value, silently skewing both the
# byte total and the byte->token ratio this item exists to establish. Two
# independent guards now exist instead, deliberately not sharing a single
# point of failure: check-contributor-manifest.sh's lint rejects a
# block/folded row before it ever reaches this script, AND this script's own
# caller (see the `frontmatter:description` case arm below) re-checks the
# extracted value against the same bare-indicator pattern and fails loudly
# rather than trusting the lint alone.
frontmatter_description() {
  awk '
    NR==1 && $0=="---" { infm=1; next }
    infm && $0=="---" { exit }
    infm && /^description:/ {
      sub(/^description: ?/, "")
      sub(/[ \t]+$/, "")
      print
      exit
    }
  ' "$1"
}

# _cp_is_block_scalar <value> — bash-3.2-safe test (`[[ =~ ]]`, a builtin,
# not an external tool) for whether a frontmatter scalar VALUE is a bare
# YAML block (`|`) or folded (`>`) style indicator — optionally followed by
# a chomping indicator (`+`/`-`) and/or a single-digit explicit indentation
# indicator, and nothing else. This is the shape `description: >` /
# `description: |-` / `description: >2` take once the leading
# `description: ` prefix is stripped — a real one-line description never
# legitimately consists of ONLY one of these two characters.
_cp_is_block_scalar() {
  [[ "$1" =~ ^[\|\>][+-]?[0-9]?$ ]]
}

# ---------------------------------------------------------------------------
# TIER-1 — the composed kernel-authored render, through the compose seam's
# own render-only mode (never a duplicated render here).
# ---------------------------------------------------------------------------
scratch="$(mktemp -d "${TMPDIR:-/tmp}/count-prose.XXXXXX")"
# _count_prose_cleanup — preserves the script's real exit status through
# cleanup. A bare `trap 'rm -rf "$scratch"' EXIT` replaces $? with `rm`'s
# own (successful) exit code, so a genuine failure anywhere above (e.g. an
# `unbound variable` under `set -u` on bash 3.2) would silently report exit
# 0 to every caller, including scripts/quality-gates.sh's KERNEL_GATES
# runner and validate-prose-budget.sh's rc check — exactly the silent-skip
# failure mode this script's entire purpose (honest measurement) exists to
# avoid. A NAMED function, rather than an inline `trap '…; exit $rc' EXIT`
# string, sidesteps a shellcheck false positive (SC2154 "rc is referenced
# but not assigned") that idiom triggers even though the assignment and
# use are both present and correctly ordered — verified against a minimal
# reproduction; this shape is shellcheck-clean.
_count_prose_cleanup() {
  local rc=$?
  rm -rf "$scratch"
  exit "$rc"
}
trap _count_prose_cleanup EXIT

# Scrub every build.config.sh setting NAME from this process's own environment
# before invoking the seam (see the header determinism note above — layer 2
# outranks the layer-3/4 file-pinning below, so an inherited exported setting
# must be unset here too).
#
# The scrub is BEST-EFFORT hygiene, so its exit status must not reach this
# script's own (temperloop#2142). The comment that used to sit here claimed "a
# missing/older helper prints nothing -> `unset` with no args is a harmless
# no-op"; that premise is FALSE in zsh, where a zero-argument `unset` errors
# (rc=1), and ANY non-zero `unset` -- e.g. a printed name that collides with a
# `readonly` parameter -- is non-zero in bash too, which this file's `set -e`
# would turn into an abort. Not live today: this file carries a bash shebang and
# the gate invokes it as `bash`. But the byte-identical form in
# build-level.mjs's emitted gate command DID fabricate an `acceptance-gate-failed`
# under zsh, so the form is fixed here as well rather than left as a loaded gun
# for whoever re-hosts or `source`s this. The rule is enforced mechanically for
# build-level.mjs only (the K2142 guard in test_workflow.sh); the repo-wide lint
# that would cover this file too is temperloop#2157. `-v` restricts the scrub to
# variables so bash cannot fall through to a same-named function; `__cp_noop`
# keeps the argument list non-empty.
settings_bin="$COUNT_PROSE_ROOT/workflows/scripts/build/build-config-settings.sh"
# shellcheck disable=SC2046  # intentional word-splitting: unset takes N bare NAME args, one per line from build-config-settings.sh
unset -v __cp_noop $(bash "$settings_bin" 2>/dev/null) || :

tier1_target="$scratch/kernel-only.md"
# The overlay path is never read or existence-checked when
# INSTALL_CLAUDE_MD_KERNEL_ONLY=1 (see install-claude-md.sh) — passed here
# only to satisfy the script's positional-arg contract.
BUILD_CONFIG_MACHINE=/dev/null \
BUILD_CONFIG_LOCAL=/dev/null \
INSTALL_CLAUDE_MD_KERNEL_ONLY=1 \
  "$install_script" "$kernel_doc" "$scratch/unused-overlay.md" "$tier1_target"

tier1_count="$(lines_in "$tier1_target")"

# ---------------------------------------------------------------------------
# TIER-2 — per-file line counts over every TRACKED claude/**/*.md file
# (git ls-files, never a filesystem glob — see the determinism note above).
# ---------------------------------------------------------------------------
cd "$COUNT_PROSE_ROOT" || exit 1

# Captured into a variable (never a `< <(process substitution)`) so a real
# failure anywhere in the pipeline is actually checked: a process
# substitution's own exit status is NOT observed by the `while read ... done
# < <(...)` construct that consumes it (a well-known bash gotcha — the loop
# only ever sees `read`'s own EOF-driven exit code), so a git/grep/sort
# failure there would silently degrade to an empty file list instead of a
# clear error. `set -o pipefail` (this file's own top-of-file `set -euo
# pipefail`) makes the command-substitution SUBSHELL's own exit code
# reflect the first failing pipeline stage; the explicit `||` below then
# actually observes that exit code, which the process-substitution form
# could not.
#   `grep`'s own "zero matches" exit (1) is deliberately absorbed (`|| true`)
#   so it never trips `pipefail` on its own — a real repo variant with zero
#   claude/**/*.md files is a legitimate, distinctly-messaged case (the
#   explicit `${#tier2_files[@]} -eq 0` check below), not a pipeline error.
#   A genuine `git ls-files` failure still trips pipefail via ITS stage.
if ! tier2_raw="$(git ls-files -- claude | { grep '\.md$' || true; } | LC_ALL=C sort)"; then
  echo "count-prose: failed to enumerate tracked claude/**/*.md files (git ls-files | grep | sort)" >&2
  exit 1
fi

tier2_files=()
while IFS= read -r f; do
  [ -z "$f" ] && continue
  tier2_files+=("$f")
done <<<"$tier2_raw"

if [ "${#tier2_files[@]}" -eq 0 ]; then
  echo "count-prose: zero tracked claude/**/*.md files found under $COUNT_PROSE_ROOT — nothing to count" >&2
  exit 1
fi

tier2_total=0
declare -a tier2_counts=()
for f in "${tier2_files[@]}"; do
  c="$(lines_in "$f")"
  tier2_counts+=("$c")
  tier2_total=$((tier2_total + c))
done

# ---------------------------------------------------------------------------
# Report.
# ---------------------------------------------------------------------------
echo "TIER-1 kernel-authored composed render: ${tier1_count} lines"
echo "  (claude/CLAUDE.kernel.md rendered via workflows/scripts/install-claude-md.sh"
echo "   INSTALL_CLAUDE_MD_KERNEL_ONLY=1 — knowledge-store-routing + overlay excluded)"
echo
echo "TIER-2 per-file line counts (claude/**/*.md, agent charters included):"
i=0
for f in "${tier2_files[@]}"; do
  printf '%8d  %s\n' "${tier2_counts[$i]}" "$f"
  i=$((i + 1))
done
echo
echo "TIER-2 total: ${tier2_total} lines across ${#tier2_files[@]} files"

# ---------------------------------------------------------------------------
# SESSION-START CONTRIBUTORS (temperloop#827, epic #810 P1) — manifest-
# driven byte report. workflows/scripts/config/contributor-manifest.tsv is
# the single source of truth for WHICH tracked paths this counts; adding a
# contributor is a row there, never a code change here (unless the row
# needs a `unit` this script does not implement yet — the case arm below
# is the closed set).
# ---------------------------------------------------------------------------
if [ "$contributor_manifest_available" -eq 0 ]; then
  echo
  echo "count-prose: contributor manifest not found: $CONTRIBUTOR_MANIFEST_TSV — skipping SESSION-START CONTRIBUTORS section" >&2
  exit 0
fi

contrib_paths=()
contrib_units=()
contrib_labels=()
contrib_loads=()
contrib_bytes=()
contrib_words=()

while IFS=$'\t' read -r c_path c_unit c_label c_load || [ -n "${c_path:-}" ]; do
  [ -z "${c_path:-}" ] && continue
  case "$c_path" in \#*) continue ;; esac

  # `read -r` with `IFS=$'\t'` splits only on real tabs — it trims neither
  # trailing spaces nor a trailing CR (a CRLF-saved manifest would leave
  # `\r` glued onto c_load, the LAST field on the line, since a bare `\r`
  # is ordinary line content up to the actual newline `read` strips). Strip
  # both from every field so a CRLF/trailing-space manifest can never route
  # a row into a foreign `load` bucket silently (the failure mode this
  # exists to close: `"harness-auto\r" != "harness-auto"` would otherwise
  # pass c_load's closed-set case below by falling through to a NEW,
  # single-row bucket instead of failing loudly).
  c_path="${c_path%$'\r'}"; c_path="${c_path%"${c_path##*[![:space:]]}"}"
  c_unit="${c_unit%$'\r'}"; c_unit="${c_unit%"${c_unit##*[![:space:]]}"}"
  c_label="${c_label%$'\r'}"; c_label="${c_label%"${c_label##*[![:space:]]}"}"
  c_load="${c_load%$'\r'}"; c_load="${c_load%"${c_load##*[![:space:]]}"}"

  if [ -z "${c_unit:-}" ] || [ -z "${c_label:-}" ] || [ -z "${c_load:-}" ]; then
    echo "count-prose: malformed contributor-manifest row (need 4 tab-separated fields): $c_path" >&2
    exit 1
  fi

  # load closed-set validation (mirrors check-contributor-manifest.sh's own
  # `case "${loads[$i]}"` check) — this script must not accept a value the
  # lint would reject, or a manifest that somehow slips past the lint (or a
  # caller pointing CONTRIBUTOR_MANIFEST_TSV at an unlinted fixture) could
  # route a row into a silently-created foreign bucket instead of failing.
  case "$c_load" in
    harness-auto | pointer-turn1 | none | n/a) ;;
    *)
      echo "count-prose: contributor row '$c_path' has unknown load class '$c_load' (want: harness-auto | pointer-turn1 | none | n/a)" >&2
      exit 1
      ;;
  esac

  case "$c_unit" in
    full)
      [ -f "$c_path" ] || { echo "count-prose: contributor row '$c_path' (unit full) does not exist" >&2; exit 1; }
      row_bytes="$(bytes_in "$c_path")"
      row_words="$(words_in "$c_path")"
      ;;
    frontmatter:description)
      [ -f "$c_path" ] || { echo "count-prose: contributor row '$c_path' (unit frontmatter:description) does not exist" >&2; exit 1; }
      val="$(frontmatter_description "$c_path")"
      [ -n "$val" ] || { echo "count-prose: contributor row '$c_path' has no description: frontmatter field" >&2; exit 1; }
      if _cp_is_block_scalar "$val"; then
        echo "count-prose: contributor row '$c_path' has a YAML block/folded scalar (description: $val) — only a single-line unquoted scalar is supported" >&2
        exit 1
      fi
      row_bytes="$(bytes_of "$val")"
      row_words="$(words_of "$val")"
      ;;
    *)
      echo "count-prose: contributor row '$c_path' has unknown unit '$c_unit' (want: full | frontmatter:description)" >&2
      exit 1
      ;;
  esac

  contrib_paths+=("$c_path")
  contrib_units+=("$c_unit")
  contrib_labels+=("$c_label")
  contrib_loads+=("$c_load")
  contrib_bytes+=("$row_bytes")
  contrib_words+=("$row_words")
done <"$CONTRIBUTOR_MANIFEST_TSV"

if [ "${#contrib_paths[@]}" -eq 0 ]; then
  echo "count-prose: zero contributor rows parsed from $CONTRIBUTOR_MANIFEST_TSV" >&2
  exit 1
fi

# Distinct load classes present, in first-seen order (bash-3.2-portable —
# no associative arrays): almost always just "harness-auto" today, but a
# future temperloop#836 row (turn-1 contributor rows, e.g. AGENTS.md,
# "pointer-turn1") must get its OWN bucket rather than being folded into
# this one, per the load-class note above.
load_classes=()
# _cp_seen_load — GUARD THE EMPTY-ARRAY CASE EXPLICITLY. Under `set -u`,
# bash 3.2 (macOS's system bash, and what ci.yml's macos-latest leg runs)
# treats `"${load_classes[@]}"` as an unbound-variable reference while the
# array is still zero-length — bash >= 4.4 does not. The FIRST call here
# always hits that case (load_classes starts empty), so an unguarded
# expansion crashes this function on its very first invocation on bash 3.2
# — and because the pre-existing `trap … EXIT` used to replace `$?` with
# `rm`'s own successful exit code, that crash printed nothing at all and
# still exited 0 (fixed above; the trap now propagates `$?`). The
# `${#arr[@]}` COUNT form is 3.2-safe under `set -u` even on an empty
# array, so it gates the loop instead of expanding the array directly.
_cp_seen_load() {
  local l
  if [ "${#load_classes[@]}" -gt 0 ]; then
    for l in "${load_classes[@]}"; do [ "$l" = "$1" ] && return 0; done
  fi
  return 1
}
for l in "${contrib_loads[@]}"; do
  _cp_seen_load "$l" || load_classes+=("$l")
done

echo
echo "SESSION-START CONTRIBUTORS (bytes; workflows/scripts/config/contributor-manifest.tsv):"
current_label=""
for i in "${!contrib_paths[@]}"; do
  if [ "${contrib_labels[$i]}" != "$current_label" ]; then
    current_label="${contrib_labels[$i]}"
    echo "  -- ${current_label} --"
  fi
  printf '%10d  %s\n' "${contrib_bytes[$i]}" "${contrib_paths[$i]}"
done

for load_class in "${load_classes[@]}"; do
  class_total_bytes=0
  class_total_words=0
  class_rows=0
  for i in "${!contrib_paths[@]}"; do
    [ "${contrib_loads[$i]}" = "$load_class" ] || continue
    class_total_bytes=$((class_total_bytes + contrib_bytes[i]))
    class_total_words=$((class_total_words + contrib_words[i]))
    class_rows=$((class_rows + 1))
  done

  echo
  printf '[%s] SUBTOTAL: %d bytes across %d row(s)\n' "$load_class" "$class_total_bytes" "$class_rows"

  # The byte->token proxy ratio is derived ONLY for the harness-auto bucket
  # — the unconditional, session-start cost this item measures. A
  # pointer-turn1 (or other) bucket gets its own byte subtotal above but no
  # ratio here: it is a conditional cost (paid only if the agent complies
  # with a read instruction), never pooled into the same estimate as the
  # unconditional one (temperloop#826).
  if [ "$load_class" != "harness-auto" ]; then
    echo "  (not a session-start-prefix load class — no byte->token ratio derived for this bucket)"
    continue
  fi

  if [ "$class_total_words" -le 0 ]; then
    echo "count-prose: harness-auto contributor content has zero words — cannot derive a byte/word ratio" >&2
    exit 1
  fi

  # The fixed-point scale for a 2-decimal byte/word ratio, kept off the
  # ratio-computation line below — mirrors this kernel's own "prose names a
  # setting, never states its value" convention (CLAUDE.md § Named-setting
  # convention), applied here to a computed quantity rather than a prose
  # rule, so the line that DERIVES the ratio names quantities only, never a
  # literal.
  ratio_scale=100

  # RATIO LINE — temperloop#827 acceptance 4: re-derived at runtime from a
  # live byte count (class_total_bytes) and a live word count
  # (class_total_words, the token-count proxy this script uses in place of
  # a tokenizer dependency). Deliberately zero numeric-literal characters on
  # this exact line — test_count_prose.sh greps it for one.
  ratio_scaled=$((class_total_bytes * ratio_scale / class_total_words))

  printf '[%s] SESSION-START CONTRIBUTOR TOTAL: %d bytes across %d row(s)\n' \
    "$load_class" "$class_total_bytes" "$class_rows"
  printf '[%s] byte->token proxy ratio (bytes per whitespace-delimited word — no tokenizer dependency): bytes=%d words=%d ratio=%d.%02d\n' \
    "$load_class" "$class_total_bytes" "$class_total_words" \
    "$((ratio_scaled / ratio_scale))" "$((ratio_scaled % ratio_scale))"
done
