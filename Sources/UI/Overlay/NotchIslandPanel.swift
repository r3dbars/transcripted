// NotchIslandPanel.swift
// The borderless, non-activating panel the notch island draws in. It sits
// above the menu bar (so the island can grow out of the notch) and never
// takes keyboard focus from the app being dictated into. It stays one size
// while the island is up; NotchIslandController lets clicks through it
// everywhere except over the island itself.

import AppKit

final class NotchIslandPanel: NSPanel {
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
        // Set before the level: turning floating on resets the level to
        // .floating, which sits under the menu bar.
        self.isFloatingPanel = true
        // Above the menu bar (and the status items beside the notch), below
        // open menus.
        self.level = .statusBar
        self.becomesKeyOnlyIfNeeded = true
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = false
        self.titlebarAppearsTransparent = true
        self.titleVisibility = .hidden
        self.isMovableByWindowBackground = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        self.acceptsMouseMovedEvents = true
        self.animationBehavior = .none
        // Exclude the island from screen capture / screen sharing, like the
        // other overlays: a shared screen must not broadcast live dictation.
        self.sharingType = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// AppKit keeps windows out of the menu bar; the island belongs there.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
