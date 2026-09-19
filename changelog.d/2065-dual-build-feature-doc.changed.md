- **The dual-build harness's feature doc, changelog narrative and ADRs now
  describe what actually shipped** (#2065). `docs/features/model-comparison.md`'s
  five required sections gained the harness's mechanism as merged on
  `main` — the level barrier, arm worktree/branch naming and read isolation,
  the pairwise judge, the dual-build ledger and patch archive, the level pick
  and its two operator levers, blind judge calibration, the reviewer contract
  for the `Model-comparison-arms:` trailer, and the per-engagement
  resource/disclosure caveat — rather than the design brief's proposed shape.
  `VERSIONING.md` gained a contract-surface row for the dual-build ledger's
  versioned row schema, and ADRs 0038–0041 flipped from `Proposed` to
  `Accepted` now that the harness they describe is live. Docs-only; no
  behavior changed.
