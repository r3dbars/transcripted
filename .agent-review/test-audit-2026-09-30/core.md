# Transcripted core test audit

Audit baseline: `85bbcc09380f6de16e73119efb672e5e6a628f72` (remote main), 2026-09-30.
Lane: Core package, integration/executor smokes and concurrency proof routing. Parent owns the complete cross-repository audit and execution.

## Method and scope

Applied the OpenClaw test-audit gates supplied by the coordinator: observable contract, credible regression, distinct value beyond stronger existing proof, and no production seam that exists only for the test. This is a contract audit, with no deletion quota. Read repository `AGENTS.md`, `Tests/README.md`, the Core owner guide, package target routing and matrix/CI routes. Inventoried every Core Swift test/helper file and test method; screened assertions, source reads, async waits, fixture dependencies and skips across that inventory. Candidate methods and relevant owners/callers/overlap/history received focused inspection. This is not a line-by-line correctness certification of every source implementation or all 1,637 test methods.

Counts at baseline: **135 Swift files**, including **133 files with XCTest cases and two shared helper files**, containing **1,637 XCTest methods**. All five targets use XCTest, and import the real `TranscriptedCore`; dependencies are prebuilt native libraries/modules, not newly installed packages. Shared `TranscriptionTaskManagerMetadataTests` extensions remain in the same `PipelineTests` target, so a class filter legitimately spans multiple files. `SpeakerNamingSimulationRunner.swift` and `TranscriptSaverTestHelpers.swift` are helper code, not extra test cases.

| Target | Swift files | Files with cases | XCTest methods |
| --- | ---: | ---: | ---: |
| AudioTests | 43 | 43 | 588 |
| PipelineTests | 22 | 22 | 353 |
| SpeakerTests | 46 | 44 | 530 |
| StorageTests | 17 | 17 | 84 |
| UtilitiesTests | 7 | 7 | 82 |

## Prioritized findings

### P1 — Replace a scheduler-speed assertion with a held dependency proof (implemented)

Exact candidate: `AudioTests/AudioInitializationTests.swift`, `testStartIfNotCancelledCancelDuringStartDoesNotBlock`, baseline lines 582–625.

Promise: cancelling one system-audio start may complete while its backend's start is still blocked; a replacement attempt may start independently; the cancelled attempt must not publish successful start and must be stopped.

Baseline weakness: the test already holds `oldCapture.start` behind a semaphore, but measures `cancel()` under 0.25 seconds. A slow worker can turn correct code red. Worse, its held fake automatically releases itself after two seconds, which would obscure the intended ordering if someone merely widened the performance limit. This is a test-quality finding, not a confirmed historical flake of this particular method. The test was introduced in `d49b72bd` (PR #1711, meeting sleep/wake and stop recovery).

Owner: `Sources/TranscriptedCore/Audio/AudioFileManager.swift`, `SystemAudioCaptureStartAttempt.startIfNotCancelled` releases `lifecycleLock` before calling the backend, and `cancel` marks cancellation and tears down the backend. The app/Core capture executor constructs this attempt in `startAudioCapture`; Audio owns it through `SystemAudioCaptureAttemptOwnership`. Native `SCKAudioCapture.start` can await OS callbacks, so keeping the caller's lifecycle lock across that call is a credible regression. Related tests cover cancellation during prepare, displacement of old attempts, stopped writer ownership and backend finish/drain, but none replaces this start-versus-cancel boundary.

Bounded implementation is in **only this method**: execute cancellation on another queue; await `cancelReturned` while the old start remains held; start the fresh attempt before releasing the old start; preserve failed old-start, stop count and fresh-start assertions. A `defer` always releases the held start, which has no timed self-release. Five-second waits are harness failure deadlines, not a latency promise. No production code or test seam changed.

Four gates: passes all four. The oracle observes real attempt completion/results; lock-across-start is credible; other tests cover different windows; existing injected backend is the production protocol seam. No deletion is unlocked beyond the replaced wall-clock assertion.

Negative control design for parent: in a disposable probe tree, keep `lifecycleLock` held across `capture.start`, adjusting the following lock acquisition correctly. The `cancelReturned` expectation must fail while the held start is unreleased; the eventual cleanup must still finish after release. Do not accidentally create a recursive-lock bug as the mutation. Parent must run and record this; this lane did not run it.

Focused command: `TRANSCRIPTED_DISABLE_FILE_LOGGER=1 swift test --filter 'AudioInitializationTests/testStartIfNotCancelledCancelDuringStartDoesNotBlock'`. Then full `AudioInitializationTests`, package suite and matrix proof. Risk is confined to XCTest synchronization/cleanup; real backend/TCC latency is outside this synthetic claim.

### P2 — Wait for the task boundary before asserting that late cancellation has no side effects (deferred)

Exact candidates: `PipelineTests/TranscriptionTaskLifecycleStateTests.swift:172`, `testShutdownPreservationEvictsOccupancySynchronouslyBeforeTheEngineNoticesCancellation` (a fixed 200 ms sleep after `speech.release` at baseline line 206), and `TranscriptionTaskManagerFailedQueueTests.swift:791`, `testCancelAllSuppressesLateTranscriptSaveAndFailedQueue` (fixed 100 ms sleep after `didReturn`, baseline line 855).

These check important behavior and must remain: shutdown preservation must persist exactly one retry row, and cancelled inference must not later save Markdown, publish metadata, record stats or requeue deleted audio. The observable task handle is available in `manager.activeTasks` before preservation/cancellation, and the same sibling suite already waits for `manager.activeTasks.isEmpty` in `testCancelDuringRunningSuppressesLateResultFromAnUncooperativeEngine`. A delayed runner can either fail the test early or let a late erroneous side effect happen after the assertion. `didReturn` describes the fake engine, not the completion of the manager's post-inference work.

Owners/callers: `TranscriptionTaskManager.cancelAll`, `consumePreservedForShutdownMarker`, `finishCancelledTaskIfNeeded`, and the live/imported/retry pipeline task completion paths. The UI depends on the synchronous occupancy/quit-confirmation state, while the task boundary is the right barrier for eventual saved side effects. `TranscriptionTaskLifecycleStateTests` includes explicit history from PR #1636 review; `3a0cfc04` fixed committed precedence and a test hang. These are legitimate regression tests, not tautological mocks.

Proposed proof: capture the real task handle before preserve/cancel; release the uncooperative fake; await the captured task's completion; assert existing artifacts/stats/queue/counters. Keep immediate occupancy assertions before release. Do not merely increase sleeps. Negative control: allow cancelled completion to enqueue/save, and confirm the final oracle fails. No new production seam is needed. Focus on class `TranscriptionTaskManagerMetadataTests` (the extension's real XCTest class), then `swift test`.

Risk/limit: changing to a task wait must still be bounded by the test process watchdog if a product regression never completes. This lane did not author or run these changes because the chosen PR set is bounded.

### P2 — A synthetic-fixture failure is reported as a skip (deferred)

Exact candidate: `SpeakerTests/SpeakerVoiceprintMigrationTests.swift:589`, `testAnUnreadableHeldRowStaysHeldAndDoesNotBlockTheConfirmation`; helper `corruptHeldRecord` at baseline lines 609–615 throws `XCTSkip("could not open the temp target database")` when SQLite cannot open the fixture's second connection.

This test creates the entire migration fixture itself. A setup/path/database-open regression should fail the test; it is not an unavailable model/hardware prerequisite. Proposed change is assert `SQLITE_OK` and a nonnil handle, ensure close with `defer`, then keep the existing corrupt-row, user-confirmation and other-person progress assertions. This is a skipped-proof gap, not an observed CI failure.

Owner/callers: `SpeakerVoiceprintMigrationLedger.releaseHeldVoiceprintConfirmationsImpl` is called from `SpeakerConfirmationStore.recordUserConfirmations` in the same transaction and at migration startup. Sibling tests cover ordinary release, wrong-person confirmation and merged-person release; they do not replace malformed held-record isolation. History `fdcdb7a5` added held-person release-on-confirm after `edfe5269` introduced carry-forward migration. No test deletion is warranted. A negative control can replace the synthetic SQLite file's open path with a directory and must produce a failure instead of a skipped pass. Focus `swift test --filter 'SpeakerVoiceprintMigrationTests/testAnUnreadableHeldRowStaysHeldAndDoesNotBlockTheConfirmation'`.

### P2 — Model present but load broken is also skipped (deferred)

Exact candidates: `SpeakerTests/ERes2NetEmbedderModelTests.swift:21` (shared loader for nine tests) and `ERes2NetEmbedderParityTests.swift:29` (golden parity test). They correctly skip when the optional staged CoreML artifact is absent, but also skip when that present artifact cannot load. The declared optional boundary has already been met then, and a bad conversion/API/load regression can disappear into a skip.

Proposed proof: keep absence/availability skips; use `XCTUnwrap` or throw a test failure for a present artifact that fails to load. The pure windowing tests and generic fake-model tests do not establish native CoreML load/parity. The staged artifact is a read-only optional prerequisite, not a reason to install or download models during default CI. No production edits and no deletion are needed. History includes the original parity/conversion contract and model wrapper upgrades; no false CI failure was demonstrated here. Run only with a known synthetic approved staged artifact; default hosted CI still cannot prove the model path.

### P3 — Add a distinct ring-wrap/producer-consumer contract (deferred coverage opportunity)

Owner: `Sources/TranscriptedCore/Audio/CoreAudioTapBufferRing.swift`, called by the production Core Audio IOProc and drained on `CoreAudioSystemAudioCapture`'s serial queue. Tests in `CoreAudioTapBufferRingTests` cover copied planar/interleaved samples, capacity overflow, oversized frames, format invalidation, host-time pairing and permission-free idempotent stop. Their push/pop calls are sequential. `CoreAudioSystemAudioCaptureTests` heavily exercises simulated drain/recovery/finish events, but its receive/drain driver does not prove simultaneous SPSC ring wraparound.

Proposed distinct promise: many buffer slots wrap with exactly paired marker samples/frame lengths/host times; a single producer and consumer see each admitted buffer once in order; returned buffers remain independently owned. Use bounded batches/handshakes so the intentional overflow latch is not activated by a fast producer, and test every channel/sample, not only the first sample. Do not pretend a stress test proves all atomic memory-order schedules. Negative control: corrupt a slot's host-time/index/copy behavior, which must fail deterministically; TSan is a separate optional tool. History `4765e686`, `86fa3df6`, `5b3a817e`, `b57da0cf`, `92495f4a` shows real continuity/overflow issues and intentionally latched loss. Keep those safety guards and diagnostics. No production hook is needed. Focus `swift test --filter CoreAudioTapBufferRingTests` plus `CoreAudioSystemAudioCaptureTests`.

### Source-fragment candidates: retain unless stronger runtime proof really replaces them

Five Core test files currently read production sources, with seven actual source-reading test methods. The shape baseline recognizes four of these files (six methods); `AudioTapInstallGuardTests.testEveryProductionInstallTapIsGuarded` is an additional whole-`Sources` scan. Merely mentioning `Sources/` in comments is not a source-text test: formatter artifact contracts, `SupersessionEpochTests`, `PipelineRollbackRegistryTests` and name-rewrite tests do not read their implementation as text.

| Source-reading test | Current contract | Why removal is not justified now |
| --- | --- | --- |
| AudioInitialization: meeting-start route settle before file/tap; mic-recovery settle before sizing segment | AirPods format changes must not create a mismatched tap/file | Pure format checks do not prove executor ordering; retain until a route-swap executor boundary is driven |
| MicOnlyRecording: diagnostics avoid stored tap; startup branches before tap factory | Explicit mic-only capture must not acquire system-audio permission or carry prior tap state | Runtime mic-only tests cover many outcomes, but full startup without a real input engine is not exercised |
| MicStopTailHandoff: finishing admission before generation bump; close after teardown | Last microphone words must reach WAV | Strong real `Audio.stop` artifact test delivers tail after `stop` returns, so it cannot see the intra-call window |
| SystemAudioStopTailHandoff: finishing armed before generation bump | Tail delivered by consumer timer during stop must survive | Existing tests prove tail bytes/drain/cancel but do not deliver exactly between those statements |
| AudioTapInstallGuard: every production tap uses exception catcher | A new unguarded AVFoundation tap must not reintroduce an ObjC exception crash | Actual raised-exception test proves one wrapper; it cannot establish all call-site coverage |

These tests can fail on reflow/rename and they should eventually migrate to stronger behavior/architecture proof. Their removal today would unlock edits without proving the guarded safety window. No demonstrated harmless-refactor failure in these specific Core source-reading methods was supplied to this lane, so none is labelled a confirmed flake. Do not add a production-only race hook simply to delete a pin.

## Retained and overlapping proof

- Keep failed-queue persistence/deletion, journal recovery, timeout promotion, symlink/out-of-root rejection, rollback and shutdown audio ownership tests. They verify real persisted files and reloaded rows, including failure injection; their setup fakes are external service boundaries, not copied orchestrators.
- Keep `DatabaseFilePermissionsTests` for SQLite DB/WAL/SHM and log trim permissions. Keep actual log redaction output and shared privacy corpus. Security/privacy/storage consistency must not be weakened for speed or green CI.
- Keep `MeetingMarkdownGoldenTests`, formatter/CaptureKit tokens, version/frontmatter corpus and route artifacts. These assert an exported storage protocol, not source formatting. The same fixtures in Core/CaptureKit/MCP intentionally constrain independently implemented readers.
- `TranscriptFormatterCaptureKitContractTests.testEveryTranscriptRowIsKitParseable` uses a local regex, and the CaptureKit sibling uses a hand-copied writer document. A future shared writer-to-real-consumer fixture would provide stronger drift proof, but current exact token/approved artifact assertions still protect distinct public contracts and should not simply disappear.
- Keep speaker matching/write-back/provenance/merge/confirmation negative cases. Preset constants are calibrated product values; comparing them is legitimate compatibility/tuning protection. Multiple normalization methods are not automatically duplicates: they sit on distinct exposed paths.
- Keep public import tests using `import TranscriptedCore` without `@testable`; they protect package visibility that internal tests cannot.
- Empty inputs, no-op repeated cancel/stop, old generation rejection, exact boundary fractions and corrupt input cases have credible observable regressions. They are not removed merely because their bodies are short.
- No whole test file met all four deletion gates with sufficient evidence. No suite/case was deleted by this lane.

## Routing and additional proof surface

`Package.swift` defines real Core production target + native exception support and the five test bundles, all sharing native deps include/link flags. A no-filter root `swift test` also includes Writing targets, which belong to the other audit lane. `swift test --filter '^AudioTests\.'` (or equivalent other target), and class/method filters are scoped development routes; there is no runtime-coverage equivalence between a narrow class run and the full root package.

Matrix `.agents/test-matrix.yml` Core/package rule (baseline lines 450–460): `bash build-deps.sh --force`, `bash build.sh --no-open`, `bash run-tests.sh`, `bash run-integration-smoke.sh`, `swift test`. CI `.github/workflows/swift-ci.yml` `spm-tests` runs `bash scripts/dev/swift-test-stall-watch.sh swift test`, prints stall samples on any result, then integration smoke. Deps are built/cached for Apple Silicon macOS 26. Hosted CI explicitly keeps real-model executable paths opt-in.

Integration inventory:

| File/entry point | Contract and substitutions | Route/limits |
| --- | --- | --- |
| Tests/Integration/AppCoreIntegrationSmoke.swift | Links actual bundled `libDraftDeps`; temporary Core paths, real speaker DB write/read/list, failed queue write/count; compile-time host initializer closure | `run-integration-smoke.sh`; does not construct real MeetingSessionController/AppServices/Parakeet, start devices or infer models |
| Tests/Integration/WakeRecoveryIntegrationSmoke.swift | Real WakeRecoveryCoordinator with scripted hotkeys/readiness/sleep collaborators | Same runner; proves join/retry/order, not OS wake/device integration |
| Tests/Integration/ParakeetLifecycle/ExecutorSmoke.swift | Production lifecycle extension, uncooperative delayed FluidAudio fake, exact stale/success/error/ownership transitions | `scripts/dev/test-parakeet-lifecycle.sh`, also integration runner; one-second operation deadlines and 30-second process deadline; excludes full engine/router/inference leases |
| Tests/Integration/ParakeetLifecycle/EngineScaffold.swift | Engine state and excluded collaborators, not duplicated lifecycle decisions | Helper for executor; real API drift still needs authoritative app build |
| Tests/Integration/ParakeetLifecycle/FakeFluidAudio.swift | Delayed download/load/init with explicit test releases; fake ignores cancellation | Test-only module in build/parakeet-lifecycle-tests; no real caches, network or microphone |
| Tests/Integration/HomeMeetingDeletion/ReservationSmoke.swift | Actual Core reservation plus real Home helper deletion/trash/undo; temp synthetic bytes and redirected Trash | `scripts/dev/test-home-deletion-reservation.sh`; 47 documented prior assertions, separately run after test-enabled Core artifacts; not OS Trash/native Home UI |
| Tests/E2E/TranscriptedE2ESmoke.swift | Dictation/meeting Markdown, retained audio resolve, MCP dirs manifest, diagnostic redaction | `run-e2e-smoke.sh`; deterministic files, no real microphone/TCC/Calendar/AX/Sparkle |
| Tests/E2E/SlowPastebackSmoke.swift | Production ClipboardRestoringTextPaster with named synthetic pasteboards and delayed fake target | `run-slow-pasteback-smoke.sh`; not native Accessibility insertion into real apps |
| AudioTests/LiveCaptureSmokeTests.swift | Synthetic signal evidence test plus opt-in production mic/system recording and external tone | Default package skips live case; `run-live-capture-smoke.sh` explicitly enables it. Not run in this lane per user constraint |

Concurrency verification is spread across gate/ring/ownership/state tests above, staged executor smokes, compiler checks and runtime stall diagnostics. `scripts/dev/concurrency-census.sh` typechecks app sources with `-strict-concurrency=complete` against `.agents/concurrency-baseline.json`; `concurrency-census.py --self-test` verifies its counting/ratchet. It is compiler-warning proof, not race-free capture proof or a benchmark. No separate `Tests/Concurrency` directory exists at this head.

## Coverage and execution limits

No heavy build, test executable, live audio, model download, private recording/user-state inspection, credential change, or CI rerun was performed by this lane. Static inventory/searches, relevant source/history reads and the focused test edit only. The coordinator must run the mutation/focused/full/repository proof against the final clean tree and exact-head CI before reporting success. This report is not a green-test claim.

Default root package coverage is not evidence of real CoreML models or corpus accuracy. Conditional dependencies include ERes2Net staged-model load/golden/inference tests, `TRANSCRIPTED_VOICEPRINT_PARITY_MANIFEST`, `TRANSCRIPTED_E2E_WAV`, `SPEAKER_EVAL_QMATRIX_DIR`, and the explicitly gated live audio smoke. Missing corpus/model fixture skips are legitimate reported limits; model-present failure skips and the temp SQLite failure skip are quality gaps called out above. `LabKnobOverridesTests` intentionally avoids its no-env check if the lab env is configured. Pure fake-model/windowing tests retain useful algorithm contracts without proving native model accuracy.

The suite has strong saved-file/database and synthetic capture-event coverage. Limits remain full app-to-Core host behavior, real microphone/Bluetooth/system audio format transitions, TCC, inference accuracy, native UI/Trash/clipboard integration, platform scheduling and all possible atomic interleavings. Root suite green must not be presented as those checks passing.

## Complete Core file inventory

Each group below is the package target/area and every path is relative to `Tests/TranscriptedCoreTests`. Cases count `func test...` definitions (not dynamic scenario loop counts or assertions). The named example is an inventory anchor, not a claim that it is the file's only contract.

### AudioTests

Capture readiness; mic/system ownership and recovery; backpressure/PCM; device routing and format; signal/resampling/health; journals; opt-in hardware smoke. All files route through the `AudioTests` root-package XCTest bundle.

| File | Cases | Example promise | Audit flags |
| --- | ---: | --- | --- |
| AudioTests/AudioCaptureStartStateTests.swift | 4 | `testSystemFramesWithoutMicFramesStayWaiting` | retained behavior/contract coverage |
| AudioTests/AudioDiagnosticsSnapshotTests.swift | 9 | `testSnapshotIncludesIssue500SignalDiagnostics` | retained behavior/contract coverage |
| AudioTests/AudioFileManagerTests.swift | 34 | `testCoreAudioErrorsRemainIndeterminateWithoutDocumentedTCCCode` | retained behavior/contract coverage |
| AudioTests/AudioFormatPolicyTests.swift | 13 | `testDisplaySampleRateRendersUsableRatesAsIntegerString` | retained behavior/contract coverage |
| AudioTests/AudioInitializationTests.swift | 44 | `testMeetingInputModeIsCapturedForTheRecordingAndSurvivesRecoveryReset` | production source read retained; cancellation ordering improved |
| AudioTests/AudioLevelMonitorSilenceTests.swift | 6 | `testLoudAudioKeepsNonSilentAndZeroDuration` | retained behavior/contract coverage |
| AudioTests/AudioLevelPublishGateTests.swift | 4 | `testBackToBackMicBuffersPublishOnce` | retained behavior/contract coverage |
| AudioTests/AudioPipelineDiagnosticsSnapshotShapeTests.swift | 9 | `testPrivacySafeContextMapsEveryField` | retained behavior/contract coverage |
| AudioTests/AudioResamplerTests.swift | 16 | `testResampleSameRateIsIdentity` | retained behavior/contract coverage |
| AudioTests/AudioSignalRecoveryTests.swift | 33 | `testAnalyzeReturnsZeroedAnalysisForEmptySamples` | retained behavior/contract coverage |
| AudioTests/AudioStateTransitionTests.swift | 36 | `testSCKRecoveryEpochOfficialStopInvalidatesRecoveryBeforeLateStart` | retained behavior/contract coverage |
| AudioTests/AudioStopCleanupTests.swift | 3 | `testBlockedMicrophoneStopDoesNotHoldSystemCaptureOrWriterOpen` | retained behavior/contract coverage |
| AudioTests/AudioTapInstallGuardTests.swift | 4 | `testRunsTheInstallAndDoesNotThrowWhenNothingRaises` | production source read retained |
| AudioTests/BluetoothMeetingRouteContractTests.swift | 6 | `testMeetingBluetoothOutputUsesBuiltInMicFallback` | retained behavior/contract coverage |
| AudioTests/CoreAudioSystemAudioCaptureTests.swift | 62 | `testProductionAggregateDoesNotWaitForTappedPlayback` | retained behavior/contract coverage |
| AudioTests/CoreAudioTapBufferRingTests.swift | 6 | `testOwnsCopiedInterleavedAndPlanarSamples` | retained behavior/contract coverage |
| AudioTests/FailedRecordingSignalProbeTests.swift | 11 | `testProbeReportsAbsentForFullySilentRecording` | retained behavior/contract coverage |
| AudioTests/LiveCaptureSmokeTests.swift | 2 | `testSavedSignalEvidenceDistinguishesToneFromValidSilentWAV` | conditional skip; see limits; async/sleep synchronization screened |
| AudioTests/MeetingInputDeviceSelectionPolicyTests.swift | 23 | `testOverriddenBuiltInRouteRejectsStaleBluetoothSampleRate` | retained behavior/contract coverage |
| AudioTests/MeetingRecordingJournalTests.swift | 20 | `testLifecycleWritesStatesAndClearRemoves` | retained behavior/contract coverage |
| AudioTests/MicOnlyRecordingTests.swift | 29 | `testMicOnlyStartIsReadyOnceTheMicStreams` | production source read retained |
| AudioTests/MicRecordingFileMergerTests.swift | 8 | `testMergePadsRecoveryGapAndResamplesSegments` | retained behavior/contract coverage |
| AudioTests/MicRecoveryFallbackTests.swift | 28 | `testRouteChangeThatStopsTheLiveMicRecoversRightAway` | retained behavior/contract coverage |
| AudioTests/MicStopTailHandoffTests.swift | 3 | `testStopWritesMicBuffersDeliveredBeforeTheTapIsTornDown` | production source read retained |
| AudioTests/MicrophoneSharingTests.swift | 3 | `testZoomGuardOverridesAppleProcessingWithoutChangingPreferenceOrOpeningIdleMic` | retained behavior/contract coverage |
| AudioTests/PCMBufferBackpressureGateTests.swift | 10 | `testMicAndSystemOverflowCanClaimOnlyOneStopPerGeneration` | retained behavior/contract coverage |
| AudioTests/PinnedMicrophoneCaptureTests.swift | 28 | `testDeliversContiguousBuffersWithoutEvents` | retained behavior/contract coverage |
| AudioTests/QuietMicAttenuationDetectorTests.swift | 14 | `testSustainedAttenuationFiresOnceAfterWindow` | retained behavior/contract coverage |
| AudioTests/RealtimeAGCTests.swift | 13 | `testAttenuatedInputRampsUpToTargetPeak` | retained behavior/contract coverage |
| AudioTests/RecordingHealthInfoOverrideTests.swift | 12 | `testHealthInfoUsesLiveStatusWhenOverrideAbsent` | retained behavior/contract coverage |
| AudioTests/RecordingValidatorResolvedSaveDirectoryTests.swift | 6 | `testReturnsPathsTranscriptsWhenNoCustomLocation` | retained behavior/contract coverage |
| AudioTests/SCKAudioCaptureInterleavingTests.swift | 15 | `testOverlappingStartCannotDiscardFirstInFlightStream` | async/sleep synchronization screened |
| AudioTests/SpeechAudioConversionTests.swift | 5 | `testMicrophoneDownmixPreservesSpeechAcrossChannelLayouts` | retained behavior/contract coverage |
| AudioTests/SystemAudioBackendSelectionTests.swift | 1 | `testDefaultFactoryCreatesCoreAudioWithoutAcquiringPermission` | retained behavior/contract coverage |
| AudioTests/SystemAudioEarlyStopHandoffTests.swift | 6 | `testStopThatClaimedTheSystemFileKeepsItFromTheAbandonedSetup` | retained behavior/contract coverage |
| AudioTests/SystemAudioRecoveryParityTests.swift | 30 | `testRecordSystemAudioDeviceSwitchFeedsSameCounterAsMicPath` | async/sleep synchronization screened |
| AudioTests/SystemAudioSilenceWatchTests.swift | 8 | `testNothingHappensWhileNoOtherAppPlays` | retained behavior/contract coverage |
| AudioTests/SystemAudioStopTailHandoffTests.swift | 4 | `testStopCleanupWritesTheDrainedRingTailBeforeClosingTheWriter` | production source read retained |
| AudioTests/TranscriptMetadataBuilderTests.swift | 3 | `testHealthInfoMarksFailedSystemAudioAsDegraded` | retained behavior/contract coverage |
| AudioTests/VoiceProcessingBindResultTests.swift | 3 | `testBindResultEqualityReflectsBothFields` | retained behavior/contract coverage |
| AudioTests/VoiceProcessingDisarmOutcomeTests.swift | 2 | `testEngineRunningLeavesPriorCacheValueUnchanged` | retained behavior/contract coverage |
| AudioTests/VoiceProcessingStartFallbackPolicyTests.swift | 7 | `testRequestedButInactiveSelectsTheFallback` | retained behavior/contract coverage |
| AudioTests/WAVHeaderRepairTests.swift | 5 | `testFinalizedFileNeedsNoRepair` | retained behavior/contract coverage |

### PipelineTests

Real orchestration around injected speech/diarization services; task lifecycle; retry/failure persistence and safe cleanup; imported/recovered audio; metadata/language and rollback. All files route through the `PipelineTests` root-package XCTest bundle.

| File | Cases | Example promise | Audit flags |
| --- | ---: | --- | --- |
| PipelineTests/FailedTranscriptionManagerDeletionTests.swift | 20 | `testDeleteFailedTranscriptionRemovesTinyRetainedAudioAndQueueEntry` | retained behavior/contract coverage |
| PipelineTests/FailedTranscriptionManagerTests.swift | 38 | `testInitRejectsOutOfHomeAudioPathsAndRewritesQueue` | retained behavior/contract coverage |
| PipelineTests/MeetingPipelineTimingsTests.swift | 3 | `testStagesAddUpAndSleepIsWallMinusAwake` | async/sleep synchronization screened |
| PipelineTests/ModelDownloadServiceTests.swift | 17 | `testSafeModelFilenameAllowsNestedModelFiles` | retained behavior/contract coverage |
| PipelineTests/PipelineRollbackRegistryManagerTests.swift | 3 | `testRealDequeueRollbackCancelsQueuedSpeakerNamingRequestAndItsOwnClipCleanup` | retained behavior/contract coverage |
| PipelineTests/PipelineRollbackRegistryTests.swift | 16 | `testCheckCancellationDoesNothingWhenNotCancelled` | retained behavior/contract coverage |
| PipelineTests/SpeechSegmentPackingTests.swift | 7 | `testLayoutPutsSilenceBetweenSegmentsAndRecordsRanges` | retained behavior/contract coverage |
| PipelineTests/TranscriptionAudioFileTests.swift | 4 | `testAudioFilePublicAPIInitializesModelsAndPreservesInput` | retained behavior/contract coverage |
| PipelineTests/TranscriptionLanguageTests.swift | 3 | `testSelectionValidatesKnownCodesAndCodableRoundTrips` | retained behavior/contract coverage |
| PipelineTests/TranscriptionPipelineErrorPolicyTests.swift | 27 | `testSafeFailureDiagnosticMessageRoutesTypedAudioErrors` | retained behavior/contract coverage |
| PipelineTests/TranscriptionPipelineHelpersTests.swift | 46 | `testLanguageSamplingSpansRecordingAndDoesNotRepeatShortEvidence` | retained behavior/contract coverage |
| PipelineTests/TranscriptionPipelineStateTests.swift | 34 | `testEmbeddingWeightTreatsBoundaryFractionsAsLowerTier` | retained behavior/contract coverage |
| PipelineTests/TranscriptionTaskLifecycleStateTests.swift | 6 | `testCancelDuringRunningSuppressesLateResultFromAnUncooperativeEngine` | async/sleep synchronization screened |
| PipelineTests/TranscriptionTaskManagerDiagnosticsTests.swift | 3 | `testPipelineModelReadinessReloadsModelsAfterCleanup` | retained behavior/contract coverage |
| PipelineTests/TranscriptionTaskManagerDiarizationEngineTests.swift | 3 | `testSavedMeetingRecordsNemotronBackendAndVoiceprintModel` | retained behavior/contract coverage |
| PipelineTests/TranscriptionTaskManagerFailedQueueTests.swift | 25 | `testStartTranscriptionAllowsMicOnlyRecovery` | async/sleep synchronization screened |
| PipelineTests/TranscriptionTaskManagerImportedAudioTests.swift | 22 | `testStartImportedTranscriptionDoesNotDeleteOutOfSandboxFileWhenRejected` | retained behavior/contract coverage |
| PipelineTests/TranscriptionTaskManagerLanguageTests.swift | 3 | `testSavedRetranscriptionLanguagePreservesSelectionNotDetectedGuess` | retained behavior/contract coverage |
| PipelineTests/TranscriptionTaskManagerMetadataTests.swift | 18 | `testPopulateSavedMetadataReadsLargeFrontmatterBeyondInitialChunk` | async/sleep synchronization screened |
| PipelineTests/TranscriptionTaskManagerRecoveryTests.swift | 23 | `testRecoversOrphanedRecordingWithCorruptHeader` | async/sleep synchronization screened |
| PipelineTests/TranscriptionTaskManagerRetryTests.swift | 14 | `testRetryRejectsReadableAudioAfterDeletionCleanupFailed` | retained behavior/contract coverage |
| PipelineTests/TranscriptionTaskManagerStopTimeoutTests.swift | 18 | `testStopTimeoutFailedQueueCanKeepScratchAudioUntilItFinalizes` | retained behavior/contract coverage |

### SpeakerTests

Real identity/matching and SQLite state; embedding/windowing/model interface policies; migration, confirmations, provenance and saved transcript rewriting; optional model/corpus checks. All files route through the `SpeakerTests` root-package XCTest bundle.

| File | Cases | Example promise | Audit flags |
| --- | ---: | --- | --- |
| SpeakerTests/BackgroundLoadedSpeakerSegmentEmbedderTests.swift | 6 | `testBuildingTheMeetingStackAroundItLoadsNothing` | retained behavior/contract coverage |
| SpeakerTests/CalendarNamingPolicyTests.swift | 18 | `testWithNoInviteALoneMatchBelowTheStandardBarGoesToReview` | retained behavior/contract coverage |
| SpeakerTests/ClipRemovalPolicyTests.swift | 3 | `testRemovingAMissingClipCountsAsAlreadyGone` | retained behavior/contract coverage |
| SpeakerTests/CoreMLSpeakerSegmentEmbedderTests.swift | 25 | `testShortTurnReachesTheModelTiledToItsMinimum` | conditional skip; see limits |
| SpeakerTests/CoreMLVoiceprintMultiFunctionTests.swift | 16 | `testEveryCallRunsOnTheFunctionBuiltForItsLength` | conditional skip; see limits |
| SpeakerTests/DiarizationBackendTests.swift | 15 | `testBackendRawValuesRoundTrip` | retained behavior/contract coverage |
| SpeakerTests/DiarizationReembedTests.swift | 7 | `testNoEmbedderIsIdentity` | retained behavior/contract coverage |
| SpeakerTests/DiarizationSpeakerIdParsingTests.swift | 5 | `testParsesSortformerUnderscoreForm` | retained behavior/contract coverage |
| SpeakerTests/ERes2NetDiarizationE2ETests.swift | 1 | `testDiarizeReembedsWithERes2Net` | conditional skip; see limits |
| SpeakerTests/ERes2NetEmbedderModelTests.swift | 9 | `testDimensionAndIdentifier` | conditional skip; see limits |
| SpeakerTests/ERes2NetEmbedderParityTests.swift | 1 | `testSwiftEmbedderMatchesGolden` | conditional skip; see limits |
| SpeakerTests/ERes2NetEmbedderUnitTests.swift | 17 | `testWindowBoundsEmpty` | retained behavior/contract coverage |
| SpeakerTests/EmbeddingClustererTests.swift | 16 | `testPairwiseMergeWithNoSegmentsReturnsEmpty` | retained behavior/contract coverage |
| SpeakerTests/FluidAudioCompatibilityTests.swift | 3 | `testCosineToDistanceMatchesTheLegacyConversion` | retained behavior/contract coverage |
| SpeakerTests/NemotronTurnBuilderTests.swift | 20 | `testEmptyAndDegenerateInputProduceNoTurns` | retained behavior/contract coverage |
| SpeakerTests/RetroactiveSpeakerUpdaterTests.swift | 47 | `testRetroactivelyUpdateSpeakerRenamesEscapedQuotes` | retained behavior/contract coverage |
| SpeakerTests/SpeakerAutoAcceptMarginTests.swift | 5 | `testLuckyExemplarImpostorRejectedByAverageMargin` | retained behavior/contract coverage |
| SpeakerTests/SpeakerConfirmationTests.swift | 5 | `testPassiveAppearancesNeverGraduateProfile` | retained behavior/contract coverage |
| SpeakerTests/SpeakerDBDimensionIsolationTests.swift | 7 | `testStoresEachDimensionFaithfully` | retained behavior/contract coverage |
| SpeakerTests/SpeakerEmbeddingMatcherTests.swift | 18 | `testMatchSpeakerReturnsNilOnEmptyDatabase` | retained behavior/contract coverage |
| SpeakerTests/SpeakerEmbeddingThresholdsFileTests.swift | 11 | `testSnakeCaseCalibrationFileLoadsExactlyItsValues` | retained behavior/contract coverage |
| SpeakerTests/SpeakerEmbeddingThresholdsTests.swift | 5 | `testWeSpeakerPresetMatchesProductionValues` | retained behavior/contract coverage |
| SpeakerTests/SpeakerExemplarDeltaEvalTests.swift | 1 | `testExemplarDeltaOnRealQmatrixFingerprints` | conditional skip; see limits |
| SpeakerTests/SpeakerExemplarPolicyTests.swift | 6 | `testSameAsAverageStoresNoExemplar` | retained behavior/contract coverage |
| SpeakerTests/SpeakerIdentityBarsTests.swift | 21 | `testWeSpeakerIdentityBarsAreTheValuesTheStackAlwaysUsed` | retained behavior/contract coverage |
| SpeakerTests/SpeakerIdentityMutationServiceTests.swift | 15 | `testRenameHappyPathUpdatesDatabaseAndTranscript` | retained behavior/contract coverage |
| SpeakerTests/SpeakerMatchOutcomeTests.swift | 6 | `testRecordAndReadRecentOutcomesNewestFirst` | retained behavior/contract coverage |
| SpeakerTests/SpeakerMatchingServiceTests.swift | 5 | `testMatchAgainstProfilesAcceptsMatureHighConfidenceProfile` | retained behavior/contract coverage |
| SpeakerTests/SpeakerMultiExemplarMatchingTests.swift | 6 | `testLegacyProfileWithoutExemplarsMatchesUnchanged` | retained behavior/contract coverage |
| SpeakerTests/SpeakerNameRewriteEdgeCaseTests.swift | 10 | `testBracketLabelWithWhitespaceOnlyUtteranceRenamesEveryRow` | retained behavior/contract coverage |
| SpeakerTests/SpeakerNameSaveReliabilityTests.swift | 27 | `testRelabelingRecognizedPersonToAnotherSavedPersonKeepsBothPeople` | async/sleep synchronization screened |
| SpeakerTests/SpeakerNamingCoordinatorTests.swift | 38 | `testRepeatedSourceProfileMergeSavesEveryRow` | async/sleep synchronization screened |
| SpeakerTests/SpeakerNamingSimulationRunnerTests.swift | 7 | `testDeepSpeakerNamingSimulationSuitePassesWithFullReport` | retained behavior/contract coverage |
| SpeakerTests/SpeakerNegativeExemplarPolicyTests.swift | 12 | `testVetoesWhenNegativeIsCloseAndCompetitive` | retained behavior/contract coverage |
| SpeakerTests/SpeakerNegativeExemplarTests.swift | 8 | `testRecordAndReadNegativeExemplars` | retained behavior/contract coverage |
| SpeakerTests/SpeakerProfileMergerTests.swift | 15 | `testMergeDuplicatesSkipsDisputedProfiles` | retained behavior/contract coverage |
| SpeakerTests/SpeakerProfileProvenanceTests.swift | 14 | `testProfileSnapshotRoundTripsAllFields` | retained behavior/contract coverage |
| SpeakerTests/SpeakerProvenanceTests.swift | 9 | `testUnmergeRestoresTwoDistinctProfiles` | retained behavior/contract coverage |
| SpeakerTests/SpeakerRecognizedReviewPolicyTests.swift | 7 | `testAReviewIsQueuedWhenEveryoneWasRecognizedAndTheIslandListsThem` | retained behavior/contract coverage |
| SpeakerTests/SpeakerSeparationTests.swift | 21 | `testWithNothingTurnedOnSegmentsComeBackUnchanged` | retained behavior/contract coverage |
| SpeakerTests/SpeakerVoiceprintMigrationGateTests.swift | 8 | `testTranscriptionAskedForMidMoveWaitsThenRunsAgainstTheMovedPeople` | retained behavior/contract coverage |
| SpeakerTests/SpeakerVoiceprintMigrationTests.swift | 16 | `testNamedPeopleCarryOverWithTheirIdsNamesCountsAndConfirmations` | conditional skip; see limits |
| SpeakerTests/SpeakerWriteBackGateTests.swift | 3 | `testFrozenAlphaLeavesVoiceprintUnchangedButRecordsAppearance` | retained behavior/contract coverage |
| SpeakerTests/SpeakerWritePathPolicyTests.swift | 15 | `testConfidentWellSeparatedMatchAdaptsAtFullRate` | retained behavior/contract coverage |
| SpeakerTests/Support/SpeakerNamingSimulationRunner.swift | 0 | `No test case; helper only` | shared fixture/helper |
| SpeakerTests/Support/TranscriptSaverTestHelpers.swift | 0 | `No test case; helper only` | shared fixture/helper |

### StorageTests

Paths/validation/permission safety; persisted SQLite/query rollback; saved audio/archive behavior; Markdown/frontmatter/exported protocol and identity preservation. All files route through the `StorageTests` root-package XCTest bundle.

| File | Cases | Example promise | Audit flags |
| --- | ---: | --- | --- |
| StorageTests/CoreStoragePathsTests.swift | 11 | `testDefaultLayoutIsSelfConsistent` | retained behavior/contract coverage |
| StorageTests/DatabaseFilePermissionsTests.swift | 2 | `testStatsDatabaseRestrictsSQLiteArtifactsToOwnerOnly` | retained behavior/contract coverage |
| StorageTests/FrontmatterCorpusParityTests.swift | 3 | `testCorpusIsNonEmpty` | retained behavior/contract coverage |
| StorageTests/MeetingMarkdownGoldenTests.swift | 3 | `testTwoPersonCallMatchesApprovedMarkdown` | retained behavior/contract coverage |
| StorageTests/MeetingRouteArtifactFixtureTests.swift | 2 | `testTranscriptSaverAndAudioArchiverProduceSyntheticRouteArtifacts` | retained behavior/contract coverage |
| StorageTests/RecordingAudioArchiverTests.swift | 7 | `testArchiveCopiesLiveMeetingMicAndSystemAudio` | retained behavior/contract coverage |
| StorageTests/RecordingMetadataFactoryTests.swift | 2 | `testFromAggregatesWordAndSpeakerCountsAcrossChannels` | retained behavior/contract coverage |
| StorageTests/StatsDatabaseModelsTests.swift | 6 | `testRecordingMetadataDefaultIdIsAValidUUIDString` | retained behavior/contract coverage |
| StorageTests/StatsDatabaseQueriesTests.swift | 7 | `testGetRecordingsFiltersByDateRangeInclusive` | retained behavior/contract coverage |
| StorageTests/StatsDatabaseTests.swift | 7 | `testGetRecentRecordingsHonorsLimitAndSortOrder` | retained behavior/contract coverage |
| StorageTests/TranscriptFileRewriteTests.swift | 4 | `testIdenticalContentSkipsWriteAndKeepsBothDates` | retained behavior/contract coverage |
| StorageTests/TranscriptFormatVersionTests.swift | 2 | `testMeetingSaveEmitsFlatFormatVersionAndRawStyle` | retained behavior/contract coverage |
| StorageTests/TranscriptFormatterAudioHealthTests.swift | 8 | `testSystemSignalVerificationMetadataIsIndependentOfQualityAndSurvivesCopies` | retained behavior/contract coverage |
| StorageTests/TranscriptFormatterCaptureKitContractTests.swift | 4 | `testFlatFrontmatterTokensSurviveRoundTrip` | retained behavior/contract coverage |
| StorageTests/TranscriptFrontmatterTests.swift | 8 | `testParsesFlatValuesAndBody` | retained behavior/contract coverage |
| StorageTests/TranscriptSaverDefaultSaveDirectoryTests.swift | 7 | `testReturnsDefaultTranscriptsWhenNoCustomPathSet` | retained behavior/contract coverage |
| StorageTests/TranscriptSaverRecoveryIdentityTests.swift | 1 | `testFindsStableTranscriptIdentityWithoutFollowingSymlinks` | retained behavior/contract coverage |

### UtilitiesTests

Dates; real logger files/privacy/permissions; lab knobs; public API visibility; supersession/generation ownership primitives. All files route through the `UtilitiesTests` root-package XCTest bundle.

| File | Cases | Example promise | Audit flags |
| --- | ---: | --- | --- |
| UtilitiesTests/DateFormattingHelperTests.swift | 6 | `testFormatDayStampProducesYYYYMMDD` | retained behavior/contract coverage |
| UtilitiesTests/FileLoggerTests.swift | 8 | `testMultipleLoggersAppendWithoutOverwritingEarlierEntries` | retained behavior/contract coverage |
| UtilitiesTests/LabKnobOverridesTests.swift | 12 | `testNoEnvironmentVariableReturnsDefaults` | conditional skip; see limits |
| UtilitiesTests/LogPrivacySanitizerTests.swift | 19 | `testSanitizeTextReturnsEmptyForEmptyInput` | retained behavior/contract coverage |
| UtilitiesTests/LogTailTrimmerTests.swift | 6 | `testMaxLinesGateSkipsTrimBelowThreshold` | retained behavior/contract coverage |
| UtilitiesTests/PublicTranscriptedCoreAPITests.swift | 1 | `testPublicCoreStoragePathsAndRecordingValidatorAreImportable` | retained behavior/contract coverage |
| UtilitiesTests/SupersessionEpochTests.swift | 30 | `testBeginStartsAtGenerationOneFromZeroInitialState` | retained behavior/contract coverage |

COORD_DONE: BRIEF | PR owned by parent | one deterministic system-audio cancellation test edited; complete Core inventory/audit | no GitHub cleanup action | parent runs negative/focused/full/exact-head proof | static audit and diff review only; no test run | lanes used: Codex=core_audit; Claude=n/a; Local=static inspection; Windows=n/a | verify changed cancellation test and integrate report
