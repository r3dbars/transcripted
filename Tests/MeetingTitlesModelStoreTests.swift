import CryptoKit
import Foundation

func testMeetingTitlesModelStore() async {
    let good = Data("GGUF".utf8) + Data((0..<4_092).map { UInt8($0 % 251) })
    let goodHash = SHA256.hash(data: good).map { String(format: "%02x", $0) }.joined()
    let asset = MeetingTitlesModelAsset(
        identifier: "test-model", repository: "example/test", revision: "abc123",
        fileName: "test.gguf", expectedBytes: Int64(good.count), sha256: goodHash
    )

    runSuite("The pinned production model is an immutable revision with size and sha256") {
        let production = MeetingTitlesModelAsset.production
        assertEqual(production.expectedBytes, 3_106_738_272)
        assertEqual(production.sha256.count, 64)
        assertEqual(production.revision.count, 40)
        assertEqual(
            production.downloadURL.absoluteString,
            "https://huggingface.co/unsloth/gemma-4-E2B-it-GGUF/resolve/0314792d7f1f7e229411f620751375812bb9faf2/gemma-4-E2B-it-Q4_K_M.gguf"
        )
        assertTrue(MeetingTitlesModelNetworkPolicy.allows(production.downloadURL))
        assertFalse(MeetingTitlesModelNetworkPolicy.allows(URL(string: "http://huggingface.co/x")!))
        assertFalse(MeetingTitlesModelNetworkPolicy.allows(URL(string: "https://example.com/x")!))
    }

    await runSuite("A good download is verified and installed") {
        let root = MeetingTitlesFixtures.temporaryDirectory("titles-model")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingTitlesModelStore(asset: asset, rootDirectory: root, fetcher: ServingFetcher(body: good), retryDelays: [])
        do {
            try await store.download { _, _ in }
        } catch {
            assertTrue(false, "download failed: \(error)")
        }
        assertTrue(store.isInstalled)
        assertFalse(FileManager.default.fileExists(atPath: store.partialURL.path), "the partial is promoted")
        let handle = try? store.openVerifiedModel()
        assertEqual(try? handle?.read(upToCount: 4), Data("GGUF".utf8))
    }

    await runSuite("A download with the wrong bytes fails safely and installs nothing") {
        let root = MeetingTitlesFixtures.temporaryDirectory("titles-model")
        defer { try? FileManager.default.removeItem(at: root) }
        var bad = good
        bad[100] ^= 0xFF
        let store = MeetingTitlesModelStore(asset: asset, rootDirectory: root, fetcher: ServingFetcher(body: bad), retryDelays: [])
        var failure: MeetingTitlesModelFailure?
        do { try await store.download { _, _ in } } catch { failure = error as? MeetingTitlesModelFailure }
        assertEqual(failure, .checksumMismatch)
        assertFalse(store.isInstalled)
        assertFalse(FileManager.default.fileExists(atPath: store.modelURL.path))
        assertFalse(FileManager.default.fileExists(atPath: store.partialURL.path), "bad bytes are deleted")
    }

    await runSuite("A server refusal or a short body fails without installing") {
        let root = MeetingTitlesFixtures.temporaryDirectory("titles-model")
        defer { try? FileManager.default.removeItem(at: root) }
        let refused = MeetingTitlesModelStore(asset: asset, rootDirectory: root, fetcher: ServingFetcher(body: good, status: 403), retryDelays: [])
        var failure: MeetingTitlesModelFailure?
        do { try await refused.download { _, _ in } } catch { failure = error as? MeetingTitlesModelFailure }
        assertEqual(failure, .serverRejectedRequest)
        assertFalse(refused.isInstalled)

        let short = MeetingTitlesModelStore(asset: asset, rootDirectory: root, fetcher: ServingFetcher(body: good.prefix(100)), retryDelays: [])
        failure = nil
        do { try await short.download { _, _ in } } catch { failure = error as? MeetingTitlesModelFailure }
        assertEqual(failure, .offline)
        assertFalse(short.isInstalled)
        assertEqual(short.partialBytes, 100, "a cut-off download keeps its partial to resume")
    }

    await runSuite("An interrupted download resumes with a Range request") {
        let root = MeetingTitlesFixtures.temporaryDirectory("titles-model")
        defer { try? FileManager.default.removeItem(at: root) }
        let fetcher = ServingFetcher(body: good)
        let store = MeetingTitlesModelStore(asset: asset, rootDirectory: root, fetcher: fetcher, retryDelays: [])
        try? FileManager.default.createDirectory(at: store.modelDirectory, withIntermediateDirectories: true)
        try? good.prefix(1_000).write(to: store.partialURL)
        do { try await store.download { _, _ in } } catch { assertTrue(false, "resume failed: \(error)") }
        assertEqual(fetcher.rangeHeaders, ["bytes=1000-"])
        assertTrue(store.isInstalled)
    }

    await runSuite("Not enough disk space stops before downloading") {
        let root = MeetingTitlesFixtures.temporaryDirectory("titles-model")
        defer { try? FileManager.default.removeItem(at: root) }
        let fetcher = ServingFetcher(body: good)
        let store = MeetingTitlesModelStore(
            asset: asset, rootDirectory: root, fetcher: fetcher, availableDiskSpace: { _ in 10 }, retryDelays: []
        )
        var failure: MeetingTitlesModelFailure?
        do { try await store.download { _, _ in } } catch { failure = error as? MeetingTitlesModelFailure }
        assertEqual(failure, .insufficientDiskSpace)
        assertEqual(fetcher.rangeHeaders.count, 0, "no request was made")
    }

    await runSuite("A model file changed on disk fails verification and is removed") {
        let root = MeetingTitlesFixtures.temporaryDirectory("titles-model")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingTitlesModelStore(asset: asset, rootDirectory: root, fetcher: ServingFetcher(body: good), retryDelays: [])
        try? await store.download { _, _ in }
        var tampered = good
        tampered[2_000] ^= 0x01
        try? tampered.write(to: store.modelURL)
        var failure: MeetingTitlesModelFailure?
        do { _ = try store.openVerifiedModel() } catch { failure = error as? MeetingTitlesModelFailure }
        assertEqual(failure, .checksumMismatch)
        assertFalse(store.isInstalled)
    }

    await runSuite("Off then on quickly: the new download waits for the cancelled one, never two writers") {
        let root = MeetingTitlesFixtures.temporaryDirectory("titles-model")
        defer { try? FileManager.default.removeItem(at: root) }
        let fetcher = StallingFetcher(body: good)
        let store = MeetingTitlesModelStore(asset: asset, rootDirectory: root, fetcher: fetcher, retryDelays: [])
        let first = Task { try await store.download { _, _ in } }
        while !fetcher.hasStalled { try? await Task.sleep(for: .milliseconds(2)) }
        first.cancel()
        fetcher.stopStalling()
        do { try await store.download { _, _ in } } catch { assertTrue(false, "second download failed: \(error)") }
        _ = await first.result
        assertEqual(fetcher.maxConcurrentFetches, 1, "one writer on the partial at a time")
        assertTrue(store.isInstalled)
    }

    await runSuite("Remove deletes only this model's files") {
        let root = MeetingTitlesFixtures.temporaryDirectory("titles-model")
        defer { try? FileManager.default.removeItem(at: root) }
        let neighbor = root.appendingPathComponent("keep.txt")
        try? Data("keep".utf8).write(to: neighbor)
        let store = MeetingTitlesModelStore(asset: asset, rootDirectory: root, fetcher: ServingFetcher(body: good), retryDelays: [])
        try? await store.download { _, _ in }
        assertTrue(store.bytesOnDisk > 0)
        try? store.remove()
        assertEqual(store.bytesOnDisk, 0)
        assertTrue(FileManager.default.fileExists(atPath: neighbor.path))
    }
}

/// Serves `body` (or its tail for a Range request) with `status`.
private final class ServingFetcher: MeetingTitlesModelFetching, @unchecked Sendable {
    private let body: Data
    private let status: Int
    private let lock = NSLock()
    private var ranges: [String] = []

    init(body: Data, status: Int = 200) {
        self.body = body
        self.status = status
    }

    var rangeHeaders: [String] { lock.withLock { ranges } }

    func fetch(
        _ request: URLRequest,
        onResponse: @escaping @Sendable (Int, [String: String]) throws -> Void,
        onData: @escaping @Sendable (Data) throws -> Void
    ) async throws {
        let range = request.value(forHTTPHeaderField: "Range")
        lock.withLock { if let range { ranges.append(range) } }
        guard status == 200 else {
            try onResponse(status, [:])
            return
        }
        if let range, let start = Int(range.dropFirst("bytes=".count).dropLast()) {
            try onResponse(206, ["Content-Range": "bytes \(start)-\(body.count - 1)/\(body.count)"])
            try onData(body.subdata(in: start..<body.count))
        } else {
            try onResponse(200, [:])
            var offset = 0
            while offset < body.count {
                let end = min(offset + 1_000, body.count)
                try onData(body.subdata(in: offset..<end))
                offset = end
            }
        }
    }
}

/// The first fetch writes half the body, then waits until it is cancelled.
/// Later fetches serve the rest (Range) or the whole body.
private final class StallingFetcher: MeetingTitlesModelFetching, @unchecked Sendable {
    private let body: Data
    private let lock = NSLock()
    private var active = 0
    private var maxActive = 0
    private var stalled = false
    private var stalling = true

    init(body: Data) { self.body = body }

    var hasStalled: Bool { lock.withLock { stalled } }
    var maxConcurrentFetches: Int { lock.withLock { maxActive } }
    func stopStalling() { lock.withLock { stalling = false } }

    func fetch(
        _ request: URLRequest,
        onResponse: @escaping @Sendable (Int, [String: String]) throws -> Void,
        onData: @escaping @Sendable (Data) throws -> Void
    ) async throws {
        let shouldStall: Bool = lock.withLock {
            active += 1
            maxActive = max(maxActive, active)
            return stalling && !stalled
        }
        defer { lock.withLock { active -= 1 } }
        if shouldStall {
            try onResponse(200, [:])
            try onData(body.prefix(body.count / 2))
            lock.withLock { stalled = true }
            // Like URLSession: keeps going until the task is cancelled.
            while true {
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        if let range = request.value(forHTTPHeaderField: "Range"), let start = Int(range.dropFirst("bytes=".count).dropLast()) {
            try onResponse(206, ["Content-Range": "bytes \(start)-\(body.count - 1)/\(body.count)"])
            try onData(body.subdata(in: start..<body.count))
        } else {
            try onResponse(200, [:])
            try onData(body)
        }
    }
}
