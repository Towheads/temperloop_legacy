#!/usr/bin/env bash
#
# check-reviewer-routing.sh — extension/glob-axis drift lint for the
# reviewer-routing tsv (ADR 0008,
# docs/adr/0008-reviewer-routing-tsv-extension-axis-scope.md).
#
# workflows/scripts/config/reviewer-routing.tsv is the single source of
# truth for the extension/path-glob -> reviewer axis of /build's 3e
# pre-push review routing (claude/commands/build.md). This lint compares
# the extension/glob SET between the tsv and build.md's routing prose —
# not merely that the prose cites the tsv's filename — so the two cannot
# silently drift apart:
#
#   1. Structural: no extension/glob key in the tsv is claimed by two rows
#      (the tsv's own internal duplicate-claim invariant). NOTE what this
#      is NOT: two DIFFERENT keys that both match the same FILE are legal,
#      and are now in use — `.mjs` -> typescript-reviewer alongside
#      `**/build-level.mjs` -> shell-reviewer (temperloop#2129), which
#      build.md 3e's run-both multi-match rule runs together. The invariant
#      is one KEY claimed twice, never one FILE routed twice, so this check
#      compares key STRINGS and deliberately never computes key overlap.
#   1b. ASCII: every DATA row is pure ASCII (every byte below 0x80). The tsv
#      header states this constraint in prose and, until temperloop#2129,
#      nothing checked it. It is load-bearing, not cosmetic:
#      claude/workflows/build-level.mjs's review-diff relay guard compares a
#      checksum computed TWICE over these same rows -- once in bash over
#      od-reported UTF-8 BYTE values, once in JS over UTF-16 code units via
#      charCodeAt -- and the two agree only while every character is below
#      0x80. One accented name or smart quote in a data row silently desyncs
#      them and can fire a spurious content_mismatch escalation on a
#      perfectly faithful relay copy, which then reads as routing-table
#      corruption rather than as the typo it is. Comment lines are excluded
#      here exactly as they are from both checksums (the header already
#      carries em dashes safely, for that reason).
#   2. Citation: build.md's 3e section names reviewer-routing.tsv by path,
#      so a reader lands on the real source of truth.
#   3. Set-membership (the ADR 0008 D3-shaped check, `check-setting-prose.sh`
#      shape): for EVERY extension/glob key the tsv defines, that key's
#      literal backtick-quoted form (e.g. `` `.py` ``) must NOT reappear
#      anywhere in build.md's 3e section. The tsv is the only place a
#      route may be stated; a key resurfacing in prose is exactly the
#      silent reintroduction of the old inline extension list this lint
#      exists to catch.
#
# Explicitly OUT of scope (ADR 0008): the `architectural` change-kind
# route. It carries no file extension/glob to compare, so it is never a
# tsv key and is naturally never checked here — this is stated for
# legibility, not because the scan needs special-case code to exclude it.
#
# Usage:
#   check-reviewer-routing.sh
#
# Env overrides (fixture-driven tests):
#   REVIEWER_ROUTING_TSV    path to the tsv (default: sibling
#                           reviewer-routing.tsv)
#   REVIEWER_ROUTING_BUILD_MD   path to build.md (default:
#                           claude/commands/build.md under the repo root)
#
# Kept bash-3.2-portable (no associative arrays, no mapfile) so it runs on
# the macOS dev shell as well as Linux CI, matching every other
# workflows/scripts/config/*.sh checker (check-setting-prose.sh,
# check-setting-registry.sh).

set -uo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

: "${REVIEWER_ROUTING_TSV:=$SCRIPT_DIR/reviewer-routing.tsv}"
: "${REVIEWER_ROUTING_BUILD_MD:=$REPO_ROOT/claude/commands/build.md}"

if [ ! -f "$REVIEWER_ROUTING_TSV" ]; then
  echo "check-reviewer-routing: tsv not found at $REVIEWER_ROUTING_TSV" >&2
  exit 1
fi
if [ ! -f "$REVIEWER_ROUTING_BUILD_MD" ]; then
  echo "check-reviewer-routing: build.md not found at $REVIEWER_ROUTING_BUILD_MD" >&2
  exit 1
fi

_rr_ere_escape() {
  # Same bracket-expression ordering discipline as check-setting-prose.sh's
  # _kp_ere_escape (`]` first, `[` last-before-close) so BSD/macOS sed
  # doesn't misread a following `.`/`:`/`=` as a collating-symbol token.
  printf '%s' "$1" | sed -E 's/[]\.^$*+?(){}|[]/\\&/g'
}

# --- load tsv rows: key, reviewer, agent-path — comments/blank lines out ---
keys=()
reviewers=()
agent_paths=()
while IFS=$'\t' read -r key reviewer agent_path || [ -n "${key:-}" ]; do
  [ -z "${key:-}" ] && continue
  case "$key" in \#*) continue ;; esac
  if [ -z "${reviewer:-}" ] || [ -z "${agent_path:-}" ]; then
    echo "check-reviewer-routing: malformed row (need 3 tab-separated fields): $key" >&2
    exit 1
  fi
  keys+=("$key")
  reviewers+=("$reviewer")
  agent_paths+=("$agent_path")
done <"$REVIEWER_ROUTING_TSV"

if [ "${#keys[@]}" -eq 0 ]; then
  echo "check-reviewer-routing: zero extension/glob rows parsed from $REVIEWER_ROUTING_TSV" >&2
  exit 1
fi

violations=0

# --- 1. structural: no key claimed by two rows -----------------------------
for i in "${!keys[@]}"; do
  for j in "${!keys[@]}"; do
    [ "$j" -le "$i" ] && continue
    if [ "${keys[$i]}" = "${keys[$j]}" ]; then
      printf 'DUPLICATE: %s is claimed by two rows (%s, %s)\n' \
        "${keys[$i]}" "${reviewers[$i]}" "${reviewers[$j]}"
      violations=$((violations + 1))
    fi
  done
done

# --- 1b. ASCII: every DATA row is pure ASCII (see header, check 1b) --------
# BYTE-exact and dialect-free on purpose: strip every byte in the ASCII
# range and see whether anything survives. Under LC_ALL=C (exported at the
# top of this script) `tr -d` is a byte filter on BSD and GNU alike, so this
# needs no `grep -P`, no locale-dependent character class, and no
# `[^\x00-\x7F]` escape BSD basic-regex would read literally. Checked per
# row rather than over the whole file so the message can name the offender.
for i in "${!keys[@]}"; do
  ascii_residue="$(printf '%s\t%s\t%s' "${keys[$i]}" "${reviewers[$i]}" "${agent_paths[$i]}" \
    | LC_ALL=C tr -d '\000-\177')"
  if [ -n "$ascii_residue" ]; then
    printf 'NON-ASCII: row %s (-> %s) carries a non-ASCII character — the bash and JS relay checksums disagree above 0x7F, so this can fire a spurious content_mismatch on a faithful relay copy\n' \
      "${keys[$i]}" "${reviewers[$i]}"
    violations=$((violations + 1))
  fi
done

# --- isolate build.md's 3e section (from "#### 3e." to the next "#### ") ---
section_file="$(mktemp)"
trap 'rm -f "$section_file"' EXIT
awk '
  /^#### 3e\./ { insection = 1 }
  insection && /^#### / && !/^#### 3e\./ { insection = 0 }
  insection { print }
' "$REVIEWER_ROUTING_BUILD_MD" >"$section_file"

if [ ! -s "$section_file" ]; then
  echo "check-reviewer-routing: no '#### 3e.' section found in $REVIEWER_ROUTING_BUILD_MD — routing prose moved or renamed?" >&2
  exit 1
fi

# --- 2. citation: build.md's 3e section names the tsv by path --------------
if ! grep -q 'reviewer-routing\.tsv' "$section_file"; then
  echo "CITATION MISSING: build.md's 3e section does not cite reviewer-routing.tsv"
  violations=$((violations + 1))
fi

# --- 3. set-membership: no tsv key's backtick-quoted form in build.md ------
for i in "${!keys[@]}"; do
  key="${keys[$i]}"
  key_esc="$(_rr_ere_escape "$key")"
  pat="\`${key_esc}\`"
  if grep -qE -- "$pat" "$section_file"; then
    printf 'DRIFT: tsv key %s (-> %s) reappears literally in build.md 3e prose — the tsv is the only place this route may be stated\n' \
      "$key" "${reviewers[$i]}"
    violations=$((violations + 1))
  fi
done

echo
if [ "$violations" -gt 0 ]; then
  echo "FAIL: $violations reviewer-routing violation(s)" >&2
  exit 1
fi
echo "OK — reviewer-routing.tsv (${#keys[@]} extension/glob row(s)) and build.md's 3e prose agree: no duplicate keys, all data rows ASCII, tsv cited, no route restated in prose"
