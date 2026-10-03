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

    /// On only while the island asks who was on a call and someone clicks a
    /// name box to type. The island otherwise never takes keyboard focus
    /// from the app being dictated into.
    var acceptsKeyForTyping = false

    override var canBecomeKey: Bool { acceptsKeyForTyping }
    override var canBecomeMain: Bool { false }

    /// Hidden from screen sharing and screenshots unless the person turned on
    /// Show island in screen sharing. The controller calls this before each
    /// show, so the switch applies at once.
    func applyScreenSharingPreference(userDefaults: UserDefaults = .standard) {
        let wanted: NSWindow.SharingType = NotchIslandPreferences.visibleInScreenSharing(userDefaults: userDefaults) ? .readOnly : .none
        // Called on every render; skip the window-server round trip when
        // nothing changed.
        if sharingType != wanted { sharingType = wanted }
    }

    /// AppKit keeps windows out of the menu bar; the island belongs there.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
