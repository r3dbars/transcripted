// DictationSessionPipeline.swift
// The start and stop wiring of DictationSessionController that tests run
// against a fake controller: start admission, Try Again restarts, the start
// click, focus recovery after a failed mic start, the stop task up to
// transcription, an empty take, Paste Anyway, a stop before capture started,
// and Quit.

import AppKit

/// What the dictation start/stop pipeline reads and calls on its controller.
///
/// `DictationSessionController` conforms with its own state and methods, so
/// the extensions below are the code production runs. The fast test runner
/// can't build the controller (it needs the whole app), so
/// `Tests/DictationSessionPipelineTests.swift` conforms a small fake and runs
/// the same extensions. Router, overlay and telemetry calls that belong to one
/// step are passed in per call as closures instead of being listed here.
@MainActor
protocol DictationSessionPipelineHost: AnyObject {
    var isDictating: Bool { get set }
    var currentDictationSessionID: UUID { get set }
    var currentDictationTrigger: DictationTrigger { get }
    var currentDictationShortcutMode: DictationShortcutMode? { get }
    var sessionSourceApp: NSRunningApplication? { get }
    var lastCompletedText: String? { get set }
    var recordingStartRetryTask: Task<Void, Never>? { get set }
    var queuedStartGate: DictationQueuedStartGate { get set }

    // Start
    var didPlayStartCue: Bool { get set }
    var startActivationRecoveryGate: DictationStartActivationRecoveryGate { get set }
    var currentStartReadinessProfile: DictationStartReadinessProfile { get }
    /// `NSApp.isActive`.
    var appIsActive: Bool { get }
    /// Whether dictation would borrow the live meeting's mic; nil when the
    /// controller isn't wired to the app yet.
    var activeMeetingMicCheck: (() -> Bool)? { get }
    var isPreviousTakeTranscribing: Bool { get }
    func startDictation(
        sourceApp: NSRunningApplication?,
        trigger: DictationTrigger,
        shortcutMode: DictationShortcutMode?,
        anchorRect: NSRect?,
        isRetry: Bool
    )
    @discardableResult
    func rememberStartPressIfFinishing(
        sourceApp: NSRunningApplication?,
        trigger: DictationTrigger,
        shortcutMode: DictationShortcutMode?,
        isRetry: Bool
    ) -> Bool
    func showIslandStartingState(near sourceApp: NSRunningApplication?)
    /// `dictation_start_requested`.
    func trackDictationStartRequested(trigger: DictationTrigger, isRetry: Bool)
    /// `dictation_start_failed` for a press refused before it had a session.
    func trackDictationStartRefused(trigger: DictationTrigger, failureKind: String)
    func dictationStartUnavailableReason() -> String?
    func playDictationStartSound()
    func prepareStartActivation(sourceApp: NSRunningApplication?, isCurrent: () -> Bool) async

    // Stop, saved audio and Quit
    var stoppedAudioRecovery: DictationStoppedAudioRecovery? { get set }
    var stoppedAudioRecoveryPreservationSessionID: UUID? { get set }
    var stoppedAudioCheckpointSignal: DictationStoppedAudioCheckpointSignal? { get }
    var dictationHasRecoverableRecording: Bool { get }
    var currentStoppedAudioRecoveryWAVExists: Bool { get }
    func stopDictationAndPaste(trigger: DictationTrigger, shortcutMode: DictationShortcutMode?, autoPaste: Bool)
    func cancelDictation(preserveStoppedAudio: Bool)
    func dropQueuedDictationStart(showMessage: Bool)
    func showFailedCheckpointRecoveryError()
    func showDictationError(_ message: String)
    func savedDictationAudioAction(for url: URL) -> (title: String, action: () -> Void)
    func discardStoppedAudioRecovery(transcriptPersisted: Bool, explicitDiscard: Bool)
    func pasteWithClipboardRestore(_ text: String, followCurrentFocus: Bool) -> TextPasteOutcome
    func startPersistingDictationTranscript(
        text: String,
        delivery: DictationDelivery,
        recovery: DictationStoppedAudioRecovery?
    ) -> Task<DictationTranscriptPersistenceResult, Never>
    func publishDictationTranscriptPersistence(
        _ result: DictationTranscriptPersistenceResult,
        delivery: DictationDelivery,
        context: [String: String]
    )
    func dictationContext(extra: [String: String]) -> [String: String]
}

/// An overlay message with an optional button, the shape of
/// `FloatingOverlayController.showError`.
typealias DictationShowMessage = @MainActor (_ message: String, _ actionTitle: String?, _ action: (() -> Void)?) -> Void

// MARK: - Start

extension DictationSessionPipelineHost {
    /// Runs `DictationStartAdmission` with this controller's state and shows
    /// why a refused press didn't start. True when the press became a new
    /// session; nothing about the new session is set before that.
    func admitDictationStart(
        sourceApp: NSRunningApplication?,
        trigger: DictationTrigger,
        shortcutMode: DictationShortcutMode?,
        isRetry: Bool
    ) -> Bool {
        let admission = DictationStartAdmission.decide(
            DictationStartAdmission.Steps(
                isDictating: { self.isDictating },
                rememberPressIfFinishing: {
                    self.rememberStartPressIfFinishing(
                        sourceApp: sourceApp,
                        trigger: trigger,
                        shortcutMode: shortcutMode,
                        isRetry: isRetry
                    )
                },
                showStartingIsland: { self.showIslandStartingState(near: sourceApp) },
                countRequest: { self.trackDictationStartRequested(trigger: trigger, isRetry: isRetry) },
                blocksNewCapture: {
                    DictationTerminationAdmissionPolicy.blocksNewCapture(
                        hasRecoverableRecording: self.dictationHasRecoverableRecording,
                        recoveryWAVExists: self.currentStoppedAudioRecoveryWAVExists
                    )
                },
                previousTakeIsTranscribing: { self.isPreviousTakeTranscribing },
                unavailableReason: { self.dictationStartUnavailableReason() },
                countRefusal: { refusal in
                    self.trackDictationStartRefused(trigger: trigger, failureKind: refusal.rawValue)
                },
                beginSession: { self.currentDictationSessionID = UUID() }
            )
        )
        switch admission {
        case .admitted:
            return true
        case .refused(.unsavedCaptureRecoveryPending, _):
            // A failed checkpoint may leave native audio as the only copy.
            // Starting a fresh capture would clear that timeline.
            showFailedCheckpointRecoveryError()
        case .refused(.previousDictationTranscribing, _):
            showDictationError("Still finishing the last dictation. Try again in a moment.")
        case .refused(.dictationUnavailable, let message):
            showDictationError(message ?? "")
        case .alreadyDictating, .queuedBehindFinishingTake:
            break
        }
        return false
    }

    /// A Try Again / Retry Dictation button restarting the failed take. It's
    /// marked as a retry, so four taps don't read as five separate attempts.
    func retryDictation(sourceApp: NSRunningApplication?, anchorRect: NSRect?) {
        startDictation(
            sourceApp: sourceApp,
            trigger: currentDictationTrigger,
            shortcutMode: nil,
            anchorRect: anchorRect,
            isRetry: true
        )
    }

    /// The start click, once per session, from whichever path gets there
    /// first: the key press on a built-in or wired mic, otherwise the moment
    /// recording starts.
    func playStartCueOnce() {
        guard !didPlayStartCue else { return }
        didPlayStartCue = true
        playDictationStartSound()
    }

    /// The ready-engine fast path: the start click (when it plays on the key
    /// press) is queued before the mic start task, so it never waits on the
    /// microphone opening. With `opensInThisTurn` the open starts in this
    /// turn instead of after the island's first frame commits; see
    /// `DictationFastStartLaunch`.
    func launchFastStart(
        startCuePlaysOnKeyPress: Bool,
        opensInThisTurn: Bool = false,
        openMicrophone: @escaping @MainActor () async -> Void
    ) {
        if startCuePlaysOnKeyPress {
            playStartCueOnce()
        }
        recordingStartRetryTask?.cancel()
        recordingStartRetryTask = nil
        if let handle = DictationFastStartLaunch.start(
            opensInThisTurn: opensInThisTurn,
            openMicrophone: openMicrophone
        ) {
            recordingStartRetryTask = handle
        }
    }

    /// What a native mic start runs when the open fails: try the foreground
    /// handshake once for this session (see `recoverBackgroundHotkeyStart`).
    func startFailureRecovery(sessionID: UUID) -> @MainActor () async -> Void {
        { [weak self] in
            await self?.recoverBackgroundHotkeyStart(sessionID: sessionID)
        }
    }

    /// A successful ordinary start never changes focus. Only a real native
    /// start failure can request this one recovery step for the current session.
    ///
    /// This is now the second line of defence, not the first: issue #1743's
    /// front-loaded preparation — the App Nap suppression assertion, taken
    /// before the first microphone open — is what a background start relies
    /// on. This stays for the case where the process was prepared and the
    /// open still failed.
    ///
    /// The guard reads `allowsForegroundActivationEscalation` rather than
    /// listing triggers inline as PR #1744 did. That list named
    /// `keyboardShortcut` and `rightOptionTap`, neither of which anything in
    /// the tree constructs, so it read as coverage it did not have.
    func recoverBackgroundHotkeyStart(sessionID: UUID) async {
        guard let usesMeetingMic = activeMeetingMicCheck,
              startActivationRecoveryGate.admit(
                  sessionID: sessionID,
                  currentSessionID: currentDictationSessionID,
                  isDictating: isDictating,
                  isCancelled: Task.isCancelled,
                  appIsActive: appIsActive,
                  allowsEscalation: currentStartReadinessProfile.allowsForegroundActivationEscalation,
                  usesMeetingMic: usesMeetingMic
              ) else { return }
        await prepareStartActivation(
            sourceApp: sessionSourceApp,
            isCurrent: { self.isDictating && self.currentDictationSessionID == sessionID }
        )
    }
}

// MARK: - Stop

/// The router and overlay calls the stop task makes before it has text.
struct DictationStopTranscriptionSteps<Snapshot> {
    var markStopRequested: @MainActor () -> Void
    var stopMicrophone: @MainActor () async -> Void
    var playStopCue: @MainActor () -> Void
    var snapshot: @MainActor () async -> Snapshot?
    /// Writes the private recovery WAV (nil when there was nothing to write).
    /// Runs off the main actor.
    var checkpointWork: @MainActor (Snapshot) -> @Sendable () throws -> DictationStoppedAudioRecovery?
    /// Deletes a WAV written for a session that is gone. Runs off the main actor.
    var discardWork: @MainActor (DictationStoppedAudioRecovery?) -> @Sendable () -> Void
    var hasRecoverableRecording: @MainActor () -> Bool
    /// Completes this stop's checkpoint signal.
    var checkpointSettled: @MainActor () async -> Void
    var reportCheckpointFailure: @MainActor (Error) -> Void
    var clearSession: @MainActor (_ outcome: String) -> Void
    /// `DictationPostStopModelWait.run` with the stage's session check.
    var waitForModel: @MainActor (_ isCurrent: @escaping @MainActor () -> Bool) async -> DictationPostStopModelWait.Result
    /// Logs and counts a model that never became ready.
    var reportModelUnavailable: @MainActor () -> Void
    var showMessage: DictationShowMessage
    var startTranscribing: @MainActor () -> Void
    var transcribe: @MainActor (_ preparedRecording: Snapshot?) async -> String?
    var now: @MainActor () -> CFAbsoluteTime
}

enum DictationStopTranscriptionOutcome: Equatable {
    /// The stop lost its session. Do nothing more.
    case abandoned
    /// The take ended with its message already shown (checkpoint or model failure).
    case ended
    /// The model ran; nil or empty text is an empty take.
    case transcribed(String?)
}

/// When each step of the stop happened, for stop-latency telemetry.
struct DictationStopTranscriptionMarks: Equatable {
    var checkpoint = DictationStopCheckpoint.Marks()
    var modelWaitStartedAt: CFAbsoluteTime?
    var modelReadyAt: CFAbsoluteTime?
    var transcriptionStartedAt: CFAbsoluteTime?
    var transcribedAt: CFAbsoluteTime?
}

extension DictationSessionPipelineHost {
    /// The stop task from the stale-task fence to the model's text:
    ///
    /// 1. A stop task that was cancelled or belongs to an older session does
    ///    nothing at all: no stop diagnostics, no mic stop.
    /// 2. `DictationStopCheckpoint` stops the mic, plays the stop click, and
    ///    writes the private WAV. A WAV written after the stop lost its
    ///    session is kept only if Quit marked that session for preservation.
    /// 3. A failed or impossible checkpoint ends the take with Retry Saving
    ///    before anything waits on the model.
    /// 4. Only then the model wait, then transcription of the snapshot the
    ///    checkpoint already made.
    func runStopUntilTranscribed<Snapshot>(
        taskSessionID: UUID,
        _ steps: DictationStopTranscriptionSteps<Snapshot>
    ) async -> (outcome: DictationStopTranscriptionOutcome, marks: DictationStopTranscriptionMarks) {
        var marks = DictationStopTranscriptionMarks()
        let isCurrent: @MainActor () -> Bool = {
            !Task.isCancelled && self.isDictating && self.currentDictationSessionID == taskSessionID
        }
        guard isCurrent() else { return (.abandoned, marks) }
        steps.markStopRequested()
        // The accepted stop request owns cancellation even if recovery
        // publishes a brief idle state before this task begins. The engine's
        // idle stop path invalidates any pending recovery restart.
        let checkpoint = await DictationStopCheckpoint.run(
            DictationStopCheckpoint.Steps<Snapshot, DictationStoppedAudioRecovery?>(
                isCurrent: {
                    DictationStoppedAudioRecoveryCommitPolicy.shouldPersist(
                        taskCancelled: Task.isCancelled,
                        isDictating: self.isDictating,
                        taskSessionID: taskSessionID,
                        currentSessionID: self.currentDictationSessionID
                    )
                },
                stopMicrophone: steps.stopMicrophone,
                playStopCue: steps.playStopCue,
                snapshot: steps.snapshot,
                checkpointWork: steps.checkpointWork,
                discardWork: steps.discardWork,
                keepAbandonedCheckpoint: {
                    DictationStoppedAudioRecoveryCommitPolicy.shouldRetainPersistedRecovery(
                        taskSessionID: taskSessionID,
                        preservationSessionID: self.stoppedAudioRecoveryPreservationSessionID
                    )
                },
                hasRecoverableRecording: steps.hasRecoverableRecording,
                now: steps.now
            )
        )
        marks.checkpoint = checkpoint.marks
        var preparedRecording: Snapshot?
        switch checkpoint.outcome {
        case .abandoned:
            return (.abandoned, marks)
        case .checkpointed(let recording, let recovery):
            stoppedAudioRecovery = recovery
            preparedRecording = recording
        case .noSnapshot:
            break
        case .checkpointUnavailable:
            endWithFailedCheckpoint(outcome: "audio_checkpoint_unavailable", steps.clearSession)
            return (.ended, marks)
        case .checkpointFailed(let error):
            steps.reportCheckpointFailure(error)
            endWithFailedCheckpoint(outcome: "audio_persistence_failed", steps.clearSession)
            return (.ended, marks)
        }

        await steps.checkpointSettled()
        guard isCurrent() else { return (.abandoned, marks) }

        // Surface model warmup honestly instead of calling it "Transcribing"
        // before the local dictation model is actually ready.
        let modelWait = await steps.waitForModel(isCurrent)
        switch modelWait.outcome {
        case .alreadyLoaded:
            marks.modelWaitStartedAt = marks.checkpoint.micStoppedAt
            marks.modelReadyAt = marks.checkpoint.micStoppedAt
        case .ready:
            marks.modelWaitStartedAt = modelWait.marks.waitStartedAt
            marks.modelReadyAt = modelWait.marks.readyAt
        case .abandoned:
            return (.abandoned, marks)
        case .unavailable:
            steps.reportModelUnavailable()
            // The wait told the user their recording was safe, so its saved
            // audio is offered whatever the take's length.
            if let recovery = stoppedAudioRecovery, recovery.sessionID == taskSessionID {
                let savedAudioAction = savedDictationAudioAction(for: recovery.url)
                steps.showMessage(
                    DictationPostStopModelWaitPolicy.modelUnavailableMessage(recordingSaved: true),
                    savedAudioAction.title,
                    savedAudioAction.action
                )
            } else {
                steps.showMessage(
                    DictationPostStopModelWaitPolicy.modelUnavailableMessage(recordingSaved: false),
                    nil,
                    nil
                )
            }
            isDictating = false
            steps.clearSession("model_unavailable")
            return (.ended, marks)
        }
        steps.startTranscribing()
        marks.transcriptionStartedAt = steps.now()
        let text = await steps.transcribe(preparedRecording)
        marks.transcribedAt = steps.now()
        guard isCurrent() else { return (.abandoned, marks) }
        return (.transcribed(text), marks)
    }

    /// The take's audio has no durable WAV. The session ends first, so the
    /// message can offer Retry Saving for the audio still in memory.
    private func endWithFailedCheckpoint(outcome: String, _ clearSession: @MainActor (String) -> Void) {
        isDictating = false
        clearSession(outcome)
        showFailedCheckpointRecoveryError()
    }

    /// A stop that arrived before the mic ever started recording: cancel the
    /// start and the speech engine (which drops any preserved recovery
    /// audio), end the session, and offer Try Again.
    func endStopBeforeCaptureStarted(
        inputFormatReady: Bool,
        cancelSpeechEngine: @MainActor () -> Void,
        report: @MainActor (_ failureKind: String) -> Void,
        showTimeout: @MainActor (_ retry: @escaping () -> Void) -> Void
    ) {
        recordingStartRetryTask?.cancel()
        recordingStartRetryTask = nil
        cancelSpeechEngine()
        let failureKind = inputFormatReady ? "microphone_start_failed" : "microphone_route_not_ready"
        report(failureKind)
        isDictating = false
        showTimeout { [weak self] in
            guard let self else { return }
            self.retryDictation(sourceApp: self.sessionSourceApp, anchorRect: nil)
        }
    }
}

// MARK: - Empty take

/// The overlay and telemetry calls for a take whose text came back empty.
struct DictationEmptyTakeSteps {
    var reason: DictationEmptyTranscriptionReason
    /// When the stop was requested; the press is measured from the session start.
    var stopRequestedAt: CFAbsoluteTime
    var sessionStartedAt: CFAbsoluteTime
    var heldBackText: @MainActor () -> String?
    /// Logs and counts the empty take.
    var report: @MainActor (DictationEmptyTranscriptPolicy.Decision) -> Void
    /// A mis-tap: close the overlay the same way a cancel does.
    var closeLikeCancel: @MainActor () -> Void
    var showNoSpeechAndDismiss: @MainActor () -> Void
    var showMessage: DictationShowMessage
    var showPasted: @MainActor () -> Void
    var clearSession: @MainActor (_ outcome: String) -> Void
}

extension DictationSessionPipelineHost {
    /// What a take with no text does, from `DictationEmptyTranscriptPolicy`.
    /// A mis-tap is judged by how long the key was held, not by how long
    /// transcription took.
    func finishEmptyTake(taskSessionID: UUID, _ steps: DictationEmptyTakeSteps) {
        let reason = steps.reason
        let decision = DictationEmptyTranscriptPolicy.decide(
            reason: reason,
            pressDuration: steps.stopRequestedAt - steps.sessionStartedAt,
            hasHeldBackText: steps.heldBackText() != nil,
            hasSavedRecording: stoppedAudioRecovery != nil,
            audioStillInMemory: dictationHasRecoverableRecording
        )
        steps.report(decision)
        let message = DictationNoSpeechPresentationPolicy.message(
            trigger: currentDictationTrigger.rawValue,
            reason: reason,
            shortcutMode: currentDictationShortcutMode,
            savedRecordingOffered: decision.action == .offerSavedRecording
        )
        switch decision.action {
        case .closeLikeCancel:
            // No "Recording ended too soon" error to dismiss.
            steps.closeLikeCancel()
        case .showNoSpeechAndDismiss:
            steps.showNoSpeechAndDismiss()
        case .offerPasteAnyway:
            // Probably a wrong-language guess, but the check can be
            // wrong, so the text is one press away and the audio stays.
            // Unreachable: decide() saw this text, and nothing between
            // it and here (all synchronous, on the main actor) clears it.
            guard let heldText = steps.heldBackText() else { break }
            steps.showMessage(
                message,
                DictationHeldTextActionCopy.pasteAnywayTitle,
                pasteHeldBackTextAction(
                    heldText,
                    recovery: stoppedAudioRecovery,
                    saveContext: dictationContext(extra: [:]),
                    taskSessionID: taskSessionID,
                    showPasted: steps.showPasted,
                    showError: { steps.showMessage($0, nil, nil) }
                )
            )
        case .offerSavedRecording:
            guard let recovery = stoppedAudioRecovery else { break }
            let savedAudioAction = savedDictationAudioAction(for: recovery.url)
            steps.showMessage(message, savedAudioAction.title, savedAudioAction.action)
        case .offerCheckpointRetry:
            // The captured audio has no durable WAV. If native RAM
            // remains, offer the guarded no-paste checkpoint retry
            // rather than mislabeling this as model-empty speech.
            isDictating = false
            showFailedCheckpointRecoveryError()
        case .showMessage:
            steps.showMessage(message, nil, nil)
        }
        isDictating = false
        steps.clearSession(reason.runtimeOutcome)
        if decision.discardsSavedRecording {
            discardStoppedAudioRecovery(transcriptPersisted: false, explicitDiscard: true)
        }
    }

    /// Paste Anyway on held-back text: paste it, then save it like any
    /// finished take (dictation history, Paste Last Dictation, and the kept
    /// audio cleaned up once the save lands).
    func pasteHeldBackTextAction(
        _ heldText: String,
        recovery: DictationStoppedAudioRecovery?,
        saveContext: [String: String],
        taskSessionID: UUID,
        showPasted: @escaping @MainActor () -> Void,
        showError: @escaping @MainActor (String) -> Void
    ) -> () -> Void {
        { [weak self] in
            guard let self else { return }
            let outcome = self.pasteWithClipboardRestore(heldText, followCurrentFocus: true)
            self.lastCompletedText = heldText
            let saveTask = self.startPersistingDictationTranscript(
                text: heldText,
                delivery: outcome.delivery,
                recovery: recovery
            )
            Task { @MainActor [weak self] in
                let result = await saveTask.value
                self?.publishDictationTranscriptPersistence(
                    result,
                    delivery: outcome.delivery,
                    context: saveContext
                )
            }
            // Pasting pumps the run loop; a take started meanwhile owns the pill.
            guard self.currentDictationSessionID == taskSessionID, !self.isDictating else { return }
            switch outcome {
            case .pasted, .likelyPasted:
                showPasted()
            case .copied(let message, reason: _), .failed(let message, reason: _):
                showError(message)
            }
        }
    }
}

// MARK: - Quit

extension DictationSessionPipelineHost {
    /// Quit while dictating, through `DictationTerminationFinisher`: stop the
    /// take and give it a grace period; if it's still going, mark its audio
    /// to be kept, wait (bounded) for its WAV checkpoint, and only then
    /// cancel it, keeping the audio.
    func finishDictationForTermination(
        gracePolls: Int = 100,
        pollNanoseconds: UInt64 = 100_000_000,
        checkpointTimeoutNanoseconds: UInt64 = 2_000_000_000
    ) async -> Bool {
        await DictationTerminationFinisher.run(
            DictationTerminationFinisher.Steps(
                setTerminating: { self.queuedStartGate.setTerminating($0) },
                dropQueuedStart: { self.dropQueuedDictationStart(showMessage: false) },
                isDictating: { self.isDictating },
                admitInactiveQuit: { self.admitInactiveDictationQuit() },
                stop: { self.stopDictationAndPaste(trigger: .unknown, shortcutMode: nil, autoPaste: true) },
                gracePolls: gracePolls,
                sleepOnePoll: {
                    do {
                        try await Task.sleep(nanoseconds: pollNanoseconds)
                        return true
                    } catch {
                        return false
                    }
                },
                preserveStoppedAudio: {
                    self.stoppedAudioRecoveryPreservationSessionID = self.currentDictationSessionID
                },
                waitForCheckpoint: {
                    guard let signal = self.stoppedAudioCheckpointSignal else { return false }
                    return await signal.waitForCompletion(timeoutNanoseconds: checkpointTimeoutNanoseconds)
                },
                canTerminateActive: {
                    DictationTerminationAdmissionPolicy.canTerminate(
                        isDictating: self.isDictating,
                        checkpointSettled: true,
                        hasRecoverableRecording: self.dictationHasRecoverableRecording,
                        recoveryWAVExists: self.currentStoppedAudioRecoveryWAVExists
                    )
                },
                showError: { self.showDictationError($0) },
                cancelPreservingStoppedAudio: { self.cancelDictation(preserveStoppedAudio: true) }
            )
        )
    }

    private func admitInactiveDictationQuit() -> Bool {
        let canTerminate = DictationTerminationAdmissionPolicy.canTerminate(
            isDictating: false,
            checkpointSettled: false,
            hasRecoverableRecording: dictationHasRecoverableRecording,
            recoveryWAVExists: currentStoppedAudioRecoveryWAVExists
        )
        if !canTerminate {
            queuedStartGate.setTerminating(false)
            showFailedCheckpointRecoveryError()
        }
        return canTerminate
    }
}

// MARK: - Fast-start launch

/// A plain `Task {}` made inside the key press's main-actor job only runs
/// after that job ends, which is after the island's first Core Animation
/// commit. `Task.immediate` runs the open's synchronous prefix right now, so
/// the pinned prepare reaches its coordinator alongside that commit (~3-5 ms
/// sooner on a physical-key start). The island's state is still set first;
/// its frame now commits right after the open's synchronous prefix (no HAL
/// work, well under a millisecond) instead of before it.
///
/// The caller gates it (`opensInThisTurn`). Off for a borrowed meeting mic
/// (no coordinator hop to win, and it can finish without suspending), the
/// first start since launch (it can register the default-input listener on
/// main against a cold HAL), and an unloaded model (the prefix may tear down
/// and check caches). Those keep the deferred task.
@MainActor
enum DictationFastStartLaunch {
    /// Set once the open has run to the end.
    @MainActor private final class Attempt {
        var finished = false
    }

    /// Starts the open and returns the handle to keep as the in-flight start,
    /// or nil when the open already finished before this returned. A finished
    /// open has already run `finishRecordingStart` (or its failure path), so
    /// storing its task would make a later key release read as a start that is
    /// still pending.
    static func start(
        opensInThisTurn: Bool,
        openMicrophone: @escaping @MainActor () async -> Void
    ) -> Task<Void, Never>? {
        guard opensInThisTurn else {
            return Task { @MainActor in await openMicrophone() }
        }
        let attempt = Attempt()
        let task = Task.immediate { @MainActor in
            await openMicrophone()
            attempt.finished = true
        }
        return attempt.finished ? nil : task
    }
}
