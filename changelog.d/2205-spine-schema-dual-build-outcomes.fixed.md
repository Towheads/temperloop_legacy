- **`/build`'s dual-build comparison no longer discards healthy candidate
  builds as infrastructure failures** (#2205). The driver constrains its
  machinery helper to a fixed list of result values, and twenty of the values
  the dual-build steps actually report — the candidate-arm verdict, the
  comparison-ledger row outcomes, the judge and its calibration pair, the
  winner/loser stamp and archive, the leftover-arm scan, and the vendored-gate
  name probe — were missing from that list. Because the constraint is enforced
  at decode time, a missing value could not be returned at all: the helper was
  forced onto an unrelated one and the true result survived only in an
  undeclared free-form field, so the driver read a passing build as a failure.
  All twenty values are now declared, and
  `workflows/scripts/build/tests/test_workflow.sh` fails the build if the
  values `claude/workflows/build-level.mjs` reports ever drift from the ones it
  declares again.
