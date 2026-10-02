// ParakeetAudioOwnershipSourceContractTests.swift
//
// Source-text contracts for the start path's timed-work lease. Delayed
// cleanup ownership, graph replacement, zombie cancellation, the stop and
// route-change orderings, and the recovery snapshot lease are behavior tests
// now (ParakeetAudioGraphTests.swift). What is left runs inside
// ParakeetEngine.startRecording and the AVAudioEngine tap closure, which the
// fast runner can't compile: start isn't behind the audio-graph seam yet.

import Foundation

func testParakeetAudioOwnershipSourceContract() {
    runSuite("ParakeetEngine cancelled starts are gated by their exact lease") {
        let source = readParakeetEngineSource()
        guard let installStart = source.range(of: "func installTapAndStartEngine("),
              let installEnd = source.range(of: "/// Share the user-consented", range: installStart.upperBound..<source.endIndex) else {
            assertTrue(false, "test should find the tap install and engine start")
            return
        }

        let install = String(source[installStart.lowerBound..<installEnd.lowerBound])

        assertTrue(
            install.contains("isWorkCurrent: startWorkIsCurrent")
                && install.contains("phase: .audioStart")
                && install.contains("guard startWorkIsCurrent() else { throw CancellationError() }")
                && install.contains("startCancellationState.canDeliverSamples")
                && install.contains("try audioEngine.start()"),
            "every start should validate its lease at entry, tap delivery, and around engine start"
        )
        assertTrue(
            source.contains("!startCancellationState.commit()")
                && source.contains("audioStartCancellationState?.cancel()"),
            "a successful start should commit callback delivery while stop cancels it immediately"
        )
        assertTrue(
            source.contains("let startCancellationState = ParakeetAudioStartCancellationState()")
                && source.contains("audioEngineWorkOwnership.begin(owner: attemptOwner, phase: .audioStart)"),
            "normal and recovery starts should share the same replaceable timed-work lease"
        )
        guard let recordingStart = source.range(of: "func startRecording(isRecoveryAttempt: Bool = false) async -> Bool"),
              let recordingEnd = source.range(
                of: "private func cancelAudioWatchdogForRecordingStart()",
                range: recordingStart.upperBound..<source.endIndex
              ) else {
            assertTrue(false, "test should find the recording start body")
            return
        }
        let recording = String(source[recordingStart.lowerBound..<recordingEnd.lowerBound])
        guard let snapshotState = recording.range(of: "let snapshotCancellationState = ParakeetAudioStartCancellationState()"),
              let snapshotLease = recording.range(
                of: "audioEngineWorkOwnership.begin(owner: attemptOwner, phase: .audioStart)",
                range: snapshotState.upperBound..<recording.endIndex
              ),
              let snapshotRead = recording.range(
                of: "snapshot = try await audioInputSnapshot(",
                range: snapshotLease.upperBound..<recording.endIndex
              ),
              let finishSnapshotLease = recording.range(
                of: "finishSnapshotLease()",
                range: snapshotRead.upperBound..<recording.endIndex
              ) else {
            assertTrue(false, "the start snapshot should be inside a replaceable lease")
            return
        }
        assertTrue(
            snapshotLease.lowerBound < snapshotRead.lowerBound
                && snapshotRead.lowerBound < finishSnapshotLease.lowerBound,
            "the lease must cover pre-tap format reads so stop can replace a blocked queue"
        )
        assertTrue(
            recording.contains("isEngineWorkCurrent: snapshotWorkIsCurrent"),
            "queued or late snapshot work should observe cancellation before touching the retired engine"
        )
    }
}
