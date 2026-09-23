- **A failed `runner-preflight` can no longer skip the required `checks`
  status context** (#2211). Since the self-hosted runner routing landed,
  `checks` declared `needs: [runner-preflight]` with no `if:` — and a `needs`
  job that fails or is cancelled does not fail its dependent, it *skips* it, so
  a preflight that died outside its own (fail-open) script left the repo's only
  required context unpublished: either the merge queue wedges, or GitHub treats
  the skip as passing and a commit reaches `main` having run zero gates.
  `checks` now carries `if: ${{ !cancelled() }}` — not `always()`, which would
  also override a deliberate cancellation — plus a `'"ubuntu-latest"'` JSON
  fallback on `runs-on`, so a preflight that wrote no output routes the full
  gate set to a hosted runner instead of erroring out on `fromJSON('')`. The
  normal self-hosted and hosted routing paths, the job body, the matrix and the
  context name are all unchanged.
