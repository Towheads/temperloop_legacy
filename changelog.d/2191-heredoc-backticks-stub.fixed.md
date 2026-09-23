- **The replay-batch test suite's timeout shard no longer prints `sleep` usage
  errors to stderr** (#2191). The shard built a stub runner from an unquoted
  heredoc whose comments quoted `` `sleep` `` and `` `exec` `` in backticks, so
  the shell ran each of them as a command substitution while writing the file:
  two `usage: sleep number[unit] [...]` lines on the suite's stderr, and a stub
  whose comments arrived on disk with those words deleted. The backticks are now
  escaped like the `\$1` beside them, so the stub is written with its comments
  intact and the shard's stderr is empty like every other shard's.
