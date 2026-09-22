- **Two of the automated review seats now run on whatever model the session
  driving them runs on, instead of a fixed cheaper one** (temperloop#2132, move
  the workflow and TypeScript review seats to the session model). Each reviewer
  in this project declares which model it runs on. The workflow-spec reviewer
  and the TypeScript reviewer both declared a cheaper fixed model, justified in
  their own charters on the grounds that their findings were advisory — that
  nothing downstream was gated on them and a human would filter anything they
  got wrong.

  That justification stopped being true. A high-severity finding from either
  seat now sends the work item back to be rebuilt before anything is pushed, so
  the seat's output is the gate rather than an input to it. The project's own
  tiering rule says a seat in that position stays on the session model unless a
  paired measurement shows a cheaper one costs less per completed item. No such
  measurement exists yet, so the charters were rewritten to argue from the rule
  that is actually in force, and the stale advisory-findings justification is
  kept only as explicitly-labelled history.

  Worth stating plainly: this is a lead to measure, not a demonstrated
  improvement. The paired comparison that would settle it needs review-round
  telemetry that only began being recorded alongside this release, and the
  comparison is confounded — the seats differ in what they review as well as in
  which model they run on. The caveat is recorded in the tiering rule itself and
  in both charters so it is not quietly forgotten if the numbers later move.

  One trade-off is deliberate and worth knowing about. Reading the model off the
  calling session buys agreement with that session; it does not guarantee a
  floor. A seat that pins its model keeps that model no matter how cheaply the
  caller runs, which is why the architecture reviewer pins its own and is
  unchanged here. The two seats moved in this release will follow a cheaply-run
  driver downward without announcing it. The exposure is bounded — the cheap
  automated tier is already barred from code changes, pull requests and merges —
  but it is real, and reversing it means pinning both seats back.
