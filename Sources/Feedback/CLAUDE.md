# Feedback Folder

## Current State

This folder is currently documentation-only and does not contain active Swift sources.

The earlier feedback-store pipeline described in older docs is not a live subsystem in the current Transcripted app. Operational diagnostics now flow through `Sources/Observability/`.

## Guidance

- Treat any references to `feedback.jsonl` in older docs as historical unless backed by current source.
- If structured user-feedback capture returns, document the file format, storage path, and ownership here when the code lands.
