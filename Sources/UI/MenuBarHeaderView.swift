// MenuBarHeaderView.swift
// Header section: simple title + readiness status

import AppKit

@MainActor
final class MenuBarHeaderView: NSView {
    private let titleLabel = NSTextField(labelWithString: "Draft")
    private let statusDot = NSView()
    private let statusLabel = NSTextField(labelWithString: "Ready")

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setupViews() {
        titleLabel.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        titleLabel.textColor = MenuTokens.textPrimaryNS
        addSubview(titleLabel)

        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = MenuTokens.statusDotSize / 2
        statusDot.layer?.backgroundColor = MenuTokens.statusGreenNS.cgColor
        addSubview(statusDot)

        statusLabel.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        statusLabel.textColor = MenuTokens.textSecondaryNS
        addSubview(statusLabel)
    }

    override func layout() {
        super.layout()
        let titleSize = titleLabel.fittingSize
        titleLabel.frame = NSRect(x: 0, y: bounds.height - titleSize.height, width: titleSize.width, height: titleSize.height)

        let dotSize = MenuTokens.statusDotSize
        let statusSize = statusLabel.fittingSize
        let statusY = titleLabel.frame.minY - 6 - statusSize.height
        statusDot.frame = NSRect(x: 0, y: statusY + (statusSize.height - dotSize) / 2, width: dotSize, height: dotSize)
        statusLabel.frame = NSRect(x: dotSize + 6, y: statusY, width: bounds.width - dotSize - 6, height: statusSize.height)
    }

    func update(isReady: Bool, statusText: String) {
        statusDot.layer?.backgroundColor = (isReady ? MenuTokens.statusGreenNS : MenuTokens.statusOrangeNS).cgColor
        statusLabel.stringValue = statusText
        needsLayout = true
    }

    var intrinsicHeight: CGFloat { 36 }
}
