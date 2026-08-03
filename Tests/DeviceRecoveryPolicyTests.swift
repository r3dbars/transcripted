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
    }

    runSuite("ParakeetConfigChangeGraphPolicy — real or unproven route changes still rebuild") {
        let stableIdentity = routeIdentity(defaultInputID: 80, selectedInputID: 80, outputID: 73)
        let differentSameClassIdentity = routeIdentity(defaultInputID: 81, selectedInputID: 81, outputID: 74)
        let cases: [(source: ParakeetConfigChangeSource, recording: Bool, samples: Bool, ready: Bool, observed: ParakeetAudioRouteIdentity?)] = [
            (.defaultInputDevice, true, true, true, stableIdentity),
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
                "changed identities, explicit input events, idle graphs, or unproven routes must retain the full recovery path"
            )
        }
    }
}
