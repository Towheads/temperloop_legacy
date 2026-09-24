- **An escalation that still holds resumable state now keeps its board claim
  HELD** (#2230). `build-level.mjs` stamps every escalation it returns with
  `claim_disposition` (`hold` | `release`) plus the `resumable_state` reading
  behind it, and `/build` 3d-esc step 1 disposes the board claim off that field.
  Previously a `level-pick` escalation released its items back to
  `fnd:status:ready` while still holding four worktrees of unlanded committed
  work, so the cross-session lock said "available" while the disk said
  otherwise — a peer `/sweep` or `/fix` could pull the same issue and create
  `build/<slug>` beside the held `build/<slug>@baseline`/`@candidate`, different
  branch names git refuses nothing about. The disposition is read off facts the
  escalation carries (`worktrees_intact[]`, `worktree_left_intact`,
  `committed_work`), never off its kind, so a future held-state escalation
  inherits the hold without being added to a list, and an escalation that holds
  nothing — the arm-failure path — releases exactly as before.
