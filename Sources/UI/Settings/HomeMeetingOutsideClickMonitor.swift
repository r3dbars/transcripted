import AppKit
import SwiftUI

/// Watches for clicks outside an expanded Meetings card in the same window
/// (margins, right gutter, below the list, day headers) without adding any
/// hit-testing view over the card or competing with buttons inside it.
///
/// Defers collapse until one runloop tick after mouse-up so clicking a closed
/// card below the open one still opens that card cleanly instead of shifting
/// it out from under the pointer on mouse-down.
struct HomeMeetingOutsideClickMonitor: NSViewRepresentable {
    let isActive: Bool
    let onOutsideClick: () -> Void

    func makeNSView(context: Context) -> OutsideClickAnchorView {
        let view = OutsideClickAnchorView()
        view.onOutsideClick = onOutsideClick
        view.setMonitoring(isActive)
        return view
    }

    func updateNSView(_ view: OutsideClickAnchorView, context: Context) {
        view.onOutsideClick = onOutsideClick
        view.setMonitoring(isActive)
    }

    static func dismantleNSView(_ view: OutsideClickAnchorView, coordinator: ()) {
        view.setMonitoring(false)
    }
}

@MainActor
final class OutsideClickAnchorView: NSView {
    var onOutsideClick: (() -> Void)?

    private var downMonitor: Any?
    private var upMonitor: Any?
    private var pendingDownPoint: NSPoint?
    private var isMonitoring = false

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setMonitoring(_ active: Bool) {
        guard active != isMonitoring else { return }
        isMonitoring = active
        if active {
            installMonitors()
        } else {
            removeMonitors()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            removeMonitors()
            isMonitoring = false
        }
    }

    private func installMonitors() {
        guard downMonitor == nil else { return }
        downMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.handleMouseDown(event)
            return event
        }
        upMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            self?.handleMouseUp(event)
            return event
        }
    }

    private func removeMonitors() {
        if let downMonitor {
            NSEvent.removeMonitor(downMonitor)
            self.downMonitor = nil
        }
        if let upMonitor {
            NSEvent.removeMonitor(upMonitor)
            self.upMonitor = nil
        }
        pendingDownPoint = nil
    }

    private func handleMouseDown(_ event: NSEvent) {
        pendingDownPoint = nil
        guard isMonitoring, let hostWindow = window, event.window === hostWindow else { return }
        let localPoint = convert(event.locationInWindow, from: nil)
        if bounds.contains(localPoint) { return }
        if let hit = hostWindow.contentView?.hitTest(event.locationInWindow),
           Self.isInsideScroller(hit) {
            return
        }
        pendingDownPoint = event.locationInWindow
    }

    private func handleMouseUp(_ event: NSEvent) {
        guard let downPoint = pendingDownPoint else { return }
        pendingDownPoint = nil
        guard isMonitoring, let hostWindow = window, event.window === hostWindow else { return }
        // Ignore drags (window move, text selection, card drag).
        let distance = hypot(event.locationInWindow.x - downPoint.x, event.locationInWindow.y - downPoint.y)
        guard distance <= 6 else { return }
        let localPoint = convert(event.locationInWindow, from: nil)
        guard !bounds.contains(localPoint) else { return }

        // Defer one tick so a Button click on another meeting card runs first
        // and replaces the open card before we decide whether to collapse.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isMonitoring, self.window != nil else { return }
            self.onOutsideClick?()
        }
    }

    private static func isInsideScroller(_ view: NSView) -> Bool {
        var cursor: NSView? = view
        while let current = cursor {
            if current is NSScroller { return true }
            cursor = current.superview
        }
        return false
    }
}
