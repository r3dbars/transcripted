import Foundation

// MARK: - Stats Database Protocol
// Conformer: StatsDatabase
//
// Thin read/write surface for recording history and daily activity. The protocol exposes
// only the methods embedders need to substitute their own stats backend (e.g. a host app wants
// to persist to its own store). Bulk aggregation helpers (monthly rollups, streak
// computation, etc.) live directly on StatsDatabase and are not part of this protocol.

@available(macOS 14.0, *)
public protocol StatsStore {
    /// Record a completed transcription session. Writes are asynchronous under the hood,
    /// so this call is fire-and-forget.
    func recordSession(_ metadata: RecordingMetadata)

    /// Get the total number of recordings stored.
    func getTotalRecordingsCount() -> Int

    /// Get recordings that fall within an inclusive date range, newest first.
    func getRecordings(from startDate: Date, to endDate: Date) -> [RecordingMetadata]

    /// Check whether a recording has already been indexed at the given transcript path.
    func recordingExists(transcriptPath: String) -> Bool
}
