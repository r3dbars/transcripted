// ModelDownloadTransport.swift
// The production HTTP transport for the Writing model download: URLSession
// delegate callbacks feed a bounded channel the manager reads in bulk.

import Foundation

/// Session-level redirect guard: a redirect may only stay on the fixed HTTPS
/// model host and its CDN.
private final class ModelDownloadRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(request.url.map(ModelDownloadNetworkPolicy.allows) == true ? request : nil)
    }
}

/// The production HTTP transport. Each request runs as a data task with its
/// own delegate; the bytes URLSession hands over land in a bounded
/// `ModelDownloadBodyChannel` and reach the manager as the chunks they
/// arrived in (coalesced up to `coalescedChunkBytes` while the manager is
/// behind). When `bufferedByteLimit` is reached the session's serial delegate
/// queue waits for the manager, so no completed model-sized `Data` is ever
/// held and no chunk is dropped.
struct URLSessionModelDownloadTransport: ModelDownloadTransport, Sendable {
    private let session: URLSession
    private let coalescedChunkBytes: Int
    private let bufferedByteLimit: Int

    init(
        session: URLSession? = nil,
        coalescedChunkBytes: Int = 1 << 20,
        bufferedByteLimit: Int = 4 << 20
    ) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.urlCache = nil
            configuration.httpShouldSetCookies = false
            configuration.httpCookieStorage = nil
            let delegateQueue = OperationQueue()
            delegateQueue.maxConcurrentOperationCount = 1
            delegateQueue.name = "com.justinbetker.transcripted.model-download"
            self.session = URLSession(
                configuration: configuration,
                delegate: ModelDownloadRedirectDelegate(),
                delegateQueue: delegateQueue
            )
        }
        self.coalescedChunkBytes = max(1, coalescedChunkBytes)
        self.bufferedByteLimit = max(1, bufferedByteLimit)
    }

    func response(for request: URLRequest) async throws -> ModelDownloadResponse {
        let channel = ModelDownloadBodyChannel(
            byteLimit: bufferedByteLimit,
            coalescedChunkBytes: coalescedChunkBytes
        )
        let delegate = ModelDownloadTaskDelegate(channel: channel)
        let task = session.dataTask(with: request)
        task.delegate = delegate
        // Whatever ends the body early (the manager stops reading, drops the
        // response after validating it, or is cancelled) releases the stream
        // and with it this guard, which wakes a waiting delegate callback and
        // cancels the task. Otherwise the session's serial delegate queue
        // would stay blocked and the next request on this transport would hang.
        let guardian = ModelDownloadTaskGuard(task: task, channel: channel)

        let http: HTTPURLResponse = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.awaitResponse(continuation)
                task.resume()
            }
        } onCancel: {
            guardian.stop()
        }

        let body = AsyncThrowingStream<Data, Error> {
            try await guardian.next()
        }

        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String {
                headers[key] = value
            }
        }
        return ModelDownloadResponse(statusCode: http.statusCode, headers: headers, body: body)
    }

    enum TransportError: Error {
        case notHTTPResponse
    }
}

/// Ties a data task's life to its body stream. Released with the stream.
private final class ModelDownloadTaskGuard: @unchecked Sendable {
    private let task: URLSessionDataTask
    private let channel: ModelDownloadBodyChannel

    init(task: URLSessionDataTask, channel: ModelDownloadBodyChannel) {
        self.task = task
        self.channel = channel
    }

    func next() async throws -> Data? {
        try await withTaskCancellationHandler {
            try await channel.next()
        } onCancel: {
            stop()
        }
    }

    func stop() {
        channel.terminate()
        task.cancel()
    }

    deinit { stop() }
}

/// Per-task delegate: the response head resolves `response(for:)`, body bytes
/// go into the channel, completion finishes it. Redirects get the same host
/// check as the session delegate, so an injected session keeps the policy.
private final class ModelDownloadTaskDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let channel: ModelDownloadBodyChannel
    private let lock = NSLock()
    private var continuation: CheckedContinuation<HTTPURLResponse, Error>?
    private var outcome: Result<HTTPURLResponse, Error>?

    init(channel: ModelDownloadBodyChannel) {
        self.channel = channel
    }

    func awaitResponse(_ continuation: CheckedContinuation<HTTPURLResponse, Error>) {
        lock.lock()
        if let outcome {
            lock.unlock()
            continuation.resume(with: outcome)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    private func resolve(_ result: Result<HTTPURLResponse, Error>) {
        lock.lock()
        guard outcome == nil else { lock.unlock(); return }
        outcome = result
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(with: result)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            resolve(.failure(URLSessionModelDownloadTransport.TransportError.notHTTPResponse))
            completionHandler(.cancel)
            return
        }
        resolve(.success(http))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if !channel.send(data) { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            resolve(.failure(error))
            channel.finish(.failure(error))
        } else {
            resolve(.failure(URLSessionModelDownloadTransport.TransportError.notHTTPResponse))
            channel.finish(.success(()))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(request.url.map(ModelDownloadNetworkPolicy.allows) == true ? request : nil)
    }
}

/// A bounded single-producer, single-consumer byte channel.
///
/// The producer is a URLSession delegate callback on its own serial queue, so
/// `send` may block that thread until the consumer frees room; it never drops
/// a chunk. The consumer awaits `next()` without blocking a Swift
/// concurrency thread. `terminate()` wakes both sides for good.
final class ModelDownloadBodyChannel: @unchecked Sendable {
    let byteLimit: Int
    let coalescedChunkBytes: Int
    private let condition = NSCondition()
    private var chunks: [Data] = []
    private var buffered = 0
    private var completion: Result<Void, Error>?
    private var terminated = false
    private var waiter: CheckedContinuation<Data?, Error>?

    init(byteLimit: Int, coalescedChunkBytes: Int) {
        self.byteLimit = max(1, byteLimit)
        self.coalescedChunkBytes = max(1, coalescedChunkBytes)
    }

    /// Bytes queued and not yet taken by the consumer.
    var bufferedBytes: Int {
        condition.lock()
        defer { condition.unlock() }
        return buffered
    }

    /// Queues `data`, waiting while the buffer is full. Returns false once
    /// the channel was terminated or finished; the caller should stop.
    @discardableResult
    func send(_ data: Data) -> Bool {
        guard !data.isEmpty else { return true }
        condition.lock()
        while !terminated, completion == nil, buffered >= byteLimit {
            condition.wait()
        }
        guard !terminated, completion == nil else {
            condition.unlock()
            return false
        }
        if let waiting = waiter {
            waiter = nil
            condition.unlock()
            waiting.resume(returning: data)
            return true
        }
        if let last = chunks.indices.last, chunks[last].count + data.count <= coalescedChunkBytes {
            chunks[last].append(data)
        } else {
            chunks.append(data)
        }
        buffered += data.count
        condition.unlock()
        return true
    }

    /// Ends the body after the queued chunks: `.success` ends it cleanly, a
    /// failure is thrown to the consumer once the queued chunks are taken.
    func finish(_ result: Result<Void, Error>) {
        condition.lock()
        guard !terminated, completion == nil else {
            condition.unlock()
            return
        }
        completion = result
        let waiting = waiter
        waiter = nil
        condition.broadcast()
        condition.unlock()
        waiting?.resume(with: result.map { nil })
    }

    /// The consumer is gone or cancelled: drop what's queued, release a waiting
    /// producer, and end a waiting consumer with `CancellationError`.
    func terminate() {
        condition.lock()
        terminated = true
        chunks.removeAll()
        buffered = 0
        let waiting = waiter
        waiter = nil
        condition.broadcast()
        condition.unlock()
        waiting?.resume(throwing: CancellationError())
    }

    /// The next chunk in arrival order, nil at the end, the transfer error, or
    /// `CancellationError` once terminated.
    func next() async throws -> Data? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
            condition.lock()
            if !chunks.isEmpty {
                let chunk = chunks.removeFirst()
                buffered -= chunk.count
                condition.broadcast()
                condition.unlock()
                continuation.resume(returning: chunk)
                return
            }
            if terminated {
                condition.unlock()
                continuation.resume(throwing: CancellationError())
                return
            }
            if let completion {
                condition.unlock()
                continuation.resume(with: completion.map { nil })
                return
            }
            waiter = continuation
            condition.unlock()
        }
    }
}
