import Foundation
import TranscriptedCore

enum FailedMeetingPresentation {
    static func item(
        from failed: FailedTranscription,
        isRetrying: Bool
    ) -> MeetingSessionController.FailedMeetingItem {
        MeetingSessionController.FailedMeetingItem(
            id: failed.id,
            timestamp: failed.timestamp,
            title: title(for: failed),
            detail: detail(for: failed),
            meta: meta(for: failed, isRetrying: isRetrying),
            isRetryable: failed.isRetryable,
            isRetrying: isRetrying,
            hasAudioFiles: failed.audioFilesExist()
        )
    }

    private static func title(for failed: FailedTranscription) -> String {
        let message = failed.errorMessage.lowercased()

        if message.contains("system audio is required") || message.contains("screen recording") {
            return "Turn on Screen Recording"
        }

        if message.contains("recording too short") || message.contains("at least") {
            return "Recording was too short"
        }

        if message.contains("no samples recorded") || message.contains("empty audio") {
            return "No audio was captured"
        }

        if message.contains("failed to save") {
            return "Couldn't save the transcript"
        }

        return failed.isRetryable ? "Transcript needs another pass" : "Recording needs attention"
    }

    private static func detail(for failed: FailedTranscription) -> String {
        let message = failed.errorMessage.lowercased()

        if message.contains("system audio is required") || message.contains("screen recording") {
            return "Turn on Screen Recording in System Settings, then retry the meeting."
        }

        if message.contains("recording too short") || message.contains("at least") {
            return "Keep the meeting running a little longer before stopping the capture."
        }

        if message.contains("no samples recorded") || message.contains("empty audio") {
            return "The source audio was kept, but there was not enough signal to transcribe."
        }

        if message.contains("failed to save") {
            return failed.shortErrorMessage
        }

        return failed.shortErrorMessage
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
