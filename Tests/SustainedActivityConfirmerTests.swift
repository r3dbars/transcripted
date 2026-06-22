// SustainedActivityConfirmerTests.swift
// Tests for the pure "is this sustained, or a blip?" gate shared by the mic and
// camera activity monitors.

import Foundation

func testSustainedActivityConfirmer() {
    let now = Date(timeIntervalSince1970: 1_000)
    let sustain: TimeInterval = 3

    runSuite("SustainedActivityConfirmer — a freshly seen key is not confirmed yet and arms a deadline") {
        let outcome = SustainedActivityConfirmer.confirm(
            raw: ["com.google.Chrome.helper"],
            activeSince: [:],
            now: now,
            sustain: sustain
        )
        assertTrue(outcome.confirmed.isEmpty, "a key seen for the first time should not be confirmed until it is sustained")
        assertEqual(outcome.activeSince["com.google.Chrome.helper"], now, "first-seen time should be recorded as now")
        assertEqual(outcome.nextDeadline, now.addingTimeInterval(sustain), "the deadline should be sustain seconds after first sight")
    }

    runSuite("SustainedActivityConfirmer — a key held past the sustain window is confirmed and clears the deadline") {
        let outcome = SustainedActivityConfirmer.confirm(
            raw: ["com.google.Chrome.helper"],
            activeSince: ["com.google.Chrome.helper": now.addingTimeInterval(-sustain)],
            now: now,
            sustain: sustain
        )
        assertEqual(outcome.confirmed, ["com.google.Chrome.helper"], "a key continuously present for >= sustain should be confirmed")
        assertNil(outcome.nextDeadline, "nothing is pending once the only key is confirmed")
    }

    runSuite("SustainedActivityConfirmer — a key that drops out of raw re-arms next time it appears") {
        let first = SustainedActivityConfirmer.confirm(
            raw: ["us.zoom.xos"],
            activeSince: ["us.zoom.xos": now.addingTimeInterval(-10)],
            now: now,
            sustain: sustain
        )
        assertEqual(first.confirmed, ["us.zoom.xos"], "the long-held key is confirmed")

        // The key disappears, then comes back: its first-seen must reset, not
        // resume from the stale 10s-ago timestamp.
        let gone = SustainedActivityConfirmer.confirm(raw: [], activeSince: first.activeSince, now: now, sustain: sustain)
        assertTrue(gone.activeSince.isEmpty, "a key absent from raw must be dropped so it has to re-arm")

        let returned = SustainedActivityConfirmer.confirm(
            raw: ["us.zoom.xos"],
            activeSince: gone.activeSince,
            now: now.addingTimeInterval(1),
            sustain: sustain
        )
        assertTrue(returned.confirmed.isEmpty, "a key that returned must serve the full sustain window again, not inherit old credit")
    }

    runSuite("SustainedActivityConfirmer — mixed keys confirm independently and report the earliest pending deadline") {
        let outcome = SustainedActivityConfirmer.confirm(
            raw: ["old", "new"],
            activeSince: ["old": now.addingTimeInterval(-sustain)],
            now: now,
            sustain: sustain
        )
        assertEqual(outcome.confirmed, ["old"], "only the sustained key should be confirmed")
        assertEqual(outcome.nextDeadline, now.addingTimeInterval(sustain), "the deadline should track the still-pending key")
    }

    runSuite("SustainedActivityConfirmer — a zero sustain confirms immediately (legacy emit-on-sight)") {
        let outcome = SustainedActivityConfirmer.confirm(
            raw: ["com.apple.WebKit.GPU"],
            activeSince: [:],
            now: now,
            sustain: 0
        )
        assertEqual(outcome.confirmed, ["com.apple.WebKit.GPU"], "a zero sustain should confirm on first sight")
        assertNil(outcome.nextDeadline, "nothing is pending when everything confirms immediately")
    }

    runSuite("SustainedActivityConfirmer — empty raw yields the inactive edge") {
        let outcome = SustainedActivityConfirmer.confirm(raw: [], activeSince: [:], now: now, sustain: sustain)
        assertTrue(outcome.confirmed.isEmpty, "no activity should confirm nothing")
        assertTrue(outcome.activeSince.isEmpty, "no activity should track nothing")
        assertNil(outcome.nextDeadline, "no activity should arm no deadline")
    }
}
