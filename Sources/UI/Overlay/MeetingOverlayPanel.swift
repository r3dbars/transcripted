// MeetingOverlayPanel.swift
// AppKit panels and tooltip views used by the meeting overlay.

import AppKit

// MARK: - Panel

/// Non-activating NSPanel for the meeting overlay. Distinct from
/// `FloatingOverlayPanel` so cross-feature regressions to one don't break the
/// other.
@available(macOS 14.0, *)
final class MeetingOverlayPanel: NSPanel {
    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: true
        )
        self.level = .popUpMenu
        self.isFloatingPanel = true
        self.becomesKeyOnlyIfNeeded = true
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = true
        self.titlebarAppearsTransparent = true
        self.titleVisibility = .hidden
        self.isMovableByWindowBackground = true
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.acceptsMouseMovedEvents = true
        self.allowsToolTipsWhenApplicationIsInactive = true
        // Exclude the meeting overlay from screen capture / screen sharing.
        // Panels default to `.readOnly`, which ScreenCaptureKit captures.
        self.sharingType = .none
    }

    // Never steals keyboard focus — meeting UI is read-only status.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@available(macOS 14.0, *)
@MainActor
final class MeetingOverlayTooltipPanel: NSPanel {
    private let tooltipView = MeetingOverlayTooltipView()

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 80, height: 26),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        self.level = .statusBar
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = true
        self.ignoresMouseEvents = true
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        // Keep the hover tooltip out of screen capture too, matching the
        // recording panel.
        self.sharingType = .none
        self.contentView = tooltipView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func update(text: String) -> NSSize {
        tooltipView.update(text: text)
    }
}

@available(macOS 14.0, *)
@MainActor
final class MeetingOverlayTooltipView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let horizontalPadding: CGFloat = 10
    private let verticalPadding: CGFloat = 6

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.masksToBounds = true
        layer?.backgroundColor = AccessibilityDisplayPolicy.backdropColor(
            NSColor(calibratedWhite: 0.10, alpha: 0.98)
        ).cgColor
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor

        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = MeetingOverlayTokens.textPrimary
        label.lineBreakMode = .byClipping
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let labelSize = label.fittingSize
        label.frame = NSRect(
            x: horizontalPadding,
            y: (bounds.height - labelSize.height) / 2,
            width: max(0, bounds.width - horizontalPadding * 2),
            height: labelSize.height
        )
    }

    func update(text: String) -> NSSize {
        label.stringValue = text
        let labelSize = label.fittingSize
        let size = NSSize(
            width: ceil(labelSize.width + horizontalPadding * 2),
            height: max(24, ceil(labelSize.height + verticalPadding * 2))
        )
        frame = NSRect(origin: .zero, size: size)
        needsLayout = true
        return size
    }
}
