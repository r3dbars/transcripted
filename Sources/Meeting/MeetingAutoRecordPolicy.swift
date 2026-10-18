import Foundation

/// Whether a detected-call signal should auto-start recording, keep the
/// existing island prompt, or stay quiet.
///
/// Auto-start is opt-in and narrow: a proven Zoom/Teams native mic hold or a
/// browser tab title that names Meet, Zoom, or Teams, with both capture
/// permissions already granted and nothing else recording. Every other
/// detected call keeps today's prompt. Off by default, so the current
/// Record / Not now / Remind flow is unchanged until the setting is on.
enum MeetingAutoRecordPolicy {
    enum Decision: Equatable {
        /// Detector asked, but another capture already owns the mic.
        case none
        /// Current behavior: show the island Record prompt.
        case prompt
        /// Start through the existing detected-prompt Record path.
        case autoStart
    }

    struct Request: Equatable {
        var autoRecordEnabled: Bool
        var evidence: MeetingPromptCallEvidence
        var provider: MeetingPromptProvider
        var reason: MeetingPromptReason
        var microphoneGranted: Bool
        var systemAudioGranted: Bool
        var otherCaptureActive: Bool
    }

    static func decision(for request: Request) -> Decision {
        if request.otherCaptureActive { return .none }
        if request.autoRecordEnabled,
           isCallProven(request),
           request.microphoneGranted,
           request.systemAudioGranted {
            return .autoStart
        }
        return .prompt
    }

    /// Native Zoom or Teams holding the mic, or a browser tab title that
    /// only exists during a Meet, Zoom, or Teams call.
    static func isCallProven(_ request: Request) -> Bool {
        switch request.evidence {
        case .nativeApp:
            return request.reason == .micInput
                && (request.provider == .zoom || request.provider == .teams)
        case .tabTitle:
            return request.provider == .zoom
                || request.provider == .teams
                || request.provider == .googleMeet
        case .none, .callSite, .camera, .micAndOutput, .micOnly, .nonCallSite:
            return false
        }
    }
}
