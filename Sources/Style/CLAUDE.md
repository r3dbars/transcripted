# Style Utilities

## Current status

`Sources/Style/` is now a small utility area, not a live product subsystem.

## Important file

- `StyleUtils.swift` — pure helpers for refinement scheduling, edit-distance heuristics, and extracting recent example text from historical `style.md` shapes

## Notes

- there is no live `StyleEngine` source here
- these helpers survive mainly for retained utility and test coverage
- if you change the heuristics, update the tests

## Relevant tests

- `Tests/StyleUtilsTests.swift`
