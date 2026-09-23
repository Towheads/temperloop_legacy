- **`make test-build` and `make test-cli-subcommands` are no longer quality
  gates; their 73 individual test scripts are.** (#2162) Each umbrella entry
  looped a whole directory glob *serially inside one worker slot*, so the gate
  pool — which schedules per list entry — could never spread the two longest
  poles in the set (measured serially: 335s and 125s, against 77s and 71s for
  their slowest individual script). `scripts/quality-gates.sh` now
  glob-expands `workflows/scripts/build/tests/` and `bin/subcommands/tests/`
  at list time into one gate per script, so a newly added `test_*.sh` becomes
  a gate with no registry edit anywhere. The same tests still run — this is a
  re-packaging for parallelism, not a coverage change — and both `make`
  targets still work for local use.
- **Every per-script gate carries its own wall-clock bound.** (#2162) Each one
  runs through `workflows/scripts/build/bounded-suite.sh` under the
  `BUILD_SUITE_TIMEOUT_SECS` setting, so the hang guard added in #2184 covers
  the path the gate run actually takes rather than only the `make` targets it
  was originally wired to. That guard's poll cadence was tightened in the same
  change, cutting its per-invocation cost from roughly 1.0s to 0.25s.
- **`workflows/scripts/config/gate-paths.tsv` now accepts a wildcard row
  key.** (#2162) A key carrying `*`, `?` or `[` maps a whole family of gates,
  which is what lets the expanded families stay path-scoped without a
  hand-typed row per script. An exact key still wins over a wildcard one, so a
  single script can keep its own narrower row, and
  `workflows/scripts/config/check-gate-paths.sh` still fails a wildcard row
  that matches no current gate.
