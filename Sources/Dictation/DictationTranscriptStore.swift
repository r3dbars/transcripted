// DictationTranscriptStore.swift
// Shared save/read seam for saved dictation markdown artifacts.

import AppKit
import Foundation

extension Notification.Name {
    static let dictationTranscriptDidSave = Notification.Name("Transcripted.DictationTranscriptDidSave")
    static let dictationNoSpeechDetected = Notification.Name("Transcripted.DictationNoSpeechDetected")
}

struct SavedDictationEntry: Identifiable, Sendable {
    let url: URL
    let entryID: String?
    let title: String
    let text: String
    let createdAt: Date
    let delivery: DictationDelivery
    let sourceAppName: String
    let sourceAppBundleID: String?

    var id: String {
        if let entryID, !entryID.isEmpty {
            return "\(url.path)#\(entryID)"
        }
        return "\(url.path)#\(createdAt.timeIntervalSince1970)#\(title)"
    }
}

struct DictationTranscriptCounts: Sendable {
    let total: Int
    let today: Int
    let totalWords: Int
}

enum DictationTranscriptStore {
    private static let dictationDayPrefix = "Dictations_"

    private static let iso8601Formatters: [ISO8601DateFormatter] = {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]

        return [fractional, standard]
    }()
    private static let iso8601FormatterQueue = DispatchQueue(label: "Transcripted.DictationTranscriptStore.iso8601Formatters")

    @discardableResult
    static func save(
        text: String,
        sourceApp: NSRunningApplication?,
        delivery: DictationDelivery,
        createdAt: Date = Date(),
        directory: URL? = nil
    ) throws -> SavedDictationTranscript {
        let saved = try DictationTranscriptWriter.save(
            text: text,
            sourceApp: sourceApp,
            delivery: delivery,
            createdAt: createdAt,
            directory: directory
        )
        NotificationCenter.default.post(name: .dictationTranscriptDidSave, object: saved.url)
        return saved
    }

    static func latestSavedText(directory: URL? = nil) -> String? {
        latestSavedDictation(directory: directory)?.text
    }

    static func latestSavedDictation(directory: URL? = nil) -> SavedDictationEntry? {
        recentSavedDictations(limit: 1, directory: directory).first
    }

    static func savedDictationCounts(directory: URL? = nil, today: Date = Date()) -> DictationTranscriptCounts {
        let folder = directory ?? DictationStoragePaths.transcriptsFolder
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let files = try? FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
              ) else {
            return DictationTranscriptCounts(total: 0, today: 0, totalWords: 0)
        }

        let todayURL = DictationTranscriptWriter.dailyFileURL(for: today, in: folder)
        var total = 0
        var todayCount = 0
        var totalWords = 0

        for file in files where isDictationDayFile(file) {
            if Task.isCancelled { break }
            let stats = fileStats(in: file)
            total += stats.entries
            totalWords += stats.words
            if file.lastPathComponent == todayURL.lastPathComponent {
                todayCount = stats.entries
            }
        }

        return DictationTranscriptCounts(total: total, today: todayCount, totalWords: totalWords)
    }

    static func recentSavedDictations(limit: Int = 5, directory: URL? = nil) -> [SavedDictationEntry] {
        guard limit > 0 else { return [] }

        let folder = directory ?? DictationStoragePaths.transcriptsFolder
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let files = try? FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        let dayFiles = files
            .filter { isDictationDayFile($0) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }

        var collectedEntries: [SavedDictationEntry] = []
        for file in dayFiles {
            if Task.isCancelled { break }
            let remaining = limit - collectedEntries.count
            collectedEntries.append(contentsOf: entries(in: file, limit: remaining))
            if collectedEntries.count >= limit {
                break
            }
        }

        return Array(
            collectedEntries
                .sorted { $0.createdAt > $1.createdAt }
                .prefix(limit)
        )
    }

    private static func isDictationDayFile(_ url: URL) -> Bool {
        url.pathExtension == "md" && url.lastPathComponent.hasPrefix(dictationDayPrefix)
    }

    /// Removes a single dictation entry by matching on its stable saved entry ID.
    /// If the day file has no remaining entries, the file is deleted.
    static func deleteEntry(_ entry: SavedDictationEntry) throws {
        let url = entry.url
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            throw NSError(domain: "DictationTranscriptStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not read \(url.lastPathComponent)."])
        }

        let sections = splitSections(in: content)
        var removedCount = 0
        let kept: [String] = sections.filter { section in
            guard let parsed = parseEntry(from: section, in: url) else { return true }
            if isSameEntry(parsed, as: entry) {
                removedCount += 1
                return false
            }
            return true
        }

        guard removedCount > 0 else {
            throw NSError(
                domain: "DictationTranscriptStore",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Could not find the dictation entry to delete."]
            )
        }

        if kept.isEmpty {
            try FileManager.default.removeItem(at: url)
        } else {
            let header = headerPreface(in: content)
            let rebuilt = (header + kept.joined(separator: "\n\n")).trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
            try rebuilt.write(to: url, atomically: true, encoding: .utf8)
            FileManager.default.restrictFileToOwnerOnly(at: url)
        }

        NotificationCenter.default.post(name: .dictationTranscriptDidSave, object: url)
    }

    private static func isSameEntry(_ lhs: SavedDictationEntry, as rhs: SavedDictationEntry) -> Bool {
        if let lhsEntryID = lhs.entryID, let rhsEntryID = rhs.entryID {
            return lhs.url == rhs.url && lhsEntryID == rhsEntryID
        }

        return lhs.url == rhs.url
            && lhs.createdAt == rhs.createdAt
            && lhs.title == rhs.title
    }

    private static func headerPreface(in content: String) -> String {
        var preface: [String] = []
        for line in content.components(separatedBy: "\n") {
            if isEntryHeading(line) { break }
            preface.append(line)
        }
        let joined = preface.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? "" : joined + "\n\n"
    }

    private static func entries(in url: URL, limit: Int? = nil) -> [SavedDictationEntry] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }

        if let limit, limit > 0 {
            return splitRecentSections(in: content, limit: limit)
                .compactMap { parseEntry(from: $0, in: url) }
        }

        return splitSections(in: content)
            .compactMap { parseEntry(from: $0, in: url) }
    }

    private struct DictationFileStats {
        let entries: Int
        let words: Int
    }

    private static func fileStats(in url: URL) -> DictationFileStats {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return DictationFileStats(entries: 0, words: 0)
        }

        var entries = 0
        var words = 0
        var scanningMetadata = false
        var sawMetadataLine = false

        for line in content.components(separatedBy: "\n") {
            if Task.isCancelled { break }
            if isEntryHeading(line) {
                entries += 1
                scanningMetadata = true
                sawMetadataLine = false
                continue
            }

            guard scanningMetadata else { continue }

            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                if sawMetadataLine {
                    scanningMetadata = false
                }
                continue
            }

            sawMetadataLine = true
            if trimmed.hasPrefix("Words:") {
                words += intMetadataValue(from: trimmed, prefix: "Words:")
            }
        }

        return DictationFileStats(entries: entries, words: words)
    }

    private static func splitSections(in content: String) -> [String] {
        let lines = content.components(separatedBy: "\n")
        var sections: [String] = []
        var currentSection: [String] = []

        for line in lines {
            if isEntryHeading(line) {
                if !currentSection.isEmpty {
                    sections.append(currentSection.joined(separator: "\n"))
                }
                currentSection = [line]
            } else if !currentSection.isEmpty {
                currentSection.append(line)
            }
        }

        if !currentSection.isEmpty {
            sections.append(currentSection.joined(separator: "\n"))
        }

        return sections
    }

    private static func splitRecentSections(in content: String, limit: Int) -> [String] {
        let lines = content.components(separatedBy: "\n")
        var recentSections: [String] = []
        var currentSection: [String] = []

        for line in lines {
            if isEntryHeading(line) {
                if !currentSection.isEmpty {
                    recentSections.append(currentSection.joined(separator: "\n"))
                    if recentSections.count > limit {
                        recentSections.removeFirst(recentSections.count - limit)
                    }
                }
                currentSection = [line]
            } else if !currentSection.isEmpty {
                currentSection.append(line)
            }
        }

        if !currentSection.isEmpty {
            recentSections.append(currentSection.joined(separator: "\n"))
            if recentSections.count > limit {
                recentSections.removeFirst(recentSections.count - limit)
            }
        }

        return recentSections
    }

    private static func isEntryHeading(_ line: String) -> Bool {
        line.range(
            of: #"^## \d{1,2}:\d{2} [AP]M - .+"#,
            options: .regularExpression
        ) != nil
    }

    private static func parseEntry(from rawSection: String, in url: URL) -> SavedDictationEntry? {
        let lines = rawSection.components(separatedBy: "\n")
        guard let heading = lines.first, heading.hasPrefix("## ") else {
            return nil
        }

        let title = parseTitle(from: heading)
        var entryID: String?
        var createdAtText = ""
        var sourceAppName = "Unknown"
        var sourceAppBundleID: String?
        var delivery = DictationDelivery.failed
        var bodyLines: [String] = []
        var inBody = false
        var sawMetadata = false

        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                if !inBody, sawMetadata {
                    inBody = true
                } else if inBody {
                    bodyLines.append("")
                }
                continue
            }

            if inBody {
                bodyLines.append(line)
                continue
            }

            if trimmed.hasPrefix("Entry ID:") {
                sawMetadata = true
                entryID = metadataValue(from: trimmed, prefix: "Entry ID:")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "`"))
            } else if trimmed.hasPrefix("Captured:") {
                sawMetadata = true
                createdAtText = metadataValue(from: trimmed, prefix: "Captured:")
            } else if trimmed.hasPrefix("Timestamp:") {
                sawMetadata = true
                createdAtText = metadataValue(from: trimmed, prefix: "Timestamp:")
            } else if trimmed.hasPrefix("Source app:") {
                sawMetadata = true
                sourceAppName = metadataValue(from: trimmed, prefix: "Source app:")
            } else if trimmed.hasPrefix("Bundle ID:") {
                sawMetadata = true
                sourceAppBundleID = metadataValue(from: trimmed, prefix: "Bundle ID:")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "`"))
            } else if trimmed.hasPrefix("Delivery:") {
                sawMetadata = true
                let rawDelivery = metadataValue(from: trimmed, prefix: "Delivery:")
                delivery = DictationDelivery(rawValue: rawDelivery) ?? .failed
            } else if trimmed.hasPrefix("Words:") || trimmed.hasPrefix("Characters:") {
                sawMetadata = true
            } else if !sawMetadata {
                inBody = true
                bodyLines.append(line)
            }
        }

        let text = bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackCreatedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let createdAt = parseCreatedAt(createdAtText)
            ?? fallbackCreatedAt
            ?? Date(timeIntervalSince1970: 0)

        return SavedDictationEntry(
            url: url,
            entryID: entryID,
            title: title,
            text: text,
            createdAt: createdAt,
            delivery: delivery,
            sourceAppName: sourceAppName,
            sourceAppBundleID: sourceAppBundleID
        )
    }

    private static func parseTitle(from heading: String) -> String {
        let rawHeading = heading.replacingOccurrences(of: "## ", with: "")
        let parts = rawHeading.components(separatedBy: " - ")
        if parts.count > 1 {
            return parts.dropFirst().joined(separator: " - ")
        }
        return rawHeading
    }

    private static func metadataValue(from line: String, prefix: String) -> String {
        line
            .replacingOccurrences(of: prefix, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func intMetadataValue(from line: String, prefix: String) -> Int {
        let value = metadataValue(from: line, prefix: prefix)
            .replacingOccurrences(of: ",", with: "")
        return Int(value) ?? 0
    }

    private static func parseCreatedAt(_ value: String) -> Date? {
        guard !value.isEmpty else {
            return nil
        }

        return iso8601FormatterQueue.sync { () -> Date? in
            for formatter in iso8601Formatters {
                if let parsed = formatter.date(from: value) {
                    return parsed
                }
            }
            return nil
        }
    }
}
