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
            self?.scheduleInputDeviceNameRefresh(configChangeSource: .audioEngine)
        }
    }

    func removeAudioEngineConfigObserver() {
        guard let observer = configChangeObserver else { return }
        NotificationCenter.default.removeObserver(observer)
        configChangeObserver = nil
    }

    func restoreAudioEngineConfigObserverIfCurrent(
        _ owner: ParakeetAudioGraphOwnerToken
    ) {
        guard owner.matchesEngine(audioEngine), !isShuttingDown else { return }
        installAudioEngineConfigObserverIfNeeded()
    }

    // Migrated to the shared `DefaultInputDeviceMonitor` (codebase audit
    // 2026-08 — see that file's header for why three independent
    // kAudioHardwarePropertyDefaultInputDevice listeners were collapsed into
    // one). The CoreAudio-selection read runs off the main thread through the
    // one-worker latest-wins mailbox below. A route notification storm can
    // therefore retain at most one active lookup and one pending request.
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
            self?.scheduleInputDeviceNameRefresh(configChangeSource: .defaultInputDevice)
        }
    }

    func removeInputDeviceChangeListener() {
        guard let inputDeviceChangeObserverToken else { return }
        DefaultInputDeviceMonitor.shared.removeObserver(inputDeviceChangeObserverToken)
        self.inputDeviceChangeObserverToken = nil
    }

    nonisolated func scheduleInputDeviceNameRefresh(
        configChangeSource: ParakeetConfigChangeSource? = nil
    ) {
        guard inputDeviceRefreshMailbox.submit(
            configChangeSource: configChangeSource
        ) else { return }
        Task { @MainActor [weak self] in
            await self?.drainInputDeviceRefreshMailbox()
        }
    }

    private func drainInputDeviceRefreshMailbox() async {
        while !Task.isCancelled,
              !isShuttingDown,
              let request = inputDeviceRefreshMailbox.takeNext() {
            let loadedSelection = await Task.detached(priority: .utility) {
                Self.loadDictationInputDeviceSelection()
            }.value
            guard !Task.isCancelled, !isShuttingDown else { return }

            if let loadedSelection {
                updateCachedInputDeviceSelection(loadedSelection)
            } else {
                updateCachedInputDeviceName("Unknown")
            }

            guard let source = request.configChangeSource else { continue }
            let observedSelection: DictationInputDeviceSelection?
            if source == .defaultInputDevice {
                let selection = loadedSelection ?? Self.unknownInputDeviceSelection
                routeTransitionDebounceState.observe(categoricalAudioRoute(for: selection))
                observedSelection = selection
            } else {
                observedSelection = loadedSelection
            }
            await handleAudioConfigChange(
                source: source,
                observedSelection: observedSelection
            )
        }
    }

    private func handleAudioConfigChange(
        source: ParakeetConfigChangeSource,
        observedSelection: DictationInputDeviceSelection? = nil
    ) async {
        // Meeting capture owns the live audio graph while dictation borrows
        // its PCM. A system route change belongs to the meeting recovery path;
        // do not wake or rebuild the dormant dictation AVAudioEngine — but
        // only while the meeting session that lent the mic is still actually
        // alive. resolveSharedMeetingMicClaimStatus() resolves a claim
        // orphaned by a dead session (crash, error teardown ordering) to
        // `.stale`, releases it, and reports it; isSharedMeetingMicClaimCurrent
        // then reads false so config-change recovery still runs instead of
        // staying suppressed forever. Mirrors the guard in
        // ParakeetEngine.handleSystemWake().
        if isSharedMeetingMicClaimCurrent {
            return
        }
        // Recording startup owns route selection and format validation. Letting
        // the config-change recovery path run at the same time makes it fight
        // the intentional Bluetooth -> built-in override and can create a
        // restore/override loop between consecutive dictations.
        if audioStartInProgress {
            return
        }
        // A route notification that arrives while user stop is suspended must
        // not inherit the old recording bit and later restart the microphone.
        if audioStopInProgress {
            return
        }
        if CFAbsoluteTimeGetCurrent() < ignoreInputSelectionConfigChangesUntil {
            return
        }

        audioConfigObservationGeneration &+= 1
        let observationGeneration = audioConfigObservationGeneration
        let configChangeObservedAt = CFAbsoluteTimeGetCurrent()

        let currentSelection: DictationInputDeviceSelection?
        if let observedSelection {
            currentSelection = observedSelection
        } else {
            currentSelection = await Task.detached(priority: .utility) {
                Self.loadDictationInputDeviceSelection()
            }.value
        }

        // The route lookup above suspends outside the audio graph. Recheck all
        // lifecycle owners before this handler mutates recovery state.
        guard !isSharedMeetingMicClaimCurrent,
              !audioStartInProgress,
              !audioStopInProgress,
              observationGeneration == audioConfigObservationGeneration,
              CFAbsoluteTimeGetCurrent() >= ignoreInputSelectionConfigChangesUntil else {
            return
        }

        let observedRouteIdentity = currentSelection.map {
            ParakeetAudioRouteIdentity(selection: $0)
        }

        // An idle app has nothing to recover in real time. Rebuilding native
        // AVAudioEngine graphs for background route chatter can turn a noisy
        // CoreAudio notification source into unbounded retained engines. Mark
        // readiness stale and validate once, on the next explicit dictation.
        // A recording temporarily stopped by recovery keeps its intent through
        // configChangeWasRecording / the recovery flags and stays on the live
        // recovery path below.
        let hasActiveRecordingIntent = isRecording
            || configChangeWasRecording
            || preservingRecordingAcrossRecovery
            || zombieRecoveryState.isActive
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

        if ParakeetConfigChangeContinuityPolicy.shouldProbe(
            wasRecording: isRecording,
            hadSampleFlow: hasReceivedAudioSamples,
            inputWasReady: recoveryState.canStartRecording,
            graphEndpointsMatch: graphEndpointsMatch
        ) {
            try? await Task.sleep(
                nanoseconds: TranscriptedConstants.audioConfigChangeDebounceDelay
            )
            guard !isSharedMeetingMicClaimCurrent,
                  !audioStartInProgress,
                  !audioStopInProgress,
                  observationGeneration == audioConfigObservationGeneration,
                  CFAbsoluteTimeGetCurrent() >= ignoreInputSelectionConfigChangesUntil else {
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
            observedRouteIdentity: observedRouteIdentity
        )
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
        let configCleanupOwner = currentAudioEngineQueueOwnerToken()

        if isRecording {
            preserveCurrentRecordingBuffersForRecovery()
            await removeRecordingTap()
            guard ownsAudioEngineQueue(configCleanupOwner) else {
                cancelConfigRecoveryIfCurrent(generation: recoveryGeneration)
                return
            }
            isRecording = false
            audioLevel = 0
        }

        await stopAudioEngine()
        guard ownsAudioEngineQueue(configCleanupOwner) else {
            cancelConfigRecoveryIfCurrent(generation: recoveryGeneration)
            return
        }
        isEnginePrewarmed = false

        switch graphStrategy {
        case .reuseCurrentGraph:
            // CoreAudio already stopped this graph. Leave it in place so the
            // normal recovery snapshot + recording restart can rebind the tap
            // without retiring another AVAudioEngine and scheduling another
            // late configuration echo.
            AppLogger.transcription.info("PARAKEET | stable configuration change → reusing current audio graph")
        case .rebuildGraph:
            guard let rebuiltOwner = await rebuildAudioEngine(reason: "configuration_change") else {
                cancelConfigRecoveryIfCurrent(generation: recoveryGeneration)
                return
            }
            guard ownsAudioGraph(rebuiltOwner) else {
                cancelConfigRecoveryIfCurrent(generation: recoveryGeneration)
                return
            }
        }

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
            let wasRecordingForAnalytics = self.configChangeWasRecording
            Task.detached(priority: .utility) { [weak self] in
                let selection = Self.loadDictationInputDeviceSelection()
                await self?.recordStableRouteChangeAnalytics(
                    selection: selection,
                    wasRecording: wasRecordingForAnalytics,
                    recoveryGeneration: recoveryGeneration
                )
            }
            // Telemetry coalescing must never suppress the real recovery state
            // transition, including an A -> B -> A notification burst.
            self.attemptDeviceRecovery()
        }
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

            guard !Task.isCancelled else { return }
            guard !self.recoveryState.isStale(generation: myGeneration) else { return }

            var lastSnapshotOwner: ParakeetAudioEngineQueueOwnerToken?
            do {
                var recoveryAttempt = 0
                var readySnapshot: ParakeetAudioInputSnapshot?
                while readySnapshot == nil {
                    recoveryAttempt += 1
                    let snapshotOwner = self.currentAudioEngineQueueOwnerToken()
                    lastSnapshotOwner = snapshotOwner
                    self.audioEngineWorkOwnership.begin(
                        owner: snapshotOwner,
                        phase: .deviceRecoverySnapshot
                    )
                    let snapshot: ParakeetAudioInputSnapshot
                    do {
                        snapshot = try await self.audioInputSnapshot(
                            operation: recoveryAttempt == 1 ? "device_recovery" : "device_recovery_retry",
                            recoveryGeneration: myGeneration,
                            isEngineWorkCurrent: { [audioEngineWorkOwnership] in
                                audioEngineWorkOwnership.isActive(
                                    owner: snapshotOwner,
                                    phase: .deviceRecoverySnapshot
                                )
                            }
                        )
                        guard self.audioEngineWorkOwnership.finish(
                            owner: snapshotOwner,
                            phase: .deviceRecoverySnapshot
                        ) else {
                            throw CancellationError()
                        }
                    } catch {
                        self.audioEngineWorkOwnership.finish(
                            owner: snapshotOwner,
                            phase: .deviceRecoverySnapshot
                        )
                        throw error
                    }
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
                    var restartBudget = ParakeetRecordingRestartBudget(
                        startedAtUptime: ProcessInfo.processInfo.systemUptime
                    )
                    while let attempt = restartBudget.takeNextAttempt(
                        nowUptime: ProcessInfo.processInfo.systemUptime
                    ) {
                        guard !Task.isCancelled else { return }
                        guard !self.recoveryState.isStale(generation: myGeneration) else { return }
                        let startSucceeded = await self.startRecording()
                        guard !Task.isCancelled else { return }
                        guard !self.recoveryState.isStale(generation: myGeneration) else { return }
                        if startSucceeded {
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
                        guard ParakeetDeviceRecoveryStartRetryPolicy.shouldRetry(
                            after: self.lastRecordingStartFailureReason,
                            inputCanStartRecording: self.recoveryState.canStartRecording
                        ) else { break }
                        // A measured split Bluetooth route needed one more probe
                        // after the old two-second window. Wait only when another
                        // bounded attempt remains; do not add dead time after the
                        // terminal failure.
                        guard let delay = restartBudget.delayBeforeNextAttempt(
                            nowUptime: ProcessInfo.processInfo.systemUptime
                        ) else { break }
                        try? await Task.sleep(nanoseconds: delay)
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
                let audioEngineWorkError = error as? ParakeetAudioEngineWorkError
                let audioEngineQueueBlocked =
                    audioEngineWorkError?.requiresGraphAbandonment == true
                if audioEngineQueueBlocked {
                    guard let lastSnapshotOwner,
                          self.ownsAudioEngineQueue(lastSnapshotOwner) else { return }
                }
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
                // Circuit-open means this attempt never entered the current
                // queue. The already-counted blocked workers keep their leases;
                // fail closed without retiring another healthy graph.
                if audioEngineWorkError?.isCircuitOpen == true {
                    return
                }
                switch ParakeetDeviceRecoveryFailurePolicy.rebuildStrategy(
                    audioEngineQueueBlocked: audioEngineQueueBlocked
                ) {
                case .queuedOnAudioEngineQueue:
                    guard await self.rebuildAudioEngine(reason: "device_change_rewarm_failed") != nil else { return }
                case .abandonBlockedAudioGraph:
                    guard let lastSnapshotOwner,
                          self.abandonBlockedAudioEngine(
                            reason: "device_change_rewarm_failed",
                            expectedOwner: lastSnapshotOwner
                          ) else { return }
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
            let timeoutOwner = self.currentAudioEngineQueueOwnerToken()
            switch timeoutAction.rebuildStrategy {
            case .queuedOnAudioEngineQueue:
                guard await self.rebuildAudioEngine(reason: "device_change_recovery_timeout") != nil else { return }
            case .abandonBlockedAudioGraph:
                guard self.abandonBlockedAudioEngine(
                    reason: "device_change_recovery_timeout",
                    expectedOwner: timeoutOwner
                ) else { return }
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
