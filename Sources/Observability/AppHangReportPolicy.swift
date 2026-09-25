import Foundation

/// Decides which Sentry app-hang reports are real freezes.
///
/// Hang tracking used to be off because a modal window (an alert, an open
/// panel, the update window) runs its own run loop that doesn't drain the
/// main dispatch queue, so Sentry's watchdog counted a person reading a popup
/// as a frozen app. This policy keeps the watchdog on but only reports a
/// freeze of 5+ seconds, and drops any hang while a popup was showing.
enum AppHangReportPolicy {
    /// A freeze must last this long before it is reported (Sentry's default is 2 s).
    static let timeoutSeconds: TimeInterval = 5

    /// A popup that closed this recently can still explain a hang: the
    /// watchdog's ping may have waited behind it and landed just after.
    static let popupGraceSeconds: TimeInterval = 1

    /// Main-thread frame names that mean the app is waiting on a popup or a
    /// system permission prompt, not frozen. Matched as substrings. Frame
    /// names are only present when the SDK symbolicates on device, so this is
    /// a backstop behind `PopupPresenceTracker`.
    static let popupFrameMarkers: [String] = [
        "runModal",
        "ModalSession",
        "NSAlert",
        "SPUStandardUserDriver",
        "TCC",
        "AESendMessage",
        "requestAccess",
    ]

    static func isAppHang(mechanismType: String?) -> Bool {
        mechanismType == "AppHang"
    }

    static func shouldDrop(
        mechanismType: String?,
        popupLikely: Bool,
        mainThreadFunctions: [String]
    ) -> Bool {
        guard isAppHang(mechanismType: mechanismType) else { return false }
        if popupLikely { return true }
        return mainThreadFunctions.contains { function in
            popupFrameMarkers.contains { function.contains($0) }
        }
    }
}

/// Thread-safe record of whether a popup is on screen. AppKit notifications
/// update it on the main thread; Sentry reads it from its watchdog thread
/// while the main thread may be stuck, so it never touches AppKit itself.
final class PopupPresenceTracker: @unchecked Sendable {
    static let shared = PopupPresenceTracker()

    private let lock = NSLock()
    private var openPopups: Set<ObjectIdentifier> = []
    private var lastClosedAt: Date?

    func popupOpened(_ id: ObjectIdentifier) {
        lock.lock()
        defer { lock.unlock() }
        openPopups.insert(id)
    }

    func popupClosed(_ id: ObjectIdentifier, now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        guard openPopups.remove(id) != nil else { return }
        lastClosedAt = now
    }

    func isPopupLikely(now: Date = Date(), grace: TimeInterval = AppHangReportPolicy.popupGraceSeconds) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if !openPopups.isEmpty { return true }
        guard let lastClosedAt else { return false }
        return now.timeIntervalSince(lastClosedAt) < grace
    }
}
