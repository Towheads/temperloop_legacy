- **`/build`'s dual-build judge verdict and its calibration status are no
  longer thrown away, and a discarded payload now says so** (#2208). The
  sibling of #2205 one level down: that one fixed the list of *result values*
  the driver's machinery helper may return, this one fixes the *shape of the
  data* those results carry. The driver's result contract declared only flat
  scalar fields and no nested ones, including the only two nested results the
  dual-build steps emit — the pairwise judge's verdict and the judge's own
  calibration status. An undeclared field is still accepted but has no declared
  type, so the decode was free to hand it back as a JSON *string*, and did: a
  live run produced a complete verdict and a real calibration reading, both
  arrived stringified, and both readers' "is this an object?" checks silently
  dropped them — reporting a judge that was never available and a calibration
  file that could not be reached, neither of which was true. Both fields are
  now declared as objects. A payload that still arrives with the wrong type is
  reported under its own name (`judge-payload-shape-mismatch` /
  `calibration-payload-shape-mismatch`) with a message saying the result
  *arrived and was discarded*, instead of the old message blaming the judge for
  producing nothing; a genuinely missing payload keeps its original
  "unavailable" reading, so the two stay distinguishable. The calibration gate
  still fails closed in every case. `workflows/scripts/build/tests/test_workflow.sh`
  gained a third lockstep axis that fails the build if a nested result the
  driver reads as an object is ever left undeclared again.
