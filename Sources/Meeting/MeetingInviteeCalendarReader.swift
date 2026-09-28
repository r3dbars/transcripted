import EventKit
import Foundation

/// Finds who was invited to the calendar event a saved meeting started with,
/// for the name buttons in speaker review. Read-only, and it never asks for
/// calendar access: it only looks when access was already granted for the
/// meeting prompt. Unlike the prompt, it keeps events with no meeting link,
/// so in-person meetings count too. Names stay on this Mac and are never
/// logged or sent anywhere.
//
// @unchecked Sendable is safe because EKEventStore is documented thread-safe
// and every query serializes on `queue`. EKEvent objects never leave it.
@available(macOS 14.0, *)
final class MeetingInviteeCalendarReader: @unchecked Sendable {
    static let shared = MeetingInviteeCalendarReader()

    private let queue = DispatchQueue(label: "MeetingInviteeCalendarReader", qos: .utility)
    private var eventStore: EKEventStore?

    /// Everyone but you on the event the recording started with, or an empty
    /// list when there is no access, no such event, or two of them.
    func inviteeNames(recordingStart: Date) async -> [String] {
        guard TranscriptedPermissionAccess.calendarAccessGranted() else { return [] }
        let events = await eventSnapshots(recordingStart: recordingStart)
        return MeetingInviteeSuggestionPolicy.matchingEvent(
            recordingStart: recordingStart,
            among: events
        )?.inviteeNames ?? []
    }

    /// Every event running at any point in the window where a matching event
    /// could start; the policy keeps only the ones that actually start in it.
    private func eventSnapshots(recordingStart: Date) async -> [MeetingInviteeEventSnapshot] {
        let start = recordingStart.addingTimeInterval(-MeetingInviteeSuggestionPolicy.startGrace)
        let end = recordingStart.addingTimeInterval(MeetingInviteeSuggestionPolicy.startLeadTime + 1)
        return await withCheckedContinuation { continuation in
            queue.async {
                let store = self.eventStore ?? EKEventStore()
                self.eventStore = store
                let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
                let snapshots = store.events(matching: predicate).compactMap(Self.snapshot(for:))
                continuation.resume(returning: snapshots)
            }
        }
    }

    private static func snapshot(for event: EKEvent) -> MeetingInviteeEventSnapshot? {
        guard let startDate = event.startDate,
              let endDate = event.endDate,
              let attendees = event.attendees,
              !attendees.isEmpty else { return nil }
        // The organizer is not always listed among the attendees. The policy
        // drops the duplicate when they are.
        let people = (event.organizer.map { [$0] } ?? []) + attendees
        let participants = people.map { attendee in
            MeetingInviteeRawParticipant(
                name: attendee.name,
                email: attendee.url.scheme?.lowercased() == "mailto"
                    ? attendee.url.absoluteString
                    : nil,
                isCurrentUser: attendee.isCurrentUser,
                isPerson: attendee.participantType == .person || attendee.participantType == .unknown
            )
        }
        return MeetingInviteeEventSnapshot(
            startDate: startDate,
            endDate: endDate,
            isAllDay: event.isAllDay,
            inviteeNames: MeetingInviteeSuggestionPolicy.inviteeNames(from: participants)
        )
    }
}
