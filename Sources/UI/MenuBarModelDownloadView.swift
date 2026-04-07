// MenuBarModelDownloadView.swift
// Warm-up progress card for Transcripted's local dictation and meeting models

import AppKit

@MainActor
final class MenuBarModelDownloadView: NSView {
    private let titleLabel = NSTextField(labelWithString: "Getting Transcripted ready")
    private let subtitleLabel = NSTextField(labelWithString: "Loading dictation and meeting models")
    private let progressBar = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = MenuTokens.cardCornerRadius
        layer?.backgroundColor = MenuTokens.cardBackgroundNS.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = MenuTokens.cardBorderNS.cgColor

        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = MenuTokens.textPrimaryNS
        addSubview(titleLabel)

        subtitleLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        subtitleLabel.textColor = MenuTokens.textSecondaryNS
        addSubview(subtitleLabel)

        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.doubleValue = 0
        addSubview(progressBar)

        statusLabel.font = NSFont.systemFont(ofSize: 10)
        statusLabel.textColor = MenuTokens.textSecondaryNS
        statusLabel.lineBreakMode = .byTruncatingTail
        addSubview(statusLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let pad: CGFloat = 12
        let contentWidth = bounds.width - pad * 2

        titleLabel.frame = NSRect(x: pad, y: bounds.height - 26, width: contentWidth, height: 16)
        subtitleLabel.frame = NSRect(x: pad, y: bounds.height - 44, width: contentWidth, height: 14)
        progressBar.frame = NSRect(x: pad, y: bounds.height - 62, width: contentWidth, height: 8)
        statusLabel.frame = NSRect(x: pad, y: 12, width: contentWidth, height: 12)
    }

    func update(warmupStatus: MeetingSessionController.ModelWarmupStatus) {
        titleLabel.stringValue = warmupStatus.title
        subtitleLabel.stringValue = warmupStatus.subtitle
        progressBar.doubleValue = warmupStatus.progress
        if warmupStatus.dictationStatus == "Failed" || warmupStatus.meetingsStatus == "Failed" {
            statusLabel.stringValue = warmupStatus.detail
        } else {
            statusLabel.stringValue = "Dictation \(warmupStatus.dictationStatus) • Meetings \(warmupStatus.meetingsStatus)"
        }
        needsLayout = true
    }

    var intrinsicHeight: CGFloat { 78 }
}
