- **A refused dual-build arm's `failure` record is built fresh per arm** (#2252).
  `UNEVIDENCED_ACCEPTANCE_FAILURE` was one module-level object spread by
  reference into every refused arm's record — both arms of a pair, and every
  pair in a level, all aliasing one instance. Nothing mutated it, so the bug was
  latent; the first edit to annotate a record in place (stamping a slug or arm
  name onto `record.failure` before logging) would have silently rewritten every
  other record in the level. It is now a factory, matching the fresh-object
  convention every sibling `failure` value already followed.
- **The #2229 static guards report an anchor that moved as an anchor that moved**
  (#2252). Both guards capture a function body with an `awk` range and grep it
  without checking the capture is non-empty, so renaming the anchored function
  made them fail with the wrong reason — "driveArm never calls
  unevidencedAcceptance" when the call site was intact and only the name had
  changed. They now assert the capture first. The anchors were also tightened to
  match the opening paren: `/^async function driveArm/` matched any function
  whose name merely *starts* with `driveArm`, so a prefix-colliding rename
  handed the guard a body it was never pointed at and did not trip it at all —
  found by mutation-testing the new assertions rather than by reading them.
