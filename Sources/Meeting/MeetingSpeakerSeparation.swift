import Foundation
import TranscriptedCore

/// Chooses the speaker separation for one live meeting: nothing when the flag is
/// off, otherwise the lab-tuned settings capped at the size of the calendar
/// invite the recording started with. The invite count comes from the same lookup
/// speaker review uses for its name buttons, so no invite (or no calendar access)
/// simply means no cap.
enum MeetingSpeakerSeparation {
    /// Pure decision: flag state and invited people in, options out.
    static func options(enabled: Bool, invitedPeople: Int?) -> SpeakerSeparationOptions? {
        guard enabled else { return nil }
        let cap = invitedPeople.flatMap { SpeakerSeparationOptions.speakerCap(invitedPeople: $0) }
        return .labTuned(maxSpeakers: cap)
    }

    /// Reads the flag and, only when it is on, the invite for `recordingStart`.
    static func resolve(recordingStart: Date?) async -> SpeakerSeparationOptions? {
        guard SpeakerSeparationPreferences.isEnabled() else { return nil }
        var invitedPeople: Int?
        if let recordingStart {
            let names = await MeetingInviteeCalendarReader.shared.inviteeNames(recordingStart: recordingStart)
            invitedPeople = names.isEmpty ? nil : names.count
        }
        return options(enabled: true, invitedPeople: invitedPeople)
    }
}

/// The lineup for lineup naming, only when the flag is on: the calendar invite the
/// recording started with (same lookup speaker review uses for its name buttons),
/// or, with no invite or no calendar access, the 12 people heard most recently.
enum MeetingCalendarNaming {
    static func lineupRequest(recordingStart: Date?) async -> SpeakerNamingPolicy.LineupRequest? {
        guard CalendarNamingPreferences.isEnabled() else { return nil }
        var names: [String] = []
        if let recordingStart {
            names = await MeetingInviteeCalendarReader.shared.inviteeNames(recordingStart: recordingStart)
        }
        return SpeakerNamingPolicy.LineupRequest(invitedNames: names, recentPeopleLimit: 12)
    }
}
