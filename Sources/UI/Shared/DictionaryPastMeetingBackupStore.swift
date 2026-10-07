import CryptoKit
import Foundation
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif

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

    /// Forgets files that weren't in the latest count, so the cache never
    /// holds more than the current library.
    func retainOnly(_ urls: [URL]) {
        let keep = Set(urls.map(\.path))
        lock.lock()
        entries = entries.filter { keep.contains($0.key) }
        lock.unlock()
    }
}

/// Where fixed meetings' original text is kept until the fix is a few days
/// old, so Undo survives edits to the correction and quitting the app.
///
/// Meetings are found by file name in the current meetings folder, so moving
/// the library in Settings doesn't break Undo. Every read-modify-write of a
/// receipt holds one lock, so a delete from Home and a fix can't undo each
/// other's cleanup.
struct DictionaryPastMeetingBackupStore: Sendable {
    static let retention: TimeInterval = 3 * 24 * 60 * 60
    private static let receiptFilename = "receipt.json"
    private static let lock = NSRecursiveLock()

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
        Self.lock.lock()
        defer { Self.lock.unlock() }
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
        Self.lock.lock()
        defer { Self.lock.unlock() }
        let folder = folder(for: receipt.id)
        // A fix whose last backup was just dropped (its meeting was deleted)
        // must not come back.
        guard fileManager.fileExists(atPath: folder.path) else { return }
        let url = folder.appendingPathComponent(Self.receiptFilename)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(receipt).write(to: url, options: .atomic)
        fileManager.restrictFileToOwnerOnly(at: url)
    }

    func remove(id: String, fileManager: FileManager = .default) {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        try? fileManager.removeItem(at: folder(for: id))
    }

    func removeBackup(_ change: DictionaryPastMeetingFileChange, id: String, fileManager: FileManager = .default) {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        try? fileManager.removeItem(at: folder(for: id).appendingPathComponent(change.backupFilename))
    }

    /// Fixes that can still be undone, newest first, leaving out meetings
    /// that aren't in the meetings folder right now. Read-only: a meeting
    /// deleted from Home can still come back with its Undo, so only
    /// `prune` and `removeBackups` delete anything.
    func recentReceipts(
        meetingsDirectory: URL,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) -> [DictionaryPastMeetingFixReceipt] {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        var receipts: [DictionaryPastMeetingFixReceipt] = []
        for (_, stored) in storedReceipts(fileManager: fileManager) {
            guard var receipt = stored, now.timeIntervalSince(receipt.createdAt) <= Self.retention else { continue }
            receipt.changes.removeAll { !fileManager.fileExists(atPath: $0.url(in: meetingsDirectory).path) }
            if !receipt.changes.isEmpty {
                receipts.append(receipt)
            }
        }
        return receipts.sorted { $0.createdAt > $1.createdAt }
    }

    /// Drops backups older than the retention window and backups of meetings
    /// that no longer exist (deleted, or renamed so Undo couldn't find them),
    /// so a deleted meeting never lingers here. Called at launch.
    func prune(meetingsDirectory: URL, now: Date = Date(), fileManager: FileManager = .default) {
        // A library on a drive that isn't mounted looks like every meeting is
        // gone. Wait until it's back instead of dropping every backup.
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: meetingsDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return }
        Self.lock.lock()
        defer { Self.lock.unlock() }
        for (folder, stored) in storedReceipts(fileManager: fileManager) {
            guard let receipt = stored else {
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
            let gone = receipt.changes.filter { !fileManager.fileExists(atPath: $0.url(in: meetingsDirectory).path) }
            if !gone.isEmpty {
                dropping(gone, from: receipt, fileManager: fileManager)
            }
        }
    }

    /// Deletes every backup of the given meetings. Called when meetings are
    /// deleted, so no copy of a deleted meeting stays behind.
    func removeBackups(forMeetingsAt urls: [URL], fileManager: FileManager = .default) {
        let filenames = Set(urls.map(\.lastPathComponent))
        guard !filenames.isEmpty else { return }
        Self.lock.lock()
        defer { Self.lock.unlock() }
        for (_, stored) in storedReceipts(fileManager: fileManager) {
            guard let receipt = stored else { continue }
            let matching = receipt.changes.filter { filenames.contains($0.filename) }
            if !matching.isEmpty {
                dropping(matching, from: receipt, fileManager: fileManager)
            }
        }
    }

    /// Replaces a fix's receipt with what's still left to undo, or removes
    /// the fix once nothing is.
    func keepOnly(_ changes: [DictionaryPastMeetingFileChange], of receipt: DictionaryPastMeetingFixReceipt, fileManager: FileManager = .default) -> DictionaryPastMeetingFixReceipt? {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        let dropped = receipt.changes.filter { !changes.contains($0) }
        let updated = dropping(dropped, from: receipt, fileManager: fileManager)
        return updated.changes.isEmpty ? nil : updated
    }

    private func storedReceipts(fileManager: FileManager) -> [(URL, DictionaryPastMeetingFixReceipt?)] {
        guard let folders = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return folders.map { folder in
            let data = try? Data(contentsOf: folder.appendingPathComponent(Self.receiptFilename))
            let receipt = data.flatMap { try? decoder.decode(DictionaryPastMeetingFixReceipt.self, from: $0) }
            return (folder, receipt.flatMap { Self.isWellFormed($0, in: folder) ? $0 : nil })
        }
    }

    /// Cleanup deletes paths built from a receipt, so only trust one whose id
    /// is its own folder's UUID name and whose backups are plain `N.md` files.
    private static func isWellFormed(_ receipt: DictionaryPastMeetingFixReceipt, in folder: URL) -> Bool {
        guard UUID(uuidString: receipt.id) != nil, receipt.id == folder.lastPathComponent else { return false }
        return receipt.changes.allSatisfy { change in
            let name = change.backupFilename
            guard name.hasSuffix(".md") else { return false }
            let index = name.dropLast(3)
            return !index.isEmpty && index.allSatisfy(\.isASCII) && index.allSatisfy(\.isNumber)
        }
    }

    /// Removes some meetings' backups from a fix. The whole fix goes once no
    /// backups are left.
    @discardableResult
    private func dropping(
        _ changes: [DictionaryPastMeetingFileChange],
        from receipt: DictionaryPastMeetingFixReceipt,
        fileManager: FileManager
    ) -> DictionaryPastMeetingFixReceipt {
        var updated = receipt
        guard !changes.isEmpty else { return updated }
        for change in changes {
            removeBackup(change, id: receipt.id, fileManager: fileManager)
        }
        updated.changes.removeAll { change in changes.contains(change) }
        if updated.changes.isEmpty {
            remove(id: receipt.id, fileManager: fileManager)
        } else {
            try? save(updated, fileManager: fileManager)
        }
        return updated
    }
}
