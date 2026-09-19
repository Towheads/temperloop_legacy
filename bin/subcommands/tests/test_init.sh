#!/usr/bin/env bash
#
# Tests for init.sh — `temperloop init` (foundation #765 Epic D "newcomer
# experience", item foundation-init / #854). Board/proposal-toolkit fixture
# style: a throwaway real-git bare upstream + clone, a stubbed `gh` on
# PATH that LOGS every call it sees (the write-intercepting-wrapper proof:
# a denied/dry-run action must leave ZERO mutating gh calls in the log),
# zero network, structured-output assertions via jq.
#
# SCOPE-DOWN (temperloop#796): `init` no longer applies ANY API state. Its
# job is bootstrap `.temperloop/config` (+ its proposal PR) -> offer/file the
# first epic -> print the handoff -> stop. The flags that used to gate the
# retired applies (--yes/--no-required-check, --yes/--no-labels,
# --yes/--no-board) are RETAINED as deprecated no-ops, each with a named
# removal window — an ADOPTER's own wrapper script may pass any of them
# (VERSIONING.md's CLI-surface contract row covers `bin/subcommands/*`), and
# init.sh exits 2 on an unknown arg, so removing one early would hard-fail
# callers that cannot be enumerated from inside this repo. Several cases
# below therefore assert the INVERSE of what they once did: the flag
# parses, a deprecation notice fires, and ZERO mutating gh calls result.
#
# REMOVAL (temperloop#524, epic "retire the Projects-v2/GraphQL arm"):
# `--provision-board` and `--tracker-mode` — the two flags scoped to the
# ADR-0004 Projects-arm removal — no longer parse at all. Each now exits
# non-zero with an error naming the removal release, not the generic
# "unknown arg" text.
#
# Covers:
#   - --dry-run + --no-network: tree-only preview, zero gh calls of any
#     kind (no api/label/project/pr create), config committed locally only
#   - --no-network gates the Step 3 proposal PR (temperloop#969): a
#     remote-less repo gets a `skipped — network disabled` notice and a
#     completed run, not a raw `git push failed` abort on an unfamiliar
#     branch. NOTE this is why the cases below that merely want the
#     first-epic offer out of the way no longer pass --no-network: closed
#     stdin already skips that offer (test 2's arm), and the flag now
#     suppresses the very proposal step most of them assert on.
#   - non-interactive: no --yes-* flag + closed stdin -> the first-epic
#     offer skips, zero mutating gh calls, and a handoff line still prints
#   - deprecated apply flags (--yes-required-check --yes-labels): each
#     emits a deprecation notice naming where the step went, and NEITHER
#     fires a single mutating gh call; installs[] carries only the
#     proposal_pr entry
#   - round-trip: re-running against the same repo re-reads the prior
#     .temperloop/config (schema 1) and carries a PRE-SCOPE-DOWN adopter's
#     recorded label/required_check/board installs forward untouched, so
#     `temperloop eject` can still revert them
#   - boards.conf integration: when workflows/scripts/board/ exists in the
#     target repo, the rendered board.<N>.* entry is proposed into its
#     boards.conf; a second run with the entry already present leaves it
#     untouched (idempotent)
#   - REGRESSION PIN (temperloop#793/#796): the rendered boards.conf entry
#     is COMPLETE — `board.<N>.backend=issues` present, the literal
#     "FILL IN" absent — in BOTH .tracker.boards_conf_entry and the
#     proposed boards.conf. The retired `projects` arm emitted a commented
#     `# board.<N>.project=<FILL IN ...>` placeholder before the apply step
#     and never reassigned it, so a fully-consented run still shipped a
#     dangling contract past a green suite.
#   - --yes-board (still deprecated, still parses): ZERO `gh project
#     create` calls, the notice fires, tracker.mode stays "issues"
#   - REMOVED-FLAGS REGRESSION (temperloop#524): --provision-board and
#     --tracker-mode no longer parse at all — each exits non-zero, the
#     error names the removal release, and zero gh calls of any kind fire
#   - the scoped-down contract end to end: --yes-first-epic files the epic,
#     applies zero API state, and hands off with the `next step:` marker
#   - the decline floor is the durable re-offer pointer ALONE — no inline
#     principles interview (it is the epic's own L0 now, deferred)
#   - HANDOFF PREREQUISITE PROBE: a `prerequisite:` line appears when
#     ~/.claude/commands/assess.md is absent and not when it is present,
#     while the `next step:` marker itself stays byte-identical in both
#     states (install-tier2.yml greps it on a runner that has no ~/.claude/)
#   - TOKENS PRODUCER PLACEMENT (temperloop#984): a repo with no
#     .temperloop/report.d/tokens gets the kernel's locator shim proposed
#     into the SAME files manifest as .temperloop/config — verbatim, mode
#     755, executable on disk, honoring the drop-in contract (exit 0 + one
#     skip line) when run in a stranger's repo with no kernel installed —
#     and NO new installs[] entry type appears (a tree artifact rides the
#     manifest; installs[] is API state eject reverts via gh)
#   - PRODUCER NEVER OVERWRITTEN: a pre-existing (adopter-owned) producer at
#     that path is byte-identical after `init`, and the proposal commit does
#     not touch it at all
#   - --tracker-mode with a bogus value hits the SAME removed-flag error as
#     a well-formed one, exit 2 — the old "must be issues or projects"
#     validation is gone with the flag, not just relocated
#   - --dir not a git repo -> exit 1
#   - ARGUMENT VALIDATION ORDERING: --base and --remote are BOTH refused
#     before the first git invocation that consumes them, so an
#     option-shaped `--upload-pack=<cmd>` payload on either argument of
#     `git fetch "$remote" "$base"` never executes
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INIT="$HERE/../init.sh"
# The kernel checkout's own copy of the shim — the canonical source `init`
# copies verbatim (bin/subcommands/init.sh § "TOKENS PRODUCER SHIM").
KERNEL_SRC="$(cd "$HERE/../../.." && pwd)"
SHIM_SRC="$KERNEL_SRC/.temperloop/report.d/tokens"
# The dual-build shim's own canonical source (temperloop#2084) — same
# treatment as SHIM_SRC above.
DUAL_BUILD_SHIM_SRC="$KERNEL_SRC/.temperloop/report.d/dual-build"

fail() { printf 'FAIL: %b\n' "$1" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@test \
       GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@test

WORK="$(mktemp -d "${TMPDIR:-/tmp}/init-test-XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

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

# --- fake gh: logs every call; a caller sets FAKE_GH_MODE to steer replies -
BIN="$WORK/bin"
mkdir -p "$BIN"
CALL_LOG="$WORK/gh-calls.log"
cat > "$BIN/gh" <<'FAKE_GH_EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALL_LOG"
case "$1" in
  api)
    # FAKE_SEARCH_422 (temperloop#1444) — reproduce the REAL failure shape
    # observed in install-tier2 run 31772670963: gh prints its error BODY
    # to STDOUT and exits non-zero. A consumer that fails open without
    # validating the captured value gets that JSON blob as its "issue
    # number".
    if [ -n "${FAKE_SEARCH_422:-}" ]; then
      case "$*" in
        *search/issues*)
          printf '%s' "{\"message\":\"Query must include 'is:issue' or 'is:pull-request'\",\"documentation_url\":\"https://docs.github.com/rest/search/search#search-issues-and-pull-requests\",\"status\":\"422\"}"
          exit 1
          ;;
      esac
    fi
    case "$*" in
      *branches/*/protection*required_status_checks*)
        exit "${FAKE_REQUIRED_CHECK_RC:-0}"
        ;;
      */branches/*/protection*)
        echo "HTTP 404" >&2
        exit 1
        ;;
      */labels*)
        printf '[]'
        exit 0
        ;;
      *search/issues*"design-brief: docs/adr/0010-onboarding-as-first-executed-epic.md"*)
        # Idempotency probe for an already-filed first epic (temperloop#781
        # handoff-lastness test). Real gh applies the caller's own --jq
        # '.items[0].number // empty' to the raw search response; since this
        # fake never runs jq, it just prints the number directly — the same
        # thing that filter would have produced.
        [ -n "${FAKE_EXISTING_EPIC_NUM:-}" ] && printf '%s' "$FAKE_EXISTING_EPIC_NUM"
        exit 0
        ;;
    esac
    exit 0
    ;;
  label)
    case "$2" in
      list)
        printf '%s\n' $FAKE_EXISTING_LABELS
        exit 0
        ;;
      create)
        exit 0
        ;;
    esac
    exit 0
    ;;
  project)
    case "$2" in
      create)
        echo "https://github.com/orgs/${FAKE_OWNER:-acme}/projects/${FAKE_PROJECT_NUM:-42}"
        exit 0
        ;;
    esac
    exit 0
    ;;
  issue)
    case "$2" in
      create)
        echo "https://github.com/${FAKE_GH_REPO:-acme/widget}/issues/${FAKE_ISSUE_NUM:-77}"
        exit 0
        ;;
    esac
    exit 0
    ;;
  pr)
    case "$2" in
      create)
        if [ -n "${FAKE_PR_EXISTS:-}" ]; then
          echo "a pull request for branch \"$FAKE_PR_BRANCH\" into branch \"main\" already exists: https://github.com/${FAKE_GH_REPO:-acme/widget}/pull/${FAKE_PR_NUM:-9}" >&2
          exit 1
        fi
        echo "https://github.com/${FAKE_GH_REPO:-acme/widget}/pull/${FAKE_PR_NUM:-9}"
        exit 0
        ;;
    esac
    exit 0
    ;;
esac
exit 0
FAKE_GH_EOF
chmod +x "$BIN/gh"

export CALL_LOG

# run WANT_RC ARGS... — invoke init.sh with the fake gh on PATH, closed
# stdin (proves the non-interactive default-deny path unless a test
# explicitly wants otherwise), asserts exit code. Sets $out.
run() {
  local want="$1"
  shift
  : > "$CALL_LOG"
  local rc=0
  out="$(PATH="$BIN:$PATH" \
    FAKE_GH_REPO="${FAKE_GH_REPO:-acme/widget}" \
    FAKE_PR_NUM="${FAKE_PR_NUM:-}" \
    FAKE_PR_EXISTS="${FAKE_PR_EXISTS:-}" \
    FAKE_PR_BRANCH="${FAKE_PR_BRANCH:-}" \
    FAKE_REQUIRED_CHECK_RC="${FAKE_REQUIRED_CHECK_RC:-0}" \
    FAKE_EXISTING_LABELS="${FAKE_EXISTING_LABELS:-}" \
    FAKE_OWNER="${FAKE_OWNER:-acme}" \
    FAKE_PROJECT_NUM="${FAKE_PROJECT_NUM:-42}" \
    FAKE_ISSUE_NUM="${FAKE_ISSUE_NUM:-77}" \
    FAKE_EXISTING_EPIC_NUM="${FAKE_EXISTING_EPIC_NUM:-}" \
    FAKE_SEARCH_422="${FAKE_SEARCH_422:-}" \
    HOME="${FAKE_HOME:-$HOME}" \
    CALL_LOG="$CALL_LOG" \
    bash "$INIT" "$@" </dev/null 2>&1)" && rc=0 || rc=$?
  [ "$rc" -eq "$want" ] || fail "expected rc=$want got rc=$rc for: $* -- output:\n$out"
}

call_count() {
  # call_count PATTERN — how many logged gh calls match (grep -c, fixed string)
  grep -Fc "$1" "$CALL_LOG" 2>/dev/null || true
}

# assert_no_mutating_gh LABEL — the scope-down's central invariant: `init`
# writes ZERO API state, whatever deprecated apply flags it was handed. A
# read-shaped `gh pr create` (the tree-only proposal step) and the
# first-epic `search/issues` idempotency probes are not API-state writes and
# are deliberately not covered here.
assert_no_mutating_gh() {
  local label="$1"
  grep -q "^label create" "$CALL_LOG" \
    && fail "$label: created a label (init applies no API state since temperloop#796)"
  grep -q "required_status_checks" "$CALL_LOG" \
    && fail "$label: wrote a required status check (init applies no API state since temperloop#796)"
  grep -q "^project create" "$CALL_LOG" \
    && fail "$label: provisioned a Projects-v2 board (dropped outright, temperloop#793)"
  return 0
}

# assert_probe_query_qualified LABEL — the temperloop#1444 API-contract
# guard. GitHub's search/issues endpoint REQUIRES an `is:issue` or
# `is:pull-request` qualifier and 422s without one. A fake `gh` cannot
# reproduce that (it answers whatever q= it is handed), so the only way a
# hermetic suite can pin the live query's validity is to assert the wire
# text of the q= this script actually sends. At least one probe must have
# fired, and EVERY probe that fired must carry the qualifier — an absent
# assertion here is exactly how the drift returned unseen.
assert_probe_query_qualified() {
  local label="$1" probes line
  probes="$(grep -F 'search/issues' "$CALL_LOG" || true)"
  [ -n "$probes" ] \
    || fail "$label: no search/issues idempotency probe was logged at all"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    grep -qF 'is:issue' <<<"$line" \
      || fail "$label: a search/issues probe omits the mandatory is:issue qualifier — GitHub 422s on this query:\n  $line"
  done <<<"$probes"
  return 0
}

# assert_complete_boards_entry LABEL ENTRY BOARD — the temperloop#793/#796
# regression pin. Every line the renderer emits must be a real,
# adapter-readable assignment; a commented `<FILL IN>` placeholder is
# exactly the dangling contract that survived a green suite before.
assert_complete_boards_entry() {
  local label="$1" entry="$2" board="$3"
  grep -q "board\.$board\.backend=issues" <<<"$entry" \
    || fail "$label: rendered entry missing board.$board.backend=issues (got: $entry)"
  grep -q "FILL IN" <<<"$entry" \
    && fail "$label: rendered entry still carries a 'FILL IN' placeholder (temperloop#793) (got: $entry)"
  return 0
}

# =============================================================================
# 1. --dry-run + --no-network: GENUINELY ZERO-WRITE (temperloop#413) — no
#    baseline.jsonl write, no .temperloop/config write, no commit, no
#    branch switch, and the target checkout is bit-identical (HEAD,
#    current branch, `git status --porcelain`, and the tree's file
#    listing all unchanged) before vs. after the dry run. Also zero gh
#    calls of any kind (unchanged from before this fix).
# =============================================================================
REPO1="$(new_fixture_repo repo1)"
BEFORE_HEAD="$(git -C "$REPO1" rev-parse HEAD)"
BEFORE_BRANCH="$(git -C "$REPO1" branch --show-current)"
BEFORE_STATUS="$(git -C "$REPO1" status --porcelain)"
BEFORE_FIND="$(find "$REPO1" -mindepth 1 -not -path '*/.git*' | sort)"

run 0 --dir "$REPO1" --gh-repo acme/widget --no-network --dry-run \
  --yes-required-check --yes-labels

[ ! -s "$CALL_LOG" ] || fail "dry-run made gh calls (should be zero):\n$(cat "$CALL_LOG")"
grep -q 'would create: .temperloop/config' <<<"$out" \
  || fail "dry-run did not print a tree-only preview of what it would write (got: $out)"
grep -q 'skipped (--dry-run — tree-only preview, no baseline write)' <<<"$out" \
  || fail "dry-run did not report the baseline snapshot as skipped (got: $out)"

AFTER_HEAD="$(git -C "$REPO1" rev-parse HEAD)"
AFTER_BRANCH="$(git -C "$REPO1" branch --show-current)"
AFTER_STATUS="$(git -C "$REPO1" status --porcelain)"
AFTER_FIND="$(find "$REPO1" -mindepth 1 -not -path '*/.git*' | sort)"

[ "$AFTER_HEAD" = "$BEFORE_HEAD" ] || fail "dry-run moved HEAD ($BEFORE_HEAD -> $AFTER_HEAD)"
[ "$AFTER_BRANCH" = "$BEFORE_BRANCH" ] || fail "dry-run switched branches ($BEFORE_BRANCH -> $AFTER_BRANCH)"
[ "$AFTER_STATUS" = "$BEFORE_STATUS" ] \
  || fail "dry-run left the working tree dirty (before status=[$BEFORE_STATUS] after status=[$AFTER_STATUS])"
[ "$AFTER_FIND" = "$BEFORE_FIND" ] \
  || fail "dry-run changed the tree's file listing (before:\n$BEFORE_FIND\nafter:\n$AFTER_FIND)"
[ ! -e "$REPO1/.temperloop/config" ] || fail "dry-run wrote .temperloop/config to disk"
[ ! -e "$REPO1/.temperloop/baseline.jsonl" ] \
  || fail "dry-run wrote .temperloop/baseline.jsonl (baseline snapshot must be gated by --dry-run)"
git -C "$REPO1" show HEAD:.temperloop/config >/dev/null 2>&1 \
  && fail "dry-run committed .temperloop/config locally (must be zero-write)"
echo "PASS: --dry-run + --no-network is genuinely zero-write — no baseline.jsonl, no .temperloop/config, no commit, HEAD/branch/tree bit-identical before vs. after, zero gh calls"

# =============================================================================
# 2. Non-interactive: no --yes-* flag, closed stdin -> the first-epic offer
#    skips (nobody answered, so nothing beyond the notice happens), zero
#    MUTATING gh calls, and the run still prints its handoff line. A
#    read-shaped `gh pr create` call still fires (the tree-only proposal
#    step is independent of the offer).
# =============================================================================
REPO2="$(new_fixture_repo repo2)"
FAKE_PR_NUM=20 run 0 --dir "$REPO2" --gh-repo acme/widget
assert_no_mutating_gh "non-interactive run"
grep -q "first-epic: skipped — no interactive operator detected" <<<"$out" \
  || fail "first-epic did not report the non-interactive skip (got: $out)"
grep -q "^next step: " <<<"$out" \
  || fail "run printed no handoff line (got: $out)"
echo "PASS: non-interactive, no --yes-* flags -> the first-epic offer skips, zero mutating gh calls, handoff still printed"

# =============================================================================
# 3. Deprecated apply flags: --yes-required-check --yes-labels still PARSE
#    (exit 0, never the exit-2 unknown-arg path), each emits a deprecation
#    notice naming where the step went, and NEITHER applies anything. The
#    only install this run mints is the proposal_pr self-record.
# =============================================================================
REPO3="$(new_fixture_repo repo3)"
FAKE_PR_NUM=21 run 0 --dir "$REPO3" --gh-repo acme/widget \
  --yes-required-check --yes-labels
assert_no_mutating_gh "deprecated --yes-required-check/--yes-labels"
grep -q "DEPRECATED — --yes-required-check" <<<"$out" \
  || fail "--yes-required-check fired no deprecation notice (got: $out)"
grep -q "DEPRECATED — --yes-labels" <<<"$out" \
  || fail "--yes-labels fired no deprecation notice (got: $out)"
grep -q "first epic" <<<"$out" \
  || fail "the required-check deprecation notice does not name where the step went (got: $out)"
grep -q '"outcome": "PR_OPENED"' <<<"$out" || fail "expected PR_OPENED outcome (got: $out)"

cfg="$(cat "$REPO3/.temperloop/config")"
[ "$(jq -r '.schema' <<<"$cfg")" = "1" ] || fail "landed config schema is not 1"
[ "$(jq -r '.tracker.mode' <<<"$cfg")" = "issues" ] || fail "landed config tracker.mode wrong"
[ "$(jq '[.installs[] | select(.type=="label" or .type=="required_check" or .type=="board")] | length' <<<"$cfg")" -eq 0 ] \
  || fail "installs[] recorded an API-state entry init no longer applies (got: $(jq -c '.installs' <<<"$cfg"))"
[ "$(jq -r '.installs[] | select(.type=="proposal_pr") | .pr_number' <<<"$cfg")" = "21" ] \
  || fail "installs[] missing/wrong proposal_pr entry (self-record second pass) (got: $(jq -c '.installs' <<<"$cfg"))"
assert_complete_boards_entry "deprecated-flags run" "$(jq -r '.tracker.boards_conf_entry' <<<"$cfg")" 1
echo "PASS: the deprecated apply flags parse, report where their step went, and apply nothing — installs[] carries only the proposal_pr self-record"

# =============================================================================
# 4. Round-trip + PRE-SCOPE-DOWN manifest carry-forward. A repo initialised
#    before temperloop#796 has real `label`/`required_check`/`board` entries
#    in its installs[]; `.temperloop/config`'s schema stays 1 and those
#    entries MUST survive a re-run untouched, because `temperloop eject`
#    still keeps all four handlers and is the only thing that can revert
#    that API state. Dropping them here would silently strand it.
# =============================================================================
legacy_cfg="$(jq -c '.installs = [
    {type:"label", repo:"acme/widget", name:"fnd:status:backlog"},
    {type:"required_check", repo:"acme/widget", branch:"main", name:"checks"},
    {type:"board", owner:"acme", project_number:99, url:"https://example.invalid/p/99"}
  ] + .installs' "$REPO3/.temperloop/config")"
printf '%s\n' "$legacy_cfg" > "$REPO3/.temperloop/config"
# Commit it: proposal-pr.sh re-creates the proposal branch fresh off the base
# tip on every run, which would refuse to run over an uncommitted change to a
# tracked file. init reads the config from the working tree before that.
git -C "$REPO3" add .temperloop/config
git -C "$REPO3" commit -q -m "seed a pre-scope-down install manifest"

FAKE_PR_EXISTS=1 FAKE_PR_BRANCH="foundation-init/config" FAKE_PR_NUM=21 \
  run 0 --dir "$REPO3" --gh-repo acme/widget --yes-required-check --yes-labels
grep -q "Found existing .temperloop/config (schema 1)" <<<"$out" \
  || fail "round-trip did not detect+re-read the existing config (got: $out)"
assert_no_mutating_gh "round-trip re-run"
cfg2="$(cat "$REPO3/.temperloop/config")"
[ "$(jq -r '.schema' <<<"$cfg2")" = "1" ] || fail "round-trip changed the config schema (must stay 1)"
[ "$(jq '[.installs[] | select(.type=="label")] | length' <<<"$cfg2")" -eq 1 ] \
  || fail "round-trip dropped the pre-scope-down label install (got: $(jq -c '.installs' <<<"$cfg2"))"
[ "$(jq '[.installs[] | select(.type=="required_check")] | length' <<<"$cfg2")" -eq 1 ] \
  || fail "round-trip dropped the pre-scope-down required_check install (got: $(jq -c '.installs' <<<"$cfg2"))"
[ "$(jq -r '.installs[] | select(.type=="board") | .project_number' <<<"$cfg2")" = "99" ] \
  || fail "round-trip dropped the pre-scope-down board install (got: $(jq -c '.installs' <<<"$cfg2"))"
echo "PASS: round-trip re-reads schema 1 and carries a PRE-SCOPE-DOWN adopter's label/required_check/board installs forward, so eject can still revert them"

# =============================================================================
# 5. boards.conf integration: board toolkit present -> proposes the entry;
#    a second run with it already present leaves boards.conf untouched.
#    Real (non-dry-run) runs, since --dry-run is now zero-write (#413) and
#    no longer commits anything locally to inspect via `git show` — that
#    invariant is covered by test 1 above; this test's own job is the
#    boards.conf proposal + idempotent-re-run logic, unrelated to dry-run.
# =============================================================================
REPO5="$(new_fixture_repo repo5)"
mkdir -p "$REPO5/workflows/scripts/board"
echo "# marker" > "$REPO5/workflows/scripts/board/marker.txt"
git -C "$REPO5" add -A && git -C "$REPO5" commit -q -m "seed board toolkit"
FAKE_PR_NUM=22 run 0 --dir "$REPO5" --gh-repo acme/widget
proposed_conf="$(git -C "$REPO5" show HEAD:workflows/scripts/board/boards.conf 2>/dev/null || true)"
grep -q "board.1.repo=acme/widget" <<<"$proposed_conf" \
  || fail "boards.conf entry was not proposed when the board toolkit is present"
# REGRESSION PIN (temperloop#793/#796) — the PROPOSED boards.conf half.
assert_complete_boards_entry "proposed boards.conf" "$proposed_conf" 1
# ...and the .temperloop/config half, the surface an operator hand-applies
# from when the board toolkit is NOT present. Both are pinned because the
# retired projects arm poisoned both at once.
assert_complete_boards_entry "config tracker.boards_conf_entry" \
  "$(jq -r '.tracker.boards_conf_entry' "$REPO5/.temperloop/config")" 1

# IDEMPOTENT RE-RUN. This assertion used to read `grep "already present —
# leaving"` and nothing else — it asserted a LOG LINE while the file it
# claimed was being left alone was in fact being deleted (the manifest
# omitted it, and the branch re-cut off a base that never carried it dropped
# it). Assert the substantive invariant instead: after a second run the
# proposed boards.conf is still there and still byte-identical. Test 16
# covers the same property for both optional entries together.
FAKE_PR_EXISTS=1 FAKE_PR_BRANCH="foundation-init/config" FAKE_PR_NUM=22 \
  run 0 --dir "$REPO5" --gh-repo acme/widget
reproposed_conf="$(git -C "$REPO5" show HEAD:workflows/scripts/board/boards.conf 2>/dev/null || true)"
[ -n "$reproposed_conf" ] \
  || fail "the second run DROPPED boards.conf from the proposal (got: $out)"
[ "$reproposed_conf" = "$proposed_conf" ] \
  || fail "the second run changed boards.conf instead of carrying it forward verbatim:\n  run1: $proposed_conf\n  run2: $reproposed_conf"
assert_complete_boards_entry "re-proposed boards.conf" "$reproposed_conf" 1

# ...and the genuine nothing-to-do case, which is the entry being on the BASE
# tip (not merely in the working tree): push the proposal to main and re-run.
# Only here is "leaving it untouched" the truthful thing to print, because
# only here does the freshly-cut proposal branch already carry it.
git -C "$REPO5" push -q origin "HEAD:main" \
  || fail "could not push the proposed boards.conf to the fixture's origin/main"
git -C "$REPO5" fetch -q origin
FAKE_PR_EXISTS=1 FAKE_PR_BRANCH="foundation-init/config" FAKE_PR_NUM=22 \
  run 0 --dir "$REPO5" --gh-repo acme/widget
grep -qF "already on main — leaving workflows/scripts/board/boards.conf untouched" <<<"$out" \
  || fail "with the entry already on the base branch, init did not report leaving boards.conf untouched (got: $out)"
settled_conf="$(git -C "$REPO5" show HEAD:workflows/scripts/board/boards.conf 2>/dev/null || true)"
[ "$settled_conf" = "$proposed_conf" ] \
  || fail "boards.conf changed once the entry was already on the base branch"
echo "PASS: boards.conf integration proposes a COMPLETE rendered entry, carries it forward verbatim on a re-run (never dropping it), and reports nothing-to-do only once it is on the base tip"

# =============================================================================
# 6. --yes-board ALONE: still a deprecated no-op (temperloop#793 dropped
#    board provisioning from init outright). The flag still parses — exit
#    0, never the exit-2 unknown-arg path — reports its deprecation, ZERO
#    `gh project create` calls fire, and the rendered entry stays complete.
#    (Previously this case also carried --tracker-mode projects and
#    --provision-board; those two no longer parse at all — see test 7.)
# =============================================================================
REPO6="$(new_fixture_repo repo6)"
FAKE_PR_NUM=23 FAKE_OWNER=acme FAKE_PROJECT_NUM=99 \
  run 0 --dir "$REPO6" --gh-repo acme/widget --yes-board
[ "$(call_count 'project create')" -eq 0 ] \
  || fail "board provisioning still fired: $(call_count 'project create') 'project create' call(s) (temperloop#793 dropped it)"
assert_no_mutating_gh "--yes-board"
grep -q "DEPRECATED — --yes-board" <<<"$out" \
  || fail "--yes-board fired no deprecation notice (got: $out)"
cfg6="$(cat "$REPO6/.temperloop/config")"
[ "$(jq -r '.tracker.mode' <<<"$cfg6")" = "issues" ] \
  || fail "tracker.mode was not issues (got: $(jq -r '.tracker.mode' <<<"$cfg6"))"
[ "$(jq '[.installs[] | select(.type=="board")] | length' <<<"$cfg6")" -eq 0 ] \
  || fail "a board install entry was recorded (got: $(jq -c '.installs' <<<"$cfg6"))"
assert_complete_boards_entry "--yes-board run" "$(jq -r '.tracker.boards_conf_entry' <<<"$cfg6")" 1
echo "PASS: --yes-board parses standalone, reports its deprecation, provisions nothing, and the rendered entry stays complete"

# =============================================================================
# 7. REMOVED-FLAGS REGRESSION (temperloop#524, epic "retire the
#    Projects-v2/GraphQL arm" — this item, init-cli-retire-projects-flags):
#    the board-provisioning flag and --tracker-mode no longer parse AT
#    ALL. Each exits non-zero (2, the CLI-usage-error code) with a message
#    that NAMES THE REMOVAL — not the generic "unknown arg" text a caller
#    would get for a flag that was never real — and zero gh calls of any
#    kind fire, since parsing fails before any gh invocation is reachable.
#    The board-provisioning flag is caught by a `--provision-*` PREFIX
#    match (its one historic exact spelling lives on in bin/README.md's
#    compat table, deliberately not repeated in init.sh's own source — see
#    that script's "REMOVED FLAGS" header note) rather than one exact
#    string, so a second case below pins that the whole family is caught,
#    not just the one name this repo's own history happened to use.
# =============================================================================
REPO7="$(new_fixture_repo repo7)"
run 2 --dir "$REPO7" --gh-repo acme/widget --provision-board
[ -s "$CALL_LOG" ] \
  && fail "--provision-board: a gh call fired before the removed-flag error should have stopped parsing (log: $(cat "$CALL_LOG"))"
grep -qF "init.sh: unknown arg: --provision-board" <<<"$out" \
  && fail "--provision-board fell through to the generic unknown-arg error instead of naming its removal (got: $out)"
grep -qF "'--provision-board' was removed" <<<"$out" \
  || fail "--provision-board's error does not say it was removed, echoing back what was typed (got: $out)"
grep -qF "ADR 0004, epic #524" <<<"$out" \
  || fail "--provision-board's error does not name the removal release (ADR 0004, epic #524) (got: $out)"

# A DIFFERENT member of the same retired flag family — proves the match is
# a PREFIX, not one hardcoded exact string, and that the error echoes back
# whatever the caller actually typed.
run 2 --dir "$REPO7" --gh-repo acme/widget --provision-labels
grep -qF "'--provision-labels' was removed" <<<"$out" \
  || fail "a sibling --provision-* flag was not caught by the prefix match and named back correctly (got: $out)"

run 2 --dir "$REPO7" --gh-repo acme/widget --tracker-mode issues
[ -s "$CALL_LOG" ] \
  && fail "--tracker-mode: a gh call fired before the removed-flag error should have stopped parsing (log: $(cat "$CALL_LOG"))"
grep -qF "init.sh: unknown arg: --tracker-mode" <<<"$out" \
  && fail "--tracker-mode fell through to the generic unknown-arg error instead of naming its removal (got: $out)"
grep -qi "tracker-mode.*removed" <<<"$out" \
  || fail "--tracker-mode's error does not say it was removed (got: $out)"
grep -qF "ADR 0004, epic #524" <<<"$out" \
  || fail "--tracker-mode's error does not name the removal release (ADR 0004, epic #524) (got: $out)"
echo "PASS: the board-provisioning flag family (--provision-*) and --tracker-mode no longer parse; both exit 2 naming the removal release (ADR 0004, epic #524), echoing back what was typed, not the generic unknown-arg error"

# =============================================================================
# 8. THE SCOPED-DOWN CONTRACT END TO END (temperloop#796): --yes-first-epic
#    -> the epic is filed, the run HANDS OFF to /assess and STOPS. It must
#    apply zero API state on the way, and the `next step:` handoff marker
#    (what .github/workflows/install-tier2.yml greps for) must name the
#    filed epic number.
# =============================================================================
REPO8="$(new_fixture_repo repo8)"
FAKE_PR_NUM=25 FAKE_ISSUE_NUM=77 \
  run 0 --dir "$REPO8" --gh-repo acme/widget --yes-first-epic
[ "$(call_count 'issue create')" -eq 1 ] \
  || fail "expected exactly 1 'issue create' (the first epic), got $(call_count 'issue create')"
assert_no_mutating_gh "--yes-first-epic"
grep -q "first-epic: filed .*#77" <<<"$out" \
  || fail "first-epic was not reported as filed (got: $out)"
grep -q "^next step: /assess --epic 77" <<<"$out" \
  || fail "handoff line missing or does not name the filed epic (got: $out)"
grep -q "temperloop init: done" <<<"$out" || fail "run did not reach its closing line (got: $out)"
echo "PASS: --yes-first-epic files the epic, applies zero API state, and hands off with 'next step: /assess --epic <N>'"

# =============================================================================
# 8b. THE HANDOFF BOX IS THE TRUE LAST THING PRINTED (temperloop#781):
#     `temperloop init: done` now prints BEFORE the closing handoff box, not
#     after — so the operator's scrollback ends on the actionable handoff
#     (a visually distinct "not finished" banner + the exact launch-Claude
#     command + the exact `/assess --epic N` invocation + the full,
#     never-truncated epic URL), never on the bare done marker. This
#     inspects the actual TAIL of $out (reused from test 8 above, before
#     any later run() call overwrites it) rather than just asserting
#     presence anywhere in the output.
# =============================================================================
last_nonblank="$(printf '%s\n' "$out" | sed '/^[[:space:]]*$/d' | tail -1)"
[ "$last_nonblank" != "temperloop init: done" ] \
  || fail "'temperloop init: done' is the LAST line printed — the handoff box must be last (got tail: $last_nonblank)"
grep -qF '====' <<<"$last_nonblank" \
  || fail "the last non-blank line is not the handoff box's closing border (got: $last_nonblank)"
done_line="$(printf '%s\n' "$out" | grep -n '^temperloop init: done$' | tail -1 | cut -d: -f1)"
handoff_hdr_line="$(printf '%s\n' "$out" | grep -n '^-- 5\. Handoff --$' | tail -1 | cut -d: -f1)"
[ -n "$done_line" ] && [ -n "$handoff_hdr_line" ] \
  || fail "could not locate both 'temperloop init: done' and the Handoff header in output (got: $out)"
[ "$done_line" -lt "$handoff_hdr_line" ] \
  || fail "'temperloop init: done' (output line $done_line) does not precede the Handoff block (output line $handoff_hdr_line) — it must print BEFORE, never after"
grep -qF "    claude" <<<"$out" \
  || fail "handoff box missing the exact command to launch Claude Code in this repo (got: $out)"
grep -qF "Epic: https://github.com/acme/widget/issues/77" <<<"$out" \
  || fail "handoff box missing the full (never-truncated) epic URL (got: $out)"
grep -qi "NOT FINISHED" <<<"$out" \
  || fail "handoff box does not state that configuration is not finished (got: $out)"
echo "PASS: the handoff box is the LAST thing printed — 'temperloop init: done' now precedes it, and the box carries the not-finished framing, the launch command, the exact /assess invocation, and the full epic URL"

# =============================================================================
# 9. Decline floor is the POINTER ALONE (temperloop#796, ADR 0010 amended):
#    --no-first-epic files the durable re-offer pointer and runs NO inline
#    principles interview — the interview is the epic's own L0, deferred.
#    Closed stdin proves it: the retired inline interview read from stdin,
#    so a run that still attempted it would take the empty-answer path and
#    print its own interview banner.
# =============================================================================
REPO9="$(new_fixture_repo repo9)"
FAKE_PR_NUM=26 FAKE_ISSUE_NUM=88 \
  run 0 --dir "$REPO9" --gh-repo acme/widget --no-first-epic
grep -q "first-epic: declined" <<<"$out" || fail "decline was not reported (got: $out)"
grep -q "filed durable re-offer pointer .*#88" <<<"$out" \
  || fail "decline did not file the durable re-offer pointer (got: $out)"
grep -q "Inline principles interview" <<<"$out" \
  && fail "decline still ran the retired INLINE principles interview banner (got: $out)"
grep -q "Do you have existing engineering conventions" <<<"$out" \
  && fail "decline still asked the retired inline A1 principles question (got: $out)"
grep -q "^next step: " <<<"$out" || fail "decline printed no handoff line (got: $out)"
echo "PASS: declining files the durable re-offer pointer as the WHOLE floor — no inline principles interview, handoff still printed"

# =============================================================================
# 10. HANDOFF PREREQUISITE PROBE. `/assess` and `/build` only exist on a
#     machine that ran `temperloop install` (which symlinks claude/* into
#     ~/.claude/), but the try -> try --demo -> init ladder otherwise needs
#     no machine-wide setup — so a stranger can reach the handoff with no
#     ~/.claude/commands/ at all. init probes for it and adds a
#     `prerequisite:` line when it's missing.
#
#     The load-bearing assertion is the one that holds in BOTH states: the
#     `next step: /assess --epic <N>` line is byte-identical either way.
#     .github/workflows/install-tier2.yml greps exactly that line on a CI
#     runner (where ~/.claude/ does NOT exist), so a probe that rewrote the
#     marker instead of adding a line would silently break that gate.
# =============================================================================
REPO10A="$(new_fixture_repo repo10a)"
FAKE_HOME="$WORK/home-no-install" && mkdir -p "$FAKE_HOME"
FAKE_HOME="$FAKE_HOME" FAKE_PR_NUM=27 FAKE_ISSUE_NUM=91 \
  run 0 --dir "$REPO10A" --gh-repo acme/widget --yes-first-epic
handoff_uninstalled="$(printf '%s\n' "$out" | grep '^next step: ' || true)"
grep -q '^next step: /assess --epic 91' <<<"$out" \
  || fail "uninstalled probe changed the stable handoff marker (got: $out)"
grep -q '^prerequisite: .*temperloop install' <<<"$out" \
  || fail "no prerequisite line when ~/.claude/commands/assess.md is absent (got: $out)"

REPO10B="$(new_fixture_repo repo10b)"
FAKE_HOME_INSTALLED="$WORK/home-installed"
mkdir -p "$FAKE_HOME_INSTALLED/.claude/commands"
echo "# assess" > "$FAKE_HOME_INSTALLED/.claude/commands/assess.md"
FAKE_HOME="$FAKE_HOME_INSTALLED" FAKE_PR_NUM=28 FAKE_ISSUE_NUM=91 \
  run 0 --dir "$REPO10B" --gh-repo acme/widget --yes-first-epic
handoff_installed="$(printf '%s\n' "$out" | grep '^next step: ' || true)"
grep -q '^prerequisite: ' <<<"$out" \
  && fail "prerequisite line printed even though ~/.claude/commands/assess.md exists (got: $out)"
[ "$handoff_installed" = "$handoff_uninstalled" ] \
  || fail "the 'next step:' marker differs between the installed and uninstalled probe states — install-tier2.yml greps it on a runner with no ~/.claude/:\n  installed:   $handoff_installed\n  uninstalled: $handoff_uninstalled"
echo "PASS: the handoff names its \`temperloop install\` prerequisite when /assess isn't installed, and the 'next step:' marker itself is byte-identical in both states"

# =============================================================================
# 11. --tracker-mode with a BOGUS value hits the SAME removed-flag error as
#     a well-formed one, exit 2. The old "must be issues or projects"
#     validation is GONE along with the flag, not merely relocated behind
#     it — this pins that a bogus value doesn't resurrect the old message.
# =============================================================================
REPO10="$(new_fixture_repo repo10)"
run 2 --dir "$REPO10" --tracker-mode bogus
grep -qi "tracker-mode.*removed" <<<"$out" \
  || fail "bogus --tracker-mode value did not hit the removed-flag error (got: $out)"
grep -qi "must be 'issues' or 'projects'" <<<"$out" \
  && fail "the old --tracker-mode value-validation message resurfaced instead of the removed-flag error (got: $out)"
echo "PASS: --tracker-mode is refused with exit 2 regardless of its value, and names the removal rather than the old value-validation message"

# =============================================================================
# 12. --dir not a git repo -> exit 1
# =============================================================================
mkdir -p "$WORK/not-a-repo"
run 1 --dir "$WORK/not-a-repo"
grep -qi "not a git working tree" <<<"$out" || fail "non-repo --dir error message unclear (got: $out)"
echo "PASS: --dir pointing outside a git working tree is refused with exit 1"

# =============================================================================
# 13. THE HANDOFF RECOVERS ON THE IDEMPOTENT ALREADY-FILED PATH (temperloop
#     #781): an operator who lost the first run's scrollback re-runs `init`
#     and must get the SAME actionable handoff — not just a bare "already
#     filed" notice. The search/issues idempotency probe (design-brief
#     marker) reports the epic as already filed via FAKE_EXISTING_EPIC_NUM;
#     `init` must recover the full epic URL (constructed from $gh_repo,
#     since the idempotency probe only ever returns a NUMBER) and print the
#     identical handoff box, with zero new 'issue create' calls.
# =============================================================================
REPO13="$(new_fixture_repo repo13)"
FAKE_EXISTING_EPIC_NUM=77 FAKE_PR_NUM=29 \
  run 0 --dir "$REPO13" --gh-repo acme/widget
[ "$(call_count 'issue create')" -eq 0 ] \
  || fail "idempotent already-filed path re-filed the epic: $(call_count 'issue create') 'issue create' call(s)"
grep -q "first-epic: already filed as #77" <<<"$out" \
  || fail "the already-filed idempotency notice did not fire (got: $out)"
# API-CONTRACT GUARD (temperloop#1444). This case validated the MESSAGE
# SHAPE against a fake gh and nothing else, which is precisely why the
# broken query shipped: the fake answers any q= at all. Assert the wire
# query itself — GitHub's search/issues 422s without an `is:issue` /
# `is:pull-request` qualifier, so a probe missing it can never hit.
assert_probe_query_qualified "already-filed probe"
grep -q "^next step: /assess --epic 77" <<<"$out" \
  || fail "idempotent re-run's handoff marker missing or does not name the existing epic (got: $out)"
grep -qF "Epic: https://github.com/acme/widget/issues/77" <<<"$out" \
  || fail "idempotent re-run did not recover the full epic URL for the recovery handoff (got: $out)"
grep -qF "    claude" <<<"$out" \
  || fail "idempotent re-run's handoff box missing the launch-Claude-Code command (got: $out)"
last_nonblank13="$(printf '%s\n' "$out" | sed '/^[[:space:]]*$/d' | tail -1)"
[ "$last_nonblank13" != "temperloop init: done" ] \
  || fail "idempotent re-run: 'temperloop init: done' is the LAST line printed — the handoff box must be last"
grep -qF '====' <<<"$last_nonblank13" \
  || fail "idempotent re-run: the last non-blank line is not the handoff box's closing border (got: $last_nonblank13)"
echo "PASS: the idempotent already-filed path recovers the same actionable handoff (full epic URL + launch command), last, with zero re-filed issues"

# =============================================================================
# 14. THE TOKENS PRODUCER IS PLACED (temperloop#984). `temperloop report`'s
#     headline metric comes from a drop-in producer at
#     .temperloop/report.d/tokens; nothing placed it before this item, so
#     the headline was silently unavailable in every repo except the kernel
#     checkout itself. `init` now proposes it in the SAME files manifest
#     .temperloop/config already rides.
#
#     Four things are pinned, because each has its own way of silently
#     half-working: the content is a VERBATIM copy of the kernel's shim (a
#     restated second copy would drift); the git mode is 100755 and the file
#     is executable ON DISK (report.sh only runs executables — a 644
#     producer renders as "skipped" and the headline degrades with no
#     error); the placed copy actually SATISFIES the drop-in contract when
#     run in a stranger's repo with no kernel installed (exit 0, one skip
#     line, nothing else); and installs[] gains NO new entry type (a tree
#     artifact is reverted by the tree — installs[] is the API-state set
#     eject reverts via `gh`).
#
#     Non-interactivity needs no separate assertion: run() closes stdin, so
#     a prompt added anywhere on this path would hang or take an empty
#     answer, and closed stdin is itself what makes the first-epic offer —
#     the one interactive step init has — skip outright (the same
#     "no interactive operator detected" arm test 2 pins).
# =============================================================================
REPO14="$(new_fixture_repo repo14)"
FAKE_PR_NUM=30 run 0 --dir "$REPO14" --gh-repo acme/widget
grep -qF "report.d producer: proposing .temperloop/report.d/tokens (mode 755)" <<<"$out" \
  || fail "init did not report proposing the tokens producer (got: $out)"

P14="$REPO14/.temperloop/report.d/tokens"
[ -f "$P14" ] || fail "init did not place .temperloop/report.d/tokens into the target repo"
git -C "$REPO14" show "HEAD:.temperloop/report.d/tokens" > "$WORK/landed14" 2>/dev/null \
  || fail "the tokens producer was not committed by the proposal (not in HEAD)"
# BYTE-EXACT, `cmp` not `$(…)` (temperloop#992). This used to compare through
# a pair of `$(…)` captures that stripped trailing newlines on both sides,
# because proposal-pr.sh re-read every manifest entry's content through its
# own capture and wrote it with a bare `printf '%s'` — so the landed copy was
# always the source MINUS its final newline. The generator now normalizes each
# entry to exactly one final newline, and the shim source ends in exactly one,
# so "verbatim copy" is now literally true and the assertion says so —
# including the final byte a stranger's first proposal diff used to flag with
# "\ No newline at end of file".
cmp -s "$WORK/landed14" "$SHIM_SRC" \
  || fail "the landed producer is not a byte-exact copy of the kernel shim at $SHIM_SRC (tail: $(od -c < "$WORK/landed14" | tail -3))"

mode14="$(git -C "$REPO14" ls-tree HEAD .temperloop/report.d/tokens | awk '{print $1}')"
[ "$mode14" = "100755" ] \
  || fail "the landed producer is not committed executable (git mode $mode14, want 100755) — report.sh only runs executables"
[ -x "$P14" ] || fail "the landed producer is not executable on disk"

# The placed copy honors the drop-in contract in a STRANGER's repo: no
# TEMPERLOOP_HOME, a PATH with no `temperloop`, and no workflows/ tree for
# the shim's self-checkout resolver to find -> exit 0 and exactly the
# contract's skip line, never a stack trace or a non-zero exit.
prc=0
producer_out="$(cd "$REPO14" && env -u TEMPERLOOP_HOME PATH=/usr/bin:/bin \
  ./.temperloop/report.d/tokens 2>&1)" || prc=$?
[ "$prc" -eq 0 ] \
  || fail "the placed producer exited $prc in a kernel-less repo (the drop-in contract requires exit 0) — output: $producer_out"
grep -qF "skipped -- tokens: producer unavailable" <<<"$producer_out" \
  || fail "the placed producer did not emit the contract's skip line in a kernel-less repo (got: $producer_out)"

[ "$(jq '[.installs[] | select(.type != "proposal_pr")] | length' "$REPO14/.temperloop/config")" -eq 0 ] \
  || fail "placing the producer minted a non-proposal_pr installs[] entry — a TREE artifact rides the files manifest, never installs[] (got: $(jq -c '.installs' "$REPO14/.temperloop/config"))"
echo "PASS: init proposes the tokens producer shim verbatim at mode 755, executable, contract-honoring in a kernel-less repo, with no new installs[] entry type"

# =============================================================================
# 14b. THE SAME RUN ALSO PLACES THE DUAL-BUILD PRODUCER SHIM (temperloop
#      #2084, epic #2065 "new-work dual-build harness"). Same run as test 14
#      above, same manifest, same byte-exact-copy/mode-755/soft-seam/no-new-
#      installs-entry properties — asserted here for the SECOND shim init
#      wires unconditionally (unlike model-comparison's own inert shim,
#      ADR 0027 — see bin/subcommands/init.sh's "DUAL-BUILD PRODUCER SHIM"
#      header note for why that is still zero standing cost).
# =============================================================================
grep -qF "report.d producer: proposing .temperloop/report.d/dual-build (mode 755)" <<<"$out" \
  || fail "the same run did not report proposing the dual-build producer (got: $out)"

DBP14="$REPO14/.temperloop/report.d/dual-build"
[ -f "$DBP14" ] || fail "init did not place .temperloop/report.d/dual-build into the target repo"
git -C "$REPO14" show "HEAD:.temperloop/report.d/dual-build" > "$WORK/dblanded14" 2>/dev/null \
  || fail "the dual-build producer was not committed by the proposal (not in HEAD)"
cmp -s "$WORK/dblanded14" "$DUAL_BUILD_SHIM_SRC" \
  || fail "the landed dual-build producer is not a byte-exact copy of the kernel shim at $DUAL_BUILD_SHIM_SRC"

dbmode14="$(git -C "$REPO14" ls-tree HEAD .temperloop/report.d/dual-build | awk '{print $1}')"
[ "$dbmode14" = "100755" ] \
  || fail "the landed dual-build producer is not committed executable (git mode $dbmode14, want 100755)"
[ -x "$DBP14" ] || fail "the landed dual-build producer is not executable on disk"

dbprc=0
dbproducer_out="$(cd "$REPO14" && env -u TEMPERLOOP_HOME PATH=/usr/bin:/bin \
  ./.temperloop/report.d/dual-build 2>&1)" || dbprc=$?
[ "$dbprc" -eq 0 ] \
  || fail "the placed dual-build producer exited $dbprc in a kernel-less repo — output: $dbproducer_out"
grep -qF "skipped -- dual-build: producer unavailable" <<<"$dbproducer_out" \
  || fail "the placed dual-build producer did not emit the contract's skip line in a kernel-less repo (got: $dbproducer_out)"

[ "$(jq '[.installs[] | select(.type != "proposal_pr")] | length' "$REPO14/.temperloop/config")" -eq 0 ] \
  || fail "placing the dual-build producer minted a non-proposal_pr installs[] entry (got: $(jq -c '.installs' "$REPO14/.temperloop/config"))"
echo "PASS: the same run also proposes the dual-build producer shim verbatim at mode 755, executable, contract-honoring in a kernel-less repo, with no new installs[] entry type"

# =============================================================================
# 15. AN EXISTING PRODUCER IS NEVER OVERWRITTEN (temperloop#984). A producer
#     already at that path belongs to the ADOPTER — hand-written, or edited
#     after an earlier `init`. Silently clobbering it would destroy work
#     `init` has no standing to touch, with no undo. Present -> leave it
#     byte-for-byte alone, say so, and don't even include it in the
#     proposal commit.
#
#     The sentinel is pushed to the fixture's origin/main on purpose:
#     proposal-pr.sh re-creates the proposal branch fresh off the BASE tip
#     (preferring refs/remotes/origin/<base>), so a seed that only existed
#     as a local commit would vanish from the working tree for a reason
#     that has nothing to do with overwriting — and the test would pass or
#     fail for the wrong reason.
# =============================================================================
REPO15="$(new_fixture_repo repo15)"
mkdir -p "$REPO15/.temperloop/report.d"
cat > "$REPO15/.temperloop/report.d/tokens" <<'ADOPTER_PRODUCER_EOF'
#!/usr/bin/env bash
# An adopter's OWN tokens producer. `temperloop init` must never touch this.
echo '{"tokens_spent": 4242}'
ADOPTER_PRODUCER_EOF
chmod 755 "$REPO15/.temperloop/report.d/tokens"
cp "$REPO15/.temperloop/report.d/tokens" "$WORK/producer15.before"
# Seed an adopter-owned dual-build producer too (temperloop#2084) — the
# SAME rule 1 the tokens shim just above exercises applies to BOTH shims
# independently, and without this second seed the bare "proposing" absence
# assertion below would trip on dual-build's own (unrelated) fresh proposal.
cat > "$REPO15/.temperloop/report.d/dual-build" <<'ADOPTER_DUAL_BUILD_PRODUCER_EOF'
#!/usr/bin/env bash
# An adopter's OWN dual-build producer. `temperloop init` must never touch this.
echo '{"producer": "dual-build", "tiers": []}'
ADOPTER_DUAL_BUILD_PRODUCER_EOF
chmod 755 "$REPO15/.temperloop/report.d/dual-build"
cp "$REPO15/.temperloop/report.d/dual-build" "$WORK/dbproducer15.before"
git -C "$REPO15" add -A
git -C "$REPO15" commit -q -m "seed adopter-owned tokens + dual-build producers"
# No `2>/dev/null` here: this push is load-bearing for the test's validity
# (see the comment above), and under `set -euo pipefail` a swallowed failure
# would abort the whole suite with no diagnostic at all.
git -C "$REPO15" push -q origin main \
  || fail "could not push the seeded producer to the fixture's origin/main (the test's own precondition)"
git -C "$REPO15" fetch -q origin

FAKE_PR_NUM=31 run 0 --dir "$REPO15" --gh-repo acme/widget
grep -qF "report.d producer: .temperloop/report.d/tokens already on main — leaving it untouched" <<<"$out" \
  || fail "init did not report skipping the pre-existing producer (got: $out)"
grep -qF "report.d producer: proposing" <<<"$out" \
  && fail "init proposed the producer even though one was already present (got: $out)"

cmp -s "$WORK/producer15.before" "$REPO15/.temperloop/report.d/tokens" \
  || fail "init OVERWROTE a pre-existing tokens producer — it must be byte-identical after the run"
git -C "$REPO15" show --name-only --format= HEAD | grep -F ".temperloop/report.d/tokens" >/dev/null \
  && fail "the proposal commit touched the pre-existing tokens producer (it must not appear in the diff at all)"
mode15="$(git -C "$REPO15" ls-tree HEAD .temperloop/report.d/tokens | awk '{print $1}')"
[ "$mode15" = "100755" ] || fail "the pre-existing producer's mode changed (git mode $mode15, want 100755)"

grep -qF "report.d producer: .temperloop/report.d/dual-build already on main — leaving it untouched" <<<"$out" \
  || fail "init did not report skipping the pre-existing dual-build producer (got: $out)"
cmp -s "$WORK/dbproducer15.before" "$REPO15/.temperloop/report.d/dual-build" \
  || fail "init OVERWROTE a pre-existing dual-build producer — it must be byte-identical after the run"
git -C "$REPO15" show --name-only --format= HEAD | grep -F ".temperloop/report.d/dual-build" >/dev/null \
  && fail "the proposal commit touched the pre-existing dual-build producer (it must not appear in the diff at all)"
dbmode15="$(git -C "$REPO15" ls-tree HEAD .temperloop/report.d/dual-build | awk '{print $1}')"
[ "$dbmode15" = "100755" ] || fail "the pre-existing dual-build producer's mode changed (git mode $dbmode15, want 100755)"
echo "PASS: a pre-existing tokens producer is byte-identical after init, absent from the proposal commit, and its mode is unchanged"
echo "PASS: a pre-existing dual-build producer gets the identical rule-1 treatment (byte-identical, absent from the commit, mode unchanged)"

# =============================================================================
# 16. THE IDEMPOTENT RE-RUN KEEPS WHAT RUN 1 PROPOSED (the blocking defect).
#
#     proposal-pr.sh re-creates the proposal branch FRESH off the base tip
#     every run, so the manifest is a diff against BASE, not against whatever
#     is checked out. Deciding an optional entry from the WORKING TREE
#     therefore deleted it on run 2: after run 1 the checkout sits on the
#     proposal branch carrying the file, run 2's tree probe saw it, "skipped"
#     it out of the manifest, and the re-cut branch (off a base that never
#     had it) dropped it — while printing "leaving it untouched", and
#     force-pushing that regression over the open PR.
#
#     Both optional entries had the bug and both are asserted here, because
#     they now share one base-tip decision path: the producer AND boards.conf
#     must still be present, byte-identical, and in the proposal commit after
#     a second consecutive `init` in the same repo. No test covered a second
#     run in one repo before, which is exactly why the suite couldn't see it.
# =============================================================================
REPO16="$(new_fixture_repo repo16)"
mkdir -p "$REPO16/workflows/scripts/board"
echo "# marker" > "$REPO16/workflows/scripts/board/marker.txt"
git -C "$REPO16" add -A
git -C "$REPO16" commit -q -m "seed board toolkit"
git -C "$REPO16" push -q origin main \
  || fail "could not push the seeded board toolkit to the fixture's origin/main"
git -C "$REPO16" fetch -q origin

# --- run 1: proposes both optional entries -------------------------------
FAKE_PR_NUM=32 run 0 --dir "$REPO16" --gh-repo acme/widget
grep -qF "report.d producer: proposing .temperloop/report.d/tokens" <<<"$out" \
  || fail "run 1 did not propose the producer (got: $out)"
git -C "$REPO16" show "HEAD:.temperloop/report.d/tokens" > "$WORK/run1-producer" 2>/dev/null \
  || fail "run 1 did not commit the producer"
git -C "$REPO16" show "HEAD:workflows/scripts/board/boards.conf" > "$WORK/run1-boards" 2>/dev/null \
  || fail "run 1 did not commit boards.conf"

# --- run 2: the same repo, now sitting on the proposal branch -------------
FAKE_PR_EXISTS=1 FAKE_PR_BRANCH="foundation-init/config" FAKE_PR_NUM=32 \
  run 0 --dir "$REPO16" --gh-repo acme/widget

P16="$REPO16/.temperloop/report.d/tokens"
[ -f "$P16" ] \
  || fail "RE-RUN DELETED THE PRODUCER: it is gone from the working tree after a second init"
git -C "$REPO16" show "HEAD:.temperloop/report.d/tokens" > "$WORK/run2-producer" 2>/dev/null \
  || fail "RE-RUN DROPPED THE PRODUCER from the proposal commit"
cmp -s "$WORK/run1-producer" "$WORK/run2-producer" \
  || fail "the re-run changed the producer's committed bytes (it must be carried forward verbatim)"
mode16="$(git -C "$REPO16" ls-tree HEAD .temperloop/report.d/tokens | awk '{print $1}')"
[ "$mode16" = "100755" ] || fail "the re-run lost the producer's executable bit (git mode $mode16, want 100755)"

# The boards.conf half of the same root cause.
git -C "$REPO16" show "HEAD:workflows/scripts/board/boards.conf" > "$WORK/run2-boards" 2>/dev/null \
  || fail "RE-RUN DROPPED boards.conf from the proposal commit"
cmp -s "$WORK/run1-boards" "$WORK/run2-boards" \
  || fail "the re-run changed boards.conf (it must be carried forward verbatim, not reverted to the base tip)"
assert_complete_boards_entry "re-run boards.conf" "$(cat "$WORK/run2-boards")" 1
echo "PASS: a second consecutive init keeps BOTH optional entries — producer and boards.conf still present, byte-identical, executable, and in the proposal commit"

# =============================================================================
# 17. BASE/WORKING-TREE DIVERGENCE: an adopter's producer that exists on the
#     BASE BRANCH but not in the local checkout is NOT overwritten.
#
#     The opposite direction of the same root cause, and the one the earlier
#     fixtures were structurally unable to see (they seeded tree and base
#     together, so the two never disagreed). Reproduce the disagreement
#     directly: commit the adopter's producer to origin/main via a SEPARATE
#     clone, then leave the local checkout on an older commit that has never
#     seen it. The old working-tree probe found nothing and proposed ours
#     straight over theirs; the base-tip probe must leave it alone.
# =============================================================================
REPO17="$(new_fixture_repo repo17)"
OTHER17="$WORK/repo17-other"
git clone -q "$WORK/repo17-upstream.git" "$OTHER17" 2>/dev/null
mkdir -p "$OTHER17/.temperloop/report.d"
printf '%s\n' '#!/usr/bin/env bash' 'echo ADOPTER-OWNED-PRODUCER' \
  > "$OTHER17/.temperloop/report.d/tokens"
chmod 755 "$OTHER17/.temperloop/report.d/tokens"
cp "$OTHER17/.temperloop/report.d/tokens" "$WORK/producer17.onbase"
# Same second seed as test 15 (temperloop#2084) — without it, dual-build's
# OWN unrelated fresh-proposal line would trip the bare "proposing" absence
# assertion below.
printf '%s\n' '#!/usr/bin/env bash' 'echo ADOPTER-OWNED-DUAL-BUILD-PRODUCER' \
  > "$OTHER17/.temperloop/report.d/dual-build"
chmod 755 "$OTHER17/.temperloop/report.d/dual-build"
cp "$OTHER17/.temperloop/report.d/dual-build" "$WORK/dbproducer17.onbase"
git -C "$OTHER17" add -A
git -C "$OTHER17" commit -q -m "adopter commits their own tokens + dual-build producers"
git -C "$OTHER17" push -q origin main \
  || fail "could not push the adopter's producers from the second clone"

# REPO17's working tree has never seen it — a stale clone, exactly the shape
# the reviewer reproduced. (The fetch only moves the remote-tracking ref;
# the checkout stays on the older commit.)
git -C "$REPO17" fetch -q origin
[ ! -e "$REPO17/.temperloop/report.d/tokens" ] \
  || fail "fixture bug: REPO17's working tree already has the producer, so this test proves nothing"

FAKE_PR_NUM=33 run 0 --dir "$REPO17" --gh-repo acme/widget
grep -qF "report.d producer: proposing" <<<"$out" \
  && fail "init proposed its own shim over a producer that exists on the base branch (got: $out)"
grep -qF "already on main — leaving it untouched" <<<"$out" \
  || fail "init did not detect the base-branch producer (got: $out)"
git -C "$REPO17" show --name-only --format= HEAD | grep -F ".temperloop/report.d/tokens" >/dev/null \
  && fail "the proposal commit touched the adopter's base-branch producer"
git -C "$REPO17" show "HEAD:.temperloop/report.d/tokens" > "$WORK/producer17.after" 2>/dev/null \
  || fail "the adopter's producer vanished from the proposal branch"
cmp -s "$WORK/producer17.onbase" "$WORK/producer17.after" \
  || fail "init OVERWROTE an adopter's producer that existed on the base branch but not in the local checkout"

grep -qF "report.d producer: .temperloop/report.d/dual-build already on main — leaving it untouched" <<<"$out" \
  || fail "init did not detect the base-branch dual-build producer (got: $out)"
git -C "$REPO17" show --name-only --format= HEAD | grep -F ".temperloop/report.d/dual-build" >/dev/null \
  && fail "the proposal commit touched the adopter's base-branch dual-build producer"
git -C "$REPO17" show "HEAD:.temperloop/report.d/dual-build" > "$WORK/dbproducer17.after" 2>/dev/null \
  || fail "the adopter's dual-build producer vanished from the proposal branch"
cmp -s "$WORK/dbproducer17.onbase" "$WORK/dbproducer17.after" \
  || fail "init OVERWROTE an adopter's dual-build producer that existed on the base branch but not in the local checkout"
echo "PASS: a producer present on the base branch but absent locally is left byte-identical — the stale-clone overwrite direction is closed"
echo "PASS: the dual-build producer gets the identical base/working-tree-divergence treatment"

# =============================================================================
# 18. THE SOFT-SEAM ARM: an unusable shim degrades legibly and, above all,
#     never commits a ZERO-BYTE mode-755 file.
#
#     init.sh runs WITHOUT `set -e`, so a bare `[ -f ]` let an unreadable or
#     empty shim through: `$(cat …)` returned empty, the manifest append ran
#     anyway, and an empty executable landed in the adopter's PR — which
#     report.sh then execs to exit 0 with no output and no `skipped` line, the
#     exact failure this arm exists to make legible arriving illegibly. Both
#     unusable shapes are covered by pointing PRODUCER_SHIM's own lookup at a
#     throwaway kernel root: a MISSING shim, and a present-but-EMPTY one.
# =============================================================================
# init.sh resolves the shim relative to its own location, so a fake kernel
# root is a directory holding a copy of init.sh at bin/subcommands/ with no
# (or an empty) .temperloop/report.d/tokens beside it. Everything else it
# needs (the probe, the generator) is symlinked back to the real checkout.
make_fake_kernel() {
  local root="$1"
  mkdir -p "$root/bin/subcommands" "$root/workflows/scripts"
  cp "$INIT" "$root/bin/subcommands/init.sh"
  ln -s "$KERNEL_SRC/workflows/scripts/probe" "$root/workflows/scripts/probe"
  ln -s "$KERNEL_SRC/workflows/scripts/proposal" "$root/workflows/scripts/proposal"
  ln -s "$KERNEL_SRC/claude" "$root/claude"
}

# 18a — the shim file is absent entirely.
FAKE_KERNEL_MISSING="$WORK/fake-kernel-missing"
make_fake_kernel "$FAKE_KERNEL_MISSING"
REPO18A="$(new_fixture_repo repo18a)"
INIT_SAVED="$INIT"
INIT="$FAKE_KERNEL_MISSING/bin/subcommands/init.sh"
FAKE_PR_NUM=34 run 0 --dir "$REPO18A" --gh-repo acme/widget
INIT="$INIT_SAVED"
grep -qF "report.d producer: skipped — shim unavailable" <<<"$out" \
  || fail "a missing shim did not report the legible soft-seam skip (got: $out)"
git -C "$REPO18A" show "HEAD:.temperloop/report.d/tokens" >/dev/null 2>&1 \
  && fail "a missing shim still committed a producer into the proposal"
grep -qF '"outcome": "PR_OPENED"' <<<"$out" \
  || fail "a missing shim blocked the rest of init (the soft seam must never fail the run) (got: $out)"

# 18b — the shim exists but is EMPTY (the zero-byte-executable trap).
FAKE_KERNEL_EMPTY="$WORK/fake-kernel-empty"
make_fake_kernel "$FAKE_KERNEL_EMPTY"
mkdir -p "$FAKE_KERNEL_EMPTY/.temperloop/report.d"
: > "$FAKE_KERNEL_EMPTY/.temperloop/report.d/tokens"
chmod 755 "$FAKE_KERNEL_EMPTY/.temperloop/report.d/tokens"
REPO18B="$(new_fixture_repo repo18b)"
INIT="$FAKE_KERNEL_EMPTY/bin/subcommands/init.sh"
FAKE_PR_NUM=35 run 0 --dir "$REPO18B" --gh-repo acme/widget
INIT="$INIT_SAVED"
grep -qF "report.d producer: skipped — shim unavailable" <<<"$out" \
  || fail "an EMPTY shim did not report the legible soft-seam skip (got: $out)"
git -C "$REPO18B" show "HEAD:.temperloop/report.d/tokens" >/dev/null 2>&1 \
  && fail "an EMPTY shim committed a ZERO-BYTE mode-755 file into the adopter's proposal"
[ ! -e "$REPO18B/.temperloop/report.d/tokens" ] \
  || fail "an EMPTY shim left a zero-byte producer in the working tree"
echo "PASS: an unusable shim (missing OR empty) degrades to the legible skip, never commits a zero-byte executable, and never fails the run"

# =============================================================================
# 19. `--base` IS VALIDATED BEFORE IT REACHES git (command injection).
#
#     `--base` parses unvalidated, and the base-tip probe made init the FIRST
#     consumer of it — `git fetch "$remote" "$base"`. git honors
#     option-shaped arguments, so `--base '--upload-pack=<cmd>'` EXECUTED.
#     proposal-pr.sh does reject the name, but only AFTER init's own fetch had
#     already run it: downstream refusal is not a guard. This asserts the
#     ORDERING, not merely the refusal — the marker file must never appear.
# =============================================================================
REPO19="$(new_fixture_repo repo19)"
PWNED_MARKER="$WORK/PWNED-marker"
rm -f "$PWNED_MARKER"
run 2 --dir "$REPO19" --gh-repo acme/widget \
  --base "--upload-pack=touch $PWNED_MARKER; git-upload-pack"
[ ! -e "$PWNED_MARKER" ] \
  || fail "COMMAND INJECTION: --base reached git and executed its --upload-pack payload before anything validated it"
grep -qF "is not a valid git branch name" <<<"$out" \
  || fail "a malformed --base was not refused with a clear message (got: $out)"
# ...and the guard is not merely "reject everything": an explicit, valid
# --base must still drive a normal run.
FAKE_PR_NUM=36 run 0 --dir "$REPO19" --gh-repo acme/widget --base main
grep -qF '"outcome": "PR_OPENED"' <<<"$out" \
  || fail "an explicit, valid --base was refused by the new guard (got: $out)"
echo "PASS: a malformed --base is refused (exit 2) BEFORE any git invocation — no payload executes — while a valid --base still runs"

# =============================================================================
# 20. boards.conf UNION: the base tip's board entries survive a STALE local
#     checkout that knows fewer of them.
#
#     The boards.conf mirror of test 17, and the half the earlier fix missed.
#     That cut let the working tree's whole-file bytes REPLACE base's, which
#     only looked safe because the sole covered case was "tree lacks the file
#     entirely". A stale clone carrying a STALE boards.conf still won outright
#     and deleted every board.<N>.* base had and the tree didn't.
#
#     Reproduced exactly: base carries board.1 + board.2, the local checkout
#     knows only board.1, and init adds board.3. All three must survive.
# =============================================================================
REPO20="$(new_fixture_repo repo20)"
mkdir -p "$REPO20/workflows/scripts/board"
printf '%s\n' 'board.1.repo=acme/widget' 'board.1.backend=issues' \
  > "$REPO20/workflows/scripts/board/boards.conf"
git -C "$REPO20" add -A
git -C "$REPO20" commit -q -m "seed boards.conf with board.1 only"
git -C "$REPO20" push -q origin main || fail "could not push the board.1-only boards.conf"

# A second clone adds board.2 and pushes — origin/main now knows more than
# REPO20's working tree does.
OTHER20="$WORK/repo20-other"
git clone -q "$WORK/repo20-upstream.git" "$OTHER20" 2>/dev/null
printf '%s\n' 'board.1.repo=acme/widget' 'board.1.backend=issues' '' \
  'board.2.repo=acme/other' 'board.2.backend=issues' \
  > "$OTHER20/workflows/scripts/board/boards.conf"
git -C "$OTHER20" add -A
git -C "$OTHER20" commit -q -m "another adopter adds board.2"
git -C "$OTHER20" push -q origin main || fail "could not push board.2 from the second clone"

# REPO20 learns the new tip but never merges it: a stale working tree.
git -C "$REPO20" fetch -q origin
grep -q "board.2." "$REPO20/workflows/scripts/board/boards.conf" \
  && fail "fixture bug: REPO20's working tree already knows board.2, so this test proves nothing"

FAKE_PR_NUM=37 run 0 --dir "$REPO20" --gh-repo acme/widget --board 3
union_conf="$(git -C "$REPO20" show HEAD:workflows/scripts/board/boards.conf 2>/dev/null || true)"
grep -q "board.2.repo=acme/other" <<<"$union_conf" \
  || fail "THE UNION DROPPED board.2 — an entry that exists on the base branch but not in the stale local checkout:\n$union_conf"
grep -q "board.1.repo=acme/widget" <<<"$union_conf" \
  || fail "the union dropped board.1 (got:\n$union_conf)"
grep -q "board.3.repo=acme/widget" <<<"$union_conf" \
  || fail "the union did not add the newly requested board.3 (got:\n$union_conf)"
assert_complete_boards_entry "union boards.conf" "$union_conf" 3
grep -qF "keeping every board main already defines" <<<"$out" \
  || fail "the propose branch did not narrate what it was preserving (got: $out)"
echo "PASS: boards.conf is a real union — every board the base tip defines survives a stale local checkout, and the new entry is added alongside"

# =============================================================================
# 21. RULE 2 PRESERVES THE ADOPTER'S MODE, it does not re-arm it.
#
#     The carry-forward arm hardcoded mode 755 regardless of what it carried.
#     644 is a MEANINGFUL state for a producer — report.sh only runs
#     executables, so a non-executable one renders as "skipped -- tokens:
#     producer unavailable". That makes `chmod 644` a plausible deliberate
#     DISABLE, which forcing 755 silently re-armed while printing "unchanged".
# =============================================================================
REPO21="$(new_fixture_repo repo21)"
mkdir -p "$REPO21/.temperloop/report.d"
printf '%s\n' '#!/usr/bin/env bash' 'echo DELIBERATELY-DISABLED' \
  > "$REPO21/.temperloop/report.d/tokens"
chmod 644 "$REPO21/.temperloop/report.d/tokens"
cp "$REPO21/.temperloop/report.d/tokens" "$WORK/producer21.before"

FAKE_PR_NUM=38 run 0 --dir "$REPO21" --gh-repo acme/widget
mode21="$(git -C "$REPO21" ls-tree HEAD .temperloop/report.d/tokens | awk '{print $1}')"
[ "$mode21" = "100644" ] \
  || fail "rule 2 re-armed a deliberately non-executable producer (git mode $mode21, want 100644)"
[ ! -x "$REPO21/.temperloop/report.d/tokens" ] \
  || fail "rule 2 made a 644 producer executable on disk"
# Newline-tolerant, unlike test 15's `cmp -s`. Test 15's file rides through
# on the base tip and is never rewritten, so it stays byte-exact; a rule-2
# carry-forward is re-written THROUGH the manifest and so loses its final
# newline exactly like every other entry (proposal-pr.sh re-reads `.content`
# via a `$(…)` capture). That is why the run's own line claims "content and
# mode", not "bytes" — asserting cmp here would be asserting a claim the
# generator makes impossible.
[ "$(cat "$WORK/producer21.before")" = "$(cat "$REPO21/.temperloop/report.d/tokens")" ] \
  || fail "rule 2 changed the carried-forward producer's content"
grep -qF "mode (644) preserved" <<<"$out" \
  || fail "the carry-forward line did not name the mode it preserved (got: $out)"
grep -qF "bytes and mode" <<<"$out" \
  && fail "the carry-forward line overclaims byte-exactness, which the generator's newline strip makes impossible (got: $out)"
echo "PASS: rule 2 carries the adopter's own mode (644 stays 644, content unchanged) instead of forcing 755"

# =============================================================================
# 22. THE --dry-run PREVIEW IS RELATIVE TO THE BASE TIP, and says so.
#
#     A real run commits onto a branch cut fresh off base, so base is what
#     "would create / unchanged" is relative to. Comparing against the working
#     tree made the preview lie routinely once rule 2's carry-forward existed:
#     REPO16 has already had two real runs, so its tree carries the producer
#     while origin/main still does not — the old preview printed `unchanged`
#     for a path a real run would CREATE.
# =============================================================================
run 0 --dir "$REPO16" --gh-repo acme/widget --no-network --dry-run
grep -qE '^  would create: \.temperloop/report\.d/tokens$' <<<"$out" \
  || fail "the dry-run preview did not report the producer as a CREATE against the base tip (got: $out)"
grep -qF "unchanged:    .temperloop/report.d/tokens" <<<"$out" \
  && fail "the dry-run preview still compares against the working tree — it called a base-tip CREATE 'unchanged' (got: $out)"
grep -qF "NOT refreshed (--dry-run performs no fetch" <<<"$out" \
  || fail "the dry-run preview did not disclose that its base ref was not refreshed (got: $out)"
echo "PASS: the --dry-run preview diffs against the base tip a real run would branch from, and discloses that it skipped the fetch"

# =============================================================================
# 23. `--remote` IS VALIDATED BEFORE IT REACHES git (command injection).
#
#     The sibling of test 19. `--remote` parses unvalidated and is spliced
#     into `git fetch "$remote" "$base"` as that call's FIRST POSITIONAL —
#     the position git parses as an OPTION when the word begins with '-'. So
#     `--remote '--upload-pack=<cmd>'` EXECUTED, exactly like the `--base`
#     payload test 19 closed on the OTHER argument of the same command.
#     proposal-pr.sh does reject the name, but only after init's own fetch has
#     already run it: downstream refusal is not a guard. Asserts the ORDERING
#     — the marker file must never appear — not merely the refusal.
# =============================================================================
REPO23="$(new_fixture_repo repo23)"
PWNED_REMOTE_MARKER="$WORK/PWNED-remote-marker"
rm -f "$PWNED_REMOTE_MARKER"
run 2 --dir "$REPO23" --gh-repo acme/widget --base main \
  --remote "--upload-pack=touch $PWNED_REMOTE_MARKER; git-upload-pack"
[ ! -e "$PWNED_REMOTE_MARKER" ] \
  || fail "COMMAND INJECTION: --remote reached git and executed its --upload-pack payload before anything validated it"
grep -qF "must not begin with '-'" <<<"$out" \
  || fail "an option-shaped --remote was not refused with a clear message (got: $out)"
# A remote name git itself would reject is refused too (same guard, non-'-' arm).
run 2 --dir "$REPO23" --gh-repo acme/widget --remote "bad remote"
grep -qF "is not a valid git remote name" <<<"$out" \
  || fail "a malformed --remote was not refused with a clear message (got: $out)"
# ...and the guard is not merely "reject everything": an explicit, valid
# --remote must still drive a normal run.
FAKE_PR_NUM=39 run 0 --dir "$REPO23" --gh-repo acme/widget --remote origin
grep -qF '"outcome": "PR_OPENED"' <<<"$out" \
  || fail "an explicit, valid --remote was refused by the new guard (got: $out)"
echo "PASS: a malformed --remote is refused (exit 2) BEFORE any git invocation — no payload executes — while a valid --remote still runs"

# =============================================================================
# 25. --no-network GATES THE STEP 3 PROPOSAL PR (temperloop#969).
#
#     The flag suppressed Step 2's first-epic offer and NOT Step 3, so
#     `temperloop init --dir . --no-network --base master` in a REMOTE-LESS
#     repo invoked proposal-pr.sh anyway: it force-created and switched to
#     foundation-init/config, committed onto it, and only THEN died on
#     `git push` with a raw `fatal: 'origin' does not appear to be a git
#     repository` — exiting non-zero and never reaching the Step 4/5
#     summary + handoff. A stranger was left on an unfamiliar branch, with
#     a git error and no recovery guidance, by a flag whose name promises
#     the opposite.
#
#     Four halves, asserted together because each is satisfiable without
#     the others (suppressing the error alone, or the push alone, would
#     each still leave part of the report standing):
#       (a) exit 0, and NEITHER raw git-push string in the output;
#       (b) the degradation notice — the kernel's `skipped — ` prefix, the
#           reason, and what did not happen;
#       (c) Step 4's summary AND the `next step:` handoff marker still
#           print, i.e. the run CONTINUES rather than aborting;
#       (d) the checkout never leaves its original branch and NO
#           foundation-init/* branch is created at all. This is the half a
#           push-only suppression would not fix: proposal-pr.sh's own
#           --dry-run mode still performs a real local checkout + commit,
#           so routing through it would silence the error and strand the
#           operator on the branch exactly as before.
#
#     Then the two controls that keep this from being a vacuous pass: the
#     same skip fires in a repo that DOES have a reachable remote (the gate
#     is the FLAG, not the absence of a remote — the old behavior differed
#     only by which error you got), and dropping the flag on that very repo
#     still opens the PR (the gate is not "refuse everything").
# =============================================================================
REPO24="$WORK/repo24-no-remote"
git init -q --initial-branch=master "$REPO24"
git -C "$REPO24" commit -q --allow-empty -m init
[ -z "$(git -C "$REPO24" remote)" ] \
  || fail "fixture bug: REPO24 has a remote, so it cannot reproduce the remote-less push failure"
R24_HEAD="$(git -C "$REPO24" rev-parse HEAD)"

# Deliberately NO --gh-repo: the issue's verbatim reproduction command.
run 0 --dir "$REPO24" --no-network --base master

# (a) the raw git failure is gone — both halves of the reported string.
for pusherr in "git push failed" "does not appear to be a git repository"; do
  if grep -qF "$pusherr" <<<"$out"; then
    fail "--no-network still reached the push: raw git error '$pusherr' surfaced (got: $out)"
  fi
done

# (b) the degradation notice names what was skipped and why.
grep -qF "skipped — network disabled (--no-network)" <<<"$out" \
  || fail "no degradation notice for the network-gated proposal step (got: $out)"
grep -qF "no proposal branch, no commit, no push, no PR" <<<"$out" \
  || fail "the skip notice does not name what did not happen (got: $out)"

# (c) the run CONTINUES — summary and handoff both still print.
grep -qF -- "-- 4. Summary --" <<<"$out" \
  || fail "the run aborted before the Step 4 summary (got: $out)"
grep -q "^next step: " <<<"$out" \
  || fail "the run aborted before the Step 5 handoff marker (got: $out)"

# (d) the checkout is where the operator left it — no stray proposal branch.
[ "$(git -C "$REPO24" branch --show-current)" = "master" ] \
  || fail "--no-network switched the checkout off its original branch (now: $(git -C "$REPO24" branch --show-current))"
[ "$(git -C "$REPO24" rev-parse HEAD)" = "$R24_HEAD" ] \
  || fail "--no-network committed to the checkout (HEAD moved $R24_HEAD -> $(git -C "$REPO24" rev-parse HEAD))"
if git -C "$REPO24" rev-parse --verify --quiet "refs/heads/foundation-init/config" >/dev/null; then
  fail "--no-network created the foundation-init/config branch it must never reach"
fi
[ "$(call_count "pr create")" -eq 0 ] \
  || fail "--no-network reached GitHub: $(call_count "pr create") 'pr create' call(s) logged"

# CONTROL 1: a repo WITH a reachable remote skips identically — the gate is
# the flag, not a missing remote.
REPO24B="$(new_fixture_repo repo24b)"
R24B_HEAD="$(git -C "$REPO24B" rev-parse HEAD)"
FAKE_PR_NUM=40 run 0 --dir "$REPO24B" --gh-repo acme/widget --no-network
grep -qF "skipped — network disabled (--no-network)" <<<"$out" \
  || fail "--no-network did not skip the proposal in a repo that HAS a remote (got: $out)"
[ "$(git -C "$REPO24B" rev-parse HEAD)" = "$R24B_HEAD" ] \
  || fail "--no-network committed to a remote-having checkout instead of skipping"
[ "$(call_count "pr create")" -eq 0 ] \
  || fail "--no-network opened a PR in a repo that has a remote"

# CONTROL 2: the gate is not "refuse everything" — the same repo, same
# invocation minus the flag, still opens the proposal PR.
FAKE_PR_NUM=40 run 0 --dir "$REPO24B" --gh-repo acme/widget
grep -qF '"outcome": "PR_OPENED"' <<<"$out" \
  || fail "dropping --no-network no longer opens the proposal PR (got: $out)"
echo "PASS: --no-network skips the Step 3 proposal PR with a degradation notice instead of failing on a raw git push — no branch switch, no commit, no PR, and the summary + handoff still print"

# =============================================================================
# 25. A FAILED IDEMPOTENCY PROBE IS "UNKNOWN", NEVER "ALREADY FILED"
#     (temperloop#1444). Observed live in install-tier2 run 31772670963:
#
#       first-epic: already filed as #{"message":"Query must include
#       'is:issue' or 'is:pull-request'",...,"status":"422"} — skipping
#       offer (idempotent)
#
#     Two compounding bugs. GitHub's search/issues endpoint now REQUIRES an
#     `is:issue`/`is:pull-request` qualifier (external drift — no commit
#     here caused it), and `gh` writes its error BODY to STDOUT, so the old
#     `2>/dev/null || true` fail-open let that raw JSON blob become the
#     issue number: non-empty, therefore reported as already-filed AND
#     passed into `_init_set_handoff`, corrupting the handoff too. ANY
#     probe error — rate limit, network blip, auth scope, outage — silently
#     disabled the first-epic offer while claiming the epic existed.
#
#     Test 13 above could not catch this: it asserts the already-filed
#     MESSAGE SHAPE against a fake gh that answers whatever q= it is
#     handed. So this case attacks the two halves the message shape cannot
#     see — the wire query's validity (assert_probe_query_qualified, now
#     also asserted in test 13) and the ERROR path's disposition.
# =============================================================================
REPO25="$(new_fixture_repo repo25)"
FAKE_SEARCH_422=1 FAKE_PR_NUM=41 \
  run 0 --dir "$REPO25" --gh-repo acme/widget

# (a) the false positive is gone — an error is never read as a hit.
grep -q "first-epic: already filed" <<<"$out" \
  && fail "a 422 probe error was reported as 'already filed' (got: $out)"

# (b) no non-numeric value escaped the probe ANYWHERE — not into the
#     notice, not into the handoff. The blob is unmistakable if it leaks.
grep -qF '{"message"' <<<"$out" \
  && fail "gh's error body leaked out of the probe into init's output (got: $out)"
grep -qF 'Query must include' <<<"$out" \
  && fail "gh's error body leaked out of the probe into init's output (got: $out)"

# (c) the handoff is the un-offered one, not a fabricated /assess pointer
#     at a garbage epic number.
grep -qF 'next step: run `temperloop init` interactively' <<<"$out" \
  || fail "a failed probe did not fall back to the un-offered handoff (got: $out)"
grep -q '^next step: /assess --epic ' <<<"$out" \
  && fail "a failed probe still produced an /assess handoff naming an epic it never confirmed (got: $out)"

# (d) LEGIBLE DEGRADATION, never a silent skip (kernel § legible
#     agent-gate degradation): the notice names what could not be
#     determined and why.
grep -q "first-epic: idempotency probe unavailable" <<<"$out" \
  || fail "a failed probe skipped silently — no degradation notice (got: $out)"

# (e) the API-contract half: the query this script actually sent carries
#     `is:issue`.
assert_probe_query_qualified "422 probe run"

# (f) nothing was filed on the error path.
[ "$(call_count 'issue create')" -eq 0 ] \
  || fail "a failed probe filed an issue: $(call_count 'issue create') 'issue create' call(s)"

# (g) UNATTENDED ORDERING PIN. The unknown-state arm is ranked AFTER the
#     ambient-CI arm on purpose, so an unattended run still skips for its
#     truer, more specific reason — .github/workflows/install-tier2.yml
#     asserts that exact line, and pinning a release gate to probe health
#     would make it hostage to a transient search outage. (run() closes
#     stdin, which is the unattended signal here.)
grep -q "first-epic: skipped — no interactive operator detected" <<<"$out" \
  || fail "a failed probe pre-empted the ambient-CI skip line install-tier2.yml asserts (got: $out)"

# CONTROL: with consent given there IS an operator, so the unknown-state
# arm is the one that fires — and it WITHHOLDS. Filing a duplicate epic is
# the single outcome this probe exists to prevent, so an unanswerable probe
# must not be treated as "no epic exists, go ahead".
REPO25B="$(new_fixture_repo repo25b)"
FAKE_SEARCH_422=1 FAKE_PR_NUM=42 FAKE_ISSUE_NUM=99 \
  run 0 --dir "$REPO25B" --gh-repo acme/widget --yes-first-epic
[ "$(call_count 'issue create')" -eq 0 ] \
  || fail "--yes-first-epic filed an epic while the idempotency probe was unanswerable — this is the duplicate-epic case: $(call_count 'issue create') 'issue create' call(s)"
grep -q "first-epic: skipped — idempotency state unknown" <<<"$out" \
  || fail "the unknown-state withhold notice did not fire under --yes-first-epic (got: $out)"
grep -q "first-epic: already filed" <<<"$out" \
  && fail "a 422 probe error was reported as 'already filed' under --yes-first-epic (got: $out)"

# CONTROL 2: the gate is the ERROR, not the qualifier — a healthy probe on
# the same fixture still reports a real hit and still hands off.
REPO25C="$(new_fixture_repo repo25c)"
FAKE_EXISTING_EPIC_NUM=77 FAKE_PR_NUM=43 \
  run 0 --dir "$REPO25C" --gh-repo acme/widget
grep -q "first-epic: already filed as #77" <<<"$out" \
  || fail "the hardened probe stopped recognising a genuine already-filed hit (got: $out)"
grep -q "first-epic: idempotency probe unavailable" <<<"$out" \
  && fail "a HEALTHY probe emitted the degradation notice (got: $out)"
echo "PASS: a failed search/issues probe reads as UNKNOWN — never 'already filed' — leaks no error body into the notice or the handoff, withholds the offer legibly, and the probe query carries the mandatory is:issue qualifier"

echo
echo "ALL PASS: test_init.sh"
