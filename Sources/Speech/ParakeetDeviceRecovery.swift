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
        let observedEngine = audioEngine
        let observedEngineID = ObjectIdentifier(observedEngine)
        let bindingIntent = auhalBindingIntent
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: observedEngine,
            // Capture the post on its originating thread; dispatching this
            // observer to MainActor first could itself age out the 2.5s echo
            // window before the timestamp is taken.
            queue: nil
        ) { [weak self] _ in
            let arrival = ParakeetConfigChangeArrival.stamp(
                engineID: observedEngineID,
                bindingIntent: bindingIntent,
                window: TranscriptedConstants.selfInducedConfigChangeIgnoreWindow
            )
            self?.scheduleInputDeviceNameRefresh(
                configChangeSource: .audioEngine,
                observedAt: arrival.observedAt,
                bindingToken: arrival.bindingToken
            )
        }
    }

    func removeAudioEngineConfigObserver() {
        guard let observer = configChangeObserver else { return }
        NotificationCenter.default.removeObserver(observer)
        configChangeObserver = nil
    }

    // Migrated to the shared `DefaultInputDeviceMonitor` (codebase audit
    // 2026-08 — see that file's header for why three independent
    // kAudioHardwarePropertyDefaultInputDevice listeners were collapsed into
    // one). The CoreAudio-selection read runs off the main thread through the
    // one-worker latest-wins mailbox below. The worker's HAL read has a
    // bounded wait and at most two timed-out replacement workers; a wedged
    // lookup must not hold later notifications or defer recovery forever.
    //
    // isSelfWrite policy: ignore. ParakeetEngine never writes
    // kAudioHardwarePropertyDefaultInputDevice through
    // `DefaultInputDeviceMonitor.setDefaultInputDevice` — only
    // `PersistentDictationInputController`'s writes are classified
    // `isSelfWrite == true` here, and this engine has no reason to run its
    // device-recovery machinery in reaction to that controller reasserting
    // its own preference. Dropping those notifications reproduces this
    // consumer's pre-migration behavior (it never saw its own writes trigger
    // recovery, since it doesn't make any). ParakeetEngine's *own*
    // default-input overrides during recording start are a separate concern
    // entirely — they don't go through `setDefaultInputDevice` at all, so
    // they always arrive here with `isSelfWrite == false` and are guarded
    // instead by this method's own `ignoreInputSelectionConfigChangesUntil`
    // (checked in `handleAudioConfigChange` below), unchanged — that window
    // spans the whole recording-start sequencing around the override, not
    // just the CoreAudio round trip, so it was intentionally kept
    // per-consumer instead of centralized.
    func installInputDeviceChangeListenerIfNeeded() {
        guard inputDeviceChangeObserverToken == nil else { return }
        DefaultInputDeviceMonitor.shared.start()
        inputDeviceChangeObserverToken = DefaultInputDeviceMonitor.shared.addObserver { [weak self] isSelfWrite in
            guard !isSelfWrite else { return }
            self?.scheduleInputDeviceNameRefresh(
                configChangeSource: .defaultInputDevice,
                observedAt: CFAbsoluteTimeGetCurrent()
            )
        }
    }

    func removeInputDeviceChangeListener() {
        guard let inputDeviceChangeObserverToken else { return }
        DefaultInputDeviceMonitor.shared.removeObserver(inputDeviceChangeObserverToken)
        self.inputDeviceChangeObserverToken = nil
    }

    nonisolated func scheduleInputDeviceNameRefresh(
        configChangeSource: ParakeetConfigChangeSource? = nil,
        observedAt: CFAbsoluteTime? = nil,
        bindingToken: ParakeetAUHALBindingToken? = nil
    ) {
        guard inputDeviceRefreshMailbox.submit(
            configChangeSource: configChangeSource,
            observedAt: observedAt ?? (configChangeSource == nil ? nil : CFAbsoluteTimeGetCurrent()),
            bindingToken: bindingToken
        ) else { return }
        Task { @MainActor [weak self] in
            await self?.drainInputDeviceRefreshMailbox()
        }
    }

    private func drainInputDeviceRefreshMailbox() async {
        while !Task.isCancelled,
              !isShuttingDown,
              let request = inputDeviceRefreshMailbox.takeNext() {
            let loadedSelection = await boundedRouteNotificationSelection()
            guard !Task.isCancelled, !isShuttingDown else { return }

            if let loadedSelection {
                updateCachedInputDeviceSelection(loadedSelection)
            } else {
                updateCachedInputDeviceName("Unknown")
            }

            guard let source = request.configChangeSource else { continue }
            let observedSelection = loadedSelection ?? Self.unknownInputDeviceSelection
            if source == .defaultInputDevice {
                let selection = observedSelection
                routeTransitionDebounceState.observe(categoricalAudioRoute(for: selection))
            }
            await handleAudioConfigChange(
                source: source,
                observedSelection: observedSelection,
                observedAt: request.observedAt,
                bindingToken: request.bindingToken
            )
        }
    }

    /// Unknown is returned for a failed, timed-out, or circuit-open HAL read.
    /// The caller still dispatches recovery rather than waiting indefinitely
    /// for a USB driver's synchronous AudioObjectGetPropertyData to return.
    private func boundedRouteNotificationSelection() async -> DictationInputDeviceSelection? {
        try? await Self.inputDeviceRefreshWorkCoordinator.run(
            operation: "route_notification_selection_lookup",
            timeoutNanoseconds: TranscriptedConstants.systemInputOperationTimeout
        ) {
            Self.loadDictationInputDeviceSelection()
        }
    }

    func recoverForMicrophoneSharing() async {
        await handleAudioConfigChange(
            source: .audioEngine,
            observedSelection: cachedInputDeviceSelection,
            forceForMicrophoneSharing: true
        )
    }

    private func handleAudioConfigChange(
        source: ParakeetConfigChangeSource,
        observedSelection: DictationInputDeviceSelection? = nil,
        observedAt: CFAbsoluteTime? = nil,
        bindingToken: ParakeetAUHALBindingToken? = nil,
        forceForMicrophoneSharing: Bool = false
    ) async {
        // Each owner below keeps route recovery out
        // (`ParakeetConfigChangeAdmissionPolicy`):
        // - Meeting capture owns the live audio graph while dictation borrows
        //   its PCM, but only while the meeting session that lent the mic is
        //   still alive. A claim orphaned by a dead session resolves to
        //   `.stale` (released and reported) and stops blocking recovery.
        //   Mirrors the guard in ParakeetEngine.handleSystemWake().
        // - Recording startup owns route selection and format validation;
        //   recovering alongside it fights the start's own binding.
        // - A route notification that arrives while a user stop is suspended
        //   must not inherit the old recording bit and restart the mic.
        // - The pinned recorder follows its own device and never uses this
        //   engine; rebuilding it mid-recording is what binds the macOS
        //   default input (and a Bluetooth headset). Idle changes take the
        //   normal deferred path, which touches no device.
        guard admitsConfigChangeRecovery else { return }
        let generationAtAdmission = audioConfigObservationGeneration
        let configChangeObservedAt = observedAt ?? CFAbsoluteTimeGetCurrent()

        let currentSelection: DictationInputDeviceSelection?
        if let observedSelection {
            currentSelection = observedSelection
        } else {
            currentSelection = await boundedRouteNotificationSelection()
                ?? Self.unknownInputDeviceSelection
        }

        // The route lookup above suspends outside the audio graph. Recheck all
        // lifecycle owners before this handler mutates recovery state.
        guard admitsConfigChangeRecovery,
              generationAtAdmission == audioConfigObservationGeneration else {
            return
        }

        let observedRouteIdentity = currentSelection.map {
            ParakeetAudioRouteIdentity(selection: $0)
        }
        let admission = await ParakeetConfigChangeAdmission.decide(
            ParakeetConfigChangeAdmissionRequest(
                source: source, observedAt: configChangeObservedAt, bindingToken: bindingToken,
                forceForMicrophoneSharing: forceForMicrophoneSharing,
                ignoreWindowUntil: ignoreInputSelectionConfigChangesUntil),
            observedRoute: observedRouteIdentity,
            stableRoute: stableAudioRouteIdentity,
            windowDuration: TranscriptedConstants.selfInducedConfigChangeIgnoreWindow,
            currentEngine: { audioEngine },
            waitForResolution: { token in
                await token.waitForResolution(
                    nativeTimeoutNanoseconds: TranscriptedConstants.audioStartOperationTimeout
                )
            },
            stillAdmitted: {
                !Task.isCancelled && !isShuttingDown
                    && !isSharedMeetingMicClaimCurrent
                    && pinnedDictationRecording == nil
                    && !audioStartInProgress && !audioStopInProgress
                    && generationAtAdmission == audioConfigObservationGeneration
            }
        )
        guard admission == .recover else { return }
        audioConfigObservationGeneration &+= 1
        let observationGeneration = audioConfigObservationGeneration

        // An idle app has nothing to recover in real time. Rebuilding native
        // AVAudioEngine graphs for background route chatter can turn a noisy
        // CoreAudio notification source into unbounded retained engines. Mark
        // readiness stale and validate once, on the next explicit dictation.
        // A recording temporarily stopped by recovery keeps its intent through
        // configChangeWasRecording / the recovery flags and stays on the live
        // recovery path below.
        let hasActiveRecordingIntent = !recordingInterrupted && (
            isRecording || configChangeWasRecording
                || preservingRecordingAcrossRecovery || zombieRecoveryState.isActive
        )
        guard hasActiveRecordingIntent else {
            invalidateAudioGraphForIdleRouteChange()
            prewarmRetryTask?.cancel()
            prewarmRetryTask = nil
            prewarmRetryCount = 0
            configRecoveryTask?.cancel()
            configRecoveryTask = nil
            cancelConfigRecoveryTimeout()
            recoveryState.deferUntilNextUse()
            publishRecoveryState()
            isEnginePrewarmed = false

            configChangeDebounceTask?.cancel()
            configChangeDebounceTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: TranscriptedConstants.audioConfigChangeDebounceDelay)
                guard !Task.isCancelled, let self, !self.isShuttingDown else { return }
                self.recordStableRouteChangeAnalytics(
                    selection: currentSelection,
                    wasRecording: false,
                    recoveryGeneration: nil
                )
                self.configChangeDebounceTask = nil
            }
            AppLogger.transcription.info(
                "PARAKEET | idle configuration change deferred until next dictation"
            )
            return
        }

        let graphEndpointsMatch = stableAudioRouteIdentity.map { stableIdentity in
            observedRouteIdentity.map(stableIdentity.matchesGraphEndpoints) ?? false
        } ?? false

        // Healthy local samples do not prove a call app can still read its mic.
        // A confirmed VPIO downgrade must run even when our stream is healthy.
        if ParakeetConfigChangeContinuityPolicy.shouldProbe(
            wasRecording: isRecording,
            hadSampleFlow: hasReceivedAudioSamples,
            inputWasReady: recoveryState.canStartRecording,
            graphEndpointsMatch: graphEndpointsMatch,
            forceForMicrophoneSharing: forceForMicrophoneSharing
        ) {
            try? await Task.sleep(
                nanoseconds: TranscriptedConstants.audioConfigChangeDebounceDelay
            )
            guard !isSharedMeetingMicClaimCurrent,
                  !audioStartInProgress,
                  !audioStopInProgress,
                  observationGeneration == audioConfigObservationGeneration else {
                return
            }
            if ParakeetConfigChangeContinuityPolicy.shouldIgnoreAfterProbe(
                wasRecording: isRecording,
                inputWasReady: recoveryState.canStartRecording,
                graphEndpointsMatch: graphEndpointsMatch,
                sampleArrivedAfterNotification: receivedAudioSamples(
                    since: configChangeObservedAt
                )
            ) {
                if let currentSelection {
                    routeTransitionDebounceState.observe(
                        categoricalAudioRoute(for: currentSelection)
                    )
                    updateCachedInputDeviceSelection(currentSelection)
                }
                AppLogger.transcription.info(
                    "PARAKEET | configuration change ignored; current audio samples are still flowing"
                )
                return
            }
        }

        let graphStrategy = ParakeetConfigChangeGraphPolicy.strategy(
            source: source,
            wasRecording: isRecording,
            hadSampleFlow: hasReceivedAudioSamples,
            inputWasReady: recoveryState.canStartRecording,
            stableRouteIdentity: stableAudioRouteIdentity,
            observedRouteIdentity: observedRouteIdentity,
            forceForMicrophoneSharing: forceForMicrophoneSharing
        )
        // Retire the graph owner, signal recovery, stop what's running and
        // pick reuse or rebuild (`ParakeetConfigChangeTeardown`). The UI waits
        // on the published recovery flags instead of racing.
        guard let recoveryGeneration = await ParakeetConfigChangeTeardown.run(
            graph: audioGraph,
            host: self,
            strategy: graphStrategy,
            forceForMicrophoneSharing: forceForMicrophoneSharing
        ) else { return }

        // Cancel any in-flight recovery — the latest device change wins.
        // Bluetooth disconnect/reconnect fires multiple notifications over
        // 500-1500ms; each cancels the previous recovery so only the final
        // stable device state gets a recovery attempt.
        configChangeDebounceTask?.cancel()
        configRecoveryTask?.cancel()

        configChangeDebounceTask = Task { @MainActor [weak self] in
            // 250ms debounce — long enough to coalesce rapid BT notifications,
            // short enough that dictation recovery feels responsive.
            // Telemetry coalescing must never suppress the real recovery state
            // transition, including an A -> B -> A notification burst.
            await ParakeetConfigChangeDebounce.settle(
                sleep: {
                    try? await Task.sleep(nanoseconds: TranscriptedConstants.audioConfigChangeDebounceDelay)
                },
                isCancelled: { Task.isCancelled || self == nil },
                scheduleStableRouteReport: {
                    guard let self else { return }
                    let wasRecordingForAnalytics = self.configChangeWasRecording
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        let selection = await self.boundedRouteNotificationSelection()
                        guard !Task.isCancelled, !self.isShuttingDown else { return }
                        self.recordStableRouteChangeAnalytics(
                            selection: selection,
                            wasRecording: wasRecordingForAnalytics,
                            recoveryGeneration: recoveryGeneration
                        )
                    }
                },
                attemptRecovery: { self?.attemptDeviceRecovery() }
            )
        }
    }

    /// Startup, a suspended stop, a borrowed meeting mic, and the pinned
    /// recorder each own the graph; config-change recovery waits its turn.
    var admitsConfigChangeRecovery: Bool {
        ParakeetConfigChangeAdmissionPolicy.admits(
            sharedMeetingMicClaimCurrent: isSharedMeetingMicClaimCurrent,
            audioStartInProgress: audioStartInProgress,
            audioStopInProgress: audioStopInProgress,
            pinnedRecordingActive: pinnedDictationRecording != nil
        )
    }

    private func invalidateAudioGraphForIdleRouteChange() {
        audioGraphGeneration += 1
    }

    private func recordStableRouteChangeAnalytics(
        selection: DictationInputDeviceSelection?,
        wasRecording: Bool,
        recoveryGeneration: UInt64?
    ) {
        if let recoveryGeneration,
           recoveryState.isStale(generation: recoveryGeneration) {
            return
        }
        guard let selection else {
            routeTransitionDebounceState.discardPendingRoute()
            return
        }
        routeTransitionDebounceState.observe(categoricalAudioRoute(for: selection))
        updateCachedInputDeviceSelection(selection)
        stableAudioRouteIdentity = ParakeetAudioRouteIdentity(selection: selection)
        guard let stableRoute = routeTransitionDebounceState.commitPendingRoute() else { return }

        AppLogger.transcription.info("PARAKEET | stable input route changed → \(stableRoute.routeShape)")
        let context = dictationRouteAnalyticsContext(
            selection: selection,
            extra: ["was_recording": "\(wasRecording)"]
        )
        EventReporter.shared.capture(
            level: .info,
            engine: "parakeet",
            event: "default_input_device_changed",
            message: "Stable categorical input route changed",
            context: context
        )
        AnalyticsReporter.track(
            "dictation_audio_route_changed",
            properties: context
        )
    }

    // MARK: - Recovery execution
    //
    // The two pure decision points below — "is this format snapshot ready or
    // do we keep waiting" and "how do we recover from a failed rewarm" — are
    // `ParakeetDeviceRecoveryReadinessPolicy.action(for:)` and
    // `ParakeetDeviceRecoveryFailurePolicy.action(wasRecording:)` /
    // `.rebuildStrategy(audioEngineQueueBlocked:)` in
    // ParakeetStartRecordingFailurePolicy.swift. The ordering that consults
    // them lives in ParakeetDeviceRecoverySequence.swift; the methods below
    // hand it the real CoreAudio/AVAudioEngine steps.

    private func attemptDeviceRecovery() {
        // Keep the intent latched while the graph is temporarily stopped. A
        // second Bluetooth notification must inherit it, even before any PCM
        // was captured; consuming it here strands the superseding recovery.
        let shouldRestartRecording = configChangeWasRecording
        let myGeneration = recoveryState.generation
        let recoveryStartedAt = CFAbsoluteTimeGetCurrent()

        configRecoveryTask = Task { @MainActor [weak self] in
            // Wait for CoreAudio to finish settling the new device graph.
            try? await Task.sleep(nanoseconds: TranscriptedConstants.audioRecoveryDelay)
            guard !Task.isCancelled, let self = self else { return }
            await ParakeetDeviceRecoverySequence.run(
                generation: myGeneration,
                shouldRestartRecording: shouldRestartRecording,
                steps: self.deviceRecoverySteps(
                    generation: myGeneration,
                    shouldRestartRecording: shouldRestartRecording,
                    startedAt: recoveryStartedAt
                )
            )
        }
    }

    private func deviceRecoverySteps(
        generation myGeneration: UInt64,
        shouldRestartRecording: Bool,
        startedAt recoveryStartedAt: CFAbsoluteTime
    ) -> ParakeetDeviceRecoverySteps<ParakeetAudioInputSnapshot> {
        ParakeetDeviceRecoverySteps(
            isStale: { self.recoveryState.isStale(generation: $0) },
            releaseRecordingIntent: { self.configChangeWasRecording = false },
            reportAttempted: { artifactRetained in
                WorkflowRecoveryTelemetry.attempted(
                    workflowKind: "dictation",
                    failureKind: "route_changed",
                    retrySource: "audio_route_recovery",
                    surface: "runtime",
                    artifactRetained: artifactRetained
                )
            },
            reportFinished: { result, artifactRetained in
                WorkflowRecoveryTelemetry.finished(
                    workflowKind: "dictation",
                    failureKind: "route_changed",
                    retrySource: "audio_route_recovery",
                    result: result,
                    elapsedSeconds: CFAbsoluteTimeGetCurrent() - recoveryStartedAt,
                    surface: "runtime",
                    artifactRetained: artifactRetained
                )
            },
            readSnapshot: { snapshotOwner, recoveryAttempt in
                // One exact lease a user stop can claim; a snapshot that
                // returns after the claim is a cancellation.
                try await self.audioEngineWorkOwnership.runLeased(
                    owner: snapshotOwner,
                    phase: .deviceRecoverySnapshot
                ) { isLeaseCurrent in
                    try await self.audioInputSnapshot(
                        operation: recoveryAttempt == 1 ? "device_recovery" : "device_recovery_retry",
                        recoveryGeneration: myGeneration,
                        isEngineWorkCurrent: isLeaseCurrent
                    )
                }
            },
            readiness: { snapshot in
                self.audioFormatReadiness(
                    outputFormat: snapshot.outputFormat,
                    hwFormat: snapshot.hwFormat,
                    selection: snapshot.selection
                )
            },
            reportStillSettling: { snapshot, readiness, recoveryAttempt in
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
            },
            sleep: { nanoseconds in try? await Task.sleep(nanoseconds: nanoseconds) },
            commitSnapshot: { snapshot in
                self.updateNativeSampleRate(snapshot.outputFormat.sampleRate)
                self.prewarmRetryCount = 0
                AppLogger.transcription.info("PARAKEET | audio device changed → \(self.inputDeviceName) (\(self.safeNativeSampleRate())Hz), input ready")
            },
            finishRecovery: { success, generation in
                self.recoveryState.finishRecovery(success: success, generation: generation)
            },
            cancelTimeout: { self.cancelConfigRecoveryTimeout() },
            publishRecoveryState: { self.publishRecoveryState() },
            reportSucceeded: { snapshot in
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
            },
            restartRecording: {
                // The ordinary start path keeps the preserved segments on the
                // same recording. A measured split Bluetooth route needed one
                // more probe after the old two-second window, so failures that
                // can still clear retry inside a budget. The watchdog (via
                // isRecoveryAttempt=false) catches silent failures where the
                // device looks functional but produces no samples.
                await ParakeetRouteRecoveryRestart.run(
                    startedAtUptime: ProcessInfo.processInfo.systemUptime,
                    nowUptime: { ProcessInfo.processInfo.systemUptime },
                    isCurrent: {
                        !Task.isCancelled && !self.recoveryState.isStale(generation: myGeneration)
                    },
                    startRecording: { await self.startRecording() },
                    shouldRetry: {
                        ParakeetDeviceRecoveryStartRetryPolicy.shouldRetry(
                            after: self.lastRecordingStartFailureReason,
                            inputCanStartRecording: self.recoveryState.canStartRecording
                        )
                    },
                    sleep: { delay in try? await Task.sleep(nanoseconds: delay) }
                )
            },
            reportRecordingRecovered: { attempt in
                AppLogger.transcription.info("PARAKEET | recording recovered on new device (\(self.inputDeviceName)) after \(attempt) attempt(s)")
                EventReporter.shared.capture(level: .info, engine: "parakeet",
                    event: "recording_recovered_device_change",
                    message: "Recording recovered after device change",
                    context: [
                        "audio_device": self.inputDeviceName,
                        "sample_rate": "\(self.safeNativeSampleRate())",
                        "attempts": "\(attempt)"
                    ])
            },
            interruptPreservingTimeline: { self.interruptRecordingPreservingRecoveredTimeline() },
            reportRestartExhausted: { snapshot in
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
            },
            hasRecoveredTimeline: { !self.recoveredRecordingTimeline.isEmpty },
            reportFailed: { _ in
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
            },
            reportRecordingInterrupted: { error in
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
            },
            reportRewarmFailed: { error, reportSentryFailure in
                if reportSentryFailure {
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
            },
            graph: deviceRecoveryGraphSteps()
        )
    }

    private func deviceRecoveryGraphSteps() -> ParakeetDeviceRecoveryGraphSteps {
        ParakeetDeviceRecoveryGraphSteps(
            currentOwner: { self.currentAudioEngineQueueOwnerToken() },
            ownsQueue: { self.ownsAudioEngineQueue($0) },
            rebuildOnQueue: { reason in await self.rebuildAudioEngine(reason: reason) != nil },
            abandonBlockedGraph: { reason, owner in
                self.abandonBlockedAudioEngine(reason: reason, expectedOwner: owner)
            },
            scheduleFreshPrewarmRetry: {
                self.prewarmRetryCount = 0
                self.schedulePrewarmRetry()
            }
        )
    }

    private func scheduleConfigRecoveryTimeout(generation: UInt64, wasRecording: Bool) {
        configRecoveryTimeoutTask?.cancel()
        configRecoveryTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: TranscriptedConstants.audioDeviceRecoveryTimeout)
            guard !Task.isCancelled, let self, !self.isShuttingDown else { return }
            await ParakeetDeviceRecoverySequence.runTimeout(
                generation: generation,
                wasRecording: wasRecording,
                steps: self.deviceRecoveryTimeoutSteps(generation: generation, wasRecording: wasRecording)
            )
        }
    }

    private func deviceRecoveryTimeoutSteps(
        generation: UInt64,
        wasRecording: Bool
    ) -> ParakeetDeviceRecoveryTimeoutSteps {
        let timeoutSeconds = Double(TranscriptedConstants.audioDeviceRecoveryTimeout) / 1_000_000_000
        return ParakeetDeviceRecoveryTimeoutSteps(
            timeoutRecovery: { self.recoveryState.timeoutRecovery(generation: $0) },
            clearTimeoutTask: { self.configRecoveryTimeoutTask = nil },
            releaseRecordingIntent: { self.configChangeWasRecording = false },
            publishRecoveryState: { self.publishRecoveryState() },
            reportTimedOut: { failureAction in
                AnalyticsReporter.track(
                    "dictation_audio_route_recovery_timeout",
                    properties: self.dictationRouteAnalyticsContext(
                        selection: self.cachedInputDeviceSelection,
                        extra: [
                            "recovery_latency_bucket": AnalyticsReporter.durationBucket(seconds: timeoutSeconds),
                            "was_recording": "\(wasRecording)"
                        ]
                    )
                )
                WorkflowRecoveryTelemetry.finished(
                    workflowKind: "dictation",
                    failureKind: "route_changed",
                    retrySource: "audio_route_recovery",
                    result: "failed",
                    elapsedSeconds: timeoutSeconds,
                    surface: "runtime",
                    artifactRetained: !self.recoveredRecordingTimeline.isEmpty
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
            },
            interruptPreservingTimeline: { self.interruptRecordingPreservingRecoveredTimeline() },
            reportRecordingInterrupted: {
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
            },
            graph: deviceRecoveryGraphSteps()
        )
    }

    func cancelConfigRecoveryTimeout() {
        configRecoveryTimeoutTask?.cancel()
        configRecoveryTimeoutTask = nil
    }

    func cancelConfigRecoveryIfCurrent(generation: UInt64) {
        guard recoveryState.cancelRecovery(generation: generation) else { return }
        configChangeDebounceTask?.cancel()
        configChangeDebounceTask = nil
        configRecoveryTask?.cancel()
        configRecoveryTask = nil
        cancelConfigRecoveryTimeout()
        configChangeWasRecording = false
        publishRecoveryState()
    }
}

extension ParakeetEngine: ParakeetConfigChangeRecoveryHost {
    func beginConfigChangeRecovery() -> UInt64 {
        // Track whether any config change in the current burst interrupted a
        // recording. Once set, later changes in the same burst inherit it.
        if isRecording {
            configChangeWasRecording = true
        }
        // Bump the recovery generation and signal UI that the engine is
        // recovering. DictationSessionController waits on these flags.
        cancelConfigRecoveryTimeout()
        let recoveryGeneration = recoveryState.beginConfigChange()
        publishRecoveryState()
        scheduleConfigRecoveryTimeout(
            generation: recoveryGeneration,
            wasRecording: configChangeWasRecording
        )
        // Fresh device state warrants a fresh retry budget for prewarm.
        prewarmRetryCount = 0
        return recoveryGeneration
    }

    func cancelPrewarmRetry() {
        prewarmRetryTask?.cancel()
        prewarmRetryTask = nil
    }

    func markRecordingStoppedForRecovery() {
        isRecording = false
        audioLevel = 0
    }

    func reportGraphReusedAfterConfigChange() {
        AppLogger.transcription.info("PARAKEET | stable configuration change → reusing current audio graph")
    }
}
