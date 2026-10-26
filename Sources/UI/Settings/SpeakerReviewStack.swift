import Foundation
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif

/// The Speakers page's "Who spoke?" cards, one meeting at a time, and what
/// they mean for the Everyone list and the Home attention row. Worked out
/// once when its inputs change instead of on every read, since the page, the
/// Everyone list, and Home all ask for it on each render.
///
/// Only the top card is drawn. So only the voices on that card (and on a
/// card just finished, while its Undo is up) are left out of Everyone;
/// voices on cards further down stay listed (with a "Waiting in review"
/// badge) and can be searched, renamed, merged, or deleted without cycling
/// the stack.
struct SpeakerReviewStack {
    static let empty = SpeakerReviewStack(voices: [], skippedCallKeys: [], laterCallKeys: [])
    static let waitingBadgeTitle = "Waiting in review"

    /// One card per call with voices still unnamed, newest call first, minus
    /// skipped calls. Calls sent back with Later go last, in the order sent.
    let calls: [SpeakerPendingMeetingGroup]
    /// Voices on the open top card. Everyone leaves these out unless the
    /// person is searching, since the card sits right above it.
    let topCardVoiceIDs: Set<UUID>
    /// Every voice on any card, open or waiting underneath.
    let queuedVoiceIDs: Set<UUID>
    /// Voices on a card that was just finished and is being saved (or can
    /// still be undone). Everyone leaves them out like the top card's.
    let heldOutVoiceIDs: Set<UUID>

    /// `heldOutCallKeys`: cards just finished, kept off the stack until
    /// their answers are saved. `focusedCallKey`: a card the Meetings page
    /// asked for, moved to the top.
    init(
        voices: [SpeakerPendingVoiceGroup],
        skippedCallKeys: Set<String>,
        laterCallKeys: [String],
        heldOutCallKeys: Set<String> = [],
        focusedCallKey: String? = nil
    ) {
        let all = SpeakerReviewQueueScanner.groupedByMeeting(voices)
            .filter { !skippedCallKeys.contains($0.id) }
        let groups = all.filter { !heldOutCallKeys.contains($0.id) }
        let later = Set(laterCallKeys)
        let front = groups.filter { !later.contains($0.id) }
        let back = laterCallKeys.compactMap { key in groups.first { $0.id == key } }
        var ordered = front + back
        if let focusedCallKey, let index = ordered.firstIndex(where: { $0.id == focusedCallKey }) {
            ordered.insert(ordered.remove(at: index), at: 0)
        }
        calls = ordered
        topCardVoiceIDs = Set(calls.first?.voices.map(\.id) ?? [])
        queuedVoiceIDs = Set(calls.flatMap { $0.voices.map(\.id) })
        heldOutVoiceIDs = Set(all.filter { heldOutCallKeys.contains($0.id) }.flatMap { $0.voices.map(\.id) })
    }

    /// Voices still waiting for a name, for Home's attention row. A skipped
    /// call's voices don't count; they live under Everyone now.
    var voiceCount: Int { queuedVoiceIDs.count }

    /// The Everyone list from `profiles` (already sorted and, when searching,
    /// already filtered). A search shows every match, including voices on
    /// the open card, so any voice can always be found by search.
    func directory(_ profiles: [SpeakerProfile], isSearching: Bool) -> [SpeakerProfile] {
        guard !isSearching else { return profiles }
        let onCards = topCardVoiceIDs.union(heldOutVoiceIDs)
        return profiles.filter { Self.isNamed($0) || !onCards.contains($0.id) }
    }

    /// How many voices each saved meeting still has to name (by transcript
    /// path), and which card holds them, for the Meetings page's "2 to name"
    /// and its jump to "Who spoke?". A voice heard in several meetings counts
    /// for each, but waits on one card: the newest meeting's.
    struct MeetingNaming: Equatable {
        let voicesToName: Int
        let callKey: String
    }

    func meetingNaming(items: [SpeakerPendingReviewItem]) -> [String: MeetingNaming] {
        var voicesByPath: [String: Set<UUID>] = [:]
        for item in items where queuedVoiceIDs.contains(item.speakerId) {
            voicesByPath[item.transcriptURL.standardizedFileURL.path, default: []].insert(item.speakerId)
        }
        var naming: [String: MeetingNaming] = [:]
        for (path, voices) in voicesByPath {
            // Its own card when it has one, else the card its voices wait on.
            let own = calls.first { $0.transcriptURL.standardizedFileURL.path == path }
            guard let call = own ?? calls.first(where: { call in call.voices.contains { voices.contains($0.id) } }) else {
                continue
            }
            naming[path] = MeetingNaming(voicesToName: voices.count, callKey: call.id)
        }
        return naming
    }

    /// Whether this Everyone row is an unnamed voice sitting on a review card.
    func isWaitingForReview(_ profile: SpeakerProfile) -> Bool {
        !Self.isNamed(profile) && queuedVoiceIDs.contains(profile.id)
    }

    /// The saved-transcript row to name when someone renames this voice from
    /// Everyone, or nil for a plain rename. A voice that still needs a name
    /// (on a card, or in a skipped call) is named the way its card names it,
    /// so its transcripts and confirmations come out the same either way.
    static func reviewItemForRename(
        of profile: SpeakerProfile,
        in queue: [SpeakerPendingReviewItem]
    ) -> SpeakerPendingReviewItem? {
        guard !isNamed(profile) else { return nil }
        return queue.first { $0.speakerId == profile.id }
    }

    private static func isNamed(_ profile: SpeakerProfile) -> Bool {
        profile.displayName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
}
