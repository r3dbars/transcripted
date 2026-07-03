import Foundation
@preconcurrency import AVFoundation
import CoreAudio
import QuartzCore

// MARK: - Device Recovery & Watchdog

/// Why the mic capture engine is being restarted mid-recording. A consented
/// processing change (issue #500 mic boost) reuses the device-recovery
/// machinery but must not masquerade as a device failure in health metadata.
enum MicCaptureRestartReason {
    case deviceChange
    case processingChange
}

/// Extension handling mic device recovery, watchdog timer, and sleep/wake resilience.
/// Runs on background threads — NOT @MainActor.
extension Audio {

    // MARK: - Watchdog Timer

    func startWatchdog() {
        lastBufferTime = CACurrentMediaTime()
        watchdogTimer?.invalidate()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self, self.isRecording else { return }

            let timeSinceLastBuffer = CACurrentMediaTime() - self.lastBufferTime

            if timeSinceLastBuffer > 3.0 {
                // Enforce cooldown — don't attempt recovery more often than every 5s
                if let lastRecovery = self.lastRecoveryTime,
                   Date().timeIntervalSince(lastRecovery) < self.recoveryCooldown {
                    return  // Too soon, skip this tick
                }

                // Give up after too many failed recoveries
                if self.recoveryAttemptCount >= self.maxRecoveryAttempts {
                    AppLogger.audioMic.error("Max recovery attempts reached, stopping recording", [
                        "attempts": "\(self.recoveryAttemptCount)"
                    ])
                    let savedError = "Audio device unavailable \u{2014} recording stopped after \(self.recoveryAttemptCount) recovery attempts. Reconnect your microphone and try again."
                    DispatchQueue.main.async {
                        self.stop()
                        // Re-apply error after stop() clears it
                        self.error = savedError
                    }
                    return
                }

                // Audio stopped → device likely changed
                AppLogger.audioMic.warning("Audio device disconnected or changed, switching to default")
                let sessionGeneration = self.recordingSessionGeneration
                // Dispatch to background — recovery uses Thread.sleep for HAL settle time
                DispatchQueue.global(qos: .userInitiated).async {
                    self.recoverFromDeviceChange(sessionGeneration: sessionGeneration)
                }
            }
        }
    }

    func stopWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
    }

    // MARK: - Device Recovery

    func recoverFromDeviceChange(
        sessionGeneration: UInt64,
        reason: MicCaptureRestartReason = .deviceChange
    ) {
        // Ignore recovery work that belonged to an older recording session.
        guard sessionGeneration == recordingSessionGeneration else {
            AppLogger.audioMic.info("Skipping stale recovery request", [
                "expectedSession": "\(sessionGeneration)",
                "currentSession": "\(recordingSessionGeneration)"
            ])
            return
        }

        // CRITICAL: Prevent concurrent recovery attempts
        // AVAudioEngine notifications can fire multiple times during rapid device changes
        guard !isMicRecovering else {
            AppLogger.audioMic.warning("Recovery already in progress, skipping duplicate request")
            return
        }
        isMicRecovering = true
        defer { isMicRecovering = false }
        lastRecoveryTime = Date()

        guard let engine = engine, let inputNode = inputNode else { return }

        // Track device switch for health monitoring. Deliberate processing
        // restarts stay out of deviceSwitchCount so health metadata and
        // capture_quality aren't polluted; recoveryAttemptCount stays
        // unconditional — it's the watchdog give-up safety counter and
        // resets on success below.
        let switchStart = Date()
        let lastMicBufferTime = lastBufferTime
        if reason == .deviceChange {
            deviceSwitchCount += 1
        }
        recoveryAttemptCount += 1
        AppLogger.audioMic.debug("Recovering from device change", ["switchNumber": "\(deviceSwitchCount)", "maxAttempts": "\(maxRecoveryAttempts)"])

        // Stop engine (but keep recording flag true), then reset to system
        // default. Keep graph mutation serialized with stop/start teardown so
        // a user stop during device recovery cannot race CoreAudio format
        // reads or tap replacement.
        var didResetGraph = false
        withAudioGraphLock {
            guard sessionGeneration == recordingSessionGeneration else {
                AppLogger.audioMic.info("Skipping stale recovery before graph reset", [
                    "expectedSession": "\(sessionGeneration)",
                    "currentSession": "\(recordingSessionGeneration)"
                ])
                return
            }
            tearDownInputTapSafely(
                engine: engine,
                inputNode: inputNode,
                operation: "device_recovery_reset"
            )
            engine.reset()
            // engine.reset() clears VPIO state on the input node; require re-arm.
            voiceProcessingEnabled = false
            self.inputNode = engine.inputNode
            didResetGraph = true
        }
        guard didResetGraph else {
            return
        }

        // HAL settle time - wait for audio hardware to stabilize after device change
        // Same approach as SystemAudioCapture recovery
        Thread.sleep(forTimeInterval: 0.1)  // 100ms

        // A new recording session may have started while the HAL was settling.
        guard sessionGeneration == recordingSessionGeneration else {
            AppLogger.audioMic.info("Skipping stale recovery after HAL settle", [
                "expectedSession": "\(sessionGeneration)",
                "currentSession": "\(recordingSessionGeneration)"
            ])
            return
        }

        // Get new device format
        guard let newInputNode = self.inputNode else {
            AppLogger.audioMic.error("Failed to get input node after reset")
            return
        }

        // Re-enable VPIO after the HAL settles so setVoiceProcessingEnabled
        // queries a stable device. Skips silently if VPIO can't engage on the
        // new device, in which case recordingFormat(for:) falls back to the
        // hardware format. Then refresh software AGC from the user's selected
        // mode so raw/off stays raw after device recovery.
        var recordingFormat = withAudioGraphLock {
            applyPreferredMeetingInputDevice(to: newInputNode, operation: "device_recovery")
            armVoiceProcessing(on: newInputNode)
            refreshRealtimeAGCForCurrentProcessingMode(resetExisting: true)

            // Read the format the tap will actually deliver (VPIO-aware when
            // armVoiceProcessing succeeded above, hardware format otherwise).
            return self.recordingFormat(for: newInputNode)
        }
        var recordingSnapshot = AudioRecordingFormatPolicy.snapshot(recordingFormat)
        if recordingSnapshot == nil {
            AppLogger.audioMic.warning("Recovery format invalid after first read, retrying", [
                "sampleRate": "\(recordingFormat.sampleRate)",
                "channels": "\(recordingFormat.channelCount)"
            ])
            Thread.sleep(forTimeInterval: 0.3)
            recordingFormat = withAudioGraphLock {
                self.recordingFormat(for: newInputNode)
            }
            recordingSnapshot = AudioRecordingFormatPolicy.snapshot(recordingFormat)
        }
        guard let recordingSnapshot else {
            AppLogger.audioMic.error("Recovery format remained invalid", [
                "sampleRate": "\(recordingFormat.sampleRate)",
                "channels": "\(recordingFormat.channelCount)"
            ])
            return
        }
        let oldChannelCount = self.inputChannelCount
        AppLogger.audioMic.info("Switched to default device", ["sampleRate": "\(recordingSnapshot.sampleRate)", "channels": "\(recordingSnapshot.channelCount)"])

        // ALWAYS update channel count for proper downmix handling
        // This was a bug: if only channel count changed (not sample rate), downmix wouldn't work
        self.inputChannelCount = recordingSnapshot.channelCount
        if recordingSnapshot.channelCount > 1 && oldChannelCount != recordingSnapshot.channelCount {
            AppLogger.audioMic.debug("Recovery: will manually downmix to mono", ["channels": "\(recordingSnapshot.channelCount)"])
        }

        let channelCountChanged = oldChannelCount != recordingSnapshot.channelCount
        var recoverySegmentURL: URL?
        var shouldKeepRecoverySegment = false
        defer {
            if let recoverySegmentURL, !shouldKeepRecoverySegment {
                micAudioFileQueue.sync {
                    if micAudioFile?.url == recoverySegmentURL {
                        micAudioFile?.close()
                        micAudioFile = nil
                    }
                }
                try? FileManager.default.removeItem(at: recoverySegmentURL)
            }
        }

        if channelCountChanged {
            AppLogger.audioMic.info("Input channel count changed during recovery", [
                "oldChannels": "\(oldChannelCount)",
                "newChannels": "\(recordingSnapshot.channelCount)"
            ])
        }

        AppLogger.audioMic.warning("Closing current mic file and creating recovery segment")
        // Close explicitly so the retiring segment's WAV header is finalized
        // before the merger can ever read it. Even same-rate device switches
        // need a new segment so the missing-buffer interval can be padded.
        micAudioFileQueue.sync {
            micAudioFile?.close()
            micAudioFile = nil
        }

        let captureDir = self.paths.audioCaptures
        try? FileManager.default.createDirectory(at: captureDir, withIntermediateDirectories: true)
        let timestamp = DateFormattingHelper.formatFilenamePrecise(Date())
        let fileURL = captureDir.appendingPathComponent("meeting_\(timestamp)_mic_recovery.wav")
        recoverySegmentURL = fileURL

        do {
            let monoFormat = try AudioRecordingFormatPolicy.makeMonoOutputFormat(
                sampleRate: recordingSnapshot.sampleRate
            )
            self.monoOutputFormat = monoFormat

            let newFile = try AVAudioFile(
                forWriting: fileURL,
                settings: monoFormat.settings,
                commonFormat: monoFormat.commonFormat,
                interleaved: monoFormat.isInterleaved
            )
            FileManager.default.restrictToOwnerOnly(atPath: fileURL.path)
            micAudioFileQueue.sync { micAudioFile = newFile }
            AppLogger.audioMic.info("Created recovery audio file", ["file": fileURL.lastPathComponent])
        } catch {
            AppLogger.audioMic.error("Failed to create recovery audio file", ["error": error.localizedDescription])
            return
        }

        guard sessionGeneration == recordingSessionGeneration else {
            AppLogger.audioMic.info("Skipping stale recovery before engine restart", [
                "expectedSession": "\(sessionGeneration)",
                "currentSession": "\(recordingSessionGeneration)"
            ])
            return
        }

        // Restart engine
        do {
            try withAudioGraphLock {
                guard sessionGeneration == recordingSessionGeneration else {
                    throw AudioCaptureStaleSessionError()
                }
                // Reinstall tap using shared buffer handler
                tearDownInputTapSafely(
                    engine: engine,
                    inputNode: newInputNode,
                    operation: "device_recovery_restart"
                )
                newInputNode.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat) { [weak self] buffer, _ in
                    self?.handleMicBuffer(buffer)
                }
                do {
                    engine.prepare()
                    try engine.start()
                } catch {
                    tearDownInputTapSafely(
                        engine: engine,
                        inputNode: newInputNode,
                        operation: "device_recovery_restart_failed"
                    )
                    throw error
                }
            }
            lastBufferTime = CACurrentMediaTime() // Reset watchdog

            let transientMessage = reason == .processingChange ? "Mic boost enabled" : "Switched to default mic"
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.error = transientMessage

                // Clear error after 3 seconds (use weak self to prevent retain)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                    guard let self = self else { return }
                    if self.error == transientMessage {
                        self.error = nil
                    }
                }
            }

            // Record the true missing-buffer interval. The watchdog only
            // invokes recovery after buffers have already been absent for a
            // few seconds, so measuring from recovery start undercounts the
            // timeline gap and desyncs mic/system audio after device switches.
            let monotonicGapDuration = CACurrentMediaTime() - lastMicBufferTime
            let wallClockGapDuration = Date().timeIntervalSince(switchStart)
            let gapDuration = max(0, max(monotonicGapDuration, wallClockGapDuration))
            let gap = AudioGap(
                start: Date(timeIntervalSinceNow: -gapDuration),
                duration: gapDuration,
                reason: reason == .processingChange ? "Mic processing change" : "Device switch"
            )
            appendRecordingGap(gap)
            if let recoverySegmentURL {
                appendMicSegment(MicRecordingSegment(url: recoverySegmentURL, gapBeforeDuration: gap.duration))
                shouldKeepRecoverySegment = true
            }
            recoveryAttemptCount = 0
            AppLogger.audioMic.info("Device recovery complete, recording continues", ["gap": gap.description])
        } catch {
            if error is AudioCaptureStaleSessionError {
                AppLogger.audioMic.info("Skipping stale recovery restart", [
                    "expectedSession": "\(sessionGeneration)",
                    "currentSession": "\(recordingSessionGeneration)"
                ])
                return
            }
            AppLogger.audioMic.error("Failed to restart engine", ["error": error.localizedDescription])
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.error = "Microphone recovery failed. Reconnect your audio device or try quitting and reopening Transcripted."
                self.stop()
            }
        }
    }
}
