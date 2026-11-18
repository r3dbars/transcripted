// MeetingSessionController+MeetingSplit.swift
// Split on new meeting: while one meeting records, offer to stop it and start
// a new recording when a different meeting looks like it is starting, so
// back-to-back calls don't end up in one recording. Two triggers: a calendar
// meeting entering its prompt window (from MeetingPromptDetector), and the
// bound call app coming back after the "Call ended" warning (from +CallEnd).

import Foundation

/// The split prompt the island shows while recording.
struct MeetingSplitOffer: Equatable {
    let recordingIdentity: UUID
    /// The calendar meeting that is starting. Nil for a call re-join, which
    /// has no title to offer.
    let candidate: MeetingPromptDetector.Candidate?
}

/// What became of a calendar split offer, for the detector's bookkeeping.
enum MeetingSplitDecision {
    case accepted
    case startFailed
    case declined
}

@available(macOS 14.0, *)
@MainActor
extension MeetingSessionController {
    // MARK: - Split on new meeting

    /// Raises the split prompt. An event that started with this recording is
    /// its own meeting, not a new one. A calendar offer replaces a re-join
    /// offer (it has a title); otherwise one offer at a time. Returns whether
    /// this candidate is now offered.
    @discardableResult
    func offerMeetingSplit(candidate: MeetingPromptDetector.Candidate?) -> Bool {
        guard case .recording = state, let identity = activeRecordingIdentity else { return false }
        if let candidate {
            if let startedAt = activeRecordingStartedAt,
               MeetingInviteeSuggestionPolicy.startsTogether(eventStart: candidate.startDate, recordingStart: startedAt) {
                return false
            }
            if let offered = meetingSplitOffer?.candidate { return offered.id == candidate.id }
        } else if meetingSplitOffer != nil {
            return false
        }
        meetingSplitOffer = MeetingSplitOffer(recordingIdentity: identity, candidate: candidate)
        trackMeetingSplit("shown", candidate: candidate)
        return true
    }

    /// Split: stop this recording (it transcribes in the background, since
    /// transcribing → startingRecording is legal) and start the next one. A
    /// calendar split starts like Record on that meeting's prompt, with its
    /// title and its own call-end arming. A re-join has no candidate, so the
    /// new recording is armed on this one's call app.
    func acceptMeetingSplit() async {
        guard let offer = meetingSplitOffer else { return }
        meetingSplitOffer = nil
        guard case .recording = state, offer.recordingIdentity == activeRecordingIdentity else { return }
        let rejoinFamilies = offer.candidate == nil ? callEndTracking?.families : nil
        trackMeetingSplit("split", candidate: offer.candidate)
        // Before the stop, like a prompt Record: the detector can evaluate
        // between the two recordings and must not prompt for this meeting.
        if let candidate = offer.candidate { onMeetingSplitDecision?(candidate, .accepted) }
        await stopRecording(reason: .newMeetingSplit)
        let started = await startRecording(
            trigger: .detectedPrompt,
            suggestedTitle: offer.candidate?.suggestedTranscriptTitle,
            detectedCallCandidate: offer.candidate
        )
        if !started, let candidate = offer.candidate { onMeetingSplitDecision?(candidate, .startFailed) }
        if started, let rejoinFamilies, callEndTracking == nil,
           AutoCallDetectionPreferences.isEnabled(), let identity = activeRecordingIdentity {
            armCallEndTracking(identity: identity, families: rejoinFamilies, late: false)
        }
    }

    /// Keep recording. A calendar meeting is not offered again; a re-join
    /// is offered again only after another "Call ended" warning.
    func declineMeetingSplit() {
        guard let offer = meetingSplitOffer else { return }
        meetingSplitOffer = nil
        trackMeetingSplit("kept", candidate: offer.candidate)
        if let candidate = offer.candidate { onMeetingSplitDecision?(candidate, .declined) }
    }

    private func trackMeetingSplit(_ action: String, candidate: MeetingPromptDetector.Candidate?) {
        var properties = ["action": action, "trigger": candidate == nil ? "call_rejoin" : "calendar"]
        if let candidate { properties["provider"] = candidate.provider.rawValue }
        DiagnosticsTrail.record(engine: "meeting", event: "meeting_split_offer", message: "Split offer \(action)",
                                context: baseDiagnosticsContext(extra: properties))
        AnalyticsReporter.track("meeting_split_offer", properties: properties)
    }
}
