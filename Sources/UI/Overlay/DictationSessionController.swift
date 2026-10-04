// DictationSessionController.swift
// Session orchestration for dictation mode.

import AppKit
import AVFoundation
import Combine

@MainActor
class DictationSessionController: ObservableObject {
    /// Issue #1743: the App Nap suppression assertion is balanced on this
    /// property's transitions rather than on individual start/stop paths.
    /// A dictation session ends in a dozen different places (success, cancel,
    /// early release, interruption, permission failure, start timeout) and
    /// every one of them already flips this flag, so keying the assertion
    /// here is what makes "the microphone is opening" and "the process is not
    /// nappable" the same fact. Take it before any audio work begins, in
    /// `startDictation`, so a background hotkey start prepares the process the
    /// way a menu start already has by being frontmost.
    @Published var isDictating = false {
        didSet {
            guard oldValue != isDictating else { return }
            if isDictating {
                processActivity.acquire(reason: processActivityLabel.reason)
            } else {
                processActivity.release()
                processActivityLabel.sessionEnded()
                DictationAudioMuffler.shared.micClosed()
            }
        }
    }
    @Published var lastCompletedText: String?

    // Session state below is internal only so the DictationSessionController+*.swift
    // extensions can share it. It is not for use outside the controller.
    private var interruptionSubscription: AnyCancellable?
    private var muffleSubscription: AnyCancellable?
    let textPaster = ClipboardRestoringTextPaster()
    let autoSender = DictationAutoSender()
    /// Owns the engine-facing half of a dictation session: the recovery
    /// wait-loop state machine and the other STTRouter control-flow
    /// decisions. See Sources/Speech/DictationSession.swift.
    let dictationSession = DictationSession()
    let startActivation = DictationStartActivation()
    var startActivationRecoveryGate = DictationStartActivationRecoveryGate()
    /// App Nap suppression held for the length of a session. See the note on
    /// `isDictating` for why it is balanced there.
    private let processActivity = DictationProcessActivity.shared
    /// The readiness plan for the session currently starting. Set before
    /// `isDictating` flips so the App Nap assertion and the diagnostics both
    /// describe the same start.
    var currentStartReadinessProfile = DictationStartReadinessProfile.foreground

    /// The label the App Nap assertion is taken under, which is what shows up
    /// in Activity Monitor and `powermetrics`.
    ///
    /// Kept separate from `currentStartReadinessProfile` because `isDictating`
    /// also flips true at the two stop-finalization readmissions, which
    /// re-enter a retained recording rather than opening the microphone. They
    /// carry no readiness profile of their own, so the label goes back to
    /// "stop finalization" whenever a session ends. See
    /// `DictationProcessActivityLabel`.
    private var processActivityLabel = DictationProcessActivityLabel()

    /// What the pending start is waiting on right now, and since when.
    ///
    /// Issue #1743: `pending_for_ms` on the cancel event says how long a start
    /// had been running when the user's hotkey ended it, but not what it was
    /// doing with that time. A start can sit in a microphone-permission
    /// prompt, a model warmup, an audio-route recovery wait, or the CoreAudio
    /// open itself, and those point at four different bugs. This names which,
    /// so a reporter's log line is readable without a debugger attached.
    var pendingStartStage = DictationPendingStartStageClock(now: CFAbsoluteTimeGetCurrent())

    func enterPendingStartStage(_ stage: DictationPendingStartStage) {
        pendingStartStage.enter(stage, now: CFAbsoluteTimeGetCurrent())
    }

    /// Sends a saved dictation recording through the same import as
    /// Capture → Transcribe Audio File. Wired by the app delegate; without it
    /// the recovery messages fall back to showing the file in Finder.
    var onTranscribeSavedAudio: ((URL) -> Void)?

    var appState: TranscriptedAppState? {
        didSet { setupInterruptionObserver() }
    }
    var overlayController: FloatingOverlayController? {
        didSet {
            oldValue?.onActionableMessageDiscarded = nil
            textPaster.discardPasteRetry()
            overlayController?.onEscapeDuringSession = { [weak self] in
                guard let self else { return }
                guard self.isDictating else {
                    self.overlayController?.dismissError()
                    return
                }
                self.cancelDictation()
            }
            overlayController?.onStopListening = { [weak self] in
                guard let self = self, self.isDictating else { return }
                self.stopDictationAndPaste(trigger: .overlayButton)
            }
            overlayController?.onActionableMessageDiscarded = { [weak self] in
                self?.textPaster.discardPasteRetry()
            }
            // Any Esc, including the first of "press again to discard",
            // takes back a start that is waiting on this take.
            overlayController?.onEscapeKeyDuringSession = { [weak self] in
                self?.dropQueuedDictationStart(showMessage: false)
            }
        }
    }

    /// Unwrap both required dependencies or log a warning and return nil.
    func readyState() -> (TranscriptedAppState, FloatingOverlayController)? {
        guard let appState = appState, let overlayController = overlayController else {
            EventReporter.shared.capture(level: .warning, engine: "overlay", event: "session_not_wired",
                message: "appState or overlayController not set")
            return nil
        }
        return (appState, overlayController)
    }

    var sessionSourceApp: NSRunningApplication?
    var sessionPasteTarget: DictationPasteTarget?
    var sessionAnchorRect: NSRect?
    var startupTask: Task<Void, Never>?
    var streamingTask: Task<Void, Never>?
    var stopFinalizationGate = DictationStopFinalizationGate()
    var recordingStartRetryTask: Task<Void, Never>?
    var sessionTimeoutTask: Task<Void, Never>?
    var sessionStartTime: CFAbsoluteTime = 0
    var currentRequestIsFirstSinceLaunch = false
    var currentDictationTrigger: DictationTrigger = .unknown
    var currentDictationSessionID = UUID()
    /// Whether this session's start click has played. It plays once, on key
    /// press or after recording starts (see `DictationStartCuePolicy`).
    var didPlayStartCue = false
    /// The shortcut that started this session, when a shortcut did. Read from
    /// the press itself, never from `HotkeyPreferences.dictationShortcutMode()`.
    var currentDictationShortcutMode: DictationShortcutMode?
    var stoppedAudioRecovery: DictationStoppedAudioRecovery?
    var stoppedAudioRecoveryPreservationSessionID: UUID?
    var stoppedAudioCheckpointSignal: DictationStoppedAudioCheckpointSignal?
    var autoSendRequestDecision = DictationAutoSendRequestDecision.notEvaluated
    /// A start-shortcut press that landed while the last take was still
    /// finishing. It starts as soon as that take is done. See
    /// `DictationQueuedStartPolicy`.
    struct QueuedDictationStart {
        let sourceApp: NSRunningApplication?
        let trigger: DictationTrigger
        let shortcutMode: DictationShortcutMode
        let isRetry: Bool
        let requestedAt: TimeInterval
    }
    var queuedDictationStart: QueuedDictationStart?
    var queuedDictationStartTask: Task<Void, Never>?
    /// Shut while Quit waits for a take to finish, so a press then can't
    /// queue a new recording during shutdown.
    var queuedStartGate = DictationQueuedStartGate()

    deinit {
        startupTask?.cancel()
        streamingTask?.cancel()
        recordingStartRetryTask?.cancel()
        sessionTimeoutTask?.cancel()
        queuedDictationStartTask?.cancel()
    }

    private func setupInterruptionObserver() {
        guard let appState = appState else { return }
        interruptionSubscription = appState.sttRouter.$recordingInterrupted
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in
                guard let self = self, self.isDictating else { return }
                self.handleDictationInterruption()
            }
        muffleSubscription = makeDictationMuffleSubscription(appState: appState)
    }

    // MARK: - Dictation Mode (Option+Space)

    /// Start dictation — show overlay and begin voice recording (no screenshot/vision)
    /// - Parameter isRetry: `true` when the caller is one of this controller's own
    ///   error-alert actions ("Try Again", "Retry Dictation", the microphone
    ///   permission recovery action) rather than a fresh request from a
    ///   hotkey, the menu bar, or onboarding. Those actions all pass the
    ///   failed attempt's `currentDictationTrigger` back in, so `trigger`
    ///   alone cannot tell a retry apart from the press that preceded it, and
    ///   a user who taps Try Again four times would otherwise read as five
    ///   independent attempts in the denominator.
    func startDictation(
        sourceApp: NSRunningApplication?,
        trigger: DictationTrigger = .unknown,
        shortcutMode: DictationShortcutMode? = nil,
        anchorRect: NSRect? = nil,
        isRetry: Bool = false
    ) {
        let requestStartedAt = CFAbsoluteTimeGetCurrent()
        guard let (appState, overlayController) = readyState() else { return }
        // DictationStartAdmission (run by `admitDictationStart` in
        // DictationSessionPipeline.swift) decides whether this press becomes
        // a take and counts it: a press while already dictating or queued
        // behind a finishing take isn't counted yet; every other press is
        // counted (`dictation_start_requested`, the attempt denominator)
        // before any guard can refuse it and before the session id is
        // minted. A refused press shows why and changes nothing below.
        guard admitDictationStart(
            sourceApp: sourceApp,
            trigger: trigger,
            shortcutMode: shortcutMode,
            isRetry: isRetry
        ) else { return }
        // Issue #1743: decide the readiness plan BEFORE `isDictating` flips,
        // because that flip takes the App Nap suppression assertion and its
        // reason string names the plan.
        //
        // `NSApp.isActive` here is a synchronous sample of "was Transcripted
        // frontmost the instant the start was requested". It is deliberately
        // not a prediction about the rest of the start: the menu path calls
        // `sourceApp?.activate` on the line before `startDictation`, and
        // AppKit activation is asynchronous, so a menu start still samples as
        // foreground and then hands focus away while the microphone opens.
        // What the sample stands in for is "the process was in use a moment
        // ago", which is what decides whether App Nap has had the chance to
        // demote it.
        let startedInForeground = NSApp.isActive
        currentStartReadinessProfile = DictationStartReadinessPolicy.profile(
            triggerRawValue: trigger.rawValue,
            isAppActive: startedInForeground
        )
        processActivityLabel.startingMicrophone(currentStartReadinessProfile)
        isDictating = true
        enterPendingStartStage(.startRequested)
        didPlayStartCue = false
        stopFinalizationGate.reset()
        dictationSession.startReadinessProfile = currentStartReadinessProfile
        dictationSession.telemetryContext = [
            "session_id": currentDictationSessionID.uuidString,
            "correlation_id": currentDictationSessionID.uuidString,
            "trigger": trigger.rawValue,
            "start_plan": currentStartReadinessProfile.name,
        ]
        stoppedAudioRecovery = nil
        stoppedAudioRecoveryPreservationSessionID = nil
        stoppedAudioCheckpointSignal = nil
        sessionSourceApp = sourceApp
        sessionPasteTarget = DictationPasteTarget.capture(sourceApp: sourceApp)
        sessionAnchorRect = anchorRect
        sessionStartTime = requestStartedAt
        currentDictationTrigger = trigger
        currentDictationShortcutMode = shortcutMode
        autoSendRequestDecision = .notEvaluated
        lastCompletedText = nil
        appState.runtimeDiagnostics.recordSession(kind: "dictation", stage: "start_requested")
        recordStartReadinessPrepared(
            appState: appState,
            trigger: trigger,
            shortcutMode: shortcutMode,
            isAppActive: startedInForeground
        )

        switch TranscriptedPermissionAccess.microphoneAuthorizationStatus() {
        case .authorized:
            continueDictationStart(
                appState: appState,
                sourceApp: sourceApp
            )
        case .notDetermined:
            enterPendingStartStage(.awaitingMicrophonePermission)
            overlayController.showLoadingState(
                near: sourceApp,
                presentation: microphonePermissionPresentation(),
                anchorRect: anchorRect
            )
            startupTask?.cancel()
            startupTask = Task { @MainActor [weak self] in
                guard let self else { return }
                let granted = await TranscriptedPermissionAccess.requestMicrophoneAccessIfNeeded()
                guard !Task.isCancelled, self.isDictating else { return }
                self.startupTask = nil
                if granted {
                    self.continueDictationStart(
                        appState: appState,
                        sourceApp: sourceApp
                    )
                } else {
                    self.presentMicrophonePermissionError(
                        TranscriptedPermissionAccess.microphoneAuthorizationStatus(),
                        sourceApp: sourceApp
                    )
                }
            }
        case .denied, .restricted:
            presentMicrophonePermissionError(
                TranscriptedPermissionAccess.microphoneAuthorizationStatus(),
                sourceApp: sourceApp
            )
        @unknown default:
            presentMicrophonePermissionError(
                TranscriptedPermissionAccess.microphoneAuthorizationStatus(),
                sourceApp: sourceApp
            )
        }
    }

    /// One line per start saying how the process was prepared, so a report
    /// like issue #1743 can be answered from Console instead of guesswork.
    ///
    /// Deliberately carries no "app nap suppressed" flag. This runs after
    /// `isDictating = true`, and that flip is what takes the assertion, so
    /// such a flag would read `true` on every line ever logged and tell a
    /// reporter nothing. `app_nap_holders` is the refcount, which does vary —
    /// greater than one means another session was still holding the
    /// assertion when this start began.
    private func recordStartReadinessPrepared(
        appState: TranscriptedAppState,
        trigger: DictationTrigger,
        shortcutMode: DictationShortcutMode?,
        isAppActive: Bool
    ) {
        let extra = DictationStartReadinessPolicy.preparedDiagnostics(
            triggerRawValue: trigger.rawValue,
            isAppActive: isAppActive,
            profile: currentStartReadinessProfile,
            appNapHolders: processActivity.holderCount,
            shortcutMode: shortcutMode
        )
        DiagnosticsTrail.record(
            logger: appState.logger,
            engine: "dictation",
            event: "dictation_start_readiness_prepared",
            message: "Prepared dictation start readiness before opening the microphone",
            context: dictationContext(extra: extra)
        )
    }

    private func recordDictationStarted(
        appState: TranscriptedAppState,
        trigger: DictationTrigger
    ) {
        let requestToRecordingMs = max(0, Int((CFAbsoluteTimeGetCurrent() - sessionStartTime) * 1_000))
        DiagnosticsTrail.record(
            logger: appState.logger,
            engine: "dictation",
            event: "dictation_started",
            message: "Dictation started",
            context: dictationContext(
                extra: [
                    "trigger": trigger.rawValue,
                    "request_to_recording_ms": "\(requestToRecordingMs)"
                ]
            )
        )
        // `start_latency_bucket` is the off-device twin of
        // `request_to_recording_ms`: how long the user waited between asking
        // and the mic recording. It is the one field `dictation_start_requested`
        // cannot carry, since the request fires before anything has started.
        AnalyticsReporter.track(
            "dictation_started",
            properties: dictationAnalyticsProperties(
                extra: [
                    "trigger": trigger.rawValue,
                    "start_latency_bucket": AnalyticsReporter.latencyBucket(milliseconds: requestToRecordingMs),
                    "start_latency_ms": MachineClassTelemetry.roundedMilliseconds(requestToRecordingMs),
                    "first_since_launch": currentRequestIsFirstSinceLaunch ? "true" : "false",
                ].merging(dictationSpeedContext(appState: appState)) { current, _ in current }
            )
        )
    }

    /// The tail every successful microphone start shares, fast path and
    /// recovery loop alike. See `DictationRecordingStarted`.
    func finishRecordingStart(
        appState: TranscriptedAppState,
        afterRecordingStarted: @escaping @MainActor () -> Void = {}
    ) {
        DictationRecordingStarted.finish(DictationRecordingStarted.Steps(
            clearStartHandle: { self.recordingStartRetryTask = nil },
            recordStarted: {
                self.recordDictationStarted(appState: appState, trigger: self.currentDictationTrigger)
                afterRecordingStarted()
            },
            playStartCue: { self.playStartCueOnce() },
            installSessionTimeout: { self.installSessionTimeout() }
        ))
    }

    /// This session's id while it is dictating, for a caller that needs to
    /// act on this exact session later.
    var activeDictationSessionID: UUID? {
        isDictating ? currentDictationSessionID : nil
    }

    /// Cancel dictation without pasting
    func cancelDictation(preserveStoppedAudio: Bool = false) {
        guard let (appState, overlayController) = readyState() else { return }
        // Esc on a finishing take means stop, not "and start the next one".
        dropQueuedDictationStart(showMessage: false)
        if preserveStoppedAudio {
            stoppedAudioRecoveryPreservationSessionID = currentDictationSessionID
        }
        cancelActiveTasks(cancelRecording: true)
        if !preserveStoppedAudio {
            discardStoppedAudioRecovery(explicitDiscard: true)
            // The "discarded" cue only when something was actually thrown away;
            // a quit that keeps the audio stays silent.
            AppSoundPlayer.shared.play(.dictationCancelled)
        }
        overlayController.hideWithCancelAnimation()
        isDictating = false
        appState.runtimeDiagnostics.clearSession(kind: "dictation", outcome: "cancelled")
        appState.logger.log("DICTATION | cancelled")
        DiagnosticsTrail.record(
            logger: appState.logger,
            level: .info,
            engine: "dictation",
            event: "dictation_cancelled",
            message: "Dictation cancelled",
            context: dictationContext(
                extra: [
                    "trigger": currentDictationTrigger.rawValue,
                    "duration_ms": "\(Int((CFAbsoluteTimeGetCurrent() - sessionStartTime) * 1000))"
                ]
            )
        )
        if currentDictationTrigger == .onboarding {
            NotificationCenter.default.post(name: .dictationNoSpeechDetected, object: nil)
        }
        AnalyticsReporter.track(
            "dictation_cancelled",
            properties: dictationAnalyticsProperties(
                extra: [
                    "duration_bucket": AnalyticsReporter.durationBucket(seconds: CFAbsoluteTimeGetCurrent() - sessionStartTime),
                    "trigger": currentDictationTrigger.rawValue,
                ]
            )
        )
        ProductFrictionTelemetry.track(
            surface: .dictation,
            stage: "dictation_recording",
            result: .cancelled,
            failureKind: "user_cancelled",
            elapsedBucket: AnalyticsReporter.durationBucket(seconds: CFAbsoluteTimeGetCurrent() - sessionStartTime),
            routeShape: dictationAnalyticsProperties()["route_shape"],
            modelState: ProductFrictionTelemetry.modelState(isReady: appState.sttRouter.isModelLoaded)
        )
    }

    func cancelActiveTasks(cancelRecording: Bool) {
        startActivation.cancel()
        let recordingStartWasInFlight = recordingStartRetryTask != nil
        let sttIsRecording = appState?.sttRouter.isRecording ?? false
        let sttIsTranscribing = appState?.sttRouter.isTranscribing ?? false
        let cancellationPlan = DictationActiveTaskCancellationPolicy.plan(
            cancelRecording: cancelRecording,
            recordingStartWasInFlight: recordingStartWasInFlight,
            sttIsRecording: sttIsRecording,
            sttIsTranscribing: sttIsTranscribing
        )

        startupTask?.cancel()
        startupTask = nil
        if cancellationPlan.cancelStreamingTask {
            streamingTask?.cancel()
            streamingTask = nil
        }
        textPaster.restorePendingClipboardNow()
        recordingStartRetryTask?.cancel()
        recordingStartRetryTask = nil
        sessionTimeoutTask?.cancel()
        sessionTimeoutTask = nil
        clearSessionCapCountdown()

        guard cancellationPlan.cancelSpeechEngine,
              let appState else { return }
        dictationSession.cancelEngine(appState: appState)
    }
}

// The start/stop wiring in DictationSessionPipeline.swift runs on this
// controller through DictationSessionPipelineHost; the tests run it on a fake.
// Most requirements are the controller's own members; these adapt the rest.
extension DictationSessionController: DictationSessionPipelineHost {
    var appIsActive: Bool { NSApp.isActive }

    var isPreviousTakeTranscribing: Bool { appState?.sttRouter.isTranscribing ?? false }

    var dictationHasRecoverableRecording: Bool { appState?.sttRouter.hasRecoverableRecording ?? false }

    func showIslandStartingState(near sourceApp: NSRunningApplication?) {
        overlayController?.showIslandStartingStateIfSelected(near: sourceApp)
    }

    func trackDictationStartRequested(trigger: DictationTrigger, isRetry: Bool) {
        guard let appState else { return }
        trackDictationStartRequested(appState: appState, trigger: trigger, isRetry: isRetry)
    }

    func trackDictationStartRefused(trigger: DictationTrigger, failureKind: String) {
        guard let appState else { return }
        trackDictationStartRefused(appState: appState, trigger: trigger, failureKind: failureKind)
    }

    func dictationStartUnavailableReason() -> String? {
        guard let appState else { return nil }
        return dictationStartUnavailableReason(appState: appState)
    }

    func playDictationStartSound() {
        AppSoundPlayer.shared.play(.dictationStart)
    }

    func prepareStartActivation(sourceApp: NSRunningApplication?, isCurrent: () -> Bool) async {
        _ = await startActivation.prepare(sourceApp: sourceApp, isCurrent: isCurrent)
    }

    func showDictationError(_ message: String) {
        overlayController?.showError(message)
    }
}

// DictationReadinessRefreshRunner and DictationReadinessRefreshTimeout moved
// to Sources/Speech/DictationSession.swift along with the recovery wait loop
// that owns them.
