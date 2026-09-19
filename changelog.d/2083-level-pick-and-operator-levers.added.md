- **A `/build` run comparing two models now picks a winner for the level and ships
  it** (#2083). Until now a `--dual-build` level built every in-scope item twice,
  judged the two results and stopped there — nothing decided which of the two
  builds actually became a pull request. `/build` now scores the level by a rule
  fixed before the run starts (an arm that produced no green branch loses that
  item; a judged tie counts for neither; an overall tie goes to the arm that cost
  less), opens pull requests from the winning side only, and archives the losing
  branches — deleting one only after proving its saved patch still applies. Each
  winning pull request gets the `Model-comparison-arms:` disclosure line, and a
  pull request that could not be stamped with it is held back from merging rather
  than shipped without the disclosure.
- **The winner is not merged on your behalf until the judge has been checked
  against a human** (#2083). While `.temperloop/model-comparison/dual-build/calibration.json`
  reports anything other than `calibrated`, `/build` stops the level and asks
  before any pull request is opened — with no default and no timeout, so an
  unattended run parks instead of proceeding. Once the judge is calibrated the
  same question becomes optional: you can still override the pick for the whole
  level, or for one item at a time, and an item-level override is recorded as a
  human preference the calibration record keeps.
