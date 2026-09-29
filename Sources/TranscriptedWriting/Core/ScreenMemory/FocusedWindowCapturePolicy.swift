import Foundation

/// Picks the one window Screen Memory may read: the focused window of the
/// app the user is typing in. Owner decision 2026-09-29: setup tells people
/// Screen Memory "reads the window you're replying in", so it never reads
/// the whole display and never another app's window. Pure and
/// deterministic so the rule is testable without a live display.
///
/// Fails closed. Anything the caller can't prove about the window (it's
/// gone, it belongs to someone else, it isn't in front, its app is unknown,
/// excluded or out of scope) is a refusal, and a refusal captures nothing.
public enum FocusedWindowCapturePolicy {
    /// One on-screen window, as the capture layer saw it.
    public struct Window: Equatable, Sendable {
        public let windowIdentifier: UInt32
        public let processIdentifier: Int32
        public let bundleIdentifier: String?
        /// Window server layer. Normal document windows are layer 0; menus,
        /// panels and overlays sit above it.
        public let layer: Int
        /// Documented front-to-back rank, 0 is frontmost. `nil` when the
        /// window server's on-screen list doesn't include the window.
        public let zOrderRank: Int?

        public init(
            windowIdentifier: UInt32,
            processIdentifier: Int32,
            bundleIdentifier: String?,
            layer: Int,
            zOrderRank: Int?
        ) {
            self.windowIdentifier = windowIdentifier
            self.processIdentifier = processIdentifier
            self.bundleIdentifier = bundleIdentifier
            self.layer = layer
            self.zOrderRank = zOrderRank
        }
    }

    /// Who has focus right now, observed at capture time.
    public struct FocusEvidence: Equatable, Sendable {
        /// The active app. `nil` when it can't be read, which refuses.
        public let frontmostApplicationProcessIdentifier: Int32?
        /// The app Accessibility says has keyboard focus. It can differ from
        /// the frontmost app when a non-activating panel (a launcher, a
        /// floating search field) takes the keyboard. `nil` means unknown
        /// (no Accessibility access, or the system didn't answer), which
        /// refuses: without it a launcher's typing could read the window
        /// behind it.
        public let keyboardFocusProcessIdentifier: Int32?

        public init(
            frontmostApplicationProcessIdentifier: Int32?,
            keyboardFocusProcessIdentifier: Int32?
        ) {
            self.frontmostApplicationProcessIdentifier = frontmostApplicationProcessIdentifier
            self.keyboardFocusProcessIdentifier = keyboardFocusProcessIdentifier
        }
    }

    public enum Choice: Equatable, Sendable {
        case capture(windowIdentifier: UInt32)
        case refuse(Refusal)
    }

    public enum Refusal: Equatable, Sendable {
        /// No typing target, or one without a window or process.
        case noTarget
        /// The target window isn't among the on-screen windows.
        case windowNotVisible
        /// The window belongs to a different process or app than the target.
        case ownerMismatch
        /// Not a normal document window (layer 0).
        case notNormalWindow
        /// The window's app has no bundle ID, so exclusions and the app
        /// scope can't be checked.
        case unknownApp
        /// A password manager or an app on the user's exclusion list.
        case excluded(bundleIdentifier: String)
        /// The app isn't in the Writing app scope.
        case outOfScope(bundleIdentifier: String)
        /// The window's app isn't the frontmost app (or that's unknown).
        case notFrontmostApp
        /// Accessibility says keyboard focus is in another process.
        case keyboardFocusElsewhere
        /// Accessibility couldn't say which process has keyboard focus.
        case keyboardFocusUnknown
        /// Another window of the same app is in front of this one, or the
        /// window's z-order is unknown.
        case notFocusedWindow
    }

    public static func choose(
        target: TypingTargetIdentity?,
        windows: [Window],
        focus: FocusEvidence,
        excludedApps: Set<String>,
        appInScope: (String) -> Bool
    ) -> Choice {
        guard let target,
              let windowIdentifier = target.windowIdentifier,
              let processIdentifier = target.processIdentifier else {
            return .refuse(.noTarget)
        }
        guard let window = windows.first(where: { $0.windowIdentifier == windowIdentifier }) else {
            return .refuse(.windowNotVisible)
        }
        // Window IDs get reused, so the ID alone doesn't prove this is the
        // window the target named.
        guard window.processIdentifier == processIdentifier,
              target.bundleIdentifier == nil || window.bundleIdentifier == target.bundleIdentifier else {
            return .refuse(.ownerMismatch)
        }
        guard window.layer == 0 else { return .refuse(.notNormalWindow) }
        guard let bundleIdentifier = window.bundleIdentifier, !bundleIdentifier.isEmpty else {
            return .refuse(.unknownApp)
        }
        // Always unions the password-manager set; never trusts the caller to.
        if DefaultExcludedApps.isExcluded(bundleIdentifier, configuredExcludedApps: excludedApps) {
            return .refuse(.excluded(bundleIdentifier: bundleIdentifier))
        }
        guard appInScope(bundleIdentifier) else {
            return .refuse(.outOfScope(bundleIdentifier: bundleIdentifier))
        }
        guard focus.frontmostApplicationProcessIdentifier == processIdentifier else {
            return .refuse(.notFrontmostApp)
        }
        guard let keyboardFocus = focus.keyboardFocusProcessIdentifier else {
            return .refuse(.keyboardFocusUnknown)
        }
        guard keyboardFocus == processIdentifier else { return .refuse(.keyboardFocusElsewhere) }
        // The app's focused window is its frontmost normal window.
        guard let rank = window.zOrderRank else { return .refuse(.notFocusedWindow) }
        let sameAppWindowInFront = windows.contains {
            $0.processIdentifier == processIdentifier
                && $0.layer == 0
                && $0.windowIdentifier != windowIdentifier
                && ($0.zOrderRank.map { $0 < rank } ?? false)
        }
        guard !sameAppWindowInFront else { return .refuse(.notFocusedWindow) }
        return .capture(windowIdentifier: windowIdentifier)
    }
}
