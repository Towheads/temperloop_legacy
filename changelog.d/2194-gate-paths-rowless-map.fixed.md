- **`check-gate-paths.sh` now reports every finding on a row-less map instead
  of aborting** (#2194). `map has no usable rows` is recorded, not fatal, so
  the completeness walk still ran — with `KEY_BY_INDEX` empty. Under bash 3.2
  (macOS `/bin/bash`) `"${KEY_BY_INDEX[@]}"` on a zero-length array is an
  unbound-variable error under `set -u`, so the gate died after one finding
  and printed a bash error where the other 288 should have been. The
  expansion now uses the repo's guarded idiom, `"${arr[@]+"${arr[@]}"}"`.
