#!/usr/bin/env bash
# make doctor — verify managed install links and report drift.
#
# Sources workflows/scripts/install/links.sh for the canonical link enumeration,
# then classifies each managed path and prints a status table.
#
# Status codes (printed per-entry and in the summary):
#
#   OK        symlink present and resolves to the expected source
#             OR managed real file / shim is present
#   MISSING   target path does not exist (and is not a broken symlink)
#   DRIFT     symlink present but points at a DIFFERENT file
#   SHADOWED  a real file/directory exists where a symlink is expected
#   DANGLING  symlink present but its target path does not exist on disk
#
# Those five classify the managed link TABLE only — they compare a symlink's
# target PATH IDENTITY (exact target string, else same device+inode —
# temperloop#1909, so a symlinked $HOME is not mistaken for drift), never
# file CONTENT. Content drift is a separate section:
# check_installed_workflow_drift() (temperloop#1397) compares the installed
# ~/.claude/workflows/*.mjs against this checkout's claude/workflows/*.mjs by
# sha256 and reports OK / DRIFT / ABSENT / UNKNOWN / SKIPPED — see that
# function's own header.
#
# Exit codes:
#   0   all entries are OK
#   1   one or more entries are non-OK
#   2   usage error (an unrecognised --only value)
#
# Usage: bash workflows/scripts/install/doctor.sh [--only=<check>] [<foundation-root>]
#        (foundation-root defaults to the repo root detected from this script's path)
#
#   --only=installed-workflow-drift
#        Run ONLY check_installed_workflow_drift() and exit with its status,
#        skipping the managed-link table and every other check. This is the
#        REUSE SEAM (temperloop#2027): the pre-flight gate
#        workflows/scripts/build/workflow-path.sh needs that one detector's
#        verdict before a driver invokes an orchestrator copy, and a second
#        hand-rolled sha256 comparison living in the build machinery would be
#        the duplicate-mechanism smell this flag exists to avoid. One
#        detector, two entrypoints — the full report, and this focused one.
#        Any other --only value is a usage error (exit 2), never a silent
#        fall-through to the full run.
#
# shellcheck shell=bash
set -uo pipefail

# ---------------------------------------------------------------------------
# Resolve FOUNDATION (repo root) from this script's location or an argument,
# plus the optional --only=<check> focus selector.
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DOCTOR_ONLY=""
_doctor_positional=()
for _arg in "$@"; do
  case "$_arg" in
    --only=*) DOCTOR_ONLY="${_arg#--only=}" ;;
    *)        _doctor_positional+=("$_arg") ;;
  esac
done

case "$DOCTOR_ONLY" in
  ""|installed-workflow-drift) ;;
  *)
    echo "doctor.sh: unknown --only value: ${DOCTOR_ONLY}" >&2
    echo "doctor.sh: supported: --only=installed-workflow-drift" >&2
    exit 2
    ;;
esac

FOUNDATION="${_doctor_positional[0]:-$(cd "${SCRIPT_DIR}/../../.." && pwd)}"
export FOUNDATION

# Source the shared enumeration helper.
# shellcheck source=links.sh
source "${SCRIPT_DIR}/links.sh"

# Source the shared gitignore-safety helper (temperloop#569/#570 dedup —
# check_reviewer_coverage() below calls gitignore_ensure_entry() directly
# instead of a private, doctor-local reimplementation).
GITIGNORE_SAFETY_SH="${SCRIPT_DIR}/gitignore-safety.sh"
if [ ! -f "$GITIGNORE_SAFETY_SH" ]; then
  echo "doctor.sh: missing sibling script: $GITIGNORE_SAFETY_SH" >&2
  exit 1
fi
# shellcheck source=gitignore-safety.sh
source "$GITIGNORE_SAFETY_SH"

# ---------------------------------------------------------------------------
# same_physical_file <path_a> <path_b>
#
# True when both paths exist AND name the SAME physical file — same device +
# inode, with every symlinked component followed. Bash's `test -ef` is the
# whole implementation: it is POSIX-portable, present in bash 3.2 (stock
# macOS), and needs no `realpath`/`readlink -f` — neither of which exists in
# a usable form on a stock BSD/macOS host (GNU `readlink -f` is absent there,
# so a path-string resolution would have to be hand-rolled per-platform).
#
# WHY THIS EXISTS (temperloop#1909). classify_entry() used to decide a
# symlink's status by comparing the link's TARGET STRING against the expected
# source string. Two correct-but-differently-spelled paths for the same file
# then read as DRIFT: a first-run persona install under `mktemp -d` on macOS
# reported ALL 24 managed symlinks as DRIFT because the links were created
# through the resolved `/private/var/folders/...` spelling while doctor's own
# $FOUNDATION/$HOME carried the unresolved `/var/folders/...` one. Any $HOME
# that resolves through a symlink (macOS `/var` -> `/private/var`, `/tmp` ->
# `/private/tmp`, a bind-mounted or external-volume home) hits it, and the
# operator sees a wall of DRIFT for a perfectly correct install.
#
# Identity, not spelling, is the question the DRIFT verdict is actually
# asking, so identity is what it now compares. This never WEAKENS the check:
# a link pointing at a genuinely different file has a different inode and is
# still DRIFT, and a dangling link cannot satisfy `-ef` at all (both operands
# must exist), so it never launders a broken install into an OK.
# ---------------------------------------------------------------------------
same_physical_file() {
  local a="$1" b="$2"
  [ -n "$a" ] && [ -n "$b" ] || return 1
  [ -e "$a" ] && [ -e "$b" ] || return 1
  [ "$a" -ef "$b" ]
}

# ---------------------------------------------------------------------------
# classify_entry <target> <expected_source> <kind>
#
# Prints the status string for a single managed path.
#
# For kind=symlink the OK test is TWO-STEP (temperloop#1909): the cheap exact
# target-string match first, then same_physical_file() above as the fallback
# that keeps a differently-spelled path to the same file out of DRIFT. See
# that helper's header for why string equality alone was wrong.
# ---------------------------------------------------------------------------
classify_entry() {
  local target="$1"
  local expected_src="$2"
  local kind="$3"

  if [[ "$kind" == "real" || "$kind" == "claude-md" ]]; then
    # settings.json (real) / composed CLAUDE.md (claude-md) — both are
    # expected to be a real (non-symlink) regular file; same classification.
    if [ -f "$target" ] && ! [ -L "$target" ]; then
      echo "OK"
    elif [ -e "$target" ] || [ -L "$target" ]; then
      echo "DRIFT"   # exists but not a plain file (e.g. is a symlink or directory)
    else
      echo "MISSING"
    fi
    return
  fi

  if [[ "$kind" == "gh-shim" ]]; then
    # gh logger shim — managed real copy, recognised by 'call-logger' marker.
    if [ -f "$target" ] && ! [ -L "$target" ] && grep -q 'call-logger' "$target" 2>/dev/null; then
      echo "OK"
    elif [ -f "$target" ] && ! [ -L "$target" ]; then
      echo "DRIFT"   # real file but not our shim
    elif [ -L "$target" ]; then
      echo "DRIFT"   # should be a real file, not a symlink
    elif [ -e "$target" ]; then
      echo "DRIFT"   # something else (directory?)
    else
      echo "MISSING"
    fi
    return
  fi

  # kind == "symlink"
  if [ -L "$target" ]; then
    local actual_src
    actual_src="$(readlink "$target")"
    if [[ "$actual_src" == "$expected_src" ]]; then
      if [ -e "$target" ]; then
        echo "OK"
      else
        echo "DANGLING"
      fi
    elif same_physical_file "$target" "$expected_src"; then
      # Different spelling, same physical file — e.g. a $HOME or a checkout
      # root that resolves through a symlink (temperloop#1909). Not drift.
      echo "OK"
    else
      echo "DRIFT"
    fi
  elif [ -e "$target" ]; then
    echo "SHADOWED"
  else
    echo "MISSING"
  fi
}

# ---------------------------------------------------------------------------
# check_knowledge_root — foundation Epic B "layered CLAUDE.md" / the Epic A
# (#762) knowledge_store split-brain guard: EVERY consumer of ks_root() must
# resolve the SAME KNOWLEDGE_STORE_ROOT regardless of which files it happens
# to source first. A mismatch means the two planes silently split the
# corpus: e.g. a script-plane consumer that sources build.config.sh writes
# into one directory while a bare-env consumer (a hook, a launchd agent —
# session-start-drain.sh is the motivating case) that sources only
# knowledge_store.sh reads/writes another.
#
# REWRITTEN (foundation#1332): the prior version of this check compared
# ks_root() against a root derived from KNOWLEDGE_STORE_OBSIDIAN_API_KEY_FILE
# (workflows/scripts/lib/knowledge_store_obsidian.sh) — but that setting's
# ONLY default is itself "$(ks_root)/.obsidian/plugins/.../data.json", and
# nothing in this tree ever sets it independently. So the old check compared
# a value to itself: its MISMATCH branch was dead code that could never
# fire. Worse, its resolution subshell sourced build.config.sh FIRST, which
# directly sources the operator's rung-3 machine conf (BUILD_CONFIG_MACHINE)
# into scope before ks_root() ever ran its own `:=` — so the old check could
# only ever observe the ALREADY-correct plane, never the bare-env plane it
# was nominally guarding. This is exactly how a 218-drain, 16-consecutive-day
# split-brain outage (temperloop#1328/foundation#1328, fixed for real
# consumers by temperloop#771's _ks_machine_conf_root()) ran with this check
# reporting green the whole time.
#
# The rewrite compares TWO independently-resolved planes instead:
#
#   Plane A (script-plane) — sources build.config.sh, then knowledge_store.sh,
#     then calls ks_root(). build.config.sh directly sources the rung-3
#     machine conf into this subshell's scope, so this is the root any
#     consumer that goes through the full build/sweep stack sees — the same
#     value install-claude-md.sh renders as the vault "Store root:" line.
#
#   Plane B (bare-env) — sources ONLY knowledge_store.sh, then calls
#     ks_root(). This is exactly what a bare hook or launchd agent sees: no
#     build.config.sh in the chain, so ks_root()'s own `_ks_machine_conf_root
#     || _ks_default_root` fallback (temperloop#771) is what resolves it.
#
# A mismatch here is real and actionable: it means the rung-3 machine conf
# (or its KNOWLEDGE_STORE_MACHINE_CONF pointer) is broken or inconsistent
# with whatever build.config.sh itself sees, so the bare-env plane silently
# resolves a different root than the script-plane one.
#
# AGREEMENT ARM (foundation#1340): equality catches a SPLIT root but is blind
# to a UNIFORMLY WRONG one — with the machine conf absent both planes fall
# through to _ks_default_root(), agree, and the check used to print a bare OK
# over a root that is not the store. Since nothing in this tree installs or
# verifies that conf, it is an untracked SPOF, and the plain-files backend's
# `mkdir -p` on append means a wrong root is silently CREATED rather than
# erroring. So when the planes agree, the check now also reports the root's
# PROVENANCE (env / machine-conf / default-fallback) and downgrades OK to WARN
# for default-fallback — the one case where agreement proves nothing. Provenance
# rather than a store-shaped probe: the only store-identity signal available
# (`.obsidian/`) is an overlay artifact a kernel-only install does not have,
# whereas "did anything configure this?" needs no such signal. The WARN is
# advisory (return 0) — a fresh install with no store configured yet lands here
# legitimately, and the defect being closed was a false OK, not a missing FAIL.
#
# Runs fully offline: sourcing build.config.sh / knowledge_store.sh does no
# network I/O (only functions never called here would).
# ---------------------------------------------------------------------------
check_knowledge_root() {
  local build_config="${FOUNDATION}/workflows/scripts/build/build.config.sh"
  local ks_lib="${FOUNDATION}/workflows/scripts/lib/knowledge_store.sh"

  printf '\nKnowledge-store root check:\n'

  if [[ ! -f "$build_config" || ! -f "$ks_lib" ]]; then
    printf '  SKIPPED (config files not found under %s)\n' "$FOUNDATION"
    return 0
  fi

  local plane_a plane_b
  plane_a="$(
    set -e
    # shellcheck source=/dev/null
    source "$build_config"
    # shellcheck source=/dev/null
    source "$ks_lib"
    ks_root
  )" || { printf '  FAIL — could not resolve build.config.sh / knowledge_store.sh (plane A, script-plane)\n'; return 1; }

  plane_b="$(
    set -e
    # shellcheck source=/dev/null
    source "$ks_lib"
    ks_root
  )" || { printf '  FAIL — could not resolve knowledge_store.sh (plane B, bare-env)\n'; return 1; }

  printf '  Plane A (script-plane, via build.config.sh)  = %s\n' "$plane_a"
  printf '  Plane B (bare-env, knowledge_store.sh alone) = %s\n' "$plane_b"

  if [[ "$plane_a" == "$plane_b" ]]; then
    # AGREEMENT IS NOT SUFFICIENT (foundation#1340). The comparison above is an
    # equality check, so it detects a SPLIT root — not a UNIFORMLY WRONG one.
    # With the rung-3 machine conf absent, BOTH planes fall through to
    # _ks_default_root() and agree on a root that is not the store at all; the
    # old code printed a bare OK for exactly that state. That is the same
    # silent-success shape as the 16-day split-brain outage described above,
    # and it is reachable today: nothing in this tree installs, deploys, or
    # verifies the machine conf, so it is an untracked single point of failure.
    #
    # The discriminator is PROVENANCE, not content. Asking "does this look like
    # a store" needs a store-shaped signal, and the only one on hand
    # (`.obsidian/`, which mind_snapshot.sh keys on) is an overlay artifact a
    # kernel-only install does not have. Asking "did anything actually CONFIGURE
    # this root" needs no such signal and is exactly the question whose answer
    # makes agreement meaningful: if the root came from the default fallback,
    # both planes agreeing tells us only that both fell back the same way.
    local provenance root_state
    # `set +eu`, not `set +e`: the ambient shell carries no `-e` (line 24), so
    # relaxing it is inert — `-u` is the inherited option that could actually
    # kill this subshell mid-source. This is the same idiom
    # _ks_machine_conf_root uses for the same "read a sibling config without
    # importing its failures" job.
    #
    # The `-n` test mirrors `ks_root`'s own `:=` semantics, which treat an
    # exported-but-EMPTY KNOWLEDGE_STORE_ROOT as unset — so an empty value
    # labels machine-conf/default-fallback, exactly as ks_root would resolve it.
    #
    # `conf-present-but-unusable` is split out because _ks_machine_conf_root
    # returns 1 for more than one situation: no conf file at all, and a conf
    # that exists but never sets KNOWLEDGE_STORE_ROOT. Both fall back, but only
    # the first is the fresh-install case the remedy text below describes —
    # telling someone who HAS a conf that they have none sends them looking in
    # the wrong place. (Its third return-1 case, a RELATIVE root, never reaches
    # this arm: build.config.sh sources the conf directly, so plane A adopts
    # the relative value while plane B's absolute-path guard rejects it, and
    # the planes MISMATCH above instead — louder and more accurate.)
    provenance="$(
      set +eu
      # shellcheck source=/dev/null
      source "$ks_lib" >/dev/null 2>&1
      if [[ -n "${KNOWLEDGE_STORE_ROOT:-}" ]]; then printf 'env'
      elif _ks_machine_conf_root >/dev/null 2>&1; then printf 'machine-conf'
      elif [[ -f "${KNOWLEDGE_STORE_MACHINE_CONF:-}" ]]; then printf 'conf-present-but-unusable'
      else printf 'default-fallback'; fi
    )"

    if [[ "$provenance" == "env" || "$provenance" == "machine-conf" ]]; then
      printf '  OK — script-plane and bare-env knowledge-store root agree (resolved from %s).\n' "$provenance"
      return 0
    fi

    # `-print -quit` stops at the FIRST hit: this is a cheap "is there anything
    # here at all" probe, not a count, so it must not walk a large store. It is
    # also deliberately NOT `find … | head -1`: `head` closing the pipe early
    # makes find die of SIGPIPE, so that pipeline reports 141 under `pipefail`
    # on the common (a file WAS found) path. Harmless while this script runs
    # `set -uo pipefail` without `-e`, but it would abort the whole check the
    # day someone adds `-e`. `-quit` is POSIX-2024 and present on both BSD
    # (macOS) and GNU find, verified on this box.
    if [[ ! -d "$plane_b" ]]; then
      root_state='the directory does not exist yet'
    elif [[ -n "$(find "$plane_b" -type f -name '*.md' -print -quit 2>/dev/null)" ]]; then
      root_state='the directory holds documents'
    else
      root_state='the directory exists but holds no documents'
    fi

    printf '  WARN — both planes agree, but NOTHING CONFIGURED this root: it came\n'
    printf '  from the built-in default fallback, so agreement here proves only that\n'
    printf '  both planes fell back identically — not that the root is your store.\n'
    printf '  Resolved root: %s (%s)\n' "$plane_b" "$root_state"
    printf '  If that is not where your knowledge store lives, every consumer is\n'
    printf '  reading and writing a shadow store — and the plain-files backend\n'
    printf '  creates it on first append, so this fails silently and looks green.\n'
    if [[ "$provenance" == "conf-present-but-unusable" ]]; then
      printf '  Fix: the rung-3 machine conf EXISTS but does not set a usable\n'
      printf '  KNOWLEDGE_STORE_ROOT, so the root fell back silently. Add an\n'
      printf '  absolute KNOWLEDGE_STORE_ROOT to it (a relative value is rejected).\n'
    else
      printf '  Fix: set KNOWLEDGE_STORE_ROOT in the rung-3 machine conf (see\n'
      printf '  docs/config-precedence.md, default path under XDG_CONFIG_HOME or\n'
      printf '  HOME/.config, temperloop/build.config.sh), or point\n'
      printf '  KNOWLEDGE_STORE_MACHINE_CONF at the conf that sets it.\n'
      printf '  (A fresh install with no store configured yet is expected to warn here.)\n'
    fi
    return 0
  fi

  printf '  MISMATCH — a consumer that sources build.config.sh (plane A) resolves\n'
  printf '  KNOWLEDGE_STORE_ROOT to a DIFFERENT directory than a bare consumer that\n'
  printf '  sources only knowledge_store.sh (plane B, e.g. a hook or launchd agent).\n'
  printf '  Fix the rung-3 machine conf (see docs/config-precedence.md, default path\n'
  printf '  under XDG_CONFIG_HOME or HOME/.config, temperloop/build.config.sh) or\n'
  printf '  repoint KNOWLEDGE_STORE_MACHINE_CONF at it so both planes agree.\n'
  return 1
}

# ---------------------------------------------------------------------------
# check_cross_checkout_split — temperloop#777: the CROSS-checkout counterpart
# to check_knowledge_root() above. #774's plane-A/plane-B comparison STAYS —
# it is correct — but it is scoped to THIS checkout ($FOUNDATION): it sources
# build.config.sh / knowledge_store.sh straight from $FOUNDATION, so it can
# never observe a split where ~/.claude itself is bound to a DIFFERENT
# checkout entirely. Live evidence 2026-07-26: after vendoring v0.18.0 into
# ~/dev/foundation, `readlink -f ~/.claude/hooks/session-start-drain.sh`
# resolved into an unrelated checkout — clean-on-main, but still pinned to
# v0.17.0 — whose ks_root() returned the WRONG root, causing 25 drain skips
# in one day. #774's check reported OK in BOTH checkouts the entire time; it
# was never wrong about what it measured, it just wasn't measuring this.
#
# Resolves a REPRESENTATIVE installed surface —
# ~/.claude/hooks/session-start-drain.sh, the exact file the incident above
# traced through (links.sh's own "claude/* -> ~/.claude/*" enumeration
# symlinks the whole claude/hooks/ DIRECTORY, so resolving this one file's
# physical parent dir is enough to reveal which checkout ~/.claude/hooks is
# actually bound to) — to its real (symlink-resolved) physical path, then
# asks git which checkout OWNS that path (`git -C <dir> rev-parse
# --show-toplevel`) and compares it against the checkout doctor itself is
# running in ($FOUNDATION). A mismatch names BOTH paths and BOTH .kernel-pin
# tags, reusing kernel_pin_tag_of() from env-reconcile.sh rather than
# reimplementing the same 8-line file read — sourced in a SUBSHELL only
# (never doctor.sh's own top level), so its globals / arg-parse loop can
# never leak into or fight with doctor.sh's own (mirrors check_knowledge_
# root's own build.config.sh/knowledge_store.sh subshell-sourcing above).
# env-reconcile.sh's own header documents this as safe: its main-enumeration
# body is guarded behind a direct-invocation check (`BASH_SOURCE[0] == $0`)
# that is never true under `source`, so sourcing it only ever defines
# functions and returns — never runs the reconciler or trips one of its
# `exit`s.
#
# Degrades to SKIPPED (never a hard failure) when:
#   - the installed surface doesn't exist yet (a fresh install / stranger's
#     clone that hasn't run `make install-claude` at all);
#   - it exists on disk but doesn't resolve into ANY git checkout (a real,
#     unmanaged/SHADOWED copy rather than a symlink into a checkout —
#     classify_entry's own SHADOWED case already flags that separately, so
#     this check staying silent here does not lose the signal).
#
# Runs fully offline: readlink/pwd -P/git rev-parse do no network I/O.
# ---------------------------------------------------------------------------
_cross_checkout_kernel_pin_tag() {
  local checkout="$1"
  local env_reconcile="${SCRIPT_DIR}/../build/env-reconcile.sh"
  local tag

  if [[ ! -f "$env_reconcile" ]]; then
    printf '(unknown — env-reconcile.sh not found)\n'
    return 0
  fi

  tag="$(
    # NOTE — no apostrophes in these comments: they sit inside a $( ... ) and
    # bash 3.2 (macOS /bin/bash) would read one as an opening quote and swallow
    # the closing paren. Guarded by scripts/lint-bash32-cmdsubst-comment.sh
    # (temperloop#1098).
    #
    # The env-reconcile.sh arg-parse loop reads "$@" — and since this
    # function was itself CALLED with an argument (checkout), that argument
    # is still $1 here, not empty. Left un-cleared, `source` inherits it as
    # the env-reconcile.sh positional params, its arg-parse loop treats
    # the checkout path as an unrecognized flag, and it `exit 2`s before
    # kernel_pin_tag_of is ever defined (silently — the caller only sees an
    # empty, rc!=0 command substitution). Scoped to THIS subshell only, so
    # the enclosing function keeps its own "$@"/"$1" untouched.
    set --
    # shellcheck source=/dev/null
    source "$env_reconcile" 2>/dev/null
    kernel_pin_tag_of "$checkout" 2>/dev/null
  )" || tag=""

  if [[ -n "$tag" ]]; then
    printf '%s\n' "$tag"
  else
    printf '(no .kernel-pin)\n'
  fi
}

check_cross_checkout_split() {
  local home claude_dir surface base
  home="${HOME:-$(eval echo ~)}"
  claude_dir="${home}/.claude"
  surface="${claude_dir}/hooks/session-start-drain.sh"
  base="$(basename "$surface")"

  printf '\nCross-checkout install-source check (temperloop#777):\n'

  if [[ ! -e "$surface" && ! -L "$surface" ]]; then
    printf '  SKIPPED (no installed surface at %s — fresh install, or make install-claude not yet run)\n' "$surface"
    return 0
  fi

  local real_dir real_path
  real_dir="$(cd "$(dirname "$surface")" 2>/dev/null && pwd -P)" || real_dir=""
  if [[ -z "$real_dir" || ! -f "${real_dir}/${base}" ]]; then
    printf '  SKIPPED (%s does not resolve to a real file on disk — broken/dangling install)\n' "$surface"
    return 0
  fi
  real_path="${real_dir}/${base}"

  local installed_root this_root
  installed_root="$(git -C "$real_dir" rev-parse --show-toplevel 2>/dev/null)" || {
    printf '  SKIPPED (%s does not resolve into any git checkout — not a symlink into a kernel repo)\n' "$real_path"
    return 0
  }
  installed_root="$(cd "$installed_root" 2>/dev/null && pwd -P)" || return 0
  this_root="$(cd "$FOUNDATION" 2>/dev/null && pwd -P)" || return 0

  if [[ "$installed_root" == "$this_root" ]]; then
    printf '  OK — installed surface (%s) resolves into THIS checkout (%s).\n' "$real_path" "$this_root"
    return 0
  fi

  local this_tag installed_tag
  this_tag="$(_cross_checkout_kernel_pin_tag "$this_root")"
  installed_tag="$(_cross_checkout_kernel_pin_tag "$installed_root")"

  printf '  MISMATCH — %s\n' "$surface"
  printf '  resolves (real path) to %s\n' "$real_path"
  printf '  which is owned by a DIFFERENT checkout than the one doctor is running from:\n'
  printf '    doctor checkout : %s  [.kernel-pin tag: %s]\n' "$this_root" "$this_tag"
  printf '    installed from  : %s  [.kernel-pin tag: %s]\n' "$installed_root" "$installed_tag"
  printf '  ~/.claude is bound to a DIFFERENT checkout than this one — edits here under\n'
  printf '  claude/hooks/... are NOT what the installed hooks actually run. Re-run\n'
  printf '  "make install-claude" from %s to repoint ~/.claude at THIS checkout,\n' "$this_root"
  printf '  or confirm %s is the intended install source.\n' "$installed_root"
  return 1
}

# ---------------------------------------------------------------------------
# check_cache_state — report the canonical-layer issue-cache store's state
# per board (F#988/#1026): whether a board has opted in (`board.<N>.cache=on`
# in boards.conf) and whether its on-disk store is present/stale/absent.
#
# READ-ONLY and never fails the overall `make doctor` gate — an absent store
# or absent boards.conf is a normal, expected state (cache is opt-in), not a
# drift condition the way a broken managed symlink is. This mirrors
# check_knowledge_root's SKIPPED-is-fine posture for a tree that simply
# doesn't have the pieces wired up yet.
#
# Board discovery is boards.conf-only (the same file board.sh's own
# `_board_conf_file()` would resolve — machine-level, then repo-local),
# never the built-in org-specific case map in board.sh: a stranger's fresh
# clone has no boards.conf and this prints one informational line and
# returns, exactly like links_provision_cache_stores's own discovery.
# ---------------------------------------------------------------------------
check_cache_state() {
  local board_lib="${FOUNDATION}/workflows/scripts/board/lib/board.sh"
  local cache_lib="${FOUNDATION}/workflows/scripts/board/lib/cache.sh"

  printf '\nCache-store state (F#988/#1026):\n'

  if [[ ! -f "$board_lib" || ! -f "$cache_lib" ]]; then
    printf '  SKIPPED (board.sh / cache.sh not found under %s)\n' "$FOUNDATION"
    return 0
  fi

  # temperloop#165: the machine conf's subdir renamed foundation/ ->
  # temperloop/ in v0.15.0, and the legacy read was removed in v0.19.0 — the
  # legacy path is no longer a fallback. But this is `doctor`, whose whole
  # job is to explain why a tree isn't wired up the way its operator thinks,
  # so a legacy file that still exists is REPORTED rather than passed over in
  # silence (same disposition as board.sh's own promoted NOTE — and note this
  # fires whether or not a repo-local conf then supplies the boards, since
  # the operator's question is "why is my machine conf being ignored").
  local machine_conf="${XDG_CONFIG_HOME:-$HOME/.config}/temperloop/boards.conf"
  local machine_conf_legacy="${XDG_CONFIG_HOME:-$HOME/.config}/foundation/boards.conf"
  local repo_conf="${FOUNDATION}/workflows/scripts/board/boards.conf"
  local conf=""
  if [[ ! -f "$machine_conf" && -f "$machine_conf_legacy" ]]; then
    printf '  NOTE: a machine boards.conf exists only at the legacy path %s — the default moved to %s in v0.15.0 and the legacy read was removed in v0.19.0, so that file is IGNORED; move it.\n' "$machine_conf_legacy" "$machine_conf"
  fi
  if [[ -f "$machine_conf" ]]; then
    conf="$machine_conf"
  elif [[ -f "$repo_conf" ]]; then
    conf="$repo_conf"
  fi

  if [[ -z "$conf" ]]; then
    printf '  (no boards.conf found — nothing configured; cache is OFF everywhere by default)\n'
    return 0
  fi

  local boards
  boards="$(grep -oE '^board\.[0-9]+\.repo=' "$conf" 2>/dev/null | cut -d. -f2 | sort -un)"
  if [[ -z "$boards" ]]; then
    printf '  (%s declares no board with a repo= axis — nothing to report)\n' "$conf"
    return 0
  fi

  local n enabled state
  while IFS= read -r n; do
    [[ -n "$n" ]] || continue

    if grep -q "^board\.${n}\.cache=on$" "$conf" 2>/dev/null; then
      enabled="on"
    else
      enabled="off"
    fi

    state="$(
      # shellcheck source=/dev/null
      source "$board_lib" 2>/dev/null
      # shellcheck source=/dev/null
      source "$cache_lib" 2>/dev/null
      repo="$(board_repo "$n" 2>/dev/null)" || { printf 'n/a (no repo axis)'; exit 0; }
      meta="$(cache_meta_file "$repo" 2>/dev/null)"
      if [[ -z "$meta" || ! -f "$meta" ]]; then
        printf 'absent'
      elif cache_stale "$repo" 2>/dev/null; then
        printf 'stale'
      else
        printf 'present'
      fi
    )"

    printf '  board.%-3s  cache=%-3s  store=%s\n' "$n" "$enabled" "$state"
  done <<<"$boards"
}

# ---------------------------------------------------------------------------
# check_bm_tool_install — install AND REPORT the knowledge_search backend's
# pinned basic-memory uv tool (temperloop#1113).
#
# This is the DOCTOR half of the ratified hybrid install design. The other
# half lives in workflows/scripts/lib/knowledge_search.sh's availability gate,
# which lazily installs the pin on first use so a stranger who never runs
# doctor still gets a working first `ks_search`. Neither half replaces the
# other: the lazy half keeps the zero-setup first-run virtue that made `uvx`
# the original default, and this half gives an INSTALLED checkout a
# predictable, pre-warmed state — so the first real search is fast, and an
# operator can see the pin's install state without running a search at all.
#
# Why the switch happened (the state this reports on): resolving
# `uvx --from basic-memory==<pin>` per run left uv unpacking a fresh
# environment into its own cache with no permanent install location and no
# expiry — measured at 30 GB against a 273 MB store, unprunable for as long as
# a warm daemon held the cache lock. An installed uv tool puts a stable
# virtualenv on disk instead, and the cache goes back to being a cache.
#
# ADVISORY, never a gate. `make doctor` must stay runnable on a host with no
# `uv`, no network, or no interest in the search seam at all — an uninstalled
# or uninstallable pin is a reported state, not a broken managed link. It
# therefore always returns 0, exactly like check_cache_state.
#
# Runs entirely inside a SUBSHELL so sourcing the two libraries cannot leak
# their `:=` defaults (KNOWLEDGE_STORE_ROOT and friends) into doctor's own
# scope or into any later check — the same isolation posture
# check_knowledge_root and check_cache_state already use.
# ---------------------------------------------------------------------------
check_bm_tool_install() {
  local store_lib="${FOUNDATION}/workflows/scripts/lib/knowledge_store.sh"
  local search_lib="${FOUNDATION}/workflows/scripts/lib/knowledge_search.sh"
  # The install bound (KNOWLEDGE_SEARCH_BM_INSTALL_TIMEOUT) is applied by
  # _ks_bm_install_tool ONLY when run_with_timeout is already in scope — it is
  # the caller's job to provide it. Doctor is the caller that most predictably
  # drives the install (it runs it unconditionally on an absent/drifted pin),
  # and this check is documented as advisory, never a gate: `make doctor` must
  # stay runnable on a host with no uv and no network. Without this source the
  # setting is inert here and a wedged network turns `make doctor` into an
  # unbounded hang — worse than the failure the advisory posture was built for.
  local timeout_lib="${FOUNDATION}/workflows/scripts/lib/portable-timeout.sh"

  printf '\nknowledge_search basic-memory tool (temperloop#1113):\n'

  if [[ ! -f "$store_lib" || ! -f "$search_lib" ]]; then
    printf '  SKIPPED (knowledge_store.sh / knowledge_search.sh not found under %s)\n' "$FOUNDATION"
    return 0
  fi

  (
    # shellcheck source=/dev/null
    source "$store_lib" 2>/dev/null || {
      printf '  SKIPPED (could not source knowledge_store.sh)\n'; exit 0; }
    # shellcheck source=/dev/null
    source "$search_lib" 2>/dev/null || {
      printf '  SKIPPED (could not source knowledge_search.sh)\n'; exit 0; }
    # Best-effort: an older/vendored tree without this lib simply runs the
    # install unbounded, exactly as it did before this source existed.
    if [ -f "$timeout_lib" ]; then
      # shellcheck source=/dev/null
      source "$timeout_lib" 2>/dev/null || true
    fi

    # A kernel checkout older than #1113 has no install seam to drive. Report
    # that plainly rather than failing — this file is also read by vendored
    # trees that pull the kernel forward at their own pace.
    if ! declare -F _ks_bm_ensure_tool >/dev/null 2>&1; then
      printf '  SKIPPED (this knowledge_search.sh predates the uv-tool install seam)\n'
      exit 0
    fi

    printf '  pin         %s\n' "$(_ks_bm_pin_id)"
    printf '  entry point %s\n' "$(_ks_bm_bin_path)"

    if _ks_bm_tool_ready; then
      printf '  state       INSTALLED (matches the configured pin)\n'
      exit 0
    fi

    if ! command -v uv >/dev/null 2>&1; then
      printf '  state       UNAVAILABLE (uv is not on PATH — install uv, then re-run doctor)\n'
      exit 0
    fi

    if [ -x "$(_ks_bm_bin_path)" ]; then
      printf '  state       PIN DRIFT (installed at a different pin) — re-installing\n'
    else
      printf '  state       ABSENT — installing\n'
    fi

    if _ks_bm_ensure_tool; then
      printf '  state       INSTALLED (matches the configured pin)\n'
    else
      printf '  state       INSTALL FAILED (uv output above) — ks_search will degrade with a "skipped --" notice\n'
    fi
  )
  return 0
}

# ---------------------------------------------------------------------------
# check_reviewer_coverage — advisory, WARN-level reviewer-activation-coverage
# check (temperloop#550, ADR 0007/0008). REUSES #548's pure, non-interactive
# data path (reviewer_coverage_gaps / reviewer_coverage_check_integrity,
# sourced from reviewer-activation-coverage.sh) — NEVER #549's interactive
# reviewer-activate.sh (that script has no source-guard and would run its
# whole offer/prompt body unconditionally if sourced here).
#
# Strictly advisory: a WARN increments a local tally ONLY, never `non_ok`/
# the exit code — an inert, un-activated reviewer is the DESIGNED default
# (opt-in, ADR 0007), so a fresh checkout with zero activated reviewers must
# still exit 0. Mirrors check_cache_state()'s read-only `|| true` posture.
#
# Three outcomes per catalogued-reviewer language, computed from #548's own
# gap-set semantics:
#   - resolvable gap (catalogued in reviewer-routing.tsv, material usage at/
#     above REVIEWER_SCAN_MIN_FILES, not yet activated, not durably declined)
#     -> WARN, every run, until activated or declined. reviewer_coverage_
#     gaps() already computes exactly this set.
#   - durably declined (a decline marker under the per-repo reviewer-state
#     dir, #549's format) -> silent. reviewer_coverage_gaps() already
#     excludes these from its output, so nothing extra is needed here.
#   - uncatalogued (a reviewer-routing.tsv row whose catalog-agent-path does
#     NOT resolve to a real file on disk — reviewer_coverage_check_
#     integrity() reports it DANGLING, i.e. that "catalogued" language has no
#     actual backing rubric to activate) -> a ONE-TIME INFO, never a
#     repeating WARN. This check is catalog-wide (not dependent on this
#     checkout's own file mix), so it fires identically anywhere the tsv/
#     catalog pairing is broken. "One-time" state is a small marker file
#     under the SAME gitignored per-repo reviewer-state dir #549 owns
#     (.claude/reviewer-state/doctor-uncatalogued-notified) — this is
#     doctor.sh's FIRST write-capable check, a deliberate scoped exception to
#     its otherwise read-only posture, confined to that one gitignored path
#     and NEVER touching anything a `git add -A` would stage. If the state
#     dir/gitignore can't be confirmed safe, this degrades to read-only
#     (skips the write, so the INFO simply reprints next run) rather than
#     leaking state anywhere — and never fails the check either way.
# ---------------------------------------------------------------------------
check_reviewer_coverage() {
  local rac_sh="${FOUNDATION}/workflows/scripts/install/reviewer-activation-coverage.sh"

  printf '\nReviewer coverage check (temperloop#550):\n'

  if [[ ! -f "$rac_sh" ]]; then
    printf '  SKIPPED (reviewer-activation-coverage.sh not found under %s)\n' "$FOUNDATION"
    return 0
  fi

  # shellcheck source=/dev/null
  if ! source "$rac_sh" 2>/dev/null; then
    printf '  SKIPPED (could not source reviewer-activation-coverage.sh)\n'
    return 0
  fi

  if [[ ! -f "${REVIEWER_ROUTING_TSV:-}" ]]; then
    printf '  SKIPPED (reviewer-routing.tsv not found at %s)\n' "${REVIEWER_ROUTING_TSV:-<unset>}"
    return 0
  fi

  local project_dir="$FOUNDATION"
  local gaps=""
  gaps="$(reviewer_coverage_gaps "$project_dir" "$REVIEWER_ROUTING_TSV" 2>/dev/null)" || gaps=""

  local warn_count=0 name
  if [[ -n "$gaps" ]]; then
    while IFS= read -r name; do
      [[ -n "$name" ]] || continue
      printf '  WARN  %-22s catalogued, not yet activated (repo has material usage at/above threshold) — run reviewer-activate.sh to opt in or decline\n' "$name"
      warn_count=$((warn_count + 1))
    done <<<"$gaps"
  fi

  local integrity_err=""
  integrity_err="$(reviewer_coverage_check_integrity "$REVIEWER_ROUTING_TSV" "$FOUNDATION" 2>&1 1>/dev/null)" || true

  if [[ -n "$integrity_err" ]]; then
    local state_dir="${project_dir}/.claude/reviewer-state"
    local notice_marker="${state_dir}/doctor-uncatalogued-notified"

    if [[ ! -e "$notice_marker" ]]; then
      printf '  INFO  one or more reviewer-routing.tsv entries reference a language with no backing rubric on disk (uncatalogued) — see docs/features/review-agents.md for the bring-your-own path:\n'
      printf '%s\n' "$integrity_err" | sed 's/^/        /'

      if gitignore_ensure_entry "$project_dir" ".claude/reviewer-state/" "${project_dir}/.claude/reviewer-state/.doctor-probe"; then
        # if-then-else, not `A && B || C` (SC2015): the marker write is
        # best-effort — a failed mkdir or printf must never fail the check.
        if mkdir -p "$state_dir" 2>/dev/null; then
          printf '# doctor.sh: uncatalogued-language notice already shown on %s\n' "$(date +%Y-%m-%d)" >"$notice_marker" 2>/dev/null || true
        fi
      fi
    fi
  fi

  if [[ "$warn_count" -eq 0 && -z "$integrity_err" ]]; then
    printf '  no resolvable reviewer-activation gaps\n'
  fi

  return 0
}

# ---------------------------------------------------------------------------
# check_project_agents_tree — advisory report on the PROJECT-SCOPED
# .claude/{agents,commands} tree (temperloop#1943).
#
# THE BLIND SPOT THIS CLOSES. The managed-link table above enumerates the
# MACHINE surface only (links.sh, rooted at $HOME/.claude), so the
# project-scoped tree project-agents.sh deploys had no reporter at all. That
# tree is gitignored by the installer itself, so a stale entry is invisible to
# `git status` too — and a dangling entry under .claude/agents/ is the exact
# surface Claude Code's capability probe reads, so a deleted reviewer keeps
# reading as "available" with nothing anywhere saying so. project-agents.sh
# now prunes on every deploy; this is the backstop for a link that somehow
# survives (a failed rm, a tree nobody has re-deployed since).
#
# It REUSES project-agents-prune.sh's scanner rather than re-deriving the
# recognizer — the same predicate that decides what the installer REMOVES is
# what decides what this REPORTS, so the audit can never stop covering the
# thing that deletes files. The scan is pure: doctor does no pruning of its
# own and writes nothing here.
#
# STRICTLY ADVISORY, and deliberately so. Like check_cache_state() and
# check_reviewer_coverage(), it is called with `|| true` and its findings are
# folded into NO tally — not `non_ok`, not the exit code. An un-deployed or
# partially-deployed project-scoped tree is a legitimate state (the whole
# deploy is opt-in: a stranger's clone has no .claude/agents/ at all), so it
# must never fail `make doctor` — which is also the post-checkout doctor run
# of `temperloop update`, where a hard failure would block a release landing
# over a stale gitignored symlink.
#
# Degrades to SKIPPED (never a failure) when the shared lib is absent — a
# vendored or older tree that has not pulled this far.
# ---------------------------------------------------------------------------
check_project_agents_tree() {
  local prune_lib="${FOUNDATION}/workflows/scripts/install/project-agents-prune.sh"

  printf '\nProject-scoped agent/command tree (temperloop#1943):\n'

  if [[ ! -f "$prune_lib" ]]; then
    printf '  SKIPPED (project-agents-prune.sh not found under %s)\n' "$FOUNDATION"
    return 0
  fi

  # shellcheck source=project-agents-prune.sh
  if ! source "$prune_lib" 2>/dev/null; then
    printf '  SKIPPED (could not source project-agents-prune.sh)\n'
    return 0
  fi

  local rows=""
  rows="$(project_agents_scan_dangling "$FOUNDATION" "$FOUNDATION" 2>/dev/null)" || rows=""

  if [[ -z "$rows" ]]; then
    printf '  OK        no dangling managed links under %s/.claude/{agents,commands}\n' "$FOUNDATION"
    return 0
  fi

  local rel link_target dangling=0
  while IFS=$'\t' read -r rel link_target; do
    [[ -n "$rel" ]] || continue
    printf '  DANGLING  .claude/%s -> %s (source gone)\n' "$rel" "$link_target"
    dangling=$((dangling + 1))
  done <<<"$rows"

  printf '  %d dangling managed link(s) — advisory only, does not affect this run exit code.\n' "$dangling"
  printf '  Re-run: bash workflows/scripts/install/project-agents.sh --project-dir %s\n' "$FOUNDATION"
  return 0
}

# check_toolkit_provenance — is the toolkit code in THIS checkout the release
# it claims to be? (temperloop#1047, ADR 0021/0022.)
#
# Delegates entirely to workflows/scripts/toolkit-provenance.sh — this
# function carries no baseline logic of its own, exactly as
# check_legacy_host_config delegates to legacy-host-preflight.sh. The probe is
# read-only, network-free and always exits 0, so this check cannot fail doctor
# for an environmental reason.
#
# NON-FATAL by design, mirroring check_cache_state / check_reviewer_coverage:
# a MODIFIED checkout is a state an operator may have entered deliberately
# (the sanctioned KERNEL_EDIT_ACK / `Upstream:` waiver path — see
# docs/features/toolkit-provenance.md), so it WARNs and always returns 0. It
# never touches `non_ok` or doctor's exit code.
#
# Three outcomes, one per verdict:
#   RELEASED  — one line, no WARN. A released checkout passes quietly.
#   MODIFIED  — WARN, plus the probe's own attribution block verbatim
#               (uncommitted vs. committed drift; commit, author and any
#               `Upstream:` reference) so the reader can act without re-running
#               anything.
#   UNKNOWN   — SKIPPED, carrying the probe's own reason. This is the kernel's
#               OWN development checkout's outcome: it has no release baseline
#               by construction, and giving it one would mis-classify the
#               self-distribution suite (ADR 0021).
# ---------------------------------------------------------------------------
check_toolkit_provenance() {
  local probe="${FOUNDATION}/workflows/scripts/toolkit-provenance.sh"

  printf '\nToolkit provenance check (temperloop#1047):\n'

  if [[ ! -f "$probe" ]]; then
    printf '  SKIPPED (toolkit-provenance.sh not found under %s)\n' "$FOUNDATION"
    return 0
  fi

  local report=""
  report="$(bash "$probe" --root "$FOUNDATION" --format report 2>&1)" || report=""

  if [[ -z "$report" ]]; then
    printf '  SKIPPED (the provenance probe produced no output)\n'
    return 0
  fi

  local verdict claims reason
  verdict="$(sed -n '1s/^Toolkit provenance: //p' <<<"$report")"

  case "$verdict" in
    RELEASED)
      claims="$(sed -n 's/^  claims:  *//p' <<<"$report" | head -n1)"
      printf '  toolkit tree is byte-identical to the release it claims (%s)\n' "${claims:-unnamed release}"
      ;;
    MODIFIED)
      claims="$(sed -n 's/^  claims:  *//p' <<<"$report" | head -n1)"
      printf '  WARN  MODIFIED — the running toolkit is NOT the release it claims (%s). Upstream the change or restore the released content; see docs/features/toolkit-provenance.md\n' "${claims:-unnamed release}"
      sed -n '2,$p' <<<"$report" | sed 's/^/    /'
      ;;
    *)
      reason="$(sed -n 's/^  reason:  *//p' <<<"$report" | head -n1)"
      printf '  SKIPPED (%s)\n' "${reason:-no release baseline could be established}"
      ;;
  esac

  return 0
}

# ---------------------------------------------------------------------------
# check_legacy_host_config — HOST-STATE preflight for legacy host-config
# paths a release has REMOVED (temperloop#908). Delegates entirely to the
# registry-driven workflows/scripts/install/legacy-host-preflight.sh (see
# that file's own header for the full rationale and the two instances that
# motivated it — foundation#1419's stranded funnel-cron.plist and
# temperloop#165's unmigrated legacy boards.conf).
#
# Unlike check_cache_state's advisory NOTE (which never affects doctor's
# exit code — a legacy machine conf that's merely unread might still be
# harmless if a repo-local conf covers the same boards), this check is a
# GATE: a registry entry that comes back LIVE-UNMIGRATED means a host
# consumable a release removed is both still present AND has no successor
# in place, which is never a benign state — it is the exact silent-and-
# wrong failure both motivating instances produced. Non-zero here fails
# `make doctor`, and therefore fails the `temperloop update` post-checkout
# doctor run (bin/subcommands/update.sh run_post_checkout()) — the point a
# release actually lands on an operator's host.
#
# Degrades to SKIPPED (never a hard failure) when legacy-host-preflight.sh
# itself is absent — a stranger's fresh clone at a kernel version that
# predates this check, or a vendored tree that hasn't pulled this far yet.
# ---------------------------------------------------------------------------
check_legacy_host_config() {
  local preflight_sh="${FOUNDATION}/workflows/scripts/install/legacy-host-preflight.sh"

  printf '\nLegacy host-config preflight (temperloop#908):\n'

  if [[ ! -f "$preflight_sh" ]]; then
    printf '  SKIPPED (legacy-host-preflight.sh not found under %s)\n' "$FOUNDATION"
    return 0
  fi

  # shellcheck source=legacy-host-preflight.sh
  if ! source "$preflight_sh" 2>/dev/null; then
    printf '  SKIPPED (could not source legacy-host-preflight.sh)\n'
    return 0
  fi

  if ! legacy_host_preflight_run; then
    printf '  one or more legacy host-config paths are LIVE and UNMIGRATED — see above.\n'
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# check_installed_workflow_drift — temperloop#1397: the INSTALLED per-level
# build workflow (~/.claude/workflows/*.mjs) can silently drift from this
# checkout's own claude/workflows/*.mjs, and until this check nothing on any
# surface said so.
#
# WHY THIS EXISTS. `/build` Step 3, `/sweep` Step 0.3 and `/fix` Step 3 all
# resolve the orchestrator as `workflowPath="$HOME/.claude/workflows/
# build-level.mjs"` and invoke it by `scriptPath`. That path is the INSTALLED
# copy — so what actually executes is whatever was last installed there, not
# what is committed in the checkout the session is editing. Two live
# reproductions, both found only because a session happened to diff the two
# by hand before invoking:
#   * 2026-08-10 (the filing): installed 153,468 bytes dated Aug 7 vs a repo
#     copy of 169,056 bytes — 154 commits of orchestration machinery that
#     would never have run.
#   * 2026-08-21 (during the run that fixed this): installed 204,139 bytes
#     dated Aug 15 vs a repo copy of 212,478 bytes dated Aug 21. Every
#     workflow invocation of that overnight run executed a six-day-stale
#     orchestrator — including the batches that merged temperloop#1587's
#     escalation-payload fix, whose payloads then still showed the pre-fix
#     contradiction because the installed copy never changed.
#
# Same class as temperloop#1365/#1591: stale machinery never announces
# itself — it runs old logic and reports success. The existing surfaces
# genuinely cannot see it. classify_entry() compares a symlink's target PATH
# IDENTITY, so an installed real-file copy, or a symlink that points at the
# intended directory whose CONTENT is stale, both read OK.
# check_cross_checkout_split() resolves ~/.claude/hooks and would catch
# ~/.claude/workflows being bound to a different checkout, but it is a
# path-identity check, not a content one, and never says which side is newer.
# This check compares CONTENT (sha256, byte-compare fallback) and reports
# both sizes, both mtimes and both digests so the reader can tell which side
# is newer WITHOUT running the diff the issue is about.
#
# FOUR DISTINCT OUTCOMES — absent is never drift and never clean
# (the temperloop#1591/#1523 absence-vs-indeterminacy split):
#   OK       both copies are byte-identical (digest reported).
#   DRIFT    they differ. Reports size + mtime + sha256 for BOTH, names
#            which one is NEWER and by how much, and names the physical
#            directory the installed copy really lives in. Non-zero.
#   ABSENT   nothing is installed at that path at all — a checkout that
#            never installed, or a fleet that installs elsewhere. Printed
#            as its own outcome and explicitly NOT drift, NOT in sync.
#            Contributes nothing to doctor's exit code: nothing is wrong,
#            there is simply nothing to compare.
#   UNKNOWN  something IS at the installed path but drift could not be
#            evaluated (dangling symlink, a directory, an unreadable file,
#            no digest tool AND cmp errored). Indeterminate, never clean —
#            non-zero, per the "a check that could not run must not report
#            success" rule (temperloop#1409/#1476).
# Plus SKIPPED when this checkout ships no claude/workflows/*.mjs at all
# (nothing to compare AGAINST — a tree that predates the workflow path).
#
# DETECT AND REPORT ONLY — this check NEVER writes to ~/.claude. Installing
# is global shared state and a deliberately operator-run action (the kernel's
# working-tree-ownership rule); a doctor check that auto-copied would be
# exactly the foreign mutation that rule forbids. It names the remedy and
# leaves the decision to a human.
#
# Runs fully offline; every file it touches it only reads.
# ---------------------------------------------------------------------------

# Epoch mtime of a file, dialect feature-detected ONCE. A `stat -c %Y ||
# stat -f %m` fallback chain is NOT safe: on BSD/macOS `stat -f %m FILE`
# succeeds, but on GNU coreutils `stat -f %m FILE` treats "%m" as a FILE
# operand, prints filesystem status, and can exit 0 with garbage on stdout.
# Same idiom as workflows/scripts/drain/vault_hygiene_report.sh.
if stat -c %Y . >/dev/null 2>&1; then
  _doctor_stat_mtime() { stat -c %Y "$1" 2>/dev/null; }   # GNU coreutils
else
  _doctor_stat_mtime() { stat -f %m "$1" 2>/dev/null; }   # BSD/macOS
fi

# sha256 of a file, or rc 1 when no hasher is on PATH (the caller then falls
# back to a byte compare). Same portable preference order as
# workflows/scripts/chunk-redundancy-surface.sh's _sandbox_sha256.
_doctor_file_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

# Human-readable local time for an epoch. BSD `date -r EPOCH` formats a
# timestamp; GNU `date -r` wants a FILE and fails on a number, so it falls
# through to `date -d @EPOCH`. Order matters. Rendered in the host local
# zone, never UTC (the kernel's human-facing-dates rule).
_doctor_fmt_epoch() {
  local e="${1:-}"
  [[ -z "$e" ]] && { printf '(mtime unreadable)'; return 0; }
  date -r "$e" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null \
    || date -d "@${e}" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null \
    || printf 'epoch %s' "$e"
}

# Whole seconds -> a compact "Nd Nh Nm" age, for the newer-by delta.
_doctor_fmt_age() {
  local s="${1:-0}" d h m
  d=$(( s / 86400 )); h=$(( (s % 86400) / 3600 )); m=$(( (s % 3600) / 60 ))
  if (( d > 0 )); then printf '%dd %dh' "$d" "$h"
  elif (( h > 0 )); then printf '%dh %dm' "$h" "$m"
  else printf '%dm' "$m"; fi
}

check_installed_workflow_drift() {
  local home installed_dir repo_dir
  home="${HOME:-$(eval echo ~)}"
  installed_dir="${home}/.claude/workflows"
  repo_dir="${FOUNDATION}/claude/workflows"

  printf '\nInstalled build-workflow content check (temperloop#1397):\n'

  # Compare EVERY workflow this checkout ships, not just build-level.mjs.
  # build-level.mjs is the one the incidents named, but a check scoped to a
  # single instance is the smell the kernel principle warns about — the next
  # workflow added under claude/workflows/ inherits the defect for free.
  local -a repo_files=()
  local f
  if [[ -d "$repo_dir" ]]; then
    for f in "${repo_dir}"/*.mjs; do
      [[ -f "$f" ]] && repo_files+=("$f")
    done
  fi

  if (( ${#repo_files[@]} == 0 )); then
    printf '  SKIPPED (this checkout ships no %s/*.mjs — nothing to compare against)\n' "$repo_dir"
    return 0
  fi

  local rc=0 base installed
  for f in "${repo_files[@]}"; do
    base="$(basename "$f")"
    installed="${installed_dir}/${base}"

    # --- ABSENT: nothing installed. NOT drift, and NOT in sync. ------------
    if [[ ! -e "$installed" && ! -L "$installed" ]]; then
      printf '  ABSENT   %s\n' "$installed"
      printf '           nothing is installed there — this host has never installed %s,\n' "$base"
      printf '           or the fleet installs it somewhere else. ABSENT is NOT drift and\n'
      printf '           NOT an in-sync result: there is nothing to compare %s against.\n' "$f"
      printf '           A /build, /sweep or /fix run that resolves scriptPath to that path\n'
      printf '           would fail outright rather than silently run stale machinery.\n'
      continue
    fi

    # --- UNKNOWN: present but not comparable. Indeterminate, never clean. --
    if [[ ! -f "$installed" ]]; then
      local why="not a regular file"
      [[ -L "$installed" && ! -e "$installed" ]] && why="dangling symlink"
      [[ -d "$installed" ]] && why="a directory"
      printf '  UNKNOWN  %s\n' "$installed"
      printf '           exists but drift could NOT be evaluated (%s). Indeterminate —\n' "$why"
      printf '           this is deliberately not reported as either drift or in sync.\n'
      rc=1
      continue
    fi

    local d_repo d_inst same=""
    d_repo="$(_doctor_file_sha256 "$f")" || d_repo=""
    d_inst="$(_doctor_file_sha256 "$installed")" || d_inst=""

    if [[ -n "$d_repo" && -n "$d_inst" ]]; then
      if [[ "$d_repo" == "$d_inst" ]]; then same=1; else same=0; fi
    else
      # No hasher, or a hash that failed: fall back to a byte compare, and
      # keep cmp's THIRD outcome (rc >= 2 = it could not read a side)
      # distinct from "they differ" rather than collapsing it into drift.
      cmp -s "$f" "$installed" >/dev/null 2>&1
      case $? in
        0) same=1 ;;
        1) same=0 ;;
        *) same="" ;;
      esac
    fi

    if [[ -z "$same" ]]; then
      printf '  UNKNOWN  %s\n' "$installed"
      printf '           could not be hashed OR byte-compared against %s (unreadable?).\n' "$f"
      printf '           Indeterminate — not reported as either drift or in sync.\n'
      rc=1
      continue
    fi

    local s_repo s_inst m_repo m_inst real_dir
    s_repo="$(wc -c <"$f" 2>/dev/null | tr -d ' ')" || s_repo="?"
    s_inst="$(wc -c <"$installed" 2>/dev/null | tr -d ' ')" || s_inst="?"
    m_repo="$(_doctor_stat_mtime "$f")" || m_repo=""
    m_inst="$(_doctor_stat_mtime "$installed")" || m_inst=""

    if [[ "$same" == "1" ]]; then
      printf '  OK       %s\n' "$installed"
      printf '           byte-identical to %s\n' "$f"
      printf '           [%s bytes, sha256 %s]\n' "$s_repo" "${d_repo:-(byte-compared; no sha256 tool on PATH)}"
      continue
    fi

    real_dir="$(cd "$(dirname "$installed")" 2>/dev/null && pwd -P)" || real_dir=""

    printf '  DRIFT    %s\n' "$installed"
    printf '           installed : %s bytes  %s\n' "$s_inst" "$(_doctor_fmt_epoch "$m_inst")"
    printf '                       sha256 %s\n' "${d_inst:-(unavailable — byte-compared)}"
    if [[ -n "$real_dir" && "$real_dir" != "$installed_dir" ]]; then
      printf '                       real path: %s/%s\n' "$real_dir" "$base"
    fi
    printf '           repo copy : %s bytes  %s\n' "$s_repo" "$(_doctor_fmt_epoch "$m_repo")"
    printf '                       sha256 %s\n' "${d_repo:-(unavailable — byte-compared)}"
    printf '                       %s\n' "$f"

    if [[ -n "$m_repo" && -n "$m_inst" ]]; then
      if (( m_repo > m_inst )); then
        printf '           NEWER: the REPO copy, by %s. The installed copy is STALE.\n' \
          "$(_doctor_fmt_age $(( m_repo - m_inst )))"
      elif (( m_inst > m_repo )); then
        printf '           NEWER: the INSTALLED copy, by %s. This checkout is BEHIND what\n' \
          "$(_doctor_fmt_age $(( m_inst - m_repo )))"
        printf '           is installed (a vendored tree that has not pulled, or another\n'
        printf '           checkout installed over it).\n'
      else
        printf '           NEWER: undecidable — both carry the SAME mtime yet differ in\n'
        printf '           content. Compare the sha256 values above by hand.\n'
      fi
    else
      printf '           NEWER: undecidable — an mtime could not be read on one side.\n'
    fi

    printf '           WHY IT MATTERS: /build Step 3, /sweep Step 0.3 and /fix Step 3 all\n'
    printf '           invoke it by scriptPath at ~/.claude/workflows/%s, so THAT copy is\n' "$base"
    printf '           what executes — not the one in this checkout.\n'
    printf '           REMEDY (operator-run, never automatic): re-run the install from the\n'
    printf '           checkout you intend to be canonical, or point scriptPath at the\n'
    printf '           in-repo absolute path %s for this session.\n' "$f"
    printf '           This check only REPORTS — it never writes to %s.\n' "$installed_dir"
    rc=1
  done

  return "$rc"
}

# ---------------------------------------------------------------------------
# Focused mode (--only=<check>) — run ONE check and exit with its status.
#
# The reuse seam temperloop#2027 needs: workflow-path.sh gates a driver's
# orchestrator invocation on this same detector rather than growing a second
# one, and the full run below is far too broad (and far too slow) to sit in
# front of every /build, /sweep and /fix invocation. Dispatch happens AFTER
# every check function is defined and BEFORE any of the full run's output, so
# the focused caller gets exactly one section on stdout and nothing else.
# ---------------------------------------------------------------------------
if [[ "$DOCTOR_ONLY" == "installed-workflow-drift" ]]; then
  check_installed_workflow_drift
  exit $?
fi

# ---------------------------------------------------------------------------
# Main — enumerate and classify every managed entry.
# ---------------------------------------------------------------------------
ok=0
non_ok=0
non_ok_entries=()

printf '\nmake doctor — managed link status (%s)\n\n' "$FOUNDATION"
printf '  %-10s  %s\n' "STATUS" "TARGET"
printf '  %-10s  %s\n' "----------" "------"

while IFS=$'\t' read -r target kind expected_src; do
  status="$(classify_entry "$target" "$expected_src" "$kind")"
  printf '  %-10s  %s\n' "$status" "$target"
  if [[ "$status" == "OK" ]]; then
    (( ok++ )) || true
  else
    (( non_ok++ )) || true
    non_ok_entries+=("${status}  ${target}")
  fi
done < <(links_enumerate "$FOUNDATION")

echo
printf 'OK: %d   Non-OK: %d\n' "$ok" "$non_ok"

knowledge_root_status=0
check_knowledge_root || knowledge_root_status=$?

cross_checkout_status=0
check_cross_checkout_split || cross_checkout_status=$?

check_cache_state || true

check_bm_tool_install || true

check_reviewer_coverage || true

# Advisory only (temperloop#1943) — `|| true`, and deliberately absent from
# the exit-code composition below, exactly like check_cache_state() and
# check_reviewer_coverage() above.
check_project_agents_tree || true
check_toolkit_provenance || true

legacy_host_status=0
check_legacy_host_config || legacy_host_status=$?

workflow_drift_status=0
check_installed_workflow_drift || workflow_drift_status=$?

if (( non_ok > 0 )); then
  echo
  echo "Non-OK entries:"
  printf '  %s\n' "${non_ok_entries[@]}"
fi

if (( non_ok > 0 || knowledge_root_status != 0 || cross_checkout_status != 0 \
      || legacy_host_status != 0 || workflow_drift_status != 0 )); then
  echo
  exit 1
fi

echo
