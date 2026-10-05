// ParakeetInputReadiness.swift
// Idle dictation input readiness for ParakeetEngine: prewarm, bounded
// prewarm retry, forced readiness recovery, the recovery-state publishers,
// and the native sample-rate accessors. Split out of ParakeetEngine.swift.
//
// Pinned-microphone dictation takes its early branch before any engine
// work here, so a Bluetooth default input is never bound by prewarm.
//
// These are internal collaborator methods on ParakeetEngine. ParakeetEngine
// (ParakeetEngine.swift) stays the public-API owner and @MainActor home for
// the state; this file only groups one slice of its implementation.

@preconcurrency import AVFoundation
import Foundation
import TranscriptedCore

extension ParakeetEngine {
    // MARK: - Input readiness

    func prewarm() async {
        guard !Task.isCancelled else { return }
        guard !isShuttingDown else { return }
        guard !isRecording else { return }
        guard !audioStartInProgress else { return }
        if usesPinnedDictationMicrophone() {
            let skipsEngineWarmup = await pinnedDictationSkipsEngineWarmup()
            guard !Task.isCancelled, !isShuttingDown, !isRecording, !audioStartInProgress else { return }
            if skipsEngineWarmup {
                markPinnedDictationInputReady()
                return
            }
        }
        var admissionOwner = currentAudioEngineQueueOwnerToken()
        guard prewarmAdmission.begin(owner: admissionOwner) else {
            // Join the existing probe instead of returning immediately: the
            // caller counts finished refreshes toward forced graph replacement.
            // A quick no-op here would still churn a slow-but-healthy binding.
            let waitStartedAt = ProcessInfo.processInfo.systemUptime
            while let active = prewarmAdmission.owner,
                  active.matchesResources(engine: audioEngine, queue: audioEngineQueue),
                  !isShuttingDown, !isRecording, !audioStartInProgress,
                  ProcessInfo.processInfo.systemUptime - waitStartedAt < TranscriptedConstants.dictationReadinessRefreshTimeout {
                do { try await Task.sleep(nanoseconds: TranscriptedConstants.dictationReadinessPollInterval) }
                catch { return }
            }
            return
        }
        defer { prewarmAdmission.finish(owner: admissionOwner) }
        installAudioObserversIfNeeded()
        scheduleInputDeviceNameRefresh()

        guard let releasedOwner = await releaseIdleAudioHardware(removeTap: false),
              prewarmAdmission.transfer(from: admissionOwner, to: releasedOwner) else { return }
        admissionOwner = releasedOwner
        guard !Task.isCancelled else { return }
        let prewarmOwner = currentAudioEngineQueueOwnerToken()
        guard canContinuePrewarm(owner: prewarmOwner) else { return }

        let microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        switch ParakeetPrewarmPolicy.decision(for: microphoneStatus) {
        case .proceed:
            break
        case .skip(let level, let event, let message, let context):
            let eventLevel: EventLevel
            switch level {
            case .info:
                eventLevel = .info
            case .warning:
                eventLevel = .warning
            }
            EventReporter.shared.capture(
                level: eventLevel,
                engine: "parakeet",
                event: event,
                message: message,
                context: context
            )
            return
        }

        let snapshot: ParakeetAudioInputSnapshot
        do {
            snapshot = try await audioInputSnapshot(
                operation: "prewarm",
                isEngineWorkCurrent: nil
            )
        } catch {
            guard canContinuePrewarm(owner: prewarmOwner) else { return }
            EventReporter.shared.capture(
                level: .warning,
                engine: "parakeet",
                event: "prewarm_failed",
                message: error.localizedDescription
            )
            markFormatUnreadyAndPublish()
            schedulePrewarmRetry()
            return
        }
        guard canContinuePrewarm(owner: prewarmOwner) else { return }

        // Both buses must be available before publishing readiness. A raw
        // AirPods input can still expose a stale 48kHz output bus over 24kHz
        // hardware; startup explicitly aligns its tap with the live hardware
        // format instead of assuming the input node will convert between them.
        let readiness = audioFormatReadiness(
            outputFormat: snapshot.outputFormat,
            hwFormat: snapshot.hwFormat,
            selection: snapshot.selection
        )
        guard readiness == .ready else {
            EventReporter.shared.capture(level: .warning, engine: "parakeet", event: "prewarm_invalid_format",
                message: "Audio format invalid during prewarm",
                context: audioFormatContext(
                    outputFormat: snapshot.outputFormat,
                    hwFormat: snapshot.hwFormat,
                    selection: snapshot.selection,
                    readiness: readiness
                ))
            // Do NOT rebuild the engine here, even for .routeNotSettled. The override
            // this snapshot just applied (built-in mic instead of a Bluetooth headset)
            // lives on this engine's AUHAL; discarding the engine forces the next
            // snapshot to touch the AirPods mic again to rebind the AUHAL to the
            // system default before re-applying the override — audibly bumping the
            // Bluetooth route on every retry and racing settling with churn instead
            // of waiting it out. Keep the engine and let schedulePrewarmRetry() poll;
            // applyPreferredDictationInputDevice() is a no-op once the deviceID already
            // matches, so retries here are cheap format reads with no route touch.
            markFormatUnreadyAndPublish()
            schedulePrewarmRetry()
            return
        }

        updateNativeSampleRate(snapshot.outputFormat.sampleRate)

        prewarmRetryCount = 0
        markFormatReadyAndPublish()
        AppLogger.transcription.info("PARAKEET | input ready (\(inputDeviceName), \(safeNativeSampleRate())Hz)")
    }

    private func canContinuePrewarm(owner: ParakeetAudioEngineQueueOwnerToken) -> Bool {
        !isShuttingDown
            && !isRecording
            && !audioStartInProgress
            && ownsAudioEngineQueue(owner)
    }

    func schedulePrewarmRetry() {
        guard !isShuttingDown else { return }
        // Bounded retry — give CoreAudio time to settle, but don't loop forever.
        // Each call counts toward the budget; budget resets on a successful prewarm
        // or on an explicit device change (which restarts the cycle anyway).
        guard prewarmRetryCount < TranscriptedConstants.prewarmRetryBudget else {
            EventReporter.shared.capture(level: .warning, engine: "parakeet",
                event: "prewarm_retry_budget_exhausted",
                message: "Prewarm retry budget exhausted — engine will retry on next device change or user action",
                context: ["audio_device": inputDeviceName])
            prewarmRetryCount = 0
            return
        }
        prewarmRetryCount += 1
        let capturedGeneration = recoveryState.generation
        prewarmRetryTask?.cancel()
        prewarmRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: TranscriptedConstants.audioRecoveryDelay)
            guard !Task.isCancelled,
                  let self,
                  !self.isShuttingDown,
                  !self.recoveryState.isStale(generation: capturedGeneration) else { return }
            await self.prewarm()
        }
    }

    func forceInputReadinessRecovery(reason: String) async {
        guard !Task.isCancelled else { return }
        guard !isShuttingDown else { return }
        guard !isRecording, !audioStartInProgress else { return }
        if usesPinnedDictationMicrophone() {
            // Hold the readiness wait while the route is read, so a start
            // can't slip in on the stale engine before it is replaced.
            // `markPinnedDictationInputReady` clears this on the skip path.
            markFormatUnreadyAndPublish()
            let decision = await pinnedDictationWarmupDecision()
            guard !Task.isCancelled, !isShuttingDown, !isRecording, !audioStartInProgress else { return }
            if decision.skipsEngineWarmup {
                if decision.engineRecordsBluetoothInput {
                    // Starts on this headset keep failing against an engine
                    // bound to the old route. Swap in a fresh one, as a
                    // relaunch would; nothing opens the headset until the
                    // next key press.
                    abandonBlockedAudioEngine(reason: reason)
                }
                markPinnedDictationInputReady()
                return
            }
        }

        prewarmRetryTask?.cancel()
        prewarmRetryTask = nil
        prewarmRetryCount = 0

        EventReporter.shared.capture(
            level: .warning,
            engine: "parakeet",
            event: "input_readiness_recovery_forced",
            message: "Forced idle audio graph recovery while waiting for dictation input readiness",
            context: [
                "reason": reason,
                "recovering": "\(recoveryState.isRecovering)",
                "format_ready": "\(recoveryState.inputFormatReady)",
                "generation": "\(recoveryState.generation)",
            ]
        )

        abandonBlockedAudioEngine(reason: reason)
        markFormatUnreadyAndPublish()
        do {
            try await Task.sleep(nanoseconds: TranscriptedConstants.audioRecoveryDelay)
        } catch {
            return
        }
        guard !Task.isCancelled else { return }
        await prewarm()
    }

    func publishRecoveryState() {
        isRecovering = recoveryState.isRecovering
        inputFormatReady = recoveryState.inputFormatReady
    }

    func markFormatUnreadyAndPublish() {
        recoveryState.markFormatUnready()
        publishRecoveryState()
    }

    func markStartFailedAndPublish() {
        recoveryState.markStartFailed()
        publishRecoveryState()
    }

    func markFormatReadyAndPublish() {
        if !recoveryState.inputFormatReady {
            recoveryState.markFormatReady()
            publishRecoveryState()
        }
    }

    func safeNativeSampleRate() -> Double {
        pendingSamplesLock.withLock {
            ParakeetAudioFormatReadinessPolicy.captureSampleRateOrFallback(nativeSampleRate)
        }
    }

    func updateNativeSampleRate(_ sampleRate: Double) {
        pendingSamplesLock.withLock {
            nativeSampleRate = ParakeetAudioFormatReadinessPolicy.captureSampleRateOrFallback(sampleRate)
        }
    }
}
