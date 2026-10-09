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

    static func word(_ tier: SpeakerNamingTier) -> String {
        switch tier {
        case .new: return "New"
        case .learning: return "Learning"
        case .auto: return "Auto"
        }
    }

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
        switch tier {
        case .auto:
            return "Confirmed in \(meetings(confirmed)). Transcripted names \(first) on its own when the voice is a clear match."
        case .learning where !isTrusted:
            return "A recent correction paused auto-naming for \(first). Confirm \(first) once more to turn it back on."
        case .learning, .new:
            let left = max(0, required - confirmed)
            if left == 1 {
                return "Confirmed in \(meetings(confirmed)). One more and Transcripted names \(first) on its own."
            }
            if confirmed == 0 {
                return "Not confirmed yet. After \(meetings(required)), Transcripted names \(first) on its own."
            }
            return "Confirmed in \(confirmed) of \(required) meetings. \(left) more and Transcripted names \(first) on its own."
        }
    }

    /// VoiceOver label for the dial: the word plus the count.
    static func accessibilityLabel(confirmed: Int, required: Int, tier: SpeakerNamingTier) -> String {
        if tier == .auto { return "\(word(tier)), names on its own" }
        return "\(word(tier)), \(confirmed) of \(required) meetings confirmed"
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

    /// The short line under a name in the review, or nil for none.
    /// `confirmedBefore` is the count before this review.
    static func reviewHint(moment: ReviewMoment, confirmedBefore: Int, required: Int, isTrusted: Bool) -> ReviewHint? {
        let bar = max(1, required)
        switch moment {
        case .asking:
            guard isTrusted, bar - max(0, confirmedBefore) == 1 else { return nil }
            return ReviewHint(text: "One more yes to auto-name", usesPersonColor: true)
        case .confirmed:
            let after = max(0, confirmedBefore) + 1
            if after >= bar {
                // Past the bar on probation, a yes restores trust over time; don't
                // promise auto-naming that the health check may still withhold.
                return isTrusted ? ReviewHint(text: "Named automatically from now on", usesPersonColor: true) : nil
            }
            let left = bar - after
            return ReviewHint(text: left == 1 ? "1 more to go" : "\(left) more to go", usesPersonColor: false)
        case .savedNew:
            let left = bar - 1
            guard left > 0 else { return nil }
            return ReviewHint(text: "Saved · \(left) more to auto-name", usesPersonColor: false)
        }
    }

    /// The review footer next to the glowing dots, or nil when no one on the
    /// call is named automatically.
    static func autoNamedFooter(count: Int) -> String? {
        switch count {
        case ..<1: return nil
        case 1: return "1 person named automatically"
        default: return "\(count) people named automatically"
        }
    }
}
