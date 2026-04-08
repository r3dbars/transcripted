# Draft

## What This Contains

Pure draft-processing helpers that support review and diff presentation.

Current Swift files: **2**

| File | Purpose |
|---|---|
| `DiffSummary.swift` | Word-level diff computation and edit-summary helpers |
| `DraftUtils.swift` | Small pure utility helpers extracted for testability |

## Notes
- There is no longer a large `DraftEngine` implementation in this directory on `main`.
- Treat this folder as pure helper logic, not app-state orchestration.
