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
- **The reconciliation guard now fails CLOSED on a lake it cannot read** (#2220).
  `validate-command-run-reconcile.sh` built its file list as a space-joined
  string and expanded it unquoted, so a lake path containing a space split into
  non-existent fragments, the read error was swallowed, and the reduction over
  zero files produced a valid empty report — `ok — 0 record(s)` over a lake it
  never opened, with every check passing vacuously. The list is an indexed array
  handed straight to `jq`, and `jq`'s exit status is kept and checked: a read
  that FAILED is now distinguishable from one that found nothing. A non-numeric
  `CMD_RUN_OPEN_GRACE_SECS` is likewise a hard failure rather than a silent skip
  of the MISSING-RUN check it bounds.
- **…and on a lake DIRECTORY it cannot list** (#2220). The fix above reached the
  stream FILE only; the lake DIRECTORY kept the identical hole one level up.
  `for f in "$raw_dir"/command-runs-*.jsonl` with `[ -f "$f" ] || continue`
  folded "readable, no files", "unreadable", "absent" and "not a directory"
  into one empty file list, and the empty-list arm printed the sanctioned
  exit-0 sentence over all four — so a lake **holding a real record**, merely
  `chmod 000`, reported that this host had emitted no telemetry and that there
  was no property to break. The directory is now classified before the glob:
  not-a-directory and unlistable fail closed in either mode, and a lake named
  **explicitly** (`--raw-dir` or `$CMD_RUN_RAW_DIR`) also fails closed when it
  is absent or holds no matching file — the same explicit/default asymmetry
  `--stream` and `--open-dir` already implement. The one documented exit-0
  case is unchanged but narrowed to what it always meant: **default** mode,
  no matching files. A record count that could not be read now also fails
  closed as MISSING-RUN rather than silently skipping that marker.
- **A terminal emit now closes only the open-ledger marker it adopted** (#2220).
  `emit-command-run.sh`'s close path `rm`-ed whatever sat on the ledger key
  whenever nothing was parked — including a marker the run never adopted: an
  aged `emitted=0` marker (past `CMD_RUN_RUN_ID_TTL_SECS`, so a fresh id was
  minted instead) or a malformed one carrying no `run_id`. Both are exactly
  what `validate-command-run-reconcile.sh` reads as MISSING-RUN and
  MARKER-MALFORMED, so the alarm was erased before the guard could see it,
  contradicting the documented invariant that an `emitted=0` marker is never
  removed at any age. An unadopted marker is now left in place; only its own
  run, or `--open`'s spent-marker prune, retires it.
- **`validate-command-run-emit.sh`'s `--command` presence check no longer
  accepts a longer command name** (#2220). It anchored on `\b`, which matches
  between `e` and `-`, so `triage.md`'s own legitimate
  `--open --command triage-feedback` line satisfied the `triage` check by
  itself — drop the main `/triage` open call and the lint stayed green. It now
  anchors on whitespace-or-end-of-line.
- **The command-run open ledger is keyed per RUN, not per (session, command)**
  (#2220). Two `/fix` runs driven concurrently from one session — ordinary
  operator usage — collapsed onto one marker and one `run_id`, and the second
  `--open` overwrote the first run's held id. `emit-command-run.sh` takes a new
  `--target` (a `/fix` target, a `/sweep` or `/triage` board), passed identically
  on the `--open` call and the terminal emit; `--open` never overwrites a marker
  still live on its key, and moves a stale un-emitted marker aside rather than
  deleting the missing-run alarm it represents. Marker writes are atomic
  (write-temp-then-rename), and a non-numeric `CMD_RUN_RUN_ID_TTL_SECS` warns and
  falls back instead of silently disabling the adoption freshness bound. A caller
  that passes no `--target` keeps the previous key byte-for-byte.
- **The live-lake reconciliation sweep moved off the merge path to `/tidy`**
  (#2220). `scripts/quality-gates.sh` gates the hermetic fixture suite only. The
  guard's default mode reads `meta/data/raw`, mutable per-host state no diff
  produces, so one abandoned `emitted=0` marker — a killed session, exactly what
  the ledger exists to record — would have turned the gate red for every later
  merge on that host. `/tidy`'s environment-hygiene step runs it and reports
  stale markers, which is where a stale-marker report belongs.
