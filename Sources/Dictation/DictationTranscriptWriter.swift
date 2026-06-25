// DictationTranscriptWriter.swift
// Persists completed dictations as markdown artifacts for later agent/context use.

import AppKit
import Foundation

struct SavedDictationTranscript: Sendable {
    let url: URL
    let title: String
}

enum DictationDelivery: String, Sendable {
    case pasted
    case copied
    case failed

    var summaryText: String {
        switch self {
        case .pasted: return "Pasted"
        case .copied: return "Copied to clipboard"
        case .failed: return "Saved only"
        }
    }
}

enum DictationTranscriptMutationLock {
    private static let writeLock = NSLock()

    static func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        writeLock.lock()
        defer { writeLock.unlock() }
        return try operation()
    }
}

enum DictationTranscriptWriter {
    private static let dayFilenameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let entryIdFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter
    }()

    private static let sectionTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "h:mm a"
        return formatter
    }()

    private static let dayTitleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter
    }()

    private static let fallbackTitleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = "MMM d 'at' h:mm a"
        return formatter
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    @discardableResult
    static func save(
        text: String,
        sourceApp: NSRunningApplication?,
        delivery: DictationDelivery,
        createdAt: Date = Date(),
        directory: URL? = nil
    ) throws -> SavedDictationTranscript {
        try save(
            text: text,
            sourceAppName: sourceApp?.localizedName ?? "Unknown",
            sourceBundleID: sourceApp?.bundleIdentifier,
            delivery: delivery,
            createdAt: createdAt,
            directory: directory
        )
    }

    @discardableResult
    static func save(
        text: String,
        sourceAppName: String,
        sourceBundleID: String?,
        delivery: DictationDelivery,
        createdAt: Date = Date(),
        directory: URL? = nil
    ) throws -> SavedDictationTranscript {
        try DictationTranscriptMutationLock.withLock {
            try saveLocked(
                text: text,
                sourceAppName: sourceAppName,
                sourceBundleID: sourceBundleID,
                delivery: delivery,
                createdAt: createdAt,
                directory: directory
            )
        }
    }

    private static func saveLocked(
        text: String,
        sourceAppName: String,
        sourceBundleID: String?,
        delivery: DictationDelivery,
        createdAt: Date,
        directory: URL?
    ) throws -> SavedDictationTranscript {
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = buildTitle(from: normalizedText, createdAt: createdAt)
        let folder = directory ?? DictationStoragePaths.transcriptsFolder
        if directory != nil {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let url = dailyFileURL(for: createdAt, in: folder)

        let sourceBundleID = sourceBundleID ?? ""
        let wordCount = normalizedText.split(whereSeparator: \.isWhitespace).count
        let characterCount = normalizedText.count
        let entryID = "dictation-\(entryIdFormatter.string(from: createdAt))-\(UUID().uuidString.lowercased())"
        let dayHeader = dailyHeader(for: createdAt)
        let section = dailySection(
            entryID: entryID,
            title: title,
            text: normalizedText,
            createdAt: createdAt,
            sourceAppName: sourceAppName,
            sourceBundleID: sourceBundleID,
            delivery: delivery,
            wordCount: wordCount,
            characterCount: characterCount
        )

        if hasExistingContent(at: url) {
            try appendSection(section, to: url)
        } else {
            let body = dayHeader + "\n\n" + section
            try body.write(to: url, atomically: true, encoding: .utf8)
        }

        FileManager.default.restrictFileToOwnerOnly(at: url)

        return SavedDictationTranscript(url: url, title: title)
    }

    static func dailyFileURL(for date: Date, in directory: URL) -> URL {
        let slug = dayFilenameFormatter.string(from: date)
        return directory.appendingPathComponent("Dictations_\(slug).md", isDirectory: false)
    }

    private static func dailyHeader(for date: Date) -> String {
        let escapedTitle = "Dictations for \(dayTitleFormatter.string(from: date))"
            .replacingOccurrences(of: "\"", with: "'")

        return """
        ---
        title: "\(escapedTitle)"
        date: \(dayFilenameFormatter.string(from: date))
        capture_type: dictation_day
        ---

        # Dictations for \(dayTitleFormatter.string(from: date))
        """
    }

    private static func dailySection(
        entryID: String,
        title: String,
        text: String,
        createdAt: Date,
        sourceAppName: String,
        sourceBundleID: String,
        delivery: DictationDelivery,
        wordCount: Int,
        characterCount: Int
    ) -> String {
        let headingTitle = title.replacingOccurrences(of: "\n", with: " ")
        let bundleLine = sourceBundleID.isEmpty ? "" : "\nBundle ID: `\(sourceBundleID)`"

        return """
        ## \(sectionTimeFormatter.string(from: createdAt)) - \(headingTitle)

        Entry ID: `\(entryID)`
        Captured: \(isoFormatter.string(from: createdAt))
        Source app: \(sourceAppName)\(bundleLine)
        Delivery: \(delivery.rawValue)
        Words: \(wordCount)
        Characters: \(characterCount)

        \(text)
        """
    }

    private static func hasExistingContent(at url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize else {
            return false
        }
        return size > 0
    }

    // Append by rewriting the whole day file atomically (write-temp-then-rename) rather
    // than seeking to the end of the existing file and writing in place. A crash or
    // interruption part way through an in-place `FileHandle` write would leave a half-written
    // section glued onto the day's data and corrupt every earlier entry in the file. With an
    // atomic write the prior content survives untouched until the new file is renamed into
    // place, so a failed write can lose the in-flight section but never the existing day.
    private static func appendSection(_ section: String, to url: URL) throws {
        let existing = try String(contentsOf: url, encoding: .utf8)
        let separator = existing.hasSuffix("\n\n") ? "" : "\n\n"
        let combined = existing + separator + section
        try combined.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func buildTitle(from text: String, createdAt: Date) -> String {
        let words = text
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .prefix(7)
            .map(String.init)

        let candidate = words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.count >= 10 {
            return candidate
        }

        return "Dictation \(fallbackTitleFormatter.string(from: createdAt))"
    }
}
