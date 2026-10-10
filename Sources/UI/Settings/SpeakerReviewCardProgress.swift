// SpeakerReviewCardProgress.swift
// What the Speakers page's "Review and name these people" stack says and draws
// around a voice once it's named on a card: the person's print lighting one
// more ring, the line under the name ("Named automatically from now on", "3
// more to go", "Saved · 4 more to auto-name"), the card's "Weekly sync is done"
// footer, and the closed summary card ("3 voices to name"). The words are the
// island's (SpeakerNamingTierPresentation.reviewHint), so both places say the
// same thing. Foundation-only so the fast tests can compile it.

import Foundation
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif

/// A voice just named on a review card, kept on the card after the queue
/// refresh drops it so the person can see their print light up.
struct SpeakerReviewNamedVoice: Equatable, Identifiable {
    /// The queued voice that was named.
    let voiceID: UUID
    /// Who it is now: the saved person it joined, or the voice itself when
    /// it was saved under a new name.
    let personID: UUID
    let name: String
    /// Confirmed meetings before this answer (0 for someone new).
    let confirmedBefore: Int
    /// The refreshed store count after saving, not an assumed one-meeting increment.
    var confirmedAfter: Int = 0
    /// The confirmed-meeting bar for auto-naming.
    var requiredMeetings: Int
    /// Saved under a new name rather than joining someone already saved.
    let isNewPerson: Bool
    /// `SpeakerNamingStanding.isTrusted` for the person it joined.
    var isTrusted: Bool

    var id: UUID { voiceID }
}

enum SpeakerReviewCardProgress {
    /// Distinct confirmed meetings persisted by the answer, including all queued calls.
    static func confirmedAfter(_ voice: SpeakerReviewNamedVoice) -> Int {
        max(0, voice.confirmedAfter)
    }

    /// Rings lit before the answer: the print the person had walking in.
    static func litRingsBefore(_ voice: SpeakerReviewNamedVoice) -> Int {
        guard !voice.isNewPerson else { return 0 }
        return litRings(confirmed: voice.confirmedBefore, voice: voice)
    }

    /// Rings lit after the answer; the print animates up to this.
    static func litRingsAfter(_ voice: SpeakerReviewNamedVoice) -> Int {
        litRings(confirmed: confirmedAfter(voice), voice: voice)
    }

    /// The line under the name, the island's words for the same moment.
    static func hint(_ voice: SpeakerReviewNamedVoice) -> SpeakerNamingTierPresentation.ReviewHint? {
        let hint = SpeakerNamingTierPresentation.reviewHint(
            moment: .confirmed,
            confirmedBefore: confirmedAfter(voice),
            required: voice.requiredMeetings,
            isTrusted: voice.isTrusted,
            earnsConfirmation: false
        )
        guard voice.isNewPerson, let hint, !hint.usesPersonColor else { return hint }
        return .init(text: "Saved · \(max(0, voice.requiredMeetings - confirmedAfter(voice))) more to auto-name", usesPersonColor: false)
    }

    /// "Weekly sync is done · 2 voices named", or just "Weekly sync is done".
    static func doneLine(callTitle: String, namedCount: Int) -> String {
        let title = callTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let head = title.isEmpty ? "This call is done" : "\(title) is done"
        switch namedCount {
        case ..<1: return head
        case 1: return "\(head) · 1 voice named"
        default: return "\(head) · \(namedCount) voices named"
        }
    }

    /// The done card's button: on to the next call, or close the stack.
    static func nextTitle(callsAfterThis: Int) -> String {
        callsAfterThis > 0 ? "Next call" : "Done"
    }

    /// The closed summary card's title.
    static func summaryTitle(voiceCount: Int) -> String {
        voiceCount == 1 ? "1 voice to name" : "\(voiceCount) voices to name"
    }

    /// "From Weekly sync", "From Weekly sync and Design review", or "From
    /// Weekly sync and 3 other calls".
    static func summarySource(callTitles: [String]) -> String? {
        let titles = callTitles
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let first = titles.first else { return nil }
        switch titles.count {
        case 1: return "From \(first)"
        case 2: return "From \(first) and \(titles[1])"
        default: return "From \(first) and \(titles.count - 1) other calls"
        }
    }

    private static func litRings(confirmed: Int, voice: SpeakerReviewNamedVoice) -> Int {
        let trusted = voice.isTrusted
        let tier = SpeakerNamingTier.tier(
            confirmedMeetings: confirmed,
            requiredMeetings: voice.requiredMeetings,
            isTrusted: trusted
        )
        return SpeakerNamingTierPresentation.filledSegments(
            confirmed: confirmed,
            required: voice.requiredMeetings,
            tier: tier
        )
    }
}
