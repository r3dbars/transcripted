import CryptoKit
import Foundation
import Testing
@testable import TranscriptedWritingRuntime

/// A scripted in-memory server for `URLSessionModelDownloadTransport`. Each
/// test registers its own path, so suites can run in parallel.
private final class StubServer: @unchecked Sendable {
    struct Script {
        var status = 200
        var headers: [String: String] = [:]
        var chunks: [Data] = []
        var error: URLError?
        var redirect: URL?
        var holdOpen = false
    }

    static let shared = StubServer()
    private let lock = NSLock()
    private var scripts: [String: Script] = [:]
    private var requested: [String] = []
    private var stopped: Set<String> = []
    private var stopWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func register(_ script: Script) -> URL {
        let path = "/model-\(UUID().uuidString)"
        lock.lock()
        scripts[path] = script
        lock.unlock()
        return URL(string: "https://huggingface.co\(path)")!
    }

    func script(for url: URL) -> Script? {
        lock.lock()
        defer { lock.unlock() }
        requested.append(url.absoluteString)
        return scripts[url.path]
    }

    func wasRequested(_ url: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return requested.contains(url.absoluteString)
    }

    func noteStopped(_ url: URL) {
        lock.lock()
        stopped.insert(url.absoluteString)
        let waiters = stopWaiters.removeValue(forKey: url.absoluteString) ?? []
        lock.unlock()
        waiters.forEach { $0.resume() }
    }

    func waitUntilStopped(_ url: URL) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if stopped.contains(url.absoluteString) {
                lock.unlock()
                continuation.resume()
                return
            }
            stopWaiters[url.absoluteString, default: []].append(continuation)
            lock.unlock()
        }
    }
}

private final class StubURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let script = StubServer.shared.script(for: url) else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        if let redirect = script.redirect {
            let response = HTTPURLResponse(
                url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                headerFields: ["Location": redirect.absoluteString]
            )!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: redirect), redirectResponse: response)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        // An explicit Content-Type keeps URLSession from holding the response
        // back to sniff the body.
        let headers = script.headers.merging(["Content-Type": "application/octet-stream"]) { mine, _ in mine }
        let response = HTTPURLResponse(url: url, statusCode: script.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in script.chunks { client?.urlProtocol(self, didLoad: chunk) }
        if script.holdOpen { return }
        if let error = script.error {
            client?.urlProtocol(self, didFailWithError: error)
        } else {
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        if let url = request.url { StubServer.shared.noteStopped(url) }
    }
}

@Suite("Model download transport", .timeLimit(.minutes(1)))
struct ModelDownloadTransportTests {
    private func transport(coalesce: Int = 1_000, limit: Int = 3_000) -> URLSessionModelDownloadTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSessionModelDownloadTransport(
            session: URLSession(configuration: configuration),
            coalescedChunkBytes: coalesce,
            bufferedByteLimit: limit
        )
    }

    private func pieces() -> (chunks: [Data], joined: Data) {
        var chunks: [Data] = []
        var joined = Data()
        for index in 0..<200 {
            let count = index % 25 == 0 ? 6_000 : 37
            let chunk = Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &+ index) })
            chunks.append(chunk)
            joined.append(chunk)
        }
        return (chunks, joined)
    }

    @Test("Many small and a few large pieces arrive byte-identical and in order, with status and headers")
    func bodyArrivesInOrder() async throws {
        let (chunks, joined) = pieces()
        let url = StubServer.shared.register(.init(
            headers: ["Content-Length": String(joined.count), "X-Fixture": "yes"],
            chunks: chunks
        ))
        let response = try await transport().response(for: URLRequest(url: url))
        #expect(response.statusCode == 200)
        #expect(response.headers["X-Fixture"] == "yes")
        #expect(response.headers["Content-Length"] == String(joined.count))

        var received = Data()
        for try await chunk in response.body {
            received.append(chunk)
            await Task.yield()
        }
        #expect(received == joined)
    }

    @Test("A server error status is returned as the response, not thrown")
    func serverErrorPassesThrough() async throws {
        let url = StubServer.shared.register(.init(status: 500, chunks: [Data("nope".utf8)]))
        let response = try await transport().response(for: URLRequest(url: url))
        #expect(response.statusCode == 500)
    }

    @Test("Dropping a response unread cancels the transfer, and the transport still serves the next request")
    func droppedResponseReleasesTheSession() async throws {
        let shared = transport(limit: 64)
        let open = StubServer.shared.register(.init(chunks: [Data(count: 512), Data(count: 512)], holdOpen: true))
        do {
            let response = try await shared.response(for: URLRequest(url: open))
            #expect(response.statusCode == 200)
        }
        await StubServer.shared.waitUntilStopped(open)

        let (chunks, joined) = pieces()
        let next = StubServer.shared.register(.init(chunks: chunks))
        let response = try await shared.response(for: URLRequest(url: next))
        var received = Data()
        for try await chunk in response.body { received.append(chunk) }
        #expect(received == joined)
    }

    @Test("A connection lost mid-body is thrown from the body as the same URLError")
    func midBodyErrorSurfaces() async throws {
        let url = StubServer.shared.register(.init(chunks: [Data(count: 10)], error: URLError(.networkConnectionLost)))
        let response = try await transport().response(for: URLRequest(url: url))
        var thrown: URLError?
        do {
            for try await _ in response.body {}
        } catch let error as URLError {
            thrown = error
        }
        #expect(thrown?.code == .networkConnectionLost)
    }

    @Test("A redirect off the model host is never followed")
    func offHostRedirectIsRefused() async throws {
        let evil = URL(string: "https://example.com/model-\(UUID().uuidString)")!
        let url = StubServer.shared.register(.init(redirect: evil))
        if let response = try? await transport().response(for: URLRequest(url: url)) {
            #expect(response.statusCode != 200)
        }
        #expect(!StubServer.shared.wasRequested(evil))
    }

    @Test("A redirect to the model CDN is followed")
    func cdnRedirectIsFollowed() async throws {
        let (chunks, joined) = pieces()
        let target = StubServer.shared.register(.init(chunks: chunks))
        let cdn = URL(string: "https://cdn-lfs.hf.co\(target.path)")!
        let url = StubServer.shared.register(.init(redirect: cdn))
        let response = try await transport().response(for: URLRequest(url: url))
        var received = Data()
        for try await chunk in response.body { received.append(chunk) }
        #expect(response.statusCode == 200)
        #expect(received == joined)
    }

    @Test("A model downloads through the URLSession transport and is verified and promoted")
    func managerDownloadsThroughTransport() async throws {
        let data = Data([0x47, 0x47, 0x55, 0x46]) + Data((0..<50_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
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
        // The manager always asks for the descriptor's URL; route it to a
        // registered script with a closure transport that rewrites the path.
        let script = StubServer.shared.register(.init(
            headers: ["Content-Length": String(data.count)],
            chunks: stride(from: 0, to: data.count, by: 4_096).map { data[$0..<min($0 + 4_096, data.count)] }
        ))
        let inner = transport(coalesce: 8_192, limit: 16_384)
        let rewriting = ClosureModelDownloadTransport { request in
            var routed = request
            routed.url = script
            return try await inner.response(for: routed)
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tilde-transport-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ModelManager(
            descriptor: descriptor,
            rootDirectory: root,
            transport: rewriting,
            callbackQueue: .global(qos: .utility),
            availableDiskSpace: { _ in Int64.max },
            retryDelays: []
        )
        _ = manager.start()
        await manager.waitUntilSettled()

        #expect(manager.state == .ready(manager.modelURL))
        #expect(try Data(contentsOf: manager.modelURL) == data)
    }
}

@Suite("Model download body channel", .timeLimit(.minutes(1)))
struct ModelDownloadBodyChannelTests {
    @Test("A fast producer never buffers more than the limit plus one chunk, and nothing is dropped")
    func producerIsBounded() async throws {
        let chunk = 64 * 1024
        let channel = ModelDownloadBodyChannel(byteLimit: 4 * chunk, coalescedChunkBytes: chunk)
        let producer = Thread {
            for index in 0..<64 {
                guard channel.send(Data(repeating: UInt8(index), count: chunk)) else { return }
            }
            channel.finish(.success(()))
        }
        producer.start()

        var received = 0
        var expectedIndex = 0
        while let data = try await channel.next() {
            #expect(channel.bufferedBytes <= 4 * chunk + chunk)
            #expect(data.count == chunk)
            #expect(data.first == UInt8(expectedIndex))
            expectedIndex += 1
            received += data.count
        }
        #expect(received == 64 * chunk)
    }

    @Test("Terminating the channel releases a producer blocked on a full buffer")
    func terminateReleasesBlockedProducer() async throws {
        let channel = ModelDownloadBodyChannel(byteLimit: 10, coalescedChunkBytes: 10)
        let accepted: Bool = await withCheckedContinuation { continuation in
            Thread {
                _ = channel.send(Data(count: 10))
                // The buffer is full: this send waits until terminate().
                continuation.resume(returning: channel.send(Data(count: 10)))
            }.start()
            Thread {
                while channel.bufferedBytes < 10 { sched_yield() }
                channel.terminate()
            }.start()
        }
        #expect(!accepted)
        await #expect(throws: CancellationError.self) {
            _ = try await channel.next()
        }
    }

    @Test("A transfer error reaches the consumer after the chunks queued before it")
    func errorAfterQueuedChunks() async throws {
        let channel = ModelDownloadBodyChannel(byteLimit: 1_000, coalescedChunkBytes: 1)
        channel.send(Data([1]))
        channel.send(Data([2]))
        channel.finish(.failure(URLError(.networkConnectionLost)))
        #expect(try await channel.next() == Data([1]))
        #expect(try await channel.next() == Data([2]))
        await #expect(throws: URLError.self) {
            _ = try await channel.next()
        }
    }
}
