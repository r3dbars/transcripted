# Transcripted standalone fast-test audit

Audit baseline: `85bbcc09380f6de16e73119efb672e5e6a628f72` (remote-main snapshot supplied to this lane). Read-only lane; no repository edits, source mutations, Swift builds, dependency installs, app launches, or real audio/private recordings. Reviewed root `AGENTS.md`, `Tests/README.md`, current runner/helper implementation, scoped Speech/Meeting guides, source-shape ratchet, source-pin checker, and current source-text inventory. OpenClaw test-audit methodology: https://github.com/openclaw/openclaw/blob/main/.agents/skills/test-audit/SKILL.md . The audit is adapted to Swift and the actual runner; OpenClaw's Node/Vitest/PR commands are not applicable here.

## Result and scope

The root suite has substantial real behavior coverage. Pure policies, stored preference compatibility, filesystem persistence/deletion, sanitizers, target-confirmation state, synthetic audio processing, and AppKit panel privacy contracts are independently useful. No deletion quota applies. Keep security/privacy/storage/release/platform checks, including legitimate text contracts. The highest-confidence fast-runner defect discovered independently in this lane is a **never-invoked stopped-audio recovery registry suite**. The most important broader gap is **controller/executor behavior being either source-matched or reproduced in test-owned fake executors**.

Every root `Tests/*Tests.swift` file was scanned for entry routing, suite labels, assertion structure, source reads, clock limits, fake types, and test-only seams. Full owner/caller/history inspection was performed for the prioritized candidates below, not for every assertion in the 65,954-line suite. The inventory is complete for files and declared suite labels; this is not an exhaustive semantic proof or line-coverage report.

Baseline inventory: **243 root test files**, **65,954 lines**, **2,461 lexical `runSuite` call sites**, **9,767 lexical assertion call sites**. Lexical counts include code/comments; loops and conditional skips mean they are not executed-test counts. `TestHelpers.swift:28–71` increments the public runner totals for each assertion, not each suite. Three files (`ASRInferenceWaiterQueueTests`, `ModelLoadProgressWaiterTests`, `DictationInputBindingSettleTests`) assert directly without `runSuite`; they execute but do not support suite-level quarantine. One additional top-level `test*` function is currently uncalled; see F1.

Shape metadata: **51 root test files / 479 source-text read-use matches** and **2 root test files / 4 wall-clock assertion matches**. The ratchet measures reads/helper calls, not number of source assertions. Full repository shape check: 494 grandfathered read-use matches in 57 files and 7 clock assertions in 5 files. The source-pin check resolved 1,272 pins across 91 target files from 483 Swift test/helper files: 95% of 1,346 file-backed contains/range assertions, with 25 unresolved and 49 negative-on-slice assertions skipped. A green source-pin check only proves those strings currently match.

## Prioritized evidence

### F1 — P1: a stopped-audio registry test is defined but never runs

- Exact location: `Tests/DictationStoppedAudioRecoveryTests.swift:18`, `testDictationStoppedAudioRecoveryRetryRegistry()`, suite `stopped dictation recovery survives a failed retry until success`.
- Actual routing: `scripts/entrypoints/run-tests.sh:224–259` derives exactly one function from each filename; generated runner calls `testDictationStoppedAudioRecovery`, not the extra function. `rg -n testDictationStoppedAudioRecoveryRetryRegistry . --glob '*.swift' --glob '!build/**'` found only the declaration. An all-root `^func test*` scan found this as the only unreferenced extra test entry (the other extra helper, `testRecentCaptureLoader`, is invoked).
- What it detects today: **nothing in normal/filtered fast runs**. If invoked, it detects retain/lookup/remove for a single ID. The second getter at lines 34–37 repeats the first getter without introducing a retry failure; it only proves lookup is non-consuming, not a controller retry lifecycle.
- Production owner/callers: `Sources/Dictation/DictationStoppedAudioRecovery.swift:12–25`; `MeetingSessionController` stores it at line 330, looks up before retry at 2949, removes on explicit discard at 2955, removes after saved transcript at 3480, retains on failed import at 3523, and removes accidental-start completion at 3720. These are real data-preservation paths, not test-only code.
- Stronger existing proof: `DictationStoppedAudioRecoveryTests` already proves WAV bytes, owner-only permissions, discovery, failed-save retention, explicit-discard cleanup; `DictationStoppedAudioInterleavingTests` combines store and gate synthetically. Neither invokes this registry suite or proves ID isolation. No stronger real controller retry executor proof exists in this fast lane.
- History: introduced in `b7912b101` on 2026-07-18; unchanged body remains in current file despite recent stop-stage extractions (`9f8cc189`, `2bb11d81`). The identity is specifically failed-meeting ID, not dictation session ID.
- Coherent test-only improvement: route the suite through the canonical entry or give it a separate convention-named file; name the registry promise honestly. Cover missing ID, two IDs, replacement for one ID, non-consuming lookups, remove-one-preserves-other, repeated/missing removal. Do not claim a simulated getter is a failed production retry. A deliberate mutation of `retain` or wrong-key/remove-all behavior must fail after routing; an assertion sentinel in the old helper proves the baseline reachability hole if needed.
- Deletion unlocked: only the misleading repeated assertion/unreachable wrapper if folded; no production deletion.
- Risk: low test-only edit, high-value retention contract. Focus: `bash run-tests.sh --filter DictationStoppedAudioRecovery`; full `bash run-tests.sh`, shape checks, `bash check.sh`.

### F2 — P1 follow-up: observer-rebinding test owns the behavior it claims to prove

- Exact location: `Tests/ParakeetAudioObserverOwnershipTests.swift:24–40`, `Parakeet overlapping rebuild binds the final observer to the live engine`; fake `ParakeetAudioObserverBindingTestState` at 44–59.
- What it detects: the real `ParakeetAudioGraphOwnerToken.matchesEngine` behavior plus correctness of the test's own remove/install/storage code. Removing production `removeAudioEngineConfigObserver()` or observer-reinstall calls cannot affect the fake and would not fail this suite. The fake implements every observer transition and the test explicitly orders them.
- Real owner/callers: `ParakeetDeviceRecovery.swift:20–62` installs/removes/restores the actual NotificationCenter registration, including `!isShuttingDown`; `ParakeetEngine.swift:1349–1383` tears down, restores from defer, removes any observer restored by a stale overlap, then installs on replacement. Recording start/rebuild/recovery/wake paths use these methods.
- Stronger remaining proof: first suite checks real engine identity in the token and should be retained. `ParakeetAudioGraphOwnershipTests` validates other real ownership types; Bluetooth and device-recovery source pins preserve call placement. These do not prove real observer registration/delivery. The cheap static checks are necessary until replacement executor coverage exists.
- History: `66fd5f57`, `Rebind observer after overlapping audio rebuild` (2026-07-23), introduced the real repair and the fake together. This is a credible regression, not obsolete functionality.
- Stronger proof: run the real rebuild/observer executor with an injected graph driver or delayed-fake engine scaffold and NotificationCenter; hold stale restoration, publish replacement, post to retired and live engine objects, assert exactly one live callback and no callbacks after shutdown. Mutation: omit the second removal before replacing graph; observe callback binding fail. Do not extract a seam used only by tests.
- Deletion unlocked: test-owned observer fake only after owner-boundary replacement. No removal proposed now; no test-only production seam identified.
- Risk: medium/high audio ownership boundary. Focus currently `bash run-tests.sh --filter ParakeetAudioObserverOwnership` and `--filter ParakeetAudioGraphOwnership`; future executor tests plus build/integration and hardware limits explicitly stated.

### F3 — P1 follow-up: synthetic stopped-audio finalizer cannot prove controller ordering or delivery

- Exact location: `Tests/DictationStoppedAudioInterleavingTests.swift:8`, `Two Stops during a blocked WAV checkpoint, model outcome …`; fake `SyntheticStoppedAudioFinalizer.stop` at approximately 126–169.
- Actual proof: real `DictationStopFinalizationGate`, `DictationAudioRecovery`, `DictationEmptyInferencePolicy`, and real private WAV storage cooperate under a synthetic barrier. This is useful component-composition proof.
- Gap: fake executor itself increments `terminalPublications`, decides error/empty branches, increments `deliveries`, and invokes cleanup with `transcriptPersisted: true`; it never calls the app stop controller, pastes, or writes a Markdown transcript. Asserting `deliveries == 1` does not prove exactly one real paste/save; asserting WAV retirement on `.text` trusts a cleanup receipt supplied by the fake.
- Real callers: `DictationSessionController.stopDictationAndPaste` now invokes production `DictationStopCheckpoint.run` around line 1251, then `DictationPostStopModelWait.run` and terminal policies. `DictationStopCheckpointTests` runs the real extracted stop executor and proves mic/cue/snapshot/write order, session fences, off-main write/discard, and checkpoint failure. `DictationStopFinalizationPolicyTests` runs real save/Auto Enter ordering. These are stronger for those distinct stages, but the full controller publication boundary remains unavailable in the fast runner.
- History: suite belongs to the recording durability/cancellation fixes in the `c35aea2d` lineage; stop executor extracted subsequently in `9f8cc189`. Keep recording/data safety until equivalent real-path proof is demonstrated.
- Stronger proof: compose the production extracted stages and real writer at an actual caller boundary with fake model/clipboard adapters; hold WAV write; two actual stop admissions; ensure no delivery before one saved artifact and preserve WAV after model/save failure. Author from a promise and show a baseline/mutation failure at the real stage.
- Deletion unlocked: synthetic finalizer executor only after replacement; none in this PR. Risk: high data safety. Commands: filtered Interleaving/StopCheckpoint/PostStopModelWait/StopFinalization suites, deterministic E2E, full app build/fast tests.

### F4 — P2: remaining clock thresholds and one stale skip label

- `ClipboardRestoringTextPasterTests.swift:2056–2120`, `…unconfirmed paste does not arm Auto Enter`, asserts `elapsed < 0.15` at 2100. Its meaningful outputs already verify copied outcome and retained dictation text. A loaded scheduler can violate 150 ms without a behavior regression.
- `…waits when no pasteboard read occurs` at 2121–2180 is skipped in CI via `TRANSCRIPTED_SKIP_TIMING_SENSITIVE_TESTS=1` (`swift-ci.yml:171–174`). The name/skip copy describes a pending/floor timing proof, but the actual current assertion at 2171 is again `< 0.15` and expects **no pending wait** for unconfirmed paste. It duplicates the nearby unconfirmed-flow scenario with a fake pasteboard and no independent confirmed-Auto-Enter outcome.
- `ParakeetRecoveryStateTests.swift:256–290`, `In-flight AUHAL setter awaits bounded confirmation without blocking notification delivery`, asserts success `<2.5s` (267) and hung setter `<1.0s` (284), using 5 s/50 ms actual timeouts and 40/20 ms sleeps. The eventual echo ownership/late-confirmation outcomes are useful; thresholds are scheduler-sensitive. `fa425791` widened setter timing specifically for slow CI; this is a maintenance risk with documented history, not evidence to delete the regression.
- Production callers: `ClipboardRestoringTextPaster.waitForClipboardReadyForAutoEnter` serves optional real Auto Enter after target confirmation; `ParakeetAUHALBindingToken.waitForResolution` serves device notification recovery. Existing clipboard target-read/confirmation policies and token echo ownership tests are primary behavior owners, but no injected timer seam covers the wait itself.
- Stronger proof: replace wall-clock asserts with held/released work + independently observed return/ownership, or a real production-needed clock injection. For unconfirmed Auto Enter, assert no Enter dispatch and unchanged recovery clipboard at the owning delivery boundary; use the actual outcomes in the suite name. Preserve confirmed readiness/fallback contract and all existing restore/user-copy tests.
- Deletion unlocked: duplicated clock assertion/skip only if independent behavior is represented; no production removal. Risk medium paste safety/audio recovery. Commands: clipboard and ParakeetRecoveryState filters, slow pasteback smoke, shape `--shrink` only after conversion.

### F5 — P2 follow-up: source-only wiring remains at actual safety/privacy boundaries

Representative high-confidence locations:

- `DictationStartedTelemetryContractTests.swift`: placement/order of `dictation_start_requested`, successful `dictation_started`, refusals and failure attribution are source slices of `DictationSessionController`. This cannot distinguish an unreachable/misguarded call containing the same tokens. Real caller is the controller; policies alone do not prove lifecycle emission. Need actual capture start executor and event-recording sink before removing pins. History `90e00d57`, `Count every dictation start a user asks for`; admission extraction in `35c51aaf` strengthens decision proof but does not prove event emission. Filter `DictationStartedTelemetryContract`.
- `AnalyticsEventForwardingPolicyTests.swift:350+`, `EventReporter forwards the caller's context, not the merged engine state`: pins `forwardedEvent(` and `context: context ?? [:]`. The file's other 7 suites execute the real policy and sanitizers, independently checking allowed events/keys/values. Real `EventReporter.capture` at `EventReporter.swift:192–272` merges state for local diagnostics but forwards caller context at 252. A captured sink should verify contradictory engine-state/caller values and privacy scrub at the real reporter boundary. The policy+sanitizer combination remains valuable and is not duplicated proof. Filter `AnalyticsEventForwardingPolicy`; no source-pin removal yet.
- `AuditRegressionCoverageContractTests.swift:13–37`: whole-second overlay/menubar duration pins can pass when a subscriber is dead and fail on `.map` refactors. Source owner `MeetingOverlayController` and `MenuBarPanelController`, real UI publishers, are not compiled by the fast runner. Need a production-needed duration publisher/output seam; behavior test fractional ticks must produce only distinct whole-second layout updates. The pasteback suite in the same file already executes the real paster and must remain; failed queue-terminal revisit is still static.
- `CrashReporterOptionsTests.swift`: exact assignment strings enforce a real SDK privacy/noise boundary. Current test also strips comments and disabled regions and checks assignments precede `SentrySDK.start`; keep until actual SDK options can be captured using dependency-backed types. Do not delete for brittleness alone.
- `BluetoothRouteContractTests`, `DeviceRecoveryPolicyTests`, `ParakeetAudioOwnershipSourceContractTests`, and `ParakeetMicrophoneSharingSourceContractTests`: pure policy/ownership behavior is strong, but raw AVAudioEngine command/read/tap ordering, real default-input override/restore, shared-mic handoff, and late native cleanup remain source-only in this runner. Their live boundaries require graph executor/hardware proof; policy fakes never establish AirPods correctness.
- `UIAutomationSurfaceContractTests`: extensive implementation literals/identifiers (198 shape read-use matches) complement actual QA AX click smoke. Stable accessibility IDs, approved copy, action presence, and platform routes can be legitimate independent UI contracts; source greps alone cannot prove an AX element is present/enabled/clickable. Keep UI boundary smoke and migrate safe pins only after equivalent real AX/presentation proof.

No test-only production export/wrapper was proven removable in this lane. Source-pinned controller seams are production-used paths, not dead code. The source-text inventory itself is stale in places: it still describes a stop/start pipeline seam as wholly absent although `DictationStopCheckpoint`, `DictationPostStopModelWait`, `DictationSessionCapTimer`, and admission policies are now extracted and used. Current code and tests take precedence; do not delete all rows from that older document mechanically.

## Retained apparent false positives

- `CaptureLibraryPathSafetySyncTests`: byte-identical safety logic across app, Core, and CaptureKit build units is the independent architecture/storage contract; keep the file comparison and runtime path rejection tests.
- `OverlayScreenSharePrivacyTests`: actual compiled panels assert real `.sharingType`, focus/level constraints; the source inventory discovers newly added windows across `Sources/UI`. Preserve privacy coverage, including uncompiled transcript-bearing surfaces and explicit opt-in policy. Runtime screenshots alone cannot discover every new window definition.
- Shared sanitizer regression corpus replayed by analytics/Sentry/local sinks is distinct delivery/privacy risk, not duplicate helper coverage. Reporter opt-out/retry buffer tests assert actual persisted records and injected network behavior.
- `NightlySecurityContractTests`: signed-app fixture checker plus entitlement/manifest constraints are independent shipped platform/security proof; preserve. Release metadata consistency and appcast/cask contracts should continue to fail on true cross-file drift.
- Stable preference keys, enum raw values, filename/parser golden fixtures, architecture source-list/data manifests, approved presentation wording, and retained audio duration/channel/tail validation can all be meaningful contracts. Static, repetitive, or literal-based alone is not a deletion reason.
- `DictationConcurrentWriteTests` validates all 120 distinct entries plus one day header in a real temp Markdown file; this is storage-loss proof, not a fake counter. It still needs stronger deterministic race activation/mutation evidence if changed, not relaxation of its expected entry count.
- `SpeakerClipPlaybackTests` executes the real retained-audio player against synthetic audio ranges. The separate CI lane reported an unexplained historic failure; do not remove/loosen range checks without reproducing and replacing equivalent regression proof.
- `AppSoundPlayer playback entrypoints are best effort` in `DictationSoundsTests` has no assertion: it is a no-crash smoke only and does not prove playback. Other preference, cue-resource, stale-cue, and quiet-feedback contracts are independent; keep them. A future fake audio-output boundary may make the no-crash smoke redundant, but no deletion is justified now.

## Runner audit and measurement limits

The runner discovers all 243 filename entries, catches missing/duplicated expected functions and stray root Swift files, and compiles only selected tests plus `TestHelpers.swift` and a curated production source list. This is not a whole-app build; many controller tests consequently resort to greps. Missing production files are checked explicitly. Source-list edits need compiler/build evidence, not just text pins.

A throwaway `TRANSCRIPTED_CONTAINER_DIR` redirects app-owned storage before any static singleton; binary launches disable the file logger. Synthetic private pasteboards and explicit temp directories protect user recordings/clipboard. The reusable app-object cache hashes source contents, source list, compiler and flags; a lock serializes cache mutation. It is released before execution; tests binary/output are shared within one worktree, so concurrent filtered invocations are not an established isolation guarantee. Run one fast suite process at a time per worktree. This is a runner observation, not a proposed unrelated production fix.

`runSuite` supports named quarantine; the current quarantine file has zero entries. Some suites return early on a timing env flag and print SKIPPED without incrementing the quarantine summary. Runtime failure totals count assertions and do not report skipped scenario counts generally. A high assertion count or passing static metadata therefore does not establish complete meaningful behavior coverage.

Hardware limits: no root fast test proves actual microphone recording, Bluetooth/HFP format behavior, live system audio, TCC, real paste-back into external apps, full app accessibility, network model availability, or signed shipping/install behavior. Those require mapped integration/E2E/QA/build/hardware layers and must be reported separately.

## Checks run by this lane

- `python3 scripts/dev/check-test-shape.py` — PASS: 494 read-use matches / 57 files, 7 clock asserts / 5 files; none new.
- `python3 scripts/dev/check-source-pins.py` — PASS: every 1,272 resolved current pin holds; unresolved/sliced-negative limits above.
- `bash -n scripts/entrypoints/run-tests.sh` — PASS.
- Read-only all-root extra-function reachability scan and `rg` caller/history checks — confirmed F1; no other unreferenced top-level extra `test*` entry found.

Not run here: `run-tests.sh`, `swift test`, mutation builds, app build, smokes, hardware, full QA, CI dispatch/retries. Parent implementation lane owns execution and exact-head CI. These read-only results do not substitute for its final-tree proof.

## Complete root-file inventory

The table below names every root fast-test file at the supplied main snapshot. `Suites` and `Assertions` are lexical call sites (not executed counts). `Source uses`/`Clock limits` come from the current ratchet baseline; zero means unflagged, not guaranteed absence of implementation coupling. Dynamic suite labels may expand to multiple runtime scenarios.

| File | Lines | Suites | Assertions | Source uses | Clock limits |
| --- | ---: | ---: | ---: | ---: | ---: |
| `Tests/ASRInferenceWaiterQueueTests.swift` | 73 | 0 | 13 | 0 | 0 |
| `Tests/AccessibilityBridgeTests.swift` | 32 | 3 | 4 | 0 | 0 |
| `Tests/ActivationPolicyControllerTests.swift` | 253 | 17 | 21 | 0 | 0 |
| `Tests/AgentConnectionGuideTests.swift` | 364 | 8 | 74 | 0 | 0 |
| `Tests/AgentMCPConnectorTests.swift` | 748 | 27 | 92 | 0 | 0 |
| `Tests/AgentSetupLifecycleTelemetryTests.swift` | 214 | 6 | 20 | 0 | 0 |
| `Tests/AnalyticsEventForwardingPolicyTests.swift` | 305 | 8 | 28 | 2 | 0 |
| `Tests/AnalyticsEventPolicyTests.swift` | 1937 | 45 | 512 | 11 | 0 |
| `Tests/AnalyticsPayloadSanitizerTests.swift` | 242 | 16 | 64 | 0 | 0 |
| `Tests/AnalyticsReporterTests.swift` | 944 | 43 | 147 | 0 | 0 |
| `Tests/AppHangReportPolicyTests.swift` | 52 | 4 | 10 | 0 | 0 |
| `Tests/AppleSpeechLocalePolicyTests.swift` | 188 | 13 | 44 | 0 | 0 |
| `Tests/AudioAutomationCoverageContractTests.swift` | 128 | 4 | 10 | 8 | 0 |
| `Tests/AudioImportQueueTests.swift` | 75 | 3 | 13 | 0 | 0 |
| `Tests/AudioStoragePreferencesTests.swift` | 47 | 3 | 3 | 0 | 0 |
| `Tests/AuditRegressionCoverageContractTests.swift` | 105 | 4 | 11 | 6 | 0 |
| `Tests/AutoCallDetectionPreferencesTests.swift` | 45 | 3 | 4 | 0 | 0 |
| `Tests/AutoEnterDisplayNameResolverTests.swift` | 66 | 5 | 7 | 0 | 0 |
| `Tests/BluetoothRouteContractTests.swift` | 817 | 23 | 146 | 30 | 0 |
| `Tests/BrowserCallEvidenceTests.swift` | 379 | 20 | 54 | 0 | 0 |
| `Tests/CIWorkflowContractTests.swift` | 119 | 6 | 20 | 0 | 0 |
| `Tests/CallAppMicrophoneSharingMonitorTests.swift` | 147 | 8 | 17 | 0 | 0 |
| `Tests/CallPromptTimeoutClockTests.swift` | 135 | 11 | 32 | 0 | 0 |
| `Tests/CameraActivityMonitorTests.swift` | 29 | 2 | 3 | 0 | 0 |
| `Tests/CaptureLibraryChangeBroadcasterTests.swift` | 108 | 3 | 9 | 0 | 0 |
| `Tests/CaptureLibraryMigrationPlannerTests.swift` | 480 | 16 | 66 | 0 | 0 |
| `Tests/CaptureLibraryPathSafetySyncTests.swift` | 46 | 1 | 3 | 2 | 0 |
| `Tests/CaptureLibrarySizeTests.swift` | 49 | 3 | 8 | 0 | 0 |
| `Tests/CapturePillPlacementPolicyTests.swift` | 28 | 2 | 3 | 0 | 0 |
| `Tests/CaptureUndoTests.swift` | 238 | 7 | 31 | 0 | 0 |
| `Tests/ClaudeDesktopIntegrationInstallerTests.swift` | 2218 | 66 | 229 | 0 | 0 |
| `Tests/ClipboardRestoringTextPasterTests.swift` | 3136 | 74 | 251 | 4 | 2 |
| `Tests/ContextCaptureEnginePolicyTests.swift` | 848 | 43 | 90 | 22 | 0 |
| `Tests/CrashReporterOptionsTests.swift` | 79 | 1 | 5 | 1 | 0 |
| `Tests/CustomDictionaryPreferencesTests.swift` | 178 | 9 | 17 | 0 | 0 |
| `Tests/DefaultInputDeviceMonitorTests.swift` | 473 | 22 | 63 | 0 | 0 |
| `Tests/DeviceRecoveryPolicyTests.swift` | 446 | 13 | 43 | 6 | 0 |
| `Tests/DiarizationBackendPreferencesTests.swift` | 36 | 3 | 11 | 0 | 0 |
| `Tests/DictationAudioLevelMeterTests.swift` | 48 | 2 | 5 | 0 | 0 |
| `Tests/DictationAudioRecoveryTests.swift` | 196 | 5 | 28 | 2 | 0 |
| `Tests/DictationAutoSendPreferencesTests.swift` | 284 | 8 | 38 | 0 | 0 |
| `Tests/DictationCancelHintPolicyTests.swift` | 80 | 4 | 11 | 0 | 0 |
| `Tests/DictationCleanupPreferencesTests.swift` | 36 | 3 | 4 | 0 | 0 |
| `Tests/DictationConcurrentWriteTests.swift` | 74 | 1 | 3 | 0 | 0 |
| `Tests/DictationEmptyTranscriptPolicyTests.swift` | 92 | 9 | 21 | 0 | 0 |
| `Tests/DictationFillerCleanupPolicyTests.swift` | 99 | 10 | 24 | 0 | 0 |
| `Tests/DictationInputBindingSettleTests.swift` | 143 | 0 | 28 | 0 | 0 |
| `Tests/DictationInputDeviceSelectionPolicyTests.swift` | 1234 | 38 | 157 | 4 | 0 |
| `Tests/DictationLanguageScriptPolicyTests.swift` | 111 | 10 | 33 | 2 | 0 |
| `Tests/DictationMeterPolicyTests.swift` | 63 | 3 | 7 | 0 | 0 |
| `Tests/DictationMicrophoneLoadingPresentationPolicyTests.swift` | 71 | 5 | 13 | 0 | 0 |
| `Tests/DictationNoSpeechPresentationPolicyTests.swift` | 83 | 6 | 14 | 0 | 0 |
| `Tests/DictationOverlayPlacementPolicyTests.swift` | 59 | 4 | 7 | 0 | 0 |
| `Tests/DictationOverlayPresentationPreferencesTests.swift` | 163 | 8 | 23 | 0 | 0 |
| `Tests/DictationPostStopModelWaitTests.swift` | 173 | 11 | 27 | 0 | 0 |
| `Tests/DictationQueuedStartPolicyTests.swift` | 101 | 5 | 19 | 6 | 0 |
| `Tests/DictationReadinessWaitPolicyTests.swift` | 402 | 30 | 38 | 0 | 0 |
| `Tests/DictationRecordingStartAttemptTests.swift` | 108 | 8 | 22 | 2 | 0 |
| `Tests/DictationRecordingStartOverlayPolicyTests.swift` | 524 | 31 | 71 | 8 | 0 |
| `Tests/DictationSessionCapTests.swift` | 203 | 5 | 24 | 2 | 0 |
| `Tests/DictationSessionCapTimerTests.swift` | 122 | 6 | 15 | 0 | 0 |
| `Tests/DictationSessionCapWarningPolicyTests.swift` | 64 | 4 | 14 | 0 | 0 |
| `Tests/DictationSessionDecisionTests.swift` | 73 | 5 | 5 | 0 | 0 |
| `Tests/DictationSessionTimeoutTests.swift` | 37 | 3 | 9 | 0 | 0 |
| `Tests/DictationSoundsTests.swift` | 234 | 10 | 37 | 4 | 0 |
| `Tests/DictationStartActivationTests.swift` | 287 | 14 | 48 | 0 | 0 |
| `Tests/DictationStartAdmissionTests.swift` | 142 | 7 | 21 | 0 | 0 |
| `Tests/DictationStartCuePolicyTests.swift` | 36 | 3 | 9 | 0 | 0 |
| `Tests/DictationStartReadinessTests.swift` | 398 | 14 | 72 | 8 | 0 |
| `Tests/DictationStartedTelemetryContractTests.swift` | 148 | 4 | 14 | 2 | 0 |
| `Tests/DictationStartupRouteReadinessTests.swift` | 155 | 3 | 18 | 0 | 0 |
| `Tests/DictationStopCheckpointTests.swift` | 217 | 12 | 25 | 0 | 0 |
| `Tests/DictationStopFinalizationPolicyTests.swift` | 120 | 6 | 13 | 0 | 0 |
| `Tests/DictationStoppedAudioInterleavingTests.swift` | 167 | 1 | 11 | 0 | 0 |
| `Tests/DictationStoppedAudioRecoveryTests.swift` | 428 | 9 | 62 | 6 | 0 |
| `Tests/DictationTerminationCheckpointTests.swift` | 198 | 6 | 45 | 2 | 0 |
| `Tests/DictationTranscriptPersistenceTests.swift` | 120 | 4 | 23 | 1 | 0 |
| `Tests/DictationTranscriptStoreTests.swift` | 390 | 9 | 35 | 0 | 0 |
| `Tests/DictationTranscriptWriterTests.swift` | 206 | 4 | 21 | 0 | 0 |
| `Tests/DictationWarmupPresentationPolicyTests.swift` | 103 | 7 | 23 | 0 | 0 |
| `Tests/DictionaryPastMeetingFixTests.swift` | 450 | 15 | 105 | 0 | 0 |
| `Tests/ExistingInstallModelPrefetchPolicyTests.swift` | 332 | 12 | 30 | 2 | 0 |
| `Tests/FailedMeetingPresentationTests.swift` | 689 | 29 | 102 | 3 | 0 |
| `Tests/FailedMeetingRecoveryPresentationTests.swift` | 118 | 8 | 15 | 0 | 0 |
| `Tests/FeedbackIssueBuilderTests.swift` | 160 | 8 | 43 | 0 | 0 |
| `Tests/FirstRunExperienceTests.swift` | 381 | 23 | 105 | 0 | 0 |
| `Tests/FocusOrderContractTests.swift` | 184 | 3 | 17 | 10 | 0 |
| `Tests/HomeCaptureRefreshTests.swift` | 268 | 2 | 13 | 0 | 0 |
| `Tests/HomeDeleteConfirmationPolicyTests.swift` | 42 | 2 | 6 | 0 | 0 |
| `Tests/HomeFirstArtifactVisibilityTests.swift` | 111 | 1 | 10 | 6 | 0 |
| `Tests/HomeImportAudioActionTests.swift` | 71 | 1 | 7 | 4 | 0 |
| `Tests/HomeMeetingCacheIsolationTests.swift` | 191 | 2 | 14 | 0 | 0 |
| `Tests/HomeMeetingDeletionTests.swift` | 530 | 13 | 75 | 0 | 0 |
| `Tests/HomeMeetingPreviewFormatterTests.swift` | 207 | 4 | 30 | 0 | 0 |
| `Tests/HomeMeetingRenameTests.swift` | 910 | 20 | 86 | 0 | 0 |
| `Tests/HomeMeetingSearchIndexTests.swift` | 306 | 10 | 38 | 0 | 0 |
| `Tests/HomePresentationTests.swift` | 119 | 6 | 23 | 0 | 0 |
| `Tests/HomeRootAlertPolicyTests.swift` | 70 | 4 | 8 | 0 | 0 |
| `Tests/HomeScanWarningPolicyTests.swift` | 72 | 5 | 10 | 0 | 0 |
| `Tests/HomeSearchMatchingTests.swift` | 80 | 2 | 19 | 0 | 0 |
| `Tests/HomeTranscriptionActivityCopyTests.swift` | 78 | 6 | 8 | 0 | 0 |
| `Tests/HotkeyPreferencesTests.swift` | 129 | 7 | 12 | 0 | 0 |
| `Tests/LabControlCommandTests.swift` | 164 | 7 | 84 | 0 | 0 |
| `Tests/LaunchAtLoginPreferencesTests.swift` | 155 | 6 | 24 | 0 | 0 |
| `Tests/LocalObservabilityPayloadSanitizerTests.swift` | 274 | 13 | 39 | 0 | 0 |
| `Tests/MachineClassTelemetryTests.swift` | 50 | 4 | 23 | 0 | 0 |
| `Tests/MeetingArtifactAudioDirectoryNamingTests.swift` | 42 | 1 | 1 | 0 | 0 |
| `Tests/MeetingArtifactRecoveryStoreTests.swift` | 275 | 4 | 13 | 0 | 0 |
| `Tests/MeetingAudioArchiveResolverTests.swift` | 617 | 1 | 57 | 0 | 0 |
| `Tests/MeetingAudioInactivityDetectorTests.swift` | 191 | 8 | 25 | 0 | 0 |
| `Tests/MeetingAudioStorageManagerTests.swift` | 1443 | 41 | 153 | 0 | 0 |
| `Tests/MeetingCallAudioAskTests.swift` | 96 | 7 | 10 | 0 | 0 |
| `Tests/MeetingCaptureAttemptTests.swift` | 286 | 10 | 23 | 0 | 0 |
| `Tests/MeetingCaptureCompletionPolicyTests.swift` | 40 | 3 | 3 | 0 | 0 |
| `Tests/MeetingCaptureVolumeDiagnosticsTests.swift` | 591 | 24 | 110 | 0 | 0 |
| `Tests/MeetingDurationFormatterTests.swift` | 33 | 4 | 12 | 0 | 0 |
| `Tests/MeetingFailureCopyTests.swift` | 160 | 8 | 26 | 0 | 0 |
| `Tests/MeetingFailureKindTests.swift` | 387 | 36 | 52 | 0 | 0 |
| `Tests/MeetingImportPreparationFailureCopyTests.swift` | 73 | 4 | 10 | 0 | 0 |
| `Tests/MeetingImportedAudioPreparerTests.swift` | 1019 | 30 | 124 | 0 | 0 |
| `Tests/MeetingInviteeSuggestionPolicyTests.swift` | 189 | 9 | 26 | 0 | 0 |
| `Tests/MeetingLanguageDetectionPolicyTests.swift` | 26 | 2 | 17 | 0 | 0 |
| `Tests/MeetingMicBoostPromptPolicyTests.swift` | 146 | 8 | 17 | 0 | 0 |
| `Tests/MeetingMicOnlyNoticeTests.swift` | 222 | 9 | 42 | 0 | 0 |
| `Tests/MeetingMicrophonePreferencesTests.swift` | 56 | 2 | 10 | 2 | 0 |
| `Tests/MeetingOverlayPillPreferencesTests.swift` | 29 | 1 | 3 | 0 | 0 |
| `Tests/MeetingPillFinishPresentationTests.swift` | 71 | 5 | 26 | 0 | 0 |
| `Tests/MeetingPillRestPolicyTests.swift` | 93 | 3 | 10 | 0 | 0 |
| `Tests/MeetingProcessingTelemetryTests.swift` | 75 | 3 | 20 | 0 | 0 |
| `Tests/MeetingPromptDetectorTests.swift` | 1400 | 46 | 141 | 0 | 0 |
| `Tests/MeetingPromptHeuristicsTests.swift` | 601 | 31 | 106 | 0 | 0 |
| `Tests/MeetingPromptLearnedBackoffTests.swift` | 170 | 7 | 26 | 0 | 0 |
| `Tests/MeetingPromptPriorityTests.swift` | 384 | 12 | 78 | 0 | 0 |
| `Tests/MeetingPromptRecordActionTests.swift` | 94 | 4 | 8 | 0 | 0 |
| `Tests/MeetingPromptTelemetryTests.swift` | 269 | 7 | 59 | 0 | 0 |
| `Tests/MeetingQuickSummaryExtractorTests.swift` | 228 | 9 | 33 | 0 | 0 |
| `Tests/MeetingRecordingStartGateTests.swift` | 298 | 13 | 61 | 0 | 0 |
| `Tests/MeetingSessionStateMachineTests.swift` | 155 | 13 | 38 | 0 | 0 |
| `Tests/MeetingSessionUIPolicyTests.swift` | 342 | 19 | 38 | 12 | 0 |
| `Tests/MeetingSpeakerSeparationProviderTests.swift` | 48 | 2 | 4 | 0 | 0 |
| `Tests/MeetingStartFailureClassifierTests.swift` | 353 | 14 | 47 | 0 | 0 |
| `Tests/MeetingStopSnapshotEvidenceTests.swift` | 100 | 3 | 15 | 2 | 0 |
| `Tests/MeetingTranscriptStylerTests.swift` | 797 | 1 | 72 | 0 | 0 |
| `Tests/MeetingUnexpectedStopDurationTests.swift` | 58 | 3 | 6 | 0 | 0 |
| `Tests/MeetingWarmupStatusPolicyTests.swift` | 177 | 12 | 36 | 0 | 0 |
| `Tests/MenuBarHeaderLayoutPolicyTests.swift` | 49 | 2 | 7 | 0 | 0 |
| `Tests/MenuBarHeaderStatusPresentationTests.swift` | 98 | 4 | 18 | 0 | 0 |
| `Tests/MenuBarMeetingCapturePhaseTests.swift` | 22 | 2 | 14 | 0 | 0 |
| `Tests/MenuBarPrimaryButtonTitleTests.swift` | 32 | 2 | 3 | 0 | 0 |
| `Tests/MenuBarShortcutWarningPresentationTests.swift` | 47 | 4 | 8 | 0 | 0 |
| `Tests/MicActivityMonitorTests.swift` | 166 | 12 | 14 | 0 | 0 |
| `Tests/MicRecordingMergePlanTests.swift` | 77 | 5 | 7 | 0 | 0 |
| `Tests/MicrophoneChoicePreferencesTests.swift` | 159 | 5 | 29 | 2 | 0 |
| `Tests/MicrophoneProcessingPreferencesTests.swift` | 321 | 13 | 51 | 3 | 0 |
| `Tests/ModelCacheInventoryTests.swift` | 350 | 13 | 56 | 0 | 0 |
| `Tests/ModelLoadProgressWaiterTests.swift` | 77 | 0 | 12 | 0 | 0 |
| `Tests/NightlySecurityContractTests.swift` | 311 | 9 | 66 | 1 | 0 |
| `Tests/NotchIslandGeometryTests.swift` | 252 | 11 | 68 | 0 | 0 |
| `Tests/NotchIslandPresentationTests.swift` | 419 | 25 | 104 | 0 | 0 |
| `Tests/NotchIslandSpeakerReviewPolicyTests.swift` | 244 | 13 | 72 | 0 | 0 |
| `Tests/ObservabilityLogRotationTests.swift` | 82 | 4 | 12 | 0 | 0 |
| `Tests/ObservabilityLogWriterTests.swift` | 392 | 12 | 59 | 15 | 0 |
| `Tests/ObservabilityPreferencesTests.swift` | 25 | 2 | 4 | 0 | 0 |
| `Tests/ObservabilityTextRedactorTests.swift` | 323 | 27 | 91 | 0 | 0 |
| `Tests/OnboardingAbandonmentReasonPolicyTests.swift` | 14 | 1 | 2 | 0 | 0 |
| `Tests/OverlayScreenSharePrivacyTests.swift` | 308 | 8 | 21 | 20 | 0 |
| `Tests/OwnFileResolverTests.swift` | 147 | 2 | 11 | 0 | 0 |
| `Tests/ParakeetAudioGraphOwnershipTests.swift` | 1171 | 23 | 123 | 2 | 0 |
| `Tests/ParakeetAudioObserverOwnershipTests.swift` | 59 | 2 | 5 | 0 | 0 |
| `Tests/ParakeetAudioOwnershipSourceContractTests.swift` | 441 | 8 | 54 | 11 | 0 |
| `Tests/ParakeetCacheMigrationTests.swift` | 65 | 1 | 11 | 0 | 0 |
| `Tests/ParakeetInputTapFormatPolicyTests.swift` | 66 | 3 | 9 | 0 | 0 |
| `Tests/ParakeetMicrophoneSharingSourceContractTests.swift` | 102 | 4 | 37 | 2 | 0 |
| `Tests/ParakeetModelInitDiagnosticsTests.swift` | 476 | 18 | 67 | 0 | 0 |
| `Tests/ParakeetPrewarmPolicyTests.swift` | 55 | 4 | 4 | 0 | 0 |
| `Tests/ParakeetRecoveryStateTests.swift` | 611 | 40 | 147 | 4 | 2 |
| `Tests/ParakeetShortAudioGateTests.swift` | 165 | 13 | 38 | 0 | 0 |
| `Tests/ParakeetStartRecordingFailurePolicyTests.swift` | 1024 | 57 | 181 | 9 | 0 |
| `Tests/ParakeetSystemWakePolicyTests.swift` | 19 | 2 | 2 | 0 | 0 |
| `Tests/PasteLastDictationFeedbackTests.swift` | 67 | 5 | 20 | 0 | 0 |
| `Tests/PayloadSanitizationCoreTests.swift` | 55 | 8 | 13 | 0 | 0 |
| `Tests/PermissionStateHarnessContractTests.swift` | 72 | 3 | 8 | 5 | 0 |
| `Tests/PermissionsOnboardingPreferencesTests.swift` | 168 | 7 | 21 | 0 | 0 |
| `Tests/PhysicalDictationTriggerPreferencesTests.swift` | 616 | 19 | 61 | 0 | 0 |
| `Tests/PhysicalShortcutMatcherTests.swift` | 323 | 16 | 38 | 0 | 0 |
| `Tests/PinnedDictationSpeedPathTests.swift` | 129 | 5 | 38 | 0 | 0 |
| `Tests/PinnedMicrophoneCapturePreferencesTests.swift` | 62 | 3 | 5 | 0 | 0 |
| `Tests/PipelineErrorKindContractTests.swift` | 186 | 6 | 8 | 0 | 0 |
| `Tests/QuitConfirmationPreferencesTests.swift` | 83 | 2 | 14 | 0 | 0 |
| `Tests/RecentCaptureScannersTests.swift` | 1810 | 52 | 156 | 0 | 0 |
| `Tests/RecordedAudioTimelineTests.swift` | 230 | 14 | 42 | 1 | 0 |
| `Tests/ReleaseMetadataContractTests.swift` | 257 | 4 | 31 | 0 | 0 |
| `Tests/ReliabilityPacketRecorderTests.swift` | 615 | 16 | 116 | 0 | 0 |
| `Tests/RetainedDataSourceComboBoxTests.swift` | 55 | 2 | 7 | 4 | 0 |
| `Tests/RetranscribeLocalSpeakerPreferenceContractTests.swift` | 45 | 1 | 7 | 4 | 0 |
| `Tests/RuntimeDiagnosticsStoreTests.swift` | 427 | 15 | 50 | 0 | 0 |
| `Tests/STTRouterPolicyTests.swift` | 265 | 17 | 71 | 3 | 0 |
| `Tests/SentryEventPolicyTests.swift` | 669 | 18 | 156 | 6 | 0 |
| `Tests/SentryPayloadSanitizerTests.swift` | 323 | 18 | 112 | 0 | 0 |
| `Tests/SentryRuntimeConfigurationTests.swift` | 239 | 12 | 24 | 0 | 0 |
| `Tests/SettingsRecentCaptureRefreshPolicyTests.swift` | 299 | 16 | 46 | 0 | 0 |
| `Tests/SharedMeetingMicClaimTests.swift` | 111 | 9 | 11 | 0 | 0 |
| `Tests/SharedMeetingMicLevelMeterTests.swift` | 150 | 4 | 19 | 0 | 0 |
| `Tests/SharedMeetingMicRecorderTests.swift` | 105 | 5 | 11 | 0 | 0 |
| `Tests/SingleInstanceGuardTests.swift` | 46 | 3 | 11 | 1 | 0 |
| `Tests/SpeakerClipPlaybackTests.swift` | 107 | 4 | 18 | 0 | 0 |
| `Tests/SpeakerEmbedderLoadFailureMemoryTests.swift` | 80 | 6 | 14 | 0 | 0 |
| `Tests/SpeakerEmbedderPreferencesTests.swift` | 47 | 4 | 15 | 0 | 0 |
| `Tests/SpeakerNameSelectionPolicyTests.swift` | 85 | 5 | 11 | 0 | 0 |
| `Tests/SpeakerNamingPolicyTests.swift` | 243 | 10 | 23 | 0 | 0 |
| `Tests/SpeakerPeopleReviewPolicyTests.swift` | 92 | 5 | 7 | 0 | 0 |
| `Tests/SpeakerRecognitionTelemetryTests.swift` | 33 | 2 | 14 | 0 | 0 |
| `Tests/SpeakerReviewPresentationGateTests.swift` | 73 | 6 | 26 | 0 | 0 |
| `Tests/SpeakerReviewQueueScannerTests.swift` | 728 | 17 | 66 | 0 | 0 |
| `Tests/SpeakerReviewStackTests.swift` | 188 | 7 | 29 | 0 | 0 |
| `Tests/SpeakerVoiceRowPresentationTests.swift` | 122 | 7 | 25 | 0 | 0 |
| `Tests/StatusItemPresentationTests.swift` | 241 | 3 | 29 | 5 | 0 |
| `Tests/SupportDiagnosticsBundleTests.swift` | 229 | 4 | 55 | 0 | 0 |
| `Tests/SustainedActivityConfirmerTests.swift` | 85 | 6 | 15 | 0 | 0 |
| `Tests/TelemetryContextTests.swift` | 49 | 3 | 18 | 0 | 0 |
| `Tests/TimedOutFailedMeetingFinalizationTests.swift` | 364 | 12 | 51 | 0 | 0 |
| `Tests/TodayPresentationTests.swift` | 211 | 8 | 68 | 0 | 0 |
| `Tests/TranscriptedConstantsTests.swift` | 237 | 14 | 41 | 0 | 0 |
| `Tests/TranscriptedPermissionAccessTests.swift` | 1150 | 43 | 173 | 0 | 0 |
| `Tests/TranscriptedStoragePathsTests.swift` | 641 | 16 | 77 | 0 | 0 |
| `Tests/TranscriptedSupportActionsTests.swift` | 73 | 4 | 14 | 0 | 0 |
| `Tests/TranscriptionLanguagePreferencesTests.swift` | 122 | 7 | 38 | 0 | 0 |
| `Tests/TranscriptionModelPreferencesTests.swift` | 122 | 8 | 28 | 0 | 0 |
| `Tests/TranscriptionModelWarmupOwnershipTests.swift` | 237 | 14 | 57 | 0 | 0 |
| `Tests/UIAutomationSurfaceContractTests.swift` | 1175 | 19 | 117 | 198 | 0 |
| `Tests/UnrecognizedSelectorReasonTests.swift` | 56 | 5 | 15 | 0 | 0 |
| `Tests/UpdateActionSafetyPolicyTests.swift` | 206 | 8 | 28 | 0 | 0 |
| `Tests/UpdateClickRoutingPolicyTests.swift` | 141 | 6 | 19 | 0 | 0 |
| `Tests/UpdateFailureKindTests.swift` | 206 | 10 | 40 | 0 | 0 |
| `Tests/UpdateInstallDetectionTests.swift` | 162 | 5 | 21 | 0 | 0 |
| `Tests/UsageHealthStoreTests.swift` | 107 | 5 | 27 | 0 | 0 |
| `Tests/WakeRecoveryCoordinatorTests.swift` | 337 | 7 | 38 | 0 | 0 |
| `Tests/WhisperCustomDictionaryTests.swift` | 60 | 3 | 4 | 1 | 0 |
| `Tests/WritingAnalyticsTests.swift` | 204 | 7 | 41 | 0 | 0 |
| `Tests/WritingDayFileReaderTests.swift` | 103 | 3 | 22 | 0 | 0 |
| `Tests/WritingDemoScriptTests.swift` | 70 | 4 | 29 | 0 | 0 |
| `Tests/WritingSetupPresentationTests.swift` | 310 | 13 | 109 | 0 | 0 |
| `Tests/WritingSetupStateTests.swift` | 108 | 6 | 23 | 0 | 0 |

