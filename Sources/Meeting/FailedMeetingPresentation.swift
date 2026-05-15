import Foundation
import TranscriptedCore

enum FailedMeetingPresentation {
    static func item(
        from failed: FailedTranscription,
        isRetrying: Bool
    ) -> MeetingSessionController.FailedMeetingItem {
        let failureKind = MeetingFailureKind.classify(message: failed.errorMessage)
        let availableAudioURLs = audioURLs(for: failed)
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
            meta: meta(for: failed, hasAudioFiles: !availableAudioURLs.isEmpty, isRetrying: isRetrying),
            failureKind: failureKind,
            isRetryable: failed.isRetryable,
            isRetrying: isRetrying,
            hasAudioFiles: !availableAudioURLs.isEmpty,
            audioURLs: availableAudioURLs
        )
    }

    private static func audioURLs(for failed: FailedTranscription) -> [URL] {
        let fileManager = FileManager.default
        return [failed.systemAudioURL, failed.micAudioURL]
            .compactMap { $0 }
            .filter { fileManager.fileExists(atPath: $0.path) }
    }

    private static func meta(for failed: FailedTranscription, hasAudioFiles: Bool, isRetrying: Bool) -> String {
        var parts = [failed.formattedTimestamp]

        if hasAudioFiles {
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
