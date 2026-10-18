// lint-fixture-path: Sources/Meeting/MeetingPromptDetector.swift
// Shape of cb900ba2a^ MeetingPromptDetector: the detector built its own
// EKEventStore as a stored property, so construction ran on main.
import EventKit

@MainActor
final class MeetingPromptDetector {
    private let eventStore = EKEventStore()
    private let otherStore = EKEventStore.init()
}
