- **A review round whose only blocking findings came from the documentation
  reviewer no longer re-runs the acceptance gate** (temperloop#2138, skip the
  acceptance-gate re-run on a prose-only round). The `/build` driver runs the
  project's own quality-gate suite against each worker's branch before the pull
  request opens — roughly twenty minutes of suite wall time. A round whose only
  blocking findings are the documentation reviewer's changed prose and nothing
  else, so that suite was re-paying for an input set the fix could not have
  moved. Such a round now skips the gate entirely: the suite is never invoked,
  rather than invoked and its result discarded. The findings themselves are
  untouched and still reach the pull request's review notes and the parked
  record exactly as they would have.

  The decision is deliberately one-sided. Skipping an acceptance gate on a
  branch that needed it is far worse than the wasted run the change exists to
  save, so the predicate skips only from a blocking set every one of whose
  findings is positively established as the documentation reviewer's. Anything
  it cannot establish — a round with no blocking findings at all, a finding
  carrying no reviewer, a malformed record, a seat name that merely resembles
  the documentation reviewer's — runs the gate, unchanged. A skipped gate also
  reports its own `SKIPPED` verdict and a null elapsed time rather than a
  fabricated pass, so nothing downstream can read a suite that never ran as one
  that passed.

  This is the gate half of the change only. Deciding *which* reviewers a repeat
  round re-runs remains the stable-roster mechanism shipped in
  temperloop#2129; the two compose, and no second notion of which reviewer
  raised which finding was added beside it.
