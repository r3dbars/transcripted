// BrowserCallEvidence.swift
// Pure "is this browser mic use really a call?" policy for the detected-call
// prompt. Foundation only, so the fast-test runner can pin every rule.
//
// Why this exists: MicActivityMonitor can only say *which process* holds the
// mic, and for a browser that is a shared helper (`com.google.Chrome.helper`,
// `com.apple.WebKit.GPU`). Every browser mic user used to become a Google Meet
// call, so ChatGPT or Claude voice, web dictation, Loom and voice search all
// raised "Call detected in your browser". In 30 days that prompt was dismissed
// far more often than it was used (customers/pain-points.md #4).
//
// The evidence ladder, strongest first:
// 1. A browser window title names a call surface (a Meet tab, Teams, Zoom web)
//    -> prompt right away, named after the provider.
// 2. The focused browser window is a known non-call site (ChatGPT, Loom...)
//    -> never prompt for this mic session.
// 3. The browser is also playing audio, or the camera is on -> prompt after
//    `corroboratedDelay` of continuous mic use.
// 4. Mic only -> prompt after `uncorroboratedDelay`.
//
// The camera only corroborates. PostHog (30 days to 2026-09-23, CI builds
// excluded) showed camera-on browser prompts were recorded 11% of the time vs
// 20% with the camera off, and only 48% of recorded browser calls had the
// camera on, so it is neither proof of a call nor needed for one.
//
// Window titles come from Accessibility, which Transcripted already holds for
// paste-back. No new permission. Titles are classified in memory and dropped:
// they are never logged, stored, or sent anywhere. Only the verdict enum
// leaves this file.

import Foundation

/// One browser window's title as read through Accessibility.
struct BrowserWindowTitle: Equatable {
    let title: String
    /// Whether this is the browser app's focused (key) window.
    let isFocused: Bool
}

/// What the browser window titles say about the current mic use.
enum BrowserCallTitleVerdict: Equatable {
    /// A window title names a call surface. `provider` is set when the surface
    /// maps to one of our providers (Meet, Teams, Zoom, Webex, FaceTime).
    case call(provider: MeetingPromptProvider?)
    /// The focused window is a site that uses the mic for something that is
    /// not a call (voice assistants, screen recorders, dictation).
    case notCall
    /// Nothing recognizable, or no titles (Accessibility off, no windows).
    case unknown
}

/// How strong the evidence behind an ad-hoc prompt is. Coarse enum only; it is
/// the `call_evidence` analytics property.
enum MeetingPromptCallEvidence: String, Equatable {
    /// Not an ad-hoc browser decision (calendar prompts, runtime prompts).
    case none
    /// A native conferencing app (Zoom, Teams, FaceTime, Webex) is the source.
    case nativeApp = "native_app"
    /// A browser window title names a call surface we have a provider for
    /// (a Meet, Teams, Zoom, Webex, or FaceTime tab).
    case tabTitle = "tab_title"
    /// A browser window title names a call surface without a provider of its
    /// own (a Slack huddle, Whereby, Jitsi).
    case callSite = "call_site"
    /// A browser holds the mic (or is frontmost) while the camera is on.
    /// Corroboration only, not proof (see the header).
    case camera
    /// A browser holds the mic and is playing audio.
    case micAndOutput = "mic_and_output"
    /// A browser has held the mic for a while with nothing else to go on.
    case micOnly = "mic_only"

    /// Browser evidence strong enough to name the call and skip the wait.
    var isVerifiedBrowserCall: Bool {
        self == .tabTitle || self == .callSite
    }

    /// Browser evidence that is only a guess from how long the mic was held
    /// and what else was going on.
    var isUnverifiedBrowserCall: Bool {
        self == .camera || self == .micAndOutput || self == .micOnly
    }

    var isBrowserCall: Bool {
        isVerifiedBrowserCall || isUnverifiedBrowserCall
    }
}

enum BrowserCallEvidence {
    // MARK: Timing

    /// How long a browser must hold the mic, while also playing audio or with
    /// the camera on, before an unrecognized site prompts. Long enough that voice search and short
    /// dictation never reach it; short enough that a real call still gets its
    /// prompt inside the first minute.
    static let corroboratedDelay: TimeInterval = 20
    /// How long a browser must hold the mic with nothing else to go on (no
    /// call title, no camera, no audio playing back).
    static let uncorroboratedDelay: TimeInterval = 60
    /// While a browser holds the mic and the titles have not named a call, the
    /// detector re-reads them this often, so switching to the Meet tab (or the
    /// wait running out) is noticed without waiting for the slow poll.
    static let titleRecheckInterval: TimeInterval = 15

    struct Timing: Equatable {
        var corroboratedDelay: TimeInterval
        var uncorroboratedDelay: TimeInterval
        var titleRecheckInterval: TimeInterval

        static let standard = Timing(
            corroboratedDelay: BrowserCallEvidence.corroboratedDelay,
            uncorroboratedDelay: BrowserCallEvidence.uncorroboratedDelay,
            titleRecheckInterval: BrowserCallEvidence.titleRecheckInterval
        )
    }

    // MARK: Decision

    enum Decision: Equatable {
        /// Offer the prompt now. `provider` is set only when a tab title named
        /// the call surface; `nil` is the generic browser call.
        case prompt(provider: MeetingPromptProvider?, evidence: MeetingPromptCallEvidence)
        /// Not enough evidence yet; look again at `recheckAt`.
        case wait(recheckAt: Date)
        /// This mic use is not a call; stay quiet.
        case notACall
    }

    /// Decides what to do about a browser that has held the mic since
    /// `micSince` (the moment the monitor confirmed it).
    static func decide(
        verdict: BrowserCallTitleVerdict,
        cameraInUse: Bool,
        browserPlayingAudio: Bool,
        micSince: Date,
        now: Date,
        timing: Timing = .standard
    ) -> Decision {
        switch verdict {
        case .call(let provider):
            return .prompt(provider: provider, evidence: provider == nil ? .callSite : .tabTitle)
        case .notCall:
            return .notACall
        case .unknown:
            break
        }

        let evidence: MeetingPromptCallEvidence
        if browserPlayingAudio {
            evidence = .micAndOutput
        } else if cameraInUse {
            evidence = .camera
        } else {
            evidence = .micOnly
        }
        let delay = evidence == .micOnly ? timing.uncorroboratedDelay : timing.corroboratedDelay
        let promptAt = micSince.addingTimeInterval(delay)
        if now >= promptAt {
            return .prompt(provider: nil, evidence: evidence)
        }
        // Re-read titles on the recheck cadence, but never later than the
        // moment the wait runs out.
        return .wait(recheckAt: min(promptAt, now.addingTimeInterval(timing.titleRecheckInterval)))
    }

    // MARK: Title classification

    /// Classifies the titles of every window of the browsers holding the mic.
    /// Any window naming a call wins, because the call tab may sit in a
    /// window the user is not looking at. A non-call site only counts when it
    /// is the focused window, since that is where the mic use most likely is.
    static func classify(_ windows: [BrowserWindowTitle]) -> BrowserCallTitleVerdict {
        var sawCallWithoutProvider = false
        for window in windows {
            switch callSurface(forTitle: window.title) {
            case .some(.some(let provider)):
                return .call(provider: provider)
            case .some(.none):
                sawCallWithoutProvider = true
            case .none:
                continue
            }
        }
        if sawCallWithoutProvider {
            return .call(provider: nil)
        }
        if windows.contains(where: { $0.isFocused && isNonCallSite(title: $0.title) }) {
            return .notCall
        }
        return .unknown
    }

    /// `nil` when the title is not a call surface; `.some(provider)` when it
    /// is, with the provider when we have one for it.
    static func callSurface(forTitle rawTitle: String) -> MeetingPromptProvider?? {
        let title = normalized(rawTitle)
        guard !title.isEmpty else { return nil }

        if isGoogleMeetTitle(title) {
            return .some(.googleMeet)
        }
        if title.contains("microsoft teams") {
            return .some(.teams)
        }
        if title.contains("zoom meeting") || title.contains("zoom webinar")
            || title.contains("zoom workplace") || title == "zoom"
            || title.hasPrefix("zoom - ") || title.hasPrefix("zoom | ") {
            return .some(.zoom)
        }
        if title.contains("webex") {
            return .some(.webex)
        }
        if title.contains("facetime") {
            return .some(.facetime)
        }
        if otherCallSurfaceMarkers.contains(where: { title.contains($0) }) {
            return .some(nil)
        }
        return nil
    }

    static func isNonCallSite(title rawTitle: String) -> Bool {
        let title = normalized(rawTitle)
        guard !title.isEmpty else { return false }
        return nonCallSiteMarkers.contains { title.contains($0) }
    }

    /// Meet tab titles look like "Meet - abc-defg-hij" or "Meet – Weekly sync"
    /// (Chrome may append " - Google Chrome" and a profile name). The pre-join
    /// and lobby pages say "Google Meet". A title that starts with a meeting
    /// code also counts. The code has to lead the title so a slug that happens
    /// to be 3-4-3 letters somewhere in a page title does not match.
    private static func isGoogleMeetTitle(_ title: String) -> Bool {
        if title.contains("google meet") { return true }
        if title.hasPrefix("meet - ") || title.hasPrefix("meet: ") || title.hasPrefix("meet | ") {
            return true
        }
        return title.range(of: #"^[a-z]{3}-[a-z]{4}-[a-z]{3}($|[^a-z-])"#, options: .regularExpression) != nil
    }

    /// Browser call surfaces that have no provider of their own. They still
    /// count as a real call, so the prompt keeps the generic browser title.
    static let otherCallSurfaceMarkers: [String] = [
        "huddle",            // Slack huddles in the browser
        "whereby",
        "jitsi meet",
        "discord",
        "gather",
        "riverside",
        "streamyard",
        "goto meeting",
        "gotomeeting",
        "ringcentral",
        "bluejeans",
        "amazon chime",
        "zoho meeting",
        "livestorm",
        "skype",
        "whatsapp",
        "messenger call",
        "video call",
    ]

    /// Sites that hold the mic for something other than a call. Matched only
    /// against the focused window.
    static let nonCallSiteMarkers: [String] = [
        "chatgpt",
        "claude",
        "gemini",
        "grok",
        "perplexity",
        "copilot",
        "loom",
        "otter.ai",
        "google docs",       // voice typing
        "google search",     // voice search
        "youtube",
        "duolingo",
        "character.ai",
        "elevenlabs",
        "speechify",
        "dictation",
        "speech to text",
        "voice recorder",
        "online mic test",
        "mic test",
        "microphone test",
    ]

    private static func normalized(_ title: String) -> String {
        let lowered = title
            .replacingOccurrences(of: "\u{2013}", with: "-") // en dash
            .replacingOccurrences(of: "\u{2014}", with: "-") // em dash
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        // Drop a leading unread badge such as "(3) " so prefix rules still see
        // the page's own title.
        return lowered.replacingOccurrences(
            of: #"^\(\d+\)\s*"#,
            with: "",
            options: .regularExpression
        )
    }
}
