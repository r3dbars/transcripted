import Foundation

// MARK: - Data Models

/// Metadata for a recording session
public struct RecordingMetadata: Identifiable {
    public let id: String
    public let date: Date
    public let durationSeconds: Int
    public let wordCount: Int
    public let speakerCount: Int
    public let processingTimeMs: Int
    public let transcriptPath: String?
    public let title: String?

    public init(
        id: String = UUID().uuidString,
        date: Date,
        durationSeconds: Int,
        wordCount: Int = 0,
        speakerCount: Int = 0,
        processingTimeMs: Int = 0,
        transcriptPath: String? = nil,
        title: String? = nil
    ) {
        self.id = id
        self.date = date
        self.durationSeconds = durationSeconds
        self.wordCount = wordCount
        self.speakerCount = speakerCount
        self.processingTimeMs = processingTimeMs
        self.transcriptPath = transcriptPath
        self.title = title
    }

    /// Format duration as "Xh Ym" or "Xm"
    public var formattedDuration: String {
        let hours = durationSeconds / 3600
        let minutes = (durationSeconds % 3600) / 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }

    /// Display title (fallback to date if no title)
    public var displayTitle: String {
        if let title = title, !title.isEmpty {
            return title
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "Recording - \(formatter.string(from: date))"
    }
}

/// Daily activity summary
public struct DailyActivity {
    public let date: String // "yyyy-MM-dd"
    public let recordingCount: Int
    public let totalDurationSeconds: Int
    public let actionItemsCount: Int

    public init(date: String, recordingCount: Int, totalDurationSeconds: Int, actionItemsCount: Int) {
        self.date = date
        self.recordingCount = recordingCount
        self.totalDurationSeconds = totalDurationSeconds
        self.actionItemsCount = actionItemsCount
    }

    /// Intensity level (0-4) for heat map
    public var intensityLevel: Int {
        if recordingCount == 0 {
            return 0
        } else if recordingCount == 1 {
            return 1
        } else if recordingCount <= 3 {
            return 2
        } else if recordingCount <= 5 {
            return 3
        } else {
            return 4
        }
    }

    /// Format total duration for display
    public var formattedDuration: String {
        let hours = totalDurationSeconds / 3600
        let minutes = (totalDurationSeconds % 3600) / 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }
}
