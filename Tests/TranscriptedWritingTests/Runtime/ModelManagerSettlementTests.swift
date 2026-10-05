import CryptoKit
import Foundation
import Testing
@testable import TranscriptedWritingRuntime

@Suite("Model manager settlement generations", .timeLimit(.minutes(1)))
struct ModelManagerSettlementTests {
    /// Deliberately ignores cancellation until released, like an operation
    /// still unwinding on an external callback. No network or large files.
    private actor HeldTransport: ModelDownloadTransport {
        nonisolated let arrivals = AsyncStream<Int>.makeStream()
        private var nextID = 0
        private var pending: [Int: CheckedContinuation<ModelDownloadResponse, Error>] = [:]

        func response(for request: URLRequest) async throws -> ModelDownloadResponse {
            let id = nextID
            nextID += 1
            return try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                arrivals.continuation.yield(id)
            }
        }

        func fail(_ id: Int) {
            pending.removeValue(forKey: id)?.resume(returning: ModelDownloadResponse(statusCode: 503, chunks: []))
        }
    }

    @Test("A cancelled waiter returns while the shared model operation remains active")
    func waiterCancellationDoesNotCancelDownload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("model-settlement-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = HeldTransport()
        let manager = makeManager(root: root, transport: transport)
        var arrivals = transport.arrivals.stream.makeAsyncIterator()
        #expect(manager.start())
        let request = try #require(await arrivals.next())
        let cancelled = Task { await manager.waitUntilSettled() }
        let other = Task { await manager.waitUntilSettled() }
        while manager.settlementWaiterCount != 2 { await Task.yield() }
        cancelled.cancel()
        await cancelled.value
        #expect(manager.settlementWaiterCount == 1)
        #expect(!manager.start())
        await transport.fail(request)
        await other.value
        #expect(manager.state == .failed(.serverRejectedRequest))
    }

    @Test("Manager cancellation releases its waiters before a superseded transport returns")
    func cancellationSettlesOnlyItsGeneration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("model-settlement-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = HeldTransport()
        let manager = makeManager(root: root, transport: transport)
        var arrivals = transport.arrivals.stream.makeAsyncIterator()
        #expect(manager.start())
        let oldRequest = try #require(await arrivals.next())
        let oldWaiter = Task { await manager.waitUntilSettled() }
        while manager.settlementWaiterCount != 1 { await Task.yield() }
        manager.cancel()
        #expect(manager.start())
        let newRequest = try #require(await arrivals.next())
        let currentWaiter = Task { await manager.waitUntilSettled() }
        while manager.settlementWaiterCount != 1 { await Task.yield() }
        await oldWaiter.value
        #expect(manager.settlementWaiterCount == 1)
        await transport.fail(oldRequest)
        await transport.fail(newRequest)
        await currentWaiter.value
        #expect(manager.state == .failed(.serverRejectedRequest))
        await manager.waitUntilSettled()
    }

    @Test("Deletion settles old waiters before draining, and old completion leaves a newer generation pending")
    func deletionDrainCannotSettleSuccessor() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("model-settlement-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = HeldTransport()
        let manager = makeManager(root: root, transport: transport)
        var arrivals = transport.arrivals.stream.makeAsyncIterator()
        #expect(manager.start())
        let oldRequest = try #require(await arrivals.next())
        let oldWaiter = Task { await manager.waitUntilSettled() }
        while manager.settlementWaiterCount != 1 { await Task.yield() }
        let deletion = Task { await manager.deleteModelAndWait() }
        // The old transport deliberately ignores cancellation. This wait
        // must return before releasing it, while deletion still drains it.
        await oldWaiter.value
        #expect(manager.start())
        let newRequest = try #require(await arrivals.next())
        let currentWaiter = Task { await manager.waitUntilSettled() }
        while manager.settlementWaiterCount != 1 { await Task.yield() }
        await transport.fail(oldRequest)
        await deletion.value
        // Deletion awaited A's actual task, so its finish has now happened.
        // B is still held before writing any bytes; A cannot settle it.
        #expect(manager.settlementWaiterCount == 1)
        #expect(!manager.start())
        await transport.fail(newRequest)
        await currentWaiter.value
        #expect(manager.state == .failed(.serverRejectedRequest))
    }

    private func makeManager(root: URL, transport: HeldTransport) -> ModelManager {
        let bytes = Data("GGUFfixture".utf8)
        return ModelManager(
            descriptor: ModelDescriptor(
                identifier: "fixture", version: "fixture", repository: "tests/fixtures",
                revision: "0123456789abcdef0123456789abcdef01234567", fileName: "fixture.gguf",
                expectedBytes: Int64(bytes.count),
                sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            ),
            rootDirectory: root,
            transport: transport,
            availableDiskSpace: { _ in Int64.max },
            retryDelays: []
        )
    }
}
