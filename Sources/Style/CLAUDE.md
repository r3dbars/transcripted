# Style Utilities

## Current Scope

The old style-learning engine is no longer present in this branch. This folder currently contains one active source file:

- `StyleUtils.swift`

## What `StyleUtils` Does

`StyleUtils` is a pure-function helper namespace used by tests and diff/style heuristics. It does not own UI state, files, or background jobs.

Key helpers:

- `shouldRefineNow(exampleCount:styleFileContents:)`
- `averageRecentEditDistance(last:styleFileContents:)`
- `extractRecentEditDistances(last:styleFileContents:)`
- `wordEditDistance(_:_:)`
- `extractRecentExamplesText(last:styleFileContents:)`

## Important Constraint

These helpers still understand the historic `style.md` example-block format (`### Example`, `EDIT_DISTANCE`, `USER_SENT`, and so on). If you reuse or change them, preserve that parsing contract unless you are intentionally migrating every caller and test.

## What Is Not Here

- no `StyleEngine`
- no onboarding flow
- no live style-profile persistence owned by this folder

## Verification

```bash
bash run-tests.sh
```
