// ImportedAudioContentKey.swift
// The content key of an imported recording: hex SHA-256 of the source file's
// bytes. Two imports of the same file get the same key, so speaker
// confirmations from re-importing it count as one meeting
// (`SpeakerConfirmationMeetingID`). The key stays on this Mac (import
// journal, speaker ledger); never log it or send it anywhere.

import CryptoKit
import Foundation

struct PreparedImportedMeetingAudio: Sendable {
    let copiedAudioURL: URL
    /// Nil only when the source couldn't be read a second time for hashing
    /// (video imports hash the source separately from extracting its audio).
    let sourceContentKey: String?
    let suggestedTitle: String
    let recordingDate: Date
}

enum ImportedMeetingMediaKind: Equatable {
    case audio
    case audiovisual
}

enum ImportedAudioContentKey {
    /// Incremental hash over the chunks a copy already streams, so an audio
    /// import is read only once.
    struct Hasher {
        private var digest = SHA256()

        mutating func update(_ chunk: Data) {
            digest.update(data: chunk)
        }

        func finalize() -> String {
            digest.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }

    /// Streams `url` in chunks and returns its content key. Returns nil when the
    /// file can't be read; only cancellation throws. Never blocks the import on
    /// a hashing problem: without a key, confirmations fall back to counting per
    /// transcript, as before.
    static func ofFile(at url: URL, chunkSize: Int = 1 << 20) throws -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = Hasher()
        do {
            while try autoreleasepool(invoking: { () throws -> Bool in
                try Task.checkCancellation()
                guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else { return false }
                hasher.update(chunk)
                return true
            }) {}
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
        return hasher.finalize()
    }
}
