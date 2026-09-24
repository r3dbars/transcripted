// MenuBarHeaderStatusPresentation.swift
// Foundation-pure presentation policy for the menubar header's status line.

import Foundation

/// Decides what the header's status dot and label communicate, so the
/// recording / ready / warmup precedence lives outside view code and stays
/// unit-testable. The view maps `Tone` onto its dot colors.
struct MenuBarHeaderStatusPresentation: Equatable {
    enum Tone: Equatable {
        case recording
        case ready
        case working
    }

    let text: String
    let tone: Tone

    /// Recording wins over everything: an active meeting capture is the one
    /// state the user must never misread (shown as "Starting…"/"Saving…"
    /// while the mic engages or the audio is handed off). A meeting
    /// transcript being made comes next, so the popover never reads "Ready" while minutes of work
    /// are still running. Otherwise ready shows "Ready", and a warming-up
    /// header surfaces the warmup subtitle as-is.
    static func resolve(
        isReady: Bool,
        isMeetingRecording: Bool,
        warmupSubtitle: String,
        transcribingStatus: String? = nil,
        capturePhase: MenuBarMeetingCapturePhase? = nil
    ) -> MenuBarHeaderStatusPresentation {
        if isMeetingRecording {
            // Red only while the mic is really recording; starting and
            // saving are work in progress.
            let phase = capturePhase ?? .recording
            return MenuBarHeaderStatusPresentation(
                text: phase.headerText,
                tone: phase == .recording ? .recording : .working
            )
        }
        if isReady, let transcribingStatus, !transcribingStatus.isEmpty {
            return MenuBarHeaderStatusPresentation(text: transcribingStatus, tone: .working)
        }
        if isReady {
            return MenuBarHeaderStatusPresentation(text: "Ready", tone: .ready)
        }
        return MenuBarHeaderStatusPresentation(text: warmupSubtitle, tone: .working)
    }
}
