# Writing bridge

## What this owns

`Sources/Writing/` is the app side of Writing (shipped in 1.1.67, off until the user turns it on in the Writing tab). It hosts the runtime from `Sources/TranscriptedWriting/` inside Transcripted, writes Save my writing day files, and feeds the Writing tab. Everything here is `@MainActor` app glue; the logic it runs lives in the library.

The library (`Sources/TranscriptedWriting/`) and the keyboard (`Sources/TranscriptedKeyboard/`) have their own `AGENTS.md`. The tab's views are in `Sources/UI/Settings/Writing/` and `Sources/UI/Settings/Pages/WritingSettingsPage.swift`.

## Module

`WritingBridge` in `.agents/modules.json`.

- **Public surface:** `WritingController`, `WritingSettingsModel`, `WritingSetupState`, `WritingSetupPresentation`, `WritingSidebarNewBadge`, `WritingDayFileReader`, `WritingDayFileWriter`, `WritingStorageUsage`, `WritingAnalytics`.
- **May depend on:** WritingCore, WritingRuntime, Support, Observability. It's the only app module besides UISettings and AppShell that may name the runtime.
- **No grandfathered crossings.** `WritingSetupPresentation.swift` (the tab's copy) and `WritingSidebarNewBadge.swift` (the sidebar badge's defaults key) live here so the model never names `UI/Settings`. The badge's `isShown(for:dismissed:)` stays next to `TranscriptedSettingsPage`.
- **WritingCore is a real Swift module** (`TranscriptedWritingCore`). Files here that name its types start with `#if canImport(TranscriptedWritingCore) import TranscriptedWritingCore #endif`.
- **Tests:** see "Tests" below.

## Entry points

- `WritingController.swift` — the runtime host. `TranscriptedAppState` owns one, calls `startIfEnabled(log:)` at launch, `handleSystemWake()` on wake and `stop()` at quit; `TranscriptedApp` calls `noteTerminationRequest()`. It starts the keyboard socket (`GhostBrainServerHost`), the `llama-server` helper and its model, Screen Memory, Personal History and the keyboard installer. With only Save my writing on, the model, helper and Screen Memory stay off. The Writing tab calls `applyRunState()` after "Turn on writing" and after any feature toggle.
- `WritingSetupState.swift` — whether setup finished, and `WritingActivation`: run once setup is done and at least one feature is on (or the dev-only `WritingDebugEnabled` default). Once setup is done, launch also reaps a helper a crash left running.
- `WritingSettingsModel.swift` — the Writing tab's state (intro, setup draft, everyday view). One per controller (`shared(for:)`) so a setup in progress survives tab switches. It only reads and asks; every runtime change goes through `WritingController`.
- `WritingRefreshTimers.swift` — the Writing tab's refresh timers, suspended while its window is closed or occluded and resumed on show; Foundation-only so a fast test drives it.
- `WritingFrontWindowPoller.swift` / `WritingFrontWindowChangeDetector.swift` — Screen Memory's front-window poll: a `DispatchSourceTimer` on its own queue that hops to main only when the front window changes; the pure change rule is in the detector (Foundation-only, fast-tested).
- `WritingDayFileWriter.swift` — Save my writing's host side: builds `WritingDayFileRecorder` against `<capture-library>/writing`, closes idle entries on a timer, flushes at quit, and posts a notification after each append so Home and Today refresh. Entries that close with nothing to scrub go on to Personal History.
- `WritingDayFileReader.swift` — reads one `Writing_<YYYY-MM-dd>.md` for the tab's Today list. Never writes.
- `WritingAnalytics.swift` — the two count-only Writing events, through `AnalyticsReporter.track`.
- `WritingStorageUsage.swift` — byte sizes for the tab's storage meter (models, saved writing, learning data). Never opens file contents.
- Delete model (`WritingController.deleteDownloadedModels()`, next to the storage meter) — turns Autocomplete off if it's on, cancels model work and waits for the helper to exit, then empties the model root through `WritingModelStore.removeAll(under:)` (refuses a symlinked root; never follows links). The sequence is `WritingModelRemoval` in the runtime library, tested with a fake host. Delete all writing never touches the model.
- `WritingSetupPresentation.swift` — the tab's words and small rules from the approved design (`docs/writing-plan.md`). Foundation plus two WritingCore value types, so the fast tests compile it.
- `WritingPausableIngest.swift` — wraps Personal History ingest so "Pause for 1 hour" drops typed text (acknowledged, never kept) as well as suggestions.
- `WritingSidebarNewBadge.swift` — the defaults key the Writing tab sets when setup finishes, which drops the sidebar's "New" badge.

## Rules

- **Writing never sends text.** Analytics are counts and setup choices only, read from the text-free outcome ledger summary. No app names, bundle IDs, or per-suggestion events. Adding an event is the lockstep edit in `Sources/Observability/AGENTS.md`; run `python3 scripts/dev/check-telemetry-keys.py`.
- **The app owns every disk write.** The keyboard sends events over the socket; this folder and the library write day files and Personal History. Day-file folders are 0700 and files 0600, and every entry goes through `WritingSecretScrubber` before it lands.
- **Paths, preferences and analytics are injected into the library from here.** Don't make `Sources/TranscriptedWriting/` read app types or app paths. UI may use pure Core value types like `TildeModelChoice`.
- **Off the main thread.** Front-window reads and helper probes don't block the main actor. Screen Memory never reads Transcripted's own windows.
- **Screen Recording ask.** Meeting-only users never see it, and granting it must not relaunch the app during a meeting.
- **Files the root fast tests compile** (`WritingAnalytics`, `WritingSetupState`, `WritingDayFileReader`, `WritingStorageUsage`, `WritingSetupPresentation`, `WritingSidebarNewBadge`, `WritingRefreshTimers`, `WritingFrontWindowChangeDetector`) stay Foundation-only (plus WritingCore value types). They're in the hand-kept list in `scripts/entrypoints/run-tests.sh`; a new file a fast test needs goes there too.

## Tests

- Root fast tests: `Tests/WritingAnalyticsTests.swift`, `Tests/WritingSetupStateTests.swift`, `Tests/WritingDayFileReaderTests.swift`, `Tests/WritingSetupPresentationTests.swift`, and the tab's `Tests/WritingDemoScriptTests.swift`. Run them with `bash run-tests.sh --filter Writing` (case-insensitive substring).
- Library behavior (recorder, composer, scrubber, Personal History) is tested under `swift test --filter '^TranscriptedWritingTests\.'`.
- `WritingController` has no unit tests; check it with a real signed build (autocomplete needs a real signing identity, see `Sources/TranscriptedWriting/AGENTS.md`).

```bash
bash build.sh --no-open
bash run-tests.sh
```

## Background

- `docs/writing-plan.md` — the design record and the approved tab copy; code comments cite its sections.
- `docs/writing-port-ledger.md` — which Tilde file became which file here.
- `docs/capture-format.md` ("Writing day files") and `docs/storage-paths.md` ("Writing") — the day-file format and every Writing path.
