import CryptoKit
import Foundation
import Testing
@testable import TranscriptedWritingRuntime

@Suite("Verified model manager")
struct ModelManagerTests {
    private actor StubTransport: ModelDownloadTransport {
        var responses: [ModelDownloadResponse]
        var requests: [URLRequest] = []

        init(_ responses: [ModelDownloadResponse]) {
            self.responses = responses
        }

        func response(for request: URLRequest) async throws -> ModelDownloadResponse {
            requests.append(request)
            guard !responses.isEmpty else { throw URLError(.badServerResponse) }
            return responses.removeFirst()
        }
    }

    private struct Fixture {
        let data: Data
        let descriptor: ModelDescriptor
        let root: URL

        init(expectedHash: String? = nil) {
            data = Data([0x47, 0x47, 0x55, 0x46]) + Data("test Gemma bytes".utf8)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            descriptor = ModelDescriptor(
                identifier: "fixture-\(UUID().uuidString)",
                version: "fixture",
                repository: "tests/fixtures",
                revision: "0123456789abcdef0123456789abcdef01234567",
                fileName: "fixture.gguf",
                expectedBytes: Int64(data.count),
                sha256: expectedHash ?? digest
            )
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("tilde-model-manager-\(UUID().uuidString)", isDirectory: true)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func stream(_ chunks: [Data]) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
    }

    private func response(
        status: Int = 200,
        headers: [String: String] = [:],
        chunks: [Data]
    ) -> ModelDownloadResponse {
        ModelDownloadResponse(statusCode: status, headers: headers, body: stream(chunks))
    }

    private func manager(
        fixture: Fixture,
        transport: any ModelDownloadTransport,
        onProgress: ModelManager.ProgressHandler? = nil,
        availableDiskSpace: @escaping ModelManager.DiskSpaceProvider = { _ in Int64.max },
        retryDelays: [Duration] = []
    ) -> ModelManager {
        ModelManager(
            descriptor: fixture.descriptor,
            rootDirectory: fixture.root,
            transport: transport,
            callbackQueue: .global(qos: .utility),
            onProgress: onProgress,
            availableDiskSpace: availableDiskSpace,
            retryDelays: retryDelays
        )
    }

    @Test("The signed descriptor pins the newer Gemma 4 E2B Q4_K_M bytes")
    func pinnedDescriptor() {
        let descriptor = ModelDescriptor.gemma4E2BQ4KM
        #expect(descriptor.repository == "mradermacher/gemma-4-E2B-GGUF")
        #expect(descriptor.revision == "3762686d74ff8db6c98f8d3c389f56fbdf994d5a")
        #expect(descriptor.fileName == "gemma-4-E2B.Q4_K_M.gguf")
        #expect(descriptor.expectedBytes == 3_427_861_984)
        #expect(descriptor.sha256 == "389c868898bffed97fd178646f88562cafecc6f60983a636bac53b131fd068a2")
        #expect(descriptor.downloadURL.absoluteString == "https://huggingface.co/mradermacher/gemma-4-E2B-GGUF/resolve/3762686d74ff8db6c98f8d3c389f56fbdf994d5a/gemma-4-E2B.Q4_K_M.gguf")
    }

    @Test("The signed descriptor pins the official Qwen 3.5 9B Q4_K_M bytes")
    func pinnedQwenDescriptor() {
        let descriptor = ModelDescriptor.qwen35B9BQ4KM
        #expect(descriptor.identifier == "qwen3.5-9b-base-q4km")
        #expect(descriptor.repository == "mradermacher/Qwen3.5-9B-Base-GGUF")
        #expect(descriptor.revision == "ec5c6b42ca313fc71afe4a40b068d3f7026bf4f6")
        #expect(descriptor.fileName == "Qwen3.5-9B-Base.Q4_K_M.gguf")
        #expect(descriptor.expectedBytes == 5_629_109_312)
        #expect(descriptor.sha256 == "4171d5fec62a373744ca4f01ec9e2378c092a65f480c039e9c679d910351fda2")
        #expect(descriptor.downloadURL.absoluteString == "https://huggingface.co/mradermacher/Qwen3.5-9B-Base-GGUF/resolve/ec5c6b42ca313fc71afe4a40b068d3f7026bf4f6/Qwen3.5-9B-Base.Q4_K_M.gguf")
    }

    @Test("Download redirects stay inside the fixed HTTPS model host and CDN")
    func downloadHostPolicy() throws {
        #expect(ModelDownloadNetworkPolicy.allows(try #require(URL(string: "https://huggingface.co/model"))))
        #expect(ModelDownloadNetworkPolicy.allows(try #require(URL(string: "https://us.aws.cdn.hf.co/model"))))
        #expect(!ModelDownloadNetworkPolicy.allows(try #require(URL(string: "http://huggingface.co/model"))))
        #expect(!ModelDownloadNetworkPolicy.allows(try #require(URL(string: "https://example.com/model"))))
        #expect(!ModelDownloadNetworkPolicy.allows(try #require(URL(string: "https://huggingface.co.evil.test/model"))))
    }

    @Test("A streamed model is verified and atomically promoted")
    func downloadsAndPromotesVerifiedModel() async {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let transport = StubTransport([
            response(headers: ["Content-Length": String(fixture.data.count)], chunks: [
                fixture.data.prefix(4), fixture.data.dropFirst(4)
            ].map { Data($0) })
        ])
        let manager = manager(fixture: fixture, transport: transport)

        #expect(manager.start())
        await manager.waitUntilSettled()

        #expect(manager.state == ModelState.ready(manager.modelURL))
        #expect(FileManager.default.fileExists(atPath: manager.modelURL.path))
        #expect(!FileManager.default.fileExists(atPath: manager.partialURL.path))
        let installedData = try? Data(contentsOf: manager.modelURL)
        #expect(installedData == Optional(fixture.data))
        #expect(await transport.requests.first?.value(forHTTPHeaderField: "Range") == nil)
        let fileMode = try? FileManager.default.attributesOfItem(atPath: manager.modelURL.path)[.posixPermissions] as? NSNumber
        #expect(fileMode?.intValue == 0o600)
    }

    @Test("A wrong hash is never promoted")
    func checksumMismatchFailsClosed() async {
        let fixture = Fixture(expectedHash: String(repeating: "0", count: 64))
        defer { fixture.cleanup() }
        let transport = StubTransport([
            response(headers: ["Content-Length": String(fixture.data.count)], chunks: [fixture.data])
        ])
        let manager = manager(fixture: fixture, transport: transport)

        _ = manager.start()
        await manager.waitUntilSettled()

        #expect(manager.state == ModelState.failed(.checksumMismatch))
        #expect(!FileManager.default.fileExists(atPath: manager.modelURL.path))
        #expect(!FileManager.default.fileExists(atPath: manager.partialURL.path))
    }

    @Test("A non-GGUF response is rejected as an invalid model")
    func invalidGGUFFailsClosed() async {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let invalidData = Data([0, 1, 2, 3]) + fixture.data.dropFirst(4)
        let invalidDescriptor = ModelDescriptor(
            identifier: fixture.descriptor.identifier,
            version: fixture.descriptor.version,
            repository: fixture.descriptor.repository,
            revision: fixture.descriptor.revision,
            fileName: fixture.descriptor.fileName,
            expectedBytes: Int64(invalidData.count),
            sha256: SHA256.hash(data: invalidData).map { String(format: "%02x", $0) }.joined()
        )
        let transport = StubTransport([
            response(headers: ["Content-Length": String(invalidData.count)], chunks: [invalidData])
        ])
        let manager = ModelManager(
            descriptor: invalidDescriptor,
            rootDirectory: fixture.root,
            transport: transport,
            callbackQueue: .global(qos: .utility),
            availableDiskSpace: { _ in Int64.max }
        )

        _ = manager.start()
        await manager.waitUntilSettled()

        #expect(manager.state == ModelState.failed(.invalidModel))
        #expect(!FileManager.default.fileExists(atPath: manager.modelURL.path))
    }

    @Test("An interrupted partial resumes only after a matching 206 Content-Range")
    func resumesMatchingRange() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let prefixCount = 7
        let partialDirectory = fixture.root.appendingPathComponent(fixture.descriptor.identifier, isDirectory: true)
        try FileManager.default.createDirectory(at: partialDirectory, withIntermediateDirectories: true)
        try fixture.data.prefix(prefixCount).write(to: partialDirectory.appendingPathComponent("model.gguf.partial"))
        let suffix = Data(fixture.data.dropFirst(prefixCount))
        let transport = StubTransport([
            response(
                status: 206,
                headers: [
                    "Content-Range": "bytes \(prefixCount)-\(fixture.data.count - 1)/\(fixture.data.count)",
                    "Content-Length": String(suffix.count)
                ],
                chunks: [suffix]
            )
        ])
        let manager = manager(fixture: fixture, transport: transport)

        _ = manager.start()
        await manager.waitUntilSettled()

        #expect(manager.state == ModelState.ready(manager.modelURL))
        #expect(try Data(contentsOf: manager.modelURL) == fixture.data)
        #expect(await transport.requests.first?.value(forHTTPHeaderField: "Range") == "bytes=\(prefixCount)-")
    }

    @Test("A dropped connection resumes automatically from the saved partial")
    func retriesDroppedConnection() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let prefixCount = 7
        let interrupted = AsyncThrowingStream<Data, Error> { continuation in
            continuation.yield(Data(fixture.data.prefix(prefixCount)))
            continuation.finish(throwing: URLError(.networkConnectionLost))
        }
        let suffix = Data(fixture.data.dropFirst(prefixCount))
        let transport = StubTransport([
            ModelDownloadResponse(
                statusCode: 200,
                headers: ["Content-Length": String(fixture.data.count)],
                body: interrupted
            ),
            response(
                status: 206,
                headers: [
                    "Content-Range": "bytes \(prefixCount)-\(fixture.data.count - 1)/\(fixture.data.count)",
                    "Content-Length": String(suffix.count)
                ],
                chunks: [suffix]
            )
        ])
        let manager = manager(fixture: fixture, transport: transport, retryDelays: [.zero])

        _ = manager.start()
        await manager.waitUntilSettled()

        #expect(manager.state == .ready(manager.modelURL))
        #expect(try Data(contentsOf: manager.modelURL) == fixture.data)
        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(requests[1].value(forHTTPHeaderField: "Range") == "bytes=\(prefixCount)-")
    }

    @Test("A 200 response safely restarts a partial instead of appending")
    func restartsOnUnrangedResponse() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let partialDirectory = fixture.root.appendingPathComponent(fixture.descriptor.identifier, isDirectory: true)
        try FileManager.default.createDirectory(at: partialDirectory, withIntermediateDirectories: true)
        try Data(fixture.data.prefix(5)).write(to: partialDirectory.appendingPathComponent("model.gguf.partial"))
        let transport = StubTransport([
            response(headers: ["Content-Length": String(fixture.data.count)], chunks: [fixture.data])
        ])
        let manager = manager(fixture: fixture, transport: transport)

        _ = manager.start()
        await manager.waitUntilSettled()

        #expect(manager.state == ModelState.ready(manager.modelURL))
        #expect(try Data(contentsOf: manager.modelURL) == fixture.data)
    }

    @Test("A complete verified partial promotes without another request")
    func promotesCompletePartial() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let manager = manager(fixture: fixture, transport: StubTransport([]))
        try FileManager.default.createDirectory(at: manager.modelDirectory, withIntermediateDirectories: true)
        try fixture.data.write(to: manager.partialURL)

        _ = manager.start()
        await manager.waitUntilSettled()

        #expect(manager.state == .ready(manager.modelURL))
        #expect(try Data(contentsOf: manager.modelURL) == fixture.data)
    }

    @Test("A complete invalid partial is removed before a clean download")
    func restartsCompleteInvalidPartial() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let replacement = Data([0x47, 0x47, 0x55, 0x46]) + Data(repeating: 9, count: fixture.data.count - 4)
        let transport = StubTransport([
            response(headers: ["Content-Length": String(fixture.data.count)], chunks: [fixture.data])
        ])
        let manager = manager(fixture: fixture, transport: transport)
        try FileManager.default.createDirectory(at: manager.modelDirectory, withIntermediateDirectories: true)
        try replacement.write(to: manager.partialURL)

        _ = manager.start()
        await manager.waitUntilSettled()

        #expect(manager.state == .ready(manager.modelURL))
        #expect(await transport.requests.first?.value(forHTTPHeaderField: "Range") == nil)
    }

    @Test("A partial symlink is rejected without changing its target")
    func rejectsPartialSymlink() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let manager = manager(fixture: fixture, transport: StubTransport([]))
        try FileManager.default.createDirectory(at: manager.modelDirectory, withIntermediateDirectories: true)
        let target = fixture.root.appendingPathComponent("target.txt")
        let original = Data("do not change".utf8)
        try original.write(to: target)
        try FileManager.default.createSymbolicLink(at: manager.partialURL, withDestinationURL: target)

        _ = manager.start()
        await manager.waitUntilSettled()

        #expect(manager.state == .failed(.installationFailed))
        #expect(try Data(contentsOf: target) == original)
    }

    @Test("Runtime handoff rechecks bytes after a ready model is replaced")
    func runtimeHandoffReverifies() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let manager = manager(fixture: fixture, transport: StubTransport([]))
        try FileManager.default.createDirectory(at: manager.modelDirectory, withIntermediateDirectories: true)
        try fixture.data.write(to: manager.modelURL)
        _ = manager.start()
        await manager.waitUntilSettled()
        let verified = manager.verifiedInstalledModelFile()
        #expect(verified?.url == manager.modelURL)

        let replacement = Data([0x47, 0x47, 0x55, 0x46]) + Data(repeating: 7, count: fixture.data.count - 4)
        try replacement.write(to: manager.modelURL)
        try verified?.handle.seek(toOffset: 0)
        #expect(try verified?.handle.readToEnd() == fixture.data)
        try? verified?.handle.close()
        #expect(manager.verifiedInstalledModelFile() == nil)
    }

    @Test("Runtime handoff hashes unchanged bytes once per process")
    func runtimeHandoffCachesFullHash() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let manager = manager(fixture: fixture, transport: StubTransport([]))
        try FileManager.default.createDirectory(at: manager.modelDirectory, withIntermediateDirectories: true)
        try fixture.data.write(to: manager.modelURL)
        _ = manager.start()
        await manager.waitUntilSettled()
        let afterInstall = manager.fullVerificationCount

        let first = manager.verifiedInstalledModelFile()
        #expect(first != nil)
        #expect(manager.fullVerificationCount == afterInstall + 1)
        try? first?.handle.close()

        // A helper restart: same bytes, same inode, no new hash.
        let second = manager.verifiedInstalledModelFile()
        #expect(second != nil)
        #expect(manager.fullVerificationCount == afterInstall + 1)
        try second?.handle.seek(toOffset: 0)
        #expect(try second?.handle.readToEnd() == fixture.data)
        try? second?.handle.close()

        // Rewriting the identical bytes in place moves the modification and
        // change times, which is enough to force the hash again.
        try fixture.data.write(to: manager.modelURL)
        let third = manager.verifiedInstalledModelFile()
        #expect(third != nil)
        #expect(manager.fullVerificationCount == afterInstall + 2)
        try? third?.handle.close()
    }

    @Test("A same-size in-place edit after a cached verification is caught by the hash")
    func runtimeHandoffCacheCannotMaskAnEdit() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let manager = manager(fixture: fixture, transport: StubTransport([]))
        try FileManager.default.createDirectory(at: manager.modelDirectory, withIntermediateDirectories: true)
        try fixture.data.write(to: manager.modelURL)
        _ = manager.start()
        await manager.waitUntilSettled()
        let verified = manager.verifiedInstalledModelFile()
        #expect(verified != nil)
        try? verified?.handle.close()
        let hashesBefore = manager.fullVerificationCount

        let handle = try FileHandle(forWritingTo: manager.modelURL)
        try handle.seek(toOffset: UInt64(fixture.data.count - 1))
        try handle.write(contentsOf: Data([fixture.data.last! &+ 1]))
        try handle.close()

        #expect(manager.verifiedInstalledModelFile() == nil)
        #expect(manager.fullVerificationCount == hashesBefore + 1)
    }

    @Test("A mismatched range response is rejected and the partial remains resumable")
    func rejectsMismatchedRange() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let prefixCount = 4
        let partialDirectory = fixture.root.appendingPathComponent(fixture.descriptor.identifier, isDirectory: true)
        try FileManager.default.createDirectory(at: partialDirectory, withIntermediateDirectories: true)
        let partialURL = partialDirectory.appendingPathComponent("model.gguf.partial")
        try fixture.data.prefix(prefixCount).write(to: partialURL)
        let transport = StubTransport([
            response(
                status: 206,
                headers: ["Content-Range": "bytes 0-\(fixture.data.count - 1)/\(fixture.data.count)"],
                chunks: [fixture.data]
            )
        ])
        let manager = manager(fixture: fixture, transport: transport)

        _ = manager.start()
        await manager.waitUntilSettled()

        #expect(manager.state == ModelState.failed(.serverRejectedRequest))
        #expect(FileManager.default.fileExists(atPath: partialURL.path))
        #expect(try Data(contentsOf: partialURL) == fixture.data.prefix(prefixCount))
    }

    @Test("An already verified model skips the network")
    func existingVerifiedModelSkipsDownload() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let transport = StubTransport([])
        let manager = manager(fixture: fixture, transport: transport)
        try FileManager.default.createDirectory(at: manager.modelDirectory, withIntermediateDirectories: true)
        try fixture.data.write(to: manager.modelURL, options: .atomic)

        _ = manager.start()
        await manager.waitUntilSettled()

        #expect(manager.state == ModelState.ready(manager.modelURL))
        #expect(await transport.requests.isEmpty)
    }

    @Test("Offline and disk-space failures remain actionable")
    func mapsOperationalFailures() async {
        let offlineFixture = Fixture()
        defer { offlineFixture.cleanup() }
        let offlineTransport = ClosureModelDownloadTransport { _ in
            throw URLError(.notConnectedToInternet)
        }
        let offline = manager(fixture: offlineFixture, transport: offlineTransport)
        _ = offline.start()
        await offline.waitUntilSettled()
        #expect(offline.state == .failed(.offline))

        let diskFixture = Fixture()
        defer { diskFixture.cleanup() }
        let disk = manager(
            fixture: diskFixture,
            transport: StubTransport([]),
            availableDiskSpace: { _ in 0 }
        )
        _ = disk.start()
        await disk.waitUntilSettled()
        #expect(disk.state == .failed(.insufficientDiskSpace))
    }

    @Test("Deletion removes the verified model and partial")
    func deletesBothInstallFiles() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let manager = manager(fixture: fixture, transport: StubTransport([]))
        try FileManager.default.createDirectory(at: manager.modelDirectory, withIntermediateDirectories: true)
        try fixture.data.write(to: manager.modelURL)
        try Data([1, 2, 3]).write(to: manager.partialURL)

        await manager.deleteModelAndWait()

        #expect(manager.state == ModelState.missing)
        #expect(!FileManager.default.fileExists(atPath: manager.modelURL.path))
        #expect(!FileManager.default.fileExists(atPath: manager.partialURL.path))
    }
}
