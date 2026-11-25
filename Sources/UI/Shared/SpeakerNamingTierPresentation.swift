// SpeakerNamingTierPresentation.swift
// The words around a person's voice print (one ring per confirmed meeting; a
// full print means Transcripted names them on its own), shared by the notch
// island's speaker review and Settings › Speakers so both say exactly the same
// thing. Foundation-only so the fast tests can compile it. The print's color is
// the person's identity (VoicePrintStyle), never their status: status is how
// many rings are lit, plus these words.

import Foundation
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif

enum SpeakerNamingTierPresentation {
    /// Segments in the dial. Matches the standard bar, so one segment is one
    /// confirmed meeting outside a lineup.
    static let segmentCount = 5

    /// Filled segments out of `segmentCount`. On a meeting whose bar is lower
    /// than 5 (a live meeting's lineup), the dial scales so reaching that bar
    /// fills it.
    static func filledSegments(confirmed: Int, required: Int, tier: SpeakerNamingTier) -> Int {
        if tier == .auto { return segmentCount }
        let bar = max(1, required)
        let scaled = Int((Double(max(0, confirmed)) / Double(bar) * Double(segmentCount)).rounded(.down))
        return min(segmentCount - 1, max(0, scaled))
    }

    /// The hover text and VoiceOver hint. `name` is the saved display name.
    static func explanation(name: String, confirmed: Int, required: Int, tier: SpeakerNamingTier, isTrusted: Bool) -> String {
        let first = firstName(name)
        let meetings = { (count: Int) in count == 1 ? "1 meeting" : "\(count) meetings" }
        let contextual = max(1, required) < segmentCount
        let scope = contextual ? " with matching meeting context" : ""
        switch tier {
        case .auto:
            let match = contextual ? "when the voice is a clear match and meeting context supports it" : "when the voice is a clear match"
            return "Confirmed in \(meetings(confirmed)). Transcripted names \(first) on its own \(match)."
        case .learning where !isTrusted:
            return "A recent correction paused auto-naming for \(first). Keep confirming \(first) until the voice is a clear match again."
        case .learning, .new:
            let left = max(0, required - confirmed)
            if left == 1 {
                return "Confirmed in \(meetings(confirmed)). One more and Transcripted names \(first) on its own\(scope)."
            }
            if confirmed == 0 {
                return "Not confirmed yet. After \(meetings(required)), Transcripted names \(first) on its own\(scope)."
            }
            return "Confirmed in \(confirmed) of \(required) meetings. \(left) more and Transcripted names \(first) on its own\(scope)."
        }
    }

    private static func firstName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? name
    }

    // MARK: - Speaker review lines

    /// Where a review row is: still asking "Marcus Reed?", answered Yes, or
    /// a voice just named in place.
    enum ReviewMoment: Equatable { case asking, confirmed, savedNew }

    struct ReviewHint: Equatable {
        let text: String
        /// Drawn in the person's print color (a "splash" for a payoff moment);
        /// otherwise secondary text.
        let usesPersonColor: Bool
    }

    /// The short line under a name in the review, or nil for none. One
    /// format everywhere: "4 of 5" (confirmed meetings out of the bar), then
    /// "Auto" once Transcripted names them on its own. The long sentence
    /// (and any "meeting context") lives in the hover tip, `explanation`.
    /// `confirmedBefore` is the count before this review.
    static func reviewHint(moment: ReviewMoment, confirmedBefore: Int, required: Int, isTrusted: Bool, earnsConfirmation: Bool = true) -> ReviewHint? {
        let bar = max(1, required)
        let before = max(0, confirmedBefore)
        switch moment {
        case .asking:
            // Nothing to count yet, or on probation: no number to promise.
            guard earnsConfirmation, isTrusted, before > 0, before < bar else { return nil }
            return ReviewHint(text: progressText(confirmed: before, required: bar), usesPersonColor: bar - before == 1)
        case .confirmed:
            let after = before + (earnsConfirmation ? 1 : 0)
            if after >= bar {
                // Past the bar on probation, a yes restores trust over time; don't
                // promise auto-naming that the health check may still withhold.
                return isTrusted ? ReviewHint(text: autoText, usesPersonColor: true) : nil
            }
            return ReviewHint(text: progressText(confirmed: after, required: bar), usesPersonColor: false)
        case .savedNew:
            guard bar > 1 else { return nil }
            return ReviewHint(text: progressText(confirmed: 1, required: bar), usesPersonColor: false)
        }
    }

    /// "4 of 5": confirmed meetings out of the bar.
    static func progressText(confirmed: Int, required: Int) -> String {
        "\(max(0, confirmed)) of \(max(1, required))"
    }

    /// Named on their own from now on.
    static let autoText = "Auto"

    /// The review footer next to the glowing dots, or nil when no one on the
    /// call is named automatically.
    static func autoNamedFooter(count: Int) -> String? {
        switch count {
        case ..<1: return nil
        default: return "\(count) auto-named"
        }
    }
}
