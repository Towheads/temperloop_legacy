#!/usr/bin/env bash
#
# ensure-shellcheck.sh — resolve a PINNED shellcheck binary, downloading and
# caching the official static release when the pinned version isn't already
# cached. Prints the absolute path of the pinned binary on STDOUT (and nothing
# else on stdout — all diagnostics go to stderr) so callers can do:
#
#     bin="$(scripts/ensure-shellcheck.sh)"
#     "$bin" -e SC1091 some-file.sh
#
# Why (temperloop#567): local `make shellcheck` and CI must run the SAME
# version of shellcheck, or the local gate gives a false green — a construct flagged
# by CI-ubuntu's shellcheck (0.9.0, apt) that local/brew's 0.11.0 does not emit
# (the #550 SC2015 skew, `mkdir && printf || true` at doctor.sh:400). Pinning one
# exact version and using it everywhere makes a local green guarantee a CI green.
#
# Self-contained: needs only curl (or wget), tar, and sha256sum (or shasum) — no
# uv, no docker. The binary is cached under <repo>/.cache/shellcheck/<version>/
# (gitignored) and verified against a known SHA-256 before it is trusted.
#
# Resolution order (temperloop#2198): a `shellcheck` already on PATH that
# reports EXACTLY the pinned version wins first — no download, no cache. The
# parity contract is the VERSION, not the download: an exact-version host
# binary gives the same verdicts, and on Linux/aarch64 the official release
# asset is ~5x slower than a natively built one (124 s vs 23 s over the same
# 150 files in foundation's CI VM), so a host that provisioned a native build
# must be allowed to use it. Any OTHER version on PATH is ignored, never used —
# the #567 no-silent-host-fallback guarantee is untouched. Then the in-repo
# cache, then the pinned download.
set -euo pipefail

# The single source of truth for the pin. Override via env for a deliberate bump.
SHELLCHECK_VERSION="${SHELLCHECK_VERSION:-0.11.0}"

# Repo root = parent of this script's dir (scripts/).
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/.." && pwd)"
CACHE_DIR="${REPO_ROOT}/.cache/shellcheck/${SHELLCHECK_VERSION}"
BIN="${CACHE_DIR}/shellcheck"

# Fastest path: a PATH shellcheck reporting exactly the pinned version. The
# `command -v` result may be a symlink — print it as found; callers only exec it.
if sys_bin="$(command -v shellcheck 2>/dev/null)" && [ -n "$sys_bin" ] \
   && "$sys_bin" --version 2>/dev/null | grep -xF "version: ${SHELLCHECK_VERSION}" >/dev/null; then
  printf '%s\n' "$sys_bin"
  exit 0
fi

# Fast path: a cached binary of the pinned version that reports that version.
# No network. `--version` prints a `version: <v>` line we match exactly.
if [ -x "$BIN" ] && "$BIN" --version 2>/dev/null | grep -xF "version: ${SHELLCHECK_VERSION}" >/dev/null; then
  printf '%s\n' "$BIN"
  exit 0
fi

# Resolve platform → release asset stem + its known sha256 (v0.11.0 .tar.gz).
os="$(uname -s)"
arch="$(uname -m)"
case "${os}.${arch}" in
  Darwin.arm64 | Darwin.aarch64)
    asset="darwin.aarch64"
    sha="339b930feb1ea764467013cc1f72d09cd6b869ebf1013296ba9055ab2ffbd26f" ;;
  Darwin.x86_64)
    asset="darwin.x86_64"
    sha="c2c15e08df0e8fbc374c335b230a7ee958c313fa5714817a59aa59f1aa594f51" ;;
  Linux.x86_64)
    asset="linux.x86_64"
    sha="b7af85e41cc99489dcc21d66c6d5f3685138f06d34651e6d34b42ec6d54fe6f6" ;;
  Linux.aarch64 | Linux.arm64)
    asset="linux.aarch64"
    sha="68a8133197a50beb8803f8d42f9908d1af1c5540d4bb05fdfca8c1fa47decefc" ;;
  *)
    {
      echo "ensure-shellcheck.sh: no pinned shellcheck ${SHELLCHECK_VERSION} asset for ${os}/${arch}."
      echo "  Install shellcheck ${SHELLCHECK_VERSION} yourself and put it on PATH,"
      echo "  or extend the platform map in $0."
    } >&2
    exit 1 ;;
esac

tarball="shellcheck-v${SHELLCHECK_VERSION}.${asset}.tar.gz"
url="https://github.com/koalaman/shellcheck/releases/download/v${SHELLCHECK_VERSION}/${tarball}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "ensure-shellcheck.sh: downloading pinned shellcheck ${SHELLCHECK_VERSION} (${asset})..." >&2
if command -v curl >/dev/null 2>&1; then
  curl -fsSL "$url" -o "${tmp}/${tarball}"
elif command -v wget >/dev/null 2>&1; then
  wget -qO "${tmp}/${tarball}" "$url"
else
  echo "ensure-shellcheck.sh: need curl or wget to download shellcheck." >&2
  exit 1
fi

# Verify the checksum BEFORE trusting the binary.
if command -v sha256sum >/dev/null 2>&1; then
  actual="$(sha256sum "${tmp}/${tarball}" | awk '{print $1}')"
elif command -v shasum >/dev/null 2>&1; then
  actual="$(shasum -a 256 "${tmp}/${tarball}" | awk '{print $1}')"
else
  echo "ensure-shellcheck.sh: need sha256sum or shasum to verify the download." >&2
  exit 1
fi
if [ "$actual" != "$sha" ]; then
  {
    echo "ensure-shellcheck.sh: checksum mismatch for ${tarball}"
    echo "  expected ${sha}"
    echo "  actual   ${actual}"
    echo "  (a version bump needs its matching sha256 in the platform map.)"
  } >&2
  exit 1
fi

# Extract (the tarball unpacks to shellcheck-v<version>/shellcheck) and install
# into the cache atomically-ish: extract to tmp, then move into place.
tar -xzf "${tmp}/${tarball}" -C "$tmp"
mkdir -p "$CACHE_DIR"
mv "${tmp}/shellcheck-v${SHELLCHECK_VERSION}/shellcheck" "$BIN"
chmod +x "$BIN"

printf '%s\n' "$BIN"
