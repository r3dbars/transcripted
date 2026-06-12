// ObservabilityLogRotation.swift
// Rename-based rotation for append-only JSONL observability logs.

import Foundation

enum ObservabilityLogRotation {
    /// Rotate `fileURL` by renaming it to `<name>.<ext>.1` once it exceeds
    /// `threshold` bytes. Rename keeps rotation O(1) and atomic: no contents
    /// are read or rewritten, and a concurrent writer holding the old
    /// descriptor keeps appending to the rotated file instead of losing or
    /// splicing records mid-rotation. One rotated generation is kept, so disk
    /// use stays bounded at roughly twice the threshold per log.
    @discardableResult
    static func rotateIfNeeded(at fileURL: URL, threshold: UInt64) -> Bool {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.size] as? UInt64,
              size > threshold else {
            return false
        }

        let rotatedURL = fileURL.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: rotatedURL)
        do {
            try FileManager.default.moveItem(at: fileURL, to: rotatedURL)
            FileManager.default.restrictFileToOwnerOnly(at: rotatedURL)
            return true
        } catch {
            fputs("⚠️ LOG | failed to rotate \(fileURL.lastPathComponent): \(ObservabilityTextRedactor.redact(error.localizedDescription))\n", stderr)
            return false
        }
    }
}
