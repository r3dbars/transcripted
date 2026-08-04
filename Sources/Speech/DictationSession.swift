// DictationSession.swift
// Engine-facing dictation orchestration: owns the recovery wait-loop state
// machine and the other STTRouter-facing control-flow decisions that used to
// live inside DictationSessionController (an AppKit/overlay presenter).
//
// This type intentionally does not import AppKit overlay types. It talks to
// STTRouter/ParakeetEngine directly and reports back through plain data
// (outcomes, status snapshots) and injected closures for the handful of
// presentation touchpoints (loading-state updates) that must happen at an
// exact point inside the wait loop. DictationSessionController remains the
// place that turns those into FloatingOverlayController calls, plays sounds,
// and owns panel geometry/tooltips/accessibility.
//
// Lives in Sources/Speech/ (not Sources/Dictation/) because Sources/Dictation
// is scoped to persistence helpers only — its own CLAUDE.md says recording
// lifecycle changes belong in DictationSessionController and Sources/Speech/.
// Sources/Speech/ already owns STTRouter/ParakeetEngine and the readiness
// policies (DictationReadinessWaitPolicy, ParakeetRecoveryState) this type
// consults, so it is the natural @MainActor home for the engine-facing half
// of a dictation session.
//
// The DictationSession class itself and its pure value/decision types
// (WaitStatus, StartOutcome, StartPathDecision, ...) are declared in the
// sibling DictationSessionTypes.swift so the fast test runner can compile
// and exercise them without this file's TranscriptedAppState dependency.
// This file is everything that actually touches TranscriptedAppState/STTRouter.
//
// This type does not publish its own lifecycle/state — see the NOTE at the
// top of DictationSessionTypes.swift for why.

import Foundation

extension DictationSession {
    // MARK: - Meeting-mic sharing / availability

    func canUseActiveMeetingMicForDictation(appState: TranscriptedAppState) -> Bool {
        guard #available(macOS 14.0, *) else { return false }
        return appState.meetingSession.canShareMicWithDictation
    }

    func dictationStartUnavailableReason(appState: TranscriptedAppState) -> String? {
        guard #available(macOS 14.0, *) else { return nil }
        return DictationStartAvailabilityPolicy.unavailableReason(
            hasActiveMeetingCapture: appState.meetingSession.shouldBlockDictationForActiveMeetingCapture,
            canShareMeetingMic: appState.meetingSession.canShareMicWithDictation,
            isSpeakerReviewPending: appState.meetingSession.isSpeakerReviewPending
        )
    }

    // MARK: - Recording start

    func startPathDecision(appState: TranscriptedAppState) -> StartPathDecision {
        .decide(
            isRecordingModelLoaded: appState.sttRouter.isRecordingModelLoaded,
            selectedModelFilesAvailableLocally: appState.sttRouter.selectedModelFilesAvailableLocally
        )
    }

    func startDictationAudioRecording(
        appState: TranscriptedAppState,
        isRecoveryAttempt: Bool = false
    ) async -> Bool {
        if canUseActiveMeetingMicForDictation(appState: appState) {
            if appState.meetingSession.startDictationFromActiveMeetingMic() {
                return true
            }
            // The meeting may have entered stop between the caller's first
            // observation and the atomic handoff. Only fall back to the
            // normal mic once capture no longer owns the route.
            if canUseActiveMeetingMicForDictation(appState: appState) {
                return false
            }
        }
        if isRecoveryAttempt {
            return await appState.sttRouter.startRecordingRecoveryAttempt()
        }
        return await appState.sttRouter.startRecording()
    }

    /// Reads the current fast-path plan (skip loading vs. wait) from the live
    /// STTRouter recovery flags, mirroring the read `beginDictationRecording`
    /// used to make before it decides whether to show loading UI.
    func recordingStartPlan(
        appState: TranscriptedAppState,
        canUseMeetingMic: Bool
    ) -> DictationRecordingStartOverlayPolicy.Plan {
        DictationRecordingStartOverlayPolicy.plan(
            isRecovering: canUseMeetingMic ? false : appState.sttRouter.isRecovering,
            inputFormatReady: canUseMeetingMic ? true : appState.sttRouter.inputFormatReady
        )
    }

    // MARK: - Engine reset / cancel

    /// The STTRouter-touching half of the controller's failed-start cleanup.
    /// The controller still owns clearing its own task handles and
    /// `isDictating` — this only performs the engine-facing reset, in the
    /// same order the inline version did.
    func resetEngineAfterFailedStart(
        appState: TranscriptedAppState,
        hardReset: Bool,
        reason: String
    ) async {
        if hardReset {
            appState.sttRouter.abandonBlockedRecordingStart(reason: reason)
        } else {
            await appState.sttRouter.resetAfterFailedRecordingStart()
        }
    }

    /// The STTRouter-touching half of the controller's active-task
    /// cancellation. Callers gate this on
    /// `DictationActiveTaskCancellationPolicy.plan(...).cancelSpeechEngine`.
    func cancelEngine(appState: TranscriptedAppState) {
        appState.sttRouter.cancel()
    }

    // MARK: - Model warmup wait loop

    /// The model-warmup wait loop that used to live inline inside
    /// `DictationSessionController.startDictationAfterWarmup`: decides
    /// whether to retry a failed load, join an in-flight download/load, or
    /// kick a fresh initialization, purely from `STTRouter
    /// .recordingModelDownloadState`. The controller turns `onModelStateUpdate`
    /// snapshots into loading-overlay presentation and reacts to the outcome.
    func waitForModelAndStart(
        appState: TranscriptedAppState,
        isDictating: @escaping () -> Bool,
        onModelStateUpdate: @escaping (ParakeetModelState) -> Void
    ) async -> ModelWarmupOutcome {
        if case .failed = appState.sttRouter.recordingModelDownloadState {
            // A previous attempt failed; retry once before the wait loop
            // treats .failed as terminal.
            await appState.sttRouter.initializeRecordingModel()
        }

        let deadline = ProcessInfo.processInfo.systemUptime
            + TranscriptedConstants.modelLoadWaitBudget
        while ProcessInfo.processInfo.systemUptime < deadline {
            guard !Task.isCancelled, isDictating() else { return .aborted }

            let modelState = appState.sttRouter.recordingModelDownloadState
            onModelStateUpdate(modelState)

            switch modelState {
            case .ready:
                return .ready
            case .failed(let message):
                return .failed(message)
            case .notLoaded, .cached:
                let stateBefore = appState.sttRouter.recordingModelDownloadState.diagnosticName
                await appState.sttRouter.initializeRecordingModel()
                // If initialization bailed without progressing (e.g.
                // mid-shutdown), sleep so this loop can't spin hot.
                if appState.sttRouter.recordingModelDownloadState.diagnosticName == stateBefore {
                    try? await Task.sleep(nanoseconds: TranscriptedConstants.modelLoadPollInterval)
                }
            case .downloading, .loading:
                // Downloads publish progress the overlay refreshes on a
                // short poll; an in-flight load is joined directly so
                // recording starts the moment it settles.
                await appState.sttRouter.waitForRecordingModelLoadProgress()
            }
        }

        guard !Task.isCancelled else { return .aborted }
        return .timedOut
    }

    // MARK: - Recovery wait loop

    /// The recovery wait-loop state machine that used to live inline inside
    /// `DictationSessionController.waitForEngineAndStart`. Collapses the
    /// former `.startRecoveryRecording` / `.startRecording` switch cases
    /// (see PR body for the verbatim before/after diff) into a single
    /// `performStartAttempt` path parameterized on `isRecoveryAttempt`.
    ///
    /// The caller (the controller) is responsible for the up-front
    /// microphone-permission gate — that's a permission concern, not an
    /// STTRouter one. `onWaitUpdate` snapshots turn into loading-overlay
    /// presentation; `onRecordingStarted` is invoked the instant a start
    /// attempt succeeds — matching the original inline order exactly, it
    /// runs BEFORE this function's own stage-record/log calls, so the
    /// overlay flips to `.listening` before any "started after wait"
    /// telemetry fires (see the PR's ordering note). Sound and
    /// session-timeout installation still happen after the call returns,
    /// driven off the returned `.started` outcome.
    func waitForEngineAndStart(
        appState: TranscriptedAppState,
        sessionStartTime: CFAbsoluteTime,
        isDictating: @escaping () -> Bool,
        onWaitUpdate: @escaping (WaitStatus) -> Void,
        onRecordingStarted: @escaping () -> Void
    ) async -> StartOutcome {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let deadline = startedAt + TranscriptedConstants.dictationRecoveryBudget
        var startAttempts = 0
        var readyStartFailures = 0
        var recoveryStartAttempts = 0
        var readinessRefreshes = 0
        var forcedReadinessRecoveries = 0
        var readinessRefreshTimedOut = false
        var nextReadinessRefreshAt = startedAt
        let readinessRefresher = DictationReadinessRefreshRunner()
        defer {
            readinessRefresher.cancel()
        }

        if !appState.sttRouter.isRecovering, !appState.sttRouter.inputFormatReady {
            if readinessRefresher.start(appState: appState) {
                readinessRefreshes += 1
            }
            nextReadinessRefreshAt = ProcessInfo.processInfo.systemUptime + TranscriptedConstants.dictationReadinessRefreshInterval
        }

        while ProcessInfo.processInfo.systemUptime < deadline {
            guard isDictating(), !Task.isCancelled else { return .aborted }

            let now = ProcessInfo.processInfo.systemUptime
            if let staleRefresh = readinessRefresher.cancelIfTimedOut(now: now) {
                readinessRefreshTimedOut = true
                DiagnosticsTrail.record(
                    logger: appState.logger,
                    level: .warning,
                    engine: "dictation",
                    event: "dictation_readiness_refresh_timeout",
                    message: "Dictation input-readiness refresh timed out while waiting to start",
                    context: dictationContext(
                        appState: appState,
                        extra: [
                            "operation": staleRefresh.operation,
                            "elapsed_ms": "\(Int(staleRefresh.elapsed * 1000))",
                            "readiness_refreshes": "\(readinessRefreshes)",
                            "is_recovering": "\(appState.sttRouter.isRecovering)",
                            "format_ready": "\(appState.sttRouter.inputFormatReady)"
                        ]
                    )
                )
            }

            let elapsed = now - startedAt
            let isRecovering = appState.sttRouter.isRecovering
            let inputFormatReady = appState.sttRouter.inputFormatReady
            onWaitUpdate(
                WaitStatus(
                    elapsed: elapsed,
                    deviceName: appState.sttRouter.inputDeviceName,
                    isRecovering: isRecovering,
                    inputFormatReady: inputFormatReady,
                    startAttempts: startAttempts
                )
            )

            let action = DictationReadinessWaitPolicy.action(
                isRecovering: isRecovering,
                inputFormatReady: inputFormatReady,
                readyStartFailures: readyStartFailures,
                readinessRefreshes: readinessRefreshes,
                forcedRecoveryAttempts: forcedReadinessRecoveries,
                recoveryStartAttempts: recoveryStartAttempts,
                readinessRefreshTimedOut: readinessRefreshTimedOut
            )
            switch action {
            case .waitForRecovery:
                break

            case .refreshInputReadiness:
                if now >= nextReadinessRefreshAt {
                    if readinessRefresher.start(appState: appState) {
                        readinessRefreshes += 1
                    }
                    nextReadinessRefreshAt = ProcessInfo.processInfo.systemUptime + TranscriptedConstants.dictationReadinessRefreshInterval
                }

            case .forceInputRecovery:
                if readinessRefresher.startForcedRecovery(
                    appState: appState,
                    reason: "dictation_readiness_wait_stalled"
                ) {
                    forcedReadinessRecoveries += 1
                    readinessRefreshes = 0
                    nextReadinessRefreshAt = ProcessInfo.processInfo.systemUptime + TranscriptedConstants.dictationReadinessRefreshInterval
                }

            case .startRecoveryRecording, .startRecording:
                let isRecoveryAttempt = (action == .startRecoveryRecording)
                let outcome = await performStartAttempt(
                    appState: appState,
                    isRecoveryAttempt: isRecoveryAttempt,
                    startedAt: startedAt,
                    sessionStartTime: sessionStartTime,
                    isDictating: isDictating,
                    onRecordingStarted: onRecordingStarted,
                    startAttempts: &startAttempts,
                    recoveryStartAttempts: &recoveryStartAttempts,
                    readyStartFailures: &readyStartFailures,
                    readinessRefreshTimedOut: &readinessRefreshTimedOut,
                    readinessRefreshes: &readinessRefreshes,
                    readinessRefresher: readinessRefresher,
                    nextReadinessRefreshAt: &nextReadinessRefreshAt
                )
                switch outcome {
                case .aborted:
                    return .aborted
                case .started(let info):
                    return .started(info)
                case .retrying:
                    break
                }
            }

            try? await Task.sleep(nanoseconds: TranscriptedConstants.dictationReadinessPollInterval)
        }

        guard isDictating(), !Task.isCancelled else { return .aborted }
        readinessRefresher.cancel()

        let cleanupPlan = DictationRecordingStartFailurePolicy.cleanupPlan(for: "microphone_start_timeout")
        DiagnosticsTrail.record(
            logger: appState.logger,
            level: .error,
            engine: "dictation",
            event: "microphone_start_timeout",
            message: "Dictation recording failed to start within recovery budget",
            context: dictationContext(
                appState: appState,
                extra: [
                    "wait_ms": "\(Int(TranscriptedConstants.dictationRecoveryBudget * 1000))",
                    "audio_device": appState.sttRouter.inputDeviceName,
                    "failure_kind": "microphone_start_timeout",
                    "is_recovering": "\(appState.sttRouter.isRecovering)",
                    "format_ready": "\(appState.sttRouter.inputFormatReady)",
                    "start_attempts": "\(startAttempts)",
                    "readiness_refreshes": "\(readinessRefreshes)",
                    "recovery_start_attempts": "\(recoveryStartAttempts)",
                    "forced_readiness_recoveries": "\(forcedReadinessRecoveries)"
                ]
            )
        )
        return .timedOut(
            TimedOutInfo(
                startAttempts: startAttempts,
                readinessRefreshes: readinessRefreshes,
                recoveryStartAttempts: recoveryStartAttempts,
                forcedReadinessRecoveries: forcedReadinessRecoveries,
                cleanupPlan: cleanupPlan
            )
        )
    }

    fileprivate enum StartAttemptOutcome {
        case aborted
        case started(StartedInfo)
        case retrying
    }

    /// The merged `.startRecoveryRecording` / `.startRecording` execution
    /// path. See the PR body for the verbatim before/after diff proving this
    /// collapse is faithful to both original branches.
    fileprivate func performStartAttempt(
        appState: TranscriptedAppState,
        isRecoveryAttempt: Bool,
        startedAt: TimeInterval,
        sessionStartTime: CFAbsoluteTime,
        isDictating: () -> Bool,
        onRecordingStarted: () -> Void,
        startAttempts: inout Int,
        recoveryStartAttempts: inout Int,
        readyStartFailures: inout Int,
        readinessRefreshTimedOut: inout Bool,
        readinessRefreshes: inout Int,
        readinessRefresher: DictationReadinessRefreshRunner,
        nextReadinessRefreshAt: inout TimeInterval
    ) async -> StartAttemptOutcome {
        startAttempts += 1
        if isRecoveryAttempt {
            recoveryStartAttempts += 1
            readinessRefreshTimedOut = false
            DiagnosticsTrail.record(
                logger: appState.logger,
                level: .warning,
                engine: "dictation",
                event: "dictation_recording_recovery_start",
                message: "Dictation forcing one recovery recording start after stale readiness refreshes",
                context: dictationContext(
                    appState: appState,
                    extra: [
                        "attempt": "\(startAttempts)",
                        "readiness_refreshes": "\(readinessRefreshes)",
                        "is_recovering": "\(appState.sttRouter.isRecovering)",
                        "format_ready": "\(appState.sttRouter.inputFormatReady)"
                    ]
                )
            )
        }

        let started = await startDictationAudioRecording(appState: appState, isRecoveryAttempt: isRecoveryAttempt)
        guard !Task.isCancelled, isDictating() else {
            if started {
                await appState.sttRouter.stopRecording()
            }
            return .aborted
        }

        if started {
            // Flip the overlay to .listening (and resize) BEFORE the stage
            // record / "started after wait" logs below — matching both
            // original inline branches, which set `overlayController.state
            // = .listening` first and only logged afterward. Firing
            // telemetry before the overlay update would make it look like
            // the app is still loading while it has already started.
            onRecordingStarted()
            appState.runtimeDiagnostics.recordSession(kind: "dictation", stage: "recording_after_wait")
            let waited = Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000)
            let requestToRecordingMs = Int((CFAbsoluteTimeGetCurrent() - sessionStartTime) * 1000)
            if isRecoveryAttempt {
                appState.logger.log("DICTATION | started after forced recovery start and \(waited)ms wait (parakeet, \(appState.sttRouter.inputDeviceName))")
                DiagnosticsTrail.record(
                    logger: appState.logger,
                    engine: "dictation",
                    event: "dictation_started_after_wait",
                    message: "Dictation started after forcing a recovery recording start",
                    context: dictationContext(
                        appState: appState,
                        extra: [
                            "request_to_recording_ms": "\(requestToRecordingMs)",
                            "wait_ms": "\(waited)",
                            "start_attempts": "\(startAttempts)",
                            "readiness_refreshes": "\(readinessRefreshes)"
                        ]
                    )
                )
            } else {
                appState.logger.log("DICTATION | started after \(waited)ms wait (parakeet, \(appState.sttRouter.inputDeviceName))")
                DiagnosticsTrail.record(
                    logger: appState.logger,
                    engine: "dictation",
                    event: "dictation_started_after_wait",
                    message: "Dictation started after waiting for engine readiness",
                    context: dictationContext(
                        appState: appState,
                        extra: [
                            "request_to_recording_ms": "\(requestToRecordingMs)",
                            "wait_ms": "\(waited)",
                            "audio_device": appState.sttRouter.inputDeviceName,
                            "start_attempts": "\(startAttempts)",
                            "readiness_refreshes": "\(readinessRefreshes)"
                        ]
                    )
                )
            }
            return .started(
                StartedInfo(
                    isRecoveryAttempt: isRecoveryAttempt,
                    waitedMs: waited,
                    requestToRecordingMs: requestToRecordingMs,
                    startAttempts: startAttempts,
                    readinessRefreshes: readinessRefreshes
                )
            )
        }

        if isRecoveryAttempt {
            readinessRefreshes = 0
            if readinessRefresher.start(appState: appState) {
                readinessRefreshes += 1
            }
            nextReadinessRefreshAt = ProcessInfo.processInfo.systemUptime + TranscriptedConstants.dictationReadinessRefreshInterval
        } else {
            readyStartFailures += 1
            DiagnosticsTrail.record(
                logger: appState.logger,
                level: .warning,
                engine: "dictation",
                event: "dictation_recording_retry",
                message: "Dictation microphone start failed; retrying",
                context: dictationContext(
                    appState: appState,
                    extra: [
                        "attempt": "\(startAttempts)",
                        "audio_device": appState.sttRouter.inputDeviceName,
                        "is_recovering": "\(appState.sttRouter.isRecovering)",
                        "format_ready": "\(appState.sttRouter.inputFormatReady)"
                    ]
                )
            )
            if !appState.sttRouter.isRecovering {
                if readinessRefresher.start(appState: appState) {
                    readinessRefreshes += 1
                }
                nextReadinessRefreshAt = ProcessInfo.processInfo.systemUptime + TranscriptedConstants.dictationReadinessRefreshInterval
            }
        }
        return .retrying
    }

    fileprivate func dictationContext(
        appState: TranscriptedAppState,
        extra: [String: String] = [:]
    ) -> [String: String] {
        var context: [String: String] = [
            "audio_device": appState.sttRouter.inputDeviceName
        ]
        for (key, value) in appState.sttRouter.dictationAudioRouteAnalyticsContext {
            context[key] = value
        }
        for (key, value) in extra {
            context[key] = value
        }
        return context
    }
}

/// Runs the async `refreshInputReadiness` / `forceInputReadinessRecovery`
/// STTRouter calls the wait loop above kicks off, tracking a generation
/// counter so a superseded refresh can't clobber a newer one and exposing a
/// simple timeout check the loop consults each iteration.
@MainActor
private final class DictationReadinessRefreshRunner {
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var operation: String?
    private var startedAt: TimeInterval?

    func start(appState: TranscriptedAppState) -> Bool {
        start(operation: "refresh_input_readiness") {
            await appState.sttRouter.refreshInputReadiness()
        }
    }

    func startForcedRecovery(appState: TranscriptedAppState, reason: String) -> Bool {
        if task != nil, operation != "force_input_recovery" {
            cancel()
        }
        return start(operation: "force_input_recovery") {
            await appState.sttRouter.forceInputReadinessRecovery(reason: reason)
        }
    }

    func cancelIfTimedOut(now: TimeInterval) -> DictationReadinessRefreshTimeout? {
        guard task != nil,
              DictationReadinessRefreshTimeoutPolicy.timedOut(startedAt: startedAt, now: now) else {
            return nil
        }

        let stale = DictationReadinessRefreshTimeout(
            operation: operation ?? "unknown",
            elapsed: now - (startedAt ?? now)
        )
        generation &+= 1
        task?.cancel()
        task = nil
        operation = nil
        startedAt = nil
        return stale
    }

    func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
        operation = nil
        startedAt = nil
    }

    private func start(
        operation operationName: String,
        _ body: @escaping @MainActor () async -> Void
    ) -> Bool {
        guard task == nil else { return false }
        generation &+= 1
        let taskGeneration = generation
        operation = operationName
        startedAt = ProcessInfo.processInfo.systemUptime
        task = Task { @MainActor [weak self] in
            guard !Task.isCancelled else { return }
            guard self?.generation == taskGeneration else { return }
            await body()
            guard !Task.isCancelled else { return }
            guard self?.generation == taskGeneration else { return }
            self?.task = nil
            self?.operation = nil
            self?.startedAt = nil
        }
        return true
    }
}

private struct DictationReadinessRefreshTimeout {
    let operation: String
    let elapsed: TimeInterval
}
