import Foundation

/// One calendar event's invite list, copied off EventKit so the policy below
/// never touches EventKit objects. Invitee names stay on this Mac: they are
/// only shown in speaker review and never go to analytics or crash reports.
struct MeetingInviteeEventSnapshot: Equatable {
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
    /// Everyone invited except you, already cleaned by `inviteeNames(from:)`.
    let inviteeNames: [String]
}

/// One raw invitee as EventKit reports it, before cleaning.
struct MeetingInviteeRawParticipant: Equatable {
    let name: String?
    let email: String?
    let isCurrentUser: Bool
    /// Rooms, resources and mailing groups are on invites but never talk.
    let isPerson: Bool
}

/// Turns the calendar invite for a meeting into speaker-review suggestions:
/// one-click name buttons, invitees first in the name list, and a pre-filled
/// name for a 1:1. Suggestions only. Nothing here changes which voices get
/// named silently.
///
/// An event only counts when the recording started when the event did: in
/// the same window the "record this meeting?" pop-up is offered (a minute
/// before to five minutes after the start). A recording that merely falls
/// inside a long calendar slot never picks up its invite list, so a second
/// call later in that hour gets no names.
enum MeetingInviteeSuggestionPolicy {
    /// Most name buttons one review row shows.
    static let maxSuggestions = 4
    /// How early a recording may start before the event and still count.
    static let startLeadTime = MeetingPromptHeuristics.calendarReminderLeadTime
    /// How late a recording may start after the event and still count.
    static let startGrace = MeetingPromptHeuristics.calendarReminderPostStartGrace

    // MARK: - Picking the event

    /// The one event whose start lines up with the recording's start, or nil
    /// when none does or two different events do (a double booking we can't
    /// tell apart).
    static func matchingEvent(
        recordingStart: Date,
        among events: [MeetingInviteeEventSnapshot]
    ) -> MeetingInviteeEventSnapshot? {
        let matches = events.filter { event in
            guard !event.isAllDay, !event.inviteeNames.isEmpty else { return false }
            let startedAfterEvent = recordingStart.timeIntervalSince(event.startDate)
            return (-startLeadTime ... startGrace).contains(startedAfterEvent)
        }
        guard let first = matches.first,
              matches.allSatisfy({ $0.inviteeNames == first.inviteeNames }) else { return nil }
        return first
    }

    // MARK: - Cleaning names

    /// Display names for everyone on the invite except you, rooms and groups.
    /// An invitee with only an email gets a name from it when the email reads
    /// like one ("sam.lee@…" → "Sam Lee"); otherwise they are left out, so an
    /// email address is never shown as a name.
    static func inviteeNames(from participants: [MeetingInviteeRawParticipant]) -> [String] {
        var seen: Set<String> = []
        var names: [String] = []
        for participant in participants where participant.isPerson && !participant.isCurrentUser {
            guard let name = displayName(for: participant) else { continue }
            let key = SpeakerNameSelectionPolicy.normalizedSearchText(name)
            guard !key.isEmpty,
                  !SpeakerNameSelectionPolicy.isOwnerLabel(name),
                  seen.insert(key).inserted else { continue }
            names.append(name)
        }
        return names
    }

    static func displayName(for participant: MeetingInviteeRawParticipant) -> String? {
        let name = participant.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !name.isEmpty, !name.contains("@") {
            return name
        }
        let email = participant.email ?? (name.contains("@") ? name : nil)
        return email.flatMap(nameFromEmail)
    }

    static func nameFromEmail(_ email: String) -> String? {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "mailto:", with: "", options: [.caseInsensitive, .anchored])
        guard let localPart = trimmed.split(separator: "@").first else { return nil }
        let words = localPart
            .split(whereSeparator: { $0 == "." || $0 == "_" || $0 == "-" })
            .map(String.init)
        // "sam" or "jbetker91" could be anything; only a clear first.last reads as a name.
        guard words.count >= 2,
              words.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isLetter) }) else { return nil }
        return words.map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")
    }

    // MARK: - Suggestions for a review row

    /// The name-list labels for the invitees: a saved person's existing label
    /// when exactly one saved person has that name, otherwise the invitee's
    /// name (picking it creates a new person, same as typing it).
    static func suggestionLabels<Option>(
        inviteeNames: [String],
        labels: [String],
        optionsByLabel: [String: Option],
        displayName: (Option) -> String
    ) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for name in inviteeNames {
            let key = SpeakerNameSelectionPolicy.normalizedSearchText(name)
            let matchingLabels = labels.filter { label in
                guard let option = optionsByLabel[label] else { return false }
                return SpeakerNameSelectionPolicy.normalizedSearchText(displayName(option)) == key
            }
            let label = matchingLabels.count == 1 ? matchingLabels[0] : name
            guard seen.insert(label).inserted else { continue }
            result.append(label)
            if result.count == maxSuggestions { break }
        }
        return result
    }

    /// The row's name list with the invitees moved to the top, right after
    /// "You" when the list starts with it.
    static func labelsWithInviteesFirst(labels: [String], inviteeLabels: [String]) -> [String] {
        guard !inviteeLabels.isEmpty else { return labels }
        let inviteeSet = Set(inviteeLabels)
        let rest = labels.filter { !inviteeSet.contains($0) }
        if let first = rest.first, SpeakerNameSelectionPolicy.isOwnerLabel(first) {
            return [first] + inviteeLabels + rest.dropFirst()
        }
        return inviteeLabels + rest
    }

    /// A 1:1 on the calendar with a single remote voice that has no suggested
    /// name: that voice is almost certainly the one other invitee. Returns the
    /// name to pre-fill; the user still has to press Save.
    static func oneOnOnePrefill(
        inviteeNames: [String],
        remoteVoiceCount: Int,
        remoteVoiceHasSuggestion: Bool
    ) -> String? {
        guard inviteeNames.count == 1,
              remoteVoiceCount == 1,
              !remoteVoiceHasSuggestion else { return nil }
        return inviteeNames[0]
    }
}
