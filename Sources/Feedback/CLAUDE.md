# Feedback — FeedbackStore

## What This Is

`FeedbackStore` logs every accepted draft to:

```
~/Library/Application Support/Draft/feedback.jsonl
```

One JSON object per line, appended on every Copy or Paste action. It also parses the feedback log to compute aggregate usage statistics displayed in the MenuBarPanel.

## File: FeedbackStore.swift (~172 lines)

Contains three components:

1. **`FeedbackEntry`** — A `Codable` struct representing one feedback record. Uses `CodingKeys` for snake_case JSON mapping.
2. **`UsageStats`** — A plain struct aggregating usage metrics (words dictated, messages drafted, minutes saved, words drafted, words accepted).
3. **`FeedbackStore`** — `@MainActor ObservableObject` with `@Published var stats`. Handles both writing (`record()`) and reading (`refreshStats()`) of the feedback log.

Also includes `AcceptAction` enum (`copy`, `paste`).

## Schema

```json
{
  "timestamp": "2026-02-17T16:30:00Z",
  "raw_text": "the user's original spoken/typed input",
  "drafted_text": "what Claude produced",
  "accepted_text": "what was actually copied/pasted (may differ if user edited the draft)",
  "action": "copy" | "paste",
  "example_count": 5,
  "formality": "casual"
}
```

The `formality` field is optional — present when vision extraction detected a register (casual/professional/formal).

## UsageStats

```swift
struct UsageStats {
    var wordsDictated: Int = 0
    var messagesDrafted: Int = 0
    var minutesSaved: Int = 0
    var wordsDrafted: Int = 0
    var wordsAccepted: Int = 0
}
```

Computed by `refreshStats()` from the feedback log. `minutesSaved` is estimated at ~40 WPM average typing speed: `(wordsDrafted + wordsAccepted) / 40`. This accounts for both the words Claude drafted (which the user would have had to type themselves) and the words in the final accepted version (the actual typing savings). These stats are displayed in the MenuBarPanel stats section, where the "saved" label has a hover tooltip breaking down `wordsDrafted` and `wordsAccepted`.

## Why

The native `AnalysisEngine` (in `Sources/Analysis/`) reads `feedback.jsonl` to understand:
- Which drafts the user accepted without editing (signals: prompt is working)
- Which drafts the user edited before accepting (signals: prompt missed something)
- Patterns across many accepts (signals: what the user's voice really sounds like)

It then rewrites `prompts.json` to improve future drafts.

The `UsageStats` give the user a quick sense of how much value Draft has provided (words dictated, messages drafted, time saved).

## Design Notes

- JSONL (not JSON array) so the file can be appended atomically without parsing the whole thing
- `FeedbackStore` conforms to `ObservableObject` with a `@Published var stats` property so SwiftUI views (MenuBarPanel) can reactively display usage statistics
- File writes via `record()` are synchronous on whatever thread calls them
- File reads via `refreshStats()` dispatch to a `Task.detached` block that calls a `nonisolated static` helper (`parseStats(url:)`) to avoid blocking the main actor. The helper parses the entire JSONL file, decodes each line with a locally-created `JSONDecoder`, and aggregates into a `UsageStats` value. Lines that fail to decode are silently skipped. The result is assigned back to `self.stats` on the main actor.
- `accepted_text` != `drafted_text` when the user edits the draft in the TextEditor before hitting Copy/Paste — this edit delta is the richest feedback signal
- An `encoder` is initialized once on `FeedbackStore` and reused for all writes. A `decoder` is created locally inside `parseStats()` for each read pass.

## Public API

| Method | Purpose |
|--------|---------|
| `record(rawText:draftedText:acceptedText:action:exampleCount:formality:)` | Append a feedback entry to `feedback.jsonl` |
| `refreshStats()` | Parse `feedback.jsonl` and update the `@Published stats` property |

## Error Handling

All failure paths log warnings via both `print()` and `EventReporter`:
- `feedback_encode_failed` — if `JSONEncoder` fails to encode the entry
- `feedback_file_open_failed` — if `FileHandle` cannot open `feedback.jsonl` for appending
- `feedback_file_create_failed` — if initial file creation fails

`refreshStats()` resets stats to zero defaults if the file is missing or unreadable. Malformed lines are skipped without error.

This makes feedback logging failures visible in the debug log and `events.jsonl` rather than silently dropping training data.
