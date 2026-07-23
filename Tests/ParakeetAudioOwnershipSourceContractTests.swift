// ParakeetAudioOwnershipSourceContractTests.swift
//
// Source-text contracts for delayed CoreAudio cleanup. The pure ownership and
// interleaving policies have behavioral coverage in the focused graph-ownership
// and recovery-state suites.

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

    runSuite("ParakeetEngine cancelled recovery starts are gated and cleaned on the retired worker") {
        let source = readParakeetEngineSource()
        guard let timedWorkStart = source.range(of: "private func runTimedAudioEngineWork<T>("),
              let timedWorkEnd = source.range(of: "private static func elapsedMilliseconds", range: timedWorkStart.upperBound..<source.endIndex),
              let installStart = source.range(of: "private func installTapAndStartEngine("),
              let installEnd = source.range(of: "func removeRecordingTap", range: installStart.upperBound..<source.endIndex),
              let abandonStart = source.range(of: "func abandonBlockedAudioEngine("),
              let abandonEnd = source.range(of: "private func handleSystemWake() async", range: abandonStart.upperBound..<source.endIndex) else {
            assertTrue(false, "test should find timed start and blocked-graph cleanup helpers")
            return
        }

        let timedWork = String(source[timedWorkStart.lowerBound..<timedWorkEnd.lowerBound])
        let install = String(source[installStart.lowerBound..<installEnd.lowerBound])
        let abandon = String(source[abandonStart.lowerBound..<abandonEnd.lowerBound])

        assertTrue(
            timedWork.contains("guard isWorkCurrent?() != false")
                && timedWork.contains("cleanupAfterCancellation?(engine)"),
            "timed work should skip a claimed queued lease and clean in-flight cancellation on its own worker"
        )
        assertTrue(
            install.contains("isWorkCurrent: recoveryWorkIsCurrent")
                && install.contains("phase: .zombieRecoveryStart")
                && install.contains("guard recoveryWorkIsCurrent() else { throw CancellationError() }")
                && install.contains("recoveryCancellationState.canDeliverSamples")
                && install.contains("try audioEngine.start()"),
            "recovery start should validate its lease at entry, tap delivery, and around engine start"
        )
        assertTrue(
            source.contains("!zombieStartCancellationState.commit()")
                && source.contains("zombieRecoveryStartCancellationState?.cancel()"),
            "a successful recovery should commit callback delivery while stop cancels it immediately"
        )
        assertTrue(
            abandon.contains("let retiredQueue = audioEngineQueue")
                && abandon.contains("retiredQueue.async")
                && abandon.contains("Self.cleanUpLateAudioStart(on: retiredEngine)"),
            "blocked graph abandonment should queue cleanup behind any in-flight retired work"
        )
    }

    runSuite("ParakeetEngine system-input reconciliation is finite and checks CoreAudio results") {
        let source = readParakeetEngineSource()
        guard let performStart = source.range(of: "private func performSystemInputReconciliation("),
              let lateHandlerStart = source.range(of: "private func handleLateSystemInputReconciliationCompletion(", range: performStart.upperBound..<source.endIndex),
              let lateHandlerEnd = source.range(of: "private func schedulePendingSystemInputRestore", range: lateHandlerStart.upperBound..<source.endIndex),
              let drainStart = source.range(of: "private func drainSystemInputReconciliations()"),
              let drainEnd = source.range(of: "private func performSystemInputReconciliation", range: drainStart.upperBound..<source.endIndex) else {
            assertTrue(false, "test should find the system-input reconciliation helpers")
            return
        }

        let perform = String(source[performStart.lowerBound..<lateHandlerStart.lowerBound])
        let lateHandler = String(source[lateHandlerStart.lowerBound..<lateHandlerEnd.lowerBound])
        let drain = String(source[drainStart.lowerBound..<drainEnd.lowerBound])

        assertTrue(
            perform.contains("guard applyError == nil")
                && perform.contains("guard restoreError == nil"),
            "CoreAudio error strings must not be treated as successful route convergence"
        )
        assertTrue(
            perform.contains("handleLateSystemInputReconciliationCompletion")
                && !perform.contains("await self?.reconcileSystemInputAfterLateCompletion"),
            "timed-out reconciliation should classify late completion instead of recursively starting fresh work"
        )
        assertTrue(
            lateHandler.contains("guard coreAudioError == nil")
                && lateHandler.contains("pendingSystemInputRestore.owner == intendedOwner")
                && lateHandler.contains("else if !pendingSystemInputRestore.hasPendingValue")
                && lateHandler.contains("await reconcileSystemInputAfterLateCompletion"),
            "late completion should request another bounded pass only when MainActor intent changed"
        )
        assertTrue(
            drain.contains("while !pendingSystemInputReconciliations.isEmpty")
                && drain.contains("systemInputReconciliationTask = nil"),
            "reconciliation requests should drain through one coalescing MainActor task"
        )
    }
}
