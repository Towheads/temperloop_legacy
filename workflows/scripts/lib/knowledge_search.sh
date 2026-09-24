#!/usr/bin/env bash
#
# knowledge_search.sh — SOURCED library defining foundation's knowledge_search
# surface: concept-level (semantic/hybrid) retrieval over the knowledge_store's
# corpus (F#776, Epic A #762 "kernel split: seams in place — ZERO behavior
# change").
#
# Companion to knowledge_store.sh (same directory, document I/O). This file
# adds a SEARCH surface bound to the SAME corpus: ks_search's target is
# always ks_root (knowledge_store.sh) — there is NO independent search-corpus
# path setting. A search index that could point somewhere other than the
# document store would silently drift from it (split-brain guard).
#
# Backend selected by the Phase-0 spike verdict (foundation #776, completed
# 2026-07-02): basic-memory v0.22.1
# (https://github.com/basicmachines-co/basic-memory), run STRICTLY as an
# external CLI subprocess over argv/stdout — never imported or vendored,
# because basic-memory is AGPL-3.0 and this repo is not. See the "AGPL
# boundary" note below and workflows/scripts/lib/tests/test_knowledge_search_agpl_boundary.sh.
#
# See knowledge_store.contract.md's "## knowledge_search" section (appended
# after the existing document-I/O sections, which are owned by a sibling
# item — this file does not touch backend dispatch for ks_read/ks_write/
# ks_append/ks_list) for the full interface spec and the spike verdict's
# required adapter posture (numbered points 1-9), reproduced as inline
# comments next to the code that implements each one below.
#
# This file is SOURCED — it sets no shell options (the caller owns
# set -euo). Depends on: knowledge_store.sh (ks_root — source it first),
# jq (reshaping basic-memory's JSON into this file's JSONL output).
#
# ── Config settings ─────────────────────────────────────────────────────────
#   KNOWLEDGE_SEARCH_BACKEND     backend name, kebab-case. Default:
#                                basic-memory (the only backend this file
#                                implements; the plain-files knowledge_store
#                                backend has no search backend of its own —
#                                see "Obsidian-mode note" in the contract for
#                                how an obsidian-backend store still reaches
#                                this same basic-memory search backend, or
#                                stays on Obsidian's own search_vault_smart
#                                at the agent plane).
#   KNOWLEDGE_SEARCH_BM_HOME     isolated $HOME for the basic-memory
#                                subprocess (point 6: its own
#                                ~/.basic-memory/{config.json,memory.db}
#                                lives here — adapter-owned state, never
#                                Travis's real $HOME). Default:
#                                ${XDG_STATE_HOME:-$HOME/.local/state}/foundation/basic-memory-home
#   KNOWLEDGE_SEARCH_BM_PROJECT  the basic-memory project name bound to
#                                ks_root. Default: foundation-knowledge
#   KNOWLEDGE_SEARCH_BM_VERSION  pinned basic-memory version (point 5)
#                                INSTALLED as a uv tool
#                                (`uv tool install basic-memory==<version>`)
#                                and invoked through the installed entry
#                                point. Default: 0.22.1 (the spike-verdict
#                                pin — upgrades are a deliberate adapter
#                                change to this default, not silent drift;
#                                changing it RE-INSTALLS, it never keeps
#                                running the previously installed build —
#                                see _ks_bm_tool_ready below).
#   KNOWLEDGE_SEARCH_BM_INSTALL_TIMEOUT
#                                bound, in seconds, on that one-time
#                                `uv tool install` (temperloop#1113). Applied
#                                only when the caller has already sourced
#                                workflows/scripts/lib/portable-timeout.sh
#                                (probed with `command -v run_with_timeout`,
#                                never sourced from here — this library's
#                                dependency set stays knowledge_store.sh + jq).
#                                Unbounded install otherwise, exactly as
#                                before. Default: 900.
#   KNOWLEDGE_SEARCH_BM_INDEX_TIMEOUT
#                                bound, in seconds, on the one-time COLD-START
#                                INDEX a search runs immediately after it first
#                                registers the project (temperloop#1635 — see
#                                _ks_bm_initial_index below). Same
#                                portable-timeout.sh caveat as
#                                KNOWLEDGE_SEARCH_BM_INSTALL_TIMEOUT above:
#                                applied only when the caller already sourced
#                                that library, unbounded otherwise.
#                                Default: 900.
#   KNOWLEDGE_SEARCH_RERANK      1 = re-rank the backend's candidate set
#                                before returning (default); 0 = return the
#                                backend's own order untouched. See
#                                "## Post-fetch re-rank" below.
#   KNOWLEDGE_SEARCH_RERANK_DEPTH
#                                how many candidates to FETCH from the backend
#                                per query before re-ranking down to the
#                                caller's --limit. Default 20. Internal: the
#                                caller still receives exactly --limit results.
#   KNOWLEDGE_SEARCH_RERANK_LEX_WEIGHT
#                                relative weight of the lexical rank list
#                                against the backend's own rank list in the
#                                rank fusion. Default 1.0 (equal). 0 disables
#                                the lexical contribution without disabling
#                                the deeper fetch.
#   KNOWLEDGE_SEARCH_ABSTAIN     1 = abstain (return the same genuine
#                                zero-result shape a backend-empty query
#                                gets) when the FINAL, post-re-rank result set
#                                would otherwise be answered by a candidate
#                                that clears neither measured floor below; 0
#                                = never abstain via this lever (DEFAULT --
#                                opt-in; see CHANGELOG [Unreleased] and
#                                foundation#1450 for the measured floor this
#                                gates, and why it ships off by default).
#   KNOWLEDGE_SEARCH_ABSTAIN_SCORE_FLOOR
#                                floor on the TOP-RANKED (post-re-rank)
#                                candidate's own backend `.score`. Default
#                                0.72 -- measured on the 213-query
#                                engine-neutral golden-query bench against
#                                the SHIPPED hybrid+rerank surface (see "##
#                                Abstention floor" below).
#   KNOWLEDGE_SEARCH_ABSTAIN_LEX_FLOOR
#                                floor on that same top-ranked candidate's
#                                lexical-coverage feature (the re-rank's own
#                                title/path term-agreement score, `L` below).
#                                Default 0.10. BOTH floors must fail (AND, not
#                                OR) for the candidate to abstain -- neither
#                                alone measurably separates.
#   KNOWLEDGE_SEARCH_PARTITION   project/partition SCOPE for every ks_search
#                                call (temperloop#418). EMPTY by default =
#                                unpartitioned: the whole corpus, byte-identical
#                                to the pre-#418 surface. When non-empty, a
#                                result is returned ONLY if its doc_id proves
#                                membership in that partition (see
#                                "## Project partition" below). Overridable
#                                per call by `ks_search --partition <name>`.
#                                FAILS CLOSED by construction: enforced in
#                                ks_search itself, never delegated to a
#                                backend that might not honour it.
#   KNOWLEDGE_SEARCH_BM_PYTHON   pinned CPython version passed to
#                                `uv tool install --python <version>`
#                                (point 5's companion pin, and part of the
#                                installed-pin identity — changing it
#                                re-installs). The bm version pin alone
#                                still let uv resolve whatever interpreter
#                                the host offered; a host that resolved
#                                3.14 hit a from-source maturin/PyO3 build
#                                of litellm (a bm dep with no cp314 wheel)
#                                that fails, surfacing as an opaque
#                                registration failure (temperloop#368,
#                                foundation#1176). Default: 3.13 (newest
#                                CPython with prebuilt wheels for the full
#                                0.22.1 dependency closure — bump together
#                                with KNOWLEDGE_SEARCH_BM_VERSION, never
#                                silently).
#
# NOT a corpus-root setting: ks_search always targets ks_root (knowledge_store.sh)
# — there is no KNOWLEDGE_SEARCH_ROOT or equivalent.

# ── Public interface ────────────────────────────────────────────────────
# ks_search <query> [--limit N] [--partition <name>]
#                                 -> ranked results, JSON Lines on stdout:
#                                    one {"doc_id","title","score","snippet"}
#                                    object per line, already ranked by the
#                                    backend (highest relevance first).
#                                    An UNRECOGNISED argument is rejected with
#                                    exit 2 before any backend call
#                                    (temperloop#418) — never silently
#                                    discarded, because a discarded SCOPE
#                                    argument would return the full unfiltered
#                                    corpus to a caller that believes it asked
#                                    for a scoped search.
# ks_search_partition_supported   -> exit 0 iff THIS copy of the library
#                                    implements the --partition scope. A
#                                    caller that depends on scoping probes
#                                    `command -v ks_search_partition_supported`
#                                    before calling: on a pre-#418 library the
#                                    function does not exist at all, which is
#                                    the only reliable way to tell a kernel
#                                    that HONOURS the scope from one that
#                                    silently ignores it.
# ks_search_reindex [--full] [--search] [--embeddings]
#                                 -> rebuilds the search backend's index for
#                                    ks_root's corpus. Never runs as a
#                                    background watcher (point 3) — this is
#                                    always an explicit, one-shot call (a
#                                    post-pull hook / cron entry point).
#                                    Flags are forwarded to the backend CLI by
#                                    name (temperloop#888): `--full --search`
#                                    is the full filesystem rescan + FTS
#                                    rebuild WITHOUT the forced full re-embed
#                                    (61s vs. 587s for bare `--full` on a
#                                    977-note store), so a drift-healing
#                                    caller no longer has to reach into the
#                                    private `_ks_bm_run`. An UNRECOGNISED
#                                    argument is rejected with exit 2, never
#                                    silently discarded.
# ks_search_available [--quiet]   -> exit 0 if the selected backend's
#                                    required tooling is present OR could be
#                                    made present, exit 3 otherwise. Lets a
#                                    caller probe before calling ks_search if
#                                    it wants to avoid the stderr notice.
#                                    NOT a pure predicate since temperloop#1113:
#                                    on the basic-memory backend this gate
#                                    LAZILY INSTALLS the pinned tool when it
#                                    is absent (the hybrid install design —
#                                    see _ks_search_backend_basic_memory_
#                                    available below), so a stranger who never
#                                    ran `doctor` still gets a working first
#                                    ks_search. `--quiet` suppresses only the
#                                    "skipped —" degradation notice (used by
#                                    ks_search's own internal probe so the
#                                    notice isn't printed twice); install
#                                    progress still reaches stderr.
#
# Exit codes (both ks_search and ks_search_reindex):
#   0 — success. For ks_search, this includes a legitimate ZERO-result
#       match — an empty JSONL stream on stdout with exit 0 is a real "no
#       matches", never confused with "backend unavailable". On a backend
#       zero-result, ks_search first attempts a ripgrep lexical fallback over
#       the corpus (foundation#950); a fallback hit is emitted in the same
#       JSONL contract with a score of 0 (marking a lexical, not semantic,
#       match) and a one-line stderr notice. Still exit 0 when the fallback
#       also finds nothing (or rg is absent) — a genuine no-match.
#   2 — invalid usage (empty query, an unrecognised ks_search or
#       ks_search_reindex flag, a --limit/--partition with no value, an EMPTY
#       --partition value, dispatch to an unregistered backend).
#   3 — backend unavailable ("skipped"): the backend's required subprocess
#       tooling could not be made present — `uv` is not on PATH, or the
#       one-time `uv tool install` of the pinned basic-memory failed
#       (temperloop#1113). A message beginning
#       "skipped — knowledge_search unavailable" is printed to stderr;
#       NOTHING is ever printed to stdout in this case — legible
#       degradation, never a silent empty result.
#   4 — backend error: the subprocess ran but exited non-zero, or its
#       output could not be parsed as the expected JSON shape.
# Epoch milliseconds, for the read-log OUTCOME field `wall_ms` (foundation#1449).
# Mirrors gh-call-logger.sh's `_now_ms` idiom exactly (same fallback, same
# rationale): prefer perl's Time::HiRes (ms resolution, perl ships on macOS +
# CI); degrade to whole-second precision (×1000) if perl is unavailable —
# coarse but never fatal, and never a reason a search call fails.
_ks_now_ms() {
  local ms
  if ms="$(/usr/bin/perl -MTime::HiRes=time -e 'printf "%d", time()*1000' 2>/dev/null)" \
     && [ -n "$ms" ]; then
    printf '%s' "$ms"
  else
    printf '%s000' "$(date +%s 2>/dev/null || echo 0)"
  fi
}

ks_search() {
  local query="${1:-}"
  if [ -z "$query" ]; then
    echo "knowledge_search: usage: ks_search <query> [--limit N] [--partition <name>]" >&2
    return 2
  fi
  shift || true

  # ── Argument parsing: an ALLOWLIST that fails closed (temperloop#418) ──
  # This loop used to live only in the backends, each ending in `*) shift ;;`
  # — an unknown flag was silently discarded and the call proceeded. That is
  # tolerable for a typo'd tuning flag; it is NOT tolerable for a SCOPE flag,
  # because a discarded `--partition` returns the FULL, UNFILTERED corpus to a
  # caller that believes it asked for a scoped search — the exact confidential
  # cross-project bleed the partition exists to prevent, delivered silently
  # under a flag that looked like it worked. So ks_search parses its own
  # arguments strictly here, at the public seam, and rejects anything it does
  # not recognise with exit 2 before making any backend call at all. Same
  # shape as ks_search_reindex's allowlist (temperloop#888).
  local limit=10 partition="${KNOWLEDGE_SEARCH_PARTITION:-}"
  while [ $# -gt 0 ]; do
    case "$1" in
      --limit)
        if [ $# -lt 2 ]; then
          echo "knowledge_search: ks_search: --limit requires a value" >&2
          return 2
        fi
        limit="$2"; shift 2 ;;
      --partition)
        # An EMPTY value is rejected rather than read as "no partition": a
        # caller whose `--partition "$CLIENT"` expanded to nothing must get a
        # loud error, never a silent widening back to the whole corpus.
        if [ $# -lt 2 ] || [ -z "$2" ]; then
          echo "knowledge_search: ks_search: --partition requires a non-empty value" >&2
          return 2
        fi
        partition="$2"; shift 2 ;;
      *)
        printf 'knowledge_search: ks_search: unrecognised argument "%s" (accepted: --limit, --partition)\n' "$1" >&2
        return 2
        ;;
    esac
  done

  # Read-log telemetry (temperloop#229, OUTCOME fields added by
  # foundation#1449 — see knowledge_store.sh's ks__read_log_emit header for
  # the full field contract): this is "the search entrypoint" the
  # knowledge_store.sh read-log contract names. Emission is deferred to AFTER
  # the dispatch below (outcome fields — result count, top score,
  # rg-fallback, mode, wall-time — are only known once the call completes),
  # gated the same way the pre-#1449 code gated its pre-dispatch emit: on the
  # backend's availability probe (the same "available" op ks_search_available
  # exposes publicly) — an unavailable backend never really searches, so it
  # shouldn't log a search attempt either.
  #
  # `--quiet` (temperloop#1113), not a blanket `2>/dev/null`. The suppression
  # here has ever only had ONE job: stop the "skipped —" notice being printed
  # twice (once by this probe, once by the real dispatch below). Since #1113
  # the gate can also do a one-time `uv tool install`, whose progress is the
  # only thing telling an operator why their first ks_search is taking
  # minutes — swallowing ALL of the probe's stderr would make that first run
  # silently hang-looking. So the notice is suppressed by name and everything
  # else passes through.
  local do_log=0
  ks_search__dispatch available --quiet >/dev/null && do_log=1

  # Dispatch to the backend, capturing stdout so a legitimate ZERO-result
  # (exit 0, empty stream) can trigger a ripgrep fallback over the corpus
  # (foundation#950). A backend error (exit 4) or unavailable backend (exit 3)
  # is NOT masked — its legible-degradation contract (stderr notice, exit code)
  # is preserved: only the exit-0-empty case falls back. Result sets are bounded
  # by --limit, so buffering the happy path in a var is cheap. Timed for the
  # wall_ms outcome field — this measures the BACKEND DISPATCH only (not any
  # rg-fallback below), which is the number worth watching for regression.
  local out rc=0 t0 t1 wall_ms
  t0="$(_ks_now_ms)"
  # Arguments are NORMALIZED here — the backend receives exactly the flags it
  # implements, never the caller's raw argv. `--partition` in particular is
  # CONSUMED at this seam and never forwarded: enforcement must not depend on a
  # backend choosing to honour it (a backend that ignored it would fail OPEN).
  out="$(ks_search__dispatch search "$query" --limit "$limit")" || rc=$?
  t1="$(_ks_now_ms)"
  wall_ms=$(( t1 - t0 ))
  [ "$wall_ms" -ge 0 ] 2>/dev/null || wall_ms=0   # guard against clock skew / fallback rounding

  # Abstention floor (foundation#1450): _ks_bm_rerank emits this ONE sentinel
  # line in place of the normal JSONL stream when every candidate failed the
  # measured floor (KNOWLEDGE_SEARCH_ABSTAIN=1). Detected and consumed HERE,
  # not inside the rerank, because only ks_search knows whether the rg
  # fallback below is allowed to run: the ratified L1 semantics (clause 4)
  # say the fallback stays suppressed whenever the backend returned a
  # non-empty candidate set, and a floor-triggered abstention is exactly
  # that — a POST-re-rank empty, never a backend-empty. So this is checked
  # BEFORE the backend-empty branch below, and clears $out to the genuine
  # empty-result shape without ever letting the sentinel itself leak past
  # this function.
  local abstained=0
  if [ "$rc" -eq 0 ] && [ "$out" = '{"__ks_abstain":true}' ]; then
    abstained=1
    out=""
  fi

  # Backend returned a genuine zero-result. A query class the semantic/hybrid
  # backend ranked to nothing may still have a literal match — try ripgrep so
  # the answer is degraded-but-answered rather than silently empty (foundation#950).
  # Only on a clean rc=0 empty result — a dispatch ERROR (rc 3/4) below is NOT
  # masked by a fallback attempt, exactly as the pre-#1449 code never masked it.
  # A floor-triggered abstention (abstained=1) is NOT a backend-empty (the
  # backend returned candidates; the floor discarded them) so it must NOT
  # fall into this branch either — guarded by `abstained` staying 0 here.
  #
  # NOTE the ordering below: `backend_empty` is captured from the BACKEND's own
  # result, BEFORE the partition filter runs, so the fallback's trigger
  # condition is bit-for-bit what it was pre-#418. A set the partition filter
  # empties is a POST-filter empty (like an abstention), not a backend-empty,
  # and must not newly summon a subprocess the pre-#418 surface never ran.
  local backend_empty=0
  [ -z "$out" ] && backend_empty=1

  # ── Partition scope enforcement (temperloop#418) ──────────────────────────
  # Applied HERE, at the public seam, to EVERY result stream a caller can
  # receive: the backend's own results (below) and the rg lexical fallback's
  # (further down). One enforcement point, so no backend and no degraded path
  # can route around it. A filter error is FAIL-CLOSED — exit 4 with nothing on
  # stdout, never the unfiltered set.
  if [ -n "$partition" ] && [ "$rc" -eq 0 ] && [ -n "$out" ]; then
    out="$(printf '%s\n' "$out" | ks_search__partition_filter "$partition")" || {
      echo "knowledge_search: partition filter failed; refusing to return unscoped results" >&2
      return 4
    }
  fi

  local rg_fired=0
  if [ "$abstained" -eq 0 ] && [ "$rc" -eq 0 ] && [ "$backend_empty" -eq 1 ]; then
    out="$(ks_search__rg_fallback "$query" --limit "$limit")"
    if [ -n "$partition" ] && [ -n "$out" ]; then
      out="$(printf '%s\n' "$out" | ks_search__partition_filter "$partition")" || {
        echo "knowledge_search: partition filter failed; refusing to return unscoped results" >&2
        return 4
      }
    fi
    [ -n "$out" ] && rg_fired=1
  fi

  # Log the OUTCOME regardless of success/error — matching the pre-#1449
  # gate's count semantics exactly (it logged once per available-gated call,
  # independent of what the dispatch below returned): an errored dispatch is
  # itself a countable outcome (a real backend failure on a real query), not
  # something to drop from the tally just because it has no result set.
  if [ "$do_log" -eq 1 ]; then
    local result_count top_score mode
    if [ "$rc" -ne 0 ]; then
      # Dispatch errored (3=unavailable mid-flight, 4=backend error) — no
      # result set to describe; name the failure in `mode` instead of
      # guessing a result shape.
      result_count="-"
      top_score="-"
      mode="error:${rc}"
    elif [ -n "$out" ]; then
      result_count="$(printf '%s\n' "$out" | grep -c '^' 2>/dev/null)" || result_count=0
      top_score="$(printf '%s\n' "$out" | head -n1 | jq -r '.score // "-"' 2>/dev/null)" || top_score="-"
      [ -n "$top_score" ] || top_score="-"
    else
      result_count=0
      top_score="-"
    fi
    if [ "$rc" -eq 0 ]; then
      if [ "$rg_fired" -eq 1 ]; then
        # The score:0 lexical fallback answered the query — this OVERRIDES
        # the hybrid/rerank labels below: the caller received a lexical, not
        # a semantic, match (see _ks_bm_rerank's trap 2 on this sentinel).
        mode="rg-fallback"
      else
        # "hybrid" is the only retrieval mode this adapter implements (both
        # backends pin --hybrid / search_type:"hybrid"); "+rerank" reflects
        # whether the post-fetch re-rank (temperloop#1446) actually ran for
        # this query — outcome fields record the POST-re-rank result, so
        # this names what the caller actually received, not just the
        # configured default.
        mode="hybrid"
        [ "${KNOWLEDGE_SEARCH_RERANK:-1}" = "1" ] && mode="hybrid+rerank"
      fi
    fi
    # abstained: "1" when the KNOWLEDGE_SEARCH_ABSTAIN floor fired for this
    # query (foundation#1450), "0" otherwise — the live misfire monitor for
    # the feature (rationale: knowledge_store.sh's ks__read_log_emit header).
    ks__read_log_emit script search "$query" \
      "$result_count" "$top_score" "$abstained" "$rg_fired" "$mode" "$wall_ms"
  fi

  if [ "$rc" -ne 0 ]; then
    return "$rc"
  fi
  [ -n "$out" ] && printf '%s\n' "$out"
  return 0
}

# ── Project partition (temperloop#418) ────────────────────────────────────
# THE cross-project confidentiality seam. `ks_search`'s corpus is the whole
# resolved `ks_root` (see the corpus-binding note at the top of this file), and
# the store's only isolation between projects is the `<project> - <title>.md`
# FILENAME CONVENTION — which search, until this, did not respect. For an
# operator running one `$HOME` across several engagements that is structural,
# not incidental: a query typed during client B's session could rank and return
# client A's confidential notes.
#
# The scope is a SEARCH-LAYER FILTER, not a store-layer partition. That is a
# deliberate scope choice, stated plainly rather than half-built: a true
# multi-tenant store partition would have to reach `ks_read`/`ks_write`/
# `ks_list`/`ks_sync`, the backend matrix, and the doc-id normalizer — a
# store-layer redesign. The filter closes the bleed this issue is actually
# about (search surfacing another project's notes) at one enforcement point,
# and `knowledge_store.contract.md` § Project partition names exactly what it
# does and does not cover.
#
# ── Membership: proven by the doc_id, never assumed ───────────────────────
# A result belongs to partition `<p>` iff its `doc_id` satisfies EITHER:
#   * filename convention — its BASENAME starts with `<p> - `
#     (`Decisions/acme - retainer terms.md` is in partition `acme`); this is
#     the convention the store already uses and the one the issue names.
#   * directory convention — the doc_id starts with `<p>/`
#     (`acme/Decisions/retainer terms.md`), for a store organised by
#     top-level project directory instead.
# Matching is EXACT and case-sensitive; there is no fuzzy or prefix-ish match,
# because a near-miss here is a confidentiality failure, not a ranking miss.
#
# ── Unpartitioned notes are EXCLUDED, on purpose ──────────────────────────
# A note matching neither form (`Index.md`, `Sessions/2026-08-04.md`) is NOT
# returned by a scoped search. This is the fail-closed reading: an
# unconventioned note is one whose ownership the store cannot prove, and a
# confidentiality filter must not return what it cannot attribute. The cost is
# real and is documented for the operator (scoped search hides generic notes
# too) — the alternative, a "shared/unpartitioned notes are always visible"
# opt-out, is exactly the fail-open lever this seam exists to not have.
#
# <partition> ; JSONL on stdin -> the subset on stdout. Returns non-zero
# (leaving stdout EMPTY) if the filter itself could not run — the caller turns
# that into exit 4 rather than falling back to the unfiltered stream.
ks_search__partition_filter() {
  local partition="$1" filtered rc=0
  filtered="$(jq -c --arg p "$partition" '
      select((.doc_id | type) == "string")
      | select((.doc_id | split("/") | last | startswith($p + " - "))
               or (.doc_id | startswith($p + "/")))
    ' 2>/dev/null)" || rc=$?
  # A legitimately EMPTY result (nothing in this partition matched) is jq exit
  # 0 with empty stdout — a real "no matches in scope", handled by the caller
  # exactly like any other zero-result. Only a genuine jq failure (absent
  # binary, unparseable stream) lands here.
  if [ "$rc" -ne 0 ]; then
    return "$rc"
  fi
  [ -n "$filtered" ] && printf '%s\n' "$filtered"
  return 0
}

# Capability probe for the partition scope (temperloop#418). Exists purely so a
# caller can tell a library that HONOURS `--partition` from one that does not:
# on a pre-#418 copy of this file the function is simply not defined, so
# `command -v ks_search_partition_supported >/dev/null` is a reliable,
# zero-subprocess version-skew check. A scope-dependent caller MUST probe —
# passing `--partition` to a library that predates it is the one remaining way
# to get unscoped results back while believing you asked for scoped ones, and
# no amount of care inside THIS file can close that for a caller running an
# older one.
ks_search_partition_supported() { return 0; }

# Ripgrep lexical fallback over the knowledge_store corpus (foundation#950).
# Fires ONLY when the selected backend returns a legitimate zero-result — a
# fixed-string, case-insensitive rg over the corpus's `*.md` files, reshaped
# into the SAME {doc_id,title,score,snippet} JSONL contract the backend emits so
# a consumer can't tell the two apart (score is a 0 sentinel marking a lexical
# fallback hit vs. the backend's real relevance float). rg's defaults already
# skip hidden dirs (the vault's `.smart-env` embedding store, `.obsidian`), so
# this never bulk-greps them. Fail-open and SILENT on the common no-match path:
# no rg on PATH, no corpus root, or no literal match leaves the empty result
# untouched (a genuine no-match is not an error); only an actual fallback hit
# prints results AND a one-line stderr notice, so ordinary no-match queries add
# no noise. Depends on: ks_root (knowledge_store.sh), rg, jq.
ks_search__rg_fallback() {
  local query="$1"; shift
  local limit=10
  # Allowlist, not a silent discard (temperloop#418): every arg loop this file
  # owns now rejects what it does not recognise, so no path can quietly drop a
  # flag a caller believed was applied. ks_search normalizes its argv before
  # calling here, so in production this loop only ever sees `--limit N`.
  while [ $# -gt 0 ]; do
    case "$1" in
      --limit) limit="${2:-10}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
      *)
        printf 'knowledge_search: ks_search__rg_fallback: unrecognised argument "%s" (accepted: --limit)\n' "$1" >&2
        return 2
        ;;
    esac
  done
  command -v rg >/dev/null 2>&1 || return 0     # no rg → the empty result stands
  local root; root="$(ks_root 2>/dev/null)" || return 0
  [ -n "$root" ] && [ -d "$root" ] || return 0
  local hits
  hits="$( ( cd "$root" 2>/dev/null || exit 0
             rg --json -i -F -m1 -g '*.md' -e "$query" -- . 2>/dev/null ) \
    | jq -c 'select(.type=="match")
             | {doc_id: (.data.path.text | ltrimstr("./")),
                title:  (.data.path.text | split("/") | last | rtrimstr(".md")),
                score:  0,
                snippet:(.data.lines.text | rtrimstr("\n"))}' 2>/dev/null \
    | head -n "$limit" )" || true
  # `|| true`: this lib is SOURCED into scripts that own `set -euo pipefail`, and
  # the pipeline exits non-zero on the two fail-open cases — rg exits 1 on the
  # common NO-MATCH path, and `head` closing the pipe early on a many-hit result
  # SIGPIPEs jq (141) under pipefail. Neither is an error here, so the assignment
  # must not be allowed to trip the caller's set -e (foundation#950 shell-review).
  [ -n "$hits" ] || return 0                     # rg found nothing → genuine no-match
  echo "knowledge_search: backend returned no matches; surfacing ripgrep lexical fallback (score=0) over the corpus (foundation#950)" >&2
  printf '%s\n' "$hits"
}

ks_search_reindex() {
  ks_search__dispatch reindex "$@"
}

ks_search_available() {
  ks_search__dispatch available "$@"
}

# ── Backend dispatch (mirrors knowledge_store.sh's ks__dispatch shape) ────
: "${KNOWLEDGE_SEARCH_BACKEND:=basic-memory}"
# Standing partition scope (temperloop#418). EMPTY = unpartitioned, the
# pre-#418 whole-corpus behaviour, byte-for-byte. Set it once per engagement
# (an env export, a per-project config) and every ks_search in that session is
# scoped; `ks_search --partition <name>` overrides it per call.
: "${KNOWLEDGE_SEARCH_PARTITION:=}"

ks_search__backend_fn() {
  local op="$1" backend="${KNOWLEDGE_SEARCH_BACKEND//-/_}"
  printf '_ks_search_backend_%s_%s\n' "$backend" "$op"
}

ks_search__dispatch() {
  local op="$1"; shift
  local fn; fn="$(ks_search__backend_fn "$op")"
  if ! command -v "$fn" >/dev/null 2>&1; then
    printf 'knowledge_search: backend "%s" does not implement "%s" (no %s defined)\n' \
      "$KNOWLEDGE_SEARCH_BACKEND" "$op" "$fn" >&2
    return 2
  fi
  "$fn" "$@"
}

# ── basic-memory backend ──────────────────────────────────────────────────
# Every function below either assembles the posture (config/env) or shells
# out to the pinned basic-memory CLI, INSTALLED as a uv tool and invoked
# through its own installed entry point (temperloop#1113 — see
# _ks_bm_ensure_tool below for why this replaced the per-run `uvx --from
# basic-memory==<version>` resolution). Nothing here imports or vendors any
# basic-memory source — the ONLY way this file talks to basic-memory is as a
# subprocess (points 4 and 5). Confirmed against the real 0.22.1 CLI (network-available
# adapter-authoring session, 2026-07-02): `project add` is idempotent
# (prints "already exists" and exits 0 on a repeat call), a config.json
# holding ONLY the override keys below is merged with the tool's own
# pydantic defaults (no need to restate the full schema), and
# `tool search-notes --hybrid` prints clean JSON on stdout with all
# progress/model-download chatter on stderr.

: "${KNOWLEDGE_SEARCH_BM_PROJECT:=foundation-knowledge}"
: "${KNOWLEDGE_SEARCH_BM_VERSION:=0.22.1}"
: "${KNOWLEDGE_SEARCH_BM_PYTHON:=3.13}"
: "${KNOWLEDGE_SEARCH_BM_INSTALL_TIMEOUT:=900}"
: "${KNOWLEDGE_SEARCH_BM_INDEX_TIMEOUT:=900}"
# Overlay seam (foundation#946): extra `.bmignore` patterns appended to the
# generic upstream base set that _ks_bm_ensure_ignore writes — space- or
# newline-separated BARE segment names. EMPTY by default, so a stranger's install
# excludes only basic-memory's own defaults; an overlay sets this to add
# store-specific exclusions (foundation sets `_inbox` to prune its transient
# Sessions/_inbox drain-queue stubs). Each MUST be a single bare segment (see the
# _ks_bm_ensure_ignore header for why a slash-containing pattern never matches).
: "${KNOWLEDGE_SEARCH_BM_EXTRA_IGNORES:=}"

# point 6: dedicated HOME for the bm subprocess, under XDG_STATE_HOME.
_ks_bm_home() {
  : "${KNOWLEDGE_SEARCH_BM_HOME:=${XDG_STATE_HOME:-$HOME/.local/state}/foundation/basic-memory-home}"
  printf '%s\n' "$KNOWLEDGE_SEARCH_BM_HOME"
}

_ks_bm_config_dir()  { printf '%s/.basic-memory\n' "$(_ks_bm_home)"; }
_ks_bm_config_path() { printf '%s/config.json\n' "$(_ks_bm_config_dir)"; }
# .bmignore lives at basic-memory's OWN resolve_data_dir() (== our isolated config
# dir, since HOME is pinned there — point 6), never inside ks_root / the corpus
# itself. Safe to write even when ks_root is a read-only corpus (foundation#946
# production shadow-read on a live Obsidian vault).
_ks_bm_ignore_path() { printf '%s/.bmignore\n' "$(_ks_bm_config_dir)"; }
# point 6 (cont'd): semantic_embedding_cache_dir pinned inside the isolated
# home, not the machine's shared HF/fastembed cache.
_ks_bm_cache_dir()   { printf '%s/embedding-cache\n' "$(_ks_bm_home)"; }

# ── point 5, rewritten: the pin is INSTALLED, not resolved per run (#1113) ──
# This adapter used to reach basic-memory as `uvx --from
# basic-memory==<pin> basic-memory ...` — zero setup, but with NO PERMANENT
# INSTALL LOCATION. uv resolves the package, unpacks a ready-to-run
# environment into its own cache (`archive-v0`), and executes OUT OF THAT
# CACHE. Every distinct resolution (a new pin, a new interpreter, a changed
# dependency set) adds another environment and nothing ever expires them:
# measured at 30 GB on a host that had been running this path for months,
# against a knowledge store of 273 MB, with the root volume at 0 bytes free.
#
# Two properties made it worse than ordinary cache growth, and BOTH are
# closed by installing instead of resolving:
#   * The isolated HOME (point 6) forks a SECOND cache — uv locates its cache
#     relative to HOME, so the adapter's own pinned home grows a cache tree
#     independent of the operator's.
#   * The cache CANNOT BE PRUNED while a long-running search process is up:
#     uvx holds the cache lock for that process's whole lifetime, so
#     `uv cache prune` fails with "Cache is currently in-use" for as long as
#     the warm basic-memory-mcp daemon (knowledge_search_mcp.sh) is serving —
#     and because the cache IS the live environment, clearing it by hand
#     would delete the running interpreter out from under that daemon. With a
#     persistent daemon the reclaim window never naturally arrives.
# An INSTALLED uv tool puts a stable virtualenv (with its own managed
# interpreter) under _ks_bm_tool_dir instead, so uv's cache holds no live
# environment, holds no lock, and stays prunable at any time — including
# while the daemon is serving.
#
# Everything the tool install writes stays adapter-owned, under the same
# isolated home point 6 already established: UV_TOOL_DIR (the virtualenvs),
# UV_TOOL_BIN_DIR (the entry-point shims), and HOME (uv's own cache +
# managed-interpreter dirs) are ALL pinned there. Nothing lands in the
# operator's `~/.local/{share,bin}`, and the invocation below never resolves
# `basic-memory` through PATH — so a system-wide basic-memory install can
# neither be picked up by accident nor shadowed by ours.
_ks_bm_tool_dir()     { printf '%s/uv-tools\n' "$(_ks_bm_home)"; }
_ks_bm_tool_bin_dir() { printf '%s/uv-tool-bin\n' "$(_ks_bm_home)"; }
_ks_bm_bin_path()     { printf '%s/basic-memory\n' "$(_ks_bm_tool_bin_dir)"; }

# THE PIN-CHANGE GUARD, and the sharpest regression risk of the switch. Under
# uvx the pin was re-asserted on EVERY invocation, so bumping
# KNOWLEDGE_SEARCH_BM_VERSION took effect on the next call for free. An
# installed tool has no such property: it would happily keep serving the
# previously installed build forever while the adapter's own pin said
# otherwise — silent drift of exactly the kind point 5's `auto_update: false`
# posture exists to make deliberate rather than invisible.
#
# So the installed pin's IDENTITY is recorded on disk next to the shim and
# compared on every call. The identity is BOTH pins (version + interpreter),
# because both are arguments to the install and either changing means the
# installed environment no longer matches what this file asks for. A stamp
# that disagrees — or is missing, as it is on a tree installed by an older
# copy of this adapter — is treated exactly like "not installed": re-install,
# then re-stamp.
_ks_bm_pin_stamp_path() { printf '%s/.ks-installed-pin\n' "$(_ks_bm_tool_bin_dir)"; }
_ks_bm_pin_id() {
  printf 'basic-memory==%s python=%s\n' \
    "$KNOWLEDGE_SEARCH_BM_VERSION" "$KNOWLEDGE_SEARCH_BM_PYTHON"
}

# Cheap, zero-subprocess readiness probe: an executable entry point AND a pin
# stamp that matches the pins THIS process is configured with. Kept cheap on
# purpose — it runs on every ks_search (twice: the read-log probe and the
# backend's own gate), so it must never cost more than a couple of stats.
_ks_bm_tool_ready() {
  local bm_bin stamp
  bm_bin="$(_ks_bm_bin_path)"
  stamp="$(_ks_bm_pin_stamp_path)"
  [ -x "$bm_bin" ] || return 1
  [ -f "$stamp" ] || return 1
  [ "$(cat "$stamp" 2>/dev/null)" = "$(_ks_bm_pin_id)" ] || return 1
  return 0
}

# Installs (or RE-installs, on a pin change) the pinned tool. `--force` is
# unconditional rather than conditional-on-drift: this function is only
# reached when _ks_bm_tool_ready already said the on-disk state does NOT
# match the configured pins, and `uv tool install` without it can decline to
# replace an existing installation — precisely the silent-old-version failure
# the stamp exists to catch.
#
# PER-PROCESS FAILURE MEMO. A failed install must not be retried on every
# subsequent gate call: ks_search alone runs the gate twice per query, and a
# minutes-long network failure repeated per call would turn one degraded
# search into an unbounded stall. The memo is process-local private state
# (never a setting), so a fresh process retries — a transient network outage
# self-heals on the next invocation without anyone clearing anything.
#
# The bound on the install is applied ONLY when the caller has already
# sourced portable-timeout.sh; this library refuses to grow a second
# dependency for it (it cannot resolve its own directory portably — it is
# sourced under zsh as well as bash, where BASH_SOURCE does not exist). Every
# env override goes through `env` rather than a `VAR=v func` prefix, because
# a variable assignment prefixed onto a *shell function* call persists into
# the calling shell in some bash modes — and clobbering the caller's HOME
# would be a spectacular way to fail.
_ks_bm_install_tool() {
  local out rc=0 bm_bin
  [ "${_KS_BM_INSTALL_FAILED:-0}" = "1" ] && return 1
  if ! command -v uv >/dev/null 2>&1; then
    _KS_BM_INSTALL_FAILED=1
    return 127
  fi
  mkdir -p "$(_ks_bm_home)" "$(_ks_bm_tool_dir)" "$(_ks_bm_tool_bin_dir)" || {
    _KS_BM_INSTALL_FAILED=1
    return 1
  }
  printf 'knowledge_search: installing %s as a uv tool under %s (one-time; a cold install downloads an interpreter and can take minutes)\n' \
    "$(_ks_bm_pin_id)" "$(_ks_bm_tool_dir)" >&2
  local -a install_cmd
  # HOME= alone does NOT isolate uv: it resolves its cache as UV_CACHE_DIR ->
  # $XDG_CACHE_HOME/uv -> HOME-relative, and its managed interpreters as
  # UV_PYTHON_INSTALL_DIR -> $XDG_DATA_HOME/uv/python -> HOME-relative. An
  # exported XDG_CACHE_HOME/XDG_DATA_HOME (routine on Linux and CI, and this
  # repo leans on XDG_STATE_HOME heavily) therefore WINS over the HOME
  # override and the downloaded CPython lands in the operator's shared tree.
  # Both are pinned explicitly so every byte uv writes stays under our home.
  install_cmd=(env
    "HOME=$(_ks_bm_home)"
    "UV_TOOL_DIR=$(_ks_bm_tool_dir)"
    "UV_TOOL_BIN_DIR=$(_ks_bm_tool_bin_dir)"
    "UV_CACHE_DIR=$(_ks_bm_home)/uv-cache"
    "UV_PYTHON_INSTALL_DIR=$(_ks_bm_home)/uv-python"
    uv tool install --force
      --python "$KNOWLEDGE_SEARCH_BM_PYTHON"
      "basic-memory==${KNOWLEDGE_SEARCH_BM_VERSION}")
  # `command -v`, NOT `declare -F`: under zsh `declare` is `typeset` and its
  # `-F` flag means "float with N digits", so `declare -F run_with_timeout`
  # SUCCEEDS unconditionally (declaring a float of that name) and this branch
  # would always be taken — then die with "command not found". This library is
  # sourced under zsh (temperloop#40), so the probe has to be one both shells
  # answer the same way. `command -v` finds shell functions in both.
  if command -v run_with_timeout >/dev/null 2>&1; then
    out="$(run_with_timeout "${KNOWLEDGE_SEARCH_BM_INSTALL_TIMEOUT}" "${install_cmd[@]}" 2>&1)" || rc=$?
  else
    out="$("${install_cmd[@]}" 2>&1)" || rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    printf '%s\n' "$out" | tail -n 15 >&2
    _KS_BM_INSTALL_FAILED=1
    return "$rc"
  fi
  bm_bin="$(_ks_bm_bin_path)"
  if [ ! -x "$bm_bin" ]; then
    printf 'knowledge_search: uv tool install reported success but no entry point exists at %s\n' "$bm_bin" >&2
    _KS_BM_INSTALL_FAILED=1
    return 1
  fi
  # Write-then-rename, never truncate-in-place: the pipeline fans out worker
  # processes sharing one KNOWLEDGE_SEARCH_BM_HOME, and _ks_bm_tool_ready
  # cat's this stamp on EVERY ks_search. A concurrent reader landing in a
  # truncate window would read an empty stamp, conclude "not installed", and
  # fire a redundant `uv tool install --force` that replaces the entry point
  # under a sibling about to exec it. rename(2) is atomic within a directory,
  # so a reader sees either the old stamp or the new one, never a partial.
  local stamp stamp_tmp
  stamp="$(_ks_bm_pin_stamp_path)"
  stamp_tmp="${stamp}.tmp.$$"
  if ! { _ks_bm_pin_id > "$stamp_tmp" && mv -f "$stamp_tmp" "$stamp"; }; then
    rm -f "$stamp_tmp"
    _KS_BM_INSTALL_FAILED=1
    return 1
  fi
  return 0
}

# The idempotent front door: ready -> no-op; otherwise install/re-pin.
_ks_bm_ensure_tool() {
  _ks_bm_tool_ready && return 0
  _ks_bm_install_tool
}

# point 7: THE embedding-model pin — the single site where the model name is
# authored. Nothing else in this file may spell a model name; the config
# writer and the dimensions derivation below both read it from here.
_ks_bm_embedding_model() { printf 'bge-small-en-v1.5\n'; }

# point 7 (cont'd, temperloop#907): the model's vector dimensionality is
# DERIVED from the pin above, never authored independently. basic-memory
# writes `semantic_embedding_dimensions` into the vector column definition;
# a config that names a model but leaves the dimensions at a mismatched
# value silently produces a zero-embedding index — the index builds, every
# search returns nothing, and no error is raised anywhere. Deriving the
# number from the model name is what makes that unrepresentable: a future
# model flip edits ONE literal (_ks_bm_embedding_model) and this table
# re-derives the matching width, or fails loudly if the new model is not in
# it. Adding a model here means adding its width in the same edit — that
# coupling IS the guard. Widths are the published dimensionality of each
# bge-*-en-v1.5 checkpoint.
_ks_bm_embedding_dimensions() {
  local model
  model="${1:-$(_ks_bm_embedding_model)}"
  case "$model" in
    bge-small-en-v1.5) printf '384\n' ;;
    bge-base-en-v1.5)  printf '768\n' ;;
    bge-large-en-v1.5) printf '1024\n' ;;
    *)
      printf 'ks_search: no embedding dimensions known for model "%s" — add its width to _ks_bm_embedding_dimensions (temperloop#907)\n' \
        "$model" >&2
      return 1
      ;;
  esac
}

# point 1, rewritten for the installed-tool default (temperloop#1113): the
# gate is now "the pinned tool is installed at the configured pins, OR can be
# installed right now". This IS the dispatch target for the public
# "available" op (ks_search_available calls this directly, by the
# `_ks_search_backend_<name>_<op>` naming convention) — exit 0 when ready,
# exit 3 with the "skipped —" stderr notice when not, so a caller gets the
# same legible-degradation signal whether it probes explicitly via
# ks_search_available or hits it implicitly via ks_search/ks_search_reindex.
#
# ── The gate LAZILY INSTALLS — the second half of the ratified hybrid ──────
# Moving off `uvx` traded away the one virtue that made it the default: a
# stranger with nothing but `uv` on PATH got a working first ks_search with
# no setup step at all. `workflows/scripts/install/doctor.sh` installs and
# reports the pin, which covers an INSTALLED checkout — but a stranger who
# never runs doctor would otherwise hit a permanent "skipped —" with no hint
# that one command fixes it, a silent-skip hole where zero-setup used to be.
# So the gate self-heals: absent tool + `uv` on PATH -> install it here, then
# report available. doctor's half makes the state PREDICTABLE and pre-warmed;
# this half makes it REACHABLE without doctor. Both, deliberately.
#
# What this gate is NOT, by default: a pure predicate. The public op's
# contract has always been "can this backend answer a search", and since the
# answer is now "yes, after a one-time install", performing that install is
# what makes the answer true rather than merely optimistic.
#
# `--probe` is the ZERO-SIDE-EFFECT arm, and it is public on purpose. Making
# the default arm side-effecting silently repurposed every existing caller
# that used this as a cheap predicate — most sharply the hermetic gate at
# scripts/tests/test_stranger_config.sh, which runs under KERNEL_GATES in a
# fresh sandbox where the tool is never ready, and which therefore started
# firing a real network install from inside a test whose own assertion reads
# "never a network call" (kernel principle 3). A private `_ks_bm_tool_ready`
# was not enough: an out-of-file caller cannot reach a private accessor, so
# the only sweepable fix is a public flag. `--probe` answers "is it ready
# RIGHT NOW" — exit 0 ready, exit 3 not — and never installs, never writes.
#
# `--quiet` suppresses the "skipped —" notice ONLY (ks_search's internal
# read-log probe passes it so the notice isn't printed twice). Install
# progress and uv's own failure output are never suppressed by it: they are
# the only thing distinguishing a first run that is working from one that has
# hung. An unrecognised flag is rejected (exit 2) rather than shifted away,
# matching every other argument loop this file owns (temperloop#418).
#
# SC2120: this function IS called with an argument — but only through the
# dispatch indirection (`ks_search__dispatch available --quiet`, resolved by
# name at runtime) and from the warm backend's delegation in
# knowledge_search_mcp.sh, neither of which shellcheck can follow.
# shellcheck disable=SC2120
_ks_search_backend_basic_memory_available() {
  local quiet=0 probe=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --quiet) quiet=1; shift ;;
      --probe) probe=1; shift ;;
      *)
        printf 'knowledge_search: basic-memory available: unrecognised argument "%s" (accepted: --quiet, --probe)\n' "$1" >&2
        return 2
        ;;
    esac
  done

  _ks_bm_tool_ready && return 0

  # --probe stops here: report not-ready, install nothing, write nothing.
  if [ "$probe" -eq 1 ]; then
    [ "$quiet" -eq 1 ] || echo "skipped — knowledge_search unavailable: the pinned basic-memory tool is not installed (probe only; run 'make doctor' or any ks_search to install it)" >&2
    return 3
  fi

  if ! command -v uv >/dev/null 2>&1; then
    [ "$quiet" -eq 1 ] || echo "skipped — knowledge_search unavailable: uv not found on PATH (needed to install the pinned basic-memory tool)" >&2
    return 3
  fi

  _ks_bm_install_tool && return 0
  [ "$quiet" -eq 1 ] || printf 'skipped — knowledge_search unavailable: could not install %s as a uv tool\n' \
    "$(_ks_bm_pin_id)" >&2
  return 3
}

# Writes .bmignore BEFORE the first index (like config.json below) and only if
# absent. Carries basic-memory's OWN upstream default ignore set (ignore_utils.py
# DEFAULT_IGNORE_PATTERNS / create_default_bmignore(), reproduced verbatim so a
# version bump can't silently change what's excluded out from under us), plus any
# store-specific patterns from KNOWLEDGE_SEARCH_BM_EXTRA_IGNORES (the overlay seam,
# empty by default). Lives at _ks_bm_config_dir() — basic-memory's OWN
# resolve_data_dir() under our pinned HOME, never inside ks_root, so it never
# touches the corpus (safe even on a read-only corpus / production shadow-read).
#
# EXTRA-IGNORE patterns MUST each be a single BARE segment name (e.g. `_inbox`, not
# `Sessions/_inbox`): upstream's recursive scan (sync_service.py scan_directory)
# re-bases should_ignore_path on each subdirectory as it descends, so a
# slash-containing pattern never matches below the top level (verified live on
# 0.22.1 — both slash forms indexed the target; the bare-segment form prunes the
# dir the same way the `.obsidian` default does).
# NOTE: no local named `path` here — see the zsh PATH-tie note below (temperloop#40).
_ks_bm_ensure_ignore() {
  local ignore_path pat
  ignore_path="$(_ks_bm_ignore_path)"
  [ -f "$ignore_path" ] && return 0
  mkdir -p "$(_ks_bm_config_dir)" || return 1
  cat > "$ignore_path" <<'BMIGNORE'
# Basic Memory Ignore Patterns (knowledge_search adapter)
# Base set mirrors basic-memory's own upstream default (ignore_utils.py
# DEFAULT_IGNORE_PATTERNS), pinned here rather than left to fall through to
# the library default so a version bump can't silently change it.
.*
*.db
*.db-shm
*.db-wal
config.json
.git
.svn
__pycache__
*.pyc
*.pyo
*.pyd
.pytest_cache
.coverage
*.egg-info
.tox
.mypy_cache
.ruff_cache
.venv
venv
env
.env
node_modules
build
dist
.cache
.idea
.vscode
.DS_Store
Thumbs.db
desktop.ini
.obsidian
*.tmp
*.swp
*.swo
*~
BMIGNORE
  # Append overlay-supplied store-specific patterns (space/newline-separated).
  # Empty by default — a stranger's install carries only the upstream base above.
  if [ -n "${KNOWLEDGE_SEARCH_BM_EXTRA_IGNORES:-}" ]; then
    printf '\n# Store-specific additions (KNOWLEDGE_SEARCH_BM_EXTRA_IGNORES)\n' >> "$ignore_path"
    # Intentional word-splitting on the space/newline-separated pattern list.
    # shellcheck disable=SC2086
    for pat in $KNOWLEDGE_SEARCH_BM_EXTRA_IGNORES; do
      printf '%s\n' "$pat" >> "$ignore_path"
    done
  fi
}

# ── Posture VERIFY-AND-REPAIR on an EXISTING config.json (foundation#1211) ──
# _ks_bm_ensure_config used to be write-if-absent: it early-returned on
# `[ -f "$cfg_path" ]`, so an existing config.json was TRUSTED to still carry
# the no-mutation posture the adapter wrote. That trust does not hold in the
# field. A live host was found carrying basic-memory's OWN defaults in that
# file — sync_changes: true, ensure_frontmatter_on_sync: true, auto_update:
# true, semantic_embedding_cache_dir: null — i.e. precisely the vault-MUTATION
# class the posture exists to prevent, silently re-enabled. bm rewrites this
# file itself (`project add` and friends persist through it), so
# "adapter-owned state dir" is a claim about intent, never a guarantee about
# bytes. The adapter therefore VERIFIES the posture keys on every call now and
# repairs the ones that drifted, instead of assuming presence implies posture.
#
# Three properties this is built around:
#
#  * MERGE, NEVER REGENERATE. The `projects` map and `default_project` are
#    adapter-UNOWNED state written by bm's own CLI (point 9: registration is
#    CLI-only, config-only edits are not honored). Rewriting the file from the
#    absent-config template below would DEREGISTER every live project. So the
#    repair is a key-wise merge onto the parsed document: the posture keys are
#    set, and every other key — bm's bookkeeping included — passes through.
#  * MODEL AND DIMENSIONS MOVE AS A PAIR, never half-updated — the same
#    temperloop#907 coupling the absent-config writer has. Both are resolved by
#    the caller BEFORE either write path runs, so an unknown model fails the
#    whole call rather than repairing a config into a mismatched width (which
#    silently yields a zero-embedding index: the index builds, every search
#    returns nothing, and no error is raised anywhere).
#  * IDEMPOTENT BY COMPARISON, not by assumption. The repaired document is
#    compared against the on-disk one in canonical (sorted, compact) form, and
#    the file is left COMPLETELY untouched — same bytes, same mtime — when
#    nothing drifted. A config already carrying the posture is therefore never
#    reformatted, and a second consecutive call is a provable no-op.
#
# Best-effort by design: a missing jq, or a config.json that is not a JSON
# OBJECT — unparseable, empty, truncated, or a valid non-object like `[]` —
# WARNS on stderr and leaves the file alone (the pre-#1211 behavior for an
# existing file) rather than failing the search outright — but it never passes
# silently, so an unverified posture is visible rather than assumed.
# NOTE: no local named `path`/`cdpath`/`fpath`/`mailpath` here either — see the
# zsh PATH-tie note on _ks_bm_ensure_config below (temperloop#40).
_ks_bm_repair_config() {
  local cfg_path="$1" cache="$2" model="$3" dims="$4"
  local on_disk repaired tmp_path
  if ! command -v jq >/dev/null 2>&1; then
    printf 'knowledge_search: jq not found — the basic-memory no-mutation posture in %s is UNVERIFIED\n' \
      "$cfg_path" >&2
    return 0
  fi
  # The guard must reject THREE shapes, not just unparseable bytes: `jq . ` on an
  # EMPTY or whitespace-only file exits 0 with empty output, and a valid-but-
  # non-object document (`[]`, `"str"`, a bare number) parses fine here and then
  # fails the merge below with jq's own "Cannot index array" — turning a
  # recoverable config problem into exit 4 for every search. Both collapse into
  # one test: demand a JSON OBJECT and treat an empty capture as the failure
  # signal, so all three take the warn-and-leave-alone path together. An empty
  # config is the worst case of the drift #1211 exists to close — bm falls back
  # to ITS defaults (sync_changes/ensure_frontmatter_on_sync true, the
  # vault-mutation posture) — so it must never report as verified.
  on_disk="$(jq -S -c 'if type == "object" then . else error("not an object") end' "$cfg_path" 2>/dev/null)" || on_disk=""
  if [ -z "$on_disk" ]; then
    printf 'knowledge_search: %s is not a JSON object (empty, truncated, or not valid JSON) — leaving it untouched; the basic-memory no-mutation posture is UNVERIFIED\n' \
      "$cfg_path" >&2
    return 0
  fi
  # Every key here maps a posture point enumerated on _ks_bm_ensure_config
  # below; the two sets must stay in lockstep (the tests assert that).
  repaired="$(jq --arg model "$model" --argjson dims "$dims" --arg cache "$cache" '
      .disable_permalinks            = true
    | .ensure_frontmatter_on_sync    = false
    | .format_on_save                = false
    | .update_permalinks_on_move     = false
    | .kebab_filenames               = false
    | .sync_changes                  = false
    | .auto_update                   = false
    | .semantic_embedding_model      = $model
    | .semantic_embedding_dimensions = $dims
    | .semantic_embedding_cache_dir  = $cache
  ' "$cfg_path")" || return 1
  [ "$(printf '%s\n' "$repaired" | jq -S -c .)" = "$on_disk" ] && return 0
  # Write via a temp file + rename so a crash mid-write can never leave a
  # truncated config behind (bm reads this file on every invocation).
  # SEED THE TEMP FILE FROM THE ORIGINAL so the replacement inherits its mode:
  # `printf > new-file` would take the umask default, silently widening a 0600
  # config to 0644 on every repair. `cp` is the portable way to carry the mode
  # across — `chmod --reference` is GNU-only and `stat -c` vs `stat -f %Lp` is
  # exactly the BSD/GNU split the tool-invocation rule warns about.
  # A signal landing between this write and the `mv` orphans the temp file; that
  # is ACCEPTED rather than trapped. A sourced lib cannot install an EXIT trap
  # without stomping its caller's, and reaping `"$cfg_path".ks-repair.*` on entry
  # would race a concurrent repair in another process — deleting ITS temp file
  # mid-write and turning that call into the search outage this guard avoids.
  tmp_path="$cfg_path.ks-repair.$$"
  cp "$cfg_path" "$tmp_path" || { rm -f "$tmp_path"; return 1; }
  printf '%s\n' "$repaired" > "$tmp_path" || { rm -f "$tmp_path"; return 1; }
  mv -f "$tmp_path" "$cfg_path" || { rm -f "$tmp_path"; return 1; }
  printf 'knowledge_search: repaired drifted no-mutation posture keys in %s (foundation#1211)\n' \
    "$cfg_path" >&2
  return 0
}

# Writes config.json BEFORE the first index (point 2) when absent, and VERIFIES
# + REPAIRS the posture keys on an existing one (foundation#1211 — see
# _ks_bm_repair_config above for why presence is no longer trusted as posture).
# Maps every spike-verdict posture point:
#   point 1 — disable_permalinks: true            (+ env var, see _ks_bm_run)
#   point 2 — ensure_frontmatter_on_sync: false, format_on_save: false,
#             update_permalinks_on_move: false, kebab_filenames: false
#   point 3 — sync_changes: false (the watcher is never enabled)
#   point 5 — auto_update: false (upgrades are a deliberate version-pin bump)
#   point 6 — semantic_embedding_cache_dir pinned inside the isolated home
#   point 7 — semantic_embedding_model: bge-small-en-v1.5 (the default —
#             pinned explicitly here so it can never drift to a non-bge
#             model and reintroduce upstream #1023's normalization bug),
#             PLUS the semantic_embedding_dimensions that model requires.
#             Both come from _ks_bm_embedding_model / _ks_bm_embedding_
#             dimensions — one pin, one derivation — so the pair can never
#             be written half-updated (temperloop#907; a mismatched width
#             yields a silent zero-embedding index).
# NOTE: no local here (or anywhere in this file) may be named `path`, `cdpath`,
# `fpath`, or `mailpath`. Under zsh those identifiers are tied to the colon-array
# side of the corresponding uppercase env var (`path` <-> `PATH`), so a
# `local path=…` in a *sourced* function silently rebinds `PATH` for that scope —
# and since these libs are sourced (not executed) and then shell out to
# PATH-resolved tooling (`uv` and `env` in the install gate; `jq`, `rg` and
# friends downstream), a clobbered `PATH` makes those unresolvable and the
# search fails. bash treats `path` as an ordinary variable, so this is invisible under
# bash and under CI. Use `cfg_path`/`proj_path`/`doc_path` instead. (temperloop#40)
_ks_bm_ensure_config() {
  local dir cfg_path cache model dims
  dir="$(_ks_bm_config_dir)"
  cfg_path="$(_ks_bm_config_path)"
  cache="$(_ks_bm_cache_dir)"
  # Ensure .bmignore first — BEFORE the config-exists early return, so a store
  # whose config.json already exists (from a prior run) still gets its ignore
  # file written (foundation#946). Both are "write only if absent", so this is
  # idempotent and independent of config.json's presence.
  _ks_bm_ensure_ignore || return 1
  # point 7: model and dimensions resolved as a PAIR from the single pin, and
  # BEFORE either write path runs. The old code got this ordering for free by
  # sitting after a write-if-absent early return; now that an EXISTING config
  # is repaired rather than trusted, the guarantee has to be stated up front to
  # still hold on that path: a model with no known width fails the whole call
  # here, rather than writing — or repairing into — a config whose mismatched
  # width would index every note to a zero vector.
  model="$(_ks_bm_embedding_model)"
  dims="$(_ks_bm_embedding_dimensions "$model")" || return 1
  mkdir -p "$dir" "$cache" || return 1
  # Existing config: VERIFY the posture and repair only what drifted. Never
  # regenerate from the template below — that would deregister bm's
  # CLI-registered `projects` map (point 9).
  if [ -f "$cfg_path" ]; then
    _ks_bm_repair_config "$cfg_path" "$cache" "$model" "$dims" || return 1
    return 0
  fi
  cat > "$cfg_path" <<JSON
{
  "disable_permalinks": true,
  "ensure_frontmatter_on_sync": false,
  "format_on_save": false,
  "update_permalinks_on_move": false,
  "kebab_filenames": false,
  "sync_changes": false,
  "auto_update": false,
  "semantic_embedding_model": "$model",
  "semantic_embedding_dimensions": $dims,
  "semantic_embedding_cache_dir": "$cache"
}
JSON
}

# Runs the pinned basic-memory CLI as a subprocess (points 4 and 5): isolated
# HOME (point 6) + the belt-and-suspenders env var (point 1, on top of the
# config.json key of the same name) + the version pin (point 5) + the
# interpreter pin (KNOWLEDGE_SEARCH_BM_PYTHON — without it uv resolves the
# host's newest CPython, and a resolution onto a version some bm dependency
# ships no wheel for triggers a from-source native build that can fail; the
# temperloop#368 / foundation#1176 failure mode). Both pins are asserted at
# INSTALL time now (temperloop#1113) rather than re-passed per invocation,
# and _ks_bm_tool_ready re-checks them on every call so a pin change
# re-installs instead of silently continuing to run the old build.
#
# This is the ONLY place in this file that invokes the basic-memory binary,
# and it does so by ABSOLUTE PATH into the adapter's own tool-bin dir — never
# a bare `basic-memory` that PATH could resolve to an unpinned/system
# install, and NEVER the `mcp` subcommand (point 4 — sidesteps upstream
# #1017).
#
# The readiness check here is a GUARD, not the install seam: every public
# entry point runs the availability gate (which installs) first, so reaching
# _ks_bm_run with no entry point means a caller bypassed that gate. Failing
# loudly with 127 beats installing from a helper whose callers expect a bm
# invocation to be all that happens.
#
# OPTIONALLY BOUNDED (temperloop#1635). `_ks_bm_run_bounded <secs> …` is the
# real body; `_ks_bm_run …` is the unbounded façade every existing caller
# keeps using unchanged. The bound exists for ONE caller — the cold-start
# index below, which runs INSIDE a search call, where an unbounded subprocess
# would turn "my first search is slow" into "my first search never returns".
# Kept as one function rather than two invocation sites so the posture (the
# isolated HOME, the belt-and-suspenders env var, the absolute entry-point
# path) still has exactly one author — the property
# test_knowledge_search_agpl_boundary.sh check 3 is built on.
#
# The argv is assembled through `env` rather than a `VAR=v cmd` prefix for the
# same reason _ks_bm_install_tool does: run_with_timeout's `timeout` backend
# execs an external command, and a variable-assignment prefix is not part of
# an argv. Semantics are identical (`env` sets exactly these two variables for
# exactly this child), and the unbounded path goes through the same array, so
# there is one command shape, not two.
_ks_bm_run_bounded() {
  local secs="$1"; shift
  local bm_bin
  bm_bin="$(_ks_bm_bin_path)"
  if [ ! -x "$bm_bin" ]; then
    printf 'knowledge_search: pinned basic-memory tool is not installed at %s (availability gate bypassed?)\n' \
      "$bm_bin" >&2
    return 127
  fi
  local -a bm_cmd
  bm_cmd=(env
    "HOME=$(_ks_bm_home)"
    BASIC_MEMORY_DISABLE_PERMALINKS=true
    "$bm_bin" "$@")
  # `command -v`, not `declare -F` — see the zsh note in _ks_bm_install_tool.
  if [ -n "$secs" ] && command -v run_with_timeout >/dev/null 2>&1; then
    run_with_timeout "$secs" "${bm_cmd[@]}"
  else
    "${bm_cmd[@]}"
  fi
}

_ks_bm_run() {
  _ks_bm_run_bounded "" "$@"
}

# ── THE COLD-START INDEX (temperloop#1635) ────────────────────────────────
# Registering a project does NOT index it. `basic-memory project add` writes
# the registration and returns; nothing scans the corpus. So on a genuinely
# clean host — the stranger first-run path #1113's lazy install was built to
# preserve — the chain used to end one step short: install the pin, register
# the project, search an EMPTY index, and return zero results with exit 0.
# Legible degradation reported nothing, because nothing had failed; the
# stranger simply got "no matches" for every query, forever, until something
# else happened to call ks_search_reindex. Measured live in a clean Debian
# container on 2026-08-19 (docs/validation/clean-host-ks-search.md): first
# search, three-note corpus, zero results — the install worked perfectly and
# the search still could not answer.
#
# This closes it at the one place that knows a cold start just happened: the
# search path's project-not-found miss branch, immediately after the
# registration it already performs. That branch fires on first use and on a
# post-`basic-memory reset` DB drop — both are exactly "the index is empty" —
# and never on a warm query, so this costs nothing per search (the warm path
# does not even call `project add`, per foundation#996).
#
# BEST-EFFORT, NEVER FATAL. A failed index warns on stderr and falls through
# to the retry: the retry may still be answerable (another process may have
# indexed the same store), and a zero-result search that then hits the
# ripgrep lexical fallback is a better outcome than exit 4. What it must
# never be is SILENT — a silent index failure is the same invisible-empty
# state this function exists to remove.
_ks_bm_initial_index() {
  local project="$1" out rc=0
  printf 'knowledge_search: first use of project "%s" — indexing the corpus once (a large store can take minutes)\n' \
    "$project" >&2
  out="$(_ks_bm_run_bounded "$KNOWLEDGE_SEARCH_BM_INDEX_TIMEOUT" reindex --project "$project" 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'knowledge_search: the one-time cold-start index failed (exit %s) — searches will return no matches until ks_search_reindex succeeds\n' \
      "$rc" >&2
    printf '%s\n' "$out" | tail -n 15 >&2
    return "$rc"
  fi
  return 0
}

# point 9: project registration via the CLI only — config-only edits to the
# `projects` map are not honored in 0.22.1. `project add` is idempotent
# (confirmed against the real CLI), so it is safe to call whenever registration
# is needed without a separate "is it already registered" check. Since #996 the
# SEARCH path no longer calls this per query — it registers LAZILY only on a
# project-not-found miss (the ~1.9s re-register was ~45% of search latency,
# F#992); reindex still calls it up front. Idempotency is what makes the
# lazy-on-miss retry safe (first use AND the post-`reset` DB-dropped path).
# On failure the subprocess's own output is surfaced (bounded to its tail)
# instead of swallowed: an opaque "registration failed" with no cause left
# three separate field failures undiagnosable until someone re-ran the
# subprocess by hand (temperloop#368 / foundation#1176 — the actual cause
# was a uvx dependency build, invisible from the adapter's message alone).
_ks_bm_project_add() {
  local name="$1" proj_path="$2" out rc=0   # NOT `path` — see the zsh PATH-tie note above (temperloop#40)
  out="$(_ks_bm_run project add "$name" "$proj_path" 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s\n' "$out" | tail -n 15 >&2
    return "$rc"
  fi
  return 0
}

# ── Post-fetch re-rank (temperloop#1446, epic foundation#1443) ────────────
# THE ranking lever, per the keystone mode-sweep verdict ([[Decisions/foundation
# - mode-sweep verdict (retrieval-mode architecture)]], foundation#1445). That
# sweep measured, on a 768d substrate over 204 labeled queries, that hybrid's
# hit@20 is 0.9461 against a hit@5 of 0.8676 while MRR stays flat across the
# same 4x depth increase: the right document is almost always ALREADY in the
# candidate set the backend returns, just not in the top 5. Depth buys
# coverage, not ranking. So the lever is not a different retrieval mode (every
# alternative — a better single default, intent routing, multi-mode fusion —
# was measured and rejected there); it is to FETCH DEEPER and re-order.
#
# Deliberately THIN: no cross-encoder, no model download, no new dependency —
# jq only, the idiom this file already speaks. Features are computed from the
# candidate's own {doc_id,title} against the query.
#
# ── The three traps this implementation is built around ───────────────────
#  1. SCORES ARE QUERY-RELATIVE, NEVER CORPUS-ABSOLUTE. basic-memory's hybrid
#     fuses as max(v,f) + 0.3*min(v,f) AFTER normalising the lexical half by the
#     maximum within that query's OWN result set (observed range 0.5702-1.2845,
#     exceeding 1.0). A global score threshold is therefore not well-founded and
#     cross-candidate score arithmetic is invalid. So this re-ranker NEVER reads
#     .score: it fuses two RANK lists (reciprocal-rank fusion), which is
#     scale-free by construction.
#  2. THE score:0 rg-FALLBACK SENTINEL MUST NEVER BE REORDERED. score 0 is a
#     PROVENANCE MARKER (a ripgrep lexical hit surfaced when the backend found
#     nothing), not a relevance value — and because lexical modes emit NEGATIVE
#     scores while hybrid emits ~[0.57,1.28], a raw 0 sorts above everything in
#     one context and below everything in another. Structurally, fallback hits
#     can never reach this function (ks_search runs the fallback only AFTER the
#     backend returned an empty set, downstream of every call site here); the
#     explicit sentinel guard below is belt-and-suspenders on top of that
#     separation, and it degrades to identity rather than guessing.
#  3. THE CANDIDATE SET INHERITS HYBRID'S TIE-JITTER (~3.7% of top-5 lists
#     reorder between identical runs). Every ordering step below breaks ties on
#     the backend's own rank, so the re-rank adds no instability of its own.
#
# Contract: this changes the ORDER of results and which k survive. It NEVER
# changes the record shape — each surviving candidate object is passed through
# byte-for-byte as the reshape stage emitted it (the {doc_id,title,score,snippet}
# JSONL contract and the exit-code contract are frozen surfaces).
#
# <query> <k> : reads reshaped JSONL candidates (backend rank order) on stdin,
#               writes the re-ranked top-<k> as JSONL on stdout.
: "${KNOWLEDGE_SEARCH_RERANK:=1}"
: "${KNOWLEDGE_SEARCH_RERANK_DEPTH:=20}"
: "${KNOWLEDGE_SEARCH_RERANK_LEX_WEIGHT:=1.0}"

# ── Abstention floor (foundation#1450, epic foundation#1443) ──────────────
# Below a MEASURED floor on the shipped hybrid+rerank surface, return the
# adapter's existing genuine-zero-result shape instead of confident-looking
# hits on a query the store cannot actually answer.
#
# ── WHY NOT RAW `.score` ALONE, AND WHY NOT THE FUSION SCORE ALONE ────────
# The two obvious single-surface floors were measured and REJECTED:
#  * Raw backend `.score` is query-relative (trap 1 above) -- on the 213-query
#    engine-neutral bench, the 9 correct-abstention queries' top-ranked
#    candidate scored 0.65-0.76, which sits INSIDE genuine hits' own range
#    (0.58-1.28, median 0.79). A floor tight enough to catch most abstention
#    cases drops 30%+ of genuine top-5 hits.
#  * The fusion score `.f` this file computes is RRF-based and dominated by
#    RANK, not relevance: the top-ranked candidate's semantic term alone is a
#    near-constant 1/(rrfk+0) on EVERY query, answerable or not, so `.f`
#    alone carries almost no separating signal (measured: overlaps entirely).
# What DOES separate, measured on that same corpus (two independent runs,
# byte-identical results -- the fused candidate order is deterministic, only
# TIE-BREAKING among near-equal ranks jitters): the CONJUNCTION of the
# top-ranked candidate's raw score AND its own lexical-coverage feature `L`
# (query-term agreement with that candidate's title/path, already computed
# below for the fusion). Neither alone separates; requiring BOTH to be low
# does, because a genuine hit is either a strong semantic match (high score)
# or a strong lexical match (high L) almost without exception in this corpus.
# Measured result at the shipped defaults (0.72 / 0.10): 4/9 correct
# abstentions gained, 0/186 labeled top-5 hits lost -- see CHANGELOG.
#
# ── SMALL-n CAVEAT ─────────────────────────────────────────────────────────
# The corpus carries exactly 9 correct-abstention examples -- the only ones
# that exist -- so these floors are CALIBRATED to, not validated against a
# held-out set of, unanswerable queries. The zero-measured-cost claim (186/186
# preserved, confirmed on two independent runs) is the load-bearing safety
# property; the 4/9 recall figure is a directional floor, not a guarantee for
# novel unanswerable queries. Ships opt-in (KNOWLEDGE_SEARCH_ABSTAIN=0 default)
# pending broader live validation.
#
# ── SCOPE: the main fusion branch only ────────────────────────────────────
# The floor applies ONLY where this function actually computes `L`/`.f` --
# the real-query fusion branch below. It does NOT reach the score-0 sentinel
# bypass (trap 2 -- a fallback set is never a candidate for abstention
# scoring, it already IS the degraded-answer path), the empty-candidate-set
# bypass, or the no-usable-query-terms bypass (no lexical feature exists to
# gate on there); those three edge paths are unchanged.
#
# Signaling: when every candidate fails the gate, this function emits ONE
# sentinel line, `{"__ks_abstain":true}`, in place of the normal JSONL
# stream. ks_search (knowledge_search.sh) is the ONE place that consumes it --
# it converts the sentinel to the genuine empty-result shape, sets the
# `abstained` outcome field, and (per the ratified L1 mode-sweep semantics,
# clause 4) suppresses the score-0 rg lexical fallback, because the backend
# itself returned a non-empty candidate set: an abstention here is a
# POST-re-rank empty, never a backend-empty, and the fallback fires only on
# the latter. The sentinel never reaches a real caller.
: "${KNOWLEDGE_SEARCH_ABSTAIN:=0}"
: "${KNOWLEDGE_SEARCH_ABSTAIN_SCORE_FLOOR:=0.72}"
: "${KNOWLEDGE_SEARCH_ABSTAIN_LEX_FLOOR:=0.10}"

_ks_bm_rerank() {
  local query="$1" k="$2"
  # Disabled -> exact pre-#1446 behavior: the backend's own order, untouched.
  # (The fetch depth also collapses to --limit at the call sites, so "off" is a
  # true no-op, not a truncated deep fetch.)
  if [ "${KNOWLEDGE_SEARCH_RERANK:-1}" != "1" ]; then
    cat
    return 0
  fi
  # Feature weights are deliberately NOT settings: they are ordering constants
  # of the lexical feature, selected on the #1443 bench corpus, and exposing
  # five knobs would be mechanism where one balance knob
  # (KNOWLEDGE_SEARCH_RERANK_LEX_WEIGHT) suffices.
  #   w_title  1.0  query-term coverage of the candidate's TITLE
  #   w_path   0.4  coverage of its full doc_id PATH (directory segments are
  #                 weaker evidence than the title — "Decisions/" matches the
  #                 word "decision" in a way that means nothing)
  #   w_phrase 1.0  bonus when the normalised query appears VERBATIM inside the
  #                 title or path — the near-verbatim recall that IS the
  #                 known-item case ("the board adapter cache split note")
  #   rrfk     10   reciprocal-rank-fusion constant. The textbook 60 is tuned
  #                 for lists of thousands; over a 20-candidate set it flattens
  #                 every rank to near-equal and the fusion stops discriminating.
  jq -cs \
    --arg q "$query" --argjson k "$k" \
    --argjson rrfk 10 --argjson w_title 1.0 --argjson w_path 0.4 \
    --argjson w_phrase 1.0 \
    --argjson w_lex "${KNOWLEDGE_SEARCH_RERANK_LEX_WEIGHT:-1.0}" \
    --argjson abstain "$([ "${KNOWLEDGE_SEARCH_ABSTAIN:-0}" = "1" ] && echo true || echo false)" \
    --argjson abstain_score_floor "${KNOWLEDGE_SEARCH_ABSTAIN_SCORE_FLOOR:-0.72}" \
    --argjson abstain_lex_floor "${KNOWLEDGE_SEARCH_ABSTAIN_LEX_FLOOR:-0.10}" '
    def norm: ascii_downcase | gsub("[^a-z0-9]+"; " ") | sub("^ +"; "") | sub(" +$"; "");
    # Single characters are dropped: they carry no retrieval signal and match
    # far too much. Digits are KEPT (issue refs like 1443 are strong known-item
    # evidence).
    def toks: norm | split(" ") | map(select(length > 1));
    # Deliberately minimal suffix stemmer, applied to BOTH sides so a query term
    # and a title term reach the same root. It exists because the measured
    # known-item misses were dominated by inflection mismatches the exact-token
    # matcher could not see -- "editor"/"Editing", "plan"/"Plans-archive". Each
    # rule is length-guarded so it cannot chew a short word down to a stub, and
    # the plural rule skips a double-s ("process" stays "process"). It is NOT a
    # linguistic stemmer and does not try to be: over-merging costs precision,
    # so only inflections that actually appeared in the corpus are handled.
    def stem:
      (if (test("(ing|ers|ors|ed)$") and (length > 5)) then sub("(ing|ers|ors|ed)$"; "") else . end)
      | (if (test("(er|or)$") and (length > 4)) then sub("(er|or)$"; "") else . end)
      | (if (test("[^s]s$") and (length > 3)) then sub("s$"; "") else . end);
    def stems: toks | map(stem) | unique;
    def stop: ["the","a","an","of","for","in","on","to","and","or","is","are",
               "was","were","be","been","being","what","how","why","where",
               "when","which","who","whom","that","this","these","those","with",
               "do","does","did","doing","my","we","our","us","it","its","by",
               "from","at","as","not","but","if","then","than","so","about",
               "into","out","up","down","over","under","all","any","some","no",
               "can","will","would","should","could","you","your","me","there",
               "their","them","they","have","has","had","get","got","use","used",
               "using","vs","via","re"];

    . as $all
    | ($q | toks | map(stem)) as $qraw
    # A query made ENTIRELY of stopwords keeps its raw terms rather than
    # collapsing to an empty term set (which would silently disable the lever).
    | (($qraw - (stop | map(stem))) as $s
       | (if ($s | length) > 0 then $s else $qraw end) | unique) as $qt
    | ($q | norm) as $qn
    | if ($all | length) == 0 then empty
      # Trap 2: any score-0 provenance marker in the set -> pass through
      # untouched. Never reorder a fallback hit against backend results.
      elif ([ $all[] | select(.score == 0) ] | length) > 0 then $all[0:$k][]
      # No usable query terms -> nothing to re-rank on; keep backend order.
      elif ($qt | length) == 0 then $all[0:$k][]
      else
        [ $all
          | to_entries[]
          | .key as $r
          | .value as $d
          | { r: $r, d: $d,
              tt: (($d.title // "") | stems),
              pt: ((($d.doc_id // "") | sub("\\.md$"; "")) | stems),
              ph: (if ((($d.title // "") | norm) | contains($qn))
                      or ((($d.doc_id // "") | norm) | contains($qn))
                   then 1 else 0 end) }
        ] as $c
        # Per-query term rarity (IDF over THIS query candidate set, never a
        # corpus statistic). A term carried by most candidates -- "subset",
        # "epic", a project name -- discriminates nothing here, while a term in
        # one or two candidates is exactly the known-item signal. Computing it
        # over the returned set keeps it query-relative, which is what trap 1
        # requires; a corpus-wide IDF would also mean a second index to maintain.
        | ($c | length) as $n
        | ( reduce $c[] as $x ({};
              reduce (($x.tt + $x.pt) | unique)[] as $t (.; .[$t] = ((.[$t] // 0) + 1)))
          ) as $df
        | ( [ $qt[] | { key: ., value: (($n / (($df[.] // 0) + 0.5)) | log) } ]
            | from_entries ) as $idf
        # A term absent from every candidate gets the largest weight but can
        # never be matched, so it only ever sits in the denominator. Weights are
        # floored at 0 so a term present in every candidate contributes nothing
        # rather than going negative.
        | ( [ $qt[] | (if ($idf[.] // 0) > 0 then $idf[.] else 0 end) ] | add ) as $wtot
        | [ $c[]
            | . as $x
            | ( [ $qt[] | select(. as $t | $x.tt | index($t))
                        | (if ($idf[.] // 0) > 0 then $idf[.] else 0 end) ] | add // 0 ) as $twt
            | ( [ $qt[] | select(. as $t | $x.pt | index($t))
                        | (if ($idf[.] // 0) > 0 then $idf[.] else 0 end) ] | add // 0 ) as $pwt
            # Fall back to plain coverage when every query term is equally
            # common (wtot == 0), so the feature degrades instead of dividing
            # by zero.
            | (if $wtot > 0
               then { t: ($twt / $wtot), p: ($pwt / $wtot) }
               else { t: (([ $qt[] | select(. as $t | $x.tt | index($t)) ] | length) / ($qt | length)),
                      p: (([ $qt[] | select(. as $t | $x.pt | index($t)) ] | length) / ($qt | length)) }
               end) as $cv
            | { r: $x.r, d: $x.d,
                L: ($w_title * $cv.t + $w_path * $cv.p + $w_phrase * $x.ph) }
          ] as $c2
        # The lexical rank list contains ONLY candidates with real lexical
        # evidence (L > 0). A candidate with zero query-term agreement gets no
        # lexical term at all, rather than a middling rank that would inject
        # noise into the fusion. Ties break on backend rank (trap 3).
        | ([ $c2[] | select(.L > 0) ] | sort_by(-.L, .r)) as $lex
        | ($lex | to_entries
                | map({ key: (.value.r | tostring), value: .key })
                | from_entries) as $lexrank
        | [ $c2[]
            | .f = (1 / ($rrfk + .r)
                    + $w_lex * (($lexrank[(.r | tostring)]) as $lr
                                | if $lr == null then 0 else 1 / ($rrfk + $lr) end))
          ]
        | sort_by(-.f, .r)
        # Abstention floor (foundation#1450): gate on the TOP-ranked (best
        # available) candidate only -- if even the best one fails both
        # floors, none of the rest can pass either (see the comment block
        # above this function for why BOTH must fail, and the measured
        # 0/186-cost result). Off by default ($abstain false) -> untouched.
        | if ($abstain and (length > 0)
              and (.[0].d.score < $abstain_score_floor)
              and (.[0].L < $abstain_lex_floor))
          then {__ks_abstain: true}
          else (.[0:$k][] | .d)
          end
      end
  '
}

# Reshape basic-memory's SearchResponse JSON ({results:[...]}) read on stdin
# into this file's JSONL contract on stdout — one {doc_id,title,score,snippet}
# object per line. The output-shape contract has ONE owner here: the cold
# backend below AND the warm basic-memory-mcp backend (knowledge_search_mcp.sh)
# both pipe through this, so a field rename in a bm version bump can't drift the
# two backends apart (one is production, the other its fail-open fallback).
_ks_bm_reshape_results() {
  jq -c '.results[]? | {doc_id: .file_path, title: .title, score: .score, snippet: (.matched_chunk // .content // "")}'
}

# <query> [--limit N] -> JSONL results on stdout (see exit-code contract on
# ks_search above).
_ks_search_backend_basic_memory_search() {
  local query="$1"; shift
  local limit=10
  # Allowlist, not a silent discard (temperloop#418) — see ks_search's own
  # parse loop for why a discarded flag is the dangerous shape here. Note
  # `--partition` is deliberately NOT accepted at this layer: the scope is
  # enforced in ks_search, above every backend, so that a backend can never
  # fail open by simply not implementing it.
  while [ $# -gt 0 ]; do
    case "$1" in
      --limit) limit="${2:?knowledge_search: --limit requires a value}"; shift 2 ;;
      *)
        printf 'knowledge_search: basic-memory search: unrecognised argument "%s" (accepted: --limit)\n' "$1" >&2
        return 2
        ;;
    esac
  done

  # shellcheck disable=SC2119  # deliberately no args: these call sites want the loud (non-quiet) gate
  _ks_search_backend_basic_memory_available || return $?
  _ks_bm_ensure_config || {
    echo "knowledge_search: could not write basic-memory config" >&2
    return 4
  }

  local root project raw rc=0
  root="$(ks_root)"
  project="$KNOWLEDGE_SEARCH_BM_PROJECT"

  # Post-fetch re-rank (#1446): ask the backend for a DEEPER candidate set than
  # the caller wants, then re-rank down to --limit. Internal by construction —
  # the caller still receives exactly `limit` records. With the re-rank off,
  # depth collapses to limit and this is a no-op.
  local depth="$limit"
  if [ "${KNOWLEDGE_SEARCH_RERANK:-1}" = "1" ] \
     && [ "${KNOWLEDGE_SEARCH_RERANK_DEPTH:-20}" -gt "$limit" ]; then
    depth="${KNOWLEDGE_SEARCH_RERANK_DEPTH:-20}"
  fi

  # foundation#996: try the search FIRST and register the project lazily only on
  # a miss. The per-query `basic-memory project add` is a ~1.9s subprocess (~45%
  # of search latency, F#992) yet a no-op on an already-registered project, so
  # the warm path — the overwhelming common case — now issues ONE subprocess
  # instead of two. `|| rc=$?` (not a bare trailing `$?` read) so a failing
  # command substitution doesn't trip the CALLER's `set -e` before rc is
  # captured — this file is sourced into scripts that own that option.
  raw="$(_ks_bm_run tool search-notes "$query" --hybrid --project "$project" --page-size "$depth" 2>/dev/null)" || rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$raw" ]; then
    # Miss: the project isn't registered yet (first use), or a `basic-memory
    # reset` dropped the DB while config still lists it (the idempotency caveat
    # the per-query call used to cover). Register (idempotent) and retry ONCE. A
    # genuinely empty result is NOT a miss — basic-memory returns a non-empty
    # `{"results":[]}` envelope for it — so this branch fires only on a real
    # project-not-found / DB-dropped failure, never on a warm no-match query.
    _ks_bm_project_add "$project" "$root" || {
      echo "knowledge_search: basic-memory project registration failed" >&2
      return 4
    }
    # Registration alone leaves the index EMPTY — index once, here, before the
    # retry (temperloop#1635; see _ks_bm_initial_index above for why this is
    # the one place that knows a cold start just happened). Best-effort: a
    # failure warns and falls through to the retry rather than failing the
    # search outright.
    _ks_bm_initial_index "$project" || true
    rc=0
    # The FIRST search's stderr is suppressed above (a miss there is expected —
    # "project not found" on a cold start). A RETRY failure, by contrast, is a
    # genuine backend error worth diagnosing, so capture its stderr and surface
    # the tail on failure — the same K#368/foundation#1176 discipline
    # `_ks_bm_project_add` applies (an opaque "failed" with no cause is
    # undiagnosable).
    local search_err; search_err="$(mktemp "${TMPDIR:-/tmp}/ks-search-err.XXXXXX" 2>/dev/null)" || search_err=/dev/null
    raw="$(_ks_bm_run tool search-notes "$query" --hybrid --project "$project" --page-size "$depth" 2>"$search_err")" || rc=$?
    if [ "$rc" -ne 0 ] || [ -z "$raw" ]; then
      echo "knowledge_search: basic-memory search-notes failed (exit $rc)" >&2
      [ "$search_err" != /dev/null ] && { tail -n 15 "$search_err" >&2; rm -f "$search_err"; }
      return 4
    fi
    [ "$search_err" != /dev/null ] && rm -f "$search_err"
  fi

  printf '%s' "$raw" | _ks_bm_reshape_results | _ks_bm_rerank "$query" "$limit" \
    || { echo "knowledge_search: could not parse basic-memory search output" >&2; return 4; }
}

# [--full] [--search] [--embeddings] -> rebuilds the index for ks_root's
# project. Always explicit (point 3) — no caller of this file ever starts a
# watcher. basic-memory's own reindex is resumable on timeout re-invocation
# (contract-documented CI caching guidance), so this is safe to call repeatedly.
#
# Flag passthrough (temperloop#888). Each accepted flag is forwarded to
# `basic-memory reindex` by NAME, from an explicit allowlist — deliberately
# not a blanket `"$@"` forward, because the allowlist is exactly what makes
# the unknown-flag rejection below possible. The shapes that matter, measured
# on a 977-note live store (foundation#1425, 2026-07-28):
#
#   --full --search   full filesystem rescan + FTS rebuild, reconciling the
#                     entity table (re-paths moves, drops deletions) WITHOUT
#                     the forced full re-embed — 61s
#   --full            the above plus the forced full re-embed             — 587s
#
# The first shape is what a scheduled drift-healing reindex wants, and before
# this it was unreachable through the public seam: a caller had to reach into
# the library-PRIVATE `_ks_bm_run` behind a `command -v` probe to get it.
#
# An UNRECOGNISED argument is now an error (exit 2, the contract's
# invalid-usage code), not silently shifted away. The old loop discarded
# every non-`--full` argument, so a mistyped `ks_search_reindex --full
# --serch` silently degraded to bare `--full` — the 587s forced re-embed
# instead of the 61s shape the caller asked for — with no warning at all.
_ks_search_backend_basic_memory_reindex() {
  local full=0 rebuild_search=0 rebuild_embeddings=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --full)       full=1; shift ;;
      --search)     rebuild_search=1; shift ;;
      --embeddings) rebuild_embeddings=1; shift ;;
      *)
        printf 'knowledge_search: ks_search_reindex: unrecognised argument "%s" (accepted: --full, --search, --embeddings)\n' "$1" >&2
        return 2
        ;;
    esac
  done

  # shellcheck disable=SC2119  # deliberately no args: these call sites want the loud (non-quiet) gate
  _ks_search_backend_basic_memory_available || return $?
  _ks_bm_ensure_config || {
    echo "knowledge_search: could not write basic-memory config" >&2
    return 4
  }

  local root project
  root="$(ks_root)"
  project="$KNOWLEDGE_SEARCH_BM_PROJECT"
  _ks_bm_project_add "$project" "$root" || {
    echo "knowledge_search: basic-memory project registration failed" >&2
    return 4
  }

  # Assemble the forwarded flags in a fixed order so the emitted command line
  # is deterministic regardless of the order the caller passed them. `--project`
  # is appended last and unconditionally, which also keeps the expansion below
  # safe under `set -u` on bash 3.2 (macOS), where "${empty_array[@]}" is an
  # unbound-variable error rather than an empty expansion.
  local -a bm_args
  bm_args=()
  if [ "$full" -eq 1 ]; then               bm_args+=(--full); fi
  if [ "$rebuild_search" -eq 1 ]; then     bm_args+=(--search); fi
  if [ "$rebuild_embeddings" -eq 1 ]; then bm_args+=(--embeddings); fi
  bm_args+=(--project "$project")

  _ks_bm_run reindex "${bm_args[@]}" || {
    echo "knowledge_search: basic-memory reindex failed" >&2
    return 4
  }
}

# Note: ks_search_available dispatches op "available" straight to
# _ks_search_backend_basic_memory_available (defined above) — same function
# used internally as the availability gate for search/reindex, exposed
# standalone so a caller can probe without touching stdout at all.
