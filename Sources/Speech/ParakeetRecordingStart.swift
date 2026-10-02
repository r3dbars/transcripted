// ParakeetRecordingStart.swift
// Dictation recording start for ParakeetEngine: the startRecording state
// machine, start-failure reporting and graph reset, the call-app
// microphone-sharing recheck, and the startup watchdog / zombie-recovery
// cancellation. Split out of ParakeetEngine.swift.
//
// startRecording asks the pinned-microphone path first
// (startPinnedDictationRecordingIfEnabled) before any engine attempt, so a
// Bluetooth default input is not bound when the pinned path records.
//
// These are internal collaborator methods on ParakeetEngine. ParakeetEngine
// (ParakeetEngine.swift) stays the public-API owner and @MainActor home for
// the state; this file only groups one slice of its implementation.

@preconcurrency import AVFoundation
import Foundation
import TranscriptedCore

extension ParakeetEngine {
    // MARK: - Recording

    private static func timingContext(_ timings: [String: Int]) -> [String: String] {
        timings.reduce(into: [:]) { context, entry in
            context[entry.key] = "\(entry.value)"
        }
    }

    func shareMicrophoneWithCallAppIfNeeded() async {
        guard await audioGraph.callAppMayDowngradeVoiceProcessing(
            isAllowed: { microphoneSharingDowngradeIsAllowed() }
        ) else { return }
        // Reuse the owned recovery path so already-spoken audio survives the
        // VPIO -> regular-input transition when a call app opens during dictation.
        await recoverForMicrophoneSharing()
    }

    private func microphoneSharingDowngradeIsAllowed() -> Bool {
        ParakeetMicrophoneSharingPolicy.mayDowngrade(
            callAppRunning: CallAppMicrophoneSharingMonitor.shared.isCallAppRunning,
            isRecording: isRecording,
            borrowsMeetingMic: sharedMeetingMicClaim != nil,
            audioStartInProgress: audioStartInProgress,
            audioStopInProgress: audioStopInProgress,
            isShuttingDown: isShuttingDown
        )
    }

    private func resetAudioGraphAfterStartFailure(
        reason: String,
        rebuildEngine: Bool
    ) async -> ParakeetAudioGraphOwnerToken? {
        // Keep runtime/UI state coherent when startRecording fails before we ever
        // transition to a stable recording session.
        cancelAudioWatchdogForRecordingStart()
        isRecording = false
        audioLevel = 0
        didReceiveAudioSamples = false
        didReceiveNonZeroAudioSamples = false
        recordingStartedOnLikelyBluetoothHandsFreeRoute = false

        // Reset/rebuild can block in CoreAudio too. The graph keeps the
        // admitted start's exact resources claimable so a user stop can replace
        // this queue immediately instead of making the successor wait on stale
        // cleanup.
        return await audioGraph.resetAfterStartFailure(
            reason: reason,
            rebuildEngine: rebuildEngine
        )
    }

    private func audioStartContext(
        attempt: Int,
        isRecoveryAttempt: Bool,
        engineWasRunning: Bool,
        outputFormat: ParakeetAudioFormatSummary,
        hwFormat: ParakeetAudioFormatSummary,
        error: Error? = nil
    ) -> [String: String] {
        var context = [
            "attempt": "\(attempt)",
            "start_mode": isRecoveryAttempt ? "recovery" : "normal",
            "recovering": "\(recoveryState.isRecovering)",
            "format_ready": "\(recoveryState.inputFormatReady)",
            "generation": "\(recoveryState.generation)",
            "prewarmed": "\(isEnginePrewarmed)",
            "engine_running_before_start": "\(engineWasRunning)",
            "tap_installed": "\(inputTapInstalled)",
            "output_rate_hz": String(format: "%.0f", outputFormat.sampleRate),
            "output_channels": "\(outputFormat.channelCount)",
            "input_rate_hz": String(format: "%.0f", hwFormat.sampleRate),
            "hw_channels": "\(hwFormat.channelCount)",
            "input_device_class": inputDeviceClass(for: inputDeviceName),
        ]

        if let error {
            let nsError = error as NSError
            context["status_domain"] = nsError.domain
            context["status_code"] = "\(nsError.code)"
        }

        return context
    }

    private func reportAudioStartFailureIfNeeded(message: String, context: [String: String]) {
        let now = CFAbsoluteTimeGetCurrent()
        guard ParakeetAudioStartRecoveryPolicy.shouldReportFailure(
            now: now,
            lastReportAt: lastAudioStartFailureReportAt
        ) else {
            EventReporter.shared.capture(
                level: .warning,
                engine: "parakeet",
                event: "audio_engine_start_failed",
                message: message,
                context: context.merging(["report_throttled": "true"]) { current, _ in current }
            )
            return
        }

        lastAudioStartFailureReportAt = now
        EventReporter.shared.capture(
            level: .error,
            engine: "parakeet",
            event: "audio_engine_start_failed",
            message: message,
            context: context
        )
    }

    func startRecording(isRecoveryAttempt: Bool = false) async -> Bool {
        lastRecordingStartFailureReason = nil
        guard !isShuttingDown, !Task.isCancelled else { return false }
        guard !isRecording else { return true }
        guard !audioStartInProgress else {
            EventReporter.shared.capture(
                level: .warning,
                engine: "parakeet",
                event: "audio_start_deferred",
                message: "Audio start requested while another start is still in progress",
                context: [
                    "recovering": "\(recoveryState.isRecovering)",
                    "format_ready": "\(recoveryState.inputFormatReady)",
                    "generation": "\(recoveryState.generation)",
                    "audio_graph_generation": "\(audioGraphGeneration)"
                ]
            )
            return false
        }
        audioStartReferenceTime = CFAbsoluteTimeGetCurrent()
        audioGraphGeneration += 1
        var startOwner = currentAudioEngineQueueOwnerToken()
        guard audioStartAdmission.begin(owner: startOwner) else { return false }
        // Device-change recovery uses the ordinary start/watchdog path but
        // continues the same dictation while its earlier segments are held.
        if ParakeetRecordingContinuityPolicy.startsFreshRecording(
            isRecoveryAttempt: isRecoveryAttempt,
            preservingAcrossRecovery: preservingRecordingAcrossRecovery
        ) {
            beginFreshRecordingSession()
        }
        var startEngine = audioEngine
        var startQueue = audioEngineQueue
        defer {
            audioStartAdmission.finish(owner: startOwner)
        }
        func failAudioStart() async -> Bool {
            // Keep the temporary built-in input selected across the controller's
            // bounded retry loop. The final failure reset, explicit cancel,
            // cleanup, or a successful recording stop owns restoration.
            return false
        }

        scheduleInputDeviceNameRefresh()
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        guard micStatus == .authorized else {
            EventReporter.shared.capture(level: .error, engine: "parakeet", event: "mic_not_authorized",
                message: "Microphone permission status: \(micStatus.rawValue)")
            return await failAudioStart()
        }

        installAudioObserversIfNeeded()
        guard isRecoveryAttempt || recoveryState.canStartRecording else {
            EventReporter.shared.capture(
                level: .warning,
                engine: "parakeet",
                event: "audio_start_deferred",
                message: "Audio start requested while input format is still recovering",
                context: [
                    "recovering": "\(recoveryState.isRecovering)",
                    "format_ready": "\(recoveryState.inputFormatReady)",
                    "generation": "\(recoveryState.generation)"
                ]
            )
            if !recoveryState.isRecovering {
                schedulePrewarmRetry()
            }
            return await failAudioStart()
        }

        recordingInterrupted = false
        didReceiveAudioSamples = false
        didReceiveNonZeroAudioSamples = false
        recordingStartedOnLikelyBluetoothHandsFreeRoute = false
        cancelAudioWatchdogForRecordingStart()
        if ParakeetRecordingContinuityPolicy.startsFreshRecording(
            isRecoveryAttempt: isRecoveryAttempt,
            preservingAcrossRecovery: preservingRecordingAcrossRecovery
        ) {
            recoveredRecordingTimeline.removeAll(keepingCapacity: true)
        }
        pendingSamplesLock.withLock {
            pendingSamples.removeAll(keepingCapacity: true)
            lastAudioSampleAt = 0
            didReportPendingSampleTruncation = false
            if ParakeetRecordingContinuityPolicy.startsFreshRecording(
                isRecoveryAttempt: isRecoveryAttempt,
                preservingAcrossRecovery: preservingRecordingAcrossRecovery
            ) {
                firstAudioSampleAt = nil
            }
        }
        if let pinnedStarted = await startPinnedDictationRecordingIfEnabled(owner: startOwner) {
            return pinnedStarted
        }

        let maxAttempts = isRecoveryAttempt ? 1 : 1 + TranscriptedConstants.audioStartRecoveryAttempts
        for attempt in 1...maxAttempts {
            let attemptOwner = startOwner
            let attemptEngine = startEngine
            let attemptQueue = startQueue
            guard ownsAudioEngineQueue(attemptOwner) else {
                EventReporter.shared.capture(
                    level: .warning,
                    engine: "parakeet",
                    event: "audio_start_aborted",
                    message: "Audio start aborted because the audio graph changed before startup finished",
                    context: ["audio_graph_generation": "\(audioGraphGeneration)"]
                )
                return await failAudioStart()
            }

            // The format reads below use the same serial engine queue as tap
            // installation. Lease them before the first suspension so stop can
            // retire a blocked snapshot instead of stranding the next start.
            let snapshot: ParakeetAudioInputSnapshot
            do {
                snapshot = try await audioGraph.withStartSnapshotLease(
                    owner: attemptOwner,
                    holder: self
                ) { snapshotWorkIsCurrent in
                    try await audioInputSnapshot(
                        operation: "start_recording",
                        allowsBuiltInBluetoothFallback: !isRecoveryAttempt,
                        isEngineWorkCurrent: snapshotWorkIsCurrent
                    )
                }
            } catch {
                guard ownsAudioEngineQueue(attemptOwner) else { return await failAudioStart() }
                let audioEngineWorkError = error as? ParakeetAudioEngineWorkError
                let systemInputWorkError = error as? ParakeetSystemInputWorkError
                let operationTimedOut = audioEngineWorkError?.isTimedOut == true
                    || systemInputWorkError?.isTimedOut == true
                let workCircuitOpen = audioEngineWorkError?.isCircuitOpen == true
                    || systemInputWorkError?.isCircuitOpen == true
                let operationBlocked = operationTimedOut || workCircuitOpen
                let inputBindingFailed = error is DictationInputDeviceBindingError
                lastRecordingStartFailureReason = operationBlocked
                    ? .audioEngineStartTimedOut
                    : inputBindingFailed ? .audioRouteNotSettled : .invalidAudioFormat
                let failureKind = workCircuitOpen
                    ? "audio_engine_work_circuit_open"
                    : operationTimedOut ? "audio_format_read_timeout" : "audio_format_unavailable"
                EventReporter.shared.capture(
                    level: operationBlocked ? .error : .warning,
                    engine: "parakeet",
                    event: failureKind,
                    message: workCircuitOpen
                        ? "Audio engine start was blocked by a prior timed operation"
                        : operationTimedOut
                        ? "Audio hardware format read timed out while starting dictation"
                        : "Audio hardware format could not be read while starting dictation",
                    context: [
                        "attempt": "\(attempt)",
                        "failure_kind": failureKind,
                        "start_mode": isRecoveryAttempt ? "recovery" : "normal",
                        "error": error.localizedDescription
                    ]
                )
                if audioEngineWorkError?.requiresGraphAbandonment == true {
                    guard abandonBlockedAudioEngine(
                        reason: "audio_format_read_timeout",
                        expectedOwner: attemptOwner
                    ) else { return await failAudioStart() }
                } else if audioEngineWorkError?.isCircuitOpen != true && !inputBindingFailed {
                    // Only an audio-engine circuit-open means the engine graph
                    // itself is blocked. A system-input circuit-open comes from
                    // the separate system-input coordinator queue (the Bluetooth
                    // device-property hang), and the graph is still ours to
                    // reset, exactly as before this failure path was typed.
                    guard await resetAudioGraphAfterStartFailure(
                        reason: "audio_format_read_failed",
                        rebuildEngine: true
                    ) != nil else { return await failAudioStart() }
                }
                // A circuit-open failure did not schedule work on this graph,
                // so leave it in place and fail closed. Retiring it would
                // create graph churn without freeing any blocked worker lease.
                markFormatUnreadyAndPublish()
                schedulePrewarmRetry()
                return await failAudioStart()
            }
            guard ownsAudioEngineQueue(attemptOwner) else {
                EventReporter.shared.capture(
                    level: .warning,
                    engine: "parakeet",
                    event: "audio_start_aborted",
                    message: "Audio start aborted because the audio graph changed while reading input format",
                    context: ["audio_graph_generation": "\(audioGraphGeneration)"]
                )
                return await failAudioStart()
            }

            let readiness = audioFormatReadiness(
                outputFormat: snapshot.outputFormat,
                hwFormat: snapshot.hwFormat,
                selection: snapshot.selection
            )
            guard readiness == .ready else {
                let failureReason = readiness.startFailureReason ?? .invalidAudioFormat
                lastRecordingStartFailureReason = failureReason
                let startFailureAction = ParakeetStartRecordingFailurePolicy.action(
                    for: failureReason,
                    isRecoveryAttempt: isRecoveryAttempt
                )
                AppLogger.transcription.warning("PARAKEET | input format unavailable (\(readiness.rawValue)): output=\(snapshot.outputFormat.sampleRate)Hz/\(snapshot.outputFormat.channelCount)ch hw=\(snapshot.hwFormat.sampleRate)Hz/\(snapshot.hwFormat.channelCount)ch")
                var context = audioStartContext(
                    attempt: attempt,
                    isRecoveryAttempt: isRecoveryAttempt,
                    engineWasRunning: snapshot.engineWasRunning,
                    outputFormat: snapshot.outputFormat,
                    hwFormat: snapshot.hwFormat
                )
                context.merge(
                    audioFormatContext(
                        outputFormat: snapshot.outputFormat,
                        hwFormat: snapshot.hwFormat,
                        selection: snapshot.selection,
                        readiness: readiness
                    )
                ) { current, _ in current }
                EventReporter.shared.capture(
                    level: .warning,
                    engine: "parakeet",
                    event: "audio_format_unavailable",
                    message: "Audio hardware format not ready while starting dictation",
                    context: context
                )
                guard await resetAudioGraphAfterStartFailure(
                    reason: readiness == .routeNotSettled ? "audio_route_not_settled" : "invalid_audio_format",
                    rebuildEngine: startFailureAction.rebuildAudioEngine
                ) != nil else { return await failAudioStart() }
                if startFailureAction.markFormatUnready {
                    markFormatUnreadyAndPublish()
                }
                if startFailureAction.schedulePrewarmRetry {
                    schedulePrewarmRetry()
                }
                return await failAudioStart()
            }

            updateNativeSampleRate(snapshot.outputFormat.sampleRate)
            recordingStartedOnLikelyBluetoothHandsFreeRoute = ParakeetRouteDiagnosticsPolicy.isLikelyBluetoothHandsFreeProfile(
                inputClass: selectedInputClass(for: snapshot.selection),
                outputDeviceClass: defaultOutputClass(for: snapshot.selection),
                inputRate: snapshot.hwFormat.sampleRate,
                outputRate: snapshot.outputFormat.sampleRate
            )
            if let generation = zombieRecoveryStartGeneration {
                guard zombieRecoveryState.canContinue(generation: generation) else {
                    return await failAudioStart()
                }
            }

            do {
                let startOutcome = try await installTapAndStartEngine(
                    startLeaseOwner: attemptOwner,
                    attemptEngine: attemptEngine,
                    attemptQueue: attemptQueue,
                    selection: snapshot.selection
                )
                let startSnapshot: ParakeetAudioStartSnapshot
                switch startOutcome {
                case .started(let started):
                    startSnapshot = started
                case .graphChanged:
                    EventReporter.shared.capture(
                        level: .warning,
                        engine: "parakeet",
                        event: "audio_start_aborted",
                        message: "Audio start aborted because the audio graph changed while starting",
                        context: ["audio_graph_generation": "\(audioGraphGeneration)"]
                    )
                    return await failAudioStart()
                case .cancelled:
                    return await failAudioStart()
                }
                inputTapInstalled = true
                isEnginePrewarmed = true

                var timingContext = dictationRouteAnalyticsContext(
                    outputFormat: snapshot.outputFormat,
                    hwFormat: snapshot.hwFormat,
                    selection: snapshot.selection,
                    extra: [
                        "engine_running_before_start": "\(startSnapshot.engineWasRunning)",
                        "start_mode": isRecoveryAttempt ? "recovery" : "normal",
                    ]
                )
                timingContext.merge(Self.timingContext(snapshot.stageTimings)) { current, _ in current }
                timingContext.merge(Self.timingContext(startSnapshot.stageTimings)) { current, _ in current }
                EventReporter.shared.capture(
                    level: .info,
                    engine: "parakeet",
                    event: "dictation_audio_start_timing",
                    message: "Dictation audio start stage timing",
                    context: timingContext
                )

                if !startSnapshot.engineWasRunning && isEnginePrewarmed {
                    EventReporter.shared.capture(level: .info, engine: "parakeet",
                        event: "audio_engine_started",
                        message: "Audio engine started on worker queue",
                        context: [
                            "start_mode": isRecoveryAttempt ? "recovery" : "normal",
                            "output_rate_hz": String(format: "%.0f", snapshot.outputFormat.sampleRate),
                            "input_rate_hz": String(format: "%.0f", snapshot.hwFormat.sampleRate)
                        ])
                }
            } catch {
                guard ownsAudioEngineQueue(attemptOwner) else { return await failAudioStart() }
                let audioEngineWorkError = error as? ParakeetAudioEngineWorkError
                let operationTimedOut = audioEngineWorkError?.isTimedOut == true
                let workCircuitOpen = audioEngineWorkError?.isCircuitOpen == true
                let operationBlocked = operationTimedOut || workCircuitOpen
                var context = audioStartContext(
                    attempt: attempt,
                    isRecoveryAttempt: isRecoveryAttempt,
                    engineWasRunning: snapshot.engineWasRunning,
                    outputFormat: snapshot.outputFormat,
                    hwFormat: snapshot.hwFormat,
                    error: error
                )
                let failureReason = operationTimedOut
                    ? ParakeetStartRecordingFailureReason.audioEngineStartTimedOut
                    : ParakeetAudioFormatReadinessPolicy.startFailureReason(for: error as NSError)
                lastRecordingStartFailureReason = failureReason
                let startFailureAction = ParakeetStartRecordingFailurePolicy.action(
                    for: failureReason,
                    isRecoveryAttempt: isRecoveryAttempt
                )
                context["failure_kind"] = audioEngineWorkError?.isCircuitOpen == true
                    ? "audio_engine_work_circuit_open"
                    : operationTimedOut ? "audio_engine_start_timeout" : "audio_engine_start_failed"
                context["sample_flow_started"] = "\(didReceiveAudioSamples)"
                context["sample_signal_started"] = "\(didReceiveNonZeroAudioSamples)"
                let shouldRetry = !operationBlocked
                    && failureReason == .audioEngineStartFailed
                    && ParakeetAudioStartRecoveryPolicy.shouldRetryStartFailure(
                    isRecoveryAttempt: isRecoveryAttempt,
                    failedAttempts: attempt
                )
                if let audioEngineWorkError {
                    if audioEngineWorkError.requiresGraphAbandonment {
                        guard abandonBlockedAudioEngine(
                            reason: "audio_engine_start_timeout",
                            expectedOwner: attemptOwner
                        ) else { return await failAudioStart() }
                    }
                } else {
                    guard await resetAudioGraphAfterStartFailure(
                        reason: failureReason == .audioRouteNotSettled ? "audio_route_not_settled" : "audio_engine_start_failed",
                        rebuildEngine: startFailureAction.rebuildAudioEngine
                    ) != nil else { return await failAudioStart() }
                }

                if shouldRetry {
                    let retryOwner = currentAudioEngineQueueOwnerToken()
                    guard audioStartAdmission.transfer(from: startOwner, to: retryOwner) else {
                        return await failAudioStart()
                    }
                    startOwner = retryOwner
                    startEngine = audioEngine
                    startQueue = audioEngineQueue
                    AppLogger.transcription.warning("PARAKEET | audio engine start failed, resetting graph and retrying once: \(error.localizedDescription)")
                    EventReporter.shared.capture(
                        level: .warning,
                        engine: "parakeet",
                        event: "audio_engine_start_retrying",
                        message: "Audio engine failed to start; resetting graph and retrying",
                        context: context
                    )
                    continue
                }

                if failureReason == .audioRouteNotSettled {
                    AppLogger.transcription.warning("PARAKEET | audio route format unsupported while starting; waiting for CoreAudio to settle")
                    EventReporter.shared.capture(
                        level: .warning,
                        engine: "parakeet",
                        event: "audio_route_not_settled",
                        message: "Audio route format was not ready while starting dictation",
                        context: context
                    )
                    if startFailureAction.markFormatUnready {
                        markStartFailedAndPublish()
                    }
                    if startFailureAction.schedulePrewarmRetry {
                        schedulePrewarmRetry()
                    }
                    return await failAudioStart()
                }

                if workCircuitOpen {
                    AppLogger.transcription.error("PARAKEET | audio engine start blocked by an open work circuit after \(attempt) attempt(s): \(error.localizedDescription)")
                    EventReporter.shared.capture(
                        level: .error,
                        engine: "parakeet",
                        event: "audio_engine_work_circuit_open",
                        message: "Audio engine start was blocked by a prior timed operation",
                        context: context
                    )
                    if startFailureAction.markFormatUnready {
                        markStartFailedAndPublish()
                    }
                    if startFailureAction.schedulePrewarmRetry {
                        schedulePrewarmRetry()
                    }
                    return await failAudioStart()
                }

                if operationTimedOut {
                    AppLogger.transcription.error("PARAKEET | audio engine start timed out after \(attempt) attempt(s): \(error.localizedDescription)")
                    EventReporter.shared.capture(
                        level: .error,
                        engine: "parakeet",
                        event: "audio_engine_start_timeout",
                        message: "Audio engine start timed out; abandoned blocked microphone graph",
                        context: context
                    )
                    if startFailureAction.markFormatUnready {
                        markStartFailedAndPublish()
                    }
                    if startFailureAction.schedulePrewarmRetry {
                        schedulePrewarmRetry()
                    }
                    return await failAudioStart()
                }

                AppLogger.transcription.error("PARAKEET | audio engine failed after \(attempt) attempt(s): \(error.localizedDescription)")
                reportAudioStartFailureIfNeeded(message: error.localizedDescription, context: context)
                if startFailureAction.markFormatUnready {
                    markStartFailedAndPublish()
                }
                if startFailureAction.schedulePrewarmRetry {
                    schedulePrewarmRetry()
                }
                return await failAudioStart()
            }

            if attempt > 1 {
                EventReporter.shared.capture(
                    level: .info,
                    engine: "parakeet",
                    event: "audio_engine_start_recovered",
                    message: "Audio engine started after a graph reset",
                    context: [
                        "attempts": "\(attempt)",
                        "start_mode": isRecoveryAttempt ? "recovery" : "normal",
                        "output_rate_hz": String(format: "%.0f", snapshot.outputFormat.sampleRate),
                        "output_channels": "\(snapshot.outputFormat.channelCount)",
                        "input_rate_hz": String(format: "%.0f", snapshot.hwFormat.sampleRate),
                        "hw_channels": "\(snapshot.hwFormat.channelCount)",
                    ]
                )
            }
            lastAudioStartFailureReportAt = nil
            break
        }

        // The committed start already queued its call-app recheck; it runs
        // after this MainActor turn, once isRecording is set below.
        isRecording = true
        markFormatReadyAndPublish()
        AppLogger.transcription.info("PARAKEET | recording started (\(inputDeviceName), \(safeNativeSampleRate())Hz)")

        // Watchdog: detect zombie audio engine (running but no usable signal after sleep/wake).
        // Only on first attempt — recovery attempt doesn't re-watchdog to prevent infinite loops.
        if !isRecoveryAttempt {
            startAudioWatchdog()
        }

        return true
    }

    private func cancelAudioWatchdogForRecordingStart() {
        audioWatchdogTask?.cancel()
        audioWatchdogTask = nil
        guard ParakeetZombieEngineRecoverySequence.recordingStartKeepsRecovery(
            startGeneration: zombieRecoveryStartGeneration,
            state: zombieRecoveryState
        ) else {
            cancelZombieEngineRecovery()
            return
        }
    }

    @discardableResult
    private func cancelZombieEngineRecovery() -> Bool {
        zombieRecoveryTask?.cancel()
        audioStartCancellationState?.cancel()
        audioStartCancellationState = nil
        // Cancellation may advance logical ownership before this method runs.
        // If reset or start work still owns these exact resources, replace
        // both before successor cleanup can enqueue.
        let didReplaceBlockedGraph = audioGraph.replaceGraphHoldingPendingWork()
        zombieRecoveryTask = nil
        zombieRecoveryStartGeneration = nil
        if let terminal = zombieRecoveryState.cancelActiveAttempt() {
            reportZombieEngineRecoveryTerminal(terminal)
        }
        return didReplaceBlockedGraph
    }

    @discardableResult
    func cancelAudioWatchdog() -> Bool {
        audioWatchdogTask?.cancel()
        audioWatchdogTask = nil
        return cancelZombieEngineRecovery()
    }
}
