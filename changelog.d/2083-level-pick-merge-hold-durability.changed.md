- **A dual-build pull request held back for a missing disclosure line now stays
  held across a crash or a resume** (#2083). The hold lived only in the memory of
  the run that worked out the level, so a `/build` that died — or was simply
  re-run later against the same plan — saw an ordinary parked item with an
  ordinary open pull request and merged it without the
  `Model-comparison-arms:` line. The hold is now written onto the plan note
  itself as a `merge_blocked:` field: `plan.sh writeback` gains
  `--merge-blocked <value>` to record it and `--clear-merge-blocked` to lift it,
  carries an existing hold through every later write that does not mention it,
  and `plan.sh roster --stage gate` reports a held item as
  `MERGE BLOCKED (<value>) — held out of the merge set` instead of counting it
  among the pull requests up for merge.
