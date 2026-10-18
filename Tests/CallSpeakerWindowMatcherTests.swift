// CallSpeakerWindowMatcherTests.swift
// Promise: the call-app speaker reader walks only windows that are a meeting
// in a supported app, and tells windows of the same meeting from windows of
// different meetings. It reads native call apps before browsers and Slack
// last, gives each app a fair share of the poll, and walks Slack only when a
// huddle is likely. All names and titles are fictional.

import Foundation

func testCallSpeakerWindowMatcher() {
    runSuite("CallSpeakerWindowMatcher: Meet tabs match through browser suffixes") {
        let meetTitles = [
            "Meet - abc-defg-hij - Google Chrome",
            "Meet - abc-defg-hij - Camera and microphone recording - Google Chrome - Work",
            "Meet - abc-defg-hij - Microphone recording - Microsoft Edge",
            "Meet - abc-defg-hij - Camera recording - Mozilla Firefox",
            "(2) Meet - abc-defg-hij - Google Chrome",
            "meet - ABC-DEFG-HIJ",
        ]
        for title in meetTitles {
            assertEqual(
                CallSpeakerWindowMatcher.match(title: title, host: .browser),
                CallSpeakerWindowMatch(app: .browserMeet, meetingKey: "meet:abc-defg-hij"),
                "\"\(title)\" is the Meet call abc-defg-hij"
            )
        }
        let named = CallSpeakerWindowMatcher.match(title: "Meet - Design review - Google Chrome", host: .browser)
        assertEqual(named?.app, .browserMeet, "a Meet tab titled with the meeting name is still a Meet call")
        assertTrue(
            named?.meetingKey != CallSpeakerWindowMatcher.match(title: "Meet - Budget review - Google Chrome", host: .browser)?.meetingKey,
            "two Meet tabs with different titles are different meetings"
        )
    }

    runSuite("CallSpeakerWindowMatcher: pages that only mention Meet don't match") {
        let notCalls = [
            "Google Meet - Google Chrome",
            "Meeting notes - Google Docs - Google Chrome",
            "Meetup: Swift night - Google Chrome",
            "Zoom Workplace - Google Chrome",
            "",
        ]
        for title in notCalls {
            assertTrue(
                CallSpeakerWindowMatcher.match(title: title, host: .browser) == nil,
                "\"\(title)\" is not a call the reader walks"
            )
        }
    }

    runSuite("CallSpeakerWindowMatcher: Teams meetings match in the browser and the desktop app") {
        assertEqual(
            CallSpeakerWindowMatcher.match(title: "Weekly sync | Microsoft Teams - Microsoft Edge", host: .browser)?.app,
            .browserTeams,
            "a Teams web meeting tab"
        )
        assertEqual(
            CallSpeakerWindowMatcher.match(title: "Meeting compact view | Weekly sync | Microsoft Teams", host: .teamsDesktop),
            CallSpeakerWindowMatch(app: .teamsDesktop, meetingKey: "teams-desktop", isCompactView: true),
            "the Teams compact view belongs to the same meeting as the main window, flagged as compact"
        )
        assertEqual(
            CallSpeakerWindowMatcher.match(title: "Weekly sync | Microsoft Teams", host: .teamsDesktop),
            CallSpeakerWindowMatch(app: .teamsDesktop, meetingKey: "teams-desktop"),
            "the Teams main meeting window"
        )
        assertTrue(
            CallSpeakerWindowMatcher.match(title: "Settings", host: .teamsDesktop) == nil,
            "a Teams window that isn't titled as Teams content"
        )
    }

    runSuite("CallSpeakerWindowMatcher: Zoom meeting windows and Slack huddles") {
        for title in ["Zoom Meeting", "Zoom Webinar", "Zoom", "Zoom Meeting 40-Minutes"] {
            assertEqual(CallSpeakerWindowMatcher.match(title: title, host: .zoom)?.app, .zoom, "\"\(title)\" is a Zoom meeting window")
        }
        for title in ["Zoom Workplace", "Settings", "Chat"] {
            assertTrue(CallSpeakerWindowMatcher.match(title: title, host: .zoom) == nil, "\"\(title)\" is not a Zoom meeting window")
        }
        assertEqual(
            CallSpeakerWindowMatcher.match(title: "Huddle in #design-crit - Slack", host: .slack)?.app,
            .slack,
            "a Slack huddle window"
        )
        assertEqual(
            CallSpeakerWindowMatcher.match(title: "design-crit (Channel) - Acme - Slack", host: .slack)?.app,
            .slack,
            "a huddle can sit in any Slack window, so every one is a candidate"
        )
        assertTrue(CallSpeakerWindowMatcher.isLikelyHuddleTitle("Huddle in #design-crit - Slack"), "huddle windows are read first")
        assertTrue(!CallSpeakerWindowMatcher.isLikelyHuddleTitle("design-crit (Channel) - Acme - Slack"), "others after")
        assertEqual(
            CallSpeakerWindowMatcher.match(title: "Zoom Meeting - Google Chrome", host: .browser),
            CallSpeakerWindowMatch(app: .browserZoom, meetingKey: "zoom-web"),
            "Zoom's web client in a browser"
        )
    }

    runSuite("CallSpeakerApp: running apps map to hosts, helpers never do") {
        assertEqual(CallSpeakerApp.host(forBundleID: "us.zoom.xos"), .zoom, "Zoom")
        assertEqual(CallSpeakerApp.host(forBundleID: "com.microsoft.teams2"), .teamsDesktop, "new Teams")
        assertEqual(CallSpeakerApp.host(forBundleID: "com.microsoft.teams"), .teamsDesktop, "classic Teams")
        assertEqual(CallSpeakerApp.host(forBundleID: "com.tinyspeck.slackmacgap"), .slack, "Slack")
        assertEqual(CallSpeakerApp.host(forBundleID: "com.google.Chrome"), .browser, "Chrome")
        assertEqual(CallSpeakerApp.host(forBundleID: "com.apple.Safari"), .browser, "Safari")
        assertTrue(CallSpeakerApp.host(forBundleID: "com.google.Chrome.helper") == nil, "Chrome's helper owns no windows")
        assertTrue(CallSpeakerApp.host(forBundleID: "com.apple.WebKit.GPU") == nil, "WebKit's GPU process owns no windows")
        assertTrue(CallSpeakerApp.host(forBundleID: "com.apple.Notes") == nil, "Notes hosts no call")
    }

    runSuite("CallSpeakerApp: only Chromium and Electron apps get AXManualAccessibility") {
        for bundleID in ["com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser.Browser",
                         "com.microsoft.teams2", "com.tinyspeck.slackmacgap"] {
            assertTrue(CallSpeakerApp.needsManualAccessibility(bundleID: bundleID), "\(bundleID) builds its tree on request")
        }
        for bundleID in ["com.apple.Safari", "org.mozilla.firefox", "us.zoom.xos"] {
            assertTrue(!CallSpeakerApp.needsManualAccessibility(bundleID: bundleID), "\(bundleID) is left alone")
        }
    }

    runSuite("CallSpeakerReadPlan: native call apps first, browsers next, Slack last") {
        let apps: [(String, CallSpeakerApp.Host)] = [
            ("slack", .slack), ("chrome", .browser), ("zoom", .zoom), ("safari", .browser), ("teams", .teamsDesktop),
        ]
        let order = CallSpeakerReadPlan.ordered(apps) { $0.1 }.map(\.0)
        assertEqual(order, ["zoom", "teams", "chrome", "safari", "slack"], "Slack can never go ahead of a meeting window")
    }

    runSuite("CallSpeakerReadPlan: the first call app gets most of the poll, and later apps keep enough for their titles") {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let pollDeadline = start.addingTimeInterval(1.5)
        // Zoom, then an idle browser, then Slack. Zoom's huge tree uses all it gets.
        let zoom = CallSpeakerReadPlan.appDeadline(now: start, pollDeadline: pollDeadline, appsLeft: 3)
        assertEqual((zoom.timeIntervalSince(start) * 1000).rounded(), 1200, "the call app isn't cut to a third of the poll")
        let browser = CallSpeakerReadPlan.appDeadline(now: zoom, pollDeadline: pollDeadline, appsLeft: 2)
        assertEqual((browser.timeIntervalSince(zoom) * 1000).rounded(), 150, "a later app still gets its reserve")
        assertEqual(CallSpeakerReadPlan.appDeadline(now: browser, pollDeadline: pollDeadline, appsLeft: 1), pollDeadline, "the last app gets what is left")
        // The first app finds no meeting window and is done in 0.1 s: the rest passes on.
        let second = CallSpeakerReadPlan.appDeadline(now: start.addingTimeInterval(0.1), pollDeadline: pollDeadline, appsLeft: 2)
        assertEqual((second.timeIntervalSince(start) * 1000).rounded(), 1350, "unused time goes to the apps after it")
        // Little time left: never less than an even split.
        let late = CallSpeakerReadPlan.appDeadline(now: start.addingTimeInterval(1.3), pollDeadline: pollDeadline, appsLeft: 3)
        assertEqual((late.timeIntervalSince(start) * 1000).rounded(), 1367, "an even split is the floor")
    }

    runSuite("CallSpeakerReadPlan: Slack is walked only when a huddle is likely") {
        var micChecks = 0
        let huddleTitle = CallSpeakerReadPlan.isSlackHuddleLikely(
            windowTitles: ["design-crit (Channel) - Acme - Slack", "Huddle in #design-crit - Slack"],
            holdsMicrophone: { micChecks += 1; return false }
        )
        assertTrue(huddleTitle, "a huddle-titled window")
        assertEqual(micChecks, 0, "the mic isn't checked when a title already says huddle")
        assertTrue(!CallSpeakerReadPlan.isSlackHuddleLikely(
            windowTitles: ["design-crit (Channel) - Acme - Slack"], holdsMicrophone: { false }
        ), "Slack open all day, off the mic, no huddle title: not walked")
        assertTrue(CallSpeakerReadPlan.isSlackHuddleLikely(
            windowTitles: ["design-crit (Channel) - Acme - Slack"], holdsMicrophone: { true }
        ), "Slack holding the mic: a huddle in a plain window")
    }

    runSuite("CallSpeakerReadPlan: Slack's own helper on the mic counts, other apps don't") {
        assertTrue(CallSpeakerReadPlan.isSlackHoldingMicrophone(micInputBundleIDs: ["com.tinyspeck.slackmacgap.helper"]), "Electron helper")
        assertTrue(CallSpeakerReadPlan.isSlackHoldingMicrophone(micInputBundleIDs: ["com.tinyspeck.slackmacgap"]), "the app itself")
        assertTrue(!CallSpeakerReadPlan.isSlackHoldingMicrophone(micInputBundleIDs: ["com.tinyspeck.slackmacgapx", "us.zoom.xos"]), "lookalikes and other apps")
        assertTrue(!CallSpeakerReadPlan.isSlackHoldingMicrophone(micInputBundleIDs: []), "nobody on the mic")
    }
}
