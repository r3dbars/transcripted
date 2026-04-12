# Text utilities

## Current status

`Sources/Text/` holds a couple of small pure text helpers that survived the
earlier drafting flow.

## Files

- `DiffSummary.swift` — legacy pure word-level diff helpers retained from the removed review flow
- `RefusalHeuristics.swift` — refusal-phrase heuristic retained as a pure utility

## Agent notes

- The product-level drafting mode is removed on `main`; `Sources/UI/DictationSessionController.swift` now handles dictation only and returns a fixed message from removed draft-mode methods.
- `DiffSummary` is no longer part of a live top-level product flow on `main`.
- `RefusalHeuristics.looksLikeRefusal(...)` is still covered by tests, but it belongs to the older ghostwriting domain and is not a live top-level product flow on `main`.

## Test coverage

- `Tests/DiffSummaryTests.swift`
- `Tests/RefusalHeuristicsTests.swift`
