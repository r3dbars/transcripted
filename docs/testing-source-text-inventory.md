# Source-text test inventory

Root fast tests (`Tests/*.swift`, run by `bash run-tests.sh`) that read production Swift
files as text and assert on fragments of them. These "pins" go red on harmless renames and
reflows, and stay green when the behavior breaks but the text survives. This file lists every
root test file that reads a `Sources/**/*.swift` path, what it promises, and what it would
take to check that promise through inputs and outputs instead. It was built from:

```bash
grep -lE '"Sources/[^"]+\.swift"' Tests/*.swift \
  | xargs grep -lE 'readRepoTextFile|contentsOf(File)?:|readParakeet[A-Za-z]*Source|readSource|sourceSlice'
```

That returned 51 files when this inventory was built. After the source-pin burn-down
(PR #1949) it returns 36 (35 test files plus `Tests/TestHelpers.swift`), and
`python3 scripts/dev/check-test-shape.py` reported 357 source-text uses in 40 files (348 in 39
after the hotspot splits in PR #1950). That
script and `.agents/test-shape-baseline.json` are the source of truth for counts; the "Pins"
column below is from the original pass. SPM tests under
`Tests/TranscriptedCoreTests/` and the `Tools/*` packages are out of scope.

## Verdicts

- `convert-now`: the promise can be checked through non-private code already compiled into the
  fast runner (`APP_SOURCES` in `scripts/entrypoints/run-tests.sh` plus the shared lists in
  `scripts/entrypoints/lib/shared-smoke-sources.sh`).
- `delete`: an existing behavior test already covers the promise; the pin can go.
- `needs-seam`: the code under test is not compiled into the runner (usually a `@MainActor`
  controller wired to AppKit, CoreAudio, or the whole app graph). The verdict names the
  smallest production change that would make a behavior test possible.
- `keep`: the test is legitimately about text: a privacy or banned-API scan across many files,
  a byte-for-byte sync check, or a contract with a script, doc, or another package.
- `converted` / `deleted`: done in this pass. "(partial)" means the file still has pins
  that need a seam; they are listed.

"Pins" is a rough count, taken before this pass, of assert call sites that check production
source text (loops count once). Doc, script, and fixture reads are not counted.

## Totals

| Verdict | Files |
| --- | --- |
| converted (all pins in the file) | 1 |
| converted (partial) | 5 |
| deleted (partial) | 2 |
| needs-seam | 38 |
| keep | 5 |
| Total | 51 |

No `convert-now` or `delete` items are left that this pass found. Everything still pinned
needs a production change first, or is a legitimate text contract.

Most of the `needs-seam` rows share a few owners:

- `Sources/UI/Overlay/DictationSessionController.swift` was read by 16 files. After the hotspot
  split (PR #1950) only 4 still read it, all for code in the core file; the start, stop,
  paste-back, cap and telemetry code moved to its `+*.swift` extensions. Its start and
  stop paths (sound cues, mis-taps, session cap, Paste Anyway, checkpoints, telemetry) are
  pinned as ordered strings. Smallest seam: a compiled stop/start pipeline type that takes its
  collaborators (stop mic, play cue, snapshot, transcribe, paste, persist, track) as closures
  and that the controller calls. A fake then records the order, so "the stop click plays after
  the mic stops and before transcription" becomes an event-order assertion.
- `Sources/Speech/ParakeetEngine.swift` and `ParakeetDeviceRecovery.swift` were read by 7 files
  in this table, plus the two files listed under "Outside the grep" below. After the split
  (PR #1950) the engine is `ParakeetEngine.swift` plus sibling files; most readers take all of
  them through `readParakeetEngineSource()`, and the rows below name the sibling a test reads
  directly. Smallest seam: an
  audio-graph driver protocol for the `AVAudioEngine` calls (install/remove tap, stop, set
  input device, read formats, VPIO) so the engine's ordering and ownership logic can run
  against a recording fake. Done for teardown and replacement: `ParakeetAudioGraphDriver` in
  `Sources/Speech/ParakeetAudioGraph.swift`. Start (tap install, engine start, the start
  snapshot lease) and the route-change handler's admission arguments still run in
  ParakeetEngine and stay pinned.
- `Sources/Meeting/MeetingSessionController.swift` is read by 9 files. Smallest seams: move
  `FailedMeetingItem` to its own file (done in phase 2: `Sources/Meeting/FailedMeetingItem.swift`,
  so `FailedMeetingPresentation.swift` now compiles in the runner), and extract
  `handleUnexpectedCaptureStop` and the retranscribe/preserve entry points behind a small
  capture protocol.

## Inventory

Paths in "Reads" are relative to `Sources/` unless shown otherwise.

| File | Reads | Pins | Promise(s) | Verdict |
| --- | --- | --- | --- | --- |
| `AgentConnectionGuideTests.swift` | `UI/Shared/AgentConnectionGuide.swift` | 1 | The folder-path copy is computed on every read, so a relocated capture library shows up. | **converted**: the suite relocates the capture library between two reads of `folderPathsText`. No source reads left. |
| `AnalyticsEventForwardingPolicyTests.swift` | `Observability/EventReporter.swift` | 0 | `EventReporter.capture` runs the forwarding policy on the caller's own context, so pinned-mic facts reach PostHog without engine state. | **converted** in PR #1949: no source reads left. |
| `AnalyticsEventPolicyTests.swift` | `Observability/WorkflowRecoveryTelemetry.swift`, `TranscriptedApp.swift`, `Meeting/MeetingSessionController.swift`, `TranscriptedCore/Speaker/SpeakerFinalizationFailure.swift` (plus docs, `.psv` taxonomy, MCP tool source) | ~12 | Workflow recovery sends the allowlisted bucket key and a separate failed event. Meeting prompt events fire exactly once per path. Every Core speaker-finalization reason survives the sanitizer. Docs and taxonomy match the allowlist. | needs-seam: give `WorkflowRecoveryTelemetry` a `track` closure (like `DictationPasteRetryTelemetry.performUserRetry`) and move prompt-event firing into the compiled `MeetingPromptTelemetry`. The docs, taxonomy, MCP, and Core raw-value cross-checks are keep (cross-package and doc contracts). |
| `AudioAutomationCoverageContractTests.swift` | none as code (names `Meeting/MeetingTranscriptStyler.swift` as data) | 0 | The daily audio script names every route lane, issue 500 manual proof stays explicit, and the E2E smoke compiles the transcript styler from the right shared array. | keep: script and doc contract. |
| `AuditRegressionCoverageContractTests.swift` | `UI/Overlay/MeetingOverlayController.swift`, `UI/MenuBar/MenuBarPanelController.swift`, `Support/ClipboardRestoringTextPaster.swift`, `Meeting/TranscriptionQueueCoordinator.swift` | 9 | Pasteback re-checks the target before Cmd+V and downgrades to copied; a failed dispatch falls back to copy. Overlay and menubar duration ticks collapse to whole seconds. Terminal status handlers revisit the background queue. | **converted (partial)**: the pasteback suite runs the real paster with a non-frontmost target and a failing dispatcher (3 pins out). Rest needs-seam: one compiled whole-second duration publisher both controllers use; the queue revisit as a compiled coordinator policy. PR #1949 cut more of these; see `.agents/test-shape-baseline.json` for what's left. |
| `BluetoothRouteContractTests.swift` | `Speech/Parakeet*.swift` (banned-call scan), `TranscriptedApp.swift` | ~3 | Dictation never writes the Mac-wide default input. Persistent input restores on shutdown. | **converted (partial)**: the input-snapshot ordering (serialized selection, fail-closed lookup, ignore window armed before the graph read) is a behavior test in `ParakeetAudioGraphTests.swift`, and the system-input restore it guarded was dead code and is deleted. The persistent-input listener, relinquish and shutdown pins run the real controller against fakes in `PersistentDictationInputControllerTests.swift` (`PersistentDictationInputSystem` seam). Keep: the no-Mac-wide-write scan (a banned-call contract) and the QA-report suite. Left: the `TranscriptedApp` awaits-`stopAndRestore` pin, held until #1946 lands. |
| `CaptureLibraryPathSafetySyncTests.swift` | compares three copies of `CaptureLibraryPathSafety.swift` | 3 | The three synced copies stay byte-identical. | keep: sync check is the point. |
| `CrashReporterOptionsTests.swift` | `Observability/CrashReporter.swift` | 5 | Sentry privacy and noise options (no PII, no auto sessions, no network breadcrumbs, zero breadcrumbs, no stack traces, no failed-request capture) are set once before `SentrySDK.start`. | needs-seam: move the option values into a compiled function that applies them to a small protocol the Sentry `Options` type conforms to, so a fake records them. |
| `ClipboardRestoringTextPasterTests.swift` | `Support/ClipboardRestoringTextPaster.swift`, `UI/Overlay/DictationSessionController.swift`, `UI/Overlay/FloatingOverlayController.swift` | ~15 | AX reads are bounded to 50 ms. The focused-element cast is type-checked. The Core import stays `canImport`-guarded. An ambiguous paste never offers a duplicate paste. Provider reads never confirm a paste or arm Auto Enter. | **deleted (partial)**: the provider-read pin is gone; covered by "a likely paste into a selected target never authorizes Auto Enter" and "a read with a silent AX source is a likely paste, not a confirmed one". Rest needs-seam: inject an AX element reader into `FocusedTextPasteConfirmation.capture()`; controller suite waits on the dictation pipeline seam. PR #1949 cut more of these; see `.agents/test-shape-baseline.json` for what's left. |
| `ContextCaptureEnginePolicyTests.swift` | `Capture/ContextCaptureEngine.swift`, `TranscriptedAppState.swift`, `UI/Overlay/DictationSessionController.swift` | 0 | Hotkeys debounce per action with push-to-talk exempt. The paste callback survives re-registering. A disabled tap reconciles a missed push-to-talk release. The tap runs on its own run loop. An Accessibility grant re-registers hotkeys. Wake recovery reads the registration error, not the advisory banner. A press while finishing shows a message. | **converted** in PR #1949: no source reads left. |
| `DeviceRecoveryPolicyTests.swift` | `Speech/ParakeetDeviceRecovery.swift` | ~17 | Recovery keeps recording intent across a Bluetooth notification burst and only the current task releases it. Binding waits poll and stale snapshots can't commit. A cancelled session is never rebuilt. | needs-seam: the recovery executor (`attemptDeviceRecovery` and its timeout task) still runs in ParakeetEngine; the audio-graph seam covers its teardown, restart loop and snapshot lease, not its intent latching. |
| `DictationInputDeviceSelectionPolicyTests.swift` | `Speech/ParakeetPinnedMicrophone.swift` | ~6 | Warmup is judged on the same selection the start records and turns back on after an engine fallback. Pinned dictation steers off a Bluetooth headset unless the Microphone choice keeps the macOS input, and a chosen mic always wins. | needs-seam: move the argument building in `pinnedDictationInputSelection()` into a compiled `PinnedDictationInputPolicy` function and the fallback flag into a small compiled state type. PR #1949 cut more of these; see `.agents/test-shape-baseline.json` for what's left. |
| `DictationAudioRecoveryTests.swift` | every engine file through `readParakeetEngineSource()`, `UI/Overlay/DictationSessionController.swift` | ~12 | Terminal interruption clears restart intent before it publishes and keeps the audio; abandoned sessions cancel the engine. | **converted (partial)**: the drain pins are behavior tests ("Pending tap audio joins the take one segment at a time, each at its own rate" and the 48k-to-24k timeline suite in `RecordedAudioTimelineTests.swift`). Rest needs-seam: the interruption helper and the dictation pipeline seam. |
| `DictationLanguageScriptPolicyTests.swift` | `Speech/STTRouter.swift`, `UI/Overlay/DictationSessionController.swift` | 4 | Paste Anyway pastes and saves the held-back text instead of dropping it. | **converted**: reads no source text after PR #1950. Was needs-seam: dictation pipeline seam. PR #1949 cut more of these; see `.agents/test-shape-baseline.json` for what's left. |
| `DictationQueuedStartPolicyTests.swift` | `Capture/ContextCaptureEngine.swift`, `UI/Overlay/DictationSessionController.swift`, `UI/Overlay/FloatingOverlayController.swift` | ~10 | Presses during a finishing take go through the queue. Esc and Quit drop a waiting start. A passing note gives way to the next take. A refused Quit lets presses queue again. | needs-seam: dictation pipeline seam (the policy itself is already tested in this file). PR #1949 cut more of these; see `.agents/test-shape-baseline.json` for what's left. |
| `DictationRecordingStartOverlayPolicyTests.swift` | `Capture/ContextCaptureEngine.swift`, `Meeting/MeetingSessionController.swift`, `UI/Overlay/DictationSessionController.swift` | ~25 | The early-release message comes from the policy. A repeated Stop is fenced before the loading cancel. An unexpected meeting stop hands the mic back to dictation. The start handle is cleared on the recovery path. | needs-seam: dictation pipeline seam; meeting unexpected-stop seam. PR #1949 cut more of these; see `.agents/test-shape-baseline.json` for what's left. |
| `DictationSessionCapTests.swift` | `UI/Overlay/DictationSessionController.swift`, `UI/Overlay/OverlayHeaderView.swift` | 0 | The five-minute cap warns, pastes only if the original target is still frontmost, saves to Markdown with a Paste It action, and an interruption with preserved audio offers Transcribe. | **converted** in PR #1949: no source reads left. |
| `DictationRecordingStartAttemptTests.swift` | `Speech/DictationSession.swift`, `UI/Overlay/DictationSessionController.swift` | 0 | Both production start paths use the tested failure-only recovery runner, at most once per session. | **converted** in PR #1949: no source reads left. |
| `DictationSoundsTests.swift` | `UI/Overlay/DictationSessionController.swift`, `UI/Settings/TranscriptedSettingsView.swift`, `UI/Shared/TranscriptedSupportActions.swift` | 8 | The stop click plays once, after the mic stops (so speakers can't leak it into the take) and before transcription and paste. The start click plays once, on the fast path. Feedback submit stays silent. | needs-seam: dictation pipeline seam with an injected sound player. The `TranscriptedSupportActions` silence check is keep: a banned-call scan (the type needs the app graph, and an injected player can't see a direct call). The `TranscriptedSettingsView` slice is the Settings lane's. |
| `DictationStartReadinessTests.swift` | `Speech/DictationSession.swift`, `UI/Overlay/DictationSessionController.swift` | 0 | Hotkey trigger raw values match `DictationTrigger`. The App Nap reason uses a label the readmission sites set. The cancel diagnostic names the pending stage. Recovery-loop stage reports reach the session-scoped controller. | **converted** in PR #1949: no source reads left. |
| `DictationStartedTelemetryContractTests.swift` | `UI/Overlay/DictationSessionController.swift` | 18 | `dictation_started` fires only after the mic starts. `dictation_start_requested` fires before any guard and before the session id. Guard refusals and retries are labelled. Warmup failures count as start failures. | needs-seam: dictation pipeline seam with an injected `track` closure. |
| `DictationTerminationCheckpointTests.swift` | `TranscriptedApp.swift`, `UI/Overlay/DictationSessionController.swift` | ~15 | Quit defers while audio isn't checkpointed and replies false before meeting or app shutdown. New capture and Retry Saving wait on the old checkpoint. A failed snapshot is fenced before inference. | needs-seam: dictation pipeline seam (the admission policy itself is already tested in this file). |
| `DictationStoppedAudioRecoveryTests.swift` | `Meeting/MeetingSessionController.swift`, `Speech/ParakeetDictationTranscription.swift` (was `ParakeetEngine.swift`), `Speech/STTRouter.swift`, `TranscriptedApp.swift`, `UI/Overlay/DictationSessionController.swift` | ~28 | Stop writes a private WAV checkpoint off the main actor before waiting on the model. External model errors keep usable audio. | needs-seam: dictation pipeline seam. PR #1949 cut more of these; see `.agents/test-shape-baseline.json` for what's left. |
| `DictationTranscriptPersistenceTests.swift` | `UI/Overlay/DictationSessionController.swift` | 0 | Session-cap completion labels delivery and failure only after proof of save. | **converted** in PR #1949: no source reads left. |
| `ExistingInstallModelPrefetchPolicyTests.swift` | `TranscriptedAppState.swift` | 0 | Models warm at launch unless `TRANSCRIPTED_LAZY_MODEL_WARMUP=1`. Meeting models warm too. Dictation warms at user priority, the pass at utility. | **converted** in PR #1949: no source reads left. |
| `FailedMeetingPresentationTests.swift` | `Meeting/MeetingSessionController.swift`, `UI/Settings/HomeView.swift`, `UI/Settings/TranscriptedSettingsView.swift` (was also `Meeting/FailedMeetingPresentation.swift`, `UI/Settings/FailedMeetingRecoveryPresentation.swift`) | ~19 | Skipped no-speech outcomes surface a visible error. Retry needs surviving audio while partial audio stays revealable. Retained WAVs read "raw audio kept". Retry counts show in metadata. Cleanup is a confirmed delete. | **converted (partial)**: the retry-readiness helper pin calls `FailedMeetingRecoveryPresentation.retryDisabled`, and (phase 2) every `FailedMeetingPresentation.swift` pin now builds rows through `FailedMeetingPresentation.item(from:)` from real files on disk. Rest needs-seam: the skipped no-speech pin needs the meeting capture protocol; the Home row and Settings cleanup pins need Home's row reveal/retry and delete wiring moved into a compiled presentation type. PR #1949 cut more of these; see `.agents/test-shape-baseline.json` for what's left. |
| `FocusOrderContractTests.swift` | `UI/MenuBar/MenuBarActionRowView.swift`, `MenuBarContentView.swift`, `MenuBarPrimaryActionsView.swift`, `MenuBarUtilityActionsView.swift`, `UI/Settings/TranscriptedSettingsPage.swift`, `TranscriptedSettingsSidebar.swift` | 0 | Menu bar rows are focusable and chained in the declared order. Settings sidebar pages produce the declared identifiers in ⌘1–⌘5 order. | **converted** in PR #1949: no source reads left. |
| `HomeFirstArtifactVisibilityTests.swift` | `UI/Overlay/MeetingOverlayRootView.swift`, `UI/Settings/HomeView.swift`, `Pages/HomeSettingsPage.swift`, `QuietDictationLibrary.swift`, `QuietHomeLibrary.swift`, `TranscriptedSettingsView.swift` | 10 | Dictation rows show Open file and "saved only" on a failed paste. Only active work spins. The meeting overlay says "Saved to Markdown". Copy for agent prefers the portable bundle. Old vague copy doesn't return. | needs-seam: move the row and overlay copy and the tone-to-icon choice into a compiled presentation type the views read. |
| `HomeImportAudioActionTests.swift` | `UI/Settings/HomeView.swift`, `Pages/GeneralSettingsPage.swift`, `Pages/HomeSettingsPage.swift`, `TranscriptedSettingsView.swift` | 6 | Settings has a "Transcribe a file" row wired to `importAudioFile()`, and Home's empty meetings state offers the same route. | needs-seam: move the row and empty-state copy and identifiers into the compiled `HomeCaptureListCopy` and route the action through a compiled action table. PR #1949 cut more of these; see `.agents/test-shape-baseline.json` for what's left. |
| `MeetingMicrophonePreferencesTests.swift` | `Meeting/MeetingCaptureBridge.swift` | 0 | Meeting start picks the mic mode through the recorder-aware check and applies a Settings mic only while the recorder shows that picker. | **converted** in PR #1949: no source reads left. |
| `MeetingStopSnapshotEvidenceTests.swift` | `Meeting/MeetingSessionController.swift` | 6 | Unexpected-stop evidence (status, warning, unheard seconds) is stashed before the warning clears and used by the stop snapshot. | needs-seam: meeting unexpected-stop seam. |
| `MeetingSessionUIPolicyTests.swift` | `Meeting/MeetingSessionController.swift`, `UI/MenuBar/MenuBarPanelController.swift`, `UI/Overlay/MeetingOverlayController.swift` | ~21 | Audio sleep/wake listens on the workspace center. Unexpected stop leaves recording before any await. Start returns false for an active capture. Discard needs `session.recording` and re-checks after confirm. Menu start/stop uses capture-active state. | needs-seam: meeting capture protocol plus a compiled overlay-menu policy. PR #1949 cut more of these; see `.agents/test-shape-baseline.json` for what's left. |
| `MicrophoneProcessingPreferencesTests.swift` | `Meeting/MeetingCaptureBridge.swift`, `UI/Settings/TranscriptedSettingsView.swift` | 10 | Boost Mic arms voice processing for the live meeting without saving the mode and respects a call app on the mic. Only a successful start uses up the next-meeting boost. | needs-seam: same `MeetingCaptureBridge` extraction as above. PR #1949 cut more of these; see `.agents/test-shape-baseline.json` for what's left. |
| `MicrophoneChoicePreferencesTests.swift` | `UI/Settings/TranscriptedSettingsView.swift` | 5 | Settings shows the one Microphone picker only while the recorder is on and keeps the older rows otherwise. | needs-seam: a compiled layout policy the settings view switches on. |
| `ParakeetAudioGraphOwnershipTests.swift` | `Speech/ParakeetEngine.swift`, `ParakeetDeviceRecovery.swift` | 0 | A config-change restart keeps the same recording claim when segments are retained. | **converted** in PR #1949: no source reads left. The route-restart call-site pin moved to `ParakeetAudioOwnershipSourceContractTests.swift`. |
| `NightlySecurityContractTests.swift` | none as code (a manifest names `Observability/AnalyticsEventPolicy.swift` as data) | 0 | The nightly security checker, entitlement manifest, and docs stay in step. | keep: script, manifest, and doc contract. |
| `ObservabilityLogWriterTests.swift` | `Observability/AppLogSink.swift`, `EventReporter.swift`, `LockedFileAppender.swift`, `ObservabilityLogRotation.swift`, `ReliabilityPacketRecorder.swift`, `TranscriptedApp.swift`, `TranscriptedCore/Logging/FileLogger.swift`, `TranscriptedCore/Speaker/RetroactiveSpeakerUpdater.swift` | ~17 | Shutdown flushes buffered events. Local events carry build identity. The reliability recorder sees raw events. Logs are made owner-only before append. `AppLogSink` redacts. Console diagnostics avoid absolute paths. No NSException-throwing `FileHandle` APIs. | **converted (partial)**: log-file preparation now runs `ObservabilityLogFilePreparation.openPreparedHandle` on a world-readable log. Rest needs-seam: compile `EventReporter` and `AppLogSink` with an injected writer. The legacy `FileHandle` sweep is keep (banned-API lint across two build units). PR #1949 cut more of these; see `.agents/test-shape-baseline.json` for what's left. |
| `OverlayScreenSharePrivacyTests.swift` | `TranscriptedApp.swift`, `UI/MenuBar/PasteLastDictationFeedback.swift`, `UI/Overlay/{CapturePillController,FloatingOverlayPanel,MeetingOverlayController,MeetingOverlayPanel,NotchIslandController}.swift`, `UI/Settings/{SpeakerNamingSheet,TranscriptedOnboardingWindowController,TranscriptedSettingsWindowController}.swift` | ~17 | Transient overlays and transcript windows stay out of screen capture. Settings and onboarding stay capturable. Every new window gets classified. The pill scopes Return and Escape. Detected prompts use the capture pill. | **deleted (partial)**: the `FloatingOverlayPanel` and `CapturePillPanel` rows left the source table; "FloatingOverlayPanel is excluded from screen capture" and "CapturePillPanel is excluded from screen capture" build them for real. The rest is keep (privacy scan across `Sources/UI`). PR #1949 cut more of these; see `.agents/test-shape-baseline.json` for what's left. |
| `ParakeetRecoveryStateTests.swift` | `Speech/ParakeetDeviceRecovery.swift`, `ParakeetInputRoute.swift` (was `ParakeetEngine.swift`) | 10 | AUHAL and notification callbacks are timestamped on arrival, carry setter ownership, and confirm or fail echo ownership. | needs-seam: audio-graph driver protocol. |
| `ParakeetMicrophoneSharingSourceContractTests.swift` | every engine file through `readParakeetEngineSource()`, `ParakeetDeviceRecovery.swift` | ~16 | Dictation rechecks call apps around every start. Sharing recovery is forced and keeps event-time suppression. Native teardown disarms VPIO without creating an input node. | **converted (partial)**: the owned-graph downgrade probe, the stop-in-progress guard, buffer preservation, and failed-VPIO graph disposal are behavior tests in `ParakeetAudioGraphTests.swift`. Rest needs-seam: start wiring and the route-change handler's policy arguments. The native `AVAudioEngine` teardown order is keep until a real-engine test can check it. |
| `ParakeetShortAudioGateTests.swift` | `UI/Overlay/DictationSessionController.swift` | 5 | A mis-tap closes like a cancel, counts as cancelled, and shows no error. | needs-seam: the policy is covered by "treats only a quick, too-short press as a mis-tap"; the controller wiring needs the pipeline seam. |
| `SentryEventPolicyTests.swift` | `Meeting/MeetingSessionController.swift`, `Observability/SentryEventPolicy.swift`, `TranscriptedCore/Speaker/SpeakerFinalizationFailure.swift`, `UI/Overlay/DictationSessionController.swift` | ~10 | Every allowlisted Sentry tag key survives the sanitizer. The mic-not-ready cancel is recorded at `.error`. Meeting stop emits one canonical terminal before degraded-capture reporting. Core speaker reasons stay searchable. | needs-seam. Smallest: make `SentryEventPolicy.allowedDiagnosticTagKeys` internal so the test iterates it instead of parsing it. The Core raw-value cross-check is keep. PR #1949 cut more of these; see `.agents/test-shape-baseline.json` for what's left. |
| `RetranscribeLocalSpeakerPreferenceContractTests.swift` | `Meeting/MeetingSessionController.swift`, `Meeting/TranscriptionQueueCoordinator.swift` | 7 | Every meeting transcription entry point (retranscribe, live queue, preserved failures) reads People in the room from the preference. | needs-seam: meeting capture protocol. |
| `RetainedDataSourceComboBoxTests.swift` | `UI/Settings/SpeakerNameAutocompleteField.swift`, `SpeakerNamingSheet.swift` | 3 | Speaker name boxes never hand AppKit an unretained data source. | needs-seam: compile `SpeakerNameAutocompleteField` (or give it a factory for its combo box) so a test can check the box type and that its source survives. PR #1949 cut more of these; see `.agents/test-shape-baseline.json` for what's left. |
| `RecordedAudioTimelineTests.swift` | `Speech/ParakeetSharedMeetingMicBridge.swift` | 0 | Borrowed meeting PCM always reaches the shared recorder, with no live-display gate. | **converted** in PR #1949: no source reads left. |
| `StatusItemPresentationTests.swift` | `TranscriptedApp.swift`, `UI/MenuBar/MenuBarGlyph.swift` (plus the docs icon generator) | ~10 | The status item uses the `MenuBarGlyph` states with accessible labels and no stock symbol or red. Glyph geometry matches the SVG generator. | **converted (partial)**: the `MenuBarGlyph` pin now renders every glyph and checks it is a template drawn in neutral ink. Rest needs-seam: a compiled function returning (glyph, label) for the capture state. The generator-sync suite is keep. PR #1949 cut more of these; see `.agents/test-shape-baseline.json` for what's left. |
| `STTRouterPolicyTests.swift` | `Speech/STTRouter.swift` | 0 | Both Parakeet variants wait for the model with a deadline. Recording establishes the resolved variant before capture. Apple Speech is wired through every engine switch. | **converted** in PR #1949: no source reads left. |
| `TestHelpers.swift` | `Speech/` engine files | 0 | Shared readers (`readSourceFixture`, `readParakeetEngineSource`) for the pinned suites. | keep: remove `readParakeetEngineSource` when its last caller converts. The device-recovery, zombie and system-input readers are gone. |
| `SingleInstanceGuardTests.swift` | `TranscriptedApp.swift` | 5 | Reopening the app surfaces the existing controls (onboarding, popover, settings fallback) without a modal alert. | needs-seam: a compiled reopen policy that returns which surface to show. |
| `UIAutomationSurfaceContractTests.swift` | 30+ files under `UI/`, `Meeting/`, `TranscriptedApp.swift`, `TranscriptedMenuCommands.swift` | ~109 | Menubar, Settings, and Home controls keep stable AX identifiers, hit targets, and shortcuts for the QA AX smoke. Empty and error states teach and act. Design tokens have one source. | keep: identifier contract with external automation. The copy and UX pins (WS4 states, the unverified-audio pill) are needs-seam. |
| `WhisperCustomDictionaryTests.swift` | `Speech/WhisperEngine.swift` | 0 | Whisper output goes through the custom dictionary before it is returned. | **converted** in PR #1949: no source reads left. |

## Outside the grep

Two more root tests pinned Parakeet source through the `readParakeet*Source()` helpers in
`TestHelpers.swift`, so the literal-path grep above misses them:

- `ParakeetAudioOwnershipSourceContractTests.swift`: **converted (partial)** by the audio-graph
  seam (`ParakeetAudioGraph`, `ParakeetAudioGraphSequences`). Delayed-cleanup ownership, rebuild
  and abandon, zombie reset and cancellation, the blocked-start timeout, the stop and route-change
  orderings, the route restart and the recovery snapshot lease are behavior tests in
  `ParakeetAudioGraphTests.swift`. One helper read is left: the start path's lease checks inside
  `startRecording` and the tap closure, which are not behind the seam yet.
- `ParakeetStartRecordingFailurePolicyTests.swift`: no source reads left after PR #1949

`PermissionStateHarnessContractTests.swift` reads `Tools/TranscriptedQA/Sources/...`, which is
another package's source, not app source.

## What changed in this pass

Behavior assertions replaced 12 pins (counting the two table rows dropped from the
screen-share table) across 8 files, and 19 behavior assertions were added:

- `AgentConnectionGuideTests.swift`: relocates the capture library between reads (+3).
- `AuditRegressionCoverageContractTests.swift`: runs the paster with a non-frontmost target and
  with a failing dispatcher (+5).
- `ObservabilityLogWriterTests.swift`: prepares a pre-existing 0644 log and checks it comes back
  0600 with its records intact (+5).
- `FocusOrderContractTests.swift`: checks page identifiers and ⌘ shortcut order (+2).
- `StatusItemPresentationTests.swift`: renders each glyph and checks template and neutral ink (+2).
- `FailedMeetingPresentationTests.swift`: calls `retryDisabled` for complete, missing,
  non-retryable, and silent audio (+2).
- `ClipboardRestoringTextPasterTests.swift` and `OverlayScreenSharePrivacyTests.swift`: pins
  deleted where an existing behavior suite already covers them.

## Phase 2: the FailedMeetingItem seam

`FailedMeetingItem` moved out of `FailedMeetingStore.swift` (where the wave-2 audit had put it,
aliased from `MeetingSessionController`) into `Sources/Meeting/FailedMeetingItem.swift`, nested
under `FailedMeetingPresentation`. Both files are now in `APP_SOURCES`. That turned the three
`FailedMeetingPresentation.swift` source reads in `FailedMeetingPresentationTests.swift` (10
assertions) into seven behavior suites that write real audio files to a temp folder and check
the row that comes back: a lone mic placeholder is revealable but not retry-ready, a missing mic
file doesn't hide retry while system audio survives, WAVs (any case) read as raw audio only
while they're on disk, and titles, retry counts, and a running retry show in the row. The
file's source-text count went 6 -> 3 (baseline 501 -> 498).
