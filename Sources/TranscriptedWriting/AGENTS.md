# TranscriptedWriting library

## What this owns

Writing's autocomplete and Save my writing logic, ported from Tilde at `f36f6562` (`docs/writing-port-ledger.md` maps every file). Two layers:

- `Core/` — pure policy, Foundation only: suggestion state, activation and reveal policies, the prompt builder (`RawContinuationPrompt`), output cleaning, decision reasons, the socket wire format (`GhostBrainWire`), scene and Screen Memory policies, Personal History events and the personal predictor, `SecretRules` and `WritingSecretScrubber`. No AppKit, IMKit, processes, sockets or files.
- `Runtime/` — Tilde's app half minus its UI: the owner-only socket and peer auth (`GhostBrainServerHost`), the `llama-server` child (`LlamaServerProcessHost`, `LlamaCompletionEngine`, `ScaffoldPrewarmer`, `WritingHelperWakeRecovery`), model download and Tilde-model adoption (`ModelManager`, `WritingModelAdoption`), Screen Memory (`ScreenMemory/`), Personal History (`PersonalHistory/`), Save my writing (`SaveMyWriting/`), outcome-ledger readers (`Stats/`), the keyboard installer and Input Sources calls, settings, and the diagnostics log.

## How it's built

- `build.sh` compiles both layers straight into the app module. That's why Runtime files guard their Core import with `#if canImport(TranscriptedWritingCore)`.
- `scripts/entrypoints/lib/bundle-input-method.sh` compiles `Core/` again, together with `Sources/TranscriptedKeyboard/`, into the keyboard bundle. A Core change ships in two binaries.
- `Package.swift` declares `TranscriptedWritingCore` and `TranscriptedWritingRuntime` so the ported tests run under `swift test`. They take no deps flags.

## Rules

- **Library boundary.** The app reaches the runtime only through `Sources/Writing/`. Paths, preferences and analytics are injected by that bridge; nothing here reads app types or Transcripted's storage helpers.
- **Text stays local and mostly in memory.** Completion context and Screen Memory snapshots are memory-only. The outcome ledger is text-free (`TextFreeOnlineEvent`). Personal History is encrypted and owner-only (`SecureLocalStorage`: 0700 folders, 0600 files). Saved writing reaches disk only as day files, after `WritingSecretScrubber`; an entry that had a secret in it never goes to Personal History. `DiagnosticsMetadataRedactor` keeps text out of `writing-diagnostics.log`.
- **Screen Memory reads only the focused window**, never Transcripted's own windows, and an unknown keyboard focus refuses. Password managers are always excluded (`DefaultExcludedApps`), and the app scope gates suggestions as well as capture.
- **Peer auth.** Release builds answer only the signed keyboard from the same Team ID. `TRANSCRIPTED_WRITING_ALLOW_UNSIGNED_LOCAL_PEER=1` works in DEBUG builds only, so autocomplete needs a build signed with a real identity.
- **Keyboard behavior matches Tilde.** Don't tune suggestion logic without a reason recorded in the port ledger's "Deviations" section. The key table is in `docs/writing-plan.md` ("Keyboard behavior").
- **Models are pinned by hash.** A model descriptor carries an exact immutable URL and SHA-256; the bytes are the trust boundary for downloads and for adopting a standalone Tilde model. The `llama-server` helper is pinned in `build-deps.sh` (`docs/llama-server-provenance.md`).
- **Tests never touch real Input Sources or user state.** `WritingKeyboardInputSource` takes a fake in tests; `DiagnosticsLog` honors `TRANSCRIPTED_DISABLE_FILE_LOGGER=1`.

## Tests

`Tests/TranscriptedWritingTests/` (Swift Testing, not XCTest), split into `Core/` and `Runtime/`. Keyboard tests live in `Runtime/` and `@testable import TranscriptedKeyboard`.

```bash
swift test --filter '^TranscriptedWritingTests\.'
bash build-deps.sh --force && bash build.sh --no-open && bash run-tests.sh
```

`.agents/test-matrix.yml` maps `Sources/TranscriptedWriting/**` to the full Core set (deps rebuild, app build, fast tests, integration smoke, `swift test`).

## Background

- `docs/writing-plan.md` — design record (decisions, keyboard behavior, storage, phases).
- `docs/storage-paths.md` ("Writing") — current state, model and log paths.
- `docs/capture-format.md` ("Writing day files") — the day-file grammar; `SaveMyWriting/WritingDayFileFormatter.swift`, CaptureKit's parser and `Sources/Writing/WritingDayFileReader.swift` must agree with it.
