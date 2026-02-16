# Style Learning Engine

## What This Does

Learns the user's writing style from accepted drafts and generates progressively deeper style profiles that personalize how Haiku drafts messages.

## Key File

- `StyleEngine.swift` — `@MainActor ObservableObject` managing style.md, example collection, and style analysis

## How It Works

### Collection
Every time the user accepts a draft (Copy or "Paste to Last App"), `recordExample(acceptedMessage:)` saves the polished output to `~/Library/Application Support/Draft/style.md`. Only the accepted message is saved — not the raw input or screenshot context.

### Analysis (Tiered)
Every 5 accepted examples, `regenerateStyleSummary()` sends all examples to Haiku with a style analysis prompt. The prompt scales with example count:

- **5-9 examples (Early):** Tone, sentence patterns, openings/closings, punctuation fingerprint, signature phrases
- **10-19 examples (Growing):** Adds argument structure, paragraph flow, emotional range, transition patterns
- **20+ examples (Mature):** Full persona — vocabulary signatures, contextual adaptation, rhetorical devices, what makes their writing uniquely theirs

Uses `maxTokens: 4096` (vs. 1024 for regular drafts) since rich profiles need more room.

### Application
`buildSystemPrompt()` extracts only the Style Summary section (not examples) and wraps it in ghostwriting instructions. Tells Haiku to embody the user's voice — use their vocabulary, mirror their rhythms, match their energy. The prompt says "ghostwrite as this person" not just "match this style."

### Cost Model
Only the Style Summary is injected into the system prompt, not the raw examples. This means drafting cost stays constant regardless of example count (5 or 500). The analysis cost scales with examples but only runs every 5th draft.

## File Format (style.md)

```markdown
# Writing Style Profile

## Style Summary
[Haiku-generated structured profile with labeled sections]

## Accepted Examples

### Example 1
[accepted message text]

### Example 2
[accepted message text]
```

## Public Interface

```swift
@Published var exampleCount: Int
@Published var styleFileContents: String

func buildSystemPrompt() -> String              // Returns style-aware or default prompt
func recordExample(acceptedMessage: String)      // Saves accepted draft
func regenerateStyleSummary(apiKey: String) async // Triggers Haiku analysis
```

## Storage

- **Location:** `~/Library/Application Support/Draft/style.md`
- **Format:** Markdown with structured sections
- **Persistence:** Written atomically on every change
