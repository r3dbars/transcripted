// NotchIslandSpeakerReviewView+Mic.swift
// The local mic's voices in "Who spoke?". The mic is the owner, so its voices
// start as You and the review doesn't ask: one quiet line, "On your mic · You",
// with "Not just me?" for the times someone else used the mic. That opens a
// row per mic voice under a small "On your mic" header with "Just me" to put
// them back. The rule for what each saves is NotchIslandSpeakerReviewPolicy's
// Lock (`.keptAsYou`); the island's Later leaves an untouched default unsaved
// (`collectUpdates`), so only a Done saves it.

import AppKit

@available(macOS 14.0, *)
extension NotchIslandSpeakerReviewView {
    /// The mic line: "On your mic · You" and "Not just me?", or, while each
    /// voice is named, "On your mic" and "Just me" over the rows.
    func micSectionHeader() -> NSView {
        let label = NotchIslandPalette.label(
            NotchIslandSpeakerReviewPolicy.micLineTitle,
            font: .systemFont(ofSize: 12, weight: .semibold),
            color: NSColor(white: 1, alpha: 0.42)
        )
        var views: [NSView] = [label]
        if keepMicAsYou {
            let you = NotchIslandPalette.label(
                SpeakerNameSelectionPolicy.ownerLabel,
                font: .systemFont(ofSize: 13, weight: .semibold),
                color: NotchIslandPalette.primaryText
            )
            views.append(you)
        }
        let toggle = NotchIslandTextButton(
            title: NotchIslandSpeakerReviewPolicy.keepAsYouTitle(keepMicAsYou: keepMicAsYou),
            restAlpha: 0.6
        )
        toggle.onPress = { [weak self] in self?.toggleKeepMicAsYou() }
        toggle.setAccessibilityLabel(NotchIslandSpeakerReviewPolicy.keepAsYouAccessibilityLabel(keepMicAsYou: keepMicAsYou))
        toggle.setAccessibilityHelp(NotchIslandSpeakerReviewPolicy.keepAsYouHelp(keepMicAsYou: keepMicAsYou))
        toggle.setAccessibilityIdentifier("speaker-review-mic-line")
        views += [NSView(), toggle]
        let line = NSStackView(views: views)
        line.orientation = .horizontal
        line.alignment = .firstBaseline
        line.spacing = 8
        line.edgeInsets = NSEdgeInsets(top: 6, left: 0, bottom: keepMicAsYou ? 6 : 0, right: 0)
        line.translatesAutoresizingMaskIntoConstraints = false
        line.widthAnchor.constraint(equalToConstant: width).isActive = true
        return line
    }

    /// "Not just me?" names each mic voice; "Just me" makes them all You
    /// again (`.collapsedToMe`), whatever was typed for them.
    func toggleKeepMicAsYou() {
        stopLaterCountdown()
        keepMicAsYou.toggle()
        for row in rows where row.isMic {
            row.setKeptAsYou(keepMicAsYou)
        }
        assignColors()
        redrawKeepingAnswers()
    }
}
