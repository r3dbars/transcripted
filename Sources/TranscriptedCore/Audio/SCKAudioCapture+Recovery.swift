import AVFoundation
import Combine
import CoreMedia
import QuartzCore
import ScreenCaptureKit

@available(macOS 26.0, *)
extension SCKAudioCapture {
    /// Proactive post-wake recovery hook (`SystemAudioCaptureEngine`
    /// conformance). Mirrors `Audio.installWorkspaceSleepWakeObservers()`'s
    /// mic-path kick, which restarts the mic graph ~1s after wake instead of
    /// waiting for the watchdog to notice a stall — ScreenCaptureKit streams
    /// can come back from sleep in the same silently-stuck state a stalled
    /// mic tap does, and this path gets one chance to do the same before this
    /// backend's own buffer-stall watchdog would otherwise take up to
    /// `bufferStallTimeoutSeconds` to notice.
    ///
    /// No-ops when nothing is actively capturing, so calling this
    /// unconditionally after every wake (recording or not) is safe. Reuses
    /// `handleMidRecordingFailure`'s existing bounded-recovery machinery —
    /// same one-attempt cap, same epoch/token ownership — rather than adding
    /// a second recovery path.
    func recoverAfterSystemWake() {
        let state = currentStreamState()
        guard state.isCapturing, let generation = state.generation else { return }
        // Do not gate on last-buffer age. CACurrentMediaTime pauses during
        // sleep, so a stuck stream looks freshly healthy after lid-open.
        AppLogger.audioSystem.info("SCKAudioCapture: proactive recovery after system wake")
        handleMidRecordingFailure(
            "System audio reconnecting after system wake.",
            generation: generation,
            attemptRestart: true
        )
    }
    func logStats() {
        statsLock.lock()
        let total = _totalBuffers
        let withData = _buffersWithData
        statsLock.unlock()
        AppLogger.audioSystem.info("SCKAudioCapture: buffer stats", [
            "total": "\(total)",
            "withData": "\(withData)"
        ])
    }

    func resetStats() {
        statsLock.lock()
        _totalBuffers = 0
        _buffersWithData = 0
        statsLock.unlock()
    }

    func publishErrorMessage(_ message: String?) {
        if Thread.isMainThread {
            errorMessage = message
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.errorMessage = message
            }
        }
    }

    func publishHealthyIfCurrent(identity: ObjectIdentifier, generation: UInt64) {
        let publish = { [weak self] in
            guard let self,
                  self.isCurrentCapturingStream(identity: identity, generation: generation) else {
                return
            }
            self.errorMessage = nil
        }
        if Thread.isMainThread {
            publish()
        } else {
            DispatchQueue.main.async(execute: publish)
        }
    }

    func resetBufferWatchdogState() {
        watchdogLock.lock()
        _lastBufferTime = CACurrentMediaTime()
        _hasReceivedFirstBuffer = false
        watchdogLock.unlock()
    }

    func markBufferReceived() {
        watchdogLock.lock()
        _lastBufferTime = CACurrentMediaTime()
        _hasReceivedFirstBuffer = true
        watchdogLock.unlock()
    }

    /// The monotonic time of the last real audio buffer this capture
    /// delivered — the same value the buffer-stall watchdog compares
    /// against. Used to measure recovery-gap duration from when audio
    /// actually stopped flowing, not from whenever the watchdog/error
    /// callback happened to notice.
    func lastKnownBufferTime() -> CFTimeInterval {
        watchdogLock.lock()
        defer { watchdogLock.unlock() }
        return _lastBufferTime
    }

    /// Mirrors `Audio.waitForMicBuffer`: poll until a real buffer arrives or
    /// the timeout expires. Used after a recovery `start()` so a silent
    /// restart does not refund the attempt budget.
    func waitForRestartedBuffer(timeout: TimeInterval) -> Bool {
        let deadline = CACurrentMediaTime() + timeout
        while CACurrentMediaTime() < deadline {
            if !currentStreamState().isCapturing { return false }
            watchdogLock.lock()
            let got = _hasReceivedFirstBuffer
            watchdogLock.unlock()
            if got { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        if !currentStreamState().isCapturing { return false }
        watchdogLock.lock()
        defer { watchdogLock.unlock() }
        return _hasReceivedFirstBuffer
    }

    func startWatchdog(generation: UInt64) {
        stopWatchdog()
        let timer = DispatchSource.makeTimerSource(queue: watchdogQueue)
        let interval = DispatchTimeInterval.milliseconds(Int(Self.bufferStallTimeoutSeconds * 1000))
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            self?.checkWatchdog(generation: generation)
        }
        watchdogLock.lock()
        watchdogTimer = timer
        watchdogLock.unlock()
        timer.resume()
    }

    func stopWatchdog() {
        watchdogLock.lock()
        let timer = watchdogTimer
        watchdogTimer = nil
        watchdogLock.unlock()
        timer?.cancel()
    }

    func checkWatchdog(generation: UInt64) {
        guard isActiveCaptureGeneration(generation) else { return }
        watchdogLock.lock()
        let elapsed = CACurrentMediaTime() - _lastBufferTime
        watchdogLock.unlock()

        // Missing-buffer stall, including the silent-after-restart case
        // where start() reset lastBufferTime to now and first-buffer is
        // still false. Do not require a prior buffer. Amplitude silence
        // alone never reaches this path.
        guard elapsed >= Self.bufferStallTimeoutSeconds else { return }
        AppLogger.audioSystem.error("SCKAudioCapture: buffer watchdog timed out", [
            "elapsedSeconds": String(format: "%.1f", elapsed)
        ])
        handleMidRecordingFailure(
            "System audio failed - ScreenCaptureKit stopped sending audio buffers.",
            generation: generation,
            attemptRestart: true
        )
    }

    func handleMidRecordingFailure(
        _ message: String,
        generation: UInt64,
        attemptRestart: Bool
    ) {
        // Captured BEFORE any recovery step runs. The buffer watchdog only
        // fires after `bufferStallTimeoutSeconds` of silence, so measuring
        // the gap from "now" (when the watchdog/`didStopWithError` finally
        // noticed) would omit that entire silent stretch — the largest part
        // of the real outage. `_lastBufferTime` is the actual moment audio
        // stopped flowing; `stopSync`/`prepare`/`start` below reset it via
        // `resetBufferWatchdogState()`, so it must be read here, once, and
        // carried through as a local rather than re-read after recovery.
        let lastKnownBufferTimeAtFailure = self.lastKnownBufferTime()
        guard isActiveCaptureGeneration(generation) else { return }
        guard attemptRestart, let callback = activeFailureCallback(generation: generation) else {
            publishErrorMessage(message)
            return
        }

        // Atomically check-and-set recovery state so concurrent failure
        // callbacks cannot both start recovery, and an official stop cannot
        // slip between the active-capture check and token creation.
        var recoveryToken: SCKRecoveryEpochState.Token?
        var recoveryAttempt = 0
        var exhaustedRecovery = false
        captureStateLock.lock()
        if _isCapturing,
           streamPhase == .capturing,
           streamGeneration == generation,
           recoveryEpochState.acceptsRecovery,
           !isRecovering {
            if recoveryAttempts < Self.maxRecoveryAttempts {
                recoveryAttempts += 1
                isRecovering = true
                recoveryAttempt = recoveryAttempts
                recoveryToken = recoveryEpochState.begin()
            } else {
                exhaustedRecovery = true
            }
        }
        captureStateLock.unlock()

        guard let recoveryToken else {
            if exhaustedRecovery {
                publishErrorMessage(message)
            }
            return
        }
        publishErrorMessage("System audio reconnecting after capture interruption.")
        // Report the attempt the same way the mic path counts a device
        // switch at the start of `recoverFromDeviceChange`, so system-audio
        // recovery is visible in `RecordingHealthInfo` even if the attempt
        // ultimately fails.
        recoveryEventSubject.send(.deviceSwitch)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var recoverySucceeded = false
            defer {
                // Every exit that never reached `.gap` must still release
                // the write hold `.deviceSwitch` armed, or the rest of the
                // recording's system buffers are dropped. Sent before
                // finishRecovery so a successor attempt cannot arm its own
                // hold ahead of this release.
                if !recoverySucceeded {
                    self.recoveryEventSubject.send(.recoveryAbandoned)
                }
                self.finishRecovery(recoveryToken)
            }
            do {
                AppLogger.audioSystem.info("SCKAudioCapture: attempting stream recovery", [
                    "attempt": "\(recoveryAttempt)"
                ])

                guard self.shouldContinueRecovery(recoveryToken, at: "before cleanup") else { return }
                self.stopSync(preservingRecoveryToken: recoveryToken)
                guard self.shouldContinueRecovery(recoveryToken, at: "after cleanup") else { return }

                guard self.shouldContinueRecovery(recoveryToken, at: "before prepare") else { return }
                try self.prepare(preservingRecoveryToken: recoveryToken)
                guard self.shouldContinueRecovery(recoveryToken, at: "after prepare") else { return }

                guard self.shouldContinueRecovery(recoveryToken, at: "before start") else { return }
                try self.start(bufferCallback: callback, recoveryToken: recoveryToken)
                guard self.shouldContinueRecovery(recoveryToken, at: "after start") else { return }
                // start() only proves ScreenCaptureKit accepted the restart.
                // Wait for a real buffer before refunding the attempt budget
                // or publishing healthy. Longer than the mic path's 2 s gate:
                // a post-wake SCK restart can take several seconds to deliver
                // its first frame, and giving up early costs the rest of the
                // meeting's system audio.
                guard self.waitForRestartedBuffer(timeout: 5.0) else {
                    AppLogger.audioSystem.error("SCKAudioCapture: stream recovery start succeeded but no audio buffer arrived")
                    self.publishErrorMessage("System audio failed - ScreenCaptureKit could not restart audio capture.")
                    // The restarted stream is still running. Once this
                    // attempt is abandoned the write hold comes down, so a
                    // buffer that arrives late would be written with no pad
                    // for the outage and shift the rest of the system track
                    // against the microphone. Stop it before giving up.
                    self.stopSync(preservingRecoveryToken: recoveryToken)
                    return
                }
                guard self.shouldContinueRecovery(recoveryToken, at: "after first buffer") else { return }
                AppLogger.audioSystem.info("SCKAudioCapture: stream recovery succeeded")
                self.resetRecoveryAttemptsAfterSuccess()
                if let identity = self.currentStreamState().stream?.captureIdentity,
                   let generation = self.currentStreamState().generation {
                    self.publishHealthyIfCurrent(identity: identity, generation: generation)
                }
                let gapDuration = max(0, CACurrentMediaTime() - lastKnownBufferTimeAtFailure)
                recoverySucceeded = true
                self.recoveryEventSubject.send(.gap(duration: gapDuration))
            } catch is SCKRecoveryCancelledError {
                AppLogger.audioSystem.info("SCKAudioCapture: recovery stopped after cancellation")
            } catch {
                guard self.shouldContinueRecovery(recoveryToken, at: "failure") else { return }
                AppLogger.audioSystem.error("SCKAudioCapture: stream recovery failed", [
                    "error": error.localizedDescription
                ])
                self.publishErrorMessage("System audio failed - ScreenCaptureKit could not restart audio capture.")
            }
        }
    }
}
