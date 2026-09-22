- **`checks` now routes to the shared self-hosted `ci-mini` Linux runner when
  one is online and idle, falling back to hosted `ubuntu-latest` otherwise**
  (#2165). A new `runner-preflight` job in `.github/workflows/ci.yml` probes
  both the org- and repo-scoped self-hosted runner APIs with the optional
  `RUNNER_PAT` secret and emits a dynamic `runs-on` for `checks`. Every
  failure mode — absent secret, fork PR, 403/404, non-JSON body, offline,
  busy, or a runner missing any required label — falls through to hosted, so
  a checkout with no runner and no secret is unaffected. The required status
  context is deliberately unchanged: `checks`'s single-entry
  `strategy.matrix` is retained purely as the `checks (ubuntu-latest)`
  context-name token, since GitHub derives a matrix job's check name from the
  job id and matrix values and never from `runs-on`.
- **The CI required-context guard in `scripts/tests/test_quality_gates_parallel.sh`
  now asserts the context itself instead of counting jobs** (#2165). It previously
  proxied "one job on a single-entry matrix" by requiring at most two top-level job
  keys, which false-failed on a second job that cannot move the context while
  passing a second matrix *dimension* that renames it to
  `checks (ubuntu-latest, <x>)`. It now checks the `checks` job id, exactly one
  matrix dimension with exactly one value, that the value is the `ubuntu-latest`
  token the required context is spelled with, and that the preflight's hosted
  fallback image agrees with it.
