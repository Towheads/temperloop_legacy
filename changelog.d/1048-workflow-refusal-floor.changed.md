- **A refused or unavailable `Workflow` invocation now has a specified
  disposition in `/sweep`, `/fix` and `/build`** (#1048). The tier-1
  synchronous chunk invocation in `claude/commands/sweep.md` Step 3 is the
  floor tier 2 degrades *to*, but it had no floor of its own: a refusal is
  no `{parked, escalations}` return at all, so the run stalled or improvised
  and Step 3.5's terminal-state assertion then hard-failed on unchecked
  entries whose only defect was that the driver was never allowed to start
  them. Now: a new **Step 0.7 preflight** resolves foreground availability
  once, up front (the `Workflow` tool present in the session tool list, plus
  a readable `$workflowPath` — both pure reads, safe under `--dry-run`) and
  stops with the remedy named rather than failing per chunk; the background
  half stays `unknown` by design, since a classifier refusal is only decided
  at invocation time, and tier 2's existing degradation notice consumes it at
  its single launch point. A chunk refused at call time is never retried:
  every issue in it is machinery-parked — a comment naming the refusal and
  the remedy, deliberately **no** `needs-clarification` label and no
  assignment, since there is no question to answer — recorded on the existing
  `parked` terminal disposition (no fourth disposition, so Step 3.6's
  `merged + resolved + parked == items_processed` arithmetic is untouched),
  and the run continues to the next chunk. A **second consecutive** refusal
  ends the attempt loop for the run, bounding the prompt storm a nine-chunk
  run would otherwise produce. `/fix` gets the same preflight and the same
  machinery-park; `/build`'s floor is instead its existing conversational
  `--no-workflow` path, which it now selects for the rest of the run.
  Scoped **defensively**: the live 2026-08-02 refusal hit the tier-2
  *background* launch, which degraded exactly as specified — the foreground
  path was permitted.
