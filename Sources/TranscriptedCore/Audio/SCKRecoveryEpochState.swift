/// Lock-owned coordination for the one bounded ScreenCaptureKit recovery.
///
/// An official stop disables recovery and advances the epoch. Internal cleanup
/// may preserve the active token so the same recovery can continue, but a stale
/// token can never become current again.
struct SCKRecoveryEpochState {
    typealias Token = UInt64

    private(set) var epoch: UInt64 = 0
    private(set) var activeToken: Token?
    private(set) var acceptsRecovery = false

    mutating func enableForActiveCapture() {
        epoch &+= 1
        activeToken = nil
        acceptsRecovery = true
    }

    mutating func begin() -> Token? {
        guard acceptsRecovery else { return nil }
        epoch &+= 1
        activeToken = epoch
        return epoch
    }

    @discardableResult
    mutating func cancel(preserving token: Token? = nil) -> Bool {
        if let token, isCurrent(token) {
            return false
        }
        epoch &+= 1
        activeToken = nil
        acceptsRecovery = false
        return true
    }

    func isCurrent(_ token: Token) -> Bool {
        acceptsRecovery && activeToken == token && epoch == token
    }

    @discardableResult
    mutating func finish(_ token: Token) -> Bool {
        guard isCurrent(token) else { return false }
        activeToken = nil
        return true
    }
}
