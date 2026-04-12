# Text utilities

## Current status

`Sources/Text/` now holds a single small pure text helper that survived the
earlier drafting flow.

## Files

- `DiffSummary.swift` — legacy pure word-level diff helpers retained from the removed review flow

## Agent notes

- The product-level drafting mode is removed on `main`; `Sources/UI/DictationSessionController.swift` now handles dictation only and returns a fixed message from removed draft-mode methods.
- `DiffSummary` is no longer part of a live top-level product flow on `main`.

## Test coverage

- `Tests/DiffSummaryTests.swift`
