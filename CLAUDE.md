# Draft — Voice-to-Text → Polished Message

## What This Is

A macOS utility that captures rough spoken (or typed) thoughts and uses Claude Haiku to polish them into well-crafted messages matching the user's personal writing style. Features global hotkey screen capture for full conversation context extraction and platform-aware formatting. Built with SwiftUI, Apple Speech Framework, and the Anthropic Messages API.

## Architecture

```
Sources/
├── DraftApp.swift           ← @main entry point only
├── Speech/                  ← Voice capture engine (Apple SFSpeechRecognizer)
├── API/                     ← Anthropic API client (text + vision) + AuthCredential + Keychain
├── Draft/                   ← DraftEngine + PlatformFormatter — orchestrates drafting
├── Style/                   ← StyleEngine — learns user's writing voice + onboarding
├── Messages/                ← iMessage database reader (SQLite, onboarding import)
├── Capture/                 ← Screen capture, context extraction, CapturedContext struct
└── UI/                      ← SwiftUI views, onboarding, app tracker, debug logger
```

**Each subfolder in Sources/ has its own CLAUDE.md with component-specific knowledge. Read the relevant CLAUDE.md before modifying any file in that folder.**

## Build & Run

```bash
cd /Users/justin.betker/Draft
bash build.sh
```

This compiles all Swift files from `Sources/`, signs the app bundle, and launches it.

## Key Features

- **Voice-to-text** — Speak rough thoughts, Draft polishes them via Haiku
- **Full conversation context** — Option+Space screenshots the current app, Haiku Vision extracts the entire visible conversation thread (all messages, participants, platform, formality)
- **Platform-aware formatting** — Detects Slack/iMessage/email/Discord/Teams and adjusts drafting style (e.g., no subject lines for Slack, casual for iMessage)
- **Style learning** — Every accepted draft saves a training pair (AI output vs. what you actually sent); Sonnet incrementally refines your style profile with graduated frequency
- **Style onboarding** — New users can import iMessages automatically (recommended) or paste samples manually; Sonnet builds an immediate style profile (no cold start)
- **Combined onboarding** — iMessage import path includes optional "Add Slack, email, or other writing samples" section to supplement with additional sources for a richer profile
- **iMessage import** — Optional onboarding path that reads `~/Library/Messages/chat.db` for zero-effort style profile generation (requires Full Disk Access)
- **Paste to source app** — Pastes the polished message back to the exact app that was screenshotted, with activation polling for reliability
- **Frictionless keyboard flow** — Enter in input → Draft, Enter in output → Paste to source app, Shift+Enter → newline

## End-to-End Data Flow

### Hotkey → Draft → Accept Pipeline (the primary flow)

```
1. User presses Option+Space in Slack/iMessage/etc.
   │
   ├─→ [SYNC in C callback] Capture frontApp + screenshot (before focus shifts)
   │
   ├─→ [PARALLEL A] Start voice recording (SpeechEngine.startListening())
   │                 └─→ User speaks instructions while vision processes
   │
   └─→ [PARALLEL B] Send screenshot to Haiku Vision (AnthropicAPI.extractStructuredContext())
                     └─→ Returns CapturedContext (platform, talkingTo, formality, conversation)
                     └─→ Injected at TOP of inputText via textBeforeRecording

2. Both complete → triggerAutoDraft() OR user presses Enter
   │
   ├─→ CapturedContext.draftingPrompt(userInstructions:) assembles full prompt
   ├─→ StyleEngine.buildSystemPrompt() adds style profile
   ├─→ PlatformFormatter adds formatting instructions to system prompt
   └─→ AnthropicAPI.draft() → result → PlatformFormatter.postProcess()
       └─→ draftedText (displayed in output TextEditor, editable by user)
       └─→ originalDraft (frozen snapshot for style learning)

3. User edits draft (optional) → presses Enter or clicks "Paste to [App]"
   │
   ├─→ recordAcceptedExample()
   │   ├─→ styleEngine.recordExample(aiDraft: originalDraft, userFinal: draftedText, platform)
   │   ├─→ Training pair saved to style.md (AI_DRAFT vs USER_SENT + edit distance)
   │   └─→ shouldRefineNow() → maybe triggers Sonnet refinement (last 20 examples)
   │
   └─→ pasteToApp() → activate source app → poll isActive → simulate ⌘V
```

### Plain Draft Pipeline (no screenshot)

```
User types/speaks in input → Enter → DraftEngine.draftMessage()
└─→ StyleEngine.buildSystemPrompt() + raw text → AnthropicAPI.draft() → output
```

## Common Modifications Playbook

### To add a new messaging platform (e.g., LinkedIn):

1. **`Sources/Draft/PlatformFormatter.swift`** — Add `case linkedin` to the enum, add bundle ID in `detect()`, add `formattingInstructions` for the platform, add `postProcess()` rules if markdown needs fixing
2. **`Sources/Draft/CLAUDE.md`** — Add to the bundle ID mapping table
3. **Test** — Open the target app, capture with ⌥Space, verify platform detection in debug log

### To add new metadata to training pairs:

1. **`Sources/Style/StyleEngine.swift`** — Add the field to the `exampleBlock` string in `recordExample()`, update `extractRecentEditDistances()` if it's a parseable metric
2. **`Sources/UI/ContentView.swift`** — Pass the new data into `recordExample()` from `recordAcceptedExample()` (~line 587)
3. **`Sources/Style/StyleEngine.swift`** — Update `buildRefinementPrompt()` to tell Sonnet about the new field
4. **`Sources/Style/CLAUDE.md`** — Update the file format example

### To change the refinement logic:

1. **`Sources/Style/StyleEngine.swift`** — Modify `shouldRefineNow()` for frequency, `extractRecentExamplesText(last:)` for window size, `buildRefinementPrompt()` for what Sonnet sees
2. **`Sources/UI/ContentView.swift`** — The call site at `recordAcceptedExample()` (~line 597) just calls `shouldRefineNow()` — usually no changes needed here

### To modify the vision extraction prompt:

1. **`Sources/API/AnthropicAPI.swift`** — Edit `contextExtractionPrompt()` (~line 74)
2. **`Sources/Capture/CapturedContext.swift`** — If adding new labeled fields, update `parse()` and the struct properties
3. **`Sources/Capture/CLAUDE.md`** — Update CapturedContext struct docs

### To add a new UI feature/tab:

1. **`Sources/UI/ContentView.swift`** — Add to the `TabView` in `ContentView.body` (~line 17)
2. Define the new view in a separate file in `Sources/UI/`
3. **`Sources/UI/CLAUDE.md`** — Document the new view and its purpose

## Git & GitHub

Before committing or pushing, always switch to the **r3dbars** GitHub account:
```bash
gh auth switch --user r3dbars
```
Repo-level git config is already set (`user.name: r3dbars`, `user.email: r3dbars@users.noreply.github.com`). The auth switch ensures push credentials match.

A `/push` slash command is available (`.claude/commands/push.md`) that handles the full flow: auth switch → stage → commit → push.

## Key Decisions

- **Single binary, no Xcode project** — compiled with `swiftc` directly via `build.sh`
- **Zero third-party dependencies** — only Apple frameworks and URLSession for HTTP
- **Credentials in macOS Keychain** — not UserDefaults, not hardcoded, not env vars
- **Two auth modes supported** — API key (`x-api-key`) OR Claude subscription token (`Authorization: Bearer`) via `AuthCredential` enum. See `Sources/API/CLAUDE.md`.
- **Sandbox disabled** (`com.apple.security.app-sandbox: false`) — required for microphone + screen capture
- **Carbon RegisterEventHotKey** for global hotkey — OS-level interception, works in any app
- **Synchronous screenshot in hotkey callback** — captures frontmost app + screenshot before window focus shifts to Draft
- **Plain-text vision extraction** — Haiku Vision returns labeled sections (PLATFORM/TALKING TO/FORMALITY/CONVERSATION), parsed by `CapturedContext.parse()`. No JSON — simpler and handles variable-length conversations
- **Source app stored on capture** — The exact `NSRunningApplication` is saved at hotkey time, so paste-back targets the right app even if focus changes

## Project-Wide Learnings

1. **Apple Speech buffer resets are undocumented** — see `Sources/Speech/CLAUDE.md`
2. **No official Anthropic Swift SDK** — raw URLSession with Codable + JSONSerialization for vision
3. **`swiftc` multi-file compilation** — `$(find Sources -name '*.swift')` in build.sh
4. **Global hotkey timing is critical** — screenshot AND frontmost app reference must be captured synchronously in the C callback before any `Task { @MainActor }` dispatch, or window focus shifts and you capture Draft instead of the target app
5. **Claude subscription auth uses Bearer token, not x-api-key** — users generate it via `claude setup-token` (Claude Code CLI). Anthropic blocked third-party PKCE OAuth in Jan 2026; setup-token is the sanctioned path. Tokens expire and must be regenerated.
6. **Auth is abstracted behind `AuthCredential`** — never pass raw `apiKey: String` around. Use `AuthCredential.load()` and `auth.apply(to: &request)`. Switching modes clears the other credential from Keychain.
7. **SwiftUI `.onKeyPress` needs the `keys:phases:` variant** — the single-key form `onKeyPress(.return)` doesn't expose modifiers, so you can't distinguish Enter from Shift+Enter. Use `onKeyPress(keys: [.return], phases: .down)` which passes the full `KeyPress` object
8. **SwiftUI type-checker has limits** — complex `body` with inline closures can exceed Swift's type-check timeout. Fix: extract views into separate `@ViewBuilder` computed properties
9. **Haiku confuses message content with metadata** — the vision prompt must explicitly say "look at the conversation HEADER/TITLE BAR for the contact name, NOT names mentioned inside messages"
10. **Pro audio interfaces break SFSpeechRecognizer** — USB interfaces like BEACN Mic (96kHz/4ch) cause error 1110 "no speech detected." Fix: force mono tap format (`AVAudioFormat(standardFormatWithSampleRate: nativeRate, channels: 1)`) — AVAudioEngine handles the channel mixdown automatically
11. **iMessage `text` stores U+FFFC for attachment-only messages** — 558 out of 625 messages can be this invisible placeholder character. Filter by `trimmed.count < 2`, not word count

## Frameworks Linked

- `SwiftUI` — UI
- `AVFoundation` — Audio engine / microphone
- `Speech` — Apple Speech recognition
- `Security` — Keychain access
- `AppKit` — macOS-specific (NSPasteboard, NSWorkspace, NSRunningApplication)
- `Carbon` — Global hotkey registration (RegisterEventHotKey)
- `CoreGraphics` — Window capture (CGWindowListCreateImage)
- `Combine` — Required by SwiftUI internally
- `SQLite3` (via `-lsqlite3`) — iMessage database reading for style onboarding
