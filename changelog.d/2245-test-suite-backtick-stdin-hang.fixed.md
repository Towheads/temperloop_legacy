- **The build workflow test suite no longer hangs forever instead of reporting a
  verdict** (#2245). Each `run_node_case` test body is passed as a
  double-quoted bash argument, so bash performs command substitution on it
  while merely *building* that argument — before the test function is even
  entered. Two JS comments quoted a shell word in Markdown backticks
  (``a `cat` after the gate is the regression``), so bash executed them. The
  `sleep` one failed harmlessly; the bare `cat` inherited the suite's stdin and
  blocked forever whenever that stdin was neither a terminal nor `/dev/null` —
  which is exactly the case under an unattended runner, where stdin is a socket
  that never reaches EOF. The suite produced **no verdict at all**: one run
  burned 11 hours and a second checkout sat wedged for 5 days, both looking
  like work in progress rather than a failure. Both backticks are now escaped,
  and a new `#2245` guard refuses any unescaped backtick in a test body —
  seated *ahead of the first test case*, since a guard placed after them would
  be outrun by the very hang it exists to catch. The guard carries its own
  self-check against a synthetic offender, so a clean result cannot be vacuous.
