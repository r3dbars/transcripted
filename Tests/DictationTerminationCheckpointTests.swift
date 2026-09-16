import Foundation

func testDictationTerminationCheckpoint() async {
    let stalledCheckpoint = DictationStoppedAudioCheckpointSignal()
    let firstQuit = await stalledCheckpoint.waitForCompletion(timeoutNanoseconds: 20_000_000)
    let repeatQuit = await stalledCheckpoint.waitForCompletion(timeoutNanoseconds: 20_000_000)
    await stalledCheckpoint.complete()
    let completedQuit = await stalledCheckpoint.waitForCompletion(timeoutNanoseconds: 20_000_000)

    runSuite("Termination checkpoint defers repeated Quit until an in-flight stop settles") {
        assertFalse(firstQuit, "a never-completing checkpoint must not admit Quit")
        assertFalse(repeatQuit, "a later Quit must still defer while the same stop is stalled")
        assertTrue(completedQuit, "a later Quit can be admitted after the stop completes")
    }

    let alreadyComplete = DictationStoppedAudioCheckpointSignal()
    await alreadyComplete.complete()
    let immediateQuit = await alreadyComplete.waitForCompletion(timeoutNanoseconds: 0)
    let cancelledAlreadyCompleteQuit = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return await alreadyComplete.waitForCompletion(timeoutNanoseconds: 0)
    }
    let cancelledSettledDeferred = await cancelledAlreadyCompleteQuit.value
    let cancelledCheckpoint = DictationStoppedAudioCheckpointSignal()
    let cancelledQuit = Task {
        await cancelledCheckpoint.waitForCompletion(timeoutNanoseconds: 5_000_000_000)
    }
    cancelledQuit.cancel()
    let cancellationDeferred = await cancelledQuit.value

    runSuite("Termination checkpoint admits settled audio and defers a cancelled wait") {
        assertTrue(immediateQuit, "completed checkpoint admits even with no remaining wait budget")
        assertFalse(cancellationDeferred, "cancelled termination wait must defer instead of admitting Quit")
        assertFalse(cancelledSettledDeferred, "a cancelled Quit must not be admitted merely because the checkpoint was already settled")
    }

    runSuite("Termination admission distinguishes checkpoint completion from a durable recording") {
        assertTrue(DictationTerminationAdmissionPolicy.mustStopBeforeInference(
            snapshotAvailable: false, hasRecoverableRecording: true
        ), "a missing WAV snapshot with retained native RAM must not enter consuming inference")
        assertFalse(DictationTerminationAdmissionPolicy.mustStopBeforeInference(
            snapshotAvailable: true, hasRecoverableRecording: true
        ), "a valid snapshot may proceed to model inference with its recovery checkpoint")
        assertFalse(DictationTerminationAdmissionPolicy.mustStopBeforeInference(
            snapshotAvailable: false, hasRecoverableRecording: false
        ), "genuine empty capture retains normal no-audio/silence handling")
        assertFalse(DictationTerminationAdmissionPolicy.canTerminate(
            isDictating: true, checkpointSettled: false,
            hasRecoverableRecording: true, recoveryWAVExists: true
        ), "an unfinished checkpoint cannot admit Quit")
        assertFalse(DictationTerminationAdmissionPolicy.canTerminate(
            isDictating: true, checkpointSettled: true,
            hasRecoverableRecording: true, recoveryWAVExists: false
        ), "a completed but failed WAV checkpoint cannot cancel active finalization")
        assertFalse(DictationTerminationAdmissionPolicy.canTerminate(
            isDictating: false, checkpointSettled: true,
            hasRecoverableRecording: true, recoveryWAVExists: false
        ), "a failed WAV write cannot turn an inactive controller into permission to discard RAM audio")
        assertTrue(DictationTerminationAdmissionPolicy.canTerminate(
            isDictating: true, checkpointSettled: true,
            hasRecoverableRecording: false, recoveryWAVExists: true
        ), "a settled existing WAV admits the preserving-cancel fallback")
        assertTrue(DictationTerminationAdmissionPolicy.canTerminate(
            isDictating: false, checkpointSettled: false,
            hasRecoverableRecording: false, recoveryWAVExists: false
        ), "a completed transcript or intentional explicit discard can Quit without stranded RAM audio")
        assertTrue(DictationTerminationAdmissionPolicy.blocksNewCapture(
            hasRecoverableRecording: true, recoveryWAVExists: false
        ), "new capture must not overwrite the only native RAM copy after a failed WAV checkpoint")
        assertFalse(DictationTerminationAdmissionPolicy.blocksNewCapture(
            hasRecoverableRecording: true, recoveryWAVExists: true
        ), "a durable WAV permits a later fresh dictation")
        assertFalse(DictationTerminationAdmissionPolicy.blocksNewCapture(
            hasRecoverableRecording: false, recoveryWAVExists: false
        ), "explicit discard or consumed successful transcription permits fresh dictation")
    }

    runSuite("Retry Saving readmits only the same settled retained recording") {
        func canRetry(
            active: Bool = false, settled: Bool = true, ram: Bool = true,
            wav: Bool = false, sameSession: Bool = true, pendingStart: Bool = false
        ) -> Bool {
            DictationTerminationAdmissionPolicy.canRetrySaving(
                isDictating: active, checkpointSettled: settled,
                hasRecoverableRecording: ram, recoveryWAVExists: wav,
                isCurrentSession: sameSession, hasPendingStart: pendingStart
            )
        }
        assertTrue(canRetry(), "a finished failed WAV write can retry its preserved native timeline")
        assertFalse(canRetry(active: true), "a second click cannot reset a stop already in flight")
        assertFalse(canRetry(settled: false), "a retry cannot race an old checkpoint write")
        assertFalse(canRetry(ram: false), "a consumed or discarded recording cannot be retried")
        assertFalse(canRetry(wav: true), "an already-durable recording must not be overwritten")
        assertFalse(canRetry(sameSession: false), "a retry cannot borrow a newer session's audio")
        assertFalse(canRetry(pendingStart: true), "a pending fresh start cannot be mistaken for a retained-audio retry")
        let decision = DictationRecordingStartLifecyclePolicy.stopDecision(
            isLoadingOverlay: false, isListeningOverlay: true,
            hasStartupTask: false, hasRecordingStartTask: false, sttIsRecording: false
        )
        assertEqual(decision, .stopRecording, "the existing stop path accepts retained idle audio from a listening admission state")
        let sessionID = UUID()
        var gate = DictationStopFinalizationGate()
        assertTrue(gate.admit(sessionID: sessionID), "the first stop owns this session")
        assertFalse(gate.admit(sessionID: sessionID), "repeat stop is fenced while the old checkpoint is active")
        gate.reset()
        assertTrue(gate.admit(sessionID: sessionID), "a settled retry can readmit the same retained session")
    }

    do {
        let controller = try String(
            contentsOf: repoFixtureURL("Sources/UI/Overlay/DictationSessionController.swift"),
            encoding: .utf8
        )
        let app = try String(contentsOf: repoFixtureURL("Sources/TranscriptedApp.swift"), encoding: .utf8)
        let termination = controller.components(separatedBy: "func finishDictationForTermination() async -> Bool").last ?? ""
        let terminationBody = termination.components(separatedBy: "// MARK: - Private").first ?? ""
        let wait = terminationBody.range(of: "waitForCompletion(timeoutNanoseconds: 2_000_000_000)")
        let waitEnd = wait?.upperBound ?? terminationBody.startIndex
        let deferral = terminationBody.range(of: "return false", range: waitEnd..<terminationBody.endIndex)
        let preservation = terminationBody.range(of: "cancelDictation(preserveStoppedAudio: true)")
        let appAdmission = app.range(of: "guard await self.sessionController.finishDictationForTermination() else")
        let appAdmissionEnd = appAdmission?.upperBound ?? app.startIndex
        let appDeferral = app.range(of: "self.replyToPendingTerminationRequests(sender, shouldTerminate: false)", range: appAdmissionEnd..<app.endIndex)
        let appDeferralEnd = appDeferral?.upperBound ?? app.startIndex
        let meetingPrep = app.range(of: "await self.appState.meetingSession.prepareForTermination()", range: appDeferralEnd..<app.endIndex)
        let start = controller.range(of: "func startDictation(")
        let startGuard = controller.range(of: "DictationTerminationAdmissionPolicy.blocksNewCapture(",
                                          range: (start?.upperBound ?? controller.startIndex)..<controller.endIndex)
        let newSession = controller.range(of: "currentDictationSessionID = UUID()",
                                          range: (startGuard?.upperBound ?? controller.startIndex)..<controller.endIndex)
        let recoveryReset = controller.range(of: "stoppedAudioRecovery = nil",
                                             range: (newSession?.upperBound ?? controller.startIndex)..<controller.endIndex)
        let retry = controller.components(separatedBy: "private func retrySavingRetainedDictationAudio()").last ?? ""
        let retryWait = retry.range(of: "await checkpointSignal.waitForCompletion(timeoutNanoseconds: 2_000_000_000)")
        let retryGate = retry.range(of: "self.stopFinalizationGate.reset()")
        let retryStop = retry.range(of: "self.stopDictationAndPaste(trigger: .unknown, autoPaste: false)")
        let unsavedAudio = controller.range(of: "if emptyReason == .audioNeedsRecovery {")
        let unsavedAudioRetry = controller.range(of: "showFailedCheckpointRecoveryError()",
                                                 range: (unsavedAudio?.upperBound ?? controller.startIndex)..<controller.endIndex)
        let snapshot = controller.range(of: "if let recording = await appState.sttRouter.snapshotRecordedSamplesForPersistence()")
        let nilSnapshotFence = controller.range(of: "DictationTerminationAdmissionPolicy.mustStopBeforeInference(",
                                                range: (snapshot?.upperBound ?? controller.startIndex)..<controller.endIndex)
        let inference = controller.range(of: "let voiceText = await appState.sttRouter.transcribe(",
                                         range: (nilSnapshotFence?.upperBound ?? controller.startIndex)..<controller.endIndex)

        runSuite("Production Quit wiring defers shutdown before an unsafe checkpoint") {
            assertTrue(terminationBody.contains("if !isDictating { return admitInactiveDictationQuit() }"),
                       "normal stop grace must check retained RAM audio before admitting a completed dictation")
            assertTrue(terminationBody.contains("recoveryWAVExists: currentStoppedAudioRecoveryWAVExists"),
                       "a completed checkpoint needs a real current-session WAV before preserving cancellation")
            assertTrue(terminationBody.contains("Audio isn't saved yet; your recording wasn't discarded"),
                       "unsafe Quit must describe uncheckpointed audio without claiming a completed save")
            assertTrue(wait != nil && deferral != nil && preservation != nil, "termination needs a bounded checkpoint and a preserving fallback")
            if let wait, let deferral, let preservation {
                assertTrue(wait.lowerBound < deferral.lowerBound && deferral.lowerBound < preservation.lowerBound,
                           "checkpoint timeout must return false before any cancellation of in-flight audio")
            }
            assertTrue(app.contains("self.terminationCleanupStarted = false"), "deferred Quit must reset cleanup admission for a later request")
            assertTrue(appAdmission != nil && appDeferral != nil && meetingPrep != nil,
                       "unsafe dictation must reply false before meeting termination or app shutdown")
            if let appAdmission, let appDeferral, let meetingPrep {
                assertTrue(appAdmission.lowerBound < appDeferral.lowerBound && appDeferral.lowerBound < meetingPrep.lowerBound,
                           "meeting/app shutdown must not run after dictation Quit deferral")
            }
            assertTrue(startGuard != nil && newSession != nil && recoveryReset != nil,
                       "new capture must fence unsaved RAM before assigning a new session or clearing recovery")
            if let startGuard, let newSession, let recoveryReset {
                assertTrue(startGuard.lowerBound < newSession.lowerBound && newSession.lowerBound < recoveryReset.lowerBound,
                           "the failed-checkpoint guard must precede every fresh-session side effect")
            }
            assertTrue(retryWait != nil && retryGate != nil && retryStop != nil,
                       "Retry Saving must await the old owner, then readmit and use the no-paste stop pipeline")
            if let retryWait, let retryGate, let retryStop {
                assertTrue(retryWait.lowerBound < retryGate.lowerBound && retryGate.lowerBound < retryStop.lowerBound,
                           "retry cannot reset stop ownership before its old checkpoint has settled")
            }
            assertTrue(unsavedAudio != nil && unsavedAudioRetry != nil,
                       "an undecoded recording without WAV must offer retained-RAM saving retry instead of claiming only model-empty speech")
            assertTrue(snapshot != nil && nilSnapshotFence != nil && inference != nil,
                       "failed WAV snapshot with retained RAM must be fenced before consuming model inference")
            if let snapshot, let nilSnapshotFence, let inference {
                assertTrue(snapshot.lowerBound < nilSnapshotFence.lowerBound && nilSnapshotFence.lowerBound < inference.lowerBound,
                           "snapshot failure must stop before the model can drain the only audio copy")
            }
        }
    } catch {
        runSuite("Production Quit source fixtures are readable") {
            assertTrue(false, "could not inspect production Quit wiring: \(error)")
        }
    }
}
