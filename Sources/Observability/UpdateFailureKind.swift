import Foundation

enum UpdateFailureKind: String {
    case badAppcast = "bad_appcast"
    case checkTimedOut = "check_timed_out"
    case downloadFailed = "download_failed"
    case feedUnreachable = "feed_unreachable"
    case installFailed = "install_failed"
    case offline = "offline"
    case signatureFailed = "signature_failed"
    case sparkleBusy = "sparkle_busy"
    case unknown = "unknown"

    private static let sparkleErrorDomain = "SUSparkleErrorDomain"
    private static let sparkleNoUpdateErrorCode = 1001

    static func isNoUpdateFound(_ error: Error?) -> Bool {
        guard let error else { return false }

        let nsError = error as NSError
        return nsError.domain == sparkleErrorDomain
            && nsError.code == sparkleNoUpdateErrorCode
    }

    static func diagnosticCode(_ error: Error?) -> String? {
        guard let error else { return nil }

        let nsError = error as NSError
        let domain = nsError.domain.lowercased()
        let codePrefix: String

        switch nsError.domain {
        case NSURLErrorDomain:
            codePrefix = "url"
        case NSCocoaErrorDomain:
            codePrefix = "cocoa"
        case NSPOSIXErrorDomain:
            codePrefix = "posix"
        default:
            codePrefix = domain.contains("sparkle") ? "sparkle" : "other"
        }

        return "\(codePrefix)_\(nsError.code)"
    }

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
