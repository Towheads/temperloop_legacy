#!/usr/bin/env bash
# description: health check for the machine surface — managed link status, knowledge-store root, cache state, reviewer coverage, and toolkit provenance
#
# doctor.sh — `temperloop doctor` (temperloop#1047).
#
# WHAT THIS SUPERSEDES, stated plainly because a shipped document asserted the
# opposite: `bin/README.md` used to say outright "There is no `temperloop
# doctor` subcommand; `doctor.sh` is invoked directly, at the path `temperloop
# install` prints for you." That is no longer true, and the same change that
# added this file rewrote that paragraph and added a CHANGELOG entry rather
# than leaving the release contradicting its own docs.
#
# WHY IT EXISTS. The health check was reachable only two ways: by typing an
# absolute script path an operator had to copy off the tail of a `temperloop
# install` run, or as the trailing step of `temperloop update`. Neither is
# discoverable from `temperloop help`. Once the health check grew a check
# whose whole purpose is to be run ad hoc mid-session — "is the toolkit I am
# running actually the release it claims to be?" (check_toolkit_provenance,
# temperloop#1047) — a subcommand stopped being a convenience and became the
# on-ramp that check needs.
#
# WHY THIS IS NOT A "SHADOW MAKEFILE TARGET". The dispatcher's scope rule
# (bin/temperloop's header) forbids growing this CLI into a second front door
# onto an existing checkout's day-to-day `make` work. `doctor` is not that:
# it reports on the MACHINE SURFACE — the ~/.claude symlinks, the install
# manifest's paths, the managed clone's own provenance — which is exactly the
# pre-checkout, machine-scoped territory this CLI owns (ADR 0023, "the CLI is
# pre-checkout; slash commands are in-checkout"). `make doctor` runs the same
# script for someone who already has a checkout and a Makefile; this reaches
# the stranger who has neither.
#
# DELEGATION, NOT REIMPLEMENTATION. Every argument, every line of output and
# the exit code all come from workflows/scripts/install/doctor.sh, which is
# `exec`'d — not re-parsed, not filtered, not re-printed. `temperloop doctor`
# and `bash <clone>/workflows/scripts/install/doctor.sh` are therefore
# byte-identical by construction, which is what
# workflows/scripts/tests/test_temperloop_doctor_subcommand.sh asserts.
#
# DISPATCH MODEL: a discovered subcommand, like every sibling here — this
# file's mere presence at bin/subcommands/doctor.sh IS `temperloop doctor`,
# with no dispatcher edit.
#
# PREREQS: none. It shells out to neither `claude` nor `gh`, so it declares no
# `# prereqs:` header (see bin/temperloop's per-subcommand prereq contract).
#
# Usage:
#   temperloop doctor [<toolkit-root>]
#
#   <toolkit-root>  optional; defaults to the clone this CLI lives in. Passed
#                   straight through to the underlying script, whose own usage
#                   header owns its meaning.
#
# Exit code: whatever the underlying health check returns — 0 when every
# managed entry is OK, 1 when one or more is not.
set -uo pipefail

SUBCOMMAND_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$(cd "$SUBCOMMAND_DIR/.." && pwd)"
KERNEL_ROOT="$(cd "$BIN_DIR/.." && pwd)"
DOCTOR_SH="$KERNEL_ROOT/workflows/scripts/install/doctor.sh"

case "${1:-}" in
  -h|--help)
    grep '^#' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
esac

if [ ! -f "$DOCTOR_SH" ]; then
  echo "temperloop doctor: health check not found at $DOCTOR_SH" >&2
  echo "  This clone looks incomplete — reinstall with bin/bootstrap.sh, or run 'temperloop update'." >&2
  exit 1
fi

exec bash "$DOCTOR_SH" "$@"
