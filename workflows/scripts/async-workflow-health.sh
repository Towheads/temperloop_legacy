#!/usr/bin/env bash
#
# async-workflow-health.sh — the ALARM for a red ASYNCHRONOUS (non-PR-triggered)
# GitHub Actions workflow (temperloop#1297).
#
# THE GAP THIS CLOSES. A PR-gated workflow reports to the person who opened
# the PR; nobody has to remember to look. An asynchronous one — a nightly
# `schedule`, a release-tag push, a `workflow_dispatch` — reports to nobody in
# particular, so a broken quality gate sits on `main` until somebody happens
# to open the Actions tab. Both observed instances in this repo were found
# while ALREADY red, weeks in, never at the moment they turned:
#   * install-tier2.yml leaned on GitHub's built-in scheduled-workflow-failure
#     email until its weekly cron was retired (1ecb118). See
#     docs/features/ci-install-tier2.md: "The retired `schedule` trigger leaned
#     on GitHub's built-in *scheduled*-workflow-failure notification, which
#     stopped applying when the cron went."
#   * nightly-macos.yml never had any notification at all — its own header
#     says "There is NO paging, no Slack, no webhook."
# So this detector reports a workflow's CURRENT STATE, not a state TRANSITION:
# a workflow red for seven consecutive nights renders an alarm on every run,
# which is exactly what a transition-only detector would have missed twice.
#
# WHERE THE ALARM LANDS. Its `--format brief` output is embedded in the kernel
# telemetry brief's "1. Attention — what needs you now" section
# (workflows/scripts/telemetry-brief.sh), which `/check-in` renders every day
# and `/telemetry` renders on demand. No new surface was invented: this wires
# into the one that already exists and is already read.
#
# GENERIC OVER WORKFLOWS, NOT A HARDCODED LIST. This script DISCOVERS every
# file in .github/workflows/ and classifies it from its own `on:` triggers.
# workflows/scripts/config/async-workflow-registry.tsv records only the
# DISPOSITION (alarm / exempt) of each discovered asynchronous workflow, and
# the whole thing FAILS CLOSED: a newly-added asynchronous workflow that
# nobody registered is reported as UNREGISTERED on the very same line a red
# run would be reported on. Same for an `on:` block the classifier cannot
# parse (treated as asynchronous), for a registry row naming a workflow file
# that no longer exists, and for an absent or empty registry.
#
# CLASSIFIER (the triggers, not the file name, decide):
#   SYNCHRONOUS  pull_request · pull_request_target · merge_group · a `push`
#                restricted to `branches:` · a bare `push:` (fires on every
#                branch commit). These put a verdict in front of the person
#                who just pushed.
#   ASYNCHRONOUS schedule · workflow_dispatch · repository_dispatch ·
#                workflow_run · a `push` restricted to `tags:` · ANY trigger
#                this classifier does not recognise (fail closed).
#   A workflow is IN SCOPE iff it has at least one asynchronous trigger; its
#   run history is then filtered to those asynchronous EVENTS only, so a
#   hybrid workflow's PR runs never mask its scheduled leg.
#
# RUN SOURCE. Live: `gh run list --workflow <file>`. Under
# ASYNC_WORKFLOW_RUNS_DIR the runs come from `<dir>/<workflow-file>.json`
# instead — a recorded fixture in the exact `gh run list --json` shape. That
# seam is what lets the test suite cover every verdict deterministically with
# no live-network call (kernel principle 3); an absent fixture file is a
# legitimate case (empty run history), not an error.
#
# NEVER BLOCKS ITS READER. Every path exits 0 and every degradation is
# LEGIBLE: no `gh`, no `jq`, an unreadable registry, a failed API call — each
# renders a `skipped — <reason>` line naming what went unchecked, never a
# crash and never a silent pass. A status readout must not be able to fail
# the check-in that reads it.
#
# Usage:
#   async-workflow-health.sh [--format brief|report] [--repo OWNER/REPO]
#
#   --format brief   (default) bullet lines for embedding in the telemetry
#                    brief's Attention section
#   --format report  the same content as a standalone, headed block
#   --repo           OWNER/REPO to query; default is inferred by `gh` from
#                    this checkout
#
# ARGUMENT HANDLING IS DELIBERATELY LENIENT. An unrecognised flag is dropped
# and an unrecognised `--format` value falls back to `brief`, both silently
# and both exiting 0. That is a considered exception to this file's
# every-degradation-is-legible rule, made for the same reason as the rule
# itself: this script runs inside a status readout, and a readout must never
# be able to fail — or noisily editorialise — the check-in that reads it. The
# only callers are the test suite and telemetry-brief.sh, which pass literal
# correct flags.
#
# Settings (registered in workflows/scripts/config/setting-registry.tsv):
#   ASYNC_WORKFLOW_DIR       workflow directory to classify
#   ASYNC_WORKFLOW_REGISTRY  the disposition registry TSV
#   ASYNC_WORKFLOW_RUNS_DIR  fixture dir of recorded `gh run list --json`
#                            output, one `<workflow-file>.json` per workflow;
#                            empty (the default) means query gh live
#   ASYNC_WORKFLOW_RUN_LIMIT how many recent runs to examine per workflow
#   ASYNC_WORKFLOW_GH_TIMEOUT seconds to bound each live `gh run list` call
#
# Kept POSIX-bash-3.2 friendly (no mapfile, no associative arrays) and BSD/GNU
# portable (no GNU-only flags, no `\?` in a basic-regex sed, no bare
# `timeout`) — this repo's gates run on macos-latest as well as ubuntu.

set -uo pipefail

here="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -P "$here/../.." && pwd)"

: "${ASYNC_WORKFLOW_DIR:=$repo_root/.github/workflows}"
: "${ASYNC_WORKFLOW_REGISTRY:=$repo_root/workflows/scripts/config/async-workflow-registry.tsv}"
: "${ASYNC_WORKFLOW_RUNS_DIR:=}"
: "${ASYNC_WORKFLOW_RUN_LIMIT:=30}"
: "${ASYNC_WORKFLOW_GH_TIMEOUT:=30}"

# The ONE bounded-subprocess watchdog (temperloop#256) — stock macOS ships no
# `timeout` binary, so a bare `timeout N gh ...` dies on a fresh Mac. Sourcing
# is guarded and FAILS OPEN: a checkout that vendors a subset without the lib
# still runs, just unbounded, which is the pre-existing behavior rather than a
# new failure. `|| true` because this file runs under `set -uo pipefail`.
if [ -f "$here/lib/portable-timeout.sh" ]; then
  # shellcheck source=workflows/scripts/lib/portable-timeout.sh
  # shellcheck disable=SC1091
  . "$here/lib/portable-timeout.sh" || true
fi
# `command -v` alone: POSIX, and already true for a FUNCTION as well as a
# binary. The `declare -F` half this used to carry was bash-only (temperloop#1776
# — under zsh `declare -F` succeeds for an undefined name), and redundant besides.
if ! command -v run_with_timeout >/dev/null 2>&1; then
  run_with_timeout() { shift; "$@"; }
fi
case "$ASYNC_WORKFLOW_GH_TIMEOUT" in
  ''|*[!0-9]*) ASYNC_WORKFLOW_GH_TIMEOUT=30 ;;
esac

format="brief"
repo_flag=""
while [ $# -gt 0 ]; do
  case "$1" in
    # `shift 2` FAILS (count out of range) when the flag is the LAST argument,
    # and a failed shift does not shift — so `$#` never decreases and this loop
    # spins forever on `--format` with no value. There is no `set -e` to catch
    # the non-zero shift, and `${2:-...}` removes the unset-variable crash that
    # would otherwise have terminated it. Shift the flag first, then the value
    # only if one is actually there. Same class as temperloop#1342.
    --format) format="${2:-brief}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
    --repo) repo_flag="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
    -h|--help) sed -n '2,/^$/p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) shift ;;
  esac
done
case "$format" in
  brief|report) ;;
  *) format="brief" ;;
esac
case "$ASYNC_WORKFLOW_RUN_LIMIT" in
  ''|*[!0-9]*) ASYNC_WORKFLOW_RUN_LIMIT=30 ;;
esac

# ── output buffers ──────────────────────────────────────────────────────────
# Detail bullets accumulate here; the headline is composed last, once the
# counts are known, so the reader sees the verdict before the evidence.
detail=""
n_red=0
n_green=0
n_unknown=0
n_unreg=0
n_exempt=0
n_registered=0

add_detail() { detail="${detail}  - $1
"; }

emit() {  # compose + print, then exit 0 — every caller path ends here
  local headline="$1"
  if [ "$format" = "report" ]; then
    echo "# Asynchronous workflow health — $(TZ="${DISPLAY_TZ:-America/Los_Angeles}" date +%Y-%m-%d)"
    echo
  fi
  printf -- '- %s\n' "$headline"
  [ -n "$detail" ] && printf '%s' "$detail"
  if [ "$format" = "report" ]; then
    echo
    echo "Registry: $ASYNC_WORKFLOW_REGISTRY · workflows: $ASYNC_WORKFLOW_DIR"
    echo "A RED line means the workflow's newest completed asynchronous run FAILED and has stayed failed for the named number of consecutive runs — a state, not a transition."
  fi
  exit 0
}

# ── degradation gates (legible, never silent) ───────────────────────────────
if [ ! -d "$ASYNC_WORKFLOW_DIR" ]; then
  emit "asynchronous workflow health: skipped — no workflow directory at $ASYNC_WORKFLOW_DIR (nothing classified; a red scheduled workflow would go unseen)"
fi
if ! command -v jq >/dev/null 2>&1; then
  emit "asynchronous workflow health: skipped — jq not found, so run history cannot be parsed (a red scheduled workflow would go unseen)"
fi

# ── classifier ──────────────────────────────────────────────────────────────
# Prints two lines for a workflow file:
#   TRIGGERS <space-separated top-level trigger names>
#   PUSHKEYS <space-separated sub-keys of a `push:` block>
# or the single line UNPARSEABLE when no `on:` block could be read at all.
classify() {  # $1 = workflow file path
  awk '
    BEGIN { inon = 0; cur = ""; trig = ""; pushkeys = ""; parsed = 0 }
    # Inline sequence form:  on: [push, pull_request]
    /^on:[ \t]*\[/ {
      line = $0
      sub(/^on:[ \t]*\[/, "", line)
      sub(/\].*$/, "", line)
      gsub(/[ \t"]/, "", line)
      gsub(/,/, " ", line)
      trig = trig " " line
      parsed = 1
      next
    }
    # Inline mapping form:  on: {push: {...}} — deliberately unsupported, and
    # saying so is the whole point: UNPARSEABLE is treated as asynchronous.
    /^on:[ \t]*\{/ { next }
    # Single scalar form:  on: schedule
    /^on:[ \t]+[A-Za-z_]/ {
      line = $0
      sub(/^on:[ \t]+/, "", line)
      sub(/[ \t]*#.*$/, "", line)
      trig = trig " " line
      parsed = 1
      next
    }
    # Block form:  on:  (triggers follow, indented)
    /^on:[ \t]*(#.*)?$/ { inon = 1; parsed = 1; next }
    inon == 1 && /^[^ \t#]/ { inon = 0 }
    inon == 1 && /^  [A-Za-z_]+:/ {
      key = $0
      sub(/^[ \t]+/, "", key)
      sub(/:.*$/, "", key)
      cur = key
      trig = trig " " key
      next
    }
    inon == 1 && cur == "push" && /^    [A-Za-z_]+:/ {
      key = $0
      sub(/^[ \t]+/, "", key)
      sub(/:.*$/, "", key)
      pushkeys = pushkeys " " key
      next
    }
    END {
      if (parsed == 0) { print "UNPARSEABLE"; exit }
      print "TRIGGERS" trig
      print "PUSHKEYS" pushkeys
    }
  ' "$1" 2>/dev/null
}

# async_events <triggers> <pushkeys> -> space-separated gh EVENT names that
# are asynchronous for this workflow (empty = the workflow is synchronous).
async_events() {
  local trig="$1" pushkeys="$2" t out=""
  # `$trig` is deliberately word-split, but it must NOT be glob-expanded: the
  # classifier's inline-sequence arm (`on: [push, "*"]`) strips quotes, so a
  # metacharacter can reach here and expand against the CALLER'S cwd. That
  # both garbles the operator-facing line and — because the filenames it
  # yields never match a real gh event — makes a registered, RED workflow
  # report UNKNOWN, the exact masking this detector exists to prevent. It
  # also makes the verdict depend on where the reader happened to be standing.
  set -f
  for t in $trig; do
    case "$t" in
      pull_request|pull_request_target|merge_group) ;;
      push)
        case " $pushkeys " in
          *" tags "*) out="$out push" ;;
        esac
        ;;
      schedule|workflow_dispatch|repository_dispatch|workflow_run)
        out="$out $t" ;;
      # Fail closed: a trigger this classifier does not know about is assumed
      # to be one nobody is watching.
      *) out="$out $t" ;;
    esac
  done
  set +f
  printf '%s' "${out# }"
}

# ── registry ────────────────────────────────────────────────────────────────
registry_ok=0
if [ -f "$ASYNC_WORKFLOW_REGISTRY" ] && [ -r "$ASYNC_WORKFLOW_REGISTRY" ]; then
  # "Has at least one row that is neither a comment nor blank." awk rather
  # than a grep pipeline so an empty/comments-only registry is a single
  # readable predicate (and to stay clear of SC2143 / lint-pipe-grep-q).
  if awk '
      /^[[:space:]]*#/ { next }
      /^[[:space:]]*$/ { next }
      { found = 1; exit }
      END { exit(found ? 0 : 1) }
    ' "$ASYNC_WORKFLOW_REGISTRY" 2>/dev/null; then
    registry_ok=1
  fi
fi

registry_disposition() {  # $1 = workflow basename -> alarm|exempt|"" (unregistered)
  [ "$registry_ok" -eq 1 ] || { printf ''; return 0; }
  awk -F'\t' -v wf="$1" '
    /^[[:space:]]*#/ { next }
    NF < 2 { next }
    $1 == wf { print $2; found = 1; exit }
  ' "$ASYNC_WORKFLOW_REGISTRY" 2>/dev/null
}

# ── run history ─────────────────────────────────────────────────────────────
runs_json() {  # $1 = workflow basename -> JSON array on stdout, non-zero on failure
  if [ -n "$ASYNC_WORKFLOW_RUNS_DIR" ]; then
    if [ -f "$ASYNC_WORKFLOW_RUNS_DIR/$1.json" ]; then
      cat "$ASYNC_WORKFLOW_RUNS_DIR/$1.json"
    else
      # An absent fixture is a legitimate empty run history, never an error.
      echo '[]'
    fi
    return 0
  fi
  command -v gh >/dev/null 2>&1 || return 1
  # BOUNDED. This runs on the /check-in daily read surface, where the header's
  # central promise is that the detector never blocks its reader — and the call
  # site's `|| true` fence catches a FAILURE, not a HANG. A bound that fires
  # returns non-zero, which falls through to the caller's existing
  # gh_failed=1 -> UNKNOWN branch: legibly unchecked, never silently green.
  if [ -n "$repo_flag" ]; then
    run_with_timeout "$ASYNC_WORKFLOW_GH_TIMEOUT" \
      gh run list --repo "$repo_flag" --workflow "$1" \
      --limit "$ASYNC_WORKFLOW_RUN_LIMIT" \
      --json event,status,conclusion,createdAt,url 2>/dev/null
  else
    (cd "$repo_root" && run_with_timeout "$ASYNC_WORKFLOW_GH_TIMEOUT" \
      gh run list --workflow "$1" \
      --limit "$ASYNC_WORKFLOW_RUN_LIMIT" \
      --json event,status,conclusion,createdAt,url 2>/dev/null)
  fi
}

# verdict <json> <async-events> -> "STATE<TAB>streak<TAB>createdAt<TAB>url<TAB>event"
# STATE ∈ GREEN | RED | EMPTY. `streak` counts CONSECUTIVE non-success runs
# from newest backwards, which is what makes an already-red workflow report
# its true age instead of looking like a fresh one-off.
verdict() {
  printf '%s' "$1" | jq -r --arg evs "$2" '
    ($evs | split(" ") | map(select(length > 0))) as $ev
    | (if type == "array" then . else [] end)
    | [ .[]
        | select((.status // "") == "completed")
        | select((.event // "") as $e | ($ev | index($e)) != null)
        | select((.conclusion // "") as $c
                 | (["success","failure","timed_out","startup_failure","action_required"]
                    | index($c)) != null) ]
    | sort_by(.createdAt // "") | reverse
    | if length == 0 then "EMPTY\t0\t\t\t"
      else
        (reduce .[] as $r ({n: 0, stop: false};
           if .stop then .
           elif ($r.conclusion == "success") then {n: .n, stop: true}
           else {n: (.n + 1), stop: false} end)) as $s
        | .[0] as $newest
        | (if $s.n == 0 then "GREEN" else "RED" end)
          + "\t" + ($s.n | tostring)
          + "\t" + ($newest.createdAt // "")
          + "\t" + ($newest.url // "")
          + "\t" + ($newest.event // "")
      end' 2>/dev/null
}

# ── walk every workflow file ────────────────────────────────────────────────
gh_failed=0
seen_files=""
for wf_path in "$ASYNC_WORKFLOW_DIR"/*.yml "$ASYNC_WORKFLOW_DIR"/*.yaml; do
  [ -f "$wf_path" ] || continue
  wf="$(basename "$wf_path")"
  seen_files="$seen_files $wf"

  cls="$(classify "$wf_path")"
  case "$cls" in
    UNPARSEABLE*)
      trig="__unparseable__"; pushkeys="" ;;
    *)
      trig="$(printf '%s\n' "$cls" | awk '/^TRIGGERS/ { sub(/^TRIGGERS/, ""); print }')"
      pushkeys="$(printf '%s\n' "$cls" | awk '/^PUSHKEYS/ { sub(/^PUSHKEYS/, ""); print }')" ;;
  esac

  evs="$(async_events "$trig" "$pushkeys")"
  [ -n "$evs" ] || continue   # synchronous — reported by the PR it belongs to

  disp="$(registry_disposition "$wf")"
  if [ -z "$disp" ]; then
    n_unreg=$((n_unreg + 1))
    if [ "$registry_ok" -eq 1 ]; then
      add_detail "UNREGISTERED $wf — asynchronous triggers ($evs) but no row in $ASYNC_WORKFLOW_REGISTRY. Add a row (alarm|exempt) so a red run cannot go unwatched."
    else
      add_detail "UNREGISTERED $wf — asynchronous triggers ($evs) and the disposition registry is absent or empty ($ASYNC_WORKFLOW_REGISTRY), so NOTHING here is being watched."
    fi
    continue
  fi
  n_registered=$((n_registered + 1))

  json="$(runs_json "$wf")"
  if [ -z "$json" ]; then
    gh_failed=1
    n_unknown=$((n_unknown + 1))
    add_detail "UNKNOWN $wf — run history unavailable (gh missing, unauthenticated, or the API call failed); this workflow's state went UNCHECKED."
    continue
  fi

  line="$(verdict "$json" "$evs")"
  state="$(printf '%s' "$line" | cut -f1)"
  streak="$(printf '%s' "$line" | cut -f2)"
  when="$(printf '%s' "$line" | cut -f3)"
  url="$(printf '%s' "$line" | cut -f4)"
  event="$(printf '%s' "$line" | cut -f5)"

  case "$state" in
    RED)
      if [ "$disp" = "exempt" ]; then
        n_exempt=$((n_exempt + 1))
        add_detail "exempt $wf — RED ($streak consecutive failed $event run(s), newest $when) but registered \`exempt\`; no alarm raised. $url"
      else
        n_red=$((n_red + 1))
        add_detail "RED $wf — $streak consecutive failed $event run(s), newest $when · $url"
      fi
      ;;
    GREEN)
      if [ "$disp" = "exempt" ]; then
        n_exempt=$((n_exempt + 1))
        add_detail "exempt $wf — newest $event run succeeded $when; registered \`exempt\`."
      else
        n_green=$((n_green + 1))
        add_detail "ok $wf — newest $event run succeeded $when"
      fi
      ;;
    *)
      n_unknown=$((n_unknown + 1))
      add_detail "UNKNOWN $wf — no completed asynchronous run ($evs) in the last $ASYNC_WORKFLOW_RUN_LIMIT runs; nothing to judge, so nothing is being verified either."
      ;;
  esac
done

# ── stale registry rows (fail closed the other direction) ───────────────────
if [ "$registry_ok" -eq 1 ]; then
  # `|| [ -n "$row_wf" ]` — `read` returns non-zero on a final line with no
  # terminating newline, so without it the last registry row is silently
  # exempt from this half of the fail-closed contract.
  while IFS="$(printf '\t')" read -r row_wf row_disp _rest || [ -n "$row_wf" ]; do
    # Match the comment rule the two awk parsers above already use
    # (`/^[[:space:]]*#/`). A bare `\#*` here saw an INDENTED comment as a
    # workflow name and rendered a fabricated STALE-ROW alarm for it.
    row_wf_trimmed="${row_wf#"${row_wf%%[![:space:]]*}"}"
    case "$row_wf_trimmed" in ''|\#*) continue ;; esac
    row_wf="$row_wf_trimmed"
    [ -n "$row_disp" ] || continue
    case " $seen_files " in
      *" $row_wf "*) ;;
      *)
        n_unreg=$((n_unreg + 1))
        add_detail "STALE-ROW $row_wf — registered in $ASYNC_WORKFLOW_REGISTRY but no such workflow file in $ASYNC_WORKFLOW_DIR; the registry is drifting from the tree."
        ;;
    esac
  done < "$ASYNC_WORKFLOW_REGISTRY"
fi

# ── headline ────────────────────────────────────────────────────────────────
src="gh run list (live)"
[ -n "$ASYNC_WORKFLOW_RUNS_DIR" ] && src="recorded run fixtures @ $ASYNC_WORKFLOW_RUNS_DIR"

if [ "$n_registered" -eq 0 ] && [ "$n_unreg" -eq 0 ]; then
  emit "asynchronous workflow health: no asynchronous workflows found in $ASYNC_WORKFLOW_DIR (every workflow there is PR/branch-triggered, so its verdict already reaches whoever pushed)"
fi

alarms=$((n_red + n_unreg + n_unknown))
if [ "$alarms" -gt 0 ]; then
  headline="asynchronous workflow health: NEEDS ATTENTION — $n_red red · $n_unreg unregistered/stale · $n_unknown unknown · $n_green green · $n_exempt exempt (source: $src)"
else
  headline="asynchronous workflow health: all clear — $n_green green · $n_exempt exempt (source: $src)"
fi
[ "$gh_failed" -eq 1 ] && headline="$headline [degraded: at least one workflow went unchecked]"

emit "$headline"
