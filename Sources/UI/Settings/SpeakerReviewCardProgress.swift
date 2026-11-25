// SpeakerReviewCardProgress.swift
// What the Speakers page's "Review and name these people" stack says and draws
// around a voice once it's named on a card: the person's print lighting one
// more ring, the line under the name ("Auto", "2 of 5", or "1 of 5" for
// someone new), and the "Weekly sync is done" banner. The words are the
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
        SpeakerNamingTierPresentation.reviewHint(
            moment: .confirmed,
            confirmedBefore: confirmedAfter(voice),
            required: voice.requiredMeetings,
            isTrusted: voice.isTrusted,
            earnsConfirmation: false
        )
    }

    /// "Weekly sync is done · 2 voices named", or just "Weekly sync is done".
    static func doneLine(callTitle: String, namedCount: Int) -> String {
        let title = callTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let head = title.isEmpty ? "This meeting is done" : "\(title) is done"
        switch namedCount {
        case ..<1: return head
        case 1: return "\(head) · 1 voice named"
        default: return "\(head) · \(namedCount) voices named"
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

/// A successful naming stays on the review card. The queue refresh drops
/// the unnamed row; the parent only holds the call and appends the named
/// row when this returns the voice.
enum SpeakerReviewNamedRetention {
    enum Action: Equatable {
        case typedName
        case joinedSavedPerson
        case markedAsMe
    }

    struct Owner {
        let id: UUID
        let name: String
        let confirmedMeetings: Int
        let requiredMeetings: Int
        let isTrusted: Bool
    }

    /// "This is me" is a naming: You, either as a new person or joined to
    /// the existing owner.
    static func thisIsMe(
        voiceID: UUID,
        existingOwner: Owner?,
        requiredMeetings: Int = SpeakerNamingTierPresentation.segmentCount
    ) -> SpeakerReviewNamedVoice {
        if let owner = existingOwner {
            return SpeakerReviewNamedVoice(
                voiceID: voiceID,
                personID: owner.id,
                name: owner.name,
                confirmedBefore: owner.confirmedMeetings,
                requiredMeetings: owner.requiredMeetings,
                isNewPerson: false,
                isTrusted: owner.isTrusted
            )
        }
        return SpeakerReviewNamedVoice(
            voiceID: voiceID,
            personID: voiceID,
            name: SpeakerNameSelectionPolicy.ownerLabel,
            confirmedBefore: 0,
            requiredMeetings: requiredMeetings,
            isNewPerson: true,
            isTrusted: true
        )
    }

    static func retainedVoice(
        after action: Action,
        didSave: Bool,
        named: SpeakerReviewNamedVoice
    ) -> SpeakerReviewNamedVoice? {
        guard didSave else { return nil }
        switch action {
        case .typedName, .joinedSavedPerson, .markedAsMe:
            return named
        }
    }
}
