#!/usr/bin/env bash
#
# source.sh — the testbed SOURCE-PROVIDER seam (temperloop#1228/#1230, epic
# #1117 Produces 2): the interface `temperloop testbed` resolves a source
# through, plus its two implementations — `mirror-from-repo` (the reader's
# own repository) and `materialize-from-seed` (a prepared project tracked in
# this repository, materialized into the reader's own account).
#
# WHY FIVE FUNCTIONS, NOT ONE TUPLE (temperloop#1228 notes; the fifth,
# `dir_arg()`, landed with temperloop#1356 — see "PROVIDER-SCOPED DIRECTORY
# ARGUMENT RESOLUTION" below): the epic's Contract described this seam as a
# single five-member tuple (`{git content, issue list, default name,
# provenance-capable, promotable}`), which conflated RESOLVE-TIME capability
# (what kind of source is this, and can pre-flight check it) with
# EXECUTE-TIME work products (the git content, the issues) and left
# pre-flight vestigial for the one check it exists for: a command must be
# able to describe + pre-flight a source with ZERO writes, before it ever
# creates anything. Splitting into separate members fixes that:
#
#   dir_arg(dir, seed_dir) -> the ONE of the driver's two CLI-level
#                              directory values (--dir, --seed-dir) that
#                              THIS provider's directory argument actually
#                              means — see "PROVIDER-SCOPED DIRECTORY
#                              ARGUMENT RESOLUTION" below. Resolvable with
#                              ZERO reads of any kind: it is a pure string
#                              selection, never a filesystem or network
#                              call.
#   describe([dir])         -> {kind, base_name, source_repo,
#                              provenance_capable, promotable} —
#                              resolvable with ZERO network writes and ZERO
#                              content fetching, so pre-flight can run
#                              before anything is produced. `dir` is this
#                              provider's OWN resolved directory argument
#                              (dir_arg()'s return value), never a
#                              driver-level CLI flag directly. `source_repo`
#                              is `"<owner>/<name>"` when THIS PROVIDER'S
#                              OWN resolved `dir` names a github.com
#                              `origin` remote, else JSON `null` — see
#                              "SOURCE IDENTITY IS SEAM DATA, NOT
#                              DRIVER-COMPUTED" below (temperloop#1357).
#   preflight_checks([dir]) -> the provider's own all-reads checks, as a
#                              list of zero-arg shell function NAMES the
#                              driver invokes in order. This is the ONE seam
#                              that eliminates the per-provider `case` this
#                              interface exists to avoid: the command's
#                              driver runs whatever this yields and NEVER
#                              branches on provider kind to decide which
#                              checks apply.
#   produce_git(dest, [dir]) -> materializes the source's git content by
#                              pushing it to `dest` (a git push target —
#                              URL or local path; the driving command
#                              resolves the newly-created destination repo
#                              into a pushable target before calling this).
#   produce_issues(dest, [dir]) -> creates the source's carried-over issues
#                              on `dest` (an `OWNER/NAME` repo slug, for
#                              `gh issue create --repo`).
#
# `describe()` yields `base_name`, NOT a final name — collision-safe
# uniquification against an existing repo is a shared DOWNSTREAM concern
# (the command driver's), not each provider's own job.
#
# PROVIDER-SCOPED DIRECTORY ARGUMENT RESOLUTION (temperloop#1356). Before
# this, `describe`/`preflight_checks`/`produce_git`/`produce_issues` all took
# their provider's directory as a single trailing arg the DRIVER supplied
# directly from its own `--dir` (default `.`) — fine for mirror-from-repo,
# whose directory argument genuinely IS "the source repository directory",
# but wrong for materialize-from-seed, whose directory argument means
# something else entirely ("which seed directory") and whose own in-tree
# default (`_TESTBED_SEED_DIR_DEFAULT` below) only applies when that
# argument is EMPTY — so the driver's `.` default silently reached this
# provider too and overrode its default from any cwd, yielding a `.`-derived
# testbed name. `dir_arg()` fixes that WITHOUT a `case` on kind anywhere in
# the driver (bin/subcommands/testbed.sh has none — see its own T2 test) and
# without a `case` on kind in this file's public dispatch either (`dir_arg`
# dispatches by function-name lookup, exactly like the other four members;
# `testbed_source__fn`/`testbed_source__require` below never branch on a
# literal kind string). The driver calls `testbed_source_dir_arg <kind>
# <dir> <seed_dir>` ONCE, passing BOTH of its own CLI-level values
# (`--dir`, `--seed-dir`) unconditionally, for every kind; each provider's
# OWN `dir_arg()` implementation picks whichever one is actually its own
# and returns THAT — mirror-from-repo's returns `dir` (arg 1), ignoring
# `seed_dir`; materialize-from-seed's returns `seed_dir` (arg 2), ignoring
# `dir`. The driver then threads that ONE resolved value into
# describe/preflight_checks/produce_git/produce_issues exactly as before —
# their own arg-position contracts (documented above and per-provider
# below) are UNCHANGED by this. "The provider seam owns what its directory
# argument means" cashes out mechanically to: each provider states, in its
# own `dir_arg()`, which of the driver's CLI-level directory concepts is
# its own — never the driver inspecting `kind` to decide.
#
# SOURCE IDENTITY IS SEAM DATA, NOT DRIVER-COMPUTED (temperloop#1357, epic
# #1411). Before this, the driver (bin/subcommands/testbed.sh) computed a
# `source_slug` itself — a bare `git remote get-url origin` read in the
# DRIVER's cwd — identically for both providers, and fed that one value into
# the handoff banner, the consent block, and the persisted record. That is
# wrong for materialize-from-seed in exactly the same shape #1356 fixed for
# directory arguments: the driver's cwd is not this provider's source at
# all, so running a seed testbed from inside ANY git checkout that happens
# to have an `origin` (the likely case for someone trying the demo from a
# clone) silently captured an UNRELATED repository's slug — a schema
# violation record.sh's own docs rule out (`.source_repo` is "null for
# materialize-from-seed"). `dir_arg()` alone did not fix this: it resolves
# WHICH directory a provider's functions receive, but the driver never
# threaded that resolved directory through to a slug computation at all —
# it kept reading its own cwd regardless of kind.
#
# The fix folds source identity into `describe()`, the seam member the
# driver already calls exactly once, already dispatched by kind, already
# given each provider's own resolved directory argument
# (`provider_dir_arg`, mirror-from-repo's `dir_arg()` implementation
# returns its OWN checkout path, never a stray cwd). `describe()`'s JSON
# payload carries a `source_repo` field: mirror-from-repo's own
# implementation resolves it from ITS OWN `source_dir` argument (the exact
# same read `base_name` already derives its slug from, just also
# returned); materialize-from-seed's implementation returns `null`
# unconditionally — there is no upstream repository to name, ever,
# regardless of what git checkout the command happened to be run from. The
# driver reads `.source_repo` off the ALREADY-RESOLVED `describe()` payload
# instead of re-deriving anything itself — no `case` on kind, no second
# slug parser, no dependence on the driver's own cwd.
#
# PROVENANCE STAMPING (Produces 5): `mirror-from-repo`'s `produce_issues`
# stamps a machine-readable `copied from <owner>/<repo>#<N>` line into every
# issue IT creates — inside its own `produce_issues`, not in shared
# downstream code. Promotion (a later item) resolves correspondence by exact
# lookup on that line; a provider that has no upstream issue to cite
# (`materialize-from-seed`) simply never stamps one, and reports
# `provenance_capable: false` from `describe()` so callers never expect it
# to.
#
# ── Provider dispatch (mirrors workflows/scripts/lib/knowledge_store.sh's
# backend-dispatch shape: `ks__dispatch` / `_ks_backend_<name>_<op>`) ───────
# A provider is a set of five `_testbed_provider_<name>_<op>` functions,
# where <name> is the provider's kebab-case `kind` with '-' -> '_'
# (`mirror-from-repo` -> `mirror_from_repo`). Registering a new provider
# means defining its five functions and sourcing that file before use — no
# change to the dispatcher below, and no `case` on kind anywhere in this
# file either. `materialize-from-seed` (temperloop#1230) is the worked
# proof of that shape for the original four — the dispatcher, the public
# seam members, and every downstream caller are byte-for-byte unchanged by
# a new provider's arrival.
#
# This file is SOURCED — it sets no shell options (the caller owns
# `set -euo pipefail`; see knowledge_store.sh's own header for the same
# convention). Requires: bash, git, jq always; gh only for the network-
# touching ops (`preflight_checks`'s gh-auth check, and mirror-from-repo's
# `produce_issues`) — never for `describe()`.

# <kind> <op> -> the provider function name dispatch resolves to.
testbed_source__fn() {
  local kind="$1" op="$2"
  printf '_testbed_provider_%s_%s\n' "${kind//-/_}" "$op"
}

# <fn> <kind> <op> -> exit 0 if <fn> is a defined function, else exit 2 with
# a legible message naming the missing provider/op (mirrors ks__dispatch's
# unknown-backend guard).
testbed_source__require() {
  local fn="$1" kind="$2" op="$3"
  if ! command -v "$fn" >/dev/null 2>&1; then
    printf 'testbed-source: provider "%s" does not implement "%s" (no %s defined)\n' \
      "$kind" "$op" "$fn" >&2
    return 2
  fi
}

# ── Public interface — the five seam members, kind-dispatched ──────────────
# testbed_source_dir_arg <kind> <dir> <seed_dir>         -> resolved dir arg
# testbed_source_describe <kind> [args...]              -> JSON on stdout
# testbed_source_preflight_checks <kind> [args...]      -> fn names on stdout
# testbed_source_produce_git <kind> <dest> [args...]    <- pushes git content
# testbed_source_produce_issues <kind> <dest> [args...] <- creates issues
# Every call dispatches on <kind> alone; no caller of this seam may branch
# on provider kind itself — that is exactly the per-provider `case` this
# interface exists to eliminate downstream.
testbed_source_dir_arg() {
  local kind="$1"; shift
  local fn; fn="$(testbed_source__fn "$kind" dir_arg)"
  testbed_source__require "$fn" "$kind" dir_arg || return $?
  "$fn" "$@"
}

testbed_source_describe() {
  local kind="$1"; shift
  local fn; fn="$(testbed_source__fn "$kind" describe)"
  testbed_source__require "$fn" "$kind" describe || return $?
  "$fn" "$@"
}

testbed_source_preflight_checks() {
  local kind="$1"; shift
  local fn; fn="$(testbed_source__fn "$kind" preflight_checks)"
  testbed_source__require "$fn" "$kind" preflight_checks || return $?
  "$fn" "$@"
}

testbed_source_produce_git() {
  local kind="$1"; shift
  local fn; fn="$(testbed_source__fn "$kind" produce_git)"
  testbed_source__require "$fn" "$kind" produce_git || return $?
  "$fn" "$@"
}

testbed_source_produce_issues() {
  local kind="$1"; shift
  local fn; fn="$(testbed_source__fn "$kind" produce_issues)"
  testbed_source__require "$fn" "$kind" produce_issues || return $?
  "$fn" "$@"
}

# ── shared helpers (kept file-private with a leading underscore since they
# are not part of the seam) ────────────────────────────────────────────────
# All-reads check: gh is present and authenticated. BOTH providers' own
# `check_gh_auth` delegate here rather than each carrying its own copy —
# every provider that files issues needs exactly this check with exactly
# this wording, and two copies is how the two wordings drift apart. The
# per-provider wrapper names stay distinct because `preflight_checks()`
# yields function NAMES and the driver runs whatever it is handed; the
# shared body is an implementation detail beneath that seam, not a change
# to it.
_testbed_check_gh_auth() {
  if ! command -v gh >/dev/null 2>&1; then
    echo "skipped — gh CLI not found on PATH" >&2
    return 1
  fi
  if ! gh auth status >/dev/null 2>&1; then
    echo "skipped — gh is not authenticated (run: gh auth login)" >&2
    return 1
  fi
}

# <remote-url> -> best-effort github.com "owner/repo" extraction. Same shape
# as conventions-probe.sh's slug_from_remote / baseline-snapshot.sh's
# sibling — deliberately re-derived here rather than sourced from either
# (both are standalone `set -euo pipefail` scripts, not sourceable libs).
# Prints empty on no match; never fails.
_testbed_slug_from_remote() {
  local url="$1" slug=""
  case "$url" in
    git@github.com:*) slug="${url#git@github.com:}" ;;
    ssh://git@github.com/*) slug="${url#ssh://git@github.com/}" ;;
    https://github.com/*) slug="${url#https://github.com/}" ;;
    http://github.com/*) slug="${url#http://github.com/}" ;;
    *) slug="" ;;
  esac
  slug="${slug%.git}"
  slug="${slug%/}"
  printf '%s' "$slug"
}

# ═══════════════════════════════════════════════════════════════════════════
# Provider: mirror-from-repo — the reader's own repository. Provenance-
# capable, promotable. The source is a LOCAL git checkout (default: `.`,
# the caller's cwd) — every function below takes that checkout's path as an
# optional trailing/second argument, defaulting to `.`. The DRIVER resolves
# that value through this provider's own `dir_arg()` (below), never from its
# `--dir` flag directly — see "PROVIDER-SCOPED DIRECTORY ARGUMENT
# RESOLUTION" in this file's header.
# ═══════════════════════════════════════════════════════════════════════════

# <dir> <seed_dir> -> returns <dir> verbatim: mirror-from-repo's directory
# argument IS the driver's `--dir` value; it has no use for `--seed-dir`.
# Zero reads — a pure string selection, safe to call before anything else.
_testbed_provider_mirror_from_repo_dir_arg() {
  printf '%s' "${1:-}"
}

# [source-dir] -> JSON {kind, base_name, source_repo, provenance_capable,
# promotable} on stdout. ZERO network calls: `git remote get-url` is a local
# config read, never a network round-trip, so this is safe to call before
# pre-flight has run or anything has been created. base_name falls back to
# the checkout's directory basename when no `origin` remote is configured
# (or it isn't a recognized github.com form) — still zero-network either
# way. `source_repo` is the SAME slug read, from THIS provider's OWN
# `source_dir` argument — never the driver's cwd (temperloop#1357) — and is
# JSON null exactly when base_name had to fall back (no resolvable slug).
_testbed_provider_mirror_from_repo_describe() {
  local source_dir="${1:-.}" url slug base_name
  url="$(git -C "$source_dir" remote get-url origin 2>/dev/null || true)"
  slug="$(_testbed_slug_from_remote "$url")"
  if [ -n "$slug" ]; then
    base_name="${slug##*/}"
  else
    base_name="$(basename "$(git -C "$source_dir" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$source_dir")")"
  fi
  jq -cn --arg kind "mirror-from-repo" --arg base_name "$base_name" --arg source_repo "$slug" \
    '{kind: $kind, base_name: $base_name, source_repo: (if $source_repo == "" then null else $source_repo end), provenance_capable: true, promotable: true}'
}

# [source-dir] -> newline-separated preflight check function NAMES (zero
# args each) on stdout. Stashes source-dir in a provider-scoped global so
# the printed check functions stay parameterless — the driver invokes
# whatever this yields with no further context, per the seam contract.
_TESTBED_MIRROR_SOURCE_DIR="."
_testbed_provider_mirror_from_repo_preflight_checks() {
  _TESTBED_MIRROR_SOURCE_DIR="${1:-.}"
  printf '%s\n' \
    _testbed_provider_mirror_from_repo_check_git_repo \
    _testbed_provider_mirror_from_repo_check_gh_auth
}

# All-reads check: the source dir is a real git working tree (mirroring
# needs real history to push). `skipped —` on failure, naming the fix,
# consistent with this repo's established degradation wording (e.g.
# bin/subcommands/init.sh, baseline-snapshot.sh).
_testbed_provider_mirror_from_repo_check_git_repo() {
  local dir="${_TESTBED_MIRROR_SOURCE_DIR:-.}"
  if ! git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "skipped — $dir is not a git working tree (mirror-from-repo mirrors a real git checkout)" >&2
    return 1
  fi
}

# All-reads check: gh is present and authenticated (produce_issues needs it
# to read the source's issues and create them on the destination).
_testbed_provider_mirror_from_repo_check_gh_auth() {
  _testbed_check_gh_auth
}

# <dest> [source-dir] -> mirror-pushes every ref (branches + tags) from
# source-dir's local git history to <dest>, a git push target (URL or local
# path — the driving command resolves the newly-created destination repo
# into one before calling this; this function is agnostic to what kind of
# target it is, which is what makes it testable against a plain local bare
# repo with zero network).
_testbed_provider_mirror_from_repo_produce_git() {
  local dest="${1:?testbed-source(mirror-from-repo): produce_git requires a destination git push target}"
  local source_dir="${2:-.}"
  local out
  if ! out="$(git -C "$source_dir" push --mirror "$dest" 2>&1)"; then
    printf 'testbed-source(mirror-from-repo): git push --mirror to %s failed: %s\n' "$dest" "$out" >&2
    return 1
  fi
}

# <dest> [source-dir] -> reads source-dir's open issues (via gh, from the
# repo its `origin` remote names) and creates one issue per source issue on
# <dest> (an OWNER/NAME repo slug), each body carrying a machine-readable
# `copied from <owner>/<repo>#<N>` line — stamped HERE, inside this
# provider's own produce_issues, never in shared downstream code (Produces
# 5). Prints the count copied on success.
_testbed_provider_mirror_from_repo_produce_issues() {
  local dest="${1:?testbed-source(mirror-from-repo): produce_issues requires a destination owner/repo}"
  local source_dir="${2:-.}"
  local source_url source_slug issues_json n i count=0

  command -v gh >/dev/null 2>&1 \
    || { echo "testbed-source(mirror-from-repo): gh CLI not found on PATH" >&2; return 1; }
  command -v jq >/dev/null 2>&1 \
    || { echo "testbed-source(mirror-from-repo): jq not found on PATH" >&2; return 1; }

  source_url="$(git -C "$source_dir" remote get-url origin 2>/dev/null || true)"
  source_slug="$(_testbed_slug_from_remote "$source_url")"
  if [ -z "$source_slug" ]; then
    printf 'testbed-source(mirror-from-repo): cannot resolve source owner/repo from %s'"'"'s origin remote (%s)\n' \
      "$source_dir" "$source_url" >&2
    return 1
  fi

  if ! issues_json="$(gh issue list --repo "$source_slug" --state open --json number,title,body 2>&1)"; then
    printf 'testbed-source(mirror-from-repo): gh issue list on %s failed: %s\n' "$source_slug" "$issues_json" >&2
    return 1
  fi

  n="$(printf '%s' "$issues_json" | jq 'length')"
  i=0
  while [ "$i" -lt "$n" ]; do
    local entry num title body provenance full_body create_out
    entry="$(printf '%s' "$issues_json" | jq -c ".[$i]")"
    num="$(printf '%s' "$entry" | jq -r '.number')"
    title="$(printf '%s' "$entry" | jq -r '.title')"
    body="$(printf '%s' "$entry" | jq -r '.body // ""')"
    provenance="copied from ${source_slug}#${num}"
    full_body="$(printf '%s\n\n---\n%s\n' "$body" "$provenance")"
    if ! create_out="$(gh issue create --repo "$dest" --title "$title" --body "$full_body" 2>&1)"; then
      printf 'testbed-source(mirror-from-repo): gh issue create on %s failed for source #%s: %s\n' \
        "$dest" "$num" "$create_out" >&2
      return 1
    fi
    count=$((count + 1))
    i=$((i + 1))
  done
  printf 'testbed-source(mirror-from-repo): copied %s issue(s) from %s to %s\n' "$count" "$source_slug" "$dest"
}

# ═══════════════════════════════════════════════════════════════════════════
# Provider: materialize-from-seed — a prepared project whose content is
# TRACKED IN THIS REPOSITORY, materialized into a private repo in the
# OPERATOR'S OWN account (ADR 0025: "any artifact this toolkit creates for
# evaluation purposes is materialized into the operator's own account, from
# content tracked in this repository"). NOT provenance-capable (there is no
# upstream issue to cite) and NOT promotable (there is no original to
# promote back to) — `describe()` reports both as false so no caller ever
# expects otherwise.
#
# NO PROJECT-OWNED REPOSITORY EXISTS AT ANY POINT. Nothing below names,
# reads, clones, or forks a remote this project controls: the git content is
# built locally from tracked files and pushed to the caller-supplied `dest`,
# and the issues are created on that same `dest`. The only remote touched is
# the one the driving command just created in the operator's account.
#
# The source is a SEED DIRECTORY (default: `workflows/scripts/demo/seed`,
# resolved relative to this file so it works from any cwd) laid out as:
#
#   seed.json     {name, description, default_branch} — describe() reads it
#   project/      copied verbatim into a fresh git repo and pushed
#   issues/*.md   one issue each, `# <title>` on line 1, body after it
#
# Every function below takes that seed directory as an optional
# trailing/second argument, exactly mirroring how mirror-from-repo takes its
# source checkout — same arity, same position, so the driver calls both
# identically and TEARDOWN (which only ever reads the artifact record the
# driver writes) sees no difference between a seed testbed and any other.
# The DRIVER resolves that value through this provider's own `dir_arg()`
# (below), never from its `--dir` flag directly — see "PROVIDER-SCOPED
# DIRECTORY ARGUMENT RESOLUTION" in this file's header; that is precisely
# what keeps a `--dir`/cwd value from ever reaching this provider's naming
# again (temperloop#1356).
# ═══════════════════════════════════════════════════════════════════════════

# Resolved once at source time from this file's own location, so a caller in
# any cwd gets the in-tree seed by default. Empty when the seed directory is
# absent (a consumer that vendored source.sh without the seed) — the
# preflight check below is what reports that legibly.
_TESTBED_SEED_DIR_DEFAULT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../demo/seed" 2>/dev/null && pwd || printf '%s' '')"

# [seed-dir] -> the seed directory to use (the argument, else the in-tree
# default). File-private, not a seam member.
_testbed_seed_dir() {
  local given="${1:-}"
  if [ -n "$given" ]; then printf '%s' "$given"; else printf '%s' "$_TESTBED_SEED_DIR_DEFAULT"; fi
}

# <dir> <seed_dir> -> returns <seed_dir> verbatim: materialize-from-seed's
# directory argument IS the driver's `--seed-dir` value, never `--dir` (that
# belongs to mirror-from-repo alone). Zero reads — a pure string selection,
# safe to call before anything else. This is the fix for temperloop#1356:
# before `dir_arg()` existed, the driver had no way to hand this provider
# `--seed-dir` instead of `--dir` without branching on kind, so it always
# received `--dir`'s value (default `.`) and silently overrode its own
# in-tree seed default.
_testbed_provider_materialize_from_seed_dir_arg() {
  printf '%s' "${2:-}"
}

# [seed-dir] -> JSON {kind, base_name, source_repo, provenance_capable,
# promotable} on stdout. ZERO network calls and zero content fetching:
# `seed.json` is a tracked local file, so this is safe to call before
# pre-flight has run or anything has been created. base_name comes from the
# seed's own `name`, falling back to the seed directory's basename so a
# malformed or absent seed.json still yields a usable name rather than
# failing describe() (the preflight check is where a broken seed is
# reported, not here). `source_repo` is UNCONDITIONALLY JSON null — there is
# no upstream repository here to name, ever, no matter what git checkout (if
# any) the command happens to be run from (temperloop#1357: this is exactly
# what keeps a materialize-from-seed run from ever reporting some OTHER
# repository — e.g. whatever the caller's cwd's `origin` happens to be — as
# its source).
_testbed_provider_materialize_from_seed_describe() {
  local seed_dir base_name=""
  seed_dir="$(_testbed_seed_dir "${1:-}")"
  if [ -f "$seed_dir/seed.json" ]; then
    base_name="$(jq -r '.name // empty' "$seed_dir/seed.json" 2>/dev/null || true)"
  fi
  if [ -z "$base_name" ]; then
    base_name="$(basename "${seed_dir:-seed}")"
  fi
  jq -cn --arg kind "materialize-from-seed" --arg base_name "$base_name" \
    '{kind: $kind, base_name: $base_name, source_repo: null, provenance_capable: false, promotable: false}'
}

# [seed-dir] -> newline-separated preflight check function NAMES (zero args
# each) on stdout. Same shape as mirror-from-repo's: the seed dir is stashed
# in a provider-scoped global so the printed check functions stay
# parameterless, per the seam contract.
_TESTBED_SEED_SOURCE_DIR=""
_testbed_provider_materialize_from_seed_preflight_checks() {
  _TESTBED_SEED_SOURCE_DIR="$(_testbed_seed_dir "${1:-}")"
  printf '%s\n' \
    _testbed_provider_materialize_from_seed_check_seed_content \
    _testbed_provider_materialize_from_seed_check_gh_auth
}

# All-reads check: the seed directory is present and complete — a project
# tree with at least one file to push, and at least one issue definition to
# file. `skipped —` on failure naming the fix, consistent with
# mirror-from-repo's checks and this repo's established degradation wording.
_testbed_provider_materialize_from_seed_check_seed_content() {
  # Falls back to the in-tree default (exactly as mirror-from-repo's checks
  # fall back to `.`) so the check is still meaningful when the caller
  # captured `preflight_checks` in a command substitution — a subshell, whose
  # assignment to the provider-scoped global never reaches the parent.
  local dir="${_TESTBED_SEED_SOURCE_DIR:-$_TESTBED_SEED_DIR_DEFAULT}"
  if [ -z "$dir" ] || [ ! -d "$dir" ]; then
    echo "skipped — seed directory not found at '${dir:-<unset>}' (materialize-from-seed needs the in-tree seed content)" >&2
    return 1
  fi
  if [ ! -d "$dir/project" ] || [ -z "$(find "$dir/project" -type f -print -quit 2>/dev/null)" ]; then
    echo "skipped — $dir/project is missing or empty (nothing to materialize)" >&2
    return 1
  fi
  if [ ! -d "$dir/issues" ] || [ -z "$(find "$dir/issues" -name '*.md' -type f -print -quit 2>/dev/null)" ]; then
    echo "skipped — $dir/issues holds no *.md issue definitions (nothing to file)" >&2
    return 1
  fi
}

# All-reads check: gh is present and authenticated (produce_issues needs it
# to create the seed's issues on the destination). Delegates to the shared
# helper — one wording for both providers.
_testbed_provider_materialize_from_seed_check_gh_auth() {
  _testbed_check_gh_auth
}

# <dest> [seed-dir] -> builds a fresh single-commit git repository from the
# seed's `project/` tree in a temp dir and mirror-pushes it to <dest>, a git
# push target (URL or local path). Deliberately the SAME final mechanism as
# mirror-from-repo — `git push --mirror <dest>` — so everything downstream of
# this seam (the artifact record, teardown, the driver) sees one shape, and
# so this is testable against a plain local bare repo with zero network.
#
# The commit identity is pinned with `-c` overrides rather than read from the
# operator's git config: the seed is fixture content, not their authorship,
# and a host with no user.email configured must not fail here. Signing is
# forced off for the same reason.
_testbed_provider_materialize_from_seed_produce_git() {
  local dest="${1:?testbed-source(materialize-from-seed): produce_git requires a destination git push target}"
  local seed_dir work branch out rc=0
  seed_dir="$(_testbed_seed_dir "${2:-}")"

  if [ ! -d "$seed_dir/project" ]; then
    printf 'testbed-source(materialize-from-seed): seed project tree not found at %s/project\n' "$seed_dir" >&2
    return 1
  fi

  branch="$(jq -r '.default_branch // "main"' "$seed_dir/seed.json" 2>/dev/null || true)"
  [ -n "$branch" ] || branch="main"

  work="$(mktemp -d "${TMPDIR:-/tmp}/testbed-seed-XXXXXX")" || {
    echo "testbed-source(materialize-from-seed): could not create a temp working directory" >&2
    return 1
  }

  # tar-pipe rather than `cp -R`: it carries dotfiles and is identical on
  # BSD and GNU userlands (`cp -R src/. dst` differs subtly between them).
  if ! out="$( { (cd "$seed_dir/project" && tar cf - .) | (cd "$work" && tar xf -); } 2>&1 )"; then
    printf 'testbed-source(materialize-from-seed): copying the seed project tree failed: %s\n' "$out" >&2
    rm -rf "$work"
    return 1
  fi

  if ! out="$( {
    git -C "$work" init -q \
      && git -C "$work" symbolic-ref HEAD "refs/heads/$branch" \
      && git -C "$work" add -A \
      && git -C "$work" \
        -c user.name="temperloop testbed" \
        -c user.email="testbed@localhost" \
        -c commit.gpgsign=false \
        commit -q -m "Initial commit — temperloop testbed seed project" \
      && git -C "$work" push --mirror "$dest"
  } 2>&1 )"; then
    rc=1
    printf 'testbed-source(materialize-from-seed): building and pushing the seed tree to %s failed: %s\n' "$dest" "$out" >&2
  fi

  rm -rf "$work"
  return "$rc"
}

# <dest> [seed-dir] -> creates one issue on <dest> (an OWNER/NAME repo slug)
# per `issues/*.md` in the seed, in filename order. NO provenance line is
# stamped: there is no upstream issue to cite, which is exactly what
# `describe()`'s `provenance_capable: false` tells callers. Prints the count
# created on success.
_testbed_provider_materialize_from_seed_produce_issues() {
  local dest="${1:?testbed-source(materialize-from-seed): produce_issues requires a destination owner/repo}"
  local seed_dir f title body create_out count=0
  seed_dir="$(_testbed_seed_dir "${2:-}")"

  command -v gh >/dev/null 2>&1 \
    || { echo "testbed-source(materialize-from-seed): gh CLI not found on PATH" >&2; return 1; }

  if [ ! -d "$seed_dir/issues" ]; then
    printf 'testbed-source(materialize-from-seed): seed issue definitions not found at %s/issues\n' "$seed_dir" >&2
    return 1
  fi

  for f in "$seed_dir"/issues/*.md; do
    [ -f "$f" ] || continue
    title="$(head -n 1 "$f" | sed -E 's/^#[[:space:]]*//')"
    if [ -z "$title" ]; then
      printf 'testbed-source(materialize-from-seed): %s has no "# <title>" first line\n' "$f" >&2
      return 1
    fi
    # Body = everything after the title line, with the blank separator line
    # trimmed so the issue does not open on an empty line.
    body="$(tail -n +2 "$f" | sed -E '1{/^[[:space:]]*$/d;}')"
    if ! create_out="$(gh issue create --repo "$dest" --title "$title" --body "$body" 2>&1)"; then
      printf 'testbed-source(materialize-from-seed): gh issue create on %s failed for %s: %s\n' \
        "$dest" "$(basename "$f")" "$create_out" >&2
      return 1
    fi
    count=$((count + 1))
  done

  printf 'testbed-source(materialize-from-seed): created %s issue(s) on %s from the in-tree seed\n' "$count" "$dest"
}
