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

    runSuite("MicActivityMonitor.callOutputBundleIDs — keeps only native conferencing apps playing output") {
        let processes: [(bundleID: String?, isRunningOutput: Bool)] = [
            ("us.zoom.xos", true),
            ("com.microsoft.teams2", false),
            ("com.google.Chrome.helper", true),
            ("com.spotify.client", true),
            (nil, true),
        ]
        let users = MicActivityMonitor.callOutputBundleIDs(from: processes, ownBundleID: "com.justinbetker.draft")
        assertEqual(
            users,
            ["us.zoom.xos"],
            "only native conferencing output should count — browsers and media apps must stay invisible"
        )
    }

    runSuite("MicActivityMonitor.callOutputBundleIDs — drops our own playback, including helpers") {
        let processes: [(bundleID: String?, isRunningOutput: Bool)] = [
            ("com.justinbetker.draft", true),
            ("com.justinbetker.draft.helper", true),
            ("com.apple.FaceTime", true),
        ]
        let users = MicActivityMonitor.callOutputBundleIDs(from: processes, ownBundleID: "com.justinbetker.draft")
        assertEqual(
            users,
            ["com.apple.FaceTime"],
            "our own bundle and its helpers must never count as a detected call"
        )
    }

    runSuite("MicActivityMonitor.callOutputBundleIDs — emits an empty set when no conferencing app plays output") {
        let processes: [(bundleID: String?, isRunningOutput: Bool)] = [
            ("us.zoom.xos", false),
            ("com.spotify.client", true),
        ]
        let users = MicActivityMonitor.callOutputBundleIDs(from: processes, ownBundleID: "com.justinbetker.draft")
        assertTrue(users.isEmpty, "no conferencing output should produce the explicit empty 'inactive' set")
    }

    // MARK: - SubscriptionOutcome (codex review of PR #1640, P2: start→stop→start race)
    //
    // subscribeToDefaultInputDeviceChanges captures `startGeneration` before
    // hopping to the main actor to subscribe on DefaultInputDeviceMonitor,
    // then re-checks it once back on `queue`. These cases cover the scenarios
    // that motivated the generation check.

    runSuite("MicActivityMonitor.SubscriptionOutcome — stores when still running the same start() cycle") {
        let outcome = MicActivityMonitor.SubscriptionOutcome.decide(
            isStarted: true,
            currentGeneration: 1,
            capturedGeneration: 1
        )
        assertEqual(outcome, .store, "the common case: no stop()/restart happened while the hop was in flight")
    }

    runSuite("MicActivityMonitor.SubscriptionOutcome — drops when stop() ran before the hop finished") {
        let outcome = MicActivityMonitor.SubscriptionOutcome.decide(
            isStarted: false,
            currentGeneration: 2,
            capturedGeneration: 1
        )
        assertEqual(outcome, .dropStale, "a torn-down instance must not accumulate a dangling subscription")
    }

    runSuite("MicActivityMonitor.SubscriptionOutcome — drops a first start()'s subscription that resolves after a restart") {
        // The exact race this fix targets: start() (gen 1) begins subscribing,
        // then stop() (gen 2) then start() (gen 3) both run before the first
        // subscription's cross-actor hop resolves. `started` is true again
        // (gen 3 is running), so a naive `isStarted`-only check would store
        // the stale gen-1 token over the live gen-3 one and leak it.
        let outcome = MicActivityMonitor.SubscriptionOutcome.decide(
            isStarted: true,
            currentGeneration: 3,
            capturedGeneration: 1
        )
        assertEqual(outcome, .dropStale, "a superseded start() cycle's subscription must never overwrite the current one")
    }

    runSuite("MicActivityMonitor.SubscriptionOutcome — the current cycle's own subscription still stores after other churn") {
        // Generation 3 (the current start()) resolving against itself must
        // still store, even though earlier generations churned.
        let outcome = MicActivityMonitor.SubscriptionOutcome.decide(
            isStarted: true,
            currentGeneration: 3,
            capturedGeneration: 3
        )
        assertEqual(outcome, .store, "the live cycle's own subscription must not be collateral damage from the fix")
    }
}
