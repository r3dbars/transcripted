import Foundation

/// The small seam between the completion engine and URLSession. Keeping an
/// explicit data task here makes cancellation observable and ensures a stale
/// suggestion stops helper inference instead of only abandoning a Swift loop.
struct LlamaCompletionHTTPStream: @unchecked Sendable {
    let statusCode: Int
    let lines: AsyncThrowingStream<String, Error>
    let cancel: @Sendable () -> Void
}

protocol LlamaCompletionStreamingTransport: Sendable {
    func open(request: URLRequest) async throws -> LlamaCompletionHTTPStream
}

typealias LlamaStreamNetworkFactory = @Sendable (URLRequest, URLSessionConfiguration, URLSessionStreamOperation) -> LlamaStreamNetwork

struct URLSessionLlamaCompletionTransport: LlamaCompletionStreamingTransport, @unchecked Sendable {
    // Private owned template: configured once, never mutated or handed out.
    private let configuration: URLSessionConfiguration
    private let makeNetwork: LlamaStreamNetworkFactory

    init(
        configuration: URLSessionConfiguration = .ephemeral,
        makeNetwork: @escaping LlamaStreamNetworkFactory = { request, configuration, operation in
            URLSessionStreamOperation.makeNetwork(request: request, configuration: configuration, operation: operation)
        }
    ) {
        let owned = configuration.copy() as! URLSessionConfiguration
        owned.requestCachePolicy = .reloadIgnoringLocalCacheData
        owned.urlCache = nil
        owned.httpCookieStorage = nil
        owned.httpShouldSetCookies = false
        owned.urlCredentialStorage = nil
        owned.connectionProxyDictionary = [:]
        self.configuration = owned
        self.makeNetwork = makeNetwork
    }

    func open(request: URLRequest) async throws -> LlamaCompletionHTTPStream {
        let operation = URLSessionStreamOperation()
        // Even an injected factory may retain/mutate only its operation's copy.
        let operationConfiguration = configuration.copy() as! URLSessionConfiguration
        operation.start(network: makeNetwork(request, operationConfiguration, operation))
        let statusCode = try await operation.waitForResponse()
        return LlamaCompletionHTTPStream(
            statusCode: statusCode,
            lines: operation.lines,
            cancel: { operation.cancel() }
        )
    }
}

/// The network side of one streamed request, kept behind closures so tests
/// can drive the operation's delegate callbacks in any order without a socket.
struct LlamaStreamNetwork: @unchecked Sendable {
    /// Starts the request.
    let resume: @Sendable () -> Void
    /// Cancels the in-flight request.
    let cancelTask: @Sendable () -> Void
    /// Releases the session so its delegate reference and socket go away.
    let invalidate: @Sendable () -> Void
}

final class URLSessionStreamOperation: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let lines: AsyncThrowingStream<String, Error>

    private let lock = NSLock()
    private let lineContinuation: AsyncThrowingStream<String, Error>.Continuation
    private var responseContinuation: CheckedContinuation<Int, Error>?
    private var receivedStatusCode: Int?
    private var responseError: Error?
    private var buffer = Data()
    private var network: LlamaStreamNetwork?
    private var finished = false

    override init() {
        var captured: AsyncThrowingStream<String, Error>.Continuation!
        lines = AsyncThrowingStream<String, Error> { captured = $0 }
        lineContinuation = captured
        super.init()
        lineContinuation.onTermination = { @Sendable [weak self] termination in
            if case .cancelled = termination { self?.cancel() }
        }
    }

    static func makeNetwork(
        request: URLRequest,
        configuration: URLSessionConfiguration,
        operation: URLSessionStreamOperation
    ) -> LlamaStreamNetwork {
        // Each operation owns its delegate/session and invalidates only itself.
        let session = URLSession(configuration: configuration, delegate: operation, delegateQueue: nil)
        let task = session.dataTask(with: request)
        return LlamaStreamNetwork(
            resume: { task.resume() },
            cancelTask: { task.cancel() },
            invalidate: { session.invalidateAndCancel() }
        )
    }

    func start(network: LlamaStreamNetwork) {
        lock.lock()
        let alreadyFinished = finished
        if !alreadyFinished { self.network = network }
        lock.unlock()
        if alreadyFinished {
            network.invalidate()
            return
        }
        network.resume()
    }

    /// True while a caller is parked in `waitForResponse()`.
    var isWaitingForResponse: Bool {
        lock.lock()
        defer { lock.unlock() }
        return responseContinuation != nil
    }

    func waitForResponse() async throws -> Int {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let status = receivedStatusCode {
                    lock.unlock()
                    continuation.resume(returning: status)
                } else if let error = responseError {
                    lock.unlock()
                    continuation.resume(throwing: error)
                } else {
                    responseContinuation = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            cancel()
        }
    }

    func cancel() {
        finish(throwing: CancellationError(), cancelTask: true)
    }

    // MARK: - Delegate callbacks, forwarded to plain methods tests can call

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        let accepted = receive(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        completionHandler(accepted ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        receive(data: data)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        complete(error: error)
    }

    /// Records the response status and wakes the waiter. Returns false when the
    /// operation already finished, so a late response can't resurrect it.
    @discardableResult
    func receive(statusCode status: Int) -> Bool {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return false
        }
        receivedStatusCode = status
        let continuation = responseContinuation
        responseContinuation = nil
        lock.unlock()
        continuation?.resume(returning: status)
        return true
    }

    func receive(data: Data) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        buffer.append(data)
        var ready: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.prefix(upTo: newline)
            buffer.removeSubrange(...newline)
            ready.append(String(decoding: line, as: UTF8.self))
        }
        lock.unlock()
        for line in ready { lineContinuation.yield(line) }
    }

    func complete(error: Error?) {
        finish(throwing: error, cancelTask: false)
    }

    private func finish(throwing error: Error?, cancelTask: Bool) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let network = self.network
        self.network = nil
        // Decide the waiter's outcome while still holding the lock. A response
        // callback can land the moment the lock drops; re-reading the status
        // after that would skip the resume and leave the waiter parked forever.
        let responseContinuation = self.responseContinuation
        self.responseContinuation = nil
        let responseOutcome: Result<Int, Error>
        if let status = receivedStatusCode {
            responseOutcome = .success(status)
        } else {
            let failure = error ?? URLError(.badServerResponse)
            responseError = failure
            responseOutcome = .failure(failure)
        }
        let tail = buffer
        buffer.removeAll(keepingCapacity: false)
        lock.unlock()

        if cancelTask { network?.cancelTask() }
        network?.invalidate()
        responseContinuation?.resume(with: responseOutcome)
        if let error {
            // A truncated frame must not mask the transport error.
            lineContinuation.finish(throwing: error)
        } else {
            if !tail.isEmpty { lineContinuation.yield(String(decoding: tail, as: UTF8.self)) }
            lineContinuation.finish()
        }
    }
}
