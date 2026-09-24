- **Capability probes are now shell-dialect-safe, so a sourced lib can no longer
  call an undefined function** (#1776). `declare -F <name>` is bash's "is this a
  defined function?"; zsh implements `declare` as `typeset`, whose `-F` means
  "float with N digits", so the probe *declared a float* and exited 0 for a name
  that did not exist. Because every command spec mandates `source "$BOARD_LIB"`
  inside the agent's Bash tool — zsh on macOS — the guard was inverted on the
  primary path: `board.sh` died `_board_issues_item_list: command not found:
  cache_read` on the first board call of a `/triage` run, twice. Every real
  capability guard in the tree (and the `type -t` probe in
  `scripts/quality-gates.sh`, bash-only in the same way) now uses the POSIX
  `command -v`, correct in both shells, and the command specs' own snippets were
  updated with them. The load-bearing `reconcile.sh` contract — its board reads
  stay live *because* the probe fails when `cache.sh` is unsourced — is preserved
  and still pinned by `test_reconcile.sh` Lens 3 and
  `test_cache_command_wiring.sh` section 3.
- **New gate `scripts/lint-shell-dialect-probe.sh`** (#1776), run by
  `scripts/quality-gates.sh` like every other gate, fails on a
  newly-introduced `declare -F` / `typeset -F` / `type -t` capability probe across
  the tracked shell set *and* `claude/commands/*.md` (a spec's fenced snippets are
  pasted verbatim into that zsh shell, so a spec is an execution surface for this
  bug). Portable `typeset -f` and comments that merely name the idiom are not
  flagged; a line that must carry the shape as data opts out with a
  `shell-dialect-probe:exempt — <why>` pragma. A degenerate input (absent or
  unreadable file, empty resolved file set) exits 2 rather than reporting a
  vacuous pass.
