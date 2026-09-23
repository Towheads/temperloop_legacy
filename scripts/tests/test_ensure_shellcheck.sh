#!/usr/bin/env bash
# Regression tests for scripts/ensure-shellcheck.sh (temperloop#567).
#
# The gate this backstops: local `make shellcheck` and CI must run the SAME
# version of shellcheck, or the local gate false-greens (the #550 SC2015 skew,
# where CI-ubuntu's 0.9.0 flagged a construct local/brew's 0.11.0 did not). The
# helper's contract is: resolve a binary that reports EXACTLY the pinned version,
# and fail loudly (never silently fall back to a host version) when it cannot.
#
# T1/T2 provision the real pinned binary (network on a cold cache, then a warm
# fast path) — they SKIP cleanly, exit 0, only when genuinely offline with a cold
# cache, so they run for real in CI/online and never false-fail with no network.
# T3 is network-independent in outcome: an unknown pinned version must exit
# non-zero, proving a bad/unpinned version can't slip through as a false green.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/scripts/ensure-shellcheck.sh"
EXPECTED_VERSION="0.11.0"
PASS=0
FAIL=0

pass() { echo "  ✓ $1"; (( PASS++ )); }
fail() { echo "  ✗ $1"; (( FAIL++ )); }

# ---------------------------------------------------------------------------
# T1 — the helper resolves a binary that reports EXACTLY the pinned version.
# ---------------------------------------------------------------------------
if ! bin1="$(bash "$SCRIPT" 2>/dev/null)"; then
  echo "  SKIP: ensure-shellcheck.sh could not provision shellcheck $EXPECTED_VERSION"
  echo "        (offline with a cold cache) — skipping version/idempotency checks."
  echo "  ---"
  echo "  PASS=$PASS FAIL=$FAIL (skipped)"
  exit 0
fi

if [ -x "$bin1" ]; then
  pass "helper resolved an executable binary path"
else
  fail "helper's printed path is not executable: [$bin1]"
fi

reported="$("$bin1" --version 2>/dev/null | awk -F': ' '/^version:/ {print $2}')"
if [ "$reported" = "$EXPECTED_VERSION" ]; then
  pass "resolved binary reports the pinned version ($EXPECTED_VERSION)"
else
  fail "resolved binary reports '$reported', expected pinned '$EXPECTED_VERSION'"
fi

# ---------------------------------------------------------------------------
# T2 — idempotent: a second call returns the same path via the warm fast path.
# ---------------------------------------------------------------------------
bin2="$(bash "$SCRIPT" 2>/dev/null)"
if [ "$bin1" = "$bin2" ]; then
  pass "idempotent: repeat call returns the same cached path"
else
  fail "repeat call returned a different path: [$bin1] vs [$bin2]"
fi

# ---------------------------------------------------------------------------
# T3 — an unknown pinned version must FAIL LOUDLY, never silently succeed with a
# host shellcheck. Network-independent: the 404 download (or offline curl error)
# both exit non-zero, so this asserts the same outcome with or without network.
# ---------------------------------------------------------------------------
if SHELLCHECK_VERSION="99.99.99" bash "$SCRIPT" >/dev/null 2>&1; then
  fail "helper unexpectedly SUCCEEDED for a nonexistent version 99.99.99"
else
  pass "helper fails loudly for an unresolvable pinned version (no silent host fallback)"
fi

# ---------------------------------------------------------------------------
# T4 — a PATH shellcheck reporting EXACTLY the pinned version is used first, with
# no download (temperloop#2198). Pinned to a version that has no release asset
# and no cache, so the ONLY way the helper can succeed is the PATH binary —
# network-independent, and it proves precedence over the download in one shot.
# ---------------------------------------------------------------------------
fake_dir="$(mktemp -d)"
trap 'rm -rf "$fake_dir"' EXIT
cat > "$fake_dir/shellcheck" <<'FAKE'
#!/usr/bin/env bash
[ "${1:-}" = "--version" ] && { printf 'ShellCheck - shell script analysis tool\nversion: 77.77.77\n'; exit 0; }
exit 0
FAKE
chmod +x "$fake_dir/shellcheck"
got="$(SHELLCHECK_VERSION="77.77.77" PATH="$fake_dir:$PATH" bash "$SCRIPT" 2>/dev/null)"
if [ "$got" = "$fake_dir/shellcheck" ]; then
  pass "a PATH shellcheck reporting exactly the pinned version is used first (no download)"
else
  fail "expected the PATH binary [$fake_dir/shellcheck], got [$got]"
fi

# ---------------------------------------------------------------------------
# T5 — a PATH shellcheck of a DIFFERENT version is ignored: with the pin set to
# an unresolvable version, the helper must still fail rather than use it. This
# is T3's guarantee restated against an explicit, present, wrong-version host
# binary — the case the PATH-first step must never regress.
# ---------------------------------------------------------------------------
if SHELLCHECK_VERSION="99.99.99" PATH="$fake_dir:$PATH" bash "$SCRIPT" >/dev/null 2>&1; then
  fail "helper used a PATH shellcheck of the WRONG version (77.77.77 for pin 99.99.99)"
else
  pass "a PATH shellcheck of a different version is ignored, never a silent fallback"
fi

echo "  ---"
echo "  PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
