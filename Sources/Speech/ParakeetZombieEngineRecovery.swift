// ParakeetZombieEngineRecovery.swift
// Zombie-audio-engine detection and bounded replacement for ParakeetEngine,
// split out of ParakeetEngine.swift (codebase audit 2026-08-05 follow-up
// wave — same extension-file pattern as ParakeetDeviceRecovery.swift and
// ParakeetModelLifecycle.swift).
//
// After sleep/wake, CoreAudio can report the engine as running while the
// hardware graph is disconnected. This file owns the startup watchdog that
// detects that state (no/only-silent samples after recording start) and the
// separate generation-gated recovery task that replaces the stale
// AVAudioEngine through a bounded reset and retries once. Do not fold the
// recovery task back into the watchdog or reuse a detected zombie graph —
// see Sources/Speech/CLAUDE.md.
//
// These are internal collaborator methods on ParakeetEngine — ParakeetEngine
// remains the public-API owner and MainActor home for this state
// (`audioWatchdogTask`, `zombieRecoveryTask`, `zombieRecoveryState`,
// `zombieRecoveryStartGeneration`); this file just groups the zombie-recovery
// slice of its implementation. The audio-graph/queue owner-token helpers it
// guards with stay in ParakeetEngine.swift because every start/stop path
// uses them, not just recovery.

@preconcurrency import AVFoundation
import Foundation
import TranscriptedCore

extension ParakeetEngine {
    /// Watchdog that detects zombie audio engines — running but producing no usable signal.
    /// After sleep/wake, CoreAudio may report the engine as running but the hardware graph
    /// is disconnected. If no samples arrive within 2 seconds, replace the stale engine
    /// through a bounded reset and retry once.
    /// If the user stops dictation during the recovery delay, the pending retry is cleared
    /// so the watchdog does not revive a recording the user already ended.
    func startAudioWatchdog() {
        audioWatchdogTask?.cancel()
        audioWatchdogTask = nil
        audioWatchdogTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: TranscriptedConstants.audioWatchdogTimeout)
            guard let self = self, self.isRecording, !Task.isCancelled else { return }

            let sampleCount = self.pendingSamplesLock.withLock {
                guard self.isRecording else { return -1 }
                return self.pendingSamples.count + self.sampleBuffer.count
            }
            guard sampleCount >= 0 else { return }

            let shouldReset = ParakeetSampleSignalPolicy.shouldResetStartupAudio(
                sampleCount: sampleCount,
                hasNonZeroSignal: self.didReceiveNonZeroAudioSamples,
                isLikelyBluetoothHandsFreeRoute: self.recordingStartedOnLikelyBluetoothHandsFreeRoute
            )
            guard shouldReset else { return }

            let failureKind = sampleCount == 0 ? "no_sample_callbacks" : "silent_hfp_callbacks"
            EventReporter.shared.capture(level: .warning, engine: "parakeet", event: "zombie_engine_detected",
                message: sampleCount == 0
                    ? "No audio samples received after recording start — resetting engine"
                    : "Only silent audio samples received after recording start — resetting engine",
                context: self.zombieRecoveryTelemetryContext(
                    failureKind: failureKind,
                    stage: .detected,
                    result: nil
                ))

            // Detection and recovery use separate task lifetimes. Otherwise the
            // recovery's call into startRecording cancels the watchdog task that
            // is currently executing, skipping cancellation-aware settle work.
            self.audioWatchdogTask = nil
            self.startZombieEngineRecovery(failureKind: failureKind)
        }
    }

    private func startZombieEngineRecovery(failureKind: String) {
        guard !zombieRecoveryState.isActive else { return }
        let generation = zombieRecoveryState.begin(failureKind: failureKind)
        zombieRecoveryTask = Task { @MainActor [weak self] in
            await self?.runZombieEngineRecovery(generation: generation)
        }
    }

    private func runZombieEngineRecovery(generation: UInt64) async {
        defer {
            clearZombieRecoveryStartGeneration(ifMatching: generation)
            if zombieRecoveryState.canContinue(generation: generation) {
                finishZombieEngineRecovery(
                    generation: generation,
                    result: Task.isCancelled ? .cancelled : .failed
                )
            }
        }

        guard zombieRecoveryState.advance(to: .reset, generation: generation) else { return }
        let recoveryGraphOwner = currentAudioGraphOwnerToken()
        pendingSamplesLock.withLock {
            pendingSamples.removeAll(keepingCapacity: true)
            didReportPendingSampleTruncation = false
        }
        isRecording = false
        audioLevel = 0
        configChangeWasRecording = false
        ignoreInputSelectionConfigChangesUntil = CFAbsoluteTimeGetCurrent()
            + TranscriptedConstants.selfInducedConfigChangeIgnoreWindow

        // Stop/config-change cancellation takes ownership of graph cleanup. The
        // superseded zombie task must not enter recreation after this suspension.
        guard canContinueZombieEngineRecovery(
            generation: generation,
            expectedOwner: recoveryGraphOwner
        ) else { return }
        guard await recreateAudioEngineForZombieRecovery(
            generation: generation,
            expectedOwner: recoveryGraphOwner
        ) else { return }
        guard !Task.isCancelled, zombieRecoveryState.canContinue(generation: generation) else { return }

        guard zombieRecoveryState.advance(to: .settle, generation: generation) else { return }
        do {
            try await Task.sleep(nanoseconds: TranscriptedConstants.audioRecoveryDelay)
        } catch {
            return
        }
        guard !Task.isCancelled, zombieRecoveryState.canContinue(generation: generation) else { return }

        guard zombieRecoveryState.advance(to: .restart, generation: generation) else { return }
        zombieRecoveryStartGeneration = generation
        let started = await startRecording(isRecoveryAttempt: true)
        clearZombieRecoveryStartGeneration(ifMatching: generation)
        guard zombieRecoveryState.canContinue(generation: generation) else { return }

        if started {
            AppLogger.transcription.info("PARAKEET | zombie engine recovered — recording restarted")
            finishZombieEngineRecovery(generation: generation, result: .succeeded)
        } else {
            AppLogger.transcription.error("PARAKEET | zombie engine recovery failed")
            interruptRecordingPreservingRecoveredTimeline()
            finishZombieEngineRecovery(generation: generation, result: .failed)
        }
    }

    /// A detected zombie is evidence that the current AVAudioEngine graph is stale.
    /// Replace that instance rather than stopping and starting it again. Queue work
    /// is bounded; if CoreAudio does not return, abandon the old graph and queue.
    private func recreateAudioEngineForZombieRecovery(
        generation: UInt64,
        expectedOwner: ParakeetAudioGraphOwnerToken
    ) async -> Bool {
        guard canContinueZombieEngineRecovery(
            generation: generation,
            expectedOwner: expectedOwner
        ) else { return false }

        trackAudioEngineRebuildChurn(reason: "zombie_engine_recovery")
        audioGraphGeneration += 1
        let resetOwner = currentAudioGraphOwnerToken()
        let resetQueueOwner = currentAudioEngineQueueOwnerToken()
        removeAudioEngineConfigObserver()
        defer {
            restoreAudioEngineConfigObserverIfCurrent(resetOwner)
        }
        let retiredEngine = audioEngine
        audioEngineWorkOwnership.begin(owner: resetQueueOwner, phase: .zombieReset)

        do {
            try await runTimedAudioEngineWork(operation: "zombie_engine_reset") { [audioEngineWorkOwnership] audioEngine in
                defer {
                    audioEngineWorkOwnership.finish(
                        owner: resetQueueOwner,
                        phase: .zombieReset
                    )
                }
                Self.safelyRemoveInputTap(on: audioEngine)
                audioEngine.reset()
            }
        } catch {
            audioEngineWorkOwnership.finish(owner: resetQueueOwner, phase: .zombieReset)
            guard error is ParakeetAudioEngineWorkError else { return false }
            guard canContinueZombieEngineRecovery(
                generation: generation,
                expectedOwner: resetOwner
            ) else { return false }

            // Only the exact generation+engine owner may abandon a timed-out
            // queue; a newer graph may reuse the same engine instance.
            return abandonBlockedAudioEngine(
                reason: "zombie_engine_reset_timeout",
                expectedOwner: resetQueueOwner
            )
        }

        guard canContinueZombieEngineRecovery(
            generation: generation,
            expectedOwner: resetOwner
        ) else { return false }

        inputTapInstalled = false
        isEnginePrewarmed = false
        didReceiveAudioSamples = false
        didReceiveNonZeroAudioSamples = false
        recordingStartedOnLikelyBluetoothHandsFreeRoute = false
        removeAudioEngineConfigObserver()
        let didReserveRetiredEngine = reserveRetiredAudioEngine(
            retiredEngine,
            reason: "zombie_engine_recovery"
        )
        guard didReserveRetiredEngine else {
            // A watchdog-confirmed zombie is never safe to reuse, even after
            // reset. Once the bounded retirement store is full, fail this
            // attempt and let its delayed releases make room for a later one.
            AppLogger.transcription.error(
                "PARAKEET | zombie audio graph replacement refused because retirement limit is full"
            )
            // Recovery already transitioned the engine to non-recording. Tell
            // the owning dictation session immediately so its listening UI
            // cannot remain active while no microphone samples are arriving.
            interruptRecordingPreservingRecoveredTimeline()
            return false
        }
        audioEngine = AVAudioEngine()
        if !isShuttingDown {
            installAudioEngineConfigObserverIfNeeded()
        }
        EventReporter.shared.capture(
            level: .warning,
            engine: "parakeet",
            event: "audio_engine_rebuilt",
            message: "Audio engine replaced after zombie-state detection",
            context: ["reason": "zombie_engine_recovery"]
        )
        return true
    }

    private func canContinueZombieEngineRecovery(
        generation: UInt64,
        expectedOwner: ParakeetAudioGraphOwnerToken
    ) -> Bool {
        ParakeetZombieRecoveryOwnershipPolicy.canContinue(
            taskIsCancelled: Task.isCancelled,
            recoveryIsCurrent: zombieRecoveryState.canContinue(generation: generation),
            expectedOwner: expectedOwner,
            currentGraphGeneration: audioGraphGeneration,
            currentEngine: audioEngine
        )
    }

    private func clearZombieRecoveryStartGeneration(ifMatching generation: UInt64) {
        guard zombieRecoveryStartGeneration == generation else { return }
        zombieRecoveryStartGeneration = nil
    }

    private func finishZombieEngineRecovery(
        generation: UInt64,
        result: ParakeetZombieRecoveryResult
    ) {
        guard let terminal = zombieRecoveryState.finish(result: result, generation: generation) else { return }
        zombieRecoveryTask = nil
        reportZombieEngineRecoveryTerminal(terminal)
    }

    func reportZombieEngineRecoveryTerminal(_ terminal: ParakeetZombieRecoveryTerminal) {
        let context = zombieRecoveryTelemetryContext(
            failureKind: terminal.failureKind,
            stage: terminal.stage,
            result: terminal.result
        )
        AnalyticsReporter.track("dictation_zombie_recovery_finished", properties: context)

        switch terminal.result {
        case .succeeded:
            EventReporter.shared.capture(
                level: .info,
                engine: "parakeet",
                event: "zombie_engine_recovered",
                message: "Audio engine recovered after bounded replacement",
                context: context
            )
        case .failed:
            EventReporter.shared.capture(
                level: .error,
                engine: "parakeet",
                event: "zombie_engine_recovery_failed",
                message: "Audio engine could not recover after bounded replacement",
                context: context
            )
        case .cancelled:
            EventReporter.shared.capture(
                level: .info,
                engine: "parakeet",
                event: "zombie_engine_recovery_cancelled",
                message: "Audio engine recovery was cancelled",
                context: context
            )
        }
    }

    private func zombieRecoveryTelemetryContext(
        failureKind: String,
        stage: ParakeetZombieRecoveryStage,
        result: ParakeetZombieRecoveryResult?
    ) -> [String: String] {
        let route = dictationRouteAnalyticsContext(selection: cachedInputDeviceSelection)
        var context: [String: String] = [
            "failure_kind": failureKind,
            "hfp_suspected": route["hfp_suspected"] ?? "false",
            "input_device_class": route["input_device_class"] ?? "unknown",
            "output_device_class": route["output_device_class"] ?? "unknown",
            "route_shape": route["route_shape"] ?? "unknown",
            "stage": stage.rawValue,
        ]
        if let result {
            context["result"] = result.rawValue
        }
        return context
    }
}
