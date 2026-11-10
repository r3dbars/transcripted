import Foundation

/// Authority for system-capture observations, separate from native producer
/// lifetime and the attempt that owns its recorded-file tail. Every mutation
/// validates the binding under the same lock that advances the session.
final class SystemAudioObservationOwnership: @unchecked Sendable {
    struct Token: Equatable, Sendable {
        let generation: UInt64
        let captureID: ObjectIdentifier
        fileprivate let revision: UInt64
    }

    private let lock = NSLock()
    private var sessionGeneration: UInt64?
    private var binding: Token?
    private var revision: UInt64 = 0
    private var recoveryDepth = 0

    /// Starting the same session again must not discard its binding or holds.
    /// An older start cannot rewind authority belonging to a newer recording.
    @discardableResult
    func beginSession(generation: UInt64) -> Bool {
        lock.withLock {
            if let current = sessionGeneration {
                guard generation >= current else { return false }
                if generation == current { return true }
            }
            sessionGeneration = generation
            binding = nil
            recoveryDepth = 0
            return true
        }
    }

    /// Every accepted binding gets new authority, including the same backend
    /// object reused within one session. Tokens retain its identity, not it.
    func bind(generation: UInt64, captureID: ObjectIdentifier) -> Token? {
        lock.withLock {
            guard sessionGeneration == generation else { return nil }
            revision &+= 1
            let token = Token(generation: generation, captureID: captureID, revision: revision)
            binding = token
            recoveryDepth = 0
            return token
        }
    }

    func owns(_ token: Token) -> Bool {
        lock.withLock { ownsLocked(token) }
    }

    @discardableResult
    func beginRecovery(_ token: Token) -> Bool {
        lock.withLock {
            guard ownsLocked(token) else { return false }
            recoveryDepth += 1
            return true
        }
    }

    @discardableResult
    func endRecovery(_ token: Token) -> Bool {
        lock.withLock {
            guard ownsLocked(token), recoveryDepth > 0 else { return false }
            recoveryDepth -= 1
            return true
        }
    }

    var isHolding: Bool {
        lock.withLock { recoveryDepth > 0 }
    }

    // Caller holds lock. No host callback, queue hop, publisher or native
    // operation runs within this authority's critical sections.
    private func ownsLocked(_ token: Token) -> Bool {
        sessionGeneration == token.generation && binding == token
    }
}
