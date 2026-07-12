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
}
