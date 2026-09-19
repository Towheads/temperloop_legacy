- **The acceptance gate could report a failure on a tree where it never ran**
  (temperloop#2142). Before running `scripts/quality-gates.sh` against a
  candidate branch, the build pipeline clears its own configuration out of the
  gate's environment, using the setting names printed by
  `workflows/scripts/build/build-config-settings.sh`. Where that helper is
  missing or predates this feature — any repo on an older vendored copy of the
  toolkit — it printed nothing, and an `unset` with no arguments is a harmless
  no-op in bash but an error in zsh, which is the shell the pipeline's command
  runner uses on macOS. That error aborted the rest of the chained command, so
  the gate never executed at all; the pipeline then read the missing result as
  a failed gate and stopped the branch as broken. Clearing that configuration is
  best-effort tidying, so its failure should never have been able to stop the
  gate at all — and an absent helper was only one of three ways it could fail.
  The command now always passes a placeholder name so the list is never empty,
  ignores anything the helper prints that is not a valid setting name, checks in
  a throwaway shell whether the clearing would fail before doing it for real,
  and finally disregards its result either way. Whatever goes wrong with the
  tidying now, the gate still runs and reports what it actually found. The two
  other places in this repo that clear configuration the same way
  (`workflows/scripts/count-prose.sh` and the build-config settings test) were
  carrying the same assumption in a comment that said it was safe; they now
  carry the corrected form and the corrected comment.

- **The log line for a passed acceptance gate now names a stable slice cap**
  (temperloop#2133). It printed a single `cap N` figure that was whatever
  allowance remained at that moment, so a run that had extended its budget
  printed a different number for the same word. That figure is what you read to
  decide whether to raise `BUILD_GATE_SLICE_SECS` or split the gate list, and a
  number that means something different each run cannot be compared. The line
  now names the configured base cap, how many extensions are allowed, the
  resulting hard limit, how many were spent and this run's ceiling — each
  derived from its setting rather than restated.

- **A gate slice whose failure count cannot be read is no longer treated as a
  clean slice** (temperloop#2133). When a long-running gate exhausts its time
  budget, the pipeline grants it more only if every slice so far reported zero
  failures. That check coerced any unreadable count to zero, so an unknown
  result would have been indistinguishable from a clean one. It now requires a
  real number. Nothing changes today — every count the pipeline currently
  produces is already a plain number — this closes the path before an
  unreadable-count case can take it.
