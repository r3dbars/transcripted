import Foundation

@available(macOS 14.0, *)
@available(macOS 14.0, *)
enum MeetingPromptCalendarScoring {
    static func calendarCandidates(
        from events: [MeetingPromptCalendarEventSnapshot],
        now: Date,
        runtimeSnapshot: MeetingPromptRuntimeSnapshot
    ) -> [MeetingPromptScoredCandidate] {
        events.compactMap { event in
            scoredCalendarCandidate(
                from: event,
                now: now,
                runtimeSnapshot: runtimeSnapshot
            )
        }
    }

    private static func scoredCalendarCandidate(
        from event: MeetingPromptCalendarEventSnapshot,
        now: Date,
        runtimeSnapshot: MeetingPromptRuntimeSnapshot
    ) -> MeetingPromptScoredCandidate? {
        guard !event.isAllDay else { return nil }
        guard let meetingURL = event.meetingURL,
              let provider = event.provider else { return nil }

        let startsIn = event.startDate.timeIntervalSince(now)
        let endsIn = event.endDate.timeIntervalSince(now)
        guard MeetingPromptWindowPolicy.shouldOfferCalendarPrompt(startsIn: startsIn, endsIn: endsIn) else { return nil }

        let eventTitle = suggestedTranscriptTitle(from: event) ?? "Upcoming meeting"
        let transcriptTitle = suggestedTranscriptTitle(from: event)
        let runtimeReason = activeRuntimeReason(
            for: provider,
            runtimeSnapshot: runtimeSnapshot
        )
        let detail = buildDetail(eventTitle: eventTitle, startsIn: startsIn, runtimeReason: runtimeReason)
        let score = scoreForCandidate(startsIn: startsIn, runtimeReason: runtimeReason)

        return MeetingPromptScoredCandidate(
            candidate: MeetingPromptDetector.Candidate(
                id: "calendar:\(event.id)",
                title: "Meeting detected",
                detail: detail,
                provider: provider,
                reason: MeetingPromptHeuristics.reason(
                    for: .calendarEvent,
                    hasRuntimeContext: runtimeReason != nil
                ),
                source: .calendarEvent,
                startDate: event.startDate,
                endDate: event.endDate,
                meetingURL: meetingURL,
                suggestedTranscriptTitle: transcriptTitle
            ),
            score: score
        )
    }

    private static func suggestedTranscriptTitle(from event: MeetingPromptCalendarEventSnapshot) -> String? {
        let trimmed = (event.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func buildDetail(eventTitle: String, startsIn: TimeInterval, runtimeReason: String?) -> String {
        if let runtimeReason {
            return "\(eventTitle) - \(runtimeReason)"
        }

        if startsIn > 90 {
            let minutes = Int(ceil(startsIn / 60))
            return "\(eventTitle) - starts in \(minutes) min"
        }

        if startsIn > 15 {
            return "\(eventTitle) - starts soon"
        }

        if startsIn >= -120 {
            return "\(eventTitle) - starting now"
        }

        return "\(eventTitle) - already in progress"
    }

    private static func scoreForCandidate(startsIn: TimeInterval, runtimeReason: String?) -> Int {
        var score = runtimeReason == nil ? 1 : 3

        if (-60 ... 120).contains(startsIn) {
            score += 2
        } else if (-5 * 60 ... 5 * 60).contains(startsIn) {
            score += 1
        }

        return score
    }

    private static func activeRuntimeReason(
        for provider: MeetingPromptProvider,
        runtimeSnapshot: MeetingPromptRuntimeSnapshot
    ) -> String? {
        if !provider.activeBundleIdentifiers.isEmpty,
           provider.activeBundleIdentifiers.contains(where: runtimeSnapshot.runningBundleIDs.contains) {
            return "\(provider.displayName) is open"
        }

        if provider.browserHosted,
           let frontmostBundleID = runtimeSnapshot.frontmostBundleID,
           MeetingPromptRuntimeSnapshot.browserBundleIdentifiers.contains(frontmostBundleID) {
            return "meeting tab is active"
        }

        return nil
    }
}
