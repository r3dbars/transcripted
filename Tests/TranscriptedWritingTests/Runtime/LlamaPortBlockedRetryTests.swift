import TranscriptedWritingCore
import Darwin
import Foundation
import Testing
@testable import TranscriptedWritingRuntime

/// When another process holds the helper's port, Writing keeps retrying on
/// the same ladder, but a retry that can prove the same refused listener is
/// still there skips the seal check, the model clone and lsof. Anything that
/// changed takes the full path on that same retry.
///
/// The "foreign listener" is a real listening socket owned by the test
/// process, so the libproc check is real. lsof and the retry timer are fakes,
/// so no wall clock is involved.
@Suite("Llama port-in-use retries", .serialized)
struct LlamaPortBlockedRetryTests {
    @Test("A foreign listener that stays put costs one asset resolve and one lsof, on the unchanged retry ladder")
    func stuckListenerRetriesCheaply() async throws {
        let socket = try ListeningSocket()
        defer { socket.close() }
        let world = FakeWorld(listeners: [getpid()])
        let host = world.host(port: socket.port)
        host.start()
        defer { host.stop() }

        try await world.waitForRetries(1)
        for retry in 2...9 {
            world.fireNextRetry()
            try await world.waitForRetries(retry)
            #expect(host.snapshot == .retrying(.portInUse))
        }

        #expect(world.assetResolves == 1)
        #expect(world.listenerLookups == 1)
        #expect(world.delays == [2, 4, 8, 16, 32, 60, 60, 60, 60])
    }

    @Test("Once the listener lets go, the very next retry takes the full path and launches")
    func freedPortRecoversOnNextRetry() async throws {
        let socket = try ListeningSocket()
        let world = FakeWorld(listeners: [getpid()])
        let host = world.host(port: socket.port)
        host.start()
        defer { host.stop() }

        try await world.waitForRetries(1)
        world.fireNextRetry()
        try await world.waitForRetries(2)
        #expect(world.assetResolves == 1)

        socket.close()
        world.setListeners([])
        world.fireNextRetry()
        try await world.waitForRetries(3)

        #expect(world.assetResolves == 2)
        #expect(world.listenerLookups == 2)
        // The stand-in binary doesn't exist, so the launch itself fails.
        #expect(host.snapshot == .retrying(.launchFailed))
    }

    @Test("A listener lsof names but that no longer holds the port gets the full path every retry")
    func unprovenListenerTakesFullPath() async throws {
        // Nothing listens on this port, but the fake lsof still names us.
        let port = try ListeningSocket.unusedPort()
        let world = FakeWorld(listeners: [getpid()])
        let host = world.host(port: port)
        host.start()
        defer { host.stop() }

        try await world.waitForRetries(1)
        for retry in 2...4 {
            world.fireNextRetry()
            try await world.waitForRetries(retry)
        }
        #expect(world.assetResolves == 4)
        #expect(world.listenerLookups == 4)
        #expect(host.snapshot == .retrying(.portInUse))
    }

    @Test("Missing assets with a busy port is still terminal")
    func missingAssetsStayTerminal() async throws {
        let socket = try ListeningSocket()
        defer { socket.close() }
        let world = FakeWorld(listeners: [getpid()], assetsMissing: true)
        let host = world.host(port: socket.port)
        host.start()
        defer { host.stop() }

        try await world.waitForAssetResolves(1)
        try await world.waitFor { host.snapshot == .failed(.assetsMissing) }
        #expect(world.delays.isEmpty)
    }

    @Test("Stopping and starting again resolves the assets again")
    func restartResolvesAgain() async throws {
        let socket = try ListeningSocket()
        defer { socket.close() }
        let world = FakeWorld(listeners: [getpid()])
        let host = world.host(port: socket.port)
        host.start()
        defer { host.stop() }

        try await world.waitForRetries(1)
        host.stop()
        host.start()
        try await world.waitForRetries(2)
        #expect(world.assetResolves == 2)
        #expect(world.listenerLookups == 2)
    }

    @Test("The cheap retry is taken only when the full path would refuse too")
    func stillBlockedMatchesTheReapRule() {
        let binary = "/Applications/Transcripted.app/Contents/Helpers/llama-server"
        func stillBlocked(
            _ pids: [Int32],
            listening: Set<Int32>,
            path: String = "/usr/local/bin/other",
            parent: String = "1"
        ) -> Bool {
            LlamaServerProcessHost.stillBlocked(
                .init(binary: binary, pids: pids),
                port: 17891,
                isListening: { pid, _ in listening.contains(pid) },
                executablePath: { _ in path },
                parentProcess: { _ in parent }
            )
        }

        // Someone else's listener that's still there: blocked.
        #expect(stillBlocked([4242], listening: [4242]))
        // It went away: take the full path.
        #expect(!stillBlocked([4242], listening: []))
        // Two refused listeners, one gone: take the full path.
        #expect(!stillBlocked([4242, 5353], listening: [4242]))
        #expect(stillBlocked([4242, 5353], listening: [4242, 5353]))
        // Our own helper, still parented to a live app: blocked.
        #expect(stillBlocked([4242], listening: [4242], path: binary, parent: "977"))
        // Our own helper now adopted by launchd is reapable: full path.
        #expect(!stillBlocked([4242], listening: [4242], path: binary, parent: "1"))
        // Nothing remembered never counts as blocked.
        #expect(!stillBlocked([], listening: []))
    }

    @Test("Whenever the cheap retry says blocked, the full reap rule refuses every set holding those listeners")
    func stillBlockedImpliesFullPathRefuses() {
        let binary = "/Applications/Transcripted.app/Contents/Helpers/llama-server"
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<500 {
            let remembered = (0..<Int.random(in: 1...3, using: &generator)).map { _ in
                Int32.random(in: 100...110, using: &generator)
            }
            let extra = (0..<Int.random(in: 0...2, using: &generator)).map { _ in
                Int32.random(in: 100...110, using: &generator)
            }
            let current = Array(Set(remembered + extra))
            let listening = Set(current)
            let ours = Set(current.filter { _ in Bool.random(using: &generator) })
            let adopted = Set(current.filter { _ in Bool.random(using: &generator) })
            let path: (Int32) -> String? = { ours.contains($0) ? binary : "/usr/bin/other" }
            let parent: (Int32) -> String? = { adopted.contains($0) ? "1" : "977" }

            let blocked = LlamaServerProcessHost.stillBlocked(
                .init(binary: binary, pids: Array(Set(remembered))),
                port: 17891,
                isListening: { pid, _ in listening.contains(pid) },
                executablePath: path,
                parentProcess: parent
            )
            guard blocked else { continue }
            let reap = LlamaServerProcessHost.orphanToReap(
                listeners: current,
                binary: binary,
                executablePath: path,
                parentProcess: parent
            )
            #expect(reap == nil)
        }
    }
}

/// Counting fakes for the host's asset resolver, lsof and retry timer.
private final class FakeWorld: @unchecked Sendable {
    private let lock = NSLock()
    private var listenerSet: [Int32]
    private let assetsMissing: Bool
    private var resolves = 0
    private var lookups = 0
    private var requestedDelays: [TimeInterval] = []
    private var pending: [@Sendable () -> Void] = []

    init(listeners: [Int32], assetsMissing: Bool = false) {
        listenerSet = listeners
        self.assetsMissing = assetsMissing
    }

    var assetResolves: Int { lock.withLock { resolves } }
    var listenerLookups: Int { lock.withLock { lookups } }
    var delays: [TimeInterval] { lock.withLock { requestedDelays } }

    func setListeners(_ listeners: [Int32]) { lock.withLock { listenerSet = listeners } }

    func host(port: Int) -> LlamaServerProcessHost {
        LlamaServerProcessHost(
            port: port,
            assetResolver: { [self] in
                lock.withLock { resolves += 1 }
                return assetsMissing ? nil : .init(binary: LlamaPortBlockedRetryTestsPaths.binary, model: "/nonexistent-model")
            },
            portListeners: { [self] _ in
                lock.withLock {
                    lookups += 1
                    return listenerSet
                }
            },
            retryScheduler: { [self] delay, fire in
                lock.withLock {
                    requestedDelays.append(delay)
                    pending.append(fire)
                }
            }
        )
    }

    func fireNextRetry() {
        let fire = lock.withLock { pending.isEmpty ? nil : pending.removeFirst() }
        fire?()
    }

    func waitForRetries(_ count: Int) async throws {
        try await waitFor { self.delays.count >= count }
    }

    func waitForAssetResolves(_ count: Int) async throws {
        try await waitFor { self.assetResolves >= count }
    }

    /// Polls an outcome; the iteration cap only stops a broken test from
    /// hanging and is not a timing assertion.
    func waitFor(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<2_000 where !condition() {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        try #require(condition())
    }
}

private enum LlamaPortBlockedRetryTestsPaths {
    static let binary = "/nonexistent-\(UUID().uuidString)/llama-server"
}

/// A real TCP listener on 127.0.0.1, owned by the test process.
private final class ListeningSocket: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32
    let port: Int

    init() throws {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EBADF) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 1) == 0 else {
            Darwin.close(fd)
            throw POSIXError(.EADDRINUSE)
        }
        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &assigned) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard named == 0 else {
            Darwin.close(fd)
            throw POSIXError(.EBADF)
        }
        descriptor = fd
        port = Int(UInt16(bigEndian: assigned.sin_port))
    }

    /// A port that was free a moment ago; nothing listens on it afterwards.
    static func unusedPort() throws -> Int {
        let socket = try ListeningSocket()
        socket.close()
        return socket.port
    }

    func close() {
        lock.withLock {
            guard descriptor >= 0 else { return }
            Darwin.close(descriptor)
            descriptor = -1
        }
    }

    deinit { close() }
}
