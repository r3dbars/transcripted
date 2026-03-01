// PanelDragView.swift
// Transparent NSView that initiates a native window drag on mouseDown.
// Uses NSWindow.performDrag(with:) which respects .nonactivatingPanel automatically.
// Lives as a pure AppKit subview of the panel's content view — NOT an NSViewRepresentable.
// This avoids executor isolation crashes during nested run loop body evaluations.

import AppKit

class PanelDragView: NSView {
    weak var panel: NSPanel?

    /// Width of the interactive zone on the right edge of the header (chevron + hint).
    /// Clicks in this zone pass through to the SwiftUI buttons underneath.
    private let interactiveRightMargin: CGFloat = 120

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Pass through clicks near the right edge so the chevron button receives them
        if point.x > bounds.width - interactiveRightMargin {
            return nil  // Let the SwiftUI hosting view handle this click
        }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        if let panel = panel {
            panel.performDrag(with: event)
        } else {
            super.mouseDown(with: event)
        }
    }

    override func resetCursorRects() {
        // Only show drag cursor in the draggable area (not the interactive right zone)
        let dragRect = NSRect(x: 0, y: 0, width: max(0, bounds.width - interactiveRightMargin), height: bounds.height)
        addCursorRect(dragRect, cursor: .openHand)
    }
}
