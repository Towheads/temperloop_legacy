- **The two slowest quality gates now finish in well under a minute each**
  (#2163). `test_score_gate_env.sh` fell from 33s to 8s locally (176s to 144s
  was the CI pair before this change), and `test_replay_batch.sh` — a
  250-second straggler that set the pool's makespan floor on its own — is now
  eight `--group N` gates whose longest shard is 49s locally. Both were
  profiled before being cut, and **no assertion was weakened, skipped or
  deferred to nightly**: the same 72 checks run, and each shard additionally
  re-runs the suite's no-live-call canary verdict, so hermeticity is proved
  per shard rather than once per suite.
  - `test_score_gate_env.sh` spends ~100% of its wall time running the real
    config-ladder suite twice, so the win came from `temperloop config list`
    itself, which dropped 3.02s to 0.63s with byte-identical output: the
    registry row splitter stopped deriving its field count from a
    `${row//[!$'\t']/}` global substitution (a per-character bash walk, ~2ms
    per row over 434 rows) and now accumulates it while splitting, the
    registry's list-membership test became one quoted-substring `case` instead
    of a quadratic word-split loop, and `config list`'s three per-row layer
    probes now read a one-shot variable index instead of re-scanning a map.
    `bin/subcommands/tests/test_config.sh` fell from 17s to 4s with them.
  - Fixture stubs that exist to outlive a bounded timeout now `exec sleep`
    rather than forking one. Under `run_with_timeout`'s portable bash backend
    — the path a stock macOS runner without `timeout`/`gtimeout` takes — the
    watchdog `kill -9`s the bash it spawned, and a forked `sleep` survived it,
    was re-parented to init, and showed up as a `Terminate orphan process …
    (sleep)` line at CI job teardown. Measured directly: forked leaves a
    PPID-1 orphan, `exec`'d leaves none.
