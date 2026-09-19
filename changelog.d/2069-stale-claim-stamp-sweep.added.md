- **`reconcile.sh` gains a `--claims` lens that clears a dead session's claim
  stamp, so a stranded board item becomes claimable again** (#2069). When an
  item is In Progress and its `fnd:host/session:*` stamp names a session on
  the same host that is provably dead — its Claude Code transcript is absent,
  or untouched for longer than `RECONCILE_STALE_AFTER_SECS` — that one label
  is now the only thing removed. The `fnd:status:*` label is left
  byte-identical, the issue is never closed, and its status is never moved
  back to Ready, so an epic that is genuinely still in flight keeps reading
  that way. Previously nothing cleared such a stamp while the item stayed
  open and In Progress, and `workflows/scripts/board/claim.sh` refuses a claim
  another session owns — so the item could not be picked up again by anyone.
  `workflows/scripts/board/reconcile.sh --board <N> --claims` reports the
  candidates with how long each has been stale and writes nothing; `--apply`
  performs the strips; `--unattended` implies `--apply` and records what it
  cleared to the pending-decisions note. A stamp on another host is never
  stripped — that session's liveness cannot be checked from here — and a live
  session's own claim is never touched. An item an **open PR** would close is
  reported rather than stripped: its work is already delivered and its claim is
  held until the merge cascade clears it, so clearing the stamp early would let
  a later claim silently overwrite the owner. If the open-PR read errors, or
  its result cannot be established, every candidate is reported and nothing is
  stripped — and an `--unattended` run records how many candidates that
  covered to the pending-decisions note, as its own number, separate from the
  count it held back for an open PR, even when it cleared nothing. A failing
  open-PR read is therefore visible at the next check-in as a count that keeps
  recurring, instead of only in one night's output while the sweep quietly
  stops clearing anything. `claude/commands/tidy.md` runs the sweep on its
  nightly pass.
