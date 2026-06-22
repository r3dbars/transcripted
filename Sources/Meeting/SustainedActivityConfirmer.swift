// SustainedActivityConfirmer.swift
// Pure "is this sustained, or just a blip?" gate shared by MicActivityMonitor
// and CameraActivityMonitor (docs/auto-call-detection-spec.md, aggressiveness +
// camera work).
//
// A device-activity scan tells us which keys (mic-holding bundle IDs, or a
// single camera sentinel) are active *right now*. That raw signal fires on any
// momentary access — a one-off "Hey Google" voice search, a permission probe, an
// app checking camera availability. We do not want to prompt on those. This
// helper turns the raw set into a *confirmed* set: a key is only confirmed once
// it has been continuously present for at least `sustain` seconds.
//
// It is the lightweight, on-device alternative to Plaud's deferred Phase-2 UDP
// inspection: a browser/app that holds the mic (or the camera) continuously for
// a few seconds is overwhelmingly a live call, while blips drop out before they
// ever reach the prompt. Keeping it pure (no clock, no CoreAudio/CMIO) makes the
// decision unit-testable without a live device; the monitors own the timing and
// re-scan at `nextDeadline` so a genuine call surfaces the moment it is
// confirmed rather than waiting for the next backstop poll.

import Foundation

enum SustainedActivityConfirmer {
    struct Outcome: Equatable {
        /// Keys that have been continuously active for at least `sustain`.
        let confirmed: Set<String>
        /// First-seen timestamps to carry into the next scan. Keys absent from
        /// `raw` are dropped so a key that drops out and returns must re-arm.
        let activeSince: [String: Date]
        /// Earliest moment an as-yet-unconfirmed key will become confirmed, so
        /// the caller can schedule a one-shot re-scan. `nil` when nothing is
        /// pending (everything is either confirmed or inactive).
        let nextDeadline: Date?
    }

    /// Confirms which of `raw`'s keys have been continuously present for at least
    /// `sustain` seconds, given the prior first-seen map.
    ///
    /// - A `sustain` of `0` (or negative) confirms everything immediately, which
    ///   preserves the pre-sustain "emit on first sight" behavior when desired.
    /// - First-seen is the earliest scan a key appeared in; it only resets when
    ///   the key drops out of `raw` entirely.
    static func confirm(
        raw: Set<String>,
        activeSince: [String: Date],
        now: Date,
        sustain: TimeInterval
    ) -> Outcome {
        var updatedSince: [String: Date] = [:]
        var confirmed: Set<String> = []
        var nextDeadline: Date?

        for key in raw {
            let since = activeSince[key] ?? now
            updatedSince[key] = since
            if now.timeIntervalSince(since) >= sustain {
                confirmed.insert(key)
            } else {
                let deadline = since.addingTimeInterval(sustain)
                nextDeadline = nextDeadline.map { min($0, deadline) } ?? deadline
            }
        }

        return Outcome(confirmed: confirmed, activeSince: updatedSince, nextDeadline: nextDeadline)
    }
}
