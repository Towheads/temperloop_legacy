#!/usr/bin/env bash
#
# test_dual_build_ledger.sh — fixture suite for
# workflows/scripts/model-comparison/dual-build-ledger.sh (temperloop#2072,
# epic #2065 "new-work dual-build harness"). Plain mktemp-fixture style,
# mirroring the sibling test_lake_sweep.sh/test_worktree.sh's real-git,
# zero-network shape. No mapfile / associative arrays / GNU-only flags
# (bash 3.2 compatible, per this directory's existing convention).
#
# Sections:
#   1-2   append: monotonic seq across successive valid rows
#   3-9   append: EVERY required-field/enum/nested-cost rejection the
#         validator enforces — each one a NEGATIVE case, so this suite can
#         actually go red if the validator regresses (see § 25's own note
#         on the exact silent-pass bug this guards against)
#   10-15 read: normal read, --expect match/mismatch, a mid-file gap
#         ("records missing" self-check with no --expect), a truncated
#         trailing partial line (simulated crash mid-write), and an absent
#         ledger (legal when nothing was expected, an error when something
#         was)
#   16-18 archive / archive-check: a clean patch APPLIES against its real
#         base, a conflicting base REJECTS (git am's own verdict, not a
#         hand-rolled diff compare), and a missing archive dies loudly
#   19    purge: dry run is a no-op, --yes removes the whole folder
#   20-22 prune: retention-based archive removal, the DUAL_BUILD_ARCHIVE_
#         RETENTION_DAYS named-setting fallback, and the no-window refusal
#   23    the machinery_version-bump fixture (acceptance bullet 3): rows
#         written under two different machinery_version values interleave
#         cleanly — seq stays monotonic, neither row's version is rewritten
#   24    the worktree-sweep fixture (acceptance bullet 3): the ledger dir
#         lives in the MAIN repo tree, never inside a worktree, so adding
#         and removing a worktree leaves it byte-identical
#   25    schema_version/seq are ASSIGNED by the script, never accepted from
#         a caller — a forged seq/schema_version in the input row is ignored
#   26    operator/host: caller-supplied values are respected verbatim;
#         omitted values fall back to the environment
#   27-29 the DATA-DIR vs SETTINGS resolution boundary (temperloop#2119):
#         the default ledger dir follows the CWD's git toplevel, a row
#         written from repo A is invisible from repo B (and still visible
#         from A — both states), a decoy build.config.sh in the cwd repo is
#         NOT sourced (settings keep the $0 climb), and a cwd outside any
#         checkout REFUSES by name instead of silently falling back to the
#         kernel checkout
#   30    the `repo` row field (temperloop#2119): assigned from the cwd,
#         caller-supplied respected verbatim, and a pre-existing row with
#         NO `repo` key still reads and tallies (backward compatibility)
#
# Usage: bash workflows/scripts/model-comparison/tests/test_dual_build_ledger.sh
set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$HERE/../dual-build-ledger.sh"

pass=0; total=0
ok()    { pass=$((pass + 1)); printf 'PASS: %s\n' "$1"; }
count() { total=$((total + 1)); }
fail()  { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-dual-build-ledger.XXXXXX")" || exit 1
WORK="$(cd -P "$WORK" && pwd)"
trap 'chmod -R u+rwX "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

gitc() { git -c user.name="DBL Test" -c user.email="dbl-test@example.com" -c commit.gpgsign=false "$@"; }

sut() { bash "$SUT" "$@"; }

# epoch_stamp <epoch-seconds> -> `touch -t` stamp. BSD `date -r` takes an
# epoch; GNU `date -r` takes a reference FILE instead — so a bare
# `date -u -r "$epoch" +...` is BSD/macOS-only and silently empty (touch -t
# ""  errors) on the ubuntu-latest CI runner. Same feature-detect-once shape
# as workflows/scripts/build/tests/test_state_graph_local.sh's own
# epoch_stamp helper.
epoch_stamp() {
  if date -r 0 '+%Y' >/dev/null 2>&1; then
    date -r "$1" '+%Y%m%d%H%M.%S'          # BSD/macOS
  else
    date -d "@$1" '+%Y%m%d%H%M.%S'         # GNU coreutils
  fi
}

# row <slug> <arm> [overrides-jq-filter] — a minimal, fully-valid row.
row() {
  local slug="$1" arm="$2" extra="${3:-.}"
  jq -c --arg slug "$slug" --arg arm "$arm" \
    '{tier:"sonnet", model:"claude-sonnet-5", slug:$slug, arm:$arm,
      base_sha:"basexxxxx", head_sha:"headxxxxx", start_order:1, gate:"pass",
      cost:{tokens_in:10,tokens_out:20,wall_clock_ms:1000,retry_tokens:0,
            retry_count:0,recovery:false},
      judge:null, pick:null,
      override:{applied:false,scope:null,reason:null},
      loss_reason:null, cross_read_attempted:false, guard_armed:"ARMED",
      machinery_version:"v1"}' <<<'{}' | jq -c "$extra"
}

# ── 1-2. append: monotonic seq ──────────────────────────────────────────────
count
D1="$WORK/d1"
r1="$(sut append --dir "$D1" --row "$(row foo baseline)")" || fail "1: append 1 failed"
[ "$(jq -r .seq <<<"$r1")" = "1" ] || fail "1: first row seq must be 1 (got $(jq -r .seq <<<"$r1"))"
[ "$(jq -r .schema_version <<<"$r1")" = "1" ] || fail "1: schema_version must be 1"
ok "1 append assigns seq=1, schema_version=1 to the first row"

count
r2="$(sut append --dir "$D1" --row "$(row foo candidate)")" || fail "2: append 2 failed"
[ "$(jq -r .seq <<<"$r2")" = "2" ] || fail "2: second row seq must be 2 (got $(jq -r .seq <<<"$r2"))"
ok "2 a second append gets the next monotonic seq"

# ── 3-9. append rejections (every required-field/enum/nested-cost path) ────
# Each case appends nothing new to D1 and leaves it at exactly 2 rows —
# checked once at the end of this block (test 9b) so a validator regression
# that lets ANY of these through is caught even if its own rc-check slips.
count
out="$(sut append --dir "$D1" --row "$(row foo baseline | jq -c 'del(.machinery_version)')" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] || fail "3: a row missing machinery_version was accepted"
[[ "$out" == *"missing required field(s): machinery_version"* ]] || fail "3: wrong/no error for missing field (got: $out)"
ok "3 append refuses a row missing a required top-level field"

count
out="$(sut append --dir "$D1" --row "$(row foo weird-arm)" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] || fail "4: arm=weird-arm was accepted"
[[ "$out" == *'arm must be'* ]] || fail "4: wrong/no error for bad arm (got: $out)"
ok "4 append refuses an arm outside {baseline,candidate}"

count
out="$(sut append --dir "$D1" --row "$(row foo baseline | jq -c '.gate="maybe"')" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] || fail "5: gate=maybe was accepted"
[[ "$out" == *'gate must be'* ]] || fail "5: wrong/no error for bad gate (got: $out)"
ok "5 append refuses a gate outside {pass,fail}"

count
out="$(sut append --dir "$D1" --row "$(row foo baseline | jq -c '.guard_armed="SORTOF"')" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] || fail "6: guard_armed=SORTOF was accepted"
[[ "$out" == *'guard_armed must be'* ]] || fail "6: wrong/no error for bad guard_armed (got: $out)"
ok "6 append refuses a guard_armed outside {ARMED,UNARMED,UNKNOWN}"

count
out="$(sut append --dir "$D1" --row "$(row foo baseline | jq -c '.loss_reason="oops"')" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] || fail "7: loss_reason=oops was accepted"
[[ "$out" == *'loss_reason must be'* ]] || fail "7: wrong/no error for bad loss_reason (got: $out)"
ok "7 append refuses a loss_reason outside {gate,judge,infra,incomplete,null}"

count
out="$(sut append --dir "$D1" --row "$(row foo baseline | jq -c '.cost |= del(.tokens_out)')" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] || fail "8: cost missing tokens_out was accepted"
[[ "$out" == *'cost missing field(s): tokens_out'* ]] || fail "8: wrong/no error for incomplete cost (got: $out)"
ok "8 append refuses a cost object missing a required sub-field"

count
n="$(sut read --dir "$D1" | jq 'length')"
[ "$n" = "2" ] || fail "9: D1 should still hold exactly 2 rows after 6 rejected appends, has $n"
ok "9 none of the 6 rejected rows above were written to the ledger"

# ── 10-15. read ──────────────────────────────────────────────────────────────
count
out="$(sut read --dir "$D1")" || fail "10: read failed"
[ "$(jq 'length' <<<"$out")" = "2" ] && [ "$(jq -r '.[0].seq' <<<"$out")" = "1" ] \
  || fail "10: read did not return 2 rows sorted by seq (got: $out)"
ok "10 read returns every row, sorted by seq"

count
sut read --dir "$D1" --expect 2 >/dev/null || fail "11: --expect matching the true count must succeed"
ok "11 read --expect N succeeds when N matches the true row count"

count
out="$(sut read --dir "$D1" --expect 5 2>&1)"; rc=$?
[ "$rc" -ne 0 ] || fail "12: --expect 5 against 2 real rows must fail"
[[ "$out" == *"records missing"* ]] || fail "12: expected 'records missing' in output (got: $out)"
ok "12 read --expect N fails and prints 'records missing' when N exceeds the true count"

count
D2="$WORK/d2-gap"
sut append --dir "$D2" --row "$(row bar baseline)" >/dev/null
sut append --dir "$D2" --row "$(row bar candidate)" >/dev/null
sut append --dir "$D2" --row "$(row baz baseline)" >/dev/null
sed -n '1p;3p' "$D2/rows.jsonl" > "$D2/rows.jsonl.tmp" && mv "$D2/rows.jsonl.tmp" "$D2/rows.jsonl"
out="$(sut read --dir "$D2" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] || fail "13: a ledger missing its middle row (seq gap) must fail even with no --expect"
[[ "$out" == *"records missing"* ]] || fail "13: expected 'records missing' for a seq gap (got: $out)"
ok "13 read self-detects a seq gap (a truncated/edited ledger) with no --expect needed"

count
D3="$WORK/d3-partial"
sut append --dir "$D3" --row "$(row qux baseline)" >/dev/null
sut append --dir "$D3" --row "$(row qux candidate)" >/dev/null
printf '{"seq":3,"slug":"crashed-mid-write"' >>"$D3/rows.jsonl"   # no closing brace/newline
out="$(sut read --dir "$D3" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] || fail "14: a truncated trailing partial line must fail read"
[[ "$out" == *"records missing"* ]] || fail "14: expected 'records missing' for a partial trailing line (got: $out)"
ok "14 read detects a truncated trailing (crash-mid-write) line and reports 'records missing'"

count
D4="$WORK/d4-absent"
out="$(sut read --dir "$D4")"; rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "[]" ] || fail "15a: reading a never-created ledger with no --expect must be legal (empty array), got rc=$rc out=$out"
out="$(sut read --dir "$D4" --expect 1 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && [[ "$out" == *"records missing"* ]] || fail "15b: reading an absent ledger with --expect > 0 must fail as 'records missing'"
ok "15 an absent ledger reads as empty (legal, nothing expected) or 'records missing' (something was expected)"

# ── 16-18. archive / archive-check ──────────────────────────────────────────
count
REPO="$WORK/repo"
gitc init -q --initial-branch=main "$REPO"
gitc -C "$REPO" commit -q --allow-empty -m init
BASE_SHA="$(git -C "$REPO" rev-parse HEAD)"
gitc -C "$REPO" checkout -q -b conflict-base
echo "conflicting pre-existing content" >"$REPO/file.txt"
git -C "$REPO" add file.txt
gitc -C "$REPO" commit -q -m "conflict setup"
CONFLICT_SHA="$(git -C "$REPO" rev-parse HEAD)"
gitc -C "$REPO" checkout -q main
gitc -C "$REPO" checkout -q -b feature
echo hello >"$REPO/file.txt"
git -C "$REPO" add file.txt
gitc -C "$REPO" commit -q -m "add file"
HEAD_SHA="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" format-patch -1 --stdout HEAD >"$WORK/good.patch"
gitc -C "$REPO" checkout -q main

DL="$WORK/dl-archive"
sut append --dir "$DL" --row "$(row acme baseline | jq -c --arg b "$BASE_SHA" --arg h "$HEAD_SHA" '.base_sha=$b | .head_sha=$h')" >/dev/null
sut archive acme baseline --dir "$DL" --from "$WORK/good.patch" >/dev/null
[ -f "$DL/archives/acme@baseline.patch" ] || fail "16: archive did not write acme@baseline.patch"
ok "16 archive writes the per-(slug,arm) patch file"

count
out="$(sut archive-check acme baseline --dir "$DL" --repo "$REPO")"; rc=$?
[ "$rc" -eq 0 ] && [ "$(jq -r .outcome <<<"$out")" = "APPLIES" ] \
  || fail "17a: archive-check against the real base should APPLY (got rc=$rc out=$out)"
# The negative case is what actually DISCRIMINATES this from a check that
# always reports success: the SAME patch against a base whose file.txt
# already diverges must be REJECTED by git-am's own verdict.
out="$(sut archive-check acme baseline --dir "$DL" --repo "$REPO" --base "$CONFLICT_SHA" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && [ "$(jq -r .outcome <<<"$out" 2>/dev/null)" = "REJECTED" ] \
  || fail "17b: archive-check against a conflicting base should REJECT (got rc=$rc out=$out)"
# The real repo is never mutated by the check (it runs in a throwaway clone).
[ -z "$(git -C "$REPO" status --porcelain)" ] || fail "17c: archive-check left the real repo dirty"
[ "$(git -C "$REPO" rev-parse --abbrev-ref HEAD)" = "main" ] || fail "17c: archive-check left the real repo on the wrong branch"
ok "17 archive-check APPLIES a clean patch, REJECTS a conflicting one (git am's own verdict), and never mutates the real repo"

count
out="$(sut archive-check nosuch baseline --dir "$DL" --repo "$REPO" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && [[ "$out" == *"no archived patch at"* ]] || fail "18: a missing archive should die loudly (got rc=$rc out=$out)"
ok "18 archive-check dies loudly when no archive was ever saved for (slug,arm)"

# ── 19. purge ────────────────────────────────────────────────────────────────
count
DP="$WORK/dp-purge"
sut append --dir "$DP" --row "$(row p1 baseline)" >/dev/null
sut archive p1 baseline --dir "$DP" --from "$WORK/good.patch" >/dev/null
sut purge --dir "$DP" >/dev/null
[ -d "$DP" ] || fail "19a: a dry-run purge (no --yes) must not remove anything"
sut purge --dir "$DP" --yes >/dev/null
[ ! -e "$DP" ] || fail "19b: purge --yes must remove the whole ledger folder"
ok "19 purge is a dry-run without --yes and removes the whole folder with it"

# ── 20-22. prune ─────────────────────────────────────────────────────────────
count
DPR="$WORK/dpr-prune"
mkdir -p "$DPR/archives"
sut append --dir "$DPR" --row "$(row r1 baseline)" >/dev/null
echo old >"$DPR/archives/old@baseline.patch"
echo new >"$DPR/archives/new@baseline.patch"
old_epoch=$(( $(date -u +%s) - 40 * 86400 ))
touch -t "$(epoch_stamp "$old_epoch")" "$DPR/archives/old@baseline.patch"
sut prune --dir "$DPR" --retention-days 30 >/dev/null   # dry run: no removal
[ -f "$DPR/archives/old@baseline.patch" ] || fail "20a: a dry-run prune must not delete anything"
sut prune --dir "$DPR" --retention-days 30 --apply >/dev/null
[ ! -f "$DPR/archives/old@baseline.patch" ] || fail "20b: prune --apply did not remove the archive older than the retention window"
[ -f "$DPR/archives/new@baseline.patch" ] || fail "20c: prune --apply removed an archive NEWER than the retention window"
[ -f "$DPR/rows.jsonl" ] || fail "20d: prune must never touch rows.jsonl — only archives are retention-pruned"
ok "20 prune removes only archives older than the retention window, never rows.jsonl or newer archives"

count
out="$(DUAL_BUILD_ARCHIVE_RETENTION_DAYS=30 sut prune --dir "$DPR" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || fail "21: prune should honour DUAL_BUILD_ARCHIVE_RETENTION_DAYS when --retention-days is omitted (got rc=$rc: $out)"
ok "21 prune falls back to the DUAL_BUILD_ARCHIVE_RETENTION_DAYS setting (named-setting convention: symbolic reference, no local default)"

count
unset DUAL_BUILD_ARCHIVE_RETENTION_DAYS
# BUILD_CONFIG pointed at a path that cannot exist makes this genuinely
# unconfigured regardless of whether the sibling `dual-build-settings` item
# (#2071) has landed a DUAL_BUILD_ARCHIVE_RETENTION_DAYS row in the real
# build.config.sh by the time this suite runs — see BUILD_CONFIG's own
# "fixture-isolation override point" comment in the SUT.
out="$(BUILD_CONFIG="$WORK/no-such-build-config.sh" sut prune --dir "$DPR" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && [[ "$out" == *"no retention window configured"* ]] \
  || fail "22: prune with neither --retention-days nor the env setting should refuse clearly (got rc=$rc: $out)"
ok "22 prune refuses clearly (no silent default) when no retention window is configured at all"

# ── 23. machinery_version-bump fixture ──────────────────────────────────────
count
DMV="$WORK/dmv-bump"
sut append --dir "$DMV" --row "$(row mv baseline | jq -c '.machinery_version="v1"')" >/dev/null
sut append --dir "$DMV" --row "$(row mv candidate | jq -c '.machinery_version="v1"')" >/dev/null
# The bump: a later append under a DIFFERENT machinery_version, mid-stream.
sut append --dir "$DMV" --row "$(row mv2 baseline | jq -c '.machinery_version="v2"')" >/dev/null
out="$(sut read --dir "$DMV")" || fail "23: read failed across a machinery_version bump"
[ "$(jq 'length' <<<"$out")" = "3" ] || fail "23: expected 3 rows across the bump, got $(jq 'length' <<<"$out")"
[ "$(jq -r '.[2].seq' <<<"$out")" = "3" ] || fail "23: seq must stay monotonic across the bump"
[ "$(jq -r '.[0].machinery_version' <<<"$out")" = "v1" ] || fail "23: the pre-bump row's machinery_version was rewritten"
[ "$(jq -r '.[2].machinery_version' <<<"$out")" = "v2" ] || fail "23: the post-bump row does not carry the new machinery_version"
ok "23 rows written under two different machinery_version values interleave cleanly (seq monotonic, neither rewritten) — the machinery_version-bump fixture"

# ── 24. worktree-sweep fixture ──────────────────────────────────────────────
count
WREPO="$WORK/wrepo"
gitc init -q --initial-branch=main "$WREPO"
gitc -C "$WREPO" commit -q --allow-empty -m init
DWT="$WREPO/.temperloop/model-comparison/dual-build"
sut append --dir "$DWT" --row "$(row wt baseline)" >/dev/null
sut archive wt baseline --dir "$DWT" --from "$WORK/good.patch" >/dev/null
rows_before="$(shasum -a 256 "$DWT/rows.jsonl" | awk '{print $1}')"
arch_before="$(shasum -a 256 "$DWT/archives/wt@baseline.patch" | awk '{print $1}')"
# A worktree lifecycle (add + remove) is scoped to <repo>.wt/<slug>, a SIBLING
# of the repo, never inside it — this fixture proves that structural claim
# behaviourally rather than just asserting it by reading the path shape.
git -C "$WREPO" worktree add -q -b wt-probe "${WREPO}.wt/wt-probe" main
git -C "$WREPO" worktree remove --force "${WREPO}.wt/wt-probe"
git -C "$WREPO" worktree prune
git -C "$WREPO" branch -D wt-probe >/dev/null
rows_after="$(shasum -a 256 "$DWT/rows.jsonl" | awk '{print $1}')"
arch_after="$(shasum -a 256 "$DWT/archives/wt@baseline.patch" | awk '{print $1}')"
[ "$rows_before" = "$rows_after" ] || fail "24a: rows.jsonl changed across a worktree add+remove"
[ "$arch_before" = "$arch_after" ] || fail "24b: the patch archive changed across a worktree add+remove"
sut read --dir "$DWT" --expect 1 >/dev/null || fail "24c: the ledger failed its own consistency check after the worktree sweep"
rm -rf "${WREPO}.wt" 2>/dev/null
ok "24 the ledger dir + patch archive are byte-identical before/after a worktree add+remove — the worktree-sweep fixture"

# ── 25. schema_version/seq are ASSIGNED, never accepted from a caller ──────
count
D5="$WORK/d5-forged"
r="$(sut append --dir "$D5" --row "$(row forged baseline | jq -c '.seq=999 | .schema_version=42')")" || fail "25: append failed"
[ "$(jq -r .seq <<<"$r")" = "1" ] || fail "25a: a forged seq=999 in the input was not overridden (got $(jq -r .seq <<<"$r"))"
[ "$(jq -r .schema_version <<<"$r")" = "1" ] || fail "25b: a forged schema_version=42 in the input was not overridden (got $(jq -r .schema_version <<<"$r"))"
ok "25 append always assigns its own seq/schema_version, ignoring any caller-supplied values for them"

# ── 26. operator/host defaulting ────────────────────────────────────────────
count
r="$(sut append --dir "$D5" --row "$(row forged candidate | jq -c '.operator="alice" | .host="ci-runner-3"')")" || fail "26a: append failed"
[ "$(jq -r .operator <<<"$r")" = "alice" ] && [ "$(jq -r .host <<<"$r")" = "ci-runner-3" ] \
  || fail "26a: caller-supplied operator/host were not respected verbatim"
r="$(sut append --dir "$D5" --row "$(row forged2 baseline)")" || fail "26b: append failed"
[ -n "$(jq -r .operator <<<"$r")" ] && [ "$(jq -r .operator <<<"$r")" != "null" ] || fail "26b: an omitted operator was not defaulted"
[ -n "$(jq -r .host <<<"$r")" ] && [ "$(jq -r .host <<<"$r")" != "null" ] || fail "26b: an omitted host was not defaulted"
ok "26 operator/host are respected verbatim when supplied, and defaulted from the environment when omitted"

# ── 27-29. DATA-DIR vs SETTINGS resolution boundary (temperloop#2119) ──────
# Before #2119 the ledger DATA dir climbed from $0 to the kernel checkout,
# exactly like BUILD_CONFIG still does — so an adopter's rows, archives and
# calibration.json landed in the KERNEL's .temperloop/, and two repos
# dual-building on one host silently shared one ledger. Two throwaway git
# repos discriminate the fix directly, in BOTH states (principle 1): repo A's
# row must be visible from repo A's cwd and invisible from repo B's.
REPO_A="$WORK/repoA"; REPO_B="$WORK/repoB"
mkdir -p "$REPO_A" "$REPO_B"
gitc init -q --initial-branch=main "$REPO_A"
gitc init -q --initial-branch=main "$REPO_B"
# The kernel checkout this SUT actually lives in — the dir the OLD $0 climb
# resolved to. Nothing this section writes may land under it.
KERNEL_ROOT="$(cd -P "$HERE/../../../.." && pwd)"
KERNEL_ROWS="$KERNEL_ROOT/.temperloop/model-comparison/dual-build/rows.jsonl"
# Fingerprint of the kernel checkout's own ledger BEFORE this section runs —
# "absent" when there is none. The old $0 climb wrote exactly here, so this
# is the file that must not move.
kernel_rows_fingerprint() {
  if [ -f "$KERNEL_ROWS" ]; then shasum -a 256 "$KERNEL_ROWS" | awk '{print $1}'; else echo absent; fi
}
KERNEL_ROWS_BEFORE="$(kernel_rows_fingerprint)"

count
outA="$(cd "$REPO_A" && env -u DUAL_BUILD_LEDGER_DIR bash "$SUT" append --row "$(row cwdscope baseline)")" \
  || fail "27: append from repo A's cwd with no --dir failed"
[ -f "$REPO_A/.temperloop/model-comparison/dual-build/rows.jsonl" ] \
  || fail "27a: the row did not land under repo A's OWN .temperloop/model-comparison/dual-build/"
[ "$(kernel_rows_fingerprint)" = "$KERNEL_ROWS_BEFORE" ] \
  || fail "27b: the append touched the KERNEL checkout's ledger at $KERNEL_ROWS — the \$0 climb is still in play"
[ "$(jq -r .seq <<<"$outA")" = "1" ] || fail "27c: the first row in repo A's own ledger must be seq 1"
ok "27 the default ledger dir resolves from the CWD's git toplevel, not the \$0 climb to the kernel checkout"

count
nA="$(cd "$REPO_A" && env -u DUAL_BUILD_LEDGER_DIR bash "$SUT" read | jq 'length')" || fail "28: read from repo A failed"
nB="$(cd "$REPO_B" && env -u DUAL_BUILD_LEDGER_DIR bash "$SUT" read | jq 'length')" || fail "28: read from repo B failed"
[ "$nA" = "1" ] || fail "28a: repo A's own row is NOT visible when read with cwd = repo A (got $nA)"
[ "$nB" = "0" ] || fail "28b: repo A's row LEAKED into a read with cwd = repo B (got $nB)"
ok "28 a row written with cwd = repo A is visible from repo A and NOT visible from repo B (isolation, both states)"

count
# The settings half of the boundary, discriminated rather than asserted: a
# DECOY build.config.sh planted inside repo A would redirect the ledger if
# settings followed the cwd. They must keep climbing from $0, so it is never
# sourced and the row still lands in repo A's own default ledger dir.
mkdir -p "$REPO_A/workflows/scripts/build"
printf 'DUAL_BUILD_LEDGER_DIR=%s\n' "$WORK/decoy-ledger" >"$REPO_A/workflows/scripts/build/build.config.sh"
( cd "$REPO_A" && env -u DUAL_BUILD_LEDGER_DIR -u BUILD_CONFIG bash "$SUT" append --row "$(row decoy candidate)" ) >/dev/null \
  || fail "29: append from repo A with a decoy build.config.sh failed"
[ ! -e "$WORK/decoy-ledger" ] \
  || fail "29a: the cwd repo's DECOY build.config.sh was sourced — settings must keep the \$0 climb (temperloop#980)"
[ "$(cd "$REPO_A" && env -u DUAL_BUILD_LEDGER_DIR bash "$SUT" read | jq 'length')" = "2" ] \
  || fail "29b: the second row did not land in repo A's own ledger"
# And a cwd outside any checkout REFUSES by name rather than falling back.
out="$(cd "$WORK" && env -u DUAL_BUILD_LEDGER_DIR bash "$SUT" read 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && [[ "$out" == *"no ledger dir"* ]] \
  || fail "29c: a cwd outside any git checkout must refuse by name, not fall back (got rc=$rc: $out)"
[ "$(kernel_rows_fingerprint)" = "$KERNEL_ROWS_BEFORE" ] \
  || fail "29d: the un-resolvable-cwd path fell back to the kernel checkout's ledger"
ok "29 settings keep the \$0 climb (a decoy build.config.sh in the cwd repo is never sourced) and an un-resolvable cwd refuses by name"

# ── 30. the additive, backward-compatible `repo` row field ─────────────────
count
r="$(cd "$REPO_A" && env -u DUAL_BUILD_LEDGER_DIR bash "$SUT" append --row "$(row repofield baseline)")" \
  || fail "30: append failed"
[ "$(jq -r .repo <<<"$r")" = "$(cd "$REPO_A" && pwd -P)" ] \
  || fail "30a: repo was not stamped with the invoking repo's toplevel (got $(jq -r .repo <<<"$r"))"
r="$(cd "$REPO_A" && env -u DUAL_BUILD_LEDGER_DIR bash "$SUT" append --row "$(row repofield candidate | jq -c '.repo="/elsewhere/repoZ"')")" \
  || fail "30: append with a caller-supplied repo failed"
[ "$(jq -r .repo <<<"$r")" = "/elsewhere/repoZ" ] \
  || fail "30b: a caller-supplied repo was not respected verbatim"
# BACKWARD COMPATIBILITY: a ledger of PRE-#2119 rows — no `repo` key at all —
# must still read, self-check and tally. Built by stripping the key from real
# appended rows, so this fixture can never drift from the writer's own shape.
DOLD="$WORK/d-oldrows"
mkdir -p "$DOLD"
( cd "$REPO_A" && env -u DUAL_BUILD_LEDGER_DIR bash "$SUT" read ) \
  | jq -c '.[] | del(.repo)' >"$DOLD/rows.jsonl" || fail "30: could not build the old-row fixture"
grep -q '"repo"' "$DOLD/rows.jsonl" && fail "30c-guard: the old-row fixture still carries a repo key"
old_n="$(sut read --dir "$DOLD" | jq 'length')" || fail "30c: reading a ledger of rows with NO repo field failed"
[ "$old_n" = "4" ] || fail "30c: expected 4 old-style rows to read back, got $old_n"
[ "$(sut read --dir "$DOLD" | jq '[.[] | select(has("repo"))] | length')" = "0" ] \
  || fail "30d: read invented a repo key on rows that never had one"
sut read --dir "$DOLD" --expect 4 >/dev/null || fail "30e: the --expect self-check failed over old-style rows"
# And a NEW row appends cleanly onto an old-style ledger (mixed file).
sut append --dir "$DOLD" --row "$(row mixed baseline)" >/dev/null || fail "30f: appending onto an old-style ledger failed"
[ "$(sut read --dir "$DOLD" | jq 'length')" = "5" ] || fail "30g: the mixed old+new ledger did not read back"
ok "30 repo is stamped from the cwd, respected verbatim when supplied, and rows with NO repo key still read, self-check and accept new appends"

printf '\ntest_dual_build_ledger.sh: %d/%d checks passed\n' "$pass" "$total"
[ "$pass" -eq "$total" ] || exit 1
