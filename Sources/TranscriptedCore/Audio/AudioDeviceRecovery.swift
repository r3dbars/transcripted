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

/// Queue-confined ownership for the shared microphone writer. Recovery is a
/// two-step retire/install operation, so the generation stays claimed while
/// the old file is closed and the replacement is created. A newer recording
/// can replace that claim, causing the stale recovery install to fail.
struct MicWriterOwnership<Writer: AnyObject> {
    private(set) var writer: Writer?
    private(set) var generation: UInt64?

    @discardableResult
    mutating func installSessionWriter(_ writer: Writer, generation: UInt64) -> Writer? {
        let displacedWriter = self.writer
        self.writer = writer
        self.generation = generation
        return displacedWriter
    }

    mutating func takeWriterOwned(by generation: UInt64) -> Writer? {
        guard self.generation == generation, let writer else { return nil }
        self.writer = nil
        return writer
    }

    mutating func installRecoveryWriter(_ writer: Writer, generation: UInt64) -> Bool {
        guard self.generation == generation, self.writer == nil else { return false }
        self.writer = writer
        return true
    }

    mutating func takeWriterAndInvalidate(for generation: UInt64) -> Writer? {
        let writer = self.writer
        self.writer = nil
        self.generation = generation
        return writer
    }

    @discardableResult
    mutating func removeIfOwned(_ writer: Writer, generation: UInt64) -> Bool {
        guard self.generation == generation, self.writer === writer else { return false }
        self.writer = nil
        return true
    }

}

enum MicRecoveryReadinessPolicy {
    static func deliveredNewBuffer(before: Int, after: Int) -> Bool {
        after > before
    }
}

enum MicRecoveryRetryPolicy {
    static func shouldResetMeetingSelectionBeforeRetry(
        for reason: MicCaptureRestartReason
    ) -> Bool {
        switch reason {
        case .deviceChange:
            return true
        case .processingChange:
            return false
        }
    }
}

enum MicWatchdogArmingPolicy {
    static func shouldArm(afterNonemptyBufferCount bufferCount: Int) -> Bool {
        bufferCount == 1
    }

    static func shouldArmAfterSuccessfulStart(watchdogIsArmed: Bool) -> Bool {
        !watchdogIsArmed
    }
}

enum MicWatchdogSessionPolicy {
    static func shouldRun(
        watchdogGeneration: UInt64,
        currentGeneration: UInt64,
        isRecording: Bool,
        isRecovering: Bool
    ) -> Bool {
        watchdogGeneration == currentGeneration && isRecording && !isRecovering
    }
}
/// Extension handling mic device recovery, watchdog timer, and sleep/wake resilience.
/// Runs on background threads — NOT @MainActor.
extension Audio {

    // MARK: - Watchdog Timer

    func startWatchdog() {
        lastBufferTime = CACurrentMediaTime()
        watchdogTimer?.invalidate()
        let watchdogGeneration = recordingSessionGeneration
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self,
                  MicWatchdogSessionPolicy.shouldRun(
                      watchdogGeneration: watchdogGeneration,
                      currentGeneration: self.recordingSessionGeneration,
                      isRecording: self.isRecording,
                      isRecovering: self.isMicRecovering
                  ) else { return }

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
                        guard self.recordingSessionGeneration == watchdogGeneration,
                              self.isRecording,
                              !self.isMicRecovering else { return }
                        self.stop()
                        guard self.recordingSessionGeneration == watchdogGeneration &+ 1 else { return }
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

        // CRITICAL: Prevent concurrent recovery attempts, including across a
        // fast stop/start. The owner remains set until the old background
        // recovery returns, so its defer cannot clear a newer session's state.
        guard beginMicRecovery(for: sessionGeneration) else {
            AppLogger.audioMic.warning("Recovery already in progress, skipping duplicate request")
            return
        }
        defer { endMicRecovery(for: sessionGeneration) }
        guard sessionGeneration == recordingSessionGeneration else { return }
        lastRecoveryTime = Date()

        guard let currentEngine = engine, let currentInputNode = inputNode else { return }

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
                engine: currentEngine,
                inputNode: currentInputNode,
                operation: "device_recovery_reset"
            )
            disarmVoiceProcessing(
                on: currentInputNode,
                reason: "device_recovery_replace_graph"
            )
            currentEngine.reset()
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

        // A rejected device bind can leave the node half-switched. Rebuild the
        // graph from scratch, retry once, and validate both device ID and
        // hardware format before installing another tap.
        let bluetoothInputWasSelected = reason == .deviceChange && meetingInputIsBluetooth()
        let preparedGraph: PreparedMeetingInputGraph
        do {
            preparedGraph = try makeReadyMeetingInputGraph(
                operation: "device_recovery",
                resetMeetingSelectionBeforeRetry: MicRecoveryRetryPolicy
                    .shouldResetMeetingSelectionBeforeRetry(for: reason),
                sessionGeneration: sessionGeneration,
                routeWasUnstable: bluetoothInputWasSelected
            )
        } catch {
            AppLogger.audioMic.error("Failed to prepare microphone recovery graph", [
                "error": error.localizedDescription
            ])
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.recordingSessionGeneration == sessionGeneration else { return }
                self.stop()
                self.error = "Microphone recovery failed. Reconnect your audio device or try quitting and reopening Transcripted."
            }
            return
        }
        let engine = preparedGraph.engine
        let newInputNode = preparedGraph.inputNode
        let recordingFormat = preparedGraph.recordingFormat
        let recordingSnapshot = preparedGraph.recordingSnapshot
        refreshRealtimeAGCForCurrentProcessingMode(resetExisting: true)
        let oldChannelCount = self.inputChannelCount
        AppLogger.audioMic.info("Rebuilt mic engine on pinned meeting input", ["sampleRate": "\(recordingSnapshot.sampleRate)", "channels": "\(recordingSnapshot.channelCount)"])

        // ALWAYS update channel count for proper downmix handling
        // This was a bug: if only channel count changed (not sample rate), downmix wouldn't work
        self.inputChannelCount = recordingSnapshot.channelCount
        if recordingSnapshot.channelCount > 1 && oldChannelCount != recordingSnapshot.channelCount {
            AppLogger.audioMic.debug("Recovery: will manually downmix to mono", ["channels": "\(recordingSnapshot.channelCount)"])
        }

        let channelCountChanged = oldChannelCount != recordingSnapshot.channelCount
        var recoverySegmentURL: URL?
        var recoveryWriter: AVAudioFile?
        var recoveryWriterWasInstalled = false
        var shouldKeepRecoverySegment = false
        defer {
            if let recoverySegmentURL, !shouldKeepRecoverySegment {
                if let recoveryWriter {
                    let shouldCloseWriter = !recoveryWriterWasInstalled || micAudioFileQueue.sync {
                        micAudioFileOwnership.removeIfOwned(
                            recoveryWriter,
                            generation: sessionGeneration
                        )
                    }
                    if shouldCloseWriter {
                        recoveryWriter.close()
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
        guard let retiringWriter = micAudioFileQueue.sync(execute: {
            micAudioFileOwnership.takeWriterOwned(by: sessionGeneration)
        }) else {
            AppLogger.audioMic.info("Skipping recovery because mic writer ownership changed", [
                "expectedSession": "\(sessionGeneration)",
                "currentSession": "\(recordingSessionGeneration)"
            ])
            return
        }
        retiringWriter.close()

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
            recoveryWriter = newFile
            let installed = micAudioFileQueue.sync {
                micAudioFileOwnership.installRecoveryWriter(
                    newFile,
                    generation: sessionGeneration
                )
            }
            guard installed else {
                AppLogger.audioMic.info("Skipping stale recovery writer replacement", [
                    "expectedSession": "\(sessionGeneration)",
                    "currentSession": "\(recordingSessionGeneration)"
                ])
                return
            }
            recoveryWriterWasInstalled = true
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

        // Restart engine. `engine.start()` only proves the graph was accepted;
        // it does not prove the selected microphone can deliver frames.
        let bufferCountBeforeRestart = micBufferCount
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
                    self?.handleMicBuffer(buffer, sessionGeneration: sessionGeneration)
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
            guard waitForMicBuffer(
                after: bufferCountBeforeRestart,
                sessionGeneration: sessionGeneration,
                timeout: 2.0
            ) else {
                throw NSError(
                    domain: "Audio",
                    code: 6,
                    userInfo: [NSLocalizedDescriptionKey: "The microphone restarted but did not deliver audio."]
                )
            }
            guard sessionGeneration == recordingSessionGeneration else {
                throw AudioCaptureStaleSessionError()
            }

            // Recovery notices are status, not errors. `Audio.error` is a
            // terminal bridge channel and must only carry real failures.
            AppLogger.audioMic.info(
                reason == .processingChange
                    ? "Microphone processing restart confirmed by audio frame"
                    : "Microphone device recovery confirmed by audio frame"
            )

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
            let finalized = finalizeMicRecoveryArtifacts(
                gap: gap,
                recoverySegment: recoverySegmentURL.map {
                    MicRecordingSegment(url: $0, gapBeforeDuration: gap.duration)
                },
                sessionGeneration: sessionGeneration
            )
            guard finalized else {
                throw AudioCaptureStaleSessionError()
            }
            if recoverySegmentURL != nil {
                shouldKeepRecoverySegment = true
            }
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
                guard let self,
                      self.recordingSessionGeneration == sessionGeneration else { return }
                self.stop()
                self.error = "Microphone recovery failed. Reconnect your audio device or try quitting and reopening Transcripted."
            }
        }
    }

    private func waitForMicBuffer(
        after previousBufferCount: Int,
        sessionGeneration: UInt64,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = CACurrentMediaTime() + timeout
        while CACurrentMediaTime() < deadline {
            guard sessionGeneration == recordingSessionGeneration else { return false }
            if MicRecoveryReadinessPolicy.deliveredNewBuffer(
                before: previousBufferCount,
                after: micBufferCount
            ) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard sessionGeneration == recordingSessionGeneration else { return false }
        return MicRecoveryReadinessPolicy.deliveredNewBuffer(
            before: previousBufferCount,
            after: micBufferCount
        )
    }
}
