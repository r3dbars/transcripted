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
    static func sha256Hex(from handle: FileHandle, chunkSize: Int = 1024 * 1024) throws -> String {
        var hash = SHA256()
        while try autoreleasepool(invoking: { () throws -> Bool in
            guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else { return false }
            hash.update(data: chunk)
            return true
        }) {}
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
