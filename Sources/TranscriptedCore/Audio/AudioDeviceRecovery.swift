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

    enum RecoveryRetirement {
        case retired(Writer)
        /// Still this recording's, but an earlier failed recovery already
        /// closed its segment and had nothing to replace it with.
        case alreadyRetired
        case notOwned
    }

    /// Take the writer a device recovery is about to replace. Unlike
    /// `takeWriterOwned(by:)`, tells "a failed attempt left no writer" apart
    /// from "ownership moved to another recording", so the next attempt can
    /// still install its recovery segment.
    func retireWriterForRecovery(by generation: UInt64) -> RecoveryRetirement {
        lock.lock()
        defer { lock.unlock() }
        guard storedGeneration == generation else { return .notOwned }
        guard let writer = storedWriter else { return .alreadyRetired }
        storedWriter = nil
        return .retired(writer)
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

/// When a device-change recovery should try the built-in mic before the
/// pinned one. `recoveryAttemptNumber` counts attempts since the last
/// successful recovery (it resets on success), so anything above 1 means the
/// previous attempt already failed on the pinned mic. A mic that has not
/// delivered a single frame this recording never worked at all, so retrying
/// it first would only burn the meeting-start deadline.
enum MicRecoveryInputFallbackPolicy {
    static func shouldTryBuiltInFirst(
        reason: MicCaptureRestartReason,
        recoveryAttemptNumber: Int,
        micHasDeliveredAudio: Bool
    ) -> Bool {
        guard reason == .deviceChange else { return false }
        return recoveryAttemptNumber > 1 || !micHasDeliveredAudio
    }
}

/// What to do after the meeting mic engine posts
/// `AVAudioEngineConfigurationChange`. Switching the Mac's output or default
/// device stops the engine. Before this observer existed only the watchdog
/// noticed, after its 3s stall check on a 2s timer, so each switch lost up to
/// ~5s of the user's voice.
enum MicEngineConfigurationChangePolicy {
    enum Decision: Equatable {
        /// Not the live meeting graph, or the recording is over or asleep.
        case ignore
        /// The engine kept delivering audio through the change.
        case stillFlowing
        /// Another recovery owns the graph right now; look again shortly.
        case waitForRecovery
        /// A recovery just ran. Leave a flapping route to the watchdog's
        /// slower cooldown instead of rebuilding the graph back to back.
        case leaveToWatchdog
        case recover
    }

    /// Let CoreAudio finish the route change before checking for frames.
    static let settleSeconds: TimeInterval = 0.25
    static let recoveryWaitSeconds: TimeInterval = 0.5
    static let maxRecoveryWaits = 6
    static let minimumSecondsBetweenRecoveries: TimeInterval = 1.0

    static func decision(
        sessionIsCurrent: Bool,
        isRecording: Bool,
        isSystemSleeping: Bool,
        isRecovering: Bool,
        changedEngineIsPublishedGraph: Bool,
        deliveredNewBuffer: Bool,
        secondsSinceLastRecovery: TimeInterval?
    ) -> Decision {
        guard sessionIsCurrent, isRecording, !isSystemSleeping else { return .ignore }
        guard !isRecovering else { return .waitForRecovery }
        guard changedEngineIsPublishedGraph else { return .ignore }
        guard !deliveredNewBuffer else { return .stillFlowing }
        if let secondsSinceLastRecovery,
           secondsSinceLastRecovery < minimumSecondsBetweenRecoveries {
            return .leaveToWatchdog
        }
        return .recover
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

        // A failed earlier attempt can leave no published graph. Rebuild from
        // scratch then; returning here would skip the attempt count, so the
        // watchdog would never give up and the meeting would record silence.
        let currentEngine = engine
        let currentInputNode = inputNode

        // Track device switch for health monitoring. Deliberate processing
        // restarts stay out of deviceSwitchCount so health metadata and
        // capture_quality aren't polluted; recoveryAttemptCount stays
        // unconditional — it's the watchdog give-up safety counter and
        // resets on success below.
        let switchStart = Date()
        let lastMicBufferTime = lastBufferTime
        if reason == .deviceChange {
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
            if let currentEngine {
                if let currentInputNode {
                    tearDownInputTapSafely(
                        engine: currentEngine,
                        inputNode: currentInputNode,
                        operation: "device_recovery_reset"
                    )
                    disarmVoiceProcessing(
                        on: currentInputNode,
                        reason: "device_recovery_replace_graph"
                    )
                }
                currentEngine.reset()
            }
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

        // The pinned mic already failed once in this streak, or never
        // delivered a frame at all. Try the built-in mic first this time.
        if MicRecoveryInputFallbackPolicy.shouldTryBuiltInFirst(
            reason: reason,
            recoveryAttemptNumber: recoveryAttemptCount,
            micHasDeliveredAudio: micBufferCount > 0
        ) {
            pinBuiltInMeetingInputFallback(operation: "device_recovery")
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
            if error is AudioCaptureStaleSessionError { return }
            AppLogger.audioMic.error("Failed to prepare microphone recovery graph", [
                "error": error.localizedDescription
            ])
            logMicRecoveryWillRetry(stage: "prepare_graph")
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
        switch micAudioFileQueue.sync(execute: {
            micAudioFileOwnership.retireWriterForRecovery(by: sessionGeneration)
        }) {
        case .retired(let retiringWriter):
            retiringWriter.close()
        case .alreadyRetired:
            // An earlier attempt closed the last segment and then failed.
            // Its gap is still open; this attempt's segment pads all of it.
            AppLogger.audioMic.info("Previous mic recovery left no open segment; creating a new one")
        case .notOwned:
            AppLogger.audioMic.info("Skipping recovery because mic writer ownership changed", [
                "expectedSession": "\(sessionGeneration)",
                "currentSession": "\(recordingSessionGeneration)"
            ])
            return
        }

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
            // The recovery segment is discarded below, so a slow mic that
            // starts delivering now would only feed a nil writer while
            // looking healthy to the watchdog. Stop it; the retry rebuilds.
            withAudioGraphLock {
                guard sessionGeneration == recordingSessionGeneration else { return }
                tearDownInputTapSafely(
                    engine: engine,
                    inputNode: newInputNode,
                    operation: "device_recovery_no_audio"
                )
            }
            logMicRecoveryWillRetry(stage: "restart_engine")
        }
    }

    /// One failed recovery no longer ends the meeting: system audio keeps
    /// recording and the watchdog retries on its cooldown, trying the
    /// built-in mic first from the second attempt on. The watchdog still
    /// stops the recording with an error after `maxRecoveryAttempts` in a row.
    private func logMicRecoveryWillRetry(stage: String) {
        AppLogger.audioMic.warning("Microphone recovery attempt failed; recording continues and will retry", [
            "stage": stage,
            "attempt": "\(recoveryAttemptCount)",
            "maxAttempts": "\(maxRecoveryAttempts)"
        ])
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

// MARK: - Engine Configuration Change

extension Audio {

    func installMicEngineConfigurationChangeObserver() {
        guard micEngineConfigurationObserver == nil else { return }
        // object: nil because every recovery publishes a fresh engine. The
        // check below only acts on the live meeting graph, so dictation's own
        // engine and detached graphs that are still being built are ignored.
        micEngineConfigurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let changedEngine = notification.object as? AVAudioEngine else { return }
            self?.handleMicEngineConfigurationChange(changedEngine)
        }
    }

    /// Posted on an arbitrary thread, possibly while a graph build holds the
    /// graph lock. Snapshot lock-free state here and do the real check on a
    /// background queue after a short settle.
    func handleMicEngineConfigurationChange(_ changedEngine: AVAudioEngine) {
        scheduleMicEngineConfigurationCheck(
            changedEngine: changedEngine,
            sessionGeneration: recordingSessionGeneration,
            bufferCountAtChange: micBufferCount,
            delay: MicEngineConfigurationChangePolicy.settleSeconds,
            remainingRecoveryWaits: MicEngineConfigurationChangePolicy.maxRecoveryWaits
        )
    }

    private func scheduleMicEngineConfigurationCheck(
        changedEngine: AVAudioEngine,
        sessionGeneration: UInt64,
        bufferCountAtChange: Int,
        delay: TimeInterval,
        remainingRecoveryWaits: Int
    ) {
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + delay
        ) { [weak self, weak changedEngine] in
            guard let self else { return }
            let publishedEngine = self.withAudioGraphLock { self.engine }
            let decision = MicEngineConfigurationChangePolicy.decision(
                sessionIsCurrent: sessionGeneration == self.recordingSessionGeneration,
                isRecording: self.isRecording,
                isSystemSleeping: self.sleepTimestamp != nil,
                isRecovering: self.isMicRecovering,
                changedEngineIsPublishedGraph: changedEngine != nil
                    && changedEngine === publishedEngine,
                deliveredNewBuffer: MicRecoveryReadinessPolicy.deliveredNewBuffer(
                    before: bufferCountAtChange,
                    after: self.micBufferCount
                ),
                secondsSinceLastRecovery: self.lastRecoveryTime.map {
                    Date().timeIntervalSince($0)
                }
            )

            switch decision {
            case .ignore:
                return
            case .stillFlowing:
                AppLogger.audioMic.info("Microphone kept delivering audio through an audio route change")
            case .waitForRecovery:
                guard remainingRecoveryWaits > 0, let changedEngine else { return }
                self.scheduleMicEngineConfigurationCheck(
                    changedEngine: changedEngine,
                    sessionGeneration: sessionGeneration,
                    bufferCountAtChange: bufferCountAtChange,
                    delay: MicEngineConfigurationChangePolicy.recoveryWaitSeconds,
                    remainingRecoveryWaits: remainingRecoveryWaits - 1
                )
            case .leaveToWatchdog:
                AppLogger.audioMic.info("Audio route changed right after a mic recovery; leaving it to the watchdog")
            case .recover:
                AppLogger.audioMic.warning("Audio route change stopped the microphone; recovering now")
                self.recoverFromDeviceChange(sessionGeneration: sessionGeneration)
            }
        }
    }
}
