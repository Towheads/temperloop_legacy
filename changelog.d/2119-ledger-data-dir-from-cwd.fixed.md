- **The dual-build ledger now writes to the repo being built, not the kernel
  checkout** (#2119). `workflows/scripts/model-comparison/dual-build-ledger.sh`
  resolved its ledger *data* folder (`rows.jsonl`, `archives/`,
  `calibration-pairs.jsonl`, `calibration.json`, and `archive-check`'s default
  `--repo`) by climbing from `$0` to the kernel checkout, so an adopter's rows
  landed in the kernel's `.temperloop/` and two repos dual-building on one host
  silently shared one ledger — while the read side
  (`workflows/scripts/report-producers/dual-build`) was already cwd-scoped, so
  the two halves disagreed. Data now resolves from `git rev-parse
  --show-toplevel` of the cwd, per `report.contract.md`'s "invoked with cwd =
  the target repo" invariant; a cwd outside any checkout is refused by name
  rather than falling back. **Settings resolution is deliberately unchanged** —
  `BUILD_CONFIG`/`build.config.sh` keeps the `$0` climb (the temperloop#980
  kernel-vs-adopter boundary), and a decoy `build.config.sh` in the cwd repo is
  never sourced.
  **One behavior change rides along:** `archive-check`'s default `--repo` is
  data too, so it is now empty outside any checkout — an
  `archive-check <slug> <arm> --dir DIR` invocation with no `--repo`, which
  used to work from any cwd, refuses by name (`pass --repo PATH`) rather than
  test-applying the patch against whatever checkout the script ships in. Pass
  `--repo PATH`, or run it from inside the repo being checked.
- **Additive `repo` field on the dual-build ledger row schema** (#2119). Each
  row now carries the absolute git toplevel it was appended from, so a ledger
  that an explicitly shared `DUAL_BUILD_LEDGER_DIR` still mixes can be split by
  repo rather than discarded. It is **backward compatible**: rows written
  before the field existed carry no `repo` key, and `read`, its `--expect`
  self-check, `calibrate-*` and the report producer all parse, tally and render
  them unchanged.
- **The build machinery pins the dual-build ledger dir explicitly** (#2119).
  Every `dual-build-ledger.sh` invocation `claude/workflows/build-level.mjs`
  emits now carries an absolute `--dir` rooted at the driven repo root, so the
  ledger target no longer depends on the executor's cwd. Without it the new
  cwd-relative default would have followed an executor sitting in a linked
  worktree — landing `rows.jsonl`, the patch archives and
  `calibration-pairs.jsonl` in a directory `git worktree remove` destroys, and
  leaving the level-pick gate reading an empty calibration. The cwd default
  stays correct for a human running the script inside the repo being built.
