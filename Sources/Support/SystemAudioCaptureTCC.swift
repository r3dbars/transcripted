import AppKit
import AVFoundation
import ApplicationServices
import CoreAudio
import Combine
import EventKit
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif

enum SystemAudioCaptureTCCStatus: String, Equatable, Sendable {
    case authorized
    case denied
    case notDetermined = "not_determined"
    /// macOS's permission API could not be loaded. Callers fall back to the
    /// tap probe and the in-recording signal check.
    case unavailable
}

/// Direct access to macOS's System Audio Recording decision
/// (`kTCCServiceAudioCapture`). Core Audio process taps have no public
/// permission query, so this uses TCC.framework's `TCCAccessPreflight` and
/// `TCCAccessRequest`. They are private symbols, loaded lazily; a missing
/// symbol reads as `.unavailable` so an OS change degrades to the old probe
/// instead of crashing or inventing an answer.
struct SystemAudioCaptureTCC: Sendable {
    let preflight: @Sendable () -> SystemAudioCaptureTCCStatus
    /// Shows the macOS allow box when the decision is open; returns the
    /// current answer without a box once it is decided. Nil = unavailable.
    let request: @Sendable () async -> Bool?

    static let live = SystemAudioCaptureTCC(
        preflight: { SystemAudioCaptureTCCSymbols.preflightStatus() },
        request: { await SystemAudioCaptureTCCSymbols.requestAccess() }
    )

    static let unavailable = SystemAudioCaptureTCC(preflight: { .unavailable }, request: { nil })
}

private enum SystemAudioCaptureTCCSymbols {
    typealias PreflightFunction = @convention(c) (CFString, CFDictionary?) -> Int32
    typealias RequestFunction = @convention(c) (
        CFString,
        CFDictionary?,
        @escaping @convention(block) (Bool) -> Void
    ) -> Void

    private static let service = "kTCCServiceAudioCapture" as CFString
    private static let symbols: (preflight: PreflightFunction?, request: RequestFunction?) = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW) else {
            return (nil, nil)
        }
        let preflight = dlsym(handle, "TCCAccessPreflight").map { unsafeBitCast($0, to: PreflightFunction.self) }
        let request = dlsym(handle, "TCCAccessRequest").map { unsafeBitCast($0, to: RequestFunction.self) }
        return (preflight, request)
    }()

    static func preflightStatus() -> SystemAudioCaptureTCCStatus {
        guard let preflight = symbols.preflight else { return .unavailable }
        switch preflight(service, nil) {
        case 0: return .authorized
        case 1: return .denied
        case 2: return .notDetermined
        default: return .unavailable
        }
    }

    static func requestAccess() async -> Bool? {
        guard let request = symbols.request else { return nil }
        return await withCheckedContinuation { continuation in
            // Private API: never trust it to call back exactly once.
            let resumed = NSLock()
            var didResume = false
            request(service, nil) { granted in
                resumed.lock()
                let shouldResume = !didResume
                didResume = true
                resumed.unlock()
                if shouldResume { continuation.resume(returning: granted) }
            }
        }
    }
}
