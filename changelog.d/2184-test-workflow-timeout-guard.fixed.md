- **`make test-build-workflow` and `make test-build` are now bounded by a
  wall-clock guard that names the case that was running** (#2184). Neither
  target had any bound, so a hang inside the suite ran forever with no signal
  — the observed incident ran ~50h and left two orphaned process trees, and
  surfaced only because a human looked at `ps`. Both targets now run through
  `workflows/scripts/build/bounded-suite.sh`, which fails loudly at
  `$BUILD_SUITE_TIMEOUT_SECS` (new, default 1800s, `build.config.sh`) with a
  report naming the case that was RUNNING — not the last one that passed —
  and kills the suite's whole process group so nothing is left orphaned. The
  watchdog is dependency-free bash: it needs neither GNU `timeout` nor
  `gtimeout`, so the bound holds on a stock macOS. A healthy run is
  unchanged: same stdout, same stderr, same exit code.
