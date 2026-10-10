// DictationTranscriptStore.swift
// Shared save/read seam for saved dictation markdown artifacts.

import AppKit
import Foundation
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif

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
    /// The `Audio:` line: kept audio relative to the dictations folder
    /// (`audio/<uuid>.m4a`). Nil for entries saved without kept audio. The
    /// file may have aged out; resolve it with `DictationAudioArchive`.
    var audioRelativePath: String? = nil

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
    private static let statsCache = DictationFileStatsCache()

    // Sendable value types, so no lock and no shared ICU formatter: a parse
    // costs well under a microsecond instead of ~40 us behind a serial queue.
    private static let fractionalCreatedAtStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let plainCreatedAtStyle = Date.ISO8601FormatStyle()

    @discardableResult
    static func save(
        text: String,
        sourceApp: NSRunningApplication?,
        delivery: DictationDelivery,
        createdAt: Date = Date(),
        directory: URL? = nil,
        audioRelativePath: String? = nil
    ) throws -> SavedDictationTranscript {
        let saved = try DictationTranscriptWriter.save(
            text: text,
            sourceApp: sourceApp,
            delivery: delivery,
            createdAt: createdAt,
            directory: directory,
            audioRelativePath: audioRelativePath
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
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
              ) else {
            return DictationTranscriptCounts(total: 0, today: 0, totalWords: 0)
        }

        let todayURL = DictationTranscriptWriter.dailyFileURL(for: today, in: folder)
        var total = 0
        var todayCount = 0
        var totalWords = 0

        var scannedPaths = Set<String>()
        for file in files where isDictationDayFile(file) {
            // Return before the prune below: a cancelled scan only saw some of
            // the day files, and pruning to those would throw away every other
            // file's cached stats and force the next refresh to reparse them.
            if Task.isCancelled {
                return DictationTranscriptCounts(total: 0, today: 0, totalWords: 0)
            }
            guard let signature = DictationFileStatsCache.Signature(url: file) else { continue }
            scannedPaths.insert(signature.path)
            let stats = statsCache.stats(for: signature) {
                fileStats(in: file)
            }
            total += stats.entries
            totalWords += stats.words
            if file.lastPathComponent == todayURL.lastPathComponent {
                todayCount = stats.entries
            }
        }
        statsCache.prune(keeping: scannedPaths)

        return DictationTranscriptCounts(total: total, today: todayCount, totalWords: totalWords)
    }

    /// Entries in the day file for `today` alone: one stat and, on a cache
    /// miss, one parse. Same count as `savedDictationCounts(...).today`
    /// without reading every other day file. Reads through the shared stats
    /// cache and never prunes it (it sees only one file).
    static func savedDictationCount(forDayOf today: Date = Date(), directory: URL? = nil) -> Int {
        let folder = directory ?? DictationStoragePaths.transcriptsFolder
        let todayURL = DictationTranscriptWriter.dailyFileURL(for: today, in: folder)
        // Match what the directory listing in `savedDictationCounts` would
        // count: the on-disk name must be exactly today's (case-insensitive
        // volumes would otherwise resolve a ".MD" file) and not hidden.
        guard isDictationDayFile(todayURL),
              let values = try? todayURL.resourceValues(forKeys: [.nameKey, .isHiddenKey]),
              values.name == todayURL.lastPathComponent,
              values.isHidden != true,
              let signature = DictationFileStatsCache.Signature(url: todayURL) else {
            return 0
        }
        return statsCache.stats(for: signature) {
            fileStats(in: todayURL)
        }.entries
    }

    /// Entry and word counts per day file on or after `since`, keyed by the
    /// day's start. Reads through the same stats cache as
    /// `savedDictationCounts`, and never prunes it (this sees only part of the
    /// library). Backs the Today page.
    static func savedDictationDayCounts(
        directory: URL? = nil,
        since: Date,
        calendar: Calendar = .current
    ) -> [(day: Date, entries: Int, words: Int)] {
        let folder = directory ?? DictationStoragePaths.transcriptsFolder
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.calendar = Calendar(identifier: .gregorian)
        parser.timeZone = calendar.timeZone
        parser.dateFormat = "yyyy-MM-dd"
        let earliest = calendar.startOfDay(for: since)

        var result: [(day: Date, entries: Int, words: Int)] = []
        for file in files where isDictationDayFile(file) {
            if Task.isCancelled { return [] }
            let stamp = file.deletingPathExtension().lastPathComponent.dropFirst(dictationDayPrefix.count)
            guard let parsed = parser.date(from: String(stamp)) else { continue }
            let day = calendar.startOfDay(for: parsed)
            guard day >= earliest,
                  let signature = DictationFileStatsCache.Signature(url: file) else { continue }
            let stats = statsCache.stats(for: signature) {
                fileStats(in: file)
            }
            result.append((day: day, entries: stats.entries, words: stats.words))
        }
        return result.sorted { $0.day < $1.day }
    }

    static func resetSavedDictationCountsCacheForTesting() {
        statsCache.reset()
    }

    static func savedDictationCountsCacheMissesForTesting() -> Int {
        statsCache.misses
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

    /// What `deleteEntryReversibly` did, carrying everything needed to
    /// restore the entry within an undo grace window.
    enum EntryDeletionUndo {
        /// The day file was rewritten without the entry.
        case rewrote(url: URL, originalContent: String, newContent: String)
        /// The entry was the file's only one: the whole day file moved to
        /// the Trash (never a permanent delete).
        case trashedFile(originalURL: URL, trashedURL: URL?)
    }

    /// Reversible variant of `deleteEntry` for the inline-undo flow: same
    /// lock-protected mutation and matching rules, but the empty-day case
    /// moves the file to the Trash instead of permanently removing it, and
    /// the returned payload lets `restoreDeletedEntry` put things back.
    static func deleteEntryReversibly(_ entry: SavedDictationEntry) throws -> EntryDeletionUndo {
        let undo: EntryDeletionUndo = try DictationTranscriptMutationLock.withLock {
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
                var trashedURL: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &trashedURL)
                return .trashedFile(originalURL: url, trashedURL: trashedURL as URL?)
            } else {
                let header = headerPreface(in: content)
                let rebuilt = (header + kept.joined(separator: "\n\n")).trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
                try TranscriptFileRewrite.write(rebuilt, to: url)
                FileManager.default.restrictFileToOwnerOnly(at: url)
                return .rewrote(url: url, originalContent: content, newContent: rebuilt)
            }
        }

        NotificationCenter.default.post(name: .dictationTranscriptDidSave, object: entry.url)
        return undo
    }

    /// Restores a reversible deletion. Safe against dictations that saved
    /// into the same day during the grace window: if the file changed since
    /// the rewrite, the removed sections are merged back in instead of
    /// clobbering the newer content. (Entry display order is sorted by
    /// timestamp at read time, so merge position inside the file does not
    /// affect what the user sees.)
    static func restoreDeletedEntry(_ undo: EntryDeletionUndo) throws {
        let notifyURL: URL
        switch undo {
        case .rewrote(let url, let originalContent, let newContent):
            notifyURL = url
            try DictationTranscriptMutationLock.withLock {
                let current = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                if current == newContent || current.isEmpty {
                    try TranscriptFileRewrite.write(originalContent, to: url)
                } else {
                    let removedSections = missingSections(from: originalContent, comparedTo: newContent)
                    guard !removedSections.isEmpty else { return }
                    let rebuilt = current.trimmingCharacters(in: .whitespacesAndNewlines)
                        + "\n\n" + removedSections.joined(separator: "\n\n") + "\n"
                    try TranscriptFileRewrite.write(rebuilt, to: url)
                }
                FileManager.default.restrictFileToOwnerOnly(at: url)
            }
        case .trashedFile(let originalURL, let trashedURL):
            notifyURL = originalURL
            guard let trashedURL else {
                throw NSError(
                    domain: "DictationTranscriptStore",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "The deleted day file's Trash location is unknown; restore it from the Trash manually."]
                )
            }
            try DictationTranscriptMutationLock.withLock {
                if FileManager.default.fileExists(atPath: originalURL.path) {
                    // A new dictation recreated the day file during the
                    // grace window — merge the trashed sections back in.
                    let current = (try? String(contentsOf: originalURL, encoding: .utf8)) ?? ""
                    let old = (try? String(contentsOf: trashedURL, encoding: .utf8)) ?? ""
                    let oldSections = splitSections(in: old).map(droppingTrailingBlankLines)
                    guard !oldSections.isEmpty else { return }
                    let rebuilt = current.trimmingCharacters(in: .whitespacesAndNewlines)
                        + "\n\n" + oldSections.joined(separator: "\n\n") + "\n"
                    try TranscriptFileRewrite.write(rebuilt, to: originalURL)
                    try? FileManager.default.removeItem(at: trashedURL)
                } else {
                    try FileManager.default.moveItem(at: trashedURL, to: originalURL)
                }
                FileManager.default.restrictFileToOwnerOnly(at: originalURL)
            }
        }

        NotificationCenter.default.post(name: .dictationTranscriptDidSave, object: notifyURL)
    }

    /// Sections present in `original` but absent from `reduced`. Compared
    /// without surrounding whitespace: the delete rewrite rejoins sections
    /// with "\n\n", so a kept section's trailing blank lines can differ from
    /// the original and must not make it look deleted (and get re-appended).
    private static func missingSections(from original: String, comparedTo reduced: String) -> [String] {
        let reducedSet = Set(splitSections(in: reduced).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        return splitSections(in: original)
            .filter { !reducedSet.contains($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .map(droppingTrailingBlankLines)
    }

    /// A split section carries the blank lines that separated it from the
    /// next heading. Restore re-adds its own "\n\n" separators, so keeping
    /// them would grow the file on every Undo (#2187). Only trailing line
    /// breaks are dropped; trailing spaces on the last line stay (#2150).
    private static func droppingTrailingBlankLines(_ section: String) -> String {
        var lines = section.components(separatedBy: "\n")
        while lines.count > 1, let last = lines.last, last.isEmpty { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    /// Removes a single dictation entry by matching on its stable saved entry ID.
    /// If the day file has no remaining entries, the file is deleted. Kept
    /// audio is the caller's to remove (`DictationAudioArchive.deleteKeptAudio(for:)`);
    /// this file stays free of the archive so the storage smokes compile it alone.
    static func deleteEntry(_ entry: SavedDictationEntry) throws {
        try DictationTranscriptMutationLock.withLock {
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
                try TranscriptFileRewrite.write(rebuilt, to: url)
                FileManager.default.restrictFileToOwnerOnly(at: url)
            }
        }

        NotificationCenter.default.post(name: .dictationTranscriptDidSave, object: entry.url)
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

    private final class DictationFileStatsCache: @unchecked Sendable {
        struct Signature: Hashable {
            let path: String
            let modifiedAt: Date
            let size: Int

            init?(url: URL) {
                let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
                guard let values = try? url.resourceValues(forKeys: keys),
                      values.isRegularFile != false,
                      let modifiedAt = values.contentModificationDate,
                      let size = values.fileSize else {
                    return nil
                }

                self.path = url.standardizedFileURL.path
                self.modifiedAt = modifiedAt
                self.size = size
            }
        }

        private struct Entry {
            let signature: Signature
            let stats: DictationFileStats
        }

        private let lock = NSLock()
        private var entriesByPath: [String: Entry] = [:]
        private var missCount = 0

        var misses: Int {
            lock.lock()
            defer { lock.unlock() }
            return missCount
        }

        func stats(for signature: Signature, load: () -> DictationFileStats) -> DictationFileStats {
            lock.lock()
            let cached = entriesByPath[signature.path]
            lock.unlock()
            if cached?.signature == signature, let stats = cached?.stats {
                return stats
            }

            let stats = load()
            lock.lock()
            entriesByPath[signature.path] = Entry(signature: signature, stats: stats)
            missCount += 1
            lock.unlock()
            return stats
        }

        func prune(keeping paths: Set<String>) {
            lock.lock()
            entriesByPath = entriesByPath.filter { paths.contains($0.key) }
            lock.unlock()
        }

        func reset() {
            lock.lock()
            entriesByPath.removeAll()
            missCount = 0
            lock.unlock()
        }
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

    private static let entryHeadingRegex = try? NSRegularExpression(
        pattern: #"^## \d{1,2}:\d{2} [AP]M - .+"#
    )

    static func isEntryHeading(_ line: String) -> Bool {
        // Every match starts with "## ", so this cheap check skips the regex
        // for the body and metadata lines that make up most of a day file.
        guard line.hasPrefix("## "), let regex = entryHeadingRegex else { return false }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        return regex.firstMatch(in: line, range: range) != nil
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
        var audioRelativePath: String?
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
            } else if trimmed.hasPrefix("Audio:") {
                sawMetadata = true
                let value = metadataValue(from: trimmed, prefix: "Audio:")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "`"))
                audioRelativePath = value.isEmpty ? nil : value
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
            sourceAppBundleID: sourceAppBundleID,
            audioRelativePath: audioRelativePath
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

        // ISO8601DateFormatter truncated the fraction to the millisecond, so
        // cut a hand-edited longer fraction to 3 digits first. What's left is
        // a whole millisecond that FormatStyle can land a fraction of a
        // microsecond off, so snap to the nearest one. Together that keeps
        // createdAt, entry ids and legacy delete matching bit-identical.
        let trimmed = truncatingFractionToMilliseconds(value)
        guard let parsed = (try? fractionalCreatedAtStyle.parse(trimmed))
            ?? (try? plainCreatedAtStyle.parse(trimmed)) else {
            return nil
        }
        let milliseconds = (parsed.timeIntervalSince1970 * 1_000).rounded()
        return Date(timeIntervalSince1970: milliseconds / 1_000)
    }

    /// `...:00.1239999Z` becomes `...:00.123Z`; anything else is unchanged.
    private static func truncatingFractionToMilliseconds(_ value: String) -> String {
        guard let dot = value.firstIndex(of: ".") else { return value }
        let digitsStart = value.index(after: dot)
        let digitsEnd = value[digitsStart...].firstIndex { !$0.isASCII || !$0.isNumber } ?? value.endIndex
        guard value.distance(from: digitsStart, to: digitsEnd) > 3 else { return value }
        let keepEnd = value.index(digitsStart, offsetBy: 3)
        return String(value[..<keepEnd] + value[digitsEnd...])
    }
}
