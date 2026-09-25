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

struct URLSessionLlamaCompletionTransport: LlamaCompletionStreamingTransport, @unchecked Sendable {
    private let configuration: URLSessionConfiguration

    init(configuration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration
    }

    func open(request: URLRequest) async throws -> LlamaCompletionHTTPStream {
        let operation = URLSessionStreamOperation()
        operation.start(request: request, configuration: configuration)
        let statusCode = try await operation.waitForResponse()
        return LlamaCompletionHTTPStream(
            statusCode: statusCode,
            lines: operation.lines,
            cancel: { operation.cancel() }
        )
    }
}

private final class URLSessionStreamOperation: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let lines: AsyncThrowingStream<String, Error>

    private let lock = NSLock()
    private let lineContinuation: AsyncThrowingStream<String, Error>.Continuation
    private var responseContinuation: CheckedContinuation<Int, Error>?
    private var receivedStatusCode: Int?
    private var responseError: Error?
    private var buffer = Data()
    private var session: URLSession?
    private var task: URLSessionDataTask?
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

    func start(request: URLRequest, configuration: URLSessionConfiguration) {
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        let task = session.dataTask(with: request)
        lock.lock()
        self.session = session
        self.task = task
        lock.unlock()
        task.resume()
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
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        lock.lock()
        receivedStatusCode = status
        let continuation = responseContinuation
        responseContinuation = nil
        lock.unlock()
        continuation?.resume(returning: status)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
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

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        finish(throwing: error, cancelTask: false)
    }

    private func finish(throwing error: Error?, cancelTask: Bool) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let task = self.task
        let session = self.session
        self.task = nil
        self.session = nil
        let responseContinuation = self.responseContinuation
        self.responseContinuation = nil
        if receivedStatusCode == nil { responseError = error ?? URLError(.badServerResponse) }
        let tail = buffer
        buffer.removeAll(keepingCapacity: false)
        lock.unlock()

        if cancelTask { task?.cancel() }
        session?.invalidateAndCancel()
        if receivedStatusCode == nil {
            responseContinuation?.resume(throwing: error ?? URLError(.badServerResponse))
        }
        if let error {
            // A truncated frame must not mask the transport error.
            lineContinuation.finish(throwing: error)
        } else {
            if !tail.isEmpty { lineContinuation.yield(String(decoding: tail, as: UTF8.self)) }
            lineContinuation.finish()
        }
    }
}
