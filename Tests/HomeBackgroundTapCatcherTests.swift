import AppKit
import SwiftUI

// Promises for the click-away around Speakers (and Home): it closes an open
// card on a click in empty space, and never takes a click meant for an AppKit
// button inside it. User report on 1.1.74: with three meetings to confirm,
// Skip and "Done, next meeting" on the Speakers "Who spoke?" card answered
// only on their 1px edge. Those buttons are borderless NSButtons inside an
// NSViewRepresentable, and the whole Speakers section sits in this catcher.

@MainActor
private final class ClickAwayButtonTarget: NSObject {
    var presses = 0
    @objc func press() { presses += 1 }
}

/// A borderless, momentary-change NSButton like the review's footer pills.
private struct ClickAwayFooterButton: NSViewRepresentable {
    let button: NSButton
    func makeNSView(context: Context) -> NSButton { button }
    func updateNSView(_ nsView: NSButton, context: Context) {}
}

/// Refuses a quit while the fixture is up. A quit ends the test process with
/// status 0 before the summary, which hides every later suite; one CI run of
/// this file stopped that way. Counted so the suite can say so.
@MainActor
private final class ClickAwayAppDelegate: NSObject, NSApplicationDelegate {
    static let shared = ClickAwayAppDelegate()
    var quitRequests = 0
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        quitRequests += 1
        return .terminateCancel
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@MainActor
private final class ClickAwayFixture {
    let target = ClickAwayButtonTarget()
    let button: NSButton
    var clickAways = 0
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 240),
                          styleMask: [.borderless], backing: .buffered, defer: false)

    private let previousDelegate: NSApplicationDelegate?

    init(title: String) {
        _ = NSApplication.shared
        previousDelegate = NSApp.delegate
        NSApp.delegate = ClickAwayAppDelegate.shared
        button = NSButton(title: title, target: nil, action: nil)
        button.isBordered = false
        button.setButtonType(.momentaryChange)
        button.wantsLayer = true
        button.target = target
        button.action = #selector(ClickAwayButtonTarget.press)
        let root = VStack(alignment: .leading, spacing: 0) {
            ClickAwayFooterButton(button: button)
                .frame(width: 180, height: 34)
                .padding(20)
            Spacer(minLength: 0)
        }
        .frame(width: 400, height: 240, alignment: .topLeading)
        .homeBackgroundTapCatcher { [unowned self] in self.clickAways += 1 }
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: root)
        window.orderFrontRegardless()
        window.contentView?.layoutSubtreeIfNeeded()
    }

    /// One short turn of the run loop, then a turn of the main queue. The
    /// tests run inside a main-queue job, and a run loop turned from there
    /// does not run other main-queue work, which SwiftUI may use to deliver a
    /// tap: yielding lets that work run.
    private func turn() async {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        await Task.yield()
    }

    /// SwiftUI puts the AppKit button in the window on a later turn, and builds
    /// its gestures when it first draws: wait for the button, up to two seconds.
    func waitUntilReady() async {
        let deadline = Date().addingTimeInterval(2)
        while !isReady, Date() < deadline { await turn() }
    }

    /// The button is in this window with a real size.
    var isReady: Bool { button.window === window && button.frame.width > 0 && button.frame.height > 0 }

    /// The button's center (or an offset from it) in window coordinates.
    func pointInButton(dx: CGFloat = 0, dy: CGFloat = 0) -> NSPoint {
        let center = NSPoint(x: button.bounds.midX + dx, y: button.bounds.midY + dy)
        return button.convert(center, to: nil)
    }

    /// A real left click through the window: down, then up. The up is queued
    /// first so a button's tracking loop can take it; if something else took
    /// the down, the up is delivered here instead.
    func click(at point: NSPoint) async {
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil,
                               eventNumber: 0, clickCount: 1,
                               pressure: type == .leftMouseDown ? 1 : 0)!
        }
        let before = target.presses + clickAways
        NSApp.postEvent(event(.leftMouseUp), atStart: false)
        window.sendEvent(event(.leftMouseDown))
        while let pending = NSApp.nextEvent(matching: [.leftMouseUp], until: Date(),
                                            inMode: .default, dequeue: true) {
            window.sendEvent(pending)
        }
        // SwiftUI runs a tap's action on a later turn of the run loop: wait
        // for either answer, up to a second.
        let deadline = Date().addingTimeInterval(1)
        while target.presses + clickAways == before, Date() < deadline { await turn() }
    }

    func close() {
        window.close()
        NSApp.delegate = previousDelegate
    }
}

// async so the runner hops to the main thread: windows need it.
@MainActor
func testHomeBackgroundTapCatcher() async {
    let doneTitle = SpeakerMeetingReviewPolicy.doneTitle(meetingsAfterThis: 2)

    await runSuite("A click on empty space still closes the open card") {
        let fixture = ClickAwayFixture(title: doneTitle)
        defer { fixture.close() }
        await fixture.waitUntilReady()
        assertTrue(fixture.isReady, "the button is in the window")
        await fixture.click(at: NSPoint(x: 300, y: 40))
        assertEqual(fixture.clickAways, 1, "empty-space click reached the click-away")
        assertEqual(fixture.target.presses, 0, "empty-space click pressed nothing")
    }

    await runSuite("A click on the middle of \"\(doneTitle)\" presses it, not the click-away") {
        let fixture = ClickAwayFixture(title: doneTitle)
        defer { fixture.close() }
        await fixture.waitUntilReady()
        assertTrue(fixture.isReady, "the button is in the window")
        await fixture.click(at: fixture.pointInButton())
        assertEqual(fixture.target.presses, 1,
                    "center click pressed the button (click-away took \(fixture.clickAways))")
        assertEqual(fixture.clickAways, 0, "center click left the click-away alone")
    }

    await runSuite("Clicks anywhere across the label press the button, every time") {
        let fixture = ClickAwayFixture(title: doneTitle)
        defer { fixture.close() }
        await fixture.waitUntilReady()
        // Left of the label, its middle, right of it, three times over (one
        // round per queued meeting).
        for _ in 0..<3 {
            for dx: CGFloat in [-60, 0, 60] { await fixture.click(at: fixture.pointInButton(dx: dx, dy: 4)) }
        }
        assertEqual(fixture.target.presses, 9,
                    "nine label clicks pressed the button (click-away took \(fixture.clickAways))")
        assertEqual(fixture.clickAways, 0, "label clicks left the click-away alone")
    }

    runSuite("Nothing above asked the test process to quit") {
        assertEqual(ClickAwayAppDelegate.shared.quitRequests, 0, "quit requests refused during the click tests")
    }
    // Two CI runs ended with status 0 inside this file and printed no
    // summary. Flush, so the next run's log shows whether the file finished.
    print("HomeBackgroundTapCatcher: all four suites returned")
    fflush(stdout)
}
