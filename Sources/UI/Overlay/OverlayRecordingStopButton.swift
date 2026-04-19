import AppKit

@MainActor
final class OverlayRecordingStopButton: NSButton {
    static let sideLength: CGFloat = 28

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.sideLength, height: Self.sideLength)
    }

    override var isHighlighted: Bool {
        didSet { updateLayerAppearance() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func commonInit() {
        title = ""
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        setButtonType(.momentaryPushIn)
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = Self.sideLength / 2
        layer?.borderWidth = 1
        configureImage()
        updateLayerAppearance()
    }

    func configure(accessibilityLabel: String, toolTip: String) {
        setAccessibilityLabel(accessibilityLabel)
        self.toolTip = toolTip
    }

    private func configureImage() {
        guard let symbol = NSImage(
            systemSymbolName: "stop.fill",
            accessibilityDescription: nil
        ) else {
            image = nil
            return
        }

        let configuration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        image = symbol.withSymbolConfiguration(configuration) ?? symbol
        contentTintColor = OverlayTokens.textPrimary.withAlphaComponent(0.92)
    }

    private func updateLayerAppearance() {
        layer?.backgroundColor = (isHighlighted
            ? NSColor.white.withAlphaComponent(0.20)
            : NSColor.white.withAlphaComponent(0.12)
        ).cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(isHighlighted ? 0.16 : 0.08).cgColor
    }
}
