import Foundation

enum ParakeetStartRecordingFailureReason: Equatable {
    case invalidAudioFormat
    case audioRouteNotSettled
    case audioEngineStartFailed
}

struct ParakeetStartRecordingFailureAction: Equatable {
    let markFormatUnready: Bool
    let schedulePrewarmRetry: Bool
    let rebuildAudioEngine: Bool
}

enum ParakeetStartRecordingFailurePolicy {
    static func action(
        for reason: ParakeetStartRecordingFailureReason,
        isRecoveryAttempt: Bool
    ) -> ParakeetStartRecordingFailureAction {
        let shouldScheduleRetry: Bool
        switch reason {
        case .invalidAudioFormat, .audioRouteNotSettled, .audioEngineStartFailed:
            shouldScheduleRetry = !isRecoveryAttempt
        }

        return ParakeetStartRecordingFailureAction(
            markFormatUnready: true,
            schedulePrewarmRetry: shouldScheduleRetry,
            rebuildAudioEngine: true
        )
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

    static func readiness(
        outputSampleRate: Double,
        outputChannelCount: UInt32,
        inputSampleRate: Double,
        inputChannelCount: UInt32,
        selectedInputClass: String,
        selectionOverrodeDefault: Bool
    ) -> ParakeetAudioFormatReadiness {
        guard outputSampleRate > 0, outputChannelCount > 0,
              inputSampleRate > 0, inputChannelCount > 0 else {
            return .invalid
        }

        if selectionOverrodeDefault,
           selectedInputClass != "bluetooth",
           inputSampleRate >= 44_100,
           likelyBluetoothSpeechRates.contains(Int(outputSampleRate.rounded())) {
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
}
