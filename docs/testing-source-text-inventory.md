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

That returns 51 files (50 test files plus `Tests/TestHelpers.swift`). SPM tests under
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

- `Sources/UI/Overlay/DictationSessionController.swift` is read by 16 files. Its start and
  stop paths (sound cues, mis-taps, session cap, Paste Anyway, checkpoints, telemetry) are
  pinned as ordered strings. Smallest seam: a compiled stop/start pipeline type that takes its
  collaborators (stop mic, play cue, snapshot, transcribe, paste, persist, track) as closures
  and that the controller calls. A fake then records the order, so "the stop click plays after
  the mic stops and before transcription" becomes an event-order assertion.
- `Sources/Speech/ParakeetEngine.swift` and `ParakeetDeviceRecovery.swift` are read by 7 files
  in this table, plus the two files listed under "Outside the grep" below. Smallest seam: an
  audio-graph driver protocol for the `AVAudioEngine` calls (install/remove tap, stop, set
  input device, read formats, VPIO) so the engine's ordering and ownership logic can run
  against a recording fake.
- `Sources/Meeting/MeetingSessionController.swift` is read by 9 files. Smallest seams: move
  `MeetingSessionController.FailedMeetingItem` to its own file (lets
  `FailedMeetingPresentation.swift` compile in the runner), and extract
  `handleUnexpectedCaptureStop` and the retranscribe/preserve entry points behind a small
  capture protocol.

## Inventory

Paths in "Reads" are relative to `Sources/` unless shown otherwise.

| File | Reads | Pins | Promise(s) | Verdict |
| --- | --- | --- | --- | --- |
| `AgentConnectionGuideTests.swift` | `UI/Shared/AgentConnectionGuide.swift` | 1 | The folder-path copy is computed on every read, so a relocated capture library shows up. | **converted**: the suite relocates the capture library between two reads of `folderPathsText`. No source reads left. |
| `AnalyticsEventForwardingPolicyTests.swift` | `Observability/EventReporter.swift` | 2 | `EventReporter.capture` runs the forwarding policy on the caller's own context, so pinned-mic facts reach PostHog without engine state. | needs-seam: inject an analytics sink closure into `EventReporter` (or extract the forwarding step into a pure function) and compile it in the runner. |
| `AnalyticsEventPolicyTests.swift` | `Observability/WorkflowRecoveryTelemetry.swift`, `TranscriptedApp.swift`, `Meeting/MeetingSessionController.swift`, `TranscriptedCore/Speaker/SpeakerFinalizationFailure.swift` (plus docs, `.psv` taxonomy, MCP tool source) | ~12 | Workflow recovery sends the allowlisted bucket key and a separate failed event. Meeting prompt events fire exactly once per path. Every Core speaker-finalization reason survives the sanitizer. Docs and taxonomy match the allowlist. | needs-seam: give `WorkflowRecoveryTelemetry` a `track` closure (like `DictationPasteRetryTelemetry.performUserRetry`) and move prompt-event firing into the compiled `MeetingPromptTelemetry`. The docs, taxonomy, MCP, and Core raw-value cross-checks are keep (cross-package and doc contracts). |
| `AudioAutomationCoverageContractTests.swift` | none as code (names `Meeting/MeetingTranscriptStyler.swift` as data) | 0 | The daily audio script names every route lane, issue 500 manual proof stays explicit, and the E2E smoke compiles the transcript styler from the right shared array. | keep: script and doc contract. |
| `AuditRegressionCoverageContractTests.swift` | `UI/Overlay/MeetingOverlayController.swift`, `UI/MenuBar/MenuBarPanelController.swift`, `Support/ClipboardRestoringTextPaster.swift`, `Meeting/TranscriptionQueueCoordinator.swift` | 9 | Pasteback re-checks the target before Cmd+V and downgrades to copied; a failed dispatch falls back to copy. Overlay and menubar duration ticks collapse to whole seconds. Terminal status handlers revisit the background queue. | **converted (partial)**: the pasteback suite runs the real paster with a non-frontmost target and a failing dispatcher (3 pins out). Rest needs-seam: one compiled whole-second duration publisher both controllers use; the queue revisit as a compiled coordinator policy. |
| `BluetoothRouteContractTests.swift` | `Speech/ParakeetEngine.swift`, `ParakeetDeviceRecovery.swift`, `ParakeetSystemInputCoordination.swift`, `PersistentDictationInputController.swift`, `TranscriptedApp.swift` | ~84 | The dictation tap uses the delivered buffer rate, not the AirPods HFP rate. The forced input override lands before any format read. Failed binding can't publish readiness. The system input override is restored after recording. Persistent input follows reconnects and waits for active dictation. | needs-seam: audio-graph driver protocol (see above). The QA-report suite is keep. |
| `CaptureLibraryPathSafetySyncTests.swift` | compares three copies of `CaptureLibraryPathSafety.swift` | 3 | The three synced copies stay byte-identical. | keep: sync check is the point. |
| `CrashReporterOptionsTests.swift` | `Observability/CrashReporter.swift` | 5 | Sentry privacy and noise options (no PII, no auto sessions, no network breadcrumbs, zero breadcrumbs, no stack traces, no failed-request capture) are set once before `SentrySDK.start`. | needs-seam: move the option values into a compiled function that applies them to a small protocol the Sentry `Options` type conforms to, so a fake records them. |
| `ClipboardRestoringTextPasterTests.swift` | `Support/ClipboardRestoringTextPaster.swift`, `UI/Overlay/DictationSessionController.swift`, `UI/Overlay/FloatingOverlayController.swift` | ~15 | AX reads are bounded to 50 ms. The focused-element cast is type-checked. The Core import stays `canImport`-guarded. An ambiguous paste never offers a duplicate paste. Provider reads never confirm a paste or arm Auto Enter. | **deleted (partial)**: the provider-read pin is gone; covered by "a likely paste into a selected target never authorizes Auto Enter" and "a read with a silent AX source is a likely paste, not a confirmed one". Rest needs-seam: inject an AX element reader into `FocusedTextPasteConfirmation.capture()`; controller suite waits on the dictation pipeline seam. |
| `ContextCaptureEnginePolicyTests.swift` | `Capture/ContextCaptureEngine.swift`, `TranscriptedAppState.swift`, `UI/Overlay/DictationSessionController.swift` | ~32 | Hotkeys debounce per action with push-to-talk exempt. The paste callback survives re-registering. A disabled tap reconciles a missed push-to-talk release. The tap runs on its own run loop. An Accessibility grant re-registers hotkeys. Wake recovery reads the registration error, not the advisory banner. A press while finishing shows a message. | needs-seam: move the file-private `PhysicalShortcutDetector` into its own compiled file with an injected key-state probe and callback. |
| `DeviceRecoveryPolicyTests.swift` | `Speech/ParakeetDeviceRecovery.swift` | ~17 | Recovery keeps recording intent across a Bluetooth notification burst and only the current task releases it. Binding waits poll and stale snapshots can't commit. A cancelled session is never rebuilt. | needs-seam: audio-graph driver protocol. |
| `DictationInputDeviceSelectionPolicyTests.swift` | `Speech/ParakeetPinnedMicrophone.swift` | ~6 | Warmup is judged on the same selection the start records and turns back on after an engine fallback. Pinned dictation steers off a Bluetooth headset unless the Microphone choice keeps the macOS input, and a chosen mic always wins. | needs-seam: move the argument building in `pinnedDictationInputSelection()` into a compiled `PinnedDictationInputPolicy` function and the fallback flag into a small compiled state type. |
| `DictationAudioRecoveryTests.swift` | `Speech/ParakeetEngine.swift`, `UI/Overlay/DictationSessionController.swift` | ~16 | Route recovery keeps a multi-segment timeline with native rates, cleans up through one path, and a stop always reaches the engine. | needs-seam: audio-graph driver protocol. |
| `DictationLanguageScriptPolicyTests.swift` | `Speech/STTRouter.swift`, `UI/Overlay/DictationSessionController.swift` | 4 | Paste Anyway pastes and saves the held-back text instead of dropping it. | needs-seam: dictation pipeline seam. |
| `DictationQueuedStartPolicyTests.swift` | `Capture/ContextCaptureEngine.swift`, `UI/Overlay/DictationSessionController.swift`, `UI/Overlay/FloatingOverlayController.swift` | ~10 | Presses during a finishing take go through the queue. Esc and Quit drop a waiting start. A passing note gives way to the next take. A refused Quit lets presses queue again. | needs-seam: dictation pipeline seam (the policy itself is already tested in this file). |
| `DictationRecordingStartOverlayPolicyTests.swift` | `Capture/ContextCaptureEngine.swift`, `Meeting/MeetingSessionController.swift`, `UI/Overlay/DictationSessionController.swift` | ~25 | The early-release message comes from the policy. A repeated Stop is fenced before the loading cancel. An unexpected meeting stop hands the mic back to dictation. The start handle is cleared on the recovery path. | needs-seam: dictation pipeline seam; meeting unexpected-stop seam. |
| `DictationSessionCapTests.swift` | `UI/Overlay/DictationSessionController.swift`, `UI/Overlay/OverlayHeaderView.swift` | ~19 | The five-minute cap warns, pastes only if the original target is still frontmost, saves to Markdown with a Paste It action, and an interruption with preserved audio offers Transcribe. | needs-seam: dictation pipeline seam. |
| `DictationRecordingStartAttemptTests.swift` | `Speech/DictationSession.swift`, `UI/Overlay/DictationSessionController.swift` | ~8 | Both production start paths use the tested failure-only recovery runner, at most once per session. | needs-seam: compile `DictationSession.swift` in the runner, or pass the runner into the controller. |
| `DictationSoundsTests.swift` | `UI/Overlay/DictationSessionController.swift`, `UI/Settings/TranscriptedSettingsView.swift`, `UI/Shared/TranscriptedSupportActions.swift` | 8 | The stop click plays once, after the mic stops (so speakers can't leak it into the take) and before transcription and paste. The start click plays once, on the fast path. Feedback submit stays silent. | needs-seam: dictation pipeline seam with an injected sound player. |
| `DictationStartReadinessTests.swift` | `Speech/DictationSession.swift`, `UI/Overlay/DictationSessionController.swift` | ~19 | Hotkey trigger raw values match `DictationTrigger`. The App Nap reason uses a label the readmission sites set. The cancel diagnostic names the pending stage. Recovery-loop stage reports reach the session-scoped controller. | needs-seam. Smallest first step: move `DictationTrigger` into the compiled `Speech/DictationSessionTypes.swift` so the raw-value suite compares enums directly. |
| `DictationStartedTelemetryContractTests.swift` | `UI/Overlay/DictationSessionController.swift` | 18 | `dictation_started` fires only after the mic starts. `dictation_start_requested` fires before any guard and before the session id. Guard refusals and retries are labelled. Warmup failures count as start failures. | needs-seam: dictation pipeline seam with an injected `track` closure. |
| `DictationTerminationCheckpointTests.swift` | `TranscriptedApp.swift`, `UI/Overlay/DictationSessionController.swift` | ~15 | Quit defers while audio isn't checkpointed and replies false before meeting or app shutdown. New capture and Retry Saving wait on the old checkpoint. A failed snapshot is fenced before inference. | needs-seam: dictation pipeline seam (the admission policy itself is already tested in this file). |
| `DictationStoppedAudioRecoveryTests.swift` | `Meeting/MeetingSessionController.swift`, `Speech/ParakeetEngine.swift`, `Speech/STTRouter.swift`, `TranscriptedApp.swift`, `UI/Overlay/DictationSessionController.swift` | ~28 | Stop writes a private WAV checkpoint off the main actor before waiting on the model. External model errors keep usable audio. | needs-seam: dictation pipeline seam. |
| `DictationTranscriptPersistenceTests.swift` | `UI/Overlay/DictationSessionController.swift` | 3 | Session-cap completion labels delivery and failure only after proof of save. | needs-seam: the policy is covered by "Session-cap completion labels a failed Markdown save as failed delivery"; the controller wiring needs the pipeline seam. |
| `ExistingInstallModelPrefetchPolicyTests.swift` | `TranscriptedAppState.swift` | 5 | Models warm at launch unless `TRANSCRIPTED_LAZY_MODEL_WARMUP=1`. Meeting models warm too. Dictation warms at user priority, the pass at utility. | needs-seam: move the environment check and the two priorities into the compiled `ExistingInstallModelPrefetchPolicy`. |
| `FailedMeetingPresentationTests.swift` | `Meeting/FailedMeetingPresentation.swift`, `Meeting/MeetingSessionController.swift`, `UI/Settings/FailedMeetingRecoveryPresentation.swift`, `UI/Settings/HomeView.swift`, `UI/Settings/TranscriptedSettingsView.swift` | ~19 | Skipped no-speech outcomes surface a visible error. Retry needs all audio while partial audio stays revealable. Retained WAVs read "raw audio kept". Retry counts show in metadata. Cleanup is a confirmed delete. | **converted (partial)**: the retry-readiness helper pin now calls `FailedMeetingRecoveryPresentation.retryDisabled`. Rest needs-seam: move `FailedMeetingItem` out of `MeetingSessionController` so `FailedMeetingPresentation.swift` compiles here. |
| `FocusOrderContractTests.swift` | `UI/MenuBar/MenuBarActionRowView.swift`, `MenuBarContentView.swift`, `MenuBarPrimaryActionsView.swift`, `MenuBarUtilityActionsView.swift`, `UI/Settings/TranscriptedSettingsPage.swift`, `TranscriptedSettingsSidebar.swift` | 9 | Menu bar rows are focusable and chained in the declared order. Settings sidebar pages produce the declared identifiers in ⌘1–⌘5 order. | **converted (partial)**: page identifiers and order now come from `TranscriptedSettingsPage` (2 pin call sites out). Rest needs-seam: compile the menu bar row/section views and `SettingsSidebarSection` so `keyboardFocusableRows` and `primarySection` can be checked directly. |
| `HomeFirstArtifactVisibilityTests.swift` | `UI/Overlay/MeetingOverlayRootView.swift`, `UI/Settings/HomeView.swift`, `Pages/HomeSettingsPage.swift`, `QuietDictationLibrary.swift`, `QuietHomeLibrary.swift`, `TranscriptedSettingsView.swift` | 10 | Dictation rows show Open file and "saved only" on a failed paste. Only active work spins. The meeting overlay says "Saved to Markdown". Copy for agent prefers the portable bundle. Old vague copy doesn't return. | needs-seam: move the row and overlay copy and the tone-to-icon choice into a compiled presentation type the views read. |
| `HomeImportAudioActionTests.swift` | `UI/Settings/HomeView.swift`, `Pages/GeneralSettingsPage.swift`, `Pages/HomeSettingsPage.swift`, `TranscriptedSettingsView.swift` | 6 | Settings has a "Transcribe a file" row wired to `importAudioFile()`, and Home's empty meetings state offers the same route. | needs-seam: move the row and empty-state copy and identifiers into the compiled `HomeCaptureListCopy` and route the action through a compiled action table. |
| `MeetingMicrophonePreferencesTests.swift` | `Meeting/MeetingCaptureBridge.swift` | 3 | Meeting start picks the mic mode through the recorder-aware check and applies a Settings mic only while the recorder shows that picker. | needs-seam: a compiled `MeetingMicrophonePreferences` function that returns the mode and device UID the bridge applies. |
| `MeetingStopSnapshotEvidenceTests.swift` | `Meeting/MeetingSessionController.swift` | 6 | Unexpected-stop evidence (status, warning, unheard seconds) is stashed before the warning clears and used by the stop snapshot. | needs-seam: meeting unexpected-stop seam. |
| `MeetingSessionUIPolicyTests.swift` | `Meeting/MeetingSessionController.swift`, `UI/MenuBar/MenuBarPanelController.swift`, `UI/Overlay/MeetingOverlayController.swift` | ~21 | Audio sleep/wake listens on the workspace center. Unexpected stop leaves recording before any await. Start returns false for an active capture. Discard needs `session.recording` and re-checks after confirm. Menu start/stop uses capture-active state. | needs-seam: meeting capture protocol plus a compiled overlay-menu policy. |
| `MicrophoneProcessingPreferencesTests.swift` | `Meeting/MeetingCaptureBridge.swift`, `UI/Settings/TranscriptedSettingsView.swift` | 10 | Boost Mic arms voice processing for the live meeting without saving the mode and respects a call app on the mic. Only a successful start uses up the next-meeting boost. | needs-seam: same `MeetingCaptureBridge` extraction as above. |
| `MicrophoneChoicePreferencesTests.swift` | `UI/Settings/TranscriptedSettingsView.swift` | 5 | Settings shows the one Microphone picker only while the recorder is on and keeps the older rows otherwise. | needs-seam: a compiled layout policy the settings view switches on. |
| `ParakeetAudioGraphOwnershipTests.swift` | `Speech/ParakeetEngine.swift`, `ParakeetDeviceRecovery.swift` | 2 | A config-change restart keeps the same recording claim when segments are retained. | needs-seam: audio-graph driver protocol. |
| `NightlySecurityContractTests.swift` | none as code (a manifest names `Observability/AnalyticsEventPolicy.swift` as data) | 0 | The nightly security checker, entitlement manifest, and docs stay in step. | keep: script, manifest, and doc contract. |
| `ObservabilityLogWriterTests.swift` | `Observability/AppLogSink.swift`, `EventReporter.swift`, `LockedFileAppender.swift`, `ObservabilityLogRotation.swift`, `ReliabilityPacketRecorder.swift`, `TranscriptedApp.swift`, `TranscriptedCore/Logging/FileLogger.swift`, `TranscriptedCore/Speaker/RetroactiveSpeakerUpdater.swift` | ~17 | Shutdown flushes buffered events. Local events carry build identity. The reliability recorder sees raw events. Logs are made owner-only before append. `AppLogSink` redacts. Console diagnostics avoid absolute paths. No NSException-throwing `FileHandle` APIs. | **converted (partial)**: log-file preparation now runs `ObservabilityLogFilePreparation.openPreparedHandle` on a world-readable log. Rest needs-seam: compile `EventReporter` and `AppLogSink` with an injected writer. The legacy `FileHandle` sweep is keep (banned-API lint across two build units). |
| `OverlayScreenSharePrivacyTests.swift` | `TranscriptedApp.swift`, `UI/MenuBar/PasteLastDictationFeedback.swift`, `UI/Overlay/{CapturePillController,FloatingOverlayPanel,MeetingOverlayController,MeetingOverlayPanel,NotchIslandController}.swift`, `UI/Settings/{SpeakerNamingSheet,TranscriptedOnboardingWindowController,TranscriptedSettingsWindowController}.swift` | ~17 | Transient overlays and transcript windows stay out of screen capture. Settings and onboarding stay capturable. Every new window gets classified. The pill scopes Return and Escape. Detected prompts use the capture pill. | **deleted (partial)**: the `FloatingOverlayPanel` and `CapturePillPanel` rows left the source table; "FloatingOverlayPanel is excluded from screen capture" and "CapturePillPanel is excluded from screen capture" build them for real. The rest is keep (privacy scan across `Sources/UI`). |
| `ParakeetRecoveryStateTests.swift` | `Speech/ParakeetDeviceRecovery.swift`, `ParakeetEngine.swift` | 10 | AUHAL and notification callbacks are timestamped on arrival, carry setter ownership, and confirm or fail echo ownership. | needs-seam: audio-graph driver protocol. |
| `ParakeetMicrophoneSharingSourceContractTests.swift` | `Speech/ParakeetEngine.swift`, `ParakeetDeviceRecovery.swift` | ~37 | Dictation turns voice processing off while a call app is open without changing the saved mode. Call-app launch recovery only downgrades an owned active graph. Teardown disarms voice processing without creating an input node. A failed disable never becomes shared capture. | needs-seam: audio-graph driver protocol. |
| `ParakeetShortAudioGateTests.swift` | `UI/Overlay/DictationSessionController.swift` | 5 | A mis-tap closes like a cancel, counts as cancelled, and shows no error. | needs-seam: the policy is covered by "treats only a quick, too-short press as a mis-tap"; the controller wiring needs the pipeline seam. |
| `SentryEventPolicyTests.swift` | `Meeting/MeetingSessionController.swift`, `Observability/SentryEventPolicy.swift`, `TranscriptedCore/Speaker/SpeakerFinalizationFailure.swift`, `UI/Overlay/DictationSessionController.swift` | ~10 | Every allowlisted Sentry tag key survives the sanitizer. The mic-not-ready cancel is recorded at `.error`. Meeting stop emits one canonical terminal before degraded-capture reporting. Core speaker reasons stay searchable. | needs-seam. Smallest: make `SentryEventPolicy.allowedDiagnosticTagKeys` internal so the test iterates it instead of parsing it. The Core raw-value cross-check is keep. |
| `RetranscribeLocalSpeakerPreferenceContractTests.swift` | `Meeting/MeetingSessionController.swift`, `Meeting/TranscriptionQueueCoordinator.swift` | 7 | Every meeting transcription entry point (retranscribe, live queue, preserved failures) reads People in the room from the preference. | needs-seam: meeting capture protocol. |
| `RetainedDataSourceComboBoxTests.swift` | `UI/Settings/SpeakerNameAutocompleteField.swift`, `SpeakerNamingSheet.swift` | 3 | Speaker name boxes never hand AppKit an unretained data source. | needs-seam: compile `SpeakerNameAutocompleteField` (or give it a factory for its combo box) so a test can check the box type and that its source survives. |
| `RecordedAudioTimelineTests.swift` | `Speech/ParakeetSharedMeetingMicBridge.swift` | 2 | Borrowed meeting PCM always reaches the shared recorder, with no live-display gate. | needs-seam: audio-graph driver protocol (or move the append into a compiled forwarder). |
| `StatusItemPresentationTests.swift` | `TranscriptedApp.swift`, `UI/MenuBar/MenuBarGlyph.swift` (plus the docs icon generator) | ~10 | The status item uses the `MenuBarGlyph` states with accessible labels and no stock symbol or red. Glyph geometry matches the SVG generator. | **converted (partial)**: the `MenuBarGlyph` pin now renders every glyph and checks it is a template drawn in neutral ink. Rest needs-seam: a compiled function returning (glyph, label) for the capture state. The generator-sync suite is keep. |
| `STTRouterPolicyTests.swift` | `Speech/STTRouter.swift` | ~13 | Both Parakeet variants wait for the model with a deadline. Recording establishes the resolved variant before capture. Apple Speech is wired through every engine switch. | needs-seam: an engine-factory protocol for `STTRouter`. |
| `TestHelpers.swift` | `Speech/ParakeetDeviceRecovery.swift`, `ParakeetEngine.swift`, `ParakeetSystemInputCoordination.swift`, `ParakeetZombieEngineRecovery.swift` | 0 | Shared readers (`readSourceFixture`, `readParakeet*Source`) for the pinned suites. | keep: remove the `readParakeet*` helpers when their last caller converts. |
| `SingleInstanceGuardTests.swift` | `TranscriptedApp.swift` | 5 | Reopening the app surfaces the existing controls (onboarding, popover, settings fallback) without a modal alert. | needs-seam: a compiled reopen policy that returns which surface to show. |
| `UIAutomationSurfaceContractTests.swift` | 30+ files under `UI/`, `Meeting/`, `TranscriptedApp.swift`, `TranscriptedMenuCommands.swift` | ~109 | Menubar, Settings, and Home controls keep stable AX identifiers, hit targets, and shortcuts for the QA AX smoke. Empty and error states teach and act. Design tokens have one source. | keep: identifier contract with external automation. The copy and UX pins (WS4 states, the unverified-audio pill) are needs-seam. |
| `WhisperCustomDictionaryTests.swift` | `Speech/WhisperEngine.swift` | 2 | Whisper output goes through the custom dictionary before it is returned. | needs-seam: a compiled finalizer function `WhisperEngine` returns through. |

## Outside the grep

Two more root tests pin Parakeet source through the `readParakeet*Source()` helpers in
`TestHelpers.swift`, so the literal-path grep above misses them. Both are needs-seam
(audio-graph driver protocol):

- `ParakeetAudioOwnershipSourceContractTests.swift` (about 11 helper reads)
- `ParakeetStartRecordingFailurePolicyTests.swift` (about 9 helper reads, next to real policy tests)

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
