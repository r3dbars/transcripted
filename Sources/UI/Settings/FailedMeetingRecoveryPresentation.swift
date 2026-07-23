import Foundation

enum FailedMeetingRecoveryIconTone: Equatable {
    case neutral
    case warning
}

struct FailedMeetingRecoveryPresentation: Equatable {
    let iconSystemName: String
    let iconTone: FailedMeetingRecoveryIconTone
    let retryDisabled: Bool
    let retryHelp: String

    static func make(
        failureKind: MeetingFailureKind,
        canRetry: Bool,
        retryUnavailableReason: String?,
        isRetryable: Bool,
        isRetrying: Bool,
        hasAudioFiles: Bool
    ) -> FailedMeetingRecoveryPresentation {
        FailedMeetingRecoveryPresentation(
            iconSystemName: failureKind == .recordingTooShort ? "timer" : "exclamationmark.triangle.fill",
            iconTone: failureKind == .recordingTooShort ? .neutral : .warning,
            retryDisabled: retryDisabled(
                canRetry: canRetry,
                isRetryable: isRetryable,
                isRetrying: isRetrying,
                hasAudioFiles: hasAudioFiles
            ),
            retryHelp: retryHelp(
                canRetry: canRetry,
                retryUnavailableReason: retryUnavailableReason,
                isRetryable: isRetryable,
                isRetrying: isRetrying,
                hasAudioFiles: hasAudioFiles
            )
        )
    }

    static func retryDisabled(
        canRetry: Bool,
        isRetryable: Bool,
        isRetrying: Bool,
        hasAudioFiles: Bool
    ) -> Bool {
        !canRetry || !isRetryable || !hasAudioFiles || isRetrying
    }

    static func retryHelp(
        canRetry: Bool,
        retryUnavailableReason: String?,
        isRetryable: Bool,
        isRetrying: Bool,
        hasAudioFiles: Bool
    ) -> String {
        if isRetrying {
            return "Retry is already running."
        }
        if !hasAudioFiles || !isRetryable {
            return "This meeting does not have enough saved audio to retry."
        }
        if let retryUnavailableReason {
            return retryUnavailableReason
        }
        if !canRetry {
            return "Wait for the current meeting work to finish before retrying."
        }
        return "Transcribe this saved audio again."
    }
}
