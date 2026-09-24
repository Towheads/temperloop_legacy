- **A /build turn can no longer end with in-flight work and no armed wake
  source** (#2210). The merge queue and CI are pull-only, so nothing ever
  notified the orchestrator that a PR merged — silence read exactly like
  "still queued", and the /build of epic #2065 stalled three times that way
  (~20 min, 12.5 h, and once more), every one caught by the operator asking
  rather than by a mechanism. Two structural fixes, not instructions:
  - New `workflows/scripts/build/wake-guard.sh`. `arm` makes the
    post-enqueue MERGED wait a **blocking, bounded, foreground** poll (it
    drives `gate.sh poll` under a kill-not-detach watchdog) — a turn cannot
    end in front of it, so a merge that lands after the orchestrator would
    otherwise have yielded is seen within one poll interval. `assert` is the
    refusal: open work with nothing scheduled exits non-zero. `bound` is the
    reusable watchdog — it runs a command in its own process group and
    **kills** at the bound rather than detaching, the way the `Bash` tool's
    own `timeout` parameter does (that detach is how a 500s-bounded command
    ran 12.5 h unbounded). The watchdog never asks the watched process for
    permission to fire: no `pgrep -f`, no liveness poll, just a pid and a
    sleep — and a HUP/INT/QUIT/TERM delivered to the guard reaps that group
    before exiting, so the signal door cannot detach the tree either.
  - `assert` is declared **mandatory** before any turn-end at /build 4b and
    ships its execution signal in the same change, per the kernel's
    § Mandatory-step birth rule: a registered row in
    `mandatory-step-registry.tsv` whose guard goes red if 4b ever stops
    invoking it.
  - `claude/workflows/build-level.mjs` now compiles that same
    kill-not-detach bound into the worker's own scoped-gate command, so a
    wedged `quality-gates.sh` is killed at the workflow's `#1071` step
    ceiling and its sentinel reports `{"state":"finished","rc":137,
    "outcome":"TIMEOUT","timedOut":true,…}` instead of sitting at
    `"running"` forever while the suite runs on unwatched.
  - Two new settings size the armed wake: `BUILD_WAKE_POLL_INTERVAL` (30 s)
    and `BUILD_WAKE_POLL_TIMEOUT` (540 s, one call's liveness bound — the
    merge-queue ceiling stays `BUILD_QUEUE_TIMEOUT`, whose sizing is open at
    #2055). That bound is a budget for the **whole PR set**, not a per-PR
    allowance: a level routinely selects several PRs, and a per-PR bound
    would let ordinary queue waits sum past the harness's foreground ceiling
    and get the armed call itself auto-backgrounded — the same defect through
    the new mechanism. A set that spends its budget returns `TIMEOUT` naming
    the first unfinished PR, and the caller chains another armed call.
