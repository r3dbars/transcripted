# Feedback — FeedbackStore

## What This Is

`FeedbackStore` logs every accepted draft to:

```
~/Library/Application Support/Draft/feedback.jsonl
```

One JSON object per line, appended on every Copy or Paste action.

## Schema

```json
{
  "timestamp": "2026-02-17T16:30:00Z",
  "raw_text": "the user's original spoken/typed input",
  "drafted_text": "what Claude produced",
  "accepted_text": "what was actually copied/pasted (may differ if user edited the draft)",
  "action": "copy" | "paste",
  "example_count": 5
}
```

## Why

The orchestrator agent reads `feedback.jsonl` to understand:
- Which drafts the user accepted without editing (signals: prompt is working)
- Which drafts the user edited before accepting (signals: prompt missed something)
- Patterns across many accepts (signals: what the user's voice really sounds like)

It then rewrites `prompts.json` to improve future drafts.

## Design Notes

- JSONL (not JSON array) so the file can be appended atomically without parsing the whole thing
- `FeedbackStore` is not `@MainActor` — file writes are synchronous on whatever thread calls `record()`
- No read methods — this is a write-only append log. The analysis engine reads the file directly.
- `accepted_text` != `drafted_text` when the user edits the draft in the TextEditor before hitting Copy/Paste — this edit delta is the richest feedback signal

## Error Handling

All failure paths now log warnings instead of failing silently:
- `print("⚠️ FEEDBACK | failed to encode feedback entry")` — if `JSONEncoder` fails
- `print("⚠️ FEEDBACK | failed to open feedback.jsonl for writing")` — if `FileHandle` open fails
- `print("⚠️ FEEDBACK | failed to create feedback.jsonl: ...")` — if initial file creation fails

This makes feedback logging failures visible in the debug log rather than silently dropping training data.
