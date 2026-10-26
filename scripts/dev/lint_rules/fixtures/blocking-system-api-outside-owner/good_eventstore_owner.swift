// lint-fixture-path: Sources/Meeting/MeetingPromptCalendarReader.swift
// The calendar reader owns EKEventStore construction, on its queue.
import EventKit

final class MeetingPromptCalendarReader: @unchecked Sendable {
    private var eventStore: EKEventStore?

    private func store() -> EKEventStore {
        if let eventStore { return eventStore }
        let store = EKEventStore()
        eventStore = store
        return store
    }
}
