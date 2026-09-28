import Foundation
import TranscriptedCore

/// Chooses the speaker separation for one live meeting: the tuned settings for the
/// diarization backend this app runs, capped from the calendar invite the recording
/// started with. The invite count comes from the same lookup speaker review uses for
/// its name buttons, so no invite (or no calendar access) simply means no cap.
enum MeetingSpeakerSeparation {
    /// Pure decision: backend and invited people in, options out.
    static func options(backend: DiarizationBackend, invitedPeople: Int?) -> SpeakerSeparationOptions {
        SpeakerSeparationOptions.tuned(for: backend, invitedPeople: invitedPeople)
    }

    /// Reads the invite for `recordingStart` and returns the options for `backend`.
    static func resolve(backend: DiarizationBackend, recordingStart: Date?) async -> SpeakerSeparationOptions {
        var invitedPeople: Int?
        if let recordingStart {
            let names = await MeetingInviteeCalendarReader.shared.inviteeNames(recordingStart: recordingStart)
            invitedPeople = names.isEmpty ? nil : names.count
        }
        return options(backend: backend, invitedPeople: invitedPeople)
    }
}

/// The lineup for lineup naming: the calendar invite the recording started with
/// (same lookup speaker review uses for its name buttons), or, with no invite or no
/// calendar access, the 12 people heard most recently.
enum MeetingCalendarNaming {
    static func lineupRequest(recordingStart: Date?) async -> SpeakerNamingPolicy.LineupRequest {
        var names: [String] = []
        if let recordingStart {
            names = await MeetingInviteeCalendarReader.shared.inviteeNames(recordingStart: recordingStart)
        }
        return SpeakerNamingPolicy.LineupRequest(invitedNames: names, recentPeopleLimit: 12)
    }
}
