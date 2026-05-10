// MenuBarHeaderView.swift
// Top status zone for the menubar popover.

import AppKit

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
        titleLabel.font = MenuTokens.Fonts.headerTitle
        titleLabel.textColor = MenuTokens.textPrimaryNS
        addSubview(titleLabel)

        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = MenuTokens.statusDotSize / 2
        addSubview(statusDot)

        statusLabel.font = MenuTokens.Fonts.headerStatus
        statusLabel.textColor = MenuTokens.textSecondaryNS
        addSubview(statusLabel)

        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        addSubview(progressBar)

        detailLabel.font = MenuTokens.Fonts.headerDetail
        detailLabel.textColor = MenuTokens.textSecondaryNS
        detailLabel.maximumNumberOfLines = 3
        detailLabel.lineBreakMode = .byWordWrapping
        addSubview(detailLabel)

        if let image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Warning") {
            warningIconView.image = image
            warningIconView.contentTintColor = MenuTokens.statusOrangeNS
        }
        addSubview(warningIconView)

        warningLabel.font = MenuTokens.Fonts.headerDetail
        warningLabel.textColor = MenuTokens.textSecondaryNS
        warningLabel.maximumNumberOfLines = 3
        warningLabel.lineBreakMode = .byWordWrapping
        addSubview(warningLabel)
    }

    override func layout() {
        super.layout()

        let isReady = currentWarmupStatus == .ready
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
            detailLabel.frame = NSRect(
                x: 0,
                y: 54,
                width: bounds.width,
                height: measuredTextHeight(for: detailLabel.stringValue, font: detailLabel.font, width: bounds.width)
            )
        }

        warningIconView.isHidden = !hasWarning
        warningLabel.isHidden = !hasWarning
        if hasWarning {
            let warningWidth = max(0, bounds.width - 18)
            let warningY: CGFloat = isReady ? 28 : detailLabel.frame.maxY + 6
            warningIconView.frame = NSRect(x: 0, y: warningY + 1, width: 12, height: 12)
            warningLabel.frame = NSRect(
                x: 18,
                y: warningY - 1,
                width: warningWidth,
                height: measuredTextHeight(for: warningLabel.stringValue, font: warningLabel.font, width: warningWidth)
            )
        }
    }

    func update(warmupStatus: MeetingSessionController.ModelWarmupStatus, hotkeyError: String?) {
        currentWarmupStatus = warmupStatus
        currentHotkeyError = hotkeyError

        let isReady = warmupStatus == .ready
        statusDot.layer?.backgroundColor = (isReady ? MenuTokens.statusGreenNS : MenuTokens.statusOrangeNS).cgColor
        statusLabel.stringValue = isReady ? "Ready" : warmupStatus.subtitle
        progressBar.doubleValue = warmupStatus.progress
        detailLabel.stringValue = isReady ? "" : warmupStatus.detail
        warningLabel.stringValue = hotkeyError ?? ""

        needsLayout = true
        invalidateIntrinsicContentSize()
    }

    var intrinsicHeight: CGFloat {
        let isReady = currentWarmupStatus == .ready
        let hasWarning = currentHotkeyError?.isEmpty == false
        let contentWidth = measurementWidth
        let warningWidth = max(0, contentWidth - 18)

        if isReady {
            let warningHeight = measuredTextHeight(for: currentHotkeyError ?? "", font: warningLabel.font, width: warningWidth)
            return hasWarning ? 28 + warningHeight + 2 : 0
        }

        let detailHeight = measuredTextHeight(for: currentWarmupStatus.detail, font: detailLabel.font, width: contentWidth)
        let contentHeight = 54 + detailHeight
        guard hasWarning else { return contentHeight }

        let warningHeight = measuredTextHeight(for: currentHotkeyError ?? "", font: warningLabel.font, width: warningWidth)
        return contentHeight + 6 + warningHeight
    }

    private var measurementWidth: CGFloat {
        bounds.width > 0 ? bounds.width : MenuTokens.panelWidth - (MenuTokens.innerPadding * 2)
    }

    private func measuredTextHeight(for text: String, font: NSFont?, width: CGFloat) -> CGFloat {
        guard !text.isEmpty, width > 0 else { return 0 }

        let resolvedFont = font ?? MenuTokens.Fonts.headerDetail
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                .font: resolvedFont,
                .paragraphStyle: paragraphStyle
            ]
        )
        let measured = attributed.boundingRect(
            with: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let lineHeight = ceil(resolvedFont.ascender - resolvedFont.descender + resolvedFont.leading)
        let maxHeight = lineHeight * 3
        return min(max(ceil(measured.height), lineHeight), maxHeight)
    }
}
