// BrowserCallEvidenceTests.swift
// Pins the "is this browser mic use really a call?" rules behind the
// detected-call prompt: which window titles name a call, which sites never
// prompt, and how long an unrecognized browser has to hold the mic.

import Foundation

func testBrowserCallEvidence() {
    guard #available(macOS 14.0, *) else { return }

    runSuite("BrowserCallEvidence.classify — Meet tab titles name Google Meet") {
        let meetTitles = [
            "Meet - abc-defg-hij",
            "Meet \u{2013} Weekly design sync - Google Chrome - Work",
            "(2) Meet - abc-defg-hij",
            "Google Meet",
            "abc-defg-hij - Google Chrome",
        ]
        for title in meetTitles {
            assertEqual(
                BrowserCallEvidence.classify([BrowserWindowTitle(title: title, isFocused: true)]),
                .call(provider: .googleMeet),
                "\"\(title)\" should read as a Google Meet call"
            )
        }
    }

    runSuite("BrowserCallEvidence.classify — other web call surfaces keep their provider") {
        assertEqual(
            BrowserCallEvidence.classify([BrowserWindowTitle(title: "Meeting with Ana | Microsoft Teams", isFocused: true)]),
            .call(provider: .teams),
            "a Teams web tab should be a Teams call"
        )
        assertEqual(
            BrowserCallEvidence.classify([BrowserWindowTitle(title: "Zoom Meeting", isFocused: false)]),
            .call(provider: .zoom),
            "a Zoom web client tab should be a Zoom call"
        )
        assertEqual(
            BrowserCallEvidence.classify([BrowserWindowTitle(title: "Cisco Webex Meetings", isFocused: true)]),
            .call(provider: .webex),
            "a Webex tab should be a Webex call"
        )
        assertEqual(
            BrowserCallEvidence.classify([BrowserWindowTitle(title: "Huddle with Sam - Slack", isFocused: true)]),
            .call(provider: nil),
            "a Slack huddle is a call even though it has no provider of its own"
        )
    }

    runSuite("BrowserCallEvidence.classify — voice assistants and recorders are not calls") {
        for title in ["ChatGPT", "Claude", "Loom | Free Screen & Video Recording Software", "Untitled document - Google Docs"] {
            assertEqual(
                BrowserCallEvidence.classify([BrowserWindowTitle(title: title, isFocused: true)]),
                .notCall,
                "a focused \"\(title)\" window should not read as a call"
            )
        }
    }

    runSuite("BrowserCallEvidence.classify — a call tab anywhere beats a focused non-call site") {
        let windows = [
            BrowserWindowTitle(title: "ChatGPT", isFocused: true),
            BrowserWindowTitle(title: "Meet - abc-defg-hij", isFocused: false),
        ]
        assertEqual(
            BrowserCallEvidence.classify(windows),
            .call(provider: .googleMeet),
            "the Meet tab in a background window is where the mic is; ChatGPT in front must not hide it"
        )
    }

    runSuite("BrowserCallEvidence.classify — only the focused window can say not a call") {
        let windows = [
            BrowserWindowTitle(title: "ChatGPT", isFocused: false),
            BrowserWindowTitle(title: "Hacker News", isFocused: true),
        ]
        assertEqual(
            BrowserCallEvidence.classify(windows),
            .unknown,
            "a ChatGPT window in the background says nothing about who holds the mic"
        )
    }

    runSuite("BrowserCallEvidence.classify — ordinary pages and no titles are unknown") {
        assertEqual(BrowserCallEvidence.classify([]), .unknown, "no titles (Accessibility off) is unknown, not a call")
        assertEqual(
            BrowserCallEvidence.classify([BrowserWindowTitle(title: "How to meet-cute: the-best-way-to-cook", isFocused: true)]),
            .unknown,
            "a 3-4-3 slug inside an ordinary title must not look like a Meet code"
        )
        assertEqual(
            BrowserCallEvidence.classify([BrowserWindowTitle(title: "Meeting notes - Notion", isFocused: true)]),
            .unknown,
            "the word meeting on its own is not a call surface"
        )
    }

    let start = Date(timeIntervalSince1970: 10_000)

    runSuite("BrowserCallEvidence.decide — a named call tab prompts right away") {
        assertEqual(
            BrowserCallEvidence.decide(
                verdict: .call(provider: .googleMeet),
                cameraInUse: false,
                browserPlayingAudio: false,
                micSince: start,
                now: start
            ),
            .prompt(provider: .googleMeet, evidence: .tabTitle),
            "a Meet tab holding the mic is a call now, with no wait"
        )
        assertEqual(
            BrowserCallEvidence.decide(
                verdict: .call(provider: nil),
                cameraInUse: false,
                browserPlayingAudio: false,
                micSince: start,
                now: start
            ),
            .prompt(provider: nil, evidence: .callSite),
            "a call site with no provider still prompts now, as a generic browser call"
        )
    }

    runSuite("BrowserCallEvidence.decide — a known non-call site never prompts") {
        assertEqual(
            BrowserCallEvidence.decide(
                verdict: .notCall,
                cameraInUse: true,
                browserPlayingAudio: true,
                micSince: start,
                now: start.addingTimeInterval(600)
            ),
            .notACall,
            "ChatGPT voice talking back for ten minutes is still not a call"
        )
    }

    runSuite("BrowserCallEvidence.decide — an unknown site with only the mic waits a minute") {
        assertEqual(
            BrowserCallEvidence.decide(verdict: .unknown, cameraInUse: false, browserPlayingAudio: false, micSince: start, now: start),
            .wait(recheckAt: start.addingTimeInterval(BrowserCallEvidence.titleRecheckInterval)),
            "while waiting, titles are re-read on the short recheck cadence"
        )
        assertEqual(
            BrowserCallEvidence.decide(
                verdict: .unknown,
                cameraInUse: false,
                browserPlayingAudio: false,
                micSince: start,
                now: start.addingTimeInterval(50)
            ),
            .wait(recheckAt: start.addingTimeInterval(BrowserCallEvidence.uncorroboratedDelay)),
            "the last recheck lands exactly when the wait runs out"
        )
        assertEqual(
            BrowserCallEvidence.decide(
                verdict: .unknown,
                cameraInUse: false,
                browserPlayingAudio: false,
                micSince: start,
                now: start.addingTimeInterval(BrowserCallEvidence.uncorroboratedDelay)
            ),
            .prompt(provider: nil, evidence: .micOnly),
            "a minute of continuous browser mic use prompts as a generic browser call"
        )
    }

    runSuite("BrowserCallEvidence.decide — audio playing back or the camera shortens the wait") {
        assertEqual(
            BrowserCallEvidence.decide(
                verdict: .unknown,
                cameraInUse: false,
                browserPlayingAudio: true,
                micSince: start,
                now: start.addingTimeInterval(BrowserCallEvidence.corroboratedDelay)
            ),
            .prompt(provider: nil, evidence: .micAndOutput),
            "the browser also playing audio is someone talking back"
        )
        assertEqual(
            BrowserCallEvidence.decide(
                verdict: .unknown,
                cameraInUse: true,
                browserPlayingAudio: false,
                micSince: start,
                now: start.addingTimeInterval(BrowserCallEvidence.corroboratedDelay)
            ),
            .prompt(provider: nil, evidence: .camera),
            "the camera corroborates but is not proof, so it gets the same short wait"
        )
        assertEqual(
            BrowserCallEvidence.decide(
                verdict: .unknown,
                cameraInUse: true,
                browserPlayingAudio: false,
                micSince: start,
                now: start.addingTimeInterval(5)
            ),
            .wait(recheckAt: min(
                start.addingTimeInterval(BrowserCallEvidence.corroboratedDelay),
                start.addingTimeInterval(5 + BrowserCallEvidence.titleRecheckInterval)
            )),
            "the camera alone must not prompt before the wait"
        )
        assertTrue(
            BrowserCallEvidence.corroboratedDelay < BrowserCallEvidence.uncorroboratedDelay,
            "corroborated browser mic use should prompt sooner than bare mic use"
        )
        assertTrue(
            BrowserCallEvidence.corroboratedDelay >= 15,
            "voice search and short dictation must never reach the corroborated wait"
        )
    }

    runSuite("MeetingPromptCallEvidence — verified vs unverified browser evidence") {
        assertTrue(MeetingPromptCallEvidence.tabTitle.isVerifiedBrowserCall, "a named call tab is verified")
        assertTrue(MeetingPromptCallEvidence.callSite.isVerifiedBrowserCall, "a call site title is verified")
        assertTrue(MeetingPromptCallEvidence.camera.isUnverifiedBrowserCall, "the camera only corroborates")
        assertTrue(MeetingPromptCallEvidence.micOnly.isUnverifiedBrowserCall, "time on the mic is a guess")
        assertFalse(MeetingPromptCallEvidence.nativeApp.isBrowserCall, "a native app is not a browser call")
        assertFalse(MeetingPromptCallEvidence.none.isBrowserCall, "no evidence is not a browser call")
    }

    runSuite("MeetingPromptProvider.browserFamily — helpers line up with their browser app") {
        assertEqual(MeetingPromptProvider.browserFamily(forBundleID: "com.google.Chrome.helper"), "com.google.Chrome", "a Chrome helper belongs to Chrome")
        assertEqual(MeetingPromptProvider.browserFamily(forBundleID: "com.apple.WebKit.GPU"), "com.apple.WebKit", "Safari audio runs in WebKit")
        assertEqual(MeetingPromptProvider.browserFamily(forBundleID: "us.zoom.xos"), nil, "a native app is not a browser")
        assertEqual(
            MeetingPromptProvider.browserAppFamily(forBundleFamily: "com.apple.WebKit"),
            "com.apple.Safari",
            "WebKit's windows are Safari's"
        )
        assertEqual(
            MeetingPromptProvider.browserAppFamily(forBundleFamily: "com.google.Chrome"),
            "com.google.Chrome",
            "Chrome's windows are its own"
        )
    }
}
