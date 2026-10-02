import AppKit
import Foundation

// Behavior tests for Sources/UI/Overlay/DictationSessionPipeline.swift: the
// start and stop wiring DictationSessionController runs through
// DictationSessionPipelineHost. The controller itself can't be built in this
// runner, so a fake controller conforms to the host protocol and the real
// pipeline code runs against it. These replace source-text pins that read the
// controller's +Area files (persist before the model wait, the Quit order,
// retry-marked restarts, the start click, held-back text, the empty-take
// branches, the stale stop-task fence, and the focus-recovery wiring).
//
// Synthetic only: nothing here opens a mic, writes a real recovery WAV under
// Application Support, or pastes. `bash check.sh hardware` is still the check
// for real capture and paste-back.

@MainActor
func testDictationSessionPipeline() async {
    // MARK: Start

    runSuite("A press refused for unsaved audio leaves the session alone and offers Retry Saving") {
        let host = PipelineFakeHost()
        host.isDictating = false
        host.dictationHasRecoverableRecording = true
        host.currentStoppedAudioRecoveryWAVExists = false
        let before = host.currentDictationSessionID

        let admitted = host.admitDictationStart(sourceApp: nil, trigger: .physicalKey, shortcutMode: .pushToTalk, isRetry: false)

        assertFalse(admitted, "a fresh capture would clear the only copy of the last take")
        assertEqual(host.currentDictationSessionID, before, "no new session id before the guard lets the press through")
        assertEqual(
            host.events.all,
            ["island", "count request retry=false", "refused unsaved_capture_recovery_pending", "retry saving error"],
            "the press is counted, refused with its own reason, and the Retry Saving message shows"
        )
    }

    runSuite("An admitted press is counted before its session id exists") {
        let host = PipelineFakeHost()
        host.isDictating = false
        let before = host.currentDictationSessionID
        var idWhenCounted: UUID?
        host.onCountRequest = { idWhenCounted = host.currentDictationSessionID }

        let admitted = host.admitDictationStart(sourceApp: nil, trigger: .menu, shortcutMode: nil, isRetry: true)

        assertTrue(admitted)
        assertEqual(idWhenCounted, before, "dictation_start_requested never carries the new session's id")
        assertTrue(host.currentDictationSessionID != before, "admission mints the new session")
        assertEqual(host.events.all, ["island", "count request retry=true"], "a retry press is counted as a retry")
    }

    runSuite("Each refused press reports its own reason and says why") {
        let busy = PipelineFakeHost()
        busy.isDictating = false
        busy.isPreviousTakeTranscribing = true
        assertFalse(busy.admitDictationStart(sourceApp: nil, trigger: .menu, shortcutMode: nil, isRetry: false))
        assertEqual(busy.events.all.suffix(2), [
            "refused previous_dictation_transcribing",
            "error: Still finishing the last dictation. Try again in a moment.",
        ])

        let unavailable = PipelineFakeHost()
        unavailable.isDictating = false
        unavailable.unavailableReason = "No microphone."
        assertFalse(unavailable.admitDictationStart(sourceApp: nil, trigger: .menu, shortcutMode: nil, isRetry: false))
        assertEqual(unavailable.events.all.suffix(2), ["refused dictation_unavailable", "error: No microphone."])

        let already = PipelineFakeHost()
        assertFalse(already.admitDictationStart(sourceApp: nil, trigger: .menu, shortcutMode: nil, isRetry: false))
        assertEqual(already.events.all, [], "a press while dictating is neither counted nor shown")
    }

    runSuite("Try Again restarts the failed take marked as a retry") {
        let host = PipelineFakeHost()
        host.currentDictationTrigger = .physicalKey
        let anchor = NSRect(x: 1, y: 2, width: 3, height: 4)

        host.retryDictation(sourceApp: nil, anchorRect: anchor)

        assertEqual(host.starts.count, 1)
        assertEqual(host.starts.first?.isRetry, true, "four taps on Try Again must not read as five attempts")
        assertEqual(host.starts.first?.trigger, .physicalKey, "the retry keeps the failed take's trigger")
        assertEqual(host.starts.first?.anchorRect, anchor, "the retry opens where the take was")
    }

    await runSuite("The start click is queued before the mic start and plays once per session") {
        let host = PipelineFakeHost()
        host.launchFastStart(startCuePlaysOnKeyPress: true) { host.events.append("mic start") }
        assertEqual(host.events.all, ["start click"], "the click doesn't wait on the mic start task")
        await host.recordingStartRetryTask?.value
        host.playStartCueOnce() // recording started
        assertEqual(host.events.all, ["start click", "mic start"], "recording starting doesn't click a second time")

        let headset = PipelineFakeHost()
        headset.launchFastStart(startCuePlaysOnKeyPress: false) { headset.events.append("mic start") }
        await headset.recordingStartRetryTask?.value
        headset.playStartCueOnce()
        assertEqual(headset.events.all, ["mic start", "start click"], "a headset hears the click only once recording started")
    }

    await runSuite("A failed background hotkey start tries focus recovery once") {
        let host = PipelineFakeHost.backgroundHotkeyStart()
        let recover = host.startFailureRecovery(sessionID: host.currentDictationSessionID)

        await recover()
        await recover()

        assertEqual(host.events.all, ["prepare activation current=true"], "one foreground handshake for this session, never two")
    }

    await runSuite("Focus recovery is skipped when it can't help or isn't this session's") {
        let stale = PipelineFakeHost.backgroundHotkeyStart()
        await stale.startFailureRecovery(sessionID: UUID())()
        assertEqual(stale.events.all, [], "a start the session no longer owns doesn't steal focus")

        let frontmost = PipelineFakeHost.backgroundHotkeyStart()
        frontmost.appIsActive = true
        await frontmost.startFailureRecovery(sessionID: frontmost.currentDictationSessionID)()
        assertEqual(frontmost.events.all, [], "Transcripted is already frontmost")

        let meetingMic = PipelineFakeHost.backgroundHotkeyStart()
        meetingMic.usesMeetingMic = true
        await meetingMic.startFailureRecovery(sessionID: meetingMic.currentDictationSessionID)()
        assertEqual(meetingMic.events.all, [], "never while dictation borrows the meeting mic")

        let menu = PipelineFakeHost()
        menu.currentStartReadinessProfile = DictationStartReadinessPolicy.profile(triggerRawValue: "menu", isAppActive: false)
        await menu.startFailureRecovery(sessionID: menu.currentDictationSessionID)()
        assertEqual(menu.events.all, [], "only a hotkey start may escalate to the foreground")
    }

    // MARK: Stop

    await runSuite("A stale stop task touches nothing") {
        let superseded = PipelineFakeHost()
        let staleID = UUID()
        let result = await superseded.runStopUntilTranscribed(taskSessionID: staleID, superseded.stopSteps())
        assertEqual(result.outcome, .abandoned)
        assertEqual(superseded.events.all, [], "an older stop task can't stop or relabel the session now running")

        let ended = PipelineFakeHost()
        ended.isDictating = false
        _ = await ended.runStopUntilTranscribed(taskSessionID: ended.currentDictationSessionID, ended.stopSteps())
        assertEqual(ended.events.all, [], "a session that already ended isn't stopped again")

        let cancelled = PipelineFakeHost()
        let task = Task { @MainActor in
            await cancelled.runStopUntilTranscribed(taskSessionID: cancelled.currentDictationSessionID, cancelled.stopSteps())
        }
        task.cancel()
        let cancelledResult = await task.value
        assertEqual(cancelledResult.outcome, .abandoned)
        assertEqual(cancelled.events.all, [], "a cancelled stop task doesn't reach the mic")
    }

    await runSuite("The take is saved before anything waits on the model, then that snapshot is transcribed") {
        let host = PipelineFakeHost()
        let result = await host.runStopUntilTranscribed(taskSessionID: host.currentDictationSessionID, host.stopSteps())

        assertEqual(result.outcome, .transcribed("hello"))
        assertEqual(host.events.all, [
            "stop requested", "stop mic", "stop click", "snapshot", "write checkpoint",
            "checkpoint settled", "model wait", "transcribing", "transcribe snapshot-1",
        ], "checkpoint, then the model wait, then transcription of the checkpointed snapshot")
        assertEqual(host.events.all.filter { $0 == "stop click" }.count, 1, "one stop click from stop to text")
        assertEqual(host.stoppedAudioRecovery?.sessionID, host.currentDictationSessionID, "the take keeps its checkpoint until delivered")
    }

    await runSuite("No snapshot while audio is still in memory ends the take before the model") {
        let host = PipelineFakeHost()
        host.snapshotValue = nil
        host.recoverableRecording = true
        let result = await host.runStopUntilTranscribed(taskSessionID: host.currentDictationSessionID, host.stopSteps())

        assertEqual(result.outcome, .ended)
        assertEqual(Array(host.events.all.suffix(2)), ["clear audio_checkpoint_unavailable", "retry saving error"])
        assertFalse(host.events.all.contains("model wait"), "inference would consume the only copy")
        assertFalse(host.events.all.contains { $0.hasPrefix("transcribe ") })
        assertEqual(host.dictatingWhenRetrySavingShown, [false], "the session ends first, so Retry Saving can be offered")
    }

    await runSuite("A failed checkpoint write ends the take with Retry Saving before the model") {
        let host = PipelineFakeHost()
        host.checkpointWriteFails = true
        let result = await host.runStopUntilTranscribed(taskSessionID: host.currentDictationSessionID, host.stopSteps())

        assertEqual(result.outcome, .ended)
        assertEqual(Array(host.events.all.suffix(3)), ["report checkpoint failure", "clear audio_persistence_failed", "retry saving error"])
        assertFalse(host.events.all.contains("model wait"))
        assertEqual(host.dictatingWhenRetrySavingShown, [false])
    }

    await runSuite("No snapshot and nothing left in memory transcribes without a prepared recording") {
        let host = PipelineFakeHost()
        host.snapshotValue = nil
        let result = await host.runStopUntilTranscribed(taskSessionID: host.currentDictationSessionID, host.stopSteps())

        assertEqual(result.outcome, .transcribed("hello"))
        assertEqual(host.events.all.last, "transcribe none")
    }

    await runSuite("A checkpoint finished after Quit took the session is kept, otherwise deleted") {
        for quitMarkedIt in [true, false] {
            let host = PipelineFakeHost()
            host.holdCheckpointWrite = true
            let sessionID = host.currentDictationSessionID
            let task = Task { @MainActor in
                await host.runStopUntilTranscribed(taskSessionID: sessionID, host.stopSteps())
            }
            await host.waitForEvent("write checkpoint")
            // Quit: mark (or not), then cancel the take while the WAV is written.
            if quitMarkedIt { host.stoppedAudioRecoveryPreservationSessionID = sessionID }
            host.isDictating = false
            host.releaseCheckpointWrite()
            let result = await task.value

            assertEqual(result.outcome, .abandoned)
            assertEqual(
                host.events.all.contains("discard checkpoint"),
                !quitMarkedIt,
                quitMarkedIt ? "Quit's preservation mark keeps the WAV for launch recovery" : "a WAV nobody claimed is deleted"
            )
        }
    }

    await runSuite("A model that never loads ends the take and offers the saved recording") {
        let host = PipelineFakeHost()
        host.modelWaitOutcome = .unavailable
        let result = await host.runStopUntilTranscribed(taskSessionID: host.currentDictationSessionID, host.stopSteps())

        assertEqual(result.outcome, .ended)
        assertEqual(host.messages.last?.message, DictationPostStopModelWaitPolicy.modelUnavailableMessage(recordingSaved: true))
        assertEqual(host.messages.last?.actionTitle, "Transcribe It", "the saved recording is one press away")
        assertFalse(host.isDictating)
        assertEqual(host.events.all.last, "clear model_unavailable")
        assertFalse(host.events.all.contains { $0.hasPrefix("transcribe ") })
    }

    runSuite("A stop before capture started cancels the engine and offers a retried start") {
        let host = PipelineFakeHost()
        let pendingStart = Task<Void, Never> { @MainActor in }
        host.recordingStartRetryTask = pendingStart
        var retry: (() -> Void)?

        host.endStopBeforeCaptureStarted(
            inputFormatReady: false,
            cancelSpeechEngine: { host.events.append("cancel engine") },
            report: { host.events.append("report \($0)") },
            showTimeout: { retry = $0; host.events.append("timeout message") }
        )

        assertNil(host.recordingStartRetryTask, "the pending start is dropped")
        assertTrue(pendingStart.isCancelled)
        assertEqual(host.events.all, ["cancel engine", "report microphone_route_not_ready", "timeout message"],
                    "the engine is cancelled, dropping any preserved recovery audio, before the failure is reported")
        assertFalse(host.isDictating)
        retry?()
        assertEqual(host.starts.map(\.isRetry), [true], "Try Again is a retry")
    }

    // MARK: Empty take

    runSuite("A mis-tap is judged by how long the key was held, and closes like a cancel") {
        let quick = PipelineFakeHost()
        quick.finishEmptyTake(taskSessionID: quick.currentDictationSessionID, quick.emptySteps(.recordingTooShort, heldFor: 0.2))
        assertEqual(quick.events.all, [
            "report cancelled=true",
            "close like cancel",
            "clear \(DictationEmptyTranscriptionReason.recordingTooShort.runtimeOutcome)",
            "discard explicit=true",
        ], "a quick press closes like Esc, counts as cancelled, and drops its audio")
        assertTrue(quick.messages.isEmpty, "no error text to dismiss")

        let held = PipelineFakeHost()
        held.finishEmptyTake(taskSessionID: held.currentDictationSessionID, held.emptySteps(.recordingTooShort, heldFor: 30))
        assertFalse(held.events.all.contains("close like cancel"), "a long hold isn't a mis-tap, however long transcription took")
    }

    runSuite("No speech shows its note, then drops the saved audio") {
        let host = PipelineFakeHost()
        host.stoppedAudioRecovery = host.recovery()
        host.finishEmptyTake(taskSessionID: host.currentDictationSessionID, host.emptySteps(.noSpeech, heldFor: 5))
        assertTrue(host.events.all.contains("no speech note"))
        assertEqual(host.events.all.last, "discard explicit=true")
        assertFalse(host.isDictating)
    }

    runSuite("Audio that needs recovery but has no WAV offers Retry Saving, not an empty-speech note") {
        let host = PipelineFakeHost()
        host.finishEmptyTake(taskSessionID: host.currentDictationSessionID, host.emptySteps(.audioNeedsRecovery, heldFor: 5))
        assertEqual(host.dictatingWhenRetrySavingShown, [false])
        assertTrue(host.messages.isEmpty)
        assertFalse(host.events.all.contains("discard explicit=true"), "the audio in memory is the only copy")
    }

    runSuite("A saved recording is offered again; audio the model heard nothing in keeps its launch reminder") {
        let needsRecovery = PipelineFakeHost()
        let recovery = needsRecovery.recovery()
        needsRecovery.stoppedAudioRecovery = recovery
        needsRecovery.finishEmptyTake(taskSessionID: needsRecovery.currentDictationSessionID, needsRecovery.emptySteps(.audioNeedsRecovery, heldFor: 5))
        assertEqual(needsRecovery.messages.last?.actionTitle, "Transcribe It")
        assertEqual(needsRecovery.savedAudioPromptURL, recovery.url)
        assertFalse(needsRecovery.events.all.contains("discard explicit=true"))

        let modelFailed = PipelineFakeHost()
        modelFailed.stoppedAudioRecovery = modelFailed.recovery()
        modelFailed.finishEmptyTake(taskSessionID: modelFailed.currentDictationSessionID, modelFailed.emptySteps(.modelFailure, heldFor: 5))
        assertEqual(modelFailed.messages.last?.actionTitle, "Transcribe It")
        assertNil(modelFailed.savedAudioPromptURL, "a model failure keeps its reminder through the normal launch scan")
    }

    await runSuite("Paste Anyway pastes the held-back text and saves it with the kept audio") {
        let host = PipelineFakeHost()
        let recovery = host.recovery()
        host.stoppedAudioRecovery = recovery
        host.heldBackText = "こんにちは"
        host.finishEmptyTake(taskSessionID: host.currentDictationSessionID, host.emptySteps(.otherLanguage, heldFor: 5))

        assertEqual(host.messages.last?.actionTitle, DictationHeldTextActionCopy.pasteAnywayTitle)
        assertFalse(host.events.all.contains("discard explicit=true"), "the audio stays in case the language guess was wrong")
        host.messages.last?.action?()
        await host.waitForEvent("publish pasted")

        assertEqual(host.lastCompletedText, "こんにちは", "Paste Last Dictation gets the held text")
        assertEqual(host.events.all.filter { $0.hasPrefix("paste") || $0.hasPrefix("save") || $0.hasPrefix("publish") || $0 == "pasted" }, [
            "paste こんにちは", "save こんにちは pasted recovery=true", "pasted", "publish pasted",
        ], "pasted, saved with the paste's delivery and the kept audio, then shown")
        assertEqual(host.savedRecoveries, [recovery], "saving retires this take's own WAV")
    }

    runSuite("Paste Anyway after a new take started doesn't touch that take's pill") {
        let host = PipelineFakeHost()
        host.heldBackText = "hola"
        host.finishEmptyTake(taskSessionID: host.currentDictationSessionID, host.emptySteps(.otherLanguage, heldFor: 5))
        host.currentDictationSessionID = UUID()
        host.isDictating = true
        host.messages.last?.action?()
        assertTrue(host.events.all.contains("paste hola"))
        assertFalse(host.events.all.contains("pasted"), "the new take owns the pill")
    }

    // MARK: Quit

    await runSuite("Quit marks the take, waits for its checkpoint, then cancels it keeping the audio") {
        let host = PipelineFakeHost()
        let signal = DictationStoppedAudioCheckpointSignal()
        host.stoppedAudioCheckpointSignal = signal
        host.currentStoppedAudioRecoveryWAVExists = true
        // The stop task's checkpoint settles only once Quit has marked the take.
        let checkpoint = Task { @MainActor in
            while host.stoppedAudioRecoveryPreservationSessionID == nil {
                guard !Task.isCancelled else { return }
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            host.events.append("checkpoint settled")
            await signal.complete()
        }
        defer { checkpoint.cancel() }

        let quits = await host.finishDictationForTermination(
            gracePolls: 1,
            pollNanoseconds: 1_000_000,
            checkpointTimeoutNanoseconds: 3_000_000_000
        )

        assertTrue(quits)
        assertEqual(host.events.all, ["drop queued start", "stop", "checkpoint settled", "cancel preserve=true"],
                    "stop, then (marked) wait for the WAV, then cancel without discarding it")
        assertEqual(host.preservationWhenCancelled, [host.currentDictationSessionID], "the cancel happens with this take marked")
    }

    await runSuite("Quit with no WAV after the checkpoint is refused and the take kept") {
        let host = PipelineFakeHost()
        let signal = DictationStoppedAudioCheckpointSignal()
        await signal.complete()
        host.stoppedAudioCheckpointSignal = signal
        host.dictationHasRecoverableRecording = true
        host.currentStoppedAudioRecoveryWAVExists = false

        let quits = await host.finishDictationForTermination(gracePolls: 1, pollNanoseconds: 1_000_000)

        assertFalse(quits)
        assertEqual(host.events.all.last, "error: \(DictationTerminationFinisher.uncheckpointedQuitMessage)")
        assertFalse(host.events.all.contains { $0.hasPrefix("cancel") }, "nothing cancels the only copy")
        assertFalse(host.queuedStartGate.isTerminating, "a refused Quit lets presses queue again")
    }

    await runSuite("Quit with nothing dictating but unsaved audio offers Retry Saving") {
        let host = PipelineFakeHost()
        host.isDictating = false
        host.dictationHasRecoverableRecording = true
        host.currentStoppedAudioRecoveryWAVExists = false

        let quits = await host.finishDictationForTermination()

        assertFalse(quits)
        assertEqual(host.events.all, ["drop queued start", "retry saving error"])
        assertFalse(host.queuedStartGate.isTerminating)
    }
}

// MARK: - Fake controller

@MainActor
private final class PipelineFakeHost: DictationSessionPipelineHost {
    struct Start: Equatable {
        var trigger: DictationTrigger
        var anchorRect: NSRect?
        var isRetry: Bool
    }

    struct Message {
        var message: String
        var actionTitle: String?
        var action: (() -> Void)?
    }

    let events = PipelineEvents()
    var starts: [Start] = []
    var messages: [Message] = []
    var dictatingWhenRetrySavingShown: [Bool] = []
    var preservationWhenCancelled: [UUID?] = []
    var savedRecoveries: [DictationStoppedAudioRecovery?] = []
    var onCountRequest: () -> Void = {}

    // Host state
    var isDictating = true
    var currentDictationSessionID = UUID()
    var currentDictationTrigger: DictationTrigger = .keyboardShortcut
    var currentDictationShortcutMode: DictationShortcutMode? = .pushToTalk
    var sessionSourceApp: NSRunningApplication?
    var lastCompletedText: String?
    var recordingStartRetryTask: Task<Void, Never>?
    var queuedStartGate = DictationQueuedStartGate()
    var didPlayStartCue = false
    var startActivationRecoveryGate = DictationStartActivationRecoveryGate()
    var currentStartReadinessProfile = DictationStartReadinessProfile.foreground
    var appIsActive = false
    var usesMeetingMic = false
    var activeMeetingMicCheck: (() -> Bool)? { { [unowned self] in self.usesMeetingMic } }
    var isPreviousTakeTranscribing = false
    var unavailableReason: String?
    var stoppedAudioRecovery: DictationStoppedAudioRecovery?
    var stoppedAudioRecoveryPreservationSessionID: UUID?
    var stoppedAudioCheckpointSignal: DictationStoppedAudioCheckpointSignal?
    var savedAudioPromptURL: URL?
    var dictationHasRecoverableRecording = false
    var currentStoppedAudioRecoveryWAVExists = false

    // Stop-stage knobs
    var snapshotValue: String? = "snapshot-1"
    var recoverableRecording = false
    var checkpointWriteFails = false
    var holdCheckpointWrite = false
    var modelWaitOutcome: DictationPostStopModelWait.Outcome = .alreadyLoaded
    var heldBackText: String?
    private let checkpointGate = DispatchSemaphore(value: 0)

    static func backgroundHotkeyStart() -> PipelineFakeHost {
        let host = PipelineFakeHost()
        host.currentStartReadinessProfile = DictationStartReadinessPolicy.profile(
            triggerRawValue: DictationTrigger.physicalKey.rawValue,
            isAppActive: false
        )
        return host
    }

    func recovery() -> DictationStoppedAudioRecovery {
        DictationStoppedAudioRecovery(
            url: URL(fileURLWithPath: "/tmp/pipeline-fake-\(currentDictationSessionID.uuidString).wav"),
            sessionID: currentDictationSessionID,
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    func releaseCheckpointWrite() { checkpointGate.signal() }

    func waitForEvent(_ event: String) async {
        for _ in 0..<5_000 where !events.all.contains(event) {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    func stopSteps() -> DictationStopTranscriptionSteps<String> {
        let events = events
        let gate = checkpointGate
        let holds = holdCheckpointWrite
        let fails = checkpointWriteFails
        let sessionID = currentDictationSessionID
        return DictationStopTranscriptionSteps<String>(
            markStopRequested: { events.append("stop requested") },
            stopMicrophone: { events.append("stop mic") },
            playStopCue: { events.append("stop click") },
            snapshot: { events.append("snapshot"); return self.snapshotValue },
            checkpointWork: { _ in
                {
                    events.append("write checkpoint")
                    if holds { gate.wait() }
                    if fails { throw PipelineFakeError() }
                    return DictationStoppedAudioRecovery(
                        url: URL(fileURLWithPath: "/tmp/pipeline-fake.wav"),
                        sessionID: sessionID,
                        createdAt: Date(timeIntervalSince1970: 0)
                    )
                }
            },
            discardWork: { _ in { events.append("discard checkpoint") } },
            hasRecoverableRecording: { self.recoverableRecording },
            checkpointSettled: { events.append("checkpoint settled") },
            reportCheckpointFailure: { _ in events.append("report checkpoint failure") },
            clearSession: { events.append("clear \($0)") },
            waitForModel: { isCurrent in
                events.append("model wait")
                return DictationPostStopModelWait.Result(
                    outcome: isCurrent() ? self.modelWaitOutcome : .abandoned,
                    marks: .init()
                )
            },
            reportModelUnavailable: { events.append("report model unavailable") },
            showMessage: { self.messages.append(Message(message: $0, actionTitle: $1, action: $2)) },
            startTranscribing: { events.append("transcribing") },
            transcribe: { events.append("transcribe \($0 ?? "none")"); return "hello" },
            now: { 0 }
        )
    }

    func emptySteps(_ reason: DictationEmptyTranscriptionReason, heldFor seconds: CFAbsoluteTime) -> DictationEmptyTakeSteps {
        DictationEmptyTakeSteps(
            reason: reason,
            stopRequestedAt: 100 + seconds,
            sessionStartedAt: 100,
            heldBackText: { self.heldBackText },
            report: { self.events.append("report cancelled=\($0.countsAsCancelled)") },
            closeLikeCancel: { self.events.append("close like cancel") },
            showNoSpeechAndDismiss: { self.events.append("no speech note") },
            showMessage: { self.messages.append(Message(message: $0, actionTitle: $1, action: $2)) },
            showPasted: { self.events.append("pasted") },
            clearSession: { self.events.append("clear \($0)") }
        )
    }

    // Host methods
    func startDictation(
        sourceApp: NSRunningApplication?,
        trigger: DictationTrigger,
        shortcutMode: DictationShortcutMode?,
        anchorRect: NSRect?,
        isRetry: Bool
    ) {
        starts.append(Start(trigger: trigger, anchorRect: anchorRect, isRetry: isRetry))
    }

    func rememberStartPressIfFinishing(
        sourceApp: NSRunningApplication?,
        trigger: DictationTrigger,
        shortcutMode: DictationShortcutMode?,
        isRetry: Bool
    ) -> Bool { false }

    func showIslandStartingState(near sourceApp: NSRunningApplication?) { events.append("island") }

    func trackDictationStartRequested(trigger: DictationTrigger, isRetry: Bool) {
        onCountRequest()
        events.append("count request retry=\(isRetry)")
    }

    func trackDictationStartRefused(trigger: DictationTrigger, failureKind: String) {
        events.append("refused \(failureKind)")
    }

    func dictationStartUnavailableReason() -> String? { unavailableReason }
    func playDictationStartSound() { events.append("start click") }

    func prepareStartActivation(sourceApp: NSRunningApplication?, isCurrent: () -> Bool) async {
        events.append("prepare activation current=\(isCurrent())")
    }

    func stopDictationAndPaste(trigger: DictationTrigger, shortcutMode: DictationShortcutMode?, autoPaste: Bool) {
        events.append("stop")
    }

    func cancelDictation(preserveStoppedAudio: Bool) {
        preservationWhenCancelled.append(stoppedAudioRecoveryPreservationSessionID)
        events.append("cancel preserve=\(preserveStoppedAudio)")
        isDictating = false
    }

    func dropQueuedDictationStart(showMessage: Bool) { events.append("drop queued start") }

    func showFailedCheckpointRecoveryError() {
        dictatingWhenRetrySavingShown.append(isDictating)
        events.append("retry saving error")
    }

    func showDictationError(_ message: String) { events.append("error: \(message)") }

    func savedDictationAudioAction(for url: URL) -> (title: String, action: () -> Void) {
        ("Transcribe It", {})
    }

    func discardStoppedAudioRecovery(transcriptPersisted: Bool, explicitDiscard: Bool) {
        events.append("discard explicit=\(explicitDiscard)")
    }

    func pasteWithClipboardRestore(_ text: String, followCurrentFocus: Bool) -> TextPasteOutcome {
        events.append("paste \(text)")
        return .pasted
    }

    func startPersistingDictationTranscript(
        text: String,
        delivery: DictationDelivery,
        recovery: DictationStoppedAudioRecovery?
    ) -> Task<DictationTranscriptPersistenceResult, Never> {
        events.append("save \(text) \(delivery.rawValue) recovery=\(recovery != nil)")
        savedRecoveries.append(recovery)
        return Task {
            DictationTranscriptPersistenceResult.measure {
                SavedDictationTranscript(url: URL(fileURLWithPath: "/tmp/pipeline-fake.md"), title: "Fake")
            }
        }
    }

    func publishDictationTranscriptPersistence(
        _ result: DictationTranscriptPersistenceResult,
        delivery: DictationDelivery,
        context: [String: String]
    ) {
        events.append("publish \(delivery.rawValue)")
    }

    func dictationContext(extra: [String: String]) -> [String: String] { extra }
}

private struct PipelineFakeError: Error {}

/// Written from the main actor and from the detached checkpoint write.
private final class PipelineEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ event: String) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
