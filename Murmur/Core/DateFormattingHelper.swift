import Foundation

/// Centralized date formatting utilities with cached formatters for performance
/// Eliminates duplicate DateFormatter initialization across the codebase
enum DateFormattingHelper {

    // MARK: - Cached Formatters (thread-safe, reused)

    /// Filename format with milliseconds: "2024-01-15_14-30-45-123"
    private static let filenamePreciseFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
        return formatter
    }()

    /// Filename format without milliseconds: "2024-01-15_14-30-45"
    private static let filenameFormatter: DateFormatter = {
        let formatter = DateFormatter()
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

    /// Time only: "14:30:45"
    private static let timeOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    /// ISO date only: "2024-01-15"
    private static let isoDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    // MARK: - Public API

    /// Format for audio filenames with millisecond precision
    /// Example: "2024-01-15_14-30-45-123"
    static func formatFilenamePrecise(_ date: Date) -> String {
        filenamePreciseFormatter.string(from: date)
    }

    /// Format for transcript filenames without milliseconds
    /// Example: "2024-01-15_14-30-45"
    static func formatFilename(_ date: Date) -> String {
        filenameFormatter.string(from: date)
    }

    /// Format for user-facing display (medium date, short time)
    /// Example: "Jan 15, 2024 at 2:30 PM"
    static func formatDisplay(_ date: Date) -> String {
        displayFormatter.string(from: date)
    }

    /// Format time only
    /// Example: "14:30:45"
    static func formatTimeOnly(_ date: Date) -> String {
        timeOnlyFormatter.string(from: date)
    }

    /// Format ISO date only
    /// Example: "2024-01-15"
    static func formatISODate(_ date: Date) -> String {
        isoDateFormatter.string(from: date)
    }

    /// Format a TimeInterval as MM:SS
    /// Example: 125.0 -> "02:05"
    static func formatDuration(_ interval: TimeInterval) -> String {
        let minutes = Int(interval) / 60
        let seconds = Int(interval) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    /// Format a TimeInterval as M:SS (no leading zero on minutes)
    /// Example: 125.0 -> "2:05"
    static func formatDurationCompact(_ interval: TimeInterval) -> String {
        let minutes = Int(interval) / 60
        let seconds = Int(interval) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
