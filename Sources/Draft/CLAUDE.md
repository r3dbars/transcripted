# Draft utilities

## Current status

`Sources/Draft/` no longer contains the live draft / ghostwriting pipeline. The current directory holds small pure utilities that survived the transition.

## Files

- `DiffSummary.swift` — pure word-level diff helpers used by overlay review UI
- `DraftUtils.swift` — refusal-phrase heuristic retained as a pure utility

## Agent notes

- The product-level draft mode is removed on `main`; `Sources/UI/DraftSessionController.swift` now handles dictation only and returns a fixed message from removed draft-mode methods.
- `DiffSummary` is still used by `Sources/UI/OverlayDiffStripView.swift` and `Sources/UI/OverlayReviewView.swift`.
- `DraftUtils.looksLikeRefusal(...)` is still covered by tests, but it belongs to the older ghostwriting domain and is not a live top-level product flow on `main`.

## Test coverage

- `Tests/DiffSummaryTests.swift`
- `Tests/RefusalDetectionTests.swift`
