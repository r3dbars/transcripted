# Draft Engine

## What This Does

Orchestrates the "rough text -> polished message" workflow. The active drafting path runs entirely on-device via MLXEngine (Qwen3.5-4B-4bit). PlatformFormatter detects the target messaging platform and provides formatting rules. DraftUtils contains the refusal detection utility.

## Key Files

- `DraftEngine.swift` (154 lines) -- `@MainActor ObservableObject` with legacy API-calling methods (`draftWithContext`, `draftMessage`). These are no longer the active path. The live drafting flow goes through `DraftSessionController` -> `MLXEngine.generate()` directly.
- `PlatformFormatter.swift` (118 lines) -- Detects target platform (Slack/iMessage/email/Discord/Teams) and provides formatting rules
- `DraftUtils.swift` (~25 lines) -- Extracted pure utility: `looksLikeRefusal()` checks if a draft is the model refusing rather than actually drafting. Used by `DraftSessionController` to skip recording refusals as training pairs. Detects 13 refusal phrases covering: missing context requests ("i need the actual", "could you provide"), readiness declarations ("i'm ready to help"), screenshot descriptions ("the screenshot shows", "i don't see a conversation"), and wrong-content indicators ("not a messaging conversation").

## How It Works

### Active Drafting Path (DraftSessionController -> MLXEngine)

The floating overlay flow in `DraftSessionController` (in `Sources/UI/DraftSessionController.swift`) calls `MLXEngine.generate()` directly for streaming token-by-token output. This is the only active drafting path. The flow:

1. Receives voice text + context (from Apple Vision OCR) + detected `PlatformFormatter`
2. Builds system prompt: style profile + platform formatting instructions
3. Assembles the user message with conversation context + voice instructions
4. Calls `MLXEngine.generate(prompt:systemPrompt:maxTokens:)` -- returns `AsyncThrowingStream<String, Error>`
5. Tokens stream into the floating overlay in real-time (~30-50 tok/s on Apple Silicon)
6. Applies `platform.postProcess()` as a safety net for formatting fixes

### DraftEngine (Legacy)

`DraftEngine.swift` is still compiled but its `draftWithContext()` and `draftMessage()` methods are legacy from the API era. They are not called in the active flow. DraftEngine remains as a lightweight `@MainActor ObservableObject` for any residual state management.

### PlatformFormatter

Detects the target messaging platform from the app's bundle identifier and provides two layers of formatting control:

**Prompt-level** (`formattingInstructions`): Appended to the system prompt. Tells the model how to format:
- **Slack** -- `*bold*` not `**bold**`, `_italic_`, no `##` headers, short paragraphs
- **iMessage** -- No markdown at all, plain text only, keep brief
- **Email** -- Proper paragraphs, greeting/sign-off, markdown OK
- **Discord** -- Standard markdown, conversational tone
- **Teams** -- Standard markdown, clean and professional
- **Generic** -- No special instructions

**Post-processing** (`postProcess()`): Regex-based safety net for when the model ignores formatting instructions:
- **Slack** -- `**bold**` -> `*bold*`, strips `##` headers
- **iMessage** -- Strips ALL markdown formatting (bold, italic, headers)
- Others -- Pass-through (markdown renders fine)

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

## Public Interface

```swift
// DraftEngine (legacy -- not used in active drafting path)
@Published var draftedText: String       // Model's polished output
@Published var originalDraft: String     // Snapshot of model output before user edits (for style learning)
@Published var isDrafting: Bool          // Loading state
@Published var error: String?            // Error message if drafting fails
var styleEngine: StyleEngine?            // Set after init
var promptStore: PromptStore?            // Set after init
var lastRawText: String                  // The raw user input from the last draft

func draftMessage(from rawText: String)                                          // Legacy plain drafting
func draftWithContext(voiceText: String, context: CapturedContext?, platform: PlatformFormatter)  // Legacy context-aware
func clear()

// PlatformFormatter
static func detect(from app: NSRunningApplication?) -> PlatformFormatter
var formattingInstructions: String    // System prompt addition
func postProcess(_ text: String) -> String  // Post-draft formatting fixes
```

## Dependencies

- `MLXEngine` (from Local/) -- on-device LLM inference (called by DraftSessionController, not DraftEngine directly)
- `StyleEngine` (from Style/) -- optional reference for personalized prompts
- `PromptStore` (from Prompts/) -- provides configurable prompt templates
- `DefaultPrompts` (from Prompts/) -- fallback prompt constants
- `CapturedContext` (from Capture/) -- structured conversation context (now populated by Apple Vision OCR)
- `PlatformFormatter` (local) -- platform-specific formatting
- `EventReporter` (from Observability/) -- error/warning event logging

## Design Notes

DraftEngine is intentionally separate from the speech engine. They don't know about each other -- the UI coordinates them. StyleEngine is injected as an optional reference, keeping the dependency lightweight. PlatformFormatter is detected at draft time from the paste target app.

**Active path:** `DraftSessionController` calls `MLXEngine.generate()` directly for streaming drafts. DraftEngine's `draftWithContext()` and `draftMessage()` are legacy methods preserved for compatibility but not invoked in the current flow. PlatformFormatter is still used by both paths.

## Verification

After modifying DraftEngine or PlatformFormatter, verify with these checks:

- **Streaming draft:** Capture a conversation (Option+D) -> speak instructions -> Option+D -> verify tokens stream into the overlay in real-time
- **originalDraft snapshot:** Draft a message -> edit the output text -> accept -> check `style.md` -- `AI_DRAFT` should be the original, `USER_SENT` should be your edited version
- **Platform formatting:** Capture from Slack -> draft -> verify no `**bold**` or `## headers` in output (Slack uses `*bold*`). Capture from iMessage -> verify no markdown at all.
- **PlatformFormatter detection:** Check debug log for platform name in brackets: `[slack]`, `[imessage]`, `[email]`, etc.
- **Refusal detection:** DraftUtils.looksLikeRefusal() should catch model refusals and prevent them from being recorded as training pairs
- **Error state:** If drafting fails, the overlay should show an error message, not crash
