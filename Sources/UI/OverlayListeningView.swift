// OverlayListeningView.swift
// Content view during listening state — live transcript or placeholder

import AppKit

@MainActor
final class OverlayListeningView: NSView {
    private let scrollView = NSScrollView()
    private let transcriptField = NSTextField(wrappingLabelWithString: "")
    private let placeholderLabel = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setupViews() {
        // Transcript scroll view
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

        transcriptField.font = NSFont.systemFont(ofSize: 13)
        transcriptField.textColor = OverlayTokens.textPrimary
        transcriptField.isBezeled = false
        transcriptField.isEditable = false
        transcriptField.drawsBackground = false
        transcriptField.lineBreakMode = .byWordWrapping
        transcriptField.maximumNumberOfLines = 0
        transcriptField.preferredMaxLayoutWidth = OverlayTokens.panelWidth - OverlayTokens.contentPadding * 2

        scrollView.documentView = transcriptField
        addSubview(scrollView)

        // Placeholder
        placeholderLabel.font = NSFont.systemFont(ofSize: 12)
        placeholderLabel.textColor = OverlayTokens.textMuted
        placeholderLabel.isBezeled = false
        placeholderLabel.isEditable = false
        placeholderLabel.drawsBackground = false
        placeholderLabel.alignment = .center
        addSubview(placeholderLabel)
    }

    override func layout() {
        super.layout()
        let pad = OverlayTokens.contentPadding
        let inset = NSRect(
            x: pad,
            y: 12,
            width: bounds.width - pad * 2,
            height: bounds.height - 24
        )
        scrollView.frame = inset
        placeholderLabel.frame = bounds

        // Size transcript field to fit content width
        transcriptField.preferredMaxLayoutWidth = inset.width
        let fittingSize = transcriptField.fittingSize
        transcriptField.frame = NSRect(
            x: 0,
            y: 0,
            width: inset.width,
            height: max(inset.height, fittingSize.height)
        )
    }

    func updateTranscript(_ text: String) {
        let hasText = !text.isEmpty
        scrollView.isHidden = !hasText
        placeholderLabel.isHidden = hasText

        if hasText {
            transcriptField.stringValue = text
            // Re-layout and scroll to bottom
            transcriptField.preferredMaxLayoutWidth = scrollView.frame.width
            let fittingSize = transcriptField.fittingSize
            transcriptField.frame = NSRect(
                x: 0,
                y: 0,
                width: scrollView.frame.width,
                height: max(scrollView.frame.height, fittingSize.height)
            )
            // Scroll to bottom
            if let docView = scrollView.documentView {
                let bottomPoint = NSPoint(x: 0, y: docView.frame.maxY - scrollView.contentSize.height)
                scrollView.contentView.scroll(to: bottomPoint)
            }
        }
    }

    func updatePlaceholder(mode: FloatingOverlayController.SessionMode,
                           draftHint: String, dictationHint: String) {
        let _ = draftHint
        let _ = dictationHint
        if mode == .dictation {
            placeholderLabel.stringValue = "Listening..."
        } else {
            placeholderLabel.stringValue = "Listening..."
        }
    }
}
