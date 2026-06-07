import AppKit

struct MenuBarActionRowSmokeSnapshot: Codable, Equatable {
    let title: String
    let detail: String
    let trailingText: String
    let automationIdentifier: String
    let isVisible: Bool
    let isEnabled: Bool
}

@MainActor
final class MenuBarActionRowView: NSControl {
    enum Tone {
        case accent
        case standard
        case warning
    }

    enum Size {
        case primary
        case utility
    }

    var onPress: (() -> Void)?

    private let symbolWellView = NSView()
    private let symbolView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let trailingLabel = NSTextField(labelWithString: "")

    private var isHovering = false { didSet { updateAppearance() } }
    private var isPressing = false { didSet { updateAppearance() } }
    private var trackingAreaRef: NSTrackingArea?
    private var rowTone: Tone = .standard
    private var rowSize: Size = .utility
    private var currentHeight: CGFloat = 26

    override var isEnabled: Bool {
        didSet {
            setAccessibilityEnabled(isEnabled)
            updateAppearance()
            window?.invalidateCursorRects(for: self)
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: currentHeight)
    }

    func update(
        symbolName: String,
        title: String,
        detail: String,
        trailingText: String? = nil,
        tone: Tone = .standard,
        size: Size = .utility,
        isEnabled: Bool = true
    ) {
        rowTone = tone
        rowSize = size
        self.isEnabled = isEnabled
        setAccessibilityLabel(title)
        setAccessibilityHelp(detail.isEmpty ? nil : detail)

        titleLabel.stringValue = title
        detailLabel.stringValue = detail
        detailLabel.isHidden = detail.isEmpty
        trailingLabel.stringValue = trailingText ?? ""
        trailingLabel.isHidden = trailingText?.isEmpty ?? true
        currentHeight = resolvedHeight()

        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title) {
            symbolView.image = image.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: size == .primary ? 14 : 12, weight: .semibold)
            )
        }

        invalidateIntrinsicContentSize()
        needsLayout = true
        updateAppearance()
    }

    func setAutomationIdentifier(_ rawValue: String) {
        identifier = NSUserInterfaceItemIdentifier(rawValue)
        setAccessibilityIdentifier(rawValue)
    }

    private func setupViews() {
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityEnabled(isEnabled)

        wantsLayer = true
        layer?.cornerRadius = MenuTokens.cardCornerRadius

        addSubview(symbolWellView)

        symbolView.imageScaling = .scaleProportionallyDown
        symbolWellView.addSubview(symbolView)

        titleLabel.textColor = MenuTokens.textPrimaryNS
        addSubview(titleLabel)

        detailLabel.textColor = MenuTokens.textSecondaryNS
        detailLabel.lineBreakMode = .byTruncatingTail
        addSubview(detailLabel)

        trailingLabel.textColor = MenuTokens.textMutedNS
        trailingLabel.alignment = .right
        addSubview(trailingLabel)

        updateAppearance()
    }

    private func updateAppearance() {
        let backgroundColor: NSColor
        let iconTint: NSColor
        let titleColor: NSColor
        let detailColor: NSColor
        let trailingColor: NSColor

        if !isEnabled {
            backgroundColor = MenuTokens.flatRowDisabledNS
            iconTint = MenuTokens.textMutedNS
            titleColor = MenuTokens.textMutedNS
            detailColor = MenuTokens.textMutedNS
            trailingColor = MenuTokens.textMutedNS
        } else if isPressing {
            backgroundColor = MenuTokens.flatRowPressedNS
            iconTint = toneColors().pressed
            titleColor = MenuTokens.textPrimaryNS
            detailColor = MenuTokens.textSecondaryNS
            trailingColor = MenuTokens.textSecondaryNS
        } else if isHovering {
            backgroundColor = MenuTokens.flatRowHoverNS
            iconTint = toneColors().pressed
            titleColor = MenuTokens.textPrimaryNS
            detailColor = MenuTokens.textSecondaryNS
            trailingColor = MenuTokens.textSecondaryNS
        } else {
            backgroundColor = .clear
            iconTint = toneColors().normal
            titleColor = MenuTokens.textPrimaryNS
            detailColor = MenuTokens.textSecondaryNS
            trailingColor = MenuTokens.textMutedNS
        }

        layer?.backgroundColor = backgroundColor.cgColor
        layer?.borderWidth = 0
        symbolView.contentTintColor = iconTint
        titleLabel.textColor = titleColor
        detailLabel.textColor = detailColor
        trailingLabel.textColor = trailingColor
        alphaValue = isEnabled ? 1.0 : 0.55
    }

    private func toneColors() -> (normal: NSColor, pressed: NSColor) {
        switch rowTone {
        case .accent:
            return (NSColor.systemBlue, NSColor.systemBlue)
        case .standard:
            return (MenuTokens.textSecondaryNS, MenuTokens.textPrimaryNS)
        case .warning:
            return (MenuTokens.statusOrangeNS, MenuTokens.statusOrangeNS)
        }
    }

    override func layout() {
        super.layout()

        let hasDetail = !detailLabel.isHidden
        let padX: CGFloat = 6
        let iconWidth: CGFloat = rowSize == .primary ? 17 : 16
        let symbolSize: CGFloat = rowSize == .primary ? 14 : 12
        let trailingWidth: CGFloat = trailingLabel.isHidden ? 0 : (rowSize == .primary ? 76 : 64)
        let trailingSpacing: CGFloat = trailingWidth > 0 ? 8 : 0
        let contentWidth = bounds.width - (padX * 2) - iconWidth - 8 - trailingWidth - trailingSpacing
        let textWidth = max(CGFloat(0), contentWidth)

        updateTypography()

        symbolWellView.frame = NSRect(x: padX, y: floor((bounds.height - symbolSize) / 2), width: iconWidth, height: symbolSize)
        symbolView.frame = NSRect(
            x: max(0, floor((iconWidth - symbolSize) / 2)),
            y: 0,
            width: symbolSize,
            height: symbolSize
        )

        let textX = symbolWellView.frame.maxX + 8
        if !hasDetail {
            let centeredY = (bounds.height - 16) / 2
            titleLabel.frame = NSRect(x: textX, y: centeredY, width: textWidth, height: 16)
            detailLabel.frame = .zero
        } else {
            let titleY: CGFloat = 1
            titleLabel.frame = NSRect(x: textX, y: titleY, width: textWidth, height: 16)
            detailLabel.frame = NSRect(x: textX, y: titleLabel.frame.maxY + 1, width: textWidth, height: 13)
        }

        if trailingWidth > 0 {
            let trailingX = bounds.width - padX - trailingWidth
            let trailingY = hasDetail ? 2 : (bounds.height - 14) / 2
            trailingLabel.frame = NSRect(x: trailingX, y: trailingY, width: trailingWidth, height: 14)
        }
    }

    private func updateTypography() {
        switch rowSize {
        case .primary:
            titleLabel.font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
            detailLabel.font = NSFont.systemFont(ofSize: 10)
            trailingLabel.font = NSFont.systemFont(ofSize: 10.5, weight: .medium)
        case .utility:
            titleLabel.font = NSFont.systemFont(ofSize: 12.5, weight: .regular)
            detailLabel.font = NSFont.systemFont(ofSize: 10)
            trailingLabel.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        }
    }

    private func resolvedHeight() -> CGFloat {
        let hasDetail = !detailLabel.stringValue.isEmpty
        switch rowSize {
        case .primary:
            return hasDetail ? MenuTokens.compactActionRowHeight : 24
        case .utility:
            return hasDetail ? 28 : 24
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard isEnabled else { return }
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseEntered(with event: NSEvent) {
        guard isEnabled else { return }
        isHovering = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        isPressing = false
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isPressing = true
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        defer { isPressing = false }
        guard isEnabled, inside else { return }
        onPress?()
    }

    var smokeSnapshot: MenuBarActionRowSmokeSnapshot {
        MenuBarActionRowSmokeSnapshot(
            title: titleLabel.stringValue,
            detail: detailLabel.stringValue,
            trailingText: trailingLabel.stringValue,
            automationIdentifier: accessibilityIdentifier(),
            isVisible: !isHidden,
            isEnabled: isEnabled
        )
    }
}
