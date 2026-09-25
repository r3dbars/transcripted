import AppKit

/// Feeds `PopupPresenceTracker` from AppKit window notifications on the main
/// thread. A popup is a modal window (alerts, open/save panels) or a Sparkle
/// update window. `NSAlert.runModal` orders its window out rather than
/// closing it, so a popup also counts as closed once it resigns key and is no
/// longer visible.
@MainActor
final class AppHangPopupObserver {
    static let shared = AppHangPopupObserver()

    private let tracker: PopupPresenceTracker
    private var tokens: [NSObjectProtocol] = []
    private var tracked: [ObjectIdentifier: WeakWindow] = [:]

    private struct WeakWindow {
        weak var window: NSWindow?
    }

    init(tracker: PopupPresenceTracker = .shared) {
        self.tracker = tracker
    }

    func start() {
        guard tokens.isEmpty else { return }
        let center = NotificationCenter.default
        tokens.append(center.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated { self?.windowBecameKey(window) }
        })
        tokens.append(center.addObserver(
            forName: NSWindow.didResignKeyNotification, object: nil, queue: .main
        ) { [weak self] note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated { self?.windowResignedKey(window) }
        })
        tokens.append(center.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated { self?.markClosed(window) }
        })
    }

    static func isPopup(_ window: NSWindow) -> Bool {
        if NSApp.modalWindow === window { return true }
        // Sparkle's update windows are plain NSWindows owned by its own
        // controllers (SUUpdateAlert, SPUStandardUserDriver...).
        let classNames = [
            String(describing: type(of: window)),
            window.windowController.map { String(describing: type(of: $0)) } ?? "",
        ]
        return classNames.contains { $0.hasPrefix("SPU") || $0.hasPrefix("SU") }
    }

    private func windowBecameKey(_ window: NSWindow?) {
        pruneHiddenPopups()
        guard let window, Self.isPopup(window) else { return }
        let id = ObjectIdentifier(window)
        tracked[id] = WeakWindow(window: window)
        tracker.popupOpened(id)
    }

    private func windowResignedKey(_ window: NSWindow?) {
        guard let window, tracked[ObjectIdentifier(window)] != nil else { return }
        // runModal orders the alert out after this fires; check once it returns.
        DispatchQueue.main.async { [weak self] in
            self?.pruneHiddenPopups()
        }
    }

    private func markClosed(_ window: NSWindow?) {
        guard let window else { return }
        let id = ObjectIdentifier(window)
        guard tracked.removeValue(forKey: id) != nil else { return }
        tracker.popupClosed(id)
    }

    private func pruneHiddenPopups() {
        for (id, entry) in tracked {
            guard let window = entry.window else {
                tracked.removeValue(forKey: id)
                tracker.popupClosed(id)
                continue
            }
            if !window.isVisible {
                tracked.removeValue(forKey: id)
                tracker.popupClosed(id)
            }
        }
    }
}
