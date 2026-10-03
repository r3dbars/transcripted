import CryptoKit
import Darwin
import Foundation
import Testing
@testable import TranscriptedWritingRuntime

/// The launch check hashes a clone of the installed model once and the runtime
/// handoff serves exactly those hashed bytes.
@Suite("Verified model manager: held clone handoff")
struct ModelManagerHeldCloneTests {
    private struct NoNetwork: ModelDownloadTransport {
        func response(for request: URLRequest) async throws -> ModelDownloadResponse {
            throw URLError(.badServerResponse)
        }
    }

    private struct Fixture {
        let data: Data
        let manager: ModelManager

        init() {
            data = Data([0x47, 0x47, 0x55, 0x46]) + Data("held clone fixture bytes".utf8)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let descriptor = ModelDescriptor(
                identifier: "fixture-\(UUID().uuidString)",
                version: "fixture",
                repository: "tests/fixtures",
                revision: "0123456789abcdef0123456789abcdef01234567",
                fileName: "fixture.gguf",
                expectedBytes: Int64(data.count),
                sha256: digest
            )
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("tilde-held-clone-\(UUID().uuidString)", isDirectory: true)
            manager = ModelManager(
                descriptor: descriptor,
                rootDirectory: root,
                transport: NoNetwork(),
                callbackQueue: .global(qos: .utility),
                availableDiskSpace: { _ in Int64.max },
                retryDelays: []
            )
        }

        func install(mode: Int = 0o600) throws {
            try FileManager.default.createDirectory(at: manager.modelDirectory, withIntermediateDirectories: true)
            try data.write(to: manager.modelURL)
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: manager.modelURL.path)
        }

        func launch() async {
            _ = manager.start()
            await manager.waitUntilSettled()
        }

        func strayClones() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: manager.modelDirectory.path)
                .filter { $0.hasPrefix(".model-runtime-") }
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: manager.rootDirectory)
        }
    }

    private func info(_ handle: FileHandle) -> stat {
        var result = stat()
        _ = fstat(handle.fileDescriptor, &result)
        return result
    }

    private func contents(_ handle: FileHandle) throws -> Data? {
        try handle.seek(toOffset: 0)
        return try handle.readToEnd()
    }

    @Test("A launch check hashes once and the first handoff serves those bytes from an unlinked read-only file")
    func firstHandoffServesHashedBytes() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        try fixture.install()
        await fixture.launch()
        #expect(fixture.manager.state == .ready(fixture.manager.modelURL))

        let handoff = try #require(fixture.manager.verifiedInstalledModelFile())
        defer { try? handoff.handle.close() }
        #expect(fixture.manager.fullVerificationCount == 1)
        #expect(try contents(handoff.handle) == fixture.data)
        let served = info(handoff.handle)
        #expect(served.st_nlink == 0)
        #expect(served.st_mode & 0o7777 == 0o400)
        #expect(try fixture.strayClones().isEmpty)
    }

    @Test("Helper restarts never re-hash and each gets its own unlinked copy of the hashed bytes")
    func restartsDoNotRehash() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        try fixture.install()
        await fixture.launch()

        var inodes: [UInt64] = []
        for _ in 0..<3 {
            let handoff = try #require(fixture.manager.verifiedInstalledModelFile())
            #expect(try contents(handoff.handle) == fixture.data)
            let served = info(handoff.handle)
            #expect(served.st_nlink == 0)
            #expect(served.st_mode & 0o7777 == 0o400)
            inodes.append(served.st_ino)
            try? handoff.handle.close()
        }
        #expect(fixture.manager.fullVerificationCount == 1)
        #expect(inodes[1] != inodes[0])
        #expect(inodes[2] != inodes[1])
        #expect(try fixture.strayClones().isEmpty)
    }

    @Test("A writer holding a shared mapping can't get unhashed bytes into the handoff")
    func sharedMappingWriteIsNeverServed() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        try fixture.install()
        await fixture.launch()
        let first = try #require(fixture.manager.verifiedInstalledModelFile())
        try? first.handle.close()

        let descriptor = open(fixture.manager.modelURL.path, O_RDWR)
        #expect(descriptor >= 0)
        let length = fixture.data.count
        let mapping = mmap(nil, length, PROT_READ | PROT_WRITE, MAP_SHARED, descriptor, 0)
        close(descriptor)
        let base = try #require(mapping == MAP_FAILED ? nil : mapping)
        defer { munmap(base, length) }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        bytes[6] = bytes[6] &+ 1

        if let handoff = fixture.manager.verifiedInstalledModelFile() {
            #expect(try contents(handoff.handle) == fixture.data)
            try? handoff.handle.close()
        }
    }

    @Test("A 0644 installed model is tightened to 0600, not deleted or downloaded again")
    func looseModeIsTightened() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        try fixture.install(mode: 0o644)
        await fixture.launch()

        #expect(fixture.manager.state == .ready(fixture.manager.modelURL))
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.manager.modelURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try Data(contentsOf: fixture.manager.modelURL) == fixture.data)
    }

    @Test("Cancelling a launch check never deletes the installed model")
    func cancelDuringLaunchCheckKeepsModel() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        try fixture.install()
        _ = fixture.manager.start()
        fixture.manager.cancel()
        await fixture.launch()

        #expect(fixture.manager.state == .ready(fixture.manager.modelURL))
        #expect(try Data(contentsOf: fixture.manager.modelURL) == fixture.data)
    }

    @Test("Cancelling the manager (Autocomplete off, model switch) drops the held clone, so the next handoff hashes again")
    func cancelDropsHeldClone() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        try fixture.install()
        await fixture.launch()
        fixture.manager.cancel()

        let handoff = try #require(fixture.manager.verifiedInstalledModelFile())
        defer { try? handoff.handle.close() }
        #expect(fixture.manager.fullVerificationCount == 2)
        #expect(try contents(handoff.handle) == fixture.data)
    }

    @Test("A cancelled model hash throws CancellationError instead of returning a digest")
    func cancelledHashThrows() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tilde-hash-cancel-\(UUID().uuidString)")
        try Data(repeating: 1, count: 4096).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let cancellation = ModelHashCancellation()
        cancellation.cancel()
        #expect(throws: CancellationError.self) {
            _ = try ModelFileHasher.sha256Hex(from: handle, chunkSize: 1024, isCancelled: cancellation.isCancelled)
        }
        try handle.seek(toOffset: 0)
        let digest = try ModelFileHasher.sha256Hex(from: handle, chunkSize: 1024)
        #expect(digest == SHA256.hash(data: Data(repeating: 1, count: 4096)).map { String(format: "%02x", $0) }.joined())
    }
}
