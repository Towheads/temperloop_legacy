- **Toolkit provenance: the toolkit now reports whether the code you are
  running is the release it claims to be** (#1047). A new read-only,
  network-free probe (`workflows/scripts/toolkit-provenance.sh`) answers
  `RELEASED`, `MODIFIED` (naming every differing path, split into your own
  uncommitted drift versus committed drift attributed to its commit, author and
  any `Upstream:` reference) or `UNKNOWN` (always with a reason), for both a
  vendoring consumer and a managed clone. It persists no state anywhere, so
  there is nothing to go stale and nothing to remove at uninstall. The verdict
  surfaces in four places: the health check (`check_toolkit_provenance` —
  `WARN`-level and strictly non-fatal), an unprompted session-start notice on
  `MODIFIED`, a re-probe folded into the subtree-edit guard's prompt (the moment
  drift begins, which a session-start check is structurally blind to), and a
  `/tidy` drain step that records a persistently modified checkout to the
  pending-decisions surface.
- **`temperloop doctor` is now a subcommand.** The health check was previously
  reachable only by typing an absolute script path or as the tail of
  `temperloop update`. `temperloop doctor` `exec`s the same script, so its
  output and exit code are identical by construction, and it takes the same
  optional `<toolkit-root>` argument. This **supersedes a documented
  statement**: `bin/README.md` and `docs/features/install-cli.md` both said
  outright that no such subcommand existed, and both are corrected in the same
  change.
