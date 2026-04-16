// ModelDownloadService.swift
// Resilient model download with HuggingFace mirror fallback, retry logic,
// and error classification. Provides retry wrapping for FluidAudio model initialization.

import Foundation
import Network
import CryptoKit

// MARK: - Error Classification

/// Categorizes download errors for user-friendly messaging
public enum DownloadErrorKind: Equatable {
    case networkOffline
    case tlsFailure
    case timeout
    case diskSpace
    case serverError(statusCode: Int)
    case unknown(String)

    public var title: String {
        switch self {
        case .networkOffline: return "No Internet Connection"
        case .tlsFailure: return "Secure Connection Failed"
        case .timeout: return "Download Timed Out"
        case .diskSpace: return "Not Enough Disk Space"
        case .serverError: return "Server Error"
        case .unknown: return "Download Failed"
        }
    }

    public var detail: String {
        switch self {
        case .networkOffline:
            return "Connect to the internet and try again."
        case .tlsFailure:
            return "Could not establish a secure connection to the download server. Check your network or try a VPN."
        case .timeout:
            return "The download took too long. Try again or check your connection speed."
        case .diskSpace:
            return "Free up at least 1 GB of disk space and try again."
        case .serverError(let code):
            return "The download server returned an error (\(code)). This is usually temporary — try again in a few minutes."
        case .unknown(let message):
            return message
        }
    }
}

/// Structured download error with classification
public struct ModelDownloadError: Error, LocalizedError {
    public let kind: DownloadErrorKind
    public let underlyingError: Error?

    public init(kind: DownloadErrorKind, underlyingError: Error?) {
        self.kind = kind
        self.underlyingError = underlyingError
    }

    public var errorDescription: String? {
        kind.detail
    }
}

// MARK: - Download Service

public enum ModelDownloadService {

    /// HuggingFace mirror URLs, tried in order
    private static let mirrors: [String] = [
        "https://huggingface.co",
        "https://hf-mirror.com"
    ]

    /// Default retry configuration
    public static let maxRetries = 3
    private static let retryDelays: [UInt64] = [2_000_000_000, 5_000_000_000, 10_000_000_000] // 2s, 5s, 10s

    // MARK: - Network Reachability

    /// Quick network connectivity check using NWPathMonitor.
    /// Returns true if any network path is available.
    public static func checkNetworkReachability() async -> Bool {
        // Box to safely track whether continuation has been resumed.
        // Both the handler and timeout run on the same serial queue, so no lock needed.
        class ResumeGuard { var done = false }

        return await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let queue = DispatchQueue(label: "com.transcripted.network-check", qos: .utility)
            let guard_ = ResumeGuard()

            monitor.pathUpdateHandler = { path in
                guard !guard_.done else { return }
                guard_.done = true
                monitor.cancel()
                continuation.resume(returning: path.status == .satisfied)
            }
            monitor.start(queue: queue)

            // Timeout after 3 seconds — if we can't determine network status, assume offline
            queue.asyncAfter(deadline: .now() + 3) {
                guard !guard_.done else { return }
                guard_.done = true
                monitor.cancel()
                continuation.resume(returning: false)
            }
        }
    }

    // MARK: - Error Classification

    /// Classify any Error into a user-friendly DownloadErrorKind
    public static func classifyError(_ error: Error) -> DownloadErrorKind {
        let nsError = error as NSError

        // Check for disk space first
        if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteOutOfSpaceError {
            return .diskSpace
        }
        if nsError.domain == NSPOSIXErrorDomain && nsError.code == 28 { // ENOSPC
            return .diskSpace
        }

        // URL errors
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorNotConnectedToInternet,
                 NSURLErrorNetworkConnectionLost,
                 NSURLErrorDataNotAllowed,
                 NSURLErrorCannotFindHost,
                 NSURLErrorCannotConnectToHost,
                 NSURLErrorDNSLookupFailed:
                return .networkOffline
            case NSURLErrorSecureConnectionFailed,
                 NSURLErrorServerCertificateHasBadDate,
                 NSURLErrorServerCertificateUntrusted,
                 NSURLErrorServerCertificateHasUnknownRoot,
                 NSURLErrorServerCertificateNotYetValid,
                 NSURLErrorClientCertificateRejected,
                 NSURLErrorClientCertificateRequired:
                return .tlsFailure
            case NSURLErrorTimedOut:
                return .timeout
            default:
                break
            }
        }

        return .unknown(error.localizedDescription)
    }

    /// Check available disk space in bytes
    public static func availableDiskSpace() -> UInt64? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let available = values.volumeAvailableCapacityForImportantUsage else {
            return nil
        }
        return UInt64(available)
    }

    // MARK: - Retry Wrapper

    /// Execute an async operation with retry logic and exponential backoff.
    /// Classifies errors on each attempt and only retries transient failures.
    public static func withRetry<T>(
        maxAttempts: Int = maxRetries,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        var lastError: Error?

        for attempt in 0..<maxAttempts {
            do {
                return try await operation()
            } catch {
                lastError = error
                let kind = classifyError(error)

                // Don't retry permanent failures
                switch kind {
                case .diskSpace:
                    throw ModelDownloadError(kind: kind, underlyingError: error)
                default:
                    break
                }

                // Log retry
                AppLogger.services.warning("Download attempt \(attempt + 1)/\(maxAttempts) failed", [
                    "error": error.localizedDescription,
                    "kind": kind.title
                ])

                // Wait before retrying (unless this was the last attempt)
                if attempt < maxAttempts - 1 {
                    let delay = retryDelays[min(attempt, retryDelays.count - 1)]
                    try? await Task.sleep(nanoseconds: delay)
                }
            }
        }

        // All retries exhausted — guard handles the edge case where maxAttempts is 0
        // (loop never runs, lastError stays nil); force-unwrap here would be a DoS vector
        guard let exhaustedError = lastError else {
            throw ModelDownloadError(kind: .unknown("No download was attempted (maxAttempts was 0)"), underlyingError: nil)
        }
        let kind = classifyError(exhaustedError)
        throw ModelDownloadError(kind: kind, underlyingError: exhaustedError)
    }

    // MARK: - Filename Validation

    /// Validate a filename returned by an external API before using it in a file path.
    /// Security: filenames are attacker-controlled data from an external API response.
    /// A compromised or impersonated server could inject path traversal sequences (e.g. "../../../.ssh/authorized_keys")
    /// into rfilename values. We reject any name containing ".." components or absolute paths.
    static func isSafeModelFilename(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        guard !name.hasPrefix("/") else { return false }
        let components = name.components(separatedBy: "/")
        guard !components.contains("..") && !components.contains(".") else { return false }
        guard !name.unicodeScalars.contains(where: { $0.value < 32 }) else { return false }
        return true
    }

    /// Validate a HuggingFace model ID before interpolating it into download URLs.
    /// Security: modelId is string-interpolated directly into HTTPS URLs. An attacker-controlled
    /// or misconfigured value containing path traversal sequences (e.g. "../../foo") or
    /// URL-breaking characters could cause the request to hit an unexpected endpoint.
    /// Allowlist: "namespace/model-name" — alphanumerics, hyphens, underscores, dots, and
    /// exactly one optional slash separating namespace from model name.
    static func isSafeModelId(_ modelId: String) -> Bool {
        guard !modelId.isEmpty, modelId.count <= 200 else { return false }
        // Must not contain ".." traversal components
        let components = modelId.components(separatedBy: "/")
        guard !components.contains(".."), !components.contains(".") else { return false }
        // At most two path components (namespace/model) — extra slashes are suspicious
        guard components.count <= 2 else { return false }
        // Each component must be non-empty and consist only of safe characters
        let safeChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        for component in components {
            guard !component.isEmpty,
                  component.unicodeScalars.allSatisfy({ safeChars.contains($0) }) else {
                return false
            }
        }
        return true
    }


    // MARK: - HuggingFace Model Download Infrastructure

    /// Represents a file in a HuggingFace model repository
    struct HFModelFile {
        let name: String
        let size: Int?
        /// SHA-256 hex digest for LFS-tracked files (e.g. model weights).
        /// Populated from the HuggingFace API response when available.
        /// Security: used to verify file integrity after download from mirrors,
        /// so a compromised third-party mirror cannot silently serve malicious weights.
        let sha256: String?
    }

    /// Fetch the list of files in a HuggingFace model repository
    static func fetchModelFileList(modelId: String) async throws -> [HFModelFile] {
        // Security: validate modelId against an allowlist before interpolating into URLs.
        // An untrusted or misconfigured modelId containing ".." or extra slashes could cause
        // the request to hit an unintended endpoint on the mirror server.
        guard isSafeModelId(modelId) else {
            throw ModelDownloadError(
                kind: .unknown("Invalid model ID '\(modelId)' — must match namespace/model-name format"),
                underlyingError: nil
            )
        }
        // Try each mirror for the API call
        for mirror in mirrors {
            // Security: use safe URL construction — force-unwrap would crash if modelId or mirror
            // contained URL-unsafe characters. Guard lets us skip the mirror and try the next.
            guard let apiURL = URL(string: "\(mirror)/api/models/\(modelId)") else {
                AppLogger.services.warning("Skipping mirror — could not construct API URL", ["mirror": mirror, "modelId": modelId])
                continue
            }

            do {
                let (data, response) = try await URLSession.shared.data(from: apiURL)

                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                    continue
                }

                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let siblings = json["siblings"] as? [[String: Any]] else {
                    continue
                }

                let files = siblings.compactMap { sibling -> HFModelFile? in
                    guard let name = sibling["rfilename"] as? String else { return nil }
                    // Security: filter out any filenames that would escape the cache directory.
                    // Malicious or compromised API responses could include path traversal sequences.
                    guard isSafeModelFilename(name) else {
                        AppLogger.services.warning("Skipping unsafe filename in model manifest", ["filename": name])
                        return nil
                    }
                    let size = sibling["size"] as? Int
                    // Security: extract SHA-256 from LFS metadata if present.
                    let sha256 = (sibling["lfs"] as? [String: Any])?["sha256"] as? String
                    return HFModelFile(name: name, size: size, sha256: sha256)
                }

                if !files.isEmpty {
                    AppLogger.services.info("Fetched model file list", [
                        "mirror": mirror,
                        "files": "\(files.count)"
                    ])
                    return files
                }
            } catch {
                AppLogger.services.warning("Failed to fetch file list from mirror", [
                    "mirror": mirror,
                    "error": error.localizedDescription
                ])
                continue
            }
        }

        throw ModelDownloadError(
            kind: .unknown("Could not fetch model file list from any mirror"),
            underlyingError: nil
        )
    }

    /// Download a single file with mirror fallback and retry.
    /// - Parameters:
    ///   - modelId: HuggingFace model identifier
    ///   - filename: Filename within the model repository (pre-validated by isSafeModelFilename)
    ///   - destination: Local destination URL
    ///   - expectedSHA256: SHA-256 hex digest from the HuggingFace API manifest (optional).
    ///     Security: when provided, the downloaded file is verified against this digest before being
    ///     moved to its destination. This prevents a compromised third-party mirror (hf-mirror.com)
    ///     from silently serving malicious model weights in place of the genuine files.
    static func downloadFileWithMirrorFallback(
        modelId: String,
        filename: String,
        destination: URL,
        expectedSHA256: String? = nil
    ) async throws {
        // Security: validate modelId against an allowlist before interpolating into URLs.
        // Mirrors this check in fetchModelFileList — defense-in-depth for callers that
        // invoke downloadFileWithMirrorFallback directly.
        guard isSafeModelId(modelId) else {
            throw ModelDownloadError(
                kind: .unknown("Invalid model ID '\(modelId)' — must match namespace/model-name format"),
                underlyingError: nil
            )
        }
        for mirror in mirrors {
            // Security: use safe URL construction — force-unwrap would crash if filename contained
            // URL-unsafe characters (e.g., spaces) not caught by isSafeModelFilename. Skip
            // this mirror and try the next rather than crashing.
            guard let fileURL = URL(string: "\(mirror)/\(modelId)/resolve/main/\(filename)") else {
                AppLogger.services.warning("Skipping mirror — could not construct file URL", ["mirror": mirror, "file": filename])
                continue
            }

            do {
                try await withRetry(maxAttempts: 2) {
                    let (tempURL, response) = try await URLSession.shared.download(from: fileURL)

                    if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                        throw ModelDownloadError(
                            kind: .serverError(statusCode: httpResponse.statusCode),
                            underlyingError: nil
                        )
                    }

                    // Security: verify SHA-256 digest of downloaded file when the API manifest
                    // provided one. Rejects files where the digest does not match — a compromised
                    // mirror cannot substitute malicious model weights without detection.
                    if let expected = expectedSHA256 {
                        let computed = try sha256Hex(of: tempURL)
                        guard computed.lowercased() == expected.lowercased() else {
                            try? FileManager.default.removeItem(at: tempURL)
                            AppLogger.services.error("SHA-256 mismatch for downloaded model file — rejecting", [
                                "file": filename,
                                "mirror": mirror,
                                "expected": expected,
                                "actual": computed
                            ])
                            throw ModelDownloadError(
                                kind: .unknown("Integrity check failed for \(filename) — digest mismatch"),
                                underlyingError: nil
                            )
                        }
                    }

                    // Move to destination
                    try FileManager.default.moveItem(at: tempURL, to: destination)

                    // Security: restrict model files to owner-only read (0o600).
                    FileManager.default.restrictToOwnerOnly(atPath: destination.path)
                }

                AppLogger.services.debug("Downloaded \(filename) from \(mirror)")
                return
            } catch {
                AppLogger.services.warning("Mirror download failed", [
                    "mirror": mirror,
                    "file": filename,
                    "error": error.localizedDescription
                ])
                // Clean up partial file
                try? FileManager.default.removeItem(at: destination)
                continue
            }
        }

        throw ModelDownloadError(
            kind: .unknown("Failed to download \(filename) from all mirrors"),
            underlyingError: nil
        )
    }

    /// Compute the SHA-256 hex digest of a file by streaming it in chunks.
    /// Security: avoids loading large model files (potentially several GB) entirely into memory.
    /// A naive Data(contentsOf:) call could exhaust RAM and crash the app before the integrity
    /// check completes, letting a compromised mirror bypass SHA-256 verification by serving an
    /// oversized file. Streaming caps peak memory at one chunk (1MB) regardless of file size.
    static func sha256Hex(of url: URL) throws -> String {
        let fileHandle = try FileHandle(forReadingFrom: url)
        defer { try? fileHandle.close() }
        var hasher = CryptoKit.SHA256()
        let chunkSize = 1024 * 1024 // 1MB chunks — large enough for throughput, small enough for memory safety
        while true {
            guard let chunk = try fileHandle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
