- **A build whose CI poll never came back no longer reports the pull request
  as failing** (temperloop#2249). When the poll returned an error — or its
  batch produced no readable result — the run escalated the item as though CI
  had run and gone red. It had not: in the case that surfaced this, the pull
  request's checks were already passing, and it merged with no further changes.
  Escalations of that shape now carry their own name, `ci-unknown`, instead of
  `ci-failed`, so the two get different handling: `ci-failed` means fix the
  failure, `ci-unknown` means re-check the pull request's status. The
  `ci-unknown` payload reports only facts — the poll's own output, the commit
  it was pinned to, and how far through its budget it got — and
  `claude/commands/build.md` documents both names side by side.
