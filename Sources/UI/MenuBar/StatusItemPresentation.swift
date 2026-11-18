// StatusItemPresentation.swift
// What the always-visible status item shows for each state, and the one place
// that writes it onto the button. The delegate calls `apply` at launch and on
// every change, so tests can drive the same path.

import AppKit

enum StatusItemPresentation {
    static let idleLabel = "Transcripted"

    /// Something that needs a click, shown on the idle glyph as a dot.
    enum Attention: Equatable {
        /// The dictation and meeting keys can't work until Accessibility is on.
        case shortcutsNeedAccessibility
        /// An update needs a click (install, or restart to finish).
        case updateNeedsClick
    }

    /// Capture outranks everything: a meeting, then dictation. Then a meeting
    /// transcript being made, then something that needs a click.
    static func `for`(
        meetingRecording: Bool,
        dictating: Bool,
        transcribing: Bool = false,
        attention: Attention? = nil
    ) -> (glyph: MenuBarGlyph, label: String) {
        if meetingRecording {
            return (.meetingRecording, "Transcripted — recording meeting")
        }
        if dictating {
            return (.dictating, "Transcripted — dictating")
        }
        if transcribing {
            return (.working, "Transcripted — making a transcript")
        }
        switch attention {
        case .shortcutsNeedAccessibility:
            return (.attention, "Transcripted — your key needs Accessibility")
        case .updateNeedsClick:
            return (.attention, "Transcripted — update ready")
        case nil:
            return (.idle, idleLabel)
        }
    }

    /// Single writer for the button's image, tint, tooltip, and accessibility
    /// label so the capture indicator, the attention dot and the update note
    /// can't fight over shared button state.
    ///
    /// Keep the always-visible status item quiet during screen sharing. The
    /// app icon's bubble is a template image in every state: distinct
    /// silhouettes (outline, filled, filled + dot, outline + dot, outline +
    /// ring) and accessibility labels carry the state; nothing is tinted. The
    /// red Stop and green live marks stay inside the open popover and island.
    @MainActor
    static func apply(
        to button: NSButton,
        meetingRecording: Bool,
        dictating: Bool,
        transcribing: Bool = false,
        attention: Attention? = nil,
        updateTooltip: String?
    ) {
        let (glyph, label) = self.for(
            meetingRecording: meetingRecording,
            dictating: dictating,
            transcribing: transcribing,
            attention: attention
        )
        button.image = glyph.image(accessibilityDescription: label)
        button.contentTintColor = nil
        button.setAccessibilityLabel(label)
        guard let updateTooltip else {
            button.toolTip = label
            return
        }
        // When the dot is the update, the update note replaces "update ready".
        let showsUpdateDot = glyph == .attention && attention == .updateNeedsClick
        button.toolTip = "\(showsUpdateDot ? idleLabel : label) — \(updateTooltip)"
    }
}
