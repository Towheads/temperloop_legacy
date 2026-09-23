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
- **Additive `repo` field on the dual-build ledger row schema** (#2119). Each
  row now carries the absolute git toplevel it was appended from, so a ledger
  that an explicitly shared `DUAL_BUILD_LEDGER_DIR` still mixes can be split by
  repo rather than discarded. It is **backward compatible**: rows written
  before the field existed carry no `repo` key, and `read`, its `--expect`
  self-check, `calibrate-*` and the report producer all parse, tally and render
  them unchanged.
