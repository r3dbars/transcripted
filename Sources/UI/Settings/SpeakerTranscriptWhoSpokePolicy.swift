// SpeakerTranscriptWhoSpokePolicy.swift
// "Who spoke?" for a saved meeting the review queue has nothing left for: the
// Meetings card's "Who spoke?" opens this meeting's card on Speakers even when
// every voice already has a name, so any name in it can still be fixed there,
// all at once. It is the same card (the island's review in page chrome), built
// from the transcript instead of the queue: a voice still called "Speaker 2"
// is asked "Who's this?", a named one shows its name with "Not Priya?", and
// the answers come back as the same transcript assignments the per-line quick
// fix saves (`assignMeetingSpeakers`). Foundation-only so the fast tests can
// compile it; the card itself is SpeakerTranscriptWhoSpoke.swift.

import Foundation
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif

enum SpeakerTranscriptWhoSpokePolicy {
    /// One voice heard in the transcript.
    struct Voice: Equatable {
        let identity: HomeMeetingSpeakerIdentity
        /// The line shown under it (the turn its window of audio plays).
        let quote: String?
        /// Still a generic label: asked "Who's this?" instead of shown by name.
        let asks: Bool
    }

    /// Every voice in the transcript, first heard first.
    static func voices(in lines: [HomeMeetingTranscriptLine]) -> [Voice] {
        HomeMeetingSpeakerNamingPolicy.drafts(from: lines).map { draft in
            Voice(
                identity: draft.identity,
                quote: draft.sampleTexts.first,
                asks: isUnnamed(draft.identity.displayName)
            )
        }
    }

    /// "Speaker 2", "Speaker", "Unknown voice", or nothing: a label the
    /// transcript gave a voice nobody has named.
    static func isUnnamed(_ displayName: String) -> Bool {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return true }
        let lowered = name.lowercased()
        if lowered == "unknown" || lowered == "unknown voice" { return true }
        guard lowered.hasPrefix("speaker") else { return false }
        let rest = lowered.dropFirst("speaker".count).trimmingCharacters(in: .whitespaces)
        return rest.isEmpty || rest.allSatisfy(\.isNumber)
    }

    /// The card's answers as transcript assignments, one per voice that
    /// changed. `identities` maps each row's id to the voice it stands for;
    /// `savedNames` is saved people by id (a pick keeps their name);
    /// `ownerID` is the saved "You", if there is one. "Not a person" has no
    /// transcript meaning here, so it saves nothing.
    static func assignments(
        for updates: [SpeakerReviewUpdate],
        identities: [UUID: HomeMeetingSpeakerIdentity],
        savedNames: [UUID: String],
        ownerID: UUID?
    ) -> [HomeMeetingSpeakerAssignment] {
        var seen = Set<UUID>()
        return updates.compactMap { update in
            guard seen.insert(update.persistentSpeakerId).inserted,
                  let identity = identities[update.persistentSpeakerId] else { return nil }
            let typed = SpeakerMeetingReviewPolicy.usableName(update.newName)
            switch update.action {
            case .merged(let target):
                if target == update.persistentSpeakerId || target == identity.persistentSpeakerID {
                    // The voice's own saved person: a rename at most.
                    return typed.flatMap { rename(identity, to: $0) }
                }
                guard let name = typed ?? SpeakerMeetingReviewPolicy.usableName(savedNames[target]) else { return nil }
                return HomeMeetingSpeakerAssignment(identity: identity, newName: name, targetProfileID: target)
            case .collapsedToMe:
                let owner = SpeakerNameSelectionPolicy.ownerLabel
                if let ownerID, ownerID != identity.persistentSpeakerID {
                    return HomeMeetingSpeakerAssignment(identity: identity, newName: owner, targetProfileID: ownerID)
                }
                return rename(identity, to: owner)
            case .discardedFromDatabase:
                return nil
            case .named, .confirmed, .corrected:
                return typed.flatMap { rename(identity, to: $0) }
            }
        }
    }

    private static func rename(_ identity: HomeMeetingSpeakerIdentity, to name: String) -> HomeMeetingSpeakerAssignment? {
        guard name != identity.displayName else { return nil }
        return HomeMeetingSpeakerAssignment(identity: identity, newName: name, targetProfileID: nil)
    }
}
