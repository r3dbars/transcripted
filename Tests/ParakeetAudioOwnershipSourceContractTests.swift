// ParakeetAudioOwnershipSourceContractTests.swift
//
// Source-text contracts for delayed CoreAudio cleanup. The pure ownership and
// interleaving policies have behavioral coverage in ParakeetRecoveryStateTests.

import Foundation

func testParakeetAudioOwnershipSourceContract() {
    runSuite("ParakeetEngine delayed cleanup mutates only its exact graph owner") {
        let source = readParakeetEngineSource()
        guard let removeTapStart = source.range(of: "func removeRecordingTap(force: Bool = false) async"),
              let removeTapEnd = source.range(of: "/// Share the user-consented", range: removeTapStart.upperBound..<source.endIndex),
              let startFailureStart = source.range(of: "private func resetAudioGraphAfterStartFailure("),
              let startFailureEnd = source.range(of: "/// Tracks rebuild frequency", range: startFailureStart.upperBound..<source.endIndex),
              let rebuildStart = source.range(of: "func rebuildAudioEngine(reason: String) async"),
              let rebuildEnd = source.range(of: "func abandonBlockedAudioEngine", range: rebuildStart.upperBound..<source.endIndex),
              let failedStartCleanupStart = source.range(of: "func resetAfterFailedRecordingStart() async"),
              let failedStartCleanupEnd = source.range(of: "func abandonBlockedRecordingStart", range: failedStartCleanupStart.upperBound..<source.endIndex),
              let idleCleanupStart = source.range(of: "private func releaseIdleAudioHardware("),
              let idleCleanupEnd = source.range(of: "private func cancelAudioWatchdogForRecordingStart()", range: idleCleanupStart.upperBound..<source.endIndex) else {
            assertTrue(false, "test should find the delayed audio cleanup helpers")
            return
        }

        let removeTap = String(source[removeTapStart.lowerBound..<removeTapEnd.lowerBound])
        let startFailure = String(source[startFailureStart.lowerBound..<startFailureEnd.lowerBound])
        let rebuild = String(source[rebuildStart.lowerBound..<rebuildEnd.lowerBound])
        let failedStartCleanup = String(source[failedStartCleanupStart.lowerBound..<failedStartCleanupEnd.lowerBound])
        let idleCleanup = String(source[idleCleanupStart.lowerBound..<idleCleanupEnd.lowerBound])

        assertPostAwaitOwnershipGuard(
            in: removeTap,
            ownerCapture: "let tapOwner = currentAudioGraphOwnerToken()",
            suspension: "await runAudioEngineWork",
            guardStatement: "guard ownsAudioGraph(tapOwner) else { return }",
            mutation: "inputTapInstalled = false",
            helper: "removeRecordingTap"
        )
        assertPostAwaitOwnershipGuard(
            in: startFailure,
            ownerCapture: "let resetOwner = currentAudioGraphOwnerToken()",
            suspension: "await runAudioEngineWork",
            guardStatement: "guard ownsAudioGraph(resetOwner) else { return nil }",
            mutation: "inputTapInstalled = false",
            helper: "resetAudioGraphAfterStartFailure"
        )
        assertPostAwaitOwnershipGuard(
            in: rebuild,
            ownerCapture: "let rebuildOwner = currentAudioGraphOwnerToken()",
            suspension: "await runAudioEngineWork",
            guardStatement: "guard ownsAudioGraph(rebuildOwner) else { return nil }",
            mutation: "audioEngine = AVAudioEngine()",
            helper: "rebuildAudioEngine"
        )
        assertTrue(
            failedStartCleanup.contains("let failedStartCleanupOwner = currentAudioEngineQueueOwnerToken()")
                && failedStartCleanup.contains("guard ownsAudioEngineQueue(failedStartCleanupOwner) else { return }"),
            "resetAfterFailedRecordingStart should retain exact cleanup ownership without obsolete streaming work"
        )
        assertPostAwaitOwnershipGuard(
            in: idleCleanup,
            ownerCapture: "let idleCleanupOwner = currentAudioEngineQueueOwnerToken()",
            suspension: "await removeRecordingTap(force: true)",
            guardStatement: "guard ownsAudioEngineQueue(idleCleanupOwner) else { return nil }",
            mutation: "await stopAudioEngine()",
            helper: "releaseIdleAudioHardware remove-tap completion"
        )

        guard let stopSuspension = idleCleanup.range(of: "await stopAudioEngine()"),
              let postStopGuard = idleCleanup.range(
                of: "guard ownsAudioEngineQueue(idleCleanupOwner) else { return nil }",
                range: stopSuspension.upperBound..<idleCleanup.endIndex
              ),
              let clearPrewarm = idleCleanup.range(of: "isEnginePrewarmed = false", range: postStopGuard.upperBound..<idleCleanup.endIndex) else {
            assertTrue(false, "releaseIdleAudioHardware should revalidate ownership after stopping the engine")
            return
        }
        assertTrue(
            stopSuspension.lowerBound < postStopGuard.lowerBound && postStopGuard.lowerBound < clearPrewarm.lowerBound,
            "releaseIdleAudioHardware must preserve a newer owner's prewarm state after delayed stop completion"
        )
    }
}
