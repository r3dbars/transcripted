// ParakeetAudioOwnershipSourceContractTests.swift
//
// Source-text contracts for delayed CoreAudio cleanup. The pure ownership and
// interleaving policies have behavioral coverage in the focused graph-ownership
// and recovery-state suites. The timed engine-work runner, the single-flight
// stop, and system-input reconciliation moved to behavior tests in
// ParakeetEngineWorkLifecycleTests.swift. What is left here waits on an
// audio-graph driver seam for ParakeetEngine (see
// docs/testing-source-text-inventory.md).

import Foundation

func testParakeetAudioOwnershipSourceContract() {
    runSuite("ParakeetEngine delayed cleanup mutates only its exact graph owner") {
        let source = readParakeetEngineSource()
        let zombieSource = readParakeetZombieRecoverySource()
        guard let removeTapStart = source.range(of: "func removeRecordingTap(force: Bool = false) async"),
              let removeTapEnd = source.range(of: "func stopAudioEngine() async", range: removeTapStart.upperBound..<source.endIndex),
              let startFailureStart = source.range(of: "private func resetAudioGraphAfterStartFailure("),
              let startFailureEnd = source.range(of: "private func audioStartContext(", range: startFailureStart.upperBound..<source.endIndex),
              let rebuildStart = source.range(of: "func rebuildAudioEngine("),
              let rebuildEnd = source.range(of: "func abandonBlockedAudioEngine", range: rebuildStart.upperBound..<source.endIndex),
              let zombieResetStart = zombieSource.range(of: "private func recreateAudioEngineForZombieRecovery("),
              let zombieResetEnd = zombieSource.range(of: "private func canContinueZombieEngineRecovery(", range: zombieResetStart.upperBound..<zombieSource.endIndex),
              let failedStartCleanupStart = source.range(of: "func resetAfterFailedRecordingStart() async"),
              let failedStartCleanupEnd = source.range(of: "func abandonBlockedRecordingStart", range: failedStartCleanupStart.upperBound..<source.endIndex),
              let idleCleanupStart = source.range(of: "func releaseIdleAudioHardware("),
              let idleCleanupEnd = source.range(of: "\n}\n", range: idleCleanupStart.upperBound..<source.endIndex) else {
            assertTrue(false, "test should find the delayed audio cleanup helpers")
            return
        }

        let removeTap = String(source[removeTapStart.lowerBound..<removeTapEnd.lowerBound])
        let startFailure = String(source[startFailureStart.lowerBound..<startFailureEnd.lowerBound])
        let rebuild = String(source[rebuildStart.lowerBound..<rebuildEnd.lowerBound])
        let zombieReset = String(zombieSource[zombieResetStart.lowerBound..<zombieResetEnd.lowerBound])
        // Timed zombie reset publishes its lease before it can suspend and
        // retires only that exact lease (moved here from the old watchdog suite).
        if let beginLease = zombieReset.range(of: "audioEngineWorkOwnership.begin(owner: resetQueueOwner, phase: .zombieReset)"),
           let timedReset = zombieReset.range(of: "runTimedAudioEngineWork(operation: \"zombie_engine_reset\")", range: beginLease.upperBound..<zombieReset.endIndex),
           let finishLease = zombieReset.range(of: "audioEngineWorkOwnership.finish(", range: timedReset.upperBound..<zombieReset.endIndex) {
            assertTrue(beginLease.upperBound <= timedReset.lowerBound && timedReset.upperBound <= finishLease.lowerBound, "zombie reset should begin, run, then finish its exact lease")
        } else {
            assertTrue(false, "zombie reset should begin its .zombieReset lease before the timed reset and finish it after")
        }
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
                && rebuild.contains("removeAudioEngineConfigObserver()")
                && rebuild.contains("let didReserveRetiredEngine = reserveRetiredAudioEngine(")
                && rebuild.contains("if didReserveRetiredEngine {\n            audioEngine = AVAudioEngine()\n        }")
                && rebuild.contains("guard didReserveRetiredEngine else {"),
            "rebuild should restore stale observers and replace the engine only when bounded retirement succeeds"
        )
        assertTrue(
            zombieReset.contains("defer {\n            restoreAudioEngineConfigObserverIfCurrent(resetOwner)\n        }")
                && zombieReset.contains("removeAudioEngineConfigObserver()")
                && zombieReset.contains("let didReserveRetiredEngine = reserveRetiredAudioEngine(")
                && zombieReset.contains("guard didReserveRetiredEngine else {")
                && zombieReset.contains("\"PARAKEET | zombie audio graph replacement refused because retirement limit is full\"")
                && zombieReset.contains("interruptRecordingPreservingRecoveredTimeline()\n            return false")
                && zombieReset.contains("return false\n        }\n        audioEngine = AVAudioEngine()"),
            "zombie reset should fail closed at the retirement limit, surface interruption, and never reuse a detected zombie graph"
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
                of: "private func cancelPendingRecordingRecovery()",
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
        guard let installStart = source.range(of: "func installTapAndStartEngine("),
              let installEnd = source.range(of: "/// Share the user-consented", range: installStart.upperBound..<source.endIndex),
              let abandonStart = source.range(of: "func abandonBlockedAudioEngine("),
              let abandonEnd = source.range(of: "func reserveRetiredAudioEngine(", range: abandonStart.upperBound..<source.endIndex) else {
            assertTrue(false, "test should find start and blocked-graph cleanup helpers")
            return
        }

        let install = String(source[installStart.lowerBound..<installEnd.lowerBound])
        let abandon = String(source[abandonStart.lowerBound..<abandonEnd.lowerBound])

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
        guard let stopStart = source.range(of: "func stopRecording() async"),
              let idleStopStart = source.range(of: "if audioStartInProgress {", range: stopStart.upperBound..<source.endIndex),
              let idleStopEnd = source.range(
                of: "await restorePendingSystemInputAfterRecording(",
                range: idleStopStart.upperBound..<source.endIndex
              ) else {
            assertTrue(false, "test should find idle stop cancellation")
            return
        }
        let stopBeforeIdle = String(source[stopStart.lowerBound..<idleStopStart.lowerBound])
        let idleStop = String(source[idleStopStart.lowerBound..<idleStopEnd.lowerBound])
        guard stopBeforeIdle.contains("cancelAudioWatchdog()"),
              idleStop.contains("audioStartAdmission.cancel()") else {
            assertTrue(false, "idle stop should cancel timed start work and admission")
            return
        }
        assertTrue(
            abandon.contains("let retiredQueue = audioEngineQueue")
                && abandon.contains("retiredQueue.async")
                && abandon.contains("Self.cleanUpLateAudioStart(on: retiredEngine)"),
            "blocked graph abandonment should queue cleanup behind any in-flight retired work"
        )
    }

    runSuite("ParakeetEngine stop consumes matching config recovery before any suspension") {
        let engineSource = readParakeetEngineSource()
        let recoverySource = readParakeetDeviceRecoverySource()
        guard let stopStart = engineSource.range(of: "func stopRecording() async"),
              let stopEnd = engineSource.range(
                of: "private func cancelPendingRecordingRecovery()",
                range: stopStart.upperBound..<engineSource.endIndex
              ),
              let handlerStart = recoverySource.range(of: "private func handleAudioConfigChange("),
              let handlerEnd = recoverySource.range(
                of: "private func recordStableRouteChangeAnalytics",
                range: handlerStart.upperBound..<recoverySource.endIndex
              ) else {
            assertTrue(false, "test should find stop and config-recovery bodies")
            return
        }

        let stopBody = String(engineSource[stopStart.lowerBound..<stopEnd.lowerBound])
        let handlerBody = String(recoverySource[handlerStart.lowerBound..<handlerEnd.lowerBound])
        guard let generationCapture = stopBody.range(of: "let configRecoveryGeneration = recoveryState.isRecovering"),
              let graphInvalidation = stopBody.range(of: "audioGraphGeneration += 1", range: generationCapture.upperBound..<stopBody.endIndex),
              let cancelRecovery = stopBody.range(
                of: "cancelConfigRecoveryIfCurrent(generation: configRecoveryGeneration)",
                range: graphInvalidation.upperBound..<stopBody.endIndex
              ),
              let recordingBranch = stopBody.range(of: "guard isRecording else", range: cancelRecovery.upperBound..<stopBody.endIndex),
              let firstStopAwait = stopBody.range(of: "await ", range: cancelRecovery.upperBound..<stopBody.endIndex) else {
            assertTrue(false, "stop should synchronously invalidate and cancel config recovery before choosing active or idle cleanup")
            return
        }

        let stopCancellationWindow = String(stopBody[generationCapture.lowerBound..<cancelRecovery.upperBound])
        assertTrue(graphInvalidation.lowerBound < cancelRecovery.lowerBound, "stop must retire the audio graph before cancelling its recovery")
        assertTrue(cancelRecovery.lowerBound < recordingBranch.lowerBound, "idle and active stop must share the same recovery cancellation")
        assertTrue(cancelRecovery.lowerBound < firstStopAwait.lowerBound, "stop must cancel recovery before suspended HAL cleanup")
        assertFalse(stopCancellationWindow.contains("await "), "recovery cancellation must be atomic on MainActor")
        assertEqual(
            handlerBody.components(separatedBy: "cancelConfigRecoveryIfCurrent(generation: recoveryGeneration)").count - 1,
            4,
            "all four stale config-cleanup exits should consume only their matching recovery generation"
        )

        // Zombie-cancellation ordering (moved here from the old
        // ParakeetStartRecordingFailurePolicyTests suites). A stale zombie task
        // must not resume between graph invalidation and cancellation, or it can
        // recreate the graph or restart the mic against a superseded owner.
        if let stopWatchdog = stopBody.range(of: "cancelAudioWatchdog()", range: graphInvalidation.upperBound..<stopBody.endIndex) {
            let window = String(stopBody[graphInvalidation.lowerBound..<stopWatchdog.upperBound])
            assertFalse(window.contains("await "), "stop should invalidate the graph and cancel zombie recovery in one actor turn")
        } else {
            assertTrue(false, "stop should cancel the watchdog after invalidating the graph")
        }

        if let configGraphBump = handlerBody.range(of: "audioGraphGeneration += 1"),
           let configCancel = handlerBody.range(of: "cancelAudioWatchdog()", range: configGraphBump.upperBound..<handlerBody.endIndex) {
            let window = String(handlerBody[configGraphBump.lowerBound..<configCancel.upperBound])
            assertFalse(window.contains("await "), "config change must invalidate the graph owner and cancel zombie recovery without suspending")
        } else {
            assertTrue(false, "config change should invalidate the graph before cancelling zombie recovery")
        }

        if let cancelStart = engineSource.range(of: "private func cancelZombieEngineRecovery()"),
           let cancelEnd = engineSource.range(of: "func cancelAudioWatchdog() -> Bool", range: cancelStart.upperBound..<engineSource.endIndex) {
            let cancelBody = String(engineSource[cancelStart.lowerBound..<cancelEnd.lowerBound])
            if let claim = cancelBody.range(of: "audioEngineWorkOwnership.claimPendingWorkForSuccessor("),
               let replace = cancelBody.range(of: "abandonBlockedAudioEngine(reason: reason)", range: claim.upperBound..<cancelBody.endIndex),
               let terminal = cancelBody.range(of: "zombieRecoveryState.cancelActiveAttempt()", range: replace.upperBound..<cancelBody.endIndex) {
                let window = String(cancelBody[claim.lowerBound..<terminal.lowerBound])
                assertFalse(window.contains("await "), "a still-blocked engine queue must be claimed and replaced in one MainActor turn")
            } else {
                assertTrue(false, "zombie cancellation should claim and replace a blocked queue before publishing its terminal result")
            }
        } else {
            assertTrue(false, "test should find cancelZombieEngineRecovery")
        }

        // Route recovery keeps buffered audio, then restarts through the normal
        // start path (moved here from ParakeetAudioGraphOwnershipTests).
        assertTrue(
            handlerBody.contains("preserveCurrentRecordingBuffersForRecovery()"),
            "config change during recording should preserve buffered audio before tearing down the tap"
        )
        assertTrue(
            recoverySource.contains("let startSucceeded = await self.startRecording()"),
            "device recovery should restart through startRecording so retained segments keep the same recording claim"
        )
    }

    runSuite("ParakeetEngine config change cannot restart recording after stop begins") {
        // Stop-intent visibility for the stop's whole lifetime is a behavior
        // test now (ParakeetEngineWorkLifecycleTests, single-flight stop).
        let recoverySource = readParakeetDeviceRecoverySource()
        guard let handlerStart = recoverySource.range(of: "private func handleAudioConfigChange("),
              let handlerEnd = recoverySource.range(
                of: "private func recordStableRouteChangeAnalytics",
                range: handlerStart.upperBound..<recoverySource.endIndex
              ) else {
            assertTrue(false, "test should find the config-recovery body")
            return
        }

        let handlerBody = String(recoverySource[handlerStart.lowerBound..<handlerEnd.lowerBound])
        guard let rejectDuringStop = handlerBody.range(of: "if audioStopInProgress"),
              let graphInvalidation = handlerBody.range(of: "audioGraphGeneration += 1", range: rejectDuringStop.upperBound..<handlerBody.endIndex),
              let inheritRecording = handlerBody.range(of: "if isRecording", range: graphInvalidation.upperBound..<handlerBody.endIndex) else {
            assertTrue(false, "config recovery should reject an in-progress stop before graph mutation")
            return
        }

        assertTrue(rejectDuringStop.lowerBound < graphInvalidation.lowerBound, "route change must not steal graph ownership during stop")
        assertTrue(rejectDuringStop.lowerBound < inheritRecording.lowerBound, "route change must not inherit the stopped session for restart")
    }

    runSuite("ParakeetEngine config-recovery snapshots are claimable by stop") {
        let source = readParakeetDeviceRecoverySource()
        guard let recoveryStart = source.range(of: "private func attemptDeviceRecovery()"),
              let recoveryEnd = source.range(
                of: "private func scheduleConfigRecoveryTimeout",
                range: recoveryStart.upperBound..<source.endIndex
              ) else {
            assertTrue(false, "test should find config-recovery execution")
            return
        }
        let recovery = String(source[recoveryStart.lowerBound..<recoveryEnd.lowerBound])

        assertTrue(
            recovery.contains("audioEngineWorkOwnership.begin(\n                        owner: snapshotOwner,\n                        phase: .deviceRecoverySnapshot")
                && recovery.contains("isEngineWorkCurrent: { [audioEngineWorkOwnership] in")
                && recovery.contains("audioEngineWorkOwnership.isActive(\n                                    owner: snapshotOwner,\n                                    phase: .deviceRecoverySnapshot")
                && recovery.components(separatedBy: "audioEngineWorkOwnership.finish(").count - 1 == 2,
            "each recovery snapshot should publish one exact lease that stop can claim and every exit finishes"
        )
    }

}
