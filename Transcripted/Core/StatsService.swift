import Foundation
import Combine

/// Service for calculating and providing stats for the dashboard
/// Provides reactive stats updates via Combine publishers
@available(macOS 14.0, *)
@MainActor
final class StatsService: ObservableObject {

    static let shared = StatsService()

    // MARK: - Published Stats (for UI binding)

    /// Total hours transcribed (all time)
    @Published private(set) var totalHoursTranscribed: Double = 0

    /// Total number of recordings
    @Published private(set) var totalRecordings: Int = 0

    /// Current recording streak (consecutive days)
    @Published private(set) var currentStreak: Int = 0

    /// Longest streak ever
    @Published private(set) var longestStreak: Int = 0

    /// Average meeting duration in seconds
    @Published private(set) var averageMeetingDuration: TimeInterval = 0

    /// Monthly activity for heat map
    @Published private(set) var monthlyActivity: [String: DailyActivity] = [:]

    /// Recent transcripts (last 3)
    @Published private(set) var recentTranscripts: [RecordingMetadata] = []

    /// Stats for last 30 days
    @Published private(set) var last30DaysRecordings: Int = 0
    @Published private(set) var last30DaysDuration: Int = 0
    /// Active days in current month
    @Published private(set) var activeDaysThisMonth: Int = 0

    /// Motivational message based on stats
    @Published private(set) var motivationalMessage: String = ""

    /// Today's stats (for menu bar)
    @Published private(set) var todayRecordings: Int = 0
    @Published private(set) var todayDurationSeconds: Int = 0

    /// This week's stats (for menu bar)
    @Published private(set) var weekRecordings: Int = 0
    @Published private(set) var weekDurationSeconds: Int = 0

    // MARK: - Private

    private let database = StatsDatabase.shared
    private var refreshTask: Task<Void, Never>?

    private init() {
        Task {
            await refreshStats()
        }
    }

    // MARK: - Public Methods

    /// Refresh all stats from database
    func refreshStats() async {
        // Get all-time stats
        totalRecordings = database.getTotalRecordingsCount()

        let totalSeconds = database.getTotalDurationSeconds()
        totalHoursTranscribed = Double(totalSeconds) / 3600.0

        // Calculate average duration
        if totalRecordings > 0 {
            averageMeetingDuration = Double(totalSeconds) / Double(totalRecordings)
        }

        // Get today's stats (for menu bar)
        let todayStats = database.getStatsForLastDays(0)
        todayRecordings = todayStats.recordings
        todayDurationSeconds = todayStats.durationSeconds

        // Get this week's stats (for menu bar)
        let weekStats = database.getStatsForLastDays(7)
        weekRecordings = weekStats.recordings
        weekDurationSeconds = weekStats.durationSeconds

        // Get last 30 days stats
        let thirtyDayStats = database.getStatsForLastDays(30)
        last30DaysRecordings = thirtyDayStats.recordings
        last30DaysDuration = thirtyDayStats.durationSeconds
        // Get monthly activity for heat map
        monthlyActivity = database.getDailyActivity(for: Date())
        activeDaysThisMonth = monthlyActivity.values.filter { $0.recordingCount > 0 }.count

        // Calculate streaks
        calculateStreaks()

        // Get recent transcripts
        let allRecordings = database.getAllRecordings()
        recentTranscripts = Array(allRecordings.prefix(3))

        // Update motivational message
        updateMotivationalMessage()
    }

    /// Record a new session (called after transcription completes)
    func recordSession(_ metadata: RecordingMetadata) async {
        database.recordSession(metadata)
        await refreshStats()
    }

    /// Get activity for a specific month
    func getActivityForMonth(_ date: Date) -> [String: DailyActivity] {
        return database.getDailyActivity(for: date)
    }

    /// Get all recordings
    func getAllRecordings() -> [RecordingMetadata] {
        return database.getAllRecordings()
    }

    /// Check if database has data (for migration prompt)
    func hasExistingData() -> Bool {
        return totalRecordings > 0
    }

    // MARK: - Private Methods

    private func calculateStreaks() {
        let activeDates = database.getAllActiveDates()

        guard !activeDates.isEmpty else {
            currentStreak = 0
            longestStreak = 0
            return
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"

        let calendar = Calendar.current
        let today = dateFormatter.string(from: Date())
        let yesterday = dateFormatter.string(from: calendar.date(byAdding: .day, value: -1, to: Date()) ?? Date())

        // Calculate current streak
        var streak = 0
        var checkDate = Date()

        // Start counting from today or yesterday if today has no activity
        if !activeDates.contains(today) && !activeDates.contains(yesterday) {
            currentStreak = 0
        } else {
            // If today has activity, start from today; otherwise start from yesterday
            if !activeDates.contains(today) {
                checkDate = calendar.date(byAdding: .day, value: -1, to: Date()) ?? Date()
            }

            while true {
                let checkDateStr = dateFormatter.string(from: checkDate)
                if activeDates.contains(checkDateStr) {
                    streak += 1
                    checkDate = calendar.date(byAdding: .day, value: -1, to: checkDate) ?? Date()
                } else {
                    break
                }
            }
            currentStreak = streak
        }

        // Calculate longest streak
        var longest = 0
        var currentRun = 0
        var previousDate: Date?

        // Sort dates in ascending order
        let sortedDates = activeDates.sorted()

        for dateStr in sortedDates {
            guard let date = dateFormatter.date(from: dateStr) else { continue }

            if let previous = previousDate {
                let daysDiff = calendar.dateComponents([.day], from: previous, to: date).day ?? 0
                if daysDiff == 1 {
                    currentRun += 1
                } else {
                    longest = max(longest, currentRun)
                    currentRun = 1
                }
            } else {
                currentRun = 1
            }

            previousDate = date
        }

        longest = max(longest, currentRun)
        longestStreak = longest
    }

    private func updateMotivationalMessage() {
        if currentStreak >= 7 {
            motivationalMessage = "You're on fire! \(currentStreak) days in a row of capturing meetings."
        } else if currentStreak >= 3 {
            motivationalMessage = "Great momentum! Keep the streak going."
        } else if last30DaysRecordings >= 20 {
            motivationalMessage = "Impressive! You've captured \(last30DaysRecordings) meetings this month."
        } else if last30DaysRecordings >= 10 {
            motivationalMessage = "Solid month so far with \(last30DaysRecordings) meetings recorded."
        } else if last30DaysRecordings > 0 {
            motivationalMessage = "Every meeting captured is knowledge preserved."
        } else if totalRecordings > 0 {
            motivationalMessage = "Ready to capture your next meeting?"
        } else {
            motivationalMessage = "Start your first recording to see your stats!"
        }
    }

    // MARK: - Formatted Stats for Display

    /// Format total hours for display (e.g., "14.5h" or "2h 30m")
    var formattedTotalHours: String {
        if totalHoursTranscribed >= 1 {
            return String(format: "%.1fh", totalHoursTranscribed)
        } else {
            let minutes = Int(totalHoursTranscribed * 60)
            return "\(minutes)m"
        }
    }

    /// Format last 30 days duration
    var formattedLast30DaysDuration: String {
        let hours = last30DaysDuration / 3600
        let minutes = (last30DaysDuration % 3600) / 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }

    /// Compact duration for menu bar (e.g., "0m", "47m", "1.5h", "2h")
    static func formatDurationCompact(_ seconds: Int) -> String {
        let hours = Double(seconds) / 3600.0
        if hours >= 1 {
            let rounded = (hours * 10).rounded() / 10
            if rounded == rounded.rounded() {
                return "\(Int(rounded))h"
            }
            return String(format: "%.1fh", rounded)
        }
        return "\(seconds / 60)m"
    }

    /// Format today's duration compactly
    var formattedTodayDuration: String {
        Self.formatDurationCompact(todayDurationSeconds)
    }

    /// Format this week's duration (e.g., "5h 30m")
    var formattedWeekDuration: String {
        let hours = weekDurationSeconds / 3600
        let minutes = (weekDurationSeconds % 3600) / 60
        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        return "\(minutes)m"
    }

    /// Format average meeting duration
    var formattedAverageDuration: String {
        let minutes = Int(averageMeetingDuration / 60)
        if minutes >= 60 {
            let hours = minutes / 60
            let remainingMinutes = minutes % 60
            return "\(hours)h \(remainingMinutes)m"
        }
        return "\(minutes)m"
    }
}

// MARK: - Convenience Extensions

@available(macOS 14.0, *)
extension StatsService {

    /// Create a RecordingMetadata from local transcription result
    static func createMetadata(
        from result: TranscriptionResult,
        transcriptPath: String?,
        title: String?
    ) -> RecordingMetadata {
        let totalWordCount = result.micWordCount + result.systemWordCount
        let totalSpeakers = result.micSpeakerCount + result.systemSpeakerCount

        return RecordingMetadata(
            date: Date(),
            durationSeconds: Int(result.duration),
            wordCount: totalWordCount,
            speakerCount: totalSpeakers,
            processingTimeMs: Int(result.processingTime * 1000),
            transcriptPath: transcriptPath,
            title: title
        )
    }

}
