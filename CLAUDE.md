# Draft — Voice-to-Text → Polished Message

## What This Is

A macOS utility that captures rough spoken (or typed) thoughts and uses Claude Haiku to polish them into well-crafted messages matching the user's personal writing style. Features global hotkey screen capture for full conversation context extraction and platform-aware formatting. Built with SwiftUI, Apple Speech Framework, and the Anthropic Messages API.

## Architecture

```
Sources/
├── DraftApp.swift           ← @main entry point only
├── Speech/                  ← Voice capture engine (Apple SFSpeechRecognizer)
├── API/                     ← Anthropic API client (text + vision) + Keychain storage
├── Draft/                   ← DraftEngine + PlatformFormatter — orchestrates drafting
├── Style/                   ← StyleEngine — learns user's writing voice + onboarding
├── Capture/                 ← Screen capture, context extraction, CapturedContext struct
└── UI/                      ← SwiftUI views, onboarding, app tracker, debug logger
```

**Each subfolder in Sources/ has its own CLAUDE.md with component-specific knowledge. Read the relevant CLAUDE.md before modifying any file in that folder.**

## Build & Run

```bash
cd /Users/****/Draft
bash build.sh
```

This compiles all Swift files from `Sources/`, signs the app bundle, and launches it.

## Key Features

- **Voice-to-text** — Speak rough thoughts, Draft polishes them via Haiku
- **Full conversation context** — Ctrl+Option+D screenshots the current app, Haiku Vision extracts the entire visible conversation thread (all messages, participants, platform, formality)
- **Platform-aware formatting** — Detects Slack/iMessage/email/Discord/Teams and adjusts drafting style (e.g., no subject lines for Slack, casual for iMessage)
- **Style learning** — Every accepted draft teaches Draft your writing style; tiered analysis deepens with more examples
- **Style onboarding** — New users paste real writing samples on first launch; Sonnet builds an immediate style profile (no cold start)
- **Paste to source app** — Pastes the polished message back to the exact app that was screenshotted, with activation polling for reliability
- **Frictionless keyboard flow** — Enter in input → Draft, Enter in output → Paste to source app, Shift+Enter → newline

## Key Decisions

- **Single binary, no Xcode project** — compiled with `swiftc` directly via `build.sh`
- **Zero third-party dependencies** — only Apple frameworks and URLSession for HTTP
- **API key in macOS Keychain** — not UserDefaults, not hardcoded, not env vars
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
5. **SwiftUI `.onKeyPress` needs the `keys:phases:` variant** — the single-key form `onKeyPress(.return)` doesn't expose modifiers, so you can't distinguish Enter from Shift+Enter. Use `onKeyPress(keys: [.return], phases: .down)` which passes the full `KeyPress` object
6. **SwiftUI type-checker has limits** — complex `body` with inline closures can exceed Swift's type-check timeout. Fix: extract views into separate `@ViewBuilder` computed properties
7. **Haiku confuses message content with metadata** — the vision prompt must explicitly say "look at the conversation HEADER/TITLE BAR for the contact name, NOT names mentioned inside messages"

## Frameworks Linked

- `SwiftUI` — UI
- `AVFoundation` — Audio engine / microphone
- `Speech` — Apple Speech recognition
- `Security` — Keychain access
- `AppKit` — macOS-specific (NSPasteboard, NSWorkspace, NSRunningApplication)
- `Carbon` — Global hotkey registration (RegisterEventHotKey)
- `CoreGraphics` — Window capture (CGWindowListCreateImage)
- `Combine` — Required by SwiftUI internally
