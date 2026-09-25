- **A model-comparison arm that is refused for recording no acceptance evidence
  now gets its own failure record** (#2252). All such refusals previously shared
  one object — both arms of a pair, and every pair in a comparison run. Nothing
  wrote to it, so no run was affected, but any later change that annotated a
  record in place would have altered every other record at the same time. Each
  record is now built separately. No output shape changes.
- **Two self-checks in `workflows/scripts/build/tests/test_workflow.sh` now
  report a moved code anchor as a moved anchor** (#2252). Each locates a
  function in `claude/workflows/build-level.mjs` and inspects its body. If that
  function is renamed, the lookup returns nothing and the check used to fail
  claiming the code inside it had been deleted — sending the reader after a call
  site that was never removed. The checks now verify they found the function
  before inspecting it, and say so when they did not. They also match the
  function name exactly: previously a name that merely *began* with the one
  being looked for would satisfy the lookup and hand the check unrelated code,
  which was found by testing the new behaviour rather than by reading it. Both
  still fail the build on the condition they were written to catch.
