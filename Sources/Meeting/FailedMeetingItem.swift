// FailedMeetingItem.swift
// The failed-meeting row that `FailedMeetingPresentation.item(from:)` builds
// and Home renders. Moved out of FailedMeetingStore.swift so this type and
// FailedMeetingPresentation.swift compile in the fast-test runner without the
// @MainActor store or MeetingSessionController.
//
// `FailedMeetingStore.FailedMeetingItem` and
// `MeetingSessionController.FailedMeetingItem` stay resolvable as typealiases.
// It is nested here rather than top-level because a nested
// `typealias FailedMeetingItem = FailedMeetingItem` would refer to itself.

import Foundation

extension FailedMeetingPresentation {
    struct FailedMeetingItem: Identifiable, Equatable {
        let id: UUID
        let timestamp: Date
        let title: String
        let detail: String
        let meta: String
        let failureKind: MeetingFailureKind
        let isRetryable: Bool
        let isRetrying: Bool
        let hasAudioFiles: Bool
        let audioURLs: [URL]
        var usableAudio: FailedMeetingUsableAudio = .unknown
    }
}
