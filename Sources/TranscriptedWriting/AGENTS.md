# TranscriptedWriting library

## What this owns

Writing's autocomplete and Save my writing logic, ported from Tilde at `f36f6562` (`docs/writing-port-ledger.md` maps every file). Two layers:

- `Core/` — pure policy, Foundation only: suggestion state, activation and reveal policies, the prompt builder (`RawContinuationPrompt`), output cleaning, decision reasons, the socket wire format (`GhostBrainWire`), scene and Screen Memory policies, Personal History events and the personal predictor, `SecretRules` and `WritingSecretScrubber`. No AppKit, IMKit, processes, sockets or files.
- `Runtime/` — Tilde's app half minus its UI: the owner-only socket and peer auth (`GhostBrainServerHost`), the `llama-server` child (`LlamaServerProcessHost`, `OwnSigningTeam` (the owner Team ID from the running app's own signature, cached once non-nil), `BundleSealPassMemo` (the helper launch's whole-bundle seal pass, remembered per process by lstat fingerprints of the helper and CodeResources), `LlamaCompletionEngine`, `ScaffoldPrewarmer`, `WritingHelperWakeRecovery`), model download and Tilde-model adoption (`ModelManager`, `ModelDownloadTransport` for the bounded URLSession download stream, `ModelFileHasher` for chunked, cancellable hashing that never holds the file in memory, `WritingModelAdoption`), Screen Memory (`ScreenMemory/`), Personal History (`PersonalHistory/`), Save my writing (`SaveMyWriting/`), outcome-ledger readers (`Stats/`), the keyboard installer and Input Sources calls, settings, and the diagnostics log.

## Modules

Two modules in `.agents/modules.json`, both covered by this page:

- **WritingCore** (`Core/`): may depend on nothing. It compiles as its own Swift module, `TranscriptedWritingCore`, in the app build too, so anything the app or Runtime uses must be `public`. Public surface the app uses: `TildeModelChoice`, `WritingKeyboardSetupState`, `PersonalHistoryEvent`, `TypingTargetIdentity`, `TildeProductProfile`, `PersonalNextWordPrediction`, `WritingAppScope`, `ScreenScene`.
- **WritingRuntime** (`Runtime/`): may depend on WritingCore. Only WritingBridge, UISettings and AppShell may name it. Its facade (`OutcomeLedger*`, `WritingDayFileRecorder`, `ModelState`, `WritingPreferences`, `DiagnosticsLog`, `LlamaRuntimeSnapshot`, `TildeLocalOutcomeStores`, `GhostBrainServerHost`, `EncryptedPersonalHistoryStore`) is all `internal` today; making it a real module needs an access-control pass first.

## How it's built

- `scripts/entrypoints/lib/swiftc-app-args.sh` (used by `build.sh`, `build-beta.sh` and the typecheck scripts) compiles `Core/` first as a static module (`build/modules/libTranscriptedWritingCore.a` plus its `.swiftmodule`) and links it in; `Runtime/` compiles straight into the app module. Runtime files and the app files that use Core types import it under `#if canImport(TranscriptedWritingCore)`: the fast tests (`run-tests.sh`) and smokes compile the few Core files they need straight into their own module, where the import isn't there.
- `scripts/entrypoints/lib/bundle-input-method.sh` compiles `Core/` again, together with `Sources/TranscriptedKeyboard/`, into the keyboard bundle. A Core change ships in two binaries.
- `Package.swift` declares `TranscriptedWritingCore` and `TranscriptedWritingRuntime` so the ported tests run under `swift test`. They take no deps flags.

`ModelDescriptor.swift` holds the model asset/transport value types. `ModelSettlement` gives each `ModelManager` lifecycle generation an event-driven completion: cancelling one waiter leaves the download alone, while manager cancellation releases its generation's waiters without waiting for transport cleanup. `ScaffoldPrewarmer` keeps task identity across pause/resume so cancelled work cannot clear a newer request.

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
