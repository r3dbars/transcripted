import Foundation

enum UpdateFailureKind: String {
    case badAppcast = "bad_appcast"
    case checkTimedOut = "check_timed_out"
    case downloadFailed = "download_failed"
    case feedUnreachable = "feed_unreachable"
    case installFailed = "install_failed"
    case offline = "offline"
    /// Sparkle refuses to update an app launched from its mounted DMG
    /// (`SURunningFromDiskImageError`). The user has to drag the app to
    /// Applications first; no retry will help.
    case runningFromDiskImage = "running_from_disk_image"
    case signatureFailed = "signature_failed"
    case sparkleBusy = "sparkle_busy"
    case unknown = "unknown"

    /// Sparkle error codes (`SUErrors.h`) that carry a stable meaning without
    /// parsing localized text. Download-phase codes are handled after the
    /// underlying `NSURLError` check so a network cause keeps its own kind.
    private static let sparkleCodeKinds: [Int: UpdateFailureKind] = [
        1000: .badAppcast,          // SUAppcastParseError
        1002: .badAppcast,          // SUAppcastError
        1003: .runningFromDiskImage, // SURunningFromDiskImageError
        1004: .badAppcast,          // SUResumeAppcastError
        1005: .installFailed,       // SURunningTranslocated
        2000: .downloadFailed,      // SUTemporaryDirectoryError
        2001: .downloadFailed,      // SUDownloadError
        3000: .installFailed,       // SUUnarchivingError
        3001: .signatureFailed,     // SUSignatureError
        3002: .signatureFailed,     // SUValidationError
        4000: .installFailed,       // SUFileCopyFailure
        4001: .installFailed,       // SUAuthenticationFailure
        4002: .installFailed,       // SUMissingUpdateError
        4003: .installFailed,       // SUMissingInstallerToolError
        4004: .installFailed,       // SURelaunchError
        4005: .installFailed,       // SUInstallationError
        4006: .installFailed,       // SUDowngradeError
        4008: .installFailed,       // SUInstallationAuthorizeLaterError
        4009: .installFailed,       // SUNotValidUpdateError
        4010: .installFailed,       // SUAgentInvalidationError
        4012: .installFailed,       // SUInstallationWriteNoPermissionError
    ]

    static func isNoUpdate(_ error: Error?) -> Bool {
        guard let error else { return false }

        let nsError = error as NSError
        return nsError.domain.lowercased().contains("sparkle")
            && nsError.code == 1001
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
        // Sparkle wraps the appcast fetch in `SUDownloadError` (2001) and
        // puts the real `NSURLError` under `NSUnderlyingErrorKey`; a top-level
        // domain check alone reported those as `unknown` for 31 users in one
        // month. Walk the chain so an offline or unreachable feed keeps its
        // own kind wherever Sparkle nested it.
        for candidate in errorChain(startingAt: nsError) where candidate.domain == NSURLErrorDomain {
            switch candidate.code {
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
                 NSURLErrorBadServerResponse,
                 NSURLErrorSecureConnectionFailed,
                 NSURLErrorCannotLoadFromNetwork:
                return .feedUnreachable
            default:
                break
            }
        }

        if let textKind = classifyFromLocalizedText(nsError) {
            return textKind
        }

        for candidate in errorChain(startingAt: nsError)
        where candidate.domain.lowercased().contains("sparkle") {
            if let codeKind = sparkleCodeKinds[candidate.code] {
                return codeKind
            }
        }

        return fallback
    }

    /// The error plus its `NSUnderlyingErrorKey` chain, bounded so a
    /// self-referential userInfo cannot loop.
    private static func errorChain(startingAt root: NSError) -> [NSError] {
        var chain: [NSError] = []
        var current: NSError? = root
        while let error = current, chain.count < 6 {
            chain.append(error)
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return chain
    }

    private static func classifyFromLocalizedText(_ nsError: NSError) -> UpdateFailureKind? {
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

        return nil
    }
}
