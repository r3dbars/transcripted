import Foundation

enum ParakeetStartRecordingFailureReason: Equatable {
    case invalidAudioFormat
    case audioEngineStartFailed
}

struct ParakeetStartRecordingFailureAction: Equatable {
    let markFormatUnready: Bool
    let schedulePrewarmRetry: Bool
}

enum ParakeetStartRecordingFailurePolicy {
    static func action(
        for reason: ParakeetStartRecordingFailureReason,
        isRecoveryAttempt: Bool
    ) -> ParakeetStartRecordingFailureAction {
        let shouldScheduleRetry: Bool
        switch reason {
        case .invalidAudioFormat, .audioEngineStartFailed:
            shouldScheduleRetry = !isRecoveryAttempt
        }

        return ParakeetStartRecordingFailureAction(
            markFormatUnready: true,
            schedulePrewarmRetry: shouldScheduleRetry
        )
    }
}
