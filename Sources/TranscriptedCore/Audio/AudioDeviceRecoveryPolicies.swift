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
        /// Another recovery owns the published graph; look again shortly.
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
        changedEngineIsRunning: Bool,
        deliveredNewBuffer: Bool,
        secondsSinceLastRecoveryEnded: TimeInterval?,
        recoveryAttemptsUsed: Int,
        maxRecoveryAttempts: Int
    ) -> Decision {
        guard sessionIsCurrent, isRecording, !isSystemSleeping else { return .ignore }
        guard !isRecovering else { return .waitForRecovery }
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

/// Where a retry's gap starts, when an earlier attempt already closed the
/// last segment. Measured from the last frame the recording kept, not the
/// last frame seen: a failed attempt can take frames (e.g. from a re-bound
/// input) that are thrown away with its segment. The attempt that closes a
/// segment anchors at its own last frame and doesn't ask.
enum MicRecoveryGapAnchorPolicy {
    static func anchor(
        storedAnchor: CFTimeInterval?,
        lastBufferTime: CFTimeInterval
    ) -> CFTimeInterval {
        guard let storedAnchor else { return lastBufferTime }
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

    /// Buffers still arriving usually mean the mic is fine, and skipping the
    /// rebuild keeps AirPods (as the default input) out of call mode. But
    /// buffers can keep coming from a device that went away during sleep,
    /// and the watchdog only notices missing buffers, not dead ones. So a
    /// bound device that is known dead still gets the restart. Unknown
    /// (`nil`) keeps the skip.
    static func shouldSkipRestart(micStillDelivering: Bool, boundDeviceAlive: Bool?) -> Bool {
        micStillDelivering && boundDeviceAlive != false
    }
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
