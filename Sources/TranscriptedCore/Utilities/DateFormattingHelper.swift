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

    /// Time-only format for transcript frontmatter: "14:30:45"
    private static let timeOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    /// ISO date-only format for transcript frontmatter: "2024-01-15"
    private static let isoDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let formatterQueue = DispatchQueue(label: "TranscriptedCore.DateFormattingHelper.formatters")

    // MARK: - Public API

    /// Format for audio filenames with millisecond precision
    /// Example: "2024-01-15_14-30-45-123"
    public static func formatFilenamePrecise(_ date: Date) -> String {
        formatterQueue.sync {
            filenamePreciseFormatter.string(from: date)
        }
    }

    /// Format for transcript filenames without milliseconds
    /// Example: "2024-01-15_14-30-45"
    public static func formatFilename(_ date: Date) -> String {
        formatterQueue.sync {
            filenameFormatter.string(from: date)
        }
    }

    /// Format for user-facing display (medium date, short time)
    /// Example: "Jan 15, 2024 at 2:30 PM"
    public static func formatDisplay(_ date: Date) -> String {
        formatterQueue.sync {
            displayFormatter.string(from: date)
        }
    }

    /// Format for transcript frontmatter time values
    /// Example: "14:30:45"
    public static func formatTimeOnly(_ date: Date) -> String {
        formatterQueue.sync {
            timeOnlyFormatter.string(from: date)
        }
    }

    /// Parse transcript frontmatter time values
    /// Example: "14:30:45"
    public static func parseTimeOnly(_ value: String) -> Date? {
        formatterQueue.sync {
            timeOnlyFormatter.date(from: value)
        }
    }

    /// Format for transcript frontmatter date values
    /// Example: "2024-01-15"
    public static func formatISODate(_ date: Date) -> String {
        formatterQueue.sync {
            isoDateFormatter.string(from: date)
        }
    }

    /// Format a TimeInterval as MM:SS
    /// Example: 125.0 -> "02:05"
    public static func formatDuration(_ interval: TimeInterval) -> String {
        let minutes = Int(interval) / 60
        let seconds = Int(interval) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
