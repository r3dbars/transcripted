// DictationTranscriptWriter.swift
// Persists completed dictations as markdown artifacts for later agent/context use.

import AppKit
import Foundation

struct SavedDictationTranscript {
    let url: URL
    let title: String
    let sidecarURL: URL?
}

enum DictationDelivery: String {
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

enum DictationTranscriptWriter {
    private static let dayFilenameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let frontmatterDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let frontmatterTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static let sectionTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "h:mm a"
        return formatter
    }()

    private static let detailFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static let dayTitleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateStyle = .long
        formatter.timeStyle = .none
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
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = buildTitle(from: normalizedText, createdAt: createdAt)
        let folder = directory ?? DictationStoragePaths.transcriptsFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = dailyFileURL(for: createdAt, in: folder)

        let sourceAppName = sourceApp?.localizedName ?? "Unknown"
        let sourceBundleID = sourceApp?.bundleIdentifier ?? ""
        let wordCount = normalizedText.split(whereSeparator: \.isWhitespace).count
        let characterCount = normalizedText.count
        let dayHeader = dailyHeader(for: createdAt)
        let section = dailySection(
            title: title,
            text: normalizedText,
            createdAt: createdAt,
            sourceAppName: sourceAppName,
            sourceBundleID: sourceBundleID,
            delivery: delivery,
            wordCount: wordCount,
            characterCount: characterCount
        )

        let body: String
        if FileManager.default.fileExists(atPath: url.path),
           let existing = try? String(contentsOf: url, encoding: .utf8),
           !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let separator = existing.hasSuffix("\n\n") ? "" : "\n\n"
            body = existing + separator + section
        } else {
            body = dayHeader + "\n\n" + section
        }

        try body.write(to: url, atomically: true, encoding: .utf8)
        FileManager.default.restrictFileToOwnerOnly(at: url)

        let sidecarURL = try? DictationAgentOutput.appendEntry(
            title: title,
            text: normalizedText,
            sourceAppName: sourceAppName,
            sourceAppBundleId: sourceBundleID.isEmpty ? nil : sourceBundleID,
            delivery: delivery,
            wordCount: wordCount,
            characterCount: characterCount,
            createdAt: createdAt,
            markdownURL: url,
            directory: folder
        )

        return SavedDictationTranscript(url: url, title: title, sidecarURL: sidecarURL)
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
        date: \(frontmatterDateFormatter.string(from: date))
        capture_type: dictation_day
        ---

        # Dictations for \(dayTitleFormatter.string(from: date))
        """
    }

    private static func dailySection(
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

        Dictated \(detailFormatter.string(from: createdAt))  •  \(wordCount) \(wordCount == 1 ? "word" : "words")  •  \(delivery.summaryText)

        Source app: \(sourceAppName)\(bundleLine)
        Timestamp: \(frontmatterDateFormatter.string(from: createdAt)) \(frontmatterTimeFormatter.string(from: createdAt))
        Characters: \(characterCount)

        \(text)
        """
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

        let fallbackFormatter = DateFormatter()
        fallbackFormatter.locale = Locale.current
        fallbackFormatter.dateFormat = "MMM d 'at' h:mm a"
        return "Dictation \(fallbackFormatter.string(from: createdAt))"
    }
}
