import Foundation
import TranscriptedCore

enum FailedMeetingPresentation {
    static func item(
        from failed: FailedTranscription,
        isRetrying: Bool
    ) -> MeetingSessionController.FailedMeetingItem {
        let failureKind = MeetingFailureKind.classify(message: failed.errorMessage)
        let availableAudioURLs = audioURLs(for: failed)
        let hasRetryableAudioFiles = failed.audioFilesExist()
        let copy = MeetingFailureCopy.make(
            forMessage: failed.errorMessage,
            shortErrorMessage: failed.shortErrorMessage,
            isRetryable: failed.isRetryable
        )

        return MeetingSessionController.FailedMeetingItem(
            id: failed.id,
            timestamp: failed.timestamp,
            title: title(for: failed, fallback: copy.title),
            detail: copy.detail,
            meta: meta(for: failed, availableAudioURLs: availableAudioURLs, isRetrying: isRetrying),
            failureKind: failureKind,
            isRetryable: failed.isRetryable,
            isRetrying: isRetrying,
            hasAudioFiles: hasRetryableAudioFiles,
            audioURLs: availableAudioURLs
        )
    }

    private static func title(for failed: FailedTranscription, fallback: String) -> String {
        if let title = failed.meetingTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            return title
        }
        return fallback == "Transcript needs another pass" ? "Meeting transcript failed" : fallback
    }

    private static func audioURLs(for failed: FailedTranscription) -> [URL] {
        let fileManager = FileManager.default
        return [failed.systemAudioURL, failed.micAudioURL]
            .compactMap { $0 }
            .filter { fileManager.fileExists(atPath: $0.path) }
    }

    private static func meta(for failed: FailedTranscription, availableAudioURLs: [URL], isRetrying: Bool) -> String {
        var parts = [failed.formattedTimestamp]

        if !availableAudioURLs.isEmpty {
            let sizeText = failed.formattedFileSize
            let hasRawAudio = availableAudioURLs.contains {
                $0.pathExtension.localizedCaseInsensitiveCompare("wav") == .orderedSame
            }
            if sizeText == "Unknown" {
                parts.append(hasRawAudio ? "Raw audio kept" : "Audio kept")
            } else {
                parts.append(hasRawAudio ? "\(sizeText) raw audio kept" : "\(sizeText) kept")
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
