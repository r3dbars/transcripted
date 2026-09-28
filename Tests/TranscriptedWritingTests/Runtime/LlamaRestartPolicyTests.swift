import Foundation
import Testing
@testable import TranscriptedWritingRuntime

@Suite("Llama restart policy")
struct LlamaRestartPolicyTests {
    @Test("Failures back off but always retry")
    func boundedBackoff() {
        var policy = LlamaRestartPolicy()
        let delays = (0..<8).map { _ in policy.delay(wasHealthy: false, uptime: 1) }
        #expect(delays == [2, 4, 8, 16, 32, 60, 60, 60])
    }

    @Test("A proven run resets the backoff")
    func provenRunResets() {
        var policy = LlamaRestartPolicy()
        _ = policy.delay(wasHealthy: false, uptime: 1)
        _ = policy.delay(wasHealthy: false, uptime: 1)
        #expect(policy.delay(wasHealthy: true, uptime: 120) == 2)
        #expect(policy.failures == 1)
    }
}

@Suite("Llama health probe cadence")
struct LlamaHealthProbeCadenceTests {
    @Test("Probes start fast, then settle back to the original steady cadence")
    func laddersFromFastToSteady() {
        #expect(LlamaServerProcessHost.healthProbeDelayMilliseconds(attempt: 0) == 100)
        #expect(LlamaServerProcessHost.healthProbeDelayMilliseconds(attempt: 3) == 100)
        #expect(LlamaServerProcessHost.healthProbeDelayMilliseconds(attempt: 4) == 250)
        #expect(LlamaServerProcessHost.healthProbeDelayMilliseconds(attempt: 8) == 500)
        #expect(LlamaServerProcessHost.healthProbeDelayMilliseconds(attempt: 11) == 500)
        #expect(LlamaServerProcessHost.healthProbeDelayMilliseconds(attempt: 12) == 1_000)
        #expect(LlamaServerProcessHost.healthProbeDelayMilliseconds(attempt: 16) == 2_000)
        #expect(LlamaServerProcessHost.healthProbeAttempts == 51)
        #expect(LlamaServerProcessHost.healthProbeDelayMilliseconds(attempt: 50) == 2_000)
    }

    /// The whole point of the ladder: a helper serving 300ms after launch is
    /// discovered then, not at the next flat two-second tick.
    @Test("A helper ready shortly after launch is discovered in the first few hundred milliseconds")
    func fastStartIsDiscoveredFast() {
        let waitBeforeFourthProbe = (0..<3).reduce(0) {
            $0 + LlamaServerProcessHost.healthProbeDelayMilliseconds(attempt: $1)
        }
        #expect(waitBeforeFourthProbe == 300)
    }

    /// The ceiling that matters is the whole path to `health-timeout`, not the
    /// sleeps alone: every attempt also runs `probeHealth`, which can block for
    /// its own 2-second request timeout against a helper that accepts the
    /// connection but never answers. Counting only sleeps is what let the
    /// attempt count drift upward while the ceiling silently grew with it.
    @Test("The ladder keeps the health-timeout ceiling of the flat loop it replaced")
    func ceilingIsPreserved() {
        let attempts = LlamaServerProcessHost.healthProbeAttempts
        let sleeping = (0..<attempts).reduce(0) {
            $0 + LlamaServerProcessHost.healthProbeDelayMilliseconds(attempt: $1)
        }
        let probing = attempts * 2_000
        // The flat loop it replaced was 45 x (2,000ms probe + 2,000ms sleep).
        #expect(sleeping + probing <= 180_000)
        // And it must not collapse either — a helper still gets a real chance.
        #expect(sleeping + probing >= 170_000)
    }
}

@Suite("Llama listener ownership")
struct LlamaListenerOwnershipTests {
    /// The readiness gate runs this before every completion request. A wrong
    /// "no" here does not degrade a suggestion — it withholds every suggestion,
    /// silently, for as long as it is wrong. So prove it against a real
    /// listening socket rather than trusting the kernel query by inspection.
    ///
    /// Known limit: this inspects `getpid()`, and self-inspection through
    /// libproc is always permitted. Production asks about a *child* pid, where
    /// the App Sandbox and hardened runtime can refuse — a case no unsandboxed
    /// unit test can reproduce. `probeHealth` records
    /// `llama-server-unowned-listener` when the helper answers `/health` but
    /// shows no listening socket, so such a refusal surfaces in diagnostics
    /// rather than silently disabling every suggestion.
    @Test("The kernel query sees a real listening socket, and stops seeing it once closed")
    func tracksARealListeningSocket() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        try #require(descriptor >= 0)
        var stillOpen = true
        defer { if stillOpen { close(descriptor) } }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0 // the kernel picks a free port
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, size) }
        }
        try #require(bound == 0)
        try #require(listen(descriptor, 1) == 0)

        var assigned = sockaddr_in()
        var length = size
        let named = withUnsafeMutablePointer(to: &assigned) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        try #require(named == 0)
        let port = Int(UInt16(bigEndian: assigned.sin_port))
        try #require(port > 0)

        #expect(LlamaServerProcessHost.holdsListeningSocket(pid: getpid(), port: port))

        // Same process, same port, socket gone: the gate must fail closed.
        close(descriptor)
        stillOpen = false
        #expect(!LlamaServerProcessHost.holdsListeningSocket(pid: getpid(), port: port))
    }

    @Test("A port this process never bound is not reported as ours")
    func rejectsAPortWeDoNotHold() {
        // Port 0 is never a real listening port, so this exercises the
        // scan-finds-nothing path without racing another process's socket.
        #expect(!LlamaServerProcessHost.holdsListeningSocket(pid: getpid(), port: 0))
    }
}
