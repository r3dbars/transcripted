import CryptoKit
import Darwin
import Foundation
import Testing
@testable import TranscriptedWritingRuntime

/// Promise: verifying a model file gives the exact SHA-256 and never holds
/// the file in memory. The launch check hashes the 5.2 GB Writing model, so a
/// hasher that keeps every chunk alive spikes the app by the model's size.
@Suite("Model file hasher")
struct ModelFileHasherTests {
    private static func physicalFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    private static func makeFile(megabytes: Int) throws -> (url: URL, digest: String) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-hasher-\(UUID().uuidString).gguf")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        var hash = SHA256()
        var block = Data(count: 1024 * 1024)
        for index in 0..<megabytes {
            block.withUnsafeMutableBytes { bytes in
                for offset in stride(from: 0, to: bytes.count, by: 4096) { bytes[offset] = UInt8(truncatingIfNeeded: index &+ offset) }
            }
            hash.update(data: block)
            try handle.write(contentsOf: block)
        }
        try handle.close()
        return (url, hash.finalize().map { String(format: "%02x", $0) }.joined())
    }

    @Test("Hashing gives the exact SHA-256 of the file")
    func exactDigest() throws {
        let (url, digest) = try Self.makeFile(megabytes: 3)
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        #expect(try ModelFileHasher.sha256Hex(from: handle) == digest)
    }

    @Test("Hashing a large file doesn't keep its chunks in memory")
    func memoryStaysFlat() throws {
        // Footprint is process-wide and other suites run in parallel, so the
        // file is big enough that the no-pool case (~192 MB) can't hide under
        // their noise, and the bar sits well clear of both.
        let megabytes = 192
        let (url, digest) = try Self.makeFile(megabytes: megabytes)
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let before = Self.physicalFootprint()
        let result = try ModelFileHasher.sha256Hex(from: handle)
        let after = Self.physicalFootprint()
        // Parallel suites can free memory meanwhile; a shrink is zero growth,
        // not an unsigned wrap.
        let grown = after > before ? after - before : 0
        #expect(result == digest)
        // Without a pool per chunk, all 192 chunks are still alive here
        // (footprint grows by ~192 MB). With it, growth stays a few MB.
        #expect(grown < 64 * 1024 * 1024, "footprint grew \(grown / 1_048_576) MB while hashing \(megabytes) MB")
    }
}
