import Foundation

/// What Writing keeps on this Mac, for the Writing tab's storage meter.
/// Sizes only: nothing here opens a file's contents.
///
/// Foundation only, so the root fast tests compile it.
struct WritingStorageUsage: Equatable, Sendable {
    /// The `Writing_*.md` day files in the capture library.
    let savedWritingBytes: Int64
    /// Personalized-suggestion history and the text-free outcome ledger.
    let learningBytes: Int64
    /// Downloaded autocomplete models, finished or partial.
    let modelBytes: Int64

    var totalBytes: Int64 { savedWritingBytes + learningBytes + modelBytes }

    struct Segment: Equatable {
        let label: String
        let bytes: Int64
        /// Share of the total, 0...1. Zero when nothing is stored.
        let fraction: Double
    }

    /// The meter's three parts, largest-first order kept fixed so colors
    /// don't jump: model, saved writing, learning data.
    var segments: [Segment] {
        let total = totalBytes
        func share(_ bytes: Int64) -> Double {
            total > 0 ? Double(max(0, bytes)) / Double(total) : 0
        }
        return [
            Segment(label: "Model", bytes: modelBytes, fraction: share(modelBytes)),
            Segment(label: "Saved writing", bytes: savedWritingBytes, fraction: share(savedWritingBytes)),
            Segment(label: "Learning data", bytes: learningBytes, fraction: share(learningBytes)),
        ]
    }

    static func formatted(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: max(0, bytes))
    }

    /// "3.4 GB on this Mac" or "Nothing stored yet".
    var summary: String {
        totalBytes > 0 ? "\(Self.formatted(totalBytes)) on this Mac" : "Nothing stored yet"
    }

    /// "Model 3.4 GB · Saved writing 24 KB · Learning data 1 MB", skipping
    /// empty parts.
    var legend: String {
        segments.filter { $0.bytes > 0 }
            .map { "\($0.label) \(Self.formatted($0.bytes))" }
            .joined(separator: " · ")
    }

    // MARK: - Measuring

    /// The day files directly inside the writing folder.
    static func dayFileBytes(in directory: URL, fileManager: FileManager = .default) -> Int64 {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return 0 }
        return names
            .filter { $0.hasPrefix("Writing_") && $0.hasSuffix(".md") }
            .reduce(0) { $0 + regularFileBytes(directory.appendingPathComponent($1)) }
    }

    /// Every regular file under `root`, without following symlinks.
    static func fileBytes(under root: URL, fileManager: FileManager = .default) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: []
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += regularFileBytes(url)
        }
        return total
    }

    private static func regularFileBytes(_ url: URL) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true else { return 0 }
        return Int64(values.fileSize ?? 0)
    }
}
