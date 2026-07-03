import Foundation

/// Measures and buckets the on-disk size of the capture library.
///
/// Retained meeting audio defaults to `AudioRetentionWindow.never`, so a busy
/// user's library grows without bound and nothing in the app ever says so. A
/// once-per-launch measurement (reported next to the retention setting) makes
/// that growth visible in the event log instead of being discovered only when
/// the disk fills.
enum CaptureLibrarySize {
    /// Sum of regular-file sizes under `url`, skipping symlinks so a linked
    /// external folder is never double-counted or traversed. Returns nil when
    /// the directory cannot be enumerated.
    static func measureBytes(at url: URL, fileManager: FileManager = .default) -> Int64? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsPackageDescendants]
        ) else {
            return nil
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
            ) else { continue }
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            guard values.isRegularFile == true, let size = values.fileSize else { continue }
            total += Int64(size)
        }
        return total
    }

    /// Coarse size bucket safe for telemetry — never the exact byte count.
    static func bucketLabel(forBytes bytes: Int64) -> String {
        let gigabyte: Int64 = 1024 * 1024 * 1024
        switch bytes {
        case ..<(gigabyte): return "under_1gb"
        case ..<(5 * gigabyte): return "1_5gb"
        case ..<(20 * gigabyte): return "5_20gb"
        case ..<(50 * gigabyte): return "20_50gb"
        default: return "over_50gb"
        }
    }
}
