# TranscriptedWriting library

## What this owns

Core and runtime logic for opt-in **"Save my writing"** (capture-only local Markdown day files). Two layers:

- `Core/` — policy and value types: the capture-only socket wire format (`GhostBrainRequest` / `GhostBrainResponse` in `GhostBrainWire.swift`), `PersonalHistoryEvent`, `PersonalHistoryCapturePolicy`, `PersonalHistoryDeletionTracker`, `PersonalHistoryCaretContinuity`, `WritingAppScope`, `DefaultExcludedApps`, `SecretRules`, `WritingSecretScrubber`, `WritingKeyboardSetupState`, `WritingKeyboardActivationFlow`, `TildeProductProfile`, `ProcessPeerIdentityCache`, and `DiagnosticsMetadataRedactor`. No AppKit, IMKit, processes, or socket I/O.
- `Runtime/` — the owner-only unix socket and peer auth (`GhostBrainServerHost`), Save my writing (`SaveMyWriting/`: `WritingEntryComposer`, `WritingDayFileFormatter`, `WritingDayFileStore`, `WritingDayFileRecorder`, `WritingDayFileRescrubber`, `WritingHistoryIngest`, `WritingPendingEntryJournal`), keyboard installer and Input Sources (`KeyboardInstaller`, `GhostKeyboardInstallerHost`, `WritingKeyboardInputSource`), settings (`TildeSettings`, `WritingPreferences`), and `DiagnosticsLog`.

## Modules

Two modules in `.agents/modules.json`, both covered by this page:

- **WritingCore** (`Core/`): may depend on nothing. Compiles as its own Swift module (`TranscriptedWritingCore`) in the app build, so anything the app or Runtime uses must be `public`.
- **WritingRuntime** (`Runtime/`): may depend on WritingCore. Only WritingBridge, UISettings, and AppShell may name it.

## How it's built

- `scripts/entrypoints/lib/swiftc-app-args.sh` compiles `Core/` first as a static module (`build/modules/libTranscriptedWritingCore.a` plus its `.swiftmodule`) and links it in; `Runtime/` compiles straight into the app module. Runtime files and app files import Core under `#if canImport(TranscriptedWritingCore)`.
- `scripts/entrypoints/lib/bundle-input-method.sh` compiles `Core/` again, together with `Sources/TranscriptedKeyboard/`, into the keyboard bundle. A Core change ships in two binaries.
- `Package.swift` declares `TranscriptedWritingCore` and `TranscriptedWritingRuntime` so tests run under `swift test`.

## Rules

- **Library boundary.** The app reaches the runtime only through `Sources/Writing/`. Paths, preferences, and analytics are injected by that bridge; nothing here reads app types or Transcripted's storage helpers.
- **Text stays local and scrubbed.** Password managers are always excluded (`DefaultExcludedApps`), and `WritingAppScope` gates capture on both the keyboard and app sides. Saved writing reaches disk only after `WritingSecretScrubber`: closed entries first get an owner-only recovery journal (`SecureLocalStorage`: 0700 folders, 0600 files), then their day file. `DiagnosticsMetadataRedactor` keeps text out of `writing-diagnostics.log`.
- **Peer auth.** Release builds answer only the signed keyboard from the same Team ID. `TRANSCRIPTED_WRITING_ALLOW_UNSIGNED_LOCAL_PEER=1` works in DEBUG builds only.
- **Tests never touch real Input Sources or user state.** `WritingKeyboardInputSource` takes a fake in tests; `DiagnosticsLog` honors `TRANSCRIPTED_DISABLE_FILE_LOGGER=1`.

`Core/Text/WritingScrubberTokenIdentity.swift` marks pre-existing redaction tokens while the scrubber runs and restores them before returning, keeping `Result.kinds` limited to new redactions in text order.

## Tests

`Tests/TranscriptedWritingTests/` (Swift Testing), split into `Core/` and `Runtime/`. Keyboard tests live in `Runtime/` and `@testable import TranscriptedKeyboard`.

```bash
TRANSCRIPTED_DISABLE_FILE_LOGGER=1 swift test --filter '^TranscriptedWritingTests\.'
bash build.sh --no-open && bash run-tests.sh
```
