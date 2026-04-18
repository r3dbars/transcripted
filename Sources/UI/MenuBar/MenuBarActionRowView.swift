import AppKit

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

        var height: CGFloat {
            switch self {
            case .primary:
                return 44
            case .utility:
                return 36
            }
        }
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

    override var isEnabled: Bool {
        didSet { updateAppearance() }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: rowSize.height)
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

        titleLabel.stringValue = title
        detailLabel.stringValue = detail
        detailLabel.isHidden = detail.isEmpty
        trailingLabel.stringValue = trailingText ?? ""
        trailingLabel.isHidden = trailingText?.isEmpty ?? true

        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title) {
            symbolView.image = image.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: size == .primary ? 14 : 13, weight: .semibold)
            )
        }

        invalidateIntrinsicContentSize()
        needsLayout = true
        updateAppearance()
    }

    private func setupViews() {
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.borderWidth = 1

        symbolWellView.wantsLayer = true
        symbolWellView.layer?.cornerRadius = 10
        addSubview(symbolWellView)

        symbolView.imageScaling = .scaleProportionallyDown
        symbolWellView.addSubview(symbolView)

        titleLabel.font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        titleLabel.textColor = MenuTokens.textPrimaryNS
        addSubview(titleLabel)

        detailLabel.font = NSFont.systemFont(ofSize: 10)
        detailLabel.textColor = MenuTokens.textSecondaryNS
        detailLabel.lineBreakMode = .byTruncatingTail
        addSubview(detailLabel)

        trailingLabel.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        trailingLabel.textColor = MenuTokens.textMutedNS
        trailingLabel.alignment = .right
        addSubview(trailingLabel)

        updateAppearance()
    }

    private func updateAppearance() {
        let backgroundColor: NSColor
        let borderColor: NSColor
        let iconTint: NSColor
        let iconBackground: NSColor

        if !isEnabled {
            backgroundColor = MenuTokens.actionDisabledNS
            borderColor = MenuTokens.sectionDividerNS
            iconTint = MenuTokens.textMutedNS
            iconBackground = MenuTokens.symbolBackgroundNS
        } else if isPressing {
            backgroundColor = MenuTokens.actionPressedNS
            borderColor = MenuTokens.actionBorderNS
            (iconTint, iconBackground) = toneColors(pressed: true)
        } else if isHovering {
            backgroundColor = MenuTokens.recentHoverNS
            borderColor = MenuTokens.actionBorderNS
            (iconTint, iconBackground) = toneColors(pressed: false)
        } else {
            backgroundColor = MenuTokens.actionBackgroundNS
            borderColor = MenuTokens.actionBorderNS
            (iconTint, iconBackground) = toneColors(pressed: false)
        }

        layer?.backgroundColor = backgroundColor.cgColor
        layer?.borderColor = borderColor.cgColor
        symbolWellView.layer?.backgroundColor = iconBackground.cgColor
        symbolView.contentTintColor = iconTint
        alphaValue = isEnabled ? 1.0 : 0.55
    }

    private func toneColors(pressed: Bool) -> (NSColor, NSColor) {
        switch rowTone {
        case .accent:
            return (
                NSColor.systemBlue,
                pressed ? MenuTokens.accentButtonPressedNS : MenuTokens.accentButtonBackgroundNS
            )
        case .standard:
            return (MenuTokens.textPrimaryNS, MenuTokens.symbolBackgroundNS)
        case .warning:
            return (
                MenuTokens.statusOrangeNS,
                pressed ? MenuTokens.failedBorderNS : MenuTokens.failedBackgroundNS
            )
        }
    }

    override func layout() {
        super.layout()

        let padX: CGFloat = rowSize == .primary ? 12 : 10
        let wellSize: CGFloat = rowSize == .primary ? 30 : 24
        let symbolSize: CGFloat = rowSize == .primary ? 16 : 13
        let trailingWidth: CGFloat = trailingLabel.isHidden ? 0 : (rowSize == .primary ? 104 : 88)
        let trailingSpacing: CGFloat = trailingWidth > 0 ? 10 : 0
        let contentWidth = bounds.width - (padX * 2) - wellSize - 12 - trailingWidth - trailingSpacing
        let textWidth = max(CGFloat(0), contentWidth)

        symbolWellView.frame = NSRect(x: padX, y: (bounds.height - wellSize) / 2, width: wellSize, height: wellSize)
        symbolView.frame = NSRect(
            x: (wellSize - symbolSize) / 2,
            y: (wellSize - symbolSize) / 2,
            width: symbolSize,
            height: symbolSize
        )

        let textX = symbolWellView.frame.maxX + 12
        if detailLabel.isHidden {
            let centeredY = (bounds.height - 16) / 2
            titleLabel.frame = NSRect(x: textX, y: centeredY, width: textWidth, height: 16)
            detailLabel.frame = .zero
        } else {
            let titleY: CGFloat = rowSize == .primary ? 6 : 4
            titleLabel.frame = NSRect(x: textX, y: titleY, width: textWidth, height: 16)
            detailLabel.frame = NSRect(x: textX, y: titleLabel.frame.maxY + 1, width: textWidth, height: 13)
        }

        if trailingWidth > 0 {
            let trailingX = bounds.width - padX - trailingWidth
            let trailingY = (bounds.height - 14) / 2
            trailingLabel.frame = NSRect(x: trailingX, y: trailingY, width: trailingWidth, height: 14)
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
}
