// MeetingPillFinishPresentation.swift
// Foundation-pure presentation for how a meeting finishes on the meeting pill
// and the menubar header: transcription progress, the saved pill (its dwell
// timing and the meeting's name), and whether an error pill offers Open.

import Foundation

enum MeetingPillFinishPresentation {
    /// How long the "Saved to Markdown" pill stays up so there is time to
    /// read the meeting's name and click Open.
    static let savedPillDwellSeconds: Double = 6
    /// After the pointer leaves a saved pill it was resting on.
    static let savedPillHoverOutDwellSeconds: Double = 2.5

    /// Whole percent for a pipeline progress value, or nil when there is no
    /// meaningful number to show (not started, or already done).
    static func percent(progress: Double?) -> Int? {
        guard let progress, progress.isFinite, progress > 0, progress < 1 else { return nil }
        return min(99, max(1, Int((progress * 100).rounded(.down))))
    }

    /// "1 more waiting" / "2 more waiting", or nil with nothing queued.
    static func queuedText(queuedCount: Int) -> String? {
        guard queuedCount > 0 else { return nil }
        return "\(queuedCount) more waiting"
    }

    /// Secondary text beside "Transcribing meeting…" on the pill:
    /// "42%", "42% · 1 more waiting", "1 more waiting", or "".
    static func pillDetail(progress: Double?, queuedCount: Int) -> String {
        let parts = [
            percent(progress: progress).map { "\($0)%" },
            queuedText(queuedCount: queuedCount)
        ].compactMap { $0 }
        return parts.joined(separator: " · ")
    }

    /// Menubar header status while a meeting transcript is being made:
    /// "Transcribing 42%", "Transcribing · 1 more waiting", or "Transcribing".
    static func menuStatus(progress: Double?, queuedCount: Int) -> String {
        var text = "Transcribing"
        if let percent = percent(progress: progress) {
            text += " \(percent)%"
        }
        if let queued = queuedText(queuedCount: queuedCount) {
            text += " · \(queued)"
        }
        return text
    }

    /// Secondary text beside "Saved to Markdown": the meeting's name when it
    /// is known, else a plain pointer to the Open button.
    static func savedDetail(meetingTitle: String?) -> String {
        let trimmed = meetingTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Ready to read" : trimmed
    }

    /// Whether the error pill offers "Open" (the Meetings page). Only when a
    /// failed-meeting row exists to act on, and not for failures that happen
    /// before any audio is saved (permissions, a device that would not start,
    /// a mis-tap): there is nothing on the Meetings page for those.
    static func errorOffersOpenMeetings(failureKind: MeetingFailureKind, hasFailedMeetingRows: Bool) -> Bool {
        guard hasFailedMeetingRows else { return false }
        switch failureKind {
        case .systemAudioPermission,
             .systemAudioPermissionCheckInconclusive,
             .microphonePermission,
             .microphoneStartFailed,
             .systemAudioStartFailed,
             .meetingAudioStartFailed,
             .microphoneMissing,
             .recordingTooShort:
            return false
        default:
            return true
        }
    }
}
