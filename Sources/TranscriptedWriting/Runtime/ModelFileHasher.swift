// ModelFileHasher.swift
// SHA-256 of a multi-GB model file without holding it in memory.

import CryptoKit
import Foundation

enum ModelFileHasher {
    /// Hashes the file in 1 MB chunks. Each `read(upToCount:)` hands back an
    /// autoreleased buffer, so without a pool per chunk every chunk stays
    /// alive until the loop ends: hashing the 5.2 GB Writing model at launch
    /// held the whole file in memory (a measured 5.66 GB peak, vs 4 MB with
    /// the pool).
    ///
    /// `isCancelled` is checked before every chunk; once it returns true the
    /// hash stops and throws `CancellationError`, never a verdict.
    static func sha256Hex(
        from handle: FileHandle,
        chunkSize: Int = 1024 * 1024,
        isCancelled: () -> Bool = { false }
    ) throws -> String {
        var hash = SHA256()
        while try autoreleasepool(invoking: { () throws -> Bool in
            if isCancelled() { throw CancellationError() }
            guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else { return false }
            hash.update(data: chunk)
            return true
        }) {}
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// A cancel flag a hash running on a dispatch queue polls per chunk; set from
/// a Swift task's cancellation handler.
final class ModelHashCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func isCancelled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}
