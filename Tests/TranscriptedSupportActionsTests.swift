import Foundation

@MainActor
func testTranscriptedSupportActions() async {
    runSuite("Support email successful handoff opens once without fallback or clipboard changes") {
        let url = URL(string: "mailto:help@transcripted.app?subject=Test")!
        var openedURLs: [URL] = []
        var fallbackCount = 0
        var copiedAddresses: [String] = []

        let opened = SupportEmailDispatcher.open(
            url,
            openURL: { openedURLs.append($0); return true },
            presentFallback: { fallbackCount += 1; return .copyAddress },
            copyAddress: { copiedAddresses.append($0) }
        )

        assertTrue(opened, "the caller may dismiss its feedback draft only after a successful handoff")
        assertEqual(openedURLs, [url], "the prepared URL must be handed off exactly once")
        assertEqual(fallbackCount, 0, "successful dispatch needs no fallback")
        assertTrue(copiedAddresses.isEmpty, "successful handoff must preserve the clipboard")
    }

    runSuite("Support email failed handoff shows fallback without silently copying") {
        var openCount = 0
        var fallbackCount = 0
        var copiedAddresses: [String] = []

        let opened = SupportEmailDispatcher.open(
            URL(string: "mailto:help@transcripted.app"),
            openURL: { _ in openCount += 1; return false },
            presentFallback: { fallbackCount += 1; return .dismiss },
            copyAddress: { copiedAddresses.append($0) }
        )

        assertFalse(opened, "a missing mail handler must not be reported as a successful handoff")
        assertEqual(openCount, 1, "do not repeatedly launch a broken mail handler")
        assertEqual(fallbackCount, 1, "dispatch failure must present a useful fallback")
        assertTrue(copiedAddresses.isEmpty, "dismissing fallback must preserve the clipboard")
    }

    runSuite("Support email copies only the address after explicit fallback choice") {
        var copiedAddresses: [String] = []

        let opened = SupportEmailDispatcher.open(
            URL(string: "mailto:help@transcripted.app?body=Private%20draft"),
            openURL: { _ in false },
            presentFallback: { .copyAddress },
            copyAddress: { copiedAddresses.append($0) }
        )

        assertFalse(opened, "copying an address is not sending or opening the prepared draft")
        assertEqual(copiedAddresses, [FeedbackIssueBuilder.supportEmailAddress], "copy only the public support address, never the draft or diagnostics")
    }

    runSuite("Support email URL preparation failure offers the same fallback") {
        var openCount = 0
        var fallbackCount = 0
        var copiedAddresses: [String] = []

        let opened = SupportEmailDispatcher.open(
            nil,
            openURL: { _ in openCount += 1; return true },
            presentFallback: { fallbackCount += 1; return .copyAddress },
            copyAddress: { copiedAddresses.append($0) }
        )

        assertFalse(opened, "a missing prepared URL must keep the draft open")
        assertEqual(openCount, 0, "there is no URL to launch")
        assertEqual(fallbackCount, 1, "URL generation failure must not silently do nothing")
        assertEqual(copiedAddresses, [FeedbackIssueBuilder.supportEmailAddress], "explicit copy should remain available without a prepared URL")
    }
}
