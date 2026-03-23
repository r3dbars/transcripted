// ModelDownloadService.swift
// Resilient model download with HuggingFace mirror fallback, retry logic,
// and error classification. Provides pre-population for Qwen cache and
// retry wrapping for FluidAudio model initialization.

import Foundation
import Network

// MARK: - Error Classification

/// Categorizes download errors for user-friendly messaging
enum DownloadErrorKind: Equatable {
    case networkOffline
    case tlsFailure
    case timeout
    case diskSpace
    case serverError(statusCode: Int)
    case unknown(String)

    var title: String {
        switch self {
        case .networkOffline: return "No Internet Connection"
        case .tlsFailure: return "Secure Connection Failed"
        case .timeout: return "Download Timed Out"
        case .diskSpace: return "Not Enough Disk Space"
        case .serverError: return "Server Error"
        case .unknown: return "Download Failed"
        }
    }

    var detail: String {
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
struct ModelDownloadError: Error, LocalizedError {
    let kind: DownloadErrorKind
    let underlyingError: Error?

    var errorDescription: String? {
        kind.detail
    }
}

// MARK: - Download Service

enum ModelDownloadService {

    /// HuggingFace mirror URLs, tried in order
    private static let mirrors: [String] = [
        "https://huggingface.co",
        "https://hf-mirror.com"
    ]

    /// Default retry configuration
    private static let maxRetries = 3
    private static let retryDelays: [UInt64] = [2_000_000_000, 5_000_000_000, 10_000_000_000] // 2s, 5s, 10s

    // MARK: - Network Reachability

    /// Quick network connectivity check using NWPathMonitor.
    /// Returns true if any network path is available.
    static func checkNetworkReachability() async -> Bool {
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
    static func classifyError(_ error: Error) -> DownloadErrorKind {
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
    static func availableDiskSpace() -> UInt64? {
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
    static func withRetry<T>(
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

        // All retries exhausted
        let kind = classifyError(lastError!)
        throw ModelDownloadError(kind: kind, underlyingError: lastError)
    }

    // MARK: - Qwen Pre-Population

    /// Pre-populate the Qwen model cache by downloading files directly from HuggingFace
    /// with mirror fallback. If cache already exists, skips download.
    ///
    /// mlx-swift-lm stores models at ~/Library/Caches/models/{org}/{model}/
    /// If files exist there, loadModelContainer() skips its own download.
    static func prePopulateQwenCache(
        modelId: String = "mlx-community/Qwen3.5-4B-4bit",
        progressHandler: ((Double) -> Void)? = nil
    ) async throws {
        let cacheDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/models")
            .appendingPathComponent(modelId)

        // If cache directory already has files, skip
        if FileManager.default.fileExists(atPath: cacheDir.path) {
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: cacheDir.path)) ?? []
            if !contents.isEmpty {
                AppLogger.services.info("Qwen cache already populated, skipping pre-download", [
                    "path": cacheDir.path,
                    "files": "\(contents.count)"
                ])
                return
            }
        }

        // Check disk space (~2.5GB needed)
        if let available = availableDiskSpace(), available < 3_000_000_000 {
            throw ModelDownloadError(kind: .diskSpace, underlyingError: nil)
        }

        // Check network first
        guard await checkNetworkReachability() else {
            throw ModelDownloadError(kind: .networkOffline, underlyingError: nil)
        }

        // Fetch file manifest from HuggingFace API
        let fileList = try await fetchModelFileList(modelId: modelId)

        AppLogger.services.info("Qwen pre-population starting", [
            "files": "\(fileList.count)",
            "modelId": modelId
        ])

        // Create cache directory
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        // Download each file with mirror fallback
        var downloadedCount = 0
        for file in fileList {
            // Security: validate filename from external API before constructing a path with it.
            // Rejects path traversal sequences (e.g. "../../.ssh") injected by a malicious server.
            guard isSafeModelFilename(file.name) else {
                AppLogger.services.error("Rejecting unsafe model filename from API response", ["filename": file.name])
                throw ModelDownloadError(kind: .unknown("Unsafe filename in model file list: \(file.name)"), underlyingError: nil)
            }

            let destURL = cacheDir.appendingPathComponent(file.name)

            // Skip if already downloaded
            if FileManager.default.fileExists(atPath: destURL.path) {
                downloadedCount += 1
                progressHandler?(Double(downloadedCount) / Double(fileList.count))
                continue
            }

            try await downloadFileWithMirrorFallback(
                modelId: modelId,
                filename: file.name,
                destination: destURL
            )

            downloadedCount += 1
            progressHandler?(Double(downloadedCount) / Double(fileList.count))
        }

        AppLogger.services.info("Qwen pre-population complete", ["path": cacheDir.path])
    }

    /// Represents a file in a HuggingFace model repository
    private struct HFModelFile {
        let name: String
        let size: Int?
    }

    /// Validate a filename returned by the HuggingFace API before using it in a file path.
    /// Security: filenames are attacker-controlled data from an external API response.
    /// A compromised or impersonated server could inject path traversal sequences (e.g. "../../../.ssh/authorized_keys")
    /// into rfilename values. We reject any name containing ".." components or absolute paths.
    private static func isSafeModelFilename(_ name: String) -> Bool {
        // Reject empty names
        guard !name.isEmpty else { return false }
        // Reject absolute paths
        guard !name.hasPrefix("/") else { return false }
        // Reject names containing ".." path traversal components
        let components = name.components(separatedBy: "/")
        guard !components.contains("..") && !components.contains(".") else { return false }
        // Reject names with null bytes or control characters
        guard !name.unicodeScalars.contains(where: { $0.value < 32 }) else { return false }
        return true
    }

    /// Fetch the list of files in a HuggingFace model repository
    private static func fetchModelFileList(modelId: String) async throws -> [HFModelFile] {
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
                    return HFModelFile(name: name, size: size)
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

    /// Download a single file with mirror fallback and retry
    private static func downloadFileWithMirrorFallback(
        modelId: String,
        filename: String,
        destination: URL
    ) async throws {
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

                    // Move to destination
                    try FileManager.default.moveItem(at: tempURL, to: destination)
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
}
