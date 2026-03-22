import Foundation

// MARK: - Stats Database Protocol
// Conformer: StatsDatabase

protocol StatsStore {
    /// Record a completed transcription
    func recordTranscription(
        date: String,
        time: String,
        durationSeconds: Int,
        wordCount: Int,
        speakerCount: Int,
        processingTimeMs: Int,
        transcriptPath: String,
        title: String?
    )

    /// Get total recording count
    func totalRecordingCount() -> Int

    /// Get total duration in seconds
    func totalDurationSeconds() -> Int

    /// Get recordings for a specific date
    func recordingsForDate(_ date: String) -> [RecordingMetadata]

    /// Get daily activity for a date range
    func dailyActivity(from startDate: String, to endDate: String) -> [DailyActivity]
}
