// DeviceRecoveryPolicyTests.swift
// First dedicated unit-test suite for ParakeetEngine's device-change recovery
// decision table (codebase audit 2026-07-08 wave 2, spec W2-C).
//
// The decision types under test — ParakeetDeviceRecoveryReadinessPolicy,
// ParakeetDeviceRecoveryFailurePolicy, and ParakeetDeviceRecoveryTimeoutPolicy —
// are pure, Foundation-only enums defined in ParakeetStartRecordingFailurePolicy.swift.
// They are the decision layer that ParakeetDeviceRecovery.swift's side-effecting
// executor (attemptDeviceRecovery / scheduleConfigRecoveryTimeout) consults; this
// file enumerates every branch of that decision table as one canonical table
// instead of leaving it implicit across prose assertions.

import Foundation

func testDeviceRecoveryPolicy() {
    func routeIdentity(
        defaultInputID: UInt32,
        selectedInputID: UInt32,
        outputID: UInt32?,
        reason: DictationInputDeviceSelectionReason = .defaultIsSafe
    ) -> ParakeetAudioRouteIdentity {
        let defaultInput = DictationAudioDevice(
            id: defaultInputID,
            name: "Input \(defaultInputID)",
            transport: .builtIn,
            inputChannelCount: 1,
            uid: "input-\(defaultInputID)"
        )
        let selectedInput = DictationAudioDevice(
            id: selectedInputID,
            name: "Selected \(selectedInputID)",
            transport: .builtIn,
            inputChannelCount: 1,
            uid: "selected-\(selectedInputID)"
        )
        let output = outputID.map {
            DictationAudioDevice(
                id: $0,
                name: "Output \($0)",
                transport: .builtIn,
                inputChannelCount: 0,
                uid: "output-\($0)"
            )
        }
        return ParakeetAudioRouteIdentity(
            selection: DictationInputDeviceSelection(
                defaultInput: defaultInput,
                selectedInput: selectedInput,
                defaultOutput: output,
                reason: reason
            )
        )
    }

    runSuite("Device recovery retains recording intent across a Bluetooth notification burst") {
        let source = readSourceFixture("Sources/Speech/ParakeetDeviceRecovery.swift")
        guard let attemptStart = source.range(of: "private func attemptDeviceRecovery()"),
              let taskStart = source.range(of: "configRecoveryTask = Task", range: attemptStart.upperBound..<source.endIndex),
              let terminalStart = source.range(of: "defer {", range: taskStart.upperBound..<source.endIndex),
              let terminalEnd = source.range(of: "WorkflowRecoveryTelemetry.attempted(", range: terminalStart.upperBound..<source.endIndex),
              let timeoutStart = source.range(of: "private func scheduleConfigRecoveryTimeout(") else {
            assertTrue(false, "recovery must expose task and terminal ownership seams")
            return
        }
        let admission = String(source[attemptStart.upperBound..<taskStart.lowerBound])
        assertFalse(
            admission.contains("configChangeWasRecording = false"),
            "starting recovery must not consume intent before a second notification arrives with isRecording=false"
        )
        let terminal = String(source[terminalStart.upperBound..<terminalEnd.lowerBound])
        assertTrue(
            terminal.contains("if !self.recoveryState.isStale(generation: myGeneration) {\n                    self.configChangeWasRecording = false"),
            "only the terminating current task can release recording intent; stale tasks must leave newer recovery armed"
        )
        let timeout = String(source[timeoutStart.upperBound...])
        assertTrue(timeout.contains("self.configChangeWasRecording = false"), "terminal timeout must release restart intent rather than reanimate a failed session")
        assertFalse(source.contains("interruptRecordingAndClearRecoveredTimeline()"), "Bluetooth recovery failure must preserve audio recorded before the route changed")
        assertEqual(
            source.components(separatedBy: "interruptRecordingPreservingRecoveredTimeline()").count - 1,
            3,
            "snapshot failure, restart exhaustion, and timeout must all offer partial-audio recovery"
        )
    }

    runSuite("Device recovery waits for AUHAL binding and rejects stale snapshot commits") {
        let source = readSourceFixture("Sources/Speech/ParakeetDeviceRecovery.swift")
        guard let bindingCatch = source.range(of: "if error is DictationInputDeviceBindingError"),
              let rethrow = source.range(of: "throw error", range: bindingCatch.upperBound..<source.endIndex),
              let readySnapshot = source.range(of: "guard let snapshot = readySnapshot"),
              let rateCommit = source.range(of: "self.updateNativeSampleRate", range: readySnapshot.upperBound..<source.endIndex) else {
            assertTrue(false, "binding readiness and snapshot commit need explicit recovery gates")
            return
        }
        let waiting = String(source[bindingCatch.upperBound..<rethrow.lowerBound])
        assertTrue(waiting.contains("Task.sleep"), "binding retries must wait for hardware instead of spinning")
        assertTrue(waiting.contains("isStale(generation: myGeneration)"), "superseded binding waits must not keep retrying")
        assertTrue(waiting.contains("continue"), "binding failure must use bounded readiness polling rather than terminal graph replacement")
        let commitGuard = String(source[readySnapshot.upperBound..<rateCommit.lowerBound])
        assertTrue(commitGuard.contains("!Task.isCancelled"), "cancelled snapshots must not overwrite the recording rate")
        assertTrue(commitGuard.contains("isStale(generation: myGeneration)"), "an older route's rate must not overwrite the new graph after an await")
    }

    runSuite("Device recovery cannot rebuild a session cancelled by its interruption observer") {
        let source = readSourceFixture("Sources/Speech/ParakeetDeviceRecovery.swift")
        guard let timeoutStart = source.range(of: "private func scheduleConfigRecoveryTimeout("),
              let cancellationStart = source.range(of: "func cancelConfigRecoveryTimeout()"),
              let failureCallback = source.range(of: "if failureAction.markRecordingInterrupted {"),
              let failureRebuild = source.range(of: "switch ParakeetDeviceRecoveryFailurePolicy.rebuildStrategy(") else {
            assertTrue(false, "failure and timeout must have bounded ownership seams")
            return
        }
        let failureAfterPublication = String(source[failureCallback.upperBound..<failureRebuild.lowerBound])
        assertTrue(
            failureAfterPublication.contains("!self.recoveryState.isStale(generation: myGeneration) else { return }"),
            "the synchronous interruption observer may cancel the engine; a failed recovery must recheck before rebuilding"
        )
        let timeout = String(source[timeoutStart.upperBound..<cancellationStart.lowerBound])
        guard let owner = timeout.range(of: "let timeoutOwner = self.currentAudioEngineQueueOwnerToken()"),
              let publish = timeout.range(of: "self.publishRecoveryState()"),
              let interrupt = timeout.range(of: "self.interruptRecordingPreservingRecoveredTimeline()"),
              let ownerGuard = timeout.range(of: "guard self.ownsAudioEngineQueue(timeoutOwner) else { return }"),
              let rebuild = timeout.range(of: "switch timeoutAction.rebuildStrategy") else {
            assertTrue(false, "timeout must capture and recheck its original owner across callback publication")
            return
        }
        assertTrue(owner.lowerBound < publish.lowerBound, "timeout ownership must be captured before callbacks can replace the graph")
        assertTrue(interrupt.lowerBound < ownerGuard.lowerBound && ownerGuard.lowerBound < rebuild.lowerBound,
                   "timeout must reject a callback-superseded graph before abandoning it")
    }

    runSuite("ParakeetDeviceRecoveryReadinessPolicy — decision table over every readiness state") {
        let cases: [(readiness: ParakeetAudioFormatReadiness, expected: ParakeetDeviceRecoveryReadinessAction)] = [
            (.ready, .finishRecovery),
            (.invalid, .keepWaiting),
            (.routeNotSettled, .keepWaiting),
        ]
        for testCase in cases {
            assertEqual(
                ParakeetDeviceRecoveryReadinessPolicy.action(for: testCase.readiness),
                testCase.expected,
                "readiness \(testCase.readiness) should map to \(testCase.expected)"
            )
        }
    }

    runSuite("ParakeetRecordingRestartBudget — admits a post-settle Bluetooth restart and stays bounded") {
        let startedAt = 100.0
        var budget = ParakeetRecordingRestartBudget(startedAtUptime: startedAt)

        // The live failure produced four unavailable starts while the split
        // Bluetooth route moved from 24 kHz back to 48 kHz. The next attempt
        // must still be available once CoreAudio finishes settling.
        for expectedAttempt in 1...4 {
            assertEqual(
                budget.takeNextAttempt(nowUptime: startedAt + (Double(expectedAttempt - 1) * 0.5)),
                expectedAttempt,
                "the measured pre-settle attempt \(expectedAttempt) should stay inside the budget"
            )
        }
        assertEqual(
            budget.takeNextAttempt(nowUptime: startedAt + 2.0),
            5,
            "recovery must include the first post-settle attempt instead of aborting immediately before it"
        )

        for expectedAttempt in 6...TranscriptedConstants.recordingRestartAttempts {
            assertEqual(
                budget.takeNextAttempt(nowUptime: startedAt + (Double(expectedAttempt - 1) * 0.5)),
                expectedAttempt
            )
        }
        assertNil(
            budget.delayBeforeNextAttempt(nowUptime: startedAt + 3.5),
            "the terminal attempt must not add a dead retry delay"
        )
        assertNil(
            budget.takeNextAttempt(nowUptime: startedAt + 3.6),
            "recovery must stop after the bounded attempt count"
        )

        var expiredBudget = ParakeetRecordingRestartBudget(startedAtUptime: startedAt)
        assertNil(
            expiredBudget.takeNextAttempt(nowUptime: startedAt + TranscriptedConstants.recordingRestartAdmissionWindow),
            "the monotonic admission deadline must stop retries even when attempts remain"
        )

        var disabledBudget = ParakeetRecordingRestartBudget(maxAttempts: 0, startedAtUptime: startedAt)
        assertNil(
            disabledBudget.takeNextAttempt(nowUptime: startedAt),
            "a zero budget should make no attempts"
        )
    }

    runSuite("ParakeetDeviceRecoveryStartRetryPolicy — retries settling formats but not failed engine work") {
        assertTrue(
            ParakeetDeviceRecoveryStartRetryPolicy.shouldRetry(
                after: .audioRouteNotSettled,
                inputCanStartRecording: false
            ),
            "the measured split-route mismatch should receive another bounded probe"
        )
        assertTrue(
            ParakeetDeviceRecoveryStartRetryPolicy.shouldRetry(
                after: .invalidAudioFormat,
                inputCanStartRecording: false
            ),
            "a transient zero or invalid format should remain retryable"
        )
        assertTrue(
            ParakeetDeviceRecoveryStartRetryPolicy.shouldRetry(
                after: nil,
                inputCanStartRecording: false
            ),
            "a prewarm still settling between probes should remain retryable"
        )
        assertFalse(
            ParakeetDeviceRecoveryStartRetryPolicy.shouldRetry(
                after: .audioEngineStartFailed,
                inputCanStartRecording: false
            ),
            "a failed engine start already used its internal retry and must not multiply the outer budget"
        )
        assertFalse(
            ParakeetDeviceRecoveryStartRetryPolicy.shouldRetry(
                after: .audioEngineStartTimedOut,
                inputCanStartRecording: false
            ),
            "a timed-out CoreAudio start must not multiply the outer budget"
        )
        assertFalse(
            ParakeetDeviceRecoveryStartRetryPolicy.shouldRetry(
                after: nil,
                inputCanStartRecording: true
            ),
            "a non-route failure with a ready input should stop immediately"
        )
    }

    runSuite("ParakeetDeviceRecoveryFailurePolicy.action — decision table over wasRecording") {
        let cases: [(wasRecording: Bool, expected: ParakeetDeviceRecoveryFailureAction)] = [
            (
                false,
                ParakeetDeviceRecoveryFailureAction(
                    reportSentryFailure: false,
                    markRecordingInterrupted: false,
                    schedulePrewarmRetry: true
                )
            ),
            (
                true,
                ParakeetDeviceRecoveryFailureAction(
                    reportSentryFailure: true,
                    markRecordingInterrupted: true,
                    schedulePrewarmRetry: true
                )
            ),
        ]
        for testCase in cases {
            assertEqual(
                ParakeetDeviceRecoveryFailurePolicy.action(wasRecording: testCase.wasRecording),
                testCase.expected,
                "wasRecording=\(testCase.wasRecording) should produce \(testCase.expected)"
            )
        }
    }

    runSuite("ParakeetDeviceRecoveryFailurePolicy.rebuildStrategy — decision table over queue-blocked state") {
        let cases: [(audioEngineQueueBlocked: Bool, expected: ParakeetAudioEngineRebuildStrategy)] = [
            (true, .abandonBlockedAudioGraph),
            (false, .queuedOnAudioEngineQueue),
        ]
        for testCase in cases {
            assertEqual(
                ParakeetDeviceRecoveryFailurePolicy.rebuildStrategy(audioEngineQueueBlocked: testCase.audioEngineQueueBlocked),
                testCase.expected,
                "audioEngineQueueBlocked=\(testCase.audioEngineQueueBlocked) should rebuild via \(testCase.expected)"
            )
        }
    }

    runSuite("ParakeetDeviceRecoveryTimeoutPolicy.action — always abandons the blocked graph, failure action tracks wasRecording") {
        let cases: [(wasRecording: Bool, expectedFailure: ParakeetDeviceRecoveryFailureAction)] = [
            (
                false,
                ParakeetDeviceRecoveryFailureAction(
                    reportSentryFailure: false,
                    markRecordingInterrupted: false,
                    schedulePrewarmRetry: true
                )
            ),
            (
                true,
                ParakeetDeviceRecoveryFailureAction(
                    reportSentryFailure: true,
                    markRecordingInterrupted: true,
                    schedulePrewarmRetry: true
                )
            ),
        ]
        for testCase in cases {
            let action = ParakeetDeviceRecoveryTimeoutPolicy.action(wasRecording: testCase.wasRecording)
            assertEqual(
                action.failureAction,
                testCase.expectedFailure,
                "timeout failure action for wasRecording=\(testCase.wasRecording) should match the failure-policy table"
            )
            assertEqual(
                action.rebuildStrategy,
                .abandonBlockedAudioGraph,
                "a device-recovery timeout always means the engine queue is presumed wedged, so it always abandons the graph"
            )
        }
    }

    runSuite("ParakeetDeviceRecoveryTimeoutPolicy — failure action mirrors ParakeetDeviceRecoveryFailurePolicy directly") {
        // The timeout path intentionally reuses the failure policy rather than
        // re-deriving its own rules — pin that composition so the two can't
        // silently drift apart.
        for wasRecording in [false, true] {
            assertEqual(
                ParakeetDeviceRecoveryTimeoutPolicy.action(wasRecording: wasRecording).failureAction,
                ParakeetDeviceRecoveryFailurePolicy.action(wasRecording: wasRecording),
                "timeout failure action should equal the shared failure policy for wasRecording=\(wasRecording)"
            )
        }
    }

    runSuite("ParakeetConfigChangeGraphPolicy — a late stable engine echo reuses the current graph") {
        let bluetooth = ParakeetCategoricalAudioRoute(
            inputDeviceClass: "built_in",
            outputDeviceClass: "bluetooth",
            routeShape: "built_in_input_to_bluetooth_output"
        )
        let builtIn = ParakeetCategoricalAudioRoute(
            inputDeviceClass: "built_in",
            outputDeviceClass: "built_in",
            routeShape: "built_in_input_to_built_in_output"
        )
        var routeState = ParakeetRouteTransitionDebounceState()
        routeState.seedStableRouteIfNeeded(bluetooth)

        // Model the observed sequence deterministically: one real Bluetooth
        // disconnect commits the built-in route, recording restarts and proves
        // sample flow, then the retired engine posts a same-route notification.
        routeState.observe(builtIn)
        assertEqual(routeState.commitPendingRoute(), builtIn, "the real disconnect should commit its new stable route")
        let stableIdentity = routeIdentity(defaultInputID: 80, selectedInputID: 80, outputID: 73)
        assertEqual(
            ParakeetConfigChangeGraphPolicy.strategy(
                source: .audioEngine,
                wasRecording: true,
                hadSampleFlow: true,
                inputWasReady: true,
                stableRouteIdentity: stableIdentity,
                observedRouteIdentity: stableIdentity
            ),
            .reuseCurrentGraph,
            "a late same-route engine echo must not retire another audio engine"
        )

        let defaultInputChurnIdentity = routeIdentity(
            defaultInputID: 81,
            selectedInputID: 80,
            outputID: 73,
            reason: .preferredBuiltInForBluetoothHeadset
        )
        assertEqual(
            ParakeetConfigChangeGraphPolicy.strategy(
                source: .defaultInputDevice,
                wasRecording: true,
                hadSampleFlow: true,
                inputWasReady: true,
                stableRouteIdentity: stableIdentity,
                observedRouteIdentity: defaultInputChurnIdentity
            ),
            .reuseCurrentGraph,
            "default-input churn must not replace a graph whose exact selected mic and output are unchanged"
        )
    }

    runSuite("ParakeetConfigChangeGraphPolicy — real or unproven route changes still rebuild") {
        let stableIdentity = routeIdentity(defaultInputID: 80, selectedInputID: 80, outputID: 73)
        let differentSameClassIdentity = routeIdentity(defaultInputID: 81, selectedInputID: 81, outputID: 74)
        let cases: [(source: ParakeetConfigChangeSource, recording: Bool, samples: Bool, ready: Bool, observed: ParakeetAudioRouteIdentity?)] = [
            (.audioEngine, true, true, true, differentSameClassIdentity),
            (.audioEngine, true, false, true, stableIdentity),
            (.audioEngine, true, true, false, stableIdentity),
            (.audioEngine, false, true, true, stableIdentity),
            (.audioEngine, true, true, true, nil),
        ]

        for testCase in cases {
            assertEqual(
                ParakeetConfigChangeGraphPolicy.strategy(
                    source: testCase.source,
                    wasRecording: testCase.recording,
                    hadSampleFlow: testCase.samples,
                    inputWasReady: testCase.ready,
                    stableRouteIdentity: stableIdentity,
                    observedRouteIdentity: testCase.observed
                ),
                .rebuildGraph,
                "changed endpoints, idle graphs, or unproven routes must retain the full recovery path"
            )
        }
    }

    runSuite("ParakeetConfigChangeContinuityPolicy ignores only proven live same-route notifications") {
        assertTrue(
            ParakeetConfigChangeContinuityPolicy.shouldProbe(
                wasRecording: true,
                hadSampleFlow: true,
                inputWasReady: true,
                graphEndpointsMatch: true
            ),
            "an active proven graph should get a short continuity probe before teardown"
        )
        assertTrue(
            ParakeetConfigChangeContinuityPolicy.shouldIgnoreAfterProbe(
                wasRecording: true,
                inputWasReady: true,
                graphEndpointsMatch: true,
                sampleArrivedAfterNotification: true
            ),
            "fresh post-notification samples prove the graph never stopped"
        )

        let unsafeCases: [(recording: Bool, ready: Bool, sameRoute: Bool, freshSample: Bool)] = [
            (false, true, true, true),
            (true, false, true, true),
            (true, true, false, true),
            (true, true, true, false),
        ]
        for testCase in unsafeCases {
            assertFalse(
                ParakeetConfigChangeContinuityPolicy.shouldIgnoreAfterProbe(
                    wasRecording: testCase.recording,
                    inputWasReady: testCase.ready,
                    graphEndpointsMatch: testCase.sameRoute,
                    sampleArrivedAfterNotification: testCase.freshSample
                ),
                "stopped, unready, changed-route, or sample-stalled graphs must still recover"
            )
        }
    }
}
