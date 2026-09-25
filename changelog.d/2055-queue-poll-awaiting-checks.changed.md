- **A pull request may now sit in the merge queue for a full hour before
  `gate.sh poll` calls it timed out** (#2055). `BUILD_QUEUE_TIMEOUT`'s default
  was sized for a repo whose `checks` job finishes in a few minutes. A queue
  round trip runs `checks` twice — once on the pull-request branch, once on
  the merge-queue trial branch — so on a repo where one run takes ~21 minutes
  the round trip could not finish inside the old window, and
  `workflows/scripts/build/gate.sh poll` reported `TIMEOUT` on a healthy pull
  request that merged moments later. The sizing rule is now stated next to the
  setting in `workflows/scripts/build/build.config.sh`: the ceiling must
  exceed twice your slowest healthy `checks` run — measure yours and raise it
  before pointing this kernel at a slower repo.

  The trade is that a genuinely stuck pull request is reported up to an hour
  after it was enqueued rather than half an hour. Two things already in place
  absorb that: a `TIMEOUT` carries `gate.sh diagnose-queue`'s classification
  as its `reason` (`QUEUED` for slow, `QUEUE_STALLED` for stuck) plus the full
  diagnosis, so you can tell the two apart the moment it fires; and a queue
  entry that never gets a run dispatched is still named early, at
  `BUILD_QUEUE_STALL_AFTER`, far below the ceiling. Nothing about the poll's
  outcomes, exit codes or `--timeout` flag changed.
