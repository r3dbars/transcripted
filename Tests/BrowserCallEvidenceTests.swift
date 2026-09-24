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
            "abc-defg-hij - Google Chrome",
        ]
        for title in meetTitles {
            assertEqual(
                BrowserCallEvidence.classify([BrowserWindowTitle(title: title, isFocused: false)]),
                .call(provider: .googleMeet),
                "\"\(title)\" should read as a Google Meet call, even from a background window"
            )
        }
    }

    runSuite("BrowserCallEvidence.classify — the Meet home page is only a call site") {
        assertEqual(
            BrowserCallEvidence.classify([BrowserWindowTitle(title: "Google Meet", isFocused: true)]),
            .callSite(provider: .googleMeet),
            "the Meet home page in front corroborates but does not prove a call"
        )
        assertEqual(
            BrowserCallEvidence.classify([
                BrowserWindowTitle(title: "Google Meet", isFocused: false),
                BrowserWindowTitle(title: "Hacker News", isFocused: true),
            ]),
            .unknown,
            "a Meet home page left open in the background says nothing"
        )
    }

    runSuite("BrowserCallEvidence.classify — in-call Teams and Zoom windows name their provider") {
        assertEqual(
            BrowserCallEvidence.classify([BrowserWindowTitle(title: "Meeting with Ana | Microsoft Teams", isFocused: false)]),
            .call(provider: .teams),
            "a Teams meeting window should be a Teams call"
        )
        assertEqual(
            BrowserCallEvidence.classify([BrowserWindowTitle(title: "Zoom Meeting", isFocused: false)]),
            .call(provider: .zoom),
            "the Zoom web client's call window should be a Zoom call"
        )
    }

    runSuite("BrowserCallEvidence.classify — call apps in front only corroborate") {
        assertEqual(
            BrowserCallEvidence.classify([BrowserWindowTitle(title: "Chat | Microsoft Teams", isFocused: true)]),
            .callSite(provider: .teams),
            "Teams chat in front is a call site, not a call"
        )
        assertEqual(
            BrowserCallEvidence.classify([BrowserWindowTitle(title: "Cisco Webex Meetings", isFocused: true)]),
            .callSite(provider: .webex),
            "a Webex page in front is a call site"
        )
        assertEqual(
            BrowserCallEvidence.classify([BrowserWindowTitle(title: "Huddle with Sam - Slack", isFocused: true)]),
            .callSite(provider: nil),
            "a Slack huddle is a call site with no provider of its own"
        )
    }

    runSuite("BrowserCallEvidence.classify — call apps left open in the background say nothing") {
        for title in ["Chat | Microsoft Teams", "WhatsApp", "Discord | #general", "Zoom Workplace"] {
            assertEqual(
                BrowserCallEvidence.classify([
                    BrowserWindowTitle(title: title, isFocused: false),
                    BrowserWindowTitle(title: "Hacker News", isFocused: true),
                ]),
                .unknown,
                "\"\(title)\" open in another window must not make any mic use a call"
            )
            assertEqual(
                BrowserCallEvidence.classify([
                    BrowserWindowTitle(title: title, isFocused: false),
                    BrowserWindowTitle(title: "ChatGPT", isFocused: true),
                ]),
                .notCall,
                "a focused ChatGPT window beats \"\(title)\" in the background"
            )
        }
    }

    runSuite("BrowserCallEvidence.classify — near-miss titles are not calls") {
        assertEqual(
            BrowserCallEvidence.classify([
                BrowserWindowTitle(title: "Meet: new hire onboarding - you@example.com - Gmail", isFocused: false),
                BrowserWindowTitle(title: "ChatGPT", isFocused: true),
            ]),
            .notCall,
            "a Gmail subject that starts with Meet is not a Meet tab"
        )
        assertEqual(
            BrowserCallEvidence.classify([BrowserWindowTitle(title: "Zoom Meetings - Zoom Support", isFocused: true)]),
            .callSite(provider: .zoom),
            "a Zoom help page is a call site at most, not the Zoom web client"
        )
        assertEqual(
            BrowserCallEvidence.classify([BrowserWindowTitle(title: "Zoom Meeting - Google Chrome", isFocused: false)]),
            .call(provider: .zoom),
            "the Zoom web client with the browser's suffix is still a Zoom call"
        )
        assertEqual(
            BrowserCallEvidence.classify([BrowserWindowTitle(title: "Bloomberg Markets", isFocused: true)]),
            .unknown,
            "markers match whole words: Bloomberg is not Loom"
        )
        assertEqual(
            BrowserCallEvidence.classify([BrowserWindowTitle(title: "Copilot | Microsoft Teams", isFocused: true)]),
            .callSite(provider: .teams),
            "a call app in front beats a non-call word in its title"
        )
    }

    runSuite("BrowserCallEvidence.classify — mail and calendar subjects are not calls") {
        assertEqual(
            BrowserCallEvidence.classify([
                BrowserWindowTitle(title: "Zoom meeting invitation - ana@example.com - Gmail", isFocused: false),
                BrowserWindowTitle(title: "ChatGPT", isFocused: true),
            ]),
            .notCall,
            "an invite open in Gmail is not a Zoom call"
        )
        assertEqual(
            BrowserCallEvidence.classify([BrowserWindowTitle(title: "Zoom meeting with Ana - Google Calendar", isFocused: true)]),
            .unknown,
            "a calendar event page is not the call itself"
        )
        assertEqual(
            BrowserCallEvidence.classify([BrowserWindowTitle(title: "Meet - Q3 calendar planning", isFocused: false)]),
            .call(provider: .googleMeet),
            "a Meet named after a calendar topic is still a Meet tab"
        )
        assertEqual(
            BrowserCallEvidence.classify([BrowserWindowTitle(title: "Mail - Outlook", isFocused: true)]),
            .unknown,
            "a mail window is neither a call nor a call site"
        )
    }

    runSuite("BrowserCallEvidence.classify — voice assistants and recorders are not calls") {
        for title in ["ChatGPT", "Claude", "Loom | Free Screen & Video Recording Software", "Online Mic Test"] {
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

    runSuite("BrowserCallEvidence.classify — pages people keep open during a call are unknown") {
        for title in ["Untitled document - Google Docs", "Lo-fi beats - YouTube"] {
            assertEqual(
                BrowserCallEvidence.classify([BrowserWindowTitle(title: title, isFocused: true)]),
                .unknown,
                "\"\(title)\" in front during a call must not make the call a non-call"
            )
        }
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
    }

    runSuite("BrowserCallEvidence.decide — a call site in front gets the short wait") {
        assertEqual(
            BrowserCallEvidence.decide(
                verdict: .callSite(provider: .teams),
                cameraInUse: false,
                browserPlayingAudio: false,
                micSince: start,
                now: start.addingTimeInterval(5)
            ),
            .wait(recheckAt: start.addingTimeInterval(BrowserCallEvidence.corroboratedDelay)),
            "Teams chat in front is not proof, so it waits like other corroboration"
        )
        assertEqual(
            BrowserCallEvidence.decide(
                verdict: .callSite(provider: .teams),
                cameraInUse: false,
                browserPlayingAudio: false,
                micSince: start,
                now: start.addingTimeInterval(BrowserCallEvidence.corroboratedDelay)
            ),
            .prompt(provider: .teams, evidence: .callSite),
            "after the short wait it prompts as a call site"
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

    runSuite("MeetingPromptCallEvidence — named vs guessed browser evidence") {
        assertTrue(MeetingPromptCallEvidence.tabTitle.isNamedBrowserCall, "a call-only tab title names the call")
        assertFalse(MeetingPromptCallEvidence.callSite.isNamedBrowserCall, "a call site in front does not")
        assertTrue(MeetingPromptCallEvidence.callSite.isBrowserCall, "a call site is still a browser call")
        assertTrue(MeetingPromptCallEvidence.camera.isUnverifiedBrowserCall, "the camera only corroborates")
        assertTrue(MeetingPromptCallEvidence.micOnly.isUnverifiedBrowserCall, "time on the mic is a guess")
        assertFalse(MeetingPromptCallEvidence.nativeApp.isBrowserCall, "a native app is not a browser call")
        assertFalse(MeetingPromptCallEvidence.none.isBrowserCall, "no evidence is not a browser call")
        assertFalse(MeetingPromptCallEvidence.nonCallSite.isBrowserCall, "a non-call site never prompts")
    }

    runSuite("MeetingPromptCallEvidence — only a certain provider is quieted on Not now") {
        assertTrue(MeetingPromptCallEvidence.nativeApp.quietsProviderOnDismiss, "Not now to native Zoom quiets Zoom")
        assertTrue(MeetingPromptCallEvidence.tabTitle.quietsProviderOnDismiss, "Not now to a Meet tab quiets Meet")
        for evidence in [MeetingPromptCallEvidence.callSite, .camera, .micAndOutput, .micOnly] {
            assertFalse(
                evidence.quietsProviderOnDismiss,
                "Not now to a \(evidence.rawValue) guess must not hide a real call of that provider"
            )
        }
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
