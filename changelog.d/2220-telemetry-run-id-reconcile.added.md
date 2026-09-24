- **Command-run telemetry records now carry a stable `run_id`, so a run reduces
  to exactly one record** (#2220). A `/fix` run that parks at the merge gate and
  merges after the operator approves emitted two records for one item, and any
  consumer summing `items_processed` counted it twice. Records now carry the run
  id `emit-command-run.sh --open` mints at the start of a run (the terminal emit
  adopts it — nothing is carried between steps), and a consumer reduces by
  grouping on `run_id` and taking the last record. Purely additive: no
  `schema_version` bump, no already-written line rewritten or backfilled, and a
  pre-#2220 record with no `run_id` still parses and reduces as its own
  singleton run.
- **New guard: `workflows/scripts/validate-command-run-reconcile.sh`** (#2220).
  It owns the property *exactly one reducible record per run* and fails on both
  the ways it breaks — a record written after this host's run-id cutover with no
  `run_id` (unreducible), and an open-ledger marker for a run that started and
  never emitted at all (the inverse failure: seven consecutive `/fix`
  dispositions once produced zero records). `--reduce` prints the reduced
  one-record-per-run view. `/fix`, `/sweep` and `/triage` each open the ledger at
  Step 0, enforced by `validate-command-run-emit.sh`.
