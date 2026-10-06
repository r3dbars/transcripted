import Foundation

/// What the Settings window still does while it's closed. The window is kept
/// (`isReleasedWhenClosed = false`) and SwiftUI keeps delivering
/// notifications to it, so without these rules a window nobody can see
/// re-reads permissions and reloads libraries on every app activation.
enum SettingsClosedWindowRefreshPolicy {
    struct ActivationWork: Equatable {
        var permissions: Bool
        var shortcuts: Bool
        var launchAtLogin: Bool
        /// Opening the window refreshes Today; activation while closed does no I/O.
        var recentCaptures: Bool
        /// Whether activation also reloads Home and Dictations. Skipped while
        /// closed; opening the window forces that reload anyway.
        var dashboard: Bool
    }

    /// Work for `NSApplication.didBecomeActiveNotification`. Opening the
    /// window runs the full refresh, so nothing is lost by skipping it here.
    static func appActivationWork(isWindowOpen: Bool) -> ActivationWork {
        ActivationWork(
            permissions: isWindowOpen,
            shortcuts: isWindowOpen,
            launchAtLogin: isWindowOpen,
            recentCaptures: isWindowOpen,
            dashboard: isWindowOpen
        )
    }

    /// True when an activation comes right after the window was presented.
    /// `present()` activates the app and starts the full `refreshState()` for
    /// that presentation, which already covers every read activation does, so
    /// the activation sweep would read permissions, shortcuts and login state
    /// a second time on the main thread while the window opens.
    static let presentationActivationWindow: TimeInterval = 1

    static func activationRepeatsPresentation(presentedAt: Date?, now: Date) -> Bool {
        guard let presentedAt else { return false }
        let elapsed = now.timeIntervalSince(presentedAt)
        return elapsed >= 0 && elapsed < presentationActivationWindow
    }
}

/// Holds the newest value while the window is closed instead of publishing
/// it, so a hidden view doesn't re-render. Opening the window hands back the
/// held value to publish before the first frame.
struct SettingsWindowSnapshotHold<Value> {
    private(set) var isWindowOpen = true
    private(set) var held: Value?

    /// The value to publish now, or nil when it was held for later.
    mutating func deliver(_ value: Value) -> Value? {
        guard isWindowOpen else {
            held = value
            return nil
        }
        held = nil
        return value
    }

    mutating func windowDidClose() {
        isWindowOpen = false
    }

    /// The held value to publish now, if one arrived while closed.
    mutating func windowWillShow() -> Value? {
        isWindowOpen = true
        defer { held = nil }
        return held
    }
}
