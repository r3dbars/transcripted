// FloatingOverlayPanel.swift
// Non-activating NSPanel subclass for the floating overlay

import AppKit

class FloatingOverlayPanel: NSPanel {
    /// When true, the panel can become key window (for text editing in review mode)
    var allowKeyStatus = false

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
        self.level = .popUpMenu  // Above .floating (3) — ensures visibility over Electron apps, status bars, etc.
        self.isFloatingPanel = true
        self.becomesKeyOnlyIfNeeded = true
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = true
        self.titlebarAppearsTransparent = true
        self.titleVisibility = .hidden
        self.isMovableByWindowBackground = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    // Dynamic: non-key during listening/drafting, key-capable during review
    override var canBecomeKey: Bool { allowKeyStatus }
    override var canBecomeMain: Bool { false }
}
