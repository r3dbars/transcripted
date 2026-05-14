import Foundation

enum MeetingSessionUIPolicy {
    static func shouldShowTranscribing(
        activeTranscriptions: Int,
        queuedTranscriptions: Int
    ) -> Bool {
        activeTranscriptions > 0 || queuedTranscriptions > 0
    }

    static func canStartQueuedTranscription(
        activeTranscriptions: Int,
        isSpeakerReviewPending: Bool,
        isPreparingQueuedTranscriptionStart: Bool
    ) -> Bool {
        activeTranscriptions == 0
            && !isSpeakerReviewPending
            && !isPreparingQueuedTranscriptionStart
    }
}
