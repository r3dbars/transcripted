import Foundation

/// Whether a detected-call signal should auto-start recording, keep the
/// existing island prompt, or stay quiet.
///
/// Auto-start is opt-in and narrow: Zoom or Teams must really hold the mic,
/// or a focused Meet/Zoom/Teams tab must hold the mic (never a background
/// tab, a Meet lobby, or the camera). That evidence has to last a few
/// seconds, both capture permissions must already be on, and nothing else
/// may be recording. Every other detected call keeps today's prompt. Off
/// by default, so Record / Not now / Remind is unchanged until the
/// setting is on.
enum MeetingAutoRecordPolicy {
    /// How long proven evidence must last before auto-start. Prompting still
    /// happens at once when the setting is off.
    static let evidenceHoldDuration: TimeInterval = 3

    enum Decision: Equatable {
        /// Detector asked, but this start must stay quiet (reserved for
        /// callers that already own the mic).
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
        /// The call app or browser process is actually on the mic.
        var holdsMicrophone: Bool
        /// The named call is in the focused/front tab or window.
        var isFocusedFrontWindow: Bool
        /// Meet's pre-join / lobby screen, not an in-call tab.
        var isMeetPreJoin: Bool
        /// How long the auto-start evidence has been true.
        var evidenceAge: TimeInterval
    }

    static func decision(for request: Request) -> Decision {
        // Another capture must not auto-start. It must not swallow the
        // calendar prompt either: when the setting is off this matches main,
        // and when it is on an unproven (or calendar) candidate still asks.
        if request.autoRecordEnabled,
           isCallProven(request),
           request.microphoneGranted,
           request.systemAudioGranted,
           !request.otherCaptureActive {
            return .autoStart
        }
        return .prompt
    }

    /// Native Zoom or Teams holding the mic, or a focused in-call Meet /
    /// Zoom / Teams tab that has also held the mic for a few seconds.
    static func isCallProven(_ request: Request) -> Bool {
        guard request.holdsMicrophone else { return false }
        guard request.evidenceAge >= evidenceHoldDuration else { return false }
        switch request.evidence {
        case .nativeApp:
            return request.provider == .zoom || request.provider == .teams
        case .tabTitle:
            return request.isFocusedFrontWindow
                && !request.isMeetPreJoin
                && (request.provider == .zoom
                    || request.provider == .teams
                    || request.provider == .googleMeet)
        case .none, .callSite, .camera, .micAndOutput, .micOnly, .nonCallSite:
            return false
        }
    }

    /// Stop or Discard of an auto-started recording declines the rest of
    /// this call. A failed start or unexpected capture stop does not.
    static func recordsDeclineOnEnd(wasAutoStarted: Bool, userStoppedOrDiscarded: Bool) -> Bool {
        wasAutoStarted && userStoppedOrDiscarded
    }

    /// Setting is on and the call would auto-start once the evidence has
    /// been held long enough. The detector waits instead of prompting.
    static func shouldWaitForEvidenceHold(_ request: Request) -> Bool {
        guard request.autoRecordEnabled else { return false }
        guard request.evidenceAge < evidenceHoldDuration else { return false }
        var held = request
        held.evidenceAge = evidenceHoldDuration
        held.otherCaptureActive = false
        held.microphoneGranted = true
        held.systemAudioGranted = true
        return isCallProven(held)
    }
}
