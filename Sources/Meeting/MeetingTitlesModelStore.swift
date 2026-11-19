import CryptoKit
import Foundation

/// The one pinned model for meeting titles: Gemma 4 E2B instruct, Q4_K_M.
/// Separate from Writing's model (Writing ships base builds, which can't do
/// this job). Pinned to an immutable revision, an exact size and a sha256,
/// the same way Writing pins its model; the bytes are the trust boundary.
struct MeetingTitlesModelAsset: Equatable, Sendable {
    let identifier: String
    let repository: String
    let revision: String
    let fileName: String
    let expectedBytes: Int64
    let sha256: String

    var downloadURL: URL {
        URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(fileName)")!
    }

    static let production = MeetingTitlesModelAsset(
        identifier: "gemma-4-e2b-it-q4km",
        repository: "unsloth/gemma-4-E2B-it-GGUF",
        revision: "0314792d7f1f7e229411f620751375812bb9faf2",
        fileName: "gemma-4-E2B-it-Q4_K_M.gguf",
        expectedBytes: 3_106_738_272,
        sha256: "740185b21d22ceb83a11c3aa62ad5842ef32c70f6096d756bbee85a1e4ec34b8"
    )
}

/// Failures carry no paths, server text or user data.
enum MeetingTitlesModelFailure: Error, Equatable, Sendable {
    case offline
    case insufficientDiskSpace
    case serverRejectedRequest
    case checksumMismatch
    case invalidModel
    case installationFailed
}

enum MeetingTitlesModelNetworkPolicy {
    /// Downloads and redirects may only reach the model host and its CDN.
    static func allows(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return host == "huggingface.co" || host.hasSuffix(".hf.co")
    }
}

/// One HTTP GET whose body streams into `onData` in arrival order.
/// `onResponse` sees the status and headers first and may throw to stop.
protocol MeetingTitlesModelFetching: Sendable {
    func fetch(
        _ request: URLRequest,
        onResponse: @escaping @Sendable (_ statusCode: Int, _ headers: [String: String]) throws -> Void,
        onData: @escaping @Sendable (Data) throws -> Void
    ) async throws
}

/// Owns the downloaded model under Application Support:
/// `models/meeting-titles/<identifier>/model.gguf`, owner-only and excluded
/// from backup. A download lands in `model.gguf.partial` (resumable) and is
/// promoted only after its size, GGUF magic and sha256 check out.
final class MeetingTitlesModelStore: @unchecked Sendable {
    let asset: MeetingTitlesModelAsset
    let modelDirectory: URL
    var modelURL: URL { modelDirectory.appendingPathComponent("model.gguf", isDirectory: false) }
    var partialURL: URL { modelDirectory.appendingPathComponent("model.gguf.partial", isDirectory: false) }

    private let fetcher: any MeetingTitlesModelFetching
    private let availableDiskSpace: @Sendable (URL) -> Int64?
    private let retryDelays: [Duration]
    private let lock = NSLock()
    /// The file identity last fully hashed in this process. A matching
    /// identity skips the multi-second rehash before each helper launch.
    private var verifiedFingerprint: FileFingerprint?

    /// `models/meeting-titles` under Application Support; the model-cache
    /// inventory measures and removes the same folder.
    static var defaultRootDirectory: URL {
        ModelCacheInventory.defaultMeetingTitlesModelsDirectory()
    }

    init(
        asset: MeetingTitlesModelAsset = .production,
        rootDirectory: URL = MeetingTitlesModelStore.defaultRootDirectory,
        fetcher: any MeetingTitlesModelFetching = URLSessionMeetingTitlesModelFetcher(),
        availableDiskSpace: @escaping @Sendable (URL) -> Int64? = MeetingTitlesModelStore.defaultDiskSpace,
        retryDelays: [Duration] = [.seconds(2), .seconds(8), .seconds(30)]
    ) {
        self.asset = asset
        self.modelDirectory = rootDirectory.appendingPathComponent(asset.identifier, isDirectory: true)
        self.fetcher = fetcher
        self.availableDiskSpace = availableDiskSpace
        self.retryDelays = retryDelays
    }

    /// Cheap check: a regular file of exactly the pinned size. The hash runs
    /// before the helper ever reads it (`openVerifiedModel`).
    var isInstalled: Bool {
        fileSize(at: modelURL) == asset.expectedBytes
    }

    var partialBytes: Int64 { fileSize(at: partialURL) ?? 0 }

    /// Bytes on disk for this feature (model plus any partial), for the
    /// model-cache inventory.
    var bytesOnDisk: Int64 { (fileSize(at: modelURL) ?? 0) + (fileSize(at: partialURL) ?? 0) }

    /// Downloads (resuming a partial), verifies and installs the model.
    /// Cancelling the task stops it and keeps the partial for next time.
    /// Calls run one at a time: a download started right after a cancelled
    /// one waits until that one has let go of the partial file.
    func download(progress: @escaping @Sendable (_ received: Int64, _ total: Int64) -> Void) async throws {
        try await downloadGate.serialize { [self] in
            try await downloadOnce(progress: progress)
        }
    }

    private let downloadGate = DownloadGate()

    private actor DownloadGate {
        private var tail: Task<Void, Never>?

        func serialize(_ operation: @escaping @Sendable () async throws -> Void) async throws {
            let previous = tail
            let task = Task {
                await previous?.value
                try Task.checkCancellation()
                try await operation()
            }
            tail = Task { _ = try? await task.value }
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        }
    }

    private func downloadOnce(progress: @escaping @Sendable (_ received: Int64, _ total: Int64) -> Void) async throws {
        if isInstalled { return }
        try ensureDirectory()
        var attempt = 0
        while true {
            do {
                try await downloadRemaining(progress: progress)
                break
            } catch let failure as MeetingTitlesModelFailure where failure == .offline && attempt < retryDelays.count {
                try await Task.sleep(for: retryDelays[attempt])
                attempt += 1
            }
        }
        try Task.checkCancellation()
        guard let handle = FileHandle(forReadingAtPath: partialURL.path) else { throw MeetingTitlesModelFailure.installationFailed }
        defer { try? handle.close() }
        switch try verify(handle) {
        case .valid:
            break
        case .checksumMismatch:
            try? FileManager.default.removeItem(at: partialURL)
            throw MeetingTitlesModelFailure.checksumMismatch
        case .invalid:
            try? FileManager.default.removeItem(at: partialURL)
            throw MeetingTitlesModelFailure.invalidModel
        }
        try promotePartial()
        if let fingerprint = fingerprint(of: handle) {
            lock.withLock { verifiedFingerprint = fingerprint }
        }
    }

    /// An open read handle on the installed model, verified against the pin.
    /// The helper reads the model through this handle, so it gets the inode
    /// that was hashed, not whatever the path points at later. A file that
    /// fails the check is deleted.
    func openVerifiedModel() throws -> FileHandle {
        guard let handle = FileHandle(forReadingAtPath: modelURL.path) else {
            throw MeetingTitlesModelFailure.invalidModel
        }
        let fingerprint = fingerprint(of: handle)
        if let fingerprint, lock.withLock({ verifiedFingerprint == fingerprint }),
           (try? verifyShape(handle)) == .valid {
            try handle.seek(toOffset: 0)
            return handle
        }
        let result = try verify(handle)
        guard result == .valid else {
            try? handle.close()
            lock.withLock { verifiedFingerprint = nil }
            try? FileManager.default.removeItem(at: modelURL)
            throw result == .checksumMismatch ? MeetingTitlesModelFailure.checksumMismatch : .invalidModel
        }
        lock.withLock { verifiedFingerprint = fingerprint }
        try handle.seek(toOffset: 0)
        return handle
    }

    /// Removes the model and any partial. Only touches this asset's folder.
    func remove() throws {
        lock.withLock { verifiedFingerprint = nil }
        for url in [modelURL, partialURL] where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Download

    private enum ResponseMode { case append, restart }

    private func downloadRemaining(progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        var offset = partialBytes
        if offset > asset.expectedBytes {
            try? FileManager.default.removeItem(at: partialURL)
            offset = 0
        }
        if offset == asset.expectedBytes { return }
        if let available = availableDiskSpace(modelDirectory), available < asset.expectedBytes - offset {
            throw MeetingTitlesModelFailure.insufficientDiskSpace
        }
        guard FileManager.default.fileExists(atPath: partialURL.path)
            || FileManager.default.createFile(atPath: partialURL.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let handle = FileHandle(forUpdatingAtPath: partialURL.path) else {
            throw MeetingTitlesModelFailure.installationFailed
        }
        defer { try? handle.close() }
        excludeFromBackup(partialURL)

        var request = URLRequest(url: asset.downloadURL)
        request.httpMethod = "GET"
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }

        let writer = PartialWriter(handle: handle, offset: offset, expected: asset.expectedBytes, progress: progress)
        let expected = asset.expectedBytes
        let startOffset = offset
        do {
            try await fetcher.fetch(request, onResponse: { status, headers in
                let mode = try Self.validate(status: status, headers: headers, offset: startOffset, expected: expected)
                try writer.begin(restart: mode == .restart)
            }, onData: { data in
                try writer.append(data)
            })
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as MeetingTitlesModelFailure {
            throw failure
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw Self.isOutOfSpace(error) ? MeetingTitlesModelFailure.insufficientDiskSpace : .offline
        }
        try? handle.synchronize()
        guard writer.received == asset.expectedBytes else { throw MeetingTitlesModelFailure.offline }
    }

    private static func validate(
        status: Int, headers: [String: String], offset: Int64, expected: Int64
    ) throws -> ResponseMode {
        func header(_ name: String) -> String? {
            headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
        if status == 200 {
            if let length = header("Content-Length").flatMap(Int64.init), length != expected {
                throw MeetingTitlesModelFailure.serverRejectedRequest
            }
            return offset == 0 ? .append : .restart
        }
        guard offset > 0, status == 206,
              let range = header("Content-Range"),
              range.hasPrefix("bytes \(offset)-"),
              range.hasSuffix("/\(expected)") else {
            throw MeetingTitlesModelFailure.serverRejectedRequest
        }
        return .append
    }

    /// Writes body chunks to the partial file; never past the pinned size.
    private final class PartialWriter: @unchecked Sendable {
        private let handle: FileHandle
        private let expected: Int64
        private let progress: @Sendable (Int64, Int64) -> Void
        private let lock = NSLock()
        private var count: Int64

        init(handle: FileHandle, offset: Int64, expected: Int64, progress: @escaping @Sendable (Int64, Int64) -> Void) {
            self.handle = handle
            self.count = offset
            self.expected = expected
            self.progress = progress
        }

        var received: Int64 { lock.withLock { count } }

        func begin(restart: Bool) throws {
            try lock.withLock {
                if restart {
                    try handle.truncate(atOffset: 0)
                    count = 0
                }
                try handle.seek(toOffset: UInt64(count))
            }
            progress(received, expected)
        }

        func append(_ data: Data) throws {
            guard !data.isEmpty else { return }
            let now: Int64 = try lock.withLock {
                guard count + Int64(data.count) <= expected else { throw MeetingTitlesModelFailure.invalidModel }
                try handle.write(contentsOf: data)
                count += Int64(data.count)
                return count
            }
            progress(now, expected)
        }
    }

    // MARK: - Verification

    enum Verification: Equatable { case valid, invalid, checksumMismatch }

    /// Size, GGUF magic, then the full sha256 in 1 MB chunks.
    func verify(_ handle: FileHandle) throws -> Verification {
        guard try verifyShape(handle) == .valid else { return .invalid }
        try handle.seek(toOffset: 0)
        var hash = SHA256()
        while try autoreleasepool(invoking: { () throws -> Bool in
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty else { return false }
            hash.update(data: chunk)
            return true
        }) {}
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        return digest == asset.sha256.lowercased() ? .valid : .checksumMismatch
    }

    private func verifyShape(_ handle: FileHandle) throws -> Verification {
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              Int64(info.st_size) == asset.expectedBytes else { return .invalid }
        try handle.seek(toOffset: 0)
        guard try handle.read(upToCount: 4) == Data([0x47, 0x47, 0x55, 0x46]) else { return .invalid }
        return .valid
    }

    private struct FileFingerprint: Equatable {
        let device: Int64
        let inode: UInt64
        let size: Int64
        let modified: Int64
        let changed: Int64
    }

    private func fingerprint(of handle: FileHandle) -> FileFingerprint? {
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else { return nil }
        return FileFingerprint(
            device: Int64(info.st_dev),
            inode: UInt64(info.st_ino),
            size: Int64(info.st_size),
            modified: Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec),
            changed: Int64(info.st_ctimespec.tv_sec) * 1_000_000_000 + Int64(info.st_ctimespec.tv_nsec)
        )
    }

    // MARK: - Files

    private func ensureDirectory() throws {
        do {
            try FileManager.default.createDirectory(
                at: modelDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: modelDirectory.path)
        } catch {
            throw MeetingTitlesModelFailure.installationFailed
        }
        excludeFromBackup(modelDirectory.deletingLastPathComponent())
        excludeFromBackup(modelDirectory)
    }

    private func promotePartial() throws {
        do {
            if FileManager.default.fileExists(atPath: modelURL.path) {
                try FileManager.default.removeItem(at: modelURL)
            }
            try FileManager.default.moveItem(at: partialURL, to: modelURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: modelURL.path)
        } catch {
            throw MeetingTitlesModelFailure.installationFailed
        }
        excludeFromBackup(modelURL)
    }

    private func excludeFromBackup(_ url: URL) {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = url
        try? mutable.setResourceValues(values)
    }

    private func fileSize(at url: URL) -> Int64? {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        return Int64(info.st_size)
    }

    static let defaultDiskSpace: @Sendable (URL) -> Int64? = { url in
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.path != "/" {
            probe.deleteLastPathComponent()
        }
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    private static func isOutOfSpace(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.code == NSFileWriteOutOfSpaceError || nsError.code == Int(ENOSPC) { return true }
        return (nsError.userInfo[NSUnderlyingErrorKey] as? Error).map(isOutOfSpace) ?? false
    }
}

/// Production fetcher: a URLSession data task whose delegate writes each
/// chunk as it arrives, so the multi-GB body never sits in memory.
struct URLSessionMeetingTitlesModelFetcher: MeetingTitlesModelFetching {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "Transcripted.MeetingTitles.ModelDownload"
        return URLSession(configuration: configuration, delegate: nil, delegateQueue: queue)
    }()

    func fetch(
        _ request: URLRequest,
        onResponse: @escaping @Sendable (Int, [String: String]) throws -> Void,
        onData: @escaping @Sendable (Data) throws -> Void
    ) async throws {
        guard let url = request.url, MeetingTitlesModelNetworkPolicy.allows(url) else {
            throw MeetingTitlesModelFailure.serverRejectedRequest
        }
        let delegate = FetchDelegate(onResponse: onResponse, onData: onData)
        let task = Self.session.dataTask(with: request)
        task.delegate = delegate
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                delegate.setContinuation(continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    private final class FetchDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let onResponse: @Sendable (Int, [String: String]) throws -> Void
        private let onData: @Sendable (Data) throws -> Void
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?
        private var failure: Error?

        init(
            onResponse: @escaping @Sendable (Int, [String: String]) throws -> Void,
            onData: @escaping @Sendable (Data) throws -> Void
        ) {
            self.onResponse = onResponse
            self.onData = onData
        }

        func setContinuation(_ continuation: CheckedContinuation<Void, Error>) {
            lock.withLock { self.continuation = continuation }
        }

        private func record(_ error: Error) {
            lock.withLock { if failure == nil { failure = error } }
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            guard let http = response as? HTTPURLResponse else {
                record(MeetingTitlesModelFailure.serverRejectedRequest)
                completionHandler(.cancel)
                return
            }
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                if let key = key as? String, let value = value as? String { headers[key] = value }
            }
            do {
                try onResponse(http.statusCode, headers)
                completionHandler(.allow)
            } catch {
                record(error)
                completionHandler(.cancel)
            }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            do {
                try onData(data)
            } catch {
                record(error)
                dataTask.cancel()
            }
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(request.url.map(MeetingTitlesModelNetworkPolicy.allows) == true ? request : nil)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            let (waiting, recorded): (CheckedContinuation<Void, Error>?, Error?) = lock.withLock {
                defer { continuation = nil }
                return (continuation, failure)
            }
            if let recorded {
                waiting?.resume(throwing: recorded)
            } else if let error {
                waiting?.resume(throwing: (error as NSError).code == NSURLErrorCancelled ? CancellationError() : error)
            } else {
                waiting?.resume()
            }
        }
    }
}
