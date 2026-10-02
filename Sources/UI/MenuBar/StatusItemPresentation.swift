// StatusItemPresentation.swift
// What the always-visible status item shows for each capture state, and the
// one place that writes it onto the button. The delegate calls `apply` at
// launch and on every recording change, so tests can drive the same path.

import AppKit

enum StatusItemPresentation {
    static let idleLabel = "Transcripted"

    /// A meeting outranks dictation; with neither it's the idle outline.
    static func `for`(meetingRecording: Bool, dictating: Bool) -> (glyph: MenuBarGlyph, label: String) {
        if meetingRecording {
            return (.meetingRecording, "Transcripted — recording meeting")
        }
        if dictating {
            return (.dictating, "Transcripted — dictating")
        }
        return (.idle, idleLabel)
    }

    /// Single writer for the button's image, tint, tooltip, and accessibility
    /// label so the recording indicator and the update badge can't fight over
    /// shared button state.
    ///
    /// Keep the always-visible status item quiet during screen sharing. The
    /// app icon's bubble is a template image in every state: distinct
    /// silhouettes (outline, filled, filled + dot) and accessibility labels
    /// preserve capture state; destructive Stop controls inside the open menus
    /// keep their red tone.
    static func apply(
        to button: NSButton,
        meetingRecording: Bool,
        dictating: Bool,
        updateTooltip: String?
    ) {
        let (glyph, label) = self.for(meetingRecording: meetingRecording, dictating: dictating)
        button.image = glyph.image(accessibilityDescription: label)
        button.contentTintColor = nil
        button.setAccessibilityLabel(label)
        if let updateTooltip {
            button.toolTip = "\(label) - \(updateTooltip)"
        } else {
            button.toolTip = label
        }
    }
}
