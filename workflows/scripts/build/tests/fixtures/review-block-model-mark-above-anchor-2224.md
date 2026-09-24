Already have the diff from the earlier view; proceeding straight to the review.

<!-- 3e-model: claude-opus-5[1m] -->

## Summary
1 file in scope for this seat. Zero blocking findings — the new pass-through is
null-safe and shell-quoted through the existing helper.

## Findings
None.

## What's solid
- **Null/undefined safety**: the combined `!= null` idiom is the correct one here.
- **Injection/escaping**: every interpolated value reuses the file's own quoting helper.

Files reviewed: `claude/workflows/build-level.mjs`.
