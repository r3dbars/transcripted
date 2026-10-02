# Writing test-quality audit

Baseline: `r3dbars/transcripted` main `85bbcc09380f6de16e73119efb672e5e6a628f72`. Read-only discovery followed by one authorized test-only batch. No heavy proof, live audio, screen capture, private recordings, app launch, package installation, or repository settings changes were run by this lane.

Method: [OpenClaw test-audit](https://github.com/openclaw/openclaw/blob/main/.agents/skills/test-audit/SKILL.md), adapted to Swift Testing and this repository. Root `AGENTS.md`, `Tests/README.md`, `.agents/test-matrix.yml`, package targets, CI routing, candidate owners/callers, sibling coverage, and git history were inspected. No scoped CLAUDE.md exists under Writing, TranscriptedWriting, or TranscriptedKeyboard on this baseline. Every Writing test file was inventoried and its test declarations and cross-cutting patterns scanned. Deep owner review concentrated on the selected lookup race and the flagged streaming/cancellation families; this is not a claim that every assertion in 20,250 lines received a line-by-line correctness review.

## Complete surface and routing

The baseline contains **95 Swift files, 20,250 lines, and 944 `@Test` declarations**: Core 49 files / 9,202 lines / 509 declarations; Runtime 46 files / 11,048 lines / 435 declarations. `PreparedCompletionContextGoldens.swift` is fixture-only; the other 94 files contain tests. Parameterized tests expand beyond the declaration count. No `.disabled` or `XCTSkip` directive was found in this subtree.

`Package.swift` routes all these files to the single `TranscriptedWritingTests` target, depending on `TranscriptedWritingCore`, `TranscriptedWritingRuntime`, and `TranscriptedKeyboard`. Writing Core has 50 Swift source files, Runtime 42, Keyboard 8. Tests use Swift Testing (`import Testing`), not XCTest. Full `swift test` runs this target alongside five Core test targets. `run-tests.sh` discovers only root `Tests/*Tests.swift`; it does not run this subtree. `.github/workflows/swift-ci.yml:271` routes package tests through `scripts/dev/swift-test-stall-watch.sh swift test`, with `TRANSCRIPTED_DISABLE_FILE_LOGGER=1` in CI's environment.

Focused family loop:

```sh
TRANSCRIPTED_DISABLE_FILE_LOGGER=1 swift test --filter 'GhostBrainServerHostPersonalLookupTimingTests|GhostBrainServerHostStreamingGateTests|PersonalStreamGatePolicyTests'
TRANSCRIPTED_DISABLE_FILE_LOGGER=1 swift test --filter '^TranscriptedWritingTests\.'
```

A change under this subtree maps to the union: `bash build-deps.sh --force`, `bash build.sh --no-open`, `bash run-tests.sh`, `bash run-integration-smoke.sh`, `swift test`; `bash check.sh` and independent whole-diff review apply before handoff. Parent coordinates these proofs after all edits are complete.

## Prioritized findings and chosen batch

### P1 — Replace a documented scheduler-sensitive personal lookup test

Exact baseline test: `GhostBrainServerHostPersonalLookupTimingTests.slowTaskReportsTimeout`, `Tests/TranscriptedWritingTests/Runtime/GhostBrainServerHostPersonalGuardTests.swift:184-207`.

Actual detection: it expects the personal lookup to return nil with diagnostic outcome `timeout` while a provider remains slow. It also rejects elapsed time >=2.5 seconds, which measures executor availability and machine load in addition to the product promise. Its provider uses a cancellation-sensitive five-second `Task.sleep`; cancellation cleanup lets that fake resolve afterward.

Owner: `GhostBrainServerHost.awaitPersonalPrediction` at `Sources/TranscriptedWriting/Runtime/GhostBrainServerHost.swift:622-654`, delegating to `PersonalLookupRace` at `:672-720`. Non-test terminal caller is `acceptOne` at `:467`. The streaming observer independently waits on the same race at `:437-446`; its 30-second ceiling and the terminal 250ms budget are distinct. `WritingController.makeServerHost` at `Sources/Writing/WritingController.swift:854-878` wires the live controller provider.

History: port introduced in `2b90c6c8`; `8ddb8082` (#1878) widened provider 2s->5s and guard 1.5s->2.5s after a loaded CI runner measured 1.64s. Read-only CI lane additionally reports three historical failures, including run 36287238036 with retry recovery at the same SHA. That evidence belongs to the CI audit, not a new execution claim from this lane.

Implemented replacement: `unresolvedLookupReportsTimeout` leaves the **real** race unresolved, awaits the real host wrapper, and asserts nil plus exactly one `personal-lookup-timing` event and the literal payload `waitedMilliseconds=0, outcome=timeout` using a constant injected diagnostic clock. Nothing can return merely because the fake happened to finish. It removes the five-second provider, elapsed bound, and cancellation-sensitive fake cleanup. The real deadline still runs; this is not proof of a particular elapsed duration. A broken deadline may trip the repository stall watchdog, which is preferable to disguising waiting as successful behavior.

Authoring gate: promise is provider-independent timeout completion and correct diagnostic outcome; credible regression is waiting solely for the provider, misclassifying timeout as resolved, or double-emitting timing; no remaining test covers the unanswered lookup; existing production wrapper and race suffice, with no new seam. No production deletion is unlocked or needed. Risk low: test-only, same output contract, no removed security or safety guard.

### P1 — Fill distinct shared-race contracts at the real owner

No direct race coverage beyond nil/fast/nil/timeout appeared anywhere in `Tests/` on the baseline.

Added `timeoutDoesNotDiscardTheProviderAnswer`: an unresolved race times out a zero-deadline waiter, the provider then resolves a literal prediction, and a later zero-deadline waiter must still obtain that prediction. Observable contract: one waiter's deadline cannot poison the shared provider result needed by another consumer. Credible mutation: record `.timedOut` globally rather than remove one ticket. Existing terminal timeout classification does not detect this; the streaming gate tests supply the answer directly rather than exercising the shared race. No production seam or source edit.

Added `firstProviderAnswerWins(firstHasValue:)` with `[true, false]`: resolve a literal prediction or nil first, then resolve a different prediction; the result must equal the first input. Observable contract: one provider answer remains authoritative, including successful absence. Credible mutation: overwrite `result` on a repeated resolve. Existing `resolvedNilIsStillResolved` does not attempt replacement, so it cannot guard this risk. No production seam or source edit.

The chosen file now has two additional `@Test` declarations, with the first-answer test providing two parameterized cases. Parent owns mutation proof and final compile/run. Focused command shown above.

### P2 — Stream-cut expected output partly derives from its production oracle

Exact candidate: `LlamaCompletionStreamCutTests.cutMatchesFullStream`, `Runtime/LlamaCompletionStreamCutTests.swift:49-96`. Its expected reference calls `RawContinuationPrompt.normalizedContinuation`, `CompletionOutputCleaner.cleanWithReason`, and `FactualGroundingPolicy.containsUnsupportedFact`, the same final-pass collaborators called by `LlamaCompletionEngine`. It protects stream-cut equivalence and cancellation, but a shared display/grounding bug can make both actual and reference agree. It also reconstructs production final-pass call shape in the test.

Non-test caller is `LlamaCompletionEngine`'s request path through `GhostBrainServerHost`; the stream helper is not a test-only path. Sibling `streamIsCutPastTheCap` already pins literal visible output `sounds really good`, cancellation, and four frame reads; `PreparedContextStreamingTests` pins independently recorded partial/final sequences, unsupported facts, and scene echo at the engine boundary. Cleaner and grounding policies retain independent tests. History: file arrived in port `2b90c6c8`.

Recommended coherent follow-up: keep the equivalence and cancellation contract, extend its existing table with literal expected visible outputs, including unsupported-fact nil where appropriate, and stop deriving expectations through production final-pass helpers. Demonstrate a mutation to a cap/grounding decision causes the table to fail. Do not delete the stream-cut tests. Risk low-to-medium because literal expectations need independently reviewed product profile semantics. Focused: `swift test --filter 'LlamaCompletionStreamCutTests|PreparedContextStreamingTests|ProfileDisplayFilterTests'`. No source seam deletion required. Unchanged in this batch.

### P2 — Bounded polling is not reliable admission synchronization

Exact candidates: `LlamaCompletionStreamingTests.cancellationReachesTransport` / `cancellationReachesURLSessionTask`, polling helpers at `Runtime/LlamaCompletionStreamingTests.swift:286-326`; `PersonalHistoryCaptureTests` helper at `:232-239`; `PersonalHistoryControllerTests` helpers at `:293-300` and `:1115-1123`; similar helpers in `PersonalHistorySecretTests`. Polls sleep 1ms for bounded counts and silently return even when the expected state never arrived. Some callers subsequently assert the state, but precondition failure can make cancellation run before the intended path is active.

The completion tests remain valuable: one uses an engine transport probe and another exercises the real URLSession transport through URLProtocol. They cover different layers; they are not duplicates. Fakes record opened/cancelled callbacks instead of implementing engine cancellation, so they are not tautological. The URLSession operation's transport contract and real helper behavior remain separately meaningful. Prefer held continuations/event handshakes in fake admission points, with cleanup, to widening poll counts. Do not introduce a production-only test seam. Caller/owner review and baseline failure reproduction are incomplete for a deletion candidate; retained unchanged. Focused: `swift test --filter 'LlamaCompletionStreamingTests|PersonalHistoryCaptureTests|PersonalHistoryControllerTests|PersonalHistorySecretTests'`.

### P2 — Cancellation-before-registration gap requires a separate product investigation

`PersonalLookupRace.value` installs the waiter inside a cancellation handler; `onCancel` only removes an already-installed ticket. Unlike the nearby `URLSessionStreamOperation`, it does not preserve cancellation as a result before continuation registration. A task already cancelled on entry, or cancelled just before registration, may therefore miss cancellation and wait for its deadline. This is a code-reading hypothesis, not a proven production defect: no runtime or baseline mutation proof was run here. Do not add a failing test and repair unrelated production code in this test-only batch. A separate owner investigation should use a self-cancelled caller, bounded independent cleanup, and explicit outcome ordering. Existing `LlamaStreamResponseRaceTests` protects the distinct response-header lost-resume bug and stays intact.

## Retained false positives and limits

- `KeyboardIdentityTests` reads `Sources/TranscriptedKeyboard/Info.plist` as a parsed property list. It checks executable, identity, and IMKit connection bytes against the shipped profile, protecting four-way packaging identity. This is an artifact/config contract, not a Swift source-text assertion, and survives implementation refactoring. Keep.
- `RawContinuationPromptTests`, prepared goldens, configuration identities, legacy wire decode/unsupported event IDs, and prompt hint tests retain byte/protocol contracts. A matching production constant alone is not adequate replacement proof.
- Secret rules, three scrubber/corpus families, terminal-prompt carryover, split card/OTP, deletion/consent rotation, encrypted checkpoint/trained-model envelopes, wrong keys, corrupt/torn writes, symlinks/FIFOs, write permissions, redirected directories, and local redaction diagnostics protect different privacy and persistence boundaries. Overlap across pure scrubber, composer, history controller, and actual saved day file is justified by separate streaming/admission/storage risks. Do not consolidate them solely by matching secret examples.
- `RuntimeBoundaryTests.redirectsAreRejected`, `LlamaServerAccessKeyTests`, `ModelManagerTests`, `LlamaOrphanReapTests`, cache PID-reuse coverage, and child shutdown tests retain platform/security safeguards. Header/auth tests inspect the real generated request; process launch-key proof runs a stand-in child and proves no key in argv. Static or slow is not a deletion reason.
- ScreenMemory's pure gate policies and actor wiring are distinct. Direct snapshots test serving/cache invalidation; fakes do not prove real ScreenCaptureKit/OCR/AX. The actual macOS permission/secure-input/focused-window boundary, signed peer authorization, live IMKit response/marked-text behavior, real model quality, real screen capture, and fresh-install UI still need authorized platform/integration proof. No such proof was run by this lane.
- No Swift-source text-read assertion, disabled test, obvious test-only wrapper ready for removal, or high-confidence duplicate deletion was found in this subtree's pattern sweep. This does not prove their absence outside Writing or prove every mock/assertion meaningful.
- `GhostStatsTests` uses `UserDefaults.standard` and restores its own daily key; `GhostStats` has a global queue/state and the suite is serialized. Standard defaults normally use the test executable domain, but this lane did not validate that domain on this machine. Harness isolation should be confirmed before claiming no preference writes; no tests were executed here.
- This lane changed only `GhostBrainServerHostPersonalGuardTests.swift`, and wrote this report outside the repository. Parent owns test-shape baseline shrink, deliberate mutation proof, full clean-tree checks, independent diff review, draft PR, and terminal exact-head CI.

## Inventory

All paths below are relative to `Tests/TranscriptedWritingTests/`. Owner paths are relative to `Sources/` when matched; a family may touch additional collaborators. Counts are immutable baseline declarations and lines, not final counts or expanded test cases.

| Test/fixture file | @Test | Lines | Primary owner(s) |
| --- | ---: | ---: | --- |
| `Core/CompletionCleanSettlementTests.swift` | 10 | 96 | `TranscriptedWriting/Core/Engine/CompletionOutputCleaner.swift` |
| `Core/CompletionOutputCleanerTests.swift` | 16 | 282 | `TranscriptedWriting/Core/Engine/CompletionOutputCleaner.swift` |
| `Core/CompletionSuggestionTests.swift` | 4 | 68 | `TranscriptedWriting/Core/Suggestions/CompletionSuggestion.swift` |
| `Core/DiagnosticsMetadataRedactorTests.swift` | 13 | 180 | `TranscriptedWriting/Core/Text/DiagnosticsMetadataRedactor.swift` |
| `Core/FactualGroundingPolicyTests.swift` | 7 | 120 | `TranscriptedWriting/Core/Suggestions/FactualGroundingPolicy.swift` |
| `Core/GhostBrainWireTests.swift` | 7 | 127 | `TranscriptedWriting/Core/Engine/GhostBrainWire.swift` |
| `Core/InlineGhostFontPolicyTests.swift` | 6 | 83 | `TranscriptedWriting/Core/Geometry/InlineGhostFontPolicy.swift` |
| `Core/InlineGhostLegibilityPolicyTests.swift` | 1 | 24 | `TranscriptedWriting/Core/Geometry/InlineGhostLegibility.swift` |
| `Core/InlineSuggestionStateTests.swift` | 19 | 455 | `TranscriptedWriting/Core/Suggestions/InlineSuggestionState.swift` |
| `Core/IntentFutureFusionTests.swift` | 2 | 31 | `TranscriptedWriting/Core/Scene/IntentFutureFusion.swift` |
| `Core/IntentFuturesTests.swift` | 8 | 93 | `TranscriptedWriting/Core/Scene/IntentFutures.swift` |
| `Core/IntentPromptHintTests.swift` | 2 | 24 | `TranscriptedWriting/Core/Engine/IntentPromptHint.swift` |
| `Core/KeyboardIdentityTests.swift` | 2 | 45 | `TranscriptedWriting/Core/Runtime/TildeProductProfile.swift`, `TranscriptedKeyboard/Info.plist` |
| `Core/OpportunityCharacterMeterTests.swift` | 4 | 47 | `TranscriptedWriting/Core/Policy/OpportunityCharacterMeter.swift` |
| `Core/PersonalHistoryEventTests.swift` | 5 | 198 | `TranscriptedWriting/Core/PersonalHistory/PersonalHistoryEvent.swift` |
| `Core/PersonalStreamGatePolicyTests.swift` | 6 | 108 | `TranscriptedWriting/Core/PersonalHistory/PersonalSuggestionPolicy.swift` |
| `Core/PersonalSuggestionPolicyTests.swift` | 7 | 76 | `TranscriptedWriting/Core/PersonalHistory/PersonalSuggestionPolicy.swift` |
| `Core/PersonalTrainedModelTests.swift` | 8 | 215 | `TranscriptedWriting/Core/PersonalHistory/PersonalVocabularyShadow.swift` |
| `Core/PersonalVocabularyShadowTests.swift` | 35 | 884 | `TranscriptedWriting/Core/PersonalHistory/PersonalVocabularyShadow.swift` |
| `Core/PreparedCompletionContextGoldens.swift` | 0 | 368 | `fixture for PreparedCompletionContextTests.swift` |
| `Core/PreparedCompletionContextTests.swift` | 6 | 161 | `TranscriptedWriting/Core/Engine/PreparedCompletionContext.swift` |
| `Core/ProcessPeerIdentityCacheTests.swift` | 6 | 107 | `TranscriptedWriting/Core/Runtime/ProcessPeerIdentityCache.swift` |
| `Core/RawContinuationPromptTests.swift` | 42 | 659 | `TranscriptedWriting/Core/Engine/RawContinuationPrompt.swift` |
| `Core/RetainedCharacterObservationTests.swift` | 2 | 48 | `TranscriptedWriting/Core/Policy/RetainedCharacterObservation.swift` |
| `Core/RetainedSpanWatchTests.swift` | 9 | 262 | `TranscriptedWriting/Core/Policy/RetainedCharacterObservation.swift` |
| `Core/SceneEchoPolicyTests.swift` | 5 | 71 | `TranscriptedWriting/Core/Suggestions/SceneEchoPolicy.swift` |
| `Core/SceneSuggestionPolicyTests.swift` | 12 | 262 | `TranscriptedWriting/Core/Scene/SceneSuggestionPolicy.swift` |
| `Core/ScreenMemory/CaptureChangeDetectorTests.swift` | 18 | 304 | `TranscriptedWriting/Core/ScreenMemory/CaptureChangeDetector.swift` |
| `Core/ScreenMemory/CaptureTriggerPolicyTests.swift` | 21 | 225 | `TranscriptedWriting/Core/ScreenMemory/CaptureTriggerPolicy.swift` |
| `Core/ScreenMemory/ContextResetDetectorTests.swift` | 3 | 25 | `TranscriptedWriting/Core/ScreenMemory/ContextResetDetector.swift` |
| `Core/ScreenMemory/DefaultExcludedAppsTests.swift` | 8 | 76 | `TranscriptedWriting/Core/ScreenMemory/DefaultExcludedApps.swift` |
| `Core/ScreenMemory/FocusedWindowCapturePolicyTests.swift` | 12 | 192 | `TranscriptedWriting/Core/ScreenMemory/FocusedWindowCapturePolicy.swift` |
| `Core/ScreenMemory/ScreenMemoryStatusTests.swift` | 10 | 95 | `TranscriptedWriting/Core/ScreenMemory/ScreenMemoryStatus.swift` |
| `Core/ScreenSceneSnapshotBridgeTests.swift` | 12 | 236 | `TranscriptedWriting/Core/Scene/ScreenSceneSnapshotBridge.swift` |
| `Core/ScreenSceneTests.swift` | 43 | 665 | `TranscriptedWriting/Core/Scene/ScreenScene.swift` |
| `Core/SecretRulesTests.swift` | 16 | 235 | `TranscriptedWriting/Core/Text/SecretRules.swift` |
| `Core/SensitiveScenePolicyTests.swift` | 21 | 240 | `TranscriptedWriting/Core/Scene/SensitiveScenePolicy.swift` |
| `Core/StableStreamPrefixTests.swift` | 3 | 28 | `TranscriptedWriting/Core/Suggestions/StableStreamPrefix.swift` |
| `Core/SuggestionActivationPolicyTests.swift` | 6 | 96 | `TranscriptedWriting/Core/Policy/SuggestionActivationPolicy.swift` |
| `Core/SuggestionArbiterTests.swift` | 4 | 44 | `TranscriptedWriting/Core/PersonalHistory/SuggestionArbiter.swift` |
| `Core/SuggestionCandidateSetTests.swift` | 3 | 34 | `TranscriptedWriting/Core/PersonalHistory/SuggestionCandidateSet.swift` |
| `Core/SuggestionDecisionReasonTests.swift` | 4 | 118 | `TranscriptedWriting/Core/Policy/SuggestionDecisionReason.swift` |
| `Core/SuggestionRevealDelayPolicyTests.swift` | 5 | 72 | `TranscriptedWriting/Core/Policy/SuggestionRevealDelayPolicy.swift` |
| `Core/TextFreeCandidateSourceTests.swift` | 6 | 125 | `TranscriptedWriting/Core/Policy/TextFreeOnlineEvent.swift` |
| `Core/TildeConfigurationTests.swift` | 6 | 141 | `TranscriptedWriting/Core/Runtime/TildeConfiguration.swift` |
| `Core/TildeProductProfileTests.swift` | 5 | 74 | `TranscriptedWriting/Core/Runtime/TildeProductProfile.swift` |
| `Core/WritingSecretCorpusTests.swift` | 3 | 76 | `TranscriptedWriting/Core/Text/WritingSecretScrubber.swift` |
| `Core/WritingSecretScrubberRegressionTests.swift` | 6 | 157 | `TranscriptedWriting/Core/Text/WritingSecretScrubber.swift` |
| `Core/WritingSecretScrubberTests.swift` | 50 | 850 | `TranscriptedWriting/Core/Text/WritingSecretScrubber.swift` |
| `Runtime/DiagnosticsLogRollTests.swift` | 2 | 68 | `TranscriptedWriting/Runtime/DiagnosticsLog.swift` |
| `Runtime/DiagnosticsLogTestIsolationTests.swift` | 2 | 21 | `TranscriptedWriting/Runtime/DiagnosticsLog.swift` |
| `Runtime/GhostBrainServerHostPersonalGuardTests.swift` | 16 | 233 | `TranscriptedWriting/Runtime/GhostBrainServerHost.swift` |
| `Runtime/GhostBrainServerHostStreamingGateTests.swift` | 9 | 231 | `TranscriptedWriting/Runtime/GhostBrainServerHost.swift`, `TranscriptedWriting/Core/PersonalHistory/PersonalSuggestionPolicy.swift` |
| `Runtime/GhostInputControllerTests.swift` | 11 | 197 | `TranscriptedKeyboard/GhostInputController.swift` |
| `Runtime/GhostKeyboardInstallerHostTests.swift` | 8 | 197 | `TranscriptedWriting/Runtime/KeyboardInstaller.swift` |
| `Runtime/GhostStatsTests.swift` | 3 | 82 | `TranscriptedKeyboard/GhostStats.swift` |
| `Runtime/IntentFuturesPromptIntegrationTests.swift` | 3 | 57 | `TranscriptedWriting/Runtime/LlamaCompletionEngine.swift`, `TranscriptedWriting/Core/Engine/IntentPromptHint.swift` |
| `Runtime/LlamaCompletionStreamCutTests.swift` | 4 | 175 | `TranscriptedWriting/Runtime/LlamaCompletionEngine.swift` |
| `Runtime/LlamaCompletionStreamingTests.swift` | 8 | 356 | `TranscriptedWriting/Runtime/LlamaCompletionEngine.swift`, `TranscriptedWriting/Runtime/LlamaCompletionStreamTransport.swift` |
| `Runtime/LlamaOrphanReapTests.swift` | 5 | 58 | `TranscriptedWriting/Runtime/LlamaServerProcessHost.swift` |
| `Runtime/LlamaRestartPolicyTests.swift` | 7 | 125 | `TranscriptedWriting/Runtime/LlamaRestartPolicy.swift` |
| `Runtime/LlamaServerAccessKeyTests.swift` | 6 | 173 | `TranscriptedWriting/Runtime/LlamaServerAccessKey.swift` |
| `Runtime/LlamaStreamResponseRaceTests.swift` | 4 | 135 | `TranscriptedWriting/Runtime/LlamaCompletionStreamTransport.swift` |
| `Runtime/ModelManagerTests.swift` | 22 | 541 | `TranscriptedWriting/Runtime/ModelManager.swift` |
| `Runtime/OutcomeLedgerSummaryTests.swift` | 17 | 568 | `TranscriptedWriting/Runtime/Stats/OutcomeLedgerSummary.swift` |
| `Runtime/PersonalHistoryCaptureTests.swift` | 7 | 240 | `TranscriptedKeyboard/PersonalHistoryCapture.swift` |
| `Runtime/PersonalHistoryControllerTests.swift` | 33 | 1125 | `TranscriptedWriting/Runtime/PersonalHistory/PersonalHistoryController.swift` |
| `Runtime/PersonalHistoryDeletionTests.swift` | 10 | 334 | `TranscriptedWriting/Core/PersonalHistory/PersonalHistoryDeletion.swift` |
| `Runtime/PersonalHistoryRetryTests.swift` | 5 | 197 | `TranscriptedKeyboard/PersonalHistoryCapture.swift`, `TranscriptedWriting/Core/Engine/GhostBrainWire.swift` |
| `Runtime/PersonalHistorySecretTests.swift` | 14 | 557 | `TranscriptedWriting/Runtime/PersonalHistory/PersonalHistoryController.swift`, `TranscriptedWriting/Runtime/SaveMyWriting/WritingEntryComposer.swift`, `TranscriptedWriting/Runtime/SaveMyWriting/WritingDayFileStore.swift` |
| `Runtime/PersonalHistoryStoreTests.swift` | 21 | 605 | `TranscriptedWriting/Runtime/PersonalHistory/PersonalHistoryStore.swift` |
| `Runtime/PersonalTrainedModelStoreTests.swift` | 8 | 295 | `TranscriptedWriting/Runtime/PersonalHistory/PersonalHistoryStore.swift`, `TranscriptedWriting/Core/PersonalHistory/PersonalVocabularyShadow.swift` |
| `Runtime/PreparedContextStreamingTests.swift` | 4 | 149 | `TranscriptedWriting/Runtime/LlamaCompletionEngine.swift`, `TranscriptedWriting/Core/Engine/PreparedCompletionContext.swift` |
| `Runtime/ProfileDisplayFilterTests.swift` | 6 | 142 | `TranscriptedWriting/Runtime/LlamaCompletionEngine.swift`, `TranscriptedWriting/Core/Runtime/TildeProductProfile.swift` |
| `Runtime/ProfileSceneOptionsTests.swift` | 4 | 37 | `TranscriptedWriting/Core/Runtime/TildeProductProfile.swift` |
| `Runtime/RuntimeBoundaryTests.swift` | 7 | 116 | `TranscriptedWriting/Runtime/LlamaServerProcessHost.swift`, `TranscriptedWriting/Runtime/LocalhostURLSession.swift` |
| `Runtime/ScaffoldPrewarmerTests.swift` | 6 | 162 | `TranscriptedWriting/Runtime/ScaffoldPrewarmer.swift` |
| `Runtime/ScreenMemory/ScreenCaptureServiceTests.swift` | 24 | 756 | `TranscriptedWriting/Runtime/ScreenMemory/ScreenCaptureService.swift` |
| `Runtime/ScreenMemory/ScreenTextRecognizerTests.swift` | 2 | 42 | `TranscriptedWriting/Runtime/ScreenMemory/ScreenTextRecognizer.swift` |
| `Runtime/ScreenMemory/WindowAttributionTests.swift` | 4 | 55 | `TranscriptedWriting/Runtime/ScreenMemory/WindowAttribution.swift` |
| `Runtime/SecureLocalStorageTests.swift` | 13 | 240 | `TranscriptedWriting/Runtime/PersonalHistory/SecureLocalStorage.swift` |
| `Runtime/TildeLocalOutcomeStoresTests.swift` | 2 | 33 | `TranscriptedWriting/Runtime/Stats/WritingLocalOutcomeStores.swift` |
| `Runtime/TildeProgressTests.swift` | 5 | 125 | `TranscriptedWriting/Runtime/Stats/WritingProgress.swift` |
| `Runtime/TildeSettingsTests.swift` | 10 | 146 | `TranscriptedWriting/Runtime/TildeSettings.swift` |
| `Runtime/TildeStatsTests.swift` | 5 | 57 | `TranscriptedWriting/Runtime/Stats/WritingStats.swift` |
| `Runtime/WritingAppScopeTests.swift` | 9 | 245 | `TranscriptedWriting/Core/PersonalHistory/WritingAppScope.swift` |
| `Runtime/WritingDayFileFormatterTests.swift` | 6 | 131 | `TranscriptedWriting/Runtime/SaveMyWriting/WritingDayFileFormatter.swift` |
| `Runtime/WritingDayFileRescrubberTests.swift` | 18 | 419 | `TranscriptedWriting/Runtime/SaveMyWriting/WritingDayFileRescrubber.swift` |
| `Runtime/WritingDayFileStoreTests.swift` | 9 | 358 | `TranscriptedWriting/Runtime/SaveMyWriting/WritingDayFileStore.swift` |
| `Runtime/WritingEntryComposerTests.swift` | 38 | 622 | `TranscriptedWriting/Runtime/SaveMyWriting/WritingEntryComposer.swift` |
| `Runtime/WritingKeyboardSetupStateTests.swift` | 13 | 222 | `TranscriptedWriting/Core/Runtime/WritingKeyboardSetupState.swift` |
| `Runtime/WritingModelAdoptionTests.swift` | 7 | 194 | `TranscriptedWriting/Runtime/WritingModelAdoption.swift` |
| `Runtime/WritingModelEligibilityTests.swift` | 5 | 66 | `TranscriptedWriting/Runtime/WritingModelEligibility.swift` |
| `Runtime/WritingModelSwitchTests.swift` | 6 | 96 | `TranscriptedWriting/Runtime/WritingModelSwitch.swift` |
| `Runtime/WritingRuntimePolicyTests.swift` | 7 | 65 | `Writing/WritingRuntimePolicy.swift` |
