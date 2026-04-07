# Draft Engine

## What This Does

Lightweight state holder for the drafting flow. DraftEngine stores the original AI draft (for style learning comparisons) and holds references to StyleEngine and PromptStore. The actual drafting orchestration -- prompt assembly, streaming generation, vision context -- happens in `DraftSessionController` (Sources/UI/), which calls `MLXEngine.generate()` directly. PlatformFormatter detects the target messaging platform and provides formatting rules. DraftUtils contains refusal detection.

## Key Files

- `DraftEngine.swift` (26 lines) -- `@MainActor ObservableObject` that holds draft state: `originalDraft`, `lastRawText`, and optional references to `StyleEngine` and `PromptStore`. Has a single `clear()` method.
- `PlatformFormatter.swift` (104 lines) -- Detects target platform (Slack/iMessage/email/Discord/Teams) from bundle identifier and provides two layers of formatting control: prompt-level instructions and regex post-processing.
- `DraftUtils.swift` (28 lines) -- Stateless enum with `looksLikeRefusal()`: checks if a draft is the model refusing/asking for clarification rather than an actual message. Detects 13 refusal phrases. Used by `DraftSessionController` to skip recording refusals as training pairs.

## How It Works

### DraftEngine (State Holder)

DraftEngine is not an orchestrator. It holds three pieces of state:

- `originalDraft` (`@Published`) -- Snapshot of the AI's output before the user edits it in the overlay TextEditor. Used by StyleEngine to compute edit distance between what the AI produced and what the user accepted.
- `lastRawText` -- The raw voice transcription from the user's last draft request. Exposed for FeedbackStore logging.
- `styleEngine` / `promptStore` -- Optional references set by `DraftAppState.initialize()` during boot. Not used by DraftEngine itself -- exposed so other components can access them through `appState.drafter`.

`clear()` resets both `originalDraft` and `lastRawText` to empty strings.

### Active Drafting Path

The actual drafting flow lives in `DraftSessionController` (Sources/UI/). The path:

1. Receives voice text + context (from LocalVisionExtractor OCR) + detected `PlatformFormatter`
2. Builds system prompt: style profile + platform formatting instructions
3. Assembles the user message with conversation context + voice instructions
4. Calls `MLXEngine.generate(prompt:systemPrompt:maxTokens:)` -- returns `AsyncThrowingStream<String, Error>`
5. Tokens stream into the floating overlay in real-time (~30-50 tok/s on Apple Silicon)
6. Applies `platform.postProcess()` as a safety net for formatting fixes
7. Stores the final draft in `DraftEngine.originalDraft` for style learning

### PlatformFormatter

Detects the target messaging platform from the app's bundle identifier and provides two layers of formatting control:

**Prompt-level** (`formattingInstructions`): Appended to the system prompt. Tells the model how to format:
- **Slack** -- `*bold*` not `**bold**`, `_italic_`, no `##` headers, short paragraphs
- **iMessage** -- No markdown at all, plain text only, keep brief
- **Email** -- Proper paragraphs, greeting/sign-off, markdown OK
- **Discord** -- Standard markdown, conversational tone
- **Teams** -- Standard markdown, clean and professional
- **Generic** -- No special instructions

**Post-processing** (`postProcess()`): Pre-compiled regex safety net for when the model ignores formatting instructions:
- **Slack** -- `**bold**` -> `*bold*`, strips `##` headers
- **iMessage** -- Strips ALL markdown formatting (bold, italic, headers)
- Others -- Pass-through (markdown renders fine)

Four regexes are compiled once as static properties (`boldRegex`, `italicAsteriskRegex`, `italicUnderscoreRegex`, `headerRegex`) to avoid recompilation per draft.

### Bundle ID Mapping

```
com.tinyspeck.slackmacgap  -> .slack
com.apple.MobileSMS         -> .imessage
com.apple.mail              -> .email
com.hnc.Discord             -> .discord
com.microsoft.teams2        -> .teams
com.microsoft.teams         -> .teams
(anything else)             -> .generic
```

### DraftUtils -- Refusal Detection

`looksLikeRefusal()` checks if a draft contains phrases indicating the model refused or asked for clarification instead of producing an actual message. Covers 13 phrases in three categories:

- **Missing context requests:** "i need the actual", "could you provide", "i'd need to see", "please provide", "i don't have enough"
- **Readiness/deflection:** "i'm ready to help", "i can't write", "go ahead and share", "what did the person say"
- **Screenshot/content descriptions:** "the screenshot shows", "i don't see a conversation", "not a messaging conversation", "i need more context"

Used by `DraftSessionController.confirmAndInject()` to skip recording refusals as training pairs, preventing style profile poisoning.

## Public Interface

```swift
// DraftEngine (@MainActor ObservableObject)
@Published var originalDraft: String    // AI's output before user edits
var styleEngine: StyleEngine?           // Set by DraftAppState.initialize()
var promptStore: PromptStore?           // Set by DraftAppState.initialize()
var lastRawText: String                 // Raw voice text from last draft
func clear()                            // Resets originalDraft and lastRawText

// PlatformFormatter (enum, CaseIterable)
static func detect(from app: NSRunningApplication?) -> PlatformFormatter
var formattingInstructions: String       // System prompt addition
func postProcess(_ text: String) -> String  // Post-draft formatting fixes

// DraftUtils (stateless enum)
static func looksLikeRefusal(_ text: String) -> Bool
```

## Dependencies

- `StyleEngine` (from Style/) -- optional reference for personalized prompts (held, not called)
- `PromptStore` (from Prompts/) -- optional reference for prompt templates (held, not called)
- `AppKit` -- `NSRunningApplication` for platform detection
- `CapturedContext` (from Capture/) -- consumed by DraftSessionController, not DraftEngine directly

Note: DraftEngine has no dependency on MLXEngine, AnthropicAPI, or any network/inference layer. It is purely a state container.

## Design Notes

DraftEngine is intentionally minimal. It was originally an orchestrator that called AnthropicAPI directly, but that responsibility moved to DraftSessionController when the app switched to local inference. DraftEngine remains as the canonical location for draft state because multiple components need to read `originalDraft` (StyleEngine for training pairs, FeedbackStore for logging).

PlatformFormatter is stateless and deterministic -- safe to call from any context. The pre-compiled regexes avoid per-draft compilation overhead.

## Verification

After modifying any file in this folder:

```bash
bash build.sh && bash run-tests.sh
```

- **Platform formatting:** Capture from Slack -> draft -> verify no `**bold**` or `## headers` in output. Capture from iMessage -> verify no markdown at all.
- **PlatformFormatter detection:** Check debug log for platform name.
- **originalDraft snapshot:** Draft a message -> edit the output text -> accept -> check `style.md` -- `AI_DRAFT` should be the original, `USER_SENT` should be your edited version.
- **Refusal detection:** `DraftUtils.looksLikeRefusal()` should catch model refusals and prevent them from being recorded as training pairs. Covered by unit tests in `Tests/DraftUtilsTests.swift`.
- **State clearing:** After `clear()`, both `originalDraft` and `lastRawText` should be empty strings.
