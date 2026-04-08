# Feedback directory

## Current status

No Swift sources currently live in `Sources/Feedback/` on `main`.

Older docs described a `FeedbackStore` and usage-stat logging path that are not present in the current source tree.

## Agent notes

- Do not assume `feedback.jsonl` is a live product dependency on `main` just because older docs mention it.
- Verify against current `Sources/Observability/` and `docs/storage-paths.md` before adding or reading new persisted files.
