import AppKit

@MainActor
func testMenuBarPopoverPresentation() async {
    // AppKit requires an application object before constructing even an
    // undisplayed window. This does not activate or display the application.
    _ = NSApplication.shared
    runSuite("Opening the menu focuses only its popover window after showing it") {
        let fixture = MenuBarPopoverPresentationFixture()
        MenuBarPopoverPresentation.show(fixture.popover, relativeTo: fixture.anchor)

        assertEqual(fixture.events, ["show", "focus popover"], "show must create the window before keyboard focus is requested")
        assertTrue(fixture.popover.shownRelativeTo === fixture.anchor, "keep the clicked status button as the anchor")
        assertEqual(fixture.popover.shownRect, fixture.anchor.bounds, "anchor to the button's bounds")
        assertEqual(fixture.popover.shownEdge, .minY, "open below the menu bar")
    }

    runSuite("A menu that cannot show does not focus a retained popover window") {
        let fixture = MenuBarPopoverPresentationFixture()
        // A previous presentation can leave the content attached to its
        // window. AppKit may refuse the next show if the anchor is hidden.
        fixture.window.contentView = fixture.content.view
        fixture.popover.willShow = false
        MenuBarPopoverPresentation.show(fixture.popover, relativeTo: fixture.anchor)

        assertEqual(fixture.events, ["show"], "a hidden menu must not steal keyboard focus")
    }

    runSuite("A shown menu without a content window leaves other windows alone") {
        let fixture = MenuBarPopoverPresentationFixture()
        fixture.popover.attachWindow = false
        MenuBarPopoverPresentation.show(fixture.popover, relativeTo: fixture.anchor)

        assertEqual(fixture.events, ["show"], "there is no application-wide focus fallback")
    }

    runSuite("Left and right status clicks retain the same popover toggle action") {
        let button = NSButton(frame: .zero)
        let target = MenuBarPopoverToggleTarget()
        let action = #selector(MenuBarPopoverToggleTarget.toggle)
        MenuBarPopoverPresentation.installToggleAction(on: button, target: target, action: action)

        let configuredEvents = NSEvent.EventTypeMask(rawValue: UInt64(button.sendAction(on: [])))
        assertEqual(configuredEvents, [.leftMouseUp, .rightMouseUp], "both clicks open the same menu, without firing on mouse down")
        assertTrue(button.target === target, "both clicks retain the same target")
        assertEqual(button.action, action, "both clicks retain the same toggle action")
    }
}

@MainActor
private final class MenuBarPopoverPresentationFixture {
    var events: [String] = []
    let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 24, height: 22))
    let content = NSViewController()
    let window = MenuBarPopoverFocusWindow(
        contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: true
    )
    let popover = MenuBarRecordingPopover()

    init() {
        content.view = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        popover.contentViewController = content
        popover.onShow = { [weak self] in
            guard let self else { return }
            self.events.append("show")
            if self.popover.willShow, self.popover.attachWindow {
                self.window.contentView = self.content.view
            }
        }
        window.onMakeKey = { [weak self] in self?.events.append("focus popover") }
    }
}

@MainActor
private final class MenuBarPopoverFocusWindow: NSPanel {
    var onMakeKey: (() -> Void)?

    // Record the request without showing a window or changing system focus.
    override func makeKey() { onMakeKey?() }
}

@MainActor
private final class MenuBarRecordingPopover: NSPopover {
    var willShow = true
    var attachWindow = true
    var onShow: (() -> Void)?
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
        onShow?()
        didShow = willShow
    }
}

@MainActor
private final class MenuBarPopoverToggleTarget: NSObject {
    @objc func toggle() {}
}
