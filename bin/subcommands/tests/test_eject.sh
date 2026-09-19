#!/usr/bin/env bash
#
# Tests for eject.sh — `temperloop eject` (foundation #765 Epic D "newcomer
# experience", item foundation-eject / #855). Same fixture style as
# test_init.sh: a throwaway real-git bare upstream + clone, a stubbed `gh`
# on PATH that LOGS every call it sees (the write-intercepting-wrapper
# proof — a declined/dry-run/offline run must leave ZERO gh calls in the
# log), zero network, structured-output assertions via jq.
#
# Covers:
#   - no .temperloop/config -> no-op, exit 0, zero gh calls, prints the
#     machine-level uninstall bullet
#   - --dry-run: zero gh calls, .temperloop/config left untouched
#   - non-interactive default-deny (no --yes, closed stdin): zero gh calls,
#     .temperloop/config left untouched
#   - consented full revert (--yes): the exact gh calls fire for each
#     install type (label/required_check/board), .temperloop/ removed
#   - idempotency: re-running after a full revert is a no-op (no config,
#     zero gh calls)
#   - proposal_pr MERGED: left alone (no close/delete-branch call, branch
#     kept), still counts as reverted
#   - proposal_pr OPEN, branch currently checked out: switches off the
#     branch first, then closes + deletes it
#   - partial failure (a label delete fails and the label still exists):
#     .temperloop/config is rewritten with only the unresolved entry,
#     exit 1, and a re-run retries only that entry
#   - offline (--no-network): every install skipped with a reason, zero gh
#     calls, .temperloop/config left in place (all entries still recorded)
#   - a label that already existed before init (no matching installs[]
#     entry) is never touched — proves manifest-driven, not namespace grep
#   - temperloop#414 partial/failed-init recovery:
#     - .temperloop/ residue with NO .temperloop/config (init.sh Step 0's
#       baseline.jsonl, written before config exists) is recognized and
#       cleaned up — zero gh calls, no branch change (the old config-gated
#       "nothing to eject" no-op used to miss this entirely)
#     - that same residue path honors --dry-run and non-interactive
#       default-deny exactly like the config-manifest path
#     - end-to-end: a REAL 'temperloop init' run that dies after its branch
#       switch (proposal-pr.sh's `git checkout -B`) leaves .temperloop/config
#       committed on the stray branch plus a recovery marker; `foundation
#       eject` restores the original branch, deletes the stray unmerged
#       local branch, and removes .temperloop/ — byte-identical to before
#       init ran
#   - temperloop#967: a REAL init run whose push SUCCEEDS but whose
#     `gh pr create` fails leaves a genuinely REMOTE stray branch (not just
#     local) plus the same recovery marker; `temperloop eject` now also
#     makes a best-effort attempt to delete the branch on the remote, not
#     only the local copy the pre-#967 recovery restore already handled
#   - temperloop#794:
#     - a config carrying `first_epic` / `first_epic_decline_pointer`
#       install entries (the read-compat case: an older init wrote one of
#       these before init.sh stopped recording them) no longer strands
#       eject — zero gh calls for either type, .temperloop/ removed, exit 0
#     - a genuinely UNKNOWN install type still marks unresolved, rewrites
#       .temperloop/config to keep only it, and exits 1 — the generic
#       unknown-type path itself stays covered as its own class, not just
#       the first_epic instance of it
#     - a MIXED manifest (a first_epic entry + a genuinely-failing label
#       entry): first_epic is dropped unconditionally and the unrelated
#       failed label entry survives alone in the rewritten config, exit 1
#       — proves the first_epic filter doesn't drop/reorder unrelated
#       entries (a single-type batch can't exercise this)
#   - temperloop#985: a hand-authored .temperloop/pricing.json survives
#     EVERY removal path that actually does an `rm -rf .temperloop` — not
#     just the happy "all installs resolved" one: the partial-init-residue
#     path, the empty-install-manifest path, AND the fully-resolved-revert
#     path each get their own test, byte-identical content and a one-line
#     "kept:" notice at each. With no pricing.json present, eject removes
#     .temperloop/ exactly as before and prints no extra line. A SECOND
#     eject run over a repo whose only .temperloop/ content is the
#     preserved pricing.json is a true no-op — the second-run idempotency
#     contract the directory-recreation carve-out could otherwise break.
#     A failed mktemp/mv stash aborts BEFORE the rm -rf runs, with no
#     false "kept" line (skipped under root, where chmod 555 is a no-op).
#     A SECOND review pass then found three more defects in the fix
#     itself: a broken pricing.json symlink survives the plain,
#     non-interrupted removal path (the restore helper's own `[ -e ]`
#     guard, distinct from the `-f`/`-L` pair used at every call site,
#     used to miss it 100% of the time); and a repo path containing both
#     an apostrophe and a space ejects cleanly end to end (a regression
#     lock for the quoting throughout eject_remove_dirs — the interrupt-
#     only defect class this path shape originally exposed, a
#     command-injection hole via unsafely-interpolated trap strings, has
#     no safe deterministic CI repro; it was verified live instead — see
#     that item's own verdict notes).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EJECT="$HERE/../eject.sh"
INIT="$HERE/../init.sh"

fail() { printf 'FAIL: %b\n' "$1" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@test \
       GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@test

WORK="$(mktemp -d "${TMPDIR:-/tmp}/eject-test-XXXXXX")"
# CHMOD_555_DIRS -- populated by any test that strips write permission off a
# fixture dir (e.g. 15f below, to force a real mktemp/mv failure) so the
# EXIT trap's own `rm -rf "$WORK"` can still remove it. Restored HERE,
# never inline in the test that set it, so a mid-test `fail` (which itself
# `exit`s) can't skip the restore and leave a stray 555 dir behind (review
# finding, second pass).
CHMOD_555_DIRS=""
cleanup() {
  for d in $CHMOD_555_DIRS; do chmod 755 "$d" 2>/dev/null || true; done
  rm -rf "$WORK"
}
trap cleanup EXIT

# --- config-hermetic git env, no background gc/maintenance (temperloop#400) --
# This suite was flaking intermittently on the macos-latest CI runner while
# passing everywhere else and locally. The suspected cause is git's automatic
# background `maintenance` / `gc --auto`, which git fires after commit/fetch/
# push and which — under a loaded runner's I/O contention — can race the NEXT
# fixture git command for the repo's index/ref locks. Pin an isolated global +
# empty system config with auto-maintenance OFF so no git process runs in the
# background, and so the fixtures depend on ZERO ambient config (identity still
# comes from the GIT_*_NAME/EMAIL vars above). GIT_OPTIONAL_LOCKS=0 stops read
# commands from taking optional locks / refreshing the index behind our back.
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_CONFIG_GLOBAL="$WORK/gitconfig"
export GIT_OPTIONAL_LOCKS=0
cat > "$GIT_CONFIG_GLOBAL" <<'GITCFG'
[gc]
	auto = 0
[maintenance]
	auto = false
[fetch]
	writeCommitGraph = false
[init]
	defaultBranch = main
GITCFG

# --- fixture: a BARE upstream (push-able) + a clone, origin/main real ------
new_fixture_repo() {
  local name="$1"
  local bare="$WORK/$name-upstream.git"
  local repo="$WORK/$name"
  git init -q --bare --initial-branch=main "$bare"
  git clone -q "$bare" "$repo" 2>/dev/null
  git -C "$repo" commit -q --allow-empty -m init
  git -C "$repo" push -q origin main 2>/dev/null
  git -C "$repo" fetch -q origin
  printf '%s\n' "$(cd "$repo" && pwd -P)"
}

seed_config() {
  # seed_config REPO_DIR INSTALLS_JSON — writes + commits .temperloop/config
  local repo="$1" installs="$2"
  mkdir -p "$repo/.temperloop"
  jq -n --argjson installs "$installs" \
    '{schema:1, generated_at:"2026-01-01T00:00:00Z",
      probe:{repo:{gh_repo:"acme/widget", default_branch:"main"}},
      tracker:{mode:"issues", board:1, boards_conf_path:"workflows/scripts/board/boards.conf", boards_conf_entry:""},
      installs:$installs}' > "$repo/.temperloop/config"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "seed .temperloop/config"
}

# --- fake gh: logs every call; env vars steer replies ----------------------
BIN="$WORK/bin"
mkdir -p "$BIN"
CALL_LOG="$WORK/gh-calls.log"
cat > "$BIN/gh" <<'FAKE_GH_EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALL_LOG"
case "$1" in
  api)
    case "$*" in
      *required_status_checks*)
        # GET (no --method) probes existence; --method DELETE reverts.
        case "$*" in
          *"--method DELETE"*) exit "${FAKE_REQUIRED_CHECK_DELETE_RC:-0}" ;;
          *) exit "${FAKE_REQUIRED_CHECK_GET_RC:-0}" ;;
        esac
        ;;
      *"git/refs/heads/"*) exit 0 ;;
      # conventions-probe.sh's two network-gated reads, reached only by
      # test 11's real `init` run. That run used to pass --no-network, which
      # made the probe skip both; since temperloop#969 that flag also skips
      # the Step 3 proposal the fixture needs init to reach, so the run drops
      # it and these endpoints are live. A bare `exit 0` with EMPTY stdout is
      # NOT a usable answer — the probe pipes it into jq and the empty result
      # blows up the final --argjson assembly (exit 2, before Step 3). Fail
      # them instead: the probe has an explicit degrade-with-a-reason arm for
      # a non-zero gh, which is also the honest answer here (test 11 deletes
      # the upstream, so nothing about this repo is reachable).
      *"/protection"*) exit 1 ;;
      *"/labels"*) exit 1 ;;
    esac
    exit 0
    ;;
  label)
    case "$2" in
      delete) exit "${FAKE_LABEL_DELETE_RC:-0}" ;;
      # mirrors the real `gh label list --json name -q '.[].name'` output
      # shape: plain names, one per line.
      list) printf '%s\n' ${FAKE_EXISTING_LABELS:-} ;;
    esac
    exit 0
    ;;
  project)
    case "$2" in
      delete) exit "${FAKE_PROJECT_DELETE_RC:-0}" ;;
      view) exit "${FAKE_PROJECT_VIEW_RC:-0}" ;;
    esac
    exit 0
    ;;
  pr)
    case "$2" in
      view) printf '%s' "${FAKE_PR_STATE:-MERGED}" ;;
      close) exit "${FAKE_PR_CLOSE_RC:-0}" ;;
      # Forces `gh pr create` to fail even though the push before it already
      # succeeded -- test 19's "push landed, PR never opened" repro (a
      # failed `gh pr create` is one of the two ways proposal-pr.sh's own
      # header says a run can die "at or after the push").
      create) [ -n "${FAKE_PR_CREATE_RC:-}" ] && exit "$FAKE_PR_CREATE_RC" ;;
    esac
    exit 0
    ;;
esac
exit 0
FAKE_GH_EOF
chmod +x "$BIN/gh"

export CALL_LOG

# run WANT_RC ARGS... — invoke eject.sh with the fake gh on PATH, closed
# stdin (proves the non-interactive default-deny path unless a test
# explicitly wants otherwise), asserts exit code. Sets $out.
run() {
  local want="$1"
  shift
  : > "$CALL_LOG"
  local rc=0
  out="$(PATH="$BIN:$PATH" \
    EJECT_GH_BIN=gh \
    FAKE_PR_STATE="${FAKE_PR_STATE:-MERGED}" \
    FAKE_PR_CLOSE_RC="${FAKE_PR_CLOSE_RC:-0}" \
    FAKE_LABEL_DELETE_RC="${FAKE_LABEL_DELETE_RC:-0}" \
    FAKE_EXISTING_LABELS="${FAKE_EXISTING_LABELS:-}" \
    FAKE_REQUIRED_CHECK_DELETE_RC="${FAKE_REQUIRED_CHECK_DELETE_RC:-0}" \
    FAKE_REQUIRED_CHECK_GET_RC="${FAKE_REQUIRED_CHECK_GET_RC:-0}" \
    FAKE_PROJECT_DELETE_RC="${FAKE_PROJECT_DELETE_RC:-0}" \
    FAKE_PROJECT_VIEW_RC="${FAKE_PROJECT_VIEW_RC:-0}" \
    CALL_LOG="$CALL_LOG" \
    bash "$EJECT" "$@" </dev/null 2>&1)" && rc=0 || rc=$?
  [ "$rc" -eq "$want" ] || fail "expected rc=$want got rc=$rc for: $* -- output:\n$out"
}

call_count() {
  grep -Fc "$1" "$CALL_LOG" 2>/dev/null || true
}

# run_init ARGS... — invoke the REAL init.sh with the same fake gh on PATH,
# closed stdin. Sets $init_out; the caller reads $init_rc itself (test 11
# below deliberately drives init.sh to a NON-zero exit — a broken push,
# standing in for a killed/failed run — and inspects the resulting repo
# state, not init.sh's own gh-call accounting).
run_init() {
  init_rc=0
  init_out="$(PATH="$BIN:$PATH" INIT_GH_BIN=gh bash "$INIT" "$@" </dev/null 2>&1)" || init_rc=$?
}

# =============================================================================
# 1. No .temperloop/config -> no-op, exit 0, zero gh calls, uninstall bullet
# =============================================================================
REPO1="$(new_fixture_repo repo1)"
run 0 --dir "$REPO1" --yes
[ ! -s "$CALL_LOG" ] || fail "no-config run made gh calls (should be zero):\n$(cat "$CALL_LOG")"
grep -q "nothing to eject" <<<"$out" || fail "no-config run did not report nothing-to-eject (got: $out)"
grep -q "Five separate removal scopes" <<<"$out" || fail "no-config run did not print the uninstall bullet (got: $out)"
echo "PASS: no .temperloop/config -> no-op, zero gh calls, uninstall bullet printed"

# =============================================================================
# 2. --dry-run: zero gh calls, config left untouched
# =============================================================================
REPO2="$(new_fixture_repo repo2)"
seed_config "$REPO2" '[{"type":"label","repo":"acme/widget","name":"fnd:status:backlog"}]'
run 0 --dir "$REPO2" --dry-run
[ ! -s "$CALL_LOG" ] || fail "dry-run made gh calls (should be zero):\n$(cat "$CALL_LOG")"
[ -f "$REPO2/.temperloop/config" ] || fail "dry-run removed .temperloop/config (should be untouched)"
echo "PASS: --dry-run makes zero gh calls, leaves .temperloop/config untouched"

# =============================================================================
# 3. Non-interactive default-deny (no --yes, closed stdin): zero gh calls,
#    config left untouched
# =============================================================================
REPO3="$(new_fixture_repo repo3)"
seed_config "$REPO3" '[{"type":"label","repo":"acme/widget","name":"fnd:status:backlog"}]'
run 0 --dir "$REPO3"
[ ! -s "$CALL_LOG" ] || fail "default-deny made gh calls (should be zero):\n$(cat "$CALL_LOG")"
[ -f "$REPO3/.temperloop/config" ] || fail "default-deny removed .temperloop/config (should be untouched)"
grep -q "aborted — nothing reverted" <<<"$out" || fail "default-deny did not report the abort (got: $out)"
echo "PASS: non-interactive, no --yes -> aborts, zero gh calls, config untouched"

# =============================================================================
# 4. Consented full revert (--yes): label + required_check + board all
#    revert via the exact gh calls, .temperloop/ removed. Then a SECOND run
#    is idempotent: no config, zero gh calls.
# =============================================================================
REPO4="$(new_fixture_repo repo4)"
seed_config "$REPO4" '[
  {"type":"label","repo":"acme/widget","name":"fnd:status:backlog"},
  {"type":"required_check","repo":"acme/widget","branch":"main","name":"checks"},
  {"type":"board","owner":"acme","project_number":42,"url":"https://github.com/orgs/acme/projects/42"}
]'
# Both report.d/ producer shims (tokens + dual-build, temperloop#2084) carry
# NO manifest entry of their own — `temperloop init` places them as tree
# artifacts, and this is the removal side of that: `eject` reverts them by
# deleting the whole `.temperloop/` tree, never a per-shim installs[] entry.
mkdir -p "$REPO4/.temperloop/report.d"
printf '#!/usr/bin/env bash\necho tokens\n' > "$REPO4/.temperloop/report.d/tokens"
printf '#!/usr/bin/env bash\necho dual-build\n' > "$REPO4/.temperloop/report.d/dual-build"
chmod 755 "$REPO4/.temperloop/report.d/tokens" "$REPO4/.temperloop/report.d/dual-build"
run 0 --dir "$REPO4" --yes
[ "$(call_count 'label delete fnd:status:backlog')" -ge 1 ] || fail "label delete call missing"
[ "$(call_count 'required_status_checks')" -ge 1 ] || fail "required-check revert call missing"
[ "$(call_count 'project delete 42')" -ge 1 ] || fail "board delete call missing"
[ ! -e "$REPO4/.temperloop/report.d/tokens" ] || fail "eject left the tokens producer shim behind"
[ ! -e "$REPO4/.temperloop/report.d/dual-build" ] || fail "eject left the dual-build producer shim behind"
[ ! -e "$REPO4/.temperloop" ] || fail "full revert did not remove .temperloop/"
grep -q "temperloop eject: done" <<<"$out" || fail "full revert did not report done (got: $out)"

run 0 --dir "$REPO4" --yes
[ ! -s "$CALL_LOG" ] || fail "second run made gh calls (should be zero — idempotent):\n$(cat "$CALL_LOG")"
grep -q "no-op" <<<"$out" || fail "second run did not report no-op (got: $out)"
echo "PASS: consented full revert fires the exact gh calls per install type, removes .temperloop/ (including both report.d/ producer shims); re-run is a zero-call no-op"

# =============================================================================
# 5. proposal_pr MERGED: left alone (no close/delete-branch call), still
#    counts as reverted (config removed)
# =============================================================================
REPO5="$(new_fixture_repo repo5)"
seed_config "$REPO5" '[{"type":"proposal_pr","branch":"foundation-init/config","pr_number":21,"url":"https://github.com/acme/widget/pull/21"}]'
FAKE_PR_STATE=MERGED run 0 --dir "$REPO5" --yes
grep -q "^pr close" "$CALL_LOG" && fail "MERGED proposal_pr should never be closed"
[ ! -e "$REPO5/.temperloop" ] || fail "MERGED proposal_pr revert did not remove .temperloop/"
grep -q "merged — left in tree" <<<"$out" || fail "did not report the merged/left-in-tree outcome (got: $out)"
echo "PASS: proposal_pr MERGED is left alone (no close call), still counts as reverted"

# =============================================================================
# 6. proposal_pr OPEN, branch currently checked out: switches off the
#    branch first, then closes + deletes it
# =============================================================================
REPO6="$(new_fixture_repo repo6)"
git -C "$REPO6" checkout -q -B foundation-init/config origin/main
seed_config "$REPO6" '[{"type":"proposal_pr","branch":"foundation-init/config","pr_number":21,"url":"https://github.com/acme/widget/pull/21"}]'
[ "$(git -C "$REPO6" symbolic-ref --short HEAD)" = "foundation-init/config" ] \
  || fail "test setup: expected to be on the proposal branch"
FAKE_PR_STATE=OPEN run 0 --dir "$REPO6" --yes
[ "$(call_count 'pr close 21')" -ge 1 ] || fail "OPEN proposal_pr was not closed"
grep -q -- "--delete-branch" "$CALL_LOG" || fail "OPEN proposal_pr close did not pass --delete-branch"
[ "$(git -C "$REPO6" symbolic-ref --short HEAD)" = "main" ] \
  || fail "did not switch off the proposal branch before closing it (on: $(git -C "$REPO6" symbolic-ref --short HEAD))"
echo "PASS: proposal_pr OPEN switches off a currently-checked-out branch, then closes + deletes it"

# =============================================================================
# 7. Partial failure: label delete fails AND the label still exists ->
#    .temperloop/config is rewritten with only that unresolved entry,
#    exit 1; a re-run retries only it.
# =============================================================================
REPO7="$(new_fixture_repo repo7)"
seed_config "$REPO7" '[
  {"type":"label","repo":"acme/widget","name":"fnd:status:backlog"},
  {"type":"label","repo":"acme/widget","name":"fnd:status:ready"}
]'
FAKE_LABEL_DELETE_RC=1 FAKE_EXISTING_LABELS="fnd:status:backlog fnd:status:ready" \
  run 1 --dir "$REPO7" --yes
grep -q "temperloop eject: incomplete" <<<"$out" || fail "partial failure did not report incomplete (got: $out)"
[ -f "$REPO7/.temperloop/config" ] || fail "partial failure removed .temperloop/config (should be kept for retry)"
cfg="$(cat "$REPO7/.temperloop/config")"
[ "$(jq '.installs | length' <<<"$cfg")" -eq 2 ] || fail "partial-failure config should keep both unresolved label entries (got: $(jq -c '.installs' <<<"$cfg"))"

# Re-run: now the deletes succeed -> fully resolved this time
FAKE_LABEL_DELETE_RC=0 run 0 --dir "$REPO7" --yes
[ ! -e "$REPO7/.temperloop" ] || fail "retry after partial failure did not fully revert"
echo "PASS: a failed revert keeps only the unresolved entries in .temperloop/config, exit 1; retry resolves them"

# =============================================================================
# 8. Offline (--no-network): every install skipped, zero gh calls, config
#    left in place with every entry still recorded
# =============================================================================
REPO8="$(new_fixture_repo repo8)"
seed_config "$REPO8" '[{"type":"label","repo":"acme/widget","name":"fnd:status:backlog"}]'
run 1 --dir "$REPO8" --yes --no-network
[ ! -s "$CALL_LOG" ] || fail "--no-network made gh calls (should be zero):\n$(cat "$CALL_LOG")"
[ -f "$REPO8/.temperloop/config" ] || fail "--no-network removed .temperloop/config (should be kept)"
grep -q -- "--no-network" <<<"$out" || fail "--no-network skip reason not reported (got: $out)"
echo "PASS: --no-network skips every install with a reason, zero gh calls, config kept for a later retry"

# =============================================================================
# 9. A pre-existing label with NO matching installs[] entry is never
#    touched — manifest-driven, not a namespace grep.
# =============================================================================
REPO9="$(new_fixture_repo repo9)"
seed_config "$REPO9" '[{"type":"label","repo":"acme/widget","name":"fnd:status:backlog"}]'
FAKE_EXISTING_LABELS="fnd:status:backlog fnd:status:ready needs-clarification" \
  run 0 --dir "$REPO9" --yes
grep -q "label delete fnd:status:ready" "$CALL_LOG" && fail "eject deleted a label with no installs[] entry (namespace-grep behavior, not manifest-driven)"
grep -q "label delete needs-clarification" "$CALL_LOG" && fail "eject deleted a label with no installs[] entry (namespace-grep behavior, not manifest-driven)"
[ "$(call_count 'label delete fnd:status:backlog')" -eq 1 ] || fail "the one recorded label was not deleted exactly once"
echo "PASS: only manifest-recorded labels are ever deleted — a pre-existing sibling label is untouched"

# =============================================================================
# 10. temperloop#414 — .temperloop/ residue with NO .temperloop/config
#     (init.sh Step 0 writes baseline.jsonl BEFORE config ever exists) is
#     recognized and cleaned up: the old config-gated no-op used to miss
#     this entirely ("nothing to eject" over real residue). Zero gh calls
#     (nothing was ever recorded), no branch change (never switched off the
#     original branch — Step 0 never touches branches).
# =============================================================================
REPO10="$(new_fixture_repo repo10)"
mkdir -p "$REPO10/.temperloop"
printf 'baseline.jsonl\n' > "$REPO10/.temperloop/.gitignore"
printf '{"schema":1,"generated_at":"2026-01-01T00:00:00Z","metrics":{"available":false}}\n' \
  > "$REPO10/.temperloop/baseline.jsonl"
BEFORE_BRANCH10="$(git -C "$REPO10" branch --show-current)"
run 0 --dir "$REPO10" --yes
[ ! -s "$CALL_LOG" ] || fail "partial-residue cleanup made gh calls (should be zero):\n$(cat "$CALL_LOG")"
[ ! -e "$REPO10/.temperloop" ] || fail "partial-residue cleanup did not remove .temperloop/"
[ "$(git -C "$REPO10" branch --show-current)" = "$BEFORE_BRANCH10" ] \
  || fail "partial-residue cleanup switched branches unexpectedly"
grep -q "Partial-init residue" <<<"$out" || fail "did not report the partial-init-residue path (got: $out)"
echo "PASS: .temperloop/ residue with no config (Step-0 baseline.jsonl only) is recognized and cleaned up, zero gh calls, no branch change"

# --- same residue path honors --dry-run and non-interactive default-deny --
REPO10B="$(new_fixture_repo repo10b)"
mkdir -p "$REPO10B/.temperloop"
printf 'baseline.jsonl\n' > "$REPO10B/.temperloop/baseline.jsonl"
run 0 --dir "$REPO10B" --dry-run
[ ! -s "$CALL_LOG" ] || fail "dry-run on partial residue made gh calls (should be zero):\n$(cat "$CALL_LOG")"
[ -e "$REPO10B/.temperloop" ] || fail "dry-run removed partial residue (should be untouched)"
grep -q "Dry run: would remove" <<<"$out" || fail "dry-run did not report what it would remove (got: $out)"

run 0 --dir "$REPO10B"
[ ! -s "$CALL_LOG" ] || fail "non-interactive default-deny on partial residue made gh calls (should be zero):\n$(cat "$CALL_LOG")"
[ -e "$REPO10B/.temperloop" ] || fail "non-interactive default-deny removed partial residue (should be untouched)"
grep -q "aborted — nothing removed" <<<"$out" || fail "non-interactive default-deny on partial residue did not report the abort (got: $out)"
echo "PASS: partial-init residue honors --dry-run and non-interactive default-deny exactly like the config-manifest path"

# =============================================================================
# 11. End-to-end partial-init -> eject recovery (temperloop#414): a REAL
#     'temperloop init' run that dies AFTER its branch switch
#     (proposal-pr.sh's `git checkout -B`) — simulated deterministically by
#     breaking the push (removing the bare upstream after cloning) rather
#     than a literal kill, so the test is hermetic/portable; the resulting
#     on-disk state (checked out on the stray proposal branch,
#     .temperloop/config committed there, .temperloop/.recovery.json
#     present, nothing ever pushed) is identical to what an interrupting
#     kill mid-push would leave. 'temperloop eject' must then restore the
#     original branch, delete the stray unmerged local branch, and remove
#     .temperloop/ — leaving the checkout byte-identical to before init ran.
# =============================================================================
BARE11="$WORK/repo11-upstream.git"
REPO11="$WORK/repo11"
git init -q --bare --initial-branch=main "$BARE11"
git clone -q "$BARE11" "$REPO11" 2>/dev/null
git -C "$REPO11" commit -q --allow-empty -m init
git -C "$REPO11" push -q origin main 2>/dev/null
git -C "$REPO11" fetch -q origin

BEFORE_HEAD11="$(git -C "$REPO11" rev-parse HEAD)"
BEFORE_BRANCH11="$(git -C "$REPO11" branch --show-current)"
BEFORE_FIND11="$(find "$REPO11" -mindepth 1 -not -path '*/.git*' | sort)"

# Break the push deterministically: remove the bare upstream AFTER cloning
# (the local refs/remotes/origin/main ref already exists, so base-branch
# resolution inside proposal-pr.sh still succeeds; only the push fails).
rm -rf "$BARE11"

# NO --no-network here, deliberately: since temperloop#969 that flag SKIPS the
# Step 3 proposal outright (branch switch and all), which is the very thing
# this fixture needs init to reach and die inside. The first-epic offer stays
# quiet anyway because run_init closes stdin — the non-attended skip arm.
run_init --dir "$REPO11" --gh-repo acme/widget
[ "$init_rc" -ne 0 ] || fail "test setup: expected the broken-push init run to fail (got rc=0): $init_out"
grep -q "proposal-pr.sh failed" <<<"$init_out" || fail "test setup: init did not fail at the expected proposal-pr step (got: $init_out)"
[ "$(git -C "$REPO11" branch --show-current)" = "foundation-init/config" ] \
  || fail "test setup: expected the failed init run to leave the checkout on foundation-init/config"
[ -f "$REPO11/.temperloop/config" ] || fail "test setup: expected .temperloop/config committed locally despite the push failure"
[ -f "$REPO11/.temperloop/.recovery.json" ] || fail "test setup: expected the recovery marker to survive the failed run"
[ "$(jq -r '.original_branch' "$REPO11/.temperloop/.recovery.json")" = "main" ] \
  || fail "test setup: recovery marker original_branch wrong (got: $(cat "$REPO11/.temperloop/.recovery.json"))"

run 0 --dir "$REPO11" --yes
grep -q "restored 'main'" <<<"$out" || fail "eject did not report restoring the original branch (got: $out)"
grep -q "deleted stray 'foundation-init/config'" <<<"$out" || fail "eject did not report deleting the stray branch (got: $out)"
[ "$(git -C "$REPO11" branch --show-current)" = "$BEFORE_BRANCH11" ] \
  || fail "eject did not restore the original branch (on: $(git -C "$REPO11" branch --show-current))"
git -C "$REPO11" show-ref --verify --quiet refs/heads/foundation-init/config \
  && fail "eject did not delete the stray local branch"
[ ! -e "$REPO11/.temperloop" ] || fail "eject did not remove .temperloop/ residue"
[ "$(git -C "$REPO11" rev-parse HEAD)" = "$BEFORE_HEAD11" ] \
  || fail "eject left HEAD different from before the failed init run"
[ -z "$(git -C "$REPO11" status --porcelain)" ] \
  || fail "eject left an uncommitted/dirty tree (status: $(git -C "$REPO11" status --porcelain))"
AFTER_FIND11="$(find "$REPO11" -mindepth 1 -not -path '*/.git*' | sort)"
[ "$AFTER_FIND11" = "$BEFORE_FIND11" ] \
  || fail "eject left extra files behind (before:\n$BEFORE_FIND11\nafter:\n$AFTER_FIND11)"
echo "PASS: a real 'temperloop init' run that dies after its branch switch (broken push, standing in for a killed process) leaves .temperloop/config committed + a recovery marker on the stray branch; 'temperloop eject' restores the original branch, deletes the stray unmerged branch, and removes .temperloop/ — byte-identical to before init ran"

# =============================================================================
# 12. temperloop#794 — a config carrying `first_epic` /
#     `first_epic_decline_pointer` install entries (the read-compat case: a
#     pre-fix init already wrote one of these) no longer strands eject.
#     Neither type ever gets a `gh` call (eject must never touch epic-issue
#     state); both are dropped as informational-only, .temperloop/ is
#     removed, exit 0.
# =============================================================================
REPO12="$(new_fixture_repo repo12)"
seed_config "$REPO12" '[
  {"type":"first_epic","repo":"acme/widget","issue":501,"url":"https://github.com/acme/widget/issues/501"},
  {"type":"first_epic_decline_pointer","repo":"acme/widget","issue":502,"url":"https://github.com/acme/widget/issues/502"}
]'
run 0 --dir "$REPO12" --yes
[ ! -s "$CALL_LOG" ] || fail "first_epic/first_epic_decline_pointer entries made gh calls (eject must never touch epic-issue state):\n$(cat "$CALL_LOG")"
grep -q "informational only — not reverted" <<<"$out" || fail "did not report the first_epic informational-only outcome (got: $out)"
[ ! -e "$REPO12/.temperloop" ] || fail "eject did not remove .temperloop/ for a config containing only first_epic-type entries"
grep -q "temperloop eject: done" <<<"$out" || fail "first_epic-only config did not report done (got: $out)"
echo "PASS: first_epic / first_epic_decline_pointer install entries no longer strand eject — zero gh calls, dropped as informational-only, .temperloop/ removed, exit 0"

# =============================================================================
# 13. The generic UNKNOWN-install-type path itself (temperloop#794 — the
#     defect class, not just the first_epic instance of it): a made-up
#     future type still hits the fallback arm, gets mark_unresolved'd, and
#     .temperloop/config is rewritten to keep only it, exit 1. Proves the
#     four existing handlers + the new first_epic read-compat handler
#     didn't accidentally widen the fallback into a silent no-op for
#     everything.
# =============================================================================
REPO13="$(new_fixture_repo repo13)"
seed_config "$REPO13" '[{"type":"bogus_future_type","repo":"acme/widget","name":"whatever"}]'
run 1 --dir "$REPO13" --yes
[ ! -s "$CALL_LOG" ] || fail "unknown install type made gh calls (should be zero):\n$(cat "$CALL_LOG")"
grep -q "unknown install type" <<<"$out" || fail "did not report the unknown-type path (got: $out)"
[ -f "$REPO13/.temperloop/config" ] || fail "unknown-type failure removed .temperloop/config (should be kept for retry)"
cfg="$(cat "$REPO13/.temperloop/config")"
[ "$(jq '.installs | length' <<<"$cfg")" -eq 1 ] || fail "unknown-type config should keep the one unresolved entry (got: $(jq -c '.installs' <<<"$cfg"))"
[ "$(jq -r '.installs[0].type' <<<"$cfg")" = "bogus_future_type" ] || fail "unresolved entry type mismatch (got: $(jq -c '.installs' <<<"$cfg"))"
grep -q "temperloop eject: incomplete" <<<"$out" || fail "unknown-type run did not report incomplete (got: $out)"
echo "PASS: a genuinely unknown install type still marks unresolved, rewrites .temperloop/config to keep it, and exits 1"

# =============================================================================
# 14. temperloop#794 — MIXED manifest: a first_epic entry alongside a label
#     entry whose delete genuinely fails (label still exists per
#     FAKE_EXISTING_LABELS, same failure fixture as test 7). Pins BOTH
#     halves of the fix at once: the first_epic entry is dropped
#     unconditionally (it must never "rescue" an unrelated failure into a
#     false success), AND the config-rewrite filter that strips first_epic
#     types doesn't drop or reorder the unrelated, genuinely-unresolved
#     label entry sitting alongside it — the property a single-type batch
#     (tests 12/13) can't exercise.
# =============================================================================
REPO14="$(new_fixture_repo repo14)"
seed_config "$REPO14" '[
  {"type":"first_epic","repo":"acme/widget","issue":501,"url":"https://github.com/acme/widget/issues/501"},
  {"type":"label","repo":"acme/widget","name":"fnd:status:backlog"}
]'
FAKE_LABEL_DELETE_RC=1 FAKE_EXISTING_LABELS="fnd:status:backlog" \
  run 1 --dir "$REPO14" --yes
grep -q "informational only — not reverted" <<<"$out" || fail "mixed-batch run did not drop the first_epic entry as informational-only (got: $out)"
grep -q "temperloop eject: incomplete" <<<"$out" || fail "mixed-batch run (genuine label failure) did not report incomplete (got: $out)"
[ -f "$REPO14/.temperloop/config" ] || fail "mixed-batch failure removed .temperloop/config (should be kept for retry)"
cfg="$(cat "$REPO14/.temperloop/config")"
[ "$(jq '.installs | length' <<<"$cfg")" -eq 1 ] || fail "mixed-batch config should keep exactly the one unresolved label entry, first_epic dropped (got: $(jq -c '.installs' <<<"$cfg"))"
[ "$(jq -r '.installs[0].type' <<<"$cfg")" = "label" ] || fail "mixed-batch unresolved entry should be the label, not first_epic (got: $(jq -c '.installs' <<<"$cfg"))"
[ "$(jq -r '.installs[0].name' <<<"$cfg")" = "fnd:status:backlog" ] || fail "mixed-batch unresolved label entry name mismatch (got: $(jq -c '.installs' <<<"$cfg"))"
echo "PASS: a mixed manifest (first_epic + a genuinely-failing label) drops the first_epic entry unconditionally and keeps only the unrelated failed label entry — intact, alone — in the rewritten config, exit 1"

# =============================================================================
# 15. temperloop#985 — a hand-authored .temperloop/pricing.json survives
#     EVERY eject removal path, not just the happy path. THE TRAP this test
#     guards against: a carve-out wired into only the final "all installs
#     reverted" success path would pass a naive single-path test and still
#     silently delete pricing.json on the partial-init-residue or
#     empty-manifest paths — so each of the three `rm -rf .temperloop`
#     call sites gets its own sub-test here (15a/15b/15c), plus the
#     no-pricing.json control (15d) proving the carve-out is invisible in
#     the common case.
# =============================================================================
PRICING_CONTENT='{"claude-opus-4-8": 18.00, "claude-sonnet-5": 5.00}'

# --- 15a: partial-init residue path (site 1 — mirrors test 10's fixture,
#     no .temperloop/config at all) --------------------------------------
REPO15A="$(new_fixture_repo repo15a)"
mkdir -p "$REPO15A/.temperloop"
printf 'baseline.jsonl\n' > "$REPO15A/.temperloop/.gitignore"
printf '%s' "$PRICING_CONTENT" > "$REPO15A/.temperloop/pricing.json"
run 0 --dir "$REPO15A" --yes
[ -f "$REPO15A/.temperloop/pricing.json" ] || fail "15a: partial-init-residue removal deleted pricing.json (site 1)"
[ "$(cat "$REPO15A/.temperloop/pricing.json")" = "$PRICING_CONTENT" ] \
  || fail "15a: pricing.json not byte-identical after partial-init-residue removal (site 1)"
[ ! -e "$REPO15A/.temperloop/.gitignore" ] || fail "15a: partial-init-residue removal left other .temperloop/ residue behind"
grep -qF "kept: .temperloop/pricing.json" <<<"$out" || fail "15a: no kept-pricing.json notice printed (site 1, got: $out)"
echo "PASS: pricing.json survives the partial-init-residue removal path (site 1), byte-identical, one-line notice"

# --- 15b: empty-install-manifest path (site 2 — n_installs==0) ---------
REPO15B="$(new_fixture_repo repo15b)"
seed_config "$REPO15B" '[]'
printf '%s' "$PRICING_CONTENT" > "$REPO15B/.temperloop/pricing.json"
run 0 --dir "$REPO15B" --yes
[ ! -s "$CALL_LOG" ] || fail "15b: empty-manifest removal made gh calls (should be zero)"
[ -f "$REPO15B/.temperloop/pricing.json" ] || fail "15b: empty-manifest removal deleted pricing.json (site 2)"
[ "$(cat "$REPO15B/.temperloop/pricing.json")" = "$PRICING_CONTENT" ] \
  || fail "15b: pricing.json not byte-identical after empty-manifest removal (site 2)"
[ ! -e "$REPO15B/.temperloop/config" ] || fail "15b: empty-manifest removal left config behind"
grep -qF "kept: .temperloop/pricing.json" <<<"$out" || fail "15b: no kept-pricing.json notice printed (site 2, got: $out)"
echo "PASS: pricing.json survives the empty-install-manifest removal path (site 2), byte-identical, one-line notice"

# --- 15c: fully-resolved-revert path (site 3 — mirrors test 4) ---------
REPO15C="$(new_fixture_repo repo15c)"
seed_config "$REPO15C" '[{"type":"label","repo":"acme/widget","name":"fnd:status:backlog"}]'
printf '%s' "$PRICING_CONTENT" > "$REPO15C/.temperloop/pricing.json"
run 0 --dir "$REPO15C" --yes
[ -f "$REPO15C/.temperloop/pricing.json" ] || fail "15c: full-revert removal deleted pricing.json (site 3)"
[ "$(cat "$REPO15C/.temperloop/pricing.json")" = "$PRICING_CONTENT" ] \
  || fail "15c: pricing.json not byte-identical after full-revert removal (site 3)"
[ ! -e "$REPO15C/.temperloop/config" ] || fail "15c: full-revert removal left config behind"
grep -qF "kept: .temperloop/pricing.json" <<<"$out" || fail "15c: no kept-pricing.json notice printed (site 3, got: $out)"
echo "PASS: pricing.json survives the fully-resolved-revert removal path (site 3), byte-identical, one-line notice"

# --- 15d: no pricing.json present -> carve-out is invisible, normal ----
#     removal, no extra line
REPO15D="$(new_fixture_repo repo15d)"
seed_config "$REPO15D" '[]'
run 0 --dir "$REPO15D" --yes
[ ! -e "$REPO15D/.temperloop" ] || fail "15d: no-pricing-json removal did not remove .temperloop/"
grep -qF "kept: .temperloop/pricing.json" <<<"$out" && fail "15d: no-pricing-json removal printed a kept-pricing.json notice when none existed (got: $out)"
echo "PASS: with no pricing.json present, eject removes .temperloop/ exactly as before and prints no extra line"

# --- 15f: a FAILED stash (mktemp/mv can't write beside .temperloop/, e.g.
#     an unwritable repo root) must abort BEFORE the rm -rf runs -- nothing
#     removed, pricing.json untouched in place, and NO false "kept" line
#     (BLOCKING 1 from the FIRST review pass: this script runs under
#     `set -uo pipefail`, not `-e`, so an unchecked mktemp/mv previously
#     fell through silently and could report "kept" over a file that was
#     actually gone). Skipped under root, where chmod 555 doesn't actually
#     block root's own writes, so the forced failure this test depends on
#     wouldn't occur -- not a false pass, a genuine inapplicability.
if [ "$(id -u)" -eq 0 ]; then
  echo "SKIP: 15f (running as root -- chmod 555 doesn't block root's own writes)"
else
  REPO15F="$(new_fixture_repo repo15f)"
  seed_config "$REPO15F" '[]'
  printf '%s' "$PRICING_CONTENT" > "$REPO15F/.temperloop/pricing.json"
  chmod 555 "$REPO15F"
  CHMOD_555_DIRS="$CHMOD_555_DIRS $REPO15F"  # restored by cleanup() even on a mid-test fail, not inline here
  run 1 --dir "$REPO15F" --yes
  chmod 755 "$REPO15F"
  [ -d "$REPO15F/.temperloop" ] || fail "15f: a failed stash still removed .temperloop/ (should be untouched)"
  [ -f "$REPO15F/.temperloop/pricing.json" ] || fail "15f: a failed stash lost pricing.json (should be untouched in place)"
  [ "$(cat "$REPO15F/.temperloop/pricing.json")" = "$PRICING_CONTENT" ] \
    || fail "15f: pricing.json content changed despite the aborted stash"
  grep -qF "kept: .temperloop/pricing.json" <<<"$out" && fail "15f: a failed stash still printed a false 'kept' line (got: $out)"
  grep -qF "FAILED to create a stash location" <<<"$out" || fail "15f: did not print the specific stash-creation-failure line (got: $out)"
  grep -q "temperloop eject: incomplete" <<<"$out" || fail "15f: a failed stash did not report incomplete (got: $out)"
  echo "PASS: a failed mktemp/mv stash aborts BEFORE the rm -rf -- .temperloop/ and pricing.json untouched, no false 'kept' claim, exit 1"
fi

# --- 15e: idempotency -- a SECOND eject run over a repo whose only
#     .temperloop/ content is the preserved pricing.json must be a true
#     no-op (temperloop#985 review finding: eject_remove_dirs's `mkdir -p`
#     to hold pricing.json back left .temperloop/ non-empty after a full
#     revert, which -- unfixed -- made a re-run fall into the
#     partial-init-residue branch instead: re-prompting to "remove"
#     content that was never residue and was already fully ejected, and
#     making eject.sh:275-277's documented "a re-run finds nothing and
#     no-ops" claim false for any repo with a preserved pricing.json) ----
REPO15E="$(new_fixture_repo repo15e)"
seed_config "$REPO15E" '[{"type":"label","repo":"acme/widget","name":"fnd:status:backlog"}]'
printf '%s' "$PRICING_CONTENT" > "$REPO15E/.temperloop/pricing.json"
run 0 --dir "$REPO15E" --yes
[ -f "$REPO15E/.temperloop/pricing.json" ] || fail "15e: first eject run deleted pricing.json"

run 0 --dir "$REPO15E" --yes
[ ! -s "$CALL_LOG" ] || fail "15e: second eject run made gh calls (should be zero -- a no-op):\n$(cat "$CALL_LOG")"
[ -f "$REPO15E/.temperloop/pricing.json" ] || fail "15e: second eject run deleted the preserved pricing.json"
[ "$(cat "$REPO15E/.temperloop/pricing.json")" = "$PRICING_CONTENT" ] \
  || fail "15e: pricing.json not byte-identical after the idempotent second run"
grep -q "no-op" <<<"$out" || fail "15e: second run over a preserved-pricing.json repo did not report no-op (got: $out)"
grep -q "Already ejected" <<<"$out" || fail "15e: second run did not report the already-ejected state (got: $out)"
echo "PASS: a second 'eject' run over a repo whose only .temperloop/ content is the preserved pricing.json is a true no-op -- matches the documented second-run idempotency contract"

# =============================================================================
# 16. temperloop#985, SECOND review pass -- BLOCKING 3: an intentionally
#     BROKEN pricing.json symlink (`-L` true, `-e`/`-f` false) must survive
#     eject. `_eject_restore_pricing_stash`'s own guard used to be a bare
#     `[ -e ]`, which FOLLOWS a symlink and is false for a broken one -- so
#     the stash (itself a broken symlink once mv'd aside) was never
#     recognized as present and the restore silently no-op'd, 100% of the
#     time, on the plain non-interrupted removal path -- no interrupt or
#     race required to reproduce this one.
# =============================================================================
REPO16="$(new_fixture_repo repo16)"
seed_config "$REPO16" '[]'
ln -s "nonexistent-target-$$" "$REPO16/.temperloop/pricing.json"
[ -L "$REPO16/.temperloop/pricing.json" ] || fail "16: test setup -- symlink was not created"
[ -e "$REPO16/.temperloop/pricing.json" ] && fail "16: test setup -- symlink must be broken (target must not exist)"
LINK_TARGET_BEFORE="$(readlink "$REPO16/.temperloop/pricing.json")"
run 0 --dir "$REPO16" --yes
[ -L "$REPO16/.temperloop/pricing.json" ] || fail "16: a broken pricing.json symlink did not survive eject"
[ "$(readlink "$REPO16/.temperloop/pricing.json" 2>/dev/null)" = "$LINK_TARGET_BEFORE" ] \
  || fail "16: restored symlink's target string changed (before: $LINK_TARGET_BEFORE, after: $(readlink "$REPO16/.temperloop/pricing.json" 2>/dev/null))"
grep -qF "kept: .temperloop/pricing.json" <<<"$out" || fail "16: no kept-pricing.json notice printed for the broken-symlink case (got: $out)"
echo "PASS: an intentionally broken pricing.json symlink survives eject on the plain (non-interrupted) removal path, target string intact"

# =============================================================================
# 17. temperloop#985, SECOND review pass -- BLOCKING 1: a repo path
#     containing BOTH an apostrophe and a space (the review's own
#     quote-mismatch/injection repro shape) must eject cleanly. The FIRST
#     fix built the interrupt-window trap by interpolating
#     `$pricing_stash`/`$pricing_src`/`$tl_mode` (derived from the repo
#     path) into a double-quoted trap STRING -- `trap`'s argument is
#     RE-PARSED as shell source when it fires, so those values were being
#     spliced into source code: a path containing `'$(...)'` executed on
#     interrupt, and an ordinary apostrophe silently mis-paired the quotes
#     across arguments and produced a no-op restore. The current fix
#     promotes those three variables to SCRIPT scope and uses a
#     single-quoted trap string (plus a bare, function-name-only trap for
#     the INT/TERM/HUP handler) so no repo-path value is EVER spliced into
#     trap source text at all -- this test exercises the ordinary
#     (non-interrupted) removal path end to end over such a path, which
#     already passed even under the vulnerable code (review: "the bug is
#     only observable on the interrupt and restore-failure paths") -- it
#     is a regression lock for the quoting throughout eject_remove_dirs
#     (mktemp/mv/stat all take this same path), not a reproduction of the
#     interrupt-only defect itself, which has no safe deterministic CI
#     repro (see this item's own verdict notes for the live manual
#     verification of the interrupt path against this exact path shape).
# =============================================================================
REPO17="$(new_fixture_repo "repo has a quote's space")"
seed_config "$REPO17" '[{"type":"label","repo":"acme/widget","name":"fnd:status:backlog"}]'
printf '%s' "$PRICING_CONTENT" > "$REPO17/.temperloop/pricing.json"
run 0 --dir "$REPO17" --yes
[ -f "$REPO17/.temperloop/pricing.json" ] || fail "17: pricing.json lost in a repo path containing an apostrophe and a space"
[ "$(cat "$REPO17/.temperloop/pricing.json")" = "$PRICING_CONTENT" ] \
  || fail "17: pricing.json corrupted in a repo path containing an apostrophe and a space"
[ ! -e "$REPO17/.temperloop/config" ] || fail "17: full-revert removal left config behind (apostrophe+space path)"
grep -qF "kept: .temperloop/pricing.json" <<<"$out" || fail "17: no kept-pricing.json notice printed (apostrophe+space path, got: $out)"
echo "PASS: a repo path containing both an apostrophe and a space ejects cleanly through the full-revert path"

# =============================================================================
# 18. temperloop#985, SECOND review pass -- BLOCKING 2's second requirement:
#     `rm -rf`'s OWN exit status must be checked and folded into a failure
#     report, so a partial removal (e.g. a real permissions/disk error --
#     not necessarily a signal) can never be silently reported as "kept" +
#     "done". Deterministic: a fake `rm` that simply exits 1, no signal or
#     timing involved -- isolates this specific fold-in logic from the
#     signal-interrupt half of the same finding, which is inherently racy
#     to reproduce deterministically in an automated suite and was instead
#     verified live (both a killed-mid-tree `rm -rf` and a signal landing
#     only on the eject.sh process itself, both confirmed to never resume
#     into a false "done" over an incompletely removed tree -- see this
#     item's own verdict notes for the exact repro and result of each).
# =============================================================================
REPO18="$(new_fixture_repo repo18)"
seed_config "$REPO18" '[]'
printf '%s' "$PRICING_CONTENT" > "$REPO18/.temperloop/pricing.json"
FAILRM="$WORK/failbin-rm18"
mkdir -p "$FAILRM"
cat > "$FAILRM/rm" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$FAILRM/rm"
rc18=0
out18="$(PATH="$FAILRM:$BIN:$PATH" EJECT_GH_BIN=gh bash "$EJECT" --dir "$REPO18" --yes </dev/null 2>&1)" || rc18=$?
[ "$rc18" -eq 1 ] || fail "18: a failing rm -rf did not produce exit 1 (got rc=$rc18): $out18"
grep -qF "kept: .temperloop/pricing.json" <<<"$out18" && fail "18: a failing rm -rf still printed a false 'kept' line (got: $out18)"
grep -q "temperloop eject: done" <<<"$out18" && fail "18: a failing rm -rf still reported 'done' (got: $out18)"
grep -qF "FAILED to fully remove .temperloop/" <<<"$out18" || fail "18: did not report the rm -rf failure (got: $out18)"
grep -q "temperloop eject: incomplete" <<<"$out18" || fail "18: a failing rm -rf did not report incomplete (got: $out18)"
[ -f "$REPO18/.temperloop/pricing.json" ] || fail "18: pricing.json was not restored despite the reported rm -rf failure -- the restore itself is independent of the removal succeeding"
echo "PASS: rm -rf's own exit status is checked -- a failed removal is reported as incomplete, never a false 'kept'+'done', even though pricing.json itself is still safely restored"

# =============================================================================
# 19. temperloop#967 — a REAL 'temperloop init' run whose PUSH SUCCEEDS but
#     whose `gh pr create` call fails (a transient API error, standing in for
#     the "dies AT OR AFTER the push" half of proposal-pr.sh's own header
#     note — distinct from test 11's broken-push repro, which never reaches
#     the remote at all). The proposal branch is pushed for REAL to the bare
#     upstream before proposal-pr.sh dies, so this is exactly the scenario
#     eject's recovery-marker branch restore used to miss: deleting only the
#     LOCAL stray branch left a genuinely REMOTE branch behind with no PR
#     ever opened to record it in installs[] and surface it to a later
#     eject. 'temperloop eject' must now ALSO make a best-effort attempt to
#     delete the branch on the remote, not just locally.
# =============================================================================
BARE19="$WORK/repo19-upstream.git"
REPO19="$WORK/repo19"
git init -q --bare --initial-branch=main "$BARE19"
git clone -q "$BARE19" "$REPO19" 2>/dev/null
git -C "$REPO19" commit -q --allow-empty -m init
git -C "$REPO19" push -q origin main 2>/dev/null
git -C "$REPO19" fetch -q origin

BEFORE_HEAD19="$(git -C "$REPO19" rev-parse HEAD)"
BEFORE_BRANCH19="$(git -C "$REPO19" branch --show-current)"
BEFORE_FIND19="$(find "$REPO19" -mindepth 1 -not -path '*/.git*' | sort)"

# Same non-network-flag reasoning as test 11: --no-network would skip Step 3
# outright, which is the very step this fixture needs init to reach and die
# inside.
FAKE_PR_CREATE_RC=1 run_init --dir "$REPO19" --gh-repo acme/widget
[ "$init_rc" -ne 0 ] || fail "19: test setup: expected the failed-pr-create init run to fail (got rc=0): $init_out"
grep -q "proposal-pr.sh failed" <<<"$init_out" || fail "19: test setup: init did not fail at the expected proposal-pr step (got: $init_out)"
[ "$(git -C "$REPO19" branch --show-current)" = "foundation-init/config" ] \
  || fail "19: test setup: expected the failed init run to leave the checkout on foundation-init/config"
[ -f "$REPO19/.temperloop/config" ] || fail "19: test setup: expected .temperloop/config committed locally despite the pr-create failure"
[ -f "$REPO19/.temperloop/.recovery.json" ] || fail "19: test setup: expected the recovery marker to survive the failed run"
# The load-bearing difference from test 11: the push itself REALLY landed on
# the bare upstream this time (real git, not the stubbed gh) -- proving the
# branch this test is about is genuinely remote, not merely local.
git --git-dir="$BARE19" show-ref --verify --quiet refs/heads/foundation-init/config \
  || fail "19: test setup: expected the push to have actually landed foundation-init/config on the bare upstream"

run 0 --dir "$REPO19" --yes
grep -q "restored 'main'" <<<"$out" || fail "19: eject did not report restoring the original branch (got: $out)"
grep -q "deleted stray 'foundation-init/config' (local)" <<<"$out" || fail "19: eject did not report deleting the stray LOCAL branch (got: $out)"
grep -qF "deleted stray 'foundation-init/config' (remote, acme/widget" <<<"$out" \
  || fail "19: eject did not report attempting the stray REMOTE branch cleanup (got: $out)"
[ "$(call_count 'api --method DELETE repos/acme/widget/git/refs/heads/foundation-init/config')" -ge 1 ] \
  || fail "19: eject did not call gh to delete the remote branch (log:\n$(cat "$CALL_LOG"))"
[ "$(git -C "$REPO19" branch --show-current)" = "$BEFORE_BRANCH19" ] \
  || fail "19: eject did not restore the original branch (on: $(git -C "$REPO19" branch --show-current))"
git -C "$REPO19" show-ref --verify --quiet refs/heads/foundation-init/config \
  && fail "19: eject did not delete the stray local branch"
[ ! -e "$REPO19/.temperloop" ] || fail "19: eject did not remove .temperloop/ residue"
[ "$(git -C "$REPO19" rev-parse HEAD)" = "$BEFORE_HEAD19" ] \
  || fail "19: eject left HEAD different from before the failed init run"
[ -z "$(git -C "$REPO19" status --porcelain)" ] \
  || fail "19: eject left an uncommitted/dirty tree (status: $(git -C "$REPO19" status --porcelain))"
AFTER_FIND19="$(find "$REPO19" -mindepth 1 -not -path '*/.git*' | sort)"
[ "$AFTER_FIND19" = "$BEFORE_FIND19" ] \
  || fail "19: eject left extra files behind (before:\n$BEFORE_FIND19\nafter:\n$AFTER_FIND19)"
echo "PASS: a real 'temperloop init' run whose push succeeds but whose 'gh pr create' fails leaves a REAL branch on the remote (not just local) plus a recovery marker; 'temperloop eject' now also makes a best-effort attempt to delete the remote branch, not just the local one"

echo
echo "ALL PASS: test_eject.sh"
