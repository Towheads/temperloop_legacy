- **The model-comparison report's cost axis now declares itself unavailable
  across vendors instead of publishing an incomparable delta** (#1742). One
  `SPEND_WEIGHT_*` set prices both arms — correct within a vendor, where the
  weights cancel out of the delta, and indefensible across two, where a
  different output:input ratio systematically mis-states one arm. The
  producer's `cost_basis` block gains a `cross_vendor` verdict (`comparable`,
  a named `reason`, and per-arm `arm_tariffs` read off `candidate.provider`),
  and `render.sh` prints that reason where the delta would have gone. A token
  class absent from every record in an arm is now reported as **unmapped**
  rather than silently priced at zero, kept distinct from a vendor that bills
  zero for it. Nothing is repriced: per-arm weights in a common currency are
  deliberately not built, so `batch.sh` spend reconciliation,
  `emit-model-usage.sh` and the producer still count a token identically, and
  the replay pre-flight spend ceiling stays in house currency as a budget cap.
