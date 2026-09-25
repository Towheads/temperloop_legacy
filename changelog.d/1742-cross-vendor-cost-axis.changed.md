- **The model-comparison report's cost axis now declares itself unavailable
  across vendors instead of publishing an incomparable delta** (#1742). One
  cost-weight set prices both arms — correct within a vendor, where the
  weights cancel out of the delta, and indefensible across two, where a
  different output-to-input price ratio systematically mis-states one arm.
  The report now carries a cross-vendor verdict: whether the axis is
  comparable at all, a named reason when it is not, and per-arm tariff facts
  naming each arm's observed vendor and models. The rendered page prints that
  reason where the cost delta would have gone, and the machine-readable
  summary sidecar carries the same flag so an automated consumer cannot lift
  a figure the page withheld. A token class that no record in an arm ever
  priced is reported as unpriced rather than silently costed at zero. Nothing
  is repriced: per-arm pricing in a common currency is deliberately not
  built, so the spend-reconciliation, attribution-emit and report surfaces
  still count a token identically, and the replay pre-flight spend ceiling
  stays in house currency as a budget cap.
