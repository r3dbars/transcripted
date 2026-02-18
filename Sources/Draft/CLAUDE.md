# Draft Engine

## What This Does

Orchestrates the "rough text → polished message" workflow. Connects the speech capture (input) to the Anthropic API (processing) and exposes the result for the UI. Uses StyleEngine for personalized system prompts and PlatformFormatter for platform-native output.

## Key Files

- `DraftEngine.swift` — `@MainActor ObservableObject` managing API key state, drafting workflow, and output
- `PlatformFormatter.swift` — Detects target platform (Slack/iMessage/email/Discord/Teams) and provides formatting rules

## How It Works

### Two Drafting Modes

**Context-Aware Drafting** (`draftWithContext()`) — the primary mode:
1. Receives voice text + `CapturedContext` (from screenshot) + detected `PlatformFormatter`
2. Builds system prompt: style profile + platform formatting instructions
3. CapturedContext assembles the user message via `draftingPrompt(userInstructions:)` — conversation context + voice instructions with explicit priority hierarchy
4. Calls `AnthropicAPI.draft()` with assembled prompt
5. Applies `platform.postProcess()` as a safety net for formatting fixes
6. Stores result in `draftedText`

**Plain Drafting** (`draftMessage()`) — fallback when no screen context:
1. Takes raw text directly
2. Gets style-aware system prompt from `styleEngine.buildSystemPrompt()`
3. Calls `AnthropicAPI.draft()` with the style prompt
4. Stores result in `draftedText`

### PlatformFormatter

Detects the target messaging platform from the app's bundle identifier and provides two layers of formatting control:

**Prompt-level** (`formattingInstructions`): Appended to the system prompt. Tells Haiku how to format:
- **Slack** — `*bold*` not `**bold**`, `_italic_`, no `##` headers, short paragraphs
- **iMessage** — No markdown at all, plain text only, keep brief
- **Email** — Proper paragraphs, greeting/sign-off, markdown OK
- **Discord** — Standard markdown, conversational tone
- **Teams** — Standard markdown, clean and professional
- **Generic** — No special instructions

**Post-processing** (`postProcess()`): Regex-based safety net for when Haiku ignores formatting instructions:
- **Slack** — `**bold**` → `*bold*`, strips `##` headers
- **iMessage** — Strips ALL markdown formatting (bold, italic, headers)
- Others — Pass-through (markdown renders fine)

### Bundle ID Mapping

```
com.tinyspeck.slackmacgap  → .slack
com.apple.MobileSMS         → .imessage
com.apple.mail              → .email
com.hnc.Discord             → .discord
com.microsoft.teams2        → .teams
com.microsoft.teams         → .teams
(anything else)             → .generic
```

## Public Interface

```swift
// DraftEngine
@Published var draftedText: String    // Haiku's polished output (mutated by TextEditor edits)
@Published var originalDraft: String  // Snapshot of AI output before user edits (for style learning)
@Published var isDrafting: Bool       // Loading state
@Published var error: String?         // Error message if API fails
var hasCredential: Bool               // Whether Keychain has a credential stored
var styleEngine: StyleEngine?         // Set by ContentView after init
var authModeName: String              // "API Key", "Claude Subscription", or "None"

func saveAPIKey(_ key: String) -> Bool
func saveSubscriptionToken(_ token: String) -> Bool
func clearCredential()
func getAuth() -> AuthCredential?     // For style summary regeneration
func draftMessage(from rawText: String)                                          // Plain drafting
func draftWithContext(voiceText: String, context: CapturedContext?, platform: PlatformFormatter)  // Context-aware
func clear()

// PlatformFormatter
static func detect(from app: NSRunningApplication?) -> PlatformFormatter
var formattingInstructions: String    // System prompt addition
func postProcess(_ text: String) -> String  // Post-draft formatting fixes
```

## Dependencies

- `AnthropicAPI` (from API/)
- `KeychainHelper` (from API/)
- `StyleEngine` (from Style/) — optional reference for personalized prompts
- `CapturedContext` (from Capture/) — structured conversation context
- `PlatformFormatter` (local) — platform-specific formatting

## Design Notes

DraftEngine is intentionally separate from SpeechEngine. They don't know about each other — the UI coordinates them. StyleEngine is injected as an optional reference by ContentView, keeping the dependency lightweight. PlatformFormatter is detected at draft time from the paste target app.

## Verification

After modifying DraftEngine or PlatformFormatter, verify with these checks:

- **Plain draft:** Type text → hit Draft (no screen capture) → check debug log for `✨ DRAFT | sending N chars to Haiku` and `✅ DRAFTED`
- **Context-aware draft:** Capture a conversation (⌥Space) → speak instructions → Draft → check log for `✨ DRAFT | context-aware [platform] talking to [name]`
- **originalDraft snapshot:** Draft a message → edit the output text → accept → check `style.md` — `AI_DRAFT` should be the original, `USER_SENT` should be your edited version
- **Platform formatting:** Capture from Slack → draft → verify no `**bold**` or `## headers` in output (Slack uses `*bold*`). Capture from iMessage → verify no markdown at all.
- **PlatformFormatter detection:** Check debug log for platform name in brackets: `[slack]`, `[imessage]`, `[email]`, etc.
- **Error state:** If API fails, `drafter.error` should show a message in the UI (not crash)
