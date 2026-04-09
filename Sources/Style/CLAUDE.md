# Style utilities

## Current status

`Sources/Style/` currently contains only `StyleUtils.swift`.

Older docs describing `StyleEngine`, onboarding flows, and `style.md` refinement do not match the current tree on `main`.

## Current file

- `StyleUtils.swift` — pure helpers for refinement scheduling, edit-distance heuristics, and extracting recent example text from a historical `style.md` shape

## Agent notes

- This directory is now utility-only. There is no live `StyleEngine` source here.
- `Sources/Text/DiffSummary.swift` reuses `StyleUtils.wordEditDistance(...)`.
- If you change these heuristics, update the tests.

## Test coverage

- `Tests/StyleUtilsTests.swift`
