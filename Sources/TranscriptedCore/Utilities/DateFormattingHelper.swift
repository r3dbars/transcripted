import Foundation

/// Centralized date formatting utilities with cached formatters for performance
/// Eliminates duplicate DateFormatter initialization across the codebase
public enum DateFormattingHelper {

    // MARK: - Cached Formatters (thread-safe, reused)

    /// Filename format with milliseconds: "2024-01-15_14-30-45-123"
    private static let filenamePreciseFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
        return formatter
    }()

    /// Filename format without milliseconds: "2024-01-15_14-30-45"
    private static let filenameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter
    }()

    /// Display format: "Jan 15, 2024 at 2:30 PM"
    private static let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    /// Day stamp format: "2024-01-15"
    private static let dayStampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// ISO8601 without fractional seconds: "2024-01-15T14:30:45Z"
    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// ISO8601 with fractional seconds: "2024-01-15T14:30:45.123Z"
    private static let iso8601FractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    // MARK: - Public API

    /// Format for audio filenames with millisecond precision
    /// Example: "2024-01-15_14-30-45-123"
    public static func formatFilenamePrecise(_ date: Date) -> String {
        filenamePreciseFormatter.string(from: date)
    }

    /// Format for transcript filenames without milliseconds
    /// Example: "2024-01-15_14-30-45"
    public static func formatFilename(_ date: Date) -> String {
        filenameFormatter.string(from: date)
    }

    /// Format for user-facing display (medium date, short time)
    /// Example: "Jan 15, 2024 at 2:30 PM"
    public static func formatDisplay(_ date: Date) -> String {
        displayFormatter.string(from: date)
    }

    /// Format a TimeInterval as MM:SS
    /// Example: 125.0 -> "02:05"
    public static func formatDuration(_ interval: TimeInterval) -> String {
        let minutes = Int(interval) / 60
        let seconds = Int(interval) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    /// Format a day stamp for filenames and frontmatter dates.
    /// Example: "2024-01-15"
    public static func formatDayStamp(_ date: Date) -> String {
        dayStampFormatter.string(from: date)
    }

    /// Parse a day stamp produced by `formatDayStamp`.
    /// Example: "2024-01-15" -> Date
    public static func parseDayStamp(_ string: String) -> Date? {
        dayStampFormatter.date(from: string)
    }

    /// Format an ISO8601 timestamp without fractional seconds.
    /// Example: "2024-01-15T14:30:45Z"
    public static func formatISO8601(_ date: Date) -> String {
        iso8601Formatter.string(from: date)
    }

    /// Format an ISO8601 timestamp with millisecond fractional seconds.
    /// Example: "2024-01-15T14:30:45.123Z"
    public static func formatISO8601WithFractionalSeconds(_ date: Date) -> String {
        iso8601FractionalFormatter.string(from: date)
    }
}
