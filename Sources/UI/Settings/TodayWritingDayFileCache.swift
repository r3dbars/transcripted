import Foundation

/// Parsed `Writing_<date>.md` day files, kept between Today rebuilds and
/// reused while a file's size and modification date are unchanged. A rebuild
/// after one save re-parses only the day file that changed instead of the
/// whole week. Thread-safe: rebuilds run off the main thread and can overlap.
final class TodayWritingDayFileCache: @unchecked Sendable {
    struct Signature: Equatable, Sendable {
        let modifiedAt: Date?
        let size: Int?
    }

    static let shared = TodayWritingDayFileCache()

    private let lock = NSLock()
    private var entries: [String: (signature: Signature, facts: [TodayWritingFact])] = [:]

    /// The file's signature. URLs cache their resource values, so pass one
    /// from this scan's directory listing (which prefetches both keys).
    static func signature(of file: URL) -> Signature {
        let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return Signature(modifiedAt: values?.contentModificationDate, size: values?.fileSize)
    }

    /// The day file's entries: the cached parse when `signature` matches,
    /// else `read()` parsed and cached. Nil when the file can't be read.
    func facts(
        for file: URL,
        signature: Signature,
        read: () -> String?
    ) -> [TodayWritingFact]? {
        let key = file.standardizedFileURL.path
        lock.lock()
        let cached = entries[key]
        lock.unlock()
        // A signature with no date or size can't prove the file is unchanged.
        if let cached, cached.signature == signature, signature.modifiedAt != nil, signature.size != nil {
            return cached.facts
        }
        guard let contents = read() else { return nil }
        let facts = TodayWritingParser.entries(fromDayFile: contents)
        lock.lock()
        entries[key] = (signature, facts)
        lock.unlock()
        return facts
    }

    /// Drops files no longer in the scanned range (or deleted).
    func retainOnly(_ files: [URL]) {
        let keep = Set(files.map { $0.standardizedFileURL.path })
        lock.lock()
        entries = entries.filter { keep.contains($0.key) }
        lock.unlock()
    }
}
