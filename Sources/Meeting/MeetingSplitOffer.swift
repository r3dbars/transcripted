import Foundation

struct MeetingSplitOffer: Equatable {
    let recordingIdentity: UUID
    let candidate: MeetingPromptDetector.Candidate?

    func isCurrent(at now: Date) -> Bool {
        guard let candidate else { return true }
        return MeetingPromptWindowPolicy.shouldOfferCalendarPrompt(
            startsIn: candidate.startDate.timeIntervalSince(now),
            endsIn: candidate.endDate.timeIntervalSince(now)
        )
    }

    /// Keep the displayed event when it still qualifies, with refreshed event details.
    /// If it disappeared, choose the next eligible event in detector priority order.
    static func refreshed(
        current: Self?, candidates: [MeetingPromptDetector.Candidate],
        identity: UUID, recordingStart: Date?
    ) -> Self? {
        let eligible = candidates.filter { candidate in
            guard let recordingStart else { return true }
            return !MeetingInviteeSuggestionPolicy.startsTogether(eventStart: candidate.startDate, recordingStart: recordingStart)
        }
        let existing = current?.recordingIdentity == identity ? current : nil
        if let candidate = eligible.first(where: { $0.id == existing?.candidate?.id }) ?? eligible.first {
            return Self(recordingIdentity: identity, candidate: candidate)
        }
        return existing?.candidate == nil ? existing : nil
    }
}
