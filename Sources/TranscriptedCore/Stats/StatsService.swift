import Foundation
import Combine

/// Service for calculating and providing stats for the dashboard
/// Provides reactive stats updates via Combine publishers
@available(macOS 14.0, *)
@MainActor
public final class StatsService: ObservableObject {

    public static let shared = StatsService()

    // MARK: - Published Stats (for UI binding)

    /// Total hours transcribed (all time)
    @Published public private(set) var totalHoursTranscribed: Double = 0

    /// Total number of recordings
    @Published public private(set) var totalRecordings: Int = 0

    /// Current recording streak (consecutive days)
    @Published public private(set) var currentStreak: Int = 0

    /// Longest streak ever
    @Published public private(set) var longestStreak: Int = 0

    /// Average meeting duration in seconds
    @Published public private(set) var averageMeetingDuration: TimeInterval = 0

    /// Monthly activity for heat map
    @Published public private(set) var monthlyActivity: [String: DailyActivity] = [:]

    /// Recent transcripts (last 3)
    @Published public private(set) var recentTranscripts: [RecordingMetadata] = []

    /// Stats for last 30 days
    @Published public private(set) var last30DaysRecordings: Int = 0
    @Published public private(set) var last30DaysDuration: Int = 0
    /// Active days in current month
    @Published public private(set) var activeDaysThisMonth: Int = 0

    /// Motivational message based on stats
    @Published public private(set) var motivationalMessage: String = ""

    /// Today's stats (for menu bar)
    @Published public private(set) var todayRecordings: Int = 0
    @Published public private(set) var todayDurationSeconds: Int = 0

    /// This week's stats (for menu bar)
    @Published public private(set) var weekRecordings: Int = 0
    @Published public private(set) var weekDurationSeconds: Int = 0

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
    ///
    /// The SQLite reads and streak scan run off the main actor (StatsDatabase
    /// serializes access on its own utility queue), so opening the settings
    /// window or refreshing the dashboard never blocks the main thread on
    /// database I/O. Published properties are updated back on the main actor
    /// once the snapshot is ready. Overlapping calls are serialized: a new
    /// refresh waits for the in-flight one instead of stacking concurrent
    /// query bursts.
    public func refreshStats() async {
        let previousRefresh = refreshTask
        let database = self.database
        let task = Task { [weak self] in
            await previousRefresh?.value
            let snapshot = await Task.detached(priority: .utility) {
                StatsSnapshot(database: database)
            }.value
            self?.apply(snapshot)
        }
        refreshTask = task
        await task.value
    }

    /// Record a new session (called after transcription completes)
    public func recordSession(_ metadata: RecordingMetadata) async {
        database.recordSession(metadata)
        await refreshStats()
    }

    /// Get activity for a specific month
    public func getActivityForMonth(_ date: Date) -> [String: DailyActivity] {
        return database.getDailyActivity(for: date)
    }

    /// Get all recordings
    public func getAllRecordings() -> [RecordingMetadata] {
        return database.getAllRecordings()
    }

    /// Check if database has data (for migration prompt)
    public func hasExistingData() -> Bool {
        return totalRecordings > 0
    }

    // MARK: - Private Methods

    /// Publish a background-built snapshot to the observed properties (main actor).
    private func apply(_ snapshot: StatsSnapshot) {
        totalRecordings = snapshot.totalRecordings
        totalHoursTranscribed = snapshot.totalHoursTranscribed
        if let averageDuration = snapshot.averageMeetingDuration {
            averageMeetingDuration = averageDuration
        }
        todayRecordings = snapshot.todayRecordings
        todayDurationSeconds = snapshot.todayDurationSeconds
        weekRecordings = snapshot.weekRecordings
        weekDurationSeconds = snapshot.weekDurationSeconds
        last30DaysRecordings = snapshot.last30DaysRecordings
        last30DaysDuration = snapshot.last30DaysDuration
        monthlyActivity = snapshot.monthlyActivity
        activeDaysThisMonth = snapshot.activeDaysThisMonth
        currentStreak = snapshot.currentStreak
        longestStreak = snapshot.longestStreak
        recentTranscripts = snapshot.recentTranscripts
        updateMotivationalMessage()
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
    public var formattedTotalHours: String {
        if totalHoursTranscribed >= 1 {
            return String(format: "%.1fh", totalHoursTranscribed)
        } else {
            let minutes = Int(totalHoursTranscribed * 60)
            return "\(minutes)m"
        }
    }

    /// Format last 30 days duration
    public var formattedLast30DaysDuration: String {
        let hours = last30DaysDuration / 3600
        let minutes = (last30DaysDuration % 3600) / 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }

    /// Compact duration for menu bar (e.g., "0m", "47m", "1.5h", "2h")
    public static func formatDurationCompact(_ seconds: Int) -> String {
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
    public var formattedTodayDuration: String {
        Self.formatDurationCompact(todayDurationSeconds)
    }

    /// Format this week's duration (e.g., "5h 30m")
    public var formattedWeekDuration: String {
        let hours = weekDurationSeconds / 3600
        let minutes = (weekDurationSeconds % 3600) / 60
        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        return "\(minutes)m"
    }

    /// Format average meeting duration
    public var formattedAverageDuration: String {
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
    public nonisolated static func createMetadata(
        from result: TranscriptionResult,
        captureId: UUID,
        transcriptPath: String?,
        title: String?,
        date: Date = Date()
    ) -> RecordingMetadata {
        let totalWordCount = result.micWordCount + result.systemWordCount
        let totalSpeakers = result.micSpeakerCount + result.systemSpeakerCount

        return RecordingMetadata(
            id: captureId.uuidString,
            date: date,
            durationSeconds: Int(result.duration),
            wordCount: totalWordCount,
            speakerCount: totalSpeakers,
            processingTimeMs: Int(result.processingTime * 1000),
            transcriptPath: transcriptPath,
            title: title
        )
    }

}

// MARK: - Background Snapshot

/// Everything `StatsService.refreshStats()` publishes, computed in one pass.
/// Built off the main actor so the SQLite reads and streak scan never block
/// the main thread; `StatsDatabase` serializes access on its own queue.
@available(macOS 14.0, *)
private struct StatsSnapshot {
    let totalRecordings: Int
    let totalHoursTranscribed: Double
    /// nil when there are no recordings, so the previously published average is kept
    let averageMeetingDuration: TimeInterval?
    let todayRecordings: Int
    let todayDurationSeconds: Int
    let weekRecordings: Int
    let weekDurationSeconds: Int
    let last30DaysRecordings: Int
    let last30DaysDuration: Int
    let monthlyActivity: [String: DailyActivity]
    let activeDaysThisMonth: Int
    let currentStreak: Int
    let longestStreak: Int
    let recentTranscripts: [RecordingMetadata]

    /// Cached "yyyy-MM-dd" formatter reused across refreshes and streak-scan
    /// iterations. DateFormatter is expensive to allocate and formatting is
    /// thread-safe on modern macOS.
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    init(database: StatsDatabase) {
        // Get all-time stats
        totalRecordings = database.getTotalRecordingsCount()

        let totalSeconds = database.getTotalDurationSeconds()
        totalHoursTranscribed = Double(totalSeconds) / 3600.0

        // Calculate average duration
        averageMeetingDuration = totalRecordings > 0
            ? Double(totalSeconds) / Double(totalRecordings)
            : nil

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
        let streaks = Self.calculateStreaks(activeDates: database.getAllActiveDates())
        currentStreak = streaks.current
        longestStreak = streaks.longest

        // Get recent transcripts
        recentTranscripts = database.getRecentRecordings(limit: 3)
    }

    private static func calculateStreaks(activeDates: [String]) -> (current: Int, longest: Int) {
        guard !activeDates.isEmpty else {
            return (current: 0, longest: 0)
        }

        let dateFormatter = dayFormatter
        let calendar = Calendar.current
        let activeDateSet = Set(activeDates)
        let today = dateFormatter.string(from: Date())
        let yesterday = dateFormatter.string(from: calendar.date(byAdding: .day, value: -1, to: Date()) ?? Date())

        // Calculate current streak, counting from today or yesterday if today
        // has no activity yet
        var current = 0
        if activeDateSet.contains(today) || activeDateSet.contains(yesterday) {
            var checkDate = Date()
            if !activeDateSet.contains(today) {
                checkDate = calendar.date(byAdding: .day, value: -1, to: Date()) ?? Date()
            }

            while activeDateSet.contains(dateFormatter.string(from: checkDate)) {
                current += 1
                checkDate = calendar.date(byAdding: .day, value: -1, to: checkDate) ?? Date()
            }
        }

        // Calculate longest streak over dates sorted in ascending order
        var longest = 0
        var currentRun = 0
        var previousDate: Date?

        for dateStr in activeDates.sorted() {
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
        return (current: current, longest: longest)
    }
}
