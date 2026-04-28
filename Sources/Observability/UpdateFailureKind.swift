import Foundation

enum UpdateFailureKind: String {
    case badAppcast = "bad_appcast"
    case downloadFailed = "download_failed"
    case feedUnreachable = "feed_unreachable"
    case installFailed = "install_failed"
    case offline = "offline"
    case signatureFailed = "signature_failed"
    case sparkleBusy = "sparkle_busy"
    case unknown = "unknown"

    static func classify(_ error: Error?, fallback: UpdateFailureKind = .unknown) -> UpdateFailureKind {
        guard let error else { return fallback }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorNotConnectedToInternet,
                 NSURLErrorInternationalRoamingOff,
                 NSURLErrorDataNotAllowed:
                return .offline
            case NSURLErrorTimedOut,
                 NSURLErrorCannotFindHost,
                 NSURLErrorCannotConnectToHost,
                 NSURLErrorDNSLookupFailed,
                 NSURLErrorNetworkConnectionLost,
                 NSURLErrorResourceUnavailable,
                 NSURLErrorBadServerResponse:
                return .feedUnreachable
            default:
                break
            }
        }

        let haystack = [
            nsError.domain,
            nsError.localizedDescription,
            nsError.localizedFailureReason,
            nsError.localizedRecoverySuggestion,
        ]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()

        if haystack.contains("signature")
            || haystack.contains("ed25519")
            || haystack.contains("edsa")
            || haystack.contains("dsa") {
            return .signatureFailed
        }

        if haystack.contains("appcast")
            || haystack.contains("xml")
            || haystack.contains("parse") {
            return .badAppcast
        }

        if haystack.contains("download") {
            return .downloadFailed
        }

        if haystack.contains("install")
            || haystack.contains("relaunch")
            || haystack.contains("restart") {
            return .installFailed
        }

        if haystack.contains("session")
            || haystack.contains("busy")
            || haystack.contains("in progress") {
            return .sparkleBusy
        }

        return fallback
    }
}
