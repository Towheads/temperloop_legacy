- **A `/build` CI-fix re-review keeps its delta range across an upstream
  rebase, and is told the base moved** (#2149). The §3e.5 pre-gate freshness
  step now re-stamps the §3e prior-reviewed-SHA marker onto the post-rebase
  base, so the §3g re-review's `git diff <prior-sha>..HEAD` range covers
  exactly the CI fix instead of degrading to no range at all (the marker
  previously named a commit the rebase had orphaned). Because the reviewer
  never saw the post-rebase tree, the re-stamp also writes a paired notice
  that the continuation prompt renders: the round is told an upstream rebase
  landed between rounds, that its prior conclusions were made against a
  pre-rebase tree, and that the tighter range excludes the upstream delta.
  temperloop#2127's `git merge-base --is-ancestor` fail-safe is unchanged and
  still empties a base that is not an ancestor of `HEAD`, so a history rewrite
  the re-stamp does not cover still degrades to the range-free wording.
