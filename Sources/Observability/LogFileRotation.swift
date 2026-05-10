import Foundation

enum LogFileRotation {
    static func rotateIfNeeded(
        fileURL: URL,
        threshold: UInt64 = TranscriptedConstants.logRotationThreshold,
        keepLines: Int = TranscriptedConstants.logRotationKeepLines,
        fileManager: FileManager = .default
    ) throws {
        guard keepLines > 0,
              fileManager.fileExists(atPath: fileURL.path),
              let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
              let size = attributes[.size] as? UInt64,
              size > threshold,
              let data = fileManager.contents(atPath: fileURL.path),
              let content = String(data: data, encoding: .utf8) else {
            return
        }

        var lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" {
            lines.removeLast()
        }
        var kept = lines.suffix(keepLines).joined(separator: "\n")
        if !kept.isEmpty {
            kept.append("\n")
        }
        try kept.write(to: fileURL, atomically: true, encoding: .utf8)
        fileManager.restrictFileToOwnerOnly(at: fileURL)
    }
}
