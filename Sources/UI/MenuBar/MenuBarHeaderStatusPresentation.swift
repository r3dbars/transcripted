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
    /// state the user must never misread. Otherwise ready shows "Ready", and
    /// a warming-up header surfaces the warmup subtitle as-is.
    static func resolve(
        isReady: Bool,
        isMeetingRecording: Bool,
        warmupSubtitle: String
    ) -> MenuBarHeaderStatusPresentation {
        if isMeetingRecording {
            return MenuBarHeaderStatusPresentation(text: "Recording", tone: .recording)
        }
        if isReady {
            return MenuBarHeaderStatusPresentation(text: "Ready", tone: .ready)
        }
        return MenuBarHeaderStatusPresentation(text: warmupSubtitle, tone: .working)
    }
}
