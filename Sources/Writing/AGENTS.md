# Writing bridge

## What this owns

`Sources/Writing/` is the app side of opt-in **"Save my writing"** (capture-only, off by default). Users opt in on the **Agent** page (`Sources/UI/Settings/AgentConnectionSettingsPage.swift` → `Sources/UI/Settings/WritingCaptureSettingsCard.swift`) to capture what they type into local, secret-scrubbed Markdown day files (`captures/writing/Writing_YYYY-MM-DD.md`) so AI tools and Today have context across meetings, dictations, and writing.

Autocomplete, local LLMs (`llama-server`), GGUF model downloads, Screen Memory, Personal History learning, and Write for Me (`NextSentence`) were spun out; zero LLM downloads and zero Screen Recording permission are required.

The library (`Sources/TranscriptedWriting/`) and the capture-only IMKit keyboard (`Sources/TranscriptedKeyboard/`) have their own `AGENTS.md`.

## Module

`WritingBridge` in `.agents/modules.json`.

- **Public surface:** `WritingController`, `WritingCaptureCardModel`, `WritingSetupState`, `WritingDayFileReader`, `WritingDayFileWriter`, `WritingStorageUsage`, `WritingAnalytics`.
- **May depend on:** WritingCore, WritingRuntime, Support, Observability. `WritingCaptureCardModel` bridges `WritingCore` types cleanly so `UISettings` never needs to import `WritingCore`.
- **WritingCore is a real Swift module** (`TranscriptedWritingCore`). Files here that name its types start with `#if canImport(TranscriptedWritingCore) import TranscriptedWritingCore #endif`.

## Entry points

- `WritingController.swift` — the `@MainActor` runtime host. `TranscriptedAppState` owns one, calls `startIfEnabled(log:)` at launch, `handleSystemWake()` on wake, and `stop()` at quit; `TranscriptedApp` calls `noteTerminationRequest()`. Starts only the owner-only unix socket (`GhostBrainServerHost`), the local Markdown day-file writer (`WritingDayFileWriter`), and the keyboard installer (`GhostKeyboardInstallerHost`). Runs only while `Save my writing` is on (or `WritingDebugEnabled` is set).
- `WritingCaptureCardModel.swift` — `@MainActor` view model for `WritingCaptureSettingsCard` on the Agent page: toggle opt-in, keyboard install/activation status, `All apps` vs `Picked apps` scope, saved-writing byte summary, and "Delete all saved writing".
- `WritingSetupState.swift` — `WritingSetupState` and `WritingActivation` (Foundation-only for fast tests).
- `WritingDayFileWriter.swift` — host side of Save my writing: builds `WritingDayFileRecorder` against `<capture-library>/writing`, closes idle entries on a timer, flushes at quit (with recovery journal in app state), and posts a notification after each append so Home and Today refresh.
- `WritingDayFileReader.swift` — reads one `Writing_<YYYY-MM-dd>.md` for Today. Never writes.
- `WritingAnalytics.swift` — count-only `writing_setup_completed` event through `AnalyticsReporter.track` (keeps allowlist schema valid with `autocomplete_enabled: "false"`, `model_choice: "none"`).
- `WritingStorageUsage.swift` — byte size of `Writing_*.md` files on disk (Foundation-only for fast tests). Never opens file contents.
- `LegacyWritingDataCleanup.swift` — removes legacy Personal History, Outcome Ledger, Word Diary, and `next-sentence` folders under app support plus the legacy Personal History Keychain key on launch (outside automated harnesses) and on Delete all saved writing; refuses symlinks and out-of-root paths, and leaves `captures/writing/` day files untouched on launch.

## Rules

- **Writing never sends text.** Analytics are setup booleans/scope only. No app names, bundle IDs, or writing text leave the device.
- **The app owns every disk write.** The keyboard sends events over the socket; this folder and the library write day files. Day-file folders are 0700 and files 0600, and every closed entry goes through `WritingSecretScrubber` before it lands. `WritingDayFileWriter.defaultPendingDirectory` injects a separate app-owned recovery journal for closed scrubbed entries, never raw/open events. `finishWritingForTermination()` seals batch admission once its final closed entry is durable. Delete all erases recovery even when the runtime is stopped.
- **Paths, preferences and analytics are injected into the library from here.** Don't make `Sources/TranscriptedWriting/` read app types or app paths.
- **Off the main thread.** Keyboard install copy and signature checks run detached (`GhostKeyboardInstallerHost.installOrUpdate(using:)`); only Text Input Sources calls return to main, and `TISRegisterInputSource` runs only for a fresh copy or an unlisted keyboard.
- **Files the root fast tests compile** (`WritingAnalytics`, `WritingSetupState`, `WritingDayFileReader`, `WritingStorageUsage`, `LegacyWritingDataCleanup`) stay Foundation-only and live in `APP_SOURCES` in `scripts/entrypoints/run-tests.sh`.

## Tests

- Root fast tests: `Tests/WritingAnalyticsTests.swift`, `Tests/WritingSetupStateTests.swift`, `Tests/WritingDayFileReaderTests.swift`. Run with `bash run-tests.sh --filter Writing`.
- Library behavior (recorder, composer, scrubber, keyboard capture, installer): `TRANSCRIPTED_DISABLE_FILE_LOGGER=1 swift test --filter '^TranscriptedWritingTests\.'`.
