import Foundation

/// Lightweight per-file summaries of `Writing_<date>.md` day files, kept
/// between Stats rebuilds and reused while a file's size and modification date
/// are unchanged. Only counts and timestamps are retained — never full entry
/// body text. Thread-safe: rebuilds run off the main thread and can overlap.
final class TodayWritingDayFileCache: @unchecked Sendable {
    struct Signature: Equatable, Sendable {
        let modifiedAt: Date?
        let size: Int?
    }

    static let shared = TodayWritingDayFileCache()

    private let lock = NSLock()
    private var entries: [String: (signature: Signature, summary: TodayWritingDaySummary)] = [:]

    /// The file's signature. URLs cache their resource values, so pass one
    /// from this scan's directory listing (which prefetches both keys).
    static func signature(of file: URL) -> Signature {
        let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return Signature(modifiedAt: values?.contentModificationDate, size: values?.fileSize)
    }

    /// The day file's summary: cached counts when `signature` and `day` match,
    /// else `read()` parsed into counts and cached. Nil when the file can't be read.
    func summary(
        for file: URL,
        day: Date,
        signature: Signature,
        read: () -> String?
    ) -> TodayWritingDaySummary? {
        let key = file.standardizedFileURL.path
        lock.lock()
        let cached = entries[key]
        lock.unlock()
        // A signature with no date or size can't prove the file is unchanged.
        if let cached,
           cached.signature == signature,
           cached.summary.day == day,
           signature.modifiedAt != nil,
           signature.size != nil {
            return cached.summary
        }
        guard let contents = read() else { return nil }
        let summary = TodayWritingParser.daySummary(fromDayFile: contents, day: day)
        lock.lock()
        entries[key] = (signature, summary)
        lock.unlock()
        return summary
    }

    /// Drops files no longer in the scanned range (or deleted).
    func retainOnly(_ files: [URL]) {
        let keep = Set(files.map { $0.standardizedFileURL.path })
        lock.lock()
        entries = entries.filter { keep.contains($0.key) }
        lock.unlock()
    }
}
