import CryptoKit
import Darwin
import Foundation

/// Local authority for a selected replacement target, captured before an async
/// preparation wait. Modern captures bind their UUID; older meetings without a
/// UUID bind the exact readable file and bytes instead. Never log this value.
public struct TranscriptReplacementExpectation: Equatable, Sendable {
    let captureID: UUID?
    private let legacy: LegacyFingerprint?

    private struct LegacyFingerprint: Equatable, Sendable {
        let device: Int32
        let inode: UInt64
        let bornSeconds: Int
        let bornNanos: Int
        let digest: Data
    }

    public static func capture(
        at url: URL, expectedCaptureID: UUID? = nil, requiringLegacy: Bool = false
    ) throws -> Self {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw CocoaError(.fileReadNoSuchFile) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var prefix = Data()
        var hasher = SHA256()
        while try autoreleasepool(invoking: { () throws -> Bool in
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty else { return false }
            if prefix.count < TranscriptFrontmatter.maximumFrontmatterByteLimit {
                prefix.append(chunk.prefix(TranscriptFrontmatter.maximumFrontmatterByteLimit - prefix.count))
            }
            hasher.update(data: chunk)
            return true
        }) {}
        let raw = String(decoding: prefix, as: UTF8.self)
        let values = TranscriptFrontmatter.values(in: raw)
        if values == nil {
            // A malformed/oversized YAML header may conceal protection metadata;
            // it must never acquire a legacy exemption from the write guard.
            let fences = ["---\n", "---\r\n", "\u{FEFF}---\n", "\u{FEFF}---\r\n"]
            guard !fences.contains(where: { raw.hasPrefix($0) }) else { throw CocoaError(.fileReadCorruptFile) }
        }
        let actualID = values.flatMap(TranscriptFrontmatter.captureID(in:))
        guard !requiringLegacy || actualID == nil else { throw CocoaError(.fileReadCorruptFile) }
        guard expectedCaptureID == nil || actualID == expectedCaptureID else {
            throw CocoaError(.fileReadCorruptFile)
        }
        if let actualID { return Self(captureID: actualID, legacy: nil) }
        return Self(captureID: nil, legacy: LegacyFingerprint(
            device: info.st_dev, inode: info.st_ino,
            bornSeconds: info.st_birthtimespec.tv_sec, bornNanos: info.st_birthtimespec.tv_nsec,
            digest: Data(hasher.finalize())
        ))
    }

    func matches(at url: URL) throws -> Bool {
        let current = try Self.capture(at: url, requiringLegacy: captureID == nil)
        return self == current
    }
}
