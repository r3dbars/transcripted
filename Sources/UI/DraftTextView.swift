// DraftTextView.swift
// NSTextView subclass for the review state — handles Enter/Escape/Shift+Enter

import AppKit

@MainActor
final class DraftTextView: NSTextView {
    /// Called when user presses Enter (non-empty text)
    var onConfirm: (() -> Void)?
    /// Called when user presses Escape
    var onCancel: (() -> Void)?
    /// Called on every text change (syncs text back to controller)
    var onTextChange: ((String) -> Void)?

    convenience init() {
        self.init(frame: .zero)
        configureDefaults()
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        configureDefaults()
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        configureDefaults()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func configureDefaults() {
        isRichText = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticTextCompletionEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        font = NSFont.systemFont(ofSize: 13)
        textColor = OverlayTokens.textPrimary
        backgroundColor = .clear
        insertionPointColor = OverlayTokens.textPrimary
        drawsBackground = false
        isEditable = true
        isSelectable = true
        allowsUndo = true
        textContainerInset = NSSize(width: 8, height: 8)
        isVerticallyResizable = true
        isHorizontallyResizable = false
        textContainer?.widthTracksTextView = true
        textContainer?.heightTracksTextView = false
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36: // Return
            if event.modifierFlags.contains(.shift) {
                // Shift+Enter: insert newline
                super.keyDown(with: event)
            } else {
                // Enter: confirm (if non-empty)
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                onConfirm?()
            }
        case 53: // Escape
            onCancel?()
        default:
            super.keyDown(with: event)
        }
    }

    override func didChangeText() {
        super.didChangeText()
        onTextChange?(string)
    }
}
