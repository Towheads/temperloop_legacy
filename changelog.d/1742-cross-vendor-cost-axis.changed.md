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
  a figure the page withheld.

  A token class the records never priced is no longer silently costed at
  zero, and the two ways that happens are now kept apart. A class carrying no
  value at all is a gap, and it withholds the cost axis whatever the arms
  were run against. A class that is simply zero on every record withholds
  only when the two arms ran against different vendors, whose usage reports
  need not have the same shape; when both arms ran against one vendor it is
  reported as a genuine zero the comparison carries, because an arm that
  never created cache really did spend nothing on it and withholding there
  would break the same-vendor comparison this axis exists for.

  Nothing is repriced: per-arm pricing in a common currency is deliberately
  not built, so the spend-reconciliation, attribution-emit and report
  surfaces still count a token identically, and the replay pre-flight spend
  ceiling stays in house currency as a budget cap.
