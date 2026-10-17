// CallSpeakerTileParserTests.swift
// Promise: from a call app's meeting window, the parser reads who is on the
// call and who the app shows as speaking, keeps the local user apart, and
// withholds the speaking read whenever the windows can't be trusted together.
// Fixture trees are in Tests/Fixtures/CallSpeaker/; every name is fictional.
// The fixtures follow unverified selectors, not live dumps.

import Foundation

private func callSpeakerFixture(_ name: String) -> CallSpeakerAXNode {
    loadJSONFixture("Tests/Fixtures/CallSpeaker/\(name).json", as: CallSpeakerAXNode.self)
}

private func window(
    _ app: CallSpeakerApp,
    key: String? = nil,
    compact: Bool = false,
    _ tree: CallSpeakerAXNode,
    truncated: Bool = false
) -> CallSpeakerWindowRead {
    CallSpeakerWindowRead(
        match: CallSpeakerWindowMatch(app: app, meetingKey: key ?? app.rawValue, isCompactView: compact),
        tree: tree,
        truncated: truncated
    )
}

private func teamsTile(_ name: String, speaking: Bool) -> CallSpeakerAXNode {
    CallSpeakerAXNode(
        role: "AXMenuItem",
        description: "\(name), unmuted More options",
        children: speaking ? [CallSpeakerAXNode(role: "AXGroup", domClassList: ["vdi-frame-occlusion"])] : []
    )
}

private func teamsWindow(_ tiles: [CallSpeakerAXNode]) -> CallSpeakerAXNode {
    CallSpeakerAXNode(role: "AXWindow", children: tiles)
}

func testCallSpeakerTileParser() {
    runSuite("CallSpeakerTileParser: Teams roster items, the speaking frame and the local user") {
        let parse = CallSpeakerSelectorTable.parser(for: .teamsDesktop).parse(callSpeakerFixture("teams-gallery"))
        assertEqual(parse.roster, ["Ana Ruiz", "Ben Okafor"], "Teams roster, cleaned of (External); context-menu items skipped")
        assertEqual(parse.speaking, ["Ana Ruiz"], "the occlusion frame marks speaking; a muted tile never speaks")
        assertEqual(parse.selfNames, ["Cara Diaz"], "the profile picture and own video tile mark the local user")
    }

    runSuite("CallSpeakerTileParser: Teams \"you are speaking\" and \"is speaking\" labels") {
        let tree = teamsWindow([
            teamsTile("Ana Ruiz", speaking: false),
            CallSpeakerAXNode(role: "AXStaticText", description: "Ben Okafor is speaking"),
            CallSpeakerAXNode(role: "AXStaticText", description: "You are speaking"),
        ])
        let parse = CallSpeakerSelectorTable.parser(for: .browserTeams).parse(tree)
        assertEqual(parse.roster, ["Ana Ruiz", "Ben Okafor"], "a speaking label adds its person")
        assertEqual(parse.speaking, ["Ben Okafor", "You"], "labelled speaker plus the local user")
        assertEqual(parse.selfNames, ["You"], "the local user, unnamed")
    }

    runSuite("CallSpeakerTileParser: Slack huddle names tiles from the profile button and ignores muted speakers") {
        let parse = CallSpeakerSelectorTable.parser(for: .slack).parse(callSpeakerFixture("slack-huddle"))
        assertEqual(parse.roster, ["Dev Patel", "Eli Novak"], "names from \"View <name>'s profile\"; a tile without one is skipped")
        assertEqual(parse.speaking, ["Dev Patel"], "a muted tile is never speaking, even with a stale overlay")
    }

    runSuite("CallSpeakerTileParser: native Zoom reads video render tiles and the profile button") {
        let zoom = CallSpeakerSelectorTable.parser(for: .zoom)
        let other = zoom.parse(callSpeakerFixture("zoom-active-speaker"))
        assertEqual(other.speaking, ["Gus Moreno"], "\"active speaker\" piece is speaking; muted audio is not")
        assertEqual(other.roster, ["Gus Moreno", "Hana Sato"], "roster without the local user or a \"Video off\" tile")
        assertEqual(other.selfNames, ["Ivy Chen"], "\", profile options\" names the local user")

        let mine = CallSpeakerSnapshotBuilder.build([window(.zoom, callSpeakerFixture("zoom-self-speaking"))])
        assertEqual(mine.selfNames, ["Ivy Chen"], "local user")
        assertEqual(mine.speaking, ["Ivy Chen"], "the local user's speech is recorded as theirs")
        assertEqual(mine.status, .rosterOnly, "only the local user speaking is no speaking evidence for others")
    }

    runSuite("CallSpeakerTileParser: Zoom web frames name the person from the footer") {
        let parse = CallSpeakerSelectorTable.parser(for: .browserZoom).parse(callSpeakerFixture("zoom-web"))
        assertEqual(parse.roster, ["Lena Ortiz", "Max Ueda"], "footer names, (Guest) stripped")
        assertEqual(parse.speaking, ["Lena Ortiz"], "the --active frame is speaking")
    }

    runSuite("CallSpeakerTileParser: Meet tiles name people and mark speakers") {
        let parse = CallSpeakerSelectorTable.parser(for: .browserMeet).parse(callSpeakerFixture("meet-tiles"))
        assertEqual(parse.roster, ["Jo Lind", "Kai Moss", "Lea Varga"], "names from More options and speaking labels; a static-text-only tile (\"You\") is skipped")
        assertEqual(parse.speaking, ["Jo Lind", "Lea Varga"], "speaking class and speaking label both count")
    }

    runSuite("CallSpeakerTileParser: a Meet tile with only control labels names nobody") {
        let parse = CallSpeakerSelectorTable.parser(for: .browserMeet).parse(callSpeakerFixture("meet-control-labels"))
        assertEqual(parse.roster, ["Jo Lind"], "\"Pin to your main screen\", \"Your video\" and other controls are never names")
        assertEqual(parse.tileCount, 1, "the control-only tile is not a participant")
        assertTrue(parse.speaking.isEmpty, "its speaking class names nobody")
    }

    runSuite("CallSpeakerNameCleaner: strips tags and role words; rejects non-names") {
        let cases: [(String, CallSpeakerNameCleaner.Cleaned?)] = [
            ("Ana Ruiz (Host)", .init(name: "Ana Ruiz", isSelf: false)),
            ("Ana Ruiz (Co-host), muted", .init(name: "Ana Ruiz", isSelf: false)),
            ("Ben Okafor (Guest)", .init(name: "Ben Okafor", isSelf: false)),
            ("Ben Okafor (Unverified)", .init(name: "Ben Okafor", isSelf: false)),
            ("Ben Okafor (External)", .init(name: "Ben Okafor", isSelf: false)),
            ("Eli Novak, Host", .init(name: "Eli Novak", isSelf: false)),
            ("Cara Diaz (me)", .init(name: "Cara Diaz", isSelf: true)),
            ("Cara Diaz (You)", .init(name: "Cara Diaz", isSelf: true)),
            ("Ana-Lucia Ferro", .init(name: "Ana-Lucia Ferro", isSelf: false)),
            ("You", nil),
            ("Video on", nil),
            ("Backgrounds and effects", nil),
            ("Participant", nil),
            ("Ana Ru\u{2026}", nil),
            ("Ana Ru...", nil),
            ("Ana\nRuiz", nil),
            ("more options for Ana Ruiz", nil),
            (String(repeating: "a", count: 151), nil),
            ("", nil),
            ("A", nil),
        ]
        for (raw, expected) in cases {
            assertEqual(CallSpeakerNameCleaner.clean(raw), expected, "clean(\"\(raw.prefix(30))\")")
        }
    }

    runSuite("CallSpeakerSnapshotBuilder: one meeting window with a speaking tile is trusted") {
        let snapshot = CallSpeakerSnapshotBuilder.build([window(.teamsDesktop, callSpeakerFixture("teams-gallery"))])
        assertEqual(snapshot.status, .speakingIndicator, "speaking indicator read")
        assertEqual(snapshot.speaking, ["Ana Ruiz"], "speaking set")
        assertEqual(snapshot.roster, ["Ana Ruiz", "Ben Okafor"], "roster")
        assertEqual(snapshot.selfNames, ["Cara Diaz"], "self")
        assertEqual(snapshot.app, .teamsDesktop, "the app is carried for the Teams lag shift")
    }

    runSuite("CallSpeakerSnapshotBuilder: nobody speaking is roster only; no window or no tiles say so") {
        let quiet = CallSpeakerSnapshotBuilder.build([window(.teamsDesktop, teamsWindow([
            teamsTile("Ana Ruiz", speaking: false), teamsTile("Ben Okafor", speaking: false),
        ]))])
        assertEqual(quiet.status, .rosterOnly, "tiles without a speaking indicator")
        assertEqual(quiet.roster, ["Ana Ruiz", "Ben Okafor"], "the roster still counts")

        assertEqual(CallSpeakerSnapshotBuilder.build([]).status, .noWindow, "no meeting window")
        let empty = CallSpeakerSnapshotBuilder.build([window(.teamsDesktop, CallSpeakerAXNode(role: "AXWindow"))])
        assertEqual(empty.status, .noTiles, "a meeting window without tiles (a Teams chat window)")
    }

    runSuite("CallSpeakerSnapshotBuilder: tiles from two apps or two meetings are withheld") {
        let snapshot = CallSpeakerSnapshotBuilder.build([
            window(.teamsDesktop, callSpeakerFixture("teams-gallery")),
            window(.slack, callSpeakerFixture("slack-huddle")),
        ])
        assertEqual(snapshot.status, .multipleWindows, "Teams and a Slack huddle at once")
        assertTrue(snapshot.speaking.isEmpty && snapshot.roster.isEmpty, "nothing from either is used")

        let twoMeets = CallSpeakerSnapshotBuilder.build([
            window(.browserMeet, key: "meet:abc-defg-hij", callSpeakerFixture("meet-tiles")),
            window(.browserMeet, key: "meet:klm-nopq-rst", CallSpeakerAXNode(role: "AXWindow")),
        ])
        assertEqual(twoMeets.status, .multipleWindows, "two Meet codes open, even if one shows no tiles")

        let withEmptyWindow = CallSpeakerSnapshotBuilder.build([
            window(.teamsDesktop, callSpeakerFixture("teams-gallery")),
            window(.browserMeet, CallSpeakerAXNode(role: "AXWindow")),
        ])
        assertEqual(withEmptyWindow.status, .speakingIndicator, "another app's window without tiles doesn't count")
    }

    runSuite("CallSpeakerSnapshotBuilder: Teams reads only a single compact view") {
        let main = teamsWindow([teamsTile("Ana Ruiz", speaking: true), teamsTile("Ben Okafor", speaking: false)])
        let compact = teamsWindow([teamsTile("Ben Okafor", speaking: true)])
        let one = CallSpeakerSnapshotBuilder.build([
            window(.teamsDesktop, main), window(.teamsDesktop, compact: true, compact),
        ])
        assertEqual(one.status, .speakingIndicator, "one compact view is trusted")
        assertEqual(one.speaking, ["Ben Okafor"], "and read alone, ignoring the main window")

        let two = CallSpeakerSnapshotBuilder.build([
            window(.teamsDesktop, compact: true, compact), window(.teamsDesktop, compact: true, compact),
        ])
        assertEqual(two.status, .multipleWindows, "two compact views are ambiguous")
    }

    runSuite("CallSpeakerSnapshotBuilder: windows of one meeting that disagree are withheld") {
        let main = teamsWindow([teamsTile("Ana Ruiz", speaking: true), teamsTile("Ben Okafor", speaking: false)])
        let other = teamsWindow([teamsTile("Ana Ruiz", speaking: false)])
        let disagree = CallSpeakerSnapshotBuilder.build([window(.teamsDesktop, main), window(.teamsDesktop, other)])
        assertEqual(disagree.status, .windowsDisagree, "one window says Ana is speaking, the other says not")
        assertTrue(disagree.speaking.isEmpty, "no speaking evidence from a disagreeing poll")
        assertEqual(disagree.roster, ["Ana Ruiz", "Ben Okafor"], "the roster is still read")

        let agreeing = teamsWindow([teamsTile("Ana Ruiz", speaking: true)])
        let agree = CallSpeakerSnapshotBuilder.build([window(.teamsDesktop, main), window(.teamsDesktop, agreeing)])
        assertEqual(agree.status, .speakingIndicator, "a window showing fewer people but the same speaker agrees")
    }

    runSuite("CallSpeakerSnapshotBuilder: a truncated meeting window is withheld") {
        let cut = CallSpeakerSnapshotBuilder.build([window(.teamsDesktop, callSpeakerFixture("teams-gallery"), truncated: true)])
        assertEqual(cut.status, .truncated, "a capped walk may have missed a speaking tile")
        assertTrue(cut.speaking.isEmpty, "no speaking evidence from a truncated read")

        let cutEmpty = CallSpeakerSnapshotBuilder.build([window(.teamsDesktop, CallSpeakerAXNode(role: "AXWindow"), truncated: true)])
        assertEqual(cutEmpty.status, .truncated, "a capped walk that found no tiles is truncated, not empty")

        let slack = CallSpeakerSnapshotBuilder.build([
            window(.slack, callSpeakerFixture("slack-huddle")),
            window(.slack, CallSpeakerAXNode(role: "AXWindow"), truncated: true),
        ])
        assertEqual(slack.status, .speakingIndicator, "a cut-short Slack window without a huddle doesn't withhold the huddle")
    }
}
