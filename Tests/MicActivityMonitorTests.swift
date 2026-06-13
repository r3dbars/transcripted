// MicActivityMonitorTests.swift
// Tests for the pure attribution + self-exclusion helpers of MicActivityMonitor.
// The CoreAudio listener itself is not unit-testable (verified live with a real
// Meet call via scripts/dev/mic-activity-spike.swift).

import Foundation

func testMicActivityMonitor() {
    guard #available(macOS 14.0, *) else { return }

    runSuite("MicActivityMonitor.micUsingBundleIDs — keeps only processes holding the mic input") {
        let processes: [(bundleID: String?, isRunningInput: Bool)] = [
            ("com.google.Chrome.helper", true),
            ("com.google.Chrome", false),
            ("com.apple.QuickTimePlayerX", false),
            (nil, true),
        ]
        let users = MicActivityMonitor.micUsingBundleIDs(from: processes, ownBundleID: "com.justinbetker.draft")
        assertEqual(users, ["com.google.Chrome.helper"], "only the process actively holding the mic should be reported")
    }

    runSuite("MicActivityMonitor.micUsingBundleIDs — drops our own capture, including helpers") {
        let processes: [(bundleID: String?, isRunningInput: Bool)] = [
            ("com.justinbetker.draft", true),
            ("com.justinbetker.draft.helper", true),
            ("com.google.Chrome.helper", true),
        ]
        let users = MicActivityMonitor.micUsingBundleIDs(from: processes, ownBundleID: "com.justinbetker.draft")
        assertEqual(
            users,
            ["com.google.Chrome.helper"],
            "our own bundle and its helpers must never count as a detected call"
        )
    }

    runSuite("MicActivityMonitor.micUsingBundleIDs — emits an empty set when nothing holds the mic (inactive edge)") {
        let processes: [(bundleID: String?, isRunningInput: Bool)] = [
            ("com.google.Chrome.helper", false),
            ("us.zoom.xos", false),
        ]
        let users = MicActivityMonitor.micUsingBundleIDs(from: processes, ownBundleID: "com.justinbetker.draft")
        assertTrue(users.isEmpty, "no active mic users should produce the explicit empty 'inactive' set")
    }

    runSuite("MicActivityMonitor.nonSelfBundleIDs — passes everything through when own bundle is unknown") {
        let users = MicActivityMonitor.nonSelfBundleIDs(["com.google.Chrome.helper"], ownBundleID: "")
        assertEqual(
            users,
            ["com.google.Chrome.helper"],
            "an empty own-bundle id should not accidentally filter real mic users"
        )
    }
}
