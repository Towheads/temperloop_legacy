- **A machinery result line dropped, merged or reshaped in relay is now
  detected instead of read as a step that never ran** (#2193). A batched
  machinery sequence stops early by design, so "fewer results than steps"
  carried no information: a corrupted relay and an absent step both escalated
  as `machinery step '<name>' produced no result`. The generated batch script
  now prints its own end-of-run tally — steps dispatched, steps run, JSON lines
  printed — as its last line on every exit path, including an early stop, and
  the engine refuses the whole batch under a new `machinery-relay-integrity`
  escalation kind when the relayed array does not account for that count, or
  when a relayed object carries a field no machinery step emits (the live case
  invented `questions_surfaced` / `question_count` while folding two steps into
  one object). A faithful relay is unchanged — same results, same step indices,
  no new escalation — and the closed field set is re-derived from the emitters
  by a lockstep guard, so a new machinery field can never become a false
  refusal.
