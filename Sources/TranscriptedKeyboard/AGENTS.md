# Transcripted Keyboard

Writing's IMKit input method, ported from Tilde's InlineGhostIME. It shows autocomplete as marked text in the host app, handles Tab / `` ` `` / Esc / type-through, and sends typing events to the app for Save my writing. It is its own process and bundle: `Transcripted Keyboard.app`, named "Transcripted" in Input Sources. The app side is `Sources/Writing/AGENTS.md`; the shared library is `Sources/TranscriptedWriting/AGENTS.md`.

## Module

`Keyboard` in `.agents/modules.json`, compiled as its own executable. It may use WritingCore (`Sources/TranscriptedWriting/Core/`, module `TranscriptedWritingCore`) and nothing else in `Sources/`. No app module may name its types. `check-module-boundaries.py` checks both directions.

## Rules

- **The keyboard never writes user text to disk.** The app owns every disk write. Accepted text lives in memory only for the kept-or-edited checks; the ledger records reason codes and counts.
- **Ghosts are IMKit marked text only.** No Accessibility inserts, overlays, or fake paste. Suggestions stop under Secure Event Input.
- **Keys behave like Tilde.** The table is "Keyboard behavior" in `docs/writing-plan.md`. In Electron hosts a stray Tab moves focus out of the field, so a Tab that lands mid-chain is held.
- **Key callbacks stay cheap.** Sampling and capture run after the callback returns; `PersonalHistoryCapture` only snapshots consent and enqueues.
- **Core imports stay behind `#if canImport(TranscriptedWritingCore)`**, because the bundle script compiles Core into the same module as these files.
- Interaction behavior comes from the app's served configuration, not from this bundle.

## Files

- `main.swift` starts the `IMKServer`. Its connection name comes from `TildeProductProfile` and must match `InputMethodConnectionName` in `Info.plist`.
- `GhostInputController.swift` is the controller: marked-text ghost, type-through, dictionary suffixes for partial words, chained accept, phrase requests to the app.
- `GhostBrainClient.swift` is one cancellable streaming request over the app's owner-only unix socket. Cancelling closes the connection, which tells the app to stop inference.
- `GhostContextTailSampler.swift` is the Screen Memory content-reset sampler (host text only) plus the process-wide calm-reveal (Chromium/Electron) cache.
- `PersonalHistoryCapture.swift` batches typing events in memory (Backspace inside its own text included) and sends them to the app on a utility queue.
- `GhostOutcomeLedger.swift`, `GhostProvenance.swift`, `GhostStats.swift` are the text-free outcome ledger and aggregate counters.
- `WritingAppScopeReader.swift` reads the Writing tab's app scope from the keyboard's suite on every key. The scope gates suggestions as well as capture.
- `Info.plist`: the build stamps both version keys from the root `Info.plist`.

## How it's built

`scripts/entrypoints/lib/bundle-input-method.sh` compiles these files plus `Sources/TranscriptedWriting/Core/` into one module (Swift 5 mode, `-framework InputMethodKit`) and places the bundle at `Contents/Library/Input Methods/` in the app. `build.sh` and `build-beta.sh` sign it inside-out with `config/entitlements/keyboard.plist`. `scripts/entrypoints/lib/swiftc-app-args.sh` excludes this folder so the keyboard never lands in the app binary. At launch `KeyboardInstaller` (`Sources/TranscriptedWriting/Runtime/KeyboardInstaller.swift`) copies the bundle to `~/Library/Input Methods/` when missing or outdated.

## Tests

Keyboard tests live in `Tests/TranscriptedWritingTests/Runtime/` and `@testable import TranscriptedKeyboard`: `GhostInputControllerTests`, `GhostContextTailSamplerTests`, `PersonalHistoryCaptureTests`, `GhostStatsTests`, `WritingAppScopeTests`, and others.

```bash
swift test --filter '^TranscriptedWritingTests\.'
bash Tests/BuildDependencies/CLIPackagingTests.sh   # pins the signing calls
bash build.sh --no-open
```

Packaging changes also need `SKIP_NOTARIZATION=1 bash build-beta.sh '' <user>` (see `.agents/test-matrix.yml`). Real typing behavior needs a hand check in a signed build: Slack, Mail, Notes, Chrome, and VS Code.

- `GhostInputController+Suggestions.swift`, `+Context.swift`, `+Outcomes.swift` — extensions of the controller: scheduling and requesting suggestions, field snapshots and ticket context, and outcome-ledger recording. Stored state stays in the main file, so members they share are internal, not `private`.
