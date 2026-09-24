// SpeakerReviewPresentationGate.swift
// Foundation-pure rule for when the post-meeting speaker review window may
// appear: never on top of a meeting that is being recorded.

import Foundation

/// Tracks the current speaker review request and whether a meeting is being
/// captured, and says what the presenter should do. A review that arrives
/// while a meeting records (back-to-back calls) waits until that recording
/// stops, so the window never lands in the middle of the next call. A window
/// that is already open stays open: the user may be typing in it.
struct SpeakerReviewPresentationGate: Equatable {
    enum Action: Equatable {
        case none
        case present(UUID)
        case dismiss
    }

    private(set) var currentRequestID: UUID?
    private(set) var presentedRequestID: UUID?
    private(set) var isMeetingCaptureActive = false

    /// True while a review is waiting for the recording to stop.
    var isHoldingReview: Bool {
        currentRequestID != nil && presentedRequestID != currentRequestID
    }

    mutating func requestChanged(to requestID: UUID?) -> Action {
        currentRequestID = requestID
        guard let requestID else {
            guard presentedRequestID != nil else { return .none }
            presentedRequestID = nil
            return .dismiss
        }
        if presentedRequestID == requestID {
            return .none
        }
        if isMeetingCaptureActive && presentedRequestID == nil {
            return .none
        }
        presentedRequestID = requestID
        return .present(requestID)
    }

    mutating func meetingCaptureChanged(isActive: Bool) -> Action {
        isMeetingCaptureActive = isActive
        guard !isActive, let currentRequestID, presentedRequestID != currentRequestID else {
            return .none
        }
        presentedRequestID = currentRequestID
        return .present(currentRequestID)
    }

    /// A review window closed (Save, Review Later, the close box, or being
    /// replaced). Only the window for the presented request counts, so a
    /// replaced window closing can't forget its replacement. That request is
    /// finished either way, so it is never shown again even if its clearing
    /// arrives after a recording stops.
    mutating func windowClosed(requestID: UUID) {
        guard presentedRequestID == requestID else { return }
        presentedRequestID = nil
        if currentRequestID == requestID {
            currentRequestID = nil
        }
    }
}

/// Header copy for the speaker review window.
enum SpeakerReviewPresentationCopy {
    static let subtitle = "Transcript saved. Name unknown voices, confirm suggested matches, or review later on the Speakers page."

    /// "Review speakers · Weekly sync", or the generic title when the
    /// meeting's name can't be read.
    static func title(meetingTitle: String?) -> String {
        let trimmed = meetingTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Review meeting speakers" : "Review speakers · \(trimmed)"
    }
}
