# Text Utilities

## Current status

`Sources/Text/` contains a few pure text helpers retained from the earlier
drafting flow.

## Important files

- `DiffSummary.swift` — word-level diff helpers still used by overlay review UI
- `RefusalHeuristics.swift` — refusal-phrase heuristic retained as a pure utility

## Notes

- the product-level drafting mode is removed on `main`
- `DiffSummary` still matters to the dictation overlay review experience
- `RefusalHeuristics` is legacy-domain utility, not a top-level current feature

## Relevant tests

- `Tests/DiffSummaryTests.swift`
- `Tests/RefusalHeuristicsTests.swift`
