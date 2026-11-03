// CallSpeakerApp.swift
// Which call apps the speaker reader understands, which running apps can host
// them, and which of their windows is a meeting. Pure functions over bundle
// IDs and window titles, so the matcher is tested without a running app.
//
// Provenance: title rules marked "unverified" are not yet checked against
// live windows.
//
// Privacy: window titles carry meeting names. Match them in memory and drop
// them; never log them.

import Foundation

enum CallSpeakerApp: String, Sendable, CaseIterable {
    case zoom
    case teamsDesktop
    case slack
    case browserMeet
    case browserTeams
    case browserZoom

    static let zoomBundleIDs = ["us.zoom.xos"]
    static let teamsDesktopBundleIDs = ["com.microsoft.teams2", "com.microsoft.teams"]
    static let slackBundleIDs = ["com.tinyspeck.slackmacgap"]

    var isTeams: Bool { self == .teamsDesktop || self == .browserTeams }

    /// Whether this app's parser can tell the local user's own tile from
    /// everyone else's. Slack huddle tiles carry no known self marker (none
    /// is known; only a "(you)" name tag, if Slack ever shows one,
    /// is caught by the name cleaner), so its roster always includes the
    /// user. Roster observations alone never name a voice in Core.
    var detectsSelf: Bool { self != .slack }

    /// The kind of running app a window belongs to, before its title says
    /// whether it is a meeting.
    enum Host: Sendable, Equatable {
        case zoom
        case teamsDesktop
        case slack
        case browser
    }

    /// The host for a running app's bundle ID, or nil when no supported call
    /// can live in it. Exact app IDs only: helper processes own no windows.
    static func host(forBundleID bundleID: String) -> Host? {
        if zoomBundleIDs.contains(bundleID) { return .zoom }
        if teamsDesktopBundleIDs.contains(bundleID) { return .teamsDesktop }
        if slackBundleIDs.contains(bundleID) { return .slack }
        if browserAppFamilies.contains(where: { bundleID.matchesBundleFamily($0) }),
           !bundleID.lowercased().contains(".helper") {
            return .browser
        }
        return nil
    }

    /// Browser app families whose windows can show a web call. Safari's
    /// audio family (`com.apple.WebKit`) maps to Safari's own app family.
    static var browserAppFamilies: Set<String> {
        Set(MeetingPromptProvider.browserBundleIDPrefixes.map(MeetingPromptProvider.browserAppFamily(forBundleFamily:)))
    }

    /// Chromium and Electron apps build their Accessibility tree only when a
    /// screen reader asks, or when `AXManualAccessibility` is set on the app.
    static func needsManualAccessibility(bundleID: String) -> Bool {
        let families = [
            "com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser",
            "company.thebrowser.Browser",
        ]
        if families.contains(where: { bundleID.matchesBundleFamily($0) }) { return true }
        return teamsDesktopBundleIDs.contains(bundleID) || slackBundleIDs.contains(bundleID)
    }
}

/// One meeting window the matcher recognized. `meetingKey` tells windows of
/// the same meeting (Zoom's main and floating windows, Teams' compact view)
/// from windows of different meetings.
struct CallSpeakerWindowMatch: Equatable, Sendable {
    let app: CallSpeakerApp
    let meetingKey: String
    /// Teams' "Meeting compact view | ..." window. When exactly one is open,
    /// it alone is read (unverified Teams window gate).
    var isCompactView = false
}

enum CallSpeakerWindowMatcher {
    /// Suffixes browsers add to a tab's title. Everything from the first one
    /// on is dropped (a Chrome profile name can follow " - Google Chrome").
    static let browserTitleSuffixes = [
        " - Camera and microphone recording",
        " - Microphone recording",
        " - Camera recording",
        " - Google Chrome",
        " - Microsoft Edge",
        " - Mozilla Firefox",
        " - Brave",
        " - Arc",
    ]

    /// Unverified, matches the spec: `^meet - [a-z]{3}-[a-z]{4}-[a-z]{3}(?= |$)` on the
    /// lowercased, suffix-stripped title (en and em dashes accepted too).
    private static let meetCodePattern = try! NSRegularExpression(
        pattern: "^meet\\s*[-\u{2013}\u{2014}]\\s*([a-z]{3}-[a-z]{4}-[a-z]{3})(?= |$)",
        options: [.caseInsensitive]
    )
    private static let meetTitlePrefixPattern = try! NSRegularExpression(
        pattern: "^meet\\s*[-\u{2013}\u{2014}]\\s+\\S",
        options: [.caseInsensitive]
    )
    private static let unreadCountPrefixPattern = try! NSRegularExpression(
        pattern: "^\\(\\d+\\)\\s*",
        options: []
    )

    /// Whether a window of `host` titled `title` is a meeting the reader
    /// should walk, and which meeting.
    static func match(title rawTitle: String, host: CallSpeakerApp.Host) -> CallSpeakerWindowMatch? {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        switch host {
        case .slack:
            // A huddle can show in any Slack window (unverified;
            // every Slack window is scanned for huddle tiles), so every window is a
            // candidate; windows without tiles don't count.
            return CallSpeakerWindowMatch(app: .slack, meetingKey: "slack")
        case .zoom:
            guard !title.isEmpty else { return nil }
            return isZoomMeetingTitle(title) ? CallSpeakerWindowMatch(app: .zoom, meetingKey: "zoom") : nil
        case .teamsDesktop:
            guard !title.isEmpty else { return nil }
            return isTeamsMeetingTitle(title)
                ? CallSpeakerWindowMatch(app: .teamsDesktop, meetingKey: "teams-desktop", isCompactView: isTeamsCompactView(title))
                : nil
        case .browser:
            guard !title.isEmpty else { return nil }
            let tab = strippedBrowserTitle(title)
            if let code = meetCode(in: tab) {
                return CallSpeakerWindowMatch(app: .browserMeet, meetingKey: "meet:" + code.lowercased())
            }
            if matches(meetTitlePrefixPattern, tab) {
                return CallSpeakerWindowMatch(app: .browserMeet, meetingKey: "meet-title:" + tab.lowercased())
            }
            if isTeamsMeetingTitle(tab) {
                return CallSpeakerWindowMatch(app: .browserTeams, meetingKey: "teams-web", isCompactView: isTeamsCompactView(tab))
            }
            let lowered = tab.lowercased()
            if lowered.hasPrefix("zoom meeting") || lowered.hasPrefix("zoom webinar") {
                return CallSpeakerWindowMatch(app: .browserZoom, meetingKey: "zoom-web")
            }
            return nil
        }
    }

    /// Slack windows to scan first: a huddle-titled window is the likeliest.
    static func isLikelyHuddleTitle(_ title: String) -> Bool {
        title.range(of: "huddle", options: .caseInsensitive) != nil
    }

    /// A browser tab title without the browser's own suffixes or an unread
    /// count prefix ("(2) Meet - ...").
    static func strippedBrowserTitle(_ title: String) -> String {
        var cut = title.endIndex
        for suffix in browserTitleSuffixes {
            if let range = title.range(of: suffix, options: .caseInsensitive), range.lowerBound < cut {
                cut = range.lowerBound
            }
        }
        var tab = String(title[..<cut]).trimmingCharacters(in: .whitespaces)
        let ns = tab as NSString
        if let prefix = unreadCountPrefixPattern.firstMatch(in: tab, range: NSRange(location: 0, length: ns.length)) {
            tab = ns.replacingCharacters(in: prefix.range, with: "")
        }
        return tab
    }

    static func meetCode(in tab: String) -> String? {
        let ns = tab as NSString
        guard let match = meetCodePattern.firstMatch(in: tab, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1 else { return nil }
        return ns.substring(with: match.range(at: 1))
    }

    static func isZoomMeetingTitle(_ title: String) -> Bool {
        let lowered = title.lowercased()
        return lowered == "zoom" || lowered.hasPrefix("zoom meeting") || lowered.hasPrefix("zoom webinar")
    }

    static func isTeamsCompactView(_ title: String) -> Bool {
        title.lowercased().hasPrefix("meeting compact view | ")
    }

    static func isTeamsMeetingTitle(_ title: String) -> Bool {
        let lowered = title.lowercased()
        return isTeamsCompactView(title) || lowered.contains("| microsoft teams")
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }
}
