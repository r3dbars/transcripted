import Foundation
import TranscriptedCore

/// Finds the saved transcript a speaker review is about. The background
/// restyle renames the file after the review is queued, so when the original
/// path is gone the transcript is found again by its id in the same folder.
enum SpeakerReviewTranscriptLocator {
    /// `url` if it still exists, else the renamed file with `transcriptId`
    /// in the same folder, else nil.
    static func currentURL(for url: URL, transcriptId: UUID?) -> URL? {
        if FileManager.default.fileExists(atPath: url.path) { return url }
        return TranscriptSaver.existingTranscriptURL(
            in: url.deletingLastPathComponent(),
            transcriptId: transcriptId
        )
    }
}
