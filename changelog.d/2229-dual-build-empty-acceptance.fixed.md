- **A dual-build arm that records no acceptance evidence is no longer reported
  as a passing arm** (#2229). An arm whose worker returned `status: done` with
  an empty `acceptance_results` used to come back `gate: pass` — a record
  byte-identical, at the level tally, the ledger row and the level-pick
  payload, to an arm that had verified every criterion. A pass naming zero
  criteria cannot be told apart from a vacuous one, and in a two-arm
  comparison that asymmetry reads as a model difference. Such an arm is now
  recorded as a `fail` with `loss_reason: incomplete` and a named
  `unevidenced-acceptance` failure, so it cannot win its item and its branch
  never reaches a PR. Arms that record their criteria are unaffected.
- **The dual-build level cost block no longer reports `known: true` over a
  null token count** (#2229). `known` was true whenever *either* tokens or
  wall-clock had been captured, so a level with no token envelope published
  `{ tokens: null, known: true }`. `known` now answers for `tokens` alone and
  the fallback unit carries its own `wall_clock_known`; the cheaper-arm
  tie-break is unchanged, as it reads the values rather than these flags.
