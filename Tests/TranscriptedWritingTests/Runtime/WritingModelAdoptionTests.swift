import CryptoKit
import Foundation
import Testing
@testable import TranscriptedWritingCore
@testable import TranscriptedWritingRuntime

/// Tilde-model adoption against fixture files in a temp directory. Never
/// points at the real `~/Library/Application Support/Tilde`.
struct WritingModelAdoptionTests {
    private final class DownloadCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func record() { lock.withLock { count += 1 } }
        var calls: Int { lock.withLock { count } }
    }

    private struct Fixture {
        let root: URL
        let tildeModels: URL
        let descriptor: ModelDescriptor
        let bytes: Data
        let downloads = DownloadCounter()

        init() throws {
            let base = FileManager.default.temporaryDirectory
                .appendingPathComponent("writing-adoption-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            // The owner-only helpers refuse symlinked paths (/var -> /private/var).
            root = base.resolvingSymlinksInPath()
            tildeModels = root.appendingPathComponent("Tilde/Models", isDirectory: true)
            var bytes = Data([0x47, 0x47, 0x55, 0x46])
            bytes.append(contentsOf: (0..<8_188).map { UInt8($0 % 251) })
            self.bytes = bytes
            descriptor = ModelDescriptor(
                identifier: "writing-test-model",
                version: "1",
                repository: "fixture/writing-test-model",
                revision: "0000000000000000000000000000000000000000",
                fileName: "fixture.gguf",
                expectedBytes: Int64(bytes.count),
                sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            )
        }

        var tildeModelURL: URL {
            WritingModelAdoption.tildeModelURL(for: descriptor, in: tildeModels)
        }

        func makeManager() -> ModelManager {
            let downloads = downloads
            return ModelManager(
                descriptor: descriptor,
                rootDirectory: root.appendingPathComponent("Transcripted/models/writing", isDirectory: true),
                transport: ClosureModelDownloadTransport { _ in
                    downloads.record()
                    throw URLError(.badServerResponse)
                },
                callbackQueue: DispatchQueue(label: "writing-adoption-tests"),
                retryDelays: []
            )
        }

        func writeTildeModel(_ data: Data) throws {
            let directory = tildeModelURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: tildeModelURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tildeModelURL.path)
        }

        func adopt(into manager: ModelManager) async -> WritingModelAdoption.Outcome {
            let descriptor = descriptor
            let modelDirectory = manager.modelDirectory
            let tildeModels = tildeModels
            return await Task.detached {
                WritingModelAdoption.adoptIfNeeded(
                    descriptor: descriptor,
                    modelDirectory: modelDirectory,
                    tildeModelsRoot: tildeModels
                )
            }.value
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    @Test func adoptsAVerifiedTildeModelThatModelManagerThenAccepts() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.writeTildeModel(fixture.bytes)
        let manager = fixture.makeManager()

        #expect(await fixture.adopt(into: manager) == .adopted)

        #expect(try Data(contentsOf: manager.modelURL) == fixture.bytes)
        let attributes = try FileManager.default.attributesOfItem(atPath: manager.modelURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(!exists(manager.modelDirectory.appendingPathComponent(WritingModelAdoption.stagingFileName)))
        // Tilde's copy is untouched.
        #expect(try Data(contentsOf: fixture.tildeModelURL) == fixture.bytes)

        manager.prepare()
        await manager.waitUntilSettled()
        #expect(manager.state == .ready(manager.modelURL))
        #expect(fixture.downloads.calls == 0)
    }

    @Test func rejectsAHashMismatchAndLeavesNothingBehind() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        var tampered = fixture.bytes
        tampered[tampered.count - 1] ^= 0xFF
        try fixture.writeTildeModel(tampered)
        let manager = fixture.makeManager()

        #expect(await fixture.adopt(into: manager) == .rejected(.checksumMismatch))

        #expect(!exists(manager.modelURL))
        #expect(!exists(manager.modelDirectory.appendingPathComponent(WritingModelAdoption.stagingFileName)))
        #expect(try Data(contentsOf: fixture.tildeModelURL) == tampered)
    }

    @Test func rejectsAWrongSize() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.writeTildeModel(fixture.bytes + Data([0]))
        let manager = fixture.makeManager()

        #expect(await fixture.adopt(into: manager) == .rejected(.sizeMismatch))
        #expect(!exists(manager.modelURL))
    }

    @Test func rejectsASymlinkedTildeModel() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let elsewhere = fixture.root.appendingPathComponent("elsewhere.gguf")
        try fixture.bytes.write(to: elsewhere)
        try FileManager.default.createDirectory(
            at: fixture.tildeModelURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: fixture.tildeModelURL, withDestinationURL: elsewhere)
        let manager = fixture.makeManager()

        #expect(await fixture.adopt(into: manager) == .rejected(.notRegularFile))
        #expect(!exists(manager.modelURL))
    }

    @Test func reportsNoTildeModel() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let manager = fixture.makeManager()

        #expect(await fixture.adopt(into: manager) == .noTildeModel)
        #expect(!exists(manager.modelURL))
    }

    @Test func leavesAnExistingInstallAlone() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.writeTildeModel(fixture.bytes)
        let manager = fixture.makeManager()
        try FileManager.default.createDirectory(at: manager.modelDirectory, withIntermediateDirectories: true)
        let existing = Data("already here".utf8)
        try existing.write(to: manager.modelURL)

        #expect(await fixture.adopt(into: manager) == .alreadyInstalled)
        #expect(try Data(contentsOf: manager.modelURL) == existing)
    }

    @Test func dropsAStalePartialDownloadAfterAdopting() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.writeTildeModel(fixture.bytes)
        let manager = fixture.makeManager()
        try FileManager.default.createDirectory(
            at: manager.modelDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Data(fixture.bytes.prefix(100)).write(to: manager.partialURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manager.partialURL.path)

        #expect(await fixture.adopt(into: manager) == .adopted)
        #expect(!exists(manager.partialURL))
        #expect(try Data(contentsOf: manager.modelURL) == fixture.bytes)
    }
}
