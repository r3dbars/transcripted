// DictationTranscriptWriter.swift
// Persists completed dictations as markdown artifacts for later agent/context use.

import AppKit
import Foundation

struct SavedDictationTranscript {
    let url: URL
    let title: String
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
    private static let filenameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
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

    private static let detailFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    @discardableResult
    static func save(
        text: String,
        sourceApp: NSRunningApplication?,
        delivery: DictationDelivery,
        createdAt: Date = Date()
    ) throws -> SavedDictationTranscript {
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = buildTitle(from: normalizedText, createdAt: createdAt)
        let slug = filenameFormatter.string(from: createdAt)
        let url = DictationStoragePaths.transcriptsFolder
            .appendingPathComponent("Dictation_\(slug).md", isDirectory: false)

        let sourceAppName = sourceApp?.localizedName ?? "Unknown"
        let sourceBundleID = sourceApp?.bundleIdentifier ?? ""
        let wordCount = normalizedText.split(whereSeparator: \.isWhitespace).count
        let characterCount = normalizedText.count

        let escapedTitle = title.replacingOccurrences(of: "\"", with: "'")
        let escapedAppName = sourceAppName.replacingOccurrences(of: "\"", with: "'")

        let body = """
        ---
        title: "\(escapedTitle)"
        date: \(frontmatterDateFormatter.string(from: createdAt))
        time: \(frontmatterTimeFormatter.string(from: createdAt))
        capture_type: dictation
        source_app_name: "\(escapedAppName)"
        source_app_bundle_id: "\(sourceBundleID)"
        delivery: \(delivery.rawValue)
        word_count: \(wordCount)
        character_count: \(characterCount)
        ---

        # \(title)

        Dictated \(detailFormatter.string(from: createdAt))  •  \(wordCount) \(wordCount == 1 ? "word" : "words")  •  \(delivery.summaryText)

        ## Dictation

        \(normalizedText)
        """

        try body.write(to: url, atomically: true, encoding: .utf8)
        return SavedDictationTranscript(url: url, title: title)
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
