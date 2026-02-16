# Style Learning Engine

## What This Does

Learns the user's writing style from accepted drafts and generates progressively deeper style profiles that personalize how Haiku drafts messages. Includes a first-launch onboarding flow where users paste real writing samples for instant profile generation.

## Key File

- `StyleEngine.swift` — `@MainActor ObservableObject` managing style.md, example collection, style analysis, and onboarding state

## How It Works

### Onboarding (First Launch)

Solves the **cold start problem** — without onboarding, the first 10+ drafts are generic because Draft doesn't know how you write yet.

1. After API key entry, `StyleOnboardingView` appears (gated by `hasCompletedOnboarding`)
2. User pastes real writing samples (Slack messages, texts, emails — messy is fine)
3. `importBulkSamples()` sends samples to **Sonnet** (not Haiku — deeper reasoning for style analysis) with a specialized `bulkAnalysisPrompt` that handles timestamps, sender names, reactions, and mixed-author content
4. Sonnet returns a comprehensive 400-600 word style profile analyzing 10 dimensions
5. Profile saved as initial Style Summary in `style.md`, raw samples saved as Onboarding Samples
6. User can review, add more samples and regenerate, or accept
7. "Skip for Now" is always available — the incremental system works without onboarding

### Collection (Incremental)

Every time the user accepts a draft (Copy or "Paste to Source App"), `recordExample(acceptedMessage:)` saves the polished output to `style.md`. Only the accepted message is saved — not the raw input or screenshot context.

### Analysis (Tiered)

Every 5 accepted examples, `regenerateStyleSummary()` sends ALL writing data to **Sonnet** with a style analysis prompt. The prompt scales with example count:

- **5-9 examples (Early):** Tone, sentence patterns, openings/closings, punctuation fingerprint, signature phrases
- **10-19 examples (Growing):** Adds argument structure, paragraph flow, emotional range, transition patterns
- **20+ examples (Mature):** Full persona — vocabulary signatures, contextual adaptation, rhetorical devices, what makes their writing uniquely theirs

When regenerating, both **onboarding samples AND accepted examples** are included so Sonnet has the full picture.

Uses `maxTokens: 4096` (vs. 1024 for regular drafts) and `AnthropicAPI.sonnetModel` since rich style profiles need deeper reasoning.

### Bulk Analysis Prompt vs. Tiered Prompts

The **bulk analysis prompt** (onboarding) is different from the tiered prompts:
- Designed for messy, raw pastes with timestamps, sender names, reactions, quoted text
- Tells Sonnet to ignore metadata and focus on HOW the person writes
- Uses the user's name to filter out other people's messages
- Analyzes all 10 dimensions immediately (enough data from the paste)

The **tiered prompts** (incremental) analyze only polished accepted drafts, scaling dimensions as more examples accumulate.

### Application

`buildSystemPrompt()` extracts only the Style Summary section (not examples) and wraps it in ghostwriting instructions. Tells Haiku to embody the user's voice — use their vocabulary, mirror their rhythms, match their energy. The prompt says "ghostwrite as this person" not just "match this style."

### Cost Model

Only the Style Summary is injected into the system prompt, not the raw examples. This means drafting cost stays constant regardless of example count (5 or 500). The analysis cost scales with examples but only runs every 5th draft.

## File Format (style.md)

```markdown
# Writing Style Profile

## Style Summary
[Sonnet-generated structured profile with labeled sections]

## Onboarding Samples
[Raw pasted writing from onboarding — may include timestamps, names, etc.]

## Accepted Examples

### Example 1
[accepted message text]

### Example 2
[accepted message text]
```

The `## Onboarding Samples` section only exists if the user completed the onboarding flow (not skipped).

## Public Interface

```swift
@Published var exampleCount: Int
@Published var styleFileContents: String
@Published var hasCompletedOnboarding: Bool     // Persisted to UserDefaults

func buildSystemPrompt() -> String              // Returns style-aware or default prompt
func recordExample(acceptedMessage: String)      // Saves accepted draft
func regenerateStyleSummary(apiKey: String) async // Triggers Sonnet analysis (includes onboarding samples)
func importBulkSamples(rawText: String, apiKey: String) async throws -> String  // Onboarding bulk import
func completeOnboarding()                        // Sets hasCompletedOnboarding = true
func getAPIKey() -> String?                      // Not on StyleEngine — use DraftEngine.getAPIKey()
```

## Storage

- **Style data:** `~/Library/Application Support/Draft/style.md`
- **Onboarding flag:** `UserDefaults` key `"style-onboarding-completed"`
- **User's name:** `UserDefaults` key `"user-display-name"` (set during onboarding, used for vision extraction too)
- **Format:** Markdown with structured sections, written atomically on every change
