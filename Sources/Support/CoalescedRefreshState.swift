/// One running read and one pending refresh. The owner serializes access (usually
/// on the main actor), calls `finished()` exactly once for every started read,
/// and may suspend new reads while its surface is hidden. A pending change is
/// retained until the next visible request; no notification payload is discarded.
struct CoalescedRefreshState: Sendable {
    var isEnabled = true
    private(set) var isRunning = false
    private(set) var isPending = false

    init(isEnabled: Bool = true) {
        self.isEnabled = isEnabled
    }

    mutating func request() -> Bool {
        isPending = true
        return takePending()
    }

    mutating func finished() -> Bool {
        isRunning = false
        return takePending()
    }

    /// Starts a change held while disabled, without adding a new request.
    mutating func startPending() -> Bool {
        takePending()
    }

    private mutating func takePending() -> Bool {
        guard isEnabled, !isRunning, isPending else { return false }
        isPending = false
        isRunning = true
        return true
    }
}

/// Reads are submitted in revision order, but their owner may resume completion
/// tasks in a different order. Never replace a published snapshot with an older
/// one; callers still deliver each edit's completion independently.
struct RefreshPublicationOrder: Sendable {
    private var requested: UInt64 = 0
    private var published: UInt64 = 0

    mutating func beginRead() -> UInt64 {
        requested &+= 1
        return requested
    }

    mutating func accept(_ revision: UInt64) -> Bool {
        guard revision > published, revision <= requested else { return false }
        published = revision
        return true
    }
}
