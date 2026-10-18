// ModelDownloadService.swift
// Retry logic and error classification for FluidAudio model initialization.

import Foundation

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

    /// Default retry configuration
    public static let maxRetries = 3
    private static let retryDelays: [UInt64] = [2_000_000_000, 5_000_000_000, 10_000_000_000] // 2s, 5s, 10s

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
}
