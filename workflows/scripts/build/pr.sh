#!/usr/bin/env bash
#
# build push + PR-open mechanics — the deterministic-machinery script that owns
# the 3f steps of /build (epic #253, spike #245): the closing-keyword
# pre-push scan, the speculative base-currency check, push-by-SHA, and PR-body
# assembly from the worker verdict JSON + plan fields. A step moved here iff
# its behavior is a pure function of observable machine state with a closed
# outcome set; the judgment-shaped halves (rewording an offending commit, the
# BASE_STALE rebase/conflict handling, branch-collision triage) stay
# orchestrator-driven in build.md and branch on these outcomes.
#
#   pr.sh scan <worktreePath>                  # closing-keyword pre-push scan
#   pr.sh base-check <worktreePath>            # speculative base-currency check
#   pr.sh rebase <worktreePath>                # rebase onto fresh origin/<default>
#   pr.sh push <worktreePath> <branch> [--force|--allow-rewrite]  # push HEAD by SHA
#   pr.sh recover-probe <worktreePath> <branch>    # 3c lost-return side-effect probe
#   pr.sh open --verdict <file|-> [--gh-issue N] [--also-closes N,N,...]
#         [--plan-link <target>] [--source <ref>] [--verification-surface-file <path>] \
#         ( --body-only | --update-pr <n> --repo <repo-root>
#           | --repo <repo-root> --branch <b> --title <t> )
#   pr.sh acceptance-extract <bodyFile|->     # inverse of the ## Acceptance recap
#
# `open` assembles the PR body from the worker's verdict JSON (summary,
# acceptance_results — the 3d return contract) plus the plan fields, then runs
# `gh pr create`. The ## Verification section's body is resolved by precedence
# (the #418 inflow-cut): --verification-surface-file <path> if given, else the
# verdict's `.verification_surface_path` (a file the worker wrote in its
# worktree and returned only the path to), else the inline `.verification_surface`
# field (back-compat), else the acceptance recap. Reading the surface from a
# file keeps that large block OUT of the orchestrator's context — it never
# round-trips through the verdict JSON. Issue linkage lives HERE and only
# here: one bare `Closes #N` line per gh_issue/also_closes entry, each on its
# own line, never combined, never backticked (GitHub silently ignores
# backticked keywords, and `Closes #1 and #2` closes only #1). Either flag
# also accepts a fully-qualified `owner/repo#N` ref (the `repo:` field's
# cross-repo case — plan-schema.md § Optional `repo:` field), emitted as
# `Closes owner/repo#N`; a bare `Closes #N` is same-repo only. Because linkage
# lives here and only here, a bare closing-keyword LINE the worker wrote into
# its own verification surface is STRIPPED from that surface before the body is
# assembled (temperloop#1023 — see strip_surface_closes below), so the assembled
# body carries exactly one linkage block. `--body-only` prints the assembled
# body verbatim and exits — the dry mode tests assert on. `--update-pr <n>`
# (temperloop#1846) assembles the body through this exact same path but runs
# `gh pr edit <n> --body` instead of create — the .mjs re-renders an open PR's
# body after a CI-fix re-review round adds §3e reviewer evidence the original
# 3f body couldn't carry.
#
# The assembled body is BOUNDED before it reaches gh (temperloop#2009): a body
# over $BUILD_PR_BODY_MAX_BYTES is truncated locally — reviewer prose first,
# oldest review round first — rather than sent and rejected with `GraphQL: Body
# is too long` after the worker, the reviewers, the gates and the push have all
# already succeeded. The bound is applied at ONE site above every arm, so
# `--body-only`, `gh pr create` and `gh pr edit` can never disagree about the
# outbound body; a body inside the cap is passed through byte-for-byte. See
# bound_body below for the full ladder and what it never cuts.
#
# `acceptance-extract` is the INVERSE of `open`'s `## Acceptance` recap: it
# reads an assembled PR body back into the worker's `acceptance_results`
# entries. The recap's evidence rides its own nested line (temperloop#1267), so
# the criterion/evidence split is POSITIONAL and both survive an embedded
# ` — ` byte-exactly — the round-trip property `open`'s tests assert, and the
# reason a downstream reader (replay, a retro judge, an auditing human) has one
# owned extractor to call rather than a per-consumer parse-by-eye.
#
# Output contract — CLOSED outcome set, one structured JSON line per outcome
# (exceptions: `open --body-only` prints the raw body and `acceptance-extract`
# prints a JSON array, neither in an outcome wrapper):
#   scan       → {"outcome":"SCAN_CLEAN"} |
#                {"outcome":"SCAN_BLOCKED","matches":[…]} + non-zero exit
#   base-check → {"outcome":"BASE_CURRENT"|"BASE_STALE","merge_base":…,"tip":…}
#   rebase     → {"outcome":"REBASED","base":…,"tip":…,"sha":…,"rebase_needed":bool} |
#                {"outcome":"REBASE_CONFLICT","base":…,"tip":…,"error":…} + non-zero exit |
#                {"outcome":"DIRTY_WORKTREE","base":…,"tip":…,"rebase_needed":bool,
#                 "dirty_files":N,"dirty_paths":[…]} + non-zero exit
#                (DIRTY_WORKTREE = git REFUSED to start the rebase because the
#                 tree carries uncommitted TRACKED-file edits — a distinct state
#                 from a content conflict, which REBASE_CONFLICT now means and
#                 only means; rebase_needed=false says base == tip, i.e. no
#                 rebase was required at all — temperloop#735)
#   push       → {"outcome":"PUSHED","sha":…,"branch":…,"forced":bool,
#                 "pr_lookup":"ok"|"unavailable","pr_number":N|null} |
#                {"outcome":"PUSHED_UNWATCHED","sha":…,"branch":…,"forced":bool,
#                 "pr_lookup":"ok","pr_number":N,"pr_head_ref":…,"pr_url":…,
#                 "stale_head_cause":"branch-mismatch","error":…} + non-zero exit |
#                {"outcome":"PUSH_REJECTED","sha":…,"branch":…,"forced":bool,
#                 "lease":…|null,"refused_reason":"remote_not_superseded"
#                   |"supersede_probe_failed"|null,"remote_tip":…|null,
#                 "remote_only_commits":N|null,"error":…} + non-zero exit
#                (refused_reason is temperloop#2103 round 3: a REQUESTED rewrite
#                 this script declined to issue because the remote tip is not
#                 superseded by local history — a genuine branch-content
#                 collision — or because that question could not be answered. No
#                 force is issued, the plain push is rejected loudly by git, and
#                 origin is untouched; null on every other rejection.)
#                (PUSHED_UNWATCHED is temperloop#1688: the push LANDED, but the
#                 ref it landed on is watched by NO open PR while another open PR
#                 for the same slug sits on a DIFFERENT head ref — the
#                 `build/<slug>` vs `fix/<slug>` two-ref split. `stale_head_cause`
#                 is what tells that apart from GitHub's post-force-push head lag;
#                 see pr_survey() and cmd_push() below.)
#                (forced=true only when a genuine rewrite needed a force; a
#                 requested rewrite that is a pure fast-forward downgrades to a
#                 plain push, forced=false — #335. When forced=true the payload
#                 also carries "lease":<the remote sha the force was leased
#                 against>: the force is ALWAYS
#                 --force-with-lease=<ref>:<sha> over a value read FIRST, never
#                 a bare --force — temperloop#2103.)
#   open       → {"outcome":"PR_OPENED","pr_number":…,"url":…,
#                 "surface_closes_stripped":N} |
#                {"outcome":"EXISTS","pr_number":…,"url":…,
#                 "surface_closes_stripped":N} |
#                {"outcome":"BODY_UPDATED","pr_number":…,
#                 "surface_closes_stripped":N}
#                (EXISTS when gh reports a PR for that branch already exists — adopt it;
#                 BODY_UPDATED for the --update-pr re-render arm (temperloop#1846);
#                 surface_closes_stripped = how many duplicate bare closing-keyword
#                 lines were removed from the worker's verification surface, normally 0)
#   recover-probe → {"outcome":"RECOVER_NONE"|"RECOVER_DIRTY"|"RECOVER_COMMITTED"
#                    |"RECOVER_PUSHED"|"RECOVER_PR_OPEN","sha":…,"branch":…,
#                    "commits_ahead":N,"pushed":bool,"remote_sha":…,
#                    "dirty":bool,"dirty_files":N,
#                    "verification_surface_present":bool[,"pr_number":N,"url":…]}
#   acceptance-extract → [{"passed":bool,"criterion":…,"evidence":…|null,
#                          "deferred_host_config":…|null,
#                          "discrimination_evidence":…|null}, …]
#   error      → {"outcome":"ERROR","error":…} + non-zero exit
set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo '{"outcome":"ERROR","error":"jq not found"}'; exit 1; }

# The 3f step-0 closing-keyword pattern (the ec8d5fd class): any GitHub
# closing keyword followed by an issue reference, case-insensitive.
CLOSING_RE='\b(close[sd]?|fix(e[sd])?|resolve[sd]?)\b[[:space:]]*#[0-9]+'

# Settings come from the sibling build.config.sh when this checkout vendors it
# (the same shape issue-state.sh uses); the `:=` lines below are the layer-6
# fallback for a consuming checkout that carries pr.sh without that config file.
# They are byte-identical duplicates of build.config.sh's own literals, which
# stays the single owning site for both — setting-registry.tsv records ONE row
# per name, citing build.config.sh (see that registry's own header).
PR_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=workflows/scripts/build/build.config.sh
[ -f "$PR_HERE/build.config.sh" ] && . "$PR_HERE/build.config.sh"
: "${BUILD_PR_BODY_MAX_BYTES:=60000}"                  # non-vendoring-checkout fallback
: "${SPEND_TRANSCRIPT_ROOT:=$HOME/.claude/projects}"   # non-vendoring-checkout fallback
# A non-numeric or zero override would disable the bound entirely, which is not
# an option this setting offers (the API rejection it prevents is unconditional).
# The floor is structural rather than a second setting: the linkage lines, the
# attribution footer and one truncation marker are the parts no rung of
# bound_body may cut, so a cap below their combined size could not be honored by
# any truncation at all. Clamping keeps "the outbound body is within the cap" an
# invariant for every value an operator can set.
case "$BUILD_PR_BODY_MAX_BYTES" in
  ''|*[!0-9]*|0) BUILD_PR_BODY_MAX_BYTES=60000 ;;
esac
[ "$BUILD_PR_BODY_MAX_BYTES" -lt 2000 ] && BUILD_PR_BODY_MAX_BYTES=2000

# fd 3 = the script's real stdout. Helpers run inside command substitutions,
# where a die()'s ERROR line would be captured by the caller instead of
# reaching the orchestrator — emitting via fd 3 keeps the structured error on
# the real stdout regardless of call context.
exec 3>&1
die() {
  jq -cn --arg error "$1" '{outcome:"ERROR", error:$error}' >&3
  exit 1
}

usage() {
  die "usage: pr.sh scan <worktreePath> | base-check <worktreePath> | rebase <worktreePath> | push <worktreePath> <branch> [--force|--allow-rewrite] | recover-probe <worktreePath> <branch> | open --verdict <file|-> [--gh-issue N] [--also-closes N,N,...] [--plan-link <target>] [--source <ref>] [--verification-surface-file <path>] (--body-only | --update-pr <n> --repo <repo-root> | --repo <repo-root> --branch <branch> --title <title>) | acceptance-extract <bodyFile|->"
}

# Physical-path resolve for an EXISTING dir (portable — no GNU readlink -f).
abs_dir() { (cd "$1" 2>/dev/null && pwd -P); }

# Resolve + validate a worktree path: must exist and be a git work-tree
# toplevel (a linked worktree is its own toplevel, so the orchestrator's
# deterministic `<repo>.wt/<slug>` path passes; a subdir does not).
resolve_worktree() {
  local arg="$1" wt top
  wt="$(abs_dir "$arg")" || die "worktree path '$arg' does not exist"
  top="$(git -C "$wt" rev-parse --show-toplevel 2>/dev/null)" || die "worktree path '$arg' is not inside a git work tree"
  top="$(abs_dir "$top")"
  [ "$wt" = "$top" ] || die "worktree path '$arg' is not a git toplevel (toplevel is '$top')"
  printf '%s\n' "$wt"
}

# The repo's default branch, from origin's HEAD (falling back to main/master).
default_branch() {
  local repo="$1" ref b
  if ref="$(git -C "$repo" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)"; then
    printf '%s\n' "${ref#origin/}"
    return 0
  fi
  for b in main master; do
    if git -C "$repo" show-ref --verify --quiet "refs/remotes/origin/$b"; then
      printf '%s\n' "$b"
      return 0
    fi
  done
  return 1
}

# Branch names feed a refspec; reject anything git itself would reject rather
# than letting the push error surface as a confusing rejection.
validate_branch() {
  local branch="$1"
  [ -n "$branch" ] || die "branch name is empty"
  git check-ref-format "refs/heads/$branch" >/dev/null 2>&1 \
    || die "branch '$branch' is not a valid git branch name"
}

# Issue refs feed `Closes` lines: either plain digits (bare same-repo
# `Closes #N`) or a fully-qualified `owner/repo#N` cross-repo ref (the
# `repo:` field case — plan-schema.md § Optional `repo:` field). A bare
# `Closes #N` is same-repo only (CLAUDE.md § Issue linkage), so a cross-repo
# close must carry the owner/repo# qualifier — see closes_line() below.
_ISSUE_QUALIFIED_RE='^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+$'
validate_issue() {
  [[ "$1" =~ ^[0-9]+$ ]] && return 0
  [[ "$1" =~ $_ISSUE_QUALIFIED_RE ]] && return 0
  die "issue ref '$1' invalid — must be digits, or owner/repo#N for a cross-repo close"
}

# Format one issue ref as a bare `Closes` line (no trailing newline — the
# caller appends $'\n' itself, since a $(...) capture would strip it): a
# qualified owner/repo#N ref is emitted as-is (Closes owner/repo#N); a plain
# number gets the leading # (Closes #N).
closes_line() {
  case "$1" in
    *'#'*) printf 'Closes %s' "$1" ;;
    *)     printf 'Closes #%s' "$1" ;;
  esac
}

# --- scan: 3f step 0 — closing-keyword pre-push scan --------------------------
# Pure function of the worker's unpushed commit messages: grep every commit
# body in origin/<default>..HEAD for closing keywords. A match is the ec8d5fd
# failure mode (GitHub scans default-branch commit messages, not just the PR
# body, so a stray `Closes #N` auto-closes on merge); linkage belongs in the
# PR body alone, so a hit BLOCKS the push.
cmd_scan() {
  local wt default log matches
  wt="$(resolve_worktree "$1")"
  default="$(default_branch "$wt")" || die "cannot resolve origin's default branch in '$wt'"
  log="$(git -C "$wt" log "origin/$default..HEAD" --format=%B 2>&1)" \
    || die "git log origin/$default..HEAD failed in '$wt': $log"
  matches="$(grep -iE "$CLOSING_RE" <<<"$log" || true)"
  if [ -z "$matches" ]; then
    jq -cn '{outcome:"SCAN_CLEAN"}'
  else
    jq -cn --arg m "$matches" '{outcome:"SCAN_BLOCKED", matches:($m|split("\n"))}'
    exit 1
  fi
}

# --- base-check: 3f step 0.5 — speculative base-currency check ----------------
# Fetch the default branch, then compare merge-base(HEAD, origin/<default>)
# against the origin/<default> tip: equal → the worker's base is current
# (BASE_CURRENT, safe to push); behind → BASE_STALE (pushing would silently
# drop the merged level-k changes in overlapping regions — the orchestrator
# runs the rebase-then-reverify / discard-and-respawn flow, not this script).
cmd_base_check() {
  local wt default mb tip outcome out
  wt="$(resolve_worktree "$1")"
  default="$(default_branch "$wt")" || die "cannot resolve origin's default branch in '$wt'"
  out="$(git -C "$wt" fetch origin "$default" 2>&1)" \
    || die "git fetch origin $default failed in '$wt': $out"
  tip="$(git -C "$wt" rev-parse "origin/$default")" || die "cannot resolve origin/$default tip"
  mb="$(git -C "$wt" merge-base HEAD "origin/$default" 2>/dev/null)" \
    || die "no merge base between HEAD and origin/$default in '$wt'"
  if [ "$mb" = "$tip" ]; then outcome="BASE_CURRENT"; else outcome="BASE_STALE"; fi
  jq -cn --arg outcome "$outcome" --arg mb "$mb" --arg tip "$tip" \
    '{outcome:$outcome, merge_base:$mb, tip:$tip}'
}

# --- rebase: 3f step 0.5 — rebase onto fresh origin/<default> ------------------
# The unconditional stale-base guard (#525): a worker branches off
# origin/<default> at the start of its run, but on a fast-moving default a long
# run lets the default advance mid-build — so by push/PR-open time the worker's
# base is stale and the PR's cumulative diff REVERTS whatever merged in between
# (W49 PR#82 / W52 PR#83). Fetch the default fresh, then rebase the worktree's
# HEAD onto its tip so the PR diff carries ONLY the worker's own changes:
#   - DIRTY worktree  → git would REFUSE to rebase at all ("cannot rebase: You
#                       have unstaged changes") → DIRTY_WORKTREE + non-zero exit
#                       (see below — never attempted, so never a conflict)
#   - already current (merge-base == tip) → nothing to replay; the rebase is
#                       SKIPPED entirely → REBASED, rebase_needed:false
#   - behind          → replay the worker's commits onto the new tip, REBASED
#   - CONFLICT        → `git rebase --abort` (leave the worktree clean, NEVER a
#                       half-rebased tree and NEVER a silent revert) → REBASE_CONFLICT
#                       + non-zero exit. The orchestrator escalates this as a
#                       rebase conflict for a human to resolve.
#
# DIRTY_WORKTREE vs REBASE_CONFLICT — two states, two outcomes (temperloop#735).
# git refuses to START a rebase while tracked files carry uncommitted edits, and
# that refusal is a NON-ZERO exit exactly like a content conflict. Branching on
# the exit code alone collapsed the two: a worker that FINISHED (commit made,
# gates green) but left one tracked file unstaged was reported
# {"outcome":"REBASE_CONFLICT","base":X,"tip":X} — base == tip, so no rebase was
# even needed and no conflict existed anywhere — and the orchestrator's
# rebase-conflict escalation would have discarded that finished work.
# The two cases are separable from git's OWN state rather than from its exit
# code or its (localised, reworded-between-releases) stderr prose: `git status
# --porcelain --untracked-files=no` is non-empty iff the tree carries the
# tracked-file edits that make git refuse. So the dirtiness is probed FIRST and
# reported as its own outcome, the rebase is never attempted (nothing to abort,
# and the worker's uncommitted edits are left exactly where they are), and
# REBASE_CONFLICT is left meaning only what it says: a rebase was attempted and
# its replay failed. `rebase_needed` (base != tip) rides both outcomes so the
# orchestrator can see that a DIRTY_WORKTREE with rebase_needed:false is a
# finished worker needing its edits COMMITTED — never a discard.
# Untracked files are deliberately not dirt here: git rebases straight past
# them, and the worktree always carries at least the untracked `.build-guard`.
cmd_rebase() {
  local wt default base tip out sha dirty dirty_files rebase_needed
  wt="$(resolve_worktree "$1")"
  default="$(default_branch "$wt")" || die "cannot resolve origin's default branch in '$wt'"
  out="$(git -C "$wt" fetch origin "$default" 2>&1)" \
    || die "git fetch origin $default failed in '$wt': $out"
  tip="$(git -C "$wt" rev-parse "origin/$default")" || die "cannot resolve origin/$default tip"
  base="$(git -C "$wt" merge-base HEAD "origin/$default" 2>/dev/null)" \
    || die "no merge base between HEAD and origin/$default in '$wt'"
  if [ "$base" = "$tip" ]; then rebase_needed=false; else rebase_needed=true; fi

  # The dirty-vs-conflict split, probed before anything is attempted.
  # stdout ONLY (stderr discarded rather than folded in): a git warning on
  # stderr must never be counted as one of the dirty paths.
  dirty="$(git -C "$wt" status --porcelain --untracked-files=no 2>/dev/null)" \
    || die "git status --porcelain failed in '$wt'"
  if [ -n "$dirty" ]; then
    dirty_files="$(printf '%s\n' "$dirty" | wc -l | tr -d ' ')"
    case "$dirty_files" in ''|*[!0-9]*) dirty_files=0 ;; esac
    jq -cn --arg base "$base" --arg tip "$tip" --argjson rebase_needed "$rebase_needed" \
      --argjson dirty_files "$dirty_files" --arg paths "$dirty" \
      '{outcome:"DIRTY_WORKTREE", base:$base, tip:$tip,
        rebase_needed:$rebase_needed, dirty_files:$dirty_files,
        dirty_paths:($paths|split("\n"))}'
    exit 1
  fi

  # Base already current: there is nothing to replay, so skip the rebase.
  if [ "$rebase_needed" = false ]; then
    sha="$(git -C "$wt" rev-parse HEAD 2>/dev/null)" || die "cannot resolve HEAD in '$wt'"
    jq -cn --arg base "$base" --arg tip "$tip" --arg sha "$sha" \
      '{outcome:"REBASED", base:$base, tip:$tip, sha:$sha, rebase_needed:false}'
    return 0
  fi

  if out="$(git -C "$wt" rebase "origin/$default" 2>&1)"; then
    sha="$(git -C "$wt" rev-parse HEAD 2>/dev/null)" || die "cannot resolve HEAD after rebase in '$wt'"
    jq -cn --arg base "$base" --arg tip "$tip" --arg sha "$sha" \
      '{outcome:"REBASED", base:$base, tip:$tip, sha:$sha, rebase_needed:true}'
  else
    # Conflict (or any rebase failure): abort so the worktree is left clean and
    # the worker's commits are intact — NEVER leave a half-applied rebase, and
    # NEVER silently propose a revert. Escalate as a rebase conflict.
    git -C "$wt" rebase --abort >/dev/null 2>&1 || true
    jq -cn --arg base "$base" --arg tip "$tip" --arg error "$out" \
      '{outcome:"REBASE_CONFLICT", base:$base, tip:$tip, error:$error}'
    exit 1
  fi
}

# --- pr_survey: which open PR, if any, watches the ref we just pushed? ---------
# (temperloop#1688 — the observation cmd_push branches on; see its header.)
#
# Answers BOTH halves of the question in ONE `gh pr list` call, because the two
# are the same listing read two ways:
#   .match   — an open PR whose head ref IS <branch>. Its presence is the whole
#              benign case: whatever else is true, this push reached the PR.
#   .sibling — an open PR on a DIFFERENT head ref whose last path segment equals
#              <branch>'s. That is the `build/<slug>` vs `fix/<slug>` split
#              exactly: same slug, different type prefix, so it is the same work.
# A sibling with NO match is the only reportable state. "No match and no sibling"
# is the ORDINARY first push (build-level.mjs pushes at 3f-1 and opens the PR at
# 3f-2, so there is legitimately no PR yet) and must stay a plain PUSHED — which
# is also why this check needs no flag to stay off the normal path.
#
# READ-ONLY and FAIL-SOFT, same posture as recover-probe: a missing, erroring, or
# unparseable `gh` degrades to lookup:"unavailable" and the push still reports
# PUSHED. A push that already succeeded must never be turned into a failure by an
# inability to OBSERVE, only by a positive observation of the split.
pr_survey() {
  local wt="$1" branch="$2" out
  command -v gh >/dev/null 2>&1 || { printf '%s\n' '{"lookup":"unavailable"}'; return 0; }
  out="$(cd "$wt" && gh pr list --state open --json number,url,headRefName --limit 100 2>/dev/null || true)"
  if [ -z "$out" ] || ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"$out"; then
    printf '%s\n' '{"lookup":"unavailable"}'
    return 0
  fi
  jq -c --arg branch "$branch" '
    ($branch | split("/") | last) as $slug
    | { lookup: "ok",
        match: ((map(select(.headRefName == $branch)))[0] // null),
        sibling: ((map(select(.headRefName != $branch
                              and ((.headRefName | split("/") | last) == $slug))))[0] // null) }
  ' <<<"$out" 2>/dev/null || printf '%s\n' '{"lookup":"unavailable"}'
}

# Authoritative re-check of the exact-head miss, run ONLY when the survey above
# already found a sibling. `--limit 100` bounds the listing, so on a very busy
# repo a real match could fall outside the window and read as the split; `gh pr
# list --head` is server-side filtered and unbounded by that window. Two calls in
# the suspicious case, one in every ordinary one. Fail-soft the same way: if this
# confirm cannot run, we cannot positively observe the split, so we do not report
# it (prints the PR number when a match DOES exist, empty when confirmed absent,
# and `?` when indeterminate).
pr_head_confirm() {
  local wt="$1" branch="$2" out
  command -v gh >/dev/null 2>&1 || { printf '%s\n' '?'; return 0; }
  out="$(cd "$wt" && gh pr list --head "$branch" --state open --json number --limit 1 2>/dev/null || true)"
  if [ -z "$out" ] || ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"$out"; then
    printf '%s\n' '?'
    return 0
  fi
  jq -r '(.[0].number // "") | tostring' <<<"$out" 2>/dev/null || printf '%s\n' '?'
}

# content_superseded <worktree> <remote-sha> — the CONTENT-CONTAINMENT oracle
# (temperloop#2095). Echoes `yes`, `no` or `unknown`; never fails its caller.
#
# WHY A SECOND ORACLE EXISTS AT ALL. The patch-equivalence probe below
# (`rev-list --cherry-pick`) decides "is this remote commit already in our
# history?" by PATCH-ID, and `git patch-id` hashes the diff BODY — context lines
# included. A rebase onto a newer origin/<default> rewrites those context lines
# whenever the advance touched anything within three lines of the item's own
# hunk, so the rebased commit gets a DIFFERENT patch-id from the pre-rebase
# commit the engine itself pushed one round earlier. `--cherry-pick` then counts
# the engine's own work as unique remote work and the rewrite is refused. The
# engine rebases on EVERY continuation round (§3e.5's pre-gate freshness step),
# so this misfires on the COMMON path, not a rare one: the live sighting was
# /fix 1650 round 2, where the "remote-only" commit's rebased equivalent changed
# the same four files with the same +377/-1 and not one changed line differed.
#
# THE ORACLE. Patch-id asks about COMMITS; the question the gate actually needs
# answered is about CONTENT: does HEAD already contain everything the remote tip
# has? Merge the remote tip into HEAD in memory and compare trees. If the merge
# adds nothing — the resulting tree IS HEAD's tree — then the remote holds no
# content HEAD lacks, and rewriting the ref destroys nothing. That is invariant
# under rebase, because a replayed commit's CONTENT is unchanged even when its
# patch-id is not. `merge-tree --write-tree` does this with no index, no
# checkout and no worktree mutation.
#
# WHAT IT STILL REFUSES, deliberately — the narrowing cmd_push's own comment
# documents is preserved, not traded away:
#   * a genuine DROP (round 2 rebases without a commit round 1 pushed): the
#     merge re-introduces that commit's content, so the tree DIFFERS ⇒ `no`.
#   * an unrelated branch-name collision: the merge brings in the foreign work,
#     so the tree DIFFERS ⇒ `no`.
#   * a merge that CONFLICTS (rc 1): the remote carries content that cannot even
#     be reconciled with HEAD, which is the opposite of superseded ⇒ `no`.
# Only a clean merge that changes nothing answers `yes`.
#
# `unknown` is reserved for a probe that could not RUN — a git too old for
# `merge-tree --write-tree` (<2.38), unrelated histories with no merge base, an
# unreadable tree. It is never an assertion either way; the caller keeps the
# patch-equivalence verdict in that case, which is exactly the pre-#2095
# behaviour, so an old git degrades to today's conservatism rather than to a
# force it could not justify.
content_superseded() {
  local wt="$1" remote="$2" ours merged rc=0
  ours="$(git -C "$wt" rev-parse 'HEAD^{tree}' 2>/dev/null || true)"
  case "$ours" in ''|*[!0-9a-f]*) printf '%s\n' unknown; return 0 ;; esac
  merged="$(git -C "$wt" merge-tree --write-tree HEAD "$remote" 2>/dev/null)" || rc=$?
  if [ "$rc" -eq 1 ]; then
    printf '%s\n' no
    return 0
  fi
  if [ "$rc" -ne 0 ]; then
    printf '%s\n' unknown
    return 0
  fi
  merged="$(printf '%s\n' "$merged" | awk 'NR==1 {print $1}')"
  case "$merged" in ''|*[!0-9a-f]*) printf '%s\n' unknown; return 0 ;; esac
  if [ "$merged" = "$ours" ]; then printf '%s\n' yes; else printf '%s\n' no; fi
}

# --- push: 3f step 1 — push-by-SHA ---------------------------------------------
# Push the worktree's HEAD to the plan branch by SHA, honoring the plan's
# `branch:` name regardless of the worktree's throwaway build/<slug> local
# branch. A rewrite is *requested* by the rebase re-push (0.5), the CI-fix
# re-push (3g) and the 3f-1 push itself (`--allow-rewrite`), but is only
# actually *used* when the push is a genuine history rewrite — see the
# fast-forward downgrade below (#335). A rejection is a structured outcome —
# stale-branch-vs-collision triage is the orchestrator's call.
#
# temperloop#2103 — THE FORCE IS A LEASE, OVER A VALUE READ FIRST.
# The rewrite is issued as `--force-with-lease=refs/heads/<branch>:<sha>` where
# <sha> is the remote ref's value this function READ moments earlier, never a
# bare `--force`. A bare force discards whatever a concurrent writer put on the
# ref between the read and the push — the same class of loss this whole path
# exists to prevent — while the lease turns that race into a rejection. Reading
# the value is therefore not optional: when the remote ref cannot be read at all
# (fetch AND ls-remote both fail, or the ref is simply absent), NO force is
# issued. That is a deliberate narrowing of the pre-#2103 behaviour, which kept
# the requested force on an unreadable remote: an unleasable force is exactly
# the push we must not make, and a plain push that is rejected fails LOUDLY as
# PUSH_REJECTED, which is recoverable, whereas a blind overwrite is not.
#
# temperloop#2103 round 3 — AND THE LEASE IS NOT ENOUGH ON ITS OWN. A lease stops
# a writer who moves the ref BETWEEN the read and the push; it does nothing about
# content that was already on the ref when the read happened. Because 3f-1 now
# requests a rewrite on EVERY item's push rather than only on a rescue, a branch
# name colliding with unrelated work would otherwise be silently overwritten and
# reported as an ordinary PUSHED. So a requested rewrite is additionally gated on
# the same supersede check the escalation-time rescue push uses
# (build-level.mjs's preserveCommittedWorkCmd): every commit the remote tip has
# and HEAD does not must be patch-equivalent to one in HEAD. When it is not — or
# when that cannot be established — NO force is issued, the plain push is
# rejected LOUDLY, and `refused_reason` names which of the two it was. See the
# supersede gate inside cmd_push below for the full argument.
#
# `--allow-rewrite` is a spelling of the same request that carries no
# classifier-visible `--force` token in the command line the orchestrator
# executes (#437 — an unconditional literal `--force` trips the git-destructive
# safety classifier non-deterministically and silently parks an autonomous run).
# 3f-1 uses it on EVERY push because a continuation round's branch is routinely
# already on origin and the 3f-0a rebase has just rewritten it, so a plain push
# can never fast-forward (temperloop#2103's three live occurrences).
#
# #335 — prefer a plain fast-forward push over --force. A CI-retry commit is a
# fast-forward descendant of the already-pushed head (the CI-fix worker resets
# to the remote tip, then commits on top), so it needs no history rewrite; yet
# the requesting caller always passes --force. An unconditional --force on a
# feature branch trips the git-destructive safety classifier in auto mode
# non-deterministically, which silently parks/dead-ends an autonomous /sweep,
# /build --unattended, or pipeline-drive-merge run. So when --force is requested
# we DOWNGRADE to a plain push whenever we can positively prove the local head
# descends from the current remote tip (a pure fast-forward), and reserve the
# real --force for a genuine rewrite (local head does NOT descend the tip) or an
# indeterminate remote state (fetch failed) — never weakening main's safety.
# `forced` in the PUSHED payload records what was actually used.
#
# temperloop#1688 — WHICH REF DID THE PUSH LAND ON, AND IS ANY PR WATCHING IT?
# A push reports the ref it was HANDED, which is always truthful and can still be
# useless: `worktree.sh create` names the worktree's local branch `build/<slug>`
# while the PR is opened on the plan's `branch:` (`<type>/<slug>`, in practice
# `fix/<slug>`), so an operator or driver re-pushing a rebased worktree with the
# obvious-looking `pr.sh push <wt> build/<slug>` creates a SECOND remote ref that
# no PR references. `PUSHED` then says nothing false and nothing useful: the PR
# keeps serving its pre-rebase content, and the only downstream symptom is a PR
# head that looks "stale" — indistinguishable by eye from GitHub's well-known
# post-force-push head lag (the lag ci-poll.sh's own header documents). That
# collapse is what made the live 2026-08-21 sighting get MISdiagnosed as the lag.
# It came within one `--sha` pin of temperloop#254's false green: unpinned,
# ci-poll.sh would have resolved to the stale PR head, found ITS green checks, and
# reported CI_GREEN for content that was not what would merge.
#
# So the push asks the question it is uniquely placed to answer — it KNOWS the ref
# it just wrote — and reports the two-ref split as its OWN outcome rather than
# leaving it to be inferred from a symptom two steps downstream. The distinction
# that defeats the misdiagnosis is structural, not a wording choice:
#   * BRANCH-MISMATCH (this outcome): the open PR's head REF is a DIFFERENT ref
#     from the one pushed. The PR will never see this push, at any latency.
#   * GITHUB HEAD LAG (benign, never reported here): the open PR's head ref is the
#     SAME ref that was pushed; only its cached head SHA trails, and it converges.
# `stale_head_cause:"branch-mismatch"` plus both ref names is what lets a reader
# tell them apart, so the fix does not depend on the `--sha` pin also being right.
cmd_push() {
  local wt branch force="$1" sha out effective_force lease_arg lease_sha rc
  local survey lookup match_pr sibling_pr sibling_ref sibling_url confirm forced_json msg
  local unique refused_reason refusal contained supersede_basis
  wt="$(resolve_worktree "$2")"
  branch="$3"
  validate_branch "$branch"
  sha="$(git -C "$wt" rev-parse HEAD 2>/dev/null)" || die "cannot resolve HEAD in '$wt'"
  effective_force=""
  lease_arg=""
  lease_sha=""
  unique=""
  refused_reason=""
  supersede_basis=""
  if [ -n "$force" ]; then
    # READ the remote ref's current value first — the lease's expected value.
    # The fetch is preferred because it also brings the object local, which is
    # what makes the fast-forward test below answerable; ls-remote is the
    # fallback that still yields a value when a ref-specific fetch cannot run.
    if git -C "$wt" fetch --quiet origin "$branch" 2>/dev/null; then
      lease_sha="$(git -C "$wt" rev-parse FETCH_HEAD 2>/dev/null || true)"
    fi
    if [ -z "$lease_sha" ]; then
      # `|| true` is LOAD-BEARING, not decoration (see this file's header on the
      # temperloop#2009 pipefail trap): this is a plain assignment over a
      # pipeline, so under `set -euo pipefail` an unreachable or auth-failed
      # origin makes ls-remote fail, pipefail carries that status, and pr.sh
      # dies at this line — with 2>/dev/null swallowing the diagnostic, that is
      # a bare exit 128 and NO outcome line at all, on the one path whose whole
      # purpose is not losing work. Guarded, the failure falls through to the
      # empty-lease arm below, which issues no force and lets a plain push be
      # rejected LOUDLY as PUSH_REJECTED.
      lease_sha="$(git -C "$wt" ls-remote origin "refs/heads/$branch" 2>/dev/null | awk 'NR==1 {print $1}' || true)"
    fi
    case "$lease_sha" in ''|*[!0-9a-f]*) lease_sha="" ;; esac
    if [ -z "$lease_sha" ]; then
      # Ref absent from origin, or unreadable. Nothing to rewrite, and nothing
      # to lease against — a plain push creates it, or is rejected LOUDLY.
      :
    elif git -C "$wt" merge-base --is-ancestor "$lease_sha" HEAD 2>/dev/null; then
      # #335 — POSITIVE proof of a pure fast-forward: downgrade to a plain push.
      :
    else
      # temperloop#2103 round 3 — THE SUPERSEDE GATE. A genuine rewrite: the
      # remote tip is NOT an ancestor of HEAD, so landing HEAD on that ref
      # discards whatever is already there. A lease alone does not make that
      # safe, and that distinction is the whole finding: a lease only prevents a
      # writer moving the ref BETWEEN the read above and the push below. It says
      # nothing about content that was ALREADY sitting on the ref when the read
      # happened. Without this gate, 3f-1 — which requests a rewrite on EVERY
      # item's main-line push, not only on a rescue — would force over a leftover
      # manual branch, a reused slug or a planning bug and report an ordinary
      # PUSHED, which the driver takes as the happy path straight into opening a
      # PR. Nothing would surface that a rewrite had happened at all.
      #
      # So the test is the one preserveCommittedWorkCmd (build-level.mjs, the
      # escalation-time rescue push) already applies, applied here verbatim and
      # for the same reason: every commit reachable from the remote tip but not
      # from HEAD must have a patch-equivalent in HEAD (`rev-list --cherry-pick
      # --right-only`, git cherry's own test). Zero such commits ⇒ the remote
      # holds a superseded copy of exactly this work (the rebased-continuation
      # case this issue is about) ⇒ rewriting it destroys nothing. Otherwise the
      # remote carries commits this worktree does not, and NO force is issued.
      # The two force paths this change touches are now symmetric; the asymmetry
      # — the rescue path refusing what it could not prove superseded while the
      # far busier ordinary path did not — is what review round 2 caught.
      #
      # THE REFUSAL IS THE PLAIN PUSH, not a synthesized failure. Falling through
      # with no force leaves the same `git push` the pre-#2103 code issued, and a
      # non-fast-forward remote rejects it LOUDLY with git's own diagnostic —
      # exactly the PUSH_REJECTED a human triaged before this change. That
      # restores what build.md §3f step 1 promises rather than narrowing the
      # promise, which is the wrong direction for a work-loss fix.
      # `refused_reason` on that rejection is what tells it apart from the other
      # two no-force rejections (see the payload below), so a reader never has to
      # infer which of them happened.
      #
      # Two refusal reasons, never one (the round-1 lesson, held to here too):
      # `unique` empty means the probe could not be ANSWERED — the remote tip's
      # object is not local, because the ref-specific fetch above failed and only
      # `ls-remote` yielded a value — which is NOT the same claim as an
      # established conflict. `supersede_probe_failed` says exactly that rather
      # than asserting a conflict it never established. Both refuse identically;
      # only the claim made about why differs.
      #
      # `--no-merges` is the same DELIBERATE narrowing the rescue path documents:
      # an ordinary merge commit's underlying unique commits are still counted,
      # but an evil merge's own conflict-resolution edits are invisible to this
      # count. A /build worker branch does not normally carry merge commits, and
      # dropping the flag would count every merge's whole second parent as
      # remote-only work and refuse essentially every legitimate rewrite.
      #
      # ACKNOWLEDGED, ACCEPTED NARROWING in the other direction: a continuation
      # round that deliberately DROPS a commit an earlier round pushed no longer
      # rewrites unattended — it refuses and escalates for triage. That is the
      # conservative side of a work-loss fix on purpose: the refusal costs one
      # human decision and is fully recoverable; the overwrite it replaces is not.
      unique="$(git -C "$wt" rev-list --count --cherry-pick --right-only --no-merges "HEAD...$lease_sha" 2>/dev/null || true)"
      case "$unique" in ''|*[!0-9]*) unique="" ;; esac
      #
      # temperloop#2095 — AND THE SECOND ORACLE, because patch-id alone cannot
      # tell a genuine drop from a REBASE. `--cherry-pick` compares patch-ids,
      # and a rebase onto a newer origin/<default> shifts context lines, which
      # changes the patch-id of a commit it replayed intact. The engine rebases
      # on EVERY continuation round, so the pre-rebase commit the engine ITSELF
      # pushed last round is counted as unique remote work and this gate refuses
      # the push it exists to allow — on the common path, not the rare one.
      # So a non-zero count is no longer the last word: it hands off to
      # content_superseded() above, which answers the question the gate actually
      # needs — does HEAD already CONTAIN the remote tip's content? — by merging
      # the remote tip into HEAD in memory and asking whether the tree moved.
      # A genuine drop, an unrelated collision and a conflicting remote all still
      # answer `no` and still refuse; only a clean merge that changes nothing
      # opens the gate. `unknown` (a git too old for `merge-tree --write-tree`,
      # unrelated histories) keeps the patch-equivalence verdict, i.e. the
      # pre-#2095 refusal — an unanswerable second probe never widens the gate.
      if [ "$unique" = 0 ]; then
        effective_force=1
        lease_arg="--force-with-lease=refs/heads/$branch:$lease_sha"
        supersede_basis="patch-equivalence"
      elif [ -n "$unique" ]; then
        contained="$(content_superseded "$wt" "$lease_sha")"
        if [ "$contained" = yes ]; then
          effective_force=1
          lease_arg="--force-with-lease=refs/heads/$branch:$lease_sha"
          supersede_basis="content-containment"
        else
          refused_reason="remote_not_superseded"
        fi
      else
        refused_reason="supersede_probe_failed"
      fi
    fi
  fi
  rc=0
  if [ -n "$lease_arg" ]; then
    out="$(git -C "$wt" push "$lease_arg" origin "$sha:refs/heads/$branch" 2>&1)" || rc=$?
  else
    out="$(git -C "$wt" push origin "$sha:refs/heads/$branch" 2>&1)" || rc=$?
  fi
  if [ "$rc" -eq 0 ]; then
    forced_json="$([ -n "$effective_force" ] && echo true || echo false)"
    # temperloop#1688 — the push landed; now ask which PR, if any, watches the ref.
    survey="$(pr_survey "$wt" "$branch")"
    lookup="$(jq -r '.lookup // "unavailable"' <<<"$survey" 2>/dev/null || echo unavailable)"
    match_pr="$(jq -r '(.match.number // "") | tostring' <<<"$survey" 2>/dev/null || echo '')"
    sibling_pr="$(jq -r '(.sibling.number // "") | tostring' <<<"$survey" 2>/dev/null || echo '')"
    sibling_ref="$(jq -r '.sibling.headRefName // ""' <<<"$survey" 2>/dev/null || echo '')"
    sibling_url="$(jq -r '.sibling.url // ""' <<<"$survey" 2>/dev/null || echo '')"
    if [ "$lookup" = "ok" ] && [ -z "$match_pr" ] && [ -n "$sibling_pr" ]; then
      confirm="$(pr_head_confirm "$wt" "$branch")"
      if [ -z "$confirm" ]; then
        # Positively observed: nothing open watches refs/heads/<branch>, and the
        # sibling PR on a different ref is the work this push belongs to.
        msg="pushed refs/heads/${branch}, but NO open PR references that ref."
        msg="${msg} Open PR #${sibling_pr} tracks refs/heads/${sibling_ref} instead, so it will not see this push"
        msg="${msg} — its head stays at its pre-push content."
        msg="${msg} This is a BRANCH-NAME mismatch (two different refs), NOT GitHub's post-force-push head lag:"
        msg="${msg} that lag shows the SAME ref with a trailing head sha and converges on its own, this never will."
        msg="${msg} Re-push onto the PR's own ref: pr.sh push <worktree> ${sibling_ref} --allow-rewrite"
        jq -cn --arg sha "$sha" --arg branch "$branch" --argjson forced "$forced_json" \
           --arg pr "$sibling_pr" --arg ref "$sibling_ref" --arg url "$sibling_url" --arg msg "$msg" \
          '{outcome:"PUSHED_UNWATCHED", sha:$sha, branch:$branch, forced:$forced,
            pr_lookup:"ok", pr_number:($pr|tonumber), pr_head_ref:$ref, pr_url:$url,
            stale_head_cause:"branch-mismatch", error:$msg}'
        exit 1
      fi
      # `?` (indeterminate) or a late-found match: no positive observation of the
      # split, so fall through to PUSHED rather than manufacture a failure.
      case "$confirm" in ''|*[!0-9]*) match_pr="" ;; *) match_pr="$confirm" ;; esac
    fi
    # `lease` records the remote value the force was leased against, so the
    # rewrite is auditable after the fact (temperloop#2103); null on every
    # non-forced push, where nothing was leased.
    # `supersede_basis` (temperloop#2095) names WHICH oracle let the rewrite
    # through — `patch-equivalence` (the remote's commits are patch-identical to
    # ours) or `content-containment` (they are not, but merging the remote tip
    # into HEAD moves no tree, the rebased-continuation case). Null on every
    # non-forced push, where no supersede question was asked.
    jq -cn --arg sha "$sha" --arg branch "$branch" --argjson forced "$forced_json" \
       --arg lookup "$lookup" --arg pr "$match_pr" --arg lease "$lease_sha" \
       --arg basis "$supersede_basis" \
      '{outcome:"PUSHED", sha:$sha, branch:$branch, forced:$forced,
        lease:(if $forced then $lease else null end),
        supersede_basis:(if $forced and $basis != "" then $basis else null end),
        pr_lookup:$lookup, pr_number:(if $pr == "" then null else ($pr|tonumber) end)}'
  else
    # `forced`/`lease`/`refused_reason` on the rejection too, so a reader can
    # tell the FOUR rejections apart without re-deriving them: a plain push that
    # could not fast-forward (forced=false, lease=null, refused_reason=null — no
    # rewrite was requested), a rewrite whose lease went stale under a concurrent
    # writer (forced=true with a lease), a requested rewrite whose remote value
    # could not be read at all (forced=false, lease=null, refused_reason=null,
    # but the error names a non-fast-forward), and — temperloop#2103 round 3 — a
    # requested rewrite this function REFUSED to issue because the remote tip is
    # not superseded by local history, or because that question could not be
    # answered (forced=false, refused_reason set, `remote_tip` naming the sha it
    # refused over and `remote_only_commits` the established count).
    #
    # The refusal is stated in `error` FIRST, ahead of git's own non-fast-forward
    # text, because `error` is what §3f step 1 renders verbatim to the human who
    # triages this: the raw git message alone would read as the ordinary stale
    # branch it is not, and the decision the operator has to make (rename the
    # branch, or confirm the remote work really is superseded) turns entirely on
    # which of the two this is.
    if [ -n "$refused_reason" ]; then
      if [ "$refused_reason" = "remote_not_superseded" ]; then
        refusal="REFUSED to rewrite refs/heads/${branch}: origin's tip ${lease_sha} carries ${unique} commit(s)"
        refusal="${refusal} this worktree's history does not, so the local history does NOT supersede it."
        refusal="${refusal} This is a genuine content collision — a leftover branch, a reused slug or a planning bug —"
        refusal="${refusal} NOT the stale pre-rebase copy of this same work that --allow-rewrite exists to land."
        # Say which of the two oracles carried the refusal (temperloop#2095), so
        # a reader is never told a containment claim that was never established.
        if [ "$contained" = no ]; then
          refusal="${refusal} BOTH oracles agree: the commits are not patch-equivalent, AND merging origin's tip into"
          refusal="${refusal} this worktree's HEAD would change the tree — so origin carries content HEAD does not,"
          refusal="${refusal} which a rebase alone can never produce."
        else
          refusal="${refusal} The content-containment cross-check could not RUN here (an unsupported git, or no common"
          refusal="${refusal} history), so this rests on patch-equivalence alone — which a rebase can invalidate."
        fi
      else
        refusal="REFUSED to rewrite refs/heads/${branch}: could not establish whether this worktree's history"
        refusal="${refusal} supersedes origin's tip ${lease_sha} (its object is not available locally, so the"
        refusal="${refusal} patch-equivalence probe could not run). No conflict is asserted — the question is UNANSWERED."
      fi
      refusal="${refusal} No force was issued and origin is exactly where it was."
      refusal="${refusal} Triage by hand: inspect origin/${branch}; if it is unrelated work, pick a new branch name"
      refusal="${refusal} (patch the plan's branch:); if it is genuinely superseded, confirm that and re-push."
      out="${refusal}"$'\n\n'"${out}"
    fi
    jq -cn --arg sha "$sha" --arg branch "$branch" --arg error "$out" \
       --argjson forced "$([ -n "$effective_force" ] && echo true || echo false)" \
       --arg lease "$lease_sha" --arg refused "$refused_reason" --arg unique "$unique" \
      '{outcome:"PUSH_REJECTED", sha:$sha, branch:$branch, forced:$forced,
        lease:(if $forced then $lease else null end),
        refused_reason:(if $refused == "" then null else $refused end),
        remote_tip:(if $refused == "" then null else $lease end),
        remote_only_commits:(if $unique == "" then null else ($unique|tonumber) end),
        error:$error}'
    exit 1
  fi
}

# --- recover-probe: 3c lost-return side-effect probe (temperloop#939) ----------
# When the 3c worker completes WITHOUT returning a verdict (the subagent never
# called StructuredOutput, or blew the StructuredOutput retry cap), the return
# CHANNEL failed — which says nothing about whether the WORK failed. In the #939
# incident the worker had committed, pushed, opened PR #936 and gone green, yet
# the level reported `worker-error`; a second worker in the same run had
# committed but not pushed. So the side-effect state at death is NOT uniform and
# a single boolean ("did it get far enough?") mis-handles one of the two shapes.
#
# This is the STAGED probe build-level.mjs runs before it classifies that death.
# It reads only observable ground truth — never the worker's word — and reports
# the furthest stage the work actually reached:
#   1. commits ahead of origin/<default> in the worktree? → work exists at all
#   2. the branch present on origin (`git ls-remote`)?    → it was pushed
#   3. an OPEN PR for that branch (`gh pr list`)?         → the PR exists
# RECOVER_NONE (stage 0, and no open PR) is the genuine-failure case the caller
# still escalates unchanged. Anything else is recoverable: the caller
# reconstructs the parked record from these fields instead of escalating, and
# resumes the machinery at the right stage rather than re-spawning the worker.
#
# RECOVER_DIRTY (temperloop#993) splits stage 0 in two. A worker that backgrounds
# the quality gate and yields is reaped mid-flight: it has REAL WORK ON DISK and
# ZERO commits (observed twice in one run — #982 with 8 modified files, #983 with
# 3), which is a materially different state from a worker that died having touched
# nothing. Both were RECOVER_NONE before, so the caller could not tell "resume the
# same worktree, the work is still there" from "nothing happened". `dirty` /
# `dirty_files` (a `git status --porcelain` line count, tracked edits AND untracked
# files) are reported on EVERY outcome; the RECOVER_DIRTY outcome fires only where
# it changes the answer — nothing committed, no PR, but the tree is dirty. It is
# NOT a "landed" stage: nothing is committed, so there is nothing to push or open a
# PR from — the caller's recovery ladder must keep treating it as not-landed and
# resume the WORKER (build-level.mjs's foreground-cure re-spawn), never
# reconstruct a parked record from it.
#
# `verification_surface_present` reports whether the worker got as far as writing
# `.build-verification.md`, so the caller knows whether it may pass
# --verification-surface-file to `open` (a given-but-missing surface file is a
# hard ERROR by contract) or must fall back to a synthesized surface.
#
# Read-only and FAIL-SOFT by construction: it fetches nothing and writes nothing,
# and a missing/erroring `gh` degrades to "no PR observed" (a caller that then
# re-runs `open` gets EXISTS and adopts the PR anyway) rather than failing the
# whole recovery. Only an unusable worktree/branch argument is a structured ERROR.
cmd_recover_probe() {
  local wt branch default ahead sha remote_sha pr_number url outcome surface out
  local dirty_files dirty
  wt="$(resolve_worktree "$1")"
  branch="$2"
  validate_branch "$branch"
  default="$(default_branch "$wt")" || die "cannot resolve origin's default branch in '$wt'"
  sha="$(git -C "$wt" rev-parse HEAD 2>/dev/null)" || die "cannot resolve HEAD in '$wt'"
  # No fetch: the worktree was created from the local origin/<default> ref, and a
  # probe must never mutate refs or depend on the network to answer.
  ahead="$(git -C "$wt" rev-list --count "origin/$default..HEAD" 2>/dev/null || echo 0)"
  case "$ahead" in ''|*[!0-9]*) ahead=0 ;; esac

  remote_sha=""
  out="$(git -C "$wt" ls-remote --heads origin "$branch" 2>/dev/null || true)"
  if [ -n "$out" ]; then
    remote_sha="$(printf '%s\n' "$out" | head -1 | awk '{print $1}')"
  fi

  pr_number=""; url=""
  if command -v gh >/dev/null 2>&1; then
    out="$(cd "$wt" && gh pr list --head "$branch" --state open --json number,url --limit 1 2>/dev/null || true)"
    if [ -n "$out" ] && jq -e . >/dev/null 2>&1 <<<"$out"; then
      pr_number="$(jq -r '(.[0].number // "") | tostring | select(. != "null")' <<<"$out" 2>/dev/null || true)"
      url="$(jq -r '.[0].url // ""' <<<"$out" 2>/dev/null || true)"
    fi
  fi
  case "$pr_number" in ''|*[!0-9]*) pr_number="" ;; esac

  surface=false
  if [ -f "$wt/.build-verification.md" ]; then surface=true; fi

  # Uncommitted work on disk (tracked edits + untracked files). Reported on every
  # outcome; only stage 0 branches on it (temperloop#993). `.build-guard` is
  # EXCLUDED by pathspec: worktree.sh's `create` drops that marker itself, so it
  # is orchestrator machinery, never worker work — counting it would make every
  # freshly-created worktree read dirty and collapse RECOVER_NONE into
  # RECOVER_DIRTY wherever a consuming repo has not gitignored it (this repo has;
  # the exclusion is what makes the rung correct where it hasn't).
  dirty_files="$(git -C "$wt" status --porcelain -- ':(exclude).build-guard' 2>/dev/null | wc -l | tr -d ' ')"
  case "$dirty_files" in ''|*[!0-9]*) dirty_files=0 ;; esac
  dirty=false
  if [ "$dirty_files" -gt 0 ]; then dirty=true; fi

  if [ -n "$pr_number" ]; then
    outcome="RECOVER_PR_OPEN"
  elif [ "$ahead" -eq 0 ] && [ "$dirty_files" -gt 0 ]; then
    # Nothing committed, no PR — but the worker left real work on disk. The
    # #993 backgrounded-gate stall: resume the worker on THIS worktree.
    outcome="RECOVER_DIRTY"
  elif [ "$ahead" -eq 0 ]; then
    # Nothing committed and no PR — the worker died with no observable trace.
    outcome="RECOVER_NONE"
  elif [ -n "$remote_sha" ]; then
    outcome="RECOVER_PUSHED"
  else
    outcome="RECOVER_COMMITTED"
  fi

  jq -cn --arg outcome "$outcome" --arg sha "$sha" --arg branch "$branch" \
     --argjson ahead "$ahead" --arg remote_sha "$remote_sha" \
     --arg pr "$pr_number" --arg url "$url" --argjson surface "$surface" \
     --argjson dirty "$dirty" --argjson dirty_files "$dirty_files" \
     '{outcome:$outcome, sha:$sha, branch:$branch, commits_ahead:$ahead,
       pushed:($remote_sha != ""), remote_sha:$remote_sha,
       dirty:$dirty, dirty_files:$dirty_files,
       verification_surface_present:$surface}
      + (if $pr == "" then {} else {pr_number:($pr|tonumber), url:$url} end)'
}

# --- open: 3f step 2 — PR-body assembly + gh pr create -------------------------

# Resolve the ## Verification surface body by precedence (the #418 inflow-cut),
# so the large block need never round-trip through the orchestrator's context:
#   1. --verification-surface-file <path>      (explicit; the orchestrator
#      passes the deterministic worktree path)      → read the file
#   2. verdict's `.verification_surface_path`       (the worker wrote a file in
#      its worktree and returned only the path)      → read the file
#   3. verdict's inline `.verification_surface`      (back-compat)
#   4. empty → the caller falls back to the acceptance recap
# A path that is given but unreadable is a contract violation → die (a structured
# ERROR the orchestrator branches on, rather than silently degrading to recap).
resolve_surface() {
  local surface_file="$1" verdict="$2" spath
  if [ -n "$surface_file" ]; then
    [ -f "$surface_file" ] || die "--verification-surface-file '$surface_file' does not exist"
    cat "$surface_file"
    return 0
  fi
  spath="$(jq -r '.verification_surface_path // ""' <<<"$verdict")"
  if [ -n "$spath" ]; then
    [ -f "$spath" ] || die "verdict .verification_surface_path '$spath' does not exist"
    cat "$spath"
    return 0
  fi
  jq -r '.verification_surface // ""' <<<"$verdict"
}

# Strip the worker's own duplicate linkage from the resolved verification
# surface (temperloop#1023). Issue linkage lives in ONE place — the bare
# `Closes` block assemble_body emits from --gh-issue/--also-closes. The
# `## Verification` section, by contrast, is WORKER-AUTHORED content spliced in
# verbatim, so a worker that copied that block into its own
# `.build-verification.md` made the assembled body carry it twice (observed on
# temperloop PR #1019). GitHub dedupes closing keywords, so linkage still
# resolved — the cost is reviewer-facing: the body reads as though linkage were
# declared twice, contradicting the single-home invariant this script's header
# states. Stripping here rather than asking every worker to remember a prose
# rule keeps the invariant machine-enforced, like the `scan` pre-push check.
#
# What is removed is deliberately NARROW — only a line GitHub itself would
# honor AND that can only be a duplicate of this script's own emission: a WHOLE
# line that is nothing but `<keyword> #N` or `<keyword> owner/repo#N`. Kept:
#   - a mid-sentence mention ("…emits `Closes #976` near the top of the body")
#   - a backticked / inline-code line — GitHub ignores those, so they were never
#     a duplicate (the same lexical model lint-pr-body.sh uses)
#   - an indented line (a 4-space code block — likewise ignored by GitHub)
#   - ANY line inside a ``` / ~~~ fenced code block, so a surface that quotes an
#     assembled PR body as its evidence keeps that evidence intact
# Blank lines left behind by a removal are NOT collapsed: Markdown renders a run
# of blank lines identically, and any rewrite beyond deleting the offending line
# would risk mutating worker evidence for a cosmetic gain.
#
#   mode=count → print how many lines WOULD be stripped (0 for a clean surface)
#   mode=strip → print the surface with those lines removed
# cmd_open counts first and only re-runs in strip mode when the count is
# non-zero, so a surface carrying no such line is passed through byte-for-byte
# by construction rather than by inspection.
strip_surface_closes() {
  awk -v mode="$1" '
    function is_closes_line(l,   t) {
      t = tolower(l)
      if (t ~ /^(closes|closed|close|fixes|fixed|fix|resolves|resolved|resolve)[[:blank:]]*:?[[:blank:]]*#[0-9]+[[:blank:]]*$/) return 1
      if (t ~ /^(closes|closed|close|fixes|fixed|fix|resolves|resolved|resolve)[[:blank:]]*:?[[:blank:]]*[a-z0-9_.-]+\/[a-z0-9_.-]+#[0-9]+[[:blank:]]*$/) return 1
      return 0
    }
    BEGIN { fence = ""; n = 0 }
    {
      if (fence != "") {
        if (substr($0, 1, 3) == fence) fence = ""
        if (mode == "strip") print
        next
      }
      if (substr($0, 1, 3) == "```" || substr($0, 1, 3) == "~~~") {
        fence = substr($0, 1, 3)
        if (mode == "strip") print
        next
      }
      if (is_closes_line($0)) { n++; next }
      if (mode == "strip") print
    }
    END { if (mode == "count") print n + 0 }
  '
}

# Assemble the PR body per the 3f contract, from the verdict JSON + plan
# fields. Section order: summary; bare Closes lines (one per entry, own line,
# no backticks — combining or code-spanning them breaks GitHub's auto-close);
# acceptance recap; ## Verification (the resolved surface, see resolve_surface,
# falling back to the recap ONLY if no surface was produced); backlinks;
# Claude Code footer.
#
# $7 (optional) overrides the verdict's `.summary` — the seam bound_body uses
# to re-assemble with reviewer prose truncated, so the bounding never has to
# re-parse an already-assembled body to find its section edges.
assemble_body() {
  local verdict="$1" gh_issue="$2" also_closes="$3" plan_link="$4" source_ref="$5" surface="$6" \
        summary_override="${7-}"
  local summary recap body n
  summary="$(jq -er '.summary' <<<"$verdict" 2>/dev/null)" \
    || die "verdict JSON missing .summary"
  [ -n "$summary_override" ] && summary="$summary_override"
  # temperloop#1319: `.discrimination_evidence` (worker-reported proof that an
  # acceptance check can actually FAIL — which mechanism it removed, that the
  # suite went red without it, that restoring it went green) is a FOURTH field
  # the worker may return alongside `.criterion`/`.passed`/`.evidence`. This jq
  # is the load-bearing consumer: reading only the original three would
  # silently DROP that evidence from the PR body a human actually reviews —
  # exactly the failure this item exists to close (see presentation-plane.md's
  # WORKER_VERDICT_SCHEMA row). Rendered on its own line under the bullet so a
  # long discrimination narrative doesn't crowd the pointer-shaped `evidence`.
  # temperloop#1182: `.deferred_host_config` is a FIFTH field — the deferral
  # marker for a criterion that turns on a gitignored host-local file a
  # worktree structurally never contains. Read here for exactly the reason
  # above: without it, a human reviewing this PR cannot tell an unchecked box
  # meaning "the worker failed this" from one meaning "nobody could check this
  # from a worktree — the orchestrator verified it in the real checkout". The
  # two render identically otherwise, which is the whole failure.
  # temperloop#1267: `.evidence` rides its OWN nested line (`\n      — …`),
  # never appended inline after a bare ` — ` delimiter. ` — ` occurs inside
  # real criteria AND inside real evidence, so an inline delimiter made the
  # recap unparseable: a first-occurrence split truncates the criterion, a
  # last-occurrence split breaks whenever the evidence carries its own
  # em-dash, and no rule decides between them. On its own line the split is
  # POSITIONAL — `acceptance-extract` below recovers both fields byte-exactly
  # with no heuristic. GitHub renders the indented continuation as part of the
  # same list paragraph, so the human reading looks unchanged.
  recap="$(jq -r '(.acceptance_results // [])[]
            | "- [" + (if .passed then "x" else " " end) + "] "
              + .criterion
              + ((.evidence // "") | if . == "" then "" else "\n      — " + . end)
              + ((.deferred_host_config // "") | if . == "" then "" else "\n      DEFERRED — host-config `" + . + "` is invisible from a worktree; verified parent-side (temperloop#1182)" end)
              + ((.discrimination_evidence // "") | if . == "" then "" else "\n      discrimination: " + . end)' \
          <<<"$verdict")" || die "verdict JSON has malformed .acceptance_results"
  # surface is resolved by the caller (cmd_open → resolve_surface) so a missing
  # surface file dies at the top level, not inside this nested command sub.

  body="$summary"$'\n'
  if [ -n "$gh_issue" ] || [ -n "$also_closes" ]; then
    body="$body"$'\n'
    [ -n "$gh_issue" ] && body="${body}$(closes_line "$gh_issue")"$'\n'
    for n in $also_closes; do
      body="${body}$(closes_line "$n")"$'\n'
    done
  fi
  if [ -n "$recap" ]; then
    body="$body"$'\n''## Acceptance'$'\n'"$recap"$'\n'
  fi
  body="$body"$'\n''## Verification'$'\n'
  if [ -n "$surface" ]; then
    body="$body$surface"$'\n'
  else
    # Fallback only when the worker produced no verification_surface — the
    # bare recap alone does not satisfy the PR-verification-surface rule, so
    # the orchestrator should treat this as degraded, not normal.
    body="$body$recap"$'\n'
  fi
  if [ -n "$plan_link" ] || [ -n "$source_ref" ]; then
    body="$body"$'\n'
    [ -n "$plan_link" ] && body="${body}Tracked in: [[${plan_link}]]"$'\n'
    [ -n "$source_ref" ] && body="${body}Derived from: ${source_ref}"$'\n'
  fi
  body="$body"$'\n''🤖 Generated with [Claude Code](https://claude.com/claude-code)'
  printf '%s\n' "$body"
}

# --- the PR-body cap (temperloop#2009) ----------------------------------------
#
# GitHub rejects a PR body over 65536 characters — `GraphQL: Body is too long`.
# That rejection lands on `gh pr create`/`gh pr edit`, i.e. at the very LAST
# step of 3f, after the worker, every routed reviewer, the acceptance gate, the
# activation gate and the push have all already succeeded: the branch is safe
# but the result cannot be published, and an unattended run simply parks. Two
# live items failed exactly that way in one day (temperloop#1958, #1970), both
# recovered by hand. So the body is bounded HERE, locally, before it is ever
# handed to gh — an over-cap body is truncated, never sent and rejected.
#
# $BUILD_PR_BODY_MAX_BYTES is the bound, in BYTES. Bytes rather than characters
# is deliberate and conservative in the safe direction: a UTF-8 byte count is
# always >= the character count GitHub actually meters, so a body inside the
# byte cap is inside the character limit too. The default sits below 65536 with
# headroom for the linkage + attribution tail the ladder never touches.
#
# WHAT GETS CUT, IN ORDER. The ladder is deliberately prose-first, because the
# body is where un-actioned review findings are MEANT to be read: temperloop#1970
# carries residual blocking findings into `## Review notes` instead of looping
# another review round, so gutting that section first would hollow out the very
# feature that raised the body pressure. Rungs, each re-measured before the next:
#   1. the EARLIEST review ROUNDS of verbatim reviewer prose, oldest round first
#      (the reviewBodySuffix render orders rounds[0] first, ci-fix rounds after),
#      one more round at a time — never the newest ROUND, which is where every
#      residual HIGH from the final round lives. The unit is a round, not a
#      reviewer block: a round that routed three reviewers renders three blocks,
#      and dropping them one at a time would strip two of the final round's
#      reviewers while the ladder still reported the round as protected;
#   2. the newest round's own prose tail — every `### ` heading in that round
#      (each reviewer's name AND each `### [HIGH] …` finding title) is kept;
#   3. the MIDDLE of the `## Verification` surface, head AND tail kept;
#   4. a structural floor — reached only if the linkage block, acceptance recap,
#      backlinks and footer alone exceed the cap — which cuts the assembled body
#      and re-appends the linkage lines and footer verbatim; if even that cannot
#      converge it hard-cuts byte-exactly at a safe UTF-8 boundary (hard_bytes)
#      and says so on stderr, and refuses with the script's own structured ERROR
#      if no such boundary exists. So an over-cap, SIGPIPE-killed or invalid-UTF-8
#      body is never emitted by ANY path.
# NEVER cut, at any rung: the `Closes #N` linkage lines, the `## Acceptance`
# recap (where a worker's activation-proof evidence rides), the `§3e review —
# ran:` line, the `## Verification` heading, the backlinks, or the footer.
#
# Every cut is LEGIBLE. A silent truncation would be a worse failure than the
# API rejection it replaces, so each rung leaves an inline marker naming what
# it dropped, how many rounds/bytes, and where the full text can still be read
# — the workflow journal for reviewer prose, the worktree's own
# `.build-verification.md` for the surface.

# Byte length of a string (no trailing newline — what gh is actually handed).
body_bytes() { LC_ALL=C printf %s "$1" | wc -c | tr -d ' '; }

# Marker sentinel — every rung's inline marker starts with this, so a reader
# (and this script's tests) can find a truncation without parsing prose.
PR_BODY_TRUNC_MARK='_[PR-body cap]'

# Reviewer-prose surgery inside the summary's `## Review notes` section.
# Modes: `count` (how many review ROUNDS), `bytes-last` (byte size of the last
# round's cuttable prose, every structural line excluded), `drop` (remove the $2
# earliest ROUNDS, never the last, leaving a marker), `trim-last` (keep the last
# round's structural lines plus $3 bytes of its prose, leaving a marker).
#
# BLOCK EDGES COME FROM THE PRODUCER, NOT FROM MARKDOWN (temperloop#2009 review
# round 2). Each block opens with the delimiter build-level.mjs's
# reviewBlockMarker() emits — `<!-- 3e-review-block reviewer="…" round="N" -->`
# — matched here as a FULL token anchored at line start. Nothing else is a
# boundary, and no heading is consulted at all.
#
# That is the whole point, and it is the third shape this parse has taken. The
# first ended the section at the next `## ` line and lost it to the reviewers'
# own top-level `## Summary`. The second read a `### <token>` heading as a block
# head — and a reviewer writing a bare `### Notes`, or quoting one inside a
# fenced code block, minted a phantom round that let rung 1 drop the NEWEST
# round's residual HIGH findings (the ones temperloop#1970 routes into this very
# section for the human at the merge gate). build-level.mjs's own comment above
# `sections` says the structured render exists precisely so a CI-fix round can be
# relabeled "without regex surgery on reviewer text that may itself contain
# `### ` lines" — so reviewer text is not parsed here either. An explicit
# delimiter cannot be spoofed by prose: the producer neutralizes any occurrence
# of the token inside the text it splices (neutralizeReviewBlockMark), so a
# reviewer quoting this design writes `<!-- 3e-review-block-quoted …`, which is
# legible to a human and matches nothing here.
#
# Consequence worth stating: a `## Review notes` section rendered by anything
# OTHER than reviewBodySuffix carries no delimiters, so every prose rung sees
# zero rounds and no-ops. That is deliberate — the alternative is guessing, which
# is the defect. pr.sh and build-level.mjs ship together, and test_pr.sh holds a
# static guard that the two literals agree byte-for-byte.
#
# ROUNDS, NOT BLOCKS. One round renders ONE block PER ROUTED REVIEWER, so a
# three-reviewer round is three blocks. The unit of truncation is the round:
# blocks are grouped by the `round="N"` attribute their delimiter carries, and a
# rung drops or trims whole rounds. Counting blocks as rounds would let rung 1
# strip two of the FINAL round's three reviewers while still reporting the newest
# round as protected — and since temperloop#1970 carries residual blocking
# findings into this very section, those are precisely the findings that must
# survive.
review_notes() {
  LC_ALL=C awk -v mode="$1" -v drop="${2:-0}" -v keep="${3:-0}" \
      -v cap="$BUILD_PR_BODY_MAX_BYTES" -v journal="$SPEND_TRANSCRIPT_ROOT" \
      -v mark="$PR_BODY_TRUNC_MARK" '
    # The producer-emitted delimiter, whole and at line start. Keep this literal
    # in lockstep with reviewBlockMarker() in claude/workflows/build-level.mjs.
    function is_block_head(s) {
      return (s ~ /^<!-- 3e-review-block reviewer="[^"]*" round="[0-9]+" -->$/)
    }
    function round_key(s,   t) {
      t = s
      sub(/^.*round="/, "", t); sub(/".*$/, "", t)
      return t + 0          # string->number here is DECIMAL; a leading 0 is not octal
    }
    function block_reviewer(s,   t) {
      t = s
      sub(/^.*reviewer="/, "", t); sub(/".*$/, "", t)
      return t
    }
    # How the dropped round is NAMED in the inline marker — the same
    # `<reviewer>` / `<reviewer> (ci-fix round N)` label the human-facing
    # heading carries, rebuilt from the delimiter rather than read off prose.
    function block_name(s,   r) {
      r = round_key(s)
      return (r == 0) ? block_reviewer(s) : block_reviewer(s) " (ci-fix round " r ")"
    }
    # Structural lines a prose rung never cuts: the delimiter itself, and every
    # `### ` heading (each reviewer name AND each `### [HIGH] …` finding title).
    function is_structural(s) {
      return (is_block_head(s) || s ~ /^### /)
    }
    { lines[NR] = $0 }
    END {
      # No section anchor: a delimiter appears only where the producer put one,
      # so scanning the whole input is both correct and immune to a `## Review
      # notes` line appearing inside someone else s prose.
      end = NR + 1
      nb = 0
      for (i = 1; i < end; i++) {
        if (is_block_head(lines[i])) { nb++; bs[nb] = i; bkey[nb] = round_key(lines[i]) }
      }
      # Group consecutive blocks into rounds by their round key.
      ng = 0
      for (j = 1; j <= nb; j++) {
        if (ng == 0 || bkey[j] != gkey[ng]) { ng++; gkey[ng] = bkey[j]; gfirst[ng] = j }
        glast[ng] = j
      }
      for (g = 1; g <= ng; g++) {
        gfrom[g] = bs[gfirst[g]]
        gto[g] = (glast[g] < nb) ? bs[glast[g] + 1] - 1 : end - 1
      }
      if (mode == "count") { print ng; exit }
      if (mode == "bytes-last") {
        n = 0
        if (ng) for (i = gfrom[ng]; i <= gto[ng]; i++) if (!is_structural(lines[i])) n += length(lines[i]) + 1
        print n
        exit
      }
      if (ng == 0) { for (i = 1; i <= NR; i++) print lines[i]; exit }
      if (mode == "drop") {
        if (drop > ng - 1) drop = ng - 1
        if (drop < 1) { for (i = 1; i <= NR; i++) print lines[i]; exit }
        from = gfrom[1]; to = gto[drop]
        bytes = 0; names = ""
        for (i = from; i <= to; i++) bytes += length(lines[i]) + 1
        for (g = 1; g <= drop; g++) {
          for (j = gfirst[g]; j <= glast[g]; j++) {
            h = block_name(lines[bs[j]])
            names = names (names == "" ? "" : ", ") h
          }
        }
        for (i = 1; i < from; i++) print lines[i]
        printf "%s dropped the %d earliest §3e review round(s) of verbatim reviewer prose — %s — %d bytes, to fit the %d-byte PR-body cap ($BUILD_PR_BODY_MAX_BYTES). The findings are not suppressed: read them in full in the workflow journal (agent-*.jsonl under %s)._\n", mark, drop, names, bytes, cap, journal
        print ""
        for (i = to + 1; i <= NR; i++) print lines[i]
        exit
      }
      if (mode == "trim-last") {
        from = gfrom[ng]; to = gto[ng]
        for (i = 1; i < from; i++) print lines[i]
        acc = 0; cut = 0; cutlines = 0
        for (i = from; i <= to; i++) {
          # Every structural line in the newest round is kept: the block
          # delimiter, each reviewer name AND each `### [HIGH] …` finding
          # title stays legible, only prose goes.
          if (is_structural(lines[i])) { print lines[i]; continue }
          if (!cut && acc + length(lines[i]) + 1 <= keep) { acc += length(lines[i]) + 1; print lines[i]; continue }
          cut += length(lines[i]) + 1; cutlines++
        }
        if (cut > 0) {
          printf "%s truncated the newest §3e review round of verbatim reviewer prose here — %d line(s), %d bytes — to fit the %d-byte PR-body cap ($BUILD_PR_BODY_MAX_BYTES). Every reviewer name and finding heading in that round is kept above; the findings are not suppressed: read them in full in the workflow journal (agent-*.jsonl under %s)._\n", mark, cutlines, cut, cap, journal
        }
        for (i = to + 1; i <= NR; i++) print lines[i]
        exit
      }
      for (i = 1; i <= NR; i++) print lines[i]
    }
  '
}

# Elide the MIDDLE of a text block, keeping its head and its tail (a worker's
# activation proof or closing verdict is as often at the end as at the start),
# with a marker in the gap. $1 = total bytes to keep; $2 = what the text is;
# $3 = where the full text can still be read.
trim_middle() {
  LC_ALL=C awk -v keep="$1" -v what="$2" -v where="$3" \
      -v cap="$BUILD_PR_BODY_MAX_BYTES" -v mark="$PR_BODY_TRUNC_MARK" '
    { lines[NR] = $0; len[NR] = length($0) + 1; total += len[NR] }
    END {
      if (total <= keep) { for (i = 1; i <= NR; i++) print lines[i]; exit }
      headb = int(keep * 0.6); tailb = keep - headb
      h = 0; acc = 0
      for (i = 1; i <= NR; i++) { if (acc + len[i] > headb) break; acc += len[i]; h = i }
      t = NR + 1; acc = 0
      for (i = NR; i > h; i--) { if (acc + len[i] > tailb) break; acc += len[i]; t = i }
      dropped = 0; droplines = 0
      for (i = h + 1; i < t; i++) { dropped += len[i]; droplines++ }
      for (i = 1; i <= h; i++) print lines[i]
      print ""
      printf "%s elided %d line(s), %d bytes, from the middle of the %s to fit the %d-byte PR-body cap ($BUILD_PR_BODY_MAX_BYTES) — its head and tail are kept. Full text: %s._\n", mark, droplines, dropped, what, cap, where
      print ""
      for (i = t; i <= NR; i++) print lines[i]
    }
  '
}

# Keep the first $1 bytes of stdin, cutting at a line boundary. `LC_ALL=C` is
# load-bearing, exactly as in review_notes/trim_middle above: under gawk in a
# UTF-8 locale `length()` counts CHARACTERS, which would silently turn this
# byte budget into a character budget. macOS awk and Ubuntu mawk happen to count
# bytes, so the bare form agrees here and on CI by luck, not by contract.
head_bytes() {
  LC_ALL=C awk -v keep="$1" '{ n += length($0) + 1; if (n > keep) exit; print }'
}

# hard_bytes — the last-resort, BYTE-EXACT cut. Keeps at most $1 bytes of stdin
# and prints them; prints nothing and exits 1 if it cannot do so safely, so the
# caller refuses structurally rather than emitting something broken.
#
# Two properties it exists for, both learned the hard way (temperloop#2009
# review round 2):
#
#   1. It READS ALL OF STDIN. The previous form was
#      `printf %s "$body" | head -c "$cap"` — `head -c` exits the moment it has
#      its bytes, `printf` then takes SIGPIPE and exits 141, `pipefail`
#      propagates that, and `set -e` aborts pr.sh at the assignment. That is a
#      bare exit 141 with no `{"outcome":"ERROR",…}` line and no body at all, on
#      the ONE rung whose entire contract is "cannot fail" and which is reached
#      only on a pathological (i.e. large) body — strictly worse than the
#      over-cap send it replaces, because 3f gets something unparseable instead
#      of something diagnosable. Reproduced locally on a 300KB string.
#   2. It NEVER SPLITS A MULTI-BYTE SEQUENCE. A raw cut at byte N can land
#      inside a UTF-8 character and hand `gh` invalid UTF-8. So it backs off
#      from the budget to the last ASCII whitespace byte, and failing that to
#      the last ASCII printable byte: a truncation directly after an ASCII byte
#      is always a valid UTF-8 boundary. In the C locale a byte >= 0x80 is
#      neither `[[:print:]]` nor `[[:space:]]`, which is what makes the test
#      "is this byte ASCII?" — and `LC_ALL=C` therefore load-bearing here for a
#      second reason beyond `length()`.
hard_bytes() {
  LC_ALL=C awk -v keep="$1" '
    { all = all $0 "\n" }
    END {
      if (length(all) <= keep) { printf "%s", all; exit 0 }
      s = substr(all, 1, keep)
      for (k = length(s); k > 0; k--)
        if (substr(s, k, 1) ~ /^[[:space:]]$/) { printf "%s", substr(s, 1, k); exit 0 }
      for (k = length(s); k > 0; k--)
        if (substr(s, k, 1) ~ /^[[:print:]]$/) { printf "%s", substr(s, 1, k); exit 0 }
      exit 1
    }
  '
}

# bound_body — the ladder above. $1 is the already-assembled body (so the
# common under-cap path costs one measurement and returns it BYTE-IDENTICAL);
# $2..$7 are assemble_body's own arguments, re-used to re-assemble from
# truncated components rather than re-parsing the assembled text.
bound_body() {
  local body="$1" verdict="$2" gh_issue="$3" also_closes="$4" plan_link="$5" source_ref="$6" surface="$7"
  local cap="$BUILD_PR_BODY_MAX_BYTES" allow=700
  local size summary rounds drop cand last_bytes keep over n tail

  size="$(body_bytes "$body")"
  if [ "$size" -le "$cap" ]; then
    printf '%s\n' "$body"
    return 0
  fi

  summary="$(jq -r '.summary // ""' <<<"$verdict")"

  # Rung 1 — drop the earliest whole review ROUNDS of reviewer prose, oldest first.
  rounds="$(review_notes count <<<"$summary")"
  case "$rounds" in ''|*[!0-9]*) rounds=0 ;; esac
  drop=1
  while [ "$drop" -le $((rounds - 1)) ]; do
    cand="$(review_notes drop "$drop" <<<"$summary")"
    body="$(assemble_body "$verdict" "$gh_issue" "$also_closes" "$plan_link" "$source_ref" "$surface" "$cand")"
    size="$(body_bytes "$body")"
    if [ "$size" -le "$cap" ]; then
      printf '%s\n' "$body"
      return 0
    fi
    drop=$((drop + 1))
  done
  [ "$rounds" -gt 1 ] && summary="$(review_notes drop $((rounds - 1)) <<<"$summary")"

  # Rung 2 — trim the newest ROUND's prose tail, keeping every `### ` heading in
  # it (each reviewer's name and each `### [HIGH] …` finding title).
  if [ "$rounds" -gt 0 ]; then
    last_bytes="$(review_notes bytes-last <<<"$summary")"
    case "$last_bytes" in ''|*[!0-9]*) last_bytes=0 ;; esac
    over=$((size - cap))
    keep=$((last_bytes - over - allow))
    [ "$keep" -lt 0 ] && keep=0
    summary="$(review_notes trim-last 0 "$keep" <<<"$summary")"
    body="$(assemble_body "$verdict" "$gh_issue" "$also_closes" "$plan_link" "$source_ref" "$surface" "$summary")"
    size="$(body_bytes "$body")"
    if [ "$size" -le "$cap" ]; then
      printf '%s\n' "$body"
      return 0
    fi
  fi

  # Rung 3 — elide the middle of the verification surface. Never dropped: a
  # floor keeps its head and tail, so `## Verification` always carries content.
  if [ -n "$surface" ]; then
    over=$((size - cap))
    keep=$(( $(body_bytes "$surface") - over - allow ))
    [ "$keep" -lt 1200 ] && keep=1200
    surface="$(trim_middle "$keep" "verification surface" \
      "the worker's .build-verification.md in the item's worktree" <<<"$surface")"
    body="$(assemble_body "$verdict" "$gh_issue" "$also_closes" "$plan_link" "$source_ref" "$surface" "$summary")"
    size="$(body_bytes "$body")"
    if [ "$size" -le "$cap" ]; then
      printf '%s\n' "$body"
      return 0
    fi
  fi

  # Rung 4 — the structural floor. Reached only when the parts no rung above
  # touches (the linkage block, the acceptance recap, the backlinks, the
  # footer) exceed the cap on their own. Cut the assembled body and re-append
  # the linkage lines and footer verbatim, so auto-close and attribution
  # survive a cut that had nowhere else left to go.
  local footer='🤖 Generated with [Claude Code](https://claude.com/claude-code)'
  local line full hard resid attempt=0
  full="$body"
  tail=""
  for n in $gh_issue $also_closes; do
    tail="${tail}$(closes_line "$n")"$'\n'
  done
  # Reserve room for the marker plus the WHOLE linkage block and footer, then
  # re-append only what the cut actually removed — the body carries exactly one
  # linkage block (this script's own invariant), never a duplicate of lines the
  # head kept. The loop re-measures the REAL byte length and shrinks the cut
  # until it fits: every budget above is computed from awk's byte lengths, and
  # this is the one rung with nothing below it to catch a rounding error.
  keep=$(( cap - $(body_bytes "$tail") - $(body_bytes "$footer") - allow ))
  while :; do
    [ "$keep" -lt 1 ] && keep=1
    body="$(head_bytes "$keep" <<<"$full")"
    body="${body}"$'\n\n'"$PR_BODY_TRUNC_MARK cut here to fit the ${cap}-byte PR-body cap (\$BUILD_PR_BODY_MAX_BYTES) — the issue linkage and the attribution footer are re-appended below, so auto-close and attribution survive a cut that had nowhere else left to go. Full text: the workflow journal (agent-*.jsonl under $SPEND_TRANSCRIPT_ROOT)._"
    for n in $gh_issue $also_closes; do
      line="$(closes_line "$n")"
      grep -qxF -- "$line" <<<"$body" || body="${body}"$'\n'"$line"
    done
    grep -qxF -- "$footer" <<<"$body" || body="${body}"$'\n\n'"$footer"
    [ "$(body_bytes "$body")" -le "$cap" ] && break
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 12 ] || [ "$keep" -le 1 ]; then
      # Exhaustion. The shrink loop above is a LINE-boundary cut, so a single
      # line longer than the whole budget (or a linkage+footer tail that alone
      # exceeds the cap) can leave it stuck over the bound. Breaking here and
      # printing would hand `gh` an over-cap body — the exact API rejection this
      # whole ladder exists to prevent, now wearing a truncation marker. So the
      # last resort is a BYTE-EXACT cut that structurally cannot overshoot,
      # announced on stderr so the orchestrator's log carries a diagnosable
      # refusal rather than a silent mangling.
      resid="$(body_bytes "$body")"
      # shellcheck disable=SC2016  # $BUILD_PR_BODY_MAX_BYTES is the setting NAME, shown to a human, not expanded
      printf 'ERROR: PR-body cap ladder exhausted at rung 4 — %s bytes still over the %s-byte cap ($BUILD_PR_BODY_MAX_BYTES) after %s shrink attempts; hard-cutting to %s bytes. Full text: the workflow journal (agent-*.jsonl under %s).\n' \
        "$resid" "$cap" "$attempt" "$cap" "$SPEND_TRANSCRIPT_ROOT" >&2
      # One consumer, always: hard_bytes reads all of stdin (no SIGPIPE can
      # reach its producer under `set -o pipefail`) and cuts at the last ASCII
      # boundary inside the budget, so the result can neither overshoot the cap
      # nor split a multi-byte character. It refuses — empty, non-zero — only
      # when the budget holds no ASCII byte to cut after at all; there is
      # nothing safe left to emit then, so this dies with the script's own
      # structured ERROR on real stdout rather than handing `gh` a mangled body.
      hard="$(hard_bytes "$cap" <<<"$body")" || hard=""
      [ -n "$hard" ] || die "PR-body cap ladder exhausted at rung 4 and no safe byte boundary exists within the ${cap}-byte cap ($resid bytes); refusing to emit a truncated body"
      body="$hard"
      break
    fi
    keep=$(( keep * 3 / 4 ))
  done
  printf '%s\n' "$body"
}

# --- acceptance-extract: the INVERSE of assemble_body's ## Acceptance recap ----
#
# temperloop#1267. The PR body is the only durable verbatim record of the
# acceptance bullets a worker was handed (the item object is never persisted;
# the worktree and its .build-verification.md are deleted at terminal
# disposition; /sweep and /fix singletons produce no plan note). Every consumer
# that reads that record back — replay, a retro judge, a human auditing a merge
# — needs ONE owned extractor rather than a parse-by-eye per consumer, or the
# ambiguity this item closed re-enters through the reader instead of the writer.
#
# The grammar it inverts, one entry per `- [x] ` / `- [ ] ` bullet inside the
# FIRST `## Acceptance` section (a later `## ` heading ends it; a `## Acceptance`
# heading appearing inside a worker's own verification surface is therefore never
# re-entered):
#
#   - [x] <criterion, possibly spanning further un-prefixed lines>
#         — <evidence>
#         DEFERRED — host-config `<path>` is invisible from a worktree; …
#         discrimination: <discrimination_evidence>
#
# Each field ends at the next marker line, the next bullet, or a BLANK line, so
# an un-prefixed continuation line belongs to whichever field is open — that is
# what makes an embedded newline, and an embedded ` — `, survive intact. The
# split is POSITIONAL: no first-vs-last-delimiter guess anywhere. Two structural
# constraints the format asks of its inputs, both of which a bullet that renders
# as one Markdown list item already satisfies: no field's text contains a line
# beginning with one of the three marker prefixes above (six spaces + `— `,
# `DEFERRED — host-config \``, or `discrimination: `), and none contains a blank
# line (which would end the list item's paragraph in GitHub's renderer anyway —
# the recap's own trailing blank line before the next `## ` heading is exactly
# that terminator).
# shellcheck disable=SC2016  # $l / $ph are jq bindings — shell must NOT expand them
ACCEPTANCE_EXTRACT_JQ='
def flush: if .cur == null then . else .out += [.cur | del(.phase)] | .cur = null end;
split("\n")
| reduce .[] as $l (
    {sec: false, done: false, cur: null, out: []};
    if .done then .
    elif ($l == "## Acceptance") and (.sec | not) then .sec = true
    elif .sec and ($l | startswith("## ")) then flush | .sec = false | .done = true
    elif (.sec | not) then .
    elif ($l | test("^- \\[[x ]\\] ")) then
        flush
      | .cur = {passed: ($l[3:4] == "x"), criterion: $l[6:], evidence: null,
                deferred_host_config: null, discrimination_evidence: null,
                phase: "criterion"}
    elif .cur == null then .
    elif ($l == "") then .cur.phase = "closed"
    elif (.cur.phase == "closed") then .
    elif ($l | startswith("      — ")) and (.cur.phase == "criterion") then
        .cur.evidence = $l[8:] | .cur.phase = "evidence"
    elif ($l | startswith("      DEFERRED — host-config `")) then
        .cur.deferred_host_config =
          ($l | capture("^      DEFERRED — host-config `(?<p>.*)` is invisible from a worktree;") | .p)
      | .cur.phase = "deferred_host_config"
    elif ($l | startswith("      discrimination: ")) then
        .cur.discrimination_evidence = $l[22:] | .cur.phase = "discrimination_evidence"
    else
        (.cur.phase) as $ph | .cur[$ph] = (.cur[$ph] + "\n" + $l)
    end)
| flush
| .out
'

# acceptance-extract <bodyFile|-> — read an assembled PR body, print the
# recovered acceptance entries as one compact JSON array. Like `open
# --body-only`, this is an exception to the one-outcome-JSON-line contract: the
# array IS the payload, and an unreadable path is the usual structured ERROR.
cmd_acceptance_extract() {
  local src="$1" body
  if [ "$src" = "-" ]; then
    body="$(cat)"
  else
    [ -f "$src" ] || die "acceptance-extract: body file '$src' does not exist"
    body="$(cat "$src")"
  fi
  jq -Rsc "$ACCEPTANCE_EXTRACT_JQ" <<<"$body" \
    || die "acceptance-extract: could not parse the ## Acceptance recap"
}

cmd_open() {
  local verdict_src="" repo="" branch="" title="" gh_issue="" also_closes="" \
        plan_link="" source_ref="" surface_file="" surface="" body_only="" update_pr="" verdict body out url pr_number n raw
  local stripped=0 raw_len=0 truncated=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --verdict)     [ $# -ge 2 ] || usage; verdict_src="$2"; shift ;;
      --repo)        [ $# -ge 2 ] || usage; repo="$2"; shift ;;
      --branch)      [ $# -ge 2 ] || usage; branch="$2"; shift ;;
      --title)       [ $# -ge 2 ] || usage; title="$2"; shift ;;
      --gh-issue)    [ $# -ge 2 ] || usage; gh_issue="$2"; shift ;;
      --also-closes) [ $# -ge 2 ] || usage; also_closes="$2"; shift ;;
      --plan-link)   [ $# -ge 2 ] || usage; plan_link="$2"; shift ;;
      --source)      [ $# -ge 2 ] || usage; source_ref="$2"; shift ;;
      --verification-surface-file) [ $# -ge 2 ] || usage; surface_file="$2"; shift ;;
      --body-only)   body_only=1 ;;
      --update-pr)   [ $# -ge 2 ] || usage; update_pr="$2"; shift ;;
      *) usage ;;
    esac
    shift
  done

  [ -n "$verdict_src" ] || die "open requires --verdict <file|->"
  if [ "$verdict_src" = "-" ]; then
    verdict="$(cat)"
  else
    [ -f "$verdict_src" ] || die "verdict file '$verdict_src' does not exist"
    verdict="$(cat "$verdict_src")"
  fi
  jq -e . >/dev/null 2>&1 <<<"$verdict" || die "verdict is not valid JSON"

  [ -z "$gh_issue" ] || validate_issue "$gh_issue"
  # --also-closes accepts comma- or space-separated numbers; normalize to
  # space-separated so each emits its own bare `Closes #N` line.
  also_closes="$(printf '%s' "$also_closes" | tr ',' ' ')"
  for n in $also_closes; do validate_issue "$n"; done

  # Resolve the verification surface at the TOP level (not inside assemble_body's
  # nested command sub) so a missing surface file dies cleanly with a structured
  # ERROR. `|| exit 1` propagates resolve_surface's die (it already wrote the
  # ERROR to fd3) without emitting a second one.
  surface="$(resolve_surface "$surface_file" "$verdict")" || exit 1
  # temperloop#1023 — drop a linkage block the worker copied into its own
  # surface, so the assembled body carries exactly one (see strip_surface_closes).
  if [ -n "$surface" ]; then
    stripped="$(strip_surface_closes count <<<"$surface")"
    case "$stripped" in ''|*[!0-9]*) stripped=0 ;; esac
    if [ "$stripped" -gt 0 ]; then
      surface="$(strip_surface_closes strip <<<"$surface")"
    fi
  fi
  body="$(assemble_body "$verdict" "$gh_issue" "$also_closes" "$plan_link" "$source_ref" "$surface")"
  # temperloop#2009 — bound the body BEFORE it reaches gh. An over-cap body is
  # truncated here, legibly; it is never sent and rejected by the API after the
  # whole item has already succeeded. Applied at this ONE site, above every
  # arm below, so `--body-only`'s preview, `gh pr create` and `gh pr edit`
  # cannot disagree about what the outbound body is. Under the cap this is the
  # identity: the assembled body is returned byte-for-byte.
  raw_len="$(body_bytes "$body")"
  body="$(bound_body "$body" "$verdict" "$gh_issue" "$also_closes" "$plan_link" "$source_ref" "$surface")"
  truncated=$(( raw_len - $(body_bytes "$body") ))
  [ "$truncated" -lt 0 ] && truncated=0

  if [ -n "$body_only" ]; then
    printf '%s\n' "$body"
    return 0
  fi

  # --update-pr <n> (temperloop#1846): re-render an EXISTING PR's body through
  # this same assemble_body path — the .mjs's 3g.5 re-render after a CI-fix
  # re-review round adds reviewer evidence 3f's original body couldn't carry.
  # Deliberately a mode of `open`, not a sibling command: the body must be
  # byte-identical to what a fresh `open` would assemble (same verdict read,
  # linkage validation, surface resolve + closes strip), so the one shared
  # code path is the guarantee. --branch/--title are create-time-only.
  if [ -n "$update_pr" ]; then
    case "$update_pr" in
      ''|*[!0-9]*) die "open --update-pr requires a numeric PR number (got '$update_pr')" ;;
    esac
    [ -n "$repo" ] || die "open --update-pr requires --repo <repo-root>"
    repo="$(abs_dir "$repo")" || die "repo-root does not exist"
    if ! out="$(cd "$repo" && gh pr edit "$update_pr" --body "$body" 2>&1)"; then
      die "gh pr edit failed: $out"
    fi
    jq -cn --arg n "$update_pr" --argjson stripped "$stripped" --argjson trunc "$truncated" \
      '{outcome:"BODY_UPDATED", pr_number:($n|tonumber), surface_closes_stripped:$stripped,
        body_truncated_bytes:$trunc}'
    return 0
  fi

  [ -n "$repo" ]   || die "open requires --repo <repo-root> (unless --body-only)"
  [ -n "$branch" ] || die "open requires --branch (unless --body-only)"
  [ -n "$title" ]  || die "open requires --title (unless --body-only)"
  repo="$(abs_dir "$repo")" || die "repo-root does not exist"
  validate_branch "$branch"

  if ! out="$(cd "$repo" && gh pr create --head "$branch" --title "$title" --body "$body" 2>&1)"; then
    # gh pr create fails with "a pull request for branch ... already exists: <url>"
    # when the branch already has an open PR (e.g. a create retry after the first
    # create actually succeeded). Adopt the existing PR — parse its number and URL
    # from the error message and return a structured EXISTS outcome (success) so
    # the caller routes it to the normal CI-poll/park-with-pr path.
    if printf '%s\n' "$out" | grep -iE 'a pull request for branch .* already exists' >/dev/null; then
      url="$(grep -oE 'https?://[^[:space:]]+/pull/[0-9]+' <<<"$out" | tail -1 || true)"
      raw="$(grep -oE '/pull/[0-9]+' <<<"$out" | tail -1 || true)"
      pr_number="${raw#/pull/}"
      [ -n "$pr_number" ] || die "could not parse PR number from existing-PR error: $out"
      jq -cn --arg n "$pr_number" --arg url "$url" --argjson stripped "$stripped" --argjson trunc "$truncated" \
        '{outcome:"EXISTS", pr_number:($n|tonumber), url:$url, surface_closes_stripped:$stripped,
          body_truncated_bytes:$trunc}'
      return 0
    fi
    die "gh pr create failed: $out"
  fi
  # gh prints the new PR URL; take the last `/pull/<n>` reference in the output.
  raw="$(grep -oE '/pull/[0-9]+' <<<"$out" | tail -1 || true)"
  pr_number="${raw#/pull/}"
  [ -n "$pr_number" ] || die "could not parse PR number from gh output: $out"
  url="$(grep -oE 'https?://[^[:space:]]+/pull/[0-9]+' <<<"$out" | tail -1 || true)"
  jq -cn --arg n "$pr_number" --arg url "$url" --argjson stripped "$stripped" --argjson trunc "$truncated" \
    '{outcome:"PR_OPENED", pr_number:($n|tonumber), url:$url, surface_closes_stripped:$stripped,
      body_truncated_bytes:$trunc}'
}

[ $# -ge 1 ] || usage
cmd="$1"; shift
case "$cmd" in
  scan)
    [ $# -eq 1 ] || usage
    cmd_scan "$1"
    ;;
  base-check)
    [ $# -eq 1 ] || usage
    cmd_base_check "$1"
    ;;
  rebase)
    [ $# -eq 1 ] || usage
    cmd_rebase "$1"
    ;;
  push)
    [ $# -ge 2 ] || usage
    wt_arg="$1"; branch_arg="$2"; shift 2
    force=""
    while [ $# -gt 0 ]; do
      case "$1" in
        # Two spellings of ONE request: "rewrite the remote branch if the local
        # head is not a fast-forward of it". `--allow-rewrite` is the spelling
        # 3f-1 uses because it carries no classifier-visible `--force` token
        # (#437); `--force` stays for the existing 0.5/3g callers. Neither ever
        # produces a bare `git push --force` — see cmd_push (temperloop#2103).
        --force|--allow-rewrite) force=1 ;;
        *) usage ;;
      esac
      shift
    done
    cmd_push "$force" "$wt_arg" "$branch_arg"
    ;;
  recover-probe)
    [ $# -eq 2 ] || usage
    cmd_recover_probe "$1" "$2"
    ;;
  open)
    cmd_open "$@"
    ;;
  acceptance-extract)
    [ $# -eq 1 ] || usage
    cmd_acceptance_extract "$1"
    ;;
  *) usage ;;
esac
