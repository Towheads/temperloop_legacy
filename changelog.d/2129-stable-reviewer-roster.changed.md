- **The `/build` driver's own emitted shell now gets a shell reviewer, and a
  repeat review round only re-runs the reviewers whose files actually moved**
  (temperloop#2129). `claude/workflows/build-level.mjs` builds the commands it
  runs — the quality-gate call, the push and pull-request steps, the CI poll,
  the review diff — as bash assembled inside JavaScript template strings and
  executed verbatim. Only its `.mjs` extension was routed, and it routed to the
  TypeScript reviewer, which correctly reads those commands as string literals
  and therefore never reads the shell inside them: quoting gaps, `set -e` blind
  spots and macOS-versus-Linux tool differences in that emitted text had no
  reviewer at all. A `**/build-level.mjs` row in
  `workflows/scripts/config/reviewer-routing.tsv` now puts the shell reviewer
  on that file alongside the TypeScript one from the first round, and the shell
  reviewer's own definition states the emitted-shell case and tells it to read
  the emitted commands rather than the JavaScript around them — the row alone
  would have handed a shell reviewer nine thousand lines of JavaScript with no
  instruction about what to look at.

  The second half bounds what that costs. A review round that follows an
  earlier one used to re-spawn every routed reviewer, so an item that looped
  its full round budget re-paid for a full review of files the round's fix
  could not have touched. Such a round now re-runs only the reviewers with at
  least one routed file changed since the commit the previous round reviewed;
  a reviewer with none is carried forward, and its block is still rendered in
  the pull request's review notes so a cold reader can tell a carried reviewer
  from one that was never routed. Three exemptions always re-run regardless:
  a mandatory reviewer, a reviewer routed by something other than a file (a
  per-item override, an architectural change kind), and the reviewer that
  raised the previous round's blocking finding — re-checking that fix is the
  whole reason the round exists, and the fix routinely lands in a file that
  reviewer is not routed for. A missing or unusable prior-round marker disarms
  the carry entirely, so the degradation direction is always more review,
  never less.
