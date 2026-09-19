- **When `/build`'s quality-gate run is cut short, the report now names a fix
  that can actually work** (#1650). The run is sliced: the gate suite runs for a
  budgeted stretch, stops cleanly between gates, and resumes. When no verdict
  comes out of that, the escalation used to offer one suggestion — raise the
  slice budget, or split the gate list — and that suggestion was wrong about
  half the time and unactionable the other half.
  - **The two ways a run ends without a verdict now read differently.** A suite
    that is slow *in aggregate* runs out of slices with every slice returning
    cleanly, and more gate time genuinely helps it. A *single* gate that overruns
    the whole window kills the slice outright, and no amount of extra budget
    reaches it — the budget is only ever checked between gates. The report now
    says which of the two happened and offers only the lever that fits it.
  - **The slice budget is reported with its ceiling.** Raising it is bounded:
    the deadline that kills a slice is derived from the budget and is itself
    capped by the hard limit on how long one command may run, so at the shipped
    default the budget can rise by a fifth and the deadline by about a tenth —
    once. The report now states that arithmetic, and when the budget is already
    at its ceiling it says so instead of suggesting a raise that cannot happen.
  - **The report names the gate the run stopped on.** "Split the gate list" used
    to leave the reader to find the offending gate themselves; the escalation now
    carries that gate's position in the list and, when the list still resolves,
    its name and the one command that prints it.
  - **That command is now the same command the report ran.** It was being built
    twice, and the copy handed to the reader left out the setting that puts the
    gate suite on its scoped selection — so it listed the full gate set and, at
    the same position, named an unrelated gate with complete confidence. Both are
    now built from one place, quoted so a checkout path containing a space still
    works, and a gate name carrying a quote or a backslash no longer corrupts the
    report it is written into.
  - **A gate spelled outside the expected vocabulary now fails the build.** The
    position-to-name lookup only recognises gates that begin `make ` or `bash `;
    one spelled any other way was silently dropped and shifted every later
    position by one. `check-gate-paths.sh` gained a fifth check that fails on it.
