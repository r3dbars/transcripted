import Foundation

/// Distinguishes a blocked audio-engine worker from a worker that actually
/// exceeded its deadline. Circuit-open work remains fail-closed without
/// abandoning the graph that never started.
enum ParakeetAudioEngineWorkError: LocalizedError {
    case timedOut(operation: String, timeoutMs: Int)
    case circuitOpen(operation: String, activeWorkers: Int)

    var isTimedOut: Bool {
        if case .timedOut = self { return true }
        return false
    }

    var requiresGraphAbandonment: Bool {
        isTimedOut
    }

    var isCircuitOpen: Bool {
        if case .circuitOpen = self { return true }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .timedOut(let operation, let timeoutMs):
            return "Audio engine \(operation) timed out after \(timeoutMs)ms"
        case .circuitOpen(let operation, let activeWorkers):
            return "Audio engine \(operation) skipped while \(activeWorkers) timed operations are still running"
        }
    }
}

enum ParakeetStartRecordingFailureReason: Equatable {
    case invalidAudioFormat
    case audioRouteNotSettled
    case audioEngineStartFailed
    case audioEngineStartTimedOut
}

struct ParakeetStartRecordingFailureAction: Equatable {
    let markFormatUnready: Bool
    let schedulePrewarmRetry: Bool
    let rebuildAudioEngine: Bool
}

struct ParakeetDeviceRecoveryFailureAction: Equatable {
    let reportSentryFailure: Bool
    let markRecordingInterrupted: Bool
    let schedulePrewarmRetry: Bool
}

enum ParakeetDeviceRecoveryReadinessAction: Equatable {
    case finishRecovery
    case keepWaiting
}

enum ParakeetAudioEngineRebuildStrategy: Equatable {
    case queuedOnAudioEngineQueue
    case abandonBlockedAudioGraph
}

enum ParakeetConfigChangeSource: Equatable, Sendable {
    case audioEngine
    case defaultInputDevice
}

enum ParakeetConfigChangeGraphStrategy: Equatable {
    case reuseCurrentGraph
    case rebuildGraph
}

/// Chooses whether a configuration notification requires replacing the whole
/// AVAudioEngine or whether recovery can restart the current graph in place.
///
/// Releasing a retired AVAudioEngine can make CoreAudio stop the replacement
/// engine and post a late configuration notification even though the physical
/// route did not change. Rebuilding again for that notification retires another
/// engine and creates a self-sustaining five-second recovery loop. A proven
/// recording on the exact same process-local graph endpoints can safely reuse
/// its current graph. The system default input and selection reason are not
/// graph endpoints: they may change while Transcripted keeps the same explicit
/// mic and output. Changed, unknown, unready, or sample-unproven active graphs
/// keep the full rebuild path. Idle notifications never reach this policy;
/// they defer validation until the next explicit dictation. Telemetry remains
/// categorical and never receives this identity.
enum ParakeetConfigChangeGraphPolicy {
    static func strategy(
        source: ParakeetConfigChangeSource,
        wasRecording: Bool,
        hadSampleFlow: Bool,
        inputWasReady: Bool,
        stableRouteIdentity: ParakeetAudioRouteIdentity?,
        observedRouteIdentity: ParakeetAudioRouteIdentity?
    ) -> ParakeetConfigChangeGraphStrategy {
        guard wasRecording,
              hadSampleFlow,
              inputWasReady,
              let stableRouteIdentity,
              let observedRouteIdentity,
              stableRouteIdentity.matchesGraphEndpoints(observedRouteIdentity) else {
            return .rebuildGraph
        }
        return .reuseCurrentGraph
    }
}

enum ParakeetConfigChangeContinuityPolicy {
    static func shouldProbe(
        wasRecording: Bool,
        hadSampleFlow: Bool,
        inputWasReady: Bool,
        graphEndpointsMatch: Bool
    ) -> Bool {
        wasRecording && hadSampleFlow && inputWasReady && graphEndpointsMatch
    }

    static func shouldIgnoreAfterProbe(
        wasRecording: Bool,
        inputWasReady: Bool,
        graphEndpointsMatch: Bool,
        sampleArrivedAfterNotification: Bool
    ) -> Bool {
        wasRecording
            && inputWasReady
            && graphEndpointsMatch
            && sampleArrivedAfterNotification
    }
}

struct ParakeetDeviceRecoveryTimeoutAction: Equatable {
    let failureAction: ParakeetDeviceRecoveryFailureAction
    let rebuildStrategy: ParakeetAudioEngineRebuildStrategy
}

enum ParakeetStartRecordingFailurePolicy {
    static func action(
        for reason: ParakeetStartRecordingFailureReason,
        isRecoveryAttempt: Bool
    ) -> ParakeetStartRecordingFailureAction {
        let shouldScheduleRetry: Bool
        let shouldRebuildAudioEngine: Bool
        switch reason {
        case .invalidAudioFormat, .audioEngineStartFailed, .audioEngineStartTimedOut:
            shouldScheduleRetry = !isRecoveryAttempt
            shouldRebuildAudioEngine = true
        case .audioRouteNotSettled:
            shouldScheduleRetry = true
            shouldRebuildAudioEngine = false
        }

        return ParakeetStartRecordingFailureAction(
            markFormatUnready: true,
            schedulePrewarmRetry: shouldScheduleRetry,
            rebuildAudioEngine: shouldRebuildAudioEngine
        )
    }
}

enum ParakeetDeviceRecoveryFailurePolicy {
    static func action(wasRecording: Bool) -> ParakeetDeviceRecoveryFailureAction {
        ParakeetDeviceRecoveryFailureAction(
            reportSentryFailure: wasRecording,
            markRecordingInterrupted: wasRecording,
            schedulePrewarmRetry: true
        )
    }

    /// Choose how to recover the audio graph after a device-change rewarm fails.
    ///
    /// A rewarm fails when the recovery snapshot throws. The only non-stale throw
    /// it can produce is a timed-out audio-engine operation — which means the
    /// serial `audioEngineQueue` is wedged behind a CoreAudio call that never
    /// returned (the classic AirPods/Bluetooth route-switch hang). Queuing a
    /// `rebuildAudioEngine` on that same blocked queue would never run, so the
    /// recovery task hangs forever and the engine stays dead until the user
    /// force-quits (surfacing as `app.unclean_shutdown_detected`).
    ///
    /// When the queue is blocked, abandon the wedged graph instead: swap in a
    /// fresh `AVAudioEngine` and a fresh queue synchronously, mirroring the
    /// recovery-timeout path (`ParakeetDeviceRecoveryTimeoutPolicy`) and the
    /// start-recording timeout path. Non-blocked failures can still rebuild on
    /// the existing queue.
    static func rebuildStrategy(audioEngineQueueBlocked: Bool) -> ParakeetAudioEngineRebuildStrategy {
        audioEngineQueueBlocked ? .abandonBlockedAudioGraph : .queuedOnAudioEngineQueue
    }
}

enum ParakeetDeviceRecoveryReadinessPolicy {
    static func action(for readiness: ParakeetAudioFormatReadiness) -> ParakeetDeviceRecoveryReadinessAction {
        switch readiness {
        case .ready:
            return .finishRecovery
        case .invalid, .routeNotSettled:
            return .keepWaiting
        }
    }
}

enum ParakeetDeviceRecoveryStartRetryPolicy {
    static func shouldRetry(
        after failureReason: ParakeetStartRecordingFailureReason?,
        inputCanStartRecording: Bool
    ) -> Bool {
        guard let failureReason else {
            return !inputCanStartRecording
        }
        switch failureReason {
        case .invalidAudioFormat, .audioRouteNotSettled:
            return true
        case .audioEngineStartFailed, .audioEngineStartTimedOut:
            return false
        }
    }
}

/// Bounded attempt state for restarting an interrupted recording after a real
/// endpoint change. CoreAudio can report a usable snapshot and then renegotiate
/// the split Bluetooth route again while the microphone graph starts. Keeping
/// this as explicit state guarantees one post-settle attempt without restoring
/// the old unbounded recovery loop.
struct ParakeetRecordingRestartBudget: Equatable {
    let maxAttempts: Int
    let retryDelayNanoseconds: UInt64
    let deadlineUptime: TimeInterval
    private(set) var attemptsMade = 0

    init(
        maxAttempts: Int = TranscriptedConstants.recordingRestartAttempts,
        retryDelayNanoseconds: UInt64 = TranscriptedConstants.recordingRestartRetryDelay,
        admissionWindow: TimeInterval = TranscriptedConstants.recordingRestartAdmissionWindow,
        startedAtUptime: TimeInterval
    ) {
        self.maxAttempts = max(0, maxAttempts)
        self.retryDelayNanoseconds = retryDelayNanoseconds
        deadlineUptime = startedAtUptime + max(0, admissionWindow)
    }

    mutating func takeNextAttempt(nowUptime: TimeInterval) -> Int? {
        guard attemptsMade < maxAttempts, nowUptime < deadlineUptime else { return nil }
        attemptsMade += 1
        return attemptsMade
    }

    func delayBeforeNextAttempt(nowUptime: TimeInterval) -> UInt64? {
        guard attemptsMade < maxAttempts else { return nil }
        let retryDelaySeconds = Double(retryDelayNanoseconds) / 1_000_000_000
        guard nowUptime + retryDelaySeconds < deadlineUptime else { return nil }
        return retryDelayNanoseconds
    }
}

enum ParakeetDeviceRecoveryTimeoutPolicy {
    static func action(wasRecording: Bool) -> ParakeetDeviceRecoveryTimeoutAction {
        ParakeetDeviceRecoveryTimeoutAction(
            failureAction: ParakeetDeviceRecoveryFailurePolicy.action(wasRecording: wasRecording),
            rebuildStrategy: .abandonBlockedAudioGraph
        )
    }
}

enum ParakeetAudioEngineRetirementPolicy {
    /// CoreAudio can still deliver queued AVAudioIOUnit property-listener blocks
    /// after Transcripted has stopped and replaced an AVAudioEngine during route churn.
    static let deferredReleaseDelayNanoseconds: UInt64 = 5_000_000_000

    /// A notification storm must not retain an unlimited number of native
    /// audio graphs during that safety window. When full, recovery refuses a
    /// further replacement and reuses a successfully reset graph when safe.
    static let maximumRetainedEngineCount = 4
}

enum ParakeetASRManagerCleanupDecision: Equatable {
    case cleanupNow
    case deferUntilProcessExit
}

enum ParakeetASRManagerCleanupPolicy {
    static func decision(isTranscribing: Bool) -> ParakeetASRManagerCleanupDecision {
        isTranscribing ? .deferUntilProcessExit : .cleanupNow
    }
}

struct ParakeetASRInferenceActivityState: Equatable {
    private(set) var activeCount = 0

    var isActive: Bool {
        activeCount > 0
    }

    func canStartImmediately(reservedHandoffCount: Int) -> Bool {
        !isActive && reservedHandoffCount <= 0
    }

    mutating func begin() {
        activeCount += 1
    }

    mutating func finish() {
        activeCount = max(0, activeCount - 1)
    }
}

enum ParakeetAudioFormatReadiness: String, Equatable {
    case ready
    case invalid
    case routeNotSettled

    var startFailureReason: ParakeetStartRecordingFailureReason? {
        switch self {
        case .ready:
            return nil
        case .invalid:
            return .invalidAudioFormat
        case .routeNotSettled:
            return .audioRouteNotSettled
        }
    }
}

enum ParakeetAudioFormatReadinessPolicy {
    private static let likelyBluetoothSpeechRates: Set<Int> = [8_000, 16_000, 24_000]
    static let audioUnitFormatNotSupportedCode = -10_868
    static let fallbackCaptureSampleRate: Double = 48_000
    private static let minimumUsableSampleRate: Double = 8_000
    private static let maximumUsableSampleRate: Double = 384_000
    private static let maximumBufferCapacitySampleRate: Double = 96_000

    static func readiness(
        outputSampleRate: Double,
        outputChannelCount: UInt32,
        inputSampleRate: Double,
        inputChannelCount: UInt32,
        selectedInputClass: String,
        outputDeviceClass: String,
        selectionOverrodeDefault: Bool,
        selectionReason: DictationInputDeviceSelectionReason? = nil
    ) -> ParakeetAudioFormatReadiness {
        guard isUsableCaptureSampleRate(outputSampleRate), outputChannelCount > 0,
              isUsableCaptureSampleRate(inputSampleRate), inputChannelCount > 0 else {
            return .invalid
        }

        let lowRateOutputBus = likelyBluetoothSpeechRates.contains(Int(outputSampleRate.rounded()))
        let overriddenBluetoothOutputRoute = selectionOverrodeDefault
            && outputDeviceClass == "bluetooth"
        let suppressedRecoveryBluetoothRoute = selectedInputClass == "bluetooth"
            && outputDeviceClass == "bluetooth"
            && selectionReason == .builtInFallbackSuppressedForRecoveryAttempt

        if selectedInputClass != "bluetooth",
           inputSampleRate >= 44_100,
           lowRateOutputBus,
           (outputDeviceClass != "bluetooth" || overriddenBluetoothOutputRoute) {
            return .routeNotSettled
        }

        if suppressedRecoveryBluetoothRoute, lowRateOutputBus {
            return .routeNotSettled
        }

        return .ready
    }

    static func startFailureReason(for error: NSError) -> ParakeetStartRecordingFailureReason {
        if error.code == audioUnitFormatNotSupportedCode {
            return .audioRouteNotSettled
        }
        return .audioEngineStartFailed
    }

    static func isUsableCaptureSampleRate(_ sampleRate: Double) -> Bool {
        sampleRate.isFinite
            && sampleRate >= minimumUsableSampleRate
            && sampleRate <= maximumUsableSampleRate
    }

    static func captureSampleRateOrFallback(_ sampleRate: Double) -> Double {
        isUsableCaptureSampleRate(sampleRate) ? sampleRate : fallbackCaptureSampleRate
    }

    static func bufferCapacitySampleCount(sampleRate: Double, seconds: Int) -> Int {
        let safeRate = captureSampleRateOrFallback(sampleRate)
        let sampleCount = safeRate * Double(seconds)
        guard sampleCount.isFinite, sampleCount > 0 else {
            return Int(fallbackCaptureSampleRate) * max(seconds, 1)
        }
        return min(Int(sampleCount), Int(maximumBufferCapacitySampleRate) * max(seconds, 1))
    }
}

enum ParakeetTapSampleRatePolicy {
    static func effectiveSampleRate(
        bufferSampleRate: Double,
        hardwareSampleRate _: Double? = nil
    ) -> Double {
        ParakeetAudioFormatReadinessPolicy.captureSampleRateOrFallback(bufferSampleRate)
    }
}

enum ParakeetSampleSignalPolicy {
    private static let nonZeroSignalThreshold: Float = 0.000_001

    static func hasNonZeroSignal(_ samples: [Float]) -> Bool {
        samples.contains { abs($0) > nonZeroSignalThreshold }
    }

    static func shouldResetStartupAudio(
        sampleCount: Int,
        hasNonZeroSignal: Bool,
        isLikelyBluetoothHandsFreeRoute: Bool
    ) -> Bool {
        sampleCount == 0 || (sampleCount > 0 && !hasNonZeroSignal && isLikelyBluetoothHandsFreeRoute)
    }
}

enum ParakeetRouteDiagnosticsPolicy {
    static func routeShape(
        selectedInputClass: String,
        outputDeviceClass: String
    ) -> String {
        "\(selectedInputClass)_input_to_\(outputDeviceClass)_output"
    }

    static func isLikelyBluetoothHandsFreeProfile(
        inputClass: String,
        outputDeviceClass: String,
        inputRate: Double?,
        outputRate: Double?
    ) -> Bool {
        guard let inputRate, let outputRate else { return false }
        if inputClass == "bluetooth" {
            return inputRate <= 24_000 && outputRate >= 44_100
        }
        if outputDeviceClass == "bluetooth" {
            return outputRate <= 24_000 && inputRate >= 44_100
        }
        return false
    }
}

struct ParakeetAudioFormatSummary: Equatable {
    let sampleRate: Double
    let channelCount: UInt32
}
