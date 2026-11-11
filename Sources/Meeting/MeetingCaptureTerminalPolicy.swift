import Foundation

enum CaptureStopFinalizationOwner: Equatable {
    case audioFinalizer
    case recordingJournalRecovery
}

/// Decisions shared by the actual pending/expired discard routes and the
/// post-await UI clear. Recovery owns its handed-off artifacts independently.
enum MeetingCaptureTerminalPolicy {
    static func mayDiscardFinalizedAudio(finalizationOwner: CaptureStopFinalizationOwner) -> Bool {
        finalizationOwner != .recordingJournalRecovery
    }
    static func mayClearPublishedURLs(resultStopGeneration: UInt64?, currentGeneration: UInt64) -> Bool {
        guard let resultStopGeneration else { return false }
        return resultStopGeneration == currentGeneration
    }
}
