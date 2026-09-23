- **`checks` now runs on the mini's self-hosted Linux CI VM when it is online
  and idle, and on hosted `ubuntu-latest` otherwise** (#2165). A new
  `runner-preflight` job in `.github/workflows/ci.yml` lists the repo's
  self-hosted runners through a `RUNNER_PAT` repo secret (fine-grained,
  Administration: Read on this repo only) and hands `checks` its `runs-on`.
  The required status context is unchanged — it is still `checks
  (ubuntu-latest)`, because a context is named from the job and its matrix
  values, never from `runs-on` — so branch protection and the merge queue
  need no change. Without the secret, or with the VM stopped or busy, every
  run routes hosted exactly as before: the self-hosted path is an
  accelerator, never a dependency. `checks` also gains `timeout-minutes: 30`
  so a wedged self-hosted job cannot hold the merge queue for GitHub's
  6-hour default. Provisioning, autostart and uninstall of the VM live in
  foundation's `infra/ci-runner/`; this repo owns only the routing.
