import AppKit

/// Feeds `PopupPresenceTracker` from AppKit window notifications on the main
/// thread. A popup is a modal window (alerts, open/save panels, any modal
/// update prompt). `NSAlert.runModal` orders its window out rather than
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

    /// Only a modal window blocks the main queue. A non-modal window (like
    /// Sparkle's usual update window) can stay open for hours without
    /// explaining a freeze, so it must not silence one.
    static func isPopup(_ window: NSWindow) -> Bool {
        NSApp.modalWindow === window
    }

    private func windowBecameKey(_ window: NSWindow?) {
        pruneHiddenPopups()
        guard let window else { return }
        if Self.isPopup(window) {
            track(window)
            return
        }
        // If the modal session hasn't registered the window yet, look again
        // once the run loop turns, including inside the modal loop itself.
        let id = ObjectIdentifier(window)
        RunLoop.main.perform(inModes: [.default, .modalPanel]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let key = NSApp.keyWindow,
                      ObjectIdentifier(key) == id, Self.isPopup(key) else { return }
                self.track(key)
            }
        }
    }

    private func track(_ window: NSWindow) {
        let id = ObjectIdentifier(window)
        guard tracked[id] == nil else { return }
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
