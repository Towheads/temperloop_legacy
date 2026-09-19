The build orchestrator is loadable again, and can no longer outgrow its own loader unnoticed.

`claude/workflows/build-level.mjs` is executed by the Claude Code Workflow tool, which refuses to load a script file above a fixed byte limit. Nothing in this repo measured the file against that limit, because the limit belongs to the tool rather than to the project. The file crossed 98% of it in one change and went past it in the next, at which point `/fix`, `/sweep` and `/build` all stopped working at once — they each start by handing the tool this one file. Both changes had passed every check, because no check was looking.

Two things changed:

- 42 long explanatory comment blocks were moved out of the module into a new companion file, `claude/workflows/build-level.design-notes.md`, each one replaced in the code by a one-line summary and a pointer to its full text. The notes are unabridged — they record why each mechanism works the way it does, and several were quoted by reviewers while this change was being made. No line of code was touched: the module's 4,202 non-comment lines are byte-for-byte identical before and after. The file went from 554,776 bytes to 425,358, leaving roughly 46KB of room before the new guard objects.
- A new check measures every workflow script against a configured share of the tool's limit and fails the build when one gets close, reporting how many bytes of room are left rather than a bare percentage. Its own test asserts both directions — that an oversized file is rejected and a normal one is not — so the check cannot quietly stop working.

The order matters: this failure is not self-repairing. Fixing it needs the orchestrator, and the orchestrator is what stops loading, so recovery is a manual edit outside the usual pipeline.
