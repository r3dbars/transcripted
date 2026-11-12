import Foundation

/// Coarse reason a stopped dictation's recovery WAV could not be saved
/// (`dictation_stopped_audio_persistence_failed`). The store throws plain
/// Foundation errors (`CocoaError`, `POSIXError`, `EncodingError`) whose
/// descriptions carry file names, so Sentry gets only this code under
/// `persist_cause`. `SentryPayloadSanitizer` drops any other value under
/// that key.
enum StoppedAudioPersistCause: String, CaseIterable {
    case diskFull = "disk_full"
    case permissionDenied = "permission_denied"
    case missingSource = "missing_source"
    case encodeFailed = "encode_failed"
    case writeFailed = "write_failed"
    case other

    static let key = "persist_cause"

    static func classify(_ error: Error) -> StoppedAudioPersistCause {
        if error is EncodingError { return .encodeFailed }
        let nsError = error as NSError
        if let cause = cause(domain: nsError.domain, code: nsError.code) { return cause }
        // Foundation often wraps the POSIX errno that says what really went
        // wrong (ENOSPC behind a generic write failure, say).
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           let cause = cause(domain: underlying.domain, code: underlying.code),
           cause != .writeFailed {
            return cause
        }
        return nsError.domain == NSCocoaErrorDomain && isCocoaWriteCode(nsError.code) ? .writeFailed : .other
    }

    static func eventContext(for error: Error) -> [String: String] {
        [key: classify(error).rawValue]
    }

    /// Sanitizer gate: `persist_cause` only leaves the device as a known code.
    static func allows(key: String, value: Any) -> Bool {
        guard key == Self.key else { return true }
        guard let string = value as? String else { return false }
        return StoppedAudioPersistCause(rawValue: string) != nil
    }

    private static func cause(domain: String, code: Int) -> StoppedAudioPersistCause? {
        switch domain {
        case NSPOSIXErrorDomain:
            switch POSIXErrorCode(rawValue: Int32(truncatingIfNeeded: code)) {
            case .ENOSPC?, .EDQUOT?: return .diskFull
            case .EACCES?, .EPERM?, .EROFS?: return .permissionDenied
            case .ENOENT?, .ENOTDIR?: return .missingSource
            case nil: return .other
            default: return .writeFailed
            }
        case NSCocoaErrorDomain:
            switch CocoaError.Code(rawValue: code) {
            case .fileWriteOutOfSpace: return .diskFull
            case .fileWriteNoPermission, .fileReadNoPermission, .fileWriteVolumeReadOnly:
                return .permissionDenied
            case .fileNoSuchFile, .fileReadNoSuchFile: return .missingSource
            case .coderInvalidValue: return .encodeFailed
            default: return nil
            }
        default:
            return nil
        }
    }

    private static func isCocoaWriteCode(_ code: Int) -> Bool {
        // NSFileWriteErrorMinimum ... NSFileWriteErrorMaximum, plus locking.
        (512...1023).contains(code) || code == CocoaError.fileLocking.rawValue
    }
}
