# Draft — Voice-to-Text → Polished Message

## What This Is

A macOS utility that captures rough spoken (or typed) thoughts and uses Claude Haiku to polish them into well-crafted messages. Built with SwiftUI, Apple Speech Framework, and the Anthropic Messages API.

## Architecture

```
Sources/
├── DraftApp.swift           ← @main entry point only
├── Speech/                  ← Voice capture engine (Apple SFSpeechRecognizer)
├── API/                     ← Anthropic API client + Keychain storage
├── Draft/                   ← DraftEngine — orchestrates speech → API → output
└── UI/                      ← SwiftUI views (ContentView, APIKeyEntryView)
```

**Each subfolder in Sources/ has its own CLAUDE.md with component-specific knowledge. Read the relevant CLAUDE.md before modifying any file in that folder.**

## Build & Run

```bash
cd /Users/justin.betker/Draft
bash build.sh
```

This compiles all Swift files from `Sources/`, signs the app bundle, and launches it.

## Key Decisions

- **Single binary, no Xcode project** — compiled with `swiftc` directly via `build.sh`
- **Zero third-party dependencies** — only Apple frameworks (SwiftUI, Speech, AVFoundation, Security) and URLSession for HTTP
- **API key in macOS Keychain** — not UserDefaults, not hardcoded, not env vars
- **Sandbox disabled** (`com.apple.security.app-sandbox: false`) — required for microphone access without full Xcode provisioning

## Project-Wide Learnings

1. **Apple Speech buffer resets are undocumented** — see `Sources/Speech/CLAUDE.md` for the full story. This was the hardest bug to find.
2. **No official Anthropic Swift SDK** — we use raw URLSession. See `Sources/API/CLAUDE.md` for the request/response format.
3. **`swiftc` multi-file compilation** — use `$(find Sources -name '*.swift')` in build.sh to compile all source files together. No module maps needed.

## Frameworks Linked

- `SwiftUI` — UI
- `AVFoundation` — Audio engine / microphone
- `Speech` — Apple Speech recognition
- `Security` — Keychain access
- `AppKit` — macOS-specific (NSPasteboard, NSColor)
- `Combine` — Required by SwiftUI internally
