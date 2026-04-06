// MenuBarHeaderView.swift
// Top status zone for the menubar popover.

import AppKit

@MainActor
final class MenuBarHeaderView: NSView {
    private let titleLabel = NSTextField(labelWithString: "Draft")
    private let statusDot = NSView()
    private let statusLabel = NSTextField(labelWithString: "Ready")
    private let progressBar = NSProgressIndicator()
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
        titleLabel.font = NSFont.systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textColor = MenuTokens.textPrimaryNS
        addSubview(titleLabel)

        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = MenuTokens.statusDotSize / 2
        addSubview(statusDot)

        statusLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        statusLabel.textColor = MenuTokens.textSecondaryNS
        addSubview(statusLabel)

        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        addSubview(progressBar)

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

        let isReady = currentWarmupStatus == .ready
        let hasWarning = currentHotkeyError?.isEmpty == false
        let padTop: CGFloat = 0

        titleLabel.frame = NSRect(x: 0, y: padTop, width: bounds.width, height: 22)

        let statusY: CGFloat = 28
        let dotSize = MenuTokens.statusDotSize
        statusDot.frame = NSRect(x: 0, y: statusY + 3, width: dotSize, height: dotSize)
        statusLabel.frame = NSRect(x: dotSize + 8, y: statusY, width: bounds.width - dotSize - 8, height: 14)

        progressBar.isHidden = isReady
        if !isReady {
            progressBar.frame = NSRect(x: 0, y: 50, width: bounds.width, height: 8)
        }

        warningIconView.isHidden = !hasWarning
        warningLabel.isHidden = !hasWarning
        if hasWarning {
            let warningY: CGFloat = isReady ? 50 : 66
            warningIconView.frame = NSRect(x: 0, y: warningY + 1, width: 12, height: 12)
            warningLabel.frame = NSRect(x: 18, y: warningY - 1, width: bounds.width - 18, height: 26)
        }
    }

    func update(warmupStatus: MeetingSessionController.ModelWarmupStatus, hotkeyError: String?) {
        currentWarmupStatus = warmupStatus
        currentHotkeyError = hotkeyError

        let isReady = warmupStatus == .ready
        statusDot.layer?.backgroundColor = (isReady ? MenuTokens.statusGreenNS : MenuTokens.statusOrangeNS).cgColor
        statusLabel.stringValue = isReady ? "Ready" : warmupStatus.subtitle
        progressBar.doubleValue = warmupStatus.progress
        warningLabel.stringValue = hotkeyError ?? ""

        needsLayout = true
        invalidateIntrinsicContentSize()
    }

    var intrinsicHeight: CGFloat {
        let isReady = currentWarmupStatus == .ready
        let hasWarning = currentHotkeyError?.isEmpty == false
        if hasWarning {
            return isReady ? 78 : 94
        }
        return isReady ? 46 : 62
    }
}
