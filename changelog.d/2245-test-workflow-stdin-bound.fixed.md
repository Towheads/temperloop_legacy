- **A direct run of the build workflow test suite is now wall-clock bounded,
  and the suite can no longer be hung by anything reading its stdin** (#2245).
  `make test-build-workflow` and the `checks` CI job already ran
  `workflows/scripts/build/tests/test_workflow.sh` under
  `workflows/scripts/build/bounded-suite.sh`, which kills a stalled run at
  `BUILD_SUITE_TIMEOUT_SECS` and names the case that was running — but a bare
  `bash workflows/scripts/build/tests/test_workflow.sh` had no bound at all,
  which is exactly how one run sat for 11 hours. The suite now re-execs itself
  under that wrapper when invoked directly; the wrapper exports
  `WF_TEST_SELF_BOUND=1` to the command it runs, so the make and CI paths are
  unchanged and never wrap twice (set it yourself to run the suite raw, e.g.
  under a debugger). Separately, the suite redirects its own stdin from
  `/dev/null` before it does anything else, so a child that falls back to
  stdin — the incident's `cat`, or any future `cat "$empty_var"` — reads EOF
  instead of blocking on a runner's never-closing socket. Both layers are
  proven in `workflows/scripts/build/tests/test_bounded_suite.sh` against
  stdin deliberately held open by a never-closing FIFO.
