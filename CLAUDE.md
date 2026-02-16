# Draft — Voice-to-Text → Polished Message

## What This Is

A macOS utility that captures rough spoken (or typed) thoughts and uses Claude Haiku to polish them into well-crafted messages matching the user's personal writing style. Features global hotkey screen capture for conversation context extraction. Built with SwiftUI, Apple Speech Framework, and the Anthropic Messages API.

## Architecture

```
Sources/
├── DraftApp.swift           ← @main entry point only
├── Speech/                  ← Voice capture engine (Apple SFSpeechRecognizer)
├── API/                     ← Anthropic API client (text + vision) + Keychain storage
├── Draft/                   ← DraftEngine — orchestrates speech → API → output
├── Style/                   ← StyleEngine — learns user's writing voice over time
├── Capture/                 ← Screen capture + context extraction via Haiku Vision
└── UI/                      ← SwiftUI views, app tracker, debug logger
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
- **Context capture** — Ctrl+Option+D screenshots the current app, Haiku Vision extracts conversation text
- **Style learning** — Every accepted draft teaches Draft your writing style; tiered analysis deepens with more examples
- **Paste to last app** — One click copies the polished message back to Slack/iMessage/etc.

## Key Decisions

- **Single binary, no Xcode project** — compiled with `swiftc` directly via `build.sh`
- **Zero third-party dependencies** — only Apple frameworks and URLSession for HTTP
- **API key in macOS Keychain** — not UserDefaults, not hardcoded, not env vars
- **Sandbox disabled** (`com.apple.security.app-sandbox: false`) — required for microphone + screen capture
- **Carbon RegisterEventHotKey** for global hotkey — OS-level interception, works in any app
- **Synchronous screenshot in hotkey callback** — captures before window focus shifts to Draft

## Project-Wide Learnings

1. **Apple Speech buffer resets are undocumented** — see `Sources/Speech/CLAUDE.md`
2. **No official Anthropic Swift SDK** — raw URLSession with Codable + JSONSerialization for vision
3. **`swiftc` multi-file compilation** — `$(find Sources -name '*.swift')` in build.sh
4. **Global hotkey timing is critical** — screenshot must happen synchronously in the C callback before any `Task { @MainActor }` dispatch, or window focus shifts and you capture Draft instead of the target app
5. **SwiftUI keyboard shortcuts are window-scoped** — they intercept before text fields, so don't use unmodified Space as a shortcut

## Frameworks Linked

- `SwiftUI` — UI
- `AVFoundation` — Audio engine / microphone
- `Speech` — Apple Speech recognition
- `Security` — Keychain access
- `AppKit` — macOS-specific (NSPasteboard, NSWorkspace, NSRunningApplication)
- `Carbon` — Global hotkey registration (RegisterEventHotKey)
- `CoreGraphics` — Window capture (CGWindowListCreateImage)
- `Combine` — Required by SwiftUI internally
