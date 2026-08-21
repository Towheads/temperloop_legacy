#!/usr/bin/env bash
#
# toolkit-provenance.sh — answer, for the toolkit code that is actually
# running, whether it is byte-identical to the release it claims to be
# (temperloop#1047; ADR 0021 "toolkit provenance is derived, never declared"
# and ADR 0022 "the baseline is the recorded-vs-recomputed subtree split").
#
# THE QUESTION. The toolkit reaches a machine by one of two paths, and on both
# of them the live machine surface (~/.claude/…) resolves through symlinks into
# a working tree — so editing that tree changes the toolkit's behaviour in the
# next session. Nothing else on the machine reports whether the code running
# right now is a released version or somebody's local modification. This script
# is that report.
#
# THE VERDICT VOCABULARY — one vocabulary, two backends behind it:
#   RELEASED   the subject tree is byte-identical to the release it claims.
#   MODIFIED   it is not, and every differing path is named — split into
#              UNCOMMITTED drift (the running operator's, now) and COMMITTED
#              drift (a shared git-history fact, attributed to its commit and
#              author, with any `Upstream:` waiver reference).
#   UNKNOWN    the baseline could not be established. ALWAYS carries a reason.
#
# THE GOVERNING POLARITY (ADR 0022 § Consequences): when the baseline cannot be
# established the verdict is UNKNOWN, **never** RELEASED. A probe that reports
# "released" for a modified tree is worse than no probe — it re-creates exactly
# the invisibility this exists to remove while asserting it has been removed.
# So every failure path in this file lands on UNKNOWN.
#
# READ-ONLY, NETWORK-FREE, FAIL-OPEN. It runs a handful of local `git`
# plumbing calls, writes nothing anywhere (ADR 0021: no marker file, no mode
# flag, no added pin-file field — nothing to go stale, nothing to uninstall),
# never contacts a network, and exits 0 on every verdict including UNKNOWN.
# Exit 2 is reserved for a usage error, mirroring env-hygiene-report.sh.
#
# ── BACKEND 1: vendoring consumer (repo-root `.kernel-pin` + `kernel/`) ──────
# The release claim is `.kernel-pin`'s `tag` line (READ-ONLY here — that file's
# format is a versioned contract surface and its mere PRESENCE class-gates the
# kernel self-distribution suite; this script never writes it).
#
# The baseline is the **subtree split**, recorded against recomputed. A
# squashing `git subtree pull --squash` (what `scripts/update-kernel.sh` runs)
# synthesises a commit whose message carries
#
#     git-subtree-dir: kernel
#     git-subtree-split: <upstream sha>
#
# and whose OWN TREE is exactly the pulled subtree content. That commit is
# reachable from HEAD forever (it is the merge's second parent), so its tree is
# a durable, local, network-free record of "what was pulled". The recomputed
# side is `HEAD:kernel` (plus the working tree, for uncommitted drift).
#
# WHY NOT THE PIN COMMIT (rejected outright — ADR 0022). `update-kernel.sh`
# makes TWO commits: the subtree pull first, then a separate pin-file commit —
# and skips the second entirely on an idempotent re-run. Using "the commit that
# last touched .kernel-pin" as the baseline therefore advances the baseline PAST
# a pre-existing hand edit, the diff comes back empty, and the probe reports a
# modified tree as RELEASED. That exact sequence is reproduced as a regression
# fixture in workflows/scripts/tests/test_toolkit_provenance.sh.
#
# ── BACKEND 2: managed clone ($TEMPERLOOP_HOME) ─────────────────────────────
# A managed clone has no subtree at all, so it needs its own baseline: the
# NEAREST REACHABLE release tag (`git describe --tags --abbrev=0`), not exact
# tag detachment. An adopter who commits a modification is no longer sitting
# exactly at the tag — and that is precisely the state most worth reporting.
#
# ── NEITHER: UNKNOWN, with a reason ─────────────────────────────────────────
# The kernel's own development checkout is neither a vendoring consumer (no
# `.kernel-pin`) nor the managed clone, and has no release baseline to compare
# against — it reports UNKNOWN naming that. Giving it a `.kernel-pin` to make
# it comparable would mis-classify the whole self-distribution test suite at
# once (ADR 0021), so it is deliberately left unanswerable.
#
# CAPABILITY LIMIT, stated rather than papered over (ADR 0021 § Consequences):
# this can only report what git can see inside the vendored prefix / managed
# clone. An adopter's edits to their OWN repository or overlay are out of scope
# by construction.
#
# Usage:
#   toolkit-provenance.sh [--root <dir>] [--format report|verdict|entry]
#
#     --format report   (default) human-readable verdict + full attribution.
#     --format verdict  one bare word — RELEASED | MODIFIED | UNKNOWN. The
#                       machine-readable form doctor.sh and the hooks parse.
#     --format entry    a ready-to-append `### … Status: open` pending-decisions
#                       block, IFF the verdict is MODIFIED; prints NOTHING
#                       otherwise. Same shape/contract as
#                       env-hygiene-report.sh --format entry.
#     --root <dir>      probe THIS tree instead of the running toolkit's own.
#
# Env:
#   TOOLKIT_PROVENANCE_ROOT  same as --root (the test seam; --root wins).
#   TEMPERLOOP_HOME          managed-clone location (default
#                            $HOME/.local/share/temperloop — the value
#                            bin/lib/common.sh's TEMPERLOOP_CLI_HOME_DEFAULT
#                            and bin/bootstrap.sh both use).
#
# WHICH TREE IS PROBED BY DEFAULT, and why it is not $PWD. The subject is the
# tree THIS SCRIPT PHYSICALLY LIVES IN, resolved through symlinks — i.e. the
# toolkit that is actually running. That is what makes the cross-engagement
# case work: the managed clone is shared across every project an adopter
# touches (bin/README.md § Running across multiple repos or clients), so a
# session started in a second, unrelated project tree still resolves into the
# same modified toolkit and still gets the verdict. Scoping to $PWD's repo
# would report RELEASED there, which is the wrong answer.
#
# Kept bash-3.2 compatible (macOS /bin/bash), like its sibling probe scripts.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

# ── Arg parse ───────────────────────────────────────────────────────────────
FORMAT="report"
ROOT_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --format) FORMAT="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
    --format=*) FORMAT="${1#--format=}"; shift ;;
    --root) ROOT_ARG="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
    --root=*) ROOT_ARG="${1#--root=}"; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "toolkit-provenance: unknown arg: $1" >&2; exit 2 ;;
  esac
done
case "$FORMAT" in
  report|verdict|entry) ;;
  *) echo "toolkit-provenance: unknown --format: $FORMAT (report|verdict|entry)" >&2; exit 2 ;;
esac

# ── Verdict state (populated by resolve_*; rendered at the bottom) ──────────
VERDICT="UNKNOWN"
REASON=""
BACKEND=""
CLAIMED_RELEASE=""
BASELINE_DESC=""
COMMITTED_PATHS=""
UNCOMMITTED_LINES=""
ATTRIBUTION=""

unknown() {
  VERDICT="UNKNOWN"
  REASON="$1"
}

# git_q <root> <args...> — a git call that never leaks stderr and never trips
# `set -e` semantics for its caller (this script runs without -e, but every
# call site tests the status explicitly).
git_q() {
  local root="$1"; shift
  git -C "$root" "$@" 2>/dev/null
}

# ── Resolve the subject tree ────────────────────────────────────────────────
# Precedence: --root > $TOOLKIT_PROVENANCE_ROOT > this script's own tree.
subject_dir="$ROOT_ARG"
[ -n "$subject_dir" ] || subject_dir="${TOOLKIT_PROVENANCE_ROOT:-}"
if [ -z "$subject_dir" ]; then
  # workflows/scripts/<this file> -> the toolkit tree root is two levels up.
  subject_dir="$SCRIPT_DIR/../.."
fi
if resolved=$(cd "$subject_dir" 2>/dev/null && pwd -P); then
  subject_dir="$resolved"
else
  unknown "subject path does not exist or is not a directory: $subject_dir"
  subject_dir=""
fi

git_root=""
if [ -n "$subject_dir" ]; then
  git_root=$(git_q "$subject_dir" rev-parse --show-toplevel)
  if [ -n "$git_root" ]; then
    if resolved=$(cd "$git_root" 2>/dev/null && pwd -P); then git_root="$resolved"; fi
  else
    unknown "$subject_dir is not inside a git checkout — provenance is derived from git and cannot be answered without it"
  fi
fi

# ── Attribution helper ──────────────────────────────────────────────────────
# attribute_paths <root> <baseline-rev> <path-prefix> <paths...>
# For each committed-drift path, name the commit(s) that introduced it since
# the baseline, their author, and any `Upstream: <kernel-PR-url>` waiver
# reference in the commit body. This is what makes the verdict actionable for
# a bystander who inherited someone else's change via a pull rather than
# making it themselves.
attribute_paths() {
  local root="$1" base="$2" prefix="$3"
  shift 3
  local p full line sha an subj body up out="" logout=""
  for p in "$@"; do
    [ -n "$p" ] || continue
    if [ -n "$prefix" ]; then full="$prefix/$p"; else full="$p"; fi
    logout=$(git_q "$root" log --no-merges -n 3 --format='%h|%an|%s' "$base..HEAD" -- "$full")
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      sha="${line%%|*}"; line="${line#*|}"
      an="${line%%|*}"; line="${line#*|}"
      subj="$line"
      body=$(git_q "$root" log -1 --format=%b "$sha")
      up=$(printf '%s\n' "$body" | sed -n 's/^[[:space:]]*Upstream:[[:space:]]*//p' | head -n1)
      if [ -n "$up" ]; then
        out="${out}      via ${sha} \"${subj}\" — ${an} (Upstream: ${up})
"
      else
        out="${out}      via ${sha} \"${subj}\" — ${an} (no Upstream: reference)
"
      fi
    done <<<"$logout"
    ATTRIBUTION="${ATTRIBUTION}    ${full}
${out}"
    out=""
  done
}

# ── Shared comparison ───────────────────────────────────────────────────────
# compare_trees <root> <baseline-tree> <current-tree> <status-pathspec>
# Sets COMMITTED_PATHS / UNCOMMITTED_LINES and the verdict.
compare_trees() {
  local root="$1" base_tree="$2" cur_tree="$3" pathspec="$4"

  COMMITTED_PATHS=$(git_q "$root" diff --name-only "$base_tree" "$cur_tree")

  if [ -n "$pathspec" ]; then
    UNCOMMITTED_LINES=$(git_q "$root" status --porcelain -- "$pathspec")
  else
    UNCOMMITTED_LINES=$(git_q "$root" status --porcelain)
  fi

  if [ -n "$COMMITTED_PATHS" ] || [ -n "$UNCOMMITTED_LINES" ]; then
    VERDICT="MODIFIED"
  else
    VERDICT="RELEASED"
  fi
}

# ── BACKEND 1 — vendoring consumer ─────────────────────────────────────────
resolve_vendored() {
  local root="$1" prefix="kernel"
  BACKEND="vendored subtree ($prefix/ in $root)"

  CLAIMED_RELEASE=$(awk '/^tag /{print $2; exit}' "$root/.kernel-pin" 2>/dev/null)
  [ -n "$CLAIMED_RELEASE" ] || CLAIMED_RELEASE="<no tag line in .kernel-pin>"

  local sq
  sq=$(git_q "$root" rev-list -n 1 HEAD --grep="^git-subtree-dir: ${prefix}\$")
  if [ -z "$sq" ]; then
    unknown "no subtree-split marker for '$prefix/' is reachable from HEAD — this vendored tree was not produced by a squashing subtree pull, so there is no recorded baseline to compare against"
    return 0
  fi

  local base_tree cur_tree recorded
  base_tree=$(git_q "$root" rev-parse "${sq}^{tree}")
  if [ -z "$base_tree" ]; then
    unknown "the subtree-split commit $sq has no readable tree — the object store cannot answer the baseline"
    return 0
  fi
  cur_tree=$(git_q "$root" rev-parse "HEAD:${prefix}")
  if [ -z "$cur_tree" ]; then
    unknown "HEAD carries no '$prefix/' tree — the vendored prefix is absent from the committed tree"
    return 0
  fi
  recorded=$(git_q "$root" log -1 --format=%B "$sq" | sed -n 's/^git-subtree-split:[[:space:]]*//p' | head -n1)
  BASELINE_DESC="subtree split ${recorded:-<unrecorded>} recorded at ${sq} (tree ${base_tree}) vs recomputed tree ${cur_tree}"

  compare_trees "$root" "$base_tree" "$cur_tree" "$prefix"

  if [ "$VERDICT" = "MODIFIED" ] && [ -n "$COMMITTED_PATHS" ]; then
    local ifs_save="$IFS"; IFS=$'\n'
    # shellcheck disable=SC2086
    set -- $COMMITTED_PATHS
    IFS="$ifs_save"
    attribute_paths "$root" "$sq" "$prefix" "$@"
  fi
}

# ── BACKEND 2 — managed clone ──────────────────────────────────────────────
resolve_managed() {
  local root="$1"
  BACKEND="managed clone ($root)"

  local tag
  tag=$(git_q "$root" describe --tags --abbrev=0 --match 'v[0-9]*' HEAD)
  if [ -z "$tag" ]; then
    unknown "no release tag is reachable from HEAD in the managed clone — a shallow or tagless clone has no baseline (run 'git -C $root fetch --tags' to restore one)"
    return 0
  fi
  CLAIMED_RELEASE="$tag"

  local base_tree cur_tree
  base_tree=$(git_q "$root" rev-parse "${tag}^{tree}")
  cur_tree=$(git_q "$root" rev-parse "HEAD^{tree}")
  if [ -z "$base_tree" ] || [ -z "$cur_tree" ]; then
    unknown "could not resolve the tree for $tag or HEAD in the managed clone"
    return 0
  fi
  BASELINE_DESC="nearest reachable release tag ${tag} (tree ${base_tree}) vs recomputed HEAD tree ${cur_tree}"

  compare_trees "$root" "$base_tree" "$cur_tree" ""

  if [ "$VERDICT" = "MODIFIED" ] && [ -n "$COMMITTED_PATHS" ]; then
    local ifs_save="$IFS"; IFS=$'\n'
    # shellcheck disable=SC2086
    set -- $COMMITTED_PATHS
    IFS="$ifs_save"
    attribute_paths "$root" "$tag" "" "$@"
  fi
}

# ── Backend selection ──────────────────────────────────────────────────────
if [ "$VERDICT" = "UNKNOWN" ] && [ -z "$REASON" ] && [ -n "$git_root" ]; then
  managed_home="${TEMPERLOOP_HOME:-$HOME/.local/share/temperloop}"
  if managed_resolved=$(cd "$managed_home" 2>/dev/null && pwd -P); then
    managed_home="$managed_resolved"
  fi

  if [ -f "$git_root/.kernel-pin" ] && [ -d "$git_root/kernel" ]; then
    resolve_vendored "$git_root"
  elif [ -n "$managed_home" ] && [ "$git_root" = "$managed_home" ]; then
    resolve_managed "$git_root"
  elif [ -f "$git_root/workflows/scripts/kernel/kernel-manifest.txt" ]; then
    BACKEND="kernel development checkout"
    unknown "$git_root is the kernel's own development checkout — it carries no .kernel-pin (deliberately: that file's presence class-gates the self-distribution suite) and is not the managed clone, so there is no release baseline to compare against"
  else
    BACKEND="unrecognised"
    unknown "$git_root is neither a kernel-vendoring consumer (no .kernel-pin + kernel/) nor the managed clone at ${TEMPERLOOP_HOME:-$HOME/.local/share/temperloop}"
  fi
fi

# ── Render ─────────────────────────────────────────────────────────────────
if [ "$FORMAT" = "verdict" ]; then
  printf '%s\n' "$VERDICT"
  exit 0
fi

render_drift() {
  if [ -n "$UNCOMMITTED_LINES" ]; then
    printf '  uncommitted drift (yours, right now — restore it or upstream it):\n'
    printf '%s\n' "$UNCOMMITTED_LINES" | sed 's/^/    /'
  fi
  if [ -n "$COMMITTED_PATHS" ]; then
    printf '  committed drift (a shared git-history fact — it arrived with a pull, it is not necessarily yours):\n'
    printf '%s' "$ATTRIBUTION"
  fi
}

if [ "$FORMAT" = "entry" ]; then
  [ "$VERDICT" = "MODIFIED" ] || exit 0
  ts=$(date '+%Y-%m-%d %H:%M')
  host=$(hostname -s 2>/dev/null || echo unknown-host)
  printf '### %s · toolkit provenance · %s\n' "$ts" "$host"
  printf -- '- **Decision:** reconcile a MODIFIED toolkit checkout (%s) that claims to be %s — upstream the change, or restore the released content\n' "$BACKEND" "$CLAIMED_RELEASE"
  printf -- '- **Default taken:** leave modified (report-only; nothing restored, nothing upstreamed, no PR opened)\n'
  printf -- '- **Disposition:** auto-taken (unattended/--force-now; no live operator)\n'
  printf -- '- **Status:** open\n'
  printf -- '- **Detail:**\n'
  render_drift | sed 's/^/  /'
  exit 0
fi

# --format report
printf 'Toolkit provenance: %s\n' "$VERDICT"
[ -n "$BACKEND" ] && printf '  backend:   %s\n' "$BACKEND"
[ -n "$CLAIMED_RELEASE" ] && printf '  claims:    %s\n' "$CLAIMED_RELEASE"
[ -n "$BASELINE_DESC" ] && printf '  baseline:  %s\n' "$BASELINE_DESC"
case "$VERDICT" in
  UNKNOWN)
    printf '  reason:    %s\n' "$REASON"
    ;;
  RELEASED)
    printf '  the toolkit tree is byte-identical to the release it claims.\n'
    ;;
  MODIFIED)
    render_drift
    ;;
esac
exit 0
