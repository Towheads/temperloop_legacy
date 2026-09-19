- **A cumulative dual-build report producer, wired into `temperloop report`
  by default** (#2084, epic #2065, ADR 0038/0041). `workflows/scripts/
  report-producers/dual-build` rolls the dual-build ledger's per-item,
  per-arm rows into a per-tier block: a candidate item-win rate with an
  exact binomial interval (never a bootstrap), the level-pick tally (which
  arm's code actually shipped, override-inclusive — a distinct number from
  the override-blind win rate), whole-job cost per arm, the override rate,
  and the judge's own calibration status. Unresolved items (tied, unjudged,
  infra, or both-gates-failed) are excluded from the win-rate numerator and
  denominator and counted in an honesty block alongside the tier scope,
  single-host scope, and a not-in-scope count (unavailable from the ledger
  alone, reported as such rather than fabricated). A verdict is printed only
  once the judge is `calibrated` *and* the sample clears
  `MODEL_COMPARISON_MIN_SAMPLE_N` *and* the unresolved rate stays under
  `DUAL_BUILD_UNRESOLVED_THRESHOLD_PCT` — otherwise it prints `"below floor
  - keep accumulating"` or `"judge uncalibrated - verdict withheld"` rather
  than a number it cannot support. Unlike the model-comparison module's own
  inert shim (ADR 0027), this producer's `.temperloop/report.d/dual-build`
  locator shim IS wired unconditionally by `temperloop init`, the same
  treatment as the `tokens` shim — zero standing cost, since an empty ledger
  degrades to one `skipped -- ` line.
