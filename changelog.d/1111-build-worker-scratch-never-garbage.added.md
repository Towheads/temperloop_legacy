- **Background-job scratch now has a retention policy** (#1111). `/build`
  worker scratch under the harness's job directory (`~/.claude/jobs/*/tmp/`)
  was never reclaimed: two finished job dirs accumulated 38.5GB of Xcode
  DerivedData trees and eval corpora — all of it regenerable — and took the
  root volume to 0 bytes free, hard enough that the harness's own Bash tool
  could not allocate a command's output file. `/tidy`'s § Environment hygiene
  step now classifies job scratch through the new
  `workflows/scripts/build/lib/job-scratch.sh`: a **terminal** job past its
  grace window with scratch over the size floor reports
  `JOB_SCRATCH_RECLAIMABLE` and is auto-healed in-lane by
  `workflows/scripts/build/job-scratch-reclaim.sh --apply` (which keeps the run
  record — `state.json`, `timeline.jsonl` — and deletes only `tmp/`), while a
  **non-terminal** job holding oversize scratch reports `JOB_SCRATCH_ABANDONED`
  and is left for a human, since a blocked job resumes once it is answered.
  The reclaimer is dry-run by default, re-verifies every target against the
  resolved job root before removing it, never follows a symlinked `tmp/`, and
  refuses `$HOME` or `/` as a sweep root.
