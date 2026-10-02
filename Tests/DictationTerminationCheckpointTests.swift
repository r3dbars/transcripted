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

    await runSuite("Quit with a take running waits for its checkpoint and refuses before cancelling unsaved audio") { @MainActor in
        // The stop never finishes in the grace window and the checkpoint times out.
        let stalled = TerminationFake(stopFinishes: false, checkpointSettles: false)
        let stalledQuit = await DictationTerminationFinisher.run(stalled.steps())
        assertFalse(stalledQuit, "a checkpoint that never settles must not admit Quit")
        assertEqual(
            stalled.events,
            ["terminating=true", "dropQueuedStart", "stop", "polls=3", "preserve", "waitForCheckpoint",
             "error:\(DictationTerminationFinisher.unsafeQuitMessage)", "terminating=false"],
            "the refusal comes after the bounded wait and before any cancellation"
        )
        assertTrue(
            DictationTerminationFinisher.unsafeQuitMessage.contains("Audio isn't saved yet; your recording wasn't discarded"),
            "unsafe Quit describes unsaved audio without claiming a completed save"
        )

        // The checkpoint settles but no WAV exists for this take.
        let noWAV = TerminationFake(stopFinishes: false, checkpointSettles: true, hasWAV: false)
        let noWAVQuit = await DictationTerminationFinisher.run(noWAV.steps())
        assertFalse(noWAVQuit, "a settled checkpoint without a real WAV still refuses Quit")
        assertFalse(noWAV.events.contains("cancelPreserving"), "the only copy is never cancelled")
        assertEqual(noWAV.events.last, "terminating=false", "a refusal clears the terminating flag for a later Quit")

        // The checkpoint settles with a WAV: cancel, keeping the stopped audio.
        let safe = TerminationFake(stopFinishes: false, checkpointSettles: true, hasWAV: true)
        let safeQuit = await DictationTerminationFinisher.run(safe.steps())
        assertTrue(safeQuit, "a durable WAV admits Quit")
        assertEqual(
            Array(safe.events.suffix(3)),
            ["waitForCheckpoint", "canTerminateActive", "cancelPreserving"],
            "the preserving cancel only follows a settled checkpoint with a WAV"
        )
        assertFalse(safe.events.contains("terminating=false"), "an admitted Quit stays terminating")
    }

    await runSuite("Quit after the take finishes goes through the retained-audio check") { @MainActor in
        let finished = TerminationFake(stopFinishes: true, checkpointSettles: true, admitInactive: false)
        let finishedQuit = await DictationTerminationFinisher.run(finished.steps())
        assertFalse(finishedQuit, "a completed stop with unsaved retained audio still refuses Quit")
        assertEqual(finished.events.last, "admitInactiveQuit", "a finished take is judged by the inactive-take check")
        assertFalse(finished.events.contains("waitForCheckpoint"), "no checkpoint wait once the take is done")

        let idle = TerminationFake(dictating: false, admitInactive: true)
        let idleQuit = await DictationTerminationFinisher.run(idle.steps())
        assertTrue(idleQuit, "Quit with nothing recording and nothing retained is admitted")
        assertEqual(idle.events, ["terminating=true", "dropQueuedStart", "admitInactiveQuit"], "and nothing is stopped")

        let cancelled = TerminationFake(stopFinishes: false, sleepCancelled: true)
        let cancelledQuit = await DictationTerminationFinisher.run(cancelled.steps())
        assertFalse(cancelledQuit, "a cancelled grace wait refuses Quit")
        assertEqual(cancelled.events.last, "terminating=false", "and clears the terminating flag")
    }

    await runSuite("Retry Saving waits for the old checkpoint, then readmits and stops without pasting") { @MainActor in
        var events: [String] = []
        func steps(settles: Bool, canRetry: Bool) -> DictationRetainedAudioRetry.Steps {
            DictationRetainedAudioRetry.Steps(
                waitForCheckpoint: { events.append("wait"); return settles },
                onCheckpointTimeout: { events.append("timeout") },
                canRetry: { events.append("canRetry"); return canRetry },
                resetStopGate: { events.append("resetGate") },
                readmit: { events.append("readmit") },
                stopWithoutPaste: { events.append("stopWithoutPaste") },
                afterStop: { events.append("afterStop") }
            )
        }
        await DictationRetainedAudioRetry.run(steps(settles: true, canRetry: true))
        assertEqual(
            events, ["wait", "canRetry", "resetGate", "readmit", "stopWithoutPaste", "afterStop"],
            "stop ownership resets only after the old checkpoint settles, then the no-paste stop runs"
        )
        events = []
        await DictationRetainedAudioRetry.run(steps(settles: false, canRetry: true))
        assertEqual(events, ["wait", "timeout"], "a stalled old checkpoint never readmits the take")
        events = []
        await DictationRetainedAudioRetry.run(steps(settles: true, canRetry: false))
        assertEqual(events, ["wait", "canRetry"], "a take that can't be retried is left alone")
    }

    // The controller's side (Quit's mark/wait/cancel wiring, a press refused
    // for unsaved audio before any new-session side effect, the empty take
    // that offers Retry Saving, and an unavailable checkpoint ending the take
    // before the model) runs through DictationSessionPipeline.swift and is a
    // behavior test in DictationSessionPipelineTests.swift.
    await runSuite("App Quit refused by dictation replies false before any shutdown and allows a later Quit") { @MainActor in
        let refused = AppTerminationRecorder(dictationAdmits: false)
        let refusedQuit = await AppTerminationSequence.run(refused.steps())
        assertFalse(refusedQuit, "unsafe dictation audio refuses Quit")
        assertEqual(
            refused.events, ["finishDictation", "resetAdmission", "reply:false"],
            "the refusal resets cleanup admission and replies false, with no meeting prep, input restore, or flush"
        )

        let accepted = AppTerminationRecorder(dictationAdmits: true)
        let acceptedQuit = await AppTerminationSequence.run(accepted.steps())
        assertTrue(acceptedQuit, "saved dictation audio admits Quit")
        assertEqual(
            accepted.events,
            ["finishDictation", "meetingPrepare", "appStateShutdown", "restoreInput", "flushEvents", "markFinished", "reply:true"],
            "meeting prep, shutdown, input restore, and the event flush all finish before AppKit hears true"
        )
    }
}

/// Records the app's Quit steps. Each async step yields first, so a step
/// that isn't awaited would land after the reply.
@MainActor
private final class AppTerminationRecorder {
    var events: [String] = []
    private let dictationAdmits: Bool

    init(dictationAdmits: Bool) {
        self.dictationAdmits = dictationAdmits
    }

    private func record(_ event: String) async {
        await Task.yield()
        events.append(event)
    }

    func steps() -> AppTerminationSequence.Steps {
        AppTerminationSequence.Steps(
            finishDictationForTermination: { await self.record("finishDictation"); return self.dictationAdmits },
            resetCleanupAdmission: { self.events.append("resetAdmission") },
            prepareMeetingForTermination: { await self.record("meetingPrepare") },
            shutDownAppState: { self.events.append("appStateShutdown") },
            stopAndRestorePersistentInput: { await self.record("restoreInput") },
            flushLocalEvents: { await self.record("flushEvents") },
            markCleanupFinished: { self.events.append("markFinished") },
            replyToPendingRequests: { self.events.append("reply:\($0)") }
        )
    }
}

@MainActor
private final class TerminationFake {
    var events: [String] = []
    private var dictating: Bool
    private let stopFinishes: Bool
    private let checkpointSettles: Bool
    private let hasWAV: Bool
    private let admitInactive: Bool
    private let sleepCancelled: Bool
    private var polls = 0

    init(
        dictating: Bool = true,
        stopFinishes: Bool = false,
        checkpointSettles: Bool = true,
        hasWAV: Bool = true,
        admitInactive: Bool = true,
        sleepCancelled: Bool = false
    ) {
        self.dictating = dictating
        self.stopFinishes = stopFinishes
        self.checkpointSettles = checkpointSettles
        self.hasWAV = hasWAV
        self.admitInactive = admitInactive
        self.sleepCancelled = sleepCancelled
    }

    func steps() -> DictationTerminationFinisher.Steps {
        DictationTerminationFinisher.Steps(
            setTerminating: { self.events.append("terminating=\($0)") },
            dropQueuedStart: { self.events.append("dropQueuedStart") },
            isDictating: { self.dictating },
            admitInactiveQuit: { self.events.append("admitInactiveQuit"); return self.admitInactive },
            stop: {
                self.events.append("stop")
                if self.stopFinishes { self.dictating = false }
            },
            gracePolls: 3,
            sleepOnePoll: {
                if self.sleepCancelled { return false }
                self.polls += 1
                if self.polls == 3 { self.events.append("polls=3") }
                return true
            },
            preserveStoppedAudio: { self.events.append("preserve") },
            waitForCheckpoint: { self.events.append("waitForCheckpoint"); return self.checkpointSettles },
            canTerminateActive: { self.events.append("canTerminateActive"); return self.hasWAV },
            showError: { self.events.append("error:\($0)") },
            cancelPreservingStoppedAudio: { self.events.append("cancelPreserving") }
        )
    }
}
