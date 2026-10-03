import CryptoKit
import Darwin
import Foundation

/// Promise: importing an audio file copies it byte-for-byte into an
/// owner-only scratch file without holding the whole file in memory, and the
/// scratch copy never inherits the source's locks, flags or extended
/// attributes. A 1 h WAV is ~0.7 GB, so a copy loop that keeps every chunk
/// alive spikes the app by the file's size and leaves it dirty for minutes.
func testMeetingImportedAudioCopyMemory() async {
    await runSuite("Importing a large audio file copies it exactly without holding it in memory") {
        let root = importCopyMemoryTemporaryRoot()
        let sourceURL = root.appendingPathComponent("long-call.wav")
        let destinationURL = root.appendingPathComponent("imported-long-call.wav")
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let megabytes = 96
        let sourceDigest = try! importCopyMemoryWriteVariedFile(at: sourceURL, megabytes: megabytes)

        let before = importCopyMemoryPhysicalFootprint()
        let task = Task.detached {
            try MeetingImportedAudioPreparer.copyInterruptibly(
                from: sourceURL,
                to: destinationURL,
                fileManager: FileManager.default
            )
        }
        do {
            try await task.value
        } catch {
            assertTrue(false, "copying a readable file should succeed, got \(error)")
            return
        }
        let after = importCopyMemoryPhysicalFootprint()
        let grown = after > before ? after - before : 0

        assertEqual(importCopyMemoryDigest(of: destinationURL), sourceDigest, "the scratch copy must match the source byte for byte")
        let mode = (try? FileManager.default.attributesOfItem(atPath: destinationURL.path))?[.posixPermissions] as? NSNumber
        assertEqual(mode?.intValue, 0o600, "the scratch copy must be owner-only")
        // Without a pool per chunk, every 1 MB chunk is still resident here
        // (about +96 MB). With it, growth stays a few MB.
        assertTrue(
            grown < 32 * 1024 * 1024,
            "footprint grew \(grown / 1_048_576) MB while copying \(megabytes) MB"
        )
    }

    await runSuite("Imported audio scratch copy drops the source's flags and extended attributes") {
        let root = importCopyMemoryTemporaryRoot()
        let sourceURL = root.appendingPathComponent("Locked Call.wav")
        let scratchURL = root.appendingPathComponent("scratch", isDirectory: true)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            chflags(sourceURL.path, 0)
            try? FileManager.default.removeItem(at: root)
        }
        FileManager.default.createFile(atPath: sourceURL.path, contents: Data(repeating: 7, count: 64 * 1024))
        let oldDate = Date(timeIntervalSince1970: 1_704_067_200) // 2024-01-01
        try! FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: sourceURL.path)
        let sourceXattrs = ["com.apple.metadata:_kMDItemUserTags", "com.apple.metadata:kMDItemWhereFroms"]
        for name in sourceXattrs {
            let value = Array("fixture".utf8)
            _ = setxattr(sourceURL.path, name, value, value.count, 0, 0)
        }
        assertEqual(chflags(sourceURL.path, UInt32(UF_IMMUTABLE | UF_HIDDEN)), 0, "fixture setup: lock and hide the source")

        let prepared: PreparedImportedMeetingAudio
        do {
            prepared = try await MeetingImportedAudioPreparer.prepareImportedAudio(
                from: sourceURL,
                scratchDirectory: scratchURL
            )
        } catch {
            assertTrue(false, "a locked, hidden audio file should still import, got \(error)")
            return
        }
        let copyPath = prepared.copiedAudioURL.path

        var status = stat()
        assertEqual(lstat(copyPath, &status), 0, "the scratch copy should exist")
        assertEqual(status.st_flags, 0, "the scratch copy must not inherit locked or hidden flags")
        assertEqual(Int(status.st_mode & 0o777), 0o600, "the scratch copy must be owner-only")
        let copyXattrs = importCopyMemoryXattrNames(atPath: copyPath)
        for name in sourceXattrs {
            assertFalse(copyXattrs.contains(name), "the scratch copy must not carry \(name)")
        }
        let copyModified = (try? FileManager.default.attributesOfItem(atPath: copyPath))?[.modificationDate] as? Date
        assertTrue((copyModified ?? oldDate) > oldDate, "the scratch copy is a new file, not a clone with the source's dates")
        assertNoThrow({ try FileManager.default.removeItem(atPath: copyPath) }, "the scratch copy must stay removable")
    }
}

private func assertNoThrow(_ body: () throws -> Void, _ message: String) {
    do { try body() } catch { assertTrue(false, "\(message): \(error)") }
}

private func importCopyMemoryTemporaryRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
        "MeetingImportedAudioCopyMemoryTests-\(UUID().uuidString)",
        isDirectory: true
    )
}

private func importCopyMemoryPhysicalFootprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? info.phys_footprint : 0
}

private func importCopyMemoryWriteVariedFile(at url: URL, megabytes: Int) throws -> String {
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    var hash = SHA256()
    var block = Data(count: 1024 * 1024)
    for index in 0..<megabytes {
        block.withUnsafeMutableBytes { bytes in
            for offset in stride(from: 0, to: bytes.count, by: 4096) {
                bytes[offset] = UInt8(truncatingIfNeeded: index &+ offset)
            }
        }
        hash.update(data: block)
        try handle.write(contentsOf: block)
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}

private func importCopyMemoryDigest(of url: URL) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    var hash = SHA256()
    while let chunk = autoreleasepool(invoking: { try? handle.read(upToCount: 1 << 20) }), !chunk.isEmpty {
        hash.update(data: chunk)
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}

private func importCopyMemoryXattrNames(atPath path: String) -> [String] {
    let size = listxattr(path, nil, 0, 0)
    guard size > 0 else { return [] }
    var buffer = [CChar](repeating: 0, count: size)
    guard listxattr(path, &buffer, size, 0) == size else { return [] }
    return buffer.split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
}
