#!/usr/bin/env bash
#
# Tests for workflows/scripts/build/pr.sh — the build push + PR-open
# mechanics CLI (epic #253, spike #245). Board-toolkit fixture style: a
# throwaway real-git bare upstream + clone in a tmpdir, a stubbed `gh` on
# PATH, zero network, structured-output assertions via jq.
#
# Covers:
#   - scan: clean commit messages → SCAN_CLEAN; a `Closes #153` commit (the
#     ec8d5fd class) → SCAN_BLOCKED + offending line + non-zero exit
#   - base-check: BASE_CURRENT on a current base; BASE_STALE once upstream advances
#   - rebase (temperloop#735): the dirty-vs-conflict split — a genuine content
#     clash is REBASE_CONFLICT, an uncommitted tracked-file edit is DIRTY_WORKTREE
#     (edit preserved, HEAD unmoved, `rebase_needed` telling base==tip from a real
#     stale base), untracked files are not dirt, and the SAME conflicting fixture
#     flips between the two outcomes purely on whether the tree is clean
#   - push: push-by-SHA places the branch on a local bare remote → PUSHED;
#     non-fast-forward → PUSH_REJECTED + non-zero; --force recovers
#   - push (temperloop#1688): the open-PR survey — a push onto a ref no open PR
#     references while a sibling PR sits on a DIFFERENT ref for the same slug is
#     PUSHED_UNWATCHED + non-zero, naming both refs and `stale_head_cause`; the
#     benign neighbours it must NOT fire on are all pinned as controls (a PR
#     whose head ref MATCHES but whose head sha trails — genuine GitHub lag; the
#     ordinary first push with no PR anywhere; an unrelated PR on a different
#     slug; a bounded-listing miss the --head confirm resolves; an erroring gh)
#   - open --body-only: per-entry bare `Closes` emission (gh_issue=278 +
#     also_closes=[171] → exactly `Closes #278` and `Closes #171`, own lines,
#     never combined, never backticked); acceptance recap; ## Verification;
#     backlinks + footer; fallback-to-recap when verification_surface absent
#   - acceptance-extract (temperloop#1267): the recap round-trips BYTE-EXACTLY
#     when ` — ` appears inside the criterion AND inside the evidence (evidence
#     now rides its own nested line, so the split is positional, not a
#     first-vs-last-em-dash guess); multi-line criteria, an evidence-less entry,
#     a decoy `## Acceptance` inside the worker's own surface, `-` stdin, an
#     empty result for a recap-less body, and a structured ERROR on a bad path
#   - open (temperloop#1023): a worker surface carrying its OWN copy of the
#     linkage block is stripped down to one block, a surface with no honored
#     closing-keyword line (mid-sentence / backticked / indented / fenced) is
#     passed through byte-for-byte, and the count rides `surface_closes_stripped`
#   - open (temperloop#2009): the PR-body cap — an under-cap body passes through
#     byte-identically with no marker and body_truncated_bytes=0; an over-cap body
#     is bounded BEFORE gh (the body actually handed to `gh pr create` is within
#     $BUILD_PR_BODY_MAX_BYTES), with verbatim reviewer prose dropped OLDEST review
#     round first and the newest round kept, an inline marker naming what/how
#     much/where, `--body-only` byte-identical to the outbound body, and the
#     linkage lines, acceptance recap, verification surface and footer never cut;
#     a review-prose-free over-cap body is bounded by eliding the surface's MIDDLE
#   - open (stubbed gh): PR_OPENED with parsed pr_number; body/head passed to gh
#   - recover-probe (temperloop#939): the staged lost-return ladder — RECOVER_NONE
#     / _COMMITTED / _PUSHED / _PR_OPEN across the four real fixture states, plus
#     the fail-soft degradation when `gh` errors
#   - recover-probe (temperloop#993): the RECOVER_DIRTY rung — a dirty worktree
#     with ZERO commits (the backgrounded-gate stall) is distinguished from a
#     clean RECOVER_NONE, and dirty/dirty_files ride every outcome
#   - error: structured ERROR + non-zero exit on bad inputs
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/pr.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@test \
       GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@test

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# Fixture: a BARE upstream (push-able) + a clone with main pushed, so
# origin/main exists — the same shape a real checkout has.
git init -q --bare --initial-branch=main "$TMP/upstream.git"
git clone -q "$TMP/upstream.git" "$TMP/repo" 2>/dev/null
git -C "$TMP/repo" commit -q --allow-empty -m init
git -C "$TMP/repo" push -q origin main 2>/dev/null
git -C "$TMP/repo" fetch -q origin
REPO="$(cd "$TMP/repo" && pwd -P)"
BARE="$TMP/upstream.git"

# --- scan: clean messages pass -------------------------------------------------
git -C "$REPO" checkout -q -b clean-br origin/main
git -C "$REPO" commit -q --allow-empty -m "add widget renderer" \
  -m "Plain description; mentions issue #153 without a closing keyword."
out="$(bash "$SCRIPT" scan "$REPO")"
[ "$(jq -r .outcome <<<"$out")" = "SCAN_CLEAN" ] || fail "clean scan not SCAN_CLEAN (got: $out)"
echo "PASS: scan → SCAN_CLEAN on closing-keyword-free commit messages"

# --- scan: a Closes #153 commit message blocks (the ec8d5fd class) --------------
git -C "$REPO" checkout -q -b bad-br origin/main
git -C "$REPO" commit -q --allow-empty -m "implement widget" -m "Closes #153"
rc=0; out="$(bash "$SCRIPT" scan "$REPO")" || rc=$?
[ "$rc" -ne 0 ] || fail "SCAN_BLOCKED did not exit non-zero"
[ "$(jq -r .outcome <<<"$out")" = "SCAN_BLOCKED" ] || fail "bad scan not SCAN_BLOCKED (got: $out)"
jq -e '.matches | index("Closes #153")' <<<"$out" >/dev/null \
  || fail "offending line not surfaced in .matches (got: $out)"
# Case-insensitive + other keywords: `fixes #12` blocks too.
git -C "$REPO" checkout -q -b bad-br2 origin/main
git -C "$REPO" commit -q --allow-empty -m "tweak widget" -m "this fixes #12 for good"
rc=0; out="$(bash "$SCRIPT" scan "$REPO")" || rc=$?
[ "$rc" -ne 0 ] && [ "$(jq -r .outcome <<<"$out")" = "SCAN_BLOCKED" ] \
  || fail "lowercase 'fixes #12' not blocked (got: $out)"
echo "PASS: scan → SCAN_BLOCKED + offending lines + non-zero exit on closing keywords"

# --- base-check: current base ----------------------------------------------------
git -C "$REPO" checkout -q clean-br
out="$(bash "$SCRIPT" base-check "$REPO")"
[ "$(jq -r .outcome <<<"$out")" = "BASE_CURRENT" ] || fail "base-check not BASE_CURRENT (got: $out)"
[ "$(jq -r .merge_base <<<"$out")" = "$(jq -r .tip <<<"$out")" ] \
  || fail "BASE_CURRENT but merge_base != tip (got: $out)"
echo "PASS: base-check → BASE_CURRENT when merge-base == origin/<default> tip"

# --- base-check: stale base after upstream advances ------------------------------
git clone -q "$BARE" "$TMP/advancer" 2>/dev/null
git -C "$TMP/advancer" -c user.name=test -c user.email=test@test \
  commit -q --allow-empty -m "level-k merge advances main"
git -C "$TMP/advancer" push -q origin main 2>/dev/null
out="$(bash "$SCRIPT" base-check "$REPO")"   # clean-br branched from the OLD tip
[ "$(jq -r .outcome <<<"$out")" = "BASE_STALE" ] || fail "base-check not BASE_STALE (got: $out)"
[ "$(jq -r .merge_base <<<"$out")" != "$(jq -r .tip <<<"$out")" ] \
  || fail "BASE_STALE but merge_base == tip (got: $out)"
echo "PASS: base-check → BASE_STALE once origin/<default> advances past the base"

# --- rebase: stale, non-conflicting base → REBASED onto the advanced tip ----------
# clean-br carries its own commit branched off the OLD tip; origin/main has since
# advanced (the advancer pushed an empty commit above). The worker's commit
# touches no file the advance touched, so the rebase replays cleanly. The PR diff
# vs the NEW tip must then contain ONLY the worker's own change — the #525 fix.
new_tip="$(git -C "$REPO" rev-parse origin/main)"
out="$(bash "$SCRIPT" rebase "$REPO")"
[ "$(jq -r .outcome <<<"$out")" = "REBASED" ] || fail "rebase not REBASED (got: $out)"
# HEAD is now a descendant of the advanced origin/main tip (base brought current).
[ "$(git -C "$REPO" merge-base HEAD origin/main)" = "$new_tip" ] \
  || fail "rebase did not bring HEAD's base onto the advanced origin/main tip"
[ "$(jq -r .sha <<<"$out")" = "$(git -C "$REPO" rev-parse HEAD)" ] \
  || fail "REBASED .sha != post-rebase HEAD (got: $out)"
[ "$(jq -r .rebase_needed <<<"$out")" = "true" ] \
  || fail "a stale base did not report rebase_needed:true (got: $out)"
# The cumulative diff vs the new tip is ONLY the worker's own commit (no revert of
# the intervening merge): exactly one commit ahead of origin/main.
[ "$(git -C "$REPO" rev-list --count origin/main..HEAD)" -eq 1 ] \
  || fail "rebased branch not exactly 1 commit ahead of advanced origin/main"
echo "PASS: rebase → REBASED replays the worker commit onto the advanced origin/<default> tip"

# --- rebase: already-current base → REBASED (no-op) --------------------------------
# A branch whose base is already the origin/main tip rebases to a no-op and still
# reports REBASED — the unconditional guard never errors on a current worker.
git -C "$REPO" fetch -q origin
git -C "$REPO" checkout -q -b current-br origin/main
git -C "$REPO" commit -q --allow-empty -m "on current tip"
cur_sha="$(git -C "$REPO" rev-parse HEAD)"
out="$(bash "$SCRIPT" rebase "$REPO")"
[ "$(jq -r .outcome <<<"$out")" = "REBASED" ] || fail "current-base rebase not REBASED (got: $out)"
[ "$(jq -r .sha <<<"$out")" = "$cur_sha" ] || fail "no-op rebase changed HEAD (got: $out)"
# temperloop#735: base == tip is reported as such — the rebase is SKIPPED, not run.
[ "$(jq -r .rebase_needed <<<"$out")" = "false" ] \
  || fail "current-base REBASED did not report rebase_needed:false (got: $out)"
[ "$(jq -r .base <<<"$out")" = "$(jq -r .tip <<<"$out")" ] \
  || fail "rebase_needed:false but base != tip (got: $out)"
echo "PASS: rebase → REBASED no-op (rebase_needed:false) when the worker's base is already current"

# --- rebase: untracked files are NOT dirt ------------------------------------------
# git rebases straight past untracked files, and every build worktree carries at
# least the untracked `.build-guard` marker — so an untracked file must never be
# read as a dirty worktree (temperloop#735).
printf 'scratch\n' > "$REPO/untracked-scratch.txt"
out="$(bash "$SCRIPT" rebase "$REPO")"
[ "$(jq -r .outcome <<<"$out")" = "REBASED" ] \
  || fail "untracked file read as dirt (got: $out)"
rm -f "$REPO/untracked-scratch.txt"
echo "PASS: rebase → REBASED with an untracked file present (untracked ≠ dirty)"

# --- rebase: dirty worktree, base already current → DIRTY_WORKTREE -----------------
# The temperloop#735 case, verbatim: a FINISHED worker (commit made) that left one
# tracked file unstaged, on a base that is already current — so no rebase was ever
# needed and no conflict exists anywhere. git refuses to start the rebase; that
# refusal must NOT be reported as REBASE_CONFLICT, and the worker's uncommitted
# edit must be left exactly where it is (this run would otherwise be discarded).
git -C "$REPO" fetch -q origin
git -C "$REPO" checkout -q -b dirty-current origin/main
printf 'committed\n' > "$REPO/worker.txt"
git -C "$REPO" add worker.txt
git -C "$REPO" commit -q -m "worker commits worker.txt"
dirty_sha="$(git -C "$REPO" rev-parse HEAD)"
printf 'forgotten unstaged edit\n' >> "$REPO/worker.txt"     # the load-bearing leftover
rc=0; out="$(bash "$SCRIPT" rebase "$REPO" 2>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] || fail "DIRTY_WORKTREE did not exit non-zero"
[ "$(jq -r .outcome <<<"$out")" = "DIRTY_WORKTREE" ] \
  || fail "unstaged-changes refusal not DIRTY_WORKTREE (got: $out)"
[ "$(jq -r .rebase_needed <<<"$out")" = "false" ] \
  || fail "DIRTY_WORKTREE on a current base did not report rebase_needed:false (got: $out)"
[ "$(jq -r .base <<<"$out")" = "$(jq -r .tip <<<"$out")" ] \
  || fail "the #735 base==tip fact is not visible in the payload (got: $out)"
[ "$(jq -r .dirty_files <<<"$out")" = "1" ] || fail "dirty_files != 1 (got: $out)"
jq -e '.dirty_paths | join(" ") | test("worker[.]txt")' <<<"$out" >/dev/null \
  || fail "the offending path is not named in .dirty_paths (got: $out)"
# Nothing was attempted, so nothing was aborted: HEAD intact AND the edit intact.
[ ! -d "$REPO/.git/rebase-merge" ] && [ ! -d "$REPO/.git/rebase-apply" ] \
  || fail "DIRTY_WORKTREE left a rebase in progress"
[ "$(git -C "$REPO" rev-parse HEAD)" = "$dirty_sha" ] \
  || fail "DIRTY_WORKTREE moved HEAD"
grep -q 'forgotten unstaged edit' "$REPO/worker.txt" \
  || fail "DIRTY_WORKTREE destroyed the worker's uncommitted edit"
# Committing the leftover is all it takes: the same tree then rebases clean.
git -C "$REPO" add worker.txt
git -C "$REPO" commit -q -m "amend in the leftover"
out="$(bash "$SCRIPT" rebase "$REPO")"
[ "$(jq -r .outcome <<<"$out")" = "REBASED" ] \
  || fail "committing the leftover did not clear DIRTY_WORKTREE (got: $out)"
echo "PASS: rebase → DIRTY_WORKTREE (rebase_needed:false, edit preserved) on an unstaged-changes refusal"

# --- rebase: conflicting base → REBASE_CONFLICT + abort (worktree left clean) ------
# A worker that edits the SAME line the intervening merge edited conflicts on
# rebase. The script must ABORT (leave the worktree clean — no half-applied
# rebase, no rebase-in-progress, never a silent revert) and emit REBASE_CONFLICT
# + non-zero exit so the orchestrator escalates a rebase conflict.
git -C "$REPO" fetch -q origin
git -C "$REPO" checkout -q -b conflict-base origin/main
printf 'worker line\n' > "$REPO/shared.txt"
git -C "$REPO" add shared.txt
git -C "$REPO" commit -q -m "worker edits shared.txt"
# Advance origin/main with a CONFLICTING edit to the same file/line.
git clone -q "$BARE" "$TMP/advancer2" 2>/dev/null
git -C "$TMP/advancer2" -c user.name=test -c user.email=test@test checkout -q main
printf 'main line\n' > "$TMP/advancer2/shared.txt"
git -C "$TMP/advancer2" add shared.txt
git -C "$TMP/advancer2" -c user.name=test -c user.email=test@test commit -q -m "main edits shared.txt"
git -C "$TMP/advancer2" push -q origin main 2>/dev/null
rc=0; out="$(bash "$SCRIPT" rebase "$REPO" 2>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] || fail "REBASE_CONFLICT did not exit non-zero"
[ "$(jq -r .outcome <<<"$out")" = "REBASE_CONFLICT" ] || fail "conflict not REBASE_CONFLICT (got: $out)"
# Aborted: no rebase-in-progress, working tree clean, HEAD back at the worker commit.
[ ! -d "$REPO/.git/rebase-merge" ] && [ ! -d "$REPO/.git/rebase-apply" ] \
  || fail "rebase left in progress — not aborted (silent-revert risk)"
[ -z "$(git -C "$REPO" status --porcelain)" ] || fail "worktree not clean after conflict abort"
[ "$(cat "$REPO/shared.txt")" = "worker line" ] \
  || fail "conflict abort did not restore the worker's content (silent revert)"
echo "PASS: rebase → REBASE_CONFLICT aborts the rebase (clean worktree, no silent revert) + non-zero exit"

# --- rebase: the discriminating twin — SAME conflicting base, but dirty -----------
# Identical repo state to the case just above (a genuine content conflict is
# waiting), plus an uncommitted tracked-file edit. git refuses BEFORE it can ever
# reach the conflict, so the honest answer is DIRTY_WORKTREE — even though a real
# conflict does exist here. Without this pair, a pre-check that simply relabelled
# every rebase failure would pass the case above just as happily (temperloop#735).
printf 'worker line\nuncommitted tail\n' > "$REPO/shared.txt"
rc=0; out="$(bash "$SCRIPT" rebase "$REPO" 2>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] || fail "dirty-over-conflict did not exit non-zero"
[ "$(jq -r .outcome <<<"$out")" = "DIRTY_WORKTREE" ] \
  || fail "dirty tree over a conflicting base not DIRTY_WORKTREE (got: $out)"
[ "$(jq -r .rebase_needed <<<"$out")" = "true" ] \
  || fail "DIRTY_WORKTREE on a STALE base did not report rebase_needed:true (got: $out)"
grep -q 'uncommitted tail' "$REPO/shared.txt" \
  || fail "dirty-over-conflict destroyed the uncommitted edit"
# Drop the dirt and the SAME tree reports the genuine conflict again — the
# conflict path is narrowed, not disabled.
git -C "$REPO" checkout -q -- shared.txt
rc=0; out="$(bash "$SCRIPT" rebase "$REPO" 2>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] && [ "$(jq -r .outcome <<<"$out")" = "REBASE_CONFLICT" ] \
  || fail "genuine conflict no longer reports REBASE_CONFLICT once the tree is clean (got: $out)"
echo "PASS: rebase → dirty-over-a-conflicting-base is DIRTY_WORKTREE; clean the tree and it is REBASE_CONFLICT again"

# Restore to a clean detached-from-conflict state for the push tests below, which
# expect clean-br checked out on the (now twice-advanced) main lineage.
git -C "$REPO" checkout -q clean-br

# `pr.sh push` now surveys open PRs (temperloop#1688), so every push below runs
# with an erroring `gh` on PATH — deterministic and network-free (kernel
# principle 3), and the fail-soft arm the survey must degrade through. The
# survey's own outcomes get real stubs in the #1688 block further down.
NOGH="$TMP/bin-nogh"
mkdir -p "$NOGH"
cat > "$NOGH/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh: could not determine repository" >&2
exit 1
EOF
chmod +x "$NOGH/gh"

# --- push: push-by-SHA places the branch on the bare remote ----------------------
sha="$(git -C "$REPO" rev-parse HEAD)"
out="$(PATH="$NOGH:$PATH" bash "$SCRIPT" push "$REPO" feat/widget)"
[ "$(jq -r .outcome <<<"$out")" = "PUSHED" ] || fail "push outcome (got: $out)"
[ "$(jq -r .sha <<<"$out")" = "$sha" ] || fail "push sha mismatch (got: $out)"
[ "$(jq -r .branch <<<"$out")" = "feat/widget" ] || fail "push branch (got: $out)"
[ "$(git -C "$BARE" rev-parse refs/heads/feat/widget)" = "$sha" ] \
  || fail "remote branch feat/widget not at pushed sha"
echo "PASS: push places HEAD by SHA on the remote plan branch (PUSHED)"

# --- push: non-fast-forward rejected without --force; --force recovers -----------
git -C "$REPO" commit -q --amend --allow-empty -m "reworded widget commit"
newsha="$(git -C "$REPO" rev-parse HEAD)"
rc=0; out="$(PATH="$NOGH:$PATH" bash "$SCRIPT" push "$REPO" feat/widget)" || rc=$?
[ "$rc" -ne 0 ] || fail "non-FF push did not exit non-zero"
[ "$(jq -r .outcome <<<"$out")" = "PUSH_REJECTED" ] || fail "collision not PUSH_REJECTED (got: $out)"
out="$(PATH="$NOGH:$PATH" bash "$SCRIPT" push "$REPO" feat/widget --force)"
[ "$(jq -r .outcome <<<"$out")" = "PUSHED" ] || fail "push --force outcome (got: $out)"
[ "$(git -C "$BARE" rev-parse refs/heads/feat/widget)" = "$newsha" ] \
  || fail "remote branch not at force-pushed sha"
# #335: the amended HEAD does NOT descend from the remote tip (a genuine
# history rewrite), so --force is really used — forced=true.
[ "$(jq -r .forced <<<"$out")" = "true" ] \
  || fail "genuine rewrite must report forced=true (got: $out)"
echo "PASS: push collision → PUSH_REJECTED + non-zero; --force re-push lands (PUSHED, forced=true)"

# --- push: --force on a fast-forward descendant DOWNGRADES to a plain push (#335) ---
# A CI-retry commit is a fast-forward descendant of the already-pushed head: the
# CI-fix worker resets to the remote tip and commits on top. build-level.mjs
# still *requests* --force (pr.sh push … --force), but because the local head
# descends from the current remote tip the push needs no history rewrite — pr.sh
# must DOWNGRADE to a plain (non-force) push (forced=false) so the git-destructive
# safety classifier is never engaged. The remote must still advance to the new sha.
git -C "$REPO" fetch -q origin
git -C "$REPO" checkout -q -B ff-retry refs/remotes/origin/feat/widget
ff_base="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" commit -q --allow-empty -m "CI-retry fix commit (ff descendant)"
ff_sha="$(git -C "$REPO" rev-parse HEAD)"
[ "$ff_sha" != "$ff_base" ] || fail "fixture error: ff-retry commit did not advance HEAD"
out="$(PATH="$NOGH:$PATH" bash "$SCRIPT" push "$REPO" feat/widget --force)"
[ "$(jq -r .outcome <<<"$out")" = "PUSHED" ] || fail "ff --force push outcome (got: $out)"
[ "$(jq -r .forced <<<"$out")" = "false" ] \
  || fail "fast-forward --force must DOWNGRADE to a plain push (forced=false) (got: $out)"
[ "$(git -C "$BARE" rev-parse refs/heads/feat/widget)" = "$ff_sha" ] \
  || fail "remote branch did not advance to the fast-forward retry sha"
echo "PASS: push --force on a fast-forward descendant downgrades to a plain push (PUSHED, forced=false)"

# --- push: a plain (non-force) push reports forced=false --------------------------
git -C "$REPO" fetch -q origin
git -C "$REPO" checkout -q -b plainpush origin/main
git -C "$REPO" commit -q --allow-empty -m "fresh branch commit"
plainsha="$(git -C "$REPO" rev-parse HEAD)"
out="$(PATH="$NOGH:$PATH" bash "$SCRIPT" push "$REPO" feat/plainpush)"
[ "$(jq -r .outcome <<<"$out")" = "PUSHED" ] || fail "plain push outcome (got: $out)"
[ "$(jq -r .forced <<<"$out")" = "false" ] || fail "plain push must report forced=false (got: $out)"
[ "$(git -C "$BARE" rev-parse refs/heads/feat/plainpush)" = "$plainsha" ] \
  || fail "plain push did not land the branch"
echo "PASS: plain push (no --force requested) reports forced=false"

# --- push: THE REBASE-THEN-PUSH SEQUENCE, pinned end to end (temperloop#2103) ------
# The live shape, observed three times in one session and hand-recovered every
# time: a CONTINUATION round whose branch an earlier round already pushed, which
# 3f-0a then rebases onto a newer origin/<default>. The rewritten history does
# not contain the remote tip, so a plain push can NEVER fast-forward — this is a
# structural consequence of rebase-then-plain-push, not a transient.
#
# Two halves, and the first is the one that matters: a plain push here MUST NOT
# silently return success. If it ever did, the run would proceed to open a PR on
# a ref still serving the PRE-rebase content while the rebased commits existed
# only in the worktree — the loss path the whole issue is about. The second half
# is the fix: `--allow-rewrite` lands it under a LEASE over the value pr.sh read
# first, and the payload carries that value so the rewrite is auditable.
git -C "$REPO" fetch -q origin
git -C "$REPO" checkout -q -B cont origin/main
printf 'round 1\n' > "$REPO/cont.txt"
git -C "$REPO" add -A -- cont.txt
git -C "$REPO" commit -q -m "continuation round 1 work"
out="$(PATH="$NOGH:$PATH" bash "$SCRIPT" push "$REPO" fix/cont)"
[ "$(jq -r .outcome <<<"$out")" = "PUSHED" ] || fail "fixture setup: round-1 push (got: $out)"
round1="$(git -C "$REPO" rev-parse HEAD)"
# origin/<default> advances underneath, exactly as it does when a sibling item
# merges during a long build — this is what makes the rebase non-trivial.
git -C "$REPO" checkout -q -B advancer origin/main
printf 'a sibling item merged\n' > "$REPO/sibling.txt"
git -C "$REPO" add -A -- sibling.txt
git -C "$REPO" commit -q -m "sibling item"
git -C "$REPO" push -q origin HEAD:main
git -C "$REPO" checkout -q cont
out="$(PATH="$NOGH:$PATH" bash "$SCRIPT" rebase "$REPO")"
[ "$(jq -r .outcome <<<"$out")" = "REBASED" ] || fail "fixture setup: 3f-0a rebase (got: $out)"
rebased="$(git -C "$REPO" rev-parse HEAD)"
[ "$rebased" != "$round1" ] || fail "fixture error: the rebase did not rewrite the branch"
# RED half — a plain push of the rewritten, already-pushed branch.
rc=0; out="$(PATH="$NOGH:$PATH" bash "$SCRIPT" push "$REPO" fix/cont)" || rc=$?
[ "$rc" -ne 0 ] \
  || fail "a plain push of a REWRITTEN, already-pushed branch returned SUCCESS — the rebased commits are not on origin (got: $out)"
[ "$(jq -r .outcome <<<"$out")" = "PUSH_REJECTED" ] \
  || fail "rebase-then-plain-push must be PUSH_REJECTED (got: $out)"
[ "$(jq -r .forced <<<"$out")" = "false" ] \
  || fail "a rejection with no rewrite requested must say forced=false (got: $out)"
# The ORDINARY non-fast-forward rejection carries no refusal reason — this is the
# control the collision-refusal block below is distinguished against (#2103 r3).
[ "$(jq -r .refused_reason <<<"$out")" = "null" ] \
  || fail "#2103: a rejection where NO rewrite was requested must not claim a refusal reason (got: $out)"
[ "$(git -C "$BARE" rev-parse refs/heads/fix/cont)" = "$round1" ] \
  || fail "a rejected push must leave origin exactly where it was"
# GREEN half — the same sequence with the rewrite requested.
out="$(PATH="$NOGH:$PATH" bash "$SCRIPT" push "$REPO" fix/cont --allow-rewrite)"
[ "$(jq -r .outcome <<<"$out")" = "PUSHED" ] \
  || fail "--allow-rewrite must land a rebased continuation branch without hand intervention (got: $out)"
[ "$(jq -r .forced <<<"$out")" = "true" ] || fail "a genuine rewrite must report forced=true (got: $out)"
[ "$(jq -r .lease <<<"$out")" = "$round1" ] \
  || fail "the force must be LEASED against the remote value read first, and report it (got: $out)"
[ "$(git -C "$BARE" rev-parse refs/heads/fix/cont)" = "$rebased" ] \
  || fail "the leased rewrite did not land the rebased tip on origin"
echo "PASS: rebase-then-push — a plain push of a rewritten, already-pushed branch is REJECTED (never a silent success); --allow-rewrite lands it under a lease (#2103)"

# --- push: a branch-name collision with UNRELATED content REFUSES (#2103 round 3) ---
# THE ASYMMETRY THIS BLOCK CLOSES. The block above proves --allow-rewrite lands a
# rebased continuation; because 3f-1 passes that flag on EVERY item's push rather
# than only on a rescue, the same code path now runs over any branch name that
# happens to already exist on origin. A lease does not help there: it only stops a
# writer who moves the ref BETWEEN the read and the push, and says nothing about
# content that was already sitting on it. So a leftover manual branch, a reused
# slug or a planning bug would be force-overwritten and reported as an ordinary
# PUSHED, which the driver takes straight into opening a PR — silent loss on the
# busiest push path in the pipeline, and the exact shape this whole issue exists
# about. The escalation-time rescue push refuses this case; this asserts the
# ordinary push now refuses it too, on the same patch-equivalence test.
#
# The fixture is a GENUINE content collision, not a stale copy of the same work:
# what is on origin (`unrelated.txt`) has no patch-equivalent anywhere in the
# pushing worktree (`ours.txt`), so nothing here is superseded by anything.
git -C "$REPO" fetch -q origin
git -C "$REPO" checkout -q -B collide-theirs origin/main
printf 'work that has nothing to do with our item\n' > "$REPO/unrelated.txt"
git -C "$REPO" add -A -- unrelated.txt
git -C "$REPO" commit -q -m "unrelated work already living on this branch name"
out="$(PATH="$NOGH:$PATH" bash "$SCRIPT" push "$REPO" fix/collide)"
[ "$(jq -r .outcome <<<"$out")" = "PUSHED" ] \
  || fail "fixture setup: the colliding branch must exist on origin first (got: $out)"
collide="$(git -C "$REPO" rev-parse HEAD)"
# A DIFFERENT item now plans the same branch name. Its history diverged from the
# default branch, so the remote tip is not an ancestor of HEAD and the rewrite
# arm is reached — the same arm the rebased-continuation case takes.
git -C "$REPO" checkout -q -B collide-ours origin/main
printf 'a completely different item\n' > "$REPO/ours.txt"
git -C "$REPO" add -A -- ours.txt
git -C "$REPO" commit -q -m "a completely different item"
rc=0; out="$(PATH="$NOGH:$PATH" bash "$SCRIPT" push "$REPO" fix/collide --allow-rewrite)" || rc=$?
[ "$rc" -ne 0 ] \
  || fail "#2103: a rewrite over UNRELATED remote content returned SUCCESS — that content is gone (got: $out)"
[ "$(jq -r .outcome <<<"$out")" != "PUSHED" ] \
  || fail "#2103: a refused collision must NOT be reported as an ordinary push (got: $out)"
[ "$(jq -r .outcome <<<"$out")" = "PUSH_REJECTED" ] \
  || fail "#2103: a collision with unrelated content must be a structured PUSH_REJECTED (got: $out)"
[ "$(jq -r .forced <<<"$out")" = "false" ] \
  || fail "#2103: a refused collision must issue NO force at all (got: $out)"
[ "$(jq -r .refused_reason <<<"$out")" = "remote_not_superseded" ] \
  || fail "#2103: the refusal must be distinguishable from an ordinary non-ff rejection (got: $out)"
[ "$(jq -r .remote_tip <<<"$out")" = "$collide" ] \
  || fail "#2103: the refusal must name the remote tip it refused over (got: $out)"
[ "$(jq -r .remote_only_commits <<<"$out")" = "1" ] \
  || fail "#2103: the refusal must report the established remote-only commit count (got: $out)"
case "$(jq -r .error <<<"$out")" in
  *REFUSED*) : ;;
  *) fail "#2103: the rejection text must SAY it refused, ahead of git's non-ff message (got: $out)" ;;
esac
# The load-bearing assertion: the unrelated work is still on origin, byte for byte.
[ "$(git -C "$BARE" rev-parse refs/heads/fix/collide)" = "$collide" ] \
  || fail "#2103: THE COLLIDING BRANCH WAS OVERWRITTEN — unrelated work on origin/fix/collide was destroyed"
echo "PASS: a branch-name collision with unrelated content REFUSES and leaves origin untouched, distinguishably (#2103)"

# --- push: a CONTEXT-SHIFTING rebase is still superseded (temperloop#2095) --------
# THE FALSE POSITIVE THIS BLOCK PINS. The rebased-continuation block above passes
# only because its round-1 commit and the sibling that advanced main touch
# DIFFERENT files, so the rebase replays the commit byte-identically and its
# patch-id survives. That is the lucky case. `git patch-id` hashes the diff
# BODY — context lines included — so the moment the sibling's change lands within
# three lines of the item's own hunk, the rebased commit's patch-id CHANGES even
# though it applied cleanly and dropped nothing. `rev-list --cherry-pick` then
# counts the engine's OWN round-1 commit as unique remote work and refuses the
# push it is supposed to allow. The engine rebases on EVERY continuation round,
# so this fires on the common path, not the rare one (live: /fix 1650 round 2 —
# remote tip carried 1 "remote-only" commit whose rebased equivalent changed the
# same 4 files with the same +377/-1, and the refusal was pure false positive).
#
# The fixture makes the context shift explicit: round 1 edits the LAST line of a
# shared file, the sibling that merges into main edits a line three above it, and
# the rebase therefore rewrites round 1's context. Nothing is dropped.
git -C "$REPO" fetch -q origin
git -C "$REPO" checkout -q -B ctx-seed origin/main
printf 'L1\nL2\nL3\nL4\nL5\nL6\n' > "$REPO/shared.txt"
git -C "$REPO" add -A -- shared.txt
git -C "$REPO" commit -q -m "seed the shared file"
git -C "$REPO" push -q origin HEAD:main
git -C "$REPO" fetch -q origin
git -C "$REPO" checkout -q -B ctxcont origin/main
printf 'L1\nL2\nL3\nL4\nL5\nL6 ROUND1\n' > "$REPO/shared.txt"
git -C "$REPO" commit -q -am "continuation round 1 — edits the tail of shared.txt"
out="$(PATH="$NOGH:$PATH" bash "$SCRIPT" push "$REPO" fix/ctxcont)"
[ "$(jq -r .outcome <<<"$out")" = "PUSHED" ] || fail "fixture setup: ctx round-1 push (got: $out)"
ctx_round1="$(git -C "$REPO" rev-parse HEAD)"
# origin/main advances with a change INSIDE round 1's context window.
git -C "$REPO" checkout -q -B ctxadvancer origin/main
printf 'L1\nL2\nL3\nL4 SIBLING\nL5\nL6\n' > "$REPO/shared.txt"
git -C "$REPO" commit -q -am "sibling item edits shared.txt inside round 1's context"
git -C "$REPO" push -q origin HEAD:main
git -C "$REPO" checkout -q ctxcont
out="$(PATH="$NOGH:$PATH" bash "$SCRIPT" rebase "$REPO")"
[ "$(jq -r .outcome <<<"$out")" = "REBASED" ] || fail "fixture setup: ctx 3f-0a rebase (got: $out)"
ctx_rebased="$(git -C "$REPO" rev-parse HEAD)"
# Fixture assertion, so a future git that preserved patch-ids across a context
# shift would fail LOUDLY here rather than silently turn this block vacuous.
[ "$(git -C "$REPO" rev-list --count --cherry-pick --right-only --no-merges "HEAD...$ctx_round1")" != "0" ] \
  || fail "#2095: fixture no longer produces a patch-id shift — this block would prove nothing"
# Nothing was dropped: every line round 1 added is still in the rebased tree.
grep -q 'L6 ROUND1' "$REPO/shared.txt" \
  || fail "#2095: fixture error — the rebase did not preserve round 1's work"
rc=0; out="$(PATH="$NOGH:$PATH" bash "$SCRIPT" push "$REPO" fix/ctxcont --allow-rewrite)" || rc=$?
[ "$rc" -eq 0 ] \
  || fail "#2095: a rebase that PRESERVED every pushed commit must be allowed to push (got: $out)"
[ "$(jq -r .outcome <<<"$out")" = "PUSHED" ] \
  || fail "#2095: a context-shifting but fully-preserving rebase must be PUSHED, not refused (got: $out)"
[ "$(jq -r .refused_reason <<<"$out")" = "null" ] \
  || fail "#2095: a preserved rebase must carry NO refusal reason (got: $out)"
[ "$(jq -r .forced <<<"$out")" = "true" ] \
  || fail "#2095: the preserved rebase must land as a LEASED force (got: $out)"
[ "$(jq -r .lease <<<"$out")" = "$ctx_round1" ] \
  || fail "#2095: the force must be leased against the value read from origin (got: $out)"
[ "$(jq -r .supersede_basis <<<"$out")" = "content-containment" ] \
  || fail "#2095: the payload must name WHICH oracle allowed the rewrite (got: $out)"
[ "$(git -C "$BARE" rev-parse refs/heads/fix/ctxcont)" = "$ctx_rebased" ] \
  || fail "#2095: the rebased tip did not land on origin"
echo "PASS: a context-shifting rebase that preserved every pushed commit is allowed to push (#2095)"

# --- push: a GENUINE drop is still refused (temperloop#2095) ----------------------
# The other half, and the one that keeps the fix from being a regression. The
# probe's own comment documents the conservative narrowing deliberately: a
# continuation round that DROPS a commit an earlier round pushed must not rewrite
# unattended — it refuses and escalates for triage. Loosening the oracle for the
# rebase case must not loosen it for this one, so the same fixture shape is run
# with one of round 1's commits genuinely dropped.
git -C "$REPO" fetch -q origin
git -C "$REPO" checkout -q -B dropcont origin/main
printf 'keep me\n' > "$REPO/keep.txt"
git -C "$REPO" add -A -- keep.txt
git -C "$REPO" commit -q -m "round 1 commit A — kept"
drop_keep="$(git -C "$REPO" rev-parse HEAD)"
printf 'do not lose me\n' > "$REPO/dropped.txt"
git -C "$REPO" add -A -- dropped.txt
git -C "$REPO" commit -q -m "round 1 commit B — the one round 2 drops"
out="$(PATH="$NOGH:$PATH" bash "$SCRIPT" push "$REPO" fix/dropcont)"
[ "$(jq -r .outcome <<<"$out")" = "PUSHED" ] || fail "fixture setup: drop round-1 push (got: $out)"
drop_round1="$(git -C "$REPO" rev-parse HEAD)"
# origin/main advances, then round 2 rebases only commit A — commit B is gone.
git -C "$REPO" checkout -q -B dropadvancer origin/main
printf 'another sibling\n' > "$REPO/sibling2.txt"
git -C "$REPO" add -A -- sibling2.txt
git -C "$REPO" commit -q -m "sibling item 2"
git -C "$REPO" push -q origin HEAD:main
git -C "$REPO" fetch -q origin
git -C "$REPO" checkout -q -B dropcont "$drop_keep"
git -C "$REPO" rebase -q origin/main
[ ! -e "$REPO/dropped.txt" ] || fail "#2095: fixture error — commit B was not actually dropped"
rc=0; out="$(PATH="$NOGH:$PATH" bash "$SCRIPT" push "$REPO" fix/dropcont --allow-rewrite)" || rc=$?
[ "$rc" -ne 0 ] \
  || fail "#2095: a continuation that DROPS a pushed commit must NOT rewrite unattended (got: $out)"
[ "$(jq -r .outcome <<<"$out")" = "PUSH_REJECTED" ] \
  || fail "#2095: a genuine drop must stay a structured PUSH_REJECTED (got: $out)"
[ "$(jq -r .forced <<<"$out")" = "false" ] \
  || fail "#2095: a refused drop must issue NO force at all (got: $out)"
[ "$(jq -r .refused_reason <<<"$out")" = "remote_not_superseded" ] \
  || fail "#2095: a genuine drop must still be refused as remote_not_superseded (got: $out)"
[ "$(git -C "$BARE" rev-parse refs/heads/fix/dropcont)" = "$drop_round1" ] \
  || fail "#2095: THE DROPPED COMMIT WAS OVERWRITTEN — origin/fix/dropcont lost work"
echo "PASS: a continuation that genuinely drops a pushed commit is STILL refused and escalated (#2095)"

# --- push: the lease is LOAD-BEARING — a moved remote is rejected, not clobbered ---
# The discriminating test for temperloop#2103's "lease-guarded, never unguarded"
# bar. A bare `--force` would land here and destroy whatever the remote gained
# between the read and the push; the lease must turn that into a rejection.
#
# The concurrent writer is simulated deterministically by splitting the remote's
# URLs: the FETCH url points at a stale snapshot (so the value pr.sh reads is
# `round1`), while the PUSH url points at the real upstream (already advanced to
# `$rebased` by the block above). That is precisely the state a real concurrent
# writer creates — the value read is no longer the value on the ref.
#
# The pushing history is a CONTINUATION of `$rebased` (round 2 on top of the
# landed round-1 work), deliberately, so that it supersedes the stale `$round1`
# the fetch url serves and the supersede gate added in round 3 lets the force
# through. That keeps this block pinning the property it names — the LEASE is
# what catches the moved ref — rather than being short-circuited by the earlier
# gate and silently testing nothing about leases at all. The genuine
# non-superseding case has its own block above.
git init -q --bare --initial-branch=main "$TMP/stale.git"
git -C "$REPO" push -q "$TMP/stale.git" "$round1:refs/heads/fix/cont"
git -C "$REPO" push -q "$TMP/stale.git" "$rebased:refs/heads/main"
git clone -q "$BARE" "$TMP/leaserepo" 2>/dev/null
LEASEREPO="$(cd "$TMP/leaserepo" && pwd -P)"
git -C "$LEASEREPO" remote set-url origin "$TMP/stale.git"
git -C "$LEASEREPO" remote set-url --push origin "$BARE"
git -C "$LEASEREPO" checkout -q -b leaser origin/fix/cont
[ "$(git -C "$LEASEREPO" rev-parse HEAD)" = "$rebased" ] \
  || fail "fixture setup: the leasing worktree must start from the landed rebased tip"
printf 'round 2\n' > "$LEASEREPO/cont.txt"
git -C "$LEASEREPO" add -A -- cont.txt
git -C "$LEASEREPO" commit -q -m "continuation round 2 work"
rc=0; out="$(PATH="$NOGH:$PATH" bash "$SCRIPT" push "$LEASEREPO" fix/cont --allow-rewrite)" || rc=$?
[ "$rc" -ne 0 ] || fail "a STALE lease must not push (got: $out)"
[ "$(jq -r .outcome <<<"$out")" = "PUSH_REJECTED" ] || fail "a stale lease must be PUSH_REJECTED (got: $out)"
[ "$(jq -r .forced <<<"$out")" = "true" ] \
  || fail "#2103: a SUPERSEDING rewrite must still be issued as a leased force — this block must reach the lease, not the supersede gate (got: $out)"
[ "$(jq -r .refused_reason <<<"$out")" = "null" ] \
  || fail "#2103: a stale-lease rejection is not a supersede refusal and must not claim to be (got: $out)"
[ "$(jq -r .lease <<<"$out")" = "$round1" ] || fail "the rejection must name the stale value it leased against (got: $out)"
[ "$(git -C "$BARE" rev-parse refs/heads/fix/cont)" = "$rebased" ] \
  || fail "THE LEASE FAILED TO PROTECT: origin's fix/cont was overwritten out from under a concurrent writer"
echo "PASS: a force whose leased value has moved is REJECTED and origin is left untouched (#2103)"

# --- push: an UNREACHABLE origin still prints its outcome line (#2103 round 2) ---
# The lease read is the only network call that happens BEFORE the push, and it
# runs under pr.sh's `set -euo pipefail`. A missing ref is benign (ls-remote
# exits 0 and empty), but an unreachable or auth-failed origin — a network blip,
# an expired credential, a GitHub outage mid-unattended-run — fails BOTH the
# fetch and the ls-remote. Unguarded, pipefail carried that status into a plain
# assignment and `set -e` killed pr.sh at the lease line, with 2>/dev/null
# swallowing the diagnostic: exit 128, stdout and stderr EMPTY. That breaks
# runMachinery's executor contract (a non-zero exit STILL prints its outcome
# line) and leaves the solo executor to invent an outcome — on the one path
# whose entire purpose is not losing work. The behaviour asserted here is the
# one the pr.sh header already promises: an unreadable remote issues NO force,
# and the plain push fails LOUDLY as a structured PUSH_REJECTED.
git init -q --initial-branch=main "$TMP/unreachable-wt"
UNREACHWT="$(cd "$TMP/unreachable-wt" && pwd -P)"
git -C "$UNREACHWT" config user.email t@example.com
git -C "$UNREACHWT" config user.name "t"
git -C "$UNREACHWT" commit -q --allow-empty -m "work held only in this worktree"
# An origin that cannot be reached at all — deterministic and offline (#3: no
# live network in a fixture); a path that does not exist reproduces it exactly.
git -C "$UNREACHWT" remote add origin "$TMP/no-such-origin.git"
rc=0
out="$(PATH="$NOGH:$PATH" bash "$SCRIPT" push "$UNREACHWT" fix/unreachable-2103 --allow-rewrite 2>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] || fail "a push to an unreachable origin must exit non-zero (got: $out)"
[ -n "$out" ] \
  || fail "#2103: pr.sh DIED without printing an outcome line on an unreachable origin (rc=$rc) — the lease read must be guarded"
jq -e . >/dev/null 2>&1 <<<"$out" \
  || fail "#2103: an unreachable origin must still print PARSEABLE JSON (got: $out)"
[ "$(jq -r .outcome <<<"$out")" = "PUSH_REJECTED" ] \
  || fail "#2103: an unreachable origin must be a structured PUSH_REJECTED (got: $out)"
[ "$(jq -r .forced <<<"$out")" = "false" ] \
  || fail "#2103: an UNREADABLE remote value must issue NO force at all (got: $out)"
[ "$(jq -r .lease <<<"$out")" = "null" ] \
  || fail "#2103: there is no leased value when the remote could not be read (got: $out)"
[ -n "$(jq -r '.error // ""' <<<"$out")" ] \
  || fail "#2103: the rejection must carry the diagnostic, not swallow it (got: $out)"
echo "PASS: an unreachable origin is a structured PUSH_REJECTED with no force, not a silent exit-128 death (#2103)"

# --- push: pr.sh never issues an UNGUARDED force ----------------------------------
# A static floor under both blocks above: every `git push` in pr.sh that forces
# must do so through --force-with-lease. A future edit that reaches for a bare
# --force reintroduces exactly the loss this issue is about, and would pass both
# functional fixtures above.
grep -q -- '--force-with-lease=refs/heads/' "$SCRIPT" \
  || fail "#2103: pr.sh must force through --force-with-lease=<ref>:<sha>"
# Both spellings of a bare force are covered, because they are the two a future
# author actually reaches for: the long `--force` and the `-f` shorthand. The
# pipeline is fine here — it is an `if` condition, so pipefail's non-zero from
# the inner grep is the intended "no match".
if grep -vE '^[[:space:]]*#' "$SCRIPT" | grep -nE 'git[^|;&]*push[^|;&]*(--force([^-=]|$)|-f( |$))'; then
  fail "#2103: pr.sh issues a BARE git push --force/-f — a force here must always be leased"
fi
# And an expect-less `git push --force-with-lease` is a bare force wearing the
# right name: with no `=<ref>:<sha>` it leases against the LOCAL remote-tracking
# ref, which a preceding fetch has just made agree with origin — the classic
# fetch-then-lease footgun, which silently clobbers exactly the concurrent
# writer the lease is supposed to catch. Every occurrence must carry an explicit
# expect value read at push time.
if grep -vE '^[[:space:]]*#' "$SCRIPT" | grep -nE -- '--force-with-lease([^=]|$)'; then
  fail "#2103: pr.sh uses --force-with-lease with NO =<ref>:<sha> expect value — that leases against the local tracking ref, not a value read from origin"
fi
echo "PASS: pr.sh forces only through --force-with-lease=<ref>:<sha> over a value it read first (#2103)"

# --- push: the force is gated on the SUPERSEDE probe, not on the lease alone ----
# The second static floor, under the collision block above. The lease floor
# immediately above proves every force is leased; it cannot tell whether the
# force was allowed to be ISSUED in the first place. A future edit that deletes
# the patch-equivalence gate and goes straight from "not an ancestor" to a leased
# force passes every fixture that exercises a superseded remote — and silently
# restores the overwrite. The probe is spelled here exactly as the rescue path in
# build-level.mjs spells it, which is the symmetry review round 2 required.
grep -q -- '--cherry-pick --right-only --no-merges' "$SCRIPT" \
  || fail "#2103: cmd_push must gate a requested rewrite on the patch-equivalence supersede probe (git cherry's own test), not on the lease alone"
echo "PASS: a requested rewrite is gated on the supersede probe, symmetric with the rescue push (#2103)"

# --- push: the supersede gate carries BOTH oracles, at both sites (#2095) --------
# The functional blocks above prove the behaviour; this is the static floor under
# them. Patch-equivalence alone cannot distinguish a genuine drop from a rebase,
# and a future edit that removes the content-containment cross-check restores a
# refusal on the pipeline's COMMON path while every #2103 fixture still passes.
# The rescue push in build-level.mjs must carry the same second oracle for the
# same reason — the asymmetry between the two push sites is exactly what
# temperloop#2103 review round 2 caught, and it must not re-open here.
grep -q 'merge-tree --write-tree' "$SCRIPT" \
  || fail "#2095: cmd_push must cross-check a non-zero patch-equivalence count against the content-containment oracle (merge-tree --write-tree), or a rebase reads as a dropped commit"
grep -q 'content_superseded()' "$SCRIPT" \
  || fail "#2095: pr.sh must define content_superseded() — the one place the containment oracle's tri-state (yes/no/unknown) is decided"
MJS_PRESERVE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)/claude/workflows/build-level.mjs"
if [ -f "$MJS_PRESERVE" ]; then
  awk '/^function preserveCommittedWorkCmd\(/,/^}$/' "$MJS_PRESERVE" | grep 'merge-tree --write-tree' >/dev/null \
    || fail "#2095: build-level.mjs's rescue push must carry the SAME content-containment oracle — an escalated, already-rebased item would otherwise report WORK_PRESERVE_FAILED over fully superseded work"
fi
echo "PASS: both push sites cross-check patch-equivalence against content containment (#2095)"

# --- push: the open-PR survey (temperloop#1688) -----------------------------------
# The live 2026-08-21 shape: the worktree's local branch is `build/<slug>` while
# the PR was opened on `fix/<slug>`, so a rebase-and-re-push aimed at the obvious
# `build/<slug>` lands a SECOND remote ref that no PR watches. The push is
# truthful and useless; the only downstream symptom is a PR head that looks
# "stale", which reads as GitHub's post-force-push lag. Every case below is
# stubbed at `gh` — no network, deterministic listings.
#
# Stub grammar: $GH_SURVEY_JSON is the `gh pr list --state open` listing; a call
# carrying `--head` (pr.sh's authoritative confirm) answers from that same
# listing filtered to the requested ref, so the stub can never disagree with
# itself the way two hand-written fixtures could.
mkdir -p "$TMP/bin-survey"
cat > "$TMP/bin-survey/gh" <<'EOF'
#!/usr/bin/env bash
head_ref=""; want_head=0
for a in "$@"; do
  if [ "$want_head" = 1 ]; then head_ref="$a"; want_head=0; continue; fi
  [ "$a" = "--head" ] && want_head=1
done
if [ -n "$head_ref" ]; then
  jq -c --arg h "$head_ref" 'map(select(.headRefName == $h))' <<<"${GH_SURVEY_JSON:?}"
else
  printf '%s\n' "${GH_SURVEY_JSON:?}"
fi
EOF
chmod +x "$TMP/bin-survey/gh"

git -C "$REPO" fetch -q origin
git -C "$REPO" checkout -q -b "build/env-reconcile-1404" origin/main
git -C "$REPO" commit -q --allow-empty -m "rebased worker commit"
wt_sha="$(git -C "$REPO" rev-parse HEAD)"

# THE REGRESSION CASE. PR #1404 is open on fix/env-reconcile-1404; the re-push
# aims at build/env-reconcile-1404. Must REPORT, not proceed.
PR_ON_FIX='[{"number":1404,"url":"https://github.com/Towheads/temperloop/pull/1404","headRefName":"fix/env-reconcile-1404"}]'
rc=0
out="$(GH_SURVEY_JSON="$PR_ON_FIX" PATH="$TMP/bin-survey:$PATH" \
       bash "$SCRIPT" push "$REPO" "build/env-reconcile-1404" --force)" || rc=$?
[ "$rc" -ne 0 ] || fail "a push onto a ref no open PR watches must exit non-zero (got: $out)"
[ "$(jq -r .outcome <<<"$out")" = "PUSHED_UNWATCHED" ] \
  || fail "build/<slug> push while the PR is on fix/<slug> must be PUSHED_UNWATCHED (got: $out)"
[ "$(jq -r .branch <<<"$out")" = "build/env-reconcile-1404" ] \
  || fail "PUSHED_UNWATCHED must name the ref actually pushed (got: $out)"
[ "$(jq -r .pr_number <<<"$out")" = "1404" ] \
  || fail "PUSHED_UNWATCHED must name the PR that is NOT watching (got: $out)"
[ "$(jq -r .pr_head_ref <<<"$out")" = "fix/env-reconcile-1404" ] \
  || fail "PUSHED_UNWATCHED must name the ref the PR DOES track (got: $out)"
[ "$(jq -r .sha <<<"$out")" = "$wt_sha" ] || fail "PUSHED_UNWATCHED sha mismatch (got: $out)"
# The push still LANDED — this is a report about where it landed, not a failure
# to land, and a caller must not re-push believing nothing happened.
[ "$(git -C "$BARE" rev-parse refs/heads/build/env-reconcile-1404)" = "$wt_sha" ] \
  || fail "PUSHED_UNWATCHED must still have placed the branch (the push DID succeed)"
# Criterion 2 — the two meanings must be TOLD APART, not merely flagged. The
# machine-readable cause says which one this is, and the message names both refs
# plus the discriminating fact (lag keeps the SAME ref).
[ "$(jq -r .stale_head_cause <<<"$out")" = "branch-mismatch" ] \
  || fail "PUSHED_UNWATCHED must classify the stale-head cause as branch-mismatch (got: $out)"
msg="$(jq -r .error <<<"$out")"
grep -q 'build/env-reconcile-1404' <<<"$msg" || fail "message omits the pushed ref (got: $msg)"
grep -q 'fix/env-reconcile-1404'   <<<"$msg" || fail "message omits the PR's ref (got: $msg)"
grep -qi 'not GitHub'              <<<"$msg" || fail "message does not rule out the GitHub lag (got: $msg)"
grep -qi 'SAME ref'                <<<"$msg" || fail "message does not state what lag looks like instead (got: $msg)"
echo "PASS: push onto a ref no open PR watches → PUSHED_UNWATCHED + non-zero, both refs named, cause classified"

# CONTROL — genuine GitHub post-force-push head lag. Same visible symptom (the
# PR's head looks stale), but the PR's head REF *is* the ref just pushed, so the
# push reached it and the lag converges on its own. Must stay a plain PUSHED:
# this is the case a naive "PR head looks stale" warning would collapse into the
# one above, reproducing the original misdiagnosis.
PR_ON_SAME='[{"number":1404,"url":"https://github.com/Towheads/temperloop/pull/1404","headRefName":"build/env-reconcile-1404"}]'
rc=0
out="$(GH_SURVEY_JSON="$PR_ON_SAME" PATH="$TMP/bin-survey:$PATH" \
       bash "$SCRIPT" push "$REPO" "build/env-reconcile-1404" --force)" || rc=$?
[ "$rc" -eq 0 ] \
  || fail "genuine GitHub head lag must NOT be reported — the two causes are collapsed (got: $out)"
[ "$(jq -r .outcome <<<"$out")" = "PUSHED" ] \
  || fail "a PR whose head REF matches the pushed ref is GitHub lag at worst — must stay PUSHED (got: $out)"
[ "$(jq -r .pr_number <<<"$out")" = "1404" ] \
  || fail "PUSHED must still name the PR watching the ref (got: $out)"
[ "$(jq -r .stale_head_cause <<<"$out")" = "null" ] \
  || fail "the benign lag case must carry no stale_head_cause (got: $out)"
echo "PASS: a PR on the SAME head ref (genuine GitHub head lag) stays PUSHED — the two causes are not collapsed"

# CONTROL — the ordinary build-level.mjs first push: 3f-1 pushes, 3f-2 opens the
# PR, so no PR references the ref yet and none exists elsewhere for the slug.
# This is the path the check must never break.
rc=0
out="$(GH_SURVEY_JSON='[]' PATH="$TMP/bin-survey:$PATH" \
       bash "$SCRIPT" push "$REPO" "fix/first-push-1688")" || rc=$?
[ "$rc" -eq 0 ] || fail "the normal build-level.mjs first push must not be reported (got: $out)"
[ "$(jq -r .outcome <<<"$out")" = "PUSHED" ] \
  || fail "the normal pre-PR first push must stay PUSHED (got: $out)"
[ "$(jq -r .pr_lookup <<<"$out")" = "ok" ] || fail "first push should report a successful lookup (got: $out)"
[ "$(jq -r .pr_number <<<"$out")" = "null" ] || fail "first push has no PR yet (got: $out)"
echo "PASS: the normal push-then-open-PR path (no PR anywhere yet) stays PUSHED"

# CONTROL — an unrelated open PR on a different slug is not a sibling.
PR_OTHER='[{"number":99,"url":"u","headRefName":"fix/some-other-slug-1"}]'
rc=0
out="$(GH_SURVEY_JSON="$PR_OTHER" PATH="$TMP/bin-survey:$PATH" \
       bash "$SCRIPT" push "$REPO" "fix/first-push-1688" --force)" || rc=$?
[ "$rc" -eq 0 ] || fail "an unrelated slug must not be reported (got: $out)"
[ "$(jq -r .outcome <<<"$out")" = "PUSHED" ] \
  || fail "an unrelated PR on another slug must not trip the survey (got: $out)"
echo "PASS: an open PR on an unrelated slug does not trip the survey"

# CONTROL — fail-soft. An erroring `gh` cannot OBSERVE the split, and a push that
# already succeeded must never be turned into a failure by an inability to look.
out="$(PATH="$NOGH:$PATH" bash "$SCRIPT" push "$REPO" "build/env-reconcile-1404" --force)"
[ "$(jq -r .outcome <<<"$out")" = "PUSHED" ] \
  || fail "an erroring gh must degrade to PUSHED, not fail the push (got: $out)"
[ "$(jq -r .pr_lookup <<<"$out")" = "unavailable" ] \
  || fail "an erroring gh must be reported as pr_lookup:unavailable (got: $out)"
echo "PASS: push survey degrades fail-soft when gh errors (PUSHED, pr_lookup:unavailable)"

# CONTROL — a match outside the bounded listing. The survey lists at most 100
# open PRs, so on a busy repo the real match can fall outside the window while a
# sibling sits inside it. The authoritative `--head` confirm resolves it, and no
# split is reported. Stub: the listing shows only the sibling; the --head lookup
# is answered from a listing that DOES contain the match.
cat > "$TMP/bin-survey/gh" <<'EOF'
#!/usr/bin/env bash
head_ref=""; want_head=0
for a in "$@"; do
  if [ "$want_head" = 1 ]; then head_ref="$a"; want_head=0; continue; fi
  [ "$a" = "--head" ] && want_head=1
done
if [ -n "$head_ref" ]; then
  jq -c --arg h "$head_ref" 'map(select(.headRefName == $h))' <<<"${GH_HEAD_JSON:?}"
else
  printf '%s\n' "${GH_SURVEY_JSON:?}"
fi
EOF
chmod +x "$TMP/bin-survey/gh"
rc=0
out="$(GH_SURVEY_JSON="$PR_ON_FIX" \
       GH_HEAD_JSON='[{"number":1500,"url":"u","headRefName":"build/env-reconcile-1404"}]' \
       PATH="$TMP/bin-survey:$PATH" bash "$SCRIPT" push "$REPO" "build/env-reconcile-1404" --force)" || rc=$?
[ "$rc" -eq 0 ] || fail "a --head-confirmed match must not be reported (got: $out)"
[ "$(jq -r .outcome <<<"$out")" = "PUSHED" ] \
  || fail "a match found only by the --head confirm must NOT be reported as a split (got: $out)"
[ "$(jq -r .pr_number <<<"$out")" = "1500" ] \
  || fail "the confirm's PR number must be adopted (got: $out)"
echo "PASS: a real match outside the bounded listing is recovered by the --head confirm, not reported"

# --- open --body-only: per-entry bare Closes + full 3f body shape ----------------
cat > "$TMP/verdict.json" <<'EOF'
{
  "status": "done",
  "summary": "Implements the widget renderer behind the existing seam.",
  "acceptance_results": [
    {"criterion": "widget renders", "passed": true, "evidence": "test_widget.py::test_render green"},
    {"criterion": "legacy path unchanged", "passed": false, "evidence": "one diff remains"}
  ],
  "verification_surface": "Before: 0 widgets rendered.\nAfter: 3 widgets rendered."
}
EOF
body="$(bash "$SCRIPT" open --verdict "$TMP/verdict.json" \
  --gh-issue 278 --also-closes 171 \
  --plan-link "Plans/2026-06-09 foundation - machinery#machinery-pr-open" \
  --source "epic #253, spike #245 verdict" --body-only)"
# Per-entry bare emission: exactly the two lines, each on its own line.
[ "$(grep -c '^Closes #' <<<"$body")" -eq 2 ] || fail "expected exactly 2 Closes lines (body: $body)"
grep -qx 'Closes #278' <<<"$body" || fail "missing bare 'Closes #278' on its own line"
grep -qx 'Closes #171' <<<"$body" || fail "missing bare 'Closes #171' on its own line"
grep -q 'Closes #278 and' <<<"$body" && fail "Closes lines combined — closes only #278"
grep -q '`Closes' <<<"$body" && fail "backticked Closes — GitHub ignores it (ec8d5fd class)"
# Acceptance recap with passed/evidence.
grep -qF '## Acceptance' <<<"$body" || fail "missing acceptance recap heading"
# temperloop#1267: evidence rides its OWN nested line, never an inline ` — `.
grep -qxF -- '- [x] widget renders' <<<"$body" \
  || fail "missing passed recap line"
grep -qxF -- '      — test_widget.py::test_render green' <<<"$body" \
  || fail "passed entry's evidence is not on its own nested line (body: $body)"
grep -qxF -- '- [ ] legacy path unchanged' <<<"$body" \
  || fail "missing failed recap line"
grep -qxF -- '      — one diff remains' <<<"$body" \
  || fail "failed entry's evidence is not on its own nested line (body: $body)"
grep -q -- '] widget renders — ' <<<"$body" \
  && fail "evidence re-inlined after a bare em-dash — the temperloop#1267 defect (body: $body)"
# No .discrimination_evidence on either entry above → no stray "discrimination:" line.
grep -q 'discrimination:' <<<"$body" \
  && fail "recap emitted a stray discrimination: line for entries with no .discrimination_evidence (body: $body)"
# Verification section = the worker's verification_surface.
grep -qF '## Verification' <<<"$body" || fail "missing ## Verification"
grep -qF 'After: 3 widgets rendered.' <<<"$body" || fail "verification_surface not in body"
# Backlinks + footer.
grep -qxF 'Tracked in: [[Plans/2026-06-09 foundation - machinery#machinery-pr-open]]' <<<"$body" \
  || fail "missing Tracked in backlink"
grep -qxF 'Derived from: epic #253, spike #245 verdict' <<<"$body" \
  || fail "missing Derived from source ref"
grep -qxF '🤖 Generated with [Claude Code](https://claude.com/claude-code)' <<<"$body" \
  || fail "missing Claude Code footer"
echo "PASS: open --body-only emits per-entry bare Closes + recap + Verification + backlinks + footer"

# --- open --body-only: .discrimination_evidence reaches the recap (temperloop#1319) ---
# The whole point of #1319: a jq filter that reads only .passed/.criterion/.evidence
# would silently DROP a worker-reported .discrimination_evidence field instead of
# surfacing it to the PR's human reviewer. This proves it survives end to end.
cat > "$TMP/verdict-discrim.json" <<'EOF'
{
  "status": "done",
  "summary": "Adds a guard that rejects an out-of-worktree write.",
  "acceptance_results": [
    {"criterion": "guard rejects out-of-worktree writes", "passed": true, "evidence": "test_guard.sh::test_reject green", "discrimination_evidence": "Removed the path-prefix check at build-worktree-guard.sh:42 -> test_guard.sh RED (1 failed); restored -> GREEN (12 passed)."}
  ],
  "verification_surface": "Before: guard allowed any path.\nAfter: guard rejects paths outside the worktree."
}
EOF
body="$(bash "$SCRIPT" open --verdict "$TMP/verdict-discrim.json" --gh-issue 1319 --body-only)"
grep -qF '## Acceptance' <<<"$body" || fail "discrimination-evidence fixture missing ## Acceptance heading"
grep -qxF -- '- [x] guard rejects out-of-worktree writes' <<<"$body" \
  || fail "discrimination-evidence fixture missing the base recap line (body: $body)"
grep -qxF -- '      — test_guard.sh::test_reject green' <<<"$body" \
  || fail "discrimination-evidence fixture: evidence not on its own nested line (body: $body)"
grep -qF 'discrimination: Removed the path-prefix check at build-worktree-guard.sh:42 -> test_guard.sh RED (1 failed); restored -> GREEN (12 passed).' <<<"$body" \
  || fail "recap dropped .discrimination_evidence — a jq filter reading only .passed/.criterion/.evidence silently drops this field (body: $body)"
echo "PASS: open --body-only surfaces .discrimination_evidence in the acceptance recap (temperloop#1319)"

# --- open --body-only: .deferred_host_config reaches the recap (temperloop#1182) ---
# A host-config deferral rides `passed: false` (the worker did NOT confirm it) plus
# the `deferred_host_config` marker. Read only .passed and the recap renders it as a
# bare unchecked box — visually identical to "the worker failed this criterion", the
# exact misreading this field exists to prevent. The DEFERRED line must survive.
cat > "$TMP/verdict-hostcfg.json" <<'EOF'
{
  "status": "done",
  "summary": "Wires the retro-judge spawn to the host credential seam.",
  "acceptance_results": [
    {"criterion": "pipeline-retro-judge-spawn.sh --dry-run reports credential_present", "passed": false, "evidence": "not observable from a worktree", "deferred_host_config": "workflows/scripts/build/build.config.local.sh (SENTRY_AUTH_TOKEN)"},
    {"criterion": "the spawn script reads the credential from config", "passed": true, "evidence": "test_pipeline_retro_judge_spawn.sh green"}
  ],
  "verification_surface": "Before: no credential seam.\nAfter: the spawn sources build.config.local.sh."
}
EOF
body="$(bash "$SCRIPT" open --verdict "$TMP/verdict-hostcfg.json" --gh-issue 1182 --body-only)"
grep -qF -- '- [ ] pipeline-retro-judge-spawn.sh --dry-run reports credential_present' <<<"$body" \
  || fail "host-config fixture missing the base recap line for the deferred criterion (body: $body)"
grep -qF 'DEFERRED — host-config `workflows/scripts/build/build.config.local.sh (SENTRY_AUTH_TOKEN)` is invisible from a worktree; verified parent-side (temperloop#1182)' <<<"$body" \
  || fail "recap dropped .deferred_host_config — an unchecked box then reads as a worker FAILURE rather than a criterion nobody could check worktree-side (body: $body)"
# A non-deferred entry must not pick up a stray DEFERRED line.
[ "$(grep -c 'DEFERRED — host-config' <<<"$body")" -eq 1 ] \
  || fail "expected exactly one DEFERRED line — the marker leaked onto an entry with no .deferred_host_config (body: $body)"
echo "PASS: open --body-only surfaces .deferred_host_config in the acceptance recap (temperloop#1182)"

# --- acceptance recap round-trips through ` — ` (temperloop#1267) ----------------
# The PR body is the ONLY durable verbatim record of the acceptance bullets a
# worker was handed. With evidence appended inline after a bare ` — ` that record
# was not parseable: ` — ` occurs inside real criteria (a first-occurrence split
# silently TRUNCATES the criterion — the live #1201 bullet-3 case, where the
# dropped clause was the anti-over-exclusion guard) and inside real evidence (a
# last-occurrence split then eats the evidence tail). Neither rule is right, and
# nothing picks between them. Evidence on its OWN nested line makes the split
# positional, and `pr.sh acceptance-extract` is the heuristic-free inverse.
#
# The fixture below is deliberately the hard shape: BOTH fields carry ` — `,
# one criterion spans several lines, and one entry has no evidence at all.
cat > "$TMP/verdict-emdash.json" <<'EOF'
{
  "status": "done",
  "summary": "Round-trip fixture.",
  "acceptance_results": [
    {"criterion": "A genuine user turn that merely FOLLOWS a command invocation is NOT over-excluded — guard the rule to the single adjacent expansion turn", "passed": true, "evidence": "test_scan_stub.sh 3c(a) — four-turn fixture yields exactly 1 match"},
    {"criterion": "a criterion that spans\nseveral lines — with an em-dash on the last", "passed": false, "evidence": "ev — with — several — dashes", "deferred_host_config": "build.config.local.sh (TOKEN)", "discrimination_evidence": "removed the guard — RED; restored — GREEN"},
    {"criterion": "an entry with no evidence at all — still fine", "passed": true}
  ],
  "verification_surface": "## Acceptance\n- [x] a decoy bullet inside the worker's own surface — must never be re-parsed"
}
EOF
bash "$SCRIPT" open --verdict "$TMP/verdict-emdash.json" --gh-issue 1267 --body-only > "$TMP/body-emdash.md"
# Byte-exact round-trip: extract → compare against the verdict's own entries.
# `passed` plus the four optional fields, nulls dropped so an absent field and a
# null one compare equal.
jq -S '.acceptance_results
       | map({passed, criterion, evidence, deferred_host_config, discrimination_evidence}
             | with_entries(select(.value != null)))' \
   "$TMP/verdict-emdash.json" > "$TMP/rt-want.json"
bash "$SCRIPT" acceptance-extract "$TMP/body-emdash.md" \
  | jq -S 'map(with_entries(select(.value != null)))' > "$TMP/rt-got.json"
diff -u "$TMP/rt-want.json" "$TMP/rt-got.json" \
  || fail "acceptance recap did not round-trip byte-exactly (want/got above)"
# Both halves of the acceptance, named so a regression says which one broke.
jq -e '.[0].criterion | endswith("single adjacent expansion turn")' "$TMP/rt-got.json" >/dev/null \
  || fail "criterion containing ' — ' was TRUNCATED on extract (temperloop#1267 first-occurrence split)"
jq -e '.[1].evidence == "ev — with — several — dashes"' "$TMP/rt-got.json" >/dev/null \
  || fail "evidence containing ' — ' was truncated on extract (last-occurrence split)"
jq -e '.[1].criterion == "a criterion that spans\nseveral lines — with an em-dash on the last"' "$TMP/rt-got.json" >/dev/null \
  || fail "a multi-line criterion lost its continuation lines on extract"
jq -e '.[2].evidence == null' "$TMP/rt-got.json" >/dev/null \
  || fail "an entry with no evidence invented one on extract"
# The worker surface's own `## Acceptance` heading must not re-open the section.
[ "$(jq 'length' "$TMP/rt-got.json")" -eq 3 ] \
  || fail "extract re-parsed a decoy '## Acceptance' inside the verification surface"
# stdin (`-`) is the same extractor.
bash "$SCRIPT" acceptance-extract - < "$TMP/body-emdash.md" \
  | jq -S 'map(with_entries(select(.value != null)))' > "$TMP/rt-stdin.json"
diff -q "$TMP/rt-got.json" "$TMP/rt-stdin.json" >/dev/null \
  || fail "acceptance-extract - (stdin) disagreed with the file path form"
echo "PASS: acceptance recap round-trips byte-exactly with ' — ' in BOTH criterion and evidence (temperloop#1267)"

# A body with no ## Acceptance section extracts to an empty array, not an error.
printf '%s\n' 'just a summary' > "$TMP/body-noacc.md"
[ "$(bash "$SCRIPT" acceptance-extract "$TMP/body-noacc.md")" = "[]" ] \
  || fail "acceptance-extract on a body with no ## Acceptance section did not return []"
rc=0; out="$(bash "$SCRIPT" acceptance-extract "$TMP/nonexistent-body.md" 2>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] && [ "$(jq -r .outcome <<<"$out")" = "ERROR" ] \
  || fail "acceptance-extract on a missing path not structured ERROR (got: $out)"
echo "PASS: acceptance-extract returns [] for a recap-less body and structured ERROR for a missing path"

# --- open --body-only: multiple also_closes, comma-separated ---------------------
body="$(bash "$SCRIPT" open --verdict "$TMP/verdict.json" \
  --gh-issue 278 --also-closes 171,205 --body-only)"
[ "$(grep -c '^Closes #' <<<"$body")" -eq 3 ] || fail "expected 3 Closes lines (body: $body)"
grep -qx 'Closes #205' <<<"$body" || fail "missing 'Closes #205'"
echo "PASS: open emits one bare Closes line per also_closes entry (comma list)"

# --- open --body-only: cross-repo repo: honor point — owner/repo#N (RED/GREEN) ----
# GREEN: a fully-qualified owner/repo#N gh_issue/also_closes ref is accepted and
# emitted as `Closes owner/repo#N` (not bare `Closes #N` — a bare close is
# same-repo only, plan-schema.md § Optional repo: field).
body="$(bash "$SCRIPT" open --verdict "$TMP/verdict.json" \
  --gh-issue acme/widgets#42 --also-closes acme/widgets#43 --body-only)"
grep -qxF 'Closes acme/widgets#42' <<<"$body" \
  || fail "missing qualified 'Closes acme/widgets#42' (body: $body)"
grep -qxF 'Closes acme/widgets#43' <<<"$body" \
  || fail "missing qualified 'Closes acme/widgets#43' (body: $body)"
grep -q '^Closes #' <<<"$body" && fail "qualified ref must not also emit a bare 'Closes #N' (body: $body)"
echo "PASS: open emits Closes owner/repo#N for a qualified cross-repo gh_issue/also_closes ref"

# RED: a malformed issue ref (neither plain digits nor owner/repo#N) is rejected.
rc=0
out="$(bash "$SCRIPT" open --verdict "$TMP/verdict.json" --gh-issue not-a-ref --body-only 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "malformed --gh-issue 'not-a-ref' did not exit non-zero (out: $out)"
grep -qi 'invalid' <<<"$out" || fail "malformed --gh-issue error missing 'invalid' (out: $out)"
echo "PASS: open rejects a malformed --gh-issue ref (neither digits nor owner/repo#N)"

# --- open --body-only: no verification_surface → fall back to the recap ----------
jq 'del(.verification_surface)' "$TMP/verdict.json" > "$TMP/verdict-nosurface.json"
body="$(bash "$SCRIPT" open --verdict "$TMP/verdict-nosurface.json" --gh-issue 278 --body-only)"
grep -qF '## Verification' <<<"$body" || fail "fallback body missing ## Verification"
# The recap appears twice: once under ## Acceptance, once as the fallback surface.
[ "$(grep -cxF -- '- [x] widget renders' <<<"$body")" -eq 2 ] \
  || fail "fallback did not reuse the acceptance recap under ## Verification (body: $body)"
echo "PASS: open falls back to the acceptance recap only when verification_surface is absent"

# --- open: verification surface by file-ref (#418 inflow-cut) ---------------------
# The worker writes its surface to a file and returns ONLY the path (keeping the
# block out of orchestrator context); the assembled body must be byte-identical
# to the inline-field path. Both the verdict `.verification_surface_path` key and
# the explicit --verification-surface-file flag are exercised.
printf '%s\n' "Before: 0 widgets rendered." "After: 3 widgets rendered." > "$TMP/surface.md"
inline_body="$(bash "$SCRIPT" open --verdict "$TMP/verdict.json" --gh-issue 278 --also-closes 171 \
  --plan-link "Plans/2026-06-09 foundation - machinery#machinery-pr-open" --source "epic #253" --body-only)"
# (a) verdict carries .verification_surface_path instead of the inline field
jq --arg p "$TMP/surface.md" 'del(.verification_surface) | .verification_surface_path=$p' \
  "$TMP/verdict.json" > "$TMP/verdict-pathref.json"
pathref_body="$(bash "$SCRIPT" open --verdict "$TMP/verdict-pathref.json" --gh-issue 278 --also-closes 171 \
  --plan-link "Plans/2026-06-09 foundation - machinery#machinery-pr-open" --source "epic #253" --body-only)"
[ "$pathref_body" = "$inline_body" ] || fail "path-key body not byte-identical to inline body"
# (b) --verification-surface-file flag, verdict has neither surface field
flag_body="$(bash "$SCRIPT" open --verdict "$TMP/verdict-nosurface.json" --gh-issue 278 --also-closes 171 \
  --plan-link "Plans/2026-06-09 foundation - machinery#machinery-pr-open" --source "epic #253" \
  --verification-surface-file "$TMP/surface.md" --body-only)"
[ "$flag_body" = "$inline_body" ] || fail "--verification-surface-file body not byte-identical to inline body"
echo "PASS: verification surface by file-ref (path key + flag) == inline body, byte-identical"

# --- open: --verification-surface-file precedence over the inline field -----------
printf 'FROM FILE\n' > "$TMP/surface2.md"
out_body="$(bash "$SCRIPT" open --verdict "$TMP/verdict.json" --gh-issue 1 \
  --verification-surface-file "$TMP/surface2.md" --body-only)"
grep -qF 'FROM FILE' <<<"$out_body" || fail "flag did not override inline surface"
grep -qF 'After: 3 widgets rendered.' <<<"$out_body" && fail "inline surface leaked when flag given"
echo "PASS: --verification-surface-file takes precedence over the inline verification_surface field"

# --- open: a given-but-missing surface file → structured ERROR --------------------
rc=0; out="$(bash "$SCRIPT" open --verdict "$TMP/verdict.json" --gh-issue 1 \
  --verification-surface-file "$TMP/does-not-exist.md" --body-only 2>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] && [ "$(jq -r .outcome <<<"$out")" = "ERROR" ] \
  || fail "missing --verification-surface-file not structured ERROR (got: $out)"
jq --arg p "$TMP/nope.md" 'del(.verification_surface) | .verification_surface_path=$p' \
  "$TMP/verdict.json" > "$TMP/verdict-pathref-missing.json"
rc=0; out="$(bash "$SCRIPT" open --verdict "$TMP/verdict-pathref-missing.json" --gh-issue 1 --body-only 2>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] && [ "$(jq -r .outcome <<<"$out")" = "ERROR" ] \
  || fail "missing .verification_surface_path file not structured ERROR (got: $out)"
echo "PASS: a given-but-missing surface file (flag or path key) → structured ERROR + non-zero exit"

# --- open: the worker's own Closes block is stripped from the surface (#1023) ------
# Observed on temperloop PR #1019: the worker copied pr.sh's linkage block into
# its own .build-verification.md, so the assembled body carried it TWICE. Linkage
# lives in pr.sh alone, so `open` strips a bare closing-keyword LINE out of the
# spliced surface. Assertions below compare the ## Verification window byte-for-
# byte against the expected surface, so a strip that mangles anything else fails.
#
# verif_window N — the N lines of $body that follow the '## Verification' heading.
verif_window() {
  local n="$1" ln
  ln="$(grep -n '^## Verification$' <<<"$body" | head -1 | cut -d: -f1)"
  [ -n "$ln" ] || fail "assembled body has no ## Verification heading"
  sed -n "$((ln + 1)),$((ln + n))p" <<<"$body"
}

cat > "$TMP/surface-dup.md" <<'MD'
Closes #278
Closes Towheads/foundation#171

## What changed
The widget renderer now paints 3 widgets.
MD
cat > "$TMP/surface-dup-expected.md" <<'MD'

## What changed
The widget renderer now paints 3 widgets.
MD
body="$(bash "$SCRIPT" open --verdict "$TMP/verdict-nosurface.json" \
  --gh-issue 278 --also-closes Towheads/foundation#171 \
  --verification-surface-file "$TMP/surface-dup.md" --body-only)"
[ "$(grep -c '^Closes ' <<<"$body")" -eq 2 ] \
  || fail "duplicate linkage survived — expected exactly 2 Closes lines (body: $body)"
grep -qx 'Closes #278' <<<"$body" || fail "pr.sh's own bare 'Closes #278' missing after strip"
grep -qx 'Closes Towheads/foundation#171' <<<"$body" \
  || fail "pr.sh's own qualified 'Closes Towheads/foundation#171' missing after strip"
[ "$(verif_window "$(wc -l < "$TMP/surface-dup-expected.md")")" = "$(cat "$TMP/surface-dup-expected.md")" ] \
  || fail "stripped surface not byte-identical to expected (body: $body)"
echo "PASS: open strips a worker-copied Closes block from the surface — one linkage block (#1023)"

# --- open: a surface with no HONORED closing-keyword line is untouched (#1023) -----
# The strip is deliberately narrow: only a WHOLE line that is nothing but
# `<keyword> #N` / `<keyword> owner/repo#N` — i.e. only what GitHub itself would
# honor AND what can only be a duplicate of pr.sh's emission. A mid-sentence
# mention, a backticked line, a 4-space-indented line and ANY line inside a
# fenced code block (a surface quoting an assembled body as its evidence) all
# survive byte-for-byte.
cat > "$TMP/surface-clean.md" <<'MD'
Before: 0 widgets rendered.

pr.sh emits Closes #279 near the top of the body, which is the single home.
`Closes #280`
    Closes #281

```text
Closes #282
Fixes Towheads/foundation#283
```
After: 3 widgets rendered.
MD
body="$(bash "$SCRIPT" open --verdict "$TMP/verdict-nosurface.json" --gh-issue 278 \
  --verification-surface-file "$TMP/surface-clean.md" --body-only)"
[ "$(verif_window "$(wc -l < "$TMP/surface-clean.md")")" = "$(cat "$TMP/surface-clean.md")" ] \
  || fail "keyword-free surface was modified (body: $body)"
for n in 279 280 281 282; do
  grep -qF "Closes #$n" <<<"$body" || fail "non-honored 'Closes #$n' was stripped (body: $body)"
done
grep -qF 'Fixes Towheads/foundation#283' <<<"$body" \
  || fail "fenced 'Fixes Towheads/foundation#283' was stripped (body: $body)"
# Two line-start `Closes ` lines: pr.sh's own, plus the one INSIDE the fenced
# block — which is exactly the proof the fence guard fired (a fence-blind strip
# would have eaten it and left 1).
[ "$(grep -c '^Closes ' <<<"$body")" -eq 2 ] \
  || fail "expected pr.sh's own Closes line + the fenced one (body: $body)"
echo "PASS: open leaves a surface with no honored closing-keyword line byte-identical (#1023)"

# --- open: stubbed gh → PR_OPENED with parsed number ------------------------------
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${GH_STUB_ARGS:?}"
echo "https://github.com/Towheads/foundation/pull/342"
EOF
chmod +x "$TMP/bin/gh"
out="$(GH_STUB_ARGS="$TMP/gh-args" PATH="$TMP/bin:$PATH" bash "$SCRIPT" open \
  --verdict "$TMP/verdict.json" --repo "$REPO" --branch feat/widget \
  --title "feat: widget renderer" --gh-issue 278 --also-closes 171 \
  --plan-link "Plans/2026-06-09 foundation - machinery#machinery-pr-open" \
  --source "epic #253")"
[ "$(jq -r .outcome <<<"$out")" = "PR_OPENED" ] || fail "open outcome (got: $out)"
[ "$(jq -r .pr_number <<<"$out")" = "342" ] || fail "pr_number not parsed (got: $out)"
grep -qx -- '--head' "$TMP/gh-args" || fail "gh not invoked with --head"
grep -qx 'feat/widget' "$TMP/gh-args" || fail "gh --head branch wrong"
grep -qx 'Closes #278' "$TMP/gh-args" || fail "assembled body (with Closes #278) not passed to gh"
grep -qx 'Closes #171' "$TMP/gh-args" || fail "assembled body (with Closes #171) not passed to gh"
[ "$(jq -r .surface_closes_stripped <<<"$out")" = "0" ] \
  || fail "surface_closes_stripped not 0 for a clean surface (got: $out)"
echo "PASS: open creates via gh with the assembled body → PR_OPENED {pr_number}"

# --- open: surface_closes_stripped reports the strip on the real outcome (#1023) ---
# The strip is otherwise invisible (it deletes worker-authored lines), so the
# count rides the structured outcome the .mjs logs — SPINE_OUTCOME_SCHEMA is
# `additionalProperties: true`, so this is a passthrough field, not a new outcome.
out="$(GH_STUB_ARGS="$TMP/gh-args-dup" PATH="$TMP/bin:$PATH" bash "$SCRIPT" open \
  --verdict "$TMP/verdict-nosurface.json" --repo "$REPO" --branch feat/widget \
  --title "feat: widget renderer" --gh-issue 278 --also-closes Towheads/foundation#171 \
  --verification-surface-file "$TMP/surface-dup.md")"
[ "$(jq -r .outcome <<<"$out")" = "PR_OPENED" ] || fail "dup-surface open outcome (got: $out)"
[ "$(jq -r .surface_closes_stripped <<<"$out")" = "2" ] \
  || fail "surface_closes_stripped did not report the 2 stripped lines (got: $out)"
[ "$(grep -c '^Closes ' "$TMP/gh-args-dup")" -eq 2 ] \
  || fail "body passed to gh still carries a duplicate linkage block"
echo "PASS: open reports surface_closes_stripped on PR_OPENED (#1023)"

# --- open: verdict on stdin -------------------------------------------------------
body="$(bash "$SCRIPT" open --verdict - --gh-issue 9 --body-only < "$TMP/verdict.json")"
grep -qx 'Closes #9' <<<"$body" || fail "stdin verdict not consumed"
echo "PASS: open accepts the verdict JSON on stdin (--verdict -)"

# --- open: EXISTS outcome when gh reports a PR already exists (#544) ---------------
# gh returns a non-zero exit with the "already exists" message — pr.sh must parse
# the PR number and URL and return {outcome:"EXISTS",...} (NOT ERROR/pr-open-failed).
mkdir -p "$TMP/bin-exists"
cat > "$TMP/bin-exists/gh" <<'EOF'
#!/usr/bin/env bash
# Simulate: gh pr create fails because a PR already exists
echo "a pull request for branch \"feat/widget\" into branch \"main\" already exists: https://github.com/Towheads/foundation/pull/163"
exit 1
EOF
chmod +x "$TMP/bin-exists/gh"
out="$(PATH="$TMP/bin-exists:$PATH" bash "$SCRIPT" open \
  --verdict "$TMP/verdict.json" --repo "$REPO" --branch feat/widget \
  --title "feat: widget renderer" --gh-issue 278)"
[ "$(jq -r .outcome <<<"$out")" = "EXISTS" ] \
  || fail "already-exists gh error not EXISTS (got: $out)"
[ "$(jq -r .pr_number <<<"$out")" = "163" ] \
  || fail "pr_number not parsed from already-exists message (got: $out)"
[ "$(jq -r .url <<<"$out")" = "https://github.com/Towheads/foundation/pull/163" ] \
  || fail "url not parsed from already-exists message (got: $out)"
echo "PASS: open returns EXISTS{pr_number,url} when gh reports a PR already exists (#544)"

# --- open --update-pr: re-render an existing PR's body via gh pr edit (#1846) -----
# The .mjs's 3g.5 re-render after a CI-fix re-review round. Must go through the
# SAME assemble_body path as create (same linkage lines, same surface handling)
# but invoke `gh pr edit <n> --body` and return BODY_UPDATED — never create.
mkdir -p "$TMP/bin-edit"
cat > "$TMP/bin-edit/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${GH_STUB_ARGS:?}"
EOF
chmod +x "$TMP/bin-edit/gh"
out="$(GH_STUB_ARGS="$TMP/gh-args-edit" PATH="$TMP/bin-edit:$PATH" bash "$SCRIPT" open \
  --verdict "$TMP/verdict.json" --repo "$REPO" --update-pr 342 \
  --gh-issue 278 --also-closes 171 \
  --plan-link "Plans/2026-06-09 foundation - machinery#machinery-pr-open" \
  --source "epic #253")"
[ "$(jq -r .outcome <<<"$out")" = "BODY_UPDATED" ] || fail "update-pr outcome (got: $out)"
[ "$(jq -r .pr_number <<<"$out")" = "342" ] || fail "update-pr pr_number (got: $out)"
[ "$(sed -n '1p' "$TMP/gh-args-edit")" = "pr" ] || fail "gh not invoked as pr edit (args: $(cat "$TMP/gh-args-edit"))"
[ "$(sed -n '2p' "$TMP/gh-args-edit")" = "edit" ] || fail "gh not invoked as pr edit (args: $(cat "$TMP/gh-args-edit"))"
[ "$(sed -n '3p' "$TMP/gh-args-edit")" = "342" ] || fail "gh pr edit not given the PR number"
grep -qx 'Closes #278' "$TMP/gh-args-edit" || fail "re-assembled body (Closes #278) not passed to gh pr edit"
grep -qx 'Closes #171' "$TMP/gh-args-edit" || fail "re-assembled body (Closes #171) not passed to gh pr edit"
# Byte-parity with create: the body handed to gh pr edit must equal --body-only's
# for the same inputs — the one-shared-code-path guarantee the arm exists for.
expected_body="$(bash "$SCRIPT" open --verdict "$TMP/verdict.json" --gh-issue 278 --also-closes 171 \
  --plan-link "Plans/2026-06-09 foundation - machinery#machinery-pr-open" --source "epic #253" --body-only)"
# gh-args holds: pr / edit / 342 / --body / <body> — the body is everything after --body.
actual_body="$(awk 'seen{print} $0=="--body"{seen=1}' "$TMP/gh-args-edit")"
[ "$actual_body" = "$expected_body" ] \
  || fail "update-pr body diverges from the shared assemble_body (--body-only) path"
rc=0; bash "$SCRIPT" open --verdict "$TMP/verdict.json" --update-pr 342 >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "update-pr without --repo must die"
rc=0; bash "$SCRIPT" open --verdict "$TMP/verdict.json" --repo "$REPO" --update-pr abc >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "update-pr with a non-numeric PR number must die"
echo "PASS: open --update-pr re-renders via gh pr edit → BODY_UPDATED (#1846)"

# --- open: the PR-body cap (temperloop#2009) --------------------------------------
# GitHub rejects a body over 65536 characters, and that rejection lands on
# `gh pr create` AFTER the worker, the reviewers, the gates and the push have all
# already succeeded. pr.sh must bound the body LOCALLY first. The cap is
# $BUILD_PR_BODY_MAX_BYTES; these cases drive it small (an env override beats
# build.config.sh's `:=`) rather than minting 60KB fixtures.
#
# Fixture: the `## Review notes` section is rendered by the REAL PRODUCER —
# reviewBodySuffix() in claude/workflows/build-level.mjs — never by a
# hand-written imitation of it. That is the load-bearing part of this fixture,
# and it is the third shape it has taken, because both earlier hand-written ones
# encoded an assumption the producer does not honour and stayed GREEN while the
# feature was broken:
#   - round 1: `### `-only blocks, a shape production never emits. The section
#     scan ended at the first reviewer's `## Summary`, rungs 1-3 no-opped, and
#     the blunt rung-4 head-cut dropped the acceptance recap, the
#     activation-proof evidence, the verification surface and the NEWEST round's
#     prose while KEEPING the oldest — every documented guarantee, inverted.
#   - round 2: every prose heading in the fixture carried spaces or brackets, so
#     none could spoof a block head. A bare single-word `### Notes` — which real
#     reviewer prose writes constantly — minted a phantom round and let rung 1
#     drop the genuine newest round's residual HIGH findings.
# Rendering through the producer removes that class: there is no second
# implementation of the block grammar left to drift. The reviewer TEXT is still
# written here, deliberately adversarially, because that half genuinely is
# untrusted input.
MJS="$(cd "$(dirname "$SCRIPT")/../../.." && pwd)/claude/workflows/build-level.mjs"
[ -f "$MJS" ] || fail "build-level.mjs not found at $MJS — the cap fixtures render through its reviewBodySuffix (#2009)"

# Render `## Review notes` exactly as production does. The .mjs is a Workflow
# runtime script, not an importable ESM (top-level `return`), so this simulates
# the runtime wrap the way test_workflow.sh's harness does — strip
# `export const meta`, wrap the body in an AsyncFunction — and swaps the final
# `return await buildLevel();` for a return of the renderer under test. Every
# failure path exits non-zero and FAILS the suite; it can never degrade into
# silently testing a hand-rolled shape.
render_review_suffix() { # $1 = rounds JSON file → the real reviewBodySuffix output
  MJS_PATH="$MJS" node -e '
    const { readFileSync } = require("fs");
    const src = readFileSync(process.env.MJS_PATH, "utf8").replace(/^export const meta/m, "const meta");
    const entry = "return await buildLevel();";
    if (!src.includes(entry)) { console.error("probe: entry line not found in build-level.mjs"); process.exit(3); }
    const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
    globalThis.args = "{}";
    (async () => {
      const api = await new AsyncFunction(src.replace(entry, "return { reviewBodySuffix };"))();
      if (typeof api.reviewBodySuffix !== "function") { console.error("probe: reviewBodySuffix not returned"); process.exit(3); }
      process.stdout.write(api.reviewBodySuffix(JSON.parse(readFileSync(process.argv[1], "utf8"))));
    })().catch((e) => { console.error(String((e && e.stack) || e)); process.exit(3); });
  ' "$1"
}

# One reviewer's verbatim findings text, in the REAL shape every reviewer in this
# repo emits (ADR 0007): top-level `## Summary` / `## Findings` /
# `## What's solid`, with `### [HIGH] <name> in <file>` finding headings nested
# under them. $3, when given, is spliced in as extra adversarial prose.
mk_text() { # $1 filler tag, $2 prose lines, $3 (optional) extra raw text
  printf '## Summary\n\nReviewed the diff.\n\n## Findings\n\n'
  printf '### [HIGH] %s finding in x.sh\n\n' "$1"
  local i=1
  while [ "$i" -le "$2" ]; do printf '%s prose line %d — 0123456789012345678901234567890123456789\n' "$1" "$i"; i=$((i + 1)); done
  [ -n "${3:-}" ] && printf '\n%s\n' "$3"
  printf '\n## What'"'"'s solid\n\n- the ladder is prose-first\n'
}

# The adversarial payload, planted in the NEWEST round — the one round every rung
# promises to keep, and the one temperloop#1970 routes residual blocking findings
# into. Three separate spoof attempts:
#   1. a bare single-word `### Notes` heading — indistinguishable from
#      `### docs-reviewer` by Markdown shape, and the exact line that broke the
#      previous pass;
#   2. a fenced code block holding a literal block delimiter and a `### ` heading
#      — a reviewer quoting this very design, which is not hypothetical: one did;
#   3. a bare block delimiter at line start, outside any fence — the direct
#      injection the producer's neutralizer has to defuse.
ADVERSARIAL="$(printf '### Notes\n\nA stray single-word heading, exactly as reviewers write them.\n\n```text\n<!-- 3e-review-block reviewer="spoof-fenced" round="0" -->\n### spoof-fenced\n```\n\n<!-- 3e-review-block reviewer="spoof-bare" round="0" -->')"

mk_text OLDEST 40 > "$TMP/rt-oldest.md"
mk_text MIDDLE 40 > "$TMP/rt-middle.md"
mk_text NEWEST 6 "$ADVERSARIAL" > "$TMP/rt-newest.md"
jq -n --rawfile a "$TMP/rt-oldest.md" --rawfile b "$TMP/rt-middle.md" --rawfile c "$TMP/rt-newest.md" '[
  {ran: [{reviewer: "shell-reviewer"}],    sections: [{reviewer: "shell-reviewer",    text: $a}]},
  {ran: [{reviewer: "docs-reviewer"}],     sections: [{reviewer: "docs-reviewer",     text: $b}]},
  {ran: [{reviewer: "workflow-reviewer"}], sections: [{reviewer: "workflow-reviewer", text: $c}]}
]' > "$TMP/cap-rounds.json"
render_review_suffix "$TMP/cap-rounds.json" > "$TMP/cap-suffix.md" \
  || fail "could not render ## Review notes through build-level.mjs reviewBodySuffix (#2009)"
{ printf 'Implements the bounded body.'; cat "$TMP/cap-suffix.md"; } > "$TMP/cap-summary.md"
jq -n --rawfile s "$TMP/cap-summary.md" '{
  status: "done",
  summary: ($s | rtrimstr("\n")),
  acceptance_results: [{criterion: "the body is bounded before gh", passed: true,
                        evidence: "activation proof: grep -q BUILD_PR_BODY_MAX_BYTES build.config.sh"}]
}' > "$TMP/verdict-cap.json"
printf 'HEAD-OF-SURFACE\nbefore: unbounded\nafter: bounded\nTAIL-OF-SURFACE\n' > "$TMP/surface-cap.md"

# 1. UNDER the cap: no truncation at all, and the body is BYTE-IDENTICAL to the
#    unbounded assembly (a huge cap = the identity path). A cap that quietly
#    rewrote a normal body would be a worse defect than the one being fixed.
under_default="$(bash "$SCRIPT" open --verdict "$TMP/verdict.json" --gh-issue 278 --also-closes 171 \
  --plan-link "Plans/p#i" --source "epic #253" \
  --verification-surface-file "$TMP/surface-cap.md" --body-only)"
under_huge="$(BUILD_PR_BODY_MAX_BYTES=4000000 bash "$SCRIPT" open --verdict "$TMP/verdict.json" \
  --gh-issue 278 --also-closes 171 --plan-link "Plans/p#i" --source "epic #253" \
  --verification-surface-file "$TMP/surface-cap.md" --body-only)"
[ "$under_default" = "$under_huge" ] \
  || fail "an under-cap body was not passed through byte-identically (#2009)"
grep -qF '[PR-body cap]' <<<"$under_default" \
  && fail "an under-cap body must carry no truncation marker (body: $under_default)"
out="$(GH_STUB_ARGS="$TMP/gh-args-undercap" PATH="$TMP/bin:$PATH" bash "$SCRIPT" open \
  --verdict "$TMP/verdict.json" --repo "$REPO" --branch feat/widget --title "t" \
  --gh-issue 278 --verification-surface-file "$TMP/surface-cap.md")"
[ "$(jq -r .body_truncated_bytes <<<"$out")" = "0" ] \
  || fail "body_truncated_bytes must be 0 for an under-cap body (got: $out)"
echo "PASS: open leaves an under-cap body byte-identical, unmarked, body_truncated_bytes=0 (#2009)"

# 2. OVER the cap: the outbound body — the one handed to `gh pr create`, not just
#    the preview — is within the cap. This is the whole item: a body over the cap
#    is truncated locally and never sent to be rejected by the API.
#
#    Every assertion below runs against the REAL reviewer shape mk_round now
#    emits, and together they are the documented guarantees: the acceptance recap
#    kept, activation-proof evidence kept, the verification surface kept, the
#    NEWEST round's prose kept, the OLDEST round's prose dropped. Under the
#    pre-fix `### `-only fixture every one of those read the other way.
cap=3000
out="$(BUILD_PR_BODY_MAX_BYTES="$cap" GH_STUB_ARGS="$TMP/gh-args-cap" PATH="$TMP/bin:$PATH" \
  bash "$SCRIPT" open --verdict "$TMP/verdict-cap.json" --repo "$REPO" --branch feat/widget \
  --title "feat: bounded body" --gh-issue 2009 --also-closes 1958 \
  --plan-link "Plans/p#i" --source "epic #2009" \
  --verification-surface-file "$TMP/surface-cap.md")"
[ "$(jq -r .outcome <<<"$out")" = "PR_OPENED" ] || fail "over-cap open outcome (got: $out)"
sent="$(awk 'seen{print} $0=="--body"{seen=1}' "$TMP/gh-args-cap")"
sent_bytes="$(LC_ALL=C printf %s "$sent" | wc -c | tr -d ' ')"
[ "$sent_bytes" -le "$cap" ] \
  || fail "the body handed to gh is $sent_bytes bytes, over the $cap-byte cap (#2009)"
[ "$(jq -r .body_truncated_bytes <<<"$out")" -gt 0 ] \
  || fail "body_truncated_bytes must report the cut (got: $out)"
# Oldest review round first: the earliest round's prose goes, the newest stays.
grep -qF 'OLDEST prose line' <<<"$sent" \
  && fail "the OLDEST review round's prose survived while newer prose was cut (#2009)"
grep -qF 'NEWEST prose line' <<<"$sent" \
  || fail "the NEWEST review round's prose was dropped — truncation ran newest-first (#2009)"
# Never dropped: linkage, the acceptance recap (where activation-proof evidence
# rides), the verification surface, the §3e `ran:` line, the footer.
grep -qx 'Closes #2009' <<<"$sent" || fail "the Closes linkage line was truncated away (#2009)"
grep -qx 'Closes #1958' <<<"$sent" || fail "an also-closes linkage line was truncated away (#2009)"
grep -qF '## Acceptance' <<<"$sent" || fail "the acceptance recap was truncated away (#2009)"
grep -qF 'activation proof:' <<<"$sent" || fail "the activation proof evidence was truncated away (#2009)"
grep -qF '## Verification' <<<"$sent" || fail "the verification section was truncated away (#2009)"
grep -qF 'HEAD-OF-SURFACE' <<<"$sent" || fail "the verification surface was truncated away (#2009)"
grep -qF '§3e review — ran:' <<<"$sent" || fail "the §3e review ran: line was truncated away (#2009)"
grep -qxF '🤖 Generated with [Claude Code](https://claude.com/claude-code)' <<<"$sent" \
  || fail "the attribution footer was truncated away (#2009)"
# Legible, never silent: the marker names what went, how much, and where to read it.
marker="$(grep -F '[PR-body cap]' <<<"$sent")"
[ -n "$marker" ] || fail "an over-cap body was truncated SILENTLY — no inline marker (#2009)"
grep -qF 'shell-reviewer' <<<"$marker" || fail "the marker does not name the dropped round (got: $marker)"
grep -qE '[0-9]+ bytes' <<<"$marker" || fail "the marker does not name how many bytes went (got: $marker)"
grep -qF 'agent-*.jsonl' <<<"$marker" \
  || fail "the marker does not name the workflow journal as where the full text lives (got: $marker)"
# The prose rungs actually EXECUTED — the reviewers' own top-level `## Summary`
# headings did not end the `## Review notes` section early, leaving the ladder to
# fall through to rung 4's blunt head-cut. That fall-through is the exact defect
# the `### `-only fixture hid, so assert against it directly, not by inference.
grep -qF 'cut here to fit' <<<"$marker" \
  && fail "the ladder fell through to rung 4's structural floor on a body rungs 1-3 could bound (#2009)"
grep -qF '## Summary' "$TMP/cap-summary.md" \
  || fail "the fixture no longer carries the reviewers' real top-level heading shape (#2009)"
# The newest round is never the casualty of a SPOOF. Its prose carries a stray
# single-word `### Notes`, a fenced code block holding a literal block delimiter
# and a `### ` heading, and a bare delimiter at line start — none of which may be
# read as a block boundary. If any were, that round's residual HIGH would be
# droppable and the previous pass's failure would be back verbatim.
grep -qF '### Notes' "$TMP/cap-summary.md" \
  || fail "the fixture lost its adversarial stray '### Notes' heading (#2009)"
grep -qF '### [HIGH] NEWEST finding in x.sh' <<<"$sent" \
  || fail "a stray heading inside the NEWEST round's prose spoofed a block boundary and its residual HIGH was dropped (#2009)"
grep -qF '### workflow-reviewer (ci-fix round 2)' <<<"$sent" \
  || fail "the NEWEST round's own reviewer heading was dropped (#2009)"
grep -qF 'workflow-reviewer' <<<"$marker" \
  && fail "the drop marker names the NEWEST round's reviewer — a phantom round shifted the newest-round bound (#2009)"
echo "PASS: an over-cap body is bounded BEFORE gh — reviewer prose dropped oldest-round-first, legibly (#2009)"

# 2a. Block boundaries come from the PRODUCER's delimiter, never from a Markdown
#     heading — and a reviewer quoting that delimiter cannot spoof one.
grep -qE '^<!-- 3e-review-block reviewer="shell-reviewer" round="0" -->$' "$TMP/cap-summary.md" \
  || fail "reviewBodySuffix did not emit an explicit block delimiter (#2009)"
grep -qE '^<!-- 3e-review-block reviewer="workflow-reviewer" round="2" -->$' "$TMP/cap-summary.md" \
  || fail "the block delimiter does not carry the round key (#2009)"
# Both planted delimiters — the fenced one and the bare one — must come out
# NEUTRALIZED, and no un-neutralized spoof may survive anywhere in the section.
grep -qF '<!-- 3e-review-block-quoted reviewer="spoof-fenced"' "$TMP/cap-summary.md" \
  || fail "a delimiter quoted inside a reviewer's fenced code block was spliced un-neutralized (#2009)"
grep -qF '<!-- 3e-review-block-quoted reviewer="spoof-bare"' "$TMP/cap-summary.md" \
  || fail "a delimiter planted at line start in reviewer prose was spliced un-neutralized (#2009)"
grep -cE '^<!-- 3e-review-block reviewer="[^"]*" round="[0-9]+" -->$' "$TMP/cap-summary.md" \
  | grep -x 3 >/dev/null || fail "the section carries a block delimiter that reviewBodySuffix did not emit (#2009)"
# The two literals are one contract across two files. A rename on either side
# silently returns the consumer to seeing zero rounds, which no-ops every prose
# rung — green tests, dead feature. Pin them together.
grep -qF "const REVIEW_BLOCK_MARK = '3e-review-block';" "$MJS" \
  || fail "build-level.mjs no longer defines the block delimiter literal this suite pins (#2009)"
grep -qF '3e-review-block reviewer="[^"]*" round="[0-9]+"' "$SCRIPT" \
  || fail "pr.sh's block-head pattern no longer matches build-level.mjs's delimiter grammar (#2009)"
# The consumer must not have a heading-shaped fallback left: a `^### ` block-head
# test is exactly what the last two passes were spoofed through.
grep -q 'is_block_head(s)' "$SCRIPT" \
  || fail "pr.sh's is_block_head was renamed away from the delimiter-keyed form (#2009)"
grep -qF 'if (s !~ /^### /) return 0' "$SCRIPT" \
  && fail "pr.sh still infers a block head from a Markdown '###' heading (#2009)"
echo "PASS: block edges are keyed on the producer's explicit delimiter, and quoted delimiters are neutralized (#2009)"

# 2c. The spoof, sized so that inferring block heads from Markdown ACTUALLY
#     costs the newest round its findings — the shape the previous pass shipped
#     green. The newest round's prose carries a fenced code block holding a
#     delimiter, then a bare single-word `### Notes` heading followed by the bulk
#     of the round's text.
#
#     Under a `### <token>` block-head heuristic that reads as THREE rounds —
#     shell-reviewer, workflow-reviewer, and a phantom "Notes" round — so rung
#     1's `drop <= rounds - 1` clamp permits dropping the genuine newest round
#     while the marker still calls the (phantom) newest one protected. Under the
#     producer-emitted delimiter it is TWO rounds, the clamp protects the real
#     newest, and rung 2 trims only its prose. The sizing is what makes the
#     difference observable: one dropped round is not enough to fit, so the
#     heuristic is forced to take the second.
{
  printf '## Summary\n\nReviewed the diff.\n\n## Findings\n\n'
  printf '### [HIGH] RESIDUAL finding in x.sh\n\n'
  i=1
  while [ "$i" -le 6 ]; do printf 'RESIDUAL prose line %d — 0123456789012345678901234567890123456789\n' "$i"; i=$((i + 1)); done
  printf '\nQuoting the design, as a reviewer just did:\n\n```text\n<!-- 3e-review-block reviewer="spoof-fenced" round="9" -->\n### spoof-fenced\n```\n'
  printf '\n### Notes\n\n'
  i=1
  while [ "$i" -le 40 ]; do printf 'NOTES prose line %d — 0123456789012345678901234567890123456789\n' "$i"; i=$((i + 1)); done
} > "$TMP/rt-spoof-new.md"
mk_text SPOOFOLD 40 > "$TMP/rt-spoof-old.md"
jq -n --rawfile a "$TMP/rt-spoof-old.md" --rawfile b "$TMP/rt-spoof-new.md" '[
  {ran: [{reviewer: "shell-reviewer"}],    sections: [{reviewer: "shell-reviewer",    text: $a}]},
  {ran: [{reviewer: "workflow-reviewer"}], sections: [{reviewer: "workflow-reviewer", text: $b}]}
]' > "$TMP/cap-rounds-spoof.json"
render_review_suffix "$TMP/cap-rounds-spoof.json" > "$TMP/cap-suffix-spoof.md" \
  || fail "could not render the spoof ## Review notes through reviewBodySuffix (#2009)"
{ printf 'Body.'; cat "$TMP/cap-suffix-spoof.md"; } > "$TMP/cap-summary-spoof.md"
jq -n --rawfile s "$TMP/cap-summary-spoof.md" '{
  status: "done",
  summary: ($s | rtrimstr("\n")),
  acceptance_results: [{criterion: "prose cannot spoof a block boundary", passed: true,
                        evidence: "activation proof: grep -q BUILD_PR_BODY_MAX_BYTES build.config.sh"}]
}' > "$TMP/verdict-cap-spoof.json"
spoof="$(BUILD_PR_BODY_MAX_BYTES="$cap" bash "$SCRIPT" open --verdict "$TMP/verdict-cap-spoof.json" \
  --gh-issue 2009 --plan-link "Plans/p#i" --source "epic #2009" \
  --verification-surface-file "$TMP/surface-cap.md" --body-only)"
[ "$(LC_ALL=C printf %s "$spoof" | wc -c | tr -d ' ')" -le "$cap" ] \
  || fail "the spoof-bearing body was not bounded (#2009)"
grep -qF 'SPOOFOLD prose line' <<<"$spoof" \
  && fail "the oldest round's prose survived the spoof fixture — the ladder did not run oldest-first (#2009)"
# THE assertion. temperloop#1970 routes residual blocking findings into this
# section for the human at the merge gate; a heading-inferred boundary drops
# exactly this line.
grep -qF '### [HIGH] RESIDUAL finding in x.sh' <<<"$spoof" \
  || fail "a stray '### Notes' in the newest round's prose spoofed a block boundary and the round's residual HIGH was dropped (#2009)"
grep -qF '### workflow-reviewer (ci-fix round 1)' <<<"$spoof" \
  || fail "the newest round's reviewer heading was dropped by a spoofed boundary (#2009)"
spoof_marker="$(grep -F 'earliest §3e review round' <<<"$spoof")"
grep -qF 'the 1 earliest §3e review round(s)' <<<"$spoof_marker" \
  || fail "the ladder dropped more than the one genuine older round (got: $spoof_marker)"
grep -qF 'workflow-reviewer' <<<"$spoof_marker" \
  && fail "the marker names the newest round's reviewer as dropped (got: $spoof_marker)"
grep -qF '<!-- 3e-review-block-quoted reviewer="spoof-fenced"' "$TMP/cap-summary-spoof.md" \
  || fail "a delimiter inside a fenced code block reached the body un-neutralized (#2009)"
echo "PASS: a stray heading and a fenced delimiter in the NEWEST round cannot spoof a block boundary — its findings survive (#2009)"

# 2b. The unit of truncation is a ROUND, not a reviewer block. One round renders
#     one block PER ROUTED REVIEWER, so a three-reviewer final round is three
#     blocks — and dropping blocks one at a time would strip two of them while
#     the marker still claimed the newest round was protected. temperloop#1970
#     carries residual blocking findings into this very section, so those are
#     precisely the findings that must survive.
mk_text OLDA 30 > "$TMP/rt-olda.md"
mk_text OLDB 30 > "$TMP/rt-oldb.md"
mk_text NEWA 4 > "$TMP/rt-newa.md"
mk_text NEWB 4 > "$TMP/rt-newb.md"
mk_text NEWC 4 "$ADVERSARIAL" > "$TMP/rt-newc.md"
jq -n --rawfile a "$TMP/rt-olda.md" --rawfile b "$TMP/rt-oldb.md" \
      --rawfile c "$TMP/rt-newa.md" --rawfile d "$TMP/rt-newb.md" --rawfile e "$TMP/rt-newc.md" '[
  {ran: [{reviewer: "shell-reviewer"}, {reviewer: "docs-reviewer"}],
   sections: [{reviewer: "shell-reviewer", text: $a}, {reviewer: "docs-reviewer", text: $b}]},
  {ran: [{reviewer: "workflow-reviewer"}],
   sections: [{reviewer: "shell-reviewer", text: $c}, {reviewer: "docs-reviewer", text: $d},
              {reviewer: "workflow-reviewer", text: $e}]}
]' > "$TMP/cap-rounds-multi.json"
render_review_suffix "$TMP/cap-rounds-multi.json" > "$TMP/cap-suffix-multi.md" \
  || fail "could not render the multi-reviewer ## Review notes through reviewBodySuffix (#2009)"
{ printf 'Body.'; cat "$TMP/cap-suffix-multi.md"; } > "$TMP/cap-summary-multi.md"
jq -n --rawfile s "$TMP/cap-summary-multi.md" '{
  status: "done",
  summary: ($s | rtrimstr("\n")),
  acceptance_results: [{criterion: "the round is the unit", passed: true,
                        evidence: "activation proof: grep -q BUILD_PR_BODY_MAX_BYTES build.config.sh"}]
}' > "$TMP/verdict-cap-multi.json"
multi="$(BUILD_PR_BODY_MAX_BYTES="$cap" bash "$SCRIPT" open --verdict "$TMP/verdict-cap-multi.json" \
  --gh-issue 2009 --plan-link "Plans/p#i" --source "epic #2009" \
  --verification-surface-file "$TMP/surface-cap.md" --body-only)"
[ "$(LC_ALL=C printf %s "$multi" | wc -c | tr -d ' ')" -le "$cap" ] \
  || fail "the multi-reviewer-round body was not bounded (#2009)"
for tag in OLDA OLDB; do
  grep -qF "$tag prose line" <<<"$multi" \
    && fail "an OLDEST-round reviewer's prose ($tag) survived while newer prose was cut (#2009)"
done
for r in 'shell-reviewer (ci-fix round 1)' 'docs-reviewer (ci-fix round 1)' 'workflow-reviewer (ci-fix round 1)'; do
  grep -qF "### $r" <<<"$multi" \
    || fail "the newest round lost reviewer '$r' — truncation counted blocks, not rounds (#2009)"
done
for tag in NEWA NEWB NEWC; do
  grep -qF "### [HIGH] $tag finding" <<<"$multi" \
    || fail "a residual finding heading from the newest round ($tag) was dropped (#2009)"
done
# The marker's unit is honest: ONE round went, and it names both of that round's
# reviewers — never "1 round" while only one of its two blocks was removed.
multi_marker="$(grep -F 'earliest §3e review round' <<<"$multi")"
grep -qF 'the 1 earliest §3e review round(s)' <<<"$multi_marker" \
  || fail "the marker miscounts the truncation unit (got: $multi_marker)"
grep -qF 'shell-reviewer, docs-reviewer' <<<"$multi_marker" \
  || fail "the marker does not name every reviewer in the dropped round (got: $multi_marker)"
echo "PASS: truncation drops whole ROUNDS — a multi-reviewer final round keeps every reviewer and finding heading (#2009)"

# 3. --body-only reflects the SAME bounding, byte-for-byte: the assembled-body
#    preview and the outbound body cannot disagree about what was truncated.
preview="$(BUILD_PR_BODY_MAX_BYTES="$cap" bash "$SCRIPT" open --verdict "$TMP/verdict-cap.json" \
  --gh-issue 2009 --also-closes 1958 --plan-link "Plans/p#i" --source "epic #2009" \
  --verification-surface-file "$TMP/surface-cap.md" --body-only)"
[ "$preview" = "$sent" ] \
  || fail "--body-only's preview diverges from the bounded body handed to gh (#2009)"
echo "PASS: open --body-only reflects the same bounding as the outbound body (#2009)"

# 4. A body with NO reviewer prose at all is bounded too — the surface's middle is
#    elided, its head AND tail kept, and the section itself is never dropped.
{ printf 'HEAD-OF-SURFACE\n'; i=1; while [ "$i" -le 200 ]; do printf 'surface filler line %d — 0123456789012345678901234567890123456789\n' "$i"; i=$((i + 1)); done; printf 'TAIL-OF-SURFACE\n'; } > "$TMP/surface-big.md"
body="$(BUILD_PR_BODY_MAX_BYTES="$cap" bash "$SCRIPT" open --verdict "$TMP/verdict.json" \
  --gh-issue 2009 --verification-surface-file "$TMP/surface-big.md" --body-only)"
[ "$(LC_ALL=C printf %s "$body" | wc -c | tr -d ' ')" -le "$cap" ] \
  || fail "a review-prose-free over-cap body was not bounded (#2009)"
grep -qF 'HEAD-OF-SURFACE' <<<"$body" || fail "the surface head was not kept (#2009)"
grep -qF 'TAIL-OF-SURFACE' <<<"$body" || fail "the surface tail was not kept (#2009)"
grep -qF '## Verification' <<<"$body" || fail "the verification section was dropped outright (#2009)"
grep -qx 'Closes #2009' <<<"$body" || fail "linkage lost while eliding the surface (#2009)"
surface_marker="$(grep -F '[PR-body cap]' <<<"$body")"
grep -qF 'verification surface' <<<"$surface_marker" \
  || fail "the surface elision is not marked inline (#2009)"
echo "PASS: a body with no reviewer prose is bounded by eliding the surface middle, head+tail kept (#2009)"

# 5. A cap below the parts no rung may cut (linkage + footer + one marker) is
#    clamped to the structural floor, and a non-numeric one falls back — neither
#    can disable the bound or ask for a body that could not be assembled at all.
for bad in 10 not-a-number ""; do
  body="$(BUILD_PR_BODY_MAX_BYTES="$bad" bash "$SCRIPT" open --verdict "$TMP/verdict-cap.json" \
    --gh-issue 2009 --verification-surface-file "$TMP/surface-cap.md" --body-only)"
  bytes="$(LC_ALL=C printf %s "$body" | wc -c | tr -d ' ')"
  [ "$bytes" -gt 0 ] || fail "cap '$bad' produced an empty body (#2009)"
  grep -qx 'Closes #2009' <<<"$body" || fail "cap '$bad' lost the linkage line (#2009)"
  grep -qxF '🤖 Generated with [Claude Code](https://claude.com/claude-code)' <<<"$body" \
    || fail "cap '$bad' lost the attribution footer (#2009)"
done
# The empty/non-numeric arms fall back to the registered default, so they must
# NOT truncate this fixture at all; the clamped tiny cap must.
grep -qF '[PR-body cap]' <<<"$(BUILD_PR_BODY_MAX_BYTES=not-a-number bash "$SCRIPT" open \
  --verdict "$TMP/verdict-cap.json" --gh-issue 2009 --body-only)" \
  && fail "a non-numeric cap did not fall back to the registered default (#2009)"
grep -qF '[PR-body cap]' <<<"$(BUILD_PR_BODY_MAX_BYTES=10 bash "$SCRIPT" open \
  --verdict "$TMP/verdict-cap.json" --gh-issue 2009 --body-only)" \
  || fail "a below-floor cap was ignored instead of clamped (#2009)"
echo "PASS: a below-floor cap clamps and a non-numeric one falls back — neither disables the bound (#2009)"

# 6. Rung 4's EXHAUSTION path still cannot emit an over-cap body. The shrink loop
#    cuts at line boundaries and re-appends the whole linkage block, so a linkage
#    tail that alone exceeds the cap leaves it stuck over the bound — and simply
#    breaking out would hand `gh` an over-cap body, the very API rejection this
#    item exists to prevent, now wearing a truncation marker. The ladder instead
#    hard-cuts byte-exactly and announces the residual on stderr.
many="$(seq 1000 1249 | paste -sd, -)"     # 250 also-closes lines ≫ the 2000-byte cap floor
err="$TMP/cap-exhaust.err"
body="$(BUILD_PR_BODY_MAX_BYTES=2000 bash "$SCRIPT" open --verdict "$TMP/verdict-cap.json" \
  --gh-issue 2009 --also-closes "$many" --plan-link "Plans/p#i" --source "epic #2009" \
  --verification-surface-file "$TMP/surface-cap.md" --body-only 2>"$err")"
bytes="$(LC_ALL=C printf %s "$body" | wc -c | tr -d ' ')"
[ "$bytes" -le 2000 ] \
  || fail "rung 4's exhaustion path emitted a $bytes-byte body over the 2000-byte cap (#2009)"
grep -q '^ERROR: PR-body cap ladder exhausted' "$err" \
  || fail "an exhausted ladder cut the body without a structured ERROR on stderr (got: $(cat "$err"))"
grep -qE 'ERROR: .* [0-9]+ bytes still over the [0-9]+-byte cap' "$err" \
  || fail "the exhaustion ERROR does not name the residual size (got: $(cat "$err"))"
echo "PASS: rung 4's exhaustion path hard-cuts byte-exactly and reports the residual — never an over-cap body (#2009)"

# 6b. That last-resort cut, exercised DIRECTLY — because the ladder structurally
#     cannot reach it with a body big enough to expose its two real hazards, and
#     that is precisely how a SIGPIPE-prone form survived two passes. Exhaustion
#     implies the linkage tail alone nears the cap, which forces `keep` to 1, so
#     the body handed to the cut is only marker+linkage+footer: a few KB, always
#     ASCII, and comfortably inside a pipe buffer. The hazards live outside that
#     envelope, so the function is extracted and driven on inputs that reach them.
hb="$(sed -n '/^hard_bytes() {$/,/^}$/p' "$SCRIPT")"
[ -n "$hb" ] || fail "could not extract hard_bytes from pr.sh — the last-resort cut is untested (#2009)"
# (a) A 300KB input, far past any pipe buffer. The previous form was
#     `printf %s "$body" | head -c "$cap"`: head exits as soon as it has its
#     bytes, printf takes SIGPIPE and exits 141, pipefail propagates it and
#     `set -e` aborts pr.sh at the assignment — a bare 141 with no structured
#     ERROR and no body at all, on the one rung whose contract is "cannot fail".
printf 'x%.0s' $(seq 1 99) > "$TMP/hb-line.txt"
{ i=1; while [ "$i" -le 3000 ]; do cat "$TMP/hb-line.txt"; printf '\n'; i=$((i + 1)); done; } > "$TMP/hb-big.txt"
[ "$(LC_ALL=C wc -c < "$TMP/hb-big.txt" | tr -d ' ')" -gt 200000 ] || fail "the hard_bytes fixture is too small to reach the SIGPIPE envelope (#2009)"
out="$(bash -c 'set -euo pipefail
'"$hb"'
hard_bytes 2000 < "$1"' _ "$TMP/hb-big.txt")" \
  || fail "hard_bytes died on a 300KB input — the SIGPIPE class is back (#2009)"
[ "$(LC_ALL=C printf %s "$out" | wc -c | tr -d ' ')" -le 2000 ] \
  || fail "hard_bytes overshot its byte budget (#2009)"
# (b) UTF-8. A raw byte cut can land INSIDE a multi-byte sequence and hand `gh`
#     invalid UTF-8. Budget 101 lands on the first byte of a 2-byte character
#     here, so a correct cut backs off to the preceding ASCII boundary.
{ i=1; while [ "$i" -le 20 ]; do printf 'éééééééééé \n'; i=$((i + 1)); done; } > "$TMP/hb-utf8.txt"
out="$(bash -c 'set -euo pipefail
'"$hb"'
hard_bytes 101 < "$1"' _ "$TMP/hb-utf8.txt")" \
  || fail "hard_bytes refused a cut it could make safely (#2009)"
[ -n "$out" ] || fail "hard_bytes returned nothing for a budget with a safe boundary in it (#2009)"
printf %s "$out" | python3 -c 'import sys; sys.stdin.buffer.read().decode("utf-8")' \
  || fail "hard_bytes split a multi-byte UTF-8 sequence (#2009)"
# (c) No safe boundary at all → refuse (empty, non-zero), never emit a mangled
#     cut. pr.sh turns that into its own structured ERROR rather than guessing.
printf 'éééééééééééééééééééééééééééééééééééééééééééééééééé' > "$TMP/hb-noascii.txt"
rc=0
out="$(bash -c 'set -euo pipefail
'"$hb"'
hard_bytes 51 < "$1"' _ "$TMP/hb-noascii.txt")" || rc=$?
[ "$rc" -ne 0 ] || fail "hard_bytes returned a cut with no safe UTF-8 boundary instead of refusing (#2009)"
[ -z "$out" ] || fail "hard_bytes emitted bytes on its refusal path (#2009)"
# And the construct itself is gone from the ladder, not merely bypassed on the
# path the tests above happen to take.
ladder="$(awk '/^# --- the PR-body cap/,/^# --- acceptance-extract/' "$SCRIPT" | grep -vE '^[[:space:]]*#')"
grep -qF 'head -c' <<<"$ladder" \
  && fail "the cap ladder pipes into head -c again — that construct SIGPIPEs its producer under pipefail (#2009)"
grep -qF 'hard_bytes "$cap"' <<<"$ladder" \
  || fail "rung 4's exhaustion arm no longer routes through hard_bytes (#2009)"
echo "PASS: hard_bytes survives a 300KB input, never splits UTF-8, and refuses rather than mangle (#2009)"

# 7. Every awk in the cap ladder is LC_ALL=C-pinned. The ladder's budgets are in
#    BYTES and it measures them with awk's `length()`, which under gawk in a
#    UTF-8 locale counts CHARACTERS — silently turning a byte budget into a
#    character one. macOS awk and Ubuntu mawk both happen to count bytes, so an
#    unpinned call agrees on dev and CI by luck, not by contract, and no runtime
#    assertion here can catch it. A static check can.
unpinned="$(awk '/^# --- the PR-body cap/,/^# --- acceptance-extract/' "$SCRIPT" \
  | grep -vE '^[[:space:]]*#' | grep -n 'awk ' | grep -v 'LC_ALL=C awk' || true)"
[ -z "$unpinned" ] \
  || fail "an awk in the PR-body cap ladder is not LC_ALL=C-pinned, so its byte budget is locale-dependent (#2009): $unpinned"
echo "PASS: every awk in the cap ladder pins LC_ALL=C, so its budgets are bytes under any awk/locale (#2009)"

# --- recover-probe: the staged lost-return side-effect ladder (temperloop#939) ----
# Drives all four stages against the real fixture, bottom to top, on a branch of
# its own so the earlier push tests' remote state cannot mask a stage transition.
git -C "$REPO" fetch -q origin
git -C "$REPO" checkout -q -b build/recov origin/main
out="$(bash "$SCRIPT" recover-probe "$REPO" feat/recov)"
[ "$(jq -r .outcome <<<"$out")" = "RECOVER_NONE" ] \
  || fail "no commits + no PR must be RECOVER_NONE (got: $out)"
[ "$(jq -r .commits_ahead <<<"$out")" = "0" ] || fail "commits_ahead should be 0 (got: $out)"
[ "$(jq -r .pushed <<<"$out")" = "false" ] || fail "pushed should be false (got: $out)"
jq -e 'has("pr_number") | not' <<<"$out" >/dev/null || fail "pr_number must be absent with no PR (got: $out)"
[ "$(jq -r .dirty <<<"$out")" = "false" ] || fail "a clean worktree must report dirty:false (got: $out)"
[ "$(jq -r .dirty_files <<<"$out")" = "0" ] || fail "a clean worktree must report dirty_files:0 (got: $out)"
echo "PASS: recover-probe → RECOVER_NONE when nothing observable landed (the genuine-failure case)"

# --- recover-probe: the DIRTY rung (temperloop#993) -------------------------------
# Same zero-commit, no-PR state as RECOVER_NONE above — but with real work left on
# disk. That is the backgrounded-gate stall (#982: 8 modified files / 0 commits;
# #983: 3 / 0), and it must NOT read as "nothing happened": the caller resumes the
# worker on THIS worktree instead of escalating. Both index-staged and untracked
# paths count toward the porcelain tally.
printf 'staged work\n' > "$REPO/staged-work.txt"
git -C "$REPO" add staged-work.txt
printf 'untracked work\n' > "$REPO/untracked-work.txt"
out="$(bash "$SCRIPT" recover-probe "$REPO" feat/recov)"
[ "$(jq -r .outcome <<<"$out")" = "RECOVER_DIRTY" ] \
  || fail "a dirty worktree with 0 commits must be RECOVER_DIRTY, not RECOVER_NONE (got: $out)"
[ "$(jq -r .commits_ahead <<<"$out")" = "0" ] \
  || fail "RECOVER_DIRTY must still report commits_ahead 0 (got: $out)"
[ "$(jq -r .pushed <<<"$out")" = "false" ] || fail "RECOVER_DIRTY must report pushed:false (got: $out)"
[ "$(jq -r .dirty <<<"$out")" = "true" ] || fail "dirty must be true on a dirty worktree (got: $out)"
[ "$(jq -r .dirty_files <<<"$out")" = "2" ] \
  || fail "dirty_files must count BOTH the staged and the untracked path (got: $out)"
echo "PASS: recover-probe → RECOVER_DIRTY on uncommitted work with zero commits (the #993 stall shape)"
git -C "$REPO" rm -q --cached staged-work.txt >/dev/null
rm -f "$REPO/staged-work.txt" "$REPO/untracked-work.txt"

# `.build-guard` is worktree.sh's OWN marker, not worker work: it must not count
# toward the dirty tally, or every freshly-created worktree would read
# RECOVER_DIRTY in a consuming repo that has not gitignored it.
printf '{"slug":"x"}\n' > "$REPO/.build-guard"
out="$(bash "$SCRIPT" recover-probe "$REPO" feat/recov)"
[ "$(jq -r .outcome <<<"$out")" = "RECOVER_NONE" ] \
  || fail "the .build-guard marker alone must not make a worktree read dirty (got: $out)"
[ "$(jq -r .dirty_files <<<"$out")" = "0" ] \
  || fail ".build-guard must be excluded from the dirty tally (got: $out)"
echo "PASS: recover-probe excludes worktree.sh's own .build-guard marker from the dirty tally (#993)"
rm -f "$REPO/.build-guard"

git -C "$REPO" commit -q --allow-empty -m "worker work that never returned a verdict"
recov_sha="$(git -C "$REPO" rev-parse HEAD)"
out="$(bash "$SCRIPT" recover-probe "$REPO" feat/recov)"
[ "$(jq -r .outcome <<<"$out")" = "RECOVER_COMMITTED" ] \
  || fail "a commit ahead of base with no push must be RECOVER_COMMITTED (got: $out)"
[ "$(jq -r .sha <<<"$out")" = "$recov_sha" ] || fail "probe sha mismatch (got: $out)"
[ "$(jq -r .commits_ahead <<<"$out")" = "1" ] || fail "commits_ahead should be 1 (got: $out)"
[ "$(jq -r .verification_surface_present <<<"$out")" = "false" ] \
  || fail "verification_surface_present should be false (got: $out)"
echo "PASS: recover-probe → RECOVER_COMMITTED on an unpushed worktree commit (the #939 L1 shape)"

PATH="$NOGH:$PATH" bash "$SCRIPT" push "$REPO" feat/recov >/dev/null
: > "$REPO/.build-verification.md"
out="$(bash "$SCRIPT" recover-probe "$REPO" feat/recov)"
[ "$(jq -r .outcome <<<"$out")" = "RECOVER_PUSHED" ] \
  || fail "a pushed branch with no PR must be RECOVER_PUSHED (got: $out)"
[ "$(jq -r .pushed <<<"$out")" = "true" ] || fail "pushed should be true (got: $out)"
[ "$(jq -r .remote_sha <<<"$out")" = "$recov_sha" ] || fail "remote_sha mismatch (got: $out)"
[ "$(jq -r .verification_surface_present <<<"$out")" = "true" ] \
  || fail "verification_surface_present must report the worker's .build-verification.md (got: $out)"
echo "PASS: recover-probe → RECOVER_PUSHED once the branch is on origin (+ surface-file presence)"

mkdir -p "$TMP/bin-prlist"
cat > "$TMP/bin-prlist/gh" <<'EOF'
#!/usr/bin/env bash
echo '[{"number":936,"url":"https://github.com/Towheads/temperloop/pull/936"}]'
EOF
chmod +x "$TMP/bin-prlist/gh"
out="$(PATH="$TMP/bin-prlist:$PATH" bash "$SCRIPT" recover-probe "$REPO" feat/recov)"
[ "$(jq -r .outcome <<<"$out")" = "RECOVER_PR_OPEN" ] \
  || fail "an open PR for the branch must be RECOVER_PR_OPEN (got: $out)"
[ "$(jq -r .pr_number <<<"$out")" = "936" ] || fail "pr_number not adopted from gh (got: $out)"
[ "$(jq -r .url <<<"$out")" = "https://github.com/Towheads/temperloop/pull/936" ] \
  || fail "url not adopted from gh (got: $out)"
echo "PASS: recover-probe → RECOVER_PR_OPEN{pr_number,url} when an open PR exists (the #939 L0 shape)"

# Fail-soft: a broken/erroring gh degrades to "no PR observed" rather than
# failing the whole recovery (the caller's `open` then returns EXISTS and adopts).
mkdir -p "$TMP/bin-ghfail"
cat > "$TMP/bin-ghfail/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh: could not determine repository" >&2
exit 1
EOF
chmod +x "$TMP/bin-ghfail/gh"
out="$(PATH="$TMP/bin-ghfail:$PATH" bash "$SCRIPT" recover-probe "$REPO" feat/recov)"
[ "$(jq -r .outcome <<<"$out")" = "RECOVER_PUSHED" ] \
  || fail "an erroring gh must degrade to the push-stage answer, not fail (got: $out)"
echo "PASS: recover-probe degrades fail-soft when gh errors (no PR observed, push stage still reported)"
rm -f "$REPO/.build-verification.md"

# --- error: closed ERROR outcome + non-zero exit ----------------------------------
rc=0; out="$(bash "$SCRIPT" recover-probe "$TMP/nonexistent" feat/recov 2>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] && [ "$(jq -r .outcome <<<"$out")" = "ERROR" ] \
  || fail "recover-probe on missing path not structured ERROR (got: $out)"
rc=0; out="$(bash "$SCRIPT" scan "$TMP/nonexistent" 2>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] && [ "$(jq -r .outcome <<<"$out")" = "ERROR" ] \
  || fail "scan on missing path not structured ERROR (got: $out)"
rc=0; out="$(bash "$SCRIPT" open --gh-issue 1 --body-only 2>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] && [ "$(jq -r .outcome <<<"$out")" = "ERROR" ] \
  || fail "open without --verdict not structured ERROR (got: $out)"
rc=0; out="$(bash "$SCRIPT" open --verdict "$TMP/verdict.json" --gh-issue 'abc' --body-only 2>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] && [ "$(jq -r .outcome <<<"$out")" = "ERROR" ] \
  || fail "non-numeric --gh-issue not structured ERROR (got: $out)"
rc=0; out="$(PATH="$NOGH:$PATH" bash "$SCRIPT" push "$REPO" 'bad..branch' 2>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] && [ "$(jq -r .outcome <<<"$out")" = "ERROR" ] \
  || fail "invalid branch name not structured ERROR (got: $out)"
echo "PASS: failures emit structured ERROR + non-zero exit (closed outcome set)"
