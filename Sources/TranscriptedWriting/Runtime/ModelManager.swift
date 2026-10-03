#if canImport(TranscriptedWritingCore)
import TranscriptedWritingCore
#endif
import CryptoKit
import Foundation

/// The signed description of a model Tilde is willing to install.
///
/// A descriptor is deliberately complete: there is no runtime manifest lookup
/// and no floating branch in the download URL.  The bytes, rather than the
/// host serving them, are the trust boundary for the external model.
struct ModelDescriptor: Equatable, Sendable {
    let identifier: String
    let version: String
    let repository: String
    let revision: String
    let fileName: String
    let expectedBytes: Int64
    let sha256: String

    init(
        identifier: String,
        version: String,
        repository: String,
        revision: String,
        fileName: String,
        expectedBytes: Int64,
        sha256: String
    ) {
        precondition(!identifier.isEmpty)
        precondition(!version.isEmpty)
        precondition(!repository.isEmpty)
        precondition(!revision.isEmpty)
        precondition(!fileName.isEmpty)
        precondition(expectedBytes > 0)
        precondition(Self.isSHA256(sha256))
        precondition(!fileName.contains("/"), "model fileName must be a leaf name")

        self.identifier = identifier
        self.version = version
        self.repository = repository
        self.revision = revision
        self.fileName = fileName
        self.expectedBytes = expectedBytes
        self.sha256 = sha256.lowercased()
    }

    /// The exact immutable Hugging Face `resolve` URL.  The revision is a
    /// commit, not a branch or tag, and the file name is pinned in the signed
    /// descriptor.
    var downloadURL: URL {
        URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(fileName)")!
    }

    /// The default lightweight model supported by this Tilde release.
    static let gemma4E2BQ4KM = ModelDescriptor(
        identifier: ProductionModelAsset.identifier,
        version: ProductionModelAsset.revision,
        repository: ProductionModelAsset.repository,
        revision: ProductionModelAsset.revision,
        fileName: ProductionModelAsset.fileName,
        expectedBytes: ProductionModelAsset.expectedBytes,
        sha256: ProductionModelAsset.sha256
    )

    /// Compatibility spelling for call sites that use the model's display
    /// name rather than its quantization suffix.
    static let gemma4E2B = gemma4E2BQ4KM

    static let qwen35B9BQ4KM = ModelDescriptor(
        identifier: Qwen9BModelAsset.identifier,
        version: Qwen9BModelAsset.revision,
        repository: Qwen9BModelAsset.repository,
        revision: Qwen9BModelAsset.revision,
        fileName: Qwen9BModelAsset.fileName,
        expectedBytes: Qwen9BModelAsset.expectedBytes,
        sha256: Qwen9BModelAsset.sha256
    )

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
        }
    }
}

typealias Gemma4E2BModelDescriptor = ModelDescriptor

/// The externally visible lifecycle of the model asset.
enum ModelState: Equatable, Sendable {
    case checking
    case missing
    case downloading(receivedBytes: Int64, totalBytes: Int64)
    case verifying
    case ready(URL)
    case failed(ModelFailure)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    var modelURL: URL? {
        if case let .ready(url) = self { return url }
        return nil
    }
}

/// Failures intentionally contain no server text, paths, or user data.  This
/// keeps diagnostics safe and gives setup a small, stable repair vocabulary.
enum ModelFailure: Equatable, Sendable {
    case offline
    case insufficientDiskSpace
    case serverRejectedRequest
    case checksumMismatch
    case invalidModel
    case installationFailed
}

/// An open, verified model inode. Passing this handle into the child binds
/// runtime launch to the bytes that were hashed instead of re-opening a path
/// that another same-user process could replace.
struct VerifiedModelFile: @unchecked Sendable {
    let url: URL
    let handle: FileHandle
}

/// A streaming HTTP response used by `ModelManager`.
///
/// `body` yields bounded chunks.  Implementations must not materialize the
/// model as one `Data` value.  Tests can provide a deterministic stream while
/// production uses `URLSessionModelDownloadTransport`.
struct ModelDownloadResponse: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let body: AsyncThrowingStream<Data, Error>

    init(
        statusCode: Int,
        headers: [String: String] = [:],
        body: AsyncThrowingStream<Data, Error>
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    init(statusCode: Int, headers: [String: String] = [:], chunks: [Data]) {
        self.init(
            statusCode: statusCode,
            headers: headers,
            body: AsyncThrowingStream { continuation in
                for chunk in chunks { continuation.yield(chunk) }
                continuation.finish()
            }
        )
    }
}

protocol ModelDownloadTransport: Sendable {
    func response(for request: URLRequest) async throws -> ModelDownloadResponse
}

enum ModelDownloadNetworkPolicy {
    static func allows(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else {
            return false
        }
        return host == "huggingface.co" || host.hasSuffix(".hf.co")
    }
}

/// Convenient adapter for tests and other local callers.
struct ClosureModelDownloadTransport: ModelDownloadTransport {
    let handler: @Sendable (URLRequest) async throws -> ModelDownloadResponse

    init(_ handler: @escaping @Sendable (URLRequest) async throws -> ModelDownloadResponse) {
        self.handler = handler
    }

    func response(for request: URLRequest) async throws -> ModelDownloadResponse {
        try await handler(request)
    }
}

/// Owns one verified model in Application Support.
///
/// All lifecycle mutation is serialized through `stateQueue`; the potentially
/// slow network and hashing work runs in an async task and never blocks that
/// queue.  A durable `.partial` is written in the model directory and only a
/// fully verified file is promoted to `model.gguf`.
final class ModelManager: @unchecked Sendable {
    typealias State = ModelState
    typealias Failure = ModelFailure
    typealias StateHandler = @Sendable (ModelState) -> Void
    typealias ProgressHandler = @Sendable (Int64, Int64) -> Void
    typealias DiskSpaceProvider = @Sendable (URL) -> Int64?

    static var defaultDescriptor: ModelDescriptor {
        switch TildeProductProfile.current {
        case .production:
            TildeModelSelection.descriptor(
                for: .production,
                productionChoice: TildeModelSelection.choice(for: .production)
            )
        case .preview9B: .qwen35B9BQ4KM
        }
    }

    let descriptor: ModelDescriptor
    let rootDirectory: URL
    let modelDirectory: URL
    let modelURL: URL
    let partialURL: URL

    var state: ModelState { stateQueue.sync { stateStorage } }
    var currentState: ModelState { state }
    var installedModelURL: URL? { state.modelURL }

    /// Revalidates the exact bytes at the runtime handoff. A prior `.ready`
    /// state is not enough because the external file can be replaced after the
    /// manager's initial check.
    ///
    /// The full SHA-256 of the model (3.4–5.6 GB, seconds of I/O and one
    /// saturated core) runs on an unlinked read-only clone of `model.gguf`,
    /// and the manager holds that clone. While the source's content
    /// fingerprint (inode, size, modification, change, and creation times,
    /// read under the directory lock) still equals the one the clone was made
    /// at, the handoff serves the held bytes: the first time a duplicate of
    /// the hashed descriptor itself (its pages are already warm), after that
    /// a fresh clone of it. The served bytes are therefore always bytes this
    /// process hashed, even if the source is written through a shared
    /// mapping that the fingerprint can't see. Any in-place write or
    /// replacement moves the fingerprint and forces a fresh clone and full
    /// hash; the size and magic checks still run on every handoff. The held
    /// clone is dropped whenever the manager leaves `.ready`, is cancelled,
    /// or deletes the model, so an install, delete, or re-download always
    /// hashes. What this removes is the re-hash on every helper restart.
    func verifiedInstalledModelFile() -> VerifiedModelFile? {
        guard state.isReady else { return nil }
        if let held = stateQueue.sync(execute: { heldModel }),
           SecureLocalStorage.contentFingerprint(ofOwnerOnlyFileAt: modelURL) == held.fingerprint,
           let served = serve(from: held) {
            return VerifiedModelFile(url: modelURL, handle: served)
        }
        releaseHeldModel()
        var fingerprint: SecureLocalStorage.FileContentFingerprint?
        guard let clone = SecureLocalStorage.openUnlinkedCloneForReading(at: modelURL, fingerprint: &fingerprint),
              let fingerprint,
              (try? verifyModel(from: clone)) == .valid else { return nil }
        let candidate = HeldModel(handle: clone, fingerprint: fingerprint, handedOut: false)
        let replaced: HeldModel? = stateQueue.sync {
            guard stateStorage.isReady else { return nil }
            defer { heldModel = candidate }
            return heldModel
        }
        _ = replaced
        guard let served = serve(from: candidate) else { return nil }
        return VerifiedModelFile(url: modelURL, handle: served)
    }

    /// A clone this process hashed, and the source fingerprint it was made at.
    private struct HeldModel {
        let handle: FileHandle
        let fingerprint: SecureLocalStorage.FileContentFingerprint
        let handedOut: Bool
    }

    /// Never hands out the held handle itself: the first handoff gets a
    /// duplicate descriptor, later ones a fresh clone, which is then held in
    /// its place so the previous helper's pages can go.
    private func serve(from held: HeldModel) -> FileHandle? {
        let served: FileHandle
        let next: HeldModel
        if held.handedOut {
            guard let clone = SecureLocalStorage.openUnlinkedClone(of: held.handle, inDirectory: modelDirectory),
                  let keep = Self.duplicate(clone) else { return nil }
            served = clone
            next = HeldModel(handle: keep, fingerprint: held.fingerprint, handedOut: true)
        } else {
            guard let duplicate = Self.duplicate(held.handle) else { return nil }
            served = duplicate
            next = HeldModel(handle: held.handle, fingerprint: held.fingerprint, handedOut: true)
        }
        guard (try? verifyModelShape(from: served)) == .valid,
              (try? served.seek(toOffset: 0)) != nil else { return nil }
        let replaced: HeldModel? = stateQueue.sync {
            guard heldModel?.handle === held.handle else { return nil }
            defer { heldModel = next }
            return heldModel
        }
        _ = replaced
        return served
    }

    private static func duplicate(_ handle: FileHandle) -> FileHandle? {
        let descriptor = fcntl(handle.fileDescriptor, F_DUPFD_CLOEXEC, 0)
        return descriptor >= 0 ? FileHandle(fileDescriptor: descriptor, closeOnDealloc: true) : nil
    }

    /// Drops the held clone outside `stateQueue`, so closing its descriptor
    /// never runs under the lock.
    private func releaseHeldModel() {
        let released: HeldModel? = stateQueue.sync {
            defer { heldModel = nil }
            return heldModel
        }
        _ = released
    }

    /// Number of full content hashes this manager has computed; tests only.
    var fullVerificationCount: Int { stateQueue.sync { fullVerifications } }

    private let transport: any ModelDownloadTransport
    private let callbackQueue: DispatchQueue
    private let stateQueue = DispatchQueue(label: "com.justinbetker.draft.model-manager-state")
    /// Full hashes run here, never on the Swift cooperative pool.
    private let hashQueue = DispatchQueue(label: "com.justinbetker.draft.model-manager-hash")
    private let availableDiskSpace: DiskSpaceProvider
    private let retryDelays: [Duration]
    private let stateHandler: StateHandler?
    private let progressHandler: ProgressHandler?
    private var stateStorage: ModelState = .checking
    private var activeTask: Task<Void, Never>?
    private var activeGeneration: UInt64 = 0
    private var heldModel: HeldModel?
    private var fullVerifications = 0

    init(
        descriptor: ModelDescriptor = ModelManager.defaultDescriptor,
        rootDirectory: URL? = nil,
        transport: any ModelDownloadTransport = URLSessionModelDownloadTransport(),
        callbackQueue: DispatchQueue = .main,
        onStateChange: StateHandler? = nil,
        onProgress: ProgressHandler? = nil,
        availableDiskSpace: @escaping DiskSpaceProvider = ModelManager.defaultDiskSpace,
        retryDelays: [Duration] = [
            .milliseconds(500), .seconds(1), .seconds(2), .seconds(4),
            .seconds(8), .seconds(16), .seconds(30), .seconds(30)
        ]
    ) {
        self.descriptor = descriptor
        let root = rootDirectory ?? Self.defaultRootDirectory
        self.rootDirectory = Self.canonicalRoot(root)
        self.modelDirectory = self.rootDirectory.appendingPathComponent(descriptor.identifier, isDirectory: true)
        self.modelURL = self.modelDirectory.appendingPathComponent("model.gguf", isDirectory: false)
        self.partialURL = self.modelDirectory.appendingPathComponent("model.gguf.partial", isDirectory: false)
        self.transport = transport
        self.callbackQueue = callbackQueue
        self.stateHandler = onStateChange
        self.progressHandler = onProgress
        self.availableDiskSpace = availableDiskSpace
        self.retryDelays = retryDelays
    }

    static var defaultRootDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport
            .appendingPathComponent(TildeProductProfile.current.supportDirectoryName, isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    /// Resolve symlinks in the existing prefix even when the model-store leaf
    /// has not been created yet (for example macOS's `/var` -> `/private/var`).
    private static func canonicalRoot(_ url: URL) -> URL {
        var existing = url.standardizedFileURL
        var missingComponents: [String] = []
        while existing.path != "/", !FileManager.default.fileExists(atPath: existing.path) {
            missingComponents.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        let resolvedPrefix: String
        if let canonical = realpath(existing.path, nil) {
            defer { free(canonical) }
            resolvedPrefix = String(cString: canonical)
        } else {
            resolvedPrefix = existing.path
        }
        var resolved = URL(fileURLWithPath: resolvedPrefix, isDirectory: true)
        for component in missingComponents {
            resolved.appendPathComponent(component, isDirectory: true)
        }
        return resolved
    }

    /// Starts a check/download if another lifecycle operation is not already
    /// running.  Returns false when a concurrent caller already owns it.
    @discardableResult
    func start() -> Bool {
        stateQueue.sync {
            guard activeTask == nil else { return false }
            activeGeneration &+= 1
            let generation = activeGeneration
            let task = Task { [weak self] in
                guard let self else { return }
                await self.run(generation: generation)
            }
            activeTask = task
            return true
        }
    }

    func prepare() { _ = start() }
    func refresh() { _ = start() }

    /// Waits until the current check/download task has finished.  This is
    /// useful to lifecycle owners and makes deterministic tests straightforward.
    func waitUntilSettled() async {
        while stateQueue.sync(execute: { activeTask != nil }) {
            // Transcripted: a cancelled waiter returns instead of spinning
            // until a superseded download finishes.
            if Task.isCancelled { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Transcripted deviation: stops an in-flight check or download without
    /// deleting anything. Tilde never needed it because it relaunched on a
    /// model switch; Transcripted swaps managers in place instead. A resumable
    /// `.partial` stays on disk for a later switch back.
    func cancel() {
        let task = stateQueue.sync { () -> Task<Void, Never>? in
            activeGeneration &+= 1
            let oldTask = activeTask
            activeTask = nil
            return oldTask
        }
        task?.cancel()
        releaseHeldModel()
    }

    /// Cancels an in-flight operation and removes both the verified model and
    /// any durable partial.  The async variant is the completion point for UI
    /// callers that need to reopen setup only after deletion is complete.
    func deleteModel() {
        Task { await deleteModelAndWait() }
    }

    func deleteModelAndWait() async {
        let task = stateQueue.sync { () -> Task<Void, Never>? in
            activeGeneration &+= 1
            let oldTask = activeTask
            activeTask = nil
            return oldTask
        }
        task?.cancel()
        await task?.value
        releaseHeldModel()
        do {
            try removeModelFiles()
            publish(.missing)
        } catch {
            publish(.failed(.installationFailed))
        }
    }

    private func run(generation: UInt64) async {
        defer { finish(generation: generation) }
        do {
            publish(.checking, generation: generation)
            try Task.checkCancellation()
            try ensureModelDirectory()

            // Hold the launch check's hashed clone so the first runtime
            // handoff serves those bytes instead of hashing the multi-GB
            // model a second time.
            let installed = try await verifyInstalledModel(qos: .userInitiated)
            if installed.result == .valid {
                publish(.ready(modelURL), generation: generation, held: installed.held)
                return
            }
            if FileManager.default.fileExists(atPath: modelURL.path) {
                try removeItem(at: modelURL)
            }
            publish(.missing, generation: generation)

            var partialBytes = try partialByteCount()
            if partialBytes > descriptor.expectedBytes {
                try removeItem(at: partialURL)
                partialBytes = 0
            }
            if partialBytes == descriptor.expectedBytes {
                switch try await verifyPartial() {
                case .valid:
                    try promotePartial()
                    publish(.ready(modelURL), generation: generation)
                    return
                case .checksumMismatch, .invalid:
                    try removeItem(at: partialURL)
                    partialBytes = 0
                }
            }
            try await downloadWithRetries(generation: generation)
            publish(.verifying, generation: generation)
            try Task.checkCancellation()

            switch try await verifyPartial() {
            case .valid:
                break
            case .checksumMismatch:
                try? removeItem(at: partialURL)
                throw ManagerError.checksumMismatch
            case .invalid:
                try? removeItem(at: partialURL)
                throw ManagerError.invalidModel
            }
            try promotePartial()
            let promoted = try await verifyInstalledModel(qos: .userInitiated)
            switch promoted.result {
            case .valid:
                break
            case .checksumMismatch:
                try? removeItem(at: modelURL)
                throw ManagerError.checksumMismatch
            case .invalid:
                try? removeItem(at: modelURL)
                throw ManagerError.invalidModel
            }
            publish(.ready(modelURL), generation: generation, held: promoted.held)
        } catch is CancellationError {
            // A delete or a newer operation owns the next state.  Do not turn
            // an intentional cancellation into a user-visible failure.
        } catch {
            publish(.failed(map(error)), generation: generation)
        }
    }

    private enum ResponseMode { case append, restart }

    private func downloadWithRetries(generation: UInt64) async throws {
        var retryIndex = 0
        while true {
            do {
                try await downloadRemaining(generation: generation)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard map(error) == .offline, retryIndex < retryDelays.count else { throw error }
                let received = (try? partialByteCount()) ?? 0
                publish(
                    .downloading(receivedBytes: received, totalBytes: descriptor.expectedBytes),
                    generation: generation
                )
                let delay = retryDelays[retryIndex]
                retryIndex += 1
                try await Task.sleep(for: delay)
            }
        }
    }

    private func downloadRemaining(generation: UInt64) async throws {
        var partialBytes = try partialByteCount()
        let requiredBytes = descriptor.expectedBytes - partialBytes
        if let available = availableDiskSpace(modelDirectory), available < requiredBytes {
            throw ManagerError.insufficientDiskSpace
        }

        try Task.checkCancellation()
        let request = makeRequest(startingAt: partialBytes)
        let response = try await transport.response(for: request)
        try Task.checkCancellation()
        let mode = try validate(response: response, startingAt: partialBytes)
        if mode == .restart {
            partialBytes = 0
            try truncatePartial()
        }

        publish(.downloading(receivedBytes: partialBytes, totalBytes: descriptor.expectedBytes), generation: generation)
        try await append(response.body, to: partialURL, startingAt: partialBytes, generation: generation)
    }

    private func makeRequest(startingAt offset: Int64) -> URLRequest {
        var request = URLRequest(url: descriptor.downloadURL)
        request.httpMethod = "GET"
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        return request
    }

    private func validate(response: ModelDownloadResponse, startingAt offset: Int64) throws -> ResponseMode {
        if offset == 0 {
            guard response.statusCode == 200 else { throw ManagerError.serverRejectedRequest }
            if let length = header("Content-Length", response.headers),
               let bytes = Int64(length), bytes != descriptor.expectedBytes {
                throw ManagerError.serverRejectedRequest
            }
            return .append
        }

        if response.statusCode == 200 {
            if let length = header("Content-Length", response.headers),
               let bytes = Int64(length), bytes != descriptor.expectedBytes {
                throw ManagerError.serverRejectedRequest
            }
            return .restart
        }

        guard response.statusCode == 206,
              let contentRange = header("Content-Range", response.headers),
              let range = parseContentRange(contentRange),
              range.start == offset,
              range.total == descriptor.expectedBytes,
              range.end >= range.start else {
            throw ManagerError.serverRejectedRequest
        }
        if let length = header("Content-Length", response.headers),
           let bytes = Int64(length), bytes != range.end - range.start + 1 {
            throw ManagerError.serverRejectedRequest
        }
        return .append
    }

    private func append(
        _ stream: AsyncThrowingStream<Data, Error>,
        to url: URL,
        startingAt offset: Int64,
        generation: UInt64
    ) async throws {
        guard let handle = SecureLocalStorage.openFileForReadingAndAppending(at: url) else {
            throw ManagerError.installationFailed
        }
        try excludeFromBackup(url)
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(offset))
            var received = offset
            for try await chunk in stream {
                try Task.checkCancellation()
                guard !chunk.isEmpty else { continue }
                let next = received + Int64(chunk.count)
                guard next <= descriptor.expectedBytes else {
                    throw ManagerError.invalidModel
                }
                try handle.write(contentsOf: chunk)
                received = next
                publish(.downloading(receivedBytes: received, totalBytes: descriptor.expectedBytes), generation: generation)
            }
            try handle.synchronize()
            guard received == descriptor.expectedBytes else {
                throw ManagerError.invalidModel
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ManagerError {
            throw error
        } catch {
            if Self.isOutOfSpace(error) { throw ManagerError.insufficientDiskSpace }
            if Self.isOffline(error) { throw ManagerError.offline }
            throw ManagerError.installationFailed
        }
    }

    private enum VerificationResult: Equatable { case valid, invalid, checksumMismatch }

    /// Hashes an unlinked clone of `model.gguf` off the cooperative pool and
    /// returns it to hold for the first handoff. A looser mode is tightened
    /// to 0600 first (only when it differs). When the clone can't be made the
    /// file is hashed in place instead, so a clone failure never becomes a
    /// verdict that deletes the model; cancellation throws.
    private func verifyInstalledModel(
        qos: DispatchQoS.QoSClass
    ) async throws -> (result: VerificationResult, held: HeldModel?) {
        var info = stat()
        if lstat(modelURL.path, &info) != 0 {
            if errno == ENOENT { return (.invalid, nil) }
            throw ManagerError.installationFailed
        }
        guard let source = SecureLocalStorage.openExistingFileForReadingAndWriting(at: modelURL) else {
            throw ManagerError.installationFailed
        }
        try? source.close()
        return try await hashOffPool(qos: qos) { isCancelled in
            var fingerprint: SecureLocalStorage.FileContentFingerprint?
            guard let clone = SecureLocalStorage.openUnlinkedCloneForReading(at: self.modelURL, fingerprint: &fingerprint),
                  let fingerprint else {
                return (result: try self.verifyModel(at: self.modelURL, isCancelled: isCancelled), held: nil)
            }
            let result = try self.verifyModel(from: clone, isCancelled: isCancelled)
            let held = result == .valid ? HeldModel(handle: clone, fingerprint: fingerprint, handedOut: false) : nil
            return (result: result, held: held)
        }
    }

    private func verifyPartial() async throws -> VerificationResult {
        try await hashOffPool(qos: .userInitiated) { isCancelled in
            try self.verifyModel(at: self.partialURL, isCancelled: isCancelled)
        }
    }

    /// Runs `work` on `hashQueue` at `qos`; cancelling the calling task makes
    /// the hash throw `CancellationError` at its next chunk.
    private func hashOffPool<T>(
        qos: DispatchQoS.QoSClass,
        _ work: @escaping @Sendable (_ isCancelled: () -> Bool) throws -> T
    ) async throws -> T {
        let cancellation = ModelHashCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                hashQueue.async(qos: DispatchQoS(qosClass: qos, relativePriority: 0), flags: .enforceQoS) {
                    continuation.resume(with: Result { try work(cancellation.isCancelled) })
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func verifyModel(at url: URL, isCancelled: () -> Bool = { false }) throws -> VerificationResult {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            if errno == ENOENT { return .invalid }
            throw ManagerError.installationFailed
        }
        guard let handle = SecureLocalStorage.openExistingFileForReadingAndWriting(at: url) else {
            throw ManagerError.installationFailed
        }
        defer { try? handle.close() }
        return try verifyModel(from: handle, isCancelled: isCancelled)
    }

    private func verifyModel(from handle: FileHandle, isCancelled: () -> Bool = { false }) throws -> VerificationResult {
        let shape = try verifyModelShape(from: handle)
        guard shape == .valid else { return shape }
        try handle.seek(toOffset: 0)
        stateQueue.sync { fullVerifications += 1 }
        let digest = try ModelFileHasher.sha256Hex(from: handle, isCancelled: isCancelled)
        return digest == descriptor.sha256.lowercased() ? .valid : .checksumMismatch
    }

    /// The cheap half of `verifyModel`: a regular file of exactly the expected
    /// size that opens with the GGUF magic. Never a substitute for the hash on
    /// its own; the handoff uses it alone only for bytes this process has
    /// already hashed.
    private func verifyModelShape(from handle: FileHandle) throws -> VerificationResult {
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_size == descriptor.expectedBytes else { return .invalid }
        try handle.seek(toOffset: 0)
        guard let bytes = try handle.read(upToCount: 4),
              bytes == Data([0x47, 0x47, 0x55, 0x46]) else { return .invalid }
        return .valid
    }

    private func ensureModelDirectory() throws {
        do {
            guard SecureLocalStorage.ensureOwnerOnlyDirectory(at: modelDirectory) else {
                throw ManagerError.installationFailed
            }
            try excludeFromBackup(rootDirectory)
            try excludeFromBackup(modelDirectory)
        } catch {
            throw ManagerError.installationFailed
        }
    }

    private func partialByteCount() throws -> Int64 {
        var info = stat()
        if lstat(partialURL.path, &info) != 0 {
            if errno == ENOENT { return 0 }
            throw ManagerError.installationFailed
        }
        guard let handle = SecureLocalStorage.openExistingFileForReadingAndWriting(at: partialURL),
              fstat(handle.fileDescriptor, &info) == 0 else {
            throw ManagerError.installationFailed
        }
        defer { try? handle.close() }
        return info.st_size
    }

    private func truncatePartial() throws {
        guard let handle = SecureLocalStorage.openFileForReadingAndAppending(at: partialURL) else {
            throw ManagerError.installationFailed
        }
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try excludeFromBackup(partialURL)
    }

    private func promotePartial() throws {
        do {
            try setFilePermissions(at: partialURL, permissions: 0o600)
            try excludeFromBackup(partialURL)
            guard SecureLocalStorage.replaceOwnerOnlyFile(at: modelURL, with: partialURL) else {
                throw ManagerError.installationFailed
            }
            try setFilePermissions(at: modelURL, permissions: 0o600)
            try excludeFromBackup(modelURL)
        } catch {
            throw ManagerError.installationFailed
        }
    }

    private func removeModelFiles() throws {
        try removeItemIfPresent(at: modelURL)
        try removeItemIfPresent(at: partialURL)
    }

    private func removeItem(at url: URL) throws {
        guard SecureLocalStorage.removeOwnerOnlyFile(at: url) else {
            throw ManagerError.installationFailed
        }
    }

    private func removeItemIfPresent(at url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            if errno == ENOENT { return }
            throw ManagerError.installationFailed
        }
        try removeItem(at: url)
    }

    private func excludeFromBackup(_ url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        do { try mutableURL.setResourceValues(values) }
        catch { throw ManagerError.installationFailed }
    }

    private func setFilePermissions(at url: URL, permissions: Int) throws {
        do {
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        } catch {
            throw ManagerError.installationFailed
        }
    }

    private func publish(
        _ state: ModelState,
        generation: UInt64? = nil,
        held newHeld: HeldModel? = nil
    ) {
        var released: HeldModel?
        let callbacks: (StateHandler?, ProgressHandler?) = stateQueue.sync {
            if let generation, generation != activeGeneration { return (nil, nil) }
            stateStorage = state
            if !state.isReady || newHeld != nil {
                released = heldModel
                heldModel = newHeld
            }
            return (stateHandler, progressHandler)
        }
        _ = released
        guard callbacks.0 != nil || callbacks.1 != nil else { return }
        callbackQueue.async {
            callbacks.0?(state)
            if case let .downloading(receivedBytes, totalBytes) = state {
                callbacks.1?(receivedBytes, totalBytes)
            }
        }
    }

    private func finish(generation: UInt64) {
        stateQueue.sync {
            guard generation == activeGeneration else { return }
            activeTask = nil
        }
    }

    private func map(_ error: Error) -> ModelFailure {
        if let error = error as? ManagerError {
            switch error {
            case .insufficientDiskSpace: return .insufficientDiskSpace
            case .serverRejectedRequest: return .serverRejectedRequest
            case .checksumMismatch: return .checksumMismatch
            case .invalidModel: return .invalidModel
            case .installationFailed: return .installationFailed
            case .offline: return .offline
            }
        }
        if Self.isOffline(error) { return .offline }
        return .installationFailed
    }

    private enum ManagerError: Error {
        case offline
        case insufficientDiskSpace
        case serverRejectedRequest
        case checksumMismatch
        case invalidModel
        case installationFailed
    }

    private func header(_ name: String, _ headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    private func parseContentRange(_ value: String) -> (start: Int64, end: Int64, total: Int64)? {
        let parts = value.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0].lowercased() == "bytes" else { return nil }
        let rangeAndTotal = parts[1].split(separator: "/", maxSplits: 1).map(String.init)
        guard rangeAndTotal.count == 2, let total = Int64(rangeAndTotal[1]) else { return nil }
        let bounds = rangeAndTotal[0].split(separator: "-", maxSplits: 1).map(String.init)
        guard bounds.count == 2, let start = Int64(bounds[0]), let end = Int64(bounds[1]) else { return nil }
        return (start, end, total)
    }

    private static func defaultDiskSpace(_ url: URL) -> Int64? {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey]
        return try? url.resourceValues(forKeys: keys).volumeAvailableCapacityForImportantUsage
    }

    private static func isOffline(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorNotConnectedToInternet,
                 NSURLErrorNetworkConnectionLost,
                 NSURLErrorCannotFindHost,
                 NSURLErrorDNSLookupFailed,
                 NSURLErrorTimedOut,
                 NSURLErrorResourceUnavailable:
                return true
            default: break
            }
        }
        return (nsError.userInfo[NSUnderlyingErrorKey] as? Error).map(isOffline) ?? false
    }

    private static func isOutOfSpace(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.code == NSFileWriteOutOfSpaceError || nsError.code == ENOSPC { return true }
        return (nsError.userInfo[NSUnderlyingErrorKey] as? Error).map(isOutOfSpace) ?? false
    }
}
