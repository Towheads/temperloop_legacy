- **A `## Review notes` block in a pull-request body now carries only that
  reviewer's own review** (#2224). Before each push, `/build` runs a panel of
  code reviewers (the charters under `claude/agents/`) and splices what each
  one returned into the pull-request body under `## Review notes`. A reviewer
  that emitted anything *above* the `## Summary` heading its own charter tells
  it to start with — on pull request #2223, a line of chatter plus a whole
  `## Answer to the relayed question` section replying to something the
  operator had asked the build orchestrator about the run, not about the diff —
  shipped that text verbatim into the merged body. That preamble is now
  withheld when the body is rendered and replaced by a one-line marker naming
  how many lines were removed, and the reviewer's verbatim return is written to
  the `/build` run log instead, so nothing is lost — only moved off the durable
  artifact. The marker and the log are computed from the same text, so they can
  never disagree about what was withheld.

  The guard fails toward *preserving*: a block with no `## Summary` heading at
  all, or one whose preamble contains a `### [HIGH]`, `### [MEDIUM]`,
  `### [LOW]`, `## Findings` or `## What's solid` heading, is passed through
  untouched — that is review content in an odd order, not chatter, and dropping
  a real finding off the body a reviewer relies on would be worse than the leak
  it fixes. A well-formed review block renders byte-identically to before.
