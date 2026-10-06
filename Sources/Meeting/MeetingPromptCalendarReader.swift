import EventKit
import Foundation

// Built on the reader's queue because EKEvent objects must not cross threads.
// The synthetic evaluator owns URL/provider filtering so tests and production
// share the same prompt policy.
@available(macOS 14.0, *)
private extension MeetingPromptCalendarEventSnapshot {
    init?(event: EKEvent) {
        guard let startDate = event.startDate,
              let endDate = event.endDate else { return nil }

        let snapshot = MeetingPromptCalendarEventSnapshot(
            id: event.calendarItemIdentifier,
            title: event.title,
            startDate: startDate,
            endDate: endDate,
            isAllDay: event.isAllDay,
            url: event.url,
            location: event.location,
            notes: event.notes
        )
        guard snapshot.meetingURL != nil else { return nil }
        self = snapshot
    }
}

// Runs the synchronous EKEventStore queries on a background queue so large
// calendars never block the main actor. @unchecked Sendable is safe because
// the store is only created and used on `queue`.
final class MeetingPromptCalendarReader: @unchecked Sendable {
    private let queue = DispatchQueue(label: "MeetingPromptDetector.calendar-reader", qos: .utility)
    /// `queue` only. Made on `queue`, not by whoever builds the reader:
    /// `EKEventStore()` makes synchronous preference/XPC calls, and building
    /// it on main at launch froze the app for 5 s+ (Sentry APPLE-MACOS-3J).
    private var eventStore: EKEventStore?

    init() {
        // Still made right away, so EKEventStoreChanged posts from launch on,
        // as it did when the store was built inline.
        queue.async { _ = self.store() }
    }

    private func store() -> EKEventStore {
        if let eventStore { return eventStore }
        let store = EKEventStore()
        eventStore = store
        return store
    }

    func fetchMeetingEventSnapshots(start: Date, end: Date) async -> [MeetingPromptCalendarEventSnapshot] {
        await withCheckedContinuation { continuation in
            queue.async {
                let eventStore = self.store()
                let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)
                let snapshots = eventStore.events(matching: predicate)
                    .compactMap { MeetingPromptCalendarEventSnapshot(event: $0) }
                continuation.resume(returning: snapshots)
            }
        }
    }
}
