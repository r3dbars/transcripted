import Foundation

struct MeetingSplitOffer: Equatable {
    let recordingIdentity: UUID
    let candidate: MeetingPromptDetector.Candidate?

    // A second offer for the same event or rejoin is a different user action.
    var presentationID = UUID()

    func matches(_ other: Self?) -> Bool {
        guard let other, presentationID == other.presentationID,
              recordingIdentity == other.recordingIdentity else { return false }
        return hasSameEvent(as: other)
    }

    private func hasSameEvent(as other: Self) -> Bool {
        guard let candidate, let refreshed = other.candidate else {
            return candidate == nil && other.candidate == nil
        }
        return candidate.id == refreshed.id && candidate.provider == refreshed.provider
            && candidate.startDate == refreshed.startDate && candidate.endDate == refreshed.endDate
            && candidate.meetingURL == refreshed.meetingURL
            && candidate.suggestedTranscriptTitle == refreshed.suggestedTranscriptTitle
    }

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
            var refreshed = Self(recordingIdentity: identity, candidate: candidate)
            if let existing, existing.hasSameEvent(as: refreshed) {
                refreshed.presentationID = existing.presentationID
            }
            return refreshed
        }
        return existing?.candidate == nil ? existing : nil
    }
}
