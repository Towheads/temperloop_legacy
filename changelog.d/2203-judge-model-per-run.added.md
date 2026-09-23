- **A dual-build run can now pick the model its pairwise judge runs on, for
  that run only** (#2203). `workflows/scripts/build/dual-build-preflight.sh`
  takes a new optional `--judge-model <id>` flag and carries the value on the
  `dualBuild` object it emits, which `claude/workflows/build-level.mjs` passes
  through to `workflows/scripts/model-comparison/judge.sh pairwise --model
  <id>`. Previously the judge always resolved
  `MODEL_COMPARISON_JUDGE_MODEL`, so varying the measuring instrument — to
  check whether a verdict depends on the judge as well as on the two arms —
  meant editing tracked config or a machine-local override that outlived the
  run and changed the default for everything else on the host. Omit the flag
  and nothing changes: the emitted judge command is byte-identical to before,
  and the consent prompt's spend line is unchanged. An empty value is refused
  rather than read as "no override".
