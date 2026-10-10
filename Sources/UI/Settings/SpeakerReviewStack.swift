import Foundation
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif

/// The "Review and name these people" card stack on the Speakers page, and
/// what it means for the Everyone list and the Home attention row. Worked out
/// once when its inputs change instead of on every read, since the page, the
/// Everyone list, and Home all ask for it on each render.
///
/// Only the top card is drawn. So only the voices on that card are left out
/// of Everyone; voices on cards further down stay listed (with a "Waiting in
/// review" badge) and can be searched, renamed, merged, or deleted without
/// cycling the stack.
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

    init(voices: [SpeakerPendingVoiceGroup], skippedCallKeys: Set<String>, laterCallKeys: [String]) {
        let groups = SpeakerReviewQueueScanner.groupedByMeeting(voices)
            .filter { !skippedCallKeys.contains($0.id) }
        let later = Set(laterCallKeys)
        let front = groups.filter { !later.contains($0.id) }
        let back = laterCallKeys.compactMap { key in groups.first { $0.id == key } }
        calls = front + back
        topCardVoiceIDs = Set(calls.first?.voices.map(\.id) ?? [])
        queuedVoiceIDs = Set(calls.flatMap { $0.voices.map(\.id) })
    }

    /// Voices still waiting for a name, for Home's attention row. A skipped
    /// call's voices don't count; they live under Everyone now.
    var voiceCount: Int { queuedVoiceIDs.count }

    /// The Everyone list from `profiles` (already sorted and, when searching,
    /// already filtered). A search shows every match, including voices on
    /// the open card, so any voice can always be found by search.
    func directory(_ profiles: [SpeakerProfile], isSearching: Bool, heldCallID: String? = nil) -> [SpeakerProfile] {
        guard !isSearching else { return profiles }
        // A completed call can stay visible for its celebration. The next
        // queued call is not visible yet, so its voices must remain listed.
        let visibleVoiceIDs = heldCallID.map { id in
            Set(calls.first { $0.id == id }?.voices.map(\.id) ?? [])
        } ?? topCardVoiceIDs
        return profiles.filter { Self.isNamed($0) || !visibleVoiceIDs.contains($0.id) }
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

/// UI completion ownership, independent of the disk edit itself. Leaving a
/// card invalidates its callbacks even if the same call is opened again.
struct SpeakerReviewVisit {
    private(set) var token = UUID()

    mutating func invalidate() { token = UUID() }

    func accepts(_ submittedToken: UUID, isOpen: Bool) -> Bool {
        isOpen && submittedToken == token
    }
}
