import Foundation
@preconcurrency import AVFoundation
import CoreAudio
import QuartzCore

// MARK: - Recovery Tuning

/// Single named surface for the mic-path and system-audio-path bounded
/// recovery tuning constants. Before this type existed the two paths carried
/// separate, unlinked numbers — `Audio.maxRecoveryAttempts` /
/// `Audio.recoveryCooldown` here, `SCKAudioCapture.maxRecoveryAttempts` /
/// `SCKAudioCapture.bufferStallTimeoutSeconds` in `SCKAudioCapture.swift` —
/// with nothing showing they tune the same kind of problem. Consolidating
/// them here makes the relationship (and the current asymmetry) visible.
///
/// Every value below is unchanged from before this type existed — this is a
/// mechanism unification, not a tuning change. `SystemAudio.maxRecoveryAttempts`
/// staying at 1 instead of matching `Mic.maxRecoveryAttempts` is a deliberate
/// gap: SCK's bounded recovery restarts an entire ScreenCaptureKit stream
/// (heavier than reinstalling a mic tap), so raising it is a follow-up
/// decision, not part of this parity pass.
enum AudioRecoveryTuning {
    /// Tuning for `Audio`'s mic-path watchdog + `recoverFromDeviceChange`.
    enum Mic {
        /// Matches the watchdog's give-up threshold in `Audio.startWatchdog()`.
        static let maxRecoveryAttempts = 5
        /// Matches the watchdog's `timeSinceLastBuffer` stall check in `Audio.startWatchdog()`.
        static let stallTimeoutSeconds: TimeInterval = 3.0
        /// Matches `Audio.recoveryCooldown` — minimum seconds between recovery attempts.
        static let recoveryCooldownSeconds: TimeInterval = 5.0
    }

    /// Tuning for `SCKAudioCapture`'s bounded mid-recording stream recovery.
    enum SystemAudio {
        /// Matches `SCKAudioCapture.maxRecoveryAttempts`.
        static let maxRecoveryAttempts = 1
        /// Matches `SCKAudioCapture.bufferStallTimeoutSeconds` — how long the
        /// buffer watchdog waits with no buffers before treating the stream
        /// as stalled.
        static let stallTimeoutSeconds: CFTimeInterval = 5
    }
}

// MARK: - Device Recovery & Watchdog

/// Why the mic capture engine is being restarted mid-recording. A consented
/// processing change (issue #500 mic boost) reuses the device-recovery
/// machinery but must not masquerade as a device failure in health metadata.
enum MicCaptureRestartReason {
    case deviceChange
    case processingChange
}

/// Lock-backed ownership for the shared microphone writer. Stop detaches and
/// closes the exact-generation writer from a barrier on its serial file queue,
/// after every already-admitted buffer has had a chance to write.
final class MicWriterOwnership<Writer: AnyObject>: @unchecked Sendable {
    struct SessionInstallResult {
        let didInstall: Bool
        let displacedWriter: Writer?
    }

    private let lock = NSLock()
    private var storedWriter: Writer?
    private var storedGeneration: UInt64?
    private var invalidatedThroughGeneration: UInt64?

    var writer: Writer? {
        lock.lock()
        defer { lock.unlock() }
        return storedWriter
    }

    var generation: UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return storedGeneration
    }

    @discardableResult
    func installSessionWriter(
        _ writer: Writer,
        generation: UInt64
    ) -> SessionInstallResult {
        lock.lock()
        defer { lock.unlock() }
        if let invalidatedThroughGeneration,
           generation <= invalidatedThroughGeneration {
            return SessionInstallResult(didInstall: false, displacedWriter: nil)
        }
        if let storedGeneration, storedGeneration > generation {
            return SessionInstallResult(didInstall: false, displacedWriter: nil)
        }
        let displacedWriter = storedWriter
        storedWriter = writer
        storedGeneration = generation
        return SessionInstallResult(
            didInstall: true,
            displacedWriter: displacedWriter
        )
    }

    func takeWriterOwned(by generation: UInt64) -> Writer? {
        lock.lock()
        defer { lock.unlock() }
        guard storedGeneration == generation, let writer = storedWriter else { return nil }
        storedWriter = nil
        return writer
    }

    func writerOwned(by generation: UInt64) -> Writer? {
        lock.lock()
        defer { lock.unlock() }
        guard storedGeneration == generation else { return nil }
        return storedWriter
    }

    func installRecoveryWriter(_ writer: Writer, generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let invalidatedThroughGeneration,
           generation <= invalidatedThroughGeneration {
            return false
        }
        guard storedGeneration == generation, storedWriter == nil else { return false }
        storedWriter = writer
        return true
    }

    func takeWriterOwned(
        by captureGeneration: UInt64,
        invalidatingFor stopGeneration: UInt64
    ) -> Writer? {
        lock.lock()
        defer { lock.unlock() }
        if let invalidatedThroughGeneration {
            self.invalidatedThroughGeneration = max(
                invalidatedThroughGeneration,
                stopGeneration
            )
        } else {
            self.invalidatedThroughGeneration = stopGeneration
        }
        guard storedGeneration == captureGeneration else { return nil }
        let writer = storedWriter
        storedWriter = nil
        storedGeneration = stopGeneration
        return writer
    }

    @discardableResult
    func removeIfOwned(_ writer: Writer, generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard storedGeneration == generation, storedWriter === writer else { return false }
        storedWriter = nil
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

enum MicDeviceSwitchCountingPolicy {
    static func counts(reason: MicCaptureRestartReason, afterSystemWake: Bool) -> Bool {
        reason == .deviceChange && !afterSystemWake
    }
}

/// `installTap` raises an Objective-C exception, which Swift cannot catch,
/// when its format no longer matches the input node. AirPods can switch from
/// 48 kHz to their 24 kHz call profile between graph validation and the tap
/// install, because opening their mic is what triggers the switch.
enum MicTapFormatPolicy {
    static func stillMatches(expected: AVAudioFormat, current: AVAudioFormat) -> Bool {
        expected.sampleRate == current.sampleRate
            && expected.channelCount == current.channelCount
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

enum MicWakeRecoveryPolicy {
    /// How long the wake handler waits for a mic buffer before deciding the
    /// mic needs a restart. A flowing tap delivers every ~0.1 s.
    static let flowingCheckSeconds: TimeInterval = 0.5
}

enum MicWatchdogSessionPolicy {
    /// Silence between will-sleep and the wake recovery is the Mac going to
    /// sleep, not a lost microphone, so it neither triggers recovery nor
    /// counts toward the give-up limit.
    static func shouldRun(
        watchdogGeneration: UInt64,
        currentGeneration: UInt64,
        isRecording: Bool,
        isRecovering: Bool,
        isSystemSleepPending: Bool = false
    ) -> Bool {
        watchdogGeneration == currentGeneration
            && isRecording
            && !isRecovering
            && !isSystemSleepPending
    }
}
/// Extension handling mic device recovery, watchdog timer, and sleep/wake resilience.
/// Runs on background threads — NOT @MainActor.
extension Audio {

    /// Call under the graph lock right before `installTap`. Turns a route
    /// change that would crash the app into a normal failed attempt.
    func ensureMicTapFormatStillMatches(
        _ expected: AVAudioFormat,
        on inputNode: AVAudioInputNode,
        voiceProcessingEnabled: Bool,
        operation: String
    ) throws {
        let current = recordingFormat(
            for: inputNode,
            voiceProcessingEnabled: voiceProcessingEnabled
        )
        guard MicTapFormatPolicy.stillMatches(expected: expected, current: current) else {
            AppLogger.audioMic.warning("Microphone format changed before tap install", [
                "operation": operation,
                "expectedRate": "\(expected.sampleRate)",
                "currentRate": "\(current.sampleRate)",
                "expectedChannels": "\(expected.channelCount)",
                "currentChannels": "\(current.channelCount)"
            ])
            throw NSError(
                domain: "Audio",
                code: 5,
                userInfo: [
                    NSLocalizedDescriptionKey: "The microphone route did not become ready. Check your input device and try again."
                ]
            )
        }
    }

    /// Rebuilds a validated but not yet started meeting graph when the input
    /// format moved underneath it. Opening the AirPods mic is what flips them
    /// to their call profile, so the first graph usually sees 48 kHz and the
    /// hardware is at 24 kHz a moment later. Call before the mic file is
    /// created, since the file is sized for the graph's rate.
    func settleMeetingInputGraphFormat(
        _ graph: PreparedMeetingInputGraph,
        operation: String,
        sessionGeneration: UInt64
    ) throws -> PreparedMeetingInputGraph {
        var graph = graph
        for rebuild in 1...2 {
            guard sessionGeneration == recordingSessionGeneration else {
                throw AudioCaptureStaleSessionError()
            }
            let current = withAudioGraphLock {
                recordingFormat(
                    for: graph.inputNode,
                    voiceProcessingEnabled: graph.voiceProcessingEnabled
                )
            }
            if MicTapFormatPolicy.stillMatches(expected: graph.recordingFormat, current: current) {
                return graph
            }
            AppLogger.audioMic.warning("Microphone format changed after graph setup; rebuilding", [
                "operation": operation,
                "rebuild": "\(rebuild)",
                "expectedRate": "\(graph.recordingFormat.sampleRate)",
                "currentRate": "\(current.sampleRate)",
                "expectedChannels": "\(graph.recordingFormat.channelCount)",
                "currentChannels": "\(current.channelCount)"
            ])
            incrementMicFormatRebuildCount()
            let staleGraph = graph
            withAudioGraphLock {
                discardUnstartedInputGraph(
                    engine: staleGraph.engine,
                    inputNode: staleGraph.inputNode,
                    operation: "\(operation)_discard_route_changed"
                )
            }
            // Let CoreAudio finish the profile switch before reading it again.
            Thread.sleep(forTimeInterval: 0.3)
            graph = try makeReadyMeetingInputGraph(
                operation: "\(operation)_route_changed",
                resetMeetingSelectionBeforeRetry: false,
                sessionGeneration: sessionGeneration
            )
        }
        return graph
    }

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
                      isRecovering: self.isMicRecovering,
                      isSystemSleepPending: self.isSystemSleepPending(for: watchdogGeneration)
                  ) else { return }

            // Also covers a call-app launch while another recovery was already
            // rebuilding the graph. A flowing mic is not proof Zoom can hear it.
            self.reconcileMicrophoneSharing()

            let timeSinceLastBuffer = CACurrentMediaTime() - self.lastBufferTime

            if timeSinceLastBuffer > AudioRecoveryTuning.Mic.stallTimeoutSeconds {
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
                        let expectedStopGeneration = self.predictedNextRecordingSessionGeneration()
                        self.stop()
                        guard self.recordingSessionGeneration == expectedStopGeneration else { return }
                        // Re-apply error after stop() clears it
                        self.error = savedError
                    }
                    return
                }

                // Audio stopped → device likely changed
                AppLogger.audioMic.warning("Audio device disconnected or changed, switching to default")
                // Dispatch to background — recovery uses Thread.sleep for HAL settle time
                DispatchQueue.global(qos: .userInitiated).async {
                    self.recoverFromDeviceChange(sessionGeneration: watchdogGeneration)
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
        reason: MicCaptureRestartReason = .deviceChange,
        afterSystemWake: Bool = false
    ) {
        // Ignore recovery work that belonged to an older recording session.
        guard sessionGeneration == recordingSessionGeneration else {
            AppLogger.audioMic.info("Skipping stale recovery request", [
                "expectedSession": "\(sessionGeneration)",
                "currentSession": "\(recordingSessionGeneration)"
            ])
            return
        }

        // A device-change recovery started as the Mac falls asleep cannot
        // get a frame back and would stop the recording. The wake handler
        // clears the mark and runs this recovery once the HAL has settled.
        if reason == .deviceChange, isSystemSleepPending(for: sessionGeneration) {
            AppLogger.audioMic.info("Deferring mic recovery until the system wakes")
            return
        }

        // The pinned recorder restarts itself on its own device and pads the
        // hole. It never rebuilds an engine graph, which would open the
        // default input first.
        if let pinnedCapture = withAudioGraphLock({ pinnedMicrophoneCapture }) {
            recoverPinnedMeetingMicrophone(
                pinnedCapture,
                sessionGeneration: sessionGeneration,
                reason: reason
            )
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
        // restarts and the restart after the Mac wakes stay out of
        // deviceSwitchCount so health metadata and capture_quality aren't
        // polluted (the sleep itself is recorded as a gap); recoveryAttemptCount stays
        // unconditional — it's the watchdog give-up safety counter and
        // resets on success below.
        let switchStart = Date()
        let lastMicBufferTime = lastBufferTime
        if MicDeviceSwitchCountingPolicy.counts(reason: reason, afterSystemWake: afterSystemWake) {
            // Atomic read-modify-write: the SCK-path recovery-event
            // subscription can increment this same counter concurrently on
            // main (see `Audio.incrementDeviceSwitchCount()`), so a plain
            // `deviceSwitchCount += 1` here (get + separately-locked set)
            // could race and drop an increment from either side.
            incrementDeviceSwitchCount()
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
        // Same approach the system-audio backend uses for its own recovery
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
            // Opening a Bluetooth mic after a wake or reconnect can flip it to
            // its call profile, same as at start. Rebuild on the settled
            // route before the recovery segment is sized for the old rate.
            preparedGraph = try settleMeetingInputGraphFormat(
                makeReadyMeetingInputGraph(
                    operation: "device_recovery",
                    resetMeetingSelectionBeforeRetry: MicRecoveryRetryPolicy
                        .shouldResetMeetingSelectionBeforeRetry(for: reason),
                    sessionGeneration: sessionGeneration,
                    routeWasUnstable: bluetoothInputWasSelected
                ),
                operation: "device_recovery",
                sessionGeneration: sessionGeneration
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

        let micWriteContext: MicPCMWriteContext
        do {
            let monoFormat = try AudioRecordingFormatPolicy.makeMonoOutputFormat(
                sampleRate: recordingSnapshot.sampleRate
            )
            self.monoOutputFormat = monoFormat
            micWriteContext = MicPCMWriteContext(
                generation: sessionGeneration,
                monoFormat: monoFormat,
                inputChannelCount: recordingSnapshot.channelCount
            )

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
                try ensureMicTapFormatStillMatches(
                    recordingFormat,
                    on: newInputNode,
                    voiceProcessingEnabled: preparedGraph.voiceProcessingEnabled,
                    operation: "device_recovery"
                )
                newInputNode.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat) { [weak self] buffer, _ in
                    self?.handleMicBuffer(buffer, writeContext: micWriteContext)
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

    func waitForMicBuffer(
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
