// DictationSessionController.swift
// Session orchestration for dictation mode.

import AppKit
import AVFoundation
import Combine

@MainActor
class DictationSessionController: ObservableObject {
    enum DictationTrigger: String {
        case rightOptionTap = "right_option_tap"
        case physicalKey = "physical_key"
        case keyboardShortcut = "keyboard_shortcut"
        case overlayButton = "overlay_button"
        case menu = "menu"
        case onboarding = "onboarding"
        case sessionCap = "session_cap"
        case unknown = "unknown"
    }

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
                processActivity.acquire(
                    reason: "Transcripted dictation capture (\(processActivityLabel))"
                )
            } else {
                processActivity.release()
            }
        }
    }
    @Published var lastCompletedText: String?

    private var interruptionSubscription: AnyCancellable?
    private let textPaster = ClipboardRestoringTextPaster()
    private let autoSender = DictationAutoSender()
    /// Owns the engine-facing half of a dictation session: the recovery
    /// wait-loop state machine and the other STTRouter control-flow
    /// decisions. See Sources/Speech/DictationSession.swift.
    private let dictationSession = DictationSession()
    private let startActivation = DictationStartActivation()
    private var didAttemptStartActivation = false
    /// App Nap suppression held for the length of a session. See the note on
    /// `isDictating` for why it is balanced there.
    private let processActivity = DictationProcessActivity.shared
    /// The readiness plan for the session currently starting. Set before
    /// `isDictating` flips so the App Nap assertion and the diagnostics both
    /// describe the same start.
    private var currentStartReadinessProfile = DictationStartReadinessProfile.foreground

    /// The label the App Nap assertion is taken under, which is what shows up
    /// in Activity Monitor and `powermetrics`.
    ///
    /// Kept separate from `currentStartReadinessProfile` because `isDictating`
    /// also flips true at the two stop-finalization readmissions, which
    /// re-enter a retained recording rather than opening the microphone. They
    /// carry no readiness profile of their own, and reusing the previous
    /// start's name there would put a stale, wrong word in front of a user
    /// looking at why an app is holding a power assertion.
    private var processActivityLabel = DictationStartReadinessProfile.foreground.name

    /// What the pending start is waiting on right now, and since when.
    ///
    /// Issue #1743: `pending_for_ms` on the cancel event says how long a start
    /// had been running when the user's hotkey ended it, but not what it was
    /// doing with that time. A start can sit in a microphone-permission
    /// prompt, a model warmup, an audio-route recovery wait, or the CoreAudio
    /// open itself, and those point at four different bugs. This names which,
    /// so a reporter's log line is readable without a debugger attached.
    private var pendingStartStage = DictationSessionController.idleStartStage
    private var pendingStartStageEnteredAt = CFAbsoluteTimeGetCurrent()

    private static let idleStartStage = "idle"

    private func enterPendingStartStage(_ stage: String) {
        pendingStartStage = stage
        pendingStartStageEnteredAt = CFAbsoluteTimeGetCurrent()
    }

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
        }
    }

    /// Unwrap both required dependencies or log a warning and return nil.
    private func readyState() -> (TranscriptedAppState, FloatingOverlayController)? {
        guard let appState = appState, let overlayController = overlayController else {
            EventReporter.shared.capture(level: .warning, engine: "overlay", event: "session_not_wired",
                message: "appState or overlayController not set")
            return nil
        }
        return (appState, overlayController)
    }

    private var sessionSourceApp: NSRunningApplication?
    private var sessionPasteTarget: DictationPasteTarget?
    private var sessionAnchorRect: NSRect?
    private var startupTask: Task<Void, Never>?
    private var streamingTask: Task<Void, Never>?
    private var stopFinalizationGate = DictationStopFinalizationGate()
    private var recordingStartRetryTask: Task<Void, Never>?
    private var sessionTimeoutTask: Task<Void, Never>?
    private var sessionStartTime: CFAbsoluteTime = 0
    /// Whether any dictation has been requested since this process launched.
    /// The first one is where a cold start shows (models warming at launch,
    /// the first mic bind), so both start events say whether they are it.
    private static var hasRequestedDictationThisLaunch = false
    private var currentRequestIsFirstSinceLaunch = false
    private var currentDictationTrigger: DictationTrigger = .unknown
    private var currentDictationSessionID = UUID()
    private var stoppedAudioRecovery: DictationStoppedAudioRecovery?
    private var stoppedAudioRecoveryPreservationSessionID: UUID?
    private var stoppedAudioCheckpointSignal: DictationStoppedAudioCheckpointSignal?
    private var autoSendRequestDecision = DictationAutoSendRequestDecision.notEvaluated

    /// Max duration for a listening session before auto-cancel (5 minutes).
    /// Prevents stuck sessions when the user walks away from the computer.
    /// Derived from the shared constant so the speech engine's audio buffer
    /// sizing stays in lockstep with the cap.
    private static let sessionTimeoutNanos: UInt64 =
        UInt64(TranscriptedConstants.dictationSessionMaxDuration * 1_000_000_000)
    private static let sessionTimeoutInterval: TimeInterval =
        TranscriptedConstants.dictationSessionMaxDuration
    /// Cap on each polling sleep so a wake from system sleep gets a chance to
    /// re-evaluate the uptime-based deadline before firing the cancel branch.
    private static let sessionTimeoutPollIntervalNanos: UInt64 = 30 * 1_000_000_000

    deinit {
        startupTask?.cancel()
        streamingTask?.cancel()
        recordingStartRetryTask?.cancel()
        sessionTimeoutTask?.cancel()
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
    }

    func presentPendingStoppedAudioRecoveryIfNeeded() {
        guard !isDictating,
              let overlayController,
              let recovery = DictationStoppedAudioRecoveryStore.pendingRecoveries(limit: 1).first else { return }
        overlayController.showError(
            "A stopped dictation recording is available. Retry it with Capture → Transcribe Audio File in Transcripted.",
            actionTitle: "Show Audio",
            action: {
                NSWorkspace.shared.activateFileViewerSelecting([recovery.url])
            }
        )
    }

    // MARK: - Dictation Mode (Option+Space)

    /// Start dictation — show overlay and begin voice recording (no screenshot/vision)
    /// - Parameter isRetry: `true` when the caller is one of this file's own
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
        guard !isDictating else { return }
        // The attempt denominator.
        //
        // `dictation_started` is emitted only once the microphone is actually
        // open, so a failure count measured against it is failures per
        // success, not failures per attempt. That is why 1.1.59's 21 logged
        // startup failures could not be turned into a rate: there was no
        // count of how many starts were asked for. This fires before the
        // three admission guards below and before any permission, model, or
        // audio work, so every request a user made is counted — including the
        // ones refused outright, which until now emitted nothing at all.
        //
        // It deliberately carries no session id. The session UUID is minted
        // further down, past the guards, and stamping the previous session's
        // id on a request that may never get one would read as correlation
        // that does not exist.
        trackDictationStartRequested(appState: appState, trigger: trigger, isRetry: isRetry)
        guard !DictationTerminationAdmissionPolicy.blocksNewCapture(
            hasRecoverableRecording: appState.sttRouter.hasRecoverableRecording,
            recoveryWAVExists: currentStoppedAudioRecoveryWAVExists
        ) else {
            // A failed checkpoint may leave native audio as the only copy.
            // Starting a fresh capture would clear that timeline.
            trackDictationStartRefused(
                appState: appState,
                trigger: trigger,
                failureKind: "unsaved_capture_recovery_pending"
            )
            showFailedCheckpointRecoveryError()
            return
        }
        guard !appState.sttRouter.isTranscribing else {
            trackDictationStartRefused(
                appState: appState,
                trigger: trigger,
                failureKind: "previous_dictation_transcribing"
            )
            overlayController.showError("Still finishing the last dictation. Try again in a moment.")
            return
        }
        if let unavailableReason = dictationStartUnavailableReason(appState: appState) {
            trackDictationStartRefused(
                appState: appState,
                trigger: trigger,
                failureKind: "dictation_unavailable"
            )
            overlayController.showError(unavailableReason)
            return
        }
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
        processActivityLabel = currentStartReadinessProfile.name
        isDictating = true
        enterPendingStartStage("start_requested")
        currentDictationSessionID = UUID()
        didAttemptStartActivation = false
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
            enterPendingStartStage("awaiting_microphone_permission")
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
        let profile = currentStartReadinessProfile
        var extra = [
            "trigger": trigger.rawValue,
            "app_active": "\(isAppActive)",
            "start_plan": profile.name,
            "app_nap_holders": "\(processActivity.holderCount)",
            "activation_escalation_allowed": "\(profile.allowsForegroundActivationEscalation)"
        ]
        if let shortcutMode {
            extra["shortcut_mode"] = shortcutMode.rawValue
        }
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
                    "first_since_launch": currentRequestIsFirstSinceLaunch ? "true" : "false",
                ]
            )
        )
    }

    /// Every dictation start a user asked for, emitted before anything can
    /// refuse or fail it. This is the denominator `dictation_started` cannot
    /// be: see the note at the call site in `startDictation`.
    ///
    /// `model_state` is sampled here rather than inferred later because a
    /// start that arrives while the model is still warming up fails for a
    /// different reason than one that arrives against a ready engine, and by
    /// the time a failure is reported the state has usually moved on.
    private func trackDictationStartRequested(
        appState: TranscriptedAppState,
        trigger: DictationTrigger,
        isRetry: Bool
    ) {
        currentRequestIsFirstSinceLaunch = !Self.hasRequestedDictationThisLaunch
        Self.hasRequestedDictationThisLaunch = true
        var properties = appState.sttRouter.dictationAudioRouteAnalyticsContext
        properties["trigger"] = trigger.rawValue
        properties["start_retry"] = isRetry ? "true" : "false"
        properties["first_since_launch"] = currentRequestIsFirstSinceLaunch ? "true" : "false"
        properties["model_state"] = ProductFrictionTelemetry.modelState(
            isReady: appState.sttRouter.isModelLoaded
        )

        AnalyticsReporter.track(
            "dictation_start_requested",
            properties: properties
        )
        DiagnosticsTrail.record(
            logger: appState.logger,
            engine: "dictation",
            event: "dictation_start_requested",
            message: "Dictation start requested",
            context: properties
        )
    }

    /// A start request refused by one of `startDictation`'s admission guards,
    /// before a session exists.
    ///
    /// It does not route through `trackDictationStartFailed` because that
    /// helper stamps `currentDictationSessionID`, which at this point still
    /// belongs to the *previous* dictation. A refused request has no session
    /// of its own, and borrowing the last one's id would invent a correlation
    /// that is not there. `start_attempt_bucket` is `"0"` for the same reason
    /// the permission failures report it that way: no microphone start was
    /// ever attempted.
    private func trackDictationStartRefused(
        appState: TranscriptedAppState,
        trigger: DictationTrigger,
        failureKind: String
    ) {
        var properties = appState.sttRouter.dictationAudioRouteAnalyticsContext
        properties["start_attempt_bucket"] = "0"
        emitDictationStartFailed(
            failureKind,
            properties: properties,
            trigger: trigger
        )
    }

    private func trackDictationStartFailed(
        _ failureKind: String,
        extra: [String: String] = [:]
    ) {
        emitDictationStartFailed(
            failureKind,
            properties: dictationAnalyticsProperties(extra: extra),
            trigger: currentDictationTrigger
        )
    }

    private func emitDictationStartFailed(
        _ failureKind: String,
        properties: [String: String],
        trigger: DictationTrigger
    ) {
        var analyticsProperties = properties
        analyticsProperties["failure_kind"] = failureKind
        analyticsProperties["trigger"] = trigger.rawValue

        AnalyticsReporter.track(
            "dictation_start_failed",
            properties: analyticsProperties
        )
        ProductFrictionTelemetry.track(
            surface: .dictation,
            stage: "dictation_start",
            result: .blocked,
            failureKind: failureKind,
            routeShape: analyticsProperties["route_shape"],
            modelState: ProductFrictionTelemetry.modelState(isReady: appState?.sttRouter.isModelLoaded),
            context: analyticsProperties
        )
    }

    private func dictationStartFailureKind(for status: AVAuthorizationStatus) -> String {
        switch status {
        case .denied:
            return "microphone_permission_denied"
        case .restricted:
            return "microphone_permission_restricted"
        case .notDetermined:
            return "microphone_permission_not_determined"
        case .authorized:
            return "microphone_unavailable"
        @unknown default:
            return "microphone_permission_unknown"
        }
    }

    private func continueDictationStart(
        appState: TranscriptedAppState,
        sourceApp: NSRunningApplication?
    ) {
        guard isDictating else { return }
        switch dictationSession.startPathDecision(appState: appState) {
        case .immediate:
            beginDictationRecording(sourceApp: sourceApp)

        case .concurrentWarmupThenImmediate:
            // The model files are already on disk — open the microphone now
            // and load the model concurrently so the first dictation after
            // launch doesn't stare at "Loading voice model" before it can
            // listen. The stop path already waits for the model before
            // transcribing (and surfaces a load failure gracefully), so a
            // stop that beats the load is covered.
            //
            // Deliberately untracked: cancelling this dictation must not
            // abandon a model load the next session will need, and the
            // engine dedupes concurrent initialization internally.
            Task { @MainActor in
                await appState.sttRouter.initializeRecordingModel()
            }
            beginDictationRecording(sourceApp: sourceApp)

        case .fullWarmupRequired:
            startDictationAfterWarmup(sourceApp: sourceApp)
        }
    }

    // dictationStartUnavailableReason, canUseActiveMeetingMicForDictation, and
    // startDictationAudioRecording moved to Sources/Speech/DictationSession.swift
    // — they are pure STTRouter/meeting-mic decisions with no overlay
    // involvement. Kept as thin forwarding wrappers here so every existing
    // call site in this file keeps working unchanged.
    private func dictationStartUnavailableReason(appState: TranscriptedAppState) -> String? {
        dictationSession.dictationStartUnavailableReason(appState: appState)
    }

    private func canUseActiveMeetingMicForDictation(appState: TranscriptedAppState) -> Bool {
        dictationSession.canUseActiveMeetingMicForDictation(appState: appState)
    }

    private func startDictationAudioRecording(
        appState: TranscriptedAppState,
        isRecoveryAttempt: Bool = false
    ) async -> Bool {
        let sessionID = currentDictationSessionID
        return await dictationSession.startDictationAudioRecording(
            appState: appState,
            isRecoveryAttempt: isRecoveryAttempt,
            onStartFailed: { [weak self] in
                await self?.recoverBackgroundHotkeyStart(sessionID: sessionID)
            }
        )
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
    private func recoverBackgroundHotkeyStart(sessionID: UUID) async {
        guard !Task.isCancelled, isDictating, currentDictationSessionID == sessionID,
              !didAttemptStartActivation, !NSApp.isActive,
              currentStartReadinessProfile.allowsForegroundActivationEscalation,
              let appState, !canUseActiveMeetingMicForDictation(appState: appState) else { return }
        didAttemptStartActivation = true
        _ = await startActivation.prepare(
            sourceApp: sessionSourceApp,
            isCurrent: { self.isDictating && self.currentDictationSessionID == sessionID }
        )
    }

    /// Actually start dictation recording — called directly from startDictation
    private func beginDictationRecording(sourceApp: NSRunningApplication?) {
        guard let overlayController = overlayController else { return }
        guard isDictating else { return }

        guard let appState = appState else { return }

        let canUseMeetingMic = canUseActiveMeetingMicForDictation(appState: appState)
        switch dictationSession.recordingStartPlan(appState: appState, canUseMeetingMic: canUseMeetingMic) {
        case .skipLoadingAndStartRecording:
            // Fast path — engine is ready right now. The actual CoreAudio start
            // still runs asynchronously so a slow device graph never blocks UI.
            enterPendingStartStage("opening_microphone")
            overlayController.showStartingState(near: sourceApp, anchorRect: sessionAnchorRect)
            recordingStartRetryTask?.cancel()
            recordingStartRetryTask = Task { @MainActor [weak self] in
                guard let self,
                      self.isDictating,
                      let appState = self.appState,
                      let overlayController = self.overlayController else { return }
                let startAttemptedAt = CFAbsoluteTimeGetCurrent()
                let started = await self.startDictationAudioRecording(appState: appState)
                let startMs = Int((CFAbsoluteTimeGetCurrent() - startAttemptedAt) * 1000)
                guard !Task.isCancelled, self.isDictating else {
                    if started {
                        await appState.sttRouter.stopRecording()
                    }
                    return
                }
                if started {
                    let requestToRecordingMs = Int((CFAbsoluteTimeGetCurrent() - self.sessionStartTime) * 1000)
                    self.recordingStartRetryTask = nil
                    overlayController.state = .listening
                    if !overlayController.isVisible {
                        overlayController.showPanel(near: sourceApp, anchorRect: self.sessionAnchorRect)
                    }
                    self.resizePanelToCompact()
                    self.recordDictationStarted(appState: appState, trigger: self.currentDictationTrigger)
                    appState.runtimeDiagnostics.recordSession(kind: "dictation", stage: "recording")
                    appState.logger.log("DICTATION | started (parakeet, \(appState.sttRouter.inputDeviceName))")
                    DiagnosticsTrail.record(
                        logger: appState.logger,
                        engine: "dictation",
                        event: "dictation_recording_fast_start",
                        message: "Dictation recording started through the ready-engine fast path",
                        context: self.dictationContext(
                            extra: [
                                "pre_recording_overhead_ms": "\(max(0, requestToRecordingMs - startMs))",
                                "request_to_recording_ms": "\(requestToRecordingMs)",
                                "start_ms": "\(startMs)",
                                "audio_device": appState.sttRouter.inputDeviceName,
                                "trigger": self.currentDictationTrigger.rawValue
                            ]
                        )
                    )
                    AppSoundPlayer.shared.play(.dictationStart)
                    self.installSessionTimeout()
                } else {
                    let requestToFallbackMs = Int((CFAbsoluteTimeGetCurrent() - self.sessionStartTime) * 1000)
                    DiagnosticsTrail.record(
                        logger: appState.logger,
                        level: .warning,
                        engine: "dictation",
                        event: "dictation_fast_start_fell_back_to_wait",
                        message: "Ready-engine dictation fast start failed and fell back to recovery wait",
                        context: self.dictationContext(
                            extra: [
                                "pre_recording_overhead_ms": "\(max(0, requestToFallbackMs - startMs))",
                                "request_to_fallback_ms": "\(requestToFallbackMs)",
                                "start_ms": "\(startMs)",
                                "audio_device": appState.sttRouter.inputDeviceName,
                                "trigger": self.currentDictationTrigger.rawValue,
                                "start_plan": self.currentStartReadinessProfile.name,
                                "app_active": "\(NSApp.isActive)",
                                "is_recovering": "\(appState.sttRouter.isRecovering)",
                                "format_ready": "\(appState.sttRouter.inputFormatReady)"
                            ]
                        )
                    )
                    self.enterPendingStartStage("waiting_for_audio_route")
                    await self.waitForEngineAndStart(sourceApp: sourceApp)
                }
            }
            return
        case .showLoadingWhileWaiting:
            // Slow path — engine is settling after a device change. Wait for it.
            enterPendingStartStage("waiting_for_audio_route")
            overlayController.showMiniCursorStartingStateIfNeeded(
                near: sourceApp,
                anchorRect: sessionAnchorRect
            )
            overlayController.showLoadingState(
                near: sourceApp,
                presentation: microphoneRecoveryPresentation(
                    elapsed: 0,
                    deviceName: appState.sttRouter.inputDeviceName,
                    isRecovering: appState.sttRouter.isRecovering,
                    inputFormatReady: appState.sttRouter.inputFormatReady,
                    startAttempts: 0
                ),
                anchorRect: sessionAnchorRect
            )
        }
        recordingStartRetryTask?.cancel()
        recordingStartRetryTask = Task { @MainActor [weak self] in
            await self?.waitForEngineAndStart(sourceApp: sourceApp)
        }
    }

    // The recovery wait-loop state machine (deadline, readiness-refresh
    // bookkeeping, the merged start-attempt path) now lives in
    // DictationSession.waitForEngineAndStart. This wrapper keeps the
    // permission gate (a permission concern, not an STTRouter one) and turns
    // wait-status snapshots and the final outcome into overlay presentation,
    // sound, and session-timeout installation — the presentational half that
    // stays here.
    private func waitForEngineAndStart(sourceApp: NSRunningApplication?) async {
        guard let appState = appState, let overlayController = overlayController else { return }
        guard isDictating else { return }

        // Permission check up front — no point waiting if the user denied mic access.
        let microphoneStatus = TranscriptedPermissionAccess.microphoneAuthorizationStatus()
        guard microphoneStatus == .authorized else {
            presentMicrophonePermissionError(microphoneStatus, sourceApp: sourceApp)
            return
        }

        let sessionID = currentDictationSessionID
        let outcome = await dictationSession.waitForEngineAndStart(
            appState: appState,
            sessionStartTime: sessionStartTime,
            isDictating: { [weak self] in
                self?.isDictating == true && self?.currentDictationSessionID == sessionID
            },
            onStartFailed: { [weak self] in
                await self?.recoverBackgroundHotkeyStart(sessionID: sessionID)
            },
            onStartStageChanged: { [weak self] stage in
                guard let self, self.isDictating,
                      self.currentDictationSessionID == sessionID,
                      !Task.isCancelled else { return }
                self.enterPendingStartStage(stage.rawValue)
            },
            onWaitUpdate: { [weak self] status in
                guard let self, let overlayController = self.overlayController else { return }
                overlayController.showLoadingState(
                    near: sourceApp,
                    presentation: self.microphoneRecoveryPresentation(
                        elapsed: status.elapsed,
                        deviceName: status.deviceName,
                        isRecovering: status.isRecovering,
                        inputFormatReady: status.inputFormatReady,
                        startAttempts: status.startAttempts
                    ),
                    anchorRect: self.sessionAnchorRect
                )
            },
            onRecordingStarted: { [weak self] in
                // Fires the instant a start attempt succeeds, BEFORE
                // DictationSession's own stage-record/log calls — matches
                // both original inline branches, which flipped the overlay
                // to .listening first and only logged afterward.
                guard let self else { return }
                self.overlayController?.state = .listening
                self.resizePanelToCompact()
            }
        )

        // DictationSession already re-checks isDictating/Task.isCancelled at
        // every point the original inline loop did before it hands back an
        // outcome, so `.aborted` is the only outcome for those cases.
        switch outcome {
        case .aborted:
            return

        case .started:
            // overlayController.state/resizePanelToCompact() already ran via
            // onRecordingStarted above, before DictationSession's telemetry.
            recordDictationStarted(appState: appState, trigger: currentDictationTrigger)
            // Drop the finished start handle like the fast path does: a stale
            // non-nil handle makes a later push-to-talk release during a
            // mid-session device recovery read as "cancel pending start",
            // which discards the audio the engine preserved instead of
            // transcribing it.
            recordingStartRetryTask = nil
            AppSoundPlayer.shared.play(.dictationStart)
            installSessionTimeout()

        case .timedOut(let info):
            let cleanupPlan = info.cleanupPlan
            if !cleanupPlan.reportBeforeCleanup {
                await finishFailedDictationStart(appState: appState, cleanupPlan: cleanupPlan)
            }
            trackDictationStartFailed(
                cleanupPlan.outcome,
                extra: [
                    "start_attempt_bucket": AnalyticsReporter.countBucket(info.startAttempts)
                ]
            )
            if cleanupPlan.reportRuntimeStall {
                appState.runtimeDiagnostics.recordStall(
                    kind: "dictation",
                    stage: cleanupPlan.outcome,
                    durationSeconds: TranscriptedConstants.dictationRecoveryBudget,
                    extra: dictationAnalyticsProperties(extra: [
                        "failure_kind": cleanupPlan.outcome,
                        "format_ready": "\(appState.sttRouter.inputFormatReady)",
                        "forced_readiness_recoveries": "\(info.forcedReadinessRecoveries)",
                        "readiness_refreshes": "\(info.readinessRefreshes)",
                        "recovering": "\(appState.sttRouter.isRecovering)",
                        "recovery_start_attempts": "\(info.recoveryStartAttempts)",
                        "start_attempts": "\(info.startAttempts)",
                        "trigger": currentDictationTrigger.rawValue,
                    ])
                )
            }
            if cleanupPlan.reportBeforeCleanup {
                await finishFailedDictationStart(appState: appState, cleanupPlan: cleanupPlan)
            }
            overlayController.showError(
                microphoneTimeoutMessage(
                    deviceName: appState.sttRouter.inputDeviceName,
                    startAttempts: info.startAttempts,
                    inputFormatReady: appState.sttRouter.inputFormatReady,
                    routeContext: appState.sttRouter.dictationAudioRouteAnalyticsContext
                ),
                actionTitle: "Try Again",
                action: { [weak self] in
                    guard let self else { return }
                    self.startDictation(sourceApp: sourceApp, trigger: self.currentDictationTrigger, isRetry: true)
                }
            )
        }
    }

    private func finishFailedDictationStart(
        appState: TranscriptedAppState,
        cleanupPlan: DictationRecordingStartFailureCleanupPlan
    ) async {
        recordingStartRetryTask = nil
        sessionTimeoutTask?.cancel()
        sessionTimeoutTask = nil
        if cleanupPlan.resetSpeechEngine {
            await dictationSession.resetEngineAfterFailedStart(
                appState: appState,
                hardReset: cleanupPlan.hardResetSpeechEngine,
                reason: cleanupPlan.outcome
            )
        }
        appState.runtimeDiagnostics.clearSession(
            kind: "dictation",
            outcome: cleanupPlan.outcome,
            resetToIdle: cleanupPlan.resetRuntimeSessionToIdle
        )
        isDictating = false
    }

    private func presentMicrophonePermissionError(
        _ status: AVAuthorizationStatus,
        sourceApp: NSRunningApplication? = nil
    ) {
        guard let appState = appState, let overlayController = overlayController else { return }
        let shouldOfferRecoveryAction = shouldOfferMicrophoneRecoveryAction(for: status)
        DiagnosticsTrail.record(
            logger: appState.logger,
            level: .error,
            engine: "dictation",
            event: "dictation_recording_failed",
            message: "Dictation recording failed to start",
            context: dictationContext(
                extra: [
                    "audio_device": appState.sttRouter.inputDeviceName,
                    "mic_status": status.diagnosticName
                ]
            )
        )
        trackDictationStartFailed(dictationStartFailureKind(for: status))
        appState.runtimeDiagnostics.clearSession(kind: "dictation", outcome: "start_failed")
        overlayController.showError(
            microphoneUnavailableMessage(for: status, openedSettings: false),
            actionTitle: shouldOfferRecoveryAction ? TranscriptedPermissionKind.microphoneActionTitle(for: status) : nil,
            action: shouldOfferRecoveryAction ? { [weak self] in
                guard let self else { return }
                switch status {
                case .notDetermined:
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        let granted = await TranscriptedPermissionAccess.requestMicrophoneAccessIfNeeded()
                        guard granted else {
                            self.presentMicrophonePermissionError(
                                TranscriptedPermissionAccess.microphoneAuthorizationStatus(),
                                sourceApp: sourceApp
                            )
                            return
                        }
                        self.startDictation(
                            sourceApp: sourceApp,
                            trigger: self.currentDictationTrigger,
                            anchorRect: self.sessionAnchorRect,
                            isRetry: true
                        )
                    }
                case .denied, .restricted:
                    overlayController.dismissError()
                    TranscriptedPermissionAccess.openSettings(for: .microphone)
                case .authorized:
                    self.startDictation(
                        sourceApp: sourceApp,
                        trigger: self.currentDictationTrigger,
                        anchorRect: self.sessionAnchorRect,
                        isRetry: true
                    )
                @unknown default:
                    overlayController.dismissError()
                    TranscriptedPermissionAccess.openSettings(for: .microphone)
                }
            } : nil
        )
        isDictating = false
    }

    /// Stop dictation and paste — selected local STT batch transcription.
    ///
    /// When `autoPaste` is `false` the transcript is still transcribed and saved
    /// to the daily Markdown file, but it is not pasted into the focused app and
    /// auto-send is suppressed. The 5-minute session cap uses this to recover a
    /// walked-away dictation instead of discarding it, without injecting text
    /// into whatever app now happens to hold focus.
    func stopDictationAndPaste(
        trigger: DictationTrigger = .unknown,
        shortcutMode: DictationShortcutMode? = nil,
        autoPaste: Bool = true
    ) {
        guard let (appState, overlayController) = readyState() else { return }
        let stopRequestedAt = CFAbsoluteTimeGetCurrent()
        DiagnosticsTrail.record(
            logger: appState.logger,
            engine: "dictation",
            event: "dictation_stop_requested",
            message: "Dictation stop requested",
            context: dictationContext(
                extra: [
                    "dictation_session_id": currentDictationSessionID.uuidString,
                    "trigger": trigger.rawValue,
                    "overlay_state": overlayStateName(overlayController.state),
                    "stt_recording": "\(appState.sttRouter.isRecording)"
                ]
            )
        )
        guard isDictating else {
            DiagnosticsTrail.record(
                logger: appState.logger,
                level: .info,
                engine: "dictation",
                event: "dictation_stop_ignored",
                message: "Ignored dictation stop because no dictation session was active",
                context: dictationContext(
                    extra: [
                        "trigger": trigger.rawValue,
                        "overlay_state": overlayStateName(overlayController.state),
                        "stt_recording": "\(appState.sttRouter.isRecording)"
                    ]
                )
            )
            return
        }
        // The overlay can briefly look like pending startup again while the
        // first stop waits for a model. Fence repeats before stopDecision so
        // they cannot be misread as cancelPendingStart and discard its WAV.
        if stopFinalizationGate.admittedSessionID == currentDictationSessionID {
            DiagnosticsTrail.record(
                logger: appState.logger,
                level: .info,
                engine: "dictation",
                event: "dictation_stop_ignored",
                message: "Ignored repeated stop while this session is already finalizing",
                context: dictationContext(extra: [
                    "trigger": trigger.rawValue,
                    "dictation_session_id": currentDictationSessionID.uuidString,
                    "reason": "already_finalizing"
                ])
            )
            return
        }
        let stopDecision = DictationRecordingStartLifecyclePolicy.stopDecision(
            isLoadingOverlay: overlayController.state == .loading,
            isListeningOverlay: overlayController.state == .listening,
            hasStartupTask: startupTask != nil,
            hasRecordingStartTask: recordingStartRetryTask != nil,
            sttIsRecording: appState.sttRouter.isRecording
        )

        if stopDecision == .cancelPendingStart {
            if trigger == .physicalKey {
                cancelPendingDictationStartAfterEarlyRelease(
                    appState: appState,
                    overlayController: overlayController,
                    shortcutMode: shortcutMode
                )
                return
            }
            cancelDictation()
            return
        }

        guard stopDecision == .stopRecording else {
            if overlayController.state == .drafting || appState.sttRouter.isTranscribing {
                overlayController.showError("Still finishing the last dictation. Try again in a moment.")
            }
            DiagnosticsTrail.record(
                logger: appState.logger,
                level: .warning,
                engine: "dictation",
                event: "dictation_stop_ignored",
                message: "Ignored dictation stop because recording was no longer active",
                context: dictationContext(
                    extra: [
                        "trigger": trigger.rawValue,
                        "overlay_state": overlayStateName(overlayController.state),
                        "stt_recording": "\(appState.sttRouter.isRecording)"
                    ]
                )
            )
            return
        }
        let hasRecoverableRecording = appState.sttRouter.hasRecoverableRecording
        guard appState.sttRouter.isRecording || hasRecoverableRecording else {
            recordingStartRetryTask?.cancel()
            recordingStartRetryTask = nil
            appState.sttRouter.cancel()
            let failureKind = appState.sttRouter.inputFormatReady
                ? "microphone_start_failed"
                : "microphone_route_not_ready"
            DiagnosticsTrail.record(
                logger: appState.logger,
                level: .error,
                engine: "dictation",
                event: "dictation_capture_not_started",
                message: "Dictation stop requested before audio capture started",
                context: dictationContext(
                    extra: [
                        "trigger": trigger.rawValue,
                        "overlay_state": overlayStateName(overlayController.state),
                        "failure_kind": failureKind
                    ]
                )
            )
            trackDictationStartFailed(failureKind)
            appState.runtimeDiagnostics.clearSession(kind: "dictation", outcome: failureKind)
            isDictating = false
            overlayController.showError(
                microphoneTimeoutMessage(
                    deviceName: appState.sttRouter.inputDeviceName,
                    startAttempts: 0,
                    inputFormatReady: appState.sttRouter.inputFormatReady,
                    routeContext: appState.sttRouter.dictationAudioRouteAnalyticsContext
                ),
                actionTitle: "Try Again",
                action: { [weak self] in
                    guard let self else { return }
                    self.startDictation(sourceApp: self.sessionSourceApp, trigger: self.currentDictationTrigger, isRetry: true)
                }
            )
            return
        }
        guard stopFinalizationGate.admit(sessionID: currentDictationSessionID) else {
            // @MainActor callers cannot interleave between the early fence and
            // admission, but keep the policy as the final ownership check.
            return
        }
        sessionTimeoutTask?.cancel()
        sessionTimeoutTask = nil
        recordingStartRetryTask?.cancel()
        recordingStartRetryTask = nil

        streamingTask?.cancel()
        let taskSessionID = currentDictationSessionID
        let taskRecordingModelLease = appState.sttRouter.recordingModelLease
        let checkpointSignal = DictationStoppedAudioCheckpointSignal()
        stoppedAudioCheckpointSignal = checkpointSignal
        streamingTask = Task {
            defer {
                appState.sttRouter.finishRecordingModelUse(taskRecordingModelLease)
                Task { await checkpointSignal.complete() }
            }
            var stopTiming = DictationStopTiming(requestedAt: stopRequestedAt)
            var stoppedRecordingSnapshot: RecordedSpeechSamples?
            guard !Task.isCancelled,
                  self.isDictating,
                  self.currentDictationSessionID == taskSessionID else { return }
            appState.runtimeDiagnostics.recordSession(kind: "dictation", stage: "stop_requested")
            // The accepted stop request owns cancellation even if recovery
            // publishes a brief idle state before this task begins. The engine's
            // idle stop path invalidates any pending recovery restart.
            await appState.sttRouter.stopRecording()
            stopTiming.micStoppedAt = CFAbsoluteTimeGetCurrent()
            guard !Task.isCancelled,
                  self.isDictating,
                  self.currentDictationSessionID == taskSessionID else { return }

            do {
                stopTiming.snapshotStartedAt = CFAbsoluteTimeGetCurrent()
                if let recording = await appState.sttRouter.snapshotRecordedSamplesForPersistence() {
                    stopTiming.snapshotFinishedAt = CFAbsoluteTimeGetCurrent()
                    guard DictationStoppedAudioRecoveryCommitPolicy.shouldPersist(
                        taskCancelled: Task.isCancelled,
                        isDictating: self.isDictating,
                        taskSessionID: taskSessionID,
                        currentSessionID: self.currentDictationSessionID
                    ) else { return }
                    stopTiming.recoveryCheckpointStartedAt = CFAbsoluteTimeGetCurrent()
                    let recovery = try await Task.detached(priority: .userInitiated) {
                        try DictationStoppedAudioRecoveryStore.persist(
                            samples16k: recording.samples16k,
                            sessionID: taskSessionID
                        )
                    }.value
                    stopTiming.recoveryCheckpointFinishedAt = CFAbsoluteTimeGetCurrent()
                    guard DictationStoppedAudioRecoveryCommitPolicy.shouldPersist(
                        taskCancelled: Task.isCancelled,
                        isDictating: self.isDictating,
                        taskSessionID: taskSessionID,
                        currentSessionID: self.currentDictationSessionID
                    ) else {
                        if !DictationStoppedAudioRecoveryCommitPolicy.shouldRetainPersistedRecovery(
                            taskSessionID: taskSessionID,
                            preservationSessionID: self.stoppedAudioRecoveryPreservationSessionID
                        ) {
                            _ = await Task.detached(priority: .utility) {
                                DictationStoppedAudioRecoveryStore.cleanup(
                                    recovery,
                                    explicitDiscard: true
                                )
                            }.value
                        }
                        return
                    }
                    self.stoppedAudioRecovery = recovery
                    stoppedRecordingSnapshot = recording
                } else {
                    stopTiming.snapshotFinishedAt = CFAbsoluteTimeGetCurrent()
                    guard DictationStoppedAudioRecoveryCommitPolicy.shouldPersist(
                        taskCancelled: Task.isCancelled,
                        isDictating: self.isDictating,
                        taskSessionID: taskSessionID,
                        currentSessionID: self.currentDictationSessionID
                    ) else { return }
                    if DictationTerminationAdmissionPolicy.mustStopBeforeInference(
                        snapshotAvailable: false,
                        hasRecoverableRecording: appState.sttRouter.hasRecoverableRecording
                    ) {
                        // A converter/owner race may fail the WAV snapshot
                        // while native audio survives. Inference would consume
                        // that last RAM copy without a durable checkpoint.
                        self.isDictating = false
                        appState.runtimeDiagnostics.clearSession(
                            kind: "dictation", outcome: "audio_checkpoint_unavailable"
                        )
                        self.showFailedCheckpointRecoveryError()
                        return
                    }
                }
            } catch {
                stopTiming.recoveryCheckpointFinishedAt = CFAbsoluteTimeGetCurrent()
                guard DictationStoppedAudioRecoveryCommitPolicy.shouldPersist(
                    taskCancelled: Task.isCancelled,
                    isDictating: self.isDictating,
                    taskSessionID: taskSessionID,
                    currentSessionID: self.currentDictationSessionID
                ) else { return }
                appState.logger.log("DICTATION | failed to preserve stopped audio: \(error.localizedDescription)")
                EventReporter.shared.capture(
                    level: .error,
                    engine: "dictation",
                    event: "dictation_stopped_audio_persistence_failed",
                    message: error.localizedDescription
                )
                self.isDictating = false
                appState.runtimeDiagnostics.clearSession(kind: "dictation", outcome: "audio_persistence_failed")
                self.showFailedCheckpointRecoveryError()
                return
            }

            await checkpointSignal.complete()
            guard !Task.isCancelled, self.isDictating,
                  self.currentDictationSessionID == taskSessionID else { return }

            // Surface model warmup honestly instead of calling it "Transcribing"
            // before the local dictation model is actually ready.
            if !appState.sttRouter.isRecordingModelLoaded {
                stopTiming.modelWaitStartedAt = CFAbsoluteTimeGetCurrent()
                appState.logger.log("DICTATION | waiting for voice model before transcribe…")
                self.updateLoadingOverlay(sourceApp: self.sessionSourceApp, phase: .afterRecording)
                let modelWaitDeadline = ProcessInfo.processInfo.systemUptime
                    + TranscriptedConstants.modelLoadWaitBudget
                modelWait: while !appState.sttRouter.isRecordingModelLoaded,
                    ProcessInfo.processInfo.systemUptime < modelWaitDeadline {
                    guard !Task.isCancelled,
                          self.isDictating,
                          self.currentDictationSessionID == taskSessionID else { return }
                    self.updateLoadingOverlay(sourceApp: self.sessionSourceApp, phase: .afterRecording)
                    switch appState.sttRouter.recordingModelDownloadState {
                    case .failed:
                        // The concurrent load already failed — surface the
                        // error now instead of waiting out the full budget.
                        break modelWait
                    case .notLoaded, .cached:
                        // Nothing is loading the model; kick (or join) the
                        // deduped initialization instead of waiting for
                        // another caller to do it.
                        appState.sttRouter.requestRecordingModelInitialization()
                        await appState.sttRouter.waitForRecordingModelLoadProgress(until: modelWaitDeadline)
                    case .downloading, .loading, .ready:
                        await appState.sttRouter.waitForRecordingModelLoadProgress(until: modelWaitDeadline)
                    }
                }
                guard !Task.isCancelled, self.isDictating,
                      self.currentDictationSessionID == taskSessionID else { return }
                guard appState.sttRouter.isRecordingModelLoaded else {
                    appState.logger.log("DICTATION | voice model failed to load for transcription")
                    overlayController.showError("The voice model didn't load. Please try dictating again in a moment.")
                    ProductFrictionTelemetry.track(
                        surface: .dictation,
                        stage: "dictation_transcribe",
                        result: .blocked,
                        failureKind: "model_not_ready",
                        elapsedBucket: AnalyticsReporter.durationBucket(seconds: CFAbsoluteTimeGetCurrent() - sessionStartTime),
                        routeShape: self.dictationAnalyticsProperties()["route_shape"],
                        modelState: "not_ready"
                    )
                    isDictating = false
                    appState.runtimeDiagnostics.clearSession(kind: "dictation", outcome: "model_unavailable")
                    return
                }
                stopTiming.modelReadyAt = CFAbsoluteTimeGetCurrent()
            } else {
                stopTiming.modelWaitStartedAt = stopTiming.micStoppedAt
                stopTiming.modelReadyAt = stopTiming.micStoppedAt
            }
            overlayController.state = .drafting
            overlayController.resizePanelToCompact()
            appState.runtimeDiagnostics.recordSession(kind: "dictation", stage: "transcribing")
            stopTiming.transcriptionStartedAt = CFAbsoluteTimeGetCurrent()
            let voiceText = await appState.sttRouter.transcribe(
                preparedRecording: stoppedRecordingSnapshot
            )
            stopTiming.transcribedAt = CFAbsoluteTimeGetCurrent()
            guard !Task.isCancelled,
                  self.isDictating,
                  self.currentDictationSessionID == taskSessionID else { return }

            let cleanupEnabled = DictationCleanupPreferences.isEnabled()
            let cleanupResult = voiceText.map { rawText in
                if cleanupEnabled {
                    return DictationFillerCleanupPolicy.clean(rawText)
                }
                let trimmedText = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
                return DictationFillerCleanupResult(text: trimmedText, removedCount: 0, changed: trimmedText != rawText)
            }
            stopTiming.cleanedAt = CFAbsoluteTimeGetCurrent()
            guard let text = cleanupResult?.text, !text.isEmpty else {
                let emptyReason = appState.sttRouter.lastEmptyTranscriptionReason ?? .noSpeech
                appState.logger.log("DICTATION | no transcription (\(emptyReason.rawValue)), cancelling")
                EventReporter.shared.capture(
                    level: .warning,
                    engine: "overlay",
                    event: emptyReason.localEventName,
                    message: emptyReason.localEventMessage,
                    context: self.dictationContext(
                        extra: [
                            "duration_ms": "\(Int((CFAbsoluteTimeGetCurrent() - self.sessionStartTime) * 1000))",
                            "trigger": self.currentDictationTrigger.rawValue,
                            "reason": emptyReason.rawValue
                        ]
                    )
                )
                AnalyticsReporter.track(
                    emptyReason.analyticsEventName,
                    properties: self.dictationAnalyticsProperties(
                        extra: [
                            "duration_bucket": AnalyticsReporter.durationBucket(
                                seconds: CFAbsoluteTimeGetCurrent() - sessionStartTime
                            ),
                            "trigger": currentDictationTrigger.rawValue,
                        ]
                    )
                )
                ProductFrictionTelemetry.track(
                    surface: .dictation,
                    stage: "dictation_transcribe",
                    result: .giveUp,
                    failureKind: emptyReason.frictionFailureKind,
                    elapsedBucket: AnalyticsReporter.durationBucket(seconds: CFAbsoluteTimeGetCurrent() - sessionStartTime),
                    routeShape: self.dictationAnalyticsProperties()["route_shape"],
                    modelState: ProductFrictionTelemetry.modelState(isReady: appState.sttRouter.isModelLoaded)
                )
                if emptyReason.shouldDiscardStoppedAudioRecovery {
                    NotificationCenter.default.post(name: .dictationNoSpeechDetected, object: nil)
                    AppSoundPlayer.shared.play(.noSpeech)
                    overlayController.showNoSpeechAndDismiss(trigger: currentDictationTrigger.rawValue, reason: emptyReason)
                } else if let recovery = self.stoppedAudioRecovery {
                    overlayController.showError(
                        DictationNoSpeechPresentationPolicy.message(
                            trigger: currentDictationTrigger.rawValue,
                            reason: emptyReason
                        ),
                        actionTitle: "Show Audio",
                        action: {
                            NSWorkspace.shared.activateFileViewerSelecting([recovery.url])
                        }
                    )
                } else {
                    if emptyReason == .audioNeedsRecovery {
                        // The captured audio has no durable WAV. If native RAM
                        // remains, offer the guarded no-paste checkpoint retry
                        // rather than mislabeling this as model-empty speech.
                        isDictating = false
                        showFailedCheckpointRecoveryError()
                    } else {
                        overlayController.showError(
                            DictationNoSpeechPresentationPolicy.message(
                                trigger: currentDictationTrigger.rawValue,
                                reason: emptyReason
                            )
                        )
                    }
                }
                isDictating = false
                appState.runtimeDiagnostics.clearSession(kind: "dictation", outcome: emptyReason.runtimeOutcome)
                if emptyReason.shouldDiscardStoppedAudioRecovery {
                    self.discardStoppedAudioRecovery(explicitDiscard: true)
                }
                return
            }

            guard !Task.isCancelled else { return }
            if (cleanupResult?.removedCount ?? 0) > 0 {
                appState.logger.log("DICTATION | filler cleanup removed \(cleanupResult?.removedCount ?? 0) items")
            }

            if !autoPaste {
                // Session cap reached (the user walked away mid-dictation).
                // Recover the transcript by saving it to the daily Markdown file,
                // but do NOT paste it into whatever app now holds focus and do
                // NOT auto-send — the cap exists to rescue abandoned sessions,
                // not to inject text into an unattended app.
                await self.finalizeWithoutPaste(
                    text: text,
                    appState: appState,
                    overlayController: overlayController,
                    sessionID: taskSessionID
                )
                return
            }

            appState.logger.log("DICTATION | pasting \(text.count) chars")
            lastCompletedText = text
            stopTiming.pasteStartedAt = CFAbsoluteTimeGetCurrent()
            let pasteOutcome = self.pasteWithClipboardRestore(text)
            stopTiming.pastedAt = CFAbsoluteTimeGetCurrent()
            // Paste confirmation pumps the run loop, so cancellation/restart can occur here too.
            guard DictationSessionCompletionPolicy.canPublish(
                sessionID: taskSessionID, currentSessionID: self.currentDictationSessionID,
                isDictating: self.isDictating, cancelled: Task.isCancelled
            ) else { return }
            stopTiming.pasteBreakdown = self.textPaster.lastPasteTiming
            // Capture ownership before suspending. The writer may outlive cancellation.
            let recovery = self.stoppedAudioRecovery
            let saveContext = self.dictationContext()
            stopTiming.finalizationStartedAt = CFAbsoluteTimeGetCurrent()
            let finalization = await DictationStopFinalizer.finalize(
                order: DictationStopFinalizationPolicy.order,
                startSaving: {
                    return self.startPersistingDictationTranscript(
                        text: text,
                        delivery: pasteOutcome.delivery,
                        recovery: recovery
                    )
                },
                finishSaving: { saveTask in
                    let result = await saveTask.value
                    self.publishDictationTranscriptPersistence(result, delivery: pasteOutcome.delivery, context: saveContext)
                    return result
                },
                saveSynchronously: {
                    let result = self.persistDictationTranscript(text: text, delivery: pasteOutcome.delivery)
                    _ = DictationStoppedAudioRecoveryStore.cleanup(recovery, transcriptPersisted: result.saved != nil)
                    return result
                },
                performAutoEnter: {
                    stopTiming.autoEnterStartedAt = CFAbsoluteTimeGetCurrent()
                    let outcome = await self.performAutoEnterIfNeeded(
                        pasteOutcome: pasteOutcome,
                        sessionID: taskSessionID
                    )
                    stopTiming.autoEnterFinishedAt = CFAbsoluteTimeGetCurrent()
                    return outcome
                }
            )
            let autoSendOutcome = finalization.autoEnterOutcome
            let saveResult = finalization.saveResult
            guard DictationSessionCompletionPolicy.canPublish(
                sessionID: taskSessionID, currentSessionID: self.currentDictationSessionID,
                isDictating: self.isDictating, cancelled: Task.isCancelled
            ) else { return }
            if saveResult.saved != nil, self.stoppedAudioRecovery == recovery {
                self.stoppedAudioRecovery = nil
            }
            stopTiming.saveStartedAt = saveResult.startedAt
            stopTiming.savedAt = saveResult.finishedAt
            stopTiming.savePublishedAt = CFAbsoluteTimeGetCurrent()
            let saveFailureMessage = saveResult.failureMessage
            let wordCount = text.split(whereSeparator: \.isWhitespace).count
            stopTiming.completedAt = CFAbsoluteTimeGetCurrent()
            var deliveryContext: [String: String] = [
                "dictation_session_id": taskSessionID.uuidString,
                "trigger": self.currentDictationTrigger.rawValue,
                "delivery": pasteOutcome.delivery.rawValue,
                "auto_send": autoSendOutcome.diagnosticName,
                "chars": "\(text.count)",
                "words": "\(wordCount)",
                "duration_ms": "\(Int((CFAbsoluteTimeGetCurrent() - self.sessionStartTime) * 1000))",
            ]
            if let failureReason = pasteOutcome.failureReason {
                deliveryContext["failure_kind"] = failureReason.rawValue
            }
            DiagnosticsTrail.record(
                logger: appState.logger,
                level: pasteOutcome.diagnosticLevel,
                engine: "dictation",
                event: "dictation_delivery_completed",
                message: pasteOutcome.diagnosticMessage,
                context: self.dictationContext(extra: deliveryContext)
            )
            self.recordDictationStopLatency(
                appState: appState,
                timing: stopTiming,
                sessionID: taskSessionID,
                stopTrigger: trigger,
                startTrigger: self.currentDictationTrigger,
                pasteOutcome: pasteOutcome,
                autoSendOutcome: autoSendOutcome,
                wordCount: wordCount,
                charCount: text.count,
                cleanupEnabled: cleanupEnabled,
                cleanupChanged: cleanupResult?.changed ?? false,
                saveSucceeded: saveFailureMessage == nil
            )
            trackDictationDeliveryFriction(
                pasteOutcome: pasteOutcome,
                saveSucceeded: saveFailureMessage == nil,
                elapsedSeconds: CFAbsoluteTimeGetCurrent() - sessionStartTime
            )
            switch pasteOutcome {
            case .pasted:
                AppSoundPlayer.shared.play(.dictationDelivered)
                if let saveFailureMessage {
                    overlayController.showError(saveFailureMessage)
                } else if case .failed(let failure) = autoSendOutcome {
                    overlayController.showError("Text pasted, but Auto Enter didn't run. \(failure.message)")
                } else {
                    overlayController.showSuccessAndDismiss(title: autoSendOutcome.confirmationTitle ?? "Pasted")
                }
            case .copied(let message, reason: .pasteConfirmationUnavailable):
                if let saveFailureMessage {
                    overlayController.showError("\(message) \(saveFailureMessage)")
                } else {
                    overlayController.showClipboardNotice(message)
                }
                appState.logger.log("DICTATION | paste command sent without positive delivery proof; showing neutral clipboard notice: \(message)")
            case .copied(let message, reason: _):
                if let saveFailureMessage {
                    overlayController.showError("\(message) \(saveFailureMessage)")
                } else {
                    // The text is safe on the clipboard — present it as a calm
                    // "press ⌘V" notice, not a warning-triangle error.
                    overlayController.showClipboardNotice(message)
                }
            case .failed(let message, reason: _):
                let combinedMessage: String
                if let saveFailureMessage {
                    combinedMessage = "\(message) \(saveFailureMessage)"
                } else {
                    combinedMessage = message
                }
                overlayController.showError(combinedMessage)
            }
            isDictating = false
            appState.logger.log("DICTATION | completed with outcome \(pasteOutcome)")
            if case .failed(let failure) = autoSendOutcome {
                appState.logger.log("DICTATION | auto enter failed: \(failure.message)")
            }
            let autoSendTelemetry = DictationAutoSendTelemetry.snapshot(
                request: self.autoSendRequestDecision,
                pasteOutcome: pasteOutcome,
                sendOutcome: autoSendOutcome
            )
            let targetConfirmationMode = DictationTargetConfirmationMode.resolve(
                outcome: pasteOutcome,
                diagnostic: self.textPaster.lastConfirmationDiagnostic
            )
            var dictationCompletedExtra: [String: String] = [
                "delivery": pasteOutcome.delivery.rawValue,
                "auto_send": autoSendOutcome.diagnosticName,
                "duration_bucket": AnalyticsReporter.durationBucket(seconds: CFAbsoluteTimeGetCurrent() - sessionStartTime),
                "trigger": currentDictationTrigger.rawValue,
                "word_count_bucket": AnalyticsReporter.wordCountBucket(wordCount),
                "target_confirmation_mode": targetConfirmationMode.rawValue,
            ]
            if let failureReason = pasteOutcome.failureReason {
                dictationCompletedExtra["failure_kind"] = failureReason.rawValue
            }
            dictationCompletedExtra.merge(autoSendTelemetry.analyticsProperties) { _, new in new }
            AnalyticsReporter.track(
                "dictation_completed",
                properties: self.dictationAnalyticsProperties(
                    extra: dictationCompletedExtra
                )
            )
            if let saved = saveResult.saved {
                ActivationTelemetry.trackDictationArtifactSaved(
                    saved: saved,
                    delivery: pasteOutcome.delivery.rawValue,
                    durationBucket: AnalyticsReporter.durationBucket(seconds: CFAbsoluteTimeGetCurrent() - sessionStartTime),
                    trigger: currentDictationTrigger.rawValue,
                    wordCountBucket: AnalyticsReporter.wordCountBucket(wordCount)
                )
                ActivationTelemetry.trackFirstArtifactSavedIfNeeded(
                    artifactKind: .dictation,
                    surface: .dictationSave,
                    trigger: currentDictationTrigger.rawValue,
                    wordCountBucket: AnalyticsReporter.wordCountBucket(wordCount),
                    durationBucket: AnalyticsReporter.durationBucket(seconds: CFAbsoluteTimeGetCurrent() - sessionStartTime)
                )
                self.trackOnboardingFirstDictationSavedIfNeeded(
                    delivery: pasteOutcome.delivery,
                    wordCount: wordCount
                )
            }
            appState.runtimeDiagnostics.clearSession(kind: "dictation", outcome: "completed")
        }
    }

    /// Finalize a dictation by saving it to the daily Markdown file without
    /// pasting into the focused app or auto-sending. Used by the 5-minute
    /// session cap so a walked-away session is recovered instead of discarded.
    private func finalizeWithoutPaste(
        text: String,
        appState: TranscriptedAppState,
        overlayController: FloatingOverlayController,
        sessionID: UUID
    ) async {
        lastCompletedText = text
        let recovery = stoppedAudioRecovery
        let saveContext = dictationContext()
        let saveTask = startPersistingDictationTranscript(text: text, delivery: .savedWithoutPaste, recovery: recovery)
        let saveResult = await saveTask.value
        publishDictationTranscriptPersistence(saveResult, delivery: .savedWithoutPaste, context: saveContext)
        guard DictationSessionCompletionPolicy.canPublish(
            sessionID: sessionID, currentSessionID: currentDictationSessionID,
            isDictating: isDictating, cancelled: Task.isCancelled
        ) else { return }
        if saveResult.saved != nil, stoppedAudioRecovery == recovery {
            stoppedAudioRecovery = nil
        }
        let saveFailureMessage = saveResult.failureMessage
        let completionTelemetry = DictationSessionCapCompletionTelemetryPolicy.snapshot(
            saveSucceeded: saveResult.saved != nil
        )
        let wordCount = text.split(whereSeparator: \.isWhitespace).count
        let durationSeconds = CFAbsoluteTimeGetCurrent() - sessionStartTime
        appState.logger.log("DICTATION | session cap reached, saved \(text.count) chars without pasting")
        DiagnosticsTrail.record(
            logger: appState.logger,
            level: saveFailureMessage == nil ? .info : .warning,
            engine: "dictation",
            event: "dictation_session_cap_saved",
            message: saveFailureMessage == nil
                ? "Dictation auto-saved at session cap without pasting"
                : "Dictation session cap save failed",
            context: dictationContext(
                extra: [
                    "dictation_session_id": sessionID.uuidString,
                    "trigger": currentDictationTrigger.rawValue,
                    "chars": "\(text.count)",
                    "words": "\(wordCount)",
                    "duration_ms": "\(Int(durationSeconds * 1000))",
                    "save_failed": "\(saveFailureMessage != nil)"
                ]
            )
        )
        var completionProperties: [String: String] = [
            "delivery": completionTelemetry.delivery.rawValue,
            "auto_send": "disabled",
            "duration_bucket": AnalyticsReporter.durationBucket(seconds: durationSeconds),
            "trigger": currentDictationTrigger.rawValue,
            "word_count_bucket": AnalyticsReporter.wordCountBucket(wordCount),
        ]
        if let failureKind = completionTelemetry.failureKind {
            completionProperties["failure_kind"] = failureKind
        }
        AnalyticsReporter.track(
            "dictation_completed",
            properties: dictationAnalyticsProperties(extra: completionProperties)
        )
        if let saveFailureMessage {
            overlayController.showError(saveFailureMessage)
        } else {
            overlayController.showError(
                "Saved to Markdown. Paste it now, or use Paste Last Dictation later.",
                actionTitle: "Paste It",
                action: { [weak self] in
                    guard let self else { return }
                    let outcome = self.pasteWithClipboardRestore(text)
                    switch outcome {
                    case .pasted:
                        overlayController.showSuccessAndDismiss(title: "Pasted")
                    case .copied(let message, reason: _), .failed(let message, reason: _):
                        overlayController.showError(message)
                    }
                }
            )
            if let saved = saveResult.saved {
                ActivationTelemetry.trackDictationArtifactSaved(
                    saved: saved,
                    delivery: DictationDelivery.savedWithoutPaste.rawValue,
                    durationBucket: AnalyticsReporter.durationBucket(seconds: durationSeconds),
                    trigger: currentDictationTrigger.rawValue,
                    wordCountBucket: AnalyticsReporter.wordCountBucket(wordCount)
                )
            }
            ActivationTelemetry.trackFirstArtifactSavedIfNeeded(
                artifactKind: .dictation,
                surface: .dictationSave,
                trigger: currentDictationTrigger.rawValue,
                wordCountBucket: AnalyticsReporter.wordCountBucket(wordCount),
                durationBucket: AnalyticsReporter.durationBucket(seconds: durationSeconds)
            )
        }
        isDictating = false
        appState.runtimeDiagnostics.clearSession(
            kind: "dictation",
            outcome: saveFailureMessage == nil ? "session_cap_saved" : "session_cap_save_failed"
        )
    }

    /// Cancel dictation without pasting
    func cancelDictation(preserveStoppedAudio: Bool = false) {
        guard let (appState, overlayController) = readyState() else { return }
        if preserveStoppedAudio {
            stoppedAudioRecoveryPreservationSessionID = currentDictationSessionID
        }
        cancelActiveTasks(cancelRecording: true)
        if !preserveStoppedAudio {
            discardStoppedAudioRecovery(explicitDiscard: true)
        }
        AppSoundPlayer.shared.play(.dictationCancelled)
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

    func finishDictationForTermination() async -> Bool {
        guard isDictating else { return admitInactiveDictationQuit() }
        stopDictationAndPaste(trigger: .unknown)

        for _ in 0..<100 {
            if !isDictating { return admitInactiveDictationQuit() }
            do {
                try await Task.sleep(nanoseconds: 100_000_000)
            } catch {
                return false
            }
        }

        if isDictating {
            stoppedAudioRecoveryPreservationSessionID = currentDictationSessionID
            guard let stoppedAudioCheckpointSignal,
                  await stoppedAudioCheckpointSignal.waitForCompletion(timeoutNanoseconds: 2_000_000_000) else {
                showUnsafeDictationQuitError()
                return false
            }
            guard DictationTerminationAdmissionPolicy.canTerminate(
                isDictating: isDictating,
                checkpointSettled: true,
                hasRecoverableRecording: appState?.sttRouter.hasRecoverableRecording ?? false,
                recoveryWAVExists: currentStoppedAudioRecoveryWAVExists
            ) else {
                showUncheckpointedActiveDictationQuitError()
                return false
            }
            cancelDictation(preserveStoppedAudio: true)
        }
        return true
    }

    private var currentStoppedAudioRecoveryWAVExists: Bool {
        guard let stoppedAudioRecovery,
              stoppedAudioRecovery.sessionID == currentDictationSessionID else { return false }
        return FileManager.default.fileExists(atPath: stoppedAudioRecovery.url.path)
    }

    private func admitInactiveDictationQuit() -> Bool {
        let canTerminate = DictationTerminationAdmissionPolicy.canTerminate(
            isDictating: false,
            checkpointSettled: false,
            hasRecoverableRecording: appState?.sttRouter.hasRecoverableRecording ?? false,
            recoveryWAVExists: currentStoppedAudioRecoveryWAVExists
        )
        if !canTerminate { showFailedCheckpointRecoveryError() }
        return canTerminate
    }

    private func showUnsafeDictationQuitError() {
        overlayController?.showError(
            "Quit paused. Audio isn't saved yet; your recording wasn't discarded. Try Quit again shortly."
        )
    }

    private func showUncheckpointedActiveDictationQuitError() {
        overlayController?.showError(
            "Quit paused. This recording isn't safely saved. Keep Transcripted open until dictation finishes."
        )
    }

    private func showFailedCheckpointRecoveryError() {
        guard let overlayController else { return }
        let message = "Audio is only in memory. Keep Transcripted open; check storage, then Retry Saving."
        guard !isDictating,
              appState?.sttRouter.hasRecoverableRecording == true,
              stoppedAudioCheckpointSignal != nil,
              !currentStoppedAudioRecoveryWAVExists else {
            overlayController.showError(
                "Audio couldn't be saved safely. Keep Transcripted open and contact support."
            )
            return
        }
        overlayController.showError(
            message,
            actionTitle: "Retry Saving",
            action: { [weak self] in self?.retrySavingRetainedDictationAudio() }
        )
    }

    private func retrySavingRetainedDictationAudio() {
        let sessionID = currentDictationSessionID
        guard let checkpointSignal = stoppedAudioCheckpointSignal else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard await checkpointSignal.waitForCompletion(timeoutNanoseconds: 2_000_000_000) else {
                if self.currentDictationSessionID == sessionID && !self.isDictating {
                    self.showFailedCheckpointRecoveryError()
                }
                return
            }
            guard let (appState, overlayController) = self.readyState() else { return }
            guard DictationTerminationAdmissionPolicy.canRetrySaving(
                isDictating: self.isDictating,
                checkpointSettled: true,
                hasRecoverableRecording: appState.sttRouter.hasRecoverableRecording,
                recoveryWAVExists: self.currentStoppedAudioRecoveryWAVExists,
                isCurrentSession: self.currentDictationSessionID == sessionID,
                hasPendingStart: self.startupTask != nil || self.recordingStartRetryTask != nil
            ) else { return }
            // The previous stop has released its model lease and completed its
            // checkpoint signal. Readmit this same retained recording only;
            // the listening state is an admission input, not a new mic start.
            self.stopFinalizationGate.reset()
            // Not a microphone start — see `processActivityLabel`.
            self.processActivityLabel = "stop finalization"
            self.isDictating = true
            overlayController.state = .listening
            self.stopDictationAndPaste(trigger: .unknown, autoPaste: false)
            if self.isDictating,
               self.stopFinalizationGate.admittedSessionID == sessionID {
                // The listening state above is only the stop-policy admission
                // input. Present Saving immediately, including in mini mode.
                overlayController.state = .drafting
                overlayController.showLoadingState(
                    near: self.sessionSourceApp,
                    presentation: .init(
                        title: "Saving audio",
                        detail: "Retrying the recording already captured.",
                        progress: 0.2,
                        status: "Saving"
                    ),
                    anchorRect: self.sessionAnchorRect
                )
            }
        }
    }

    // MARK: - Private

    // The model-warmup wait loop (deadline, download-state polling, join vs.
    // kick decisions) now lives in DictationSession.waitForModelAndStart —
    // it is an STTRouter control-flow decision like the recovery wait loop.
    // This wrapper keeps the loading-overlay presentation and the
    // retry/error UI, which the outcome cases below trigger.
    private func startDictationAfterWarmup(sourceApp: NSRunningApplication?) {
        guard let appState = appState, let overlayController = overlayController else { return }

        startupTask?.cancel()
        enterPendingStartStage("awaiting_model_warmup")
        overlayController.showMiniCursorStartingStateIfNeeded(
            near: sourceApp,
            anchorRect: sessionAnchorRect
        )
        updateLoadingOverlay(sourceApp: sourceApp)

        startupTask = Task { @MainActor [weak self] in
            guard let self else { return }

            let outcome = await self.dictationSession.waitForModelAndStart(
                appState: appState,
                isDictating: { [weak self] in self?.isDictating ?? false },
                onModelStateUpdate: { [weak self] modelState in
                    self?.updateLoadingOverlay(sourceApp: sourceApp, modelState: modelState)
                }
            )

            switch outcome {
            case .ready:
                self.startupTask = nil
                guard self.isDictating else { return }
                self.beginDictationRecording(sourceApp: sourceApp)
            case .failed(let message):
                self.startupTask = nil
                self.isDictating = false
                self.trackDictationStartFailed("model_load_failed")
                appState.runtimeDiagnostics.clearSession(kind: "dictation", outcome: "model_failed")
                overlayController.showError(
                    "Dictation couldn't start: \(message)",
                    actionTitle: "Retry Dictation",
                    action: { [weak self] in
                        self?.startDictation(
                            sourceApp: sourceApp,
                            trigger: self?.currentDictationTrigger ?? .unknown,
                            anchorRect: self?.sessionAnchorRect,
                            isRetry: true
                        )
                    }
                )
            case .timedOut:
                self.startupTask = nil
                self.isDictating = false
                self.trackDictationStartFailed("model_load_timeout")
                appState.runtimeDiagnostics.recordStall(
                    kind: "dictation",
                    stage: "model_load_timeout",
                    durationSeconds: TranscriptedConstants.modelLoadWaitBudget
                )
                appState.runtimeDiagnostics.clearSession(kind: "dictation", outcome: "model_load_timeout")
                overlayController.showError(
                    "The voice model is still warming up. Try again in a moment.",
                    actionTitle: "Retry Dictation",
                    action: { [weak self] in
                        self?.startDictation(
                            sourceApp: sourceApp,
                            trigger: self?.currentDictationTrigger ?? .unknown,
                            anchorRect: self?.sessionAnchorRect,
                            isRetry: true
                        )
                    }
                )
            case .aborted:
                // Matches the original loop's early-return guard: the task
                // was cancelled or the session already ended elsewhere
                // (which already owns clearing `startupTask`), so this must
                // not touch it — a superseding startDictation call may have
                // already installed a new one.
                break
            }
        }
    }

    private func updateLoadingOverlay(
        sourceApp: NSRunningApplication?,
        modelState: ParakeetModelState? = nil,
        phase: DictationWarmupPresentationPolicy.Phase = .beforeRecording
    ) {
        guard let appState = appState else { return }
        let presentation = loadingPresentation(
            for: modelState ?? appState.sttRouter.recordingModelDownloadState,
            phase: phase
        )
        overlayController?.showLoadingState(
            near: sourceApp,
            presentation: presentation,
            anchorRect: sessionAnchorRect
        )
    }

    private func loadingPresentation(
        for modelState: ParakeetModelState,
        phase: DictationWarmupPresentationPolicy.Phase = .beforeRecording
    ) -> FloatingOverlayController.LoadingPresentation {
        let copy = DictationWarmupPresentationPolicy.copy(
            modelState: modelState,
            phase: phase
        )
        return .init(
            title: copy.title,
            detail: copy.detail,
            progress: copy.progress,
            status: copy.status
        )
    }

    private func microphoneRecoveryPresentation(
        elapsed: TimeInterval,
        deviceName: String,
        isRecovering: Bool,
        inputFormatReady: Bool,
        startAttempts: Int
    ) -> FloatingOverlayController.LoadingPresentation {
        let budget = TranscriptedConstants.dictationRecoveryBudget
        let progress = min(0.85, 0.1 + (elapsed / budget) * 0.75)
        let copy = DictationMicrophoneLoadingPresentationPolicy.copy(
            elapsed: elapsed,
            deviceName: deviceName,
            isRecovering: isRecovering,
            inputFormatReady: inputFormatReady,
            startAttempts: startAttempts
        )
        return .init(
            title: copy.title,
            detail: copy.detail,
            progress: progress,
            status: copy.status
        )
    }

    private func microphonePermissionPresentation() -> FloatingOverlayController.LoadingPresentation {
        .init(
            title: "Allow microphone",
            detail: "Transcripted needs microphone access before dictation can listen.",
            progress: 0.16,
            status: "Waiting for macOS permission"
        )
    }

    private func microphoneTimeoutMessage(
        deviceName: String,
        startAttempts: Int,
        inputFormatReady: Bool,
        routeContext: [String: String]
    ) -> String {
        DictationMicrophoneTimeoutPresentationPolicy.message(
            deviceName: deviceName,
            startAttempts: startAttempts,
            inputFormatReady: inputFormatReady,
            routeContext: routeContext
        )
    }

    /// Shrink the panel to compact (header-only) height without animation.
    /// Called after loading → listening transition to undo showLoadingState()'s expansion.
    private func resizePanelToCompact() {
        overlayController?.resizePanelToCompact()
    }

    /// Install a timeout that auto-cancels the session after 5 minutes of
    /// *active* uptime. Tracks the deadline against `ProcessInfo.systemUptime`
    /// so Mac sleep does not consume the session's remaining record window —
    /// otherwise a session that sees the Mac sleep for hours would auto-cancel
    /// immediately on wake when Task.sleep's wall-clock deadline expires.
    private func installSessionTimeout() {
        sessionTimeoutTask?.cancel()
        var timeout = DictationSessionTimeout(timeoutInterval: Self.sessionTimeoutInterval)
        timeout.start(at: ProcessInfo.processInfo.systemUptime)
        sessionTimeoutTask = Task { [weak self] in
            var didWarnSessionCap = false
            while !Task.isCancelled {
                let now = ProcessInfo.processInfo.systemUptime
                if timeout.isExpired(at: now) { break }
                let remainingSeconds = timeout.remaining(at: now) ?? 0
                if !didWarnSessionCap, remainingSeconds <= 30 {
                    didWarnSessionCap = true
                    self?.overlayController?.showLoadingState(
                        near: self?.sessionSourceApp,
                        presentation: .init(
                            title: "Long dictation",
                            detail: "Wrapping up soon. Release the key to finish now.",
                            progress: 0.94,
                            status: "30 seconds left"
                        ),
                        anchorRect: self?.sessionAnchorRect
                    )
                }
                let remainingNanos = UInt64((remainingSeconds * 1_000_000_000).rounded(.up))
                let sleepNanos = min(remainingNanos, Self.sessionTimeoutPollIntervalNanos)
                if sleepNanos == 0 { break }
                try? await Task.sleep(nanoseconds: sleepNanos)
            }
            guard !Task.isCancelled, let self = self else { return }
            if self.isDictating {
                let shouldAutoPaste = self.sessionPasteTarget?.matchesCurrentFrontmostApp() ?? false
                self.appState?.logger.log(
                    shouldAutoPaste
                        ? "DICTATION | session cap reached, finalizing with original paste target still active"
                        : "DICTATION | session cap reached, finalizing without paste"
                )
                EventReporter.shared.capture(level: .info, engine: "overlay", event: "dictation_timeout",
                    message: shouldAutoPaste
                        ? "Dictation reached the 5-minute cap; pasting because the original target is still active"
                        : "Dictation reached the 5-minute cap; saving without paste")
                self.stopDictationAndPaste(trigger: .sessionCap, autoPaste: shouldAutoPaste)
            }
        }
    }

    private func cancelPendingDictationStartAfterEarlyRelease(
        appState: TranscriptedAppState,
        overlayController: FloatingOverlayController,
        shortcutMode: DictationShortcutMode?
    ) {
        cancelActiveTasks(cancelRecording: true)
        AppSoundPlayer.shared.play(.dictationCancelled)
        let releasedWhileAppActive = NSApp.isActive
        let startPendingForMs = Int((CFAbsoluteTimeGetCurrent() - sessionStartTime) * 1000)
        let stage = pendingStartStage
        let stagePendingForMs = Int((CFAbsoluteTimeGetCurrent() - pendingStartStageEnteredAt) * 1000)
        isDictating = false
        enterPendingStartStage(Self.idleStartStage)
        appState.runtimeDiagnostics.clearSession(kind: "dictation", outcome: "microphone_not_ready")
        // This is the line behind the error the user actually sees, and it is
        // the one we ask a reporter to paste back from
        // ~/Library/Application Support/Transcripted/logs/debug.log, so every
        // field has to make sense to someone who has never read this file.
        //
        // The decisive one is `pending_for_ms`: how long the start had been
        // running when the hotkey ended it. Seconds means the microphone open
        // was genuinely stalled. A hundred milliseconds or so means a quick
        // hotkey simply beat a normal start, and no amount of audio-path
        // tuning would have helped. See #1743 — that is the open question the
        // rest of this diff cannot answer on its own.
        //
        // `pending_stage` says what those milliseconds were spent on:
        // `opening_microphone` is the CoreAudio open itself, which is the only
        // stage the audio path could be blamed for. `awaiting_model_warmup`,
        // `awaiting_microphone_permission` and `waiting_for_audio_route` are
        // each a different bug with a different fix, and `start_requested`
        // means the hotkey arrived before the start had chosen a path at all.
        // `stage_pending_for_ms` is time in that stage; `pending_for_ms` is
        // time since the whole request began.
        //
        // `shortcut_mode` comes from the physical key action that ended this
        // session: `push_to_talk` is a key release, `hands_free` is a second
        // press. Both route through `trigger: physical_key`.
        //
        // `pending_for_ms` and `duration_ms` carry the same number.
        // `duration_ms` is the original key and stays so nothing already
        // reading it breaks; `pending_for_ms` is the name that says what the
        // number means.
        //
        // Level is `.error`, not `.info`, and that is load-bearing rather than
        // cosmetic: `EventReporter` forwards to Sentry and to the reliability
        // analytics counter only at `.error`, so an allowlist entry alone
        // would never have sent this anywhere. It belongs at that level on its
        // own merits too — the user asked to dictate, got an error dialog, and
        // lost the attempt, which is exactly what `microphone_start_timeout`
        // reports for the other way the same start can fail.
        DiagnosticsTrail.record(
            logger: appState.logger,
            level: .error,
            engine: "dictation",
            event: "dictation_cancelled_before_microphone_ready",
            // Deliberately not "push-to-talk release": hands-free is the
            // default mode, and its stop press reaches here too.
            message: "Dictation hotkey ended the session before the microphone finished opening",
            context: dictationContext(
                extra: [
                    "trigger": currentDictationTrigger.rawValue,
                    // Matches the outcome recorded on the session above, and
                    // is one of the few keys the analytics registry already
                    // allows for `reliability_failure_observed`, so the
                    // counter can tell this apart from a start timeout.
                    "failure_kind": "microphone_not_ready",
                    "shortcut_mode": shortcutMode?.rawValue ?? "unknown",
                    "pending_for_ms": "\(startPendingForMs)",
                    "duration_ms": "\(startPendingForMs)",
                    "pending_stage": stage,
                    "stage_pending_for_ms": "\(stagePendingForMs)",
                    "start_plan": currentStartReadinessProfile.name,
                    "app_active": "\(releasedWhileAppActive)"
                ]
            )
        )
        // Same two numbers the diagnostics above already carry. Whether the
        // microphone is worth blaming is decided from them, not asserted:
        // see DictationEarlyReleasePresentationPolicy for why #1743's tapped
        // Push to Talk key must not be told the mic wasn't ready.
        overlayController.showError(
            DictationEarlyReleasePresentationPolicy.message(
                shortcutMode: shortcutMode,
                pendingForMs: startPendingForMs
            )
        )
    }

    private func overlayStateName(_ state: FloatingOverlayController.OverlayState) -> String {
        switch state {
        case .idle: return "idle"
        case .starting: return "starting"
        case .loading: return "loading"
        case .listening: return "listening"
        case .drafting: return "drafting"
        case .success: return "success"
        }
    }

    private func cancelActiveTasks(cancelRecording: Bool) {
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

        guard cancellationPlan.cancelSpeechEngine,
              let appState else { return }
        dictationSession.cancelEngine(appState: appState)
    }

    private func handleDictationInterruption() {
        let hasRecoverableRecording = appState?.sttRouter.hasRecoverableRecording ?? false
        let interruptedSessionID = currentDictationSessionID
        let interruptedCheckpointSignal = stoppedAudioCheckpointSignal
        cancelActiveTasks(cancelRecording: !hasRecoverableRecording)
        isDictating = false
        appState?.runtimeDiagnostics.clearSession(kind: "dictation", outcome: "interrupted")
        appState?.logger.log("DICTATION | interrupted")
        DiagnosticsTrail.record(
            logger: appState?.logger,
            level: .warning,
            engine: "dictation",
            event: "dictation_recording_interrupted",
            message: "Dictation recording was interrupted",
            context: dictationContext(
                extra: [
                    "trigger": currentDictationTrigger.rawValue,
                    "duration_ms": "\(Int((CFAbsoluteTimeGetCurrent() - sessionStartTime) * 1000))"
                ]
            )
        )
        overlayController?.showError(
            hasRecoverableRecording
                ? "Recording was interrupted. Transcripted kept the audio captured so far."
                : "Recording was interrupted. Check your microphone or audio device, then try again.",
            actionTitle: hasRecoverableRecording ? "Transcribe Captured Audio" : "Retry Dictation",
            action: { [weak self] in
                guard let self else { return }
                if hasRecoverableRecording {
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        // An interrupted stop may still be awaiting a detached
                        // WAV write/cleanup. Readmit only after its owner exits,
                        // so an explicit retry cannot share that file mid-write.
                        await interruptedCheckpointSignal?.wait()
                        guard self.currentDictationSessionID == interruptedSessionID,
                              !self.isDictating else { return }
                        guard self.appState?.sttRouter.hasRecoverableRecording == true else {
                            self.presentPendingStoppedAudioRecoveryIfNeeded()
                            if DictationStoppedAudioRecoveryStore.pendingRecoveries(limit: 1).isEmpty {
                                self.overlayController?.showError(
                                    "The captured audio is no longer available. Start a new dictation.",
                                    actionTitle: "Try Again",
                                    action: { [weak self] in
                                        guard let self else { return }
                                        self.startDictation(
                                            sourceApp: self.sessionSourceApp,
                                            trigger: self.currentDictationTrigger,
                                            anchorRect: self.sessionAnchorRect,
                                            isRetry: true
                                        )
                                    }
                                )
                            }
                            return
                        }
                        self.stopFinalizationGate.reset()
                        // Not a microphone start — see `processActivityLabel`.
                        self.processActivityLabel = "stop finalization"
                        self.isDictating = true
                        self.overlayController?.state = .listening
                        self.stopDictationAndPaste(trigger: .unknown, autoPaste: false)
                    }
                } else {
                    self.startDictation(
                        sourceApp: self.sessionSourceApp,
                        trigger: self.currentDictationTrigger,
                        anchorRect: self.sessionAnchorRect,
                        isRetry: true
                    )
                }
            }
        )
    }

    private func shouldOfferMicrophoneRecoveryAction(for status: AVAuthorizationStatus) -> Bool {
        switch status {
        case .notDetermined, .denied, .restricted:
            return true
        case .authorized:
            return false
        @unknown default:
            return true
        }
    }

    private func microphoneUnavailableMessage(
        for status: AVAuthorizationStatus,
        openedSettings: Bool = false
    ) -> String {
        switch status {
        case .notDetermined:
            return "Transcripted needs microphone access before dictation can listen."
        case .denied, .restricted:
            if openedSettings {
                return "Microphone access is off. Transcripted opened the Microphone pane in System Settings."
            }
            return "Microphone access is off. Turn it on in System Settings."
        case .authorized:
            return "Microphone unavailable. Check your audio input and try again."
        @unknown default:
            return "Microphone unavailable. Check your audio input and try again."
        }
    }

    private func pasteWithClipboardRestore(_ text: String) -> DictationPasteOutcome {
        retargetPasteToCurrentFocus()
        autoSendRequestDecision = DictationAutoSendPolicy.requestDecision(
            isEnabled: DictationAutoSendPreferences.isEnabled(),
            key: DictationAutoSendPreferences.sendKey(),
            text: text,
            duration: CFAbsoluteTimeGetCurrent() - sessionStartTime,
            sourceBundleID: sessionSourceApp?.bundleIdentifier,
            allowedBundleIDs: DictationAutoSendPreferences.allowedBundleIDs()
        )
        let outcome = textPaster.paste(
            text,
            target: sessionPasteTarget
        )
        recordPasteAttemptOutcome(outcome, attempt: "initial")
        return outcome
    }

    private func recordPasteAttemptOutcome(
        _ outcome: DictationPasteOutcome,
        attempt: String
    ) {
        if let diagnostic = textPaster.lastConfirmationDiagnostic {
            var context = diagnostic.context
            context["attempt"] = attempt
            EventReporter.shared.capture(
                level: diagnostic.event == "dictation_paste_confirmed" ? .info : outcome.diagnosticLevel,
                engine: "overlay",
                event: diagnostic.event,
                message: diagnostic.event == "dictation_paste_confirmed"
                    ? "Paste delivery confirmed from privacy-safe target signals"
                    : "Paste delivery could not be confirmed from privacy-safe target signals",
                context: context
            )
        }

        let context = ["attempt": attempt]
        switch outcome.copyReason {
        case .accessibilityMissing:
            appState?.logger.log("DICTATION | Accessibility missing, copying text instead")
        case .pasteEventCreationFailed:
            EventReporter.shared.capture(level: .error, engine: "overlay", event: "cgevent_create_failed",
                message: "CGEvent creation returned nil — paste will not work", context: context)
            appState?.logger.log("DICTATION | CGEvent paste failed, keeping text on clipboard")
        case .focusChanged:
            EventReporter.shared.capture(level: .warning, engine: "overlay", event: "dictation_paste_target_changed",
                message: "Focus changed before dictation paste", context: context)
            appState?.logger.log("DICTATION | focus changed, copying text instead")
        case .pasteNotConfirmed:
            EventReporter.shared.capture(level: .warning, engine: "overlay", event: "dictation_paste_not_confirmed",
                message: "Paste-back was dispatched but the target did not confirm reading the borrowed clipboard", context: context)
            appState?.logger.log("DICTATION | paste not confirmed, keeping text on clipboard")
        case .pasteConfirmationUnavailable:
            EventReporter.shared.capture(level: .info, engine: "overlay", event: "dictation_paste_confirmation_unavailable",
                message: "Paste-back was dispatched but the target did not expose confirmation", context: context)
            appState?.logger.log("DICTATION | paste confirmation unavailable, keeping text on clipboard")
        case nil:
            break
        }
    }

    private func retargetPasteToCurrentFocus() {
        let previousTarget = sessionPasteTarget
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let frontmostTarget = DictationPasteTarget.capture(sourceApp: frontmostApp)
        let resolvedTarget = DictationPasteTarget.preferredDestination(
            frontmostProcessIdentifier: frontmostApp?.processIdentifier,
            frontmostBundleIdentifier: frontmostApp?.bundleIdentifier,
            transcriptedBundleIdentifier: Bundle.main.bundleIdentifier,
            fallback: previousTarget
        )

        sessionPasteTarget = resolvedTarget
        if resolvedTarget == frontmostTarget,
           frontmostApp?.bundleIdentifier != Bundle.main.bundleIdentifier {
            sessionSourceApp = frontmostApp
        }

        if resolvedTarget != previousTarget {
            appState?.logger.log("DICTATION | paste target updated to current focus")
            EventReporter.shared.capture(
                level: .info,
                engine: "overlay",
                event: "dictation_paste_target_updated",
                message: "Paste target followed current focus",
                context: ["target_changed": "true"]
            )
        }
    }

    private func performAutoEnterIfNeeded(
        pasteOutcome: DictationPasteOutcome,
        sessionID: UUID
    ) async -> DictationAutoSendOutcome {
        guard autoSendRequestDecision.expected,
              pasteOutcome.allowsAutoSend else {
            return .disabled
        }

        try? await Task.sleep(nanoseconds: TranscriptedConstants.dictationAutoEnterDelay)
        guard DictationSessionCompletionPolicy.canPublish(
            sessionID: sessionID, currentSessionID: currentDictationSessionID,
            isDictating: isDictating, cancelled: Task.isCancelled
        ) else { return .disabled }
        if pasteOutcome.requiresClipboardReadinessBeforeAutoSend {
            await textPaster.waitForClipboardReadyForAutoEnter()
        }
        guard DictationSessionCompletionPolicy.canPublish(
            sessionID: sessionID, currentSessionID: currentDictationSessionID,
            isDictating: isDictating, cancelled: Task.isCancelled
        ) else { return .disabled }
        return autoSender.send(autoSendRequestDecision.key, target: sessionPasteTarget)
    }

    @discardableResult
    private func persistDictationTranscript(text: String, delivery: DictationDelivery) -> DictationTranscriptPersistenceResult {
        let result = DictationTranscriptPersistenceResult.measure {
            try DictationTranscriptWriter.save(
                text: text, sourceAppName: sessionSourceApp?.localizedName ?? "Unknown",
                sourceBundleID: sessionSourceApp?.bundleIdentifier, delivery: delivery
            )
        }
        publishDictationTranscriptPersistence(result, delivery: delivery, context: dictationContext())
        return result
    }

    private func discardStoppedAudioRecovery(
        transcriptPersisted: Bool = false,
        explicitDiscard: Bool = false
    ) {
        guard DictationStoppedAudioRecoveryStore.cleanup(
            stoppedAudioRecovery,
            transcriptPersisted: transcriptPersisted,
            explicitDiscard: explicitDiscard
        ) else { return }
        stoppedAudioRecovery = nil
    }

    private func startPersistingDictationTranscript(
        text: String,
        delivery: DictationDelivery,
        recovery: DictationStoppedAudioRecovery?
    ) -> Task<DictationTranscriptPersistenceResult, Never> {
        let sourceAppName = sessionSourceApp?.localizedName ?? "Unknown"
        let sourceBundleID = sessionSourceApp?.bundleIdentifier

        return Task.detached(priority: .utility) {
            let result = DictationTranscriptPersistenceResult.measure {
                try DictationTranscriptWriter.save(
                    text: text,
                    sourceAppName: sourceAppName,
                    sourceBundleID: sourceBundleID,
                    delivery: delivery
                )
            }
            // Clean only this writer's checkpoint, even if a new session has started.
            _ = DictationStoppedAudioRecoveryStore.cleanup(recovery, transcriptPersisted: result.saved != nil)
            return result
        }
    }

    private func publishDictationTranscriptPersistence(
        _ result: DictationTranscriptPersistenceResult,
        delivery: DictationDelivery,
        context: [String: String]
    ) {
        // Artifact notifications are global; diagnostics must retain the saving session's context.
        if let saved = result.saved {
            recordDictationTranscriptSaved(saved, delivery: delivery, context: context)
            NotificationCenter.default.post(name: .dictationTranscriptDidSave, object: saved.url)
        } else if let error = result.failureError {
            recordDictationTranscriptSaveFailed(error, context: context)
        }
    }

    private func recordDictationTranscriptSaved(
        _ saved: SavedDictationTranscript,
        delivery: DictationDelivery,
        context: [String: String]
    ) {
        appState?.logger.log("DICTATION | saved markdown export at \(saved.url.lastPathComponent)")
        DiagnosticsTrail.record(
            logger: appState?.logger,
            engine: "dictation",
            event: "dictation_export_saved",
            message: "Saved dictation markdown export",
            context: context.merging(["delivery": delivery.rawValue]) { _, new in new }
        )
    }

    private func trackOnboardingFirstDictationSavedIfNeeded(
        delivery: DictationDelivery,
        wordCount: Int
    ) {
        guard PermissionsOnboardingPreferences.markFirstDictationSavedTrackedIfNeeded() else { return }

        AnalyticsReporter.track(
            "onboarding_first_dictation_saved",
            properties: [
                "delivery": delivery.rawValue,
                // The 3-step onboarding (2026-08) has no dictation-test step;
                // "done" is the stable stage a first dictation follows.
                "step_id": "done",
                "word_count_bucket": AnalyticsReporter.wordCountBucket(wordCount),
            ]
        )
    }

    private func recordDictationTranscriptSaveFailed(_ error: Error, context: [String: String]) {
        appState?.logger.log("DICTATION | failed to save markdown export: \(error.localizedDescription)")
        DiagnosticsTrail.record(
            logger: appState?.logger,
            level: .warning,
            engine: "dictation",
            event: "dictation_export_failed",
            message: "Failed to save dictation markdown export",
            context: context.merging(["error": error.localizedDescription]) { _, new in new }
        )
    }

    private func trackDictationDeliveryFriction(
        pasteOutcome: DictationPasteOutcome,
        saveSucceeded: Bool,
        elapsedSeconds: Double
    ) {
        if pasteOutcome.delivery == .failed {
            ProductFrictionTelemetry.track(
                surface: .dictation,
                stage: "pasteback",
                result: .failed,
                failureKind: pasteOutcome.failureReason?.rawValue ?? "pasteback_failed",
                elapsedBucket: AnalyticsReporter.durationBucket(seconds: elapsedSeconds),
                routeShape: dictationAnalyticsProperties()["route_shape"],
                modelState: ProductFrictionTelemetry.modelState(isReady: appState?.sttRouter.isModelLoaded)
            )
        } else if let copyReason = pasteOutcome.copyReason {
            ProductFrictionTelemetry.track(
                surface: .dictation,
                stage: "pasteback",
                result: .fallback,
                failureKind: "pasteback_\(copyReason.diagnosticName)",
                elapsedBucket: AnalyticsReporter.durationBucket(seconds: elapsedSeconds),
                routeShape: dictationAnalyticsProperties()["route_shape"],
                modelState: ProductFrictionTelemetry.modelState(isReady: appState?.sttRouter.isModelLoaded)
            )
        }

        guard !saveSucceeded else { return }
        ProductFrictionTelemetry.track(
            surface: .dictation,
            stage: "artifact_save",
            result: .failed,
            failureKind: "dictation_save_failed",
            elapsedBucket: AnalyticsReporter.durationBucket(seconds: elapsedSeconds),
            routeShape: dictationAnalyticsProperties()["route_shape"],
            modelState: ProductFrictionTelemetry.modelState(isReady: appState?.sttRouter.isModelLoaded)
        )
    }

    private func recordDictationStopLatency(
        appState: TranscriptedAppState,
        timing: DictationStopTiming,
        sessionID: UUID,
        stopTrigger: DictationTrigger,
        startTrigger: DictationTrigger,
        pasteOutcome: DictationPasteOutcome,
        autoSendOutcome: DictationAutoSendOutcome,
        wordCount: Int,
        charCount: Int,
        cleanupEnabled: Bool,
        cleanupChanged: Bool,
        saveSucceeded: Bool
    ) {
        let measurements = timing.measurements()
        let saveOutcome = saveSucceeded ? "saved" : "failed"
        let outcome: String
        if !saveSucceeded {
            outcome = "save_failed"
        } else if pasteOutcome.delivery == .failed {
            outcome = "delivery_failed"
        } else {
            outcome = "completed"
        }

        var localContext: [String: String] = [
            "dictation_session_id": sessionID.uuidString,
            "start_trigger": startTrigger.rawValue,
            "stop_trigger": stopTrigger.rawValue,
            "delivery": pasteOutcome.delivery.rawValue,
            "auto_send": autoSendOutcome.diagnosticName,
            "save_outcome": saveOutcome,
            "outcome": outcome,
            "cleanup_enabled": "\(cleanupEnabled)",
            "cleanup_changed": "\(cleanupChanged)",
            "chars": "\(charCount)",
            "words": "\(wordCount)",
        ]
        if let copyReason = pasteOutcome.copyReason?.diagnosticName {
            localContext["copy_reason"] = copyReason
        }
        for (key, value) in measurements {
            localContext[key] = "\(value)"
        }

        DiagnosticsTrail.record(
            logger: appState.logger,
            level: pasteOutcome.delivery == .pasted && saveSucceeded ? .info : .warning,
            engine: "dictation",
            event: "dictation_stop_latency_measured",
            message: "Measured dictation stop latency",
            context: dictationContext(extra: localContext)
        )

        var analyticsProperties = dictationAnalyticsProperties(
            extra: [
                "trigger": stopTrigger.rawValue,
                "delivery": pasteOutcome.delivery.rawValue,
                "auto_send": autoSendOutcome.diagnosticName,
                "save_outcome": saveOutcome,
                "outcome": outcome,
                "cleanup_enabled": "\(cleanupEnabled)",
                "cleanup_changed": "\(cleanupChanged)",
                "word_count_bucket": AnalyticsReporter.wordCountBucket(wordCount),
            ]
        )
        if let copyReason = pasteOutcome.copyReason?.diagnosticName {
            analyticsProperties["copy_reason"] = copyReason
        }
        let autoSendTelemetry = DictationAutoSendTelemetry.snapshot(
            request: autoSendRequestDecision,
            pasteOutcome: pasteOutcome,
            sendOutcome: autoSendOutcome
        )
        analyticsProperties.merge(autoSendTelemetry.analyticsProperties) { _, new in new }
        analyticsProperties["target_confirmation_mode"] = DictationTargetConfirmationMode.resolve(
            outcome: pasteOutcome,
            diagnostic: textPaster.lastConfirmationDiagnostic
        ).rawValue
        let timingBuckets: [(metric: String, bucket: String)] = [
            ("stop_to_mic_stop_ms", "mic_stop_bucket"),
            ("model_wait_ms", "model_wait_bucket"),
            ("decode_ms", "decode_bucket"),
            ("cleanup_ms", "cleanup_bucket"),
            ("paste_ms", "paste_bucket"),
            ("auto_enter_ms", "auto_enter_bucket"),
            ("save_ms", "save_bucket"),
            ("stop_to_paste_ms", "stop_to_paste_bucket"),
            ("stop_to_done_ms", "stop_to_done_bucket"),
        ]
        for timingBucket in timingBuckets {
            guard let milliseconds = measurements[timingBucket.metric] else { continue }
            analyticsProperties[timingBucket.bucket] = AnalyticsReporter.latencyBucket(milliseconds: milliseconds)
        }

        AnalyticsReporter.track(
            "dictation_stop_latency_measured",
            properties: analyticsProperties
        )
    }

    private func dictationContext(extra: [String: String] = [:]) -> [String: String] {
        var context: [String: String] = [
            "session_id": currentDictationSessionID.uuidString,
            "correlation_id": currentDictationSessionID.uuidString,
            "trigger": currentDictationTrigger.rawValue,
            "audio_device": appState?.sttRouter.inputDeviceName ?? ""
        ]
        if let routeContext = appState?.sttRouter.dictationAudioRouteAnalyticsContext {
            for (key, value) in routeContext {
                context[key] = value
            }
        }

        for (key, value) in extra {
            context[key] = value
        }

        return context
    }

    private func dictationAnalyticsProperties(extra: [String: String] = [:]) -> [String: String] {
        var properties = appState?.sttRouter.dictationAudioRouteAnalyticsContext ?? [:]
        properties["session_id"] = currentDictationSessionID.uuidString
        properties["correlation_id"] = currentDictationSessionID.uuidString
        properties["trigger"] = currentDictationTrigger.rawValue
        for (key, value) in extra {
            properties[key] = value
        }
        return properties
    }
}

// DictationReadinessRefreshRunner and DictationReadinessRefreshTimeout moved
// to Sources/Speech/DictationSession.swift along with the recovery wait loop
// that owns them.

private struct DictationStopTiming {
    let requestedAt: CFAbsoluteTime
    var micStoppedAt: CFAbsoluteTime?
    var snapshotStartedAt: CFAbsoluteTime?
    var snapshotFinishedAt: CFAbsoluteTime?
    var recoveryCheckpointStartedAt: CFAbsoluteTime?
    var recoveryCheckpointFinishedAt: CFAbsoluteTime?
    var modelWaitStartedAt: CFAbsoluteTime?
    var modelReadyAt: CFAbsoluteTime?
    var transcriptionStartedAt: CFAbsoluteTime?
    var transcribedAt: CFAbsoluteTime?
    var cleanedAt: CFAbsoluteTime?
    var pasteStartedAt: CFAbsoluteTime?
    var pastedAt: CFAbsoluteTime?
    var pasteBreakdown: ClipboardPasteTiming?
    var autoEnterStartedAt: CFAbsoluteTime?
    var autoEnterFinishedAt: CFAbsoluteTime?
    var finalizationStartedAt: CFAbsoluteTime?
    var savePublishedAt: CFAbsoluteTime?
    var saveStartedAt: CFAbsoluteTime?
    var savedAt: CFAbsoluteTime?
    var completedAt: CFAbsoluteTime?

    func measurements() -> [String: Int] {
        var values: [String: Int] = [:]
        values["stop_to_mic_stop_ms"] = milliseconds(from: requestedAt, to: micStoppedAt)
        values["snapshot_resample_ms"] = milliseconds(from: snapshotStartedAt, to: snapshotFinishedAt)
        values["recovery_checkpoint_ms"] = milliseconds(
            from: recoveryCheckpointStartedAt,
            to: recoveryCheckpointFinishedAt
        )
        values["mic_stop_to_decode_start_ms"] = milliseconds(from: micStoppedAt, to: transcriptionStartedAt)
        values["model_wait_ms"] = milliseconds(from: modelWaitStartedAt, to: modelReadyAt)
        values["decode_ms"] = milliseconds(from: transcriptionStartedAt, to: transcribedAt)
        values["cleanup_ms"] = milliseconds(from: transcribedAt, to: cleanedAt)
        values["paste_ms"] = milliseconds(from: pasteStartedAt, to: pastedAt)
        if let pasteBreakdown {
            values.merge(pasteBreakdown.measurements()) { _, new in new }
            values["stop_to_paste_dispatch_ms"] = milliseconds(
                from: requestedAt,
                to: pasteBreakdown.dispatchFinishedAt
            )
        }
        values["auto_enter_ms"] = milliseconds(from: autoEnterStartedAt, to: autoEnterFinishedAt)
        values["save_ms"] = milliseconds(from: saveStartedAt, to: savedAt)
        values["save_publication_wait_ms"] = milliseconds(from: savedAt, to: savePublishedAt)
        values["finalization_ms"] = milliseconds(from: finalizationStartedAt, to: savePublishedAt)
        values["stop_to_paste_ms"] = milliseconds(from: requestedAt, to: pastedAt)
        values["stop_to_save_ms"] = milliseconds(from: requestedAt, to: savedAt)
        values["stop_to_done_ms"] = milliseconds(from: requestedAt, to: completedAt)
        return values
    }

    private func milliseconds(from start: CFAbsoluteTime?, to end: CFAbsoluteTime?) -> Int? {
        guard let start, let end else { return nil }
        return max(0, Int(((end - start) * 1_000).rounded()))
    }
}

private typealias DictationPasteOutcome = TextPasteOutcome

private extension TextPasteOutcome {
    var delivery: DictationDelivery {
        switch self {
        case .pasted:
            return .pasted
        case .copied:
            return .copied
        case .failed:
            return .failed
        }
    }

    var diagnosticLevel: EventLevel {
        switch self {
        case .pasted:
            return .info
        case .copied(_, reason: let reason) where reason.isPasteConfirmationUnavailable:
            return .info
        case .copied:
            return .warning
        case .failed:
            return .error
        }
    }
}

private extension TextPasteCopyReason {
    var isPasteConfirmationUnavailable: Bool {
        switch self {
        case .pasteConfirmationUnavailable:
            return true
        case .accessibilityMissing, .pasteEventCreationFailed, .focusChanged, .pasteNotConfirmed:
            return false
        }
    }

    var diagnosticName: String {
        switch self {
        case .accessibilityMissing:
            return "accessibility_missing"
        case .pasteEventCreationFailed:
            return "paste_event_creation_failed"
        case .focusChanged:
            return "focus_changed"
        case .pasteNotConfirmed:
            return "paste_not_confirmed"
        case .pasteConfirmationUnavailable:
            return "paste_confirmation_unavailable"
        }
    }
}

// AVAuthorizationStatus.diagnosticName is defined once in
// Sources/Support/TranscriptedPermissionAccess.swift and reused here.
