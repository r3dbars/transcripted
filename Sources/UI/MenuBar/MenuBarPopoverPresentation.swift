import AppKit

/// Presents the status menu without activating the whole application. Bringing
/// Transcripted's other windows forward can disturb a fullscreen app's Space
/// and the revealed menu bar that anchors this transient popover.
@MainActor
enum MenuBarPopoverPresentation {
    static func show(_ popover: NSPopover, relativeTo button: NSView) {
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // `show` may do nothing when the anchor is no longer visible. Only
        // give keyboard focus to the window of a successfully shown popover.
        guard popover.isShown else { return }
        popover.contentViewController?.view.window?.makeKey()
    }

    static func installToggleAction(on button: NSButton, target: AnyObject, action: Selector) {
        button.action = action
        button.target = target
        // Both clicks open the same popover; there is no right-click menu.
        _ = button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }
}
