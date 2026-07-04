import Foundation

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
        switch reason {
        case .invalidAudioFormat, .audioRouteNotSettled, .audioEngineStartFailed, .audioEngineStartTimedOut:
            shouldScheduleRetry = !isRecoveryAttempt
        }

        return ParakeetStartRecordingFailureAction(
            markFormatUnready: true,
            schedulePrewarmRetry: shouldScheduleRetry,
            rebuildAudioEngine: true
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
        selectionReason _: DictationInputDeviceSelectionReason? = nil
    ) -> ParakeetAudioFormatReadiness {
        guard isUsableCaptureSampleRate(outputSampleRate), outputChannelCount > 0,
              isUsableCaptureSampleRate(inputSampleRate), inputChannelCount > 0 else {
            return .invalid
        }

        let lowRateOutputBus = likelyBluetoothSpeechRates.contains(Int(outputSampleRate.rounded()))
        let overriddenBluetoothOutputRoute = selectionOverrodeDefault
            && outputDeviceClass == "bluetooth"

        if selectedInputClass != "bluetooth",
           inputSampleRate >= 44_100,
           lowRateOutputBus,
           (outputDeviceClass != "bluetooth" || overriddenBluetoothOutputRoute) {
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

enum ParakeetInputOverrideSettlePolicy {
    static func delayNanoseconds(afterImmediateReadiness readiness: ParakeetAudioFormatReadiness) -> UInt64 {
        switch readiness {
        case .ready, .invalid, .routeNotSettled:
            return TranscriptedConstants.audioRecoveryDelay
        }
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
