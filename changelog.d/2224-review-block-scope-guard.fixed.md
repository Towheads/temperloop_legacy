- **A `## Review notes` block in a PR body now carries only that seat's own
  review** (#2224). A §3e reviewer that emitted out-of-scope preamble above its
  declared `## Summary` — on PR #2223, a line of chatter plus a whole
  `## Answer to the relayed question` section answering something the operator
  had asked the *orchestrator* about the run — shipped that text verbatim into
  the merged PR body. `reviewBodySuffix()` now withholds the preamble at the
  one render seam, replacing it with a marker naming how many lines were
  removed, and the reviewer's verbatim return is logged by the run instead.
  The guard fails toward preserving: a block with no `## Summary` anchor, or
  one whose preamble contains a `### [HIGH|MEDIUM|LOW]` finding, a
  `## Findings` or a `## What's solid` heading, is passed through untouched, so
  a real finding can never be dropped. A well-formed review block renders
  byte-identically to before.
