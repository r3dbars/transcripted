import Foundation

// MARK: - Data Models

/// Metadata for a recording session
struct RecordingMetadata: Identifiable {
    let id: String
    let date: Date
    let durationSeconds: Int
    let wordCount: Int
    let speakerCount: Int
    let processingTimeMs: Int
    let transcriptPath: String?
    let title: String?

    init(
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
    var formattedDuration: String {
        let hours = durationSeconds / 3600
        let minutes = (durationSeconds % 3600) / 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }

    /// Display title (fallback to date if no title)
    var displayTitle: String {
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
struct DailyActivity {
    let date: String // "yyyy-MM-dd"
    let recordingCount: Int
    let totalDurationSeconds: Int
    let actionItemsCount: Int

    /// Intensity level (0-4) for heat map
    var intensityLevel: Int {
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
    var formattedDuration: String {
        let hours = totalDurationSeconds / 3600
        let minutes = (totalDurationSeconds % 3600) / 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }
}
