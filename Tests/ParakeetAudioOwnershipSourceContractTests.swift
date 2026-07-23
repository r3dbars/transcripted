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
              let zombieResetStart = source.range(of: "private func recreateAudioEngineForZombieRecovery("),
              let zombieResetEnd = source.range(of: "func currentAudioGraphOwnerToken()", range: zombieResetStart.upperBound..<source.endIndex),
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
        let zombieReset = String(source[zombieResetStart.lowerBound..<zombieResetEnd.lowerBound])
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
        guard let resetLease = startFailure.range(
                  of: "audioEngineWorkOwnership.begin(owner: resetWorkOwner, phase: .audioStart)"
              ),
              let rebuildCall = startFailure.range(
                  of: "return await rebuildAudioEngine(reason: reason)",
                  range: resetLease.upperBound..<startFailure.endIndex
              ) else {
            assertTrue(false, "failed-start reset should lease its engine and queue before rebuilding")
            return
        }
        assertTrue(
            resetLease.lowerBound < rebuildCall.lowerBound
                && startFailure.contains("audioEngineWorkOwnership.finish(owner: resetWorkOwner, phase: .audioStart)"),
            "failed-start reset must remain claimable by stop across blocked CoreAudio cleanup"
        )
        assertFalse(
            startFailure.contains("ParakeetAudioStartCancellationState()"),
            "failed-start reset should use its exact ownership lease instead of an unread cancellation signal"
        )
        assertPostAwaitOwnershipGuard(
            in: rebuild,
            ownerCapture: "let rebuildOwner = currentAudioGraphOwnerToken()",
            suspension: "await runAudioEngineWork",
            guardStatement: "guard ownsAudioGraph(rebuildOwner) else {",
            mutation: "audioEngine = AVAudioEngine()",
            helper: "rebuildAudioEngine"
        )
        assertTrue(
            rebuild.contains("defer {\n            restoreAudioEngineConfigObserverIfCurrent(rebuildOwner)\n        }")
                && rebuild.contains("removeAudioEngineConfigObserver()\n        audioEngine = AVAudioEngine()"),
            "rebuild should restore a stale same-engine observer and clear it before binding a replacement"
        )
        assertTrue(
            zombieReset.contains("defer {\n            restoreAudioEngineConfigObserverIfCurrent(resetOwner)\n        }")
                && zombieReset.contains("removeAudioEngineConfigObserver()\n        audioEngine = AVAudioEngine()"),
            "zombie reset should restore observers on every stale exit and rebind successful replacements"
        )
        assertTrue(
            failedStartCleanup.contains("let failedStartCleanupOwner = currentAudioEngineQueueOwnerToken()")
                && failedStartCleanup.contains("guard ownsAudioEngineQueue(failedStartCleanupOwner) else { return }"),
            "resetAfterFailedRecordingStart should retain exact cleanup ownership without obsolete streaming work"
        )
        guard let failedRelease = failedStartCleanup.range(of: "_ = await releaseIdleAudioHardware("),
              let failedRestore = failedStartCleanup.range(
                of: "await restorePendingSystemInputAfterRecording(",
                range: failedRelease.upperBound..<failedStartCleanup.endIndex
              ) else {
            assertTrue(false, "failed-start cleanup should restore its captured system-input owner after graph release")
            return
        }
        assertTrue(
            failedRelease.lowerBound < failedRestore.lowerBound,
            "graph ownership loss must not skip the independent owner-bound input restore"
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

        guard let stopRecordingStart = source.range(of: "func stopRecording() async"),
              let stopRecordingEnd = source.range(
                of: "// MARK: - Recorded Audio Buffering",
                range: stopRecordingStart.upperBound..<source.endIndex
              ) else {
            assertTrue(false, "test should find stopRecording")
            return
        }
        let stopRecording = String(source[stopRecordingStart.lowerBound..<stopRecordingEnd.lowerBound])
        guard let stopEngine = stopRecording.range(of: "await stopAudioEngine()"),
              let restoreInput = stopRecording.range(
                of: "await restorePendingSystemInputAfterRecording(",
                range: stopEngine.upperBound..<stopRecording.endIndex
              ),
              let finalOwnershipGuard = stopRecording.range(
                of: "guard stillOwnsStopGraph, ownsAudioEngineQueue(stopOwner) else { return }",
                range: restoreInput.upperBound..<stopRecording.endIndex
              ) else {
            assertTrue(false, "normal stop should restore its captured input owner before its final graph guard")
            return
        }
        assertTrue(
            stopEngine.lowerBound < restoreInput.lowerBound
                && restoreInput.lowerBound < finalOwnershipGuard.lowerBound,
            "graph loss during stop must not bypass matching system-input restoration"
        )
    }

    runSuite("ParakeetEngine blocked-start timeout replaces the graph once") {
        let source = readParakeetEngineSource()
        guard let abandonStart = source.range(of: "func abandonBlockedRecordingStart(reason: String)"),
              let abandonEnd = source.range(of: "func cancel()", range: abandonStart.upperBound..<source.endIndex) else {
            assertTrue(false, "test should find blocked-start abandonment")
            return
        }
        let abandon = String(source[abandonStart.lowerBound..<abandonEnd.lowerBound])
        assertTrue(
            abandon.contains("let didReplaceBlockedGraph = cancelAudioWatchdog()")
                && abandon.contains("if !didReplaceBlockedGraph {\n            abandonBlockedAudioEngine(reason: reason)\n        }"),
            "blocked-start timeout should skip its fallback when watchdog cancellation already replaced the graph"
        )
    }

    runSuite("ParakeetEngine cancelled starts are gated and cleaned on the retired worker") {
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
                of: "/// Begin dictation by borrowing",
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
        guard let idleStopStart = source.range(of: "if audioStartInProgress {"),
              let idleStopEnd = source.range(
                of: "await restorePendingSystemInputAfterRecording(",
                range: idleStopStart.upperBound..<source.endIndex
              ) else {
            assertTrue(false, "test should find idle stop cancellation")
            return
        }
        let idleStop = String(source[idleStopStart.lowerBound..<idleStopEnd.lowerBound])
        guard let cancelTimedStart = idleStop.range(of: "cancelAudioWatchdog()"),
              let cancelAdmission = idleStop.range(of: "audioStartAdmission.cancel()") else {
            assertTrue(false, "idle stop should cancel timed start work and admission")
            return
        }
        assertTrue(
            cancelTimedStart.lowerBound < cancelAdmission.lowerBound,
            "idle stop must retire blocked engine work before releasing start admission"
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
