import Foundation

/// Pure copy helpers for `HomeTranscriptionActivityPresentation`. Extracted
/// so this logic stays unit-testable without the enclosing presentation's
/// dependency on `MeetingSessionController` / `DisplayStatus` types.
enum HomeTranscriptionActivityCopy {
    static func resolvedTranscriptName(lastSavedTitle: String?, transcriptURL: URL?) -> String? {
        if let lastSavedTitle, !lastSavedTitle.isEmpty {
            return lastSavedTitle
        }

        guard let transcriptURL else { return nil }
        return transcriptURL.deletingPathExtension().lastPathComponent
    }

    static func failedTranscriptionDetail(for message: String) -> String {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.contains("audio file")
            || normalized.contains("convert")
            || normalized.contains("choose audio") {
            if normalized.contains("choose")
                || normalized.contains("try ") {
                return message
            }
            return "\(message) Choose another file, or convert it to WAV or M4A and import it again."
        }

        return "\(message) If audio was saved, the meeting row below will show Try again."
    }
}
