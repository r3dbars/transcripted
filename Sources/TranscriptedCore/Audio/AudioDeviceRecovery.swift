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

    /// True while `generation` still owns the mic file, whether or not a
    /// failed recovery left it without an open writer.
    func recordingOwnsMicFile(_ generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let invalidatedThroughGeneration, generation <= invalidatedThroughGeneration { return false }
        return storedGeneration == generation
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
        micHasDeliveredAudio: Bool,
        inPlaceRestartJustFailed: Bool = false
    ) -> Bool {
        guard reason == .deviceChange else { return false }
        if !micHasDeliveredAudio { return true }
        // A failed in-place restart only proves the old graph went stale.
        // Give the pinned mic one fresh graph before moving off it.
        if inPlaceRestartJustFailed { return false }
        return recoveryAttemptNumber > 1
    }
}

/// When a device-change recovery can restart the engine it already has
/// instead of building a fresh one. A fresh `AVAudioEngine`'s input node
/// binds to the macOS default input before it is moved to the pinned mic.
/// With AirPods as the default, that brief open flips them into call mode
/// and garbles playback, so reuse the graph that is already bound to the
/// pinned mic whenever it is still there.
enum MicInPlaceRestartPolicy {
    static func canRestartInPlace(
        reason: MicCaptureRestartReason,
        freshGraphRequested: Bool,
        pinnedInputID: AudioDeviceID?,
        pinnedInputIsBluetooth: Bool,
        pinnedInputIsAlive: Bool,
        boundInputID: AudioDeviceID?,
        voiceProcessingEnabled: Bool
    ) -> Bool {
        // A processing change must re-arm voice processing on a new graph.
        guard reason == .deviceChange, !freshGraphRequested else { return false }
        // Bluetooth input keeps the fresh-graph path and its bounded
        // built-in stabilization after a real headset route failure.
        guard let pinnedInputID, !pinnedInputIsBluetooth, pinnedInputIsAlive else { return false }
        // VPIO wraps the node with a private device identity.
        guard !voiceProcessingEnabled else { return false }
        return boundInputID == pinnedInputID
    }

    /// The reused node's format must still match the device. A stale format
    /// would make `installTap` raise instead of failing the attempt.
    static func formatStillMatchesDevice(
        capturedSampleRate: Double,
        deviceNominalSampleRate: Double?
    ) -> Bool {
        guard let deviceNominalSampleRate,
              deviceNominalSampleRate.isFinite,
              deviceNominalSampleRate > 0,
              capturedSampleRate.isFinite else { return false }
        return abs(capturedSampleRate - deviceNominalSampleRate) <= 1
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
        /// A recovery just ended, or this streak used up its attempts.
        /// Leave it to the watchdog's slower cooldown and give-up instead of
        /// rebuilding the graph back to back.
        case leaveToWatchdog
        /// The engine is running, so the change did not stop it: it came
        /// from a graph that was still being built, or one already restarted.
        case engineStillRunning
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
        changedEngineIsRunning: Bool,
        deliveredNewBuffer: Bool,
        secondsSinceLastRecoveryEnded: TimeInterval?,
        recoveryAttemptsUsed: Int,
        maxRecoveryAttempts: Int
    ) -> Decision {
        guard sessionIsCurrent, isRecording, !isSystemSleeping else { return .ignore }
        guard !isRecovering else { return .waitForRecovery }
        guard changedEngineIsPublishedGraph else { return .ignore }
        // A running engine was not stopped by the change. A stopped one can
        // still hand over one queued tap block afterwards, so a new buffer
        // only means "flowing" while the engine runs.
        guard !changedEngineIsRunning else {
            return deliveredNewBuffer ? .stillFlowing : .engineStillRunning
        }
        // Measured from when the last recovery ended: a failed one takes
        // seconds, so its start is always long past by the next change.
        if let secondsSinceLastRecoveryEnded,
           secondsSinceLastRecoveryEnded < minimumSecondsBetweenRecoveries {
            return .leaveToWatchdog
        }
        guard recoveryAttemptsUsed < maxRecoveryAttempts else { return .leaveToWatchdog }
        return .recover
    }
}

/// Where a recovery segment's gap starts. Measured from the last frame the
/// recording kept, not the last frame seen: a failed attempt can take frames
/// (e.g. from a re-bound input) that are thrown away with its segment.
enum MicRecoveryGapAnchorPolicy {
    static func anchor(
        closedSegmentThisAttempt: Bool,
        storedAnchor: CFTimeInterval?,
        lastBufferTime: CFTimeInterval
    ) -> CFTimeInterval {
        guard !closedSegmentThisAttempt, let storedAnchor else { return lastBufferTime }
        return min(storedAnchor, lastBufferTime)
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
        afterSystemWake: Bool = false,
        freshGraphRequested: Bool = false
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

        // CRITICAL: Prevent concurrent recovery attempts, including across a
        // fast stop/start. The owner remains set until the old background
        // recovery returns, so its defer cannot clear a newer session's state.
        guard beginMicRecovery(for: sessionGeneration) else {
            AppLogger.audioMic.warning("Recovery already in progress, skipping duplicate request")
            return
        }
        defer {
            if sessionGeneration == recordingSessionGeneration { lastRecoveryEndTime = Date() }
            endMicRecovery(for: sessionGeneration)
        }
        guard sessionGeneration == recordingSessionGeneration else { return }
        lastRecoveryTime = Date()
        // Checked before any hardware is touched: a recording that Stop
        // already took, or that never opened a mic file, has nothing to
        // recover into, and building a graph would open the default input.
        guard micAudioFileQueue.sync(execute: {
            micAudioFileOwnership.recordingOwnsMicFile(sessionGeneration)
        }) else {
            AppLogger.audioMic.info("Skipping mic recovery; this recording no longer owns a mic file", [
                "session": "\(sessionGeneration)"
            ])
            return
        }

        // A failed earlier attempt can leave no published graph. Rebuild from
        // scratch then; returning here would skip the attempt count, so the
        // watchdog would never give up and the meeting would record silence.
        let currentEngine = engine
        let currentInputNode = inputNode

        // Track device switch for health monitoring. Deliberate processing
        // restarts and the restart after the Mac wakes stay out of
        // deviceSwitchCount so health metadata and capture_quality aren't
        // polluted (the sleep itself is recorded as a gap); recoveryAttemptCount stays
        // unconditional — it's the watchdog give-up safety counter and
        // resets on success below.
        let switchStart = Date()
        var lastMicBufferTime = lastBufferTime
        // A fresh-graph retry after a failed in-place restart is the same
        // switch, so it is not counted twice.
        if !freshGraphRequested,
           MicDeviceSwitchCountingPolicy.counts(reason: reason, afterSystemWake: afterSystemWake) {
            // Atomic read-modify-write: the SCK-path recovery-event
            // subscription can increment this same counter concurrently on
            // main (see `Audio.incrementDeviceSwitchCount()`), so a plain
            // `deviceSwitchCount += 1` here (get + separately-locked set)
            // could race and drop an increment from either side.
            incrementDeviceSwitchCount()
        }
        // The fresh-graph retry finishes the attempt that just failed in
        // place, so it does not spend another of the watchdog's attempts.
        if !freshGraphRequested {
            recoveryAttemptCount += 1
        }
        AppLogger.audioMic.debug("Recovering from device change", ["switchNumber": "\(deviceSwitchCount)", "maxAttempts": "\(maxRecoveryAttempts)"])

        // The pinned mic already failed in this streak, or never delivered a
        // frame at all. Try the built-in mic first this time.
        if MicRecoveryInputFallbackPolicy.shouldTryBuiltInFirst(
            reason: reason,
            recoveryAttemptNumber: recoveryAttemptCount,
            micHasDeliveredAudio: micBufferCount > 0,
            inPlaceRestartJustFailed: freshGraphRequested
        ) {
            pinBuiltInMeetingInputFallback(operation: "device_recovery")
        }
        // After a failed attempt the current graph is suspect; build fresh.
        let inPlaceSelection = inPlaceRestartSelection(
            reason: reason,
            freshGraphRequested: freshGraphRequested || recoveryAttemptCount > 1,
            engine: currentEngine,
            inputNode: currentInputNode
        )

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
            if inPlaceSelection != nil, let currentEngine, let currentInputNode {
                // Keep the node bound to the pinned mic: no VPIO disarm and
                // no engine reset, just stop and drop the old tap.
                tearDownInputTapSafely(
                    engine: currentEngine,
                    inputNode: currentInputNode,
                    operation: "device_recovery_in_place"
                )
            } else if let currentEngine {
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

        // A rejected device bind can leave the node half-switched. Rebuild the
        // graph from scratch, retry once, and validate both device ID and
        // hardware format before installing another tap.
        let bluetoothInputWasSelected = reason == .deviceChange && meetingInputIsBluetooth()
        let preparedGraph: PreparedMeetingInputGraph
        var usedInPlaceRestart = false
        do {
            if let inPlaceSelection,
               let currentEngine,
               let currentInputNode,
               let inPlaceGraph = try prepareInPlaceMeetingInputGraph(
                   engine: currentEngine,
                   inputNode: currentInputNode,
                   selection: inPlaceSelection,
                   sessionGeneration: sessionGeneration
               ) {
                preparedGraph = inPlaceGraph
                usedInPlaceRestart = true
            } else {
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
            }
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
        AppLogger.audioMic.info(
            usedInPlaceRestart
                ? "Restarting mic engine in place on pinned meeting input"
                : "Rebuilt mic engine on pinned meeting input",
            ["sampleRate": "\(recordingSnapshot.sampleRate)", "channels": "\(recordingSnapshot.channelCount)"]
        )

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
        var recoverySegmentWasRegistered = false
        var shouldKeepRecoverySegment = false
        defer {
            if let recoverySegmentURL, !shouldKeepRecoverySegment,
               recoverySegmentWasRegistered,
               !unregisterMicRecoverySegment(recoverySegmentURL, sessionGeneration: sessionGeneration) {
                // Stop landed after the segment was registered. It already
                // listed, closed and will merge this file, including any
                // audio that arrived before the tap came down.
                AppLogger.audioMic.info("Stop took the in-progress recovery segment", [
                    "file": recoverySegmentURL.lastPathComponent
                ])
            } else if let recoverySegmentURL, !shouldKeepRecoverySegment {
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
            micRecoveryGapAnchor = lastMicBufferTime
        case .alreadyRetired:
            // An earlier attempt closed the last segment and then failed.
            // Its gap is still open; this attempt's segment pads all of it,
            // from the last frame that segment kept. Frames a failed attempt
            // wrote were deleted with its segment, so they don't count.
            lastMicBufferTime = MicRecoveryGapAnchorPolicy.anchor(
                closedSegmentThisAttempt: false,
                storedAnchor: micRecoveryGapAnchor,
                lastBufferTime: lastMicBufferTime
            )
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
            // List the segment with the recording before any buffer can
            // reach it, so a Stop during the restart keeps its audio instead
            // of deleting it. The gap is corrected once the first frame lands.
            guard registerMicRecoverySegment(
                MicRecordingSegment(
                    url: fileURL,
                    gapBeforeDuration: max(
                        CACurrentMediaTime() - lastMicBufferTime,
                        Date().timeIntervalSince(switchStart)
                    )
                ),
                sessionGeneration: sessionGeneration
            ) else {
                AppLogger.audioMic.info("Skipping stale recovery before segment registration", [
                    "expectedSession": "\(sessionGeneration)",
                    "currentSession": "\(recordingSessionGeneration)"
                ])
                return
            }
            recoverySegmentWasRegistered = true
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
                // Stop ends the wait early. That is not a failed restart and
                // must not log as one or schedule a retry.
                guard sessionGeneration == recordingSessionGeneration else {
                    throw AudioCaptureStaleSessionError()
                }
                throw NSError(
                    domain: "Audio",
                    code: 6,
                    userInfo: [NSLocalizedDescriptionKey: "The microphone restarted but did not deliver audio."]
                )
            }
            guard sessionGeneration == recordingSessionGeneration else {
                throw AudioCaptureStaleSessionError()
            }
            // A reused node could be re-bound by the route change as it
            // restarts. Frames from another mic are a failed attempt, so the
            // retry builds a fresh graph on the pinned mic.
            if usedInPlaceRestart, let pinnedID = inPlaceSelection?.selectedInput.id,
               withAudioGraphLock({ newInputNode.auAudioUnit.deviceID }) != pinnedID {
                throw NSError(
                    domain: "Audio",
                    code: 7,
                    userInfo: [NSLocalizedDescriptionKey: "The microphone restarted on a different input."]
                )
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
            let finalized = finalizeRegisteredMicRecoverySegment(
                gap: gap,
                segmentURL: fileURL,
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
            if usedInPlaceRestart {
                // The reused graph went stale. Build a fresh one right away
                // instead of waiting out the watchdog cooldown. Delayed a
                // beat so this attempt's ownership is released first.
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    self?.recoverFromDeviceChange(
                        sessionGeneration: sessionGeneration,
                        reason: reason,
                        afterSystemWake: afterSystemWake,
                        freshGraphRequested: true
                    )
                }
            }
        }
    }

    /// The pinned selection when this recovery may reuse the current graph.
    private func inPlaceRestartSelection(
        reason: MicCaptureRestartReason,
        freshGraphRequested: Bool,
        engine: AVAudioEngine?,
        inputNode: AVAudioInputNode?
    ) -> MeetingInputDeviceSelection? {
        guard engine != nil, let inputNode,
              let selection = meetingInputSelectionSnapshot() else { return nil }
        let pinned = selection.selectedInput
        let boundInputID = withAudioGraphLock { inputNode.auAudioUnit.deviceID }
        let canRestart = MicInPlaceRestartPolicy.canRestartInPlace(
            reason: reason,
            freshGraphRequested: freshGraphRequested,
            pinnedInputID: pinned.id,
            pinnedInputIsBluetooth: pinned.transport == .bluetooth || pinned.transport == .bluetoothLE,
            pinnedInputIsAlive: ((try? pinned.id.readNominalSampleRate()) ?? 0) > 0,
            boundInputID: boundInputID,
            voiceProcessingEnabled: voiceProcessingEnabled
        )
        return canRestart ? selection : nil
    }

    /// Validate the current, stopped graph for reuse. Returns nil when it
    /// must be rebuilt instead; throws only for a stale session.
    private func prepareInPlaceMeetingInputGraph(
        engine: AVAudioEngine,
        inputNode: AVAudioInputNode,
        selection: MeetingInputDeviceSelection,
        sessionGeneration: UInt64
    ) throws -> PreparedMeetingInputGraph? {
        try withAudioGraphLock { () throws -> PreparedMeetingInputGraph? in
            guard sessionGeneration == recordingSessionGeneration else {
                throw AudioCaptureStaleSessionError()
            }
            guard engine === self.engine, inputNode === self.inputNode,
                  inputNode.auAudioUnit.deviceID == selection.selectedInput.id else {
                AppLogger.audioMic.info("Mic graph changed before in-place restart; rebuilding")
                return nil
            }
            let recordingFormat = self.recordingFormat(
                for: inputNode,
                voiceProcessingEnabled: false
            )
            guard let recordingSnapshot = AudioRecordingFormatPolicy.snapshot(recordingFormat),
                  MicInPlaceRestartPolicy.formatStillMatchesDevice(
                      capturedSampleRate: recordingSnapshot.sampleRate,
                      deviceNominalSampleRate: try? selection.selectedInput.id.readNominalSampleRate()
                  ) else {
                AppLogger.audioMic.info("Mic format moved since the graph was built; rebuilding", [
                    "capturedRate": "\(recordingFormat.sampleRate)"
                ])
                return nil
            }
            return PreparedMeetingInputGraph(
                engine: engine,
                inputNode: inputNode,
                recordingFormat: recordingFormat,
                recordingSnapshot: recordingSnapshot,
                voiceProcessingEnabled: false
            )
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
            let (publishedEngine, changedEngineIsRunning) = self.withAudioGraphLock {
                (self.engine, changedEngine?.isRunning ?? false)
            }
            let decision = MicEngineConfigurationChangePolicy.decision(
                sessionIsCurrent: sessionGeneration == self.recordingSessionGeneration,
                isRecording: self.isRecording,
                isSystemSleeping: self.isSystemSleepPending(for: sessionGeneration),
                isRecovering: self.isMicRecovering,
                changedEngineIsPublishedGraph: changedEngine != nil
                    && changedEngine === publishedEngine,
                changedEngineIsRunning: changedEngineIsRunning,
                deliveredNewBuffer: MicRecoveryReadinessPolicy.deliveredNewBuffer(
                    before: bufferCountAtChange,
                    after: self.micBufferCount
                ),
                secondsSinceLastRecoveryEnded: self.lastRecoveryEndTime.map {
                    Date().timeIntervalSince($0)
                },
                recoveryAttemptsUsed: self.recoveryAttemptCount,
                maxRecoveryAttempts: self.maxRecoveryAttempts
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
            case .engineStillRunning:
                AppLogger.audioMic.info("Audio route changed but the mic engine is still running; leaving it to the watchdog")
            case .recover:
                // Restarts in place when the pinned mic is still bound, so a
                // route change does not reopen the default input.
                AppLogger.audioMic.warning("Audio route change stopped the microphone; recovering now")
                self.recoverFromDeviceChange(sessionGeneration: sessionGeneration)
            }
        }
    }
}
