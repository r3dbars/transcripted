import Foundation
import Testing
@testable import TranscriptedWritingCore

@Suite("Process peer identity cache")
struct ProcessPeerIdentityCacheTests {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: TimeInterval = 1_000
        var now: TimeInterval { lock.withLock { value } }
        func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
    }

    private final class Resolver: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        var answer: CodeSigningIdentity? = CodeSigningIdentity(identifier: "com.justinbetker.draft", team: "TEAM")
        var callCount: Int { lock.withLock { calls } }
        func resolve() -> CodeSigningIdentity? {
            lock.withLock { calls += 1 }
            return answer
        }
    }

    private let key = ProcessIdentityKey(pid: 4_242, startedAtSeconds: 1_700_000_000, startedAtMicroseconds: 5)

    @Test("A fresh entry is served without resolving again")
    func hitSkipsResolution() {
        let clock = Clock()
        let cache = ProcessPeerIdentityCache<CodeSigningIdentity>(now: { clock.now })
        let resolver = Resolver()

        let first = cache.identity(for: key, resolve: resolver.resolve)
        let second = cache.identity(for: key, resolve: resolver.resolve)

        #expect(first == resolver.answer)
        #expect(second == resolver.answer)
        #expect(resolver.callCount == 1)
    }

    @Test("The same pid with a different start time is a different process")
    func pidReuseMisses() {
        let cache = ProcessPeerIdentityCache<CodeSigningIdentity>()
        let resolver = Resolver()
        _ = cache.identity(for: key, resolve: resolver.resolve)

        let successor = ProcessIdentityKey(pid: key.pid, startedAtSeconds: key.startedAtSeconds + 30, startedAtMicroseconds: 0)
        _ = cache.identity(for: successor, resolve: resolver.resolve)

        #expect(resolver.callCount == 2)
        #expect(cache.count == 2)
    }

    @Test("An expired entry is resolved again")
    func expiryRefreshes() {
        let clock = Clock()
        let cache = ProcessPeerIdentityCache<CodeSigningIdentity>(timeToLive: 60, now: { clock.now })
        let resolver = Resolver()
        _ = cache.identity(for: key, resolve: resolver.resolve)
        clock.advance(59)
        _ = cache.identity(for: key, resolve: resolver.resolve)
        #expect(resolver.callCount == 1)
        clock.advance(2)
        _ = cache.identity(for: key, resolve: resolver.resolve)
        #expect(resolver.callCount == 2)
    }

    @Test("A failed resolution is never cached")
    func nilIsNotStored() {
        let cache = ProcessPeerIdentityCache<CodeSigningIdentity>()
        let resolver = Resolver()
        resolver.answer = nil
        #expect(cache.identity(for: key, resolve: resolver.resolve) == nil)
        #expect(cache.count == 0)
        resolver.answer = CodeSigningIdentity(identifier: "com.justinbetker.draft", team: "TEAM")
        #expect(cache.identity(for: key, resolve: resolver.resolve) == resolver.answer)
        #expect(resolver.callCount == 2)
    }

    @Test("Without a process key the identity is resolved every time")
    func nilKeyBypasses() {
        let cache = ProcessPeerIdentityCache<CodeSigningIdentity>()
        let resolver = Resolver()
        _ = cache.identity(for: nil, resolve: resolver.resolve)
        _ = cache.identity(for: nil, resolve: resolver.resolve)
        #expect(resolver.callCount == 2)
        #expect(cache.count == 0)
    }

    @Test("Capacity evicts the oldest entry")
    func capacityEvictsOldest() {
        let clock = Clock()
        let cache = ProcessPeerIdentityCache<CodeSigningIdentity>(capacity: 2, now: { clock.now })
        let resolver = Resolver()
        let keys = (0..<3).map { ProcessIdentityKey(pid: Int32(100 + $0), startedAtSeconds: 1, startedAtMicroseconds: 0) }
        for key in keys {
            _ = cache.identity(for: key, resolve: resolver.resolve)
            clock.advance(1)
        }
        #expect(cache.count == 2)
        // The first key was evicted, so it resolves again; the newest did not.
        _ = cache.identity(for: keys[0], resolve: resolver.resolve)
        #expect(resolver.callCount == 4)
        _ = cache.identity(for: keys[2], resolve: resolver.resolve)
        #expect(resolver.callCount == 4)
    }
}
