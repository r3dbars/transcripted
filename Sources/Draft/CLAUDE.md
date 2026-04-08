# Draft Utilities

## What This Does

This folder is now a small pure-function utility layer used by the dictation and transcript cleanup flows. No orchestrator lives here.

## Key Files

- `DiffSummary.swift` - Word-level diff computation, human-readable edit descriptions, and milestone messages
- `DraftUtils.swift` - Refusal detection helper used to avoid poisoning downstream training or feedback data

## How It Works

`DiffSummary` is intentionally stateless. It tokenizes text, computes word-level changes, and produces a short description of how the edit changed the message. It is used wherever we need to explain user edits without involving an LLM.

`DraftUtils.looksLikeRefusal()` scans for refusal or clarification phrases so the app can skip obviously bad training examples.

## Public Interface

```swift
// DiffSummary (pure utility enum)
static func computeWordDiff(original: String, edited: String) -> [DiffOp]
static func describeEdit(original: String, edited: String, platform: String) -> String
static func milestoneMessage(exampleCount: Int) -> String?
static func hasSubstantiveEdits(original: String, edited: String) -> Bool

// DraftUtils (pure utility enum)
static func looksLikeRefusal(_ text: String) -> Bool
```

## Dependencies

- `Foundation`
- `StyleUtils` for the underlying word edit distance heuristic

## Design Notes

Keep this folder free of UI and model orchestration. The goal here is for the pure utility tests to stay fast and deterministic.

## Verification

`bash run-tests.sh`
