// CallSpeakerTileParser.swift
// Turns the Accessibility trees of a call app's meeting windows into one
// snapshot: who is on the call, who the app shows as speaking, and whether
// the read is trustworthy. Pure functions over `CallSpeakerAXNode`, tested
// with JSON fixtures in Tests/Fixtures/CallSpeaker/.
//
// Every app-specific string lives in `CallSpeakerSelectorTable`, so a changed
// class name or label is a data edit. Provenance is marked per selector:
// "unverified" = observed but not yet checked against live trees;
// "inferred" = a best guess where the observed behavior was unclear. Nothing is
// verified against a live dump yet.
//
// Privacy: names in, names out, in memory only. Never log them.

import Foundation

/// What one poll found across every meeting window.
struct CallSpeakerSnapshot: Equatable, Sendable {
    enum Status: String, Sendable, CaseIterable {
        /// Tiles were read and someone other than the local user showed as speaking.
        case speakingIndicator
        /// Tiles were read but nobody else showed as speaking.
        case rosterOnly
        /// A meeting window was found but no participant tiles in it.
        case noTiles
        /// No meeting window of a supported app.
        case noWindow
        /// Tiles in more than one app or meeting. Withheld: we can't tell
        /// which meeting is being recorded.
        case multipleWindows
        /// Windows of the same meeting showed different speakers. Withheld.
        case windowsDisagree
        /// A meeting window was cut short by a read cap. Withheld.
        case truncated

        /// Speaking evidence from this poll can't be trusted either way.
        var isWithheld: Bool {
            switch self {
            case .multipleWindows, .windowsDisagree, .truncated: return true
            default: return false
            }
        }
    }

    var roster: [String]
    /// Everyone shown as speaking, the local user included.
    var speaking: Set<String>
    var selfNames: Set<String>
    var status: Status
    /// The app the tiles came from (Teams spans get a lag shift).
    var app: CallSpeakerApp? = nil

    static func empty(_ status: Status) -> CallSpeakerSnapshot {
        CallSpeakerSnapshot(roster: [], speaking: [], selfNames: [], status: status)
    }

    /// People other than the local user shown as speaking.
    var othersSpeaking: Set<String> { speaking.subtracting(selfNames) }
}

/// One meeting window as the reader saw it.
struct CallSpeakerWindowRead: Sendable {
    let match: CallSpeakerWindowMatch
    let tree: CallSpeakerAXNode
    /// A node, depth or time cap stopped the walk early.
    let truncated: Bool
}

/// What one window's tiles say.
struct CallSpeakerWindowParse: Equatable, Sendable {
    /// People other than the local user, in tile order.
    var roster: [String] = []
    /// Everyone shown as speaking and not muted, the local user included.
    var speaking: Set<String> = []
    var selfNames: Set<String> = []
    var tileCount = 0

    var hasTiles: Bool { tileCount > 0 }
}

// MARK: - Selectors (data)

enum CallSpeakerSelectorTable {
    // Shared. unverified.
    /// Labels ending with these (lowercased) name someone speaking.
    static let speakingLabelSuffixes = [" is speaking", ", speaking", ", active speaker"]
    /// A label starting with this (lowercased) is the local user speaking.
    static let selfSpeakingPrefix = "you are speaking"

    enum Zoom {
        // Native Zoom app. unverified.
        static let tileRoleDescription = "video render"
        static let speakingPiece = "active speaker"
        static let mutedPieces: Set<String> = ["computer audio muted", "no audio connected"]
        static let selfLabelSuffix = ", profile options"
        static let selfLabelRoles: Set<String> = ["AXButton", "AXPopUpButton"]
    }

    enum ZoomWeb {
        // Zoom's web client in a browser. unverified.
        static let frameClassSuffix = "__video-frame"
        static let speakingFrameClassSuffix = "__video-frame--active"
        static let nameFooterClass = "video-avatar__avatar-footer"
    }

    enum Meet {
        // Google Meet (obfuscated class names). unverified.
        static let tileClass = "oZRSLe"
        static let speakingClass = "kssMZb"
        static let nameLabelPrefix = "More options for "
    }

    enum Slack {
        // Slack huddle. unverified (classes also in the original spec).
        static let tileClass = "p-huddle_peer_tile"
        static let speakingClass = "p-huddle_peer_tile__overlay--active_speaker"
        static let mutedClass = "p-huddle_peer_tile__name_overlay--muted"
        static let profileLabelPrefix = "View "
        static let profileLabelSuffixes = ["'s profile", "\u{2019}s profile"]
    }

    enum Teams {
        // Microsoft Teams desktop and web. unverified.
        static let tileRole = "AXMenuItem"
        static let menuRole = "AXMenu"
        static let moreOptionsSuffix = " More options"
        static let skippedPieces: Set<String> = ["muted", "unmuted", "myself video", "video"]
        static let skippedPiecePrefix = "video is "
        static let skippedPieceContains = "context "
        static let mutedPieces: Set<String> = ["muted"]
        static let speakingClass = "vdi-frame-occlusion"
        /// inferred: a class with this prefix marks the local user's own video tile.
        static let selfTileClassPrefix = "bkg_"
        static let selfButtonPrefix = "your profile"
        static let profilePicturePrefix = "profile picture of "
    }

    static func parser(for app: CallSpeakerApp) -> CallSpeakerTileParsing {
        switch app {
        case .zoom: return CallSpeakerZoomParser()
        case .browserZoom: return CallSpeakerZoomWebParser()
        case .teamsDesktop, .browserTeams: return CallSpeakerTeamsParser()
        case .slack: return CallSpeakerSlackParser()
        case .browserMeet: return CallSpeakerMeetParser()
        }
    }
}

// MARK: - Parsers

protocol CallSpeakerTileParsing: Sendable {
    func parse(_ tree: CallSpeakerAXNode) -> CallSpeakerWindowParse
}

/// Collects participants by upserting on name: muted is
/// AND-ed, speaking is OR-ed across repeated sightings of one name.
private struct ParticipantList {
    private(set) var order: [String] = []
    private var muted: [String: Bool] = [:]
    private var speaking: [String: Bool] = [:]
    var selfNames = Set<String>()
    var selfSpeaking = false

    mutating func upsert(_ cleaned: CallSpeakerNameCleaner.Cleaned, muted isMuted: Bool, speaking isSpeaking: Bool) {
        let name = cleaned.name
        if cleaned.isSelf { selfNames.insert(name) }
        if muted[name] == nil {
            order.append(name)
            muted[name] = isMuted
            speaking[name] = isSpeaking
        } else {
            muted[name] = (muted[name] ?? false) && isMuted
            speaking[name] = (speaking[name] ?? false) || isSpeaking
        }
    }

    func parse() -> CallSpeakerWindowParse {
        var result = CallSpeakerWindowParse()
        result.tileCount = order.count
        result.selfNames = selfNames
        for name in order {
            if speaking[name] == true, muted[name] != true { result.speaking.insert(name) }
            if !selfNames.contains(name) { result.roster.append(name) }
        }
        if selfSpeaking {
            if result.selfNames.isEmpty { result.selfNames.insert(CallSpeakerNameCleaner.selfName) }
            result.speaking.formUnion(result.selfNames)
        }
        return result
    }
}

private extension CallSpeakerAXNode {
    /// Pre-order, self first.
    var subtree: [CallSpeakerAXNode] {
        var nodes: [CallSpeakerAXNode] = [self]
        for child in children { nodes.append(contentsOf: child.subtree) }
        return nodes
    }

    func hasClass(where predicate: (String) -> Bool) -> Bool {
        domClassList.contains(where: predicate)
    }

    /// Description, then title.
    var labelTexts: [String] {
        [description, title].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}

/// Strips a speaking suffix from a label; nil when it has none.
private func nameBeforeSpeakingSuffix(_ label: String) -> String? {
    let lowered = label.lowercased()
    guard let suffix = CallSpeakerSelectorTable.speakingLabelSuffixes.first(where: { lowered.hasSuffix($0) }) else { return nil }
    return String(label.dropLast(suffix.count))
}

/// Native Zoom: tiles are "video render" elements named by their description.
struct CallSpeakerZoomParser: CallSpeakerTileParsing {
    typealias S = CallSpeakerSelectorTable.Zoom

    func parse(_ tree: CallSpeakerAXNode) -> CallSpeakerWindowParse {
        var list = ParticipantList()
        var selfName: CallSpeakerNameCleaner.Cleaned?
        for node in tree.subtree {
            if node.labelTexts.contains(where: { $0.lowercased().hasPrefix(CallSpeakerSelectorTable.selfSpeakingPrefix) }) {
                list.selfSpeaking = true
            }
            if let role = node.role, S.selfLabelRoles.contains(role),
               let label = node.description, label.lowercased().hasSuffix(S.selfLabelSuffix) {
                selfName = CallSpeakerNameCleaner.clean(String(label.dropLast(S.selfLabelSuffix.count)))
            }
            guard node.roleDescription?.lowercased() == S.tileRoleDescription else { continue }
            let pieces = (node.description ?? "").split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard let first = pieces.first, let cleaned = CallSpeakerNameCleaner.clean(first) else { continue }
            let lowered = pieces.map { $0.lowercased() }
            list.upsert(
                cleaned,
                muted: lowered.contains(where: S.mutedPieces.contains),
                speaking: lowered.contains(S.speakingPiece)
            )
        }
        if let selfName { list.selfNames.insert(selfName.name) }
        return list.parse()
    }
}

/// Zoom's web client: video frames with a footer naming the person.
struct CallSpeakerZoomWebParser: CallSpeakerTileParsing {
    typealias S = CallSpeakerSelectorTable.ZoomWeb

    func parse(_ tree: CallSpeakerAXNode) -> CallSpeakerWindowParse {
        var list = ParticipantList()
        collect(tree, into: &list)
        return list.parse()
    }

    private func collect(_ node: CallSpeakerAXNode, into list: inout ParticipantList) {
        let isFrame = node.hasClass { $0.hasSuffix(S.frameClassSuffix) || $0.hasSuffix(S.speakingFrameClassSuffix) }
        guard isFrame else {
            node.children.forEach { collect($0, into: &list) }
            return
        }
        let footer = node.subtree.first { $0.hasClass { $0.contains(S.nameFooterClass) } }
        let name = footer?.subtree
            .filter { $0.role == "AXStaticText" }
            .flatMap(\.labels)
            .lazy.compactMap(CallSpeakerNameCleaner.clean).first
        guard let name else { return }
        list.upsert(name, muted: false, speaking: node.hasClass { $0.hasSuffix(S.speakingFrameClassSuffix) })
    }
}

/// Google Meet in a browser.
struct CallSpeakerMeetParser: CallSpeakerTileParsing {
    typealias S = CallSpeakerSelectorTable.Meet

    func parse(_ tree: CallSpeakerAXNode) -> CallSpeakerWindowParse {
        var list = ParticipantList()
        collect(tree, into: &list)
        return list.parse()
    }

    private func collect(_ node: CallSpeakerAXNode, into list: inout ParticipantList) {
        guard node.hasClass(where: { $0.contains(S.tileClass) }) else {
            node.children.forEach { collect($0, into: &list) }
            return
        }
        let nodes = node.subtree
        var speakingFromLabel = false
        var name: CallSpeakerNameCleaner.Cleaned?

        // 1. "More options for <Name>" (case-sensitive) in value, title or description.
        let texts = nodes.flatMap { [$0.value, $0.title, $0.description].compactMap { $0 } }
        for text in texts where text.hasPrefix(S.nameLabelPrefix) {
            if let cleaned = CallSpeakerNameCleaner.clean(String(text.dropFirst(S.nameLabelPrefix.count))) {
                name = cleaned
                break
            }
        }
        // 2. "<Name> is speaking" and friends.
        for label in nodes.flatMap(\.labelTexts) {
            guard let stripped = nameBeforeSpeakingSuffix(label) else { continue }
            speakingFromLabel = true
            if name == nil { name = CallSpeakerNameCleaner.clean(stripped) }
            break
        }
        // No third step. A fallback could take the first static text
        // or group text that cleans to a name, but a tile's controls ("Pin to
        // your main screen", "Your video") clean to names too. Left out until
        // checked against a live Meet tree; a tile without either label above
        // is skipped.
        guard let name else { return }
        let speaking = speakingFromLabel || nodes.contains { $0.hasClass { $0 == S.speakingClass } }
        list.upsert(name, muted: false, speaking: speaking)
    }
}

/// Slack huddle tiles.
struct CallSpeakerSlackParser: CallSpeakerTileParsing {
    typealias S = CallSpeakerSelectorTable.Slack

    func parse(_ tree: CallSpeakerAXNode) -> CallSpeakerWindowParse {
        var list = ParticipantList()
        collect(tree, into: &list)
        return list.parse()
    }

    private func collect(_ node: CallSpeakerAXNode, into list: inout ParticipantList) {
        guard node.hasClass(where: { $0.contains(S.tileClass) }) else {
            node.children.forEach { collect($0, into: &list) }
            return
        }
        let nodes = node.subtree
        guard let name = nodes.flatMap(\.labels).lazy.compactMap(Self.profileName).first else { return }
        list.upsert(
            name,
            muted: nodes.contains { $0.hasClass { $0 == S.mutedClass } },
            speaking: nodes.contains { $0.hasClass { $0 == S.speakingClass } }
        )
    }

    /// "View <Name>'s profile".
    static func profileName(_ label: String) -> CallSpeakerNameCleaner.Cleaned? {
        guard label.hasPrefix(S.profileLabelPrefix),
              let suffix = S.profileLabelSuffixes.first(where: { label.hasSuffix($0) }),
              label.count > S.profileLabelPrefix.count + suffix.count else { return nil }
        return CallSpeakerNameCleaner.clean(String(label.dropFirst(S.profileLabelPrefix.count).dropLast(suffix.count)))
    }
}

/// Microsoft Teams, desktop and web: roster tiles are menu items.
struct CallSpeakerTeamsParser: CallSpeakerTileParsing {
    typealias S = CallSpeakerSelectorTable.Teams

    private struct Tile {
        let name: CallSpeakerNameCleaner.Cleaned
        let muted: Bool
        let speaking: Bool
        let isSelf: Bool
    }

    func parse(_ tree: CallSpeakerAXNode) -> CallSpeakerWindowParse {
        var list = ParticipantList()
        visit(tree, menuDepth: 0, into: &list)
        return list.parse()
    }

    private func visit(_ node: CallSpeakerAXNode, menuDepth: Int, into list: inout ParticipantList) {
        // Menu items inside an open AXMenu are context menus, not tiles.
        if node.role == S.tileRole, menuDepth == 0, let tile = tile(node) {
            list.upsert(tile.name, muted: tile.muted, speaking: tile.speaking)
            if tile.isSelf { list.selfNames.insert(tile.name.name) }
        }
        if node.role == "AXButton",
           node.labelTexts.contains(where: { $0.lowercased().hasPrefix(S.selfButtonPrefix) }),
           let selfName = profilePictureName(node) {
            list.selfNames.insert(selfName.name)
        }
        for label in node.labelTexts {
            if label.lowercased().hasPrefix(CallSpeakerSelectorTable.selfSpeakingPrefix) {
                list.selfSpeaking = true
            } else if let stripped = nameBeforeSpeakingSuffix(label), let cleaned = CallSpeakerNameCleaner.clean(stripped) {
                list.upsert(cleaned, muted: false, speaking: true)
            }
        }
        let depth = node.role == S.menuRole ? menuDepth + 1 : menuDepth
        for child in node.children {
            visit(child, menuDepth: depth, into: &list)
        }
    }

    private func tile(_ node: CallSpeakerAXNode) -> Tile? {
        guard var label = node.labelTexts.first else { return nil }
        if label.hasSuffix(S.moreOptionsSuffix) { label = String(label.dropLast(S.moreOptionsSuffix.count)) }
        let pieces = label.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let lowered = pieces.map { $0.lowercased() }
        let candidate = lowered.firstIndex { piece in
            !piece.isEmpty
                && !S.skippedPieces.contains(piece)
                && !piece.hasPrefix(S.skippedPiecePrefix)
                && !piece.contains(S.skippedPieceContains)
        }
        guard let candidate, let name = CallSpeakerNameCleaner.clean(pieces[candidate]) else { return nil }
        let nodes = node.subtree
        return Tile(
            name: name,
            muted: lowered.contains(where: S.mutedPieces.contains),
            speaking: nodes.contains { $0.hasClass { $0 == S.speakingClass } },
            isSelf: nodes.contains { $0.hasClass { $0.hasPrefix(S.selfTileClassPrefix) } }
        )
    }

    /// The local user's name from the "Your profile" button's picture.
    private func profilePictureName(_ button: CallSpeakerAXNode) -> CallSpeakerNameCleaner.Cleaned? {
        let nodes = button.subtree
        for image in nodes where image.role == "AXImage" {
            for label in image.labelTexts where label.lowercased().hasPrefix(S.profilePicturePrefix) {
                var name = String(label.dropFirst(S.profilePicturePrefix.count))
                if name.hasSuffix(".") { name.removeLast() }
                if let cleaned = CallSpeakerNameCleaner.clean(name) { return cleaned }
            }
        }
        return nodes.filter { $0.role == "AXStaticText" }.flatMap(\.labels)
            .lazy.compactMap(CallSpeakerNameCleaner.clean).first
    }
}

// MARK: - Names

enum CallSpeakerNameCleaner {
    /// The name recorded for the local user when the app gives no other.
    static let selfName = "You"

    struct Cleaned: Equatable {
        let name: String
        let isSelf: Bool
    }

    /// Trailing parenthesized tags dropped from a name. Unverified: Guest,
    /// Unverified, External, You; original spec: Host, Co-host, me.
    static let roleTags: Set<String> = [
        "host", "co-host", "cohost", "guest", "external", "unverified", "organizer", "organiser", "presenter",
    ]
    static let selfTags: Set<String> = ["me", "you"]
    /// Unverified denylist, plus generic words from the original spec.
    static let deniedNames: Set<String> = [
        "you", "someone", "nobody", "presenting", "presentation", "muted", "unmuted", "more options",
        "reframe", "backgrounds and effects", "microphone off", "microphone on", "video off", "video on",
        "me", "participant", "participants", "guest", "guests", "unknown",
    ]
    static let maxLength = 150

    private static let tagPattern = try! NSRegularExpression(pattern: "\\s*\\(([^()]*)\\)\\s*$", options: [])

    /// A display name from a tile label, or nil when nothing name-like is
    /// left. "(me)" and "(You)" mark the local user.
    static func clean(_ raw: String) -> Cleaned? {
        var text = raw.replacingOccurrences(of: "\u{00A0}", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.contains("\n"), !text.contains("\u{2026}"), !text.hasSuffix("...") else { return nil }
        var isSelf = false

        var changed = true
        while changed {
            changed = false
            text = text.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",")))
            if text.lowercased().hasSuffix(", muted") {
                text = String(text.dropLast(", muted".count))
                changed = true
                continue
            }
            // Trailing "(Host)", "(External)", "(me)".
            let ns = text as NSString
            if let match = tagPattern.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
                let tag = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces).lowercased()
                if selfTags.contains(tag) || roleTags.contains(tag) {
                    if selfTags.contains(tag) { isSelf = true }
                    text = ns.replacingCharacters(in: match.range, with: "")
                    changed = true
                    continue
                }
            }
            // Trailing role word: "Ana Ruiz, Host".
            if let comma = text.range(of: ",", options: .backwards) {
                let tail = text[comma.upperBound...].trimmingCharacters(in: .whitespaces).lowercased()
                if roleTags.contains(tail) {
                    text = String(text[..<comma.lowerBound])
                    changed = true
                }
            }
        }

        let name = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let lowered = name.lowercased()
        guard name.count >= 2,
              name.count <= maxLength,
              !deniedNames.contains(lowered),
              !lowered.hasPrefix("more options for ") else { return nil }
        return Cleaned(name: name, isSelf: isSelf)
    }
}

// MARK: - Snapshot

enum CallSpeakerSnapshotBuilder {
    private struct Parsed {
        let window: CallSpeakerWindowRead
        let parse: CallSpeakerWindowParse
    }

    /// Folds every meeting window of one poll into one snapshot, withholding
    /// speaking evidence whenever the windows can't be trusted together.
    /// Status order: more than one app,
    /// truncated, ambiguous windows, disagreeing windows, no tiles, roster
    /// only.
    static func build(_ windows: [CallSpeakerWindowRead]) -> CallSpeakerSnapshot {
        guard !windows.isEmpty else { return .empty(.noWindow) }

        let parsed = windows.map { Parsed(window: $0, parse: CallSpeakerSelectorTable.parser(for: $0.match.app).parse($0.tree)) }
        let appsWithTiles = Set(parsed.filter(\.parse.hasTiles).map(\.window.match.app))

        guard appsWithTiles.count <= 1 else { return .empty(.multipleWindows) }
        guard let app = appsWithTiles.first else {
            return .empty(windows.contains(where: \.truncated) ? .truncated : .noTiles)
        }

        var appWindows = parsed.filter { $0.window.match.app == app }
        // Slack windows share one node budget and most aren't huddles, so
        // only a cut-short Slack window that shows tiles withholds.
        let truncatedWindows = appWindows.filter { $0.window.truncated && (app != .slack || $0.parse.hasTiles) }
        if !truncatedWindows.isEmpty {
            return CallSpeakerSnapshot(roster: [], speaking: [], selfNames: [], status: .truncated, app: app)
        }

        // Window gates (unverified): more than one Meet code is ambiguous;
        // Teams reads only its compact view when exactly one is open, and
        // more than one compact view is ambiguous.
        if app == .browserMeet, Set(appWindows.map(\.window.match.meetingKey)).count > 1 {
            return .empty(.multipleWindows)
        }
        if app.isTeams {
            let compact = appWindows.filter(\.window.match.isCompactView)
            if compact.count > 1 { return .empty(.multipleWindows) }
            if compact.count == 1 { appWindows = compact }
        }
        appWindows = appWindows.filter(\.parse.hasTiles)
        guard !appWindows.isEmpty else { return .empty(.noTiles) }
        if Set(appWindows.map(\.window.match.meetingKey)).count > 1 { return .empty(.multipleWindows) }

        var roster: [String] = []
        var selfNames = Set<String>()
        var speaking = Set<String>()
        for entry in appWindows {
            selfNames.formUnion(entry.parse.selfNames)
            for name in entry.parse.roster where !roster.contains(name) { roster.append(name) }
            speaking.formUnion(entry.parse.speaking)
        }
        roster.removeAll { selfNames.contains($0) }

        if disagree(appWindows.map(\.parse)) {
            return CallSpeakerSnapshot(roster: roster, speaking: [], selfNames: selfNames, status: .windowsDisagree, app: app)
        }
        return CallSpeakerSnapshot(
            roster: roster,
            speaking: speaking,
            selfNames: selfNames,
            status: speaking.subtracting(selfNames).isEmpty ? .rosterOnly : .speakingIndicator,
            app: app
        )
    }

    /// Two windows of one meeting disagree when, among people both show,
    /// one shows someone speaking and the other doesn't.
    static func disagree(_ parses: [CallSpeakerWindowParse]) -> Bool {
        guard parses.count > 1 else { return false }
        for i in parses.indices {
            for j in parses.indices where j > i {
                let shared = Set(parses[i].roster).union(parses[i].selfNames)
                    .intersection(Set(parses[j].roster).union(parses[j].selfNames))
                if parses[i].speaking.intersection(shared) != parses[j].speaking.intersection(shared) {
                    return true
                }
            }
        }
        return false
    }
}
