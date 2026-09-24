import CryptoKit
import Foundation

/// Which saved meetings a dictionary correction would still change.
struct DictionaryPastMeetingScan: Equatable, Sendable {
    let meetingURLs: [URL]
    /// Total spots across those meetings, for the confirm message.
    let spotCount: Int

    var meetingCount: Int { meetingURLs.count }
}

/// One meeting a fix rewrote. The original text lives in the backup file, so
/// Undo still works after the app quits.
struct DictionaryPastMeetingFileChange: Codable, Equatable, Sendable {
    let path: String
    let backupFilename: String
    /// What the fix wrote. Undo only restores a meeting that still matches it.
    let updatedSHA256: String

    var url: URL { URL(fileURLWithPath: path) }
}

/// What one "Fix them" click changed, saved next to the backups.
struct DictionaryPastMeetingFixReceipt: Codable, Equatable, Sendable {
    let id: String
    let createdAt: Date
    let spoken: String
    let replacement: String
    var changes: [DictionaryPastMeetingFileChange]
    /// Meetings that matched but were busy (being re-transcribed), missing, or
    /// could not be read or backed up. They are left exactly as they were.
    let skippedCount: Int
    var undone: Bool = false

    var entry: CustomDictionaryEntry {
        CustomDictionaryEntry(spoken: spoken, replacement: replacement)
    }

    var fixedCount: Int { changes.count }
}

struct DictionaryPastMeetingUndoResult: Equatable, Sendable {
    let restoredURLs: [URL]
    /// Meetings that changed again after the fix (a rename, a re-transcribe,
    /// another fix), so undo left the newer version alone.
    let keptCount: Int
    /// Meetings whose backup is gone (deleted with the meeting, or aged out),
    /// so there was nothing to put back.
    var missingBackupCount: Int = 0
}

/// Copy for the line under a correction and its confirm step. Kept out of the
/// SwiftUI file so fast tests can pin it.
enum DictionaryPastMeetingFixCopy {
    static func found(_ meetings: Int) -> String {
        "Also in \(meetingPhrase(meetings, past: true))."
    }

    static func fixAction(_ meetings: Int) -> String {
        meetings == 1 ? "Fix it" : "Fix them"
    }

    static let fixing = "Fixing…"
    static let undoing = "Undoing…"
    static let undoAction = "Undo"
    static let retryAction = "Try again"

    static func fixed(count: Int, remaining: Int) -> String {
        let fixed = "Fixed \(meetingPhrase(count, past: false))."
        guard remaining > 0 else { return fixed }
        return fixed + " \(remaining) more couldn\u{2019}t be changed yet."
    }

    static func fixOutcomeNote(_ receipt: DictionaryPastMeetingFixReceipt) -> String? {
        guard receipt.fixedCount == 0 else { return nil }
        return receipt.skippedCount > 0
            ? "Couldn\u{2019}t change those meetings right now."
            : "Those meetings are already fixed."
    }

    static func undone(_ result: DictionaryPastMeetingUndoResult) -> String? {
        var notes: [String] = []
        if result.keptCount > 0 {
            notes.append(result.keptCount == 1
                ? "1 meeting changed after the fix, so it was kept."
                : "\(result.keptCount) meetings changed after the fix, so they were kept.")
        }
        if result.missingBackupCount > 0 {
            notes.append(result.missingBackupCount == 1
                ? "1 meeting\u{2019}s backup is gone, so it stays fixed."
                : "\(result.missingBackupCount) meetings\u{2019} backups are gone, so they stay fixed.")
        }
        return notes.isEmpty ? nil : notes.joined(separator: " ")
    }

    /// A fix whose correction is no longer in the list, shown under the list
    /// so it can still be undone.
    static func earlierFix(_ entry: CustomDictionaryEntry, meetings: Int) -> String {
        "Changed \u{201C}\(entry.spoken)\u{201D} to \u{201C}\(entry.replacement)\u{201D} in \(meetings == 1 ? "1 meeting" : "\(meetings) meetings")."
    }

    static func confirmTitle(_ scan: DictionaryPastMeetingScan) -> String {
        "Fix \(meetingPhrase(scan.meetingCount, past: true))?"
    }

    static func confirmMessage(_ entry: CustomDictionaryEntry, scan: DictionaryPastMeetingScan) -> String {
        let spots = scan.spotCount == 1 ? "1 spot" : "\(scan.spotCount) spots"
        return "\u{201C}\(entry.spoken)\u{201D} becomes \u{201C}\(entry.replacement)\u{201D} in \(spots), in any capitalization. Only the spoken words change, and you can undo it."
    }

    static func confirmAction(_ scan: DictionaryPastMeetingScan) -> String {
        "Fix \(meetingPhrase(scan.meetingCount, past: false))"
    }

    private static func meetingPhrase(_ count: Int, past: Bool) -> String {
        let noun = count == 1 ? "meeting" : "meetings"
        return past ? "\(count) past \(noun)" : "\(count) \(noun)"
    }
}

/// Spoken text per meeting file, reused across counts while the file is
/// unchanged, so each typing pause doesn't re-read the whole library.
final class DictionaryPastMeetingTextCache: @unchecked Sendable {
    private struct Entry {
        let modified: Date
        let size: Int?
        let segments: [String]
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    func segments(for url: URL, read: () -> [String]?) -> [String]? {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let modified = values?.contentModificationDate
        let size = values?.fileSize

        lock.lock()
        if let modified, let cached = entries[url.path], cached.modified == modified, cached.size == size {
            lock.unlock()
            return cached.segments
        }
        lock.unlock()

        guard let segments = read() else { return nil }
        if let modified {
            lock.lock()
            entries[url.path] = Entry(modified: modified, size: size, segments: segments)
            lock.unlock()
        }
        return segments
    }
}

/// Where fixed meetings' original text is kept until the fix is a few days
/// old, so Undo survives edits to the correction and quitting the app.
struct DictionaryPastMeetingBackupStore: Sendable {
    static let retention: TimeInterval = 3 * 24 * 60 * 60
    private static let receiptFilename = "receipt.json"

    let root: URL

    static func `default`(fileManager: FileManager = .default) -> DictionaryPastMeetingBackupStore {
        DictionaryPastMeetingBackupStore(
            root: fileManager.transcriptedStateDir.appendingPathComponent("dictionary-fix-backups", isDirectory: true)
        )
    }

    func folder(for id: String) -> URL {
        root.appendingPathComponent(id, isDirectory: true)
    }

    func writeBackup(_ original: String, id: String, index: Int, fileManager: FileManager = .default) throws -> String {
        let folder = folder(for: id)
        try fileManager.createPrivateDirectory(at: root)
        try fileManager.createPrivateDirectory(at: folder)
        let filename = "\(index).md"
        let url = folder.appendingPathComponent(filename)
        try original.write(to: url, atomically: true, encoding: .utf8)
        fileManager.restrictFileToOwnerOnly(at: url)
        return filename
    }

    func readBackup(_ change: DictionaryPastMeetingFileChange, id: String) throws -> String {
        try String(contentsOf: folder(for: id).appendingPathComponent(change.backupFilename), encoding: .utf8)
    }

    func save(_ receipt: DictionaryPastMeetingFixReceipt, fileManager: FileManager = .default) throws {
        let url = folder(for: receipt.id).appendingPathComponent(Self.receiptFilename)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(receipt).write(to: url, options: .atomic)
        fileManager.restrictFileToOwnerOnly(at: url)
    }

    func remove(id: String, fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: folder(for: id))
    }

    func removeBackup(_ change: DictionaryPastMeetingFileChange, id: String, fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: folder(for: id).appendingPathComponent(change.backupFilename))
    }

    /// Fixes that can still be undone, newest first. On the way it drops
    /// backups older than the retention window and backups of meetings that
    /// no longer exist (deleted, or renamed so Undo couldn't find them), so a
    /// deleted meeting never lingers here.
    func recentReceipts(now: Date = Date(), fileManager: FileManager = .default) -> [DictionaryPastMeetingFixReceipt] {
        var receipts: [DictionaryPastMeetingFixReceipt] = []
        for (folder, stored) in storedReceipts(fileManager: fileManager) {
            guard var receipt = stored else {
                // A folder without a readable receipt is a fix that never
                // saved one; nothing points at it.
                if let modified = try? folder.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                   now.timeIntervalSince(modified) > Self.retention {
                    try? fileManager.removeItem(at: folder)
                }
                continue
            }
            if now.timeIntervalSince(receipt.createdAt) > Self.retention {
                try? fileManager.removeItem(at: folder)
                continue
            }
            let gone = receipt.changes.filter { !fileManager.fileExists(atPath: $0.path) }
            if !gone.isEmpty {
                receipt = dropping(gone, from: receipt, fileManager: fileManager)
                if receipt.changes.isEmpty { continue }
            }
            if !receipt.undone {
                receipts.append(receipt)
            }
        }
        return receipts.sorted { $0.createdAt > $1.createdAt }
    }

    /// Runs the same cleanup as `recentReceipts`; called at launch.
    func prune(now: Date = Date(), fileManager: FileManager = .default) {
        _ = recentReceipts(now: now, fileManager: fileManager)
    }

    /// Deletes every backup of the given meetings. Called when meetings are
    /// deleted, so no copy of a deleted meeting stays behind.
    func removeBackups(forMeetingsAt urls: [URL], fileManager: FileManager = .default) {
        let paths = Set(urls.map(Self.canonicalPath))
        guard !paths.isEmpty else { return }
        for (_, stored) in storedReceipts(fileManager: fileManager) {
            guard let receipt = stored else { continue }
            let matching = receipt.changes.filter { paths.contains(Self.canonicalPath(URL(fileURLWithPath: $0.path))) }
            if !matching.isEmpty {
                _ = dropping(matching, from: receipt, fileManager: fileManager)
            }
        }
    }

    private func storedReceipts(fileManager: FileManager) -> [(URL, DictionaryPastMeetingFixReceipt?)] {
        guard let folders = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return folders.map { folder in
            let data = try? Data(contentsOf: folder.appendingPathComponent(Self.receiptFilename))
            return (folder, data.flatMap { try? decoder.decode(DictionaryPastMeetingFixReceipt.self, from: $0) })
        }
    }

    /// Removes some meetings' backups from a fix. The whole fix goes once no
    /// backups are left.
    private func dropping(
        _ changes: [DictionaryPastMeetingFileChange],
        from receipt: DictionaryPastMeetingFixReceipt,
        fileManager: FileManager
    ) -> DictionaryPastMeetingFixReceipt {
        for change in changes {
            removeBackup(change, id: receipt.id, fileManager: fileManager)
        }
        var updated = receipt
        updated.changes.removeAll { change in changes.contains(change) }
        if updated.changes.isEmpty {
            remove(id: receipt.id, fileManager: fileManager)
        } else {
            try? save(updated, fileManager: fileManager)
        }
        return updated
    }

    private static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

/// Applies a Settings dictionary correction to meetings that were saved before
/// the correction existed. New meetings already get the dictionary at
/// transcription time; this runs the same rules over the saved Markdown.
///
/// Only the spoken transcript changes: the turns between the `## Transcript`
/// heading and the next section. Frontmatter, the title, the "Recorded …"
/// line, timestamps, speaker labels, the footer and any section after the
/// transcript (the user's notes, old summaries) are never touched. Words
/// inside links, email addresses, file paths and code spans are skipped too.
/// Line breaks are never added or removed.
enum DictionaryPastMeetingFix {
    private static let excludedMarkdownFilenames: Set<String> = ["AGENT.md", "CLAUDE.md"]

    /// A rule that only lowercases ("Okay" -> "okay"), or doesn't change the
    /// text at all, is never offered for past meetings: it would flatten
    /// proper capitals across the library.
    static func offersPastFix(for entry: CustomDictionaryEntry) -> Bool {
        guard entry.spoken.caseInsensitiveCompare(entry.replacement) == .orderedSame else { return true }
        return entry.replacement != entry.spoken && entry.replacement != entry.replacement.lowercased()
    }

    // MARK: - Library

    /// Saved meeting transcripts directly in the meetings folder, newest name
    /// first. Mirrors the Home scanner's file filter.
    static func meetingTranscriptURLs(
        in directory: URL,
        fileManager: FileManager = .default
    ) -> [URL] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return urls
            .filter { url in
                url.pathExtension == "md"
                    && !url.deletingPathExtension().lastPathComponent.hasSuffix(".summary")
                    && !excludedMarkdownFilenames.contains(url.lastPathComponent)
                    && (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// For each correction, the saved meetings it would still change. Each file
    /// is read at most once. Corrections with no matches, or that aren't
    /// offered (see `offersPastFix`), are left out of the result.
    static func scan(
        entries: [CustomDictionaryEntry],
        in directory: URL,
        cache: DictionaryPastMeetingTextCache? = nil,
        fileManager: FileManager = .default,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) -> [CustomDictionaryEntry: DictionaryPastMeetingScan] {
        let matchers = entries
            .filter(offersPastFix(for:))
            .compactMap { entry -> (Matcher, String)? in
                guard let matcher = Matcher(entry: entry, allEntries: entries),
                      let firstWord = entry.spoken.split(whereSeparator: \.isWhitespace).first else {
                    return nil
                }
                return (matcher, String(firstWord))
            }
        guard !matchers.isEmpty else { return [:] }

        var urlsByEntry: [CustomDictionaryEntry: [URL]] = [:]
        var spotsByEntry: [CustomDictionaryEntry: Int] = [:]
        for url in meetingTranscriptURLs(in: directory, fileManager: fileManager) {
            if isCancelled() { return [:] }
            let read = { () -> [String]? in
                guard let markdown = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                return spokenSegments(in: markdown)
            }
            let segments: [String]?
            if let cache {
                segments = cache.segments(for: url, read: read)
            } else {
                segments = read()
            }
            guard let segments, !segments.isEmpty else { continue }
            let spoken = segments.joined(separator: "\n")

            for (matcher, firstWord) in matchers {
                // Cheap prefilter so a long dictionary doesn't run every regex
                // over every meeting.
                guard spoken.range(of: firstWord, options: [.caseInsensitive, .diacriticInsensitive]) != nil else {
                    continue
                }
                let spots = segments.reduce(0) { $0 + matcher.fixRanges(in: $1).count }
                if spots > 0 {
                    urlsByEntry[matcher.entry, default: []].append(url)
                    spotsByEntry[matcher.entry, default: 0] += spots
                }
            }
        }
        var result: [CustomDictionaryEntry: DictionaryPastMeetingScan] = [:]
        for (entry, urls) in urlsByEntry {
            result[entry] = DictionaryPastMeetingScan(meetingURLs: urls, spotCount: spotsByEntry[entry] ?? 0)
        }
        return result
    }

    // MARK: - File updates

    /// Rewrites every listed meeting that still has something to fix. Each
    /// meeting's original text is backed up before it is written. A meeting
    /// that is being re-transcribed, can't be read, or can't be backed up is
    /// skipped and counted, never half-written. The file's creation date is
    /// kept so Home's order doesn't change.
    static func fix(
        _ entry: CustomDictionaryEntry,
        allEntries: [CustomDictionaryEntry],
        meetingsAt urls: [URL],
        backups: DictionaryPastMeetingBackupStore,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) -> DictionaryPastMeetingFixReceipt {
        let id = UUID().uuidString
        var changes: [DictionaryPastMeetingFileChange] = []
        var skipped = 0

        if offersPastFix(for: entry), let matcher = Matcher(entry: entry, allEntries: allEntries) {
            for (index, url) in urls.enumerated() {
                do {
                    let change: DictionaryPastMeetingFileChange? = try MeetingTranscriptFileUpdateSerializer.sync(protecting: [url]) { () throws -> DictionaryPastMeetingFileChange? in
                        let raw = try String(contentsOf: url, encoding: .utf8)
                        let result = replacing(with: matcher, in: raw)
                        guard result.count > 0, result.markdown != raw else { return nil }
                        let backupFilename = try backups.writeBackup(raw, id: id, index: index, fileManager: fileManager)
                        try writePreservingCreationDate(result.markdown, to: url, fileManager: fileManager)
                        return DictionaryPastMeetingFileChange(
                            path: url.path,
                            backupFilename: backupFilename,
                            updatedSHA256: sha256(result.markdown)
                        )
                    }
                    if let change {
                        changes.append(change)
                        // Saved as it goes, so a crash mid-fix still leaves
                        // an Undo for the meetings already changed.
                        try? backups.save(DictionaryPastMeetingFixReceipt(
                            id: id,
                            createdAt: now,
                            spoken: entry.spoken,
                            replacement: entry.replacement,
                            changes: changes,
                            skippedCount: skipped
                        ), fileManager: fileManager)
                    }
                } catch {
                    skipped += 1
                }
            }
        }

        let receipt = DictionaryPastMeetingFixReceipt(
            id: id,
            createdAt: now,
            spoken: entry.spoken,
            replacement: entry.replacement,
            changes: changes,
            skippedCount: skipped
        )
        if changes.isEmpty {
            backups.remove(id: id, fileManager: fileManager)
        } else {
            // Undo still works this session if saving the receipt fails; only
            // the after-relaunch Undo is lost.
            try? backups.save(receipt, fileManager: fileManager)
        }
        return receipt
    }

    /// Puts each meeting back from its backup, but only when nothing else has
    /// written it since the fix. Otherwise undo would silently throw that work away.
    static func undo(
        _ receipt: DictionaryPastMeetingFixReceipt,
        backups: DictionaryPastMeetingBackupStore,
        fileManager: FileManager = .default
    ) -> DictionaryPastMeetingUndoResult {
        var restored: [URL] = []
        var kept = 0
        var missingBackups = 0

        for change in receipt.changes {
            guard let original = try? backups.readBackup(change, id: receipt.id) else {
                missingBackups += 1
                continue
            }
            do {
                let didRestore: Bool = try MeetingTranscriptFileUpdateSerializer.sync(protecting: [change.url]) { () throws -> Bool in
                    let current = try String(contentsOf: change.url, encoding: .utf8)
                    guard sha256(current) == change.updatedSHA256 else { return false }
                    try writePreservingCreationDate(original, to: change.url, fileManager: fileManager)
                    return true
                }
                if didRestore {
                    restored.append(change.url)
                    backups.removeBackup(change, id: receipt.id, fileManager: fileManager)
                } else {
                    kept += 1
                }
            } catch {
                kept += 1
            }
        }

        if kept == 0 {
            backups.remove(id: receipt.id, fileManager: fileManager)
        } else {
            // Keep the leftover backups until they age out, but never offer
            // this fix's Undo again.
            var finished = receipt
            finished.undone = true
            try? backups.save(finished, fileManager: fileManager)
        }
        return DictionaryPastMeetingUndoResult(restoredURLs: restored, keptCount: kept, missingBackupCount: missingBackups)
    }

    private static func writePreservingCreationDate(_ text: String, to url: URL, fileManager: FileManager) throws {
        let creationDate = (try? fileManager.attributesOfItem(atPath: url.path))?[.creationDate] as? Date
        try text.write(to: url, atomically: true, encoding: .utf8)
        fileManager.restrictFileToOwnerOnly(at: url)
        // The new modification date is kept on purpose so Home's cache and the
        // agent index see the change.
        if let creationDate {
            try? fileManager.setAttributes([.creationDate: creationDate], ofItemAtPath: url.path)
        }
    }

    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Pure text

    /// One correction plus the longer corrections that win over it, the same
    /// way live transcription applies the longest phrase first.
    struct Matcher {
        let entry: CustomDictionaryEntry
        let regex: NSRegularExpression
        let longerRules: [NSRegularExpression]

        init?(entry: CustomDictionaryEntry, allEntries: [CustomDictionaryEntry]) {
            guard let regex = CustomDictionaryTextProcessor.matcher(for: entry.spoken) else { return nil }
            self.entry = entry
            self.regex = regex
            let spoken = Self.normalized(entry.spoken)
            self.longerRules = allEntries.compactMap { other in
                let otherSpoken = Self.normalized(other.spoken)
                guard otherSpoken.count > spoken.count, otherSpoken.contains(spoken) else { return nil }
                return CustomDictionaryTextProcessor.matcher(for: other.spoken)
            }
        }

        private static func normalized(_ text: String) -> String {
            text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }

        /// Matches that would actually change something.
        func fixRanges(in segment: String) -> [NSRange] {
            let text = segment as NSString
            let fullRange = NSRange(location: 0, length: text.length)
            let matches = regex.matches(in: segment, range: fullRange).map(\.range)
            guard !matches.isEmpty else { return [] }
            let claimedByLongerRules = longerRules.flatMap { $0.matches(in: segment, range: fullRange).map(\.range) }
            let replacement = entry.replacement as NSString
            return matches.filter { match in
                !claimedByLongerRules.contains(where: { NSIntersectionRange($0, match).length > 0 })
                    && !DictionaryPastMeetingFix.isAlreadyReplacement(match, in: text, replacement: replacement)
                    && !DictionaryPastMeetingFix.isInsideLinkOrCode(match, in: text)
            }
        }
    }

    /// How many spots in a meeting's spoken text the correction would change.
    static func fixCount(
        of entry: CustomDictionaryEntry,
        allEntries: [CustomDictionaryEntry] = [],
        in markdown: String
    ) -> Int {
        guard let matcher = Matcher(entry: entry, allEntries: allEntries) else { return 0 }
        return spokenSegments(in: markdown).reduce(0) { $0 + matcher.fixRanges(in: $1).count }
    }

    static func replacing(
        _ entry: CustomDictionaryEntry,
        allEntries: [CustomDictionaryEntry] = [],
        in markdown: String
    ) -> (markdown: String, count: Int) {
        guard let matcher = Matcher(entry: entry, allEntries: allEntries) else { return (markdown, 0) }
        return replacing(with: matcher, in: markdown)
    }

    private static func replacing(with matcher: Matcher, in markdown: String) -> (markdown: String, count: Int) {
        var count = 0
        let rewritten = forEachSpokenSegment(in: markdown) { segment in
            let ranges = matcher.fixRanges(in: segment)
            guard !ranges.isEmpty else { return nil }
            count += ranges.count
            let mutable = NSMutableString(string: segment)
            for range in ranges.reversed() {
                mutable.replaceCharacters(in: range, with: matcher.entry.replacement)
            }
            return mutable as String
        }
        return (rewritten, count)
    }

    /// True when the text around a match already reads as the replacement:
    /// "PostHog" already cased right, or "Claude Code" for a
    /// "claude -> Claude Code" rule. That keeps a fix from stacking
    /// ("Claude Code Code") and makes a second run find nothing. Casing only
    /// counts when the replacement is the same length as the match, so a
    /// casing rule still fixes "posthog".
    fileprivate static func isAlreadyReplacement(
        _ match: NSRange,
        in text: NSString,
        replacement: NSString
    ) -> Bool {
        let length = replacement.length
        guard length >= match.length else { return false }
        let options: NSString.CompareOptions = length == match.length ? [] : [.caseInsensitive]
        let earliest = max(0, NSMaxRange(match) - length)
        let latest = min(match.location, text.length - length)
        guard earliest <= latest else { return false }
        for start in earliest...latest {
            let candidate = NSRange(location: start, length: length)
            if text.compare(replacement as String, options: options, range: candidate) == .orderedSame {
                return true
            }
        }
        return false
    }

    /// Links, email addresses, file paths and `code` stay exactly as written,
    /// so "cloud" -> "Claude" never turns cloud.google.com into Claude.google.com.
    fileprivate static func isInsideLinkOrCode(_ match: NSRange, in text: NSString) -> Bool {
        let backticksBefore = text.substring(to: match.location).filter { $0 == "`" }.count
        if backticksBefore % 2 == 1 { return true }

        let whitespace = CharacterSet.whitespacesAndNewlines
        var start = match.location
        while start > 0, let scalar = UnicodeScalar(text.character(at: start - 1)), !whitespace.contains(scalar) {
            start -= 1
        }
        var end = NSMaxRange(match)
        while end < text.length, let scalar = UnicodeScalar(text.character(at: end)), !whitespace.contains(scalar) {
            end += 1
        }
        let edgePunctuation = CharacterSet(charactersIn: ".,;:!?\"'()[]{}<>*_\u{2018}\u{2019}\u{201C}\u{201D}")
        let token = text.substring(with: NSRange(location: start, length: end - start))
            .trimmingCharacters(in: edgePunctuation)
        if token.contains("/") || token.contains("@") || token.contains("\\") { return true }

        // A dot between two letters or digits: a domain or file name.
        let scalars = Array(token.unicodeScalars)
        guard scalars.count >= 3 else { return false }
        for index in 1..<(scalars.count - 1) where scalars[index] == "." {
            if CharacterSet.alphanumerics.contains(scalars[index - 1]),
               CharacterSet.alphanumerics.contains(scalars[index + 1]) {
                return true
            }
        }
        return false
    }

    static func spokenSegments(in markdown: String) -> [String] {
        var segments: [String] = []
        forEachSpokenSegment(in: markdown) { segment in
            segments.append(segment)
            return nil
        }
        return segments
    }

    /// Walks the spoken-text part of every transcript line. `transform` returns
    /// replacement text for a segment, or nil to keep it. Only saved meetings
    /// are touched: the frontmatter must say `capture_type: meeting` (or carry
    /// a `capture_id`), and the file needs a `## Transcript` /
    /// `## Full Transcript` heading. The walk ends at the next `## ` section,
    /// a `---` rule, or the footer, the same place the transcript styler ends
    /// the transcript.
    @discardableResult
    private static func forEachSpokenSegment(
        in markdown: String,
        _ transform: (String) -> String?
    ) -> String {
        var lines = markdown.components(separatedBy: "\n")

        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---",
              let closing = lines.indices.dropFirst().first(where: {
                  lines[$0].trimmingCharacters(in: .whitespacesAndNewlines) == "---"
              }) else {
            // No frontmatter, or unterminated: not a file Transcripted saved.
            return markdown
        }
        let isMeeting = lines[1..<closing].contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed == "capture_type: meeting"
                || trimmed == "capture_type: \"meeting\""
                || trimmed.hasPrefix("capture_id:")
        }
        guard isMeeting else { return markdown }

        guard let heading = lines.indices.dropFirst(closing + 1).first(where: {
            let trimmed = lines[$0].trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed == "## Full Transcript" || trimmed == "## Transcript"
        }) else {
            return markdown
        }

        var changed = false
        for index in lines.indices.dropFirst(heading + 1) {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "---"
                || trimmed.hasPrefix("## ")
                || trimmed.hasPrefix("*Generated by Transcripted")
                || trimmed.hasPrefix("**Participants:**") {
                break
            }
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix(">") || trimmed.hasPrefix("Recorded ") {
                continue
            }

            let textStart = spokenTextStart(in: line)
            let segment = String(line[textStart...])
            guard !segment.isEmpty, let replaced = transform(segment) else { continue }
            lines[index] = String(line[..<textStart]) + replaced
            changed = true
        }

        return changed ? lines.joined(separator: "\n") : markdown
    }

    /// Where the spoken words begin on a line. Turn headers look like
    /// `**00:12**  [Mic/Linus]` (styled) or `[00:01] [System/[[Alex]]] Hello`
    /// (legacy); both the time and the speaker label are skipped. Any other
    /// line is spoken text from its first character.
    private static func spokenTextStart(in line: String) -> String.Index {
        guard let first = line.firstIndex(where: { !$0.isWhitespace }) else { return line.endIndex }
        var cursor: String.Index

        if line[first...].hasPrefix("**") {
            let timeStart = line.index(first, offsetBy: 2)
            guard let close = line.range(of: "**", range: timeStart..<line.endIndex),
                  looksLikeTimestamp(line[timeStart..<close.lowerBound]) else {
                return line.startIndex
            }
            cursor = close.upperBound
        } else if line[first] == "[" {
            let timeStart = line.index(after: first)
            guard let close = line[timeStart...].firstIndex(of: "]"),
                  looksLikeTimestamp(line[timeStart..<close]) else {
                return line.startIndex
            }
            cursor = line.index(after: close)
        } else {
            return line.startIndex
        }

        while cursor < line.endIndex, line[cursor].isWhitespace {
            cursor = line.index(after: cursor)
        }
        if cursor < line.endIndex, line[cursor] == "[",
           let labelEnd = matchingClosingBracket(in: line, from: cursor) {
            cursor = line.index(after: labelEnd)
        }
        return cursor
    }

    /// Outer closing bracket, so `[System/[[Alex]]]` doesn't stop inside the link.
    private static func matchingClosingBracket(in line: String, from start: String.Index) -> String.Index? {
        var depth = 0
        var index = start
        while index < line.endIndex {
            switch line[index] {
            case "[":
                depth += 1
            case "]":
                depth -= 1
                if depth == 0 { return index }
            default:
                break
            }
            index = line.index(after: index)
        }
        return nil
    }

    private static func looksLikeTimestamp(_ value: Substring) -> Bool {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return false }
        return parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }
}
