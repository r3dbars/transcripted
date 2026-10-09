import AppKit

@MainActor
func testMenuBarPopoverPresentation() async {
    // AppKit requires an application object before constructing even an
    // undisplayed window. This does not activate or display the application.
    _ = NSApplication.shared
    runSuite("Menu visibility queries only the popover window and requires explicit offscreen evidence") {
        let fixture = MenuBarPopoverPresentationFixture()
        let number = fixture.window.windowNumber
        assertTrue(number > 0, "the fixture has a registered window number")
        let cases: [(Any?, Int, MenuBarPopoverWindowVisibility)] = [
            (true, 0, .onActiveSpace),
            (false, 101, .otherSpace),
            (false, 0, .unknown),
            (nil, 101, .unknown),
            ("false", 101, .unknown)
        ]
        for (onscreen, layer, expected) in cases {
            var calls = 0
            let actual = MenuBarPopoverPresentation.visibility(of: fixture.window) { numbers in
                calls += 1
                assertEqual(CFArrayGetCount(numbers), 1, "request exactly one window description, never a session-wide list")
                assertEqual(UInt(bitPattern: CFArrayGetValueAtIndex(numbers, 0)), UInt(number),
                            "Quartz receives the popover's ID as an integer value, not a boxed object")
                var entry: [String: Any] = [kCGWindowNumber as String: number, kCGWindowLayer as String: layer]
                entry[kCGWindowIsOnscreen as String] = onscreen
                return [entry]
            }
            assertEqual(calls, 1, "each visibility check uses one targeted query")
            assertEqual(actual, expected, "only explicit offscreen metadata can trigger the Space retry")
        }
        let unavailable = MenuBarPopoverPresentation.visibility(of: fixture.window) { _ in nil }
        assertEqual(unavailable, .unknown, "a failed window-server lookup does not trigger a retry")
        let unrelated = MenuBarPopoverPresentation.visibility(of: fixture.window) { _ in
            [[kCGWindowNumber as String: number + 1, kCGWindowIsOnscreen as String: false, kCGWindowLayer as String: 101]]
        }
        assertEqual(unrelated, .unknown, "another window's metadata cannot classify the popover")
        fixture.window.reportedWindowNumber = 0
        let unregistered = MenuBarPopoverPresentation.visibility(of: fixture.window) { _ in
            assertTrue(false, "an unregistered popover must not query the window server")
            return []
        }
        assertEqual(unregistered, .unknown, "a popover without a window-server ID has unknown visibility")
        fixture.window.reportedWindowNumber = Int(CGWindowID.max) + 1
        assertEqual(MenuBarPopoverPresentation.visibility(of: fixture.window) { _ in
            assertTrue(false, "a window number outside Quartz's ID range must not be queried")
            return []
        }, .unknown)
    }

    runSuite("The production Quartz description API handles an absent window without a retry") {
        let fixture = MenuBarPopoverPresentationFixture()
        fixture.window.reportedWindowNumber = Int(CGWindowID.max)
        assertEqual(MenuBarPopoverPresentation.visibility(of: fixture.window), .unknown,
                    "a nonexistent ID returns no usable description through the real bounded API")
    }

    runSuite("Unknown menu visibility does not close and reopen a successfully shown popover") {
        let fixture = MenuBarPopoverPresentationFixture()
        fixture.windowVisibility = { _ in .unknown }
        fixture.presentation.show(fixture.popover, relativeTo: fixture.anchor)
        assertEqual(fixture.popover.presentations.count, 1, "missing metadata leaves successful presentation alone")
        assertTrue(fixture.fallbackPanels.isEmpty, "unknown visibility cannot allocate the elevated fallback")
    }

    runSuite("Opening the menu focuses only its popover window after showing it") {
        let fixture = MenuBarPopoverPresentationFixture()
        fixture.presentation.show(fixture.popover, relativeTo: fixture.anchor)

        assertEqual(fixture.events, ["show", "focus popover"], "show must create the window before keyboard focus is requested")
        assertTrue(fixture.popover.shownRelativeTo === fixture.anchor, "keep the clicked status button as the anchor")
        assertEqual(fixture.popover.shownRect, fixture.anchor.bounds, "anchor to the button's bounds")
        assertEqual(fixture.popover.shownEdge, .minY, "open below the menu bar")
        assertTrue(fixture.fallbackPanels.isEmpty, "a successful status-button presentation needs no fallback window")
    }

    runSuite("A menu that cannot show does not focus a retained popover window") {
        let fixture = MenuBarPopoverPresentationFixture()
        // A previous presentation can leave the content attached to its
        // window. AppKit may refuse the next show if the anchor is hidden.
        fixture.window.contentView = fixture.content.view
        fixture.popover.showResults = [false, false]
        fixture.presentation.show(fixture.popover, relativeTo: fixture.anchor)

        assertEqual(fixture.events, ["show", "create anchor", "order anchor", "show", "order out anchor"], "a hidden menu cleans up its single retry without stealing keyboard focus")
        assertEqual(fixture.popover.presentations.count, 2, "failure does not start an unbounded presentation loop")
        assertEqual(fixture.fallbackPanels.first?.orderOutCount, 1, "a refused retry removes its temporary anchor")
    }

    runSuite("A menu dismissed during its first presentation stays dismissed") {
        let fixture = MenuBarPopoverPresentationFixture()
        fixture.popover.showResults = [true, true]
        fixture.onShow = { [weak fixture] count in
            if count == 1 { fixture?.popover.close() }
        }
        fixture.presentation.show(fixture.popover, relativeTo: fixture.anchor)

        assertEqual(fixture.popover.presentations.count, 1, "a close notification distinguishes dismissal from a refused show")
        assertTrue(fixture.fallbackPanels.isEmpty, "dismissal does not allocate a recovery anchor")
        assertFalse(fixture.popover.isShown, "a closed menu must not immediately reopen")
        assertFalse(fixture.events.contains("focus popover"), "dismissal cannot focus a retained window")
    }

    runSuite("A shown menu without a content window leaves other windows alone") {
        let fixture = MenuBarPopoverPresentationFixture()
        fixture.popover.attachWindow = false
        fixture.presentation.show(fixture.popover, relativeTo: fixture.anchor)

        assertEqual(fixture.events, ["show"], "there is no application-wide focus fallback")
        assertTrue(fixture.fallbackPanels.isEmpty, "a shown popover does not need a second presentation")
    }

    runSuite("A menu AppKit reports as shown on another Space opens on the full-screen anchor") {
        let fixture = MenuBarPopoverPresentationFixture()
        fixture.windowVisibility = { _ in .otherSpace }
        fixture.popover.showResults = [true, true]
        fixture.presentation.show(fixture.popover, relativeTo: fixture.anchor)

        assertEqual(fixture.popover.presentations.count, 2, "a shown window on another Space gets one anchor retry")
        assertTrue(fixture.popover.isShown, "the retried menu is open")
        guard let panel = fixture.fallbackPanels.first, let retry = fixture.popover.presentations.last else { return }
        assertTrue(retry.view.window === panel, "the visible menu is anchored in the full-screen panel")
        assertEqual(panel.level, .screenSaver, "the anchor sits above full-screen content")
        assertEqual(fixture.events, ["show", "create anchor", "order anchor", "show", "focus popover"], "recovery orders the anchor before the second show")
    }

    runSuite("A status click dismisses a menu retried from another Space without reopening on mouse up") {
        for downType: NSEvent.EventType in [.leftMouseDown, .rightMouseDown] {
            let fixture = MenuBarPopoverPresentationFixture()
            fixture.windowVisibility = { _ in .otherSpace }
            fixture.popover.showResults = [true, true, true, true]
            fixture.presentation.show(fixture.popover, relativeTo: fixture.anchor)
            assertEqual(fixture.popover.closeCount, 1, "the other-Space presentation is forcibly closed before the retry")
            fixture.currentEvent = menuBarMouseEvent(downType, number: 173, at: fixture.anchorScreenPoint)
            fixture.popover.close()
            let upType: NSEvent.EventType = downType == .leftMouseDown ? .leftMouseUp : .rightMouseUp
            fixture.currentEvent = menuBarMouseEvent(upType, number: 173, at: fixture.anchorScreenPoint)
            fixture.presentation.show(fixture.popover, relativeTo: fixture.anchor)
            assertEqual(fixture.popover.presentations.count, 2, "the dismissal's mouse up cannot reopen the retried menu")
            assertFalse(fixture.popover.isShown, "the retried menu stays dismissed")
            assertEqual(fixture.fallbackPanels.count, 1, "the dismissing click creates no replacement fallback")
            fixture.currentEvent = menuBarMouseEvent(upType, number: 174, at: fixture.anchorScreenPoint)
            fixture.presentation.show(fixture.popover, relativeTo: fixture.anchor)
            assertEqual(fixture.popover.presentations.count, 4, "the next independent click remains usable")
        }
    }

    runSuite("A refused status-button presentation retries once at its original screen position") {
        let fixture = MenuBarPopoverPresentationFixture()
        fixture.popover.showResults = [false, true]
        let originalRect = fixture.sourceWindow.convertToScreen(fixture.anchor.convert(fixture.anchor.bounds, to: nil))
        fixture.onShow = { [weak fixture] count in
            if count == 1 { fixture?.anchor.removeFromSuperview() }
        }
        fixture.presentation.show(fixture.popover, relativeTo: fixture.anchor)

        assertEqual(fixture.events, ["show", "create anchor", "order anchor", "show", "focus popover"], "the anchor is ordered before the retry and focus follows successful presentation")
        assertEqual(fixture.popover.presentations.count, 2, "a refused show gets one retry")
        assertEqual(fixture.fallbackPanels.count, 1, "the retry uses one temporary anchor window")
        guard let panel = fixture.fallbackPanels.first, let retry = fixture.popover.presentations.last else { return }
        assertEqual(panel.frame, originalRect, "capture the screen rectangle before the menu bar can retract")
        assertTrue(retry.view !== fixture.anchor, "the retry does not reuse the vanished status button")
        assertTrue(retry.view.window === panel, "the retry is anchored in the temporary panel")
        assertEqual(retry.rect, retry.view.bounds, "the retry uses the new anchor's bounds")
        assertTrue(retry.rect.width > 0 && retry.rect.height > 0, "the replacement anchor has visible dimensions")
        assertEqual(retry.edge, .minY, "the recovered menu still opens below its anchor")
        assertEqual(panel.orderOutCount, 0, "keep the fallback anchor alive while the popover is shown")
        assertTrue(panel.styleMask.contains(.nonactivatingPanel), "the anchor does not activate Transcripted")
        assertTrue(panel.ignoresMouseEvents, "the transparent anchor does not intercept status clicks")
        assertFalse(panel.hidesOnDeactivate, "the anchor stays visible while the full-screen app remains active")
        assertEqual(panel.backgroundColor, .clear, "the helper does not paint over the status icon")
        assertEqual(panel.alphaValue, 1, "AppKit still sees a visible positioning window")
        assertEqual(panel.sharingType, .readOnly, "the empty positioning surface does not hide the menu from screenshots")
        assertTrue(panel.collectionBehavior.contains([.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications]), "the anchor can join another app's full-screen Space")
    }

    runSuite("A refused menu with no source window does not guess a fallback position") {
        let fixture = MenuBarPopoverPresentationFixture()
        fixture.anchor.removeFromSuperview()
        fixture.popover.showResults = [false]
        fixture.presentation.show(fixture.popover, relativeTo: fixture.anchor)

        assertEqual(fixture.events, ["show"], "missing screen geometry cannot open a guessed-position menu")
        assertTrue(fixture.fallbackPanels.isEmpty, "do not allocate a panel without a source screen rectangle")
    }

    runSuite("Invalid or offscreen status-button rectangles cannot create a fallback menu") {
        let invalidRects: [NSRect] = [
            NSRect(x: 100, y: 100, width: 0, height: 22),
            NSRect(x: 100, y: 100, width: 24, height: 0),
            NSRect(x: 100, y: 100, width: -24, height: 22),
            NSRect(x: CGFloat.nan, y: 100, width: 24, height: 22),
            NSRect(x: 100, y: CGFloat.infinity, width: 24, height: 22),
            NSRect(x: 100, y: 100, width: CGFloat.infinity, height: 22),
            NSRect(x: 3100, y: 100, width: 24, height: 22),
            NSRect(x: 2990, y: 100, width: 24, height: 22)
        ]
        for rect in invalidRects {
            let fixture = MenuBarPopoverPresentationFixture()
            fixture.sourceWindow.screenRectOverride = rect
            fixture.popover.showResults = [false]
            fixture.presentation.show(fixture.popover, relativeTo: fixture.anchor)

            assertEqual(fixture.popover.presentations.count, 1, "invalid or partially offscreen geometry gets no retry: \(rect)")
            assertTrue(fixture.fallbackPanels.isEmpty, "invalid or partially offscreen geometry allocates no panel: \(rect)")
        }
    }

    runSuite("A fallback anchor must fit one screen rather than span the desktop's bounding rectangle") {
        let fixture = MenuBarPopoverPresentationFixture()
        fixture.screens = [NSRect(x: 0, y: 0, width: 100, height: 100), NSRect(x: 100, y: 0, width: 100, height: 100)]
        fixture.sourceWindow.screenRectOverride = NSRect(x: 90, y: 50, width: 24, height: 22)
        fixture.popover.showResults = [false]
        fixture.presentation.show(fixture.popover, relativeTo: fixture.anchor)

        assertEqual(fixture.popover.presentations.count, 1, "a rectangle crossing screen boundaries gets no retry")
        assertTrue(fixture.fallbackPanels.isEmpty, "the fallback cannot bridge two screens")
    }

    runSuite("Menu-bar positions and displays with negative origins remain usable anchors") {
        for origin in [NSPoint.zero, NSPoint(x: -3000, y: -1000)] {
            let fixture = MenuBarPopoverPresentationFixture()
            let screen = NSRect(origin: origin, size: NSSize(width: 3000, height: 2000))
            fixture.screens = [screen]
            let rect = NSRect(x: screen.minX + 500, y: screen.maxY - 22, width: 24, height: 22)
            fixture.sourceWindow.screenRectOverride = rect
            fixture.popover.showResults = [false, true]
            fixture.presentation.show(fixture.popover, relativeTo: fixture.anchor)
            assertEqual(fixture.fallbackPanels.first?.frame, rect, "the top menu-bar band belongs to this display")
            assertTrue(fixture.popover.isShown, "a negative display origin does not invalidate the menu")
        }
    }

    runSuite("Closing another popover leaves the shown fallback menu intact") {
        let fixture = MenuBarPopoverPresentationFixture()
        fixture.popover.showResults = [false, true]
        fixture.presentation.show(fixture.popover, relativeTo: fixture.anchor)
        let unrelatedPopover = MenuBarRecordingPopover()
        NotificationCenter.default.post(name: NSPopover.didCloseNotification, object: unrelatedPopover)

        assertEqual(fixture.fallbackPanels.first?.orderOutCount, 0, "another popover's notification cannot discard this anchor")
        assertTrue(fixture.popover.isShown, "another popover closing does not dismiss this menu")

        fixture.popover.close()
        assertEqual(fixture.fallbackPanels.first?.orderOutCount, 1, "closing the matching popover removes its anchor")
    }

    runSuite("Changing Spaces dismisses a fallback menu and removes its temporary anchor") {
        let fixture = MenuBarPopoverPresentationFixture()
        fixture.popover.showResults = [false, true]
        fixture.presentation.show(fixture.popover, relativeTo: fixture.anchor)
        fixture.spaceNotifications.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)

        assertEqual(fixture.popover.closeCount, 1, "the fallback popover must not follow the user into another Space")
        assertTrue(!fixture.popover.isShown, "the fallback menu is dismissed when the active Space changes")
        assertEqual(fixture.fallbackPanels.first?.orderOutCount, 1, "Space dismissal removes the panel exactly once")
        fixture.spaceNotifications.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        assertEqual(fixture.popover.closeCount, 1, "later Space changes do not act on a closed menu")
    }

    runSuite("Reopening a fallback menu uses the current status-button screen position") {
        let fixture = MenuBarPopoverPresentationFixture()
        fixture.popover.showResults = [false, true, false, true]
        fixture.presentation.show(fixture.popover, relativeTo: fixture.anchor)
        fixture.popover.close()
        let movedRect = NSRect(x: 1300, y: 1800, width: 24, height: 22)
        fixture.sourceWindow.screenRectOverride = movedRect
        fixture.presentation.show(fixture.popover, relativeTo: fixture.anchor)

        assertEqual(fixture.fallbackPanels.count, 2, "reopening creates a fresh presentation anchor")
        assertEqual(fixture.fallbackPanels.first?.orderOutCount, 1, "the old anchor remains cleaned up")
        assertEqual(fixture.fallbackPanels.last?.frame, movedRect, "a reopened menu does not reuse stale screen geometry")
        assertEqual(fixture.fallbackPanels.last?.orderOutCount, 0, "the new anchor remains until this menu closes")
        assertEqual(fixture.popover.presentations.count, 4, "each opening gets only its own single retry")

        NotificationCenter.default.post(name: NSPopover.didCloseNotification, object: fixture.popover)
        assertEqual(fixture.fallbackPanels.last?.orderOutCount, 0, "a late close notification cannot discard the reopened popover's anchor")
    }

    runSuite("Showing an already shown fallback menu preserves its anchor and focus") {
        let fixture = MenuBarPopoverPresentationFixture()
        fixture.popover.showResults = [false, true]
        fixture.presentation.show(fixture.popover, relativeTo: fixture.anchor)
        let originalEvents = fixture.events
        fixture.presentation.show(fixture.popover, relativeTo: fixture.anchor)

        assertEqual(fixture.events, originalEvents, "a repeated show is a no-op while this popover is visible")
        assertEqual(fixture.fallbackPanels.count, 1, "a repeated show does not replace the retained anchor")
        assertEqual(fixture.fallbackPanels.first?.orderOutCount, 0, "a repeated show does not remove the retained anchor")
    }

    runSuite("The status click that dismisses a fallback menu does not reopen it on mouse up") {
        for buttonType: NSEvent.EventType in [.leftMouseDown, .rightMouseDown] {
            let fixture = MenuBarPopoverPresentationFixture()
            fixture.popover.showResults = [false, true, false, true]
            fixture.presentation.show(fixture.popover, relativeTo: fixture.anchor)
            fixture.currentEvent = menuBarMouseEvent(buttonType, number: 71, at: fixture.anchorScreenPoint)
            fixture.popover.close()
            let upType: NSEvent.EventType = buttonType == .leftMouseDown ? .leftMouseUp : .rightMouseUp
            fixture.currentEvent = menuBarMouseEvent(upType, number: 71, at: fixture.anchorScreenPoint)
            fixture.presentation.show(fixture.popover, relativeTo: fixture.anchor)

            assertEqual(fixture.popover.presentations.count, 2, "matching mouse up consumes the dismissal without reopening")
            assertEqual(fixture.fallbackPanels.count, 1, "the dismissing click creates no replacement panel")
            assertTrue(!fixture.popover.isShown, "clicking the original status button leaves the menu closed")

            fixture.currentEvent = menuBarMouseEvent(upType, number: 72, at: fixture.anchorScreenPoint)
            fixture.presentation.show(fixture.popover, relativeTo: fixture.anchor)
            assertEqual(fixture.popover.presentations.count, 4, "the next independent click can reopen normally")
            assertTrue(fixture.popover.isShown, "suppression is limited to the closing click")
        }
    }

    runSuite("A different click or button is not suppressed after status-button dismissal") {
        let nextClicks: [(NSEvent.EventType, Int)] = [(.leftMouseUp, 82), (.rightMouseUp, 81)]
        for (type, number) in nextClicks {
            let fixture = MenuBarPopoverPresentationFixture()
            fixture.popover.showResults = [false, true, false, true]
            fixture.presentation.show(fixture.popover, relativeTo: fixture.anchor)
            fixture.currentEvent = menuBarMouseEvent(.leftMouseDown, number: 81, at: fixture.anchorScreenPoint)
            fixture.popover.close()
            fixture.currentEvent = menuBarMouseEvent(type, number: number, at: fixture.anchorScreenPoint)
            fixture.presentation.show(fixture.popover, relativeTo: fixture.anchor)

            assertEqual(fixture.popover.presentations.count, 4, "a different event number or mouse button represents a new click")
            assertTrue(fixture.popover.isShown, "an unrelated click can show the menu")
        }
    }

    runSuite("Status-button dismissal cannot suppress a matching event for another anchor view") {
        let fixture = MenuBarPopoverPresentationFixture()
        fixture.popover.showResults = [false, true, false, true]
        fixture.presentation.show(fixture.popover, relativeTo: fixture.anchor)
        fixture.currentEvent = menuBarMouseEvent(.leftMouseDown, number: 91, at: fixture.anchorScreenPoint)
        fixture.popover.close()
        let otherAnchor = NSView(frame: fixture.anchor.frame)
        fixture.sourceWindow.contentView?.addSubview(otherAnchor)
        fixture.currentEvent = menuBarMouseEvent(.leftMouseUp, number: 91, at: fixture.anchorScreenPoint)
        fixture.presentation.show(fixture.popover, relativeTo: otherAnchor)

        assertEqual(fixture.popover.presentations.count, 4, "suppression belongs only to the source status button")
        assertTrue(fixture.popover.isShown, "another source view remains able to present")
    }

    runSuite("Outside click and Escape dismissal leave the next status click available") {
        for dismissal in ["outside click", "Escape", "no event"] {
            let fixture = MenuBarPopoverPresentationFixture()
            fixture.popover.showResults = [false, true, false, true]
            fixture.presentation.show(fixture.popover, relativeTo: fixture.anchor)
            if dismissal == "outside click" {
                let outsidePoint = NSPoint(x: fixture.anchorScreenPoint.x + 100, y: fixture.anchorScreenPoint.y - 100)
                fixture.currentEvent = menuBarMouseEvent(.leftMouseDown, number: 101, at: outsidePoint)
            } else if dismissal == "Escape" {
                fixture.currentEvent = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: 0, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                    isARepeat: false, keyCode: 53
                )
            }
            fixture.popover.close()
            fixture.currentEvent = menuBarMouseEvent(.leftMouseUp, number: 101, at: fixture.anchorScreenPoint)
            fixture.presentation.show(fixture.popover, relativeTo: fixture.anchor)

            assertEqual(fixture.popover.presentations.count, 4, "\(dismissal) must not consume the next status click")
            assertTrue(fixture.popover.isShown, "the menu reopens after \(dismissal)")
        }
    }

    runSuite("Explicit menu dismissal does not consume a later request with a retained mouse event") {
        let fixture = MenuBarPopoverPresentationFixture()
        fixture.popover.showResults = [false, true, false, true]
        fixture.presentation.show(fixture.popover, relativeTo: fixture.anchor)
        fixture.currentEvent = menuBarMouseEvent(.leftMouseUp, number: 111, at: fixture.anchorScreenPoint)
        fixture.presentation.close(fixture.popover)
        fixture.presentation.show(fixture.popover, relativeTo: fixture.anchor)

        assertEqual(fixture.popover.closeCount, 1, "explicit dismissal closes the shown menu")
        assertEqual(fixture.fallbackPanels.first?.orderOutCount, 1, "explicit dismissal removes its original anchor")
        assertEqual(fixture.popover.presentations.count, 4, "an explicit close cannot treat the retained event as a new dismissal click")
        assertTrue(fixture.popover.isShown, "a subsequent presentation request still opens")
    }

    runSuite("Left and right status clicks retain the same popover toggle action") {
        let button = MenuBarToggleButton(frame: .zero)
        let target = MenuBarPopoverToggleTarget()
        let action = #selector(MenuBarPopoverToggleTarget.toggle)
        MenuBarPopoverPresentation.installToggleAction(on: button, target: target, action: action)

        assertEqual(button.requestedEvents, [.leftMouseUp, .rightMouseUp], "both clicks open the same menu, without firing on mouse down")
        assertTrue(button.target === target, "both clicks retain the same target")
        assertEqual(button.action, action, "both clicks retain the same toggle action")
    }
}

@MainActor
private final class MenuBarPopoverPresentationFixture {
    var events: [String] = []
    var screens = [NSRect(x: 0, y: 0, width: 3000, height: 3000)]
    var fallbackPanels: [MenuBarPopoverAnchorPanel] = []
    var onShow: ((Int) -> Void)?
    var currentEvent: NSEvent?
    var windowVisibility: (NSWindow) -> MenuBarPopoverWindowVisibility = { _ in .unknown }
    let spaceNotifications = NotificationCenter()
    let sourceWindow = MenuBarPopoverSourceWindow(
        contentRect: NSRect(x: 500, y: 800, width: 200, height: 50),
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: true
    )
    let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 24, height: 22))
    let content = NSViewController()
    let window = MenuBarPopoverFocusWindow(
        contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: true
    )
    let popover = MenuBarRecordingPopover()
    lazy var presentation = MenuBarPopoverPresentation(
        makeAnchorWindow: { [unowned self] in
            self.events.append("create anchor")
            let panel = MenuBarPopoverAnchorPanel(
                contentRect: .zero,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: true
            )
            panel.onOrderFront = { [weak self] in self?.events.append("order anchor") }
            panel.onOrderOut = { [weak self] in self?.events.append("order out anchor") }
            self.fallbackPanels.append(panel)
            return panel
        },
        screenFrames: { [unowned self] in self.screens },
        spaceNotifications: spaceNotifications,
        currentEvent: { [unowned self] in self.currentEvent },
        windowVisibility: { [unowned self] window in self.windowVisibility(window) }
    )

    var anchorScreenPoint: NSPoint {
        let rect = sourceWindow.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        return NSPoint(x: rect.midX, y: rect.midY)
    }

    init() {
        sourceWindow.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 50))
        sourceWindow.contentView?.addSubview(anchor)
        content.view = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        popover.contentViewController = content
        popover.onShow = { [weak self] in
            guard let self else { return }
            self.events.append("show")
            if self.popover.isShown, self.popover.attachWindow {
                self.window.contentView = self.content.view
            }
            self.onShow?(self.popover.presentations.count)
        }
        window.onMakeKey = { [weak self] in self?.events.append("focus popover") }
    }
}

@MainActor
private final class MenuBarPopoverSourceWindow: NSPanel {
    var screenRectOverride: NSRect?

    override func convertToScreen(_ rect: NSRect) -> NSRect {
        screenRectOverride ?? super.convertToScreen(rect)
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor
private final class MenuBarPopoverAnchorPanel: NSPanel {
    var onOrderFront: (() -> Void)?
    var onOrderOut: (() -> Void)?
    private(set) var orderOutCount = 0

    // These calls must stay inert: the tests do not display windows or switch Spaces.
    override func orderFrontRegardless() { onOrderFront?() }
    override func orderOut(_ sender: Any?) {
        orderOutCount += 1
        onOrderOut?()
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor
private final class MenuBarPopoverFocusWindow: NSPanel {
    var onMakeKey: (() -> Void)?
    var reportedWindowNumber = 713
    override var windowNumber: Int { reportedWindowNumber }

    // Record the request without showing a window or changing system focus.
    override func makeKey() { onMakeKey?() }
}

@MainActor
private final class MenuBarRecordingPopover: NSPopover {
    struct Presentation {
        let rect: NSRect
        let view: NSView
        let edge: NSRectEdge
    }

    var showResults: [Bool] = [true]
    var attachWindow = true
    var onShow: (() -> Void)?
    private(set) var presentations: [Presentation] = []
    private(set) var closeCount = 0
    var shownRelativeTo: NSView?
    var shownRect = NSRect.zero
    var shownEdge: NSRectEdge = .maxY
    private var didShow = false

    override var isShown: Bool { didShow }

    // Exercise the production presentation seam without displaying UI.
    override func show(relativeTo positioningRect: NSRect, of positioningView: NSView, preferredEdge: NSRectEdge) {
        shownRelativeTo = positioningView
        shownRect = positioningRect
        shownEdge = preferredEdge
        let index = presentations.count
        presentations.append(Presentation(rect: positioningRect, view: positioningView, edge: preferredEdge))
        didShow = showResults.indices.contains(index) ? showResults[index] : false
        onShow?()
    }

    override func close() {
        closeCount += 1
        NotificationCenter.default.post(name: NSPopover.willCloseNotification, object: self)
        didShow = false
        NotificationCenter.default.post(name: NSPopover.didCloseNotification, object: self)
    }

    override func performClose(_ sender: Any?) { close() }
}

@MainActor
private func menuBarMouseEvent(_ type: NSEvent.EventType, number: Int, at point: NSPoint) -> NSEvent? {
    // Window number zero makes locationInWindow a screen position. These
    // records are never posted to AppKit or the operating system.
    NSEvent.mouseEvent(
        with: type, location: point, modifierFlags: [], timestamp: 0,
        windowNumber: 0, context: nil, eventNumber: number, clickCount: 1, pressure: 0
    )
}

@MainActor
private final class MenuBarPopoverToggleTarget: NSObject {
    @objc func toggle() {}
}

@MainActor
private final class MenuBarToggleButton: NSButton {
    var requestedEvents: NSEvent.EventTypeMask = []

    // A plain NSButton filters right-click delivery differently from the
    // status bar button. Record the requested mask without creating a real
    // status item in the user's menu bar.
    override func sendAction(on mask: NSEvent.EventTypeMask) -> Int {
        requestedEvents = mask
        return 0
    }
}
