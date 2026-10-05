#if canImport(TranscriptedWritingCore)
import TranscriptedWritingCore
#endif
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

