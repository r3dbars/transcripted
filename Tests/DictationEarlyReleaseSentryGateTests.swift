// Sentry issue 2J: a dictation hotkey that ends the start before the mic is
// ready. Quick Push to Talk taps (the user is told to hold the key) were most
// of its volume, so they stay out of Sentry. Every early release still counts
// in PostHog as `reliability_failure_observed`.
//
// `DictationEarlyReleaseCancelReport` and `ObservabilityEventCapturePlan`
// (what EventReporter.capture sends where) are both in run-tests.sh's
// APP_SOURCES, so the plan here is the one the controller's call produces.

import Foundation

func testDictationEarlyReleaseSentryGate() {
    /// The plan for the event the controller records, built from the same
    /// report helpers the controller calls.
    func plan(_ mode: DictationShortcutMode?, pendingForMs: Int) -> ObservabilityEventCapturePlan {
        ObservabilityEventCapturePlan.make(
            level: DictationEarlyReleaseCancelReport.level,
            engine: DictationEarlyReleaseCancelReport.engine,
            event: DictationEarlyReleaseCancelReport.event,
            message: DictationEarlyReleaseCancelReport.message,
            context: DictationEarlyReleaseCancelReport.context(
                trigger: "physical_key",
                shortcutMode: mode,
                pendingForMs: pendingForMs,
                pendingStage: "opening_microphone",
                stagePendingForMs: pendingForMs,
                startPlan: "background",
                appActive: false
            ),
            engineState: nil,
            infoDictionary: nil,
            timestamp: "2026-10-05T12:00:00.000Z",
            appVersion: "1.2.3",
            osVersion: "Version 26.0",
            forwardToSentry: DictationEarlyReleaseCancelReport.forwardsToSentry(
                shortcutMode: mode,
                pendingForMs: pendingForMs
            )
        )
    }

    func message(_ mode: DictationShortcutMode?, pendingForMs: Int) -> String {
        DictationEarlyReleasePresentationPolicy.message(shortcutMode: mode, pendingForMs: pendingForMs)
    }

    let threshold = DictationEarlyReleasePresentationPolicy.shortTapThresholdMs

    runSuite("A quick Push to Talk tap stays out of Sentry but still counts in PostHog") {
        let tap = plan(.pushToTalk, pendingForMs: 72)
        assertEqual(
            message(.pushToTalk, pendingForMs: 72),
            DictationEarlyReleasePresentationPolicy.shortTapMessage,
            "the user is told to hold the key, not that the mic failed"
        )
        assertFalse(tap.forwardsToSentry, "a tapped key is not a mic failure, so Sentry never sees it")
        assertNotNil(tap.sentryPolicy, "the reliability_failure_observed PostHog event still goes out")
        assertEqual(tap.entry.level, EventLevel.error.rawValue, "the event keeps its .error level")
        assertEqual(tap.mergedContext["failure_kind"], "microphone_not_ready", "PostHog keeps the same failure kind")
        assertEqual(tap.mergedContext["shortcut_mode"], "push_to_talk", "and the same shortcut mode")

        let justUnder = plan(.pushToTalk, pendingForMs: threshold - 1)
        assertFalse(justUnder.forwardsToSentry, "one millisecond under the tap threshold is still a tap")
        assertNotNil(justUnder.sentryPolicy, "and still counted")
    }

    runSuite("A slow Push to Talk release reaches Sentry with the mic-not-ready message") {
        for pendingForMs in [threshold, 2870] {
            let slow = plan(.pushToTalk, pendingForMs: pendingForMs)
            assertEqual(
                message(.pushToTalk, pendingForMs: pendingForMs),
                DictationEarlyReleasePresentationPolicy.microphoneNotReadyMessage,
                "a \(pendingForMs) ms hold is told the mic wasn't ready"
            )
            assertTrue(slow.forwardsToSentry, "a \(pendingForMs) ms Push to Talk release must reach Sentry")
            assertNotNil(slow.sentryPolicy, "and still counts in PostHog")
        }
    }

    runSuite("A Hands-Free second press reaches Sentry however fast it was") {
        for pendingForMs in [40, 2870] {
            let press = plan(.handsFree, pendingForMs: pendingForMs)
            assertEqual(
                message(.handsFree, pendingForMs: pendingForMs),
                DictationEarlyReleasePresentationPolicy.microphoneNotReadyMessage,
                "hands-free is never told to hold the key"
            )
            assertTrue(press.forwardsToSentry, "a \(pendingForMs) ms hands-free press must reach Sentry")
            assertNotNil(press.sentryPolicy, "and still counts in PostHog")
        }
        let unknownMode = plan(nil, pendingForMs: 40)
        assertTrue(unknownMode.forwardsToSentry, "a release with no known mode is shown mic-not-ready, so it forwards")
    }

    runSuite("Every other caller keeps the old Sentry routing") {
        let allowlisted = ObservabilityEventCapturePlan.make(
            level: DictationEarlyReleaseCancelReport.level,
            engine: DictationEarlyReleaseCancelReport.engine,
            event: DictationEarlyReleaseCancelReport.event,
            message: DictationEarlyReleaseCancelReport.message,
            context: nil,
            engineState: nil,
            infoDictionary: nil,
            timestamp: "2026-10-05T12:00:00.000Z",
            appVersion: "1.2.3",
            osVersion: "Version 26.0"
        )
        assertNotNil(allowlisted.sentryPolicy, "an allowlisted .error is counted")
        assertTrue(allowlisted.forwardsToSentry, "and with the default flag it still goes to Sentry")

        let notAllowlisted = ObservabilityEventCapturePlan.make(
            level: .error,
            engine: "dictation",
            event: "not_an_allowlisted_event",
            message: "x",
            context: nil,
            engineState: nil,
            infoDictionary: nil,
            timestamp: "2026-10-05T12:00:00.000Z",
            appVersion: "1.2.3",
            osVersion: "Version 26.0"
        )
        assertNil(notAllowlisted.sentryPolicy, "outside the allowlist there is no failure count")
        assertFalse(notAllowlisted.forwardsToSentry, "and the default flag doesn't open Sentry to it")
    }
}
