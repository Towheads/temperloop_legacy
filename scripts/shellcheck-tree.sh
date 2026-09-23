#!/usr/bin/env bash
#
# scripts/shellcheck-tree.sh — the whole-tree shell lint run by the
# `make shellcheck` target, as a BOUNDED-CONCURRENCY fan-out instead of one
# serial `xargs` pass (temperloop#2164).
#
# (Style note for editors of this file: never start a comment line with the
# bare tool name after the `#` — that is the directive syntax, and the linter
# then rejects the whole file with SC1073/SC1072 instead of reading prose.)
#
# ── Why ──────────────────────────────────────────────────────────────────
# `make shellcheck` used to be exactly one line:
#
#     find . -name '*.sh' -not -path './.git/*' -not -path '*/tests/*' -print0 \
#       | xargs -0 --no-run-if-empty "$bin" -e SC1091
#
# i.e. ONE single-threaded shellcheck process over ~223 files, and it is pinned
# to the gate pool's serial lane (scripts/quality-gates.sh § SERIAL_LANE_PINS),
# so its whole wall time lands on the critical path. Once temperloop#2162 split
# the test-build / test-cli-subcommands umbrellas into ~73 per-script gates,
# nothing else in the pool was long enough to hide behind — measured on the
# item's host (2026-09-22, 10 cores, 223 files): 33s serial, the longest single
# gate left in the set. This script is the same lint, fanned out.
#
# ── The correctness trap this exists to avoid (read before editing) ──────
# A shellcheck finding is NOT per-file — findings depend on WHICH OTHER FILES
# share the invocation. shellcheck follows a `source`d file only when that file
# is *also named as an input on the same command line* (that is what SC1091
# "was not specified as input" means). So a naive shard changes the verdict:
# split this tree into chunks and scripts/quality-gates.sh is suddenly linted
# WITHOUT workflows/scripts/lib/gate-selection.sh beside it, its
# GATE_SELECTION_* assignments look dead, and four brand-new SC2034/SC2329
# findings appear that the serial run never emitted. Measured, not theorised:
# a bare `xargs -0 -P8 -n10` shard of this exact tree produced 4 findings the
# serial pass did not.
#
# The fix is `-x` (--external-sources): shellcheck then resolves each `source`
# from disk instead of from the command line, which makes every finding
# INVOCATION-INDEPENDENT — the property sharding needs. `-x` does not widen
# what gets LINTED (the `*/tests/*` exclusion below is untouched; a followed
# file is read for context, never reported on), and on the tree at adoption
# time whole-tree serial WITH `-x` was byte-identical to whole-tree serial
# WITHOUT it. scripts/tests/test_shellcheck_tree.sh pins both halves.
#
# ── Ordering and exit codes ──────────────────────────────────────────────
# Chunks are CONTIGUOUS slices of the file list in `find` order, each chunk's
# output captured to its own file and concatenated back in chunk order — so the
# printed report is byte-identical to the old serial command's, and no two
# concurrent shellcheck processes ever interleave into one stream (the BSD-vs-
# GNU `xargs -P` interleaving hazard simply never arises).
#
# The verdict is FAIL-CLOSED, which is the subtle part of any `-P` fan-out: a
# chunk records its own shellcheck status to a file and always exits 0, and the
# parent fails the run if ANY chunk's status is non-zero, unparseable, or
# MISSING (a chunk killed before it could report is a lost verdict, never a
# pass). `xargs`'s own non-zero exit is folded in too.
#
# ── Portability ──────────────────────────────────────────────────────────
# Stock macOS as well as the Linux CI image. Notably NOT used: `nproc` (GNU
# coreutils; absent on macOS — the core count is resolved through
# gate-pool.sh's already-tested portable resolver), and `xargs -P` for anything
# but dispatch. `xargs -P maxprocs` itself is in both the BSD and GNU xargs.
#
# ── Usage ────────────────────────────────────────────────────────────────
#   bash scripts/shellcheck-tree.sh [--root <dir>] [--jobs <n|auto>]
#                                   [--shellcheck <path>]
#
#   --root <dir>         tree to lint (default: this script's repo root)
#   --jobs <n|auto>      worker count (default: $SHELLCHECK_JOBS, else `auto`)
#   --shellcheck <path>  binary to run (default: resolved via
#                        scripts/ensure-shellcheck.sh, the pin of #567)
#
# Exit 0 when the tree is clean, non-zero when any file fails or any chunk's
# verdict is lost.
set -uo pipefail

_sct_script_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_sct_self="$_sct_script_dir/$(basename "${BASH_SOURCE[0]}")"
_sct_repo_root="$(cd -P "$_sct_script_dir/.." && pwd)"

# The exact lint invocation, in ONE place so the parent, the shard and the
# test suite can never drift apart. `-e SC1091` is inherited verbatim from the
# pre-parallel target; `-x` is the sharding enabler documented above.
SHELLCHECK_TREE_FLAGS=(-x -e SC1091)

# ── Shard mode ───────────────────────────────────────────────────────────
# Internal re-exec target, never invoked by hand: lint one chunk, capture its
# output and its status beside the chunk's own argument list, exit 0 either way
# so `xargs` never aborts the fan-out on a lint finding.
if [ "${1:-}" = "--shard" ]; then
  _sct_chunk="${2:-}"
  [ -n "$_sct_chunk" ] || { echo "shellcheck-tree.sh: --shard needs a chunk dir" >&2; exit 2; }
  _sct_bin="$(cat "$_sct_chunk/../bin")"
  cd "$(cat "$_sct_chunk/../root")" || exit 2
  _sct_files=()
  while IFS= read -r -d '' _sct_f; do
    _sct_files+=("$_sct_f")
  done < "$_sct_chunk/args"
  _sct_rc=0
  if [ "${#_sct_files[@]}" -gt 0 ]; then
    "$_sct_bin" "${SHELLCHECK_TREE_FLAGS[@]}" "${_sct_files[@]}" \
      > "$_sct_chunk/out" 2>&1 || _sct_rc=$?
  else
    : > "$_sct_chunk/out"
  fi
  printf '%s\n' "$_sct_rc" > "$_sct_chunk/rc"
  exit 0
fi

# ── Parent mode ──────────────────────────────────────────────────────────
root=""
jobs_spec="${SHELLCHECK_JOBS:-auto}"
bin=""

while [ $# -gt 0 ]; do
  case "$1" in
    --root)
      root="${2:-}"
      shift
      shift
      ;;
    --jobs)
      jobs_spec="${2:-}"
      shift
      shift
      ;;
    --shellcheck)
      bin="${2:-}"
      shift
      shift
      ;;
    -h | --help)
      awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "$_sct_self"
      exit 0
      ;;
    *)
      echo "shellcheck-tree.sh: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

[ -n "$root" ] || root="$_sct_repo_root"
root="$(cd -P "$root" && pwd)" || exit 2

# Worker count. Reuses gate-pool.sh's resolver rather than re-deriving it: it is
# already portable (nproc where present, `sysctl -n hw.ncpu` on Darwin, a sane
# constant otherwise), already clamps a bogus spec to 1 rather than silently
# picking a concurrency nobody asked for, and is already covered by
# scripts/tests/test_quality_gates_parallel.sh. If that lib is missing (a
# partial checkout), fall back to 1 — serial is always CORRECT, only slow.
jobs=1
# shellcheck source=workflows/scripts/lib/gate-pool.sh
if . "$_sct_repo_root/workflows/scripts/lib/gate-pool.sh" 2>/dev/null; then
  jobs="$(gate_pool_resolve_jobs "$jobs_spec")"
fi
case "$jobs" in
  '' | *[!0-9]*) jobs=1 ;;
esac
[ "$jobs" -lt 1 ] && jobs=1

# The pinned binary, resolved ONCE in the parent — never concurrently by N
# shards, which would race ensure-shellcheck.sh's single shared cache path.
if [ -z "$bin" ]; then
  bin="$(bash "$_sct_repo_root/scripts/ensure-shellcheck.sh")" || exit 1
fi

# The file set. This find expression is the pre-parallel target's, verbatim —
# in particular the `*/tests/*` exclusion is deliberate and is NOT this item's
# to narrow (that question is tracked separately in temperloop#2191).
files=()
while IFS= read -r -d '' f; do
  files+=("$f")
done < <(cd "$root" && find . -name '*.sh' -not -path './.git/*' -not -path '*/tests/*' -print0)

[ "${#files[@]}" -gt 0 ] || exit 0

tmp="$(mktemp -d)" || exit 1
trap 'rm -rf "$tmp"' EXIT
printf '%s\n' "$bin" > "$tmp/bin"
printf '%s\n' "$root" > "$tmp/root"

# Chunk width: aim for ~4 chunks per worker so a slow file cannot straggle a
# whole worker's share, while still amortising process startup over a batch.
chunk_target=$((jobs * 4))
[ "$chunk_target" -lt 1 ] && chunk_target=1
per=$(( (${#files[@]} + chunk_target - 1) / chunk_target ))
[ "$per" -lt 1 ] && per=1

nchunks=0
filled=0
for f in "${files[@]}"; do
  if [ "$filled" -eq 0 ]; then
    d="$tmp/$(printf '%06d' "$nchunks")"
    mkdir -p "$d"
    : > "$d/args"
    nchunks=$((nchunks + 1))
  fi
  printf '%s\0' "$f" >> "$d/args"
  filled=$((filled + 1))
  [ "$filled" -ge "$per" ] && filled=0
done

# Dispatch. `xargs -n 1 -P jobs` is the fan-out ONLY — every byte of report and
# every verdict travels through the per-chunk files above, so nothing depends
# on how BSD or GNU xargs interleaves its children's stdout.
xargs_rc=0
i=0
while [ "$i" -lt "$nchunks" ]; do
  printf '%s\0' "$tmp/$(printf '%06d' "$i")"
  i=$((i + 1))
done | xargs -0 -n 1 -P "$jobs" bash "$_sct_self" --shard || xargs_rc=$?

# Reassemble in chunk order, then aggregate the verdict FAIL-CLOSED.
rc=0
[ "$xargs_rc" -eq 0 ] || {
  echo "shellcheck-tree.sh: dispatcher exited $xargs_rc" >&2
  rc=1
}
i=0
while [ "$i" -lt "$nchunks" ]; do
  d="$tmp/$(printf '%06d' "$i")"
  if [ -f "$d/out" ]; then
    cat "$d/out"
  else
    echo "shellcheck-tree.sh: chunk $i produced no output file (verdict lost)" >&2
    rc=1
  fi
  chunk_rc=""
  [ -f "$d/rc" ] && chunk_rc="$(cat "$d/rc")"
  case "$chunk_rc" in
    0) : ;;
    '' | *[!0-9]*)
      echo "shellcheck-tree.sh: chunk $i reported no usable status (verdict lost)" >&2
      rc=1
      ;;
    *) rc=1 ;;
  esac
  i=$((i + 1))
done

exit "$rc"
