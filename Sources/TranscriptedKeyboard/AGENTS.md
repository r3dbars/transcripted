# Transcripted Keyboard

Lightweight capture-only IMKit input method for opt-in **"Save my writing"**. It never renders marked text, never intercepts or alters keystrokes (always returns `false` from `handle(_:client:)` so the host app handles every key natively), and forwards typed text and tracked Backspaces to Transcripted over the owner-only unix socket when the user has opted in.

It is its own process and bundle: `Transcripted Keyboard.app`, named "Transcripted" in Input Sources. The app side is `Sources/Writing/AGENTS.md`; the shared library is `Sources/TranscriptedWriting/AGENTS.md`.

## Module

`Keyboard` in `.agents/modules.json`, compiled as its own executable. It may use WritingCore (`Sources/TranscriptedWriting/Core/`, module `TranscriptedWritingCore`) and nothing else in `Sources/`. No app module may name its types. `check-module-boundaries.py` checks both directions.

## Rules

- **The keyboard never writes user text to disk.** The app owns every disk write.
- **Capture-only pass-through.** Never draws marked text, never consumes keys, stops immediately under Secure Event Input, password managers (`DefaultExcludedApps`), modifier shortcuts, or pause.
- **Key callbacks stay cheap.** `PersonalHistoryCapture` only snapshots consent/scope and enqueues; socket delivery runs on a utility queue.
- **A segment chain survives a host's stale caret.** Save my writing's chain breaks on a caret jump, judged by `PersonalHistoryCaretContinuity` (Core).
- **Core imports stay behind `#if canImport(TranscriptedWritingCore)`**, because the bundle script compiles Core into the same module as these files.

## Files

- `main.swift` starts the `IMKServer`. Its connection name comes from `TildeProductProfile` and must match `InputMethodConnectionName` in `Info.plist`.
- `GhostInputController.swift` is the capture-only IMKit controller (`@objc(GhostInputController)`).
- `GhostBrainClient.swift` sends capture batches over the app's owner-only unix socket.
- `PersonalHistoryCapture.swift` batches typing events in memory (Backspace inside its own text included) and sends them to the app on a utility queue.
- `WritingAppScopeReader.swift` reads the app scope (`All apps` vs `Picked apps`) from the keyboard's defaults suite on every key.
- `Info.plist`: the build stamps both version keys from the root `Info.plist`.

## How it's built

`scripts/entrypoints/lib/bundle-input-method.sh` compiles these files plus `Sources/TranscriptedWriting/Core/` into one module (Swift 5 mode, `-framework InputMethodKit`) and places the bundle at `Contents/Library/Input Methods/` in the app. `build.sh` and `build-beta.sh` sign it inside-out with `config/entitlements/keyboard.plist`. `scripts/entrypoints/lib/swiftc-app-args.sh` excludes this folder so the keyboard never lands in the app binary.

## Tests

Keyboard tests live in `Tests/TranscriptedWritingTests/Runtime/` and `@testable import TranscriptedKeyboard`: `GhostInputControllerTests`, `PersonalHistoryCaptureTests`, `PersonalHistoryDeletionTests`, `PersonalHistoryRetryTests`, `WritingAppScopeTests`.

```bash
TRANSCRIPTED_DISABLE_FILE_LOGGER=1 swift test --filter '^TranscriptedWritingTests\.'
bash build.sh --no-open
```
