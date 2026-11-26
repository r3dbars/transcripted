import Foundation

/// Byte size of saved writing day files (`Writing_*.md`) on this Mac.
/// Sizes only: never opens file contents. Foundation-only for fast tests.
struct WritingStorageUsage: Equatable, Sendable {
    let savedWritingBytes: Int64

    static func formatted(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: max(0, bytes))
    }

    var summary: String {
        savedWritingBytes > 0 ? "\(Self.formatted(savedWritingBytes)) saved on this Mac" : "Nothing saved yet"
    }

    /// The day files directly inside the writing folder.
    static func dayFileBytes(in directory: URL, fileManager: FileManager = .default) -> Int64 {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return 0 }
        return names
            .filter { $0.hasPrefix("Writing_") && $0.hasSuffix(".md") }
            .reduce(0) { $0 + regularFileBytes(directory.appendingPathComponent($1)) }
    }

    private static func regularFileBytes(_ url: URL) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true else { return 0 }
        return Int64(values.fileSize ?? 0)
    }
}
