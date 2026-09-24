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
// 1. A window title that only exists during a call (a Meet tab, the Zoom web
//    client, a Teams meeting window), in any window of that browser
//    -> prompt right away, named after the provider. Sticky for the session.
// 2. The focused window is a known non-call site (ChatGPT, Claude, Loom...)
//    -> no prompt for this browser mic session, even after the user clicks
//    to another tab. Only a title from step 1 can still win.
// 3. The focused window is a call app whose title does not prove a call is
//    on (Teams chat, a Slack huddle, WhatsApp, Discord) -> prompt after
//    `corroboratedDelay`, as the generic browser call.
// 4. The browser is also playing audio, or the camera is on -> prompt after
//    `corroboratedDelay` of continuous mic use.
// 5. Mic only -> prompt after `uncorroboratedDelay`.
//
// Known gap: the title of a window is its active tab. A Meet tab that sits
// behind a focused ChatGPT tab in the same window from the very first read
// is not seen until the user looks at it again. The first read happens a few
// seconds after joining, while the Meet tab is almost always in front.
//
// The camera only corroborates. PostHog (30 days to 2026-09-23, CI builds
// excluded) showed camera-on browser prompts were recorded 11% of the time vs
// 20% with the camera off, and only 48% of recorded browser calls had the
// camera on, so it is neither proof of a call nor needed for one.
//
// Window titles come from Accessibility, which Transcripted holds for
// paste-back when dictation is on. No new permission, and it is never asked
// for: without it there are no titles and only the timing rules apply.
// Titles are classified in memory and dropped: they are never logged, stored,
// or sent anywhere. Only the verdict enum leaves this file.

import Foundation

/// One browser window's title as read through Accessibility.
struct BrowserWindowTitle: Equatable {
    let title: String
    /// Whether this is the browser app's focused (key) window.
    let isFocused: Bool
}

/// What the browser window titles say about the current mic use.
enum BrowserCallTitleVerdict: Equatable {
    /// A window title that only exists while a call is on (a Meet tab, the
    /// Zoom web client, a Teams meeting). Proof enough to prompt now.
    case call(provider: MeetingPromptProvider)
    /// The focused window is a call app or site, but its title does not say a
    /// call is on (Teams chat, a Slack huddle, WhatsApp, Discord). Corroborates
    /// a browser mic; `provider` is set when the site maps to one of ours.
    case callSite(provider: MeetingPromptProvider?)
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
    /// A browser window title that only exists during a call names it (a
    /// Meet tab, the Zoom web client, a Teams meeting).
    case tabTitle = "tab_title"
    /// The focused browser window is a call app or site whose title does not
    /// prove a call is on (Teams chat, a Slack huddle, WhatsApp).
    case callSite = "call_site"
    /// A browser holds the mic (or is frontmost) while the camera is on.
    /// Corroboration only, not proof (see the header).
    case camera
    /// A browser holds the mic and is playing audio.
    case micAndOutput = "mic_and_output"
    /// A browser has held the mic for a while with nothing else to go on.
    case micOnly = "mic_only"
    /// The focused browser window is a known non-call site (ChatGPT voice,
    /// Loom). Only on `not_a_call` suppressions; it never prompts.
    case nonCallSite = "non_call_site"

    /// A browser call named by a title that only exists during a call.
    var isNamedBrowserCall: Bool {
        self == .tabTitle
    }

    /// Browser evidence that is only a guess from how long the mic was held
    /// and what else was going on. Includes the camera: it corroborates but
    /// does not prove a call (see `BrowserCallEvidence`).
    var isUnverifiedBrowserCall: Bool {
        self == .camera || self == .micAndOutput || self == .micOnly
    }

    /// Any browser prompt.
    var isBrowserCall: Bool {
        self == .tabTitle || self == .callSite || isUnverifiedBrowserCall
    }

    /// Whether a Not now to this prompt may quiet every prompt for its
    /// provider. Only when the provider is certain (a native app, a named
    /// call tab); otherwise a Not now to a guess would hide a real call.
    var quietsProviderOnDismiss: Bool {
        self == .none || self == .nativeApp || self == .tabTitle
    }
}

enum BrowserCallEvidence {
    // MARK: Timing

    /// How long a browser must hold the mic, while also playing audio, with
    /// the camera on, or with a call app focused, before it prompts. Long
    /// enough that voice search and short dictation never reach it; short
    /// enough that a real call still gets its prompt inside the first minute.
    static let corroboratedDelay: TimeInterval = 20
    /// How long a browser must hold the mic with nothing else to go on (no
    /// call title, no camera, no audio playing back).
    static let uncorroboratedDelay: TimeInterval = 60
    /// While a browser holds the mic and the titles have not named a call, the
    /// detector re-reads them this often, so switching to the Meet tab (or the
    /// wait running out) is noticed without waiting for the slow poll.
    static let titleRecheckInterval: TimeInterval = 15
    /// Re-read cadence once a session is known to be a non-call site. Only a
    /// named call tab can still change the answer, so there is no hurry.
    static let nonCallSiteRecheckInterval: TimeInterval = 60
    /// How long a browser can let go of the mic without ending its session.
    /// Safari releases the mic while a call is muted; each unmute must not
    /// restart the wait or forget the tab title.
    static let micReleaseGrace: TimeInterval = 30

    struct Timing: Equatable {
        var corroboratedDelay: TimeInterval
        var uncorroboratedDelay: TimeInterval
        var titleRecheckInterval: TimeInterval
        var nonCallSiteRecheckInterval: TimeInterval = BrowserCallEvidence.nonCallSiteRecheckInterval
        var micReleaseGrace: TimeInterval = BrowserCallEvidence.micReleaseGrace
        /// Minimum spacing between title reads within one browser session.
        /// Several sensor edges can land in the same second; one read answers
        /// all of them.
        var titleReadSpacing: TimeInterval = 2

        static let standard = Timing(
            corroboratedDelay: BrowserCallEvidence.corroboratedDelay,
            uncorroboratedDelay: BrowserCallEvidence.uncorroboratedDelay,
            titleRecheckInterval: BrowserCallEvidence.titleRecheckInterval
        )
    }

    // MARK: Decision

    enum Decision: Equatable {
        /// Offer the prompt now. `provider` is set when a title named the
        /// call (or the focused call site maps to one of ours); `nil` is the
        /// generic browser call.
        case prompt(provider: MeetingPromptProvider?, evidence: MeetingPromptCallEvidence)
        /// Not enough evidence yet; look again at `recheckAt`.
        case wait(recheckAt: Date)
        /// This mic use is not a call; stay quiet.
        case notACall
    }

    /// Decides what to do about a browser that has held the mic since
    /// `micSince` (the moment the monitor confirmed it). `verdict` is the
    /// session's verdict, with the sticky rules already applied by the caller.
    static func decide(
        verdict: BrowserCallTitleVerdict,
        cameraInUse: Bool,
        browserPlayingAudio: Bool,
        micSince: Date,
        now: Date,
        timing: Timing = .standard
    ) -> Decision {
        let evidence: MeetingPromptCallEvidence
        var provider: MeetingPromptProvider?
        switch verdict {
        case .call(let named):
            return .prompt(provider: named, evidence: .tabTitle)
        case .notCall:
            return .notACall
        case .callSite(let site):
            evidence = .callSite
            provider = site
        case .unknown:
            if browserPlayingAudio {
                evidence = .micAndOutput
            } else if cameraInUse {
                evidence = .camera
            } else {
                evidence = .micOnly
            }
        }

        let delay = evidence == .micOnly ? timing.uncorroboratedDelay : timing.corroboratedDelay
        let promptAt = micSince.addingTimeInterval(delay)
        if now >= promptAt {
            return .prompt(provider: provider, evidence: evidence)
        }
        // Re-read titles on the recheck cadence, but never later than the
        // moment the wait runs out.
        return .wait(recheckAt: min(promptAt, now.addingTimeInterval(timing.titleRecheckInterval)))
    }

    // MARK: Title classification

    /// Classifies the titles of every window of the browsers holding the mic.
    ///
    /// A title that only exists during a call wins from any window, because
    /// the call may sit in a window the user is not looking at. Everything
    /// else only counts from the focused window: a Teams chat or WhatsApp tab
    /// left open all day says nothing about who holds the mic right now.
    /// Mail and calendar windows are skipped outright, since an invite's
    /// subject ("Zoom meeting with Ana") reads like a call.
    static func classify(_ windows: [BrowserWindowTitle]) -> BrowserCallTitleVerdict {
        let readable = windows.filter { !isMailOrCalendarTitle(normalized($0.title)) }
        for window in readable {
            if let provider = inCallProvider(forTitle: window.title) {
                return .call(provider: provider)
            }
        }
        guard let focused = readable.first(where: \.isFocused) else { return .unknown }
        if isNonCallSite(title: focused.title) {
            return .notCall
        }
        if let site = callSite(forTitle: focused.title) {
            return .callSite(provider: site)
        }
        return .unknown
    }

    /// The provider when `rawTitle` only exists while a call is on, else `nil`.
    static func inCallProvider(forTitle rawTitle: String) -> MeetingPromptProvider? {
        let title = normalized(rawTitle)
        guard !title.isEmpty, !isMailOrCalendarTitle(title) else { return nil }
        if isGoogleMeetTitle(title) {
            return .googleMeet
        }
        // The Zoom web client's call window.
        if title.hasPrefix("zoom meeting") || title.hasPrefix("zoom webinar") {
            return .zoom
        }
        // Teams web names the window after the meeting or call itself.
        if title.contains("microsoft teams"),
           teamsInCallPrefixes.contains(where: { title.hasPrefix($0) }) {
            return .teams
        }
        return nil
    }

    /// `nil` when the title is not a call app or site; `.some(provider)` when
    /// it is, with the provider when we have one for it. Only meaningful for
    /// the focused window.
    static func callSite(forTitle rawTitle: String) -> MeetingPromptProvider?? {
        let title = normalized(rawTitle)
        guard !title.isEmpty, !isMailOrCalendarTitle(title) else { return nil }
        if title.contains("google meet") {
            return .some(.googleMeet)
        }
        if title.contains("microsoft teams") {
            return .some(.teams)
        }
        if title.hasPrefix("zoom") || title.contains("zoom workplace")
            || title.contains("| zoom") || title.contains("- zoom") {
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

    /// Meet tab titles in a call or its pre-join screen look like
    /// "Meet - abc-defg-hij" or "Meet – Weekly sync" (Chrome may append
    /// " - Google Chrome" and a profile name). A title that starts with a
    /// meeting code also counts. The code has to lead the title so a slug that
    /// happens to be 3-4-3 letters somewhere in a page title does not match.
    /// The Meet home page ("Google Meet") is often left open all day, so it is
    /// only a call site, not a call.
    private static func isGoogleMeetTitle(_ title: String) -> Bool {
        if title.hasPrefix("meet - ") || title.hasPrefix("meet: ") || title.hasPrefix("meet | ") {
            return true
        }
        return title.range(of: #"^[a-z]{3}-[a-z]{4}-[a-z]{3}($|[^a-z-])"#, options: .regularExpression) != nil
    }

    /// Teams web window titles during a meeting or call ("Meeting with Ana |
    /// Microsoft Teams", "Call with Sam | Microsoft Teams"). Chat, calendar
    /// and activity pages do not start this way.
    static let teamsInCallPrefixes: [String] = [
        "meeting with ",
        "meeting in ",
        "meeting now",
        "call with ",
        "call in progress",
    ]

    /// Mail and calendar pages: an invite's subject or event name can read
    /// like a call ("Zoom meeting with Ana - Gmail") without one going on.
    private static func isMailOrCalendarTitle(_ title: String) -> Bool {
        mailOrCalendarMarkers.contains { title.contains($0) }
    }

    static let mailOrCalendarMarkers: [String] = [
        "gmail",
        "outlook",
        "yahoo mail",
        "proton mail",
        "fastmail",
        "icloud mail",
        "inbox",
        "calendar",
    ]

    /// Call apps and sites with no in-call title we can trust. They
    /// corroborate a browser mic only while focused, and the prompt keeps the
    /// generic browser title.
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
    /// against the focused window. Pages people keep in front during a call
    /// (Google Docs for notes, YouTube) are deliberately not listed: a
    /// non-call verdict sticks for the session, so it has to be a site whose
    /// own mic use is the likely one.
    static let nonCallSiteMarkers: [String] = [
        "chatgpt",
        "claude",
        "gemini",
        "grok",
        "perplexity",
        "copilot",
        "loom",
        "otter.ai",
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
