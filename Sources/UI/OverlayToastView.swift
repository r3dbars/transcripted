// OverlayToastView.swift
// Brief floating toast after accepting an edited draft — pure AppKit

import AppKit

@MainActor
final class OverlayToastView: NSView {
    private let iconView = NSImageView()
    private let messageLabel = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setupViews() {
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.70).cgColor

        // Icon: brain SF Symbol in accent green
        if let image = NSImage(systemSymbolName: "brain.head.profile.fill", accessibilityDescription: "Learning") {
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            iconView.image = image.withSymbolConfiguration(config)
            iconView.contentTintColor = OverlayTokens.accentGreen
        }
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        // Message
        messageLabel.font = NSFont.systemFont(ofSize: 12)
        messageLabel.textColor = OverlayTokens.textPrimary
        messageLabel.maximumNumberOfLines = 2
        messageLabel.lineBreakMode = .byTruncatingTail
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(messageLabel)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),

            messageLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            messageLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            messageLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func update(message: String) {
        messageLabel.stringValue = message
    }
}
