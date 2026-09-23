- **`scripts/ensure-shellcheck.sh` now uses a `shellcheck` already on PATH when
  it reports exactly the pinned version**, before the in-repo cache and the
  pinned download (#2198). The parity contract is the version, not the
  download: a same-version host binary gives the same verdicts, and on
  Linux/aarch64 the official release asset is ~5x slower than a natively
  built one (124 s vs 23 s over the same 150 files in foundation's CI VM),
  which was most of why the self-hosted `make shellcheck` gate took 576 s
  against 66 s hosted. A PATH shellcheck of any other version is still
  ignored, never used — `test_ensure_shellcheck.sh` gains T4 (exact-version
  PATH binary wins, no download) and T5 (wrong-version PATH binary is
  ignored) beside the existing no-silent-host-fallback case.
