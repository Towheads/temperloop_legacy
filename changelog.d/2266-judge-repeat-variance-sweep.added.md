- **A stored pair of model-comparison arms can now be re-judged repeatedly,
  without rebuilding anything** (#2266). `judge.sh pairwise` compares two saved
  records and never touches a working tree, so a pair archived by the
  dual-build harness can be scored again long after its worktrees are gone. The
  new `workflows/scripts/model-comparison/judge-repeat.sh` reconstructs both
  records from those archives and re-judges the pair N times (`sweep`), or
  prints what it would send without sending it (`records`), then summarises the
  margin distribution, the order-agreement rate, and a fair-coin sign test over
  decisive verdicts (`report`). The statistics come from the existing
  `stats.sh`; none are computed here.
- **Why this exists.** Two A/A runs — both arms on the same model — each
  returned a confident, order-stable preference at a margin near 17. That is
  what the instrument reports when there is nothing to find, so it is the floor
  any real comparison has to clear. Telling *judge* variance apart from
  *sample* variance previously meant dozens of fresh builds; re-judging one
  stored pair answers the first question for the cost of the judge calls alone.
- **The repeat corpus is kept separate from calibration, on purpose.** Rows go
  to their own `judge-repeat.jsonl` store, never to the blind-pair file the
  calibration bar is computed from — a machine re-judging something is not a
  human having looked at it, and letting it count would move the bar on its
  own. A repeat whose two presentation orders disagree is recorded as the tie
  it is, rather than dropped, so the reported average is not flattered.
