#!/usr/bin/env bash
#
# build plan-note mechanics — the deterministic-machinery script that owns the
# Step-1 plan parse/validate + dependency-level toposort and the in-band
# sentinel writeback of /build (epic #253, spike #245). These are pure
# functions of the plan note's text with closed outcome sets, so they move from
# prose in build.md to code here; the judgment-shaped halves (what to DO
# with a validation failure, which item to spawn next) stay orchestrator-driven.
#
#   plan.sh validate  <planFile>                 # schema validation (plan-schema.md § Validation rules)
#   plan.sh toposort  <planFile>                 # dependency levels from depends-on ∪ after
#   plan.sh writeback <planFile> --slug <slug> --sentinel <state> \
#         [--pr N] [--pushed-sha SHA] [--speculative] [--run-status <text>] \
#         [--merge-blocked <value>] [--clear-merge-blocked]
#   plan.sh roster    <planFile> --level <k> --stage <launch|gate|close> \
#         [--owner-repo <o/r>] [--only-slugs <csv>] [--driver <text>] [--plan-link <text>]
#
# `validate` enforces the 15 plan-schema rules (status==approved, slug+acceptance
# present, unique kebab slugs ≤40, branch <type>/<slug>, depends-on/after refs
# exist, the depends-on∪after union acyclic, no leftover acceptance placeholder,
# gh_issue a positive int, gh_issue/split_from mutual exclusion, the rule-11
# external-gate gate_check requirement, rule-12 repo owner/repo shape, the
# rule-13 activation-block class∈{A,B,C} + class-A proof: requirement, the
# rule-14 product-source activation-required requirement — see
# RULE_14_CUTOVER_DATE below for the grandfather gate — and the rule-15
# keystone-spike marker being value 'true' on a kind: spike item only,
# temperloop#526).
# `toposort` partitions items into
# dependency levels — level 0 = items with neither depends-on nor after — over
# the UNION of both edge sets, and emits `{"levels":[["a","b"],["c"]]}` on stdout.
#
# `writeback` flips an item's checkbox sentinel ([ ]→[~]→[m]→[x], the as-you-go
# variant [ ]→[~]→[>]→[x] (temperloop#1026), plus [v]/[-])
# and stamps sub-lines (pr:, pushed_sha:, speculative:, merge_blocked:,
# Run-status:) on the plan
# note. It is the SOLE sentinel-writeback path: ALL vault writes route through a
# single `_plan_vault_write` indirection (mirrors board.sh's `_board_gh`),
# overridable in tests.
#
# The write is TWO-TIER, resolved per call (#342):
#   1. If an Obsidian Local REST API config (the plugin's data.json) is found —
#      via PLAN_API_KEY_FILE / KNOWLEDGE_STORE_ROOT-derived, or the vault root
#      RESOLVED from the plan note's own absolute path — the patched note PUTs
#      to that REST API (the same API the board adapter and session-start-drain
#      hook use). A configured-but-unreachable REST API FAILS LOUD (WRITE_FAILED
#      + non-zero) — never silent success — because a sentinel write IS the
#      resume-safety substrate and a silent loss loses resume state.
#   2. If NO REST config is found (e.g. a temperloop kernel checkout whose vault
#      has no Local REST API plugin), the write FAILS SOFT to a direct
#      filesystem write of the plan note's on-disk path — the sentinel is still
#      persisted durably (resume-safety intact), just via the filesystem instead
#      of REST. Only when there is neither a REST config NOR a writable on-disk
#      plan path does it emit WRITE_SKIPPED — a soft, non-fatal outcome the
#      orchestrator can handle (vs. the hard WRITE_FAILED of a broken endpoint).
#
# Output contract — CLOSED outcome set, one structured JSON line per outcome
# (exception: `toposort` prints the `{"levels":…}` object directly):
#   validate  → {"outcome":"VALID"} |
#               {"outcome":"INVALID","errors":[…]} + non-zero exit
#   toposort  → {"levels":[[…],…],"order":[…]} |
#               {"outcome":"CYCLE","cycle":[…]} + non-zero exit
#   writeback → {"outcome":"WRITTEN","slug":…,"sentinel":…} |
#               {"outcome":"WRITE_SKIPPED","slug":…,"reason":…} (soft; zero exit) |
#               {"outcome":"WRITE_FAILED","slug":…,"error":…} + non-zero exit
#   roster    → a plain-text operator report on stdout (see cmd_roster) |
#               {"outcome":"ROSTER_INCOMPLETE",…} + non-zero exit
#   error     → {"outcome":"ERROR","error":…} + non-zero exit
set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo '{"outcome":"ERROR","error":"jq not found"}'; exit 1; }

# Rule 14 (plan-schema.md) grandfather cutover: a plan whose frontmatter `date:`
# is present and STRICTLY BEFORE this date is exempt from the product-source
# activation-required check, so an already-`approved` in-flight plan authored
# before rule 14 shipped keeps validating unchanged on its next /build resume
# (temperloop non-BREAKING release discipline). A plan with NO `date:`
# frontmatter is never grandfathered (treated as on-or-after cutover). Bump
# this only when deliberately re-cutting the grandfather boundary — never to
# silence a specific plan's failure.
RULE_14_CUTOVER_DATE="2026-07-17"

# fd 3 = the script's real stdout. Helpers run inside command substitutions,
# where a die()'s ERROR line would be captured by the caller instead of reaching
# the orchestrator — emitting via fd 3 keeps the structured error on the real
# stdout regardless of call context (same seam as pr.sh / ci-poll.sh).
exec 3>&1
die() {
  jq -cn --arg error "$1" '{outcome:"ERROR", error:$error}' >&3
  exit 1
}

usage() {
  die "usage: plan.sh validate <planFile> | toposort <planFile> | writeback <planFile> --slug <slug> --sentinel <[ ]|[~]|[m]|[>]|[x]|[v]|[-]> [--pr N] [--pushed-sha SHA] [--speculative] [--run-status <text>] [--merge-blocked <value>] [--clear-merge-blocked] | roster <planFile> --level <k> --stage <launch|gate|close> [--owner-repo <owner/repo>] [--only-slugs <csv>] [--driver <text>] [--plan-link <text>]"
}

# --- the ONE test-injection seam ---------------------------------------------
# Every sentinel write goes through here. Production PUTs the patched note to the
# Obsidian Local REST API; tests override this after sourcing
# (e.g. `_plan_vault_write() { fake_write "$@"; }`) so NO live REST call happens
# in the suite. Mirrors board.sh's `_board_gh`.
#
#   _plan_vault_write <vaultRelPath> <contentFile>
#
# Return-code contract (consumed by cmd_writeback):
#   0  → written (via REST when configured, else the filesystem fallback)
#   1  → REST was CONFIGURED but the write FAILED (unreachable / HTTP error) —
#        fail loud (WRITE_FAILED); a configured endpoint going silent loses
#        resume state, so this stays a hard, non-zero failure.
#   3  → no REST config AND no writable on-disk plan path — WRITE_SKIPPED, a
#        SOFT outcome (nothing was persisted, but nothing was broken either).
# Config default resolution routes through the knowledge_store seam's obsidian
# backend (foundation #777, Epic A #762 "kernel split") rather than a literal:
# KNOWLEDGE_STORE_OBSIDIAN_API_KEY_FILE / _API_BASE already default to today's
# vault path/URL in that ONE file (knowledge_store_obsidian.sh), so plan.sh no
# longer repeats the literal here. PLAN_API_BASE / PLAN_API_KEY_FILE remain the
# names tests/callers override (unchanged surface) — they now fall back to the
# seam's own settings instead of a hardcoded default.
PLAN_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
if [ -f "$PLAN_LIB_DIR/knowledge_store.sh" ]; then
  # shellcheck source=workflows/scripts/lib/knowledge_store.sh
  . "$PLAN_LIB_DIR/knowledge_store.sh"
fi
if [ -f "$PLAN_LIB_DIR/knowledge_store_obsidian.sh" ]; then
  # shellcheck source=workflows/scripts/lib/knowledge_store_obsidian.sh
  . "$PLAN_LIB_DIR/knowledge_store_obsidian.sh"
fi
PLAN_API_BASE="${PLAN_API_BASE:-${KNOWLEDGE_STORE_OBSIDIAN_API_BASE:-https://127.0.0.1:27124}}"
PLAN_API_KEY_FILE="${PLAN_API_KEY_FILE:-${KNOWLEDGE_STORE_OBSIDIAN_API_KEY_FILE:-}}"

# Resolve the Obsidian Local REST API key file for THIS writeback, printing the
# first existing candidate on stdout (exit 0), or exit 1 when none exists (=>
# no REST config, the caller falls soft to a filesystem write). Resolution
# order, most-specific first (#342):
#   1. PLAN_API_KEY_FILE — the caller/test override, itself defaulted from the
#      knowledge_store seam's KNOWLEDGE_STORE_OBSIDIAN_API_KEY_FILE setting (which
#      derives from KNOWLEDGE_STORE_ROOT — the "actual knowledge-store root").
#   2. The vault root RESOLVED from the plan note's own absolute on-disk path:
#      the parent of its `/Plans/` segment. This is what makes writeback work in
#      a checkout whose vault differs from the KNOWLEDGE_STORE_ROOT default
#      (e.g. a temperloop kernel checkout whose vault lives under a non-default
#      knowledge-store root, writing that vault's own /Plans/…): the plan
#      file's location is the ground truth for which vault it belongs to.
# A resolved candidate must actually EXIST on disk to be used — a nonexistent
# path is treated as "no REST config here", not a hard error.
_plan_resolve_api_key_file() {
  local on_disk="${1:-}" vault_root cand
  if [ -n "$PLAN_API_KEY_FILE" ] && [ -f "$PLAN_API_KEY_FILE" ]; then
    printf '%s\n' "$PLAN_API_KEY_FILE"
    return 0
  fi
  case "$on_disk" in
    /*/Plans/*)
      vault_root="${on_disk%%/Plans/*}"
      cand="$vault_root/.obsidian/plugins/obsidian-local-rest-api/data.json"
      if [ -f "$cand" ]; then
        printf '%s\n' "$cand"
        return 0
      fi
      ;;
  esac
  return 1
}

# _plan_vault_write <vaultRelPath> <contentFile> [<onDiskPath>]
_plan_vault_write() {
  local vault_path="$1" content_file="$2" on_disk="${3:-}" \
        api_key http_code encoded_path key_file
  if key_file="$(_plan_resolve_api_key_file "$on_disk")"; then
    # --- Tier 1: a REST config exists → PUT to the Obsidian Local REST API ----
    api_key="$(jq -r '.apiKey // empty' "$key_file" 2>/dev/null)"
    [ -n "$api_key" ] || { echo "plan.sh: could not read apiKey from $key_file" >&2; return 1; }
    # URL-encode each path SEGMENT (preserving the '/' separators) before the PUT.
    # Plan filenames carry spaces per the canonical 'Plans/<date> <project> -
    # <title>.md' convention; interpolated raw, curl rejects the URL (exit 3,
    # http_code 000) and writeback breaks for EVERY real plan (#364). jq @uri
    # percent-encodes per segment so 'Plans/a b.md' → 'Plans/a%20b.md'.
    encoded_path="$(printf '%s' "$vault_path" | jq -sRr 'split("/") | map(@uri) | join("/")')" \
      || { echo "plan.sh: failed to URL-encode vault path '$vault_path'" >&2; return 1; }
    # Whole-file PUT (idempotent); no PATCH, so the REST-API 4.0 targetScope rule
    # does not apply (cf. session-start-drain.sh, foundation #6).
    http_code="$(curl -s -k -o /dev/null -w '%{http_code}' \
      -X PUT "$PLAN_API_BASE/vault/$encoded_path" \
      -H "Authorization: Bearer $api_key" \
      -H "Content-Type: text/markdown" \
      --data-binary "@$content_file" 2>/dev/null)" || {
        echo "plan.sh: REST API unreachable at $PLAN_API_BASE (curl failed)" >&2
        return 1
      }
    case "$http_code" in
      200|204) return 0 ;;
      000|"") echo "plan.sh: REST API unreachable at $PLAN_API_BASE (no response)" >&2; return 1 ;;
      *) echo "plan.sh: REST API write to $vault_path failed (HTTP $http_code)" >&2; return 1 ;;
    esac
  fi

  # --- Tier 2: no REST config → fail SOFT to a direct filesystem write --------
  # The sentinel is still persisted durably (resume-safety intact), just to the
  # plan note's on-disk path instead of via REST. cmd_writeback verified the
  # path exists before calling us, so this is normally a straight overwrite.
  if [ -n "$on_disk" ] && cat "$content_file" > "$on_disk" 2>/dev/null; then
    echo "plan.sh: no Obsidian REST config found; wrote sentinel directly to $on_disk (filesystem fallback)" >&2
    return 0
  fi
  echo "plan.sh: no REST config and no writable on-disk plan path — sentinel NOT persisted (WRITE_SKIPPED)" >&2
  return 3
}

# --- plan-note parsing -------------------------------------------------------
# A plan note is markdown: YAML frontmatter (--- … ---) then a `## Items`
# section of `- [ ] **title** `slug: x` …` blocks with indented sub-line fields.
# We parse in awk: emit one TSV record per item with its fields, and frontmatter
# `status:` separately. Robust to field order and to extra whitespace.

# Read the frontmatter `status:` value (first `status:` between the leading --- markers).
fm_status() {
  awk '
    NR==1 && $0=="---" { infm=1; next }
    infm && $0=="---" { exit }
    infm && /^status:[[:space:]]*/ {
      sub(/^status:[[:space:]]*/,""); sub(/[[:space:]]*#.*/,""); gsub(/[[:space:]]+$/,"");
      print; exit
    }
  ' "$1"
}

# Read the frontmatter `date:` value (first `date:` between the leading --- markers).
# Used by rule 14's grandfather gate — a plan authored before RULE_14_CUTOVER_DATE
# is exempt. Prints nothing (empty) when no `date:` frontmatter is present.
fm_date() {
  awk '
    NR==1 && $0=="---" { infm=1; next }
    infm && $0=="---" { exit }
    infm && /^date:[[:space:]]*/ {
      sub(/^date:[[:space:]]*/,""); sub(/[[:space:]]*#.*/,""); gsub(/[[:space:]]+$/,"");
      print; exit
    }
  ' "$1"
}

# Emit, for each item, a line: SLUG<TAB>FIELD=VALUE pairs joined by US (0x1f).
# Recognized fields: slug, branch, depends-on, after, gh_issue, split_from,
# gate_check, acceptance (=1 if a non-empty acceptance block exists),
# acceptance_placeholder (=1 if the placeholder line is present), notes,
# sentinel (the current checkbox char), title, kind (code|spike, default code),
# keystone (the raw keystone: value — a keystone spike halts /build for verdict
# review before dependents build, temperloop#526), files (raw comma-separated
# files: value, backtick-quoted per entry).
# This is the single parse used by validate/toposort/writeback.
parse_items() {
  awk '
    function flush() {
      if (have_item) {
        rec = slug
        rec = rec SEP "sentinel=" sentinel
        rec = rec SEP "title=" title
        rec = rec SEP "branch=" branch
        rec = rec SEP "dependson=" dependson
        rec = rec SEP "after=" after
        rec = rec SEP "gh_issue=" gh_issue
        rec = rec SEP "split_from=" split_from
        rec = rec SEP "gate_check=" gate_check
        rec = rec SEP "notes=" notes
        rec = rec SEP "acceptance=" (acc_count>0 ? "1" : "0")
        rec = rec SEP "acc_placeholder=" acc_placeholder
        rec = rec SEP "activation=" (activation ? "1" : "0")
        rec = rec SEP "act_class=" act_class
        rec = rec SEP "act_proof=" act_proof
        rec = rec SEP "kind=" (kind=="" ? "code" : kind)
        rec = rec SEP "keystone=" keystone
        rec = rec SEP "files=" files
        rec = rec SEP "cost=" (cost ? "1" : "0")
        rec = rec SEP "cost_because=" cost_because
        rec = rec SEP "pr=" pr
        rec = rec SEP "speculative=" speculative
        rec = rec SEP "merge_blocked=" merge_blocked
        rec = rec SEP "run_status=" run_status
        rec = rec SEP "repo=" repo
        print rec
      }
      have_item=0; slug=""; sentinel=""; title=""; branch=""; dependson="";
      after=""; gh_issue=""; split_from=""; gate_check=""; notes="";
      acc_count=0; acc_placeholder=0; in_acc=0
      activation=0; act_class=""; act_proof=""; in_activation=0
      kind=""; keystone=""; files=""
      cost=0; cost_because=""; in_cost=0
      pr=""; speculative=""; run_status=""; repo=""; merge_blocked=""
    }
    BEGIN { SEP=sprintf("%c",31); in_items=0 }
    /^##[[:space:]]+Items[[:space:]]*$/ { in_items=1; next }
    in_items && /^##[[:space:]]/ { flush(); in_items=0; next }
    !in_items { next }

    # Item header: - [x] **title** `slug: foo` — scope
    /^[[:space:]]*-[[:space:]]*\[.\]/ {
      flush()
      have_item=1
      line=$0
      # sentinel char between the brackets
      s=line; sub(/^[^[]*\[/,"",s); sentinel=substr(s,1,1)
      # title between ** **
      t=line
      if (match(t, /\*\*[^*]+\*\*/)) {
        title=substr(t, RSTART+2, RLENGTH-4)
      }
      # slug inside `slug: x`
      if (match(line, /`slug:[[:space:]]*[a-zA-Z0-9_-]+`/)) {
        sl=substr(line, RSTART, RLENGTH)
        gsub(/`/,"",sl); sub(/slug:[[:space:]]*/,"",sl); gsub(/[[:space:]]/,"",sl)
        slug=sl
      }
      in_acc=0
      next
    }

    # Sub-line fields (indented). We are inside an item block.
    have_item {
      l=$0
      # acceptance block: `- acceptance:` opens it; subsequent deeper bullets are entries.
      if (l ~ /^[[:space:]]*-[[:space:]]*acceptance:[[:space:]]*$/) { in_acc=1; in_activation=0; in_cost=0; next }
      if (in_acc) {
        # placeholder line is fatal at execution
        if (l ~ /no acceptance criteria derivable from source/) { acc_placeholder=1 }
        # A same-level field key (activation:, notes:, gate_check:, ...) ends the
        # acceptance block — tested BEFORE the deeper-bullet entry regex. A field
        # bullet like `- activation:` also matches the generic `- <text>` deeper-
        # bullet shape, so if the entry regex ran first it would swallow the field
        # as an acceptance entry and never open the activation block — the rule-14
        # false positive that fires when activation: follows acceptance: (the
        # canonical field order). Field keys carry `<word>:`; prose entries do not.
        if (l ~ /^[[:space:]]*-[[:space:]]*[a-zA-Z_-]+:/) { in_acc=0 }
        # otherwise a deeper bullet is an acceptance entry
        else if (l ~ /^[[:space:]]+-[[:space:]]+/) { acc_count++; next }
        else { next }
      }
      # activation block: `- activation:` opens it; `- class:` / `- proof:` are its
      # keyed entries (the inward twin of gate_check — plan-schema.md § activation).
      if (l ~ /^[[:space:]]*-[[:space:]]*activation:[[:space:]]*$/) { in_activation=1; activation=1; in_acc=0; in_cost=0; next }
      if (in_activation) {
        if (match(l, /^[[:space:]]*-[[:space:]]*class:[[:space:]]*/)) {
          v=l; sub(/^[[:space:]]*-[[:space:]]*class:[[:space:]]*/,"",v); gsub(/`/,"",v); gsub(/[[:space:]]/,"",v); act_class=v; next
        }
        if (match(l, /^[[:space:]]*-[[:space:]]*proof:[[:space:]]*/)) {
          v=l; sub(/^[[:space:]]*-[[:space:]]*proof:[[:space:]]*/,"",v); act_proof=v; next
        }
        # any other same-level field key ends the activation block (fall through to field parse)
        if (l ~ /^[[:space:]]*-[[:space:]]*[a-zA-Z_-]+:/) { in_activation=0 }
        else { next }
      }
      # cost block (foundation#1059): `- cost:` marks an item with outsized
      # EXECUTION spend (presence = expensive, the binary flag); `- because:`
      # (required, rule 16) and `- budget:` (optional token ceiling) are its
      # keyed entries. Same block shape as activation above — EXCEPT the open is
      # forgiving of an inline value: `- cost: deep-research` (a hand-authored
      # one-liner) opens the block AND takes the inline value as the `because:`
      # shorthand, so it is FLAGGED, never silently dropped. A nested
      # `- because:` still overrides an inline value.
      if (match(l, /^[[:space:]]*-[[:space:]]*cost:([[:space:]]|$)/)) {
        in_cost=1; cost=1; in_activation=0; in_acc=0
        v=l; sub(/^[[:space:]]*-[[:space:]]*cost:[[:space:]]*/,"",v); gsub(/`/,"",v); gsub(/[[:space:]]*#.*/,"",v); gsub(/^[[:space:]]+|[[:space:]]+$/,"",v)
        if (v != "") cost_because=v
        next
      }
      if (in_cost) {
        if (match(l, /^[[:space:]]*-[[:space:]]*because:[[:space:]]*/)) {
          v=l; sub(/^[[:space:]]*-[[:space:]]*because:[[:space:]]*/,"",v); gsub(/`/,"",v); gsub(/[[:space:]]*#.*/,"",v); gsub(/^[[:space:]]+|[[:space:]]+$/,"",v); cost_because=v; next
        }
        if (l ~ /^[[:space:]]*-[[:space:]]*budget:[[:space:]]*/) { next }
        # any other same-level field key ends the cost block
        if (l ~ /^[[:space:]]*-[[:space:]]*[a-zA-Z_-]+:/) { in_cost=0 }
        else { next }
      }
      if (match(l, /^[[:space:]]*-[[:space:]]*branch:[[:space:]]*/)) {
        v=l; sub(/^[[:space:]]*-[[:space:]]*branch:[[:space:]]*/,"",v); gsub(/`/,"",v); gsub(/[[:space:]]*#.*/,"",v); gsub(/^[[:space:]]+|[[:space:]]+$/,"",v); branch=v; next
      }
      if (match(l, /^[[:space:]]*-[[:space:]]*depends-on:[[:space:]]*/)) {
        v=l; sub(/^[[:space:]]*-[[:space:]]*depends-on:[[:space:]]*/,"",v); gsub(/[[:space:]]*#.*/,"",v); dependson=v; next
      }
      if (match(l, /^[[:space:]]*-[[:space:]]*after:[[:space:]]*/)) {
        v=l; sub(/^[[:space:]]*-[[:space:]]*after:[[:space:]]*/,"",v); gsub(/[[:space:]]*#.*/,"",v); after=v; next
      }
      if (match(l, /^[[:space:]]*-[[:space:]]*gh_issue:[[:space:]]*/)) {
        v=l; sub(/^[[:space:]]*-[[:space:]]*gh_issue:[[:space:]]*/,"",v); gsub(/#/,"",v); gsub(/[[:space:]]*#.*/,"",v); gsub(/^[[:space:]]+|[[:space:]]+$/,"",v); gh_issue=v; next
      }
      if (match(l, /^[[:space:]]*-[[:space:]]*split_from:[[:space:]]*/)) {
        v=l; sub(/^[[:space:]]*-[[:space:]]*split_from:[[:space:]]*/,"",v); gsub(/[[:space:]]+#.*/,"",v); gsub(/^[[:space:]]+|[[:space:]]+$/,"",v); split_from=v; next
      }
      if (match(l, /^[[:space:]]*-[[:space:]]*gate_check:[[:space:]]*/)) {
        v=l; sub(/^[[:space:]]*-[[:space:]]*gate_check:[[:space:]]*/,"",v); gate_check=v; next
      }
      if (match(l, /^[[:space:]]*-[[:space:]]*notes:[[:space:]]*/)) {
        v=l; sub(/^[[:space:]]*-[[:space:]]*notes:[[:space:]]*/,"",v); notes=v; next
      }
      if (match(l, /^[[:space:]]*-[[:space:]]*kind:[[:space:]]*/)) {
        v=l; sub(/^[[:space:]]*-[[:space:]]*kind:[[:space:]]*/,"",v); gsub(/[[:space:]]*#.*/,"",v); gsub(/^[[:space:]]+|[[:space:]]+$/,"",v); kind=v; next
      }
      if (match(l, /^[[:space:]]*-[[:space:]]*keystone:[[:space:]]*/)) {
        v=l; sub(/^[[:space:]]*-[[:space:]]*keystone:[[:space:]]*/,"",v); gsub(/`/,"",v); gsub(/[[:space:]]*#.*/,"",v); gsub(/^[[:space:]]+|[[:space:]]+$/,"",v); keystone=v; next
      }
      if (match(l, /^[[:space:]]*-[[:space:]]*files:[[:space:]]*/)) {
        v=l; sub(/^[[:space:]]*-[[:space:]]*files:[[:space:]]*/,"",v); gsub(/[[:space:]]*#.*/,"",v); files=v; next
      }
      # Run-state stamps writeback lays down. Parsed (not just written) because
      # `roster` renders each item stage/disposition from them (temperloop#1310).
      if (match(l, /^[[:space:]]*-[[:space:]]*pr:[[:space:]]*/)) {
        v=l; sub(/^[[:space:]]*-[[:space:]]*pr:[[:space:]]*/,"",v); gsub(/#/,"",v); gsub(/`/,"",v); gsub(/^[[:space:]]+|[[:space:]]+$/,"",v); pr=v; next
      }
      # temperloop#2083. The dual-build merge HOLD. Parsed because the Step 4
      # merge-gate selected set subtracts every item carrying it, and a resumed
      # run has nothing else to read it from — the level summary that computed
      # it died with the previous invocation.
      if (match(l, /^[[:space:]]*-[[:space:]]*merge_blocked:[[:space:]]*/)) {
        v=l; sub(/^[[:space:]]*-[[:space:]]*merge_blocked:[[:space:]]*/,"",v); gsub(/`/,"",v); gsub(/[[:space:]]*#.*/,"",v); gsub(/^[[:space:]]+|[[:space:]]+$/,"",v); merge_blocked=v; next
      }
      if (match(l, /^[[:space:]]*-[[:space:]]*speculative:[[:space:]]*/)) {
        v=l; sub(/^[[:space:]]*-[[:space:]]*speculative:[[:space:]]*/,"",v); gsub(/`/,"",v); gsub(/[[:space:]]*#.*/,"",v); gsub(/^[[:space:]]+|[[:space:]]+$/,"",v); speculative=v; next
      }
      if (match(l, /^[[:space:]]*-[[:space:]]*[Rr]un-status:[[:space:]]*/)) {
        v=l; sub(/^[[:space:]]*-[[:space:]]*[Rr]un-status:[[:space:]]*/,"",v); gsub(/^[[:space:]]+|[[:space:]]+$/,"",v); run_status=v; next
      }
      if (match(l, /^[[:space:]]*-[[:space:]]*repo:[[:space:]]*/)) {
        v=l; sub(/^[[:space:]]*-[[:space:]]*repo:[[:space:]]*/,"",v); gsub(/`/,"",v); gsub(/[[:space:]]*#.*/,"",v); gsub(/^[[:space:]]+|[[:space:]]+$/,"",v); repo=v; next
      }
    }
    END { flush() }
  ' "$1"
}

# Extract a single field from a parsed record line.
rec_field() {
  local rec="$1" key="$2"
  awk -v k="$key" 'BEGIN{SEP=sprintf("%c",31)}{
    n=split($0,a,SEP)
    for(i=2;i<=n;i++){ p=index(a[i],"="); if(substr(a[i],1,p-1)==k){print substr(a[i],p+1); exit}}
  }' <<<"$rec"
}
rec_slug() { awk 'BEGIN{FS=sprintf("%c",31)}{print $1; exit}' <<<"$1"; }

# Split a comma/space-separated slug list into space-separated tokens.
split_list() { printf '%s' "$1" | tr ',' ' ' | xargs 2>/dev/null || true; }

# Rule 14's product-source predicate (plan-schema.md § Optional `activation:`
# block): does a raw `files:` value carry at least one path under a shipped
# kernel/product-machinery root — scripts/, workflows/, or claude/? Backtick
# quoting is stripped before splitting on commas. Returns 0 (true) on a match,
# 1 (false) on no files or no matching entry.
_files_touch_shipped() {
  local raw="${1//\`/}" tok
  # No files declared → cannot touch a shipped path (also avoids expanding an
  # empty array under `set -u`, which aborts on bash 3.2 / macOS system bash).
  [ -n "$raw" ] || return 1
  IFS=',' read -ra _ftoks <<<"$raw"
  for tok in "${_ftoks[@]}"; do
    tok="$(printf '%s' "$tok" | xargs 2>/dev/null || true)"
    case "$tok" in
      scripts/*|workflows/*|claude/*) return 0 ;;
    esac
  done
  return 1
}

# --- validate ----------------------------------------------------------------
cmd_validate() {
  local file="$1" records status errors=() slug rec
  [ -f "$file" ] || die "plan file '$file' does not exist"
  status="$(fm_status "$file")"
  records="$(parse_items "$file")"
  [ -n "$records" ] || die "no items found under '## Items' in '$file'"

  # Rule 14 grandfather gate: a plan whose frontmatter `date:` is present and
  # STRICTLY BEFORE RULE_14_CUTOVER_DATE is exempt (already-approved in-flight
  # plans keep validating unchanged). No `date:` → never grandfathered.
  # YYYY-MM-DD strings compare correctly lexically, no date arithmetic needed.
  local plan_date rule14_grandfathered=0
  plan_date="$(fm_date "$file")"
  if [ -n "$plan_date" ] && [[ "$plan_date" < "$RULE_14_CUTOVER_DATE" ]]; then
    rule14_grandfathered=1
  fi

  # Rule 1: status must be approved (not draft / missing).
  if [ "$status" != "approved" ]; then
    errors+=("rule 1: frontmatter status is '${status:-<missing>}', must be 'approved'")
  fi

  # Build slug set first (for ref-existence + uniqueness). Bash 3.2 — no
  # associative arrays; track membership in comma-fenced strings.
  local all_slugs=() seen_slugs="," seen_dupes=","
  while IFS= read -r rec; do
    [ -n "$rec" ] || continue
    slug="$(rec_slug "$rec")"
    if [ -z "$slug" ]; then
      errors+=("rule 3: an item has no slug: (title='$(rec_field "$rec" title)')")
      continue
    fi
    all_slugs+=("$slug")
  done <<<"$records"

  # Rule 3 (uniqueness) + slug charset/length.
  for slug in "${all_slugs[@]}"; do
    if [[ "$seen_slugs" == *",$slug,"* ]] && [[ "$seen_dupes" != *",$slug,"* ]]; then
      errors+=("rule 3: duplicate slug '$slug'")
      seen_dupes="$seen_dupes$slug,"
    fi
    seen_slugs="$seen_slugs$slug,"
    if ! [[ "$slug" =~ ^[a-z0-9-]+$ ]]; then
      errors+=("rule 3: slug '$slug' must match [a-z0-9-]+")
    fi
    if [ "${#slug}" -gt 40 ]; then
      errors+=("rule 3: slug '$slug' exceeds 40 chars")
    fi
  done

  # Per-item field rules.
  while IFS= read -r rec; do
    [ -n "$rec" ] || continue
    slug="$(rec_slug "$rec")"
    [ -n "$slug" ] || continue
    local branch acc acc_ph gh_issue split_from gate_check notes dep aft tok
    local activation act_class act_proof kind keystone files cost cost_because
    branch="$(rec_field "$rec" branch)"
    acc="$(rec_field "$rec" acceptance)"
    acc_ph="$(rec_field "$rec" acc_placeholder)"
    gh_issue="$(rec_field "$rec" gh_issue)"
    split_from="$(rec_field "$rec" split_from)"
    gate_check="$(rec_field "$rec" gate_check)"
    notes="$(rec_field "$rec" notes)"
    dep="$(rec_field "$rec" dependson)"
    aft="$(rec_field "$rec" after)"
    activation="$(rec_field "$rec" activation)"
    act_class="$(rec_field "$rec" act_class)"
    act_proof="$(rec_field "$rec" act_proof)"
    kind="$(rec_field "$rec" kind)"
    keystone="$(rec_field "$rec" keystone)"
    files="$(rec_field "$rec" files)"
    cost="$(rec_field "$rec" cost)"
    cost_because="$(rec_field "$rec" cost_because)"

    # Rule 2: acceptance block present.
    [ "$acc" = "1" ] || errors+=("rule 2: item '$slug' has no acceptance: block")
    # Rule 9: no leftover acceptance placeholder.
    [ "$acc_ph" != "1" ] || errors+=("rule 9: item '$slug' still has the acceptance placeholder line")
    # Rule 4: branch matches <type>/<slug-ish>.
    if [ -n "$branch" ]; then
      [[ "$branch" =~ ^(feat|fix|chore|refactor|docs|test)/[a-z0-9-]+$ ]] \
        || errors+=("rule 4: item '$slug' branch '$branch' must match <type>/<slug> (type ∈ feat|fix|chore|refactor|docs|test)")
    fi
    # Rule 7: gh_issue (when present) a positive int.
    if [ -n "$gh_issue" ]; then
      { [[ "$gh_issue" =~ ^[0-9]+$ ]] && [ "$gh_issue" -gt 0 ]; } \
        || errors+=("rule 7: item '$slug' gh_issue '$gh_issue' must be a positive integer")
    fi
    # Rule 10: gh_issue/split_from mutual exclusion; split_from must be #<posint>.
    if [ -n "$split_from" ]; then
      if [ -n "$gh_issue" ]; then
        errors+=("rule 10: item '$slug' carries both gh_issue and split_from (mutually exclusive)")
      fi
      [[ "$split_from" =~ ^#[0-9]+$ ]] && [ "${split_from#\#}" -gt 0 ] 2>/dev/null \
        || errors+=("rule 10: item '$slug' split_from '$split_from' must be a #<positive-integer> ref")
    fi
    # Rule 11: a prose external/cross-plan gate in notes: needs a gate_check:.
    if [ -n "$notes" ] && [[ "$notes" =~ (do[[:space:]]not[[:space:]]start|don\'?t[[:space:]]start|until[[:space:]]+#[0-9]+|lands[[:space:]]*\(?#[0-9]+) ]]; then
      [ -n "$gate_check" ] || errors+=("rule 11: item '$slug' declares a prose external gate in notes: but carries no gate_check: predicate")
    fi
    # Rule 13: an activation: block (when present) must declare a valid class; a
    # class-A block must carry a proof: predicate (the synchronous in-repo
    # activation check /build runs at Step 3e.6). B/C are ledger-discharged.
    if [ "$activation" = "1" ]; then
      case "$act_class" in
        A|B|C) : ;;
        *) errors+=("rule 13: item '$slug' activation: class '${act_class:-<missing>}' must be one of A|B|C") ;;
      esac
      if [ "$act_class" = "A" ] && [ -z "$act_proof" ]; then
        errors+=("rule 13: item '$slug' activation: class A must carry a proof: predicate (the synchronous in-repo activation check)")
      fi
    fi
    # Rule 14: a PRODUCT-SOURCE item — kind: code (not spike) whose files: list
    # includes at least one path under scripts/, workflows/, or claude/ — must
    # carry an activation: block. kind: spike and docs-only items (files: only
    # under docs/ or a *.md outside claude/) are exempt. Grandfathered plans
    # (frontmatter date: before RULE_14_CUTOVER_DATE) are exempt regardless, so
    # an already-approved in-flight plan authored before rule 14 shipped keeps
    # validating unchanged on resume.
    if [ "$rule14_grandfathered" -ne 1 ] && [ "$kind" = "code" ] \
       && _files_touch_shipped "$files" && [ "$activation" != "1" ]; then
      errors+=("rule 14: item '$slug' is product-source (kind: code, files: touches scripts/|workflows/|claude/) but carries no activation: block")
    fi
    # Rule 15: keystone: (when present) is a spike-only marker whose only
    # meaningful value is `true` — a keystone spike halts /build for operator
    # verdict-review before dependents build (temperloop#526). It is meaningless
    # on a code item (which merges through the normal gate) so a keystone: on a
    # non-spike item is a plan defect. An empty value = field absent = no gate.
    if [ -n "$keystone" ]; then
      if [ "$keystone" != "true" ]; then
        errors+=("rule 15: item '$slug' keystone '$keystone' must be 'true' (the only meaningful value) or absent")
      fi
      # kind defaults to code when unset; a keystone marker requires kind: spike.
      if [ "${kind:-code}" != "spike" ]; then
        errors+=("rule 15: item '$slug' carries keystone: but is not kind: spike (keystone is a spike-only review-gate marker)")
      fi
    fi
    # Rule 16: a cost: block (present = the item has outsized execution spend,
    # foundation#1059) MUST carry a because: entry naming the cost driver — a
    # bare "expensive" with no reason is uninformative at the approval surface.
    # budget: stays optional. (Display-only field; /build surfaces it at the
    # per-item approval preview so a large spend isn't buried in a plain item.)
    if [ "$cost" = "1" ] && [ -z "$cost_because" ]; then
      errors+=("rule 16: item '$slug' has a cost: block but no because: (name the driver — deep-research | agent-fanout | large-eval | <freeform>)")
    fi
    # Rule 5/8: depends-on + after refs must exist in this plan.
    for tok in $(split_list "$dep"); do
      [[ ",$(IFS=,; echo "${all_slugs[*]}")," == *",$tok,"* ]] \
        || errors+=("rule 5: item '$slug' depends-on '$tok' which is not a slug in this plan")
    done
    for tok in $(split_list "$aft"); do
      [[ ",$(IFS=,; echo "${all_slugs[*]}")," == *",$tok,"* ]] \
        || errors+=("rule 8: item '$slug' after '$tok' which is not a slug in this plan")
    done
  done <<<"$records"

  # Rule 8 (acyclic): the union depends-on ∪ after must be a DAG. Reuse toposort.
  if ! topo_out="$(compute_levels "$records" 2>/dev/null)"; then
    local cyc
    cyc="$(jq -r '.cycle // [] | join(" -> ")' <<<"$topo_out" 2>/dev/null || true)"
    errors+=("rule 8: dependency cycle in depends-on ∪ after${cyc:+ ($cyc)}")
  fi

  if [ "${#errors[@]}" -eq 0 ]; then
    jq -cn '{outcome:"VALID"}'
  else
    printf '%s\n' "${errors[@]}" | jq -R . | jq -cs '{outcome:"INVALID", errors:.}'
    exit 1
  fi
}

# --- toposort ----------------------------------------------------------------
# Level 0 = items with in-degree 0 (no depends-on and no after) over the union
# of both edge sets. Emits the {"levels":…,"order":…} object on success; on a
# cycle, prints {"outcome":"CYCLE","cycle":[…]} and returns non-zero.
# `compute_levels` is the shared core (also used by validate's acyclic check).
#
# THIN WRAPPER (L0-a, epic #1910): the walk itself is graph.sh's `levels`
# subcommand (Kahn's algorithm over the shared edge-list JSON shape) — this
# function's own job is converting plan records into that shape (from=
# prerequisite, to=dependent, one edge per depends-on/after reference) and
# re-rendering graph.sh's answer in this command's historical output grammar
# (an "order" field graph.sh doesn't itself produce, and a leaner two-key
# {"outcome","cycle"} object on a cycle rather than graph.sh's own three-key
# one — the caller-facing grammar is unchanged either way).
compute_levels() {
  local records="$1"
  local rec slug dep aft tok
  local -a slugs=()
  local -a edge_lines=()

  while IFS= read -r rec; do
    [ -n "$rec" ] || continue
    slugs+=("$(rec_slug "$rec")")
  done <<<"$records"

  local slug_list=" ${slugs[*]} "

  while IFS= read -r rec; do
    [ -n "$rec" ] || continue
    slug="$(rec_slug "$rec")"
    dep="$(rec_field "$rec" dependson)"
    aft="$(rec_field "$rec" after)"
    for tok in $(split_list "$dep"); do
      case "$slug_list" in
        *" $tok "*) edge_lines+=("$(jq -cn --arg f "$tok" --arg t "$slug" '{from:$f,to:$t,type:"depends-on"}')") ;;
      esac
    done
    for tok in $(split_list "$aft"); do
      case "$slug_list" in
        *" $tok "*) edge_lines+=("$(jq -cn --arg f "$tok" --arg t "$slug" '{from:$f,to:$t,type:"after"}')") ;;
      esac
    done
  done <<<"$records"

  local nodes_json edges_json input graph_out rc=0
  if [ "${#slugs[@]}" -eq 0 ]; then
    nodes_json="[]"
  else
    nodes_json="$(printf '%s\n' "${slugs[@]}" | jq -R . | jq -cs .)"
  fi
  if [ "${#edge_lines[@]}" -eq 0 ]; then
    edges_json="[]"
  else
    edges_json="$(printf '%s\n' "${edge_lines[@]}" | jq -cs .)"
  fi
  input="$(jq -cn --argjson nodes "$nodes_json" --argjson edges "$edges_json" '{nodes:$nodes, edges:$edges}')"

  graph_out="$(printf '%s' "$input" | bash "$PLAN_LIB_DIR/graph.sh" levels -)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    # Re-order the stuck remainder into this plan's own authored order
    # (graph.sh reports it alphabetically; the historical awk Kahn reported
    # it in file order) and drop graph.sh's extra partial-`levels` field —
    # this command's cycle grammar has always been the leaner two-key form.
    jq -cn --argjson order "$nodes_json" --argjson cyc "$(jq -c '.cycle' <<<"$graph_out")" \
      '{outcome:"CYCLE", cycle: ($order | map(select(. as $s | $cyc | index($s) != null)))}'
    return 1
  fi
  jq -c --argjson order "$nodes_json" '. + {order: $order}' <<<"$graph_out"
}

cmd_toposort() {
  local file="$1" records out
  [ -f "$file" ] || die "plan file '$file' does not exist"
  records="$(parse_items "$file")"
  [ -n "$records" ] || die "no items found under '## Items' in '$file'"
  if out="$(compute_levels "$records")"; then
    printf '%s\n' "$out"
  else
    printf '%s\n' "$out"
    exit 1
  fi
}

# --- writeback ---------------------------------------------------------------
# Flip the named item's checkbox sentinel and stamp sub-lines, then PUT the
# patched note via the _plan_vault_write seam. A vault path is derived from the
# file path's tail under the vault root (Plans/<name>.md); the orchestrator
# always passes a path under the configured vault root, so the REST
# vault-relative path is the segment after the vault root.
cmd_writeback() {
  local file="" slug="" sentinel="" pr="" pushed_sha="" speculative="" run_status="" has_run_status=0
  # temperloop#2083. `merge_blocked` is a HOLD, not a pointer, so it is STICKY:
  # unlike the stamps below, an existing sub-line is carried through untouched
  # by any writeback that does not name it, and clearing it takes an explicit
  # --clear-merge-blocked. A hold that a later sentinel flip could silently drop
  # is the same silent-loss bug as never persisting it (an unstamped dual-build
  # PR reaching Step 4's merge gate, ADR 0040).
  local merge_blocked="" clear_merge_blocked=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --slug)        [ $# -ge 2 ] || usage; slug="$2"; shift ;;
      --sentinel)    [ $# -ge 2 ] || usage; sentinel="$2"; shift ;;
      --pr)          [ $# -ge 2 ] || usage; pr="$2"; shift ;;
      --pushed-sha)  [ $# -ge 2 ] || usage; pushed_sha="$2"; shift ;;
      --speculative) speculative=1 ;;
      --run-status)  [ $# -ge 2 ] || usage; run_status="$2"; has_run_status=1; shift ;;
      --merge-blocked) [ $# -ge 2 ] || usage; merge_blocked="$2"; shift ;;
      --clear-merge-blocked) clear_merge_blocked=1 ;;
      --*)           usage ;;
      *)             if [ -z "$file" ]; then file="$1"; else usage; fi ;;
    esac
    shift
  done
  [ -n "$file" ]     || die "writeback requires <planFile>"
  [ -n "$slug" ]     || die "writeback requires --slug"
  [ -n "$sentinel" ] || die "writeback requires --sentinel"
  [ -f "$file" ]     || die "plan file '$file' does not exist"
  if [ -n "$merge_blocked" ] && [ "$clear_merge_blocked" = 1 ]; then
    die "--merge-blocked and --clear-merge-blocked are mutually exclusive"
  fi
  case "$sentinel" in
    ' '|~|m|'>'|x|v|-) sentinel="[$sentinel]" ;;         # bare char form
    '[ ]'|'[~]'|'[m]'|'[>]'|'[x]'|'[v]'|'[-]') : ;;      # bracketed form
    *) die "invalid sentinel '$sentinel' (one of: [ ] [~] [m] [>] [x] [v] [-])" ;;
  esac

  # Confirm the slug exists.
  local records
  records="$(parse_items "$file")"
  grep -q "^${slug}$(printf '\037')" <<<"$records" \
    || die "slug '$slug' not found in '$file'"

  # Patch in a tmp copy: flip the sentinel on the slug's item header line, then
  # stamp/replace sub-lines within that item block.
  local tmp
  tmp="$(mktemp)"
  PLAN_SLUG="$slug" PLAN_SENTINEL="$sentinel" PLAN_PR="$pr" \
  PLAN_PUSHED_SHA="$pushed_sha" PLAN_SPECULATIVE="$speculative" \
  PLAN_RUN_STATUS="$run_status" PLAN_HAS_RUN_STATUS="$has_run_status" \
  PLAN_MERGE_BLOCKED="$merge_blocked" PLAN_CLEAR_MERGE_BLOCKED="$clear_merge_blocked" \
  awk '
    BEGIN {
      slug=ENVIRON["PLAN_SLUG"]; sent=ENVIRON["PLAN_SENTINEL"]
      pr=ENVIRON["PLAN_PR"]; sha=ENVIRON["PLAN_PUSHED_SHA"]
      spec=ENVIRON["PLAN_SPECULATIVE"]; rs=ENVIRON["PLAN_RUN_STATUS"]
      has_rs=ENVIRON["PLAN_HAS_RUN_STATUS"]
      mb=ENVIRON["PLAN_MERGE_BLOCKED"]; mb_clear=ENVIRON["PLAN_CLEAR_MERGE_BLOCKED"]
      in_item=0; pr_done=0; sha_done=0; spec_done=0; rs_done=0; mb_done=0
    }
    # leaving the target item block: flush any not-yet-present sub-lines.
    function flush_stamps() {
      if (pr!="" && !pr_done)   print "  - pr: " pr
      if (sha!="" && !sha_done) print "  - pushed_sha: " sha
      if (spec=="1" && !spec_done) print "  - speculative: true"
      if (has_rs=="1" && !rs_done) print "  - Run-status: " rs
      if (mb!="" && !mb_done) print "  - merge_blocked: " mb
    }
    # any item header line
    /^[[:space:]]*-[[:space:]]*\[.\]/ {
      if (in_item) { flush_stamps(); in_item=0 }
      line=$0
      is_target = (index(line, "`slug: " slug "`")>0 || index(line, "`slug:" slug "`")>0)
      if (is_target) {
        in_item=1
        # replace the [.] sentinel with the requested one
        sub(/\[.\]/, sent, line)
        print line
        next
      }
    }
    # inside the target block: replace existing stamp sub-lines in place
    in_item && /^[[:space:]]*-[[:space:]]*pr:/ {
      if (pr!="") { print "  - pr: " pr; pr_done=1 } ; next
    }
    in_item && /^[[:space:]]*-[[:space:]]*pushed_sha:/ {
      if (sha!="") { print "  - pushed_sha: " sha; sha_done=1 } ; next
    }
    in_item && /^[[:space:]]*-[[:space:]]*speculative:/ {
      if (spec=="1") { print "  - speculative: true"; spec_done=1 } ; next
    }
    in_item && /^[[:space:]]*-[[:space:]]*Run-status:/ {
      if (has_rs=="1") { print "  - Run-status: " rs; rs_done=1 } ; next
    }
    # STICKY, by design: an existing hold is re-printed verbatim when this
    # writeback names neither flag. The neighbours above drop their sub-line in
    # that case; for a merge HOLD that would mean any later sentinel flip
    # silently un-blocks an unstamped dual-build PR.
    in_item && /^[[:space:]]*-[[:space:]]*merge_blocked:/ {
      if (mb_clear=="1") { next }
      if (mb!="") { print "  - merge_blocked: " mb; mb_done=1; next }
      mb_done=1; print; next
    }
    # leaving the block on a blank line or a new top-level construct
    in_item && (/^[^[:space:]]/ || /^[[:space:]]*$/) {
      flush_stamps(); in_item=0
    }
    { print }
    END { if (in_item) flush_stamps() }
  ' "$file" > "$tmp"

  # Derive the vault-relative path: the tail after a `/Plans/` (or vault root)
  # segment. Falls back to basename under Plans/ for a bare file.
  local vault_path
  case "$file" in
    */Plans/*) vault_path="Plans/${file##*/Plans/}" ;;
    *)         vault_path="Plans/$(basename "$file")" ;;
  esac

  # Pass the plan note's on-disk path as the filesystem-fallback target: when no
  # REST config is resolvable the seam persists the sentinel there instead of
  # failing loud (#342). rc: 0 = WRITTEN, 1 = WRITE_FAILED (loud), 3 = SKIPPED.
  local rc=0
  _plan_vault_write "$vault_path" "$tmp" "$file" || rc=$?
  rm -f "$tmp"
  case "$rc" in
    0)
      jq -cn --arg slug "$slug" --arg sentinel "$sentinel" \
        '{outcome:"WRITTEN", slug:$slug, sentinel:$sentinel}'
      ;;
    3)
      # Soft skip: nothing was persisted, but nothing broke — zero exit so the
      # orchestrator can decide how to proceed rather than aborting the run.
      jq -cn --arg slug "$slug" \
        '{outcome:"WRITE_SKIPPED", slug:$slug, reason:"no REST config and no writable on-disk plan path — see stderr"}' >&3
      ;;
    *)
      jq -cn --arg slug "$slug" \
        '{outcome:"WRITE_FAILED", slug:$slug, error:"vault REST write failed — see stderr"}' >&3
      exit 1
      ;;
  esac
}

# --- roster ------------------------------------------------------------------
# Render ONE dependency level's operator-facing roster (temperloop#1310).
#
#   plan.sh roster <planFile> --level <k> --stage <launch|gate|close> \
#         [--owner-repo <owner/repo>] [--only-slugs <csv>] [--driver <text>] \
#         [--plan-link <text>]
#
# WHY THIS IS CODE AND NOT PROSE. /workflows is an OPT-IN progress surface, so
# the orchestrator's own transcript is the only surface the kernel controls that
# PUSHES a level's composition to the operator. A roster narrated by the
# executing model is exactly the thing that silently degrades under context
# pressure — a dropped row is indistinguishable from "that item was not in this
# level". Rendering it here makes TOTALITY structural: the row set is generated
# by iterating the level's own membership, and the header counts are DERIVED
# from the rows rather than restated beside them, so a worked example (or a real
# render) that does not add up cannot be produced at all.
#
# FAIL-CLOSED. After rendering, the emitted row count is checked against the
# level's membership and the header partition is checked to sum to the total; a
# mismatch is ROSTER_INCOMPLETE + non-zero exit, never a short roster printed as
# if it were whole.
#
# NEVER INFER. An unresolvable value is NAMED, never guessed: an item with no
# `gh_issue:` renders `no issue`, a slug with no parsed item record or a sentinel
# outside plan-schema.md's seven renders the report-only `[?]` marker plus the
# reason. `[?]` is deliberately NOT a plan sentinel and is never written back.
#
# STAGE VOCABULARY (`--stage launch`) — a closed set of seven, derived from the
# seven sentinels plan-schema.md § Status sentinels defines rather than adding an
# eighth, so the report cannot drift from the note it renders. Tested in this
# precedence, which is what keeps a narrowed 3d-esc re-drive honest:
#   terminal     [x] [>] [v] [-] [m] — nothing this pass drives
#   parked       still-open, but outside a non-empty --only-slugs
#   continuation named in --only-slugs (the escalation re-drive)
#   fresh        [ ]
#   resume       [~] carrying pr:
#   speculative  [~] + speculative: true
#   respawn      any other [~]
# Only the last five count toward the header's "active" (to-be-driven) count.
#
# Output is a plain-text block on stdout (an operator report, not a machine
# record); argument/parse errors still take the file-wide structured ERROR path.
cmd_roster() {
  local file="" level="" stage="" owner_repo="" only_slugs="" driver="" plan_link=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --level)      [ $# -ge 2 ] || usage; level="$2"; shift ;;
      --stage)      [ $# -ge 2 ] || usage; stage="$2"; shift ;;
      --owner-repo) [ $# -ge 2 ] || usage; owner_repo="$2"; shift ;;
      --only-slugs) [ $# -ge 2 ] || usage; only_slugs="$2"; shift ;;
      --driver)     [ $# -ge 2 ] || usage; driver="$2"; shift ;;
      --plan-link)  [ $# -ge 2 ] || usage; plan_link="$2"; shift ;;
      --*)          usage ;;
      *)            if [ -z "$file" ]; then file="$1"; else usage; fi ;;
    esac
    shift
  done
  [ -n "$file" ] || die "roster requires <planFile>"
  [ -f "$file" ] || die "plan file '$file' does not exist"
  case "$stage" in
    launch|gate|close) : ;;
    *) die "roster requires --stage launch|gate|close" ;;
  esac
  case "$level" in
    ''|*[!0-9]*) die "roster requires --level <non-negative integer>" ;;
  esac

  local records levels_json slugs
  records="$(parse_items "$file")"
  [ -n "$records" ] || die "no items found under '## Items' in '$file'"
  levels_json="$(compute_levels "$records")" \
    || die "dependency cycle in '$file' — run 'plan.sh toposort' for the cycle"
  slugs="$(printf '%s\n' "$levels_json" | jq -r --argjson k "$level" '.levels[$k] // [] | .[]')"
  [ -n "$slugs" ] || die "level $level has no items in '$file'"

  local members=0 rows_n=0 active=0 n_merge=0 n_merged=0 n_open=0 n_skipped=0 n_other=0
  local w_slug=4 w_ref=3 row US
  US="$(printf '\037')"
  local rows=() slug rec sentinel mark gh irepo ref kind pr spec rs in_only tok
  local stage_s next_s disp rest

  while IFS= read -r slug; do
    [ -n "$slug" ] || continue
    members=$((members + 1))
    rec="$(grep -m1 -- "^${slug}$(printf '\037')" <<<"$records" || true)"
    if [ -z "$rec" ]; then
      # Totality over inference: the level says this slug is a member, so it gets
      # a row naming what could not be established — it is never dropped.
      rows+=("[?]${US}${slug}${US}no issue${US}no item record parsed for this slug — investigate before advancing")
      [ "${#slug}" -le "$w_slug" ] || w_slug="${#slug}"
      rows_n=$((rows_n + 1)); n_other=$((n_other + 1))
      continue
    fi
    sentinel="$(rec_field "$rec" sentinel)"
    case "$sentinel" in
      ' ') mark='[ ]' ;;
      '~'|'m'|'x'|'v'|'-'|'>') mark="[$sentinel]" ;;
      *) mark='[?]' ;;
    esac
    gh="$(rec_field "$rec" gh_issue)"
    irepo="$(rec_field "$rec" repo)"
    if [ -z "$gh" ]; then
      ref="no issue"
    elif [ -n "$irepo" ] && [ -n "$owner_repo" ] && [ "$irepo" != "$owner_repo" ]; then
      ref="${irepo}#${gh}"
    else
      ref="#${gh}"
    fi
    kind="$(rec_field "$rec" kind)"
    [ -n "$kind" ] || kind="code"
    pr="$(rec_field "$rec" pr)"
    spec="$(rec_field "$rec" speculative)"
    mblk="$(rec_field "$rec" merge_blocked)"
    rs="$(rec_field "$rec" run_status)"

    in_only=0
    for tok in $(split_list "$only_slugs"); do
      if [ "$tok" = "$slug" ]; then in_only=1; fi
    done

    if [ "$stage" = launch ]; then
      case "$mark" in
        '[x]'|'[>]'|'[v]'|'[-]'|'[m]') stage_s="terminal"; next_s="not driven this pass" ;;
        '[ ]'|'[~]')
          if [ -n "$only_slugs" ] && [ "$in_only" -eq 0 ]; then
            # A narrowed re-drive (3d-esc continuation) drives ONLY --only-slugs;
            # every other still-open sibling is parked, not silently dropped.
            stage_s="parked"; next_s="not driven this pass"
          elif [ "$in_only" -eq 1 ]; then
            stage_s="continuation"; next_s="3c re-spawn (escalation continuation)"
          elif [ "$mark" = '[ ]' ]; then
            stage_s="fresh"; next_s="3a claim"
          elif [ -n "$pr" ]; then
            stage_s="resume"; next_s="3g re-attach PR #${pr}"
          elif [ "$spec" = "true" ]; then
            stage_s="speculative"; next_s="3f step 0.5 base-currency check"
          else
            stage_s="respawn"; next_s="3c re-spawn"
          fi ;;
        *) stage_s="stage unknown — sentinel is not one of plan-schema's seven"
           next_s="investigate before advancing" ;;
      esac
      rest="$(printf '%-5s  %s → %s' "$kind" "$stage_s" "$next_s")"
      # "active" = the items THIS pass will actually drive. A terminal, parked,
      # or unreadable-sentinel row is reported but not counted, so an all-terminal
      # level reads as the no-op it is instead of looking like work.
      case "$stage_s" in
        fresh|continuation|resume|speculative|respawn) active=$((active + 1)) ;;
      esac
    else
      case "$mark" in
        '[x]') disp="merged${pr:+ in PR #$pr}"; n_merged=$((n_merged + 1)) ;;
        '[>]') disp="as-you-go merge in flight — awaiting confirmed MERGED${pr:+ (PR #$pr)}"
               n_other=$((n_other + 1)) ;;
        '[m]')
          # temperloop#2083. A `merge_blocked` item parks `[m]` with an open,
          # green PR — indistinguishable here from a merge-eligible one unless
          # the hold is read back off the note. It is HELD, not failed, so it is
          # reported and counted, just never as part of the merge set.
          if [ -n "$mblk" ]; then
            disp="MERGE BLOCKED (${mblk}) — held out of the merge set${pr:+ (PR #$pr)}"
            n_other=$((n_other + 1)); n_open=$((n_open + 1))
          elif [ "$stage" = gate ]; then
            disp="in the merge set — mergeability detailed above${pr:+ (PR #$pr)}"
            n_merge=$((n_merge + 1)); n_open=$((n_open + 1))
          else
            disp="left open — awaiting manual merge${pr:+ (PR #$pr)}"
            n_merge=$((n_merge + 1)); n_open=$((n_open + 1))
          fi ;;
        '[v]') disp="verdict captured"; n_other=$((n_other + 1)) ;;
        '[-]') disp="skipped"; n_skipped=$((n_skipped + 1)) ;;
        '[~]') disp="still in flight — not in the merge set"; n_other=$((n_other + 1)) ;;
        '[ ]') disp="never driven this level — itself a finding"; n_other=$((n_other + 1)) ;;
        *) disp="disposition unknown — plan sentinel unreadable; investigate before advancing"
           n_other=$((n_other + 1)) ;;
      esac
      [ -z "$rs" ] || disp="${disp} — ${rs}"
      rest="$disp"
    fi
    rows+=("${mark}${US}${slug}${US}${ref}${US}${rest}")
    [ "${#slug}" -le "$w_slug" ] || w_slug="${#slug}"
    [ "${#ref}" -le "$w_ref" ] || w_ref="${#ref}"
    rows_n=$((rows_n + 1))
  done <<<"$slugs"

  # FAIL-CLOSED totality check. The header partition is derived from the rows,
  # so this is what makes "the counts equal the rows shown" a property of the
  # renderer rather than a convention a future editor has to remember.
  if [ "$rows_n" -ne "$members" ]; then
    jq -cn --argjson rows "$rows_n" --argjson members "$members" --argjson level "$level" \
      '{outcome:"ROSTER_INCOMPLETE", level:$level, members:$members, rows:$rows,
        error:"roster rendered fewer rows than the level has items"}' >&3
    exit 1
  fi
  case "$stage" in
    gate)
      if [ $((n_merge + n_merged + n_skipped + n_other)) -ne "$members" ]; then
        jq -cn --argjson level "$level" '{outcome:"ROSTER_INCOMPLETE", level:$level,
          error:"disposition partition does not sum to the level item count"}' >&3
        exit 1
      fi ;;
    close)
      if [ $((n_merged + n_open + n_skipped + n_other)) -ne "$members" ]; then
        jq -cn --argjson level "$level" '{outcome:"ROSTER_INCOMPLETE", level:$level,
          error:"close-out partition does not sum to the level item count"}' >&3
        exit 1
      fi ;;
  esac

  case "$stage" in
    launch)
      printf '=== Level %s launch: %s items (%s active)%s%s ===\n' \
        "$level" "$members" "$active" \
        "${owner_repo:+ · $owner_repo}" "${plan_link:+ · $plan_link}" ;;
    gate)
      printf -- '--- Level %s disposition: %s items · %s in the merge set · %s outside it ---\n' \
        "$level" "$members" "$n_merge" "$((members - n_merge))" ;;
    close)
      printf -- '--- Level %s closed: %s items · %s merged · %s left open · %s skipped · %s unchanged ---\n' \
        "$level" "$members" "$n_merged" "$n_open" "$n_skipped" "$n_other" ;;
  esac
  local r_mark r_slug r_ref r_rest
  for row in "${rows[@]}"; do
    IFS="$US" read -r r_mark r_slug r_ref r_rest <<<"$row"
    printf '%s %-*s  %-*s  %s\n' "$r_mark" "$w_slug" "$r_slug" "$w_ref" "$r_ref" "$r_rest"
  done
  case "$stage" in
    launch) [ -z "$driver" ] || printf '# driver: %s\n' "$driver" ;;
    close)  [ -z "$driver" ] || printf '# next: %s\n' "$driver" ;;
  esac
}

[ $# -ge 1 ] || usage
cmd="$1"; shift
case "$cmd" in
  validate)  [ $# -eq 1 ] || usage; cmd_validate "$1" ;;
  toposort)  [ $# -eq 1 ] || usage; cmd_toposort "$1" ;;
  writeback) cmd_writeback "$@" ;;
  roster)    cmd_roster "$@" ;;
  *) usage ;;
esac
