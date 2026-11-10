import Foundation
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif

/// A saved status can also describe an older meeting's speaker review. Only a
/// pipeline save owned by the running job may consume its recovery/telemetry.
enum MeetingTranscriptSavedPolicy {
    static func completesPipelineJob(
        origin: TranscriptSaveOrigin?, savedTaskID: UUID?, queuedTaskID: UUID?
    ) -> Bool {
        guard origin == .pipeline else { return false }
        // Direct retries and saved-audio retranscriptions have no queued ID.
        return queuedTaskID == nil || savedTaskID == queuedTaskID
    }
}
