// OverlayToolbarView.swift
// Bottom toolbar for the floating overlay — hints and status indicators

import AppKit

@MainActor
final class OverlayToolbarView: NSView {
    private let leftContainer = NSView()
    private let editedDot = NSView()
    private let editedLabel = NSTextField(labelWithString: "")
    private let voiceOnlyLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setupViews() {
        // Left container for edited indicator or voice-only label
        addSubview(leftContainer)

        // Green dot
        editedDot.wantsLayer = true
        editedDot.layer?.cornerRadius = 2.5
        editedDot.layer?.backgroundColor = OverlayTokens.accentGreen.cgColor
        editedDot.isHidden = true
        leftContainer.addSubview(editedDot)

        // "edited . teaching Transcripted" label
        editedLabel.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        editedLabel.textColor = OverlayTokens.accentGreen
        editedLabel.isBezeled = false
        editedLabel.isEditable = false
        editedLabel.drawsBackground = false
        editedLabel.isHidden = true
        leftContainer.addSubview(editedLabel)

        // "voice only" label
        voiceOnlyLabel.font = NSFont.systemFont(ofSize: 10)
        voiceOnlyLabel.textColor = OverlayTokens.textMuted
        voiceOnlyLabel.stringValue = "voice only"
        voiceOnlyLabel.isBezeled = false
        voiceOnlyLabel.isEditable = false
        voiceOnlyLabel.drawsBackground = false
        voiceOnlyLabel.isHidden = true
        leftContainer.addSubview(voiceOnlyLabel)

        // Right hint label
        hintLabel.font = NSFont.systemFont(ofSize: 10)
        hintLabel.textColor = OverlayTokens.textMuted
        hintLabel.isBezeled = false
        hintLabel.isEditable = false
        hintLabel.drawsBackground = false
        hintLabel.alignment = .right
        addSubview(hintLabel)
    }

    override func layout() {
        super.layout()
        let pad = OverlayTokens.contentPadding
        let h = bounds.height

        // Left container
        leftContainer.frame = NSRect(x: pad, y: 0, width: bounds.width / 2 - pad, height: h)

        // Green dot
        editedDot.frame = NSRect(x: 0, y: (h - 5) / 2, width: 5, height: 5)
        editedLabel.frame = NSRect(x: 9, y: (h - editedLabel.fittingSize.height) / 2, width: leftContainer.frame.width - 9, height: editedLabel.fittingSize.height)
        voiceOnlyLabel.frame = NSRect(x: 0, y: (h - voiceOnlyLabel.fittingSize.height) / 2, width: leftContainer.frame.width, height: voiceOnlyLabel.fittingSize.height)

        // Right hint
        let hintSize = hintLabel.fittingSize
        hintLabel.frame = NSRect(x: bounds.width - pad - hintSize.width, y: (h - hintSize.height) / 2, width: hintSize.width, height: hintSize.height)
    }

    func update(state: FloatingOverlayController.OverlayState,
                hasEdits: Bool, hasContext: Bool) {
        switch state {
        case .review:
            isHidden = false
            if hasEdits {
                editedDot.isHidden = false
                editedLabel.isHidden = false
                editedLabel.stringValue = "edited \u{00B7} teaching Transcripted"
                voiceOnlyLabel.isHidden = true
            } else if !hasContext {
                editedDot.isHidden = true
                editedLabel.isHidden = true
                voiceOnlyLabel.isHidden = false
            } else {
                editedDot.isHidden = true
                editedLabel.isHidden = true
                voiceOnlyLabel.isHidden = true
            }
            hintLabel.stringValue = "\u{21A9} send \u{00B7} Esc cancel"

        case .diffFlash:
            isHidden = false
            editedDot.isHidden = false
            editedLabel.isHidden = false
            editedLabel.stringValue = "learning from your edits"
            voiceOnlyLabel.isHidden = true
            hintLabel.stringValue = "\u{21A9} confirm \u{00B7} Esc go back"

        default:
            isHidden = true
        }
        needsLayout = true
    }
}
