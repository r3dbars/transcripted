import EventKit
import Foundation

/// Finds who was invited to the calendar event that overlaps a saved meeting,
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

    /// Everyone but you on the event that best covers the recording, or an
    /// empty list when there is no access, no event, or no clear winner.
    func inviteeNames(recordingStart: Date, recordingDuration: TimeInterval) async -> [String] {
        guard TranscriptedPermissionAccess.calendarAccessGranted() else { return [] }
        let events = await eventSnapshots(recordingStart: recordingStart, recordingDuration: recordingDuration)
        return MeetingInviteeSuggestionPolicy.bestEvent(
            recordingStart: recordingStart,
            recordingDuration: recordingDuration,
            among: events
        )?.inviteeNames ?? []
    }

    private func eventSnapshots(
        recordingStart: Date,
        recordingDuration: TimeInterval
    ) async -> [MeetingInviteeEventSnapshot] {
        let length = max(recordingDuration, MeetingInviteeSuggestionPolicy.minimumRecordingSeconds)
        let start = recordingStart
        let end = recordingStart.addingTimeInterval(length)
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
