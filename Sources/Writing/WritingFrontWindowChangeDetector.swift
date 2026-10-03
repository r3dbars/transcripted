import Foundation

/// The decision half of Writing's 1 Hz front-window poll, kept pure so it can
/// be tested without a window server.
///
/// Reads happen on the poll's background queue (`record`); the window-changed
/// trigger runs on main (`takeDelivery`). Main hears about a read only when it
/// differs from the previous read, and at most one delivery is ever pending:
/// a later change before main runs just replaces it. Main then fires only if
/// the identity differs from the last one it acted on, so a change that
/// reverts while main is busy (A→B→A) fires nothing, and A→B→C fires once
/// with C. That's the same single comparison the old main-thread poll made.
///
/// The first read records the baseline and never fires.
struct FrontWindowChangeDetector<Identity: Equatable> {
    private var hasBaseline = false
    private var lastRead: Identity?
    private var lastActed: Identity?
    private var hasPending = false
    private var pending: Identity?

    init() {}

    /// Background side. Returns true when the caller should schedule a main
    /// hop: something changed and no hop is already on its way.
    mutating func record(_ identity: Identity?) -> Bool {
        guard hasBaseline else {
            hasBaseline = true
            lastRead = identity
            lastActed = identity
            return false
        }
        guard identity != lastRead else { return false }
        lastRead = identity
        pending = identity
        if hasPending { return false }
        hasPending = true
        return true
    }

    /// Main side. Returns `.some(identity)` when the trigger should fire with
    /// that identity (which may itself be nil: no front window), `.none` when
    /// there's nothing to do.
    mutating func takeDelivery() -> Identity?? {
        guard hasPending else { return .none }
        hasPending = false
        let identity = pending
        pending = nil
        guard identity != lastActed else { return .none }
        lastActed = identity
        return .some(identity)
    }
}

/// Reuses the last bundle ID while the front window's (pid, window number)
/// stays the same, so an unchanged tick skips the LaunchServices read. A nil
/// result is never reused: the next read asks again.
struct FrontWindowBundleMemo {
    private var key: (pid: Int32, window: UInt32)?
    private var bundleIdentifier: String?

    init() {}

    mutating func bundleIdentifier(
        pid: Int32,
        window: UInt32,
        lookup: (Int32) -> String?
    ) -> String? {
        if let key, key.pid == pid, key.window == window, let bundleIdentifier {
            return bundleIdentifier
        }
        let resolved = lookup(pid)
        key = (pid, window)
        bundleIdentifier = resolved
        return resolved
    }
}
