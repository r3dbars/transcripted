import Foundation
import TranscriptedCore

enum FailedMeetingPresentation {
    static func item(
        from failed: FailedTranscription,
        isRetrying: Bool
    ) -> MeetingSessionController.FailedMeetingItem {
        let failureKind = MeetingFailureKind.classify(message: failed.errorMessage)
        let copy = MeetingFailureCopy.make(
            forMessage: failed.errorMessage,
            shortErrorMessage: failed.shortErrorMessage,
            isRetryable: failed.isRetryable
        )

        return MeetingSessionController.FailedMeetingItem(
            id: failed.id,
            timestamp: failed.timestamp,
            title: copy.title,
            detail: copy.detail,
            meta: meta(for: failed, isRetrying: isRetrying),
            failureKind: failureKind,
            isRetryable: failed.isRetryable,
            isRetrying: isRetrying,
            hasAudioFiles: failed.audioFilesExist()
        )
    }

    private static func meta(for failed: FailedTranscription, isRetrying: Bool) -> String {
        var parts = [failed.formattedTimestamp]

        if failed.audioFilesExist() {
            let sizeText = failed.formattedFileSize
            if sizeText == "Unknown" {
                parts.append("Audio kept")
            } else {
                parts.append("\(sizeText) kept")
            }
        }

        if failed.retryCount > 0 {
            let attempts = failed.retryCount == 1 ? "1 retry" : "\(failed.retryCount) retries"
            parts.append(attempts)
        }

        if isRetrying {
            parts.append("Retrying now")
        }

        return parts.joined(separator: " • ")
    }
}
