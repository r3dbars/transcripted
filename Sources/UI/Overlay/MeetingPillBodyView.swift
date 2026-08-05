// MeetingPillBodyView.swift
// Click-and-drag body view for the meeting recording pill.

import AppKit

// MARK: - Pill body

/// Transparent click surface covering the recording strip. Clicking toggles
/// the transcript drawer; a small drag still moves the panel (re-handed to
/// the window once movement exceeds a threshold); right-click shows the
/// pill's context menu.
@available(macOS 14.0, *)
@MainActor
final class MeetingPillBodyView: NSView {
    var onClick: (() -> Void)?
    var menuProvider: (() -> NSMenu?)?

    private var pendingDownEvent: NSEvent?

    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        pendingDownEvent = event
    }

    override func mouseDragged(with event: NSEvent) {
        guard let downEvent = pendingDownEvent else { return }
        let dx = abs(event.locationInWindow.x - downEvent.locationInWindow.x)
        let dy = abs(event.locationInWindow.y - downEvent.locationInWindow.y)
        guard dx > 4 || dy > 4 else { return }
        // Past the click threshold: this is a move, hand the gesture to the
        // window so the panel drags exactly like its other background areas.
        pendingDownEvent = nil
        window?.performDrag(with: downEvent)
    }

    override func mouseUp(with event: NSEvent) {
        guard pendingDownEvent != nil else { return }
        pendingDownEvent = nil
        onClick?()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?() ?? super.menu(for: event)
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}

