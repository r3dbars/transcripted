import Foundation


/// Retry availability policy for failed-meeting rows. The old composite
/// presentation (icon + tone + full struct) retired with the failed-meetings
/// card; the inline row consumes these two answers directly.
enum FailedMeetingRecoveryPresentation {
    static func retryDisabled(
        canRetry: Bool,
        isRetryable: Bool,
        isRetrying: Bool,
        hasAudioFiles: Bool,
        usableAudio: FailedMeetingUsableAudio = .unknown
    ) -> Bool {
        !canRetry || !isRetryable || !hasAudioFiles || isRetrying || usableAudio == .absent
    }

    static func retryHelp(
        canRetry: Bool,
        retryUnavailableReason: String?,
        isRetryable: Bool,
        isRetrying: Bool,
        hasAudioFiles: Bool,
        usableAudio: FailedMeetingUsableAudio = .unknown
    ) -> String {
        if isRetrying {
            return "Retry is already running."
        }
        if !hasAudioFiles || !isRetryable {
            return "This meeting does not have enough saved audio to retry."
        }
        if usableAudio == .absent {
            return "The saved audio has no sound in it, so transcribing it again cannot produce a transcript."
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
