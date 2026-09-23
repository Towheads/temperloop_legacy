- **`config list` no longer lets a setting's VALUE supply a shell variable
  NAME** (#2218). The three layer maps are `name<TAB>value`, one record per
  line, and values went in raw — so a setting whose value held a newline (in
  CI, `CHANGELOG_GATE_PR_BODY`, which is the whole pull-request body) opened
  fresh records, and `_config_list_index` then read a *name* out of value
  text and handed it to `printf -v`. Bash parses that name argument: a name
  shaped `IDENT[...]` makes the brackets an array subscript evaluated in
  **arithmetic context**, which performs command substitution. Two observed
  consequences, both fixed here:

    - **Attacker-influenced text reached an evaluating context.** A PR body
      line of the form `evil[$(cmd)]<TAB>x` ran `cmd`, and `config list`
      still exited 0. Bounding it honestly: fork PRs get no secrets and, per
      GitHub's default, need approval for a first-time contributor, and
      runner-preflight routes a secret-less run to hosted `ubuntu-latest` —
      but a same-repo branch PR can route to the self-hosted `ci-mini`
      runner. The everyday trigger is accidental rather than hostile: a PR
      body quoting `config list --format tsv` output or a
      `contexts == ["checks (ubuntu-latest)"]` line is enough.
    - **A fabricated row for a real setting, and a red CI gate.** Prose
      shaped `IDENT<TAB>value` was indexed as that setting, so
      `BUILD_QUOTA_PAUSE_PCT` reported `machine-conf 99` when the truth was
      `tracked-repo 10` — both the value and the winning layer invented. The
      arithmetic-eval case aborted under `set -u`, turning
      `test_config.sh` and `test_score_gate_env.sh` red on any
      `pull_request` run whose diff scoped them in.

  The fix is at the producer, not the consumer: every value is now carried
  and printed C-escaped (`\\`, `\t`, `\n`), applied at one place per
  direction, so a value structurally cannot carry a field or record
  separator. `_config_list_index` additionally refuses any name that is not
  a legal shell identifier before `printf -v` sees it, so the hazard stays
  closed even if a future edit reintroduces a bad name.

- **`config list` output now escapes backslash, TAB and newline in the
  `value` column** (#2218) — both `--format tsv` and `--format text`, for
  all five layers. This makes the documented "one row per line" contract
  structural. A consumer that wants raw bytes reverses `\n` → newline,
  `\t` → TAB, `\\` → backslash, in that order. No value in the current
  registry contains any of the three, so today's output is byte-identical.
  Trailing newlines in a file-layer value are now preserved rather than
  eaten by the map's `$( )` capture, closing the "the parse is not
  lossless" caveat in the script's header.
