- **The push supersede probe no longer reads a rebase as unsuperseded remote
  work** (#2095). `pr.sh push --allow-rewrite` and `build-level.mjs`'s
  escalation-time work-preservation push both gated a `--force-with-lease` on
  `git rev-list --cherry-pick`, which decides commit equivalence by **patch-id**
  — and `git patch-id` hashes the diff body, context lines included. §3e.5
  rebases every continuation round onto a fresh `origin/main`, so any advance
  landing within three lines of the item's own hunk changed the rebased commit's
  patch-id even though it applied intact. The probe then counted the engine's
  own previous-round commit as unique remote work, and the push was refused
  `remote_not_superseded` / the item reported `WORK_PRESERVE_FAILED` with
  `preserved: false` — on the pipeline's common path, not a rare one.

  A non-zero patch-equivalence count is now cross-checked against a
  **content-containment** oracle: merge the remote tip into `HEAD` in memory
  (`git merge-tree --write-tree`) and ask whether the tree moved. An unchanged
  tree means the remote holds no content `HEAD` lacks, which is invariant under
  rebase. The conservative narrowing is preserved exactly — a continuation that
  genuinely **drops** a commit an earlier round pushed, an unrelated branch-name
  collision, and a remote that will not merge cleanly all still refuse and
  escalate — and a git too old for `merge-tree --write-tree` (before 2.38) keeps
  the previous patch-equivalence verdict rather than widening the gate. A push
  that forces now reports `supersede_basis` (`patch-equivalence` or
  `content-containment`) naming which oracle allowed the rewrite.
