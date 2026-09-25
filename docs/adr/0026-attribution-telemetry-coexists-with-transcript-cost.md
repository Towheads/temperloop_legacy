---
title: "0026: per-seat attribution telemetry coexists with transcript-based cost measurement"
---

## Status

Proposed

## Context

epic: Towheads/temperloop#1225

ADR 0020 decided that cost measurement reads session transcripts: no new
telemetry stream is emitted and no model call site changes. That decision holds
for what it was made about — the *spend* number. But the model-comparison
harness (epic #1225) needs something transcripts structurally cannot provide
**for most seats**: attribution. A transcript records what a session spent by
model; for those seats — sweep worker, fix worker, triage, drive — it cannot
say which pipeline *seat* spent it, nor which *outcome* (which issue, which
merged PR) the spend produced. Whole-job cost per merged outcome — the
comparison report's primary metric — requires exactly that join. (Exactly one
seat class is the exception, and the transcript corpus *is* the only place it
survives; the Correction below states it, and qualifies both this paragraph
and the next.)

The naive fix, replacing the transcript producer with spawn-site emission, is
the alternative ADR 0020 explicitly rejected, and re-litigating it would
reopen the counting traps that decision documents (requestId dedup, cache-class
weighting). The naive alternative in the other direction — deriving attribution
from transcripts after the fact — fails because the transcript does not carry
the seat identity or the outcome ref; only the spawn site knows both at spawn
time.

**Correction (temperloop#1314).** Both claims above — this section's opening
"something transcripts structurally cannot provide", and the immediately
preceding "fails because the transcript does not carry the seat identity" —
are true for every seat class *except one*. Claude Code writes a
sidecar `agent-<id>.meta.json` beside each subagent journal, and for
**agent-frontmatter seats** (the `claude/agents/**` definitions: the
`/workshop` lens panel, the `/assess` and `/triage` review agents, `/build`
3e's reviewers, the persona agents) that sidecar's `agentType` field *is* the
seat name. Those seats are also the one class that can never emit a record of
its own, because the harness reads the agent `.md` at spawn and no kernel
code runs in that path. So the transcript corpus is the only place their
identity survives, and the emission-based stream is structurally unable to
reach them.

## Decision

Two producers, one owner per number. The transcript-based producer (ADR 0020)
remains the sole owner of the report's headline dollar/spend figure. A new
per-seat attribution stream — one record per spawned seat per run, carrying
seat name, model, provider, token counts, duration, and outcome ref — owns
seat and outcome attribution, and nothing else. The attribution stream
inherits ADR 0020's counting rules (requestId dedup, cache-class weighting)
rather than re-deriving them, so the two producers can never disagree about
how a token is counted; divergence between them is a defect with a declared
owner, not an ambiguity. Attribution records are schema-validated at content
level (model/provider enums, field shapes), paired with an emit-site validator
in the existing emit/validate family, and the stream is schema-versioned from
day one.

**Narrowing: the agent-frontmatter complement.** The transcript-based producer may derive
seat attribution for **agent-frontmatter seats only** — the class the
attribution stream structurally cannot reach — and only through a side
channel that is inert by default. Concretely: the corpus walk feeding the
headline is unchanged; a separate, opt-in, depth-pinned walk feeds one
additional output key whose totals are self-contained and are never a
decomposition of the headline. The two producers therefore remain disjoint
in domain as well as in number ownership: the emission stream owns
attribution for every seat that can emit, the transcript producer owns
attribution for the one class that cannot, and neither owns any figure the
other reports. This narrows the scope of "and nothing else" above; it does
not overturn the headline ownership that clause protects.

## Consequences

- Whole-job cost per merged outcome becomes computable: attribution records
  supply the seat/outcome join, the transcript producer supplies the money.
- Every current and future spawn site owes an emission; the paired validator
  turns a missing emission into a gate failure instead of a silently
  under-counted seat.
- ADR 0020's "no new telemetry stream" clause is narrowed, not overturned: no
  new stream competes for the *spend* number; the new stream exists only for
  attribution, which 0020's producer never claimed.
- The usage-capture path parses the `claude -p` CLI result, so a CLI format
  change breaks emission visibly (validator) rather than as silent zeros.
- Seat attribution has full coverage without a second stream competing for
  the spend figure: emitting seats via the attribution stream, non-emitting
  agent-frontmatter seats via the transcript producer's inert side channel.
- The disjointness is asserted mechanically, not by convention: a fixture
  proves the profiler's default `--format json` output is byte-identical
  with the side channel absent.
- **The shared weighting carries a same-tariff assumption, and it is checked
  rather than assumed** (temperloop#1742). The clause above — the attribution
  stream inherits ADR 0020's cache-class weighting so the two producers "can
  never disagree about how a token is counted" — buys that agreement with one
  `SPEND_WEIGHT_*` set shared by every surface. Those weights are *relative
  price multipliers read off a single vendor price sheet*, so any figure
  denominated in them assumes the spend it summarises was **billed under the
  same real-world tariff**. Within one vendor that holds, and in a comparison
  the weights cancel out of the delta. Across two vendors it does not: a
  different output:input ratio systematically mis-states one arm, and a token
  class a vendor does not have prices as 0 rather than as *unmapped*. The
  model-comparison producer therefore publishes a `cost_basis.cross_vendor`
  verdict on every run and declares its cost axis **unavailable, with a named
  reason**, rather than publishing a delta priced at one vendor's ratios.
  Per-arm weights in a common currency are deliberately not built: a second
  weight set would break the counting identity this ADR's "can never
  disagree" clause depends on. Nothing about this rides the attribution
  stream — the verdict is read off `candidate.provider` on the replay records
  by the transcript-side producer, which keeps ownership of the figure it
  qualifies.
