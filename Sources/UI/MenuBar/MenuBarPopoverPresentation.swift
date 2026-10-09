import AppKit

enum MenuBarPopoverWindowVisibility {
    case onActiveSpace
    case otherSpace
    case unknown
}

/// Keeps focus local to the menu, including when AppKit refuses its status-item
/// anchor or reports the popover shown while its window is on another Space.
/// The temporary anchor is only used after one of those failures. It does not
/// retry a popover that was shown and then dismissed.
@MainActor
final class MenuBarPopoverPresentation: NSObject {
    private let makeAnchorWindow: @MainActor () -> NSPanel
    private let screenFrames: @MainActor () -> [NSRect]
    private let spaceNotifications: NotificationCenter
    private let currentEvent: @MainActor () -> NSEvent?
    private let windowVisibility: @MainActor (NSWindow) -> MenuBarPopoverWindowVisibility
    private var anchorWindow: NSPanel?
    private weak var presentedPopover: NSPopover?
    private weak var sourceButton: NSView?
    private var sourceRect: NSRect?
    private var dismissalClick: DismissalClick?
    private var explicitlyClosing = false
    private var dismissedDuringPresentation = false

    private struct DismissalClick {
        let button: NSView
        let number: Int64
        let mouseUpType: NSEvent.EventType
    }

    init(
        makeAnchorWindow: @escaping @MainActor () -> NSPanel = { MenuBarPopoverAnchorPanel() },
        screenFrames: @escaping @MainActor () -> [NSRect] = { NSScreen.screens.map(\.frame) },
        spaceNotifications: NotificationCenter = NSWorkspace.shared.notificationCenter,
        currentEvent: @escaping @MainActor () -> NSEvent? = { NSApp.currentEvent },
        windowVisibility: @escaping @MainActor (NSWindow) -> MenuBarPopoverWindowVisibility = { window in
            MenuBarPopoverPresentation.visibility(of: window)
        }
    ) {
        self.makeAnchorWindow = makeAnchorWindow
        self.screenFrames = screenFrames
        self.spaceNotifications = spaceNotifications
        self.currentEvent = currentEvent
        self.windowVisibility = windowVisibility
        super.init()
    }

    func show(_ popover: NSPopover, relativeTo button: NSView) {
        if consumeDismissalClick(for: button) { return }
        guard !popover.isShown else { return }
        releaseAnchor()

        // Snapshot before show: a revealed menu bar may retract during the
        // presentation. Never guess a position from a stale/offscreen window.
        let screenRect = anchorScreenRect(for: button)
        dismissedDuringPresentation = false
        presentedPopover = popover
        NotificationCenter.default.addObserver(
            self, selector: #selector(popoverWillClose(_:)), name: NSPopover.willCloseNotification, object: popover
        )
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

        // isShown stays true when a regular app's popover window is committed
        // on another Space. That is not a visible menu, so close it and retry once.
        let shownOnAnotherSpace = popover.isShown
            && popover.contentViewController?.view.window.map { windowVisibility($0) == .otherSpace } == true
        if shownOnAnotherSpace {
            closeShownOnAnotherSpace(popover)
        }

        if let screenRect, shownOnAnotherSpace || (!popover.isShown && !dismissedDuringPresentation) {
            let panel = makeAnchorWindow()
            panel.styleMask = [.borderless, .nonactivatingPanel]
            panel.isReleasedWhenClosed = false
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            // This contains only a clear positioning view, never capture text.
            // Keep the menu's normal screenshot behavior unchanged.
            panel.sharingType = .readOnly
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            // Above full-screen content; .statusBar sits below it.
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications, .stationary, .ignoresCycle]
            panel.setFrame(screenRect, display: false)
            let anchor = NSView(frame: NSRect(origin: .zero, size: screenRect.size))
            panel.contentView = anchor
            anchorWindow = panel
            presentedPopover = popover
            sourceButton = button
            sourceRect = screenRect
            NotificationCenter.default.addObserver(
                self, selector: #selector(popoverDidClose(_:)), name: NSPopover.didCloseNotification, object: popover
            )
            spaceNotifications.addObserver(
                self, selector: #selector(activeSpaceDidChange), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil
            )
            panel.orderFrontRegardless()
            // One attempt only. Retain the anchor through native dismissal,
            // so retracting the real menu bar cannot remove this anchor.
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
            if !popover.isShown { releaseAnchor() }
        } else {
            releaseAnchor()
        }

        guard popover.isShown else { return }
        popover.contentViewController?.view.window?.makeKey()
    }

    private func closeShownOnAnotherSpace(_ popover: NSPopover) {
        explicitlyClosing = true
        popover.performClose(nil)
        explicitlyClosing = false
        dismissedDuringPresentation = false
        dismissalClick = nil
    }

    static func visibility(of window: NSWindow) -> MenuBarPopoverWindowVisibility {
        let number = window.windowNumber
        guard number > 0,
              let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
            return .unknown
        }
        for entry in info {
            guard (entry[kCGWindowNumber as String] as? Int) == number else { continue }
            if (entry[kCGWindowIsOnscreen as String] as? Bool) == true { return .onActiveSpace }
            let layer = entry[kCGWindowLayer as String] as? Int ?? 0
            // A level of 0 means the window server has not committed this window yet.
            // An off-screen window that already has its popover level is on another Space.
            return layer == 0 ? .unknown : .otherSpace
        }
        return .unknown
    }

    private func anchorScreenRect(for button: NSView) -> NSRect? {
        guard let window = button.window else { return nil }
        let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
        guard rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.width.isFinite, rect.height.isFinite,
              rect.size.width > 0, rect.size.height > 0,
              screenFrames().contains(where: { $0.contains(rect) }) else { return nil }
        return rect
    }

    @objc private func popoverDidClose(_ notification: Notification) {
        guard let popover = notification.object as? NSPopover,
              popover === presentedPopover, !popover.isShown else { return }
        releaseAnchor()
    }

    @objc private func popoverWillClose(_ notification: Notification) {
        guard notification.object as? NSPopover === presentedPopover else { return }
        dismissedDuringPresentation = true
        guard !explicitlyClosing, let button = sourceButton, let rect = sourceRect,
              let event = currentEvent(),
              [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp].contains(event.type),
              let number = event.cgEvent?.getIntegerValueField(.mouseEventNumber) else { return }
        let point = event.window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
        guard rect.contains(point) else { return }
        // The original status button is outside the fallback anchor window.
        // If its down event dismisses the transient popover, its up action
        // must not immediately reopen it. CG mouse down/up share this number;
        // a later, unrelated click must never be swallowed by a time debounce.
        let mouseUpType: NSEvent.EventType = [.leftMouseDown, .leftMouseUp].contains(event.type) ? .leftMouseUp : .rightMouseUp
        dismissalClick = DismissalClick(button: button, number: number, mouseUpType: mouseUpType)
    }

    private func consumeDismissalClick(for button: NSView) -> Bool {
        defer { dismissalClick = nil }
        guard let click = dismissalClick, click.button === button,
              let event = currentEvent(), [.leftMouseUp, .rightMouseUp].contains(event.type) else { return false }
        return event.type == click.mouseUpType
            && event.cgEvent?.getIntegerValueField(.mouseEventNumber) == click.number
    }

    func close(_ popover: NSPopover) {
        explicitlyClosing = true
        defer {
            explicitlyClosing = false
            dismissalClick = nil
        }
        popover.performClose(nil)
    }

    @objc private func activeSpaceDidChange() {
        // A helper present on every Space must not carry an open menu into
        // another app or desktop after the user leaves the clicked Space.
        presentedPopover?.close()
        releaseAnchor()
        dismissalClick = nil
    }

    private func releaseAnchor() {
        NotificationCenter.default.removeObserver(self, name: NSPopover.didCloseNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSPopover.willCloseNotification, object: nil)
        spaceNotifications.removeObserver(self, name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        presentedPopover = nil
        sourceButton = nil
        sourceRect = nil
        anchorWindow?.orderOut(nil)
        anchorWindow = nil
    }

    static func installToggleAction(on button: NSButton, target: AnyObject, action: Selector) {
        button.action = action
        button.target = target
        // Both clicks open the same popover; there is no right-click menu.
        _ = button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }
}

/// A positioning surface, never an interactive or focusable application window.
@MainActor
private final class MenuBarPopoverAnchorPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // The status item is in the menu bar, outside the screen's visibleFrame.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
