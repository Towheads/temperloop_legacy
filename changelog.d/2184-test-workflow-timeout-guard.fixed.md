- **`make test-build-workflow` and `make test-build` are now bounded by a
  wall-clock guard that names the case that was running** (#2184). Neither
  target had any bound, so a hang inside the suite ran forever with no signal
  — the observed incident ran ~50h and left two orphaned process trees, and
  surfaced only because a human looked at `ps`. Both targets now run through
  `workflows/scripts/build/bounded-suite.sh`, which fails loudly at
  `$BUILD_SUITE_TIMEOUT_SECS` (new, default 1800s, `build.config.sh`) with a
  report naming the case that was RUNNING — not the last one that passed —
  and kills the suite's whole process group so nothing is left orphaned. The
  same process-group reap runs on SIGINT and SIGTERM, so Ctrl-C leaves no
  detached suite behind either. The watchdog is dependency-free bash: it needs
  neither GNU `timeout` nor `gtimeout`, so the bound holds on a stock macOS.

  A healthy run keeps its exit code, its byte-identical stdout, and its
  stderr unmerged and untouched. One difference is worth knowing about rather
  than discovering: the wrapped suite's stdout is a file that the guard
  relays onward, not the caller's terminal, so `isatty(1)` is false inside the
  suite and stdout arrives in ≤1s relay batches. A suite that branches on a
  tty check will take its non-tty branch.
