#if canImport(TranscriptedWritingCore)
import TranscriptedWritingCore
#endif
import Foundation

/// "Pause for 1 hour" pauses Save my writing as well as suggestions. Tilde's
/// pause stopped only the ghost, and its keyboard keeps sending typed text
/// while paused; here that text is acknowledged and never kept, so the
/// keyboard doesn't retry it.
struct WritingPausableIngest: PersonalHistoryIngesting {
    let base: any PersonalHistoryIngesting
    let isPaused: @Sendable () -> Bool

    func ingest(_ events: [PersonalHistoryEvent]) async -> Bool {
        guard !isPaused() else { return PersonalHistoryEvent.validBatch(events) }
        return await base.ingest(events)
    }
}
