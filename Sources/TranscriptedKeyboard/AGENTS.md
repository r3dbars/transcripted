# Transcripted Keyboard

## What this owns

Writing's IMKit input method, ported from Tilde's InlineGhostIME. It shows autocomplete as marked text in the host app, handles Tab / `` ` `` / Esc / type-through, and sends typing events to the app for Save my writing. It's its own process and its own bundle: `Transcripted Keyboard.app`, named "Transcripted" in Input Sources.

## Module

`Keyboard` in `.agents/modules.json`, compiled as its own executable. It may use WritingCore and nothing else in `Sources/`, and no app module may name its types (`check-module-boundaries.py` checks both).

## Entry points

- `main.swift` — starts the `IMKServer` with the connection name from `TildeProductProfile`; it must match `InputMethodConnectionName` in `Info.plist`.
- `GhostInputController.swift` — the controller: marked-text ghost, type-through, dictionary suffixes for partial words, chained accept, and phrase requests to the app. Interaction behavior comes from the app's served configuration, not this bundle.
- `GhostBrainClient.swift` — one cancellable streaming request over the app's owner-only unix socket. Cancelling closes the connection, which tells the app to stop inference.
- `PersonalHistoryCapture.swift` — memory-only batching of typing events (including Backspace inside its own text), sent to the app on a utility queue. The key callback only snapshots consent and enqueues.
- `GhostOutcomeLedger.swift`, `GhostProvenance.swift`, `GhostStats.swift` — the text-free outcome ledger and aggregate counters.
- `WritingAppScopeReader.swift` — reads the Writing tab's app scope from the keyboard's suite on each key; the scope gates suggestions as well as capture.
- `Info.plist` — the bundle's plist; the build stamps both version keys from the root `Info.plist`.

## How it's built

`scripts/entrypoints/lib/bundle-input-method.sh` compiles these files plus `Sources/TranscriptedWriting/Core/` into one module (Swift 5 mode, `-framework InputMethodKit`) and places the bundle at `Contents/Library/Input Methods/` in the app. `build.sh` and `build-beta.sh` sign it inside-out with `config/entitlements/keyboard.plist`. `scripts/entrypoints/lib/swiftc-app-args.sh` excludes this folder so the keyboard never lands in the app binary. At launch `KeyboardInstaller` copies it to `~/Library/Input Methods/` when missing or outdated.

## Rules

- **The keyboard never writes user text to disk.** The app owns every disk write. Accepted text lives in memory only for the kept-or-edited checks; the ledger records reason codes and counts.
- **No other insertion paths.** Ghosts are IMKit marked text only: no Accessibility inserts, overlays or fake paste. Suggestions stop under Secure Event Input.
- **Keys behave like Tilde.** See the table in `docs/writing-plan.md` ("Keyboard behavior"). In Electron hosts a stray Tab moves focus out of the field, so a Tab that lands mid-chain is held.
- **Core imports stay guarded** with `#if canImport(TranscriptedWritingCore)`, since the bundle script compiles Core into the same module.

## Tests

Keyboard tests are in `Tests/TranscriptedWritingTests/Runtime/` (`GhostInputControllerTests`, `PersonalHistoryCaptureTests`, `GhostStatsTests`, `WritingAppScopeTests`, and others that `@testable import TranscriptedKeyboard`).

```bash
swift test --filter '^TranscriptedWritingTests\.'
bash Tests/BuildDependencies/CLIPackagingTests.sh   # pins the signing calls
bash build.sh --no-open
```

Packaging changes also need `SKIP_NOTARIZATION=1 bash build-beta.sh '' <user>` (see `.agents/test-matrix.yml`). Real typing behavior needs a hand check in a signed build: Slack, Mail, Notes, Chrome and VS Code.
