// MenuBarModelStatusView.swift
// Persistent model status badge in the menu bar popover — shows which voice
// model is running, with download progress and error affordance.

import AppKit

@MainActor
final class MenuBarModelStatusView: NSControl {
    private let statusDot = NSView()
    private let label = NSTextField(labelWithString: "")
    private let chevron = NSImageView()

    var onOpenSettings: (() -> Void)?
    private var currentState: FirstRunLocalModelState = .notLoaded

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
        applyState()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func setupViews() {
        setAccessibilityElement(true)
        setAccessibilityRole(.button)

        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.clear.cgColor

        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = MenuTokens.statusDotSize / 2
        addSubview(statusDot)

        label.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        label.textColor = MenuTokens.textSecondaryNS
        label.lineBreakMode = .byTruncatingTail
        label.cell?.usesSingleLineMode = true
        addSubview(label)

        if let image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil) {
            chevron.image = image
            chevron.contentTintColor = MenuTokens.textMutedNS
            chevron.imageScaling = .scaleProportionallyDown
        }
        addSubview(chevron)

        let track = NSTrackingArea(
            rect: .zero,
            options: [.inVisibleRect, .activeInKeyWindow, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(track)
    }

    override func layout() {
        super.layout()
        let pad: CGFloat = 8
        let dotSize = MenuTokens.statusDotSize
        let chevronSize: CGFloat = 10
        let midY = bounds.midY

        statusDot.frame = NSRect(
            x: pad,
            y: midY - dotSize / 2,
            width: dotSize,
            height: dotSize
        )
        chevron.frame = NSRect(
            x: bounds.width - pad - chevronSize,
            y: midY - chevronSize / 2,
            width: chevronSize,
            height: chevronSize
        )
        let labelX = statusDot.frame.maxX + 8
        label.frame = NSRect(
            x: labelX,
            y: midY - 8,
            width: chevron.frame.minX - labelX - 6,
            height: 16
        )
    }

    func update(state: FirstRunLocalModelState) {
        currentState = state
        applyState()
        needsLayout = true
        window?.invalidateCursorRects(for: self)
    }

    private func applyState() {
        switch currentState {
        case .ready:
            statusDot.layer?.backgroundColor = MenuTokens.statusGreenNS.cgColor
            label.stringValue = "Parakeet TDT V3 · On-device"
            toolTip = "Parakeet TDT V3 is cached outside app updates. Click to open settings."
        case .downloading(let progress):
            statusDot.layer?.backgroundColor = NSColor.systemBlue.cgColor
            label.stringValue = progress > 0
                ? "Downloading Parakeet · \(Int(progress * 100))%"
                : "Downloading Parakeet · one-time setup"
            toolTip = "One-time local model download. It stays cached outside future app updates. Click to open settings."
        case .cached:
            statusDot.layer?.backgroundColor = MenuTokens.statusGreenNS.cgColor
            label.stringValue = "Parakeet TDT V3 · Cached"
            toolTip = "Parakeet model files are cached outside app updates. They load into memory when dictation starts."
        case .loading:
            statusDot.layer?.backgroundColor = NSColor.systemBlue.cgColor
            label.stringValue = "Loading Parakeet TDT V3…"
            toolTip = "Finishing local model setup. Click to open settings."
        case .notLoaded:
            statusDot.layer?.backgroundColor = MenuTokens.textMutedNS.cgColor
            label.stringValue = "Parakeet TDT V3 · On demand"
            toolTip = "First use downloads Parakeet once, then stores it outside app updates. Click to open settings."
        case .failed:
            statusDot.layer?.backgroundColor = MenuTokens.statusOrangeNS.cgColor
            label.stringValue = "Parakeet TDT V3 · Needs retry"
            toolTip = "Local model failed. Open Models settings to retry the download."
        }
        setAccessibilityLabel("Local model status")
        setAccessibilityValue(label.stringValue)
        setAccessibilityHelp(toolTip)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = MenuTokens.actionBackgroundNS.cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func mouseDown(with event: NSEvent) {
        layer?.backgroundColor = MenuTokens.actionPressedNS.cgColor
    }

    override func mouseUp(with event: NSEvent) {
        layer?.backgroundColor = bounds.contains(convert(event.locationInWindow, from: nil))
            ? MenuTokens.actionBackgroundNS.cgColor
            : NSColor.clear.cgColor
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onOpenSettings?()
        }
    }

    var intrinsicHeight: CGFloat { MenuTokens.minimumHitTargetSize }

    override var acceptsFirstResponder: Bool { true }

    override func accessibilityPerformPress() -> Bool {
        onOpenSettings?()
        return true
    }
}
