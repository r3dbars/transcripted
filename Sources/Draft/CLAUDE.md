# Draft Helpers

## Current Scope

This folder no longer contains the old drafting engine. It now holds small pure helpers that survived the rename:

- `DiffSummary.swift`
- `DraftUtils.swift`

## `DiffSummary.swift`

Provides pure word-level diff and edit-description logic:

- `computeWordDiff(original:edited:)`
- `describeEdit(original:edited:platform:)`
- `milestoneMessage(exampleCount:)`
- `hasSubstantiveEdits(original:edited:)`

This file is used for lightweight edit feedback and tests. It has no UI or inference dependencies.

## `DraftUtils.swift`

Contains small drafting-era utility logic that is still reused, primarily refusal detection:

- `looksLikeRefusal(_:)`

That check remains useful anywhere legacy or compatibility drafting text can still surface.

## Naming Note

`Draft` in this folder name is historical. The live Transcripted app is dictation- and meeting-focused; this folder is just where the shared pure helpers still live.

## Verification

```bash
bash run-tests.sh
```
