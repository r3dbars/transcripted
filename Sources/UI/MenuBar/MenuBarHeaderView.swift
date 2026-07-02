// MenuBarHeaderView.swift
// Top status zone for the menubar popover.

import AppKit

struct MenuBarHeaderSmokeSnapshot: Codable, Equatable {
    let statusText: String
    let detailText: String
    let warningText: String
    let isReady: Bool
}

@MainActor
final class MenuBarHeaderView: NSView {
    private let titleLabel = NSTextField(labelWithString: "Transcripted")
    private let statusDot = NSView()
    private let statusLabel = NSTextField(labelWithString: "Ready")
    private let progressBar = NSProgressIndicator()
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let warningIconView = NSImageView()
    private let warningLabel = NSTextField(wrappingLabelWithString: "")

    private var currentWarmupStatus: MeetingSessionController.ModelWarmupStatus = .ready
    private var currentHotkeyError: String?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func setupViews() {
        titleLabel.font = NSFont.systemFont(ofSize: 15.5, weight: .semibold)
        titleLabel.textColor = MenuTokens.textPrimaryNS
        addSubview(titleLabel)

        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = MenuTokens.statusDotSize / 2
        addSubview(statusDot)

        statusLabel.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        statusLabel.textColor = MenuTokens.textSecondaryNS
        addSubview(statusLabel)

        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        addSubview(progressBar)

        detailLabel.font = NSFont.systemFont(ofSize: 10)
        detailLabel.textColor = MenuTokens.textSecondaryNS
        detailLabel.maximumNumberOfLines = 2
        addSubview(detailLabel)

        if let image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Warning") {
            warningIconView.image = image
            warningIconView.contentTintColor = MenuTokens.statusOrangeNS
        }
        addSubview(warningIconView)

        warningLabel.font = NSFont.systemFont(ofSize: 10)
        warningLabel.textColor = MenuTokens.textSecondaryNS
        warningLabel.maximumNumberOfLines = 2
        addSubview(warningLabel)
    }

    override func layout() {
        super.layout()

        let isReady = currentWarmupStatus.isReadyForMenuHeader
        let hasWarning = currentHotkeyError?.isEmpty == false

        if isReady && !hasWarning {
            let dotSize = MenuTokens.statusDotSize
            let labelWidth = statusLabel.intrinsicContentSize.width
            let statusWidth = dotSize + 6 + labelWidth
            let statusX = bounds.width - statusWidth
            titleLabel.frame = NSRect(x: 0, y: 0, width: max(120, statusX - 8), height: 20)
            statusDot.frame = NSRect(x: statusX, y: 7, width: dotSize, height: dotSize)
            statusLabel.frame = NSRect(x: statusDot.frame.maxX + 6, y: 3, width: labelWidth, height: 16)
        } else {
            titleLabel.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 20)
            let statusY: CGFloat = 22
            let dotSize = MenuTokens.statusDotSize
            statusDot.frame = NSRect(x: 0, y: statusY + 3, width: dotSize, height: dotSize)
            statusLabel.frame = NSRect(x: dotSize + 8, y: statusY, width: bounds.width - dotSize - 8, height: 14)
        }

        progressBar.isHidden = isReady
        detailLabel.isHidden = isReady
        if !isReady {
            progressBar.frame = NSRect(x: 0, y: 42, width: bounds.width, height: 8)
            detailLabel.frame = NSRect(x: 0, y: 54, width: bounds.width, height: 24)
        }

        warningIconView.isHidden = !hasWarning
        warningLabel.isHidden = !hasWarning
        if hasWarning {
            let warningY = MenuBarHeaderLayoutPolicy.warningTop(isReady: isReady)
            warningIconView.frame = NSRect(x: 0, y: warningY + 1, width: 12, height: 12)
            warningLabel.frame = NSRect(
                x: 18,
                y: warningY - 1,
                width: bounds.width - 18,
                height: MenuBarHeaderLayoutPolicy.warningTextHeight
            )
        }
    }

    func update(
        warmupStatus: MeetingSessionController.ModelWarmupStatus,
        hotkeyError: String?,
        isMeetingRecording: Bool = false
    ) {
        currentWarmupStatus = warmupStatus
        currentHotkeyError = hotkeyError

        let isReady = warmupStatus.isReadyForMenuHeader
        if isMeetingRecording {
            statusDot.layer?.backgroundColor = NSColor.systemRed.cgColor
            statusLabel.stringValue = "Recording"
        } else {
            statusDot.layer?.backgroundColor = (isReady ? MenuTokens.statusGreenNS : MenuTokens.statusOrangeNS).cgColor
            statusLabel.stringValue = isReady ? "Ready" : warmupStatus.subtitle
        }
        progressBar.doubleValue = warmupStatus.progress
        detailLabel.stringValue = isReady ? "" : warmupStatus.detail
        warningLabel.stringValue = hotkeyError ?? ""

        needsLayout = true
        invalidateIntrinsicContentSize()
    }

    var intrinsicHeight: CGFloat {
        let isReady = currentWarmupStatus.isReadyForMenuHeader
        let hasWarning = currentHotkeyError?.isEmpty == false
        return MenuBarHeaderLayoutPolicy.intrinsicHeight(isReady: isReady, hasWarning: hasWarning)
    }

    var smokeSnapshot: MenuBarHeaderSmokeSnapshot {
        MenuBarHeaderSmokeSnapshot(
            statusText: statusLabel.stringValue,
            detailText: detailLabel.stringValue,
            warningText: warningLabel.stringValue,
            isReady: currentWarmupStatus.isReadyForMenuHeader
        )
    }
}
