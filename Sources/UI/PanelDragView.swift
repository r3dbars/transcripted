// PanelDragView.swift
// Transparent NSView that initiates a native window drag on mouseDown.
// Uses NSWindow.performDrag(with:) which respects .nonactivatingPanel automatically.
// Lives as a pure AppKit subview of the panel's content view — NOT an NSViewRepresentable.
// This avoids executor isolation crashes during nested run loop body evaluations.

import AppKit

class PanelDragView: NSView {
    weak var panel: NSPanel?

    override func mouseDown(with event: NSEvent) {
        if let panel = panel {
            panel.performDrag(with: event)
        } else {
            super.mouseDown(with: event)
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }
}
