- **A passing §3e.6 class-A activation gate is now recorded on the item's parked
  record, not just logged** (#1431). `build-level.mjs`'s `runActivationGate()`
  hands back a PASS record — `{ class, proof, absence_asserting, merge_base,
  exit_code }` — and `park()` stamps it as `activation`. A log line cannot be
  checked once the run is over, so until now "the gate ran" was unprovable from
  the item's own output; `merge_base` additionally names the sha the
  temperloop#944 control pass ran against, so an absence proof's control is
  provable rather than asserted. Present **only** for a `class: A` item that
  passed — an item with no `activation:` block, or `class: B`/`C`, carries no
  such key and its parked record is byte-identical to before. The guarantee
  spans **both** documented build paths: `build.md` §3e.6 now also states what
  the `--no-workflow` conversational path must stamp — an equivalent `activation:`
  sub-line on the item's `[m]` plan-note sentinel.
