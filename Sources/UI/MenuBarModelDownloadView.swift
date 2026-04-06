// MenuBarModelDownloadView.swift
// Warm-up progress card for Draft's local dictation and meeting models

import AppKit

@MainActor
final class MenuBarModelDownloadView: NSView {
    private let titleLabel = NSTextField(labelWithString: "Getting Draft ready")
    private let subtitleLabel = NSTextField(labelWithString: "Loading dictation and meeting models")
    private let progressBar = NSProgressIndicator()
    private let dictationLabel = NSTextField(labelWithString: "Dictation")
    private let dictationStatusLabel = NSTextField(labelWithString: "Waiting")
    private let meetingsLabel = NSTextField(labelWithString: "Meetings")
    private let meetingsStatusLabel = NSTextField(labelWithString: "Waiting")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")

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

        dictationLabel.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        dictationLabel.textColor = MenuTokens.textMutedNS
        addSubview(dictationLabel)

        dictationStatusLabel.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        dictationStatusLabel.textColor = MenuTokens.textSecondaryNS
        addSubview(dictationStatusLabel)

        meetingsLabel.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        meetingsLabel.textColor = MenuTokens.textMutedNS
        addSubview(meetingsLabel)

        meetingsStatusLabel.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        meetingsStatusLabel.textColor = MenuTokens.textSecondaryNS
        meetingsStatusLabel.alignment = .right
        addSubview(meetingsStatusLabel)

        detailLabel.font = NSFont.systemFont(ofSize: 10)
        detailLabel.textColor = MenuTokens.textSecondaryNS
        detailLabel.maximumNumberOfLines = 2
        detailLabel.lineBreakMode = .byWordWrapping
        addSubview(detailLabel)
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

        let rowY = bounds.height - 84
        dictationLabel.frame = NSRect(x: pad, y: rowY, width: 54, height: 12)
        dictationStatusLabel.frame = NSRect(x: dictationLabel.frame.maxX + 4, y: rowY, width: 90, height: 12)

        meetingsStatusLabel.frame = NSRect(x: bounds.width - pad - 72, y: rowY, width: 72, height: 12)
        meetingsLabel.frame = NSRect(x: meetingsStatusLabel.frame.minX - 56, y: rowY, width: 52, height: 12)

        detailLabel.frame = NSRect(x: pad, y: 12, width: contentWidth, height: 24)
    }

    func update(warmupStatus: MeetingSessionController.ModelWarmupStatus) {
        titleLabel.stringValue = warmupStatus.title
        subtitleLabel.stringValue = warmupStatus.subtitle
        progressBar.doubleValue = warmupStatus.progress
        dictationStatusLabel.stringValue = warmupStatus.dictationStatus
        meetingsStatusLabel.stringValue = warmupStatus.meetingsStatus
        detailLabel.stringValue = warmupStatus.detail
        needsLayout = true
    }

    var intrinsicHeight: CGFloat { 104 }
}
