import Foundation

enum MeetingSessionUIPolicy {
    static func shouldShowTranscribing(
        activeTranscriptions: Int,
        queuedTranscriptions: Int
    ) -> Bool {
        activeTranscriptions > 0 || queuedTranscriptions > 0
    }
}
