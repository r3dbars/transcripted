// ParakeetDeviceRecovery.swift
// Device-change detection and recovery execution for ParakeetEngine, split
// out of ParakeetEngine.swift (codebase audit 2026-07-08 wave 2, spec W2-C).
//
// The pure decision tables this executor consults already live as testable,
// side-effect-free types in ParakeetStartRecordingFailurePolicy.swift:
// `ParakeetDeviceRecoveryReadinessPolicy`, `ParakeetDeviceRecoveryFailurePolicy`,
// and `ParakeetDeviceRecoveryTimeoutPolicy`. This file is the side-effecting
// executor that talks to CoreAudio / AVAudioEngine and drives ParakeetEngine's
// recovery state machine (`ParakeetRecoveryState`) off those decisions.
//
// These are internal collaborator methods on ParakeetEngine — ParakeetEngine
// remains the public-API owner and MainActor home for this state; this file
// just groups the device-recovery slice of its implementation.

@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import TranscriptedCore

extension ParakeetEngine {
    // MARK: - Device-change detection

    func installAudioEngineConfigObserverIfNeeded() {
        guard configChangeObserver == nil else { return }
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.handleAudioConfigChange()
            }
        }
    }

    func removeAudioEngineConfigObserver() {
        guard let observer = configChangeObserver else { return }
        NotificationCenter.default.removeObserver(observer)
        configChangeObserver = nil
    }

    func installInputDeviceChangeListenerIfNeeded() {
        guard inputDeviceChangeListener == nil else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task.detached(priority: .utility) { [weak self] in
                let selection = Self.loadDictationInputDeviceSelection() ?? Self.unknownInputDeviceSelection
                await self?.handleDefaultInputDeviceChange(selection: selection)
            }
        }

        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            .main,
            listener
        )

        guard status == noErr else {
            EventReporter.shared.capture(
                level: .warning,
                engine: "parakeet",
                event: "default_input_listener_failed",
                message: "Failed to register default input device listener",
                context: ["status": "\(status)"]
            )
            return
        }

        inputDeviceChangeListener = listener
    }

    func removeInputDeviceChangeListener() {
        unregisterDefaultInputDeviceListener(inputDeviceChangeListener)
        inputDeviceChangeListener = nil
    }

    private func handleDefaultInputDeviceChange(selection: DictationInputDeviceSelection) {
        cachedInputDeviceName = selection.selectedInput.name
        cachedInputDeviceSelection = selection
        AppLogger.transcription.info("PARAKEET | default input changed → \(selection.defaultInput.name); dictation input → \(selection.selectedInput.name)")
        EventReporter.shared.capture(
            level: .info,
            engine: "parakeet",
            event: "default_input_device_changed",
            message: "Default input device changed",
            context: inputSelectionContext(selection)
        )
        Task { @MainActor [weak self] in
            await self?.handleAudioConfigChange()
        }
    }

    private func handleAudioConfigChange() async {
        // Meeting capture owns the live audio graph while dictation borrows
        // its PCM. A system route change belongs to the meeting recovery path;
        // do not wake or rebuild the dormant dictation AVAudioEngine.
        if sharedMeetingMicRecording {
            scheduleInputDeviceNameRefresh()
            return
        }
        // Recording startup owns route selection and format validation. Letting
        // the config-change recovery path run at the same time makes it fight
        // the intentional Bluetooth -> built-in override and can create a
        // restore/override loop between consecutive dictations.
        if audioStartInProgress {
            return
        }
        if CFAbsoluteTimeGetCurrent() < ignoreInputSelectionConfigChangesUntil {
            return
        }
        audioGraphGeneration += 1

        // Track whether any config change in the current burst interrupted a
        // recording. Once set, subsequent changes in the same burst inherit it.
        if isRecording {
            configChangeWasRecording = true
        }

        // Bump the generation counter and signal UI that engine is recovering.
        // DictationSessionController waits on these flags instead of racing.
        cancelConfigRecoveryTimeout()
        let recoveryGeneration = recoveryState.beginConfigChange()
        publishRecoveryState()
        // Load the new route off the main actor — the enumeration is blocking
        // coreaudiod IPC — then refresh the analytics cache and report.
        let wasRecordingForAnalytics = configChangeWasRecording
        Task.detached(priority: .utility) { [weak self] in
            let selection = Self.loadDictationInputDeviceSelection()
            await self?.recordRouteChangeAnalytics(
                selection: selection,
                wasRecording: wasRecordingForAnalytics
            )
        }
        scheduleConfigRecoveryTimeout(
            generation: recoveryGeneration,
            wasRecording: configChangeWasRecording
        )
        // Fresh device state warrants a fresh retry budget for prewarm.
        prewarmRetryCount = 0

        // Immediately tear down anything that's running — the system has
        // already stopped the engine internally before posting this notification,
        // so the tap and prewarm state are stale.
        cancelAudioWatchdog()
        prewarmRetryTask?.cancel()
        prewarmRetryTask = nil

        if isRecording {
            preserveCurrentRecordingBuffersForRecovery()
            streamingSamplesLock.withLock { streamingSampleBuffer.removeAll(keepingCapacity: true) }
            Task { await eouManager?.reset() }
            await removeRecordingTap()
            isRecording = false
            audioLevel = 0
        }

        await stopAudioEngine()
        isEnginePrewarmed = false
        await rebuildAudioEngine(reason: "configuration_change")

        // Cancel any in-flight recovery — the latest device change wins.
        // Bluetooth disconnect/reconnect fires multiple notifications over
        // 500-1500ms; each cancels the previous recovery so only the final
        // stable device state gets a recovery attempt.
        configChangeDebounceTask?.cancel()
        configRecoveryTask?.cancel()

        configChangeDebounceTask = Task { @MainActor [weak self] in
            // 250ms debounce — long enough to coalesce rapid BT notifications,
            // short enough that dictation recovery feels responsive.
            try? await Task.sleep(nanoseconds: TranscriptedConstants.audioConfigChangeDebounceDelay)
            guard !Task.isCancelled, let self = self else { return }
            self.attemptDeviceRecovery()
        }
    }

    private func recordRouteChangeAnalytics(
        selection: DictationInputDeviceSelection?,
        wasRecording: Bool
    ) {
        if let selection {
            updateCachedInputDeviceSelection(selection)
        }
        AnalyticsReporter.track(
            "dictation_audio_route_changed",
            properties: dictationRouteAnalyticsContext(
                selection: selection,
                extra: [
                    "was_recording": "\(wasRecording)"
                ]
            )
        )
    }

    // MARK: - Recovery execution
    //
    // The two pure decision points below — "is this format snapshot ready or
    // do we keep waiting" and "how do we recover from a failed rewarm" — are
    // `ParakeetDeviceRecoveryReadinessPolicy.action(for:)` and
    // `ParakeetDeviceRecoveryFailurePolicy.action(wasRecording:)` /
    // `.rebuildStrategy(audioEngineQueueBlocked:)` in
    // ParakeetStartRecordingFailurePolicy.swift. This method is the executor
    // that drives CoreAudio/AVAudioEngine off those decisions.

    private func attemptDeviceRecovery() {
        let shouldRestartRecording = configChangeWasRecording
        configChangeWasRecording = false
        let myGeneration = recoveryState.generation
        let recoveryStartedAt = CFAbsoluteTimeGetCurrent()

        configRecoveryTask = Task { @MainActor [weak self] in
            // Wait for CoreAudio to finish settling the new device graph.
            try? await Task.sleep(nanoseconds: TranscriptedConstants.audioRecoveryDelay)
            guard !Task.isCancelled, let self = self else { return }
            guard !self.recoveryState.isStale(generation: myGeneration) else { return }
            var workflowRecoveryFinished = false
            func finishWorkflowRecovery(result: String, artifactRetained: Bool) {
                guard !workflowRecoveryFinished else { return }
                workflowRecoveryFinished = true
                WorkflowRecoveryTelemetry.finished(
                    workflowKind: "dictation",
                    failureKind: "route_changed",
                    retrySource: "audio_route_recovery",
                    result: result,
                    elapsedSeconds: CFAbsoluteTimeGetCurrent() - recoveryStartedAt,
                    surface: "runtime",
                    artifactRetained: artifactRetained
                )
            }
            defer {
                finishWorkflowRecovery(
                    result: Task.isCancelled ? "cancelled" : "superseded",
                    artifactRetained: shouldRestartRecording
                )
            }
            WorkflowRecoveryTelemetry.attempted(
                workflowKind: "dictation",
                failureKind: "route_changed",
                retrySource: "audio_route_recovery",
                surface: "runtime",
                artifactRetained: shouldRestartRecording
            )

            let recoverySelection = await Task.detached(priority: .utility) {
                Self.loadDictationInputDeviceSelection()
            }.value
            guard !Task.isCancelled else { return }
            guard !self.recoveryState.isStale(generation: myGeneration) else { return }
            if ParakeetPrewarmPolicy.shouldDeferHardwareRecovery(
                for: recoverySelection,
                wasRecording: shouldRestartRecording
            ) {
                if let recoverySelection {
                    self.updateCachedInputDeviceSelection(recoverySelection)
                }
                self.prewarmRetryCount = 0
                guard self.recoveryState.finishRecovery(success: true, generation: myGeneration) else { return }
                self.cancelConfigRecoveryTimeout()
                self.publishRecoveryState()
                EventReporter.shared.capture(
                    level: .info,
                    engine: "parakeet",
                    event: "prewarm_deferred_for_bluetooth_fallback",
                    message: "Deferred idle microphone graph changes until dictation starts",
                    context: self.dictationRouteDiagnosticsContext(selection: recoverySelection)
                )
                finishWorkflowRecovery(result: "success", artifactRetained: false)
                return
            }

            do {
                var recoveryAttempt = 0
                var readySnapshot: ParakeetAudioInputSnapshot?
                while readySnapshot == nil {
                    recoveryAttempt += 1
                    let snapshot = try await self.audioInputSnapshot(
                        operation: recoveryAttempt == 1 ? "device_recovery" : "device_recovery_retry",
                        recoveryGeneration: myGeneration
                    )
                    let readiness = self.audioFormatReadiness(
                        outputFormat: snapshot.outputFormat,
                        hwFormat: snapshot.hwFormat,
                        selection: snapshot.selection
                    )
                    switch ParakeetDeviceRecoveryReadinessPolicy.action(for: readiness) {
                    case .finishRecovery:
                        readySnapshot = snapshot
                    case .keepWaiting:
                        var context = self.audioFormatContext(
                            outputFormat: snapshot.outputFormat,
                            hwFormat: snapshot.hwFormat,
                            selection: snapshot.selection,
                            readiness: readiness
                        )
                        context["recovery_attempt"] = "\(recoveryAttempt)"
                        EventReporter.shared.capture(
                            level: .warning,
                            engine: "parakeet",
                            event: "device_change_rewarm_deferred",
                            message: "Audio route still settling after device change",
                            context: context
                        )
                        try? await Task.sleep(nanoseconds: TranscriptedConstants.audioRecoveryDelay)
                        guard !Task.isCancelled else { return }
                        guard !self.recoveryState.isStale(generation: myGeneration) else { return }
                        continue
                    }
                }
                guard let snapshot = readySnapshot else { return }
                self.updateNativeSampleRate(snapshot.outputFormat.sampleRate)
                self.prewarmRetryCount = 0
                AppLogger.transcription.info("PARAKEET | audio device changed → \(self.inputDeviceName) (\(self.safeNativeSampleRate())Hz), input ready")

                guard !Task.isCancelled else { return }
                guard self.recoveryState.finishRecovery(success: true, generation: myGeneration) else { return }
                self.cancelConfigRecoveryTimeout()
                self.publishRecoveryState()
                AnalyticsReporter.track(
                    "dictation_audio_route_recovery_finished",
                    properties: self.dictationRouteAnalyticsContext(
                        outputFormat: snapshot.outputFormat,
                        hwFormat: snapshot.hwFormat,
                        selection: snapshot.selection,
                        extra: [
                            "outcome": "success",
                            "recovery_latency_bucket": AnalyticsReporter.durationBucket(seconds: CFAbsoluteTimeGetCurrent() - recoveryStartedAt),
                            "was_recording": "\(shouldRestartRecording)"
                        ]
                    )
                )

                // If we were recording, try to restart on the new device.
                // The watchdog (via isRecoveryAttempt=false) catches silent
                // failures where the device looks functional but produces no
                // samples. The watchdog gets one retry before giving up.
                if shouldRestartRecording {
                    var restarted = false
                    for attempt in 1...TranscriptedConstants.recordingRestartAttempts {
                        guard !Task.isCancelled else { return }
                        guard !self.recoveryState.isStale(generation: myGeneration) else { return }
                        if await self.startRecording() {
                            restarted = true
                            AppLogger.transcription.info("PARAKEET | recording recovered on new device (\(self.inputDeviceName)) after \(attempt) attempt(s)")
                            EventReporter.shared.capture(level: .info, engine: "parakeet",
                                event: "recording_recovered_device_change",
                                message: "Recording recovered after device change",
                                context: [
                                    "audio_device": self.inputDeviceName,
                                    "sample_rate": "\(self.safeNativeSampleRate())",
                                    "attempts": "\(attempt)"
                                ])
                            finishWorkflowRecovery(result: "success", artifactRetained: true)
                            break
                        }
                        // BT format negotiation can take ~1-2s; wait between attempts.
                        try? await Task.sleep(nanoseconds: TranscriptedConstants.recordingRestartRetryDelay)
                    }
                    if !restarted {
                        self.interruptRecordingAndClearRecoveredTimeline()
                        EventReporter.shared.capture(level: .error, engine: "parakeet",
                            event: "recording_interrupted",
                            message: "Recording could not restart after device change within retry budget",
                            context: self.dictationRouteDiagnosticsContext(
                                outputFormat: snapshot.outputFormat,
                                hwFormat: snapshot.hwFormat,
                                selection: snapshot.selection,
                                extra: [
                                    "audio_device": self.inputDeviceName,
                                    "reason": "recording_restart_budget_exhausted"
                                ]
                            ))
                        finishWorkflowRecovery(result: "failed", artifactRetained: false)
                    }
                } else {
                    finishWorkflowRecovery(result: "success", artifactRetained: false)
                }
            } catch {
                guard !self.recoveryState.isStale(generation: myGeneration) else { return }
                // A timed-out audio-engine operation means the serial engine queue
                // is wedged behind a CoreAudio call that never returned (the AirPods
                // / Bluetooth route-switch hang). Rebuilding on that same queue would
                // never run, so fail safe by abandoning the blocked graph instead.
                let audioEngineQueueBlocked = error is ParakeetAudioEngineWorkError
                let failureAction = ParakeetDeviceRecoveryFailurePolicy.action(wasRecording: shouldRestartRecording)
                if self.recoveryState.finishRecovery(success: false, generation: myGeneration) {
                    self.cancelConfigRecoveryTimeout()
                    self.publishRecoveryState()
                }
                AnalyticsReporter.track(
                    "dictation_audio_route_recovery_finished",
                    properties: self.dictationRouteAnalyticsContext(
                        selection: self.cachedInputDeviceSelection,
                        extra: [
                            "outcome": "failed",
                            "recovery_latency_bucket": AnalyticsReporter.durationBucket(seconds: CFAbsoluteTimeGetCurrent() - recoveryStartedAt),
                            "was_recording": "\(shouldRestartRecording)"
                        ]
                    )
                )
                finishWorkflowRecovery(result: "failed", artifactRetained: shouldRestartRecording)
                if failureAction.markRecordingInterrupted {
                    self.interruptRecordingAndClearRecoveredTimeline()
                    EventReporter.shared.capture(level: .error, engine: "parakeet",
                        event: "recording_interrupted",
                        message: "Recording interrupted — engine rewarm failed after device change",
                        context: self.dictationRouteDiagnosticsContext(
                            selection: self.cachedInputDeviceSelection,
                            extra: [
                                "audio_device": self.inputDeviceName,
                                "error": error.localizedDescription
                            ]
                        ))
                }
                if failureAction.reportSentryFailure {
                    EventReporter.shared.capture(level: .error, engine: "parakeet",
                        event: "device_change_rewarm_failed",
                        message: error.localizedDescription,
                        context: self.dictationRouteDiagnosticsContext(
                            selection: self.cachedInputDeviceSelection,
                            extra: [
                                "audio_device": self.inputDeviceName,
                                "was_recording": "\(shouldRestartRecording)",
                                "recovery_generation": "\(myGeneration)"
                            ]
                        ))
                } else {
                    EventReporter.shared.capture(level: .warning, engine: "parakeet",
                        event: "device_change_rewarm_deferred",
                        message: "Idle audio route still settling after device change",
                        context: self.dictationRouteDiagnosticsContext(
                            selection: self.cachedInputDeviceSelection,
                            extra: [
                                "was_recording": "false",
                                "error": error.localizedDescription,
                                "recovery_generation": "\(myGeneration)"
                            ]
                        ))
                }
                switch ParakeetDeviceRecoveryFailurePolicy.rebuildStrategy(
                    audioEngineQueueBlocked: audioEngineQueueBlocked
                ) {
                case .queuedOnAudioEngineQueue:
                    await self.rebuildAudioEngine(reason: "device_change_rewarm_failed")
                case .abandonBlockedAudioGraph:
                    self.abandonBlockedAudioEngine(reason: "device_change_rewarm_failed")
                }
                if failureAction.schedulePrewarmRetry {
                    self.prewarmRetryCount = 0
                    self.schedulePrewarmRetry()
                }
            }
        }
    }

    private func scheduleConfigRecoveryTimeout(generation: UInt64, wasRecording: Bool) {
        configRecoveryTimeoutTask?.cancel()
        configRecoveryTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: TranscriptedConstants.audioDeviceRecoveryTimeout)
            guard !Task.isCancelled, let self, !self.isShuttingDown else { return }
            guard self.recoveryState.timeoutRecovery(generation: generation) else { return }

            self.configRecoveryTimeoutTask = nil
            self.publishRecoveryState()
            let timeoutAction = ParakeetDeviceRecoveryTimeoutPolicy.action(wasRecording: wasRecording)
            let failureAction = timeoutAction.failureAction
            AnalyticsReporter.track(
                "dictation_audio_route_recovery_timeout",
                properties: self.dictationRouteAnalyticsContext(
                    selection: self.cachedInputDeviceSelection,
                    extra: [
                        "recovery_latency_bucket": AnalyticsReporter.durationBucket(
                            seconds: Double(TranscriptedConstants.audioDeviceRecoveryTimeout) / 1_000_000_000
                        ),
                        "was_recording": "\(wasRecording)"
                    ]
                )
            )
            WorkflowRecoveryTelemetry.finished(
                workflowKind: "dictation",
                failureKind: "route_changed",
                retrySource: "audio_route_recovery",
                result: "failed",
                elapsedSeconds: Double(TranscriptedConstants.audioDeviceRecoveryTimeout) / 1_000_000_000,
                surface: "runtime",
                artifactRetained: wasRecording
            )
            let diagnosticsEvent = failureAction.reportSentryFailure
                ? "device_change_recovery_timeout"
                : "device_change_recovery_deferred"
            let diagnosticsLevel: EventLevel = failureAction.reportSentryFailure ? .error : .warning
            let diagnosticsMessage = failureAction.reportSentryFailure
                ? "Audio device recovery timed out"
                : "Idle audio route still settling after device change"
            EventReporter.shared.capture(
                level: diagnosticsLevel,
                engine: "parakeet",
                event: diagnosticsEvent,
                message: diagnosticsMessage,
                context: self.dictationRouteDiagnosticsContext(
                    selection: self.cachedInputDeviceSelection,
                    extra: [
                        "recovery_generation": "\(generation)",
                        "timeout_ms": "\(TranscriptedConstants.audioDeviceRecoveryTimeout / 1_000_000)",
                        "was_recording": "\(wasRecording)",
                        "audio_device": self.inputDeviceName
                    ]
                )
            )
            if failureAction.markRecordingInterrupted {
                self.interruptRecordingAndClearRecoveredTimeline()
                EventReporter.shared.capture(
                    level: .error,
                    engine: "parakeet",
                    event: "recording_interrupted",
                    message: "Recording interrupted because audio device recovery timed out",
                    context: self.dictationRouteDiagnosticsContext(
                        selection: self.cachedInputDeviceSelection,
                        extra: [
                            "audio_device": self.inputDeviceName,
                            "reason": "device_change_recovery_timeout"
                        ]
                    )
                )
            }
            switch timeoutAction.rebuildStrategy {
            case .queuedOnAudioEngineQueue:
                await self.rebuildAudioEngine(reason: "device_change_recovery_timeout")
            case .abandonBlockedAudioGraph:
                self.abandonBlockedAudioEngine(reason: "device_change_recovery_timeout")
            }
            if failureAction.schedulePrewarmRetry {
                self.prewarmRetryCount = 0
                self.schedulePrewarmRetry()
            }
        }
    }

    func cancelConfigRecoveryTimeout() {
        configRecoveryTimeoutTask?.cancel()
        configRecoveryTimeoutTask = nil
    }
}
