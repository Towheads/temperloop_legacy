- **The shell and Python review seats now always run on the strong model,
  instead of whichever model the session driving them happened to use**
  (temperloop#2179, pin the shell-reviewer and python-reviewer seats to an
  explicit tier). Each automated reviewer in this project declares which model
  it runs on. These two declared "whatever the caller is running" — which buys
  agreement with the caller, never a floor. A cheaply-run automated drive
  therefore ran them cheaply, silently, with nothing in any artifact recording
  that it had happened.

  That matters more for these two seats than for most. The project's own
  routing table sends every shell script, every `Makefile`, and the build
  driver itself to the shell reviewer, and every Python file to the Python
  reviewer — so both gate the machinery this project is made of, and no second
  reviewer stands behind either. The earlier decision to leave them alone
  rested on the belief that they only ran in other people's repositories, and
  that belief was wrong.

  The gap was observed rather than assumed: in two consecutive review passes
  the shell seat ran on the strong model only because the session driving it
  did, while a sibling seat on the same pass ran cheap. The behaviour was right
  by accident; it is now right by construction. A test asserts both pins, so
  the decision cannot drift back unnoticed, and the tier inventory records the
  reasoning as settled rather than open.

  Deliberately not swept along: the TypeScript and workflow-spec seats keep
  reading their model off the calling session. Their case rests on different
  reasoning, with a measurement still outstanding.
