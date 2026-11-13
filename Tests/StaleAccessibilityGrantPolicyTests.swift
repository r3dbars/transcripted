// StaleAccessibilityGrantPolicyTests.swift
//
// A reinstall can leave macOS holding an old Accessibility grant: the app
// reads as trusted, but the ⌘V paste-back posts never arrives, so every paste
// ends "not confirmed" with nothing reading the clipboard. These suites check
// when the "re-grant Accessibility" notice shows, and when the streak resets.
// Pure values only: whether a real stale grant drops ⌘V this way needs a
// hands-on check on a Mac with a reinstalled build.

import Foundation

func testStaleAccessibilityGrantPolicy() {
    runStaleAccessibilityGrantPolicySuites()
}

private let unconfirmed = TextPasteOutcome.copied("Couldn't confirm the paste.", reason: .pasteNotConfirmed)

private func unconfirmedWithoutRead(_ targetID: String?) -> StaleAccessibilityGrantTracker.Observation {
    StaleAccessibilityGrantTracker.observation(outcome: unconfirmed, pasteEvidence: "none", targetID: targetID)
}

private func runStaleAccessibilityGrantPolicySuites() {
    runSuite("Three unconfirmed pastes no app read, across two apps, suggest re-granting Accessibility") {
        var tracker = StaleAccessibilityGrantTracker()
        tracker.record(unconfirmedWithoutRead("app.one"))
        assertFalse(tracker.suggestsRegrant, "one miss is not a pattern")
        tracker.record(unconfirmedWithoutRead("app.two"))
        assertFalse(tracker.suggestsRegrant, "two misses are not enough")
        tracker.record(unconfirmedWithoutRead("app.one"))
        assertTrue(tracker.suggestsRegrant, "third miss across two apps shows the hint")
        tracker.record(unconfirmedWithoutRead("app.two"))
        assertTrue(tracker.suggestsRegrant, "the hint stays while the misses continue")
    }

    runSuite("Misses in only one app never suggest a re-grant") {
        var tracker = StaleAccessibilityGrantTracker()
        for _ in 0..<6 {
            tracker.record(unconfirmedWithoutRead("app.one"))
        }
        assertFalse(tracker.suggestsRegrant, "one app with no text box can't trip it")
        tracker.record(unconfirmedWithoutRead(nil))
        assertFalse(tracker.suggestsRegrant, "an unknown target is not a second app")
    }

    runSuite("A paste that lands resets the streak") {
        for landed in [TextPasteOutcome.pasted, .likelyPasted] {
            var tracker = StaleAccessibilityGrantTracker()
            tracker.record(unconfirmedWithoutRead("app.one"))
            tracker.record(unconfirmedWithoutRead("app.two"))
            tracker.record(unconfirmedWithoutRead("app.one"))
            assertTrue(tracker.suggestsRegrant)
            tracker.record(StaleAccessibilityGrantTracker.observation(
                outcome: landed, pasteEvidence: nil, targetID: "app.one"
            ))
            assertFalse(tracker.suggestsRegrant, "\(landed) clears the hint")
            tracker.record(unconfirmedWithoutRead("app.two"))
            tracker.record(unconfirmedWithoutRead("app.one"))
            assertFalse(tracker.suggestsRegrant, "the count starts over after \(landed)")
        }
    }

    runSuite("An unconfirmed paste that an app read after ⌘V proves it arrived and resets") {
        for evidence in ["clipboard_read", nil] as [String?] {
            assertEqual(
                StaleAccessibilityGrantTracker.observation(outcome: unconfirmed, pasteEvidence: evidence, targetID: "app.one"),
                .pasteReachedTarget,
                "evidence \(evidence ?? "missing") is not a lost keystroke"
            )
        }
        assertEqual(
            StaleAccessibilityGrantTracker.observation(
                outcome: unconfirmed, pasteEvidence: "read_outside_window",
                clipboardReadAfterDispatch: "true", targetID: "app.one"
            ),
            .pasteReachedTarget,
            "a late read after ⌘V means the keystroke arrived"
        )
        var tracker = StaleAccessibilityGrantTracker()
        tracker.record(unconfirmedWithoutRead("app.one"))
        tracker.record(unconfirmedWithoutRead("app.two"))
        tracker.record(StaleAccessibilityGrantTracker.observation(
            outcome: unconfirmed, pasteEvidence: "clipboard_read", targetID: "app.one"
        ))
        tracker.record(unconfirmedWithoutRead("app.one"))
        assertFalse(tracker.suggestsRegrant, "a read in the middle breaks the run")
    }

    runSuite("A clipboard read before ⌘V neither counts nor breaks the streak") {
        // A clipboard history app can read the borrowed text before ⌘V is
        // sent. Only that first read is stamped, so it says nothing about
        // whether the keystroke landed.
        for afterDispatch in ["false", nil] as [String?] {
            assertEqual(
                StaleAccessibilityGrantTracker.observation(
                    outcome: unconfirmed, pasteEvidence: "read_outside_window",
                    clipboardReadAfterDispatch: afterDispatch, targetID: "app.one"
                ),
                .unrelated,
                "read before ⌘V (after_dispatch \(afterDispatch ?? "missing")) is not proof either way"
            )
        }
        var tracker = StaleAccessibilityGrantTracker()
        tracker.record(unconfirmedWithoutRead("app.one"))
        tracker.record(unconfirmedWithoutRead("app.two"))
        tracker.record(StaleAccessibilityGrantTracker.observation(
            outcome: unconfirmed, pasteEvidence: "read_outside_window",
            clipboardReadAfterDispatch: "false", targetID: "app.one"
        ))
        assertFalse(tracker.suggestsRegrant, "the early read doesn't add to the streak")
        tracker.record(unconfirmedWithoutRead("app.one"))
        assertTrue(tracker.suggestsRegrant, "and it doesn't wipe it either")
    }

    runSuite("Accessibility reported off resets; other copy and failure reasons don't count or reset") {
        var tracker = StaleAccessibilityGrantTracker()
        tracker.record(unconfirmedWithoutRead("app.one"))
        tracker.record(unconfirmedWithoutRead("app.two"))
        let unrelated: [TextPasteOutcome] = [
            .copied("moved", reason: .focusChanged),
            .copied("no event", reason: .pasteEventCreationFailed),
            .failed("busy", reason: .clipboardSnapshotIncomplete(.tooLarge)),
            .failed("cancelled", reason: .cancelled),
        ]
        for outcome in unrelated {
            assertEqual(
                StaleAccessibilityGrantTracker.observation(outcome: outcome, pasteEvidence: "none", targetID: "app.three"),
                .unrelated
            )
            tracker.record(StaleAccessibilityGrantTracker.observation(
                outcome: outcome, pasteEvidence: "none", targetID: "app.three"
            ))
        }
        assertFalse(tracker.suggestsRegrant, "unrelated outcomes don't add to the streak")
        tracker.record(unconfirmedWithoutRead("app.one"))
        assertTrue(tracker.suggestsRegrant, "and they don't break it either")

        tracker.record(StaleAccessibilityGrantTracker.observation(
            outcome: .copied("off", reason: .accessibilityMissing), pasteEvidence: nil, targetID: "app.one"
        ))
        assertFalse(tracker.suggestsRegrant, "Accessibility off has its own notice")
    }

    runSuite("The island hint fits on its one line") {
        // The not-pasted hint is a single clipped label; the existing hints
        // run up to about 52 characters.
        assertTrue(StaleAccessibilityGrantCopy.islandHint.count <= 52, "hint is \(StaleAccessibilityGrantCopy.islandHint.count) chars")
        assertTrue(StaleAccessibilityGrantCopy.fallbackMessage.contains("⌘V"), "the fallback still says how to paste")
    }
}
