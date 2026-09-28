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
    func directory(_ profiles: [SpeakerProfile], isSearching: Bool) -> [SpeakerProfile] {
        guard !isSearching else { return profiles }
        return profiles.filter { Self.isNamed($0) || !topCardVoiceIDs.contains($0.id) }
    }

    /// Whether this Everyone row is an unnamed voice sitting on a review card.
    func isWaitingForReview(_ profile: SpeakerProfile) -> Bool {
        !Self.isNamed(profile) && queuedVoiceIDs.contains(profile.id)
    }

    private static func isNamed(_ profile: SpeakerProfile) -> Bool {
        profile.displayName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
}
