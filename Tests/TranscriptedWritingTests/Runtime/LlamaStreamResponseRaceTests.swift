import Foundation
import Testing
@testable import TranscriptedWritingRuntime

/// Whoever waits for the helper's response headers always wakes up, however a
/// cancel and the response callback interleave. A waiter that never wakes
/// hangs the suggestion and leaks the socket and task behind it.
@Suite("Llama stream response wait survives a cancel/response race")
struct LlamaStreamResponseRaceTests {
    @Test("A response that lands while a cancel is finishing still wakes the waiter")
    func responseDuringCancelStillWakesWaiter() async throws {
        let operation = URLSessionStreamOperation()
        let network = RecordingNetwork()
        // The response callback lands exactly when cancel has dropped its lock
        // and is tearing down the request: the old window for a lost resume.
        network.onCancelTask = { operation.receive(statusCode: 200) }
        operation.start(network: network.handle)

        let waiter = Task { try await operation.waitForResponse() }
        while !operation.isWaitingForResponse { await Task.yield() }

        operation.cancel()

        let outcome = await Self.outcome(of: waiter)
        #expect(outcome == .threw(cancellation: true))
        #expect(network.cancelCount == 1)
        #expect(network.invalidateCount == 1)
    }

    @Test("A response that arrives before the cancel returns its status")
    func responseBeforeCancelReturnsStatus() async throws {
        let operation = URLSessionStreamOperation()
        let network = RecordingNetwork()
        operation.start(network: network.handle)

        let waiter = Task { try await operation.waitForResponse() }
        while !operation.isWaitingForResponse { await Task.yield() }

        #expect(operation.receive(statusCode: 503))
        operation.cancel()

        #expect(await Self.outcome(of: waiter) == .returned(503))
    }

    @Test("A transport failure before any response wakes the waiter with that failure")
    func failureBeforeResponseWakesWaiter() async throws {
        let operation = URLSessionStreamOperation()
        let network = RecordingNetwork()
        operation.start(network: network.handle)

        let waiter = Task { try await operation.waitForResponse() }
        while !operation.isWaitingForResponse { await Task.yield() }

        operation.complete(error: URLError(.networkConnectionLost))

        #expect(await Self.outcome(of: waiter) == .threw(cancellation: false))
        #expect(network.cancelCount == 0)
        #expect(network.invalidateCount == 1)
    }

    @Test("A response after the operation finished is refused")
    func lateResponseIsRefused() async throws {
        let operation = URLSessionStreamOperation()
        operation.start(network: RecordingNetwork().handle)
        operation.cancel()

        #expect(operation.receive(statusCode: 200) == false)
        await #expect(throws: CancellationError.self) { try await operation.waitForResponse() }
    }

    enum Outcome: Equatable {
        case returned(Int)
        case threw(cancellation: Bool)
        /// The waiter never woke. Reported instead of awaited, so a
        /// regression fails this test rather than stalling the whole run.
        case hung
    }

    /// The waiter's result, or `.hung` if it hasn't woken after a margin far
    /// beyond anything a correct run needs (it wakes synchronously).
    private static func outcome(of waiter: Task<Int, Error>) async -> Outcome {
        await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
            let once = ResumeOnce(continuation)
            Task {
                do {
                    once.resume(.returned(try await waiter.value))
                } catch {
                    once.resume(.threw(cancellation: error is CancellationError))
                }
            }
            Task {
                try? await Task.sleep(for: .seconds(30))
                once.resume(.hung)
            }
        }
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<LlamaStreamResponseRaceTests.Outcome, Never>?

    init(_ continuation: CheckedContinuation<LlamaStreamResponseRaceTests.Outcome, Never>) {
        self.continuation = continuation
    }

    func resume(_ outcome: LlamaStreamResponseRaceTests.Outcome) {
        let taken: CheckedContinuation<LlamaStreamResponseRaceTests.Outcome, Never>? = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        taken?.resume(returning: outcome)
    }
}

private final class RecordingNetwork: @unchecked Sendable {
    private let lock = NSLock()
    private var cancels = 0
    private var invalidates = 0
    var onCancelTask: (@Sendable () -> Void)?

    var cancelCount: Int { lock.withLock { cancels } }
    var invalidateCount: Int { lock.withLock { invalidates } }

    var handle: LlamaStreamNetwork {
        LlamaStreamNetwork(
            resume: {},
            cancelTask: { [self] in
                lock.withLock { cancels += 1 }
                onCancelTask?()
            },
            invalidate: { [self] in lock.withLock { invalidates += 1 } }
        )
    }
}
