import Foundation

/// A code-signing identity as the socket peers check it: the bundle
/// identifier and, when the code is signed with a Developer ID, its team.
public struct CodeSigningIdentity: Equatable, Sendable {
    public let identifier: String
    public let team: String?

    public init(identifier: String, team: String?) {
        self.identifier = identifier
        self.team = team
    }
}

/// One live process instance. A pid alone is reusable by a later process;
/// the kernel's start time for the pid is what pins the key to this
/// instance, so a cache entry can never be handed to a successor that
/// happened to inherit the number.
public struct ProcessIdentityKey: Hashable, Sendable {
    public let pid: Int32
    public let startedAtSeconds: Int64
    public let startedAtMicroseconds: Int64

    public init(pid: Int32, startedAtSeconds: Int64, startedAtMicroseconds: Int64) {
        self.pid = pid
        self.startedAtSeconds = startedAtSeconds
        self.startedAtMicroseconds = startedAtMicroseconds
    }
}

/// Remembers a resolved code-signing identity per live process instance.
///
/// Resolving a peer's identity through the Security framework is the most
/// expensive fixed cost on the completion socket, and both ends paid it on
/// every typed word for the peer *and* for themselves. A running process
/// cannot change the code it was launched with, so once an instance
/// (pid plus kernel start time) has resolved to an identity, that answer
/// holds for as long as the instance lives. The time-to-live is only a
/// bound on how long a stale positive answer could persist under the
/// threat model the socket already accepts; it is not what makes the
/// cache correct.
///
/// Pure bookkeeping: the caller resolves identities and looks up start
/// times, so this type has no process or Security dependency and the
/// eviction rules are unit-testable. A `nil` resolution is never stored,
/// so a transient failure costs one retry rather than a poisoned entry.
public final class ProcessPeerIdentityCache<Identity: Sendable>: @unchecked Sendable {
    public let timeToLive: TimeInterval
    public let capacity: Int

    private let now: @Sendable () -> TimeInterval
    private let lock = NSLock()
    private var entries: [ProcessIdentityKey: Entry] = [:]

    private struct Entry {
        let identity: Identity
        let storedAt: TimeInterval
    }

    public init(
        timeToLive: TimeInterval = 600,
        capacity: Int = 8,
        now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.timeToLive = max(0, timeToLive)
        self.capacity = max(1, capacity)
        self.now = now
    }

    /// The cached identity for `key` when one is fresh, else whatever
    /// `resolve` returns (stored when non-nil). A `nil` key means the caller
    /// could not pin the process instance; the identity is resolved and
    /// returned uncached, exactly as if this cache did not exist.
    public func identity(
        for key: ProcessIdentityKey?,
        resolve: () -> Identity?
    ) -> Identity? {
        guard let key else { return resolve() }
        let current = now()
        if let cached = lock.withLock({ entries[key] }), current - cached.storedAt < timeToLive {
            return cached.identity
        }
        guard let resolved = resolve() else { return nil }
        lock.withLock {
            entries[key] = Entry(identity: resolved, storedAt: current)
            while entries.count > capacity,
                  let oldest = entries.min(by: { $0.value.storedAt < $1.value.storedAt }) {
                entries.removeValue(forKey: oldest.key)
            }
        }
        return resolved
    }

    /// Number of live entries; for tests and diagnostics only.
    public var count: Int { lock.withLock { entries.count } }
}
