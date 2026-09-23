- **`make shellcheck` now lints the tree in parallel instead of in one
  single-threaded pass** (#2164). It was the longest gate left in
  `scripts/quality-gates.sh` once the `test-build` / `test-cli-subcommands`
  umbrellas were split into per-script gates (#2162), and it sits on the pool's
  serial lane, so its whole wall time was on the critical path: 36s → 12s at
  four workers on the reference host (19s at two), over the same file set with
  a byte-identical report. `SHELLCHECK_JOBS` picks the worker count —
  `auto` (the default) resolves the host's cores through the same portable
  resolver the gate pool uses, and `SHELLCHECK_JOBS=1` restores the
  pre-parallel serial pass exactly.

  Two things to know if you vendor this gate. The target's body moved out of
  the `Makefile` into `scripts/shellcheck-tree.sh`, so a consuming repo that
  copied the old recipe should take the script instead. And the lint now runs
  with `-x` (`--external-sources`), which is what makes a finding
  invocation-independent and therefore safe to shard — without it, splitting
  the tree invents new `SC2034`/`SC2329` findings for variables whose only use
  is in a file that is no longer in the same invocation. `-x` widens what
  shellcheck reads for *context*, never what it *lints*: the file set, the
  `*/tests/*` exclusion and `-e SC1091` are unchanged.
