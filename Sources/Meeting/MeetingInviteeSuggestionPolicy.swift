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
    /// How many people besides you are on the invite, from
    /// `invitedPeopleCount(from:)`. Counts invitees `inviteeNames` leaves out
    /// (an email that doesn't read as a name), so a call is never mistaken
    /// for a one-on-one. Nil = unknown; use `inviteeNames.count`.
    var invitedPeopleCount: Int? = nil
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
        // An invite whose people are all email-only has no names to show but
        // still counts: it is a real call, and it must take part in the
        // double-booking check so a named event at the same time can't win.
        let matches = events.filter { event in
            guard !event.isAllDay, peopleCount(of: event) > 0 else { return false }
            let startedAfterEvent = recordingStart.timeIntervalSince(event.startDate)
            return (-startLeadTime ... startGrace).contains(startedAfterEvent)
        }
        // Same names = the same meeting on two calendars, even when one copy
        // lists an extra email-only guest; keep the bigger count. With no
        // names to compare, only equal counts can show it's one meeting.
        guard let first = matches.first,
              matches.allSatisfy({ $0.inviteeNames == first.inviteeNames }),
              !first.inviteeNames.isEmpty || matches.allSatisfy({ peopleCount(of: $0) == peopleCount(of: first) })
        else { return nil }
        let biggestCount = matches.map(peopleCount(of:)).max() ?? 0
        guard biggestCount > peopleCount(of: first) else { return first }
        var merged = first
        merged.invitedPeopleCount = biggestCount
        return merged
    }

    private static func peopleCount(of event: MeetingInviteeEventSnapshot) -> Int {
        event.invitedPeopleCount ?? event.inviteeNames.count
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

    /// How many people besides you are on the invite: rooms and groups left
    /// out, the organizer listed twice counted once. Unlike `inviteeNames`,
    /// someone with only an email like "jsmith@…" still counts, since they
    /// can still talk.
    static func invitedPeopleCount(from participants: [MeetingInviteeRawParticipant]) -> Int {
        var seen: Set<String> = []
        for participant in participants where participant.isPerson && !participant.isCurrentUser {
            if let name = participant.name, SpeakerNameSelectionPolicy.isOwnerLabel(name) { continue }
            let email = participant.email?
                .replacingOccurrences(of: "mailto:", with: "", options: [.caseInsensitive, .anchored])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let key: String
            if let email, !email.isEmpty {
                key = "email:" + email
            } else if let name = displayName(for: participant) {
                key = "name:" + SpeakerNameSelectionPolicy.normalizedSearchText(name)
            } else {
                // Nothing to tell this person apart by; count them anyway.
                key = "unknown:\(seen.count)"
            }
            seen.insert(key)
        }
        return seen.count
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

    /// A 1:1 on the calendar where the whole meeting heard one remote voice,
    /// that voice is up for review, and it has no suggested name: that voice
    /// is almost certainly the one other invitee. Returns the name to
    /// pre-fill; the user still has to press Save.
    ///
    /// `remoteVoicesInMeeting` counts every remote voice, including ones
    /// already named silently that never reach review, so an extra guest
    /// next to an auto-named invitee is not handed the invitee's name. When
    /// that count is unknown, nothing is pre-filled.
    static func oneOnOnePrefill(
        inviteeNames: [String],
        remoteVoicesInMeeting: Int?,
        remoteRowsInReview: Int,
        remoteRowHasSuggestion: Bool
    ) -> String? {
        guard inviteeNames.count == 1,
              remoteVoicesInMeeting == 1,
              remoteRowsInReview == 1,
              !remoteRowHasSuggestion else { return nil }
        return inviteeNames[0]
    }
}
