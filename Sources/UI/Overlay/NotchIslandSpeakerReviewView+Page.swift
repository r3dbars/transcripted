// NotchIslandSpeakerReviewView+Page.swift
// The island's "Who spoke?" drawn as a card on Settings › Speakers, one saved
// meeting at a time (`Chrome.page`). The rows, ✓ / ✕, the name field and its
// suggestions, All me, Not a person and the footer's glowing dots are the
// island's own. What differs: the header names the meeting ("Who spoke? ·
// Weekly sync" and its date), each voice shows its quote, there's no Later
// ring, and the buttons are Skip and "Done, next meeting". Done hands the
// answers to the page and leaves the card as it is, so the page's Undo can
// bring it back with every answer still in place.

import AppKit
import TranscriptedCore

@available(macOS 14.0, *)
extension NotchIslandSpeakerReviewView {
    var isPage: Bool { pageCard != nil }

    var pageCard: PageCard? {
        if case .page(let card) = chrome { return card }
        return nil
    }

    /// "Who spoke? · Weekly sync" on the left, the meeting's date on the right.
    func pageHeaderLine() -> NSView {
        let title = NotchIslandPalette.label(
            pageCard?.title ?? NotchIslandSpeakerReviewPolicy.headerTitle,
            font: .systemFont(ofSize: 15, weight: .semibold),
            color: NotchIslandPalette.primaryText
        )
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var views: [NSView] = [title, NSView()]
        if let detail = pageCard?.detail {
            let date = NotchIslandPalette.label(detail, font: .systemFont(ofSize: 12), color: NSColor(white: 1, alpha: 0.55))
            date.setContentCompressionResistancePriority(.required, for: .horizontal)
            date.setContentHuggingPriority(.required, for: .horizontal)
            views.append(date)
        }
        let line = NSStackView(views: views)
        line.orientation = .horizontal
        line.alignment = .firstBaseline
        line.spacing = 12
        line.translatesAutoresizingMaskIntoConstraints = false
        line.widthAnchor.constraint(equalToConstant: width).isActive = true
        line.setAccessibilityElement(false)
        return line
    }

    /// Skip, then "Done, next meeting".
    func pageButtons(_ card: PageCard, done: NotchIslandButton) -> NSStackView {
        let skip = NotchIslandButton(title: card.skipTitle, style: .link, height: 30, fontSize: 13)
        skip.setAccessibilityHelp(card.skipHelp)
        skip.setAccessibilityIdentifier("transcripted.speakers.who-spoke.skip")
        skip.onPress = { [weak self] in self?.skipPage() }
        done.setAccessibilityHelp("Save these names and go on to the next meeting.")
        done.setAccessibilityIdentifier("transcripted.speakers.who-spoke.done")
        let buttons = NSStackView(views: [skip, done])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 16
        buttons.setHuggingPriority(.required, for: .horizontal)
        return buttons
    }

    /// Something on the card was answered or typed, so rebuilding it would
    /// lose work.
    var hasDraft: Bool {
        keepsMicAsYou || rows.contains { row in
            row.answer != .none || row.isDiscarded || !row.nameField.stringValue.isEmpty
        }
    }

    /// The page's words changed (Done becomes "Done, next meeting" when
    /// another meeting lines up). The answers on the card stay as they are.
    func updatePageCard(_ card: PageCard) {
        guard case .page(let current) = chrome, current != card else { return }
        chrome = .page(card)
        if current.doneTitle != card.doneTitle {
            pageDoneButton?.replaceTitle(card.doneTitle)
            pageDoneButton?.setAccessibilityLabel(card.doneTitle)
            onLayoutChange?()
        }
    }

    /// Done on the page: every answer, read the way the island's Done reads
    /// it (a name left typed in a field counts). The card stays as it is.
    func finishPageDone() {
        SpeakerClipPlayback.stop()
        let result = collectUpdates(finish: .done)
        onDone?(result.updates, result.unanswered)
    }

    /// Skip: save what was answered, the way the island's Later does, and let
    /// the page stop asking about the rest.
    private func skipPage() {
        SpeakerClipPlayback.stop()
        onSkip?(collectUpdates(finish: .later).updates)
    }
}
